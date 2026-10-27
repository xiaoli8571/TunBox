#!/usr/bin/env node
/**
 * 配置生成「完整性」验证 —— mihomo 启动失败（parse config: yaml: unmarshal errors）的回归门禁。
 *
 * 背景（2026-10-20 用户报障原文：Clash 内核启动失败: VPN 扩展启动异常:
 *       parse config:yaml: unmarshal errors:...）：
 *   mihomo 用 go.yaml.in/yaml/v3 v3.0.5，**uniqueKeys 默认开启**（decode.go:344）
 *   → 同一层级的重复键 = TypeError = **整份配置拒载**（全有全无：一个节点坏，
 *     整个 VPN 起不来），**不是**「后者覆盖前者」。
 *   yaml.v3 是 YAML 1.2 core schema：`yes/no/on/off` 解析为 **!!str**（不是 bool）
 *   → 落进 RawConfig 的 bool 字段就是 `cannot unmarshal !!str 'yes' into bool`。
 *
 * 本脚本**真跑**真实源码：
 *   ① 把 entry/src/main/ets + tools/true-chain-harness 复制到**临时目录**（不污染仓库，
 *      不改动 tools/true-chain-harness/generated 里的入库文件）；
 *   ② 跑真实的 tools/true-chain-harness/prepare.mjs（只重写 import 目标 + 注入系统能力 stub，
 *      解析/合并/映射逻辑一行不改），转译出可在 Node 里执行的 .ts；
 *   ③ 直接 import 转译后的**真实 ClashConfigGenerator / YamlMerger / SubscriptionService**，
 *      驱动真实的 ClashConfigGenerator.generate() 产出**真实内核配置**再断言。
 *
 * 覆盖场景（与《订阅解析内核化改造方案》§9.3 根因表一一对应）：
 *   1. flow-map 节点内重复键（R0/R0b，依赖 C15）→ 产物同 map 内不再出现重复键
 *   2. 点号 provider 名（R1）→ 键行保留为键行、字段仍归属它、RULE-SET 引用不再被丢弃
 *   3. 同名 provider（R4）→ 只出现一次，字段行没有落进上一条 provider
 *   4. 字段键名不同的同名 provider（R4'''）→ 整块被丢弃（不静默并错）
 *   5. 覆盖层写 dns:（R2）→ 产物顶层 dns: 只出现一次
 *   6. 覆盖层写 allow-lan: yes（R3）→ 产物是 allow-lan: true
 *   7. rules 行带 '- ' 前缀（R6）→ rules: 段没有嵌套 seq
 *   8. 产物含 store-selected: true（C22）且不含 store-selections
 *   9. safeGroupUrl('') 兜底是 https（C4）
 *  10. 产物「同层级重复键」扫描 → 0 问题
 *
 * 跑法：node scripts/verify-config-generation-integrity.mjs
 * 退出码 0 = 全绿。
 */
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');

// ── 0. .ets 里含 enum（ProxyDropReason），Node 的类型剥离模式不支持 enum，
//      必须用 --experimental-transform-types（整链转译）。本脚本自己带旗重启一次，
//      保证「node scripts/verify-config-generation-integrity.mjs」直接可跑。
if (!process.execArgv.includes('--experimental-transform-types')
  && process.env.TUNBOX_CFG_INTEGRITY_CHILD !== '1') {
  const res = spawnSync(
    process.execPath,
    ['--experimental-transform-types', '--no-warnings', fileURLToPath(import.meta.url)],
    { stdio: 'inherit', env: { ...process.env, TUNBOX_CFG_INTEGRITY_CHILD: '1' } },
  );
  process.exit(res.status === null ? 1 : res.status);
}

// ── 断言框架 ───────────────────────────────────────────────────────────────
let passed = 0;
let failed = 0;
let deferred = 0;

function ok(cond, label, detail) {
  if (cond) {
    passed++;
    console.log(`  ✅ ${label}`);
  } else {
    failed++;
    console.log(`  ❌ ${label}${detail ? `\n       ${detail}` : ''}`);
  }
}

function eq(actual, expected, label) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  ok(a === e, label, `期望 ${e}\n       实际 ${a}`);
}

function note(label, detail) {
  deferred++;
  console.log(`  ⏭ DEFERRED ${label}${detail ? `\n       ${detail}` : ''}`);
}

function section(title) {
  console.log(`\n${title}`);
}

// ── 1. 准备临时转译环境（真源码 → 真 .ts，不写仓库）─────────────────────────
const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'tunbox-cfg-integrity-'));
function cleanup() {
  try {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  } catch (e) {
    /* 临时目录清理失败不影响结论 */
  }
}

const harnessSrc = path.join(root, 'tools/true-chain-harness');
if (!fs.existsSync(harnessSrc)) {
  console.error(`FATAL: 找不到 tools/true-chain-harness（${harnessSrc}）`);
  process.exit(1);
}
fs.cpSync(path.join(root, 'entry/src/main/ets'), path.join(tmpRoot, 'entry/src/main/ets'),
  { recursive: true });
fs.cpSync(harnessSrc, path.join(tmpRoot, 'tools/true-chain-harness'), { recursive: true });
const prep = spawnSync(process.execPath,
  [path.join(tmpRoot, 'tools/true-chain-harness/prepare.mjs')],
  { encoding: 'utf8' });
if (prep.status !== 0) {
  console.error('FATAL: prepare.mjs 失败\n' + (prep.stdout || '') + (prep.stderr || ''));
  process.exit(1);
}
const genDir = path.join(tmpRoot, 'tools/true-chain-harness/generated');
const G = (name) => pathToFileURL(path.join(genDir, name)).href;

/**
 * 临时副本的 stubs 补丁：harness 的 stubs.ts 未必覆盖后来新增的 @kit.* 具名导出
 * （例如 @kit.BasicServicesKit 的 BusinessError）——缺一个具名导出就会让整个
 * import 链 SyntaxError。**只在临时副本里补最小替身**，不碰仓库里的任何文件。
 */
function patchTempStubs() {
  const stubsPath = path.join(genDir, 'stubs.ts');
  let stubs = fs.readFileSync(stubsPath, 'utf8');
  const needed = new Set();
  for (const file of fs.readdirSync(genDir)) {
    if (!file.endsWith('.ts')) {
      continue;
    }
    const text = fs.readFileSync(path.join(genDir, file), 'utf8');
    const re = /import\s+(?:type\s+)?\{([^}]*)\}\s+from\s*'\.\/stubs\.ts'/g;
    let m = re.exec(text);
    while (m !== null) {
      for (const raw of m[1].split(',')) {
        const name = raw.trim().split(/\s+as\s+/)[0].trim();
        if (name.length > 0) {
          needed.add(name);
        }
      }
      m = re.exec(text);
    }
  }
  const additions = [];
  for (const name of needed) {
    const exported = new RegExp(
      `export\\s+(?:const|class|function|let|var|interface|type|enum)\\s+${name}\\b`,
    );
    if (!exported.test(stubs)) {
      additions.push(`export class ${name} extends Error { code: number = 0; }`);
    }
  }
  if (additions.length > 0) {
    fs.writeFileSync(stubsPath,
      `${stubs}\n// [verify-config-generation-integrity] 临时补齐缺失的 @kit 具名导出\n`
      + `${additions.join('\n')}\n`, 'utf8');
    console.log(`（临时副本补齐 stubs 导出：${additions.length} 个）`);
  }
}
patchTempStubs();

const { ClashConfigGenerator } = await import(G('ClashConfigGenerator.ts'));
const { AppSettings } = await import(G('AppSettings.ts'));
const { ProxyNode } = await import(G('ProxyNode.ts'));
const { ProxyGroup } = await import(G('ProxyGroup.ts'));
const { YamlMerger } = await import(G('YamlMerger.ts'));
const { SubscriptionService } = await import(G('SubscriptionService.ts'));

// ── 2. 通用工具 ────────────────────────────────────────────────────────────

/** 取第一行以 prefix 开头的行（缩进敏感）。 */
function findLine(lines, prefix) {
  for (const line of lines) {
    if (line.startsWith(prefix)) {
      return line;
    }
  }
  return null;
}

/** 统计「顶层键」出现次数（indent 0 的 key: 行）。 */
function countTopLevelKey(text, key) {
  let count = 0;
  for (const raw of text.split('\n')) {
    if (raw.length === 0 || raw.startsWith(' ') || raw.startsWith('\t')) {
      continue;
    }
    const t = raw.trim();
    if (t === key || t.startsWith(`${key}:`) || t.startsWith(`${key} `)) {
      count++;
    }
  }
  return count;
}

/** 在引号外找第一个冒号 → [key, value]；没有冒号返回 null。 */
function splitKey(content) {
  let quote = '';
  let depth = 0;
  for (let i = 0; i < content.length; i++) {
    const ch = content.charAt(i);
    if (quote.length > 0) {
      if (ch === quote) {
        quote = '';
      }
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }
    if (ch === '{' || ch === '[') {
      depth++;
      continue;
    }
    if (ch === '}' || ch === ']') {
      depth--;
      continue;
    }
    if (ch === ':' && depth === 0) {
      return { key: content.substring(0, i).trim(), value: content.substring(i + 1).trim() };
    }
  }
  return null;
}

/** 去掉尾部注释（引号感知）。 */
function stripComment(value) {
  const text = value.trim();
  if (text.startsWith('#')) {
    return '';
  }
  let quote = '';
  for (let i = 0; i < text.length; i++) {
    const ch = text.charAt(i);
    if (quote.length > 0) {
      if (ch === quote) {
        quote = '';
      }
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }
    if (ch === '#' && i > 0 && text.charAt(i - 1) === ' ') {
      return text.substring(0, i).trim();
    }
  }
  return text;
}

/** 按顶层分隔符切分（引号/括号感知）。 */
function splitTopLevel(text, sep) {
  const parts = [];
  let quote = '';
  let depth = 0;
  let current = '';
  for (let i = 0; i < text.length; i++) {
    const ch = text.charAt(i);
    if (quote.length > 0) {
      current += ch;
      if (ch === quote) {
        quote = '';
      }
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      current += ch;
      continue;
    }
    if (ch === '{' || ch === '[') {
      depth++;
      current += ch;
      continue;
    }
    if (ch === '}' || ch === ']') {
      depth--;
      current += ch;
      continue;
    }
    if (ch === sep && depth === 0) {
      parts.push(current);
      current = '';
      continue;
    }
    current += ch;
  }
  parts.push(current);
  return parts;
}

/** 扫描 flow collection（{...} / [...]）里的重复键。 */
function scanFlow(text, lineNo, problems) {
  const trimmed = text.trim();
  if (trimmed.startsWith('[')) {
    const inner = trimmed.substring(1, trimmed.lastIndexOf(']'));
    for (const part of splitTopLevel(inner, ',')) {
      const p = part.trim();
      if (p.startsWith('{') || p.startsWith('[')) {
        scanFlow(p, lineNo, problems);
      }
    }
    return;
  }
  if (!trimmed.startsWith('{')) {
    return;
  }
  const inner = trimmed.substring(1, trimmed.lastIndexOf('}'));
  const keys = new Set();
  for (const part of splitTopLevel(inner, ',')) {
    const p = part.trim();
    if (p.length === 0) {
      continue;
    }
    const ki = splitKey(p);
    if (ki === null) {
      continue;
    }
    if (keys.has(ki.key)) {
      problems.push({ key: ki.key, line: lineNo, where: 'flow map' });
    } else {
      keys.add(ki.key);
    }
    const v = ki.value.trim();
    if (v.startsWith('{') || v.startsWith('[')) {
      scanFlow(v, lineNo, problems);
    }
  }
}

/**
 * 「同层级重复键」扫描 —— 模拟 yaml.v3 uniqueKeys 的判定：
 * 同一个 mapping 内出现两个同名键即问题（顶层 / 块内 / flow map 内都算）。
 */
function scanDuplicateKeys(text) {
  const problems = [];
  const lines = text.split('\n');
  const root = { indent: -1, keys: new Set() };
  const stack = [root];
  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const trimmed = raw.trim();
    if (trimmed.length === 0 || trimmed.startsWith('#')) {
      continue;
    }
    const indent = raw.length - raw.trimStart().length;
    while (stack.length > 1 && stack[stack.length - 1].indent >= indent) {
      stack.pop();
    }
    let content = trimmed;
    let seqItem = false;
    if (content === '-' || content.startsWith('- ')) {
      seqItem = true;
      content = content === '-' ? '' : content.substring(2).trim();
    }
    if (content.length === 0) {
      continue;
    }
    if (content.startsWith('{') || content.startsWith('[')) {
      scanFlow(content, i + 1, problems);
      if (seqItem) {
        stack.push({ indent, keys: new Set() });
      }
      continue;
    }
    const ki = splitKey(content);
    if (ki === null) {
      continue;
    }
    const key = ki.key;
    const value = stripComment(ki.value);
    if (seqItem) {
      // 序列项本身是一个 map：键属于这个 item 自己的层级
      const itemFrame = { indent, keys: new Set() };
      itemFrame.keys.add(key);
      stack.push(itemFrame);
      continue;
    }
    const frame = stack[stack.length - 1];
    if (frame.keys.has(key)) {
      problems.push({ key, line: i + 1, where: `indent ${indent}` });
    } else {
      frame.keys.add(key);
    }
    if (value.length === 0) {
      stack.push({ indent, keys: new Set() });
    } else if (value.startsWith('{') || value.startsWith('[')) {
      scanFlow(value, i + 1, problems);
    }
  }
  return problems;
}

/** 构造一个可写入内核的 vless 节点。 */
function makeNode(name, extra) {
  const n = new ProxyNode();
  n.id = `id-${name}`;
  n.subscriptionId = 'sub-1';
  n.originalName = name;
  n.name = name;
  n.server = 'example.invalid';
  n.port = 443;
  n.proxyType = 'vless';
  n.uuid = '11111111-2222-3333-4444-555555555555';
  n.tls = true;
  if (extra) {
    Object.assign(n, extra);
  }
  return n;
}

/** 基础设置（默认全开规则、关去广告、关双轨）。 */
function baseSettings() {
  const s = new AppSettings();
  s.rulesEnabled = true;
  s.hyperAdRulesEnabled = false;
  s.useRawProviderConfig = false;
  s.customRuleSets = [];
  s.customRules = [];
  s.yamlOverride = '';
  return s;
}

/** 驱动**真实** generate()。 */
function generateConfig(opts) {
  const o = opts || {};
  const settings = o.settings || baseSettings();
  const nodes = o.nodes || [makeNode('node-A')];
  const selected = o.selected || nodes[0];
  return ClashConfigGenerator.generate(
    selected, nodes, settings,
    o.mixedPort === undefined ? 7890 : o.mixedPort,
    o.apiPort === undefined ? 9090 : o.apiPort,
    o.dnsPort === undefined ? 1053 : o.dnsPort,
    o.apiSecret === undefined ? 'secret' : o.apiSecret,
    o.useGeoip === undefined ? false : o.useGeoip,
    o.ipv6Enabled === undefined ? true : o.ipv6Enabled,
    o.proxyHosts || {},
    o.tunEnabled === undefined ? true : o.tunEnabled,
    o.proxyGroups || [],
    o.ruleProviderReady === undefined ? true : o.ruleProviderReady,
    o.useSmart === undefined ? false : o.useSmart,
    o.subscriptionRules || [],
    o.subscriptionRuleProviders || '',
    o.smartTestUrl || '',
    o.subscriptionDnsUpstreams || [],
    o.subscriptionDnsPolicies || [],
  );
}

console.log('配置生成完整性验证（mihomo yaml uniqueKeys / YAML 1.2 布尔）');
console.log(`临时转译环境：${tmpRoot}`);

// ── 真实内核（可选但强烈建议）：mihomo.exe -t -d <dir> -f <cfg> = 真判决 ──
// 本机路径：C:\Worker\TunBox\mihomo-build\<build>\mihomo.exe（与 App 内置同一份构建）。
// 找不到就整段降级为「跳过」（不判失败），保证脚本在别的机器上也能跑。
const MIHOMO_CANDIDATES = [
  // 与 App 内置内核同源的 Windows 构建（prepare.mjs 钉死的那一份）
  'C:/Worker/TunBox/TunBox-Window/extra/sidecar/mihomo-smart.exe',
  // 或者直接放在新内核源码树里的构建产物
  'C:/Worker/TunBox/mihomo-build/mihomo-smart-462455136157a760937c666bba71afe33b1a809e/mihomo.exe',
];
function findMihomo() {
  for (const p of MIHOMO_CANDIDATES) {
    if (fs.existsSync(p)) {
      return p;
    }
  }
  const buildRoot = path.join(root, '..', 'mihomo-build');
  if (fs.existsSync(buildRoot)) {
    for (const dir of fs.readdirSync(buildRoot)) {
      const candidate = path.join(buildRoot, dir, 'mihomo.exe');
      if (fs.existsSync(candidate)) {
        return candidate;
      }
    }
  }
  return '';
}
const MIHOMO = findMihomo();
console.log(MIHOMO.length > 0
  ? `真实内核：${MIHOMO}`
  : '真实内核：未找到 mihomo.exe（真实内核判定将跳过，不影响其余断言）');

/** 用真实内核判定配置是否被接受（mihomo -t）。 */
function kernelAccepts(cfgText) {
  if (MIHOMO.length === 0) {
    return { skipped: true, ok: false, output: '' };
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tunbox-kernel-'));
  const cfgPath = path.join(dir, 'config.yaml');
  fs.writeFileSync(cfgPath, cfgText, 'utf8');
  const res = spawnSync(MIHOMO, ['-t', '-d', dir, '-f', cfgPath], { encoding: 'utf8' });
  const output = `${res.stdout || ''}${res.stderr || ''}`;
  try {
    fs.rmSync(dir, { recursive: true, force: true });
  } catch (e) {
    /* 临时目录清理失败不影响结论 */
  }
  return { skipped: false, ok: res.status === 0, output };
}

/** 真实内核判定（找不到内核则跳过，不判失败）。 */
function kernelOk(cfgText, label) {
  const res = kernelAccepts(cfgText);
  if (res.skipped) {
    note(`${label}：真实内核判定（跳过：未找到 mihomo.exe）`);
    return;
  }
  ok(res.ok, `${label}：真实内核 mihomo -t 接受该配置`,
    res.ok ? '' : res.output.split('\n')
      .filter((l) => l.includes('error') || l.includes('cannot') || l.includes('failed'))
      .slice(0, 4).join('\n       '));
}

// ── 场景 1：flow-map 节点内重复键（R0 / R0b，依赖 C15）──────────────────
section('[1] flow-map 节点内重复键 → 产物同 map 内不再出现重复键（R0/R0b）');
{
  const body = [
    'proxies:',
    '  - {name: "dup-cipher", type: vless, server: ex1.invalid, port: 443, uuid: u1, cipher: aes-128-gcm, cipher: chacha20-ietf-poly1305}',
    '  - {name: "dup-nested", type: vless, server: ex2.invalid, port: 443, uuid: u2, ws-opts: {path: /a, path: /b}}',
  ].join('\n');
  const merged = YamlMerger.merge([body], 'sub', 'sub-1');
  const nodes = SubscriptionService['mergedToNodes'](merged, 'sub-1');
  ok(nodes.length === 2, `真实合并链解析出 2 个节点（实际 ${nodes.length}）`);
  const cfg = generateConfig({ nodes });
  const problems = scanDuplicateKeys(cfg);
  const dupInProxies = problems.filter((p) => p.key === 'cipher' || p.key === 'path');
  if (dupInProxies.length === 0) {
    ok(true, '产物中 flow-map 内不再出现重复键（cipher / path 各只出现一次）');
  } else {
    ok(false, '产物中 flow-map 内不再出现重复键（cipher / path 各只出现一次）',
      `仍有重复：${JSON.stringify(dupInProxies)}`);
  }
  const cipherCount = (cfg.match(/\bcipher:/g) || []).length;
  ok(cipherCount <= 2, `cipher 键出现次数 ${cipherCount}（两个节点各至多一个）`);
  const allProblems = scanDuplicateKeys(cfg);
  ok(allProblems.length === 0, '整份产物同层级重复键扫描 → 0 问题',
    JSON.stringify(allProblems));
}

// ── 场景 2：点号 provider 名（R1）────────────────────────────────────────
section('[2] 点号 provider 名（my.provider:）→ 键行保留、字段归属它、RULE-SET 不被丢弃');
{
  const providers = [
    '  my.provider:',
    '    type: http',
    '    behavior: classical',
    '    format: yaml',
    '    url: "https://example.invalid/my.provider.yaml"',
  ].join('\n');
  const cfg = generateConfig({
    subscriptionRuleProviders: providers,
    subscriptionRules: ['RULE-SET,my.provider,DIRECT'],
  });
  const lines = cfg.split('\n');
  ok(findLine(lines, '  my.provider:') !== null, '点号名的键行被保留为**键行**（2 空格）');
  ok(findLine(lines, '    type: http') !== null, '它的字段行仍是 4 空格字段行');
  const keyIdx = lines.findIndex((l) => l === '  my.provider:');
  const fieldIdx = lines.findIndex((l) => l === '    type: http');
  ok(keyIdx >= 0 && fieldIdx > keyIdx, '字段行紧跟在键行之后（没有变成兄弟键）');
  ok(cfg.includes('  - RULE-SET,my.provider,DIRECT'), '引用该 provider 的 RULE-SET 规则**未被丢弃**');
  ok(ClashConfigGenerator.lastSkippedUserRules === 0,
    `跳过的用户规则数 = 0（实际 ${ClashConfigGenerator.lastSkippedUserRules}）`);
  const problems = scanDuplicateKeys(cfg);
  ok(problems.length === 0, '产物同层级重复键扫描 → 0 问题', JSON.stringify(problems));
  kernelOk(cfg, '含点号 provider 名 + RULE-SET 引用的配置');
}

// ── 场景 3：同名 provider（R4）───────────────────────────────────────────
section('[3] 同名 provider → 只出现一次，字段行没有落进上一条 provider');
{
  const providers = [
    '  dup:',
    '    type: http',
    '    behavior: classical',
    '  dup:',
    '    type: http',
    '    interval: 3600',
  ].join('\n');
  const cfg = generateConfig({ subscriptionRuleProviders: providers });
  const lines = cfg.split('\n');
  const dupKeys = lines.filter((l) => l === '  dup:').length;
  eq(dupKeys, 1, '同名 provider 的键行只出现一次');
  ok(!cfg.includes('    interval: 3600'), '重复块的字段行被**整块丢弃**（没落进上一条）');
  ok(cfg.includes('    behavior: classical'), '第一条 provider 的字段完好保留');
  const problems = scanDuplicateKeys(cfg);
  ok(problems.length === 0, '产物同层级重复键扫描 → 0 问题', JSON.stringify(problems));
  kernelOk(cfg, '同名 provider 去重后的配置');
}

// ── 场景 4：字段键名不同的同名 provider（R4''' 静默并错）────────────────
section('[4] 字段键名与上一条不同的同名 provider → 整块被丢弃（不静默并错）');
{
  const providers = [
    '  other:',
    '    type: http',
    '    behavior: classical',
    '  dup:',
    '    type: http',
    '    behavior: classical',
    '  dup:',
    '    type: http',
    '    interval: 3600',
    '    url: "https://example.invalid/dup.yaml"',
  ].join('\n');
  const cfg = generateConfig({ subscriptionRuleProviders: providers });
  const lines = cfg.split('\n');
  eq(lines.filter((l) => l === '  dup:').length, 1, '同名 provider 只出现一次');
  ok(!cfg.includes('    interval: 3600'), '第二条 dup 的字段（interval）被整块丢弃');
  ok(!cfg.includes('https://example.invalid/dup.yaml'), '第二条 dup 的字段（url）被整块丢弃');
  ok(cfg.includes('    behavior: classical'), '第一条 dup 的字段完好保留');
  const problems = scanDuplicateKeys(cfg);
  ok(problems.length === 0, '产物同层级重复键扫描 → 0 问题', JSON.stringify(problems));
}

// ── 场景 5：覆盖层写 dns:（R2）──────────────────────────────────────────
section('[5] 覆盖层写 dns: → 产物顶层 dns: 只出现一次（R2）');
{
  const settings = baseSettings();
  settings.yamlOverride = [
    'dns:',
    '  enable: true',
    '  ipv6: false',
    '  listen: "0.0.0.0:1053"',
  ].join('\n');
  const cfg = generateConfig({ settings });
  eq(countTopLevelKey(cfg, 'dns'), 1, '顶层 dns: 只出现一次');
  ok(cfg.includes('  listen: "0.0.0.0:1053"'), '覆盖层的 dns 内容被保留（用户能力不丢）');
  const problems = scanDuplicateKeys(cfg);
  ok(problems.length === 0, '产物同层级重复键扫描 → 0 问题', JSON.stringify(problems));
  kernelOk(cfg, '覆盖层写 dns: 之后的配置');
}

// ── 场景 6：覆盖层布尔字面量（R3，按真实内核实测口径）──────────────────
section('[6] 覆盖层布尔字面量：带引号的 "true"/"1" 等致命写法必须被改写（R3）');
{
  const settings = baseSettings();
  settings.yamlOverride = [
    'allow-lan: yes',            // 裸写：内核本来就吃（实测），这里只做规范化
    'unified-delay: on',
    'tcp-concurrent: OFF',
    'ipv6: "true"',              // 带引号的 true：**致命**（!!str into bool）→ 必须改写
    'dns:',
    '  enable: "yes"',           // 带引号的 yes：内核能吃 → 保持原样
    '  respect-rules: "0"',      // 带引号的 "0"：**致命** → 必须改写
    '  ipv6: 1',                 // 裸写 1（!!int into bool）：**致命** → 必须改写
  ].join('\n');
  const cfg = generateConfig({ settings });
  ok(cfg.includes('allow-lan: true'), '裸写 allow-lan: yes → allow-lan: true（规范化）');
  ok(cfg.includes('unified-delay: true'), '裸写 unified-delay: on → true（规范化）');
  ok(cfg.includes('tcp-concurrent: false'), '裸写 tcp-concurrent: OFF → false（规范化）');
  ok(cfg.includes('ipv6: true'), '带引号的 ipv6: "true" → 裸 true（去掉引号）');
  ok(!cfg.includes('"true"'), '产物里不再残留带引号的 "true"（!!str into bool 会整份拒载）');
  ok(cfg.includes('  respect-rules: false'), '带引号的 dns.respect-rules: "0" → 裸 false');
  ok(cfg.includes('  ipv6: true'), '裸写的 dns.ipv6: 1 → 裸 true（!!int into bool 同样致命）');
  ok(cfg.includes('  enable: "yes"'), '带引号的 "yes" 内核能吃 → 保持原样（不擅自改写）');
  ok(!/: "1"/.test(cfg) && !/: "0"/.test(cfg), '产物里不再残留带引号的 "1"/"0"');
  const problems = scanDuplicateKeys(cfg);
  ok(problems.length === 0, '产物同层级重复键扫描 → 0 问题', JSON.stringify(problems));
  kernelOk(cfg, '含各种布尔写法的覆盖层配置');
}

// ── 场景 7：rules 行带 '- ' 前缀（R6）───────────────────────────────────
section('[7] rules 行带 "- " 前缀 → rules: 段没有嵌套 seq（R6）');
{
  const cfg = generateConfig({
    subscriptionRules: [
      '- DOMAIN-SUFFIX,example.invalid,DIRECT',
      'DOMAIN,foo.invalid,DIRECT',
    ],
  });
  const lines = cfg.split('\n');
  const rulesIdx = lines.findIndex((l) => l === 'rules:');
  ok(rulesIdx >= 0, '找到 rules: 段');
  const ruleLines = lines.slice(rulesIdx + 1).filter((l) => l.trim().startsWith('- '));
  ok(ruleLines.length > 0, `rules: 段有 ${ruleLines.length} 条规则`);
  ok(!ruleLines.some((l) => l.trim().startsWith('- - ')), 'rules: 段没有 "- - "（嵌套 seq）');
  ok(cfg.includes('  - DOMAIN-SUFFIX,example.invalid,DIRECT'),
    '带 "- " 前缀的规则被剥离后正常写入');
  const problems = scanDuplicateKeys(cfg);
  ok(problems.length === 0, '产物同层级重复键扫描 → 0 问题', JSON.stringify(problems));
  kernelOk(cfg, '规则带 "- " 前缀被剥离后的配置');
}

// ── 场景 8：store-selected（C22）────────────────────────────────────────
section('[8] profile: store-selected: true（C22，键名不是 store-selections）');
{
  const cfg = generateConfig({});
  ok(cfg.includes('  store-selected: true'), '产物含 store-selected: true');
  ok(!cfg.includes('store-selections'), '产物不含 store-selections（错键已清除）');
}

// ── 场景 9：组测速 URL 兜底（C4）───────────────────────────────────────
section('[9] safeGroupUrl("") 兜底是 https（C4）');
{
  eq(ClashConfigGenerator.safeGroupUrl(''), 'https://www.gstatic.com/generate_204',
    '空串兜底 = https://www.gstatic.com/generate_204');
  ok(ClashConfigGenerator.safeGroupUrl('http://example.invalid/x').includes('http://example.invalid/x'),
    '用户自填的 http 地址保持原样（不被改写）');
  ok(ClashConfigGenerator.safeGroupUrl('https://example.invalid/x').includes('https://example.invalid/x'),
    '用户自填的 https 地址保持原样');
}

// ── 场景 10：整链综合产物扫描 ───────────────────────────────────────────
section('[10] 综合场景：订阅 provider + 覆盖层 + 自定义规则集 → 同层级重复键 0 问题');
{
  const settings = baseSettings();
  settings.yamlOverride = [
    'dns:',
    '  enable: true',
    '  ipv6: false',
    'allow-lan: yes',
  ].join('\n');
  const cfg = generateConfig({
    settings,
    subscriptionRuleProviders: [
      '  my.provider:',
      '    type: http',
      '    behavior: classical',
      '  my.provider:',
      '    type: http',
      '    interval: 3600',
    ].join('\n'),
    subscriptionRules: [
      'RULE-SET,my.provider,DIRECT',
      '- DOMAIN-SUFFIX,example.invalid,DIRECT',
    ],
  });
  const problems = scanDuplicateKeys(cfg);
  ok(problems.length === 0, '综合产物同层级重复键扫描 → 0 问题', JSON.stringify(problems));
  eq(countTopLevelKey(cfg, 'dns'), 1, '顶层 dns: 仍只出现一次');
  eq(countTopLevelKey(cfg, 'rule-providers'), 1, '顶层 rule-providers: 只有 1 个');
  eq(countTopLevelKey(cfg, 'rules'), 1, '顶层 rules: 只有 1 个');
  eq(countTopLevelKey(cfg, 'profile'), 1, '顶层 profile: 只有 1 个');
  ok(cfg.includes('  - RULE-SET,my.provider,DIRECT'), 'RULE-SET 引用仍在（没被静默丢弃）');
  kernelOk(cfg, '综合场景（订阅 provider + 重复 provider + 覆盖层 dns/allow-lan）的配置');
}

// ── 场景 11：覆盖层空段不得抹掉生成器的同名段 ──────────────────────────
section('[11] 覆盖层空段（rules: 只有注释）→ 不抹掉生成器的规则、也不产生重复键');
{
  const settings = baseSettings();
  settings.yamlOverride = [
    'rules:',
    '  # 这里本来想写规则',
  ].join('\n');
  const cfg = generateConfig({ settings });
  eq(countTopLevelKey(cfg, 'rules'), 1, '顶层 rules: 仍只有 1 个');
  ok(cfg.includes('  - MATCH,PROXY'), '生成器的兜底规则没有被空段抹掉');
  const problems = scanDuplicateKeys(cfg);
  ok(problems.length === 0, '产物同层级重复键扫描 → 0 问题', JSON.stringify(problems));
}

// ── 场景 12：覆盖层自身重复顶层键 → 整段去重（保留首个）─────────────────
section('[12] 覆盖层自身重复顶层键 → 保留首个，不产生重复顶层键');
{
  const settings = baseSettings();
  settings.yamlOverride = [
    'custom-x: 1',
    'custom-x: 2',
  ].join('\n');
  const cfg = generateConfig({ settings });
  eq(countTopLevelKey(cfg, 'custom-x'), 1, '顶层 custom-x: 只出现一次');
  ok(cfg.includes('custom-x: 1'), '保留的是首个值');
  const problems = scanDuplicateKeys(cfg);
  ok(problems.length === 0, '产物同层级重复键扫描 → 0 问题', JSON.stringify(problems));
}

// ── 场景 13：真实内核的阴性对照（证明内核判定不是「永远通过」）────────────
section('[13] 真实内核阴性对照：手工造坏的配置必须被内核拒载');
{
  const broken = [
    'mixed-port: 7890',
    'mode: rule',
    'dns:',
    '  enable: true',
    'dns:',                       // ← 重复顶层键（uniqueKeys → 整份拒载）
    '  enable: false',
    'allow-lan: "true"',          // ← 带引号的 bool（!!str into bool → 整份拒载）
    'rules:',
    '  - MATCH,DIRECT',
  ].join('\n');
  const res = kernelAccepts(broken);
  if (res.skipped) {
    note('阴性对照：真实内核判定（跳过：未找到 mihomo.exe）');
  } else {
    ok(!res.ok, '坏配置（重复顶层键 + 带引号布尔）被真实内核拒载（判定有牙齿）',
      res.output.split('\n').filter((l) => l.includes('error') || l.includes('cannot')).slice(0, 4).join('\n       '));
  }
}

// ── 场景 14：订阅自带 DNS 上游（2026-10-20「测速全部超时」定案的回归闸门）──
section('[14] 订阅 dns 上游透传：proxy-server-nameserver / nameserver-policy 三分支');
{
  const dnsBlock = (cfg) => {
    const lines = cfg.split('\n');
    const start = lines.indexOf('dns:');
    if (start < 0) return '';
    const out = [];
    for (let i = start + 1; i < lines.length; i++) {
      if (lines[i].length > 0 && !lines[i].startsWith(' ')) break;
      out.push(lines[i]);
    }
    return out.join('\n');
  };
  const proxyNsBlock = (cfg) => {
    const block = dnsBlock(cfg).split('\n');
    const start = block.indexOf('  proxy-server-nameserver:');
    if (start < 0) return null;
    const out = [];
    for (let i = start + 1; i < block.length; i++) {
      if (block[i].length > 0 && !block[i].startsWith('    ')) break;
      out.push(block[i]);
    }
    return out.join('\n');
  };
  // a) 订阅没给 → 内置公共 DoT（原行为；加了分支也不能丢兜底）
  {
    const blk = proxyNsBlock(generateConfig({}));
    ok(blk !== null && blk.includes('- tls://223.5.5.5:853'),
      '无订阅 dns：proxy-server-nameserver 回落到内置 DoT');
  }
  // b) 订阅给了 proxy-server-nameserver → 按订阅域名后缀写进 -policy 段，
  //    全局仍只留中性 DoT（混排会让公共 DNS 在并发首答里抢跑私有 DoH）
  {
    const nodes = [makeNode('jp-1', { server: 'a.jushuitan.com' })];
    const cfg = generateConfig({
      nodes,
      subscriptionDnsUpstreams: [{
        subId: 'sub-1',
        servers: [
          'https://ns1.pubdns.co/dns-hyy/abc',
          'https://dnsdoh.trafficmanager.net/dns-hyy/abc',
        ],
      }],
    });
    const blk = proxyNsBlock(cfg) || '';
    ok(blk.includes('tls://223.5.5.5:853'), '全局 proxy-server-nameserver 恒为中性 DoT');
    ok(!blk.includes('ns1.pubdns.co'), '订阅上游不再并进全局列表（防跨订阅抢答）');
    ok(/proxy-server-nameserver-policy:/.test(cfg), '订阅上游写进 proxy-server-nameserver-policy');
    ok(cfg.includes('"+.jushuitan.com":'), 'policy 后缀取自该订阅节点域名');
    ok(cfg.includes('ns1.pubdns.co'), 'policy 段带上订阅私有 DoH');
  }
  // c) 订阅只给 nameserver-policy → 同名后缀同时镜像进 -policy（否则专用解析器看不到）
  {
    const nodes = [makeNode('jp-1', { server: 'best.jushuitan.com' })];
    const cfg = generateConfig({
      nodes,
      subscriptionDnsPolicies: [['+.jushuitan.com', 'https://bvd-api.dohcore.com:2096/dns-query/x']],
    });
    ok(cfg.includes('"+.jushuitan.com":'), 'policy 后缀写进 nameserver-policy');
    ok(cfg.includes('bvd-api.dohcore.com'), 'policy 上游写进配置');
    const idx = cfg.indexOf('proxy-server-nameserver-policy:');
    ok(idx >= 0 && cfg.slice(idx).includes('bvd-api.dohcore.com'),
      'policy 镜像进 proxy-server-nameserver-policy');
  }
  // f) 两份订阅各自的上游互不越界（本轮根因：跨订阅抢答）
  {
    const nodes = [
      makeNode('a-1', { server: 'a.alpha.com', subscriptionId: 'sub-A' }),
      makeNode('b-1', { server: 'b.beta.net', subscriptionId: 'sub-B' }),
    ];
    const cfg = generateConfig({
      nodes,
      subscriptionDnsUpstreams: [
        { subId: 'sub-A', servers: ['https://private-a.example/dns'] },
        { subId: 'sub-B', servers: ['1.2.3.4:53'] },
      ],
    });
    const idx = cfg.indexOf('proxy-server-nameserver-policy:');
    const blk = idx >= 0 ? cfg.slice(idx, cfg.indexOf('\n  fake-ip-filter', idx) + 1) : '';
    ok(blk.includes('"+.alpha.com":'), 'A 订阅后缀入 policy');
    ok(blk.includes('"+.beta.net":'), 'B 订阅后缀入 policy');
    const aPart = blk.slice(blk.indexOf('"+.alpha.com":'), blk.indexOf('"+.beta.net":'));
    const bPart = blk.slice(blk.indexOf('"+.beta.net":'));
    ok(aPart.includes('private-a.example') && !aPart.includes('1.2.3.4:53'), 'A 后缀只绑 A 的上游');
    ok(bPart.includes('1.2.3.4:53') && !bPart.includes('private-a.example'), 'B 后缀只绑 B 的上游');
  }
  // d) policy 与节点域名无关 → 不注入（不把机场其它域名的策略带进用户 DNS）
  {
    const cfg = generateConfig({
      nodes: [makeNode('x', { server: 'example.invalid' })],
      subscriptionDnsPolicies: [['+.jushuitan.com', 'https://bvd-api.dohcore.com:2096/dns-query/x']],
    });
    ok(!cfg.includes('jushuitan'), '与节点域名无关的 policy 不注入');
  }
  // e) 非法上游（空格/引号/未知 scheme）一律过滤，合法 IP:port 保留
  {
    const nodes = [makeNode('n1', { server: 'n1.example.com' })];
    const cfg = generateConfig({
      nodes,
      subscriptionDnsUpstreams: [{
        subId: 'sub-1',
        servers: ['https://evil example.com/x', '"quoted"', 'bogus://x', '1.2.3.4:53'],
      }],
    });
    ok(cfg.includes('1.2.3.4:53'), '合法的 IP:port 上游保留');
    ok(!cfg.includes('evil example.com') && !cfg.includes('bogus://'), '非法/未知上游被过滤');
  }
}

// ── 场景 15：DNS 恒接管 + fake-ip（2026-10-21：v6 也必须走代理）────────────
section('[15] DNS 恒接管 + fake-ip：range6 落在 TUN 的 /64，AAAA 走隧道');
{
  const dnsOf = (cfg) => {
    const lines = cfg.split('\n');
    const start = lines.indexOf('dns:');
    if (start < 0) {
      return '';
    }
    let end = lines.length;
    for (let i = start + 1; i < lines.length; i++) {
      if (lines[i].length > 0 && !lines[i].startsWith(' ')) {
        end = i;
        break;
      }
    }
    return lines.slice(start, end).join('\n');
  };

  const cfg = generateConfig({});
  const blk = dnsOf(cfg);
  ok(blk.length > 0, 'dns: 段恒存在（开关已删，无法整段关闭）');
  ok(blk.includes('  enable: true'), 'dns.enable 默认 true（设置页「DNS 接管」默认开）');
  ok(blk.includes('  enhanced-mode: fake-ip'), 'enhanced-mode 是 fake-ip（v6 也交给隧道）');
  ok(blk.includes('  fake-ip-range: 198.18.0.1/16'), 'v4 假池 198.18.0.1/16');
  ok(blk.includes('  fake-ip-range6: fdfe:dcba:9876::/64'), 'v6 假池 = TUN 自己的 /64（有 on-link 路由）');
  ok(blk.includes('  fake-ip-filter:'), 'fake-ip-filter 放行局域网/STUN/NTP/门户探活');
  ok(!cfg.includes('store-fake-ip'), '不写 store-fake-ip');
  ok(cfg.includes('  dns-hijack:') && cfg.includes('    - any:53'), 'tun.dns-hijack 恒开（any:53）');
  ok(blk.includes('  ipv6: true'), '默认双栈开 → dns.ipv6: true');

  const offBlk = dnsOf(generateConfig({ ipv6Enabled: false }));
  ok(offBlk.includes('  ipv6: false'), '关掉双栈 → dns.ipv6: false（AAAA 由内核回空）');
  ok(!offBlk.includes('fake-ip-range6'), '关掉双栈 → 不下发 range6（否则假 v6 无路由）');
  kernelOk(cfg, '默认配置（fake-ip + range6 + dns-hijack 恒开）');
  kernelOk(cfg, '默认配置（fake-ip + range6 + dns-hijack 恒开）');
}

// ── 场景 16：proxies 段「节点数不得凭空变 0」（2026-10-21 新增）───────────
//
// 历史真因（docs/latency-redesign.md / LatencyProbe.ets 自述）：订阅导入后凭据被
// **封存**（sealPlaintext 清空内存明文），而某条路径生成配置前**没回填凭据** ⇒
// 生成器按「缺凭据」把每条节点整条跳过 ⇒ **测速核 YAML 里一个节点都没有** ⇒
// 内核 /delay 秒回 503 ⇒ App 把它报成「网络不可达」，用户看到「全部节点失败」。
//
// 既有闸门只锁「回填调用点在生成之前」这一**顺序**（verify-latency-core-freshness），
// 于是「调用点还在、但回填实际没生效」仍然全绿。这里补**行为**断言：
// 有效节点进 generate() ⇒ 产物 proxies 段必须逐条落地。
section('[16] proxies 段：有效节点必须逐条落地（不得静默变 0）');
{
  /** 取顶层段（indent 0 的 `key:` 到下个顶层键） */
  const blockOf = (text, key) => {
    const lines = text.split('\n');
    const start = lines.findIndex((l) => l === `${key}:`);
    if (start < 0) {
      return '';
    }
    let end = lines.length;
    for (let i = start + 1; i < lines.length; i++) {
      if (lines[i].length > 0 && !lines[i].startsWith(' ')) {
        end = i;
        break;
      }
    }
    return lines.slice(start, end).join('\n');
  };
  /** 数 proxies 段里「- name:」条目数（块式节点各占一项） */
  const countNodeEntries = (blk) => (blk.match(/^\s*-\s*\{?\s*name:/gm) || []).length;

  // ① 基线：3 个有效节点 ⇒ 产物里必须有 3 条，且名字都在
  {
    const nodes = [makeNode('n-1'), makeNode('n-2'), makeNode('n-3')];
    const cfg = generateConfig({ nodes });
    const blk = blockOf(cfg, 'proxies');
    ok(blk.length > 0, '① proxies 段存在');
    const entries = countNodeEntries(blk);
    ok(entries === 3, `① 3 个有效节点 ⇒ proxies 段 3 条（实际 ${entries}）`);
    for (const n of nodes) {
      ok(blk.includes(n.name), `① 节点 ${n.name} 出现在产物里`);
    }
  }

  // ② 负对照：**全部节点都不可写**时生成器必须**响亮失败**（抛错），
  //    绝不能产出一份「proxies 段为空」的配置 —— 那正是历史事故的形态
  //    （测速核 YAML 里一个节点都没有 ⇒ 内核 /delay 全 503 ⇒ 被报成网络问题）。
  {
    const bad = makeNode('no-cred');
    bad.uuid = '';
    bad.protocolParam = '';
    let threw = false;
    let msg = '';
    try {
      generateConfig({ nodes: [bad] });
    } catch (e) {
      threw = true;
      msg = String(e && e.message ? e.message : e);
    }
    ok(threw, '② 全部节点不可写 ⇒ 生成器抛错（不产出空 proxies 配置）',
      threw ? '' : '没有抛错 = 危险：会产生 0 节点的配置');
    if (threw) {
      ok(msg.includes('没有可用的节点配置'),
        '② 抛错文案指明「没有可用的节点配置」', msg.slice(0, 120));
      ok(msg.includes('凭据'),
        '② 抛错文案指明凭据回填问题（指向可行动的修法）', msg.slice(0, 160));
    }
    const stats = ClashConfigGenerator.countDroppedNodes([bad]);
    ok(stats.missingCredential >= 1,
      `② 缺凭据被记账：missingCredential=${stats.missingCredential}（>=1）`);
  }

  // ③ 混合：有效 + 缺凭据 ⇒ 产物条数 == 有效条数（不是 0，也不是总数）
  {
    const good = makeNode('ok-1');
    const bad = makeNode('bad-1');
    bad.uuid = '';
    bad.protocolParam = '';
    const cfg = generateConfig({ nodes: [good, bad] });
    const blk = blockOf(cfg, 'proxies');
    const entries = countNodeEntries(blk);
    ok(entries === 1, `③ 1 有效 + 1 缺凭据 ⇒ proxies 段 1 条（实际 ${entries}）`);
    ok(blk.includes('ok-1'), '③ 有效节点仍在产物里');
  }
}

// ── 场景 17：代理组引用完整性（悬空引用会让内核**整份拒载**）─────────────
//
// ClashConfigGenerator 里有一整套「成员可解析性 + 迭代消除悬空引用 + 纯循环组丢弃」
// 逻辑（先落地直接引用节点的组，再逐轮向外传播）。注释自述：内核 config.Parse 对
// 「引用不存在的组/未声明 provider」会**拒载整份配置** ⇒ 一旦回归，全部节点消失。
// 该逻辑此前**没有行为闸门**（grep「循环/悬空/落地」在 verify-*.mjs 无命中）。
section('[17] 代理组引用完整性：无悬空引用、纯循环组被丢弃');
{
  /** 造一个真实的 ProxyGroup（成员显式声明） */
  const makeGroup = (name, groupType, members) => {
    const g = new ProxyGroup();
    g.subscriptionId = 'sub-1';
    g.name = name;
    g.groupType = groupType;
    g.members = members.slice();
    return g;
  };
  const blockOf = (text, key) => {
    const lines = text.split('\n');
    const start = lines.findIndex((l) => l === `${key}:`);
    if (start < 0) {
      return '';
    }
    let end = lines.length;
    for (let i = start + 1; i < lines.length; i++) {
      if (lines[i].length > 0 && !lines[i].startsWith(' ')) {
        end = i;
        break;
      }
    }
    return lines.slice(start, end).join('\n');
  };
  /** 收集产物里所有「已声明名字」：节点名 + 组名 + 内置策略 */
  const collectDeclared = (cfg, nodes) => {
    const set = new Set(['DIRECT', 'REJECT', 'PASS', 'COMPATIBLE', 'GLOBAL', 'PROXY']);
    for (const n of nodes) {
      set.add(n.name);
    }
    const gblk = blockOf(cfg, 'proxy-groups');
    const re = /^\s*-\s*name:\s*"?([^"\n]+?)"?\s*$/gm;
    let m = re.exec(gblk);
    while (m !== null) {
      set.add(m[1].trim());
      m = re.exec(gblk);
    }
    return set;
  };
  /** 扫描 proxy-groups 各成员的引用目标（含嵌套组、含 use: 之外的 proxies 列表） */
  const collectRefs = (cfg) => {
    const gblk = blockOf(cfg, 'proxy-groups');
    const refs = [];
    const lines = gblk.split('\n');
    let inProxies = false;
    for (const line of lines) {
      if (/^\s*proxies:\s*$/.test(line)) {
        inProxies = true;
        continue;
      }
      if (inProxies) {
        const m = /^\s*-\s*"?([^"\n]+?)"?\s*$/.exec(line);
        if (m) {
          refs.push(m[1].trim());
          continue;
        }
        if (line.trim().length > 0) {
          inProxies = false;
        }
      }
    }
    return refs;
  };

  // ① 正常组引用节点
  {
    const nodes = [makeNode('a-1'), makeNode('a-2')];
    const cfg = generateConfig({
      nodes,
      proxyGroups: [
        makeGroup('AUTO', 'url-test', nodes.map((n) => n.name)),
        makeGroup('FALLBACK', 'fallback', nodes.map((n) => n.name)),
      ],
    });
    const declared = collectDeclared(cfg, nodes);
    const refs = collectRefs(cfg);
    const dangling = refs.filter((r) => !declared.has(r));
    ok(dangling.length === 0,
      `① 组内成员全部指向已声明名字（悬空 ${dangling.length} 个）`,
      dangling.length > 0 ? `悬空：${JSON.stringify([...new Set(dangling)])}` : '');
  }

  // ② **悬空引用必须被消除**：组内成员写了一个不存在节点名 ⇒ 该成员不得出现在产物里
  //    （内核 config.Parse 对引用不存在的名字会拒载整份配置）
  {
    const nodes = [makeNode('b-1'), makeNode('b-2')];
    const cfg = generateConfig({
      nodes,
      proxyGroups: [makeGroup('DANGLING', 'url-test', ['b-1', 'ghost-node-xyz'])],
    });
    const declared = collectDeclared(cfg, nodes);
    const refs = collectRefs(cfg);
    const dangling = refs.filter((r) => !declared.has(r));
    ok(!refs.includes('ghost-node-xyz'),
      '② 指向不存在节点的成员被剔除（不写进产物）');
    ok(dangling.length === 0,
      `② 产物里 0 个悬空引用`,
      dangling.length > 0 ? `悬空：${JSON.stringify([...new Set(dangling)])}` : '');
    kernelOk(cfg, '② 含悬空成员的配置：真实内核仍接受（说明已消除）');
  }

  // ③ 组引用组：引用**不存在的组名**也必须被消除
  {
    const nodes = [makeNode('c-1')];
    const inner = makeGroup('INNER', 'url-test', ['c-1']);
    const outer = makeGroup('OUTER', 'select', ['INNER', 'no-such-group']);
    const cfg = generateConfig({ nodes, proxyGroups: [inner, outer] });
    const declared = collectDeclared(cfg, nodes);
    const refs = collectRefs(cfg);
    const dangling = refs.filter((r) => !declared.has(r));
    ok(!refs.includes('no-such-group'), '③ 指向不存在组的成员被剔除');
    ok(dangling.length === 0,
      '③ 组引用组时也无悬空引用',
      dangling.length > 0 ? `悬空：${JSON.stringify([...new Set(dangling)])}` : '');
    kernelOk(cfg, '③ 组引用组的配置：真实内核接受');
  }

  // ④ 自环与纯循环：组引用自己 / 两个组互相引用且都没有节点出口
  //    ⇒ 必须整组丢弃（否则内核报循环引用 / 该组永远无出口）
  {
    const nodes = [makeNode('d-1')];
    const selfLoop = makeGroup('SELF', 'select', ['SELF']);
    const cycA = makeGroup('CYC-A', 'select', ['CYC-B']);
    const cycB = makeGroup('CYC-B', 'select', ['CYC-A']);
    const cfg = generateConfig({ nodes, proxyGroups: [selfLoop, cycA, cycB] });
    const refs = collectRefs(cfg);
    ok(!refs.includes('SELF'), '④ 自环组成员被剔除（不引用自身）');
    const declared = collectDeclared(cfg, nodes);
    const dangling = refs.filter((r) => !declared.has(r));
    ok(dangling.length === 0,
      '④ 纯循环组不产生悬空引用',
      dangling.length > 0 ? `悬空：${JSON.stringify([...new Set(dangling)])}` : '');
    kernelOk(cfg, '④ 含自环/纯循环组的配置：真实内核接受（说明已被消除或丢弃）');
  }
}

// ── 场景 15：provider 权威模式（useRawProviderConfig=true）────────────────
// 三家主流客户端（FlClash / Verge / CMFA）都是「节点定义交给内核解析」，
// App 不再逐字段搬运节点。这里锁住三件事：provider 段发射、节点不重复静态发射、
// 组内不按名引用（只走 use:），保证不会出现「改名后引用悬空 → 整份拒载」。
section('[15] provider 权威：被覆盖订阅不再重发射节点，组内只走 use:，无悬空引用');
{
  const { RawSubscriptionStore, RawProviderEntry } = await import(G('stubs.ts'));
  const rawPath = path.join(os.tmpdir(), 'tunbox-provider-raw-verify.yaml');
  const rawBody = [
    'proxies:',
    '  - {name: "节点甲", type: trojan, server: 1.1.1.1, port: 443, password: pw1}',
    '  - {name: "节点甲", type: trojan, server: 2.2.2.2, port: 443, password: pw2}',
    // 必须覆盖「App 侧节点表里的每一个名字」，否则会触发名字一致性回退（见下）
    '  - {name: "节点乙", type: trojan, server: 3.3.3.3, port: 443, password: pw3}',
    ''
  ].join('\n');
  fs.writeFileSync(rawPath, rawBody, 'utf8');
  // 2026-10-22：provider 计划新增「App 侧节点名必须与原文一致」的硬约束（名字对不上
  // 会让 /proxies/{name}/delay 404 → 界面「未生效」）。所以这里必须把原文放进
  // RawBodyCache —— 否则计划会判定「拿不到原文」而整体回退内联，场景就测不到 provider 路径。
  const { RawBodyCache } = await import(G('RawProxyYaml.ts'));
  RawBodyCache.put('sub-1', rawBody);
  const entry = new RawProviderEntry();
  entry.subscriptionId = 'sub-1';
  entry.providerName = 'sub-1';
  entry.providerPath = rawPath;
  entry.filePath = rawPath;
  entry.bytes = 160;
  entry.nodeEstimate = 2;
  RawSubscriptionStore.upsert(entry);

  const s = baseSettings();
  s.useRawProviderConfig = true;
  const nodes = [makeNode('节点甲'), makeNode('节点乙')];
  // 订阅自带的组：成员是**节点名**。被 provider 覆盖后这些名字不在 `proxies:` 段里，
  // 若原样发射就是内核 `proxy group[0]: ... not found` 整份拒载（2026-10-22 真机原样）。
  const subGroup = new ProxyGroup();
  subGroup.subscriptionId = 'sub-1';
  subGroup.name = '🔰 选择节点';
  subGroup.groupType = 'select';
  subGroup.members = ['节点甲', '节点乙'];
  const cfg = generateConfig({ settings: s, nodes, proxyGroups: [subGroup] });

  ok(cfg.includes('proxy-providers:'), '⑮a provider 段已发射');
  ok(cfg.includes('use:'), '⑮b 组内通过 use: 引用 provider');
  ok(!cfg.includes('"节点甲"'), '⑮c 被覆盖订阅的节点不再静态重发射（避免两份同名副本）');
  // 订阅自带组必须被处理：成员按名引用的覆盖节点要被过滤，并补上 use:
  {
    const groupHeader = '  - name: "🔰 选择节点"';
    const at = cfg.indexOf(groupHeader);
    const next = cfg.indexOf('  - name: "', at + groupHeader.length);
    const block = at < 0 ? '' : cfg.slice(at, next < 0 ? undefined : next);
    ok(at >= 0, '⑮f 订阅自带组仍被发射（不整组丢弃）');
    ok(block.includes('use:'), '⑮g 该组补上 use:（否则成员被过滤后无出口）');
    ok(!block.includes('节点甲'), '⑮h 该组不再按名引用 provider 覆盖的节点');
  }
  // 悬空引用自检（本块局部实现，避免依赖别的场景里的闭包）：
  // 只扫 proxy-groups 的 proxies: 列表；`use:` 段是 provider 名，不算节点引用。
  // ⚠ 声明集合**必须只来自实际发射**（proxies: 段 + 组名 + 内置策略），
  //   不能把「入参节点表」整表塞进来 —— 那样会把「节点根本没发射」掩盖成「无悬空」
  //   （2026-10-22 这个掩盖让场景 15 在真机事故前一直是绿的）。
  const pIdx15 = cfg.indexOf('proxies:');
  const pEnd15 = cfg.indexOf('proxy-groups:');
  const pblk = pIdx15 >= 0 && pEnd15 > pIdx15 ? cfg.slice(pIdx15, pEnd15) : '';
  const gIdx = cfg.indexOf('proxy-groups:');
  const gblk = gIdx < 0 ? '' : cfg.slice(gIdx);
  const declared = new Set(['DIRECT', 'REJECT', 'PASS', 'COMPATIBLE', 'GLOBAL', 'PROXY']);
  for (const m of pblk.matchAll(/^\s*-\s*name:\s*"([^"]+)"/gm)) {
    declared.add(m[1]);
  }
  for (const m of pblk.matchAll(/^\s*-\s*\{name:\s*"([^"]+)"/gm)) {
    declared.add(m[1]);
  }
  for (const m of gblk.matchAll(/^\s*-\s*name:\s*"([^"]+)"/gm)) {
    declared.add(m[1]);
  }
  const refs = [];
  let inProxies = false;
  let groupHasUse = false;
  for (const line of gblk.split('\n')) {
    if (/^\s*-\s*name:\s*"/.test(line)) {
      groupHasUse = false;
    }
    if (/^\s*use:\s*$/.test(line)) {
      groupHasUse = true;
      inProxies = false;
      continue;
    }
    if (/^\s*proxies:\s*$/.test(line)) {
      inProxies = true;
      continue;
    }
    if (inProxies) {
      const m = /^\s*-\s*"([^"]+)"\s*$/.exec(line);
      if (m !== null) {
        // 带 use: 的组其成员可能来自 provider（名字查不到属正常）
        if (!groupHasUse) {
          refs.push(m[1]);
        }
        continue;
      }
      if (line.trim().length > 0) {
        inProxies = false;
      }
    }
  }
  const dangling = refs.filter((r) => !declared.has(r));
  ok(dangling.length === 0,
    '⑮d 无悬空引用（组内不按名引用未发射的节点）',
    dangling.length > 0 ? `悬空：${JSON.stringify([...new Set(dangling)])}` : '');
  kernelOk(cfg, '⑮e provider 权威配置');

  RawSubscriptionStore.drop('sub-1');
  try {
    fs.rmSync(rawPath, { force: true });
  } catch (e) {
    /* 清理失败不影响结论 */
  }
}

// ── 场景 16：原文透传不得吞掉任何节点（2026-10-22 真实内核抓到的空洞）───────
// 事故形态：原始实现把「建原文索引」和「发射节点」写成同一趟循环，`subId.length === 0`
// 的 `continue` 让手工导入节点（无订阅归属）整条消失，`proxies:` 后面为空
// → 内核 `proxy group[0]: PROXY: '香港 01' not found` 整份拒载。
// 这里用真生成链覆盖三种节点：有原文且同名（走原文）、有原文但名字对不上（退回解析）、
// 完全没有订阅归属（手工节点）。三条都必须出现在 `proxies:` 段里。
section('[16] 原文透传：有/无原文、有无订阅归属的节点都不得被静默丢弃');
{
  const { RawBodyCache } = await import(G('RawProxyYaml.ts'));
  const rawBody = [
    'proxies:',
    '  - name: "原文节点"',
    '    type: trojan',
    '    server: raw.invalid',
    '    port: 443',
    '    password: pw',
    // 原文里带一个「解析发射不会产出」的字段 → 用它证明这一行确实来自原文
    '    client-fingerprint: chrome',
    '',
    'proxy-groups: []',
    'rules: []',
  ].join('\n');
  RawBodyCache.put('sub-raw', rawBody);

  const nRaw = makeNode('原文节点', { subscriptionId: 'sub-raw', server: 'raw.invalid', proxyType: 'trojan', password: 'pw' });
  const nMiss = makeNode('原文外节点', { subscriptionId: 'sub-raw' });
  const nManual = makeNode('手工节点', { subscriptionId: '' });

  // 保险起见把急停开关打开，并还原（避免污染后续/其它套件）
  const prevFlag = ClashConfigGenerator.rawPassthroughEnabled;
  ClashConfigGenerator.rawPassthroughEnabled = true;
  const cfg = generateConfig({ nodes: [nRaw, nMiss, nManual] });
  ClashConfigGenerator.rawPassthroughEnabled = prevFlag;
  RawBodyCache.drop('sub-raw');

  const pStart = cfg.indexOf('proxies:');
  const pEnd = cfg.indexOf('proxy-groups:');
  const pBlock = pStart >= 0 && pEnd > pStart ? cfg.slice(pStart, pEnd) : '';
  for (const nm of ['原文节点', '原文外节点', '手工节点']) {
    ok(pBlock.includes(`"${nm}"`), `⑯ ${nm} 出现在 proxies: 段`);
  }
  ok(pBlock.includes('client-fingerprint: chrome'), '⑯ 同名节点的定义来自订阅原文（非解析重发射）');
  ok(pBlock.includes('reindent') === false, '⑯ 产物里没有残留的实现痕迹');
  ok((pBlock.match(/^\s*-\s/gm) || []).length === 3,
    `⑯ proxies: 段条目数 = 3（实际 ${(pBlock.match(/^\s*-\s/gm) || []).length}）`);
  kernelOk(cfg, '⑯ 原文透传 + 手工节点混合的配置');
}

// 自定义 GEOIP 规则也必须受数据库就绪闸门约束，首次安装不能同步联网下载卡住启动。
{
  const settings = baseSettings();
  settings.customRules = ['GEOIP,US,DIRECT', 'DOMAIN-SUFFIX,example.com,REJECT'];
  const before = settings.customRules.slice();
  const missing = generateConfig({ settings, useGeoip: false });
  ok(!missing.includes('GEOIP,US,DIRECT'), '⑰ 缺库时跳过自定义 GEOIP 规则');
  ok(missing.includes('DOMAIN-SUFFIX,example.com,REJECT'), '⑰ 缺库不影响普通域名规则');
  ok(JSON.stringify(settings.customRules) === JSON.stringify(before), '⑰ 不修改用户保存的规则');
  kernelOk(missing, '⑰ 没有 GeoIP 数据库的首次连接配置');
  const ready = generateConfig({ settings, useGeoip: true });
  ok(ready.includes('GEOIP,US,DIRECT'), '⑰ 数据库就绪后自定义 GEOIP 规则恢复');
  settings.rulesEnabled = false;
  const disabled = generateConfig({ settings, useGeoip: false });
  ok(!disabled.includes('GEOIP,US,DIRECT') && !disabled.includes('DOMAIN-SUFFIX,example.com,REJECT'),
    '⑰ 关闭规则引擎后不发射自定义规则');
}

console.log(`\n${passed} passed, ${failed} failed, ${deferred} deferred`);
if (failed === 0) {
  cleanup();
  process.exit(0);
}
console.log(`（失败时保留临时转译环境便于排查：${tmpRoot}）`);
process.exit(1);
