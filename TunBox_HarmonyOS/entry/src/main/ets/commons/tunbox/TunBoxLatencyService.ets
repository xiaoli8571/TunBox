/**
 * FlClash 等价测速服务（UI/后台的唯一测速入口）
 *
 * 职责：把 `TunBoxDelayRun`（32 并发、逐节点 `/proxies/{name}/delay`、-1/-2 语义）
 *       接到本仓库的展示层 `LatencyLiveView`，并提供与旧 `LatencyEngine` 同名的
 *       会话 API（isRunning / cancel / progress），让页面改动最小。
 *
 * 来源（FlClash）：
 *  - `lib/providers/actions/proxies.dart` `_runDelayTests` / `_runDelayTest`：
 *    逐节点 getDelay，`null`（没排到槽 / 取消 / 守护到期）不写结论；
 *    `CoreMethodException.isCoreUnavailable` ⇒ 整批取消。
 *  - `lib/providers/actions/proxies.dart` `setDelay` + `renderThrottleDuration(300ms)`：
 *    结果合批刷新 UI（本实现由 LatencyLiveView 内部 200ms 节流承担，语义等价）。
 *  - 组测速 = 组内所有节点**逐个测**（`delayTest(group.all)`），
 *    不是 `GET /group/{name}/delay`（规格 §4.2）。
 *
 * 明确没有（FlClash 也没有，规格 §4.4）：
 *  离线 TCP/TLS 探活、DNS 预解析判定、core_not_ready 连击作废、批次硬截止、
 *  5 分钟新鲜度跳过、后台静默自动测速。
 */
import { ClashApiService } from '../services/ClashApiService';
import { ConnectionOrchestrator } from '../services/ConnectionOrchestrator';
import { AppLogger } from '../utils/AppLogger';
import { LatencyContext, LatencyRecord, LatencyState, LatencyChannel } from '../services/LatencyState';
import { LatencyLiveView } from '../services/LatencyLiveView';
import { LatencyProbeKind, LatencyStrategy } from '../latency/LatencyKinds';
import {
  DelayResult, DelayTarget, TunBoxDelayRun, TunBoxDelaySummary,
  TUNBOX_DELAY_TIMED_OUT, TUNBOX_DELAY_FAILED, TUNBOX_DELAY_URL
} from '../tunbox/TunBoxDelay';

const TAG = 'TunBoxLatencyService';

/** 进度快照（UI 只读这几个数，字段语义与 FlClash summary 一致）。 */
export class TunBoxLatencyProgress {
  total: number = 0;
  started: number = 0;
  measured: number = 0;
  timeout: number = 0;
  failed: number = 0;
  cancelled: number = 0;
  wasCancelled: boolean = false;
  running: boolean = false;

  done(): boolean {
    return !this.running;
  }
}

export class TunBoxLatencySession {
  private readonly run: TunBoxDelayRun;
  private readonly progress: TunBoxLatencyProgress = new TunBoxLatencyProgress();
  private readonly source: string;
  private finished: boolean = false;
  private readonly targets: DelayTarget[];
  private readonly runId: number;
  private readonly previous: Map<string, LatencyRecord>;
  /** Explicit cancellation and a missing controller response both produce no node verdict. */
  private explicitCancel: boolean = false;
  private readonly contexts: Map<string, LatencyContext>;
  private readonly current: () => boolean;

  private clearOwnTesting(): void {
    for (const target of this.targets) {
      const context = this.contexts.get(target.key) ?? null;
      if (!LatencyLiveView.isTestingOwnedBy(target.proxyName, this.runId, context)) { continue; }
      const old = this.previous.get(target.key);
      if (old !== undefined) {
        LatencyLiveView.setRecord(old);
      } else {
        // Missing controller response is not evidence of a node timeout.
        const rec = LatencyRecord.untested(target.proxyName);
        rec.context = context;
        rec.failKind = this.explicitCancel ? LatencyProbeKind.CANCELLED : LatencyProbeKind.CORE_NOT_READY;
        LatencyLiveView.setRecord(rec);
      }
    }
    LatencyLiveView.flushNow();
  }
  /** 完成信号（供调用方 await；取消同样会兑现，避免永远挂住）。 */
  private resolveDone: (progress: TunBoxLatencyProgress) => void = (): void => {};
  private readonly donePromise: Promise<TunBoxLatencyProgress>;

  constructor(api: ClashApiService, targets: DelayTarget[], source: string,
    runId: number, previous: Map<string, LatencyRecord>,
    contexts: Map<string, LatencyContext> = new Map<string, LatencyContext>(),
    current: () => boolean = (): boolean => true) {
    this.contexts = contexts;
    this.current = current;
    this.targets = targets;
    this.runId = runId;
    this.previous = previous;
    this.source = source;
    this.run = new TunBoxDelayRun(api.endpointBase(), api.endpointSecret());
    this.donePromise = new Promise<TunBoxLatencyProgress>((resolve) => {
      this.resolveDone = resolve;
    });
    this.progress.total = targets.length;
    this.progress.running = true;
    this.run.start(targets,
      (result: DelayResult): void => {
        this.apply(result);
      },
      (summary: TunBoxDelaySummary): void => {
        this.complete(summary);
      });
  }

  private async complete(summary: TunBoxDelaySummary): Promise<void> {
    if (this.finished) { return; }
    // Upstream null/guard/cancel paths do not publish a node result. A healthy
    // controller proves nothing about a missing URLTest reply; retain old data.
    this.progress.started = summary.started;
    this.progress.measured = summary.measured;
    this.progress.timeout = summary.timedOut;
    this.progress.failed = summary.failed;
    this.progress.cancelled = summary.cancelled;
    this.progress.wasCancelled = summary.wasCancelled;
    this.progress.running = false;
    this.finished = true;
    this.clearOwnTesting();
    this.resolveDone(this.progress);
    AppLogger.info(TAG, `delay batch done: total=${summary.total} measured=${summary.measured} `
      + `timeout=${summary.timedOut} failed=${summary.failed} cancelled=${summary.cancelled} `
      + `wall=${summary.wallMs}ms conc=${summary.concurrency} peak=${summary.peakInflight}`);
  }

  private apply(result: DelayResult): void {
    if (this.finished || !this.current()) { return; }
    const context = this.contexts.get(result.key) ?? null;
    if (!LatencyLiveView.isTestingOwnedBy(result.proxyName, this.runId, context)) { return; }
    const now = Date.now();
    // 【2026-10-22 真机 bug 修复】失败分类必须是 `LatencyProbeKind` 里的**真分类**：
    // 旧实现写的是字面量 `'failed'`，而 `LatencyStore.describe()` 只认表内分类
    // （timeout / network_unreachable / switch_failed / …），认不出就走 `else → '--'`。
    // 真机表现就是「20 个节点测完，13 个失败的全部显示 --，不是超时/拨号失败」。
    if (!LatencyStrategy.isValidDelay(result.value)) {
      // 404 = 内核里没有这个名字；其它 = 拨了没通。用户报障排查需要名字+码。
      AppLogger.warn(TAG, `delay failed: ${result.proxyName} http=${result.httpCode} value=${result.value}`);
    }
    let failKind: string = LatencyProbeKind.TIMEOUT;
    if (result.value !== TUNBOX_DELAY_TIMED_OUT) {
      // 404 = 内核里没有这个节点（名字对不上/没进配置）→「未生效」，不是节点坏；
      // 503/400/200-但-delay<=0 = 内核拨过但没拨通 →「拨号失败」。
      failKind = result.httpCode === 404
        ? LatencyProbeKind.SWITCH_FAILED : LatencyProbeKind.NETWORK_UNREACHABLE;
    }
    // 延迟值合法性必须与旧引擎同口径（LatencyStrategy.isValidDelay，1..32766）：
    // 内核偶发回 65535/-1 之类的哨兵值，不套校验会把它们当真实延迟落盘并参与排序。
    const valid = LatencyStrategy.isValidDelay(result.value);
    const rec: LatencyRecord = valid
      ? LatencyRecord.measured(result.proxyName, result.value, LatencyChannel.CORE, now)
      : LatencyRecord.failed(result.proxyName,
        result.value === TUNBOX_DELAY_TIMED_OUT ? LatencyState.TIMEOUT : LatencyState.FAILED,
        now, LatencyChannel.CORE, failKind);
    rec.source = this.source;
    rec.context = context;
    rec.runId = this.runId;
    LatencyLiveView.setRecord(rec);
    this.progress.started = this.progress.started + 1;
    if (valid) {
      this.progress.measured = this.progress.measured + 1;
    } else if (result.value === TUNBOX_DELAY_TIMED_OUT) {
      this.progress.timeout = this.progress.timeout + 1;
    } else {
      this.progress.failed = this.progress.failed + 1;
    }
  }

  isRunning(): boolean {
    return !this.finished && this.run.isRunning();
  }

  currentProgress(): TunBoxLatencyProgress {
    return this.progress;
  }

  /** 等本批结束（正常完成或取消都会兑现）。 */
  wait(): Promise<TunBoxLatencyProgress> {
    return this.donePromise;
  }

  /** 取消：在途 abort、未开始跳过，一条结论都不写。 */
  cancel(): void {
    if (this.finished) {
      return;
    }
    // 显式取消：收尾时未测完的节点不得盖章（新批马上会重测同一批节点）
    this.explicitCancel = true;
    this.progress.wasCancelled = true;
    this.run.cancel();
    this.clearOwnTesting();
    this.progress.cancelled = Math.max(0, this.progress.total - this.progress.measured
      - this.progress.timeout - this.progress.failed);
    this.progress.running = false;
    this.finished = true;
    this.resolveDone(this.progress);
    AppLogger.info(TAG, `delay batch cancelled: ${this.progress.started}/${this.progress.total} started`);
  }
}

export class TunBoxLatencyService {
  private static current: TunBoxLatencySession | null = null;

  /**
   * 启动一批测速（新批会取消旧批，与 FlClash「一个 job 一个 cancel 标记」一致）。
   *
   * @param nodeNames 待测节点名（内核 `/proxies` 里的名字，**不是**本地节点表的名字）
   * @param testUrl   全局测速 URL（默认 gstatic 204）
   * @param perNodeUrl 可选：按节点给测速 URL（FlClash 组内 `url` 优先）
   */
  static start(api: ClashApiService, nodeNames: string[], testUrl: string,
    source: string = 'manual',
    perNodeUrl: Map<string, string> | null = null,
    expected: string = '', context: LatencyContext | null = null,
    current: () => boolean = (): boolean => true): TunBoxLatencySession {
    const effectiveUrl = testUrl.length > 0 ? testUrl : TUNBOX_DELAY_URL;
    const targets: DelayTarget[] = [];
    for (const name of nodeNames) {
      const url = perNodeUrl !== null ? perNodeUrl.get(name) ?? effectiveUrl : effectiveUrl;
      targets.push(new DelayTarget(name, url || effectiveUrl, '', expected, api.providerForProxy(name)));
    }
    return TunBoxLatencyService.startTargets(api, targets, source, context, current);
  }

  /** Explicit per-target policy; deduplication and ownership use the full identity. */
  static startTargets(api: ClashApiService, requested: DelayTarget[], source: string = 'manual',
    context: LatencyContext | null = null,
    current: () => boolean = (): boolean => true): TunBoxLatencySession {
    if (TunBoxLatencyService.current !== null) { TunBoxLatencyService.current.cancel(); }
    const targets: DelayTarget[] = [];
    const previous: Map<string, LatencyRecord> = new Map<string, LatencyRecord>();
    const contexts: Map<string, LatencyContext> = new Map<string, LatencyContext>();
    const seen: Set<string> = new Set<string>();
    const runId = LatencyLiveView.nextRunId();
    for (const target of requested) {
      if (target.proxyName.length === 0) { continue; }
      const scoped = context === null ? null
        : new LatencyContext(context.profileId, context.revision, target.testUrl, target.expected);
      target.key = scoped === null ? JSON.stringify([target.testUrl, target.expected, target.proxyName])
        : scoped.key(target.proxyName);
      if (seen.has(target.key)) { continue; }
      seen.add(target.key);
      if (scoped !== null) { contexts.set(target.key, scoped); }
      targets.push(target);
      const old = LatencyLiveView.recordFor(target.proxyName, scoped);
      if (old !== null && old.state !== LatencyState.TESTING) { previous.set(target.key, old); }
      LatencyLiveView.markTesting(target.proxyName, runId, scoped);
    }
    const session = new TunBoxLatencySession(api, targets, source, runId, previous, contexts, current);
    TunBoxLatencyService.current = session;
    AppLogger.info(TAG, `delay batch start: targets=${targets.length} source=${source}`);
    return session;
  }

  static cancelCurrent(): void {
    if (TunBoxLatencyService.current !== null) {
      TunBoxLatencyService.current.cancel();
      TunBoxLatencyService.current = null;
    }
  }

  static isRunning(): boolean {
    return TunBoxLatencyService.current !== null && TunBoxLatencyService.current.isRunning();
  }

  static currentProgress(): TunBoxLatencyProgress | null {
    return TunBoxLatencyService.current === null ? null : TunBoxLatencyService.current.currentProgress();
  }

  /**
   * 组测速（FlClash `delayTestPageGroup`）：组内所有节点逐个测。
   * 返回被取消/未开始的节点数由 session 自己的 summary 负责。
   */
  static startGroup(api: ClashApiService, groupNodeNames: string[], testUrl: string,
    source: string = 'manual', expected: string = ''): TunBoxLatencySession {
    return TunBoxLatencyService.start(api, groupNodeNames, testUrl, source, null, expected);
  }
}

// 回收探针注册：组测速/订阅测速批进行中阻止编排器回收无头内核（顺延而非杀核）。
// 注册在类外静态初始化，import 本模块即生效；重复注册由 includes 去重。
const recycleProbe = (): boolean => TunBoxLatencyService.isRunning();
if (!ConnectionOrchestrator.testCoreBusyProbes.includes(recycleProbe)) {
  ConnectionOrchestrator.testCoreBusyProbes.push(recycleProbe);
}
