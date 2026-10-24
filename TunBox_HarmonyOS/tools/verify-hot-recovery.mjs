#!/usr/bin/env node
// Node 24: node tools/verify-hot-recovery.mjs. No generated files/build required.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';

const root = new URL('../entry/src/main/ets/', import.meta.url);
function source(path) {
  return stripTypeScriptTypes(readFileSync(new URL(path, root), 'utf8')
    .replace(/^import[\s\S]*?;\s*$/gm, '')
    .replace(/\bexport default /g, '').replace(/\bexport /g, ''), { mode: 'strip' });
}
function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; }
function fixture({ attach = true, protect = true, start = true, gate = null } = {}) {
  const events = [], timers = new Map(); let nextTimer = 0, running = false;
  const context = vm.createContext({
    console, AppLogger: { info() {}, warn() {}, error() {}, errText(e) { return e instanceof Error ? e.message : String(e); } },
    VpnExtensionAbility: class {}, AppRoutingRuntime: class {},
    AppRoutingPolicy: { runtimeError() { return ''; } },
    NetTypes: { UNKNOWN: 'unknown', NONE: 'none' },
    MAX_CORE_RECOVERY_ATTEMPTS: 3, MAX_TUNNEL_REBUILDS: 2,
    coreRecoveryDelayMs: n => 1000 * 2 ** n, tunnelRebuildDelayMs: () => 1500,
    fs: { unlinkSync() {} },
    setInterval(fn, delay) { const id = ++nextTimer; timers.set(id, { fn, delay }); return id; },
    clearInterval(id) { timers.delete(id); },
    setTimeout(fn, delay) { const id = ++nextTimer; timers.set(id, { fn, delay }); return id; },
    clearTimeout(id) { timers.delete(id); },
    native: {
      attachTunFd(fd) { events.push(['attach', fd]); assert.equal(fd, 42, 'must use original platform fd'); return attach; },
      initProtect(...args) { assert.equal(args.length, 0); events.push(['protect']); return protect ? 100 : -1; },
      startCore(path, fd) { events.push(['start', fd]); assert.ok(fd >= 0, 'VPN start must never be headless');
        assert.ok(events.some(e => e[0] === 'protect'), 'protect initialized before start');
        return (gate ? gate.promise : Promise.resolve(start)).then(ok => { running = ok; return ok; }); },
      stopCore() { events.push(['stop']); running = false; },
      lastError() { return 'mock native failure'; }, isCoreAlive() { return running; },
      readProtectSocketFd() { return [-1, -1]; }
    }
  });
  vm.runInContext(`{ ${source('core/CoreBridge.ets')} globalThis.bridge = coreBridge; }`, context);
  context.coreBridge = context.bridge;
  vm.runInContext(`${source('vpnability/VpnExtensionAbility.ets')} globalThis.Extension = TunBoxVpnExtension;`, context);
  const ext = new context.Extension();
  ext.connection = { async destroy() { events.push(['destroy']); } };
  ext.platformTunFd = 42;
  ext.configPathForCleanup = '/cache/config.yaml';
  ext.recoveryAttempts = 1;
  ext.ensureConfigMtu = () => {};
  ext.writeStatus = phase => events.push(['status', phase]);
  ext.reportStartOk = () => events.push(['startup-marker']);
  return { ext, bridge: context.bridge, events, timers, running: () => running };
}

{
  const f = fixture();
  await f.ext.recoverCore('test');
  assert.deepEqual(f.events.slice(0, 4), [['stop'], ['attach', 42], ['protect'], ['start', 42]]);
  assert.ok(f.events.some(e => e[0] === 'status' && e[1] === 'running'));
  assert.ok(!f.events.some(e => e[0] === 'startup-marker'));
  assert.equal(f.ext.recoveryAttempts, 0);
  assert.ok(f.ext.protectTimer >= 0 && f.ext.coreMonitorTimer >= 0);
  await f.ext.cleanupResources();
  assert.equal(f.ext.platformTunFd, -1);
  assert.equal(f.timers.size, 0);
  console.log('PASS successful recovery: original fd, protect ordering, monitors, cleanup');
}
for (const failure of ['attach', 'protect', 'start']) {
  const f = fixture({ [failure]: false });
  await f.ext.recoverCore('failure');
  assert.ok(!f.events.some(e => e[0] === 'status' && e[1] === 'running'));
  if (failure !== 'start') assert.ok(!f.events.some(e => e[0] === 'start'));
  assert.equal(f.ext.protectTimer, -1);
  assert.equal(f.ext.recoveryRunning, false);
  assert.ok(f.ext.recoveryTimer >= 0, 'retry scheduled after releasing running gate');
  assert.equal(f.ext.recoveryAttempts, 2);
  assert.equal(f.running(), false);
  assert.equal(f.bridge.tunFd, -1);
  await f.ext.cleanupResources();
  console.log(`PASS failed ${failure}: rollback, no false success, retry scheduled`);
}
// Cleanup while each async boundary is outstanding must not resume the old flow.
for (const boundary of ['stopCore', 'attachTun', 'initProtect', 'startCore']) {
  const gate = deferred();
  const f = fixture(boundary === 'startCore' ? { gate } : {});
  const entered = deferred();
  const original = f.bridge[boundary].bind(f.bridge);
  if (boundary !== 'startCore') {
    let first = true;
    f.bridge[boundary] = async (...args) => {
      const value = await original(...args);
      if (first) { first = false; entered.resolve(); await gate.promise; }
      return value;
    };
  }
  const recovery = f.ext.recoverCore('race');
  if (boundary === 'startCore') {
    // Finite microtask drain, no timers or wall-clock sleep.
    for (let i = 0; i < 20 && !f.events.some(e => e[0] === 'start'); i++) await Promise.resolve();
    assert.ok(f.events.some(e => e[0] === 'start'));
  } else await entered.promise;
  const cleanup = f.ext.cleanupResources();
  assert.equal(f.ext.connection, null, 'disconnect invalidates synchronously');
  gate.resolve(true);
  await Promise.all([recovery, cleanup]);
  assert.equal(f.running(), false);
  assert.equal(f.ext.platformTunFd, -1);
  assert.equal(f.timers.size, 0);
  assert.ok(!f.events.some(e => e[0] === 'status' && e[1] === 'running'));
  if (boundary !== 'startCore') assert.ok(!f.events.some(e => e[0] === 'start'));
  else assert.ok(f.events.findLastIndex(e => e[0] === 'stop') > f.events.findIndex(e => e[0] === 'start'));
  console.log(`PASS cleanup during ${boundary}: no resurrection`);
}
console.log('All hot-recovery tests passed (actual Extension and CoreBridge source, mocked native).');
