#!/usr/bin/env node
/**
 * 订阅合并 · provider 段并集闸门（Profile Provider Merge Gate）
 *
 * ## 为什么有这道闸门（2026-10-23 用户真机报障）
 *
 * 现象：0.5.4 手动更新去广告规则后 VPN 启动失败，删掉规则集就正常。
 * 真机日志（VpnExtensionAbility）给出的内核原话：
 *
 *   vpn onCreate failed: code=-1 msg=parse config:
 *   rules[0] [RULE-SET,hyper-adrules,REJECT] error: rule set [hyper-adrules] not found
 *
 * 根因：`ProfileConfigMerger.merge()` 把 overlay（App 生成的运行配置）里的
 * `rule-providers` 段**整段删掉**再追加订阅原文的同名段；而订阅原文没有
 * `rule-providers`，于是：
 *   · overlay 的 `rules:` 被保留（RULE-SET,hyper-adrules,REJECT 仍在第一条）
 *   · overlay 的 `rule-providers:` 声明消失
 * → 引用在、声明丢 → 内核整份拒载 → 隧道起不来。
 *
 * ## 闸门断言什么
 *
 *  A. 用**真实的** `ProfileConfigMerger`（tools/true-chain-harness 生成）跑合并：
 *     overlay 有 provider + 原文没有 → 合并结果必须**保留** overlay 的 provider 声明，
 *     且 `RULE-SET,hyper-adrules` 仍能被声明满足（自洽性：每个 RULE-SET 引用的名字
 *     都能在 rule-providers 段找到声明）。
 *  B. 原文自带 provider（订阅自己的 rule-providers）→ 两边的块都要在（并集）。
 *  C. 同名 provider → overlay 优先（原文同名块被丢弃，不产生重复顶层键）。
 *  D. `proxy-providers` 同理（同类缺陷，一并守住）。
 *  E. 原文完全没有 provider 段时，不能凭空造出一个空 `rule-providers:` 头
 *     （空 mapping 会让内核报 cannot unmarshal）。
 *  F. 负对照：把实现改回「整段替换」→ 闸门必须变红。
 *
 * 跑法：
 *   node scripts/verify-profile-merge-providers.mjs
 *   node scripts/verify-profile-merge-providers.mjs --self-test
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const generated = (name) => pathToFileURL(path.join(root, 'tools/true-chain-harness/generated', name)).href;

let passed = 0;
let failed = 0;
const failures = [];

function check(name, fn) {
  try {
    fn();
    passed += 1;
    console.log(`PASS ${name}`);
  } catch (e) {
    failed += 1;
    failures.push(`${name} :: ${e.message}`);
    console.log(`FAIL ${name} :: ${e.message}`);
  }
}

/** 从 YAML 文本里取某顶层段的命名块名（2 空格缩进、以 : 结尾） */
function providerNames(yaml, key) {
  const lines = yaml.split('\n');
  const out = [];
  let inSection = false;
  for (const line of lines) {
    if (line === `${key}:` || line.startsWith(`${key}: `)) {
      inSection = true;
      continue;
    }
    if (!inSection) {
      continue;
    }
    if (/^[A-Za-z0-9_"'.-]+:/.test(line)) {
      inSection = false; // 回到顶层键
      continue;
    }
    const m = line.match(/^ {2}([A-Za-z0-9_.-]+):\s*$/);
    if (m) {
      out.push(m[1]);
    }
  }
  return out;
}

/** 取出 rules 段里所有 RULE-SET 引用的 provider 名 */
function ruleSetRefs(yaml) {
  const out = [];
  for (const line of yaml.split('\n')) {
    const m = line.match(/^\s*-\s*RULE-SET,([^,]+),/);
    if (m) {
      out.push(m[1].trim());
    }
  }
  return out;
}

const OVERLAY = `mixed-port: 7890
mode: rule
rules:
  - RULE-SET,hyper-adrules,REJECT
  - RULE-SET,rs-my-rules,REJECT
  - GEOIP,CN,DIRECT
rule-providers:
  hyper-adrules:
    type: http
    behavior: domain
    format: mrs
    interval: 86400
    path: ./ruleset/hyper_adrules_ads.mrs
    url: "https://example.invalid/hyper_adrules_ads.mrs"
  rs-my-rules:
    type: http
    behavior: domain
    format: yaml
    interval: 86400
    path: ./ruleset/custom_rs_my_rules
    url: "https://example.invalid/my-rules.yaml"
proxy-providers: []
`;

const PROFILE_NO_PROVIDERS = `proxies:
  - name: 香港01
    type: ss
    server: 1.2.3.4
    port: 8388
    cipher: aes-128-gcm
    password: x
proxy-groups:
  - name: 选择节点
    type: select
    proxies:
      - 香港01
rules:
  - GEOIP,CN,DIRECT
  - MATCH,选择节点
`;

const PROFILE_WITH_PROVIDERS = `${PROFILE_NO_PROVIDERS}rule-providers:
  sub-ads:
    type: http
    behavior: domain
    format: yaml
    interval: 86400
    path: ./ruleset/sub-ads.yaml
    url: "https://example.invalid/sub-ads.yaml"
`;

const PROFILE_SHADOW = `${PROFILE_NO_PROVIDERS}rule-providers:
  hyper-adrules:
    type: http
    behavior: ipcidr
    format: yaml
    interval: 3600
    path: ./ruleset/should-be-dropped.yaml
    url: "https://example.invalid/sub-version.yaml"
`;

async function main() {
  const selfTest = process.argv.includes('--self-test');
  const modulePath = path.join(root, 'tools/true-chain-harness/generated/ProfileConfigMerger.ts');
  if (!fs.existsSync(modulePath)) {
    // generated/ 不进 git（.gitignore 里忽略），新克隆的仓库必须先按真源码生成一遍
    console.log('generated/ProfileConfigMerger.ts 缺失，先跑 prepare 生成 …');
    const prepared = spawnSync(process.execPath,
      [path.join(root, 'tools/true-chain-harness/prepare.mjs')], { encoding: 'utf8' });
    if (prepared.status !== 0 || !fs.existsSync(modulePath)) {
      console.log('FAIL 无法生成 generated/ProfileConfigMerger.ts');
      console.log(prepared.stderr || prepared.stdout || '');
      process.exit(1);
    }
  }
  const { ProfileConfigMerger } = await import(generated('ProfileConfigMerger.ts'));

  const merge = (overlay, profile) => {
    const r = ProfileConfigMerger.merge(overlay, profile);
    assert.equal(r.ok, true, `merge 失败：${r.error}`);
    return r.yaml;
  };

  check('原文没有 provider 段时，overlay 的 rule-providers 声明必须保留', () => {
    const out = merge(OVERLAY, PROFILE_NO_PROVIDERS);
    const names = providerNames(out, 'rule-providers');
    assert.ok(names.includes('hyper-adrules'), `rule-providers 丢了 hyper-adrules；实际=${names.join(',')}`);
    assert.ok(names.includes('rs-my-rules'), `rule-providers 丢了自定义规则集 rs-my-rules；实际=${names.join(',')}`);
  });

  check('保留声明后 RULE-SET 引用自洽（引用 ⊆ 声明）', () => {
    const out = merge(OVERLAY, PROFILE_NO_PROVIDERS);
    const declared = new Set(providerNames(out, 'rule-providers'));
    const refs = ruleSetRefs(out);
    assert.ok(refs.length >= 2, `RULE-SET 规则条数异常：${refs.length}`);
    for (const ref of refs) {
      assert.ok(declared.has(ref), `RULE-SET 引用了未声明的 provider「${ref}」（内核会整份拒载）`);
    }
  });

  check('RULE-SET 仍在 rules 首条（顺序未被合并破坏）', () => {
    const out = merge(OVERLAY, PROFILE_NO_PROVIDERS);
    const rulesStart = out.indexOf('rules:');
    assert.ok(rulesStart >= 0, 'rules 段丢失');
    const firstRule = out.substring(rulesStart).split('\n').slice(1)
      .map((l) => l.trim()).filter((l) => l.startsWith('- '))[0];
    assert.equal(firstRule, '- RULE-SET,hyper-adrules,REJECT');
  });

  check('原文自带 rule-providers 时两边取并集', () => {
    const out = merge(OVERLAY, PROFILE_WITH_PROVIDERS);
    const names = providerNames(out, 'rule-providers');
    assert.ok(names.includes('hyper-adrules'), `丢了 overlay 的 hyper-adrules；实际=${names.join(',')}`);
    assert.ok(names.includes('sub-ads'), `丢了原文的 sub-ads；实际=${names.join(',')}`);
    assert.equal(names.filter((n) => n === 'hyper-adrules').length, 1, '同名 provider 被写了两次');
    assert.equal(out.split('\n').filter((l) => l === 'rule-providers:').length, 1,
      'rule-providers 顶层键重复（内核报 duplicate key）');
  });

  check('同名 provider 冲突时 overlay 优先（原文版本被丢弃）', () => {
    const out = merge(OVERLAY, PROFILE_SHADOW);
    const lines = out.split('\n');
    assert.ok(!lines.some((l) => l.includes('should-be-dropped')), '原文同名 provider 的字段泄漏进了最终配置');
    assert.ok(lines.some((l) => l.includes('behavior: domain')), 'overlay 的 behavior: domain 丢了');
    assert.ok(!lines.some((l) => l.trim() === 'behavior: ipcidr'), '原文的 behavior: ipcidr 覆盖了 overlay');
  });

  check('proxy-providers 同类并集（原文声明会保留）', () => {
    const overlay = OVERLAY.replace('proxy-providers: []', `proxy-providers:
  own-pp:
    type: http
    url: "https://example.invalid/pp.yaml"
    path: ./providers/own-pp.yaml`);
    const profile = `${PROFILE_NO_PROVIDERS}proxy-providers:
  sub-pp:
    type: http
    url: "https://example.invalid/sub-pp.yaml"
    path: ./providers/sub-pp.yaml
`;
    const out = merge(overlay, profile);
    const names = providerNames(out, 'proxy-providers');
    assert.ok(names.includes('own-pp'), `丢了 overlay 的 own-pp；实际=${names.join(',')}`);
    assert.ok(names.includes('sub-pp'), `丢了原文的 sub-pp；实际=${names.join(',')}`);
  });

  check('两边都没有 provider 段时不凭空造空头', () => {
    const overlay = `mixed-port: 7890
mode: rule
rules:
  - GEOIP,CN,DIRECT
`;
    const out = merge(overlay, PROFILE_NO_PROVIDERS);
    assert.ok(!out.includes('rule-providers:'), '凭空生成了 rule-providers 空段');
    assert.ok(!out.includes('proxy-providers:'), '凭空生成了 proxy-providers 空段');
  });

  check('不会把 provider 字段行漏到顶层（缩进必须保留）', () => {
    const out = merge(OVERLAY, PROFILE_NO_PROVIDERS);
    const lines = out.split('\n');
    assert.ok(!lines.includes('type: http'), 'provider 字段行掉到了顶层缩进');
    for (const key of ['type:', 'behavior:', 'format:', 'path:', 'url:']) {
      const top = lines.find((l) => l.startsWith(key));
      assert.equal(top, undefined, `字段「${key.trim()}」出现在顶层`);
    }
  });

  if (selfTest) {
    console.log('');
    console.log('── 负对照（回退成「整段替换」，必须复现用户报障）──');
    const mutatedPath = path.join(root, 'tools/true-chain-harness/generated/_mutant_ProfileConfigMerger.ts');
    const original = fs.readFileSync(modulePath, 'utf8');
    const mutant = original.replace(
      /const PROVIDER_MERGE_KEYS: string\[\] = \['proxy-providers', 'rule-providers'\];/,
      'const PROVIDER_MERGE_KEYS: string[] = [];');
    if (mutant === original) {
      failed += 1;
      failures.push('负对照变异未生效：generated 里的 PROVIDER_MERGE_KEYS 声明格式变了，请同步修改变异正则');
      console.log('    ❌ 变异未生效（正则没匹配到常量声明）');
    } else {
      fs.writeFileSync(mutatedPath, mutant);
      const { ProfileConfigMerger: Mutant } = await import(pathToFileURL(mutatedPath).href);
      const merged = Mutant.merge(OVERLAY, PROFILE_NO_PROVIDERS);
      const mutatedOut = merged.ok ? merged.yaml : '';
      fs.unlinkSync(mutatedPath);
      const names = providerNames(mutatedOut, 'rule-providers');
      const refs = ruleSetRefs(mutatedOut);
      const caught = !names.includes('hyper-adrules') && refs.includes('hyper-adrules');
      console.log(`  · 回退成整段替换 → rule-providers=[${names.join(',')}] refs=[${refs.join(',')}]`);
      console.log(caught ? '    ✅ 复现用户报障（引用在、声明丢），闸门判红' : '    ❌ 闸门不敏感：变异后仍看不到「声明丢失」');
      if (!caught) {
        failed += 1;
        failures.push('负对照未生效：变异后仍未复现「声明丢失」');
      }
    }
  }

  console.log('');
  console.log(`PASSED=${passed} FAILED=${failed} TOTAL=${passed + failed}`);
  console.log(`RESULT: ${failed === 0 ? 'PROFILE PROVIDER MERGE PASSED' : 'PROFILE PROVIDER MERGE FAILED'}`);
  for (const line of failures) {
    console.log(`  ❌ ${line}`);
  }
  process.exit(failed === 0 ? 0 : 1);
}

main();
