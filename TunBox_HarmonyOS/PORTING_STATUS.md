# TunBox HarmonyOS — 移植进度与剩余工作清单

> 本文件是移植工作的进度账本（2026-09-17 更新，见文末「架构与性能改造」一节）。
> **当前状态：HAP 已可完整编译（BUILD SUCCESSFUL，含原生 NAPI）；网络监听、恢复编排与
> 权威状态已下沉到 VpnExtensionAbility，规则/节点/模式支持不重建隧道的热更新，
> 全链路 IPv6 双栈 + DNS 覆写改为设置页开关（默认都开，§4），3s 定周期心跳已改为事件驱动 +
> 低频存活租约。**
> 继续开发前必须通读本文件和 `SPEC.md`（规格书 §1.4 功能 / §1.5 UI / §4 验收）。

## 构建方法（本机已验证）

```powershell
cd C:\Users\Administrator\Downloads\zcode-worker\TunBox-HM\TunBox_HarmonyOS
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
$env:Path = 'C:\Program Files\Huawei\DevEco Studio\jbr\bin;' + $env:Path
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module -p module=entry@default -p product=default assembleHap --no-daemon
# 产物: entry\build\default\outputs\default\entry-default-unsigned.hap
# 已复制: C:\Users\Administrator\Downloads\zcode-worker\TunBox_HarmonyOS.hap (未签名, ~1.6MB)
```

- SDK：本机 DevEco Studio SDK **API 26**（`compatibleSdkVersion: "26.0.0"`，注意新版本号格式不带 `(N)` 括号后缀）
- 签名：HAP 当前未签名，装真机需 AGC 证书 + Profile（手动步骤，见 README_HarmonyOS.md）
- 打包依赖 java：必须把 `DevEco Studio\jbr\bin` 加入 PATH，否则 PackageHap 报 `spawn java ENOENT`

## Mihomo 内核编译（ohos/arm64）

- 方案：**不用 gomobile**（upstream 用 gomobile bind 产出 bionic libc 的 android .so，无法在 OHOS musl 上加载）。
  自写 c-shared 包装层 `mihomo-build/mihomo-<commit>/cshared_main.go`（package main，导出
  TunBoxInit/TunBoxStart/TunBoxStop/TunBoxIsRunning/TunBoxVersion/TunBoxLastError），
  复制 upstream `TunBox_Android/native/bridge/bridge.go`（package bridge）到 mihomo 源码 `bridge/` 子目录，
  `GOOS=linux GOARCH=arm64 CGO_ENABLED=1 CC=<OHOS NDK clang --target=aarch64-linux-ohos --sysroot=...>` 编译。
- 本机构建脚本：`C:\Users\Administrator\Downloads\zcode-worker\build_core.ps1`（产物应放 `entry\libs\arm64-v8a\libgojni.so`）
- protect 机制：cshared_main.go 内置 auto-approve 守护（读 pipe fd → 自动 SetProtectResult(true)）。
  **API21/26 核对点**：真机上若出现流量回环，需把该 fd 真正绑定到底层物理网络。
- 注意：本机 8GB 内存，编译 mihomo 峰值内存大，需关闭 DevEco/浏览器等大户，`-p 1` 降低并行度。
- ABI 对齐：`tunbox_core_napi.cpp` 的 dlsym 符号已与 cshared_main.go 一致（含 TunBoxLastError）。
  NAPI startCore 直接收 configPath + tunFd，由 Go 侧读文件。

## 已完成（P0/P1 + UI 1:1 + P2/P3 全部收官，2026-09-06 最终版）

> **2026-09-06 P3 收官**：
> - **YAML 合并引擎** `commons/services/YamlMerger.ets`：移植 subscription_yaml_merger.dart 核心语义
>   （proxies 分节提取与缩进规整、条目切分、内容指纹跨订阅去重、previousYaml 同内容节点保留名称、
>   uniqueProxyName "(n)" 后缀、节点数/单条/字段/输出全部限额）。已接入订阅刷新：Clash YAML 订阅
>   走合并链路（上一轮 YAML 按 subId 缓存于 preferences，512KB 封顶）。已声明简化：dialer-proxy
>   依赖解析未实现（ss/ssr 订阅不含该依赖）；解析面向 flow-map 与块列表两种主流写法。
> - **强制代理站点对话框**：节点选择页顶栏「站点」入口，逐行域名输入 → settings.forceProxySites →
>   下次连接的配置生成生效（DOMAIN-SUFFIX,site,PROXY）。
> - **hypium 单测** `entry/src/ohosTest/ets/test/LogicTest.ets`（12 个用例）：SSR/SS/SIP002/Base64 订阅
>   解析、Clash YAML 提取、配置生成器（IPv6 双栈/DNS 覆写/mode/external-controller/GEOIP/MATCH/强制站点）、
>   国家识别、日志脱敏、节点名规整、延迟配色阈值、YAML 合并（去重+名称保留）、URL 校验与脱敏。
>   DevEco 中右键 ohosTest → Run 'LogicTest' 即可执行（本地单测引擎）。
> - **THIRD_PARTY_NOTICES**：补齐 libgojni.so OHOS 构建来源（方式/产物/SHA-256/包装层 ABI/与
>   upstream gomobile 方案差异/对应源码获取方式），GPL-3.0 合规闭环。

> **2026-09-06 P2 收官**：
> - **apiSecret 加密存储**：AssetStoreKit（`asset.add/query`，ALIAS 检索，失败降级偏好并记日志）
> - **连接快照 + 启动自动恢复**：连接成功写入 `{desiredConnected, nodeName}`，断开清除；
>   HomePage 启动时若快照为已连接意图 → 自动重连上次节点（对应 NativeConnectionSnapshot 恢复语义）
> - **内核自动恢复**：存活监控检测内核死亡 → 自动重连（最多 2 次退避），失败则转手动并提示
> - **代理模式**：规则/全局（AppSettings.proxyMode → 配置生成 mode 字段 + 节点选择页 chips 运行时 PATCH /configs）
> - **常驻通知速率**：TunBoxNotifier（isOngoing，每秒随流量轮询刷新，节流 900ms，授权未开静默降级）
> - **订阅删除撤销条**：删除后 5 秒内可撤销（undoRemove 已有事务快照）
> - **更新检查**：UpdateChecker 查 GitHub latest release，关于对话框"检查更新"按钮接线
> - 注：errorManager 崩溃钩子在本 SDK（API26）的 ErrorObserver 类型不可公开导入，已移除（诊断面板日志仍可用）

> **2026-09-06 UI 大版本更新**：读 upstream 共享 widgets 源码后发现安卓版真实 UI 使用 `TunBoxUiTokens`
> （深海军蓝渐变背景 + 紫色主色 #8A84FF，`app_theme.dart` 是旧版兼容色已被弃用）。已按 upstream 源码
> **逐组件 1:1 重写**全部页面：
> - `theme/UiTokens.ets`：TunBoxUiTokens 全量色值/尺寸 + 延迟配色阈值（<180 绿/<350 黄/≥350 或超时红）+ 节点名规整
> - `widgets/SurfaceCard.ets`：TunBoxSurfaceCard 等价（surface 88% + 白20%描边 + 黑22%投影 blur28/offsetY14）
> - `pages/HomePage.ets`：渐变背景+双辉光、头部（关于/TunBox/使用教程）、状态胶囊、166 圆形电源按钮
>   （连接色逻辑+光晕+连接中 LoadingProgress）、当前节点卡（图标盒/旗帜/名称/延迟/chevron）、
>   公网 IPv4 行、浮动底部导航（主页/订阅+版本页脚）、关于/教程自定义对话框
> - `pages/NodeSelectionPage.ets`（新增）：订阅筛选 chips + 节点卡（旗帜/名称/延迟按钮/选中勾）+ 测全部/单测
> - `pages/SubscriptionPage.ets`：添加卡（➕标题+输入框+primaryBlue按钮）、我的订阅+计数徽标+全部刷新、
>   刷新结果条、订阅卡（渐变图标盒/脱敏URL/✎编辑/🗑删除/启用点/相对时间）、空态、删除确认与编辑对话框
> - `pages/NodeEditPage.ets`：新令牌风格表单
> - 批量/单节点延迟测试（LatencyController + ClashApiService.testLatency）
> - 订阅直链节点导入（singleNodeImported 分支）与 updateSubscription 编辑持久化

| 鸿蒙文件 | 对应 upstream 源 | 状态 |
|---|---|---|
| 工程配置全套（app/build-profile/oh-package/hvigor-config/module.json5，权限含 MANAGE_VPN） | — | ✅ 已按 SDK 26 校正，hvigor 校验通过 |
| `ets/theme/AppTheme.ets` | `lib/theme/app_theme.dart` | ✅ 色值逐项照抄 |
| `ets/commons/models/ProxyNode.ets`（SSR/SS 编解码，util.Base64Helper） | proxy_node.dart + ssr/uri parser | ✅ ArkTS 严格模式合规 |
| `ets/commons/models/Subscription.ets` / `AppSettings.ets` / `PublicIpInfo.ets` | 对应 models | ✅ |
| `ets/commons/services/SubscriptionParser.ets` | subscription_parser*.dart | ✅ |
| `ets/commons/services/SubscriptionFetchPolicy.ets`（UA 链，url.URL 校验） | subscription_fetch_policy.dart | ✅ |
| `ets/commons/services/ClashConfigGenerator.ets`（IPv6/DNS 覆写/规则） | clash_config_generator.dart | ✅ |
| `ets/commons/services/ClashApiService.ets`（waitReady/selectNode/testLatency/traffic） | clash_service_* | ✅ |
| `ets/commons/services/SettingsService.ets` / `SubscriptionService.ets`（含撤销 + ManualNodeStore） | 对应 services | ✅ |
| `ets/commons/services/PublicIpService.ets`（含国家策略/旗帜） | public_ip_info_service + node_country_policy | ✅ |
| `ets/commons/services/ConnectionOrchestrator.ets`（写配置→startVpnExtensionAbility→等 API→选节点→监控） | connection_orchestrator 等 | ✅ 真实 API 链路 |
| `ets/core/CoreBridge.ets` + `cpp/tunbox_core_napi.cpp` + `cpp/types/` d.ts | native_bridge + Bridge.kt | ✅ 编译通过，import native from 'libtunbox_core_napi.so' |
| `ets/vpnability/VpnExtensionAbility.ets`（createVpnConnection→create→fd→内核；TASK_KEEPING 长时任务） | TunBoxVpnService.kt | ✅ 真实 vpnExtension API |
| `ets/pages/HomePage.ets` / `SubscriptionPage.ets` / `NodeEditPage.ets` | 三个页面 | ✅ 编译通过 |
| `ets/widgets/`（GlassContainer@BuilderParam/NodeCard/SubscriptionCard/CountryFlagIcon/DiagnosticsSheet） | widgets | ✅ |
| `ets/widget/ToggleCard.ets` 服务卡片 + form_config.json | VpnTileService | ✅ |
| `resources/`（base/zh_CN/en_US 字符串、图标、main_pages、form_config） | res | ✅ |

## 剩余工作（按此顺序继续，一次性完成）

### P1.5 — 内核链路收尾（最高优先）

1. ~~确认/完成 libgojni.so 编译~~ **✅ 已完成**。**内核已从 zeyugao/mihomo@7031b75 换为
   lux5am/mihomo-smart（Alpha @ 8d4c8c7）**，产物 `entry\libs\arm64-v8a\libgojni.so`（46.9MB，ELF64 AArch64，
   导出符号与旧内核逐一比对一致，`libgojni.h` 字节级不变）。后续改 Go 代码后用
   `scripts\build-ohos-core.ps1` 重编（源码在 `..\mihomo-build\mihomo-smart-8d4c8c7…\`，脚本会自动选中该目录；
   GOPROXY 必须走 goproxy.cn，链接期约需 4GB+ 提交内存）。
   内核选型、补丁清单与验证记录见 `docs/KERNEL_UPGRADE_2026-10-23.md`（含 2026-09 首轮换核前史）。
2. **真机冒烟**：**不要在 module.json5 声明 ohos.permission.MANAGE_VPN**（受限 ACL 权限，声明后安装报
   "权限申请失败，请按ACL签名指导申请受限权限"；已于 2026-09-06 移除，参照 NekoBox4Harmony 已验证做法：
   HarmonyOS 6.x 上 type:"vpn" 的 VpnExtensionAbility 无需该权限，DevEco 自动签名即可安装，
   运行时由系统 VPN 授权弹框管控）。流程：签名 → 安装 → 订阅导入 → 连接 → 验证 Clash API 9090 可达、TUN 流量、断开恢复。
3. **签名交付**：调试用 DevEco 自动签名即可（工程已无受限权限）；对外发布需 AGC 证书/Profile。

### P2 — 功能补全（对照 SPEC §1.4）

4. 完整 YAML 解析/合并（subscription_yaml_merger.dart、bounded_yaml.dart）
5. 批量测延迟 + 结果缓存（home_latency_controller.dart、private_node_latency_policy.dart）
6. apiSecret 加密存储（@ohos.security.asset 或 cryptoFramework AES-GCM，当前明文）
7. 连接快照持久化与重启恢复（NativeConnectionSnapshot/Store/Committer）
8. 开机自启（CommonEventSubscriber 监听开机事件 → 触发连接）
9. 应用分流：按 UID 分流在 OHOS VpnConfig 的能力以真机为准；不支持则转内核规则层方案
10. 设置页 SettingsPage.ets（主题/自启/排除应用/强制代理站点/测延迟 URL）+ main_pages.json 登记
11. 常驻通知速率更新（NotificationUpdatePolicy）
12. 订阅删除 5s 撤销 UI（undoRemove 已实现）
13. 更新检查（update_checker/update_service）
14. 崩溃报告（errorManager.on('error') → 本地日志 + 提示）
15. 启动编排（startup/* 任务图）
16. 内核恢复策略完整移植（core_recovery_policy.dart：重启内核→重建 TUN→重选节点→退避）

### P3 — 质量与合规

17. hypium 单测：SubscriptionParser / ClashConfigGenerator / SubscriptionFetchPolicy / NodeCountryPolicy / LogRedactor
18. THIRD_PARTY_NOTICES.md 补 ohos 构建来源（含 libgojni.sha256）
19. 对照 SPEC §1.5 色值逐项复核 UI；§4 验收清单逐项打勾

## 已知骨架简化（必须移除/替换）

- `VpnExtensionAbility` 的 protect 由 Go 侧 auto-approve（见上），真机需验证回环
- `SettingsService.apiSecret` 明文存储
- HomePage 节点抽屉未按订阅分组（对应 tunbox_node_selection_subscription_filter）
- HomePage 诊断抽屉传入 diag: null（固定显示未运行），需接入 orchestrator.diagnostics()
- 服务卡片状态文本未联动 formProvider.updateForm

## 架构与性能改造（2026-09-17，对齐《mihomo VPN 架构与性能优化建议》）

按优化建议完成的一轮结构性改造，八项全部落地并已通过编译与离线自动验证。

### 1. 网络监听与恢复编排下沉 Extension（控制面/数据面解耦）

`VpnExtensionAbility` 在隧道存续期间成为**唯一权威**，UI 进程被系统回收不影响 VPN 数据面：

- `onCreate` 建隧道前先 `startNetworkAuthority()` 订阅网络事件（`NetworkStateWatcher`）。
- `startCoreMonitor()` 每 10s 在 Extension 进程内直接 `coreBridge.isCoreAlive()` 探测内核。
- `scheduleCoreRecovery()` / `recoverCore()`：内核死亡后**就地热重启内核**（保持 TUN 不拆），
  指数退避、单航班门控、上限 `MAX_CORE_RECOVERY_ATTEMPTS`。
- `scheduleTunnelRebuild()` / `rebuildTunnel()`：热恢复耗尽才升级为 TUN 重建，上限
  `MAX_TUNNEL_REBUILDS`，再耗尽转 `leak-blocked`（保持阻断不放行，绝不泄漏）。
- 决策逻辑抽到零依赖纯模块 `commons/services/VpnRecoveryPolicy.ets`，Extension 运行时与
  离线用例共用同一真值源。

### 2. 扩大安全热更新，最小化 VPN/TUN/Core 重建

`ClashApiService` 新增 `putConfigs()` / `reloadFromPath()`（`PUT /configs?force=true`），
`ConnectionOrchestrator` 新增三条不重建隧道的生效路径，失败才回退完整重连：

| 变更类型 | 路径 | 是否重建 TUN |
| --- | --- | --- |
| 代理模式（规则/全局） | `applyProxyMode()` → `PUT /configs {mode}` | 否 |
| 规则 / 强制站点 | `applyRulesChanged()` → 重写 YAML + `reloadFromPath` | 否 |
| 切换节点 | `switchNodeHot()` → `PUT /proxies` | 否 |
| 免代理 / 走代理应用（包名级） | `restartIfConnected()`（VpnConfig 只能在建隧道时下发） | 是 |

页面接线：HomePage / RulesPage / NodeSelectionPage 已改走上述入口，并按
`hot` / `reconnect` / `none` 三态给出准确提示。

### 3. Extension 主导的可靠状态同步

- Extension 写 `vpn_status.json`（`VpnRuntimeStatus`：phase/mtu/netType/coreAlive/
  recoveryAttempts/rebuilds/seq/ts/detail），**事件驱动**、内容去重。
- UI 侧 `TunnelAuthority.parseExtensionStatus()` + `deriveUiPhase()` 纯函数解析并归一
  （`running→connected`、`recovering`/`leak-blocked` 原样、租约过期→`stale`），
  `ConnectionOrchestrator.extensionStatus()` 供冷启动/回收后还原真实状态。
- 断开时 `clearStartError()` 一并清除状态文件，防止读到上一会话的陈旧 `running`。

### 4. IPv6 双栈（2026-10-20 由「统一 IPv4-only」改为设置页开关，默认开）

背景：旧策略在 4 层硬关 IPv6（YAML `ipv6: false` + `dns.ipv6: false`、运行时 `/configs`
`"ipv6": false`、Extension `isIPv6Accepted: false` + 无 `::/0`、`ipv6Active=false` + 诊断恒 `skip`），
却从未真正拦住 v6 —— 真机实测隧道在线时 `ping6 2001:4860:4860::8888` 仍直连成功、`vpn-tun`
上 `::/0` 为 0 条（只挂在 wlan0），即 **v6 一直从物理网卡绕过代理**；同时 `dns.ipv6: false`
让隧道 DNS 对 AAAA 一律回 `ancount=0`，v6-only 站点必然打不开。

现状（2026-10-27 起）：设置页「网络」有**两个开关** —— `IPv6 双栈`（默认开）与
`DNS 接管`（默认开）。后者 2026-10-21 曾按产品定案删除（DNS 恒接管），2026-10-27 用户要求恢复；
恢复时按「YAML 是唯一真源」实现：生成器写 `dns.enable` + `tun.dns-hijack`，扩展
`readTunFlagsFromConfig` 读**同一份 YAML 的 dns.enable 行**决定是否下发
`VpnConfig.dnsAddresses`（关 = 不下发，系统沿用物理网络 DNS），不存在第二个可漂移状态位。

| UI 项 | 设置字段 | 落点 |
|---|---|---|
| IPv6 双栈 | `ipv6Enabled` | YAML 顶层 `ipv6:` + `dns.ipv6:`；Extension 据此装 v6 地址 + `::/0` + `isIPv6Accepted` |
| DNS 接管 | `dnsOverrideEnabled` | YAML `dns.enable` / `tun.dns-hijack:`；Extension 读同一行决定 `VpnConfig.dnsAddresses`（关 = 不下发）。关掉时也不吃订阅原文的 `dns.enable: true`（`ProfileConfigMerger.merge(..., allowProfileDns=false)`） |

`fake-ip-range6` **永不产出**，且 2026-10-21 起整个 fake-ip 退场：`enhanced-mode: redir-host`
（`fake-ip-range` / `fake-ip-filter` / `store-fake-ip` 全部删除）。原因见 §5 与 `docs/latency-redesign.md` §十二：
`withFakeIP` 只在 fake-ip 模式挂载、`fakePool6 == nil` 时 AAAA 恒回空，而平台不装任何 v6 路由
⇒ 「fake-ip + 无 range6」v6-only 站点必然打不开，「fake-ip + 有 range6」假 v6 必然无路可达。
`redir-host` 下 AAAA 由 `withResolver` 返回真实地址（只受 `dns.ipv6` 控制），v6-only 站点可用
（v6 流量直连物理网卡 —— 平台不装 v6 路由这一事实未变）。

Extension 读**同一份 YAML** 决定 TUN 的 v6 地址（`fdfe:dcba:9876::1/126`）、`::/0` 与
`isIPv6Accepted` —— 不新增 want 参数，避免 TUN 与内核两处不一致；`ipv6Active` 仅作诊断展示
（真实 AAAA 探针：AAAA 拿不到 = 真故障，不再有「已知限制 skip」）。
另删除从未生效的伪键 `disable-ipv6: true`（非 mihomo 顶层键，非 strict unmarshal 静默忽略）。
`inet6-address` 仍不声明：v6 地址经 `VpnConfig.addresses` 注入已有 fd 的 TUN。

真机验收（2026-10-20 21:52–22:20，华为真机 / 隧道在线；**当时还是 fake-ip + 双开关**，留作对照）：
- `vpn config: dual-stack, dnsOverride=true, routes=2`；关/开两个开关后各自重连，状态位随之变化
  （`ipv4-only` / `dnsOverride=false`），开关 → YAML → Extension 闭环成立。
- 隧道 DNS（`127.0.0.1:1053`）对 `ipv6.google.com` 的 A 返回 fake-ip `198.18.1.206`，
  对 AAAA 返回 `ancount=0`（fake-ip 无 v6 池）—— 这正是本次改 redir-host 的直接动因。
- **v6 不进隧道（平台限制，非配置问题）**：`/proc/net/ipv6_route` 里 `vpn-tun` 有 7 条 v6 路由，
  全部是地址派生（`/126`、`fe80::/64`、`/128`、`ff00::/8`），**没有 `::/0`**；v4 默认路由
  （`/proc/net/route` mask `FCFFFFFF`）正常存在。⇒ v6 出站走物理网卡直连。

待真机复验（2026-10-21 改动后）：
- `enhanced-mode` 为 `redir-host` 时 A 应答是真实地址（不再是 `198.18.x`），`ipv6.google.com`
  的 AAAA 应返回真实 v6 地址；
- `getDnsServers()` 恒返回 `172.19.0.2`（开关已不存在，只有这一种形态）；
- 探针 IPv6 项在双栈开、网络有 v6 时为 pass；网络无 v6 时为 fail（给出关闭双栈的建议）。

### 5. DNS 分流 / fallback / 缓存 与 链路参数

`dns.nameserver-policy` 分流 + `fallback` DoT（`1.1.1.1:853` / `8.8.8.8:853#DIRECT`）+
`cache-algorithm: arc` / `disable-cache: false` / `strategy: prefer_ipv4` + `enhanced-mode: redir-host`
（2026-10-21 起；fake-ip 已退场，`fake-ip-filter` 随之删除）；
`tcp-concurrent` / `unified-delay` / `keep-alive-idle` / `keep-alive-interval` / `udp-timeout` /
`find-process-mode: off` / `log-level: warning` / `profile.store-*`。
`strict-route` 明确不启用（gvisor 栈无 iptables，OHOS 上不可用）。

### 6. 按承载动态 MTU

`mtuForNetType()`：蜂窝 1360、其余 1400；网络切换导致 MTU 变化时在重建预算内重建 TUN，
并由 `ensureConfigMtu()` 把新 MTU 同步回内核 YAML，避免两侧不一致。

### 7. 移除 3s 定周期心跳 I/O

删除 `startHeartbeat()` / `HEARTBEAT_INTERVAL_MS`；改为「事件驱动写状态文件」+
「10s 内核监控顺带刷新一次存活租约时间戳」（`touchLivenessLease()`）。
UI 的 15s 陈旧窗口判定仍然成立，I/O 从每 3s 降至每 10s 且相位变化即时可见。

### 8. 验证

- `node scripts/verify-vpn-architecture.mjs`：**125 条断言全绿**。可执行部分直接加载
  `VpnRecoveryPolicy.ets` / `TunnelAuthority.ets` 真源码（Node 24 type-stripping），仿真
  后台/锁屏/UI 进程回收、网络切换、内核崩溃、弱网退避、长时间运行、不可恢复收敛；
  另有对配置生成器/Extension/编排器的源码级不变量断言（已明确标注为 SOURCE 断言）。
- `node scripts/verify-logic-pure.mjs` 228 全绿；`verify-latency-cache.mjs` 全绿。
- `entry/src/ohosTest/ets/test/VpnArchTest.ets`：11 个 hypium 用例覆盖同一批纯逻辑，
  已注册进 `List.test.ets`。
- 顺带修复了 ohosTest 模块**从未编译成功**的历史问题（该模块在引入前即已损坏）：
  `OpenHarmonyTestRunner` 按 API 26 契约重写（`TestRunner` 是 interface、无 `run()`），
  `TestAbility` 补上真正的 `Hypium.hypiumTest()` 启动链路（旧代码调用了不存在的
  `delegator.sendState()` 且从未执行用例），`LogicTest.ets` 的 17 处相对路径深度写错
  （多两层 `../`）、`rankNodes` 漏 import、3 处接口用对象字面量实现、
  `assertSmallerOrEqual` 拼错，均已修正。现在 `entry@ohosTest` 也 BUILD SUCCESSFUL。
- 需真机 + 签名包复核的项：真实锁屏/后台保留、Wi-Fi↔蜂窝切换、Core 崩溃自愈、
  弱网吞吐与断流、长时间运行内存与 fd 稳定性。

### 构建（含 ohosTest）

```powershell
# 项目路径含中文会让 hvigor 报 Invalid project path，需镜像到纯 ASCII 目录再构建
robocopy '<本目录>' 'C:\Users\xiaoli\Downloads\Agent-WorkerSpaces\TunBox-HarmonyOS-build' `
  /MIR /XD .git entry\build entry\.cxx .hvigor node_modules oh_modules
# ohosTest 需要 hypium：首次在该目录执行 ohpm install --all
& 'C:\Program Files\Huawei\DevEco Studio\tools\ohpm\bin\ohpm.bat' install --all
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
$env:Path = 'C:\Program Files\Huawei\DevEco Studio\jbr\bin;' + $env:Path
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module -p module=entry@default  -p product=default assembleHap --no-daemon
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module -p module=entry@ohosTest -p product=default assembleHap --no-daemon
# 产物: entry\build\default\outputs\default\entry-default-unsigned.hap
```

> 注意：`robocopy /MIR` 会删掉目标目录里源目录没有的东西，务必把 `oh_modules` 加入
> `/XD`，否则每次同步都要重装 hypium 依赖。

## 应用分流方案二测试版（2026-09-17，独立分支，尚未合并）

- [x] 当前工作代码快照（包含原未提交改动），独立 trial 分支开发；原工作目录未修改。
- [x] AppRoutingPage：三模式、两份名单保留、搜索、已选筛选/置顶、名称排序、批量增删、手动备注、复制导出、草稿退出确认、仅保存/保存并应用。
- [x] 节点页网络规则合并应用分流入口；设置页接线及补足遗留字符串资源。
- [x] 显式模式/冲突确认迁移、256上限拒绝而非截断、空include禁止、单名单JSON传输、运行与重建校验。
- [x] 配置损坏不回退all；重连前验证策略，失败提示与无连接区分。
- [x] 应用分流71项（真实纯逻辑/SettingsService mock + 明确标注的源码断言）、架构126项、纯逻辑228项、延迟缓存3项通过。
- [x] entry@default 与 entry@ohosTest assembleHap 均 BUILD SUCCESSFUL；按用户选择交付未签名HAP。
- [ ] 真机UI、真实包名分流、后台/重连、Profile适配、签名安装与hypium运行由用户验收，未声称已通过。
- 限制：SDK未提供全机应用枚举；目录仅保留原工程微信/抖音条目，其他应用手动添加，全部明确标记安装状态未确认；字形不是实际应用图标。
- 安全边界：本次拒绝错误策略退回all，不等于系统级断网保护。既有TUN销毁/重建失败时不能保证kill-switch，本次不重构该机制。
- 快照补充：原gitignore的 *credential* 意外排除了 CredentialStore.ets 源码，已纳入快照补充提交；未复制任何签名密钥到代码归档。

## 主页规则卡片与网站分流测试版（2026-09-17 第二轮，同一分支 0f32925）

- [x] 主页新增「规则」「网络规则」两张主题卡片；左上角旧规则按钮与旧规则弹窗移除；节点页规则入口与相关弹窗死代码移除。
- [x] 网络规则页路由到 强制代理网站 / 强制直连网站 / 应用分流 三个入口；SiteRoutingPage 采用与应用分流一致的列表、勾选批量、搜索排序、导入导出、草稿保存；两份网站名单同时生效，冲突需移除一侧。
- [x] 网站规则保存走既有 applyRulesChanged 热更新（失败回退重连）；选择仅保存则下次连接或规则重载生效；保存前重新读取设置并只覆盖两份网站名单，减少并发覆盖。
- [x] HomePage / NodeSelectionPage 自定义 pageTransition 移除，与应用分流一致的系统默认 push/pop。
- [x] clean 后 entry@default 与 entry@ohosTest 均 BUILD SUCCESSFUL（仅编译；页面运行与动画手感未做真机验证）。
- [x] 回归：应用分流71项、网站分流56项（含6项既有AppSettings对损坏旧值的非阻断AUDIT，未扩scope）、架构127项、纯逻辑228项、延迟缓存3项全绿；verify-vpn-architecture 过时页面断言已按新导航同步迁移。
- [x] 交付未签名 HAP：TunBox-Rules-HomeCards-unsigned.hap（20,231,983 字节，SHA256 1D5A0F3839702512EC44AA555A057F3F4C80C9765691A0F84CF6C982E436B38A）。
- [ ] 真机验收：主页卡片布局、站点列表操作、全局模式下网站规则提示、进入节点页/网络规则页的过渡效果。
- 已知限制：强制代理/直连是两份同时生效的名单（域名级，直连优先），与应用分流的互斥模式不同；绕过 VPN 的应用不受网站规则影响。AppSettings 历史上会静默丢弃损坏旧数据（非数组/非字符串），本轮不改该行为，仅 AUDIT 记录。

## 第三轮：主页 2×2 卡片与规则弹窗合并（2026-09-17，提交 0d89b0f）

- [x] 规则入口合并进主页「网络规则」4 选项弹窗（规则/强制代理/强制直连/应用分流），NetworkRulesPage 删除；主页 2×2 四等大卡片（节点/数据/代理模式/网络规则）。
- [x] 代理模式菜单更名「智能」；黑底系统菜单（showActionMenu 无背景色参数）改为主题化 CustomDialog。
- [x] 公网 IP 胶囊移至启动按钮正下方，内容自适应宽度，长 IPv6 BREAK_ALL 换行。
- [x] 双模块构建成功；回归：站点56/架构127/应用71/逻辑228/延迟3 全绿，断言迁移至弹窗结构。
- [x] 交付 TunBox-HomeCards-v3-unsigned.hap（最新 SHA256 56AD19DD…C61038F；四卡随后按反馈从146固定高改为与旧版网络规则卡一致的内容自适应高度，提交 f73f3e4）。
- [ ] 真机验收：弹窗主题色（深浅色）、2×2 布局、IPv6 胶囊换行、四入口路由。

## 第四轮：卡片启动 VPN 热恢复修复（2026-09-17，提交 914f35b）

- [x] VpnExtensionAbility.recoverCore：stopCore 后重挂载原平台 TUN fd（platformTunFd 借用，绝不回传原生模板 fd）→ initProtect()（原生 stop 会关闭 protect 管道，必须重建）→ startCore；每个 await 后校验代际/连接/fd，清理路径同步失效 lifecycleGeneration。
- [x] CoreBridge：attachTun 仅成功才缓存 fd；startCore 记录在途 promise，stopCore 等待其完成再停，杜绝断开后异步 worker 复活内核。
- [x] 失败路径回滚（停核、停监视器、leak-blocked 状态）且不拆平台 TUN（Kill Switch 保留）；重试调度移到 recoveryRunning 复位之后（原 catch 内调度会被门控吞掉）；成功不再重写一次性 START_OK 握手文件。
- [x] 新增 tools/verify-hot-recovery.mjs（Node 24 stripTypeScriptTypes 实源执行 + mock native）8/8 通过：成功恢复 fd/顺序、attach/protect/start 三类失败回滚不虚报 running、四类 await 期间清理不复活内核。
- [x] 全量回归：应用 71 / 站点 56 / 架构 127 / 逻辑 228 / 延迟 3 / 热恢复 8 全绿；ohosTest 与 assembleApp 构建成功；主线证书签名并 verify-app 通过（APP+HAP，见 SIGNED-APP-DELIVERY.md）。
- [ ] 真机安装受阻：设备 192.168.3.146 现装 debug 签名，release 证书不能覆盖（9568322）；用户选择暂不安装。恢复路径的设备级验证（内核崩溃→热恢复→流量不中断）待安装后进行。
- 已知遗留：rebuildTunnel 路径 stopCore 后同样缺 initProtect 与代际守卫（下一轮）；UI 进程恢复编排与扩展恢复可能竞争（评审已记录，暂不动）。

## 第五轮：卡片启动秒断根因修复——会话守护者（2026-09-18，提交 2715f35）

- [x] 真机取证（hdc 复现两次，时间线一致）：Form 宿主回收 → `:vpn` 在 0.3 秒内被连带回收（exit 0）；扩展进程申请连续任务必然 401（只支持 UIAbility 上下文）；卡片"已连接"为陈旧展示。
- [x] 修复：卡片 toggle 从 message 改为 router → QuickToggleAbility；该能力连接成功后注册 dataTransfer 连续任务成为会话守护者（module.json5 backgroundModes），15s 低频轮询跨进程权威租约（阈值 2），会话终结即注销任务+刷卡片+自毁；注册被拒则写 guard-denied 并退回旧行为。
- [x] VpnExtensionAbility 移除 401 死代码与"Android 前台服务"误导注释；QuickToggle 寿命守护放宽到 60s 并在守护接管时撤销。
- [x] 新增 VpnGuardianPolicy 纯策略 + tools/verify-card-guard.mjs（EXEC 策略 + SOURCE 结构，8 项含构建 profile 中 backgroundModes 落地检查）。
- [x] 七套件全绿（71/56/127/228/3/热恢复8/守护8）；default/ohosTest/assembleApp 全部 BUILD SUCCESSFUL；主线证书签名 v2（见 SIGNED-APP-DELIVERY.md 的哈希与验收清单）。
- [ ] 真机安装仍需用户 DevEco Run（debug 通道）或卸载重装（-k 保数据）；安装后按清单验证守护存活/断开释放/通知关闭降级。
- 残留观察：NETMANAGER 对旧安装件报 trustedApplications 非数组；新代码只在 include/exclude 发送字符串数组，若新包仍报需回传日志。

## 合并入主线与 5.5.1 发布（2026-09-18）

- [x] 第二~五轮全部改动（27 文件：应用分流 v2、站点分流、主页 2×2 + 网络规则弹窗、热恢复修复、会话守护 + 自动退桌面）已从试验副本逐文件哈希校验后合入主线；主线在合并前先以 `9596543` 提交原未提交工作作安全基线，可整体回退。
- [x] 版本号统一 5.5.1（AppScope：50501/5.5.1）；主线 clean 后 default/ohosTest/assembleApp 三构建 BUILD SUCCESSFUL；七套件回归全绿（回归需在构建之后跑，卡片守护断言会校验构建 profile）。
- [x] 新主线脚本 `sign-release-package.ps1`（版本号自动命名，产物在 `TunBox-HarmonyOS\dist\`）：TunBox_HarmonyOS-5.5.1-release-signed.app + TunBox-5.5.1-release-signed.hap，主线证书内外层 verify-app 通过。
- [x] 试验目录 TunBox-AppRouting-20260917（快照/bundle/试验仓库/旧包）已按用户指示删除；全部历史可从本仓库两个提交（9596543 基线 + 本次功能合并）与标签 v5.5.1 复现。本文各轮中引用的 trial 路径自本条起失效。
- [ ] 真机 5.5.1 验收（守护存活/退桌面/断开释放/通知降级），沿用第五轮清单。


## 2026-10-23：0.6.0 审查修复与重新安装

- 修复订阅校验/别名/Base64、配置新鲜度、内核目录启动、组选点、测速收尾与未开始却报完成；native stopCore 异步化。
- 62 套 strict 回归通过，新专项最终 15 项、真实订阅保真 16 项、前台会话 24 项、热恢复 8 项通过；release APP/HAP 与设备签名 HAP 构建成功。
- 最终 0.6.0 / 525 已重新安装到用户设备；此次干净安装首测由用户继续验收。细节见 docs/REVIEW_FIXES_2026-10-23_0.6.0.md。

## 2026-10-23：0.6.0 / 527 规则默认值、测速提示与保活复查

- 规则引擎默认关闭；修复自定义 GEOIP 缺库时漏过启动保护。移除两处页面的组级失败分类、超时/过载数量提示。
- 核对 PR #5（d50845f）：音频保活和 30 秒后台任务自检仍在。修复恢复后漏接进度心跳、迟到旧任务事件误撤销新守护、普通取消后重复等待。
- 保活生产源码回归 26/26、前台会话 24/24、卡片守护 8/8 通过；规则和测速定向回归通过。release APP/HAP 与设备兼容签名 HAP 均构建成功。
- 527 安装包已生成，设备未连接，尚未推送安装；未测锁屏长时存活与耗电。详见 docs/KEEPALIVE_REVIEW_2026-10-23_0.6.0.md。

## 2026-10-23：0.6.0 / 528 启动依赖复查

- Geo 数据铺盘改为结构检查、失败可重试、缓存删除可重建、完整临时文件原子替换，避免进程标记和只看大小掩盖坏缓存。
- 新增真实生产链路测试 43 项（含 64 份真实内核配置校验与 4 次内核实际启动），全部通过；旧安装器同组回归 6 项失败。规则默认关闭不变。
- 528 已构建签名，设备未连接，尚未安装。范围与证据见 docs/STARTUP_RECHECK_2026-10-23_0.6.0.md。

## 2026-10-23：0.6.0 / 529–531 第一批 P0 整改、图标事故与发布签名

- 第一批 P0（启动/停止/热加载串行化、最终配置校验、代理模式 PATCH、最近可用快照回退、保活迟到事件隔离）见 docs/REMEDIATION_BATCH1_2026-10-23_0.6.0.md。
- 530 暴露出增量编译资源编号错位（电源按钮与底栏三个图标串位）；531 用真正的清理构建修复，新增 scripts/verify-ui-resource-bindings.mjs 构建后门禁（debug+release 双模式），并在 AGENTS.md 固化“打包必须清理构建、构建后跑该门禁”。
- 全量回归 65 个脚本：PASS 64 / FAIL 1（仅缺私有真实订阅夹具）/ SKIP 0，真失败 0；strict 退出码仍为 1，不能称为全门禁通过。
- 已产出 0.6.0/531 三件套：未签名 HAP、签名 HAP、签名 APP；hap-sign-tool 验签成功，三者 modules.abc 一致（a26b8f54…）。
- 531 debug 候选已覆盖安装并在真机确认图标恢复；设备随后被用户使用，531 上的启动/模式切换/断开逐步取证未完成。
## 2026-10-24：0.6.0 / 531 真机逐步验收（release 编译模式）

- 设备 MLR-AL00 / OpenHarmony-7.0.0.105 安装 release 编译 + 设备调试签名的同版本包；其 modules.abc 与 dist 三件套一致（a26b8f54…），即真机运行与发布包同一份编译产物。
- 图标恢复在 release 编译包上再次目视确认（电源 ⏻、底栏九宫格/列表/齿轮）；4 个订阅数据在覆盖安装后保留。
- 启动连接 1535ms（prep 39/launch 1162/ready 1453/pinned 1535），TUN 建立、startCore ok、VPN 图标出现。
- 模式切换 规则→全局→直连→规则 全部生效：日志 hot-updated，直连时公网出口由代理 IP 变为本地 IP，切回规则恢复，连接未中断。
- 主动断开约 2.0s 完成，VPN 扩展进程退出，UI/流量/时长/VPN 图标全部复位。
- 未连接状态测速：headless test core 就绪，7/7 measured、timeout=0、failed=0，页面显示 58–265ms，无失败分类/超时数量横幅。
- 仍未完成：8 小时锁屏存活、耗电对照、音频保活、网络切换矩阵。证据见本地审计目录 DEVICE-531R-VERIFICATION.md。

## 2026-10-28：按 ClashPlus 改造——订阅迁主页、页签 1 改为数据页

- 依据 ClashPlus 1.2.7 静态逆向（Dart AOT / Blutter）落地三项：主页内联订阅、数据页四卡、订阅管理独立页。逆向证据与映射表见 `docs/CLASHPLUS_ALIGN_2026-10-28.md`。
- 新增 `components/SubscriptionSection.ets`：主页订阅卡列表 + 节点展开选点；展开动画逐值对齐 Plus `_ProfileNodeOverlayState`（340ms/`cubic-bezier(0.645,0.045,0.355,1)` 正向、300ms/`cubic-bezier(0.215,0.61,0.355,1)` 反向、高度揭示 `h=内容高×t` + `clip`、内容透明度 `clamp(t/0.6,0,1)`、整块 `clamp(0.65t+0.35,0,1)`），由 `UIContext.createAnimator` 逐帧驱动。
- 新增 `pages/StatsPage.ets` 接管页签 1「数据」：速率双曲线卡（峰值/平均/本次连接/累计总量）、内存占用 + 运行时间双卡、出口 IP 卡（国旗/国家/城市/ISP/ASN/时区）、连通性卡（默认 google.com/github.com，TCP443 或 HTTP(S) 经本机代理，左滑删除）。
- 新增 `commons/services/TrafficStatsStore.ets`：累计/按日（`lifetime_traffic_up/down`、`daily_traffic_by_ymd_v1`，键名与 Plus 同义）+ 每月清零日 1–28；**记账由 App 级每秒 tick 驱动**（HomePage.bootstrap 启动），不依赖「数据」页是否被打开。
- 新增 `commons/services/ConnectivityProbe.ets`；`PublicIpInfo`/`PublicIpService` 补 ASN 与 timezone；`ClashApiService` 新增 `fetchMemoryInuse()`（`GET /memory`）。
- `SubscriptionPage` 退化为「订阅管理」推入页（`navTitle`/`showBack`），新增 `pages/SubscriptionManagePage.ets` 承载；服务卡片 `targetPage=SubscriptionPage` 深链改折算为「主页 + 打开订阅管理页」（EntryAbility 同步调整）。
- 底栏页签 1 文案「数据」、图标改 `ic_network`；主页两条「暂无可用节点」提示文案改为指向主页「订阅」。
- 验证：`clean assembleHap` BUILD SUCCESSFUL；`scripts/verify-ui-resource-bindings.mjs` PASS（未新增 media 资源）。

### 2026-10-28 追加（第二轮用户验收意见）

- 主页卡片全删（速率/连接），公网 IP 移入启动按钮内沿底部弧线显示；订阅区块成为主页主体。
- 订阅展开改为**全屏覆盖**（`bindContentCover`）：卡片当表头 + 仅订阅自带分组 chips + 节点列表，选点自动退出；分组切换 bug（@Builder 值参数不响应）已修。
- 订阅卡片：流量进度条、到期文案、测速/刷新/设置三按钮（40×40）、当前订阅蓝框。
- 订阅管理页（`SubscriptionPage` / `SubscriptionManagePage`）删除，增删改全部并入主页「+」菜单式弹窗（二维码/URL/文件/转换）；`main_pages.json` 与 EntryAbility 深链同步收口；只接受 Clash 订阅，单节点链接拒绝。
- 设置页：连接管理/测速地址/GeoIP 资产/订阅转换四项删除；新增「网络与数据」分类（IPv6 / DNS 覆写 / Smart 选点模型）。
- 底部 dock 渐隐底删除。
