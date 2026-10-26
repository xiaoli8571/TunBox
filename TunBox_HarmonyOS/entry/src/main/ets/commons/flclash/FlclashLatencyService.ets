/**
 * FlClash 等价测速服务（UI/后台的唯一测速入口）
 *
 * 职责：把 `FlclashDelayRun`（32 并发、逐节点 `/proxies/{name}/delay`、-1/-2 语义）
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
import { LatencyRecord, LatencyState, LatencyChannel } from '../services/LatencyState';
import { LatencyLiveView } from '../services/LatencyLiveView';
import { LatencyProbeKind, LatencyStrategy } from '../latency/LatencyKinds';
import {
  DelayResult, DelayTarget, FlclashDelayRun, FlclashDelaySummary,
  FLCLASH_DELAY_TIMED_OUT, FLCLASH_DELAY_FAILED, FLCLASH_DELAY_URL, delayTestKey
} from '../flclash/FlclashDelay';

const TAG = 'FlclashLatencyService';

/** 进度快照（UI 只读这几个数，字段语义与 FlClash summary 一致）。 */
export class FlclashLatencyProgress {
  total: number = 0;
  started: number = 0;
  measured: number = 0;
  timeout: number = 0;
  failed: number = 0;
  cancelled: number = 0;
  running: boolean = false;

  done(): boolean {
    return !this.running;
  }
}

export class FlclashLatencySession {
  private readonly api: ClashApiService;
  private readonly run: FlclashDelayRun;
  private readonly progress: FlclashLatencyProgress = new FlclashLatencyProgress();
  private readonly source: string;
  private finished: boolean = false;
  private readonly targets: DelayTarget[];
  private readonly runId: number;
  private readonly previous: Map<string, LatencyRecord>;

  private clearOwnTesting(): void {
    for (const target of this.targets) {
      if (LatencyLiveView.isTestingOwnedBy(target.proxyName, this.runId)) {
        const old = this.previous.get(target.proxyName);
        LatencyLiveView.setRecord(old !== undefined ? old : LatencyRecord.untested(target.proxyName));
      }
    }
    LatencyLiveView.flushNow();
  }
  /** 完成信号（供调用方 await；取消同样会兑现，避免永远挂住）。 */
  private resolveDone: (progress: FlclashLatencyProgress) => void = (): void => {};
  private readonly donePromise: Promise<FlclashLatencyProgress>;

  constructor(api: ClashApiService, targets: DelayTarget[], source: string,
    runId: number, previous: Map<string, LatencyRecord>) {
    this.api = api;
    this.targets = targets;
    this.runId = runId;
    this.previous = previous;
    this.source = source;
    this.run = new FlclashDelayRun(api.endpointBase(), api.endpointSecret());
    this.donePromise = new Promise<FlclashLatencyProgress>((resolve) => {
      this.resolveDone = resolve;
    });
    this.progress.total = targets.length;
    this.progress.running = true;
    this.run.start(targets,
      (result: DelayResult): void => {
        this.apply(result);
      },
      (summary: FlclashDelaySummary): void => {
        this.progress.started = summary.started;
        this.progress.measured = summary.measured;
        this.progress.timeout = summary.timedOut;
        this.progress.failed = summary.failed;
        this.progress.cancelled = summary.cancelled;
        this.progress.running = false;
        this.finished = true;
        this.clearOwnTesting();
        this.resolveDone(this.progress);
        AppLogger.info(TAG, `delay batch done: total=${summary.total} measured=${summary.measured} `
          + `timeout=${summary.timedOut} failed=${summary.failed} cancelled=${summary.cancelled} `
          + `wall=${summary.wallMs}ms conc=${summary.concurrency} peak=${summary.peakInflight}`);
      });
  }

  private apply(result: DelayResult): void {
    const now = Date.now();
    // 【2026-10-22 真机 bug 修复】失败分类必须是 `LatencyProbeKind` 里的**真分类**：
    // 旧实现写的是字面量 `'failed'`，而 `LatencyStore.describe()` 只认表内分类
    // （timeout / network_unreachable / switch_failed / …），认不出就走 `else → '--'`。
    // 真机表现就是「20 个节点测完，13 个失败的全部显示 --，不是超时/拨号失败」。
    let failKind: string = LatencyProbeKind.TIMEOUT;
    if (result.value !== FLCLASH_DELAY_TIMED_OUT) {
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
        result.value === FLCLASH_DELAY_TIMED_OUT ? LatencyState.TIMEOUT : LatencyState.FAILED,
        now, LatencyChannel.CORE, failKind);
    rec.source = this.source;
    LatencyLiveView.setRecord(rec);
    this.progress.started = this.progress.started + 1;
    if (valid) {
      this.progress.measured = this.progress.measured + 1;
    } else if (result.value === FLCLASH_DELAY_TIMED_OUT) {
      this.progress.timeout = this.progress.timeout + 1;
    } else {
      this.progress.failed = this.progress.failed + 1;
    }
  }

  isRunning(): boolean {
    return !this.finished && this.run.isRunning();
  }

  currentProgress(): FlclashLatencyProgress {
    return this.progress;
  }

  /** 等本批结束（正常完成或取消都会兑现）。 */
  wait(): Promise<FlclashLatencyProgress> {
    return this.donePromise;
  }

  /** 取消：在途 abort、未开始跳过，一条结论都不写。 */
  cancel(): void {
    if (this.finished) {
      return;
    }
    this.run.cancel();
    this.clearOwnTesting();
    this.progress.running = false;
    this.finished = true;
    this.resolveDone(this.progress);
    AppLogger.info(TAG, `delay batch cancelled: ${this.progress.started}/${this.progress.total} started`);
  }
}

export class FlclashLatencyService {
  private static current: FlclashLatencySession | null = null;

  /**
   * 启动一批测速（新批会取消旧批，与 FlClash「一个 job 一个 cancel 标记」一致）。
   *
   * @param nodeNames 待测节点名（内核 `/proxies` 里的名字，**不是**本地节点表的名字）
   * @param testUrl   全局测速 URL（默认 gstatic 204）
   * @param perNodeUrl 可选：按节点给测速 URL（FlClash 组内 `url` 优先）
   */
  static start(api: ClashApiService, nodeNames: string[], testUrl: string,
    source: string = 'manual',
    perNodeUrl: Map<string, string> | null = null): FlclashLatencySession {
    if (FlclashLatencyService.current !== null) {
      FlclashLatencyService.current.cancel();
    }
    const effectiveUrl = testUrl.length > 0 ? testUrl : FLCLASH_DELAY_URL;
    const seen: Set<string> = new Set<string>();
    const targets: DelayTarget[] = [];
    const previous: Map<string, LatencyRecord> = new Map<string, LatencyRecord>();
    // 批次身份：发号统一走 LatencyLiveView.nextRunId —— 与 LatencyEngine 共用
    // 同一序列，跨引擎永不撞号（旧批收尾误清新批 TESTING 标记的结构性根因）。
    const runId = LatencyLiveView.nextRunId();
    for (const name of nodeNames) {
      if (name.length === 0 || seen.has(name)) {
        continue;
      }
      seen.add(name);
      const url = perNodeUrl !== null && perNodeUrl.has(name) ? perNodeUrl.get(name) as string : effectiveUrl;
      targets.push(new DelayTarget(name, url.length > 0 ? url : effectiveUrl,
        delayTestKey(url.length > 0 ? url : effectiveUrl, name)));
      const old = LatencyLiveView.recordFor(name);
      if (old !== null && old.state !== LatencyState.TESTING) { previous.set(name, old); }
      LatencyLiveView.markTesting(name, runId);
    }
    const session = new FlclashLatencySession(api, targets, source, runId, previous);
    FlclashLatencyService.current = session;
    AppLogger.info(TAG, `delay batch start: nodes=${targets.length} url=${effectiveUrl} source=${source}`);
    return session;
  }

  static cancelCurrent(): void {
    if (FlclashLatencyService.current !== null) {
      FlclashLatencyService.current.cancel();
      FlclashLatencyService.current = null;
    }
  }

  static isRunning(): boolean {
    return FlclashLatencyService.current !== null && FlclashLatencyService.current.isRunning();
  }

  static currentProgress(): FlclashLatencyProgress | null {
    return FlclashLatencyService.current === null ? null : FlclashLatencyService.current.currentProgress();
  }

  /**
   * 组测速（FlClash `delayTestPageGroup`）：组内所有节点逐个测。
   * 返回被取消/未开始的节点数由 session 自己的 summary 负责。
   */
  static startGroup(api: ClashApiService, groupNodeNames: string[], testUrl: string,
    source: string = 'manual'): FlclashLatencySession {
    return FlclashLatencyService.start(api, groupNodeNames, testUrl, source, null);
  }
}

// 回收探针注册：组测速/订阅测速批进行中阻止编排器回收无头内核（顺延而非杀核）。
// 注册在类外静态初始化，import 本模块即生效；重复注册由 includes 去重。
const recycleProbe = (): boolean => FlclashLatencyService.isRunning();
if (!ConnectionOrchestrator.testCoreBusyProbes.includes(recycleProbe)) {
  ConnectionOrchestrator.testCoreBusyProbes.push(recycleProbe);
}
