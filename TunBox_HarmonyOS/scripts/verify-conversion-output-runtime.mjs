// Executes the production conversion handler and converters. Only OS picker/file/network storage are faked.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {stripTypeScriptTypes} from 'node:module';
const base = new URL('../entry/src/main/ets/', import.meta.url);
const read = p => fs.readFileSync(new URL(p, base), 'utf8');
const ctx = vm.createContext({ console, URL, TextEncoder, TextDecoder, Date,
  util: { TextEncoder: {create:()=>({encodeInto:s=>new TextEncoder().encode(s)})} },
  AppLogger: {info(){},warn(){},errText:String}, TAG:'convert-test', getContext:()=>({})
});
function load(file, names) {
  const text=read(file).replace(/^import\b[\s\S]*?;\r?\n/gm,'').replace(/^export /gm,'');
  const result=vm.runInContext(stripTypeScriptTypes(`(()=>{${text}\nreturn {${names}}})()`,{mode:'transform'}),ctx);
  Object.assign(ctx,result);return result;
}
load('commons/services/YamlMerger.ets','YamlMerger');
load('commons/flclash/ProfileConfigMerger.ets','ProfileConfigMerger');
load('commons/flclash/SubConverter.ets','SubConverter');
load('commons/services/ImportFilePolicy.ets','ImportFilePolicy');
const ui=read('components/SubscriptionSection.ets');
const method=ui.match(/^  private async importFromConvert\([\s\S]*?^  }/m)[0];
const Panel=vm.runInContext(stripTypeScriptTypes(`(()=>{class Panel{${method}}return Panel})()`,{mode:'transform'}),ctx);
const link='trojan://fixture-password@127.0.0.1:443#'+encodeURIComponent('台湾 测试🚀');
const existing='proxies:\n  - {name: "自定义直连", type: direct}\nproxy-groups:\n  - {name: "已选组", type: select, proxies: ["自定义直连"]}\nrules:\n  - MATCH,已选组\n';
let passed=0, exported='';
function setup() {
  const h={imports:[],toasts:[],chunks:[],picked:0,opened:0,closed:0,synced:0,reloads:0,fetches:0,uris:['file://fixture/export.yaml'],limit:17,writeError:false,zeroWrite:false,pickerError:false,added:1,createSub:true,body:existing};
  ctx.SettingsService={async load(){return {allowInsecureSubscriptionHttp:false};}};
  ctx.SubscriptionFetchPolicy={async fetch(url,a,b,allow){h.fetches++;assert.equal(allow,false);return {body:h.body};}};
  ctx.picker={DocumentSaveOptions:class{},DocumentViewPicker:class{async save(opts){h.picked++;h.options=opts;if(h.pickerError)throw Error('denied');return h.uris;}}};
  ctx.fs={OpenMode:{READ_WRITE:2,CREATE:64,TRUNC:512},async open(){h.opened++;return {fd:7};},
    async write(fd,data){assert.equal(fd,7);if(h.writeError)throw Error('disk full');if(h.zeroWrite)return 0;const bytes=new Uint8Array(data),n=Math.min(h.limit,bytes.length);h.chunks.push(Buffer.from(bytes.slice(0,n)));return n;},
    async fsync(){h.synced++;},async close(){h.closed++;}};
  h.panel=Object.assign(new Panel(),{converting:false,service:{subscriptions:[],async addLocalYaml(name,yaml){h.imports.push({name,yaml});if(h.createSub)this.subscriptions.push({});return h.added;}},toast:t=>h.toasts.push(t),reload:()=>h.reloads++});
  h.text=()=>Buffer.concat(h.chunks).toString('utf8'); return h;
}
async function test(name,fn){const h=setup();await fn(h);assert.equal(h.panel.converting,false);passed++;console.log('PASS '+name);}
await test('default choice imports converted links and never opens the save picker',async h=>{
  await h.panel.importFromConvert(link);assert.equal(h.imports.length,1);assert.equal(h.picked,0);assert.equal(h.reloads,1);
  assert.match(h.imports[0].yaml,/proxy-groups:/);assert.match(h.imports[0].yaml,/MATCH,手动选择/);assert.match(h.imports[0].name,/\.yaml$/);
  exported=h.imports[0].yaml;
});
await test('export writes identical complete UTF-8 YAML even with partial writes and creates no subscription',async h=>{
  await h.panel.importFromConvert(link,true);assert.equal(h.text(),exported);assert.equal(h.imports.length,0);assert.equal(h.reloads,0);
  assert.equal(h.closed,1);assert.equal(h.synced,1);assert.ok(h.chunks.length>1);assert.match(h.toasts.at(-1),/已保存/);
  assert.deepEqual(Array.from(h.options.fileSuffixChoices),['YAML 配置|.yaml']);
});
await test('existing YAML preserves groups/rules verbatim for export',async h=>{
  await h.panel.importFromConvert(existing,true);assert.equal(h.text(),existing);assert.equal(h.imports.length,0);
});
await test('base64 share list converts through the same production parser',async h=>{
  await h.panel.importFromConvert(Buffer.from(link).toString('base64'),true);assert.equal(h.text(),exported);
});
await test('a URL uses the existing fetch policy before either output path',async h=>{
  await h.panel.importFromConvert('https://fixture.invalid/sub',true);assert.equal(h.fetches,1);assert.equal(h.text(),existing);
});
await test('cancelled save neither writes nor imports and does not claim success',async h=>{
  h.uris=[];await h.panel.importFromConvert(link,true);assert.equal(h.opened,0);assert.equal(h.imports.length,0);assert.equal(h.toasts.length,0);
});
for(const kind of ['writeError','zeroWrite'])await test(kind+' closes the file and reports failure without import',async h=>{
  h[kind]=true;await h.panel.importFromConvert(link,true);assert.equal(h.closed,1);assert.equal(h.imports.length,0);assert.match(h.toasts.at(-1),/失败/);assert.equal(h.synced,0);
});
await test('picker rejection resets busy state and never imports',async h=>{
  h.pickerError=true;await h.panel.importFromConvert(link,true);assert.equal(h.opened,0);assert.equal(h.imports.length,0);assert.match(h.toasts.at(-1),/失败/);
});
await test('empty/invalid conversion never offers a file or creates a subscription',async h=>{
  for(const value of ['', 'not a subscription'])await h.panel.importFromConvert(value,true);
  assert.equal(h.picked,0);assert.equal(h.imports.length,0);
});
await test('UTF-8 byte limit rejects oversized output before opening the picker',async h=>{
  const limit=ctx.ImportFilePolicy.YAML_MAX_BYTES;ctx.ImportFilePolicy.YAML_MAX_BYTES=64;
  try {await h.panel.importFromConvert(existing,true);assert.equal(h.picked,0);assert.match(h.toasts.at(-1),/过大/);}finally{ctx.ImportFilePolicy.YAML_MAX_BYTES=limit;}
});
await test('provider-only successful import is not mistaken for an empty failure',async h=>{
  h.added=0;await h.panel.importFromConvert('proxy-providers:\n  p: {type: http, url: https://fixture.invalid/sub}\n');
  assert.match(h.toasts.at(-1),/已导入/);assert.equal(h.reloads,1);
});
await test('rejected zero-node import cannot claim it added a subscription',async h=>{
  h.added=0;h.createSub=false;await h.panel.importFromConvert(link);assert.match(h.toasts.at(-1),/未完成/);
});
await test('duplicate conversion requests do not open a second output flow',async h=>{
  h.panel.converting=true;await h.panel.importFromConvert(link,true);assert.equal(h.picked,0);h.panel.converting=false;
});
assert.ok(ui.includes("this.ConvertOutputChoice('直接导入 TunBox', false)"));
assert.ok(ui.includes("this.ConvertOutputChoice('导出 YAML 文件', true)"));
assert.ok(ui.includes('this.onConvert(this.convertText, this.exportConvertedYaml)'));
assert.ok(ui.includes('this.importFromConvert(text, exportFile)'));
const core=process.env.MIHOMO_BIN||path.resolve('../mihomo-build/mihomo-smart-462455136157a760937c666bba71afe33b1a809e/mihomo.exe');
assert.ok(fs.existsSync(core),'real core required to validate exported YAML');
const temp=fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()),'tunbox-probe-convert-output-'));
try {
  fs.writeFileSync(path.join(temp,'config.yaml'),exported);
  const r=spawnSync(core,['-t','-d',temp,'-f',path.join(temp,'config.yaml')],{encoding:'utf8',timeout:30000,windowsHide:true});
  assert.equal(r.status,0,(r.stdout||'')+(r.stderr||''));console.log('PASS real mihomo accepts the exact exported YAML');
}finally{
  const resolved=fs.realpathSync(temp);assert.equal(path.dirname(resolved),fs.realpathSync(os.tmpdir()));assert.ok(path.basename(resolved).startsWith('tunbox-probe-convert-output-'));fs.rmSync(resolved,{recursive:true,force:true});
}
console.log(`PASS ${passed} conversion output runtime scenarios + real kernel YAML validation`);
