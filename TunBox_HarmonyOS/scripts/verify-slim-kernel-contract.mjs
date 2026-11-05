#!/usr/bin/env node
// Existing gate path: size reduction must not remove native outbounds.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const recipes = ['scripts/build-ohos-core.ps1', 'scripts/build-ohos-core.sh'];
let count = 0;
for (const recipe of recipes) {
  const source = fs.readFileSync(path.join(root, recipe), 'utf8');
  const tags = source.match(/-tags\s+"?([a-z0-9_,]+)"?/);
  assert.ok(tags, `${recipe}: missing actual build tags`);
  assert.deepEqual(tags[1].split(',').sort(), ['cmfa', 'with_gvisor'], `${recipe}: outbound capability was removed`);
  assert.ok(source.includes('constant.Version=TunBox-smart-46245513'), 'core version must identify its source');
  console.log(`PASS ${recipe}: full outbound build tags and source version`); count++;
}
const binary = fs.readFileSync(path.join(root, 'entry/libs/arm64-v8a/libgojni.so'));
assert.equal(binary.subarray(0, 4).toString('hex'), '7f454c46', 'packaged core must be ELF');
for (const constructor of ['NewTailscale', 'NewZeroTier', 'NewEasyTier', 'NewWireGuard']) {
  assert.ok(binary.includes(Buffer.from('outbound.' + constructor)), `packaged core is missing ${constructor}`);
  console.log(`PASS packaged core includes ${constructor}`); count++;
}
console.log(`core capability contract: ${count} passed (protocol login requires real service credentials)`);
