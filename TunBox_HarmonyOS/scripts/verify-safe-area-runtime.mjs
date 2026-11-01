#!/usr/bin/env node
// Execute the actual SafeArea source with only platform APIs stubbed.
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
const path = fileURLToPath(new URL('../entry/src/main/ets/theme/SafeArea.ets', import.meta.url));
const source = fs.readFileSync(path, 'utf8').replace(/^import .*;\r?\n/gm, '').replace('export class SafeArea', 'class SafeArea');
const values = new Map();
let top = 20, bottom = 20, listener;
const context = vm.createContext({
  display: { getDefaultDisplaySync: () => ({ densityPixels: 1, height: 800 }) },
  window: { AvoidAreaType: { TYPE_SYSTEM: 0, TYPE_NAVIGATION_INDICATOR: 1 } },
  AppStorage: { get: key => values.get(key), setOrCreate: (key, value) => values.set(key, value) },
  AppLogger: { info() {}, warn() {}, errText: String }
});
vm.runInContext(stripTypeScriptTypes(source) + '\nglobalThis.safe = SafeArea;', context);
const safe = context.safe;
const win = { getWindowAvoidArea: () => ({ topRect: { height: top }, bottomRect: { height: bottom } }), on: (_name, cb) => { listener = cb; } };
safe.init(win);
safe.calibrate(800);
const revision = values.get('theme_revision');
const clearance = safe.dockClearance();
assert.equal(safe.topPad(), 8);
top = 40;
listener({ type: 0 });
assert.equal(safe.topPad(), 28);
assert.ok(values.get('theme_revision') > revision, 'top-only inset change must notify pages');
assert.equal(safe.dockClearance(), clearance, 'top-only update must not move the Dock');
const unchanged = values.get('theme_revision');
listener({ type: 0 });
assert.equal(values.get('theme_revision'), unchanged, 'identical measurements must not trigger a redraw');
bottom = 30;
listener({ type: 1 });
assert.ok(values.get('theme_revision') > unchanged, 'bottom changes must notify pages');
console.log('PASS actual SafeArea: top-only update, stable Dock, no duplicate redraw, bottom update');
