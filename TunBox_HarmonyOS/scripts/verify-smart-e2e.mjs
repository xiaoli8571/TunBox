#!/usr/bin/env node
// Run current production composition and real Smart routing against a local
// HTTP origin. No subscription, public endpoint, or synthesized Smart policy.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import net from 'node:net';
import { once } from 'node:events';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const file = fileURLToPath(import.meta.url);
if (!process.execArgv.includes('--experimental-transform-types')) {
  const result = spawnSync(process.execPath, ['--experimental-transform-types', '--no-warnings', file, ...process.argv.slice(2)], {stdio:'inherit'});
  process.exit(result.status ?? 1);
}
const root = path.resolve(path.dirname(file), '..');
const prepared = spawnSync(process.execPath, [path.join(root,'tools/true-chain-harness/prepare.mjs')], {encoding:'utf8'});
assert.equal(prepared.status,0,prepared.stderr);
const generated = name => pathToFileURL(path.join(root,'tools/true-chain-harness/generated',`${name}.ts`));
const { TunBoxProfileBuilder, TunBoxBaseData, TunBoxProfileInput } = await import(generated('TunBoxProfileBuilder'));
const { ClashConfigGenerator } = await import(generated('ClashConfigGenerator'));
const { AppSettings } = await import(generated('AppSettings'));
const { ProxyNode } = await import(generated('ProxyNode'));
const { miniYamlParse } = await import('./fixtures/mini-yaml.mjs');
const kernel = process.argv.includes('--kernel') ? process.argv[process.argv.indexOf('--kernel')+1]
  : path.join(root,'../mihomo-build/mihomo-smart-462455136157a760937c666bba71afe33b1a809e/mihomo.exe');
assert.ok(kernel && fs.existsSync(kernel),'same-source kernel is required');
const { smartModelFixture } = await import('./fixtures/smart-model.mjs');
const model = smartModelFixture();
assert.equal(fs.existsSync(path.join(root,'entry/src/main/resources/rawfile/Model.bin')),false,'models must not be bundled');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(),'tunbox-probe-smart-e2e-'));
const groupName = '♻️ 自动选择';
const nodes = ['Node A','Node B'].map((name,index) => Object.assign(new ProxyNode(),{
  id:`fixture-${index}`,name,originalName:name,proxyType:'socks5',server:'127.0.0.1',port:9
}));
const delay = ms => new Promise(resolve => setTimeout(resolve,ms));
let passed = 0;
const pass = name => {passed++; console.log(`PASS ${name}`);};
async function freePort() {
  const server = http.createServer(); server.listen(0,'127.0.0.1'); await once(server,'listening');
  const port = server.address().port; await new Promise(resolve => server.close(resolve)); return port;
}
async function json(url) {
  const response = await fetch(url,{signal:AbortSignal.timeout(2000)});
  assert.equal(response.status,200,await response.clone().text()); return response.json();
}
try {
  for (const mode of ['auto','manual']) {
    const settings = new AppSettings(); settings.autoSelectMode=mode;
    const yaml = ClashConfigGenerator.generate(nodes[0],nodes,settings,17890,19090,1053,'fixture',false,false,{},false,[],true);
    const doc = miniYamlParse(yaml);
    assert.ok(!doc['proxy-groups'].some(g => g.type==='smart'));
    pass(`legacy ${mode} mode does not synthesize a Smart group`);
  }
  for (const [type,lightgbm] of [['smart',true],['smart',false],['url-test',false],['app-smart',true],['app-provider',true]]) {
    const appSmart=type.startsWith('app-');
    const smartType=type!=='url-test';
    const dir = path.join(scratch,`${type}-${lightgbm}`); fs.mkdirSync(dir);
    if (lightgbm) fs.copyFileSync(model,path.join(dir,'Model.bin'));
    let held = null;
    const origin = http.createServer((req,res) => {
      if (req.url.endsWith('/hold')) {held=res; res.writeHead(200); res.write('hold');}
      else {setTimeout(() => {res.writeHead(204); res.end();},8);}
    });
    origin.listen(0,'127.0.0.1'); await once(origin,'listening');
    const originPort = origin.address().port, apiPort=await freePort(), mixedPort=await freePort();
    origin.on('connect',(request,socket,head)=>{
      if(request.url!==`127.0.0.1:${originPort}`) {socket.destroy();return;}
      const upstream=net.connect(originPort,'127.0.0.1',()=>{
        socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        if(head.length) upstream.write(head);
        upstream.pipe(socket);socket.pipe(upstream);
      });
      upstream.on('error',()=>socket.destroy());socket.on('error',()=>upstream.destroy());
      socket.on('close',()=>upstream.destroy());
    });
    const url = `http://127.0.0.1:${originPort}/generate_204`;
    const policy = {name:groupName,type,proxies:['Node A','Node B'],url,interval:0};
    if (type==='smart') Object.assign(policy,{uselightgbm:lightgbm,collectdata:false,'prefer-asn':false});
    let document;
    for (const mode of (appSmart ? ['auto'] : ['auto','manual'])) {
      const base = new TunBoxBaseData();
      base.config={proxies:[{name:'Node A',type:'direct'},{name:'Node B',type:'direct'}],'proxy-groups':[policy],rules:[`MATCH,${groupName}`]};
      if(appSmart) {
        const pool=['Node A','Node B'].map(name=>({name,type:'http',server:'127.0.0.1',port:originPort}));
        base.config={proxies:pool,'proxy-groups':[{name:'ROOT',type:'select',proxies:pool.map(node=>node.name)}],rules:['MATCH,ROOT']};
        if(type==='app-provider') base.config={
          'proxy-providers':{airport:{type:'inline',payload:pool}},
          'proxy-groups':[{name:'ROOT',type:'select',use:['airport']}],rules:['MATCH,ROOT']};
      }
      base.proxies=2; base.proxyGroups=1; base.rules=1; base.matchRules=[`MATCH,${groupName}`];
      const input = new TunBoxProfileInput();
      Object.assign(input,{profileId:'fixture',profilePath:path.join(dir,'profile.yaml'),profilesDir:dir,tunEnabled:false});
      input.useSmart=appSmart;input.smartTestUrl=url;
      const settings=new AppSettings(); settings.autoSelectMode=mode; settings.hyperAdRulesEnabled=false; settings.customRules=[];
      const overlay=miniYamlParse(ClashConfigGenerator.generate(
        nodes[0],nodes,settings,mixedPort,apiPort,1053,'',false,false,{},
        false,[],false,[],'',[],[],false));
      overlay.dns={enable:false}; overlay.sniffer={enable:false}; overlay['log-level']='info';
      const result=TunBoxProfileBuilder.compose(base,overlay,null,input);
      assert.equal(result.ok,true,result.error); document=JSON.parse(result.yaml);
      if(appSmart) {
        assert.equal(result.smartGroupName,groupName);
        assert.equal(result.smartParentGroupName,'ROOT');
        assert.equal(document['proxy-groups'].find(group=>group.name==='ROOT').proxies[0],groupName);
      } else assert.deepEqual(document['proxy-groups'],[policy]);
      pass(`${type} LightGBM=${lightgbm} policy preserved in ${mode} mode`);
    }
    const config=path.join(dir,'config.json'); fs.writeFileSync(config,JSON.stringify(document));
    const child=spawn(kernel,['-d',dir,'-f',config],{windowsHide:true,stdio:['ignore','pipe','pipe']});
    const exited=once(child,'exit'); let logs='';
    child.stdout.on('data',data=>logs+=data); child.stderr.on('data',data=>logs+=data);
    let request;
    try {
      const api=`http://127.0.0.1:${apiPort}`;
      let table;
      for (let i=0;i<50;i++) {
        try {table=await json(`${api}/proxies`);break;} catch(error) {
          if (child.exitCode!==null || i===49) throw Error(`${error.message}\n${logs}`);
          await delay(100);
        }
      }
      assert.equal(String(table.proxies[groupName].type).toLowerCase(),smartType?'smart':'urltest');
      const measured=await json(`${api}/proxies/${encodeURIComponent(groupName)}/delay?timeout=3000&url=${encodeURIComponent(url)}`);
      assert.ok(Number.isFinite(measured.delay) && measured.delay>=0);
      pass(`real ${type} LightGBM=${lightgbm} group URLTest returns a delay`);
      request=http.get({host:'127.0.0.1',port:mixedPort,path:`http://127.0.0.1:${originPort}/hold`,
        headers:{Host:`127.0.0.1:${originPort}`},agent:false,timeout:5000});
      request.on('timeout',()=>request.destroy(Error('mixed-port request timed out')));
      request.on('error',()=>{});
      const [response]=await once(request,'response'); response.resume(); assert.equal(response.statusCode,200);
      const connections=await json(`${api}/connections`);
      assert.ok(connections.connections.some(c=>c.chains.includes(groupName) && c.chains.some(n=>['Node A','Node B'].includes(n))));
      if (smartType) {
        const connsPath=path.join(dir,'connections.json'),proxiesPath=path.join(dir,'proxies.json');
        fs.writeFileSync(connsPath,JSON.stringify(connections)); fs.writeFileSync(proxiesPath,JSON.stringify(table));
        const replay=spawnSync(process.execPath,[path.join(root,'scripts/verify-smart-active-chains.mjs'),connsPath,proxiesPath],{encoding:'utf8'});
        assert.equal(replay.status,0,`${replay.stdout}\n${replay.stderr}`);
      }
      pass(`real ${type} LightGBM=${lightgbm} traffic records its selected node and group`);
      assert.ok(!/start download|Can't find Model.bin|Can't find MMDB/i.test(logs),logs);
      if (lightgbm) assert.match(logs,/Model file loaded successfully/);
      else assert.equal(fs.existsSync(path.join(dir,'Model.bin')),false);
      pass(`${type} LightGBM=${lightgbm} starts without resource downloads`);
    } finally {
      request?.destroy(); held?.end(); origin.closeAllConnections();
      await new Promise(resolve=>origin.close(resolve));
      child.kill(); await exited;
    }
  }
  console.log(`RESULT: ${passed} passed; local real-kernel routing, not device Smart acceptance`);
} finally {
  fs.rmSync(scratch,{recursive:true,force:true});
}
