#!/usr/bin/env node
/**
 * node tools/verify-config-sanitize.mjs (Node 24+)
 * 背景（用户真机 2026-09-18）：mihomo yaml.v3 对 C0 控制符(除\t\n\r)、0x7F-0x84、
 * 0x86-0x9F 报 "control characters are not allowed"，整份配置拒载 → 内核启动失败。
 * EXEC: 真实 sanitizeControlChars / friendlyVpnStartError 源码执行。
 * SOURCE: 三个净化出口 + 友好错误映射的接线断言。
 */
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const read = p => readFileSync(resolve(root, p), 'utf8');
let passed = 0; let failed = 0;
const check = async (name, fn) => {
  try { await fn(); passed++; console.log('PASS ' + name); }
  catch (e) { failed++; console.log('FAIL ' + name + ' -> ' + e.message); }
};

const gen = read('entry/src/main/ets/commons/services/ClashConfigGenerator.ets');
const pol = read('entry/src/main/ets/commons/services/VpnRecoveryPolicy.ets');
const ext = read('entry/src/main/ets/vpnability/VpnExtensionAbility.ets');

const grab = (source, startMark, label, endMark = '\n  }') => {
  const start = source.indexOf(startMark);
  assert.ok(start >= 0, 'extract ' + label);
  const end = source.indexOf(endMark, start);
  assert.ok(end > start, 'close of ' + label);
  return source.slice(start, end + endMark.length);
};

// EXEC sanitizeControlChars
const sanitizeSrc = stripTypeScriptTypes(
  'const ClashConfigGenerator = { ' + grab(gen, 'static sanitizeControlChars(value: string): string {', 'sanitize').replace(/^static /, '') + ' };',
  { mode: 'strip' });
const sanitizeMod = { exports: {} };
new Function('exports', sanitizeSrc + '\nexports.sanitize = ClashConfigGenerator.sanitizeControlChars;')(sanitizeMod.exports);
const sanitize = sanitizeMod.exports.sanitize;

// EXEC friendlyVpnStartError
const friendlySrc = stripTypeScriptTypes(
  grab(pol, 'export function friendlyVpnStartError', 'friendly', '\n}').replace(/^export /, ''),
  { mode: 'strip' });
const friendlyMod = { exports: {} };
new Function('exports', friendlySrc + '\nexports.friendly = friendlyVpnStartError;')(friendlyMod.exports);
const friendly = friendlyMod.exports.friendly;

const FORBIDDEN = [];
for (let c = 0; c <= 0x1f; c++) if (c !== 0x09 && c !== 0x0a && c !== 0x0d) FORBIDDEN.push(c);
for (let c = 0x7f; c <= 0x84; c++) FORBIDDEN.push(c);
for (let c = 0x86; c <= 0x9f; c++) FORBIDDEN.push(c);

await check(`EXEC sanitize removes all ${FORBIDDEN.length} yaml-illegal codepoints`, () => {
  for (const code of FORBIDDEN) {
    const ch = String.fromCharCode(code);
    const out = sanitize('a' + ch + 'b');
    assert.ok(!out.includes(ch), 'leaked 0x' + code.toString(16));
    assert.equal(out.length, 3);
  }
});
await check('EXEC sanitize preserves legal yaml text incl. cjk/emoji/newlines', () => {
  const keep = '香港节点 01 🚀 path:/a?ed=2048\nkey: "v"';
  assert.equal(sanitize(keep), keep);
});
await check('EXEC sanitize maps tab/CR to space (never raw)', () => {
  const out = sanitize('x\ty\rz');
  assert.equal(out, 'x y z');
});
await check('EXEC friendly maps create() conflict codes', () => {
  assert.match(friendly(2203002, 'x'), /另一个 VPN/);
  assert.match(friendly(2203001, 'x'), /拒绝了/);
  assert.match(friendly(2200002, 'x'), /网络服务/);
  assert.match(friendly(2200001, 'x'), /参数/);
  assert.equal(friendly(-1, 'boom'), 'VPN 扩展启动异常: boom');
});

await check('SOURCE generator final return is sanitized (last-resort gate)', () => {
  assert.match(gen, /return ClashConfigGenerator\.sanitizeControlChars\(lines\.join\('\\n'\)/);
});
await check('SOURCE both verbatim embed sites sanitized (wsExtras raw + rawTemplate)', () => {
  assert.match(gen, /out\.push\(\[sub, ClashConfigGenerator\.sanitizeControlChars\(value\)\]\)/);
  assert.match(gen, /rawParts: string\[\] = \[`name: \$\{q\(n\.name\)\}`, ClashConfigGenerator\.sanitizeControlChars\(n\.rawTemplate\)\]/);
});
await check('SOURCE extension uses friendly mapping with code extraction', () => {
  assert.ok(ext.includes('friendlyVpnStartError(code, msg)'), 'friendly call');
  assert.ok(ext.includes('typeof err.code'), 'code extraction');
});

// ── 2026-09-18 真机三报错修复的回归断言 ────────────────────────────────
await check('EXEC friendly maps kernel parse failures & empty/[object Object] text', () => {
  assert.match(friendly(-1, 'parse config :proxy "12": has unset fields:password'), /凭据|刷新订阅/);
  assert.match(friendly(-1, 'parse config: yaml: control characters are not allowed'), /控制字符|刷新订阅/);
  assert.match(friendly(-1, ''), /无详细信息/);
  assert.match(friendly(-1, '[object Object]'), /无详细信息/);
  assert.equal(friendly(-1, 'boom'), 'VPN 扩展启动异常: boom');
});

await check('EXEC friendly maps remaining official VPN error codes (2200003/2203004/1990000x)', () => {
  assert.match(friendly(2200003, 'x'), /内部错误/);
  assert.match(friendly(2203004, 'x'), /描述符/);
  assert.match(friendly(19900001, 'x'), /参数/);
  assert.match(friendly(19900002, 'x'), /提单|重试/);
});

await check('SOURCE ensureConfigMtu rewrites via fresh TRUNC fd (no NUL-hole read-modify-write)', () => {
  const fn = grab(ext, 'private ensureConfigMtu(): void {', 'ensureConfigMtu');
  assert.ok(!fn.includes('truncateSync'), 'shared-fd truncate+write is the bug (POSIX keeps offset)');
  assert.match(fn, /fs\.OpenMode\.READ_WRITE \| fs\.OpenMode\.CREATE \| fs\.OpenMode\.TRUNC/, 'fresh trunc fd rewrite');
});

await check('SOURCE provider raw subscription sanitized before persisting', () => {
  const raw = read('entry/src/main/ets/commons/services/RawSubscriptionStore.ets');
  // 清洗必须发生在**落盘前**（2026-10-20 起写入改为「临时文件 + rename」的原子写，
  // 所以断言点从 writePrivate(path, ...) 改成清洗产物的使用处）
  assert.match(raw, /const cleaned = RawSubscriptionStore\.stripControlChars\(content\)/,
    'provider 原文必须先清洗再落盘');
  assert.match(raw, /privateFs\.writePrivate\(tmp, payload\)/,
    '原子写：先写临时文件（payload = 清洗+校验后的内容）');
  assert.match(raw, /fs\.renameSync\(tmp, path\)/,
    '原子写：同目录 rename 覆盖（旧文件在失败时原封不动）');
  // 与生成器规则逐字一致（同一 keep-map）
  const copy = grab(raw, 'private static stripControlChars(value: string): string {', 'stripCopy');
  const genBody = grab(gen, 'static sanitizeControlChars(value: string): string {', 'sanitize');
  const norm = s => s.replace(/stripControlChars|sanitizeControlChars/g, 'FN').replace(/\s+/g, ' ');
  assert.ok(norm(copy).includes(norm(genBody).slice(norm(genBody).indexOf('{'))), 'rule drift between copies');
});

await check('SOURCE dropReasonFor gates relay protocols that require credentials', () => {
  assert.match(gen, /proxyType === 'tuic'[\s\S]{0,120}MISSING_CREDENTIAL/);
  assert.match(gen, /proxyType === 'hysteria'[\s\S]{0,220}MISSING_CREDENTIAL/);
  assert.match(gen, /proxyType === 'anytls'[\s\S]{0,80}MISSING_CREDENTIAL/);
});

await check('SOURCE no Error-instanceof error-text residues anywhere in app sources', () => {
  const offenders = [];
  const walk = dir => {
    for (const entry of readdirSync(resolve(root, dir), { withFileTypes: true })) {
      const rel = dir + '/' + entry.name;
      if (entry.isDirectory()) {
        if (!entry.name.startsWith('.')) { walk(rel); }
        continue;
      }
      if (!entry.name.endsWith('.ets')) { continue; }
      if (read(rel).includes('instanceof ' + 'Error')) { offenders.push(rel); }
    }
  };
  walk('entry/src/main/ets');
  assert.deepEqual(offenders, [],
    'Error-instanceof residues (use AppLogger.errText or a BusinessError-aware local helper): ' + offenders.join(', '));
  const logger = read('entry/src/main/ets/commons/utils/AppLogger.ets');
  assert.match(logger, /static errText\(e: Object\): string/);
});

// ── 2026-09-19 新装首连 want 丢参被分流门禁误杀的修复断言 ──────────────
const orch = read('entry/src/main/ets/commons/services/ConnectionOrchestrator.ets');
const rfp = read('entry/src/main/ets/commons/services/RuntimeFilePolicy.ets');
const cb = read('entry/src/main/ets/core/CoreBridge.ets');

await check('EXEC friendly maps app-routing param-loss to actionable text', () => {
  assert.match(friendly(-1, '应用分流参数缺失或冲突，已拒绝恢复 VPN，请在应用内重新连接'), /路由参数|再点一次/);
});

await check('SOURCE extension gate falls back to params snapshot (path-bound + fresh), still rejects otherwise', () => {
  const fb = grab(ext, 'private readStartParamsFallback(configPath: string): StartParamsSnapshot | null {', 'fallback');
  assert.match(fb, /filePath !== configPath/, 'snapshot must bind to this launch configPath');
  assert.match(fb, /START_PARAMS_MAX_AGE_MS/, 'freshness gate');
  assert.ok(!fb.includes('fromTransport'), 'fallback itself never guesses routing');
  assert.match(ext, /readStartParamsFallback\(configPath\)[\s\S]{0,240}throw new Error\('应用分流参数缺失或冲突/,
    'reject only after fallback miss');
});

await check('SOURCE orchestrator snapshots params pre-launch, retries launch once, skips node penalty', () => {
  const w = grab(orch, 'private writeStartParamsFile(', 'writeStartParamsFile');
  assert.match(w, /writePrivate\(`\$\{this\.context\.cacheDir\}\/\$\{START_PARAMS_FILE\}`/, '0600 write');
  assert.match(w, /rec\.ts = Date\.now\(\)/, 'freshness stamp');
  const wPos = orch.indexOf('this.writeStartParamsFile(configPath, appRouting.mode');
  // 测速路径也有同名 start(want)，必须从本次快照位置向后找隧道拉起
  const sPos = orch.indexOf('vpnExtension.startVpnExtensionAbility(want)', wPos);
  assert.ok(wPos > 0 && sPos > wPos, 'snapshot written before launch');
  assert.match(orch, /应用分流参数缺失或冲突'\) >= 0 && !launchRetryDone/, 'one silent stop→start retry');
  assert.match(orch, /errorMessage\.indexOf\('应用分流参数缺失或冲突'\) < 0[\s\S]{0,160}recordNodeFailure/,
    'param-loss never penalizes node');
});

await check('SOURCE launch-epoch handshake proves start delivery (swallow detection)', () => {
  assert.match(ext, /vpn onCreate'\);\s*\n\s*this\.writeLaunchEpoch\(\)/, 'epoch written first thing in onCreate');
  assert.match(ext, /const LAUNCH_EPOCH_FILE = 'vpn_launch_epoch.txt'/);
  assert.match(orch, /const launchFloorTs = Date\.now\(\);[\s\S]{0,120}startVpnExtensionAbility\(want\)/,
    'floor captured before launch');
  assert.match(orch, /await this\.awaitLaunchEpoch\(launchFloorTs\)/, 'first confirmation');
  assert.match(orch, /await this\.awaitLaunchEpoch\(retryFloorTs\)/, 're-launch confirmation');
  assert.match(orch, /VPN 扩展进程未接收本次拉起/, 'distinct actionable error');
  assert.match(rfp, /TUNNEL_STATE_FILES[\s\S]{0,400}vpn_launch_epoch\.txt/, 'cleared with tunnel lifecycle');
  const clr = grab(ext, 'private clearStartError(configPath: string): void {', 'extClear');
  assert.ok(!clr.includes('LAUNCH_EPOCH_FILE'), 'ext onCreate cleanup must not delete the epoch it just wrote');
});

await check('SOURCE snapshot file name agrees across processes and clears with tunnel lifecycle', () => {
  const name = "'vpn_start_params.json'";
  assert.ok(ext.includes(name), 'extension const');
  assert.ok(orch.includes(name), 'orchestrator const');
  assert.match(rfp, /TUNNEL_STATE_FILES[\s\S]{0,320}vpn_start_params\.json/, 'disconnect cleanup list');
});

// ── 5.5.7：内核启动期"联网下载"阻塞（全新安装 ruleset 缺失） ────────────────
// 真机实证 2026-09-19：rule-providers 是 type: http，本地 path 文件缺失时 mihomo 会在
// TunBoxStart() 内同步拉取远端并阻塞（不返回、不报错）→ 扩展静默、UI 30s 超时。
await check('SOURCE generator gates http rule-provider on local file readiness', () => {
  assert.match(gen, /ruleProviderReady: boolean = true/, 'opt-in param with safe default');
  // provider 声明与 RULE-SET 引用必须同受该开关约束，否则仍会引用未声明的 provider
  // （2026-10-16 起声明段为单一合并段：hyper-adrules 条目在去重后、声明头前追加）
  const decl = gen.indexOf("finalProviderLines.push('  hyper-adrules:')");
  const ref = gen.indexOf('RULE-SET,hyper-adrules,REJECT');
  const header = gen.indexOf("lines.push('rule-providers:')") ;
  assert.ok(decl > 0 && ref > 0 && header > decl, 'both sites present');
  assert.match(gen.slice(Math.max(0, decl - 260), decl), /hyperAdRulesEnabled && ruleProviderReady/,
    'provider declaration gated');
  assert.match(gen.slice(Math.max(0, ref - 200), ref), /hyperAdRulesEnabled && ruleProviderReady/,
    'RULE-SET reference gated identically');
});

await check('SOURCE orchestrator checks rule-provider file and degrades on all three generate paths', () => {
  assert.match(orch, /const RULESET_SUBDIR = 'ruleset'/);
  assert.match(orch, /const HYPER_AD_RULES_FILE = 'hyper_adrules_ads\.mrs'/);
  const ready = grab(orch, 'private isRuleProviderReady(): boolean {', 'ruleReady');
  assert.match(ready, /statSync\(p\)\.size > 0/, 'existence+non-empty check');
  assert.match(ready, /return false/, 'missing file degrades');
  // 三条生成路径（隧道 / 测速核 / 规则热重载）都必须传该标志
  const calls = orch.split('ClashConfigGenerator.generate(').length - 1;
  const withFlag = orch.split('ruleProviderReady)').length - 1 + orch.split('this.isRuleProviderReady())').length - 1;
  assert.ok(calls >= 3, `expected >=3 generate call sites, got ${calls}`);
  assert.equal(withFlag, calls, 'every generate call site passes the readiness flag');
});

await check('SOURCE orchestrator backgrounds the missing ruleset download (never in core start path)', () => {
  // 2026-09 下载器重构：等待型 downloadRuleProviderAsset（共享 downloadAsset 写盘）
  // + fire-and-forget downloadRuleProviderInBackground 包装（镜像表升级为带来源标签的
  // AssetMirror[]，按用户偏好重排）。断言随结构迁移，语义不变：有镜像表、拒绝错误页、
  // 原子覆盖写盘、后台触发。
  const dl = grab(orch, 'private async downloadRuleProviderAsset(source: string): Promise<boolean> {',
    'downloadRuleProviderInBackground(source');
  assert.match(dl, /HYPER_AD_RULES_MIRRORS/, 'mirror list');
  assert.match(dl, /byteLength > 1024/, 'reject tiny error pages');
  const shared = grab(orch, 'private async downloadAsset(', 'private async downloadGeoipAsset');
  assert.match(shared, /OpenMode\.TRUNC/, 'atomic overwrite');
  assert.match(orch, /missing; generate config without RULE-SET'\);\s*\n\s*\/\/[^\n]*\n\s*this\.downloadRuleProviderInBackground\(settings\.assetSource\)/,
    'kick off prefetch right after degrading');
  // 下载必须只在 UI 进程后台发生：扩展进程内不得出现该下载器（否则又回到启动路径阻塞）
  assert.ok(!ext.includes('downloadRuleProviderInBackground'), 'extension must not run the downloader');
});

await check('SOURCE core start is wrapped in a hard timeout that reports actionable text', () => {
  assert.match(ext, /const CORE_START_TIMEOUT_MS = \d+/, 'timeout constant');
  assert.match(ext, /private async runStage\(label: string, stage: Promise<boolean>, timeoutMs: number\): Promise<StageOutcome>/);
  const so = grab(ext, 'class StageOutcome {', 'stageOutcome');
  assert.match(so, /timedOut: boolean = false/, 'distinguishes hang from failure');
  assert.match(ext, /startCoreWithTimeout\(configPath\)/, 'tunnel path uses the wrapper');
  assert.match(ext, /runStage\('headless startCore'/, 'headless path uses the wrapper');
  assert.match(ext, /内核启动超时（20s 无响应）/, 'actionable tunnel error');
  assert.match(ext, /测速内核启动超时/, 'actionable headless error');
  assert.match(pol, /内核启动超时'\) >= 0 \|\| rawMessage\.indexOf\('测速内核启动超时'\) >= 0/,
    'friendly mapping for both');
  assert.match(orch, /errorMessage\.indexOf\('内核启动超时'\) < 0[\s\S]{0,200}recordNodeFailure/,
    'infra hang must not penalize the node');
});

await check('SOURCE stopCore bounds its wait so a blocked start cannot freeze cleanup', () => {
  assert.match(cb, /const STOP_WAIT_MS = \d+/, 'bounded wait constant');
  const stop = grab(cb, 'async stopCore(): Promise<void> {', 'stopCore');
  assert.match(stop, /Promise\.race\(/, 'races the pending start against a timer');
  assert.match(stop, /native\.stopCore\(\)/, 'native rollback still runs after timeout');
});

// ── 5.6.0：零节点首连硬门禁 ───────────────────────────────────────────────
// 真机/用户实证 2026-09-19：全新安装时 "loaded 1 subscriptions, 0 nodes"，
// 点连接 → 1861 字节空壳配置 → 内核 20s 无响应（CORE_START_TIMEOUT_MS 命中）
// → 报"卡在联网下载，请等 10 秒后再点一次"，把用户引向完全无关的方向。
// 见 docs/first-connect-empty-nodes-rootcause.md。
await check('SOURCE connect refuses to launch the tunnel when there are zero nodes', () => {
  const body = grab(orch, 'async connect(node: ProxyNode, subs: SubscriptionService): Promise<boolean> {', 'connectBody');
  const guardAt = body.indexOf('subs.nodes.length === 0');
  assert.ok(guardAt > 0, 'connect must guard the zero-node case');
  // 门禁必须发生在写配置/拉起扩展之前
  const launchAt = body.indexOf('startVpnExtensionAbility');
  assert.ok(launchAt < 0 || guardAt < launchAt, 'guard must precede the extension launch');
  assert.match(body.slice(guardAt, guardAt + 900), /return false/,
    'zero nodes must bail out instead of proceeding');
  assert.match(body.slice(guardAt, guardAt + 900), /没有可用节点/,
    'error must be actionable and distinct from the 联网下载 misdiagnosis');
  // 不许把零节点算成节点故障
  assert.ok(!/recordNodeFailure/.test(body.slice(guardAt, guardAt + 900)),
    'a missing subscription is not a node failure');
});

await check('SOURCE zero-node connect auto-refreshes once, and the UI explains it', () => {
  assert.match(orch, /zeroNodeAutoRefreshDone/, 'auto-refresh must be latched to one attempt');
  const helper = grab(orch, 'private async autoRefreshForZeroNodes(subs: SubscriptionService): Promise<void> {', 'zeroRefresh');
  assert.match(helper, /refreshSubscription\(s\.id\)/, 'must actually refresh the subscription');
  assert.match(helper, /s\.enabled/, 'only enabled subscriptions');
  // 友好文案必须排在"内核启动超时"分支之前，否则又会被误判成联网下载
  const friendly = pol.indexOf('没有可用节点');
  const timeoutBranch = pol.indexOf("rawMessage.indexOf('内核启动超时') >= 0");
  assert.ok(friendly > 0, 'policy must map the zero-node error');
  assert.ok(friendly < timeoutBranch, 'zero-node branch must precede the core-timeout branch');
});

console.log(`\nConfig-sanitize verification: ${passed} passed, ${failed} failed (EXEC real functions; no device).`);
if (failed > 0) process.exitCode = 1;
