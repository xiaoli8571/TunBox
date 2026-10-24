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

if (!process.execArgv.includes('--experimental-transform-types')) {
  const child = spawnSync(process.execPath, ['--experimental-transform-types', '--no-warnings',
    fileURLToPath(import.meta.url), ...process.argv.slice(2)], { stdio: 'inherit' });
  process.exit(child.status ?? 1);
}
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const ets = path.join(root, 'entry/src/main/ets');
const rawDir = path.join(root, 'entry/src/main/resources/rawfile');
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
const sameFile = (actual, expected) => assert.equal(digest(fs.readFileSync(actual)), digest(fs.readFileSync(expected)));
function load(source, names, context) {
  const text = source.replace(/^import\b[\s\S]*?;\r?\n/gm, '').replace(/^export /gm, '');
  return vm.runInContext(stripTypeScriptTypes(`(()=>{${text}\nreturn {${names}};})()`,
    { mode: 'transform' }), context);
}
let serial = 0, passed = 0, failed = 0;
function harness() {
  const dir = path.join(scratch, 'installer-' + serial++); fs.mkdirSync(dir);
  const state = { reads: 0, writes: 0, resourceFailure: false, writeFailure: false, shortWrite: false, views: false };
  const handles = new Map();
  const io = {
    OpenMode: { READ_WRITE: fs.constants.O_RDWR, READ_ONLY: fs.constants.O_RDONLY,
      CREATE: fs.constants.O_CREAT, TRUNC: fs.constants.O_TRUNC },
    statSync(file) { const s = fs.statSync(file); return { size: s.size, mtime: s.mtimeMs, ino: s.ino }; },
    openSync(file, flags) { const fd = fs.openSync(file, flags); handles.set(fd, file); return { fd }; },
    closeSync(file) { handles.delete(file.fd); fs.closeSync(file.fd); },
    readSync(fd, buffer, options) { return fs.readSync(fd, Buffer.from(buffer), 0, options.length, options.offset); },
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
  const context = { cacheDir: dir, resourceManager: { getRawFileContentSync(name) {
    state.reads++;
    if (state.resourceFailure) throw Error('injected missing resource');
    const raw = fs.readFileSync(path.join(rawDir, name));
    if (!state.views) return new Uint8Array(raw);
    const buffer = new Uint8Array(raw.length + 10); buffer.set(raw, 4);
    return buffer.subarray(4, raw.length + 4);
  } } };
  const sandbox = vm.createContext({ fs: io, util: { generateRandomUUID: () => crypto.randomUUID() },
    AppLogger: logger, Uint8Array, ArrayBuffer, Map, Math });
  const { GeoDataInstaller } = load(installerSource, 'GeoDataInstaller', sandbox);
  return { ...state, state, dir, context, installer: GeoDataInstaller };
}
async function test(name, run) {
  try { await run(); passed++; console.log('PASS ' + name); }
  catch (e) { failed++; console.log('FAIL ' + name + ': ' + e.message); }
}
await test('copy failure can retry in the same process', () => {
  const h = harness(); h.state.writeFailure = true; h.installer.ensure(h.context);
  h.installer.ensure(h.context);
  sameFile(path.join(h.dir, 'geoip.metadb'), path.join(rawDir, 'geoip.metadb'));
});
await test('missing resources can recover without restarting the app', () => {
  const h = harness(); h.state.resourceFailure = true; h.installer.ensure(h.context);
  h.state.resourceFailure = false; h.installer.ensure(h.context);
  assert.ok(fs.existsSync(path.join(h.dir, 'geoip.metadb')));
});
await test('deleted cache files are restored in the same process', () => {
  const h = harness(); h.installer.ensure(h.context); fs.unlinkSync(path.join(h.dir, 'geosite.dat'));
  h.installer.ensure(h.context); assert.ok(fs.existsSync(path.join(h.dir, 'geosite.dat')));
});
await test('same-sized and larger corrupt files are repaired', () => {
  const h = harness();
  for (const name of ['geoip.metadb', 'geosite.dat']) {
    fs.writeFileSync(path.join(h.dir, name), Buffer.alloc(fs.statSync(path.join(rawDir, name)).size + 8, 0x58));
  }
  h.installer.ensure(h.context);
  for (const name of ['geoip.metadb', 'geosite.dat']) {
    sameFile(path.join(h.dir, name), path.join(rawDir, name));
  }
});
await test('shared resource-buffer views never write unrelated bytes', () => {
  const h = harness(); h.state.views = true; h.installer.ensure(h.context);
  sameFile(path.join(h.dir, 'geoip.metadb'), path.join(rawDir, 'geoip.metadb'));
});
await test('short writes preserve the original file and leave no temporary files', () => {
  const h = harness(); const old = Buffer.from('previous-invalid-database');
  fs.writeFileSync(path.join(h.dir, 'geoip.metadb'), old); h.state.shortWrite = true;
  h.installer.ensure(h.context); assert.equal(digest(fs.readFileSync(path.join(h.dir, 'geoip.metadb'))), digest(old));
  assert.ok(!fs.readdirSync(h.dir).some(n => n.endsWith('.tmp')));
  h.state.shortWrite = false; h.installer.ensure(h.context);
  assert.equal(fs.statSync(path.join(h.dir, 'geoip.metadb')).size, fs.statSync(path.join(rawDir, 'geoip.metadb')).size);
});
await test('healthy cache is neither replaced nor reread from rawfile', () => {
  const h = harness(); h.installer.ensure(h.context); const writes = h.state.writes, reads = h.state.reads;
  h.installer.ensure(h.context); assert.equal(h.state.writes, writes); assert.equal(h.state.reads, reads);
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
const sandbox = vm.createContext({ AppSettings: settingsModule.AppSettings, AutoSelectModes: settingsModule.AutoSelectModes,
  ProxyNode, ClashConfigGenerator, ProfileConfigMerger, AppLogger: logger,
  DoHResolver: { async refreshStale() {}, async resolveMany() { return {}; } }, Math, Map, Set });
const runtime = load(fs.readFileSync(path.join(ets, 'commons/config/RuntimeConfigBuilder.ets'), 'utf8'),
  'RuntimeConfigProfile,RuntimeConfigBuilder,RuntimeConfigMode', sandbox);
const kernel = path.join(root, '../mihomo-build/mihomo-smart-462455136157a760937c666bba71afe33b1a809e/mihomo.exe');
assert.ok(fs.existsSync(kernel), 'same-source kernel is required');
const node = new ProxyNode(); Object.assign(node, { id: 'a', name: 'A', originalName: 'A',
  proxyType: 'socks5', server: '127.0.0.1', port: 9 });
const profileYaml = 'proxies:\n  - {name: A, type: socks5, server: 127.0.0.1, port: 9}\nproxy-groups:\n  - {name: Main, type: select, proxies: [A]}\nrules:\n  - GEOIP,CN,DIRECT\n  - GEOSITE,cn,DIRECT\n  - MATCH,Main\n';
const liveConfigs = [];
for (const profileBacked of [false, true]) for (let flags = 0; flags < 16; flags++) {
  await test(`offline kernel: profile=${profileBacked} rule/ad/IPv6/sniff=${flags.toString(2).padStart(4, '0')}`, async () => {
    const h = harness(); h.installer.ensure(h.context);
    fs.mkdirSync(path.join(h.dir, 'ruleset'));
    fs.copyFileSync(path.join(rawDir, 'hyper_adrules_ads.mrs'), path.join(h.dir, 'ruleset/hyper_adrules_ads.mrs'));
    const p = new runtime.RuntimeConfigProfile(); p.nodes = [node];
    p.settings.rulesEnabled = !!(flags & 1); p.settings.hyperAdRulesEnabled = !!(flags & 2);
    p.settings.ipv6Enabled = !!(flags & 4); p.settings.sniffingEnabled = !!(flags & 8);
    p.settings.customRules = ['GEOIP,US,DIRECT', 'DOMAIN-SUFFIX,example.com,REJECT'];
    p.settings.yamlOverride = 'geox-url:\n  mmdb: http://127.0.0.1:1/missing\n  geosite: http://127.0.0.1:1/missing\n';
    p.settings.autoSelectMode = 'auto'; p.smartModelReady = false; p.geoipReady = true; p.ruleProviderFileReady = true;
    p.profileYaml = profileBacked ? profileYaml : ''; p.proxyHosts = { localhost: '127.0.0.1' };
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
  fs.writeFileSync(file, live.yaml.replace(/^external-controller:.*$/m, `external-controller: 127.0.0.1:${port}`));
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
