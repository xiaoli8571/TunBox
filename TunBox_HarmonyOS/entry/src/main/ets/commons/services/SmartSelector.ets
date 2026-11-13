/**
 * 智能选点与故障切换（纯逻辑，自包含服务，第二阶段）
 *
 * 背景:
 *   现有 NodeSortPersistence 只做「按延迟排序」的一次性快照，没有考虑连续失败、
 *   近期成功率与冷却，也没有任何「什么时候该切、切到哪、切完多久不许再切」的判定，
 *   结果是：节点挂了要等人工重测，或在网络抖动时反复横跳（切换风暴）。
 *
 * 本模块只负责**决策**，不含任何 IO / 定时器 / SDK 调用：
 *   评分(scoreOf) → 排序(rankNodes) → 下一个最优(nextBestNode)
 *   → 是否允许切换(failoverAllowed) → 状态迁移(markSuccess / markFailure)
 *
 * 硬性约束:
 *   1) 确定性：同一输入必得同一输出（排序用原始下标做稳定 tie-break）。
 *   2) 无副作用：mark* 返回**新对象**，绝不原地修改入参。
 *   3) 无 Date.now 依赖：所有时间由调用方以 nowMs 传入，便于单测与重放。
 *   4) 防抖：阈值 + 冷却 + 切换迟滞(switchMargin) 三层，杜绝切换风暴。
 *   5) 所有参数可配置且有合理默认值（SelectorOptions）。
 *
 * 与既有模块的关系:
 *   NodeCandidate 的字段直接对齐 NodeSortPersistence.NodeLatencyRecord
 *   （latency / failCount / lastOk），成功率派生规则也沿用其 1/(1+failCount) 语义，
 *   集成层可直接映射，无需重复造轮子。
 */

/** 未测/不支持离线测试的延迟哨兵（沿用 NodeSortPersistence 语义） */
export const LATENCY_UNTESTED: number = -2;
/** 失败的延迟哨兵 */
export const LATENCY_FAILED: number = -1;
/** 成功率未知的哨兵 */
export const SUCCESS_RATE_UNKNOWN: number = -1;
/** 成功率未知时的中性假设（不奖不罚） */
export const SUCCESS_RATE_NEUTRAL: number = 0.5;
/** 成功一次的成功率增进步长（EWMA α） */
export const SUCCESS_RATE_ALPHA: number = 0.5;
/** 失败一次的成功率衰减步长 */
export const FAILURE_RATE_ALPHA: number = 0.5;
/** 智能选点批量探测的并发上限常量 */
export const MAX_SELECT_CONCURRENCY: number = 4;

/** 单个候选节点及其运行期统计 */
export class NodeCandidate {
  /** 节点名（Clash 侧唯一键） */
  name: string = '';
  /** 延迟 ms：>=0 成功；LATENCY_FAILED(-1) 失败；LATENCY_UNTESTED(-2) 未测 */
  latency: number = LATENCY_UNTESTED;
  /** 连续失败次数 */
  consecutiveFailures: number = 0;
  /** 近期成功率 0..1；SUCCESS_RATE_UNKNOWN(-1) 表示未知 */
  recentSuccessRate: number = SUCCESS_RATE_UNKNOWN;
  /** 上次成功时间戳（ms）；0 = 从未成功 */
  lastSuccessAt: number = 0;
  /** 冷却截止时间戳（ms）；0 = 无冷却 */
  cooldownUntil: number = 0;
  /** 协议标识（vless/vmess/trojan/hysteria2/ss/ssr 或 ''），仅透传用于展示 */
  protocol: string = '';

  /** 深拷贝（纯函数返回值用） */
  copy(): NodeCandidate {
    const n = new NodeCandidate();
    n.name = this.name;
    n.latency = this.latency;
    n.consecutiveFailures = this.consecutiveFailures;
    n.recentSuccessRate = this.recentSuccessRate;
    n.lastSuccessAt = this.lastSuccessAt;
    n.cooldownUntil = this.cooldownUntil;
    n.protocol = this.protocol;
    return n;
  }

  static make(name: string, latency: number): NodeCandidate {
    const n = new NodeCandidate();
    n.name = name;
    n.latency = latency;
    return n;
  }

  static of(name: string, latency: number, consecutiveFailures: number, recentSuccessRate: number,
    lastSuccessAt: number, cooldownUntil: number): NodeCandidate {
    const n = new NodeCandidate();
    n.name = name;
    n.latency = latency;
    n.consecutiveFailures = consecutiveFailures;
    n.recentSuccessRate = recentSuccessRate;
    n.lastSuccessAt = lastSuccessAt;
    n.cooldownUntil = cooldownUntil;
    return n;
  }

  /**
   * 由「延迟 + 失败次数 + 上次是否成功」派生近期成功率，
   * 语义与 NodeSortPersistence.NodeLatencyRecord.recentSuccessRate() 一致：
   *   未测(-2) → -1（未知）；上次失败 → 0；否则 1/(1+连续失败次数)。
   */
  static deriveSuccessRate(latency: number, failCount: number, lastOk: boolean): number {
    if (latency === LATENCY_UNTESTED) {
      return SUCCESS_RATE_UNKNOWN;
    }
    if (!lastOk) {
      return 0;
    }
    return 1 / (1 + failCount);
  }

  /** 由既有测速统计直接构造（集成层从 NodeSortSnapshot 映射时的入口） */
  static fromStats(name: string, latency: number, failCount: number, lastOk: boolean,
    lastSuccessAt: number, cooldownUntil: number): NodeCandidate {
    return NodeCandidate.of(name, latency, failCount,
      NodeCandidate.deriveSuccessRate(latency, failCount, lastOk), lastSuccessAt, cooldownUntil);
  }
}

/** 选点与切换参数（全部可配置，含合理默认值） */
export class SelectorOptions {
  /** 连续失败达到该次数即认为节点失效（触发切换） */
  failThreshold: number = 3;
  /** 失效后对该节点的冷却时长（ms）——防抖，避免刚切走又切回 */
  cooldownMs: number = 60000;
  /** 是否允许自动切换（false → nextBestNode / failoverAllowed 恒为「不切」） */
  autoSwitch: boolean = true;
  /** 每一次连续失败在评分上的惩罚（ms 等价） */
  failPenalty: number = 400;
  /** 未测节点的等效延迟（ms） */
  unknownLatency: number = 500;
  /** 失败节点的等效延迟（ms） */
  failedLatency: number = 2000;
  /** 成功率权重：成功率差 1.0 折算成该毫秒惩罚 */
  successWeight: number = 300;
  /** 处于冷却期的固定惩罚（ms 等价）——保证冷却节点几乎不可能被选中 */
  cooldownPenalty: number = 5000;
  /** 距上次成功超过该时长即视为陈旧，追加惩罚 */
  staleAfterMs: number = 1800000;
  /** 陈旧惩罚（ms 等价） */
  stalePenalty: number = 200;
  /** 切换迟滞：新节点评分必须优于当前至少该值才切换（防抖） */
  switchMargin: number = 30;
  /** 批量探测并发上限（与 MAX_SELECT_CONCURRENCY 常量同源，可覆盖） */
  maxConcurrency: number = MAX_SELECT_CONCURRENCY;

  static defaults(): SelectorOptions {
    return new SelectorOptions();
  }

  copy(): SelectorOptions {
    const o = new SelectorOptions();
    o.failThreshold = this.failThreshold;
    o.cooldownMs = this.cooldownMs;
    o.autoSwitch = this.autoSwitch;
    o.failPenalty = this.failPenalty;
    o.unknownLatency = this.unknownLatency;
    o.failedLatency = this.failedLatency;
    o.successWeight = this.successWeight;
    o.cooldownPenalty = this.cooldownPenalty;
    o.staleAfterMs = this.staleAfterMs;
    o.stalePenalty = this.stalePenalty;
    o.switchMargin = this.switchMargin;
    o.maxConcurrency = this.maxConcurrency;
    return o;
  }
}

/**
 * 纯函数：参数归一化 —— 未传用默认值，非法值夹到安全范围。
 * 保证后续所有纯函数对垃圾输入也是确定且安全的。
 */
export function normalizeOptions(opts?: SelectorOptions): SelectorOptions {
  const o = opts === undefined || opts === null ? new SelectorOptions() : opts.copy();
  if (!(o.failThreshold >= 1)) {
    o.failThreshold = 1;
  }
  if (o.failThreshold > 1000) {
    o.failThreshold = 1000;
  }
  if (!(o.cooldownMs >= 0)) {
    o.cooldownMs = 0;
  }
  if (!(o.failPenalty >= 0)) {
    o.failPenalty = 0;
  }
  if (!(o.unknownLatency >= 0)) {
    o.unknownLatency = 0;
  }
  if (!(o.failedLatency >= 0)) {
    o.failedLatency = 0;
  }
  if (!(o.successWeight >= 0)) {
    o.successWeight = 0;
  }
  if (!(o.cooldownPenalty >= 0)) {
    o.cooldownPenalty = 0;
  }
  if (!(o.staleAfterMs >= 0)) {
    o.staleAfterMs = 0;
  }
  if (!(o.stalePenalty >= 0)) {
    o.stalePenalty = 0;
  }
  if (!(o.switchMargin >= 0)) {
    o.switchMargin = 0;
  }
  if (!(o.maxConcurrency >= 1)) {
    o.maxConcurrency = 1;
  }
  return o;
}

/** 节点是否处于冷却期 */
export function isInCooldown(c: NodeCandidate, nowMs: number): boolean {
  return c.cooldownUntil > nowMs;
}

/** 节点是否仍可参与选点（未冷却且连续失败未达阈值） */
export function isEligible(c: NodeCandidate, nowMs: number, opts?: SelectorOptions): boolean {
  const o = normalizeOptions(opts);
  if (isInCooldown(c, nowMs)) {
    return false;
  }
  return c.consecutiveFailures < o.failThreshold;
}

/**
 * 纯函数：综合评分（**越小越好**，单位 ms 等价）。
 * 评分 = 延迟基值 + 成功率惩罚 + 连续失败惩罚 + 冷却惩罚 + 陈旧惩罚
 *  - 延迟基值：成功 → 实际延迟；未测 → unknownLatency；失败 → failedLatency
 *  - 成功率惩罚：(1 - rate) * successWeight；rate 未知按中性 0.5
 *  - 连续失败惩罚：consecutiveFailures * failPenalty
 *  - 冷却惩罚：cooldownPenalty + 剩余冷却毫秒（冷却越久越不会被选中）
 *  - 陈旧惩罚：距上次成功超过 staleAfterMs（且曾成功过）→ stalePenalty
 */
export function scoreOf(c: NodeCandidate, nowMs: number, opts?: SelectorOptions): number {
  const o = normalizeOptions(opts);
  let base: number;
  if (c.latency === LATENCY_UNTESTED) {
    base = o.unknownLatency;
  } else if (c.latency < 0) {
    base = o.failedLatency;
  } else {
    base = c.latency;
  }
  const rate = c.recentSuccessRate >= 0 ? c.recentSuccessRate : SUCCESS_RATE_NEUTRAL;
  let score = base + (1 - rate) * o.successWeight;
  if (c.consecutiveFailures > 0) {
    score = score + c.consecutiveFailures * o.failPenalty;
  }
  if (c.cooldownUntil > nowMs) {
    score = score + o.cooldownPenalty + (c.cooldownUntil - nowMs);
  }
  if (c.lastSuccessAt > 0 && nowMs - c.lastSuccessAt > o.staleAfterMs) {
    score = score + o.stalePenalty;
  }
  return score;
}

/** 排序结果项（保留原始下标，便于稳定 tie-break 与回取候选） */
export class RankedNode {
  name: string = '';
  /** 综合评分，越小越好 */
  score: number = 0;
  /** 在输入列表中的原始下标 */
  index: number = 0;
  /** 是否处于冷却期 */
  inCooldown: boolean = false;
  /** 是否可参与选点 */
  eligible: boolean = false;
}

/**
 * 纯函数：排序（评分升序）。
 * 评分相同按原始下标升序 → 确定性、稳定，绝不因排序改变同分节点相对次序。
 */
export function rankNodes(list: NodeCandidate[], nowMs: number, opts?: SelectorOptions): RankedNode[] {
  const o = normalizeOptions(opts);
  const out: RankedNode[] = [];
  for (let i = 0; i < list.length; i++) {
    const c = list[i];
    const r = new RankedNode();
    r.name = c.name;
    r.index = i;
    r.score = scoreOf(c, nowMs, o);
    r.inCooldown = isInCooldown(c, nowMs);
    r.eligible = isEligible(c, nowMs, o);
    out.push(r);
  }
  out.sort((a: RankedNode, b: RankedNode): number => {
    if (a.score !== b.score) {
      return a.score - b.score;
    }
    return a.index - b.index;
  });
  return out;
}

/** 纯函数：排序后的节点名列表（UI 直接可用） */
export function orderedNames(list: NodeCandidate[], nowMs: number, opts?: SelectorOptions): string[] {
  const ranked = rankNodes(list, nowMs, opts);
  const names: string[] = [];
  for (const r of ranked) {
    names.push(r.name);
  }
  return names;
}

/**
 * 纯函数：下一个最优节点（不切换则返回 null）。
 *   - autoSwitch=false            → null（用户锁定当前节点）
 *   - 无候选 / 无可用候选          → null
 *   - cur=null                    → 返回最优可用节点（首次选择）
 *   - 最优就是 cur                → null
 *   - cur 连续失败已达阈值         → 立即返回最优节点（无需迟滞）
 *   - 否则要求 最优评分 + switchMargin <= cur 评分 才切换（迟滞，防抖）
 */
export function nextBestNode(cur: NodeCandidate | null, list: NodeCandidate[], nowMs: number,
  opts?: SelectorOptions): NodeCandidate | null {
  const o = normalizeOptions(opts);
  if (!o.autoSwitch) {
    return null;
  }
  if (list.length === 0) {
    return null;
  }
  const ranked = rankNodes(list, nowMs, o);
  let bestIndex = -1;
  let bestScore = 0;
  for (const r of ranked) {
    if (r.eligible) {
      bestIndex = r.index;
      bestScore = r.score;
      break;
    }
  }
  if (bestIndex < 0) {
    return null;
  }
  const best = list[bestIndex];
  if (cur === null) {
    return best;
  }
  if (cur.name === best.name) {
    return null;
  }
  if (cur.consecutiveFailures >= o.failThreshold) {
    return best;
  }
  const curScore = scoreOf(cur, nowMs, o);
  if (bestScore + o.switchMargin <= curScore) {
    return best;
  }
  return null;
}

/**
 * 纯函数：是否允许故障切换（阈值 + 冷却，防抖）。
 *   - autoSwitch=false                    → false
 *   - consecutiveFailures < failThreshold → false（没到阈值，继续忍）
 *   - cur 仍在冷却期                       → false（刚切过，不许再切，防抖核心）
 *   - 其余                                 → true
 */
export function failoverAllowed(cur: NodeCandidate | null, consecutiveFailures: number,
  nowMs: number, opts?: SelectorOptions): boolean {
  const o = normalizeOptions(opts);
  if (!o.autoSwitch) {
    return false;
  }
  if (consecutiveFailures < o.failThreshold) {
    return false;
  }
  if (cur !== null && cur.cooldownUntil > nowMs) {
    return false;
  }
  return true;
}

/**
 * 纯函数：成功一次的状态迁移（返回新对象，入参不变）。
 *   - 连续失败清零
 *   - 成功率 EWMA 上调：未知 → 1.0；否则 rate + (1-rate)*α，上限 1
 *   - lastSuccessAt = nowMs
 *   - 冷却清零
 *   - 之前是失败哨兵(-1)的延迟回退为「未测」(-2)，避免继续用陈旧失败值排序
 */
export function markSuccess(c: NodeCandidate, nowMs: number): NodeCandidate {
  const n = c.copy();
  n.consecutiveFailures = 0;
  if (c.recentSuccessRate < 0) {
    n.recentSuccessRate = 1;
  } else {
    const next = c.recentSuccessRate + (1 - c.recentSuccessRate) * SUCCESS_RATE_ALPHA;
    n.recentSuccessRate = next > 1 ? 1 : next;
  }
  n.lastSuccessAt = nowMs;
  n.cooldownUntil = 0;
  if (n.latency < 0) {
    n.latency = LATENCY_UNTESTED;
  }
  return n;
}

/**
 * 纯函数：失败一次的状态迁移（返回新对象，入参不变）。
 *   - 连续失败 +1
 *   - 延迟记为失败哨兵(-1)
 *   - 成功率衰减：未知 → 0；否则 rate * (1-α)
 *   - 连续失败达阈值 → cooldownUntil = nowMs + cooldownMs（进入冷却，防抖）
 */
export function markFailure(c: NodeCandidate, nowMs: number, opts?: SelectorOptions): NodeCandidate {
  const o = normalizeOptions(opts);
  const n = c.copy();
  n.consecutiveFailures = c.consecutiveFailures + 1;
  n.latency = LATENCY_FAILED;
  if (c.recentSuccessRate < 0) {
    n.recentSuccessRate = 0;
  } else {
    n.recentSuccessRate = c.recentSuccessRate * (1 - FAILURE_RATE_ALPHA);
  }
  n.lastSuccessAt = c.lastSuccessAt;
  n.cooldownUntil = n.consecutiveFailures >= o.failThreshold ? nowMs + o.cooldownMs : 0;
  return n;
}

/**
 * 纯函数：批量探测时的并发上限（与 MAX_SELECT_CONCURRENCY 常量/选项取小），
 * 供集成层切片调度使用。恒 >= 1。
 */
export function selectConcurrency(opts?: SelectorOptions): number {
  const o = normalizeOptions(opts);
  const c = o.maxConcurrency < MAX_SELECT_CONCURRENCY ? o.maxConcurrency : MAX_SELECT_CONCURRENCY;
  return c >= 1 ? c : 1;
}
