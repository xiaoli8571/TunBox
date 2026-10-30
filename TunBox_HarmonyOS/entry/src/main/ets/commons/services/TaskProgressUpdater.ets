/**
 * 长时任务通知接线 —— **不再写系统实况窗**（用户要求：去掉通知右侧圆环）。
 *
 * ── 历史（为什么曾经写实况窗）────────────────────────────────────────
 * 长时任务分两种类型（`backgroundTaskManager.BackgroundTaskMode`）：
 *  - DATA_TRANSFER：SDK 注释要求「必须用实况窗（live view）周期更新进度」，
 *    否则 10 分钟不更新进度会被系统取消；
 *  - MODE_TASK_KEEPING：官方接入规范明确「不得修改长时任务通知内容」
 *    （VPN 隧道保活属于这一类）。
 *
 * ── 现状（2026-10-30 用户报障：通知右侧有个圆环，要求完全去掉）────────
 * 真机 `uitest dumpLayout` 抓到的节点树里，TunBox 卡片右侧就是一个
 * `[Progress]` 组件（约 95×95，值 0.000000）—— 它是 `downloadTemplate`
 * **自带的固定结构元素**，不是 progressValue 画出来的：早前删掉 progressValue
 * 后圆环依旧在（真机截图确认），而系统实况通知「当前只支持 downloadTemplate」，
 * 换模板也不行。结论：**只要还在发实况窗，圆环就删不掉**。
 *
 * 因此本文件现在只做一件事：把节点名/速率/运行时长交给应用自己的常驻通知
 * （`TunBoxNotifier`，BASIC_TEXT，没有圆环、没有进度条），系统长时任务通知
 * **原样不动**（不改内容、不改进度），也就不再有实况窗卡片。
 *
 * 代价与取舍（写清楚，避免下次误判）：
 *  - DATA_TRANSFER 的「10 分钟不更新进度会被取消」是 SDK 注释里的要求；
 *  - 这里选择接受该风险，因为用户明确要求去掉圆环，而圆环与实况窗强绑定；
 *  - 兜底仍在：`UiGuardian` 的看门狗会在长时任务丢失时重挂并如实记录日志。
 */
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
  /** 数据传输类型：系统允许更新进度（本工程已不再更新，见文件头） */
  DATA_TRANSFER = 'dataTransfer',
  /** 计算任务类型：不得修改长时任务通知内容 */
  TASK_KEEPING = 'taskKeeping'
}

export class TaskProgressUpdater {
  /** 当前生效的长时任务类型（仅用于日志/诊断，不再决定通知走向） */
  private static kind: ContinuousTaskKind = ContinuousTaskKind.NONE;
  /** 最近一次内容（节点名 / 速率 / 时长），断连重连时用于首帧补齐 */
  private static lastNodeText: string = 'TunBox';
  private static lastSpeedLine: string = '隧道已连接 · 持续保护中';
  private static lastDurationText: string = '';

  /**
   * 内容更新（连接期间由流量轮询周期调用）：节点名进标题、速率+运行时长进正文。
   *
   * 无论哪种长时任务类型都只写应用自有通知 —— 系统长时任务通知一律不碰，
   * 实况窗（圆环）不再发布。
   */
  static updateLive(nodeText: string, speedLine: string, durationText: string): void {
    TaskProgressUpdater.lastNodeText = nodeText.trim().length > 0 ? nodeText.trim() : 'TunBox';
    TaskProgressUpdater.lastSpeedLine = speedLine;
    TaskProgressUpdater.lastDurationText = durationText;
    // 折叠态卡片只渲染「标题 + 正文」两处文本：速率与时长合并进正文同一行，
    // 与通知栏原来的信息口径一致（"↓56KB/s · 0:06:41"）；additionalText 仍是节点名，
    // 展开态多一行，不丢信息。
    const speed = TaskProgressUpdater.compactSpeed(TaskProgressUpdater.lastSpeedLine);
    const liveLine = TaskProgressUpdater.lastDurationText.length > 0
      ? `${speed} · ${TaskProgressUpdater.lastDurationText}`
      : speed;
    TunBoxNotifier.update(`TunBox · ${TaskProgressUpdater.lastNodeText}`,
      TaskProgressUpdater.lastNodeText,
      liveLine).catch((): void => {});
  }

  /**
   * 长时任务申请成功后调用：只记账，**不接管**系统通知 id、**不发布**实况窗、
   * **不撤**应用自有常驻通知（它现在是内容的唯一载体）。
   *
   * @param notificationId 申请返回的长时任务通知 id（仅记录，不写入）
   * @param kind 实际生效的长时任务类型（UiGuardian.currentTaskType()）
   */
  static attach(notificationId: number, kind: ContinuousTaskKind): void {
    TaskProgressUpdater.kind = kind;
    AppLogger.info(TAG,
      `live view disabled: content stays in app notification (taskNotificationId=${notificationId} type=${kind})`);
  }

  /** 释放 / 断开 / 任务取消或被暂停时调用（幂等）。 */
  static detach(): void {
    TaskProgressUpdater.kind = ContinuousTaskKind.NONE;
  }

  /** 当前生效的长时任务类型（诊断用）。 */
  static currentKind(): ContinuousTaskKind {
    return TaskProgressUpdater.kind;
  }

  /** 是否已登记长时任务类型（UiGuardian 看门狗重挂前用于去重）。 */
  static isActive(): boolean {
    return TaskProgressUpdater.kind !== ContinuousTaskKind.NONE;
  }

  /**
   * 速率串紧凑化，用于挤进通知的单行正文。
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
}
