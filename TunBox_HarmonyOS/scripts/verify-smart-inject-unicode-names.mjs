#!/usr/bin/env node
/**
 * 回归门禁：「自动选择启动报错」根因固化（2026-10-25 真机定案）
 *
 * ## 故障现象
 *   自动选择模式下连接失败，hilog（真机实证）：
 *   ```
 *   E ConnectionOrchestrator: connect failed: 配置校验未通过：最终配置未通过内核检查
 *     （proxy group[2]: ♻️ 自动选择: '\U0001F1EF\U0001F1F5日本•移联01' not found）。已保留原配置
 *   ```
 *   内核 `mihomo -t` 对同一份配置报逐字相同的错。
 *
 * ## 根因（两层，缺一不成立）
 *  1. 订阅导入时 `config.PrepareProfile`（内核 Go 侧）把整份文档重新 marshal，
 *     **非 BMP 字符（国旗 emoji）被写成 `"\U0001F1EF\U0001F1F5日本•移联01"`**，
 *     落盘进 `<filesDir>/profiles/<id>.yaml`。内核按 YAML 规范解码 → 真 emoji。
 *  2. `YamlMerger.decodeScalar` 处理双引号标量时**只还原 `\"` 和 `\\`**，
 *     不还原 `\U`/`\u`/`\x` 等转义 → `sequenceItemNames` 读出的节点名带字面反斜杠，
 *     与内核解出的真 emoji 不是同一个名字。
 *  3. `injectSmartPrimary` 用这些「字面反斜杠」名字生成 smart 组成员，
 *     内核在同一份配置里无法用它们寻址节点 → `proxy group[N] ... not found` → 整份拒载。
 *
 * ## 断言
 *   A. decodeScalar 经 sequenceItemNames 读转义名 = 真 emoji（不再是字面反斜杠）。
 *   B. 单引号标量里的 `\U` **必须保持字面**（YAML 单引号不做转义，别改坏真实值）。
 *   C. 全链：profile 自带 Smart 的名称、成员和选项在 compose 后原样保留；
 *      没有 Smart 的 profile 不因旧 useSmart 参数而凭空增加分组。
 *
 * 断言方式：Node 原生 TS type-stripping **直接加载 YamlMerger.ets / ProfileConfigMerger.ets
 * 源文件本体**（只把 SDK import 换成最小垫片），被测逻辑一行都不在垫片里重写。
 *
 * 用法: node scripts/verify-smart-inject-unicode-names.mjs
 * 退出码: 0 = 全部断言通过；1 = 有断言失败
 */
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';

const here = dirname(fileURLToPath(import.meta.url));
const appRoot = resolve(here, '..');
const svcDir = join(appRoot, 'entry', 'src', 'main', 'ets', 'commons', 'services');
const flclashDir = join(appRoot, 'entry', 'src', 'main', 'ets', 'commons', 'flclash');

let passed = 0;
const failures = [];
function record(label, okFlag, detail) {
  if (okFlag) { passed += 1; console.log('  ✓ ' + label); }
  else { failures.push(label + (detail ? ' -> ' + detail : '')); console.log('  ✗ ' + label + (detail ? ' — ' + detail : '')); }
}
function eq(label, actual, expected) {
  record(label, Object.is(actual, expected),
    'expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
}

// ── 加载沙箱：真实源码 + 最小垫片 ────────────────────────────────────
const sandbox = mkdtempSync(join(tmpdir(), 'tunbox-probe-smartunicode-'));
process.once('exit', () => rmSync(sandbox, { recursive: true, force: true }));
writeFileSync(join(sandbox, 'package.json'), JSON.stringify({ type: 'module' }), 'utf8');

writeFileSync(join(sandbox, 'shim_appkit.ts'), [
  'export const util = {',
  '  TextDecoder: class { constructor(_e?: string) {} decodeToString(_b: Uint8Array): string { return ""; } },',
  '  TextEncoder: class { encodeInto(_s: string): { read: number } { return { read: 0 }; } }',
  '};',
].join('\n'), 'utf8');
writeFileSync(join(sandbox, 'shim_logger.ts'), [
  'export class AppLogger {',
  '  static info(_t: string, _m: string): void {}',
  '  static warn(_t: string, _m: string): void {}',
  '  static error(_t: string, _m: string): void {}',
  '  static errText(e: Object): string { return e === null || e === undefined ? "unknown error" : String(e); }',
  '}',
].join('\n'), 'utf8');

function stage(srcPath, name) {
  const src = readFileSync(srcPath, 'utf8');
  const patched = src
    .replace(/from '@kit\.ArkTS'/g, "from './shim_appkit.ts'")
    .replace(/from '@kit\.AppKit'/g, "from './shim_appkit.ts'")
    .replace(/from '@ohos\.util'/g, "from './shim_appkit.ts'")
    .replace(/from '\.\.\/utils\/AppLogger'/g, "from './shim_logger.ts'")
    .replace(/from '\.\/AppLogger'/g, "from './shim_logger.ts'")
    // 兄弟模块改指向沙箱内同名产物
    .replace(/from '\.\.\/services\/YamlMerger'/g, "from './YamlMerger.ts'");
  const out = join(sandbox, name + '.ts');
  writeFileSync(out, patched, 'utf8');
  return out;
}

const yamlOut = stage(join(svcDir, 'YamlMerger.ets'), 'YamlMerger');
const mergerOut = stage(join(flclashDir, 'ProfileConfigMerger.ets'), 'ProfileConfigMerger');
const { YamlMerger } = await import(pathToFileURL(yamlOut).href);
const { ProfileConfigMerger } = await import(pathToFileURL(mergerOut).href);

// 2026-11-05（FlClash 全量照抄）：compose 的依赖 shim —— 门禁只用到两个常量
writeFileSync(join(sandbox, 'shim_generator.ts'), [
  'export class ClashConfigGenerator {',
  `  static readonly SMART_GROUP_NAME = '♻️ 自动选择';`,
  "  static readonly SMART_INFO_NODE_FILTER = '流量|过期';",
  '}',
].join('\n'), 'utf8');
writeFileSync(join(sandbox, 'shim_fetchpolicy.ts'), [
  'export function tunboxUserAgent(): string {',
  "  return 'TunBox/v-harness clash-verge Platform/OpenHarmony';",
  '}',
].join('\n'), 'utf8');
writeFileSync(join(sandbox, 'shim_corebridge.ts'), [
  'export const coreBridge = {',
  '  async getProfileBase(_p: string): Promise<never> { throw new Error("compose-only gate"); },',
  '  async decodeYaml(_t: string): Promise<never> { throw new Error("compose-only gate"); },',
  '};',
].join('\n'), 'utf8');
writeFileSync(join(sandbox, 'shim_filekit.ts'), [
  'export const fileIo = new Proxy({}, {',
  '  get() { throw new Error("compose-only gate must not access the filesystem"); }',
  '});',
].join('\n'), 'utf8');

function stageBuilder(srcPath, name) {
  const src = readFileSync(srcPath, 'utf8');
  const patched = src
    .replace(/from '@kit\.CoreFileKit'/g, "from './shim_filekit.ts'")
    .replace(/from '\.\.\/\.\.\/core\/CoreBridge'/g, "from './shim_corebridge.ts'")
    .replace(/from '\.\.\/services\/ClashConfigGenerator'/g, "from './shim_generator.ts'")
    .replace(/from '\.\.\/services\/SubscriptionFetchPolicy'/g, "from './shim_fetchpolicy.ts'")
    .replace(/from '\.\.\/latency\/LatencyTestUrl'/g, "from './LatencyTestUrl.ts'")
    .replace(/from '\.\.\/utils\/AppLogger'/g, "from './shim_logger.ts'");
  const out = join(sandbox, name + '.ts');
  writeFileSync(out, patched, 'utf8');
  return out;
}
stage(join(appRoot,'entry/src/main/ets/commons/latency/LatencyTestUrl.ets'),'LatencyTestUrl');
const builderOut = stageBuilder(join(flclashDir, 'TunBoxProfileBuilder.ets'), 'TunBoxProfileBuilder');

// ── A. 双引号里的 \U / \u / \x 必须解码成真字符 ──────────────────────
console.log('\n[A] 双引号标量转义解码（YAML 1.2 语义）');
const profileEscaped = [
  'proxies:',
  '  - { name: "\\U0001F1EF\\U0001F1F5日本•移联01", type: socks5, server: a.example, port: 1 }',
  '  - { name: "\\u65E5本2", type: socks5, server: b.example, port: 2 }',
  '  - { name: "\\x41BC", type: socks5, server: c.example, port: 3 }',
  '  - { name: "tab\\there", type: socks5, server: d.example, port: 4 }',
  '',
].join('\n');
const names = YamlMerger.sequenceItemNames(profileEscaped, 'proxies');
eq('\\U 8 位码点 → 真 emoji（不是字面反斜杠）', names[0], '\u{1F1EF}\u{1F1F5}日本•移联01');
eq('\\u 4 位码点 → 真字符', names[1], '日本2');
eq('\\x 2 位码点 → 真字符', names[2], 'ABC');
eq('\\t → 制表符', names[3], 'tab\there');
record('解码结果不含字面反斜杠', names[0].indexOf('\\') < 0, 'got ' + JSON.stringify(names[0]));

// ── B. 单引号不做转义：\U 必须保持字面（别把用户真实值改坏）────────────
console.log('\n[B] 单引号标量必须保持字面（负对照）');
const singleQuoted = [
  'proxies:',
  "  - { name: '\\U0001F1EF\\U0001F1F5日本•移联01', type: socks5, server: a.example, port: 1 }",
  "  - { name: 'plain name', type: socks5, server: b.example, port: 2 }",
  '',
].join('\n');
const singleNames = YamlMerger.sequenceItemNames(singleQuoted, 'proxies');
eq('单引号内 \\U 保持字面', singleNames[0], '\\U0001F1EF\\U0001F1F5日本•移联01');
eq('单引号内普通名字不变', singleNames[1], 'plain name');
record('单引号结果确实带反斜杠（说明不是被误当双引号解）',
  singleNames[0].indexOf('\\') === 0, 'got ' + JSON.stringify(singleNames[0]));

// ── C. 全链：unicode profile → compose 保留真实分组 ──────────────────────
console.log('\n[C] 全链：compose 保留真实 Smart / URLTest，unicode 名字逐字一致');
const { TunBoxProfileBuilder, TunBoxBaseData, TunBoxProfileInput } =
  await import(pathToFileURL(join(sandbox, 'TunBoxProfileBuilder.ts')).href);

const profileProxies = [
  { name: '\u{1F1EF}\u{1F1F5}日本•移联01', type: 'socks5', server: 'a.example', port: 1 },
  { name: '\u{1F1F8}\u{1F1EC}新加坡•移联01', type: 'socks5', server: 'b.example', port: 2 },
  { name: '剩余流量：947.23 GB', type: 'socks5', server: 'c.example', port: 3 },
];
const baseConfig = {
  'mixed-port': 7890,
  'mode': 'rule',
  'proxies': profileProxies,
  'proxy-groups': [
    { name: '吹雪云', type: 'select', proxies: ['自动选择', '\u{1F1EF}\u{1F1F5}日本•移联01', '\u{1F1F8}\u{1F1EC}新加坡•移联01'] },
    { name: '自动选择', type: 'url-test', proxies: ['\u{1F1EF}\u{1F1F5}日本•移联01'] },
  ],
  'rules': ['MATCH,吹雪云'],
};
const base = new TunBoxBaseData();
base.config = baseConfig;
base.digest = 'u';
base.proxies = 3;
base.proxyGroups = 2;
base.rules = 1;
base.matchRules = ['MATCH,吹雪云'];

// 旧 useSmart 参数不得改变 profile 自带的分组语义。
const input = new TunBoxProfileInput();
input.profileId = 'uni';
input.profilePath = '/profiles/uni.yaml';
input.profilesDir = '/profiles';
input.overrideYaml = '';
input.dnsOverrideEnabled = false;
input.tunEnabled = true;
input.ipv6Enabled = true;
input.mtu = 1400;
input.useSmart = false;
input.smartTestUrl = 'https://www.gstatic.com/generate_204';
input.smartPolicyPriority = '';

// C1 同名 URLTest：不得合成重复组，也不得把真实 URLTest 改为 Smart。
{
  const collide = JSON.parse(JSON.stringify(base));
  collide.config['proxy-groups'] = [
    { name: '吹雪云', type: 'select', proxies: ['自动选择'] },
    { name: '♻️ 自动选择', type: 'url-test', proxies: ['自动选择'] },
  ];
  const r = TunBoxProfileBuilder.compose(collide, {}, null, input);
  const groups = JSON.parse(r.yaml)['proxy-groups'];
  const count = groups.filter((g) => g.name === '♻️ 自动选择').length;
  record('同名组碰撞 → 不注入（无重复组名）', count === 1, 'count=' + count);
  record('同名 URLTest 类型不变', groups.find(g => g.name === '♻️ 自动选择')?.type === 'url-test');
}

// C2 真实 Smart：主组、Smart 与静态节点名逐字一致（emoji 无字面反斜杠）
{
  const base2 = JSON.parse(JSON.stringify(base));
  base2.config['proxy-groups'] = [
    { name: '吹雪云', type: 'select',
      proxies: ['♻️ 自动选择', '\u{1F1EF}\u{1F1F5}日本•移联01', '\u{1F1F8}\u{1F1EC}新加坡•移联01'] },
    { name: '♻️ 自动选择', type: 'smart', uselightgbm: false,
      proxies: ['\u{1F1EF}\u{1F1F5}日本•移联01', '\u{1F1F8}\u{1F1EC}新加坡•移联01'] },
  ];
  const r = TunBoxProfileBuilder.compose(base2, {}, null, input);
  const doc = JSON.parse(r.yaml);
  const groups = doc['proxy-groups'];
  const smart = groups.find((g) => g.name === '♻️ 自动选择');
  record('profile 自带 Smart 组原样保留', smart?.type === 'smart' && smart.uselightgbm === false);
  const emojiNode = profileProxies[0].name;
  record('静态节点名是真 emoji（无字面反斜杠）', emojiNode.indexOf('\\') < 0, JSON.stringify(emojiNode));
  record('smart 组成员含真 emoji 节点名（与 proxies 逐字一致）',
    smart !== undefined && Array.isArray(smart.proxies) && smart.proxies.includes(emojiNode),
    smart ? JSON.stringify(smart.proxies) : 'no group');
  const primary = groups.find((g) => g.name === '吹雪云');
  record('主组首位 = smart', primary !== undefined && primary.proxies[0] === '♻️ 自动选择',
    primary ? JSON.stringify(primary.proxies.slice(0, 2)) : 'no group');
  record('主组原有 unicode 成员保留',
    primary !== undefined && primary.proxies.includes(emojiNode));
}

{
  input.useSmart = true;
  const r = TunBoxProfileBuilder.compose(JSON.parse(JSON.stringify(base)), {}, null, input);
  const doc = JSON.parse(r.yaml);
  const smart=doc['proxy-groups'].find(group=>group.name===r.smartGroupName);
  record('恢复的 Smart 使用内核解析后的 unicode 名称',smart?.proxies.includes(profileProxies[0].name));
  record('Smart 不含机场信息条目',!smart?.proxies.includes(profileProxies[2].name));
}

// ── 结论 ───────────────────────────────────────────────────────────────
console.log('\n-----------------------------------------');
console.log(`PASS=${passed} FAIL=${failures.length}`);
if (failures.length > 0) {
  console.log('FAILED:');
  for (const f of failures) { console.log('  · ' + f); }
  rmSync(sandbox, { recursive: true, force: true });
  process.exit(1);
}
console.log('RESULT: 全部通过（自动选择 unicode 名字链已闭合）');
rmSync(sandbox, { recursive: true, force: true });
