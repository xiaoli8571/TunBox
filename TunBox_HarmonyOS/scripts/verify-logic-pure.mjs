#!/usr/bin/env node
/**
 * 离线纯逻辑校验脚本（第二阶段：NetworkStateWatcher / LinkHealthChecker / SmartSelector）
 *
 * 为什么需要它:
 *   本工程 build-profile.json5 的 signingConfigs 为空（构建日志明确输出
 *   "No signingConfig found for product default"），因此产物是未签名 HAP，
 *   无法 hdc install，也就无法在真机上执行 @ohos/hypium 用例。
 *   为让「纯逻辑」有真实可复现的证据，本脚本用 Node 24 的原生 TypeScript
 *   （type stripping，无需 tsc）**直接加载三个 .ets 源文件本体**，
 *   只把无法在 Node 运行的 SDK import 换成最小垫片（不在垫片里重写任何被测规则），
 *   然后对真实导出的纯函数逐分支断言。
 *
 * 它验证的是什么（哪里可能失效就覆盖哪里）:
 *   1. normalizeNetType：无默认网 / 空 bearer / wifi / ethernet / cellular /
 *      蓝牙 / VPN-only 及多 bearer 优先级
 *   2. shouldEmit：无变化 / 无历史 / 去抖关闭 / 时钟回拨 / 窗口内 / 窗口边界
 *   3. NetworkStateWatcher：去抖抑制与放行、generation 严格单调递增、
 *      监听者抛异常被隔离、stop 后监听者清空、非法去抖值回退
 *   4. LinkHealthChecker.summarize：全过=ok / 单项失败=broken+首要失败项 /
 *      全失败 / 空报告=degraded / 仅跳过=degraded
 *   5. LinkHealthChecker.repairSteps：有限（<=N）、有序（报告顺序）、去重、
 *      空报告/全过=无动作
 *   6. LinkHealthChecker.run：单点挂死（永不 settle）只让自己超时失败、
 *      单点抛异常只让自己失败、其余照常；总耗时上限截断为 skip 而非 fail
 *   7. SmartSelector：scoreOf 精确评分、排序确定性（同分按下标）、
 *      冷却/阈值下的 isEligible、failoverAllowed（阈值+冷却+防抖）、
 *      nextBestNode（首次选择/迟滞/失效立即切/禁用/无候选）、
 *      markSuccess/markFailure 纯状态迁移（入参不被修改）与参数夹取
 *
 * 用法: node scripts/verify-logic-pure.mjs
 * 退出码: 0 = 全部断言通过；1 = 有断言失败或加载失败
 */
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';

const here = dirname(fileURLToPath(import.meta.url));
const appRoot = resolve(here, '..');
const svcDir = join(appRoot, 'entry', 'src', 'main', 'ets', 'commons', 'services');

// ── 极简断言器（与 Hypium 语义一致的关键方法）──────────────────────────
let passed = 0;
const failures = [];
const notes = [];

function record(label, okFlag, detail) {
  if (okFlag) {
    passed = passed + 1;
  } else {
    failures.push(label + (detail ? ' -> ' + detail : ''));
  }
}
function eq(label, actual, expected) {
  record(label, Object.is(actual, expected), 'expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
}
function ok(label, cond) {
  record(label, cond === true, 'expected true, got ' + JSON.stringify(cond));
}
function near(label, actual, expected, eps = 1e-9) {
  record(label, Math.abs(actual - expected) <= eps, 'expected ~' + expected + ', got ' + actual);
}

// ── 生成加载沙箱：真实源码 + SDK 垫片 ─────────────────────────────────
const sandbox = join(tmpdir(), 'tunbox-logic-verify-' + process.pid);
rmSync(sandbox, { recursive: true, force: true });
mkdirSync(sandbox, { recursive: true });
writeFileSync(join(sandbox, 'package.json'), JSON.stringify({ type: 'module' }), 'utf8');

// 垫片只提供「能 import 成功」所需的符号；被测的纯函数一行都不在垫片里实现。
writeFileSync(join(sandbox, 'shim_networkkit.ts'), [
  '// 离线垫片：仅满足 import 解析；被测纯函数不依赖此对象',
  'export const connection = {',
  '  createNetConnection: () => { throw new Error("offline: no NetManager"); },',
  '  getDefaultNetSync: () => { throw new Error("offline: no NetManager"); },',
  '  getNetCapabilitiesSync: () => { throw new Error("offline: no NetManager"); },',
  '  NetBearType: { BEARER_CELLULAR: 0, BEARER_WIFI: 1, BEARER_BLUETOOTH: 2, BEARER_ETHERNET: 3, BEARER_VPN: 4 }',
  '};',
  'export const http = {};'
].join('\n'), 'utf8');
writeFileSync(join(sandbox, 'shim_basic.ts'),
  'export class BusinessError extends Error { code: number = 0; }\n', 'utf8');
writeFileSync(join(sandbox, 'shim_logger.ts'), [
  'export class AppLogger {',
  '  static info(_tag: string, _msg: string): void {}',
  '  static warn(_tag: string, _msg: string): void {}',
  '  static error(_tag: string, _msg: string): void {}',
  '  static errText(e: Object): string { return e === null || e === undefined ? \'unknown error\' : String(e); }',
  '}'
].join('\n'), 'utf8');

/** 把 .ets 源文件写成可在 Node 下加载的 .ts（仅改 import 路径） */
function stage(name) {
  const src = readFileSync(join(svcDir, name + '.ets'), 'utf8');
  const patched = src
    .replace(/from '@kit\.NetworkKit'/g, "from './shim_networkkit.ts'")
    .replace(/from '@kit\.BasicServicesKit'/g, "from './shim_basic.ts'")
    .replace(/from '\.\.\/utils\/AppLogger'/g, "from './shim_logger.ts'");
  const out = join(sandbox, name + '.ts');
  writeFileSync(out, patched, 'utf8');
  return out;
}

const netPath = stage('NetworkStateWatcher');
const healthPath = stage('LinkHealthChecker');
const selectPath = stage('SmartSelector');

const load = (p) => import(pathToFileURL(p).href);

let Net, Health, Select;
try {
  Net = await load(netPath);
  Health = await load(healthPath);
  Select = await load(selectPath);
} catch (e) {
  console.error('FATAL: 加载 .ets 源码失败: ' + (e && e.stack ? e.stack : e));
  process.exit(1);
}
notes.push('已加载真实源码文件: NetworkStateWatcher.ets / LinkHealthChecker.ets / SmartSelector.ets '
  + '（Node 24 原生 TS type-stripping，仅替换 SDK import 为垫片）');

// ══════════════════════════════════════════════════════════════════════
// 1. NetworkStateWatcher.normalizeNetType
// ══════════════════════════════════════════════════════════════════════
eq('net.bearer.cellular=0', Net.BEARER_CELLULAR, 0);
eq('net.bearer.wifi=1', Net.BEARER_WIFI, 1);
eq('net.bearer.bluetooth=2', Net.BEARER_BLUETOOTH, 2);
eq('net.bearer.ethernet=3', Net.BEARER_ETHERNET, 3);
eq('net.bearer.vpn=4', Net.BEARER_VPN, 4);
eq('net.debounce.default', Net.NET_DEBOUNCE_MS, 1500);

eq('normalize.noDefaultNet([])', Net.normalizeNetType([], false), Net.NetTypes.NONE);
eq('normalize.noDefaultNet([wifi])', Net.normalizeNetType([Net.BEARER_WIFI], false), Net.NetTypes.NONE);
eq('normalize.emptyBearers', Net.normalizeNetType([], true), Net.NetTypes.UNKNOWN);
eq('normalize.wifi', Net.normalizeNetType([Net.BEARER_WIFI], true), Net.NetTypes.WIFI);
eq('normalize.ethernet', Net.normalizeNetType([Net.BEARER_ETHERNET], true), Net.NetTypes.ETHERNET);
eq('normalize.cellular', Net.normalizeNetType([Net.BEARER_CELLULAR], true), Net.NetTypes.CELLULAR);
eq('normalize.bluetoothOnly', Net.normalizeNetType([Net.BEARER_BLUETOOTH], true), Net.NetTypes.UNKNOWN);
eq('normalize.vpnOnly', Net.normalizeNetType([Net.BEARER_VPN], true), Net.NetTypes.UNKNOWN);
eq('normalize.priority.cell+wifi', Net.normalizeNetType([Net.BEARER_CELLULAR, Net.BEARER_WIFI], true), Net.NetTypes.WIFI);
eq('normalize.priority.cell+eth', Net.normalizeNetType([Net.BEARER_CELLULAR, Net.BEARER_ETHERNET], true), Net.NetTypes.ETHERNET);
eq('normalize.priority.wifi+eth', Net.normalizeNetType([Net.BEARER_WIFI, Net.BEARER_ETHERNET], true), Net.NetTypes.WIFI);
eq('normalize.priority.vpn+cell', Net.normalizeNetType([Net.BEARER_VPN, Net.BEARER_CELLULAR], true), Net.NetTypes.CELLULAR);

// ══════════════════════════════════════════════════════════════════════
// 2. NetworkStateWatcher.shouldEmit
// ══════════════════════════════════════════════════════════════════════
ok('shouldEmit.same', Net.shouldEmit('wifi', 'wifi', 99999, 1500) === false);
ok('shouldEmit.noHistory', Net.shouldEmit('', 'wifi', 0, 1500) === true);
ok('shouldEmit.debounceOff', Net.shouldEmit('wifi', 'cellular', 10, 0) === true);
ok('shouldEmit.clockBackwards', Net.shouldEmit('wifi', 'cellular', -5, 1500) === true);
ok('shouldEmit.insideWindow(1499)', Net.shouldEmit('wifi', 'cellular', 1499, 1500) === false);
ok('shouldEmit.atWindow(1500)', Net.shouldEmit('wifi', 'cellular', 1500, 1500) === true);
ok('shouldEmit.customWindow(300/300)', Net.shouldEmit('wifi', 'cellular', 300, 300) === true);
ok('shouldEmit.customWindow(299/300)', Net.shouldEmit('wifi', 'cellular', 299, 300) === false);

// ══════════════════════════════════════════════════════════════════════
// 3. NetworkStateWatcher 去抖 / generation / 回调隔离 / stop
// ══════════════════════════════════════════════════════════════════════
{
  let now = 0;
  const w = new Net.NetworkStateWatcher(1500, () => now);
  const seen = [];
  const gens = [];
  w.addListener({ onNetworkTypeChanged: (t, g) => { seen.push(t); gens.push(g); } });
  eq('watcher.initial.type', w.networkType(), Net.NetTypes.UNKNOWN);
  eq('watcher.initial.generation', w.generation(), 0);
  eq('watcher.initial.subscribed', w.isSubscribed(), false);
  eq('watcher.debounceWindowMs', w.debounceWindowMs(), 1500);

  w.feedForTest(Net.NetTypes.WIFI);
  eq('watcher.first.emit.generation', w.generation(), 1);
  eq('watcher.first.emit.type', w.networkType(), Net.NetTypes.WIFI);

  w.feedForTest(Net.NetTypes.WIFI);
  eq('watcher.same.type.no.emit', w.generation(), 1);

  now = 500;
  w.feedForTest(Net.NetTypes.CELLULAR);
  eq('watcher.inside.window.no.emit', w.generation(), 1);
  eq('watcher.inside.window.type.unchanged', w.networkType(), Net.NetTypes.WIFI);

  now = 1500;
  w.feedForTest(Net.NetTypes.CELLULAR);
  eq('watcher.window.reached.emit', w.generation(), 2);
  eq('watcher.window.reached.type', w.networkType(), Net.NetTypes.CELLULAR);

  w.feedForTest(Net.NetTypes.NONE);
  eq('watcher.none.inside.window', w.generation(), 2);
  now = 3100;
  w.feedForTest(Net.NetTypes.NONE);
  eq('watcher.none.after.window', w.generation(), 3);

  eq('watcher.seen.count', seen.length, 3);
  eq('watcher.seen[0]', seen[0], Net.NetTypes.WIFI);
  eq('watcher.seen[1]', seen[1], Net.NetTypes.CELLULAR);
  eq('watcher.seen[2]', seen[2], Net.NetTypes.NONE);
  ok('watcher.generation.monotonic', gens[0] === 1 && gens[1] === 2 && gens[2] === 3);
  eq('watcher.negative.debounce.fallsback', new Net.NetworkStateWatcher(-1).debounceWindowMs(), 1500);
}
{
  const w = new Net.NetworkStateWatcher(0, () => 100);
  const good = [];
  w.addListener({ onNetworkTypeChanged: () => { throw new Error('listener boom'); } });
  w.addListener({ onNetworkTypeChanged: (t) => { good.push(t); } });
  w.feedForTest(Net.NetTypes.ETHERNET); // 不得外抛
  eq('watcher.listener.exception.isolated', good.length, 1);
  eq('watcher.listener.exception.generation', w.generation(), 1);
  w.stop();
  eq('watcher.stop.unsubscribed', w.isSubscribed(), false);
  w.stop();
  eq('watcher.stop.idempotent', w.isSubscribed(), false);
  w.feedForTest(Net.NetTypes.WIFI);
  eq('watcher.stop.clears.listeners', good.length, 1);
}

// ══════════════════════════════════════════════════════════════════════
// 4. LinkHealthChecker.summarize 边界
// ══════════════════════════════════════════════════════════════════════
const passItem = (id) => Health.LinkHealthItem.make(id, 'label-' + id, Health.ProbeOutcome.pass('ok', 'v1'), 5);
const failItem = (id, advice) => Health.LinkHealthItem.make(id, 'label-' + id, Health.ProbeOutcome.fail('bad', advice), 7);
const skipItem = (id) => Health.LinkHealthItem.make(id, 'label-' + id, Health.ProbeOutcome.skip('n/a'), 1);
const reportOf = (items) => { const r = new Health.LinkHealthReport(); r.items = items; return r; };

eq('health.const.pass', Health.HealthStatus.PASS, 'pass');
eq('health.const.fail', Health.HealthStatus.FAIL, 'fail');
eq('health.const.skip', Health.HealthStatus.SKIP, 'skip');
eq('health.const.maxRepairSteps', Health.DEFAULT_MAX_REPAIR_STEPS, 3);
{
  const s1 = Health.summarize(reportOf([passItem('subscription'), passItem('core')]));
  eq('summarize.allPass.overall', s1.overall, Health.HealthOverall.OK);
  eq('summarize.allPass.pass', s1.passCount, 2);
  eq('summarize.allPass.fail', s1.failCount, 0);
  eq('summarize.allPass.skip', s1.skipCount, 0);
  eq('summarize.allPass.firstFailId', s1.firstFailId, '');
  ok('summarize.allPass.isOk', s1.isOk() === true);
}
{
  const r = reportOf([passItem('subscription'), failItem('core', '请点击重连以重启内核'), passItem('dns')]);
  const s2 = Health.summarize(r);
  eq('summarize.singleFail.overall', s2.overall, Health.HealthOverall.BROKEN);
  eq('summarize.singleFail.pass', s2.passCount, 2);
  eq('summarize.singleFail.fail', s2.failCount, 1);
  eq('summarize.singleFail.firstFailId', s2.firstFailId, 'core');
  eq('summarize.singleFail.firstFailLabel', s2.firstFailLabel, 'label-core');
  eq('summarize.singleFail.firstFailDetail', s2.firstFailDetail, 'bad');
  eq('summarize.singleFail.firstFailAdvice', s2.firstFailAdvice, '请点击重连以重启内核');
  ok('summarize.singleFail.isBroken', s2.isBroken() === true);
  ok('summarize.fail.has.advice', s2.firstFailAdvice.length > 0);
  eq('summarize.fail.repair.action', r.item('core').repair, Health.RepairActions.RESTART_CORE);
}
{
  const s3 = Health.summarize(reportOf([
    failItem('subscription', '请刷新订阅'), failItem('node', '请重新选择节点'), failItem('tun', '请重连以重建 TUN')
  ]));
  eq('summarize.allFail.overall', s3.overall, Health.HealthOverall.BROKEN);
  eq('summarize.allFail.fail', s3.failCount, 3);
  eq('summarize.allFail.pass', s3.passCount, 0);
  eq('summarize.allFail.firstFailId', s3.firstFailId, 'subscription');
}
{
  const s4 = Health.summarize(new Health.LinkHealthReport());
  eq('summarize.empty.overall', s4.overall, Health.HealthOverall.DEGRADED);
  eq('summarize.empty.pass', s4.passCount, 0);
  eq('summarize.empty.fail', s4.failCount, 0);
  eq('summarize.empty.firstFailId', s4.firstFailId, '');
}
{
  const s5 = Health.summarize(reportOf([passItem('subscription'), skipItem('ipv6')]));
  eq('summarize.skipOnly.overall', s5.overall, Health.HealthOverall.DEGRADED);
  eq('summarize.skipOnly.skip', s5.skipCount, 1);
  eq('summarize.skipOnly.fail', s5.failCount, 0);
}

// ══════════════════════════════════════════════════════════════════════
// 5. LinkHealthChecker.repairSteps（有限 / 有序 / 去重）
// ══════════════════════════════════════════════════════════════════════
{
  eq('repair.empty', Health.repairSteps(new Health.LinkHealthReport()).length, 0);
  eq('repair.allPass', Health.repairSteps(reportOf([passItem('core')])).length, 0);

  const r = reportOf([passItem('subscription'), failItem('node', 'a'), failItem('core', 'a'),
    failItem('clash-api', 'a'), failItem('dns', 'a')]);
  const steps = Health.repairSteps(r);
  eq('repair.default.cap', steps.length, 3);
  eq('repair.ordered[0]', steps[0], Health.RepairActions.RESELECT_NODE);
  eq('repair.ordered[1]', steps[1], Health.RepairActions.RESTART_CORE);
  eq('repair.ordered[2]', steps[2], Health.RepairActions.RESTART_CLASH_API);
  eq('repair.cap1', Health.repairSteps(r, 1).length, 1);
  eq('repair.cap5', Health.repairSteps(r, 5).length, 4);
  eq('repair.cap0', Health.repairSteps(r, 0).length, 0);
  eq('repair.capNegative', Health.repairSteps(r, -3).length, 0);

  const dup = reportOf([failItem('core', 'a'), failItem('core', 'a')]);
  const dupSteps = Health.repairSteps(dup);
  eq('repair.dedupe.length', dupSteps.length, 1);
  eq('repair.dedupe.value', dupSteps[0], Health.RepairActions.RESTART_CORE);

  const allowed = [
    Health.RepairActions.REFRESH_SUBSCRIPTION, Health.RepairActions.RESELECT_NODE,
    Health.RepairActions.GRANT_VPN_PERMISSION, Health.RepairActions.REBUILD_TUN,
    Health.RepairActions.RESTART_CORE, Health.RepairActions.RESTART_CLASH_API,
    Health.RepairActions.FIX_DNS, Health.RepairActions.CHECK_UPLINK,
    Health.RepairActions.RECONCILE_INTENT, Health.RepairActions.ENABLE_NOTIFICATIONS
  ];
  ok('repair.only.enum.actions', steps.every((s) => allowed.includes(s)));
  eq('repairForCheck.subscription', Health.repairForCheck('subscription'), Health.RepairActions.REFRESH_SUBSCRIPTION);
  eq('repairForCheck.node', Health.repairForCheck('node'), Health.RepairActions.RESELECT_NODE);
  eq('repairForCheck.vpn-auth', Health.repairForCheck('vpn-auth'), Health.RepairActions.GRANT_VPN_PERMISSION);
  eq('repairForCheck.tun', Health.repairForCheck('tun'), Health.RepairActions.REBUILD_TUN);
  eq('repairForCheck.core', Health.repairForCheck('core'), Health.RepairActions.RESTART_CORE);
  eq('repairForCheck.clash-api', Health.repairForCheck('clash-api'), Health.RepairActions.RESTART_CLASH_API);
  eq('repairForCheck.dns', Health.repairForCheck('dns'), Health.RepairActions.FIX_DNS);
  eq('repairForCheck.egress-ipv4', Health.repairForCheck('egress-ipv4'), Health.RepairActions.CHECK_UPLINK);
  eq('repairForCheck.intent', Health.repairForCheck('intent-consistency'), Health.RepairActions.RECONCILE_INTENT);
  eq('repairForCheck.unknown', Health.repairForCheck('not-a-check'), '');
}

// ══════════════════════════════════════════════════════════════════════
// 6. LinkHealthChecker.run —— 单点挂死/抛错不阻断 + 总预算截断
// ══════════════════════════════════════════════════════════════════════
function makeStubProbes() {
  const outcomes = new Map();
  const hangIds = new Set();
  const throwIds = new Set();
  const calls = [];
  const pick = (id) => {
    calls.push(id);
    if (hangIds.has(id)) return new Promise(() => { /* 永不 settle */ });
    if (throwIds.has(id)) throw new Error('probe threw: ' + id);
    return Promise.resolve(outcomes.has(id) ? outcomes.get(id) : Health.ProbeOutcome.skip('stub: n/a'));
  };
  return {
    outcomes, hangIds, throwIds, calls,
    probeSubscription: () => pick('subscription'),
    probeNode: () => pick('node'),
    probeVpnAuth: () => pick('vpn-auth'),
    probeTun: () => pick('tun'),
    probeCore: () => pick('core'),
    probeClashApi: () => pick('clash-api'),
    probeDns: () => pick('dns'),
    probeIpv4Egress: () => pick('egress-ipv4'),
    probeIpv6: () => pick('ipv6'),
    probeIntentConsistency: () => pick('intent-consistency')
  };
}

{
  const stubs = makeStubProbes();
  stubs.outcomes.set('subscription', Health.ProbeOutcome.pass('订阅含 3 个节点', '3'));
  stubs.outcomes.set('node', Health.ProbeOutcome.fail('当前节点字段缺失', '请重新选择节点'));
  stubs.outcomes.set('vpn-auth', Health.ProbeOutcome.pass('已授权'));
  stubs.outcomes.set('tun', Health.ProbeOutcome.pass('TUN 已建立', 'tun0'));
  stubs.outcomes.set('core', Health.ProbeOutcome.fail('内核已退出', '请点击重连以重启内核'));
  stubs.outcomes.set('clash-api', Health.ProbeOutcome.pass('API 可达', 'v1.19.0'));
  stubs.outcomes.set('egress-ipv4', Health.ProbeOutcome.pass('generate_204 返回 204'));
  stubs.outcomes.set('ipv6', Health.ProbeOutcome.skip('当前网络不支持 IPv6'));
  stubs.outcomes.set('intent-consistency', Health.ProbeOutcome.pass('意图与真实状态一致'));
  stubs.hangIds.add('dns');        // 永不返回
  stubs.throwIds.add('egress-ipv4'); // 同步抛异常（覆盖其上一条 pass 结论）

  const checker = new Health.LinkHealthChecker(stubs, 4000, 80);
  const report = await checker.run();
  eq('run.items.count', report.items.length, 10);
  eq('run.truncated', report.truncated, false);
  eq('run.hang.becomes.fail', report.item('dns').status, Health.HealthStatus.FAIL);
  ok('run.hang.detail.mentions.timeout', report.item('dns').detail.includes('超时'));
  eq('run.throw.becomes.fail', report.item('egress-ipv4').status, Health.HealthStatus.FAIL);
  eq('run.others.pass', report.item('clash-api').status, Health.HealthStatus.PASS);
  eq('run.skip.preserved', report.item('ipv6').status, Health.HealthStatus.SKIP);
  eq('run.order.first', report.items[0].id, 'subscription');
  eq('run.order.last', report.items[9].id, 'intent-consistency');
  ok('run.duration.recorded', report.item('core').durationMs >= 0);
  eq('run.all.probes.called', stubs.calls.length, 10);

  const s = Health.summarize(report);
  eq('run.summary.overall', s.overall, Health.HealthOverall.BROKEN);
  eq('run.summary.firstFailId', s.firstFailId, 'node');
  eq('run.summary.fail', s.failCount, 4);
  eq('run.summary.pass', s.passCount, 5);
  eq('run.summary.skip', s.skipCount, 1);
  const steps = Health.repairSteps(report);
  eq('run.repair[0]', steps[0], Health.RepairActions.RESELECT_NODE);
  eq('run.repair[1]', steps[1], Health.RepairActions.RESTART_CORE);
  eq('run.repair[2]', steps[2], Health.RepairActions.FIX_DNS);
}
{
  let t = 0;
  const clock = () => { t = t + 10; return t; };
  const stubs = makeStubProbes();
  const report = await new Health.LinkHealthChecker(stubs, 5, 50, clock).run();
  eq('budget.items.count', report.items.length, 10);
  eq('budget.truncated', report.truncated, true);
  eq('budget.no.probe.called', stubs.calls.length, 0);
  ok('budget.all.skip.not.fail', report.items.every((i) => i.status === Health.HealthStatus.SKIP));
  const s = Health.summarize(report);
  eq('budget.summary.overall', s.overall, Health.HealthOverall.DEGRADED);
  eq('budget.summary.fail', s.failCount, 0);
  eq('budget.repair.none', Health.repairSteps(report).length, 0);
}

// ══════════════════════════════════════════════════════════════════════
// 7. SmartSelector
// ══════════════════════════════════════════════════════════════════════
const NC = Select.NodeCandidate;
const SO = Select.SelectorOptions;

eq('selector.concurrency.constant', Select.MAX_SELECT_CONCURRENCY, 4);
eq('selector.sentinel.untested', Select.LATENCY_UNTESTED, -2);
eq('selector.sentinel.failed', Select.LATENCY_FAILED, -1);

// 7.1 评分 + 排序 + 确定性
{
  const nowMs = 2000;
  const c = [
    NC.of('fast-lowrate', 50, 0, 0.5, 1000, 0),
    NC.of('slow-highrate', 120, 0, 1.0, 1000, 0),
    NC.of('untested', Select.LATENCY_UNTESTED, 0, -1, 0, 0),
    NC.of('dead', Select.LATENCY_FAILED, 3, 0, 0, 0)
  ];
  eq('score.fast-lowrate', Select.scoreOf(c[0], nowMs), 200);
  eq('score.slow-highrate', Select.scoreOf(c[1], nowMs), 120);
  eq('score.untested', Select.scoreOf(c[2], nowMs), 650);
  eq('score.dead', Select.scoreOf(c[3], nowMs), 3500);

  const names = Select.orderedNames(c, nowMs);
  eq('rank.order[0]', names[0], 'slow-highrate');
  eq('rank.order[1]', names[1], 'fast-lowrate');
  eq('rank.order[2]', names[2], 'untested');
  eq('rank.order[3]', names[3], 'dead');
  const ranked = Select.rankNodes(c, nowMs);
  eq('rank.index[0]', ranked[0].index, 1);
  eq('rank.score[0]', ranked[0].score, 120);
  eq('rank.dead.ineligible', ranked[3].eligible, false);

  const a = NC.of('a', 100, 0, 1, 1000, 0);
  const b = NC.of('b', 100, 0, 1, 1000, 0);
  const n1 = Select.orderedNames([a, b], nowMs);
  const n2 = Select.orderedNames([b, a], nowMs);
  eq('rank.stable.tiebreak.1', n1[0], 'a');
  eq('rank.stable.tiebreak.2', n2[0], 'b');
  eq('rank.stable.tiebreak.1.2', n1[1], 'b');

  const staleNow = 1901000;
  const stale = NC.of('stale', 100, 0, 1, 1000, 0);
  const fresh = NC.of('fresh', 100, 0, 1, staleNow, 0);
  ok('score.stale.penalized', Select.scoreOf(stale, staleNow) > Select.scoreOf(fresh, staleNow));
  eq('score.stale.value', Select.scoreOf(stale, staleNow), 300);
  eq('score.neverSucceeded.noPenalty', Select.scoreOf(NC.of('never', 100, 0, 1, 0, 0), staleNow), 100);

  const lenient = new SO();
  lenient.failPenalty = 0;
  lenient.successWeight = 0;
  eq('score.configurable.weights', Select.scoreOf(c[3], nowMs, lenient), 2000);
}

// 7.2 冷却惩罚 + 可用性
{
  const nowMs = 100000;
  const hot = NC.of('hot', 30, 0, 1, nowMs, nowMs + 5000);
  const cold = NC.of('cold', 300, 0, 1, nowMs, 0);
  const risky = NC.of('risky', 20, 3, 1, nowMs, 0);
  eq('cooldown.hot.active', Select.isInCooldown(hot, nowMs), true);
  eq('cooldown.hot.expired', Select.isInCooldown(hot, nowMs + 5000), false);
  eq('eligible.hot', Select.isEligible(hot, nowMs), false);
  eq('eligible.risky.atThreshold', Select.isEligible(risky, nowMs), false);
  eq('eligible.cold', Select.isEligible(cold, nowMs), true);
  const relaxed = new SO();
  relaxed.failThreshold = 5;
  eq('eligible.risky.relaxedThreshold', Select.isEligible(risky, nowMs, relaxed), true);
  ok('score.cooldown.beats.lowLatency', Select.scoreOf(hot, nowMs) > Select.scoreOf(cold, nowMs));
  eq('rank.cooldown.last', Select.orderedNames([hot, cold], nowMs)[0], 'cold');
}

// 7.3 failoverAllowed
{
  const nowMs = 100000;
  const cool = NC.of('cool', 50, 3, 0, nowMs, nowMs + 60000);
  const free = NC.of('free', 50, 3, 0, nowMs, 0);
  eq('failover.below.threshold.0', Select.failoverAllowed(null, 0, nowMs), false);
  eq('failover.below.threshold.2', Select.failoverAllowed(null, 2, nowMs), false);
  eq('failover.at.threshold', Select.failoverAllowed(null, 3, nowMs), true);
  eq('failover.above.threshold', Select.failoverAllowed(null, 9, nowMs), true);
  eq('failover.blocked.inCooldown', Select.failoverAllowed(cool, 3, nowMs), false);
  eq('failover.allowed.afterCooldown', Select.failoverAllowed(cool, 3, nowMs + 60000), true);
  eq('failover.allowed.free', Select.failoverAllowed(free, 3, nowMs), true);
  const locked = new SO();
  locked.autoSwitch = false;
  eq('failover.disabled.locked', Select.failoverAllowed(null, 9, nowMs, locked), false);
  const eager = new SO();
  eager.failThreshold = 1;
  eq('failover.eager.threshold1', Select.failoverAllowed(null, 1, nowMs, eager), true);
  const patient = new SO();
  patient.failThreshold = 10;
  eq('failover.patient.threshold10', Select.failoverAllowed(null, 9, nowMs, patient), false);
  const bad = new SO();
  bad.failThreshold = 0;
  eq('options.clamp.failThreshold0', Select.normalizeOptions(bad).failThreshold, 1);
  eq('failover.clamped.threshold', Select.failoverAllowed(null, 1, nowMs, bad), true);
}

// 7.4 nextBestNode
{
  const nowMs = 100000;
  const cur = NC.of('cur', 200, 0, 1, nowMs, 0);
  const better = NC.of('better', 50, 0, 1, nowMs, 0);
  const slight = NC.of('slight', 190, 0, 1, nowMs, 0);
  eq('next.initial.selection', Select.nextBestNode(null, [cur, better], nowMs).name, 'better');
  eq('next.clearly.better', Select.nextBestNode(cur, [cur, better], nowMs).name, 'better');
  eq('next.hysteresis.blocks.slight', Select.nextBestNode(cur, [cur, slight], nowMs), null);
  eq('next.cur.is.best', Select.nextBestNode(better, [cur, better], nowMs), null);
  const locked = new SO();
  locked.autoSwitch = false;
  eq('next.disabled', Select.nextBestNode(cur, [cur, better], nowMs, locked), null);
  const deadCur = NC.of('cur', Select.LATENCY_FAILED, 3, 0, nowMs, 0);
  eq('next.failedCur.immediate', Select.nextBestNode(deadCur, [deadCur, slight], nowMs).name, 'slight');
  eq('next.allDead', Select.nextBestNode(cur,
    [NC.of('x', Select.LATENCY_FAILED, 5, 0, nowMs, 0), NC.of('y', Select.LATENCY_FAILED, 4, 0, nowMs, 0)], nowMs), null);
  eq('next.emptyList', Select.nextBestNode(cur, [], nowMs), null);
  const noHysteresis = new SO();
  noHysteresis.switchMargin = 0;
  eq('next.switchMargin0', Select.nextBestNode(cur, [cur, slight], nowMs, noHysteresis).name, 'slight');
  const curInCooldown = NC.of('cur', 50, 0, 1, nowMs, nowMs + 1000);
  eq('next.cur.inCooldown.uses.bestCand', Select.nextBestNode(curInCooldown, [curInCooldown, slight], nowMs).name, 'slight');
}

// 7.5 markSuccess / markFailure 纯状态迁移
{
  const nowMs = 500000;
  eq('deriveRate.untested', NC.deriveSuccessRate(Select.LATENCY_UNTESTED, 0, false), -1);
  eq('deriveRate.lastFailed', NC.deriveSuccessRate(100, 0, false), 0);
  eq('deriveRate.fail0', NC.deriveSuccessRate(100, 0, true), 1);
  eq('deriveRate.fail1', NC.deriveSuccessRate(100, 1, true), 0.5);
  eq('deriveRate.fail3', NC.deriveSuccessRate(100, 3, true), 0.25);
  eq('fromStats.rate', NC.fromStats('n', 100, 1, true, 1, 0).recentSuccessRate, 0.5);

  const failed = NC.of('n', Select.LATENCY_FAILED, 2, 0, 0, nowMs + 9999);
  const afterOk = Select.markSuccess(failed, nowMs);
  eq('markSuccess.immutable.failures', failed.consecutiveFailures, 2);
  eq('markSuccess.immutable.cooldown', failed.cooldownUntil, nowMs + 9999);
  eq('markSuccess.immutable.latency', failed.latency, Select.LATENCY_FAILED);
  eq('markSuccess.failures.cleared', afterOk.consecutiveFailures, 0);
  near('markSuccess.rate.ewma.from0', afterOk.recentSuccessRate, 0.5);
  eq('markSuccess.lastSuccessAt', afterOk.lastSuccessAt, nowMs);
  eq('markSuccess.cooldown.cleared', afterOk.cooldownUntil, 0);
  eq('markSuccess.failedLatency.toUntested', afterOk.latency, Select.LATENCY_UNTESTED);
  eq('markSuccess.rate.fromUnknown', Select.markSuccess(NC.of('u', 100, 0, -1, 0, 0), nowMs).recentSuccessRate, 1);
  near('markSuccess.rate.fromHalf', Select.markSuccess(NC.of('h', 100, 0, 0.5, 0, 0), nowMs).recentSuccessRate, 0.75);
  eq('markSuccess.rate.capped', Select.markSuccess(NC.of('f', 100, 0, 1, 0, 0), nowMs).recentSuccessRate, 1);

  const healthy = NC.of('h2', 80, 0, 1, nowMs - 1000, 0);
  const f1 = Select.markFailure(healthy, nowMs);
  eq('markFailure.immutable.failures', healthy.consecutiveFailures, 0);
  eq('markFailure.immutable.latency', healthy.latency, 80);
  eq('markFailure.failures+1', f1.consecutiveFailures, 1);
  eq('markFailure.latency.failed', f1.latency, Select.LATENCY_FAILED);
  near('markFailure.rate.decayed', f1.recentSuccessRate, 0.5);
  eq('markFailure.no.cooldown.belowThreshold', f1.cooldownUntil, 0);
  eq('markFailure.keeps.lastSuccessAt', f1.lastSuccessAt, nowMs - 1000);
  const f2 = Select.markFailure(f1, nowMs);
  eq('markFailure.failures=2', f2.consecutiveFailures, 2);
  near('markFailure.rate.decayed.2', f2.recentSuccessRate, 0.25);
  eq('markFailure.still.no.cooldown', f2.cooldownUntil, 0);
  const f3 = Select.markFailure(f2, nowMs);
  eq('markFailure.failures=3', f3.consecutiveFailures, 3);
  eq('markFailure.cooldown.entered', f3.cooldownUntil, nowMs + 60000);
  eq('markFailure.cooldown.blocks.failover', Select.failoverAllowed(f3, 3, nowMs), false);
  eq('markFailure.cooldown.expiry.allows.failover', Select.failoverAllowed(f3, 3, nowMs + 60000), true);
  eq('markFailure.rate.fromUnknown', Select.markFailure(NC.of('u2', 100, 0, -1, 0, 0), nowMs).recentSuccessRate, 0);
  const tight = new SO();
  tight.cooldownMs = 1000;
  tight.failThreshold = 2;
  const g1 = Select.markFailure(healthy, nowMs, tight);
  eq('markFailure.tight.no.cooldown', g1.cooldownUntil, 0);
  const g2 = Select.markFailure(g1, nowMs, tight);
  eq('markFailure.tight.cooldown', g2.cooldownUntil, nowMs + 1000);
}

// 7.6 参数夹取 + 并发常量
{
  const d = Select.normalizeOptions();
  eq('options.default.failThreshold', d.failThreshold, 3);
  eq('options.default.cooldownMs', d.cooldownMs, 60000);
  eq('options.default.autoSwitch', d.autoSwitch, true);
  eq('options.default.maxConcurrency', d.maxConcurrency, Select.MAX_SELECT_CONCURRENCY);
  const bad = new SO();
  bad.failThreshold = 0; bad.cooldownMs = -1; bad.switchMargin = -5; bad.failPenalty = -1; bad.maxConcurrency = 0;
  const fixed = Select.normalizeOptions(bad);
  eq('options.clamp.failThreshold', fixed.failThreshold, 1);
  eq('options.clamp.cooldownMs', fixed.cooldownMs, 0);
  eq('options.clamp.switchMargin', fixed.switchMargin, 0);
  eq('options.clamp.failPenalty', fixed.failPenalty, 0);
  eq('options.clamp.maxConcurrency', fixed.maxConcurrency, 1);
  eq('concurrency.default', Select.selectConcurrency(), Select.MAX_SELECT_CONCURRENCY);
  const big = new SO();
  big.maxConcurrency = 100;
  eq('concurrency.capped.by.constant', Select.selectConcurrency(big), Select.MAX_SELECT_CONCURRENCY);
  const small = new SO();
  small.maxConcurrency = 2;
  eq('concurrency.lowered', Select.selectConcurrency(small), 2);
  const keep = new SO();
  keep.failThreshold = 7;
  Select.normalizeOptions(keep);
  eq('options.input.not.mutated', keep.failThreshold, 7);
}

// ── 收尾 ──────────────────────────────────────────────────────────────
rmSync(sandbox, { recursive: true, force: true });

console.log('===== TunBox 第二阶段纯逻辑离线校验 =====');
for (const n of notes) {
  console.log('[INFO] ' + n);
}
console.log('[INFO] 断言引擎: 本脚本内置（非 Hypium）。Hypium 需真机 + 已签名 HAP，本轮未执行。');
console.log('-----------------------------------------');
if (failures.length > 0) {
  console.log('FAILED 断言 (' + failures.length + '):');
  for (const f of failures) {
    console.log('  FAIL ' + f);
  }
}
console.log('PASSED=' + passed + '  FAILED=' + failures.length + '  TOTAL=' + (passed + failures.length));
console.log(failures.length === 0 ? 'RESULT: ALL PURE-LOGIC CHECKS PASSED' : 'RESULT: FAILURES PRESENT');
process.exit(failures.length === 0 ? 0 : 1);
