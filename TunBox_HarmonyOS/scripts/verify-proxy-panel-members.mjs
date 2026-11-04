// Execute production models, policy, catalog service and non-rendering panel methods.
// OS/network/settings are injected; no credentials or complete user YAML are printed.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
const root = new URL('../entry/src/main/ets/', import.meta.url);
const read = p => {
  const baseline = process.env.TUNBOX_REVIEW_SOURCE_ROOT
    ? new URL(`entry/src/main/ets/${p}`, new URL(`file:///${process.env.TUNBOX_REVIEW_SOURCE_ROOT.replaceAll('\\','/')}/`)) : null;
  return fs.readFileSync(baseline && fs.existsSync(baseline) ? baseline : new URL(p, root), 'utf8').replace(/\r\n/g, '\n');
};
const smart = '♻️ 自动选择', scope = 'profile-A';
let settings = { proxyGroupSelections: '', autoSelectMode: 'manual' }, state = 'disconnected';
const puts = [], toasts = [];
let payload = {}, accept = true;
const api = {
  providerForProxy() { return ''; },
  async providersJson() { return null; },
  async proxiesJson() { return JSON.stringify(payload); },
  async selectProxyInGroup(group, member) {
    puts.push([group, member]);
    if (!accept) return false;
    payload.proxies[group].now = member; return true;
  }
};
let appliedProfile = scope, currentProfile = scope;
const storage = new Map();
const restarts = [];
let restartFails = false;
const orch = { get state() { return state; }, appliedProfile() { return appliedProfile; }, api,
  init() {}, getCurrentConnectionTarget() { return null; },
  getCurrentNodeName() { return settings.preferredNodeName || ''; },
  async reconnectWithNode(node) {
    if (state !== 'connected') return false;
    restarts.push(node);
    if (restartFails) throw Error('injected restart failure');
    for (const group of groups) {
      const selected = Policy.selected(settings.proxyGroupSelections, scope, group.name);
      if (selected && payload.proxies[group.name]) payload.proxies[group.name].now = selected;
    }
    await Catalog.refresh(api, true, scope);
    return true;
  }, async ensureLatencyApi() { return api; } };
const ctx = vm.createContext({ console, Date, JSON, Map, Set, Number, Object, Array, Promise,
  util: { Base64Helper: class {}, TextDecoder: { create() { return new TextDecoder(); } } },
  AppLogger: { info() {}, warn() {}, errText: String }, TAG: 'ProxyPanelRegression',
  ConnState: { CONNECTED: 'connected', CONNECTING: 'connecting' },
  AutoSelectModes: { MANUAL: 'manual', AUTO: 'auto' },
  ClashConfigGenerator: { SMART_GROUP_NAME: smart },
  ConnectionOrchestrator: { instance() { return orch; } },
  getContext() { return {}; }, effectiveTestUrl() { return 'https://example.test/204'; },
  AppStorage: { get(key) { return storage.get(key); }, setOrCreate(key, value) { storage.set(key, value); } },
  LatencyChannel: { CORE: 'core' }, LatencyLiveView: { flushNow() {} },
  LatencyEngine: { isRunning() { return false; } },
  SettingsService: { async init() {}, async load() { return settings; }, async patchSettings(fn) { fn(settings); } },
  setTimeout(fn) { fn(); return 0; }
});
function load(path, names) {
  const source = read(path).replace(/^import\b[\s\S]*?;\n/gm, '').replace(/^export /gm, '');
  const result = vm.runInContext(stripTypeScriptTypes(`(()=>{${source}\nreturn {${names}}})()`, { mode: 'transform' }), ctx);
  Object.assign(ctx, result); return result;
}
const { ProxyNode } = load('commons/models/ProxyNode.ets', 'ProxyNode,ProxyNodeType');
const { ProxyGroup } = load('commons/models/ProxyGroup.ets', 'ProxyGroup');
load('commons/latency/LatencyTestUrl.ets', 'LatencyTestUrl');
load('commons/models/AppSettings.ets', 'AppSettings');
load('commons/latency/LatencyKinds.ets', 'LatencyProbeKind,LatencyStrategy,LatencyTimeout');
load('commons/services/LatencyState.ets', 'LatencyContext');
load('commons/flclash/FlclashDelay.ets', 'DelayTarget');
ctx.LatencyStoreBridge = { async ensureStore() {}, async persistConclusions() {}, recordFor() {return null;} };
const { SubscriptionParser } = load('commons/services/SubscriptionParser.ets', 'SubscriptionParser');
load('commons/flclash/CoreCatalog.ets', 'CoreCatalog,CoreCatalogModel,CoreGroup,CoreNode');
load('commons/flclash/CoreNodeBridge.ets', 'CoreNodeBridge');
const { ProxyPanelMembers: Policy } = load('commons/flclash/ProxyPanelMembers.ets', 'ProxyPanelMembers');
const { CoreCatalogService: Catalog } = load('commons/flclash/CoreCatalogService.ets', 'CoreCatalogService');
const progressSource = read('commons/services/LatencyEngine.ets').match(/^export class LatencyProgress \{[\s\S]*?^}/m)[0];
ctx.LatencyProgress = vm.runInContext(stripTypeScriptTypes(`(()=>{${progressSource.replace('export ', '')}; return LatencyProgress})()`, {mode: 'transform'}), ctx);
const { BackgroundLatencyService: Background } = load('commons/services/BackgroundLatencyService.ets', 'BackgroundLatencyService');
const source = read('components/SubscriptionSection.ets');
const methods = ['groupsOf', 'activeGroupOf', 'catalogFor', 'profileRevisionFor', 'coreCatalogFor', 'panelNodes', 'corePanelNodes', 'localPanelNodes',
  'selectPanelMember', 'handleNodeTap', 'openDeleteSheet', 'isActiveNode', 'protoOf', 'nodeCountText', 'testSub',
  'isTestingSub', 'sortPanelRows', 'selectAsMember', 'closePanel', 'pingRecord', 'pingRecordForName'];
const extracted = methods.map(name => {
  const match = source.match(new RegExp(`^  private (?:async )?${name}\\([\\s\\S]*?^  }`, 'm'));
  assert.ok(match, `missing production method ${name}`); return match[0];
});
const Panel = vm.runInContext(stripTypeScriptTypes(`(()=>{class Panel {${extracted.join('\n')}}return Panel})()`, { mode: 'transform' }), ctx);
const fixture = `proxies:\n  - {name: 直连, type: direct}\nproxy-groups:\n  - name: 默认代理\n    type: select\n    proxies: [香港故转, 日本手动, 香港自动, 直连]\n  - name: 香港故转\n    type: fallback\n    proxies: []\n  - name: 日本手动\n    type: select\n    proxies: []\n  - name: 香港自动\n    type: url-test\n    proxies: []\n`;
// Optional arguments: raw user file, then the native-prepared copy from its profile repository.
// Native preparation is a platform boundary, not a second YAML parser implemented in this test.
const rawInput = process.argv[2] ? fs.readFileSync(process.argv[2], 'utf8') :
  'S1: &S1 {type: select, proxies: [香港故转, 日本手动, 香港自动, 直连]}\nproxy-groups:\n  - {name: 默认代理, <<: *S1}\n';
const input = process.argv[3] ? fs.readFileSync(process.argv[3], 'utf8') : fixture;
const groups = SubscriptionParser.parseProxyGroups(input, scope);
const parent = groups.find(g => g.name === '默认代理');
assert.ok(parent && parent.members.length > 1, 'fixture must include a parent with nested policies');
const direct = Object.assign(new ProxyNode(), { id: 'local-direct', subscriptionId: scope,
  name: '直连', originalName: '直连', proxyType: 'direct' });
function panel(nodes = [direct]) {
  const p = new Panel();
  Object.assign(p, { panelSubId: scope, currentProfileId: scope, selectedGroup: parent.name,
    smartSelected: false, sortByDelay: true, selectingMember: '', coreRevision: 0, nodeRevision: 0,
    profileRevisions: new Map([[scope,'r1']]), settings, currentNodeName: '', service: { nodesOf() { return nodes; }, groupsOf(id) { return groups.filter(g => g.subscriptionId === id); } },
    toast(text) { toasts.push(text); }, selectNode() { throw Error('strategy incorrectly sent to node reconnect'); }
  }); return p;
}
function corePayload() {
  const proxies = { '直连': { type: 'Direct' } };
  for (const g of groups) proxies[g.name] = { type: Policy.type(g.groupType), all: [...g.members], now: g.members[0] || '' };
  return { proxies };
}
let passed = 0;
async function test(name, fn) { await fn(); passed++; console.log('PASS ' + name); }
await test('upgrade repairs existing anchor-damaged groups from the prepared profile once and is idempotent', async () => {
  const broken = SubscriptionParser.parseProxyGroups(rawInput, scope);
  assert.equal(broken.find(g => g.name === parent.name).members.length, 0);
  const serviceSource = read('commons/services/SubscriptionService.ets');
  const match = serviceSource.match(/^  private async rebuildGroupsFromCacheIfMissing\([\s\S]*?^  }/m);
  assert.ok(match);
  let reads = 0, cacheReads = 0;
  ctx.ProfileRepository = { revisionOf: () => 'r1', read(id) { reads++; return id === scope ? input : ''; } };
  ctx.DIRECT_GROUP_ID = 'direct';
  const Service = vm.runInContext(stripTypeScriptTypes(`(()=>{class Service {${match[0]}}return Service})()`, { mode: 'transform' }), ctx);
  const service = new Service();
  Object.assign(service, { subscriptions: [{id: scope}], proxyGroups: broken,
    nodesOf() { return [direct]; }, store: { async get() { cacheReads++; throw Error('node-only cache must not override full profile'); } } });
  assert.equal(await service.rebuildGroupsFromCacheIfMissing(), true);
  assert.equal(reads, 1); assert.equal(cacheReads, 0);
  assert.deepEqual(Array.from(service.proxyGroups.find(g => g.name === parent.name).members), Array.from(parent.members));
  assert.equal(await service.rebuildGroupsFromCacheIfMissing(), false);
  const imported = serviceSource.slice(serviceSource.indexOf('  async addLocalYaml('));
  assert.ok(imported.includes('BodyDispatch.classify(ProfileRepository.read(sub.id))'));
  const remote = serviceSource.slice(serviceSource.indexOf('const profileValidation = await ProfileRepository.validateAndStore'), serviceSource.indexOf('private async appendProviderNodes'));
  assert.ok(remote.includes('BodyDispatch.classify(ProfileRepository.read(sub.id))'));
  const local = serviceSource.slice(serviceSource.indexOf('private async refreshLocalSubscription'), serviceSource.indexOf('  async addLocalYaml('));
  assert.ok(local.indexOf('ProfileRepository.read(id)') < local.indexOf('RawSubscriptionStore.readRaw(id)'));
  assert.equal((serviceSource.match(/ProxyProviderParser.parse\((?:localDispatch|dispatch).body\)/g) || []).length, 3);
});
await test('offline panel preserves exact direct-member order and strategy types', () => {
  state = 'disconnected'; Catalog.clear();
  const rows = panel().panelNodes();
  assert.deepEqual(Array.from(rows, n => n.name), Array.from(parent.members));
  assert.equal(rows.filter(Policy.isGroup).length, parent.members.length - 1);
  assert.equal(rows[0].proxyType, 'Fallback');
});
await test('a profile with no local leaf table still displays nested groups', () => {
  const rows = panel([]).panelNodes();
  assert.equal(rows.length, parent.members.length - 1); assert.ok(rows.every(Policy.isGroup));
});
await test('local rows cannot resolve a same-name node or group from another profile', () => {
  const foreign = Object.assign(new ProxyGroup(), { subscriptionId: 'profile-B', name: 'foreign', groupType: 'select' });
  const local = Object.assign(new ProxyGroup(), { subscriptionId: scope, name: 'root', members: ['foreign', 'DIRECT'] });
  const rows = Policy.fromLocal(local, [foreign], [], smart);
  assert.deepEqual(Array.from(rows, n => n.name), ['DIRECT']);
});
await test('connected panel retains children and provider members absent from local tables', async () => {
  payload = corePayload(); payload.proxies['provider-only'] = { type: 'Vless' };
  payload.proxies[parent.name].all.push('provider-only');
  await Catalog.refresh(api, true, scope); state = 'connected';
  const p = panel(), rows = p.panelNodes();
  assert.equal(rows.length, parent.members.length + 1);
  assert.ok(rows.some(n => n.name === 'provider-only')); assert.ok(p.groupsOf(scope)[0].members.includes(parent.members[0]));
});
await test('a stale foreign catalog falls back to this profile, not a same-name group', async () => {
  payload = { proxies: { [parent.name]: { type: 'Selector', all: ['foreign-node'] }, 'foreign-node': { type: 'Trojan' } } };
  await Catalog.refresh(api, true, 'profile-B');
  assert.deepEqual(Array.from(panel().panelNodes(), n => n.name), Array.from(parent.members));
});
await test('offline selection is scoped, persistent and does not start a VPN or dial a group', async () => {
  state = 'disconnected'; Catalog.clear(); puts.length = 0;
  settings = { proxyGroupSelections: Policy.remember('', 'profile-B', parent.name, 'keep'), autoSelectMode: 'auto' };
  const p = panel(), member = p.panelNodes()[1];
  await p.selectPanelMember(parent, member);
  assert.equal(puts.length, 0); assert.equal(settings.autoSelectMode, 'manual');
  assert.equal(Policy.selected(settings.proxyGroupSelections, scope, parent.name), member.name);
  assert.equal(Policy.selected(settings.proxyGroupSelections, 'profile-B', parent.name), 'keep');
  assert.equal(settings.preferredNodeName, member.name);
  assert.equal(p.currentNodeName, member.name);
  assert.ok(storage.get('node_switch_revision') > 0, 'home receives the same change without a page switch');
  assert.equal(p.isActiveNode(member), true); p.smartSelected = true; assert.equal(p.isActiveNode(member), false);
});
await test('connected selection saves the exact parent then fully restarts with the child intent', async () => {
  state = 'connected'; payload = corePayload(); accept = true; puts.length = 0;
  await Catalog.refresh(api, true, scope);
  const p = panel(), member = p.panelNodes()[1];
  await p.selectPanelMember(p.activeGroupOf(scope), member);
  assert.equal(puts.length, 0); assert.equal(p.isActiveNode(member), true);
  assert.equal(restarts.at(-1).name, member.name); assert.ok(storage.get('public_ip_revision') > 0);
  assert.ok(toasts.at(-1).includes('代理已重启'));
});
await test('failed restart preserves the requested selection without claiming success or refreshing IP', async () => {
  restartFails = true;
  const ipRevision = storage.get('public_ip_revision'), p = panel(), member = p.panelNodes()[0];
  await p.selectPanelMember(p.activeGroupOf(scope), member);
  assert.equal(settings.preferredNodeName, member.name);
  assert.ok(toasts.at(-1).includes('代理重启失败'));
  assert.equal(storage.get('public_ip_revision'), ipRevision); restartFails = false;
});
await test('group rows send a strategy intent through the panel restart flow', async () => {
  const p = panel();
  const groupRow = p.panelNodes().find((n) => Policy.isGroup(n));
  assert.ok(groupRow, 'fixture must expose a strategy row');
  let invoked = 0;
  p.selectPanelMember = async () => { invoked++; };
  p.suppressClick = false; p.deleteSheetOn = false;
  p.handleNodeTap(groupRow);
  // 2026-11-03 用户口径（对齐 FlClash）：点组行 = 选中该子组，不展开、不下钻、不改 selectedGroup
  assert.equal(p.selectedGroup, parent.name);
  assert.equal(invoked, 1);
  // 右侧圆圈做同一件事（手滑兜底）
  p.selectAsMember(groupRow);
  assert.equal(invoked, 2);
  p.openDeleteSheet(groupRow); assert.ok(toasts.at(-1).includes('策略组'));
});
await test('saved choices restore after restart; foreign, stale and read-only group keys are ignored', async () => {
  payload = corePayload(); puts.length = 0;
  let raw = Policy.remember('', scope, parent.name, parent.members[1]);
  raw = Policy.remember(raw, 'profile-B', parent.name, 'foreign');
  raw = Policy.remember(raw, scope, parent.members[0], 'missing');
  raw = Policy.remember(raw, scope, 'missing-parent', 'missing');
  assert.equal(await Catalog.restoreGroupSelections(api, scope, raw), 1);
  assert.deepEqual(puts, [[parent.name, parent.members[1]]]);
  puts.length = 0; assert.equal(await Catalog.restoreGroupSelections(api, scope, raw, () => false), 0); assert.equal(puts.length, 0);
});
await test('bad persisted JSON cannot break rendering or selection', () => {
  for (const bad of ['', 'null', '[]', 'bad', '"string"', '{"x":42}']) assert.equal(Object.keys(Policy.selections(bad)).length, 0);
});
await test('the synthetic Smart entry is not duplicated and grid/list behavior is retained', () => {
  const g = Object.assign(new ProxyGroup(), { subscriptionId: scope, name: 'root', members: [smart, 'DIRECT'] });
  const child = Object.assign(new ProxyGroup(), { subscriptionId: scope, name: smart, groupType: 'smart' });
  assert.deepEqual(Array.from(Policy.fromLocal(g, [child], [], smart), n => n.name), ['DIRECT']);
  assert.ok(source.includes('this.gridMode = !this.gridMode')); assert.ok(source.includes('this.NodeCell(row[0])'));
});
await test('counts separate strategies from proxies and never print "0 节点" for group-only configs', () => {
  state = 'disconnected'; Catalog.clear();
  // 2026-11-03 用户口径：卡片去掉「N 分组」，只报真实代理数；一个都没有就留空（只显示更新时间）
  assert.equal(panel().nodeCountText({id: scope}), '');
  const proxy = Object.assign(new ProxyNode(), {name: 'remote', proxyType: 'Vless'});
  assert.equal(Policy.summary([direct, proxy, proxy]), '1 节点');
  assert.equal(Policy.summary([direct]), '');
  assert.equal(Policy.summary([proxy]), '1 节点');
});
await test('headless snapshots retain provider rows without changing declared group counts or offline saved selection', async () => {
  payload = corePayload(); payload.proxies.GLOBAL = {type: 'Selector', all: []};
  payload.proxies['provider-real'] = {type: 'Vless'};
  payload.proxies[parent.name].all.push('provider-real');
  state = 'disconnected'; await Catalog.refresh(api, true, scope);
  const p = panel();
  assert.equal(p.nodeCountText({id: scope}), '1 节点');
  assert.ok(p.panelNodes().some(n => n.name === 'provider-real'));
  const selected = Policy.selected(settings.proxyGroupSelections, scope, parent.name);
  assert.ok(p.isActiveNode(p.panelNodes().find(n => n.name === selected)));
  let current = true;
  const stale = await Catalog.refresh({async proxiesJson() { current = false; return JSON.stringify(payload); }}, true, 'foreign', () => current);
  assert.equal(stale, null); assert.equal(Catalog.profileIdOfSnapshot(), scope);
});
await test('group exits and Direct are testable; rejected policies are not', async () => {
  const starts = [];
  ctx.FlclashLatencyService = { isRunning() { return false; }, startTargets(api, targets) {
    const names=targets.map(t=>t.proxyName); starts.push(Array.from(names));
    return { async wait() { return {total: names.length, started: names.length, measured: names.length, timeout: 0, failed: 0, cancelled: 0}; } };
  } };
  ctx.ProfileRepository = { currentId() { return currentProfile; }, revisionOf: () => 'r1' };
  ctx.SubscriptionService = { instance() { return { async init() {}, subscriptions: [{id: scope}], groupsOf() { return groups; } }; } };
  payload = corePayload();
  for (const group of groups) {
    if (group.name !== parent.name) { payload.proxies[group.name].all = ['直连']; payload.proxies[group.name].now = '直连'; }
  }
  // 2026-11-03 对齐 FlClash：同一份本地模板（`proxies` 只有 `直连` + provider 占位符）在
  // FlClash 里能正常测速——它把组员逐个交给 `/proxies/{name}/delay`，子策略组再去测自己的
  // 成员。TunBox 旧写法在「没有真实代理」时直接拒测，用户看到「没有可测速的代理节点」。
  // 这里断言批次真的跑起来，且目标就是可见组员（策略组算目标，DIRECT 不算）。
  const template = await Background.testSubscription({}, scope, null, parent.name);
  assert.equal(template.total, 1, JSON.stringify(template));
  assert.deepEqual(starts[0], ['直连']);
  payload.proxies['provider-real'] = {type: 'Vless'};
  const result = await Background.testSubscription({}, scope, null, parent.name);
  assert.equal(result.measured, 1);
  assert.deepEqual(starts[1], ['直连']);
  // 组里只有 DIRECT/REJECT：必须明确「该分组没有可测速的成员」，绝不假装测完。
  payload.proxies[parent.name].all = ['直连'];
  const directOnly = await Background.testSubscription({}, scope, null, parent.name);
  assert.equal(directOnly.total, 1);
  payload.proxies.REJECT = {type: 'Reject'};
  payload.proxies[parent.name].all = ['REJECT'];
  const rejectOnly = await Background.testSubscription({}, scope, null, parent.name);
  assert.equal(rejectOnly.total, 0);
  assert.match(rejectOnly.message, /该分组没有可测速的成员/);
  payload.proxies[parent.name].all = [...parent.members];
  ctx.IsolatedLatencyCore = { async open() { return api; }, networkCurrent: () => true, async close() {} };
  appliedProfile = 'profile-B'; state = 'connected';
  const stale = await Background.testSubscription({}, scope, null, parent.name);
  assert.equal(stale.total, 1); assert.equal(starts.length, 4); appliedProfile = scope;
  const foreign = await Background.testSubscription({}, 'profile-B');
  assert.equal(foreign, null); assert.equal(starts.length, 4);
});
await test('the actual panel never reports complete for empty, skipped or all-failed delay batches', async () => {
  const p = panel(); p.testingIds = []; p.showPanel = true;
  ctx.BackgroundLatencyService = { async testSubscription() { return {total: 0, finished: 0, message: '没有可测速的代理节点'}; } };
  await p.testSub(scope, 'local'); assert.match(toasts.at(-1), /没有可测速/); assert.equal(p.testingIds.length, 0);
  ctx.BackgroundLatencyService.testSubscription = async () => ({total: 3, finished: 3, measured: 0, timeout: 1, failed: 2, cancelled: 0, message: ''});
  await p.testSub(scope, 'local'); assert.match(toasts.at(-1), /未测得有效延迟/);
  ctx.BackgroundLatencyService.testSubscription = async () => ({total: 3, finished: 3, measured: 1, timeout: 1, failed: 1, message: ''});
  await p.testSub(scope, 'local'); assert.match(toasts.at(-1), /1 成功，1 超时，1 失败/);
});
if (process.argv[3]) { assert.equal(groups.length, 33); assert.equal(parent.members.length, 18); console.log('PASS supplied Ymihomo: 33 groups, 18 default direct members, 17 strategy rows'); }
console.log(`RESULT: ${passed} production panel runtime checks passed (mocked platform; not device UI verification)`);
