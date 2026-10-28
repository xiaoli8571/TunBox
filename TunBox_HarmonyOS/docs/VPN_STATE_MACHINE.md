# TunBox VPN 状态机（正式定义）

> 版本：2026-10-27 · 适用：`ConnectionOrchestrator.ConnState`
> 本文是**契约**：任何新增路径（自动重连、冷启动恢复、卡片/快捷方式唤起、核被杀）
> 都必须落在下表的允许转换里；不在表内的转换视为缺陷。

## 1. 状态定义

| 状态 | 值 | 含义 | UI 表现 |
|---|---|---|---|
| `DISCONNECTED` | 0 | 无会话：隧道未建立或已确认终止 | 未连接，可点连接 |
| `CONNECTING` | 1 | 单航班进行中：生成配置 → 拉起扩展 → 等内核就绪 → 钉选 | 「正在连接…」 |
| `CONNECTED` | 2 | 内核在跑且出口已确认（`KernelSelectionManager` 有叶子目标） | 已连接 + 节点名 |
| `DISCONNECTING` | 3 | 用户主动断开，等待扩展退出/清理工件 | 「正在断开…」 |
| `RECOVERING` | 4 | 会话仍应存在，但正在修复（核被杀 / 网络切换 / 自愈重建） | 「正在恢复…」 |

## 2. 允许的转换

```
DISCONNECTED ──connect()──────────────► CONNECTING
CONNECTING   ──成功(pin 确认)─────────► CONNECTED
CONNECTING   ──失败/取消──────────────► DISCONNECTED
CONNECTING   ──失败但隧道仍在─────────► RECOVERING   （不得谎报成功）
CONNECTED    ──disconnect()───────────► DISCONNECTING
CONNECTED    ──核无响应/网络切换──────► RECOVERING
DISCONNECTING──清理完成───────────────► DISCONNECTED
RECOVERING   ──重建成功───────────────► CONNECTED
RECOVERING   ──重建失败───────────────► DISCONNECTED
```

## 3. 禁止的转换（缺陷判据）

| 禁止 | 后果 | 现行防线 |
|---|---|---|
| `CONNECTING → CONNECTED` 但内核出口未确认 | 「UI 已连接、实际没网」 | 钉选阶段必须拿到 `ConnectionTarget`；拿不到就 `throw`（B9 门禁） |
| `CONNECTED → CONNECTED`（重入） | 双扩展实例/TUN 冲突 | `connectExclusive` 单航班 + `connectSeq` 代际校验 |
| 任意 → `CONNECTED` 而 `state` 早已过期 | 旧会话覆盖新会话 | `isRuleSessionCurrent(seq, generation)` |
| `DISCONNECTING → CONNECTING` | 清理未完成就重连 | 断开路径先等扩展退出（超时降级） |
| `RECOVERING → CONNECTED` 而内核未就绪 | 假恢复 | 恢复路径复用同一钉选/就绪判据 |

## 4. 触发源（谁可以改状态）

| 触发源 | 允许改到 | 入口 |
|---|---|---|
| 用户点连接 | `CONNECTING` | `HomePage` → `orchestrator.connect()` |
| 用户点断开 | `DISCONNECTING` | `orchestrator.disconnect()` |
| 通知栏/卡片/快捷方式 | 同上（与 UI 同一条 API） | `QuickToggleAbility` / `VpnQuickStart` |
| 网络状态变化 | `RECOVERING` | `NetworkStateWatcher` → `requestReconnect(reason)` |
| 核被杀/自检失败 | `RECOVERING` | `pollRuntimeLiveness` / `[health]` |
| 进程冷启动 | `DISCONNECTED`（然后按持久化意图恢复） | `EntryAbility` → `VpnQuickStart` |

## 5. 不变量（Invariants）

1. **单一事实源**：「当前节点」只能来自 `KernelSelectionManager`（内核 `/proxies`），
   `settings.preferredNode*` 仅是用户偏好缓存。
2. **单航班**：同一时刻最多一个 `CONNECTING`/`RECOVERING` 流程（`reloading`/`connecting` 互斥位）。
3. **代际**：任何异步回调落地前必须校验 `connectSeq`/`sessionGeneration`，过期即丢弃。
4. **不谎报**：没有可确认出口时不得进入 `CONNECTED`，宁可 `throw` 让 UI 显示失败。
5. **可恢复**：进入 `CONNECTED` 前必须已完成「配置提升（config promoted）」，
   否则下次冷启动没有可用原文（`mihomo_config.yaml`）。

## 6. 与日志的对应关系

| 日志 | 状态含义 |
|---|---|
| `connect timing: prep/prelaunch/launch/ready/pinned/total` | `CONNECTING` 各阶段耗时 |
| `connection target: <组> → <节点> source=<user|kernel|yaml>` | 即将进入 `CONNECTED` |
| `config promoted: kernel accepted …` | 配置已提升，冷启动可复用 |
| `pin failed … / 节点选择未生效` | `CONNECTING` 失败，**不得**进入 `CONNECTED` |
| `exit changed on kernel: …` | `CONNECTED` 内出口漂移，已同步偏好与 UI |
| `[reconnect] <reason>` | `RECOVERING` 的触发原因 |
| `[health] repair restart-core` | `RECOVERING` 的修复动作 |

## 7. 待办（未完成项，勿当作已实现）

- `ReconnectReason` 尚未收敛为枚举：目前仍存在 `reason + '-retry'` 之类的字符串拼接。
- 状态转换尚未用运行时断言强校验（当前靠单航班位 + 代际校验隐式保证）。
