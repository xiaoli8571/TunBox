#!/usr/bin/env node
// Exercise the actual aggregate runner with controlled child-process receipts.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
const url = new URL('./verify-all.mjs', import.meta.url);
const source = fs.readFileSync(url, 'utf8')
  .replace(/^import .*;\r?\n/gm, '')
  .replaceAll('import.meta.url', JSON.stringify(url.href));
function run(args, receipts) {
  const lines = [];
  const proc = { argv: ['node', 'verify-all.mjs', ...args], execPath: process.execPath, exitCode: undefined };
  const consoleStub = { log: (...v) => lines.push(v.join(' ')), error: (...v) => lines.push(v.join(' ')) };
  vm.runInNewContext(source, {
    readdirSync: () => Object.keys(receipts), existsSync: () => false, statSync: () => ({ isFile: () => true }),
    join: path.join, dirname: path.dirname, resolve: path.resolve, basename: path.basename, fileURLToPath,
    spawnSync: (_node, [file]) => receipts[path.basename(file)], process: proc, console: consoleStub
  });
  return { code: proc.exitCode, out: lines.join('\n') };
}
const pass = { status: 0, stdout: 'PASS actual checks\n', stderr: '' };
const skip = { status: 0, stdout: 'SKIP no device\n', stderr: '' };
assert.equal(run(['--only', 'missing'], { 'verify-ok.mjs': pass }).code, 1);
assert.equal(run(['--only', ''], { 'verify-ok.mjs': pass }).code, 1);
let r = run([], { 'verify-ok.mjs': pass, 'verify-optional.mjs': skip });
assert.equal(r.code, 0);
assert.match(r.out, /PASS=1 FAIL=0.*SKIP=1/);
assert.doesNotMatch(r.out, /PASS verify-optional/);
assert.equal(run(['--strict'], { 'verify-optional.mjs': skip }).code, 1);
assert.equal(run([], { 'verify-ui-resource-bindings.mjs': skip }).code, 1);
assert.equal(run([], { 'verify-arkts-compile.mjs': { status: 0, stdout: 'RESULT: 0 passed, 0 failed (skipped)' } }).out.includes('SKIP verify-arkts-compile'), true);
assert.equal(run([], { 'verify-ok.mjs': pass }).code, 0);
assert.equal(run([], { 'verify-broken.mjs': { status: 1, stdout: 'FAIL' } }).code, 1);
assert.equal(run([], { 'verify-subscription-fidelity.mjs': { status: 1, stdout: 'FAILED missing fixture' } }).code, 1, 'missing real fixture must not be waived');
console.log('PASS aggregate runner: empty selectors, skip accounting, required/strict skip rejection, success and failure');
// Negative controls exercise the real fixture entry point, not a copied validator.
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'tunbox-probe-gates-'));
try {
  const fixture = path.join(temp, 'empty.yaml');
  for (const body of ['', 'proxies: []\n', 'rules:\n  - MATCH,DIRECT\n']) {
    fs.writeFileSync(fixture, body);
    const child = spawnSync(process.execPath,
      [fileURLToPath(new URL('./verify-subscription-fidelity.mjs', import.meta.url)), fixture], { encoding: 'utf8' });
    assert.equal(child.status, 1, 'node-free fixture must not pass fidelity checks');
    assert.match(child.stdout + child.stderr, /baseline contains no proxy nodes/);
  }
  const validYaml = `proxies:\n  - {name: Unquoted spaced node, type: trojan, server: example.invalid, port: 443, password: test-only}\n  - {name: '剩余流量：1 GB', type: trojan, server: example.invalid, port: 444, password: test-only}\nproxy-groups:\n  - name: Test group\n    type: select\n    proxies: [Unquoted spaced node]\n`;
  fs.writeFileSync(fixture, validYaml);
  const fidelity = spawnSync(process.execPath,
    [fileURLToPath(new URL('./verify-subscription-fidelity.mjs', import.meta.url)), fixture], { encoding: 'utf8' });
  assert.equal(fidelity.status, 0, fidelity.stdout + fidelity.stderr);
  assert.match(fidelity.stdout, /explicit INFO exclusions: 0/);
  const chains = spawnSync(process.execPath,
    [fileURLToPath(new URL('./verify-smart-active-chains.mjs', import.meta.url)), '--self-test'], { encoding: 'utf8' });
  assert.equal(chains.status, 0, chains.stdout + chains.stderr);
  const connections = path.join(temp, 'connections.json');
  const proxies = path.join(temp, 'proxies.json');
  fs.writeFileSync(connections, JSON.stringify({ connections: [{ chains: ['Test node', 'Test group'] }] }));
  fs.writeFileSync(proxies, JSON.stringify({ proxies: { 'Test group': { type: 'Smart', all: ['Test node'] }, 'Test node': { type: 'Trojan' } } }));
  const env = { ...process.env, TUNBOX_CONNECTIONS_FIXTURE: connections, TUNBOX_PROXIES_FIXTURE: proxies, TUNBOX_SMART_GROUP: 'Test group' };
  const aggregate = fileURLToPath(new URL('./verify-all.mjs', import.meta.url));
  const wired = spawnSync(process.execPath, [aggregate, '--strict', '--only', 'smart-active-chains'], { encoding: 'utf8', env });
  assert.equal(wired.status, 0, wired.stdout + wired.stderr);
  assert.match(wired.stdout, /PASS=1 FAIL=0.*SKIP=0/);
  const invalid = spawnSync(process.execPath, [aggregate, '--strict', '--only', 'smart-active-chains'],
    { encoding: 'utf8', env: { ...env, TUNBOX_PROXIES_FIXTURE: path.join(temp, 'missing.json') } });
  assert.equal(invalid.status, 1, 'explicit missing capture must fail, not silently skip');
  console.log('PASS real fixture gates: empty subscription rejected; synthetic chain self-test and aggregate env wiring passed (not device acceptance)');
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
