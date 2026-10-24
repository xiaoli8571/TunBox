/**
 * 代理入口 DoH 预解析：解析出的 IP 写进 YAML `hosts:`，让内核拨代理服务器时
 * 不再走运行期明文 DNS（防投毒）。
 *
 * ## 2026-10-18 修正：pin 必须有 DNS TTL 支撑，短 TTL 记录一律**不 pin**
 *
 * 旧实现按固定 3h/6h 计时，与 DNS 记录自身的 TTL 无关。而机场入口域名普遍是
 * 60~120s 短 TTL + IP 轮换（AWS EIP 换绑），旧 IP 几分钟后就 ping 不通；`hosts:`
 * 又是**永久覆盖**（内核整条连接生命周期都不会再问 DNS），于是节点被钉死在失效
 * 地址上：拨号 5s 无应答 → 内核 504 → 界面整屏「超时」。
 *
 * 真机取证（2026-10-18 20:0x，飞鸟云 34 个 hysteria2 节点）：
 *   · 34 节点批 `measured=0~3 / timeout=29~32`，同一网络 FlClash 实测 <200ms；
 *   · 当时落的 hosts pin：sg02=13.228.124.169 / sg03=3.1.16.214 / us03=35.163.34.69
 *     ……**全部已失效**（DNS 现解析 sg02=18.141.49.209，旧 IP 100% 丢包；该域名
 *     TTL 只有 60~120s）；
 *   · 同一份 YAML 在 PC 上用同一内核复现：带 pin → 503/5.0s；把 pin 换成现解析值
 *     → 164~330ms；**整段删掉 pin → 155~250ms**。
 * 结论：pin 只对「记录本身稳定」的域名有意义；短 TTL 记录交给内核运行期解析
 * （内核 DNS 缓存按 TTL 过期，这正是 FlClash 等客户端的口径）。
 *
 * ## ⚠ 与 ClashConfigGenerator 的 proxy-server-nameserver **强耦合**（2026-10-19）
 *
 * 上面这个结论有一个隐含前提：**内核自己解析代理域名时必须是安全的**。
 * 2026-10-19 之前该配置是明文 UDP `223.5.5.5 / 119.29.29.29`，理由写在
 * ClashConfigGenerator 里：「这些域名已被 UI 进程 DoH pin 进 hosts:，运行期几乎
 * 不会被真的问到」。而「短 TTL 不 pin」把这条前提推翻了 —— 机场入口域名 TTL
 * 实测 60~120s，**永远拿不到 pin**，于是内核每次都要用明文 UDP 解析它们，
 * 而明文 UDP/53 在国内会被投毒（实测 www.google.com → 185.45.5.35，
 * 真值 142.251.155.119）。后果是拨代理服务器打到假 IP → 全节点超时 →
 * 「连上了但没有出口 / 公网 IP 查不到」。
 *
 * 因此 2026-10-19 已把 `proxy-server-nameserver` 同步改为加密 DoT
 * （`tls://223.5.5.5:853` + `tls://1.12.12.12:853`）。**两者必须一起改**：
 *   · 恢复「短 TTL 也 pin」→ 可以保留加密 DoT（没有坏处，只是多几毫秒）；
 *   · 想退回明文 UDP → 必须先恢复长 TTL pin，否则投毒面立刻回来。
 */
import { http } from '@kit.NetworkKit';
import { AppLogger } from '../utils/AppLogger';
import { SettingsService } from './SettingsService';

const TAG = 'DoHResolver';
const ENDPOINTS: string[] = ['https://doh.pub/dns-query', 'https://dns.alidns.com/resolve'];
/** 只有 TTL ≥ 该值的记录才允许写进 hosts（实测机场入口域名 TTL 多为 60~300s）。 */
const MIN_PIN_TTL_MS = 10 * 60 * 1000;
/** 即便 TTL 更长，pin 也不无限期覆盖：超过该年龄一律丢弃重解析。 */
const PIN_MAX_AGE_MS = 60 * 60 * 1000;
/** 被判为「短 TTL 不可 pin」的域名，多久内不再重复查询（内核自己会解析）。 */
const UNPINNABLE_HOLD_MS = 30 * 60 * 1000;
const PERSIST_DEBOUNCE_MS = 2000;

/**
 * 易变/临时隧道域名（加固③a）：quick tunnel / 内网穿透类域名轮换极快
 * （*.trycloudflare.com 每次都是随机子域），把它们 pin 到固定 IP 会让
 * 域名轮换后所有命中节点同时超时。这类域名不 pin、不缓存、不持久化，
 * 域名留给内核运行时解析。
 */
const VOLATILE_DOMAIN_SUFFIXES: string[] = ['trycloudflare.com', 'loca.lt', 'serveo.net', 'localtunnel.me'];

function isVolatileDomain(domain: string): boolean {
  const d = domain.trim().toLowerCase();
  for (const s of VOLATILE_DOMAIN_SUFFIXES) {
    if (d === s || d.endsWith('.' + s)) {
      return true;
    }
  }
  return false;
}

interface DoHAnswer {
  name: string;
  type: number;
  data: string;
  /** 记录 TTL（秒）。DoH JSON 规范字段，doh.pub / alidns 都会返回。 */
  TTL?: number;
}
interface DoHResponse {
  Status: number;
  Answer?: DoHAnswer[];
}
class DoHPin {
  ip: string;
  resolvedAt: number;
  /** 有效寿命（毫秒）= min(DoH 应答 TTL, PIN_MAX_AGE_MS)。 */
  lifetimeMs: number;
  constructor(ip: string, resolvedAt: number, lifetimeMs: number) {
    this.ip = ip;
    this.resolvedAt = resolvedAt;
    this.lifetimeMs = lifetimeMs;
  }
}

/**
 * 一次 `resolveMany()` 的**过程报告**（谁真的查了、查成没成）。
 *
 * 为什么需要它：「解析失败」这个结论**必须**能区分三件事 ——
 *   ① 查了，查到了（resolved）；
 *   ② 查了，没查到（failed ⇒ 真·NXDOMAIN ⇒ 判 dns_unresolved）；
 *   ③ **根本没查**（skipped：短 TTL 域名被故意不 pin；或域名不在本批）。
 * ②与③混为一谈就会**误报**「域名无法解析」（实测教训：2026-10-20 真机）。
 */
export class DoHResolveReport {
  /** 真的发过 DoH 查询的域名（小写）。 */
  queried: string[] = [];
  /** 查到了地址的域名（小写；含后续因易变/劫持嫌疑被丢弃的）。 */
  resolved: string[] = [];
  /** 查了但没拿到地址的域名（小写）⇒ 真·解析失败。 */
  failed: string[] = [];
  /** 故意没查的域名（小写：短 TTL / 不 pin）⇒ 没试过，不能下结论。 */
  skipped: string[] = [];
}

export class DoHResolver {
  private static cache: Map<string, DoHPin> = new Map<string, DoHPin>();
  /** 最近一次 resolveMany 的过程报告（供测速侧判定 DNS 结论）。 */
  static lastReport: DoHResolveReport = new DoHResolveReport();
  /**
   * DoH 上游判死的负缓存截止时间（0 = 未判死）。判死条件与收益见 resolveMany
   * 头注释（蜂窝下 86 域名陪跑超时、每次连接重复全灭）。TTL 3 分钟，到期自动重试。
   */
  private static dohDownUntil: number = 0;
  private static readonly CACHE_MAX_ENTRIES: number = 512;
  private static readonly WORKERS: number = 16;
  private static loaded: boolean = false;
  private static loading: Promise<void> | null = null;
  private static refreshing: Promise<number> | null = null;
  private static persistTimer: number = -1;
  private static staleQueue: Set<string> = new Set<string>();
  /**
   * 「短 TTL 不 pin」留痕：域名 → 该结论的有效截止时间。
   * 目的有两个：① 别再对它反复发 DoH 查询（内核会按 TTL 自己解析）；
   * ② 让连接路径的 DoH 预算真正落地（否则每次连接都要等它查完）。
   */
  private static unpinnable: Map<string, number> = new Map<string, number>();

  /** 并发调用共享同一载入任务；失败允许下一次重试。 */
  static async ensureLoaded(): Promise<void> {
    if (DoHResolver.loaded) {
      return;
    }
    if (DoHResolver.loading !== null) {
      return DoHResolver.loading;
    }
    const task = DoHResolver.loadPersisted();
    DoHResolver.loading = task;
    try {
      await task;
    } finally {
      DoHResolver.loading = null;
    }
  }

  private static async loadPersisted(): Promise<void> {
    try {
      const persisted = await SettingsService.loadDohPins();
      const now = Date.now();
      let dropped = 0;
      for (const domain of Object.keys(persisted)) {
        const packed = persisted[domain];
        if (typeof packed !== 'string') {
          dropped++;
          continue;
        }
        // 易变域名不加载历史 pin（加固③a）
        if (isVolatileDomain(domain)) {
          dropped++;
          continue;
        }
        // 只有 `ip|resolvedAt|lifetimeMs` 三段的记录才带得动 TTL 契约。
        // 旧版两段式（ip|ts）没有 TTL 依据，而机场短 TTL 域名的旧 IP 往往已经
        // 轮换 —— 留着就是把节点钉在失效地址上（本次真机「整屏超时」的直接原因）。
        const parts = packed.split('|');
        if (parts.length < 3) {
          dropped++;
          continue;
        }
        const ip = parts[0];
        const ts = Number(parts[1]);
        const lifetime = Math.min(Number(parts[2]), PIN_MAX_AGE_MS);
        if (!DoHResolver.looksLikeIPv4(ip) || !Number.isFinite(ts) || ts <= 0 || ts > now
          || !Number.isFinite(lifetime) || lifetime < MIN_PIN_TTL_MS
          || now - ts >= lifetime) {
          dropped++;
          continue;
        }
        DoHResolver.cachePut(domain.toLowerCase(), ip, lifetime, false, ts);
      }
      DoHResolver.loaded = true;
      if (dropped > 0) {
        AppLogger.info(TAG, `doh pin cache: dropped ${dropped} legacy/short-ttl entr(ies)`);
        // 立即重写一次：旧条目留在磁盘上会被下一个进程反复加载、反复丢弃。
        DoHResolver.schedulePersist();
      }
    } catch (e) {
      AppLogger.warn(TAG, `doh pin cache load failed: ${AppLogger.errText(e)}`);
    }
  }

  /** 该域名是否已被判为「短 TTL，不 pin」，且结论仍在有效期内。 */
  private static isHeldUnpinnable(domain: string): boolean {
    const until = DoHResolver.unpinnable.get(domain);
    if (until === undefined) {
      return false;
    }
    if (Date.now() >= until) {
      DoHResolver.unpinnable.delete(domain);
      return false;
    }
    return true;
  }

  /**
   * 命中时同样检查年龄；长驻进程不能无限使用已经失效的 IP。
   * 年龄按 pin 自身的 lifetime（= min(DNS TTL, PIN_MAX_AGE_MS)）判定：
   * 过寿命一半即进 stale 队列，到期直接丢弃。
   */
  private static cachedIp(domain: string): string {
    const pin = DoHResolver.cache.get(domain);
    if (pin === undefined) {
      return '';
    }
    const age = Date.now() - pin.resolvedAt;
    if (age < 0 || age >= pin.lifetimeMs) {
      DoHResolver.cache.delete(domain);
      DoHResolver.staleQueue.delete(domain);
      return '';
    }
    if (age * 2 >= pin.lifetimeMs) {
      DoHResolver.staleQueue.add(domain);
    }
    DoHResolver.cache.delete(domain);
    DoHResolver.cache.set(domain, pin);
    return pin.ip;
  }

  /**
   * 丢弃某个域名的 pin（下次生成配置时该域名不再进 hosts，改由内核按 TTL 现解析）。
   * 场景：pin 存在却仍然拨号超时 —— 说明记录已轮换，pin 是负资产。
   */
  static dropPin(domain: string): void {
    const d = domain.trim().toLowerCase();
    if (d.length === 0) {
      return;
    }
    if (DoHResolver.cache.delete(d)) {
      DoHResolver.staleQueue.delete(d);
      AppLogger.info(TAG, `doh pin dropped (dial timed out): ${d}`);
      DoHResolver.schedulePersist();
    }
  }

  /**
   * 该域名是否已有**可复用**的 pin（内存缓存里的，或上次落盘、被 loadPersisted
   * 读回来的）。
   *
   * 2026-10-20：接回 resolveMany 的解析主路径 —— 发 DoH 查询之前先问它「有没有
   * 现成的 pin」，命中就直接复用，省一次 DoH 往返；落盘的 pin 跨进程可用
   * （见 loadPersisted），所以第二次起的连接几乎零成本。
   *
   * ⚠ 用途边界（0.4.0 的教训，务必守住）：它**只**用来回答「这次查询能不能
   *   省掉」，**绝不能**用来收紧 DoH 预算。0.4.0 曾用它把连接期预算从 6s 收到
   *   1.5s（命中 pin 就认为"关键域名已就绪"），结果备用节点域名几乎必然解析不到
   *   （见 ConnectionOrchestrator 里 resolveMany 的注释）。预算固定 6000ms，
   *   由 scripts/verify-connect-stability.mjs 的 b10 断言守着
   *   （`hasUsablePin(priorityDomain)` 不得出现在编排器里）。
   */
  static async hasUsablePin(domain: string): Promise<boolean> {
    if (domain.length === 0) {
      return false;
    }
    await DoHResolver.ensureLoaded();
    return DoHResolver.cachedIp(domain.toLowerCase()).length > 0;
  }

  static async resolveMany(domains: string[], budgetMs: number = 6000,
    priorityDomains: string[] = []): Promise<Record<string, string>> {
    await DoHResolver.ensureLoaded();
    // 【2026-10-24 蜂窝启动慢修复】DoH 上游判死负缓存：蜂窝网络下 doh.pub/alidns 的
    // DoH 端点常被运营商拦截，一轮 86 个域名全部陪跑超时（真机 2.7s，最坏 6s 预算
    // 全吃满），且每次连接都重复同样的全灭。判死条件 = 本轮前 6 个查询全部失败且
    // 0 成功 —— 此时取消剩余查询并封 3 分钟（TTL 内 resolveMany 只走 pin 缓存、
    // 不再联网；到期自动重试，用户切回 WiFi 即恢复）。
    const upstreamDown = Date.now() < DoHResolver.dohDownUntil;
    const result: Record<string, string> = {};
    const report: DoHResolveReport = new DoHResolveReport();
    const seen = new Set<string>();
    let pending: string[] = [];
    const priority = new Set<string>();
    for (const raw of priorityDomains) {
      priority.add(raw.toLowerCase());
    }
    for (const raw of domains) {
      const d = raw.toLowerCase();
      if (seen.has(d)) {
        continue;
      }
      seen.add(d);
      // 已有可用 pin（含从磁盘读回的持久化 pin）就直接复用，不再发 DoH 往返。
      // ⚠ 这里**只**决定「这一条要不要查」，不参与任何预算判断 —— 预算恒为
      //   budgetMs，备用域名照样拿满（见 hasUsablePin 的用途边界注释）。
      if (await DoHResolver.hasUsablePin(d)) {
        result[d] = DoHResolver.cachedIp(d);
        report.resolved.push(d);
        continue;
      }
      if (!DoHResolver.isHeldUnpinnable(d)) {
        pending.push(d);
      } else {
        report.skipped.push(d);
      }
      // 命中「短 TTL 不 pin」结论的域名既不进结果也不查询：
      // 它会被写进 hosts 就会钉住会轮换的 IP，而内核自己按 TTL 解析是对的。
    }
    pending = DoHResolver.sortByPriority(pending, priority);
    if (upstreamDown) {
      // 负缓存窗口内不发任何 DoH 查询：域名全部如实记 failed（运行期内核自己走
      // proxy-server-nameserver 解析，与现有 unpinned 回退路径完全一致）。
      for (const d of pending) {
        report.failed.push(d);
      }
      DoHResolver.lastReport = report;
      return result;
    }
    const deadline = Date.now() + Math.max(0, budgetMs);
    let consecutiveFailures = 0;
    let anySuccess = false;
    let abortedUpstream = false;
    for (let pass = 0; pass < 2 && pending.length > 0 && !abortedUpstream; pass++) {
      const current = pending;
      const remaining: string[] = [];
      const workers: Promise<void>[] = [];
      let idx = 0;
      for (let w = 0; w < DoHResolver.WORKERS; w++) {
        workers.push((async (): Promise<void> => {
          while (Date.now() < deadline && idx < current.length && !abortedUpstream) {
            const d = current[idx++];
            report.queried.push(d);
            const ip = await DoHResolver.resolveANoCache(d, deadline);
            if (ip.length > 0) {
              anySuccess = true;
              consecutiveFailures = 0;
              report.resolved.push(d);
              // 只有**真的被 pin 住**的域名才允许进 hosts（短 TTL 的 cachePut 会
              // 直接拒收，此时 cachedIp 为空 → 该域名不进结果，交给内核现解析）。
              const pinned = DoHResolver.cachedIp(d);
              if (pinned.length > 0) {
                result[d] = pinned;
              }
            } else {
              report.failed.push(d);
              remaining.push(d);
              consecutiveFailures++;
              // 前 6 个查询全灭且零成功 = DoH 上游不可达（不是个别域名问题）：
              // 剩余域名不再陪跑，封 3 分钟。阈值取 6（>WORKERS，覆盖首组并发）
              // 足以区分「上游死」与「个别域名 NXDOMAIN」。
              if (!anySuccess && consecutiveFailures >= 6) {
                abortedUpstream = true;
                DoHResolver.dohDownUntil = Date.now() + 180000;
                AppLogger.warn(TAG, 'DoH upstream unreachable ('
                  + `${consecutiveFailures} consecutive failures, 0 success); `
                  + 'skipping remaining domains for 3 minutes');
              }
            }
          }
        })());
      }
      await Promise.all(workers);
      if (Date.now() >= deadline || abortedUpstream) {
        break;
      }
      pending = remaining;
    }
    // 易变域名不进结果（加固③a）：本轮解析出的 IP 不供 hosts 写入
    const volatileDropped: string[] = [];
    for (const d of Object.keys(result)) {
      if (isVolatileDomain(d)) {
        volatileDropped.push(d);
      }
    }
    // DNS 劫持/污染特征（加固③b）：一批结果里多个不同域名解析到同一 IP
    // （真机 hosts 出现过多入口域名同 IP 的可疑 pin）。命中时这批不入 pin
    // 不写 hosts（resolveANoCache 已写入缓存/入队的条目一并删除），域名留给内核运行时解析。
    const byIp = new Map<string, string[]>();
    for (const d of Object.keys(result)) {
      const ip = result[d];
      const list = byIp.get(ip);
      if (list === undefined) {
        byIp.set(ip, [d]);
      } else {
        list.push(d);
      }
    }
    const collisionDropped: string[] = [];
    for (const ip of Array.from(byIp.keys())) {
      const list = byIp.get(ip) ?? [];
      if (list.length < 2) {
        continue;
      }
      for (const d of list) {
        collisionDropped.push(d);
        DoHResolver.cache.delete(d);
        DoHResolver.staleQueue.delete(d);
      }
      AppLogger.warn(TAG, `doh hijack suspicion: ${list.length} domains -> ${ip}, pins dropped`);
    }
    DoHResolver.lastReport = report;
    if (volatileDropped.length > 0 || collisionDropped.length > 0) {
      const filtered: Record<string, string> = {};
      for (const d of Object.keys(result)) {
        if (!isVolatileDomain(d) && !collisionDropped.includes(d)) {
          filtered[d] = result[d];
        }
      }
      return filtered;
    }
    return result;
  }

  /** 在编排器允许的预连接窗口调用；失败/未处理项留队，成功查询才移除。 */
  static async refreshStale(budgetMs: number = 20000): Promise<number> {
    await DoHResolver.ensureLoaded();
    if (DoHResolver.refreshing !== null) {
      return DoHResolver.refreshing;
    }
    const task = DoHResolver.refreshQueued(budgetMs);
    DoHResolver.refreshing = task;
    try {
      return await task;
    } finally {
      DoHResolver.refreshing = null;
    }
  }

  private static async refreshQueued(budgetMs: number): Promise<number> {
    // 即使没有 resolveMany，也要发现长驻进程中新过期的条目。
    const keys: string[] = Array.from(DoHResolver.cache.keys());
    for (const domain of keys) {
      DoHResolver.cachedIp(domain);
    }
    const todo: string[] = Array.from(DoHResolver.staleQueue);
    const deadline = Date.now() + Math.max(0, budgetMs);
    let idx = 0;
    let updated = 0;
    const workers: Promise<void>[] = [];
    for (let w = 0; w < 4; w++) {
      workers.push((async (): Promise<void> => {
        while (Date.now() < deadline && idx < todo.length) {
          const d = todo[idx++];
          if ((await DoHResolver.resolveANoCache(d, deadline)).length > 0
            && DoHResolver.cachedIp(d).length > 0) {
            // 只算真正被 pin 住的：短 TTL 记录刷新后不 pin，等于交给内核解析，
            // 不要把它算成「已刷新」，否则调用方会误以为 pin 还在。
            updated++;
          }
        }
      })());
    }
    await Promise.all(workers);
    return updated;
  }

  private static sortByPriority(list: string[], priority: Set<string>): string[] {
    const head: string[] = [];
    const tail: string[] = [];
    for (const d of list) {
      if (priority.has(d)) {
        head.push(d);
      } else {
        tail.push(d);
      }
    }
    return head.concat(tail);
  }

  static async resolveA(domain: string): Promise<string> {
    await DoHResolver.ensureLoaded();
    const d = domain.toLowerCase();
    const cached = DoHResolver.cachedIp(d);
    return cached.length > 0 ? cached : DoHResolver.resolveANoCache(d, Date.now() + 10000);
  }

  private static async resolveANoCache(domain: string, deadline: number): Promise<string> {
    for (const ep of ENDPOINTS) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) {
        break;
      }
      const req = http.createHttp();
      // SDK 的连接/读取 timeout 不是共同截止时间，额外定时销毁覆盖完整请求预算。
      const deadlineTimer = setTimeout((): void => { req.destroy(); }, remaining);
      try {
        const resp = await req.request(ep + '?name=' + encodeURIComponent(domain) + '&type=A', {
          method: http.RequestMethod.GET,
          header: { 'Accept': 'application/dns-json', 'User-Agent': 'TunBox' } as Record<string, string>,
          connectTimeout: Math.min(2500, remaining),
          readTimeout: Math.min(2500, remaining),
          expectDataType: http.HttpDataType.STRING,
          usingCache: false
        } as http.HttpRequestOptions);
        if (Date.now() >= deadline || resp.responseCode !== 200 || typeof resp.result !== 'string') {
          continue;
        }
        const parsed = JSON.parse(resp.result as string) as DoHResponse;
        if (parsed.Status !== 0 || !Array.isArray(parsed.Answer)) {
          continue;
        }
        for (const a of parsed.Answer) {
          if (a.type === 1 && typeof a.data === 'string' && DoHResolver.looksLikeIPv4(a.data)) {
            // TTL 是 pin 的**唯一**寿命依据（见文件头 2026-10-18 修正）。
            // 缺 TTL（非标 DoH 端点）按 0 处理 → 不 pin，交给内核现解析。
            const ttlSec = typeof a.TTL === 'number' ? a.TTL : Number(a.TTL);
            const ttlMs = Number.isFinite(ttlSec) && ttlSec > 0 ? ttlSec * 1000 : 0;
            DoHResolver.cachePut(domain, a.data, ttlMs, true, Date.now());
            return a.data;
          }
        }
      } catch (e) {
        AppLogger.info(TAG, `DoH query failed: ${AppLogger.errText(e)}`);
      } finally {
        clearTimeout(deadlineTimer);
        req.destroy();
      }
    }
    return '';
  }

  private static looksLikeIPv4(s: string): boolean {
    const parts = s.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (const p of parts) {
      const n = Number(p);
      if (!Number.isInteger(n) || n < 0 || n > 255 || `${n}` !== p) {
        return false;
      }
    }
    return true;
  }

  /**
   * 落一条 pin（**只有 TTL 足够长的记录才会真的落**）。
   * @param ttlMs DoH 应答 TTL（毫秒）；0/过短 = 记录会轮换 → 不 pin。
   */
  private static cachePut(domain: string, ip: string, ttlMs: number, schedule: boolean,
    resolvedAt: number): void {
    // 易变域名不 pin（加固③a）：不进内存缓存也不持久化，域名留给内核运行时解析
    if (isVolatileDomain(domain)) {
      return;
    }
    // 短 TTL 记录不 pin（2026-10-18 修正）：hosts 是永久覆盖，钉住会轮换的 IP 会让
    // 整条订阅在 IP 换绑后全部拨号超时。留一条「别再问」的记号，之后交给内核解析。
    if (!(ttlMs >= MIN_PIN_TTL_MS)) {
      DoHResolver.cache.delete(domain);
      DoHResolver.staleQueue.delete(domain);
      DoHResolver.unpinnable.set(domain, Date.now() + UNPINNABLE_HOLD_MS);
      return;
    }
    DoHResolver.unpinnable.delete(domain);
    const lifetimeMs = Math.min(ttlMs, PIN_MAX_AGE_MS);
    DoHResolver.cache.delete(domain);
    DoHResolver.cache.set(domain, new DoHPin(ip, resolvedAt, lifetimeMs));
    if (Date.now() - resolvedAt >= lifetimeMs / 2) {
      DoHResolver.staleQueue.add(domain);
    } else {
      DoHResolver.staleQueue.delete(domain);
    }
    while (DoHResolver.cache.size > DoHResolver.CACHE_MAX_ENTRIES) {
      const oldest = DoHResolver.cache.keys().next();
      if (oldest.done) {
        break;
      }
      DoHResolver.cache.delete(oldest.value);
      DoHResolver.staleQueue.delete(oldest.value);
    }
    if (schedule) {
      DoHResolver.schedulePersist();
    }
  }

  private static schedulePersist(): void {
    if (DoHResolver.persistTimer >= 0) {
      return;
    }
    DoHResolver.persistTimer = setTimeout((): void => {
      DoHResolver.persistTimer = -1;
      const out: Record<string, string> = {};
      const now = Date.now();
      for (const domain of DoHResolver.cache.keys()) {
        const pin = DoHResolver.cache.get(domain);
        if (pin !== undefined && pin.lifetimeMs >= MIN_PIN_TTL_MS
          && now >= pin.resolvedAt && now - pin.resolvedAt < pin.lifetimeMs) {
          // 三段式：ip|resolvedAt|lifetimeMs —— 寿命是 pin 自己的契约，读回来必须能重建
          out[domain] = `${pin.ip}|${pin.resolvedAt}|${pin.lifetimeMs}`;
        }
      }
      SettingsService.saveDohPins(out).catch((e: Error): void => {
        AppLogger.warn(TAG, `doh pin persist failed: ${AppLogger.errText(e)}`);
      });
    }, PERSIST_DEBOUNCE_MS);
  }
}
