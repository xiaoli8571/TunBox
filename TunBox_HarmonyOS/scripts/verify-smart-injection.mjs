#!/usr/bin/env node
/**
 * verify-smart-injection.mjs — smart 组注入订阅原文的回归（2026-10-25）
 *
 * 背景：TunBox 是「订阅原文接管」架构，ProfileConfigMerger.merge 会把生成器的
 * proxy-groups 整段顶掉 → ♻️ 自动选择(smart) 组从未进入最终配置，「自动选择」在
 * 真实订阅上空转（UI 装饰）。修复 = merge 后调用 injectSmartPrimary：smart 组追加
 * 到 proxy-groups 段尾（成员=原文自己的节点名，天然单订阅）+ 主选择组首位插入。
 *
 * 本脚本直接转译真源码（ProfileConfigMerger + YamlMerger，stubs 顶掉 @kit/AppLogger），
 * 对 injectSmartPrimary 做六组用例：机场多组结构 / 裸节点骨架 / MATCH,DIRECT /
 * 无 MATCH / 主组非 select / emoji 节点名保真。
 *
 * 纯 Node 离线跑：node scripts/verify-smart-injection.mjs
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/(?=[A-Za-z]:)/, '')), '..');
const ETS = path.join(root, 'entry/src/main/ets');

let passed = 0;
let failed = 0;
function ok(cond, label, detail = '') {
  if (cond) {
    passed++;
    console.log(`  ✅ ${label}`);
  } else {
    failed++;
    console.log(`  ❌ ${label}${detail ? `\n       ${detail}` : ''}`);
  }
}
function section(title) {
  console.log(`\n${title}`);
}

// ── 转译（与 verify-config-single-source 同手法：只重写 import 目标）──────────
const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'tunbox-smart-inject-'));
process.on('exit', () => {
  try { fs.rmSync(tmpRoot, { recursive: true, force: true }); } catch (e) { /* 清理失败不影响结论 */ }
});
fs.cpSync(ETS, path.join(tmpRoot, 'ets'), { recursive: true });
fs.copyFileSync(path.join(root, 'tools/true-chain-harness/stubs.ts'), path.join(tmpRoot, 'stubs.ts'));

const IMPORT_RE = /import\s+(?:type\s+)?(?:([A-Za-z_$][\w$]*)\s*,\s*)?(?:\{([^}]*)\}|\*\s+as\s+[A-Za-z_$][\w$]*|([A-Za-z_$][\w$]*))?\s+from\s*'([^']+)'/g;

function transpile(relSrc, outName, importMap) {
  const src = fs.readFileSync(path.join(tmpRoot, 'ets', relSrc), 'utf8');
  const unresolved = [];
  const text = src.replace(IMPORT_RE, (m, _d1, _named, _d2, spec) => {
    const target = importMap[spec];
    if (target === undefined) {
      unresolved.push(spec);
      return `/* [UNRESOLVED] ${m} */`;
    }
    return m.replace(`'${spec}'`, `'${target}'`);
  });
  if (unresolved.length > 0) {
    throw new Error(`转译 ${relSrc} 失败：未映射的 import ${unresolved.join(', ')}`);
  }
  fs.writeFileSync(path.join(tmpRoot, outName), text, 'utf8');
}

transpile('commons/services/YamlMerger.ets', 'YamlMerger.ts', {
  '@kit.ArkTS': './stubs.ts',
});
transpile('commons/flclash/ProfileConfigMerger.ets', 'ProfileConfigMerger.ts', {
  '../services/YamlMerger': './YamlMerger.ts',
  '../utils/AppLogger': './stubs.ts',
});

const { ProfileConfigMerger } = await import(pathToFileURL(path.join(tmpRoot, 'ProfileConfigMerger.ts')).href);

const SMART_NAME = '♻️ 自动选择';
const SMART_HEAD = [
  `  - name: "${SMART_NAME}"`,
  '    type: smart',
  '    uselightgbm: true',
  '    collectdata: false',
  '    prefer-asn: false',
  '    url: "https://www.gstatic.com/generate_204"',
  '    exclude-filter: "(剩余流量|套餐到期|官网|客服)"'
];

function groupMembers(yaml, groupName) {
  const lines = yaml.split('\n');
  const nameLines = [`  - name: ${groupName}`, `  - name: "${groupName}"`, `  - name: '${groupName}'`];
  const start = lines.findIndex((l) => nameLines.includes(l));
  if (start < 0) { return null; }
  const members = [];
  let inProxies = false;
  for (let i = start + 1; i < lines.length; i++) {
    const l = lines[i];
    if (l.startsWith('  - ')) { break; }              // 下一个组
    if (l.trim() === 'proxies:') { inProxies = true; continue; }
    if (!l.startsWith(' ') || (l.startsWith('  -') && !l.startsWith('   '))) { break; } // 出段
    if (/^\s{2,4}[^ ]/.test(l)) { inProxies = false; continue; }               // 组内其它键 → 退出成员列表
    if (inProxies && /^ {6,}-\s/.test(l)) {
      members.push(l.trim().replace(/^-\s+/, '').replace(/^['"]|['"]$/g, ''));
    }
  }
  return members;
}

// ── 用例 1：机场多组结构（selector 主组 + 内嵌 url-test 自动组）──────────────
section('── 用例 1：机场多组结构（MATCH → 主选择组，节点挂在 url-test 下）──');
const airport = [
  'port: 7890',
  'proxies:',
  '  - {name: "🇸🇬 新加坡01", server: sg1.example.com, port: 443, type: vless, uuid: u1}',
  '  - {name: "🇯🇵 日本•移联01", server: jp1.example.com, port: 443, type: vless, uuid: u2}',
  '  - {name: "🇺🇸 美国03", server: us1.example.com, port: 443, type: vless, uuid: u3}',
  'proxy-groups:',
  '  - name: "🚀 节点选择"',
  '    type: select',
  '    proxies:',
  '      - "♻️ 自动选择"',
  '      - "🇸🇬 新加坡01"',
  '      - "🇯🇵 日本•移联01"',
  '      - "🇺🇸 美国03"',
  '  - name: "♻️ 自动选择"',
  '    type: url-test',
  '    url: http://www.gstatic.com/generate_204',
  '    interval: 300',
  '    proxies:',
  '      - "🇸🇬 新加坡01"',
  '      - "🇯🇵 日本•移联01"',
  '      - "🇺🇸 美国03"',
  'rules:',
  '  - DOMAIN-SUFFIX,google.com,🚀 节点选择',
  '  - MATCH,🚀 节点选择'
].join('\n');
const r1 = ProfileConfigMerger.injectSmartPrimary(airport, SMART_NAME, SMART_HEAD.slice());
ok(r1.ok, '注入成功', r1.reason);
ok(r1.reason.includes('primary=🚀 节点选择'), `主选择组识别正确（${r1.reason}）`);
if (r1.ok) {
  const primaryMembers = groupMembers(r1.yaml, '🚀 节点选择');
  ok(primaryMembers !== null && primaryMembers[0] === SMART_NAME,
    '主选择组首位 = smart 组', JSON.stringify(primaryMembers));
  const smartMembers = groupMembers(r1.yaml, SMART_NAME);
  ok(smartMembers !== null && smartMembers.includes('🇯🇵 日本•移联01') && smartMembers.includes('🇺🇸 美国03'),
    `smart 组成员 = 原文节点（${smartMembers ? smartMembers.length : 0} 个）`);
  ok(smartMembers !== null && !smartMembers.some((m) => m.includes('剩余流量')),
    'smart 组不含信息条（成员本就来自真实节点表）');
  // 原 url-test 组不被污染
  const autoMembers = groupMembers(r1.yaml, '♻️ 自动选择');
  ok(autoMembers !== null && autoMembers.length === 3 && !autoMembers.includes(SMART_NAME),
    '机场自带 url-test 组原样保留');
  ok(r1.yaml.includes('  - name: "♻️ 自动选择"\n    type: smart'), 'smart 组定义已追加（type: smart）');
  // 规则未被动过
  ok(r1.yaml.includes('MATCH,🚀 节点选择'), 'MATCH 规则原样保留');
  // 生成 YAML 无重复组名（uniqueKeys 安全：name 是序列项不是映射键，但同段两个同名组会歧义）
  const smartDefs = r1.yaml.split('\n').filter((l) => l.startsWith('  - name: "') && l.includes(SMART_NAME));
  ok(smartDefs.length === 2, '两个 ♻️ 组共存（机场 url-test + 注入 smart）无重名冲突');
}

// ── 用例 2：裸节点骨架（withSyntheticGroups 形态）───────────────────────────
section('── 用例 2：裸节点骨架（MATCH,手动选择）──');
const bare = [
  'proxies:',
  '  - {name: "香港01", server: h1.example.com, port: 443, type: ss, cipher: aes-128-gcm, password: p}',
  '  - {name: "香港02", server: h2.example.com, port: 443, type: ss, cipher: aes-128-gcm, password: p}',
  'proxy-groups:',
  '  - name: 手动选择',
  '    type: select',
  '    proxies:',
  '      - 香港01',
  '      - 香港02',
  '      - DIRECT',
  '  - name: 自动选择',
  '    type: url-test',
  '    interval: 300',
  '    proxies:',
  '      - 香港01',
  '      - 香港02',
  'rules:',
  '  - MATCH,手动选择'
].join('\n');
const r2 = ProfileConfigMerger.injectSmartPrimary(bare, SMART_NAME, SMART_HEAD.slice());
ok(r2.ok, '注入成功', r2.reason);
if (r2.ok) {
  const m = groupMembers(r2.yaml, '手动选择');
  ok(m !== null && m[0] === SMART_NAME && m.includes('DIRECT'), '首位插入且 DIRECT 保留', JSON.stringify(m));
}

// ── 用例 3：MATCH,DIRECT → 拒绝注入 ────────────────────────────────────────
section('── 用例 3：MATCH,DIRECT ──');
const direct = airport.replace('MATCH,🚀 节点选择', 'MATCH,DIRECT');
const r3 = ProfileConfigMerger.injectSmartPrimary(direct, SMART_NAME, SMART_HEAD.slice());
ok(!r3.ok && r3.reason.includes('DIRECT'), `拒绝注入（${r3.reason}）`);
ok(r3.yaml === direct, '原文未被修改');

// ── 用例 4：无 MATCH 规则 → 拒绝注入 ───────────────────────────────────────
section('── 用例 4：无 MATCH ──');
const noMatch = airport.split('\n').filter((l) => !l.includes('MATCH,')).join('\n');
const r4 = ProfileConfigMerger.injectSmartPrimary(noMatch, SMART_NAME, SMART_HEAD.slice());
ok(!r4.ok && r4.reason.includes('no MATCH'), `拒绝注入（${r4.reason}）`);

// ── 用例 5：主组是 url-test → 拒绝注入 ─────────────────────────────────────
section('── 用例 5：主组非 select ──');
const autoPrimary = airport
  .replace('  - name: "🚀 节点选择"\n    type: select', '  - name: "🚀 节点选择"\n    type: url-test')
  .replace('MATCH,🚀 节点选择', 'MATCH,♻️ 自动选择');
// MATCH 指向机场自带 url-test 组 → 拒绝（不可钉选、语义不符）
const r5 = ProfileConfigMerger.injectSmartPrimary(autoPrimary, SMART_NAME, SMART_HEAD.slice());
ok(!r5.ok && r5.reason.includes('not select'), `拒绝注入（${r5.reason}）`);

// ── 用例 6：纯 provider 订阅（无静态 proxies）→ 拒绝注入 ───────────────────
section('── 用例 6：provider-only 无成员池 ──');
const providerOnly = [
  'proxy-providers:',
  '  sub1:',
  '    type: http',
  '    url: "https://example.com/sub"',
  '    path: ./sub1.yaml',
  'proxy-groups:',
  '  - name: "🚀 节点选择"',
  '    type: select',
  '    use:',
  '      - sub1',
  'rules:',
  '  - MATCH,🚀 节点选择'
].join('\n');
const r6 = ProfileConfigMerger.injectSmartPrimary(providerOnly, SMART_NAME, SMART_HEAD.slice());
ok(!r6.ok && r6.reason.includes('provider-only'), `拒绝注入（${r6.reason}）`);

// ── 汇总 ──────────────────────────────────────────────────────────────────
console.log(`\n-----------------------------------------`);
console.log(`PASSED=${passed}  FAILED=${failed}`);
if (failed > 0) {
  console.log('RESULT: SMART INJECTION CHECKS FAILED');
  process.exit(1);
}
console.log('RESULT: SMART INJECTION CHECKS PASSED');
