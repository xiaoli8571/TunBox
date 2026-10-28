/**
 * 一次连接的**事务对象**（2026-10-27 P0）。
 *
 * ## 解决什么
 * 旧 `connect()` 用 `connectSeq`（一个数字）做作废判断，但只在少数位置检查。
 * 一次连接要经过十几个 await：订阅刷新 → DoH → 配置构建 → 扩展拉起 → 控制器就绪
 * → 钉选重试 → `/proxies` 回读 → 重连 → 恢复。任何一步之后用户点了停止/切了节点，
 * 旧连接仍可能继续写设置、提交 `CONNECTED`、覆盖新出口（真机：停止后又自己连上）。
 *
 * 现在每个 await 之后统一调用 `attempt.checkpoint(clock.generation())`：
 * 返回 false 就立刻 CANCELLED 返回，不再写任何状态。
 *
 * ## 为什么带 profileId + profileRevision
 * 「这次连接用的是哪份配置」必须随事务一起走。订阅在连接过程中被刷新时，
 * revision 会变 —— 此时旧事务的钉选/回读结果属于旧配置，必须作废而不是
 * 把它标成当前出口（否则 UI、ProfileStore、内核三方再次分叉）。
 */
export enum AttemptOutcome {
  /** 尚未结束。 */
  PENDING = 0,
  /** 成功（已提交 CONNECTED 且出口回读确认）。 */
  COMPLETED = 1,
  /** 被更新的事务/用户停止作废。 */
  CANCELLED = 2,
  /** 失败（已按错误模型上报）。 */
  FAILED = 3
}

export class ConnectionAttempt {
  /** 自增 id，仅用于日志关联。 */
  readonly id: number;
  /** 事务代数：每次 begin() 递增，唯一权威的「旧/新」判据。 */
  readonly generation: number;
  /** 本次连接针对的 profile id（开始时的 `ProfileRepository.currentId()`）。 */
  readonly profileId: string;
  /** 本次连接针对的 profile revision（开始时的内容指纹）。 */
  readonly profileRevision: string;
  /** 开始时间（ms）。 */
  readonly startedAt: number;
  /** 触发原因（日志用，如 user-tap / reconnect / recover）。 */
  readonly reason: string;

  private cancelled: boolean = false;
  private outcome: AttemptOutcome = AttemptOutcome.PENDING;

  constructor(id: number, generation: number, profileId: string, profileRevision: string,
    reason: string, startedAt: number) {
    this.id = id;
    this.generation = generation;
    this.profileId = profileId;
    this.profileRevision = profileRevision;
    this.reason = reason;
    this.startedAt = startedAt;
  }

  /** 标记作废（用户停止 / 新事务开始）。幂等。 */
  cancel(): void {
    this.cancelled = true;
    if (this.outcome === AttemptOutcome.PENDING) {
      this.outcome = AttemptOutcome.CANCELLED;
    }
  }

  complete(): void {
    if (this.cancelled) { return; }
    this.outcome = AttemptOutcome.COMPLETED;
  }

  fail(): void {
    if (this.cancelled) { return; }
    this.outcome = AttemptOutcome.FAILED;
  }

  isCancelled(): boolean {
    return this.cancelled;
  }

  /** 是否仍在有效期内（未作废且未结束）。 */
  isActive(): boolean {
    return !this.cancelled && this.outcome === AttemptOutcome.PENDING;
  }

  /**
   * **唯一**的继续执行判定。
   *
   * `currentGeneration` 由 `ConnectionAttemptClock.generation()` 提供；
   * 代数不同说明已有更新的事务，本事务必须立刻退出。
   */
  checkpoint(currentGeneration: number): boolean {
    if (this.cancelled) { return false; }
    return this.generation === currentGeneration;
  }

  /** 事务是否仍绑定当前 profile 版本（订阅在连接中被刷新则返回 false）。 */
  sameProfile(profileId: string, profileRevision: string): boolean {
    return this.profileId === profileId && this.profileRevision === profileRevision;
  }

  getOutcome(): AttemptOutcome {
    return this.outcome;
  }

  /** 日志用短标签，不含任何凭据/节点服务器信息。 */
  label(): string {
    return `attempt#${this.id} gen=${this.generation} profile=${this.profileId} `
      + `rev=${this.profileRevision.length > 0 ? this.profileRevision : '-'} reason=${this.reason}`;
  }
}

/**
 * 事务代数时钟。
 *
 * 与编排器里既有的 `connectSeq` 并存一段时间：`connectSeq` 管「请求排队」，
 * 这里管「单次连接事务的有效性」。`begin()` 会同时推进两者由调用方负责。
 */
export class ConnectionAttemptClock {
  private nextId: number = 1;
  private generation: number = 0;
  private current: ConnectionAttempt | null = null;

  /** 开始新事务：旧事务自动作废。 */
  begin(profileId: string, profileRevision: string, reason: string): ConnectionAttempt {
    if (this.current !== null) { this.current.cancel(); }
    this.generation = this.generation + 1;
    const attempt = new ConnectionAttempt(this.nextId++, this.generation, profileId,
      profileRevision, reason, Date.now());
    this.current = attempt;
    return attempt;
  }

  /** 当前代数（没有事务时为 0）。 */
  currentGeneration(): number {
    return this.generation;
  }

  currentAttempt(): ConnectionAttempt | null {
    return this.current;
  }

  /** 新事务是否已经取代了 `attempt`。 */
  superseded(attempt: ConnectionAttempt | null): boolean {
    if (attempt === null) { return true; }
    return attempt.generation !== this.generation || attempt.isCancelled();
  }

  /** 用户停止：作废当前事务并把代数推进，保证旧回调全部失效。 */
  cancelCurrent(): void {
    if (this.current !== null) { this.current.cancel(); }
    this.generation = this.generation + 1;
    this.current = null;
  }
}
