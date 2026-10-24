#!/usr/bin/env node
/**
 * 测速核「配置新鲜度」闸门 —— 结构不变量（2026-10-20）
 *
 * ## 守的是什么
 *
 * 用户报「导入新订阅后测速显示未生效」。真机取证结论：
 *   · 「未生效」= LatencyFailKind.SWITCH_FAILED = 内核代理表里查不到该节点
 *     （mihomo /delay 直接 404）；
 *   · 根因链：mihomo 配置**只在内核启动那一刻**按当时的节点集生成一次 →
 *     订阅导入/刷新/增删之后配置与节点集脱节 → 而测速核复用时**只探活
 *     controller**（/version 200），**从不校验配置是不是新的** → 新节点永远
 *     测不了，整屏「未生效」；
 *   · 另一条同源链路：导入/刷新后凭据被封存（内存明文清空，见
 *     SubscriptionService.sealPlaintext），而回填只在 App 启动时做 → 生成配置
 *     时这些节点因「缺凭据」被整条跳过 → 同样不在内核代理表里。
 *
 * 所以本闸门锁死的是**结构不变量**（不跑真机、不连内核）：
 *
 *   F1  存在节点集指纹实现（身份：subscriptionId/name/server/port）
 *   F2  指纹同时覆盖「凭据完整度」（password/uuid 非空的节点数）
 *   F3  persist() 是节点集变化的**唯一收口点**，且变化时发出通知
 *   F4  存在节点集变化监听注册入口
 *   F5  编排器 init() 里注册了监听
 *   F6  ensureTestCore() 在**探活之前**比对指纹，且不一致时重建
 *   F7  launchTestCore()：先回填凭据 → 再生成配置 → 再登记指纹（顺序锁死）
 *   F8  真实隧道的配置生成路径同样先回填凭据
 *   F9  存在凭据回填 helper，且它调用 initNodes
 *   F10 resetTestCoreChannelState() 清除指纹
 *   F11 stopTestCore() 清除指纹
 *   F12 存在公开的「订阅变化后作废测速核」入口，且真实隧道在场时**不动**内核
 *   F13 订阅变化后既作废又后台预热（让用户下一次点测速是热的、且配置是新的）
 *
 * ## 已知陷阱
 *
 *   · **必须先剥注释再匹配**（这些文件里到处是解释性注释，不剥会假阳性）；
 *   · **Windows CRLF**：读入后统一 replace(/\r\n/g, '\n')；
 *   · **顺序断言用偏移比较**（指纹比对必须在探活之前；回填必须在生成之前）。
 *
 * 用法:
 *   node scripts/verify-latency-core-freshness.mjs
 *   node scripts/verify-latency-core-freshness.mjs --root <另一个工程根>   （负对照）
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

const ORCH = path.join(svcDir, 'ConnectionOrchestrator.ets');
const SUBSVC = path.join(svcDir, 'SubscriptionService.ets');
const LATSTATE = path.join(svcDir, 'LatencyState.ets');
// 2026-10-20：文案表真源已迁到 commons/latency/LatencyStore.ets（LP04/LP05 收口）。
const LATSTORE = path.join(etsRoot, 'commons', 'latency', 'LatencyStore.ets');
const LATKINDS = path.join(etsRoot, 'commons', 'latency', 'LatencyKinds.ets');

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
  console.log('RESULT: LATENCY CORE FRESHNESS CHECKS FAILED (missing input file)');
  process.exit(1);
}

function readText(p) {
  if (!fs.existsSync(p)) {
    fatal(`找不到被测文件: ${p}`);
  }
  return fs.readFileSync(p, 'utf8').replace(/\r\n/g, '\n');
}

/** code 视图 = 剥注释 + 抹掉字面量内容（结构断言用）；lit 视图 = 只剥注释（文案断言用） */
function buildViews(src) {
  const n = src.length;
  const code = src.split('');
  const lit = src.split('');
  const blank = (arr, from, to) => {
    for (let k = from; k < to && k < n; k += 1) if (arr[k] !== '\n') arr[k] = ' ';
  };
  let i = 0;
  while (i < n) {
    const c = src[i];
    const d = src[i + 1];
    if (c === '/' && d === '/') {
      const s = i;
      while (i < n && src[i] !== '\n') i += 1;
      blank(code, s, i);
      blank(lit, s, i);
      continue;
    }
    if (c === '/' && d === '*') {
      const s = i;
      i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i += 1;
      i = Math.min(i + 2, n);
      blank(code, s, i);
      blank(lit, s, i);
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
      blank(code, s + 1, i - 1);
      continue;
    }
    i += 1;
  }
  return { code: code.join(''), lit: lit.join('') };
}

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
function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** 截取一个方法体：签名（正则）→ 匹配花括号 → { found, body } */
function methodBody(code, signatureRe) {
  const re = signatureRe instanceof RegExp ? signatureRe : new RegExp(escapeRe(signatureRe));
  const m = re.exec(code);
  if (!m) return null;
  const open = code.indexOf('{', m.index);
  if (open < 0) return null;
  const close = matchBrace(code, open);
  if (close < 0) return null;
  return { start: m.index, declLine: code.slice(code.lastIndexOf('\n', m.index) + 1, code.indexOf('\n', m.index)), body: code.slice(open + 1, close) };
}

// ── 读文件 ────────────────────────────────────────────────────────────
const orchSrc = readText(ORCH);
const subSrc = readText(SUBSVC);
const orch = buildViews(orchSrc);
const subs = buildViews(subSrc);
const latSrc = readText(LATSTATE);
const lat = buildViews(latSrc);
const storeSrc = readText(LATSTORE);
const store = buildViews(storeSrc);
const kindsSrc = readText(LATKINDS);
const kinds = buildViews(kindsSrc);

console.log('── 测速核配置新鲜度闸门 ──');

// F1/F2 ── 节点集指纹实现
const fp = methodBody(subs.code, /static\s+nodeSetFingerprint\s*\(/);
ok('F1 存在节点集指纹实现 nodeSetFingerprint(nodes)', fp !== null);
if (fp !== null) {
  const b = fp.body;
  const bLit = subs.lit.slice(subs.lit.indexOf('static nodeSetFingerprint'),
    subs.lit.indexOf('static nodeSetFingerprint') + 1200);
  ok('F1a 指纹覆盖身份（subscriptionId/name/server/port）',
    bLit.includes('subscriptionId') && bLit.includes('name') && bLit.includes('server') && bLit.includes('port'),
    '缺身份字段');
  ok('F2 指纹覆盖凭据完整度（password/uuid 非空计数）',
    b.includes('password') && b.includes('uuid') && /cred/i.test(b),
    '缺凭据维度');
}

// F3 ── persist() 是节点集变化的收口点
const persist = methodBody(subs.code, /private\s+async\s+persist\s*\(/);
ok('F3a 存在 persist() 收口点', persist !== null);
if (persist !== null) {
  const b = persist.body;
  ok('F3b persist() 里计算节点集指纹', b.includes('nodeSetFingerprint'));
  ok('F3c persist() 里发出节点集变化通知', b.includes('notifyNodeSetChanged'));
  ok('F3d 通知前先比对指纹（避免重复通知）', /nodeSetFingerprint[\s\S]{0,400}!==[\s\S]{0,200}notifyNodeSetChanged/.test(b));
}

// F4 ── 监听注册入口
const onChanged = methodBody(subs.code, /static\s+onNodeSetChanged\s*\(/);
ok('F4 存在节点集变化监听注册入口 onNodeSetChanged', onChanged !== null);
if (onChanged !== null) {
  ok('F4a 注册入口把监听者入队', onChanged.body.includes('push'));
}

// F5 ── 编排器注册监听
const init = methodBody(orch.code, /init\s*\(context:\s*Context\)/);
ok('F5 编排器 init() 里注册了节点集变化监听',
  init !== null && init.body.includes('onNodeSetChanged'));

// F6 ── ensureTestCore：先比指纹再探活
const ensure = methodBody(orch.code, /async\s+ensureTestCore\s*\(/);
ok('F6a 存在 ensureTestCore()', ensure !== null);
if (ensure !== null) {
  const b = ensure.body;
  const iFp = b.indexOf('nodeSetFingerprint');
  const iProbe = b.indexOf('verifyTestCoreChannel');
  ok('F6b ensureTestCore() 比对节点集指纹', iFp >= 0, '未出现 nodeSetFingerprint');
  ok('F6c 指纹比对**早于** controller 探活', iFp >= 0 && iProbe >= 0 && iFp < iProbe,
    `指纹@${iFp} 探活@${iProbe}`);
  ok('F6d 配置过期时重建（stopTestCore）', /staleConfig[\s\S]{0,400}stopTestCore/.test(b));
}

/**
 * 「生成配置」锚点：整仓唯一生成入口已改为 RuntimeConfigBuilder.buildRuntimeConfig(
 * （ClashConfigGenerator.generate 只允许出现在 builder 内部）。
 * 闸门关心的是**顺序**（先回填凭据 → 再生成配置），不是调用形式，故两个锚点都认。
 */
const genAnchor = (body) => {
  const a = body.indexOf('RuntimeConfigBuilder.buildRuntimeConfig');
  const c = body.indexOf('ClashConfigGenerator.generate');
  if (a < 0) { return c; }
  if (c < 0) { return a; }
  return Math.min(a, c);
};
/**
 * 「回填凭据」锚点：2026-10-20（lead 执行清退批次 B8）把凭据回填**收敛到唯一入口**
 * `hydrateAndBuildProfile()`，三条生成路径（测速核 / 真实隧道 / 热重载）都改成
 * 「先 await hydrateAndBuildProfile(...) → 再 buildRuntimeConfig(...)」。
 * 闸门关心的是**顺序**不是调用形式，故两个锚点都认：
 *   · `hydrateAndBuildProfile` —— 新入口（内含真正的回填）
 *   · `hydrateNodeCredentials`  —— 旧直调（若将来又出现直调，也要被认出来）
 * 防「只改名字不真回填」：F9b 断言 hydrateAndBuildProfile 内部确实调用 hydrateNodeCredentials。
 */
const hydrateAnchor = (body) => {
  const a = body.indexOf('hydrateAndBuildProfile');
  const c = body.indexOf('hydrateNodeCredentials');
  if (a < 0) { return c; }
  if (c < 0) { return a; }
  return Math.min(a, c);
};
// F7 ── launchTestCore：回填 → 生成 → 登记指纹
const launch = methodBody(orch.code, /private\s+async\s+launchTestCore\s*\(/);
ok('F7a 存在 launchTestCore()', launch !== null);
if (launch !== null) {
  const b = launch.body;
  const iHydrate = hydrateAnchor(b);
  const iGen = genAnchor(b);
  const iFp = b.indexOf('testCoreNodeFingerprint');
  ok('F7b 测速核生成配置前先回填凭据', iHydrate >= 0 && iGen >= 0 && iHydrate < iGen,
    `回填@${iHydrate} 生成@${iGen}`);
  ok('F7c 生成配置后登记节点集指纹', iFp >= 0 && iGen >= 0 && iFp > iGen,
    `生成@${iGen} 指纹@${iFp}`);
}

// F8 ── 真实隧道配置生成路径同样先回填
const connect = methodBody(orch.code, /async\s+connectExclusive\s*\(\s*node:/);
ok('F8a 存在 connect()', connect !== null);
if (connect !== null) {
  const b = connect.body;
  const iHydrate = hydrateAnchor(b);
  const iGen = genAnchor(b);
  ok('F8b 真实隧道生成配置前先回填凭据', iHydrate >= 0 && iGen >= 0 && iHydrate < iGen,
    `回填@${iHydrate} 生成@${iGen}`);
}

// F9 ── 回填 helper
const hydrate = methodBody(orch.code, /private\s+async\s+hydrateNodeCredentials\s*\(/);
ok('F9 存在凭据回填 helper', hydrate !== null);
if (hydrate !== null) {
  ok('F9a 回填 helper 调用 initNodes', hydrate.body.includes('initNodes'));
}
// F9b/F9c ── 新唯一入口（2026-10-20 批次 B8：回填收敛到 hydrateAndBuildProfile）
// 防「只把名字改了、里面其实没回填」——锚点认了新名字，就必须在链尾验到底。
const hydrateAndBuild = methodBody(orch.code, /private\s+async\s+hydrateAndBuildProfile\s*\(/);
ok('F9b 存在凭据回填唯一入口 hydrateAndBuildProfile()', hydrateAndBuild !== null);
if (hydrateAndBuild !== null) {
  ok('F9c 唯一入口内部确实调用 hydrateNodeCredentials',
    hydrateAndBuild.body.includes('hydrateNodeCredentials'));
}

// F10/F11 ── 指纹清理
const reset = methodBody(orch.code, /resetTestCoreChannelState\s*\(\s*\)/);
ok('F10a 存在 resetTestCoreChannelState()', reset !== null);
if (reset !== null) {
  ok('F10b 复位时清除节点集指纹', reset.body.includes('testCoreNodeFingerprint'));
}
const stop = methodBody(orch.code, /async\s+stopTestCore\s*\(/);
ok('F11a 存在 stopTestCore()', stop !== null);
if (stop !== null) {
  ok('F11b 停核时清除节点集指纹', stop.body.includes('testCoreNodeFingerprint'));
}

// F12 ── 订阅变化后作废测速核的公开入口
const invalidate = methodBody(orch.code, /async\s+invalidateTestCoreForSubscriptionChange\s*\(/);
ok('F12a 存在公开入口 invalidateTestCoreForSubscriptionChange()', invalidate !== null);
if (invalidate !== null) {
  ok('F12b 真实隧道在场时不作废（测速核与隧道共用扩展进程）',
    /CONNECTED|CONNECTING/.test(invalidate.body),
    '缺少 CONNECTED/CONNECTING 守卫');
  ok('F12c 作废时确实停核', invalidate.body.includes('stopTestCore'));
}

// F13 ── 订阅变化 → 作废 + 后台预热
const onNodeSet = methodBody(orch.code, /private\s+onSubscriptionNodeSetChanged\s*\(/);
ok('F13a 存在订阅节点集变化处理器', onNodeSet !== null);
if (onNodeSet !== null) {
  ok('F13b 处理器会作废测速核', onNodeSet.body.includes('invalidateTestCoreForSubscriptionChange'));
  ok('F13c 处理器会后台预热（下次点测速是热的、配置是新的）',
    onNodeSet.body.includes('prewarmLatencyChannel'));
}

// F15-F19 —— 真实隧道在场时的同类缺口（隧道配置也只在连接那一刻生成一次）
const ensureApi = methodBody(orch.code, /async\s+ensureLatencyApi\s*\(/);
ok('F15a 存在 ensureLatencyApi()', ensureApi !== null);
if (ensureApi !== null) {
  const b = ensureApi.body;
  const iFresh = b.indexOf('ensureTunnelConfigFresh');
  const iReturn = iFresh >= 0 ? b.indexOf('return this.api', iFresh) : -1;
  ok('F15b 取隧道通道前先判定隧道配置新鲜度', iFresh >= 0, '未调用 ensureTunnelConfigFresh');
  ok('F15c 新鲜度判定早于「把隧道 controller 交出去」', iFresh >= 0 && iReturn >= 0,
    `新鲜度@${iFresh} 交出@${iReturn}`);
}
const fresh = methodBody(orch.code, /private\s+async\s+ensureTunnelConfigFresh\s*\(/);
ok('F16a 存在 ensureTunnelConfigFresh()', fresh !== null);
if (fresh !== null) {
  ok('F16b 隧道配置过期时走热重载（不拆隧道）', fresh.body.includes('reloadRulesHot'));
  ok('F16c 隧道配置指纹与当前节点集比对',
    fresh.body.includes('tunnelConfigFingerprint') && fresh.body.includes('nodeSetFingerprint'));
}
const hot = methodBody(orch.code, /async\s+reloadRulesHotExclusive\s*\(/);
ok('F17a 存在 reloadRulesHot()', hot !== null);
if (hot !== null) {
  const b = hot.body;
  const iHydrate = hydrateAnchor(b);
  const iGen = genAnchor(b);
  ok('F17b 热重载生成配置前先回填凭据', iHydrate >= 0 && iGen >= 0 && iHydrate < iGen,
    `回填@${iHydrate} 生成@${iGen}`);
  const iReload = b.indexOf('reloadFromPath');
  const iFp = b.indexOf('tunnelConfigFingerprint');
  ok('F17c 热重载成功后登记新的隧道配置指纹', iFp >= 0 && iReload >= 0 && iFp > iReload,
    `重载@${iReload} 指纹@${iFp}`);
}
if (connect !== null) {
  const b = connect.body;
  const iGen = genAnchor(b);
  const iFp = b.indexOf('tunnelConfigFingerprint');
  ok('F18 连接生成配置后登记隧道配置指纹', iFp >= 0 && iGen >= 0 && iFp > iGen,
    `生成@${iGen} 指纹@${iFp}`);
}

// 文案断言（lit 视图）：用户可见提示不应把「未生效」说成节点坏了
// 2026-10-20：文案表真源已从 LatencyState 迁到 LatencyStore（LP04/LP05 收口）⇒ 断言跟着换源。
ok('F14 保留「未生效」文案口径（未生效 = 节点没进内核，不是节点坏了）',
  store.lit.includes('未生效') && /switch_failed/.test(kinds.lit),
  'LatencyStore 里找不到「未生效」，或 LatencyKinds 里找不到 switch_failed');

console.log('-----------------------------------------');
console.log(`PASSED=${pass}  FAILED=${fails.length}  TOTAL=${pass + fails.length}`);
if (fails.length > 0) {
  for (const f of fails) console.log('  FAIL ' + f);
  console.log('RESULT: LATENCY CORE FRESHNESS CHECKS FAILED');
  process.exit(1);
}
console.log('RESULT: ALL LATENCY CORE FRESHNESS CHECKS PASSED');
