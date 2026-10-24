/**
 * 测速结论真源（`LatencyStore`）与进程内视图（`LatencyController`）之间的**桥**。
 *
 * ## 为什么要单独一个文件（而不是塞进 LatencyController）
 *
 * 职责切分（审计 F2/F4/LP08）：
 *  - `LatencyLiveView` = **进程内实时视图**（承载「测试中」这类瞬态、通道、
 *    来源信息），**不是**结论的落盘真源；
 *  - `LatencyStore`（commons/latency，测速内核所有）= **结论的落盘真源**
 *    （字段级：每个 (节点, 字段) 一个槽）。
 *
 * 桥放在独立文件里还有一层工程原因：`LatencyController` 是很多 Node 侧
 * 行为闸门（verify-latency-cache / -concurrency / -restore / -engine-runtime）
 * 加载的对象，它们把 `commons/services/*.ets` 暂存成扁平沙箱再 import。
 * 若 `LatencyController` 直接 import `../latency/LatencyStore`（那条链会拖进
 * `@kit.ArkData` / `@kit.NetworkKit` / AppSettings …），这些闸门的沙箱就会
 * 缺模块而红 —— 而它们要验的是**缓存与并发语义**，与落盘仓无关。
 * 现在依赖方向是单向的：`页面 → 本桥 → {LatencyController, LatencyStore}`，
 * `LatencyController` 不认识落盘仓 ✓。
 */
import { LatencyStore, PreferencesLatencyPersistence } from '../latency/LatencyStore';
import { LatencyRecord, LatencyState } from './LatencyState';
import { LatencyLiveView } from './LatencyLiveView';
import { AppLogger } from '../utils/AppLogger';

const TAG: string = 'LatencyStoreBridge';

export class LatencyStoreBridge {
  /** 落盘后端是否已就绪 */
  private static storeReady: boolean = false;

  // ── 进程内视图（过渡门面）───────────────────────────────────────────────
  //
  // 审计 B4（LP08）：**旧门面 LatencyController.ets 已删除**（页面层零引用）。
  // 实时视图搬到 `LatencyLiveView.ets`（零跨目录 import，Node 侧扁平沙箱闸门不受影响），
  // 引擎迁到落盘仓后（批次 B5/B6）这里的转发会直接换成 LatencyStore，
  // **页面代码一行都不用再改**。
  //
  // ⚠ 纪律不变：**LatencyController 不许 import ../latency/LatencyStore**。
  //   Node 侧四个行为闸门（verify-latency-cache / -concurrency / -restore /
  //   -engine-runtime）把 commons/services/*.ets 暂存成扁平沙箱再 import，
  //   一旦那条链拖进 @kit.ArkData / @kit.NetworkKit / AppSettings，沙箱就缺模块。
  //   依赖方向永远是「页面 → 本桥 → {LatencyController, LatencyStore}」。

  /** 读一条实时记录（null = 从没测过） */
  static recordFor(nodeName: string): LatencyRecord | null {
    return LatencyLiveView.recordFor(nodeName);
  }

  /** 读实时状态（TESTING / UNTESTED / MEASURED …） */
  static stateFor(nodeName: string): number {
    return LatencyLiveView.stateFor(nodeName);
  }

  /** 读实时延迟（null = 没有数值） */
  static latencyFor(nodeName: string): number | null {
    return LatencyLiveView.latencyFor(nodeName);
  }

  /** 写一条实时记录 */
  static setRecord(rec: LatencyRecord): void {
    LatencyLiveView.setRecord(rec);
  }

  /** 写一个延迟值（-2 = 未测） */
  static set(nodeName: string, latency: number): void {
    LatencyLiveView.set(nodeName, latency);
  }

  /** 冷启动恢复一条结论（带失败分类 + 真实测速时间戳） */
  static restore(nodeName: string, latency: number, failKind: string, atMs: number): void {
    LatencyLiveView.restore(nodeName, latency, failKind, atMs);
  }

  /** 标记「测试中」（瞬态，不落盘） */
  static markTesting(nodeName: string, runId: number = 0): void {
    LatencyLiveView.markTesting(nodeName, runId);
  }

  /** 只保留这些节点的结论（订阅变更时清理） */
  static retainOnly(nodeNames: string[]): void {
    LatencyLiveView.retainOnly(nodeNames);
  }

  /** 订阅实时视图变化（UI 刷新用） */
  static addListener(listener: () => void): void {
    LatencyLiveView.addListener(listener);
  }

  /** 取消订阅 */
  static removeListener(listener: () => void): void {
    LatencyLiveView.removeListener(listener);
  }

  /** 立刻通知监听者（不等合并窗口） */
  static flushNow(): void {
    LatencyLiveView.flushNow();
  }

  /**
   * 初始化落盘仓（应用启动/进页面时调一次，幂等）。
   */
  static async ensureStore(context: Context): Promise<void> {
    if (LatencyStoreBridge.storeReady) {
      return;
    }
    try {
      await PreferencesLatencyPersistence.init(context);
      LatencyStore.setBackend(new PreferencesLatencyPersistence());
      LatencyStoreBridge.storeReady = true;
    } catch (e) {
      AppLogger.warn(TAG, `latency store init failed: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * 从落盘仓恢复结论（**唯一真源**）。
   *
   * 遵守 LatencyStore 的规则：进程内已有**更新**结论时拒绝覆盖
   * （旧快照不许盖掉新的结论 —— 审计 F4 的老坑）。
   *
   * @return 恢复成功的节点名（用于判断是不是「老装机首次升级」）
   */
  static async restoreFromStore(): Promise<string[]> {
    const restored: string[] = [];
    try {
      const backend = LatencyStore.backendRef();
      const names = await backend.listNodes();
      for (const name of names) {
        const rec = await backend.loadNode(name);
        if (rec === null) {
          continue;
        }
        if (!LatencyStore.restore(name, rec)) {
          // 拒绝覆盖（进程内更新 / 非判定失败）→ 不动进程内视图
          continue;
        }
        LatencyLiveView.restore(name, rec.delayMs, rec.failKind, rec.testedAt);
        restored.push(name);
      }
    } catch (e) {
      AppLogger.warn(TAG, `latency store restore failed: ${AppLogger.errText(e)}`);
    }
    return restored;
  }

  /**
   * 把当前结论写进落盘仓（**字段级**落盘）。
   *
   * 只写**构成节点结论**的结果：
   *  - 实测值（成功）→ 结论；
   *  - 失败 → 只有「用户主动测速」且分类是判定类（真失败）才算结论；
   *    静默批（auto 来源）的失败按既定口径显示中性「未测」，**不落结论**
   *    （否则冷启动后它会变成一颗新鲜的红「超时」）；
   *  - 非判定失败（通道没就绪 / 没排上队 / 端口可达…）→ 不落结论，沿用上次有效结论。
   */
  static async persistConclusions(names: string[]): Promise<void> {
    for (const name of names) {
      const rec: LatencyRecord | null = LatencyLiveView.recordFor(name);
      if (rec === null) {
        continue;
      }
      if (rec.state === LatencyState.MEASURED || rec.state === LatencyState.OFFLINE) {
        if (LatencyStore.applyProbeResult(name, rec.delayMs, '', rec.atMs)) {
          await LatencyStore.persist(name);
        }
        continue;
      }
      if (rec.state === LatencyState.TIMEOUT || rec.state === LatencyState.FAILED) {
        if (rec.source !== 'manual') {
          continue;
        }
        if (LatencyStore.applyProbeResult(name, -1, rec.failKind, rec.atMs)) {
          await LatencyStore.persist(name);
        }
      }
    }
  }
}
