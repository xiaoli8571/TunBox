// Production code with controlled OS boundaries; Go parser and HTTP tests use the real core.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import net from 'node:net';
import { spawn, spawnSync } from 'node:child_process';
import { stripTypeScriptTypes } from 'node:module';
import { fileURLToPath } from 'node:url';
import { harness, deferred, flush } from './orchestrator-runtime-harness.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const sourceRoot = path.join(root, 'entry/src/main/ets');
const core = path.resolve(root, '../mihomo-build/mihomo-smart-462455136157a760937c666bba71afe33b1a809e');
const scratch = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'tunbox-stability-'));
let passed = 0, failed = 0;
async function test(name, run) {
  try { await run(); passed++; console.log('PASS ' + name); }
  catch (e) { failed++; console.log('FAIL ' + name + ': ' + (e.stack ?? e)); }
}
function load(file, names, context) {
  const source = fs.readFileSync(path.join(sourceRoot, file), 'utf8')
    .replace(/^import\b[\s\S]*?;\r?\n/gm, '').replace(/^export /gm, '');
  return vm.runInContext(stripTypeScriptTypes(`(()=>{${source}\nreturn {${names}};})()`,
    { mode: 'transform' }), context);
}
const helper = path.join(scratch, 'prepare.exe');
const build = spawnSync('go', ['build', '-o', helper, path.join(root, 'scripts/fixtures/profile-prepare/main.go')],
  { cwd: core, encoding: 'utf8', timeout: 180000, windowsHide: true });
assert.equal(build.status, 0, build.stderr || build.error?.message);
function nativePrepare(text) {
  const result = spawnSync(helper, [], { input: text, encoding: 'utf8', timeout: 10000, windowsHide: true });
  assert.equal(result.status, 0, result.stderr || result.error?.message);
  const reply = JSON.parse(result.stdout);
  if (reply.error) { throw Error(reply.error); }
  return reply.yaml;
}
const valid = 'proxies:\n - {name: A, type: socks5, server: 127.0.0.1, port: 9}\n'
  + 'proxy-groups:\n - {name: Main, type: select, proxies: [A]}\nrules:\n - MATCH,Main\n';

try {
  for (const [name, yaml, accepted] of [
    ['valid final configuration', valid, true],
    ['missing rule target introduced by an override', valid.replace('MATCH,Main', 'MATCH,Missing'), false],
    ['missing rule provider introduced after profile import', valid.replace('MATCH,Main', 'RULE-SET,Missing,Main'), false],
    ['missing group member introduced after profile import', valid.replace('proxies: [A]', 'proxies: [Missing]'), false],
  ]) {
    await test('native final gate: ' + name, async () => {
      const h = harness();
      Object.assign(h.platform, load('commons/services/ConfigValidator.ets', 'ConfigValidator', h.platform));
      let calls = 0;
      h.platform.coreBridge = { async prepareProfile(text) { calls++; return nativePrepare(text); } };
      if (accepted) { assert.equal(await h.orch.prepareConfigYaml(yaml, 'regression'), yaml); }
      else { await assert.rejects(h.orch.prepareConfigYaml(yaml, 'regression'), /配置校验未通过/); }
      assert.equal(calls, 1); assert.equal(h.writes, 0); h.stop();
    });
  }
  await test('last-good records accepted bytes even when the main-file promotion failed', () => {
    const h = harness(), files = new Map();
    files.set('/sandbox/mihomo_config.yaml', 'older accepted bytes');
    h.platform.privateFs.writePrivate = (p, data) => files.set(p, data);
    h.platform.fs.renameSync = (from, to) => { files.set(to, files.get(from)); files.delete(from); };
    h.orch.snapshotLastGoodConfig('new accepted bytes');
    assert.equal(files.get('/sandbox/mihomo_config.lastgood.yaml'), 'new accepted bytes'); h.stop();
  });
  await test('snapshot rename failure preserves the existing last-good bytes', () => {
    const h = harness(), files = new Map([['/sandbox/mihomo_config.lastgood.yaml', 'old']]);
    h.platform.privateFs.writePrivate = (p, data) => files.set(p, data);
    h.platform.fs.renameSync = () => { throw Error('injected rename failure'); };
    h.orch.snapshotLastGoodConfig('new');
    assert.equal(files.get('/sandbox/mihomo_config.lastgood.yaml'), 'old'); h.stop();
  });
  await test('successful profile application recognizes the actual hot outcome', async () => {
    const h = harness();
    h.platform.ProfileRepository = { currentId: () => 's', exists: () => true, revisionOf: () => 'new' };
    h.orch.appliedProfileId = 's'; h.orch.appliedProfileRevision = 'old';
    h.orch.applyRulesChanged = async () => 'hot';
    assert.equal(await h.orch.ensureProfileApplied('changed'), true);
    for (const outcome of ['pending', 'apply-failed', 'none']) {
      h.orch.applyRulesChanged = async () => outcome;
      assert.equal(await h.orch.ensureProfileApplied('changed'), false);
    }
    h.stop();
  });

  function lifecycleFixture() {
    const h = harness(); h.orch.api.resetTrafficBaseline = () => {};
    h.orch.disconnectInternal = async () => {};
    return h;
  }
  await test('queued connection requests coalesce to the newest user choice', async () => {
    const h = lifecycleFixture(), starts = [];
    h.orch.connectExclusive = async node => { starts.push(node.name); return true; };
    const first = h.orch.connect({ name: 'A' }, h.subs);
    const second = h.orch.connect({ name: 'B' }, h.subs);
    assert.deepEqual(await Promise.all([first, second]), [false, true]);
    assert.deepEqual(starts, ['B']); h.stop();
  });
  await test('new connection waits for the previous transaction to finish cleanup', async () => {
    const h = lifecycleFixture(), gate = deferred(), events = [];
    h.orch.connectExclusive = async node => {
      events.push('start:' + node.name);
      if (node.name === 'A') { await gate.promise; }
      events.push('end:' + node.name); return true;
    };
    const first = h.orch.connect({ name: 'A' }, h.subs); await flush();
    const second = h.orch.connect({ name: 'B' }, h.subs); await flush();
    assert.deepEqual(events, ['start:A']); gate.resolve();
    assert.deepEqual(await Promise.all([first, second]), [false, true]);
    assert.deepEqual(events, ['start:A', 'end:A', 'start:B', 'end:B']); h.stop();
  });
  await test('stop while settings are loading cannot publish a late connect intent', async () => {
    const h = lifecycleFixture(), gate = deferred();
    h.platform.SettingsService.load = async () => { await gate.promise; return {}; };
    h.platform.AppRoutingPolicy = { runtime() { throw Error('must not reach routing'); } };
    const connected = h.orch.connect({ name: 'A' }, h.subs); await flush();
    const stopped = h.orch.disconnect(); gate.resolve();
    assert.equal(await connected, false); await stopped;
    assert.equal(h.writes, 0); assert.equal(h.orch.state, h.ConnState.DISCONNECTED); h.stop();
  });
  await test('duplicate stops settle disconnected instead of leaving the UI disconnecting', async () => {
    const h = lifecycleFixture(), gate = deferred();
    h.orch.disconnectInternal = async () => { await gate.promise; };
    const first = h.orch.disconnect(); await flush(); const second = h.orch.disconnect();
    gate.resolve(); await Promise.all([first, second]);
    assert.equal(h.orch.state, h.ConnState.DISCONNECTED); h.stop();
  });
  await test('late stop completion cannot erase the next successful connection', async () => {
    const h = lifecycleFixture(), gate = deferred(), events = [];
    h.orch.disconnectInternal = async () => { events.push('stop'); await gate.promise; };
    h.orch.connectExclusive = async () => { events.push('start'); h.orch.state = h.ConnState.CONNECTED; return true; };
    const stopped = h.orch.disconnect(); await flush();
    const connected = h.orch.connect({ name: 'new' }, h.subs); await flush();
    assert.deepEqual(events, ['stop']); gate.resolve(); await stopped;
    assert.equal(await connected, true); assert.equal(h.orch.state, h.ConnState.CONNECTED);
    assert.deepEqual(events, ['stop', 'start']); h.stop();
  });
  await test('connect waits for an in-flight hot reload before touching the extension', async () => {
    const h = lifecycleFixture(), gate = deferred(), events = [];
    h.orch.reloadRulesHotExclusive = async () => { events.push('reload'); await gate.promise; events.push('reload-end'); return true; };
    h.orch.connectExclusive = async () => { events.push('connect'); return true; };
    const hot = h.orch.reloadRulesHot('rules'); await flush();
    const connected = h.orch.connect({ name: 'new' }, h.subs); await flush();
    assert.deepEqual(events, ['reload']); gate.resolve(); await hot; assert.equal(await connected, true);
    assert.deepEqual(events, ['reload', 'reload-end', 'connect']); h.stop();
  });
  await test('failure recovery can reconnect without deadlocking its own resource queue', async () => {
    const h = lifecycleFixture(); let attempts = 0;
    h.orch.connectExclusive = async (_node, _subs, seq) => {
      attempts++;
      if (attempts === 1) { h.orch.failedConnectSeq = seq; h.orch.lastError = 'network'; return false; }
      h.orch.state = h.ConnState.CONNECTED; return true;
    };
    h.orch.runHealthSelfCheckAndRepair = async () => {
      await h.orch.disconnect(); return h.orch.connect({ name: 'repair' }, h.subs);
    };
    let timer;
    try {
      const result = await Promise.race([h.orch.connect({ name: 'first' }, h.subs),
        new Promise((_, reject) => { timer = setTimeout(() => reject(Error('queue deadlocked')), 1000); })]);
      assert.equal(result, true); assert.equal(attempts, 2);
    } finally { clearTimeout(timer); h.stop(); }
  });

  function networkFixture() {
    const h = lifecycleFixture();
    Object.assign(h.platform, load('commons/services/NetworkStateWatcher.ets', 'NetTypes', h.platform));
    h.orch.lastNetType = 'wifi'; h.orch.lastSubs = h.subs; h.orch.lastNodeName = 'test-node';
    return h;
  }
  // 2026-10-28 Phase 3：重连链路已迁到 `connection/ReconnectManager`（状态独占定时器/尝试计数/
  // 退避预算）。下面四条断言直击**真实模块**：`requestAsync` = 排程路径，`fireNow` = 尝试路径。
  await test('late intent lookup cannot schedule reconnect after a completed user stop', async () => {
    const h = networkFixture(), gate = deferred();
    h.orch.isUserIntentConnected = async () => { await gate.promise; return true; };
    const pending = h.orch.reconnectManager().requestAsync('network'); await flush();
    h.orch.requestDisconnect(); h.orch.disconnectRequested = false;
    gate.resolve(); await pending; assert.equal(h.timers.size, 0); h.stop();
  });
  await test('late scheduled-reconnect lookup cannot restart a stopped session', async () => {
    const h = networkFixture(), gate = deferred(); let starts = 0;
    h.orch.isUserIntentConnected = async () => { await gate.promise; return true; };
    h.orch.connect = async () => { starts++; return true; };
    const pending = h.orch.reconnectManager().fireNow('network'); await flush();
    h.orch.requestDisconnect(); h.orch.disconnectRequested = false;
    gate.resolve(); await pending; assert.equal(starts, 0); h.stop();
  });
  await test('network loss cancels a pending reconnect without creating another attempt', async () => {
    const h = networkFixture();
    await h.orch.reconnectManager().requestAsync('network'); assert.equal(h.timers.size, 1);
    h.orch.onNetworkTypeChanged('none', 100);
    assert.equal(h.timers.size, 0); h.stop();
  });
  await test('an obsolete failed reconnect cannot schedule retries in the new session', async () => {
    const h = networkFixture(); let retries = 0;
    const manager = h.orch.reconnectManager();
    manager.request = () => { retries++; };
    h.orch.connect = async () => { h.orch.connectSeq += 2; return false; };
    await manager.fireNow('network'); assert.equal(retries, 0); h.stop();
  });
  await test('headless DoH returning after stop cannot touch the shared VPN extension', async () => {
    const h = harness(), gate = deferred(); let touches = 0;
    h.orch.testCoreSubs = h.subs; h.orch.testCoreSettings = {};
    h.platform.RuntimeConfigBuilder = { async resolveSharedHosts() { await gate.promise; return {}; } };
    h.platform.vpnExtension = { async startVpnExtensionAbility() { touches++; }, async stopVpnExtensionAbility() { touches++; } };
    const pending = h.orch.launchTestCore(); await flush();
    h.orch.requestDisconnect(); gate.resolve(); assert.equal(await pending, false);
    assert.equal(touches, 0); h.stop();
  });
  await test('late headless native validation cannot write files or launch after cancellation', async () => {
    const h = harness(), gate = deferred(); let writes = 0, touches = 0;
    h.subs.nodes[0].server = '127.0.0.1'; h.orch.testCoreSubs = h.subs; h.orch.testCoreSettings = {};
    h.platform.RuntimeConfigMode = { TEST: 'test' };
    h.platform.RuntimeConfigBuilder = {
      async resolveSharedHosts() { return {}; }, proxyServerDomains: () => [],
      async buildRuntimeConfig() { return { yaml: valid }; },
    };
    h.platform.DoHResolver = { lastReport: { queried: [], failed: [], resolved: [] } };
    h.platform.SubscriptionService.nodeSetFingerprint = () => 'nodes';
    h.platform.ensurePrivateDir = () => {};
    h.platform.privateFs.writePrivate = () => { writes++; };
    h.platform.vpnExtension = { async startVpnExtensionAbility() { touches++; }, async stopVpnExtensionAbility() { touches++; } };
    h.orch.pickPorts = async () => ({}); h.orch.hydrateAndBuildProfile = async () => ({});
    h.orch.isSmartModelReady = () => false; h.orch.isGeoipReady = () => false; h.orch.isRuleProviderReady = () => false;
    h.orch.prepareConfigYaml = async text => { await gate.promise; return text; };
    const pending = h.orch.launchTestCore(); await flush();
    h.orch.requestDisconnect(); gate.resolve(); assert.equal(await pending, false);
    assert.equal(writes, 0); assert.equal(touches, 0); h.stop();
  });
  await test('real connection waits for a starting test core before resetting its ownership', async () => {
    const h = harness(), gate = deferred(); let resets = 0;
    h.platform.SettingsService.load = async () => ({});
    h.platform.AppRoutingPolicy = { runtime: () => ({}) };
    h.orch.stopTestCore = async () => { await gate.promise; };
    h.orch.invalidateTestCoreAfterRealTunnel = () => { resets++; };
    const pending = h.orch.connect(h.subs.nodes[0], h.subs); await flush();
    assert.equal(resets, 0); h.orch.requestDisconnect(); gate.resolve();
    assert.equal(await pending, false); assert.equal(resets, 0); assert.equal(h.writes, 0); h.stop();
  });

  function privateWriter({ short = false, fail = false } = {}) {
    let closed = 0, output;
    const context = vm.createContext({
      util: { TextEncoder: { create: () => new TextEncoder() } },
      fs: { OpenMode: { READ_WRITE: 2, CREATE: 64, TRUNC: 512 }, openSync: () => ({ fd: 1 }),
        writeSync(_fd, buffer) {
          if (fail) { throw Error('injected write error'); }
          output = Buffer.from(buffer); return short ? output.length - 1 : output.length;
        }, closeSync() { closed++; } },
    });
    const { FileIoPrivateFs } = load('commons/services/PrivateFileStore.ets', 'FileIoPrivateFs', context);
    return { writer: new FileIoPrivateFs(), closed: () => closed, bytes: () => output };
  }
  await test('private config writer checks UTF-8 bytes including Chinese and emoji', () => {
    const h = privateWriter(), text = '规则：节点 🚀'; h.writer.writePrivate('fixture', text);
    assert.equal(h.bytes().toString('utf8'), text); assert.equal(h.closed(), 1);
  });
  await test('short private-file writes fail before promotion and close the file', () => {
    const h = privateWriter({ short: true });
    assert.throws(() => h.writer.writePrivate('fixture', '配置'), /incomplete/); assert.equal(h.closed(), 1);
  });
  await test('private-file write failures still close the descriptor', () => {
    const h = privateWriter({ fail: true });
    assert.throws(() => h.writer.writePrivate('fixture', 'config'), /injected/); assert.equal(h.closed(), 1);
  });

  for (const failure of ['short-write', 'fsync']) {
    await test(`asset ${failure} keeps old resource and removes its partial download`, async () => {
      const h = harness(), destination = '/sandbox/geoip.metadb';
      const files = new Map([[destination, 'old-resource']]); let opened = '', closed = 0, destroyed = 0;
      const responseBytes = vm.runInContext('new ArrayBuffer(32)', h.platform);
      h.platform.AppProxyRoute = { isReady: () => false };
      h.platform.http = { RequestMethod: { GET: 'GET' }, HttpDataType: { ARRAY_BUFFER: 0 }, createHttp() {
        return { async request() { return { responseCode: 200, result: responseBytes }; },
          destroy() { destroyed++; } };
      } };
      Object.assign(h.platform.fs, {
        openSync(p) { opened = p; files.set(p, 'partial'); return { fd: 1 }; },
        writeSync() { return failure === 'short-write' ? 8 : 32; },
        fsyncSync() { if (failure === 'fsync') { throw Error('injected fsync failure'); } },
        closeSync() { closed++; }, unlinkSync(p) { files.delete(p); },
        renameSync(from, to) { files.set(to, files.get(from)); files.delete(from); },
      });
      assert.equal(await h.orch.downloadAsset([{ url: 'https://example.invalid', tag: 'fixture' }],
        destination, 1, () => true, 'auto', 'geoip.metadb'), false);
      assert.ok(opened.endsWith('.tmp')); assert.equal(files.size, 1);
      assert.equal(files.get(destination), 'old-resource'); assert.equal(closed, 1); assert.equal(destroyed, 1); h.stop();
    });
  }

  function pageHarness() {
    let timerId = 0;
    const timers = new Map();
    const state = { initGate: null, listGate: null, calls: 0, reply: [] };
    const context = vm.createContext({
      Promise, Date, Math, getContext: () => ({}), TAG: 'ConnectionsPage', POLL_INTERVAL_MS: 2000,
      AppLogger: { warn() {}, errText: String },
      ConnectionOrchestrator: { instance: () => ({ init() {}, api: { async listConnections() {
        state.calls++; const gate = state.listGate; state.listGate = null;
        if (gate) { await gate.promise; } return state.reply;
      } } }) },
      SubscriptionService: { instance: () => ({ nodes: [], async init() {
        if (state.initGate) { const gate = state.initGate; state.initGate = null; await gate.promise; }
      } }) },
      setTimeout(fn, delay) { const id = ++timerId; timers.set(id, { fn, delay, once: true }); return id; },
      clearTimeout(id) { timers.delete(id); },
      setInterval(fn, delay) { const id = ++timerId; timers.set(id, { fn, delay }); return id; },
      clearInterval(id) { timers.delete(id); },
      // 2026-10-27：页面周期任务已改走 UnifiedScheduler（全仓单 tick），
      // 替身必须把 token 记进同一张 timers 表，否则「只有一个轮询定时器」的断言会假失败。
      UnifiedScheduler: {
        every(fn, delay) { const id = ++timerId; timers.set(id, { fn, delay }); return id; },
        clear(id) { timers.delete(id); },
        count() { return timers.size; }
      },
    });
    const source = fs.readFileSync(path.join(sourceRoot, 'pages/ConnectionsPage.ets'), 'utf8');
    const body = (source.slice(source.indexOf('struct ConnectionsPage {'), source.indexOf('  build() {')) + '\n}')
      .replace('struct ConnectionsPage', 'class ConnectionsPage')
      .replace(/@StorageLink\([^\n]*?\)\s*/g, '').replace(/@State\s+/g, '');
    const Page = vm.runInContext(stripTypeScriptTypes(`(()=>{${body}\nreturn ConnectionsPage;})()`,
      { mode: 'transform' }), context);
    const page = new Page();
    return Object.assign(state, { page, timers, async fire(delay) {
      for (const [id, timer] of [...timers]) if (timer.delay === delay) {
        if (timer.once) { timers.delete(id); } timer.fn();
      }
      await flush();
    } });
  }
  await test('leaving connections before its transition ends cancels bootstrap', async () => {
    const h = pageHarness(); h.page.onPageShow(); h.page.onPageHide(); await h.fire(240);
    assert.equal(h.calls, 0); assert.equal(h.timers.size, 0);
  });
  await test('late subscription initialization cannot rearm a hidden connections page', async () => {
    const h = pageHarness(), gate = deferred(); h.initGate = gate;
    h.page.onPageShow(); await h.fire(240); h.page.aboutToDisappear(); gate.resolve(); await flush();
    assert.equal(h.calls, 0); assert.equal(h.timers.size, 0);
  });
  await test('late connection results cannot update a hidden page or restart polling', async () => {
    const h = pageHarness(), gate = deferred(); h.listGate = gate;
    h.page.onPageShow(); await h.fire(240); h.page.onPageHide();
    h.reply = [{ id: 'late', download: 10, upload: 0 }]; gate.resolve(); await flush();
    assert.equal(h.page.entries.length, 0); assert.equal(h.timers.size, 0);
  });
  await test('showing connections twice leaves exactly one active polling timer', async () => {
    const h = pageHarness(); h.page.onPageShow(); await h.fire(240);
    h.page.onPageShow(); await h.fire(240);
    assert.equal([...h.timers.values()].filter(t => t.delay === 2000).length, 1);
    h.page.onPageHide(); assert.equal(h.timers.size, 0);
  });

  await test('real core: mode PATCH changes mode without reloading or resetting the selected node', async () => {
    const socket = net.createServer(); await new Promise(resolve => socket.listen(0, '127.0.0.1', resolve));
    const port = socket.address().port; await new Promise(resolve => socket.close(resolve));
    const config = `external-controller: 127.0.0.1:${port}\nmode: rule\nlog-level: error\n`
      + valid.replace('proxies: [A]', 'proxies: [A, DIRECT]');
    const file = path.join(scratch, 'live.yaml'); fs.writeFileSync(file, config);
    const child = spawn(path.join(core, 'mihomo.exe'), ['-d', scratch, '-f', file],
      { windowsHide: true, stdio: 'ignore' });
    try {
      let ready = false;
      for (let i = 0; i < 100; i++) {
        try { ready = (await fetch(`http://127.0.0.1:${port}/version`)).ok; } catch {}
        if (ready) { break; } await new Promise(resolve => setTimeout(resolve, 50));
      }
      assert.ok(ready, 'local core must become ready');
      const requests = [], logger = { info() {}, warn() {}, error() {}, errText: String };
      const http = { RequestMethod: { GET: 'GET', PUT: 'PUT', PATCH: 'PATCH' }, createHttp() {
        return { async request(url, options) {
          requests.push([options.method, url]);
          const reply = await fetch(url, { method: options.method, headers: options.header, body: options.extraData });
          return { responseCode: reply.status, result: await reply.text() };
        }, destroy() {} };
      } };
      const context = vm.createContext({ http, AppLogger: logger, Date, Map, Set, JSON, Math });
      const { ClashApiService } = load('commons/services/ClashApiService.ets', 'ClashApiService', context);
      const api = new ClashApiService(); api.setEndpoint(port, '');
      const selected = await fetch(`http://127.0.0.1:${port}/proxies/Main`, {
        method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: 'DIRECT' }) });
      assert.equal(selected.status, 204);
      // Make file reloads fail, so a false PUT success cannot hide behind a healthy file.
      fs.writeFileSync(file, 'proxies: broken\n');
      for (const mode of ['global', 'direct', 'rule']) {
        assert.equal(await api.setMode(mode), true);
        const active = await (await fetch(`http://127.0.0.1:${port}/configs`)).json();
        assert.equal(active.mode, mode);
        const group = await (await fetch(`http://127.0.0.1:${port}/proxies/Main`)).json();
        assert.equal(group.now, 'DIRECT');
      }
      assert.ok(requests.every(([method]) => method === 'PATCH'));
    } finally {
      if (child.exitCode === null) { child.kill(); await new Promise(resolve => child.once('exit', resolve)); }
    }
  });
} finally {
  const parent = fs.realpathSync(os.tmpdir());
  if (path.dirname(fs.realpathSync(scratch)) === parent && path.basename(scratch).startsWith('tunbox-stability-')) {
    fs.rmSync(scratch, { recursive: true });
  }
}
console.log(JSON.stringify({ passed, failed }));
if (failed) { process.exitCode = 1; }
