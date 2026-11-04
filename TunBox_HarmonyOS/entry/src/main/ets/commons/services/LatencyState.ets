/**
 * 节点延迟状态模型（延迟测试重做，5.6.0）
 *
 * 旧实现用 `Map<string, number>` + 哨兵（-1 超时 / -2 未测）表达结果，结构上
 * 无法区分「超时 / 失败 / 不可用 / 未测 / 测试中」，也没有时间戳（无法显示结果
 * 新鲜度）。真机上大量"明明只是没测过却显示超时""结果永远是几分钟前的"投诉
 * 都源于此。这里改为显式状态 + 时间戳。
 *
 * 状态语义（必须一路带到 UI / 日志 / 持久化，禁止把 FAILED 折叠成 TIMEOUT）：
 *  - MEASURED  实测延迟，ms >= 1（mihomo 成功响应里 delay 恒 >= 1，0 被内核当失败）
 *  - TIMEOUT   内核侧超时（HTTP 504 {"message":"Timeout"}）；**也包括「排队超时」**
 *               （在途闸门上等太久才轮到该节点，这一轮根本没拨号 —— 分类是
 *               `failKind = queue_timeout`，用来把「节点不通」与「没排上队」分开）
 *  - FAILED    探测失败（HTTP 503：拨号失败 / 状态码不符 / delay==0）
 *  - OFFLINE   离线粗略探测（未连接内核时的 TCP/TLS/QUIC 探活，绝不冒充代理延迟）
 *  - CANCELLED 用户取消 / 网络切换中断，**不是节点结论**
 *  - UNTESTED  从未测过
 *
 * ⚠ 状态词表**保持不变**（新增状态会波及 UI 配色/排序/持久化三处），
 * 「排队超时」靠 `failKind` 表达而不是新状态 —— 见 `LatencyRecord.failKind`。
 *
 * 纯数据 + 纯函数，无副作用，可在 ohosTest 直接驱动验证。
 */

/**
 * 延迟结果状态。
 *
 * 用 class + static readonly 而不是 `enum`：与 `LatencyFailKind` / `LatencyChannel`
 * 保持同一风格，且**可被 Node 的 type-stripping 直接执行**（离线回归套件
 * `verify-latency-cache.mjs` / `test-latency-engine.js` 就是把本文件按 .ts 暂存后
 * import 进来跑的；Node 的 strip-only 模式明确拒绝 `enum`，会报
 * ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX）。
 */
// 失败分类常量**唯一真源** = 零 import 的 LatencyKinds 模块（审计 LP04：
// 不许在本文件里再写一份分类名字面量 —— 那等于第二份副本）。
// LatencyKinds 零 import ⇒ Node 侧扁平暂存闸门照样能跑（只需把它一起暂存）。
import { LatencyProbeKind, LatencyStrategy, LatencyTimeout } from '../latency/LatencyKinds';

export class LatencyState {
  static readonly UNTESTED: number = 0;
  static readonly TESTING: number = 1;
  static readonly MEASURED: number = 2;
  static readonly TIMEOUT: number = 3;
  static readonly FAILED: number = 4;
  /**
   * 用户取消 / 网络切换中断，**不是节点结论**。
   *
   * 注意：引擎目前**不会**为单个节点落这个状态 —— abort 之后不发布任何记录
   * （否则抢占方新批次的 TESTING 标记会被旧批次盖掉），被打断的节点由
   * `LatencyEngine.clearOwnTestingMarks()` 收回 UNTESTED（UI 显示 `--`，
   * 语义是"我们不知道"）。这个状态保留在词汇表与 UI 里，供 classify()
   * 与未来需要区分"被中断"的入口使用；当前行为已由
   * scripts/verify-latency-engine-runtime.mjs 真跑确认。
   */
  static readonly CANCELLED: number = 5;
  /** 离线直连探测（粗略可达性，UI 必须与真实代理延迟区分展示） */
  static readonly OFFLINE: number = 6;
}

/** 探测通道来源（诊断与展示用） */
export class LatencyChannel {
  /** 真实内核（隧道或已加载内核的 controller）：权威结果 */
  static readonly CORE: string = 'core';
  /** 离线直连探测：仅代表服务器可达，非代理延迟 */
  static readonly OFFLINE: string = 'offline';
}

/** The complete identity of a measurement. Empty context is reserved for legacy
 * callers; scoped readers never fall back to those unproven old results. */
export class LatencyContext {
  profileId: string = '';
  revision: string = '';
  testUrl: string = '';
  expected: string = '';

  constructor(profileId: string = '', revision: string = '', testUrl: string = '', expected: string = '') {
    this.profileId = profileId;
    this.revision = revision;
    this.testUrl = testUrl.trim();
    this.expected = expected.trim();
  }

  key(name: string): string {
    return `ls3:${JSON.stringify([this.profileId, this.revision, this.testUrl, this.expected, name])}`;
  }

  static fromKey(key: string): string[] | null {
    if (!key.startsWith('ls3:')) { return null; }
    try {
      const parts = JSON.parse(key.substring(4)) as string[];
      if (!Array.isArray(parts) || parts.length !== 5) { return null; }
      for (const part of parts) { if (typeof part !== 'string') { return null; } }
      return parts;
    } catch (_e) { return null; }
  }
}

/**
 * 单个节点的延迟记录。
 *
 * `atMs` 是判定/展示新鲜度的唯一依据；`staleMs` 为结果过期阈值，超过即灰显
 * （主流客户端普遍不持久化结果，我们保留但必须让用户看出"这是旧的"）。
 */
export class LatencyRecord {
  name: string = '';
  context: LatencyContext | null = null;
  /** TESTING 所属批次；旧批收尾不得清除新批标记。非持久化字段。 */
  runId: number = 0;
  state: number = LatencyState.UNTESTED;
  /** 实测延迟；仅 MEASURED/OFFLINE 有意义，其余为 -1 */
  delayMs: number = -1;
  /** 产生该结果的时间戳（Date.now()）；UNTESTED 为 0 */
  atMs: number = 0;
  /** LatencyChannel.* */
  channel: string = LatencyChannel.CORE;
  /**
   * 结果来源：'auto'（后台/进页面静默批）| 'manual'（用户手点）。
   * auto 来源的失败（TIMEOUT/FAILED）不显红 —— 冷内核并发把慢握手节点盖假超时章，
   * 用户诉求「只是显示超时，用这个节点还能正常代理」→ 显示为中性「未测」。
   * 持久化兼容：旧记录缺字段默认 'manual'（显示不回退，保持红）。
   */
  source: string = 'manual';
  /**
   * 失败分类（LatencyFailKind.*；空串 = 无失败/未分类）。
   *
   * ⚠ 这一层**曾经把分类整个丢掉**：探测侧（ClashApiService）已经把 404（内核代理表里
   * 没有这个节点）/ 504（真超时）/ 拨号失败分好类，但记录里只留了 state（数字），
   * UI 只能按 state 渲染成「超时/失败」。结果是**「节点没进内核配置」与「节点连不上」
   * 在用户侧完全一样** —— 2026-10-19 真机：36 个 anytls 因解析丢凭据被丢弃，
   * 内核 404，UI 全红，用户以为节点坏了（节点实际可用，代理正常）。
   *
   * 现在分类一路带到 UI（stateText/recordColor）与持久化快照。
   *
   * ⚠ 2026-10-20 新增一个分类：`queue_timeout`（**节点级**「没排上队」，
   * 见 `ClashApiService.LatencyFailKind.QUEUE_TIMEOUT`）。它的 state 同为 TIMEOUT，
   * 但含义与「内核 504 的真超时」不同 —— 那一轮**根本没拨号**。
   * ✅ 已按**非判定**处理：`NodeSortPersistence.isNonVerdict` 已把 `queue_timeout`
   * 列入白名单（与 core_not_ready 同源：都只说明「测速通道/客户端侧」的事），
   * 所以排序快照会**沿用上一次有效结论**，不会把「我们自己的排队」写成节点失败
   * 把节点沉底。
   */
  failKind: string = '';

  static measured(name: string, delayMs: number, channel: string, atMs: number): LatencyRecord {
    const r = new LatencyRecord();
    r.name = name;
    r.state = channel === LatencyChannel.OFFLINE ? LatencyState.OFFLINE : LatencyState.MEASURED;
    r.delayMs = delayMs;
    r.channel = channel;
    r.atMs = atMs;
    return r;
  }

  static failed(name: string, state: number, atMs: number, channel: string = LatencyChannel.CORE,
    failKind: string = ''): LatencyRecord {
    const r = new LatencyRecord();
    r.name = name;
    r.state = state;
    r.delayMs = -1;
    r.channel = channel;
    r.atMs = atMs;
    r.failKind = failKind;
    return r;
  }

  static untested(name: string): LatencyRecord {
    const r = new LatencyRecord();
    r.name = name;
    r.state = LatencyState.UNTESTED;
    r.delayMs = -1;
    r.atMs = 0;
    return r;
  }

  /** 是否有可展示的数值 */
  hasValue(): boolean {
    return (this.state === LatencyState.MEASURED || this.state === LatencyState.OFFLINE) && this.delayMs >= 0;
  }

  /** 是否是一次结论性的失败（可用于排序与持久化） */
  isFailure(): boolean {
    return this.state === LatencyState.TIMEOUT || this.state === LatencyState.FAILED;
  }
}

/**
 * 延迟策略的**薄转调层**（2026-10-20 lead 拍板迁移）。
 *
 * ## 为什么拆
 *
 * 这个类长期是「什么都装」的杂货铺，三类完全不同的东西混在一起：
 *  1. **判定表**（isNonVerdictKind / isStale / isStaleConclusion）→ 真源在零 import 的
 *     `latency/LatencyKinds.ets`（`LatencyProbeKind`），本类只转调；
 *  2. **探测策略**（有效延迟 / 内建项 / 组过滤 / 环回地址）→ 已迁到
 *     `latency/LatencyKinds.ets` 的 `LatencyStrategy`，本类只转调；
 *  3. **超时数值**（DEFAULT_TIMEOUT_MS / MAX_TIMEOUT_MS）→ 已迁到
 *     `latency/LatencyKinds.ets` 的 `LatencyTimeout`，本类只转调。
 *
 * ⇒ 现在本类**只剩两件事**：`LatencyRecord` 级别的排序（compare/sortRank —— 它需要
 * services 层的记录类型，零 import 模块引不了）与上述三类的**转调别名**。
 * 新增/修改策略请去 `LatencyKinds.ets`，**不要在这里写第二份实现**。
 *
 * ## 保留的约定
 *  - `0ms` 不是有效延迟（mihomo 成功时 delay 恒 >= 1；0 被内核当失败返回 503）。
 *  - 失败**永不排在最前**（CMFA 的朴素升序把死节点顶到最上面，是公认的体验问题）。
 *  - CANCELLED / UNTESTED 不带结论，权重排在失败之后。
 */
export class LatencyPolicy {
  /**
   * 单节点探测超时 —— **转调别名**，真源在 `latency/LatencyKinds.ets` 的
   * `LatencyTimeout.DEFAULT_TIMEOUT_MS`（与 FlClash 默认 5s 对齐）。
   *
   * 沿革（含真机取证）见真源类注释：5000 → 3000 → 1000（被飞鸟云 35 个
   * hysteria2 节点证伪：1s 时 measured=0/timeout=31 全部误杀）→ 2500 → **5000**。
   */
  static get DEFAULT_TIMEOUT_MS(): number {
    return LatencyTimeout.DEFAULT_TIMEOUT_MS;
  }

  /** mihomo 的 timeout 用 16 位整数解析，> 32767 直接 400 —— 转调别名。 */
  static get MAX_TIMEOUT_MS(): number {
    return LatencyTimeout.MAX_TIMEOUT_MS;
  }

  /**
   * 结果视为「旧」的阈值 —— **转调别名**，唯一阈值定义在零 import 的内核分类表
   * （{@link LatencyProbeKind.STALE_MS}）。
   *
   * ⚠ 这里**不再**留第二份阈值字面量（那个「10 分钟」的数）—— 阈值只能一份
   * （审计 ND05）。改成 getter 而不是 `static readonly`，是为了让「阈值定义处」
   * 在扫描型闸门眼里只有内核那一个。
   */
  static get STALE_MS(): number {
    return LatencyProbeKind.STALE_MS;
  }

  /** 0 / 负数 / 缺失都不是有效延迟 —— **转调别名**（真源 `LatencyStrategy`）。 */
  static isValidDelay(delayMs: number): boolean {
    return LatencyStrategy.isValidDelay(delayMs);
  }

  /** 节点名是否是内建项（不可测）—— **转调别名**（真源 `LatencyStrategy`）。 */
  static isBuiltinNode(name: string): boolean {
    return LatencyStrategy.isBuiltinNode(name);
  }

  /** 服务器地址是否指向本机/内网 —— **转调别名**（真源 `LatencyStrategy`）。 */
  static isLoopbackOrLocal(server: string): boolean {
    return LatencyStrategy.isLoopbackOrLocal(server);
  }

  /** 组类型是否可测 —— **转调别名**（真源 `LatencyStrategy`）。 */
  static isTestableType(type: string): boolean {
    return LatencyStrategy.isTestableType(type);
  }

  
  /**
   * 排序权重：实测最快 → 实测较慢 → 离线探测 → 未测/取消 → 超时 → 失败。
   * 失败最后（绝不让坏节点因为"-1 最小"而排最前）。
   *
   * ⚠ 这仍是**数值状态机**的一部分（审计 LP06 想删），但 verify-latency-cache
   *   直接测它（排序口径 6 条断言）—— 删了就等于把排序语义丢在无覆盖状态。
   *   ⇒ 保留，等测速内核那侧接管排序后一起删（已向 lead 报备，由 lead 拍板）。
   */
  static sortRank(rec: LatencyRecord): number {
    if (rec.state === LatencyState.MEASURED) {
      return 0;
    }
    if (rec.state === LatencyState.OFFLINE) {
      return 1;
    }
    if (rec.state === LatencyState.UNTESTED || rec.state === LatencyState.CANCELLED) {
      return 2;
    }
    if (rec.state === LatencyState.TIMEOUT) {
      return 3;
    }
    return 4;
  }

  /**
   * 比较两个记录用于升序排序。
   * 同权重内：实测按延迟升序；失败按名称稳定排序（避免顺序抖动）。
   */
  static compare(a: LatencyRecord, b: LatencyRecord): number {
    const ra = LatencyPolicy.sortRank(a);
    const rb = LatencyPolicy.sortRank(b);
    if (ra !== rb) {
      return ra - rb;
    }
    if (ra <= 1 && a.delayMs !== b.delayMs) {
      return a.delayMs - b.delayMs;
    }
    return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0);
  }

  /**
   * 结果是否已过期（灰显提示，不删除——用户仍可参考）。
   *
   * **判定归真源**：唯一判定表 = 零 import 的内核分类表
   * {@link LatencyProbeKind.isStale}（含阈值 STALE_MS），本函数只做**转调**，
   * 不再自己判「多旧算旧」（审计：判定表只能一份）。
   *
   * 口径分工（内核表里的两条，缺一不可）：
   *  - 有时间戳 ⇒ `nowMs - testedAtMs > STALE_MS` 才算旧；
   *  - 年龄未知（atMs <= 0）且**不是**失败结论 ⇒ 不算旧（无法判断，不标「·旧」）。
   *
   * ⚠ 调用方（主题）只在**有值**的结果上问这一句 —— 「有值的旧结果」标「·旧」，
   * 失败结论的陈旧由 {@link isStaleConclusion} 走另一条分支（见那里的注释）。
   * ⇒ 这里的 `rec.hasValue()` 是**调用前提**（没测出值的东西谈不上「结果过期」），
   * 不是第二份陈旧规则；判定本身全部来自内核表。
   */
  static isStale(rec: LatencyRecord, nowMs: number): boolean {
    if (!rec.hasValue()) {
      return false;
    }
    return LatencyProbeKind.isStale(rec.atMs, nowMs, false);
  }

  /**
   * 「非判定」失败分类 —— **转调别名**。
   *
   * 唯一判定表 = 零 import 的内核分类表
   * {@link LatencyProbeKind.isNonVerdictKind}（正表/反表不得并存，审计 ND13）。
   * 本文件**不再**自带一份分类清单 —— 那是第二张判定表，新增一类失败时两处
   * 不同步 ⇒ live 路径与恢复路径结论相反。
   *
   * 非判定 = **这次失败不构成「节点通不通」的结论**（清单见内核表）：
   *  core_not_ready（通道/凭证坏了）/ queue_timeout（根本没拨号）/
   *  untested（整批硬截止）/ cancelled（主动取消）/ unsupported（协议无法离线探测）/
   *  port_reachable_only（只证明端口可达）/ unknown（认不出来的失败）。
   *
   * ⚠ **空分类（''）不在表里**（内核表与本别名同口径）：写快照时（buildAuto）
   * 空分类 = 一次「没有分类的真实失败」，它是节点结论，必须写进快照；空分类只在
   * **恢复**路径上被当成「非结论」—— 快照里唯一会写出空分类失败的地方是**旧版
   * 自动切换记账**（它把一次连接失败写成 latency=-1 且不带分类），见
   * LatencyLiveView.restore。
   *
   * ⚠ 这些类别**绝不能**在冷启动恢复时渲染成红色的「超时」—— 2026-10-20 真机
   * 用户反馈「刚打开软件还没测速就显示超时，测完发现这个节点是好的」。
   */
  static isNonVerdictKind(failKind: string): boolean {
    return LatencyProbeKind.isNonVerdictKind(failKind);
  }

  /**
   * 失败结论是否已陈旧（冷启动恢复的上一轮结论用它决定要不要标「·旧」）。
   *
   * **判定归真源**：转调零 import 的内核分类表 {@link LatencyProbeKind.isStale}
   * （isFailure = true 这一支），本函数不自己判（审计：判定表只能一份）。
   *
   * ⚠⚠ **必须保住的那条规则**：**年龄未知（testedAtMs <= 0）的失败结论 ⇒ 算陈旧**。
   * 2026-10-20 真机反馈「刚打开软件还没测速就显示一颗红『超时』、测完发现这个
   * 节点是好的」的**防线**：不知道多久以前的失败，绝不能当成本次刚测出来的结论
   * 顶在列表上。内核表的 `isStale(testedAtMs, nowMs, isFailure=true)` 里
   * 「testedAtMs <= 0 ⇒ return isFailure」这一支就是这条防线 —— **别把它删掉**。
   */
  static isStaleConclusion(rec: LatencyRecord, nowMs: number): boolean {
    if (!rec.isFailure()) {
      return false;
    }
    return LatencyProbeKind.isStale(rec.atMs, nowMs, true);
  }

}
