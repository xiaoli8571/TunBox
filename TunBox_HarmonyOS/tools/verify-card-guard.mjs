#!/usr/bin/env node
/**
 * node tools/verify-card-guard.mjs (Node 24+)
 * EXEC: VpnGuardianPolicy 真实源码（stripTypeScriptTypes 执行）。
 * SOURCE: 卡片→守护宿主的结构不变量（静态断言，非设备验证）。
 * 背景：真机日志实证 Form 宿主回收后 :vpn 连带被系统回收（exit 0），
 * 修复 = 卡片点击 router 到 QuickToggleAbility 并在其中注册 dataTransfer 连续任务。
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
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

// ── EXEC: 真策略执行 ────────────────────────────────────────────────
const src = stripTypeScriptTypes(read('entry/src/main/ets/commons/services/VpnGuardianPolicy.ets'), { mode: 'strip' })
  .replace(/^export\s+class\s+VpnGuardianPolicy\b/m, 'class VpnGuardianPolicy');
const mod = { exports: {} };
new Function('exports', src + '\nexports.VpnGuardianPolicy = VpnGuardianPolicy;')(mod.exports);
const P = mod.exports.VpnGuardianPolicy;

await check('EXEC shouldGuard only for live-session outcomes', () => {
  assert.equal(P.shouldGuard('on'), true);
  assert.equal(P.shouldGuard('already'), true);
  for (const r of ['off', 'failed', 'no_node', '', 'disconnect-requested', 'ON']) assert.equal(P.shouldGuard(r), false, r);
});
await check('EXEC lease-loss release needs threshold reached and positive threshold', () => {
  assert.equal(P.shouldReleaseOnLeaseLoss(2, 2), true);
  assert.equal(P.shouldReleaseOnLeaseLoss(1, 2), false);
  assert.equal(P.shouldReleaseOnLeaseLoss(5, 0), false);
});
await check('EXEC normalizeMisses clamps garbage safely', () => {
  assert.equal(P.normalizeMisses(-3), 0);
  assert.equal(P.normalizeMisses(NaN), 0);
  assert.equal(P.normalizeMisses(3.7), 3);
  assert.equal(P.normalizeMisses(4), 4);
});

// ── SOURCE: 结构不变量 ─────────────────────────────────────────────
const toggleCard = read('entry/src/main/ets/widget/ToggleCard.ets');
const infoCard = read('entry/src/main/ets/widget/InfoCard.ets');
const guard = read('entry/src/main/ets/quicktoggleability/QuickToggleAbility.ets');
const uiGuardian = read('entry/src/main/ets/commons/services/UiGuardian.ets');
const ext = read('entry/src/main/ets/vpnability/VpnExtensionAbility.ets');
const manifest = JSON.parse(read('entry/build/default/intermediates/process_profile/default/module.json')
  .replace(/^\uFEFF/, ''));

await check('SOURCE both cards route toggle to QuickToggleAbility (no in-form connect)', () => {
  for (const card of [toggleCard, infoCard]) {
    assert.ok(card.includes("'abilityName': 'QuickToggleAbility'"), 'router target');
    assert.ok(card.includes("'vpn_shortcut': 'toggle'"), 'toggle param');
    assert.ok(!card.includes("'command': 'toggle'"), card.includes("'command': 'toggle'") ? 'legacy message must go' : '');
  }
});
await check('SOURCE guardian delegates task negotiation and releases its UIAbility task', () => {
  assert.ok(guard.includes('UiGuardian.applyContinuousTask(this.context)'), 'UIAbility context reaches the shared registration path');
  assert.ok(uiGuardian.includes("['dataTransfer']"), 'DATA_TRANSFER fallback stays in the shared path');
  assert.ok(uiGuardian.includes('backgroundTaskManager.startBackgroundRunning(context'), 'shared UIAbility registration');
  assert.ok(guard.includes('stopBackgroundRunning(this.context'), 'release path');
  assert.ok(guard.includes('VpnGuardianPolicy.shouldGuard'), 'policy-driven guard decision');
  assert.ok(guard.includes('authorityState'), 'lease polling via cross-process authority');
  assert.ok(guard.includes('clearLifetimeGuard'), 'guardian disarms lifetime guard');
  assert.ok(guard.includes('retreatToDesktop') && guard.includes('.minimize()'), 'guardian auto-retreats to desktop');
  assert.ok(guard.indexOf('retreatToDesktop();') > guard.indexOf('armGuardianPoll();'),
    'retreat runs after guardian registration succeeds');
});
await check('SOURCE guardian releases on non-guard outcomes', () => {
  assert.ok(guard.includes("releaseGuardian('action-' + outcome)") || guard.includes('releaseGuardian(\'action-\n'), 'non-guard result releases');
});
await check('SOURCE extension no longer requests or tracks continuous task', () => {
  assert.doesNotMatch(ext, /startBackgroundRunning|TASK_KEEPING|backgroundRunning/, 'extension must be task-free');
  assert.doesNotMatch(ext, /@ohos.resourceschedule.backgroundTaskManager|@ohos.app.ability.wantAgent/, 'dead imports removed');
});
await check('SOURCE built profile declares QuickToggleAbility backgroundModes dataTransfer', () => {
  const ability = manifest.module.abilities.find(a => a.name === 'QuickToggleAbility');
  assert.ok(ability, 'declared in built profile');
  assert.ok(Array.isArray(ability.backgroundModes) && ability.backgroundModes.includes('dataTransfer'), 'backgroundModes present');
});

console.log(`\nCard-guard verification: ${passed} passed, ${failed} failed (EXEC real policy + SOURCE static; no device verification).`);
if (failed > 0) process.exitCode = 1;
