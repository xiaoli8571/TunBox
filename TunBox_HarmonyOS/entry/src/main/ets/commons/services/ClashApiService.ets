/**
 * Clash RESTful API 客户端
 * 移植自 upstream: packages/tunbox_shared/lib/services/clash_service_base.dart
 *                clash_service_latency_support.dart
 *                clash_service_data_plane_support.dart
 * 对应 Android 端 MihomoApiWaiter / MihomoApiHealthProbe / MihomoProxySelection 的职责。
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { AppLogger } from '../utils/AppLogger';
import { LatencyPolicy } from './LatencyState';
import {
  LatencyProbe as CoreLatencyProbe,
  LatencyKernelEndpoint,
  LatencyHttpReply,
  LatencyHttpTransport
} from '../latency/LatencyProbe';
import { LatencyDnsVerdict } from '../latency/LatencyDnsVerdict';
// 失败分类表与结果类型住在**零 import** 的 LatencyKinds.ets（单一真源；
// services 侧只值依赖零 import 模块 ⇒ Node 行为闸门的扁平暂存沙箱能跑）。
import { LatencyProbeKind, LatencyProbeResult } from '../latency/LatencyKinds';

const TAG = 'ClashApiService';

export interface LatencyResult {
  nodeName: string;
  delayMs: number; // -1 = 超时/失败
}

export interface TrafficSnapshot {
  uploadBytes: number;
  downloadBytes: number;
  uploadSpeed: number;
  downloadSpeed: number;
}

/**
 * 单条活动连接（GET /connections 的 connections[] 条目，实时连接面板数据源）。
 * 字段刻意收敛为 UI 展示所需的最小集合；up/down 是该连接的累计字节（非速率）。
 */
export class ConnectionEntry {
  /** 内核侧连接唯一 ID（DELETE /connections/{id} 用） */
  id: string = '';
  /** 上行累计字节 */
  upload: number = 0;
  /** 下行累计字节 */
  download: number = 0;
  /** 建立时间（epoch ms；内核缺 start 字段时为 0） */
  startMs: number = 0;
  /** 规则链：如 ["DOMAIN-SUFFIX,google.com,PROXY","PROXY"] */
  chains: string[] = [];
  /** 出站链里的最终出口节点名（与已知节点求交取末个命中；不保证存在） */
  outbound: string = '';
  /** 目标 host:port（metadata.host 优先，缺省退 destinationIP） */
  host: string = '';
  /** 目标端口 */
  port: number = 0;
  /** 传输层：tcp / udp */
  network: string = '';
  /** 命中的规则原文（chains 首项），空表示无规则（如 DIRECT 直连） */
  rule: string = '';
}


/**
 * 测速传输层适配：把 ClashApiService 的**在途登记 / 取消**语义接到
 * 测速内核的「一次 GET、给一个回复」抽象上。
 *
 * 为什么不直接用内核自带的 `ArkHttpTransport`：
 * 那个实现不登记在途表 => 用户取消 / 新批次抢占时，客户端侧的 http 句柄
 * 不会被 destroy => 旧批次继续占着 127.0.0.1 的连接（真机：同 host 连接池 ≈ 8，
 * 旧批次不放手 => 新批次排队 => 假超时）。这里保留 `inflight` 登记语义。
 */
class ClashApiDelayTransport implements LatencyHttpTransport {
  private readonly owner: ClashApiService;

  constructor(owner: ClashApiService) {
    this.owner = owner;
  }

  async get(url: string, headers: Record<string, string>, timeoutMs: number): Promise<LatencyHttpReply> {
    const reply = new LatencyHttpReply();
    const req = http.createHttp();
    this.owner.trackInflight(req);
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        usingCache: false
      });
      reply.responseCode = resp.responseCode;
      if (typeof resp.result === 'string') {
        reply.body = resp.result as string;
      } else if (resp.result instanceof ArrayBuffer) {
        reply.body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
      }
      return reply;
    } finally {
      this.owner.untrackInflight(req);
      req.destroy();
    }
  }
}


/**
 * 组测速（`GET /group/{name}/delay`）的结构化结果。
 *
 * 为什么需要它（根因 T5，方案 C10）：内核在**全部成员失败**时返回 **504**
 * （body `get delay: all proxies timeout`）—— 那是「节点全不通、**通道正常**」。
 * 旧接口对**任何非 200 一律 return null**，调用方只能判定「内核不可用」，
 * 于是「所有节点都不通」与「内核挂了」在 UI 上完全无法区分
 * （用户报障原文：要么测速全部失败，要么启动代理失败）。
 *
 * ## 对外契约（供 UI 侧接入）
 *
 * | 情况 | ok | allTimedOut | failKind | 说明 |
 * |---|---|---|---|---|
 * | 200 且有成功节点 | true | false | '' | `delays` 只含 delay>0 的成员 |
 * | 200 但无一成员成功 | true | false | '' | `delays` 为空 = 本轮没测到任何节点 |
 * | **504**（全部成员超时） | **false** | **true** | TIMEOUT | **通道正常**，只是节点全不通 |
 * | 401 / 403 | false | false | CORE_NOT_READY | secret 错配 = 通道不可用 |
 * | 404 | false | false | SWITCH_FAILED | 内核里没有这个组 |
 * | 503 | false | false | TIMEOUT | 单节点拨号失败语义 |
 * | 其它非 200 | false | false | NETWORK_UNREACHABLE | |
 * | 传输异常 | false | false | CORE_NOT_READY | 本机没拿到 HTTP 响应 = 通道不可用 |
 *
 * ⚠ **本方法不抛异常**：所有失败都用返回值表达（`failKind` + `detail`）。
 */
export class GroupLatencyResult {
  /** 是否拿到**可用**响应（= 有成功节点）。注意：504 是「不可用但通道正常」→ false。 */
  ok: boolean = false;
  /** 成功节点的延迟（只含 delay > 0 的成员） */
  delays: Map<string, number> = new Map<string, number>();
  /** HTTP 状态码（0 = 传输层失败，没有拿到响应） */
  httpCode: number = 0;
  /** 失败分类（LatencyProbeKind.*；空串 = 无失败） */
  failKind: string = '';
  /** 脱敏诊断信息（绝不包含 secret / 订阅地址 / 节点口令） */
  detail: string = '';
  /** 504 = 全部成员超时（**通道正常**，节点全不通） */
  allTimedOut: boolean = false;
}

/**
 * controller 真实可用性探测结果。
 *
 * 「内核就绪」必须是四者一致：进程存活 + endpoint 端口正确 + secret 一致 +
 * 一次真实 GET /version 返回 200。仅凭进程内状态机的 ACTIVE 布尔量会把
 * 「内核已死 / 被别的 secret 覆盖」误判为就绪。
 */
export class ControllerProbe {
  /** 被探测的 endpoint 端口 */
  port: number = 0;
  /** 当前 endpoint 是否配置了 secret */
  secretConfigured: boolean = false;
  /** 是否收到 HTTP 响应（进程存活） */
  reachable: boolean = false;
  /** HTTP 状态码（0 = 无响应） */
  httpCode: number = 0;
  /** secret 是否被内核接受（200 才算） */
  secretAccepted: boolean = false;
  /** 脱敏诊断信息 */
  detail: string = '';
}

export class ClashApiService {
  private apiPort: number = 9090;
  private secret: string = '';

  /**
   * 在途延迟测试请求集合。
   * 批量测速会同时挂起 N 路 /proxies/{name}/delay；页面退出或新批次开始时若只靠
   * 逻辑标志位，内核侧这些出站连接仍会跑到各自超时（最长 2.5~5s）继续占用通道，
   * 表现为「旧批次和新批次抢通道、整体变慢」。cancelInflight() 直接 destroy 掉
   * 在途请求，通道立刻释放。
   */
  private inflight: Set<http.HttpRequest> = new Set<http.HttpRequest>();

  /** 登记一个在途测速请求（取消时统一 destroy） */
  trackInflight(req: http.HttpRequest): void {
    this.inflight.add(req);
  }

  /** 注销一个已结束/已销毁的测速请求 */
  untrackInflight(req: http.HttpRequest): void {
    this.inflight.delete(req);
  }

  /** 中断所有在途延迟测试请求，返回被中断的数量（其余业务请求不受影响）。 */
  cancelInflight(): number {
    const n = this.inflight.size;
    for (const req of this.inflight) {
      try {
        req.destroy();
      } catch (e) {
        // 已结束的请求 destroy 抛错属正常
      }
    }
    this.inflight.clear();
    return n;
  }

  setEndpoint(port: number, secret: string): void {
    this.apiPort = port;
    this.secret = secret;
  }

  /**
   * 当前 endpoint 端口。测速通道判定需要它来验证「端口 + secret 一致」，
   * 不能只看进程内状态机的 ACTIVE。
   */
  currentPort(): number {
    return this.apiPort;
  }

  /** 当前 endpoint secret（仅用于一致性比对，不得写入日志） */
  currentSecret(): string {
    return this.secret;
  }

  /** 当前 endpoint 是否与给定 secret 完全一致（测速内核通道一致性判据） */
  hasSecret(secret: string): boolean {
    return secret.length > 0 && this.secret === secret;
  }

  private baseUrl(): string {
    return `http://127.0.0.1:${this.apiPort}`;
  }

  /** 内核 REST 基址（供 FlClash 等价测速引擎直连，`FlclashDelay` 需要裸 baseUrl）。 */
  endpointBase(): string {
    return this.baseUrl();
  }

  /** controller secret（可能为空串 = 无鉴权）。 */
  endpointSecret(): string {
    return this.secret;
  }

  private authHeader(): Record<string, string> {
    const h: Record<string, string> = {};
    if (this.secret.length > 0) {
      h['Authorization'] = `Bearer ${this.secret}`;
    }
    return h;
  }

  private errText(e: Object): string {
    return AppLogger.errText(e);
  }

  /** 等待 API 就绪（对应 MihomoApiWaiter），超时返回 false */
  async waitReady(timeoutMs: number, intervalMs: number = 150): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (await this.healthProbe()) {
        return true;
      }
      await ClashApiService.sleep(intervalMs);
    }
    return false;
  }

  /** 健康探测（对应 MihomoApiHealthProbe）：GET /version */
  async healthProbe(): Promise<boolean> {
    const req = http.createHttp();
    try {
      const resp = await req.request(`${this.baseUrl()}/version`, {
        method: http.RequestMethod.GET,
        header: this.authHeader(),
        connectTimeout: 1500,
        readTimeout: 1500,
        usingCache: false
      });
      return resp.responseCode === 200;
    } catch (e) {
      return false;
    } finally {
      req.destroy();
    }
  }

  /** 切换选中节点。必须同时下发到 PROXY 组和 GLOBAL 组:
   *  mihomo 在 global(全局)模式下忽略具名 PROXY 组, 走隐式 GLOBAL 组; 若不设置
   *  GLOBAL, 它默认选 DIRECT → 全局模式下所有流量直连、被国内 DNS 污染打不开。
   *  (真机实证: 全局模式 GLOBAL now=DIRECT, youtube dial 假 IP 超时。)
   *
   *  2026-10-19 稳定性：返回值改为「PROXY 组钉选成功」——旧实现是
   *  `okProxy || okGlobal`，只要 GLOBAL 成功就算成功，于是规则模式下 PROXY 组
   *  没钉上也会返回 true，调用方以为选点已生效（真机表现为「连上了但走的是旧节点」）。
   *  GLOBAL 是**尽力而为**（部分配置不声明 GLOBAL 组，PUT 会 404，属正常）。
   *  失败时重试一次：内核刚起时首个 PUT 偶发 400/超时，重试即可收敛。
   */
  /** Find a member chain, including intermediate groups, with cycle protection. */
  private selectionPath(table: Record<string, Object>, group: string, target: string,
    visited: string[]): string[] {
    if (visited.includes(group) || visited.length > 32) { return []; }
    const entry = table[group] as Record<string, Object>;
    if (entry === undefined || entry === null || !Array.isArray(entry['all'])) { return []; }
    if (!['Selector', 'URLTest', 'Fallback', 'Smart'].includes(entry['type'] as string)) { return []; }
    const members = entry['all'] as string[];
    if (members.includes(target)) { return [group, target]; }
    const next = visited.concat([group]);
    for (const member of members) {
      const path = this.selectionPath(table, member, target, next);
      if (path.length > 0) { return [group].concat(path); }
    }
    return [];
  }

  async selectNode(nodeName: string): Promise<boolean> {
    // 「失败时重试一次」（本函数头注释承诺但旧实现缺失）：内核刚起时首个 PUT 偶发
    // 400/超时是已知瞬态，connect 恰恰在内核刚起时调用本函数 —— 不重试会把瞬态
    // 当永久失败。重试前给 300ms 让内核 controller 收敛（立即重试大概率还是 400）；
    // 第二次失败才如实返回 false（调用方 fail-fast，见 b9.no-fake-success 契约）。
    if (await this.selectNodeOnce(nodeName)) {
      return true;
    }
    await new Promise<void>((resolve) => setTimeout(() => resolve(), 300));
    return this.selectNodeOnce(nodeName);
  }

  private async selectNodeOnce(nodeName: string): Promise<boolean> {
    const json = await this.proxiesJson();
    if (json === null) { return false; }
    let table: Record<string, Object>;
    try {
      const parsed = JSON.parse(json) as Record<string, Object>;
      table = parsed['proxies'] as Record<string, Object>;
      if (table === undefined || table === null || table[nodeName] === undefined) { return false; }
    } catch (e) { return false; }
    const expected: Map<string, string> = new Map<string, string>();
    for (const group of Object.keys(table)) {
      const path = this.selectionPath(table, group, nodeName, []);
      // Pin leaves before their parents. A successful unrelated group or GLOBAL
      // must never hide a failure in a rule-facing selector.
      for (let i = path.length - 2; i >= 0; i--) {
        expected.set(path[i], path[i + 1]);
      }
    }
    let nonGlobal = false;
    for (const pair of expected) {
      const group = pair[0];
      const member = pair[1];
      const ok = await this.selectInGroup(group, member);
      if (!ok && group !== 'GLOBAL') { return false; }
      if (ok && group !== 'GLOBAL') { nonGlobal = true; }
    }
    const afterJson = await this.proxiesJson();
    if (afterJson === null) { return false; }
    try {
      const parsed = JSON.parse(afterJson) as Record<string, Object>;
      const after = parsed['proxies'] as Record<string, Object>;
      for (const pair of expected) {
        if (pair[0] === 'GLOBAL' && nonGlobal) { continue; }
        const entry = after[pair[0]] as Record<string, Object>;
        if (entry === undefined || entry['now'] !== pair[1]) { return false; }
      }
    } catch (e) { return false; }
    return expected.size > 0;
  }

  /**
   * 从 `/proxies` 里找出**包含该节点**的组名，顺序：PROXY → 非 GLOBAL → GLOBAL。
   * 返回空数组表示拿不到快照（调用方退回旧路径）。
   */
  private async groupsContaining(nodeName: string): Promise<string[]> {
    const json = await this.proxiesJson();
    if (json === null) {
      return [];
    }
    const out: string[] = [];
    try {
      const parsed = JSON.parse(json) as Record<string, Object>;
      const proxies = parsed['proxies'];
      if (proxies === undefined || proxies === null) {
        return [];
      }
      const table = proxies as Record<string, Object>;
      const head: string[] = [];
      const tail: string[] = [];
      const names = Object.keys(table);
      for (const name of names) {
        const entry = table[name] as Record<string, Object>;
        if (entry === null || entry === undefined) {
          continue;
        }
        const all = entry['all'];
        if (!Array.isArray(all)) {
          continue;
        }
        const members = all as Object[];
        let hit = false;
        for (const member of members) {
          if (typeof member === 'string' && member === nodeName) {
            hit = true;
            break;
          }
        }
        if (!hit) {
          continue;
        }
        if (name === 'PROXY') {
          head.push(name);
        } else if (name === 'GLOBAL') {
          tail.push(name);
        } else {
          head.push(name);
        }
      }
      for (const name of head) {
        out.push(name);
      }
      for (const name of tail) {
        out.push(name);
      }
    } catch (e) {
      return [];
    }
    return out;
  }

  /**
   * 读回某代理组当前选中的成员（GET /proxies/{group} 的 `now` 字段）。
   * 返回 null 表示内核不可达/组不存在；空串表示组存在但没有选中项。
   * 用途：连接后确认「选点真的生效了」，而不是只信 PUT 的 204。
   *
   * 超时刻意收紧到 1500/2000（回环请求正常 <10ms）：这是连接主路径上的
   * **观测**调用，绝不允许在 controller 过载时把连接额外拖慢 3s。
   */
  async groupSelection(group: string): Promise<string | null> {
    const req = http.createHttp();
    try {
      const resp = await req.request(`${this.baseUrl()}/proxies/${encodeURIComponent(group)}`, {
        method: http.RequestMethod.GET,
        header: this.authHeader(),
        connectTimeout: 1500,
        readTimeout: 2000,
        usingCache: false
      });
      if (resp.responseCode !== 200 || typeof resp.result !== 'string') {
        return null;
      }
      const parsed = JSON.parse(resp.result as string) as Record<string, Object>;
      const now = parsed['now'];
      return typeof now === 'string' ? now as string : '';
    } catch (e) {
      return null;
    } finally {
      req.destroy();
    }
  }

  /**
   * 原始 `GET /proxies` 响应（FlClash `core.getProxiesGroups` 的对等数据源）。
   *
   * FlClash 的节点/分组一律来自内核，App 不持有清单；TunBox 走同一份内核数据源，
   * 由 `commons/flclash/CoreCatalog` 解析成组/节点模型。
   *
   * 返回 null = 通道不可用（连接被拒 / 401 / 传输失败），调用方按「目录不可用」处理，
   * 绝不能当成「没有节点」。
   */
  async proxiesJson(): Promise<string | null> {
    const req = http.createHttp();
    this.inflight.add(req);
    try {
      const resp = await req.request(`${this.baseUrl()}/proxies`, {
        method: http.RequestMethod.GET,
        header: this.authHeader(),
        connectTimeout: 2500,
        readTimeout: 6000,
        usingCache: false
      });
      if (resp.responseCode !== 200) {
        return null;
      }
      if (typeof resp.result === 'string') {
        return resp.result as string;
      }
      if (resp.result instanceof ArrayBuffer) {
        return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
      }
      return null;
    } catch (e) {
      AppLogger.warn(TAG, `proxiesJson failed: ${this.errText(e)}`);
      return null;
    } finally {
      this.inflight.delete(req);
      req.destroy();
    }
  }

  /** 在指定组里选中节点（FlClash changeProxy 的对等实现，PUT /proxies/{group}）。 */
  async selectProxyInGroup(group: string, nodeName: string): Promise<boolean> {
    return await this.selectInGroup(group, nodeName);
  }

  /**
   * 拉取内核里**真正可测**的节点名列表（延迟测试重做的核心依赖）。
   *
   * 为什么要从内核取而不是用本地订阅列表：
   *  - 内核的代理表才是权威的（provider 节点、被过滤掉的非法节点、当前生效的配置）；
   *  - 已连接时隧道的 controller 就带着全部真实节点，直接复用即可，**不需要第二个内核**。
   *
   * 过滤规则（缺一不可）：
   *  - 去掉内建项（DIRECT / REJECT / GLOBAL / COMPATIBLE / PASS / PASS-RULE …）；
   *  - 去掉**组对象**（Selector / URLTest / Fallback / LoadBalance / Relay）——
   *    实测本项目 `PROXY.all` 里混着 14 个组条目；把组当节点测会拿到"组当前选中
   *    那个节点"的延迟，结果张冠李戴；
   *  - 去掉没有 type 的信息类条目。
   *
   * 返回 null 表示内核不可用（连接被拒 / 401 / 传输失败）——**调用方必须把它当作
   * "通道不可用"处理，绝不能把 null 当成"全部超时"**。
   */
  async testableProxyNames(): Promise<string[] | null> {
    const req = http.createHttp();
    try {
      const resp = await req.request(`${this.baseUrl()}/proxies`, {
        method: http.RequestMethod.GET,
        header: this.authHeader(),
        connectTimeout: 2500,
        readTimeout: 6000,
        usingCache: false
      });
      if (resp.responseCode !== 200) {
        AppLogger.warn(TAG, `testableProxyNames non-200: code=${resp.responseCode}`);
        return null;
      }
      const body = typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
      const root = JSON.parse(body) as Record<string, Object>;
      const proxies = root['proxies'];
      if (proxies === undefined || proxies === null) {
        return null;
      }
      const table = proxies as Record<string, Object>;
      const out: string[] = [];
      for (const name of Object.keys(table)) {
        const entry = table[name] as Record<string, Object>;
        const typeRaw = entry['type'];
        const type = typeRaw === undefined ? '' : String(typeRaw);
        if (type.length === 0) {
          continue;
        }
        if (LatencyPolicy.isBuiltinNode(name) || !LatencyPolicy.isTestableType(type)) {
          continue;
        }
        out.push(name);
      }
      AppLogger.info(TAG, `testableProxyNames: ${out.length} testable of ${Object.keys(table).length} entries`);
      return out;
    } catch (e) {
      AppLogger.warn(TAG, `testableProxyNames failed: ${this.errText(e)}`);
      return null;
    } finally {
      req.destroy();
    }
  }

  /**
   * GET /proxies → 内核代理表里的**全部**名字（含组名）。
   *
   * 与 testableProxyNames 的区别：那个过滤掉了内置节点与不可测类型，只适合
   * 「哪些节点能测」；这里要回答的是另一个问题 ——
   * **「这个节点到底在不在内核里」**。
   *
   * 组测（GET /group/PROXY/delay）只返回成功的节点，失败的节点**没有状态码**，
   * 内核不告诉你是 404（节点没进配置）还是 504（真超时）。但代理表能回答：
   * 名字不在表里 = 节点压根没被写进内核配置（订阅解析/配置生成阶段丢了它）。
   * 真机 2026-10-19：36 个 anytls 因解析丢凭据被丢弃 → 内核 404 → 「测全部」
   * 全红，用户以为节点坏了（节点实际可用）。
   *
   * @returns null = 内核不可用（调用方必须当作「通道不可用」，不是「没有节点」）
   */
  async proxyTableNames(): Promise<string[] | null> {
    const req = http.createHttp();
    try {
      const resp = await req.request(`${this.baseUrl()}/proxies`, {
        method: http.RequestMethod.GET,
        header: this.authHeader(),
        connectTimeout: 2500,
        readTimeout: 6000,
        usingCache: false
      });
      if (resp.responseCode !== 200) {
        AppLogger.warn(TAG, `proxyTableNames non-200: code=${resp.responseCode}`);
        return null;
      }
      const body = typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
      const root = JSON.parse(body) as Record<string, Object>;
      const proxies = root['proxies'];
      if (proxies === undefined || proxies === null) {
        return null;
      }
      return Object.keys(proxies as Record<string, Object>);
    } catch (e) {
      AppLogger.warn(TAG, `proxyTableNames failed: ${this.errText(e)}`);
      return null;
    } finally {
      req.destroy();
    }
  }

  /**
   * GET /connections → 经过 `groupName` 的连接**实际使用**的节点名（去重）。
   *
   * 为什么必须看 /connections 而不是 /proxies：内核 `Smart.Now()` 返回的是
   * `s.selected`，只在用户**手动固定**时非空；LightGBM 的按连接选择**不会**写回
   * `now`（见 fork `adapter/outboundgroup/smart.go` 的 `Now()`/`MarshalJSON`）。
   * 所以组详情接口根本反映不出自动选点结果，只有每条连接的 `chains` 才是事实。
   *
   * 不假设 chains 顺序：内核里 `AppendToChains` 由各组自己调用
   * （`smart.go` 只 append 自己，内层节点由适配器 append），实际顺序随实现变化。
   * 这里改成「与已知节点名求交、取最后一个命中的」，与顺序无关。
   *
   * @param knownNames 订阅里的真实节点名（用于识别 chain 里哪个是出口节点）
   * @returns null = 内核不可用（调用方必须当作"通道不可用"，不是"没有节点"）
   */
  async smartActiveNodes(groupName: string, knownNames: string[]): Promise<string[] | null> {
    const req = http.createHttp();
    try {
      const resp = await req.request(`${this.baseUrl()}/connections`, {
        method: http.RequestMethod.GET,
        header: this.authHeader(),
        connectTimeout: 2500,
        readTimeout: 6000,
        usingCache: false
      });
      if (resp.responseCode !== 200) {
        return null;
      }
      let body: string = '';
      if (typeof resp.result === 'string') {
        body = resp.result as string;
      } else if (resp.result instanceof ArrayBuffer) {
        body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
      }
      if (body.length === 0) {
        return null;
      }
      const root = JSON.parse(body) as Record<string, Object>;
      const conns = root['connections'];
      if (conns === undefined || conns === null) {
        // 无活动连接时该字段可能缺失 —— 这是"当前没有流量"，不是通道故障
        return [];
      }
      const list = conns as Object[];
      const known: string[] = knownNames;
      const used: string[] = [];
      for (const item of list) {
        const conn = item as Record<string, Object>;
        const chainsRaw = conn['chains'];
        if (chainsRaw === undefined || chainsRaw === null) {
          continue;
        }
        const chains = chainsRaw as string[];
        let goesThroughGroup = false;
        for (const name of chains) {
          if (name === groupName) {
            goesThroughGroup = true;
            break;
          }
        }
        if (!goesThroughGroup) {
          continue;
        }
        // 取最后一个「已知真实节点名」作为出口节点；组名/DIRECT 等都不在 known 里，天然被排除
        let outbound = '';
        for (const name of chains) {
          if (known.includes(name)) {
            outbound = name;
          }
        }
        if (outbound.length > 0 && !used.includes(outbound)) {
          used.push(outbound);
        }
      }
      return used;
    } catch (e) {
      AppLogger.warn(TAG, `smartActiveNodes failed: ${this.errText(e)}`);
      return null;
    } finally {
      req.destroy();
    }
  }

  /** 在指定代理组选择节点: PUT /proxies/{group} {name} */
  private async selectInGroup(group: string, nodeName: string): Promise<boolean> {    const req = http.createHttp();
    try {
      const headers: Record<string, string> = this.authHeader();
      headers['Content-Type'] = 'application/json';
      const payload: Record<string, string> = {};
      payload['name'] = nodeName;
      const resp = await req.request(`${this.baseUrl()}/proxies/${encodeURIComponent(group)}`, {
        method: http.RequestMethod.PUT,
        header: headers,
        extraData: JSON.stringify(payload),
        connectTimeout: 3000,
        readTimeout: 3000,
        usingCache: false
      });
      return resp.responseCode === 204 || resp.responseCode === 200;
    } catch (e) {
      AppLogger.error(TAG, `selectInGroup(${group}) failed: ${this.errText(e)}`);
      return false;
    } finally {
      req.destroy();
    }
  }

  /** PUT 加载配置文件；PATCH 修改运行参数。两者在 Mihomo 中不是同一条路由。 */
  private async putConfigs(payload: Record<string, string>, op: string,
    patch: boolean = false): Promise<boolean> {
    const req = http.createHttp();
    try {
      const headers: Record<string, string> = this.authHeader();
      headers['Content-Type'] = 'application/json';
      const resp = await req.request(`${this.baseUrl()}/configs${patch ? '' : '?force=true'}`, {
        method: patch ? http.RequestMethod.PATCH : http.RequestMethod.PUT,
        header: headers,
        extraData: JSON.stringify(payload),
        connectTimeout: 3000,
        readTimeout: 3000,
        usingCache: false
      });
      return resp.responseCode === 204 || resp.responseCode === 200;
    } catch (e) {
      AppLogger.error(TAG, `${op} failed: ${AppLogger.errText(e)}`);
      return false;
    } finally {
      req.destroy();
    }
  }

  /** 只修改模式，不能用 PUT 重新加载文件并重置策略组。 */
  async setMode(mode: string): Promise<boolean> {
    const payload: Record<string, string> = {};
    // mihomo 原生支持 mode: rule / global / direct（2026-10-17 用户要求主页提供直连按钮）
    payload['mode'] = (mode === 'global' || mode === 'direct') ? mode : 'rule';
    return this.putConfigs(payload, 'setMode', true);
  }

  /**
   * 热重载整份配置文件（规则/DNS/代理组等）：PUT /configs {"path": ...} ?force=true。
   * 内核在同一进程内重建 DNS/Router/Rules 并保持 TUN 与连接，无需 UI 侧重建 VPN。
   * 失败不代表应重建 VPN；调用方保留当前会话并报告未应用或未确认。
   */
  async reloadFromPath(configPath: string): Promise<boolean> {
    const payload: Record<string, string> = {};
    payload['path'] = configPath;
    return this.putConfigs(payload, 'reloadFromPath');
  }

  /**
   * controller 真实可用性探测：GET /version（带当前 secret）。
   * 返回 reachable（进程存活）+ secretAccepted（HTTP 200 = secret 一致）。
   * 这是「测速内核就绪」的唯一权威判据的一部分（配合端口 + secret 一致性比对）。
   */
  async probeController(timeoutMs: number = 1500): Promise<ControllerProbe> {
    const out = new ControllerProbe();
    out.port = this.apiPort;
    out.secretConfigured = this.secret.length > 0;
    const req = http.createHttp();
    try {
      const resp = await req.request(`${this.baseUrl()}/version`, {
        method: http.RequestMethod.GET,
        header: this.authHeader(),
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        usingCache: false
      });
      out.reachable = true;
      out.httpCode = resp.responseCode;
      out.secretAccepted = resp.responseCode === 200;
      out.detail = `http=${resp.responseCode}`;
    } catch (e) {
      out.reachable = false;
      out.httpCode = 0;
      out.secretAccepted = false;
      out.detail = this.errText(e);
    } finally {
      req.destroy();
    }
    return out;
  }


  /**
   * 延迟测试（详细版，对应 clash_service_latency_support）：
   * GET /proxies/{name}/delay
   *
   * 超时语义：timeoutMs 是**这一次尝试（单个测试 URL）**的预算，原样作为
   * mihomo 的 timeout 参数下发；外层 HTTP 只加少量调度余量。调用方对多个
   * fallback URL 依次调用时，每个 URL 各拿一份独立预算，不再把单节点总预算
   * 按剩余次数切碎（旧实现组测每次只剩 250~500ms → 大面积假超时）。
   *
   * 失败分类随结果返回（LatencyProbeKind），调用方不得再统一折叠成「超时」。
   *
   * ⚠ `lanes` 的语义（2026-10-20 修正，方案 C8/C9）：它是**同时在途的 HTTP
   * 请求数**，不是 worker 数、也不是队列深度。公式 `ceil(lanes/8)` 只有在
   * lanes = 实际在途数时才成立。
   */
  async testLatencyDetailed(nodeName: string, testUrl: string,
    // 默认值只作兜底：真实调用（LatencyEngine → ClashApiService）一律显式传同一真源，
    // 免得日后有人省略该参数时得到「单节点 0.3 秒 / 引擎 5 秒」两把尺子。
    timeoutMs: number = LatencyPolicy.DEFAULT_TIMEOUT_MS, lanes: number = 1,
    dns: LatencyDnsVerdict | null = null): Promise<LatencyProbeResult> {
    const out = new LatencyProbeResult();
    out.nodeName = nodeName;
    const endpoint = new LatencyKernelEndpoint();
    endpoint.baseUrl = this.baseUrl();
    endpoint.secret = this.secret;
    const transport = new ClashApiDelayTransport(this);
    // => 测速内核（commons/latency/LatencyProbe.ets）：**一次请求**语义 +
    //    单一失败分类表 + **完整失败响应体**进日志 + DNS 预检短路，
    //    全部只在一处实现（这条路径就是「唯一测速路径」）。
    //
    // WARN 外层超时预算也归内核常量区（LatencyProbeLimits.outerTimeoutMs = inner + 1200）：
    //    旧公式 `ceil(lanes/8) * timeoutMs + 1200` 只有在 lanes = 实际在途数时才成立，
    //    而在途数已由引擎的应用层闸门（LATENCY_INFLIGHT = 8）保证 => batchCount 恒为 1。
    //    `lanes` 保留只为兼容调用点（引擎传的是在途数），日志里留痕便于对照。
    const core = await CoreLatencyProbe.probeOne(nodeName, testUrl, endpoint, transport, timeoutMs, dns);
    out.httpCode = core.httpCode;
    out.failKind = core.failKind;
    out.detail = core.detail;
    out.isVerdict = core.isVerdict;
    out.bodyText = core.bodyText;
    out.elapsedMs = core.elapsedMs;
    out.delayMs = core.failKind === LatencyProbeKind.NONE ? core.delayMs : -1;
    if (core.failKind !== LatencyProbeKind.NONE) {
      AppLogger.warn(TAG, `latency probe result: node=${nodeName} kind=${out.failKind} `
        + `http=${out.httpCode} lanes=${lanes} inner=${timeoutMs}ms detail=${out.detail}`);
    }
    return out;
  }

  /**
   * **组测速（带失败分类）**：`GET /group/{name}/delay` —— 一次请求让内核
   * 对组内**全部节点并发测试**（Go goroutine，无客户端 http 栈的同 host 并发
   * 连接限制）。内核源码实证（mihomo-smart hub/route/groups.go）：
   *  - 传入的 url 参数**会被使用**（`group.URLTest(ctx, url, expected)`）；
   *  - ForceSet("") 只作用于非 Selector 组（PROXY 是 select 类型，用户固定选择
   *    不受影响）；
   *  - 返回 `map[节点名]延迟ms`——**成功的节点才有**，失败的（超时/拨号失败）
   *    不在 map 里，由调用方按「超时」落库（内核源码 URLTest：err!=nil 跳过）。
   *
   * ⚠ **为什么必须有分类**（根因 T5，方案 C10）：内核在**全部成员失败**时返回
   * **504**（body `get delay: all proxies timeout`）—— 那是「节点全不通、
   * **通道正常**」。旧实现对任何非 200 一律 return null → 调用方判定
   * 「内核不可用」→ 用户看到的「所有节点都不通」与「内核挂了」无法区分。
   *
   * 分类口径见 {@link GroupLatencyResult} 的契约表。**本方法不抛异常**。
   */
  async testGroupDetailedResult(groupName: string, testUrl: string,
    timeoutMs: number, expectedNodes: number = 0): Promise<GroupLatencyResult> {
    const out: GroupLatencyResult = new GroupLatencyResult();
    const req = http.createHttp();
    this.inflight.add(req);
    try {
      // 组测是内核并发全测，App 只有一个请求；外层超时给整组留足预算 + 调度余量。
      //
      // 2026-10-22（600 节点订阅「测几个又不测了」）：外层超时原来恒为 `timeoutMs + 5s`
      // = 10s，而内核侧并发上限是 50（core `mBatch=50`）⇒ 600 个节点要 ≈ ceil(600/50)×5s
      // = 60s。10s 到点 → 客户端断连 → 分类成 CORE_NOT_READY → 界面报「通道不可用」。
      // 现在按 `expectedNodes` 估算波数并逐波加预算（上限 5 分钟）。
      const waves = expectedNodes > 0 ? Math.ceil(expectedNodes / 50) : 1;
      const outerTimeoutMs = Math.min(300000, timeoutMs + 5000 + (waves - 1) * timeoutMs);
      const resp = await req.request(
        `${this.baseUrl()}/group/${encodeURIComponent(groupName)}/delay?url=${encodeURIComponent(testUrl)}&timeout=${timeoutMs}`, {
        method: http.RequestMethod.GET,
        header: this.authHeader(),
        connectTimeout: outerTimeoutMs,
        readTimeout: outerTimeoutMs,
        usingCache: false
      });
      out.httpCode = resp.responseCode;
      let body: string = '';
      if (typeof resp.result === 'string') {
        body = resp.result as string;
      } else if (resp.result instanceof ArrayBuffer) {
        body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
      }
      if (resp.responseCode === 200) {
        try {
          const parsed = JSON.parse(body) as Record<string, number>;
          for (const key of Object.keys(parsed)) {
            const delay = parsed[key];
            if (typeof delay === 'number' && delay > 0) {
              out.delays.set(key, delay);
            }
          }
          out.ok = true;
          out.detail = `http=200 measured=${out.delays.size}`;
          AppLogger.info(TAG, `group latency done: group=${groupName} measured=${out.delays.size}/${body.length}`);
        } catch (jsonError) {
          out.failKind = LatencyProbeKind.NETWORK_UNREACHABLE;
          out.detail = `http=200 bad json bodyLen=${body.length} error=${this.errText(jsonError)}`;
          AppLogger.warn(TAG, `group latency JSON error: group=${groupName} ${out.detail}`);
        }
        return out;
      }
      if (resp.responseCode === 504) {
        // 全部成员超时 —— **通道正常**，只是节点全不通（绝不能报成「内核不可用」）
        out.ok = false;
        out.allTimedOut = true;
        out.failKind = LatencyProbeKind.TIMEOUT;
        out.detail = `http=504 all proxies timeout bodyLen=${body.length}`;
        AppLogger.warn(TAG, `group latency all timed out (channel ok): group=${groupName}`);
        return out;
      }
      if (resp.responseCode === 401 || resp.responseCode === 403) {
        // secret 不一致：内核在跑，但用的不是我们这份凭证 → 通道不可用
        out.failKind = LatencyProbeKind.CORE_NOT_READY;
      } else if (resp.responseCode === 404) {
        // 内核代理表里没有这个组 → 切换/下发失败
        out.failKind = LatencyProbeKind.SWITCH_FAILED;
      } else if (resp.responseCode === 503) {
        // 单节点拨号失败语义
        out.failKind = LatencyProbeKind.TIMEOUT;
      } else {
        out.failKind = LatencyProbeKind.NETWORK_UNREACHABLE;
      }
      out.detail = `http=${resp.responseCode} bodyLen=${body.length} kind=${out.failKind}`;
      AppLogger.warn(TAG, `group latency non-200: code=${resp.responseCode} group=${groupName} `
        + `kind=${out.failKind}`);
      return out;
    } catch (e) {
      // 传输层异常：本机没能拿到 HTTP 响应 → 通道不可用（不是节点结论）
      out.failKind = LatencyProbeKind.CORE_NOT_READY;
      out.detail = `transport kind=${out.failKind} error=${this.errText(e)}`;
      AppLogger.warn(TAG, `group latency request error: ${this.errText(e)}`);
      return out;
    } finally {
      this.inflight.delete(req);
      req.destroy();
    }
  }


  /** 流量快照：GET /connections。
   *  mihomo 的 Snapshot 只有 uploadTotal/downloadTotal(累计字节), 没有速率字段;
   *  速率由本类按两次轮询的总量差值计算(比另开 /traffic WebSocket 更省资源)。 */
  private lastDownloadTotal: number = -1;
  private lastUploadTotal: number = -1;
  private lastPollAt: number = 0;

  /** 清空差值基线（连接/断开时调用, 避免跨会话算出假速率） */
  resetTrafficBaseline(): void {
    this.lastUploadTotal = -1;
    this.lastDownloadTotal = -1;
    this.lastPollAt = 0;
    this.trafficLogged = 0;
  }

  /** 一次性诊断: 前 3 次轮询把响应概况写入运行日志(排查面板恒 0 问题) */
  private trafficLogged: number = 0;

  private logTrafficOnce(code: number, bodyLen: number, up: number, down: number): void {
    if (this.trafficLogged < 3) {
      this.trafficLogged = this.trafficLogged + 1;
      AppLogger.info(TAG, `traffic diag: code=${code} len=${bodyLen} up=${up} down=${down}`);
    }
  }

  async traffic(): Promise<TrafficSnapshot> {
    const empty: TrafficSnapshot = { uploadBytes: 0, downloadBytes: 0, uploadSpeed: 0, downloadSpeed: 0 };
    const req = http.createHttp();
    try {
      const resp = await req.request(`${this.baseUrl()}/connections`, {
        method: http.RequestMethod.GET,
        header: this.authHeader(),
        connectTimeout: 2000,
        readTimeout: 2000,
        usingCache: false
      });
      let body: string = '';
      if (typeof resp.result === 'string') {
        body = resp.result as string;
      } else if (resp.result instanceof ArrayBuffer) {
        body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
      }
      if (resp.responseCode !== 200 || body.length === 0) {
        return empty;
      }
      const json = JSON.parse(body) as Record<string, number>;
      const uploadBytes = json['uploadTotal'] !== undefined ? json['uploadTotal'] : 0;
      const downloadBytes = json['downloadTotal'] !== undefined ? json['downloadTotal'] : 0;
      this.logTrafficOnce(resp.responseCode, body.length, uploadBytes, downloadBytes);
      const now = Date.now();
      let uploadSpeed = 0;
      let downloadSpeed = 0;
      if (this.lastPollAt > 0 && now > this.lastPollAt && this.lastUploadTotal >= 0) {
        const elapsedSeconds = (now - this.lastPollAt) / 1000;
        const du = uploadBytes - this.lastUploadTotal;
        const dd = downloadBytes - this.lastDownloadTotal;
        if (du >= 0) {
          uploadSpeed = du / elapsedSeconds;
        }
        if (dd >= 0) {
          downloadSpeed = dd / elapsedSeconds;
        }
      }
      this.lastUploadTotal = uploadBytes;
      this.lastDownloadTotal = downloadBytes;
      this.lastPollAt = now;
      const result: TrafficSnapshot = {
        uploadBytes: uploadBytes,
        downloadBytes: downloadBytes,
        uploadSpeed: uploadSpeed,
        downloadSpeed: downloadSpeed
      };
      return result;
    } catch (e) {
      if (this.trafficLogged < 3) {
        this.trafficLogged = this.trafficLogged + 1;
        AppLogger.info(TAG, `traffic diag: request failed ${AppLogger.errText(e)}`);
      }
      return empty;
    } finally {
      req.destroy();
    }
  }

  /**
   * 拉取活动连接列表（实时连接面板）。
   * 返回 null 表示内核/controller 不可用（与 smartActiveNodes 同语义：调用方必须把
   * null 当"通道不可用"而不是"没有连接"）；connections 字段缺失 = 正常无连接。
   */
  async listConnections(knownNames: string[] = []): Promise<ConnectionEntry[] | null> {
    const req = http.createHttp();
    try {
      const resp = await req.request(`${this.baseUrl()}/connections`, {
        method: http.RequestMethod.GET,
        header: this.authHeader(),
        connectTimeout: 2000,
        readTimeout: 3000,
        usingCache: false
      });
      if (resp.responseCode !== 200) {
        return null;
      }
      let body: string = '';
      if (typeof resp.result === 'string') {
        body = resp.result as string;
      } else if (resp.result instanceof ArrayBuffer) {
        body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
      }
      if (body.length === 0) {
        return null;
      }
      const root = JSON.parse(body) as Record<string, Object>;
      const conns = root['connections'];
      if (conns === undefined || conns === null || !Array.isArray(conns)) {
        // 无活动连接时该字段可能缺失 —— "当前没有流量"，不是通道故障
        return [];
      }
      const out: ConnectionEntry[] = [];
      for (const item of conns as Object[]) {
        const conn = item as Record<string, Object>;
        const entry = new ConnectionEntry();
        const idRaw = conn['id'];
        entry.id = typeof idRaw === 'string' ? idRaw : `${out.length}`;
        entry.upload = typeof conn['upload'] === 'number' ? conn['upload'] as number : 0;
        entry.download = typeof conn['download'] === 'number' ? conn['download'] as number : 0;
        const startRaw = conn['start'];
        entry.startMs = typeof startRaw === 'string' ? Date.parse(startRaw) : 0;
        const metaRaw = conn['metadata'];
        const meta = (metaRaw !== undefined && metaRaw !== null ? metaRaw : {}) as Record<string, Object>;
        const hostRaw = meta['host'];
        const dstRaw = meta['destinationIP'];
        const portRaw = meta['destinationPort'];
        entry.host = typeof hostRaw === 'string' && hostRaw.length > 0
          ? hostRaw : (typeof dstRaw === 'string' ? dstRaw : '');
        entry.port = typeof portRaw === 'string' ? parseInt(portRaw)
          : (typeof portRaw === 'number' ? portRaw : 0);
        const netRaw = meta['network'];
        entry.network = typeof netRaw === 'string' ? netRaw : '';
        const chainsRaw = conn['chains'];
        if (chainsRaw !== undefined && chainsRaw !== null && Array.isArray(chainsRaw)) {
          entry.chains = (chainsRaw as Object[]).map((v: Object) => String(v));
        }
        // 出口节点名：与已知节点名求交取最后一个命中（smart 组的 Now() 不回写，
        // chains 才是事实；与 smartActiveNodes 同一判定口径）。
        for (const name of entry.chains) {
          if (knownNames.length === 0 || knownNames.includes(name)) {
            entry.outbound = name;
          }
        }
        const ruleRaw = conn['rule'];
        const rulePayloadRaw = conn['rulePayload'];
        entry.rule = typeof ruleRaw === 'string' ? (typeof rulePayloadRaw === 'string'
          && (rulePayloadRaw as string).length > 0 ? `${ruleRaw}(${rulePayloadRaw})` : ruleRaw) : '';
        out.push(entry);
      }
      return out;
    } catch (e) {
      AppLogger.warn(TAG, `listConnections failed: ${this.errText(e)}`);
      return null;
    } finally {
      req.destroy();
    }
  }

  /** 关闭单条连接（DELETE /connections/{id}），2xx/204 视为成功。 */
  async closeConnection(id: string): Promise<boolean> {
    if (id.length === 0) {
      return false;
    }
    const req = http.createHttp();
    try {
      const resp = await req.request(`${this.baseUrl()}/connections/${encodeURIComponent(id)}`, {
        method: http.RequestMethod.DELETE,
        header: this.authHeader(),
        connectTimeout: 2000,
        readTimeout: 2000,
        usingCache: false
      });
      return resp.responseCode >= 200 && resp.responseCode < 300;
    } catch (e) {
      AppLogger.warn(TAG, `closeConnection failed: ${this.errText(e)}`);
      return false;
    } finally {
      req.destroy();
    }
  }

  /** 关闭全部活动连接（DELETE /connections），常用于切换节点后清理旧连接。 */
  async closeAllConnections(): Promise<boolean> {
    const req = http.createHttp();
    try {
      const resp = await req.request(`${this.baseUrl()}/connections`, {
        method: http.RequestMethod.DELETE,
        header: this.authHeader(),
        connectTimeout: 2000,
        readTimeout: 2000,
        usingCache: false
      });
      return resp.responseCode >= 200 && resp.responseCode < 300;
    } catch (e) {
      AppLogger.warn(TAG, `closeAllConnections failed: ${this.errText(e)}`);
      return false;
    } finally {
      req.destroy();
    }
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => resolve(), ms);
    });
  }
}
