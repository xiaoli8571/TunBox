/**
 * 测速**进程内实时视图**（原 LatencyController，审计 LP08 迁到这里）。
 *
 * ⚠ 这不是「结论真源」：结论的落盘真源是 `commons/latency/LatencyStore`（字段级
 *   落盘仓），本文件只承载**瞬态**：测试中标记、通道、来源、以及 UI 的订阅通知。
 *   页面层统一走 `LatencyStoreBridge`（它同时暴露本视图与落盘仓）✓。
 *
 * ⚠ **本文件必须保持「零跨目录 import」**：Node 侧四个行为闸门
 *   （verify-latency-cache / -concurrency / -restore / -engine-runtime）把它
 *   暂存成扁平沙箱再 import —— 一旦这里拖进 ../latency/*（那条链带 @kit.ArkData /
 *   @kit.NetworkKit / AppSettings），沙箱就缺模块而红。
 *
 * 延迟结果存储（重做版）
 *
 * 旧版是 `Map<string, number>`：只能放一个数字，于是超时写成 -1、未测写成 -2，
 * 既丢失了「失败 vs 超时 vs 未测」的区别，也没有时间戳。UI 只能把 -1/-2 一律
 * 渲染成「超时」，用户看到的就是"明明没测过却显示超时""数字永远不变旧"。
 *
 * 现在存 `LatencyRecord`（状态 + 延迟 + 时间戳 + 通道）。为兼容既有调用点
 * （HomePage / NodeCard / LogicTest），保留数字入口 `set()` 与 `latencyFor()`：
 *  - `set(name, -1)` → TIMEOUT（旧语义）
 *  - `set(name, -2)` → UNTESTED（旧语义）
 *  - `set(name, >=1)` → MEASURED
 * 新代码一律用 `setRecord()` / `recordFor()`。
 *
 * 性能约束不变：批量测速每个节点都会写一次，若每次都同步通知监听者，节点页会随
 * 每条结果重建整张列表（106 个节点即 106 次重排）。这里把通知合并到最多每 200ms
 * 一次，仅压缩刷新频率，数值本身不丢。
 */
import { LatencyChannel, LatencyPolicy, LatencyRecord, LatencyState } from './LatencyState';

const NOTIFY_COALESCE_MS = 200;

export class LatencyLiveView {
  private static map: Map<string, LatencyRecord> = new Map<string, LatencyRecord>();
  private static listeners: (() => void)[] = [];
  /** 待触发的合并通知定时器；-1 表示当前没有挂起的通知 */
  private static notifyTimer: number = -1;

  /**
   * 批次 runId 的**唯一发号器**（2026-10-24 P1 修复）。
   *
   * 两个引擎（LatencyEngine / FlclashLatencyService）曾经各自维护从 1 起的独立
   * 计数器，而 isTestingOwnedBy 按裸数值判定标记所有权 —— 两计数器撞号时，旧批
   * 收尾会把新批同节点上的 TESTING 标记误清成 UNTESTED（正在测的行转圈消失、
   * 旧延迟值永久丢成 --）。发号器收敛到 runId 的唯一消费者（本类）后，
   * 进程内任何两次取号必然不同值，撞号在结构上不再可能。
   */
  private static runIdSeq: number = 0;

  static nextRunId(): number {
    LatencyLiveView.runIdSeq = LatencyLiveView.runIdSeq + 1;
    return LatencyLiveView.runIdSeq;
  }

  /** 完整记录（新代码入口） */
  static recordFor(nodeName: string): LatencyRecord | null {
    const v = LatencyLiveView.map.get(nodeName);
    return v === undefined ? null : v;
  }

  /** 状态（缺省 = UNTESTED，绝不缺省成"超时"） */
  static stateFor(nodeName: string): number {
    const v = LatencyLiveView.map.get(nodeName);
    return v === undefined ? LatencyState.UNTESTED : v.state;
  }

  /**
   * 该节点的 TESTING 标记是否属于指定批次。
   *
   * 收尾方据此避免误清新批：runId 不匹配说明这条转圈是**别人**打上的。
   * runId===0 表示调用方未参与代次管理（旧调用点），退回"只看状态"的宽松语义。
   */
  static isTestingOwnedBy(nodeName: string, runId: number): boolean {
    const v = LatencyLiveView.map.get(nodeName);
    if (v === undefined || v.state !== LatencyState.TESTING) {
      return false;
    }
    return runId === 0 || v.runId === 0 || v.runId === runId;
  }

  /**
   * 兼容视图：数值延迟。
   * MEASURED/OFFLINE → 延迟；TIMEOUT/FAILED → -1；其余（未测/测试中/取消）→ null。
   */
  static latencyFor(nodeName: string): number | null {
    const v = LatencyLiveView.map.get(nodeName);
    if (v === undefined) {
      return null;
    }
    if (v.state === LatencyState.MEASURED || v.state === LatencyState.OFFLINE) {
      return v.delayMs;
    }
    if (v.state === LatencyState.TIMEOUT || v.state === LatencyState.FAILED) {
      return -1;
    }
    return null;
  }

  /** 写入完整记录 */
  static setRecord(rec: LatencyRecord): void {
    LatencyLiveView.map.set(rec.name, rec);
    LatencyLiveView.scheduleNotify();
  }

  /**
   * 标记为「测试中」（UI 显示 spinner；不覆盖已有数值，直到新结果落地）。
   *
   * runId 记录这条 TESTING 属于哪一批：抢占/取消时旧批次只允许收回**自己**
   * 打上的标记。否则同一节点的旧批次收尾会把新批次的转圈清成 `--`，
   * 用户看到"正在测速的行突然变成未测"。
   */
  static markTesting(nodeName: string, runId: number = 0): void {
    const existing = LatencyLiveView.map.get(nodeName);
    const rec = new LatencyRecord();
    rec.name = nodeName;
    rec.runId = runId;
    rec.state = LatencyState.TESTING;
    rec.delayMs = -1;
    rec.atMs = 0;
    rec.channel = existing === undefined ? LatencyChannel.CORE : existing.channel;
    LatencyLiveView.map.set(nodeName, rec);
    LatencyLiveView.scheduleNotify();
  }

  /**
   * **从持久化快照恢复**一条延迟记录（冷启动时用）。
   *
   * ⚠ 与 `set(name, latency)` 的区别 —— 这是 2026-10-20 真机用户反馈
   * 「刚打开软件还没测速，就显示超时；测完发现这个节点是好的」的根因修复：
   *
   *  1. `set()` 只收一个数字 → **失败分类（failKind）被丢掉**，
   *     「自动切换记账写的失败」「测速通道故障（core_not_ready）」「根本没拨号
   *     （queue_timeout）」全被压成同一种红色的「超时」。
   *  2. `set()` 用 `Date.now()` 打时间戳 → **上一轮的旧结论被伪装成本次刚测出来的**。
   *
   * 这里的口径：
   *  - 有数值 → 恢复成实测值，时间戳用**快照的真实测速时间**（于是超过 10 分钟
   *    自然显示「123ms·旧」）；
   *  - 失败且属于**非判定**（含空分类 = 旧版自动切换记账）→ 恢复成「未测」
   *    （显示 `--`），因为它根本不是节点通不通的结论；
   *  - 失败且是真实结论 → 恢复成失败记录，保留分类与真实时间戳，
   *    过期后由 UI 标「·旧」并灰显（不是顶着一颗新鲜的红「超时」）。
   *
   * @param latency 快照里的延迟：>=1 实测毫秒 / -1 失败 / -2 未测
   * @param failKind 失败分类（LatencyFailKind.*，空串 = 无分类）
   * @param atMs 该批次的真实时间戳（快照的 testedAt；<=0 = 年龄未知）
   */
  static restore(nodeName: string, latency: number, failKind: string, atMs: number): void {
    if (latency >= 1) {
      LatencyLiveView.setRecord(
        LatencyRecord.measured(nodeName, latency, LatencyChannel.CORE, atMs));
      return;
    }
    if (latency === -1) {
      if (failKind.length === 0 || LatencyPolicy.isNonVerdictKind(failKind)) {
        // 非结论失败 → 回到「未测」，绝不显示成红色「超时」。
        // 空分类（''）：快照里唯一会写出「不带分类的失败」的地方是**旧版自动切换
        // 记账**（一次连接失败被写成 latency=-1）—— 那不是测速结论。
        // 测速路径写进快照的失败**一定**带分类（见 NodeSelectionPage.toPersistRecord），
        // 所以这里把 '' 判成非结论是安全的（方向也是保守的：宁可显示「--」，
        // 也不显示假的「超时」）。
        LatencyLiveView.setRecord(LatencyRecord.untested(nodeName));
        return;
      }
      // 真实失败结论：保留分类（switch_failed → 显示「未生效」，其余 → 超时/失败）
      const state: number = failKind === 'timeout' ? LatencyState.TIMEOUT : LatencyState.FAILED;
      LatencyLiveView.setRecord(
        LatencyRecord.failed(nodeName, state, atMs, LatencyChannel.CORE, failKind));
      return;
    }
    LatencyLiveView.setRecord(LatencyRecord.untested(nodeName));
  }

  /** 兼容入口：数字 → 记录 */
  static set(nodeName: string, latency: number): void {
    if (latency >= 1) {
      LatencyLiveView.setRecord(
        LatencyRecord.measured(nodeName, latency, LatencyChannel.CORE, Date.now()));
      return;
    }
    if (latency === 0 || latency === -1) {
      LatencyLiveView.setRecord(
        LatencyRecord.failed(nodeName, LatencyState.TIMEOUT, Date.now()));
      return;
    }
    // -2（旧"未测"）及其它：回到未测，不盖章成失败
    LatencyLiveView.setRecord(LatencyRecord.untested(nodeName));
  }

  static clearAll(): void {
    LatencyLiveView.map.clear();
    LatencyLiveView.scheduleNotify();
  }

  /** 全部记录快照（排序/持久化用） */
  static snapshot(): LatencyRecord[] {
    const out: LatencyRecord[] = [];
    for (const rec of LatencyLiveView.map.values()) {
      out.push(rec);
    }
    return out;
  }

  /**
   * 丢弃当前订阅已不存在节点的延迟，避免订阅反复刷新或换源后 Map 常驻增长。
   * 只有确实删除条目时才通知，因而可安全地在列表重建路径调用。
   */
  static retainOnly(nodeNames: string[]): void {
    const active = new Set<string>(nodeNames);
    let changed = false;
    for (const name of LatencyLiveView.map.keys()) {
      if (!active.has(name)) {
        LatencyLiveView.map.delete(name);
        changed = true;
      }
    }
    if (changed) {
      LatencyLiveView.scheduleNotify();
    }
  }

  static addListener(listener: () => void): void {
    if (LatencyLiveView.listeners.indexOf(listener) < 0) {
      LatencyLiveView.listeners.push(listener);
    }
  }

  static removeListener(listener: () => void): void {
    const index = LatencyLiveView.listeners.indexOf(listener);
    if (index >= 0) {
      LatencyLiveView.listeners.splice(index, 1);
    }
  }

  /** 合并窗口内的通知调度：已有挂起定时器则不再排新的（O(1) 合并） */
  private static scheduleNotify(): void {
    if (LatencyLiveView.notifyTimer >= 0) {
      return;
    }
    LatencyLiveView.notifyTimer = setTimeout((): void => {
      LatencyLiveView.notifyTimer = -1;
      LatencyLiveView.notify();
    }, NOTIFY_COALESCE_MS);
  }

  /** 立即刷新（批次结束/进入页面恢复快照后调用，避免最后一批结果延迟 200ms 才显示） */
  static flushNow(): void {
    if (LatencyLiveView.notifyTimer >= 0) {
      clearTimeout(LatencyLiveView.notifyTimer);
      LatencyLiveView.notifyTimer = -1;
    }
    LatencyLiveView.notify();
  }

  /** 是否有挂起的合并通知（专项验证用） */
  static hasPendingNotify(): boolean {
    return LatencyLiveView.notifyTimer >= 0;
  }

  static notify(): void {
    for (const l of LatencyLiveView.listeners) {
      l();
    }
  }

}
