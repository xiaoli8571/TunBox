# TunBox HarmonyOS 全工程审查与本地 YAML 回归

日期：2026-11-03（Asia/Taipei）。对象：当前工作树，而非只看最近一次提交。

> 🧠 **From Hindsight memory (TunBox HarmonyOS 按 ClashPlus 改造：订阅迁主页 + 数据页)** — 历史目标是对齐 FlClash 的订阅与测速，并以当前 profile、内核节点目录为准。历史“完全对齐”的结论不能替代本轮验证。

## 结论

用户报告的主页节点名称滞后、provider 配置测速后大量 `--`，都有代码原因；本轮已修改源码并补运行回归。首轮列出的代码差距已在用户授权的后续修复中处理，当前修复内容、验证和装机步骤见 [剩余项修复记录](REVIEW_REMAINING_FIXES_2026-11-03.md)。这不等于证明所有客户端的所有行为和真机性能完全一致。 用户后续装机发现的启动变直连已另行查证并修复，见 [启动选点修复](STARTUP_SELECTION_FIX_2026-11-03.md)。

审查覆盖 `entry/src/main` 的 147 个 ArkTS、C++、Go、声明及模块配置文件，约 7.2 万行的工程清单；对节点选择、订阅导入、测速、配置合并、连接/恢复/网络切换、凭据、备份、调度和原生桥边界进行重点追踪，并运行全工程门禁与真实 ArkTS 编译。这个范围说明不代表对每一行都做了形式证明，也不把静态断言等同于真机验收。

保留了任务开始时工作树已有的优化、内核库及未提交修改。本轮没有修改用户提供的 YAML，没有上传订阅，也没有安装/发布应用。

## 用户 YAML 与截图的事实

`mihomo1.yaml` 的独立 YAML 解析结果：

- 静态 `proxies`：1 条，类型为 `direct`。
- `proxy-groups`：21 个；第一个“默认代理”有 10 行直接成员，其中包括子策略组和“直连”。
- `proxy-providers`：1 个 HTTP provider，其 URL 使用 HTTP(S)，没有 inline payload。
- 因此不能从静态 `proxies` 只有 1 条推出“订阅没有远端节点”；远端节点数要以内核加载 provider 后的目录为准。

用户的 ClashPlus 截图显示子组、直连都可取得结论：香港几行同为 67ms、台湾手动超时，其余地区有各自延迟。这是组出口测速的展示，多个组可以指向同一叶子出口。

“3 行显示延迟、提示 1 个成功”有两个不同原因：

1. 多行共用一个出口时，去重后只发一个探测是合理的，不能按显示行数推断请求数。
2. 原 TunBox 把 provider 叶子误判为“内核不认识”，只测剩余少量目标，并丢掉部分汇总中的跳过数。这才会让大量行保留 `--`，而提示看起来已经全部完成。

## 已确认并修复

| 优先级 | 问题与触发条件 | 原因、修改和证据 |
|---|---|---|
| P1 | 未连接时选择成员，主页启动按钮仍显示旧节点 | `SubscriptionSection.selectPanelMember` 只存 `proxyGroupSelections`、改面板局部状态，没有更新主页读取的选择提示，也没有发布 `node_switch_revision`。现在保存所选成员的作用域和名称、发送通知；离线策略组、provider 影子节点也可被共享展示口正确读取。 |
| P1 | provider 已加载，部分策略组仍不能测速 | mihomo REST `/proxies` 不是包含 provider 节点的完整目录。现在 `ClashApiService.proxiesJson` 合并 `/providers/proxies`，保留静态节点/组同名优先级，并登记 provider 归属。真实本机内核已复现原接口缺失、合并后存在。 |
| P1 | 目录补全后，provider 节点若仍用普通测速地址会 404 | 静态代理走 `/proxies/{name}/delay`；provider 所有的节点走 `/providers/proxies/{provider}/{name}/healthcheck`。两个测速实现都已接入归属路由，名称/URL/期望码继续编码。本机真实内核验证同一节点前者 404、后者返回有效延迟。 |
| P1 | “默认代理 → 子组 → provider 叶子”选择后出口名称仍旧 | `readKernelSelection` 原来只检查主组直接叶子，`now` 是子组时无法确认；provider 叶子也因目录不完整而丢失。现在遍历真实 `now` 链、防环，并收集可达叶子；在线选择后立即回读被选择的父组，不必等轮询。 |
| P2 | 策略组换出口后仍显示旧出口的延迟 | 旧 `delayLookupNames` 先读组名下的缓存，再读叶子；升级前组名下保存的旧结果会遮住新出口。现在已解析的组只读取当前叶子的记录。 |
| P1 | 切订阅或清理期间，晚到的目录请求把旧数据重新写回来 | 目录增加代次守卫；刷新失败返回 `null`，旧快照只保留供 UI 展示，不能作为“本次刷新成功”的返回值用于测速。已测乱序返回、切 profile、clear 后旧请求完成三个边界。 |
| P1 | 晚到的出口轮询覆盖新手选；同名节点跨 profile 时元数据不更新 | `KernelSelectionManager` 增加 set/clear 代次和有效性回调；“没变化”比较同时包含组、节点、profile。原来只比节点名。 |
| P2 | Direct 没有测速；部分批次汇总假装完整结束 | Direct 是可进行 URLTest 的适配器，已与“真实远端代理计数”分开处理，REJECT/PASS/空 provider 的 COMPATIBLE 不冒充代理结果。完成提示补跳过和未完成数，空批次/通道错误不报成功。 |
| P2 | 备份恢复丢失每个订阅的自动更新设置 | 导出已包含 `autoUpdate/updateIntervalMinutes`，导入手工复制字段时漏了两项。现在恢复它们；3 个真实导入运行用例覆盖关闭、独立间隔、旧备份缺字段。 |

核心改动位置：

- `components/SubscriptionSection.ets`
- `commons/services/{ClashApiService,ConnectionOrchestrator,KernelSelectionManager,BackgroundLatencyService,BackupRestoreService}.ets`
- `commons/tunbox/{CoreCatalogService,ProxyPanelMembers,TunBoxDelay,TunBoxLatencyService}.ets`
- `commons/latency/LatencyProbe.ets`

## 首轮审查记录的剩余项（修复前历史）

以下保留首轮发现及当时的建议。当前实现已处理这些代码项，详见 [后续修复与装机验收](REVIEW_REMAINING_FIXES_2026-11-03.md)；数值参数按既定用户要求保留。

### P2：测速缓存没有 URL 和订阅作用域

`LatencyLiveView.recordFor(nodeName)`、`setRecord(rec)` 使用节点名作为 Map 键；持久化结论也主要以节点名定位。记录没有保存本次测试 URL。

影响：两个订阅都叫“香港01”，或者用户换测速 URL 后尚未重测，同名记录可能沿用另一个上下文的结果。`retainOnly` 按名称保留，不能识别这种冲突。

FlClash 当前代码用 `testUrl + NUL + proxyName` 区分测速任务/结果；ClashPlus 的反编译记录也有 `Map<testUrl, Map<proxyName, delay>>`。建议改成 profile/配置版本、URL、节点名的明确键，并处理旧缓存迁移。这里涉及整个实时/持久化/恢复链，本轮未顺手改变存储格式。

### P2：父组测速没有完整继承子组的 URL

`BackgroundLatencyService.execute` 取当前所选父组的 `url/expectedStatus`，随后对所有解析出的叶子使用这一个策略。虽然 `TunBoxLatencyService.start` 有 `perNodeUrl` 参数，这条入口没有传入。

影响：一个父组内引用多个配置了不同测速 URL 的子组时，从父组测速与进入子组测速可能使用不同地址。FlClash 的 `_resolveDelayTestTargets` 会沿选择链取得有效 URL，再按 URL+出口去重。当前实现没有完成这部分，不应宣称完全等价。

### P2：部分平面节点选择仍拆掉整条 VPN

`ConnectionOrchestrator.reconnectWithNode` 仍执行 `disconnect → 等待 600ms → connect`。`SubscriptionSection.selectNode` 等路径使用它；新的组成员选择路径则只 PUT、读回状态。

影响：同一份已应用配置中切到一个已存在的节点，仍可能中断现有会话并重新建立 TUN。ClashPlus 1.2.7 的 `changeProxy` 逆向链路是选择、连接处理、出口刷新，不调用 `setupConfig/startTun`。

建议：先确认 profile/配置版本和目标成员一致，再复用热选点；失败或跨配置时保留有界重连。不能把“所有选节点都要断开”视作 Clash 客户端共同口径。

### 能力差异：非当前订阅的独立测速

当前 `BackgroundLatencyService.execute` 明确拒绝 `profileId !== currentId`，要求先打开该订阅。ClashPlus 逆向产物的 `asyncTestDelay` payload 支持携带 `profile-path`，可以表达目标订阅作用域。

TunBox 目前使用当前隧道核或当前无头核，没有实现等价的独立订阅测速上下文。这里应作为能力差距处理，不能悄悄切换正在使用的 VPN 来伪装支持。

### 保留的参数/收尾差异

- TunBox 当前单节点超时 3000ms，自适应并发最高 64，客户端守护 10000ms；ClashPlus 1.2.7 逆向记录为节点预算 5s、分批 100。这些参数受历史用户要求影响，不能因为对齐客户端就擅自改回。
- 当前 TunBox 对无响应新目标的非显式取消收尾可以显示超时；FlClash 的无应答分支保留上次测量、放弃结论。这里仍不是严格一致的故障口径。
- 已存在网络身份快照、尾部合并、Extension 网络更新、MTU 真源和恢复门禁；这些代码/门禁不证明 Wi-Fi/蜂窝切网延迟、长时后台存活和 IPv6 出口已经达到最优。仍需要真机证据。

## 对照来源

- 用户本机 ClashPlus 1.2.7 逆向产物：`C:/Worker/REA/_re_clashplus/asm_cloak`，它是 AOT 汇编与符号，不是原始 Dart 源码。报告用于导航，再核对调用地址；没有执行其中描述的旧任务。
- `report/20-delay-and-node-switch.md`：`delayTest 0x715bac`、`getDelay 0x716888`、`asyncTestDelay 0x716a64`、`computeRealSelectedProxyState 0x4f4e90`。
- [FlClash 当前代理动作](https://github.com/chen08209/FlClash/blob/main/lib/providers/actions/proxies.dart)：出口解析、URL、任务去重。
- [FlClash 当前内核目录](https://github.com/chen08209/FlClash/blob/main/core/proxy.go)：`tunnel.AllProxies()`；这与 TunBox 原先直接使用 REST `/proxies` 不是同一个全集。
- [mihomo API 文档](https://wiki.metacubex.one/api/)；并核对实际捆绑内核源码 `hub/route/proxies.go` 和 `hub/route/provider.go` 的路由。

## 验证记录

新增 `scripts/verify-provider-selection-runtime.mjs`，执行生产 `.ets`，仅替换鸿蒙平台边界，并使用真实本机 mihomo、loopback provider 和 loopback 204 服务：12 个用例通过。没有访问用户远端 provider，也没有把本机延迟当作用户机场的延迟。

`scripts/verify-proxy-panel-members.mjs`：17 个生产面板方法用例通过。新增断言覆盖保存偏好、主页通知、在线出口刷新、Direct 与空批次。

`scripts/verify-review-runtime.mjs`：20 个回归用例通过；`verify-backup-self-contained.mjs`：20 项，包括 3 个生产导入运行用例。

原代码负对照：把测试指向修改前的业务源码，provider 完整目录断言和面板立即同步断言都失败；修改后通过。

全量门禁结果、最终 clean 构建及资源编号检查结果见本文件末尾的最终记录。检查期间修正了已有门禁问题：Smart E2E 漏 stage `VpnRecoveryPolicy`、旧 toast 断言、Direct 被要求提供 server/port/口令、生成器已有 MTU 修改的指纹漏同步。没有为通过测试而删除远端代理的必要字段要求。

本轮验证产物为 unsigned HAP；没有签名、安装、AGC 上传或发布。未取得这份新代码的真机界面/机场测速/Smart 流量抓包验收，不能用本地门禁替代这些结果。

### 最终记录

- `TUNBOX_SUBSCRIPTION_FIXTURE` 指向用户本地 YAML（只读）；`MIHOMO_BIN` 指向本仓库 Windows 测试内核。
- `node scripts/verify-all.mjs --hap entry/build/default/outputs/default/entry-default-unsigned.hap`：**PASS=83 / FAIL=0 / SKIP=2**。没有扩大失败白名单。
- 跳过 1：`verify-latency-core-v2.mjs` 的额外 `--arkts` 临时导入编译变体；当前应用实际使用的源码已在下面的真实 clean 构建中通过。
- 跳过 2：`verify-smart-active-chains.mjs`，缺真实 Smart 连接链抓包。不能算作 Smart 真机流量验收通过。
- 最终构建：`hvigorw.bat --mode module -p module=entry@default -p product=default clean assembleHap --no-daemon`：**BUILD SUCCESSFUL，45.867s，34/34 tasks executed**。
- 构建后立即 `node scripts/verify-ui-resource-bindings.mjs`：**4/4 PASS**，主页/数据/设置/电源资源编号正确。
- 未签名产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`，29,104,202 bytes。
- 产物 SHA-256：`CA0E15791D265592BD4DCBF66F91E498DE6CD70689C003A98EC0E10C83546249`。
- 修改范围 `git diff --check` 通过。工作树已有改动继续保留，未提交或推送。
- 已按仓库约定先 DRY_RUN 再执行 `scripts/clean-workspace.sh`，本轮临时日志已清除。自动审批两次拒绝删除 `C:/Users/Administrator/AppData/Local/Temp/tunbox-probe-review-before`（仅返回 `blocked by policy`），其中 12 份修改前源码备份保留，未继续尝试其他删除方式。
