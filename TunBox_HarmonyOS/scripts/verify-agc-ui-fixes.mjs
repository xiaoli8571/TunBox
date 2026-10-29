#!/usr/bin/env node
/**
 * AGC 审核整改自检（状态栏适配 + 全屏转场时长）—— 2026-10-23 审核意见
 *
 * ## 审核原文
 *
 *  1. 状态栏适配：「采用沉浸一体化的背景设计，保证效果的整体性，避免状态栏区域被
 *     单独切割；根据页面内状态栏区域的背景色选择合适的状态栏颜色（黑/白），保证
 *     状态栏信息的易读性；避免在状态栏背景区域内采用左右半区对比差异过大的颜色，
 *     导致部分状态栏信息无法阅读。」
 *
 *  2. 转场时长：「全屏页面的转场（层级/新建/编辑/搜索等）在 8.5 英寸以下设备上
 *     不应短于 200ms，8.5~12 英寸不应短于 250ms，12 英寸以上不应短于 300ms。」
 *
 * ## 本闸门守的契约
 *
 *  A. 状态栏直接采用**页面背景色**（浅 #F4F6FB / 深 #0B1220，与 ui_background / 渐变起点同值）铺满整条，图标颜色
 *     跟随主题（浅色底深字 / 深色底浅字）；不许再回到「透明色条 + 系统底色」那种
 *     被切割的形态。
 *  B. 转场时长按**物理像素 + 真实 densityDPI** 换算英寸（不能用 densityPixels，
 *     系统显示缩放会把它改小 → 12.6" 平板被算成 9.4" → 只给 250ms，不达 300ms）；
 *     三档下限 200/250/300 必须存在；所有 PageTransitionEnter/Exit 都用
 *     TunBoxMotion.ms（不许写字面量时长）。
 *  C. 负对照（--self-test）：把状态栏改回透明、把 DPI 换回 densityPixels、
 *     把某个转场换回字面量，闸门必须变红。
 *
 * 跑法：
 *   node scripts/verify-agc-ui-fixes.mjs
 *   node scripts/verify-agc-ui-fixes.mjs --self-test
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const ets = path.join(root, 'entry/src/main/ets');

const read = (rel) => fs.readFileSync(path.join(ets, rel), 'utf8');
const PAGE_FILES = [
  'pages/AppRoutingPage.ets', 'pages/ConnectionsPage.ets', 'pages/NodeEditPage.ets',
  'pages/NodeSelectionPage.ets', 'pages/RulesPage.ets', 'pages/SiteRoutingPage.ets'
];

let passed = 0;
let failed = 0;
const failures = [];

function ok(cond, label, actual) {
  if (cond) {
    passed += 1;
    return;
  }
  failed += 1;
  failures.push(`  ❌ ${label}${actual === undefined ? '' : ` —— ${actual}`}`);
}

function checkTheme(src) {
  // 2026-10-28：浅色背景支持 Mint / Homebrew / Noctis 三套配色（用户要求），
  // 状态栏/窗口底色不再是一串写死的字面量，统一从 ThemeService.bgColors() 取（与页面渐变同源）。
  // 这里断言的**语义不变**：状态栏底色必须就是页面背景色，只是取值方式从字面量换成了调色板。
  ok(/const palette = ThemeService\.bgColors\(\);/.test(src) && /const pageBg = palette\.start;/.test(src),
    '状态栏底色 = 页面背景色（取自 ThemeService.bgColors().start，浅色随配色 / 深 #0B1220）');
  ok(/statusBarColor: pageBg,/.test(src),
    '状态栏铺页面背景色（不是透明色条，避免被单独切割）');
  ok(/const contentColor = dark \? '#F5F7FF' : '#171B2A';/.test(src),
    '状态栏图标颜色随主题切换（深色底浅字 / 浅色底深字）');
  ok(/statusBarContentColor: contentColor,/.test(src),
    '状态栏图标颜色接到 window 属性');
  ok(/navigationBarColor: bottomBg,/.test(src) && /navigationBarContentColor: contentColor,?/.test(src),
    '底部导航条同色 + 图标同口径（bottomBg = bgColors().end）');
  ok(/win\.setWindowBackgroundColor\(pageBg\);/.test(src),
    '窗口底色与页面同色（切换/首帧缝隙不露色）');
  ok(!/statusBarColor: '#00000000'/.test(src),
    '没有退回「透明状态栏」旧实现（那会露出系统底色形成色条）');
}

function checkMotion(entrySrc, tokensSrc, pageSources) {
  ok(/const dpi = d\.densityDPI > 0 \? d\.densityDPI : \(d\.xDPI > 0 \? d\.xDPI : 0\);/.test(entrySrc),
    '英寸换算用真实 densityDPI（不是会被显示缩放改写的 densityPixels）');
  ok(/Math\.sqrt\(d\.width \* d\.width \+ d\.height \* d\.height\) \/ dpi/.test(entrySrc),
    '对角线用物理像素：sqrt(w²+h²)/dpi');
  ok(/let floor = 200;/.test(entrySrc) && /floor = 250;/.test(entrySrc) && /floor = 300;/.test(entrySrc),
    '三档下限 200 / 250 / 300 齐全');
  ok(/inches > 12/.test(entrySrc) && /inches >= 8\.5/.test(entrySrc),
    '分档边界：>12 英寸 300ms、8.5~12 英寸 250ms、<8.5 英寸 200ms');
  ok(/AppStorage\.setOrCreate<number>\('tb_motion_required_ms', floor\);/.test(entrySrc),
    '下限写进 tb_motion_required_ms 供页面取用');
  ok(/this\.applyMotionFloorByScreenSize\(\);/.test(entrySrc), 'onCreate 里计算（早于任何页面创建）');
  ok(/static readonly BASE_MS: number = (\d+);/.test(tokensSrc)
    && Number(/static readonly BASE_MS: number = (\d+);/.exec(tokensSrc)[1]) >= 200,
    '设计基线 ≥ 200ms（小屏档本身合规）');
  ok(/const floor = required !== undefined && required > 0 \? required : 0;/.test(tokensSrc)
    && /return floor > TunBoxMotion\.BASE_MS \? floor : TunBoxMotion\.BASE_MS;/.test(tokensSrc),
    'TunBoxMotion.ms = max(基线, 规范下限)');

  for (const file of PAGE_FILES) {
    const src = pageSources.get(file);
    const enter = (src.match(/PageTransitionEnter\(/g) || []).length;
    const exit = (src.match(/PageTransitionExit\(/g) || []).length;
    const msEnter = (src.match(/PageTransitionEnter\(\{ duration: TunBoxMotion\.ms/g) || []).length;
    const msExit = (src.match(/PageTransitionExit\(\{ duration: TunBoxMotion\.ms/g) || []).length;
    ok(enter > 0 && enter === msEnter && exit > 0 && exit === msExit,
      `${path.basename(file)}：全屏转场时长全部走 TunBoxMotion.ms（无字面量）`,
      `enter ${msEnter}/${enter}, exit ${msExit}/${exit}`);
  }
  const mainSrc = pageSources.get('pages/MainPage.ets');
  const tabMs = (mainSrc.match(/\.animation\(\{ duration: TunBoxMotion\.ms, curve: TunBoxMotion\.curve \}\)/g) || []).length;
  ok(tabMs >= 6, '主页三大页签切换动效同样使用 TunBoxMotion.ms', `匹配 ${tabMs} 处`);
}

function runAll(sources) {
  checkTheme(sources.get('theme/ThemeService.ets'));
  checkMotion(sources.get('entryability/EntryAbility.ets'),
    sources.get('theme/TunBoxTokens.ets'), sources);
}

function loadSources() {
  const map = new Map();
  const files = ['theme/ThemeService.ets', 'theme/TunBoxTokens.ets', 'entryability/EntryAbility.ets',
    ...PAGE_FILES, 'pages/MainPage.ets'];
  for (const f of files) {
    map.set(f, read(f));
  }
  return map;
}

function selfTest(baseSources) {
  const cases = [
    {
      name: '状态栏退回透明色条',
      mutate: (s) => s.set('theme/ThemeService.ets',
        s.get('theme/ThemeService.ets').replace('statusBarColor: pageBg,', "statusBarColor: '#00000000',"))
    },
    {
      name: '英寸换算退回 densityPixels',
      mutate: (s) => s.set('entryability/EntryAbility.ets',
        s.get('entryability/EntryAbility.ets')
          .replace(/const dpi = d\.densityDPI > 0[\s\S]*?: 0\);/, 'const dpi = 0;')
          .replace('Math.sqrt(d.width * d.width + d.height * d.height) / dpi',
            'Math.sqrt(d.width * d.width + d.height * d.height) / (d.densityPixels > 0 ? d.densityPixels : 3)'))
    },
    {
      name: '某个全屏转场换回字面量时长',
      mutate: (s) => s.set('pages/RulesPage.ets',
        s.get('pages/RulesPage.ets').replace('PageTransitionEnter({ duration: TunBoxMotion.ms', 'PageTransitionEnter({ duration: 160'))
    }
  ];
  let allCaught = true;
  for (const testCase of cases) {
    const sources = new Map(baseSources);
    testCase.mutate(sources);
    const beforePassed = passed;
    const beforeFailed = failed;
    const beforeFailures = failures.length;
    runAll(sources);
    const caught = failed > beforeFailed;
    console.log(`  · ${testCase.name} → 判决 ${passed - beforePassed} passed, ${failed - beforeFailed} failed`);
    console.log(caught ? '    ✅ 被抓住' : '    ❌ 没抓住（闸门不敏感）');
    if (!caught) {
      allCaught = false;
    }
    passed = beforePassed;
    failed = beforeFailed;
    failures.length = beforeFailures;
  }
  return allCaught;
}

function main() {
  const withSelfTest = process.argv.includes('--self-test');
  const sources = loadSources();
  console.log('── AGC 审核整改自检（状态栏适配 + 全屏转场时长）──');
  runAll(sources);
  console.log(`  断言：${passed} passed, ${failed} failed`);
  for (const line of failures) {
    console.log(line);
  }
  let selfTestOk = true;
  if (withSelfTest) {
    console.log('');
    console.log('── 负对照（故意改坏源码，闸门必须 FAILED）──');
    selfTestOk = selfTest(sources);
  }
  console.log('');
  console.log(`PASSED=${passed} FAILED=${failed} TOTAL=${passed + failed}`);
  console.log(`RESULT: ${failed === 0 && selfTestOk ? 'AGC UI CHECKS PASSED' : 'AGC UI CHECKS FAILED'}`);
  process.exit(failed === 0 && selfTestOk ? 0 : 1);
}

main();

