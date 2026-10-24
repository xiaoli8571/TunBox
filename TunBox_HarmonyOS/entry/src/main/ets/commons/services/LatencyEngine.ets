/**
 * 延迟测试引擎（重做，5.6.0）—— 唯一入口
 *
 * ## 为什么废弃旧方案
 *
 * 旧实现（NodeSelectionPage.runBatch + ConnectionOrchestrator.ensureTestCore）在
 * 未连接时会**专门拉起第二个无头 mihomo 内核**（第二个 VpnExtensionAbility 进程，
 * 写 mihomo_test_config.yaml，无 TUN），再自己开 10 路 lane 逐节点打
 * /proxies/{name}/delay。代价与缺陷（真机取证 2026-09-19）：
 *
 *  1. 点测速要先等第二内核起来（DoH 预解析 → 停旧扩展 → 600ms 等待 → 启新扩展 →
 *     健康轮询，20s 超时），第一个数字迟迟不出现；
 *  2. 两个内核共用 controller 端口与 secret（且共享 cache 目录）：secret 被覆盖后
 *     全部 401 → 全显超时；cache.db 的 bbolt 文件锁与 core.log 争用；
 *  3. 第二份完整 mihomo（provider + geo 数据 + 缓存）在移动端的内存/耗电开销；
 *  4. 队列等待与探测共用一份超时预算，排在饱和 lane 后面的好节点被写成超时
 *     （FlClash 专门为这个缺陷把两者拆开）；
 *  5. 命中"10s 内测速缓存"时直接返回"无需重新测速"，用户点了像没反应。
 *
 * ## 新方案的事实依据（真机实测 + mihomo 源码）
 *
 *  - `(*Proxy).URLTest` 直接 `p.DialContext` 到出站适配器，**绕过 TUN 与规则引擎**
 *    → 只要内核已加载，测速与 VPN 是否连接无关；
 *  - 已连接时隧道的 controller 就在 127.0.0.1:9090 且**带着全部真实节点**
 *    （实测 106 节点 / 16 组，全部在 PROXY 组内）→ 直接复用，零额外启动；
 *  - `/group/{name}/delay` **不采用**：对 url-test 系组忽略传入 url、对非 Selector
 *    组会 ForceSet("") 清掉固定选择、无并发上限（每节点一 goroutine）、失败节点
 *    从 map 静默消失且可能返回 200 + 部分结果。逐节点才有状态码与可流式进度。
 *  - **取消不释放内核 socket**：getProxyDelay 用 context.Background()，abort 只是
 *    客户端行为，内核会继续拨号到自己的 timeout。故并发上限是控制负载的唯一手段。
 *  - `timeout` 用 16 位解析 → 上限 32767，且必须显式传（不传 400）。
 *  - `history.delay == 0` 表示失败；`LastDelayForTestUrl` 用 65535 表示没测过。
 *    **0 绝不能当延迟显示**，否则死节点会以"0ms"排到最前。
 *
 * ## 通道分层
 *
 *  1. `core`：**权威通道**。已连接 → 隧道 controller；未连接 → UI 进程内无头内核
 *     （无 TUN，独立端口与 secret，实测解析 1ms 级）。真实代理延迟。
 *  2. `offline`：**粗略通道**。两条内核路径都不可用时，用 TCP/TLS/QUIC 探活给
 *     服务器可达性，状态为 OFFLINE、UI 显示 `≈123ms`，**绝不冒充代理延迟**。
 */
import { AppLogger } from '../utils/AppLogger';
import { ClashApiService } from './ClashApiService';
// 失败分类表 + 探测结果类型来自**零 import** 的 `LatencyKinds.ets`（唯一真源）。
// 引擎**不再自带**失败映射（旧的 `mapFailure` 已删）：分类与「算不算节点结论」
// 全部由内核的判定表回答，引擎只负责批次调度（队列/在途/进度/取消/DNS 结论下发）。
import { LatencyProbeKind, LatencyProbeResult } from '../latency/LatencyKinds';
import { ConnectionOrchestrator, LatencyHostSnapshot } from './ConnectionOrchestrator';
import { LatencyChannel, LatencyPolicy, LatencyRecord, LatencyState } from './LatencyState';
import { LatencyLiveView } from './LatencyLiveView';
import { ProxyNode } from '../models/ProxyNode';
import { DoHResolver } from './DoHResolver';
import { LatencyDnsVerdict, LatencyDnsStatus } from '../latency/LatencyDnsVerdict';

const TAG = 'LatencyEngine';

/**
 * 并发探测数 = **并发 worker 数**（批次队列深度）。
 *
 * ⚠ 语义澄清（这一层长期被混淆 —— 方案 C8b）：
 *  · `LATENCY_CONCURRENCY`（本常量，50）= **同时处于探测中的任务数**（worker 数），
 *    即批次队列深度。它**不是**同时发出的 HTTP 请求数。
 *  · `LATENCY_INFLIGHT`（另一个常量）= **同时在飞的 HTTP 请求数**。
 *  · **2026-10-20 起两者都是 50**（用户拍板放开）：不再有应用层排队，
 *    每个节点的 elapsed 就是它自己那次 /delay 的真实耗时。
 *
 * 为什么是 50：与 FlClash 的 `maxConcurrentDelayTests = 50` **数值对齐**（口径一致，
 * 便于日后做同口径对比）。⚠ 但**数值对齐 ≠ 机制对齐**：FlClash 的 50 是内核
 * mBatch 限流（IPC 通道），本项目的 50 是客户端 REST 侧的队列深度 ——
 * 真正同时拨号的数量由内核自身调度决定（根因 T3：REST 通道拿不到核内并发）。
 *
 * 最坏墙钟：⌈50/50⌉ × 5s ≈ 5s < BATCH_DEADLINE_MS(90s) → deadline 不会砍掉队尾。
 *
 * ⚠ 历史真机取证（2026-10-17）：冷内核 44 节点**全并发**把 controller API
 * 拖到 Operation timeout；当时测得 OHOS http 单 host 约 8 并发上限。
 * 2026-10-20 用户要求放开到 50 并重测：若真机复现「测速卡住/大量假超时」，
 * 优先回退到 24 或 32。
 */
export const LATENCY_CONCURRENCY = 50;
/**
 * 同时在飞的 HTTP 请求数（**2026-10-21 晚：8 → 32**，对齐 FlClash 客户端在途 32）。
 *
 * 8 的来历（真机取证 192.168.10.5:39933，飞鸟云 31 节点批，14:32:46–14:35:10）：
 *  · 50 路在途 = 50 个 `/delay` 同时打 `127.0.0.1:9090`，而 OHOS http 栈对同一 host
 *    只有约 8 条连接（2026-09-23 已实测）⇒ 其余请求在 **HTTP 栈内部**排队，
 *    排队时间被算进外层预算 ⇒ 一到点就抛 `code=2300028 Operation timeout`；
 *  · 这些客户端超时被 `LatencyProbe.classify` 归为 `core_not_ready`（没拿到 HTTP 响应
 *    = 通道问题）⇒ 6 连击撞上 `CORE_NOT_READY_ABORT_STREAK` ⇒ **整批作废**，剩下的
 *    节点一次 `/delay` 都没发（日志 `notReady=6 unavailable=true`）—— 用户看到的就是
 *    「测出一部分超时节点后，剩下的就不测了」。
 *
 * 现行 32（用户要求与 FlClash 客户端同口径）：**前提是排队发生在应用层闸门**
 * （LatencyInflightGate）—— 闸门等待不计入单请求预算（见 gatedProbe 三条硬约束），
 * 所以栈内排队不再污染读数。若真机再次出现成片假超时，回退顺序：32 → 16 → 8。
 *
 * ⚠ 改这个值必须同步：
 *   ① `scripts/verify-latency-concurrency.mjs` 的字面数字（常量契约 / lanes / 峰值 /
 *      名额满用例 / TOTAL 节点数）；
 *   ② 「栈内排队是否仍被算进超时」这个前提（自建连接池或换传输层才谈得上再放大）。
 *   判定看 `latency batch done ... timeout= queueTimeout= notReady= unavailable=` 四个计数。
 */
export const LATENCY_INFLIGHT = 32;
/**
 * 信号量排队等待上限（毫秒）。
 *
 * 等待超时的节点标为**排队超时**（独立失败分类 `LatencyProbeKind.QUEUE_TIMEOUT`），
 * 绝不归入 CORE_NOT_READY —— 那是**通道级**故障（内核/凭证），与节点排队两回事。
 * 60s：59 节点的最坏排队约 ⌈59/8⌉×5s ≈ 37s，留足余量。
 */
export const LATENCY_QUEUE_WAIT_MAX_MS = 60000;
/** 单节点探测超时（2026-10-20 晚用户要求 5s → 3s）。 */
export const LATENCY_TIMEOUT_MS = LatencyPolicy.DEFAULT_TIMEOUT_MS;
/** 组测速（GET /group/{name}/delay）的整组预算。真机实测（2026-09-23）：内核的
 * 单节点拨号/HTTP 请求都用整组 context——死节点和连得上但响应慢的节点会等满
 * 预算才放弃，把整组拖长。3000ms：健康节点真机最高实测 ~522ms，5.7 倍余量，
 * 整组约 3 秒完成（用户要求）。
 * 2026-10-20 晚随单节点超时一起从 5s 改回 3s：组测里这个值是**每个节点**的拨号预算，
 * 与逐节点探测必须同尺，否则同一节点在「测全部」和「单节点测速」里结论相反。
 * 2026-10-22：页面层的组测速实现已删除（死路径 + 与订阅页两套口径），本常量只为兼容
 * 既有 import 保留，且改为**转调真源**（单节点 5s）—— 不许再留第二份字面量。 */
export const GROUP_TEST_TIMEOUT_MS = LatencyPolicy.DEFAULT_TIMEOUT_MS;
/** 首批请求错峰抖动上限，避免整批同时撞内核（Clash Verge Rev 同款做法）。 */
const STAGGER_MAX_MS = 200;
/**
 * 单批硬上限：超过即把剩余节点保持「未测」，绝不盖章为失败。
 * 导出是为了让回归套件能**真跑**出 deadline 场景（而不是只读源码断言），
 * 见 scripts/verify-latency-engine-runtime.mjs。
 */
export const BATCH_DEADLINE_MS = 90000;
/**
 * 连续「通道不可用」达到该次数即**中止本批**（内核不在/凭证错配，整批结论无效）。
 *
 * ⚠ 这是**全批共享**计数器：任何一个节点命中都会 +1（不是每个节点各算一份）。
 * 因此阈值不能太小 —— **个别节点的传输异常**（弱网抖动、内核瞬时过载）不该让
 * 整批结论作废。3 → 6：连击 6 次才作废整批。
 */
const CORE_NOT_READY_ABORT_STREAK = 6;
/**
 * 大订阅（几百个节点）下的作废阈值：`max(6, ceil(N/64))`。
 *
 * 为什么必须随批次放大（2026-10-22 真机：导入 600 节点订阅后「测几个就不测了」）：
 * 600 个节点里死节点占多数时，32 路在途会把 controller 的 /version 探针也压到超时 ——
 * 客户端看到的是「连续 6 次没拿到响应」，但通道其实只是**忙**。按 64 节点一档放大后，
 * 大订阅需要 ~10 次连续失联才作废，小订阅仍是 6（保持原有灵敏度）。
 */
function abortStreakFor(nodeCount: number): number {
  const scaled = Math.ceil(Math.max(1, nodeCount) / 64);
  return Math.max(CORE_NOT_READY_ABORT_STREAK, Math.min(scaled, 30));
}
/**
 * 连续「通道不可用」达到该次数即尝试一次**通道自愈**（重解析 endpoint/secret）。
 *
 * 为什么比「作废阈值」低：自愈是**廉价且每批只做一次**的动作（读一次配置、
 * 换一次凭证），早点尝试能救回「内核中途重启换了 secret」这类可恢复故障；
 * 而作废整批是**破坏性**动作（整批结论作废、剩余节点停在「未测」），
 * 必须更谨慎才敢做。
 */
const CORE_NOT_READY_RECOVER_STREAK = 3;
/**
 * 通道报「不可用」时的**就地重试**次数与线性退避基数。
 *
 * 为什么必须重试（真机取证 2026-10-18，飞鸟云 37 节点批）：
 * 死亡节点成批拨号会把 controller(127.0.0.1:9090) 拖到 `code=2300028 Operation timeout`，
 * 但这是**瞬时过载**而非内核死亡 —— 实测同一台机器上 44/46、24/24 的批次都正常。
 * 旧实现每命中一次就 `coreNotReadyStreak++`，连续 3 次即作废整批：37 节点中
 * 14 个已经被内核盖成「超时」的真实结论被回滚，其余 20 个永远停在「未测」——
 * 用户看到的就是「一半超时、一半 --」。先重试再判死，可让批次真正跑完。
 *
 * ⚠ 2 → 1 次、退避 350 → 500ms（方案 C12）：**过载时重试会把压力再放大一倍**
 * （真机 37 个死节点打爆 controller 的教训）。过载的正确解法是**限流**
 * （C7 的在途信号量），不是多打几遍 —— 每多一轮重试，连接池就更挤。
 */
const CORE_NOT_READY_RETRY_MAX = 1;
const CORE_NOT_READY_RETRY_BACKOFF_MS = 500;
/**
 * 「controller 还活着吗」的探测预算与缓存窗口（见 `LatencyRun.controllerAnswers`）。
 *
 * 为什么需要它（2026-10-21 真机根因）：客户端侧 `2300028 Operation timeout` 有两种
 * 完全相反的成因 ——（a）控制器被瞬时打满（并发拨号太多）；（b）内核真的没了 /
 * secret 被换掉。只看错误文案分不开，旧实现一律按（b）累加连击 ⇒ 6 次就把整批作废。
 * 800ms 是 `/version` 这种本地 GET 的宽松预算；缓存窗口同值，避免 8 个 worker
 * 同时命中时打出 8 次健康检查（过载时再加负载只会更糟）。
 */
const CONTROLLER_PROBE_TIMEOUT_MS = 800;
const CONTROLLER_ALIVE_CACHE_MS = 800;
/** `force=false` 时，多久以内的实测结果视为新鲜、可跳过重测。 */
export const FRESH_RESULT_MS = 5 * 60 * 1000;
/**
 * 批次结束后测速内核的空闲宽限（毫秒）。90s 内来回切页面/连点测速复用同一内核，
 * 超过则回收，避免临时进程在后台长期常驻。仅对未连接时的 headless 内核生效。
 */
export const LATENCY_CORE_IDLE_MS = 90000;

/**
 * 默认测速 URL：**HTTPS** 的 generate_204。
 *
 * 依据（2026-10-20 复核，方案 C1）：
 *  · FlClash 出厂默认即 `https://www.gstatic.com/generate_204`（数值口径对齐）；
 *  · mihomo 官方告警点名 `provider.health-check.url` 与 `group.url` 应使用 HTTPS ——
 *    明文测速地址会被机场/落地劫持（第一次 HEAD 就被劫成非 204 → 该节点判失败）；
 *  · 5.6.0 真机基线：https + 并发 8，59 节点 13.14s 跑通、`unavailable=false`。
 *
 * ⚠ 但**不得**把用户自填的 http URL 强行改写：部分出口会掐 gstatic 的 TLS SNI
 * （真机 commit `a3fe45d` 实证：YF 新加坡 https=Timeout / http=1158ms）。
 * 「用户自填 http 属合法用法」由 AppSettings 侧的**精确匹配 + 单向升级**策略保证
 * （`AppSettings.upgradeLegacyTestUrl`），本引擎只负责自己的默认值。
 */
export const LATENCY_TEST_URL = 'https://www.gstatic.com/generate_204';
/**
 * 备用测速源（**HTTPS**）。
 *
 * ⚠ **当前引擎不会自动回退到它**（方案 C14b）：自动回退会与 C7 的在途信号量 /
 * 超时预算打架 —— 回退 = 再发一次请求 = 再占一个在途名额 + 再等一份超时预算，
 * 会把「排队」放大成「过载」，正是本轮要消灭的现象。
 * 它只作为**显式选择**的备用源，供设置页与调用方使用。
 *
 * ⚠ 用户自填的 http 测速 URL 是**合法用法**（部分出口掐 gstatic 的 TLS SNI），
 * 任何地方都**不得**擅自把它改写成 https 或本常量。
 */
export const LATENCY_TEST_URL_ALT = 'https://cp.cloudflare.com/generate_204';

/** 一次在途名额的排队票据（见 LatencyInflightGate）。 */
class GateTicket {
  /** 是否拿到名额（false = 排队等待超时） */
  granted: boolean = false;
  /** 是否已结算（放号或超时，二者只生效一次） */
  settled: boolean = false;
  /** 结算回调：闸门在放号 / 超时时调用 */
  wake: (granted: boolean) => void = noopGateWake;
}

/** 空结算回调（票据在被唤醒前的占位实现） */
function noopGateWake(granted: boolean): void {
  if (granted) {
    return;
  }
}

/**
 * 应用层在途闸门（信号量）。
 *
 * ArkTS 没有原生 Semaphore，这里用**纯计数 + 等待队列**实现：
 *  · `active` = 当前占用的在途名额数（严格 ≤ `LATENCY_INFLIGHT`）；
 *  · 等待者排成 FIFO 队列，释放时按先进先出把名额**直接移交**给队首。
 *
 * 为什么必须放在应用层（根因 T2 / T3）：OHOS http 栈对同一 host 只有约 8 个并发
 * 连接，超出的请求在 **HTTP 栈内部**排队，而那段时间被算进请求的超时预算 →
 * 排队中的请求必然先在客户端侧超时 → 被归类成通道故障 → 连击作废整批 →
 * 用户看到「测速全部失败」。把排队从 HTTP 栈挪进应用层、且**让等待不计入请求
 * 超时**，每个在途请求才能拿到**真实判定**（200/504/503/404）。
 */
export class LatencyInflightGate {
  private static gate: LatencyInflightGate | null = null;
  /** 当前占用的名额数 */
  private active: number = 0;
  /** 名额上限（= OHOS 同 host 连接池容量） */
  private limit: number = LATENCY_INFLIGHT;
  /** 等待队列（FIFO） */
  private waiters: GateTicket[] = [];

  /**
   * 全局唯一实例。
   *
   * 跨批次**共享**是刻意的：新批次接管时，旧批次的在途请求还没真正结束，
   * 若每个批次各有一把闸门就会出现「短暂的 16 在途」，把连接池再次打爆。
   */
  static shared(): LatencyInflightGate {
    if (LatencyInflightGate.gate === null) {
      LatencyInflightGate.gate = new LatencyInflightGate();
    }
    return LatencyInflightGate.gate;
  }

  /** 当前在途数（诊断用） */
  inflightCount(): number {
    return this.active;
  }

  /**
   * 申请一个在途名额。
   *
   * @param waitBudgetMs 排队等待上限（毫秒）
   * @returns true = 拿到名额；false = **排队等待超时**（调用方按节点级排队超时处理，
   *          不得归入 CORE_NOT_READY）
   */
  async acquire(waitBudgetMs: number): Promise<boolean> {
    if (this.active < this.limit) {
      this.active = this.active + 1;
      return true;
    }
    const ticket: GateTicket = new GateTicket();
    const waiting: Promise<void> = new Promise<void>((resolve) => {
      ticket.wake = (granted: boolean): void => {
        if (ticket.settled) {
          return;
        }
        ticket.settled = true;
        ticket.granted = granted;
        resolve();
      };
    });
    this.waiters.push(ticket);
    let timerId: number = -1;
    timerId = setTimeout(() => {
      // 排队超时：把自己从队列里摘掉（若已被放号，settled 保护会挡住重复结算）
      const idx: number = this.waiters.indexOf(ticket);
      if (idx >= 0) {
        this.waiters.splice(idx, 1);
        ticket.wake(false);
      }
    }, waitBudgetMs);
    await waiting;
    if (timerId !== -1) {
      clearTimeout(timerId);
    }
    return ticket.granted;
  }

  /**
   * 释放一个名额，并把名额按 FIFO **直接移交**给队首等待者。
   *
   * 移交时 `active` 保持不变（名额没被浪费），等待者被唤醒后即可发请求。
   */
  release(): void {
    if (this.active > 0) {
      this.active = this.active - 1;
    }
    while (this.waiters.length > 0) {
      const next: GateTicket = this.waiters[0];
      this.waiters.shift();
      if (next.settled) {
        // 已超时结算的票据：名额继续往下传
        continue;
      }
      this.active = this.active + 1;
      next.wake(true);
      return;
    }
  }
}

/** 进度快照（UI 直接绑定） */
/**
 * 是否信任「**0 命中**」的 DNS 快照（attempted 里有域名、pins 里一个都没有）。
 *
 * 两种解释在数据上分不开：
 *  ① 整批域名真的都解析不出来（机场换域名了）—— 正是 2026-10-20 那批 mitce 节点；
 *  ② 这份快照压根**不是被测通道**的解析结果（口径错位）—— 会把好节点冤枉成域名下线。
 *
 * 默认 **false（保守）**：宁可少报，也不误伤。
 * 编排器侧把 `hostSnapshot().pins` 换成「被测通道实际生效的 hosts」、
 * 且 attempted 换成「真正查过的域名」之后，可置 true。
 */
const DNS_TRUST_EMPTY_SNAPSHOT: boolean = false;

export class LatencyProgress {
  total: number = 0;
  finished: number = 0;
  measured: number = 0;
  timeout: number = 0;
  failed: number = 0;
  cancelled: number = 0;
  /** 因结果仍新鲜而跳过的节点数（force=false 时） */
  skipped: number = 0;
  /**
   * **排队超时**的节点数（在途闸门上等太久才轮到它，这一轮没发出请求）。
   *
   * 它是 `timeout` 的**子集**（state 同为 TIMEOUT），单独计数是为了在日志里
   * 把「节点不通」与「没排上队」分开看 —— 后者是队列问题，不是节点问题。
   */
  queueTimeout: number = 0;
  /** 通道不可用（内核/凭证层面）的连续命中总数 */
  coreNotReady: number = 0;
  /**
   * **过载**次数：controller 仍能答 `/version`，但这一发 `/delay` 在客户端侧超时
   * （典型是 `2300028 Operation timeout`）。
   *
   * 与 `coreNotReady` 分开计：过载不是节点结论、也不是通道故障，**不参与连击/作废**；
   * 但必须留痕，否则「整批跑完却一堆未测」在日志里看不出原因（2026-10-21 真机）。
   */
  coreOverloaded: number = 0;
  /**
   * **域名无法解析**的节点数（2026-10-20 真机根因）。
   *
   * 这批节点**一次 /delay 都没发**（我们自己的 DoH 预解析已经判了）⇒
   * 它们不是「超时」也不是「网络不可达」，而是「域名可能已下线」。
   * 单独计数是为了让 UI 能把它折成**一条**组级诊断条，而不是 N 条同色红条。
   */
  dnsUnresolved: number = 0;
  /** 整批因通道不可用而中止：此时**不能**把结果当节点结论 */
  coreUnavailable: boolean = false;
  /** 本批实际使用的通道：LatencyChannel.CORE / OFFLINE */
  channel: string = LatencyChannel.CORE;
  running: boolean = false;

  done(): boolean {
    return !this.running;
  }
}

export type LatencyResultSink = (rec: LatencyRecord) => void;
export type LatencyProgressSink = (p: LatencyProgress) => void;

/** 批次参数 */
export class LatencyRunOptions {
  timeoutMs: number = LATENCY_TIMEOUT_MS;
  /** true=全部重测；false=跳过仍新鲜的实测结果（进页面自动测速用） */
  force: boolean = true;
  /** 结果来源：'auto'（静默批）| 'manual'（用户手点）；随记录落库供 UI 区分显示 */
  source: string = 'manual';
  /**
   * 整批硬截止（毫秒）。**0 = 按批大小自动计算**（2026-10-22 起默认）；
   * 只有回归测试才注入小值 —— 它要在毫秒级确定性地验证「超时的节点保持未测、
   * 绝不写成失败」这条契约，不必把「并发数 × 节点数」的算术巧合当前提。
   */
  batchDeadlineMs: number = 0;
  onResult: LatencyResultSink | null = null;
  onProgress: LatencyProgressSink | null = null;
}

/**
 * 单批测速会话。同一个引擎上同时只允许一个会话；新会话使旧会话立即作废。
 */
export class LatencyRun {
  private readonly api: ClashApiService | null;
  private readonly nodes: ProxyNode[];
  private readonly url: string;
  private readonly timeoutMs: number;
  private readonly force: boolean;
  private readonly source: string;
  private readonly onResult: LatencyResultSink | null;
  private readonly onProgress: LatencyProgressSink | null;
  private readonly batchDeadlineMs: number;
  private readonly progress: LatencyProgress = new LatencyProgress();
  /** 代次：被 cancel / 新批次抢占时递增，旧回调据此丢弃结果 */
  private generation: number = 0;
  /**
   * 批次身份（写入每条 TESTING 记录）。与 generation 分开：
   * generation 会被 cancel/invalidate 递增（用于丢弃结果），runId 必须**稳定**
   * 表示"这批标记是谁打的"，否则收尾时会认不出自己的标记。
   * 发号统一走 LatencyLiveView.nextRunId（进程内跨引擎唯一，防与 Flclash 路径撞号）。
   */
  private readonly runId: number = LatencyLiveView.nextRunId();
  private cancelled: boolean = false;
  private finished: boolean = false;
  private coreNotReadyStreak: number = 0;
  /**
   * 本批的整批硬截止时刻（run() 开始时确定）。
   *
   * gatedProbe 在**拿到在途名额之后**再检查它：排队期间可能已经到点，
   * 这时就不该再发请求（发了也算不进结论，只会拖慢整批）。
   */
  private deadlineAt: number = 0;
  /** 本批是否已尝试过"重新解析通道凭证"（每批最多一次） */
  private channelRecoveryTried: boolean = false;
  /**
   * controller 存活探测的缓存（见 `controllerAnswers`）：
   * `channelAliveAtMs = 0` 表示本批还没探过。
   */
  private channelAliveAtMs: number = 0;
  private channelAlive: boolean = false;
  /**
   * 本批的 **DNS 预解析快照**（批次开始时取一次，不逐节点去问编排器）。
   *
   * 来源：编排器侧的 `ConnectionOrchestrator.instance().hostSnapshot()`
   * （pins = 域名→IP，attempted = 本批尝试解析过的域名）。
   * 拿不到 / 口径不可信 = 没有 DNS 结论 => 全部按 unknown 处理（照常探测），
   * **绝不**凭空判 dns_unresolved。
   */
  private dnsSnapshot: LatencyHostSnapshot | null = null;
  private cursor: number = 0;

  constructor(api: ClashApiService | null, nodes: ProxyNode[], url: string, timeoutMs: number,
    force: boolean, onResult: LatencyResultSink | null, onProgress: LatencyProgressSink | null,
    source: string = 'manual', batchDeadlineMs: number = 0) {
    this.api = api;
    this.nodes = nodes;
    this.url = url;
    this.timeoutMs = timeoutMs;
    this.force = force;
    this.source = source;
    this.onResult = onResult;
    this.onProgress = onProgress;
    // 0 = 按批大小自动算（大订阅不再被固定的 90s 砍掉队尾）；测试注入的小值照旧生效
    this.batchDeadlineMs = batchDeadlineMs > 0
      ? batchDeadlineMs : LatencyEngine.deadlineForBatch(nodes.length);
    this.progress.total = nodes.length;
    // ⚠ api === null ⇒ 没有内核通道 ⇒ 本批**不探测**（旧的离线直连兜底通道已下线：
    //   它测的是「服务器可达」而不是代理延迟，混进延迟列会把「服务器近」冒充
    //   「线路快」）。此时 channel 记为 OFFLINE，UI 显示「未测」而不是假延迟。
    this.progress.channel = api === null ? LatencyChannel.OFFLINE : LatencyChannel.CORE;
  }

  isRunning(): boolean {
    return !this.finished && !this.cancelled;
  }

  currentProgress(): LatencyProgress {
    return this.progress;
  }

  /**
   * 取消本批。
   *
   * 注意：mihomo 的 /proxies/{n}/delay 用 context.Background()，**abort HTTP 请求
   * 不会让内核停止拨号**（仍跑到自己的 timeout）。cancel 的作用是把结果标记为
   * 「已取消」并把 UI 从"测试中"解放，而非真正减负 —— 负载由 LATENCY_CONCURRENCY
   * 控制。这里仍调用 cancelInflight()，因为它能立刻释放客户端侧 http 句柄，避免
   * 页面退出后旧回调继续写 UI。
   */
  cancel(): void {
    if (this.cancelled || this.finished) {
      return;
    }
    this.userCancelled = true;
    this.cancelled = true;
    this.generation = this.generation + 1;
    if (this.api !== null) {
      this.api.cancelInflight();
    }
    AppLogger.info(TAG, `latency run cancelled finished=${this.progress.finished}/${this.progress.total} `
      + `channel=${this.progress.channel}`);
  }

  /**
   * 「用户主动取消 / 新批次抢占」与「引擎因通道不可用自行作废」必须区分：
   * 前者绝不能写任何节点结论（用户点了取消，不是节点的问题）；后者要给
   * 被搁置的节点补一个明确结论（见 clearOwnTestingMarks 的兜底盖章）。
   */
  private userCancelled: boolean = false;

  /** 内部：新批次抢占/通道不可用时作废本批剩余工作（不再发布结果） */
  private invalidate(): void {
    this.cancelled = true;
    this.generation = this.generation + 1;
  }

  /**
   * 收尾：把本批遗留的 TESTING 标记收回 `--`。
   *
   * 为什么必须在引擎内部做：被取消、被抢占、被通道故障作废（invalidate）的节点，
   * probeThroughCore/probeOffline 都不会为它发布任何记录，那条记录会**永远停在
   * TESTING** —— UI 行上就是一个永不停止的转圈。这不是节点结论，必须收回。
   *
   * 旧实现依赖每个调用方自己记得清理（浏览器里就是 NodeSelectionPage 的
   * clearTestingMarks），漏一个入口就漏一个永久转圈。收尾归引擎 = 引擎自己在
   * 所有退出路径（正常结束 / 取消 / 作废 / 异常）上都保证不再留下 TESTING。
   */
  private clearOwnTestingMarks(): void {
    let cleared = 0;
    for (const node of this.nodes) {
      // 只收回**本批**打上的 TESTING：runId 是批次身份，抢占后的新批在
      // 同一节点上重新 markTesting(runId'≠runId)，旧批收尾不得清掉它。
      if (LatencyLiveView.isTestingOwnedBy(node.name, this.runId)) {
        LatencyLiveView.setRecord(LatencyRecord.untested(node.name));
        cleared = cleared + 1;
      }
    }
    // ⚠ 这里**不再**回滚已盖章的失败结论（2026-10-18 用户裁定后移除）。
    //
    // 旧实现（coreUnavailable 时把本批 failure 章一并改回 untested）的理由是
    // 「通道故障批的章不可信」，但代码路径上根本不成立：通道级故障
    // （failKind=CORE_NOT_READY）在 probeThroughCore 里走的是「通道级故障」分支
    // —— **从不发布任何记录**（判定权在内核的 isVerdictKind）。因此能被回滚的
    // 失败章，100% 都是内核针对该节点给出的真实拨号结论（504 → TIMEOUT）。
    //
    // 真机取证 2026-10-18（飞鸟云 37 节点批）：内核已把 14 个节点盖成「超时」，
    // 随后 controller 瞬时过载触发整批作废，这 14 个真实结论被改回「未测」，
    // 连同 20 个未探测节点，用户看到 34/38 行都是 `--`。用户明确要求
    // 「要么超时、要么显示延迟，不要第三种结果」——故此处只收回 TESTING
    // （"我们不知道"才是诚实的中性态），已确定的节点结论一律保留。
    // ── 兜底盖章（2026-10-18 用户裁定）：因**通道不可用**被搁置的节点补「超时」 ──
    //
    // 用户诉求：「要么显示延迟多少、要么显示超时，不要第三种结果」。
    // 通道作废整批时，没来得及拨号的节点此前会永远留 `--`（未测），用户会误以为
    // 根本没测速。这里给它们一个明确结论：内核不可用 → 该节点本轮无法使用 → 超时。
    //
    // 边界（很重要，别扩大）：
    //  · 只在 coreUnavailable（引擎判定通道不可用）时补章；
    //  · **用户主动取消 / 新批次抢占**（userCancelled）绝不补章 —— 那不是节点的错；
    //  · 已有结论的节点一律不动（上面已保证真实结论不被回滚）。
    let strandedStamped = 0;
    if (this.progress.coreUnavailable && !this.userCancelled) {
      for (const node of this.nodes) {
        if (LatencyLiveView.stateFor(node.name) === LatencyState.UNTESTED) {
          // 通道不可用 ≠ 节点失败：分类标 core_not_ready（NodeSortPersistence 把它
          // 列为「非节点判定」，持久化时沿用上次结论，不再把整批写成「全失败」）。
          this.publish(node.name, LatencyRecord.failed(node.name, LatencyState.TIMEOUT, Date.now(),
            LatencyChannel.CORE, LatencyProbeKind.CORE_NOT_READY));
          strandedStamped = strandedStamped + 1;
        }
      }
      this.progress.timeout = this.progress.timeout + strandedStamped;
    }
    if (cleared > 0 || strandedStamped > 0) {
      AppLogger.info(TAG, `latency cleanup: ${cleared} node(s) left TESTING -> untested`
        + `${strandedStamped > 0 ? `, ${strandedStamped} stranded node(s) stamped TIMEOUT` : ''} `
        + `(cancelled=${this.cancelled} userCancelled=${this.userCancelled} `
        + `unavailable=${this.progress.coreUnavailable}); stamped node verdicts kept`);
      LatencyLiveView.notify();
    }
  }

  /** 执行整批，返回最终进度 */
  async run(): Promise<LatencyProgress> {
    const generation = this.generation;
    const startedAt = Date.now();
    const deadlineAt = startedAt + this.batchDeadlineMs;
    this.deadlineAt = deadlineAt;
    AppLogger.info(TAG, `latency batch start nodes=${this.nodes.length} `
      + `concurrency=${LATENCY_CONCURRENCY} inflight=${LATENCY_INFLIGHT} `
      + `timeout=${this.timeoutMs}ms force=${this.force} `
      + `channel=${this.progress.channel} url=${this.url}`);

    if (this.api === null) {
      // 没有内核通道 ⇒ **本批不探测**。
      // 旧的「离线直连兜底」通道已下线：它测的是**服务器可达**（TCP/TLS 握手），
      // 不是代理延迟；混进延迟列会让「服务器近」冒充「线路快」（排序被带偏）。
      // 现在节点保持「未测」，由 UI 如实显示「--」。
      AppLogger.warn(TAG, `latency batch skipped: no core channel `
        + `(离线直连兜底通道已下线；节点保持未测)`);
      this.progress.finished = this.progress.total;
      this.finished = true;
      this.progress.running = false;
      this.emitProgress();
      return this.progress;
    }

    // DNS 预解析快照：**每批取一次**（口径一批之内一致，也避免逐节点跨模块调用）。
    // 来源：编排器侧的 `hostSnapshot()`（pins = 域名→IP，attempted = 本次尝试过的域名）。
    this.dnsSnapshot = ConnectionOrchestrator.instance().hostSnapshot();
    this.logDnsSnapshot();

    // ⚠ `lanes` 是**并发 worker 数**（队列深度），不是同时在飞的 HTTP 请求数；
    // 在途数由 LatencyInflightGate（LATENCY_INFLIGHT=8）控制。两者语义不同，别混。
    const lanes = Math.min(LATENCY_CONCURRENCY, Math.max(1, this.nodes.length));
    const workers: Promise<void>[] = [];
    for (let w = 0; w < lanes; w++) {
      workers.push(this.worker(w, generation, deadlineAt));
    }
    // worker 抛异常也必须收尾：否则 TESTING 标记会漏在控制器里（行上永久转圈）。
    // 引擎对所有退出路径负责，调用方不需要知道这个内部约定。
    try {
      await Promise.all(workers);
    } catch (e) {
      AppLogger.warn(TAG, `latency batch worker error: ${AppLogger.errText(e)}`);
    } finally {
      this.clearOwnTestingMarks();
    }

    this.finished = true;
    this.progress.running = false;
    this.emitProgress();
    AppLogger.info(TAG, `latency batch done nodes=${this.nodes.length} channel=${this.progress.channel} `
      + `measured=${this.progress.measured} timeout=${this.progress.timeout} failed=${this.progress.failed} `
      + `dnsUnresolved=${this.progress.dnsUnresolved} `
      + `queueTimeout=${this.progress.queueTimeout} `
      + `cancelled=${this.progress.cancelled} skipped=${this.progress.skipped} `
      + `notReady=${this.progress.coreNotReady} overloaded=${this.progress.coreOverloaded} `
      + `unavailable=${this.progress.coreUnavailable} `
      + `elapsed=${Date.now() - startedAt}ms`);
    // 内核回收归引擎管：批次结束后挂一个**宽限**回收（而不是立刻停）。测速内核重建
    // 要经历 DoH + 停旧扩展 + 600ms 等待 + 启新扩展 + 健康轮询（秒级），用户来回切
    // 页面/连点测速时应复用同一内核；宽限期内再次测速会 cancel 掉这个定时器。
    // 仅内核通道才需要回收：离线通道没有内核可回收；已连接时该方法内部会因
    // orchestrator busy 直接返回，绝不动用户正在用的 VPN（见 scheduleTestCoreRecycle）。
    if (this.api !== null) {
      ConnectionOrchestrator.instance().scheduleTestCoreRecycle(LATENCY_CORE_IDLE_MS);
    }
    return this.progress;
  }

  /**
   * 打印本批 DNS 快照的规模（诊断用）。
   *
   * ⚠ `pins=0` 且 `attempted>0` 是**危险信号**：可能是「整批域名真的都解析不出来」
   * （机场换域名了），也可能是「这份快照压根不是被测通道的解析结果」—— 两者的处置完全不同
   * （见 `dnsVerdictFor` 与 `DNS_TRUST_EMPTY_SNAPSHOT`）。
   */
  private logDnsSnapshot(): void {
    const snap = this.dnsSnapshot;
    if (snap === null) {
      AppLogger.info(TAG, `latency dns snapshot: none (编排器未暴露快照) `
        + `=> DNS 结论全部按 unknown 处理`);
      return;
    }
    const pins = Object.keys(snap.pins).length;
    const attempted = snap.attempted.length;
    AppLogger.info(TAG, `latency dns snapshot: pins=${pins} attempted=${attempted}`);
    if (pins === 0 && attempted > 0) {
      // ⚠ 危险信号：「整批域名都解析不出来」与「这份快照压根不是被测通道的解析结果」
      //    在数据上**分不开**（pins/attempted 口径不同时两者都是 0 命中）。
      //    在编排器把 pins 换成「被测通道实际生效的 hosts」之前，本批**不判**
      //    dns_unresolved（宁可少报，也不把好节点冤枉成域名下线）。
      AppLogger.warn(TAG, `latency dns snapshot: 0 pin / ${attempted} attempted `
        + `=> 本批不判 ${LatencyProbeKind.DNS_UNRESOLVED}（快照无正例，口径待编排器侧修 pins）`);
    }
  }

  /**
   * 某节点的 DNS 预检结论（**每批口径一致**）。
   *
   * 铁律（2026-10-20 lead 裁定）：
   *  - **没在 attempted 里 => unknown**（不是 unresolved）：「没试过解析」≠「解析不出来」；
   *  - attempted 里有、pins 里查不到 => unresolved => 一次 /delay 都不发；
   *  - 快照**没有正例**（pins 为空）=> 口径不可信 => 保守降级为 unknown（宁可少报不误伤）。
   */
  private dnsVerdictFor(node: ProxyNode): LatencyDnsVerdict | null {
    const snap = this.dnsSnapshot;
    if (snap === null) {
      return null;
    }
    // 「0 命中」的快照不产生 DNS 结论（见 logDnsSnapshot 的说明）：
    // 快照无正例时，「域名全下线」与「这份快照不是被测通道的解析结果」分不开 ⇒ 保守降级。
    // 精确口径（编排器给了 failed/resolved）：「failed 非空」本身就是证据 ⇒
    // 「整批域名都解析不出来」可以照实判，不必等 pins 里有正例。
    const hasFailedSet: boolean = snap.failed !== undefined && snap.failed.length > 0;
    if (Object.keys(snap.pins).length === 0 && snap.attempted.length > 0
      && !DNS_TRUST_EMPTY_SNAPSHOT && !hasFailedSet) {
      return null;
    }
    // failed/resolved 存在时用**精确口径**（查过才算失败）；
    // 不存在时退回旧口径（attempted + pins）——兼容旧的合成快照。
    const failedList: string[] = snap.failed === undefined ? [] : snap.failed;
    const resolvedList: string[] = snap.resolved === undefined ? [] : snap.resolved;
    const precise: boolean = snap.failed !== undefined && snap.resolved !== undefined;
    const verdict = precise
      ? LatencyDnsVerdict.fromPins(node.name, node.server, snap.pins, snap.attempted, failedList, resolvedList)
      : LatencyDnsVerdict.fromPins(node.name, node.server, snap.pins, snap.attempted);
    if (verdict.status === LatencyDnsStatus.UNRESOLVED) {
      AppLogger.info(TAG, `latency dns verdict: node=${node.name} host=${node.server} `
        + `status=unresolved => 本节点不发起 /delay，直接判 ${LatencyProbeKind.DNS_UNRESOLVED}`);
    }
    return verdict;
  }

  /** 领取下一个待测节点下标（单线程事件循环，无需锁） */
  private nextIndex(): number {
    const i = this.cursor;
    this.cursor = this.cursor + 1;
    return i;
  }

  private isAborted(generation: number): boolean {
    return this.cancelled || this.generation !== generation;
  }

  /**
   * 单个 worker：循环领取节点并探测。
   *
   * 队列等待与探测计时**分离**：testLatencyDetailed 的超时只覆盖这一次 HTTP，
   * worker 在两次探测之间不累积 deadline 压力，故排在后面的节点不会被前面的
   * 节点耗尽预算（旧实现共用一份 deadline，队尾节点大面积假超时）。
   *
   * ⚠ 另有一层**在途闸门**（LatencyInflightGate）：真正同时发出的 HTTP 请求
   * 恒定 ≤ LATENCY_INFLIGHT(8)，其余 worker 阻塞在闸门上；这段等待**不计入**
   * 请求超时（详见 gatedProbe）。worker 数（LATENCY_CONCURRENCY=50）与在途数
   * （8）是两回事，别再混用。
   */
  private async worker(lane: number, generation: number, deadlineAt: number): Promise<void> {
    // 首批错峰：0~200ms，避免整批同时打内核
    if (lane > 0) {
      const jitter = Math.floor(Math.random() * STAGGER_MAX_MS);
      await new Promise<void>((resolve) => setTimeout(() => resolve(), jitter));
    }
    for (;;) {
      if (this.isAborted(generation)) {
        return;
      }
      const index = this.nextIndex();
      if (index >= this.nodes.length) {
        return;
      }
      if (Date.now() >= deadlineAt) {
        AppLogger.warn(TAG, `latency batch deadline hit; nodes from index ${index} left untested`);
        return;
      }
      const node = this.nodes[index];

      // force=false：仍新鲜的实测结果直接跳过，不浪费一次拨号
      if (!this.force) {
        const existing = LatencyLiveView.recordFor(node.name);
        if (existing !== null && existing.channel === LatencyChannel.CORE && existing.hasValue()
          && Date.now() - existing.atMs < FRESH_RESULT_MS) {
          this.progress.skipped = this.progress.skipped + 1;
          this.progress.finished = this.progress.finished + 1;
          this.emitProgress();
          continue;
        }
      }

      LatencyLiveView.markTesting(node.name, this.runId);
      if (this.isAborted(generation)) {
        return;
      }
      // 单节点异常必须就地收敛。若让异常冒泡出 worker，Promise.all 会立刻拒绝，
      // 其余 lane 变成孤儿：批次已经宣布结束（finished=true）、调用方也已 release，
      // 它们的结果却还在后面陆续落库 —— 用户看到的是"进度条跑完了，列表还在变"。
      // 真实 ClashApiService 自己吞异常返回 failKind，所以这条路径平时不触发；
      // 但引擎不能依赖调用方永不抛错。
      let probe: LatencyProbeResult;
      try {
        probe = await this.probeThroughCore(node, generation);
      } catch (e) {
        AppLogger.warn(TAG, `latency probe threw for one node; keeping it untested: `
          + `${AppLogger.errText(e)}`);
        // 不落任何结论（保持未测），但必须计入进度，否则进度条永远到不了 total
        this.progress.finished = this.progress.finished + 1;
        this.emitProgress();
        continue;
      }
      if (this.isAborted(generation)) {
        return;
      }
      if (probe.failKind === LatencyProbeKind.CORE_NOT_READY) {
        // 通道不可用：不是节点结论 → 保持「未测」（连击/自愈/作废整批已在
        // probeThroughCore 里做完），但要计入进度，否则进度条永远到不了 total。
        this.progress.finished = this.progress.finished + 1;
        this.emitProgress();
        continue;
      }
      // 「要不要落结论」由**内核的判定表**回答（isVerdictKind），引擎不自带口径。
      const record: LatencyRecord | null = this.recordFor(node, probe);
      if (record !== null) {
        this.publish(node.name, record);
      }
      // ⚠ 「整批硬截止到点」不是通道故障：那些节点**根本没发出请求**，
      //   保持「未测」，且**不计入 finished**（finished 只统计拿到了结论的节点，
      //   否则进度条会把「没测」算成「测完了」）。
      if (probe.failKind !== LatencyProbeKind.UNTESTED) {
        this.progress.finished = this.progress.finished + 1;
      }
      this.emitProgress();
    }
  }

  /**
   * 通道失联时的自愈：内核**中途重启会换掉 external-controller 的 secret**
   * （真机实测：批测进行到 53/106 时隧道重启，secret 变更，随后所有 /delay 全部
   * 连接异常）。此时无需中止整批 —— 重新解析一次隧道凭证就能接着测。
   *
   * 由编排器实现（只有它知道 secret 从哪读、内核是不是刚重启过）；这里只负责
   * 在**连续失联并且本批已经有实测结果**时触发一次，且同批最多救一次，避免
   * 内核真死时把时间浪费在反复读盘上。
   */
  /**
   * 「controller 还活着吗」—— 把**瞬时过载**与**通道真的没了**分开（2026-10-21 真机根因）。
   *
   * 真机取证（飞鸟云 31 节点批）：50 路在途把 `127.0.0.1:9090` 打满，客户端连续拿到
   * `code=2300028 Operation timeout`，被 `LatencyProbe.classify` 归为 `core_not_ready`；
   * 6 连击直接作废整批，剩下 24 个节点一次 `/delay` 都没发。可内核其实一直活着
   * （同一批里前 5 个节点还正常回了 504），只是忙不过来。
   *
   * ⇒ 在把这次失败计入「通道故障连击」之前，先打一次 `GET /version`（本地、廉价）：
   *   · 200 且 secret 通过 ⇒ 通道是好的 ⇒ 这次只是**过载**：不计连击、不中止，
   *     本节点保持「未测」（非判定，绝不写成超时）；
   *   · 连不上 / 非 200 ⇒ 才是通道故障，走原有的自愈 + 连击 + 作废路径。
   *
   * 结论缓存 `CONTROLLER_ALIVE_CACHE_MS`：多个 worker 同时命中时只探一次，
   * 避免在已经过载的 controller 上再加一层健康检查流量。
   */
  private async controllerAnswers(): Promise<boolean> {
    const now: number = Date.now();
    if (this.channelAliveAtMs > 0 && now - this.channelAliveAtMs < CONTROLLER_ALIVE_CACHE_MS) {
      return this.channelAlive;
    }
    let alive: boolean = false;
    const api = this.api;
    if (api !== null) {
      try {
        const probe = await api.probeController(CONTROLLER_PROBE_TIMEOUT_MS);
        alive = probe.reachable && probe.secretAccepted;
      } catch (e) {
        AppLogger.warn(TAG, `latency controller probe error: ${AppLogger.errText(e)}`);
        alive = false;
      }
    }
    this.channelAliveAtMs = now;
    this.channelAlive = alive;
    return alive;
  }

  private async tryRecoverChannel(): Promise<void> {
    if (this.channelRecoveryTried) {
      return;
    }
    if (this.coreNotReadyStreak < CORE_NOT_READY_RECOVER_STREAK) {
      return;
    }
    this.channelRecoveryTried = true;
    const api = this.api;
    if (api === null) {
      return;
    }
    try {
      const recovered = await ConnectionOrchestrator.instance().refreshLatencyEndpoint(api);
      if (recovered) {
        AppLogger.info(TAG, 'latency channel recovered: endpoint secret re-resolved');
        this.coreNotReadyStreak = 0;
      } else {
        AppLogger.warn(TAG, 'latency channel recovery failed: core still unusable');
      }
    } catch (e) {
      AppLogger.warn(TAG, `latency channel recovery error: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * 在途闸门内的**单次**探测（修 T2 的根治点，方案 C7）。
   *
   * 三条硬约束：
   *  1. **先拿名额再发请求**：名额由应用层信号量给出（= OHOS 同 host 连接池容量
   *     LATENCY_INFLIGHT=8），超出的部分在**应用层**排队，而不是在 HTTP 栈里
   *     偷偷排队（旧实现把排队算进请求预算 → 排队请求必然客户端侧先超时 →
   *     被误判 CORE_NOT_READY → 连击作废整批 → 用户看到「测速全部失败」）。
   *  2. **排队等待不计入请求超时**：底层 connectTimeout/readTimeout 是在
   *     `req.request()` 调用时才生效的，只要拿到名额之后才发请求，等待就不在
   *     单请求预算里。
   *  3. **排队等待有上限**：超时 = 节点级**排队超时**（独立分类 QUEUE_TIMEOUT），
   *     绝不归入 CORE_NOT_READY（那是通道级故障：内核/凭证问题）。
   */
  private async gatedProbe(node: ProxyNode, generation: number): Promise<LatencyProbeResult> {
    const api = this.api;
    if (api === null) {
      return new LatencyProbeResult();
    }
    const gate: LatencyInflightGate = LatencyInflightGate.shared();
    const granted: boolean = await gate.acquire(LATENCY_QUEUE_WAIT_MAX_MS);
    if (!granted) {
      const queued: LatencyProbeResult = new LatencyProbeResult();
      queued.delayMs = -1;
      queued.failKind = LatencyProbeKind.QUEUE_TIMEOUT;
      queued.httpCode = 0;
      queued.detail = `queue wait exceeded ${LATENCY_QUEUE_WAIT_MAX_MS}ms`;
      AppLogger.warn(TAG, `latency queue timeout: node=${node.name} `
        + `waitLimit=${LATENCY_QUEUE_WAIT_MAX_MS}ms inflight=${gate.inflightCount()}`);
      return queued;
    }
    try {
      if (this.isAborted(generation)) {
        const aborted: LatencyProbeResult = new LatencyProbeResult();
        aborted.delayMs = -1;
        aborted.failKind = LatencyProbeKind.CANCELLED;
        aborted.detail = 'aborted while queued for an in-flight slot';
        return aborted;
      }
      if (Date.now() >= this.deadlineAt) {
        // 排队期间整批硬截止已到：保持「未测」，**不发请求**（发了也来不及算进结论）
        const skipped: LatencyProbeResult = new LatencyProbeResult();
        skipped.delayMs = -1;
        skipped.failKind = LatencyProbeKind.UNTESTED;
        skipped.detail = 'batch deadline reached while queued';
        return skipped;
      }
      // lanes = **同时在途的 HTTP 请求数**（LATENCY_INFLIGHT=8）—— 不是 worker 数、
      // 也不是队列深度。ClashApiService 的外层超时按 ceil(lanes/8) 自适应：
      // 8 → 1 批 → outerTimeout = timeoutMs + 1200（6.2s），正好覆盖内核 5s 预算
      // + 收尾余量；而排队等待发生在拿到名额**之前**，不占这份预算。
      // DNS 预检结论随探测一起下发：unresolved => **一次 /delay 都不发**，
      // 直接判 dns_unresolved（内核的 503 是通用句，看不到 DNS 原因）。
      return await api.testLatencyDetailed(node.name, this.url, this.timeoutMs, LATENCY_INFLIGHT,
        this.dnsVerdictFor(node));
    } finally {
      gate.release();
    }
  }

  /**
   * 探测一个节点（**含通道级故障处理**），返回内核的探测结果。
   *
   * 引擎的职责边界：**批次调度**。分类、判定（算不算「节点结论」）全在内核
   * （`LatencyKinds.ets` 的 `LatencyProbeKind`）；引擎只做三件事：
   *  1. 调内核探针（`gatedProbe` → `ClashApiService.testLatencyDetailed` →
   *     `LatencyProbe.probeOne`）；
   *  2. 通道瞬时过载时的就地重试 / 退避（见下）；
   *  3. 通道级故障的连击、自愈与整批作废（**不是节点结论**）。
   */
  private async probeThroughCore(node: ProxyNode, generation: number): Promise<LatencyProbeResult> {
    const firstProbe = await this.gatedProbe(node, generation);
    // ── 通道瞬时过载：先就地重试/退避，不要立刻把它算进「通道不可用」连击 ──
    // 死亡节点成批拨号会把 controller 打到 Operation timeout（2300028），这是过载
    // 而不是内核死亡；实测同一内核稍后仍能正常出结果。旧实现每命中一次就累加连击，
    // 3 次即作废整批 → 已盖章的真实结论被回滚、其余节点永远停在「未测」。
    // 这里最多再试 CORE_NOT_READY_RETRY_MAX 次（线性退避），任一成功即按正常流程
    // 发布结论；全部失败才交回下面的连击/中止逻辑。
    let probe = firstProbe;
    if (firstProbe.failKind === LatencyProbeKind.CORE_NOT_READY) {
      for (let attempt = 1; attempt <= CORE_NOT_READY_RETRY_MAX; attempt += 1) {
        if (this.isAborted(generation)) {
          break;
        }
        await new Promise<void>((resolve) => {
          setTimeout(() => resolve(), CORE_NOT_READY_RETRY_BACKOFF_MS * attempt);
        });
        if (this.isAborted(generation)) {
          break;
        }
        probe = await this.gatedProbe(node, generation);
        if (probe.failKind !== LatencyProbeKind.CORE_NOT_READY) {
          break;
        }
      }
    }
    if (probe.failKind === LatencyProbeKind.UNTESTED) {
      // 整批硬截止已到（排队期间耗尽）：本节点**根本没发出请求** → 保持「未测」，
      // 不发布任何结论，也不计入 finished（见 worker 里的 finished 记账）。
      return probe;
    }
    if (this.isAborted(generation)) {
      // 用户取消 / 新批次抢占 / 通道作废：本批剩余工作全部作废。
      //
      // 这里**故意不发布任何记录**（包括"已取消"），原因是一个真实竞态：
      // `start()` 抢占旧批次走的是同一个 `cancel()`，旧批次的 worker 会在
      // cancel 之后才异步拿到探测结果。如果此时写一条记录，就会盖掉**新批次**
      // 刚刚打上的 TESTING 标记 —— UI 上表现为"正在测速的节点突然变成已取消"。
      // 因此 abort 之后只计数、不落库；遗留的 TESTING 由收尾的
      // clearOwnTestingMarks() 统一收回 `--`（"我们不知道"，这是诚实的）。
      //
      // 注意：只有拿到结果后才计数（failKind !== NONE 说明这次探测确实被打断），
      // 取消瞬间刚好成功返回的探测不计入 cancelled。
      if (probe.failKind !== LatencyProbeKind.NONE) {
        this.progress.cancelled = this.progress.cancelled + 1;
      }
      return probe;
    }
    if (probe.failKind === LatencyProbeKind.CORE_NOT_READY) {
      // ① 先鉴别「控制器过载」与「通道真的没了」（2026-10-21 真机根因）。
      //    真机取证：飞鸟云 31 节点批，50 路在途把 controller 打满 → 一批 2300028 →
      //    6 连击作废整批，后 24 个节点一次都没拨号（`notReady=6 unavailable=true`）。
      //    能答 /version ⇒ 只是过载：**不计连击、不自愈、不中止**，本节点保持「未测」
      //    （非判定，绝不写成超时）。只有健康检查也失败，才进下面的通道故障路径。
      if (await this.controllerAnswers()) {
        this.progress.coreOverloaded = this.progress.coreOverloaded + 1;
        AppLogger.warn(TAG, `latency probe overloaded (controller alive): node=${node.name} `
          + `http=${probe.httpCode} elapsed=${probe.elapsedMs}ms => 不计连击、不作废整批`);
        return probe;
      }
      // 通道问题，不是节点问题。两种成因必须分开处理：
      //  - 内核中途重启 / secret 被换掉（真机实测：106 节点批测进行中隧道重启，
      //    此后 49 个节点全部连接异常）→ 重新解析隧道 secret 还能救回来；
      //  - 内核真的不在了 → 连续命中后作废整批。
      this.coreNotReadyStreak = this.coreNotReadyStreak + 1;
      this.progress.coreNotReady = this.progress.coreNotReady + 1;
      await this.tryRecoverChannel();
      if (this.isAborted(generation)) {
        return probe;
      }
      // 自愈已尝试过（或本轮不满足自愈条件）仍然连续失联 → 通道确实不可用。
      // 此时**作废整批**：剩余节点保持「未测」，页面提示"内核不可用，本轮未测"。
      // 绝不把通道故障写进任何节点的结论里 —— 这是旧实现"内核一抖半张列表变红"的根因。
      if (this.coreNotReadyStreak >= abortStreakFor(this.nodes.length)) {
        this.progress.coreUnavailable = true;
        AppLogger.warn(TAG, `latency batch aborted: core/channel unavailable `
          + `streak=${this.coreNotReadyStreak} measured=${this.progress.measured} `
          + `recoveryTried=${this.channelRecoveryTried}`);
        this.invalidate();
      }
      return probe;
    }
    this.coreNotReadyStreak = 0;
    return probe;
  }

  /**
   * 把内核的探测结果落成**节点结论**（或判定「不落」）。
   *
   * ⚠ 判定权在**内核**：只有 `LatencyProbeKind.isVerdictKind()` 认可的分类才盖章；
   * 其余（unknown / queue_timeout / cancelled / untested / core_not_ready …）
   * 一律**不落结论** ⇒ 沿用该节点上一次的有效结论（「我们不知道」不能变成「失败」，
   * 这正是本次重做要消灭的缺陷：旧口径一律压成 network_unreachable，
   * 于是内核一抖就半张列表变红）。
   *
   * @return 要落库的记录；null = 不落任何结论。
   */
  private recordFor(node: ProxyNode, probe: LatencyProbeResult): LatencyRecord | null {
    if (probe.failKind === LatencyProbeKind.UNTESTED) {
      // 整批硬截止到点：这一轮**根本没发出请求** → 不是「跳过」，是「没轮到」。
      // 不落结论、不计 skipped、不计 finished（进度条不能把「没测」算成「测完了」）。
      return null;
    }
    if (probe.failKind === LatencyProbeKind.QUEUE_TIMEOUT) {
      // 排队超时：这一轮**没拨号** → 与节点/出口无关 ⇒ 非判定：
      // 不落节点结论，也不该动 DoH pin。
      this.progress.queueTimeout = this.progress.queueTimeout + 1;
      return null;
    }
    if (probe.failKind === LatencyProbeKind.CANCELLED) {
      this.progress.cancelled = this.progress.cancelled + 1;
      return null;
    }
    if (probe.failKind === LatencyProbeKind.NONE) {
      if (LatencyPolicy.isValidDelay(probe.delayMs)) {
        this.progress.measured = this.progress.measured + 1;
        return LatencyRecord.measured(node.name, probe.delayMs, LatencyChannel.CORE, Date.now());
      }
      // 测通了但延迟非法（不该发生）⇒ 当作「认不出来」：不落结论。
      this.progress.skipped = this.progress.skipped + 1;
      AppLogger.info(TAG, `latency non-verdict response: node=${node.name} `
        + `kind=${probe.failKind} http=${probe.httpCode} => 不落节点结论（保留上次结论）`);
      return null;
    }
    if (probe.failKind === LatencyProbeKind.DNS_UNRESOLVED) {
      // **域名解析不出来**（我们自己的 DoH 预解析判定）=> 这是**节点结论**：
      // 该节点当前根本用不了（域名可能已下线），该换机场/换订阅，而不是换线路。
      // 它与 network_unreachable（拨号失败）严格分开，也不计入 coreNotReady 连击
      // —— 通道是好的，只是这个节点的域名死了。
      this.progress.failed = this.progress.failed + 1;
      this.progress.dnsUnresolved = this.progress.dnsUnresolved + 1;
      AppLogger.warn(TAG, `latency dns unresolved: node=${node.name} host=${node.server} `
        + `=> 判 ${LatencyProbeKind.DNS_UNRESOLVED}（域名可能已下线），不发起 /delay`);
      return LatencyRecord.failed(node.name, LatencyState.FAILED, Date.now(),
        LatencyChannel.CORE, LatencyProbeKind.DNS_UNRESOLVED);
    }
    if (!LatencyProbeKind.isVerdictKind(probe.failKind)) {
      // 非判定（unknown / unsupported / port_reachable_only）⇒ 不产生节点结论。
      this.progress.skipped = this.progress.skipped + 1;
      AppLogger.info(TAG, `latency non-verdict response: node=${node.name} `
        + `kind=${probe.failKind} http=${probe.httpCode} => 不落节点结论（保留上次结论）`);
      return null;
    }
    // 结论类失败：timeout / switch_failed / network_unreachable。
    // ⚠ 状态分档也由内核给口径（isTimeoutKind）—— 引擎不再自己拿 httpCode 猜。
    const state: number = LatencyProbeKind.isTimeoutKind(probe.failKind)
      ? LatencyState.TIMEOUT : LatencyState.FAILED;
    if (state === LatencyState.TIMEOUT) {
      this.progress.timeout = this.progress.timeout + 1;
      // 该节点入口域名若还挂着 DoH pin，却连握手都等不到应答，最可能是记录已轮换
      // （机场短 TTL 换绑）而 hosts pin 把内核钉在旧 IP 上。丢掉这条 pin：下一个
      // 批次重新生成配置时不再写 hosts，交由内核按 TTL 现解析。
      DoHResolver.dropPin(node.server);
    } else {
      this.progress.failed = this.progress.failed + 1;
    }
    // 失败分类必须带进记录：switch_failed（内核里没这个节点）与 timeout（真超时）
    // 在 state 上都是「失败」这一档，只有靠 failKind 才能在 UI 上区分开。
    return LatencyRecord.failed(node.name, state, Date.now(), LatencyChannel.CORE, probe.failKind);
  }


  private publish(nodeName: string, rec: LatencyRecord): void {
    // runId 写进每条已落库记录：通道故障批收尾据此认出本批盖的失败章并收回。
    // source 随批落库：auto 来源的失败 UI 显示中性「未测」，manual 保持红。
    rec.runId = this.runId;
    rec.source = this.source;
    LatencyLiveView.setRecord(rec);
    if (this.onResult !== null) {
      this.onResult(rec);
    }
  }

  private emitProgress(): void {
    this.progress.running = !this.finished && !this.cancelled;
    if (this.onProgress !== null) {
      this.onProgress(this.progress);
    }
  }
}


/**
 * 引擎：持有当前会话，保证同一时刻只有一批在跑。
 */
export class LatencyEngine {
  private static current: LatencyRun | null = null;

  /**
   * 按批大小算整批硬截止（2026-10-22：「600 节点订阅测几个就不测了」的根因）。
   *
   * 旧实现是固定 90s。600 个节点 / 在途 32 ≈ 19 波，每波最坏 5s ⇒ ≈ 95s 就把队尾
   * 全部留成「未测」——用户看到的就是「测了几个就不测了」。现在按波数估算并留 20s
   * 余量，下限仍是 90s、上限 15 分钟（防呆：别让一个坏批次把界面卡半小时）。
   */
  static deadlineForBatch(nodeCount: number): number {
    const inflight = Math.max(1, LATENCY_INFLIGHT);
    const waves = Math.ceil(Math.max(1, nodeCount) / inflight);
    const estimated = waves * (LatencyPolicy.DEFAULT_TIMEOUT_MS + 1200) + 20000;
    return Math.max(BATCH_DEADLINE_MS, Math.min(estimated, 900000));
  }


  /**
   * 启动一批测速。已有批次会被作废（其结果全部丢弃）。
   * @param api 内核通道；null 表示走离线粗略通道
   */
  static start(api: ClashApiService | null, nodes: ProxyNode[], url: string,
    opts: LatencyRunOptions): LatencyRun {
    if (LatencyEngine.current !== null) {
      LatencyEngine.current.cancel();
    }
    const run = new LatencyRun(api, nodes, url, opts.timeoutMs, opts.force,
      opts.onResult, opts.onProgress, opts.source, opts.batchDeadlineMs);
    LatencyEngine.current = run;
    return run;
  }

  /** 取消当前批次（页面退出 / 用户点取消 / 网络切换） */
  static cancelCurrent(): void {
    if (LatencyEngine.current !== null) {
      LatencyEngine.current.cancel();
    }
  }

  static isRunning(): boolean {
    return LatencyEngine.current !== null && LatencyEngine.current.isRunning();
  }

  static currentProgress(): LatencyProgress | null {
    return LatencyEngine.current === null ? null : LatencyEngine.current.currentProgress();
  }

  /** 批次结算后清理引用 */
  static release(run: LatencyRun): void {
    if (LatencyEngine.current === run) {
      LatencyEngine.current = null;
    }
  }
}

// 回收探针注册：测速批进行中阻止编排器回收无头内核（顺延而非杀核）。
// 注册在类外静态初始化，import 本模块即生效；重复注册由 includes 去重。
const recycleProbe = (): boolean => LatencyEngine.isRunning();
if (!ConnectionOrchestrator.testCoreBusyProbes.includes(recycleProbe)) {
  ConnectionOrchestrator.testCoreBusyProbes.push(recycleProbe);
}
