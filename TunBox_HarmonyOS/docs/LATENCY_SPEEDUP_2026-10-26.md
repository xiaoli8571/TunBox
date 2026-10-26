# 节点测速提速（2026-10-26）

用户诉求（原话）：
> 「主要优化节点测速的速度」
> 「还是觉得慢，你把超时判断调整到3秒，并发可以再稍微提高一点」
> 「点击测速到提示准备测速通道再到开始测速，这一段流程还是很慢，其他 clash 客户端基本上点了测速立马就开始测了」

本轮同时解决**两段**耗时：① 点下去到第一个探测发出（通道准备）；② 一批 80 个节点测完（批次本身）。

---

## 1. 根因

### 1.1 批次慢的真因：`@ohos.net.http` 对同一 host 的并发容量只有个位数

真机取证（80 节点、客户端 80 并发、`@ohos.net.http`）：

```
batch profile: concurrency=80 peakInflight=80 avgQueueWait=2ms p50=10000ms p90=10001ms wall=10130ms
delay batch done: total=80 measured=23 timeout=10 failed=1 cancelled=46
hilog 同期出现 285 次 code=2300028 Operation timeout
```

- `avgQueueWait=2ms` 说明**应用层**的 80 路 worker 确实同时发出了；
- 但 `p50=10000ms`（正好等于客户端守护窗口）说明一半请求根本没被 http 栈处理，一直挂到守护到期；
- `cancelled=46` = 46 个节点拿不到任何结论（UI 显示「未测」）。

结论：瓶颈不在内核（`hub/route/proxies.go:getProxyDelay` 没有任何并发信号量，每个请求独立 goroutine + 自己的 ctx 超时），而在**客户端 http 栈对同一 host 的连接池**。之前把并发从 32 提到 64/96 全部无效，反而把成功率打崩。

### 1.2 通道准备慢的真因：每次测速都可能冷启动一个 headless 内核

真机时间线（未连接、通道冷）：

```
tap → 读 profile 1.13MB + 合并生成配置 ~1.5s → 停旧扩展 600ms → 启扩展 ~165ms
    → 就绪轮询 ~200ms → 固定预热窗口 1500ms → 第一个探测
```

即点击到首个探测约 **3.5~5s**。三家客户端的内核本来就常驻，不存在这段等待。

---

## 2. 改动

### 2.1 传输层：新增 `ArkTcpDelayHttpTransport`（TCP 直连，绕开 http 栈连接池）

`commons/flclash/FlclashDelay.ets`

- 每个 delay 请求一条 `@kit.NetworkKit` TCPSocket 到本地内核，手写 HTTP/1.1 请求
  （`Connection: close`，靠内核关连接收尾，或用 `Content-Length` 提前收尾）；
- 语义与 `ArkDelayHttpTransport` 完全一致：只有拿到 HTTP 响应才 resolve（非 2xx 也 resolve），
  连接失败/超时/abort ⇒ reject；
- 开关 `FLCLASH_DELAY_USE_TCP_TRANSPORT`（false = 回退 `@ohos.net.http`）；
- `HTTP_CRLF` 用 `String.fromCharCode(13, 10)` 构造：仓库此前踩过「python heredoc 吃掉一层反斜杠，
  把 `\r\n` 写成真实换行导致源码被切断」的坑。

### 2.2 并发：基线 32、上限 64、按目标数自适应

```ts
flclashDelayConcurrency(total)  // ≤32 一波发完；>32 一路抬到 total，封顶 64
```

- 24 → 24（一波）、37 → 37（一波）、80 → 64（2 波）、600 → 64（10 波，原来 19 波）；
- `FlclashDelayPolicy` 新增 `adaptive`（默认 true）；`false` 时严格按传入并发，
  供闸门保留「固定 N 路」的行为用例。

### 2.3 超时：内核 `timeout` 5000 → 3000

- `FLCLASH_DELAY_TIMEOUT_MS = 3000`，与 `LatencyTimeout.DEFAULT_TIMEOUT_MS` 同值（闸门锁两处相等）；
- 客户端守护 30000 → 10000（`3s 内核 + 7s 余量`）——30s 的真实含义是
  「http 栈卡死的请求把整批墙钟钉在 30s」，真机那 2 条 cancelled 就是它。

### 2.4 通道准备：冷启动空闲预热 + 回收窗口放宽

`entryability/EntryAbility.ets`：`onCreate` 之后 **4s**（避开首帧/bootstrap）静默调用
`BackgroundLatencyService.prewarmChannel()`：只准备通道，不产生任何探测、不写任何延迟结论；
已连接/连接中时 `ensureTestCore` 的安全门禁直接跳过，不碰用户隧道。

`ConnectionOrchestrator`：
- `TEST_CORE_WARMUP_MS` 1500 → **1000**；
- `TEST_CORE_IDLE_RECYCLE_MS` 90s → **600s**（用户看完结果、翻两下页面再点一次不该重付冷启动）。

`SubscriptionPage.runKernelGroupTest`：先 `showToast('准备测速通道…')` 再取通道（点了要有反馈）。
`BackgroundLatencyService.runKernelGroupTest`：`CoreCatalogService.refresh(api, true)` → `false`（走快照 TTL）。

### 2.5 性能画像日志（长期保留，用于以后 A/B）

```
FlclashDelay: batch dispatchable: nodes=80 concurrency=64
FlclashDelay: batch profile: concurrency=64 peakInflight=64 avgQueueWait=0ms p50=1083ms p90=3058ms wall=3662ms
FlclashLatencyService: delay batch done: total=80 measured=49 timeout=23 failed=4 cancelled=4 wall=3662ms conc=64 peak=64
```

`FlclashDelaySummary` 新增 `concurrency / peakInflight / avgQueueWaitMs / p50ElapsedMs / p90ElapsedMs / wallMs`。
`avgQueueWait` 是判断「应用层排队」还是「传输层/内核慢」的第一指标。

---

## 3. 真机验证（局域网 hdc 连接，MLR-AL00 / HarmonyOS 26）

| 场景 | 改前 | 改后 |
|---|---|---|
| 80 节点批次墙钟 | 30.1s | **3.66~3.69s** |
| 同一批 p50 / p90 | 10000ms / 10001ms | **1083ms / 3058ms** |
| measured / cancelled | 55~58 / 0~2（32 并发 http） | **55 / 1**（64 并发 TCP） |
| http 栈超时（2300028） | 285 次 | 0 |
| 点击 → 首个探测（未连接、通道已预热） | ~4.9s | **0.71s**（581ms 取通道 + 128ms 起批） |
| 点击 → 首个探测（已连接，隧道核） | — | **<150ms**（`reusing connected tunnel controller`） |

典型设备日志：

```
17:08:14.524  （点击）
17:08:15.105  latency channel: headless test core ready
17:08:15.233  delay batch start: nodes=37
17:08:18.306  batch profile: concurrency=37 peakInflight=37 p50=734ms p90=3050ms wall=3073ms
17:08:18.307  delay batch done: total=37 measured=27 timeout=9 failed=0 cancelled=1
```

```

17:59:03.439  latency channel: headless test core ready
17:59:03.873  delay batch start: nodes=80
17:59:07.536  batch profile: concurrency=64 p50=1083ms p90=3058ms wall=3662ms
17:59:07.537  delay batch done: total=80 measured=49 timeout=23 failed=4 cancelled=4
```

> 注：3000ms 超时会把 3~5s 才能测通的节点判成超时（timeout 23 个），这是用户明确要的取舍
> （「等 5 秒太久」）；同一批在 5000ms 下 measured 会多几个。measured 总量基本不变（55 vs 57）。

---

## 4. 验证命令

```bash
node scripts/verify-flclash-delay.mjs        # 11/11 PASS（含新增 C0b 自适应曲线、C1b 一波用例）
node scripts/verify-vpn-architecture.mjs     # 313/313 PASS
node scripts/verify-latency-display.mjs      # 55/55 PASS
node scripts/verify-latency-concurrency.mjs  # 14/14 PASS
node scripts/verify-latency-engine-runtime.mjs # 27/27 PASS
node scripts/verify-latency-cache.mjs        # 65/65 PASS
node scripts/verify-latency-restore.mjs      # 42/42 PASS
```

顺带修了两个**存量**红（与本次改动无关，桩缺 `ConnectionOrchestrator.testCoreBusyProbes`）：
`verify-latency-concurrency.mjs`、`verify-latency-engine-runtime.mjs`。

---

## 5. 回退

| 想回退什么 | 怎么退 |
|---|---|
| TCP 传输层 | `FlclashDelay.ets` 的 `FLCLASH_DELAY_USE_TCP_TRANSPORT = false`（回 `@ohos.net.http`，同时应把 `FLCLASH_DELAY_MAX_CONCURRENCY` 降回 32，否则会重现 2300028 风暴） |
| 并发上限 | `FLCLASH_DELAY_MAX_CONCURRENCY` 改 32 |
| 3s 超时 | `FLCLASH_DELAY_TIMEOUT_MS` + `LatencyTimeout.DEFAULT_TIMEOUT_MS` 一起改回 5000 |
| 冷启动预热 | 删 `EntryAbility.onCreate` 里的 `this.scheduleLatencyPrewarm();` |
| 测速核常驻 | `TEST_CORE_IDLE_RECYCLE_MS` 改回 90000 |

## 6. 明确没做的事

- 没有改测速 URL（仍是 `https://www.gstatic.com/generate_204`；换成 `http://` 在历史上更快但会被机场劫持，属产品决策，不动）。
- 没有跳过「必然失败的广告/说明类节点」——FlClash 也不跳，且会让节点数口径不一致。
- 没有把测速核做成永不回收（保留 10 分钟空闲回收：常驻有 30~60MB 内存成本）。
