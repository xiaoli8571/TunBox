#!/usr/bin/env node
/**
 * 公网 IP 链路稳定性回归护栏（A 组，对应 0.4.0「取不到公网 IP」复盘）
 *
 * ## 守的是什么故障
 *
 * 用户报障：「连上了但首页公网 IP 一直显示『获取公网 IPv4 失败』，点重试也没用」，
 * 且**只有 0.4.0 有**、0.3.3 没有。复盘结论是这条链路**没有任何容错**，四个缺陷叠加：
 *
 *   ① 无请求代次：`refreshPublicIp()` 两个并发调用各自 `await` 后**无条件**写
 *      `publicIp` / `publicIpError`。启动期那次「直连出口」查询（此时隧道还没起，
 *      弱网下最长 5s+8s）晚于连接后那次「走隧道」的成功查询返回时，会把已经显示的
 *      正确 IP **清空成红字**。0.3.3 因为连接慢、两次查询不重叠所以没暴露；0.4.0
 *      把连接提速 0.3–1.5s 后必然重叠 —— 这就是「部分用户、0.4 才有」的根因。
 *   ② 失败就清空：`this.publicIp = ''` 让一次瞬时失败抹掉上一次的可用结果。
 *   ③ `publicIpRefreshing` 可能永久为 true（没有 try/finally），IP 区一直转圈。
 *   ④ 服务层无备用端点、无重试、不读 `status`、**一条日志都没有**：
 *      ip-api 免费版限流返回的是 `HTTP 200 + {"status":"fail"}`，旧实现只判
 *      `responseCode === 200`，于是把「被限流/内网/保留地址」全当成功再判空 IP；
 *      失败后无任何痕迹，用户反馈日志时无法定案。
 *
 * ## 本脚本的断言分组
 *
 *   A1 请求代次：过期结果不得写 UI（守缺陷①③）
 *   A2 失败保留上次成功 IP（守缺陷②）
 *   A3 连接成功后「先作废再查」（守缺陷①的隧道出口串味）
 *   A4 连接状态翻转时作废在飞查询（守缺陷①的同一类竞态）
 *   A5 服务层：status 解析 / 备用端点 / 仅网络类重试 / 每次查询有日志且日志不含 IP（守缺陷④）
 *   A6 所有 `refreshPublicIp(` 调用点都传了 trigger（防止以后新增调用点忘了传，日志无法定位）
 *
 * ⚠ 两个已知陷阱（本脚本已处理，勿改回去）：
 *   · Windows 上仓库是 **CRLF 检出**：必须先 `replace(/\r\n/g, '\n')` 再断言，
 *     否则跨行断言全部假阴性。
 *   · `HomePage.ets` 里**注释中也出现** `DoHResolver.resolveMany` / `refreshPublicIp(${trigger})`
 *     等字样。断言必须先剥注释；判断「调用点有没有传参」时还要把字符串内容抹掉，
 *     否则模板字符串里的日志文本会被当成一次调用。
 *
 * 用法:
 *   node scripts/verify-public-ip-stability.mjs
 *   node scripts/verify-public-ip-stability.mjs --file <HomePage.ets> --service <PublicIpService.ets>
 *   node scripts/verify-public-ip-stability.mjs --root /c/Worker/_baseline_head/TunBox_HarmonyOS
 *   （--file / --service / --root 用于负对照：指向修复前的文件时本脚本**必须失败**）
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

const homePath = argOf('--file')
  ? path.resolve(argOf('--file'))
  : path.join(etsRoot, 'pages', 'HomePage.ets');
const servicePath = argOf('--service')
  ? path.resolve(argOf('--service'))
  : path.join(etsRoot, 'commons', 'services', 'PublicIpService.ets');

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
  // Windows 上是 CRLF 检出；不归一的话所有跨行断言都会假阴性。
  return fs.readFileSync(p, 'utf8').replace(/\r\n/g, '\n');
}

/**
 * 剥注释（保留字符串内容与原始偏移，便于用原始行号定位）。
 * 只用于「必须看字符串内容」的断言，例如日志格式串里有没有拼 IP。
 */
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

/**
 * 剥注释 + 抹掉字符串/模板字面量内容（保留起止引号）。
 * 用于「按代码结构断言」：字符串里的 `refreshPublicIp(...)`、注释里的
 * `DoHResolver.resolveMany(...)` 都不能算数。
 */
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
      blank(s + 1, Math.min(i - 1, n)); // 保留起止引号
      continue;
    }
    i += 1;
  }
  return out.join('');
}

/** 从 openIdx（必须是 '{'）做括号配对，返回闭合 '}' 的下标；失败返回 -1。 */
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

/** 取 needle 之后第一个 '{' 起的花括号块内容（不含花括号）。 */
function blockAfter(code, needle, from = 0) {
  const idx = code.indexOf(needle, from);
  if (idx < 0) return null;
  const open = code.indexOf('{', idx + needle.length);
  if (open < 0) return null;
  const close = matchBrace(code, open);
  if (close < 0) return null;
  return { start: idx, bodyStart: open + 1, bodyEnd: close, text: code.slice(open + 1, close) };
}

/** 取以 signature 开头的方法体。 */
function methodBody(code, signature) {
  const idx = code.indexOf(signature);
  if (idx < 0) return null;
  const open = code.indexOf('{', idx + signature.length);
  if (open < 0) return null;
  const close = matchBrace(code, open);
  if (close < 0) return null;
  return { start: idx, bodyStart: open + 1, bodyEnd: close, text: code.slice(open + 1, close) };
}

const homeRaw = readText(homePath);
const svcRaw = readText(servicePath);
// 两套视图，**偏移完全对齐**（都只把被抹掉的部分替换成等长空格）：
//   · code  = 剥注释 + 抹字符串内容 → 做结构断言、花括号配对、调用点计数
//   · lit   = 只剥注释（保留字符串内容）→ 做「字符串里写了什么」的断言
//             （端点 URL、json['status'] 键名、日志格式串）
// 因为两者长度与原文一致，从 code 里取到的方法体区间可以直接切 lit 的同一段。
const home = codeOnly(homeRaw);
const svc = codeOnly(svcRaw);
const homeLit = stripComments(homeRaw);
const svcLit = stripComments(svcRaw);

/** 用 code 视图里的方法区间，切出 lit 视图的同一段（保留字符串内容）。 */
function litOf(lit, range) {
  return range ? lit.slice(range.bodyStart, range.bodyEnd) : '';
}

console.log('===== 公网 IP 链路稳定性回归护栏（A 组）=====');
console.log(`HomePage       : ${homePath}`);
console.log(`PublicIpService: ${servicePath}`);
console.log('-----------------------------------------');

// ═══════════════════════════════════════════════════════════════════════
// A1 请求代次：过期结果不得写 UI
//   守 0.4.0 的核心 bug：启动期「直连出口」查询晚到，把连接后查到的正确 IP
//   覆盖成「获取失败」红字。没有代次，这个竞态无法避免。
// ═══════════════════════════════════════════════════════════════════════
console.log('[A1] 请求代次（ipQuerySeq）：过期结果不得写 UI');
{
  ok('a1.seq-field-declared', /private\s+ipQuerySeq\s*:\s*number\s*=\s*0\s*;/.test(home),
    '缺少 `private ipQuerySeq: number = 0;` 字段声明');

  const body = methodBody(home, 'private async refreshPublicIp(');
  ok('a1.method-found', body !== null, '找不到 refreshPublicIp 方法');
  const t = body ? body.text : '';

  ok('a1.seq-increment', /const\s+seq\s*=\s*\+\+this\.ipQuerySeq\s*;/.test(t),
    '缺少 `const seq = ++this.ipQuerySeq;`（本次调用的代次）');

  const stale = body ? blockAfter(t, 'if (seq !== this.ipQuerySeq)') : null;
  ok('a1.stale-early-return', stale !== null && /\breturn\s*;/.test(stale.text),
    '缺少 `if (seq !== this.ipQuerySeq) { return; }` 早退分支 —— 这正是旧版覆盖 UI 的入口');

  // 早退分支里绝不能写 UI：一旦写了，代次就形同虚设。
  ok('a1.stale-branch-writes-no-ui', stale !== null
    && !/this\.publicIp\s*=/.test(stale.text)
    && !/this\.publicIpError\s*=/.test(stale.text),
    '过期分支里出现了 UI 写入（publicIp / publicIpError）');

  // 缺陷③：没有 try/finally 时，若 query() 同步抛异常，刷新标志永久为 true。
  ok('a1.try-finally', /\btry\s*\{/.test(t) && /\}\s*finally\s*\{/.test(t),
    '缺少 try/finally —— publicIpRefreshing 可能永久为 true（一直转圈）');

  const fin = body ? blockAfter(t, '} finally') : null;
  ok('a1.finally-resets-flag', fin !== null && /this\.publicIpRefreshing\s*=\s*false\s*;/.test(fin.text),
    'finally 块里没有复位 `this.publicIpRefreshing = false;`');

  // 作废方法本身：连接状态翻转 / 连接成功后调用。
  const inv = methodBody(home, 'private invalidatePublicIpQueries(');
  ok('a1.invalidate-method', inv !== null
    && /this\.ipQuerySeq\s*=\s*this\.ipQuerySeq\s*\+\s*1\s*;/.test(inv.text)
    && /this\.publicIpRefreshing\s*=\s*false\s*;/.test(inv.text),
    'invalidatePublicIpQueries() 必须递增代次并复位刷新标志');
}

// ═══════════════════════════════════════════════════════════════════════
// A2 失败保留上次成功 IP
//   守缺陷②：旧实现失败分支无条件 `this.publicIp = ''`，一次瞬时失败就抹掉
//   上一次可用的结果，用户看到的是「之前好好的，重试一下就变成失败了」。
// ═══════════════════════════════════════════════════════════════════════
console.log('[A2] 失败保留上次成功 IP');
{
  const body = methodBody(home, 'private async refreshPublicIp(');
  const t = body ? body.text : '';

  const thenBlk = body ? blockAfter(t, 'if (info.ip.length > 0)') : null;
  ok('a2.success-writes-ip', thenBlk !== null && /this\.publicIp\s*=\s*info\.ip\s*;/.test(thenBlk.text),
    '成功分支必须 `this.publicIp = info.ip;`');

  // `} else {` 紧跟 then 块结束 —— 用位置切，避免误取到别处的 else。
  let elseBlk = null;
  if (thenBlk) {
    const after = t.indexOf('else', thenBlk.bodyEnd);
    if (after >= 0) {
      const open = t.indexOf('{', after);
      const close = open >= 0 ? matchBrace(t, open) : -1;
      if (close > 0) elseBlk = { text: t.slice(open + 1, close) };
    }
  }
  ok('a2.failure-does-not-clear-ip', elseBlk !== null && !/this\.publicIp\s*=\s*''/.test(elseBlk.text),
    '失败分支仍在无条件 `this.publicIp = \'\'` —— 一次瞬时失败会抹掉上次可用结果');

  ok('a2.failure-guarded-error-text', elseBlk !== null
    && /this\.publicIp\.length\s*===\s*0/.test(elseBlk.text)
    && /this\.publicIpError\s*=/.test(elseBlk.text),
    '失败分支必须「仅在 publicIp 为空时才写 publicIpError」（保留上次成功值）');

  const catchBlk = body ? blockAfter(t, '} catch (e)') : null;
  ok('a2.catch-guarded-error-text', catchBlk !== null
    && /this\.publicIp\.length\s*===\s*0/.test(catchBlk.text),
    'catch 分支同样只能在 publicIp 为空时写错误文案');

  // 清空只允许发生在显式请求（clearBefore）时：换节点/断开后重查是合理的。
  const clears = t.match(/this\.publicIp\s*=\s*''/g) || [];
  const clearGuard = body ? blockAfter(t, 'if (clearBefore)') : null;
  ok('a2.clear-only-on-request', clears.length === 1
    && clearGuard !== null && /this\.publicIp\s*=\s*''/.test(clearGuard.text),
    `方法体内清空 publicIp 只应发生在 if (clearBefore) 里，实际出现 ${clears.length} 次`);
}

// ═══════════════════════════════════════════════════════════════════════
// A3 连接成功后：先作废在飞查询，再查隧道出口
//   只靠代次丢弃也能防覆盖，但在飞的那次「直连出口」查询会继续占用连接/带宽，
//   还可能撞上 ip-api 按出口 IP 的 45 次/分钟限流，得不偿失。
//   两个入口都必须做：电源按钮（toggleConnection）与快捷方式（startConnectionIfNeeded）。
// ═══════════════════════════════════════════════════════════════════════
console.log('[A3] 连接成功后先作废在飞查询再重查（两个入口）');
{
  function checkOrder(label, signature, trigger) {
    const b = methodBody(home, signature);
    if (!b) {
      ok(label, false, `找不到方法 ${signature}`);
      return;
    }
    // 用 lit 视图（保留字符串）：trigger 是字面量，code 视图里已被抹成空格。
    //
    // 只按 **trigger 名**匹配，不写死完整参数表：`refreshPublicIp('after-connect')`
    // 与 `refreshPublicIp('after-connect', true)` 都是合法实现（后者多一个
    // clearBefore，语义更强）。写死完整调用串会在"加参数"时假红 —— 2026-10-19
    // 就踩过一次：把 after-connect 改成带 clearBefore=true 后本断言误报。
    // 守的本质是「先作废、后重查」，与参数个数无关。
    const t = litOf(homeLit, b);
    const invIdx = t.indexOf('this.invalidatePublicIpQueries()');
    const refRe = new RegExp("refreshPublicIp\\(\\s*'" + trigger + "'");
    const m = refRe.exec(t);
    const refIdx = m === null ? -1 : m.index;
    ok(label, invIdx >= 0 && refIdx >= 0 && invIdx < refIdx,
      `要求 invalidatePublicIpQueries() 出现在 refreshPublicIp('${trigger}') 之前`
      + `（inv=${invIdx}, refresh=${refIdx}）`);
  }
  checkOrder('a3.toggle-invalidate-before-refresh', 'private async toggleConnection(', 'after-connect');
  checkOrder('a3.start-invalidate-before-refresh', 'private async startConnectionIfNeeded(', 'after-connect-shortcut');
}

// ═══════════════════════════════════════════════════════════════════════
// A4 连接状态翻转时作废在飞查询
//   出口从「本机宽带」变成「代理」（或反过来）后，旧查询的结论对新状态无意义；
//   让它晚到并写 UI，就会出现「刚连上显示的还是直连 IP / 刚断开显示代理 IP」。
// ═══════════════════════════════════════════════════════════════════════
console.log('[A4] applyOrchestratorState 在状态翻转时作废在飞查询');
{
  const b = methodBody(home, 'private applyOrchestratorState(');
  ok('a4.method-found', b !== null, '找不到 applyOrchestratorState 方法');
  const t = b ? b.text : '';
  ok('a4.was-connected-snapshot', /const\s+wasConnected\s*:\s*boolean\s*=\s*this\.isConnected\s*;/.test(t),
    '缺少 `const wasConnected: boolean = this.isConnected;`（翻转判定需要前值）');
  const flip = b ? blockAfter(t, 'if (wasConnected !== this.isConnected)') : null;
  ok('a4.flip-invalidates', flip !== null && /this\.invalidatePublicIpQueries\s*\(\s*\)/.test(flip.text),
    '状态翻转分支里没有调用 invalidatePublicIpQueries()');
}

// ═══════════════════════════════════════════════════════════════════════
// A5 服务层：status 解析 / 备用端点 / 仅网络类重试 / 每次查询有日志且不含 IP
//   守缺陷④。ip-api 免费版限流 = HTTP 200 + {"status":"fail"}，只判 200 必然误判成功；
//   失败后又没有任何日志，用户反馈时无法定案。
// ═══════════════════════════════════════════════════════════════════════
console.log('[A5] PublicIpService：status / 兜底端点 / 重试策略 / 日志');
{
  const query = methodBody(svc, 'static async query(');
  ok('a5.query-found', query !== null, '找不到 PublicIpService.query');
  const qt = query ? query.text : '';

  ok('a5.trigger-param', /static\s+async\s+query\(\s*trigger\s*:\s*string\s*=/.test(svc),
    'query() 必须接收 trigger 参数（否则日志无法定位是谁发起的）');

  const primary = methodBody(svc, 'private static async queryPrimary(');
  const pt = primary ? primary.text : '';
  // 键名 / 字面量在 lit 视图里才看得见。
  const ptLit = litOf(svcLit, primary);
  ok('a5.status-field-read', /json\['status'\]/.test(ptLit),
    'queryPrimary 没有读取响应里的 `status` 字段（限流时 HTTP 仍是 200）');

  // `if (status === 'fail')` 里的 'fail' 是字面量 → 在 lit 视图里定位，
  // 再回到 code 视图（同偏移）做花括号配对。
  let failBlkLit = null;
  if (primary) {
    const off = ptLit.indexOf("if (status === 'fail')");
    if (off >= 0) {
      const open = ptLit.indexOf('{', off);
      const close = open >= 0 ? matchBrace(pt, open) : -1;
      if (close > 0) failBlkLit = ptLit.slice(open + 1, close);
    }
  }
  ok('a5.status-fail-rejected', failBlkLit !== null && /IpQueryOutcome\.REJECTED/.test(failBlkLit),
    "`status === 'fail'` 必须归类为 REJECTED（限流/内网/保留地址），不能当成功");

  ok('a5.fallback-endpoint', /https:\/\/api64\.ipify\.org/.test(svcLit),
    '缺少备用端点 https://api64.ipify.org（IP 显示优先，宁可没有国家信息也不能显示失败）');
  ok('a5.fallback-method', methodBody(svc, 'private static async queryFallback(') !== null,
    '缺少 queryFallback() 兜底查询方法');

  // 只有网络类失败才重试：`status=fail` 是限流，重试只会让限流更久。
  const retry = query ? blockAfter(qt, 'if (first.outcome === IpQueryOutcome.NETWORK)') : null;
  ok('a5.retry-network-only', retry !== null && /queryPrimary\(/.test(retry.text),
    '缺少「仅网络类失败重试一次」的分支（if (first.outcome === IpQueryOutcome.NETWORK)）');
  ok('a5.no-retry-on-rejected', !/outcome\s*===\s*IpQueryOutcome\.REJECTED/.test(qt),
    'REJECTED（限流）不得进入重试路径');

  const primaryCalls = (qt.match(/PublicIpService\.queryPrimary\(/g) || []).length;
  ok('a5.retry-once-only', primaryCalls === 2,
    `queryPrimary 应被调用 2 次（首次 + 网络类失败重试一次），实际 ${primaryCalls} 次`);

  ok('a5.empty-on-exhausted', /return\s+PublicIpInfo\.empty\(\)\s*;/.test(qt),
    '全失败必须返回空对象，由 UI 显示失败并允许重试');

  // 每次查询都留一行可定案的日志（含端点/耗时/结果类别）。
  const logBody = methodBody(svc, 'private static log(');
  ok('a5.log-method', logBody !== null, '缺少统一的日志方法 log()');
  // 日志格式串是模板字面量 → 必须看 lit 视图。
  const lt = litOf(svcLit, logBody);
  ok('a5.log-info-and-warn', /AppLogger\.info\(TAG,\s*line\)/.test(lt) && /AppLogger\.warn\(TAG,\s*line\)/.test(lt),
    'log() 必须按结果类别分别走 AppLogger.info / AppLogger.warn');
  ok('a5.log-has-diagnostics', /endpoint=\$\{result\.endpoint\}/.test(lt)
    && /outcome=\$\{result\.outcome\}/.test(lt)
    && /elapsed=\$\{result\.elapsedMs\}ms/.test(lt),
    '日志必须含 endpoint / outcome / elapsed，否则无法定案');

  // 日志不得把 IP 明文拼进去（AppLogger 的 LogRedactor 只是兜底，不依赖它）。
  const logRawBody = (function () {
    const raw = stripComments(svcRaw);
    const m = methodBody(raw, 'private static log(');
    return m ? m.text : '';
  })();
  ok('a5.log-without-ip', logRawBody.length > 0
    && !/\$\{[^}]*\.ip\b[^}]*\}/.test(logRawBody)
    && !/\$\{[^}]*\binfo\.ip\b[^}]*\}/.test(logRawBody),
    '日志格式串里拼接了 IP 明文（只允许 trigger/endpoint/outcome/elapsed）');

  // 每个 outcome 分支都要落日志，否则「哪一步失败」仍不可知。
  const logCalls = (pt.match(/PublicIpService\.log\(/g) || []).length;
  ok('a5.log-every-branch', logCalls >= 5,
    `queryPrimary 里至少 5 个结果分支都要记日志，实际 ${logCalls} 处`);
}

// ═══════════════════════════════════════════════════════════════════════
// A6 所有 refreshPublicIp( 调用点都传了 trigger
//   旧版全部是 `refreshPublicIp()`（空参），日志里无法区分是谁发起的查询。
//   新增调用点若忘了传 trigger，这里会直接失败。
// ═══════════════════════════════════════════════════════════════════════
console.log('[A6] 所有 refreshPublicIp( 调用点都传了 trigger');
{
  const callRe = /refreshPublicIp\(/g;
  let m;
  const callSites = [];
  while ((m = callRe.exec(home)) !== null) {
    // 定义处（private async refreshPublicIp(trigger: ...)）不算调用点
    const before = home.slice(Math.max(0, m.index - 20), m.index);
    if (/private\s+async\s+$/.test(before)) continue;
    // 取参数文本到匹配的 ')'
    const open = m.index + m[0].length - 1;
    let depth = 0;
    let end = -1;
    for (let i = open; i < home.length; i += 1) {
      if (home[i] === '(') depth += 1;
      else if (home[i] === ')') {
        depth -= 1;
        if (depth === 0) { end = i; break; }
      }
    }
    const args = end > 0 ? home.slice(open + 1, end).trim() : '';
    // codeOnly() 是**等长就地替换**（注释与字符串内容抹成空格、保留换行与引号），
    // 所以 home 里的下标与 homeRaw 1:1 对应。trigger 名字必须从 homeRaw 取：
    // 在 home 上只能拿到 `'             '` 这种被抹空的字面量，无法按名校验。
    const rawArgs = end > 0 ? homeRaw.slice(open + 1, end).trim() : '';
    callSites.push({ line: home.slice(0, m.index).split('\n').length, args, rawArgs });
  }

  const empty = callSites.filter((c) => c.args.length === 0);
  ok('a6.no-empty-call-site', empty.length === 0,
    `有空参调用点（旧版形态）：${empty.map((c) => 'L' + c.line).join(', ')}`);

  // 触发点清单（2026-10-29 与实现对齐）：
  //   node-switched / reconnect-recover / after-connect-shortcut /
  //   after-disconnect / after-connect / after-mode-change
  //
  // 旧清单里的两项已不存在，此前长期红灯（a6 要求 ≥7、实际 6）：
  //   · home-bootstrap —— 已并入 schedulePublicIpRecover()：连接态跃迁（含启动后首次
  //     落到 CONNECTED）统一走补查，trigger 记为 'reconnect-recover'；
  //   · user-retry —— 从未作为独立调用点存在。出口 IP 画在 CelestialPowerOrb 内部
  //     （ipText），该组件唯一手势是 onToggle→toggleConnection()，不是 IP 重试。
  //
  // 断言改为**按名校验**而非数数：数量阈值会在触发点被合并/改名时静默失真，
  // 按名则能直接指出漏的是哪一个。
  const REQUIRED_TRIGGERS = [
    'node-switched', 'reconnect-recover', 'after-connect-shortcut',
    'after-disconnect', 'after-connect', 'after-mode-change'
  ];
  const foundTriggers = callSites
    .map((c) => {
      const q = c.rawArgs.match(/^'([^']*)'/) || c.rawArgs.match(/^"([^"]*)"/);
      return q ? q[1] : '';
    })
    .filter((t) => t.length > 0);
  const missingTriggers = REQUIRED_TRIGGERS.filter((t) => foundTriggers.indexOf(t) < 0);
  ok('a6.required-triggers', missingTriggers.length === 0,
    `缺少必需触发点：${missingTriggers.join(', ') || '（无）'}；现有：${foundTriggers.join(', ')}`);

  ok('a6.call-site-count', callSites.length >= REQUIRED_TRIGGERS.length,
    `调用点数量 ${callSites.length}，少于必需触发点数量 ${REQUIRED_TRIGGERS.length}（可能漏改了调用）`);

  // 每个参数都得是字符串字面量或 trigger 变量（拒绝 undefined / 空）。
  const bad = callSites.filter((c) => !/^(['"]|trigger\b)/.test(c.args));
  ok('a6.trigger-string-arg', bad.length === 0,
    `调用点参数不是 trigger 字符串：${bad.map((c) => `L${c.line}:${c.args}`).join(', ')}`);
}

// ── 汇总 ──────────────────────────────────────────────────────────────
console.log('-----------------------------------------');
console.log(`PASSED=${pass}  FAILED=${fails.length}  TOTAL=${pass + fails.length}`);
if (fails.length > 0) {
  for (const f of fails) console.log('  FAIL ' + f);
  console.log('RESULT: PUBLIC IP STABILITY CHECKS FAILED');
  process.exit(1);
}
console.log('RESULT: ALL PUBLIC IP STABILITY CHECKS PASSED');
