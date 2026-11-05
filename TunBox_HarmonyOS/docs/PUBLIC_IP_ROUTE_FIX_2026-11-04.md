# 代理启动到出口 IP 显示的链路检查（2026-11-04）

## 检查结论

正常连接流程原先已经在 CONNECTED 事件之前执行 `activateAppHttpProxy()`，主端点、备用端点和 UI 请求代次也都存在。但存在以下具体缺口：

1. `activateAppHttpProxy()` 失败不阻止有效 VPN 会话进入 CONNECTED，而 `PublicIpService` 每次请求按 `AppProxyRoute.isReady()` 动态设置布尔 `usingProxy`。因此代理请求通道未就绪时，会直接查询本机物理出口，违背“出口 IP”的含义。
2. 重试与备用请求重新读取全局代理状态，一轮查询可能在连接切换后改变路由。UI 代次能丢弃部分旧结果，但不能阻止额外的错误路由请求。
3. 首页自动重连时只作废在飞查询，没有同步清空现有 IP。CONNECTED 后的补查仅在 IP 为空时运行，旧值可能让补查根本不启动。
4. 补查定时器在发现已有请求进行中时也消耗次数，慢请求尚未完成就可能用尽 5 次预算。
5. mixed-port 的旧就绪探针在 clear/重新使用同一端口后晚到，能够把新会话误标为就绪。
6. 连接提交在等待 mixed-port 就绪后缺少再次校验事务/持久意图的检查，停止操作可能发生在这个 await 中间。

## 修改后的顺序

```
连接意图与配置校验
  → 内核与 TUN 就绪
  → 内核回读确认选择
  → 注册本地 mixed-port 并探测
  → 再次确认连接事务仍有效
  → CONNECTED 事件
  → 出口 IP 查询等待代理请求通道
  → 主端点 / 必要的网络重试 / HTTPS 备用端点
  → 核对路由代次、页面与请求代次
  → 显示结果
```

- 已连接和数据页查询必须使用代理通道，未就绪只返回待补查，不发送直连请求；有效 VPN 会话不因 IP 信息服务不可用而被拆除。
- 单次查询捕获端口和路由代次，使用 SDK 支持的显式 `http.HttpProxy`，全部主/备用/重试固定同一代理。断开或换会话后不再继续发送下一次请求。
- 首页在 CONNECTING、DISCONNECTING、RECOVERING 期间跳过 IP 查询；明确断开后的本机 IP 查询保留，且显式 `usingProxy=false`。
- 连接状态翻转立即清空旧 IP 并重置补查预算。真正发起补查时才计次数，等待在飞请求不计次数。
- 页面退出和数据页请求同样受页面、状态和请求代次约束。
- 数据页 shown/bootstrap 共用同一会话的在飞请求；只有连接代次已变更时才排补查，避免首次打开重复查询相同出口。
- 新增路由代次保护，旧 mixed-port 探测不能给同端口的新会话背书。
- 查询日志记录 `route=proxy:<port>` 或 `route=direct`，仍不打印 IP 地址。

## 验证

- `node scripts/verify-public-ip-route-runtime.mjs`：15 个真实生产方法运行时用例通过，覆盖未就绪、固定代理、网络重试、备用端点、路由变更、取消、迟到探针、断开直连、连接期不查询、旧 IP 清除、旧结果覆盖、补查预算和数据页重复请求。
- `node scripts/verify-public-ip-stability.mjs`：原有 37 个稳定性护栏通过。
- SDK 本机依据：`@ohos.net.http.d.ts` 的 `HttpRequestOptions.usingProxy`（支持 boolean 或 HttpProxy）；采用每请求代理对象，避免请求依赖可变的应用级代理状态。

最终构建命令：

```powershell
hvigorw.bat --mode module -p module=entry@default -p product=default -p buildMode=release -p debugLine=false clean assembleHap --no-daemon
```

- BUILD SUCCESSFUL，34 个任务实际执行，1min 15s 947ms。
- 10 组相关回归脚本通过；数据页合并调整后，IP 路由 15 项及原护栏 37 项重新通过。
- 资源编号 4/4、构建配置 13/13、实际 HAP 签名身份门禁通过。
- 最终候选包：`C:\Worker\TunBox\dist\TunBox-0.8.1-559-recovery-ip-device-signed.hap`。
- SHA256：`978DFD890FF03AEDB8918F1906B18657245B9E7863E9C18085983800BD6E2676`。
- 已覆盖安装并保留订阅、设置和当前选点；版本仍为 0.8.1 / 559，未上传或发布。

### 真机链路证据

设备当前用户选择为 ikuuu / 香港 Z03 IEPL，保持其选择不变。

- 11:28:46.942 注册 App mixed-port 7890；46.947 本地探测返回 HTTP 400，确认监听就绪。
- 11:28:46.965 本次连接耗时 2134ms；47.114 连接完成日志。
- 11:28:47.728，`after-connect` 的 ip-api 请求成功，耗时 611ms，明确记录 `route=proxy:7890`。
- 首页 IP 为弧形逐字符组件；拼接该组件与数据页完整 IP 文本对比一致。数据页显示 Hong Kong / Mong Kok / IKUUU NETWORK LTD，对应当前订阅出口。文档和查询日志不记录 IP 本身。
- 切换到数据页后两次同会话查询暴露 shown/bootstrap 重复触发，已增加合并和运行时回归；最终包另做安装验证。
- 用户主动断开后，日志明确 `route=direct`，并未被自愈拉起；强停后再安装/打开，Stage 和 Entry 均返回 `no-intent`，按钮显示“开启连接”。
- 最终包复核：11:34:17.125 mixed-port 就绪，17.295 连接完成，18.133 出口查询成功（837ms，`route=proxy:7890`）。首次打开数据页仅出现一条 11:34:38.934 `stats/stats-shown` 查询（238ms），不再紧跟重复 bootstrap 请求。验收后恢复原先断开状态。
