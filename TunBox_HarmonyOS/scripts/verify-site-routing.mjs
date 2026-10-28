#!/usr/bin/env node
/**
 * node scripts/verify-site-routing.mjs (Node 24+)
 * EXEC: actual SiteRoutingPolicy, AppSettings, SettingsService load/save and
 * SiteRoutingPage non-builder methods, stripped with Node stripTypeScriptTypes.
 * SDK boundaries are in-memory fakes, NOT device/UI/VPN integration tests.
 * SOURCE: explicitly static integration guards. No build, disk writes or commit.
 * --defer-home-node skips only parallel-agent-owned Home/Node SOURCE checks.
 * AUDIT reports existing out-of-contract malformed JSON limitations separately.
 *
 * 用法: node scripts/verify-site-routing.mjs [--ets <dir>] [--defer-home-node]
 *   --ets 指向另一棵 entry/src/main/ets 树，用于负对照（对旧代码/被改坏的代码
 *   运行本脚本时**必须失败**）。省略时用本仓库的 ets 树。
 *
 * ⚠ 行尾陷阱：仓库是 core.autocrlf=true 的 CRLF 检出；读取时统一归一化 CRLF→LF，
 *   让 `^  }` 之类的方法边界断言按真实语义工作。
 */
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const etsArg = process.argv.indexOf('--ets');
const ets = etsArg >= 0 && process.argv[etsArg + 1]
  ? resolve(process.argv[etsArg + 1])
  : resolve(root, 'entry/src/main/ets');
const read = path => readFileSync(resolve(ets, path), 'utf8').replace(/\r\n/g, '\n');
const policy = read('commons/services/SiteRoutingPolicy.ets');
const page = read('pages/SiteRoutingPage.ets');
const network = read('pages/HomePage.ets');
const settings = read('commons/models/AppSettings.ets');
const service = read('commons/services/SettingsService.ets');
const orchestrator = read('commons/services/ConnectionOrchestrator.ets');
const generator = read('commons/services/ClashConfigGenerator.ets');
const extract = (source, pattern, label) => {
  const matches = [...source.matchAll(new RegExp(pattern.source, pattern.flags.includes('g') ? pattern.flags : pattern.flags + 'g'))];
  assert.equal(matches.length, 1, 'exactly one real source extraction: ' + label);
  return matches[0][0];
};
const method = (source, name) => extract(source,
  new RegExp('^  (?:private )?(?:static )?(?:async )?' + name + '\\([^\\n]*\\{[\\s\\S]*?^  \\}', 'm'), name);
const sort = extract(read('commons/services/NodeSortPersistence.ets'), /export class NodeSortModes \{[\s\S]*?^\}/m, 'NodeSortModes');
// 测速地址真源（LatencyTestUrl）被 ClashConfigGenerator 引用 —— 本闸门不测它，
// 桩一份最小实现，避免「生成器 import 了一个本闸门没暂存的模块」而整个崩掉。
const latencyTestUrlStub = `
export class LatencyTestUrl {
  static readonly DEFAULT_URL: string = 'https://www.gstatic.com/generate_204';
  static readonly MAX_LENGTH: number = 512;
  static effective(url: string): string {
    return url.length === 0 ? LatencyTestUrl.DEFAULT_URL : url;
  }
  static isValid(url: string): boolean {
    return url.length > 0 && url.length <= LatencyTestUrl.MAX_LENGTH;
  }
}
`;
// Preserve every real field/method before the first page @Builder. Remove only
// whole-line @State annotations, not "@..." in strings, callbacks or decorators
// from the separate SiteInputDialog. The dialog builder alone is an SDK stub.
const start = page.indexOf('struct SiteRoutingPage {');
const end = page.indexOf('\n  @Builder', start);
assert.ok(start >= 0 && end > start, 'real page class prefix must exist');
let pageClass = page.slice(start, end);
const dialog = extract(pageClass,
  /^  private dialog: CustomDialogController = new CustomDialogController\(\{\r?\n[\s\S]*?^  \}\);/m, 'only dialog initializer');
// 0.4.0 起类前缀里不再只有 @State：主题即时切换引入了 @StorageLink（以及后续可能
// 出现的 @Prop/@Link/@Watch/@LocalStorageLink…）。这些**字段装饰器**都只影响 ArkUI
// 运行时，去掉后字段本身仍是合法 TS 类字段。因此按「整行装饰器」统一剥离，而不是
// 逐条枚举 —— 逐条枚举会在下一次加装饰器时又变成假失败。
// 只剥离 `^  @Name` 或 `^  @Name(...)` 形式的行首装饰器：字符串/回调里的 "@" 不受影响。
pageClass = pageClass.replace(dialog, '  private dialog = { open() {}, close() {} };')
  .replace(/^struct SiteRoutingPage \{/m, 'export class SiteRoutingPage {')
  .replace(/^  @[A-Za-z_$][\w$]*(?:\([^()]*\))?[ \t]*/gm, '  ') + '\n}\n';
assert.ok(!/^\s*@/m.test(pageClass), 'no unhandled decorators may enter execution');
const harness = `
export const boundary = { dialogs: [], toasts: [], backs: 0, applies: [], outcome: 'hot', params: {}, loadError: false, saveError: false, applyError: false };
const router = { getParams() { return boundary.params; }, back() { boundary.backs++; } };
const promptAction = { async showDialog() { const value = boundary.dialogs.shift(); if (value instanceof Error) throw value; if (value === undefined) throw new Error('Unplanned dialog'); return { index: value }; }, showToast(value) { boundary.toasts.push(value.message); } };
const $r = value => value;
const getContext = () => ({});
const pasteboard = { MIMETYPE_TEXT_PLAIN: 'text/plain', createData(type, text) { return text; }, getSystemPasteboard() { return { async setData() {} }; } };
const ConnectionOrchestrator = { instance() { return { init() {}, async applyRulesChanged(reason) { boundary.applies.push(reason); if (boundary.applyError) throw new Error('apply failed'); return boundary.outcome; } }; } };
const KEY_SETTINGS = 'app_settings_json';
export const store = { raw: '', puts: 0, flushes: 0, async get() { if (boundary.loadError) throw new Error('read failed'); return this.raw; }, async put(key, value) { if (boundary.saveError) throw new Error('write failed'); this.raw = value; this.puts++; }, async flush() { this.flushes++; } };
export class SettingsService {
  static store = store;
  // 本闸门把 store 当**唯一真源**（用例会直接改写 store.raw 模拟「另一个页面写入」），
  // 所以屏蔽进程内缓存：getter 恒为 null（每次 load 都读盘），setter 丢弃。
  static get cache() { return null; }
  static set cache(_v) {}
  static async init() {}
  static syncRawProviderGate() {} // unrelated raw subscription cleanup boundary
  // 测速快照分片与本闸门无关（闸门验的是路由规则的读写语义）：
  // 桩掉这两个新入口，别让「分片」把规则读写的结论搅进来。
  static async loadNodeSortSnapshot() { return ''; }
  static async routeSnapshotWrite() {}
${method(service, 'load')}
${method(service, 'save').replace('static async save(', 'private static async saveDeferred(')}
  // 闸门不模拟 300ms 防抖窗口（防抖本身由 verify-preference-cache 覆盖）：
  // save() 立即 flushNow，store.puts/flushes 才能在同一次 await 后可观测。
  static scheduleFlush() {}
  static async save(settings) {
    await SettingsService.saveDeferred(settings);
    await SettingsService.flushNow();
  }
${method(service, 'flushNow')}
  // 字段级写入（生产：writeChain 串行 + mutator 拿新鲜 load()）。闸门的 load/save 已是真方法，
  // 这里只需补 writeChain 与 patchSettings 本体，别让页面用到的 API 在桩里缺席。
  static writeChain = Promise.resolve();
${method(service, 'patchSettings')}
}
`;
const code = latencyTestUrlStub + '\n' + sort + '\n' + read('commons/services/AppRoutingPolicy.ets') + '\n' + policy + '\n'
  + settings.replace(/^import .*;\r?\n/gm, '') + '\n' + harness + '\n' + pageClass;
const js = stripTypeScriptTypes(code, { mode: 'strip' });
const mod = await import('data:text/javascript;base64,' + Buffer.from(js).toString('base64'));
const P = mod.SiteRoutingPolicy, A = mod.AppSettings, S = mod.SettingsService;
const B = mod.boundary, store = mod.store;
console.log(`\nSite routing verification${etsArg >= 0 ? ` (--ets ${ets})` : ''}`);
let passed = 0, failed = 0, audits = 0;
const check = async (label, fn) => {
  try { await fn(); passed++; console.log('PASS ' + label); }
  catch (error) { failed++; console.error('FAIL ' + label + '\n  ' + error.message); }
};
const domains = (n, prefix = 'p') => Array.from({ length: n }, (_, i) => `${prefix}${i}.example.com`);
const fresh = async (proxy = [], direct = [], extra = {}, kind = 'proxy') => {
  Object.assign(B, { dialogs: [], toasts: [], backs: 0, applies: [], outcome: 'hot', params: { kind }, loadError: false, saveError: false, applyError: false });
  store.raw = JSON.stringify({ forceProxySites: proxy, forceDirectSites: direct, ...extra });
  store.puts = 0; store.flushes = 0;
  const p = new mod.SiteRoutingPage(); await p.load(); return p;
};
await check('EXEC normalize lowercase, whitespace, root dot, stable dedupe and no mutation', () => {
  const raw = [' EXAMPLE.COM. ', 'example.org', 'example.com'];
  assert.deepEqual(P.normalizeList(raw), ['example.com', 'example.org']);
  assert.deepEqual(raw, [' EXAMPLE.COM. ', 'example.org', 'example.com']);
  assert.deepEqual(P.normalizeList(['', ' ']), ['']);
  assert.deepEqual(P.parseInput(' \r\n EXAMPLE.COM.\r\nexample.com\nexample.org\n'), ['example.com', 'example.org']);
  assert.deepEqual(P.parseInput(' \n\r\n'), []);
});
const badDomains = ['', ' ', '.', 'https://example.com', 'http://example.com', 'example.com/path',
  'example.com:443', '*.example.com', '.example.com', 'a..example.com', '-a.com', 'a-.com',
  'a_b.com', 'example.com?x=1', 'example.com#tag', 'user@example.com', 'example.com,PROXY',
  'example\n.com', 'example.com\n- MATCH,DIRECT', 'example.com\r- MATCH,DIRECT',
  'example.com\u0000', 'example.com\tother.org', 'example.com\u2028- MATCH,DIRECT',
  '"example.com"', 'example.com: [DIRECT]', '中文.cn', '127.0.0.1', '123', '[::1]'];
for (const value of badDomains) {
  await check('EXEC reject invalid/injection domain ' + JSON.stringify(value), () => {
    assert.notEqual(P.domainError(value), '');
    assert.notEqual(P.validationError([value], []), '');
    assert.notEqual(P.validationError([], [value]), '');
    assert.equal(P.normalizeList([value]).length, 1, 'invalid legacy string must remain available for repair');
  });
}
await check('EXEC 1/253 domain and 1/63 label length boundaries', () => {
  const max = [63, 63, 63, 61].map(n => 'a'.repeat(n)).join('.');
  assert.equal(max.length, 253);
  for (const value of ['a', 'a.b', 'a'.repeat(63) + '.com', max, 'xn--fiqs8s.cn']) assert.equal(P.domainError(value), '');
  for (const value of ['a'.repeat(64) + '.com', max + 'a']) assert.notEqual(P.domainError(value), '');
});
await check('EXEC independent 0/1/500/501 list limits, no truncation', () => {
  assert.equal(P.MAX_SITES, 500);
  assert.equal(P.validationError([], []), '');
  assert.equal(P.validationError(['a'], ['b']), '');
  assert.equal(P.validationError(domains(500), domains(500, 'd')), '');
  assert.notEqual(P.validationError(domains(501), []), '');
  assert.notEqual(P.validationError([], domains(501)), '');
  assert.equal(P.normalizeList(domains(501)).length, 501);
  assert.equal(P.normalizeList(Array(501).fill('A.COM.')).length, 1);
  assert.equal(P.validationError(Array(501).fill('A.COM.'), []), '', 'limit counts unique normalized domains');
});
await check('EXEC normalized same-domain conflicts, unrelated and parent/child domains coexist', () => {
  assert.notEqual(P.validationError(['EXAMPLE.COM.'], ['example.com']), '');
  assert.notEqual(P.validationError(P.normalizeList(['EXAMPLE.COM.']), P.normalizeList(['example.com'])), '');
  assert.equal(P.validationError(['example.com'], ['other.org']), '');
  assert.equal(P.validationError(['example.com'], ['sub.example.com']), '');
});
await check('EXEC actual SettingsService repeated saves preserve both lists and bad strings', async () => {
  const proxy = ['bad/path', '', ' EXAMPLE.COM. ', ...domains(501)];
  await fresh(proxy, ['other.org']);
  let previous;
  for (let i = 0; i < 4; i++) {
    const s = await S.load(); assert.deepEqual(s.forceProxySites, proxy); assert.deepEqual(s.forceDirectSites, ['other.org']);
    assert.notEqual(P.validationError(P.normalizeList(s.forceProxySites), s.forceDirectSites), '');
    await S.save(s);
    if (previous) assert.equal(store.raw, previous);
    previous = store.raw;
  }
  assert.equal(store.puts, 4); assert.equal(store.flushes, 4);
});
await check('EXEC page loads independent copies; add/dedupe/filter/select/sort do not persist', async () => {
  const p = await fresh(['z.org', 'A.COM.'], ['direct.org']); const raw = store.raw;
  assert.deepEqual(p.proxy, ['z.org', 'a.com']); assert.equal(p.dirty, false);
  p.toggle('a.com'); assert.deepEqual(p.visible, ['a.com', 'z.org']); assert.equal(p.dirty, false);
  p.selectedOnly = true; p.rebuild(); assert.deepEqual(p.visible, ['a.com']);
  p.query = ' Z.ORG '; p.rebuild(); assert.deepEqual(p.visible, []);
  p.query = ''; p.selectedOnly = false; p.alphabetical = true; p.rebuild();
  assert.deepEqual(p.proxy, ['z.org', 'a.com'], 'view sorting must not reorder rule array');
  assert.equal(p.add('b.org\nB.ORG.\na.com'), true); assert.deepEqual(p.proxy, ['z.org', 'a.com', 'b.org']);
  assert.equal(p.dirty, true); assert.equal(store.raw, raw); assert.equal(store.puts, 0);
  p.switchKind('direct'); assert.deepEqual(p.selected, []); assert.equal(p.selectedOnly, false);
  assert.deepEqual(p.current(), ['direct.org']); assert.deepEqual(p.other(), ['z.org', 'a.com', 'b.org']);
});
await check('EXEC page batch add rejects blank/conflict/injection atomically and accepts newline list', async () => {
  const p = await fresh(['a.com'], ['d.com']);
  for (const value of [' \n ', 'b.com\nD.COM.', 'b.com\nhttps://bad.org', 'b.com\n- MATCH,DIRECT']) {
    assert.equal(p.add(value), false); assert.deepEqual(p.proxy, ['a.com']); assert.equal(p.dirty, false);
  }
  assert.equal(p.add('b.com\r\nc.org'), true); assert.deepEqual(p.proxy, ['a.com', 'b.com', 'c.org']);
  assert.equal(store.puts, 0);
});
await check('EXEC page 500 unique limit permits duplicate import; 501 batch never partly applies', async () => {
  const p = await fresh(domains(499));
  assert.equal(p.add('new.org'), true); assert.equal(p.proxy.length, 500);
  assert.equal(p.add('NEW.ORG.'), true); assert.equal(p.proxy.length, 500);
  assert.equal(p.add('overflow.org\nalso.org'), false); assert.equal(p.proxy.length, 500);
  assert.equal(store.puts, 0);
});
await check('EXEC legacy invalid and cross-list conflicts remain visible until explicitly removed', async () => {
  const p = await fresh(['bad/path', '', 'Same.COM.'], ['same.com']);
  assert.deepEqual(p.proxy, ['bad/path', '', 'same.com']);
  p.add('valid.org'); await p.save(); assert.equal(store.puts, 0); assert.equal(B.dialogs.length, 0);
  B.dialogs.push(1); await p.remove(['bad/path', '', 'same.com']);
  assert.deepEqual(p.proxy, ['valid.org']); assert.deepEqual(p.direct, ['same.com']); assert.equal(store.puts, 0);
});
await check('EXEC removal cancel/confirm, selection cleanup and no persistence', async () => {
  const p = await fresh(['a.com', 'b.com'], ['d.com']); p.toggle('a.com');
  B.dialogs.push(0); await p.remove(['a.com']); assert.deepEqual(p.proxy, ['a.com', 'b.com']);
  B.dialogs.push(1); await p.remove(['a.com']); assert.deepEqual(p.proxy, ['b.com']); assert.deepEqual(p.selected, []);
  assert.equal(p.dirty, true); assert.deepEqual(p.direct, ['d.com']); assert.equal(store.puts, 0);
});
await check('EXEC back discard/cancel never saves; selected-only navigation is clean', async () => {
  const p = await fresh(['a.com']); p.toggle('a.com'); await p.back(); assert.equal(B.backs, 1);
  p.add('b.com'); B.dialogs.push(0); await p.back(); assert.equal(B.backs, 1);
  B.dialogs.push(1); await p.back(); assert.equal(B.backs, 2); assert.equal(store.puts, 0);
  const reopened = new mod.SiteRoutingPage(); await reopened.load(); assert.deepEqual(reopened.proxy, ['a.com']);
});
await check('EXEC save re-loads current unrelated fields, updates both lists, repeat save is no-op', async () => {
  const p = await fresh(['a.com'], ['d.com']); p.add('b.com'); p.switchKind('direct'); p.add('e.com');
  const external = await S.load(); external.themeMode = 2; external.preferredNodeId = 'changed-elsewhere';
  store.raw = JSON.stringify(external.toJson());
  B.dialogs.push(1); await p.save();
  const saved = await S.load(); assert.deepEqual(saved.forceProxySites, ['a.com', 'b.com']);
  assert.deepEqual(saved.forceDirectSites, ['d.com', 'e.com']); assert.equal(saved.themeMode, 2);
  assert.equal(saved.preferredNodeId, 'changed-elsewhere'); assert.equal(store.puts, 1); assert.equal(p.dirty, false);
  assert.deepEqual(B.applies, []); await p.save(); assert.equal(store.puts, 1);
});
await check('EXEC save cancellation and concurrent site modification preserve stored rules', async () => {
  const p = await fresh(['a.com']); p.add('b.com'); B.dialogs.push(0); await p.save();
  assert.equal(store.puts, 0); assert.equal(p.dirty, true); assert.equal(p.busy, false);
  const external = await S.load(); external.forceDirectSites = ['external.org']; store.raw = JSON.stringify(external.toJson());
  B.dialogs.push(1); await p.save(); assert.equal(store.puts, 0); assert.equal(p.dirty, true);
  assert.deepEqual((await S.load()).forceDirectSites, ['external.org']);
});
for (const outcome of ['hot', 'reconnect', 'none', 'ad-unavailable', 'pending', 'throw']) {
  await check('EXEC save/apply boundary outcome ' + outcome + ' keeps saved data', async () => {
    const p = await fresh([], [], { proxyMode: 'global' }); p.add('a.com');
    B.outcome = outcome; B.applyError = outcome === 'throw'; B.dialogs.push(2); await p.save();
    assert.deepEqual(B.applies, ['forceSitesChanged']); assert.equal(store.puts, 1); assert.equal(p.dirty, false);
    assert.deepEqual((await S.load()).forceProxySites, ['a.com']); assert.equal(p.busy, false);
    assert.match(p.notice, /全局模式/);
    assert.match(p.notice, outcome === 'hot' ? /热更新/ : outcome === 'reconnect' ? /重连/
      : outcome === 'ad-unavailable' ? /广告规则尚未下载.*手动更新/ : outcome === 'pending' ? /另一规则更新进行中/
      : outcome === 'throw' ? /应用失败/ : /下次连接/);
  });
}
await check('EXEC storage failure leaves draft dirty and does not call apply', async () => {
  const p = await fresh(['a.com']); p.add('b.com'); B.saveError = true; B.dialogs.push(2); await p.save();
  assert.equal(p.dirty, true); assert.equal(p.busy, false); assert.equal(store.puts, 0); assert.deepEqual(B.applies, []);
  B.saveError = false;
});
await check('EXEC load failure prevents editing save from clobbering settings', async () => {
  await fresh(['a.com']); B.loadError = true; const p = new mod.SiteRoutingPage(); await p.load();
  assert.equal(p.ready, false); assert.equal(p.busy, false); await p.save(); assert.equal(store.puts, 0); B.loadError = false;
});
const save = method(page, 'save'), back = method(page, 'back');
await check('SOURCE saving validates then patch-writes the three site lists before apply', () => {
  assert.ok(save.indexOf('SiteRoutingPolicy.validationError(') < save.indexOf('SettingsService.patchSettings('));
  // 并发三向比较必须在**写锁内**（mutator 里）做：load 预检与写入之间的窗口就是 F2 本身。
  assert.ok(save.indexOf('SettingsService.patchSettings(') < save.indexOf('JSON.stringify(current.forceProxySites)'),
    'three-way concurrent-edit guard must run inside the patch mutator, not before it');
  assert.ok(save.indexOf('JSON.stringify(current.forceProxySites)') < save.indexOf('current.forceProxySites ='),
    'guard must reject before any field is assigned');
  // 0.4.0 起网站规则是三态（代理 / 直连 / 拦截）：保存必须同时写三份名单，
  // 漏写任何一份都会让该态规则在下次启动后静默丢失。
  assert.deepEqual([...save.matchAll(/\bcurrent\.(\w+)\s*=(?!=)/g)].map(m => m[1]).sort(),
    ['forceBlockSites', 'forceDirectSites', 'forceProxySites']);
  // 冲突时 mutator 返回 false ⇒ patchSettings 不写盘（不只是“不生效”，而是真的不发那个写）。
  assert.match(save, /return false;/);
  assert.ok(!save.includes('SettingsService.save('), 'page must not hold a whole-object save()');
  assert.ok(save.indexOf('await SettingsService.patchSettings(') < save.indexOf('applyRulesChanged('));
  assert.match(save, /result\.index === 2/); assert.ok(!save.includes('restartIfConnected('));
  assert.ok(save.includes('this.originalProxy') && save.includes('this.originalDirect')
    && save.includes('this.originalBlock'), 'three-way concurrent-edit guard must cover the block list too');
});
await check('SOURCE discard and hardware back are guarded and never persist', () => {
  assert.match(back, /if \(!this\.dirty\)/); assert.match(back, /result\.index === 1/);
  assert.ok(!back.includes('SettingsService.save')); assert.ok(!back.includes('applyRulesChanged'));
  assert.match(page, /onBackPress\(\): boolean \{ this\.back\(\); return true; \}/);
});
await check('SOURCE failed hot reload preserves the current session without reconnect fallback', () => {
  assert.match(method(orchestrator, 'applyRulesChanged'), /this\.applyRulesChangedNow\(reason, seq, generation\)/);
  const apply = method(orchestrator, 'applyRulesChangedNow');
  assert.ok(apply.includes('reloadRulesHot(reason)'));
  assert.match(apply, /if \(hot\) \{\s*return adUnavailable \? 'ad-unavailable' : 'hot';/);
  assert.ok(!apply.includes('restartIfConnected(reason)'));
  assert.ok(apply.includes("return 'apply-failed'"));
});
await check('SOURCE generator emits all three lists, direct before proxy, and suffix semantics', () => {
  assert.ok(generator.includes('normalizeDomains(settings.forceDirectSites)'));
  assert.ok(generator.includes('normalizeDomains(settings.forceProxySites)'));
  // 第三态（拦截）在 DNS 层单独出 REJECT 预匹配规则，漏掉就等于该态配置无效。
  assert.ok(generator.includes('normalizeDomains(settings.forceBlockSites)'));
  assert.ok(generator.indexOf('DOMAIN-SUFFIX,${site},DIRECT') < generator.indexOf('DOMAIN-SUFFIX,${site},PROXY'));
  assert.ok(generator.includes('if (!directSites.includes(site))'));
  assert.ok(page.includes('勾选仅用于批量操作，不是启用开关'));
});
await check('SOURCE network entries live in SettingsPage and target registered existing pages', () => {
  const routes = JSON.parse(readFileSync(resolve(root, 'entry/src/main/resources/base/profile/main_pages.json'), 'utf8')).src;
  for (const route of ['pages/SiteRoutingPage', 'pages/AppRoutingPage', 'pages/RulesPage', 'pages/NodeSelectionPage']) {
    assert.ok(routes.includes(route), route + ' registered'); assert.ok(existsSync(resolve(ets, route + '.ets')), route + ' exists');
  }
  assert.ok(!routes.includes('pages/NetworkRulesPage'), 'obsolete transparent router page removed from main_pages.json');
  // 0.4.0 重排：网络规则入口从主页「网络规则」弹窗统一收进设置页（单一事实来源），
  // 主页不再维护第二份入口/编辑状态；SiteRoutingPage 同时改为页面内三态切换
  // （代理/直连/拦截），不再靠 pushUrl 的 kind 参数分流。
  const settingsPage = read('pages/SettingsPage.ets');
  assert.match(settingsPage, /router\.pushUrl\(\{ url: 'pages\/AppRoutingPage' \}\)/);
  assert.match(settingsPage, /router\.pushUrl\(\{ url: 'pages\/SiteRoutingPage' \}\)/);
  assert.match(settingsPage, /\.onClick\(\(\) => \{ this\.openRulesPage\(\); \}\)/);
  const openRules = method(settingsPage, 'openRulesPage');
  assert.ok(openRules.indexOf('await SettingsService.load()') < openRules.indexOf('router.pushUrl('));
  assert.match(openRules, /router\.pushUrl\(\{ url: 'pages\/RulesPage', params: params \}\)/);
  assert.match(settingsPage, /Text\('应用分流'\)/);
  // 三态切换与三份名单都在 SiteRoutingPage 内闭环
  assert.match(page, /private switchKind\(kind: string\): void \{/);
  assert.match(page, /forceBlockSites/);
  // 主页不得再出现第二份网络规则入口
  assert.ok(!network.includes('NetworkRulesDialog'), 'HomePage must not duplicate the network rules surface');
  assert.ok(!network.includes("url: 'pages/NetworkRulesPage'"));
});
// 0.4.0 统一转场（见 theme/TunBoxTokens.ets 的 TunBoxMotion）：被推入的子页必须用
// **同一套**转场令牌，禁止各页自带时长/曲线，也禁止命令式 animateTo —— 否则同一
// 手势在不同页面会有不同手感，深浅色/动效开关也没法统一治理。
const unifiedMotion = (source, label) => {
  assert.match(source, /pageTransition\(\) \{/, label + ' must declare the unified page transition');
  assert.match(source, /PageTransitionEnter\(\{ duration: TunBoxMotion\.ms, curve: TunBoxMotion\.curve \}\)/,
    label + ' enter transition must use TunBoxMotion tokens');
  assert.match(source, /PageTransitionExit\(\{ duration: TunBoxMotion\.ms, curve: TunBoxMotion\.curve \}\)/,
    label + ' exit transition must use TunBoxMotion tokens');
  assert.match(source, /TunBoxMotion\.slidePercent/, label + ' must slide by the shared percentage token');
  assert.doesNotMatch(source, /\banimateTo\s*\(/, label + ' must not use imperative animateTo');
};
await check('SOURCE Site/App pages share the unified TunBoxMotion transition', () => {
  unifiedMotion(page, 'SiteRoutingPage');
  unifiedMotion(read('pages/AppRoutingPage.ets'), 'AppRoutingPage');
});
if (process.argv.includes('--defer-home-node')) {
  console.log('DEFER SOURCE Home/Node agent-owned entries and transitions: parent must run without --defer-home-node after agent completion.');
} else {
  await check('SOURCE HomePage keeps no duplicate rules surface and no push transition', () => {
    const home = read('pages/HomePage.ets');
    // 主页是根页签页，不做推入转场；网络规则入口已收进设置页，这里不得回流副本。
    assert.doesNotMatch(home, /\bpageTransition\s*\(/, 'root tab page must not declare a push transition');
    assert.doesNotMatch(home, /\banimateTo\s*\(/);
    assert.ok(!home.includes('struct NetworkRulesDialog'), 'network rules dialog must stay in SettingsPage only');
    assert.ok(!home.includes('struct RulesCard'), 'standalone rules card merged into the rules page');
    assert.ok(!home.includes("url: 'pages/NetworkRulesPage'"));
    assert.ok(!home.includes("url: 'pages/SettingsPage'"), 'settings entry lives in the tab bar, not a route');
    assert.doesNotMatch(home, /promptAction\.showActionMenu\(/, 'proxy mode uses themed CustomDialog, not black system menu');
  });
  await check('SOURCE NodeSelection shares the unified TunBoxMotion transition with AppRouting',
    () => unifiedMotion(read('pages/NodeSelectionPage.ets'), 'NodeSelectionPage'));
}
// These are existing data-model boundary limitations, not a substituted
// expected implementation. Report observed defects separately from scoped gates.
for (const malformed of [null, 7, 'bad/path', [null], [123], [{}]]) {
  const s = A.fromJson({ forceProxySites: malformed });
  if (s.forceProxySites.length === 0) { audits++; console.warn('AUDIT existing AppSettings drops malformed legacy site value: ' + JSON.stringify(malformed)); }
}
console.log(`\nSite routing verification: ${passed} passed, ${failed} failed, ${audits} non-gating AUDIT findings (EXEC and SOURCE are distinct; no device/build verification).`);
if (failed > 0) process.exitCode = 1;
