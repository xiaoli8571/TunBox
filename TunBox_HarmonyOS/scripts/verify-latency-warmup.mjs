#!/usr/bin/env node
/**
 * 测速启动结构门禁：controller 通过本次凭证验证即可放行 TCP 测速，
 * 不再保留旧 HTTP 连接池的固定 1 秒补偿。
 * 保留停旧扩展、真实连接前回收测速核、空闲回收与页面反馈检查。
 * 行为回归在 verify-latency-startup-runtime.mjs 中执行生产方法。
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
const pagesDir = path.join(etsRoot, 'pages');

const ORCH = path.join(svcDir, 'ConnectionOrchestrator.ets');
const BG = path.join(svcDir, 'BackgroundLatencyService.ets');
const SUB_PAGE = path.join(pagesDir, 'NodeSelectionPage.ets');
const NODE_PAGE = path.join(pagesDir, 'NodeSelectionPage.ets');

// ── 断言收集 ──────────────────────────────────────────────────────────
let pass = 0;
const fails = [];
function ok(name, cond, extra) {
  if (cond) {
    pass += 1;
    console.log(`  ✓ ${name}`);
  } else {
    fails.push(name + (extra ? ` (${extra})` : ''));
    console.log(`  ✗ ${name}${extra ? ' — ' + extra : ''}`);
  }
}
function fatal(msg) {
  console.log(`  ✗ 前置检查失败 — ${msg}`);
  console.log('-----------------------------------------');
  console.log('PASSED=0  FAILED=1  TOTAL=1');
  console.log('RESULT: LATENCY WARMUP CHECKS FAILED (missing input file)');
  process.exit(1);
}

// ── 读文件 + CRLF 归一 ────────────────────────────────────────────────
function readText(p) {
  if (!fs.existsSync(p)) {
    fatal(`找不到被测文件: ${p}`);
  }
  return fs.readFileSync(p, 'utf8').replace(/\r\n/g, '\n');
}

/**
 * 生成两个**偏移对齐**的视图：
 *   code —— 剥注释 + 抹掉字符串/模板字面量内容（结构断言用）
 *   lit  —— 只剥注释，字符串内容原样保留（文案断言用）
 *
 * 说明：字符串/模板字面量被整体跳过（不回填内容），所以字面量里的 `//`、`/*`、
 * 引号、花括号都不会干扰注释识别与花括号配对。
 */
function buildViews(src) {
  const n = src.length;
  const code = src.split('');
  const lit = src.split('');
  const blankCode = (from, to) => {
    for (let k = from; k < to && k < n; k += 1) if (code[k] !== '\n') code[k] = ' ';
  };
  const blankLit = (from, to) => {
    for (let k = from; k < to && k < n; k += 1) if (lit[k] !== '\n') lit[k] = ' ';
  };
  let i = 0;
  while (i < n) {
    const c = src[i];
    const d = src[i + 1];
    if (c === '/' && d === '/') {
      const s = i;
      while (i < n && src[i] !== '\n') i += 1;
      blankCode(s, i);
      blankLit(s, i);
      continue;
    }
    if (c === '/' && d === '*') {
      const s = i;
      i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i += 1;
      i = Math.min(i + 2, n);
      blankCode(s, i);
      blankLit(s, i);
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
      i = Math.min(i + 1, n);
      // code 视图：字面量内容抹成空格（引号保留）；lit 视图：内容保留
      blankCode(s + 1, i - 1);
      continue;
    }
    i += 1;
  }
  return { code: code.join(''), lit: lit.join('') };
}

// ── 结构工具 ──────────────────────────────────────────────────────────
function matchPair(code, openIdx, openCh, closeCh) {
  let depth = 0;
  for (let i = openIdx; i < code.length; i += 1) {
    const c = code[i];
    if (c === openCh) depth += 1;
    else if (c === closeCh) {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}
const matchBrace = (code, openIdx) => matchPair(code, openIdx, '{', '}');
const matchParen = (code, openIdx) => matchPair(code, openIdx, '(', ')');

/** 截取一个方法体：签名（正则）→ 匹配花括号 → 返回 { start, bodyStart, bodyEnd, text } */
function methodBody(code, signatureRe) {
  const re = signatureRe instanceof RegExp ? signatureRe : new RegExp(escapeRe(signatureRe));
  const m = re.exec(code);
  if (!m) return null;
  const open = code.indexOf('{', m.index);
  if (open < 0) return null;
  const close = matchBrace(code, open);
  if (close < 0) return null;
  return {
    start: m.index,
    bodyStart: open + 1,
    bodyEnd: close,
    text: code.slice(open + 1, close),
    declLine: code.slice(code.lastIndexOf('\n', m.index) + 1, code.indexOf('\n', m.index)),
  };
}
function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** 收集文件里所有「行首成员定义」的方法：{ name, decl, body } */
function collectMethods(code) {
  const out = [];
  const re = /^[ \t]*(?:(?:public|private|protected)[ \t]+)?(?:static[ \t]+)?(?:async[ \t]+)?([A-Za-z_$][\w$]*)[ \t]*\(/gm;
  let m;
  while ((m = re.exec(code)) !== null) {
    const name = m[1];
    const open = code.indexOf('{', m.index);
    if (open < 0) continue;
    // 确认这个 '(' 后面确实是函数体而不是抽象签名
    const close = matchBrace(code, open);
    if (close < 0) continue;
    const declLine = code.slice(code.lastIndexOf('\n', m.index) + 1, code.indexOf('\n', m.index));
    out.push({
      name,
      declLine,
      isPrivate: /(^|[^\w$])private[ \t]/.test(declLine),
      isStatic: /(^|[^\w$])static[ \t]/.test(declLine),
      body: code.slice(open + 1, close),
      bodyStart: open + 1,
      bodyEnd: close,
    });
    re.lastIndex = close;
  }
  return out;
}

/** 收集一个方法体里所有 if 子句（含 else if）：{ cond, block } */
function collectIfBlocks(code) {
  const out = [];
  const re = /\bif[ \t]*\(/g;
  let m;
  while ((m = re.exec(code)) !== null) {
    const open = code.indexOf('(', m.index);
    const close = matchParen(code, open);
    if (close < 0) continue;
    const cond = code.slice(open + 1, close);
    let i = close + 1;
    while (i < code.length && /\s/.test(code[i])) i += 1;
    let block = null;
    if (code[i] === '{') {
      const c = matchBrace(code, i);
      if (c < 0) continue;
      block = code.slice(i + 1, c);
    } else {
      // 无花括号的单语句分支
      let depth = 0;
      let j = i;
      for (; j < code.length; j += 1) {
        const c = code[j];
        if (c === '(' || c === '[' || c === '{') depth += 1;
        else if (c === ')' || c === ']' || c === '}') depth -= 1;
        else if (c === ';' && depth <= 0) break;
      }
      block = code.slice(i, j);
    }
    out.push({ cond, block });
    re.lastIndex = Math.max(re.lastIndex, i);
  }
  return out;
}

/** 顶层逗号切分（调用实参） */
function splitArgs(code, openIdx) {
  const close = matchParen(code, openIdx);
  if (close < 0) return [];
  const inner = code.slice(openIdx + 1, close);
  const args = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < inner.length; i += 1) {
    const c = inner[i];
    if (c === '(' || c === '[' || c === '{') depth += 1;
    else if (c === ')' || c === ']' || c === '}') depth -= 1;
    else if (c === ',' && depth === 0) {
      args.push(inner.slice(start, i));
      start = i + 1;
    }
  }
  args.push(inner.slice(start));
  return args.map((s) => s.trim());
}

/** 文件级常量表：const NAME = 123 / readonly NAME = 123 → 数值 */
function collectNumericConsts(code) {
  const map = new Map();
  const re = /\b(?:const|readonly|static[ \t]+readonly)[ \t]+([A-Za-z_$][\w$]*)[ \t]*(?::[ \t]*number[ \t]*)?=[ \t]*(\d+)[ \t]*;/g;
  let m;
  while ((m = re.exec(code)) !== null) {
    map.set(m[1], Number(m[2]));
  }
  return map;
}

/** 解析一个 setTimeout 的延迟表达式 → 数值（能解析出确切值时）；解析不出返回 null */
function resolveDelay(expr, consts) {
  const e = expr.trim();
  if (e.length === 0) return null;
  if (/^\d+$/.test(e)) return Number(e);
  if (/^[A-Za-z_$][\w$]*$/.test(e)) {
    const v = consts.get(e);
    return v === undefined ? null : v;
  }
  const min = /^Math\.min\((.*)\)$/s.exec(e);
  if (min) {
    const parts = splitTopLevel(min[1]);
    const vals = parts.map((p) => resolveDelay(p, consts)).filter((v) => v !== null);
    return vals.length === parts.length && vals.length > 0 ? Math.min(...vals) : null;
  }
  const max = /^Math\.max\((.*)\)$/s.exec(e);
  if (max) {
    const parts = splitTopLevel(max[1]);
    const vals = parts.map((p) => resolveDelay(p, consts)).filter((v) => v !== null);
    return vals.length === parts.length && vals.length > 0 ? Math.max(...vals) : null;
  }
  return null;
}
function splitTopLevel(s) {
  const parts = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < s.length; i += 1) {
    const c = s[i];
    if (c === '(' || c === '[' || c === '{') depth += 1;
    else if (c === ')' || c === ']' || c === '}') depth -= 1;
    else if (c === ',' && depth === 0) {
      parts.push(s.slice(start, i).trim());
      start = i + 1;
    }
  }
  parts.push(s.slice(start).trim());
  return parts;
}

/** 方法体里所有 setTimeout 的 { delayExpr, delay } */
function collectSetTimeouts(body, consts) {
  const out = [];
  const re = /\bsetTimeout[ \t]*\(/g;
  let m;
  while ((m = re.exec(body)) !== null) {
    const open = body.indexOf('(', m.index);
    const args = splitArgs(body, open);
    const delayExpr = args.length >= 2 ? args[1] : '';
    out.push({ expr: delayExpr, delay: resolveDelay(delayExpr, consts) });
  }
  return out;
}

// ── 布尔量识别（if 条件里那个「扩展之前是否在跑」） ────────────────────
const JS_KEYWORDS = new Set([
  'if', 'else', 'return', 'true', 'false', 'null', 'undefined', 'await', 'typeof',
  'instanceof', 'in', 'of', 'new', 'this', 'const', 'let', 'var', 'function', 'void',
]);

/**
 * 从 if 条件里找出「本地布尔量」：
 *   · 必须在方法体内被声明或赋值（不是全局常量、不是 import）；
 *   · 且看起来是布尔：名字带 was/had/prev/before/running/alive/... 提示，
 *     或被直接赋 true/false，或初值来自一个 is…/has… 之类的判定调用。
 */
function findBooleanGuards(body, cond) {
  const ids = [...new Set((cond.match(/[A-Za-z_$][\w$]*/g) || [])
    .filter((x) => !JS_KEYWORDS.has(x)))];
  const hits = [];
  for (const id of ids) {
    const decl = new RegExp(`(?:^|[^\\w$.])(?:const|let|var)[ \\t]+${id}\\b`).test(body);
    const assign = new RegExp(`(?:^|[^\\w$.])${id}[ \\t]*=(?!=)`).test(body);
    const thisAssign = new RegExp(`this\\.${id}[ \\t]*=(?!=)`).test(body);
    if (!decl && !assign && !thisAssign) continue;
    const nameHint = /(was|had|prev|before|already|running|alive|active|exist|orig|initial|stopp|need|grace)/i
      .test(id);
    const literalBool = new RegExp(
      `(?:^|[^\\w$.])(?:const|let|var)?[ \\t]*${id}[ \\t]*(?::[ \\t]*boolean[ \\t]*)?=[ \\t]*(true|false)\\b`
    ).test(body);
    const callHint = new RegExp(
      `(?:^|[^\\w$.])(?:const|let|var)[ \\t]+${id}[^=]*=[ \\t]*[^;]*\\b(?:is|was|has|can|should)[A-Za-z]*[ \\t]*\\(`,
    ).test(body);
    if (nameHint || literalBool || callHint) hits.push(id);
  }
  return hits;
}

// ── 载入被测文件 ──────────────────────────────────────────────────────
const orchRaw = readText(ORCH);
const bgRaw = readText(BG);
const subRaw = readText(SUB_PAGE);
const nodeRaw = readText(NODE_PAGE);

const orch = buildViews(orchRaw);
const bg = buildViews(bgRaw);
const sub = buildViews(subRaw);
const node = buildViews(nodeRaw);

const orchConsts = collectNumericConsts(orch.code);
const orchMethods = collectMethods(orch.code);

console.log('===== 测速通道预热 / 秒开 —— 结构不变量闸门 =====');
console.log(`ConnectionOrchestrator      : ${ORCH}`);
console.log(`BackgroundLatencyService   : ${BG}`);
console.log(`NodeSelectionPage (subscription replacement): ${SUB_PAGE}`);
console.log(`NodeSelectionPage           : ${NODE_PAGE}`);
console.log('-----------------------------------------');

// Authenticated readiness replaces fixed warm-up windows.
const launchMethod = methodBody(orch.code, /\bprivate[ \t]+async[ \t]+launchTestCore[ \t]*\(/);
let launchBody = launchMethod ? launchMethod.text : '';
const channelMethod = methodBody(orch.code, /\basync[ \t]+ensureLatencyApi[ \t]*\(/);
ok('a1.channel-has-no-sleep', channelMethod !== null
  && !/\bsetTimeout\s*\(/.test(channelMethod.text));
ok('a1.no-fixed-warmup', !/testCoreWarmAt|awaitTestCoreWarmup|TEST_CORE_WARMUP_MS/.test(orch.code));
ok('a2.authenticated-readiness', launchMethod !== null
  && /probeController\s*\(/.test(launchBody) && /probe\.secretAccepted/.test(launchBody));
ok('a2.foreign-controller-rejected', /probe\.httpCode\s*===\s*401/.test(launchBody)
  && /probe\.httpCode\s*===\s*403/.test(launchBody));

// ═══════════════════════════════════════════════════════════════════════
// A2c 启动路径里不做真实 sleep
//   把 1.5s 塞进启动 Promise 会顶高 SingleFlightTestCore 的 15s 超时上限
//   （慢 DoH + 慢就绪时本来能成功的启动会突然被判超时 → 白拆一次再重启）。
// ═══════════════════════════════════════════════════════════════════════
console.log('[A2c] 启动路径里不做 ≥1000ms 的真实 sleep');
{
  const timeouts = collectSetTimeouts(launchBody, orchConsts);
  const long = timeouts.filter((t) => t.delay !== null && t.delay >= 1000);
  ok('a2c.no-long-sleep-in-launch', launchBody.length > 0 && long.length === 0,
    long.length > 0
      ? `launchTestCore() 里仍有 ≥1000ms 的真实 sleep（${long.map((t) => t.expr).join(', ')}）`
        + '—— 会顶高 SingleFlightTestCore 的 15s 启动超时上限；启动路径只应登记预热窗口'
      : '找不到 launchTestCore()');
}

// ═══════════════════════════════════════════════════════════════════════
// A3/A4/A5 停扩展之后「只在扩展真的在跑时」才等
// ═══════════════════════════════════════════════════════════════════════
console.log('[A3] launchTestCore() 内含 stopVpnExtensionAbility');
console.log('[A4] launchTestCore() 内含「if 包裹的 setTimeout」且延迟 ≥ 400ms');
console.log('[A5] 该条件等待由「扩展之前是否在跑」的布尔量把关');
{
  ok('a3.stop-extension-present', launchBody.length > 0
    && /stopVpnExtensionAbility[ \t]*\(/.test(launchBody),
    'launchTestCore() 里找不到 stopVpnExtensionAbility(...)');

  const ifBlocks = collectIfBlocks(launchBody);
  let waitHit = null;
  for (const blk of ifBlocks) {
    const ts = collectSetTimeouts(blk.block, orchConsts);
    for (const t of ts) {
      if (t.delay !== null && t.delay >= 400) {
        waitHit = { blk, delay: t.delay, expr: t.expr };
        break;
      }
    }
    if (waitHit) break;
  }
  ok('a4.conditional-wait', waitHit !== null,
    'launchTestCore() 里没有「if ( ... ) { setTimeout(...) }」形态的条件等待'
    + '（停扩展之后必须只在扩展真的在跑时等，停不掉就白等）'
    + `；已找到的 if 子句: ${ifBlocks.length} 个`);

  const guards = waitHit ? findBooleanGuards(launchBody, waitHit.blk.cond) : [];
  ok('a5.boolean-guard', waitHit !== null && guards.length > 0,
    waitHit
      ? `条件等待的 if 条件「${waitHit.blk.cond.trim()}」里没有找到本地布尔量`
        + '（应有一个记录「扩展之前是否在跑」的布尔量）'
      : 'A4 已失败，无法检查布尔量');
}

// ═══════════════════════════════════════════════════════════════════════
// A6 connect() 路径：先拆测速核，再停 VPN 扩展
// ═══════════════════════════════════════════════════════════════════════
console.log('[A6] connect() 里 stopTestCore() 早于 stopVpnExtensionAbility()');
{
  const m = methodBody(orch.code, /\basync[ \t]+connectExclusive[ \t]*\(/);
  ok('a6.connect-found', m !== null, '找不到 ConnectionOrchestrator.connect()');
  const body = m ? m.text : '';
  const stopCore = /(?:\bthis[ \t]*\.[ \t]*)?(?:stopTestCore|teardownTestCore)[ \t]*\(/.exec(body);
  const stopExt = /stopVpnExtensionAbility[ \t]*\(/.exec(body);
  ok('a6.stop-test-core-called', stopCore !== null,
    'connect() 里没有拆测速核的调用（stopTestCore()）—— '
    + '真实连接会重启扩展进程，测速核必须先拆掉');
  ok('a6.stop-extension-called', stopExt !== null,
    'connect() 里没有 stopVpnExtensionAbility(...)');
  ok('a6.stop-core-before-stop-ext',
    stopCore !== null && stopExt !== null && stopCore.index < stopExt.index,
    stopCore !== null && stopExt !== null
      ? `顺序反了：拆测速核在偏移 ${stopCore.index}，停扩展在偏移 ${stopExt.index}`
      : '缺少其中一方调用，无法比较顺序');
}

// ═══════════════════════════════════════════════════════════════════════
// A7 公开的「预热通道」入口方法，且它调用 ensureLatencyApi
// ═══════════════════════════════════════════════════════════════════════
console.log('[A7] 存在公开的 prewarm 入口方法，且调用 ensureLatencyApi');
const prewarmMethods = orchMethods.filter((m) => m.name.toLowerCase().includes('prewarm'));
{
  ok('a7.prewarm-method-exists', prewarmMethods.length > 0,
    'ConnectionOrchestrator 里找不到名字含 prewarm 的方法'
    + '（形如 prewarmLatencyChannel 的公开预热入口）');
  const pub = prewarmMethods.filter((m) => !m.isPrivate);
  ok('a7.prewarm-method-public', pub.length > 0,
    prewarmMethods.length > 0
      ? `prewarm 方法「${prewarmMethods[0].name}」是 private —— 预热入口必须公开`
      : 'A7 上一条已失败');
  const withApi = prewarmMethods.filter((m) => /ensureLatencyApi[ \t]*\(/.test(m.body));
  ok('a7.prewarm-calls-ensureLatencyApi', withApi.length > 0,
    prewarmMethods.length > 0
      ? `prewarm 方法「${prewarmMethods.map((m) => m.name).join(', ')}」里没有调用 ensureLatencyApi()`
      : 'A7 上一条已失败');
}

// ═══════════════════════════════════════════════════════════════════════
// A8 预热完必须挂回收（不许留常驻内核进程）
// ═══════════════════════════════════════════════════════════════════════
console.log('[A8] 预热入口挂 scheduleTestCoreRecycle 回收');
{
  let found = null;
  for (const pm of prewarmMethods) {
    if (/scheduleTestCoreRecycle[ \t]*\(/.test(pm.body)) {
      found = pm.name;
      break;
    }
    // 一层间接：预热入口调用的方法里挂回收
    const called = new Set((pm.body.match(/[A-Za-z_$][\w$]*[ \t]*\(/g) || [])
      .map((s) => s.replace(/[ \t]*\($/, ''))
      .filter((s) => s.length > 0));
    for (const target of orchMethods) {
      if (target.name === pm.name) continue;
      if (called.has(target.name) && /scheduleTestCoreRecycle[ \t]*\(/.test(target.body)) {
        found = `${pm.name} → ${target.name}`;
        break;
      }
    }
    if (found) break;
  }
  ok('a8.recycle-scheduled', found !== null,
    prewarmMethods.length > 0
      ? `预热入口「${prewarmMethods.map((m) => m.name).join(', ')}」里没有 scheduleTestCoreRecycle(...)`
        + ' —— 预热完必须挂回收，否则会留下常驻测速内核进程'
      : 'A7 已失败（没有 prewarm 入口）');
}

// ═══════════════════════════════════════════════════════════════════════
// A9 BackgroundLatencyService 里的 prewarm 静态方法
// ═══════════════════════════════════════════════════════════════════════
console.log('[A9] BackgroundLatencyService 有 prewarm 静态方法');
{
  const bgMethods = collectMethods(bg.code);
  const hit = bgMethods.filter((m) => m.name.toLowerCase().includes('prewarm'));
  ok('a9.bg-prewarm-method', hit.length > 0,
    'BackgroundLatencyService.ets 里找不到名字含 prewarm 的方法');
  ok('a9.bg-prewarm-static', hit.some((m) => m.isStatic),
    hit.length > 0
      ? `「${hit.map((m) => m.name).join(', ')}」不是 static 方法`
      : 'A9 上一条已失败');
}

// ═══════════════════════════════════════════════════════════════════════
// A10 页面预热调用点
// ═══════════════════════════════════════════════════════════════════════
console.log('[A10] NodeSelectionPage 页面有预热调用');
{
  const subHit = /prewarm/i.test(sub.code);
  const nodeHit = /prewarm/i.test(node.code);
  ok('a10.page-prewarm-call', subHit || nodeHit,
    'NodeSelectionPage.ets 里找不到 prewarm 调用');
}

// ═══════════════════════════════════════════════════════════════════════
// A11 SubscriptionPage 的「准备…通道」用户可见提示文案
// ═══════════════════════════════════════════════════════════════════════
console.log('[A11] NodeSelectionPage 有「准备…通道」的用户可见提示文案');
{
  const literalHit = findChannelHintLiteral(sub.lit);
  ok('a11.prepare-channel-text', literalHit !== null,
    literalHit === null
      ? 'NodeSelectionPage.ets 里找不到同时含「准备」与「通道」的字符串字面量'
        + '（测速预检阶段要给出「准备测速通道」这类用户可见提示）'
      : '');
  if (literalHit) {
    console.log(`      ↳ 命中字面量: ${literalHit}`);
  }
}

// Reset must discard the old controller credentials and stale profile stamp.
const reset = methodBody(orch.code, /\bresetTestCoreChannelState\s*\(/);
ok('a12.reset-clears-channel-ownership', reset !== null
  && /this\.testCoreSecret\s*=/.test(reset.text)
  && /this\.testCoreNodeFingerprint\s*=/.test(reset.text)
  && /this\.api\.setEndpoint/.test(reset.text));

// ── 汇总 ──────────────────────────────────────────────────────────────
console.log('-----------------------------------------');
console.log(`PASSED=${pass}  FAILED=${fails.length}  TOTAL=${pass + fails.length}`);
if (fails.length > 0) {
  for (const f of fails) console.log('  FAIL ' + f);
  console.log('RESULT: LATENCY WARMUP CHECKS FAILED');
  process.exit(1);
}
console.log('RESULT: ALL LATENCY WARMUP CHECKS PASSED');

/**
 * 在 lit 视图里找「同时含 准备 与 通道」的用户可见文案。
 * 优先：同一个字符串字面量里同时含两个词；
 * 次选：两个词在 lit 视图里相距很近（≤ 40 字符）—— 覆盖「'准备测速' + '通道…'」
 *       这种拼接写法，避免拼接造成假阴性。
 */
function findChannelHintLiteral(lit) {
  const re = /'((?:\\.|[^'\\\n])*)'|"((?:\\.|[^"\\\n])*)"|`((?:\\.|[^`\\])*)`/g;
  let m;
  while ((m = re.exec(lit)) !== null) {
    const content = m[1] !== undefined ? m[1] : (m[2] !== undefined ? m[2] : m[3]);
    if (content && content.includes('准备') && content.includes('通道')) {
      return content.slice(0, 80);
    }
  }
  const iPrep = lit.indexOf('准备');
  if (iPrep >= 0) {
    const window = lit.slice(iPrep, iPrep + 40);
    if (window.includes('通道')) {
      return window.split('\n')[0].trim().slice(0, 80) + '（拼接式文案）';
    }
  }
  return null;
}
