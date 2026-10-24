/**
 * 端到端生成器验证：真正**执行** ClashConfigGenerator.generate()，
 * 把产出的 YAML 交给**真实内核** mihomo -t 解析，并断言 smart 组语义。
 *
 * 为什么需要这个套件：
 *   现有 9 个 verify-*.mjs 全部是「源码字符串断言」（Select-String / regex），
 *   没有任何一个真正跑过生成器。坑 24/40 都是「生成的配置让内核启动卡死」，
 *   而字符串断言对这类问题完全无感 —— 这次 smart 组同理：只有把真实产物
 *   喂给真实内核，才能证明它不会在启动路径上同步下载 Model.bin。
 *
 * 跑法：node scripts/verify-smart-e2e.mjs [--kernel <mihomo.exe>]
 *   不给 --kernel 时自动从 mihomo-build/ 里找已构建的内核；找不到就跳过内核段
 *   （仍执行生成器并做结构断言），并在结尾明确报告 SKIPPED。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const ets = path.join(root, 'entry/src/main/ets');
const svc = path.join(ets, 'commons/services');
const models = path.join(ets, 'commons/models');

let passed = 0, failed = 0, skipped = 0;
function ok(cond, label) {
  if (cond) { passed++; console.log(`  ✅ ${label}`); }
  else { failed++; console.log(`  ❌ ${label}`); }
}
function skip(label) { skipped++; console.log(`  ⏭️  ${label}`); }

// ── 暂存真源码（复用 alignment 套件的 flatten + stripEnums 机制）──────────────
const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'smart-e2e-'));
const w = (n, s) => fs.writeFileSync(path.join(stage, n), s, 'utf8');
const flatten = (s) => s
  .replace(/from '(?:\.\.?\/)+(?:[A-Za-z0-9_]+\/)*([A-Za-z0-9_]+)'/g, "from './$1.ts'")
  .replace(/from '\.\.\/utils\/AppLogger'/g, "from './AppLogger.ts'");
// enum → class：成员之间可能夹注释，且收尾 } 可能带缩进，故用行感知扫描，
// 不能用 `[\s\S]*?\n\}` 的紧凑正则（对含注释/缩进的 enum 会失配）。
const stripEnums = (s) => {
  const lines = s.split('\n');
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const m = /^(\s*)export enum (\w+) \{/.exec(lines[i]);
    if (!m) { out.push(lines[i]); continue; }
    const indent = m[1], name = m[2];
    const pairs = [];
    i++;
    for (; i < lines.length; i++) {
      if (/^\s*\}/.test(lines[i])) break;              // enum 收尾
      const kv = /^\s*(\w+)\s*=\s*'([^']*)'/.exec(lines[i]);
      if (kv) pairs.push([kv[1], kv[2]]);
    }
    out.push(`${indent}export class ${name} {`);
    for (const [k, v] of pairs) out.push(`${indent}  static readonly ${k}: string = '${v}';`);
    out.push(`${indent}}`);
  }
  return out.join('\n');
};

w('AppLogger.ts', `
export class AppLogger {
  static info() {} static warn() {} static error() {} static debug() {}
  static errText(e) { return String(e && e.message ? e.message : e); }
}
`);

// 只 stage 生成器真正依赖的模型（ProxyNode / ProxyGroup / AppSettings）
for (const [file, out] of [
  ['ProxyNode.ets', 'ProxyNode.ts'],
  ['ProxyGroup.ets', 'ProxyGroup.ts'],
  ['AppSettings.ets', 'AppSettings.ts'],
  // 2026-10-21（DNS 按订阅分域）：生成器 import SubDnsUpstream / SubDnsUpstreamPolicy
  ['SubDnsUpstream.ets', 'SubDnsUpstream.ts'],
]) {
  const p = path.join(models, file);
  if (!fs.existsSync(p)) { console.log(`缺模型 ${file}`); process.exit(1); }
  w(out, stripEnums(flatten(fs.readFileSync(p, 'utf8'))));
}
// 2026-10-20（yaml-sub 的订阅解析内核化）：ProxyNode.ets 现在 import 规范解析层
// （../subscription/UriNodeParser、../subscription/ProxyNodeAdapter），
// flatten() 会把它们改写成 './UriNodeParser.ts' / './ProxyNodeAdapter.ts' ⇒
// 这几个模块也必须一并 stage，否则 ERR_MODULE_NOT_FOUND（staging 失败 ⇒ 整套件红）。
const sub = path.join(ets, 'commons/subscription');
for (const [file, out] of [
  ['ProtocolParamTable.ets', 'ProtocolParamTable.ts'],
  ['NodeUsability.ets', 'NodeUsability.ts'],
  ['UnusableLedger.ets', 'UnusableLedger.ts'],
  ['UriNodeParser.ets', 'UriNodeParser.ts'],
  ['ProxyNodeAdapter.ets', 'ProxyNodeAdapter.ts'],
]) {
  const p = path.join(sub, file);
  if (!fs.existsSync(p)) { console.log(`缺订阅解析模块 ${file}`); process.exit(1); }
  w(out, stripEnums(flatten(fs.readFileSync(p, 'utf8'))));
}
// 2026-10-20（A12c）：生成器的测速地址改走唯一真源 LatencyTestUrl（零 import）
// ⇒ 也必须 stage，否则 ClashConfigGenerator.ts import 不到。
{
  const p = path.join(ets, 'commons/latency/LatencyTestUrl.ets');
  if (!fs.existsSync(p)) { console.log('缺 latency/LatencyTestUrl.ets'); process.exit(1); }
  w('LatencyTestUrl.ts', stripEnums(flatten(fs.readFileSync(p, 'utf8'))));
}
// AppSettings 依赖 NodeSortPersistence / AppRoutingPolicy —— 用最小桩替掉
w('NodeSortPersistence.ts', `export class NodeSortModes {
  static readonly DEFAULT: string = 'default';
  static readonly LATENCY: string = 'latency';
  static normalize(m) { return m; }
}
export class NodeSortSnapshot {
  static fromJsonText() { return new NodeSortSnapshot(); }
  records() { return []; }
}
`);
w('AppRoutingPolicy.ts', `export class AppRoutingPolicy {
  static runtime() { return null; }
}
export class AppRoutingCustomApp {}
`);
// RawSubscriptionStore 的传递依赖：本套件不碰真实文件系统，全部桩掉
w('PrivateFileStore.ts', `
export class PrivateFileStore {
  static of() { return new PrivateFileStore(); }
  exists() { return false; }
  readText() { return ''; }
  writeText() {}
  remove() {}
}
export function ensurePrivateDir() {}
export function chmodPrivate() {}
export const privateFs = {
  accessSync() { throw new Error('no fs'); },
  statSync() { throw new Error('no fs'); },
  readTextSync() { return ''; },
  openSync() { throw new Error('no fs'); },
  OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2, CREATE: 64, TRUNC: 512 },
};
`);
w('SettingsService.ts', `
export class SettingsService {
  static async load() { throw new Error('stub'); }
  static async save() {}
}
`);

// 生成器本体 + 它依赖的服务：全部 stage 真源码，只桩掉纯 IO 的部分
const want = [
  ['ClashConfigGenerator.ets', 'ClashConfigGenerator.ts'],
  ['YamlMerger.ets', 'YamlMerger.ts'],
  ['RawSubscriptionStore.ets', 'RawSubscriptionStore.ts'],
  // RawSubscriptionStore 依赖配置校验闸门（C23/C26：落盘前 YAML 校验）→ 必须一并 stage
  ['ConfigValidator.ets', 'ConfigValidator.ts'],
  // 2026-10-21（原文透传）：生成器从订阅原文切片节点定义 → 纯逻辑，stage 真源码
  ['RawProxyYaml.ets', 'RawProxyYaml.ts'],
];
for (const [file, out] of want) {
  const p = path.join(svc, file);
  if (!fs.existsSync(p)) { console.log(`缺服务 ${file}`); process.exit(1); }
  // 服务里也有 export enum（如 ClashConfigGenerator 的 ProxyDropReason）→ 必须一并转换
  w(out, stripEnums(flatten(fs.readFileSync(p, 'utf8'))));
}

// 全 stage 内把 @kit.* 换成桩
w('kit.ts', `class Decoder {
  static create() { return new Decoder(); }
  decodeToString(b){ return Buffer.from(b).toString('utf8'); }
  decodeWithStream(b){ return Buffer.from(b).toString('utf8'); }
}
class Encoder {
  static create() { return new Encoder(); }
  encodeInto(s){ return new Uint8Array(Buffer.from(s,'utf8')); }
  encodeToString(s){ return Buffer.from(s,'utf8').toString('base64'); }
}
class Base64Helper {
  decodeSync(i){ return new Uint8Array(Buffer.from(String(i),'base64')); }
  decodeToStringSync(i){ return Buffer.from(String(i),'base64').toString('utf8'); }
  encodeToStringSync(i){ return Buffer.from(String(i)).toString('base64'); }
}
export const util = {
  TextDecoder: Decoder, TextEncoder: Encoder,
  Base64Helper: Base64Helper, base64Helper: new Base64Helper(),
  Type: { MIME: 'mime', BASIC: 'basic' }
};
`);
w('fs.ts', `export const fileIo = {
  accessSync() { throw new Error('no fs'); },
  statSync() { throw new Error('no fs'); },
  readTextSync() { return ''; },
  openSync() { throw new Error('no fs'); },
  OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2, CREATE: 64, TRUNC: 512 },
};
export default { fileIo };
`);
for (const f of fs.readdirSync(stage)) {
  if (!f.endsWith('.ts')) continue;
  const p = path.join(stage, f);
  let s = fs.readFileSync(p, 'utf8');
  s = s.replace(/from '@kit\.ArkTS'/g, "from './kit.ts'");
  s = s.replace(/from '@kit\.CoreFileKit'/g, "from './fs.ts'");
  s = s.replace(/from '@ohos\.\w+'/g, "from './kit.ts'");
  s = s.replace(/from '@kit\.\w+'/g, "from './kit.ts'");
  fs.writeFileSync(p, s, 'utf8');
}

// ── 载入生成器 ────────────────────────────────────────────────────────────────
let Gen = null, ProxyNode = null, ProxyGroup = null, AppSettings = null;
try {
  const m = await import(`file://${path.join(stage, 'ClashConfigGenerator.ts').replace(/\\/g, '/')}`);
  Gen = m.ClashConfigGenerator;
  ProxyNode = (await import(`file://${path.join(stage, 'ProxyNode.ts').replace(/\\/g, '/')}`)).ProxyNode;
  ProxyGroup = (await import(`file://${path.join(stage, 'ProxyGroup.ts').replace(/\\/g, '/')}`)).ProxyGroup;
  AppSettings = (await import(`file://${path.join(stage, 'AppSettings.ts').replace(/\\/g, '/')}`)).AppSettings;
} catch (e) {
  console.log(`\nFAILED to stage generator: ${e && e.stack ? e.stack : e}`);
  process.exit(1);
}

function mkNode(name, server, port) {
  const n = new ProxyNode();
  n.id = `id-${name}`;
  n.name = name; n.originalName = name;
  n.server = server; n.port = port;
  n.type = 'ss';                 // ProxyNodeType.SS 的字符串值
  n.method = 'aes-256-gcm';      // ss 的加密方式字段名是 method（不是 cipher）
  n.password = 'pw';
  n.rawYaml = '';
  return n;
}
function mkSettings(auto) {
  const s = new AppSettings();
  s.autoSelectMode = auto;
  return s;
}

const nodes = [mkNode('香港 01', '127.0.0.1', 18443), mkNode('日本 02', '127.0.0.1', 18444),
  mkNode('美国 03', '127.0.0.1', 18445)];
const gen = (useSmart, auto = 'auto') => Gen.generate(nodes[0], nodes, mkSettings(auto),
  17890, 19090, 1053, 'secret', false, false, {}, false, [], true, useSmart);

console.log('\n[1] 生成器结构断言（真正执行 generate()）');
const ySmart = gen(true);
const yPlain = gen(false);

ok(ySmart.includes('type: smart'), 'useSmart=true 时输出 type: smart');
ok(!yPlain.includes('type: smart'), 'useSmart=false 时不含 type: smart');
ok(ySmart.includes('uselightgbm: true'), 'smart 组声明 uselightgbm: true');
ok(ySmart.includes('prefer-asn: false'), 'smart 组显式 prefer-asn: false（避免同步拉 ASN.mmdb 90s）');
ok(ySmart.includes('collectdata: false'), 'smart 组 collectdata: false（本地隐私优先）');
ok(ySmart.includes(Gen.SMART_GROUP_NAME), 'smart 组名出现在配置中');
ok(ySmart.includes('  - name: "PROXY"'), 'PROXY 组仍在');

// PROXY 成员顺序：auto 模式必须把 smart 组放第一位（否则 selectNode 钉住具体节点后失效）
// 成员行是 6 空格缩进的 `      - "..."`；不能按任意 `- ` 前缀过滤，
// 否则会把 `  - name: "PROXY"` 本身当成首个成员。
const proxyMembers = (yaml) => {
  const start = yaml.indexOf('  - name: "PROXY"');
  const end = yaml.indexOf(`  - name: "${Gen.SMART_GROUP_NAME}"`);
  const block = yaml.slice(start, end > start ? end : undefined);
  return block.split('\n').filter(l => /^ {6}- "/.test(l));
};
const autoMembers = proxyMembers(ySmart);
ok(autoMembers.some(m => m.includes(Gen.SMART_GROUP_NAME)), 'PROXY 成员含 smart 组');
ok(autoMembers[0] !== undefined && autoMembers[0].includes(Gen.SMART_GROUP_NAME),
  `auto 模式下 smart 组是 PROXY 首个成员（实际: ${(autoMembers[0] || '').trim()}）`);

// manual 模式：smart 组仍存在（可手动选）但不占首位
const yManual = gen(true, 'manual');
const manualMembers = proxyMembers(yManual);
ok(manualMembers.length > 0 && !manualMembers[0].includes(Gen.SMART_GROUP_NAME),
  `manual 模式下 smart 组不占首位（实际首位: ${(manualMembers[0] || '').trim()}）`);

// 单节点时不声明 smart（无意义且多一跳）
const one = [nodes[0]];
const yOne = Gen.generate(one[0], one, mkSettings('auto'), 17890, 19090, 1053, 'secret',
  false, false, {}, false, [], true, true);
ok(!yOne.includes('type: smart'), '仅 1 个节点时不声明 smart 组');

// 组名冲突时不声明（避免引用二义性）
const clash = [mkNode(Gen.SMART_GROUP_NAME, '127.0.0.1', 18446), nodes[1]];
const yClash = Gen.generate(clash[0], clash, mkSettings('auto'), 17890, 19090, 1053, 'secret',
  false, false, {}, false, [], true, true);
ok(!yClash.includes('type: smart'), '节点名与 smart 组名冲突时不声明该组');

// ── [2] 真实内核解析 ────────────────────────────────────────────────────────
console.log('\n[2] 真实内核 mihomo -t 解析生成的配置');
let kernel = null;
const argIdx = process.argv.indexOf('--kernel');
if (argIdx > 0 && process.argv[argIdx + 1]) kernel = process.argv[argIdx + 1];
if (!kernel) {
  const buildRoot = path.join(root, '..', 'mihomo-build');
  if (fs.existsSync(buildRoot)) {
    for (const d of fs.readdirSync(buildRoot)) {
      const cand = path.join(buildRoot, d, 'mihomo.exe');
      if (fs.existsSync(cand)) { kernel = cand; break; }
    }
  }
}
if (!kernel || !fs.existsSync(kernel)) {
  skip('未找到已构建内核（传 --kernel <mihomo.exe>）—— 跳过内核解析段');
} else {
  console.log(`  使用内核: ${kernel}`);
  const kd = fs.mkdtempSync(path.join(os.tmpdir(), 'smart-k-'));
  // 必须放**真实**的 LightGBM 模型：内核 GetModel() 会校验模型内容，坏文件会被
  // 删掉并重新联网下载（实测 90s 阻塞）。所以这里用真实模型文件，找不到就跳过，
  // 绝不能用假文件 —— 那只会测出「下载耗时」而不是「是否复用现成模型」。
  const modelCandidates = [
    process.env.TUNBOX_MODEL_BIN,
    path.join(os.homedir(), '.tunbox-test', 'Model.bin'),
    path.join(root, '..', 'mihomo-build', 'Model.bin'),
  ].filter(Boolean);
  const realModel = modelCandidates.find(p => fs.existsSync(p) && fs.statSync(p).size > 1024 * 1024);
  if (!realModel) {
    skip('未找到真实 Model.bin（9.3MB）—— 跳过内核解析段');
    skip(`  可设 TUNBOX_MODEL_BIN=<path> 或用 curl 经代理下载到 ${modelCandidates[1]}`);
  } else {
  fs.copyFileSync(realModel, path.join(kd, 'Model.bin'));
  console.log(`  使用模型: ${realModel} (${fs.statSync(realModel).size} bytes)`);
  for (const [label, yaml] of [['smart', ySmart], ['plain', yPlain]]) {
    const f = path.join(kd, `${label}.yaml`);
    fs.writeFileSync(f, yaml, 'utf8');
    if (process.env.TB_DUMP === '1') { console.log(`     ── ${label}.yaml ──\n${yaml}`); }
    const t0 = Date.now();
    let out = '', code = 0;
    try {
      out = execFileSync(kernel, ['-d', kd, '-f', f, '-t'], { encoding: 'utf8', timeout: 200000 });
    } catch (e) {
      out = String((e.stdout || '') + (e.stderr || e.message || ''));
      code = e.status === undefined ? 1 : e.status;
    }
    const secs = (Date.now() - t0) / 1000;
    ok(code === 0 && /test is successful/.test(out),
      `${label} 配置被内核接受（${secs.toFixed(1)}s）`);
    // 内核拒载时把原始输出打出来 —— 只报 ❌ 而不给原因，排查一轮白跑
    // （2026-10-22：本脚本红了一轮，实际问题在输出里，看不到就只能猜）。
    if (code !== 0 || !/test is successful/.test(out)) {
      console.log(`     内核输出（exit=${code}）: ${out.trim().split('\n').slice(0, 12).join('\n     ')}`);
    }
    // 关键回归：绝不能出现 Model.bin 下载（说明 smart 组真的用了现成模型）
    ok(!/Can't find Model.bin/.test(out), `${label}: 未触发 Model.bin 下载`);
    ok(!/Can't find MMDB/.test(out), `${label}: 未触发 MMDB 下载`);
    ok(secs < 30, `${label}: 解析未长时间阻塞（${secs.toFixed(1)}s < 30s）`);
    if (label === 'smart') {
      ok(/Model file loaded successfully/.test(out), 'smart: 内核成功加载模型');
    }
  }
  fs.rmSync(kd, { recursive: true, force: true });
  }
}

console.log('\n-----------------------------------------');
console.log(`PASSED=${passed}  FAILED=${failed}  SKIPPED=${skipped}`);
console.log(failed === 0 ? 'RESULT: SMART E2E CHECKS PASSED' : 'RESULT: SMART E2E CHECKS FAILED');
fs.rmSync(stage, { recursive: true, force: true });
process.exit(failed === 0 ? 0 : 1);
