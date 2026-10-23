import assert from 'node:assert/strict';
import { harness, deferred, flush } from './orchestrator-runtime-harness.mjs';

function fixture() {
  const h = harness();
  h.settings = { rulesEnabled: true, hyperAdRulesEnabled: true, assetSource: 'github', proxyMode: 'rule' };
  h.promotes = []; h.removed = [];
  h.platform.fs.renameSync = (from, to) => h.promotes.push([from, to]);
  h.platform.fs.unlinkSync = path => { h.removed.push(path); if (path.endsWith('hyper_adrules_ads.mrs')) h.ruleReady = false; };
  h.downloads = 0; h.downloadOK = true; h.downloadGate = null; h.reloads = 0; h.restarts = 0; h.configs = [];
  h.platform.SettingsService.load = async () => ({ ...h.settings });
  h.platform.ensurePrivateDir = () => {};
  h.platform.privateFs.writePrivate = (_path, text) => h.configs.push(JSON.parse(text));
  h.platform.SubscriptionService.nodeSetFingerprint = () => 'fixture';
  h.platform.RuntimeConfigMode = { TUNNEL: 'tunnel' };
  h.platform.RuntimeConfigBuilder = { async buildRuntimeConfig(profile) {
    return { yaml: JSON.stringify({ adRule: profile.ready
      && profile.settings.hyperAdRulesEnabled }) };
  } };
  h.orch.lastSubs = h.subs; h.orch.lastNode = h.subs.nodes[0];
  h.orch.lastNodeName = 'test-node';
  h.orch.hydrateAndBuildProfile = async (_subs, settings, _name, _ports, _secret, _hosts, _smart, _geo, ready) =>
    ({ settings, ready });
  h.orch.prepareConfigYaml = text => text;
  h.orch.api.reloadFromPath = async () => { h.reloads++; return true; };
  h.orch.api.selectNode = async () => true; h.orch.api.setMode = async () => true;
  h.orch.restartIfConnected = async () => { h.restarts++; return h.orch.state === h.ConnState.CONNECTED; };
  // Only the asset transport is replaced. The production single-flight/download/apply flow executes.
  h.orch.downloadAsset = async () => {
    h.downloads++;
    if (h.downloadGate) { const gate = h.downloadGate; h.downloadGate = null; await gate.promise; }
    if (h.downloadOK) h.ruleReady = true;
    return h.downloadOK;
  };
  return h;
}

let passed = 0, failed = 0;
async function test(name, fn) {
  try { await fn(); passed++; console.log('PASS ' + name); }
  catch (e) { failed++; console.log('FAIL ' + name + ': ' + e.message); }
}

await test('enabling without a file requires manual download and keeps the tunnel', async () => {
  const h = fixture(), start = h.orch.startedAt;
  assert.equal(await h.orch.applyRulesChanged('enable-ads'), 'ad-unavailable');
  assert.equal(h.downloads, 0); assert.equal(h.configs.at(-1).adRule, false);
  assert.equal(h.restarts, 0); assert.equal(h.orch.startedAt, start);
});
await test('hot reload uses current disk readiness rather than the previous connection flag', async () => {
  const h = fixture(); h.ruleReady = true; h.orch.lastRuleProviderFileReady = false;
  assert.equal(await h.orch.reloadRulesHot('cached-provider'), true);
  assert.equal(h.configs.at(-1).adRule, true); assert.equal(h.downloads, 0);
});
await test('failed manual download leaves the running configuration unchanged', async () => {
  const h = fixture(); h.downloadOK = false;
  assert.notEqual(await h.orch.refreshGeoAsset('ruleset', 'github'), '');
  assert.equal(h.reloads, 0); assert.equal(h.restarts, 0); assert.equal(h.orch.state, h.ConnState.CONNECTED);
});
await test('disabled ad blocking does not fetch the provider', async () => {
  const h = fixture(); h.settings.hyperAdRulesEnabled = false;
  assert.equal(await h.orch.applyRulesChanged('ads-off'), 'hot');
  assert.equal(h.downloads, 0); assert.equal(h.configs.at(-1).adRule, false);
});
await test('rule engine off does not disable ad blocking (independent switch)', async () => {
  const h = fixture(); h.settings.rulesEnabled = false; h.ruleReady = true;
  // 2026-10-23 用户口径：去广告是独立开关 —— 规则引擎关掉时它仍要生效。
  assert.equal(await h.orch.applyRulesChanged('rules-off'), 'hot');
  assert.equal(h.downloads, 0); assert.equal(h.configs.at(-1).adRule, true);
});
await test('cached provider applies without downloading', async () => {
  const h = fixture(); h.ruleReady = true;
  assert.equal(await h.orch.applyRulesChanged('cached'), 'hot');
  assert.equal(h.downloads, 0); assert.equal(h.orch.lastRuleProviderFileReady, true);
});
await test('deleted file overrides stale readiness without downloading it again', async () => {
  const h = fixture(); h.ruleReady = true; h.orch.lastRuleProviderFileReady = true;
  assert.equal(h.orch.deleteGeoAsset('ruleset'), '');
  assert.equal(await h.orch.applyRulesChanged('removed-file'), 'ad-unavailable');
  assert.equal(h.configs.at(-1).adRule, false); assert.equal(h.orch.lastRuleProviderFileReady, false);
  assert.equal(h.downloads, 0); assert.equal(h.restarts, 0);
});
await test('disconnected sessions save for next connect without downloading', async () => {
  const h = fixture(); h.orch.state = h.ConnState.DISCONNECTED;
  assert.equal(await h.orch.applyRulesChanged('offline'), 'none');
  assert.equal(h.downloads, 0); assert.equal(h.reloads, 0); assert.equal(h.restarts, 0);
});
await test('user stop during manual download prevents late reload and reconnect', async () => {
  const h = fixture(), gate = deferred(); h.downloadGate = gate;
  const task = h.orch.refreshGeoAsset('ruleset', 'github'); await flush();
  assert.equal(h.downloads, 1); h.orch.disconnectRequested = true;
  gate.resolve(); await task; assert.equal(h.reloads, 0); assert.equal(h.restarts, 0);
});
await test('new connection sequence rejects an old manual download completion', async () => {
  const h = fixture(), gate = deferred(); h.downloadGate = gate;
  const task = h.orch.refreshGeoAsset('ruleset', 'github'); await flush();
  h.orch.connectSeq++; gate.resolve(); await task;
  assert.equal(h.reloads, 0); assert.equal(h.restarts, 0);
});
await test('new persistent session rejects an old manual download completion', async () => {
  const h = fixture(), gate = deferred(); h.downloadGate = gate;
  const task = h.orch.refreshGeoAsset('ruleset', 'github'); await flush();
  h.orch.sessionGeneration++; gate.resolve(); await task;
  assert.equal(h.reloads, 0); assert.equal(h.restarts, 0);
});
await test('turning ads off during manual download keeps the applied config disabled', async () => {
  const h = fixture(), gate = deferred(); h.downloadGate = gate;
  const task = h.orch.refreshGeoAsset('ruleset', 'github'); await flush();
  h.settings.hyperAdRulesEnabled = false; gate.resolve(); await task;
  assert.equal(h.configs.at(-1).adRule, false); assert.equal(h.restarts, 0);
});
await test('concurrent provider callers share one transfer and result', async () => {
  const h = fixture(), gate = deferred(); h.downloadGate = gate;
  const a = h.orch.downloadRuleProviderAsset('github');
  const b = h.orch.downloadRuleProviderAsset('github'); await flush();
  assert.equal(h.downloads, 1); gate.resolve();
  assert.deepEqual(await Promise.all([a, b]), [true, true]);
  assert.equal(h.orch.ruleProviderDownloadTask, null);
});
await test('transport exceptions settle all waiters and permit explicit retry', async () => {
  const h = fixture(), gate = deferred(), transport = h.orch.downloadAsset;
  h.orch.downloadAsset = async () => { h.downloads++; await gate.promise; throw new Error('network'); };
  const a = h.orch.downloadRuleProviderAsset('github'), b = h.orch.downloadRuleProviderAsset('github');
  gate.resolve(); assert.deepEqual(await Promise.all([a, b]), [false, false]);
  h.orch.downloadAsset = transport;
  assert.equal(await h.orch.refreshGeoAsset('ruleset', 'github'), '');
  assert.equal(h.configs.at(-1).adRule, true); assert.equal(h.downloads, 2);
});
await test('overlapping saves serialize hot reloads without reconnecting', async () => {
  const h = fixture(); h.ruleReady = true;
  assert.deepEqual(await Promise.all([h.orch.applyRulesChanged('first'), h.orch.applyRulesChanged('second')]), ['hot', 'hot']);
  assert.equal(h.restarts, 0); assert.equal(h.downloads, 0);
});
await test('explicit manual update activates rules in the current tunnel', async () => {
  const h = fixture(), start = h.orch.startedAt;
  assert.equal(await h.orch.refreshGeoAsset('ruleset', 'github'), '');
  assert.equal(h.downloads, 1); assert.equal(h.reloads, 1);
  assert.equal(h.configs.at(-1).adRule, true); assert.equal(h.restarts, 0);
  assert.equal(h.orch.startedAt, start); assert.equal(h.promotes.length, 1);
  assert.ok(h.promotes[0][0].endsWith('.next'));
});
await test('late profile build cannot write config into a newer session', async () => {
  const h = fixture(), gate = deferred(); h.ruleReady = true;
  const build = h.platform.RuntimeConfigBuilder.buildRuntimeConfig;
  h.platform.RuntimeConfigBuilder.buildRuntimeConfig = async p => { await gate.promise; return build(p); };
  const task = h.orch.applyRulesChanged('slow-build'); await flush();
  h.orch.sessionGeneration++; gate.resolve(); assert.equal(await task, 'none');
  assert.equal(h.configs.length, 0); assert.equal(h.reloads, 0); assert.equal(h.restarts, 0);
});
await test('late controller response cannot select a node or mode after user stop', async () => {
  const h = fixture(), gate = deferred(); h.ruleReady = true;
  let selections = 0, modes = 0;
  h.orch.api.reloadFromPath = async () => { h.reloads++; await gate.promise; return false; };
  h.orch.api.selectNode = async () => { selections++; return true; };
  h.orch.api.setMode = async () => { modes++; return true; };
  const task = h.orch.applyRulesChanged('slow-reload'); await flush();
  h.orch.disconnectRequested = true; gate.resolve(); assert.equal(await task, 'none');
  assert.equal(selections, 0); assert.equal(modes, 0); assert.equal(h.restarts, 0);
});
await test('another direct hot reload reports pending without restarting the tunnel', async () => {
  const h = fixture(); h.ruleReady = true; h.orch.reloading = true;
  assert.equal(await h.orch.applyRulesChanged('busy'), 'pending');
  assert.equal(h.reloads, 0); assert.equal(h.restarts, 0);
});
await test('controller reload failure still permits the existing reconnect fallback', async () => {
  const h = fixture(); h.ruleReady = true;
  h.orch.api.reloadFromPath = async () => { h.reloads++; return false; };
  assert.equal(await h.orch.applyRulesChanged('controller-failure'), 'reconnect');
  assert.equal(h.reloads, 1); assert.equal(h.restarts, 1);
});

await test('rejected staged config preserves the last accepted configuration', async () => {
  const h = fixture(); h.ruleReady = true;
  h.orch.api.reloadFromPath = async () => false;
  assert.equal(await h.orch.reloadRulesHot('reject'), false);
  assert.equal(h.promotes.length, 0); assert.ok(h.removed.some(p => p.endsWith('.next')));
});
await test('late accepted reload cannot promote configuration after user stop', async () => {
  const h = fixture(), gate = deferred(); h.ruleReady = true;
  h.orch.api.reloadFromPath = async () => { await gate.promise; return true; };
  const task = h.orch.applyRulesChanged('late-accept'); await flush();
  h.orch.disconnectRequested = true; gate.resolve();
  assert.equal(await task, 'none'); assert.equal(h.promotes.length, 0); assert.equal(h.restarts, 0);
});

console.log(JSON.stringify({ baseline: process.argv.includes('--baseline'), passed, failed }));
if (failed) process.exitCode = 1;
