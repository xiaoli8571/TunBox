# 节点选择 / 当前节点显示 / 连接启动 全链路（2026-10-28 收口）

> 起因：用户报障「**当前订阅内改选节点不生效**，只有**已连接状态下**在线切换才生效；
> 切订阅时第一次选中的节点会被一直沿用」。
> 本文把这条链路**从点下去到内核真的换出口**完整画一遍，标出真源、闸门与该次修复点。

---

## 0. 一句话结论

节点这条链上有**两类状态**，2026-10-27 已把「谁是当前出口」收口到内核，但
**连接阶段**还留着一处逐字节比较 + 一处静默回落，于是在「未连接时改选节点」这个
场景里，内核的**旧出口**（store-selected）把用户的**新选择**盖掉了。

| 状态 | 载体 | 生效范围 |
|---|---|---|
| 用户偏好（勾选、未连接时的显示、连接初始提示） | `AppSettings.preferredNodeId / preferredNodeName / preferredNodeSubscriptionId / preferredNodeNamesBySubscription` | 只是**缓存**，可被纠正 |
| 当前真实出口 | 内核 `/proxies` → 规则组 `now`（`profile.store-selected: true`） | **唯一真源**（已连接时） |
| 本次会话认定的出口 | `KernelSelectionManager.current()` → `ConnectionTarget` | 进程内，带 `profileRevision` / `generation` 防迟到写回 |

---

## 1. 用户点一个节点（未连接）

`SubscriptionPage.selectNode(node)`

1. 退出 `AUTO` → `MANUAL`（用户显式选择必须压过智能选点）。
2. `activeNodeId = node.id`（支持 `core:` 影子 id）。
3. `SettingsService.patchSettings` 一次写入：
   - `preferredNodeId` / `preferredNodeName`
   - `preferredNodeSubscriptionId`（**归属订阅**，跨订阅防串味的关键）
   - `selectedSubscriptionId`
   - `preferredNodeNamesBySubscription`（按订阅分槽记名字，刷新重排后按名字 re-anchor）
4. `refreshDisplayNode()` → `orchestrator.getCurrentNodeName()`。

此时**没有**内核参与：未连接时内核里没有本次配置，`displayNodeName()` 只能读偏好。

## 2. 当前节点显示（`ConnectionOrchestrator.getCurrentNodeName`）

```
displayNodeName(preferredNodeId, autoMode)
├─ AUTO + 智能选点            → SMART_GROUP_NAME
├─ CONNECTED 且 liveName ∈ 当前节点表 → liveName      ← 已连接一律信内核
├─ resolveUserPreference(id, name)                     ← 未连接读偏好
│    ├─ 名字在当前 profile 内精确命中 → 用它
│    └─ 否则按 id，且必须属于当前 profile，否则 null
├─ fallbackConnectionNode()                            ← 当前订阅第一个可用节点 / 订阅默认出口
└─ ''
```

`SubscriptionPage.activeNodeName()` 与 `HomePage.refreshDisplayNode()` 都走同一口径：
**已连接/连接中** 用 `orchestrator.getCurrentConnectionTarget()`，否则按
`activeNodeId` → `preferredNodeName` 递降。不允许在已连接时拿偏好当「当前节点」渲染
（2026-10-27 事故：UI 显示香港、内核走新加坡）。

## 3. 点「开启连接」（真机症状的分叉点）

`HomePage.toggleConnection()` → `selectedNode()` = `subs.resolvePreferenceHint() ?? fallbackConnectionNode()`
（`VpnQuickStart` 同口径）→ `orchestrator.connect(node)`。

`resolvePreferenceHint()` 三条路：

| 情况 | 行为 |
|---|---|
| id 命中 + 属于当前订阅 + 名字与快照一致 | 直接用 |
| id 悬空但 `preferredNodeSubscriptionId` 仍是当前订阅 | 按**名字**在当前订阅重锚，写回 `preferredNodeId` |
| 属于**别的**订阅 | `null`（绝不跨订阅按名猜），交给 `fallbackConnectionNode()` |

`fallbackConnectionNode()` 只在本订阅内取节点（排除 `NodeUsability.isInfoEntry` 的信息条目）；
整份 profile 只有默认出口时给合成节点 `profile:<current>`「订阅默认出口」。

## 4. 连接启动：配置生成（`RuntimeConfigBuilder.buildRuntimeConfig`）

唯一配置入口（隧道核 / 测速核 / 热重载都走它）：

1. `resolveSelectedNode(profile)`：`profile.selectedNodeName` 精确 → 忽略大小写 → **回落 `profile.nodes[0]`**。
2. 生成 YAML（含 `proxies` / `proxy-groups` / `rules`，规则指向的组名是机场自命名的 select 组）。
3. `resolvePinTarget(finalYaml, preferredName)` → `ConnectionTarget{groupName, nodeName, source, matched}`：
   找到规则实际指向的 select 组 → 优先该组直接成员 → 全部 proxies：
   精确 → 归一化 → 地区关键词 → 组内首个叶子 → 任意叶子。
   - `source = USER` 仅当逐字节相同；地区自愈/首叶子是 `YAML`。
   - **新增 `matched`**：按归一化名判「是不是同一个节点」。地区自愈/首叶子 `matched=false`
     —— 它们是**替身**，不是用户意图。
4. 结果回填 `RuntimeConfigResult.pinMatched`。

## 5. 连接启动：钉选（`connectExclusive`，真机 bug 的现场）

修复后的次序（**用户意图 > 内核旧出口**）：

```
kernelSel = api.readKernelSelection(built.ruleGroupName)     // 规则组真实成员 + now
intentLive = built.pinMatched && target.name != ''           // 用户意图是否真的在配置里

① kernelLeafFor(kernelSel.leafMembers, intentLive ? target.name : effectiveName)
   命中 → PUT 该名字（**内核里的真实名字**，精确 → 归一化）
② 未命中且 pinTargetName 非空 → PUT pinTargetName（本次配置里的目标）
③ 仍未钉上 且 !intentLive 且 kernelSel.nowIsLeaf → 认内核 now（跳过 PUT）
      并仅当 target.name === ''（用户本就没选）时 selfHealPreferredNode 回写偏好
④ 仍未钉上 → 同订阅候选逐个试钉（≤8 个 / PIN_PHASE_BUDGET_MS），
      仅 !intentLive 时回写偏好
⑤ 仍失败 → 预算内退避重试 → fail-fast
```

注入前置（`buildRuntimeConfig` 内）：若 `!resolvedPin.matched` 且该节点在 `proxies` 里，
调 `ProfileConfigMerger.ensureGroupMember` 把它**补进规则组首位**，再重新解析一次
（`pinMatched` 可能因此变 true）。补不进去就只告警，交给 ①–⑤ 降级。

---

## 6. 根因（本次修复）

### R1 逐字节比较内核成员名 → 误判「用户选的节点不在组里」

旧代码：

```ts
for (const leaf of kernelSel.leafMembers) {
  if (leaf === target.name) { userPickValid = true; break; }
}
```

App 侧节点名与内核里的名字只要差一个 emoji / 空格 / 分隔符，就判 `false`，
于是**跳过用户选择**，直接落到「认内核 `now`」分支 —— 而 `now` 是 store-selected
记下的**上次那个节点**（用户描述里「切订阅时第一次选中的节点」）。

→ 修：`RuntimeConfigBuilder.kernelLeafFor()`（精确 → 归一化），PUT 用内核真实名字。

### R2 认内核旧出口没有「意图闸门」

旧代码：任何 PUT 未成功就无条件认 `now`。用户刚选的新节点因此被旧出口覆盖，
且 `selfHealPreferredNode` 还把旧出口写回偏好 —— 勾选被静默改掉，用户会觉得
「App 在跟我抢控制权」。

→ 修：`intentLive` 闸门。有意图 → 不认旧出口、不回写偏好、如实打日志。

### R3 组内首叶子静默顶替（香港 → 日本）

机场的规则组常只列**一部分**节点。用户选中的节点在 `proxies` 里、App 里看得到，
但不在组成员表 → `PUT /proxies/<组>` 必 400 → `resolvePinTarget` 退回「组内首个叶子」，
`effectiveName !== target.name`，旧代码顺手把偏好改成那个叶子。

→ 修：`ProfileConfigMerger.ensureGroupMember()` 把它补进组首位（与生成器 `unshift`
同语义）；`effectiveName !== target.name` 的偏好改写加 `!built.pinMatched` 闸门。

### 为什么「已连接状态下在线切换节点」是好的

在线切换走的是另一条路（`switchNode` 直接 PUT 内核 + `KernelSelectionManager.set`），
不经过 `connectExclusive` 的「配置生成 → 钉选」编排，因此完全绕开了 R1/R2/R3。

---

## 7. 不变量（改动时不得破坏）

1. `preferredNode*` 只是偏好缓存；已连接时的「当前节点」只能来自 `ConnectionTarget`（内核 `now`）。
2. 跨订阅绝不按名猜节点；`selfHealPreferredNode` 未匹配时**不得清空** `preferredNodeId`（否则勾选变空）。
3. 钉选目标必须从**最终 YAML** 解析（组名 = 规则指向的 select 组，节点名还原 `\U0001F1ED…` 转义）。
4. 意图落地判定一律**归一化**比较；替身（地区自愈/首叶子）不算意图。
5. 用户意图存在时，任何路径都不得改写偏好，也不得用内核旧出口顶替。
6. 任何 YAML 改写失败必须原样返回（内核对同层重复键是**整份拒载**）。

## 8. 门禁

```bash
node scripts/verify-node-selection-logic.mjs        # 22 项（含真跑 ProfileConfigMerger）
node scripts/verify-vpn-architecture.mjs            # 313
node scripts/verify-config-generation-integrity.mjs # 131
node scripts/verify-preference-cache.mjs            # 38
node scripts/verify-event-driven.mjs                # 21
node scripts/verify-config-single-source.mjs        # 42
```

真机验收口径（复现报障路径）：
未连接 → 订阅页在同一订阅内把节点从 A 改选为 B → 回首页连接 → 内核
`/proxies/<规则组>.now` 必须是 B；UI 当前节点必须是 B；hilog 不应出现
`pin adopted kernel selection` / `auto-pinned ... instead`。
