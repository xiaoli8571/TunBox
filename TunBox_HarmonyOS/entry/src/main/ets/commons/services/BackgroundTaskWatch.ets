/**
 * 长时任务取消 / 暂停监听 + **取消原因分类**（官方 backgroundTaskManager）。
 *
 * ── 为什么必须有"分类"这一层 ────────────────────────────────────────────
 * 官方《Background Tasks Kit 接入规范》把下面两条列为**违规行为**：
 *   · 用户主动停止（通过删除长时任务通知、删除 AVSession 通知等方式）并取消长时
 *     任务后，**立即再次申请长时任务**；
 *   · 在系统检测到应用不合理使用长时任务，并取消/暂停长时任务后，
 *     **不得立即再次申请长时任务**。
 * 处罚：严重影响 → 立刻在违规场景禁止使用长时任务；轻微影响 → 7 个自然日内整改，
 * 否则禁止。
 *
 * SDK 之所以提供 `ContinuousTaskCancelInfo.reason`（API 15+）与
 * `ContinuousTaskSuspendInfo.suspendReason`（API 20+），正是为了让应用区分
 * 「用户主动停止」与「系统判定为不合理使用」这两种必须抑制重申请的情形。
 * 改造前本工程的做法是「取消后 1 秒无条件重挂」，同时命中上面两条红线。
 *
 * ── 本模块做三件事 ──────────────────────────────────────────────────────
 *   1) 分类：把 SDK 原因码翻译成「允许重挂吗 / 要退避多久 / 要不要用户显式操作」；
 *   2) 清账：进度心跳止损 + UiGuardian 记账刷新（registered / 抑制态 / 最早可重挂时间）；
 *   3) 广播：把分类结论交给监听者（QuickToggleAbility），由监听者按结论决定是否重挂。
 *
 * 本模块**不自己申请长时任务**（申请必须用 UIAbility 上下文，见
 * UiGuardian.applyContinuousTask —— 全工程唯一调用 startBackgroundRunning 的地方）。
 *
 * 注册点：EntryAbility.onCreate / QuickToggleAbility.onCreate（同进程，幂等）。
 */
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import { AppLogger } from '../utils/AppLogger';
import { UiGuardian } from './UiGuardian';
import { TaskProgressUpdater } from './TaskProgressUpdater';

const TAG = 'BackgroundTaskWatch';

/**
 * 长时任务取消 / 暂停的**分类结论**。
 *
 * 语义严格对应《Background Tasks Kit 接入规范》的两条违规红线：
 *  - USER_STOP：用户主动停止（删通知 / 用户取消）→ 不得自动重申请，必须等
 *    显式用户操作（连接按钮 / 卡片 / 快捷方式）解除抑制；
 *  - SYSTEM_MISUSE：系统判定为"类型不匹配 / 不合理使用"→ 同样不得立即重申请；
 *  - SYSTEM_GENERAL：一般性系统取消 → 允许重申请，但**必须退避**（不得"立即"）；
 *  - SYSTEM_RESUME：任务从"暂停"中恢复（suspendState=false）→ 任务仍然存在，
 *    只需恢复记账，不得重复申请。
 */
export enum ContinuousTaskEventCategory {
  /** 用户主动停止 */
  USER_STOP = 'user-stop',
  /** 系统判定为类型不匹配 / 不合理使用 */
  SYSTEM_MISUSE = 'system-misuse',
  /** 一般性系统取消 */
  SYSTEM_GENERAL = 'system-general',
  /** 从暂停中恢复 */
  SYSTEM_RESUME = 'system-resume'
}

/**
 * 一次取消 / 暂停事件的分类结论（由 classifyCancelReason / classifySuspendReason 生成）。
 *
 * 字段全部是基本类型，调用方（含 UiGuardian）只读这些字段即可完成判定，
 * 不需要再认识 SDK 的原因码 —— 判定逻辑集中在本文件一处，便于审计。
 */
export class ContinuousTaskVerdict {
  /** SDK 原因码（ContinuousTaskCancelReason / ContinuousTaskSuspendReason 的数值） */
  reasonCode: number = 0;
  /** SDK 细分原因码（ContinuousTaskDetailedCancelReason；该字段可选，无则 0） */
  detailedReasonCode: number = 0;
  /** 分类（ContinuousTaskEventCategory 的字符串值） */
  category: string = ContinuousTaskEventCategory.SYSTEM_GENERAL;
  /** 本次事件发生前，进程内是否持有长时任务登记（false = 本次事件与本进程无关） */
  hadRegistration: boolean = false;
  /** 是否允许**自动**重挂（false = 不得自动再申请长时任务） */
  allowAutoRearm: boolean = false;
  /** 是否必须由显式用户操作才能再次申请 */
  requireUserAction: boolean = false;
  /** 允许重挂时的最小退避时长（ms）；0 = 无需等待 */
  backoffMs: number = 0;
  /** 人类可读结论（仅用于日志，不参与判定） */
  summary: string = '';
}

/**
 * 一般性系统取消后的最小退避时长。
 *
 * 规范只写"不得立即"，这里取 30s：既能盖住系统回收任务时的抖动窗口，
 * 又不至于让 VPN 隧道在无人看管时长时间失去"所有进程不被挂起"的保护。
 */
export const REARM_BACKOFF_GENERAL_MS: number = 30000;

/**
 * 取消原因里属于「系统判定为类型不匹配 / 不合理使用」的一组。
 * 逐个列出 SDK `ContinuousTaskCancelReason` 的枚举名，不写裸数字。
 */
function isMisuseCancelReason(reasonCode: number): boolean {
  return reasonCode === backgroundTaskManager.ContinuousTaskCancelReason.SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED
    || reasonCode === backgroundTaskManager.ContinuousTaskCancelReason.SYSTEM_CANCEL_AUDIO_PLAYBACK_NOT_USE_AVSESSION
    || reasonCode === backgroundTaskManager.ContinuousTaskCancelReason.SYSTEM_CANCEL_AUDIO_PLAYBACK_NOT_RUNNING
    || reasonCode === backgroundTaskManager.ContinuousTaskCancelReason.SYSTEM_CANCEL_AUDIO_RECORDING_NOT_RUNNING
    || reasonCode === backgroundTaskManager.ContinuousTaskCancelReason.SYSTEM_CANCEL_NOT_USE_LOCATION
    || reasonCode === backgroundTaskManager.ContinuousTaskCancelReason.SYSTEM_CANCEL_NOT_USE_BLUETOOTH
    || reasonCode === backgroundTaskManager.ContinuousTaskCancelReason.SYSTEM_CANCEL_NOT_USE_MULTI_DEVICE
    || reasonCode === backgroundTaskManager.ContinuousTaskCancelReason.SYSTEM_CANCEL_USE_ILLEGALLY;
}

/**
 * 细分原因（API 26+ 的 `detailedReason`）里同样属于「不合理使用」的一组。
 * 官方枚举：ContinuousTaskDetailedCancelReason。
 */
function isMisuseDetailedReason(code: number): boolean {
  return code === backgroundTaskManager.ContinuousTaskDetailedCancelReason.SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED
    || code === backgroundTaskManager.ContinuousTaskDetailedCancelReason.SYSTEM_CANCEL_DATA_TRANSFER_NOT_UPDATE
    || code === backgroundTaskManager.ContinuousTaskDetailedCancelReason.SYSTEM_CANCEL_USE_ILLEGALLY
    || code === backgroundTaskManager.ContinuousTaskDetailedCancelReason.SYSTEM_CANCEL_AUDIO_PLAYBACK_NOT_RUNNING
    || code === backgroundTaskManager.ContinuousTaskDetailedCancelReason.SYSTEM_CANCEL_AUDIO_RECORDING_NOT_RUNNING
    || code === backgroundTaskManager.ContinuousTaskDetailedCancelReason.SYSTEM_CANCEL_NOT_USE_LOCATION
    || code === backgroundTaskManager.ContinuousTaskDetailedCancelReason.SYSTEM_CANCEL_NOT_USE_BLUETOOTH
    || code === backgroundTaskManager.ContinuousTaskDetailedCancelReason.SYSTEM_CANCEL_NOT_USE_MULTI_DEVICE
    || code === backgroundTaskManager.ContinuousTaskDetailedCancelReason.SYSTEM_CANCEL_VOIP_NOT_RUNNING
    || code === backgroundTaskManager.ContinuousTaskDetailedCancelReason.SYSTEM_CANCEL_USER_UNAUTHORIZED;
}

/**
 * 暂停原因里属于「系统判定为类型不匹配 / 不合理使用」的一组。
 * 逐个列出 SDK `ContinuousTaskSuspendReason` 的枚举名。
 *
 * 注意 SYSTEM_SUSPEND_DATA_TRANSFER_LOW_SPEED(4)：它表示"申请的是 DATA_TRANSFER
 * 类型但实际传输速率过低"，正是本工程把隧道保活错挂成 dataTransfer 的直接证据 ——
 * VPN 隧道空闲时用户流量本就低，会稳定踩中这个触发条件。
 */
function isMisuseSuspendReason(reasonCode: number): boolean {
  return reasonCode === backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_DATA_TRANSFER_LOW_SPEED
    || reasonCode === backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_AUDIO_PLAYBACK_NOT_USE_AVSESSION
    || reasonCode === backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_AUDIO_PLAYBACK_NOT_RUNNING
    || reasonCode === backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_AUDIO_RECORDING_NOT_RUNNING
    || reasonCode === backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_LOCATION_NOT_USED
    || reasonCode === backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_BLUETOOTH_NOT_USED
    || reasonCode === backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_MULTI_DEVICE_NOT_USED
    || reasonCode === backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_VOIP_NOT_USED
    || reasonCode === backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_USED_ILLEGALLY
    || reasonCode === backgroundTaskManager.ContinuousTaskSuspendReason.SYSTEM_SUSPEND_USER_UNAUTHORIZED;
}

/**
 * 把 SDK 的取消原因翻译成「这次取消允许重挂吗 / 要退避多久 / 要不要用户显式操作」。
 *
 * @param reasonCode ContinuousTaskCancelReason 的数值
 * @param detailedReasonCode ContinuousTaskDetailedCancelReason 的数值（可选，0 = 无）
 */
export function classifyCancelReason(reasonCode: number, detailedReasonCode: number = 0): ContinuousTaskVerdict {
  const verdict: ContinuousTaskVerdict = new ContinuousTaskVerdict();
  verdict.reasonCode = reasonCode;
  verdict.detailedReasonCode = detailedReasonCode;
  if (reasonCode === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL
    || reasonCode === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL_REMOVE_NOTIFICATION
    || detailedReasonCode === backgroundTaskManager.ContinuousTaskDetailedCancelReason.USER_CANCEL_REMOVE_NOTIFICATION) {
    // 用户主动停止：规范明文"不得立即再次申请" → 只能等显式用户操作。
    // 第三个条件覆盖"粗分类只给了 SYSTEM_CANCEL、细分类才指出是用户删通知"的情况
    // （SDK 两种枚举都有 USER_CANCEL_REMOVE_NOTIFICATION = 3）。
    verdict.category = ContinuousTaskEventCategory.USER_STOP;
    verdict.allowAutoRearm = false;
    verdict.requireUserAction = true;
    verdict.backoffMs = 0;
    verdict.summary = 'user stopped the continuous task (notification removed / user cancel)';
    return verdict;
  }
  if (isMisuseCancelReason(reasonCode) || isMisuseDetailedReason(detailedReasonCode)) {
    // 系统判定为类型不匹配 / 不合理使用：规范明文"不得立即再次申请"。
    verdict.category = ContinuousTaskEventCategory.SYSTEM_MISUSE;
    verdict.allowAutoRearm = false;
    verdict.requireUserAction = true;
    verdict.backoffMs = 0;
    verdict.summary = 'system judged the continuous task type mismatched / used improperly';
    return verdict;
  }
  // 其余（SYSTEM_CANCEL(2) 等一般性系统取消）：允许重挂，但不得"立即" → 给退避。
  verdict.category = ContinuousTaskEventCategory.SYSTEM_GENERAL;
  verdict.allowAutoRearm = true;
  verdict.requireUserAction = false;
  verdict.backoffMs = REARM_BACKOFF_GENERAL_MS;
  verdict.summary = 'system canceled the continuous task (generic)';
  return verdict;
}

/**
 * 把 SDK 的暂停 / 恢复原因翻译成分类结论。
 *
 * @param reasonCode ContinuousTaskSuspendReason 的数值
 * @param suspended true = 处于暂停态（应用退后台会被挂起），false = 已恢复
 */
export function classifySuspendReason(reasonCode: number, suspended: boolean): ContinuousTaskVerdict {
  const verdict: ContinuousTaskVerdict = new ContinuousTaskVerdict();
  verdict.reasonCode = reasonCode;
  if (!suspended) {
    // 恢复：任务仍然存在，只需恢复记账；重复申请既无意义也可能失败。
    verdict.category = ContinuousTaskEventCategory.SYSTEM_RESUME;
    verdict.allowAutoRearm = false;
    verdict.requireUserAction = false;
    verdict.backoffMs = 0;
    verdict.summary = 'continuous task resumed (suspendState=false); task still alive, restore accounting only';
    return verdict;
  }
  if (isMisuseSuspendReason(reasonCode)) {
    // 类型不匹配被降级：规范明文不得立即重申请 → 与"用户主动停止"同样抑制。
    verdict.category = ContinuousTaskEventCategory.SYSTEM_MISUSE;
    verdict.allowAutoRearm = false;
    verdict.requireUserAction = true;
    verdict.backoffMs = 0;
    verdict.summary = 'system suspended the task as type-mismatched / improperly used';
    return verdict;
  }
  // 其它暂停原因（例如 SYSTEM_SUSPEND_SYSTEM_LOAD_WARNING 系统高负载）：
  // 属临时性降级。任务仍在，不重复申请；但记录退避时长，供后续取消事件参考。
  verdict.category = ContinuousTaskEventCategory.SYSTEM_GENERAL;
  verdict.allowAutoRearm = false;
  verdict.requireUserAction = false;
  verdict.backoffMs = REARM_BACKOFF_GENERAL_MS;
  verdict.summary = 'system suspended the task temporarily; task still alive, no re-apply needed';
  return verdict;
}

/**
 * 长时任务事件监听者（同步回调；实现方自行容错，绝不抛出）。
 */
export interface ContinuousTaskCancelListener {
  /** 长时任务被取消：id = 连续任务 id，verdict = 原因分类结论 */
  onContinuousTaskCancel(id: number, verdict: ContinuousTaskVerdict): void;
  /** 长时任务被暂停（suspended=true）或从暂停中恢复（suspended=false） */
  onContinuousTaskSuspend(id: number, verdict: ContinuousTaskVerdict, suspended: boolean): void;
}

export class BackgroundTaskWatch {
  private static watching: boolean = false;
  private static listeners: ContinuousTaskCancelListener[] = [];
  private static lastCancelId: number = -1;
  private static lastCancelReason: string = '';
  private static lastCancelAt: number = 0;

  /**
   * 幂等注册（进程级一次）。
   * - continuousTaskCancel：API 15+；
   * - continuousTaskSuspend：API 20+（本工程 compatibleSdkVersion = 6.1.1(24) ≥ 20，
   *   但裁剪版系统 / 老设备仍可能不支持该事件 → 必须 try/catch，失败只记日志不崩）。
   */
  static ensure(): void {
    if (BackgroundTaskWatch.watching) {
      return;
    }
    BackgroundTaskWatch.watching = true;
    try {
      backgroundTaskManager.on('continuousTaskCancel',
        (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
          BackgroundTaskWatch.dispatchCancel(info);
        });
      AppLogger.info(TAG, 'continuousTaskCancel listener registered');
    } catch (e) {
      AppLogger.warn(TAG,
        `continuousTaskCancel listener registration failed: ${AppLogger.errText(e)}`);
    }
    try {
      backgroundTaskManager.on('continuousTaskSuspend',
        (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
          BackgroundTaskWatch.dispatchSuspend(info);
        });
      AppLogger.info(TAG, 'continuousTaskSuspend listener registered');
    } catch (e) {
      AppLogger.warn(TAG,
        `continuousTaskSuspend listener registration failed: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * 取消事件分发：分类 → 清账 → 广播。
   *
   * 顺序说明：先让 UiGuardian 记账（清 registered / 置抑制态 / 记最早可重挂时间），
   * 再把结论广播给监听者 —— 监听者据此决定"退避多久后重挂"，此时门禁已就位。
   */
  private static dispatchCancel(info: backgroundTaskManager.ContinuousTaskCancelInfo): void {
    const id: number = (info !== undefined && info !== null) ? info.id : -1;
    if (!UiGuardian.ownsTaskEvent(id)) {
      AppLogger.info(TAG, `ignore cancellation of an unowned task: id=${id}`);
      return;
    }
    // SDK 的 reason 是**数值枚举**（ContinuousTaskCancelReason），不是字符串 ——
    // 改造前按 string 读取，判断永远不成立（分类恒为空）。
    const reasonCode: number = (info !== undefined && info !== null && typeof info.reason === 'number')
      ? info.reason : 0;
    const detailedCode: number = (info !== undefined && info !== null && typeof info.detailedReason === 'number')
      ? info.detailedReason : 0;
    const verdict: ContinuousTaskVerdict = classifyCancelReason(reasonCode, detailedCode);
    BackgroundTaskWatch.lastCancelId = id;
    BackgroundTaskWatch.lastCancelReason = verdict.category;
    BackgroundTaskWatch.lastCancelAt = Date.now();
    // 任务已不存在：进度心跳立刻止损（继续 publish 会持续报错）
    TaskProgressUpdater.detach();
    // 刷新守护记账（清 registered / 置抑制态 / 记最早可重挂时间）；
    // noteExternalCancel 会在清账前把"此前是否持有登记"写回 verdict.hadRegistration。
    UiGuardian.noteExternalCancel(verdict);
    // 结构化一行日志：现场取证可直接判定（id / reason / detailedReason / 分类 /
    // 是否允许重挂 / 退避时长 / 此前是否持有登记）。
    AppLogger.warn(TAG,
      `continuous task canceled: id=${id} reason=${verdict.reasonCode} `
      + `detailedReason=${verdict.detailedReasonCode} category=${verdict.category} `
      + `allowAutoRearm=${verdict.allowAutoRearm} requireUserAction=${verdict.requireUserAction} `
      + `backoff=${verdict.backoffMs}ms hadRegistration=${verdict.hadRegistration} summary=${verdict.summary}`);
    for (const l of BackgroundTaskWatch.listeners.slice()) {
      try {
        l.onContinuousTaskCancel(id, verdict);
      } catch (e) {
        AppLogger.warn(TAG, `cancel listener threw: ${AppLogger.errText(e)}`);
      }
    }
  }

  /**
   * 暂停 / 恢复事件分发。
   *
   * 暂停态的关键含义（SDK 官方说明）：长时任务被暂停后，**应用退到后台会被挂起**，
   * 即"一个 UIAbility 申请长时任务后整个应用下的所有进程均不会被挂起"这条保底
   * 资格随之消失 —— VPN 扩展进程的定时器会停摆 → 存活租约停更 → UI 误判
   * core died → 拆隧道重连。因此这里必须把"失去不被挂起资格"明确打进日志。
   */
  private static dispatchSuspend(info: backgroundTaskManager.ContinuousTaskSuspendInfo): void {
    const id: number = (info !== undefined && info !== null) ? info.continuousTaskId : -1;
    if (!UiGuardian.ownsTaskEvent(id)) {
      AppLogger.info(TAG, `ignore suspension of an unowned task: id=${id}`);
      return;
    }
    const suspended: boolean = (info !== undefined && info !== null) ? info.suspendState === true : false;
    const reasonCode: number = (info !== undefined && info !== null && typeof info.suspendReason === 'number')
      ? info.suspendReason : 0;
    // suspendMessage 是 API 26 才有的可选字段（{ message, reason }），有则一并打进日志。
    const suspendMessage: string = (info !== undefined && info !== null && info.suspendMessage !== undefined
      && info.suspendMessage !== null && typeof info.suspendMessage.message === 'string')
      ? info.suspendMessage.message : '';
    const verdict: ContinuousTaskVerdict = classifySuspendReason(reasonCode, suspended);
    if (suspended) {
      TaskProgressUpdater.detach();
      UiGuardian.noteExternalSuspend(verdict, true);
      AppLogger.warn(TAG,
        `continuous task suspended: id=${id} reason=${verdict.reasonCode} category=${verdict.category} `
        + `allowAutoRearm=${verdict.allowAutoRearm} requireUserAction=${verdict.requireUserAction} `
        + `summary=${verdict.summary} message=${suspendMessage}; app loses the "never suspended" protection while suspended`);
    } else {
      UiGuardian.noteExternalSuspend(verdict, false);
      AppLogger.info(TAG,
        `continuous task resumed: id=${id} reason=${verdict.reasonCode} category=${verdict.category} `
        + `summary=${verdict.summary}`);
    }
    for (const l of BackgroundTaskWatch.listeners.slice()) {
      try {
        l.onContinuousTaskSuspend(id, verdict, suspended);
      } catch (e) {
        AppLogger.warn(TAG, `suspend listener threw: ${AppLogger.errText(e)}`);
      }
    }
  }

  static addListener(listener: ContinuousTaskCancelListener): void {
    if (!BackgroundTaskWatch.listeners.includes(listener)) {
      BackgroundTaskWatch.listeners.push(listener);
    }
  }

  static removeListener(listener: ContinuousTaskCancelListener): void {
    const idx = BackgroundTaskWatch.listeners.indexOf(listener);
    if (idx >= 0) {
      BackgroundTaskWatch.listeners.splice(idx, 1);
    }
  }

  /** 最近一次取消的时间戳（0 = 从未），供诊断展示。 */
  static lastCancelAtMs(): number {
    return BackgroundTaskWatch.lastCancelAt;
  }

  /** 最近一次取消的分类（诊断用，USER_STOP / SYSTEM_MISUSE / SYSTEM_GENERAL）。 */
  static lastReason(): string {
    return BackgroundTaskWatch.lastCancelReason;
  }
}
