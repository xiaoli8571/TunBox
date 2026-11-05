#!/usr/bin/env node
/**
 * FlClash 全量照抄验证（2026-11-05 重写）：map 级 profile 构建 → 真实内核接受。
 *
 * 旧版闸的是 `ProfileConfigMerger.merge`（文本级 YAML 手术）；该路径已退场，
 * 现在的生产链路是 `TunBoxProfileBuilder`：
 *   内核 getProfileBase(profile) → map patch（FlClash `_makeRealProfileTask` 链）
 *   → JSON dump → 内核 config.Parse（JSON ⊂ YAML）。
 *
 * 覆盖：
 *   [1] compose 纯函数真跑（内核桥数据手喂，与生产同一实现）：
 *       运行期键来自 overlay；profile general 键原样保留；端口清零默认
 *   [2] tun 合成：profile tun + overrides 按键 + overlay tun + dns-hijack；
 *       auto-detect-interface 恒 true（task.dart:219）
 *   [3] dns 三段合并：baseline（订阅 dns 禁用时）→ overrides 按键 → appendSystemDns；
 *       无 dns.ipv6 强改（redir-host 反例）
 *   [4] provider path 收容（全部非 inline，含 file 型）：有 URL md5(name@url)，
 *       无 URL md5(section/name)；旧 URL-only 记迁移；global-ua（设置/默认）
 *   [5] rules：附加规则全部保留 + target=MATCH 替换（选定 matchTarget / 最后 MATCH）+ 前置
 *   [6] 节点准入：proxies/proxy-groups 原样（无过滤/改名/Smart 注入）
 *   [7] store-selected=false / find-process-mode=off / sniffer ports 字符串化 / iptables 多接口清理
 *   [8] md5（provider 缓存键）对拍 node crypto
 *   [9] dump 是合法 JSON，且能被**真实 mihomo** `-t` 接受（找不到内核则跳过）
 */
import fs from 'node:fs';
import crypto from 'node:crypto';
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

// Always compile the current production source, never a stale generated builder.
const prepare = spawnSync(process.execPath,
  [path.join(root, 'tools/true-chain-harness/prepare.mjs')], { stdio: 'inherit' });
if (prepare.status !== 0) process.exit(1);
const { TunBoxProfileBuilder, TunBoxBaseData, TunBoxProfileInput } = await import(G('TunBoxProfileBuilder.ts'));

let failed = 0;
const ok = (cond, label, detail = '') => {
  if (cond) {
    console.log(`  ok   ${label}`);
  } else {
    failed++;
    console.log(`  FAIL ${label}${detail ? ` — ${detail}` : ''}`);
  }
};

// ── 测试数据：内核 getProfileBase 返回形态（RawConfig JSON，rule→rules 已改名）──
const baseConfig = {
  'port': 1234,
  'socks-port': 1235,
  'mixed-port': 1236,
  'mode': 'global',
  'log-level': 'debug',
  'ipv6': true,
  'allow-lan': true,
  'find-process-mode': 'always',
  'tun': { 'enable': true, 'stack': 'system', 'mtu': 1500, 'dns-hijack': ['1.2.3.4:53'] },
  'dns': {
    'enable': true,
    'enhanced-mode': 'fake-ip',
    'fake-ip-range': '198.18.0.1/16',
    'nameserver': ['119.29.29.29'],
    'proxy-server-nameserver': ['https://private.example/dns-query'],
  },
  'hosts': { 'entry.example.com': '1.2.3.4' },
  'sniffer': { 'sniff': { 'HTTP': { 'ports': [80, '8080-8888'] } } },
  'proxies': [
    { 'name': 'A', 'type': 'ss', 'server': 'a.example.com', 'port': 443, 'cipher': 'aes-128-gcm', 'password': 'p' },
    { 'name': 'B', 'type': 'trojan', 'server': 'b.example.com', 'port': 443, 'password': 'p' },
    { 'name': '剩余流量：100 GB', 'type': 'ss', 'server': 'info.example.com', 'port': 443, 'cipher': 'aes-128-gcm', 'password': 'x' },
  ],
  'proxy-groups': [
    { 'name': '🔰 选择节点', 'type': 'select', 'proxies': ['A', 'B', '剩余流量：100 GB'] },
    { 'name': '♻️ 自动选择', 'type': 'url-test', 'url': 'https://www.gstatic.com/generate_204', 'interval': 300, 'proxies': ['A', 'B'] },
  ],
  'proxy-providers': {
    'airport': { 'type': 'http', 'url': 'https://sub.example.com/clash.yaml', 'interval': 86400, 'health-check': { 'enable': true, 'url': 'https://www.gstatic.com/generate_204', 'interval': 300 } },
    // 本 fork 的 inline provider 形状是 payload 数组（ProviderSchema.Payload []map[string]any）
    'local-list': { 'type': 'inline', 'payload': [{ 'name': 'inl', 'type': 'ss', 'server': 'i.example.com', 'port': 443, 'cipher': 'aes-128-gcm', 'password': 'p' }] },
  },
  'rule-providers': {
    'ad-rules': { 'type': 'file', 'path': './ruleset/adrules.mrs', 'behavior': 'domain' },
    'remote-rules': { 'type': 'http', 'url': 'https://rules.example.com/list.yaml', 'interval': 86400 },
  },
  'rules': [
    'DOMAIN-SUFFIX,google.com,🔰 选择节点',
    'MATCH,🔰 选择节点',
  ],
};
const base = new TunBoxBaseData();
base.config = baseConfig;
base.digest = 'deadbeef';
base.proxies = baseConfig.proxies.length;
base.proxyGroups = baseConfig['proxy-groups'].length;
base.rules = baseConfig.rules.length;
base.matchRules = ['MATCH,🔰 选择节点'];

const overlay = {
  'mixed-port': 7890,
  'external-controller': '127.0.0.1:9090',
  'secret': 's3cret',
  'mode': 'rule',
  'log-level': 'warning',
  'ipv6': true,
  'unified-delay': true,
  'tcp-concurrent': true,
  'dns': {
    'enable': true,
    'listen': '127.0.0.1:1053',
    'enhanced-mode': 'fake-ip',
    'fake-ip-range': '198.18.0.1/16',
    'nameserver': ['223.5.5.5'],
  },
  'tun': { 'enable': true, 'stack': 'mips', 'mtu': 1400, 'congestion-controller': 'bbr3', 'auto-route': false, 'auto-detect-interface': false },
  'hosts': { 'pinned.example.com': '5.6.7.8' },
  'sniffer': { 'force-dns-mapping': true },
  'rules': [
    'DOMAIN-SUFFIX,blocked.example,REJECT',
    'GEOIP,CN,DIRECT',
    'MATCH,🔰 选择节点',
  ],
};

const mkInput = (overrides) => {
  const input = new TunBoxProfileInput();
  input.profileId = 'sub-1';
  input.profilePath = '/data/profiles/sub-1.yaml';
  input.profilesDir = '/data/profiles';
  input.overrideYaml = '';
  input.dnsOverrideEnabled = true;
  input.tunEnabled = true;
  input.ipv6Enabled = true;
  input.mtu = 1400;
  input.useSmart = false;
  input.smartTestUrl = 'https://www.gstatic.com/generate_204';
  input.smartPolicyPriority = '';
  return Object.assign(input, overrides ?? {});
};

console.log('[1] compose：运行期键来自 overlay；profile general 键被 patch 覆盖；FlClash 清零默认');
// compose 与生产一致地**就地** patch base.config（生产每次 getProfileBase 都返回
// 新鲜 JSON）；门禁多次调用同一 base 必须深拷贝，否则前面的断言会污染后面的。
const composeFresh = (baseData, ov, ovrd, input) =>
  TunBoxProfileBuilder.compose(JSON.parse(JSON.stringify(baseData)), ov, ovrd, input);
const r = composeFresh(base, overlay, null, mkInput());
ok(r.ok, 'compose 成功');
let doc = JSON.parse(r.yaml);
ok(doc['mixed-port'] === 7890, 'overlay mixed-port 落地', String(doc['mixed-port']));
ok(doc['mode'] === 'rule', 'overlay mode 落地（覆盖 profile global）');
ok(doc['log-level'] === 'warning', 'overlay log-level 落地');
ok(doc['secret'] === 's3cret', 'overlay secret 落地');
ok(doc['port'] === 0 && doc['socks-port'] === 0 && doc['redir-port'] === 0 && doc['tproxy-port'] === 0,
  'FlClash 端口清零默认');
ok(doc['find-process-mode'] === 'off', 'ohos find-process-mode=off（FlClash）');
ok(doc['allow-lan'] === false, 'allow-lan=false（FlClash 默认）');
ok(doc['keep-alive-interval'] === 30, 'keep-alive-interval=30（FlClash 默认）');
ok(doc['external-ui'] === '' && doc['external-ui-url'] === '' && doc['interface-name'] === '',
  'external-ui/interface-name 清空（FlClash）');
ok(doc['profile']?.['store-selected'] === false, 'profile.store-selected=false（FlClash）');
ok(doc['global-ua'] === 'TunBox/v-test clash-verge Platform/OpenHarmony'
  || (typeof doc['global-ua'] === 'string' && doc['global-ua'].includes('clash-verge')),
  'global-ua = 单一 UA（FlClash packageInfo.ua 口径）', String(doc['global-ua']));
ok(doc['geox-url']?.['mmdb']?.includes('meta-rules-dat'), 'geox-url = FlClash 默认镜像');

console.log('[2] tun 合成：profile tun + overrides 按键 + overlay tun + dns-hijack/enable/auto-detect');
ok(doc['tun']?.['stack'] === 'mips', 'overlay tun stack 落地（覆盖 profile system）', String(doc['tun']?.['stack']));
ok(doc['tun']?.['congestion-controller'] === 'bbr3', 'overlay tun congestion-controller 保留');
ok(doc['tun']?.['mtu'] === 1400, 'tun.mtu = 平台合同值');
ok(Array.isArray(doc['tun']?.['dns-hijack']) && doc['tun']['dns-hijack'][0] === 'any:53',
  'dns-hijack = any:53（FlClash default）');
ok(doc['tun']?.['auto-detect-interface'] === true,
  'auto-detect-interface 恒 true 压轴（FlClash task.dart:219）');

console.log('[3] dns：三段合并（baseline → overrides → appendSystemDns）；无 ipv6 强改');
ok(doc['dns']?.['nameserver']?.[0] === '119.29.29.29', '订阅 dns 启用 → 原样（baseline 不进）',
  JSON.stringify(doc['dns']?.['nameserver']));
ok(doc['dns']?.['proxy-server-nameserver']?.[0] === 'https://private.example/dns-query',
  '订阅私有上游保留（FlClash 行为天然满足）');
ok(doc['dns']?.['ipv6'] !== false,
  '无 ipv6 强改：不凭空写 false（profile 无此键保持缺省）');
ok(doc['dns']?.['fake-ip-range6'] === undefined,
  '无 ipv6 强改：不凭空写 fake-ip-range6');
// ipv6:true 的订阅 dns 原样保留（与上条同查混搭）
const v6Base = JSON.parse(JSON.stringify(base));
v6Base.config.dns = { 'enable': true, 'ipv6': true, 'enhanced-mode': 'fake-ip', 'fake-ip-range': '198.18.0.1/16', 'nameserver': ['119.29.29.29'] };
doc = JSON.parse(composeFresh(v6Base, overlay, null, mkInput()).yaml);
ok(doc['dns']?.['ipv6'] === true,
  '订阅 dns.ipv6:true 原样保留');
// redir-host + ipv6:true 的反例（R4 复现）：FlClash 原样，旧 TunBox 写成 false
const redirBase = JSON.parse(JSON.stringify(base));
redirBase.config.dns = { 'enable': true, 'ipv6': true, 'enhanced-mode': 'redir-host', 'nameserver': ['119.29.29.29'] };
const rRedir = composeFresh(redirBase, overlay, null, mkInput({ ipv6Enabled: true }));
doc = JSON.parse(rRedir.yaml);
ok(doc['dns']?.['ipv6'] === true,
  'redir-host + ipv6:true 必须原样保留（FlClash 无「只 fake-ip 才允许」条件）');
const disabledDnsBase = JSON.parse(JSON.stringify(base));
disabledDnsBase.config.dns = { 'enable': false };
const rDisabled = composeFresh(disabledDnsBase, overlay, null, mkInput());
doc = JSON.parse(rDisabled.yaml);
ok(doc['dns']?.['listen'] === '127.0.0.1:1053', '订阅 dns 禁用 → baseline app dns 按键覆盖');
ok(doc['dns']?.['enhanced-mode'] === 'fake-ip', 'baseline enhanced-mode 落地');
ok(!doc['dns']?.['nameserver']?.includes('system://'),
  'appendSystemDns 默认 false → 不追加 system://（上游默认）');
const rSys = composeFresh(disabledDnsBase, overlay, null, mkInput({ appendSystemDns: true }));
doc = JSON.parse(rSys.yaml);
ok(Array.isArray(doc['dns']?.['nameserver']) && doc['dns']['nameserver'].includes('system://'),
  'appendSystemDns=true → nameserver 尾部追加 system://');
const winningOverrides = { 'dns': { 'nameserver': ['10.10.10.10'], 'enable': false } };
const rOv = composeFresh(base, overlay, winningOverrides, mkInput());
doc = JSON.parse(rOv.yaml);
ok(doc['dns']?.['nameserver']?.[0] === '10.10.10.10' && doc['dns']?.['enable'] === false,
  'overrides dns 按键合并（profile 启用时亦进）', JSON.stringify(doc['dns']));
ok(doc['dns']?.['proxy-server-nameserver']?.[0] === 'https://private.example/dns-query',
  'overrides 按键合并不整段替换（私有上游保留）');

console.log('[4] provider path 收容（全部非 inline，含 file 型）+ hosts');
ok(doc['hosts']?.['pinned.example.com'] === '5.6.7.8', 'overlay hosts per-key 覆盖');
ok(doc['hosts']?.['entry.example.com'] === '1.2.3.4', 'profile hosts 保留（FlClash per-key 合并）');
doc = JSON.parse(r.yaml);
const providerPath = doc['proxy-providers']?.['airport']?.['path'];
ok(typeof providerPath === 'string'
  && providerPath === `/data/profiles/providers/sub-1/proxies/${
    crypto.createHash('md5').update('airport@https://sub.example.com/clash.yaml').digest('hex')}`,
  'http provider path = providers/<id>/proxies/<md5(name@url)>', String(providerPath));
ok(doc['proxy-providers']?.['local-list']?.['path'] === undefined, 'inline provider 不收容');
const ruleProviderPath = doc['rule-providers']?.['remote-rules']?.['path'];
ok(typeof ruleProviderPath === 'string'
  && ruleProviderPath === `/data/profiles/providers/sub-1/rules/${
    crypto.createHash('md5').update('remote-rules@https://rules.example.com/list.yaml').digest('hex')}`,
  'http rule-provider path = providers/<id>/rules/<md5>', String(ruleProviderPath));
const fileProviderPath = doc['rule-providers']?.['ad-rules']?.['path'];
ok(fileProviderPath === `/data/profiles/providers/sub-1/rules/${
    crypto.createHash('md5').update('rule-providers/ad-rules').digest('hex')}`,
  'file provider 收容（无 URL key=section/name，不再原样）', String(fileProviderPath));
ok(r.confinedProviders === 3, '收容计数 = 3（2 http + 1 file；inline 不计）', String(r.confinedProviders));
ok(r.providerMigrations.length === 2
  && r.providerMigrations.some((m) => m.from === `/data/profiles/providers/sub-1/proxies/${
      crypto.createHash('md5').update('https://sub.example.com/clash.yaml').digest('hex')}`
    && m.to === providerPath)
  && r.providerMigrations.some((m) => m.from === `/data/profiles/providers/sub-1/rules/${
      crypto.createHash('md5').update('https://rules.example.com/list.yaml').digest('hex')}`
    && m.to === ruleProviderPath),
  '旧 URL-only 缓存迁移登记（build best-effort 改名）', JSON.stringify(r.providerMigrations));

console.log('[5] rules：附加规则全部保留 + target=MATCH 替换 + 前置');
const rules = doc['rules'];
ok(Array.isArray(rules) && rules[0] === 'DOMAIN-SUFFIX,blocked.example,REJECT',
  '附加规则在前', JSON.stringify(rules));
ok(rules.includes('GEOIP,CN,DIRECT'), '附加 GEOIP 规则原样保留');
ok(rules.includes('MATCH,🔰 选择节点'), '附加 MATCH（target 本身非 MATCH）原样保留');
ok(rules.filter((x) => x === 'MATCH,🔰 选择节点').length === 2,
  '附加 MATCH 不丢弃（上游无白名单/短路逻辑）');
ok(rules.slice(-2).includes('DOMAIN-SUFFIX,google.com,🔰 选择节点')
  && rules[rules.length - 1] === 'MATCH,🔰 选择节点', 'profile 规则在后且原样');
ok(rules.indexOf('DOMAIN-SUFFIX,blocked.example,REJECT') < rules.indexOf('DOMAIN-SUFFIX,google.com,🔰 选择节点'),
  '附加规则整体前置');
const matchBase = JSON.parse(JSON.stringify(base));
matchBase.config.rules = ['DOMAIN-SUFFIX,google.com,🔰 选择节点', 'MATCH,🔰 选择节点'];
const matchOverlay = JSON.parse(JSON.stringify(overlay));
matchOverlay.rules = ['DOMAIN,example.org,MATCH', 'IP-CIDR,1.1.1.0/24,DIRECT,no-resolve'];
const rMatch = composeFresh(matchBase, matchOverlay, null, mkInput());
doc = JSON.parse(rMatch.yaml);
ok(doc['rules'].includes('DOMAIN,example.org,🔰 选择节点'),
  '附加 target=MATCH → 最后 profile MATCH target');
ok(doc['rules'].includes('IP-CIDR,1.1.1.0/24,DIRECT,no-resolve'), 'no-resolve 原样保留');
// matchTarget 由用户从 profile 已有组里选（FlClash setupState），夹具用真实存在的组
const rMatchSel = composeFresh(matchBase, matchOverlay, null, mkInput({ matchTarget: '♻️ 自动选择' }));
doc = JSON.parse(rMatchSel.yaml);
ok(doc['rules'].includes('DOMAIN,example.org,♻️ 自动选择'), '选定 matchTarget 优先');

// Exercise the production producer AND composer. The old gate hand-wrote a
// valid overlay, hiding the unconditional MATCH,PROXY emitted by production.
const { ClashConfigGenerator } = await import(G('ClashConfigGenerator.ts'));
const { AppSettings } = await import(G('AppSettings.ts'));
const { ProxyNode } = await import(G('ProxyNode.ts'));
const { miniYamlParse } = await import('./fixtures/mini-yaml.mjs');
const overlayNode = new ProxyNode();
Object.assign(overlayNode, { id: 'fixture', name: '__tunbox_overlay__', proxyType: 'socks5', server: '127.0.0.1', port: 9 });
const appSettings = new AppSettings();
appSettings.hyperAdRulesEnabled = false;
appSettings.forceProxySites = ['force.example'];
appSettings.rulesEnabled = true;
appSettings.customRules = ['IP-CIDR,1.1.1.0/24,PROXY,no-resolve'];
appSettings.yamlOverride = 'rules:\n  - MATCH,GLOBAL\n';
const generatedOverlay = (tun, defaults = false, settings = appSettings) => miniYamlParse(ClashConfigGenerator.generate(
  overlayNode, [overlayNode], settings, 7890, 9090, 1053, 'fixture', false,
  true, {}, tun, [], false, [], '', [], [], defaults));
const proxyOverlay = generatedOverlay(false);
const rProxy = composeFresh(matchBase, proxyOverlay, null, mkInput());
doc = JSON.parse(rProxy.yaml);
ok(!doc['rules'].some((x) => x.split(',').map((s) => s.trim()).includes('PROXY')),
  '附加规则不再引用不存在的 PROXY 组', JSON.stringify(doc['rules']));
ok(doc['rules'].includes('DOMAIN-SUFFIX,force.example,🔰 选择节点'), 'PROXY → profile 主组（MATCH 占位替换）');
ok(doc['rules'].includes('IP-CIDR,1.1.1.0/24,🔰 选择节点,no-resolve'), 'App 策略替换保留 no-resolve');
ok(doc['rules'].filter((x) => x.toUpperCase().startsWith('MATCH,')).length === 1
  && doc['rules'][doc['rules'].length - 1] === 'MATCH,🔰 选择节点',
  'profile 模式不生成 App 兜底，不短路订阅规则');
ok(!proxyOverlay.rules.includes('MATCH,GLOBAL'), '全局 override 不在生成器重复应用');
for (const tun of [false, true]) {
  const produced = composeFresh(matchBase, generatedOverlay(tun), null, mkInput());
  ok(JSON.stringify(JSON.parse(produced.yaml).rules) === JSON.stringify(doc.rules), `主连接/测速共用相同规则 tun=${tun}`);
}
const invalidOverlay = { ...proxyOverlay, rules: ['DOMAIN,x.example,missing-policy', 'RULE-SET,missing-provider,DIRECT'] };
const invalid = JSON.parse(composeFresh(matchBase, invalidOverlay, null, mkInput()).yaml);
ok(invalid.rules.includes('DOMAIN,x.example,missing-policy') && invalid.rules.includes('RULE-SET,missing-provider,DIRECT'),
  '显式用户规则原样交内核校验，不静默丢弃');
const noMatchBase = JSON.parse(JSON.stringify(base));
noMatchBase.config.rules = ['DOMAIN-SUFFIX,google.com,🔰 选择节点'];
const plainSettings = new AppSettings();
plainSettings.hyperAdRulesEnabled = false;
const rNoMatch = composeFresh(noMatchBase, generatedOverlay(false, false, plainSettings), null, mkInput());
doc = JSON.parse(rNoMatch.yaml);
ok(JSON.stringify(doc.rules) === JSON.stringify(noMatchBase.config.rules), '无 MATCH 的 profile 不凭空新增兜底');
const proxyGroupBase = JSON.parse(JSON.stringify(matchBase));
proxyGroupBase.config['proxy-groups'].push({ 'name': 'PROXY', 'type': 'select', 'proxies': ['A'] });
const rOwnProxy = composeFresh(proxyGroupBase, { ...proxyOverlay, rules: ['DOMAIN,explicit.example,PROXY'] }, null, mkInput());
doc = JSON.parse(rOwnProxy.yaml);
ok(doc['rules'][0] === 'DOMAIN,explicit.example,PROXY', '显式引用 profile 自带 PROXY 组原样保留');
ok(generatedOverlay(false, true, plainSettings).rules.includes('MATCH,PROXY'), '无 profile 的旧生成路径保留兜底');
doc = JSON.parse(rMatchSel.yaml);

console.log('[6] 节点准入：原样（无过滤/改名/注入）');
ok(doc['proxies'].length === 3, 'proxies 数 = 3（信息条目不过滤）', String(doc['proxies'].length));
ok(doc['proxies'].some((p) => p.name === '剩余流量：100 GB'), '信息条目原样进内核（FlClash 行为）');
ok(doc['proxy-groups'].length === 2 && doc['proxy-groups'][0]['proxies'].length === 3,
  'proxy-groups 原样（无注入/无改名）');
ok(!JSON.stringify(doc['proxies']).includes('手动选择'), '无合成组注入（任务3）');

console.log('[7] sniffer ports 字符串化 + sniff 合并');
ok(doc['sniffer']?.['force-dns-mapping'] === true, 'overlay sniffer 键级合并');
ok(JSON.stringify(doc['sniffer']?.['sniff']?.['HTTP']?.['ports']) === '["80","8080-8888"]',
  'sniff ports 数字 → 字符串（mihomo []string 口径）',
  JSON.stringify(doc['sniffer']?.['sniff']?.['HTTP']?.['ports']));

console.log('[8] md5 对拍 node crypto');
const { md5Hex } = await import(G('TunBoxProfileBuilder.ts'));
for (const sample of ['airport@https://sub.example.com/clash.yaml', '', '中文@https://例子.com/x',
  'a'.repeat(1000), 'name with spaces@http://h/x?y=1#z']) {
  ok(md5Hex(sample) === crypto.createHash('md5').update(Buffer.from(sample, 'utf8')).digest('hex'),
    `md5 一致: ${sample.slice(0, 24)}${sample.length > 24 ? '…' : ''}`);
}

console.log('[9] dump 被**真实 mihomo** `-t` 接受');
const kernelCandidates = [
  path.join(root, '..', 'mihomo-build', 'mihomo-smart-462455136157a760937c666bba71afe33b1a809e', 'mihomo.exe'),
];
const kernel = kernelCandidates.find((p) => fs.existsSync(p));
if (!kernel) {
  console.log('  SKIP 真实内核不存在（仅静态断言已完成）');
} else {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'tunbox-flclash-profile-'));
  const cfg = path.join(tmpDir, 'config.json');
  // 用 compose 的真实输出 + 内联节点改成可离线加载的形态
  const offline = JSON.parse(r.yaml);
  offline['rules'] = ['MATCH,🔰 选择节点'];
  delete offline['rule-providers'];
  offline['external-controller'] = '';
  fs.writeFileSync(cfg, JSON.stringify(offline));
  const res = spawnSync(kernel, ['-t', '-f', cfg, '-d', tmpDir], { encoding: 'utf8', timeout: 60000 });
  const out = `${res.stdout ?? ''}${res.stderr ?? ''}`;
  ok(res.status === 0 && out.includes('test is successful'),
    'compose 产物通过真实内核 `-t`（JSON ⊂ YAML）', out.split('\n').slice(-3).join(' | '));
  // 回归：App 附加规则（含 PROXY / 兜底 MATCH,PROXY）**不改写 rules** 直接交给真实内核
  const withAppRules = JSON.parse(rProxy.yaml);
  delete withAppRules['rule-providers'];
  withAppRules['external-controller'] = '';
  fs.writeFileSync(cfg, JSON.stringify(withAppRules));
  const res2 = spawnSync(kernel, ['-t', '-f', cfg, '-d', tmpDir], { encoding: 'utf8', timeout: 60000 });
  const out2 = `${res2.stdout ?? ''}${res2.stderr ?? ''}`;
  ok(res2.status === 0 && out2.includes('test is successful'),
    '带 App 附加规则（原 MATCH,PROXY）的产物通过真实内核 `-t`', out2.split('\n').slice(-3).join(' | '));
  // Real Smart policies survive composition, including the former synthetic
  // shortcut's name. A model file alone must never inject or enable a policy.
  const smartPolicy = {name:'♻️ 自动选择',type:'smart',proxies:['DIRECT'],uselightgbm:true,collectdata:false,'prefer-asn':false};
  const smartBase = JSON.parse(JSON.stringify(matchBase));
  smartBase.config['proxy-groups'] = smartBase.config['proxy-groups'].map(g => g.name === smartPolicy.name ? smartPolicy : g);
  smartBase.config.rules = ['MATCH,♻️ 自动选择'];
  const composedSmart = JSON.parse(composeFresh(smartBase, {}, null, mkInput()).yaml);
  ok(JSON.stringify(composedSmart['proxy-groups'].find(g => g.name === smartPolicy.name)) === JSON.stringify(smartPolicy),
    '真实 Smart 分组的类型、名称和 LightGBM 选项原样保留');
  delete composedSmart['rule-providers']; composedSmart['external-controller'] = '';
  const { smartModelFixture } = await import('./fixtures/smart-model.mjs');
  fs.copyFileSync(smartModelFixture(),path.join(tmpDir,'Model.bin'));
  fs.writeFileSync(cfg,JSON.stringify(composedSmart));
  const smartCheck = spawnSync(kernel,['-t','-f',cfg,'-d',tmpDir],{encoding:'utf8',timeout:15000,windowsHide:true});
  const smartOutput = `${smartCheck.stdout ?? ''}${smartCheck.stderr ?? ''}`;
  ok(smartCheck.status === 0 && smartOutput.includes('Model file loaded successfully') && !smartOutput.includes('start download'),
    '真实内核接受 Smart 并从本地加载 LightGBM，未联网下载',smartOutput.split('\n').slice(-4).join(' | '));
  try { fs.rmSync(tmpDir, { recursive: true, force: true }); } catch { /* ignore */ }
}

console.log(failed === 0 ? '\nverify-tunbox-profile: ALL PASSED' : `\nverify-tunbox-profile: ${failed} FAILED`);
process.exit(failed === 0 ? 0 : 1);
