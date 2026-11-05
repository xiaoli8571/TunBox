// Reproduce local YAML -> persisted intent -> primary group -> real kernel selection.
// Production ArkTS is executed directly; only HarmonyOS I/O boundaries are replaced.
// The HTTP provider and the core's controller are loopback fixtures, without credentials.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import http from 'node:http';
import net from 'node:net';
import { once } from 'node:events';
import { spawn, spawnSync } from 'node:child_process';
import { stripTypeScriptTypes } from 'node:module';
import { fileURLToPath } from 'node:url';

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sourceRoot = process.env.TUNBOX_REVIEW_SOURCE_ROOT || project;
const read = file => fs.readFileSync(path.join(sourceRoot, 'entry/src/main/ets', file), 'utf8');
const core = path.resolve(project, '../mihomo-build/mihomo-smart-462455136157a760937c666bba71afe33b1a809e');
const logger = { info() {}, warn() {}, error() {}, errText: String };
let settings, profileId = 'local-template', catalog = null, catalogProfile = '';
let transport = async (url, options) => {
  const response = await fetch(url, {method: options.method, body: options.extraData, headers: options.header});
  return {responseCode:response.status, result:await response.text()};
};
const context = vm.createContext({ console, Date, JSON, Map, Set, Number, Object, Array, Math, Promise,
  setTimeout, clearTimeout, AppLogger:logger, TAG:'StartupSelectionRegression',
  util:{Base64Helper:class {},TextDecoder:{create:()=>new TextDecoder()}}, BASE_MTU:1500,
  SettingsService:{async load(){return settings;}, async patchSettings(fn){fn(settings);}},
  ProfileRepository:{currentId(){return profileId;}, exists(id){return id === 'local-template';}},
  NodeUsability:{isInfoEntry(name){return name.includes('剩余流量');}},
  CoreCatalogService:{current(){return catalog;},profileIdOfSnapshot(){return catalogProfile;}},
  ClashConfigGenerator:{SMART_GROUP_NAME:'smart'},
  ConnectionEvents:{emit(){}}, ConnEvent:{exit(){return {};}},
  http:{RequestMethod:{GET:'GET',PUT:'PUT'},createHttp(){return {request:(...args)=>transport(...args),destroy(){}};}}
});
function load(file, exports) {
  const code=read(file).replace(/^import\b[\s\S]*?;\r?\n/gm,'').replace(/^export /gm,'');
  const result=vm.runInContext(stripTypeScriptTypes(`(()=>{${code}\nreturn {${exports}}})()`,{mode:'transform'}),context);
  Object.assign(context,result); return result;
}
load('commons/models/ProxyNode.ets','ProxyNode,ProxyNodeType');
load('commons/models/Subscription.ets','SubscriptionImportDiagnostics');
load('commons/latency/LatencyTestUrl.ets','LatencyTestUrl');
load('commons/models/AppSettings.ets','AppSettings,AutoSelectModes');
load('commons/config/RuntimeConfigBuilder.ets','RuntimeConfigBuilder,ConnectionTarget,ConnectionTargetSource');
load('commons/services/ClashApiService.ets','ClashApiService');
load('commons/tunbox/CoreCatalog.ets','CoreCatalog');
load('commons/tunbox/CoreNodeBridge.ets','CoreNodeBridge');
load('commons/tunbox/ProxyPanelMembers.ets','ProxyPanelMembers');
load('commons/services/YamlMerger.ets','YamlMerger');
load('commons/tunbox/ProfileConfigMerger.ets','ProfileConfigMerger');
const {SubscriptionService}=load('commons/services/SubscriptionService.ets','SubscriptionService');
const {CoreCatalogService}=load('commons/tunbox/CoreCatalogService.ets','CoreCatalogService');
// The startup pin phase is executed verbatim, including the legacy fallback branch.
// Failures before this phase (VPN permissions/platform bring-up) are outside this fixture.
const orch=read('commons/services/ConnectionOrchestrator.ets');
const start=orch.indexOf('      const startupGroupName:',orch.indexOf('private async connectExclusive('));
const end=orch.indexOf('      ConnectionEvents.emit(ConnEvent.exit(',start);
assert.ok(start>0 && end>start);
const pin=vm.runInContext(stripTypeScriptTypes(`(async function(target,built,settings,subs){
  const yaml=built.yaml, effectiveName=built.effectiveNodeName, tunnelProfile={nodes:subs.nodes};
  const seq=this.connectSeq;
  const attempt={profileId:'local-template',generation:1,checkpoint:()=>!this.cancelled};
  ${orch.slice(start,end)}
  return finalNodeName;
})`,{mode:'transform'}),context);
let count=0;
async function test(name,run){await run();count++;console.log('PASS '+name);}
const service=Object.create(SubscriptionService.prototype);
service.nodes=[Object.assign(new context.ProxyNode(),{id:'local-direct',name:'直连',proxyType:'direct',subscriptionId:profileId})];
service.subscriptions=[];
service.proxyGroups=[{name:'香港故转',subscriptionId:profileId}];
SubscriptionService.instance=()=>service;
function reset(name='',scope='local-template',remember=true){
  settings=new context.AppSettings();settings.autoSelectMode='manual';
  settings.preferredNodeName=name;settings.preferredNodeSubscriptionId=scope;
  if(remember && name)settings.preferredNodeNamesBySubscription=context.AppSettings.rememberPreferredNodeName('',scope,name);
}
function prepare(yaml){
  const r=spawnSync(helper,[],{input:yaml,encoding:'utf8',timeout:15000});
  assert.equal(r.status,0,r.stderr);const reply=JSON.parse(r.stdout);assert.equal(reply.error,'');return reply.yaml;
}
async function freePort(){const s=net.createServer();s.listen(0,'127.0.0.1');await once(s,'listening');const p=s.address().port;await new Promise(r=>s.close(r));return p;}
let child, provider;
const scratch = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'tunbox-probe-startup-selection-'));
const helper = path.join(scratch, 'prepare.exe');
try {
  const build=spawnSync('go',['build','-o',helper,path.join(project,'scripts/fixtures/profile-prepare/main.go')],{cwd:core,encoding:'utf8',timeout:180000});
  assert.equal(build.status,0,build.stderr);
  await test('cold group intent survives a static table containing only Direct',async()=>{
    reset('台湾手动');CoreCatalogService.clear();
    const hint=await service.resolvePreferenceHint();
    assert.equal(hint.name,'台湾手动');assert.equal(hint.subscriptionId,profileId);assert.ok(hint.id.startsWith('core:'));
  });
  await test('provider leaf survives process restart without a catalog or remembered slot',async()=>{
    reset('TW-02','local-template',false);
    const hint=await service.resolvePreferenceHint();assert.equal(hint.name,'TW-02');
  });
  await test('foreign profile preference and catalog cannot supply the current dial target',async()=>{
    reset('TW-02','other-profile');settings.preferredNodeId='core:TW-02';
    CoreCatalogService.model={byName:{'TW-02':{name:'TW-02',type:'Socks5'}}};CoreCatalogService.profileId='other-profile';
    assert.equal(await service.resolvePreferenceHint(),null);
  });
  await test('default connection adopts the YAML policy instead of static Direct',async()=>{
    reset();const hint=service.fallbackConnectionNode();assert.ok(hint.id.startsWith('profile:'));
  });
  await test('a changing automatic-group exit does not overwrite the manual group intent',async()=>{
    const method=orch.match(/^  private async selfHealPreferredNode\([\s\S]*?^  }/m)[0];
    const heal=vm.runInContext(stripTypeScriptTypes(`(${method.replace('private async selfHealPreferredNode','async function')})`,{mode:'transform'}),context);
    reset('香港故转');const owner={};await heal.call(owner,'HK-01',[],profileId);
    assert.equal(owner.lastNodeName,'HK-01');assert.equal(settings.preferredNodeName,'香港故转');
    assert.equal(context.AppSettings.rememberedPreferredNodeName(settings.preferredNodeNamesBySubscription,profileId),'香港故转');
  });
  const providerBody='proxies:\n  - {name: TW-01, type: socks5, server: 127.0.0.1, port: 9}\n  - {name: TW-02, type: socks5, server: 127.0.0.1, port: 9}\n  - {name: HK-01, type: socks5, server: 127.0.0.1, port: 9}\n';
  provider=http.createServer((_req,res)=>{res.writeHead(200);res.end(providerBody);});
  provider.listen(0,'127.0.0.1');await once(provider,'listening');
  const port=await freePort();
  const yaml=prepare(`external-controller: 127.0.0.1:${port}
mode: rule
log-level: error
dns:
  enable: false
  enhanced-mode: fake-ip
profile:
  store-selected: true
proxy-providers:
  HH:
    type: http
    url: http://127.0.0.1:${provider.address().port}/nodes
    path: ./providers/HH.yaml
    interval: 86400
proxies:
  - {name: 直连, type: direct}
proxy-groups:
  - {name: 默认代理, type: select, proxies: [香港故转, 台湾手动, 直连, APP-SMART]}
  - {name: AI, type: select, proxies: [默认代理, 台湾手动, 直连]}
  - {name: YouTube, type: select, proxies: [默认代理, 台湾手动, 直连]}
  - {name: 香港故转, type: fallback, use: [HH], filter: ^HK, lazy: true, url: http://127.0.0.1:${provider.address().port}/check, interval: 86400}
  - {name: 台湾手动, type: select, use: [HH], filter: ^TW}
  - {name: APP-SMART, type: smart, use: [HH], uselightgbm: false, collectdata: false, prefer-asn: false, interval: 0}
  - {name: GLOBAL, type: select, proxies: [默认代理, 台湾手动, 直连, APP-SMART]}
rules:
  - DOMAIN,ai.example,AI
  - DOMAIN,youtube.example,YouTube
  - MATCH,默认代理
`);
  await test('AI rule priority does not replace the first declared primary selector',async()=>{
    const built=context.RuntimeConfigBuilder.resolvePinTarget(yaml,'台湾手动');
    assert.equal(built.groupName,'默认代理');assert.equal(built.nodeName,'台湾手动');assert.equal(built.matched,true);
    const dynamic=context.RuntimeConfigBuilder.resolvePinTarget(yaml,'TW-02');assert.equal(dynamic.nodeName,'TW-02');
  });
  if(process.env.TUNBOX_SUBSCRIPTION_FIXTURE)await test('private local YAML keeps its selected Taiwan subgroup after native normalization',async()=>{
    const raw=fs.readFileSync(process.env.TUNBOX_SUBSCRIPTION_FIXTURE,'utf8');
    const normalized=prepare(raw);const result=context.RuntimeConfigBuilder.resolvePinTarget(normalized,'台湾手动');
    assert.equal(result.groupName,'默认代理');assert.equal(result.nodeName,'台湾手动');assert.equal(result.matched,true);
  });
  fs.writeFileSync(path.join(scratch,'config.yaml'),yaml);
  async function boot(){
    child=spawn(path.join(core,'mihomo.exe'),['-d',scratch,'-f',path.join(scratch,'config.yaml')],{windowsHide:true,stdio:'ignore'});
    for(let i=0;i<140;i++){
      try { const data=await(await fetch(`http://127.0.0.1:${port}/proxies`)).json();if(data.proxies['台湾手动']?.all.includes('TW-02'))return; }catch{}
      await new Promise(r=>setTimeout(r,50));
    }
    throw Error('loopback provider fixture did not become ready');
  }
  async function stop(){if(child && child.exitCode===null){const ended=once(child,'exit');child.kill();await ended;}child=null;}
  await boot();
  const api=new context.ClashApiService();api.setEndpoint(port,'');
  const state=async()=>JSON.parse(await api.proxiesJson()).proxies;
  function saved(group,name){settings.proxyGroupSelections=context.ProxyPanelMembers.remember(settings.proxyGroupSelections,profileId,group,name);}
  async function startup(smart=false){
    const target=await service.resolvePreferenceHint() || service.fallbackConnectionNode();
    const resolved=context.RuntimeConfigBuilder.resolvePinTarget(yaml,target.name);
    const built={yaml,options:{useSmart:smart},smartGroupName:smart?'APP-SMART':'',effectiveNodeName:resolved.nodeName,ruleGroupName:resolved.groupName,pinMatched:resolved.matched};
    const owner={api,connectSeq:1,disconnectRequested:false,attempts:{currentGeneration:()=>1},pendingProfileRevision:'fixture',
      kernelSelection:{set(value){this.value=value;}},async selfHealPreferredNode(){throw Error('explicit intent was overwritten by fallback');}};
    const selected=await pin.call(owner,target,built,settings,service);return {selected,owner};
  }
  await test('cold startup honors the Taiwan group and preserves independent service groups',async()=>{
    reset('台湾手动');saved('默认代理','台湾手动');saved('台湾手动','TW-02');
    await api.applyGroupSelection('AI','直连');await api.applyGroupSelection('YouTube','直连');
    const {selected}=await startup();assert.equal(selected,'TW-02');
    const after=await state();assert.equal(after['默认代理'].now,'台湾手动');assert.equal(after.AI.now,'直连');assert.equal(after.YouTube.now,'直连');
  });
  await test('concrete provider leaf wins over a stale saved root Direct selection',async()=>{
    reset('TW-01');saved('默认代理','直连');saved('台湾手动','TW-02');
    const {selected}=await startup();assert.equal(selected,'TW-01');
    const after=await state();assert.equal(after['默认代理'].now,'台湾手动');assert.equal(after['台湾手动'].now,'TW-01');
    assert.equal(after.AI.now,'直连');
  });
  await test('a complete core restart still applies the offline group intent',async()=>{
    await stop();await boot();CoreCatalogService.clear();reset('台湾手动');saved('默认代理','台湾手动');saved('台湾手动','TW-02');
    assert.equal((await startup()).selected,'TW-02');
  });
  await test('no saved pick adopts and confirms the profile default without pinning static Direct',async()=>{
    reset();await api.applyGroupSelection('默认代理','香港故转');
    assert.equal((await startup()).selected,'HK-01');assert.equal((await state())['默认代理'].now,'香港故转');
  });
  await test('global mode applies the same subgroup intent to the actual GLOBAL exit',async()=>{
    reset('台湾手动');settings.proxyMode='global';saved('台湾手动','TW-02');
    await api.applyGroupSelection('GLOBAL','直连');
    const {selected,owner}=await startup();assert.equal(selected,'TW-02');
    assert.equal(owner.kernelSelection.value.groupName,'GLOBAL');assert.equal((await state()).GLOBAL.now,'台湾手动');
  });
  await test('startup rejects an unavailable explicit pick and preserves the saved intent',async()=>{
    reset('missing-leaf');const select=api.selectNodeInGroup;
    api.selectNodeInGroup=(g,n,current)=>select.call(api,g,n,current,0);
    try {await assert.rejects(startup,/节点选择未生效/);assert.equal(settings.preferredNodeName,'missing-leaf');}
    finally {api.selectNodeInGroup=select;}
  });
  for(const mode of ['rule','global']) await test(`Smart startup keeps the group selected in ${mode} mode`,async()=>{
    reset('TW-02');settings.autoSelectMode='auto';settings.proxyMode=mode;
    saved('默认代理','直连');saved('GLOBAL','直连');saved('AI','直连');
    const result=await startup(true);const after=await state();
    assert.equal(after[mode==='global'?'GLOBAL':'默认代理'].now,'APP-SMART');
    assert.equal(result.selected,'APP-SMART');
    assert.equal(after.AI.now,'直连');assert.equal(settings.preferredNodeName,'TW-02');
  });
  await test('missing explicit leaf is rejected without changing the root to Direct',async()=>{
    const before=(await state())['默认代理'].now;
    assert.equal(await api.selectNodeInGroup('默认代理','missing-leaf',()=>true,0),false);
    assert.equal((await state())['默认代理'].now,before);
  });
  await test('selecting an automatic group preserves the policy rather than forcing one leaf',async()=>{
    assert.equal(await api.selectNodeInGroup('默认代理','香港故转'),true);
    assert.equal((await state())['默认代理'].now,'香港故转');
    assert.equal(await api.selectNodeInGroup('默认代理','HK-01',()=>true,0),false);
  });
  await test('an empty provider Compatible placeholder cannot count as a confirmed exit',async()=>{
    const empty=new context.ClashApiService();const table={ROOT:{type:'Selector',all:['empty'],now:'empty'},empty:{type:'Selector',all:['placeholder'],now:'placeholder'},placeholder:{type:'Compatible'}};
    empty.proxiesJson=async()=>JSON.stringify({proxies:table});empty.selectInGroup=async(g,n)=>{table[g].now=n;return true;};
    assert.equal(await empty.selectNodeInGroup('ROOT','empty',()=>true,0),false);
  });
  await test('endpoint and cancellation changes prevent late startup writes',async()=>{
    let current=true;const original=transport;let calls=0;
    transport=async(...args)=>{calls++;const result=await original(...args);current=false;return result;};
    assert.equal(await api.selectNodeInGroup('默认代理','台湾手动',()=>current),false);assert.equal(calls,2); // GET proxies + providers, no PUT
    transport=original;
  });
  await test('unscoped disk cache cannot force a reimported profile to Direct',async()=>{
    await api.applyGroupSelection('AI','直连');
    await api.applyGroupSelection('YouTube','直连');
    await stop();await boot();
    assert.equal((await state()).AI.now,'直连'); // reproduce the old cache, not just a mock
    await stop();
    const isolated=context.ProfileConfigMerger.enforceTunnelContract(yaml,1500,false);
    fs.writeFileSync(path.join(scratch,'config.yaml'),isolated);
    await boot();
    assert.equal((await state()).AI.now,'默认代理');
    assert.equal((await state()).YouTube.now,'默认代理');
    reset('台湾手动');saved('默认代理','台湾手动');saved('台湾手动','TW-02');saved('AI','直连');
    await startup();
    assert.equal((await state()).AI.now,'直连'); // explicit, scoped Direct remains valid
    assert.equal((await state()).YouTube.now,'默认代理');
    await stop();await boot();
    await CoreCatalogService.restoreGroupSelections(api,'another-import',settings.proxyGroupSelections);
    assert.equal((await state()).AI.now,'默认代理');
    await startup();assert.equal((await state()).AI.now,'直连');
  });
  await stop();
  console.log(`startup selection runtime: ${count} passed`);
} finally {
  if(child && child.exitCode===null){const ended=once(child,'exit');child.kill();await ended;}
  if(provider)await new Promise(r=>provider.close(r));
  // Only remove this newly-created fixture directory beneath the resolved Temp root.
  const real=fs.realpathSync(scratch),temp=fs.realpathSync(os.tmpdir());
  assert.equal(path.dirname(real).toLowerCase(),temp.toLowerCase());assert.ok(path.basename(real).startsWith('tunbox-probe-startup-selection-'));
  fs.rmSync(real,{recursive:true,force:true});
}
