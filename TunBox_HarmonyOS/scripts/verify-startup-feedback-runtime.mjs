#!/usr/bin/env node
// Run production HomePage methods and the orb's title with only ArkUI/OS boundaries mocked.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
const base = new URL('../entry/src/main/ets/', import.meta.url);
const read = file => readFileSync(new URL(file, base), 'utf8');
const home = read('pages/HomePage.ets');
const quickButton = read('components/FloatingQuickLaunchButton.ets');
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
async function flush() { for (let i = 0; i < 100; i++) await Promise.resolve(); }
function method(text, name) {
  const match = new RegExp(`^  (?:private )?(?:async )?${name}\\(`, 'm').exec(text);
  assert.ok(match, name); return text.slice(match.index, text.indexOf('\n  }', match.index) + 4);
}
function fixture() {
  const states = { DISCONNECTED: 0, CONNECTING: 1, CONNECTED: 2, DISCONNECTING: 3, RECOVERING: 4, ERROR: 6 };
  let now = 1000000, timerId = 0, generation = 0;
  const h = { states, forms: [], toasts: [], storage: new Map(), timers: new Map(), connects: [], disconnects: 0,
    ipCalls: [], hydrateCalls: 0, usable: true, hydrate: async () => {}, selected: async () => ({ name: 'node' }),
    connectReply: async () => true, publish: async () => {}, stopReply: async () => {} };
  class Clock extends Date { static now() { return now; } }
  const context = vm.createContext({ Promise, Date: Clock, TAG: 'HomePage', ConnState: states, getContext: () => ({}),
    Color: { Green: 'green', Orange: 'orange' }, TunBoxColors: { primaryFor: () => 'brand' },
    AppLogger: { info() {}, warn() {}, errText: String },
    AppStorage: { setOrCreate: (key, value) => h.storage.set(key, value) },
    UiGuardian: { clearExternalCancelSuppression() {}, isRegistered: () => true, isWatching: () => false,
      release: async () => {} },
    SubscriptionService: { onNodeSetChanged() {}, offNodeSetChanged() {} },
    UnifiedScheduler: { every(fn) { const id = ++timerId; h.timers.set(id, fn); return id; },
      clear(id) { h.timers.delete(id); } },
    promptAction: { showToast: ({ message }) => h.toasts.push(message) },
    FormStateSync: Object.fromEntries(['connecting', 'connected', 'disconnecting', 'disconnected', 'failed', 'noNode']
      .map(state => [state, name => ({ state, name })]).concat([['publish', async (_ctx, snapshot) => {
        h.forms.push(snapshot); await h.publish(snapshot);
      }]])) });
  const names = ['toggleConnection', 'startConnectionIfNeeded', 'completeConnectionStart', 'stopConnectionFromUser',
    'awaitSubsReady', 'selectedNode', 'hasUsableNodes', 'startNodeReadinessWatch', 'onNodesBecameReady',
    'stopNodeReadinessWatch', 'applyOrchestratorState', 'syncMiniConnectionState'];
  const Page = vm.runInContext(stripTypeScriptTypes(`class Page { ${names.map(n => method(home, n)).join('\n')} }; Page`,
    { mode: 'transform' }), context);
  const page = new Page(); h.page = page;
  Object.assign(page, { isConnected: false, isConnecting: false, pendingStart: false, pendingStop: false,
    optimisticConnected: false, startRequestSeq: 0, pendingConnectAfterNodes: false, nodeWatchTimer: -1,
    nodesLoading: false, publicIp: 'old-ip', publicIpError: '', errorMessage: '', currentNodeName: 'node',
    pageMounted: true, refreshDisplayNode() {}, stopPublicIpRecover() {}, schedulePublicIpRecover() {},
    invalidatePublicIpQueries() { h.invalidations = (h.invalidations || 0) + 1; },
    refreshPublicIp(trigger) { h.ipCalls.push({ trigger, state: page.orchestrator.state }); },
    subs: { nodes: [{ name: 'node' }], hasUsableProfile: () => h.usable,
      async init() { h.hydrateCalls++; await h.hydrate(); },
      resolvePreferenceHint: () => h.selected(), fallbackConnectionNode: () => null },
    orchestrator: { state: states.DISCONNECTED, lastError: '', isRestarting: () => false, currentNodeName: () => 'node',
      async connect(node) {
        const own = generation; h.connects.push(node); h.setState(states.CONNECTING);
        const ok = await h.connectReply(); if (own !== generation) return false;
        page.orchestrator.lastError = ok ? '' : 'test startup failure';
        h.setState(ok ? states.CONNECTED : states.ERROR); return ok;
      },
      disconnect() { generation++; h.disconnects++; h.setState(states.DISCONNECTING);
        return h.stopReply().then(() => h.setState(states.DISCONNECTED)); }
    } });
  h.setState = state => { page.orchestrator.state = state; page.applyOrchestratorState(); };
  // Use the actual parent prop expressions, so changing the UI binding cannot leave these tests green.
  const props = /CelestialPowerOrb\(\{\s+isConnected: ([^\n]+),\s+isConnecting: ([^\n]+),/.exec(home);
  assert.ok(props, 'production orb props');
  const Orb = vm.runInContext(stripTypeScriptTypes(`class Orb { ${method(read('components/CelestialPowerOrb.ets'), 'titleText')} }; Orb`,
    { mode: 'transform' }), context);
  const display = vm.runInContext(`(function() { return { isConnected: ${props[1]}, isConnecting: ${props[2]} }; })`, context);
  h.view = () => { const orb = Object.assign(new Orb(), display.call(page)); return { title: orb.titleText(), ...orb }; };
  const colorExpression = /\.fillColor\((.+)\)/.exec(quickButton)?.[1];
  assert.ok(colorExpression, 'floating quick launch power icon color expression');
  const quickColor = vm.runInContext(`(function() { return ${colorExpression}; })`, context);
  h.quickLaunchColor = (connected, connecting) => quickColor.call({ connected, connecting, themeRevision: 0 });
  h.tick = async ms => { now += ms; for (const fn of [...h.timers.values()]) fn(); await flush(); };
  return h;
}
let passed = 0;
async function test(name, run) { await run(); passed++; console.log('PASS ' + name); }

await test('tap renders connected before subscription hydration without changing actual network state', async () => {
  const h = fixture(), gate = deferred(); h.hydrate = () => gate.promise;
  const start = h.page.toggleConnection();
  assert.equal(h.view().title, '已连接'); assert.equal(h.view().isConnecting, false);
  assert.equal(h.storage.get('mini_conn_connected'), true);
  assert.equal(h.storage.get('mini_conn_connecting'), false);
  assert.equal(h.quickLaunchColor(h.storage.get('mini_conn_connected'), h.storage.get('mini_conn_connecting')), 'green');
  assert.equal(h.page.isConnected, false); assert.equal(h.page.orchestrator.state, h.states.DISCONNECTED);
  assert.equal(h.page.publicIp, ''); assert.equal(h.connects.length, 0); assert.equal(h.ipCalls.length, 0);
  assert.ok(!h.forms.some(x => x.state === 'connected'));
  gate.resolve(); await start;
  assert.equal(h.page.optimisticConnected, false); assert.equal(h.page.isConnected, true);
  assert.equal(h.view().title, '已连接'); assert.equal(h.ipCalls.length, 1);
  assert.equal(h.ipCalls[0].state, h.states.CONNECTED);
});
await test('slow real connection keeps the immediate visual state while other consumers remain connecting', async () => {
  const h = fixture(), gate = deferred(); h.connectReply = () => gate.promise;
  const start = h.page.toggleConnection(); await flush();
  assert.equal(h.page.isConnecting, true); assert.equal(h.page.isConnected, false);
  assert.equal(h.storage.get('mini_conn_connected'), true); assert.equal(h.storage.get('mini_conn_connecting'), false);
  assert.equal(h.quickLaunchColor(h.storage.get('mini_conn_connected'), h.storage.get('mini_conn_connecting')), 'green');
  assert.equal(h.quickLaunchColor(false, true), 'orange');
  assert.equal(h.quickLaunchColor(false, false), 'brand');
  assert.equal(h.view().title, '已连接'); assert.equal(h.view().isConnecting, false); assert.equal(h.ipCalls.length, 0);
  gate.resolve(true); await start;
});
await test('failed startup rolls back the optimistic button and presents the original reason', async () => {
  const h = fixture(); h.connectReply = async () => false; await h.page.toggleConnection();
  assert.equal(h.view().title, '开启连接'); assert.equal(h.page.pendingStart, false);
  assert.equal(h.storage.get('mini_conn_connected'), false);
  assert.equal(h.quickLaunchColor(h.storage.get('mini_conn_connected'), h.storage.get('mini_conn_connecting')), 'brand');
  assert.equal(h.page.errorMessage, 'test startup failure'); assert.ok(h.toasts.includes('test startup failure'));
  assert.equal(h.ipCalls.length, 0);
});
await test('a preparation exception also clears optimistic state', async () => {
  const h = fixture(); h.selected = async () => { throw Error('selection failed'); };
  await h.page.toggleConnection(); assert.equal(h.view().title, '开启连接'); assert.equal(h.page.pendingStart, false);
  assert.ok(h.toasts.some(x => x.includes('selection failed'))); assert.equal(h.connects.length, 0);
});
await test('no available node rolls back without claiming a network connection', async () => {
  const h = fixture(); h.selected = async () => null; await h.page.toggleConnection();
  assert.equal(h.view().title, '开启连接'); assert.equal(h.connects.length, 0); assert.ok(h.toasts.length > 0);
});
await test('second tap cancels hydration; a late result cannot start a proxy', async () => {
  const h = fixture(), gate = deferred(); h.hydrate = () => gate.promise;
  const start = h.page.toggleConnection(); await h.page.toggleConnection();
  assert.equal(h.disconnects, 1); assert.equal(h.page.optimisticConnected, false);
  gate.resolve(); await start; assert.equal(h.connects.length, 0); assert.equal(h.view().title, '开启连接');
});
await test('second tap cancels a pending node lookup', async () => {
  const h = fixture(), gate = deferred(); h.selected = () => gate.promise;
  const start = h.page.toggleConnection(); await flush(); await h.page.toggleConnection();
  gate.resolve({ name: 'late' }); await start; assert.equal(h.connects.length, 0);
  assert.ok(!h.forms.some(x => x.state === 'connected' || x.state === 'failed'));
});
await test('cancellation before a slow form write finishes cannot launch the old start', async () => {
  const h = fixture(), gate = deferred(); h.publish = snapshot => snapshot.state === 'connecting' ? gate.promise : Promise.resolve();
  const start = h.page.toggleConnection(); await flush(); await h.page.toggleConnection(); gate.resolve(); await start;
  assert.equal(h.connects.length, 0); assert.equal(h.view().title, '开启连接');
});
await test('old connection completion cannot clear the feedback of a newer start', async () => {
  const h = fixture(), old = deferred(); h.connectReply = () => old.promise;
  const first = h.page.toggleConnection(); await flush(); await h.page.toggleConnection();
  const next = deferred(); h.hydrate = () => next.promise; h.connectReply = async () => true;
  const second = h.page.toggleConnection(); old.resolve(true); await first;
  assert.equal(h.view().title, '已连接'); assert.equal(h.page.pendingStart, true); assert.equal(h.ipCalls.length, 0);
  next.resolve(); await second; assert.equal(h.connects.length, 2); assert.equal(h.page.isConnected, true);
});
await test('node-loading queue shows immediate feedback and resumes only once when nodes arrive', async () => {
  const h = fixture(); h.usable = false; h.page.subs.nodes = []; h.page.nodesLoading = true;
  await h.page.toggleConnection(); assert.equal(h.view().title, '已连接'); assert.equal(h.connects.length, 0);
  await h.page.startConnectionIfNeeded(); assert.equal(h.connects.length, 0);
  h.usable = true; h.page.onNodesBecameReady(); h.page.onNodesBecameReady(); await flush();
  assert.equal(h.connects.length, 1); assert.equal(h.page.isConnected, true);
});
await test('a cancelled node queue cannot reconnect when nodes arrive', async () => {
  const h = fixture(); h.usable = false; h.page.subs.nodes = []; h.page.nodesLoading = true;
  await h.page.toggleConnection(); await h.page.toggleConnection(); h.page.onNodesBecameReady(); await flush();
  assert.equal(h.connects.length, 0); assert.equal(h.view().title, '开启连接');
});
await test('node readiness timeout clears feedback and reports the reason', async () => {
  const h = fixture(); h.usable = false; h.page.subs.nodes = []; h.page.nodesLoading = true;
  await h.page.toggleConnection(); await h.tick(21000);
  assert.equal(h.view().title, '开启连接'); assert.equal(h.page.pendingConnectAfterNodes, false);
  assert.ok(h.toasts.some(x => x.includes('节点加载超时')));
});
await test('external disconnect invalidates preparation before connect has started', async () => {
  const h = fixture(), gate = deferred(); h.hydrate = () => gate.promise;
  const start = h.page.toggleConnection(); await h.page.orchestrator.disconnect(); gate.resolve(); await start;
  assert.equal(h.connects.length, 0); assert.equal(h.page.pendingStart, false); assert.equal(h.view().title, '开启连接');
});
await test('disconnect does not wait for subscription hydration or node lookup', async () => {
  const h = fixture(); h.setState(h.states.CONNECTED); h.hydrate = () => new Promise(() => {});
  await h.page.toggleConnection(); assert.equal(h.disconnects, 1); assert.equal(h.hydrateCalls, 0);
  assert.equal(h.page.pendingStop, false); assert.equal(h.view().title, '开启连接');
  assert.equal(h.ipCalls.length, 0);
});
await test('shortcut shares instant feedback and only queries the IP after actual readiness', async () => {
  const h = fixture(), gate = deferred(); h.connectReply = () => gate.promise;
  const start = h.page.startConnectionIfNeeded(); assert.equal(h.view().title, '已连接'); await flush();
  assert.equal(h.ipCalls.length, 0); gate.resolve(true); await start;
  assert.equal(h.ipCalls.length, 1); assert.equal(h.ipCalls[0].state, h.states.CONNECTED);
});
console.log(`RESULT: ${passed} startup feedback runtime cases passed`);
