#!/usr/bin/env node
/**
 * 连接链路 / DNS 防投毒 / direct 不落盘 —— 稳定性回退回归护栏（B + C + D 组）
 *
 * ## 守的是什么故障
 *
 * 0.4.0 为了「启动快」做了四处提速，每一处都在真机上换来了更难排查的故障。
 * 本脚本逐条把它们钉回安全语义，防止下次「再优化一下」时无声回退。
 *
 *   B7  `READINESS_MAX_DELAY_MS` 曾从 300 收到 150：内核刚起时 API 探测太激进，
 *       冷启动/弱网下反复打到「未就绪」分支，连接反而更慢。
 *   B8  节点钉选曾被改成「先上屏已连接、再 fire-and-forget 补钉选」：
 *       YAML 开着 `store-selections: true`，内核冷启动会恢复**上次持久化的组选点**，
 *       于是「已连接」上屏到钉选真正生效之间有 100–500ms 窗口，窗口内新建的连接走
 *       的是上一次选过的节点 —— 真机表现「连上了但代理不生效 / 公网 IP 查不到」，
 *       且只在选点与上次不同时复现。
 *   B9  同一处改造里钉选失败只 `AppLogger.warn`，等于「假装连接成功」：用户拿到一条
 *       没有出口的隧道，比明确失败更糟。
 *   B10 DoH 预算曾在「目标域名已 pin」时收紧到 1500ms，代价是**备用节点域名几乎必然
 *       解析不到** → 不进 YAML `hosts:` → 运行期退回明文 proxy-server-nameserver
 *       现解析 → 切节点/故障切换时可能拿到被污染的 IP。
 *   B11 冷启 DoH 预热（16 worker 并发、6s 预算）与启动期公网 IP 查询必然重叠，
 *       弱网下把 ip-api 握手挤到超时 —— 0.4.0「取不到公网 IP」的直接诱因之一。
 *   C12 `proxy-server-nameserver` 曾是裸 IP 明文（`- 223.5.5.5` / `- 119.29.29.29`），
 *       代理服务器域名解析走明文 UDP → 可被投毒成假 IP，隧道指向攻击者。
 *   D13 `AppSettings.fromJson` 曾接受 `direct`，一旦误触就把「直连」写进磁盘并跨重启
 *       恢复：VPN 连上了但代理完全不生效，用户几乎不可能想到是模式问题。
 *   D14 同一问题的写入口：`applyProxyMode('direct')` 曾经无条件 `SettingsService.save`。
 *
 * ⚠ 已知陷阱（本脚本已处理）：
 *   · Windows 上是 **CRLF 检出**：先 `replace(/\r\n/g, '\n')` 再断言，否则跨行断言假阴性。
 *   · 大量关键字符串在**注释**里也出现（例如 HomePage 的注释解释了「已移除的 DoH 预热」
 *     并引用了 `DoHResolver.resolveMany`）。所有断言先剥注释，否则会把"解释为什么删掉"
 *     的注释误判成"代码里还在调用"。
 *   · 中文字面量（`节点选择失败`）与 YAML 行（`tls://…`）在抹掉字符串内容的视图里不可见，
 *     需要「只剥注释」的第二视图；两视图偏移对齐，可交叉使用。
 *
 * 用法:
 *   node scripts/verify-connect-stability.mjs
 *   node scripts/verify-connect-stability.mjs --root /c/Worker/_baseline_head/TunBox_HarmonyOS
 *   node scripts/verify-connect-stability.mjs --file <ConnectionOrchestrator.ets> \
 *        --api <ClashApiService.ets> --gen <ClashConfigGenerator.ets> \
 *        --settings <AppSettings.ets> --home <HomePage.ets>
 *   （--file/--api/--gen/--settings/--home/--root 用于负对照：指向修复前的文件时
 *     本脚本**必须失败**）
 *
 * 退出码: 0 = 全部断言通过；1 = 有断言失败
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

function argOf(flag) {
  const i = process.argv.indexOf(flag);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : null;
}

const rootOverride = argOf('--root');
const appRoot = rootOverride ? path.resolve(rootOverride) : path.resolve(here, '..');
const etsRoot = path.join(appRoot, 'entry', 'src', 'main', 'ets');
const svcDir = path.join(etsRoot, 'commons', 'services');

const orchPath = argOf('--file') ? path.resolve(argOf('--file'))
  : path.join(svcDir, 'ConnectionOrchestrator.ets');
const apiPath = argOf('--api') ? path.resolve(argOf('--api'))
  : path.join(svcDir, 'ClashApiService.ets');
const genPath = argOf('--gen') ? path.resolve(argOf('--gen'))
  : path.join(svcDir, 'ClashConfigGenerator.ets');
const settingsPath = argOf('--settings') ? path.resolve(argOf('--settings'))
  : path.join(etsRoot, 'commons', 'models', 'AppSettings.ets');
const homePath = argOf('--home') ? path.resolve(argOf('--home'))
  : path.join(etsRoot, 'pages', 'HomePage.ets');

let pass = 0;
const fails = [];
function ok(name, cond, extra) {
  if (cond) {
    pass += 1;
    console.log(`  ✓ ${name}`);
  } else {
    fails.push(name + (extra ? ` (${extra})` : ''));
    console.log(`  ✗ ${name}${extra ? ` — ${extra}` : ''}`);
  }
}

// ── 读文件 + CRLF 归一 ────────────────────────────────────────────────
function readText(p) {
  if (!fs.existsSync(p)) {
    console.log(`  ✗ file.missing — 找不到被测文件: ${p}`);
    fails.push(`file.missing ${p}`);
    return '';
  }
  return fs.readFileSync(p, 'utf8').replace(/\r\n/g, '\n');
}

/** 只剥注释（保留字符串内容与原始偏移）。 */
function stripComments(src) {
  const out = src.split('');
  const n = src.length;
  const blank = (from, to) => {
    for (let k = from; k < to && k < n; k += 1) {
      if (out[k] !== '\n') out[k] = ' ';
    }
  };
  let i = 0;
  while (i < n) {
    const c = src[i];
    const d = src[i + 1];
    if (c === '/' && d === '/') {
      const s = i;
      while (i < n && src[i] !== '\n') i += 1;
      blank(s, i);
      continue;
    }
    if (c === '/' && d === '*') {
      const s = i;
      i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i += 1;
      i += 2;
      blank(s, Math.min(i, n));
      continue;
    }
    if (c === "'" || c === '"' || c === '`') {
      const q = c;
      i += 1;
      while (i < n && src[i] !== q) {
        if (src[i] === '\\') i += 1;
        i += 1;
      }
      i += 1;
      continue;
    }
    i += 1;
  }
  return out.join('');
}

/** 剥注释 + 抹掉字符串/模板字面量内容（保留起止引号），偏移与原文一致。 */
function codeOnly(src) {
  const out = src.split('');
  const n = src.length;
  const blank = (from, to) => {
    for (let k = from; k < to && k < n; k += 1) {
      if (out[k] !== '\n') out[k] = ' ';
    }
  };
  let i = 0;
  while (i < n) {
    const c = src[i];
    const d = src[i + 1];
    if (c === '/' && d === '/') {
      const s = i;
      while (i < n && src[i] !== '\n') i += 1;
      blank(s, i);
      continue;
    }
    if (c === '/' && d === '*') {
      const s = i;
      i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i += 1;
      i += 2;
      blank(s, Math.min(i, n));
      continue;
    }
    if (c === "'" || c === '"' || c === '`') {
      const q = c;
      const s = i;
      i += 1;
      while (i < n && src[i] !== q) {
        if (src[i] === '\\') i += 1;
        i += 1;
      }
      i += 1;
      blank(s + 1, Math.min(i - 1, n));
      continue;
    }
    i += 1;
  }
  return out.join('');
}

function matchBrace(code, openIdx) {
  let depth = 0;
  for (let i = openIdx; i < code.length; i += 1) {
    const c = code[i];
    if (c === '{') depth += 1;
    else if (c === '}') {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

function blockAfter(code, needle, from = 0) {
  const idx = code.indexOf(needle, from);
  if (idx < 0) return null;
  const open = code.indexOf('{', idx + needle.length);
  if (open < 0) return null;
  const close = matchBrace(code, open);
  if (close < 0) return null;
  return { start: idx, bodyStart: open + 1, bodyEnd: close, text: code.slice(open + 1, close) };
}

function methodBody(code, signature) {
  const idx = code.indexOf(signature);
  if (idx < 0) return null;
  const open = code.indexOf('{', idx + signature.length);
  if (open < 0) return null;
  const close = matchBrace(code, open);
  if (close < 0) return null;
  return { start: idx, bodyStart: open + 1, bodyEnd: close, text: code.slice(open + 1, close) };
}

/** 用 code 视图里的区间，切出 lit 视图的同一段（保留字符串内容）。 */
function litOf(lit, range) {
  return range ? lit.slice(range.bodyStart, range.bodyEnd) : '';
}

const orchRaw = readText(orchPath);
const apiRaw = readText(apiPath);
const genRaw = readText(genPath);
const settingsRaw = readText(settingsPath);
const homeRaw = readText(homePath);

const orch = codeOnly(orchRaw);
// 2026-10-20（ND11）：DoH hosts 的唯一来源是 RuntimeConfigBuilder（预算常量在这里）。
const builderLit = stripComments(readText(path.join(etsRoot, 'commons', 'config', 'RuntimeConfigBuilder.ets')));
const orchLit = stripComments(orchRaw);
const api = codeOnly(apiRaw);
const apiLit = stripComments(apiRaw);
const gen = codeOnly(genRaw);
const genLit = stripComments(genRaw);
const settings = codeOnly(settingsRaw);
const settingsLit = stripComments(settingsRaw);
const home = codeOnly(homeRaw);
const homeLit = stripComments(homeRaw);

console.log('===== 连接链路 / DNS / direct 稳定性回归护栏（B + C + D 组）=====');
console.log(`ConnectionOrchestrator: ${orchPath}`);
console.log(`ClashApiService       : ${apiPath}`);
console.log(`ClashConfigGenerator  : ${genPath}`);
console.log(`AppSettings           : ${settingsPath}`);
console.log(`HomePage              : ${homePath}`);
console.log('-----------------------------------------');

// ═══════════════════════════════════════════════════════════════════════
// B7 内核就绪探测的退避封顶必须回到 300ms
//   0.4.0 收到 150ms：内核刚起时 API 探测过于激进，冷启动/弱网下反复打空，
//   连接反而更慢（且日志里满屏 "not ready"）。
// ═══════════════════════════════════════════════════════════════════════
console.log('[B7] READINESS_MAX_DELAY_MS = 300（不得再是 150）');
{
  ok('b7.max-delay-300', /const\s+READINESS_MAX_DELAY_MS\s*=\s*300\s*;/.test(orch),
    '缺少 `const READINESS_MAX_DELAY_MS = 300;`');
  ok('b7.max-delay-not-150', !/READINESS_MAX_DELAY_MS\s*=\s*150\b/.test(orch),
    '仍存在 `READINESS_MAX_DELAY_MS = 150`（0.4.0 的激进值）');
  ok('b7.backoff-uses-cap', /Math\.min\(currentMs\s*\*\s*2,\s*READINESS_MAX_DELAY_MS\)/.test(orch),
    '退避必须由 READINESS_MAX_DELAY_MS 封顶（Math.min(currentMs * 2, READINESS_MAX_DELAY_MS)）');
}

// ═══════════════════════════════════════════════════════════════════════
// B8 节点钉选必须在 state=CONNECTED 之前且被 await
//   守「已连接」上屏早于钉选生效的那个 100–500ms 窗口：
//   窗口内新建的连接走的是内核 store-selections 恢复出来的**上一次**节点。
// ═══════════════════════════════════════════════════════════════════════
console.log('[B8] connect() 里 selectNode 先于 CONNECTED 且被 await');
{
  const connect = methodBody(orch, 'async connectExclusive(');
  ok('b8.connect-found', connect !== null, '找不到 ConnectionOrchestrator.connect()');
  const ct = connect ? connect.text : '';

  const awaitIdx = ct.indexOf('await this.api.selectNode(');
  const connectedIdx = ct.indexOf('this.state = ConnState.CONNECTED;');
  ok('b8.await-select-node-exists', awaitIdx >= 0,
    'connect() 里没有 `await this.api.selectNode(`（钉选要么没做，要么没 await）');
  ok('b8.connected-assignment-exists', connectedIdx >= 0,
    'connect() 里找不到 `this.state = ConnState.CONNECTED;`');
  ok('b8.pin-before-connected', awaitIdx >= 0 && connectedIdx >= 0 && awaitIdx < connectedIdx,
    `钉选必须在置 CONNECTED 之前完成（await=${awaitIdx}, connected=${connectedIdx}）—— 否则「已连接」上屏时走的是旧节点`);

  // fire-and-forget 形态：`this.api.selectNode(...).then(` —— 0.4.0 的写法。
  const fireAndForget = /this\.api\.selectNode\([\s\S]{0,240}?\)\s*\.then\s*\(/.test(ct);
  ok('b8.no-fire-and-forget-pin', !fireAndForget,
    '存在 `this.api.selectNode(...).then(...)` fire-and-forget 钉选（不等结果就上屏「已连接」）');

  // connect() 内每一处 selectNode 调用都必须被 await（不允许漏掉任何一处）。
  const calls = ct.match(/(?:await\s+)?this\.api\.selectNode\(/g) || [];
  const awaited = ct.match(/await\s+this\.api\.selectNode\(/g) || [];
  ok('b8.all-select-node-awaited', calls.length > 0 && calls.length === awaited.length,
    `connect() 里 ${calls.length} 处 selectNode 调用，只有 ${awaited.length} 处被 await`);
}

// ═══════════════════════════════════════════════════════════════════════
// B9 钉选失败**不允许静默**（语义见下）
//
// 0.4.0 在这一处的回归不是「没抛错」，而是 **fire-and-forget + 静默**：
// `this.api.selectNode(...).then(...)` 不等结果就上屏「已连接」，失败只 warn 一行。
// 现在的源码（2026-10-19 二次裁定）是：await → 失败**留可定位日志** → 读回
// `groupSelection('PROXY')` 校验，**不抛错**。理由写在源码注释里：`generate()` 会把
// 被丢弃的非法节点过滤掉，此时 target 可能根本不在 PROXY 组里 → PUT 必然 400 →
// 抛错会把用户从「能连但慢」变成「完全连不上」。
//
// ⚠ 与 task-5 第 9 条（要求 `throw new Error(含「节点选择失败」)`）不一致，
//   以源码现状为准。所以这里守的是**更本质的不变量**：
//   失败必须「要么抛错、要么留下带节点名的日志」，两者都没有才算回归。
//   想按 task-5 原文严格口径校验，加 `--require-throw`。
// ═══════════════════════════════════════════════════════════════════════
console.log('[B9] 钉选失败不得静默（抛错或留痕 + 读回校验）');
{
  const connect = methodBody(orch, 'async connectExclusive(');
  const ctLit = litOf(orchLit, connect);
  ok('b9.pin-guard', connect !== null && /if\s*\(\s*!pinned\s*\)\s*\{/.test(connect.text),
    '缺少 `if (!pinned) { ... }` 的钉选结果判定');

  // 失败分支：抛错 或 带节点名的 warn/error 日志，二者必居其一。
  const failBlk = connect ? blockAfter(connect.text, 'if (!pinned)') : null;
  const failLit = (function () {
    if (!connect || !failBlk) return '';
    const off = ctLit.indexOf('if (!pinned)');
    if (off < 0) return '';
    const open = ctLit.indexOf('{', off);
    const close = open >= 0 ? matchBrace(connect.text, open) : -1;
    return close > 0 ? ctLit.slice(open + 1, close) : '';
  })();
  const throws = /throw\s+new\s+Error\(/.test(failLit);
  const logsWithName = /AppLogger\.(warn|error)\(/.test(failLit) && /pinTargetName/.test(failLit);
  ok('b9.failure-not-silent', failBlk !== null && (throws || logsWithName),
    '钉选失败既没抛错也没留下带节点名的日志 —— 静默失败无法事后定案');

  // Read-back now belongs to selectNode: profiles own their group names.
  // Real nested group behavior is exercised by verify-review-runtime.mjs.
  const apiText = apiRaw;
  ok('b9.graph-read-back', /const afterJson = await this.proxiesJson\(\)/.test(apiText),
    '选点后必须重新读取真实内核目录');
  ok('b9.graph-verifies-members', /entry\['now'\] !== pair\[1\]/.test(apiText),
    '必须验证所有实际操作组的 now');
  ok('b9.no-fake-success', throws, '选点未生效必须阻止 CONNECTED');
  ok('b9.nested-path', /selectionPath\(/.test(apiText), '嵌套组必须沿组链设置');

  // task-5 原文严格口径（默认不启用）：钉选失败必须抛错。
  if (process.argv.includes('--require-throw')) {
    ok('b9.throw-node-select-failed', /throw\s+new\s+Error\(\s*`节点选择失败/.test(ctLit),
      '钉选失败必须 `throw new Error(`节点选择失败…`)`（--require-throw 严格口径）');
  } else if (!throws) {
    console.log('  · 说明: 源码采用 0.3.3 宽松语义（钉选失败只 warn 不抛错），'
      + '已按「不得静默」校验；加 --require-throw 可切回 task-5 原文口径');
  }
}

// ═══════════════════════════════════════════════════════════════════════
// B10 DoH 预解析预算必须是固定 6000ms
//   0.4.0 在「目标域名已 pin」时收紧到 1500ms：备用节点域名几乎必然解析不到，
//   不进 YAML hosts → 运行期退回明文 DNS 现解析 → 切节点时可能拿到被污染的 IP。
// ═══════════════════════════════════════════════════════════════════════
console.log('[B10] DoH 预算固定 6000ms（不得再有 1500 收紧分支）');
{
  // 2026-10-20（ND11 收口）：DoH 解析入口收口到 RuntimeConfigBuilder.resolveSharedHosts
  // ⇒ 编排器不再自己调 resolveMany ⇒ 预算常量的真源变成 RuntimeConfigBuilder.DOH_BUDGET_MS。
  const dohBudgetConst = /static readonly DOH_BUDGET_MS:\s*number\s*=\s*6000/.test(builderLit)
    || /resolveMany\(domains,\s*6000,/.test(builderLit);
  ok('b10.budget-6000-literal', dohBudgetConst,
    'DoH 预算必须是固定 6000ms（真源：RuntimeConfigBuilder.DOH_BUDGET_MS）');
  ok('b10.no-dynamic-budget', !/dohBudgetMs/.test(orch),
    '仍存在 `dohBudgetMs` 动态预算（0.4.0 的 1500ms 收紧分支）');
  ok('b10.no-pin-shortcut', !/hasUsablePin\(priorityDomain\)/.test(orch),
    '仍存在「目标域名已 pin 就收紧预算」的判定（hasUsablePin(priorityDomain)）');
  ok('b10.no-1500-server-budget', !/resolveMany\(serverDomains,\s*1500/.test(orch),
    '仍存在 resolveMany(serverDomains, 1500, …) 的收紧调用');
}

// ═══════════════════════════════════════════════════════════════════════
// B11 首页不得再有冷启 DoH 预热
//   16 worker × 6s 预算与启动期公网 IP 查询必然重叠，弱网下把 ip-api 握手挤到超时；
//   预热产物还大部分被「短 TTL 不 pin」策略丢弃，收益远小于代价。
//   ⚠ HomePage 的注释里**引用了** `DoHResolver.resolveMany` 来解释为什么删掉它，
//     所以必须用剥注释后的视图断言，否则会误判。
// ═══════════════════════════════════════════════════════════════════════
console.log('[B11] HomePage 不再包含冷启 DoH 预热');
{
  ok('b11.no-dohresolver-import', !/import\s*\{[^}]*\bDoHResolver\b[^}]*\}/.test(home),
    'HomePage 仍在 import DoHResolver（预热已移除，不该再有这条依赖）');
  ok('b11.no-resolve-many-call', !/DoHResolver\.resolveMany\s*\(/.test(home),
    'HomePage 仍调用 DoHResolver.resolveMany（冷启预热会与公网 IP 查询抢连接）');
  ok('b11.no-dohresolver-identifier', !/\bDoHResolver\b/.test(home),
    'HomePage 代码里仍出现 DoHResolver 标识符（注释里解释历史可以，代码里不行）');
}

// ═══════════════════════════════════════════════════════════════════════
// C12 proxy-server-nameserver 必须是加密 DoT，且块内不得有裸 IP 明文
//   代理服务器域名走明文 UDP 解析 → 可被投毒成攻击者 IP，隧道整条指向假服务器。
// ═══════════════════════════════════════════════════════════════════════
console.log('[C12] proxy-server-nameserver 使用加密 DoT（无裸 IP 明文）');
{
  // 取 `proxy-server-nameserver:` 这一段（到下一个 `lines.push('  <key>:` 为止）。
  const startIdx = genLit.indexOf('proxy-server-nameserver:');
  let block = '';
  if (startIdx >= 0) {
    const lines = genLit.slice(startIdx).split('\n');
    const collected = [lines[0]];
    for (let i = 1; i < lines.length; i += 1) {
      if (/lines\.push\('  [a-zA-Z0-9_-]+:/.test(lines[i])) break;
      collected.push(lines[i]);
    }
    block = collected.join('\n');
  }
  ok('c12.block-found', startIdx >= 0, '找不到 proxy-server-nameserver 配置块');
  ok('c12.dot-aliyun', /tls:\/\/223\.5\.5\.5:853/.test(block),
    '缺少加密 DoT `tls://223.5.5.5:853`');
  ok('c12.dot-dnspod', /tls:\/\/1\.12\.12\.12:853/.test(block),
    '缺少加密 DoT `tls://1.12.12.12:853`');
  ok('c12.no-bare-aliyun', !/-\s*223\.5\.5\.5\s*'/.test(block),
    '块内仍有裸 IP 明文条目 `- 223.5.5.5`（明文 UDP 可被投毒）');
  ok('c12.no-bare-dnspod', !/-\s*119\.29\.29\.29\s*'/.test(block),
    '块内仍有裸 IP 明文条目 `- 119.29.29.29`（明文 UDP 可被投毒）');
}

// ═══════════════════════════════════════════════════════════════════════
// D13 AppSettings.fromJson 不接受 direct
//   一旦 direct 跨重启恢复，用户误触一次之后每次启动都直连：VPN 连上了但代理完全
//   不生效、公网 IP 是本地出口，而用户几乎不可能想到是「模式」问题。
// ═══════════════════════════════════════════════════════════════════════
console.log('[D13] AppSettings.fromJson 不恢复 direct');
{
  const fromJson = methodBody(settings, 'static fromJson(');
  ok('d13.fromjson-found', fromJson !== null, '找不到 AppSettings.fromJson');
  const ft = litOf(settingsLit, fromJson);
  ok('d13.only-global-accepted', /s\.proxyMode\s*=\s*parsedMode\s*===\s*'global'\s*\?\s*'global'\s*:\s*'rule'\s*;/.test(ft),
    "proxyMode 必须写成 `parsedMode === 'global' ? 'global' : 'rule'`（其余一律回落 rule）");
  ok('d13.no-direct-accepted', !/parsedMode\s*===\s*'direct'/.test(ft),
    "fromJson 仍在接受 'direct'（direct 不得从磁盘恢复）");
  ok('d13.no-direct-literal', !/'direct'/.test(ft),
    "fromJson 里仍出现 'direct' 字面量");
}

// ═══════════════════════════════════════════════════════════════════════
// D14 applyProxyMode('direct') 不落盘
//   写入口与恢复口要同时关掉：只堵 fromJson 的话，direct 仍会被写进磁盘，
//   下次启动虽回落 rule，但磁盘里留着「上次是直连」的脏状态，且 save 本身是多余 I/O。
// ═══════════════════════════════════════════════════════════════════════
console.log("[D14] HomePage.applyProxyMode 在 mode === 'direct' 时不落盘");
{
  const apply = methodBody(home, 'private async applyProxyMode(');
  ok('d14.method-found', apply !== null, '找不到 HomePage.applyProxyMode');
  const at = apply ? apply.text : '';
  const atLit = litOf(homeLit, apply);

  // 定位守卫（字面量在 lit 视图里），花括号配对在 code 视图里做（同偏移）。
  const guardOff = atLit.indexOf("if (mode !== 'direct')");
  let guardBody = null;
  if (guardOff >= 0) {
    const open = atLit.indexOf('{', guardOff);
    const close = open >= 0 ? matchBrace(at, open) : -1;
    if (close > 0) guardBody = atLit.slice(open + 1, close);
  }
  ok('d14.direct-guard', guardBody !== null,
    "缺少 `if (mode !== 'direct') { ... }` 守卫（direct 不得写盘）");
  // 落盘入口：整单 save() 或字段级 patchSettings() 都算「落盘」
  // （审计 F2 后设置页一律走字段级入口 patchSettings）。
  const persistRe = /SettingsService\.(save|patchSettings)\s*\(/;
  ok('d14.save-inside-guard', guardBody !== null && persistRe.test(guardBody),
    '守卫块里没有落盘调用 —— 非 direct 模式仍应落盘');

  const saves = at.match(/SettingsService\.(save|patchSettings)\s*\(/g) || [];
  ok('d14.save-only-once', saves.length === 1,
    `applyProxyMode 里落盘调用应只有 1 处（在 direct 守卫内），实际 ${saves.length} 处`);
}

// ── 汇总 ──────────────────────────────────────────────────────────────
console.log('-----------------------------------------');
console.log(`PASSED=${pass}  FAILED=${fails.length}  TOTAL=${pass + fails.length}`);
if (fails.length > 0) {
  for (const f of fails) console.log('  FAIL ' + f);
  console.log('RESULT: CONNECT STABILITY CHECKS FAILED');
  process.exit(1);
}
console.log('RESULT: ALL CONNECT STABILITY CHECKS PASSED');
