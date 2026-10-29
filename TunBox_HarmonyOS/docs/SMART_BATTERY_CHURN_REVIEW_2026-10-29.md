# smart 自动选择：耗电与节点抖动根因分析 + 优化方案

日期：2026-10-29
范围：`kernel/mihomo-smart`（内核）+ `TunBox_HarmonyOS`（配置生成 / UI）
状态：分析与初步内核修复；未构建、未真机验证

---

## 0. 结论摘要

用户感知到的两个问题各有独立的、可定位的根因，且**互相放大**：

| 问题 | 主因（按影响排序） |
| --- | --- |
| 耗电 | ① `lazy` 健康检查被 `GetProxies(true)` 打穿，全池节点每 300s 探测一次；② `StatusTest` 对 <30KB 的 443 连接额外发一次完整 HTTPS GET，且"失败后 300s 内每条连接都复检"；③ 每条连接结束后一个 goroutine + 一次 25 参数日志 Sprintf（INFO 级别下仍格式化）+ bbolt 写；④ keep-alive idle=30s/interval=15s；⑤ `parallelDials=5` × `maxRetries=3` 最多 11 条并发拨号 |
| 切换/换 IP | ① `code 5` 对低权重节点写入 24 小时 host 状态；冷启动样本不足时可能返回 0，原检查未区分无样本与低权重；② `code 4` 的 100ms 零流量阈值可能误判短连接；③ `findSameConnection` 原先会关闭同 target 下不同节点的连接；④ `checkBlockedNodes` 判据写反，有效封禁被提前清除；⑤ shuffle / prepend 可能改变首拨顺序。实际 IP churn 数量尚无设备计数验证 |

`code 5` 与最小样本门槛的组合存在把“样本不足”误作低质量并写入 host 状态的风险；当前证据不足以断言其必然造成固定次数的 IP 切换。`code 4` 的 100ms 阈值也过于激进，实际触发规模需运行时统计。

---

## 1. 现状链路

### 1.1 探针来源（唯一）

app 侧 `RAW_PROVIDER_HEALTH_CHECK_ENABLED = false`（2026-10-22 决策），订阅 provider 不输出 `health-check:`，因此：

- 节点 alive / 延迟历史**只**来自组级健康检查（`adapter/provider/healthcheck.go`）+ 手动测速。
- 智能组 YAML 未输出 `interval` → parser 默认 **300s**（`adapter/outboundgroup/parser.go:172`：非 select/relay 且 `Interval==0` → 300）。
- 智能组 `use:` 引用 raw provider 时，`addTestUrlToProviders`（parser.go:258）会把组的 URL 追加注册到 provider 的 extra 探针表；因 provider `hc.interval == 0`，被组 interval 填充为 300s。

### 1.2 选择链路

```
DialContext (smart.go:246)
  └ selectProxies (679)
      ├ GetUnwrapResult  (30min TTL)
      ├ GetPrefetchResult
      └ GetBestProxyForTarget (stats.go:554)  → names/weights
  └ filterProxies (521)
      ├ 剔除 blockedNodes (GetBlockedNodes, stats.go:1024)
      ├ 剔除 wtFailNodes（域名级封禁）
      ├ 要求 AliveForTestUrl(testUrl)
      ├ 权重要求 >= AllowedWeight(0.4)
      ├ defaultSort（priority → delay → name）
      ├ rand.Shuffle（候选 < 总数 1/3 且无 policy-priority）
      └ prependProxy 覆盖 selected[0]
  └ tryDial → getBatch(i=0) 只取 proxies[0:1]
```

### 1.3 连接结束链路

```
registerClosureMetricsCallback (1524)
  └ go recordConnectionStats (1359)
      ├ GetOrCreateAtomicRecord（LRU / 缺失时读 bbolt）
      ├ 模型推理（LightGBM prepareFeatures + transforms）
      ├ EMA 更新权重
      ├ checkNodeQuality (1579) → UpdateHostStatus (stats.go:1243)
      │    └ isDegraded/failedBlock → findSameConnection (1647) → tracker.Close()
      ├ json.Marshal + AppendToGlobalQueue（5min 批量落盘）
      └ logConnectionStats (1270)  ← 25+ 参数 log.Debugln
```

---

## 2. 耗电根因

### E1（高）`lazy: true` 实际失效，全池节点每 300s 探测

`HealthCheck.process()`（`adapter/provider/healthcheck.go:46-61`）：

```go
lastTouch := hc.lastTouch.Load()
since := time.Since(lastTouch)
if !hc.lazy || since < hc.interval {   // :52
    hc.check()
}
```

语义是"上次 touch 距现在短于 interval 就测"，即**越活跃越测**。而 smart 会在多处 `Touch`：

| 调用点 | 频率 |
| --- | --- |
| `DialContext` → `s.GetProxies(true)`（smart.go:316） | 每条新连接 |
| `runPrefetch`（814，15m） | 15 min |
| `updateNodeRanking`（823，5m） | 5 min |
| `checkNodesStable`（1126，10m） | 10 min |

后台周期任务调用 `GetProxies(true)` 会 Touch provider，可能延后 lazy 检查的跳过窗口；但 Touch 本身不能证明每次都会触发全池 URLTest。需结合 provider 的 singleDo、lastTouch、任务时序和 URLTest 计数验证，不能据此断言 lazy 永远不跳过。

因此当前能确认的是：smart 后台维护任务存在 Touch provider 的路径，`unified-delay: true` 也会增加 URLTest 测时工作。实际每小时探测次数、请求数与蜂窝射频影响尚未测量，应先采集 URLTest 计数再估算成本。

### E2（高）`StatusTest`：小响应连接额外一次全站 HTTPS GET

`checkNodeQuality`（smart.go:1626-1644）：

```go
if downloadTotal < 0.03 && metadata.Host != "" && metadata.DstPort == 443 && !isUDP {
    if now - wtLastCheck > 300 || now - wtLastFailure < 300 {   // :1631
        checked = true
        status, ok, err := s.StatusTest(proxy, metadata.Host)
        ...
    }
}
```

三个问题：

1. **门槛太低**：`downloadTotal < 0.03` 单位是 MB，即 **30KB**。API 响应、小页面、JS 分片全部命中。
2. **第二个条件反向**：`now - wtLastFailure < 300` 意味着"最近失败过，则接下来 300 秒内**每条**连接都复检"。形成 `失败 → 复检 → 失败` 的正反馈。
3. `StatusTest`（smart.go:1694 → `adapter/adapter.go:313`）是完整 `GET https://<host>/?z=<rand>`，带 **Chrome/132 UA、浏览器级 Accept 头、chrome TLS 指纹**，最多 3 次重定向，`http.Client.Timeout = 10s`。

即：一次网页加载里的每个 <30KB 请求都可能额外产生一次真实 HTTPS 请求。

### E3（中高）每条连接的收尾成本

`registerClosureMetricsCallback`（smart.go:1524）为**每条连接**起 goroutine 执行 `recordConnectionStats`，其中：

- `GetOrCreateAtomicRecord`：LRU 命中则快；未命中要 `GetStatsForTarget` 读 bbolt。
- LightGBM 推理（`prepareFeatures` + `ApplyTransforms`）。
- `json.Marshal` + `AppendToGlobalQueue`。
- **`logConnectionStats`（smart.go:1270）：单条 25+ 参数的 `log.Debugln`**。

关键点：`log/log.go` 的实现是

```go
func Debugln(format string, v ...any) {
    event := newLog(DEBUG, format, v...)   // newLog 内部 fmt.Sprintf 已执行
    logCh <- event                          // logCh = make(chan Event) —— 无缓冲
    print(event)                            // print 里才按 level 过滤
}
```

`level = INFO` 时 `log.Debugln` **仍然完成整个 `fmt.Sprintf`**，并且向**无缓冲 channel** 发送（需等待 observable 协程接手），最后才在 `print` 里丢弃。高频小连接场景（网页、IM、心跳）下这是可观的 CPU 与调度开销。

### E4（中高）TCP keep-alive 30s / 15s

app 生成（`ClashConfigGenerator.ets:264-265`）：

```yaml
keep-alive-idle: 30
keep-alive-interval: 15
```

`component/dialer/dialer.go:140` → `keepalive.SetNetDialer(dialer)` → go1.23 分支（`tcp_keepalive_go123.go:36`）把 `KeepAliveConfig{Enable:true, Idle:30s, Interval:15s, Count:N}` 写入全局 `net.Dialer`。

结果：**所有出站连接**（不只是 redir/tproxy 入站）空闲 30s 后，每 15s 发一次探测。手机常驻几十条长连接时，这是持续的射频唤醒。

`SetDisableKeepAlive`（`component/keepalive/tcp_keepalive.go`）只对 `runtime.GOOS == "android"` 强制禁用，**`openharmony` 未特殊处理**。

### E5（中）并发拨号放大

`smart.go:52-53`：`parallelDials = 5`，`maxRetries = 3`。

`getBatch`（smart.go:247）：`i==0` 只发 1 个，之后每次 5 个并发 → 最坏 **1 + 5 + 5 = 11 条并发 TLS 建连**（同一目标）。

且超时无下限：

```go
if historyConnectTime > 0 {
    timeout = time.Duration(float64(historyConnectTime) * connectThreshold) * time.Millisecond  // ×5.0
}
if timeout > C.DefaultTCPTimeout || timeout <= 0 { timeout = C.DefaultTCPTimeout }
```

若历史 `connectTime` 为 20ms（同一局域网/同城节点），timeout = **100ms**，几乎必然失败 → 立刻升级到 5 并发 → 再失败 → 再 5 并发。弱网下这是拨号风暴。

### E6（中）应用层轮询

- 流量 2000ms、核心存活 3000ms、`UnifiedScheduler` 250ms tick、节点页 smart 轮询 3000ms（`NodeSelectionPage.ets`）。
- 全在前台/常驻期间持续跑，TUN 常驻时不会停。

### E7（低中）6 个后台周期任务的抖动摊薄了唤醒

`InitSmart` / `startTimedTask`（smart.go:721/759）注册：

| 任务 | 首延迟 | 周期 |
| --- | --- | --- |
| AdjustCacheParameters | 5s | 5m |
| 队列 flush | 5m | 5m |
| cleanupOrphanedGroups | 5m | 10m |
| runPrefetch | 5m | 15m |
| updateNodeRanking | 5m | 5m |
| checkNodesStable | 5m | 10m |
| checkBlockedNodes | 5m | 10m |
| checkHostStatus | 15m | 30m |
| cleanupOrphanedNodeCache | 10m | 120m |
| 旧记录清理 | 10m | 120m |

每个 ticker 还叠加 `rand.Float64()*30s` 抖动。抖动本意是防同时触发，但任务多时反而**把唤醒摊成更多次**。

### E8（低，偏内存/CPU）`openharmony` 内存探测缺失

`GetSystemMemoryUsage`（`component/smart/common.go:341`）只处理 `windows`（wmic）与 `linux|android|darwin|freebsd`（`/proc/meminfo`）。`openharmony` 两者都不匹配 → 直接 `return 0.5`。

后果：`AdjustCacheParameters` 永远按 0.5 调参 →
- `MaxTargets = 500 + 4500×0.25 = 1625`
- `BatchSaveThreshold = 50 + 250×0.25 = 112`

缓存规模固定在中档偏高，`GetAllStats` 的 bbolt 前缀扫描范围偏大。不直接耗电，但与 E3 叠加。

---

## 3. 节点抖动 / IP churn 根因

### C1（最高）单条连接权重 < 0.4 → 该节点对该域名封禁 24 小时

链路：

```go
// smart.go:1607
if newWeight < smart.AllowedWeight {          // AllowedWeight = 0.4 (common.go:53)
    return newWeight, true, true, 5           // isDegraded=true, checked=true, code=5
}
```

```go
// stats.go:1243 UpdateHostStatus
switch newCode {
case 1: // 永久
case 2: codeSet.Nodes[name] = now + HostFailureNodeTTL   // 24h
case 3: // 失败计数
default: codeSet.Nodes[name] = now + HostFailureNodeTTL  // ← code 4/5 落这里，24h
}
```

**"样本数不足"可能被当成"低权重"**：

```go
// component/smart/weight.go:83 CalculateWeight
if success+failure < DefaultMinSampleCount {  // DefaultMinSampleCount = 2
    return 0, false
}
// component/smart/lightgbm/lightgbm.go:580 PredictWeight
if total < smart.DefaultMinSampleCount {
    return 0, false
}
```

如果新 `(域名, 节点)` 记录在检查时只有一个样本，权重路径可能因 `total < 2` 返回 0；原 `checkNodeQuality` 随后会将 0 当作低权重并返回 `code 5`，而 `UpdateHostStatus` 对 code 5 使用默认 24 小时 TTL。这是冷启动误判路径，但记录作用域、连接回调时序及聚合状态决定它是否会在具体首连发生，不能推导出每个新域名固定切换 N 次。修复目标是让无有效样本不触发低权重封禁。

次要放大：EMA 系数 `(old*2 + new*4)/6`（α=0.667，smart.go:1345/1352）让单次异常样本就能把权重拉低 2/3，第二次即跌破 0.4。

### C2（高）`code 4` 零流量的阈值是 100 毫秒

```go
// smart.go:1617
if connectionDuration > 100 && downloadTotal == 0 && uploadTotal == 0 &&
   metadata.DstPort == 443 && !isUDP {
    return newWeight, true, true, 4
}
```

`connectionDuration` 来自 `time.Since(info.Start).Milliseconds()`（smart.go:1533），单位是**毫秒**。阈值 100 = **0.1 秒**。

命中者：
- 浏览器 `preconnect` / DNS 预热 / TLS 预热后未使用的连接；
- HTTP/2 连接复用后被关闭的空连接；
- **QUIC 竞速中失败的 TCP 探测连接**（Chrome 会同时发 TCP 和 QUIC）；
- 被应用取消的预连接。

这些连接可能满足“443 + 握手成功 + 0 字节 + >100ms”，从而进入 code 4 分支。原分支会写 host 状态并触发连接处理，但实际命中频率需观测确认。

### C3（高）`findSameConnection` 关闭同域名下**所有节点**的连接

```go
// smart.go:1647
for id := range allIDs {                                   // GetSmartTargetIDs(target, asn)
    if tracker := statistic.DefaultManager.Get(id); tracker != nil {
        if id != metadata.UUID && lo.Contains(tracker.Chains(), s.Name()) {
            if lo.Contains(tracker.Chains(), proxyName) {
                tracker.Info().Metadata.SmartBlock = "degraded"
            }
            _ = tracker.Close()                            // ← 对所有节点都执行
        }
    }
}
```

标记 `degraded` 只在同节点时做（避免级联），但 **`Close()` 是无条件执行的**。于是一次降级判定会把该域名的所有在途连接（哪怕走的是健康节点）全部 RST → 应用重连 → 重新选节点 → 出口 IP 变化 + 页面/下载中断。

`GetSmartTargetIDs` 在 `tunnel/statistic/manager.go:196`。

### C4（高）`checkBlockedNodes` 判据写反

```go
// smart.go:1210
if state.BlockedUntil > 0 && state.BlockedUntil > time.Now().Unix() {
    state.BlockedUntil = 0
    log.Debugln("[Smart] Node [%s] block period expired, unblocking", nodeName)
}
```

条件与日志语义相反：**在封禁仍然有效时清零**，且真正过期的项永不清除（`GetBlockedNodes` 会忽略过期项，故无实际危害）。

`checkBlockedNodes` 周期 10 分钟，`checkNodesStable` 封禁时长 = `checkInterval + 2m` = **12 分钟**。于是：

```
t=0    checkNodesStable 封禁 12 分钟
t=10m  checkBlockedNodes 判定 >now → 提前解封（剩余 2 分钟作废）
t=10m  UpdateBlockedNodesCache 更新 → 节点回到候选池
t=10m  checkNodesStable 重新评估 → 大概率再封 12 分钟
```

→ 节点在黑名单/白名单之间每 10 分钟来回跳，候选池规模震荡。

### C5（中高）`checkNodesStable` 把网络抖动当节点故障

```go
currentAnomaly, unstable, _, newGrade := s.calcMADMetrics(delays)
gradeDecreased := (prevGrade > 0 && newGrade > 0 && newGrade > prevGrade) || newGrade > 2
if currentAnomaly || unstable || gradeDecreased {
    state.BlockedUntil = blockedUntil   // now + 12m
}
```

- `unstable = robustCV >= 0.6`（`scale*mad/median`）。移动网络（4G/5G 切换、信号波动、电梯/地铁）很容易 ≥0.6。
- `gradeDecreased` 里的 `newGrade > 2` 是**绝对判据**：阈值 > 2000ms 就无条件算劣化，与历史无关。
- `currentAnomaly` 要求两次连续超阈（或 sentinel `0xffff`，即一次 0 延迟/不 alive 就命中）。

结合 `filterProxies` 里 `blockedNodes[name]` 直接排除（smart.go:536），每 10 分钟节点池可能大幅收缩再回弹 → 选中节点跟着变。

### C6（中）`filterProxies` 随机洗牌

```go
// smart.go:619-625
if !hasPriority {
    if len(filteredAll) < len(all)/3 {
        rand.Shuffle(len(filteredAll), func(i, j int) { ... })
    }
}
```

只要过滤后候选 < 总数 1/3 且配置里没有 `policy-priority`，候选顺序被打乱。而 `DialContext` 的 `getBatch(i=0)` **只取 `proxies[0:1]`** → 同一网络状态下首拨落点随机。

### C7（中）`prependProxy` 覆盖模型排序

```go
// smart.go:627-651
for _, p := range filteredAll {
    if !hasPrepend && (len(selected) < minCount/2 || len(wtFailNodes) <= 0 || wtBlocked) {
        prependProxy = p        // filteredAll[0] = defaultSort 的第一个
        hasPrepend = true
    } else { selected = append(selected, p) }
    ...
}
if hasPrepend { /* 插到 selected[0] */ }
```

`defaultSort` 的排序键是 `priority → LastDelayForTestUrl → name`（smart.go:576 局部闭包），**不是权重**。

只要该域名当前没有失败节点（`len(wtFailNodes) <= 0` 是常态），就把"延迟最低的节点"顶到 `selected[0]`，而 `selected[0]` 正是首拨目标。→ **模型算出来的 top1 被延迟排序覆盖**；延迟每 5 分钟变一次，首拨节点就跟着变。

### C8（中）alive 抖动

`filterProxies` 要求 `proxy.AliveForTestUrl(s.testUrl)`（smart.go:536）。URLTest 单次失败即置 `alive=false`，立刻从候选剔除；下一次健康检查又可能恢复。

放大因素：
- `unified-delay: true` → 每个节点两次 HEAD，任一失败即失败；
- `HealthCheck` 默认 `timeout = 5000ms`（`NewHealthCheck` 中 `if timeout == 0 { timeout = 5000 }`），弱网下 5s 判死；
- 组 interval 300s → 抖动窗口 5 分钟。

### C9（中）app 层 failover 与内核 smart 双控制器

`ConnectionOrchestrator.tryFailover(trigger)` 用 `settings.failoverFailureThreshold` + `SmartSelector.nextBestNode` 独立判定失败并切节点，与内核 smart 的权重模型互不知情 → 互相反向切换。

### C10（中低）unwrap 缓存与权重子 LRU

- `unwrap` 缓存 TTL 1800s（`AdjustCacheParameters`，memory.go:337）；`findSameConnection` 每次都会 `DeleteUnwrapResult`（smart.go:1660）。
- `GetOrCreateAtomicRecord` 的 weights 子 LRU size = **100**（stats.go:135）。一个域名 × 节点数 × 4 种 weightType（TCP/UDP/TCPASN/UDPASN）很容易超过 100 → 权重被淘汰回 0 → 重新触发 C1 的 `newWeight < 0.4`。

### C11（中低）EMA 过冲

`updateEMAFloat(old, new) = (old*2 + new*4)/6`，对 new 的权重是 0.667。旧值 ≤0 时直接取 new。单次异常样本即可把 0.9 拉到 ~0.57，第二次跌破 0.4 → 24h 封禁。

---

## 4. 优化方案

分四层：配置层（app 侧，零内核改动）→ 内核行为修复 → smart 子系统参数 → 模型层。

### A. 配置层（可立即验证，不动内核）

| 编号 | 改动 | 位置 | 说明 |
| --- | --- | --- | --- |
| A1 | 智能组显式输出 `interval: 900`、`lazy: true`、`max-failed-times: 3` | `ClashConfigGenerator.ets` smart 块（:687-711）、`RuntimeConfigBuilder.ets` 注入块（~520-585） | 当前继承订阅组 interval（`clampGroupInterval` :654），多数订阅是 300s。不要复用订阅值，给 smart 独立常量 |
| A2 | `keep-alive-idle: 300`、`keep-alive-interval: 75`，或直接 `disable-keep-alive: true` | `ClashConfigGenerator.ets:264-265` | 默认 30/15 过于激进；需设备验证 NAT 保持 |
| A3 | 评估 `unified-delay: false` | `ClashConfigGenerator.ets` | 探测请求直接减半；UI 延迟数值会略变 |
| A4 | 智能模式开启时禁用 app 层 `tryFailover` | `ConnectionOrchestrator.ets` | 避免双控制器 |
| A5 | 节点页 smart 轮询 3000 → 5000ms，并在 `onPageHide` 停表 | `NodeSelectionPage.ets` | 现在只依赖 `UnifiedScheduler.every` |
| A6 | 流量轮询 2000 → 5000ms；息屏暂停 UI 轮询 | `VpnExtensionAbility.ets` / 统一调度器 | |

> A1 单独做收益有限 —— 必须同时修 E1（B6），否则 interval 拉长只是线性降频。

### B. 内核行为修复（`adapter/outboundgroup/smart.go` 为主）

**P0**

**B1｜修正 `checkBlockedNodes` 判据（smart.go:1210）**

```go
- if state.BlockedUntil > 0 && state.BlockedUntil > time.Now().Unix() {
+ if state.BlockedUntil > 0 && state.BlockedUntil <= time.Now().Unix() {
```

消除每 10 分钟一次的"提前解封"，让 `checkNodesStable` 的 12 分钟封禁真正生效，消除候选池震荡。

**B2｜`code 4` 零流量阈值 100ms → 3s，且不写 24h 封禁（smart.go:1617）**

```go
- if connectionDuration > 100 && downloadTotal == 0 && uploadTotal == 0 && ...
+ if connectionDuration > 3000 && downloadTotal == 0 && uploadTotal == 0 && ...
```

并让 code 4 使用短 TTL（5–15 min）而不是 `HostFailureNodeTTL`；同时**不触发 `findSameConnection`**。

**B3｜`code 5`（权重 < AllowedWeight）不再写 24h host 封禁（smart.go:1607-1609）**

权重是软信号，受 EMA 过冲、场景识别、样本不足影响极大。建议：

```go
// 方案 1：区分"无数据"与"低权重"
if totalSamples >= smart.DefaultMinSampleCount && newWeight < smart.AllowedWeight {
    return newWeight, true, true, 5
}
// 方案 2：code 5 只降权不封禁（filterProxies 已有 weight 过滤），TTL 降到 5-15min
```

**B4｜`findSameConnection` 只在同节点时关闭连接（smart.go:1647-1660）**

```go
- if id != metadata.UUID && lo.Contains(tracker.Chains(), s.Name()) {
-     if lo.Contains(tracker.Chains(), proxyName) {
-         tracker.Info().Metadata.SmartBlock = "degraded"
-     }
-     _ = tracker.Close()
- }
+ if id != metadata.UUID && lo.Contains(tracker.Chains(), s.Name()) &&
+    lo.Contains(tracker.Chains(), proxyName) {
+     tracker.Info().Metadata.SmartBlock = "degraded"
+     _ = tracker.Close()
+ }
```

这是"用户可见的重连/IP 变化"最直接的一处。

**B5｜`StatusTest` 触发门限与限流（smart.go:1631）**

```go
- if now - wtLastCheck > 300 || now - wtLastFailure < 300 {
+ if now - wtLastCheck > 300 {          // 去掉"失败后 300s 内每条连接都复检"
```

并把 `downloadTotal < 0.03`（30KB）收窄为"下载为 0，或响应极小且耗时异常长"；给 `StatusTest` 加全局令牌桶（如 30 次/分钟）+ 每 `(target, node)` 冷却。

**B6｜周期任务不再 `GetProxies(true)`（smart.go:814, 823, 1126）**

```go
- proxies := s.GetProxies(true)   // Touch → 打穿 lazy
+ proxies := s.GetProxies(false)
```

让 `lazy: true` 真正生效：息屏/无流量时不做全池探测。

**P1**

**B7｜降低拨号放大与超时下限（smart.go:52-53, 274）**

```go
- parallelDials = 5
+ parallelDials = 2              // 移动端；或按 WiFi/蜂窝自适应
- maxRetries = 3
+ maxRetries = 2
```

```go
  if historyConnectTime > 0 {
      timeout = time.Duration(float64(historyConnectTime) * connectThreshold) * time.Millisecond
  }
+ if timeout < 1500*time.Millisecond {
+     timeout = 1500 * time.Millisecond
+ }
```

**B8｜`filterProxies` 去掉随机洗牌与排序覆盖（smart.go:619-651）**

- 移除 `rand.Shuffle`，改为确定性 tie-break（name）。
- `prependProxy` 仅在 `len(selected) == 0`（模型确实无候选）时生效，否则尊重权重顺序。

**B9｜软化 `checkNodesStable`（smart.go:1120-1170）**

- `unstable` 阈值 0.6 → 0.8，或要求连续 2 个窗口。
- 去掉 `gradeDecreased` 里的 `|| newGrade > 2` 绝对判据，只与 `prevGrade` 比较。
- 封禁时长 `checkInterval + 2m`（12m）与 10 分钟周期过于接近 → 改为 30 分钟或指数退避。

**B10｜热路径日志前置级别判断（smart.go:1270, log/log.go）**

```go
  if log.Level() <= log.DEBUG {
      s.logConnectionStats(...)
  }
```

并建议把 `logCh` 改为带缓冲（如 1024），避免每条日志一次无缓冲 channel 交接。

**P2**

**B11｜`GetSystemMemoryUsage` 支持 `openharmony`（common.go:341）**

直接 `os.ReadFile("/proc/meminfo")` 解析 `MemTotal`/`MemAvailable`（不要走 `cmd.ExecCmd`，避免每次 fork 一个进程），并把 `openharmony` 加入分支。

**B12｜`SetDisableKeepAlive` 纳入 `openharmony`**，或在 app 侧直接下发 `disable-keep-alive: true`。

### C. smart 子系统参数（`component/smart/`）

| 编号 | 改动 | 位置 | 理由 |
| --- | --- | --- | --- |
| C1 | `HostFailureNodeTTL` 分级：code 2 → 1h、code 3 → 24h、code 4/5 → 5–15min | stats.go:1243 `switch` + common.go:51 | 24h 是给"域名被该节点墙"的，不该用于软信号 |
| C2 | 权重滞回：进入候选要求 ≥0.4，踢出当前节点要求 <0.3 且连续 2 样本 | stats.go:554 `GetBestProxyForTarget` | 消除 0.4 附近的抖动 |
| C3 | `Blocked=true` 的阈值从 `maxFailedTimes`(5) 解耦为独立常量（如 3） | stats.go:1450 附近 | 现在与组配置耦合，语义混乱 |
| C4 | EMA 冷启动：样本 < 5 时用算术平均，之后 α=0.25（`(old*3+new)/4`） | smart.go:1345/1352 | 消除单样本过冲导致的封禁 |
| C5 | weights 子 LRU size 100 → 按 `节点数 × 4` 动态计算 | stats.go:135 | 避免权重被淘汰回 0 |

### D. 模型层（权重算法 / LightGBM）

**D1｜`DefaultMinSampleCount = 2` 太低（common.go:49）**

2 个样本的权重基本是噪声，而它同时是 `checkNodeQuality` 的"是否低权重"的唯一输入。两条路径：

- 提高 `AllowedWeight` 判定所需的最小样本（至少 3–5）；
- 或者让 `CalculateWeight` 在 `total < 5` 时返回**中性权重**（如 0.7）而不是 0，并额外返回 `confident=false`，由 `checkNodeQuality` 跳过 code 5。

> 这是 C1 的上游放大器，改动收益最大。

**D2｜场景识别滞回（weight.go `identifyConnectionScene`）**

`interactive` 要求 UDP latency<150ms / TCP<250ms 且 duration>3min。移动网络 RTT 常在 50–150ms 但抖动大 → 场景在 interactive/web 之间反复跳 → 权重系数来回变 → EMA 抖 → 封禁。加"连续 N 次同场景才切换"。

**D3｜LightGBM 模型分布校准**

`Model.bin` 是上游公开发布模型，与 HarmonyOS 移动网络分布未必匹配；`priorityFactor` 又在模型输出上再乘一次，可能放大排序差异。

建议做 A/B：`uselightgbm: false` 跑传统 `CalculateWeight`，对比 `code 5` 触发率与 churn 率。若差异显著，说明模型分布不匹配，应优先修传统路径（D1/D2），或先关闭 LightGBM。

**D4｜loss 因子过快获得信任（weight.go ~225）**

`trustCumul = min(1, cumulPenalty*5)`：单次丢包就能让 `cumulPenalty` 达到 0.2 → `trustCumul=1` → 立即采用累计惩罚。建议加时间衰减或最小样本门槛。

**D5｜`collectdata` 保持 false 是对的**

`recordConnectionStats` 里 degraded 时 `collectedWeight * 0.1` 或 `AllowedWeight*rand.Float64()` 属于**人为注入噪声标签**，只影响本地训练样本上传，不影响本地选择行为。既不开启，也无副作用。

---

## 5. 优先级与预期收益

| 优先级 | 项目 | 预期收益 |
| --- | --- | --- |
| **P0-1** | B1 `checkBlockedNodes` 判据 | 消除每 10 分钟的候选池震荡 |
| **P0-2** | B4 `findSameConnection` 只关同节点 | 直接消除"某域名整体被打断 → 重连 → 换 IP" |
| **P0-3** | B2 `code 4` 100ms → 3s + 短 TTL | 消除浏览器预连接/QUIC 竞速的误杀（预计是最大的一类误判） |
| **P0-4** | B3 + D1 `code 5` 区分"无数据" | 消除"新域名首连即封 6 个节点"的核心 churn 机制 |
| **P0-5** | B6 周期任务 `GetProxies(false)` | 让 `lazy` 生效；息屏期探测从"每 5 分钟全池"降到接近 0 |
| **P0-6** | A1 智能组显式 `interval: 900` | 探测频率 ↓3 倍 |
| P1-7 | B5 `StatusTest` 门限 + 限流 | 额外 HTTPS GET 大幅减少；消除失败正反馈 |
| P1-8 | A2 keep-alive 300/75 或 disable | 射频唤醒显著减少 |
| P1-9 | B8 去 shuffle / prepend 覆盖 | 首拨节点确定化，尊重模型 |
| P1-10 | B9 `checkNodesStable` 软化 | 减少移动网络抖动导致的批量封禁 |
| P1-11 | C4 EMA 冷启动保护 | 减少单样本过冲触发的封禁 |
| P1-12 | B7 `parallelDials` 2 + 超时下限 | 弱网拨号风暴缓解 |
| P2-13 | B10 日志级别前置 | 每连接 CPU/调度开销下降 |
| P2-14 | B11 openharmony 内存探测 | 缓存规模按真实内存调整 |
| P2-15 | C1 TTL 分级 | 软信号不再长期封禁 |
| P2-16 | D2/D3 场景滞回 / LightGBM A/B | 长期权重稳定性 |

**建议落地顺序**：B1 → B4 → B2 → B3/D1 → B6。之后先采集 URLTest、StatusTest、code 2/3/4/5 和连接关闭计数，再评估 interval、keep-alive、并发拨号等参数；需在移动网络下验证恢复速度、连接成功率与 NAT 保活。

---

## 6. 验证矩阵

### 6.1 设备侧

| 场景 | 指标 | 采集方式 |
| --- | --- | --- |
| 息屏待机 8h | 电量百分比、进程 CPU 时间、唤醒次数 | `hdc shell hidumper -s BatteryService -a -b`；`/proc/<pid>/stat` |
| 前台浏览 30min | `(域名 → 出口 IP)` 变化次数 | 每 10s 抓 `/connections`，按 host 聚合 chain 首节点 |
| 单域名长连接 | 是否发生 RST | hilog 过滤 `SmartBlock` / `degraded` |
| 弱网（地铁/电梯） | 封禁触发次数 | DEBUG 日志统计 code 2/3/4/5 |

### 6.2 对照组

1. smart 关闭（固定节点）—— 基线
2. smart 开启（现状）—— 复现问题
3. smart 开启 + P0 修复 —— 验证收益
4. smart 开启 + P0 修复 + A1/A2 —— 验证配置叠加收益

### 6.3 内核侧临时计数（建议加，验证后可移除）

- `URLTest` 调用次数 / 小时
- `StatusTest` 调用次数 / 小时
- `code 2/3/4/5` 各触发次数
- `findSameConnection` 关闭连接数
- `recordConnectionStats` 平均耗时

---

## 7. 关键常量与位置索引

### 内核 `adapter/outboundgroup/smart.go`

| 项 | 值 / 行号 |
| --- | --- |
| 常量块 | :41-55 |
| `parallelDials` / `maxRetries` | 5 / 3（:52-53） |
| `connectThreshold` | 5.0 |
| `DialContext` / `getBatch` / `tryDial` | 246 / 247 / 279 |
| `filterProxies` | 521 |
| `defaultSort`（局部闭包） | 576 |
| `rand.Shuffle` | 619-625 |
| `prependProxy` 覆盖 | 627-651 |
| `selectProxies` | 679 |
| `InitSmart` / `startTimedTask` | 721 / 759 |
| `checkNodesStable` | 1120 |
| `checkBlockedNodes`（判据反） | 1183，判据 :1210 |
| `logConnectionStats` | 1270 |
| `updateEMAInt` / `updateEMAFloat` | 1345 / 1352 |
| `recordConnectionStats` | 1359 |
| `registerClosureMetricsCallback` | 1524 |
| `checkNodeQuality` | 1579 |
| code 5 / code 4 / code 2 | 1609 / 1617 / 1639 |
| `findSameConnection` | 1647 |
| `checkHostStatus` | 1660 |
| `StatusTest` | 1694 |

### 内核 smart 子系统

| 项 | 值 / 位置 |
| --- | --- |
| `DefaultMinSampleCount` | 2（`common.go:49`） |
| `HostFailureNodeTTL` | 24h（`common.go:51`） |
| `AllowedWeight` | 0.4（`common.go:53`） |
| `GetSystemMemoryUsage` | `common.go:341`（openharmony 落 0.5） |
| `GetBlockedNodes` | `stats.go:1024` |
| `GetBestProxyForTarget` | `stats.go:554` |
| `GetOrCreateAtomicRecord`（weights LRU 100） | `stats.go:135` |
| `UpdateHostStatus` | `stats.go:1243` |
| `AdjustCacheParameters`（unwrap 1800s） | `memory.go:337` |
| `CalculateWeight`（样本门槛） | `weight.go:83` |
| `PredictWeight`（样本门槛） | `lightgbm.go:580` |

### 探针与 keep-alive

| 项 | 位置 |
| --- | --- |
| `lazy` 跳过条件 | `adapter/provider/healthcheck.go:52` |
| `NewHealthCheck` 默认 timeout 5000ms | `healthcheck.go:195` |
| 组 interval 默认 300s | `adapter/outboundgroup/parser.go:172` |
| `Lazy: true` 默认 | `parser.go:52` |
| `addTestUrlToProviders` | `parser.go:258` |
| `GetProxies` → `Touch` | `adapter/outboundgroup/groupbase.go:116/122` |
| `alive` / `LastDelayForTestUrl` | `adapter/adapter.go:48/130` |
| `StatusTest`（URLTest 实现） | `adapter/adapter.go:313` |
| `SetNetDialer` | `component/dialer/dialer.go:140` |
| keep-alive 应用 | `component/keepalive/tcp_keepalive_go123.go:36` |
| `GetSmartTargetIDs` | `tunnel/statistic/manager.go:196` |
| `log.Debugln` 无缓冲 channel | `log/log.go`（`logCh = make(chan Event)`） |

### app 侧

| 项 | 位置 |
| --- | --- |
| `keep-alive-idle/interval` 输出 | `ClashConfigGenerator.ets:264-265` |
| `clampGroupInterval` | `ClashConfigGenerator.ets:654` |
| smart 组块输出 | `ClashConfigGenerator.ets:687-711` |
| smart 组注入 raw profile | `RuntimeConfigBuilder.ets` ~520-585 |
| `RAW_PROVIDER_HEALTH_CHECK_ENABLED` | `RawSubscriptionStore.ets:57` |
| app failover | `ConnectionOrchestrator.ets` `tryFailover` |
| smart 轮询 | `NodeSelectionPage.ets` `startSmartPoll` |
