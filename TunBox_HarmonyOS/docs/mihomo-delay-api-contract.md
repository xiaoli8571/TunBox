# mihomo 延迟测试 API 契约（TunBox 实测存档）

**实测环境**：TunBox 5.5.6 真机（MLR-AL00 / API 24），内核 `{"meta":true,"version":"1.10.0"}`
通过 `hdc fport tcp:19090 tcp:9090` 把设备 controller 转发到 PC，用 Node/curl 直接打 API。
配置含 47 个真实节点（46 可用 + 1 手填），11 个 select 组。

## 1. 单节点延迟

```
GET /proxies/{urlencoded-name}/delay?url={urlencoded}&timeout={ms}
```

| 场景 | HTTP | 响应体 | 实测耗时 |
|---|---|---|---|
| 成功 | 200 | `{"delay":81}` | 371ms |
| 真超时（黑洞 URL，timeout=1500） | 504 | `{"message":"Timeout"}` | 1578ms |
| 节点不存在 | 404 | `{"message":"Resource not found"}` | — |
| 内建类型（DIRECT/REJECT/GLOBAL 实测） | 503 | `{"message":"An error occurred in the delay test"}` | — |
| 缺 url 参数 | 503 | `{"message":"An error occurred in the delay test"}` | 66ms |

- `expected=204` 参数**被接受但无可见行为差异**（返回与不传一致），不是必须项。
- 超时时间由 `timeout` 决定，**内核侧计时 + 504**，客户端可依赖它而不必自己 race 超时。

## 2. 组延迟（关键发现）

```
GET /group/{urlencoded-name}/delay?url={urlencoded}&timeout={ms}
```

- **存在且可用**：`/group/PROXY/delay` → `{"日本":105}`、`/group/GLOBAL/delay` → `{"DIRECT":220,"PROXY":95,"日本":98}`。
- **一次请求测整组**：`/group/PROXY/delay` 对 **58 个成员**返回完整 map，实测 **5073ms**（热）/ **3087ms**（冷启动，46 节点）。
- **失败节点被省略**（不是返回 0 或 -1）：强迫全组走黑洞 URL 时返回 504 `{"message":"get delay: all proxies timeout"}`；部分失败时失败的键**不出现在 map 里** → 调用方必须把「map 里没有」当作失败，不能当作未测。
- 组不存在 → 404 `Resource not found`。
- `GLOBAL` 里的 `DIRECT` 会被真实测量（825ms，即本机到测试 URL 的直连延迟），**不是 0**。
- select 组按其 `now` 当前选中项参与测量（`☁️ OneDrive`、`🇨🇳 国内网站` 等嵌套 select 也返回数值）。

**效率对比（同一内核、同一 URL、timeout=3000）**：
| 方式 | 节点数 | 耗时 |
|---|---|---|
| `/group/{g}/delay` 一次请求 | 46 | **3087ms** |
| 逐节点 `/proxies/{n}/delay` 串行 | 10 | 2571ms |

→ group 端点约 **4× 吞吐**，且并发完全由内核内部调度，客户端不再需要自己管 10 路 lane。

## 3. `/proxies` 结构（用于取证与失败判定）

```
{"proxies":{"<name>":{"type":"Shadowsocks","alive":true,
                      "history":[{"time":"...","delay":74}],
                      "now":"...","all":[...]}}}
```

- **`history[last].delay == 0` 表示失败**（实测死节点 `alive=false, hist=0ms`；活节点 `hist=74ms`）。`0` 绝不能当真实延迟显示。
- `all` 存在即为组（Selector/URLTest 等）；`now` 为当前选中项。
- 内建项：`COMPATIBLE/DIRECT/GLOBAL/PASS/PASS-RULE/PROXY/REJECT/REJECT-DROP`。
- 组按 `type` 区分：`Selector` / `URLTest` / `Fallback` / `LoadBalance` / `Relay` 是组；`Direct`/`Reject`/`RejectDrop`/`Compatible`/`Pass`/`PassRule` 不可作为被测节点。

## 4. 并发实测

6 路并行单节点请求 → wall 842ms，全部 200，各自 77~156ms。
内核自身并发能力充足，**瓶颈在客户端 lane 数与超时预算**。

## 5. 对 TunBox 的结论

1. 现有「为测速拉起第二个无头内核进程（VpnExtensionAbility + mihomo_test_config.yaml）」是**完全不必要的**：组端点已经在内核内并发调度，且真实隧道运行时 controller 就在 9090。
2. 现有 46 节点批测要经历：生成测速配置 → 停旧扩展 → 600ms 等待 → 启新扩展 → 健康轮询 → 10 lane × /delay → 回收 → 90s 宽限定时器；新方案只需**一个 HTTP 请求**。
3. 失败语义必须三分：**成功（有数值）/ 失败（组 map 里缺失，或单测 504）/ 未测（批次取消或未覆盖）**。内核 `history.delay==0` 与 map 缺失都属失败，绝不能显示成「0ms 很快」。
4. 测速 URL 传 `http://cp.cloudflare.com/generate_204` 与 `http://www.gstatic.com/generate_204` 均可用；用 `http://` 而非 `https://` 可省一次 TLS 握手（现有代码用 https，见 ClashApiService 调用点）。
