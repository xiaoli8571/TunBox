#!/usr/bin/env node
/**
 * FlClash 同构验证：订阅原文 + overlay 合并 → 真实内核接受。
 *
 * 覆盖：
 *   [1] ProfileConfigMerger：overlay 的运行期键保留、原文 proxies/proxy-groups/rules 接管
 *   [2] 原文显式 dns（enable: true）整段覆盖 overlay dns（FlClash isEnableDns 语义）
 *   [3] 原文未启 dns 时保留 overlay dns
 *   [4] rules 顺序：overlay 在前、原文在后（FlClash appendRules）
 *   [5] 原文的 tun / mixed-port / external-controller 不得外泄（被 overlay 覆盖）
 *   [6] 合并结果交给**真实 mihomo** `-t` 判定（找不到内核则跳过并说明）
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

if (!process.execArgv.includes('--experimental-transform-types')
  && process.env.TUNBOX_FLC_PROFILE_CHILD !== '1') {
  const res = spawnSync(
    process.execPath,
    ['--experimental-transform-types', '--no-warnings', fileURLToPath(import.meta.url), ...process.argv.slice(2)],
    { stdio: 'inherit', env: { ...process.env, TUNBOX_FLC_PROFILE_CHILD: '1' } },
  );
  process.exit(res.status === null ? 1 : res.status);
}

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const genDir = path.join(root, 'tools/true-chain-harness/generated');
const G = (name) => pathToFileURL(path.join(genDir, name)).href;

// Always compile the current production source, never a stale generated merger.
const prepare = spawnSync(process.execPath,
  [path.join(root, 'tools/true-chain-harness/prepare.mjs')], { stdio: 'inherit' });
if (prepare.status !== 0) process.exit(1);
const { ProfileConfigMerger } = await import(G('ProfileConfigMerger.ts'));
const { YamlMerger } = await import(G('YamlMerger.ts'));

let failed = 0;
const ok = (cond, label, detail = '') => {
  if (cond) {
    console.log(`  ok   ${label}`);
  } else {
    failed++;
    console.log(`  FAIL ${label}${detail ? ` — ${detail}` : ''}`);
  }
};

console.log('[1] merge：overlay 运行期键 + 原文代理段');
const overlay = `mixed-port: 7890
external-controller: 127.0.0.1:9090
secret: "s3cret"
mode: rule
log-level: warning
ipv6: true
unified-delay: true
tcp-concurrent: true
dns:
  enable: true
  enhanced-mode: redir-host
  nameserver:
    - 223.5.5.5
tun:
  enable: true
  stack: gvisor
rules:
  - DOMAIN-SUFFIX,local,DIRECT
  - MATCH,PROXY
`;
const profile = `mixed-port: 1234
external-controller: 0.0.0.0:9999
tun:
  enable: true
  stack: system
proxies:
  - name: A
    type: ss
    server: a.example.com
    port: 443
    cipher: aes-128-gcm
    password: p
  - name: B
    type: trojan
    server: b.example.com
    port: 443
    password: p
    sni: b.example.com
proxy-groups:
  - name: 🔰 选择节点
    type: select
    proxies: [A, B]
  - name: ♻️ 自动选择
    type: url-test
    url: https://www.gstatic.com/generate_204
    interval: 300
    proxies: [A, B]
rules:
  - DOMAIN-SUFFIX,google.com,🔰 选择节点
  - MATCH,🔰 选择节点
`;
const r = ProfileConfigMerger.merge(overlay, profile);
ok(r.ok, 'merge 成功');
ok(r.profileProxyItems === 2, '原文节点条目数 = 2', String(r.profileProxyItems));
ok(/^mixed-port: 7890$/m.test(r.yaml), 'overlay mixed-port 保留');
ok(!/1234/.test(r.yaml), '原文 mixed-port 未外泄');
ok(!/0\.0\.0\.0:9999/.test(r.yaml), '原文 external-controller 未外泄');
ok(/stack: gvisor/.test(r.yaml) && !/stack: system/.test(r.yaml), 'overlay tun.stack 优先');
ok(/name: 🔰 选择节点/.test(r.yaml), '原文组进入配置');
ok(/type: url-test/.test(r.yaml), '原文 url-test 组进入配置');

const rulesIdx = r.yaml.indexOf('rules:');
const rulesBlock = r.yaml.slice(rulesIdx);
const localIdx = rulesBlock.indexOf('DOMAIN-SUFFIX,local,DIRECT');
const googleIdx = rulesBlock.indexOf('DOMAIN-SUFFIX,google.com');
ok(localIdx >= 0 && googleIdx >= 0, '两段 rules 都在');
ok(localIdx < googleIdx, 'rules 顺序：overlay 在前、原文在后', `local=${localIdx} google=${googleIdx}`);

console.log('[2] 原文 dns.enable=true → 整段 dns 用原文');
const profileWithDns = `${profile}dns:
  enable: true
  nameserver:
    - https://doh.example/dns-query
`;
const r2 = ProfileConfigMerger.merge(overlay, profileWithDns);
ok(r2.ok, 'merge 成功(dns)');
ok(/doh\.example\/dns-query/.test(r2.yaml), '原文 dns 生效');
ok(!/223\.5\.5\.5/.test(r2.yaml), 'overlay dns 被原文替换');
ok((r2.yaml.match(/^dns:/gm) || []).length === 1, 'dns 键只出现一次');

console.log('[3] 原文未启 dns → 保留 overlay dns');
const profileNoDns = profile;
const r3 = ProfileConfigMerger.merge(overlay, profileNoDns);
ok(/223\.5\.5\.5/.test(r3.yaml), 'overlay dns 保留');
ok(!/doh\.example/.test(r3.yaml), '没有凭空出现的原文 dns');

console.log('[4] 原文 proxy-providers 段搬入');
const profileProvider = `proxies: []
proxy-groups:
  - name: PROXY
    type: select
    use: [airport]
proxy-providers:
  airport:
    type: http
    url: https://example.com/sub.yaml
    path: ./providers/airport.yaml
    interval: 3600
`;
const r4 = ProfileConfigMerger.merge(overlay, profileProvider);
ok(r4.ok, 'merge 成功(provider)');
ok(/proxy-providers:/.test(r4.yaml), 'proxy-providers 段进入配置');
ok(/use: \[airport\]/.test(r4.yaml), '组的 use 引用保留');

console.log('[5] 原文不是 Clash 配置 → 明确拒绝（不覆盖 overlay）');
const r5 = ProfileConfigMerger.merge(overlay, 'hello world\nrandom text');
ok(!r5.ok, '非法原文被拒');
ok(r5.yaml === '', '拒绝时不产出 yaml');

console.log('[provider regression] overlay rule references retain their declarations');
const adOverlay = overlay.replace('rules:\n', `rule-providers:
  hyper-adrules:
    type: http
    behavior: domain
    format: mrs
    path: ./ruleset/hyper_adrules_ads.mrs
    url: https://example.invalid/ads.mrs
  rs-custom:
    type: inline
    behavior: domain
    payload:
      - '+.custom.invalid'
rules:
  - RULE-SET,hyper-adrules,REJECT
  - RULE-SET,rs-custom,DIRECT
`);
const adResult = ProfileConfigMerger.merge(adOverlay, profile);
ok(adResult.ok, '广告规则 overlay + 无 provider 的订阅合并成功');
ok(/^  hyper-adrules:$/m.test(adResult.yaml), 'HyperAD provider 未被订阅覆盖掉');
ok(/^  rs-custom:$/m.test(adResult.yaml), '自定义规则集 provider 保留');
ok(/RULE-SET,hyper-adrules,REJECT/.test(adResult.yaml), '广告规则仍生效');
ok(/    payload:\n      - '\+\.custom.invalid'/.test(adResult.yaml), '嵌套 payload 缩进不变');
const withProviders = `${profile}rule-providers:
  'hyper-adrules':
    type: inline
    behavior: domain
    payload: ['+.wrong.invalid']
  'vendor.rules:中文':
    type: inline
    behavior: domain
    payload:
      - '+.vendor.invalid'
  compact: {type: inline, behavior: domain, payload: ['+.compact.invalid']}
`;
const bothResult = ProfileConfigMerger.merge(adOverlay, withProviders);
ok((bothResult.yaml.match(/^rule-providers:/gm) || []).length === 1, '只有一个 rule-providers 顶层键');
ok((bothResult.yaml.match(/^  ['"]?hyper-adrules['"]?:/gm) || []).length === 1, '同名 provider 整块去重');
ok(!bothResult.yaml.includes('wrong.invalid'), '应用 provider 优先，重复块的字段一并移除');
ok(bothResult.yaml.includes("  'vendor.rules:中文':"), '保留带冒号、点号和中文的订阅 provider');
ok(bothResult.yaml.includes("    payload:\n      - '+.vendor.invalid'"), '订阅 provider 嵌套列表缩进不变');
ok(bothResult.yaml.includes('  compact: {type: inline'), 'provider 的 flow mapping 值保留');
const profileOnly = ProfileConfigMerger.merge(overlay, withProviders);
ok(profileOnly.yaml.includes("    payload:\n      - '+.vendor.invalid'"), '仅订阅提供规则集时也保留结构');
const emptyProviders = ProfileConfigMerger.merge(adOverlay, `${profile}rule-providers: {}\n`);
ok(emptyProviders.yaml.includes('  hyper-adrules:'), '订阅空 provider map 不删除应用规则集');
const providerOnly = ProfileConfigMerger.merge(adOverlay, profileProvider);
ok(providerOnly.yaml.includes('  hyper-adrules:') && providerOnly.yaml.includes('proxy-providers:'),
  '仅使用 proxy-providers 的订阅也保留广告规则集');
const noAds = ProfileConfigMerger.merge(overlay, profile);
ok(!noAds.yaml.includes('hyper-adrules'), '未生成广告规则时不凭空加入引用或 provider');

const realCoreCases = [
  { name: 'base profile merge', yaml: r.yaml },
  { name: 'ads and custom providers with provider-free profile', yaml: adResult.yaml },
  { name: 'provider collisions and nested payloads', yaml: bothResult.yaml },
  { name: 'profile-only providers', yaml: profileOnly.yaml },
  { name: 'empty profile provider map', yaml: emptyProviders.yaml },
  { name: 'proxy-provider-only subscription', yaml: providerOnly.yaml },
  { name: 'ads absent', yaml: noAds.yaml },
];

console.log('[runtime regression] actual builder → generator → profile merger');
// Only the platform DNS boundary is replaced. Both production modes execute the
// current builder and generator; no mock of the ad-provider decision or merger.
const builderPath = path.join(genDir, '__profile-runtime-builder.ts');
const dohPath = path.join(genDir, '__profile-runtime-doh.ts');
try {
  const builder = fs.readFileSync(path.join(root,
    'entry/src/main/ets/commons/config/RuntimeConfigBuilder.ets'), 'utf8')
    .replace(/from '\.\.\/[^']+\/([^/']+)'/g, (_all, name) =>
      `from './${name === 'AppLogger' ? 'stubs'
        : name === 'DoHResolver' ? '__profile-runtime-doh' : name}.ts'`);
  fs.writeFileSync(builderPath, builder);
  fs.writeFileSync(dohPath, `export class DoHResolver {
    static async refreshStale() {}
    static async resolveMany() { return {}; }
  }`);
  const { RuntimeConfigBuilder, RuntimeConfigProfile, RuntimeConfigMode } = await import(G('__profile-runtime-builder.ts'));
  const { AppSettings, CustomRuleSet } = await import(G('AppSettings.ts'));
  const { ProxyNode } = await import(G('ProxyNode.ts'));
  const input = new RuntimeConfigProfile();
  const node = new ProxyNode();
  Object.assign(node, { name: 'A', originalName: 'A', id: 'fixture-A', server: '192.0.2.1',
    port: 443, proxyType: 'vless', uuid: '11111111-2222-3333-4444-555555555555', tls: true });
  Object.assign(input, { nodes: [node], selectedNodeName: 'A', settings: new AppSettings(),
    mixedPort: 17890, apiPort: 19090, dnsPort: 11053, apiSecret: 'fixture-only' });
  const custom = new CustomRuleSet();
  Object.assign(custom, { name: 'custom', policy: 'DIRECT', url: 'https://example.invalid/custom.yaml' });
  input.settings.customRuleSets = [custom];
  for (const mode of [RuntimeConfigMode.TUNNEL, RuntimeConfigMode.TEST]) {
    for (const rawProfile of ['', profile]) {
      input.profileYaml = rawProfile;
      for (const ready of [true, false]) {
        input.ruleProviderFileReady = ready;
        for (const enabled of [true, false]) {
          input.settings.hyperAdRulesEnabled = enabled;
          const result = await RuntimeConfigBuilder.buildRuntimeConfig(input, mode);
          const label = `${mode} profile=${!!rawProfile} file=${ready} ads=${enabled}`;
          realCoreCases.push({ name: label, yaml: result.yaml });
          ok(/^  hyper-adrules:$/m.test(result.yaml) === (ready && enabled)
            && result.yaml.includes('RULE-SET,hyper-adrules,REJECT') === (ready && enabled),
          `${label}: 广告引用与声明同步`);
          ok(/^  rs-custom:$/m.test(result.yaml) && result.yaml.includes('RULE-SET,rs-custom,DIRECT'),
            `${label}: 自定义规则集保留`);
        }
      }
    }
  }
} finally {
  for (const file of [builderPath, dohPath]) {
    if (fs.existsSync(file)) fs.unlinkSync(file);
  }
}

// ── [6] 真实内核判定 ────────────────────────────────────────────────
console.log('[6] 真实 mihomo -t 判定');
const required = process.argv.includes('--require-mihomo');
const candidates = process.env.MIHOMO_BIN ? [process.env.MIHOMO_BIN] : [
  'C:/Users/Administrator/AppData/Local/hermes/cache/scratch/mh/mihomo-windows-amd64.exe',
  path.join(root, 'scratch/mh/mihomo-windows-amd64.exe'),
];
const bin = candidates.find((p) => {
  try { return fs.statSync(p).isFile(); } catch { return false; }
});
if (!bin) {
  if (required || process.env.MIHOMO_BIN) {
    ok(false, '缺少可用 MIHOMO_BIN：真实内核门禁失败，不得跳过');
  } else {
    console.log('  skip 未找到 mihomo 内核（设 MIHOMO_BIN；发布验证必须加 --require-mihomo）');
  }
} else {
  console.log('  ' + execFileSync(bin, ['-v'], { encoding: 'utf8', timeout: 10000 }).trim());
  // -t only parses; providers are not initialized and no listener or VPN is started.
  // Fresh isolated homes also avoid sharing a running client's cache or settings.
  const cases = realCoreCases.concat([{ name: 'negative: missing hyper-adrules',
    yaml: YamlMerger.removeSection(adResult.yaml, 'rule-providers'),
    expectedError: /rule set \[hyper-adrules\] not found/i }]);
  for (const item of cases) {
    const tempParent = fs.realpathSync(os.tmpdir());
    const dir = fs.mkdtempSync(path.join(tempParent, 'tunbox-mihomo-'));
    const before = failed;
    try {
      const configPath = path.join(dir, 'config.yaml');
      fs.writeFileSync(configPath, item.yaml, 'utf8');
      const result = spawnSync(bin, ['-t', '-d', dir, '-f', configPath],
        { encoding: 'utf8', timeout: 10000, maxBuffer: 2 * 1024 * 1024 });
      const report = (result.stdout || '') + (result.stderr || '');
      const pass = item.expectedError
        ? result.status !== null && result.status !== 0 && item.expectedError.test(report)
        : result.status === 0 && /test is successful/i.test(report);
      ok(pass, `真实内核 ${item.name}`, report.trim().slice(-1000) || String(result.error || result.status));
    } finally {
      // Only remove this test's verified direct child; retain unexpected failures.
      const resolved = fs.realpathSync(dir);
      if (path.dirname(resolved) !== tempParent || !path.basename(resolved).startsWith('tunbox-mihomo-')) {
        throw new Error('Unexpected core-test cleanup boundary');
      }
      if (failed === before) fs.rmSync(resolved, { recursive: true });
      else console.log('  failure evidence: ' + resolved);
    }
  }
}

console.log(failed === 0 ? '\nALL PASS' : `\n${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
