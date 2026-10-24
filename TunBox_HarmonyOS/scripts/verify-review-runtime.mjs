// Regression tests for the 2026-10-23 subscription -> delay -> VPN review.
// Run production ArkTS through Node; replace HarmonyOS boundaries only.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { stripTypeScriptTypes } from 'node:module';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { harness } from './orchestrator-runtime-harness.mjs';
const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sources = path.join(project, 'entry/src/main/ets');
const core = path.join(project, '../mihomo-build/mihomo-smart-462455136157a760937c666bba71afe33b1a809e');
const scratch = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'tunbox-review-regression-'));
const helper = path.join(scratch, 'prepare.exe');
const build = spawnSync('go', ['build', '-o', helper, path.join(project, 'scripts/fixtures/profile-prepare/main.go')],
  {cwd:core, encoding:'utf8', timeout:180000});
assert.equal(build.status, 0, build.stderr);
const logger = {info(){},warn(){},error(){},errText:String};
const http = { RequestMethod:{GET:'GET',PUT:'PUT'}, response:null, createHttp(){
  return {request(...args){return http.response ? http.response(...args) : new Promise(()=>{});},destroy(){}};
}};
const sandbox = vm.createContext({setTimeout:(fn,ms)=>setTimeout(fn,ms===30000?25:ms),clearTimeout,
  Date,Map,Set,Promise,JSON,Math,console,http,AppLogger:logger,
  LatencyTestUrl:{DEFAULT_URL:'https://www.gstatic.com/generate_204'}});
function load(file, exports) {
  const code=fs.readFileSync(path.join(sources,file),'utf8').replace(/^import\b[\s\S]*?;\r?\n/gm,'').replace(/^export /gm,'');
  const result=vm.runInContext(stripTypeScriptTypes(`(()=>{${code}\nreturn {${exports}}})()`,{mode:'transform'}),sandbox);
  Object.assign(sandbox,result);return result;
}
function prepare(text) {
  const result=spawnSync(helper,[],{input:text,encoding:'utf8',timeout:10000});
  assert.equal(result.status,0,result.stderr);
  const reply=JSON.parse(result.stdout);
  if(reply.error)throw Error(reply.error);
  return reply.yaml;
}
let count=0;
async function test(name, run){await run();count++;console.log('PASS '+name);}
load('commons/services/YamlMerger.ets','YamlMerger');
const {ProfileConfigMerger:M}=load('commons/flclash/ProfileConfigMerger.ets','ProfileConfigMerger');
load('commons/subscription/UriNodeParser.ets','UriNodeParser');
load('commons/subscription/BodyDispatch.ets','BodyDispatch,BodyKind');
const {SubConverter}=load('commons/flclash/SubConverter.ets','SubConverter');
const {ProfileStore:P}=load('commons/flclash/ProfileStore.ets','ProfileStore');
P.attachConverter(text=>SubConverter.convert(text).proxiesYaml);
P.attachPreparer(async text=>prepare(text));
const files=new Map(); P.write=(id,text)=>{files.set(id,text);return true;};
const flow='proxies:\n  - {type: socks5, name: A, server: 127.0.0.1, port: 9}\n';
const quoted="proxies:\n  - name: 'A''B'\n    type: socks5\n    server: 127.0.0.1\n    port: 9\n";
const anchor='template: &t\n  type: socks5\n  server: 127.0.0.1\n  port: 9\nproxies:\n  - name: A\n    <<: *t\n';
const overlay='mode: rule\nrules:\n  - MATCH,PROXY\n';
await test('wrapped YAML is decoded before profile validation',async()=>{
  assert.equal((await P.validateAndStore('plain',flow)).ok,true);
  assert.equal((await P.validateAndStore('wrapped',Buffer.from(flow).toString('base64'))).ok,true);
  assert.equal(files.get('plain'),files.get('wrapped'));
});
await test('invalid outbound never overwrites the previous profile',async()=>{
  const before=files.get('plain');
  const result=await P.validateAndStore('plain','proxies:\n - {name: broken, type: invalid-protocol}\n');
  assert.equal(result.ok,false);assert.equal(files.get('plain'),before);
});
await test('flow maps and escaped single-quoted names get valid group references',async()=>{
  assert.ok(M.withSyntheticGroups(flow).includes('proxy-groups:'));
  assert.ok(M.withSyntheticGroups(quoted).includes("A''B"));
  for(const yaml of [flow,quoted]){const merged=M.merge(overlay,prepare(yaml));assert.equal(merged.ok,true);prepare(merged.yaml);}
});
await test('anchors are resolved in the whole document before section merge',async()=>{
  const normalized=prepare(anchor);assert.ok(!normalized.includes('*t'));
  assert.ok(M.merge(overlay,normalized).ok);prepare(M.merge(overlay,normalized).yaml);
});
await test('nested DNS and group headers keep their relative indentation',async()=>{
  const profile=prepare(flow+'dns:\n  enable: true\n  nameserver:\n    - https://doh.pub/dns-query\n  nameserver-policy:\n    example.com:\n      - https://dns.alidns.com/dns-query\n');
  prepare(M.merge(overlay,profile).yaml);
});
await test('explicit DNS enhanced modes are preserved without duplicate defaults',async()=>{
  for(const mode of ['redir-host','fake-ip']) {
    const profile=prepare(flow+`dns:\n  enable: true\n  enhanced-mode: ${mode}\n  fake-ip-range: 198.19.0.1/16\n  nameserver: [1.1.1.1]\n`);
    const merged=M.merge(overlay,profile);assert.equal(merged.ok,true);
    assert.equal((merged.yaml.match(/^  enhanced-mode:/gm)||[]).length,1);
    assert.ok(merged.yaml.includes(`enhanced-mode: ${mode}`));
    assert.equal((merged.yaml.match(/^  fake-ip-range:/gm)||[]).length,1);
    assert.ok(merged.yaml.includes('198.19.0.1/16'));prepare(merged.yaml);
  }
});
await test('missing DNS mode adds only missing defaults and keeps the user filter',async()=>{
  const profile=prepare(flow+'dns:\n  enable: true\n  fake-ip-range: 198.19.0.1/16\n  fake-ip-filter: [example.com]\n  nameserver: [1.1.1.1]\n');
  const merged=M.merge(overlay,profile);assert.equal(merged.ok,true);
  for(const key of ['enhanced-mode','fake-ip-range','fake-ip-filter']){
    assert.equal((merged.yaml.match(new RegExp('^  '+key+':','gm'))||[]).length,1);
  }
  assert.ok(merged.yaml.includes('enhanced-mode: fake-ip'));assert.ok(merged.yaml.includes('example.com'));prepare(merged.yaml);
});
await test('provider-only YAML is accepted without fetching its URL',async()=>{
  const text='proxy-providers:\n  nodes:\n    type: http\n    url: https://example.invalid/proxies\n    interval: 3600\nproxy-groups:\n - {name: Main, type: select, use: [nodes]}\nrules:\n - MATCH,Main\n';
  assert.equal((await P.validateAndStore('provider',text)).ok,true);
});
load('commons/latency/LatencyKinds.ets','LatencyProbeKind,LatencyStrategy,LatencyTimeout');
const {LatencyState,LatencyRecord,LatencyChannel}=load('commons/services/LatencyState.ets','LatencyState,LatencyRecord,LatencyChannel,LatencyPolicy');
const {LatencyLiveView:V}=load('commons/services/LatencyLiveView.ets','LatencyLiveView');
load('commons/flclash/FlclashDelay.ets','FlclashDelayRun,DelayTarget,FLCLASH_DELAY_TIMED_OUT,FLCLASH_DELAY_FAILED,FLCLASH_DELAY_URL,delayTestKey');
const {FlclashLatencyService:S}=load('commons/flclash/FlclashLatencyService.ets','FlclashLatencyService');
const api={endpointBase:()=> 'http://127.0.0.1:9090',endpointSecret:()=>''};
await test('cancel restores the previous conclusion and clears owned spinners',async()=>{
  V.setRecord(LatencyRecord.measured('A',80,LatencyChannel.CORE,123));
  const session=S.start(api,['A','B'],'','manual');session.cancel();await session.wait();
  assert.equal(V.stateFor('A'),LatencyState.MEASURED);assert.equal(V.latencyFor('A'),80);
  assert.equal(V.stateFor('B'),LatencyState.UNTESTED);
});
await test('guard expiration clears TESTING without inventing a timeout',async()=>{
  const session=S.start(api,['guard'],'','manual');await session.wait();
  assert.equal(V.stateFor('guard'),LatencyState.UNTESTED);
});
await test('an old batch cannot clear a new batch testing mark',async()=>{
  const first=S.start(api,['same'],'','manual');
  const second=S.start(api,['same'],'','manual');await first.wait();await Promise.resolve();
  assert.equal(V.stateFor('same'),LatencyState.TESTING);second.cancel();await second.wait();
});
await test('same profile with changed bytes triggers reload',async()=>{
  const h=harness();h.platform.ProfileStore={currentId:()=> 's',exists:()=>true,revisionOf:()=> 'new'};
  h.orch.appliedProfileId='s';h.orch.appliedProfileRevision='old';let reloads=0;
  h.orch.applyRulesChanged=async()=>{reloads++;return 'hot';};
  assert.equal(await h.orch.ensureProfileApplied('refresh'),true);assert.equal(reloads,1);h.stop();
});
await test('an empty App node table does not block a valid profile test core',async()=>{
  const h=harness();h.subs.nodes=[];h.subs.hasUsableProfile=()=>true;h.orch.state=h.ConnState.DISCONNECTED;
  h.orch.ensureTestCore=async()=>true;h.orch.awaitTestCoreWarmup=async()=>{};
  h.orch.lastSettingsForLatency=async()=>({});h.orch.scheduleTestCoreRecycle=()=>{};
  assert.ok(await h.orch.ensureLatencyApi());h.stop();
});
const {ClashApiService}=load('commons/services/ClashApiService.ets','ClashApiService');
await test('real Mihomo selection pins nested rule-facing groups and verifies them',async()=>{
  const portServer=net.createServer();await new Promise(r=>portServer.listen(0,'127.0.0.1',r));
  const port=portServer.address().port;await new Promise(r=>portServer.close(r));
  const text=`external-controller: 127.0.0.1:${port}\nmode: rule\nlog-level: error\nproxies:\n - {name: A, type: socks5, server: 127.0.0.1, port: 9}\n - {name: B, type: socks5, server: 127.0.0.1, port: 10}\nproxy-groups:\n - {name: Aux, type: select, proxies: [B, A]}\n - {name: Main, type: select, proxies: [DIRECT, Aux]}\nrules:\n - MATCH,Main\n`;
  const file=path.join(scratch,'live.yaml');fs.writeFileSync(file,text);
  const child=spawn(path.join(core,'mihomo.exe'),['-d',scratch,'-f',file],{windowsHide:true,stdio:'ignore'});
  try{
    let ready=false;for(let i=0;i<100;i++){try{if((await fetch(`http://127.0.0.1:${port}/version`)).ok){ready=true;break;}}catch{}await new Promise(r=>setTimeout(r,50));}assert.ok(ready);
    http.response=async(url,options)=>{const r=await fetch(url,{method:options.method,headers:options.header,body:options.extraData});return {responseCode:r.status,result:await r.text()};};
    const real=new ClashApiService();real.setEndpoint(port,'');assert.equal(await real.selectNode('A'),true);
    const state=await (await fetch(`http://127.0.0.1:${port}/proxies`)).json();
    assert.equal(state.proxies.Main.now,'Aux');assert.equal(state.proxies.Aux.now,'A');
    assert.equal(await real.selectNode('does-not-exist'),false);
  }finally{child.kill();await new Promise(r=>child.once('exit',r));http.response=null;}
});
await test('manual delay can start a headless core for a confirmed abandoned session',async()=>{
  const h=harness();h.orch.state=h.ConnState.DISCONNECTED;
  h.orch.authorityState=async()=>({connected:false,coreAlive:false,reason:'core-exited'});
  h.orch.restoreTunnelController=async()=>true;
  h.orch.api.probeController=async()=>({reachable:false});
  const pending=h.orch.ensureTestCore(h.subs,{},true);
  for(let i=0;i<100;i++)await Promise.resolve();
  for(const timer of h.timers.values())if(timer.delay===250)timer.fn();
  assert.equal(await pending,true);assert.equal(h.testCoreStarts,1);
  assert.equal(h.snapshot.desiredConnected,true);h.stop();
});
await test('manual delay does not replace a responding controller with the wrong credential',async()=>{
  const h=harness();h.orch.state=h.ConnState.DISCONNECTED;
  h.orch.authorityState=async()=>({connected:false,coreAlive:false,reason:'core-exited'});
  h.orch.restoreTunnelController=async()=>true;h.orch.api.probeController=async()=>({reachable:true});
  assert.equal(await h.orch.ensureTestCore(h.subs,{},true),false);assert.equal(h.testCoreStarts,0);h.stop();
});
await test('the actual subscription page never reports completion for a skipped batch',async()=>{
  const page=fs.readFileSync(path.join(sources,'pages/SubscriptionPage.ets'),'utf8');
  const start=page.indexOf('  private async speedTestSub('),end=page.indexOf('\n  /**',start);
  const method=page.slice(start,end).replace('private async speedTestSub','async speedTestSub');
  const messages=[];
  const pageContext=vm.createContext({getContext:()=>({}),AppLogger:logger,
    BackgroundLatencyService:{async testSubscription(){return null;}}});
  const Page=vm.runInContext(stripTypeScriptTypes(`(class {${method}})`,{mode:'transform'}),pageContext);
  const instance=new Page();Object.assign(instance,{speedTestingIds:[],showToast:t=>messages.push(t),
    async activateProfile(){},refreshCoreNodes(){}});
  await instance.speedTestSub('s');assert.ok(messages.some(t=>t.includes('未开始测速')));
  assert.ok(!messages.some(t=>t.includes('测速完成')));
});
await test('mixed node failures complete without classification or timeout-count prompts',async()=>{
  const page=fs.readFileSync(path.join(sources,'pages/SubscriptionPage.ets'),'utf8');
  const start=page.indexOf('  private async speedTestSub('),end=page.indexOf('\n  /**',start);
  const method=page.slice(start,end).replace('private async speedTestSub','async speedTestSub');
  const messages=[];let persisted=0;
  const pageContext=vm.createContext({getContext:()=>({}),AppLogger:logger,
    BackgroundLatencyService:{async testSubscription(){return {total:11,measured:0,timeout:5,failed:6,coreOverloaded:0};}},
    LatencyStoreBridge:{async persistConclusions(){persisted++;}}});
  const Page=vm.runInContext(stripTypeScriptTypes(`(class {${method}})`,{mode:'transform'}),pageContext);
  const instance=new Page();Object.assign(instance,{speedTestingIds:[],coreNodes:[{name:'failed-node'}],
    showToast:t=>messages.push(t),async activateProfile(){},refreshCoreNodes(){}});
  await instance.speedTestSub('s');assert.equal(persisted,1);
  assert.deepEqual(messages,['准备测速通道…','✓ 测速完成']);
});
console.log(`ALL PASS ${count} review regression cases`);
// Only this test's verified direct scratch directory may be removed.
if(path.dirname(fs.realpathSync(scratch))===fs.realpathSync(os.tmpdir())&&path.basename(scratch).startsWith('tunbox-review-regression-'))fs.rmSync(scratch,{recursive:true});
