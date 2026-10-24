/**
 * FlClash 等价节点测速引擎（ArkTS 复刻）
 *
 * 职责：以固定 32 个 worker 的并发池，逐节点打内核 REST 测速接口
 *       `GET /proxies/{name}/delay?url=…&timeout=…`，产出与 FlClash 同口径的
 *       >0 / -1 / -2 结论，并把每个结论即时回调给调用方。
 *
 * 来源（逐条对齐，偏离即 bug）：
 *   FlClash  lib/providers/actions/proxies.dart  _runDelayTests / _runDelayTest / cancelDelayTests
 *            （TaskPool(maxConcurrentDelayTests) 逐节点 getDelay；getDelay 返回 null ⇒ 不写结论；
 *              job.cancelled 后既不启动新任务也不落结论）
 *   FlClash  lib/common/constant.dart            maxConcurrentDelayTests = 32
 *                                                delayTestGuardDuration = 30s
 *                                                renderThrottleDuration = 300ms（合批由 UI 侧做，本文件不掺和）
 *   FlClash  lib/core/interface.dart             asyncTestDelay(timeout: delayTestGuardDuration)
 *   mihomo   hub/route/proxies.go getProxyDelay  200 {"delay":n} / 504 ctx 超时 / 503 失败 / 404 proxy 不存在
 *   mihomo   core/delay.go                       delayTimedOut = -1、delayFailed = -2
 *   mihomo   core/delay.go defaultTestURL        https://www.gstatic.com/generate_204
 *
 * 关键口径：
 *   1. 结果三态：>0 延迟、-1 超时（内核 ctx 超时，REST 表现为 504）、-2 失败（503 / 404 / 其它非 200）。
 *   2. **只有真正拿到 HTTP 响应才写结论**。拿不到响应（30s 守护到期、被取消、socket 异常）
 *      ＝ 不作结论，不回调；这批任务只体现在 summary.cancelled。
 *   3. 并发池固定 32 个 worker，FIFO 取任务；「排队等待」不计入 30s 守护
 *      —— 守护从请求**真正发出**那一刻才开始计时（FlClash 的 guard 包的是单次 IPC）。
 *   4. 取消：在途请求全部 abort、未开始的任务直接跳过，两者都不写结论。
 *   5. 明确不实现（FlClash 也没有，规格 §4.4）：离线 TCP/TLS 探活、DNS 预解析判定、
 *      core_not_ready 连击作废、批次硬截止、5 分钟新鲜度跳过、/group/{name}/delay 组测速。
 *
 * 平台差异（规格 §五，不算偏离）：FlClash 走 core IPC，TunBox 走内核 REST；
 * 内核 `delayTestConcurrency = 50 > 32`，客户端 32 并发天然落在核内槽位之内。
 *
 * 测试：scripts/verify-flclash-delay.mjs（网络层通过 DelayHttpTransport 注入桩，
 *       默认实现 ArkDelayHttpTransport 用 @kit.NetworkKit）。
 */
import { http } from '@kit.NetworkKit';
import { LatencyTestUrl } from '../latency/LatencyTestUrl';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'FlclashDelay';

/** 并发池大小（FlClash maxConcurrentDelayTests） */
export const FLCLASH_DELAY_CONCURRENCY: number = 32;
/** 传给**内核**的单节点测速超时（mihomo defaultDelayTestTimeout / ?timeout= 参数） */
export const FLCLASH_DELAY_TIMEOUT_MS: number = 5000;
/** 客户端守护：一次 REST 往返最多等这么久，超时＝不作结论（FlClash delayTestGuardDuration） */
export const FLCLASH_DELAY_GUARD_MS: number = 30000;
/** 默认测速 URL（mihomo defaultTestURL，调用方可按节点/组覆盖） */
// 测速地址的真源在 commons/latency/LatencyTestUrl（ND06：默认地址常量只允许一处）。
// 这里只是给 FlClash 复刻层一个本地命名，**不得**再写第二份字面量。
export const FLCLASH_DELAY_URL: string = LatencyTestUrl.DEFAULT_URL;

/** delayTimedOut：内核对 context 超时的取值 */
export const FLCLASH_DELAY_TIMED_OUT: number = -1;
/** delayFailed：内核拨号/请求失败的取值 */
export const FLCLASH_DELAY_FAILED: number = -2;

/** delayTestKey 的分隔符（FlClash common/compute.dart：'$testUrl\u0000$proxyName'） */
const DELAY_KEY_SEP: string = '\u0000';

/**
 * 去重键（FlClash delayTestKey）：同一个节点配不同测速 URL 是**两个**任务。
 */
export function delayTestKey(testUrl: string, proxyName: string): string {
  return `${testUrl}${DELAY_KEY_SEP}${proxyName}`;
}

/** 单个测速目标（FlClash _DelayTestTarget 的等价物） */
export class DelayTarget {
  /** 真正被内核拨测的出口名（组链路末端节点名，由调用方解析） */
  proxyName: string = '';
  /** 该节点/该组配置的测速 URL */
  testUrl: string = FLCLASH_DELAY_URL;
  /** 去重键 = delayTestKey(testUrl, proxyName) */
  key: string = '';

  constructor(proxyName: string = '', testUrl: string = FLCLASH_DELAY_URL, key: string = '') {
    this.proxyName = proxyName;
    this.testUrl = testUrl.length > 0 ? testUrl : FLCLASH_DELAY_URL;
    this.key = key.length > 0 ? key : delayTestKey(this.testUrl, proxyName);
  }
}

/** 一条测速结论（仅在三态之一成立时才产生） */
export class DelayResult {
  /** 被测出口名 */
  proxyName: string = '';
  /** 本次使用的测速 URL */
  testUrl: string = '';
  /** >0 延迟 ms；-1 超时；-2 失败 */
  value: number = FLCLASH_DELAY_FAILED;
  /** 内核返回的 HTTP 状态码（200 / 503 / 504 / 404 …） */
  httpCode: number = 0;
  /** 客户端侧观测到的往返耗时（从请求发出到响应抵达，ms） */
  elapsedMs: number = 0;
}

/** 一批测速的汇总（total = measured + timedOut + failed + cancelled） */
export class FlclashDelaySummary {
  /** 本批目标总数 */
  total: number = 0;
  /** 真正发出过请求的任务数（含被取消/守护到期而没结论的） */
  started: number = 0;
  /** 拿到 >0 结论的任务数 */
  measured: number = 0;
  /** 拿到 -1 的任务数 */
  timedOut: number = 0;
  /** 拿到 -2 的任务数 */
  failed: number = 0;
  /** 未产出结论的任务数：取消时在途被 abort、取消后未开始、30s 守护到期、传输层异常 */
  cancelled: number = 0;
  /**
   * 内核不可用判定。REST 通道无法把「内核没起来」与「单个节点失败」区分开
   * （404 是 proxy 不存在，503 是拨测失败，都不是内核不可用），
   * 规格 §4.4 又明确要求去掉 core_not_ready 连击作废 ⇒ 恒为 false，仅为契约占位。
   */
  coreUnavailable: boolean = false;
}

/** 结果回调：每拿到一条真结论调用一次 */
export type DelayResultSink = (result: DelayResult) => void;
/** 批次结束回调：只调用一次（含取消后的收尾） */
export type DelayDoneSink = (summary: FlclashDelaySummary) => void;

/** 一次 HTTP 往返的回复 */
export class DelayHttpReply {
  /** HTTP 状态码（0 表示没拿到响应） */
  responseCode: number = 0;
  /** 响应体原文 */
  body: string = '';

  constructor(responseCode: number = 0, body: string = '') {
    this.responseCode = responseCode;
    this.body = body;
  }
}

/**
 * 一次在途请求的句柄：promise 拿回复，abort() 立刻掐断。
 * 取消语义要求「在途全部 abort ⇒ 不写结论」，因此 abort 必须是一等公民。
 */
export class DelayRequestHandle {
  promise: Promise<DelayHttpReply>;
  abort: () => void;

  constructor(promise: Promise<DelayHttpReply>, abort: () => void) {
    this.promise = promise;
    this.abort = abort;
  }
}

/**
 * 可注入的传输层（生产实现 = ArkDelayHttpTransport；验证脚本注入桩）。
 * 约定：**只有真正拿到 HTTP 响应才 resolve**（非 2xx 也是 resolve，交给上层分类）；
 *       网络错误 / 被 abort ⇒ reject。
 */
export interface DelayHttpTransport {
  send(url: string, headers: Record<string, string>, timeoutMs: number): DelayRequestHandle;
}

/** 生产传输层：@kit.NetworkKit 单发 GET，不重试 */
export class ArkDelayHttpTransport implements DelayHttpTransport {
  send(url: string, headers: Record<string, string>, timeoutMs: number): DelayRequestHandle {
    const req = http.createHttp();
    let destroyed: boolean = false;
    const abort = (): void => {
      if (destroyed) {
        return;
      }
      destroyed = true;
      try {
        req.destroy();
      } catch (e) {
        // destroy 失败无需上报：请求已经被取消，结论本来就不写
      }
    };
    const promise: Promise<DelayHttpReply> = req.request(url, {
      method: http.RequestMethod.GET,
      header: headers,
      connectTimeout: timeoutMs,
      readTimeout: timeoutMs,
      usingCache: false
    }).then((resp: http.HttpResponse): DelayHttpReply => {
      // 状态码原样交给 classifyDelayReply；响应体只处理字符串形态（mihomo 返回 JSON 文本）
      const raw = resp.result;
      const body: string = typeof raw === 'string' ? raw as string : '';
      return new DelayHttpReply(resp.responseCode, body);
    }).finally((): void => {
      // settle（成功或失败）后必须释放原生 http 句柄：不 destroy 的话每个请求泄一个，
      // 600 节点一批就漏 600 个，反复测速直接耗尽网络栈资源。abort 自带 destroyed 防重入。
      abort();
    });
    return new DelayRequestHandle(promise, abort);
  }
}

/** 单批运行的策略（默认值 = FlClash 常量；缩小时仅供验证脚本压缩时间） */
export class FlclashDelayPolicy {
  concurrency: number = FLCLASH_DELAY_CONCURRENCY;
  timeoutMs: number = FLCLASH_DELAY_TIMEOUT_MS;
  guardMs: number = FLCLASH_DELAY_GUARD_MS;

  constructor(concurrency: number = FLCLASH_DELAY_CONCURRENCY,
    timeoutMs: number = FLCLASH_DELAY_TIMEOUT_MS,
    guardMs: number = FLCLASH_DELAY_GUARD_MS) {
    this.concurrency = concurrency > 0 ? concurrency : FLCLASH_DELAY_CONCURRENCY;
    this.timeoutMs = timeoutMs > 0 ? timeoutMs : FLCLASH_DELAY_TIMEOUT_MS;
    this.guardMs = guardMs > 0 ? guardMs : FLCLASH_DELAY_GUARD_MS;
  }
}

/** 单批运行的可变状态（只活在一次 start…onDone 之间，类字段不跨批共享） */
class DelayRunState {
  /** 用户取消标记：置位后不再启动新任务，也不落任何结论 */
  cancelled: boolean = false;
  /** FIFO 游标 */
  nextIndex: number = 0;
  started: number = 0;
  measured: number = 0;
  timedOut: number = 0;
  failed: number = 0;
  cancelledCount: number = 0;
  /** key → 在途句柄（cancel 时逐个 abort） */
  inflight: Map<string, DelayRequestHandle> = new Map<string, DelayRequestHandle>();
  /** key → 强制收尾（保证 abort 后立刻解开 worker，不依赖 promise 必然 reject） */
  pending: Map<string, () => void> = new Map<string, () => void>();
}

/**
 * 一批测速的运行体。语义等价于 FlClash 的 `_runDelayTests`：
 * TaskPool(32) + 逐节点 getDelay + guard 30s + cancel 只清状态不写结论。
 */
export class FlclashDelayRun {
  private baseUrl: string;
  private secret: string;
  private transport: DelayHttpTransport;
  private policy: FlclashDelayPolicy;
  private running: boolean = false;
  private state: DelayRunState | undefined = undefined;

  /**
   * @param baseUrl 内核 REST 基址（如 http://127.0.0.1:9090）
   * @param secret  控制面密钥（空串 = 不带 Authorization 头）
   * @param transport 传输层，默认 @kit.NetworkKit 实现
   * @param policy  并发/超时/守护，默认 FlClash 常量
   */
  constructor(baseUrl: string, secret: string,
    transport: DelayHttpTransport = new ArkDelayHttpTransport(),
    policy: FlclashDelayPolicy = new FlclashDelayPolicy()) {
    this.baseUrl = baseUrl;
    this.secret = secret;
    this.transport = transport;
    this.policy = policy;
  }

  /**
   * 发起一批测速。同一实例同时只跑一批：已在跑则忽略并告警
   * （FlClash 一个 job 一个 cancel 标记，同样不允许叠批）。
   *
   * 去重由调用方完成（FlClash 在 _resolveDelayTestTargets 里按 delayTestKey 去重），
   * 本引擎按传入顺序 FIFO 派发，不再自作主张合并。
   */
  start(targets: DelayTarget[], onResult: DelayResultSink, onDone: DelayDoneSink): void {
    if (this.running) {
      AppLogger.warn(TAG, 'start ignored: a batch is already running');
      return;
    }
    const state = new DelayRunState();
    this.state = state;
    this.running = true;
    const queue: DelayTarget[] = targets.slice();
    this.drive(queue, onResult, onDone);
  }

  /** 取消：在途 abort、未开始跳过，绝不写结论；onDone 仍会以 cancelled 计数收尾 */
  cancel(): void {
    const state = this.state;
    if (state === undefined || state.cancelled) {
      return;
    }
    state.cancelled = true;
    let aborted: number = 0;
    // 先 abort 再强制收尾：abort 让内核/协议栈立刻停下，收尾让 worker 立刻退出
    state.inflight.forEach((handle: DelayRequestHandle, key: string) => {
      try {
        handle.abort();
        aborted += 1;
      } catch (e) {
        AppLogger.warn(TAG, `cancel abort failed for ${key}: ${AppLogger.errText(e)}`);
      }
    });
    const finishes: (() => void)[] = [];
    state.pending.forEach((finish: () => void) => {
      finishes.push(finish);
    });
    for (const finish of finishes) {
      finish();
    }
    AppLogger.info(TAG, `cancelled: abortedInflight=${aborted} queued=${this.queuedCount()}`);
  }

  /** 是否有一批在跑（含正在收尾的） */
  isRunning(): boolean {
    return this.running;
  }

  // ── 内部 ────────────────────────────────────────────────────────────────

  private queuedCount(): number {
    return this.state === undefined ? 0 : this.state.nextIndex;
  }

  private async drive(queue: DelayTarget[], onResult: DelayResultSink,
    onDone: DelayDoneSink): Promise<void> {
    const state = this.state;
    if (state === undefined) {
      return;
    }
    // 让 start() 先返回，回调永不在调用栈里重入（含 0 目标的分支）
    await Promise.resolve();
    try {
      const workers: Promise<void>[] = [];
      const width: number = Math.min(this.policy.concurrency, queue.length);
      for (let i = 0; i < width; i++) {
        workers.push(this.worker(queue, state, onResult));
      }
      await Promise.all(workers);
      // 取消后未取到的任务＝直接跳过，同样不作结论
      const undispatched: number = queue.length - state.started;
      if (undispatched > 0) {
        state.cancelledCount += undispatched;
      }
    } catch (e) {
      AppLogger.error(TAG, `batch failed: ${AppLogger.errText(e)}`);
      state.cancelledCount += queue.length - state.started;
    } finally {
      const summary = this.buildSummary(state, queue.length);
      this.state = undefined;
      this.running = false;
      try {
        onDone(summary);
      } catch (e) {
        AppLogger.error(TAG, `onDone threw: ${AppLogger.errText(e)}`);
      }
    }
  }

  /** 固定 worker：FIFO 领任务，直到队尾或取消 */
  private async worker(queue: DelayTarget[], state: DelayRunState,
    onResult: DelayResultSink): Promise<void> {
    while (true) {
      if (state.cancelled) {
        return;
      }
      const index: number = state.nextIndex;
      if (index >= queue.length) {
        return;
      }
      state.nextIndex = index + 1;
      await this.runOne(queue[index], state, onResult);
    }
  }

  /**
   * 单任务：发请求 → 起 30s 守护 → 等响应。
   * 守护计时起点是「请求真正发出」（排队时间不计入）。
   */
  private runOne(target: DelayTarget, state: DelayRunState,
    onResult: DelayResultSink): Promise<void> {
    if (state.cancelled) {
      return Promise.resolve();
    }
    const url: string = this.delayUrl(target.proxyName, target.testUrl);
    let handle: DelayRequestHandle;
    try {
      // 传输层自带的超时与守护同值：谁先到都等价于「不作结论」
      handle = this.transport.send(url, this.authHeaders(), this.policy.guardMs);
    } catch (e) {
      // 同步抛错 = 连请求都没发出去，同样不写结论
      AppLogger.warn(TAG, `send failed for ${target.proxyName}: ${AppLogger.errText(e)}`);
      state.cancelledCount += 1;
      return Promise.resolve();
    }
    state.started += 1;
    const startedAt: number = Date.now();
    state.inflight.set(target.key, handle);
    return new Promise<void>((resolve: () => void) => {
      let settled: boolean = false;
      let timer: number = -1;
      const finish = (result: DelayResult | null): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer >= 0) {
          clearTimeout(timer);
          timer = -1;
        }
        state.inflight.delete(target.key);
        state.pending.delete(target.key);
        if (result !== null && !state.cancelled) {
          if (result.value > 0) {
            state.measured += 1;
          } else if (result.value === FLCLASH_DELAY_TIMED_OUT) {
            state.timedOut += 1;
          } else {
            state.failed += 1;
          }
          try {
            onResult(result);
          } catch (e) {
            AppLogger.error(TAG, `onResult threw for ${target.proxyName}: ${AppLogger.errText(e)}`);
          }
        } else {
          // 取消 / 守护到期 / 传输异常：不作结论（FlClash 的 null 分支）
          state.cancelledCount += 1;
        }
        resolve();
      };
      state.pending.set(target.key, (): void => {
        finish(null);
      });
      timer = setTimeout((): void => {
        AppLogger.warn(TAG, `guard expired for ${target.proxyName} after ${this.policy.guardMs}ms`);
        try {
          handle.abort();
        } catch (e) {
          // 忽略：结论本来就不写
        }
        finish(null);
      }, this.policy.guardMs);
      handle.promise.then((reply: DelayHttpReply): void => {
        finish(FlclashDelayRun.classify(target, reply, Date.now() - startedAt));
      }).catch((e: Object): void => {
        AppLogger.warn(TAG, `request error for ${target.proxyName}: ${AppLogger.errText(e)}`);
        finish(null);
      });
    });
  }

  /**
   * 响应 → 结论（严格按 mihomo getProxyDelay 的分支）：
   *   200 + delay > 0  → 延迟
   *   504              → -1（ctx.Err() != nil，即内核侧 ctx 超时）
   *   其它非 200（503/404/400/…）→ -2
   *   200 但 delay 缺失/<=0 → -2（内核 delay == 0 本身就是错误分支）
   *   没拿到响应（code <= 0）→ null，不写结论
   */
  static classify(target: DelayTarget, reply: DelayHttpReply, elapsedMs: number): DelayResult | null {
    if (reply.responseCode <= 0) {
      return null;
    }
    const result = new DelayResult();
    result.proxyName = target.proxyName;
    result.testUrl = target.testUrl;
    result.httpCode = reply.responseCode;
    result.elapsedMs = elapsedMs;
    if (reply.responseCode === 200) {
      const delay: number = FlclashDelayRun.parseDelay(reply.body);
      result.value = delay > 0 ? delay : FLCLASH_DELAY_FAILED;
    } else if (reply.responseCode === 504) {
      result.value = FLCLASH_DELAY_TIMED_OUT;
    } else {
      result.value = FLCLASH_DELAY_FAILED;
    }
    return result;
  }

  /** 从 `{"delay":123}` 里取 delay；异常/缺失一律 0 */
  static parseDelay(body: string): number {
    if (body.length === 0) {
      return 0;
    }
    try {
      const parsed = JSON.parse(body) as Record<string, Object>;
      const raw = parsed['delay'];
      if (typeof raw === 'number') {
        return raw as number;
      }
      return 0;
    } catch (e) {
      return 0;
    }
  }

  private delayUrl(proxyName: string, testUrl: string): string {
    let base: string = this.baseUrl;
    while (base.length > 0 && base.charAt(base.length - 1) === '/') {
      base = base.substring(0, base.length - 1);
    }
    const name: string = encodeURIComponent(proxyName);
    const url: string = encodeURIComponent(testUrl);
    return `${base}/proxies/${name}/delay?url=${url}&timeout=${this.policy.timeoutMs}`;
  }

  private authHeaders(): Record<string, string> {
    const headers: Record<string, string> = {};
    headers['Accept'] = 'application/json';
    if (this.secret.length > 0) {
      headers['Authorization'] = `Bearer ${this.secret}`;
    }
    return headers;
  }

  private buildSummary(state: DelayRunState, total: number): FlclashDelaySummary {
    const summary = new FlclashDelaySummary();
    summary.total = total;
    summary.started = state.started;
    summary.measured = state.measured;
    summary.timedOut = state.timedOut;
    summary.failed = state.failed;
    summary.cancelled = state.cancelledCount;
    return summary;
  }
}
