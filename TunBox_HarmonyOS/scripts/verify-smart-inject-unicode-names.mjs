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
 *   C. 全链：真实 profile 原文 → merge → injectSmartPrimary 成功，
 *      且注入的 smart 组成员名与 proxies 段节点名**逐字相同**（这是内核寻址的前提）。
 *
 * 断言方式：Node 原生 TS type-stripping **直接加载 YamlMerger.ets / ProfileConfigMerger.ets
 * 源文件本体**（只把 SDK import 换成最小垫片），被测逻辑一行都不在垫片里重写。
 *
 * 用法: node scripts/verify-smart-inject-unicode-names.mjs
 * 退出码: 0 = 全部断言通过；1 = 有断言失败
 */
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
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
const sandbox = join(tmpdir(), 'tunbox-smartunicode-verify-' + process.pid);
rmSync(sandbox, { recursive: true, force: true });
mkdirSync(sandbox, { recursive: true });
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

// ── C. 全链：真实 profile（PrepareProfile 重序列化形态）→ merge → inject ──
console.log('\n[C] 全链：重序列化 profile → merge → injectSmartPrimary');
const profileYaml = [
  'mixed-port: 7890',
  'mode: rule',
  'proxies:',
  '  - { name: "\\U0001F1EF\\U0001F1F5日本•移联01", type: socks5, server: a.example, port: 1 }',
  '  - { name: "\\U0001F1F8\\U0001F1EC新加坡•移联01", type: socks5, server: b.example, port: 2 }',
  '  - { name: 剩余流量：947.23 GB, type: socks5, server: c.example, port: 3 }',
  'proxy-groups:',
  '    - name: 吹雪云',
  '      type: select',
  '      proxies:',
  '        - 自动选择',
  '        - "\\U0001F1EF\\U0001F1F5日本•移联01"',
  '        - "\\U0001F1F8\\U0001F1EC新加坡•移联01"',
  '    - name: 自动选择',
  '      type: url-test',
  '      proxies:',
  '        - "\\U0001F1EF\\U0001F1F5日本•移联01"',
  'rules:',
  '    - MATCH,吹雪云',
  '',
].join('\n');
const overlay = ['mixed-port: 7890', 'mode: rule', 'proxies: []', 'proxy-groups: []',
  'rules:', '  - GEOIP,CN,DIRECT', ''].join('\n');

const merged = ProfileConfigMerger.merge(overlay, profileYaml);
record('merge 成功', merged.ok === true, merged.error);

const SMART_NAME = '♻️ 自动选择';
const smartHead = [
  `  - name: "${SMART_NAME}"`,
  '    type: smart',
  '    url: "https://www.gstatic.com/generate_204"',
];
const injected = ProfileConfigMerger.injectSmartPrimary(merged.yaml, SMART_NAME, smartHead);
record('injectSmartPrimary 成功（未跳过）', injected.ok === true, injected.reason);

if (injected.ok) {
  // 取出 smart 组的成员名，与 proxies 段的节点名逐一比对
  const lines = injected.yaml.split('\n');
  const smartIdx = lines.findIndex((l) => l.indexOf(`name: "${SMART_NAME}"`) >= 0);
  record('注入后存在 smart 组', smartIdx >= 0);
  // proxies 段真实名字（解码后）
  const decodedProxies = YamlMerger.sequenceItemNames(injected.yaml, 'proxies');
  record('proxies 段读到 3 个节点', decodedProxies.length === 3,
    'got ' + decodedProxies.length + ' ' + JSON.stringify(decodedProxies));
  const emojiNode = decodedProxies.find((n) => n.indexOf('日本') >= 0) || '';
  record('proxies 段节点名是真 emoji', emojiNode.indexOf('\\') < 0 && emojiNode.length > 0,
    'got ' + JSON.stringify(emojiNode));
  // smart 组成员块：找 smartIdx 之后第一个 proxies: 起的成员行
  const memberLines = [];
  let inMembers = false;
  for (let i = smartIdx + 1; i < lines.length; i++) {
    const l = lines[i];
    if (/^\s*proxies:\s*$/.test(l)) { inMembers = true; continue; }
    if (inMembers) {
      if (/^\s*-\s/.test(l)) { memberLines.push(l.trim().replace(/^-\s*/, '').replace(/^["']|["']$/g, '')); }
      else if (l.trim().length === 0) { break; }
      else if (!l.startsWith('     ')) { break; }
    }
  }
  record('smart 组有成员', memberLines.length > 0, 'members=' + memberLines.length);
  const emojiMember = memberLines.find((m) => m.indexOf('日本') >= 0) || '';
  record('smart 组成员名是真 emoji（无字面反斜杠）',
    emojiMember.length > 0 && emojiMember.indexOf('\\') < 0,
    'got ' + JSON.stringify(emojiMember));
  record('smart 组成员名与 proxies 节点名逐字相同（内核寻址前提）',
    emojiMember === emojiNode, 'member=' + JSON.stringify(emojiMember) + ' node=' + JSON.stringify(emojiNode));
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
