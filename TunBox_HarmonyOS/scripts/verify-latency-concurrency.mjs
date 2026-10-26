/**
 * 测速并发闸门 + 组测失败分类的**行为**验证（跑真代码，不是读源码）。
 *
 * 对应方案 §9.4 的 C7 / C8 / C8b / C10 / C10b 与 §9.9 的验收门槛：
 *   「实测 HTTP 在途请求不超过 8；排队等待不被计入单请求网络超时」
 *   「504、404、503、连接失败、请求超时分别处理，不把非 200 一律判为内核不可用」
 *
 * 做法与 verify-latency-engine-runtime.mjs 同构：把真实现暂存为 .ts 后 import，
 * 只把「不可控的外部世界」换成桩：
 *   - LatencyEngine（真） + 可编程的 api 桩（记录在途数 / lanes / 发起时刻）
 *   - ClashApiService（真） + 假 http 层（可编程返回 200/401/404/503/504/抛异常）
 *
 * 分两组：
 *   A. 引擎侧：在途上限、lanes 语义、排队不计预算、排队超时的分类
 *   B. 组测侧：504/401/404/503/传输异常/200 各自的分类，以及旧接口行为不变
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const appRoot = path.join(here, '..');
const svc = path.join(appRoot, 'entry/src/main/ets/commons/services/');
const latency = path.join(appRoot, 'entry/src/main/ets/commons/latency/');

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
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const URL_ = 'https://www.gstatic.com/generate_204';

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'latency-conc-'));
const w = (dir, name, s) => fs.writeFileSync(path.join(dir, name), s, 'utf8');

// ── 公共依赖（真实现 + 桩） ───────────────────────────────────────────────
function writeDeps(dir) {
  // 真实实现（真跑）：LatencyState / LatencyLiveView（LP08：LatencyController 已删）
  for (const f of ['LatencyState', 'LatencyLiveView']) {
    const src = fs.readFileSync(path.join(svc, f + '.ets'), 'utf8')
      .replace(/from '(\.\/[A-Za-z0-9_]+)'/g, "from '$1.ts'")
      // ⚠ services 侧现在会值依赖 `../latency/LatencyKinds`（零 import 的分类表）：
      //   扁平沙箱里没有那一层目录 ⇒ 必须改写成同目录 './LatencyKinds.ts'。
      .replace(/from '\.\.\/latency\/([A-Za-z0-9_]+)'/g, "from './$1.ts'")
      ;
    w(dir, f + '.ts', src);
  }
  // 真实现：DNS 预检结论（**零 import** 的纯模块 ⇒ 扁平沙箱可直接暂存）
  w(dir, 'LatencyDnsVerdict.ts',
    fs.readFileSync(path.join(latency, 'LatencyDnsVerdict.ets'), 'utf8')
      .replace(/from '(\.[A-Za-z0-9_/]+)'/g, "from '$1.ts'"));
  // 真实现：失败分类表 + 探测结果类型（**零 import** 的纯模块 ⇒ 扁平沙箱可直接暂存）
  // ⚠ 分类表住在零 import 的 LatencyKinds.ets：services 侧只值依赖零 import 模块，
  //   扁平暂存才不会 ERR_MODULE_NOT_FOUND。
  w(dir, 'LatencyKinds.ts',
    fs.readFileSync(path.join(latency, 'LatencyKinds.ets'), 'utf8'));
  // 桩：AppLogger
  w(dir, 'AppLogger.ts', `
export class AppLogger {
  static info(_t: string, _m: string): void {}
  static warn(_t: string, _m: string): void {}
  static error(_t: string, _m: string): void {}
  static errText(e: Object): string { return String(e); }
}
`);
  // 桩：ProxyNode
  w(dir, 'ProxyNode.ts', `
export class ProxyNode {
  name: string = '';
  type: string = 'ss';
  server: string = '';
  port: number = 443;
  constructor(name: string = '', server: string = '') {
    this.name = name; this.server = server;
  }
}
`);
  // 桩：ConnectionOrchestrator（记录自愈/回收调用）
  w(dir, 'ConnectionOrchestrator.ts', `
export class LatencyHostSnapshot {
  pins: Record<string, string> = {};
  attempted: string[] = [];
}
export class ConnectionOrchestrator {
  static recycles = [];
  static recoverCalls = 0;
  static recoverResult = true;
  // LatencyEngine 模块级会把自己注册进这个探针表（recycleProbe）；
  // 桩缺这个静态字段 ⇒ TypeError: Cannot read properties of undefined (reading 'includes')
  static testCoreBusyProbes = [];
  static reset() {
    ConnectionOrchestrator.recycles = [];
    ConnectionOrchestrator.recoverCalls = 0;
    ConnectionOrchestrator.recoverResult = true;
  }
  static instance(): ConnectionOrchestrator { return new ConnectionOrchestrator(); }
  hostSnapshot(): LatencyHostSnapshot {
    const s = new LatencyHostSnapshot();
    return s;
  }
  scheduleTestCoreRecycle(_ms: number): void { ConnectionOrchestrator.recycles.push(_ms); }
  async refreshLatencyEndpoint(_api: Object): Promise<boolean> {
    ConnectionOrchestrator.recoverCalls++;
    return ConnectionOrchestrator.recoverResult;
  }
}
`);
  // 桩：DoHResolver
  w(dir, 'DoHResolver.ts', `
export class DoHResolver {
  static dropped = [];
  static dropPin(domain: string): void { DoHResolver.dropped.push(domain); }
}
`);
}

/**
 * 引擎侧的可编程 api 桩：记录**在途数**、lanes（引擎传下来的语义参数）、
 * 每次请求的发起/结束时刻（用来证明「排队期间没有请求在飞」）。
 */
const API_STUB = `
import { LatencyProbeKind, LatencyProbeResult } from './LatencyKinds.ts';
export function probeResult(delayMs, failKind = '', httpCode = 0) {
  const r = new LatencyProbeResult();
  r.delayMs = delayMs; r.failKind = failKind; r.httpCode = httpCode;
  return r;
}
export class ClashApiService {
  static handler = null;
  static calls = [];
  static maxInflight = 0;
  static _inflight = 0;
  /** 通道健康探针桩：controller 是否还答 /version（过载鉴别，见 controllerAnswers） */
  static controllerAlive = true;
  static probeCalls = 0;
  static reset() {
    ClashApiService.handler = null;
    ClashApiService.calls = [];
    ClashApiService.maxInflight = 0;
    ClashApiService._inflight = 0;
    ClashApiService.controllerAlive = true;
    ClashApiService.probeCalls = 0;
  }
  async probeController(_timeoutMs = 1500) {
    ClashApiService.probeCalls++;
    return {
      reachable: ClashApiService.controllerAlive,
      secretAccepted: ClashApiService.controllerAlive,
    };
  }
  async testLatencyDetailed(name, url, timeoutMs, lanes = 1) {
    const c = { name: name, url: url, timeoutMs: timeoutMs, lanes: lanes, start: Date.now(), end: 0 };
    ClashApiService.calls.push(c);
    ClashApiService._inflight++;
    if (ClashApiService._inflight > ClashApiService.maxInflight) {
      ClashApiService.maxInflight = ClashApiService._inflight;
    }
    try {
      const h = ClashApiService.handler;
      if (h === null) { throw new Error('no handler'); }
      return await h(name, url, timeoutMs);
    } finally {
      c.end = Date.now();
      ClashApiService._inflight--;
    }
  }
  cancelInflight() { return 0; }
}
`;

function stageEngine(dir, queueWaitMs, inflight) {
  fs.mkdirSync(dir, { recursive: true });
  writeDeps(dir);
  w(dir, 'ClashApiService.ts', API_STUB);
  let eng = fs.readFileSync(path.join(svc, 'LatencyEngine.ets'), 'utf8');
  eng = eng
    .replace(/from '\.\.\/utils\/AppLogger'/g, "from './AppLogger.ts'")
    .replace(/from '\.\/ClashApiService'/g, "from './ClashApiService.ts'")
    .replace(/from '\.\/ConnectionOrchestrator'/g, "from './ConnectionOrchestrator.ts'")
    .replace(/from '\.\/LatencyState'/g, "from './LatencyState.ts'")
    .replace(/from '\.\/LatencyLiveView'/g, "from './LatencyLiveView.ts'")
    .replace(/from '\.\.\/models\/ProxyNode'/g, "from './ProxyNode.ts'")
    .replace(/from '\.\/DoHResolver'/g, "from './DoHResolver.ts'")
    .replace(/from '\.\.\/latency\/LatencyDnsVerdict'/g, "from './LatencyDnsVerdict.ts'")
    .replace(/from '\.\.\/latency\/LatencyKinds'/g, "from './LatencyKinds.ts'");
  if (queueWaitMs !== undefined) {
    // 排队上限改小，才能确定性地触发「排队超时」这条路径
    eng = eng.replace(/export const LATENCY_QUEUE_WAIT_MAX_MS = \d+;/,
      `export const LATENCY_QUEUE_WAIT_MAX_MS = ${queueWaitMs};`);
  }
  if (inflight !== undefined) {
    // 在途数单独调小：worker 数与在途数同宽（都是 50）时闸门**永远不会排队**，
    // 「排队超时」这条路径就成了死代码 —— 必须显式收窄在途数才能覆盖它。
    eng = eng.replace(/export const LATENCY_INFLIGHT = \d+;/,
      `export const LATENCY_INFLIGHT = ${inflight};`);
  }
  w(dir, 'LatencyEngine.ts', eng);
}

// A 组：默认排队上限（60s）
const dirA = path.join(root, 'a');
stageEngine(dirA);
// B 组：排队上限 300ms + 在途数收窄到 8（确定性地触发排队超时）。
// 在途数必须**显式调小**：worker 数与在途数同宽（都 50）时闸门永远不排队。
const dirB = path.join(root, 'b');
stageEngine(dirB, 300, 32);

const A = await import(pathToFileURL(path.join(dirA, 'LatencyEngine.ts')).href);
const AC = await import(pathToFileURL(path.join(dirA, 'ClashApiService.ts')).href);
const ALC = await import(pathToFileURL(path.join(dirA, 'LatencyLiveView.ts')).href);
const ALState = await import(pathToFileURL(path.join(dirA, 'LatencyState.ts')).href);
const B = await import(pathToFileURL(path.join(dirB, 'LatencyEngine.ts')).href);
const BC = await import(pathToFileURL(path.join(dirB, 'ClashApiService.ts')).href);
const BLC = await import(pathToFileURL(path.join(dirB, 'LatencyLiveView.ts')).href);

const { ProxyNode } = await import(pathToFileURL(path.join(dirA, 'ProxyNode.ts')).href);

function nodes(n) {
  const out = [];
  for (let i = 0; i < n; i++) out.push(new ProxyNode('node-' + i, '1.2.3.' + (i % 250 + 1)));
  return out;
}
function opts(over) {
  const o = new A.LatencyRunOptions();
  o.force = true;
  o.timeoutMs = 5000;
  o.onResult = null;
  o.onProgress = null;
  if (over && over.batchDeadlineMs !== undefined) o.batchDeadlineMs = over.batchDeadlineMs;
  return o;
}

// ── A1. 常量契约 ───────────────────────────────────────────────────────────
check('常量契约：worker 并发=50、在途请求=32（对齐 FlClash 客户端在途并发）、排队上限=60s', () => {
  eq(A.LATENCY_CONCURRENCY, 50, 'LATENCY_CONCURRENCY（worker 数 / 队列深度）');
  eq(A.LATENCY_INFLIGHT, 32, 'LATENCY_INFLIGHT（同时在途的 HTTP 请求数）');
  eq(A.LATENCY_QUEUE_WAIT_MAX_MS, 60000, 'LATENCY_QUEUE_WAIT_MAX_MS');
  // 2026-10-21 真机回退：在途数一度是 50（"与 worker 数同宽"），但 OHOS http 栈对**同一 host**
  // 只有约 8 条连接 ⇒ 超出的请求在栈内部排队，排队时间被算进单请求预算 = 假超时；
  // 假超时又被归为 core_not_ready ⇒ 6 连击作废整批（飞鸟云 31 节点批：后 24 个节点没测）。
  // 现在在途数 = 连接池容量 ⇒ 排队发生在**应用层闸门**里，闸门等待不计预算（见 A4）。
  ok(A.LATENCY_INFLIGHT === 32,
    '在途数对齐 FlClash 客户端并发（32）');
  ok(A.LATENCY_INFLIGHT <= A.LATENCY_CONCURRENCY,
    '在途数不得超过 worker 数（worker 是队列深度上限）');
});

// ── A2. lanes 语义：传给 testLatencyDetailed 的是「在途数」= 8 ─────────────
await checkAsync('lanes 语义：传下去的是同时在途的 HTTP 请求数（8），与常量同源', async () => {
  AC.ClashApiService.reset();
  ALC.LatencyLiveView.clearAll();
  AC.ClashApiService.handler = async () => AC.probeResult(120, '', 200);
  const run = A.LatencyEngine.start(new AC.ClashApiService(), nodes(30), URL_, opts());
  await run.run();
  A.LatencyEngine.release(run);
  ok(AC.ClashApiService.calls.length === 30, `每节点一次探测（got ${AC.ClashApiService.calls.length}）`);
  for (const c of AC.ClashApiService.calls) {
    eq(c.lanes, 32, 'lanes 必须是在途数（= LATENCY_INFLIGHT = 32），不是 worker 数');
  }
});

// ── A3. 真跑一批：峰值在途 ≤ 8（且确实并行） ──────────────────────────────
await checkAsync('在途上限：真跑 40 节点，峰值在途请求数 ≤ 32', async () => {
  AC.ClashApiService.reset();
  ALC.LatencyLiveView.clearAll();
  const perRequest = 250;
  AC.ClashApiService.handler = async () => {
    await sleep(perRequest);
    return AC.probeResult(120, '', 200);
  };
  const t0 = Date.now();
  const run = A.LatencyEngine.start(new AC.ClashApiService(), nodes(40), URL_, opts());
  const p = await run.run();
  const elapsed = Date.now() - t0;
  A.LatencyEngine.release(run);
  ok(AC.ClashApiService.maxInflight <= 32,
    `峰值在途必须 ≤ 32（实得 ${AC.ClashApiService.maxInflight}）`);
  ok(AC.ClashApiService.maxInflight >= 2,
    `必须真的并行（峰值 ${AC.ClashApiService.maxInflight}）`);
  console.log(`  · 峰值在途请求数 = ${AC.ClashApiService.maxInflight}（上限 8）`);
  // 40 节点 / 8 路在途 = 5 波 × 250ms ≈ 1.25s（余量给调度抖动）
  ok(elapsed < 3000,
    `在途 8 应把 40 节点压成 5 波（<3s），实得 ${elapsed}ms`);
  eq(p.measured, 40, '全部测出');
  eq(p.failed, 0, '无失败');
  eq(p.queueTimeout, 0, '排队上限 60s，5 波排队不该被判排队超时');
});

// ── A4. 排队等待不计入单请求网络超时 ─────────────────────────────────────
await checkAsync('排队等待不计入请求超时：排队后发起的请求仍拿到完整预算', async () => {
  AC.ClashApiService.reset();
  ALC.LatencyLiveView.clearAll();
  const perRequest = 250;
  AC.ClashApiService.handler = async () => {
    await sleep(perRequest);
    return AC.probeResult(120, '', 200);
  };
  const t0 = Date.now();
  // 在途数 = 8 后，40 节点就会压出排队（40 > 8）；这里用 70 节点刻意压出 9 波排队，
  // 确认「排队等待没有被算进任何单个请求的 5000ms 预算」（闸门等待发生在预算之外）。
  const run = A.LatencyEngine.start(new AC.ClashApiService(), nodes(70), URL_, opts());
  const p = await run.run();
  A.LatencyEngine.release(run);
  const calls = AC.ClashApiService.calls;
  ok(calls.length === 70, '每节点一次探测');
  const queued = calls.filter((c) => c.start - t0 > 200);
  ok(queued.length > 0, '本轮必须真的发生过排队（否则这条断言没有意义）');
  for (const c of calls) {
    eq(c.timeoutMs, 5000, '每个请求的预算都必须是完整的 5000ms（排队不许扣预算）');
    ok(c.end - c.start < 5000,
      `单请求实际耗时必须 < 预算（${c.end - c.start}ms）——排队没被算进超时`);
  }
  eq(p.measured, 70, '排队中的节点最终都测出了结果（没有被排队拖死）');
  eq(p.timeout, 0, '没有节点因为排队而被判超时');
});

// ── A5. 排队超时 = 节点级「排队超时」，绝不是 CORE_NOT_READY ─────────────
await checkAsync('排队超时：节点被标为排队超时（queue_timeout），不是内核不可用', async () => {
  BC.ClashApiService.reset();
  BLC.LatencyLiveView.clearAll();
  // B 组在途数被收窄到 32（见 stageEngine(dirB, 300, 32)）：32 个在途占满 1.2s，
  // 其余节点只能排队；排队上限 300ms → 必然超时。节点数必须 > 在途数才可能排队。
  const TOTAL = 40;
  BC.ClashApiService.handler = async () => {
    await sleep(1200);
    return BC.probeResult(120, '', 200);
  };
  const run = B.LatencyEngine.start(new BC.ClashApiService(), nodes(TOTAL), URL_, opts());
  const p = await run.run();
  B.LatencyEngine.release(run);
  ok(BC.ClashApiService.calls.length <= 32,
    `名额满时不得再发请求（实发 ${BC.ClashApiService.calls.length}）`);
  ok(p.queueTimeout > 0, `必须有节点被判排队超时（实得 ${p.queueTimeout}）`);
  eq(p.queueTimeout, TOTAL - BC.ClashApiService.calls.length, '排队超时的节点数');
  eq(p.coreNotReady, 0, '排队超时绝不能计入「通道不可用」');
  eq(p.coreUnavailable, false, '排队超时绝不能作废整批');
  for (const n of nodes(TOTAL)) {
    const rec = BLC.LatencyLiveView.recordFor(n.name);
    if (rec === null) continue;
    ok(rec.failKind !== 'core_not_ready', '不得出现 core_not_ready 的节点结论');
    if (rec.failKind === 'queue_timeout') {
      eq(rec.state, ALState.LatencyState.TIMEOUT, '排队超时的状态档位');
    }
  }
  // ⚠ 排队超时是**非判定**分类（内核判定表 isVerdictKind）：这一轮根本没拨号，
  //   与节点/出口无关 ⇒ **不落节点结论**（沿用该节点上一次的有效结论）。
  const qt = [];
  for (const n of nodes(TOTAL)) {
    const rec = BLC.LatencyLiveView.recordFor(n.name);
    if (rec !== null && rec.failKind === 'queue_timeout') qt.push(n.name);
  }
  eq(qt.length, 0, '排队超时不得落成节点结论（非判定）');
});

// ── A6. 过载鉴别：controller 还活着 ⇒ 2300028 只算过载，严禁作废整批 ────────
// 2026-10-21 真机根因（飞鸟云 31 节点批）：50 路在途把 controller 打满 ⇒ 一批客户端超时
// （code=2300028）被 classify 归成 core_not_ready ⇒ 6 连击作废整批 ⇒ 后 24 个节点**一次
// /delay 都没发**。契约：controller 仍能答 /version ⇒ 这是**过载**，必须把剩下的节点测完。
await checkAsync('controller 仍能应答时，core_not_ready 过载不得作废整批、不得中途停测', async () => {
  AC.ClashApiService.reset();
  ALC.LatencyLiveView.clearAll();
  AC.ClashApiService.controllerAlive = true;
  AC.ClashApiService.handler = async () => AC.probeResult(-1, 'core_not_ready', 0);
  const TOTAL = 20;
  const run = A.LatencyEngine.start(new AC.ClashApiService(), nodes(TOTAL), URL_, opts());
  const p = await run.run();
  A.LatencyEngine.release(run);
  eq(p.coreUnavailable, false, 'controller 活着 = 过载，绝不能作废整批');
  eq(p.coreNotReady, 0, '过载不得计入「通道不可用」连击');
  ok(p.coreOverloaded > 0, `过载次数必须留痕（got ${p.coreOverloaded}）`);
  ok(AC.ClashApiService.probeCalls > 0, '鉴别必须靠真实健康检查（probeController）');
  const attempted = new Set(AC.ClashApiService.calls.map((c) => c.name));
  eq(attempted.size, TOTAL, '每个节点都必须真的发起过探测（不许测到一半停测）');
  eq(p.finished, TOTAL, '整批必须跑完（finished=total），不许中途停测');
  eq(p.timeout, 0, '过载绝不补「超时」章（真机缺陷：未测的 24 个节点被误标超时）');
  for (const n of nodes(TOTAL)) {
    // 收尾会把这些留过 TESTING 的节点收回「未测」（LatencyRecord.untested），
    // 这是**非判定**占位：档位必须是 UNTESTED、且不得带任何 failKind。
    eq(ALC.LatencyLiveView.stateFor(n.name), ALState.LatencyState.UNTESTED,
      `${n.name} 过载后必须保持未测（不得写成超时/失败）`);
    const rec = ALC.LatencyLiveView.recordFor(n.name);
    if (rec !== null) {
      eq(rec.failKind, '', `${n.name} 不得落任何判定分类（过载是非判定）`);
      eq(rec.state, ALState.LatencyState.UNTESTED, `${n.name} 记录档位必须是未测`);
    }
  }
});

// ── A7. 通道真的没了（健康检查也失败）⇒ 原语义保留：仍作废整批 ──────────────
await checkAsync('controller 不答时，core_not_ready 连击仍作废整批（通道真的没了）', async () => {
  AC.ClashApiService.reset();
  ALC.LatencyLiveView.clearAll();
  AC.ClashApiService.controllerAlive = false;
  AC.ClashApiService.handler = async () => AC.probeResult(-1, 'core_not_ready', 0);
  const TOTAL = 30;
  const run = A.LatencyEngine.start(new AC.ClashApiService(), nodes(TOTAL), URL_, opts());
  const p = await run.run();
  A.LatencyEngine.release(run);
  eq(p.coreUnavailable, true, '连不上 controller = 通道不可用 ⇒ 作废整批（原语义保留）');
  eq(p.coreOverloaded, 0, '健康检查失败时不得被当成过载');
  ok(p.coreNotReady >= 6, `应累计到连击阈值（got ${p.coreNotReady}）`);
  // ⚠ 不能用「节点名是否出现在 calls 里」判早停：worker 数 = LATENCY_CONCURRENCY(50)，
  //   它们会先占住节点（TESTING）再到在途闸门上排队；闸门放行的快速失败请求会在
  //   500ms 退避窗口内轮到几乎每个节点 ⇒ 名字覆盖全 ≠ 跑完整批。
  //   早停的真实证据是**进度计数**（与 verify-latency-engine-runtime 的作废用例同构）：
  //   跑完的节点远少于总数，且排队/在途中的探测被撤销（每节点要先耗尽 500ms 退避才计连击）。
  ok(p.finished < TOTAL, `作废后只应有少数节点跑完（finished=${p.finished}/${TOTAL}）`);
  ok(p.cancelled > 0, `作废必须撤销排队/在途中的探测（cancelled=${p.cancelled}）`);
  let abortedFailed = 0;
  let abortedTesting = 0;
  for (let i = 0; i < TOTAL; i++) {
    const st = ALC.LatencyLiveView.stateFor('node-' + i);
    if (st === ALState.LatencyState.FAILED) abortedFailed++;
    if (st === ALState.LatencyState.TESTING) abortedTesting++;
  }
  eq(abortedFailed, 0, '通道故障绝不得写成节点失败');
  eq(abortedTesting, 0, '不得留下永久转圈的 TESTING 节点');
});

// ── B 组：真实 ClashApiService 的组测分类 ─────────────────────────────────
const dirC = path.join(root, 'c');
fs.mkdirSync(dirC, { recursive: true });
writeDeps(dirC);
w(dirC, 'fakeHttp.ts', `
export const RequestMethod = { GET: 0, POST: 1, PUT: 2, DELETE: 3 };
export class FakeRequest {
  async request(url, options) {
    return await globalThis.__fakeHttp__(url, options);
  }
  destroy() {}
}
export function createHttp() { return new FakeRequest(); }
export const http = { createHttp: createHttp, RequestMethod: RequestMethod };
`);
w(dirC, 'fakeUtil.ts', `
export const util = {
  TextDecoder: {
    create: (_enc) => ({
      decodeToString: (u8) => Buffer.from(u8).toString('utf8')
    })
  }
};
`);
// 真实 ClashApiService 现在把探测**委托给测速内核**（commons/latency/LatencyProbe.ets）
// ⇒ 沙箱里必须一并暂存内核（+ 它的零 import 依赖 LatencyTestUrl + AppSettings 桩）
w(dirC, 'LatencyTestUrl.ts',
  fs.readFileSync(path.join(latency, 'LatencyTestUrl.ets'), 'utf8'));
w(dirC, 'AppSettings.ts', `
export class AppSettings {
  testLatencyUrl: string = 'https://www.gstatic.com/generate_204';
}
`);
w(dirC, 'LatencyDnsVerdict.ts',
  fs.readFileSync(path.join(latency, 'LatencyDnsVerdict.ets'), 'utf8')
    .replace(/from '(\.[A-Za-z0-9_/]+)'/g, "from '$1.ts'"));
w(dirC, 'LatencyKinds.ts',
  fs.readFileSync(path.join(latency, 'LatencyKinds.ets'), 'utf8'));
w(dirC, 'LatencyProbe.ts',
  fs.readFileSync(path.join(latency, 'LatencyProbe.ets'), 'utf8')
    .replace(/from '@kit\.NetworkKit'/g, "from './fakeHttp.ts'")
    .replace(/from '@kit\.ArkTS'/g, "from './fakeUtil.ts'")
    .replace(/from '\.\.\/utils\/AppLogger'/g, "from './AppLogger.ts'")
    .replace(/from '\.\.\/models\/AppSettings'/g, "from './AppSettings.ts'")
    .replace(/from '\.\/LatencyTestUrl'/g, "from './LatencyTestUrl.ts'")
    .replace(/from '\.\/LatencyDnsVerdict'/g, "from './LatencyDnsVerdict.ts'")
    .replace(/from '\.\/LatencyKinds'/g, "from './LatencyKinds.ts'"));
let apiSrc = fs.readFileSync(path.join(svc, 'ClashApiService.ets'), 'utf8');
apiSrc = apiSrc
  .replace(/from '@kit\.NetworkKit'/g, "from './fakeHttp.ts'")
  .replace(/from '@kit\.ArkTS'/g, "from './fakeUtil.ts'")
  .replace(/from '\.\.\/utils\/AppLogger'/g, "from './AppLogger.ts'")
  .replace(/from '\.\/LatencyState'/g, "from './LatencyState.ts'")
  .replace(/from '\.\.\/latency\/LatencyProbe'/g, "from './LatencyProbe.ts'")
  .replace(/from '\.\.\/latency\/LatencyDnsVerdict'/g, "from './LatencyDnsVerdict.ts'")
  .replace(/from '\.\.\/latency\/LatencyKinds'/g, "from './LatencyKinds.ts'")
  // `LatencyHttpTransport` 是 **interface**（纯类型）=> Node 的 type-stripping 会把它抹掉，
  // 但 import 语句还在 => ESM 具名导入直接报错。暂存副本里去掉这个**纯类型**导入。
  .replace(/\n\s*LatencyHttpTransport,?/, '');
ok(!/@kit\./.test(apiSrc), 'staged ClashApiService 不得残留 @kit 导入');
w(dirC, 'ClashApiService.ts', apiSrc);

const C = await import(pathToFileURL(path.join(dirC, 'ClashApiService.ts')).href);
const { ClashApiService: RealApi } = C;
const { LatencyProbeKind: RealKind } =
  await import(pathToFileURL(path.join(dirC, 'LatencyKinds.ts')).href);
let lastUrl = '';
function fakeHttp(status, body) {
  globalThis.__fakeHttp__ = async (url) => {
    lastUrl = url;
    if (status === 'throw') throw new Error('connect refused');
    return { responseCode: status, result: body };
  };
}

await checkAsync('组测 504（全部成员超时）= 通道正常、节点全不通，不是内核不可用', async () => {
  fakeHttp(504, 'get delay: all proxies timeout');
  const res = await new RealApi().testGroupDetailedResult('PROXY', URL_, 5000);
  eq(res.httpCode, 504, 'httpCode');
  eq(res.allTimedOut, true, '504 必须标 allTimedOut');
  eq(res.failKind, RealKind.TIMEOUT, '504 的分类是 TIMEOUT');
  ok(res.failKind !== RealKind.CORE_NOT_READY, '504 绝不能是 CORE_NOT_READY');
  eq(res.ok, false, '504 不是「有可用响应」');
  eq(res.delays.size, 0, '504 没有成功节点');
  ok(lastUrl.includes('/group/PROXY/delay?url='), `请求路径必须是 /group/{name}/delay（实得 ${lastUrl}）`);
  ok(lastUrl.includes('&timeout=5000'), '请求必须带 timeout 参数');
});

await checkAsync('组测 401（secret 错配）= CORE_NOT_READY', async () => {
  fakeHttp(401, 'unauthorized');
  const res = await new RealApi().testGroupDetailedResult('PROXY', URL_, 5000);
  eq(res.httpCode, 401, 'httpCode');
  eq(res.failKind, RealKind.CORE_NOT_READY, '401 的分类');
  eq(res.allTimedOut, false, '401 不是全部超时');
  eq(res.ok, false, '401 没有可用响应');
});

await checkAsync('组测 404（组不存在）= SWITCH_FAILED', async () => {
  fakeHttp(404, 'not found');
  const res = await new RealApi().testGroupDetailedResult('NOPE', URL_, 5000);
  eq(res.httpCode, 404, 'httpCode');
  eq(res.failKind, RealKind.SWITCH_FAILED, '404 的分类');
  eq(res.allTimedOut, false, '404 不是全部超时');
});

await checkAsync('组测 503 = TIMEOUT（单节点拨号失败语义）', async () => {
  fakeHttp(503, 'service unavailable');
  const res = await new RealApi().testGroupDetailedResult('PROXY', URL_, 5000);
  eq(res.httpCode, 503, 'httpCode');
  eq(res.failKind, RealKind.TIMEOUT, '503 的分类');
  eq(res.allTimedOut, false, '503 不是「全部成员超时」');
});

await checkAsync('组测传输异常（本机没拿到响应）= CORE_NOT_READY', async () => {
  fakeHttp('throw', '');
  const res = await new RealApi().testGroupDetailedResult('PROXY', URL_, 5000);
  eq(res.httpCode, 0, '传输异常没有 httpCode');
  eq(res.failKind, RealKind.CORE_NOT_READY, '传输异常的分类');
  eq(res.allTimedOut, false, '传输异常不是全部超时');
  eq(res.ok, false, '传输异常没有可用响应');
});

await checkAsync('组测 200：ok=true，delays 只含 delay>0 的成员', async () => {
  fakeHttp(200, JSON.stringify({ 'node-a': 120, 'node-b': 0, 'node-c': 45 }));
  const res = await new RealApi().testGroupDetailedResult('PROXY', URL_, 5000);
  eq(res.httpCode, 200, 'httpCode');
  eq(res.ok, true, '200 = 有可用响应');
  eq(res.failKind, '', '200 没有失败分类');
  eq(res.allTimedOut, false, '200 不是全部超时');
  eq(res.delays.size, 2, '只收 delay>0 的成员');
  eq(res.delays.get('node-a'), 120, 'node-a 延迟');
  eq(res.delays.get('node-c'), 45, 'node-c 延迟');
  eq(res.delays.get('node-b'), undefined, 'node-b（delay=0）必须被过滤');
});

// ⚠ 旧兼容口已删除（审计 LP02 / LP03）：`testGroupDetailed`（任何非 200 ⇒ null）
//   与 `testLatency`（失败 ⇒ -1）会把「节点全不通（504）」和「内核不可用（401）」
//   压成同一个 null/-1 ⇒ 调用方无法区分通道级与节点级故障。
//   唯一入口是 `testGroupDetailedResult`（带分类）与 `testLatencyDetailed`（内核探针）。
await checkAsync('旧兼容口已删除：testGroupDetailed / testLatency 不再存在', () => {
  const api = new RealApi();
  eq(typeof api.testGroupDetailed, 'undefined', 'testGroupDetailed 必须已删除（LP02）');
  eq(typeof api.testLatency, 'undefined', 'testLatency 必须已删除（LP03）');
  eq(typeof api.testGroupDetailedResult, 'function', '结构化组测入口必须保留');
  eq(typeof api.testLatencyDetailed, 'function', '内核探针入口必须保留');
});

console.log('');
if (failed === 0) {
  console.log(`Latency concurrency verification: ${passed} passed, 0 failed.`);
  process.exit(0);
}
console.log(`Latency concurrency verification: ${passed} passed, ${failed} failed.`);
for (const f of failures) console.log(`  - ${f}`);
process.exit(1);
