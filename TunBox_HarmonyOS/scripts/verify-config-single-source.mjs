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
 *   A2  三个运行选项各只有**一处**决策（ruleProviderReady / selectedNode / useGeoip）
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
 *   C2  运行：让 test mode 走**不同的代理模式** → 差异检查必须判红
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

// A2：Smart 完全由 profile 声明；其余运行选项仍只有一个决策点。
const DECISIONS = [
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
  '../services/VpnRecoveryPolicy': './VpnRecoveryPolicy.ts',
  '../utils/AppLogger': './stubs.ts',
  // 2026-10-22（FlClash 同构）：overlay + 订阅原文合并
  '../tunbox/ProfileConfigMerger': './ProfileConfigMerger.ts',
  // 2026-11-05（FlClash 全量照抄）：map 级构建器（compose 为纯函数）+ profile 仓库
  '../tunbox/TunBoxProfileBuilder': './TunBoxProfileBuilder.ts',
  '../tunbox/ProfileRepository': './ProfileStore.ts',
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
const { coreBridge } = await import(G('stubs.ts'));

// ── 2.5 沙箱内核桥（2026-11-05 FlClash 全量照抄）───────────────────────────
// 生产链路：getProfileBase（内核解析 profile 文件）+ decodeYaml（内核 YAML 解码）。
// Node 门禁没有内核与 YAML 库 —— 这里用「受控子集」mini-YAML 解析器承接：
// 只解析**本门禁自造的 fixture 与生成器输出**（块/流式 map+list、引号标量、数字/布尔）。
// 超出子集的输入立即抛错（不静默）。
function miniScalar(raw) {
  const t = raw.trim();
  if (t.length === 0 || t === '~' || t === 'null') return null;
  if (t === 'true' || t === 'True' || t === 'TRUE') return true;
  if (t === 'false' || t === 'False' || t === 'FALSE') return false;
  if (/^-?\d+$/.test(t)) return parseInt(t, 10);
  if (/^-?\d+\.\d+$/.test(t)) return parseFloat(t);
  if ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))) {
    return t.slice(1, -1).replace(/''/g, "'");
  }
  return t;
}

function splitFlow(body) {
  const items = [];
  let depth = 0, quote = null, cur = '';
  for (let i = 0; i < body.length; i++) {
    const ch = body[i];
    if (quote !== null) {
      cur += ch;
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") { quote = ch; cur += ch; continue; }
    if (ch === '[' || ch === '{') depth++;
    if (ch === ']' || ch === '}') depth--;
    if (ch === ',' && depth === 0) { items.push(cur.trim()); cur = ''; continue; }
    cur += ch;
  }
  if (cur.trim().length > 0) items.push(cur.trim());
  return items;
}

function parseFlow(text) {
  const t = text.trim();
  if (t.startsWith('[')) {
    if (t === '[]') return [];
    return splitFlow(t.slice(1, -1)).map((x) => (x.startsWith('{') ? parseFlow(x) : miniScalar(x)));
  }
  if (t.startsWith('{')) {
    const out = {};
    if (t === '{}') return out;
    for (const item of splitFlow(t.slice(1, -1))) {
      const idx = item.indexOf(':');
      if (idx < 0) throw new Error(`mini-yaml: flow map item missing colon: ${item}`);
      out[miniScalar(item.slice(0, idx))] = parseFlow(item.slice(idx + 1));
    }
    return out;
  }
  return miniScalar(t);
}

function miniYamlParse(text) {
  const lines = text.replace(/\r/g, '').split('\n')
    .filter((l) => l.trim().length > 0 && !l.trim().startsWith('#'));
  let i = 0;
  const indentOf = (l) => l.length - l.trimStart().length;

  function findColon(t) {
    let quote = null;
    for (let k = 0; k < t.length; k++) {
      const ch = t[k];
      if (quote !== null) { if (ch === quote) quote = null; continue; }
      if (ch === '"' || ch === "'") { quote = ch; continue; }
      if (ch === ':' && (k + 1 === t.length || t[k + 1] === ' ')) return k;
    }
    return t.endsWith(':') ? t.length - 1 : -1;
  }

  function parseBlock(indent) {
    if (i >= lines.length) return null;
    if (lines[i].trimStart().startsWith('- ')) return parseList(indent);
    return parseMap(indent);
  }

  function parseMap(indent) {
    const out = {};
    while (i < lines.length) {
      const line = lines[i];
      const ind = indentOf(line);
      if (ind < indent) break;
      if (ind > indent) throw new Error(`mini-yaml: bad indent: ${line}`);
      if (line.trimStart().startsWith('- ')) break;
      const t = line.trim();
      const idx = findColon(t);
      if (idx < 0) throw new Error(`mini-yaml: map line missing colon: ${t}`);
      const key = miniScalar(t.slice(0, idx));
      const rest = t.slice(idx + 1).trim();
      i++;
      if (rest.length === 0) {
        const childIndent = i < lines.length ? indentOf(lines[i]) : indent + 2;
        out[key] = parseBlock(childIndent > indent ? childIndent : indent + 2);
      } else {
        out[key] = parseFlow(rest);
      }
    }
    return out;
  }

  function parseList(indent) {
    const out = [];
    while (i < lines.length) {
      const line = lines[i];
      const ind = indentOf(line);
      if (ind < indent || !line.trimStart().startsWith('- ')) break;
      const t = line.trim().slice(2).trim();
      if (t.length === 0) {
        i++;
        out.push(parseBlock(indent + 2));
        continue;
      }
      const colon = findColon(t);
      if (colon > 0) {
        // 「- name: x」→ 内嵌 map：把列表项行改成虚拟缩进行，交给 parseMap
        const itemIndent = ind + 2;
        lines[i] = ' '.repeat(itemIndent) + t;
        out.push(parseMap(itemIndent));
        continue;
      }
      out.push(parseFlow(t));
      i++;
    }
    return out;
  }

  return parseBlock(0);
}

/** map → 规范 YAML 文本（差异比对与文本断言用；两边同管线，表示差异互相抵消）。 */
function yamlNeedsQuote(v) {
  if (v.length === 0) return true;
  if (/^(?:true|false|null|yes|no|on|off|~)$/i.test(v)) return true;
  if (/^[-?:,\[\]{}#&*!|>'"%@`]/.test(v)) return true;
  if (/^(?:0x[0-9a-fA-F]+|-?\d+(?:\.\d+)?)$/.test(v)) return true;
  if (/\s$|^\s/.test(v)) return true;
  return false;
}
function yamlScalar(v) {
  if (typeof v === 'number') return String(v);
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (v === null || v === undefined) return 'null';
  const s = String(v);
  if (yamlNeedsQuote(s)) return `'${s.replace(/'/g, "''")}'`;
  return s;
}
function miniYamlDump(value) {
  const out = [];
  function walkMapInline(obj, indent) {
    const keys = Object.keys(obj);
    for (const key of keys) {
      const val = obj[key];
      const pad = ' '.repeat(indent);
      if (Array.isArray(val)) {
        if (val.length === 0) { out.push(`${pad}${key}: []`); continue; }
        const allScalar = val.every((x) => x === null || typeof x !== 'object');
        if (allScalar) {
          out.push(`${pad}${key}: [${val.map(yamlScalar).join(', ')}]`);
        } else {
          out.push(`${pad}${key}:`);
          walkList(val, indent + 2);
        }
        continue;
      }
      if (val !== null && typeof val === 'object') {
        if (Object.keys(val).length === 0) { out.push(`${pad}${key}: {}`); continue; }
        out.push(`${pad}${key}:`);
        walkMapInline(val, indent + 2);
        continue;
      }
      out.push(`${pad}${key}: ${yamlScalar(val)}`);
    }
  }
  function walkList(list, indent) {
    for (const item of list) {
      if (item !== null && typeof item === 'object') {
        const keys = Object.keys(item);
        const first = keys[0];
        const headVal = item[first];
        const pad = ' '.repeat(indent);
        if (headVal !== null && typeof headVal === 'object') {
          out.push(`${pad}- ${first}:`);
          walkMapInline(headVal, indent + 2);
        } else {
          out.push(`${pad}- ${first}: ${yamlScalar(headVal)}`);
        }
        const restKeys = keys.slice(1);
        for (const key of restKeys) {
          const val = item[key];
          if (Array.isArray(val)) {
            if (val.length === 0) { out.push(`${pad}  ${key}: []`); continue; }
            const allScalar = val.every((x) => x === null || typeof x !== 'object');
            if (allScalar) {
              out.push(`${pad}  ${key}: [${val.map(yamlScalar).join(', ')}]`);
            } else {
              out.push(`${pad}  ${key}:`);
              walkList(val, indent + 4);
            }
            continue;
          }
          if (val !== null && typeof val === 'object') {
            if (Object.keys(val).length === 0) { out.push(`${pad}  ${key}: {}`); continue; }
            out.push(`${pad}  ${key}:`);
            walkMapInline(val, indent + 4);
            continue;
          }
          out.push(`${pad}  ${key}: ${yamlScalar(val)}`);
        }
        continue;
      }
      out.push(`${' '.repeat(indent)}- ${yamlScalar(item)}`);
    }
  }
  if (Array.isArray(value)) {
    walkList(value, 0);
  } else if (value !== null && typeof value === 'object') {
    walkMapInline(value, 0);
  } else {
    out.push(yamlScalar(value));
  }
  return `${out.join('\n')}\n`;
}

// profile 文件注册表：native fixture 按路径注册（getProfileBase 按路径取）
const profileFileRegistry = new Map();
coreBridge.getProfileBase = async (p) => {
  const text = profileFileRegistry.get(p);
  if (text === undefined) throw new Error(`sandbox: no profile registered at ${p}`);
  const doc = miniYamlParse(text);
  const proxies = Array.isArray(doc['proxies']) ? doc['proxies'] : [];
  const groups = Array.isArray(doc['proxy-groups']) ? doc['proxy-groups'] : [];
  const rules = Array.isArray(doc['rules']) ? doc['rules'].map((x) => String(x)) : [];
  const matchRules = rules.filter((r) => r.toUpperCase().startsWith('MATCH,'));
  return {
    config: doc,
    digest: 'sandbox',
    proxies: proxies.length,
    proxyGroups: groups.length,
    rules: rules.length,
    matchRules,
  };
};
coreBridge.decodeYaml = async (text) => miniYamlParse(text);

/** JSON dump（新构建器产物）→ 规范 YAML 文本（喂给既有文本差异机器）。 */
function canonicalYaml(res) {
  return miniYamlDump(JSON.parse(res.yaml));
}

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
ok(tunnelRes.options.useSmart === false && testRes.options.useSmart === false,
  'B4b 两种 mode 均不以 App 选项合成 Smart 策略');
ok(tunnelRes.options.ruleProviderReady === testRes.options.ruleProviderReady,
  'B4c 两种 mode 共享同一个 ruleProviderReady 决策');
ok(tunnelRes.options.useGeoip === testRes.options.useGeoip, 'B4d 两种 mode 共享同一个 useGeoip 决策');

// adRulesOn 闸门：开关关闭时 ruleProviderReady 必须为 false（审计 F5）
const adOffProfile = makeProfile({ ...baseOpts, mixedPort: 7890, apiPort: 9090, dnsPort: 1053, apiSecret: 'x' });
adOffProfile.settings.hyperAdRulesEnabled = false;
const adOffRes = await RuntimeConfigBuilder.buildRuntimeConfig(adOffProfile, RuntimeConfigMode.TUNNEL);
ok(adOffRes.options.adRulesOn === false && adOffRes.options.ruleProviderReady === false,
  'B4e 去广告开关关闭时 ruleProviderReady 必须为 false（含 adRulesOn 闸门）');

// Native documents must retain semantics, not merely match two generated copies.
// 2026-11-05（FlClash 全量照抄）：native fixture 走新链路 —— profile 文件经内核
// getProfileBase 解析（沙箱由 mini-yaml 注册表承接），产物为 JSON dump，
// 断言前统一转回规范 YAML 文本喂给同一套差异机器。
const nativeProfile = makeProfile({ ...baseOpts, mixedPort: 27890, apiPort: 29090, dnsPort: 21053, apiSecret: 'native' });
nativeProfile.settings.autoSelectMode = 'manual';
nativeProfile.settings.hyperAdRulesEnabled = false;
nativeProfile.selectedNodeName = 'Taiwan';
nativeProfile.profileId = 'native-fixture';
const nativeYamlFixture = `mixed-port: 1234
external-controller: 0.0.0.0:1235
secret: imported-secret
global-client-fingerprint: chrome
keep-alive-interval: 17
geodata-loader: standard
profile: {store-selected: true, store-fake-ip: true}
hosts:
  node.example: 192.0.2.42
sniffer:
  enable: false
dns:
  enable: true
  listen: 0.0.0.0:53
  enhanced-mode: fake-ip
  nameserver:
    - https://private.example/dns-query
  nameserver-policy:
    '+.node.example': https://split.example/dns-query
proxies:
  - name: Direct
    type: direct
  - name: TW
    type: socks5
    server: node.example
    port: 1080
proxy-groups:
  - name: Root
    type: select
    proxies: [Taiwan, Direct]
  - name: Taiwan
    type: select
    proxies: [TW]
rules:
  - DOMAIN,example.cn,Root
  - MATCH,Root
`;
nativeProfile.profileYaml = nativeYamlFixture;
const { ProfileStore } = await import(G('ProfileStore.ts'));
profileFileRegistry.set(ProfileStore.pathOf(nativeProfile.profileId), nativeYamlFixture);
for (const override of [false, true]) {
  nativeProfile.settings.dnsOverrideEnabled = override;
  const nativeTunnelRes = await RuntimeConfigBuilder.buildRuntimeConfig(nativeProfile, RuntimeConfigMode.TUNNEL);
  const nativeTestRes = await RuntimeConfigBuilder.buildRuntimeConfig(nativeProfile, RuntimeConfigMode.TEST);
  const nativeTunnel = canonicalYaml(nativeTunnelRes);
  const nativeTestYaml = canonicalYaml(nativeTestRes);
  if (process.env.TUNBOX_CSS_DEBUG === '1') {
    console.log(`---- native tunnel yaml (override=${override}) ----`);
    console.log(nativeTunnel);
  }
  ok(nativeTunnelRes.options.selectedNodeName === 'Taiwan' && nativeTunnelRes.effectiveNodeName === 'Taiwan',
    `native DNS override=${override}: group intent is never replaced by a static node`);
  // FlClash patch 语义下的保留断言（2026-11-05 终版 = FlClash main 原样）：
  //   · profile general 键（global-client-fingerprint/geodata-loader/hosts）原样；
  //   · keep-alive-interval 由 FlClash patch 强制为 30（profile 的 17 被覆盖 —— FlClash
  //     main 同款：rawConfig['keep-alive-interval'] = patch 值）；
  //   · store-selected 强制 false（FlClash）；
  //   · profile dns 启用 → 订阅 dns 原样（listen 0.0.0.0:53 / 私有上游 / split policy 全保留；
  //     FlClash main 无「应用 DNS 整段接管」模式，dnsOverrideEnabled 不再参与）；
  //   · sniffer：overlay 键级合并，应用键胜（FlClash mergeSnifferOverride 语义）。
  for (const snippet of ['global-client-fingerprint: chrome', 'keep-alive-interval: 30', 'geodata-loader: standard',
    'store-selected: false', 'store-fake-ip: true', 'node.example: 192.0.2.42',
    'listen: 0.0.0.0:53',
    'https://private.example/dns-query', 'https://split.example/dns-query',
    'force-dns-mapping: true']) {
    ok(nativeTunnel.includes(snippet), `native DNS override=${override}: retain ${snippet.replaceAll('\n', ' ')}`);
  }
  ok(!nativeTunnel.includes('GEOIP,CN,DIRECT') && !nativeTunnel.includes('DOMAIN-SUFFIX,cn,DIRECT'),
    `native DNS override=${override}: generated domestic rules cannot preempt profile rules`);
  ok(!nativeTunnel.includes('imported-secret') && !nativeTunnel.includes('mixed-port: 1234'),
    `native DNS override=${override}: application retains listener ownership`);
  ok(violationsOf(diffYaml(nativeTunnel, nativeTestYaml)).length === 0,
    `native DNS override=${override}: tunnel and test retain the same native behavior`);
}

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

// C2 运行：故意让测速核使用不同代理模式，检查器必须识别非监听器差异。
const forkedProfile = makeProfile({
  ...baseOpts,
  mixedPort: 17890,
  apiPort: 19090,
  dnsPort: 11053,
  apiSecret: 'test-secret',
});
forkedProfile.settings.proxyMode = 'global';
const forkedTest = await RuntimeConfigBuilder.buildRuntimeConfig(forkedProfile, RuntimeConfigMode.TEST);
const forkedDiffs = diffYaml(tunnelRes.yaml, forkedTest.yaml);
const forkedViolations = violationsOf(forkedDiffs);
ok(forkedViolations.length > 0,
  'C2 运行负对照：代理模式分叉被差异检查判红（越界键非空）',
  forkedViolations.length === 0 ? '分叉没有被抓到 —— 闸门无牙' : '');
ok(forkedViolations.some((d) => d.key === 'mode'),
  'C2b 模式差异确实被列为禁止分叉的键',
  `实际差异键：${forkedDiffs.map((d) => d.key).join(', ')}`);

// ── 汇总 ──────────────────────────────────────────────────────────────────
console.log('');
console.log(`RESULT: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
