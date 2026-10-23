# AGC 审核整改记录（2026-10-23）：状态栏适配 + 全屏转场时长

> 来源：华为 AGC 上架审核报告（0.5.2 提交批）。两条意见 → 逐条定位根因、修复、真机验收。
> 相关代码：`theme/ThemeService.ets`、`theme/TunBoxTokens.ets`、`entryability/EntryAbility.ets`；
> 闸门：`scripts/verify-agc-ui-fixes.mjs`（22 断言 + 3 负对照）。
> 版本：0.5.4（versionCode 518）。

## 一、状态栏适配

审核原文：采用沉浸一体化的背景设计，避免状态栏区域被单独切割；根据页面内状态栏区域的
背景色选择合适的状态栏颜色（黑/白）；避免左右半区对比差异过大。

### 根因

状态栏原来是**透明色条**（`statusBarColor: '#00000000'`），透出的是窗口/系统底色，
而页面自己画的是渐变底。深色模式下三个"黑"根本不是同一个值：

| 层 | 深色值 |
|---|---|
| 窗口底色（旧） | `#171B22` |
| 页面渐变起点（旧） | `#0A0E1A` |
| 平色页 `ui_background` | `#0B1220` |

于是顶部必然出现一条比页面更深的窄带（截图上看就是"被单独切割"）；浅色下
`#F4F6FB` 与窗口底色相同只是巧合，换成别的页面组合同样会露色。

### 修复

- 状态栏直接铺**页面背景色本身**：浅 `#F4F6FB` / 深 `#0B1220`
  （后者与 `ui_background`、渐变起点取同一个值），整条单一颜色 —— 不存在左右半区深浅差异。
- 图标颜色随主题：浅底深字 `#171B2A`、深底浅字 `#F5F7FF`。
- 底部导航条同色（渐变终点 `#EBF1FD` / `#0F131D`）+ 图标同口径，底部不留白条。
- 窗口底色改成页面同色，切换/首帧缝隙不露另一层色。
- 深色渐变起点 `#0A0E1A` → `#0B1220`，页面顶部与状态栏连成一片。

### 真机验收（MLR-AL00，1600×2560）

- 深色：主页、订阅页 —— 状态栏与页面同色，白色图标清晰，无窄带。
- 浅色：主页、订阅页、pushed 页（设置 → 应用分流）—— 同色、深色图标清晰。
- 截图（`docs/evidence/2026-10-23-agc/`）：`statusbar-dark-home.jpg`（深色主页）、
  `statusbar-dark-subscriptions.jpg`（深色订阅）、`statusbar-light-subscriptions.jpg`（浅色订阅）、
  `statusbar-light-pushed-page.jpg`（浅色 pushed 页 应用分流）。

## 二、全屏转场时长

审核原文：8.5 英寸以下 ≥200ms；8.5~12 英寸 ≥250ms；12 英寸以上 ≥300ms。

### 根因

`applyMotionFloorByScreenSize()` 用 `densityPixels` 把物理像素折成 vp 再除 160 换算英寸。
`densityPixels` 会被系统"显示大小/字体缩放/折叠屏比例"改写，**不等于真实 DPI**：
12.6 寸平板会被算成 9.4 寸（甚至更小），档位落在 250ms，达不到 >12 英寸要求的 300ms。

### 修复

- 改用物理像素 + 真实 DPI：`inches = sqrt(widthPx² + heightPx²) / densityDPI`
  （`densityDPI` 拿不到时退回 `xDPI`，再兜底 vp/160 并打日志）。
- 三档下限 200/250/300 写入 `tb_motion_required_ms`；`TunBoxMotion.ms = max(260, 下限)`。
- 全部全屏转场统一取值：6 个路由页 `PageTransitionEnter/Exit` + 主页 3 个页签切换，
  无字面量时长（闸门 `verify-agc-ui-fixes.mjs` 逐文件断言）。

### 真机日志

```
EntryAbility: screen 1600x2560px @380dpi ≈ 7.94in → motion floor 200ms
```

（本机 8 寸平板 → 实际 260ms；>12 寸设备会算到 300ms 档。）
旧算法在同一台机器上也会输出 7.94in，但在 12.6 寸平板上输出 ~9.4in —— 错误就在这里。

## 三、闸门

`node scripts/verify-agc-ui-fixes.mjs --self-test`

- 22 条断言：状态栏取页面背景色 / 图标随主题 / 导航条同色 / 窗口底色同色；
  DPI 换算、三档边界、`tb_motion_required_ms`、每页转场都用 `TunBoxMotion.ms`。
- 3 条负对照全部被抓住：状态栏退回透明、DPI 退回 `densityPixels`、某页转场写死 160ms。
