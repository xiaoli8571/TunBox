# 延迟测试重做 —— 真机实证（5.6.0）

设备：MLR-AL00（HarmonyOS NEXT，1600×2560），`hdc` 无线连接 `192.168.3.146:39933`。
被测代码：5.6.0（`AppScope/app.json5` versionCode 50600），**与本轮发布产物同一份模块代码**。

## 0. 怎么装上去的（这条本身就是个坑）

发布产物是 **store profile（`TunBoxRelease.p7b`）** 签名，`hdc install` 直接失败
`9568322`；用户只能用 DevEco Run 装。但 `build-profile.json5` 的 `default` product
用的是 **debug 签名配置**（`keyAlias = "debugKey"` + `~/.ohos/config/default_*.p7b`），
而 debug profile 是**可以 hdc 安装的**：

```powershell
# 同一个 product、同一个 buildMode=release，只是签名走 default（debug）配置
node hvigorw.js --mode module -p module=entry@default -p product=default `
     -p buildMode=release assembleHap --no-daemon
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
# -> install bundle successfully
```

关键点：`buildMode=release` 保证优化后的模块代码与发布产物一致 ——
`entry-default-unsigned.hap` 与发布用的 unsigned hap 是**同一个** SHA256
（`791EA885…`）。所以下面的真机结论对发布产物同样成立，差别只在签名档（
store vs debug），而签名档不影响运行时行为。

> 结论（可复用）：**要在真机上验证 store-profile 包的行为，用 debug 签名重打一份
> release 构建即可**，不必等用户装。这解开了本任务"真机实证"的死结。

## 1. 通道选择：已连接时复用隧道内核，**不拉起无头测速内核**（核心设计）

连接 VPN 后在节点页测速，hilog 原文：

```
ConnectionOrchestrator: latency channel: reusing connected tunnel controller
LatencyEngine: latency batch start nodes=59 concurrency=8 timeout=5000ms force=true
               channel=core url=https://www.gstatic.com/generate_204
LatencyEngine: latency batch done nodes=59 channel=core measured=51 timeout=5 failed=2
               cancelled=0 skipped=0 notReady=1 unavailable=false elapsed=13144ms
```

- `reusing connected tunnel controller` = 走了 `ensureLatencyApi()` 的第 1 条路径，
  **没有启动 headless 测速内核**（这是本次重做要替换的"笨重方案"）。
- `channel=core` = 走真实内核；`url=https://...` = HTTPS 测试地址。
- `notReady=1` 且 `unavailable=false`：单个通道类失败被正确归类，**没有**把整批作废、
  也**没有**把它写成节点结论。

## 2. 快：59 节点 13.1s / 106 节点约 12s

- 上条日志：59 节点 `force=true` 全测 **13.14s**（concurrency=8, timeout=5000ms）。
- 另一次「全部」tab（106 节点，含 3 个订阅）轮询观测：进度 30→72→89→94→96→103，
  即 **~12s 推进 73 个节点**。

## 3. 准：五态在真机上可区分

节点页实际渲染（UI dump 提取）：

| 状态 | 真机呈现 | 颜色 |
|---|---|---|
| 实测（快） | `20ms` `21ms` `23ms` | 绿（<180） |
| 实测（慢） | `478ms` `481ms` `522ms` | 琥珀（≥350） |
| 超时 | `超时` | 红 |
| 失败 | `失败 4 次` + `成功率 100%` | 红 |
| 未测 | `--` | 中性 |

排序：实测按延迟**升序**排在最前（20,21,23,24,24,24,26,26,28,36,41,45,47,48…），
失败/超时节点在列表**末尾** —— 与设计一致，**失败永不排最前**。

## 4. 可取消：取消后不留转圈、不伪造结论

点击运行中的「取消」后，头部从「取消 + 进度」变回「测全部」，且：

```
LatencyEngine: latency cleanup: 6 node(s) left TESTING -> untested (cancelled=true unavailable=false)
```

- 这条日志是 **round 1 修复的直接真机证据**：被打断的 6 个节点由
  `LatencyEngine.clearOwnTestingMarks()` 收回「未测」，否则它们会**永久转圈**。
- 取消后列表里被打断的节点显示 `--`（实测统计：`ms=14, 超时=0, 失败=0, --=1`），
  **没有任何节点被写成失败或超时**。

## 5. 可持久化：重启后仍在，落盘内容可在设备上直接验证

`preferences/tunbox_settings` → `app_settings_json.nodeSortSnapshot`（真机原文解析）：

```
testedAt: 2026/9/19 16:31:56 | mode: auto
records: 106 | measured(>0): 89 | failed(-1): 17 | untested(-2): 0
失败样例: {"name":"🇯🇵 日本Z05 | 下载专用 | x0.01","latency":-1,"failCount":4,
          "lastOk":false,"failKind":"timeout"}
          {"name":"🇯🇵 免费-日本1-Ver.7","latency":-1,"failCount":4,
          "lastOk":false,"failKind":"network_unreachable"}
```

- 106 条记录、89 实测 / 17 失败，**真实 `failKind`（timeout / network_unreachable）**
  与 `failCount` / `lastOk` 都落盘了。
- `aa force-stop` 后冷启动，节点页仍显示同一批数值（20/21/23/24ms…），主页也直接
  渲染所选节点的延迟（`NodeSortSnapshot.fromJsonText(settings.nodeSortSnapshot)`）——
  **重启后无需重测即可看到上次结果**。
- 再次实测同一节点复现同值（香港Z03 20→22ms、香港Z09 21→18ms、香港Z02 23ms），
  数值稳定、非随机。

## 6. `force=false` 的跳过确实生效（省拨号）

```
latency batch start nodes=59 ... force=false channel=core
latency batch done  nodes=59 ... measured=0 timeout=0 failed=2 cancelled=6 skipped=51
```

`skipped=51` = 59 个节点里 51 个是 5 分钟内的新鲜结果，**没有重新拨号**；
只有 8 个真的探测了。这正是"结果可持久化"带来的直接收益。

## 7. 本次**没有**在真机上验证到的

| 项 | 原因 |
|---|---|
| 离线兜底通道（`channel=offline`，`≈ms`） | 设备上 `ensureTestCore` 总能成功，无法在不改代码的前提下强制它失败 |
| 环回/内网节点被跳过（`isLoopbackOrLocal`） | 该订阅里没有环回/内网服务器节点 |
| store-profile 发布包本身 | 本地装不了（9568322）；已验证其模块代码与 debug 签名包逐字节相同 |

截图证据（**未入库**，含用户订阅节点名，仅本地留存）：
`evidence-node-page-top.png`（升序实测 + 绿色徽标 + 成功率）、
`evidence-cancel-running.png`（进度条 + 30/59 + 取消）。
