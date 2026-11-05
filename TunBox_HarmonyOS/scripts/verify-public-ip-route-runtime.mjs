// Production HTTP route/proxy/IP code with HarmonyOS HTTP and ArkUI boundaries mocked.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import vm from 'node:vm';
const base = new URL('../entry/src/main/ets/', import.meta.url);
const read = file => readFileSync(new URL(file, base), 'utf8');
const deferred = () => { let resolve; const promise = new Promise(r => { resolve = r; }); return { promise, resolve }; };
async function flush() { for (let n = 0; n < 100; n++) await Promise.resolve(); }
function load(context, file, exports) {
  const text = read(file).replace(/^import\b[^;]+;\r?\n/gm, '').replace(/^export /gm, '');
  const result = vm.runInContext(stripTypeScriptTypes(`(() => { ${text}; return {${exports}}; })()`, { mode: 'transform' }), context);
  Object.assign(context, result); return result;
}
let passed = 0;
async function test(name, run) { await run(); passed++; console.log('PASS ' + name); }
const primary = ip => ({ responseCode: 200, result: JSON.stringify({ status: 'success', query: ip }) });
const fallback = ip => ({ responseCode: 200, result: JSON.stringify({ ip }) });
const rejected = { responseCode: 200, result: '{"status":"fail","message":"rate limit"}' };
function fixture() {
  let now = 1000000;
  const h = { calls: [], responses: [], probeGate: null, probeFails: false, logs: [], destroyed: 0 };
  class Clock extends Date { static now() { return now; } }
  const context = vm.createContext({ Date: Clock, Promise, Math, Map, JSON, Number, ArrayBuffer, Uint8Array,
    setTimeout(fn, ms) { now += ms; Promise.resolve().then(fn); return 1; },
    util: {
      TextEncoder: { create: () => ({ encodeInto: s => new TextEncoder().encode(s) }) },
      TextDecoder: { create: () => ({ decodeToString: s => new TextDecoder().decode(s) }) }
    }, connection: { setAppHttpProxy() {} }, http: { RequestMethod: { GET: 'GET' }, createHttp() {
      return { async request(url, options) {
        h.calls.push({ url, options });
        if (url.includes('127.0.0.1')) {
          if (h.probeGate) { const gate = h.probeGate; h.probeGate = null; return gate.promise; }
          if (h.probeFails) throw Error('connection refused');
          return { responseCode: 400, result: '' };
        }
        const reply = h.responses.shift();
        if (reply instanceof Error) throw reply;
        if (typeof reply === 'function') return reply();
        assert.ok(reply, 'unexpected external HTTP request'); return reply;
      }, destroy() { h.destroyed++; } };
    } }, AppLogger: { info: (...x) => h.logs.push(x), warn: (...x) => h.logs.push(x), errText: String } });
  load(context, 'commons/models/PublicIpInfo.ets', 'PublicIpInfo');
  const { AppProxyRoute: route } = load(context, 'commons/services/AppProxyRoute.ets', 'AppProxyRoute');
  const { PublicIpService: service } = load(context, 'commons/services/PublicIpService.ets', 'PublicIpService');
  return Object.assign(h, { route, service, external: () => h.calls.filter(x => !x.url.includes('127.0.0.1')),
    async ready(port = 7890) { route.apply(port); assert.equal(await route.waitUntilReady(), true); } });
}
await test('proxy-required query never sends a direct request when no channel exists', async () => {
  const h = fixture(); assert.equal((await h.service.query('connected')).ip, ''); assert.equal(h.calls.length, 0);
});
await test('connected query uses an explicit loopback proxy only after readiness', async () => {
  const h = fixture(); await h.ready(); h.responses.push(primary('198.51.100.1'));
  assert.equal((await h.service.query('connected')).ip, '198.51.100.1');
  assert.equal(h.external()[0].options.usingProxy.host, '127.0.0.1');
  assert.equal(h.external()[0].options.usingProxy.port, 7890);
  assert.ok(h.logs.every(x => !String(x).includes('198.51.100.1')));
});
await test('primary rejection and HTTPS fallback use the same proxy', async () => {
  const h = fixture(); await h.ready(); h.responses.push(rejected, fallback('198.51.100.2'));
  assert.equal((await h.service.query('fallback')).ip, '198.51.100.2');
  assert.equal(h.external().length, 2); assert.ok(h.external().every(x => x.options.usingProxy.port === 7890));
});
await test('network retry cannot change route or silently fall back to direct', async () => {
  const h = fixture(); await h.ready(); h.responses.push(Error('timeout'), rejected, fallback('198.51.100.3'));
  assert.equal((await h.service.query('retry')).ip, '198.51.100.3');
  assert.equal(h.external().length, 3); assert.ok(h.external().every(x => x.options.usingProxy.port === 7890));
});
await test('a route change discards old IP and prevents another request', async () => {
  const h = fixture(), gate = deferred(); await h.ready(); h.responses.push(() => gate.promise);
  const query = h.service.query('old-session'); await flush();
  h.route.clear(); await h.ready(17890); gate.resolve(primary('198.51.100.4'));
  assert.equal((await query).ip, ''); assert.equal(h.external().length, 1);
});
await test('a caller cancelled during a failed request cannot start retries', async () => {
  const h = fixture(), gate = deferred(); await h.ready(); h.responses.push(() => gate.promise);
  let current = true; const query = h.service.query('old', true, () => current); await flush();
  current = false; gate.resolve(rejected); assert.equal((await query).ip, ''); assert.equal(h.external().length, 1);
});
await test('a bound but unready proxy cannot query the external endpoint directly', async () => {
  const h = fixture(); h.route.apply(7890); h.probeFails = true;
  assert.equal((await h.service.query('unready')).ip, ''); assert.equal(h.external().length, 0);
  assert.ok(h.calls.every(x => x.options.usingProxy === false));
});
await test('a late readiness result cannot validate a new session reusing the same port', async () => {
  const h = fixture(), gate = deferred(); h.route.apply(7890); h.probeGate = gate;
  const ready = h.route.waitUntilReady(); await flush(); h.route.clear(); h.route.apply(7890);
  gate.resolve({ responseCode: 400 }); assert.equal(await ready, false); assert.equal(h.route.isReady(), false);
  assert.equal(await h.route.waitUntilReady(), true);
});
await test('explicit disconnected queries use direct routing and are invalidated by connection start', async () => {
  const h = fixture(); h.responses.push(primary('198.51.100.5'));
  assert.equal((await h.service.query('disconnected', false)).ip, '198.51.100.5');
  assert.equal(h.external()[0].options.usingProxy, false);
  const gate = deferred(); h.responses.push(() => gate.promise);
  const next = h.service.query('disconnected', false); await flush(); h.route.clear();
  gate.resolve(primary('198.51.100.5')); assert.equal((await next).ip, '');
});

function method(file, name) {
  const text = read(file), match = new RegExp(`^  (?:private )?(?:async )?${name}\\(`, 'm').exec(text);
  assert.ok(match, name); const end = text.indexOf('\n  }', match.index);
  return text.slice(match.index, end + 4);
}
function pageFixture(stats = false) {
  const timers = new Map(), calls = []; let id = 0;
  const states = { DISCONNECTED: 0, CONNECTING: 1, CONNECTED: 2, DISCONNECTING: 3, RECOVERING: 4, ERROR: 6 };
  const context = vm.createContext({ Promise, Date, AppLogger: { warn() {}, errText: String }, ConnState: states,
    setTimeout(fn, delay) { const token = ++id; timers.set(token, { fn, delay }); return token; },
    clearTimeout(token) { timers.delete(token); }, AppStorage: { setOrCreate() {} },
    UiGuardian: { isRegistered: () => true, isWatching: () => false }, countryCodeToFlag: () => '',
    PublicIpService: { async query(...args) { calls.push(args); return h.response ? h.response(...args) : { ip: '' }; } } });
  const file = stats ? 'pages/StatsPage.ets' : 'pages/HomePage.ets';
  const methods = stats ? ['queryIp', 'clearIpInfo']
    : ['refreshPublicIp', 'invalidatePublicIpQueries', 'schedulePublicIpRecover', 'stopPublicIpRecover', 'applyOrchestratorState'];
  const Page = vm.runInContext(stripTypeScriptTypes(`class Page { ${methods.map(n => method(file, n)).join('\n')} }; Page;`,
    { mode: 'transform' }), context);
  const page = new Page(); Object.assign(page, { publicIp: '', publicIpError: '', publicIpRefreshing: false,
    ipQuerySeq: 0, ipRecoverTimer: -1, ipRecoverTries: 0, isConnected: true, pageMounted: true,
    ipRequestId: 0, ipBusy: false, ipQueuedTrigger: '', refreshDisplayNode() {}, syncMiniConnectionState() {},
    orchestrator: { state: states.CONNECTED, currentNodeName: () => 'node', lastError: '' } });
  const h = { page, timers, calls, states, response: null, async tick() {
    const entry = timers.entries().next().value; assert.ok(entry); timers.delete(entry[0]); entry[1].fn(); await flush();
  } }; return h;
}
await test('home never requests an IP during connect/disconnect/recovery', async () => {
  const h = pageFixture();
  for (const state of [h.states.CONNECTING, h.states.DISCONNECTING, h.states.RECOVERING]) {
    h.page.orchestrator.state = state; await h.page.refreshPublicIp('transition', true);
  }
  assert.equal(h.calls.length, 0); assert.equal(h.page.publicIpRefreshing, false);
});
await test('automatic reconnection clears old direct IP and schedules a fresh exit query', async () => {
  const h = pageFixture(); h.page.isConnected = false; h.page.publicIp = 'old-direct-ip';
  h.page.applyOrchestratorState(); assert.equal(h.page.publicIp, ''); assert.equal(h.timers.size, 1);
});
await test('an old failure cannot overwrite a newer successful exit IP', async () => {
  const h = pageFixture(), old = deferred(); h.response = () => old.promise;
  const first = h.page.refreshPublicIp('old', true); h.response = () => ({ ip: 'new-exit' });
  await h.page.refreshPublicIp('new', true); old.resolve({ ip: '' }); await first;
  assert.equal(h.page.publicIp, 'new-exit'); assert.equal(h.page.publicIpError, '');
});
await test('waiting for an in-flight IP query does not exhaust the retry budget', async () => {
  const h = pageFixture(); h.page.publicIpRefreshing = true; h.page.schedulePublicIpRecover();
  for (let i = 0; i < 7; i++) await h.tick(); assert.equal(h.page.ipRecoverTries, 0);
  h.page.publicIpRefreshing = false; h.response = () => ({ ip: 'exit' }); await h.tick();
  assert.equal(h.page.ipRecoverTries, 1); assert.equal(h.page.publicIp, 'exit');
});
await test('stats queries require the proxy and become stale when the page disappears', async () => {
  const h = pageFixture(true); h.response = () => ({ ip: 'exit' }); await h.page.queryIp('shown');
  assert.equal(h.calls[0][1], true); assert.equal(h.calls[0][2](), true);
  h.page.pageMounted = false; assert.equal(h.calls[0][2](), false);
});
await test('stats shown/bootstrap share a query while a new session still queues a fresh one', async () => {
  const h = pageFixture(true), gate = deferred(); h.response = () => gate.promise;
  const first = h.page.queryIp('shown'); await h.page.queryIp('bootstrap');
  assert.equal(h.calls.length, 1); assert.equal(h.page.ipQueuedTrigger, '');
  h.page.clearIpInfo(); await h.page.queryIp('new-session');
  assert.equal(h.page.ipQueuedTrigger, 'new-session');
  h.response = () => ({ ip: 'new-exit' }); gate.resolve({ ip: 'old-exit' }); await first; await flush();
  assert.equal(h.calls.length, 2); assert.equal(h.page.ipText, 'new-exit');
});
console.log(`RESULT: ${passed} public IP route/runtime cases passed`);
