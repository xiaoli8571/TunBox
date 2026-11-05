/**
 * 无界面快捷宿主：桌面图标长按「启动代理」与服务卡片点击的共同落点。
 *
 * 与 EntryAbility 的区别：不 loadContent 任何页面，onCreate 里直接跑
 * VpnQuickStart（后台连接/断开）。
 *
 * ── 会话守护者（2026-09-18 真机取证后的设计变更）──
 * 真机日志证实：`:vpn` 扩展进程内申请长时任务必然 401（连续任务只支持 UIAbility
 * 上下文），卡片宿主进程被回收后应用组失去一切驻留凭证，`:vpn` 在 0.3 秒内被系统
 * 连带回收（exit 0），表现为「卡片启动代理几秒即断且不自愈、卡片仍显示已连接」。
 * 因此连接成功（'on'/'already'）后本能力不再立即自毁，而是：
 *   1) 用自身 UIAbility 上下文注册长时任务（统一走 UiGuardian.applyContinuousTask：
 *      优先 taskKeeping —— 官方长时任务类型表里「计算任务」才是隧道保活的正确类型；
 *      未获 ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM 受限权限时自动回退
 *      dataTransfer，行为与改造前完全一致；需通知权限，用户侧开启）；
 *   2) 保持存活并低频轮询跨进程权威状态（vpn_status 租约），会话终结即释放；
 *   3) 断开/失败/守护被拒 → 释放任务并自毁（removeMissionAfterTerminate 保证不留痕）。
 * 卡片端由此从「message 到 Form 进程内跑连接」改为「router 到本能力」，
 * Form 回调即刻返回，不再长时间占用宿主。
 *
 * 长时任务被取消/暂停后的处置（2026-10-20 合规整改）：按 BackgroundTaskWatch
 * 给出的**取消原因分类**决定 —— 用户主动停止 / 系统判定不合理使用一律不重挂
 * （接入规范红线），一般性系统取消才允许在退避窗口后重挂，且必须先确认会话仍存活。
 *
 * 历史取证（2026-09-10）：本能力「闪一下」是系统为无页面 UIAbility 建启动窗的
 * 必然副产物而非崩溃；窗口隐形化与自毁时序修正保留（见 blindWindow/scheduleSelfDestroy）。
 * 重复点击/在途请求：单航班 + 末次意图合并，绝不吞点击，也不重复拉起。
 */
import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { StageSessionRecovery } from '../commons/services/StageSessionRecovery';
import { UnifiedScheduler } from '../commons/services/UnifiedScheduler';
import { window } from '@kit.ArkUI';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import { BusinessError } from '@kit.BasicServicesKit';
import { VpnQuickStart } from '../commons/services/VpnQuickStart';
import { VpnGuardianPolicy } from '../commons/services/VpnGuardianPolicy';
import { UiGuardian, CONTINUOUS_TASK_DISABLED_DETAIL } from '../commons/services/UiGuardian';
import {
  BackgroundTaskWatch,
  ContinuousTaskCancelListener,
  ContinuousTaskVerdict
} from '../commons/services/BackgroundTaskWatch';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';
import { FormStateSync } from '../commons/services/FormStateSync';
import { ShortcutOutcomeLog, ShortcutOutcomeRecord } from '../commons/services/ShortcutOutcomeLog';
import { AppLogger } from '../commons/utils/AppLogger';
import { PersistentLogStore } from '../commons/services/PersistentLogStore';

const TAG = 'QuickToggleAbility';
/** 明确「只连接」的快捷方式参数值（与 shortcuts_config.json 保持一致） */
const MODE_START = 'start';
/** 无参数/其它值一律按切换处理（服务卡片等入口共用） */
const MODE_TOGGLE = 'toggle';
/** 完全透明色：用于抹掉无界面能力的启动窗与主窗口底色 */
const COLOR_TRANSPARENT = '#00000000';
/**
 * 兜底寿命守护：无页面能力一旦悬留就是一块黑屏，任何异常路径都不允许它常驻。
 * 覆盖最慢建连路径（扩展拉起 + 就绪 + DNS 可达上限），守护模式接管后撤销。
 */
const MAX_LIFETIME_MS = 60000;
/** 自毁前等待 windowStage 就绪的上限（极快的「已连接」短路会早于窗口创建） */
const WINDOW_STAGE_GRACE_MS = 1500;
/** 轮询 windowStage 就绪的步长 */
const WINDOW_STAGE_POLL_MS = 100;
/** 守护期权威态轮询周期：低频，避免电量与调度噪音 */
const GUARDIAN_POLL_MS = 15000;
/** 连续缺失多少次才判定会话终结（≈30s，容忍扩展重启窗口与文件读写抖动） */
const GUARDIAN_MISS_THRESHOLD = 2;

export default class QuickToggleAbility extends UIAbility implements ContinuousTaskCancelListener {
  private running: boolean = false;
  private pendingMode: string = '';
  private windowStageReady: boolean = false;
  private destroyScheduled: boolean = false;
  private destroyed: boolean = false;
  private lifetimeTimer: number = -1;
  /** 守护态：已持有连续任务并轮询会话租约 */
  private guardianActive: boolean = false;
  private bgTaskRegistered: boolean = false;
  private guardianTimer: number = -1;
  private guardianMisses: number = 0;
  private guardianChecking: boolean = false;
  /** 自愈单航班：重连在途时不再叠加新的尝试 */
  private healing: boolean = false;
  /**
   * 长时任务取消后的重挂定时器。
   * 2026-10-20 起时长不再固定：取 BackgroundTaskWatch 分类结论里的退避时长
   * （一般性系统取消 30s；用户主动停止 / 系统判定不合理使用则根本不重挂）。
   */
  private rearmTimer: number = -1;
  /** 主窗口句柄：守护接管后用于最小化回桌面（设备不支持时降级为透明悬窗）。 */
  private mainWindow: window.Window | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    StageSessionRecovery.noteUiLaunch();
    PersistentLogStore.init(this.context, 'quick');
    this.armLifetimeGuard();
    AppLogger.info(TAG, 'headless host created (no page loaded by design)');
    // 长时任务取消/暂停监听（进程级幂等）：按取消原因分类刷新记账，
    // 并决定"退避多久后重挂"或"根本不重挂"（见 onContinuousTaskCancel）。
    BackgroundTaskWatch.ensure();
    BackgroundTaskWatch.addListener(this);
    // 卡片/快捷方式拉起本宿主 = 显式用户操作：清除"用户主动停止后台任务"的抑制态
    UiGuardian.clearExternalCancelSuppression();
    this.enqueue(this.resolveMode(want));
  }

  onSaveState(reason: AbilityConstant.StateType, wantParam: Record<string, Object>): AbilityConstant.OnSaveResult {
    wantParam['tunbox_recovery'] = true;
    return AbilityConstant.OnSaveResult.RECOVERY_AGREE;
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 复用任务栈时的第二次点击（守护期间卡片再次点击 = 断开/重连意图）：必须生效。
    if (this.destroyed) {
      return;
    }
    AppLogger.info(TAG, 'headless host re-used (onNewWant)');
    // 复用任务栈的再次点击同样是显式用户操作（守护期间再次点击 = 断开/重连意图）
    UiGuardian.clearExternalCancelSuppression();
    this.enqueue(this.resolveMode(want));
  }

  onForeground(): void {
    this.drain();
  }

  onBackground(): void {
    PersistentLogStore.flush();
    // 前台的窗口生命周期可能被系统提前收起；在途任务照常继续，这里只做推进。
    this.drain();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.windowStageReady = true;
    this.blindWindow(windowStage);
    this.drain();
  }

  onWindowStageDestroy(): void {
    this.windowStageReady = false;
    this.mainWindow = null;
  }

  onDestroy(): void {
    this.destroyed = true;
    this.running = false;
    this.pendingMode = '';
    this.windowStageReady = false;
    this.clearLifetimeGuard();
    this.clearGuardianTimer();
    if (this.rearmTimer >= 0) {
      clearTimeout(this.rearmTimer);
      this.rearmTimer = -1;
    }
    BackgroundTaskWatch.removeListener(this);
    if (this.bgTaskRegistered) {
      // 兜底：进程被系统直接回收时尽力注销连续任务，避免残留登记。
      this.bgTaskRegistered = false;
      // 记账与进度心跳一并清理（UiGuardian.noteReleased 内部会 detach 进度心跳）。
      UiGuardian.noteReleased();
      backgroundTaskManager.stopBackgroundRunning(this.context).catch((): void => {
        AppLogger.warn(TAG, 'continuous task cleanup failed at destroy');
      });
    }
    AppLogger.info(TAG, 'headless host destroyed');
  }

  /**
   * 长时任务被外部取消（用户在通知栏删除任务通知 / 系统取消）。
   *
   * 处置按 **BackgroundTaskWatch 给出的原因分类** 走（2026-10-20 合规整改）：
   *  - 用户主动停止（USER_CANCEL / USER_CANCEL_REMOVE_NOTIFICATION）
   *    → **不重挂**。官方《Background Tasks Kit 接入规范》把「用户主动停止后
   *      取消长时任务，随即再次申请」列为违规行为；此时只能等显式用户操作
   *      （连接按钮 / 卡片 / 快捷方式 → UiGuardian.clearExternalCancelSuppression()）。
   *  - 系统判定不合理使用（SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED /
   *    SYSTEM_CANCEL_USE_ILLEGALLY 等）→ 同样不重挂（规范明文）。
   *  - 一般性系统取消（SYSTEM_CANCEL 等）→ 允许重挂，但**必须退避**
   *    （verdict.backoffMs，改造前是固定 1 秒），并且要先确认会话仍存活。
   *
   * 改造前这里是"1 秒无条件重挂"，同时命中规范里的两条违规红线。
   */
  onContinuousTaskCancel(id: number, verdict: ContinuousTaskVerdict): void {
    if (!this.bgTaskRegistered && !verdict.hadRegistration) {
      return;
    }
    this.bgTaskRegistered = false;
    AppLogger.warn(TAG,
      `guardian continuous task canceled: id=${id} reason=${verdict.reasonCode} `
      + `category=${verdict.category} allowAutoRearm=${verdict.allowAutoRearm} `
      + `requireUserAction=${verdict.requireUserAction} backoff=${verdict.backoffMs}ms`);
    if (!verdict.allowAutoRearm) {
      AppLogger.warn(TAG,
        `re-arm not allowed (${verdict.summary}); explicit user action required `
        + '(Background Tasks Kit 接入规范：取消后不得立即再次申请长时任务)');
      return;
    }
    // 退避到期后再重挂（退避时长来自分类结论，不再是固定 1 秒）
    if (this.rearmTimer >= 0) {
      clearTimeout(this.rearmTimer);
    }
    this.rearmTimer = setTimeout((): void => {
      this.rearmTimer = -1;
      if (this.destroyed) {
        return;
      }
      this.rearmIfSessionAlive();
    }, verdict.backoffMs);
  }

  /**
   * 长时任务被暂停（suspended=true）/ 从暂停中恢复（suspended=false）。
   *
   * 暂停态的关键含义（SDK 官方说明）：长时任务被暂停后，**应用退到后台会被挂起**
   * ——「一个 UIAbility 申请长时任务后整个应用下的所有进程均不会被挂起」这条
   * 保底资格随之消失（扩展进程定时器停摆 → 存活租约停更 → UI 误判 core died
   * → 拆隧道重连）。因此这里必须把"失去不被挂起资格"明确打进日志。
   *
   * 暂停**不触发重挂**：任务仍然存在（只是被降级），重复申请既无意义也可能失败；
   * 交给后续的 continuousTaskCancel 事件走分类流程。
   */
  onContinuousTaskSuspend(id: number, verdict: ContinuousTaskVerdict, suspended: boolean): void {
    if (suspended) {
      AppLogger.warn(TAG,
        `guardian continuous task suspended: id=${id} reason=${verdict.reasonCode} `
        + `category=${verdict.category} summary=${verdict.summary}; `
        + 'app loses the "never suspended" protection until the task resumes');
      return;
    }
    AppLogger.info(TAG,
      `guardian continuous task resumed: id=${id}; accounting restored`);
    this.bgTaskRegistered = UiGuardian.isRegistered();
  }

  /**
   * 退避到期后的重挂：先确认会话仍存活（用户意图仍是"连接"），再让 UiGuardian
   * 走统一的申请函数。
   *
   * 存活判据与本文件既有的 selfHeal 分支同源：ConnectionOrchestrator 的权威态
   * `desiredConnected`（落盘的用户意图）。UiGuardian 不做跨模块意图查询，
   * 由这里把结论作为参数传进去。
   */
  private rearmIfSessionAlive(): void {
    const orchestrator = ConnectionOrchestrator.instance();
    orchestrator.init(this.context);
    orchestrator.authorityState().then((state): void => {
      if (this.destroyed) {
        return;
      }
      if (!state.desiredConnected) {
        AppLogger.info(TAG, 're-arm skipped: session intent is no longer "connected"');
        return;
      }
      UiGuardian.rearm(this.context, true).then((armed: boolean): void => {
        if (armed) {
          this.bgTaskRegistered = true;
        }
      });
    }).catch((error: Error): void => {
      AppLogger.warn(TAG, `re-arm skipped: authority read failed (${error.message})`);
    });
  }

  /**
   * 把无内容窗口彻底变透明。
   * 这里全部是 UI-only 调用：headless 路径下必须独立 try/catch，
   * 任何失败只降级为「可能可见一闪」，绝不能把整个快捷动作带崩。
   */
  private blindWindow(windowStage: window.WindowStage): void {
    try {
      const mainWindow = windowStage.getMainWindowSync();
      mainWindow.setWindowBackgroundColor(COLOR_TRANSPARENT);
      this.mainWindow = mainWindow;
    } catch (error) {
      AppLogger.warn(TAG,
        `blind window failed (UI-only API): ${AppLogger.errText(error)}`);
    }
  }

  /** 守护接管后自动退回桌面（用户要求 2026-09-18）。minimize 在部分机型返回 801，
   *  失败仅降级为「透明窗口留在桌面」，不影响守护职责。 */
  private retreatToDesktop(): void {
    const target = this.mainWindow;
    if (target === null) {
      AppLogger.warn(TAG, 'guardian retreat skipped: no main window handle');
      return;
    }
    target.minimize().then((): void => {
      AppLogger.info(TAG, 'guardian minimized to desktop');
    }).catch((error: Error): void => {
      const err = error as BusinessError;
      AppLogger.warn(TAG, `guardian minimize unsupported code=${err.code} msg=${err.message}`);
    });
  }

  private resolveMode(want: Want): string {
    const params = want.parameters;
    if (params !== undefined && params['vpn_shortcut'] === MODE_START) {
      return MODE_START;
    }
    return MODE_TOGGLE;
  }

  /** 合并为最后一次有效意图，但绝不因能力已启动或前一次尚未完成而静默丢弃。 */
  private enqueue(mode: string): void {
    if (this.destroyed) {
      return;
    }
    this.pendingMode = mode;
    this.drain();
  }

  private drain(): void {
    if (this.destroyed || this.running || this.pendingMode.length === 0) {
      return;
    }
    const mode = this.pendingMode;
    this.pendingMode = '';
    this.running = true;
    const startedAt = Date.now();
    let outcome = 'failed';
    AppLogger.info(TAG, `quick action started: mode=${mode}`);
    VpnQuickStart.run(mode, this.context).then((result: string): void => {
      outcome = result;
      AppLogger.info(TAG, `quick action done: ${result}`);
      this.recordOutcome(mode, result, '', startedAt);
    }).catch((error: Error): void => {
      AppLogger.error(TAG, `quick action failed: ${error.message}`);
      this.recordOutcome(mode, 'failed', error.message, startedAt);
    }).finally((): void => {
      this.running = false;
      if (this.destroyed) {
        return;
      }
      if (this.pendingMode.length > 0) {
        this.drain();
        return;
      }
      if (VpnGuardianPolicy.shouldGuard(outcome)) {
        this.enterGuardian(outcome);
        return;
      }
      if (this.guardianActive) {
        // 守护期间动作以非守护结果收尾（断开/失败/no_node）：释放后自毁。
        this.releaseGuardian('action-' + outcome);
        return;
      }
      this.scheduleSelfDestroy();
    });
  }

  /**
   * 进入守护：用本 UIAbility 的上下文注册长时任务。
   *
   * 统一走 UiGuardian.applyContinuousTask（全工程唯一调用 startBackgroundRunning
   * 的地方）：优先 taskKeeping（VPN 隧道保活的正确类型），未获受限权限
   * ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM 时自动回退 dataTransfer。
   * 两种类型下的通知内容都由应用自有常驻通知（TunBoxNotifier）承载 —— 不再写系统
   * 实况窗，因为实况窗模板右侧自带圆环（用户要求完全去掉）。
   * 成功 → 常驻并低频轮询权威租约；失败（如通知被禁用）→ 如实记录并恢复自毁路径，
   * 让系统按既有语义处理会话，绝不静默伪装成功。
   */
  private async enterGuardian(outcome: string): Promise<void> {
    this.clearLifetimeGuard();
    try {
      const result = await UiGuardian.applyContinuousTask(this.context);
      // 配置层面关闭长时任务时 detail 为 CONTINUOUS_TASK_DISABLED_DETAIL：
      // 这不是申请失败（不是权限/机型问题），不能走失败自毁分支。
      if (!result.ok && result.detail !== CONTINUOUS_TASK_DISABLED_DETAIL) {
        const detail = `guard-denied(${result.detail})`;
        AppLogger.warn(TAG, `continuous task registration failed: ${detail}`);
        const record = new ShortcutOutcomeRecord();
        record.at = Date.now();
        record.mode = 'guard';
        record.result = 'failed';
        record.detail = detail;
        record.elapsedMs = 0;
        ShortcutOutcomeLog.record(this.context, record);
        this.scheduleSelfDestroy();
        return;
      }
      this.bgTaskRegistered = true;
      UiGuardian.watchSession(this.context, async (): Promise<boolean> => {
        const authority = await ConnectionOrchestrator.instance().authorityState();
        return authority.connected && authority.desiredConnected;
      });
      this.guardianActive = true;
      this.guardianMisses = 0;
      this.armGuardianPoll();
      this.retreatToDesktop();
      AppLogger.info(TAG, `guardian engaged after ${outcome} (type=${result.kind} continuous task registered)`);
    } catch (e) {
      const err = e as BusinessError;
      const detail = `guard-denied(code=${err.code} ${err.message})`;
      AppLogger.warn(TAG, `continuous task registration failed: ${detail}`);
      const record = new ShortcutOutcomeRecord();
      record.at = Date.now();
      record.mode = 'guard';
      record.result = 'failed';
      record.detail = detail;
      record.elapsedMs = 0;
      ShortcutOutcomeLog.record(this.context, record);
      this.scheduleSelfDestroy();
    }
  }

  private armGuardianPoll(): void {
    this.clearGuardianTimer();
    this.guardianTimer = UnifiedScheduler.every((): void => {
      this.checkSessionAlive();
    }, GUARDIAN_POLL_MS);
  }

  private clearGuardianTimer(): void {
    if (this.guardianTimer >= 0) {
      UnifiedScheduler.clear(this.guardianTimer);
      this.guardianTimer = -1;
    }
  }

  /** 跨进程权威判据（与 UI/Form 侧同源）：租约缺失连续达阈值 → 会话终结 → 释放守护。 */
  private checkSessionAlive(): void {
    if (this.destroyed || !this.guardianActive || this.running || this.guardianChecking) {
      return;
    }
    this.guardianChecking = true;
    const orchestrator = ConnectionOrchestrator.instance();
    orchestrator.init(this.context);
    orchestrator.authorityState().then((state): void => {
      this.guardianChecking = false;
      if (this.destroyed || !this.guardianActive) {
        return;
      }
      if (state.connected) {
        this.guardianMisses = 0;
        return;
      }
      this.guardianMisses = VpnGuardianPolicy.normalizeMisses(this.guardianMisses + 1);
      if (!VpnGuardianPolicy.shouldReleaseOnLeaseLoss(this.guardianMisses, GUARDIAN_MISS_THRESHOLD)) {
        return;
      }
      // 会话租约连续缺失 = 隧道没了（扩展进程被回收 / 内核崩溃）。
      // 关键区分：**用户意图是否仍是"想连着"**。
      //  - 意图还在（desiredConnected）：这是"被杀后台"，守护者应该自己爬起来重连；
      //    原来这里无条件 release，等于把"用户还得手动再点一次"当成方案。
      //  - 意图已断：按原语义释放并自毁。
      if (state.desiredConnected) {
        AppLogger.warn(TAG, `guardian lost session x${this.guardianMisses} but intent still on; self-healing`);
        this.selfHeal();
        return;
      }
      AppLogger.warn(TAG, `guardian releasing: session authority lost x${this.guardianMisses}`);
      this.releaseGuardian('session-lost');
    }).catch((error: Error): void => {
      this.guardianChecking = false;
      // 读失败同样计入缺失：守护不能因权威通道损坏而无限驻留。
      if (this.destroyed || !this.guardianActive) {
        return;
      }
      AppLogger.warn(TAG, `guardian authority read failed: ${error.message}`);
      this.guardianMisses = VpnGuardianPolicy.normalizeMisses(this.guardianMisses + 1);
      if (VpnGuardianPolicy.shouldReleaseOnLeaseLoss(this.guardianMisses, GUARDIAN_MISS_THRESHOLD)) {
        this.releaseGuardian('authority-unreadable');
      }
    });
  }

  /** 与前台/冷启动共用恢复链，禁止用快捷启动重放用户意图或另起一组重试。 */
  private selfHeal(): void {
    if (this.destroyed || !this.guardianActive || this.healing) { return; }
    this.healing = true;
    this.guardianMisses = 0;
    ConnectionOrchestrator.instance().restoreKilledSession(this.context).then((reason: string): void => {
      if (this.destroyed || !this.guardianActive) { return; }
      AppLogger.info(TAG, `guardian self-heal: ${reason}`);
      if (reason === 'no-intent' || reason.startsWith('phase-') || reason === 'no-recovery-target') {
        this.releaseGuardian(`recovery-ended:${reason}`);
      }
    }).catch((error: Error): void => {
      AppLogger.warn(TAG, `guardian self-heal failed: ${error.message}`);
    }).finally((): void => { this.healing = false; });
  }

  /** 释放守护：注销连续任务 → 尽力把真实状态刷到卡片 → 自毁。 */
  private releaseGuardian(reason: string): void {
    if (!this.guardianActive) {
      this.scheduleSelfDestroy();
      return;
    }
    this.guardianActive = false;
    this.clearGuardianTimer();
    const stop = this.bgTaskRegistered
      ? backgroundTaskManager.stopBackgroundRunning(this.context).catch((): void => {
        AppLogger.warn(TAG, `stopBackgroundRunning failed (${reason})`);
      })
      : Promise.resolve();
    // 只清理自己持有的登记：若长时任务实际是 EntryAbility 路径挂的，
    // 这里的 stopBackgroundRunning（本能力上下文）也停不掉它，记账不能跟着清。
    const owned: boolean = this.bgTaskRegistered;
    this.bgTaskRegistered = false;
    if (owned) {
      UiGuardian.noteReleased();
    }
    AppLogger.info(TAG, `guardian released (${reason})`);
    stop.then((): Promise<void> => {
      return FormStateSync.calibrate(this.context).then((snapshot): Promise<void> => {
        return FormStateSync.publish(this.context, snapshot);
      }).catch((): void => {
        AppLogger.warn(TAG, 'guardian release card refresh failed');
      });
    }).finally((): void => {
      this.scheduleSelfDestroy();
    });
  }

  private recordOutcome(mode: string, result: string, detail: string, startedAt: number): void {
    const record = new ShortcutOutcomeRecord();
    record.at = Date.now();
    record.mode = mode;
    record.result = result;
    record.detail = detail.length > 0 ? detail : VpnQuickStart.lastDetail();
    record.elapsedMs = Date.now() - startedAt;
    ShortcutOutcomeLog.record(this.context, record);
  }

  /**
   * 自毁时序修正：terminateSelf 必须发生在 windowStage 创建之后。
   * 若在 onCreate 里同步短路完（如「已连接」直接返回 already）就立刻 terminateSelf，
   * 框架会以 null windowStage 走窗口销毁路径（真机 hilog 里的 [JUA2516]null windowStage），
   * 窗口状态错位且有把启动窗留在屏幕上的风险。这里最多等 WINDOW_STAGE_GRACE_MS。
   */
  private scheduleSelfDestroy(): void {
    if (this.destroyScheduled || this.destroyed || this.guardianActive) {
      return;
    }
    this.destroyScheduled = true;
    if (this.windowStageReady) {
      this.terminate('window-stage-ready');
      return;
    }
    let waited = 0;
    const step = (): void => {
      if (this.destroyed) {
        return;
      }
      if (this.windowStageReady) {
        this.terminate('window-stage-late');
        return;
      }
      waited = waited + WINDOW_STAGE_POLL_MS;
      if (waited >= WINDOW_STAGE_GRACE_MS) {
        this.terminate('window-stage-timeout');
        return;
      }
      setTimeout(step, WINDOW_STAGE_POLL_MS);
    };
    setTimeout(step, WINDOW_STAGE_POLL_MS);
  }

  private terminate(reason: string): void {
    if (this.destroyed) {
      return;
    }
    this.destroyed = true;
    this.clearLifetimeGuard();
    this.clearGuardianTimer();
    AppLogger.info(TAG, `terminateSelf (${reason})`);
    this.context.terminateSelf().catch((error: Error): void => {
      // 自毁失败不重试（重试可能循环）：只记录，交给兜底寿命守护与系统回收。
      AppLogger.warn(TAG, `terminateSelf failed: ${error.message}`);
    });
  }

  private armLifetimeGuard(): void {
    this.clearLifetimeGuard();
    this.lifetimeTimer = setTimeout((): void => {
      this.lifetimeTimer = -1;
      if (this.guardianActive) {
        return;
      }
      AppLogger.warn(TAG, 'lifetime guard fired: forcing terminate to avoid a stuck blank window');
      this.terminate('lifetime-guard');
    }, MAX_LIFETIME_MS);
  }

  private clearLifetimeGuard(): void {
    if (this.lifetimeTimer >= 0) {
      clearTimeout(this.lifetimeTimer);
      this.lifetimeTimer = -1;
    }
  }
}
