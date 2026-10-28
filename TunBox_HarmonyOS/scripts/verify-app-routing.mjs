#!/usr/bin/env node
/**
 * node scripts/verify-app-routing.mjs (Node 24+)
 * EXEC: 真 AppRoutingPolicy + AppSettings + 提取真 NodeSortModes 类，原生去类型执行。
 * SOURCE: SDK 集成点静态护栏，不声称等同真机 VPN 验证；不构建、不改写工程。
 * SettingsService 真 load/save 方法另注入纯内存 store，验证损坏 JSON 的 fail-closed 边界。
 *
 * 用法: node scripts/verify-app-routing.mjs [--ets <dir>]
 *   --ets 指向另一棵 entry/src/main/ets 树，用于负对照（对旧代码/被改坏的代码
 *   运行本脚本时**必须失败**）。省略时用本仓库的 ets 树。
 *
 * ⚠ 行尾陷阱（本脚本已处理，勿改回去）：仓库在 Windows 上是 core.autocrlf=true 的
 *   CRLF 检出，而源码断言里写的是 LF 字面量（`...;\n      return;`）。读取时统一
 *   归一化 CRLF→LF，否则断言恒假 —— 这就是本脚本 0.4.0 之后常年红的原因。
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const etsArg = process.argv.indexOf('--ets');
const ets = etsArg >= 0 && process.argv[etsArg + 1]
  ? resolve(process.argv[etsArg + 1])
  : resolve(root, 'entry/src/main/ets');
// 统一换行：仓库是 CRLF 检出，源码断言写的是 LF；归一化后断言才反映真实语义。
const read = path => readFileSync(resolve(ets, path), 'utf8').replace(/\r\n/g, '\n');
const policySource = read('commons/services/AppRoutingPolicy.ets');
const settingsSource = read('commons/models/AppSettings.ets');
// 2026-10-20（ND06 收口）：AppSettings 的测速地址常量引用 LatencyTestUrl（唯一真源），
// 而本闸门会剥掉 import ⇒ 这里按**真源码**把该模块的常量注入进来。
const latencyTestUrlSrc = read('commons/latency/LatencyTestUrl.ets');
const latencyTestUrlConst = (name) => {
  const m = latencyTestUrlSrc.match(new RegExp("static readonly " + name + ": string = '([^']*)'"));
  if (m === null) { throw new Error('LatencyTestUrl.ets 里找不到常量 ' + name); }
  return m[1];
};
const sortSource = read('commons/services/NodeSortPersistence.ets');
const orchestrator = read('commons/services/ConnectionOrchestrator.ets');
const extension = read('vpnability/VpnExtensionAbility.ets');
const sortClass = sortSource.match(/export class NodeSortModes \{[\s\S]*?^\}/m)?.[0];
assert.ok(sortClass, 'must extract real NodeSortModes, never substitute a test implementation');
const serviceSource = read('commons/services/SettingsService.ets');
// 提取实际方法（按类方法4空格结束行），不复制/重写 load/save 分支。
const loadMethod = serviceSource.match(/^  static async load\(\): Promise<AppSettings> \{[\s\S]*?^  \}/m)?.[0];
const saveMethod = serviceSource.match(/^  static async save\(settings: AppSettings\): Promise<void> \{[\s\S]*?^  \}/m)?.[0];
const flushMethod = serviceSource.match(/^  static async flushNow\(\): Promise<void> \{[\s\S]*?^  \}/m)?.[0];
assert.ok(loadMethod && saveMethod && flushMethod, 'must extract actual SettingsService load/save/flushNow methods');
const serviceHarness = `
const KEY_SETTINGS = 'app_settings_json';
export class MemorySettingsStore {
  raw = ''; puts = 0; flushes = 0;
  async get() { return this.raw; }
  async put(key, value) { this.raw = value; this.puts++; }
  async flush() { this.flushes++; }
}
export class SettingsService {
  static store = null;
  // 用例会直接改写 store 原文来模拟「另一个写者」：屏蔽进程内缓存，保证 load 读盘。
  static get cache() { return null; }
  static set cache(_v) {}
  static syncRawProviderGate() {} // unrelated file cleanup boundary, no routing behavior
  // 测速快照分片与本闸门无关（闸门验的是路由规则的读写语义）：
  // 桩掉这两个新入口，别让「分片」把规则读写的结论搅进来。
  static async loadNodeSortSnapshot() { return ''; }
  static async routeSnapshotWrite() {}
${loadMethod}
${saveMethod.replace('static async save(', 'private static async saveDeferred(')}
  // 闸门不模拟 300ms 防抖窗口：save() 立即 flushNow，落盘计数才可断言。
  static scheduleFlush() {}
  static async save(settings) {
    await SettingsService.saveDeferred(settings);
    await SettingsService.flushNow();
  }
${flushMethod}
  static writeChain = Promise.resolve();
${serviceSource.match(/^  static async patchSettings\(mutator: SettingsMutator\): Promise<void> \{[\s\S]*?^  \}/m)?.[0] ?? 'static async patchSettings() { throw new Error("missing"); }'}
}
`;
const latencyTestUrlStub = [
  'class LatencyTestUrl {',
  `  static readonly DEFAULT_URL: string = ${JSON.stringify(latencyTestUrlConst('DEFAULT_URL'))};`,
  `  static readonly ALT_URL: string = ${JSON.stringify(latencyTestUrlConst('ALT_URL'))};`,
  `  static readonly LEGACY_GSTATIC_HTTP: string = ${JSON.stringify(latencyTestUrlConst('LEGACY_GSTATIC_HTTP'))};`,
  `  static readonly LEGACY_CLOUDFLARE_HTTP: string = ${JSON.stringify(latencyTestUrlConst('LEGACY_CLOUDFLARE_HTTP'))};`,
  '}'
].join('\n');
const code = latencyTestUrlStub + '\n' + sortClass + '\n' + policySource + '\n'
  + settingsSource.replace(/^import .*;\r?\n/gm, '') + serviceHarness;
const js = stripTypeScriptTypes(code, { mode: 'strip' });
const mod = await import('data:text/javascript;base64,' + Buffer.from(js).toString('base64'));
const P = mod.AppRoutingPolicy;
const M = mod.AppRoutingModes;
const A = mod.AppSettings;
const J = mod.AppSettingsJson;
console.log(`\nApp routing verification${etsArg >= 0 ? ` (--ets ${ets})` : ''}`);
let passed = 0;
const check = (label, fn) => { fn(); passed++; console.log('PASS ' + label); };
const validate = (mode, inc = [], exc = [], review = false) => P.validationError(mode, inc, exc, review);
const load = value => A.fromJson(JSON.parse(JSON.stringify(value)));
const roundTrip = s => load(s.toJson());
const packages = n => Array.from({ length: n }, (_, i) => 'com.sample.app' + i);

check('EXEC explicit modes/constants/default fields', () => {
  assert.deepEqual([M.ALL, M.INCLUDE, M.EXCLUDE], ['all', 'include', 'exclude']);
  const s = new A();
  assert.equal(s.appRoutingMode, 'all'); assert.equal(s.appRoutingNeedsReview, false);
  assert.deepEqual(s.appRoutingCustomApps, []);
});
check('EXEC JSON missing mode remains missing (no migration masking)', () => {
  const j = new J(); j.includedApps = ['com.demo.app'];
  assert.equal(j.appRoutingMode, undefined);
  assert.equal(A.fromJson(j).appRoutingMode, 'include');
});
for (const [label, raw, mode, review] of [
  ['missing', {}, 'all', false],
  ['empty', { includedApps: [], excludedApps: [] }, 'all', false],
  ['include-only', { includedApps: ['com.demo.app'] }, 'include', false],
  ['exclude-only', { excludedApps: ['com.demo.app'] }, 'exclude', false],
  ['both-disjoint', { includedApps: ['com.demo.a'], excludedApps: ['com.demo.b'] }, 'include', true],
  ['both-identical', { includedApps: ['com.demo.a'], excludedApps: ['com.demo.a'] }, 'include', true]
]) {
  check('EXEC migration ' + label, () => {
    const s = load(raw); assert.equal(s.appRoutingMode, mode); assert.equal(s.appRoutingNeedsReview, review);
    assert.deepEqual(roundTrip(s).toJson(), s.toJson());
    if (review) assert.throws(() => P.runtime(s.appRoutingMode, s.includedApps, s.excludedApps, s.appRoutingNeedsReview));
  });
}
check('EXEC legacy conflict persists across unrelated saves then explicit confirmation clears', () => {
  let s = load({ includedApps: ['com.demo.a'], excludedApps: ['com.demo.b'] });
  s.themeMode = 2; s = roundTrip(s);
  assert.equal(s.appRoutingNeedsReview, true);
  s.appRoutingMode = 'exclude'; s.appRoutingNeedsReview = false;
  s = roundTrip(s);
  assert.equal(s.appRoutingNeedsReview, false);
  assert.deepEqual(s.includedApps, ['com.demo.a']); assert.deepEqual(s.excludedApps, ['com.demo.b']);
});
check('EXEC explicit all keeps both saved lists but sends neither', () => {
  const s = load({ appRoutingMode: 'all', includedApps: ['com.demo.a'], excludedApps: ['com.demo.b'] });
  assert.equal(s.appRoutingNeedsReview, false);
  assert.deepEqual(P.runtime(s.appRoutingMode, s.includedApps, s.excludedApps, false).packages, []);
  assert.deepEqual(roundTrip(s).includedApps, s.includedApps);
  assert.deepEqual(roundTrip(s).excludedApps, s.excludedApps);
});
check('EXEC explicit include/exclude selects one list without difference', () => {
  for (const mode of ['include', 'exclude']) {
    const r = P.runtime(mode, ['com.demo.a'], ['com.demo.a', 'com.demo.b'], false);
    assert.deepEqual(r.packages, mode === 'include' ? ['com.demo.a'] : ['com.demo.a', 'com.demo.b']);
    assert.equal(r.mode, mode); assert.equal(r.needsReview, false);
  }
});
for (const mode of ['', 'global', 'ALL', ' include ', 'invalid', null, 4]) {
  check('EXEC unknown mode fails closed: ' + String(mode), () => {
    assert.notEqual(validate(mode), '');
    const s = load({ appRoutingMode: mode });
    assert.notEqual(s.appRoutingMode, 'all'); assert.equal(s.appRoutingNeedsReview, true);
    assert.throws(() => P.runtime(s.appRoutingMode, [], [], s.appRoutingNeedsReview));
  });
}
check('EXEC empty include rejected; empty exclude/all valid', () => {
  assert.notEqual(validate('include'), '');
  assert.equal(validate('exclude'), ''); assert.equal(validate('all'), '');
});
check('EXEC trim and stable dedupe do not mutate input', () => {
  const raw = [' com.demo.a ', 'com.demo.b', 'com.demo.a'];
  assert.deepEqual(P.normalizePackages(raw), ['com.demo.a', 'com.demo.b']);
  assert.equal(raw[0], ' com.demo.a ');
  assert.deepEqual(P.normalizePackages(['', ' ']), ['']);
});
for (const bad of ['', ' ', 'com.demo.a,com.demo.b', 'com.demo..app', '.com.demo', 'com.demo.',
  'com.demo app', 'com.demo\napp', 'com.demo/app', 'com.demo-app', '应用.包名', 'a', 'a.' + 'x'.repeat(126)]) {
  check('EXEC invalid package kept and blocked: ' + JSON.stringify(bad), () => {
    assert.notEqual(validate('include', [bad]), '');
    assert.notEqual(validate('exclude', [], [bad]), '');
    assert.notEqual(validate('all', [], [bad]), '');
    const s = load({ includedApps: [bad] });
    assert.deepEqual(s.includedApps, [bad.trim()]);
    assert.equal(s.appRoutingNeedsReview, true);
    assert.deepEqual(roundTrip(s).includedApps, s.includedApps);
  });
}
check('EXEC malformed legacy list/non-string item never becomes valid empty all', () => {
  for (const malformed of [null, 'com.demo.a', 7, [null], [123], [{}]]) {
    const s = load({ includedApps: malformed });
    assert.equal(s.appRoutingNeedsReview, true); assert.ok(s.includedApps.length > 0);
    assert.notEqual(validate(s.appRoutingMode, s.includedApps, s.excludedApps, false), '');
  }
});
check('EXEC bundle length boundaries', () => {
  assert.equal(validate('include', ['a.b']), '');
  assert.equal(validate('include', ['a.' + 'x'.repeat(125)]), '');
  assert.notEqual(validate('include', ['a.' + 'x'.repeat(126)]), '');
});
for (const mode of ['all', 'include', 'exclude']) {
  check('EXEC both saved lists enforce 256 in mode ' + mode, () => {
    assert.equal(validate(mode, packages(256), packages(256)), '');
    assert.notEqual(validate(mode, packages(257), []), '');
    assert.notEqual(validate(mode, ['com.demo.a'], packages(257)), '');
    assert.equal(P.normalizePackages(packages(257)).length, 257);
    const raw = { appRoutingMode: mode, includedApps: packages(257) };
    assert.equal(load(raw).includedApps.length, 257);
    assert.equal(load(raw).appRoutingNeedsReview, true);
  });
}
check('EXEC duplicate count uses unique packages, not input length', () => {
  assert.equal(validate('include', Array(300).fill('com.demo.a')), '');
  assert.equal(P.runtime('include', Array(300).fill('com.demo.a'), [], false).packages.length, 1);
});
check('EXEC custom app contract and persistence', () => {
  const s = new A(); const app = new mod.AppRoutingCustomApp();
  app.bundleName = 'com.demo.custom'; app.label = '自定义应用'; s.appRoutingCustomApps = [app];
  const copy = roundTrip(s);
  assert.equal(copy.appRoutingCustomApps[0].bundleName, app.bundleName);
  assert.equal(copy.appRoutingCustomApps[0].label, app.label);
});
for (const mode of ['all', 'include', 'exclude']) {
  check('EXEC single-list transport roundtrip ' + mode, () => {
    const r = P.runtime(mode, ['com.demo.a'], ['com.demo.b'], false);
    assert.deepEqual(P.fromTransport(r.mode, JSON.stringify(r.packages), r.needsReview), r);
    assert.equal(P.runtimeError(r), '');
  });
}
for (const [mode, json, review] of [
  ['', '[]', false], ['include', '[]', false], ['include', '["com.demo.a,com.demo.b"]', false],
  ['all', '["com.demo.a"]', false], ['include', '', false], ['include', 'broken', false],
  ['include', '{}', false], ['include', 'null', false], ['include', '[1]', false],
  ['include', '["com.demo.a"]', true], ['exclude', JSON.stringify(packages(257)), false]
]) {
  check('EXEC malformed/conflicting transport rejects ' + mode + '/' + json.slice(0, 25), () => {
    assert.throws(() => P.fromTransport(mode, json, review));
  });
}
check('EXEC session recovery rejects missing/corrupted snapshot', () => {
  assert.notEqual(P.runtimeError(new mod.AppRoutingRuntime()), '');
  const r = P.runtime('include', ['com.demo.a'], [], false);
  r.packages = []; assert.notEqual(P.runtimeError(r), '');
  r.mode = 'all'; r.packages = ['com.demo.a']; assert.notEqual(P.runtimeError(r), '');
  r.mode = 'future'; assert.notEqual(P.runtimeError(r), '');
});
check('EXEC manual input parses name|bundle (both orders, full-width bar, tab)', () => {
  const one = P.parseEntries('支付宝|com.alipay.mobile.client', '');
  assert.equal(one.length, 1);
  assert.equal(one[0].bundleName, 'com.alipay.mobile.client');
  assert.equal(one[0].label, '支付宝');
  const reversed = P.parseEntries('com.alipay.mobile.client|支付宝', '');
  assert.equal(reversed[0].bundleName, 'com.alipay.mobile.client');
  assert.equal(reversed[0].label, '支付宝');
  const wide = P.parseEntries('微信 ｜ com.tencent.wechat', '');
  assert.equal(wide[0].bundleName, 'com.tencent.wechat');
  assert.equal(wide[0].label, '微信');
  const tabbed = P.parseEntries('抖音\tcom.ss.hm.ugc.aweme', '');
  assert.equal(tabbed[0].bundleName, 'com.ss.hm.ugc.aweme');
  assert.equal(tabbed[0].label, '抖音');
});
check('EXEC manual input keeps label field for single line and per-line names for batch', () => {
  const single = P.parseEntries('com.tencent.wechat', '  微信  ');
  assert.equal(single[0].label, '微信');
  const batch = P.parseEntries('支付宝|com.alipay.mobile.client', '备注不生效');
  assert.equal(batch[0].label, '支付宝');
  const mixed = P.parseEntries('支付宝|com.alipay.mobile.client\ncom.tencent.wechat', '备注不生效');
  assert.equal(mixed.length, 2);
  assert.equal(mixed[1].label, '');
  assert.equal(mixed[1].bundleName, 'com.tencent.wechat');
  assert.deepEqual(P.parseEntries('  \n \n', ''), []);
});
check('EXEC manual input never drops an unparsable line and blocks submit', () => {
  assert.notEqual(P.entriesError([]), '');
  const ok = P.parseEntries('支付宝|com.alipay.mobile.client', '');
  assert.equal(P.entriesError(ok), '');
  const bad = P.parseEntries('支付宝 com.alipay', '');
  assert.equal(bad.length, 1);
  assert.equal(bad[0].bundleName, '支付宝 com.alipay');
  assert.notEqual(P.entriesError(bad), '');
  assert.ok(P.isBundleName('com.demo.app'));
  assert.ok(!P.isBundleName('com.demo app'));
});
const connect = orchestrator.slice(orchestrator.indexOf('  private async connectExclusive('));
const onCreate = extension.slice(extension.indexOf('  async onCreate('));
const rebuild = extension.slice(extension.indexOf('  private async rebuildTunnel('), extension.indexOf('  private startNetworkAuthority('));
const recover = extension.slice(extension.indexOf('  private async recoverCore('), extension.indexOf('  private cleanupResources('));
check('SOURCE connect validates settings before VPN stop/start and YAML generation', () => {
  const gate = connect.indexOf('AppRoutingPolicy.runtime(');
  assert.ok(gate >= 0 && gate < connect.indexOf('stopVpnExtensionAbility('));
  assert.ok(gate < connect.indexOf('RuntimeConfigBuilder.buildRuntimeConfig('));
  assert.ok(gate < connect.indexOf('startVpnExtensionAbility(want)'));
});
check('SOURCE explicit mode and one JSON list in every normal start Want', () => {
  // 断言**语义**而不是字面语法：want.parameters 曾被重构为
  // `Record<string, string|number|boolean>` + 下标赋值（ArkTS 禁止无类型对象字面量），
  // 于是老的 `appRoutingMode: appRouting.mode` 字面量断言变成假阴性。
  // 真正要守的是：三个键都必须从 appRouting.* 取值，且不得再传 CSV 名单。
  for (const key of ['appRoutingMode', 'appRoutingNeedsReview', 'appRoutingPackagesJson']) {
    assert.ok(new RegExp(`${key}'\\]\\s*=|${key}\\s*:`).test(connect),
      `connect must set want parameter ${key}`);
  }
  assert.ok(/appRoutingMode'\]\s*=\s*appRouting\.mode|appRoutingMode:\s*appRouting\.mode/.test(connect));
  assert.ok(/appRoutingNeedsReview'\]\s*=\s*appRouting\.needsReview|appRoutingNeedsReview:\s*appRouting\.needsReview/.test(connect));
  assert.ok(/appRoutingPackagesJson'\]\s*=\s*packagesJson|appRoutingPackagesJson:\s*packagesJson/.test(connect));
  assert.ok(!connect.includes('bypassPackages:')); assert.ok(!connect.includes('proxyPackages:'));
});
check('SOURCE Extension resets per-onCreate policy and checks missing/conflicting transport before create', () => {
  assert.ok(onCreate.indexOf('this.appRouting = new AppRoutingRuntime()') < onCreate.indexOf('const params = want.parameters'));
  // 同样只断言语义：拒绝旧 CSV 传输键的写法被重排过（现在是
  // `params['bypassPackages'] === undefined && params['proxyPackages'] === undefined`
  // 的合取形式，与原来的析取否定等价），逐字面量匹配会假阴性。
  assert.ok(/params\['bypassPackages'\]\s*===\s*undefined/.test(onCreate)
    && /params\['proxyPackages'\]\s*===\s*undefined/.test(onCreate),
    'onCreate must reject the legacy CSV transport keys');
  assert.ok(onCreate.indexOf('AppRoutingPolicy.fromTransport(') < onCreate.indexOf('this.connection.create(config)'));
  assert.ok(onCreate.includes('await this.cleanupResources();\n      return;'));
});
check('SOURCE no CSV difference or silent truncation', () => {
  assert.ok(!extension.includes('effectiveAllow')); assert.ok(!extension.includes(".split(',')"));
  assert.ok(!extension.includes('slice(0, 256)')); assert.ok(!policySource.includes('slice(0, 256)'));
});
check('SOURCE mutually exclusive API fields from selected mode', () => {
  assert.ok(extension.includes('config.trustedApplications = undefined;'));
  assert.ok(extension.includes('config.blockedApplications = undefined;'));
  assert.ok(extension.includes('if (this.appRouting.mode === AppRoutingModes.INCLUDE)'));
  assert.ok(extension.includes('} else if (this.appRouting.mode === AppRoutingModes.EXCLUDE'));
  assert.ok(onCreate.includes('this.applyAppRouting(config);'));
});
check('SOURCE rebuild revalidates and reapplies before destroying old connection', () => {
  // 0.4.0 重排：旧连接变量 old 更名为 retired（重建期间保留 gap protection 语义）。
  // 断言的语义不变：必须先校验路由、再销毁旧连接；只接受当前实现的变量名。
  const routingCheck = rebuild.indexOf('AppRoutingPolicy.runtimeError(this.appRouting)');
  const destroyOld = /await (?:retired|old)\.destroy\(\)/.exec(rebuild);
  assert.ok(routingCheck >= 0 && destroyOld !== null,
    'rebuild must both revalidate routing and destroy the previous connection');
  assert.ok(routingCheck < destroyOld.index);
  assert.ok(rebuild.indexOf('this.applyAppRouting(config)') < rebuild.indexOf('candidate.create(config)'));
  assert.ok(recover.indexOf('AppRoutingPolicy.runtimeError(this.appRouting)') < recover.indexOf('await coreBridge.stopCore()'));
});
check('SOURCE pure policy has no SDK or model dependencies', () => {
  assert.ok(!/^import /m.test(policySource));
  assert.ok(!/\b(any|unknown)\b/.test(policySource));
});
check('SOURCE restart prevalidates before disconnect and failure cannot be reported as none', () => {
  const restart = orchestrator.slice(orchestrator.indexOf('  async restartIfConnected('), orchestrator.indexOf('  async applyProxyMode('));
  assert.ok(restart.indexOf('AppRoutingPolicy.runtime(') < restart.indexOf('await this.disconnect()'));
  assert.match(restart, /if \(!ok\) \{\s*throw new Error/);
});
check('SOURCE direct connect routing failure preserves old tunnel and avoids repair/failover', () => {
  const preflight = connect.slice(0, connect.indexOf('const secretTask:'));
  assert.ok(preflight.includes('AppRoutingPolicy.runtime('));
  assert.ok(preflight.includes('return false;'));
  assert.ok(!preflight.includes('disconnectInternal('));
  assert.ok(!preflight.includes('runHealthSelfCheckAndRepair('));
});
const checkAsync = async (label, fn) => { await fn(); passed++; console.log('PASS ' + label); };
const S = mod.SettingsService;
const store = new mod.MemorySettingsStore();
await checkAsync('EXEC actual SettingsService uninitialized load/save reject', async () => {
  S.store = null;
  await assert.rejects(() => S.load(), /尚未初始化/);
  await assert.rejects(() => S.save(new A()), /尚未初始化/);
});
S.store = store;
await checkAsync('EXEC actual SettingsService first install empty raw permits explicit all', async () => {
  store.raw = '';
  const s = await S.load();
  assert.equal(s.appRoutingMode, 'all'); assert.equal(s.appRoutingNeedsReview, false);
  assert.deepEqual(P.runtime(s.appRoutingMode, s.includedApps, s.excludedApps, false).packages, []);
});
for (const raw of ['{', 'null', '[]', '42']) {
  await checkAsync('EXEC actual SettingsService corrupt raw rejects routing: ' + raw, async () => {
    store.raw = raw;
    const s = await S.load();
    assert.equal(s.appRoutingMode, ''); assert.equal(s.appRoutingNeedsReview, true);
    assert.throws(() => P.runtime(s.appRoutingMode, s.includedApps, s.excludedApps, s.appRoutingNeedsReview));
  });
}
await checkAsync('EXEC actual SettingsService save retains both lists/review and flushes', async () => {
  store.raw = JSON.stringify({ includedApps: ['com.demo.a'], excludedApps: ['com.demo.b'] });
  let s = await S.load(); s.themeMode = 1;
  const oldFlushes = store.flushes;
  await S.save(s); assert.equal(store.flushes, oldFlushes + 1);
  s = await S.load();
  assert.equal(s.appRoutingNeedsReview, true);
  assert.deepEqual(s.includedApps, ['com.demo.a']); assert.deepEqual(s.excludedApps, ['com.demo.b']);
  s.appRoutingMode = 'exclude'; s.appRoutingNeedsReview = false;
  await S.save(s); s = await S.load();
  assert.equal(s.appRoutingMode, 'exclude'); assert.equal(s.appRoutingNeedsReview, false);
});
console.log(`\nApp routing verification: ${passed} checks passed (EXEC + explicitly labeled SOURCE).`);
