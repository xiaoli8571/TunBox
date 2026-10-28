/**
 * 重连退避策略（2026-10-27：从 `ConnectionOrchestrator` 抽出的纯函数边界）
 *
 * 这里只做**计算**，不持有定时器、不碰连接流程：
 * 给定尝试次数，返回该等多久、是否已达上限。
 * 之所以先抽这一块：它是重连逻辑里唯一「无副作用」的部分，
 * 抽出来可以单测（门禁 ev7 直接算表），而实时调度仍留在编排器里，
 * 避免在无法真机验证网络切换的窗口里改动重连时序。
 */
export class ReconnectPolicy {
  /** 指数退避：base * 2^(attempt-1)，封顶 maxMs。attempt 从 1 开始。 */
  static delayMs(attempt: number, baseMs: number, maxMs: number): number {
    const n = attempt < 1 ? 1 : attempt;
    const scaled = baseMs * Math.pow(2, n - 1);
    return scaled < maxMs ? scaled : maxMs;
  }

  /** 是否已达最大尝试次数（达到即停止自动重试）。 */
  static exhausted(attempts: number, maxAttempts: number): boolean {
    return attempts >= maxAttempts;
  }

  /** 给人看的退避描述，日志与 UI 共用，避免两处各拼一套。
   *
   *  注意命名：**不叫 `describe`**。`describe` 在工程里是「节点失败文案表」的唯一入口
   *  （`LatencyStore.describe`），门禁 ND03 会把它之外的任何 `static describe(` 判成
   *  第二张文案表。这里描述的是重连退避参数，不是节点失败话术，故用独立名字。
   */
  static describeBackoff(attempts: number, maxAttempts: number, delayMs: number | null): string {
    if (delayMs !== null && delayMs > 0) {
      return `attempt ${attempts}/${maxAttempts} in ${delayMs}ms`;
    }
    return `attempt ${attempts}/${maxAttempts}`;
  }
}
