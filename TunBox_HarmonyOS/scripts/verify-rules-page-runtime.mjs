// Real page lifecycle/save methods with storage, timers and ArkUI boundaries mocked.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { deferred, flush } from './orchestrator-runtime-harness.mjs';

const source = fs.readFileSync(new URL('../entry/src/main/ets/pages/RulesPage.ets', import.meta.url), 'utf8')
  .replace(/\r\n/g, '\n');
const settingsSource = fs.readFileSync(new URL('../entry/src/main/ets/pages/SettingsPage.ets', import.meta.url), 'utf8')
  .replace(/\r\n/g, '\n');
const modelSource = fs.readFileSync(new URL('../entry/src/main/ets/commons/models/RulesEditorSnapshot.ets', import.meta.url), 'utf8')
  .replace(/^import\b[^\n]*\r?\n/gm, '').replace(/^export /gm, '');
function method(name, text = source) {
  const pattern = new RegExp('^  (?:private )?(?:async )?' + name + '\\([^\\n]*\\{[\\s\\S]*?^  \\}', 'm');
  const m = text.match(pattern); assert.ok(m, name); return m[0];
}
function fixture(enabled = true) {
  const h = { gate: deferred(), writes: 0, applies: 0, notices: [], navigations: [], loads: 0, settings: {
    rulesEnabled: true, hyperAdRulesEnabled: enabled, customRules: [], customRuleSets: [], yamlOverride: ''
  } };
  const timers = new Map(); let timer = 0;
  const context = vm.createContext({
    AppSettings: { normalizeRuleSets: items => items.map(x => ({ ...x })) },
    SettingsService: { async init() {}, async load() { h.loads++; await h.gate.promise;
      if (h.loadError) throw new Error('read'); return { ...h.settings }; },
      async patchSettings() { h.writes++; } },
    promptAction: { showToast: t => h.notices.push(t.message) }, getContext: () => ({}),
    setTimeout(fn) { timers.set(++timer, fn); return timer; }, clearTimeout(id) { timers.delete(id); },
    router: { async pushUrl(args) { h.navigations.push(args); } }
  });
  Object.assign(context, vm.runInContext(stripTypeScriptTypes('(() => {' + modelSource
    + '; return {RulesEditorSnapshot, RulesPageParams}; })()', { mode: 'transform' }), context));
  const code = 'class Page { settingsReady = false; bootstrapEpoch = 0; bootstrapTimer = -1;'
    + 'shownBridge = undefined; initialRules = null; hyperAdRulesEnabled = false; rulesEnabled = true;'
    + 'refreshRuleErrors() {}\n'
    + ['bootstrap', 'applyInitialRules', 'scheduleBootstrap', 'aboutToAppear', 'aboutToDisappear', 'save']
      .map(name => method(name)).join('\n')
    + '\n} Page';
  const Page = vm.runInContext(stripTypeScriptTypes(code, { mode: 'transform' }), context);
  const p = new Page(); p.orchestrator = { async applyRulesChanged() { h.applies++; return 'hot'; } };
  const SettingsPage = vm.runInContext(stripTypeScriptTypes('class SettingsPage { openingRules = false;'
    + method('openRulesPage', settingsSource) + '} SettingsPage', { mode: 'transform' }), context);
  return Object.assign(h, { p, timers, settingsPage: new SettingsPage() });
}
let passed = 0;
async function test(name, fn) { await fn(); passed++; console.log('PASS ' + name); }
await test('saved-on state is loaded before the switch becomes renderable', async () => {
  const h = fixture(), task = h.p.bootstrap(); await flush();
  assert.equal(h.p.settingsReady, false); h.gate.resolve(); await task;
  assert.equal(h.p.settingsReady, true); assert.equal(h.p.hyperAdRulesEnabled, true);
  assert.equal(h.writes, 0); assert.equal(h.applies, 0);
});
await test('saved-off state remains off when loading completes', async () => {
  const h = fixture(false), task = h.p.bootstrap(); h.gate.resolve(); await task;
  assert.equal(h.p.settingsReady, true); assert.equal(h.p.hyperAdRulesEnabled, false);
});
await test('save cannot persist default values before settings are ready', async () => {
  const h = fixture(); await h.p.save(); assert.equal(h.writes, 0); assert.equal(h.applies, 0);
});
await test('leaving during a storage read discards the late result', async () => {
  const h = fixture(), task = h.p.bootstrap(); await flush(); h.p.aboutToDisappear();
  h.gate.resolve(); await task; assert.equal(h.p.settingsReady, false);
  assert.equal(h.p.hyperAdRulesEnabled, false); assert.equal(h.writes, 0);
});
await test('a prepared editor never hides or disables its controls on a repeated show', async () => {
  const h = fixture(); h.p.settingsReady = true; h.p.hyperAdRulesEnabled = true;
  h.p.scheduleBootstrap(); assert.equal(h.timers.size, 0);
  assert.equal(h.p.settingsReady, true); assert.equal(h.p.hyperAdRulesEnabled, true);
  assert.equal(h.writes, 0); assert.equal(h.applies, 0);
});
await test('settings are read before navigation and consumed synchronously before the editor builds', async () => {
  const h = fixture(), task = h.settingsPage.openRulesPage(); await flush();
  assert.equal(h.navigations.length, 0); h.gate.resolve(); await task;
  assert.equal(h.navigations.length, 1);
  h.p.initialRules = h.navigations[0].params.initialRules;
  h.p.shownBridge = { setShowHandler(fn) { if (fn) fn(); } };
  h.p.aboutToAppear(); assert.equal(h.p.settingsReady, true);
  assert.equal(h.p.hyperAdRulesEnabled, true); assert.equal(h.timers.size, 0);
  assert.equal(h.loads, 1); assert.equal(h.writes, 0); assert.equal(h.applies, 0);
});
await test('saved-off and disabled-rule values are ready on the initial frame too', async () => {
  const h = fixture(false); h.settings.rulesEnabled = false;
  h.gate.resolve(); await h.settingsPage.openRulesPage();
  h.p.initialRules = h.navigations[0].params.initialRules; h.p.aboutToAppear();
  assert.equal(h.p.settingsReady, true); assert.equal(h.p.hyperAdRulesEnabled, false);
  assert.equal(h.p.rulesEnabled, false); assert.equal(h.timers.size, 0);
});
await test('repeated taps share one preparation and failed reads never open default controls', async () => {
  const h = fixture(); h.loadError = true;
  const a = h.settingsPage.openRulesPage(), b = h.settingsPage.openRulesPage();
  await flush(); assert.equal(h.loads, 1); h.gate.resolve(); await Promise.all([a, b]);
  assert.equal(h.navigations.length, 0); assert.equal(h.settingsPage.openingRules, false);
  h.loadError = false; await h.settingsPage.openRulesPage(); assert.equal(h.navigations.length, 1);
});
await test('loading gates the complete editor with no late enable effect on save or scroll (source guard)', async () => {
  assert.match(source, /if \(this.settingsReady\) \{\s*TopNavBar/);
  assert.ok(!source.includes('.enabled(this.settingsReady)'));
  assert.equal((source.match(/Toggle\(\{ type: ToggleType.Switch/g) || []).length, 2);
  assert.match(source, /RulesView\(\{ shownBridge: this.bridge, initialRules: this.initialRules \}\)/);
});
console.log(JSON.stringify({ passed, failed: 0, scope: 'lifecycle behavior and source guards; no device animation test' }));
