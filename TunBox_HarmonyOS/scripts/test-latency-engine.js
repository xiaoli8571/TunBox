'use strict';

/**
 * 延迟测试重做（5.6.0）源码级回归。
 *
 * 取代旧的 `test-latency-pipeline.js`：那份套件断言的是被整体删除的旧管线
 * （28 路 lane、整批级 URL 降级、`BATCH_LANES`、`prepareLatencyChannel`、
 * `buildLatencyQueue`、directReachableNames 等）。本套件断言**新架构的实际接线**，
 * 重点是"旧缺陷不许复活"的负向断言。
 *
 * 覆盖：
 *  1. 唯一入口：页面只能通过 LatencyEngine 测速，不得再自己开 lane / 自己解析响应
 *  2. **禁止 `/group/{name}/delay`**：真机 + mihomo 源码确认它会忽略传入 url、
 *     对非 Selector 组 ForceSet("") 清掉用户固定选择、无并发上限、失败节点静默消失
 *  3. 未连接测速路径不得再直接 `ensureTestCore`（改由 `ensureLatencyApi` 统一决策）
 *  4. 测速 URL 必须是 HTTPS（unified-delay 下 http:// 在劫持型代理里会失败）
 *  5. 并发上限存在且有界（内核侧无上限，客户端必须自律）
 *  6. `timeout` 必须显式传且 ≤ 32767（mihomo 按 16 位解析，超限 400）
 *  7. 整批硬截止后剩余节点保持"未测"，绝不写成超时
 *  8. 取消 ≠ 失败；通道不可用 ≠ 节点失败
 *  9. 组条目与内建项必须被过滤（PROXY.all 里混着 14 个组）
 * 10. 内核回收必须避开"用户正在用 VPN"的四种状态
 * 11. ClashConfigGenerator 逻辑内容指纹未被本次重做改动（忽略 CRLF/LF 行尾差异）
 */

const fs = require('fs');
const path = require('path');
const assert = require('assert');
const crypto = require('crypto');

const root = path.resolve(__dirname, '..');
const rel = (p) => path.join(root, p);
const svc = 'entry/src/main/ets/commons/services/';

const page = fs.readFileSync(rel('entry/src/main/ets/pages/NodeSelectionPage.ets'), 'utf8');
const engine = fs.readFileSync(rel(svc + 'LatencyEngine.ets'), 'utf8');
const state = fs.readFileSync(rel(svc + 'LatencyState.ets'), 'utf8');
const api = fs.readFileSync(rel(svc + 'ClashApiService.ets'), 'utf8');
const orch = fs.readFileSync(rel(svc + 'ConnectionOrchestrator.ets'), 'utf8');
const background = fs.readFileSync(rel(svc + 'BackgroundLatencyService.ets'), 'utf8');
const tokens = fs.readFileSync(rel('entry/src/main/ets/theme/UiTokens.ets'), 'utf8');

/** 剥离注释后只保留可执行代码，用于负向断言（注释里复述旧实现不算违规） */
function codeOnly(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/(^|[^:])\/\/[^\r\n]*/g, '$1');
}

const pageCode = codeOnly(page);
const orchCode = codeOnly(orch);
const engineCode = codeOnly(engine);

let passed = 0;
const failures = [];
function check(label, fn) {
  try {
    fn();
    passed++;
    console.log('PASS ' + label);
  } catch (e) {
    failures.push(label + ' :: ' + e.message);
    console.log('FAIL ' + label + ' :: ' + e.message);
  }
}

// ── 1. 唯一入口 ────────────────────────────────────────────────────────────
check('页面用 LatencyEngine 做批测', () => {
  assert.ok(/LatencyEngine\.start\(/.test(pageCode), 'page must call LatencyEngine.start');
  assert.ok(/ensureLatencyApi\(/.test(pageCode), 'page must obtain channel via ensureLatencyApi');
});
check('页面不再持有自己的 lane / 代次 / URL 降级状态', () => {
  // 用词边界匹配：新字段 latencyChannelLabel 里含 "latencyChannel" 子串，纯 includes 会误报
  for (const dead of ['BATCH_LANES', 'batchUrlIndex', 'batchUrlStreak', 'batchGen',
    'latencyChannel', 'directReachableNames', 'untestedNames', 'batchGuardTrips']) {
    assert.ok(!new RegExp('\\b' + dead + '\\b').test(pageCode),
      `page must not reference removed member ${dead}`);
  }
});
check('页面不再自己解析 /delay 响应（不碰 HTTP 状态码/响应体）', () => {
  // 页面允许把记录状态翻译成持久化用的 failKind（那是数据映射，不是分类），
  // 但绝不能自己发请求、自己读**原始** HTTP 响应 —— 那是引擎与 ClashApiService 的职责。
  //
  // ⚠ 2026-10-20 放宽 `httpCode`：C10 之后组测返回**已分类**的
  // GroupLatencyResult，页面读 `groupRes.httpCode` 是读「分类结果」而不是
  // 「原始响应」—— 正是为了把 504（通道正常、节点全不通）与 401/404
  // （真通道故障）区分开。`responseCode`（原始响应字段）仍然禁止。
  for (const forbidden of ['testLatencyDetailed', 'classifyStatusCode', 'classifyTransportError',
    'responseCode']) {
    assert.ok(!new RegExp('\\b' + forbidden + '\\b').test(pageCode),
      `page must not handle raw HTTP (${forbidden})`);
  }
});
check('页面不再有被删除的旧方法', () => {
  for (const dead of ['runBatch', 'probeNodeBounded', 'testNodeDelay', 'applyLatencyResult',
    'buildLatencyQueue', 'prepareLatencyChannel', 'noteUrlFailure', 'settleWorkers',
    'batchGuardMs', 'handleCoreNotReady']) {
    assert.ok(!new RegExp('\\b' + dead + '\\s*\\(').test(pageCode),
      `page must not define/call removed method ${dead}`);
  }
});

// ── 2. 组测速走单一入口 testGroupDetailed（/group/{name}/delay + 显式 timeout） ──
check('组测速只允许经由 ClashApiService.testGroupDetailed', () => {
  for (const [name, src] of [['page', pageCode], ['engine', engineCode]]) {
    assert.ok(!/\/group\//.test(src), `${name} must go through api.testGroupDetailed, not the raw endpoint`);
  }
  assert.ok(/testGroupDetailed\(/.test(codeOnly(api)), 'ClashApiService must expose the single group-test entry');
  const m = codeOnly(api).match(/\/group\/\$\{[^}]+\}\/delay\?url=\$\{[^}]+\}&timeout=\$\{timeoutMs\}/);
  assert.ok(m, 'group delay call must pass an explicit timeout param (kernel 400s without it)');
});

// ── 3. 未连接路径不得绕过 ensureLatencyApi ────────────────────────────────
check('页面不再直接调用 ensureTestCore', () => {
  assert.ok(!/ensureTestCore\s*\(/.test(pageCode),
    'page must not call ensureTestCore directly (ensureLatencyApi decides)');
});
check('ensureLatencyApi 存在且优先复用已连接隧道的 controller', () => {
  assert.ok(/async ensureLatencyApi\(\): Promise<ClashApiService \| null>/.test(orchCode),
    'ensureLatencyApi must exist with the documented signature');
  const body = orchCode.slice(orchCode.indexOf('async ensureLatencyApi'));
  assert.ok(/ConnState\.CONNECTED/.test(body.slice(0, 900)),
    'ensureLatencyApi must prefer the connected tunnel controller');
  assert.ok(/return null/.test(body), 'ensureLatencyApi must return null when no channel exists');
});
check('ensureLatencyApi 未连接时走 headless 测试内核', () => {
  const body = orchCode.slice(orchCode.indexOf('async ensureLatencyApi'));
  assert.ok(/ensureTestCore/.test(body.slice(0, 2000)), 'must attempt ensureTestCore when disconnected');
});
check('后台静默测速也走同一引擎（不再是第二套实现）', () => {
  assert.ok(/LatencyEngine\.start\(/.test(codeOnly(background)),
    'BackgroundLatencyService must delegate to LatencyEngine');
  assert.ok(!/new BatchGuard|LANES|urlFailureStreak/.test(codeOnly(background)),
    'background must not keep its own parallel pipeline');
});

// ── 4. 测速 URL 用 HTTPS（mihomo 官方要求 provider.health-check.url / group.url
//     走 HTTPS；明文测速地址会被机场/落地劫持，把正常节点判成失败） ─────────
//     ⚠ 注意：「用户自填 http 属合法用法」（部分出口掐 gstatic 的 TLS SNI，真机
//     commit a3fe45d 实证 https=Timeout / http=1158ms）—— 客户端只做
//     「历史默认值的单向升级」，绝不改写用户自己填的 http。
check('默认测速 URL 是 HTTPS 的 generate_204（对齐 FlClash 出厂默认）', () => {
  assert.ok(/LATENCY_TEST_URL\s*=\s*'https:\/\/www\.gstatic\.com\/generate_204'/.test(engine),
    'primary test url must be https://www.gstatic.com/generate_204');
  assert.ok(/LATENCY_TEST_URL_ALT\s*=\s*'https:\/\//.test(engine), 'alt test url must be https');
});
check('备用测速源是 HTTPS，且引擎不自动回退（回退会与在途闸门打架）', () => {
  assert.ok(/LATENCY_TEST_URL_ALT\s*=\s*'https:\/\/cp\.cloudflare\.com\/generate_204'/.test(engine),
    'alt test url must be the https cloudflare generate_204');
  assert.ok(!/LATENCY_TEST_URL_ALT\s*[),]/.test(engineCode.replace(/LATENCY_TEST_URL_ALT[^;]*;/g, '')),
    'engine must not auto-fallback to the alt url (it would fight the in-flight gate)');
});
check('AppSettings 默认测速 URL 是 HTTPS，历史 http 默认值单向升级为 https', () => {
  const settings = fs.readFileSync(rel('entry/src/main/ets/commons/models/AppSettings.ets'), 'utf8');
  assert.ok(/DEFAULT_TEST_URL\s*:\s*string\s*=\s*'https:\/\/www\.gstatic\.com\/generate_204'/.test(settings),
    'AppSettings DEFAULT_TEST_URL must be https');
  assert.ok(/LEGACY_TEST_URL_GSTATIC\s*:\s*string\s*=\s*'http:\/\/www\.gstatic\.com\/generate_204'/.test(settings),
    'the legacy http default must be kept as an explicit legacy constant (one-way upgrade source)');
  assert.ok(/upgradeLegacyTestUrl/.test(settings),
    'AppSettings must migrate the legacy http default to https on load');
  // ⚠ 绝不能再有「https → http 强制降级」的旧写法（那是罪魁祸首）
  assert.ok(!/'https:\/\/www\.gstatic\.com\/generate_204'\s*\n?\s*\?\s*'http:\/\//.test(settings),
    'AppSettings must not downgrade https to http any more');
});

// ── 5. 并发上限 ───────────────────────────────────────────────────────────
check('并发上限存在且有界（5~64）', () => {
  const m = engine.match(/LATENCY_CONCURRENCY(?::\s*number)?\s*=\s*(\d+)/);
  assert.ok(m, 'LATENCY_CONCURRENCY must be defined');
  const n = Number(m[1]);
  assert.ok(n >= 5 && n <= 64, `concurrency ${n} must stay within the ecosystem range 5..64`);
});
check('并发上限真的用于 lane 数（不会无界 fan-out）', () => {
  assert.ok(/Math\.min\(LATENCY_CONCURRENCY,/.test(engineCode),
    'lane count must be capped by LATENCY_CONCURRENCY');
});
check('首批请求有错峰抖动（避免整批同时打内核）', () => {
  assert.ok(/STAGGER_MAX_MS/.test(engineCode), 'stagger jitter must exist');
});

// ── 6. timeout 参数 ───────────────────────────────────────────────────────
check('timeout 显式传给内核（不传会 400）', () => {
  assert.ok(/timeout=\$\{|timeout=/.test(codeOnly(api)), 'api must send timeout param');
});
check('单节点超时不超过 16 位上限 32767', () => {
  const m = engine.match(/LATENCY_TIMEOUT_MS\s*=\s*([^;]+);/);
  assert.ok(m, 'LATENCY_TIMEOUT_MS must be defined');
  assert.ok(/LatencyPolicy\.DEFAULT_TIMEOUT_MS/.test(m[1]), 'default timeout must come from the policy');
  const d = state.match(/DEFAULT_TIMEOUT_MS(?::\s*number)?\s*=\s*(\d+)/);
  assert.ok(d && Number(d[1]) > 0 && Number(d[1]) <= 32767, 'default timeout must be 1..32767');
});
check('引擎拒绝把超限 timeout 当作有效值', () => {
  const cap = state.match(/MAX_TIMEOUT_MS(?::\s*number)?\s*=\s*(\d+)/);
  assert.ok(cap, 'MAX_TIMEOUT_MS must exist');
  assert.ok(Number(cap[1]) <= 32767, 'MAX_TIMEOUT_MS must respect the 16-bit parse limit');
});

// ── 7. 硬截止 → 未测 ──────────────────────────────────────────────────────
check('整批有硬截止', () => {
  assert.ok(/BATCH_DEADLINE_MS(?::\s*number)?\s*=\s*\d+/.test(engine), 'batch deadline must exist');
  assert.ok(/deadlineAt/.test(engineCode), 'deadline must be enforced in the worker loop');
});
check('硬截止后剩余节点保持未测（不写失败/超时）', () => {
  const idx = engineCode.indexOf('deadline hit');
  assert.ok(idx > 0, 'deadline must be logged when hit');
  const tail = engineCode.slice(idx, idx + 260);
  assert.ok(!/LatencyRecord\.failed/.test(tail),
    'hitting the deadline must NOT publish failure records for the remaining nodes');
});
check('进度对象能表达"未测/跳过"而不是只有成功失败', () => {
  assert.ok(/skipped/.test(engineCode) && /cancelled/.test(engineCode)
    && /coreNotReady/.test(engineCode), 'progress must distinguish skipped/cancelled/notReady');
});

// ── 8. 取消与通道不可用的语义 ─────────────────────────────────────────────
check('取消产生 CANCELLED 而不是 FAILED', () => {
  assert.ok(/LatencyState\.CANCELLED/.test(engineCode), 'engine must publish CANCELLED state');
  assert.ok(/CANCELLED/.test(state), 'LatencyState must define CANCELLED');
});
check('通道不可用作废整批而不是盖章成超时', () => {
  assert.ok(/coreUnavailable/.test(engineCode), 'engine must flag coreUnavailable');
  assert.ok(/CORE_NOT_READY_ABORT_STREAK/.test(engineCode), 'engine must abort after a not-ready streak');
  const idx = engineCode.indexOf('latency batch aborted');
  assert.ok(idx > 0, 'abort must be logged');
  const body = engineCode.slice(Math.max(0, idx - 500), idx + 300);
  assert.ok(!/LatencyRecord\.failed/.test(body),
    'a not-ready core must not produce failure records');
});
check('中途失联先自愈一次，再决定作废（内核重启是可恢复的）', () => {
  assert.ok(/tryRecoverChannel/.test(engineCode), 'engine must attempt channel recovery');
  assert.ok(/refreshLatencyEndpoint/.test(orchCode),
    'orchestrator must expose refreshLatencyEndpoint');
  assert.ok(/channelRecoveryTried/.test(engineCode),
    'recovery must be attempted at most once per batch');
});
check('本机 controller 的传输层异常一律不算节点结论', () => {
  const apiCode = codeOnly(api);
  const idx = apiCode.indexOf('classifyTransportError');
  assert.ok(idx > 0, 'classifyTransportError must exist');
  const body = apiCode.slice(idx, idx + 900);
  assert.ok(/CORE_NOT_READY/.test(body), 'transport errors must map to CORE_NOT_READY');
  assert.ok(!/return LatencyFailKind\.NETWORK_UNREACHABLE/.test(body),
    'a transport error must never become a node-level network failure');
});
check('离线通道跳过环回/内网地址（≈2ms 毫无意义）', () => {
  assert.ok(/isLoopbackOrLocal/.test(state), 'LatencyPolicy must expose isLoopbackOrLocal');
  assert.ok(/isLoopbackOrLocal/.test(engineCode), 'offline probe must skip local addresses');
});
check('取消会释放客户端在途请求（内核仍会跑完，但 UI 必须能停）', () => {
  assert.ok(/cancelInflight\(\)/.test(engineCode), 'cancel must call cancelInflight');
});
check('引擎注释说明了"取消不释放内核 socket"这一事实', () => {
  assert.ok(/context\.Background\(\)/.test(engine), 'must document the context.Background() caveat');
});
check('进度在批次结束后一定收敛（不会永远转圈）', () => {
  assert.ok(/this\.finished = true/.test(engineCode), 'run() must finalize progress');
  assert.ok(/this\.progress\.running = false/.test(engineCode), 'progress.running must end false');
});

// ── 9. 组条目与内建项过滤 ─────────────────────────────────────────────────
check('isTestableType 排除全部组类型', () => {
  for (const t of ['Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay']) {
    assert.ok(new RegExp(`'${t}'`).test(state), `isTestableType must exclude ${t}`);
  }
});
check('isTestableType 排除内建出站', () => {
  for (const t of ['Direct', 'Reject', 'RejectDrop', 'Compatible', 'Pass', 'Dns']) {
    assert.ok(new RegExp(`'${t}'`).test(state), `isTestableType must exclude ${t}`);
  }
});
check('testableProxyNames 逐项过滤组与内建项', () => {
  const body = codeOnly(api).slice(codeOnly(api).indexOf('testableProxyNames'));
  assert.ok(/isTestableType/.test(body) && /isBuiltinNode/.test(body),
    'the node-list fetch must filter groups and builtins');
});
check('页面展示的排序/徽标能表达五态以上（不需要靠猜测）', () => {
  assert.ok(/recordFor\(/.test(pageCode), 'page must read the full record, not just a number');
  assert.ok(/recordText\(/.test(pageCode) && /recordColor\(/.test(pageCode),
    'page must render via LatencyStyle.recordText/recordColor');
  assert.ok(/LatencyState\.TESTING/.test(pageCode), 'page must render a distinct testing state');
});
check('UI 层把离线粗略值与真实延迟区分开（≈ 前缀）', () => {
  const idx = tokens.indexOf('recordText');
  assert.ok(idx > 0, 'LatencyStyle.recordText must exist');
  const body = tokens.slice(idx, idx + 1400);
  assert.ok(body.includes('≈'), 'offline values must be prefixed to avoid being read as proxy latency');
  assert.ok(/isStale/.test(body), 'stale results must be marked');
});
check('五态文案/配色是被"真跑"验证的，不是只 grep 源码', () => {
  // recordText/recordColor 是"五态可区分"的全部实现。只 grep 关键字无法发现
  // 语义回归（例如把 UNTESTED 又画成"超时"），必须真实执行。
  const cache = fs.readFileSync(rel('scripts/verify-latency-cache.mjs'), 'utf8');
  assert.ok(/UiTokens/.test(cache), 'cache suite must stage UiTokens');
  assert.ok(/LatencyStyle\b/.test(cache) && /await import\(/.test(cache),
    'must import and execute LatencyStyle');
  for (const probe of ['recordText', 'recordColor', 'text(', 'color(']) {
    assert.ok(cache.includes(probe), `must execute ${probe}`);
  }
  assert.ok(/Set\(texts\)\.size/.test(cache),
    'must assert the five states render pairwise-distinct text');
});
check('引擎本身是被"真跑"验证的（不是只读源码）', () => {
  // LatencyEngine 是本次重做的核心（唯一入口 / 并发池 / 硬截止 / 取消 /
  // 通道分类 / TESTING 收尾）。源码断言只能证明这些字符串还在，
  // 证明不了 worker 池、取消、自愈、硬截止真的按预期跑。
  const rt = fs.readFileSync(rel('scripts/verify-latency-engine-runtime.mjs'), 'utf8');
  assert.ok(/LatencyEngine\.start\(/.test(rt), 'runtime suite must actually start the engine');
  assert.ok(/await import\(/.test(rt) && /LatencyEngine\.ts/.test(rt),
    'runtime suite must stage and import LatencyEngine');
  for (const probe of ['cancelCurrent', '_inflight', 'coreUnavailable', 'maxInflight']) {
    assert.ok(rt.includes(probe), `runtime suite must drive ${probe}`);
  }
  assert.ok(/LATENCY_CONCURRENCY/.test(rt) && /BATCH_DEADLINE_MS/.test(rt),
    'concurrency and deadline must be asserted against the real exported constants');
  assert.ok(/LatencyState\.TESTING/.test(rt), 'must assert no leftover TESTING');
  assert.ok(rt.length > 8000, 'must be a substantive behavioural suite');
});
check('deadline 常量必须导出（否则只能读源码断言，无法真跑）', () => {
  assert.ok(/export const BATCH_DEADLINE_MS/.test(engine), 'BATCH_DEADLINE_MS must be exported');
  assert.ok(/export const LATENCY_CONCURRENCY/.test(engine), 'LATENCY_CONCURRENCY must be exported');
});

// ── 10. 内核回收的安全闸 ──────────────────────────────────────────────────
check('延迟回收测速内核时必须避开用户正在用 VPN 的状态', () => {
  const idx = orchCode.indexOf('scheduleTestCoreRecycle');
  const body = orchCode.slice(idx, idx + 900);
  for (const st of ['ConnState.CONNECTED', 'ConnState.CONNECTING', 'ConnState.DISCONNECTING',
    'ConnState.RECOVERING']) {
    assert.ok(body.includes(st), `recycle must bail out when state is ${st}`);
  }
  assert.ok(/return;/.test(body), 'recycle must return early in those states');
});
check('引擎只在真的用了内核通道时才挂回收', () => {
  assert.ok(/if \(this\.api !== null\) \{\s*ConnectionOrchestrator\.instance\(\)\.scheduleTestCoreRecycle/.test(engineCode),
    'idle recycle must be conditional on a core channel');
});

// ── 10b. 引擎自己收回 TESTING 标记（不依赖调用方） ───────────────────────
// 真机/代码审计发现：被取消、被抢占、被通道故障作废的节点不会拿到任何记录，
// 若没人清理就永远停在 TESTING —— UI 行上是一个永不停止的转圈。
// 旧实现把这件事交给每个调用方（页面有 clearTestingMarks，后台路径没有）。
check('引擎在所有退出路径上自己收回 TESTING 标记', () => {
  assert.ok(/clearOwnTestingMarks/.test(engineCode), 'engine must own the cleanup');
  const body = engineCode.slice(engineCode.indexOf('private clearOwnTestingMarks'));
  assert.ok(/isTestingOwnedBy\(node\.name, this\.runId\)/.test(body), 'must target only rows TESTING-owned by this run');
  assert.ok(/LatencyRecord\.untested\(node\.name\)/.test(body), 'TESTING -> untested (never a verdict)');
  // worker 抛异常也必须收尾
  const run = engineCode.slice(engineCode.indexOf('async run(): Promise<LatencyProgress>'));
  assert.ok(/finally\s*\{\s*this\.clearOwnTestingMarks\(\)/.test(run),
    'cleanup must run in a finally so a throwing worker cannot leak TESTING');
  // 收尾必须早于 finished=true，否则 isRunning() 提前为假、清理还没做完
  assert.ok(run.indexOf('clearOwnTestingMarks') < run.indexOf('this.finished = true'),
    'cleanup must precede finished=true');
});
check('清理是幂等的，且页面只作纵深防御（不产生第二套语义）', () => {
  assert.ok(/clearTestingMarks/.test(pageCode), 'page keeps a defensive cleanup');
  // 注释在 codeOnly() 里会被剥掉，所以这里查原始源码
  assert.ok(/clearOwnTestingMarks/.test(page),
    'page comment must name the engine as the owner of the cleanup');
  // 页面不得自己发明第二套"取消/失败"语义：只允许把 TESTING 收回未测
  const body = pageCode.slice(pageCode.indexOf('private clearTestingMarks'));
  assert.ok(!/LatencyRecord\.failed/.test(body.slice(0, 600)),
    'page cleanup must not stamp failures');
});

// ── 10c. 「可排序 / 可持久化」必须有真实行为覆盖 ──────────────────────────
// 本次审计发现：NodeSortSnapshot 是排序+持久化的全部实现，但在重做前
// **没有任何套件覆盖它**（grep 所有 verify 脚本命中为 0）。
check('排序/持久化有专门的真实行为套件，且确实在跑它', () => {
  const suite = path.join(__dirname, 'verify-node-sort-persistence.mjs');
  assert.ok(fs.existsSync(suite),
    'scripts/verify-node-sort-persistence.mjs must exist (sort + persistence are in scope)');
  const src = fs.readFileSync(suite, 'utf8');
  // 必须是真驱动，不是读源码断言
  assert.ok(/await import\(/.test(src), 'must actually import and execute the module');
  assert.ok(/NodeSortSnapshot\.buildAuto/.test(src), 'must exercise buildAuto');
  assert.ok(/orderedNames/.test(src), 'must exercise the ordering');
  assert.ok(/fromJsonText|toJsonText/.test(src), 'must exercise persistence round-trip');
  // 桩常量不许硬编码：必须从真实源码抽取，否则会与实现漂移
  assert.ok(/ClashApiService\.ets/.test(src) && /matchAll/.test(src),
    'stub constants must be extracted from the real source, not hardcoded');
});
check('排序语义与页面的落盘口径一致（只有真结论才参与排序）', () => {
  assert.ok(/NodeSortSnapshot\.buildAuto/.test(pageCode), 'page persists via buildAuto');
  assert.ok(/PORT_ONLY|LatencyFailKind\.PORT_ONLY/.test(pageCode),
    'OFFLINE (port-only) must be marked non-verdict when persisting');
  assert.ok(/UNTESTED/.test(pageCode), 'untested must be marked non-verdict');
});

// ── 11. 生成器未被本次重做改动 ───────────────────────────────────────────
check('ClashConfigGenerator 逻辑内容指纹未变（忽略 CRLF/LF 行尾差异）', () => {
  const gen = fs.readFileSync(rel(svc + 'ClashConfigGenerator.ets'), 'utf8').replace(/\r\n/g, '\n');
  const hash = crypto.createHash('sha256').update(gen, 'utf8').digest('hex').slice(0, 16);
  // 记录当前指纹：本次延迟重做不应改动配置生成器（避免牵连隧道行为）
  const expected = require('./latency-gen-fingerprint.json').sha256_16;
  assert.strictEqual(hash, expected,
    `ClashConfigGenerator changed (${hash} != ${expected}); if intentional, update latency-gen-fingerprint.json`);
});
check('生成器开启 unified-delay（FlClash 口径：报第二次 HEAD 的耗时 = 真实 RTT）', () => {
  const gen = fs.readFileSync(rel(svc + 'ClashConfigGenerator.ets'), 'utf8');
  // mihomo adapter/adapter.go:259-274：unified=true 时复用同一 Transport 再发一次 HEAD，
  // 并把 start 重置为第二次 ⇒ 报的是**已建立连接**上的第二个 HEAD 耗时（少付 TLS 握手）。
  // unified=false 则把 TLS 握手算进延迟，每次测速凭空多 1~2 个 RTT（真机实测 +50~1000ms）。
  assert.ok(/unified-delay: true/.test(gen), 'unified-delay must be enabled (FlClash parity: report the 2nd HEAD)');
  assert.ok(!/unified-delay: false/.test(gen), 'unified-delay must not be disabled (it charges TLS handshake to the delay)');
});

// ── 12. 文档 ──────────────────────────────────────────────────────────────
check('存在设备实测的 delay API 契约文档', () => {
  assert.ok(fs.existsSync(rel('docs/mihomo-delay-api-contract.md')),
    'docs/mihomo-delay-api-contract.md must exist (device-verified contract)');
});
check('存在延迟测试重做设计文档', () => {
  assert.ok(fs.existsSync(rel('docs/latency-redesign.md')),
    'docs/latency-redesign.md must exist');
});

console.log(`\n${passed}/${passed + failures.length} passed, ${failures.length} failed`);
if (failures.length > 0) {
  console.log('\nFailures:');
  for (const f of failures) {
    console.log('  - ' + f);
  }
  process.exitCode = 1;
}
