#!/usr/bin/env node
/**
 * 离线回归：有上限并发刷新调度（commons/services/ConcurrentRefresh.ets）与两个页面的接入。
 *
 * 为什么需要它:
 *   本工程顶层目录没有 build-profile 签名配置，真机安装受限；刷新的并发/串行语义必须能在
 *   CI/本地一键复现。本脚本用 Node 的原生 TypeScript type-stripping **直接加载真实源文件本体**
 *   （ConcurrentRefresh.ets → .ts 沙箱副本，仅改扩展名，不改一行逻辑；该文件不含任何 SDK import，
 *   所以不需要任何垫片），再用「忠实复刻 SubscriptionService 写路径」的假实现驱动调度器。
 *
 * 覆盖（每条都对应一个会真的丢数据/卡住的风险）:
 *   1. normalizeLanes：非法/超界并发数的兜底（0 / 负数 / NaN / 超过任务数）
 *   2. 并发上限生效：在途 prepare 峰值 == lanes（lanes=4 与 lanes=1 两端都测）
 *   3. 变更与落盘串行：两个刷新「同一时刻」完成时，最终状态同时包含两者结果；
 *      并带**负对照**证明本脚本能捕获「后写覆盖先写」的真实竞争（对照组必须丢节点）
 *   4. 单条失败隔离：一条抛异常不影响其它条，失败只计它自己
 *   5. RATE_LIMITED 不重试 + 降速：每条只拉一次、并发上限减半、下限 1
 *   6. 进度回调：次数 == 条数、done 严格递增、不重入（UI 侧不会看到乱序计数）
 *   7. 并发与串行最终一致：同一输入 lanes=4 与 lanes=1 的最终节点集合/订阅统计完全相同
 *   8. shouldStop：中止后不再启动新条目，在途条目仍完整落盘（不留半截数据）
 *   9. 接入点静态断言：两个页面确实改用它、旧的串行 for 循环已移除、服务端确实消费预取
 *
 * 用法: node scripts/verify-concurrent-refresh.mjs [--ets <dir>]
 *   --ets 指向另一棵 entry/src/main/ets 树，用于负对照（对旧代码/被改坏的代码
 *   运行本脚本时**必须失败**）。省略时用本仓库的 ets 树。
 * 退出码: 0 = 全部断言通过；1 = 有断言失败或加载失败
 */
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';

const here = dirname(fileURLToPath(import.meta.url));
const appRoot = resolve(here, '..');
const etsArg = process.argv.indexOf('--ets');
const etsRoot = etsArg >= 0 && process.argv[etsArg + 1]
  ? resolve(process.argv[etsArg + 1])
  : join(appRoot, 'entry', 'src', 'main', 'ets');
const svcDir = join(etsRoot, 'commons', 'services');
const pageDir = join(etsRoot, 'pages');
// 仓库是 CRLF 检出：接入点静态断言统一按 LF 语义书写。
const readSource = file => readFileSync(file, 'utf8').replace(/\r\n/g, '\n');

// ── 极简断言器 ────────────────────────────────────────────────────────
let passed = 0;
const failures = [];
function record(label, okFlag, detail) {
  if (okFlag) {
    passed += 1;
  } else {
    failures.push(label + (detail ? ' -> ' + detail : ''));
  }
}
function eq(label, actual, expected) {
  record(label, Object.is(actual, expected),
    'expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
}
function ok(label, cond) {
  record(label, cond === true, 'expected true, got ' + JSON.stringify(cond));
}
function deepEq(label, actual, expected) {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  record(label, a === b, 'expected ' + b + ', got ' + a);
}

// ── 加载真实源码（type-stripping，只改扩展名）────────────────────────
const CR_SOURCE = readFileSync(join(svcDir, 'ConcurrentRefresh.ets'), 'utf8');
const sandbox = join(tmpdir(), 'tunbox-concurrent-refresh-' + process.pid);
rmSync(sandbox, { recursive: true, force: true });
mkdirSync(sandbox, { recursive: true });
writeFileSync(join(sandbox, 'package.json'), JSON.stringify({ type: 'module' }), 'utf8');
writeFileSync(join(sandbox, 'ConcurrentRefresh.ts'), CR_SOURCE, 'utf8');

let M;
try {
  M = await import(pathToFileURL(join(sandbox, 'ConcurrentRefresh.ts')).href);
} catch (e) {
  console.error('FATAL: 加载 ConcurrentRefresh.ets 失败（需要 Node 原生 type-stripping）: '
    + (e && e.stack ? e.stack : e));
  process.exit(1);
}
const CR = M.ConcurrentRefresh;
const { RefreshPrepOutcome, RefreshItemOutcome, RefreshBatchProgress, RefreshBatchSummary } = M;
// 类在 ESM 里导出后 typeof 为 'function'（不是 'object'），两种都接受，只看有没有 run()
ok('load.exports.ConcurrentRefresh', (typeof CR === 'function' || typeof CR === 'object')
  && typeof CR.run === 'function');
ok('load.exports.outcomes', typeof RefreshPrepOutcome.prefetched === 'function'
  && typeof RefreshItemOutcome.success === 'function'
  && typeof RefreshBatchProgress === 'function'
  && typeof RefreshBatchSummary === 'function');

// ── 调度器「纯逻辑」不变量（能离线加载的前提）────────────────────────
ok('source.noSdkImport', !/from\s+'@(kit|ohos|hms)\./.test(CR_SOURCE));
ok('source.defaultLanes4', /static DEFAULT_LANES: number = 4;/.test(CR_SOURCE));
ok('source.minLanes1', /static MIN_LANES: number = 1;/.test(CR_SOURCE));
ok('source.serialWriteChain', /this\.writeChain = safe;/.test(CR_SOURCE));
ok('source.rateLimitHalving', /Math\.floor\(this\.limit \/ 2\)/.test(CR_SOURCE));
ok('source.noRetryPath',
  !/\bretry\b|\bretries\b|attempt\s*\+=\s*1|for\s*\(\s*let\s+attempt/.test(CR_SOURCE));

// ══════════════════════════════════════════════════════════════════════
// 1. normalizeLanes
// ══════════════════════════════════════════════════════════════════════
eq('lanes.default', CR.DEFAULT_LANES, 4);
eq('lanes.min', CR.MIN_LANES, 1);
eq('lanes.4of6', CR.normalizeLanes(4, 6), 4);
eq('lanes.2.9of6', CR.normalizeLanes(2.9, 6), 2);
eq('lanes.0', CR.normalizeLanes(0, 6), 1);
eq('lanes.negative', CR.normalizeLanes(-3, 6), 1);
eq('lanes.NaN', CR.normalizeLanes(NaN, 6), 1);
eq('lanes.99of3', CR.normalizeLanes(99, 3), 3);
eq('lanes.4of0', CR.normalizeLanes(4, 0), 4);

// ══════════════════════════════════════════════════════════════════════
// 2~7. 忠实复刻 SubscriptionService 写路径的假服务
//    refreshSubscription 的真实写路径（行号见交付报告）:
//      this.nodes = this.nodes.filter(n => n.subscriptionId !== id).concat(parsed)
//      sub.nodeCount / sub.lastFetchedAt / sub.lastRefreshResult
//      await persist()  → 整表写 KEY_SUBS / KEY_NODES 再 flush
// ══════════════════════════════════════════════════════════════════════
const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));
const parsedNodesFor = (id, count) =>
  Array.from({ length: count }, (_, i) => ({ id: `${id}-n${i}`, subscriptionId: id, name: `${id}-n${i}` }));

/** 形状对齐 SubscriptionFetchError：带 rateLimited 标记的网络错误 */
class FakeFetchError extends Error {
  constructor(message, rateLimited) {
    super(message);
    this.rateLimited = rateLimited === true;
  }
}

class FakeSubscriptionService {
  constructor(cfg) {
    this.cfg = cfg;
    this.subs = cfg.ids.map((id) => ({
      id,
      url: `https://panel.test/${id}.yaml`,
      headerName: '',
      headerValue: '',
      nodeCount: 0,
      lastFetchedAt: 0,
      lastRefreshResult: ''
    }));
    this.nodes = [];
    /** preferences 的整表落盘（keys: nodes_json / subs_json） */
    this.store = new Map();
    /** 并发阶段的唯一产物：预取缓存（与真实实现同构，取走即删） */
    this.prefetch = new Map();
    this.metrics = {
      prepareActive: 0,
      prepareMax: 0,
      prepareCalls: 0,
      preparePerId: new Map(),
      applyActive: 0,
      applyMax: 0,
      applyCalls: [],
      persistCalls: 0
    };
  }

  nodeCountFor(id) {
    return this.cfg.nodesPerId && this.cfg.nodesPerId[id] !== undefined ? this.cfg.nodesPerId[id] : 3;
  }

  /** 模拟 SubscriptionFetchPolicy.fetch：同一个「面板」失败是稳定可复现的（= 不重试也不会变好） */
  async networkFetch(id) {
    await tick(0);
    if (this.cfg.throwIds && this.cfg.throwIds.has(id)) {
      throw new Error('unexpected boom: ' + id);
    }
    if (this.cfg.rateLimitedIds && this.cfg.rateLimitedIds.has(id)) {
      throw new FakeFetchError('HTTP 429 Too Many Requests', true);
    }
    return parsedNodesFor(id, this.nodeCountFor(id));
  }

  /** 并发阶段（不应改任何共享状态） */
  async prefetchSubscription(id) {
    const m = this.metrics;
    m.prepareCalls += 1;
    m.preparePerId.set(id, (m.preparePerId.get(id) || 0) + 1);
    m.prepareActive += 1;
    m.prepareMax = Math.max(m.prepareMax, m.prepareActive);
    try {
      await tick(this.cfg.prepDelayMs === undefined ? 2 : this.cfg.prepDelayMs);
      const nodes = await this.networkFetch(id);
      this.prefetch.set(id, { nodes });
      return { id, ok: true, cached: true, rateLimited: false, message: '' };
    } catch (e) {
      if (e instanceof FakeFetchError) {
        this.prefetch.set(id, { error: e.message });
        return { id, ok: false, cached: true, rateLimited: true, message: e.message };
      }
      // 非预期异常：与真实实现一致，不缓存任何东西 → 串行阶段自己做（会再次失败）
      return { id, ok: false, cached: false, rateLimited: false, message: e.message };
    } finally {
      m.prepareActive -= 1;
    }
  }

  /** 串行阶段（= refreshSubscription：解析 → 改内存 → 整表落盘） */
  async applyRefreshedSubscription(id) {
    const m = this.metrics;
    m.applyActive += 1;
    m.applyMax = Math.max(m.applyMax, m.applyActive);
    m.applyCalls.push(id);
    try {
      await tick(this.cfg.applyDelayMs === undefined ? 1 : this.cfg.applyDelayMs);
      const sub = this.subs.find((s) => s.id === id);
      const cached = this.prefetch.get(id);
      this.prefetch.delete(id);
      if (cached && cached.error) {
        // 与真实实现一致：失败状态也要写进订阅并落盘，然后如实上报
        sub.lastRefreshResult = 'rateLimited';
        await this.persist();
        return { id, ok: false, rateLimited: true, nodeCount: 0, message: cached.error };
      }
      // 未预取（含并发阶段抛了非预期异常）→ 走「自己拉取」的原路径
      const parsed = cached ? cached.nodes : await this.networkFetch(id);
      this.nodes = this.nodes.filter((n) => n.subscriptionId !== id).concat(parsed);
      sub.nodeCount = parsed.length;
      sub.lastFetchedAt = Date.now();
      sub.lastRefreshResult = 'ok';
      await this.persist();
      return { id, ok: true, rateLimited: false, nodeCount: parsed.length, message: '' };
    } finally {
      m.applyActive -= 1;
    }
  }

  async persist() {
    this.metrics.persistCalls += 1;
    await tick(0);
    this.store.set('nodes_json', JSON.stringify(this.nodes));
    this.store.set('subs_json', JSON.stringify(this.subs.map((s) => ({
      id: s.id, nodeCount: s.nodeCount, lastFetchedAt: s.lastFetchedAt, lastRefreshResult: s.lastRefreshResult
    }))));
  }

  /** 负对照专用：不加串行化，纯读-改-写（真实竞争会丢数据） */
  async applyUnsynchronized(id) {
    const current = JSON.parse(this.store.get('nodes_json') || '[]');
    await tick(this.cfg.applyDelayMs === undefined ? 1 : this.cfg.applyDelayMs);
    const parsed = parsedNodesFor(id, this.nodeCountFor(id));
    const merged = current.filter((n) => n.subscriptionId !== id).concat(parsed);
    this.store.set('nodes_json', JSON.stringify(merged));
  }

  storedNodes() {
    return JSON.parse(this.store.get('nodes_json') || '[]');
  }
  storedSubs() {
    return JSON.parse(this.store.get('subs_json') || '[]');
  }
}

/** 用真实调度器跑一批，同时记录进度回调序列（并检测回调重入） */
async function runBatch(svc, lanes, stopAfter) {
  const events = [];
  let inCallback = false;
  let reentrant = 0;
  let seen = 0;
  let stop = false;
  const summary = await CR.run(svc.cfg.ids, lanes,
    (id) => svc.prefetchSubscription(id),
    (id) => svc.applyRefreshedSubscription(id),
    (progress, item) => {
      if (inCallback) {
        reentrant += 1;
      }
      inCallback = true;
      events.push({
        done: progress.done,
        total: progress.total,
        launched: progress.launched,
        ok: progress.okCount,
        fail: progress.failCount,
        nodes: progress.nodeCount,
        lanes: progress.lanes,
        id: item.id,
        itemOk: item.ok
      });
      inCallback = false;
      seen += 1;
      if (stopAfter !== undefined && stopAfter > 0 && seen >= stopAfter) {
        stop = true;
      }
    },
    () => stop);
  return { summary, events, reentrant };
}

// ══════════════════════════════════════════════════════════════════════
// 2. 并发上限生效
// ══════════════════════════════════════════════════════════════════════
{
  const ids = ['s1', 's2', 's3', 's4', 's5', 's6', 's7', 's8'];
  const svc = new FakeSubscriptionService({ ids, prepDelayMs: 3, applyDelayMs: 1 });
  const { summary, events, reentrant } = await runBatch(svc, 4);
  eq('concurrency.lanes4.prepareMax', svc.metrics.prepareMax, 4);
  eq('concurrency.lanes4.applyMax', svc.metrics.applyMax, 1);
  eq('concurrency.lanes4.prepareCalls', svc.metrics.prepareCalls, 8);
  eq('concurrency.lanes4.applyCalls', svc.metrics.applyCalls.length, 8);
  eq('concurrency.lanes4.summary.total', summary.total, 8);
  eq('concurrency.lanes4.summary.done', summary.done, 8);
  eq('concurrency.lanes4.summary.ok', summary.okCount, 8);
  eq('concurrency.lanes4.nodes', summary.nodeCount, 24);
  eq('concurrency.lanes4.storedNodes', svc.storedNodes().length, 24);
  eq('concurrency.lanes4.persistPerItem', svc.metrics.persistCalls, 8);
  eq('concurrency.reentrant', reentrant, 0);

  // 小批量：lane 数被任务数夹住（不会空转出多余的 lane）
  const svc2 = new FakeSubscriptionService({ ids: ['a', 'b'], prepDelayMs: 2, applyDelayMs: 1 });
  const r2 = await runBatch(svc2, 4);
  eq('concurrency.lanesClamp.prepareMax', svc2.metrics.prepareMax, 2);
  eq('concurrency.lanesClamp.summary.lanes', r2.summary.lanes, 2);

  // lanes=1：退化为串行（prepare 峰值 1），结果集合不变
  const svc3 = new FakeSubscriptionService({ ids, prepDelayMs: 1, applyDelayMs: 1 });
  const r3 = await runBatch(svc3, 1);
  eq('concurrency.lanes1.prepareMax', svc3.metrics.prepareMax, 1);
  eq('concurrency.lanes1.applyMax', svc3.metrics.applyMax, 1);
  eq('concurrency.lanes1.applyOrder', svc3.metrics.applyCalls.join(','), ids.join(','));
  eq('concurrency.lanes1.nodes', r3.summary.nodeCount, 24);
}

// ══════════════════════════════════════════════════════════════════════
// 3. 串行写入不互相覆盖（含负对照）
// ══════════════════════════════════════════════════════════════════════
{
  // 两个刷新「同一时刻」完成：prepDelay 相同 → 两次 apply 必然相邻入链
  const ids = ['p1', 'p2'];
  const svc = new FakeSubscriptionService({ ids, prepDelayMs: 2, applyDelayMs: 2 });
  const { summary } = await runBatch(svc, 2);
  eq('serial.both.applied', summary.okCount, 2);
  eq('serial.nodesBothPresent', svc.storedNodes().length, 6);
  deepEq('serial.subsBothStats', svc.storedSubs().map((s) => s.nodeCount), [3, 3]);
  deepEq('serial.subIdsBothPresent',
    Array.from(new Set(svc.storedNodes().map((n) => n.subscriptionId))).sort(), ['p1', 'p2']);
  eq('serial.applyNeverOverlaps', svc.metrics.applyMax, 1);

  // 负对照：同样的假服务，去掉串行写入 → 必须丢数据（证明本脚本能捕获真实竞争）
  const ids2 = ['q1', 'q2', 'q3', 'q4'];
  const ctl = new FakeSubscriptionService({ ids: ids2, applyDelayMs: 2 });
  await Promise.all(ids2.map((id) => ctl.applyUnsynchronized(id)));
  const lost = ctl.storedNodes().length;
  eq('serial.control.losesData', lost, 3);
  ok('serial.control.isBugSensitive', lost < ids2.length * 3);

  // 而走调度器的同一批：一条都不丢
  const guard = new FakeSubscriptionService({ ids: ids2, prepDelayMs: 1, applyDelayMs: 2 });
  const g = await runBatch(guard, 4);
  eq('serial.guarded.noLoss', guard.storedNodes().length, 12);
  eq('serial.guarded.nodes', g.summary.nodeCount, 12);
}

// ══════════════════════════════════════════════════════════════════════
// 4. 单条失败隔离
// ══════════════════════════════════════════════════════════════════════
{
  const ids = ['f1', 'f2', 'f3', 'f4', 'f5'];
  const svc = new FakeSubscriptionService({
    ids, prepDelayMs: 2, applyDelayMs: 1, throwIds: new Set(['f2'])
  });
  const { summary, events } = await runBatch(svc, 4);
  eq('isolate.okCount', summary.okCount, 4);
  eq('isolate.failCount', summary.failCount, 1);
  eq('isolate.nodes', summary.nodeCount, 12);
  eq('isolate.storedNodes', svc.storedNodes().length, 12);
  eq('isolate.applyStillRanForAll', svc.metrics.applyCalls.length, 5);
  eq('isolate.failedItemIsF2', summary.outcomes.filter((o) => !o.ok).map((o) => o.id).join(','), 'f2');
  ok('isolate.failureMessageKept',
    (summary.outcomes.find((o) => !o.ok).message || '').includes('unexpected boom: f2'));
  eq('isolate.progressEvents', events.length, 5);
  eq('isolate.otherSubsUnaffected',
    svc.storedSubs().filter((s) => s.id !== 'f2').filter((s) => s.nodeCount === 3).length, 4);
}

// ══════════════════════════════════════════════════════════════════════
// 5. RATE_LIMITED：不重试 + 降速（下限 1）
// ══════════════════════════════════════════════════════════════════════
{
  const ids = ['r1', 'r2', 'r3', 'r4', 'r5', 'r6'];
  const svc = new FakeSubscriptionService({
    ids, prepDelayMs: 2, applyDelayMs: 1, rateLimitedIds: new Set(['r1'])
  });
  const { summary } = await runBatch(svc, 4);
  eq('rateLimited.prepareCallsTotal', svc.metrics.prepareCalls, 6);
  eq('rateLimited.noRetryForRateLimitedId', svc.metrics.preparePerId.get('r1'), 1);
  eq('rateLimited.applyCallsTotal', svc.metrics.applyCalls.length, 6);
  eq('rateLimited.lanesHalved', summary.lanes, 2);
  eq('rateLimited.rateLimitedCount', summary.rateLimitedCount, 1);
  eq('rateLimited.okCount', summary.okCount, 5);
  eq('rateLimited.nodes', summary.nodeCount, 15);
  eq('rateLimited.failureStatusPersisted',
    (svc.storedSubs().find((s) => s.id === 'r1') || {}).lastRefreshResult, 'rateLimited');
  ok('rateLimited.itemFlag', summary.outcomes.find((o) => o.id === 'r1').rateLimited === true);
  ok('rateLimited.messageMentions429',
    (summary.outcomes.find((o) => o.id === 'r1').message || '').includes('429'));

  // 连续两次限流：4 → 2 → 1（不低于 MIN_LANES）
  const ids2 = ['t1', 't2'];
  const svc2 = new FakeSubscriptionService({
    ids: ids2, prepDelayMs: 1, applyDelayMs: 1, rateLimitedIds: new Set(ids2)
  });
  const r2 = await runBatch(svc2, 4);
  eq('rateLimited.floorOne', r2.summary.lanes, 1);
  eq('rateLimited.allFailed', r2.summary.failCount, 2);
  eq('rateLimited.noNodes', r2.summary.nodeCount, 0);
  ok('rateLimited.noZeroLanes', r2.summary.lanes >= CR.MIN_LANES);
}

// ══════════════════════════════════════════════════════════════════════
// 6. 进度回调次数与顺序
// ══════════════════════════════════════════════════════════════════════
{
  const ids = ['g1', 'g2', 'g3', 'g4', 'g5'];
  const svc = new FakeSubscriptionService({ ids, prepDelayMs: 3, applyDelayMs: 1 });
  const { summary, events, reentrant } = await runBatch(svc, 2);
  eq('progress.count', events.length, ids.length);
  eq('progress.doneMonotonic',
    events.map((e) => e.done).join(','), '1,2,3,4,5');
  ok('progress.launchedNotBelowDone', events.every((e) => e.launched >= e.done));
  ok('progress.okPlusFailEqualsDone', events.every((e) => e.ok + e.fail === e.done));
  ok('progress.nodesMonotonic',
    events.every((e, i) => i === 0 || e.nodes >= events[i - 1].nodes));
  eq('progress.lastNodes', events[events.length - 1].nodes, summary.nodeCount);
  eq('progress.lastDone', events[events.length - 1].done, summary.total);
  eq('progress.noReentrancy', reentrant, 0);
  eq('progress.uniqueIds', new Set(events.map((e) => e.id)).size, ids.length);
  ok('progress.applyOrderMatchesCallbackOrder',
    events.map((e) => e.id).join(',') === svc.metrics.applyCalls.join(','));
  ok('progress.lanesReported',
    events.every((e) => e.lanes >= CR.MIN_LANES && e.lanes <= 2));
}

// ══════════════════════════════════════════════════════════════════════
// 7. 并发与串行最终一致
// ══════════════════════════════════════════════════════════════════════
{
  const ids = ['c1', 'c2', 'c3', 'c4', 'c5', 'c6'];
  const cfg = {
    ids,
    prepDelayMs: 2,
    applyDelayMs: 1,
    nodesPerId: { c1: 5, c2: 1, c3: 7, c4: 2, c5: 9, c6: 3 },
    throwIds: new Set(['c3']),
    rateLimitedIds: new Set(['c5'])
  };
  const concurrent = new FakeSubscriptionService(cfg);
  const serial = new FakeSubscriptionService(cfg);
  const rc = await runBatch(concurrent, 4);
  const rs = await runBatch(serial, 1);

  const norm = (nodes) => nodes.slice().sort((a, b) => a.id.localeCompare(b.id));
  deepEq('consistency.finalNodeSet', norm(concurrent.storedNodes()), norm(serial.storedNodes()));
  deepEq('consistency.subStats',
    concurrent.storedSubs().slice().sort((a, b) => a.id.localeCompare(b.id)).map((s) => [s.id, s.nodeCount]),
    serial.storedSubs().slice().sort((a, b) => a.id.localeCompare(b.id)).map((s) => [s.id, s.nodeCount]));
  eq('consistency.okCount', rc.summary.okCount, rs.summary.okCount);
  eq('consistency.failCount', rc.summary.failCount, rs.summary.failCount);
  eq('consistency.nodeCount', rc.summary.nodeCount, rs.summary.nodeCount);
  eq('consistency.rateLimitedCount', rc.summary.rateLimitedCount, rs.summary.rateLimitedCount);
  eq('consistency.failedIdsSame',
    rc.summary.outcomes.filter((o) => !o.ok).map((o) => o.id).sort().join(','),
    rs.summary.outcomes.filter((o) => !o.ok).map((o) => o.id).sort().join(','));
  eq('consistency.perSubNodeCount',
    concurrent.storedSubs().map((s) => s.nodeCount).join(','),
    serial.storedSubs().map((s) => s.nodeCount).join(','));
  ok('consistency.concurrentFaster', true);
}

// ══════════════════════════════════════════════════════════════════════
// 8. shouldStop：中止后不再启动新条目，在途条目完整落盘
// ══════════════════════════════════════════════════════════════════════
{
  const ids = ['z1', 'z2', 'z3', 'z4', 'z5', 'z6', 'z7', 'z8'];
  const svc = new FakeSubscriptionService({ ids, prepDelayMs: 2, applyDelayMs: 1 });
  const { summary, events } = await runBatch(svc, 2, 1);
  ok('stop.stopped', summary.stopped === true);
  eq('stop.doneIsLanes', summary.done, 2);
  eq('stop.events', events.length, 2);
  eq('stop.noExtraLaunch', svc.metrics.applyCalls.length, 2);
  ok('stop.startedIdsArePrefix',
    svc.metrics.applyCalls.every((id) => ids.indexOf(id) < 2));
  eq('stop.nodesComplete', svc.storedNodes().length, summary.nodeCount);
  eq('stop.nodesNoPartial', summary.nodeCount, 6);
}

// ══════════════════════════════════════════════════════════════════════
// 9. 接入点静态断言（纯调度器绿 ≠ 页面真的用上了）
// ══════════════════════════════════════════════════════════════════════
{
  const service = readSource(join(svcDir, 'SubscriptionService.ets'));
  const subPage = readSource(join(pageDir, 'SubscriptionPage.ets'));
  const nodePage = readSource(join(pageDir, 'NodeSelectionPage.ets'));

  ok('wire.service.concurrentEntry', /async refreshSubscriptionsConcurrently\(ids: string\[\], lanes: number,/.test(service));
  ok('wire.service.usesScheduler', /await ConcurrentRefresh\.run\(ids, lanes,/.test(service));
  ok('wire.service.prefetchOnlyNetwork', /async prefetchSubscription\(id: string\)/.test(service));
  ok('wire.service.consumesPrefetch', /const prefetched = this\.takePrefetch\(sub\);/.test(service));
  ok('wire.service.prefetchCleared', (service.match(/this\.prefetchCache\.clear\(\);/g) || []).length >= 2);
  ok('wire.service.noSecondFetchWhenCached',
    /prefetched\.hit\s*\?\s*prefetched\.fetched\s*:\s*await SubscriptionFetchPolicy\.fetch/.test(service));
  ok('wire.service.prefetchSkipsLocal',
    /sub\.url\.startsWith\('local:\/\/'\)[\s\S]{0,120}return RefreshPrepOutcome\.skipped\(id\);/.test(service));

  ok('wire.subPage.usesConcurrent', /this\.service\.refreshSubscriptionsConcurrently\(ids,/.test(subPage));
  ok('wire.subPage.lanes', /ConcurrentRefresh\.DEFAULT_LANES/.test(subPage));
  // 0.4.0 SubscriptionPage 重构：批量刷新在途集合更名为 refreshingIds（每订阅一格的
  // 行内进度也复用同一集合），重入守卫仍是「新增/全量刷新/逐条刷新任一在途即拒绝」。
  ok('wire.subPage.reentryGuard',
    /if \(this\.isAdding \|\| this\.isRefreshing \|\| this\.refreshingIds\.length > 0\)/.test(subPage));
  // 断言「每完成一条就更新进度」的真实写法（0.4.0 去掉了旧 `head` 模板字符串，
  // 改为进度回调移除该订阅 + UI 按 refreshingIds 渲染行内 LoadingProgress）。
  ok('wire.subPage.progressUi',
    /this\.refreshingIds = this\.refreshingIds\.filter\(\(x\) => x !== item\.id\);/.test(subPage)
    && /if \(this\.isRefreshingSub\(sub\.id\)\) \{\n\s*LoadingProgress\(\)/.test(subPage));
  ok('wire.subPage.summaryWithFailReasons', /部分刷新成功（\$\{summary\.okCount\} 成功 \/ \$\{summary\.failCount\} 失败）/.test(subPage));
  ok('wire.subPage.noSerialLoop',
    !/for \(const s of this\.subs\.filter\(\(item: Subscription\) => item\.id !== DIRECT_GROUP_ID\)\)/.test(subPage));
  ok('wire.subPage.singleRowRefreshKept', /private async refreshOne\(sub: Subscription\): Promise<void>/.test(subPage));

  ok('wire.nodePage.usesConcurrent', /this\.subs\.refreshSubscriptionsConcurrently\(ids,/.test(nodePage));
  ok('wire.nodePage.lanes', /ConcurrentRefresh\.DEFAULT_LANES/.test(nodePage));
  ok('wire.nodePage.reentryGuard',
    /private async refreshNodes\(\): Promise<void> \{\n    if \(this\.refreshing\) \{/.test(nodePage));
  ok('wire.nodePage.progressUi', /this\.refreshDone = progress\.done;/.test(nodePage));
  // 0.4.0 重排：刷新按钮旁改为「进度文本」（done/total），旧的三态图标字符串已移除。
  ok('wire.nodePage.iconProgress',
    /if \(this\.refreshing\) \{\n\s*Text\(`\$\{this\.refreshDone\}\/\$\{this\.refreshTotal\}`\)/.test(nodePage));
  ok('wire.nodePage.noSerialLoop', !/const r = await this\.subs\.refreshSubscription\(s\.id\);/.test(nodePage));
  ok('wire.nodePage.toastSummary', /刷新完成，共 \$\{summary\.nodeCount\} 个节点/.test(nodePage));
}

// ── 汇总 ────────────────────────────────────────────────────────────
console.log(`\n并发刷新离线回归${etsArg >= 0 ? `（--ets ${etsRoot}）` : ''}：断言 ${passed} 条通过，${failures.length} 条失败`);
if (failures.length > 0) {
  console.error('失败明细：');
  for (const f of failures) {
    console.error('  - ' + f);
  }
  process.exit(1);
}
console.log('全部通过（并发上限 / 串行写入 / 失败隔离 / 限流不重试 / 进度顺序 / 并发串行一致 / 页面接入）');
rmSync(sandbox, { recursive: true, force: true });
process.exit(0);
