/**
 * 有上限的并发刷新调度器（订阅页「全部刷新」与节点页顶栏「刷新」共用）。
 *
 * 为什么并发只加在「拉取」上，而解析/变更/落盘必须串行：
 *   SubscriptionService.refreshSubscription 的真实写路径（行号见本次交付报告）不是可重入的：
 *     1. `this.nodes = this.nodes.filter(...).concat(parsed)`（读-改-写）与
 *        `sub.nodeCount / sub.lastFetchedAt / sub.lastRefreshResult` 的整表落盘是**全局**的；
 *     2. 每次成功都会 `await persist()` 整表写 KEY_SUBS / KEY_NODES / KEY_HIDDEN 再 flush，
 *        两个刷新同时落盘 = 后写覆盖先写（丢节点 / 丢订阅统计）；
 *     3. 解析阶段的 `YamlMerger.resetSkipStats() / lastSkippedCount / lastSkippedTypes`
 *        是**模块级静态状态**，两个解析交错会互相污染（诊断归因错乱）；
 *     4. `this.lastImportDiagnostics` 是单个共享字段。
 *   因此本调度器的语义是：**prepare（网络 I/O）并发、apply（解析+改内存+落盘）串行**。
 *   apply 排在同一条 promise 写入链上（前一条 apply 完成前，下一条不会开始），
 *   既不丢节点、不互相覆盖，单条失败也不影响其它条；串行顺序 = 完成顺序（确定、可复现）。
 *
 * 参数与限流策略：
 *   lanes      并发上限（默认 4 = DEFAULT_LANES，可调）；实际 lane 数 = normalizeLanes(lanes, 条数)
 *   限流降速   prepare 回报 rateLimited=true（HTTP 429/403）时，剩余并发上限减半（floor 1），
 *              已经在途的请求不打断、后续任务少发；**全部条目都只尝试一次，无任何重试路径**。
 *
 * 本文件不得 import 任何 HarmonyOS SDK：纯逻辑，Node 侧可直接加载做离线回归
 * （scripts/verify-concurrent-refresh.mjs 用 type-stripping 加载本文件本体）。
 */

/** 并发阶段（单条订阅的网络拉取）的结果。只携带数据，不含任何共享状态副作用。 */
export class RefreshPrepOutcome {
  /** 并发单元的唯一键（订阅 id） */
  id: string = '';
  /** 并发阶段是否拿到了网络结果 */
  ok: boolean = false;
  /**
   * 本次并发阶段是否已经把结果（或错误）交给调用方缓存。
   * true 时串行阶段的 apply 必须消费这份缓存，**不准对同一面板再打一次请求**（429 风险）；
   * false 表示「未预取」（local:// 伪订阅 / 地址非法 / 订阅已删除），由 apply 走它原有的路径。
   */
  cached: boolean = false;
  /** 命中面板限流（HTTP 429/403）：调度器据此降速，且绝不重试 */
  rateLimited: boolean = false;
  /** 失败原因（可直接展示；不含 URL / 凭据） */
  message: string = '';

  /** 并发阶段成功拿到订阅内容（已放入调用方缓存） */
  static prefetched(id: string): RefreshPrepOutcome {
    const o = new RefreshPrepOutcome();
    o.id = id;
    o.ok = true;
    o.cached = true;
    return o;
  }

  /** 并发阶段失败（错误已放入调用方缓存，apply 会复用同一条错误，不再重试） */
  static failed(id: string, message: string, rateLimited: boolean): RefreshPrepOutcome {
    const o = new RefreshPrepOutcome();
    o.id = id;
    o.ok = false;
    o.cached = true;
    o.rateLimited = rateLimited;
    o.message = message;
    return o;
  }

  /** 未预取：apply 自行决定（local:// 伪订阅、地址非法、订阅已不存在） */
  static skipped(id: string): RefreshPrepOutcome {
    const o = new RefreshPrepOutcome();
    o.id = id;
    return o;
  }

  /** 并发阶段抛出了非预期异常（调度器兜底，未缓存任何东西） */
  static unexpected(id: string, message: string): RefreshPrepOutcome {
    const o = new RefreshPrepOutcome();
    o.id = id;
    o.message = message;
    return o;
  }
}

/** 单条订阅的最终结果（串行阶段 apply 的产出，也是进度与汇总的最小单元） */
export class RefreshItemOutcome {
  id: string = '';
  ok: boolean = false;
  rateLimited: boolean = false;
  nodeCount: number = 0;
  message: string = '';
  /**
   * 人话 + 下一步（来自 SubscriptionRefreshResult.advice）。
   * 批量汇总的 toast 优先展示它 —— message 里是原始错误码
   * （如 `code=2300060 Invalid SSL peer certificate…`），适合日志不适合给用户看。
   */
  advice: string = '';

  static success(id: string, nodeCount: number): RefreshItemOutcome {
    const o = new RefreshItemOutcome();
    o.id = id;
    o.ok = true;
    o.nodeCount = nodeCount;
    return o;
  }

  static failure(id: string, message: string, rateLimited: boolean, advice: string = ''): RefreshItemOutcome {
    const o = new RefreshItemOutcome();
    o.id = id;
    o.ok = false;
    o.message = message;
    o.rateLimited = rateLimited;
    o.advice = advice;
    return o;
  }
}

/** 进度快照（每次 apply 完成后回传一次；回调本身是串行的，顺序 = 完成顺序） */
export class RefreshBatchProgress {
  /** 本批总条数 */
  total: number = 0;
  /** 已开始并发拉取的条数（>= done） */
  launched: number = 0;
  /** 已完成（含失败）的条数 */
  done: number = 0;
  okCount: number = 0;
  failCount: number = 0;
  /** 已成功应用的节点累计数 */
  nodeCount: number = 0;
  /** 命中面板限流的条数 */
  rateLimitedCount: number = 0;
  /** 当前生效的并发上限（限流降速后会变小） */
  lanes: number = 1;
}

/** 批次汇总（页面用它拼最终一条消息） */
export class RefreshBatchSummary {
  total: number = 0;
  done: number = 0;
  okCount: number = 0;
  failCount: number = 0;
  nodeCount: number = 0;
  rateLimitedCount: number = 0;
  /** 结束时生效的并发上限（< 初始值说明中途被限流降速过） */
  lanes: number = 1;
  /** 是否被 shouldStop() 提前中止（未开始的条目不会被启动） */
  stopped: boolean = false;
  /** 逐条结果（页面按 id 映射订阅名后拼失败原因） */
  outcomes: RefreshItemOutcome[] = [];
  /** `id: 原因` 形式的原因摘要（便于日志/调试；界面展示用 outcomes + 订阅名） */
  failures: string[] = [];
}

export class ConcurrentRefresh {
  /** 默认并发路数（改这一处即可全局调速） */
  static DEFAULT_LANES: number = 4;
  /** 被限流后的最小并发（不再降到 0，也不串行阻塞整批） */
  static MIN_LANES: number = 1;

  /** 并发上限归一化：向下取整、非法值兜底为 MIN_LANES、不超过任务数 */
  static normalizeLanes(lanes: number, total: number): number {
    let value = Math.floor(lanes);
    if (!(value >= ConcurrentRefresh.MIN_LANES)) {
      value = ConcurrentRefresh.MIN_LANES;
    }
    if (total > 0 && value > total) {
      value = total;
    }
    if (value < ConcurrentRefresh.MIN_LANES) {
      value = ConcurrentRefresh.MIN_LANES;
    }
    return value;
  }

  /**
   * 统一异常文案（不输出 URL / 凭据，只输出错误消息）。
   * BusinessError 形态的普通对象（{code,message}）也要正确提取；本文件必须保持
   * 零 HarmonyOS SDK 依赖（Node 侧 type-stripping 直接加载），因此不走 AppLogger。
   */
  static describeError(e: Object): string {
    if (e === null || e === undefined) {
      return 'unknown error';
    }
    const biz = e as Record<string, Object>;
    const msgVal = biz.message;
    if (typeof msgVal === 'string' && (msgVal as string).length > 0) {
      return msgVal as string;
    }
    const text = String(e);
    return (text.length === 0 || text === '[object Object]') ? 'unknown error' : text;
  }

  /**
   * 跑一批刷新。所有回调都由调用方注入（便于离线验证与复用）：
   *   prepare(id)  并发执行（<= lanes 条同时进行）：只能做网络 I/O 与读盘，禁止改共享状态
   *   apply(id)    串行执行：解析 + 改内存 + 落盘（互斥由写入链保证）
   *   onProgress   每条 apply 完成后回调一次（串行、顺序确定；回调抛异常被隔离）
   *   shouldStop   返回 true 时不再启动新条目（在途条目仍会走完并落盘，不产生半截数据）
   */
  static async run(ids: string[], lanes: number,
    prepare: (id: string) => Promise<RefreshPrepOutcome>,
    apply: (id: string) => Promise<RefreshItemOutcome>,
    onProgress: (progress: RefreshBatchProgress, item: RefreshItemOutcome) => void,
    shouldStop: () => boolean): Promise<RefreshBatchSummary> {
    const batch = new ConcurrentRefreshBatch(ids, lanes, prepare, apply, onProgress, shouldStop);
    return await batch.run();
  }
}

/**
 * 单个批次的执行体。
 * 调度结构：一个「容量泵」+ 一定数量在途任务；每条任务自己完成 prepare 后，
 * 把自己的 apply 挂到唯一的写入链尾部（因此 apply 天然互斥且顺序确定）。
 */
class ConcurrentRefreshBatch {
  private readonly ids: string[];
  private readonly prepareFn: (id: string) => Promise<RefreshPrepOutcome>;
  private readonly applyFn: (id: string) => Promise<RefreshItemOutcome>;
  private readonly progressFn: (progress: RefreshBatchProgress, item: RefreshItemOutcome) => void;
  private readonly stopFn: () => boolean;
  private readonly summary: RefreshBatchSummary = new RefreshBatchSummary();
  private readonly progress: RefreshBatchProgress = new RefreshBatchProgress();
  /** 当前生效的并发上限（限流时减半） */
  private limit: number;
  /** 下一个待启动的下标：只在真正启动时前进 → 任何条目都不会被跳过 */
  private cursor: number = 0;
  /** 在途条数（含其串行 apply 阶段） */
  private running: number = 0;
  /** 是否已收尾（resolve 只会发生一次） */
  private settled: boolean = false;
  /** 串行写入链：所有 apply 依次挂在这条链上（永不 reject，避免一次异常断链丢数据） */
  private writeChain: Promise<void>;

  constructor(ids: string[], lanes: number,
    prepare: (id: string) => Promise<RefreshPrepOutcome>,
    apply: (id: string) => Promise<RefreshItemOutcome>,
    onProgress: (progress: RefreshBatchProgress, item: RefreshItemOutcome) => void,
    shouldStop: () => boolean) {
    this.ids = ids;
    this.limit = ConcurrentRefresh.normalizeLanes(lanes, ids.length);
    this.prepareFn = prepare;
    this.applyFn = apply;
    this.progressFn = onProgress;
    this.stopFn = shouldStop;
    this.summary.total = ids.length;
    this.summary.lanes = this.limit;
    this.progress.total = ids.length;
    this.progress.lanes = this.limit;
    this.writeChain = new Promise<void>((resolve: () => void) => resolve());
  }

  async run(): Promise<RefreshBatchSummary> {
    return await new Promise<RefreshBatchSummary>((resolve: (s: RefreshBatchSummary) => void) => {
      this.pump(resolve);
    });
  }

  /** 容量泵：只要还有余量（running < limit）且还有任务，就继续启动 */
  private pump(resolve: (s: RefreshBatchSummary) => void): void {
    if (this.settled) {
      return;
    }
    while (this.running < this.limit && this.cursor < this.ids.length && !this.stopFn()) {
      const id = this.ids[this.cursor];
      this.cursor = this.cursor + 1;
      this.running = this.running + 1;
      this.progress.launched = this.progress.launched + 1;
      this.runOne(id).then((): void => {
        this.running = this.running - 1;
        this.pump(resolve);
      }, (): void => {
        this.running = this.running - 1;
        this.pump(resolve);
      });
    }
    if (this.running === 0 && (this.cursor >= this.ids.length || this.stopFn())) {
      this.finish(resolve);
    }
  }

  private finish(resolve: (s: RefreshBatchSummary) => void): void {
    if (this.settled) {
      return;
    }
    this.settled = true;
    this.summary.stopped = this.cursor < this.ids.length;
    resolve(this.summary);
  }

  /** 单条：并发 prepare → 串行 apply（挂到写入链尾） */
  private async runOne(id: string): Promise<void> {
    let prep: RefreshPrepOutcome;
    try {
      prep = await this.prepareFn(id);
    } catch (e) {
      // 单条异常只影响这一条：不会打断其它条，也不会断写入链
      prep = RefreshPrepOutcome.unexpected(id, ConcurrentRefresh.describeError(e));
    }
    if (prep.rateLimited) {
      // 面板限流：剩余并发减半（不低于 MIN_LANES），在途请求不打断、不重试
      this.limit = Math.floor(this.limit / 2);
      if (this.limit < ConcurrentRefresh.MIN_LANES) {
        this.limit = ConcurrentRefresh.MIN_LANES;
      }
      this.progress.lanes = this.limit;
      this.summary.lanes = this.limit;
    }
    const mine: Promise<void> = this.writeChain.then(async (): Promise<void> => {
      let item: RefreshItemOutcome;
      try {
        item = await this.applyFn(id);
      } catch (e) {
        item = RefreshItemOutcome.failure(id, ConcurrentRefresh.describeError(e), false);
      }
      this.record(item);
    });
    // 链上任何异常都必须被吞掉：否则后续所有 apply 会被跳过（= 丢整批数据）
    const safe: Promise<void> = mine.then((): void => {
    }, (): void => {
    });
    this.writeChain = safe;
    await safe;
  }

  /** 累计结果并回传一次进度（进度回调是串行的；回调异常隔离，不影响批次） */
  private record(item: RefreshItemOutcome): void {
    this.summary.done = this.summary.done + 1;
    this.summary.outcomes.push(item);
    this.progress.done = this.progress.done + 1;
    if (item.ok) {
      this.summary.okCount = this.summary.okCount + 1;
      this.summary.nodeCount = this.summary.nodeCount + item.nodeCount;
      this.progress.okCount = this.progress.okCount + 1;
      this.progress.nodeCount = this.progress.nodeCount + item.nodeCount;
    } else {
      this.summary.failCount = this.summary.failCount + 1;
      this.progress.failCount = this.progress.failCount + 1;
      if (item.rateLimited) {
        this.summary.rateLimitedCount = this.summary.rateLimitedCount + 1;
        this.progress.rateLimitedCount = this.progress.rateLimitedCount + 1;
      }
      this.summary.failures.push(`${item.id}: ${item.message}`);
    }
    try {
      this.progressFn(this.progress, item);
    } catch (e) {
      // 页面回调抛异常（例如 UI 已被销毁）不允许影响批次收尾
    }
  }
}
