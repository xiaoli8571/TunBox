/**
 * UI 进程会话守护（App 内手动连接路径的防杀）+ **长时任务类型协商**。
 *
 * 真机取证（2026-09-24）：只有卡片/快捷方式路径（QuickToggleAbility）注册了
 * 连续任务；App 内手动点启动的路径没有任何驻留凭证 —— UI 进程退后台几分钟即被
 * 系统回收，VpnExtensionAbility 无独立驻留资格，跟着宿主进程组被连带杀掉
 * （表现为"启动没几分钟就被杀"）。
 *
 * 本服务在连接成功后用当前 UIAbility 上下文注册长时任务，断开/失败时释放。
 * HomePage/EntryAbility 驱动 engage/release；会话有效期间每 30 秒核对实际后台任务。
 *
 * ── 合规边界（对照官方《Background Tasks Kit 接入规范》）──────────────────
 *  - **类型**：长时任务类型表里 DATA_TRANSFER =「非托管形式的上传、下载」，
 *    TASK_KEEPING =「计算任务」（场景举例：杀毒软件）。VPN 隧道保活属于后者。
 *    因此本服务**优先申请 taskKeeping**；但 SDK `BackgroundTaskMode` 注释原文：
 *    「... of a non-PC/2-in-1 device is MODE_TASK_KEEPING, you need to request the
 *    ACL permission `ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM` before
 *    calling APIs related to continuous tasks.」—— 受限权限未获 AGC 审批前拿不到
 *    taskKeeping，此时**回退**到 dataTransfer 字符串重载，行为与改造前完全一致
 *    （实况窗 LIVE_VIEW + 5 分钟进度心跳）。dataTransfer 现仅作为回退类型。
 *  - **dataTransfer 的固有风险（已由 SDK 枚举坐实）**：系统会因
 *    「DATA_TRANSFER 类型但传输速率过低」取消 / 暂停长时任务
 *    （ContinuousTaskCancelReason.SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED = 4、
 *    ContinuousTaskSuspendReason.SYSTEM_SUSPEND_DATA_TRANSFER_LOW_SPEED = 4）。
 *    VPN 隧道空闲时用户流量本就低，会稳定踩中 → 长时任务一被取消/暂停，
 *    全应用失去「所有进程不被挂起」的保护 → 扩展进程定时器停摆 → 存活租约停更
 *    → UI 误判 core died → 拆隧道重连。改用 taskKeeping 正是为了拆掉这条链。
 *  - **用户主动停止**：删除长时任务通知 = 用户主动停止后台任务。由
 *    BackgroundTaskWatch 感知并按 reason 分类后，本服务进入抑制态
 *    （autoEngageSuppressed）；抑制期内的自动补挂一律跳过，只有显式用户操作
 *    （连接按钮 / 卡片 / 快捷方式 → clearExternalCancelSuppression()）才会
 *    清除抑制并允许重挂。
 *  - **进度更新**：dataTransfer 要求周期更新进度（首次不得超过 10 分钟），
 *    由 TaskProgressUpdater 用申请返回的 notificationId 承担；taskKeeping
 *    **不得**修改长时任务通知内容（非数据传输任务），故不推实况窗进度，
 *    速率/运行时长继续由应用自有常驻通知（TunBoxNotifier）承载。
 */
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
// `WantAgent` 是模块的**具名类型导出**（不是 wantAgent 命名空间的成员），
// 必须与命名空间一起具名导入 —— 与 TunBoxNotifier.ets 的既有写法一致。
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { AppLogger } from '../utils/AppLogger';
import { TaskProgressUpdater, ContinuousTaskKind } from './TaskProgressUpdater';
import type { ContinuousTaskVerdict } from './BackgroundTaskWatch';

const TAG = 'UiGuardian';
const WATCHDOG_INTERVAL_MS: number = 30000;
const WATCHDOG_RETRY_LIMIT: number = 3;

/**
 * 一次长时任务申请的结果。
 * 调用方据此决定后续接线与日志（不再直接触碰 startBackgroundRunning）。
 */
export class ContinuousTaskApplyResult {
  /** 是否申请成功 */
  ok: boolean = false;
  /** 最终生效的长时任务类型（NONE = 失败） */
  kind: ContinuousTaskKind = ContinuousTaskKind.NONE;
  /** 长时任务通知 id（只有 dataTransfer 会用它推实况窗进度） */
  notificationId: number = -1;
  /** 系统任务 ID 与通知 ID 不同，用于过滤上一会话迟到的取消/暂停事件。 */
  continuousTaskId: number = -1;
  /** 失败原因（成功时为空串） */
  detail: string = '';
}

export class UiGuardian {
  private static registered: boolean = false;
  private static engaging: boolean = false;
  /**
   * 用户主动停止 / 系统判定不合理使用后的**自动**重挂抑制态。
   *
   * 规范依据：《Background Tasks Kit 接入规范》——用户主动停止后取消长时任务，
   * 不得立即再次申请；系统判定应用不合理使用长时任务并取消/暂停后，也不得立即
   * 再次申请。进程级布尔：置 true 后 engage()/rearm() 的自动补挂一律跳过，
   * 只有显式用户操作（连接按钮 / 卡片 / 快捷方式 → clearExternalCancelSuppression()）
   * 才解除。
   *
   * 改造前该字段从未被赋 true（死代码），导致"取消后 1 秒无条件重挂"直接命中
   * 上面两条违规红线 —— 现由 BackgroundTaskWatch 的 reason 分类结果驱动。
   */
  private static autoEngageSuppressed: boolean = false;
  /** 抑制原因（诊断用；只记录，不参与判定） */
  private static suppressReason: string = '';
  /** 最早可重挂时间戳（0 = 无退避限制）；由一般性系统取消事件写入 */
  private static earliestRearmAt: number = 0;
  /** 当前实际生效的长时任务类型（诊断 / 分叉用） */
  private static currentKind: ContinuousTaskKind = ContinuousTaskKind.NONE;
  /** 最近一次申请返回的长时任务通知 id（暂停恢复时用于把进度心跳接回来） */
  private static lastNotificationId: number = -1;
  private static lastContinuousTaskId: number = -1;
  private static retiredTaskIds: number[] = [];
  private static generation: number = 0;
  private static taskWrites: Promise<void> = Promise.resolve();
  private static watchdogTimer: number = -1;
  private static watchdogContext: Context | null = null;
  private static sessionCheck: (() => Promise<boolean>) | null = null;
  private static watchdogBusy: boolean = false;
  private static watchdogCheckId: number = 0;
  private static watchdogAttempts: number = 0;
  private static missingSince: number = 0;
  private static suspended: boolean = false;

  /**
   * **全工程唯一**的长时任务申请入口（唯一调用 startBackgroundRunning 的地方）。
   *
   * 类型选择：
   *  1. 优先 API 21+ 的 `ContinuousTaskRequest` 重载申请
   *     `BackgroundTaskMode.MODE_TASK_KEEPING` + `BackgroundTaskSubmode.SUBMODE_NORMAL_NOTIFICATION`；
   *  2. 失败（无 `KEEP_BACKGROUND_RUNNING_SYSTEM` 授权 / 设备不支持 / 其它错误）
   *     → **回退**到现状的 `['dataTransfer']` 字符串重载，行为与改造前完全一致；
   *  3. 两者都失败 → 如实记 warn，绝不伪装成功。
   *
   * 申请成功后统一做三件事：记账（registered / 类型 / 通知 id）、接线进度心跳
   * （TaskProgressUpdater 按类型分叉）、清理退避门禁。
   */
  static async applyContinuousTask(context: Context): Promise<ContinuousTaskApplyResult> {
    const generation = UiGuardian.generation;
    const operation = UiGuardian.taskWrites.then(async (): Promise<ContinuousTaskApplyResult> => {
      if (generation !== UiGuardian.generation || UiGuardian.autoEngageSuppressed) {
        const cancelled = new ContinuousTaskApplyResult();
        cancelled.detail = 'session ended before registration';
        return cancelled;
      }
      if (UiGuardian.missingSince > 0) {
        if (UiGuardian.watchdogAttempts >= WATCHDOG_RETRY_LIMIT) {
          const exhausted = new ContinuousTaskApplyResult();
          exhausted.detail = 'automatic registration budget exhausted';
          return exhausted;
        }
        // Shared by page refresh and watchdog: neither path bypasses the same budget.
        UiGuardian.watchdogAttempts++;
      }
      const result = await UiGuardian.applyContinuousTaskNow(context, generation);
      if (!result.ok && generation === UiGuardian.generation && !UiGuardian.autoEngageSuppressed) {
        UiGuardian.earliestRearmAt = Math.max(UiGuardian.earliestRearmAt,
          Date.now() + WATCHDOG_INTERVAL_MS);
      }
      return result;
    });
    UiGuardian.taskWrites = operation.then((): void => {}, (): void => {});
    return await operation;
  }

  private static async applyContinuousTaskNow(context: Context,
    generation: number): Promise<ContinuousTaskApplyResult> {
    const result: ContinuousTaskApplyResult = new ContinuousTaskApplyResult();
    let agent: WantAgent | null = null;
    try {
      const agentRequest: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: 'com.tunbox.client',
          moduleName: 'entry',
          abilityName: 'EntryAbility'
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        // UPDATE_PRESENT_FLAG 的 SDK 原文是「替换已存在 WantAgent 的额外信息」
        // （= 复用同一个 WantAgent 记录，不累积垃圾记录），**不是**"把应用拉到
        // 前台"。重挂时真正可见的副作用是系统重新贴出长时任务通知（官方说明：
        // 申请成功会有通知、且不伴随提示音）。
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      agent = await wantAgent.getWantAgent(agentRequest);
    } catch (e) {
      result.detail = `want agent build failed: ${AppLogger.errText(e)}`;
      AppLogger.warn(TAG, `continuous task registration aborted: ${result.detail}`);
      return result;
    }
    if (agent === null) {
      result.detail = 'want agent build returned nothing';
      AppLogger.warn(TAG, `continuous task registration aborted: ${result.detail}`);
      return result;
    }

    // ① 优先 taskKeeping（VPN 隧道保活的正确类型）
    try {
      const request = new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_TASK_KEEPING];
      request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_NORMAL_NOTIFICATION];
      request.wantAgent = agent;
      const res = await backgroundTaskManager.startBackgroundRunning(context, request);
      result.ok = true;
      result.kind = ContinuousTaskKind.TASK_KEEPING;
      result.notificationId = (res !== undefined && res !== null) ? res.notificationId : -1;
      result.continuousTaskId = res?.continuousTaskId ?? -1;
      result.detail = 'taskKeeping';
      await UiGuardian.acceptApplication(context, generation, result);
      AppLogger.info(TAG, 'continuous task registered (type=taskKeeping submode=normalNotification)');
      return result;
    } catch (e) {
      // 最常见原因：非 PC/2-in-1 设备上没有 ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM
      // 受限权限 → 官方 SDK 注释明确要求该权限才能用 MODE_TASK_KEEPING。
      AppLogger.warn(TAG,
        `taskKeeping continuous task request failed, falling back to dataTransfer: ${AppLogger.errText(e)}`);
    }

    // ② 回退 dataTransfer（与改造前完全一致：实况窗 + 5 分钟进度心跳）
    if (generation !== UiGuardian.generation) { return new ContinuousTaskApplyResult(); }
    try {
      const modes: string[] = ['dataTransfer'];
      const res = await backgroundTaskManager.startBackgroundRunning(context, modes, agent);
      result.ok = true;
      result.kind = ContinuousTaskKind.DATA_TRANSFER;
      result.notificationId = (res !== undefined && res !== null) ? res.notificationId : -1;
      result.continuousTaskId = res?.continuousTaskId ?? -1;
      result.detail = 'dataTransfer';
      await UiGuardian.acceptApplication(context, generation, result);
      AppLogger.info(TAG, 'continuous task registered (type=dataTransfer, fallback path)');
      return result;
    } catch (e) {
      result.ok = false;
      result.kind = ContinuousTaskKind.NONE;
      result.detail = `both taskKeeping and dataTransfer failed: ${AppLogger.errText(e)}`;
      AppLogger.warn(TAG, `continuous task registration failed: ${result.detail}`);
      return result;
    }
  }

  private static async acceptApplication(context: Context, generation: number,
    result: ContinuousTaskApplyResult): Promise<void> {
    if (generation !== UiGuardian.generation || UiGuardian.autoEngageSuppressed) {
      try { await backgroundTaskManager.stopBackgroundRunning(context); } catch (e) {
        AppLogger.warn(TAG, `stale task cleanup failed: ${AppLogger.errText(e)}`);
      }
      result.ok = false;
      result.kind = ContinuousTaskKind.NONE;
      result.detail = 'session ended during registration';
      return;
    }
    UiGuardian.onApplied(result);
  }

  /** 申请成功后的统一记账与接线。 */
  private static onApplied(result: ContinuousTaskApplyResult): void {
    UiGuardian.registered = true;
    UiGuardian.currentKind = result.kind;
    UiGuardian.lastNotificationId = result.notificationId;
    UiGuardian.lastContinuousTaskId = result.continuousTaskId;
    UiGuardian.retiredTaskIds = UiGuardian.retiredTaskIds.filter((id: number): boolean =>
      id !== result.continuousTaskId);
    // 成功挂上即解除退避门禁（退避只针对"紧接着的重挂尝试"）
    UiGuardian.earliestRearmAt = 0;
    UiGuardian.missingSince = 0;
    UiGuardian.watchdogAttempts = 0;
    UiGuardian.suspended = false;
    // 进度心跳按类型分叉：dataTransfer 接管通知 id 推实况窗；taskKeeping 不碰通知内容。
    TaskProgressUpdater.attach(result.notificationId, result.kind);
  }

  /**
   * 连接成功后调用（HomePage 连接态同步 / EntryAbility.onBackground 补挂）。
   *
   * 显式用户操作路径（连接按钮 / 卡片 / 快捷方式）请先调
   * clearExternalCancelSuppression() 解除抑制态与退避门禁。
   * 返回 true = 长时任务已挂上；false = 未挂（被抑制 / 退避未到 / 申请失败）。
   */
  static async engage(context: Context, sessionCheck?: () => Promise<boolean>): Promise<boolean> {
    if (sessionCheck !== undefined && !UiGuardian.autoEngageSuppressed) {
      UiGuardian.watchSession(context, sessionCheck);
    }
    if (UiGuardian.registered || UiGuardian.engaging) {
      return UiGuardian.registered;
    }
    if (UiGuardian.missingSince > 0 && UiGuardian.watchdogAttempts >= WATCHDOG_RETRY_LIMIT) {
      return false;
    }
    if (UiGuardian.autoEngageSuppressed) {
      AppLogger.info(TAG,
        `guardian engage skipped: suppressed (${UiGuardian.suppressReason}); explicit user action required`);
      return false;
    }
    if (!UiGuardian.backoffElapsed()) {
      return false;
    }
    UiGuardian.engaging = true;
    try {
      const result: ContinuousTaskApplyResult = await UiGuardian.applyContinuousTask(context);
      if (!result.ok) {
        AppLogger.warn(TAG, `guardian engage failed: ${result.detail}`);
        return false;
      }
      AppLogger.info(TAG, `guardian engaged (type=${result.kind})`);
      return true;
    } catch (e) {
      AppLogger.warn(TAG, `guardian engage threw: ${AppLogger.errText(e)}`);
      return false;
    } finally {
      UiGuardian.engaging = false;
    }
  }

  /** A process-local check, not an OS wakeup or a promise to restart a killed process. */
  static watchSession(context: Context, sessionCheck: () => Promise<boolean>): void {
    UiGuardian.watchdogContext = context;
    UiGuardian.sessionCheck = sessionCheck;
    if (UiGuardian.watchdogTimer >= 0 || UiGuardian.autoEngageSuppressed) { return; }
    UiGuardian.watchdogTimer = setInterval((): void => {
      UiGuardian.checkBackgroundTask().catch((e: Error): void => {
        AppLogger.warn(TAG, `background task check failed: ${AppLogger.errText(e)}`);
      });
    }, WATCHDOG_INTERVAL_MS);
  }

  static isWatching(): boolean {
    return UiGuardian.watchdogTimer >= 0;
  }

  private static stopWatchdog(): void {
    UiGuardian.watchdogCheckId++;
    UiGuardian.watchdogBusy = false;
    if (UiGuardian.watchdogTimer >= 0) { clearInterval(UiGuardian.watchdogTimer); }
    UiGuardian.watchdogTimer = -1;
    UiGuardian.watchdogContext = null;
    UiGuardian.sessionCheck = null;
  }

  private static async checkBackgroundTask(): Promise<void> {
    const context = UiGuardian.watchdogContext;
    const check = UiGuardian.sessionCheck;
    if (context === null || check === null || UiGuardian.watchdogBusy || UiGuardian.engaging
      || UiGuardian.autoEngageSuppressed) { return; }
    const generation = UiGuardian.generation;
    const checkId = ++UiGuardian.watchdogCheckId;
    UiGuardian.watchdogBusy = true;
    try {
      if (!await check()) { return; }
      if (generation !== UiGuardian.generation || UiGuardian.autoEngageSuppressed) { return; }
      // Query failure is unknown, never proof that the task is missing.
      const tasks = await backgroundTaskManager.getAllContinuousTasks(context);
      if (generation !== UiGuardian.generation || UiGuardian.autoEngageSuppressed) { return; }
      for (const task of tasks) {
        const ownsTask = UiGuardian.lastContinuousTaskId >= 0
          ? task.continuousTaskId === UiGuardian.lastContinuousTaskId
          : (UiGuardian.lastNotificationId >= 0
            ? task.notificationId === UiGuardian.lastNotificationId
            : task.backgroundModes.includes(UiGuardian.currentKind));
        if (!ownsTask) { continue; }
        UiGuardian.lastContinuousTaskId = task.continuousTaskId;
        if (task.suspendState) {
          UiGuardian.suspended = true;
          UiGuardian.registered = false;
          TaskProgressUpdater.detach();
          AppLogger.warn(TAG, 'background task is suspended; waiting for system/user action');
          return;
        }
        UiGuardian.registered = true;
        UiGuardian.suspended = false;
        // 暂停/恢复事件可能丢失，自检确认恢复时也要接回 dataTransfer 的进度心跳。
        // 已接回时保持原定时器，避免每 30s 自检都推迟五分钟心跳。
        if (UiGuardian.currentKind === ContinuousTaskKind.DATA_TRANSFER
          && !TaskProgressUpdater.isActive() && UiGuardian.lastNotificationId >= 0) {
          TaskProgressUpdater.attach(UiGuardian.lastNotificationId, UiGuardian.currentKind);
        }
        UiGuardian.missingSince = 0;
        UiGuardian.watchdogAttempts = 0;
        return;
      }
      // 暂停的任务不得当成普通缺失任务重新申请；等待系统确认恢复。
      if (UiGuardian.suspended) { return; }
      UiGuardian.registered = false;
      TaskProgressUpdater.detach();
      if (generation !== UiGuardian.generation || UiGuardian.autoEngageSuppressed) { return; }
      if (UiGuardian.missingSince === 0) {
        UiGuardian.missingSince = Date.now();
        UiGuardian.earliestRearmAt = Math.max(UiGuardian.earliestRearmAt,
          Date.now() + WATCHDOG_INTERVAL_MS);
        AppLogger.warn(TAG, 'background task missing; waiting for recheck/backoff');
        return;
      }
      if (!UiGuardian.backoffElapsed() || UiGuardian.watchdogAttempts >= WATCHDOG_RETRY_LIMIT) { return; }
      if (!await check() || generation !== UiGuardian.generation || UiGuardian.autoEngageSuppressed) { return; }
      await UiGuardian.rearm(context, true);
    } finally {
      if (checkId === UiGuardian.watchdogCheckId) { UiGuardian.watchdogBusy = false; }
    }
  }

  /**
   * 长时任务被取消后的**自动**重挂入口（按取消原因分类决定）。
   *
   * 合规（官方《Background Tasks Kit 接入规范》）：
   *  - 用户主动停止（删通知）/ 系统判定不合理使用 → 抑制态，直接不重挂；
   *  - 一般性系统取消 → 允许重挂，但必须先过退避窗口（默认 30s），不得"立即"申请。
   *
   * @param shouldRearm 调用方给出的"会话是否仍存活"结论（用户意图仍是"连接"）。
   *        UiGuardian 不做跨模块意图查询 —— 由调用方判定后传入（QuickToggleAbility
   *        用 ConnectionOrchestrator.authorityState().desiredConnected）。
   * 返回 true = 重挂成功；false = 未挂（会话已断 / 被抑制 / 退避未到 / 申请失败）。
   */
  static async rearm(context: Context, shouldRearm: boolean): Promise<boolean> {
    if (UiGuardian.registered || UiGuardian.engaging) {
      return UiGuardian.registered;
    }
    if (!shouldRearm) {
      AppLogger.info(TAG,
        'guardian rearm skipped: session is no longer alive (user intent is not "connected")');
      return false;
    }
    if (UiGuardian.autoEngageSuppressed) {
      AppLogger.info(TAG,
        `guardian rearm skipped: suppressed (${UiGuardian.suppressReason}); explicit user action required`);
      return false;
    }
    if (!UiGuardian.backoffElapsed()) {
      return false;
    }
    UiGuardian.engaging = true;
    try {
      const result: ContinuousTaskApplyResult = await UiGuardian.applyContinuousTask(context);
      if (!result.ok) {
        AppLogger.warn(TAG, `guardian rearm failed: ${result.detail}`);
        return false;
      }
      AppLogger.info(TAG, `guardian re-armed (type=${result.kind})`);
      return true;
    } catch (e) {
      AppLogger.warn(TAG, `guardian rearm threw: ${AppLogger.errText(e)}`);
      return false;
    } finally {
      UiGuardian.engaging = false;
    }
  }

  /** 退避门禁：一般性系统取消后必须等够时间才允许再次申请（规范：不得"立即"）。 */
  private static backoffElapsed(): boolean {
    const now: number = Date.now();
    if (UiGuardian.earliestRearmAt > 0 && now < UiGuardian.earliestRearmAt) {
      AppLogger.info(TAG,
        `guardian re-arm gate: backoff not elapsed, ${UiGuardian.earliestRearmAt - now}ms remaining`);
      return false;
    }
    return true;
  }

  /**
   * 外部取消（用户删除长时任务通知 / 系统取消）的记账入口，由 BackgroundTaskWatch 调用。
   *
   * 按 reason 分类结论处理（分类逻辑见 BackgroundTaskWatch.classifyCancelReason）：
   *  - 用户主动停止（USER_CANCEL / USER_CANCEL_REMOVE_NOTIFICATION）
   *    → 置抑制态：不得自动重挂，只有显式用户操作才能解除；
   *  - 系统判定不合理使用（SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED /
   *    SYSTEM_CANCEL_USE_ILLEGALLY 等）→ 同样置抑制态（并记日志说明原因）；
   *  - 一般性系统取消（SYSTEM_CANCEL 等）→ **不**置抑制态，但记录"最早可重挂
   *    时间戳"（退避窗口），避免"立即"再次申请。
   */
  static noteExternalCancel(verdict: ContinuousTaskVerdict): void {
    // 先记录"此前是否持有登记"再清账：监听者据此判断这次事件与本进程是否相关。
    verdict.hadRegistration = UiGuardian.registered;
    UiGuardian.generation++;
    if (UiGuardian.registered) {
      AppLogger.warn(TAG, 'guardian registration cleared by external cancel');
    }
    UiGuardian.registered = false;
    UiGuardian.currentKind = ContinuousTaskKind.NONE;
    UiGuardian.lastNotificationId = -1;
    UiGuardian.retireCurrentTask();
    UiGuardian.lastContinuousTaskId = -1;
    UiGuardian.suspended = false;
    TaskProgressUpdater.detach();

    if (verdict.requireUserAction) {
      UiGuardian.stopWatchdog();
      UiGuardian.autoEngageSuppressed = true;
      UiGuardian.suppressReason = `${verdict.category}/${verdict.summary}`;
      UiGuardian.earliestRearmAt = 0;
      AppLogger.warn(TAG,
        `guardian auto re-arm suppressed: category=${verdict.category} reason=${verdict.reasonCode} `
        + `summary=${verdict.summary}; explicit user action required `
        + '(Background Tasks Kit 接入规范：取消后不得立即再次申请)');
      return;
    }
    if (verdict.allowAutoRearm) {
      // 系统取消事件已经确认任务缺失，下一次自检只需等同一轮退避。
      UiGuardian.missingSince = Date.now();
      UiGuardian.earliestRearmAt = Date.now() + verdict.backoffMs;
      AppLogger.info(TAG,
        `guardian auto re-arm allowed after backoff: category=${verdict.category} reason=${verdict.reasonCode} `
        + `backoff=${verdict.backoffMs}ms earliestRearmAt=${UiGuardian.earliestRearmAt}`);
      return;
    }
    // 既不允许自动重挂、又不要求用户显式操作（分类上不应出现）：保守按抑制处理。
    UiGuardian.autoEngageSuppressed = true;
    UiGuardian.suppressReason = `${verdict.category}/${verdict.summary}`;
    AppLogger.warn(TAG,
      `guardian auto re-arm suppressed (conservative fallback): category=${verdict.category} `
      + `reason=${verdict.reasonCode} summary=${verdict.summary}`);
  }

  /**
   * 外部暂停 / 恢复的记账入口，由 BackgroundTaskWatch 调用。
   *
   * 暂停态的关键含义：长时任务被暂停后，**应用退到后台会被挂起** —— 「一个
   * UIAbility 申请长时任务后整个应用下的所有进程均不会被挂起」这条保底资格
   * 随之消失（扩展进程定时器停摆 → 存活租约停更 → UI 误判 core died）。
   * 恢复时（suspendState=false）任务仍然存在，只需恢复记账。
   */
  static noteExternalSuspend(verdict: ContinuousTaskVerdict, suspended: boolean): void {
    UiGuardian.suspended = suspended;
    if (suspended) {
      UiGuardian.generation++;
      UiGuardian.registered = false;
      TaskProgressUpdater.detach();
      if (verdict.requireUserAction) {
        UiGuardian.stopWatchdog();
        UiGuardian.autoEngageSuppressed = true;
        UiGuardian.suppressReason = `${verdict.category}/${verdict.summary}`;
      }
      AppLogger.warn(TAG,
        `guardian suspended: category=${verdict.category} reason=${verdict.reasonCode} `
        + `summary=${verdict.summary}; app loses the "never suspended" protection while suspended`);
      return;
    }
    // 恢复：任务重新激活 → 重新记账（dataTransfer 还要把进度心跳接回来）
    UiGuardian.registered = true;
    if (UiGuardian.currentKind === ContinuousTaskKind.DATA_TRANSFER && UiGuardian.lastNotificationId >= 0) {
      TaskProgressUpdater.attach(UiGuardian.lastNotificationId, UiGuardian.currentKind);
    }
    AppLogger.info(TAG, `guardian resumed: type=${UiGuardian.currentKind} (accounting restored)`);
  }

  /** 断开/失败后调用：释放连续任务（幂等）。stopBackgroundRunning 必须 UIAbility 上下文。 */
  static async release(context: Context): Promise<void> {
    const hadTask = UiGuardian.registered || UiGuardian.engaging;
    UiGuardian.noteReleased();
    // Serialized behind pending starts: a late platform reply cannot revive a disconnected session.
    const operation = UiGuardian.taskWrites.then(async (): Promise<void> => {
      if (!hadTask) { return; }
      try {
        await backgroundTaskManager.stopBackgroundRunning(context);
        AppLogger.info(TAG, 'guardian released');
      } catch (e) {
        const err = e as BusinessError;
        AppLogger.warn(TAG, `guardian release failed (code=${err.code} ${err.message})`);
      }
    });
    UiGuardian.taskWrites = operation.then((): void => {}, (): void => {});
    await operation;
  }

  /**
   * 释放路径的记账清理（真正的 stopBackgroundRunning 由持有该 UIAbility 上下文的
   * 调用方执行）。QuickToggleAbility 在 onDestroy / releaseGuardian 里调用。
   */
  static noteReleased(): void {
    UiGuardian.generation++;
    UiGuardian.stopWatchdog();
    UiGuardian.suspended = false;
    UiGuardian.missingSince = 0;
    UiGuardian.watchdogAttempts = 0;
    UiGuardian.registered = false;
    UiGuardian.currentKind = ContinuousTaskKind.NONE;
    UiGuardian.lastNotificationId = -1;
    UiGuardian.retireCurrentTask();
    UiGuardian.lastContinuousTaskId = -1;
    UiGuardian.earliestRearmAt = 0;
    TaskProgressUpdater.detach();
  }

  static isRegistered(): boolean {
    return UiGuardian.registered;
  }

  /** Cancel/suspend IDs are continuous-task IDs, never notification IDs. */
  static ownsTaskEvent(taskId: number): boolean {
    if (UiGuardian.retiredTaskIds.includes(taskId)) { return false; }
    if (UiGuardian.lastContinuousTaskId >= 0 && taskId >= 0) {
      return taskId === UiGuardian.lastContinuousTaskId;
    }
    // Older SDKs may omit the ID in the registration reply; retain the legacy path
    // only while this process actually owns or is applying a task.
    return UiGuardian.registered || UiGuardian.engaging || UiGuardian.suspended;
  }

  private static retireCurrentTask(): void {
    const id = UiGuardian.lastContinuousTaskId;
    if (id < 0 || UiGuardian.retiredTaskIds.includes(id)) { return; }
    UiGuardian.retiredTaskIds.push(id);
    if (UiGuardian.retiredTaskIds.length > 16) { UiGuardian.retiredTaskIds.shift(); }
  }

  /**
   * 显式用户操作（连接按钮 / 卡片 / 快捷方式）入口调用：
   * 清除抑制态与退避门禁，允许再次申请长时任务。
   */
  static clearExternalCancelSuppression(): void {
    if (UiGuardian.autoEngageSuppressed) {
      AppLogger.info(TAG,
        `auto-engage suppression cleared by explicit user action (reason=${UiGuardian.suppressReason})`);
    }
    UiGuardian.autoEngageSuppressed = false;
    UiGuardian.suppressReason = '';
    UiGuardian.earliestRearmAt = 0;
    UiGuardian.missingSince = 0;
    UiGuardian.watchdogAttempts = 0;
  }

  static isAutoEngageSuppressed(): boolean {
    return UiGuardian.autoEngageSuppressed;
  }

  /** 当前实际生效的长时任务类型（诊断 / 分叉用）。 */
  static currentTaskType(): ContinuousTaskKind {
    return UiGuardian.currentKind;
  }

  /** 最早可重挂时间戳（0 = 无退避限制），供诊断展示。 */
  static earliestRearmAtMs(): number {
    return UiGuardian.earliestRearmAt;
  }
}
