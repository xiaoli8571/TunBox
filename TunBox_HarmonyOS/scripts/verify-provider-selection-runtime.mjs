// Execute production ArkTS; inject only the HarmonyOS transport and platform state.
// All network traffic in the optional real-mihomo case stays on loopback.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import http from 'node:http';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { stripTypeScriptTypes } from 'node:module';
import { fileURLToPath } from 'node:url';

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sources = path.join(project, 'entry/src/main/ets');
const alternate = process.env.TUNBOX_REVIEW_SOURCE_ROOT;
const read = file => {
  const before = alternate && path.join(alternate, 'entry/src/main/ets', file);
  return fs.readFileSync(before && fs.existsSync(before) ? before : path.join(sources, file), 'utf8');
};
let request = async () => { throw Error('transport not configured'); };
const ctx = vm.createContext({ console, Date, JSON, Map, Set, Array, Object, Number, Math, Promise,
  setTimeout, clearTimeout, ArrayBuffer, Uint8Array,
  util: { Base64Helper: class {}, TextDecoder: { create: () => new TextDecoder() } },
  AppLogger: { info() {}, warn() {}, error() {}, errText: String },
  http: { RequestMethod: {GET:'GET', PUT:'PUT'}, createHttp() {
    return { request: (...args) => request(...args), destroy() {} };
  } },
  ConnectionTargetSource: { KERNEL:'kernel' }, LatencyPolicy: { DEFAULT_TIMEOUT_MS:3000 }
});
function evaluate(source, names) {
  return vm.runInContext(stripTypeScriptTypes(`(()=>{${source.replace(/^import\b[\s\S]*?;\r?\n/gm, '')
    .replace(/^export\s*\{[\s\S]*?\}\s*from[^;]*;\r?\n/gm, '')
    .replace(/^export /gm, '')}\nreturn {${names}}})()`, {mode:'transform'}), ctx);
}
function load(file, names) { const values = evaluate(read(file), names); Object.assign(ctx, values); return values; }
load('commons/latency/LatencyTestUrl.ets', 'LatencyTestUrl');
load('commons/latency/LatencyKinds.ets', 'LatencyProbeKind,LatencyProbeResult,LatencyStrategy,LatencyTimeout');
load('commons/latency/LatencyDnsVerdict.ets', 'LatencyDnsStatus,LatencyDnsVerdict');
load('commons/latency/LatencyProbe.ets', 'LatencyProbe,LatencyKernelEndpoint,LatencyHttpReply');
ctx.CoreLatencyProbe = ctx.LatencyProbe;
const { ClashApiService: Api } = load('commons/services/ClashApiService.ets', 'ClashApiService');
const { CoreCatalog } = load('commons/tunbox/CoreCatalog.ets', 'CoreCatalog');
load('commons/models/ProxyNode.ets', 'ProxyNode,ProxyNodeType');
load('commons/tunbox/CoreNodeBridge.ets', 'CoreNodeBridge');
const { ProxyPanelMembers: Members } = load('commons/tunbox/ProxyPanelMembers.ets', 'ProxyPanelMembers');
const { CoreCatalogService: Catalog } = load('commons/tunbox/CoreCatalogService.ets', 'CoreCatalogService');
const { DelayTarget, DelayHttpReply, DelayRequestHandle, TunBoxDelayRun, TunBoxDelayPolicy } =
  load('commons/tunbox/TunBoxDelay.ets', 'DelayTarget,DelayHttpReply,DelayRequestHandle,TunBoxDelayRun,TunBoxDelayPolicy,TUNBOX_DELAY_TIMED_OUT,TUNBOX_DELAY_FAILED,TUNBOX_DELAY_URL,delayTestKey');
const targetSource = read('commons/config/RuntimeConfigBuilder.ets').match(/^export class ConnectionTarget \{[\s\S]*?^}/m)[0];
Object.assign(ctx, evaluate(targetSource, 'ConnectionTarget'));
const { KernelSelectionManager: Selection } = load('commons/services/KernelSelectionManager.ets', 'KernelSelectionManager');
let passed = 0;
async function test(name, run) { await run(); passed++; console.log('PASS ' + name); }
const leaf = 'provider node / 香港 🇭🇰', owner = 'provider / PQ';
const raw = { proxies: {
  ROOT:{type:'Selector', now:'REGION', all:['REGION','local-direct','REJECT']},
  REGION:{type:'Selector', now:leaf, all:[leaf]},
  'local-direct':{type:'Direct'}, REJECT:{type:'Reject'}
} };
const providers = {providers:{[owner]:{proxies:[{name:leaf,type:'Vless'}, {name:'ROOT',type:'Trojan'}]}}};
const api = new Api();
request = async url => ({responseCode:200, result:JSON.stringify(url.endsWith('/providers/proxies') ? providers : raw)});
await test('provider catalog fills missing leaf types and retains static/group name precedence', async () => {
  const data = JSON.parse(await api.proxiesJson());
  assert.ok(data.proxies[leaf], 'the complete catalog must contain the provider-owned leaf');
  assert.equal(data.proxies[leaf].type, 'Vless'); assert.equal(data.proxies.ROOT.type, 'Selector');
  assert.equal(api.providerForProxy(leaf), owner); assert.equal(api.providerForProxy('ROOT'), '');
  const plan = Members.delayPlan(CoreCatalog.parse(JSON.stringify(data)), 'ROOT', 'smart');
  assert.deepEqual(Array.from(plan.names), [leaf,'local-direct']); assert.equal(plan.skipped,0);
});
await test('a nested provider selection resolves to the actual leaf and can be pinned', async () => {
  const selected = await api.readKernelSelection('ROOT');
  assert.equal(selected.now,leaf); assert.equal(selected.nowIsLeaf,true);
  assert.ok(selected.leafMembers.includes(leaf));
  const model=CoreCatalog.parse(await api.proxiesJson());
  assert.deepEqual(Array.from(Members.delayLookupNames(model,'REGION')),[leaf],
    'a cached group result from the previous exit cannot shadow the selected provider leaf');
});
await test('both delay engines use the encoded provider healthcheck route', async () => {
  const urls = [], transport = { send(url) {
    urls.push(url); return new DelayRequestHandle(Promise.resolve(new DelayHttpReply(200,'{"delay":25}')),()=>{});
  } };
  const engine = new TunBoxDelayRun('http://127.0.0.1:9090','',transport,new TunBoxDelayPolicy());
  const summary = await new Promise(resolve => engine.start([new DelayTarget(leaf,'https://example.test/204','','200-299',api.providerForProxy(leaf))],()=>{},resolve));
  assert.equal(summary.measured,1);
  assert.equal(new URL(urls[0]).pathname, `/providers/proxies/${encodeURIComponent(owner)}/${encodeURIComponent(leaf)}/healthcheck`);
  assert.equal(new URL(urls[0]).searchParams.get('expected'),'200-299');
  const endpoint = new ctx.LatencyKernelEndpoint(); endpoint.providerName = owner;
  assert.equal(new URL(ctx.LatencyProbe.delayUrl(endpoint,leaf,'https://example.test/204',3000)).pathname,new URL(urls[0]).pathname);
});
await test('the actual latency service passes provider ownership to its engine and publishes the verdict',async()=>{
  load('commons/services/LatencyState.ets','LatencyState,LatencyRecord,LatencyChannel,LatencyPolicy');
  load('commons/services/LatencyLiveView.ets','LatencyLiveView');
  ctx.ConnectionOrchestrator={testCoreBusyProbes:[]};
  const urls=[];
  ctx.TunBoxDelayRun=class extends TunBoxDelayRun {
    constructor(base,secret){super(base,secret,{send(url){urls.push(url);return new DelayRequestHandle(Promise.resolve(new DelayHttpReply(200,'{"delay":33}')),()=>{});}});}
  };
  const {TunBoxLatencyService:Service}=load('commons/tunbox/TunBoxLatencyService.ets','TunBoxLatencyService');
  const progress=await Service.start(api,[leaf],'https://example.test/204').wait();
  assert.equal(progress.total,1); assert.equal(progress.measured,1);
  assert.ok(urls[0].includes('/providers/proxies/')); assert.equal(ctx.LatencyLiveView.latencyFor(leaf),33);
});
await test('failed provider reads never retain nodes or owners from the previous snapshot', async () => {
  request = async url => ({responseCode:url.endsWith('/providers/proxies') ? 503 : 200,result:JSON.stringify(raw)});
  const data = JSON.parse(await api.proxiesJson()); assert.equal(data.proxies[leaf],undefined);
  assert.equal(api.providerForProxy(leaf),'');
  const plan = Members.delayPlan(CoreCatalog.parse(JSON.stringify(data)), 'ROOT','smart');
  assert.equal(plan.skipped,1); assert.deepEqual(Array.from(plan.names),['local-direct']);
});
await test('an unavailable catalog returns no fresh result while retaining the old UI snapshot', async () => {
  await Catalog.refresh({async proxiesJson(){return JSON.stringify(raw);}},true,'profile-A');
  assert.equal(await Catalog.refresh({async proxiesJson(){return null;}},true,'profile-B'),null);
  assert.equal(Catalog.profileIdOfSnapshot(),'profile-A'); assert.ok(Catalog.current());
});
await test('a late catalog request cannot overwrite a newer profile or resurrect a cleared catalog', async () => {
  let finish;
  const old = Catalog.refresh({proxiesJson(){return new Promise(resolve=>{finish=resolve;});}},true,'profile-A');
  await Catalog.refresh({async proxiesJson(){return JSON.stringify(raw);}},true,'profile-B');
  finish(JSON.stringify(raw)); assert.equal(await old,null); assert.equal(Catalog.profileIdOfSnapshot(),'profile-B');
  const stale = Catalog.refresh({proxiesJson(){return new Promise(resolve=>{finish=resolve;});}},true,'profile-A');
  Catalog.clear(); finish(JSON.stringify(raw)); assert.equal(await stale,null); assert.equal(Catalog.current(),null);
});
await test('exit polls cannot overwrite a newer choice or retain a foreign same-name target', async () => {
  const manager = new Selection(); let finish;
  const poll = manager.syncFromKernel({readKernelSelection(){return new Promise(resolve=>{finish=resolve;});}},'ROOT','profile-A');
  manager.set(new ctx.ConnectionTarget('ROOT','new-choice','kernel','profile-A'));
  finish({nowIsLeaf:true,now:'old-choice',group:'ROOT'}); assert.equal(await poll,null); assert.equal(manager.nodeName(),'new-choice');
  const next = await manager.syncFromKernel({async readKernelSelection(){return {nowIsLeaf:true,now:'new-choice',group:'ROOT'};}},'ROOT','profile-B');
  assert.equal(next.profileId,'profile-B');
});
await test('group cycles terminate without inventing a measurable leaf', () => {
  const model = CoreCatalog.parse(JSON.stringify({proxies:{A:{type:'Selector',now:'B',all:['B']},B:{type:'Selector',now:'A',all:['A']}}}));
  assert.equal(Members.exitOf(model,'A'),''); assert.equal(Members.delayPlan(model,'A','smart').names.length,0);
});
await test('the shared home display updates offline groups and provider-only leaves, and reads live scoped exits',async()=>{
  await Catalog.refresh({async proxiesJson(){return JSON.stringify({proxies:{...raw.proxies,[leaf]:{type:'Vless'}}});}},true,'profile-A');
  let settings={preferredNodeName:leaf,preferredNodeSubscriptionId:'profile-A'};
  Object.assign(ctx,{
    SettingsService:{peek(){return settings;}}, ProfileRepository:{currentId(){return 'profile-A';}},
    AutoSelectModes:{AUTO:'auto'}, ConnState:{CONNECTED:'connected'},
    SubscriptionService:{instance(){return {groupsOf(){return [{name:'REGION'}];},resolveUserPreference(){return null;},fallbackConnectionNode(){return {name:'old-local'};}};}}
  });
  const method=read('commons/services/ConnectionOrchestrator.ets').match(/^  displayNodeName\([\s\S]*?^  }/m)[0];
  const Display=evaluate(`class Display {${method}}`,'Display').Display;
  const display=new Display(); display.state='disconnected';
  display.kernelSelection={nodeName(){return 'old-exit';},current(){return {profileId:'profile-A'};}};
  assert.equal(display.displayNodeName('','manual'),leaf);
  settings.preferredNodeName='REGION'; assert.equal(display.displayNodeName('','manual'),'REGION');
  display.state='connected'; assert.equal(display.displayNodeName('','manual'),'old-exit');
});

const kernel = process.env.TUNBOX_MIHOMO_EXE || path.resolve(project,'../mihomo-build/mihomo-smart-462455136157a760937c666bba71afe33b1a809e/mihomo.exe');
if (!fs.existsSync(kernel)) throw Error('real mihomo missing; set TUNBOX_MIHOMO_EXE');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(),'tunbox-probe-provider-review-'));
let child;
const server = http.createServer((req,res) => {
  if (req.url === '/provider') { res.end(`proxies:\n  - {name: "wire-node", type: direct}\n`); return; }
  setTimeout(()=>{res.writeHead(204);res.end();},35);
});
try {
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const port = server.address().port;
  const reserve = net.createServer(); await new Promise(resolve=>reserve.listen(0,'127.0.0.1',resolve));
  const controller = reserve.address().port; await new Promise(resolve=>reserve.close(resolve));
  fs.writeFileSync(path.join(scratch,'config.yaml'), `mixed-port: 0\nexternal-controller: 127.0.0.1:${controller}\nlog-level: silent\nproxies:\n  - {name: local-direct, type: direct}\nproxy-providers:\n  PQ:\n    type: http\n    url: http://127.0.0.1:${port}/provider\n    path: ./provider.yaml\nproxy-groups:\n  - {name: ROOT, type: select, proxies: [REGION, local-direct]}\n  - {name: REGION, type: select, use: [PQ]}\nrules: ["MATCH,ROOT"]\n`);
  child = spawn(kernel,['-d',scratch],{stdio:'ignore',windowsHide:true});
  const base = `http://127.0.0.1:${controller}`;
  const deadline = Date.now()+10000;
  let ready=false;
  while(Date.now()<deadline) {
    if(child.exitCode!==null) throw Error('fixture core exited before readiness');
    try { const r=await fetch(`${base}/providers/proxies`); const d=await r.json(); if(d.providers?.PQ?.proxies?.length) {ready=true;break;} } catch {}
    await new Promise(resolve=>setTimeout(resolve,50));
  }
  assert.ok(ready,'loopback provider must load');
  request=async(url,opts)=>{const r=await fetch(url,{method:opts.method,headers:opts.header});return {responseCode:r.status,result:await r.text()};};
  const live = new Api(); live.setEndpoint(controller,'');
  await test('real mihomo reproduces provider omissions and the production API fills them',async()=>{
    const bare=await (await fetch(`${base}/proxies`)).json(); assert.equal(bare.proxies['wire-node'],undefined);
    const full=JSON.parse(await live.proxiesJson()); assert.equal(full.proxies['wire-node'].type,'Direct');
    assert.equal(live.providerForProxy('wire-node'),'PQ');
    assert.equal((await live.readKernelSelection('ROOT')).now,'wire-node');
  });
  await test('real provider healthcheck returns delay while the static proxy route returns 404',async()=>{
    const url=`http://127.0.0.1:${port}/204`;
    assert.equal((await fetch(`${base}/proxies/wire-node/delay?url=${encodeURIComponent(url)}&timeout=3000`)).status,404);
    const transport={send(url,headers){const abort=new AbortController();return new DelayRequestHandle(
      fetch(url,{headers,signal:abort.signal}).then(async r=>new DelayHttpReply(r.status,await r.text())),()=>abort.abort());}};
    const engine=new TunBoxDelayRun(base,'',transport,new TunBoxDelayPolicy());
    const results=[];
    const summary=await new Promise(resolve=>engine.start([new DelayTarget('wire-node',url,'','',live.providerForProxy('wire-node'))],r=>results.push(r),resolve));
    assert.equal(summary.measured,1); assert.ok(results[0].value>0); assert.equal(summary.failed,0);
  });
} finally {
  if(child && child.exitCode===null) { child.kill(); await new Promise(resolve=>child.once('exit',resolve)); }
  await new Promise(resolve=>server.close(resolve));
  const resolved=fs.realpathSync(scratch);
  assert.equal(path.dirname(resolved),fs.realpathSync(os.tmpdir()));
  assert.ok(path.basename(resolved).startsWith('tunbox-probe-provider-review-'));
  fs.rmSync(resolved,{recursive:true});
}
console.log(`RESULT: ${passed} production/provider runtime checks passed (real loopback core; no device UI claims)`);
