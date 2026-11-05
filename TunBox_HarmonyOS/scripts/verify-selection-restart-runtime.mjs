// Production restart coordinator, connect/disconnect admission and page handlers.
// Only OS resource execution, preferences storage and time are injected.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { harness, flush, deferred } from './orchestrator-runtime-harness.mjs';

const source = path => fs.readFileSync(new URL('../entry/src/main/ets/' + path, import.meta.url), 'utf8');
function evaluate(text, context) {
  return vm.runInContext(stripTypeScriptTypes(text, { mode: 'transform' }), context);
}
function setup() {
  const h = harness();
  h.profile = 'fixture-profile'; h.revision = 'fixture-revision';
  h.node = { id: 'core:台湾手动', name: '台湾手动', subscriptionId: h.profile };
  h.settings = { proxyMode: 'rule', appRoutingMode: 'all', includedApps: [], excludedApps: [], appRoutingNeedsReview: false };
  h.events = []; h.connectOK = true; h.resourceGate = null; h.stopGate = null; h.loadGate = null;
  h.subs.resolvePreferenceHint = async () => h.node;
  h.orch.lastSubs = h.subs; h.orch.lastNode = h.node;
  h.orch.appliedProfileId = h.profile; h.orch.appliedProfileRevision = h.revision;
  h.orch.runtimeProxyMode = 'rule';
  h.platform.ProfileRepository.currentId = () => h.profile;
  h.platform.ProfileRepository.revisionOf = () => h.revision;
  h.platform.SettingsService.load = async () => {
    if (h.loadGate) { const gate = h.loadGate; h.loadGate = null; await gate.promise; }
    return { ...h.settings };
  };
  h.platform.AppRoutingPolicy = evaluate(`(()=>{${source('commons/services/AppRoutingPolicy.ets').replace(/^export /gm, '')}; return AppRoutingPolicy})()`, h.platform);
  h.orch.authorityState = async () => ({ connected: false });
  h.orch.switchNodeHot = async () => { throw Error('user selection attempted a hot update'); };
  h.orch.api.setMode = async () => { throw Error('user mode attempted a hot update'); };
  h.orch.disconnectExclusive = async () => {
    h.events.push(['stop']); h.orch.state = h.ConnState.DISCONNECTING;
    if (h.stopGate) { const gate = h.stopGate; h.stopGate = null; await gate.promise; }
    h.orch.state = h.ConnState.DISCONNECTED; h.orch.disconnectRequested = false;
  };
  h.orch.connectExclusive = async (node, subs, seq, attempt, mode) => {
    h.events.push(['start', node.name, mode]); h.orch.state = h.ConnState.CONNECTING;
    if (h.resourceGate) { const gate = h.resourceGate; h.resourceGate = null; await gate.promise; }
    if (seq !== h.orch.connectSeq || h.orch.disconnectRequested) return false;
    if (!h.connectOK) { h.orch.lastError = 'injected startup failure'; return false; }
    h.orch.runtimeProxyMode = mode;
    h.orch.state = h.ConnState.CONNECTED; return true;
  };
  h.grace = async () => {
    await flush();
    for (const [id, timer] of [...h.timers]) {
      if (timer.delay === 600) { h.timers.delete(id); timer.fn(); }
    }
    await flush();
  };
  h.starts = () => h.events.filter(e => e[0] === 'start');
  return h;
}
let passed = 0;
async function test(name, action) {
  const h = setup();
  try { await action(h); passed++; console.log('PASS ' + name); }
  finally { h.stop(); }
}
await test('same profile/revision still fully restarts for a selected group', async h => {
  const p = h.orch.reconnectWithNode(h.node, h.subs, 'group');
  await h.grace(); assert.equal(await p, true);
  assert.deepEqual(h.events, [['stop'], ['start', '台湾手动', 'rule']]);
});
for (const mode of ['rule', 'global', 'direct']) {
  await test(`${mode} mode completes one full restart with the exact attempt mode`, async h => {
    const p = h.orch.applyProxyMode(mode); await h.grace(); assert.equal(await p, 'restarted');
    assert.deepEqual(h.events, [['stop'], ['start', '台湾手动', mode]]);
    assert.equal(h.settings.proxyMode, 'rule', 'coordinator must not persist temporary direct');
    assert.equal(h.orch.currentProxyMode('rule'), mode);
  });
}
await test('changing a node during direct mode retains direct for that explicit restart', async h => {
  h.orch.runtimeProxyMode = 'direct';
  const p = h.orch.reconnectWithNode(h.node, h.subs, 'node'); await h.grace(); await p;
  assert.equal(h.starts()[0][2], 'direct');
});
await test('mode restarts restore saved subgroup intent instead of the previous leaf', async h => {
  h.orch.lastNode = { ...h.node, name: 'Old leaf' };
  const p = h.orch.applyProxyMode('global'); await h.grace(); await p;
  assert.equal(h.starts()[0][1], '台湾手动');
});
await test('two selections in the grace period only start the final node', async h => {
  const first = h.orch.reconnectWithNode({ ...h.node, name: 'A' }, h.subs, 'A'); await flush();
  const second = h.orch.reconnectWithNode({ ...h.node, name: 'B' }, h.subs, 'B'); await flush();
  await h.grace(); assert.equal(await first, false); assert.equal(await second, true);
  assert.deepEqual(h.starts(), [['start', 'B', 'rule']]);
});
await test('node change while a mode restart waits retains both newest choices', async h => {
  const first = h.orch.applyProxyMode('global'); await flush();
  const second = h.orch.reconnectWithNode({ ...h.node, name: 'B' }, h.subs, 'B');
  await h.grace(); assert.equal(await first, 'deferred'); assert.equal(await second, true);
  assert.deepEqual(h.starts(), [['start', 'B', 'global']]);
});
await test('mode change during a node restart restores the newest saved choice', async h => {
  h.node = { ...h.node, name: 'New leaf' };
  const first = h.orch.reconnectWithNode(h.node, h.subs, 'node'); await flush();
  const second = h.orch.applyProxyMode('direct'); await h.grace();
  assert.equal(await first, false); assert.equal(await second, 'restarted');
  assert.deepEqual(h.starts(), [['start', 'New leaf', 'direct']]);
});
await test('late preflight cannot disconnect or reconnect after a manual stop', async h => {
  const gate = deferred(); h.loadGate = gate;
  const p = h.orch.reconnectWithNode(h.node, h.subs, 'node'); await flush();
  await h.orch.disconnect(); gate.resolve(); await h.grace();
  assert.equal(await p, false); assert.equal(h.starts().length, 0); assert.equal(h.orch.isRestarting(), false);
});
await test('stop while internal teardown is pending cancels the queued restart', async h => {
  const gate = deferred(); h.stopGate = gate;
  const p = h.orch.applyProxyMode('global'); await flush();
  const stop = h.orch.disconnect(); gate.resolve(); await stop; await h.grace();
  assert.equal(await p, 'deferred'); assert.equal(h.starts().length, 0);
});
await test('stop during grace cancels restart and later offline selection does not revive it', async h => {
  const p = h.orch.reconnectWithNode(h.node, h.subs, 'node'); await flush();
  await h.orch.disconnect();
  const offline = h.orch.reconnectWithNode({ ...h.node, name: 'offline' }, h.subs, 'offline');
  await h.grace(); assert.equal(await p, false); assert.equal(await offline, false);
  assert.equal(h.starts().length, 0);
});
await test('stop during a new startup prevents stale success and leaves the session stopped', async h => {
  const gate = deferred(); h.resourceGate = gate;
  const p = h.orch.applyProxyMode('global'); await h.grace();
  const stopping = h.orch.disconnect(); gate.resolve(); await stopping; await h.grace();
  assert.equal(await p, 'deferred'); assert.equal(h.orch.state, h.ConnState.DISCONNECTED);
});
for (const field of ['profile', 'revision']) {
  await test(`${field} changes invalidate a pending restart`, async h => {
    const p = h.orch.reconnectWithNode(h.node, h.subs, field); await flush(); h[field] = 'changed';
    await h.grace(); assert.equal(await p, false); assert.equal(h.starts().length, 0);
  });
}
await test('invalid app routing is rejected before the working tunnel is torn down', async h => {
  h.settings.appRoutingNeedsReview = true;
  await assert.rejects(h.orch.applyProxyMode('global'));
  assert.equal(h.events.length, 0); assert.equal(h.orch.state, h.ConnState.CONNECTED);
});
await test('failed startup reports an error instead of restarted success', async h => {
  h.connectOK = false;
  const p = h.orch.applyProxyMode('global'); const rejected = assert.rejects(p, /injected startup failure/);
  await h.grace(); await rejected; assert.equal(h.orch.isRestarting(), false);
});
await test('offline node and mode choices never start a proxy', async h => {
  h.orch.state = h.ConnState.DISCONNECTED;
  assert.equal(await h.orch.reconnectWithNode(h.node, h.subs, 'offline'), false);
  assert.equal(await h.orch.applyProxyMode('global'), 'deferred'); assert.equal(h.events.length, 0);
});
await test('connect preflight applies mode override to the generated settings snapshot', async h => {
  const text = source('commons/services/ConnectionOrchestrator.ets');
  const start = text.indexOf('    this.failedConnectSeq = -1;', text.indexOf('private async connectExclusive('));
  const end = text.indexOf('    const secretTask:', start);
  const run = evaluate(`(async function(seq,modeOverride){${text.slice(start,end)}return settings;})`, h.platform);
  const settings = await run.call(h.orch, h.orch.connectSeq, 'direct');
  assert.equal(settings.proxyMode, 'direct'); assert.equal(h.settings.proxyMode, 'rule');
});
await test('UI takeover reads the current direct mode from the authenticated running config', async h => {
  h.config = 'mode: direct\n' + h.config;
  assert.equal(await h.orch.restoreTunnelController(h.snapshot, true), true);
  assert.equal(h.orch.currentProxyMode('rule'), 'direct');
});

// Execute the real page method: persisted mode writes may complete out of order.
await test('home mode handler suppresses stale writes and only refreshes IP after restart succeeds', async h => {
  const text = source('pages/HomePage.ets');
  const method = text.match(/^  private async applyProxyMode\([\s\S]*?^  }/m)[0];
  const gate = deferred(), calls = [], toasts = []; let firstWrite = true;
  const ctx = vm.createContext({
    ProxyModeApply: {RESTARTED:'restarted',DEFERRED:'deferred'},
    SettingsService: { async patchSettings(fn) { if (firstWrite) { firstWrite=false; await gate.promise; } fn(h.settings); }, async load(){return h.settings;} },
    promptAction: { showToast({message}) {toasts.push(message);} }, AppLogger: {warn(){},errText:String}, TAG:'test'
  });
  const Page = evaluate(`(()=>{class Page{${method}}return Page})()`, ctx);
  const page = Object.assign(new Page(), {proxyMode:'rule',proxyModeRequest:0,settings:{...h.settings},
    orchestrator:{async applyProxyMode(mode){calls.push(mode); return 'restarted';}},
    invalidatePublicIpQueries(){}, refreshPublicIp(){calls.push('ip');}});
  const first = page.applyProxyMode('global'); await flush();
  await page.applyProxyMode('direct'); gate.resolve(); await first;
  assert.deepEqual(calls, ['direct','ip']); assert.equal(toasts.length,1); assert.equal(page.proxyMode,'direct');
});
await test('offline Smart selection immediately refreshes Home through the shared display without starting VPN', async h => {
  h.orch.state=h.ConnState.DISCONNECTED;
  h.platform.AutoSelectModes={AUTO:'auto',MANUAL:'manual'};
  h.platform.ClashConfigGenerator={SMART_GROUP_NAME:'♻️ 自动选择'};
  h.platform.SettingsService.patchSettings=async fn=>fn(h.settings);
  h.platform.SettingsService.peek=()=>h.settings;
  h.orch.smartAvailableFor=async()=>true;
  h.orch.isSmartModelAvailable=()=>true;
  const homeSource=source('pages/HomePage.ets');
  const methods=['onNodeSwitched','refreshDisplayNode'].map(name=>
    homeSource.match(new RegExp(`^  (?:private )?${name}\\([\\s\\S]*?^  }`,'m'))[0]);
  const Home=evaluate(`(()=>{class Home{${methods.join('\n')}}return Home})()`,h.platform);
  const home=Object.assign(new Home(),{orchestrator:h.orch,currentNodeName:'香港旧节点',nodeSwitchRevision:0});
  const storage=new Map();
  h.platform.AppStorage={get:key=>storage.get(key),setOrCreate(key,value){
    storage.set(key,value);if(key==='node_switch_revision'){home.nodeSwitchRevision=value;home.onNodeSwitched();}
  }};
  assert.equal(await h.orch.selectSmartSubscription(h.profile,h.subs),false);
  assert.equal(h.settings.autoSelectMode,'auto');assert.equal(home.currentNodeName,'♻️ 自动选择');
  assert.equal(h.starts().length,0,'offline selection only saves intent');
  h.orch.state=h.ConnState.CONNECTING;
  assert.equal(h.orch.getCurrentNodeName(),'♻️ 自动选择');
  h.orch.kernelSelection={nodeName:()=> 'live-exit',current:()=>({profileId:h.profile})};
  h.orch.state=h.ConnState.CONNECTED;
  assert.equal(h.orch.getCurrentNodeName(),'live-exit','online Smart must still show its real scoped exit');
  h.orch.state=h.ConnState.DISCONNECTED;
  h.subs.groupsOf=()=>[];h.subs.resolveUserPreference=()=>h.subs.nodes[0];
  h.platform.CoreCatalogService={current:()=>null,profileIdOfSnapshot:()=>''};
  h.settings.preferredNodeSubscriptionId='another-profile';
  assert.notEqual(h.orch.getCurrentNodeName(),'♻️ 自动选择','Smart intent cannot leak between subscriptions');
  h.settings.preferredNodeSubscriptionId=h.profile;
  h.orch.isSmartModelAvailable=()=>false;
  assert.notEqual(h.orch.getCurrentNodeName(),'♻️ 自动选择','missing/deleted model cannot leave stale Smart intent on Home');
  h.orch.isSmartModelAvailable=()=>true;
  const broken=source('commons/services/ConnectionOrchestrator.ets').match(/^  displayNodeName\([\s\S]*?^  }/m)[0]
    .replace(/    if \(autoSelectMode === AutoSelectModes.AUTO[\s\S]*?^    }/m,'');
  const Old=evaluate(`(()=>{class Old{${broken}}return Old})()`,h.platform);
  const old=Object.assign(new Old(),{state:h.ConnState.DISCONNECTED,kernelSelection:h.orch.kernelSelection});
  assert.notEqual(old.displayNodeName(h.settings.preferredNodeId,'auto'),'♻️ 自动选择','negative control reproduces the old stale leaf');
});
console.log(`PASS ${passed} selection/restart runtime scenarios (no HAP build or device mutation)`);
