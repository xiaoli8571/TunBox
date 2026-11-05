// Run the production TCP transport and batch engine. Only NetworkKit's socket
// boundary is replaced: scripted OS event ordering, then real loopback TCP.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import net from 'node:net';
import { stripTypeScriptTypes } from 'node:module';

const source = fs.readFileSync(new URL('../entry/src/main/ets/commons/tunbox/TunBoxDelay.ets', import.meta.url), 'utf8');
const crlf = '\r\n';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const frame = (code = 200, body = '{"delay":42}') => Buffer.concat([
  Buffer.from(`HTTP/1.1 ${code} Test${crlf}Content-Length: ${Buffer.byteLength(body)}${crlf}${crlf}`), Buffer.from(body)
]);
function load(text = source) {
  let factory;
  const context = vm.createContext({ setTimeout, clearTimeout, console, TextDecoder, Uint8Array,
    AppSettings: { DEFAULT_DELAY_TEST_TIMEOUT: 5000 }, LatencyTestUrl: { DEFAULT_URL: 'https://test.example/204' },
    AppLogger: { info() {}, warn() {}, error() {}, errText: String },
    util: { TextDecoder: { create: () => ({ decodeWithStream: bytes => new TextDecoder().decode(bytes) }) } },
    socket: { constructTCPSocketInstance: () => factory() } });
  const code = text.replace(/^import\b[\s\S]*?;\r?\n/gm, '').replace(/^export /gm, '');
  const types = vm.runInContext(stripTypeScriptTypes(`(()=>{${code}\nreturn {ArkTcpDelayHttpTransport,TunBoxDelayRun,TunBoxDelayPolicy,DelayTarget}})()`, {mode:'transform'}), context);
  return { ...types, setFactory(value) { factory = value; } };
}
class ScriptedSocket {
  listeners = new Map(); closed = 0; payload = '';
  constructor(script, closeReject = false) { this.script = script; this.closeReject = closeReject; }
  on(name, fn) { this.listeners.set(name, fn); }
  off(name) { this.listeners.delete(name); }
  emit(name, value) { this.listeners.get(name)?.(value); }
  message(bytes) { this.emit('message', {message: Uint8Array.from(bytes).buffer}); }
  async connect() {}
  async send({data}) { this.payload = data; this.script(this); }
  async close() { this.closed++; if (this.closeReject) throw Error('already closed'); }
}
const production = load();
let passed = 0;
async function test(name, fn) { await fn(); passed++; console.log('PASS ' + name); }
function start(script, guard = 80, closeReject = false, code = production) {
  const socket = new ScriptedSocket(script, closeReject);
  code.setFactory(() => socket);
  const handle = new code.ArkTcpDelayHttpTransport().send(
    'http://127.0.0.1:9090/proxies/%E9%A6%99%E6%B8%AF/delay?url=x&timeout=5000', {Authorization:'Bearer fixture-secret'}, guard);
  return {socket, handle};
}
const closeFirst = socket => {
  socket.emit('close');
  setTimeout(() => socket.message(frame()), 5);
};
await test('device ordering: close before queued HTTP 200 does not discard success', async () => {
  const {socket, handle} = start(closeFirst);
  const reply = await handle.promise;
  assert.equal(reply.responseCode, 200); assert.equal(reply.body, '{"delay":42}');
  assert.equal(socket.closed, 1); assert.equal(socket.listeners.size, 0);
  assert.match(socket.payload, /Connection: keep-alive\r\n/);
  assert.match(socket.payload, /Authorization: Bearer fixture-secret\r\n/);
  assert.match(socket.payload, /^GET \/proxies\/%E9%A6%99%E6%B8%AF\/delay\?url=x&timeout=5000 HTTP\/1.1\r\n/);
});
await test('negative control: restoring close-as-success loses that exact response', async () => {
  const changed = source.replace('peerClosed = true;', 'succeed(new DelayHttpReply());');
  assert.notEqual(changed, source);
  const old = load(changed);
  const reply = await start(closeFirst, 80, false, old).handle.promise;
  assert.throws(() => assert.equal(reply.responseCode, 200));
  assert.equal(reply.responseCode, 0);
  await sleep(10);
});
await test('split headers/body and split UTF-8 bytes use byte lengths, including close-before-last-message', async () => {
  const body = '{"delay":123,"name":"香港😀"}';
  const {handle} = start(socket => {
    const bytes = frame(200, body);
    for (let i = 0; i < bytes.length - 1; i++) socket.message(bytes.subarray(i, i + 1));
    socket.emit('close');
    setTimeout(() => socket.message(bytes.subarray(-1)), 5);
  });
  assert.equal((await handle.promise).body, body);
});
await test('chunked frames include extensions and trailers, without waiting for EOF', async () => {
  const raw = 'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7;x=y\r\n{"delay\r\n5\r\n":42}\r\n0\r\nX-Trace: fixture\r\n\r\n';
  const {handle} = start(socket => {
    for (const byte of Buffer.from(raw)) socket.message([byte]);
  });
  assert.equal((await handle.promise).body, '{"delay":42}');
});
await test('HTTP 503 and 504 remain actual failed/timeout results, not missing responses', async () => {
  for (const code of [503, 504]) {
    const {handle} = start(socket => {socket.emit('close'); socket.message(frame(code,'{"message":"Timeout"}'));});
    assert.equal((await handle.promise).responseCode, code);
  }
});
await test('empty or truncated close is no verdict, never success or node timeout', async () => {
  for (const bytes of [Buffer.alloc(0), frame().subarray(0, -1)]) {
    const {socket, handle} = start(s => {s.message(bytes);s.emit('close');}, 20);
    await assert.rejects(handle.promise, /incomplete/);
    assert.equal(socket.closed, 1); assert.equal(socket.listeners.size, 0);
  }
});
await test('malformed and unbounded responses fail without leaking socket handles', async () => {
  const cases = [
    'BAD\r\nContent-Length: 0\r\n\r\n',
    'HTTP/1.1 200 OK\r\n\r\n{"delay":42}',
    'HTTP/1.1 200 OK\r\nContent-Length: 999999\r\n\r\n',
    'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nz\r\n',
    'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 1\r\n\r\n',
    'x'.repeat(65537)
  ];
  for (const raw of cases) {
    const {socket, handle} = start(s => s.message(Buffer.from(raw)));
    await assert.rejects(handle.promise); assert.equal(socket.closed, 1);
    assert.equal(socket.listeners.size, 0);
  }
});
await test('abort wins over queued success, and async close rejection is consumed', async () => {
  const {socket, handle} = start(() => {}, 80, true);
  const rejected = assert.rejects(handle.promise, /aborted/);
  handle.abort(); handle.abort(); socket.message(frame());
  await rejected; await sleep(5);
  assert.equal(socket.closed, 1); assert.equal(socket.listeners.size, 0);
});
await test('production 32-worker TCP batch completes across two waves and closes every connection', async () => {
  const peers = new Set(); let requests = 0;
  const server = net.createServer(peer => {
    peers.add(peer); peer.on('close', () => peers.delete(peer)); peer.on('error', () => {});
    let request = '';
    peer.on('data', bytes => {
      request += bytes.toString();
      if (!request.includes('\r\n\r\n')) return;
      requests++; assert.match(request, /Connection: keep-alive\r\n/);
      const path = request.split(' ')[1];
      const code = path.includes('/timeout/') ? 504 : path.includes('/failed/') ? 503 : 200;
      setTimeout(() => { if (!peer.destroyed) peer.write(frame(code)); }, 5);
    });
  });
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  class NodeSocket extends ScriptedSocket {
    constructor() { super(() => {}); this.peer = new net.Socket();
      this.peer.on('data', bytes => this.message(bytes));
      this.peer.on('close', () => this.emit('close'));
      this.peer.on('error', err => this.emit('error',err));
    }
    async connect({address}) { await new Promise((resolve,reject) => {
      this.peer.once('error',reject); this.peer.connect(address.port,address.address,resolve);
    }); }
    async send({data}) { await new Promise((resolve,reject) => this.peer.write(data,err => err ? reject(err) : resolve())); }
    async close() { this.peer.destroy(); }
  }
  production.setFactory(() => new NodeSocket());
  try {
    const run = new production.TunBoxDelayRun(`http://127.0.0.1:${server.address().port}`, '',
      new production.ArkTcpDelayHttpTransport(), new production.TunBoxDelayPolicy(32,5000,500));
    const names = [...Array.from({length:38},(_,i)=>`ok${i}`),'timeout','failed'];
    const results = [];
    const summary = await new Promise(resolve => run.start(names.map(name => new production.DelayTarget(name)), r => results.push(r), resolve));
    assert.deepEqual([summary.total,summary.measured,summary.timedOut,summary.failed,summary.cancelled], [40,38,1,1,0]);
    assert.equal(summary.wasCancelled,false); assert.equal(summary.peakInflight,32);
    assert.equal(requests,40); assert.equal(results.length,40);
    await sleep(20); assert.equal(peers.size,0);
  } finally { for (const peer of peers) peer.destroy(); await new Promise(resolve => server.close(resolve)); }
});
console.log(`RESULT: ${passed} production TCP transport checks passed`);
