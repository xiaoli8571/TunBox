// Run the production port probe and startup paths; replace platform boundaries only.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import net from 'node:net';
import { stripTypeScriptTypes } from 'node:module';
import { harness, flush } from './orchestrator-runtime-harness.mjs';

const base = new URL('../entry/src/main/ets/', import.meta.url);
function load(file, name, context) {
  const source = fs.readFileSync(new URL(file, base), 'utf8')
    .replace(/^import\b[\s\S]*?;\r?\n/gm, '').replace(/^export /gm, '');
  const result = vm.runInContext(stripTypeScriptTypes(`(()=>{${source}\nreturn ${name}})()`,
    {mode:'transform'}), context);
  context[name] = result; return result;
}
let passed = 0;
async function test(name, run) { await run(); passed++; console.log('PASS ' + name); }

await test('an accepting real listener is occupied even when a second listen would succeed', async () => {
  const listener = net.createServer(client => client.end());
  await new Promise(resolve => listener.listen(0, '127.0.0.1', resolve));
  let bindCalls = 0, clientCloses = 0;
  const context = vm.createContext({socket: {
    constructTCPSocketInstance() {
      const client = new net.Socket();
      return {
        connect({address, timeout}) { return new Promise((resolve, reject) => {
          client.once('error', reject); client.setTimeout(timeout, () => reject(Error('timeout')));
          client.connect(address.port, address.address, resolve);
        }); },
        async close() { clientCloses++; client.destroy(); }
      };
    },
    constructTCPSocketServerInstance() { bindCalls++; return {async listen(){}, async close(){}}; }
  }});
  try {
    const Probe = load('commons/services/LocalPortProbe.ets', 'LocalPortProbe', context);
    assert.equal(await Probe.isFree(listener.address().port), false);
    assert.equal(bindCalls, 0); assert.equal(clientCloses, 1);
  } finally { await new Promise(resolve => listener.close(resolve)); }
});

await test('refused connections still require a successful bind and both probe sockets close', async () => {
  let denied = false, closed = 0;
  const context = vm.createContext({socket: {
    constructTCPSocketInstance: () => ({async connect(){throw Error('refused');}, async close(){closed++;}}),
    constructTCPSocketServerInstance: () => ({async listen(){if(denied)throw Error('busy');}, async close(){closed++;}})
  }});
  const Probe = load('commons/services/LocalPortProbe.ets', 'LocalPortProbe', context);
  assert.equal(await Probe.isFree(19090), true); denied = true;
  assert.equal(await Probe.isFree(19090), false); assert.equal(closed, 4);
});

await test('headless port allocation avoids an isolated controller and never falls back to a busy port', async () => {
  const h = harness();
  try {
    const occupied = new Set([19090]);
    h.platform.socket = {
      constructTCPSocketInstance: () => ({async connect({address}){
        if(!occupied.has(address.port))throw Error('refused');
      }, async close(){}}),
      // Simulate the platform allowing a duplicate bind through address reuse.
      constructTCPSocketServerInstance: () => ({async listen(){}, async close(){}})
    };
    load('commons/services/LocalPortProbe.ets','LocalPortProbe',h.platform);
    assert.equal((await h.orch.pickPorts(9090)).apiPort, 29090);
    occupied.add(29090);
    await assert.rejects(h.orch.pickPorts(9090), /端口均被占用/);
  } finally { h.stop(); }
});

function startupFixture(probe) {
  const h = harness(); let confirmations = 0, launches = 0, resolvedNodes;
  h.orch.testCoreSubs = h.subs; h.orch.testCoreSettings = {};
  h.subs.nodes = [{server:'current.example'}, {server:'unrelated.example'}];
  h.subs.nodesOf = () => [h.subs.nodes[0]];
  h.platform.ProfileRepository.exists = () => false;
  h.platform.RuntimeConfigMode = {TEST:'test'};
  h.platform.PRIVATE_TEST_CONFIG_FILE = 'mihomo_test_config.yaml';
  h.platform.RuntimeConfigBuilder = {
    async resolveSharedHosts(nodes){resolvedNodes = Array.from(nodes);return {};},
    proxyServerDomains: () => [], async buildRuntimeConfig(){return {yaml:'valid'};}
  };
  h.platform.DoHResolver = {lastReport:{queried:[],failed:[],resolved:[]}};
  h.platform.SubscriptionService.nodeSetFingerprint = () => 'fixture';
  h.platform.ensurePrivateDir = () => {};
  h.platform.privateFs.writePrivate = () => {};
  h.platform.SettingsService.flushNow = async () => {};
  h.platform.vpnExtension = {
    async stopVpnExtensionAbility(){},
    async startVpnExtensionAbility(){launches++;}
  };
  h.orch.pickPorts = async () => ({apiPort:29090,mixedPort:27890,dnsPort:21053});
  h.orch.hydrateAndBuildProfile = async () => ({});
  h.orch.prepareConfigYaml = async text => text;
  h.orch.isSmartModelReady = h.orch.isGeoipReady = h.orch.isRuleProviderReady = () => false;
  h.orch.clearStartError = () => {};
  h.orch.readStartError = () => '';
  h.orch.readStartOk = () => launches > 0;
  h.orch.isCoreAliveByHeartbeat = () => false;
  h.orch.api.probeController = async () => probe;
  h.orch.confirmProfileApplied = () => {confirmations++;};
  h.orch.startCoreLogStream = () => {};
  return Object.assign(h,{confirmations:()=>confirmations,launches:()=>launches,resolvedNodes:()=>resolvedNodes});
}

await test('authenticated startup dispatches without a fixed warmup and resolves only its profile', async () => {
  const h = startupFixture({reachable:true,secretAccepted:true,httpCode:200});
  try {
    assert.equal(await h.orch.launchTestCore(), true, JSON.stringify(h.logs));
    assert.equal(h.confirmations(),1); assert.equal(h.launches(),1);
    assert.deepEqual(h.resolvedNodes(),[h.subs.nodes[0]]);
    assert.equal(h.timers.size,0,'an authenticated ready controller needs no artificial sleep');
  } finally { h.stop(); }
});

for(const code of [401,403]) await test(`foreign controller HTTP ${code} fails immediately without applying the profile`, async () => {
  const h = startupFixture({reachable:true,secretAccepted:false,httpCode:code});
  try {
    assert.equal(await h.orch.launchTestCore(),false);
    assert.equal(h.confirmations(),0); assert.equal(h.timers.size,0);
    assert.ok(h.logs.some(args=>String(args[1]).includes('测速端口 29090')));
  } finally { h.stop(); }
});

await test('a known live extension still gets its exit grace before replacement', async () => {
  const h = startupFixture({reachable:true,secretAccepted:true,httpCode:200});
  try {
    h.orch.isCoreAliveByHeartbeat = () => true;
    const pending = h.orch.launchTestCore(); await flush();
    assert.equal(h.launches(),0);
    const grace = [...h.timers].find(([,timer])=>timer.delay === 600);
    assert.ok(grace); h.timers.delete(grace[0]); grace[1].fn();
    assert.equal(await pending,true);assert.equal(h.launches(),1);
  } finally {h.stop();}
});

await test('a reusable headless channel returns immediately and retains idle recycling', async () => {
  const h = harness();
  try {
    h.orch.state = h.ConnState.DISCONNECTED;
    h.orch.ensureTestCore = async () => true;
    h.orch.lastSettingsForLatency = async () => ({});
    const api = await h.orch.ensureLatencyApi(true);
    assert.equal(api,h.orch.api);
    assert.equal(h.timers.size,1);
    assert.equal([...h.timers.values()][0].delay,600000);
  } finally { h.stop(); }
});
console.log(`RESULT: ${passed} latency startup runtime checks passed`);
