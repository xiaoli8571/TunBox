/**
 * 统一调度器（2026-10-27：替换散落的 setInterval）
 *
 * 问题：页面/服务各自 `setInterval`，扫描到 14 处独立定时器（HomePage 3、FormStateSync 2、
 * VpnExtensionAbility 2、QuickToggleAbility、NodeSelectionPage、ConnectionsPage、UiGuardian、
 * TaskProgressUpdater、CelestialPowerOrb…）。单看每个都不贵，叠起来就是持续唤醒。
 *
 * 方案：**一个**底层 tick（250ms），所有周期任务按各自间隔挂到它上面。
 * 对齐语义：`every(1000, cb)` 仍是「大约每 1s 一次」，但只在需要的那一 tick 上执行，
 * 且所有任务共享同一次唤醒 —— 唤醒次数从「任务数 × 频率」降到「1 × 4/s」。
 *
 * 约束：
 * - 回调里不得抛异常（内部已 try/catch 隔离，但仍应自行处理）；
 * - 用返回的 token 取消；`clear(token)` 幂等；
 * - 不用于精确计时（需要 <250ms 精度请直接用 setTimeout）。
 */
class ScheduledTask {
  id: number = 0;
  intervalMs: number = 0;
  /** 下一次应执行的绝对时间（ms） */
  nextAt: number = 0;
  callback: () => void;

  constructor(id: number, intervalMs: number, nextAt: number, callback: () => void) {
    this.id = id;
    this.intervalMs = intervalMs;
    this.nextAt = nextAt;
    this.callback = callback;
  }
}

export class UnifiedScheduler {
  private static readonly TICK_MS: number = 250;
  private static timer: number = -1;
  private static nextId: number = 1;
  private static tasks: ScheduledTask[] = [];

  /**
   * 每 intervalMs 执行一次；返回 token。
   * 参数顺序与 `setInterval(callback, ms)` **保持一致**，便于整仓平移替换。
   */
  static every(callback: () => void, intervalMs: number): number {
    const step = Math.max(UnifiedScheduler.TICK_MS, Math.floor(intervalMs));
    const id = UnifiedScheduler.nextId++;
    UnifiedScheduler.tasks.push(new ScheduledTask(id, step, Date.now() + step, callback));
    UnifiedScheduler.ensureRunning();
    return id;
  }

  /** 取消；token 无效时无副作用。 */
  static clear(token: number): void {
    if (token <= 0) { return; }
    const kept: ScheduledTask[] = [];
    for (const t of UnifiedScheduler.tasks) {
      if (t.id !== token) { kept.push(t); }
    }
    UnifiedScheduler.tasks = kept;
    if (UnifiedScheduler.tasks.length === 0) {
      UnifiedScheduler.stop();
    }
  }

  /** 当前挂载任务数（自检/门禁用）。 */
  static count(): number {
    return UnifiedScheduler.tasks.length;
  }

  private static ensureRunning(): void {
    if (UnifiedScheduler.timer >= 0) { return; }
    UnifiedScheduler.timer = setInterval((): void => {
      UnifiedScheduler.tick();
    }, UnifiedScheduler.TICK_MS);
  }

  private static stop(): void {
    if (UnifiedScheduler.timer >= 0) {
      clearInterval(UnifiedScheduler.timer);
      UnifiedScheduler.timer = -1;
    }
  }

  private static tick(): void {
    const now = Date.now();
    const snapshot: ScheduledTask[] = [];
    for (const t of UnifiedScheduler.tasks) { snapshot.push(t); }
    for (const t of snapshot) {
      if (now < t.nextAt) { continue; }
      // 先推进时间戳：回调里即使 clear 自己也不会重复触发
      t.nextAt = now + t.intervalMs;
      try {
        t.callback();
      } catch (err) {
        // 隔离：单个任务异常不得拖垮其他任务
      }
    }
  }
}
