// Execute production scope, policy, persistence, session and lifecycle code.
// HarmonyOS boundaries are injected; no device/network performance claims.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { harness, deferred, flush } from './orchestrator-runtime-harness.mjs';

const root = new URL('../entry/src/main/ets/', import.meta.url);
const read = file => fs.readFileSync(new URL(file, root), 'utf8').replace(/\r\n/g, '\n');
const logger = { info() {}, warn() {}, error() {}, errText: String };
const ctx = vm.createContext({ console, Date, JSON, Map, Set, Number, Object, Array, Promise,
  Math, setTimeout, clearTimeout, setInterval, clearInterval, AppLogger: logger,
  util: {Base64Helper: class {}, TextDecoder: {create: () => new TextDecoder()}},
  ConnState: {CONNECTED:'connected'},
  ConnectionOrchestrator: { testCoreBusyProbes: [], instance: () => ({state:'disconnected', appliedProfile: () => ''}) } });
function load(file, exports) {
  const code = read(file).replace(/^import\b[\s\S]*?;\n/gm, '').replace(/^export /gm, '');
  const result = vm.runInContext(stripTypeScriptTypes(`(()=>{${code}\nreturn {${exports}}})()`,
    { mode: 'transform' }), ctx);
  Object.assign(ctx, result); return result;
}
load('commons/latency/LatencyKinds.ets', 'LatencyProbeKind,LatencyStrategy,LatencyTimeout');
load('commons/latency/LatencyTestUrl.ets', 'LatencyTestUrl');
const { LatencyContext: Scope, LatencyRecord: Record, LatencyState: State } =
  load('commons/services/LatencyState.ets', 'LatencyContext,LatencyRecord,LatencyState,LatencyChannel,LatencyPolicy');
const { LatencyLiveView: View } = load('commons/services/LatencyLiveView.ets', 'LatencyLiveView');
const { LatencyStore: Store, MemoryLatencyPersistence: Memory } =
  load('commons/latency/LatencyStore.ets', 'LatencyStore,MemoryLatencyPersistence,PreferencesLatencyPersistence');
const { LatencyStoreBridge: Bridge } = load('commons/services/LatencyStoreBridge.ets', 'LatencyStoreBridge');
const { NodeSortSnapshot: Sort } = load('commons/services/NodeSortPersistence.ets',
  'NodeSortSnapshot,NodeSortModes,NodeLatencyRecord');
load('commons/models/ProxyNode.ets', 'ProxyNode,ProxyNodeType');
load('commons/models/ProxyGroup.ets', 'ProxyGroup');
load('commons/models/AppSettings.ets', 'AppSettings');
load('commons/tunbox/CoreNodeBridge.ets', 'CoreNodeBridge');
const { CoreCatalog: Catalog } = load('commons/tunbox/CoreCatalog.ets', 'CoreCatalog,CoreCatalogModel');
const { ProxyPanelMembers: PanelPolicy } = load('commons/tunbox/ProxyPanelMembers.ets', 'ProxyPanelMembers,DelayPlan');
const { CoreCatalogService: Catalogs } = load('commons/tunbox/CoreCatalogService.ets', 'CoreCatalogService');
const { DelayTarget, DelayHttpReply, DelayRequestHandle, TunBoxDelayRun, TunBoxDelayPolicy } =
  load('commons/tunbox/TunBoxDelay.ets', 'DelayResult,DelayTarget,DelayHttpReply,DelayRequestHandle,TunBoxDelayRun,TunBoxDelayPolicy,TUNBOX_DELAY_TIMED_OUT,TUNBOX_DELAY_FAILED,TUNBOX_DELAY_URL');
let response = () => Promise.resolve(new DelayHttpReply(200, '{"delay":35}'));
const urls = [];
ctx.TunBoxDelayRun = class extends TunBoxDelayRun {
  constructor(base, secret) {
    super(base, secret, { send(url) { urls.push(url); return new DelayRequestHandle(response(url), () => {}); } },
      new TunBoxDelayPolicy(64, 3000, 20));
  }
};
const { TunBoxLatencyService: Service } = load('commons/tunbox/TunBoxLatencyService.ets', 'TunBoxLatencyService');
const api = { endpointBase: () => 'http://127.0.0.1:9090', endpointSecret: () => '', providerForProxy: () => '',
  async healthProbe(){return false;} };
const a = new Scope('A', 'revision-1', 'https://test.example/a', '204');
const b = new Scope('B', 'revision-1', 'https://test.example/a', '204');
function measured(scope, name, delay, at = 100) {
  const record = Record.measured(name, delay, 'core', at); record.context = scope; View.setRecord(record); return record;
}
let passed = 0;
async function test(name, run) { await run(); passed++; console.log('PASS ' + name); }

await test('node dial failures, DNS failures and legacy failures render consistently as timeout', () => {
  for(const kind of ['timeout','network_unreachable','dns_unresolved','failed']) {
    assert.equal(Store.describe(kind,-1,1000,1001).text,'超时');
  }
});

await test('profile, content revision, URL and expected status are independent identities', () => {
  View.clearAll(); measured(a, '香港01', 31);
  assert.equal(View.latencyFor('香港01', a), 31);
  for (const other of [b, new Scope('A', 'revision-2', a.testUrl, a.expected),
    new Scope('A', a.revision, 'https://test.example/b', a.expected),
    new Scope('A', a.revision, a.testUrl, '200-299')]) assert.equal(View.recordFor('香港01', other), null);
  View.setRecord(Record.measured('legacy', 999, 'core', 1));
  assert.equal(View.recordFor('legacy', a), null, 'old unscoped cache has no proven provenance');
  assert.notEqual(new Scope('a\u0000b', 'c', 'd').key('e'), new Scope('a', 'b\u0000c', 'd').key('e'));
});
await test('persistent field slots and cold restore preserve the complete scope and timestamp', async () => {
  Memory.reset(); Store.clear(); Store.setBackend(new Memory());
  measured(a, '香港01', 41, 100); measured(b, '香港01', 81, 200);
  await Bridge.persistConclusions(['香港01'], a); await Bridge.persistConclusions(['香港01'], b);
  View.clearAll(); Store.clear(); await Bridge.restoreFromStore();
  assert.equal(View.latencyFor('香港01', a), 41); assert.equal(View.latencyFor('香港01', b), 81);
  assert.equal(View.recordFor('香港01', b).atMs, 200);
  measured(a, '香港01', 13, 500); Store.clear(); await Bridge.restoreFromStore();
  assert.equal(View.latencyFor('香港01', a), 13, 'disk cannot overwrite a newer live result');
});
await test('real Preferences backend round-trips long scoped names within the OS key limit and rejects wrong identities', async () => {
  const fields = new Map();
  const preferences = {async get(key,fallback){return fields.get(key) ?? fallback;},
    async put(key,value){assert.ok(Buffer.byteLength(key,'utf8') <= 1024);fields.set(key,value);},
    async getAll(){return Object.fromEntries(fields);},async flush(){}};
  ctx.preferences = {async getPreferences(){return preferences;}};
  const Prefs = ctx.PreferencesLatencyPersistence;
  await Prefs.init({}); Store.setBackend(new Prefs()); Store.clear(); View.clearAll();
  const scope = new Scope('订阅😀'.repeat(100),'revision','https://test.example/'+ 'p'.repeat(1900),'200-299');
  const name = '香港😀'.repeat(200), key = scope.key(name);
  measured(scope,name,42,777);await Bridge.persistConclusions([name],scope);
  assert.ok(fields.size > 3);assert.ok(fields.has(Prefs.key(key,'identity')));
  Store.clear();View.clearAll();await Bridge.restoreFromStore();
  assert.equal(View.latencyFor(name,scope),42);assert.equal(View.recordFor(name,scope).atMs,777);
  fields.set(Prefs.key(key,'identity'),'ls3:foreign-identity');
  assert.equal(await new Prefs().loadNode(key),null,'a token never proves identity by itself');
  await new Prefs().saveField(key,'delayMs','999');
  assert.equal(fields.get(Prefs.key(key,'delayMs')),'42','a collision/corrupt identity cannot overwrite another slot');
});
await test('retention prunes this profile revision without discarding another profile', () => {
  measured(a, '香港01', 31); measured(b, '香港01', 81);
  const next = new Scope('A', 'revision-2', a.testUrl, a.expected);
  measured(next, '香港01', 22); View.retainOnly(['香港01'], next);
  assert.equal(View.recordFor('香港01', a), null); assert.equal(View.latencyFor('香港01', next), 22);
  assert.equal(View.latencyFor('香港01', b), 81);
});
await test('sort snapshots drop unproven/foreign latency data while retaining manual order', () => {
  const snapshot = Sort.fromJsonText('{"mode":"manual","order":["香港01"],"records":[{"name":"香港01","latency":3}]}');
  snapshot.retainScope(a.key('')); assert.equal(snapshot.records.length, 0);
  assert.deepEqual(Array.from(snapshot.order), ['香港01']);
  snapshot.scope = a.key(''); snapshot.records = [{name: '香港01', latency: 2}];
  const restored = Sort.fromJsonText(snapshot.toJsonText()); restored.retainScope(b.key(''));
  assert.equal(restored.records.length, 0); assert.equal(restored.testedAt, 0);
});
await test('real settings shards retain scope and never merge foreign same-name latency/statistics', async () => {
  const {SettingsService: Settings} = load('commons/services/SettingsService.ets','SettingsService');
  const fields = new Map();
  Settings.store = {async get(key,fallback){return fields.get(key) ?? fallback;}, async put(key,value){fields.set(key,value);},async flush(){}};
  const aSnapshot = Sort.fromJsonText('{"testedAt":100,"records":[{"name":"same","latency":31}]}');
  aSnapshot.scope = a.key(''); await Settings.nodeSortSnapshotWrite(aSnapshot.toJsonText());
  const bStats = Sort.fromJsonText('{"records":[{"name":"same","failCount":4,"lastOk":false}]}');
  bStats.scope = b.key(''); await Settings.saveNodeSortStats(bStats.toJsonText());
  const aView = Sort.fromJsonText(await Settings.loadNodeSortSnapshot(a.key('')));
  assert.equal(aView.recordFor('same').latency,31);assert.equal(aView.recordFor('same').failCount,0);
  const bView = Sort.fromJsonText(await Settings.loadNodeSortSnapshot(b.key('')));
  assert.equal(bView.recordFor('same').latency,-2);assert.equal(bView.recordFor('same').failCount,4);
  bView.testedAt=200;bView.recordFor('same').latency=72;await Settings.nodeSortSnapshotWrite(bView.toJsonText());
  aSnapshot.testedAt=999;await Settings.routeSnapshotWrite(aSnapshot.toJsonText());
  const latest = Sort.fromJsonText(await Settings.loadNodeSortSnapshot(b.key('')));
  assert.equal(latest.scope,b.key(''));assert.equal(latest.recordFor('same').latency,72);
});
const model = Catalog.parse(JSON.stringify({ proxies: {
  ROOT: {type: 'Selector', now: 'X', all: ['X', 'Y', 'Z']},
  X: {type: 'Selector', now: 'same', all: ['same']},
  Y: {type: 'Selector', now: 'same', all: ['same']},
  Z: {type: 'Selector', now: 'same', all: ['same']}, same: {type: 'Vless'}
} }));
const groups = [
  {name: 'ROOT', url: 'https://test.example/parent', expectedStatus: '200-299'},
  {name: 'X', url: 'https://test.example/x', expectedStatus: '204'},
  {name: 'Y', url: 'https://test.example/y', expectedStatus: ''},
  {name: 'Z', url: '', expectedStatus: ''}
];
const plan = PanelPolicy.delayPlan(model, 'ROOT', 'smart', 'https://test.example/global', '', groups);
await test('nested groups inherit URL independently and ignore health-check status like FlClash delay', () => {
  assert.equal(plan.targets.length, 3); assert.equal(plan.skipped, 0);
  assert.deepEqual(Array.from(plan.targets, t => [t.name, t.url, t.expected]), [
    ['same', groups[1].url, ''], ['same', groups[2].url, ''], ['same', groups[0].url, '']
  ]);
  const duplicate = PanelPolicy.delayPlan(model, 'ROOT', 'smart', '', '', groups.map(g => ({...g, url: 'https://test.example/one', expectedStatus: '204'})));
  assert.equal(duplicate.targets.length, 1);
});
await test('the real adapter probes the same exit under multiple URLs and keeps each result', async () => {
  urls.length = 0;
  response = url => Promise.resolve(new DelayHttpReply(200, JSON.stringify({delay: new URL(url).searchParams.get('url') === groups[1].url ? 20 : 50})));
  const targets = plan.targets.map(t => new DelayTarget(t.name, t.url, '', t.expected));
  const result = await Service.startTargets(api, targets, 'manual', a).wait();
  assert.equal(result.total, 3); assert.equal(result.measured, 3); assert.equal(urls.length, 3);
  for (const target of plan.targets) assert.equal(View.latencyFor('same', new Scope('A', a.revision, target.url, target.expected)), target.url === groups[1].url ? 20 : 50);
});
await test('real production group-row lookup reads its current exit and matching policy', () => {
  const source = read('components/SubscriptionSection.ets');
  const method = source.match(/^  private pingRecordForName\([\s\S]*?^  }/m)[0];
  ctx.ProfileRepository = {revisionOf: () => a.revision};
  ctx.BackgroundLatencyService = { resolveTestUrl: () => 'https://test.example/global' };
  const Panel = vm.runInContext(stripTypeScriptTypes(`(()=>{class Panel{${method}}return Panel})()`, {mode:'transform'}), ctx);
  const panel = Object.assign(new Panel(), {panelSubId: 'A', selectedGroup: 'ROOT', settings: {},
    service: {groupsOf: () => groups}, profileRevisionFor: () => a.revision, catalogFor: () => model});
  measured(a, 'X', 999);
  assert.equal(panel.pingRecordForName('X').delayMs, 20, 'stale group-named record must not hide selected exit');
  panel.panelSubId = 'B'; assert.equal(panel.pingRecordForName('X'), null);
});
await test('a transport hang preserves previous results and never invents a node timeout', async () => {
  measured(a, 'previous', 12, 1000); response = () => new Promise(() => {});
  const result = await Service.start(api, ['previous', 'new'], a.testUrl, 'manual', null, a.expected, a).wait();
  assert.equal(result.cancelled, 2); assert.equal(result.timeout, 0);
  assert.equal(result.wasCancelled, false);
  assert.equal(View.latencyFor('previous', a), 12); assert.equal(View.stateFor('new', a), State.UNTESTED);
  assert.equal(View.recordFor('new', a).failKind, 'core_not_ready');
});
await test('a genuine kernel 504 remains an explicit timeout verdict', async () => {
  response = () => Promise.resolve(new DelayHttpReply(504, '{"message":"Timeout"}'));
  const result = await Service.start(api, ['timeout'], a.testUrl, 'manual', null, a.expected, a).wait();
  assert.equal(result.timeout, 1); assert.equal(View.stateFor('timeout', a), State.TIMEOUT);
});
await test('a healthy controller cannot turn a missing individual reply into a node timeout', async () => {
  measured(a, 'missing-old', 28, 1000);
  response = url => Promise.resolve(new DelayHttpReply(url.includes('/missing/') ? 0 : 200,
    url.includes('/missing/') ? '' : '{"delay":17}'));
  const healthy = {...api,async healthProbe(){return true;}};
  const result = await Service.start(healthy,['ok','missing'],a.testUrl,'manual',null,a.expected,a).wait();
  assert.equal(result.measured,1);assert.equal(result.timeout,0);assert.equal(result.cancelled,1);
  assert.equal(View.stateFor('missing',a),State.UNTESTED);
  response = () => Promise.resolve(new DelayHttpReply(0, ''));
  await Service.start(healthy,['missing-old'],a.testUrl,'manual',null,a.expected,a).wait();
  assert.equal(View.latencyFor('missing-old',a),28);
});
await test('cancellation before a late reply cannot overwrite previous node results', async () => {
  const gate = deferred(), entered = deferred();
  measured(a,'cancel-final',28,1000);
  response = () => { entered.resolve(); return gate.promise; };
  const session = Service.start(api,
    ['cancel-final'],a.testUrl,'manual',null,a.expected,a);
  await entered.promise;session.cancel();gate.resolve(new DelayHttpReply(504,''));
  assert.equal((await session.wait()).wasCancelled,true);
  await Promise.resolve();assert.equal(View.latencyFor('cancel-final',a),28);
});
await test('cancelling an old scope cannot clear a new same-name scope or another run owner', async () => {
  response = () => new Promise(() => {});
  const first = Service.start(api, ['overlap'], a.testUrl, 'manual', null, a.expected, a);
  const second = Service.start(api, ['overlap'], b.testUrl, 'manual', null, b.expected, b);
  await first.wait(); assert.equal(View.stateFor('overlap', b), State.TESTING);
  first.cancel(); assert.equal(View.stateFor('overlap', b), State.TESTING);
  second.cancel(); await second.wait(); assert.equal(View.stateFor('overlap', b), State.UNTESTED);
});
await test('internal hot-selection API rejects a read-back mismatch', async () => {
  const h = harness();
  try {
    const node = { name: 'B', subscriptionId: 'fixture-profile' };
    h.orch.lastSubs = h.subs; h.orch.appliedProfileId = node.subscriptionId;
    h.orch.appliedProfileRevision = 'fixture-revision'; h.orch.kernelSelection.groupName = () => 'Main';
    h.orch.api.selectNodeInGroup = async () => true;
    h.orch.api.readKernelSelection = async () => ({ group: 'Main', now: 'A', nowIsLeaf: true });
    assert.equal(await h.orch.switchNodeHot('B', node), false);
  } finally { h.stop(); }
});
// User node/mode switches are covered by verify-selection-restart-runtime.mjs.
await test('inactive catalogs do not replace the active catalog and require matching revision', async () => {
  Catalogs.clear(); const active = Catalog.parse('{"proxies":{"active":{"type":"Direct"}}}');
  await Catalogs.refresh({async proxiesJson(){return '{"proxies":{"active":{"type":"Direct"}}}';}}, true, 'A');
  Catalogs.rememberProfile('B', 'b1', model);
  assert.equal(Catalogs.profileIdOfSnapshot(), 'A'); assert.ok(Catalogs.current().findNode('active'));
  assert.equal(Catalogs.forProfile('B', 'b1'), model); assert.equal(Catalogs.forProfile('B', 'b2'), null);
});
await test('isolated headless lifecycle binds physical sockets and never calls Extension/current-profile APIs', async () => {
  const files = new Map(), events = [], copies = []; let netId = 7, modelReady = false;
  ctx.connection = { NetBearType: {BEARER_VPN: 4}, getDefaultNetSync: () => ({netId}),
    getNetCapabilitiesSync: () => ({bearerTypes: [1]}) };
  ctx.socket = {
    constructTCPSocketInstance: () => ({async connect(){throw Error('refused');}, async close(){}}),
    constructTCPSocketServerInstance: () => ({async listen(){}, async close(){}})
  };
  load('commons/services/LocalPortProbe.ets','LocalPortProbe');
  ctx.fs = {accessSync: path => path.endsWith('/ruleset') || (modelReady && path.endsWith('/Model.bin')),
    unlinkSync: path => files.delete(path),
    listFileSync: path => path.endsWith('/nested') ? ['cached.mrs'] : ['root.mrs','nested'],
    statSync: path => ({isDirectory: () => path.endsWith('/nested')}),
    copyFileSync: (source,target) => copies.push([source,target])};
  ctx.ensurePrivateDir = () => {};
  ctx.privateFs = { writePrivate(path, text) {files.set(path,text);} };
  ctx.coreBridge = {setPhysicalNetId(id){events.push(['bind',id]);return true;},
    async startCore(path){events.push(['start',path]);assert.equal(files.get(path),'profile-B');return true;},
    async stopCore(){events.push(['stop']);} };
  ctx.ClashApiService = class {setEndpoint(port,secret){this.port=port;this.secret=secret;} async healthProbe(){return true;} };
  const {IsolatedLatencyCore: Isolated} = load('commons/services/IsolatedLatencyCore.ets','IsolatedLatencyCore,IsolatedLatencyPorts');
  const isolatedApi = await Isolated.open({cacheDir:'/private/cache'}, async ports => {
    assert.ok(ports.apiPort >= 19090); modelReady = true; return 'profile-B';
  });
  assert.ok(isolatedApi.port >= 19090); assert.equal(events[0][0],'bind');
  assert.ok(copies.some(([source,target]) => source === '/private/cache/Model.bin'
    && target === '/private/cache/isolated-latency/Model.bin'), 'model prepared while building must be copied before core startup');
  assert.ok(copies.some(([source,target])=>source.endsWith('/ruleset/nested/cached.mrs')
    && target.endsWith('/isolated-latency/ruleset/nested/cached.mrs')),'nested rule caches are copied without touching the active cache');
  assert.equal(Isolated.networkCurrent(),true); netId = 8; assert.equal(Isolated.networkCurrent(),false);
  await Isolated.close(); assert.equal(files.size,0); assert.equal(events.at(-1)[1],-1);
  assert.equal(events.filter(e=>e[0]==='stop').length,1);
  assert.deepEqual(events.slice(-2).map(e => e[0]), ['stop','bind']);
  const closedEvents = events.length;
  await Isolated.close(); assert.equal(events.length, closedEvents, 'repeated close is a no-op');
  await assert.rejects(Isolated.open({cacheDir:'/private/cache'}, async () => { throw Error('build rejected'); }), /build rejected/);
  assert.deepEqual(events.slice(-3).map(e => e[0]), ['bind','stop','bind']);
  assert.equal(events.at(-1)[1], -1, 'failed preparation also releases the binding');
  assert.equal(Isolated.busy, false);
});
await test('physical binding rejection is a channel error before profile loading or node probing', async () => {
  ctx.coreBridge.setPhysicalNetId=()=>false;
  let built=0;
  await assert.rejects(ctx.IsolatedLatencyCore.open({cacheDir:'/private/cache'},async()=>{built++;return 'unused';}),/无法绑定物理网络/);
  assert.equal(built,0);assert.equal(ctx.IsolatedLatencyCore.busy,false);
  ctx.coreBridge.setPhysicalNetId=()=>true;
});

await test('inactive-profile execution leaves the connected profile and endpoint intact and serializes preparation', async () => {
  const entered = deferred(), buildGate = deferred();
  const liveApi = {port: 9090, secret: 'active-secret'};
  let liveChannelCalls = 0, builds = 0;
  const orchestrator = {state: 'connected', api: liveApi, init() {}, appliedProfile: () => 'A',
    async ensureLatencyApi(){liveChannelCalls++;throw Error('inactive test touched active channel');},
    async buildIsolatedLatencyYaml(id, _settings, port){
      assert.equal(id,'B');assert.ok(port >= 19090);builds++;entered.resolve();return buildGate.promise;
    }};
  ctx.ConnectionOrchestrator = {instance: () => orchestrator};
  ctx.ConnState = {CONNECTED: 'connected'};
  ctx.ProfileRepository = {currentId: () => 'A', revisionOf: id => id + '-revision'};
  ctx.SubscriptionService = {instance: () => ({async init(){}, subscriptions: [{id:'A'},{id:'B'}],
    groupsOf: () => [{name:'BROOT',url:'',expectedStatus:''}]})};
  ctx.SettingsService = {async init(){}, async load(){return {proxyGroupSelections:''};}};
  ctx.LatencyEngine = {isRunning: () => false};
  ctx.ClashConfigGenerator = {SMART_GROUP_NAME:'smart'};
  ctx.effectiveTestUrl = () => 'https://test.example/b';
  ctx.ClashApiService = class {
    setEndpoint(port,secret){this.port=port;this.secret=secret;}
    endpointBase(){return `http://127.0.0.1:${this.port}`;}
    endpointSecret(){return this.secret;}
    providerForProxy(){return '';}
    async healthProbe(){return true;}
    async proxiesJson(){return '{"proxies":{"BROOT":{"type":"Selector","now":"Bleaf","all":["Bleaf"]},"Bleaf":{"type":"Direct"}}}';}
  };
  const progressSource = read('commons/services/LatencyEngine.ets').match(/^export class LatencyProgress \{[\s\S]*?^}/m)[0];
  ctx.LatencyProgress = vm.runInContext(stripTypeScriptTypes(`(()=>{${progressSource.replace('export ','')}return LatencyProgress})()`,{mode:'transform'}),ctx);
  const {BackgroundLatencyService: Background} = load('commons/services/BackgroundLatencyService.ets','BackgroundLatencyService');
  response = () => Promise.resolve(new DelayHttpReply(200,'{"delay":17}'));
  Bridge.storeReady = true;
  const pending = Background.testSubscription({cacheDir:'/private/cache'}, 'B');
  await entered.promise;
  assert.equal(await Background.testSubscription({cacheDir:'/private/cache'}, 'B'), null);
  buildGate.resolve('profile-B');
  const result = await pending;
  assert.equal(result.measured,1);assert.equal(result.message,'');assert.equal(builds,1);
  assert.equal(liveChannelCalls,0);assert.equal(ctx.ProfileRepository.currentId(),'A');
  assert.equal(orchestrator.appliedProfile(),'A');assert.equal(orchestrator.state,'connected');
  assert.deepEqual(liveApi,{port:9090,secret:'active-secret'});
  assert.equal(View.latencyFor('Bleaf',new Scope('B','B-revision','https://test.example/b')),17);
  assert.equal(Catalogs.profileIdOfSnapshot(),'A');
});
await test('a definitive active-channel failure returns once without retry sleeps or node verdicts', async () => {
  let calls=0;
  ctx.ProfileRepository = {currentId:()=> 'A',revisionOf:()=> 'a-revision'};
  ctx.ConnectionOrchestrator = {instance:()=>({state:'disconnected',init(){},appliedProfile:()=> 'A',
    latencyChannelError:()=> '',
    async ensureLatencyApi(){calls++;return null;}})};
  const {BackgroundLatencyService: Background} = load('commons/services/BackgroundLatencyService.ets','BackgroundLatencyService');
  const original=ctx.setTimeout;
  ctx.setTimeout=()=>{throw Error('unexpected retry sleep');};
  try {
    const result=await Background.testSubscription({cacheDir:'/private/cache'},'A');
    assert.equal(calls,1);assert.match(result.message,/测速通道未就绪/);
    assert.equal(result.total,0);assert.equal(result.failed,0);assert.equal(result.timeout,0);
  } finally {ctx.setTimeout=original;}
});
await test('production background progress distinguishes partial replies from explicit cancellation', async () => {
  ctx.ConnectionOrchestrator = {instance:()=>({appliedProfile:()=> 'A'})};
  const {BackgroundLatencyService: Background} = load('commons/services/BackgroundLatencyService.ets','BackgroundLatencyService');
  response = url => {
    const name = decodeURIComponent(new URL(url).pathname.split('/')[2]);
    return Promise.resolve(new DelayHttpReply(name === 'missing' ? 0 : name === 'timeout' ? 504 : name === 'failed' ? 503 : 200,'{"delay":19}'));
  };
  const progress = await Background.runNames(api,['ok','missing','timeout','failed'],a.testUrl,'');
  assert.deepEqual([progress.measured,progress.timeout,progress.failed,progress.cancelled],[1,1,1,1]);
  assert.equal(progress.wasCancelled,false);assert.equal(progress.message,'');
  assert.equal(progress.completionMessage(),'测速结束：1成功，1超时，1失败，1项未取得结果，请重试');
  assert.doesNotMatch(progress.completionMessage(),/中断|已取消/);
  response = () => Promise.resolve(new DelayHttpReply(0,''));
  const none = await Background.runNames(api,['missing'],a.testUrl,'');
  assert.match(none.completionMessage(),/1项未取得结果/);assert.equal(none.wasCancelled,false);
  response = () => new Promise(()=>{});
  const pending = Background.runNames(api,['cancelled'],a.testUrl,'');
  Service.cancelCurrent();
  const cancelled = await pending;
  assert.equal(cancelled.wasCancelled,true);assert.match(cancelled.completionMessage(),/已取消/);
});
await test('both UIs use the same completion formatter, with channel/profile errors retaining precedence', () => {
  const progress = new ctx.LatencyProgress();
  progress.total=4;progress.measured=4;
  assert.equal(progress.completionMessage(),'测速完成：4成功，0超时');
  progress.message='订阅或网络已变化，本次测速已取消，请重试';progress.wasCancelled=true;
  assert.equal(progress.completionMessage(),progress.message);
  for(const file of ['components/SubscriptionSection.ets','pages/NodeSelectionPage.ets']) {
    assert.ok(read(file).includes('progress.completionMessage()'),file);
  }
  assert.ok(!read('commons/services/BackgroundLatencyService.ets').includes('测速通道已中断'));
});
await test('the production flat-page entry splits profiles, reads scoped results and preserves same-name rows when sorting', async () => {
  const source=read('pages/NodeSelectionPage.ets');
  const methods=['runLatency','refreshLatencyScopes','latencyContext','testUrlForLatency'].map(name=>{
    const method=source.match(new RegExp(`^  private (?:async )?${name}\\([\\s\\S]*?^  }`,'m'));
    assert.ok(method,name);return method[0];
  });
  const sortEnd=source.indexOf('    this.nodes = ordered;');
  assert.ok(sortEnd > source.indexOf('    // Sort the actual rows.'));
  const sort=source.slice(source.indexOf('    // Sort the actual rows.'),sortEnd);
  const Page=vm.runInContext(stripTypeScriptTypes(`(()=>{class Page{${methods.join('\n')}\nsort(sortable){${sort}\nreturn ordered;}}return Page})()`,{mode:'transform'}),ctx);
  const calls=[];let revisionReads=0;
  ctx.ProfileRepository={currentId:()=> 'A',revisionOf:id=>{revisionReads++;return id+'-r1';}};
  ctx.effectiveTestUrl=()=> 'https://test.example/flat';ctx.getContext=()=>({});
  ctx.UnifiedScheduler={every:setInterval,clear:clearInterval};
  ctx.BackgroundLatencyService={isRunning:()=>false,async testNodes(_context,id,names,onReady){
    calls.push([id,Array.from(names)]);onReady();
    for(const name of names) measured(new Scope(id,id+'-r1','https://test.example/flat'),name,id==='A'?13:71);
    return {total:names.length,finished:names.length,measured:names.length,timeout:0,failed:0,cancelled:0,wasCancelled:false,skipped:0,message:''};
  }};
  const aNode={id:'a-node',name:'same',subscriptionId:'A'},bNode={id:'b-node',name:'same',subscriptionId:'B'};
  const page=Object.assign(new Page(),{subs:{subscriptions:[{id:'A'},{id:'B'}]},latencyRevisions:new Map(),
    settings:{},sortMode:ctx.NodeSortModes.AUTO,applyProgress(){}});
  const result=await page.runLatency([bNode,aNode],true,true);
  assert.deepEqual(calls,[['B',['same']],['A',['same']]]);assert.equal(result.measured,2);
  const rows=page.sort([{node:bNode},{node:aNode}]);
  assert.deepEqual(Array.from(rows,row=>row.node.id),['a-node','b-node']);
  for(let i=0;i<100;i++){page.latencyContext(aNode);page.latencyContext(bNode);}
  assert.equal(revisionReads,2,'row reads and sort comparators must not read/hash profile files');
});

await test('subscription panel stays open across Smart, member and leaf selection with mutually exclusive marks', async () => {
  const source = read('components/SubscriptionSection.ets');
  const names = ['selectSmart','selectPanelMember','selectNode','refreshSmartEntry'];
  const methods = names.map(name => source.match(new RegExp(`^  private (?:async )?${name}\\([\\s\\S]*?^  }`,'m'))[0]);
  const Panel = vm.runInContext(stripTypeScriptTypes(`(()=>{class Panel{${methods.join('\n')}}return Panel})()`,{mode:'transform'}),ctx);
  let saved = new ctx.AppSettings(); saved.autoSelectMode = ctx.AutoSelectModes?.MANUAL ?? 'manual';
  const modes = {AUTO:'auto',MANUAL:'manual'};
  ctx.AutoSelectModes = modes;
  const calls = [], storage = new Map();
  ctx.TAG='selection-test';
  const errors=[];ctx.AppLogger={...logger,warn(_tag,message){errors.push(message);}};
  ctx.AppStorage = {get:key=>storage.get(key),setOrCreate:(key,value)=>storage.set(key,value)};
  ctx.SettingsService = {async patchSettings(fn){fn(saved);},async load(){return Object.assign(new ctx.AppSettings(),saved);}};
  const orch = {async selectSmartSubscription(id){saved.autoSelectMode=modes.AUTO;saved.preferredNodeSubscriptionId=id;calls.push(['smart',id]);return false;},
    async reconnectWithNode(node){calls.push(['member',node.name]);return false;},async smartAvailableFor(){return true;},isSmartModelAvailable(){return true;}};
  ctx.ConnectionOrchestrator = {instance:()=>orch};
  const panel = Object.assign(new Panel(),{panelSubId:'A',showPanel:true,selectedGroup:'ROOT',selectingMember:'',
    settings:saved,smartSelected:false,smartVisible:true,smartRefreshRevision:0,coreRevision:0,nodeRevision:0,
    service:{nodesOf:()=>[]},toast(){},reload(){},closePanel(){throw Error('selection closed the panel');}});
  const node = Object.assign(new ctx.ProxyNode(),{id:'core:leaf',name:'leaf',originalName:'leaf',subscriptionId:'A',proxyType:'Shadowsocks'});
  await panel.selectSmart();
  assert.equal(panel.showPanel,true);assert.equal(panel.selectedGroup,'ROOT');assert.equal(panel.smartSelected,true);
  await panel.selectPanelMember({subscriptionId:'A',name:'ROOT',members:['leaf']},node);
  assert.deepEqual(errors,[]);
  assert.equal(panel.showPanel,true);assert.equal(panel.smartSelected,false);assert.equal(panel.currentNodeName,'leaf');
  assert.equal(saved.autoSelectMode,modes.MANUAL);
  await panel.selectSmart(); await panel.selectNode(node);
  assert.equal(panel.showPanel,true);assert.equal(panel.smartSelected,false);assert.equal(panel.selectedGroup,'ROOT');
  assert.equal(saved.preferredNodeName,'leaf');assert.equal(saved.autoSelectMode,modes.MANUAL);
  assert.deepEqual(calls,[['smart','A'],['member','leaf'],['smart','A'],['member','leaf']]);
});

Service.cancelCurrent(); View.clearAll(); View.flushNow();
console.log(`RESULT: ${passed} scoped latency/lifecycle runtime checks passed`);
