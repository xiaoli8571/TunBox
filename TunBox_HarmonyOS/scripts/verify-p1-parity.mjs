#!/usr/bin/env node
/**
 * P1 对齐闸门（Profile Editor / Per-profile Override / DNS Query View）
 *
 * ## 覆盖什么
 * 1. 配置编辑器：整份 YAML 走 `validateAndStore`（与导入同一条校验管线），
 *    保存后 `ensureProfileApplied` 热重载；失败保留旧文件。
 * 2. 每订阅 Override：FlClash `Profile.overrides` 的等价物 —— 按 profile 存、
 *    按 profile 合并，绝不写回全局 yamlOverride（否则 A 的覆盖会扩散到 B/C）。
 * 3. DNS 查询视图：只读 `/logs` 流、按 DNS 行过滤，不落盘、不改内核。
 *
 * ## 断言
 *  A. 生产文件存在且接线正确（源码级不变量）
 *  B. `ProfileOverrideStore.effective` 行为：无覆盖时回落全局；有覆盖时优先
 *  C. 页面注册与入口（main_pages.json / SettingsPage）
 *
 * 退出码：0 = 全过；1 = 有断言失败。
 */
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const src = path.join(root, 'entry/src/main/ets');
const read = (p) => fs.readFileSync(path.join(src, p), 'utf8');

let passed = 0;
const failures = [];
function ok(name, condition) {
  if (condition) {
    passed += 1;
    console.log(`PASS ${name}`);
  } else {
    failures.push(name);
    console.log(`FAIL ${name}`);
  }
}

// ── A. 生产文件接线 ──────────────────────────────────────────────────
const editor = read('pages/ProfileEditorPage.ets');
const store = read('commons/services/ProfileOverrideStore.ets');
const dns = read('pages/DnsQueryPage.ets');
const builder = read('commons/config/RuntimeConfigBuilder.ets');
const orch = read('commons/services/ConnectionOrchestrator.ets');
const subs = read('commons/services/SubscriptionService.ets');
const settings = read('pages/SettingsPage.ets');
const pages = fs.readFileSync(path.join(root, 'entry/src/main/resources/base/profile/main_pages.json'), 'utf8');

ok('editor.exists', editor.includes('struct ProfileEditorPage'));
ok('editor.validates-before-save', editor.includes('ProfileRepository.validateAndStore(this.profileId, body)'));
ok('editor.hot-applies', editor.includes("this.orchestrator.ensureProfileApplied('profile-editor')"));
ok('editor.persists-override', editor.includes('ProfileOverrideStore.set(this.profileId, this.overrideText)'));
ok('editor.never-writes-global', !editor.includes('settings.yamlOverride ='));

ok('store.per-profile-key', store.includes('ProfileOverrideStore.cache.set(profileId'));
ok('store.effective-precedence',
  /static effective\(profileId: string, fallback: string\): string \{[\s\S]*?return own\.length > 0 \? own : fallback;/.test(store));
ok('store.rejects-oversize', store.includes('trimmed.length > MAX_CHARS'));

ok('builder.field', builder.includes('overrideYaml: string = '));
ok('builder.prefers-profile-override',
  builder.includes('profile.overrideYaml.length > 0')
  && builder.includes('? profile.overrideYaml : (profile.settings.yamlOverride ?? \'\')'));
ok('orchestrator.injects-override',
  orch.includes("profile.overrideYaml = ProfileOverrideStore.effective(profileId, '')"));
ok('subs.initialises-store', subs.includes('await ProfileOverrideStore.init(context);'));

ok('dns.subscribes-log-stream', dns.includes('this.stream.addListener(this.listener)'));
ok('dns.filters-dns-lines', dns.includes("line.text.toLowerCase().includes('dns')"));
ok('dns.no-persistence', !dns.includes('fs.') && !dns.includes('preferences.'));

ok('pages.registered',
  pages.includes('"pages/ProfileEditorPage"') && pages.includes('"pages/DnsQueryPage"'));
ok('settings.editor-entry', settings.includes("router.pushUrl({ url: 'pages/ProfileEditorPage' })"));
ok('settings.dns-entry', settings.includes("router.pushUrl({ url: 'pages/DnsQueryPage' })"));

// ── B. effective 行为（执行生产 .ets，只替换 preferences/AppLogger 边界）──
const ctx = vm.createContext({
  console, Map, JSON, Set,
  preferences: { async getPreferences() { return { async get() { return ''; }, async put() {}, async flush() {} }; } },
  AppLogger: { info() {}, warn() {}, errText: String }
});
const code = store
  .replace(/^import\b[\s\S]*?;\r?\n/gm, '')
  .replace(/^export /gm, '');
const { ProfileOverrideStore } = vm.runInContext(
  stripTypeScriptTypes(`(()=>{${code}\nreturn {ProfileOverrideStore}})()`, { mode: 'transform' }), ctx);

ok('store.effective-fallback', ProfileOverrideStore.effective('p1', 'global') === 'global');
ok('store.effective-empty-id', ProfileOverrideStore.effective('', 'global') === 'global');
ok('store.max-chars', ProfileOverrideStore.maxChars() === 8192);
ok('store.get-empty', ProfileOverrideStore.get('p1') === '');

// ── C. 负对照：这三项不得被"省事"简化掉 ─────────────────────────────
ok('contrast.no-global-write-in-editor', !editor.includes('AppSettings'));
ok('contrast.dns-does-not-open-tun', !dns.includes('VpnExtension'));
ok('contrast.override-not-silently-truncated',
  store.includes('return false;') && !store.includes('substring(0, MAX_CHARS)'));

console.log(`\nP1 对齐闸门：${passed} passed, ${failures.length} failed`);
if (failures.length > 0) {
  console.log(`FAILED: ${failures.join(', ')}`);
  process.exit(1);
}
