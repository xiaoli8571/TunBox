/**
 * 长时任务通知接线 —— **实况窗（圆环）+ 应用自有通知**（0.7.5 通知栏样式）。
 *
 * ── 为什么是这个形态 ───────────────────────────────────────────────────
 * 长时任务分两种类型（`backgroundTaskManager.BackgroundTaskMode`）：
 *  - DATA_TRANSFER：SDK 注释要求「必须用实况窗（live view）周期更新进度」，
 *    否则 10 分钟不更新进度会被系统取消；实况窗模板 `downloadTemplate`
 *    **自带右侧圆环**，只支持进度型展示。
 *  - MODE_TASK_KEEPING：官方接入规范明确「不得修改长时任务通知内容」。
 *
 * 0.7.7 曾把实况窗整条链路删掉（用户当时要求去掉圆环）。现在按用户要求
 * **恢复 0.7.5 的通知栏样式**，并把圆环接上真实数据：
 *
 *   progressValue = 订阅流量配额的「已用百分比」
 *
 * 也就是首页那张配额条（↑已用 / ↓已用 / 总量）的同一条口径：所有
 * totalBytes > 0 的订阅求和后取 (upload+download)/total。没有配额信息
 * （自建节点、机场不给 userinfo）时不写 progressValue，圆环留空，
 * 不假装有进度。
 *
 * ── 两张卡 / 一张卡的分界（照旧）────────────────────────────────────────
 *  - DATA_TRANSFER：接管系统长时任务通知 id 写实况窗，并撤掉应用自有通知
 *    → 通知栏只有一条「TunBox · 节点名 / ↓速率 ↑速率 · 时长」，右侧带配额圆环。
 *  - TASK_KEEPING：不碰通知内容，速率/时长由应用自有通知承载
 *    → 系统「正在运行」卡 + 应用卡两条（无圆环）。
 *
 * 进度心跳 5 分钟（官方窗口 10 分钟，留一倍冗余）；流量轮询每 2s 也会推一帧。
 * 发布失败（通知被禁用 1600004 等）只做节流日志，不重试风暴。
 */
import { notificationManager } from '@kit.NotificationKit';
import { UnifiedScheduler } from './UnifiedScheduler';
import { AppLogger } from '../utils/AppLogger';
import { TunBoxNotifier } from './TunBoxNotifier';
import { SubscriptionService } from './SubscriptionService';

const TAG = 'TaskProgressUpdater';

/** 进度心跳周期：官方窗口 10 分钟，5 分钟留一倍冗余 */
const UPDATE_INTERVAL_MS: number = 5 * 60 * 1000;
/** dataTransfer 实况通知固定 typeCode（官方当前仅支持 8） */
const TYPE_CODE_DATA_TRANSFER: number = 8;
/** 实况窗唯一支持的模板名 */
const TEMPLATE_NAME: string = 'downloadTemplate';
/** 失败日志节流窗口，避免周期性刷屏 */
const FAIL_LOG_THROTTLE_MS: number = 10 * 60 * 1000;

/**
 * 实际生效的长时任务类型。
 *
 * 为什么枚举定义在本文件：长时任务链路上（UiGuardian / BackgroundTaskWatch /
 * QuickToggleAbility）都要用它，而本文件是链路上**唯一不含跨模块依赖**的基础模块
 * —— 把定义放这里可以让三方共享同一份定义而不产生循环依赖。
 */
export enum ContinuousTaskKind {
  /** 未申请（或已释放） */
  NONE = 'none',
  /** 数据传输类型：允许周期更新实况窗进度，右侧圆环可用 */
  DATA_TRANSFER = 'dataTransfer',
  /** 计算任务类型：不得修改长时任务通知内容 */
  TASK_KEEPING = 'taskKeeping'
}

export class TaskProgressUpdater {
  /** 当前生效的长时任务类型（决定通知走向） */
  private static kind: ContinuousTaskKind = ContinuousTaskKind.NONE;
  /** 系统长时任务通知 id；>= 0 才写实况窗，< 0 回落到应用自有通知 */
  private static taskNotificationId: number = -1;
  /** 5 分钟进度心跳定时器句柄 */
  private static timer: number = -1;
  /** 最近一次内容（节点名 / 速率 / 时长），断连重连时用于首帧补齐 */
  private static lastNodeText: string = 'TunBox';
  private static lastSpeedLine: string = '隧道已连接 · 持续保护中';
  private static lastDurationText: string = '';
  /** 圆环进度：订阅配额已用比例 0~1；-1 表示没有配额信息（圆环留空） */
  private static quotaRatio: number = -1;
  private static lastFailLogAt: number = 0;

  /**
   * 实况内容更新（连接期间由流量轮询每 2s 调用）。
   *
   * 拿到了长时任务通知 id（dataTransfer）→ 推实况窗，圆环随配额走；
   * 否则（taskKeeping / 未挂上）→ 退回应用自有常驻通知，绝不发 1600004 风暴。
   */
  static updateLive(nodeText: string, speedLine: string, durationText: string,
    force: boolean = false): void {
    TaskProgressUpdater.lastNodeText = nodeText.trim().length > 0 ? nodeText.trim() : 'TunBox';
    TaskProgressUpdater.lastSpeedLine = speedLine;
    TaskProgressUpdater.lastDurationText = durationText;
    if (TaskProgressUpdater.taskNotificationId >= 0) {
      TaskProgressUpdater.push();
      return;
    }
    // 折叠态只渲染「标题 + 正文」两处：速率与时长合并成一行（"↓56KB/s · 0:06:41"），
    // additionalText 仍放节点名，展开态多一行不丢信息。
    const speed = TaskProgressUpdater.compactSpeed(TaskProgressUpdater.lastSpeedLine);
    const liveLine = TaskProgressUpdater.lastDurationText.length > 0
      ? `${speed} · ${TaskProgressUpdater.lastDurationText}`
      : speed;
    TunBoxNotifier.update(`TunBox · ${TaskProgressUpdater.lastNodeText}`,
      TaskProgressUpdater.lastNodeText,
      liveLine, force).catch((): void => {});
  }

  /**
   * 长时任务申请成功后调用：**按类型分叉**接管通知。
   *
   * @param notificationId 申请返回的长时任务通知 id
   * @param kind 实际生效的长时任务类型（UiGuardian.currentTaskType()）
   */
  static attach(notificationId: number, kind: ContinuousTaskKind): void {
    TaskProgressUpdater.detach();
    TaskProgressUpdater.kind = kind;
    if (kind !== ContinuousTaskKind.DATA_TRANSFER) {
      // taskKeeping：官方禁止改长时任务通知内容 → 不接管 id、不撤应用卡，
      // 速率/时长继续由 TunBoxNotifier 承载（updateLive 自动回落）。
      // 这里必须显式 release：上一次会话可能是 dataTransfer 接管态。
      TunBoxNotifier.release();
      AppLogger.info(TAG,
        `${kind} mode: live view disabled (non-dataTransfer notification must not be modified)`);
      return;
    }
    if (typeof notificationId !== 'number' || notificationId < 0) {
      AppLogger.warn(TAG, `attach skipped: invalid notificationId (${notificationId})`);
      return;
    }
    TaskProgressUpdater.taskNotificationId = notificationId;
    // 应用自有常驻通知与实况窗重复（否则通知栏两条）→ 接管即撤。
    // 顺序很重要：**先**置接管位（挡住所有在途/后续的应用卡发布），**再**串行撤卡。
    // 真机 2026-10-31：只撤不置位时，连接首帧（force，时长 0:00:00）的 publish
    // 落在 cancel 之后，通知栏就多出一条永远停在 0:00:00 的死卡。
    TunBoxNotifier.takeOver();
    TunBoxNotifier.cancel().catch((): void => {});
    // 兜底二次清扫：系统贴出实况窗时可能重排通知列表，晚 1.2s 再撤一次，
    // 确保首帧与 cancel 的先后顺序不论怎样，最后只剩实况窗一条。
    const sweepId: number = notificationId;
    setTimeout((): void => {
      if (TaskProgressUpdater.kind === ContinuousTaskKind.DATA_TRANSFER
        && TaskProgressUpdater.taskNotificationId === sweepId) {
        TunBoxNotifier.cancel().catch((): void => {});
      }
    }, 1200);
    TaskProgressUpdater.push();
    TaskProgressUpdater.timer = UnifiedScheduler.every((): void => {
      TaskProgressUpdater.push();
    }, UPDATE_INTERVAL_MS);
    AppLogger.info(TAG,
      `live view attached (taskNotificationId=${notificationId} type=${kind})`);
  }

  /** 释放 / 断开 / 任务被取消或暂停时调用（幂等）。 */
  static detach(): void {
    if (TaskProgressUpdater.timer >= 0) {
      UnifiedScheduler.clear(TaskProgressUpdater.timer);
      TaskProgressUpdater.timer = -1;
    }
    TaskProgressUpdater.taskNotificationId = -1;
    TaskProgressUpdater.kind = ContinuousTaskKind.NONE;
    // 实况窗不再接管：应用自有卡恢复可发布（断开时由 FormStateSync 负责撤卡）
    TunBoxNotifier.release();
  }

  /** 是否已登记长时任务类型（UiGuardian 看门狗重挂前用于去重）。 */
  static isActive(): boolean {
    return TaskProgressUpdater.kind !== ContinuousTaskKind.NONE;
  }

  /** 当前生效的长时任务类型（诊断用）。 */
  static currentKind(): ContinuousTaskKind {
    return TaskProgressUpdater.kind;
  }

  /**
   * 直接指定圆环进度（0~1）；传负数表示「没有配额信息，圆环留空」。
   * 一般不需要外部调用：push() 每次都会从订阅里自己刷新。
   */
  static setQuotaRatio(ratio: number): void {
    const next: number = (ratio >= 0 && ratio <= 1) ? ratio : -1;
    if (next === TaskProgressUpdater.quotaRatio) {
      return;
    }
    TaskProgressUpdater.quotaRatio = next;
    if (TaskProgressUpdater.taskNotificationId >= 0) {
      TaskProgressUpdater.push();
    }
  }

  /** 当前圆环比例（-1 = 无配额），诊断用 */
  static currentQuotaRatio(): number {
    return TaskProgressUpdater.quotaRatio;
  }

  /**
   * 从订阅里算「配额已用百分比」：把所有给了总量的订阅求和后取
   * (upload + download) / total —— 与首页配额条同一口径。
   *
   * 全都没有 totalBytes（自建节点 / 机场不给 subscription-userinfo）时返回 -1，
   * 圆环留空：不编造进度。
   */
  private static refreshQuotaRatio(): number {
    try {
      const subs = SubscriptionService.instance().subscriptions;
      let used: number = 0;
      let total: number = 0;
      for (const sub of subs) {
        if (sub.totalBytes > 0) {
          total += sub.totalBytes;
          used += Math.max(0, sub.uploadBytes) + Math.max(0, sub.downloadBytes);
        }
      }
      if (total <= 0) {
        return -1;
      }
      return Math.min(1, Math.max(0, used / total));
    } catch (e) {
      AppLogger.warn(TAG, `quota ratio unavailable: ${AppLogger.errText(e)}`);
      return -1;
    }
  }

  /**
   * 速率串紧凑化，用于挤进实况通知的单行正文。
   *   "↓ 56.0 KB/s  ↑ 0 B/s" → "↓56KB/s ↑0B/s"
   * 只动空白与整数位的小数点（56.0→56），不改数值语义；1.5 MB/s 保持 1.5MB/s。
   */
  private static compactSpeed(line: string): string {
    return line
      .replace(/(\d)\.0(?=\s*[KMG]?B\/s)/g, '$1')
      .replace(/(\d)\s+([KMG]?B\/s)/g, '$1$2')
      .replace(/\s+/g, ' ')
      .trim();
  }

  /** 单帧实况窗更新（失败绝不抛出，只做节流日志）。 */
  private static push(): void {
    const id = TaskProgressUpdater.taskNotificationId;
    if (id < 0) {
      return;
    }
    const nodeText = TaskProgressUpdater.lastNodeText;
    const speed = TaskProgressUpdater.compactSpeed(TaskProgressUpdater.lastSpeedLine);
    const duration = TaskProgressUpdater.lastDurationText;
    const liveLine = duration.length > 0 ? `${speed} · ${duration}` : speed;

    // 圆环数据：订阅配额已用百分比。每次推送都重算（fidelity 高于缓存），
    // 没有配额时不写 progressValue → 模板圆环留空，不显示假进度。
    TaskProgressUpdater.quotaRatio = TaskProgressUpdater.refreshQuotaRatio();
    const data: Record<string, Object> = {};
    data['title'] = nodeText;
    data['fileName'] = liveLine;
    if (TaskProgressUpdater.quotaRatio >= 0) {
      data['progressValue'] = Math.round(TaskProgressUpdater.quotaRatio * 100);
    }

    const request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
        systemLiveView: {
          typeCode: TYPE_CODE_DATA_TRANSFER,
          title: `TunBox · ${nodeText}`,
          text: liveLine
        }
      },
      template: {
        name: TEMPLATE_NAME,
        data: data
      }
    };
    notificationManager.publish(request).then((): void => {
      TaskProgressUpdater.lastFailLogAt = 0;
    }).catch((e: Object): void => {
      const now = Date.now();
      if (now - TaskProgressUpdater.lastFailLogAt > FAIL_LOG_THROTTLE_MS) {
        TaskProgressUpdater.lastFailLogAt = now;
        AppLogger.warn(TAG, `live view update failed: ${AppLogger.errText(e)}`);
      }
    });
  }
}
