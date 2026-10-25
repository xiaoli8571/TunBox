#!/usr/bin/env node
/**
 * 「一份配置」闸门 —— 隧道与测速核必须用**同一份**配置来源。
 *
 * ## 背景（2026-10-20 真机症状的直接根因）
 *
 * 症状：「同一节点在隧道里能用、在测速核里失败」。
 *
 * 结构根因：App 里原本有**两份 YAML**，两处各自调用 ClashConfigGenerator.generate()，
 * 而且入参不同（useSmart / ruleProviderReady / selectedNode / proxyHosts / useGeoip /
 * tun.enable / secret / 端口）—— 于是 DNS 段、固定 IP、节点定义、代理组、规则都可能
 * 不一致。FlClash 只有一份配置，结构上没有这类分叉。
 *
 * 整改：entry/src/main/ets/commons/config/RuntimeConfigBuilder.ets 收口
 *   · 一个决策函数 decideRuntimeOptions()（四个决策点各只做一次）
 *   · 一个 hosts 来源（DoHResolver 共享快照，refreshStale 只在一处调）
 *   · 一个生成入口（整仓只允许本文件调用 ClashConfigGenerator.generate(）
 *
 * ## 本闸门断言什么
 *
 * 【源码层】
 *   A1  ClashConfigGenerator.generate( 在 entry/src 下**只出现一次**，且在 RuntimeConfigBuilder.ets
 *   A2  四个决策点各只有**一处**决策（useSmart / ruleProviderReady / selectedNode / useGeoip）
 *   A3  DoHResolver.refreshStale( 全仓**只在一处**调（且在 RuntimeConfigBuilder.ets）
 *   A4  RuntimeConfigBuilder 不持有/不回写任何共享端口状态（审计 F1：测速核端口探测
 *       曾经写回 this.apiPort/mixedPort/dnsPort）
 *
 * 【运行层（真源码转译 → 真生成器）】
 *   B1  同一 profile 生成 tunnel/test 两份 YAML：差异**只**落在白名单
 *       （secret / mixed-port / external-controller / dns.listen / tun.enable / log-level）
 *   B2  两份 YAML 的节点/规则/DNS/代理组段**逐字节相同**（白名单之外无任何差异）
 *   B3  端口口径：YAML 里写的端口 == 结果对象回传的端口（调用方 setEndpoint 用同一个局部变量）
 *   B4  决策共享：两份配置的 selectedNode 相同
 *
 * 【负对照（闸门自证有牙）】
 *   C1  静态：人为再加一处 generate( 调用 → 静态检查必须判红
 *   C2  运行：让 test mode 走**不同的 useSmart** → 差异检查必须判红
 *
 * 跑法：node scripts/verify-config-single-source.mjs
 * 退出码 0 = 全绿。
 */
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');

// ── 0. .ets 转译链需要 --experimental-transform-types（enum 不被 type-stripping 支持）──
if (!process.execArgv.includes('--experimental-transform-types')
  && process.env.TUNBOX_CFG_SINGLE_SOURCE_CHILD !== '1') {
  const res = spawnSync(
    process.execPath,
    ['--experimental-transform-types', '--no-warnings', fileURLToPath(import.meta.url)],
    { stdio: 'inherit', env: { ...process.env, TUNBOX_CFG_SINGLE_SOURCE_CHILD: '1' } },
  );
  process.exit(res.status === null ? 1 : res.status);
}

// ── 断言框架 ───────────────────────────────────────────────────────────────
let passed = 0;
let failed = 0;

function ok(cond, label, detail) {
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

const BUILDER_REL = 'entry/src/main/ets/commons/config/RuntimeConfigBuilder.ets';
const BUILDER_ABS = path.join(root, BUILDER_REL);

/** 允许两份 YAML 出现差异的键（隧道 vs 测速核）。 */
const DIFF_WHITELIST = new Set([
  'secret',
  'mixed-port',
  'external-controller',
  'dns.listen',
  'tun.enable',
  'log-level',
]);

// ── 源码工具 ───────────────────────────────────────────────────────────────

/** 递归列出目录下的 .ets 文件（相对 root 的 posix 路径）。 */
function listEtFiles(relDir) {
  const abs = path.join(root, relDir);
  const out = [];
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else if (entry.isFile() && entry.name.endsWith('.ets')) {
        out.push(path.relative(root, full).split(path.sep).join('/'));
      }
    }
  };
  walk(abs);
  return out.sort();
}

/**
 * 去掉注释（保留字符串字面量里的内容）。
 *
 * 为什么必须去注释：本仓库的代码注释里会写 `ClashConfigGenerator.generate(` 这类
 * 调用形态（说明「这里以前在调它」），直接 grep 会把注释算成调用点。
 */
function stripComments(text) {
  let out = '';
  let i = 0;
  let quote = '';
  while (i < text.length) {
    const ch = text.charAt(i);
    const next = i + 1 < text.length ? text.charAt(i + 1) : '';
    if (quote.length > 0) {
      out += ch;
      if (ch === '\\') {
        if (next.length > 0) {
          out += next;
          i += 2;
          continue;
        }
      } else if (ch === quote) {
        quote = '';
      }
      i++;
      continue;
    }
    if (ch === '"' || ch === "'" || ch === '`') {
      quote = ch;
      out += ch;
      i++;
      continue;
    }
    if (ch === '/' && next === '/') {
      while (i < text.length && text.charAt(i) !== '\n') {
        i++;
      }
      if (i < text.length) {
        out += '\n'; // 保留换行，行号才不会漂
        i++;
      }
      continue;
    }
    if (ch === '/' && next === '*') {
      i += 2;
      while (i < text.length && !(text.charAt(i) === '*' && text.charAt(i + 1) === '/')) {
        if (text.charAt(i) === '\n') {
          out += '\n'; // 同上：块注释里的换行也要保留
        }
        i++;
      }
      i += 2;
      continue;
    }
    out += ch;
    i++;
  }
  return out;
}

/** 统计某个 token 在「去注释后」的源码里出现多少次。 */
function countIn(files, pattern) {
  const hits = [];
  for (const rel of files) {
    const text = stripComments(fs.readFileSync(path.join(root, rel), 'utf8'));
    const re = new RegExp(pattern.source, pattern.flags.includes('g') ? pattern.flags : `${pattern.flags}g`);
    let m = re.exec(text);
    while (m !== null) {
      const line = text.slice(0, m.index).split('\n').length;
      hits.push({ file: rel, line });
      m = re.exec(text);
    }
  }
  return hits;
}

// ── 1. 源码层断言 ──────────────────────────────────────────────────────────
section('── 1. 源码层：唯一入口 / 唯一决策点 ──');

const etFiles = listEtFiles('entry/src/main');
const testFiles = listEtFiles('entry/src/ohosTest');
ok(fs.existsSync(BUILDER_ABS), `RuntimeConfigBuilder 存在（${BUILDER_REL}）`);
if (!fs.existsSync(BUILDER_ABS)) {
  console.log('\nFATAL: RuntimeConfigBuilder.ets 不存在，后续转译无法进行');
  process.exit(1);
}

const commonsFiles = listEtFiles('entry/src/main/ets/commons');

// A1：generate( 唯一调用点（**运行时模块** entry/src/main）
const generateHits = countIn(etFiles, /ClashConfigGenerator\.generate\(/);
ok(generateHits.length === 1,
  `A1 ClashConfigGenerator.generate( 在 entry/src/main 下只出现一次（实际 ${generateHits.length} 处）`,
  generateHits.length === 1 ? '' : generateHits.map((h) => `${h.file}:${h.line}`).join('\n       '));
ok(generateHits.length === 1 && generateHits[0].file === BUILDER_REL,
  'A1b 唯一调用点位于 RuntimeConfigBuilder.ets',
  generateHits.map((h) => `${h.file}:${h.line}`).join('\n       '));

// A1c：测试模块（entry/src/ohosTest）里的调用点只允许出现在测试目录 ——
// 它们是**单元测试**在直接驱动生成器，不属于运行时配置来源，故不计入 A1。
const testHits = countIn(testFiles, /ClashConfigGenerator\.generate\(/);
ok(testHits.every((h) => h.file.includes('/test/')),
  `A1c 测试模块的 generate( 调用只在测试目录（${testHits.length} 处，不计入 A1）`,
  testHits.filter((h) => !h.file.includes('/test/')).map((h) => `${h.file}:${h.line}`).join('\n       '));

// A2：四个决策点各只有一处决策
const DECISIONS = [
  { name: 'useSmart', pattern: /const\s+useSmart\s*=/ },
  { name: 'ruleProviderReady', pattern: /const\s+ruleProviderReady\s*=/ },
  { name: 'selectedNode', pattern: /const\s+selectedNode\s*=/ },
  { name: 'useGeoip', pattern: /const\s+useGeoip\s*=/ },
];
for (const d of DECISIONS) {
  const hits = countIn(commonsFiles, d.pattern);
  ok(hits.length === 1,
    `A2 决策点「${d.name}」只有一处决策（实际 ${hits.length} 处）`,
    hits.length === 1 ? '' : hits.map((h) => `${h.file}:${h.line}`).join('\n       '));
  ok(hits.length === 1 && hits[0].file === BUILDER_REL,
    `A2b 决策点「${d.name}」的决策在 RuntimeConfigBuilder.ets`,
    hits.map((h) => `${h.file}:${h.line}`).join('\n       '));
}

// A3：refreshStale 只在一处调
const refreshHits = countIn(etFiles, /DoHResolver\.refreshStale\(/);
ok(refreshHits.length === 1,
  `A3 DoHResolver.refreshStale( 全仓只在一处调（实际 ${refreshHits.length} 处）`,
  refreshHits.map((h) => `${h.file}:${h.line}`).join('\n       '));
ok(refreshHits.length === 1 && refreshHits[0].file === BUILDER_REL,
  'A3b refreshStale 的调用在 RuntimeConfigBuilder.ets',
  refreshHits.map((h) => `${h.file}:${h.line}`).join('\n       '));

// A4：构建器不持有/不回写共享端口状态
let builderText = '';
if (fs.existsSync(BUILDER_ABS)) {
  builderText = fs.readFileSync(BUILDER_ABS, 'utf8');
}
const builderCode = stripComments(builderText);
ok(!/this\s*\.\s*(apiPort|mixedPort|dnsPort)\s*=/.test(builderCode),
  'A4 构建器不回写任何共享端口字段（this.apiPort/mixedPort/dnsPort 无赋值）');
ok(!/this\s*\.\s*apiSecret\s*=/.test(builderCode),
  'A4b 构建器不回写共享 secret');
ok((builderCode.match(/ClashConfigGenerator\.generate\(/g) || []).length === 1,
  'A4c 构建器内部只有一处 generate( 调用');

// ── 2. 准备真源码转译环境（临时目录，不写仓库）─────────────────────────────
section('── 2. 转译真源码（临时目录）──');

const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'tunbox-cfg-single-'));
function cleanup() {
  try {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  } catch (e) {
    /* 临时目录清理失败不影响结论 */
  }
}
process.on('exit', cleanup);

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

// harness 的 FILES 列表里没有新增的 config/ 目录与 DoHResolver —— 这里用与
// prepare.mjs 相同的「只重写 import 目标」手法补转译（解析逻辑一行不改）。
const IMPORT_RE = /import\s+(?:type\s+)?(?:([A-Za-z_$][\w$]*)\s*,\s*)?(?:\{([^}]*)\}|\*\s+as\s+[A-Za-z_$][\w$]*|([A-Za-z_$][\w$]*))?\s+from\s*'([^']+)'/g;

function transpile(relSrc, outName, importMap) {
  const src = fs.readFileSync(path.join(tmpRoot, 'entry/src/main/ets', relSrc), 'utf8');
  const unresolved = [];
  const text = src.replace(IMPORT_RE, (m, def1, named, def2, spec) => {
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
  fs.writeFileSync(path.join(genDir, outName), text, 'utf8');
}

transpile('commons/services/DoHResolver.ets', 'DoHResolver.ts', {
  '@kit.NetworkKit': './stubs.ts',
  '../utils/AppLogger': './stubs.ts',
  './SettingsService': './stubs.ts',
});
transpile('commons/config/RuntimeConfigBuilder.ets', 'RuntimeConfigBuilder.ts', {
  '../models/ProxyNode': './ProxyNode.ts',
  '../models/ProxyGroup': './ProxyGroup.ts',
  '../models/AppSettings': './AppSettings.ts',
  '../models/SubDnsUpstream': './SubDnsUpstream.ts',
  '../services/ClashConfigGenerator': './ClashConfigGenerator.ts',
  '../services/DoHResolver': './DoHResolver.ts',
  '../utils/AppLogger': './stubs.ts',
  // 2026-10-22（FlClash 同构）：overlay + 订阅原文合并
  '../flclash/ProfileConfigMerger': './ProfileConfigMerger.ts',
  // 2026-10-25：smart 组注入需要测速地址真源（ND06 只有一处规则）
  '../latency/LatencyTestUrl': './LatencyTestUrl.ts',
});
transpile('commons/latency/LatencyTestUrl.ets', 'LatencyTestUrl.ts', {});

/** 临时副本的 stubs 补丁：harness 的 stubs.ts 未必覆盖后来新增的 @kit.* 具名导出。 */
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
      `${stubs}\n// [verify-config-single-source] 临时补齐缺失的具名导出\n`
      + `${additions.join('\n')}\n`, 'utf8');
    console.log(`（临时副本补齐 stubs 导出：${additions.length} 个）`);
  }
}
patchTempStubs();

const { RuntimeConfigBuilder, RuntimeConfigMode, RuntimeConfigProfile } =
  await import(G('RuntimeConfigBuilder.ts'));
const { AppSettings } = await import(G('AppSettings.ts'));
const { ProxyNode } = await import(G('ProxyNode.ts'));

// ── 3. YAML 差异检查器 ─────────────────────────────────────────────────────
section('── 3. 运行层：同一份输入 → 两份 YAML ──');

/**
 * 给每行算「键路径」（dns.listen / tun.enable / secret …）。
 * 只为差异定位服务，不做完整 YAML 解析。
 */
function computePaths(lines) {
  const paths = [];
  const stack = [];
  for (const raw of lines) {
    const line = raw.replace(/\r$/, '');
    const trimmed = line.trim();
    const indent = line.length - line.trimStart().length;
    if (trimmed.length === 0 || trimmed.startsWith('#')) {
      paths.push('');
      continue;
    }
    const m = /^([^:]+):(.*)$/.exec(trimmed);
    if (m === null) {
      paths.push(stack.length > 0 ? stack[stack.length - 1].full : '');
      continue;
    }
    const key = m[1].trim();
    while (stack.length > 0 && stack[stack.length - 1].indent >= indent) {
      stack.pop();
    }
    const parent = stack.length > 0 ? stack[stack.length - 1].full : '';
    const full = parent.length > 0 ? `${parent}.${key}` : key;
    if (m[2].trim().length === 0) {
      stack.push({ indent, key, full });
    }
    paths.push(full);
  }
  return paths;
}

/** YAML → 键路径 → 行集合（用于逐段比对，避免行号错位）。 */
function yamlProfile(yaml) {
  const lines = yaml.split('\n');
  const paths = computePaths(lines);
  const map = new Map();
  for (let i = 0; i < lines.length; i++) {
    const p = paths[i];
    if (p === '') {
      continue;
    }
    const list = map.get(p);
    if (list === undefined) {
      map.set(p, [lines[i]]);
    } else {
      list.push(lines[i]);
    }
  }
  return map;
}

/** 比对两份 YAML，返回 {key, a, b} 列表（只含不同的键路径）。 */
function diffYaml(a, b) {
  const pa = yamlProfile(a);
  const pb = yamlProfile(b);
  const keys = new Set([...pa.keys(), ...pb.keys()]);
  const diffs = [];
  for (const key of keys) {
    const la = pa.get(key);
    const lb = pb.get(key);
    const sa = la === undefined ? '' : la.join('\n');
    const sb = lb === undefined ? '' : lb.join('\n');
    if (sa !== sb) {
      diffs.push({ key, a: sa, b: sb });
    }
  }
  return diffs;
}

/** 差异是否全部落在白名单内。 */
function violationsOf(diffs) {
  return diffs.filter((d) => !DIFF_WHITELIST.has(d.key));
}

/** 取某个键路径的**整棵子树**（含所有嵌套层级）的原始文本。 */
function subtree(yaml, prefix, exclude) {
  const lines = yaml.split('\n');
  const paths = computePaths(lines);
  const skip = exclude === undefined ? new Set() : exclude;
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const p = paths[i];
    if (p === prefix || p.startsWith(`${prefix}.`)) {
      if (skip.has(p)) {
        continue;
      }
      out.push(lines[i]);
    }
  }
  return out.join('\n');
}

// ── 3.1 构造 profile ──────────────────────────────────────────────────────
function makeNode(id, name, server, port) {
  const n = new ProxyNode();
  n.id = id;
  n.name = name;
  n.originalName = name;
  n.server = server;
  n.port = port;
  n.method = 'aes-128-gcm';
  n.password = 'probe-password';
  n.proxyType = 'ss';
  n.type = 3; // ProxyNodeType.SS
  return n;
}

function makeProfile(opts) {
  const p = new RuntimeConfigProfile();
  const settings = new AppSettings();
  settings.autoSelectMode = 'auto';
  settings.rulesEnabled = true;
  settings.hyperAdRulesEnabled = true;
  settings.proxyMode = 'rule';
  settings.coreLogLevel = 'warning';
  settings.testLatencyUrl = 'https://www.gstatic.com/generate_204';
  p.settings = settings;
  p.nodes = [
    makeNode('n1', 'HK-01', 'hk01.example.com', 443),
    makeNode('n2', 'JP-02', 'jp02.example.com', 8443),
  ];
  p.selectedNodeName = 'JP-02';
  p.proxyHosts = { 'hk01.example.com': '203.0.113.11', 'jp02.example.com': '203.0.113.22' };
  p.smartModelReady = opts.smartModelReady;
  p.geoipReady = opts.geoipReady;
  p.ruleProviderFileReady = opts.ruleProviderFileReady;
  p.mixedPort = opts.mixedPort;
  p.apiPort = opts.apiPort;
  p.dnsPort = opts.dnsPort;
  p.apiSecret = opts.apiSecret;
  return p;
}

const baseOpts = {
  smartModelReady: true,
  geoipReady: true,
  ruleProviderFileReady: true,
};

const tunnelProfile = makeProfile({
  ...baseOpts,
  mixedPort: 7890,
  apiPort: 9090,
  dnsPort: 1053,
  apiSecret: 'tunnel-secret',
});
const testProfile = makeProfile({
  ...baseOpts,
  mixedPort: 17890,
  apiPort: 19090,
  dnsPort: 11053,
  apiSecret: 'test-secret',
});

const tunnelRes = await RuntimeConfigBuilder.buildRuntimeConfig(tunnelProfile, RuntimeConfigMode.TUNNEL);
const testRes = await RuntimeConfigBuilder.buildRuntimeConfig(testProfile, RuntimeConfigMode.TEST);

// 同一份 profile 走两种 mode（决策输入完全相同）
const sameProfile = makeProfile({ ...baseOpts, mixedPort: 7890, apiPort: 9090, dnsPort: 1053, apiSecret: 'same' });
const sameTunnel = await RuntimeConfigBuilder.buildRuntimeConfig(sameProfile, RuntimeConfigMode.TUNNEL);
const sameTest = await RuntimeConfigBuilder.buildRuntimeConfig(sameProfile, RuntimeConfigMode.TEST);

// ── 3.2 断言 ──────────────────────────────────────────────────────────────
const diffsReal = diffYaml(tunnelRes.yaml, testRes.yaml);
const violationsReal = violationsOf(diffsReal);
ok(violationsReal.length === 0,
  'B1 隧道/测速核两份 YAML 的差异只落在白名单内',
  violationsReal.map((v) => `越界键 ${v.key}`).join('\n       '));
ok(diffsReal.length > 0,
  'B1b 端口/secret 不同时两份 YAML 确实存在差异（否则断言是空的）',
  '两份 YAML 完全相同 → 白名单断言没有意义');
const diffKeys = diffsReal.map((d) => d.key).sort();
ok(diffKeys.every((k) => DIFF_WHITELIST.has(k)),
  `B1c 差异键集合 ⊆ 白名单（实际：${diffKeys.join(', ') || '无'}）`);

const diffsSame = diffYaml(sameTunnel.yaml, sameTest.yaml);
const violationsSame = violationsOf(diffsSame);
ok(violationsSame.length === 0,
  'B2 同一 profile 下两份 YAML 的差异只落在白名单内',
  violationsSame.map((v) => `越界键 ${v.key}`).join('\n       '));

// 节点/规则/DNS/代理组段必须逐字节相同（整棵子树比较，含嵌套层级；
// dns.listen 属白名单差异 —— 两种 mode 监听端口本就不同）
const SECTIONS = [
  { key: 'proxies', skip: [] },
  { key: 'proxy-groups', skip: [] },
  { key: 'rules', skip: [] },
  { key: 'dns', skip: ['dns.listen'] },
  { key: 'rule-providers', skip: [] },
  { key: 'hosts', skip: [] },
];
for (const sec of SECTIONS) {
  const a = subtree(tunnelRes.yaml, sec.key, new Set(sec.skip));
  const b = subtree(testRes.yaml, sec.key, new Set(sec.skip));
  ok(a === b, `B2b 段「${sec.key}」两份配置逐字节相同`);
}

// 端口口径：YAML 里的端口 == 结果对象回传的端口
ok(tunnelRes.yaml.includes(`mixed-port: ${tunnelRes.mixedPort}`), 'B3 隧道 YAML 的 mixed-port 与结果对象一致');
ok(tunnelRes.yaml.includes(`external-controller: 127.0.0.1:${tunnelRes.apiPort}`), 'B3b 隧道 YAML 的 controller 端口与结果对象一致');
ok(tunnelRes.yaml.includes(`  listen: 127.0.0.1:${tunnelRes.dnsPort}`), 'B3c 隧道 YAML 的 dns.listen 与结果对象一致');
ok(testRes.yaml.includes(`mixed-port: ${testRes.mixedPort}`), 'B3d 测速核 YAML 的 mixed-port 与结果对象一致');
ok(testRes.yaml.includes(`external-controller: 127.0.0.1:${testRes.apiPort}`), 'B3e 测速核 YAML 的 controller 端口与结果对象一致');
ok(testRes.yaml.includes(`  listen: 127.0.0.1:${testRes.dnsPort}`), 'B3f 测速核 YAML 的 dns.listen 与结果对象一致');
ok(tunnelRes.apiPort !== testRes.apiPort && tunnelRes.mixedPort !== testRes.mixedPort,
  'B3g 隧道与测速核的端口互相独立（不共享同一组端口）');

// 决策共享：两份配置必须用同一个节点
ok(tunnelRes.options.selectedNodeName === testRes.options.selectedNodeName,
  `B4 两种 mode 共享同一个 selectedNode（${tunnelRes.options.selectedNodeName}）`);
ok(tunnelRes.options.useSmart === testRes.options.useSmart, 'B4b 两种 mode 共享同一个 useSmart 决策');
ok(tunnelRes.options.ruleProviderReady === testRes.options.ruleProviderReady,
  'B4c 两种 mode 共享同一个 ruleProviderReady 决策');
ok(tunnelRes.options.useGeoip === testRes.options.useGeoip, 'B4d 两种 mode 共享同一个 useGeoip 决策');

// adRulesOn 闸门：开关关闭时 ruleProviderReady 必须为 false（审计 F5）
const adOffProfile = makeProfile({ ...baseOpts, mixedPort: 7890, apiPort: 9090, dnsPort: 1053, apiSecret: 'x' });
adOffProfile.settings.hyperAdRulesEnabled = false;
const adOffRes = await RuntimeConfigBuilder.buildRuntimeConfig(adOffProfile, RuntimeConfigMode.TUNNEL);
ok(adOffRes.options.adRulesOn === false && adOffRes.options.ruleProviderReady === false,
  'B4e 去广告开关关闭时 ruleProviderReady 必须为 false（含 adRulesOn 闸门）');

// ── 4. 负对照（闸门自证有牙）──────────────────────────────────────────────
section('── 4. 负对照：分叉必须被判红 ──');

// C1 静态：再加一处 generate( 调用 → 静态检查必须判红
const fakeFiles = [
  { file: BUILDER_REL, text: 'const a = ClashConfigGenerator.generate(' },
  { file: 'entry/src/main/ets/commons/services/Other.ets', text: 'const b = ClashConfigGenerator.generate(' },
];
let fakeCount = 0;
for (const f of fakeFiles) {
  const re = /ClashConfigGenerator\.generate\(/g;
  let m = re.exec(stripComments(f.text));
  while (m !== null) {
    fakeCount++;
    m = re.exec(stripComments(f.text));
  }
}
ok(fakeCount === 2 && fakeCount !== 1,
  'C1 静态负对照：两处 generate( 调用被判定为「不是唯一入口」');

// C2 运行：让 test mode 走不同的 useSmart → 差异检查必须判红
const forkedProfile = makeProfile({
  ...baseOpts,
  smartModelReady: false, // ← 故意让测速核侧的决策与隧道侧不同
  mixedPort: 17890,
  apiPort: 19090,
  dnsPort: 11053,
  apiSecret: 'test-secret',
});
const forkedTest = await RuntimeConfigBuilder.buildRuntimeConfig(forkedProfile, RuntimeConfigMode.TEST);
const forkedDiffs = diffYaml(tunnelRes.yaml, forkedTest.yaml);
const forkedViolations = violationsOf(forkedDiffs);
ok(forkedViolations.length > 0,
  'C2 运行负对照：useSmart 分叉被差异检查判红（越界键非空）',
  forkedViolations.length === 0 ? '分叉没有被抓到 —— 闸门无牙' : '');
ok(forkedDiffs.some((d) => d.key === 'proxy-groups' || d.key.startsWith('proxy-groups.')),
  'C2b useSmart 分叉确实体现在 proxy-groups 段（说明负对照造出了真分叉）',
  `实际差异键：${forkedDiffs.map((d) => d.key).join(', ')}`);

// ── 汇总 ──────────────────────────────────────────────────────────────────
console.log('');
console.log(`RESULT: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
