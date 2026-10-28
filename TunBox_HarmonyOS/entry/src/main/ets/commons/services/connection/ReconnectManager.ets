/**
 * 重连管理器（2026-10-28 架构整改 Phase 3）
 *
 * 为什么必须独立：重连是一条**有状态的长生命周期流程**（定时器 + 尝试计数 + 退避预算 +
 * 代数判定），把它留在 `ConnectionOrchestrator` 里，结果是
 *   ① 编排器里散落 6 个重连字段，任何一次 connect 改动都要同时想「这些字段要不要重置」；
 *   ② 「用户断开后旧定时器不得复活」这种绝对优先级约束，只能靠每个回调各自记得检查；
 *   ③ 重连时序无法单测（只能连整台编排器）。
 *
 * 现在本类独占全部重连状态，编排器只提供**只读查询**与**一次真实尝试**：
 * ```
 *   request(reason)                     ← 网络切换 / 核被杀 / 用户请求
 *     └─ 意图+代数+单航班+预算 判定
 *          └─ setTimeout(退避) ──→ host.runAttempt(reason)
 *                                    └─ SUCCESS / FAILED / SUPERSEDED
 * ```
 *
 * 三条不可退让的规则（都有门禁验证）：
 * 1. **用户断开绝对优先**：`host.userDisconnected()` 为真时，任何 await 之后都必须放弃，
 *    且不得再排新定时器（`disconnectRequested` 不会被任何重连路径改写）。
 * 2. **代数失效即作废**：`sessionGeneration()` 变了（新一轮 connect/断开）⇒ 旧回调静默退出。
 * 3. **单航班**：正在 CONNECTING 或已有挂起定时器时，新请求只合并，不叠加。
 */
import { AppLogger } from '../../utils/AppLogger';
import { ReconnectPolicy } from '../ReconnectPolicy';
import { ReconnectReason } from '../ConnectionEvents';

const TAG: string = 'ReconnectManager';

/** 一次真实重连尝试的结局（由宿主判定，管理器只做后续编排） */
export enum ReconnectAttemptOutcome {
  /** 已连上，重连链路结束 */
  SUCCESS = 0,
  /** 尝试执行了但失败 —— 进入预算判定，可继续退避重试 */
  FAILED = 1,
  /** 尝试已被新的连接事务/用户断开取代 —— 不重试、不必计数 */
  SUPERSEDED = 2
}

/**
 * 宿主能力（`ConnectionOrchestrator` 提供）。
 *
 * 用**函数字段的类**而不是 interface：ArkTS 下 interface 的多实现容易在编译期报
 * 属性可赋值性错误，而带默认实现的类天然是「可替换的替身」——门禁沙箱里
 * `new ReconnectHost()` 就是一个安全空宿主，不必手写一份镜像桩。
 */
export class ReconnectHost {
  /** 用户连接意图（进程内状态优先，否则读持久化快照） */
  wantsConnected: () => Promise<boolean> = (): Promise<boolean> => Promise.resolve(false);
  /** 用户已主动断开（绝对优先，任何路径都不得越过） */
  userDisconnected: () => boolean = (): boolean => true;
  /** 物理网络不可用 */
  networkDown: () => boolean = (): boolean => false;
  /** 已有连接事务在飞（单航班） */
  connectInFlight: () => boolean = (): boolean => false;
  /** 是否还有可用的上一次端点（订阅 + 节点名） */
  hasEndpoint: () => boolean = (): boolean => false;
  /** 连接事务代数：变了说明这次尝试已被取代 */
  sessionGeneration: () => number = (): number => 0;
  networkType: () => string = (): string => 'unknown';
  networkGeneration: () => number = (): number => 0;
  watcherSubscribed: () => boolean = (): boolean => false;
  /** 真正执行一次重连（编排器负责找节点、connect、判定是否已被取代） */
  runAttempt: (reason: string) => Promise<ReconnectAttemptOutcome> =
    (): Promise<ReconnectAttemptOutcome> => Promise.resolve(ReconnectAttemptOutcome.FAILED);
  /** 重连态变化（供 UI 刷新/事件总线） */
  onChanged: () => void = (): void => {};
  /** 预算耗尽或无法继续（把可读原因交给 UI） */
  onGiveUp: (message: string) => void = (): void => {};
}

/** 重连链路计数（Phase 11 观测口径：冷启动/恢复/重连各自可解释） */
export class ReconnectTelemetry {
  /** 成功排入退避的请求数 */
  scheduled: number = 0;
  /** 实际执行的尝试数 */
  started: number = 0;
  succeeded: number = 0;
  failed: number = 0;
  /** 因预算耗尽/无端点/意图断开而放弃的次数（放弃也要可解释） */
  gaveUp: number = 0;
  /** 被合并掉的重复请求（同一时刻只允许一个挂起定时器） */
  coalesced: number = 0;
}

/** 重连运行态快照（诊断面板/UI 只读） */
export class ReconnectRuntimeState {
  /** 是否有挂起的重连定时器 */
  active: boolean = false;
  /** 是否正在执行重连（单航班） */
  connecting: boolean = false;
  /** 已发起的重连尝试次数 */
  attempts: number = 0;
  /** 最大尝试次数 */
  maxAttempts: number = 3;
  /** 下一次重连的退避延迟（ms） */
  pendingDelayMs: number = 0;
  /** 触发原因（network-changed / network-restored / ...） */
  reason: string = '';
  /** 当前网络类型 */
  networkType: string = 'unknown';
  /** 网络事件代数 */
  networkGeneration: number = 0;
  /** 网络监听是否已订阅 */
  watcherSubscribed: boolean = false;
  /** 链路计数 */
  telemetry: ReconnectTelemetry = new ReconnectTelemetry();
}

export class ReconnectManager {
  private readonly host: ReconnectHost;
  private readonly baseMs: number;
  private readonly maxAttempts: number;
  private maxMs: number;
  private timerId: number = -1;
  private attempts: number = 0;
  private reasonText: string = '';
  private pendingDelayMs: number = 0;
  private readonly telemetry: ReconnectTelemetry = new ReconnectTelemetry();

  constructor(host: ReconnectHost, baseMs: number, maxMs: number, maxAttempts: number) {
    this.host = host;
    this.baseMs = baseMs > 0 ? baseMs : 1000;
    this.maxMs = maxMs > 0 ? maxMs : 8000;
    this.maxAttempts = maxAttempts > 0 ? maxAttempts : 3;
  }

  /** 退避上限可配（ms）；已挂起的定时器不受影响（下次调度生效） */
  setMaxDelay(ms: number): void {
    if (ms > 0) {
      this.maxMs = ms;
    }
  }

  /** 是否已有挂起的退避定时器 */
  isScheduled(): boolean {
    return this.timerId >= 0;
  }

  /** 当前尝试计数（日志/UI 用） */
  attemptCount(): number {
    return this.attempts;
  }

  maxAttemptCount(): number {
    return this.maxAttempts;
  }

  /**
   * 处理「用户断开 / 已连上 / 停止监听」：取消挂起定时器。
   *
   * ⚠ 只清定时器，**不清尝试计数**：计数代表「本轮重连链路已试了几次」，
   * 由 `resetAttempts()` 显式复位（连上/新会话/用户断开时）。两件事混在一起
   * 会让「取消一次定时器」意外重置预算，从而允许无限重试。
   */
  cancel(reason: string): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
      this.pendingDelayMs = 0;
      AppLogger.info(TAG, `[reconnect] timer cancelled (${reason})`);
    }
  }

  /** 复位尝试计数与触发原因（新一轮会话 / 已连上 / 用户断开） */
  resetAttempts(): void {
    this.attempts = 0;
    this.reasonText = '';
    this.pendingDelayMs = 0;
  }

  /**
   * 请求一次（可能退避延后的）重连。单航班：已有挂起定时器则合并。
   *
   * 同步返回：调用点（网络回调 / 核死亡上报）不应该 await 重连 —— 它们只表达意图。
   */
  request(reason: ReconnectReason): void {
    this.requestAsync(reason).catch((e: Object): void => {
      AppLogger.warn(TAG, `reconnect scheduling failed: ${AppLogger.errText(e)}`);
    });
  }

  /**
   * `request()` 的可 await 版本：只给「门禁 / 诊断面板」这类需要确定性时序的调用点用。
   * 业务调用点一律用 `request()`（同步表达意图，绝不 await 重连）。
   */
  async requestAsync(reason: string): Promise<void> {
    await this.schedule(reason);
  }

  /** 直接执行一次重连（诊断面板「立即重连」/门禁直击尝试路径），跳过退避等待 */
  async fireNow(reason: string): Promise<void> {
    await this.run(reason);
  }

  /** 只读快照 */
  snapshot(connecting: boolean): ReconnectRuntimeState {
    const r = new ReconnectRuntimeState();
    r.active = this.timerId >= 0;
    r.connecting = connecting;
    r.attempts = this.attempts;
    r.maxAttempts = this.maxAttempts;
    r.pendingDelayMs = this.pendingDelayMs;
    r.reason = this.reasonText;
    r.networkType = this.host.networkType();
    r.networkGeneration = this.host.networkGeneration();
    r.watcherSubscribed = this.host.watcherSubscribed();
    r.telemetry = this.telemetry;
    return r;
  }

  // ── 内部：调度 ───────────────────────────────────────────────────

  private async schedule(reason: string): Promise<void> {
    // 代数在**任何 await 之前**取样：意图查询是异步的，期间可能已被新事务/断开取代。
    const generation = this.host.sessionGeneration();
    if (this.host.userDisconnected()) {
      AppLogger.info(TAG, `[reconnect] user-disconnected; skip (${reason})`);
      return;
    }
    const intent = await this.host.wantsConnected();
    if (generation !== this.host.sessionGeneration() || this.host.userDisconnected()
      || this.host.networkDown()) {
      return;
    }
    if (!intent) {
      AppLogger.info(TAG, `[reconnect] intent=disconnected; skip (${reason})`);
      return;
    }
    if (this.timerId >= 0) {
      this.telemetry.coalesced = this.telemetry.coalesced + 1;
      AppLogger.info(TAG, `[reconnect] already scheduled; coalesce (${reason})`);
      return;
    }
    if (this.host.connectInFlight()) {
      AppLogger.info(TAG, `[reconnect] connect in flight; skip (${reason})`);
      return;
    }
    if (ReconnectPolicy.exhausted(this.attempts, this.maxAttempts)) {
      this.telemetry.gaveUp = this.telemetry.gaveUp + 1;
      AppLogger.warn(TAG, `[reconnect] max attempts(${this.maxAttempts}) reached; give up (${reason})`);
      this.host.onGiveUp('网络切换后自动重连多次失败，已停止自动重试');
      return;
    }
    const delay: number = ReconnectPolicy.delayMs(this.attempts + 1, this.baseMs, this.maxMs);
    this.attempts = this.attempts + 1;
    this.reasonText = reason;
    this.pendingDelayMs = delay;
    this.telemetry.scheduled = this.telemetry.scheduled + 1;
    AppLogger.info(TAG, `[reconnect] schedule ${ReconnectPolicy.describeBackoff(
      this.attempts, this.maxAttempts, delay)} (${reason})`);
    this.host.onChanged();
    this.timerId = setTimeout((): void => {
      this.timerId = -1;
      this.pendingDelayMs = 0;
      this.run(reason).catch((e: Object): void => {
        AppLogger.warn(TAG, `scheduled reconnect failed: ${AppLogger.errText(e)}`);
      });
    }, delay);
  }

  // ── 内部：执行一次尝试 ────────────────────────────────────────────

  private async run(reason: string): Promise<void> {
    const generation = this.host.sessionGeneration();
    if (this.host.userDisconnected()) {
      // 用户断开 ⇒ 本轮链路结束，计数清零（下一次用户连接要从头计预算）。
      AppLogger.info(TAG, '[reconnect] cancelled by user disconnect before attempt');
      this.resetAttempts();
      this.host.onChanged();
      return;
    }
    if (!this.host.hasEndpoint()) {
      this.telemetry.gaveUp = this.telemetry.gaveUp + 1;
      AppLogger.warn(TAG, '[reconnect] no previous endpoint; abort');
      return;
    }
    const intent = await this.host.wantsConnected();
    if (generation !== this.host.sessionGeneration() || this.host.userDisconnected()
      || this.host.networkDown()) {
      return;
    }
    if (!intent) {
      AppLogger.info(TAG, '[reconnect] intent disconnected; abort');
      this.resetAttempts();
      return;
    }
    if (this.host.connectInFlight()) {
      AppLogger.info(TAG, '[reconnect] connect in flight; abort'); // 单航班
      return;
    }
    this.telemetry.started = this.telemetry.started + 1;
    AppLogger.info(TAG, `[reconnect] attempt ${this.attempts}/${this.maxAttempts} (${reason})`);
    const outcome = await this.host.runAttempt(reason);
    if (outcome === ReconnectAttemptOutcome.SUCCESS) {
      this.telemetry.succeeded = this.telemetry.succeeded + 1;
      AppLogger.info(TAG, `[reconnect] success (${reason})`);
      this.resetAttempts();
      this.cancel('reconnected');
      return;
    }
    if (outcome === ReconnectAttemptOutcome.SUPERSEDED) {
      // 新事务已经接管（或用户断开）：旧链路不得继续排重试。
      return;
    }
    this.telemetry.failed = this.telemetry.failed + 1;
    AppLogger.warn(TAG, `[reconnect] attempt failed (${reason})`);
    if (this.host.userDisconnected()) {
      this.resetAttempts();
      return;
    }
    if (this.attempts < this.maxAttempts) {
      this.request(ReconnectReason.RETRY);
    } else {
      this.telemetry.gaveUp = this.telemetry.gaveUp + 1;
      this.host.onGiveUp('网络切换后自动重连失败（已达最大尝试次数）');
    }
  }
}
