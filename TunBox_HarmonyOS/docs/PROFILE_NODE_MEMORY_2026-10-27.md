# 切订阅后还原上次选中的节点（2026-10-27）

## 现象

用户报障：在「吹雪云」选了 `新加坡01` → 切到「飞鸟云」选了 `日本01` → 再切回
「吹雪云」时没有回到 `新加坡01`，而是该订阅里第一个可用节点（感知为随机选点）。

## 根因

节点偏好只有一份全局三件套：

- `AppSettings.preferredNodeId`
- `AppSettings.preferredNodeSubscriptionId`
- `AppSettings.preferredNodeName`

切订阅后这份偏好指向**上一家订阅**的节点，`SubscriptionService.preferredNodeInCurrentProfile()`
/ `resolvePreferredNode()` 按「跨订阅不许猜」判无效，调用方回落
`fallbackConnectionNode()`（当前订阅第一个可用节点）。于是每切一次订阅，上一家的
选择就被覆盖，切回来自然回不到原节点。

## 修复

新增按订阅分槽的记忆：`AppSettings.preferredNodeNamesBySubscription`
（JSON：订阅 id → 节点名；只存名字，解析表 id 刷新后会漂移）。

写入：
- 订阅页手动选点（`SubscriptionPage.selectNode`）
- 节点页手动选点（`NodeSelectionPage.selectNode`，该页当前无导航入口，保持口径一致）
- 订阅刷新重锚（`SubscriptionService.reanchorPreferredAfterReplace`）
- 删除节点时只清对应订阅的那一条（`forgetPreferredNodeName`）

还原：
- 切订阅前（`SubscriptionPage.activateProfile`，先还原再 `ensureProfileApplied`，
  自动模式完整重连 / 手动模式热重载都会拿到正确目标）
- 订阅页冷启动（`bootstrap`）
- 首页冷启动兜底（`HomePage.bootstrap` → `restoreRememberedNodeForCurrentProfile`）
- 连接路径兜底（`SubscriptionService.resolvePreferredNode` 跨订阅分支）

记住的节点已下架/改名 → 不还原，保持旧行为（回落第一个可用节点）。

## 验证

- `node scripts/verify-types.mjs`：PASS
- `node scripts/verify-arkts-compile.mjs`：CompileArkTS 无错误、assembleHap 成功
- `node scripts/verify-vpn-architecture.mjs`：313 passed / 0 failed
- `node scripts/verify-site-routing.mjs`：58 passed / 0 failed
- 新增单测：`preferred_node_memory_is_scoped_per_subscription`（LogicTest.ets）

真机装包验证未执行：本机 hvigor 产物为 unsigned HAP，签名材料（`NEXUS_KEY_PASSWORD`
+ AGC 证书）不在本会话可用范围内。
