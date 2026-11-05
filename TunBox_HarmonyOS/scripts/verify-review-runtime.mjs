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
const scratch = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'tunbox-probe-review-regression-'));
const helper = path.join(scratch, 'prepare.exe');
// Compile the production validator/projection, replacing only its package name.
// PrepareProfile is stricter than the actual import validator and cannot stand
// in for ValidateProfile without changing which subscriptions this gate accepts.
const nativeSource = path.join(scratch, 'profile.go');
const nativeMain = path.join(scratch, 'main.go');
fs.writeFileSync(nativeSource, fs.readFileSync(path.join(core, 'bridge/profile.go'), 'utf8').replace(/^package bridge\r?$/m, 'package main'));
fs.writeFileSync(nativeMain, `package main
import ("encoding/json"; "io"; "os"; "github.com/metacubex/mihomo/config")
func main() {
  data, _ := io.ReadAll(os.Stdin)
  reply := map[string]any{}
  var err error
  if len(os.Args) > 1 && os.Args[1] == "validate" {
    var request struct { Content, Key, Path string }
    err = json.Unmarshal(data, &request)
    if err == nil { err = ValidateProfile([]byte(request.Content), request.Key, request.Path) }
  } else if len(os.Args) > 1 && os.Args[1] == "base" {
    var out *ProfileOutbounds
    out, err = GetProfileOutbounds(string(data))
    if err == nil { reply["proxies"] = len(out.Proxies) }
  } else {
    var prepared []byte
    prepared, err = config.PrepareProfile(data)
    reply["yaml"] = string(prepared)
  }
  if err != nil { reply["error"] = err.Error() }
  _ = json.NewEncoder(os.Stdout).Encode(reply)
}
`);
const build = spawnSync('go', ['build', '-o', helper, nativeMain, nativeSource],
  {cwd:core, encoding:'utf8', timeout:180000});
assert.equal(build.status, 0, build.stderr);
const logger = {info(){},warn(){},error(){},errText:(e)=>String(e)+(e&&e.stack?String(e.stack):'')};
const http = { RequestMethod:{GET:'GET',PUT:'PUT'}, response:null, createHttp(){
  return {request(...args){return http.response ? http.response(...args) : new Promise(()=>{});},destroy(){}};
}};
// 沙箱 fs：所有路径重定向进 scratch（validateAndStore 会写 <pathOf(id)>.validate.tmp，
// VM 里 ProfileRepository.dirPath 未初始化 ⇒ 路径是盘根绝对形式，必须重定向）
const sandboxFs = new Proxy({}, {
  get(_t, prop) {
    if (prop === 'OpenMode') {
      // OHOS fileIo.OpenMode 的数字值（POSIX 同值），供 ProfileRepository 的位或表达式使用
      return { READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2, CREATE: 64, TRUNC: 512, APPEND: 1024 };
    }
    const real = fs[prop];
    if (typeof real !== 'function') {
      return real;
    }
    if (prop === 'openSync') {
      // OHOS OpenMode 数字标志 -> node 字符串标志（READ_ONLY=0/WRITE_ONLY=1/
      // READ_WRITE=2 + CREATE=64 + TRUNC=512 + APPEND=1024）
      return (...args) => {
        const mapped = args.map((x) => (typeof x === 'string' && /^([A-Za-z]:)?[\\/]/.test(x)
          ? path.join(scratch, x.replace(/[\\/:]+/g, '_')) : x));
        if (typeof mapped[1] === 'number') {
          const f = mapped[1];
          const create = (f & 64) !== 0;
          const trunc = (f & 512) !== 0;
          const append = (f & 1024) !== 0;
          const rw = (f & 3) === 2;
          const wo = (f & 3) === 1;
          mapped[1] = append ? 'a+' : (rw ? (create ? (trunc ? 'w+' : 'r+') : 'r+') : (wo ? 'w' : 'r'));
        }
        const fd = real(...mapped);
        // OHOS openSync 返回 File{fd}；node 返回数字。包一层保持调用方 .fd 可用。
        return { fd };
      };
    }
    if (prop === 'closeSync' || prop === 'fsyncSync') {
      return (...args) => {
        const mapped = args.map((x) => (x !== null && typeof x === 'object' && typeof x.fd === 'number' ? x.fd : x));
        return real(...mapped);
      };
    }
    return (...args) => {
      const mapped = args.map((x) => (typeof x === 'string' && /^([A-Za-z]:)?[\\/]/.test(x)
        ? path.join(scratch, x.replace(/[\\/:]+/g, '_')) : x));
      return real(...mapped);
    };
  },
});
const sandbox = vm.createContext({setTimeout:(fn,ms)=>setTimeout(fn,ms===30000?25:ms),clearTimeout,
  Date,Map,Set,Promise,JSON,Math,console,http,fs:sandboxFs,AppLogger:logger,
  // TunBoxLatencyService 末尾会把 recycleProbe 注册进这个静态表（模块级副作用）；
  // vm 沙箱剥掉了 import，必须自带桩，否则 ReferenceError（存量红，2026-10-26 补）。
  ConnectionOrchestrator:{testCoreBusyProbes:[],instance:()=>({})},
  LatencyTestUrl:{DEFAULT_URL:'https://www.gstatic.com/generate_204'},
  coreBridge:{ async validateProfile(content,key,target) {
      const r=spawnSync(helper,['validate'],{input:JSON.stringify({Content:content,Key:key,Path:target}),encoding:'utf8',timeout:10000});
      assert.equal(r.status,0,r.stderr);
      const reply=JSON.parse(r.stdout);
      if(reply.error) throw Error(reply.error);
    }, async getProfileBase(p){
      const r=spawnSync(helper,['base'],{input:p,encoding:'utf8',timeout:10000});
      assert.equal(r.status,0,r.stderr);
      const reply=JSON.parse(r.stdout||'{}');
      if(reply.error) throw Error(reply.error);
      return {config:{},digest:'sandbox',proxies:reply.proxies,proxyGroups:0,rules:0,matchRules:[]}; } }});
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
const {ProfileConfigMerger:M}=load('commons/tunbox/ProfileConfigMerger.ets','ProfileConfigMerger');
load('commons/subscription/UriNodeParser.ets','UriNodeParser');
load('commons/subscription/BodyDispatch.ets','BodyDispatch,BodyKind');
// 2026-11-05（FlClash 照抄）：compose 的全局依赖（import 被剥掉，符号须在沙箱）
sandbox.ClashConfigGenerator={SMART_GROUP_NAME:'♻️ 自动选择',SMART_INFO_NODE_FILTER:''};
sandbox.tunboxUserAgent=()=>'TunBox/v-harness clash-verge Platform/OpenHarmony';
const {TunBoxProfileBuilder,TunBoxProfileInput}=load('commons/tunbox/TunBoxProfileBuilder.ets','TunBoxProfileBuilder,TunBoxProfileInput');
const {SubConverter}=load('commons/tunbox/SubConverter.ets','SubConverter');
const {ProfileRepository:P}=load('commons/tunbox/ProfileRepository.ets','ProfileRepository');
P.attachPreparer(async text=>prepare(text));
P.dirPath=path.join(scratch,'profiles');
const files={get:id=>fs.existsSync(P.pathOf(id)) ? fs.readFileSync(P.pathOf(id),'utf8') : undefined};
const flow='proxies:\n  - {type: socks5, name: A, server: 127.0.0.1, port: 9}\n';
const quoted="proxies:\n  - name: 'A''B'\n    type: socks5\n    server: 127.0.0.1\n    port: 9\n";
const anchor='template: &t\n  type: socks5\n  server: 127.0.0.1\n  port: 9\nproxies:\n  - name: A\n    <<: *t\n';
const overlay='mode: rule\nrules:\n  - MATCH,PROXY\n';
await test('wrapped YAML is decoded before profile validation',async()=>{
  assert.equal((await P.validateAndStore('plain',flow)).ok,true);
  assert.equal((await P.validateAndStore('wrapped',Buffer.from(flow).toString('base64'))).ok,true);
  assert.equal(files.get('plain'),files.get('wrapped'));
});
await test('malformed YAML never overwrites the previous profile',async()=>{
  const before=files.get('plain');
  const result=await P.validateAndStore('plain','proxies: [unterminated');
  assert.equal(result.ok,false);assert.equal(files.get('plain'),before);
});
await test('native import validation preserves raw mappings; runtime validation determines dialability',async()=>{
  const raw='proxies:\n - {name: unknown, type: invalid-protocol}\n';
  assert.equal((await P.validateAndStore('raw-mapping',raw)).ok,true);
  assert.equal(files.get('raw-mapping'),raw);
});
await test('age key requests and wrong keys preserve the previous profile',async()=>{
  const before=files.get('plain');
  const encrypted='-----BEGIN AGE ENCRYPTED FILE-----\ninvalid\n-----END AGE ENCRYPTED FILE-----\n';
  const missing=await P.validateAndStore('plain',encrypted);
  assert.equal(missing.ok,false); assert.equal(missing.needAgeSecretKey,true);
  assert.equal(files.get('plain'),before);
  let saved=0; const save=P.setAgeSecretKey;
  P.setAgeSecretKey=async()=>{saved++;};
  const rejected=await P.validateAndStore('plain',encrypted,'invalid-secret-key');
  assert.equal(rejected.ok,false); assert.equal(saved,0); assert.equal(files.get('plain'),before);
  P.setAgeSecretKey=save;
});
await test('flow maps and escaped single-quoted names are accepted by the kernel validator',async()=>{
  // FlClash 照抄：合并层消失，原文经内核 UnmarshalRawConfig 校验（helper 现编同步语义）
  assert.ok((await P.validateAndStore('flow',flow)).ok);
  assert.ok((await P.validateAndStore('quoted',quoted)).ok);
});
await test('anchors are resolved by the kernel before validation',async()=>{
  // 内核解析整份文档（yaml.v3 原生支持锚点/合并键）；helper 现编同源校验
  assert.ok((await P.validateAndStore('anchor',anchor)).ok);
});
await test('nested DNS and group headers are parsed by the kernel',async()=>{
  assert.ok((await P.validateAndStore('nested',
    flow+'dns:\n  enable: true\n  nameserver:\n    - https://doh.pub/dns-query\n  nameserver-policy:\n    example.com:\n      - https://dns.alidns.com/dns-query\n')).ok);
});
await test('compose keeps explicit DNS enhanced modes verbatim (map = no duplicates)',async()=>{
  for(const mode of ['redir-host','fake-ip']) {
    const baseConfig={'proxies':[{name:'A',type:'socks5',server:'127.0.0.1',port:9}],
      'proxy-groups':[{name:'Main',type:'select',proxies:['A']}],'rules':['MATCH,Main'],
      'dns':{'enable':true,'enhanced-mode':mode,'fake-ip-range':'198.19.0.1/16','nameserver':['1.1.1.1']}};
    const r=TunBoxProfileBuilder.compose(
      {config:baseConfig,digest:'t',proxies:1,proxyGroups:1,rules:1,matchRules:['MATCH,Main']},
      {'mode':'rule'}, null,
      Object.assign(new TunBoxProfileInput(),{profileId:'t',profilePath:'/t.yaml',profilesDir:'/profiles',
       tunEnabled:true,mtu:1400}));
    const doc=JSON.parse(r.yaml);
    assert.equal(doc['dns']['enhanced-mode'],mode);
    assert.equal(doc['dns']['fake-ip-range'],'198.19.0.1/16');
  }
});
await test('profile dns enabled stays verbatim; kernel fills its own defaults',async()=>{
  // FlClash main：profile dns 启用 → 原样（不再由 App 补缺省键）；用户 filter 保留
  const baseConfig={'proxies':[{name:'A',type:'socks5',server:'127.0.0.1',port:9}],
    'proxy-groups':[{name:'Main',type:'select',proxies:['A']}],'rules':['MATCH,Main'],
    'dns':{'enable':true,'fake-ip-range':'198.19.0.1/16','fake-ip-filter':['example.com'],'nameserver':['1.1.1.1']}};
  const r=TunBoxProfileBuilder.compose(
    {config:baseConfig,digest:'t',proxies:1,proxyGroups:1,rules:1,matchRules:['MATCH,Main']},
    {'mode':'rule'}, null,
    Object.assign(new TunBoxProfileInput(),{profileId:'t',profilePath:'/t.yaml',profilesDir:'/profiles',
     tunEnabled:true,mtu:1400}));
  const doc=JSON.parse(r.yaml);
  assert.deepEqual(doc['dns']['fake-ip-filter'],['example.com']);
  assert.equal(doc['dns']['fake-ip-range'],'198.19.0.1/16');
});
await test('provider-only YAML is accepted without fetching its URL',async()=>{
  const text='proxy-providers:\n  nodes:\n    type: http\n    url: https://example.invalid/proxies\n    interval: 3600\nproxy-groups:\n - {name: Main, type: select, use: [nodes]}\nrules:\n - MATCH,Main\n';
  assert.equal((await P.validateAndStore('provider',text)).ok,true);
});
load('commons/latency/LatencyKinds.ets','LatencyProbeKind,LatencyStrategy,LatencyTimeout');
load('commons/models/AppSettings.ets','AppSettings');
const {LatencyState,LatencyRecord,LatencyChannel}=load('commons/services/LatencyState.ets','LatencyState,LatencyRecord,LatencyChannel,LatencyPolicy,LatencyContext');
const {LatencyLiveView:V}=load('commons/services/LatencyLiveView.ets','LatencyLiveView');
const {TunBoxDelayRun,DelayRequestHandle,TunBoxDelayPolicy}=load('commons/tunbox/TunBoxDelay.ets','TunBoxDelayRun,DelayTarget,DelayResult,DelayRequestHandle,TunBoxDelayPolicy,TUNBOX_DELAY_TIMED_OUT,TUNBOX_DELAY_FAILED,TUNBOX_DELAY_URL,delayTestKey');
sandbox.TunBoxDelayRun=class extends TunBoxDelayRun {
  constructor(base,secret) {
    super(base,secret,{send(){return new DelayRequestHandle(new Promise(()=>{}),()=>{});}},
      new TunBoxDelayPolicy(32,5000,20));
  }
};
const {TunBoxLatencyService:S}=load('commons/tunbox/TunBoxLatencyService.ets','TunBoxLatencyService');
const api={endpointBase:()=> 'http://127.0.0.1:9090',endpointSecret:()=>'',providerForProxy:()=>''};
await test('cancel restores the previous conclusion and clears owned spinners',async()=>{
  V.setRecord(LatencyRecord.measured('A',80,LatencyChannel.CORE,123));
  const session=S.start(api,['A','B'],'','manual');session.cancel();await session.wait();
  assert.equal(V.stateFor('A'),LatencyState.MEASURED);assert.equal(V.latencyFor('A'),80);
  assert.equal(V.stateFor('B'),LatencyState.UNTESTED);
});
await test('guard expiration clears TESTING without inventing a node timeout',async()=>{
  const session=S.start(api,['guard'],'','manual');await session.wait();
  assert.equal(V.stateFor('guard'),LatencyState.UNTESTED);
  assert.equal(V.recordFor('guard').failKind,'core_not_ready');
});
await test('an old batch cannot clear a new batch testing mark',async()=>{
  const first=S.start(api,['same'],'','manual');
  const second=S.start(api,['same'],'','manual');await first.wait();await Promise.resolve();
  assert.equal(V.stateFor('same'),LatencyState.TESTING);second.cancel();await second.wait();
});
await test('same profile with changed bytes triggers reload',async()=>{
  const h=harness();h.platform.ProfileRepository={currentId:()=> 's',exists:()=>true,revisionOf:()=> 'new'};
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
    const real=new ClashApiService();real.setEndpoint(port,'');assert.equal(await real.selectNode('A','Main'),true);
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
function subscriptionTestMethod() {
  const page=fs.readFileSync(path.join(sources,'components/SubscriptionSection.ets'),'utf8').replace(/\r\n/g,'\n');
  const start=page.indexOf('  private async testSub('),end=page.indexOf('  private openEdit(',start);
  assert.ok(start >= 0 && end > start, '必须提取现行 testSub 方法');
  return page.slice(start,end).replace('private async testSub','async testSub');
}
const progressSource=fs.readFileSync(path.join(sources,'commons/services/LatencyEngine.ets'),'utf8')
  .replace(/\r\n/g,'\n').match(/^export class LatencyProgress \{[\s\S]*?^}/m)[0];
const TestProgress=vm.runInContext(stripTypeScriptTypes(`(()=>{${progressSource.replace('export ','')}return LatencyProgress})()`,{mode:'transform'}),sandbox);
async function runSubscriptionTest(result, failure, method=subscriptionTestMethod()) {
  const messages=[];
  const progress=result===null?null:Object.assign(new TestProgress(),result);
  const pageContext=vm.createContext({getContext:()=>({}),AppLogger:logger,TAG:'test',ProfileRepository:{revisionOf:()=> 'r1'},
    BackgroundLatencyService:{async testSubscription(){if(failure)throw new Error('测速通道未就绪');return progress;}}});
  const Page=vm.runInContext(stripTypeScriptTypes(`(class {${method}})`,{mode:'transform'}),pageContext);
  const instance=new Page();Object.assign(instance,{testingIds:[],latencyRevision:0,profileRevisions:new Map(),
    isTestingSub(id){return this.testingIds.includes(id);},toast:t=>messages.push(t)});
  await instance.testSub('s','订阅');
  assert.equal(instance.testingIds.length,0);
  assert.equal(instance.latencyRevision,1);
  return messages;
}
await test('订阅区测速通道失败时显示失败提示，不伪报完成',async()=>{
  assert.deepEqual(await runSubscriptionTest(null,true),['测速失败，请重试']);
});
await test('订阅区跳过测速不伪报完成，并以负对照验证守卫',async()=>{
  assert.deepEqual(await runSubscriptionTest(null,false),['测速未执行，请稍后重试']);
  const broken=subscriptionTestMethod().replace(/if \(progress === null\) \{[\s\S]*?\n      \}/,'');
  assert.notEqual(broken,subscriptionTestMethod());
  assert.deepEqual(await runSubscriptionTest(null,false,broken),['测速失败，请重试']);
});
await test('订阅区完成统计保留真实超时与失败分类',async()=>{
  assert.deepEqual(await runSubscriptionTest({total:11,finished:11,measured:0,timeout:5,failed:6,cancelled:0,message:''},false),['测速完成：0成功，5超时，6失败']);
});
await test('完成提示不把个别缺回复说成整批中断，显式取消与准备失败仍单独提示',async()=>{
  assert.deepEqual(await runSubscriptionTest({total:2,finished:2,measured:1,timeout:0,failed:1,cancelled:0,skipped:8,message:''},false),
    ['测速完成：1成功，0超时，1失败']);
  const partial={total:2,finished:2,measured:1,timeout:0,failed:0,cancelled:1,message:''};
  const expected=['测速结束：1成功，0超时，1项未取得结果，请重试'];
  assert.deepEqual(await runSubscriptionTest(partial,false),expected);
  assert.deepEqual(await runSubscriptionTest({...partial,wasCancelled:true},false),['本次测速已取消，已完成的结果已保留']);
  assert.deepEqual(await runSubscriptionTest({...partial,message:'测速通道未就绪'},false),['测速通道未就绪']);
  const broken=subscriptionTestMethod().replace('this.toast(progress.completionMessage());',
    "if(progress.cancelled > 0){this.toast('测速通道已中断，请重试');return;}this.toast(progress.completionMessage());");
  assert.notEqual(broken,subscriptionTestMethod());
  const messages=await runSubscriptionTest(partial,false,broken);
  assert.throws(()=>assert.deepEqual(messages,expected),'negative control must reject the previous blanket interruption');
});
console.log(`ALL PASS ${count} review regression cases`);
// Only this test's verified direct scratch directory may be removed.
if(path.dirname(fs.realpathSync(scratch))===fs.realpathSync(os.tmpdir())&&path.basename(scratch).startsWith('tunbox-probe-review-regression-'))fs.rmSync(scratch,{recursive:true});
