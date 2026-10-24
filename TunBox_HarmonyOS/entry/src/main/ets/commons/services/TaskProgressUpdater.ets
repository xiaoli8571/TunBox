/**
 * 长时任务进度心跳 —— **按长时任务类型分叉**（dataTransfer / taskKeeping）。
 *
 * ── 官方依据（SDK 头文件 +《Background Tasks Kit 接入规范》）────────────
 * 1) SDK `BackgroundTaskMode.DATA_TRANSFER` 注释原文：
 *    「During data transfer, the application needs to update the progress. If the
 *    progress is not updated for more than 10 minutes, the continuous task of the
 *    DATA_TRANSFER type will be canceled.」+「The notification type of the progress
 *    update must be live view.」
 *    → dataTransfer **必须**周期推实况窗进度（首次更新不得超过 10 分钟）。
 * 2) 官方《Background Tasks Kit 接入规范》：
 *    「不得修改长时任务通知内容。**数据传输任务除外**，此时可更新通知中的进度信息，
 *    但更新内容仅限进度展示，不得用于其他用途。」
 *    → 反过来说：**taskKeeping（TASK_KEEPING）绝对不能推实况窗进度**，
 *      也不能以任何方式改动长时任务通知内容。
 * 3) 官方长时任务类型表：DATA_TRANSFER =「非托管形式的上传、下载」；
 *    TASK_KEEPING =「计算任务」（场景举例：杀毒软件）→ VPN 隧道保活属于后者。
 *
 * * ── 本实现的取舍 ───────────────────────────────────────────────────────
 *  - dataTransfer（回退类型）：保持现状 —— 实况窗 LIVE_VIEW + typeCode 8 +
 *    5 分钟进度心跳；接管长时任务通知 id，并撤掉应用自有常驻通知（避免两条通知）。
 *  - taskKeeping（目标类型）：**不推**实况窗进度、**不接管**通知 id、
 *    **不撤**应用自有常驻通知 —— 节点名/速率/运行时长继续由 TunBoxNotifier 承载
 *    （updateLive 在没有长时任务通知 id 时自动回落到应用自有通知）。
 *
 * ── 通知栏为什么是「两张卡」（2026-10-20 用户反馈，先说清楚再改）─────────
 *  taskKeeping 是系统强制的长时任务类型，官方**不允许**应用改它的通知内容 ⇒
 *  系统那张「正在运行计算任务…」的卡**去不掉**（submode 全类型都带通知，
 *  SDK BackgroundTaskSubmode 无静默项）。因此 taskKeeping 模式下：
 *    · 系统卡：「正在运行计算任务…」（内容不可改，只能接受）
 *    · 应用卡：节点名 + **速率 · 运行时长**（一行，2026-10-20 按用户反馈恢复的
 *      原来的信息口径；此前时长被放进 additionalText，折叠态不显示 = 视觉上丢失）
 *  想回到「只有一张卡」只能退回 dataTransfer（实况窗卡片由应用写内容），
 *  代价是重新暴露「低速率被系统取消长时任务 → 保流失效 → 隧道掉线」那条链。
 *
 * 进度值对 VPN 没有真实百分比语义 → 以「已连接分钟数 % 100」推进进度条，
 * fileName 展示已连接时长；title/text 展示运行状态。更新内容仅限进度展示，
 * 与接入规范对 dataTransfer 的豁免条款（可更新进度信息）保持一致。
 * 发布失败（通知被禁用 1600004 / 任务已不存在等）只做节流日志，不重试风暴；
 * 任务被外部取消/暂停时由 BackgroundTaskWatch → detach() 止损。
 */
import { notificationManager } from '@kit.NotificationKit';
import { AppLogger } from '../utils/AppLogger';
import { TunBoxNotifier } from './TunBoxNotifier';

const TAG = 'TaskProgressUpdater';

/**
 * 实际生效的长时任务类型。
 *
 * 为什么枚举定义在本文件：长时任务链路上（UiGuardian / BackgroundTaskWatch /
 * QuickToggleAbility）都要用它，而本文件是链路上**唯一不含跨模块依赖**的基础模块
 * —— 把定义放这里可以让三方共享同一份定义而不产生循环依赖。
 *
 * 取值与 SDK `BackgroundTaskMode` 对应：
 *  - DATA_TRANSFER = 'dataTransfer'（SDK BackgroundTaskMode.DATA_TRANSFER = 1）
 *  - TASK_KEEPING  = 'taskKeeping'  （SDK BackgroundTaskMode.MODE_TASK_KEEPING = 9）
 */
export enum ContinuousTaskKind {
  /** 未申请（或已释放） */
  NONE = 'none',
  /** 数据传输类型：允许周期更新实况窗进度 */
  DATA_TRANSFER = 'dataTransfer',
  /** 计算任务类型：不得修改长时任务通知内容 */
  TASK_KEEPING = 'taskKeeping',
  /** Audio task: AVSession/renderer own playback; no live-view progress. */
  AUDIO_PLAYBACK = 'audioPlayback'
}

/** 更新周期：官方窗口为 10 分钟，这里 5 分钟留一倍冗余 */
const UPDATE_INTERVAL_MS: number = 5 * 60 * 1000;
/** dataTransfer 类型实况通知固定 typeCode（官方示例：当前仅支持 8） */
const TYPE_CODE_DATA_TRANSFER: number = 8;
/** 仅支持的模板名（官方：downloadTemplate） */
const TEMPLATE_NAME: string = 'downloadTemplate';
/** 失败日志节流窗口：避免周期性刷屏 */
const FAIL_LOG_THROTTLE_MS: number = 10 * 60 * 1000;

export class TaskProgressUpdater {
  private static taskNotificationId: number = -1;
  private static timer: number = -1;
  // 2026-10-19：原 startedAt 仅用于把「已连接分钟数」写进 progressValue（圆环进度）。
  // 用户要求去掉圆环后该字段再无读取方，删除以免留下只写不读的死字段。
  private static lastFailLogAt: number = 0;
  /** 最近一次实况内容（流量心跳更新，5 分钟心跳沿用同一内容） */
  private static lastNodeText: string = 'TunBox';
  private static lastSpeedLine: string = '隧道已连接 · 持续保护中';
  private static lastDurationText: string = '';

  /**
   * 实况内容更新（连接期间由流量轮询每 2s 调用）：节点名进 title、速率+时长进
   * fileName —— 与「已连接 X 分钟」同一渲染位，不新增第二条通知。长时任务通知
   * 是系统强制的（dataTransfer 连续任务），应用自己的常驻通知与它重复，已合并到
   * 这里。任务通知 id 未拿到（长时任务未挂上）时退回应用自有通知兜底。
   *
   * taskKeeping 模式下长时任务通知 id 恒为 -1（不允许改通知内容），
   * 因此本函数**始终**走应用自有常驻通知（TunBoxNotifier）—— 这正是
   * taskKeeping 的预期分工：系统通知只表示"有长时任务在跑"，
   * 速率/运行时长由应用自己的通知承载。
   */
  static updateLive(nodeText: string, speedLine: string, durationText: string): void {
    TaskProgressUpdater.lastNodeText = nodeText.trim().length > 0 ? nodeText.trim() : 'TunBox';
    TaskProgressUpdater.lastSpeedLine = speedLine;
    TaskProgressUpdater.lastDurationText = durationText;
    const id = TaskProgressUpdater.taskNotificationId;
    if (id < 0) {
      // 长时任务未挂上（或 taskKeeping 模式下**不允许**改它的通知）→ 应用自有常驻通知承载。
      //
      // 2026-10-20 用户反馈修正（「通知栏少了运行时间」）：
      //   时长原先被塞进 `additionalText`（副标题位）。折叠态的通知卡片**不渲染副标题**，
      //   用户只看到"有速率、没有运行时长" —— 视觉上等于把原来的信息弄丢了。
      //   原来的实况窗卡片是**一行**：「速率 · 运行时长」（见 push() 的 liveLine）。
      //   这里恢复同一行口径：可见正文 = 「速率 · 运行时长」，
      //   节点名进 title，additionalText 仍留节点名（展开态多一行，不丢信息）。
      const speed = TaskProgressUpdater.compactSpeed(speedLine);
      const liveLine = durationText.length > 0 ? `${speed} · ${durationText}` : speed;
      TunBoxNotifier.update(`TunBox · ${TaskProgressUpdater.lastNodeText}`,
        TaskProgressUpdater.lastNodeText,
        liveLine).catch((): void => {});
      return;
    }
    TaskProgressUpdater.push();
  }

  /**
   * 长时任务申请成功后调用：**按长时任务类型**接管通知 id 与进度心跳。
   *
   * @param notificationId 申请返回的长时任务通知 id（只有 dataTransfer 会用它推实况窗）
   * @param kind 实际生效的长时任务类型（UiGuardian.currentTaskType()）
   */
  static attach(notificationId: number, kind: ContinuousTaskKind): void {
    TaskProgressUpdater.detach();
    if (kind !== ContinuousTaskKind.DATA_TRANSFER) {
      // taskKeeping：接入规范「不得修改长时任务通知内容（数据传输任务除外）」——
      // 因此既不推实况窗进度、也不接管通知 id、更**不撤**应用自有常驻通知
      // （速率/运行时长继续由 TunBoxNotifier 承载：updateLive 在没有长时任务
      // 通知 id 时会自动回落到应用自有通知）。
      AppLogger.info(TAG,
        `${kind} mode: live-view progress disabled (non-dataTransfer long-running task notification must not be modified)`);
      return;
    }
    if (typeof notificationId !== 'number' || notificationId < 0) {
      AppLogger.warn(TAG, `attach skipped: invalid notificationId (${notificationId})`);
      return;
    }
    TaskProgressUpdater.taskNotificationId = notificationId;
    // 应用自有常驻通知与长时任务通知重复（用户实锤「两个通知消息」），接管即撤
    TunBoxNotifier.cancel().catch((): void => {});
    TaskProgressUpdater.push();
    TaskProgressUpdater.timer = setInterval((): void => {
      TaskProgressUpdater.push();
    }, UPDATE_INTERVAL_MS);
    AppLogger.info(TAG, `progress heartbeat attached (taskNotificationId=${notificationId} type=${kind})`);
  }

  /** 释放 / 断开 / 任务取消或被暂停时调用（幂等；两种长时任务类型都安全）。 */
  static detach(): void {
    if (TaskProgressUpdater.timer >= 0) {
      clearInterval(TaskProgressUpdater.timer);
      TaskProgressUpdater.timer = -1;
    }
    TaskProgressUpdater.taskNotificationId = -1;
  }

  static isActive(): boolean {
    return TaskProgressUpdater.taskNotificationId >= 0;
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

  /** 单帧进度更新（失败绝不抛出，只做节流日志）。 */
  private static push(): void {
    const id = TaskProgressUpdater.taskNotificationId;
    if (id < 0) {
      return;
    }
    const nodeText = TaskProgressUpdater.lastNodeText;
    // 2026-10-19 用户两轮反馈，合并后的正确口径：
    //   第一轮：「把右侧的那个圆环去掉，改成运行时长」；
    //   第二轮：「我是让你把右侧圆环改成运行时间，你怎么把上传下载的速率改没了」。
    //
    // 实测结论（用户截图 + SDK 文档）：
    //   · 右侧圆环是 downloadTemplate 自带的结构元素，**不是** progressValue 画出来的
    //     —— 删掉 progressValue 后圆环仍在（真机截图确认）；SDK 亦注明长时任务的
    //     系统实况通知「Currently, only downloadTemplate is supported」，换不掉。
    //     因此圆环无法在保留系统实况通知的前提下移除，已在此处注明，避免再次误判。
    //   · 实况通知只有「标题」+「单行正文」两个文本位。既然速率与时长都要保留，
    //     两者只能共用这一行。
    //   · 为不让之前的截断问题重演，速率串做去空格/去 .0 的紧凑化
    //     （"↓ 56.0 KB/s ↑ 0 B/s" → "↓56KB/s ↑0B/s"），时长用 0:00:56 紧凑写法。
    const speed = TaskProgressUpdater.compactSpeed(TaskProgressUpdater.lastSpeedLine);
    const duration = TaskProgressUpdater.lastDurationText;
    const liveLine = duration.length > 0 ? `${speed} · ${duration}` : speed;
    const data: Record<string, Object> = {};
    data['title'] = nodeText;
    data['fileName'] = liveLine;
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
    }).catch((e: Error): void => {
      const now = Date.now();
      if (now - TaskProgressUpdater.lastFailLogAt > FAIL_LOG_THROTTLE_MS) {
        TaskProgressUpdater.lastFailLogAt = now;
        AppLogger.warn(TAG, `progress update failed: ${AppLogger.errText(e)}`);
      }
    });
  }
}
