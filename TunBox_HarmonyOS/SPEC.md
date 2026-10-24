# 任务：将 TunBox 完整移植到 HarmonyOS（鸿蒙 NEXT），一次性交付全部代码

> 本文档是完整的开发任务规格书。执行者必须一次性完成全部开发动作（生成全部代码、构建脚本、配置、文档），不许分阶段、不许留 TODO、不许说"下一步再做"、不许遗漏任何页面或功能。

---

## 0. 角色与目标

你是资深鸿蒙与跨平台开发工程师。你的任务是把开源项目 TunBox（Mihomo / Clash Meta 客户端，MIT 许可，GitHub `Elegying/TunBox`，当前版本 4.0.28+4028）**1:1 完整移植到 HarmonyOS NEXT**，包括全部 UI、全部功能、VPN 内核集成。

- 原项目代码位于：`C:\Users\Administrator\Downloads\zcode-worker\TunBox-upstream`（必须先通读该目录，以实际代码为移植基准）
- 新建鸿蒙工程放在：`C:\Users\Administrator\Downloads\zcode-worker\TunBox-HM\TunBox_HarmonyOS\`（只新建此子目录，不要改动同级其他目录）
- 许可与合规：TunBox 自有代码为 MIT；捆绑的 Mihomo 内核为 GPL-3.0，需在鸿蒙工程内保留 `THIRD_PARTY_NOTICES.md` 并注明来源 tag / commit / SHA-256。无遥测、无数据上传。

---

## 1. 原项目技术事实（移植对照基准，必须逐项 1:1 对齐）

### 1.1 技术栈

| 项    | 值                                                                                                                                                                                              |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 框架   | Flutter monorepo，Flutter 锁定 3.44.1（`.fvmrc`），Dart SDK ≥3.6.0                                                                                                                                   |
| 状态管理 | provider ^6.1.0                                                                                                                                                                                |
| 其他依赖 | yaml ^3.1.0（Clash 配置解析）、http ^1.0.0（订阅拉取与 Clash API）、crypto ^3.0.7（资产完整性校验）、shared_preferences ^2.5.5、flutter_secure_storage ^10.3.1（Keystore AES-GCM）、path_provider ^2.1.6、uuid ≥3.0.6 <5.0.0 |
| 代码分层 | 平台壳（`TunBox_Android/lib/`，36 个 Dart 文件）+ 平台无关共享包（`packages/tunbox_shared/lib/`，约 120 个 Dart 文件）                                                                                                |

### 1.2 VPN 内核（关键）

- 内核为 **Mihomo（Clash Meta）**，以 Go 共享库 `libgojni.so` 形式嵌入（build mode `c-shared`，tags `with_gvisor,cmfa`，仅 arm64）。
- 内核来源：**`vernesong/mihomo`（分支 `Alpha`，commit `462455136157a760937c666bba71afe33b1a809e`）** —— 该 commit 合入了上游 mihomo `v1.19.33` 稳定版代码，并保留 Smart 策略组层；Go 模块 `github.com/metacubex/mihomo`，源码树在仓库内 `mihomo-build/mihomo-smart-4624551…/`（含 TunBox 集成层与 gvisor 补丁）。已弃用停更的 `lux5am/mihomo-smart`（其最后提交停留在 2026-07-12）。upstream Android 版仍用 `zeyugao/mihomo@7031b75…`（见 `TunBox_Android/assets/libgojni-source.txt`），鸿蒙端已按需求替换为该内核，桥接 ABI 保持不变。
- 鸿蒙端**必须自行交叉编译**出 ohos-arm64 版本（见 §3.2），不得直接复用 Android .so。
- 运行时为 **IPv4-only**：DNS 不解析 AAAA，TUN 层拦截并丢弃 IPv6 流量（Android/Windows 均如此，鸿蒙必须一致）。
- 应用与内核通过 Clash RESTful API（外部控制器 + `apiSecret`）通信：改选节点、测延迟、读流量统计。

### 1.3 Android 原生层（功能对照清单，鸿蒙需一一对应实现）

`TunBox_Android/android/.../kotlin/com/tunbox/android/` 下约 50 个 Kotlin 文件，核心职责：

- `TunBoxVpnService.kt`：VpnService 主体（TUN 建立、地址/路由/DNS 配置）
- `VpnRouteInstaller.kt` / `PublicIpv4Routes.kt`：路由安装（IPv4 全量 + 明细策略）
- `VpnIpv6Config.kt`：IPv6 拦截
- `VpnAppExclusionInstaller.kt` / `DomesticAppBypassPolicy.kt`：**应用分流**（排除应用列表 + 国内应用绕过）
- `VpnProtectMonitor.kt`：protect() 自保护监控
- `MihomoApiWaiter.kt` / `MihomoApiHealthProbe.kt` / `MihomoProxySelection.kt`：Clash API 等待、健康探测、代理选择
- `CoreLivenessMonitor.kt` / `CoreRecoveryCoordinator.kt` / `CoreRecoveryPolicy.kt` / `CoreStopDecision.kt` / `VpnServiceRestartStore.kt` / `DisconnectRecoveryCoordinator.kt`：**内核存活监控与自动恢复**
- `NativeConnectionSession.kt` / `NativeConnectionSnapshot(Store).kt` / `NativeSessionCommitter.kt`：连接会话与快照（重启后恢复状态）
- `NativeApiSecretResolver.kt`：apiSecret 加密存储解析
- `VpnNotificationSupport.kt` / `NotificationGenerationGate.kt` / `NotificationUpdatePolicy.kt`：常驻通知（连接状态、流量速率）
- `VpnTrafficTracker.kt`：上下行流量统计
- `VpnTileService.kt`：快捷磁贴开关
- `AutoConnectRequestRegistry.kt` / `VpnServiceStartPolicy.kt` / `StartGenerationGate.kt` / `VpnStartResultRegistry.kt`：开机/请求自动连接与启动门控
- `AndroidRuntimeGuard.kt` / `VpnRuntimeHealth.kt` / `UnderlyingNetworkMonitor.kt`：运行时守护与底层网络变化监测
- `ExternalUrlPolicy.kt` / `UpdateApkVerifier.kt`：外链策略、更新包校验
- `bridge/Bridge.kt`：Flutter ↔ Go 库的 JNI 桥

### 1.4 功能清单（必须全部实现）

1. **订阅管理**：添加/编辑/删除订阅（URL、名称、自定义请求头）；按 UA 协商拉取（顺序：`TunBox/4.0.28` → `Clash Verge/…` → `v2rayN/…` → `Shadowrocket/…`，原样移植 `subscription_fetch_policy.dart`）；解析 SSR 链接 / SS URI / Clash YAML / Base64 订阅 / 命名规则（6 个 parser 分部逻辑 1:1 移植）；YAML 合并、源缓存、撤销（undo）记录、刷新结果分类展示
2. **节点选择**：按订阅分组展示节点（`tunbox_node_selection_page`），节点国家识别与旗帜图标（`node_country_policy` + `country_flag_icon`）、显示名规整、延迟测试（URLTest）并着色显示、偏好节点持久化与事务化提交
3. **连接控制**：一键连接/断开、连接状态机（`connection_orchestrator`）、连接意图跟踪与转换队列、内核崩溃自动恢复、重启后自动恢复上次连接
4. **主页信息**：连接状态卡片、实时上下行速率/累计流量、当前出口公网 IP 与归属地（`public_ip_info_service`）、运行时长
5. **设置**：暗色/亮色主题跟随、开机自启、应用分流（排除列表选择器）、强制代理站点列表（`force_proxy_site_policy`）、DNS/端口等高级项（以原 `app_settings.dart` 字段为准，全部保留）
6. **诊断**：诊断面板（`app_diagnostics_view`，运行日志、内核状态、API 健康）、日志脱敏（`log_redactor`）、有界文件日志（`bounded_file_logger`）、崩溃报告采集与提示（`crash_reporter`）
7. **更新检查**：版本更新页脚与更新流程（`update_service*`，鸿蒙端适配为应用市场/HAP 包自更新提示）
8. **本地化**：中文（默认）+ 英文，全部文案与原项目 zh/en 文案一致
9. **快捷开关**：鸿蒙服务卡片 / 快捷方式实现与 Android VpnTileService 等价的"一键连接/断开"

### 1.5 UI 规格（必须 1:1 复刻）

页面结构（两页 + 辅助页，导航与 Android 版一致）：

1. **主页 `home_screen.dart`**：顶部应用栏（透明、居中标题）、核心连接按钮（状态色：连接中动画 / 已连接绿 `0xFF18A957` / 未连接）、节点当前选择卡、延迟显示、公网 IP 卡、连接操作区（`home_connection_actions_part`）、各类对话框（`home_dialogs_part`）
2. **订阅页 `subscription_screen.dart`**：订阅列表卡（`tunbox_subscription_view`）、添加订阅卡（`tunbox_subscription_add_card`）、订阅编辑对话框、网络错误对话框、更新页脚
3. **节点编辑页 `node_edit_screen.dart`**：手工添加/编辑节点表单
4. **诊断抽屉**：底部弹出 diagnostics sheet

视觉规格（照抄 `theme/app_theme.dart`，值不得改动）：

- 品牌色：主色 `#2F6BFF`，主亮 `#5B8CFF`，主暗 `#1E49D8`，强调 `#14B8A6`
- 状态色：成功 `#18A957` / 成功亮 `#34D399`，警告 `#F59E0B`，错误 `#EF4444`
- 暗色主题（默认）：背景 `#08090B`，表面 `#101114`，卡片 `#15171B`，卡片悬停 `#1C2026`，边框 `#2A2E36` / 亮边框 `#3A414D`，主文字 `#F4F6F8`，次文字 `#A4ACB8`，提示文字 `#717B8A`
- 亮色主题：背景 `#F4F6F8`，表面/卡片 `#FFFFFF`，边框 `#D8DEE8`，主文字 `#111827`，次文字 `#5F6B7A`，提示 `#8A94A6`
- Material 3、卡片圆角 16、输入框圆角 12、AppBar 无阴影居中标题 17/w600/-0.2 字距、卡片描边 1px
- **毛玻璃效果**：`glass_container` + `shaders/liquid_lens.frag` 液态透镜着色器——鸿蒙端用 ArkUI `backgroundEffect`/`foregroundEffect` + 自定义渲染等价实现，视觉上对齐
- 响应式：`responsive.dart` 的断点逻辑照搬（手机竖屏单列布局为准）

---

## 2. 鸿蒙端架构决策（按此执行）

### 2.1 总体方案

采用 **纯原生 HarmonyOS NEXT 工程（ArkTS + ArkUI，API 26+，Stage 模型）**，不使用 Flutter 鸿蒙移植版。理由：UI 规模小（3 个页面），ArkUI 可 1:1 视觉复刻且长期维护性好；Flutter OHOS fork 版本滞后、依赖生态不齐。

代码分层（映射原项目两层结构）：

```
TunBox_HarmonyOS/
├── AppScope/                          # 应用级配置
├── entry/src/main/
│   ├── module.json5                   # 权限、ExtensionAbility 声明
│   ├── ets/
│   │   ├── entryability/EntryAbility.ets
│   │   ├── entryformability/          # 服务卡片（对应 VpnTileService）
│   │   ├── pages/
│   │   │   ├── HomePage.ets           # ← home_screen.dart
│   │   │   ├── SubscriptionPage.ets   # ← subscription_screen.dart
│   │   │   └── NodeEditPage.ets       # ← node_edit_screen.dart
│   │   ├── vpnability/VpnExtensionAbility.ets   # ← TunBoxVpnService.kt
│   │   ├── theme/AppTheme.ets         # ← app_theme.dart（色值逐项照抄）
│   │   ├── widgets/                   # ← widgets/ 与 tunbox_shared/widgets/（GlassContainer、节点卡、订阅卡、对话框、国家旗帜等，逐个组件对应）
│   │   └── utils/responsive.ets
│   ├── resources/                     # base/zh_CN/en_US 全部字符串与图标（从原项目 res/ 迁移图标资源）
│   └── rawfile/                       # geoip.metadb 等内核资产
├── commons/                           # 共享逻辑库（对应 packages/tunbox_shared，见 2.3）
└── core/                              # Mihomo 内核 NAPI 封装（C/C++，见 3.2）
```

### 2.2 状态管理与持久化

- 用 ArkUI 状态管理（`@State`/`@Observed`/`@Track` + AppStorage）等价实现 provider 的 ChangeNotifier 模式；控制器文件与原项目 `controllers/` 一一对应（`home_node_controller`、`home_latency_controller`、`subscription_screen_controller`、`home_exit_country_controller`、`update_availability_controller`）
- 持久化：`@ohos.data.preferences`（对应 shared_preferences）；apiSecret 用 `@ohos.security.asset`（对应 Keystore AES-GCM）或本地 `@ohos.security.cryptoFramework` AES-GCM 加密后落盘
- YAML 解析：引入或自移植 yaml 解析（保持与 `clash_config_generator.dart` 输出一致）

### 2.3 逻辑移植规则

- `packages/tunbox_shared` 中**所有** services / policies / utils / models 必须逐文件移植为 ArkTS（或 .ets 模块），保持同名同职责：订阅 6 个 parser、`clash_config_generator`、`clash_service_*` 7 个 support、`subscription_fetch_policy`（UA 协商）、`node_country_policy`、`log_redactor`、`connection_transition_queue`、`core_recovery_policy`、`bounded_file_logger` 等一个不落
- 单元测试：为订阅解析器、配置生成器、UA 协商、国家策略、脱敏等纯逻辑模块补 ArkTS 单测（对应原项目 Kotlin/Dart 测试的存在感）
- 原文件中的注释与中文文案原样保留

### 2.4 VPN 与内核集成（核心难点，按以下方案实现）

1. **TUN**：使用 `@ohos.net.vpnExtension`（VpnExtensionAbility，API 12+）建立 TUN：配置 IPv4 地址/路由/DNS，`addAddress`/`addRoute`；在 `module.json5` 声明 extensionAbilities(type: vpn) 与 `ohos.permission.VPN` 相关权限（含申请 ACL 说明）；实现 IPv6 流量丢弃策略
2. **内核库**：用 OHOS NDK（clang/musl）交叉编译 Go：`CGO_ENABLED=1 GOOS=linux GOARCH=arm64 CC=$OHOS_NDK/.../aarch64-unknown-linux-ohos-clang go build -buildmode=c-shared -tags "with_gvisor,cmfa"`（如链接器报不兼容，按需补 ohos 补丁或在脚本中说明处理方式），产出 `libgojni.so`（arm64）+ `libtunbox_bridge.so` NAPI 桥；构建脚本保存为 `scripts/build-ohos-core.sh`，并在 `core/` 内提供 C NAPI 封装（启动/停止内核、注入 TUN fd、读取内核日志），对应 Android 的 `bridge.go` + `Bridge.kt` 职责
3. **数据面**：TUN fd 通过 NAPI 传入内核（c-shared 模式下内核经 VpnExtension 的 fd 读写流量）；Clash 外部控制器绑定 127.0.0.1 随机端口，apiSecret 随机生成并加密存储；`protect`（防回环）通过内核 socket 绑定底层网络接口实现
4. **守护与恢复**：NAPI 侧定时探测内核存活 + Clash API 健康检查（对应 `CoreLivenessMonitor`/`MihomoApiHealthProbe`），异常时按 `core_recovery_policy` 重启内核或整条 VPN；连接快照持久化实现重启自恢复
5. **通知与卡片**：前台长时任务（`backgroundTaskManager` continuous task + 通知）显示连接状态与速率；FormKit 服务卡片提供一键连接/断开
6. **流量统计**：从 Clash API `connections` 接口聚合上下行速率与累计值（与 `VpnTrafficTracker` 行为一致）

---

## 3. 交付物清单（全部完成才算结束）

1. 完整可编译的 DevEco Studio 工程（`build-profile.json5`、`hvigorfile.ts`、`module.json5`、`oh-package.json5` 齐全），target API 12+，仅 arm64
2. `core/` NAPI 桥源码 + `scripts/build-ohos-core.sh` 内核构建脚本（recipe 与原 `build-android-core.sh` 对齐，注明源 commit/SHA-256 记录方式）
3. `commons/` 全部共享逻辑 ArkTS 模块（对照 §2.3 清单，文件级一一对应）
4. 三个页面 + 全部 widgets + 主题 + 液态透镜等价效果 + zh/en 资源
5. VpnExtensionAbility 全套（TUN、路由、应用分流、IPv6 拦截、守护恢复、通知、卡片、自启）
6. `THIRD_PARTY_NOTICES.md`（GPL-3.0 合规）与 `README_HarmonyOS.md`（构建步骤、签名说明、权限清单、已知差异）
7. 权限申请说明：`ohos.permission.INTERNET`、VPN 相关权限、通知、长时任务等，在 README 中列出手工申请项
8. 纯逻辑模块单元测试

## 4. 验收标准（自检后再交付）

- [ ] 色值、圆角、字号、页面上每个元素与原项目 `app_theme.dart` / `home_screen.dart` / `subscription_screen.dart` 一致（逐项对照过）
- [ ] 订阅：SSR/SS/YAML/Base64/命名 5 类输入解析结果与原 Dart parser 行为一致；UA 协商顺序一致
- [ ] `clash_config_generator` 生成的 YAML 与原实现字段一致（IPv4-only、DNS 无 AAAA、TUN 配置、规则）
- [ ] 连接全流程可用：授权 VPN → 启动内核 → Clash API 就绪 → 选节点 → 流量走 TUN → 通知/速率/公网 IP 正常
- [ ] 内核崩溃/网络切换场景能自动恢复；App 重启后能恢复上次连接
- [ ] zh/en 文案齐全；暗/亮主题切换正常；服务卡片可一键连接
- [ ] 无 TODO / 占位实现 / 被注释掉的代码块；无遥测与数据外传
- [ ] `README_HarmonyOS.md` 能让一个新人在 DevEco Studio 中从零构建出 HAP

## 5. 输出方式

- 在本次回复中直接给出全部文件内容（按目录树组织，每个文件一个代码块并标注完整路径）；文件过多时也要全部输出，不得省略"重复/相似"部分
- 最后附：目录树总览 + 与原项目的文件映射表（原文件 → 新文件）+ 自检结果（对照 §4 逐项打勾）
