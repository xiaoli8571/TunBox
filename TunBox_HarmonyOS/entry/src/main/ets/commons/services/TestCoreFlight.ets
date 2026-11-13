/**
 * 单航班（single-flight）状态机：并发启动只生效一次，超时可取消，启停不互损。
 *
 * 对应审计项「测速内核启动/停止的并发竞态」：
 * - 并发 ensure() 共享同一个 in-flight Promise → startFn 只被调用一次；
 * - await 期间进入的 stop() 会标脏并让启动结果立刻作废（启动完成即停止），
 *   绝不会出现「后到的 stop 把别人刚拉起的扩展停掉」后又无人重启；
 * - 超时后抛出前先调用 cancelFn 释放已发出的启动；
 * - 失败/超时/停止均回到 IDLE，不残留 ACTIVE 状态。
 *
 * 纯逻辑 + 注入副作用，可在 ohosTest 中直接驱动验证。
 */

export enum TestCoreStatus {
  IDLE = 0,
  STARTING = 1,
  ACTIVE = 2,
  STOPPING = 3
}

export interface SingleFlightDeps {
  /** 实际启动内核：resolve(true)=就绪, resolve(false)=失败, reject=超时/异常 */
  startFn: () => Promise<boolean>;
  /** 取消/释放已发出的启动（超时或启动期间被 stop 时调用） */
  cancelFn: () => Promise<void>;
  /** 启动耗时的硬上限（ms） */
  timeoutMs: number;
  /** 状态变更通知（便于 UI/日志） */
  onStatusChange?: (status: TestCoreStatus) => void;
}

/** 超时哨兵：用于区分「超时」与「启动返回 false」 */
class LaunchTimeoutError extends Error {
  constructor() {
    super('测速内核拉起超时');
  }
}

export class SingleFlightTestCore {
  private status: TestCoreStatus = TestCoreStatus.IDLE;
  private inflight: Promise<boolean> | null = null;
  /** 启动过程中被要求停止：启动落地后立即回收 */
  private stopRequestedWhileStarting: boolean = false;
  /** 启动代际：快速启停/重入时使旧启动结果作废 */
  private generation: number = 0;
  private deps: SingleFlightDeps;

  constructor(deps: SingleFlightDeps) {
    this.deps = deps;
  }

  getStatus(): TestCoreStatus {
    return this.status;
  }

  isActive(): boolean {
    return this.status === TestCoreStatus.ACTIVE;
  }

  /** 是否有启动在途（供 UI 显示「测速内核启动中」） */
  isStarting(): boolean {
    return this.status === TestCoreStatus.STARTING;
  }

  private setStatus(next: TestCoreStatus): void {
    if (this.status !== next) {
      this.status = next;
      if (this.deps.onStatusChange !== undefined) {
        this.deps.onStatusChange(next);
      }
    }
  }

  /**
   * 确保内核就绪。
   * - ACTIVE：直接返回 true（幂等，不重复启动）
   * - STARTING：复用同一 in-flight Promise（并发只启动一次）
   * - 其他：发起新启动
   */
  ensure(): Promise<boolean> {
    if (this.status === TestCoreStatus.ACTIVE) {
      return Promise.resolve(true);
    }
    if (this.status === TestCoreStatus.STARTING && this.inflight !== null) {
      return this.inflight;
    }
    const run = this.run();
    this.inflight = run;
    run.finally((): void => {
      if (this.inflight === run) {
        this.inflight = null;
      }
    });
    return run;
  }

  private async run(): Promise<boolean> {
    this.stopRequestedWhileStarting = false;
    this.setStatus(TestCoreStatus.STARTING);
    const gen = ++this.generation;
    let timeoutTimer: number = -1;
    try {
      const started = await Promise.race<boolean>([
        this.deps.startFn(),
        new Promise<boolean>((resolve, reject) => {
          timeoutTimer = setTimeout(() => {
            reject(new LaunchTimeoutError());
          }, this.deps.timeoutMs);
        })
      ]);
      if (timeoutTimer >= 0) {
        clearTimeout(timeoutTimer);
        timeoutTimer = -1;
      }
      if (gen !== this.generation) {
        // 启动期间已被 stop：不进入 ACTIVE，回收刚拉起的资源
        await this.releaseQuietly();
        this.setStatus(TestCoreStatus.IDLE);
        return false;
      }
      if (this.stopRequestedWhileStarting) {
        // 快速启停：启动成功但已收到停止意图 → 立刻停止，不留残余
        await this.releaseQuietly();
        this.stopRequestedWhileStarting = false;
        this.setStatus(TestCoreStatus.IDLE);
        return false;
      }
      if (!started) {
        this.setStatus(TestCoreStatus.IDLE);
        return false;
      }
      this.setStatus(TestCoreStatus.ACTIVE);
      return true;
    } catch (e) {
      if (timeoutTimer >= 0) {
        clearTimeout(timeoutTimer);
        timeoutTimer = -1;
      }
      // 超时/异常：取消已发出的启动，保证不留残余扩展与配置
      await this.releaseQuietly();
      this.setStatus(TestCoreStatus.IDLE);
      return false;
    }
  }

  /**
   * 停止内核并回收资源。
   * - STARTING：只标脏（不立即 post 停止），避免与在途启动互相 stop；
   *   启动落地后由 run() 统一回收。
   * - ACTIVE：执行 cancelFn。
   * - 已 IDLE：直接返回（幂等）。
   */
  async stop(): Promise<void> {
    if (this.status === TestCoreStatus.IDLE) {
      return;
    }
    if (this.status === TestCoreStatus.STARTING) {
      this.stopRequestedWhileStarting = true;
      this.generation = this.generation + 1;
      if (this.inflight !== null) {
        // 等启动结算完成（run() 内部已做回收），避免并发 stop 互损
        try {
          await this.inflight;
        } catch (e) {
          // 启动失败已由 run() 归零状态
        }
      }
      this.setStatus(TestCoreStatus.IDLE);
      return;
    }
    this.setStatus(TestCoreStatus.STOPPING);
    // 使任何在途启动结果作废（防止启动结束后重新置 ACTIVE）
    this.generation = this.generation + 1;
    try {
      await this.deps.cancelFn();
    } catch (e) {
      // 停止失败不抛出：状态归零，标记已失效
    } finally {
      this.setStatus(TestCoreStatus.IDLE);
    }
  }

  /** 内部释放：吞掉异常，保证状态机不被取消失败卡住 */
  private async releaseQuietly(): Promise<void> {
    try {
      await this.deps.cancelFn();
    } catch (e) {
      // 忽略：未运行时停止会报错，属正常
    }
  }

  /**
   * 强制回到 IDLE（外部已完成资源回收后调用）。
   *
   * 与 stop() 的区别：不触发 cancelFn，因此不会与 teardown 递归；用于
   * 「停扩展失败 / 真实隧道接管了扩展进程」这类「资源已经不由本状态机掌控」
   * 的场景 —— 必须能让下一次 ensure() 真正重新走一遍 stop→start，而不是因为
   * 状态位仍是 ACTIVE 被直接短路。
   * 启动在途（STARTING）时只作废代际，收尾仍由 run() 负责，避免把并发的启动
   * 结算搞乱。
   */
  resetIdle(): void {
    this.generation = this.generation + 1;
    this.stopRequestedWhileStarting = false;
    if (this.status === TestCoreStatus.STARTING) {
      return;
    }
    this.setStatus(TestCoreStatus.IDLE);
  }
}
