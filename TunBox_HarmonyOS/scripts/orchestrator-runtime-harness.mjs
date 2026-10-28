// Runs the production orchestrator; only HarmonyOS boundaries and time are faked.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { spawnSync } from 'node:child_process';

const baseline = process.argv.includes('--baseline');
const refIndex = process.argv.indexOf('--baseline-ref');
const baselineRef = refIndex >= 0 ? process.argv[refIndex + 1] : 'HEAD';
const root = new URL('../../', import.meta.url);
const base = new URL('../entry/src/main/ets/', import.meta.url);
const sources = new Map();
function source(file) {
  if (sources.has(file)) return sources.get(file);
  if (!baseline) {
    const text = fs.readFileSync(new URL(file, base), 'utf8'); sources.set(file, text); return text;
  }
  const result = spawnSync(process.env.TUNBOX_TEST_GIT || 'git', ['show',
    baselineRef + ':TunBox_HarmonyOS/entry/src/main/ets/' + file, '--'], { cwd: root, encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr || result.error?.message);
  sources.set(file, result.stdout); return result.stdout;
}
function load(file, result, context) {
  const code = source(file).replace(/^import\b[\s\S]*?;\r?\n/gm, '').replace(/^export /gm, '');
  return vm.runInContext(stripTypeScriptTypes(`(() => {\n${code}\nreturn ${result};\n})()`,
    { mode: 'transform' }), context);
}
export function deferred() {
  let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve };
}
export async function flush() { for (let i = 0; i < 120; i++) await Promise.resolve(); }
export function harness() {
  let now = 1000000, timerId = 0;
  const timers = new Map(), logs = [], calls = [];
  const h = { heartbeat: now - 300000, controller: true, controllerGate: null,
    snapshot: { desiredConnected: true, nodeName: 'test-node', startedAt: now - 360000,
      phase: 'connected', sessionGeneration: 7, savedAt: now - 360000 },
    config: 'mixed-port: 17890\nexternal-controller: 127.0.0.1:19090\nsecret: "not-read"\ndns:\n  listen: 127.0.0.1:11053\n',
    storedSecret: 'fixture-secret', acceptedSecret: 'fixture-secret', controllerPort: 19090,
    writes: 0, losses: 0, readGate: null, apiCalls: 0, testCoreStarts: 0, ruleReady: false,
    trafficGate: null, trafficFailure: false, trafficReply: null, liveUpdates: 0 };
  class Clock extends Date { static now() { return now; } }
  class Api {
    port = 9090; secret = '';
    setEndpoint(port, secret) { this.port = port; this.secret = secret; }
    currentPort() { return this.port; } currentSecret() { return this.secret; }
    async healthProbe() {
      h.apiCalls++;
      if (h.controllerGate) { const gate = h.controllerGate; h.controllerGate = null; await gate.promise; }
      return h.controller && this.port === h.controllerPort && this.secret === h.acceptedSecret;
    }
    async traffic() {
      if (h.trafficGate) { const gate = h.trafficGate; h.trafficGate = null; await gate.promise; }
      if (h.trafficFailure) { throw new Error('injected traffic error'); }
      return h.trafficReply ?? { uploadSpeed: 0, downloadSpeed: 0, uploadBytes: 0, downloadBytes: 0 };
    }
  }
  function read(path) {
    const text = path.endsWith('vpn_heartbeat.txt') ? (h.heartbeat === null ? '' : String(h.heartbeat))
      : path.endsWith('mihomo_config.yaml') ? h.config : '';
    return { ok: text.length > 0, text, truncated: false };
  }
  const subs = { nodes: [{ id: 'fixture-node', name: 'test-node' }], async init() {} };
  const context = vm.createContext({
    Date: Clock, Math, Promise, Map, Set, Number,
    setInterval(fn, delay) { const id = ++timerId; timers.set(id, { fn, delay }); return id; },
    clearInterval(id) { timers.delete(id); },
    setTimeout(fn, delay) { const id = ++timerId; timers.set(id, { fn, delay, once: true }); return id; },
    clearTimeout(id) { timers.delete(id); },
    ClashApiService: Api, ConnectionSnapshot: class {},
    // 2026-10-27：状态枚举/事务/状态机已抽成独立模块，沙箱里必须提供等价替身，
    // 否则字段初始化（new ConnectionAttemptClock()）与 setState 门禁会 ReferenceError。
    // 数值必须与 entry/src/main/ets/commons/services/connection/ConnState.ets 一致。
    ConnState: { DISCONNECTED: 0, CONNECTING: 1, CONNECTED: 2, DISCONNECTING: 3,
      RECOVERING: 4, RECONNECTING: 5, ERROR: 6 },
    ConnectionStateMachine: {
      explain() { return null; },
      canTransition() { return true; },
      blockedByUserDisconnect() { return false; },
      interruptible() { return true; }
    },
    ConnectionTargetSource: { YAML: 'yaml', KERNEL: 'kernel', USER: 'user',
      AUTO: 'auto', RESTORE: 'restore', FALLBACK: 'fallback' },
    ConnectionTarget: class ConnectionTarget {
      constructor(groupName = '', nodeName = '', source = 'yaml', profileId = '',
        selectedAt = 0, profileRevision = '', generation = 0) {
        this.groupName = groupName; this.nodeName = nodeName; this.source = source;
        this.profileId = profileId; this.selectedAt = selectedAt;
        this.profileRevision = profileRevision; this.generation = generation;
      }
      belongsTo(id) { return this.profileId.length > 0 && this.profileId === id; }
      label() { return this.groupName.length === 0 ? this.nodeName : this.groupName + ' → ' + this.nodeName; }
    },
    ConnectionAttemptClock: class ConnectionAttemptClock {
      constructor() { this.gen = 1; }
      begin(profileId, profileRevision, reason) {
        const generation = this.gen++;
        return {
          id: generation, generation, profileId, profileRevision, reason,
          startedAt: 0, cancelled: false,
          cancel() { this.cancelled = true; },
          complete() {}, fail() {},
          isCancelled() { return this.cancelled; },
          isActive() { return !this.cancelled; },
          checkpoint() { return !this.cancelled; },
          sameProfile(id, rev) { return this.profileId === id && this.profileRevision === rev; },
          getOutcome() { return 0; },
          label() { return 'attempt#' + this.id + ' gen=' + this.generation; }
        };
      }
      currentGeneration() { return this.gen; }
      currentAttempt() { return null; }
      superseded() { return false; }
      cancelCurrent() { this.gen++; }
    },
    // 2026-10-27 拆分后的新边界：执行器沙箱里必须是可用的替身，
    // 否则 new ConnectionOrchestrator() 字段初始化就会 ReferenceError。
    KernelSelectionManager: class KernelSelectionManager {
      current() { return null; }
      nodeName() { return ''; }
      groupName() { return ''; }
      label() { return ''; }
      set() {}
      clear() {}
      async read() { return null; }
      async pickLeaf() { return null; }
      async syncFromKernel() { return null; }
    },
    ConnectionEvents: {
      subscribe() { return 1; }, unsubscribe() {}, emit() {}, count() { return 0; }
    },
    ConnEvent: class ConnEvent {
      constructor(kind) { this.kind = kind; this.state = 0; this.startedAt = 0;
        this.groupName = ''; this.nodeName = ''; this.upSpeed = 0; this.downSpeed = 0;
        this.upTotal = 0; this.downTotal = 0; }
      static state(next, startedAt) { const e = new ConnEvent(0); e.state = next; e.startedAt = startedAt; return e; }
      static exit(g, n) { const e = new ConnEvent(2); e.groupName = g; e.nodeName = n; return e; }
      static traffic(a, b, c, d) { const e = new ConnEvent(1); e.upSpeed = a; e.downSpeed = b; e.upTotal = c; e.downTotal = d; return e; }
    },
    ReconnectReason: {
      NETWORK_RESTORED: 'network-restored', NETWORK_CHANGED: 'network-changed',
      CORE_KILLED_BY_SYSTEM: 'core-killed-by-system', CORE_NOT_ALIVE: 'core-not-alive',
      RETRY: 'retry', USER_REQUEST: 'user-request'
    },
    // UnifiedScheduler 必须是**真的会排程**的替身：假定时器表里不注册任务，
    // h.tick() 就永远不会触发存活探针（表现为 coreDeathStrikes 恒为 0）。
    UnifiedScheduler: {
      every(fn, delay) { const id = ++timerId; timers.set(id, { fn, delay }); return id; },
      clear(id) { timers.delete(id); },
      count() { return timers.size; }
    },
    ReconnectPolicy: {
      delayMs(attempt, baseMs, maxMs) {
        const n = attempt < 1 ? 1 : attempt;
        const scaled = baseMs * Math.pow(2, n - 1);
        return scaled < maxMs ? scaled : maxMs;
      },
      exhausted(attempts, maxAttempts) { return attempts >= maxAttempts; },
      describeBackoff(attempts, maxAttempts, delayMs) {
        return delayMs !== null && delayMs > 0
          ? 'attempt ' + attempts + '/' + maxAttempts + ' in ' + delayMs + 'ms'
          : 'attempt ' + attempts + '/' + maxAttempts;
      }
    },
    SettingsService: {
      async init() {}, async loadSnapshot() { return { ...h.snapshot }; },
      async saveSnapshot(s) { h.writes++; h.snapshot = { ...s }; },
      async getApiSecret() { return h.storedSecret; }
    },
    // 2026-10-27：connect() 现在用 ProfileRepository 给事务打上 profile+revision，
    // 沙箱里必须有替身（不能读真实磁盘）。
    ProfileRepository: {
      currentId() { return 'fixture-profile'; },
      revisionOf() { return 'fixture-revision'; },
      fingerprint(text) { return 'fp-' + String(text).length; },
      read() { return ''; }
    },
    SubscriptionService: { instance: () => subs, onNodeSetChanged() {} },
    NetworkStateWatcher: class {
      addListener() {} isSubscribed() { return true; } networkType() { return 'wifi'; }
      generation() { return 0; }
    },
    fs: { OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2, CREATE: 64, TRUNC: 512 },
      async stat() { return {}; }, statSync(path) {
      if (path.endsWith('hyper_adrules_ads.mrs')) { if (!h.ruleReady) throw new Error('missing'); return { size: 4096 }; }
      return {}; },
      // 规则集就绪判据含 zstd 魔数 0x28B52FFD：替身必须能读回头 4 字节，否则
      // 生产侧的 hardened 校验在沙箱里恒为 false（2026-10-23 合并 PR #5 时补）。
      openSync(path) { if (path.endsWith('hyper_adrules_ads.mrs') && !h.ruleReady) throw new Error('missing'); return { fd: 1 }; },
      readSync(_fd, buffer) { const a = new Uint8Array(buffer);
        a[0] = 0x28; a[1] = 0xB5; a[2] = 0x2F; a[3] = 0xFD; return 4; },
      closeSync() {},
    },
    privateFs: { exists: path => read(path).ok, readCapped: read, async readCappedAsync(path) {
      if (h.readGate) { const gate = h.readGate; h.readGate = null; await gate.promise; } return read(path);
    } },
    MAX_STATE_FILE_BYTES: 65536,
    AppLogger: { info: (...a) => logs.push(a), warn: (...a) => logs.push(a), errText: String },
    chmodPrivate() {},
    TaskProgressUpdater: { updateLive() { h.liveUpdates++; } }
  });
  Object.assign(context, load('commons/services/TunnelAuthority.ets',
    '({ resolveAuthority, parseExtensionStatus, deriveUiPhase })', context));
  Object.assign(context, load('commons/services/RuntimeFilePolicy.ets', '({ heartbeatAgeFromText })', context));
  // Phase 3（2026-10-28）：退避策略与重连链路已独立成模块，门禁必须跑**真实**实现。
  // 用桩会让「用户断开后旧定时器不得复活」「作废尝试不得排重试」这类断言失去意义。
  Object.assign(context, load('commons/services/ReconnectPolicy.ets', '({ ReconnectPolicy })', context));
  Object.assign(context, load('commons/services/connection/ReconnectManager.ets',
    '({ ReconnectManager, ReconnectHost, ReconnectAttemptOutcome, ReconnectRuntimeState, ReconnectTelemetry })',
    context));
  const { ConnectionOrchestrator, ConnState } = load('commons/services/ConnectionOrchestrator.ets',
    '({ ConnectionOrchestrator, ConnState })', context);
  const orch = new ConnectionOrchestrator(); orch.init({ cacheDir: '/sandbox' });
  orch.state = ConnState.CONNECTED; orch.startedAt = h.snapshot.startedAt; orch.sessionGeneration = 7;
  orch.api.setEndpoint(19090, h.storedSecret);
  orch.testCoreFlight = { isActive: () => false, async ensure() { h.testCoreStarts++; return true; } };
  orch.handleCoreLoss = () => { h.losses++; calls.push('repair'); };
  return Object.assign(h, { orch, ConnState, calls, logs, timers, subs, platform: context,
    advance(ms) { now += ms; }, fresh() { h.heartbeat = now; },
    async tick(ms = 3000) {
      now += ms; for (const t of [...timers.values()]) if (t.delay === 3000) t.fn(); await flush();
    },
    stop() { orch.stopMonitors(); }, now: () => now });
}
