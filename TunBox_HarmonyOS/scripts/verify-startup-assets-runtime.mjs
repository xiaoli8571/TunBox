// Production installer + runtime builder; real files, bundled data and same-source Mihomo.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import net from 'node:net';
import { stripTypeScriptTypes } from 'node:module';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import crypto from 'node:crypto';
import zlib from 'node:zlib';

if (!process.execArgv.includes('--experimental-transform-types')) {
  const child = spawnSync(process.execPath, ['--experimental-transform-types', '--no-warnings',
    fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const ets = path.join(root, 'entry/src/main/ets');
const rawDir = path.join(root, 'entry/src/main/resources/rawfile');
const geoBytes = name => {
  const compressed = path.join(rawDir, name + '.gz');
  return fs.existsSync(compressed)
    ? zlib.gunzipSync(fs.readFileSync(compressed))
    : fs.readFileSync(path.join(rawDir, name));
};
const tempRoot = fs.realpathSync(os.tmpdir());
const scratch = fs.mkdtempSync(path.join(tempRoot, 'tunbox-startup-assets-'));
const baseline = process.argv.includes('--baseline');
let installerSource = fs.readFileSync(path.join(ets, 'commons/services/GeoDataInstaller.ets'), 'utf8');
if (baseline) {
  const old = spawnSync('git', ['show', 'HEAD:TunBox_HarmonyOS/entry/src/main/ets/commons/services/GeoDataInstaller.ets'],
    { cwd: root, encoding: 'utf8' });
  assert.equal(old.status, 0, old.stderr); installerSource = old.stdout;
}
const logger = { info() {}, warn() {}, errText: String };
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const sameFile = (actual, expected) => assert.equal(
  digest(fs.readFileSync(actual)),
  digest(Buffer.isBuffer(expected) ? expected : fs.readFileSync(expected))
);
function load(source, names, context) {
  const text = source.replace(/^import\b[\s\S]*?;\r?\n/gm, '').replace(/^export /gm, '');
  return vm.runInContext(stripTypeScriptTypes(`(()=>{${text}\nreturn {${names}};})()`,
    { mode: 'transform' }), context);
}
let serial = 0, passed = 0, failed = 0;
function harness() {
  const dir = path.join(scratch, 'installer-' + serial++); fs.mkdirSync(dir);
  const state = { reads: 0, writes: 0, resourceFailure: false, writeFailure: false,
    shortWrite: false, views: false, corruptResource: false, gzReads: [], stagingLeft: [] };
  const handles = new Map();
  const io = {
    accessSync: fs.existsSync,
    OpenMode: { READ_WRITE: fs.constants.O_RDWR, READ_ONLY: fs.constants.O_RDONLY,
      CREATE: fs.constants.O_CREAT, TRUNC: fs.constants.O_TRUNC },
    statSync(file) { const s = fs.statSync(file); return { size: s.size, mtime: s.mtimeMs, ino: s.ino }; },
    openSync(file, flags) { const fd = fs.openSync(file, flags); handles.set(fd, file); return { fd }; },
    closeSync(file) { handles.delete(file.fd); fs.closeSync(file.fd); },
    readSync(fd, buffer, options = {}) { return fs.readSync(fd, Buffer.from(buffer), 0, options.length ?? buffer.byteLength, options.offset ?? null); },
    writeSync(fd, buffer) {
      state.writes++;
      if (state.writeFailure && path.basename(handles.get(fd)).startsWith('geoip.metadb')) {
        state.writeFailure = false; throw Error('injected write failure');
      }
      const data = Buffer.from(buffer);
      return fs.writeSync(fd, state.shortWrite ? data.subarray(0, 8) : data);
    },
    renameSync: fs.renameSync, unlinkSync: fs.unlinkSync,
  };
  // 生产实现用 @ohos.zlib 的 GZip 流式接口（native C 解压）。这里用 Node 的 zlib
  // 提供同语义 stub：open 读整个文件并 gunzip、read 分块吐、close 收尾；
  // 单次上限 512KB 是为了强制走多轮 read 循环（真机 1MB 分块同理）。
  // 支持 gzopen(path) 与 gzdopen(fd) 两个入口、gzread / gzfread 两种读法，
  // 以及 state.gzOpenBroken（复现真机 17800009：gzopen 坏、gzdopen 好）。
  const makeGzip = () => {
    let plain = null, pos = 0, ownFd = null;
    const open = (name, fd) => {
      state.gzReads.push(`open:${name}`);
      if (state.corruptResource) { plain = null; throw Error('17800009 injected gzip failure'); }
      plain = zlib.gunzipSync(fs.readFileSync(fd === null ? name : handles.get(fd)));
      pos = 0; ownFd = fd;
    };
    const pull = (buf, limit) => {
      assert.ok(plain !== null, 'read before open');
      const want = Math.max(0, Math.min(buf.byteLength, limit, 512 * 1024, plain.length - pos));
      Buffer.from(buf).set(plain.subarray(pos, pos + want)); pos += want;
      state.gzReads.push(want);
      return want;
    };
    return {
      async gzopen(file, mode) {
        assert.ok(mode === 'r' || mode === 'rb', 'gzopen must open in read mode');
        if (state.gzOpenBroken) { throw Error('17800009 Internal structure error'); }
        open(file, null);
      },
      async gzdopen(fd, mode) {
        assert.ok(mode === 'r' || mode === 'rb', 'gzdopen must open in read mode');
        open('fd', fd);
      },
      async gzread(buf) { return pull(buf, buf.byteLength); },
      async gzfread(buf, size, nitems) {
        assert.equal(size, 1, 'production reads one byte-block per item');
        return pull(buf, size * nitems);
      },
      async gzclose() {
        if (ownFd !== null) { try { fs.closeSync(ownFd); } catch (e) { /* already closed */ } }
        plain = null; pos = 0; ownFd = null;
        state.gzReads.push('close'); return 0;
      },
    };
  };
  const zlibStub = { async createGZip() { return makeGzip(); }, createGZipSync() { return makeGzip(); } };
  const context = { cacheDir: dir, resourceManager: { getRawFileContentSync(name) {
    state.reads++;
    if (state.resourceFailure) throw Error('injected missing resource');
    const raw = fs.readFileSync(path.join(rawDir, name));
    if (!state.views) return new Uint8Array(raw);
    const buffer = new Uint8Array(raw.length + 10); buffer.set(raw, 4);
    return buffer.subarray(4, raw.length + 4);
  } } };
  const sandbox = vm.createContext({ fs: io, zlib: zlibStub,
    util: { generateRandomUUID: () => crypto.randomUUID() },
    HttpBodyCodec: { decompress: bytes => new Uint8Array(zlib.gunzipSync(Buffer.from(bytes))) },
    AppLogger: logger, Uint8Array, ArrayBuffer, Map, Math, setTimeout, Promise });
  const { GeoDataInstaller } = load(installerSource, 'GeoDataInstaller', sandbox);
  return { ...state, state, dir, context, sandbox, installer: GeoDataInstaller };
}
async function test(name, run) {
  try { await run(); passed++; console.log('PASS ' + name); }
  catch (e) { failed++; console.log('FAIL ' + name + ': ' + e.message); }
}
await test('copy failure can retry in the same process', async () => {
  const h = harness(); h.state.writeFailure = true; await h.installer.ensure(h.context);
  await h.installer.ensure(h.context);
  sameFile(path.join(h.dir, 'geoip.metadb'), geoBytes('geoip.metadb'));
});
await test('missing resources can recover without restarting the app', async () => {
  const h = harness(); h.state.resourceFailure = true; await h.installer.ensure(h.context);
  h.state.resourceFailure = false; await h.installer.ensure(h.context);
  assert.ok(fs.existsSync(path.join(h.dir, 'geoip.metadb')));
});
await test('deleted cache files are restored in the same process', async () => {
  const h = harness(); await h.installer.ensure(h.context); fs.unlinkSync(path.join(h.dir, 'geosite.dat'));
  await h.installer.ensure(h.context); assert.ok(fs.existsSync(path.join(h.dir, 'geosite.dat')));
});
await test('same-sized and larger corrupt files are repaired', async () => {
  const h = harness();
  for (const name of ['geoip.metadb', 'geosite.dat']) {
    fs.writeFileSync(path.join(h.dir, name), Buffer.alloc(geoBytes(name).length + 8, 0x58));
  }
  await h.installer.ensure(h.context);
  for (const name of ['geoip.metadb', 'geosite.dat']) {
    sameFile(path.join(h.dir, name), geoBytes(name));
  }
});
await test('shared resource-buffer views never write unrelated bytes', async () => {
  const h = harness(); h.state.views = true; await h.installer.ensure(h.context);
  sameFile(path.join(h.dir, 'geoip.metadb'), geoBytes('geoip.metadb'));
});
await test('short writes preserve the original file and leave no temporary files', async () => {
  const h = harness(); const old = Buffer.from('previous-invalid-database');
  fs.writeFileSync(path.join(h.dir, 'geoip.metadb'), old); h.state.shortWrite = true;
  await h.installer.ensure(h.context); assert.equal(digest(fs.readFileSync(path.join(h.dir, 'geoip.metadb'))), digest(old));
  assert.ok(!fs.readdirSync(h.dir).some(n => n.endsWith('.tmp') || n.endsWith('.gz')));
  h.state.shortWrite = false; await h.installer.ensure(h.context);
  assert.equal(fs.statSync(path.join(h.dir, 'geoip.metadb')).size, geoBytes('geoip.metadb').length);
});
await test('corrupt gzip never leaves a half-written geo file', async () => {
  const h = harness(); h.state.corruptResource = true;
  await h.installer.ensure(h.context);
  assert.ok(!fs.existsSync(path.join(h.dir, 'geoip.metadb')), 'failed inflate must not create the target');
  assert.ok(!fs.readdirSync(h.dir).some(n => n.endsWith('.tmp') || n.endsWith('.gz')), 'staging files must be cleaned');
  h.state.corruptResource = false; await h.installer.ensure(h.context);
  sameFile(path.join(h.dir, 'geoip.metadb'), geoBytes('geoip.metadb'));
});
await test('inflate is streamed in bounded chunks, not one full-明文 read', async () => {
  const h = harness(); await h.installer.ensure(h.context);
  const reads = h.state.gzReads.filter(v => typeof v === 'number' && v > 0);
  assert.ok(reads.length > 1, `expected multiple read rounds, got ${reads.length}`);
  assert.ok(reads.every(n => n <= 512 * 1024), 'each round must stay within the chunk budget');
  assert.equal(h.state.gzReads[h.state.gzReads.length - 1], 'close');
});
await test('gzdopen fallback rescues a device where gzopen is broken', async () => {
  // 2026-10-31 真机：gzopen + gzfread 报 17800009 Internal structure error，
  // 必须能在不换实现的前提下走 gzdopen(fd) 通道拿到同样的明文。
  const h = harness(); h.state.gzOpenBroken = true;
  await h.installer.ensure(h.context);
  sameFile(path.join(h.dir, 'geoip.metadb'), geoBytes('geoip.metadb'));
  sameFile(path.join(h.dir, 'geosite.dat'), geoBytes('geosite.dat'));
  assert.ok(h.state.gzReads.some(v => v === 'open:fd'), 'expected the gzdopen channel to be used');
  assert.ok(!fs.readdirSync(h.dir).some(n => n.endsWith('.tmp') || n.endsWith('.gz')));
});
await test('healthy cache is neither replaced nor reread from rawfile', async () => {
  const h = harness(); await h.installer.ensure(h.context); const writes = h.state.writes, reads = h.state.reads;
  await h.installer.ensure(h.context); assert.equal(h.state.writes, writes); assert.equal(h.state.reads, reads);
});

if (process.argv.includes('--installer-only')) {
  console.log(`RESULT: ${passed} passed, ${failed} failed (installer only; baseline=${baseline})`);
  if (path.dirname(fs.realpathSync(scratch)) === tempRoot && path.basename(scratch).startsWith('tunbox-startup-assets-')) {
    fs.rmSync(scratch, { recursive: true });
  }
  process.exit(failed ? 1 : 0);
}

// Always refresh generated production dependencies, then execute the actual runtime builder.
const prepare = spawnSync(process.execPath, [path.join(root, 'tools/true-chain-harness/prepare.mjs')], { encoding: 'utf8' });
assert.equal(prepare.status, 0, prepare.stderr);
const generated = name => pathToFileURL(path.join(root, 'tools/true-chain-harness/generated', name + '.ts'));
const settingsModule = await import(generated('AppSettings'));
const { ProxyNode } = await import(generated('ProxyNode'));
const { ClashConfigGenerator } = await import(generated('ClashConfigGenerator'));
const { ProfileConfigMerger } = await import(generated('ProfileConfigMerger'));
// 2026-11-05（FlClash 全量照抄）：profile-backed 走 TunBoxProfileBuilder ——
// 沙箱注入内核桥（mini-yaml 承接 fixture/overlay 解码；生产由内核 decodeYaml 承担）。
const { miniYamlParse } = await import(pathToFileURL(path.join(root, 'scripts/fixtures/mini-yaml.mjs')).href);
const decodeFixture = text => text.trimStart().startsWith('{') ? JSON.parse(text) : miniYamlParse(text);
const profileRegistry = new Map();
const sandboxCoreBridge = {
  async getProfileBase(p) {
    const text = profileRegistry.get(p);
    if (text === undefined) throw new Error(`sandbox: no profile registered at ${p}`);
    const doc = decodeFixture(text);
    const proxies = Array.isArray(doc['proxies']) ? doc['proxies'] : [];
    const groups = Array.isArray(doc['proxy-groups']) ? doc['proxy-groups'] : [];
    const rules = Array.isArray(doc['rules']) ? doc['rules'].map((x) => String(x)) : [];
    return { config: doc, digest: 'sandbox', proxies: proxies.length, proxyGroups: groups.length,
      rules: rules.length, matchRules: rules.filter((r) => r.toUpperCase().startsWith('MATCH,')) };
  },
  async decodeYaml(text) { return decodeFixture(text); },
};
const builderContext = vm.createContext({
  coreBridge: sandboxCoreBridge, ClashConfigGenerator,
  SubscriptionFetchPolicy: { tunboxUserAgent: () => 'TunBox/v-harness clash-verge Platform/OpenHarmony' },
  ProfileRepository: { pathOf: (id) => '/sandbox/profiles/' + id + '.yaml', dir: () => '/sandbox/profiles' },
  tunboxUserAgent: () => 'TunBox/v-harness clash-verge Platform/OpenHarmony',
  AppLogger: logger, Math, Map, Set, JSON, Date, console,
});
const { TunBoxProfileBuilder, TunBoxProfileInput } = load(
  fs.readFileSync(path.join(ets, 'commons/tunbox/TunBoxProfileBuilder.ets'), 'utf8'),
  'TunBoxProfileBuilder,TunBoxProfileInput', builderContext);

const { LatencyTestUrl } = await import(generated('LatencyTestUrl'));
const sandbox = vm.createContext({ AppSettings: settingsModule.AppSettings, AutoSelectModes: settingsModule.AutoSelectModes,
  ProxyNode, ClashConfigGenerator, ProfileConfigMerger, TunBoxProfileBuilder, TunBoxProfileInput, LatencyTestUrl,
  ProfileRepository: { pathOf: (id) => '/sandbox/profiles/' + id + '.yaml', dir: () => '/sandbox/profiles' },
  BASE_MTU: (await import(generated('VpnRecoveryPolicy'))).BASE_MTU, AppLogger: logger,
  DoHResolver: { async refreshStale() {}, async resolveMany() { return {}; } }, Math, Map, Set });
const runtime = load(fs.readFileSync(path.join(ets, 'commons/config/RuntimeConfigBuilder.ets'), 'utf8'),
  'RuntimeConfigProfile,RuntimeConfigBuilder,RuntimeConfigMode', sandbox);
const kernel = path.join(root, '../mihomo-build/mihomo-smart-462455136157a760937c666bba71afe33b1a809e/mihomo.exe');
assert.ok(fs.existsSync(kernel), 'same-source kernel is required');

// Execute the real final gate and model installer. Native parsing itself is
// covered by TestPrepareProfileSmartDoesNotInitialize in the same-source core.
function smartHarness() {
  const h = harness();
  h.sandbox.TAG = 'ConfigGate';
  const validator = load(fs.readFileSync(path.join(ets, 'commons/services/ConfigValidator.ets'), 'utf8'), 'ConfigValidator', h.sandbox);
  h.sandbox.ConfigValidator = validator.ConfigValidator;
  h.validationError = '';
  h.validated = [];
  h.sandbox.coreBridge = {
    async prepareProfile(text) {
      h.validated.push(text);
      if (h.validationError) throw Error(h.validationError);
      return text;
    },
    async decodeYaml(text) { return decodeFixture(text); }
  };
  const source = fs.readFileSync(path.join(ets, 'commons/services/ConnectionOrchestrator.ets'), 'utf8');
  const methods = ['prepareConfigYaml', 'isSmartModelReady', 'isSmartModelAvailable'].map(name => {
    const match = source.match(new RegExp(`^  (?:private )?(?:async )?${name}\\([\\s\\S]*?^  }`, 'm'));
    assert.ok(match, name); return match[0];
  });
  const Gate = vm.runInContext(stripTypeScriptTypes(`(()=>{class Gate {${methods.join('\n')}}return Gate})()`, {mode:'transform'}), h.sandbox);
  h.gate = Object.assign(new Gate(), {context: h.context});
  return h;
}
const smartDoc = (enabled = true, type = 'smart') => ({
  'proxy-groups': [{name:'♻️ 自动选择',type,proxies:['DIRECT'],uselightgbm:enabled}],
  rules:['MATCH,♻️ 自动选择']
});
function installManualModel(h) {
  const bytes = Buffer.alloc(1024 * 1024 + 1); bytes.write('tree');
  fs.writeFileSync(path.join(h.dir,'Model.bin'),bytes);
  fs.writeFileSync(path.join(h.dir,'Model.bin.manual'),'manual-v1');
  return bytes;
}
await test('final Smart overrides require manual installation, never bundle or download', async () => {
  for (const mode of ['auto','manual']) {
    const h = smartHarness(); const p = new runtime.RuntimeConfigProfile();
    p.profileId = 'smart-override'; p.profileYaml = JSON.stringify({'proxy-groups':[{name:'Main',type:'select',proxies:['DIRECT']}],rules:['MATCH,Main']});
    profileRegistry.set('/sandbox/profiles/smart-override.yaml', p.profileYaml);
    p.settings.autoSelectMode = mode; p.settings.hyperAdRulesEnabled = false; p.settings.customRules = [];
    p.settings.yamlOverride = JSON.stringify(smartDoc());
    const result = await runtime.RuntimeConfigBuilder.buildRuntimeConfig(p, runtime.RuntimeConfigMode.TEST);
    await assert.rejects(h.gate.prepareConfigYaml(result.yaml,'no-model'),/设置手动更新/);
    assert.equal(h.state.reads,0); assert.equal(h.state.writes,0);
    const bytes = installManualModel(h);
    assert.equal(await h.gate.prepareConfigYaml(result.yaml,'manual-model'),result.yaml);
    sameFile(path.join(h.dir,'Model.bin'),bytes);
    assert.equal(h.state.reads,0); assert.equal(h.state.writes,0);
  }
});
await test('missing LightGBM model fails before core startup; non-LightGBM policies stay usable', async () => {
  for (const [enabled,type,required] of [[1,'smart',true],[-1,'smart',true],[0,'smart',false],[false,'smart',false],[true,'url-test',false]]) {
    const h = smartHarness(), text=JSON.stringify(smartDoc(enabled,type));
    if(required) await assert.rejects(h.gate.prepareConfigYaml(text,'option'),/设置手动更新/);
    else assert.equal(await h.gate.prepareConfigYaml(text,'option'),text);
    assert.deepEqual(fs.readdirSync(h.dir),[]);
    assert.equal(h.state.reads,0);assert.equal(h.state.writes,0);
  }
});
await test('legacy bundled cache is not manual installation; invalid models never become ready', async () => {
  const h = smartHarness(), bytes=installManualModel(h);
  assert.equal(h.gate.isSmartModelAvailable(),true);
  fs.unlinkSync(path.join(h.dir,'Model.bin.manual'));
  assert.equal(h.gate.isSmartModelAvailable(),false);
  await assert.rejects(h.gate.prepareConfigYaml(JSON.stringify(smartDoc()),'legacy-model'),/设置手动更新/);
  sameFile(path.join(h.dir,'Model.bin'),bytes);
  fs.writeFileSync(path.join(h.dir,'Model.bin.manual'),'manual-v1');
  fs.writeFileSync(path.join(h.dir,'Model.bin'),Buffer.from('tree-truncated'));
  assert.equal(h.gate.isSmartModelAvailable(),false);
  assert.equal(h.state.reads,0);assert.equal(h.state.writes,0);
});
await test('native final-validation errors abort before model writes or config publication', async () => {
  const h = smartHarness(); h.validationError = 'rule proxy missing not found';
  await assert.rejects(h.gate.prepareConfigYaml(JSON.stringify(smartDoc()),'bad-final-reference'),/rule proxy missing not found/);
  assert.equal(h.state.reads,0); assert.equal(h.state.writes,0); assert.deepEqual(fs.readdirSync(h.dir),[]);
});
const node = new ProxyNode(); Object.assign(node, { id: 'a', name: 'A', originalName: 'A',
  proxyType: 'socks5', server: '127.0.0.1', port: 9 });
const profileYaml = 'proxies:\n  - {name: A, type: socks5, server: 127.0.0.1, port: 9}\nproxy-groups:\n  - {name: Main, type: select, proxies: [A]}\nrules:\n  - GEOIP,CN,DIRECT\n  - GEOSITE,cn,DIRECT\n  - MATCH,Main\n';
const liveConfigs = [];
for (const profileBacked of [false, true]) for (let flags = 0; flags < 16; flags++) {
  await test(`offline kernel: profile=${profileBacked} rule/ad/IPv6/sniff=${flags.toString(2).padStart(4, '0')}`, async () => {
    const h = harness(); await h.installer.ensure(h.context);
    fs.mkdirSync(path.join(h.dir, 'ruleset'));
    fs.copyFileSync(path.join(rawDir, 'hyper_adrules_ads.mrs'), path.join(h.dir, 'ruleset/hyper_adrules_ads.mrs'));
    const p = new runtime.RuntimeConfigProfile(); p.nodes = [node];
    p.settings.rulesEnabled = !!(flags & 1); p.settings.hyperAdRulesEnabled = !!(flags & 2);
    p.settings.ipv6Enabled = !!(flags & 4); p.settings.sniffingEnabled = !!(flags & 8);
    p.settings.customRules = ['GEOIP,US,DIRECT', 'DOMAIN-SUFFIX,example.com,REJECT'];
    p.settings.yamlOverride = 'geox-url:\n  mmdb: http://127.0.0.1:1/missing\n  geosite: http://127.0.0.1:1/missing\n';
    p.settings.autoSelectMode = 'auto'; p.smartModelReady = false; p.geoipReady = true; p.ruleProviderFileReady = true;
    p.profileYaml = profileBacked ? profileYaml : '';
    p.profileId = profileBacked ? 'offline-fixture' : '';
    if (profileBacked) { profileRegistry.set('/sandbox/profiles/offline-fixture.yaml', profileYaml); }
    p.proxyHosts = { localhost: '127.0.0.1' };
    p.selectedNodeName = 'A'; p.mixedPort = 17890; p.apiPort = 19090; p.dnsPort = 11053; p.apiSecret = 'test';
    for (const mode of [runtime.RuntimeConfigMode.TEST, runtime.RuntimeConfigMode.TUNNEL]) {
      const result = await runtime.RuntimeConfigBuilder.buildRuntimeConfig(p, mode);
      assert.equal(result.options.useSmart, false, 'missing model must not enable smart');
      const file = path.join(h.dir, 'config.yaml'); fs.writeFileSync(file, result.yaml);
      const checked = spawnSync(kernel, ['-t', '-d', h.dir, '-f', file], { encoding: 'utf8', timeout:10000, windowsHide:true });
      assert.equal(checked.status, 0, checked.error?.message ?? checked.stdout + checked.stderr);
      assert.ok(!checked.stdout.includes('start download'), 'offline start must not download assets');
      if (mode === runtime.RuntimeConfigMode.TEST && (flags === 0 || flags === 15)) {
        liveConfigs.push({ dir: h.dir, yaml: result.yaml, name: `profile=${profileBacked} flags=${flags}` });
      }
    }
  });
}
for (const live of liveConfigs) await test('live core controller and proxy table: ' + live.name, async () => {
  const reservation = net.createServer();
  await new Promise(resolve => reservation.listen(0, '127.0.0.1', resolve));
  const port = reservation.address().port; await new Promise(resolve => reservation.close(resolve));
  const file = path.join(live.dir, 'live.yaml');
  if (live.yaml.trimStart().startsWith('{')) {
    const liveDoc = JSON.parse(live.yaml);
    liveDoc['external-controller'] = `127.0.0.1:${port}`;
    fs.writeFileSync(file, JSON.stringify(liveDoc));
  } else {
    fs.writeFileSync(file, live.yaml.replace(/^external-controller:.*$/m, `external-controller: 127.0.0.1:${port}`));
  }
  const child = spawn(kernel, ['-d', live.dir, '-f', file], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  const exited = new Promise(resolve => child.once('exit', resolve));
  let output = ''; const collect = chunk => { output = (output + chunk.toString()).slice(-8192); };
  child.stdout.on('data', collect); child.stderr.on('data', collect);
  try {
    let ready = false;
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline) {
      try {
        const response = await fetch(`http://127.0.0.1:${port}/proxies`, {
          headers: { Authorization: 'Bearer test' }, signal: AbortSignal.timeout(400) });
        if (response.ok && (await response.json()).proxies.A) { ready = true; break; }
      } catch {}
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    assert.ok(ready, output || 'controller did not become ready');
    assert.ok(!output.includes('start download'), output);
  } finally { child.kill(); await exited; }
});
console.log(`RESULT: ${passed} passed, ${failed} failed; 64 real kernel config checks + 4 live core starts`);
if (path.dirname(fs.realpathSync(scratch)) === tempRoot && path.basename(scratch).startsWith('tunbox-startup-assets-')) {
  fs.rmSync(scratch, { recursive: true });
}
process.exitCode = failed ? 1 : 0;
