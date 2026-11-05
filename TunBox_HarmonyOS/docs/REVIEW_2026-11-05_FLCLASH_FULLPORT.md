# FlClash 全量照抄独立复核（2026-11-05）

## 结论与验收口径

**尚未全部改造到位，不能给这六项整体签署“与 FlClash 完全一致”。**

本次只按用户要求验收：FlClash 怎么设计，就用该设计核对 TunBox。不以审查者偏好的架构、性能或交互替代上游行为，也不把“额外功能”“更严格”“以前就是这样”自动算成允许差异。

被审查对象是当前未提交工作树，仓库 HEAD 为 `2e0e161582d98fb228eeb7dcd5d3d770911cc325`，不是仅审查该提交。没有修改应用、内核或测试断言；运行门禁会重新生成既有 harness 的 generated 文件。本报告独立于原审计底稿，保留原作者说明供核对。

### 固定上游版本，避免混用

- 原底稿 §1 指定 **chen08209/FlClash upstream main**，但没有给出固定提交。本次读取并固定为 **`be84736605527034689c95bf27828ff27d912c5e`**（提交标题 `chore(release): v0.9.3`）。以下 main 结论全部指这一提交。
- 本地鸿蒙参考库 `C:/Worker/REA/flclash_re/repo` 为 **`a2e8f138c445b8a90410010be1669fa67b794c0f`**。它是另一套版本，不能拿其 5000 ms 默认值与 main 的其他行为拼成一个验收基准。
- 旧鸿蒙分支仅用于核对平台适配的来源；其与 main 的不同明确列出。原作者当时使用的 main 未锁定，因此不能据此断言每一项 main 差异都是本轮改造引入的回归，但可以断言当前工作树不能认证为本次固定版本的 1:1 实现。
- 本次执行了 Windows 侧生产代码/真实内核检查和最小复现，**没有执行 FlClash/TunBox 真机 A/B，也没有安装 HAP**。

## 六项验收表

| 用户列出的项目 | 当前源码核查结果 | 能否认定完全一致 |
|---|---|---|
| 等价 TLS/HTTP 取回栈 | utls 单次取回已接入，但只配置 HTTP/2 transport；普通 HTTP 和 HTTPS/HTTP/1.1 均复现失败。FlClash 用 Dio 的 IOHttpClientAdapter/HttpClient；下载超时也为 20 s，而 TunBox 为 25 s | **否**。某订阅取回成功不能证明完整协议栈等价 |
| provider 交给内核拉 | `SubscriptionService` 中 provider 预拉循环、`appendProviderNodes`、`parseProviderBody` 已删除；HTTP provider 已由内核拉。file provider 的 path 收容、同名注入优先级仍不同 | **主目标已做，完整 provider 语义未对齐**。不能继续说“还在 App 预拉”，也不能说“全部照抄” |
| FlClash profile 装载/解析语义 | 新原生桥和 map builder 已接上，但仍存在 App 文本准入、不同的附加规则处理、DNS 修改与覆盖合并 | **否** |
| 不做自有节点过滤/改名/推断 | 信息节点过滤调用、旧合成组和部分自愈已删除；预览仍执行 `YamlMerger` 的去重/改名/协议判定，选点仍有名称归一化匹配，Smart 注入仍在 | **没有清理干净**。运行配置原文保留与 App 预览/选点仍有自有逻辑要分别评价 |
| 403 ≠ rateLimited | `isRateLimited()` 只接受 429，403 走 `HTTP_ERROR` | **此项命题已满足**；不意味着整个错误呈现与 current main 完全一致 |
| 测速：同 URL / timeout / -1 / -2 | 默认 URL 和 main 的 -1/-2 分类相符；TunBox 固定 5000 ms。current main 的 App 默认为 8000 ms，可配置，内核缺省兜底才是 5000 ms；并发、expected-status、provider timeout 等也有差异 | **部分一致，整体未对齐**。旧鸿蒙分支虽默认 5000 ms，但失败没有同样的 -1/-2 区分 |

## 逐项证据

### R1：取回传输能力与 FlClash 不同（已复现）

**FlClash**：[`request.dart:32`](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/lib/common/request.dart#L32) 创建 `IOHttpClientAdapter` / Dart `HttpClient`，`_download` 使用该客户端；[`constant.dart:82`](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/lib/common/constant.dart#L82) 定义下载超时 20 秒。没有要求订阅服务器必须支持 HTTP/2。

**TunBox**：[`bridge/fetch.go:52`](C:/Worker/TunBox/mihomo-build/mihomo-smart-462455136157a760937c666bba71afe33b1a809e/bridge/fetch.go:52) 唯一 transport 为 `http2.Transport`；没有普通 HTTP transport，也没有根据 ALPN 回落 HTTP/1.1 的分支。`cshared_main.go:165` 调用 `Fetch(..., 0)`，故采用 `fetch.go:50` 的 25 秒默认值。App 的 `allowInsecureHttp` 即使允许 HTTP，最终仍走该 native 路径。

最小复现使用当前 `bridge/fetch.go` 的生产函数：

| 服务端 | 生产 Fetch 结果 | 对照普通客户端 |
|---|---|---|
| 本地 `httptest.NewServer`，返回合法配置正文 | `http2: unencrypted HTTP/2 not enabled` | HTTP 200 |
| 本地 `httptest.NewTLSServer`，仅 HTTP/1.1 | `http2: frame too large` | HTTPS 200，`HTTP/1.1` |

第二个用例只给生产源码副本注入测试服务器 CA 信任根，以排除自签名证书错误；没有改 ALPN、拨号或请求处理逻辑。两个用例均为 Windows 侧检查，不宣称是设备复测。

**结论**：utls 可以是平台替代实现，但当前缺失的 HTTP/HTTP1 能力不是“鸿蒙不支持”；该层不能保留“完整等价已验收”的勾。

### R2：provider 拉取主体已迁移，path 与覆盖优先级仍非原样

**已完成的部分**：[`SubscriptionService.ets:2443`](C:/Worker/TunBox/TunBox_HarmonyOS/entry/src/main/ets/commons/services/SubscriptionService.ets:2443) 及本地导入/刷新路径均不再遍历 provider URL 拉取。全生产 ETS 搜索没有 `appendProviderNodes`、`parseProviderBody` 调用；`ProxyProviderParser` 仅余自身定义。不能再沿用“仍在 ArkTS 预拉”的旧状态。

**FlClash**：[`task.dart:135`](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/lib/common/task.dart#L135) 对所有非 inline provider 收容 path：有 URL 用 `name@url`，没有 URL 用 `section/name` 生成 MD5 路径。其 [`injectUnconfinedProviders:261`](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/lib/common/task.dart#L261) 先铺 injected，再铺原有 providers，即原有声明覆盖同名注入声明。

**TunBox**：[`TunBoxProfileBuilder.ets:509`](C:/Worker/TunBox/TunBox_HarmonyOS/entry/src/main/ets/commons/tunbox/TunBoxProfileBuilder.ets:509) 没有 URL 就直接跳过；[`同文件:594`](C:/Worker/TunBox/TunBox_HarmonyOS/entry/src/main/ets/commons/tunbox/TunBoxProfileBuilder.ets:594) 合并 App 生成的 provider 声明时，overlay 覆盖 profile 的同名声明。

实跑 compose，`rule-providers.local = {type:file,path:'./ruleset/local.yaml'}` 保留原 path；按 FlClash 同输入应收容到 `profiles/providers/<id>/rules/md5('rule-providers/local')`。

**结论**：保留 ruleset 文件位置是 TunBox 自身实现选择。若要达到 FlClash 的完整 file provider 设计，需要连同文件放置/迁移生命周期一起对应，不能把“当前改 path 会找不到文件”视作鸿蒙限制。App 生成 provider 的同名冲突规则也不能认定已按 upstream 注入行为照抄。

### R3：附加规则的处理不是 FlClash 的 matchTarget 语义（已复现）

**FlClash**：[`task.dart:338`](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/lib/common/task.dart#L338) 将附加规则中的 **目标 `MATCH`** 替换为选定的 matchTarget，或 profile 最后一条 MATCH 规则的目标；然后按原顺序前置附加规则。不是用“目标是否在集合里”过滤附加规则。

**TunBox**：[`TunBoxProfileBuilder.ets:610`](C:/Worker/TunBox/TunBox_HarmonyOS/entry/src/main/ets/commons/tunbox/TunBoxProfileBuilder.ets:610) 丢弃目标不在集合中的规则；[`同文件:737`](C:/Worker/TunBox/TunBox_HarmonyOS/entry/src/main/ets/commons/tunbox/TunBoxProfileBuilder.ets:737) 以最后一个逗号字段作为 target。

生产 compose 的同一测试中，profile 为 `MATCH,Select`，加入以下两条附加规则：

| 输入附加规则 | FlClash 对应处理 | TunBox 实跑 |
|---|---|---|
| `DOMAIN,example.org,MATCH` | 变成 `DOMAIN,example.org,Select` 并前置 | 删除（把 MATCH 当作不存在的目标） |
| `IP-CIDR,1.1.1.0/24,DIRECT,no-resolve` | 保留该规则并前置 | 删除（把 no-resolve 当作目标） |

TunBox 输出规则只剩 `MATCH,Select`。其中 no-resolve 也是 TunBox 自己规则校验器接受的参数，见 `ClashConfigGenerator.ets:2377`。这不是根据审查者喜好提出的规则设计，而是双方处理同类输入的直接差异。原底稿把此过滤称为“FlClash matchTarget 等价物”，该说明不成立。

### R4：启用的订阅 DNS 并非原样保留（已复现）

**FlClash**：[`task.dart:288`](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/lib/common/task.dart#L288) 在订阅 DNS 未启用时补 baseline，之后应用用户明确选择的 DNS 覆盖键；`appendSystemDns` 单独由设置决定。没有“只有 fake-ip 才允许 dns.ipv6=true”的条件。本地旧鸿蒙分支 `lib/common/task.dart:199` 附近也没有此条件。

**TunBox**：[`TunBoxProfileBuilder.ets:580`](C:/Worker/TunBox/TunBox_HarmonyOS/entry/src/main/ets/commons/tunbox/TunBoxProfileBuilder.ets:580) 使用 `input.ipv6Enabled && fake && finalDns['ipv6'] !== false` 重写 `dns.ipv6`。

实跑输入 `dns: {enable:true, ipv6:true, enhanced-mode:redir-host}`、App IPv6 开启、无用户覆盖，输出 `dns.ipv6=false`。

另有两个可直接核对的差异：TunBox 只在 DNS baseline 分支自动加 `system://`，没有上游独立的 appendSystemDns 语义；`overrides` 在 compose 开头用顶层 `setAll` 合并，DNS 子对象可能整段替换，而非上游逐个选定键的合并。

**结论**：原底稿“启用 DNS 原样保留”“只缺设置页清理”的表述不足以说明真实实现。IPv6 的额外条件是配置策略差异，不能仅凭注释“平台合同”就认定属于鸿蒙不支持的例外。

### R5：导入前仍有 FlClash 没有的文本准入条件（已复现）

**FlClash**：[`profile.dart:202`](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/lib/models/profile.dart#L202) 把字节写临时文件，调用 native validate，再复制入 profile 文件；[`core/config.go:83`](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/core/config.go#L83) 以读取/解析结果判断。没有先检查行首必须出现三个固定字符串的 App 闸门。

**TunBox**：[`ProfileRepository.ets:312`](C:/Worker/TunBox/TunBox_HarmonyOS/entry/src/main/ets/commons/tunbox/ProfileRepository.ets:312) 在调用 `getProfileBase` 之前先执行 `isKernelLoadableConfig`；[`ProfileConfigMerger.ets:145`](C:/Worker/TunBox/TunBox_HarmonyOS/entry/src/main/ets/commons/tunbox/ProfileConfigMerger.ets:145) 和 `:246` 只认行首 `proxies:` / `proxy-groups:` / `proxy-providers:`。不符合就走自有 converter，而不是先让 native 判定。

生产判定函数与当前真实 mihomo `UnmarshalRawConfig` 的对照：

| 内容 | native 解析 | App 文本闸门 |
|---|---|---|
| `{"proxies":[],"rules":["MATCH,DIRECT"]}` | 接受 | false |
| 带引号的顶层键 `"proxies": []`，加 `rules: ['MATCH,DIRECT']` | 接受 | false |
| 仅 `rules: ['MATCH,DIRECT']` | 接受 | false |

原文落盘和 native 解析桥已实现，但这些合法 mapping 不会直接按 FlClash 的入口顺序交给校验器。JSON 输出格式本身并不是此处问题；这里的问题是输入准入仍由不同逻辑决定。

### R6：不做自有改名/推断，还未清理干净

**FlClash**：[`core/proxy.go:39`](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/core/proxy.go#L39) 按原名查内核；[`同文件:186`](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/core/proxy.go#L186) 将用户提交的 proxyName 直接交给 selector，应用层不先去 emoji、去空格或转小写找替代名字。

**TunBox 的活动路径**：

1. [`SubscriptionService.ets:2382`](C:/Worker/TunBox/TunBox_HarmonyOS/entry/src/main/ets/commons/services/SubscriptionService.ets:2382) 仍调用 `YamlMerger.merge`；`YamlMerger.ets:3272` 后仍有指纹去重和 `uniqueProxyName`。实跑两个不同端点、同名 `A`，预览名变成 `A` / `A (2)`。
2. [`RuntimeConfigBuilder.ets:696`](C:/Worker/TunBox/TunBox_HarmonyOS/entry/src/main/ets/commons/config/RuntimeConfigBuilder.ets:696) 仍调用 `kernelLeafFor`；`:796` 精确匹配失败后走 `nodeKey`，`:858` 丢弃空格、符号/emoji并转小写。实跑 `kernelLeafFor(['A-B'], 'A B')` 得到 `A-B`。在新 profile 分支，这条调用处理候选组名，仍是实际选点链上的归一化推断。
3. `TunBoxProfileBuilder.ets:630` 仍可插入 Smart 组并改主组成员；源码自己明确注明“TunBox 产品功能，非 FlClash 行为”。这可以作为另行允许的产品扩展，但不属于鸿蒙系统不支持的例外，也不能计入“原样照抄”。

边界必须准确：**上述预览改名没有证明运行时 profile 的 proxies 也被同样改名**；原文进内核的主链路已改善。此次结论是 App 侧自有逻辑尚未全部删除，不能笼统宣称“已无过滤/改名/推断”。`ensureUniqueNames()` 本身已是 no-op，不能以它证明 `YamlMerger` 的另一路也已清除。

### R7：403 命题通过，完整错误处理不能顺带认证

[`SubscriptionFetchPolicy.ets:158`](C:/Worker/TunBox/TunBox_HarmonyOS/entry/src/main/ets/commons/services/SubscriptionFetchPolicy.ets:158) 的 `isRateLimited()` 只有 `HTTP && status === 429` 才为 true；`:244` 只把 429 放入 rateLimitStatus；[`SubscriptionService.ets:2570`](C:/Worker/TunBox/TunBox_HarmonyOS/entry/src/main/ets/commons/services/SubscriptionService.ets:2570) 把 403 放入 HTTP_ERROR。

因此 **403 不再被误归 rateLimited，用户列出的这一条通过**。

不过 current main `request.dart:83` 在记录错误后 rethrow；TunBox 仍保留 RATE_LIMITED 自定义状态及统一中文文案。原底稿中“所有错误文案逐字一致”的宽泛声明不能从“403 分类已修”推出。

### R8：测速只对齐了部分约定，版本与完整参数语义仍不同

**current main**：

- [`constant.dart:59`](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/lib/common/constant.dart#L59)：可选 500/1000/2000/5000/8000 ms，App 默认 **8000 ms**；[`models/config.dart:252`](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/lib/models/config.dart#L252) 使用该默认值。
- [`actions/proxies.dart:400`](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/lib/providers/actions/proxies.dart#L400) 取 App 设置，`:437` 将 timeout 传给 native。不能只看内核 5 s 缺省值就认为默认都是 5000。
- [`core/delay.go:13`](https://github.com/chen08209/FlClash/blob/be84736605527034689c95bf27828ff27d912c5e/core/delay.go#L13)：内核池 50，缺省 5 s，默认 gstatic generate_204；App TaskPool 的 `maxConcurrentDelayTests` 是 32。
- `core/delay.go:88` 优先查 provider 对该 URL 配置的 timeout；`:99` 使用空的 expected-status 范围；超时 -1、其他失败 -2。

**TunBox**：`TunBoxDelay.ets:45/61/101` 为 32 基线、最多 64 并发、固定 **5000 ms**。`:834` 构造请求，provider 成员走 `/providers/proxies/{provider}/{name}/healthcheck`，静态节点走 `/proxies/{name}/delay`。`ProxyPanelMembers.ets:132` 起会继承组的 expected-status，`BackgroundLatencyService.ets:284` 送入实际 DelayTarget。没有 current main 的配置 timeout 对应链。

**旧鸿蒙参考**：`lib/common/constant.dart:50` 的 5000 ms 与 TunBox 相同，App 上限是 50；但 `core/hub.go:192` 起把失败初始化为 -1，缺节点、拨测错误和超时没有 current main 的 -1/-2 区分。

**结论**：gstatic 默认 URL、当前 main 的 -1/-2 基本分类已经对应；整体测速并非固定版本的逐项照抄。Native RPC 与 REST 路径不同本身不自动算功能错误，真正不一致的是 timeout 来源、并发、expected-status 和 provider 特例等行为；要认证等价必须将这些一起对齐。

## 门禁复跑与原底稿可信边界

本次实际运行：

| 门禁 | 结果 | 不能覆盖的部分 |
|---|---|---|
| `verify-tunbox-profile.mjs` | ALL PASSED，含真实 mihomo `-t` | 证明生成配置可加载；没有证明所有 patch 与 FlClash 同义 |
| `verify-profile-merge-providers.mjs` | 6/6 | 其中断言正是“file path 原样”“overlay 同名优先”，与上游不同；通过只是符合本仓契约 |
| `verify-tunbox-delay.mjs` | 11/11 | 断言当前 32/64、5000；不是对 current main App 默认 8000 的差分测试 |
| `verify-sub-fetch-parity.mjs` | 21/21 | Basic 鉴权/标题等；未覆盖 native HTTP/HTTP1 的实际传输 |
| `verify-import-diagnostics.mjs` | 21/21 | 诊断呈现，不是全部合法 native mapping 的准入覆盖 |
| `verify-mihomo-alignment.mjs` | 93/93 | 包括静态检查 native fetch 接线、429 分类；未发现上述传输能力差异 |

所以不能从“重写后的门禁全绿”推出 1:1。也没有证据据此指控改测试的主观动机：可以确认的是，若干测试把 TunBox 自定义取舍固定为预期，而没有以同版本 FlClash 的结果为预期。

原底稿明确未完成的真机 A/B、设备 arm64 JSON 配置启动、私样本 fidelity、无效 DNS 开关 UI 清理等，仍然不能算完成。本次没有复跑 verify-all 或重新构建/签名，不把底稿中的 `94 PASS / 1 FAIL / 2 SKIP` 当作本轮新结果。

## 不应误判的项

- JSON 作为内核输入本身不是差异证据：当前真实 mihomo `-t` 已接受。若加载语义一致，不需要为了文件外观相同而强行要求 ArkTS YAML emitter；设备端验证仍独立待做。
- Go/NAPI 承担解析、原生线程桥、VPN fd 注入是可接受的平台实现方式；验收应看结果是否对应。
- `find-process-mode=off` 有本地 FlClash 鸿蒙分支 `task.dart:131` 的明确依据，不能凭 upstream 非鸿蒙默认值就说它错。
- INFO 过滤调用、provider App 预拉、旧合成组等已删的工作应计入完成，不能沿用历史“未做”标签。
- file provider 路径不收容、附加规则删除、名称归一化、Smart 自动插组、redir-host DNS IPv6 改写，则没有因此变成“鸿蒙不支持”的证明；它们必须在严格对齐表中明确列为差异。

## 后续验收所需动作

1. 使用一个明确提交作为六项共同上游基准；平台例外逐项给出鸿蒙分支或系统能力依据。
2. 按该版本处理 R1–R6、R8；已允许的产品扩展需进入明确白名单，不能用“更好/更严格”代替等价性。
3. 将上表反例纳入针对上游行为的回归验证；不要只检查本仓当前输出。
4. 再进行同订阅、同设置、同设备条件下的 A/B，完成 provider-only、file provider、redir-host IPv6、规则参数、导入格式与测速参数的验收。

清理预检发现全局清理脚本会涉及其他 Agent 的签名/构建材料，故没有执行全局删除。本轮仅针对自己创建的 `C:/Users/Administrator/AppData/Local/Temp/tunbox-probe-flclash-audit-20261105` 尝试清理：递归清理及随后限定明确文件名的非递归清理均被自动审批策略拒绝，工具仅返回 `blocked by policy`，未给出更具体原因。临时文件仍保留；没有删除他人的工作材料。
