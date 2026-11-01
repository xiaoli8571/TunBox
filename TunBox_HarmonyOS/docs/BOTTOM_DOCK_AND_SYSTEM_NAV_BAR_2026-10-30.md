# 底部 Dock × 系统导航条割裂修复（2026-10-30）

> 来源：用户真机截图（621×154 底部裁切）+ 像素逐点采样。
> 相关代码：`theme/SafeArea.ets`（新增）、`entryability/EntryAbility.ets`、
> `components/TopNavBar.ets`、`components/FloatingBottomBar.ets`、`theme/TunBoxTokens.ets`、
> `pages/MainPage.ets`、`pages/NodeEditPage.ets`、`pages/NodeSelectionPage.ets`、
> 以及 5 处 `dockClearance` 调用点。
> 闸门：`scripts/verify-bottom-dock-immersive.mjs`（31 断言 + 4 负对照）。

## 一、现象（用户原话）

1. 手机底部的系统导航条是一条**实色**带，和 App 的 Dock 之间「很强的割裂感」；
2. 内容往下滑动时被那条带**遮挡**；
3. Dock 也因此「位置太高」，要求「往下调一点，让导航栏和 dock 栏看起来融为一体」。

## 二、像素取证（这一步决定了改哪里）

对截图底部裁切逐点采样（列 5/60/150/300/450/560/615）：

| 位置 | 像素 | 说明 |
|---|---|---|
| 页面渐变终点（带外，右边缘） | (15,19,30) | = `bgGradientEnd` 深色 `#0F131D` |
| 那条带内部 | (11,14,22) | —— |
| 窗口底色 | (11,18,32) | `#0B1220`，**对不上** |

把带内值除以渐变终点：15×0.75=11.25、19×0.75=14.25、29×0.75=21.75
→ **(11,14,22)，三个通道全部吻合**。

结论：
- 页面渐变**已经**画进那条带了（`expandSafeArea` 生效），不是「页面没铺到」；
- 是**系统在导航条窗口上又压了一层 25% 的黑**；
- 这层遮罩 `navigationBarColor: '#00000000'` 关不掉 —— 0.7.5 早就把它设成透明了，仍然在。

顺带排除了 App 侧嫌疑：全仓库 grep 不到 `rgba(0,0,0,0.25)` / `#40000000` 这类遮罩；
Dock 本体宽度只有 86%，而那条带是**满宽**的（x=615 也在带内）。

## 三、根因

非沉浸式（默认）布局下，系统把底部那一条当成「它的地盘」，自己画底以保证手势条可见，
App 设什么色都被这层遮罩盖住。唯一开关是**窗口级沉浸式**：
`window.setWindowLayoutFullScreen(true)`。

## 四、改法

### 1. 窗口沉浸式

`EntryAbility.enableImmersiveLayout(win)`：`setWindowLayoutFullScreen(true)`，
失败只打日志不阻断启动（退回原来的非沉浸式行为）。
两条加载路径（正常 / 主题恢复失败）都调用它。

### 2. 代价必须补回来：`theme/SafeArea.ets`

沉浸式 = **布局不再自动避让**状态栏/导航条（窗口接口文档原文：
"immersive layout means that the layout does not avoid the status bar ... and
components may overlap with them"）。于是：

- 顶部：顶栏会钻到时钟底下 → `SafeArea.topPad()`；
- 底部：Dock 会贴到屏幕最底边 → `SafeArea.dockGap()`。

**不写死假设，实测自校准**：拿 MainPage 里「100% 高、没挂 `expandSafeArea`」的容器量高度，
和整屏 vp 比：

- 容器高度 ≈ 整屏 ⇒ 不避让（沉浸式真的生效）→ 顶栏补 `insetTop`，Dock 用 `margin = gap`；
- 容器高度 < 整屏 − 2vp ⇒ 仍在避让 → 顶栏不补（否则双重留白），Dock 用
  `margin = 0` + `translate.y = insetBottom − gap` **往下沉**。

两种设备最后落在**同一个视觉位置**：Dock 底边距屏幕底边 `gap`。
`gap = round(手势区 × 0.6)`，夹 8~22vp —— 取 60% 是为了让 Dock 底沿正好落在手势指示条上方一点，
既不悬空，也不让系统手势条压进 Dock 的圆角里。

避让区实测同时取 `TYPE_SYSTEM` 与 `TYPE_NAVIGATION_INDICATOR` 的 `bottomRect`（取大），
并订阅 `avoidAreaChange`（三键↔手势切换、转屏、折叠屏展开、悬浮导航开关都会重算）。

### 3. 顶部留白只加在一处

`TopNavBar` 统一加 `.margin({ top: SafeArea.topPad() })`（9 个调用点一次覆盖）；
两个自绘顶栏的页面（`NodeEditPage`、`NodeSelectionPage`）各自在内容列加
`.padding({ top: SafeArea.topPad() })`。

### 4. Dock 几何

`FloatingBottomBar`：删掉 `.expandSafeArea(BOTTOM)`，改成

```
.margin({ bottom: TunBoxGeometry.dockBottomMargin() })   // 沉浸式生效时 = gap
.translate({ y: TunBoxGeometry.dockSink() })             // 仍在避让时 = insetBottom − gap
```

### 5. 内容留白

`TunBoxGeometry.dockClearance` 由写死的 112 改成函数 `dockClearance()`
（= 栏高 64 + gap + 呼吸 40，且 `clamp ≥ 112`）。下限保留 112 是回归护栏：
2026-10-29 修过的「底框一半是阴影」就是内容进了 Dock 的 26vp 模糊半径导致的。
5 处调用点全部补上括号。

## 五、验收

- `node scripts/verify-arkts-compile.mjs` → 真机编译器 assembleHap 通过（无 ArkTS 错误）。
- `node scripts/verify-ui-resource-bindings.mjs` → 底栏三个图标编号一致。
- `node scripts/verify-agc-ui-fixes.mjs --self-test` → 29 断言 + 3 负对照全绿（系统栏透明未被回滚）。
- `node scripts/verify-bottom-dock-immersive.mjs --self-test` → 31 断言 + 4 负对照全绿。

## 六、真机验证（2026-10-30 22:12，MLR-AL00 / 1600×2560）

装机实测（debug 签名直装后冷启动到首页，截图逐像素）——**密度由 Dock 本体反推**：
Dock 面板在 y=2368…2520 共 152px，而 `dockHeight = 64vp` ⇒ **2.375 px/vp**。

| 项目 | 实测 | 判决 |
|---|---|---|
| 屏幕最底部一行（x=30/80/1520/1580 四个边角采样） | `(15,19,30)` = `#0F131D` 连续到最后一行，**没有任何台阶** | ✅ 那条 25% 遮罩消失 |
| Dock 底沿 | 距屏幕底边 40px = **16.8vp** | ✅ 已下沉（原来在安全区底边之上，≥ inset+0） |
| 手势指示条 | y=2534…2545（距底 15…26px ≈ 6…11vp），高 11px ≈ 4.6vp | 与 Dock 底沿留 **约 6vp** |
| 顶部 | 状态栏图标在 y=24…88（10…37vp），标题文字在 y=152…190（64…80vp） | ✅ 没有钻到时钟底下 |

顺带验证了参数链路：实测手势区 ≈ 28vp → `gap = round(28×0.6) = 17vp`，
与像素实测的 16.8vp 吻合 —— 说明 `getWindowAvoidArea` + 自校准这条路是通的
（也就是说本机**沉浸式生效、布局不再避让**，走的是 `margin = gap` 分支）。

**仍未验证**（真机在这一步之后掉线，`hdc list targets` 变 Offline）：

1. 滚动时内容从手势区底下穿过的手感（透明是对的，但**滚动条末端**要肉眼确认没被 Dock 压住）；
2. 屏下三键导航模式下 `TYPE_SYSTEM.bottomRect` 变大时 Dock 是否还落得对（`avoidAreaChange` 会重算，
   但没实测过）；
3. 浅色配色下的观感（取证都是深色主题）。

想再低一档就改 `SafeArea.publish()` 里的系数（0.6 → 0.4），或直接给 `tab_dock_gap` 设常量。

## 七、回退

三个开关级回退点，任一即可：

- `EntryAbility.enableImmersiveLayout` 里改成 `setWindowLayoutFullScreen(false)` → 完全回到 0.7.7 行为；
- `SafeArea.calibrate` 里把 `avoid` 强制 `true` → 顶栏不补白、Dock 用下沉路径；
- `TunBoxGeometry.dockClearance()` 直接 `return 112` → 内容留白回到旧值。

## 八、二修（2026-10-30 22:2x）：顶部同一类问题 + 「渐变模糊」

用户第二轮反馈三件事（都在顶部）：

1. 「顶部也是，搞成沉浸式的，距离顶部状态栏间隔也有点大」——截图圈出状态栏下沿到标题之间那条空白；
2. 「往上滑动的时候会被上面完全遮挡，能不能做成渐变模糊」；
3. 「感觉不够透明」——顶栏看起来还是一条板。

### 改法（三处，互相独立可回退）

| 位置 | 改动 | 为什么 |
|---|---|---|
| `SafeArea.topPad()` | 新增 `TOP_TRIM = 12`，让白从 `insetTop` 改成 `max(0, insetTop − 12)` | 顶栏行 56vp、标题行内竖居中 ⇒ 行内上下各留 ~14vp；整块补满 `insetTop` 会让状态栏下沿到标题空出 20vp |
| 所有滚动容器 | `.fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(TunBoxGeometry.scrollFadeEdge = 48) })` | 页签页是 `Column{顶栏;Scroll}`，内容滚到视口顶边是**硬切**（用户说的「完全遮挡」）。`fadingEdge` 是 ArkUI 原生边缘渐隐，进入 48vp 内线性淡出 |
| `TopNavBar` | 让白 `margin` → `padding`；加 `.backgroundEffect(radius 28)` + 三段渐变（顶 `0.22/0.30` → 中 `0.08/0.14` → 下缘 **全透明**） | 顶栏变成**浮层玻璃**：内容从它下面滚过去，透出模糊+染色，下缘渐变收口没有硬边。染色 alpha 第一版给到 0.62/0.72，实测整条比页面底色暗 6 级（用户「不够透明」），收到 0.22/0.30 后差 1–2 级 |
| `HomePage` / `StatsPage` / `SettingsPage` | 根容器 `Column` → `Stack(Alignment.Top)`，`TopNavBar` 移到 Scroll 之后（画在上层），滚动内容 `padding.top = TunBoxGeometry.headerReserve()` | 浮层顶栏必须**盖在**内容之上，内容也必须先让出它的高度；`headerReserve() = topPad() + navHeight` |

### 真机像素验收（MLR-AL00 / 1600×2560 / 2.375 px·vp⁻¹，深色主题）

| 项目 | 实测 | 判决 |
|---|---|---|
| 状态栏 inset / 自校准 | `insets top=43.8vp bottom=27.8vp`、`box=1077.9vp screen=1077.9vp → avoid=false` | 沉浸式生效，走 `topPad = insetTop − TOP_TRIM` 分支 |
| 状态栏下沿 → 标题上沿 | 104px(43.8vp) → 119px(50.1vp) = **6.3vp**（改造前 20.2vp） | ✅ 间距收掉了 |
| 顶栏浮层高度 | 玻璃下沿在 ~88vp = `topPad(31.8) + navHeight(56)` | ✅ 与令牌一致 |
| 顶栏最上沿颜色（深色） | `(10,17,33)` vs 页面底色 `(11,19,32)` → 差 1–2 级 | ✅ 基本透明（第一版是 `(5,11,27)`，暗 6 级 = 一条板） |
| 滚动后顶栏内部 | `(10,17,33)` → 底缘 `(16,24,43)`，正下方卡片 `(19,26,44)` | ✅ 背后内容按渐变强度透出来（0%→~80%） |

**仍未验证/待用户确认**：模糊强度与渐隐长度是否合适（`radius 28` / `scrollFadeEdge 48` 两个旋钮）；浅色主题下标题在亮内容上的可读性；推入式页面（规则/订阅等）目前只有 `fadingEdge`，顶栏仍是同色底（没有内容从下面过，观感与页签页不同但一致）。

版本：`0.7.8 (versionCode 550)`，`clean assembleHap` + 调试证书装机验证。
