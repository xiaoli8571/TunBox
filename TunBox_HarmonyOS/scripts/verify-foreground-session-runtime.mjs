import assert from 'node:assert/strict';
import { harness, deferred, flush } from './orchestrator-runtime-harness.mjs';
const baseline = process.argv.includes('--baseline');

let passed = 0, failed = 0;
async function test(name, fn) {
  try { await fn(); passed++; console.log('PASS ' + name); }
  catch (e) { failed++; console.log('FAIL ' + name + ': ' + e.message); }
}

await test('a responsive tunnel survives a stale heartbeat without resetting uptime', async () => {
  const h = harness(), started = h.orch.startedAt; h.orch.startMonitors(); await h.tick();
  assert.equal(h.losses, 0); assert.equal(h.orch.state, h.ConnState.CONNECTED);
  assert.equal(h.orch.startedAt, started); assert.equal(h.writes, 0); h.stop();
});
await test('foreground inspection cannot erase an unconfirmed active session', async () => {
  const h = harness(); h.controller = false;
  await h.orch.restoreKilledSession({ cacheDir: '/sandbox' });
  assert.equal(h.snapshot.desiredConnected, true); assert.equal(h.writes, 0); h.stop();
});
await test('cold UI restores the existing runtime and original start time', async () => {
  const h = harness(); h.orch.stopMonitors(); h.orch.state = h.ConnState.DISCONNECTED;
  h.orch.startedAt = 0; h.orch.api.setEndpoint(9090, '');
  await h.orch.restoreKilledSession({ cacheDir: '/sandbox' });
  assert.equal(h.orch.state, h.ConnState.CONNECTED);
  assert.equal(h.orch.startedAt, h.snapshot.startedAt);
  assert.equal(h.orch.api.currentPort(), 19090);
  assert.equal(h.orch.mixedPort, 17890); assert.equal(h.orch.dnsPort, 11053);
  assert.equal(h.writes, 0); h.stop();
});
await test('fresh leases require no controller polling', async () => {
  const h = harness(); h.fresh(); h.controller = false; h.orch.startMonitors(); await h.tick();
  assert.equal(h.apiCalls, 0); assert.equal(h.losses, 0); h.stop();
});
await test('missing heartbeat does not disrupt an authenticated live controller', async () => {
  const h = harness(); h.heartbeat = null; h.orch.startMonitors();
  for (let i = 0; i < 4; i++) await h.tick();
  assert.equal(h.losses, 0); assert.equal(h.orch.coreDeathStrikes, 0); h.stop();
});
await test('a real outage still reaches repair after three checks spanning six seconds', async () => {
  const h = harness(); h.controller = false; h.orch.startMonitors();
  await h.tick(); assert.equal(h.losses, 0);
  await h.tick(); assert.equal(h.losses, 0);
  await h.tick(); assert.equal(h.losses, 1);
  assert.equal(h.orch.state, h.ConnState.RECOVERING); h.stop();
});
await test('a lease refreshed during a failed controller request cancels the suspicion', async () => {
  const h = harness(); h.controller = false; const gate = deferred(); h.controllerGate = gate;
  h.orch.startMonitors(); await h.tick(); h.fresh(); gate.resolve(); await flush();
  assert.equal(h.orch.coreDeathStrikes, 0); assert.equal(h.losses, 0); h.stop();
});
await test('one healthy response resets the previous negative votes', async () => {
  const h = harness(); h.controller = false; h.orch.startMonitors(); await h.tick(); await h.tick();
  h.controller = true; await h.tick(); assert.equal(h.losses, 0);
  h.controller = false; await h.tick(); await h.tick(); assert.equal(h.losses, 0);
  await h.tick(); assert.equal(h.losses, 1); h.stop();
});
await test('queued callbacks after unlock cannot instantly accumulate death votes', async () => {
  const h = harness(); h.controller = false; h.orch.startMonitors(); await h.tick();
  for (let i = 0; i < 5; i++) await h.tick(0);
  assert.equal(h.orch.coreDeathStrikes, 1); assert.equal(h.losses, 0);
  await h.tick(); await h.tick(); assert.equal(h.losses, 1); h.stop();
});
await test('a slow lease read has only one in-flight monitor check', async () => {
  const h = harness(); h.controller = false; const gate = deferred(); h.readGate = gate;
  h.orch.startMonitors(); await h.tick(); await h.tick(); await h.tick();
  assert.equal(h.apiCalls, 0); gate.resolve(); await flush();
  assert.equal(h.apiCalls, 1); assert.equal(h.orch.coreDeathStrikes, 1); h.stop();
});
await test('results from a stopped monitor cannot vote in its replacement', async () => {
  const h = harness(); h.controller = false; const gate = deferred(); h.controllerGate = gate;
  h.orch.startMonitors(); await h.tick(); h.orch.stopMonitors(); h.orch.startMonitors();
  await h.tick(); assert.equal(h.orch.coreDeathStrikes, 1);
  gate.resolve(); await flush(); assert.equal(h.orch.coreDeathStrikes, 1);
  assert.equal(h.losses, 0); h.stop();
});
await test('user stop during a pending probe prevents repair', async () => {
  const h = harness(); h.controller = false; const gate = deferred(); h.controllerGate = gate;
  h.orch.startMonitors(); await h.tick(); h.orch.requestDisconnect(); gate.resolve(); await flush();
  assert.equal(h.losses, 0); assert.equal(h.orch.coreDeathStrikes, 0); h.stop();
});
await test('a newer persisted session rejects old monitor repairs', async () => {
  const h = harness(); h.controller = false; h.orch.startMonitors(); await h.tick(); await h.tick();
  h.snapshot.sessionGeneration++; await h.tick(); assert.equal(h.losses, 0); h.stop();
});
await test('a stop from another ability prevents old monitor repairs', async () => {
  const h = harness(); h.controller = false; h.orch.startMonitors(); await h.tick(); await h.tick();
  h.snapshot.desiredConnected = false; await h.tick(); assert.equal(h.losses, 0); h.stop();
});
await test('a late foreground response cannot restore a session stopped by the user', async () => {
  const h = harness(); h.orch.state = h.ConnState.DISCONNECTED; h.orch.startedAt = 0;
  const gate = deferred(); h.controllerGate = gate;
  const restore = h.orch.restoreKilledSession({ cacheDir: '/sandbox' }); await flush();
  h.orch.requestDisconnect(); h.snapshot.desiredConnected = false; h.snapshot.sessionGeneration++;
  gate.resolve(); await restore;
  assert.equal(h.orch.state, h.ConnState.DISCONNECTED); assert.equal(h.orch.startedAt, 0);
  assert.equal(h.timers.size, 0); assert.equal(h.writes, 0); h.stop();
});
await test('an unconfirmed cold runtime is neither shown connected nor erased', async () => {
  const h = harness(); h.controller = false; h.orch.state = h.ConnState.DISCONNECTED; h.orch.startedAt = 0;
  await h.orch.restoreKilledSession({ cacheDir: '/sandbox' });
  assert.equal(h.orch.state, h.ConnState.DISCONNECTED); assert.equal(h.orch.startedAt, 0);
  assert.equal(h.snapshot.desiredConnected, true); assert.equal(h.writes, 0); h.stop();
});
await test('repeated foreground restoration preserves uptime and one monitor pair', async () => {
  const h = harness(); const start = h.orch.startedAt;
  await Promise.all([h.orch.restoreKilledSession({ cacheDir: '/sandbox' }),
    h.orch.restoreKilledSession({ cacheDir: '/sandbox' })]);
  h.advance(60000); await h.orch.restoreKilledSession({ cacheDir: '/sandbox' });
  assert.equal(h.orch.startedAt, start); assert.equal(h.timers.size, 2);
  assert.equal(h.writes, 0); assert.equal(h.losses, 0); h.stop();
});
await test('an active headless test core cannot masquerade as the real tunnel', async () => {
  const h = harness(); h.orch.testCoreFlight.isActive = () => true;
  const state = await h.orch.authorityState(); assert.equal(state.connected, false);
  assert.equal(h.apiCalls, 0); h.stop();
});
await test('an incorrect stored credential cannot prove a live session', async () => {
  const h = harness(); h.storedSecret = 'wrong-credential';
  const state = await h.orch.authorityState(); assert.equal(state.connected, false); h.stop();
});
await test('controller restoration never follows a non-loopback address', async () => {
  const h = harness(); h.config = 'external-controller: 203.0.113.1:9090\n';
  const state = await h.orch.authorityState(); assert.equal(state.connected, false);
  assert.equal(h.apiCalls, 0); h.stop();
});
await test('headless prewarming cannot stop an unconfirmed real session', async () => {
  const h = harness(); h.controller = false; h.orch.state = h.ConnState.DISCONNECTED;
  assert.equal(await h.orch.ensureTestCore(h.subs, {}), false);
  assert.equal(h.testCoreStarts, 0); assert.equal(h.snapshot.desiredConnected, true); h.stop();
});
await test('opening the app with no connection intent has no runtime side effects', async () => {
  const h = harness(); h.snapshot.desiredConnected = false; h.orch.state = h.ConnState.DISCONNECTED;
  assert.equal(await h.orch.restoreKilledSession({ cacheDir: '/sandbox' }), 'no-intent');
  assert.equal(h.apiCalls, 0); assert.equal(h.writes, 0); assert.equal(h.timers.size, 0); h.stop();
});
await test('adopting a genuinely newer session uses its saved start time', async () => {
  const h = harness(); h.orch.startMonitors(); h.snapshot.sessionGeneration++;
  h.snapshot.startedAt = h.now() - 12000;
  await h.orch.restoreKilledSession({ cacheDir: '/sandbox' });
  assert.equal(h.orch.startedAt, h.snapshot.startedAt);
  assert.equal(h.orch.sessionGeneration, h.snapshot.sessionGeneration);
  assert.equal(h.timers.size, 2); assert.equal(h.writes, 0); h.stop();
});
await test('a residual live core remains visible to disconnect logic after intent is off', async () => {
  const h = harness(); h.fresh(); h.snapshot.desiredConnected = false;
  const state = await h.orch.authorityState();
  assert.equal(state.connected, false); assert.equal(state.coreAlive, true); h.stop();
});

function trafficTick(h) {
  for (const timer of [...h.timers.values()]) if (timer.delay === 2000) timer.fn();
}
await test('late traffic cannot overwrite a disconnected session or notify observers', async () => {
  const h = harness(), gate = deferred(); h.trafficGate = gate;
  h.trafficReply = { uploadSpeed: 99, downloadSpeed: 98, uploadBytes: 97, downloadBytes: 96 };
  let updates = 0; h.orch.addListener(() => updates++);
  h.orch.startMonitors(); trafficTick(h); await flush();
  h.orch.stopMonitors(); h.orch.state = h.ConnState.DISCONNECTED;
  gate.resolve(); await flush();
  assert.equal(h.orch.traffic.downloadSpeed, 0); assert.equal(updates, 0);
  assert.equal(h.liveUpdates, 0); h.stop();
});
await test('old traffic completion cannot release the new monitor single flight', async () => {
  const h = harness(), old = deferred(), current = deferred();
  h.trafficGate = old; h.orch.startMonitors(); trafficTick(h); await flush();
  h.orch.stopMonitors(); h.orch.startMonitors(); h.trafficGate = current;
  trafficTick(h); await flush(); assert.equal(h.orch.trafficPollRunning, true);
  old.resolve(); await flush(); assert.equal(h.orch.trafficPollRunning, true);
  current.resolve(); await flush(); assert.equal(h.orch.trafficPollRunning, false); h.stop();
});
await test('traffic errors settle the single flight and allow a later sample', async () => {
  const h = harness(); h.trafficFailure = true; h.orch.startMonitors(); trafficTick(h); await flush();
  assert.equal(h.orch.trafficPollRunning, false); assert.equal(h.liveUpdates, 0);
  h.trafficFailure = false; trafficTick(h); await flush();
  assert.equal(h.liveUpdates, 1); h.stop();
});

console.log(JSON.stringify({ baseline, passed, failed }));
if (failed) process.exitCode = 1;
