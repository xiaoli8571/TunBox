#!/usr/bin/env node
/**
 * 底部 Dock × 系统导航条「融为一体」闸门 —— 2026-10-30 用户报障
 *
 * ## 用户原文
 *   「手机底部的状态栏是实色，跟软件底部的 dock 栏产生很强的割裂感，并且往下滑动的时候会遮挡内容。
 *     dock 栏也因为这个遮挡位置太高了，dock 位置也往下调整一点，让导航栏和 dock 栏看起来融为一体。」
 *
 * ## 真机取证（像素级，见 `entry/src/main/ets/theme/SafeArea.ets` 文件头）
 * 621×154 的底部裁切里逐个采样：
 *   · 带内像素 (11,14,22)；
 *   · 页面渐变终点 `#0F131D` = (15,19,29)；
 *   · 15×0.75=11.25、19×0.75=14.25、29×0.75=21.75 —— **三个通道全部吻合 0.75**。
 * 结论：那条带不是「页面没铺到」，是**系统在导航条窗口上又压了一层 25% 的黑**，
 * `navigationBarColor: '#00000000'` 关不掉它（0.7.5 已经设成透明了，仍然在）。
 *
 * ## 本闸门守的契约
 *  A. 窗口必须是**沉浸式**（`setWindowLayoutFullScreen(true)`）：底部那一条归属 App，
 *     透明才是真的透明 —— 否则内容永远在带子上被截断（用户说的「遮挡内容」）。
 *  B. 沉浸式的代价必须补回来：布局不再自动避让状态栏/导航条，所以
 *     ① 顶部：`TopNavBar` 以及两个自绘顶栏的页面必须用 `SafeArea.topPad()` 让出状态栏；
 *     ② 底部：Dock 必须按「距屏幕底边 `SafeArea.dockGap()`」定位
 *        （`dockBottomMargin()` + `dockSink()` 两条腿，覆盖「沉浸式生效 / 仍在避让」两种设备）。
 *  C. 自校准存在：`SafeArea.calibrate()` 用「100% 高、没挂 expandSafeArea 的容器」实测高度
 *     与整屏比，判布局到底避不避让 —— 不许把任一假设写死。
 *  D. 内容留白跟实测走：`TunBoxGeometry.dockClearance()` 是**函数**（不是常量），
 *     下限不低于 112（回归护栏：低于它，Dock 的 26vp 模糊会把末张卡片抹成「半截阴影」）。
 *  E. 负对照（--self-test）：把沉浸式开关改成 false / 把顶栏留白删掉 / 把 Dock 定位退回旧写法 /
 *     把某个页面的 dockClearance 括号丢掉，闸门必须变红。
 *
 * 跑法：
 *   node scripts/verify-bottom-dock-immersive.mjs
 *   node scripts/verify-bottom-dock-immersive.mjs --self-test
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const ets = path.join(root, 'entry/src/main/ets');
const read = (rel) => fs.readFileSync(path.join(ets, rel), 'utf8');
const NL = String.fromCharCode(10);

/** 自绘顶栏、不走 TopNavBar 的两个页面（必须自己补状态栏留白） */
const CUSTOM_HEADER_PAGES = ['pages/NodeEditPage.ets', 'pages/NodeSelectionPage.ets'];

/** 走 TopNavBar、2026-10-30 改成「浮层玻璃顶栏」的三个页签页 */
const TAB_PAGES = ['pages/HomePage.ets', 'pages/StatsPage.ets', 'pages/SettingsPage.ets'];

/** 去掉注释，只留代码（注释里写 `TunBoxGeometry.dockClearance` 是正常文档写法） */
const BLOCK_COMMENT = new RegExp('/\\*[\\s\\S]*?\\*/', 'g');
const codeOnly = (body) => body
  .replace(BLOCK_COMMENT, '')
  .split(NL)
  .filter((ln) => !ln.trim().startsWith('//'))
  .join(NL);

function runChecks(src) {
  let passed = 0;
  const failures = [];
  const ok = (cond, label) => {
    if (cond) {
      passed += 1;
    } else {
      failures.push(label);
    }
  };

  // ── A. 沉浸式窗口 ──
  const ability = src.ability;
  ok(/setWindowLayoutFullScreen\(true\)/.test(ability),
    'EntryAbility 打开窗口沉浸式（底部导航条归属 App，挡住了才能透明）');
  ok(/private enableImmersiveLayout\(win: window\.Window\): void \{/.test(ability)
    && /\.catch\(\(e: BusinessError\) => \{/.test(ability),
    '沉浸式开关失败不阻断启动（有 catch，退回非沉浸式行为）');
  ok((ability.match(/this\.enableImmersiveLayout\(win\);/g) ?? []).length >= 2,
    '主题恢复成功与失败分支都开启沉浸式并由 enableImmersiveLayout 负责安全区测量');
  ok(/setWindowLayoutFullScreen\(true\)\.then\(\(\) => \{[\s\S]{0,600}SafeArea\.init\(win\);[\s\S]{0,80}SafeArea\.publish\(\);/.test(ability),
    '沉浸式生效后再测量避让区并重算 Dock 几何');

  // ── 系统栏仍然透明（不许退回不透明色：那是另一条已修的回归）──
  const theme = src.theme;
  ok(/navigationBarColor: ThemeService\.BAR_TRANSPARENT,/.test(theme),
    '底部导航条保持透明（沉浸式下这才是「真的透明」）');
  ok(/statusBarColor: ThemeService\.BAR_TRANSPARENT,/.test(theme),
    '状态栏保持透明（0.7.5 的修复不许回滚）');

  // ── B①. 顶部留白 ──
  // 2026-10-30 二修：TopNavBar 从「实底一条」改成「浮层玻璃」——
  // 让白仍由 SafeArea.topPad() 决定，但必须走 padding（margin 画不到背景，玻璃盖不住状态栏区）。
  ok(/\.padding\(\{[\s\S]{0,220}this\.insetTop/.test(src.topNav)
    && /@StorageProp\('tb_inset_top'\)/.test(src.topNav),
    'TopNavBar 通过状态绑定让出状态栏，安全区变化时能触发重排');
  ok(!/\.margin\(\{\s*top:\s*SafeArea\.topPad\(\)\s*\}\)/.test(src.topNav),
    'TopNavBar 不再用 margin 让白（旧写法会让顶栏变成一条实底，内容被完全遮挡）');
  for (const page of CUSTOM_HEADER_PAGES) {
    ok(/\.padding\(\{ top: SafeArea\.topPad\(\) \}\)/.test(src.pages[page]),
      `${page} 自绘顶栏让出状态栏`);
  }

  ok(/\.linearGradient\(\{ angle: 180, colors: this\.tintStops\(\) \}\)/.test(codeOnly(src.topNav)),
    '顶栏保留连续淡染色，不回退到不透明背板');

  // ── B②. Dock 定位 ──
  const dock = src.dock;
  ok(/\.margin\(\{ bottom: TunBoxGeometry\.dockBottomMargin\(\) \}\)/.test(dock),
    'Dock 底部外边距取实测值（沉浸式生效时 = gap）');
  ok(/\.translate\(\{ y: TunBoxGeometry\.dockSink\(\) \}\)/.test(dock),
    'Dock 下沉量取实测值（设备仍在避让时补 insetBottom−gap，两种设备同落点）');
  ok(!/\.expandSafeArea\(\[SafeAreaType\.SYSTEM\], \[SafeAreaEdge\.BOTTOM\]\)/.test(dock),
    'Dock 不再靠 expandSafeArea 硬顶进导航条（那条带现在归 App，硬顶会叠出第二层材质）');

  // ── C. 自校准 ──
  const safe = src.safeArea;
  ok(/static calibrate\(boxHeightVp: number\): void \{/.test(safe),
    'SafeArea 有自校准（用容器实测高度判布局避不避让，不写死假设）');
  ok(/TYPE_NAVIGATION_INDICATOR/.test(safe) && /TYPE_SYSTEM/.test(safe),
    '同时量 TYPE_SYSTEM 与 TYPE_NAVIGATION_INDICATOR 的底部避让区（取大）');
  ok(/win\.on\('avoidAreaChange'/.test(safe),
    '订阅 avoidAreaChange（三键↔手势切换 / 转屏 / 折叠屏展开都会重算）');
  ok(/static topPad\(\): number \{[\s\S]{0,400}SafeArea\.avoidActive\(\)[\s\S]{0,200}return 0;/.test(safe),
    'topPad 只在「确实不避让」时补，避免双重留白');
  // 顶栏不再使用会导致真机闪烁/空白页的渐变模糊 API；滚动内容改用 fadingEdge。
  ok(!/linearGradientBlur/.test(codeOnly(src.topNav))
    && !/linearGradientBlur/.test(codeOnly(src.pages['pages/HomePage.ets']))
    && !/linearGradientBlur/.test(codeOnly(src.pages['pages/SettingsPage.ets']))
    && !/linearGradientBlur/.test(codeOnly(src.pages['pages/StatsPage.ets'])),
    '顶栏和滚动页面不使用 linearGradientBlur（避免真机闪烁/空白页）');
  ok(/@StorageProp\('tb_inset_top'\)/.test(src.topNav)
    && /@StorageProp\('tb_avoid_active'\)/.test(src.topNav),
    '顶栏安全区参数使用 ArkUI 状态绑定');
  ok(/static headerReserve\(\): number/.test(src.tokens),
    '有 headerReserve() 统一算浮层顶栏总高');
  for (const page of TAB_PAGES) {
    const body = src.pages[page];
    ok(body.includes('TunBoxGeometry.headerReserve()'),
      `${page} 滚动内容让出浮层顶栏高度（首屏不被压住，滚动时从玻璃下穿过）`);
    ok(/Stack\(\{\s*alignContent:\s*Alignment\.Top\s*\}\)/.test(body),
      `${page} 根容器是 Stack(Top)：顶栏浮在内容之上`);
  }
  let fadeHits = 0;
  for (const rel of Object.keys(src.pages).concat(['components/SubscriptionSection.ets'])) {
    const body = src.pages[rel] ?? '';
    const n = (body.match(/fadingEdge\(true/g) ?? []).length;
    fadeHits += n;
  }
  const sub = read('components/SubscriptionSection.ets');
  fadeHits += (sub.match(/fadingEdge\(true/g) ?? []).length;
  ok(fadeHits >= 13,
    `滚动容器普遍开启边缘渐隐（命令式合计 ${fadeHits} 处）—— 到顶不再硬切，改成渐变淡出`);
  ok(/static readonly scrollFadeEdge: number = (\d+);/.test(src.tokens),
    '渐隐长度有令牌（scrollFadeEdge）');

  // ── 取样点 ──
  ok(/SafeArea\.calibrate\(Number\(cur\.height\)\);/.test(src.mainPage),
    'MainPage 用「100% 高、没挂 expandSafeArea」的容器当校准取样点');

  // ── D. 内容留白 ──
  ok(/static dockClearance\(\): number \{/.test(src.tokens),
    'TunBoxGeometry.dockClearance 是函数（跟实测手势区走）');
  ok(/const CLEARANCE_FLOOR: number = 112;/.test(safe),
    '内容留白下限 112（低于它，Dock 的 26vp 模糊会把末张卡片抹成半截阴影 —— 2026-10-29 的回归）');
  for (const [page, body] of Object.entries(src.pages)) {
    ok(!/TunBoxGeometry\.dockClearance(?!\()/.test(codeOnly(body)),
      `${page} 的 dockClearance 调用带括号（常量改函数后忘了改＝留白变 0，内容压进 Dock）`);
  }

  return { passed, failures };
}

function load() {
  const pages = {};
  for (const f of fs.readdirSync(path.join(ets, 'pages'))) {
    pages[`pages/${f}`] = read(`pages/${f}`);
  }
  return {
    ability: read('entryability/EntryAbility.ets'),
    theme: read('theme/ThemeService.ets'),
    topNav: read('components/TopNavBar.ets'),
    dock: read('components/FloatingBottomBar.ets'),
    safeArea: read('theme/SafeArea.ets'),
    tokens: read('theme/TunBoxTokens.ets'),
    mainPage: read('pages/MainPage.ets'),
    pages
  };
}

const src = load();
const result = runChecks(src);
console.log('── 底部 Dock × 系统导航条（沉浸式）闸门 ──');
console.log(`  断言：${result.passed} passed, ${result.failures.length} failed`);
for (const f of result.failures) {
  console.log(`  ❌ ${f}`);
}

let negativeFails = 0;
if (process.argv.includes('--self-test')) {
  console.log('');
  console.log('── 负对照（故意改坏，闸门必须 FAILED）──');
  const negatives = [
    ['沉浸式开关改成 false（底部那一条重新归系统，实色带回来）', (s) => {
      s.ability = s.ability.replace('win.setWindowLayoutFullScreen(true)', 'win.setWindowLayoutFullScreen(false)');
    }],
    ['顶栏不再让出状态栏（沉浸式后标题钻进时钟底下）', (s) => {
      // 2026-10-30 二修后让白改走 padding，负对照也要跟着改新写法
      s.topNav = s.topNav.replace('top: this.avoidActive ? 0 : Math.max(0, this.insetTop - 12)', 'top: 0');
    }],
    ['顶栏退回实底一条（内容又被完全遮挡，不再是渐变模糊）', (s) => {
      s.topNav = s.topNav
        .replace(/\.backgroundEffect\(\{[\s\S]*?\}\)/, '')
        .replace(/\.linearGradient\(\{[\s\S]*?\}\)/, '');
    }],
    ['Dock 退回旧写法（margin 0 + expandSafeArea，又被顶回带子上方）', (s) => {
      s.dock = s.dock
        .replace('.margin({ bottom: TunBoxGeometry.dockBottomMargin() })', '.margin({ bottom: 0 })')
        .replace('.translate({ y: TunBoxGeometry.dockSink() })',
          '.expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])');
    }],
    ['内容留白忘了改括号（常量→函数后留白变 0）', (s) => {
      s.pages['pages/SettingsPage.ets'] = s.pages['pages/SettingsPage.ets']
        .replace('Blank().height(TunBoxGeometry.dockClearance())', 'Blank().height(TunBoxGeometry.dockClearance)');
    }]
  ];
  let caught = 0;
  for (const [label, mutate] of negatives) {
    const copy = JSON.parse(JSON.stringify(src));
    mutate(copy);
    if (JSON.stringify(copy) === JSON.stringify(src)) {
      throw new Error(`负对照没有修改任何源码: ${label}`);
    }
    const r = runChecks(copy);
    const red = r.failures.length > 0;
    if (red) {
      caught += 1;
    }
    console.log(`  · ${label} → 判决 ${r.passed} passed, ${r.failures.length} failed ${red ? '✅ 被抓住' : '❌ 漏了'}`);
  }
  console.log(`NEGATIVE=${caught}/${negatives.length}`);
  negativeFails = negatives.length - caught;
}

console.log('');
console.log(`PASSED=${result.passed} FAILED=${result.failures.length}`);
if (result.failures.length > 0 || negativeFails > 0) {
  console.log('RESULT: BOTTOM DOCK CHECKS FAILED');
  process.exit(1);
}
console.log('RESULT: BOTTOM DOCK CHECKS PASSED');
