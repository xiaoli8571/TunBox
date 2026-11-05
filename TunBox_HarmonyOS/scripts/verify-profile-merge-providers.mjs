#!/usr/bin/env node
/**
 * 订阅合并 · provider 段闸门（Profile Provider Merge Gate）—— 2026-11-05 按上游重写
 *
 * ## 历史背景
 *
 * 2026-10-23 用户真机报障：0.5.4 手动更新去广告规则后 VPN 启动失败，内核原话
 *   rules[0] [RULE-SET,hyper-adrules,REJECT] error: rule set [hyper-adrules] not found
 * 根因：旧文本合并把 overlay 的 rule-providers 声明删了，rules 引用在、声明丢。
 *
 * ## 现在的生产链路（FlClash 上游 be847366 task.dart:135-160 / 261-279）
 *
 * `TunBoxProfileBuilder.compose`（map 级）：内核解析 profile → overlay（生成器产物）
 * 经内核 decodeYaml 解码 → patch 链。provider 相关语义：
 *   · 全部非 inline provider 都收容 path（有 URL key=name@url，无 URL key=section/name，
 *     section ∈ {proxy-providers, rule-providers}；含 file 型；旧 URL-only MD5 记迁移）；
 *   · overlay 注入（injected）先铺、profile 后铺，同名 profile 赢；注入声明路径原样
 *     （与上游注入的 App 落盘路径一致，不二次收容）；
 *   · mihomo 自己拉取（App 不再预取）。
 *
 * 闸门断言（compose 纯函数真跑，内核桥数据手喂）：
 *   A. 注入 provider 声明保留 + 路径原样，RULE-SET 引用可满足（自洽）
 *   B. 原文自带 provider → 并集（两边块都在）；profile http 型收容
 *   C. 同名 → profile 赢（注入先铺语义；profile 行被收容）
 *   D. proxy-providers 同理（含 inline 不收容）
 *   E. 无 provider 段 → 不凭空造空 `rule-providers: {}` 头（空 mapping 内核拒载）
 *   F. file 型收容：无 URL key=section/name；有声明的 file path 被重写为收容路径
 *   G. 规则 MATCH 替换：附加规则 target=MATCH → 选定 matchTarget（默认最后 profile MATCH），
 *      no-resolve 原样保留，前置顺序
 *
 * 跑法：
 *   node scripts/verify-profile-merge-providers.mjs
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

if (!process.execArgv.includes('--experimental-transform-types')
  && process.env.TUNBOX_PPM_CHILD !== '1') {
  const res = spawnSync(
    process.execPath,
    ['--experimental-transform-types', '--no-warnings', fileURLToPath(import.meta.url), ...process.argv.slice(2)],
    { stdio: 'inherit', env: { ...process.env, TUNBOX_PPM_CHILD: '1' } },
  );
  process.exit(res.status === null ? 1 : res.status);
}

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const genDir = path.join(root, 'tools/true-chain-harness/generated');
const G = (name) => pathToFileURL(path.join(genDir, name)).href;

const prepare = spawnSync(process.execPath,
  [path.join(root, 'tools/true-chain-harness/prepare.mjs')], { stdio: 'inherit' });
if (prepare.status !== 0) process.exit(1);
const { TunBoxProfileBuilder, TunBoxBaseData, TunBoxProfileInput } = await import(G('TunBoxProfileBuilder.ts'));

let passed = 0;
let failed = 0;
const check = (name, fn) => {
  try {
    fn();
    passed++;
    console.log(`PASS ${name}`);
  } catch (e) {
    failed++;
    console.log(`FAIL ${name} :: ${e.message}`);
  }
};
const assert = (cond, msg) => { if (!cond) throw new Error(msg); };

const mkBase = (extra) => {
  const config = {
    'mixed-port': 1234,
    'proxies': [{ 'name': 'TW', 'type': 'ss', 'server': 't.example.com', 'port': 443, 'cipher': 'aes-128-gcm', 'password': 'p' }],
    'proxy-groups': [{ 'name': 'Root', 'type': 'select', 'proxies': ['TW', 'DIRECT'] }],
    'rules': ['RULE-SET,hyper-adrules,REJECT', 'MATCH,Root'],
    ...extra,
  };
  const base = new TunBoxBaseData();
  base.config = config;
  base.digest = 't';
  base.proxies = config.proxies.length;
  base.proxyGroups = 1;
  base.rules = config.rules.length;
  base.matchRules = ['MATCH,Root'];
  return base;
};

const mkOverlay = (extra) => ({
  'mixed-port': 7890,
  'external-controller': '127.0.0.1:9090',
  'secret': 's',
  'mode': 'rule',
  'log-level': 'warning',
  'tun': { 'enable': true, 'stack': 'mips', 'auto-route': false, 'auto-detect-interface': false },
  'dns': { 'enable': true, 'enhanced-mode': 'fake-ip', 'nameserver': ['223.5.5.5'] },
  'rule-providers': {
    'hyper-adrules': { 'type': 'file', 'path': './ruleset/hyper-adrules.mrs', 'behavior': 'domain' },
  },
  'rules': ['DOMAIN-SUFFIX,ads.example,REJECT'],
  ...extra,
});

const mkInput = (over) => {
  const input = new TunBoxProfileInput();
  input.profileId = 'sub-9';
  input.profilePath = '/profiles/sub-9.yaml';
  input.profilesDir = '/profiles';
  input.overrideYaml = '';
  input.dnsOverrideEnabled = false;
  input.tunEnabled = true;
  input.ipv6Enabled = true;
  input.mtu = 1400;
  input.useSmart = false;
  input.smartTestUrl = 'https://www.gstatic.com/generate_204';
  input.smartPolicyPriority = '';
  return Object.assign(input, over ?? {});
};

const compose = (base, overlay, input) =>
  TunBoxProfileBuilder.compose(JSON.parse(JSON.stringify(base)), overlay, null, input ?? mkInput());

check('A. 注入 provider 声明保留 + 路径原样，RULE-SET 引用可满足', () => {
  const r = compose(mkBase(), mkOverlay());
  assert(r.ok, `compose 失败: ${r.error}`);
  const doc = JSON.parse(r.yaml);
  const decl = doc['rule-providers'];
  assert(decl && decl['hyper-adrules'], 'hyper-adrules 声明丢失');
  assert(doc['rules'].includes('RULE-SET,hyper-adrules,REJECT'), 'profile 的 RULE-SET 规则丢失');
  assert(decl['hyper-adrules']['path'] === './ruleset/hyper-adrules.mrs',
    '注入 provider 路径保持落盘原值（与 App provider 落盘路径一致，不二次收容）');
  assert(doc['rule-providers']['hyper-adrules']['behavior'] === 'domain', '声明字段丢失');
});

check('B. 原文自带 provider → 并集（两边块都在）；profile http 型收容', () => {
  const base = mkBase({
    'rule-providers': {
      'own-rules': { 'type': 'http', 'url': 'https://own.example/rules.yaml', 'interval': 86400 },
    },
    'rules': ['RULE-SET,own-rules,Root', 'MATCH,Root'],
  });
  const r = compose(base, mkOverlay());
  const doc = JSON.parse(r.yaml);
  assert(doc['rule-providers']['hyper-adrules'], '注入声明丢失');
  assert(doc['rule-providers']['own-rules'], '原文声明丢失');
  assert(doc['rules'].some((x) => x.startsWith('RULE-SET,own-rules')), '原文规则丢失');
  const expect = `/profiles/providers/sub-9/rules/${
    crypto.createHash('md5').update('own-rules@https://own.example/rules.yaml').digest('hex')}`;
  assert(doc['rule-providers']['own-rules']['path'] === expect,
    `profile http provider 必须收容: ${doc['rule-providers']['own-rules']['path']}`);
});

check('C. 同名 provider → profile 赢（注入先铺，task.dart:261-279）', () => {
  const base = mkBase({
    'rule-providers': {
      'hyper-adrules': { 'type': 'file', 'path': './ruleset/OLD.mrs', 'behavior': 'domain' },
    },
  });
  const r = compose(base, mkOverlay());
  const doc = JSON.parse(r.yaml);
  const confined = `/profiles/providers/sub-9/rules/${
    crypto.createHash('md5').update('rule-providers/hyper-adrules').digest('hex')}`;
  assert(doc['rule-providers']['hyper-adrules']['path'] === confined,
    `同名 profile 声明必须覆盖注入: ${doc['rule-providers']['hyper-adrules']['path']}`);
  assert(doc['rule-providers']['hyper-adrules']['path'] !== './ruleset/hyper-adrules.mrs',
    '注入行不得覆盖同名 profile 行');
});

check('D. proxy-providers 同理（注入保留 + profile http 收容 + inline 不收容）', () => {
  const base = mkBase({
    'proxy-providers': {
      'airport': { 'type': 'http', 'url': 'https://sub.example.com/clash.yaml', 'interval': 86400 },
      'file-pool': { 'type': 'file', 'path': './pool.yaml' },
    },
  });
  const overlay = mkOverlay({
    'proxy-providers': {
      'local-pool': { 'type': 'inline', 'payload': [{ 'name': 'inl', 'type': 'ss', 'server': 'i.example.com', 'port': 443, 'cipher': 'aes-128-gcm', 'password': 'p' }] },
    },
  });
  const r = compose(base, overlay);
  const doc = JSON.parse(r.yaml);
  assert(doc['proxy-providers']['airport'], '原文 proxy-provider 丢失');
  assert(doc['proxy-providers']['local-pool'], '注入 proxy-provider 丢失');
  const expect = `/profiles/providers/sub-9/proxies/${
    crypto.createHash('md5').update('airport@https://sub.example.com/clash.yaml').digest('hex')}`;
  assert(doc['proxy-providers']['airport']['path'] === expect,
    `url provider path 收容不符: ${doc['proxy-providers']['airport']['path']} vs ${expect}`);
  const fileExpect = `/profiles/providers/sub-9/proxies/${
    crypto.createHash('md5').update('proxy-providers/file-pool').digest('hex')}`;
  assert(doc['proxy-providers']['file-pool']['path'] === fileExpect,
    `file provider 无 URL 必须按 section/name 收容: ${doc['proxy-providers']['file-pool']['path']}`);
  assert(doc['proxy-providers']['local-pool']['path'] === undefined, 'inline provider 不收容');
  assert(r.providerMigrations.length === 1
    && r.providerMigrations[0].from === `/profiles/providers/sub-9/proxies/${
      crypto.createHash('md5').update('https://sub.example.com/clash.yaml').digest('hex')}`
    && r.providerMigrations[0].to === expect,
    `旧 URL-only 缓存迁移登记: ${JSON.stringify(r.providerMigrations)}`);
});

check('E. 两边都没有 provider 段 → 不凭空造空头', () => {
  const overlay = mkOverlay();
  delete overlay['rule-providers'];
  const r = compose(mkBase(), overlay);
  const doc = JSON.parse(r.yaml);
  assert(doc['rule-providers'] === undefined, '凭空造出空 rule-providers（内核拒载空 mapping）');
  assert(doc['proxy-providers'] === undefined, '凭空造出空 proxy-providers');
});

check('F. file provider 收容：无 URL key=section/name；http 型 name@url', () => {
  const base = mkBase({
    'rule-providers': {
      'local-rules': { 'type': 'file', 'path': './ruleset/local.yaml' },
      'remote-rules': { 'type': 'http', 'url': 'https://rules.example/list.yaml', 'interval': 86400 },
    },
  });
  const r = compose(base, mkOverlay());
  const doc = JSON.parse(r.yaml);
  const localExpect = `/profiles/providers/sub-9/rules/${
    crypto.createHash('md5').update('rule-providers/local-rules').digest('hex')}`;
  assert(doc['rule-providers']['local-rules']['path'] === localExpect,
    `file provider 不得原样保留: ${doc['rule-providers']['local-rules']['path']}`);
  const remoteExpect = `/profiles/providers/sub-9/rules/${
    crypto.createHash('md5').update('remote-rules@https://rules.example/list.yaml').digest('hex')}`;
  assert(doc['rule-providers']['remote-rules']['path'] === remoteExpect,
    `http provider 必须 name@url 收容: ${doc['rule-providers']['remote-rules']['path']}`);
});

check('G. 规则 MATCH 替换：选定 matchTarget / 回退最后 profile MATCH；no-resolve 与前置', () => {
  const base = mkBase({
    'rules': ['DOMAIN-SUFFIX,x.example,TW', 'MATCH,Root'],
  });
  const overlay = mkOverlay({
    'rules': [
      'DOMAIN,example.org,MATCH',
      'IP-CIDR,1.1.1.0/24,DIRECT,no-resolve',
    ],
  });
  const r = compose(base, overlay);
  const doc = JSON.parse(r.yaml);
  assert(doc['rules'].includes('DOMAIN,example.org,Root'),
    `附加 MATCH 必须替换为最后 profile MATCH target: ${JSON.stringify(doc['rules'])}`);
  assert(doc['rules'].includes('IP-CIDR,1.1.1.0/24,DIRECT,no-resolve'),
    `no-resolve 附加规则必须原样保留: ${JSON.stringify(doc['rules'])}`);
  assert(doc['rules'][0] === 'DOMAIN,example.org,Root'
    && doc['rules'][1] === 'IP-CIDR,1.1.1.0/24,DIRECT,no-resolve',
    `附加规则必须前置: ${JSON.stringify(doc['rules'])}`);
  assert(doc['rules'].includes('DOMAIN-SUFFIX,x.example,TW'), 'profile 规则被误杀');
  // 选定 matchTarget 优先于回退值
  const r2 = compose(base, overlay, mkInput({ matchTarget: 'TW' }));
  const doc2 = JSON.parse(r2.yaml);
  assert(doc2['rules'].includes('DOMAIN,example.org,TW'),
    `选定 matchTarget 必须优先: ${JSON.stringify(doc2['rules'])}`);
});

console.log('');
console.log(`PASSED=${passed}  FAILED=${failed}  TOTAL=${passed + failed}`);
if (failed === 0) {
  console.log('RESULT: PROFILE PROVIDER MERGE PASSED');
} else {
  console.log('RESULT: PROFILE PROVIDER MERGE FAILED');
  process.exit(1);
}
