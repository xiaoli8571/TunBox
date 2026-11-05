#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const file = fileURLToPath(import.meta.url);
if (!process.execArgv.includes('--experimental-transform-types')) {
  const child = spawnSync(process.execPath, ['--experimental-transform-types','--no-warnings',file], {stdio:'inherit'});
  process.exit(child.status ?? 1);
}
const root = path.resolve(path.dirname(file),'..');
const prepared = spawnSync(process.execPath,[path.join(root,'tools/true-chain-harness/prepare.mjs')],{encoding:'utf8'});
assert.equal(prepared.status,0,prepared.stderr);
const { TunBoxProfileBuilder, TunBoxBaseData, TunBoxProfileInput } = await import(
  pathToFileURL(path.join(root,'tools/true-chain-harness/generated/TunBoxProfileBuilder.ts')));
const generated = name => pathToFileURL(path.join(root,'tools/true-chain-harness/generated',`${name}.ts`));
const { AppSettings, AutoSelectModes } = await import(generated('AppSettings'));
const { ProxyNode } = await import(generated('ProxyNode'));
const smartName = '♻️ 自动选择';
const nodes = ['🇯🇵 日本01','🇭🇰 香港01'].map(name=>({name,type:'http',server:'127.0.0.1',port:9}));
const policy = type => ({name:smartName,type,proxies:nodes.map(n=>n.name),
  url:'https://www.gstatic.com/generate_204',interval:300,
  ...(type==='smart'?{uselightgbm:true,collectdata:false,'prefer-asn':false}:{})});
const rootGroup = {name:'ROOT',type:'select',proxies:nodes.map(n=>n.name)};
const cases = [
  ['ordinary selector',{proxies:nodes,'proxy-groups':[rootGroup],rules:['MATCH,ROOT']}],
  ['direct catchall',{proxies:nodes,'proxy-groups':[rootGroup],rules:['MATCH,DIRECT']}],
  ['without catchall',{proxies:nodes,'proxy-groups':[rootGroup],rules:['DOMAIN,x.example,ROOT']}],
  ['same-name URLTest',{proxies:nodes,'proxy-groups':[policy('url-test')],rules:[`MATCH,${smartName}`]}],
  ['genuine Smart',{proxies:nodes,'proxy-groups':[
    {...rootGroup,proxies:[smartName,...rootGroup.proxies]},policy('smart')],rules:['MATCH,ROOT']}],
  ['provider Smart',{'proxy-providers':{airport:{type:'inline',payload:nodes}},
    'proxy-groups':[{name:smartName,type:'smart',use:['airport'],uselightgbm:false}],rules:[`MATCH,${smartName}`]}],
  ['automatic catchall with unrelated selector',{proxies:nodes,'proxy-groups':[
    rootGroup,policy('url-test')],rules:['DOMAIN,x.example,ROOT',`MATCH,${smartName}`]}],
  ['explicit GLOBAL',{proxies:nodes,'proxy-groups':[rootGroup,{...rootGroup,name:'GLOBAL'}],rules:['MATCH,ROOT']}],
  ['leaf catchall',{proxies:nodes,rules:[`MATCH,${nodes[0].name}`]}]
];
let count=0;
for (const [name,config] of cases) {
  for (const useSmart of [false,true]) {
    const base = new TunBoxBaseData();
    Object.assign(base,{config:structuredClone(config),proxies:config.proxies?.length??0,
      proxyGroups:config['proxy-groups']?.length??0,rules:config.rules?.length??0,
      matchRules:config.rules?.filter(r=>r.startsWith('MATCH,'))??[]});
    const input = new TunBoxProfileInput();
    Object.assign(input,{profileId:'fixture',profilePath:'/profiles/fixture.yaml',profilesDir:'/profiles',
      useSmart});
    const result=TunBoxProfileBuilder.compose(base,{},null,input);
    assert.equal(result.ok,true,result.error);
    const doc=JSON.parse(result.yaml);
    assert.deepEqual(doc.proxies??[],config.proxies??[]);
    if (!useSmart) {
      assert.deepEqual(doc['proxy-groups']??[],config['proxy-groups']??[]);
      assert.deepEqual(doc.rules??[],config.rules??[]);
      assert.equal(result.smartGroupName,'');
    } else {
      const groups=doc['proxy-groups'];
      const smart=groups.find(group=>group.name===result.smartGroupName);
      assert.equal(smart.type,'smart'); assert.equal(smart.uselightgbm,true);
      assert.equal(smart.timeout,5000);
      assert.equal(new Set(groups.map(group=>group.name)).size,groups.length);
      assert.ok(groups.find(group=>group.name===result.smartParentGroupName).proxies.includes(smart.name));
      const originalSmart=config['proxy-groups']?.find(group=>group.name===smartName);
      if(originalSmart) assert.deepEqual(groups.find(group=>group.name===smartName),originalSmart);
      if(config['proxy-providers']) assert.deepEqual(smart.use,['airport']);
      assert.equal(doc.rules.filter(rule=>rule.endsWith(',DIRECT')).length,
        config.rules.filter(rule=>rule.endsWith(',DIRECT')).length);
      const global=groups.find(group=>group.name==='GLOBAL');
      if(global) assert.ok(global.proxies.includes(smart.name));
    }
    count++;console.log(`PASS ${name}: Smart=${useSmart}`);
  }
}
const noProxy={proxies:[{name:'local',type:'direct'},{name:'blocked',type:'reject'}],
  'proxy-groups':[rootGroup],rules:['MATCH,ROOT']};
assert.equal(TunBoxProfileBuilder.smartAvailable(noProxy),false);
count++; console.log('PASS direct/reject aliases cannot enter the automatic pool');
const runtimeSource=fs.readFileSync(path.join(root,'entry/src/main/ets/commons/config/RuntimeConfigBuilder.ets'),'utf8')
  .replace(/^import\b[\s\S]*?;\r?\n/gm,'').replace(/^export /gm,'');
const context=vm.createContext({AppSettings,AutoSelectModes,ProxyNode,BASE_MTU:1500});
const {RuntimeConfigBuilder,RuntimeConfigProfile}=vm.runInContext(stripTypeScriptTypes(
  `(()=>{${runtimeSource};return {RuntimeConfigBuilder,RuntimeConfigProfile};})()`,{mode:'transform'}),context);
for(const [mode,ready,scope,profile,expected] of [
  ['auto',true,'a','a',true],['manual',true,'a','a',false],['auto',false,'a','a',false],
  ['auto',true,'a','b',false],['auto',true,'','',false]]) {
  const input=new RuntimeConfigProfile();input.settings.autoSelectMode=mode;
  input.settings.preferredNodeSubscriptionId=scope;input.smartModelReady=ready;input.profileId=profile;
  assert.equal(RuntimeConfigBuilder.decideRuntimeOptions(input).useSmart,expected);
  count++;console.log(`PASS decision ${mode}, ready=${ready}, scope=${scope}, profile=${profile}`);
}
for(const value of [undefined,0,500,2000,8000,NaN]) {
  assert.equal(AppSettings.normalizeDelayTestTimeout(value),5000);
  const settings=new AppSettings();settings.delayTestTimeout=value;
  assert.equal(settings.toJson().delayTestTimeout,5000);
}
count++; console.log('PASS settings and backup serialization always normalize to 5000ms');
console.log(`RESULT: ${count} passed, 0 failed`);
