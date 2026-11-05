// Execute production model download/readiness/delete and both UI entry gates.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const file=fileURLToPath(import.meta.url);
if(!process.execArgv.includes('--experimental-transform-types')){
  process.exit(spawnSync(process.execPath,['--experimental-transform-types','--no-warnings',file],{stdio:'inherit'}).status ?? 1);
}
const root=path.resolve(path.dirname(file),'..'), ets=path.join(root,'entry/src/main/ets');
const source=fs.readFileSync(path.join(ets,'commons/services/ConnectionOrchestrator.ets'),'utf8');
const read=name=>fs.readFileSync(path.join(ets,name),'utf8');
const method=(text,name)=>{
  const hit=text.match(new RegExp(`^  (?:private )?(?:static )?(?:async )?${name}\\([\\s\\S]*?^  }`,'m'));
  assert.ok(hit,`production method ${name}`);return hit[0];
};
const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'tunbox-probe-manual-model-'));
const bytes=Buffer.alloc(1024*1024+17);bytes.write('tree');
const asArrayBuffer=buffer=>Uint8Array.from(buffer).buffer;
const storage=new Map();let requests=[],proxy=false,response='ok',hold=null;
const io={
  ...fs,accessSync:fs.existsSync,
  OpenMode:{READ_ONLY:fs.constants.O_RDONLY,READ_WRITE:fs.constants.O_RDWR,CREATE:fs.constants.O_CREAT,TRUNC:fs.constants.O_TRUNC},
  openSync:(file,flags)=>({fd:fs.openSync(file,flags)}),closeSync:file=>fs.closeSync(file.fd),
  readSync:(fd,buf)=>fs.readSync(fd,Buffer.from(buf),0,buf.byteLength,null),
  writeSync:(fd,buf)=>fs.writeSync(fd,Buffer.from(buf))
};
const context=vm.createContext({fs:io,Uint8Array,ArrayBuffer,Map,Date,Math,
  privateFs:{writePrivate:(file,text)=>fs.writeFileSync(file,text,{mode:0o600})},
  AppLogger:{info(){},warn(){},errText:String},TAG:'test',ConnState:{DISCONNECTED:0},
  AppStorage:{get:key=>storage.get(key),setOrCreate:(key,value)=>storage.set(key,value)},
  AppProxyRoute:{isReady:()=>proxy},reorderAssetMirrors:mirrors=>mirrors,
  MODEL_MIRRORS:[{url:'https://fixture/model',tag:'github'}],
  ProfileRepository:{exists:()=>false},
  http:{RequestMethod:{GET:0},HttpDataType:{ARRAY_BUFFER:0},createHttp:()=>({
    async request(url,options){requests.push({url,options});if(hold)await hold;
      if(response==='throw')throw Error('offline');
      const body=response==='ok'?bytes:Buffer.from('<html>failure</html>');
      return {responseCode:response==='status'?503:200,result:asArrayBuffer(body)};
    },destroy(){}}
  )}
});
const methods=['bufferMagicOk','downloadAsset','isSmartModelReady','isSmartModelAvailable',
  'downloadSmartModelAsset','refreshGeoAsset','deleteGeoAsset','smartAvailableFor'];
const evaluate=text=>vm.runInContext(stripTypeScriptTypes(text,{mode:'transform'}),context);
const Model=evaluate(`(()=>{class ConnectionOrchestrator{${methods.map(name=>method(source,name)).join('\n')}}return ConnectionOrchestrator})()`);
const orch=Object.assign(new Model(),{context:{cacheDir:scratch},state:0,smartModelDownloading:false,smartAvailability:new Map()});
const subs={nodesOf:()=>[{name:'A'},{name:'B'}]};
let passed=0;const pass=name=>{passed++;console.log('PASS '+name);};
try{
  assert.equal(fs.existsSync(path.join(root,'entry/src/main/resources/rawfile/Model.bin')),false);
  assert.doesNotMatch(source,/seedSmartModelFromRawfile|ensureSmartModelReady|downloadSmartModelInBackground/);
  assert.equal((source.match(/this\.downloadSmartModelAsset\(/g)||[]).length,1,'only explicit refresh may download');
  pass('no bundled model or automatic model installation path');
  assert.equal(orch.isSmartModelAvailable(),false);assert.equal(await orch.smartAvailableFor('A',subs),false);
  fs.writeFileSync(path.join(scratch,'Model.bin'),bytes);
  assert.equal(orch.isSmartModelAvailable(),false);assert.equal(requests.length,0);
  const oldReady=method(source,'isSmartModelReady').replace(/^.*if \(!fs\.accessSync\(`\$\{path\}\.manual`\)\).*\r?\n/m,'');
  const Old=evaluate(`(()=>{class Old{${oldReady}}return Old})()`);
  assert.equal(Object.assign(new Old(),{context:orch.context}).isSmartModelReady(),true,'negative control proves legacy cache would bypass manual consent without the gate');
  pass('fresh and legacy auto-seeded caches stay hidden without network activity');
  for(response of ['status','bad','throw']){
    const error=await orch.refreshGeoAsset('model','github');
    assert.match(error,/普通节点启动代理.*更新/);
    assert.equal(orch.isSmartModelAvailable(),false);assert.equal(storage.has('smart_model_seq'),false);
    assert.deepEqual(fs.readFileSync(path.join(scratch,'Model.bin')),bytes);
  }
  pass('failed manual downloads keep entry hidden, preserve file and explain proxy retry');
  response='ok';proxy=true;
  assert.equal(await orch.refreshGeoAsset('model','github'),'');
  assert.equal(orch.isSmartModelAvailable(),true);assert.equal(await orch.smartAvailableFor('A',subs),true);
  assert.equal(storage.get('smart_model_seq'),1);assert.equal(requests.at(-1).options.usingProxy,true);
  assert.deepEqual(fs.readFileSync(path.join(scratch,'Model.bin')),bytes);
  pass('successful explicit update marks installation and signals UI; proxy transport used when ready');
  response='bad';const before=Buffer.from(fs.readFileSync(path.join(scratch,'Model.bin')));
  assert.match(await orch.refreshGeoAsset('model','github'),/启动代理/);
  assert.equal(orch.isSmartModelAvailable(),true);assert.equal(storage.get('smart_model_seq'),1);
  assert.deepEqual(fs.readFileSync(path.join(scratch,'Model.bin')),before);
  assert.equal(fs.readdirSync(scratch).some(name=>name.includes('.download-')),false);
  pass('bad update preserves existing manually installed model and removes staging');
  response='ok';let resolve;hold=new Promise(r=>resolve=r);
  const update=orch.refreshGeoAsset('model','github');
  assert.match(await orch.refreshGeoAsset('model','github'),/正在更新/);
  assert.match(orch.deleteGeoAsset('model'),/正在更新/);
  resolve();assert.equal(await update,'');hold=null;
  pass('concurrent updates share a lock and deletion cannot race download');
  for(const [file,scope] of [['components/SubscriptionSection.ets','panelSubId'],['pages/NodeSelectionPage.ets','filterSubId']]){
    let visible=true;context.ConnectionOrchestrator={instance:()=>orch};context.AutoSelectModes={AUTO:'auto'};
    context.ProfileRepository.currentId=()=> 'A';
    const Page=evaluate(`(()=>{class Page{${method(read(file),'refreshSmartEntry')}}return Page})()`);
    const page=Object.assign(new Page(),{[scope]:'A',settings:{autoSelectMode:'auto',preferredNodeSubscriptionId:'A'},
      smartRefreshRevision:0,orchestrator:orch,service:subs,subs,selectedName:'old'});
    page.refreshSmartEntry();await Promise.resolve();await Promise.resolve();
    assert.equal(page.smartVisible,true);assert.equal(page.smartSelected,true);
    if(visible){assert.equal(orch.deleteGeoAsset('model'),'');visible=false;}
    page.refreshSmartEntry();await Promise.resolve();await Promise.resolve();
    assert.equal(page.smartVisible,false);assert.equal(page.smartSelected,false);
    assert.equal(orch.isSmartModelAvailable(),false);
    response='ok';assert.equal(await orch.refreshGeoAsset('model','github'),'');
  }
  pass('both node UIs show Smart only after success and hide it on deletion');
  assert.match(read('pages/HomePage.ets'),/@StorageLink\('smart_model_seq'\) @Watch\('onNodeSwitched'\)/);
  assert.equal(orch.deleteGeoAsset('model'),'');assert.equal(fs.existsSync(path.join(scratch,'Model.bin.manual')),false);
  assert.equal(fs.existsSync(path.join(scratch,'Model.bin')),false);assert.equal(await orch.smartAvailableFor('A',subs),false);
  pass('delete removes model and manual provenance; Home observes the same revision');
  console.log(`RESULT: ${passed} manual-model lifecycle checks passed`);
}finally{fs.rmSync(scratch,{recursive:true,force:true});}
