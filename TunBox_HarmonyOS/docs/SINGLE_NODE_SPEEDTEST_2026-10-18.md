# 单节点分组无法测速 —— 根因与修复（2026-10-18）

> ⚠ **后续变更（2026-10-22）**：本文所述「单节点」功能已整体下线 —— 订阅 URL 输入框
> 拒收单节点/分享链接（引导到「设置 → 订阅转换」生成 YAML 再导入），默认「单节点」分组
> 也不再创建，旧数据启动时清理。对应的 `scripts/verify-single-node-speedtest.mjs` 已删除，
> 由 `scripts/verify-single-node-removal.mjs` 接替（19 断言 + 3 负对照）。
> 本文保留为历史记录：它解释的「单节点为什么测不出速」仍然是内核 name/延迟通道语义的一部分。

## 1. 用户报障

> 支持导入单个节点例如 `vless://` 这种格式的，单节点导入后会存在默认的「单节点」分组，
> 现在单节点没有测速按钮，无法测速。

截图现象：订阅页「单节点」分组（5 个节点）行头只有 刷新 / 编辑 / 展开箭头，
**没有闪电测速图标**；展开后每个节点行只有 `--`（未测），而展开区提示文字却写着
「点击选用节点 · 长按可删除单个节点 · **点行头闪电图标测速**」——提示了一个不存在的按钮。

## 2. 根因

单节点直链导入的落点是常驻「单节点」分组，其 id 是 `DIRECT_GROUP_ID = 'direct'`：

- `entry/src/main/ets/commons/services/SubscriptionService.ets:63` — `export const DIRECT_GROUP_ID = 'direct';`
- 同文件 `:64` 名称 `'单节点'`、`:65` URL `'local://direct'`
- 同文件 `:2701` / `:2772` — `ProxyNode.fromUri(uri, DIRECT_GROUP_ID, …)`：导入节点的 `subscriptionId` 就是 `'direct'`

而 `SubscriptionPage.ets` 里有**两处同口径的拦截**，必须同时拆掉，缺一个就仍是死按钮：

| # | 位置（修复前） | 后果 |
|---|---|---|
| 1 | `speedTestSub()` 开头 `if (subId === DIRECT_GROUP_ID \|\| …) return;` | 即使按钮画出来，点下去也是**静默 no-op** |
| 2 | 分组头闪电 `Stack` 外面包着 `if (sub.id !== DIRECT_GROUP_ID) { … }` | 单节点分组**根本不渲染**这个按钮 |

回归来源：commit `c6b2638`（"订阅行闪电测速"）把展开区旧入口 `⚡ 一键测速` 删除、
改为行头纯图标按钮时，给新按钮与 `speedTestSub` 同时加上了 `DIRECT_GROUP_ID` 判定；
而该 commit 之前展开区的旧入口对单节点分组是**可用**的（当时 `speedTestSub` 无此判定）。
即：这是那次 UI 改版引入的功能回归，不是设计意图。

### 为什么单节点分组本来就应该可测（无任何特殊限制）

- `BackgroundLatencyService.testSubscription(ctx, subId)` → `execute(ctx, subscriptionId)`
  按 `node.subscriptionId === subscriptionId` 过滤节点（`BackgroundLatencyService.ets:109-113`）。
  传 `'direct'` 恰好选中全部手工导入节点，与普通订阅走**同一条** `LatencyEngine` 路径。
- 延迟探测走 `/proxies/{name}/delay`（`LatencyEngine` → `ClashApiService.testLatencyDetailed`），
  而 `ClashConfigGenerator.generate(…, allNodes, …)` 会把**全部**节点写进 `proxies:`
  （`ClashConfigGenerator.ets:353` 段头、`:394` 逐节点 `proxyYamlLine`，`validNodes` 由 `allNodes` 过滤而来）。
  单节点分组节点也在 `subs.nodes` 内，因此内核代理表里有它，名字可解析。
- 「单节点」分组不可**刷新**是合理的（`local://direct` 没有远端源），
  但**测速**与订阅源无关，不该被同一判定连带禁用。

## 3. 修复（`entry/src/main/ets/pages/SubscriptionPage.ets`，2 处）

1. `speedTestSub()` 守卫去掉 direct 分支，仅保留重入保护：

```ts
// 修复前
if (subId === DIRECT_GROUP_ID || this.speedTestingIds.includes(subId)) { return; }
// 修复后
if (this.speedTestingIds.includes(subId)) { return; }
```

2. 分组头闪电按钮去掉 `if (sub.id !== DIRECT_GROUP_ID) { … }` 包裹，
   使「单节点」分组同样渲染该按钮。**位置与形态遵守文件内的「铁律」**：
   纯图标（无文字）、位于刷新按钮左边、测速中显示 `LoadingProgress`。

未改动（刻意保留的合法闸门，均有断言守护）：
- 删除按钮对 direct 隐藏（常驻分组不可删，`doDelete` 提示「单节点分组为常驻分组，不能删除」）
- `refreshOne()` 对 direct 早退（无远端可刷新）
- `reload()` 对 direct 空组过滤（`nodeCount === 0` 时分组隐藏 → 新按钮不可能变成空组死按钮）
- `doEdit` 对 direct 允许改名但跳过 URL 校验

## 4. 验证证据

### 4.1 新增结构回归脚本

`scripts/verify-single-node-speedtest.mjs`（支持 `--file <path>` 指向任意文件，用于负对照）

```bash
cd C:\Worker\TunBox\TunBox_HarmonyOS
node scripts/verify-single-node-speedtest.mjs          # 修复后
node scripts/verify-single-node-speedtest.mjs --file /tmp/pre_crlf.ets   # 修复前（负对照）
```

| 运行对象 | 结果 | 退出码 |
|---|---|---|
| 当前（已修复）源码 | **34 通过 / 0 失败** | 0 |
| 修复前源码（`git show HEAD:…`，CRLF 归一化） | **27 通过 / 7 失败** | 1 |

负对照在修复前源码上精确命中两处根因：
`speedTestSub` 守卫含 `subId === DIRECT_GROUP_ID`、闪电按钮窗口含 `sub.id !== DIRECT_GROUP_ID`
（预修复源码 13 处常量出现，其中 `:660`、`:1215` 即两处被拆掉的闸门）。
**因此该脚本不是空断言**：它会因该 bug 而失败。

脚本内两处必须注意的坑（已修好，勿改回）：
- 守卫参数含**嵌套括号**（`this.speedTestingIds.includes(subId)`）：用 `[^)]*` 取参数会停在第一个 `)`
  上永不命中，必须用懒惰 `([\s\S]*?)`。
- 取函数体**不能切定长窗口**：定长窗口会溢进相邻函数，把 `refreshOne()` 里
  **合法**的 `DIRECT_GROUP_ID` 误判成本函数的闸门（假失败）。
- 判断「是否还有闸门」只看**代码区**（状态机掩码），注释里提到常量名不算闸门；
  但裸文本负对照 `sub.id !== DIRECT_GROUP_ID` 仍保留，守住真正的闸门。

### 4.2 既有回归脚本（repo 根目录执行）

| 脚本 | 退出码 | 结论 |
|---|---|---|
| `verify-sub-brace-balance.mjs` | 0 | SubscriptionPage.ets 括号全部配平 |
| `verify-node-sort-persistence.mjs` | 0 | 16 passed / 0 failed |
| `verify-latency-engine-runtime.mjs` | 0 | 19 passed / 0 failed（真跑引擎，桩依赖） |
| `verify-sub-node-two-row.mjs` | 1 | **既有陈旧失败**，见下 |
| `verify-concurrent-refresh.mjs` | 1 | **既有陈旧失败**，见下 |
| `verify-types.mjs` | 1 | **既有环境失败**，见下 |

三个失败均已证明与本次修改无关（同一文件跑修复前源码，得到**完全相同的失败集合**）：

- `verify-sub-node-two-row.mjs`：脚本针对更早版本的订阅页（期望 `NexusPing`、
  两行节点卡旧注释）。当前源码已重命名为 `TunBoxPing`（源码 `NexusPing` 出现 0 次）、
  节点卡结构已变。修复前后失败列表**逐字节相同**。
- `verify-concurrent-refresh.mjs`：脚本期望 `refreshingSubscriptionIds`，
  当前源码用 `refreshingIds`（9 处）。修复前后失败列表**逐字节相同**。
- `verify-types.mjs`：6 个 `error TS` **全部**位于 DevEco SDK 自带
  `…/sdk/default/openharmony/ets/api/@ohos.annotation.d.ets`，项目源码内 **0** 个，
  且日志无任何 `SubscriptionPage` 字样；其自带的项目语法阶段 `[B] PASS: 0 syntax errors`。
  属工具链/SDK 版本环境问题，权威编译判据是 hvigor（见 4.3）。

### 4.3 权威编译判据

```powershell
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
$env:Path = 'C:\Program Files\Huawei\DevEco Studio\jbr\bin;' + $env:Path
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module `
  -p module=entry@default -p product=default assembleHap --no-daemon
```

结果：`BUILD SUCCESSFUL`；`SubscriptionPage.ets` **无任何** ArkTS 警告/错误
（输出中其余告警均为其它文件的既有 deprecated 提示）。

## 5. 残余不确定性与邻接问题

**未验证（无鸿蒙真机/模拟器）**：以上全部是「源码级 + 编译级」证据。
真机上仍待确认的是端到端时序：未连接时点闪电会先拉起 headless 测速内核
（`ensureLatencyApi` → `ensureTestCore`，含约 1500ms 预热），首个延迟数字出现的耗时、
以及已连接时复用隧道 controller 的即时性。这些路径与普通订阅**完全共用代码**，
但本次未在设备上实测。

**邻接缺陷（本次未改，非本 bug 范畴，供决定是否跟进）**：

1. 「单节点」分组行头的**刷新按钮是静默死按钮**：`SubscriptionPage.ets:691`
   `refreshOne()` 对 `DIRECT_GROUP_ID` 早退，但按钮在 `:1241` 无条件渲染。
   点它没有任何反馈（无 toast、无转圈）。语义上 direct 组无远端源，
   合理修法是给该按钮加 `if (sub.id !== DIRECT_GROUP_ID)` 隐藏（与删除按钮一致）。
   本次未动，因为用户只报了测速，且隐藏/保留属可见 UI 取舍。
2. `speedTestSub()` 用 `BackgroundLatencyService.testSubscription`，其 `execute()` 在
   `LatencyEngine.isRunning()` 时直接返回（单航班）。若恰有静默批次在跑，
   用户点闪电会看到「正在测速…」→「✓ 测速完成」但实际本轮被跳过。
   该行为对**所有**订阅分组一致，非 direct 特有。
3. 节点行 `--` 只是延迟徽标，订阅页**没有**逐节点测速入口；
   逐节点测速只在节点选择页（`NodeSelectionPage` 行内 ↻）。符合现有设计（提示文字指的是行头）。

---

# 追加：同日第二、三批修复（2026-10-18 晚）

## 4. 「使用中」徽标与闪电测速图标重叠（真机报障）

**根因**：`SubscriptionPage.ets` 分组头里，分组名 `Text` **没有** `layoutWeight`。
超长订阅名按「理想宽度」撑开那个 `width('100%')` 的 Row，把后面的「使用中」徽标
挤出 Column 的右边界；ArkUI **不裁剪**溢出内容，而闪电按钮渲染在其后 → 压在徽标上。
同一原因也让名字被挤成 `···`。

**修复**：`:1215` 名称 `Text` 加 `.layoutWeight(1)`（吃剩余宽度并省略号），
`:1226` 徽标加 `.flexShrink(0)`（状态标识不压缩、不被挤出）。

**验证**：`hvigorw assembleHap` BUILD SUCCESSFUL；并**已装到真机目视确认** ——
截图显示「使用中」完整留在行内、⚡ 与其完全分离。

## 5. 测速大量显示「未测/`--`」：方案 C（用户裁定）

**真机取证（飞鸟云 37 节点批，headless 测速内核）**

```
17:38:47 nodes=46 measured=44 timeout=2        ← 另一订阅，同一手机同一网络，正常
17:38:21 nodes=38 measured=0 timeout=26 failed=2 notReady=10   ← 飞鸟云批
17:39:21 nodes=38 → aborted: core/channel unavailable streak=4 measured=1
17:39:40 cleanup: 20 node(s) left TESTING -> untested, 14 stamped failure(s) -> untested
```

- 「超时」是真的：飞鸟云 37 个节点的 `server:` 域名**全部解析到同一个 IP**
  `36.141.40.13`（手机与本机两条独立 DNS 均验证），即「单入口 IP + 端口路由」；
  内核 3s 拨号超时 → `504 kind=timeout`。对照订阅 `measured=44/46`，说明引擎与网络正常。
  另：`DoHResolver.ets:210` 的「≥2 域名同 IP 即判劫持」对该机场是**误报**
  （本次会话 19 次 `doh hijack suspicion: 37 domains`），只丢 pin、不影响连通性。

  > ⚠ **本节结论已被同日晚间取证推翻（2026-10-18 20:00~20:30）**
  > 「全部同 IP 36.141.40.13」那批是 **ikuuu**（`*.qpon` 域名），不是飞鸟云；
  > 飞鸟云是 34 个 **hysteria2** 节点，入口域名各自解析到不同的 AWS IP 且当时全部在线。
  > 「全部超时」的真因是 **DoH pin 把短 TTL 入口域名钉在已轮换的旧 IP 上**，
  > 与节点死活无关。完整取证、实验矩阵与修复见文末
  > 「# 追加：飞鸟云整屏超时的真因 —— hosts pin 钉死已轮换 IP（已修复 0.4.x）」。
- 「未测」是引擎产物：37 个死节点并发拨号把 controller 打到
  `code=2300028 Operation timeout`，连续命中后作废整批，**并把已盖章的真实超时回滚成未测**。

**修复（`LatencyEngine.ets`）**

1. `clearOwnTestingMarks()` **不再回滚**已盖章的失败结论，只收回 TESTING。
   依据：通道级故障（`failKind=CORE_NOT_READY`）在 `probeThroughCore` 里走
   `ProbeOutcome.notPublishable()`，**从不发布记录** —— 能被回滚的失败章 100% 是
   内核对该节点的真实拨号结论。回滚纯属信息丢失。
   配套删除 `LatencyController.isFailureOwnedBy()`（唯一调用点消失）。
2. 通道报不可用时**先就地重试**（`CORE_NOT_READY_RETRY_MAX=2`，线性退避 350ms），
   任一成功即正常发布；全部失败才计入连击。瞬时过载不再作废整批。

**验证**：`scripts/verify-latency-engine-runtime.mjs`（真跑引擎、桩依赖）
**21 passed / 0 failed**，其中新增两条覆盖本方案：
- 「通道作废整批时，已盖章的逐节点超时必须保留（不再回滚成未测）」
- 「通道瞬时不可用会重试；重试成功则照常出结论且不作废整批」

⚠ 既有用例「中途失联但自愈成功」的场景在重试生效后无法再触发自愈，已按新语义
改写为「3 个节点各自把重试用尽才触发一次自愈」——**这是有意的测试更新，不是放宽断言**。

**未完成**：设备在准备真机复测时掉线（`hdc list targets` 为空），因此
「装机后点飞鸟云闪电、观察批次不再回滚」这一步**没有在真机上跑完**；
结论目前由上述真跑引擎的离线用例支撑。HAP 已成功 `hdc install -r` 到设备。

## 6. 0.3 → 0.4「公网 IP 获取失败 + 代理不生效」排查结论

范围事实：`cf02697..dddf28e` 内**只有一个 commit** 动了鸿蒙 ets 源码，生成配置与
0.3.3 只差**一行**（`mode:`）。候选（含可信度）：

1. 新增 **`direct` 模式 + 首页「直连」一键按钮**且持久化（粘性）。
   `mode: direct` 绕过全部代理 → 代理不生效；公网 IP 探测走明文
   `http://ip-api.com/json/` 直出大陆网络 → 获取失败。0.3.3 无法保存 `direct`。
   **本机实测持久化 `proxyMode` 是 `rule`，故在本设备上不成立**，仅能解释
   「其他用户误触后永久直连」。
2. **`selectNode` 不再 await 就置 `CONNECTED`**（`ConnectionOrchestrator.ets:2803-2810`
   改为 fire-and-forget），而配置开了 `store-selections: true`，内核会恢复上次持久化
   选点；首页紧接探测公网 IP → 首批可能走错节点，且失败只 warn 不重试。
3. **连接路径 DoH 预算 6000ms → 1500ms**（`:2556-2560`）→ 实测
   `DoH pinned 49/100 / 53/104 / 21/70`，大量域名无 pin，运行时退回明文 UDP 解析、
   易被污染 → 可解释「部分节点 0.3 能用、0.4 不能用」。

**已排除**：`skipped 854 user rule line(s)`。该代码两版本完全相同，且被丢规则落到
`MATCH,PROXY`，只会更走代理。

**可观测性缺口（建议单独修）**：`PublicIpService.ets:98-100` 失败时**完全不记日志**，
`HomePage.refreshPublicIp()` 也不记 —— 所以日志里查不到公网 IP 痕迹，
不能作为任何证据。

---

# 追加：飞鸟云整屏超时的真因 —— hosts pin 钉死已轮换 IP（2026-10-18 晚，已修复并装机验证）

## A. 用户报障

> 最新的包测速，飞鸟云订阅节点全部超时，我用 flclash 电脑端测速，大部分都不超过 200ms。

真机（hdc 已连，`192.168.3.146:39933`）日志复现，同一批 34 个飞鸟云节点连续四轮：

```
19:39 measured=0  timeout=32
19:45 measured=0  timeout=32
19:50 measured=1  timeout=31
19:59 measured=3  timeout=29   ← 全是 hysteria2，UI 一片「超时」
```

对照：同一台机器、同一时刻 ikuuu 46 节点 `measured=45~46`、吹雪云 24 节点 `measured=13~23`。
即「引擎/网络/通道」正常，只有飞鸟云整批失败。

## B. 关键取证：pin 里的 IP 全是死的

`ConnectionOrchestrator` 在生成配置前把代理服务器域名 DoH 预解析结果写进 YAML
`hosts:`（防明文 DNS 投毒）。故障当时落盘的 pin（取自 live 配置 `hosts:`）：

| 域名 | pin 里的 IP | 当时真实 DNS | 旧 IP 状态 |
|---|---|---|---|
| sg02.459292.xyz | 13.228.124.169 | 18.141.49.209 | 100% 丢包 |
| sg03.459292.xyz | 3.1.16.214 | 13.229.167.155 | 失效 |
| us03.459292.xyz | 35.163.34.69 | 35.160.247.51 | 失效 |
| 27add0b5.344211.cc | 13.114.197.122 | 16.76.77.39 | 失效 |
| rdfhvcabfq.130239.xyz | 54.191.44.242 | 16.146.191.17 | 失效 |

而 `sg01`（pin=13.213.80.180）恰好仍有效 → 它那几个节点仍能测出 305/389/565ms。
**「哪些节点能测出来」与「pin 是否还是当前 IP」完全对应。**

DNS TTL 实测（doh.pub / alidns / 运营商 / 1.1.1.1 一致）：这些入口域名 **60~120s**，
且解析结果会轮换到另一台 AWS 实例。旧实现按固定 **3h 新鲜 / 6h 可用** 计时，
与记录 TTL 无关 → 2 分钟后就变味的 IP 被 `hosts:` **永久覆盖**整条连接生命周期，
内核每次拨号都打向死地址，5s 无应答 → `504` → UI「超时」。

## C. 实验矩阵（同一份 YAML、同一个内核二进制 `mihomo-smart-8d4c8c70`）

PC 上直接跑 `mihomo-build/.../mihomo.exe -f <设备导出的测试配置>`，只改 `hosts:`：

| 变量 | 新加坡02aws | 结论 |
|---|---|---|
| 带故障时 pin（13.228.124.169） | `503` ×3，每次 5.0s | 复现「超时」 |
| pin 改成当前解析值（18.141.49.209） | `200 / 164·178·330ms` | 立刻正常 |
| **整段删除 `hosts:` pin** | `200 / 155~250ms`（28/34 节点） | 与 FlClash 口径一致 |

设备侧同样：34 节点批控 `measured` 0~4 → 修后 14~17；串行逐测 19/34（PC 同配置 14/34，
设备反而更好）→ 剩余失败是节点侧/公告类伪节点，不是客户端。

## D. 修复（`DoHResolver.ets`，`LatencyEngine.ets`；已 `hvigorw assembleHap` 通过并装真机）

1. **pin 寿命改由 DNS TTL 决定**：`lifetime = min(answerTTL, 60min)`；
   **TTL < 10min 一律不 pin**（机场入口域名 60~300s 全部落在此档）→ 交给内核按 TTL
   现解析（内核 DNS 缓存按 TTL 过期，与 FlClash 同口径）。
2. **短 TTL 结论保留 30min**：同一进程内不再重复发 DoH 查询，连接路径预算不被打穿。
3. **持久化改三段式 `ip|resolvedAt|lifetimeMs`**；旧版两段式（没有 TTL 依据）加载即弃，
   并立刻重写一次把脏 pin 洗掉 —— 覆盖「升级后仍带着坏 pin」的场景。
4. **超时自愈**：节点在内核通道被判 `TIMEOUT` 时 `DoHResolver.dropPin(node.server)`，
   下一批生成配置不再写该 `hosts`，避免 pin 继续毒害后续批次。

真机验证（装包后冷启动，`doh_pins_json` 里仍是旧版脏数据）：

```
DoHResolver: doh pin cache: dropped 58 legacy/short-ttl entr(ies)
ConnectionOrchestrator: DoH pinned 0/70 proxy servers        ← 飞鸟云短 TTL 域名全部不 pin
LatencyEngine: latency batch done nodes=34 measured=17 timeout=15 failed=2   ← 修前 0~4
LatencyEngine: latency batch done nodes=46 measured=44 timeout=2              ← 其它订阅未回归
```

## E. 回归套件

- `scripts/verify-doh-cache-runtime.mjs`（真跑 resolver + 虚拟时钟）**15/15**：
  新增「短 TTL 不 pin/不落盘/不进 hosts」「短 TTL 结论保留期」「旧两段式脏 pin 加载即弃」
  「dropPin 落盘」「TTL 再长也只 pin 到 60min」。
- `scripts/verify-latency-engine-runtime.mjs`（真跑引擎）**22/22**：
  新增「超时节点会丢弃其入口域名 pin，且只丢超时那几个」。
- 其它：`verify-latency-cache` 61/61、`verify-latency-display` 19/19、
  `verify-mihomo-alignment` 102/102、`verify-proxy-name-uniqueness` 15/15。
- 已知**既有**失败（与本次改动无关）：`verify-vpn-architecture` 缺 `pages/RulesPage`
  （1 条）、`verify-types` 的 tsc 报错全部来自 SDK 自带 `@ohos.annotation.d.ets`
  （项目源码 0 错误）。

## F. 教训（写给下一个人）

**「防投毒」类优化必须与记录自身的生命周期对齐。** `hosts:` 是永久覆盖，
把每小时轮换多次的入口域名钉进去，等于把「防投毒」变成「稳定投毒」；
而它表现出的症状（整屏超时）看起来完全像节点死光或网络不通，
上一轮排查就是因此把 ikuuu 的「单入口 IP」误判成飞鸟云的死因。
