#!/usr/bin/env node
// Source-level lifecycle guards; actual latency must be measured on device.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
const root = new URL('../entry/src/main/ets/', import.meta.url);
const home = fs.readFileSync(new URL('pages/HomePage.ets', root), 'utf8');
const begin = home.indexOf('private async bootstrapImpl()');
const end = home.indexOf('onPublicIpRevision()', begin);
const init = home.slice(begin, end);
assert.ok(begin >= 0 && end > begin);
assert.ok(init.indexOf('addListener(this.connectionListener)') < init.indexOf('await SettingsService.init(ctx)'));
assert.ok(init.indexOf('this.pageReady = true') < init.indexOf('await LatencyStoreBridge.ensureStore(ctx)'));
assert.ok(home.includes('if (this.bootstrapTask !== null) { return this.bootstrapTask; }'));
assert.ok(home.includes('if (this.bootstrapTask === task) { this.bootstrapTask = null; }'));
assert.ok(init.includes('if (!this.pageMounted) { return; }'));
const shown = home.slice(home.indexOf('refreshForShown(): void'), home.indexOf('aboutToDisappear(): void'));
assert.ok(shown.includes('if (!this.pageReady)'));
assert.ok(shown.includes('this.applyOrchestratorState()'));
// Production runtime races and immediate visual state are exercised separately.
const { spawnSync } = await import('node:child_process');
const runtime = spawnSync(process.execPath, [fileURLToPath(new URL('./verify-startup-feedback-runtime.mjs', import.meta.url))], { encoding: 'utf8' });
process.stdout.write(runtime.stdout || '');
process.stderr.write(runtime.stderr || '');
assert.equal(runtime.status, 0, 'startup feedback production runtime cases');
console.log('PASS startup lifecycle: early listener, single flight, readiness, unmounted guard, lightweight revisit and immediate connection feedback');
