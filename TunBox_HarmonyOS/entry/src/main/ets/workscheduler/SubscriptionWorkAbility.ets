/**
 * WorkScheduler 延迟任务扩展（订阅自动刷新的后台触发器）。
 *
 * 生命周期（官方契约，见 workschedulerextensionability 文档）：
 * 系统按内存/功耗统一调度，在 repeatCycleTime 到期（约 4h 轮询）且网络可用时拉起本进程，
 * 依次回调 onWorkStart → （任务执行）→ onWorkStop。本扩展不 loadContent 任何页面，
 * onWorkStart 里直接跑一次「过期订阅刷新」然后收尾 stopWork。
 *
 * 与 SubscriptionUpdateScheduler 的关系：
 * - 调度逻辑（autoUpdateSubscription 开关、STALE_MS 过期判定、单航班闸门、
 *   refreshSubscriptionsConcurrently 复用）全部在 SubscriptionUpdateScheduler；
 * - 本扩展只是 WorkScheduler 触发点：onWorkStart → maybeRunExpiredRefresh(context, true)。
 *
 * 约束：WorkSchedulerExtensionContext 继承自 ExtensionContext，可直接传给
 * SubscriptionService.init/preferences（与 EntryAbility.context 同 App 同沙箱）。
 * onWorkStart 必须在有限时间内返回（官方建议短任务），过期检查本身是异步的：
 * 这里 fire-and-forget 启动，stopWork 立即收尾 —— 刷新批次由进程内 promise 链继续，
 * 进程存活期足够跑完（prepare 并发 2 路 + 串行落盘，与订阅页「全部刷新」同量级）。
 */
import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { Want } from '@kit.AbilityKit';
import { SubscriptionUpdateScheduler } from '../commons/services/SubscriptionUpdateScheduler';
import { SettingsService } from '../commons/services/SettingsService';
import { AppLogger } from '../commons/utils/AppLogger';

const TAG = 'SubscriptionWorkAbility';

export default class SubscriptionWorkAbility extends WorkSchedulerExtensionAbility {
  onWorkStart(work: workScheduler.WorkInfo): void {
    AppLogger.info(TAG, `onWorkStart: workId=${work?.workId}`);
    this.runRefresh(this.context);
  }

  private async runRefresh(context: Context): Promise<void> {
    try {
      // WorkScheduler runs in its own extension process; EntryAbility's async init
      // is not shared with this process.
      await SettingsService.init(context);
      const scheduler = SubscriptionUpdateScheduler.instance();
      scheduler.ensureWorkScheduled(); // isPersisted 任务被系统恢复后闸门是进程内的，补一次幂等注册
      const r = await scheduler.maybeRunExpiredRefresh(context, true);
      AppLogger.info(TAG, `work refresh done: stale=${r.stale} launched=${r.launched} `
        + `${r.skippedReason}`);
    } catch (e) {
      AppLogger.warn(TAG, `work refresh failed: ${AppLogger.errText(e)}`);
    }
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    AppLogger.info(TAG, `onWorkStop: workId=${work?.workId}`);
    // 官方建议：任务收尾时 stopWork 通知系统（isRepeat 周期任务按 repeatCycleTime 重新计时）
    try {
      workScheduler.stopWork(work);
    } catch (e) {
      AppLogger.warn(TAG, `stopWork failed: ${AppLogger.errText(e)}`);
    }
  }
}
