#!/usr/bin/env node
/**
 * node tools/verify-review-fixes-2026-10-07.mjs (Node 24+)
 * 2026-10 官方手册对照评审的修复不变量（SOURCE 级静态断言；无 SDK 执行）。
 * 覆盖：长时任务取消监听 / dataTransfer 进度心跳 / 用户停止抑制态 / 通知点击动作 /
 *       凭据缓存去明文 / 官方 VPN 错误码补全 / protect 轮询自适应 / 权限最小化。
 * 对应记录文档：REVIEW_FIXES_2026-10-07.md（回退指引见该文档）。
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const read = p => readFileSync(resolve(root, p), 'utf8');
let passed = 0; let failed = 0;
const check = (name, fn) => {
  try { fn(); passed++; console.log('PASS ' + name); }
  catch (e) { failed++; console.log('FAIL ' + name + ' -> ' + e.message); }
};

const watch = read('entry/src/main/ets/commons/services/BackgroundTaskWatch.ets');
const updater = read('entry/src/main/ets/commons/services/TaskProgressUpdater.ets');
const guardian = read('entry/src/main/ets/commons/services/UiGuardian.ets');
const toggle = read('entry/src/main/ets/quicktoggleability/QuickToggleAbility.ets');
const entry = read('entry/src/main/ets/entryability/EntryAbility.ets');
const home = read('entry/src/main/ets/pages/HomePage.ets');
const notifier = read('entry/src/main/ets/commons/services/TunBoxNotifier.ets');
const cred = read('entry/src/main/ets/commons/services/CredentialStore.ets');
const sub = read('entry/src/main/ets/commons/services/SubscriptionService.ets');
const ext = read('entry/src/main/ets/vpnability/VpnExtensionAbility.ets');
const pol = read('entry/src/main/ets/commons/services/VpnRecoveryPolicy.ets');
const manifest = read('entry/src/main/module.json5');

check('task cancel listener registered idempotently in both entry abilities', () => {
  assert.ok(watch.includes("backgroundTaskManager.on('continuousTaskCancel'"), 'event subscription');
  assert.ok(watch.includes('ContinuousTaskCancelInfo'), 'typed callback');
  assert.ok(entry.includes('BackgroundTaskWatch.ensure()'), 'EntryAbility registers');
  assert.ok(toggle.includes('BackgroundTaskWatch.ensure()'), 'QuickToggleAbility registers');
});
check('task cancel handling never auto re-registers the task', () => {
  assert.ok(watch.includes('UiGuardian.noteExternalCancel()'), 'bookkeeping refresh');
  assert.ok(watch.includes('TaskProgressUpdater.detach()'), 'progress heartbeat stop');
  assert.ok(!watch.includes('startBackgroundRunning'), 'watch must not re-apply');
  assert.ok(guardian.includes('autoEngageSuppressed'), 'suppression state');
  assert.ok(guardian.includes('clearExternalCancelSuppression'), 'explicit-action clearing');
});
check('explicit user actions clear the suppression', () => {
  assert.ok(toggle.includes('UiGuardian.clearExternalCancelSuppression()'), 'card/shortcut host');
  assert.ok(home.includes('UiGuardian.clearExternalCancelSuppression()'), 'home page actions');
});
check('dataTransfer progress heartbeat uses the official downloadTemplate channel', () => {
  assert.ok(updater.includes("'downloadTemplate'"), 'template name');
  assert.ok(updater.includes('TYPE_CODE_DATA_TRANSFER: number = 8'), 'typeCode 8');
  assert.ok(updater.includes('SlotType.LIVE_VIEW'), 'live-view slot');
  assert.ok(updater.includes('NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW'), 'system live view content');
  assert.ok(updater.includes('UPDATE_INTERVAL_MS: number = 5 * 60 * 1000'), '5min < 10min window');
  assert.ok(guardian.includes('TaskProgressUpdater.attach('), 'attached on manual path');
  assert.ok(toggle.includes('TaskProgressUpdater.attach('), 'attached on card path');
});
check('vpn notification carries a click action back to EntryAbility', () => {
  assert.ok(notifier.includes('wantAgent.getWantAgent'), 'wantAgent built');
  assert.ok(notifier.includes("abilityName: 'EntryAbility'"), 'target ability');
  assert.ok(notifier.includes('request.wantAgent = agent'), 'request wiring');
});
check('credential alias cache persists markers only (no values)', () => {
  assert.ok(cred.includes('knownAliases'), 'marker set');
  assert.ok(cred.includes('hydrateKnownAliases'), 'per-alias hydration');
  const exportFn = cred.slice(cred.indexOf('static exportAliasCache'), cred.indexOf('static importAliasCache'));
  assert.ok(exportFn.length > 0 && !exportFn.includes('pair[1]'), 'no values exported');
  assert.ok(exportFn.includes("return '[]'"), 'batch-capable firmware exports empty');
  const importFn = cred.slice(cred.indexOf('static importAliasCache'), cred.indexOf('private static async hydrateKnownAliases'));
  assert.ok(importFn.length > 0 && !importFn.includes('aliasCache.set'), 'legacy values discarded on import');
  assert.ok(sub.includes('await this.credStore.put(KEY_ALIAS_CACHE, CredentialStore.exportAliasCache())'), 'markers rewritten');
});
check('official VPN error codes all mapped', () => {
  for (const c of [2200001, 2200002, 2200003, 2203001, 2203002, 2203004, 19900001, 19900002]) {
    assert.ok(pol.includes('code === ' + c), 'friendly covers ' + c);
  }
});
check('protect polling is adaptive (idle backoff, hit resets to base)', () => {
  assert.ok(ext.includes('PROTECT_POLL_BASE_MS'), 'base constant');
  assert.ok(ext.includes('PROTECT_POLL_MAX_MS'), 'cap constant');
  assert.ok(ext.includes('this.protectPollDelayMs = drained > 0'), 'adaptive update');
  assert.ok(ext.includes('scheduleProtectTick'), 'rescheduling chain');
  assert.ok(!ext.includes('protectTimer = setInterval('), 'old fixed-interval monitor gone');
});
check('permission minimalisation: GET_BUNDLE_INFO removed', () => {
  assert.ok(!manifest.includes('"name": "ohos.permission.GET_BUNDLE_INFO"'), 'permission not declared');
  assert.ok(manifest.includes('getBundleInfoForSelfSync'), 'rationale documented');
});

console.log(`\nReview-fixes verification: ${passed} passed, ${failed} failed (SOURCE static; no device verification).`);
if (failed > 0) process.exitCode = 1;
