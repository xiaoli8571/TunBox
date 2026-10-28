# TunBox HarmonyOS 架构整改总方案（2026-10-28）

## 目标

本方案不是修复单个 Bug，而是完成 TunBox 从“已经可用”向“长期稳定、高性能、极简、可持续演进 VPN 客户端”的最终收敛。

当前状态：

- 节点选择错乱问题基本解决
- Kernel 真源已建立
- ConnectionTarget 已建立
- ConnectionEvents 已引入
- UnifiedScheduler 已引入
- KernelSelectionManager 已引入
- 状态机文档已建立
- 门禁基本全绿

当前主要风险已经从功能正确性转移到：

1. 架构复杂度
2. 超级类膨胀
3. 新旧体系并存
4. 长期维护成本
5. 状态机约束仍未完全运行时化

---

# Phase 1（已完成，持续验收）

## 连接正确性收敛

目标：

- Final YAML 成为配置事实源
- Kernel /proxies 成为运行事实源
- ConnectionTarget 成为应用层事实源

验收标准：

- UI 节点 == Kernel 节点
- ConnectionTarget == Kernel 节点
- 冷启动无漂移
- 重连无漂移
- 切订阅无漂移

状态：已基本完成。

---

# Phase 2（已完成，持续验收）

## Settings 并发写治理

目标：

彻底消灭：

```text
load()
修改
save()
```

模式。

统一改为：

```text
patchSettings()
```

收益：

- 避免覆盖并发写入
- 避免页面覆盖后台状态
- 避免恢复逻辑覆盖连接逻辑

保留 save() 的唯一场景：

- Backup Restore
- Whole Replace
- 初始化

---

# Phase 3（最高优先级）

## 拆分 ReconnectManager

现状：

ConnectionOrchestrator 仍持有：

```text
requestReconnect
reconnectTimer
reconnectAttempts
ReconnectReason
```

目标结构：

```text
ReconnectManager
```

负责：

- 网络恢复
- 网络切换
- Core Crash
- Retry Backoff
- Retry Budget
- Retry Telemetry

ConnectionOrchestrator 仅调用：

```ts
reconnectManager.request(reason)
```

禁止：

```ts
setTimeout(...)
requestReconnect(...)
```

继续散落于 Orchestrator。

验收标准：

- Orchestrator 删除全部重连状态字段
- Reconnect 生命周期完全独立

---

# Phase 4（最高优先级）

## 拆分 RecoveryManager

现状：

恢复逻辑仍然混在 Orchestrator。

目标：

```text
RecoveryManager
```

负责：

- restoreKilledSession
- Core Recovery
- Health Repair
- Snapshot Recovery
- Startup Recovery

统一入口：

```ts
recover()
```

收益：

- 冷启动恢复与连接逻辑彻底解耦
- 连接代码大幅缩减

---

# Phase 5

## ConnectionOrchestrator 瘦身

目标：

当前：

```text
5500~6000 行
```

目标：

```text
1000~1500 行
```

保留职责：

```text
connect()
disconnect()
switchNode()
getState()
```

移出：

```text
DoH
GeoAsset
RuleSet
Recovery
Reconnect
HealthCheck
LatencyCore
```

最终结构：

```text
connection/
 ├── ConnectionOrchestrator
 ├── ConnectPipeline
 ├── DisconnectPipeline
 ├── ReconnectManager
 ├── RecoveryManager
 ├── ConnectionAttempt
 ├── ConnectionStateMachine
 └── KernelSelectionManager
```

---

# Phase 6

## 状态机运行时强校验

当前：

仅文档约束。

目标：

```ts
ConnectionStateMachine.assertTransition(
  from,
  to
)
```

非法转换：

```text
记录日志
诊断上报
拒绝转换
```

禁止：

```text
CONNECTING -> CONNECTED
无出口确认
```

```text
DISCONNECTING -> CONNECTING
```

```text
RECOVERING -> CONNECTED
无 Kernel Ready
```

验收标准：

所有状态转换都经过统一断言。

---

# Phase 7

## 页面彻底事件驱动

现状：

仍存在：

```text
HomePage
SubscriptionPage
NodeSelectionPage
ConnectionsPage
```

轮询逻辑。

目标：

```text
ConnectionEvents
```

统一驱动：

事件：

```text
StateChanged
TargetChanged
TrafficChanged
ProfileChanged
HealthChanged
```

页面模式：

```ts
aboutToAppear -> subscribe
aboutToDisappear -> unsubscribe
```

删除：

```text
nodeWatchTimer
connectionTimer
connPreviewTimer
```

等状态轮询。

保留：

```text
Traffic Poll
```

但频率统一。

---

# Phase 8

## UnifiedScheduler 升级

当前：

```text
全量遍历 Task
```

未来：

```text
Priority Queue
Min Heap
```

目标：

避免：

```text
任务数增长
CPU 唤醒增加
```

统一调度：

```text
Traffic
Health
Latency
UI
```

---

# Phase 9

## PreferenceManager 抽离

现状：

SubscriptionService 中仍存在大量：

```text
remember
restore
reanchor
forget
```

逻辑。

目标：

新增：

```text
PreferenceManager
```

负责：

```text
preferredNodeId
preferredNodeName
preferredNodeSubscriptionId
preferredNodeNamesBySubscription
```

原则：

```text
Preference != Runtime
```

用户偏好永远不是运行事实源。

---

# Phase 10

## RuntimeState 收敛

目标：

建立：

```text
RuntimeState
```

统一承载：

```text
ConnectionTarget
ConnectionState
Traffic
Health
CurrentProfile
```

禁止：

```text
页面自行推导状态
```

---

# Phase 11

## 观测与诊断体系

统一事件：

```text
ConnectStarted
ConnectSucceeded
ConnectFailed
ReconnectStarted
ReconnectSucceeded
ReconnectFailed
NodeSwitched
ProfileChanged
```

统一指标：

```text
冷启动耗时
Ready耗时
Pin耗时
恢复耗时
重连耗时
```

---

# Phase 12

## 安全整改

检查：

```text
Subscription Token
API Secret
Controller Secret
Provider URL
```

要求：

```text
日志脱敏
诊断包脱敏
导出脱敏
```

禁止明文输出。

---

# Phase 13

## 自动化门禁扩展

新增验证：

```text
verify-state-machine
verify-reconnect-manager
verify-recovery-manager
verify-runtime-state
verify-event-bus
verify-no-ui-polling
```

要求：

全部进入：

```text
verify-all.mjs
```

---

# 最终目标架构

```text
ProfileRepository
        ↓
RuntimeConfigBuilder
        ↓
ConnectPipeline
        ↓
Mihomo Kernel
        ↓
KernelSelectionManager
        ↓
ConnectionTarget
        ↓
RuntimeState
        ↓
ConnectionEvents
        ↓
UI
```

原则：

1. 单一配置真源
2. 单一运行真源
3. 单向数据流
4. 事件驱动 UI
5. 最少轮询
6. 最少持久化
7. 状态机强约束
8. 用户意图与运行状态彻底分离

---

# 发布级验收标准

必须同时满足：

- 全部门禁通过
- 状态机断言零违规
- 冷启动连接成功率稳定
- Kernel 与 UI 永不漂移
- 用户断开后任何旧任务无法重连
- 页面不可见时停止高频刷新
- Settings 无并发覆盖
- 恢复链路可解释
- 重连链路可解释
- 日志无敏感信息泄漏

达到以上标准后，可视为 TunBox HarmonyOS 架构收敛完成。