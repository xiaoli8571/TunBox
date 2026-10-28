# TunBox 链路薄化改造方案（v1 · 2026-10-28）

> 目的：把「订阅解析 / 节点测速 / VPN 启动」三条链路改造成**薄链路**——App 只负责「意图 + 搬运 + 展示」，运行期的"真相"全部由内核或扩展进程产生。
> 对照基线：ClashPlus 1.2.7 静态逆向结论（见 `docs/CLASHPLUS_ALIGN_2026-10-28.md` 与逆向报告）。
> 本文只是方案，**尚未改动任何代码**。

---

## 0. 总原则（含本轮口径修正）

| # | 原则 | 具体含义 |
|---|---|---|
| **P-1** | **订阅解析必须由内核完成** | App 里不存在"解析器"这个角色。流程固定为：下载原始字节 → 落原文 → 交内核校验/加载 → 从内核读结果。`SubscriptionParser` / `UriNodeParser` **退出主链**。 |
| **P-2** | **订阅转换是独立功能，与内核解析无关** | 转换器只回答一个问题：「把非 Clash 文本变成 Clash YAML」。产物**存成原文**，此后与普通 Clash 订阅走完全相同的路径。转换器**不被**配置生成、测速、节点列表引用。 |
| **P-3** | App 只持有「意图 + 搬运 + 展示」 | 节点集、延迟、隧道状态、内核存活，全部以内核/扩展进程为准；App 只读。 |
| **P-4** | 薄化 ≠ 照抄 ClashPlus | ClashPlus 的"薄"建立在 Android 宽松后台 + `MTU 9000 固定` + 无自愈之上。鸿蒙侧的保活、网络变化重连、弱网自愈**不能砍**。 |

---

## 1. 现状体量（薄化对象）

| 模块 | 文件 | 行数 | 现状角色 |
|---|---|---|---|
| 订阅 | `commons/services/SubscriptionService.ets` | 3 947 | 拉取 + 解析 + 节点表 + 分组 + 配置原料 |
| | `commons/subscription/UriNodeParser.ets` | 782 | **App 侧解析器（拟退场）** |
| | `commons/services/SubscriptionParser.ets` | 668 | **App 侧解析器（拟退场）** |
| | `commons/flclash/SubConverter.ets` | 2 849 | 转换器（保留 → 独立化） |
| | `commons/services/YamlMerger.ets` | 3 302 | 合并节点/规则到最终 YAML |
| | `commons/flclash/ProfileConfigMerger.ets` | 903 | 原文→可加载配置的预检/合并 |
| | `commons/services/ClashConfigGenerator.ets` | 3 352 | 生成内核配置 |
| | `commons/services/SubscriptionFetchPolicy.ets` | 1 008 | 拉取策略（UA 链/重试/上限） |
| 测速 | `commons/services/LatencyEngine.ets` | 1 224 | 双通道探针 + 队列 + 分类 |
| | `commons/flclash/FlclashDelay.ets` | 869 | FlClash 等价 delay 实现 |
| | `commons/latency/LatencyStore.ets` | 694 | 结果持久化/分层 |
| | `commons/services/BackgroundLatencyService.ets` | 236 | 启动/后台测速调度 |
| 启动 | `commons/services/ConnectionOrchestrator.ets` | 5 888 | 全部编排（连接/自愈/failover/网络/保活） |
| | `vpnability/VpnExtensionAbility.ets` | 1 644 | TUN + 内核 + 心跳/状态文件 |

**合计约 26 000 行**，其中约 **7 000 行**属于"可在薄化中退出主链"的部分（见各方向收益）。

---

## 2. 方向一：订阅解析 → 内核解析（App 零解析）+ 转换独立化

### 2.1 目标形态：只有四条数据流

```
① 导入：URL / 二维码 / 文件
        → 落盘 <files>/profiles/<id>.yaml（原文，字节不改）
② 校验：coreController.validateConfig(原文)     ← 内核唯一裁决（等价 ClashPlus ActionMethod=5）
③ 加载：启动/切换 → config.yaml = 原文 + 白名单覆写层 → setupConfig
④ 展示：节点 / 分组一律读内核 GET /proxies、GET /providers/proxies
```

**转换（独立功能）**：仅出现在「添加订阅 → 转换」这一处 ——
输入分享链接 / base64 → `SubConverter` 出 Clash YAML → **存成原文** → 之后走 ②③④，与普通订阅**完全同路**。转换器不进入运行期调用链。

> 与 ClashPlus 的差别（有意保留）：ClashPlus 把"不支持格式"的裁决也完全交给内核、失败文案由 Go 回传；TunBox 仍保留「转换」这个用户可见的独立入口，因为用户明确要求"订阅转换是单独功能"。

### 2.2 P0 —— 止血：App 不再产出节点表（1–1.5 人日）

**改动点**
- `SubscriptionService.refreshSubscription()`：成功回调里**不再**写 `this.nodes` / `this.proxyGroups`；只写「原文 + 元数据」。
- 元数据保留：`lastFetchedAt`、`nodeCount`（改为**内核侧计数**）、`uploadBytes/downloadBytes/totalBytes/expireAt`（userinfo）、`etag`。
- UI 侧 `service.nodesOf()` 调用点改为 `CoreCatalogService` + `CoreNodeBridge`（这两个已在用，见 `SubscriptionSection` / `NodeSelectionPage`）。
- 信息伪节点过滤（`NodeUsability.isInfoEntry`）从「解析期过滤」改为「展示期过滤」。

**验收**
- [ ] 同一份机场订阅：App 显示节点数 == 内核 `/proxies` 中该 provider 条目数（允许 ±0）
- [ ] 断开 → 重连后节点列表不丢、顺序稳定
- [ ] 「剩余流量：xx」这类伪节点仍在列表中被隐藏（改为展示期判断）
- [ ] `verify-core-catalog.mjs` / `verify-latency-display.mjs` 全绿

**回退开关**：`parseOwner = 'kernel' | 'app'`（默认 `kernel`），一处布尔即可切回旧行为。

### 2.3 P1 —— 内核裁决 + 原文即基底（2–3 人日）

**改动点**
- 写入前统一走 `validateConfig`：不通过 → **整份拒收**并回滚旧原文（现在是"App 先解析再校验"，两份判断）。
- `ClashConfigGenerator` 改为「原文 + **白名单覆写层**」，对齐 ClashPlus `_makeRealProfileTask`：

  | 覆写白名单键 | 说明 |
  |---|---|
  | `port` / `socks-port` / `mixed-port` / `redir-port` / `tproxy-port` | 端口由 App 设置决定 |
  | `mode` / `log-level` / `ipv6` / `unified-delay` / `tcp-concurrent` / `keep-alive-interval` / `find-process-mode` / `allow-lan` | 全局开关 |
  | `tun.{enable,device,stack,mtu,dns-hijack,auto-route,route-address}` | TUN 参数（含 MTU 动态计算） |
  | `dns.*`（仅在"DNS 覆写"开启时整段替换） | 与现有开关同源 |
  | `geodata-loader` / `external-controller` / `external-ui` | 固定值 |

  其余键（含订阅自带的 `proxies` / `proxy-groups` / `rules` / `rule-providers` / `proxy-providers`）**原样保留**。
- 删除 `YamlMerger` 的**节点合并职责**（保留覆写/注入/规则拼接部分）；`SubscriptionParser` / `UriNodeParser` 移出主链。

**验收**
- [ ] 对 5 份真实订阅（Clash YAML ×3、base64 ×1、含 `proxy-providers` ×1）做 diff：生成配置与原文的差异**只出现在上面白名单键**
- [ ] 节点名 / 协议 / 参数零改写；`UUID` / `password` / `reality-opts` 逐字节一致
- [ ] `verify-config-generation-integrity.mjs` / `verify-config-single-source.mjs` / `verify-config-validator.mjs` 全绿
- [ ] 坏配置（手工破坏 YAML）导入时：整份拒收 + 旧订阅仍可用

### 2.4 P2 —— 可选：`proxy-providers` 化（3–4 人日，默认关）

- 每个订阅声明为 `type: file` 的 provider，内核自己热读；App 连"合并"都不做，只写 provider 声明与分组引用。
- 前提：内核 file provider 热重载可用 + 分组引用改造（`PROXY` / `AUTO` 由内核组承担）。
- 开关：`profileMode = 'merged' | 'provider'`（默认 `merged`）。

### 2.5 收益 / 代价

| 项 | 内容 |
|---|---|
| **退出主链** | `UriNodeParser` 782 + `SubscriptionParser` 668 + `YamlMerger` 节点合并段 ~1 800 + `SubscriptionService` 解析分支 ~800 ≈ **4 000 行** |
| **根除故障类** | "App 解析表 vs 内核目录"两套真相（你们此前"32 节点 vs 23"即此类）、"解析不出的协议被跳过导致计数偏少"、"信息伪节点/重名不一致" |
| **代价** | 订阅卡"节点数"从"精确解析值"变"内核口径"；单节点导入退化为"生成小 YAML 走原文通道"（能力保留、路径统一） |
| **风险** | 内核 `validateConfig` 对超大配置的耗时（需实测 8MB 上限下的耗时）；`proxy-groups` 引用不存在的节点时内核报错文案需映射成用户可读提示 |

---

## 3. 方向二：节点测速 → 单通道薄封装

### 3.1 目标形态

```
单节点点测：内核单点 delay（等价 ClashPlus asyncTestDelay，一次一节点）
整组/批量 ：内核组测速（一次测整组）        ← 优先路径
结果      ：只存「最后一次结论」{delay, at, failKind(3 类)}
排序      ：纯函数（视图层），引擎不再持有排序策略
```

### 3.2 P0 —— 砍双通道为单通道（1 人日）

- `LatencyChannel.OFFLINE` 降级为「连通性自检」独立入口（数据页的连通性卡片），**不再产生节点延迟结论**。
- 节点延迟结论只来自 `LatencyChannel.CORE`。

**验收**：节点行延迟永远来自内核；无连接时节点行显示「未测」而不是离线直连数值。

### 3.3 P1 —— 批量走内核组测速（1–2 人日）

- 批量/整组：优先 `BackgroundLatencyService.runKernelGroupTest()`（内核一次调用测整组）；
- 仅「单节点点测」走单次 delay（`FlclashDelay`）。
- 删除 App 侧 50 worker 调度与 `QUEUE_TIMEOUT` 分类（内核排队语义已足够）。

**验收**
- [ ] 558 个节点整组测速：一次调用完成，UI 逐批冒泡排序
- [ ] 弱网/大批量不再出现"App 侧排队超时"这一类伪失败

### 3.4 P2 —— 结果模型瘦身（0.5–1 人日）

- 结果只留 `{delay, at, failKind}`；`failKind` 收敛为三类：`TIMEOUT` / `FAILED` / `NOT_TESTED`。
- 删除 `LatencyProbeResult` 里的 `bodyText` / `httpCode` / `isVerdict` 等诊断字段（需要时改由"单节点测速详情"按需拉一次）。

**验收**：冷启动恢复延迟（`verify-latency-restore`）仍通过；存储体积下降 ≥50%。

### 3.5 收益 / 代价

| 项 | 内容 |
|---|---|
| **退出主链** | `LatencyEngine` 队列/分类段 ~600 + `FlclashDelay` 冗余分支 ~300 + `LatencyStore` 明细持久化 ~200 ≈ **1 100 行** |
| **保留** | `LatencyStore` 的"最后结论 + 时间戳"持久化（这是 ClashPlus 缺的、也是用户体感"重启后延迟还在"的关键） |
| **代价** | 失去离线探测出的"服务器可达性"（改为数据页连通性功能，语义更清楚） |
| **风险** | 内核组测速对 `url-test` 组的副作用（可能扰动自动选点）→ 需在内核侧确认"测速不改选择" |

---

## 4. 方向三：VPN 启动 → App 只发意图，编排下沉扩展

### 4.1 目标形态

```
App：  写意图（profile + node + generation） → 等「权威状态」→ 展示
扩展：  建 TUN / 起内核 / reload 配置 / protect / 网络变化重连 / 自愈 / 保活
内核：  执行
```

App 侧 `connect()` 只做三件事：① 意图原子落盘 ② 通知扩展 ③ 等权威状态（读状态文件），**不再直接 attachTun / startCore / 轮询 HTTP**。

### 4.2 P0 —— 收敛入口（2 人日）

- `ConnectionOrchestrator.connect()` 删掉"App 内编排"分支：配置应用、TUN 建立、内核启动统一由扩展按"意图文件"执行。
- 权威状态**单一来源**：扩展写 `STATUS_FILE`（phase / coreAlive / mtu / netType / generation），App 只读；删除 App 侧第二套判定（`tunnelMarkerExists` / `heartbeatAgeMs` 二选一保留）。
- `ClashApiService.waitReady` 的 HTTP 轮询改为"读扩展写出的 `ready` 字段"。

**验收**
- [ ] 连接耗时不变或更短（当前 0.3–1.5s 区间不得劣化）
- [ ] 断开 → 重连 → 切订阅 → 切节点，四类操作的权威状态与 UI 100% 一致
- [ ] `verify-connect-stability.mjs` / `verify-event-driven.mjs` / `verify-foreground-session-runtime.mjs` 全绿

### 4.3 P1 —— 配置热应用改为「generation 驱动」（2–3 人日）

- App 只写 `config.yaml` + 递增 `configGeneration`；扩展监听 generation 变化自行 `reload`（现在是 App 同步调 `setupConfig` 再等 ready）。
- 删除 App 侧 `applyProfileDebounce` 之外的重复防抖。

**验收**：切订阅的平均中断时长下降；同一 generation 不重复 reload；`verify-config-single-source` 通过。

### 4.4 P2 —— 自愈/failover 下沉（3–4 人日）

- `runHealthSelfCheckAndRepair` / `tryFailover` / `NetworkWatch` 迁入扩展（它本来就持有 TUN 与内核，且已在做 core probe / rebuildTunnel）。
- App 只展示"当前正在修复"的权威状态；不再自己发起重连。

**验收**
- [ ] 断网 30s → 恢复：隧道自愈且 App 无残留状态
- [ ] 内核被杀：扩展重启内核，App UI 在 5s 内回到 CONNECTED
- [ ] `verify-background-keepalive-runtime.mjs` 通过（保活不得退化）

### 4.5 收益 / 代价

| 项 | 内容 |
|---|---|
| **退出主链** | `ConnectionOrchestrator` 可从 5 888 行收敛到 **≈2 000 行**（-65%） |
| **根除故障类** | "连上了但走的不是选的节点"、"反复重连"、"UI 与内核状态不一致"——全部来自 App/扩展/内核三方各自判定 |
| **代价** | 扩展进程职责变重，必须依赖保活；调试链路变长（要看扩展日志） |
| **风险** | 迁移期必须有**双轨开关**（`orchestration = 'app' | 'extension'`），分三步切，每步可回滚 |

---

## 5. 落地顺序与排期（建议）

| 阶段 | 内容 | 人日 | 可回滚开关 | 关键门禁 |
|---|---|---|---|---|
| **Q1** | 方向二 P0/P1（测速单通道）+ 方向一 P0（App 不产节点表） | 3–4 | `parseOwner`、`latencyChannel` | `verify-latency-*`、`verify-core-catalog` |
| **Q2** | 方向一 P1（内核裁决 + 原文即基底） | 2–3 | `configMerge = 'whitelist' \| 'legacy'` | `verify-config-*` |
| **Q3** | 方向三 P0（入口收敛 + 权威状态单源） | 2 | `orchestration` | `verify-connect-stability` |
| **Q4** | 方向三 P1（generation 热应用） | 2–3 | 同上 | `verify-event-driven` |
| **Q5** | 方向三 P2（自愈/failover 下沉）+ 方向二 P2（结果瘦身） | 3–5 | 同上 | `verify-background-keepalive-runtime` |
| **Q6（可选）** | 方向一 P2（proxy-providers 化） | 3–4 | `profileMode` | 五份真实订阅回归 |

**总计约 15–20 人日**；每个阶段独立可发布、独立可回滚。

---

## 6. 明确**不做**的薄化（与 ClashPlus 的差异，刻意保留）

| 项 | ClashPlus | TunBox 决策 |
|---|---|---|
| **MTU** | 固定 9000 | 保持 `1400` + 按承载动态（`mtuForNetType`）；9000 在移动网络易碎包 |
| **保活** | 仅前台服务 | 保留 `UiGuardian` 连续任务 + 扩展常驻（鸿蒙后台更严格） |
| **网络变化** | 未见处理 | 保留 `NetworkWatch` 重连 |
| **失败回退** | 基本没有 | 保留"坏配置保留旧原文 + 自愈 + failover" |
| **延迟持久化** | 不持久化 | 保留（用户体感"重启后延迟还在"） |
| **拉取防御** | 无超时/无重试/单 UA | 保留 UA 链 + 重试预算 + 8MB/2000 上限 |
| **测速分类** | 固定 -2 | 保留 3 类（TIMEOUT/FAILED/NOT_TESTED） |

---

## 7. 风险清单

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| R1 | 内核 `validateConfig` 对 8MB 配置耗时过长 | 导入卡顿 | P1 前先实测；超阈值则降 `MAX_RESPONSE_BYTES` 或异步校验 + 进度条 |
| R2 | 「原文即基底」后订阅自带 `rules` 与 App 注入规则冲突 | 分流异常 | 白名单只覆写全局键；规则冲突用例进 `verify-config-*` 回归 |
| R3 | 扩展进程职责变重后崩溃面扩大 | 连接中断 | 扩展侧保留现有 core probe / rebuildTunnel；App 侧保留"最后已知状态" UI |
| R4 | 内核组测速扰动 `url-test` 自动选点 | 出口漂移 | 测速前记录 `now`，测速后校验；必要时改用独立测速内核（现有无头测速通道） |
| R5 | 迁移期双轨（App 编排 vs 扩展编排）并存 | 状态竞争 | 开关只允许整链路切换，禁止半开；切换时强制 disconnect→connect |

---

## 8. 交付物

1. 本文档（方案）。
2. 各阶段结束后：`docs/CHAIN_THINNING_<阶段>_<日期>.md`（复盘 + 实测数据 + 回归结果）。
3. 每个阶段新增/加强的 `scripts/verify-*.mjs` 门禁。

---

## 9. 下一步（需你确认）

1. **是否先做 Q1**（测速单通道 + App 不产节点表）—— 改动最小、收益最直接、风险最低。
2. 方向一 P1 的**覆写白名单**是否就按第 2.3 节那张表定稿（要不要加 `profile.store-selected` / `geodata-mode`）。
3. 方向三是否接受"编排下沉扩展"这个方向（这是三者中改动最大的一项，建议 Q1/Q2 验证过薄化收益后再启动）。
