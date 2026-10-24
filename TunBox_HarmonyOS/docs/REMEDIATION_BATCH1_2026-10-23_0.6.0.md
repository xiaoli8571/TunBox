# TunBox 整改执行记录：第一批 P0

> 日期：2026-10-23  
> 方案：[稳定性、保活与 UI 详细整改方案](C:/Worker/TunBox/TunBox_HarmonyOS/docs/TUNBOX_STABILITY_KEEPALIVE_UI_REMEDIATION_PLAN_2026-10-23.md)  
> 起始代码基线：0.6.0 / 528；本轮候选：0.6.0 / 531（529/530 为真机与 DNS 修复中间包；530 存在图标串位，已在 531 修复）。  
> 范围：第一批连接可靠性、配置应用保护及与保活相关的异步收尾。下列实现结果不代表整个 P0～P2 方案已完成。

## 1. 本轮修改

| 对应任务 | 已修改内容 | 主要文件 |
|---|---|---|
| P0-01 | 启动、测速核、热加载三条路径均在最终合并及修复后调用原生文档校验器，提前拒绝缺失策略/组/规则集引用。 | ConnectionOrchestrator |
| P0-01 | 修复 DNS 子键用顶层判断导致显式 enhanced-mode 未被识别的问题；不重复注入 fake-ip-range、fake-ip-filter。 | ProfileConfigMerger |
| P0-02 | connect/disconnect/规则热加载共用资源队列；连接意图先于异步读取登记；新操作等待旧事务收尾。 | ConnectionOrchestrator |
| P0-02 | 重复断开不再因代次变化停留在“断开中”；自动修复在资源事务释放之后运行，避免重入死锁。 | ConnectionOrchestrator |
| P0-02 | 测速启动增加独立代次，停止、超时清理及真实连接接管会使旧准备任务失效；接管前等待测速状态机结算。 | ConnectionOrchestrator |
| P0-03 | 旧流量结果不再更新新会话、通知和页面；旧 finally 不释放新轮询锁；请求异常得到收敛。 | ConnectionOrchestrator |
| P0-04 | 规则立即应用失败时不再完整重连；坏候选不会为“自动修复”拆掉当前连接。 | ConnectionOrchestrator |
| P0-04 | 热加载须确认选点后才提交 Profile 身份；失败尝试加载最近可用快照。跨 Profile 时选择新配置的节点/默认出口。 | ConnectionOrchestrator |
| P0-04 | 最近可用快照按实际接受的字节原子写入；正式文件提升失败时不再误存更旧文件；恢复也经临时文件替换。 | ConnectionOrchestrator |
| P0-05 | 旧后台任务查询不会阻塞新会话自检，旧查询结束也不能解除新查询的并发保护。 | UiGuardian |
| P0-07 | 切网意图查询和自动重连增加代次核对；离线取消待执行重连；旧失败结果不能给新会话安排重试。 | ConnectionOrchestrator |
| P0-08 | 连接列表离页时取消延迟初始化和轮询，忽略迟到列表；下载失败清理临时文件。 | ConnectionsPage、ConnectionOrchestrator |
| P0-04/08 | 私有配置写入按 UTF-8 实际字节数检测短写，失败关闭 FD，不允许短文件进入后续提升。 | PrivateFileStore |
| P1-01 | 规则页/网站规则页区分“已保存”和“立即应用未完成”，说明不自动断开当前连接。 | RulesPage、SiteRoutingPage |
| P1-01/03 | 代理模式使用 PATCH /configs；修复 PUT 重载配置造成模式未变、策略组被重置的问题。 | ClashApiService |

## 2. 重要行为说明

### 2.1 最终校验的边界

原生 `prepareProfile` 校验最终文档、代理定义及策略/规则集引用，不应用配置、不创建监听、不初始化下载 provider。

它不证明 Geo 数据语义、所有本地文件和远程 provider 已就绪。完整的最终依赖清单、远程资源预算及 DNS/逻辑规则依赖检查仍属于 P0-01 后续工作。

### 2.2 热加载失败的边界

- 校验失败：不提交候选配置，不自动重连。
- 内核拒绝/HTTP 结果未确认：保留正式文件，不宣称候选已生效。
- 内核接受但选点失败：尝试从最近可用快照恢复，不提交候选 Profile 身份。
- 响应丢失、回滚失败和内核实际生效状态不一致，还需要继续完善状态确认；不能仅凭 HTTP false 宣称原配置必然仍在运行。

### 2.3 版本与数据

529 是本轮第一次真机测试构建；530 包含该批改动及随后发现的 DNS 合并修复。版本名称仍为 0.6.0，通过版本码和包哈希区分。

规则默认关闭、去广告默认关闭、音频可选默认关闭、手动备份/恢复以及禁止测速组级失败数量汇总的既定方向继续执行。已有用户明确保存的有效选择不被重置。

## 3. 本地验证

以下记录区分脚本、同源 Windows 内核和真实鸿蒙设备，不互相替代。

| 验证入口 | 当前结果 | 说明 |
|---|---|---|
| verify-stability-remediation-runtime | 31 项通过 | 新增；真实 Go 配置解析、真实内核 PATCH 验证；平台边界与时钟为替身。 |
| verify-ad-rules-runtime | 28 项通过 | 包含坏配置不重连、迟到预检、选点失败回退、跨配置选点、最近可用快照。 |
| verify-background-keepalive-runtime | 27 项通过 | 包含新旧看门狗查询隔离；不是锁屏耗电测试。 |
| verify-foreground-session-runtime | 27 项通过 | 包含旧流量回调隔离及请求失败后的继续采样。 |
| verify-review-runtime | 18 项通过 | 包含显式 DNS 模式与用户 fake-ip 参数保留。 |
| verify-startup-assets-runtime | 43 项通过 | 包含 64 份同源内核配置检查及 4 次本地实际启动。 |
| verify-config-generation-integrity | 132 项通过 | 配置生成、引用、布尔值和缺库保护。 |
| verify-ad-rules-independence | 31 项通过 | 包括规则/去广告默认关闭及有效显式选择恢复。 |
| verify-logic-pure | 228 项通过 | 既有网络、健康与选点纯逻辑。 |
| verify-connect-stability | 35 项通过 | 钉选先于 CONNECTED 等约束。 |
| verify-vpn-architecture | 313 项通过 | 结构约束；不是系统保活实测。 |
| verify-app-routing | 71 项通过 | 应用分流及传输契约。 |
| verify-latency-core-freshness | 44 项通过 | 新鲜度检查与凭据回填顺序。 |
| verify-latency-warmup | 28 项通过 | 接管前先结算测速核等约束。 |
| verify-site-routing | 58 项通过 | 保存/应用边界；另列 6 项既有非门禁 AUDIT 观察。 |
| verify-flclash-profile | 通过 | 显式开启规则后验证自定义规则集；未改变默认关闭要求。 |

### 3.1 回归脚本调整理由

连接实现拆到 `connectExclusive`，热加载实现拆到 `reloadRulesHotExclusive`。相关源码护栏改为检查实际执行体，仍要求凭据回填、钉选、资源收尾和配置提交的原有顺序。

网站规则护栏改为要求热加载失败不重连，并由运行时异常用例验证。完整 Profile 夹具显式设置 `rulesEnabled=true`，使“用户启用后应保留规则集”的断言与默认关闭的产品要求一致。

### 3.2 全量门禁

529 首次全量运行：64 个脚本，59 通过、5 失败、0 跳过。其中四项为上面已修复的旧护栏/夹具前提；另一项是缺少私有真实订阅夹具。

530 最终全量复验：**64 个脚本中 63 通过、1 失败、0 跳过**。唯一失败为 `verify-subscription-fidelity.mjs`：缺少 `test/fixtures/real-subscription.yaml`，实际没有执行该项真实订阅保真验证。

其余四项已消除；严格命令仍以失败退出，**不能称为严格门禁全部通过**。设备上观察已有真实订阅的运行，不冒充该脚本已跑。本轮不作为通过全部门禁的公开稳定版发布。

命令与报告：

```powershell
node scripts/verify-all.mjs --strict --hap "C:\Worker\TunBox-audit-2026-10-23\remediation-224019\TunBox-0.6.0-530-device-signed.hap"
```

- 报告：[strict-530.log](C:/Worker/TunBox-audit-2026-10-23/remediation-224019/strict-530.log)。
- DevEco 最终构建：`CompileArkTS` 实际执行，`BUILD SUCCESSFUL`。
- 已恢复工程原始空 `signingConfigs`；本地调试签名配置没有留入项目。

## 4. 真机记录

### 4.1 环境与首次覆盖

- 设备型号：MLR-AL00。
- 设备系统标识：OpenHarmony-7.0.0.105。
- 本轮前已安装：0.6.0 / 525。
- 529 同签名覆盖安装成功；现有四份订阅仍可见，初始当前订阅显示 24 个节点。
- 未连接真实 VPN 时执行一次手动测速，观察到“准备测速通道”、真实 headless core ready 及后续目录刷新，未把未开始的任务直接宣布完成。
- 529 的测试日志发现 DNS 重复字段，由 530 修复后复验。

设备可能同时被用户操作；只将工具明确注入、且能对应日志的步骤计入本轮验收。其他选择变化不作为自动化测试结论，也不擅自恢复覆盖用户新选择。

### 4.2 最终候选验收

| 项目 | 结果与边界 |
|---|---|
| 覆盖安装 | 530 同签名覆盖成功，`bm dump` 确认版本码 530、名称 0.6.0。 |
| 真实启动 | 观察到最终配置写入、原生扩展运行、策略选中、配置提升和已连接 UI；不是仅有按钮状态。 |
| DNS 合并 | 530 已加入修复，18 项审查运行时用例及完整 Profile 回归通过；不再依靠重复键修复器来决定用户 DNS 模式。 |
| 模式切换 | 同源真实内核已验证 PATCH 改变实际 mode 且不重置已选节点；本轮真机切换操作受并行页面变化干扰，未计为独立通过项。 |
| 主动断开/反复操作 | 有本地运行时事件序列验证，仍需独占设备补齐真机逐步取证。 |
| 长时保活与耗电 | 未完成 8 小时、至少三轮对照及多设备矩阵。 |

设备实际出现了与工具注入时间不同的页面切换，已向用户确认是否同时操作；不据混合操作记录计算点击延迟，也不擅自恢复覆盖新的用户选择。

测试安装包：[TunBox-0.6.0-530-device-signed.hap](C:/Worker/TunBox-audit-2026-10-23/remediation-224019/TunBox-0.6.0-530-device-signed.hap)。

```text
HAP SHA-256:
78cd4379292ea920a0d74d052856504d68a14daaae1298555deacc252e0a6545

ets/modules.abc SHA-256:
c2c11b1161e512fc99913129db3656be291457366bf9454de34bd89e2179cc4f
```

这是设备测试候选；公开发布产物和完整发布门禁另行执行。

## 5. 后续顺序与未完成项

1. P0-01：完整最终依赖清单，尤其 DNS、逻辑规则、子规则、远程 provider 与 Geo/模型资源的实际就绪。
2. P0-02/03：系统授权迟回、跨进程同时启停、HTTP 结果丢失和回退未确认的状态闭环。
3. P0-05～08：普通/音频分别做媒体、网络、省电策略、长时资源与耗电对照。
4. P0-09：补稳定 0.5 的具体对照包、第二台手机等设备及真实私有配置夹具。
5. P1/P2：完成设置生效清单及其余 UI、平板、字体和无障碍批次；搜索/收藏等新功能继续后置。

当前未完成 8 小时锁屏、至少三轮耗电对照及完整多设备矩阵，不能宣布保活已超过 0.5。没有把全部方案任务勾为完成。

## 6. 证据位置

本地构建、回归和设备证据保存在：

`C:\Worker\TunBox-audit-2026-10-23\remediation-224019`

目录包含改动前源码副本、测试构建、构建日志、全量门禁日志和设备界面/日志。设备证据仅在本地使用；本文不记录订阅 URL、凭据、节点 IP 或完整原始配置。

本轮为整改候选及设备验证，不代表公开 Release 已发布。

## 7. 531：图标串位事故（资源编号错位）与最终产物

### 7.1 现象与判定

- 用户反馈启动按钮的电源图标、底部三个菜单图标被改；截图核对：底栏主页显示成下箭头、订阅显示成三点、设置显示成盾牌，电源按钮显示成订阅图标。
- 源码 SVG 与 HAP 内 media 均未被替换（`ic_power/ic_dashboard/ic_nodes/ic_settings` 与 HEAD 一致），不是设计改动。

### 7.2 根因

- media 资源编号由资源集合决定。529/530 的多次增量 `assembleHap` 在资源增删后继续复用 `CompileArkTS` 缓存，缓存内的 `Image.create({ "id": ... })` 仍是旧编号，与重新生成的 `ResourceTable` 错位。
- 530 编译产物中电源引用 `ic_nodes`、主页引用 `ic_chevron_down`，与源码 `$r('app.media.*')` 不符；设备按编译产物渲染，因此串位。
- 容易漏掉的一点：`CompileArkTS` 产物按模式分目录（`esmodule/debug` 与 `esmodule/release`），只查 debug 会让 release 包漏检。

### 7.3 修复

1. 真正清理构建：删除 `entry/build`、`build`、`.hvigor/cache` 后全量编译（`44 tasks executed, 0 up-to-date`），版本码 531。项目级 `clean` 只耗时 7ms、不清 module 产物，不能当作清理。
2. 新增构建后门禁 `scripts/verify-ui-resource-bindings.mjs`：从 `ResourceTable.txt` 取 media 名→编号，与 `FloatingBottomBar`/`CelestialPowerOrb` 的编译产物逐一比对；debug 与 release 两种模式目录都存在时必须全部通过；未编译时明确 SKIP。
3. `AGENTS.md` 固化打包规则：打包/装机 HAP 必须先清理再编译，禁止只跑增量 `assembleHap`；构建后立即跑该门禁，失败禁止安装或发布。

### 7.4 验证

| 项目 | 结果 |
|---|---|
| 资源编号门禁 | PASS ×8：主页 `ic_dashboard=16777394`、订阅 `ic_nodes=16777402`、设置 `ic_settings=16777410`、电源 `ic_power=16777404`（release 与 debug 各 4 项） |
| 真机图标 | 531 覆盖安装成功（`bm dump` 0.6.0 / 531），截图确认电源为 ⏻、底栏恢复九宫格/列表/齿轮 |
| 全量回归 | 65 个脚本：PASS 64 / FAIL 1 / SKIP 0；唯一失败为 `verify-subscription-fidelity.mjs` 缺私有真实订阅夹具（既有环境缺口，真失败 0）；strict 退出码仍为 1 |
| 发布签名 | `hap-sign-tool verify-app` 对 release HAP 与 APP 均返回 `Verify success` |

### 7.5 最终产物（0.6.0 / 531）

| 文件 | 字节 | SHA-256 |
|---|---|---|
| `dist/TunBox-0.6.0-unsigned.hap` | 40313109 | `4c21b8838965ccf35946d7d490ed4fec94754237cb99bc64d5ed2a88b56766f7` |
| `dist/TunBox-0.6.0-release-signed.hap` | 40380589 | `24a8b242adea48ee160ac106c1c58a58c472e2b55d5ebb8fd5b23a1ac86b0b21` |
| `dist/TunBox_HarmonyOS-0.6.0-release-signed.app` | 31088456 | `978b5ad987bd25b2e6366f17dbd1b856d3f1f9b54fd0627121b2e6e2d364e373` |
| 真机候选 `TunBox-0.6.0-531-device-signed.hap` | 43597208 | `da23221f841d72fedcd364a5992c7606804e0d30e6fe6ec7045ec1f38d1eb2bd` |

- 三个交付包的 `ets/modules.abc` 完全一致：`a26b8f54c130c7091d0571963bda6df82011a055d5f6c0e07265e2de4c3d8771`（release 模式编译）。
- 真机候选为 debug 模式编译，`modules.abc` 为 `fb66d72f52ad43530370340fd3cf6f31b2219f566bac739ea58a81799b828f27`；源码相同、编译模式不同，不能把两种 abc 混用比较。
- 清单：`C:/Worker/TunBox-audit-2026-10-23/remediation-224019/release-manifest-531.json`；构建日志 `build-531-release-scratch.log`；门禁回归 `strict-531-final.log`。

### 7.6 设备与限制

- 531 已在 MLR-AL00（OpenHarmony-7.0.0.105）多次覆盖安装，`bm dump` 回读 0.6.0 / 531。
- 首次安装为 debug 编译包，图标修复在该包上经截图首次确认。
- 设备随后被用户使用，暂停操作；用户确认空闲后改安装 **release 编译 + 设备调试签名** 的同版本包，使真机运行与发布包同一份编译产物（`modules.abc` 一致），并完成启动/模式/断开/测速逐步取证，见第 8 节。
- 发布签名包不能直装（证书与设备调试证书不同）；release 模式图标由构建后门禁、包内资源与编译产物一致性共同佐证。

## 8. 531 真机逐步验收（release 编译模式）

> 设备 MLR-AL00 / OpenHarmony-7.0.0.105。安装包 `TunBox-0.6.0-531-release-mode-device-signed.hap`（release 编译 + 设备调试签名，`modules.abc` 与 dist 三件套一致 `a26b8f54…`）。截图、日志与时间戳保存在本地审计目录 `DEVICE-531R-VERIFICATION.md`。

| 步骤 | 结果 |
|---|---|
| 覆盖安装 | 0.6.0 / 531 安装成功；4 个订阅（7/24/46/29 节点）保留，未卸载 |
| 冷启动 | 未连接态；电源 ⏻、底栏九宫格/列表/齿轮正确 |
| 启动连接 | 点击→已连接，`connect timing total=1535ms`（prep 39 / prelaunch 848 / launch 1162 / ready 1453 / pinned 1535）；TUN created、`stage startCore done: ok=true`、VPN 图标出现、公网 IP 为代理出口 |
| 模式切换 | 规则→全局→直连→规则：日志 `proxy mode hot-updated: global/direct/rule`；直连时公网 IP 由代理出口变为本地出口，切回规则恢复；连接时长连续、未中断 |
| 主动断开 | 点击→`disconnected` 约 2.0s；`com.tunbox.client:vpn` 进程退出；UI 未连接、流量 0 B、时长清零、VPN 图标消失 |
| 未连接测速 | 预热 `headless test core ready`；7 节点批次 `total=7 measured=7 timeout=0 failed=0`（约 1.9s）；UI 显示 58–265ms，无失败分类/超时数量横幅、无“测试中”残留 |

限制：未做 8 小时锁屏存活、耗电对照、音频保活与网络切换矩阵；发布签名包未直装（证书不同）；设备订阅 URL/凭据未导出。
