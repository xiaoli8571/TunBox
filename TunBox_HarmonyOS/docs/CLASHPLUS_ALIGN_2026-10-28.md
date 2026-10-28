# 按 ClashPlus 改造：订阅迁主页 + 数据页对齐（2026-10-28）

> 依据：对 `ClashPlus-1.2.7-14-arm64-v8a.apk` 的静态逆向（Dart AOT / Blutter，Dart 3.11.5）。
> 逆向报告与地址级证据在 `C:\Worker\_re_clashplus\report\`（`10-subscription.md` /
> `20-delay-and-node-switch.md` / `30-expand-animation.md` / `50-stats-page.md`）。
> 本文只记「Plus 是什么」→「本工程怎么落地」的映射与取舍。

## 1. 改动总览

| 位置 | 改前 | 改后 |
|---|---|---|
| 主页 `pages/HomePage.ets` | 只有天体按钮 / 模式 / 速率卡 / 连接卡 | 新增 **订阅区块** `components/SubscriptionSection`（连接卡下方） |
| 页签 1 `pages/MainPage.ets` | 订阅页 `SubscriptionPage` | **数据页 `pages/StatsPage.ets`** |
| 底栏 `components/FloatingBottomBar.ets` | 页签名「订阅」 | 「数据」（用户本轮已先改） |
| `pages/SubscriptionPage.ets` | 页签形态 | 退化为**订阅管理页**（`navTitle` / `showBack` 两个 @Prop） |
| 新增 `pages/SubscriptionManagePage.ets` | — | `@Entry` 包装，推入式打开订阅管理（加返回按钮） |
| 新增 `commons/services/TrafficStatsStore.ets` | — | 累计/按日流量 + 每月清零（对齐 Plus 口径） |
| 新增 `commons/services/ConnectivityProbe.ets` | — | 数据页连通性探测（TCP443 / HTTP / HTTPS） |
| `commons/models/PublicIpInfo.ets` + `PublicIpService` | 只有 IP/国家/城市/ISP | 增加 **ASN**、**时区**（Plus 出口 IP 卡的两行） |
| `commons/services/ClashApiService.ets` | — | 新增 `fetchMemoryInuse()`（`GET /memory`，对齐 Plus `getMemory`） |

## 2. 订阅展开动画：逐值对齐 Plus

Plus 的真身是 `_ProfileNodeOverlayState`（**不是** `NodeExpansionPanel`——后者里的
520ms/`Cubic(0.25,0.88,0.32,1)` 是死代码，逆向报告已证）。实现取值：

| 参数 | Plus 实测 | 本工程 |
|---|---|---|
| 展开时长 | 340 ms（`[pp+0x49230] int(0x53020)`） | `EXPAND_MS = 340` |
| 收起时长 | 300 ms（`[pp+0x4058] int(0x493e0)`） | `COLLAPSE_MS = 300` |
| 正向曲线 | `Cubic(0.645,0.045,0.355,1)`=easeInOutCubic（`[pp+0x49238]`） | `cubic-bezier(0.645, 0.045, 0.355, 1)` |
| 反向曲线 | `Cubic(0.215,0.61,0.355,1)`=easeOutCubic（`[pp+0x2c248]`） | `cubic-bezier(0.215, 0.61, 0.355, 1)` |
| 内容透明度 | `clamp(t/0.6, 0, 1)`（`[pp+0x4b60] double(0.6)`） | `contentOpacity()` |
| 整块透明度 | `clamp(0.65t+0.35, 0, 1)` | `shellOpacity()` |
| 高度揭示 | `ClipRect → SizedBox(h=maxH*t) → OverflowBox(fit:max, align:topCenter)` | 外层 `Column.height(内容高 × t).clip(true)` + 顶部对齐 |
| 展开高度上限 | 按可用空间夹取，超出内部滚动 | `PANEL_LIST_MAX_H = 360vp` + `List` 内部滚动 |

驱动方式：`@kit.ArkUI` 的 `Animator`（`onFrame` 逐帧回调），即 Plus 的
`AnimationController` + `CurvedAnimation` 等价物。ArkUI 的 `animateTo` 拿不到逐帧进度，
无法复刻 `t/0.6` 这类连续映射，所以必须用 `Animator`。

交互语义（同 Plus）：**点订阅卡头 = 先展开（同步）、再后台切 profile**。
`activateProfile()` 只做 `ProfileRepository.setCurrent` + `ensureProfileApplied`，
失败只打日志，绝不回滚动画。

## 3. 数据页内容对齐

Plus `views/stats/stats.dart` 的四段结构：

| Plus | 本工程 `pages/StatsPage.ets` |
|---|---|
| `_SpeedGraphCard`：下载/上传双曲线 + 峰值/平均 + 本次连接/累计总量 | `SpeedCard()` + 本地 `StatsRateChart`（双 `Polyline` + 面积 `Polygon`） |
| `_StatsGrid`：内存占用 / 运行时间（**只有这两张卡**，Plus 实证只 `Allocate_StatCardStub` 两次） | `GridCard()` + `StatTile()` ×2 |
| `_IpInfoCard`：国旗 + 国家/城市/ISP/ASN/时区，`https://ipwho.is`，15s 超时 | `IpCard()`（数据源改为本工程既有 `PublicIpService`，ip-api + ipify 兜底） |
| `_ConnectivitySection`：默认 `google.com`/`github.com`，TCP 直连 443 或 HTTP(S) 经本机代理 | `ConnectivityCard()` + `ConnectivityProbe` |

流量口径：

| Plus | 本工程 |
|---|---|
| `lifetime_traffic_up` / `lifetime_traffic_down`（prefs） | 同名键，独立 preferences 文件 `tunbox_traffic_stats` |
| `daily_traffic_by_ymd_v1`（`{ "YYYY-MM-DD": {u,d} }`） | 同名键、同结构 |
| `trafficResetDay` 1–28，每月该日 00:00（本地时区）清零 | `TrafficStatsStore.setResetDay()`；判定用「今天 ≥ 清零日」以便整月关机后补清 |
| 数值卡 1000ms 轮询 | `TICK_MS = 1000` |
| 内存 = 内核 `getMemory`（FFI） | 鸿蒙侧无该 FFI，改走内核 REST `GET /memory` 的 `inuse` |

## 4. 有意的偏离（及原因）

1. **订阅管理没有并入主页**：Plus 的增删改在设置侧的 profiles 页；本工程保留独立
   「订阅管理」推入页（复用既有 2333 行实现，避免两套管理代码分叉）。主页只做
   「看订阅 + 展开选节点」。
2. **无 overlay 浮层**：Plus 用 `OverlayEntry` 把面板浮在卡片之上；ArkUI 没有等价物，
   这里把展开体放在卡片内部、靠高度剪裁实现同样的「高度揭示」观感，且不会遮挡
   后续卡片。
3. **出口 IP 数据源**：Plus 用 `ipwho.is`；本工程沿用既有 `PublicIpService`
   （ip-api HTTP + ipify 兜底，已在真机长期可用），只补 ASN/时区两个字段。
4. **连通性探测默认 HTTPS**：与 Plus `ConnectivityTestMethod` 默认值一致；TCP 探测
   直连 443 不经代理（Plus 说明原文「TCP 直连目标主机 443 端口」）。

## 5. 验收清单

- `hvigorw --mode module -p module=entry@default -p product=default clean assembleHap` → BUILD SUCCESSFUL
- `node scripts/verify-ui-resource-bindings.mjs` → 通过（未新增 media 资源，仅复用既有图标）
- 真机冒烟：主页看到订阅卡 → 点卡头展开（340ms 高度揭示）→ 点节点切换 →
  切到「数据」页看曲线/内存/运行时间/出口 IP/连通性 → 左滑删连通性目标 → 添加域名

## 6. 2026-10-28 当轮用户定稿的最终形态（覆盖前文若干细节）

- **主页只留**：启动按钮（缩小一圈，出口 IP 以弧形文字排在按钮底部，未连接不显示）、
  模式三段（规则/全局/直连）、订阅区块。速率卡与连接卡已删除；连接管理入口同步删除。
- **订阅卡片**：图标 + 名称 + 「使用中」徽标 + 更新时间·节点数；右上三个动作
  **测速 → 刷新 → 设置**（40×40 热区）；`↑/↓/总量 + 进度条 + 到期文案`；
  **当前订阅卡片外围描蓝**（使用中徽标保留）。
- **订阅展开 = 全屏覆盖**（`bindContentCover`）：顶部直接是**订阅卡片本身当固定表头**
  （点它或底部按钮都返回），其下**只有订阅自带分组 chips**（PROXY / AUTO / …，
  与排序方式同一行右侧），再下是节点列表；节点行 = 名称+协议小字 / 延迟 / 最右单选圈，
  选中行浅绿底 + 实心圆点，点节点即切换**并自动退出**。
- **订阅增删改全部收进主页**：标题右侧只有一个「+」；弹窗四模式
  **二维码 / URL / 文件 / 转换**（白底实色、水平垂直居中）；
  URL 模式内置「允许明文 HTTP 订阅」开关（设置页那一项已删除），
  **只接受 Clash 订阅链接，单节点分享链接一律拒绝**。
- **设置页**：删除「连接管理」「测速地址」「GeoIP/数据资产」「订阅转换」；
  剩「网络与数据」= IPv6 双栈 / DNS 覆写 / Smart 选点模型（+ 更新）；
  订阅转换并入「添加订阅 → 转换」。
- **底部 dock**：去掉渐变渐隐底，栏体与页面背景融为一体。
