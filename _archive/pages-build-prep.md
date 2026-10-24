# pages-build 准备笔记（task-4 前置只读勘察）

> 作者：pages-build（task-4 负责人）。状态：等待 task-2 / task-3 完成期间只读勘察产出。
> 本文件不是合同，合同以 `docs/tunbox-ui-contract.md`（ui-contract 产出）为唯一依据。
> 用途：task-4 开工后的施工图底稿 + 缺口对账清单。

## 1. Clash Party 现状地图（src/renderer/src）

### 1.1 页面（pages/，17 个）

| 文件 | 大小 | 职责 | 主要 HeroUI 组件 | 数据来源 |
| --- | --- | --- | --- | --- |
| `mihomo.tsx` | 62.7KB | 内核设置：版本/端口/外部控制/WebUI/LAN/auth/lgbm | Button, Input, Select, Switch, Tooltip, Modal, Chip, Spinner, Divider | `useAppConfig`, `useControledMihomoConfig`, `utils/ipc` |
| `proxies.tsx` | 39.3KB | 代理组 + 节点列表（虚拟滚动、拖拽排序、展开态持久化） | Avatar, Card, Chip, Dropdown, Switch, Spinner | `useGroups`(SWR), `utils/ipc`, `useControledMihomoConfig` |
| `network.tsx` | 33.5KB | 网络拓扑图 + 网卡/规则链 | 自绘 + HeroUI | `useAppConfig`, `utils/ipc` |
| `profiles.tsx` | 24.5KB | 订阅与节点：订阅卡列表 / 本地节点 / 插件 / Sub-Store | Tabs, Dropdown, Input, Checkbox, Chip, Divider, Tooltip | `useProfileConfig`, `usePluginConfig`, SWR(subStore) |
| `settings.tsx` | 2.4KB | 设置页容器（只做编排 + 顶栏链接） | Button | 无（子组件自理） |
| `dns.tsx` | 20.7KB | DNS 覆写配置 | HeroUI 表单组 | `useControledMihomoConfig` |
| `rules.tsx` | 9.5KB | 规则列表 | Card, Chip, Input | `useRules`(SWR) |
| `connections.tsx` | 19.0KB | 连接表 + 详情弹层 | Card, Chip, Dropdown | SWR |
| `traffic.tsx` | 10.3KB | 流量趋势与排行 | Card + 自绘图表 | `useTrafficLogger` |
| `tun.tsx` | 12.0KB | TUN 配置 | HeroUI 表单组 | `useControledMihomoConfig` |
| `sysproxy.tsx` | 8.6KB | 系统代理 + PAC | HeroUI 表单组 | `useAppConfig` |
| `sniffer.tsx` | 9.1KB | 域名嗅探 | HeroUI 表单组 | `useControledMihomoConfig` |
| `override.tsx` | 10.0KB | 覆写脚本（JS） | Card, Dropdown | `useOverrideConfig` |
| `substore.tsx` | 3.8KB | Sub-Store 页面 | 小组件 | SWR |
| `logs.tsx` | 5.8KB | 内核日志 | 虚拟列表 | SWR |
| `resources.tsx` | 1.3KB | 资源页容器（GeoData/SmartModel/Provider） | 无 | `useAppConfig` |
| `simple-module.tsx` | 0.5KB | 简单模式子模块路由壳 | 无 | `useParams` |

### 1.2 组件（components/，按目录）

- `base/`（task-2 范围，页面只消费不改）：`base-page`, `base-setting-card`, `base-setting-item`, `base-editor`, `base-confirm-modal`, `collapse-input`, `border-switch`, `toast`, `mihomo-icon`, `substore-icon`, `base-error-boundary`
- `settings/`：`general-config`(35.1KB)、`mihomo-config`(22.9KB)、`shortcut-config`、`sider-config`、`substore-config`、`webdav-config`、`local-backup-config`、`actions`、`css-editor-modal`、`tray-icon-crop-modal`、`webdav-restore-modal`
- `profiles/`：`profile-item`(10.9KB)、`edit-info-modal`(21.2KB)、`edit-rules-modal`(44.1KB)、`edit-tunnels-modal`(17.7KB)、`profile-card-content`、`edit-file-modal`、`qr-code-modal`
- `proxies/`：`proxy-item`、`group-editor-modal`、`group-members-editor`、`sortable-group`
- `connections/`：`connection-table`、`connection-detail-modal`、`connection-item`
- `traffic/`：`traffic-trend-chart`、`traffic-details-table`、`traffic-rankings`
- `rules/`：`rule-item`、`rule-editor-modal`
- `resources/`：`geo-data`、`proxy-provider`、`rule-provider`、`rule-provider-editor-modal`、`smart-model`、`viewer`
- `simple/`（简单模式节点/订阅编辑）：14 个文件
- `sider/`（**布局/导航类，非本任务范围**）：`sider-cards`、`conn-card`、`dns-card`、`mihomo-core-card`、`network-card`、`outbound-mode-switcher`、`override-card`、`profile-card`、`proxy-card`、`resource-card`、`rule-card`、`sniff-card`、`substore-card`、`sysproxy-switcher`、`tun-switcher`、`usage-card`、`log-card`、`sider-item`、`config-viewer`
- 其他：`logs/log-item`、`mihomo/interface-modal`、`network/network-topology`、`override/*`、`plugins/*`、`updater/*`

### 1.3 状态与 IPC 面

- hooks：`use-app-config`、`use-controled-mihomo-config`、`use-profile-config`、`use-plugin-config`、`use-override-config`、`use-groups`、`use-rules`、`use-traffic-logger`、`use-connection-apps`、`use-dns-override-notice`、`create-config-context`
- utils：`ipc.ts`(18.1KB，全部 `window.api` 调用面)、`validate`、`error-display`、`dataUsage`、`connection-icon`、`tour`、`sider`、`init`、`startup`、`legacy-traffic-db`、`image`、`hash`、`calc`、`debounce`、`dayjs`、`includes`、`plugin-file-open`、`env.d.ts`
- locales：`zh-CN`, `zh-TW`, `en-US`, `ru-RU`, `fa-IR`（i18n 走 i18next，入口 `src/renderer/src/i18n.ts`）

### 1.4 需保留的 Clash Party 独有页面（不得删除，按 TunBox 层级收纳）

`network`（拓扑）、`traffic`（趋势/详情）、`logs`、`override`（JS 覆写）、`sniffer`、`dns`、`tun`、`sysproxy`、`resources`（Geo/Provider/SmartModel）、`substore`、`simple-module`（简单模式）。

## 2. TunBox 排布速记（只读自 tunbox 源码，待与合同对账）

### 2.1 主页签（MainPage.ets）

3 页签：主页(0) / 订阅(1) / 设置(2)；底部悬浮栏 `FloatingBottomBar`：92% 宽 / 64 高 / 32 圆角 / 底边距 20，全透明填充 + `backdropBlur(24)` + 1px 描边 + 24 半径投影；选中项 = 椭圆胶囊（primaryLight 底 + primaryBorder 描边），图标 21px + 12px 文字同行；点击有 50ms 后 280ms 的扩散光晕。切页转场 260ms + 6% 位移（Curve.Friction）。

### 2.2 主页 `HomePage.ets`（64KB）

TopNavBar（TunBox + 备份/主题）→ 天体轨域启动按钮 `CelestialPowerOrb`（320/280/200，按钮内含当前节点名）→ 代理模式三段按钮（规则/全局/直连）→ 实时速率与流量卡 `RateChart`（含公网 IP）→ 错误条；另有连接卡预览（最多 5 条、2s 轮询）、诊断弹层 `DiagnosticsSheet`、备份/恢复弹窗（含 AES-256-GCM 密码弹窗）。2026-10-17 起「规则模式卡片」下架三项迁入设置页。

### 2.3 订阅 `SubscriptionPage.ets`（82KB）

TopNav（单列/双列切换 · 刷新全部 · 添加订阅）→ 全局概览卡 → 内核智能优选条目 → 折叠式订阅分组（展开显示该订阅节点并单选）；底部浮动胶囊新增入口；含扫码 `scanBarcode` / 文件导入。

### 2.4 设置 `SettingsPage.ets`（35KB）

分组设置项，改动即时落盘 + toast；`网络重连` / `故障切换` / `诊断自检` 三项**已按用户要求完全隐藏**（默认开启、无感）。

### 2.5 节点选择 `NodeSelectionPage.ets`（109KB）

顶栏（返回/标题/测全部）+ 订阅筛选 chips + 节点卡列表（旗帜/名称/延迟按钮/选中勾）。测速唯一入口 `LatencyEngine`：已连接复用隧道 controller，未连接由编排器 `ensureLatencyApi()` 提供无头内核；两者都不可用时退化为**明确标注**的离线粗略通道（OFFLINE，显示 `≈123ms`），绝不把通道故障写成节点超时。

### 2.6 规则 `RulesPage.ets`（30KB）

`RulesView`：内容列最大宽度受限；无头部注释，含 `rulesEnabled`、`CustomRuleSet`、`hyperAdRulesEnabled`（去广告默认关）等开关。

### 2.7 连接 `ConnectionsPage.ets`（11KB）

内核 `GET /connections`，2s 轮询；未连接/内核不可达给出**明确提示**（不假装列表为空）；单条点击关闭（带确认）+ 一键关闭全部；展示流量/规则链/出口节点/持续时间。

### 2.8 网站分流 `SiteRoutingPage.ets`（22KB）

按域名分配走代理/直连；添加弹窗要求「每行一个纯域名，无需 https://、不要路径/端口/通配符，规则含子域名」；筛选（搜索 / 只看已选 / 字母排序 / 全选 / 取消勾选）。

### 2.9 其他同层子页

- `AppRoutingPage.ets`（27KB）：按应用分流，含预置项与 `appRoutingRemovedPresets`（删除名单持久化，否则 rebuild 会加回来）
- `NodeEditPage.ets`（11KB）：手工节点编辑（name/server/port/password/...），移植自 Android 端 node_edit_screen
- `widgets/`：`NodeCard`、`SubscriptionCard`、`SurfaceCard`、`CountryFlagIcon`、`DiagnosticsSheet`

## 3. TunBox 有 / Clash Party 无（候选缺口清单，待与合同第 5 节对账）

| # | 缺口 | TunBox 落点 | Clash Party 现状 | 拟落点（task-4） |
| --- | --- | --- | --- | --- |
| G1 | 连接大开关（天体轨域 Orb，按钮内含当前节点名） | HomePage `CelestialPowerOrb` | 仅侧栏 `sider/tun-switcher`/`outbound-mode-switcher` 小开关 | 主页新建 Orb 区块（页面级组件） |
| G2 | 主页代理模式三段按钮（规则/全局/直连） | HomePage | 侧栏 `outbound-mode-switcher` | 主页内联三段按钮 |
| G3 | 实时速率与流量卡 + 公网 IP | HomePage `RateChart` | `traffic.tsx` 独立页有趋势，无主页卡、无公网 IP | 主页新建速率卡；公网 IP 需 IPC（受限） |
| G4 | 连接卡预览（最多 5 条，2s 轮询，点击进连接页） | HomePage | `connections.tsx` 全量页 | 主页新建预览卡 |
| G5 | 诊断/自检弹层（自动修复） | widgets `DiagnosticsSheet` | 无 | 主页诊断按钮 + 弹层 |
| G6 | 配置备份/恢复（含 AES-256-GCM 密码、明/密可选） | HomePage BackupDialog | 设置页 `webdav-config`/`local-backup-config`（功能不等价） | 主页顶栏备份入口 + 弹层 |
| G7 | 订阅「全局概览卡」+「内核智能优选」条目 | SubscriptionPage | `profiles.tsx` 无概览卡 | 订阅页顶部新建 |
| G8 | 订阅折叠分组内**单选节点** | SubscriptionPage | 节点选择在 `proxies.tsx`（组维度） | 订阅卡展开区承接 |
| G9 | 单列/双列排布切换（排布维度而非仅布局） | SubscriptionPage TopNav | 无 | 订阅页顶部切换（写 localStorage） |
| G10 | 节点选择页：订阅筛选 chips + 测全部 + 延迟按钮 | NodeSelectionPage | `proxies.tsx` 有组筛选/测速，但无「订阅维度 chips」 | 节点页/订阅展开区 |
| G11 | 测速「离线粗略通道」明确标注（`≈123ms`，不写成超时） | NodeSelectionPage | `proxies.tsx` 只有超时文案 | 测速状态文案 + 视觉 |
| G12 | 延迟配色阈值（绿/橙/红/超时） | TunBoxPing | `proxies.tsx` 自有一套 | 统一按合同阈值，走令牌 |
| G13 | 网站分流页（域名级 代理/直连） | SiteRoutingPage | 无对应页（只有 rules） | 需新建页/组件 + 路由（路由归 task-2，需 lead 协调） |
| G14 | 应用分流页（按应用） | AppRoutingPage | `use-connection-apps` 能识别应用，但无分流页 | 同上，需路由；Windows 侧应用路径不稳定 |
| G15 | 手工节点编辑页（TunBox NodeEditPage） | NodeEditPage | `components/simple/simple-node-modal` 等已有等价能力 | 复用现有，不新建页 |
| G16 | 订阅扫码导入（扫码） | SubscriptionPage | `profiles/qr-code-modal` 是**展示**二维码 | 不做（桌面无扫码硬件），列为未实现 |
| G17 | 「内核智能优选」smart 组入口 | SubscriptionPage | `resources.tsx` 有 `<SmartModel />`（core==='mihomo-smart' 时） | 订阅页挂智能优选入口，指向 resources |
| G18 | 设置页「无感化」：网络重连/故障切换/诊断自检默认开且隐藏 | SettingsPage | 无对应开关（Clash Party 无该逻辑） | 不实现（无后端语义），合同如要求则标注 |

## 4. 施工纪律备忘

- 写入范围：`pages/**`、`components/**`（排除 `base/**` 与布局/导航类如 `sider/**`）、`locales/**`。
- 颜色/圆角/间距/动效一律走 task-2 产出的 `src/renderer/src/theme/**` 令牌，禁止硬编码色值。
- 新增路由（G13/G14 若确认要实现）超出本任务写入范围 → 必须问 lead，不擅自改 `routes/**`、`App.tsx`。
- 质量门：`pnpm run typecheck` + `pnpm run lint:check`；AGENTS.md 还要求 `format:check`（提交前）。
- 合同第 4 节映射表与第 5 节缺口清单为最终对齐依据；本文件第 3 节为预先对账底稿。
