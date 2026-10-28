# 切换订阅（只点订阅名）后「选中节点 / 当前连接节点 / 主页」三处不一致

- 日期：2026-10-28
- 影响版本：0.6.8 之后的手动选节点模式
- 关联计划：`docs/TUNBOX_ARCHITECTURE_REMEDIATION_PLAN_2026-10-28.md`（P1 连接正确性）

## 现象

已在 Nexpanel 订阅内手动选择节点并连接（订阅页勾选 = Nexpanel 节点、主页显示同节点）。
此时**只点击另一个订阅（吹雪云）的标题**、不点它下面的任何节点：

- 订阅页：勾选跑到吹雪云的节点上（`当前连接节点` 卡片仍是 Nexpanel 的）；
- 主页：仍显示 Nexpanel 的节点；
- 实际出口：内核已按新 profile 重载，旧节点名在新配置里不存在。

三处互相矛盾，用户无法判断「到底在用哪个节点」。

## 根因（两处叠加）

### ① 手动模式切订阅只做热重载，不重锚出口

`ConnectionOrchestrator.ensureProfileApplied()` 里，是否完整重连由
`shouldFullReconnectOnProfileSwitch()` 决定，而它的判据只有一条：

```ts
return settings.autoSelectMode === AutoSelectModes.AUTO;
```

手动模式下切 profile → 走 `applyRulesChanged()`（热重载 / `PUT /configs`）。
热重载刻意不拆隧道，但它**保留的是旧配置的钉节点**。新 profile 里没有这个节点名，
内核只能自己另挑一个；而 App 侧 `ConnectionTarget` 仍写着旧订阅的节点名
（`kernelSelection` 没有人在热重载路径上更新它）→ 主页 / `当前连接节点` 一直是旧订阅。

即：**跨 profile 的钉节点在物理上不可能成立**，但代码路径允许它"看起来成立"。

### ② 订阅页复选框读的是「偏好」，不是「出口」

`SubscriptionPage.activeNodeName()` 的取值顺序是
`activeNodeId`（页面态）→ `settings.preferredNodeName`。
而 `activateProfile()` 在切 profile 时会先调用 `restoreRememberedNode(id)`，
把偏好三件套（`preferredNodeId/Name/SubscriptionId`）改写成**新订阅**记住的节点。

于是本页立刻把勾画到新订阅的节点上 —— 但此时出口并没有换（见 ①），
偏好只是「用户意图」，它无权回答「现在连的是谁」。

## 修复

### ① 出口必须属于新 profile，否则重新拨号

`shouldFullReconnectOnProfileSwitch(profileId)` 增加第二条判据（不再只看模式）：

- 自动选择模式 → 完整重连（原行为，意图是让内核按新订阅重新优选）；
- 手动模式 → **出口节点不属于新 profile 时**必须完整重连；仍属于则保持热重载
  （不打断用户正在用的固定节点）。

判定按**节点名 + 订阅作用域**（`exitBelongsToProfile()`），不比 id：
内核影子节点 id 是 `core:<name>`，与解析节点 id 不同，名字才是跨数据源稳定标识。
出口记录缺失（无 `ConnectionTarget` 且 `lastNodeName` 为空）时按"不属于"处理，
重连一次把事实落定，而不是让显示层继续挂旧值。

重连目标仍由 `reconnectForProfileSwitch()` 解析：`resolvePreferenceHint()`
（此刻已被 `restoreRememberedNode` 改写为新订阅记住的节点）→ 回落该 profile 的
`fallbackConnectionNode()`，两者都强制 `subscriptionId === profileId`。

### ② 连接期间显示层只认 `ConnectionTarget`

`SubscriptionPage.activeNodeName()` 改为：

1. `state` 为 `CONNECTED`/`CONNECTING` 且 `getCurrentConnectionTarget().nodeName` 非空
   → 返回它（与主页、顶部同一真源）；
2. 否则回退 `activeNodeId` → `preferredNodeName`（未连接时偏好才代表意图）。

这样即使重连失败（拿不到可拨号目标、回落热重载），复选框也只会显示**真实出口**，
不会出现"勾着 A、实际走 B"。

## 验证

- `verify-arkts-compile.mjs` 3/0（含真实 assembleHap）
- `verify-vpn-architecture.mjs` 313/0
- `verify-no-divergence.mjs` 14/0
- `verify-stability-remediation-runtime.mjs` 31/0
- `verify-event-driven.mjs` 21/0
- `verify-sub-node-two-row.mjs` 55/0
- `verify-all.mjs`：全部通过（仅白名单 `verify-subscription-fidelity.mjs`）
- 真机（`192.168.10.7:39933`，debug 签名）：连接 Nexpanel 节点后点吹雪云标题 →
  自动重连到吹雪云节点，订阅页勾选 / `当前连接节点` / 主页三处一致。

## 教训

- **"能否热重载"是配置层问题，"钉住的出口是否还成立"是事实层问题**，
  两者不能共用同一个模式开关做判据。模式回答的是"用户想要什么"，
  节点归属回答的是"这个出口还存在于新配置里吗"。
- 偏好（`preferred*`）只表达意图。任何**已连接**状态下的"当前节点"显示，
  都必须从 `ConnectionTarget` / 内核真源取；否则一次偏好的写入就会让 UI 说谎。
- 只点订阅标题也是"换 profile"这一事实变更，它的副作用必须和"手动选节点"对齐
  （重建隧道），否则用户必须手动断开再连才能生效。
