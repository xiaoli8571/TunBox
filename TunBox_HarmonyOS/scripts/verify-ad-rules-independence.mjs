#!/usr/bin/env node
/**
 * 去广告开关独立性 + 内置规则集闸门（Ad-Rules Independence Gate）
 *
 * ## 用户口径（2026-10-23）
 *
 *  1. 「数据与规则」→「数据」，去广告规则集不再是「数据」页里的可更新/可删除资产；
 *  2. 去广告规则集随安装包内置（rawfile），开箱即用，不依赖首次联网；
 *  3. 设置页「广告拦截规则」→「路由与规则」；
 *  4. 其中的去广告开关是**独立开关**：不受「启用规则路由引擎」影响；
 *  5. 去广告开关默认关闭。
 *
 * ## 为什么必须用行为断言（而不只是 grep 源码）
 *
 * 开关耦合散落在三处：配置生成器（provider 声明 + RULE-SET 引用）、
 * RuntimeConfigBuilder（adRulesOn）、编排器（后台补下载闸门）。
 * 任何一处漏改，症状都是「规则引擎关掉时去广告静默失效」—— 界面看不出来，
 * 只有看生成出来的 YAML / 内核日志才知道。所以这里**真的生成配置**再断言。
 *
 * 跑法：
 *   node scripts/verify-ad-rules-independence.mjs
 *   node scripts/verify-ad-rules-independence.mjs --self-test   （含负对照）
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const generatedDir = path.join(root, 'tools/true-chain-harness/generated');
const generated = (name) => pathToFileURL(path.join(generatedDir, name)).href;
const ets = (rel) => path.join(root, 'entry/src/main/ets', rel);

// harness 产出的 .ts 里有 enum（ArkTS 源码原样保留）→ 必须用 transform-types 模式跑，
// 单纯的 strip-only 会直接抛 ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX。
if (process.env.TUNBOX_AD_INDEP_CHILD !== '1') {
  const res = spawnSync(process.execPath,
    ['--experimental-transform-types', '--no-warnings', fileURLToPath(import.meta.url),
      ...process.argv.slice(2)],
    { stdio: 'inherit', env: { ...process.env, TUNBOX_AD_INDEP_CHILD: '1' } });
  process.exit(res.status === null ? 1 : res.status);
}

let passed = 0;
let failed = 0;
const failures = [];

function ok(cond, label, detail) {
  if (cond) {
    passed++;
    console.log(`  ✅ ${label}`);
  } else {
    failed++;
    failures.push(`${label}${detail ? ` :: ${detail}` : ''}`);
    console.log(`  ❌ ${label}${detail ? `\n       ${detail}` : ''}`);
  }
}

function ensureGenerated() {
  const need = ['ClashConfigGenerator.ts', 'AppSettings.ts', 'ProxyNode.ts', 'stubs.ts'];
  const missing = need.filter((n) => !fs.existsSync(path.join(generatedDir, n)));
  if (missing.length === 0) {
    return true;
  }
  console.log(`generated/ 缺 ${missing.join(', ')}，先跑 prepare 生成 …`);
  const res = spawnSync(process.execPath,
    [path.join(root, 'tools/true-chain-harness/prepare.mjs')], { encoding: 'utf8' });
  if (res.status !== 0) {
    console.log(res.stderr || res.stdout || '');
    return false;
  }
  return need.every((n) => fs.existsSync(path.join(generatedDir, n)));
}

/** 生成一份配置（隧道口径），只看与去广告相关的两段 */
async function buildYaml(mods, gate) {
  const { ClashConfigGenerator } = mods;
  const settings = new mods.AppSettings();
  settings.proxyMode = 'rule';
  settings.coreLogLevel = 'warning';
  settings.rulesEnabled = gate.rulesEnabled;
  settings.hyperAdRulesEnabled = gate.hyperAdRulesEnabled;
  const node = new mods.ProxyNode();
  node.id = 'n1';
  node.name = 'HK-01';
  node.originalName = 'HK-01';
  node.server = 'hk01.example.com';
  node.port = 443;
  node.proxyType = 'ss';
  node.method = 'aes-128-cipher';
  node.password = 'probe';
  node.type = 3;
  return ClashConfigGenerator.generate(node, [node], settings, 7890, 9090, 1053, 'secret',
    true, true, {}, true, [], gate.ruleProviderReady, false, [], '', '', [], []);
}

/** rules 段里第一条 RULE-SET 是否引用 hyper-adrules */
function hasAdRuleSet(yaml) {
  return /\n\s*-\s*RULE-SET,hyper-adrules,REJECT/.test(`\n${yaml}`);
}

/** 是否声明了 hyper-adrules provider 块 */
function declaresProvider(yaml) {
  return /^\s{2}hyper-adrules:\s*$/m.test(yaml);
}

async function main() {
  const selfTest = process.argv.includes('--self-test');
  console.log('═══ 去广告开关独立性 + 内置规则集 ═══\n');

  // ── A. 默认值 ────────────────────────────────────────────────────────────
  if (!ensureGenerated()) {
    console.log('FAIL 无法生成 harness 模块');
    process.exit(1);
  }
  const mods = {
    ClashConfigGenerator: (await import(generated('ClashConfigGenerator.ts'))).ClashConfigGenerator,
    AppSettings: (await import(generated('AppSettings.ts'))).AppSettings,
    ProxyNode: (await import(generated('ProxyNode.ts'))).ProxyNode,
  };
  console.log('A. 默认值');
  const defaults = new mods.AppSettings();
  ok(defaults.hyperAdRulesEnabled === false, 'A1 去广告开关默认关闭（AppSettings 运行时默认值）');
  ok(defaults.rulesEnabled === false, 'A2 规则引擎默认关闭（与去广告互不影响）');
  const { AppSettingsJson } = await import(generated('AppSettings.ts'));
  ok(new AppSettingsJson().rulesEnabled === false, 'A3 持久化模型默认关闭');
  ok(mods.AppSettings.fromJson({}).rulesEnabled === false, 'A4 旧配置缺少开关时保持关闭');
  for (const rulesEnabled of [false, true]) {
    const restored = mods.AppSettings.fromJson({ rulesEnabled });
    ok(restored.rulesEnabled === rulesEnabled, `A5 显式保存 ${rulesEnabled} 可恢复`);
    ok(mods.AppSettings.fromJson(restored.toJson()).rulesEnabled === rulesEnabled,
      `A6 显式保存 ${rulesEnabled} 往返不变`);
  }

  // ── B. 行为断言：四种组合 ────────────────────────────────────────────────
  console.log('\nB. 生成配置（行为断言）');
  const onOff = (rulesEnabled, hyperAdRulesEnabled, ready) =>
    buildYaml(mods, { rulesEnabled, hyperAdRulesEnabled, ruleProviderReady: ready });

  const engineOff = await onOff(false, true, true);
  ok(hasAdRuleSet(engineOff), 'B1 规则引擎关 + 去广告开 → RULE-SET 仍然生成（独立开关）');
  ok(declaresProvider(engineOff), 'B2 规则引擎关 + 去广告开 → provider 仍然声明（引用 ⊆ 声明）');
  ok(engineOff.includes('MATCH,'), 'B3 规则引擎关时仍有兜底规则（去广告规则挂在同一张表上）');

  const adsOff = await onOff(true, false, true);
  ok(!hasAdRuleSet(adsOff), 'B4 去广告关 → 不生成 RULE-SET');
  ok(!declaresProvider(adsOff), 'B5 去广告关 → 不声明 provider（不留死声明）');

  const notReady = await onOff(false, true, false);
  ok(!hasAdRuleSet(notReady), 'B6 规则集未就绪 → 不生成 RULE-SET（避免内核启动期拒载）');
  ok(!declaresProvider(notReady), 'B7 规则集未就绪 → 不声明 provider');

  const bothOff = await onOff(false, false, true);
  ok(!hasAdRuleSet(bothOff) && !declaresProvider(bothOff), 'B8 两个开关都关 → 两段都不出现');

  // ── C. 内置规则集随包发布 ────────────────────────────────────────────────
  console.log('\nC. 内置规则集');
  const bundled = path.join(root, 'entry/src/main/resources/rawfile/hyper_adrules_ads.mrs');
  ok(fs.existsSync(bundled), 'C1 rawfile 里有内置去广告规则集');
  if (fs.existsSync(bundled)) {
    const stat = fs.statSync(bundled);
    ok(stat.size >= 1024, `C2 内置规则集体积正常（${stat.size} bytes）`);
    const head = fs.readFileSync(bundled).subarray(0, 4);
    ok(head[0] === 0x28 && head[1] === 0xB5 && head[2] === 0x2F && head[3] === 0xFD,
      'C3 内置规则集是合法 zstd frame（0x28B52FFD）');
  }
  const orchSrc = fs.readFileSync(ets('commons/services/ConnectionOrchestrator.ets'), 'utf8');
  ok(orchSrc.includes('seedRuleSetFromRawfile'), 'C4 编排器有「从内置副本铺盘」的实现');
  ok(orchSrc.includes('const BUNDLED_RULE_SET_RAWFILE'), 'C5 内置资源名集中定义（单一真源）');
  ok(!orchSrc.includes("item('ruleset'"), 'C6 「数据」页资产列表不再包含去广告规则集');

  // ── D. 三处闸门都必须解耦 ────────────────────────────────────────────────
  console.log('\nD. 闸门解耦（源码断言）');
  const cfgSrc = fs.readFileSync(ets('commons/services/ClashConfigGenerator.ets'), 'utf8');
  const builderSrc = fs.readFileSync(ets('commons/config/RuntimeConfigBuilder.ets'), 'utf8');
  ok(!cfgSrc.includes('settings.rulesEnabled && settings.hyperAdRulesEnabled'),
    'D1 生成器不再用「规则引擎 && 去广告」做闸门');
  ok(cfgSrc.includes('if (settings.hyperAdRulesEnabled && ruleProviderReady) {'),
    'D2 生成器闸门只看去广告开关 + 文件就绪');
  ok(builderSrc.includes('const adRulesOn = settings.hyperAdRulesEnabled;'),
    'D3 RuntimeConfigBuilder 的 adRulesOn 只看去广告开关');
  ok(orchSrc.includes('const adRulesOn = settings.hyperAdRulesEnabled;'),
    'D4 编排器后台补下载闸门只看去广告开关');

  // ── E. UI 与文案 ─────────────────────────────────────────────────────────
  console.log('\nE. 页面与文案');
  const rulesPage = fs.readFileSync(ets('pages/RulesPage.ets'), 'utf8');
  const settingsPage = fs.readFileSync(ets('pages/SettingsPage.ets'), 'utf8');
  const adToggleBlock = rulesPage.slice(rulesPage.indexOf('HyperADRules 智能去广告'),
    rulesPage.indexOf('HyperADRules 智能去广告') + 900);
  ok(!/\.enabled\(this\.rulesEnabled\)/.test(adToggleBlock),
    'E1 去广告开关不再跟随规则引擎禁用/启用');
  ok(rulesPage.includes('独立开关'), 'E2 去广告开关有「独立开关」说明文案');
  ok(settingsPage.includes("Text('路由与规则')"), 'E3 设置页入口改名为「路由与规则」');
  ok(!settingsPage.includes("Text('广告拦截规则')"), 'E4 旧名「广告拦截规则」不再出现');
  const baseStrings = fs.readFileSync(path.join(root, 'entry/src/main/resources/base/element/string.json'), 'utf8');
  ok(/\{\s*"name":\s*"settings_geo_title",\s*"value":\s*"数据"\s*\}/.test(baseStrings),
    'E5 「数据与规则」分节标题改为「数据」');

  // ── F. 负对照 ────────────────────────────────────────────────────────────
  if (selfTest) {
    console.log('\nF. 负对照（把闸门改回「规则引擎 && 去广告」，行为断言必须变红）');
    const mutantPath = path.join(generatedDir, '_mutant_ClashConfigGenerator.ts');
    const original = fs.readFileSync(path.join(generatedDir, 'ClashConfigGenerator.ts'), 'utf8');
    const mutant = original.replace(
      /if \(settings\.hyperAdRulesEnabled && ruleProviderReady\)/g,
      'if (settings.rulesEnabled && settings.hyperAdRulesEnabled && ruleProviderReady)');
    if (mutant === original) {
      failed++;
      failures.push('负对照变异未生效：生成器闸门文本变了，请同步修变异正则');
      console.log('    ❌ 变异未生效（正则没匹配到闸门）');
    } else {
      fs.writeFileSync(mutantPath, mutant);
      const { ClashConfigGenerator: Mutant } = await import(pathToFileURL(mutantPath).href);
      const mutantYaml = await buildYaml({ ...mods, ClashConfigGenerator: Mutant },
        { rulesEnabled: false, hyperAdRulesEnabled: true, ruleProviderReady: true });
      fs.unlinkSync(mutantPath);
      const lostRule = !hasAdRuleSet(mutantYaml);
      const lostProvider = !declaresProvider(mutantYaml);
      console.log(`  · 改回耦合闸门 → RULE-SET=${hasAdRuleSet(mutantYaml)} provider=${declaresProvider(mutantYaml)}`);
      ok(lostRule && lostProvider,
        'F1 耦合闸门下「规则引擎关 + 去广告开」会静默丢掉去广告（闸门判红）',
        '变异后行为与修复前一致才说明断言有效');
    }
  }

  console.log(`\nPASSED=${passed} FAILED=${failed} TOTAL=${passed + failed}`);
  console.log(`RESULT: ${failed === 0 ? 'AD RULES INDEPENDENCE PASSED' : 'AD RULES INDEPENDENCE FAILED'}`);
  for (const line of failures) {
    console.log(`  ❌ ${line}`);
  }
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => {
  console.log(`FAIL 未捕获异常：${e && e.stack ? e.stack : e}`);
  process.exit(1);
});
