# TunBox HarmonyOS × FlClash 全功能对照（2026-11-04）

基准：FlClash `main`（README / `lib/views` / `lib/models/profile.dart` / `lib/providers/actions/proxies.dart` / `core/delay.go`）
对照对象：`C:\Worker\TunBox\TunBox_HarmonyOS` 当前工作树（v0.8.2 之后，含本轮 1、2 项）。

> 唯一边界（用户 2026-11-04 定）：**界面简单、后台完整兼容；任何为了"省事"而造成
> 订阅、测速、启动、出口 IP 或恢复异常的精简都要撤掉。** 本文用 ✅ / ⚠️ / ❌ / — 标注：
> ✅ 已一致；⚠️ 有差异但可解释；❌ 缺（待补）；— 平台不存在此概念。

## 0. 本轮（1、2 项）实际改动

| 项 | 改动 | 证据 |
|---|---|---|
| 1 单一真源 | 新增 `NodeTruth`：已应用 profile 只读内核 `/proxies`；未应用 profile 的 App 表降级为**显式预览**，不再与内核合并 | `commons/tunbox/NodeTruth.ets`；`NodeSelectionPage.displayNodes()` |
| 2 Group 语义 | 组行改读内核 `all` 的**直接成员**（不递归）；出口沿 `now` 链；组卡计数改直接成员数 | `NodeSelectionPage.rebuildRows()`；`NodeTruth.exitOf/projectGroup` |
| 撤省事① | 本地导入不再用 `isClashBody` 一刀切，改走 FlClash `validateProfile` 同款管线 | `SubscriptionService.addLocalYaml` |
| 撤省事② | 文件选择器 `.yaml/.yml/.txt/.conf`（内容判定，不再按扩展名挡） | `SubscriptionSection.importYamlFile` |
| 撤省事③ | 单节点测速预算 3000 → **5000 ms**（对齐 mihomo `defaultDelayTestTimeout`） | `TunBoxDelay.TUNBOX_DELAY_TIMEOUT_MS` |
| 门禁 | 新增 `verify-single-source-nodes.mjs` 28 条；更新 4 个旧断言 | `scripts/` |

## 1. 架构与状态源

| 能力 | FlClash | TunBox HarmonyOS | 结论 |
|---|---|---|---|
| 节点来源 | 只有内核（`tunnel.AllProxies()`），App 不持有节点定义 | 已应用 profile：内核目录；其它订阅：App 表**预览** | ✅ 已对齐（预览是本仓额外能力，已显式隔离） |
| 组的语义 | 内核 `all` + `now`，面板只显示直接成员 | 同上，已改 | ✅ |
| 当前出口 | `computeRealSelectedProxyState` 沿链解析 | `NodeTruth.exitOf` 沿 `now` 链、防环 | ✅ |
| 测速目标去重 | `url + proxyName` | 作用域 = profile + 配置修订 + URL + 期望码 + 出口 | ✅（更严） |
| 内核目录缓存 | 每次 `getProxiesGroups` | `CoreCatalogService` 800 ms TTL + 代次守卫 | ⚠️ 缓存更省 IO，选点后强制刷新 |
| 配置与内核分裂 | 不存在（配置即内核输入） | 本轮已收口；`SubscriptionService.nodes` 仅预览 | ✅ |

## 2. 订阅与配置

| 能力 | FlClash | TunBox HarmonyOS | 结论 |
|---|---|---|---|
| 订阅链接导入 | ✅ | ✅（UA 链、重定向、Basic 鉴权、gzip/zlib、ETag/304） | ✅（TunBox 更宽容） |
| 本地文件导入 | ✅（任意文件，内核校验） | ✅（本轮改为内容判定，`.yaml/.yml/.txt/.conf`） | ✅ |
| 分享链接 / base64 列表 | 交内核 `encodeYamlTask` | `SubConverter`（mihomo 转换逐行移植）+ 本地导入 | ✅ 等价（实现位置不同） |
| 保存前校验 | 内核 `validateConfig` | 原生 `prepareProfile` 展开锚点+校验；无 `-t` 通道 | ⚠️ 平台限制：设备侧无 validate API |
| 覆盖合并 | `mergeProfileBase`：proxies / groups / sub-rules 整段覆盖 | `ProfileConfigMerger.merge` 同三段 + dns/hosts/providers 透传 | ✅（多透传是本仓功能） |
| 订阅标题 | `content-disposition` | 同上 + 正文机场名兜底 | ✅ |
| 自动更新 | 每 profile `autoUpdateDuration` | 每订阅独立开关与间隔（分钟） | ✅ |
| 失效保护 | 校验失败保留旧文件 | 同（"已保留旧配置"） | ✅ |
| 配置编辑器 | 内置编辑器 | ✅ `ProfileEditorPage`：整份 YAML，保存走 `validateAndStore` + `ensureProfileApplied` | ✅ |
| Override | ✅ `Profile.overrides` + JS `scripts` | ✅ 每订阅覆盖层（`ProfileOverrideStore`，按 profile 合并）；⚠️ JS 脚本受 ArkTS 禁 `eval` 限制 | ⚠️ 结构化已对齐；JS 需随包 QuickJS/NAPI |
| 自定义 proxies/groups | ✅ | ⚠️ 以订阅原文/规则页为主，无独立 CRUD 页 | ⚠️ 部分 |
| proxy-providers | ✅ | ✅ `ProxyProviderParser` + 内核加载 + provider 测速路由 | ✅ |
| WebDAV 备份 | ✅ | ❌（用户明确本阶段不做） | ❌ 按指示不做 |
| 本地备份/恢复 | ✅ | ✅ AES-GCM 加密文件（`BackupCrypto` + `BackupRestoreService`） | ✅ |
## 3. 节点 / 分组 / 测速

| 能力 | FlClash | TunBox HarmonyOS | 结论 |
|---|---|---|---|
| 节点列表 | 内核目录 | 内核目录（已应用 profile） | ✅ |
| 分组展示 | 组的直接成员 + `now` | 同上（本轮改） | ✅ |
| 选择入口 | `changeProxy` → PUT 组 + 重置连接 | `CoreCatalogService.select` + 热切换（同配置不断 TUN） | ✅（更稳） |
| 单节点测速 | 内核 `testDelay`，默认 5 s | REST `/proxies/{name}/delay`，**本轮 5 s** | ✅ |
| 组/批量测速 | TaskPool，`maxConcurrentDelayTests` | 自适应 32 基线 / 64 上限 HTTP lane | ⚠️ 并发实现不同（HTTP vs 内核池），结果口径一致 |
| 慢节点判定 | 504 = 超时；无响应保留旧值 | 同上（504→超时；无响应不写结论） | ✅ |
| provider 节点测速 | 内核内 | 走 `/providers/proxies/{p}/{n}/healthcheck` | ✅ |
| 测速 URL 继承 | 沿选择链取子组 `testUrl` | 同（作用域含 URL + 期望码） | ✅ |
| 结果作用域 | `url + proxyName` | profile + 修订 + URL + 期望码 + 出口 | ✅（更严） |
| 非当前订阅测速 | 不支持（只测当前内核） | ✅ 独立无头测速核 + 物理网卡绑定 | ✅ 额外 |
| 其他订阅节点预览 | 无此概念 | ✅ 显式 preview（本轮隔离） | ✅ 额外 |
| 节点删除 | 无（改配置） | ✅ 删除台账（刷新不复活） | ✅ 额外 |
| Smart 自动选点 | 上游无 | ✅ mihomo-smart `♻️ 自动选择` | ✅ 额外 |
| 排序/搜索/多选 | 有排序与搜索 | ✅ 延迟/手动/默认 + 搜索 + 多选删除 | ✅ |

## 4. 规则 / 分流 / DNS

| 能力 | FlClash | TunBox HarmonyOS | 结论 |
|---|---|---|---|
| 规则列表编辑 | ✅ `rules.dart` | ✅ `RulesPage`（自定义规则 + 排序） | ✅ |
| 订阅自带规则 | 由 profile 决定 | ✅ 按订阅落账并写入生成配置 | ✅ |
| rule-providers | ✅ | ✅ `subscriptionRuleProvidersBlock` | ✅ |
| 应用分流 | ✅ `access.dart`（per-app） | ✅ `AppRoutingPage`（排除/包含 + 国内应用策略） | ✅ |
| 指定站点强制代理 | 通过规则 | ✅ `SiteRoutingPage`（域名 → PROXY） | ✅ 额外（更易用） |
| DNS 接管 | 恒接管（redir-host/sentinel） | ✅ 恒接管 + fake-ip（原文显式 enhanced-mode 尊重） | ✅ |
| DNS 上游编辑 | ✅ `dns.dart` | ⚠️ 设置内 + 每订阅上游，无独立 DNS 页 | ⚠️ 入口不同 |
| DoH 预解析 | 内核内 | ✅ `DoHResolver`（测速/启动前置） | ✅ 额外 |
| 嗅探 sniffer | ✅ `sniffer.dart` | ⚠️ 透传原文 sniffer 段，无独立 UI | ⚠️ 功能在、入口缺 |
| 过滤器 filters | ✅ `filters.dart` | ⚠️ 搜索 + 删除台账替代，无规则式过滤 | ⚠️ 部分 |
| 自定义 UA | ✅ `user_agents.dart` | ⚠️ 固定 UA 链（clash-verge → clash.meta → TunBox → v2rayN → Shadowrocket） | ⚠️ 无 UI，链本身经实测 |
| 分流模式 | rule/global/direct | ✅ 同（`proxyMode` + 运行时 PATCH） | ✅ |

## 5. 隧道 / 系统集成 / 保活

| 能力 | FlClash | TunBox HarmonyOS | 结论 |
|---|---|---|---|
| TUN | 各平台原生 | `VpnExtensionAbility` + NAPI 注入 fd | ✅ |
| IPv6 | 支持 | ✅ 双栈 + IPv6 DNS 开关 | ✅ |
| MTU | 可配，默认 9000 | 固定 **1360**（换网不重建 TUN） | ⚠️ 平台取舍，非省事 |
| 系统代理 | 桌面有 | — 鸿蒙无此概念 | — |
| 应用分流 | Android per-app | ✅ 同上 | ✅ |
| 开机自启 | 桌面/Android | ⚠️ 无（鸿蒙受限） | ⚠️ |
| 快捷开关 | Android QS Tile | ✅ `QuickToggleAbility` | ✅ |
| 通知 | 常驻通知 | ✅ 通知卡（速率/时长）+ 服务卡片 | ✅ |
| 恢复策略 | 内核重启/应用重连 | ✅ `VpnRecoveryPolicy` + 进程恢复 + 网络切换监听 | ✅ |
| 出口 IP 展示 | 无（有连接页） | ✅ 公网 IPv4 + 国家策略 | ✅ 额外 |
| 深链导入 | `clash://` `clashmeta://` `flclash://` | ✅ `tunbox://import?url=` | ✅ |
## 6. 界面 / 可视化

| 能力 | FlClash | TunBox HarmonyOS | 结论 |
|---|---|---|---|
| 主题 | Material You 动态取色 + 明暗 + 主题预览页 | TunBox 品牌色板 + 明暗（`ThemeService` + tokens） | ⚠️ 无动态取色/预览页 |
| 首页 | 仪表盘（状态/流量/模式） | 天体电源球 + 状态胶囊 + 当前节点 + 公网 IP | ✅ 等价（形态不同） |
| 订阅列表 | profile 列表 | 订阅卡（排序/测速/编辑/刷新/流量/到期） | ✅ |
| 节点面板 | 组 + 成员 | 组 chips + 成员（内核直接成员） | ✅ |
| 搜索 / 排序 | ✅ | ✅（延迟/手动/默认） | ✅ |
| 连接视图 | `connection/requests.dart` | `ConnectionsPage` | ✅ |
| 日志 | ✅ | `PersistentLogStore` + `DiagnosticsSheet` | ✅ |
| DNS 查询视图 | ✅ | ✅ `DnsQueryPage`（`/logs` 过滤 DNS 行，暂停/清空/检索） | ✅ |
| 流量图表 | ✅ | `StatsPage` + `RateChart` | ✅ |
| 诊断导出 | 日志 | ✅ `DiagnosticExportService` | ✅ 额外 |
| 服务卡片 | — | ✅ FormKit 卡片 + 快捷开关 | ✅ 额外 |

## 7. 备份 / 迁移 / 自动化

| 能力 | FlClash | TunBox HarmonyOS | 结论 |
|---|---|---|---|
| 本地备份 | ✅ | ✅ 加密 JSON（AES-GCM） | ✅ |
| WebDAV 远程备份 | ✅ | ❌（用户本阶段明确不做） | ❌ 按指示 |
| 订阅自动更新 | 每 profile | 每订阅独立间隔 + 易变域名 6 h | ✅ |
| 深链导入 | 三种 scheme | ✅ `tunbox://import?url=` | ✅ |
| 外部启停 | Android 广播 | ✅ 快捷开关 Ability | ✅ |
| 更新检查 | ✅ | ✅ `UpdateChecker` | ✅ |

## 8. 平台不存在项（不是缺失）

| FlClash | 鸿蒙对应 |
|---|---|
| 系统代理 / 托盘 / 全局热键 | — 平台无此概念 |
| Android TV / 多 ABI | — 单 arm64 设备形态 |
| 桌面 helper service | — VpnExtension 由系统托管 |

## 9. 仍存差异与优先级（按唯一边界排序）

**P1（本批已交付，2026-11-04）**
1. ✅ **整份 YAML 编辑器**：`pages/ProfileEditorPage.ets` —— 保存走 `validateAndStore`（与导入同管线），
   失败保留旧文件；已连接时 `ensureProfileApplied` 热重载不重建 TUN。
2. ✅ **每订阅 Override**：`commons/services/ProfileOverrideStore.ets` + `RuntimeConfigProfile.overrideYaml`
   → `ProfileConfigMerger.merge` 按 profile 合并；**不再**写回全局 `yamlOverride`。
   ⚠️ FlClash 的 `scripts`（JS 变换）仍不可用：ArkTS 禁止 `eval`，需随包编译 QuickJS/NAPI。
3. ✅ **DNS 查询实时视图**：`pages/DnsQueryPage.ets` —— 复用 `/logs` WebSocket，按 DNS 行过滤，
   支持暂停/清空/检索；只在本页临时开 debug，离开恢复 info。

**P2（可用性/一致性，尚未开工）**
4. UA 无可选 UI（链本身经真机实测；加 UI 属产品决策）。
5. sniffer 无独立 UI（透传原文，功能在）。
6. 无规则式 filters 页（用搜索 + 删除台账替代）。
7. 主题无动态取色/主题预览（鸿蒙无 Material You 对应能力）。
8. 批量测速并发 32/64（HTTP 实现）vs FlClash 内核池 50；结果口径一致，性能取舍。
9. WebDAV（用户先前明确不做）。
10. 无开机自启（平台限制）。

**已确认不是差异**：proxy-providers、深色主题、本地备份、TUN、IPv6、DNS 接管、规则/分流、
provider 测速路由、`unified-delay`、出口链语义、组直接成员。

## 10. 验证记录（本机，2026-11-04）

```text
verify-single-source-nodes.mjs        28 passed, 0 failed（新增）
verify-import-diagnostics.mjs         21 passed, 0 failed
verify-vpn-architecture.mjs           322 passed, 0 failed
verify-concurrent-refresh.mjs         114 passed, 0 failed
verify-conversion-output-runtime.mjs  14 场景 + 真实内核 YAML 校验
verify-tunbox-delay.mjs              11/11（含 5 s 新基线）
verify-sub-parse-fidelity.mjs         727 passed, 0 failed
verify-types.mjs                      TYPE/SYNTAX CHECK PASSED
clean assembleHap                     BUILD SUCCESSFUL 42 s 197 ms
verify-ui-resource-bindings.mjs       4/4 PASS
HAP 30,697,538 B  SHA-256 A9BFD0CDC9B251EE355D7CE66090BAC804F629E62C59D0D2BC8AD6F93F2656CD
```

未签名、未装机、未上传。**真机行为（切网、后台存活、真实机场延迟）仍需用户验收**；
本文不把离线门禁当作真机结论。
