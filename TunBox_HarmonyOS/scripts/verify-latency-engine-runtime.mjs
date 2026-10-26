/**
 * LatencyEngine 真实行为验证（跑真代码，不是读源码）。
 *
 * 为什么必须做：LatencyEngine 是本次重做的核心（唯一入口、并发池、硬截止、
 * 取消、通道分类、TESTING 收尾），但此前只有**源码断言**覆盖 —— 排序、持久化、
 * 徽标都已经真跑了，引擎反而是唯一没被执行过的一环。
 *
 * 做法：把 LatencyEngine.ets 暂存为 .ts 后 import，注入全部依赖的桩
 * （api 是构造参数，天然可注入；其余是模块级单例，用桩模块替换）：
 *   - ClashApiService 桩：可编程的 testLatencyDetailed（按节点名返回结果/抛错/延迟）
 *   - ConnectionOrchestrator 桩：记录 scheduleTestCoreRecycle 调用 + refreshLatencyEndpoint
 *   - AppLogger 桩：吞日志
 *   - LatencyState / LatencyController / ProxyNode：用真实实现（也是真跑的一部分）
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const appRoot = path.join(here, '..');
const svc = path.join(appRoot, 'entry/src/main/ets/commons/services/');
const latencyDir = path.join(appRoot, 'entry/src/main/ets/commons/latency/');

let passed = 0;
let failed = 0;
const failures = [];
function check(name, fn) {
  try {
    fn();
    passed++;
    console.log(`PASS ${name}`);
  } catch (e) {
    failed++;
    failures.push(`${name} :: ${e.message}`);
    console.log(`FAIL ${name} :: ${e.message}`);
  }
}
async function checkAsync(name, fn) {
  try {
    await fn();
    passed++;
    console.log(`PASS ${name}`);
  } catch (e) {
    failed++;
    failures.push(`${name} :: ${e.message}`);
    console.log(`FAIL ${name} :: ${e.message}`);
  }
}
function eq(a, b, label) {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`${label}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
  }
}
function ok(c, label) {
  if (!c) throw new Error(label);
}

// ── 暂存 ──────────────────────────────────────────────────────────────────
const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'latency-engine-'));
const w = (n, s) => fs.writeFileSync(path.join(stage, n), s, 'utf8');

// 真实现（真跑）
for (const f of ['LatencyState', 'LatencyLiveView']) {
  const src = fs.readFileSync(path.join(svc, f + '.ets'), 'utf8')
    .replace(/from '(\.\/[A-Za-z0-9_]+)'/g, "from '$1.ts'")
    // ⚠ services 侧现在会值依赖 `../latency/LatencyKinds`（零 import 的分类表）：
    //   扁平沙箱里没有那一层目录 ⇒ 必须改写成同目录 './LatencyKinds.ts'。
    .replace(/from '\.\.\/latency\/([A-Za-z0-9_]+)'/g, "from './$1.ts'")
    ;
  w(f + '.ts', src);
}

// 真实现：DNS 预检结论（**零 import** 的纯模块 => 扁平沙箱可直接暂存）
w('LatencyDnsVerdict.ts',
  fs.readFileSync(path.join(latencyDir, 'LatencyDnsVerdict.ets'), 'utf8')
    .replace(/from '(\.[A-Za-z0-9_/]+)'/g, "from '$1.ts'"));

// 真实现：失败分类表 + 探测结果类型（**零 import** 的纯模块 => 扁平沙箱可直接暂存）
// ⚠ 分类表住在零 import 的 LatencyKinds.ets：services 侧只值依赖零 import 模块，
//   Node 行为闸门把 services 扁平暂存时才不会 ERR_MODULE_NOT_FOUND。
w('LatencyKinds.ts',
  fs.readFileSync(path.join(latencyDir, 'LatencyKinds.ets'), 'utf8'));

// 桩：ProxyNode
w('ProxyNode.ts', `
export class ProxyNodeType {
  static readonly SS: string = 'ss';
  static readonly SSR: string = 'ssr';
}
export class ProxyNode {
  name: string = '';
  type: string = '';
  server: string = '';
  port: number = 0;
  constructor(name: string = '', server: string = '') {
    this.name = name; this.server = server; this.type = 'ss'; this.port = 443;
  }
}
`);

// 桩：AppLogger
w('AppLogger.ts', `
export class AppLogger {
  static info(_t: string, _m: string): void {}
  static warn(_t: string, _m: string): void {}
  static error(_t: string, _m: string): void {}
  static errText(e: Object): string { return String(e); }
}
`);

// 桩：ClashApiService（分类表与结果类型用**真源** LatencyKinds.ets）
w('ClashApiService.ts', `
import { LatencyProbeKind, LatencyProbeResult } from './LatencyKinds.ts';
/** 可编程内核桩：由测试注入 handler(name) -> LatencyProbeResult | Promise。
 *  cancelInflight 忠实模拟真实实现：真实代码里是 req.destroy() → req.request 抛错
 *  → classifyTransportError() → CORE_NOT_READY（见 ClashApiService.ets:406）。
 *  桩若不模拟这一点，"取消"这条路径就测不出真行为。 */
export class ClashApiService {
  static handler = null;
  static calls = [];
  static maxInflight = 0;
  static _inflight = 0;
  static cancelled = 0;
  static _pending = [];
  static reset() {
    ClashApiService.handler = null;
    ClashApiService.calls = [];
    ClashApiService.maxInflight = 0;
    ClashApiService._inflight = 0;
    ClashApiService.cancelled = 0;
    ClashApiService._pending = [];
    ClashApiService.dnsShortCircuits = [];
  }
  /** DNS 预检判 unresolved 的节点：内核**一次请求都不发**（见 LatencyProbe.probeOne） */
  static dnsShortCircuits = [];
  /**
   * 通道健康探针桩（见 LatencyEngine.controllerAnswers）：
   * 默认 **不答**（= 通道真的没了）⇒ 连击/自愈/作废整批的原语义保持不变；
   * 想测「过载不得作废整批」把它设成 true。
   */
  static controllerAlive = false;
  static probeCalls = 0;
  async probeController(_timeoutMs = 1500) {
    ClashApiService.probeCalls++;
    return {
      reachable: ClashApiService.controllerAlive,
      secretAccepted: ClashApiService.controllerAlive,
    };
  }
  async testLatencyDetailed(name, url, timeoutMs, lanes = 1, dns = null) {
    if (dns !== null && dns !== undefined && dns.status === 'unresolved') {
      // 忠实模拟内核行为：不记入 calls（= 没发 /delay），直接给结论
      ClashApiService.dnsShortCircuits.push({ name, url, timeoutMs, lanes, dns });
      return probeResult(-1, LatencyProbeKind.DNS_UNRESOLVED, 0);
    }
    ClashApiService.calls.push({ name, url, timeoutMs, lanes, dns });
    ClashApiService._inflight++;
    if (ClashApiService._inflight > ClashApiService.maxInflight) {
      ClashApiService.maxInflight = ClashApiService._inflight;
    }
    const state = { aborted: false };
    const abort = () => { state.aborted = true; };
    ClashApiService._pending.push(abort);
    try {
      const h = ClashApiService.handler;
      if (h === null) { throw new Error('no handler'); }
      const r = await h(name, url, timeoutMs);
      if (state.aborted) {
        // 被 destroy 的请求在真实实现里抛错并被归类为通道不可用
        return probeResult(-1, LatencyProbeKind.CORE_NOT_READY, 0);
      }
      return r;
    } finally {
      const i = ClashApiService._pending.indexOf(abort);
      if (i >= 0) { ClashApiService._pending.splice(i, 1); }
      ClashApiService._inflight--;
    }
  }
  cancelInflight() {
    ClashApiService.cancelled++;
    const pend = ClashApiService._pending.slice();
    ClashApiService._pending = [];
    for (const a of pend) { a(); }
    return pend.length;
  }
}
export function probeResult(delayMs, failKind = '', httpCode = 0) {
  const r = new LatencyProbeResult();
  r.delayMs = delayMs; r.failKind = failKind; r.httpCode = httpCode;
  return r;
}
`);

// 桩：DoHResolver（入口域名 pin 自愈：节点 TIMEOUT 时丢 pin）
w('DoHResolver.ts', `
export class DoHResolver {
  static dropped = [];
  static reset() { DoHResolver.dropped = []; }
  static dropPin(domain) { DoHResolver.dropped.push(domain); }
}
`);

// 桩：ConnectionOrchestrator（记录回收/自愈调用）
w('ConnectionOrchestrator.ts', `
export class LatencyHostSnapshot {
  pins: Record<string, string> = {};
  attempted: string[] = [];
}
export class ConnectionOrchestrator {
  static recycles = [];
  static recoverCalls = 0;
  static recoverResult = true;
  // LatencyEngine 模块级会把自己注册进这个探针表（recycleProbe）
  static testCoreBusyProbes = [];
  /** 可配置的 DNS 快照：{ pins: {...}, attempted: [...] } */
  static snapshot = null;
  /** hostSnapshot() 被调用的次数（引擎应当**每批一次**） */
  static snapshotCalls = 0;
  static reset() {
    ConnectionOrchestrator.recycles = [];
    ConnectionOrchestrator.recoverCalls = 0;
    ConnectionOrchestrator.recoverResult = true;
    ConnectionOrchestrator.snapshot = null;
    ConnectionOrchestrator.snapshotCalls = 0;
  }
  static _inst = null;
  static instance() {
    if (ConnectionOrchestrator._inst === null) {
      ConnectionOrchestrator._inst = new ConnectionOrchestrator();
    }
    return ConnectionOrchestrator._inst;
  }
  hostSnapshot() {
    ConnectionOrchestrator.snapshotCalls++;
    const s = new LatencyHostSnapshot();
    const cfg = ConnectionOrchestrator.snapshot;
    if (cfg !== null) {
      s.pins = cfg.pins || {};
      s.attempted = cfg.attempted || [];
    }
    return s;
  }
  scheduleTestCoreRecycle(ms) { ConnectionOrchestrator.recycles.push(ms); }
  async refreshLatencyEndpoint(_api) {
    ConnectionOrchestrator.recoverCalls++;
    return ConnectionOrchestrator.recoverResult;
  }
}
`);

// 真模块：LatencyEngine（import 指向桩）
let engSrc = fs.readFileSync(path.join(svc, 'LatencyEngine.ets'), 'utf8');
engSrc = engSrc
  .replace(/from '\.\.\/utils\/AppLogger'/g, "from './AppLogger.ts'")
  .replace(/from '\.\/ClashApiService'/g, "from './ClashApiService.ts'")
  .replace(/from '\.\/ConnectionOrchestrator'/g, "from './ConnectionOrchestrator.ts'")
  .replace(/from '\.\/LatencyState'/g, "from './LatencyState.ts'")
  .replace(/from '\.\/LatencyLiveView'/g, "from './LatencyLiveView.ts'")
  .replace(/from '\.\.\/models\/ProxyNode'/g, "from './ProxyNode.ts'")
  .replace(/from '\.\/DoHResolver'/g, "from './DoHResolver.ts'")
  .replace(/from '\.\.\/latency\/LatencyDnsVerdict'/g, "from './LatencyDnsVerdict.ts'")
  .replace(/from '\.\.\/latency\/LatencyKinds'/g, "from './LatencyKinds.ts'");
ok(!/from '@ohos/.test(engSrc), 'staged engine must not import ohos kits');
w('LatencyEngine.ts', engSrc);

const E = await import(pathToFileURL(path.join(stage, 'LatencyEngine.ts')).href);
const { LatencyEngine, LatencyRunOptions, LATENCY_CONCURRENCY, BATCH_DEADLINE_MS } = E;
const { LatencyLiveView } = await import(pathToFileURL(path.join(stage, 'LatencyLiveView.ts')).href);
const { LatencyState, LatencyChannel } = await import(pathToFileURL(path.join(stage, 'LatencyState.ts')).href);
const { ClashApiService, probeResult } =
  await import(pathToFileURL(path.join(stage, 'ClashApiService.ts')).href);
const { LatencyProbeKind } =
  await import(pathToFileURL(path.join(stage, 'LatencyKinds.ts')).href);
const { ConnectionOrchestrator } = await import(pathToFileURL(path.join(stage, 'ConnectionOrchestrator.ts')).href);
const { ProxyNode } = await import(pathToFileURL(path.join(stage, 'ProxyNode.ts')).href);
const { DoHResolver } = await import(pathToFileURL(path.join(stage, 'DoHResolver.ts')).href);

const URL_ = 'https://www.gstatic.com/generate_204';
function nodes(n) {
  const out = [];
  for (let i = 0; i < n; i++) out.push(new ProxyNode('node-' + i, '1.2.3.' + (i % 250 + 1)));
  return out;
}
function fresh() {
  LatencyLiveView.clearAll();
  ClashApiService.reset();
  ConnectionOrchestrator.reset();
  DoHResolver.reset();
}
function opts(over = {}) {
  const o = new LatencyRunOptions();
  o.force = over.force ?? true;
  o.timeoutMs = over.timeoutMs ?? 5000;
  o.onResult = null;
  o.onProgress = over.onProgress ?? null;
  // 可注入的整批硬截止（默认 90s；测试用小值确定性触发 deadline）
  if (over.batchDeadlineMs !== undefined) {
    o.batchDeadlineMs = over.batchDeadlineMs;
  }
  return o;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── 1. 并发上限：真跑 worker 池 ───────────────────────────────────────────
await checkAsync('并发严格不超过 LATENCY_CONCURRENCY（真跑 worker 池）', async () => {
  fresh();
  ClashApiService.handler = async (name) => {
    await sleep(30);
    return probeResult(100);
  };
  const api = new ClashApiService();
  const run = LatencyEngine.start(api, nodes(40), URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  ok(ClashApiService.maxInflight <= LATENCY_CONCURRENCY,
    `max inflight ${ClashApiService.maxInflight} must be <= ${LATENCY_CONCURRENCY}`);
  ok(ClashApiService.maxInflight >= 2,
    `pool should actually parallelise (got ${ClashApiService.maxInflight})`);
  eq(p.measured, 40, 'all measured');
  eq(p.finished, 40, 'all finished');
  eq(p.failed, 0, 'no failures');
  eq(ClashApiService.calls.length, 40, 'one probe per node');
});

// ── 2. 每个探测都带 URL 与 timeout（契约：timeout 必传且 <=32767） ─────────
await checkAsync('每个探测都显式带 HTTPS url 与合法 timeout', async () => {
  fresh();
  ClashApiService.handler = async () => probeResult(50);
  const run = LatencyEngine.start(new ClashApiService(), nodes(6), URL_, opts({ timeoutMs: 5000 }));
  await run.run();
  LatencyEngine.release(run);
  for (const c of ClashApiService.calls) {
    eq(c.url, URL_, 'url passed through');
    ok(c.url.startsWith('https://'), 'must be https (hijacking proxies: 明文地址会被机场劫持)');
    ok(c.timeoutMs > 0 && c.timeoutMs <= 32767, `timeout ${c.timeoutMs} must be 1..32767`);
  }
});

// ── 3. 五态落库 ───────────────────────────────────────────────────────────
await checkAsync('结果按五态落库：实测/超时/失败各自可区分', async () => {
  fresh();
  const table = {
    'node-0': probeResult(42),
    'node-1': probeResult(-1, LatencyProbeKind.TIMEOUT, 504),
    'node-2': probeResult(-1, LatencyProbeKind.NETWORK_UNREACHABLE, 503),
    'node-3': probeResult(-1, LatencyProbeKind.SWITCH_FAILED, 404),
  };
  ClashApiService.handler = async (name) => table[name];
  const run = LatencyEngine.start(new ClashApiService(), nodes(4), URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  eq(LatencyLiveView.stateFor('node-0'), LatencyState.MEASURED, 'measured');
  eq(LatencyLiveView.recordFor('node-0').delayMs, 42, 'delay value');
  eq(LatencyLiveView.stateFor('node-1'), LatencyState.TIMEOUT, 'timeout');
  eq(LatencyLiveView.stateFor('node-2'), LatencyState.FAILED, 'network unreachable -> failed');
  eq(LatencyLiveView.stateFor('node-3'), LatencyState.FAILED, 'switch failed -> failed');
  eq(p.measured, 1, 'progress measured');
  eq(p.timeout, 1, 'progress timeout');
  eq(p.failed, 2, 'progress failed');
  // 超时与失败必须是不同的状态（旧实现把两者都画成"超时"）
  ok(LatencyLiveView.stateFor('node-1') !== LatencyLiveView.stateFor('node-2'),
    'timeout and failure must stay distinguishable');
});

// ── 4. delay==0 绝不当有效延迟 ────────────────────────────────────────────
await checkAsync('内核回 200 但 delay==0（失败语义）不得记为有效延迟', async () => {
  fresh();
  ClashApiService.handler = async () => probeResult(0, LatencyProbeKind.NONE, 200);
  const run = LatencyEngine.start(new ClashApiService(), nodes(3), URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  eq(p.measured, 0, 'must not count as measured');
  for (const n of ['node-0', 'node-1', 'node-2']) {
    ok(LatencyLiveView.stateFor(n) !== LatencyState.MEASURED, `${n} must not be MEASURED`);
  }
});

// ── 5. 通道故障绝不写成 FAILED；但被搁置的节点必须补「超时」（2026-10-18 新契约）──
// 旧契约：内核不可用 -> 整批作废、节点保持「未测」。
// 新契约（用户裁定「要么显示延迟、要么显示超时，不要第三种结果」）：
// 通道不可用 -> 整批作废，但**被搁置的节点补 TIMEOUT**，绝不留 `--`；
// 同时**绝不**写成 FAILED（FAILED 表示协议/认证层失败，与"够不着"不同）。
await checkAsync('内核全程不可用：不留未测、搁置节点补超时，且绝不写成失败', async () => {
  fresh();
  ConnectionOrchestrator.recoverResult = false; // 自愈失败 -> 通道不可用
  ClashApiService.handler = async () => probeResult(-1, LatencyProbeKind.CORE_NOT_READY, 0);
  const run = LatencyEngine.start(new ClashApiService(), nodes(30), URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  eq(p.coreUnavailable, true, 'batch must be flagged unavailable');
  eq(p.failed, 0, 'a dead core must NOT produce FAILED verdicts');
  ok(p.timeout > 0, `stranded nodes must be stamped TIMEOUT (got ${p.timeout})`);
  let untested = 0;
  let testing = 0;
  for (let i = 0; i < 30; i++) {
    const st = LatencyLiveView.stateFor('node-' + i);
    if (st === LatencyState.UNTESTED) untested++;
    if (st === LatencyState.TESTING) testing++;
    ok(st !== LatencyState.FAILED, `node-${i} must not be FAILED (got ${st})`);
  }
  eq(testing, 0, 'no node may be left TESTING (the forever-spinner bug)');
  eq(untested, 0, 'no node may be left "--" when the channel died (user requirement)');
  ok(p.finished < 30, `batch should still abort early (finished=${p.finished})`);
  ok(ConnectionOrchestrator.recoverCalls <= 1, 'recovery attempted at most once per batch');
});

// ── 6. 通道自愈成功则继续跑完 ─────────────────────────────────────────────
await checkAsync('中途失联但自愈成功：批次继续跑完', async () => {
  fresh();
  ConnectionOrchestrator.recoverResult = true;
  // 注意（2026-10-18 方案 C 后调整）：通道瞬时抖动现在会被**就地重试**吸收，
  // 所以"前 3 次调用失败"这种写法再也触发不到自愈（重试的后续调用就越过了阈值）。
  // 而 tryRecoverChannel() 只在 coreNotReadyStreak 达到阈值(=3)时才真正自愈。
  // 因此要走到自愈，必须让 **3 个节点各自把重试全部用尽**：
  // 每个节点 首次 + 2 次重试 都失败 → 连击满 3 → 触发一次自愈 → 自愈成功、不作废。
  const attempts = new Map();
  ClashApiService.handler = async (name) => {
    const a = attempts.get(name) ?? 0;
    attempts.set(name, a + 1);
    const alwaysFails = name === 'node-0' || name === 'node-1' || name === 'node-2';
    return (alwaysFails && a < 3)
      ? probeResult(-1, LatencyProbeKind.CORE_NOT_READY, 0)
      : probeResult(77);
  };
  const run = LatencyEngine.start(new ClashApiService(), nodes(12), URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  ok(ConnectionOrchestrator.recoverCalls === 1, 'must attempt recovery once');
  ok(p.measured > 0, `should recover and measure (measured=${p.measured})`);
  eq(p.coreUnavailable, false, 'must not be flagged unavailable after successful recovery');
});

// ── 7. 取消：不产生任何节点结论，且不留下 TESTING ─────────────────────────
// 真实语义（由本套件首次真跑确认）：abort 之后引擎**不落任何记录** —— 因为
// start() 抢占旧批次用的是同一个 cancel()，旧 worker 若写记录会盖掉新批次的
// TESTING 标记。所以被打断的节点最终是「未测 `--`」（由 clearOwnTestingMarks
// 收回），progress.cancelled 只作计数。
await checkAsync('取消：不产生节点结论、不留 TESTING，被打断的记为未测', async () => {
  fresh();
  ClashApiService.handler = async () => {
    await sleep(40);
    return probeResult(100);
  };
  const run = LatencyEngine.start(new ClashApiService(), nodes(40), URL_, opts());
  const started = run.run();
  for (let i = 0; i < 300 && ClashApiService._inflight === 0; i++) await sleep(2);
  ok(ClashApiService._inflight > 0, 'test needs at least one probe in flight');
  LatencyEngine.cancelCurrent();
  const p = await started;
  LatencyEngine.release(run);

  ok(p.finished < 40, `cancel must stop the batch (finished=${p.finished})`);
  let testing = 0;
  let failedCount = 0;
  let timeoutCount = 0;
  let untested = 0;
  for (let i = 0; i < 40; i++) {
    const st = LatencyLiveView.stateFor('node-' + i);
    if (st === LatencyState.TESTING) testing++;
    if (st === LatencyState.FAILED) failedCount++;
    if (st === LatencyState.TIMEOUT) timeoutCount++;
    if (st === LatencyState.UNTESTED) untested++;
  }
  eq(testing, 0, 'no node may be left TESTING after cancel (the forever-spinner bug)');
  eq(failedCount, 0, 'cancel must never produce node failures');
  eq(timeoutCount, 0, 'cancel must never produce timeouts');
  ok(untested > 0, `interrupted nodes must read as untested "--" (got ${untested})`);
  ok(p.cancelled > 0, `interrupted probes must be counted (got ${p.cancelled})`);
  ok(ClashApiService.cancelled > 0, 'cancelInflight must be called to free http handles');
  eq(p.coreUnavailable, false,
    'cancel must not be misreported as "core unavailable" (CORE_NOT_READY under the hood)');
});

// ── 8. 单航班 / 抢占 ──────────────────────────────────────────────────────
await checkAsync('新批次抢占旧批次：旧批次作废且不留 TESTING', async () => {
  fresh();
  ClashApiService.handler = async () => {
    await sleep(40);
    return probeResult(100);
  };
  const first = LatencyEngine.start(new ClashApiService(), nodes(30), URL_, opts());
  const p1 = first.run();
  await sleep(50);
  const second = LatencyEngine.start(new ClashApiService(), nodes(5), URL_, opts());
  const p2 = await second.run();
  const r1 = await p1;
  LatencyEngine.release(second);
  eq(p2.measured, 5, 'second batch completes');
  ok(r1.finished < 30, 'first batch must be aborted by preemption');
  let testing = 0;
  for (let i = 0; i < 30; i++) {
    if (LatencyLiveView.stateFor('node-' + i) === LatencyState.TESTING) testing++;
  }
  eq(testing, 0, 'preemption must not leave TESTING behind');
});

// ── 8b. TESTING 归属：旧批不得清掉新批打上的标记 ─────────────────────────
// 该竞态（旧批收尾 vs 新批重新标记同一节点）依赖真实时序，端到端很难稳定复现，
// 所以直接对**归属判定机制**做确定性断言：markTesting 必须写入 runId，且
// isTestingOwnedBy 必须按 runId 区分批次。机制一旦回归，这里立刻失败。
await check('TESTING 归属：runId 不同则不算本批（旧批不得清新批）', () => {
  fresh();
  LatencyLiveView.markTesting('shared-node', 1);
  const rec = LatencyLiveView.recordFor('shared-node');
  ok(rec !== null && rec.runId === 1,
    `record must carry runId, got ${rec === null ? 'null' : rec.runId}`);
  ok(LatencyLiveView.isTestingOwnedBy('shared-node', 1), 'runId 1 owns its own mark');
  ok(!LatencyLiveView.isTestingOwnedBy('shared-node', 2), 'runId 2 must NOT own runId 1 mark');
  // 新批覆盖标记后，旧批彻底失去归属（这正是"旧批清新批"的防线）
  LatencyLiveView.markTesting('shared-node', 2);
  ok(!LatencyLiveView.isTestingOwnedBy('shared-node', 1),
    'after re-mark by runId 2, runId 1 must lose ownership');
  ok(LatencyLiveView.isTestingOwnedBy('shared-node', 2), 'runId 2 keeps its own mark');
});

await check('TESTING 归属：runId=0 保持旧调用点宽松语义', () => {
  fresh();
  LatencyLiveView.markTesting('legacy-node', 0);
  const rec = LatencyLiveView.recordFor('legacy-node');
  ok(rec !== null && rec.runId === 0, 'unmanaged mark keeps runId 0');
  ok(LatencyLiveView.isTestingOwnedBy('legacy-node', 0), 'runId 0 matches itself');
  ok(LatencyLiveView.isTestingOwnedBy('legacy-node', 7),
    'runId 0 mark is treated as unowned-by-all (legacy tolerance)');
});

// ── 9. force=false 只补缺失/过期 ──────────────────────────────────────────
await checkAsync('force=false：新鲜结果跳过，过期结果重测', async () => {
  fresh();
  ClashApiService.handler = async () => probeResult(55);
  // 先测一批
  const r0 = LatencyEngine.start(new ClashApiService(), nodes(4), URL_, opts({ force: true }));
  await r0.run();
  LatencyEngine.release(r0);
  eq(ClashApiService.calls.length, 4, 'initial probe count');

  // 再以 force=false 跑一次：应全部跳过
  const r1 = LatencyEngine.start(new ClashApiService(), nodes(4), URL_, opts({ force: false }));
  const p1 = await r1.run();
  LatencyEngine.release(r1);
  eq(p1.skipped, 4, 'fresh results skipped');
  eq(ClashApiService.calls.length, 4, 'no extra probes for fresh results');

  // 把其中两个标记为过期 -> 只有它们重测
  const old = Date.now() - 11 * 60 * 1000;
  LatencyLiveView.setRecord({
    name: 'node-1', state: LatencyState.MEASURED, delayMs: 55,
    atMs: old, channel: LatencyChannel.CORE,
    measured: () => true, failed: () => false, untested: () => false, hasValue: () => true,
    isFailure: () => false,
  });
  LatencyLiveView.setRecord({
    name: 'node-2', state: LatencyState.MEASURED, delayMs: 55,
    atMs: old, channel: LatencyChannel.CORE,
    measured: () => true, failed: () => false, untested: () => false, hasValue: () => true,
    isFailure: () => false,
  });
  const r2 = LatencyEngine.start(new ClashApiService(), nodes(4), URL_, opts({ force: false }));
  const p2 = await r2.run();
  LatencyEngine.release(r2);
  eq(p2.skipped, 2, 'only the fresh two skipped');
  eq(ClashApiService.calls.length, 6, 'the two stale nodes re-probed');
});

// ── 10. 没有内核通道：api=null ⇒ **不探测**（旧离线兜底通道已下线）────────
// 旧实现走「离线直连兜底」：测的是**服务器可达**（TCP/TLS 握手），不是代理延迟，
// 于是「服务器近」被当成「线路快」混进延迟列（UI 上还带 ≈ 前缀）。该通道已下线：
// 现在没有内核通道就**一个请求都不发**，节点保持「未测(--)」。
await checkAsync('没有内核通道（api=null）：不探测，节点保持未测，不冒充延迟', async () => {
  fresh();
  const run = LatencyEngine.start(null, nodes(5), URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  eq(ClashApiService.calls.length, 0, 'no request must be sent without a core channel');
  eq(p.measured, 0, 'nothing measured');
  eq(p.failed, 0, 'not a failure');
  eq(p.timeout, 0, 'not a timeout');
  eq(p.skipped, 0, 'not skipped either — we simply did not probe');
  eq(p.finished, 5, 'progress still closes out');
  eq(ConnectionOrchestrator.recycles.length, 0, 'no core -> no recycle scheduled');
  for (let i = 0; i < 5; i++) {
    eq(LatencyLiveView.stateFor('node-' + i), LatencyState.UNTESTED, `node-${i} stays untested`);
    eq(LatencyLiveView.recordFor('node-' + i), null, `node-${i} has no record at all`);
  }
});

await checkAsync('没有内核通道：不写任何 ≈ 离线读数（不得冒充代理延迟）', async () => {
  fresh();
  const list = [
    new ProxyNode('local-127', '127.0.0.1'),
    new ProxyNode('public', '8.8.8.8'),
  ];
  const run = LatencyEngine.start(null, list, URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  eq(p.measured, 0, 'no ≈ reading at all');
  for (const n of ['local-127', 'public']) {
    ok(LatencyLiveView.stateFor(n) !== LatencyState.OFFLINE,
      `${n} must not get an offline ≈ reading`);
  }
});

// ── 12. 内核通道结束后挂回收（且只在有内核时） ────────────────────────────
await checkAsync('内核通道批次结束后挂一次宽限回收', async () => {
  fresh();
  ClashApiService.handler = async () => probeResult(30);
  const run = LatencyEngine.start(new ClashApiService(), nodes(3), URL_, opts());
  await run.run();
  LatencyEngine.release(run);
  eq(ConnectionOrchestrator.recycles.length, 1, 'exactly one recycle scheduled');
  ok(ConnectionOrchestrator.recycles[0] >= 30000,
    `recycle grace should be generous (got ${ConnectionOrchestrator.recycles[0]}ms)`);
});

// ── 13. worker 抛异常也必须收尾 ───────────────────────────────────────────
// 覆盖"客户端 api 直接 reject"（传输层抛错，而不是返回 failKind）。单个节点抛异常
// 必须就地收敛：不能带走整批（否则其余 lane 变孤儿，批次宣布结束后还在落库）。
await checkAsync('探测直接抛异常：只影响该节点，整批照常跑完', async () => {
  fresh();
  ClashApiService.handler = async (name) => {
    if (name === 'node-1') throw new Error('boom');
    return probeResult(20);
  };
  const run = LatencyEngine.start(new ClashApiService(), nodes(5), URL_, opts());
  let threw = false;
  let p = null;
  try {
    p = await run.run();
  } catch (e) {
    threw = true;
  }
  LatencyEngine.release(run);
  eq(threw, false, 'a single throwing probe must not reject the whole batch');
  let testing = 0;
  for (let i = 0; i < 5; i++) {
    if (LatencyLiveView.stateFor('node-' + i) === LatencyState.TESTING) testing++;
  }
  eq(testing, 0, 'a throwing probe must not leave TESTING behind');
  const st1 = LatencyLiveView.stateFor('node-1');
  ok(st1 !== LatencyState.FAILED,
    `a thrown transport error must not become a node FAILED verdict (got ${st1})`);
  eq(st1, LatencyState.UNTESTED, 'the throwing node stays untested');
  eq(p.measured, 4, 'the other four nodes still get measured');
  eq(p.finished, 5, 'progress must still reach total (otherwise the bar hangs)');
});

// ── 14. 进度确定性 ────────────────────────────────────────────────────────
await checkAsync('进度确定性：finished 单调不减且最终等于 total', async () => {
  fresh();
  const seen = [];
  ClashApiService.handler = async () => {
    await sleep(5);
    return probeResult(10);
  };
  const run = LatencyEngine.start(new ClashApiService(), nodes(25), URL_,
    opts({ onProgress: (p) => seen.push(p.finished) }));
  const p = await run.run();
  LatencyEngine.release(run);
  eq(p.finished, 25, 'finished == total at end');
  eq(p.total, 25, 'total');
  for (let i = 1; i < seen.length; i++) {
    ok(seen[i] >= seen[i - 1], `progress must be monotonic (${seen[i - 1]} -> ${seen[i]})`);
  }
  ok(seen.length > 1, 'progress must actually be reported');
  eq(p.running, false, 'running must be false when settled');
});

// ── 15. 硬截止：剩余保持未测而不是失败 ────────────────────────────────────
// 确定性做法：给引擎注入一个小 deadline（LatencyRunOptions.batchDeadlineMs），
// 让它必然在批内触发。原做法是按「deadline × 并发 / 节点数」算一个巨大的单次
// 探测耗时去撞真实 90s 上限 —— 那让测试同时依赖并发度与节点数的算术关系，
// 改一次并发度就失效（2026-10-19 改 50→88 时确实挂了一次）。而且它要真等
// 两分多钟。现在：每批探测 60ms、deadline 200ms → 第三批取节点时必然已过截止。
await checkAsync('硬截止后剩余节点保持未测（绝不写成失败）', async () => {
  fresh();
  // 节点数必须**大于**并发数，否则只有一批、取不到「下一批」可拦。
  // 用 LATENCY_CONCURRENCY + 40 自适应，改并发度也不会让本测试失效。
  const total = LATENCY_CONCURRENCY + 40;
  const perProbeMs = 300;
  // deadline 必须大于首批 worker 的错峰抖动上限（200ms，保证首批 88 个都能
  // 取到节点），又要小于首批完成时刻（300ms+jitter）→ 第二批必然被拦。
  const deadlineMs = 250;
  ClashApiService.handler = async () => {
    await sleep(perProbeMs);
    return probeResult(10);
  };
  const run = LatencyEngine.start(new ClashApiService(), nodes(total), URL_,
    opts({ batchDeadlineMs: deadlineMs }));
  const p = await run.run();
  LatencyEngine.release(run);
  eq(p.failed, 0, 'deadline must not produce failures');
  eq(p.timeout, 0, 'deadline must not produce timeouts');
  let testing = 0;
  for (let i = 0; i < total; i++) {
    if (LatencyLiveView.stateFor('node-' + i) === LatencyState.TESTING) testing++;
  }
  eq(testing, 0, 'deadline must not leave TESTING');
  ok(p.measured > 0 && p.measured < total,
    `deadline should leave nodes untested (measured=${p.measured}/${total}, perProbe=${perProbeMs}ms)`);
  // 剩余节点既不是失败也不是超时 —— 就是"没测"
  eq(p.finished, p.measured, 'finished counts only the ones that actually settled');
});

// ── 16. release 语义 ──────────────────────────────────────────────────────
await checkAsync('release 之后引擎不再认为自己在跑', async () => {
  fresh();
  ClashApiService.handler = async () => probeResult(10);
  const run = LatencyEngine.start(new ClashApiService(), nodes(2), URL_, opts());
  ok(LatencyEngine.isRunning(), 'running while batch in flight');
  await run.run();
  ok(!LatencyEngine.isRunning(), 'settled batch is not running');
  LatencyEngine.release(run);
  ok(!LatencyEngine.isRunning(), 'released engine is not running');
  ok(LatencyEngine.currentProgress() === null || LatencyEngine.currentProgress() !== null,
    'currentProgress must not throw after release');
});

// ── 17. 方案 C（2026-10-18）：真实节点结论不得被通道作废回滚 ──────────────
// 用户报障：飞鸟云 37 节点批里，14 个已被内核盖成「超时」的节点在通道过载作废
// 整批后被回滚成「未测」，加上 20 个未探测节点，34/38 行都是 `--`。
// 用户要求「要么超时、要么显示延迟，不要第三种结果」。
// 旧实现回滚的理由是「通道故障批的章不可信」，但通道级故障走 notPublishable，
// 从不发布记录 —— 能被回滚的失败章 100% 是内核对该节点的真实拨号结论。
await checkAsync('C：通道作废整批时，已盖章的逐节点「超时」必须保留（不再回滚成未测）', async () => {
  fresh();
  ConnectionOrchestrator.recoverResult = false;
  let n = 0;
  // 前 6 个探测是真实节点超时（内核 504），其余按通道不可用 -> 触发整批作废
  ClashApiService.handler = async () => {
    n++;
    return n <= 6 ? probeResult(-1, LatencyProbeKind.TIMEOUT, 504)
      : probeResult(-1, LatencyProbeKind.CORE_NOT_READY, 0);
  };
  const run = LatencyEngine.start(new ClashApiService(), nodes(30), URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);

  eq(p.coreUnavailable, true, 'this batch must still be flagged unavailable (abort path kept)');
  ok(p.timeout > 0, `genuine node timeouts must be counted (got ${p.timeout})`);
  // 关键断言：已盖章的超时结论必须仍然读作 TIMEOUT，不得被改回 UNTESTED
  let keptTimeouts = 0;
  let rolledBack = 0;
  for (let i = 0; i < 30; i++) {
    const st = LatencyLiveView.stateFor('node-' + i);
    if (st === LatencyState.TIMEOUT) keptTimeouts++;
    if (st === LatencyState.UNTESTED) rolledBack++;
  }
  eq(keptTimeouts, p.timeout,
    'every counted timeout must still read as TIMEOUT in the controller (no rollback)');
  ok(keptTimeouts > 0, `expected some surviving timeout verdicts (got ${keptTimeouts})`);
  ok(rolledBack < 30,
    `aborted batch must not erase every verdict into "--" (untested=${rolledBack})`);
});

// ── 18. 方案 C：通道瞬时过载先重试/退避，不立刻判死 ───────────────────────
await checkAsync('C：通道瞬时不可用会重试；重试成功则照常出结论且不作废整批', async () => {
  fresh();
  ConnectionOrchestrator.recoverResult = false;
  let n = 0;
  const seenCount = new Map();
  // 每个节点的第 1 次探测都报通道不可用，重试即恢复 —— 模拟 controller 瞬时过载
  ClashApiService.handler = async (name) => {
    n++;
    const seen = seenCount.get(name) ?? 0;
    seenCount.set(name, seen + 1);
    return seen === 0 ? probeResult(-1, LatencyProbeKind.CORE_NOT_READY, 0) : probeResult(66);
  };
  const run = LatencyEngine.start(new ClashApiService(), nodes(6), URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);

  eq(p.coreUnavailable, false,
    'transient overload absorbed by retry must NOT invalidate the whole batch');
  eq(p.measured, 6, `all 6 nodes should recover via retry (measured=${p.measured})`);
  ok(n > 6, `retry must actually re-probe (calls=${n} for 6 nodes)`);
  for (let i = 0; i < 6; i++) {
    eq(LatencyLiveView.stateFor('node-' + i), LatencyState.MEASURED, `node-${i} measured`);
  }
});

// ── 19. 2026-10-18：节点超时 → 丢掉该入口域名的 DoH pin（主机名死 pin 自愈）──
// 背景：飞鸟云 34 节点整屏「超时」的真因是 hosts pin 把短 TTL 入口域名钉在旧 IP 上。
// 引擎这一侧的责任是：内核明确判该节点超时后，别让那条 pin 继续毒害下一批配置。
await checkAsync('超时节点会丢弃其入口域名的 DoH pin（下一批交给内核现解析）', async () => {
  fresh();
  const ns = [];
  for (let i = 0; i < 4; i++) ns.push(new ProxyNode('hn-' + i, 'sg0' + i + '.example.xyz'));
  ClashApiService.handler = async (name) => {
    // 前两个节点超时，后两个正常 —— 只应丢掉超时那两个的域名
    return name === 'hn-0' || name === 'hn-1'
      ? probeResult(-1, LatencyProbeKind.TIMEOUT, 504)
      : probeResult(88);
  };
  const run = LatencyEngine.start(new ClashApiService(), ns, URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  eq(p.timeout, 2, `two nodes should be timeout (got ${p.timeout})`);
  eq(DoHResolver.dropped.slice().sort(), ['sg00.example.xyz', 'sg01.example.xyz'],
    'exactly the timed-out nodes\' server domains must have their pin dropped');
});


// ── D. DNS 预检接线（2026-10-20 真机根因：域名解析不出来 ≠ 网络不可达）────
// 契约：
//  ① 编排器的 DoH 快照**每批取一次**（口径一批之内一致）；
//  ② attempted 里有、pins 里没有的域名 => **一次 /delay 都不发**，直接判 dns_unresolved；
//  ③ pins 里有的域名 => 照常探测；
//  ④ 不在 attempted 里的域名 => **没试过解析** => 照常探测（不得误报 unresolved）；
//  ⑤ 引擎把 DNS 结论**传下去**（探针据此短路）；
//  ⑥ 认不出来的响应（unknown）=> **非判定**：不落任何节点结论。
await checkAsync('D1 DNS 快照每批只取一次（不是逐节点去问编排器）', async () => {
  fresh();
  ConnectionOrchestrator.snapshot = { pins: { 'ok.example.xyz': '1.2.3.4' }, attempted: ['ok.example.xyz'] };
  ClashApiService.handler = async () => probeResult(70);
  const run = LatencyEngine.start(new ClashApiService(), nodes(5), URL_, opts());
  await run.run();
  LatencyEngine.release(run);
  eq(ConnectionOrchestrator.snapshotCalls, 1, `snapshot must be taken once per batch (got ${ConnectionOrchestrator.snapshotCalls})`);
});

await checkAsync('D2 域名解析不出来 => 一次 /delay 都不发，直接判 dns_unresolved', async () => {
  fresh();
  ConnectionOrchestrator.snapshot = {
    pins: {},
    attempted: ['dead.example.xyz'],
  };
  // ⚠ pins 为空 ⇒ 引擎按「快照无正例」保守降级（不判 unresolved）——
  //   这一条断言的是**有正例时**的判定路径（下面 D2b 覆盖空快照的降级）。
  ConnectionOrchestrator.snapshot = {
    pins: { 'alive.example.xyz': '1.2.3.4' },
    attempted: ['alive.example.xyz', 'dead.example.xyz'],
  };
  ClashApiService.handler = async () => probeResult(70);
  const ns = [new ProxyNode('dead-node', 'dead.example.xyz'), new ProxyNode('alive-node', 'alive.example.xyz')];
  const run = LatencyEngine.start(new ClashApiService(), ns, URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  const called = ClashApiService.calls.map((c) => c.name);
  ok(!called.includes('dead-node'), `unresolved node must NOT hit the kernel (called: ${called.join(',')})`);
  ok(called.includes('alive-node'), 'resolved node must still be probed');
  eq(ClashApiService.dnsShortCircuits.map((c) => c.name).join(','), 'dead-node',
    'unresolved node must be short-circuited by the DNS verdict');
  eq(LatencyLiveView.stateFor('dead-node'), LatencyState.FAILED, 'unresolved node is a node conclusion');
  const rec = LatencyLiveView.recordFor('dead-node');
  eq(rec.failKind, LatencyProbeKind.DNS_UNRESOLVED, 'failKind must be dns_unresolved');
  eq(p.dnsUnresolved, 1, 'progress counts dns_unresolved');
  eq(p.coreNotReady, 0, 'dns_unresolved is NOT a channel failure');
});

await checkAsync('D3 引擎把 DNS 结论传给探针（unresolved 由探针短路）', async () => {
  fresh();
  ConnectionOrchestrator.snapshot = {
    pins: { 'alive.example.xyz': '1.2.3.4' },
    attempted: ['alive.example.xyz', 'dead.example.xyz'],
  };
  ClashApiService.handler = async () => probeResult(70);
  const ns = [new ProxyNode('dead-node', 'dead.example.xyz'), new ProxyNode('alive-node', 'alive.example.xyz')];
  const run = LatencyEngine.start(new ClashApiService(), ns, URL_, opts());
  await run.run();
  LatencyEngine.release(run);
  for (const c of ClashApiService.calls) {
    ok(c.dns !== null && c.dns !== undefined, `dns verdict must be passed down (${c.name})`);
    ok(typeof c.dns.status === 'string', 'dns verdict must carry a status');
  }
  const aliveCall = ClashApiService.calls.find((c) => c.name === 'alive-node');
  eq(aliveCall.dns.status, 'resolved', 'alive domain => resolved');
});

await checkAsync('D4 没在 attempted 里的域名 => 没试过解析 => 照常探测（不得误报 unresolved）', async () => {
  fresh();
  ConnectionOrchestrator.snapshot = {
    pins: { 'alive.example.xyz': '1.2.3.4' },
    attempted: ['alive.example.xyz'],
  };
  ClashApiService.handler = async () => probeResult(70);
  const ns = [new ProxyNode('untried-node', 'never-tried.example.xyz')];
  const run = LatencyEngine.start(new ClashApiService(), ns, URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  eq(ClashApiService.calls.length, 1, 'untried domain must still be probed');
  eq(p.dnsUnresolved, 0, 'untried domain must NOT be judged unresolved');
  eq(LatencyLiveView.stateFor('untried-node'), LatencyState.MEASURED, 'untried domain is probed normally');
});

await checkAsync('D5 认不出来的响应（unknown）=> 非判定，不落任何节点结论', async () => {
  fresh();
  ClashApiService.handler = async () => probeResult(-1, LatencyProbeKind.UNKNOWN, 503);
  const run = LatencyEngine.start(new ClashApiService(), nodes(3), URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  for (const n of ['node-0', 'node-1', 'node-2']) {
    // 非判定失败 => 不产生节点结论：节点回到「未测(--)」，**绝不**是失败/延迟
    eq(LatencyLiveView.stateFor(n), LatencyState.UNTESTED,
      `${n} must have no verdict (unknown is not a conclusion)`);
    const rec = LatencyLiveView.recordFor(n);
    ok(rec === null || rec.failKind === '' || rec.failKind === LatencyProbeKind.UNTESTED,
      `${n} must not carry a failure verdict (got ${rec === null ? 'null' : rec.failKind})`);
  }
  eq(p.failed, 0, 'unknown must not count as failed');
  eq(p.measured, 0, 'unknown must not count as measured');
});

await checkAsync('D6 DNS 快照为空（无正例）=> 保守降级，不判 dns_unresolved', async () => {
  fresh();
  ConnectionOrchestrator.snapshot = { pins: {}, attempted: ['dead.example.xyz'] };
  ClashApiService.handler = async () => probeResult(70);
  const ns = [new ProxyNode('dead-node', 'dead.example.xyz')];
  const run = LatencyEngine.start(new ClashApiService(), ns, URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  eq(p.dnsUnresolved, 0, 'empty snapshot must not produce dns_unresolved (快照口径不可信时宁可少报)');
  eq(ClashApiService.calls.length, 1, 'node must still be probed');
});

fs.rmSync(stage, { recursive: true, force: true });
console.log(`\nLatency engine verification: ${passed} passed, ${failed} failed (EXEC real engine; stubbed deps).`);
if (failures.length > 0) {
  console.log('Failures:');
  for (const f of failures) console.log(`  - ${f}`);
}
if (failed > 0) process.exitCode = 1;
