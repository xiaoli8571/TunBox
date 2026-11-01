#!/usr/bin/env node
// Replay captured /connections through the current production method, not a copy.
// Inputs: positional paths, or TUNBOX_CONNECTIONS_FIXTURE / TUNBOX_PROXIES_FIXTURE.
// TUNBOX_SMART_GROUP optionally selects a group; otherwise one Smart group must exist.
// --self-test uses synthetic responses to test this gate only, never device acceptance.
import { readFileSync, existsSync } from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import assert from 'node:assert/strict';

const source = readFileSync(new URL('../entry/src/main/ets/commons/services/ClashApiService.ets', import.meta.url), 'utf8');
const start = source.indexOf('  async smartActiveNodes(');
const end = source.indexOf('\n  /** 在指定代理组选择节点', start);
assert.ok(start >= 0 && end > start, 'Cannot locate production smartActiveNodes method');
const method = stripTypeScriptTypes(`class Probe {\n${source.slice(start, end)}\n}\nglobalThis.Probe = Probe;`);
async function replay(body, group, names, responseCode = 200) {
  let destroyed = false;
  const context = vm.createContext({
    http: { RequestMethod: { GET: 0 }, createHttp: () => ({
      request: async () => ({ responseCode, result: JSON.stringify(body) }),
      destroy: () => { destroyed = true; }
    }) },
    util: {}, AppLogger: { warn() {} }, TAG: 'test'
  });
  vm.runInContext(method, context);
  const probe = new context.Probe();
  probe.baseUrl = () => 'http://127.0.0.1:9090';
  probe.authHeader = () => ({});
  probe.errText = String;
  const result = await probe.smartActiveNodes(group, names);
  assert.equal(destroyed, true, 'production method must release the HTTP request');
  return result === null ? null : Array.from(result);
}
function inputs(connections, proxies, requestedGroup = '') {
  assert.ok(connections?.connections != null, 'No active connections in capture; record Smart traffic before release acceptance');
  assert.ok(Array.isArray(connections.connections), 'Capture must contain a connections array');
  const table = proxies?.proxies;
  assert.ok(table && typeof table === 'object', 'Capture must contain a proxies object');
  const candidates = Object.keys(table).filter(name => String(table[name]?.type).toLowerCase() === 'smart');
  const group = requestedGroup || (candidates.length === 1 ? candidates[0] : '');
  assert.ok(group && String(table[group]?.type).toLowerCase() === 'smart'
    && Array.isArray(table[group]?.all), 'Select one captured Smart group with TUNBOX_SMART_GROUP');
  const groupTypes = new Set(['smart', 'selector', 'select', 'urltest', 'url-test', 'fallback', 'loadbalance', 'load-balance', 'relay']);
  const names = table[group].all.filter(name => typeof name === 'string' && name !== group
    && !['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'GLOBAL'].includes(name)
    && !groupTypes.has(String(table[name]?.type).toLowerCase()));
  assert.ok(names.length > 0, 'Selected group has no concrete outbound names');
  const related = connections.connections.filter(conn => Array.isArray(conn?.chains) && conn.chains.includes(group));
  assert.ok(related.length > 0, 'No active connection traverses the selected group; capture during traffic');
  // Independent oracle: each relevant chain must identify exactly one concrete node.
  // Deduplicate nodes across connections; unrelated traffic is not a failure.
  const expected = new Set();
  for (const conn of related) {
    const hits = names.filter(name => conn.chains.includes(name));
    assert.equal(hits.length, 1, 'A selected-group connection has missing/ambiguous node identity');
    expected.add(hits[0]);
  }
  return { group, names, expected: [...expected], related: related.length };
}
async function verify(connections, proxies, group) {
  const data = inputs(connections, proxies, group);
  const got = await replay(connections, data.group, data.names);
  assert.notEqual(got, null, 'Production method rejected captured connections');
  assert.deepEqual([...got].sort(), data.expected.sort(), 'Production resolution differs from capture node membership');
  assert.equal(got.length, new Set(got).size, 'Duplicate outbound nodes');
  return data;
}

if (process.argv.includes('--self-test')) {
  const group = 'Smart sample';
  const proxies = { proxies: { [group]: { type: 'Smart', all: ['Node A', 'Node B', 'DIRECT'] },
    'Node A': { type: 'Shadowsocks' }, 'Node B': { type: 'Trojan' }, DIRECT: { type: 'Direct' } } };
  const connections = { connections: [
    { chains: ['Node A', group] }, { chains: [group, 'Node A'] },
    { chains: ['Node B', group] }, { chains: ['DIRECT'] }
  ] };
  await verify(connections, proxies, group);
  await assert.rejects(() => verify({ connections: [] }, proxies, group));
  await assert.rejects(() => verify({ connections: [{ chains: [group, 'Missing'] }] }, proxies, group));
  await assert.rejects(() => verify({ connections: [{ chains: [group, 'Node A', 'Node B'] }] }, proxies, group));
  assert.deepEqual(await replay({}, group, ['Node A']), []);
  assert.equal(await replay(connections, group, ['Node A'], 503), null);
  console.log('PASS synthetic gate self-test: actual production method, duplicates, order, unrelated traffic, missing/ambiguous nodes, no traffic and HTTP failure');
} else {
  const connsPath = process.argv[2] || process.env.TUNBOX_CONNECTIONS_FIXTURE;
  const proxiesPath = process.argv[3] || process.env.TUNBOX_PROXIES_FIXTURE;
  if (!connsPath && !proxiesPath) {
    console.log('SKIP: 需要真机抓包 /connections + /proxies（位置参数或 TUNBOX_CONNECTIONS_FIXTURE / TUNBOX_PROXIES_FIXTURE）');
  } else {
    try {
      assert.ok(connsPath && proxiesPath && existsSync(connsPath) && existsSync(proxiesPath), 'Both supplied capture files must exist');
      const result = await verify(JSON.parse(readFileSync(connsPath, 'utf8')),
        JSON.parse(readFileSync(proxiesPath, 'utf8')), process.env.TUNBOX_SMART_GROUP || '');
      console.log(`PASS captured connections replay: ${result.related} relevant connections, ${result.expected.length} concrete outbound nodes`);
      console.log('Scope: captured API payload replay only; not proof of UI rendering or device liveness');
    } catch (error) {
      console.error(`FAIL captured connections acceptance: ${error.message}`);
      process.exitCode = 1;
    }
  }
}
