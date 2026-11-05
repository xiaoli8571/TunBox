// Executes production probes, orchestrator, reconnect manager and recovery registration.
// Only OS boundaries and time are mocked. SIGKILL/OS restart claims require device evidence.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
import { harness, deferred, flush } from './orchestrator-runtime-harness.mjs';

let passed = 0;
async function test(name, fn) { await fn(); passed++; console.log('PASS ' + name); }
function probes(h, options = {}) {
  const view = {
    hasSubscriptions: () => true, subsNodeCount: () => 1,
    currentNodeName: () => 'test-node', isCurrentNodeValid: () => true,
    isHeartbeatAlive: () => false, isTunnelMarkerPresent: () => true,
    isDesiredConnected: async () => true, isIntentConsistent: async () => true,
    startErrorText: () => '', isIpv6Enabled: () => false,
    checkClashApiReachable: async () => { h.probeCalls = (h.probeCalls ?? 0) + 1; return h.controller; },
    checkDnsResolvable: async () => true, checkIpv6Resolvable: async () => true,
    checkEgressReachable: async () => true, ...options
  };
  return new h.platform.OrchestratorHealthProbes(view);
}
async function fireRecovery(h) {
  const entry = [...h.timers].find(([, timer]) => timer.once && timer.delay <= 8000);
  assert.ok(entry, 'expected a bounded reconnect timer');
  h.timers.delete(entry[0]); h.advance(entry[1].delay); entry[1].fn(); await flush();
}
function cleanupBoundaries(h) {
  h.orch.testCoreFlight = null;
  h.orch.flushTrafficAccounting = () => {};
  h.platform.coreBridge = { async stopCore() {} };
  h.platform.vpnExtension = { async stopVpnExtensionAbility() {} };
  h.platform.clearPrivateArtifacts = () => [];
}

await test('stale heartbeat plus authenticated live API passes core and shares one probe', async () => {
  const h = harness(), p = probes(h);
  assert.equal((await p.probeCore()).ok, true);
  assert.equal((await p.probeClashApi()).ok, true);
  assert.equal(h.probeCalls, 1); h.stop();
});
await test('disconnected sessions skip core/API without contacting a warm test controller', async () => {
  const h = harness(), p = probes(h, { isDesiredConnected: async () => false });
  assert.equal((await p.probeCore()).applicable, false);
  assert.equal((await p.probeClashApi()).applicable, false);
  assert.equal(h.probeCalls ?? 0, 0); h.stop();
});
await test('unready core retains the actual startup reason', async () => {
  const h = harness(); h.controller = false;
  const result = await probes(h, { startErrorText: () => '配置解析失败: invalid port' }).probeCore();
  assert.equal(result.ok, false); assert.match(result.detail, /invalid port/);
  assert.doesNotMatch(result.detail, /可能已死/); h.stop();
});
await test('missing lease and dead controller provide concrete dual failure evidence', async () => {
  const h = harness(); h.controller = false;
  assert.match((await probes(h).probeCore()).detail, /心跳与内核控制接口均无响应/); h.stop();
});
await test('cold and foreground restoration share one recovery request and preserve intent', async () => {
  const h = harness(); h.controller = false; h.orch.state = h.ConnState.DISCONNECTED;
  const result = await Promise.all([h.orch.restoreKilledSession({ cacheDir: '/sandbox' }),
    h.orch.restoreKilledSession({ cacheDir: '/sandbox' })]);
  assert.deepEqual(result, ['recovery-scheduled', 'recovery-scheduled']);
  assert.equal(h.orch.reconnectManager().snapshot(false).attempts, 1);
  assert.equal(h.timers.size, 1); assert.equal(h.writes, 0);
  assert.equal(h.snapshot.desiredConnected, true); h.stop();
});
await test('recovered controller during backoff is adopted without restarting it', async () => {
  const h = harness(); h.controller = false; h.orch.state = h.ConnState.DISCONNECTED;
  let starts = 0; h.orch.connect = async () => { starts++; return true; };
  await h.orch.restoreKilledSession({ cacheDir: '/sandbox' });
  h.controller = true; await fireRecovery(h);
  assert.equal(starts, 0); assert.equal(h.orch.state, h.ConnState.CONNECTED);
  assert.equal(h.orch.startedAt, h.snapshot.startedAt); h.stop();
});
await test('a residual fresh lease cannot falsely finish recovery while its controller is dead', async () => {
  const h = harness(); h.controller = false; h.orch.state = h.ConnState.DISCONNECTED;
  let starts = 0;
  h.orch.connect = async () => { starts++; h.orch.connectSeq++; return false; };
  await h.orch.restoreKilledSession({ cacheDir: '/sandbox' }); h.fresh();
  await fireRecovery(h); assert.equal(starts, 1);
  assert.equal(h.orch.reconnectManager().snapshot(false).telemetry.succeeded, 0); h.stop();
});
await test('user stop cancels recovery before any new extension launch', async () => {
  const h = harness(); h.controller = false; h.orch.state = h.ConnState.DISCONNECTED;
  let starts = 0; h.orch.connect = async () => { starts++; return true; };
  await h.orch.restoreKilledSession({ cacheDir: '/sandbox' }); h.orch.requestDisconnect();
  assert.equal(h.timers.size, 0); assert.equal(starts, 0); h.stop();
});
await test('another ability stopping the session also blocks pending recovery', async () => {
  const h = harness(); h.controller = false; h.orch.state = h.ConnState.DISCONNECTED;
  let starts = 0; h.orch.connect = async () => { starts++; return true; };
  await h.orch.restoreKilledSession({ cacheDir: '/sandbox' });
  h.snapshot.desiredConnected = false; h.snapshot.sessionGeneration++;
  await fireRecovery(h); assert.equal(starts, 0); h.stop();
});
await test('automatic rollback keeps intent and generation; explicit cleanup clears both', async () => {
  const h = harness(); cleanupBoundaries(h);
  await h.orch.disconnectInternal(7, true);
  assert.equal(h.snapshot.desiredConnected, true); assert.equal(h.snapshot.phase, 'recovering');
  assert.equal(h.snapshot.sessionGeneration, 7);
  await h.orch.disconnectInternal(7);
  assert.equal(h.snapshot.desiredConnected, false); assert.equal(h.snapshot.sessionGeneration, 8); h.stop();
});
await test('obsolete rollback cannot overwrite a newer persisted connection', async () => {
  const h = harness(); cleanupBoundaries(h); h.snapshot.sessionGeneration = 8;
  await h.orch.disconnectInternal(7, true);
  assert.equal(h.writes, 0); assert.equal(h.snapshot.phase, 'connected'); h.stop();
});
await test('three failed recoveries retain intent during retries then stop permanently', async () => {
  const h = harness(); cleanupBoundaries(h); h.controller = false; h.orch.state = h.ConnState.DISCONNECTED;
  let starts = 0;
  h.orch.connectExclusive = async (_node, _subs, seq) => {
    starts++; const generation = await h.orch.advanceSessionIntent(true, 'connecting', 'test-node', 0);
    await h.orch.disconnectInternal(generation, h.orch.automaticRecoveryActive);
    h.orch.failedConnectSeq = seq; h.orch.lastError = '临时系统服务错误'; return false;
  };
  await h.orch.restoreKilledSession({ cacheDir: '/sandbox' });
  await fireRecovery(h); assert.equal(h.snapshot.desiredConnected, true);
  await fireRecovery(h); assert.equal(h.snapshot.phase, 'recovering');
  await fireRecovery(h);
  assert.equal(starts, 3); assert.equal(h.timers.size, 0); assert.equal(h.snapshot.phase, 'failed');
  assert.match(h.orch.lastError, /临时系统服务错误/);
  assert.equal(await h.orch.restoreKilledSession({ cacheDir: '/sandbox' }), 'phase-failed'); h.stop();
});
await test('physical network restoration resumes a paused recovery without resetting its budget', async () => {
  const h = harness(); h.controller = false; h.orch.state = h.ConnState.DISCONNECTED;
  await h.orch.restoreKilledSession({ cacheDir: '/sandbox' });
  h.orch.onNetworkTypeChanged('none', 101); assert.equal(h.timers.size, 0);
  h.orch.onNetworkTypeChanged('wifi', 102); await flush();
  assert.equal(h.orch.reconnectManager().snapshot(false).attempts, 1);
  assert.equal(h.timers.size, 1); h.stop();
});
await test('confirmed process loss uses recovery even when health diagnostics are disabled', async () => {
  const h = harness(); h.controller = false; h.orch.state = h.ConnState.RECOVERING;
  h.orch.lastSubs = h.subs; h.orch.lastNodeName = 'test-node';
  h.platform.SettingsService.load = async () => ({ healthCheckEnabled: false });
  await h.orch.handleCoreLossAsync();
  assert.equal(h.orch.automaticRecoveryActive, true); assert.equal(h.timers.size, 1); h.stop();
});
await test('configuration and permission failures stop automatic recovery after one attempt', async () => {
  for (const error of ['配置校验未通过', '无法建立 VPN：需在弹框中允许 VPN 授权', '另一个 VPN 连接在用']) {
    const h = harness(); h.controller = false; h.orch.state = h.ConnState.DISCONNECTED;
    let starts = 0;
    h.orch.connect = async () => { h.orch.connectSeq++; starts++; h.orch.lastError = error; return false; };
    await h.orch.restoreKilledSession({ cacheDir: '/sandbox' }); await fireRecovery(h);
    assert.equal(starts, 1); assert.equal(h.timers.size, 0); assert.equal(h.snapshot.phase, 'failed'); h.stop();
  }
});
function healthFixture() {
  const h = harness(); h.orch.state = h.ConnState.DISCONNECTED; h.controller = false;
  h.platform.SettingsService.load = async () => ({ healthCheckEnabled: true, healthRepairMaxSteps: 0 });
  h.orch.hasSubscriptions = () => true; h.orch.subsNodeCount = () => 1;
  h.orch.isCurrentNodeValid = () => true; h.orch.isTunnelMarkerPresent = () => false;
  h.orch.isIntentConsistent = async () => false;
  return h;
}
await test('post-failure health diagnostics cannot replace the primary startup error', async () => {
  const h = healthFixture(); h.orch.lastError = 'VPN 扩展启动异常: bind port failed';
  assert.equal(await h.orch.runHealthSelfCheckAndRepair('connect-failed'), false);
  assert.equal(h.orch.lastError, 'VPN 扩展启动异常: bind port failed'); h.stop();
});
await test('late health results cannot overwrite a stop or a newer connection error', async () => {
  const h = healthFixture(), gate = deferred(); h.controllerGate = gate;
  const result = h.orch.runHealthSelfCheckAndRepair('connect-failed'); await flush();
  h.orch.requestDisconnect(); h.orch.lastError = 'new-session-error'; gate.resolve();
  assert.equal(await result, false); assert.equal(h.orch.lastError, 'new-session-error');
  assert.equal(h.orch.healthReport, null); h.stop();
});
await test('timeout messages do not claim an unproven download cause', async () => {
  const h = harness(); const message = h.platform.friendlyVpnStartError(-1, '内核启动超时（20s 无响应）');
  assert.match(message, /诊断日志/); assert.doesNotMatch(message, /卡在联网下载|即可正常启动/); h.stop();
});
await test('system fault recovery registers once and never replays shortcut toggle', async () => {
  const calls = [], context = vm.createContext({ appRecovery: {
    RestartFlag: { ALWAYS_RESTART: 0 }, SaveOccasionFlag: { SAVE_WHEN_ERROR: 1, SAVE_WHEN_BACKGROUND: 2 }, SaveModeFlag: { SAVE_WITH_FILE: 1 },
    enableAppRecovery: (...args) => calls.push(['enable', ...args]), setRestartWant: want => calls.push(['want', want])
  }, AppLogger: { info() {}, warn() {}, errText: String } });
  const source = readFileSync(new URL('../entry/src/main/ets/commons/services/ProcessRecovery.ets', import.meta.url), 'utf8')
    .replace(/^import\b[^;]+;\r?\n/gm, '').replace(/^export /gm, '');
  const Recovery = vm.runInContext(stripTypeScriptTypes(`(() => { ${source}; return ProcessRecovery; })()`,
    { mode: 'transform' }), context);
  Recovery.install(); Recovery.install();
  assert.equal(calls.length, 2); assert.equal(calls[1][1].abilityName, 'EntryAbility');
  assert.equal(calls[0][2], 3);
  assert.equal(calls[1][1].parameters, undefined);
});
function stageFixture(processName = 'com.tunbox.client') {
  const calls = [], state = { gate: null, fail: false };
  const context = vm.createContext({ process: { pid: 123 }, appManager: {
    async getRunningProcessInformation() {
      if (state.gate) await state.gate.promise;
      if (state.fail) throw new Error('OS query unavailable');
      return [{ pid: 456, processName: 'com.tunbox.client' }, { pid: 123, processName }];
    }
  }, ConnectionOrchestrator: { instance: () => ({
    async restoreKilledSession(c) { calls.push(['restore', c]); return 'recovery-scheduled'; }
  }) }, PersistentLogStore: { init: (...args) => calls.push(['log', ...args]) },
  AppLogger: { info() {}, warn() {}, errText: String } });
  const source = readFileSync(new URL('../entry/src/main/ets/commons/services/StageSessionRecovery.ets', import.meta.url), 'utf8')
    .replace(/^import\b[^;]+;\r?\n/gm, '').replace(/^export /gm, '');
  const Stage = vm.runInContext(stripTypeScriptTypes(`(() => { ${source}; return StageSessionRecovery; })()`,
    { mode: 'transform' }), context);
  return { Stage, calls, state };
}
await test('a main process restarted without a UI can resume its persisted session', async () => {
  const h = stageFixture(), context = { cacheDir: '/sandbox' }; await h.Stage.restore(context);
  assert.equal(h.calls.length, 2); assert.equal(h.calls[1][1], context);
});
await test('VPN and form processes cannot start a second orchestrator recovery chain', async () => {
  for (const name of ['com.tunbox.client:vpn', 'com.tunbox.client:Form', 'other']) {
    const h = stageFixture(name); await h.Stage.restore({}); assert.equal(h.calls.length, 0);
  }
});
await test('a UI launch preempts a pending stage-only restore', async () => {
  const h = stageFixture(), gate = deferred(); h.state.gate = gate;
  const restore = h.Stage.restore({}); h.Stage.noteUiLaunch(); gate.resolve(); await restore;
  assert.equal(h.calls.length, 0);
});
await test('unknown process identity fails closed without restoring any session', async () => {
  const h = stageFixture(); h.state.fail = true; await h.Stage.restore({}); assert.equal(h.calls.length, 0);
});
console.log(`RESULT: ${passed} passed; platform restart and SIGKILL still require device verification`);
