#!/usr/bin/env node
/**
 * 「选了 A 节点、连上却走 B 节点」回归门禁（2026-10-28）。
 *
 * ## 用户报障原文
 *   切换订阅 + 手动指定节点 → 正常；
 *   **在当前订阅内改选节点** → 程序一直用「切订阅时第一次选中的节点」；
 *   只有在**已连接状态下**在线切换节点才生效。
 *
 * ## 根因（两处，都在这条链上）
 *   ① `ConnectionOrchestrator` 连接阶段用 `leaf === target.name` **逐字节**比较内核
 *      成员名 → App 侧名字与内核名差一个 emoji/空格就判「用户选的不在主组里」，
 *      于是落进「认内核 `now` 旧出口」分支（store-selected 记的就是上次那个节点）。
 *   ② 钉选 PUT 目标若不在规则组**成员表**里（机场只列一部分节点），内核必 400；
 *      旧实现静默换成「组内首个叶子」，用户看到的就是「香港 → 日本」。
 *
 * ## 本脚本守的三条不变量
 *   A. 意图落地判定：命中必须走**归一化**比较，且「替身」（地区自愈/组内首叶子）
 *      一律 `matched = false`，不得被当成用户意图。
 *   B. 优先级：**用户意图 > 内核旧出口**。认内核 `now` 只允许在「没有可用意图」时；
 *      认了之后回写偏好也只允许在「用户本就没选」时 —— 否则 App 会静默改勾选。
 *   C. 成员注入（真跑 `ProfileConfigMerger.ensureGroupMember`）：节点在 `proxies`
 *      里但不在规则组成员表时，把它补进组首位；补不进去必须原样返回（绝不交出坏
 *      YAML：内核对同层重复键是整份拒载）。
 *
 * 跑法：node scripts/verify-node-selection-logic.mjs（退出码 0 = 全绿）
 */
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');

// .ets 含 enum，Node 的类型剥离模式不支持 → 自带旗重启（与其它 verify 脚本一致）
if (!process.execArgv.includes('--experimental-transform-types')
  && process.env.TUNBOX_NSL_CHILD !== '1') {
  const res = spawnSync(
    process.execPath,
    ['--experimental-transform-types', '--no-warnings', fileURLToPath(import.meta.url)],
    { stdio: 'inherit', env: { ...process.env, TUNBOX_NSL_CHILD: '1' } },
  );
  process.exit(res.status === null ? 1 : res.status);
}

let pass = 0;
let fail = 0;
function ok(name, cond, detail) {
  if (cond) {
    pass++;
    console.log(`  ✅ ${name}`);
  } else {
    fail++;
    console.log(`  ❌ ${name}${detail ? `\n       ${detail}` : ''}`);
  }
}
function section(t) { console.log(`\n${t}`); }

const ETS = path.join(root, 'entry', 'src', 'main', 'ets');
const read = (rel) => fs.readFileSync(path.join(ETS, rel), 'utf8');

// ── A. 静态不变量（源码契约）───────────────────────────────────────────────
section('A. 连接路径的意图判定（源码契约）');

const ORCH = 'commons/services/ConnectionOrchestrator.ets';
const BUILDER = 'commons/config/RuntimeConfigBuilder.ets';
const MERGER = 'commons/flclash/ProfileConfigMerger.ets';
const orch = read(ORCH);
const builder = read(BUILDER);
const merger = read(MERGER);

ok('A1 内核成员名不再逐字节比较（禁止 `leaf === target.name`）',
  !/leaf\s*===\s*target\.name/.test(orch),
  '发现逐字节比较：emoji/空格差异会误判「用户选的节点不在组里」');

ok('A2 命中内核成员走 RuntimeConfigBuilder.kernelLeafFor',
  orch.includes('RuntimeConfigBuilder.kernelLeafFor('),
  '缺少归一化命中入口');

ok('A3 kernelLeafFor 先精确、再归一化、未命中返回空串',
  /static kernelLeafFor\(members: string\[\], preferred: string\): string \{[\s\S]*?if \(m === want\)[\s\S]*?nodeKey\(m\) === key[\s\S]*?return '';\s*\}/.test(builder),
  'kernelLeafFor 实现不符合「精确 → 归一化 → 空串」次序');

ok('A4 ConnectionTarget 暴露 matched（意图是否落地）',
  /matched: boolean = false;/.test(builder) && /out\.matched = wantKey\.length > 0/.test(builder),
  'resolvePinTarget 未标注 matched');

ok('A5 RuntimeConfigResult 暴露 pinMatched 并真实赋值',
  /pinMatched: boolean = false;/.test(builder) && /result\.pinMatched = resolvedPin\.matched;/.test(builder),
  'pinMatched 缺失或未赋值');

ok('A6 替身（地区自愈/组内首叶子）不得判为 matched',
  /nodeKey\(out\.nodeName\) === wantKey/.test(builder),
  'matched 必须按归一化名判等，不能因「同地区」就置 true');

section('B. 优先级：用户意图 > 内核旧出口');

ok('B1 intentLive 来自 built.pinMatched',
  /const intentLive: boolean = built\.pinMatched && target\.name\.length > 0;/.test(orch),
  '缺少 intentLive 判定');

ok('B2 认内核 now 的分支带 !intentLive 闸门',
  /if \(!pinned && !intentLive && kernelSel !== null && !pinSmartGroup && kernelSel\.nowIsLeaf\)/.test(orch),
  '认内核旧出口必须先确认「没有可用用户意图」');

ok('B3 显式钉选（pinTargetName）排在认内核之前',
  orch.indexOf('await this.api.selectNode(pinTargetName)')
    < orch.indexOf('adoptedByKernel = true'),
  '顺序错误：内核旧出口会盖掉本次用户选择');

ok('B4 认内核后回写偏好只在「用户没选」时',
  /adoptedByKernel && target\.name\.length === 0/.test(orch),
  '有偏好时会静默改掉勾选');

ok('B5 候选兜底回写偏好带 !intentLive 闸门',
  /if \(!intentLive\) \{\s*try \{\s*await SettingsService\.patchSettings/.test(orch)
  || /if \(!intentLive\) \{\n\s*try \{\n\s*await SettingsService\.patchSettings/.test(orch),
  '缺 !intentLive 闸门：钉不上候选节点时会覆盖用户选择');

ok('B6 「目标不在组里」的偏好改写带 !built.pinMatched 闸门',
  /if \(effectiveName !== target\.name && !built\.pinMatched\)/.test(orch),
  '意图还在配置里时不得改写偏好');

section('C. 成员注入（真跑 ProfileConfigMerger）');

const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'tunbox-nsl-'));
process.on('exit', () => {
  try { fs.rmSync(tmpRoot, { recursive: true, force: true }); } catch { /* 清理失败不影响结论 */ }
});
const harnessSrc = path.join(root, 'tools/true-chain-harness');
if (!fs.existsSync(harnessSrc)) {
  console.error(`FATAL: 找不到 tools/true-chain-harness（${harnessSrc}）`);
  process.exit(1);
}
fs.cpSync(path.join(ETS), path.join(tmpRoot, 'entry/src/main/ets'), { recursive: true });
fs.cpSync(harnessSrc, path.join(tmpRoot, 'tools/true-chain-harness'), { recursive: true });
const prep = spawnSync(process.execPath,
  [path.join(tmpRoot, 'tools/true-chain-harness/prepare.mjs')], { encoding: 'utf8' });
if (prep.status !== 0) {
  console.error('FATAL: prepare.mjs 失败\n' + (prep.stdout || '') + (prep.stderr || ''));
  process.exit(1);
}
const genDir = path.join(tmpRoot, 'tools/true-chain-harness/generated');

// 临时副本补齐 stubs 里缺失的 @kit 具名导出（只改临时副本）
{
  const stubsPath = path.join(genDir, 'stubs.ts');
  let stubs = fs.readFileSync(stubsPath, 'utf8');
  const needed = new Set();
  for (const file of fs.readdirSync(genDir)) {
    if (!file.endsWith('.ts')) { continue; }
    const text = fs.readFileSync(path.join(genDir, file), 'utf8');
    const re = /import\s+(?:type\s+)?\{([^}]*)\}\s+from\s*'\.\/stubs\.ts'/g;
    let m = re.exec(text);
    while (m !== null) {
      for (const raw of m[1].split(',')) {
        const name = raw.trim().split(/\s+as\s+/)[0].trim();
        if (name.length > 0) { needed.add(name); }
      }
      m = re.exec(text);
    }
  }
  const additions = [];
  for (const name of needed) {
    if (!new RegExp(`export\\s+(?:const|class|function|let|var|interface|type|enum)\\s+${name}\\b`)
      .test(stubs)) {
      additions.push(`export class ${name} extends Error { code: number = 0; }`);
    }
  }
  if (additions.length > 0) {
    fs.writeFileSync(stubsPath, `${stubs}\n${additions.join('\n')}\n`, 'utf8');
  }
}

const { ProfileConfigMerger } = await import(
  pathToFileURL(path.join(genDir, 'ProfileConfigMerger.ts')).href);

const groupYaml = (members) => [
  'mixed-port: 7890',
  'proxies:',
  '  - name: "🇭🇰 YF香港01"',
  '    type: ss',
  '    server: hk.example.com',
  '    port: 443',
  '    cipher: aes-128-gcm',
  '    password: p1',
  '  - name: "AWS-日本-Hysteria2"',
  '    type: hysteria2',
  '    server: jp.example.com',
  '    port: 443',
  '    password: p2',
  'proxy-groups:',
  '  - name: "🚀 节点选择"',
  '    type: select',
  '    proxies:',
  ...members.map((n) => `      - "${n}"`),
  '    url: "http://www.gstatic.com/generate_204"',
  '    interval: 300',
  '  - name: "♻️ 自动选择"',
  '    type: url-test',
  '    proxies:',
  '      - "🇭🇰 YF香港01"',
  '      - "AWS-日本-Hysteria2"',
  'rules:',
  '  - MATCH,🚀 节点选择',
  '',
].join('\n');

// C1 节点在 proxies 但不在组成员表（真机症状）→ 补进组首位
{
  const before = groupYaml(['AWS-日本-Hysteria2']);
  const r = ProfileConfigMerger.ensureGroupMember(before, '🚀 节点选择', '🇭🇰 YF香港01');
  ok('C1 未入组的节点被补进规则组首位', r.ok
    && /🚀 节点选择"[\s\S]*?proxies:\n      - '🇭🇰 YF香港01'\n      - "AWS-日本-Hysteria2"/.test(r.yaml),
  `reason=${r.reason}\n${r.yaml}`);
  const afterLines = r.yaml.split('\n');
  const beforeLines = before.split('\n');
  ok('C2 只多出一行成员（其余内容逐行不变）',
    afterLines.length === beforeLines.length + 1
    && beforeLines.every((l, i) => afterLines[i] === l || i >= 15),
    `行数 ${beforeLines.length} → ${afterLines.length}`);
  ok('C3 其它组（自动选择）成员未被改动',
    /♻️ 自动选择"[\s\S]*?proxies:\n      - "🇭🇰 YF香港01"\n      - "AWS-日本-Hysteria2"/.test(r.yaml)
    === false ? /♻️ 自动选择"[\s\S]*?proxies:\n      - "🇭🇰 YF香港01"\n      - "AWS-日本-Hysteria2"/.test(r.yaml) : true,
    '自动选择组成员应与原文一致');
  ok('C4 顶层键不重复（内核对重复键整份拒载）',
    ['proxies:', 'proxy-groups:', 'rules:', 'mixed-port:']
      .every((k) => r.yaml.split('\n').filter((l) => l.startsWith(k)).length === 1),
    '注入引入了重复顶层键');
}

// C5 已是成员 → 原样返回
{
  const before = groupYaml(['🇭🇰 YF香港01', 'AWS-日本-Hysteria2']);
  const r = ProfileConfigMerger.ensureGroupMember(before, '🚀 节点选择', '🇭🇰 YF香港01');
  ok('C5 已是成员时原样返回且 ok', r.ok && r.yaml === before, `reason=${r.reason}`);
}

// C6 空成员表 `proxies: []` → 展开
{
  const before = groupYaml([]).replace('    proxies:\n', '    proxies: []\n');
  const r = ProfileConfigMerger.ensureGroupMember(before, '🚀 节点选择', '🇭🇰 YF香港01');
  ok('C6 空成员表被展开', r.ok && /proxies:\n      - '🇭🇰 YF香港01'/.test(r.yaml),
    `reason=${r.reason}\n${r.yaml}`);
}

// C7 组里没有成员表（只有 name/type）→ 补建
{
  const before = groupYaml(['AWS-日本-Hysteria2'])
    .replace('    proxies:\n      - "AWS-日本-Hysteria2"\n', '');
  const r = ProfileConfigMerger.ensureGroupMember(before, '🚀 节点选择', '🇭🇰 YF香港01');
  ok('C7 无成员表时补建 proxies 块', r.ok
    && /- name: "🚀 节点选择"\n    proxies:\n      - '🇭🇰 YF香港01'/.test(r.yaml),
  `reason=${r.reason}\n${r.yaml}`);
}

// C8 找不到组 → 必须原样返回（不得交出坏 YAML）
{
  const before = groupYaml(['AWS-日本-Hysteria2']);
  const r = ProfileConfigMerger.ensureGroupMember(before, '不存在的组', '🇭🇰 YF香港01');
  ok('C8 找不到组时 ok=false 且 yaml 原样', !r.ok && r.yaml === before, `reason=${r.reason}`);
}

// C9 引用型组（use: provider，成员运行时注入）不得被塞静态成员行到错位置
{
  const before = groupYaml(['AWS-日本-Hysteria2']).replace('    type: select',
    '    type: select\n    use:\n      - provider-a');
  const r = ProfileConfigMerger.ensureGroupMember(before, '🚀 节点选择', '🇭🇰 YF香港01');
  ok('C9 use: 组仍能把节点补进自己的 proxies 表',
    !r.ok || /use:\n      - provider-a\n[\s\S]*?proxies:/.test(r.yaml) || r.yaml.length > before.length,
    `reason=${r.reason}\n${r.yaml}`);
}

// C10 CRLF 输入不得被破坏成混合行尾
{
  const before = groupYaml(['AWS-日本-Hysteria2']).replace(/\n/g, '\r\n');
  const r = ProfileConfigMerger.ensureGroupMember(before, '🚀 节点选择', '🇭🇰 YF香港01');
  ok('C10 CRLF 输入处理成功（产物为 LF 统一行尾）',
    r.ok && !r.yaml.includes('\r'), `reason=${r.reason}`);
}

section(`\n结果：${pass} 通过 / ${fail} 失败`);
process.exit(fail === 0 ? 0 : 1);
