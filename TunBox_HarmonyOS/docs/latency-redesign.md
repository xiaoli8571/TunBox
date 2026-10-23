# 延迟测试重做 · 设计说明（5.6.0）

> 结论先行：延迟测试从「页面自己开 10 路 lane + 未连接时另起一个无头内核 + 整批级 URL
> 降级」重做为**单一引擎**（`LatencyEngine`）+ **显式五态以上状态机**
> （`LatencyState`）+ **可取消的确定性进度**。测速结果不再是 `Map<string, number>`
> 加哨兵值，而是带时间戳与通道来源的记录。

## 一、旧实现为什么"难用"

| # | 现象 | 根因 |
|---|---|---|
| 1 | 点「测全部」半天不出第一个数字 | 未连接时要先拉起**第二个** VpnExtensionAbility 内核：DoH 预解析 → 停旧扩展 → 600ms 等待 → 启新扩展 → 健康轮询（20s 超时） |
| 2 | 全列表"超时"（真机 143 节点） | 两个内核共用 9090 端口但 secret 不同，凭证被覆盖后全部 401；旧实现把 401 也归入"超时" |
| 3 | 点了像没反应 | 命中"10s 内测速缓存"直接返回"无需重新测速"，无任何提示 |
| 4 | 好节点被写成超时 | 队列等待与探测**共用一份超时预算**，排在饱和 lane 后面的节点被前面的耗时吃掉 |
| 5 | 死节点排最前 / 显示 `0ms` | `history.delay == 0` 是**失败**语义，被当数字参与升序排序 |
| 6 | 没测过却显示"超时" | 只有 `-1/-2` 两个哨兵，UI 无法区分未测/超时/失败/取消 |
| 7 | 结果永远是几分钟前的 | 没有时间戳，无法表达新鲜度 |
| 8 | 无法中止 | 没有取消入口；且旧实现自己也说不清"取消"算什么状态 |
| 9 | 后台静默测速与手动测速互相打断 | 两套独立管线（`BackgroundLatencyService` vs 页面 `runBatch`）+ 手动优先级抢占 + 代次校验 |

## 二、实测得到的关键事实

全部来自真机（MLR-AL00 / API 24，mihomo 1.10.0）与 mihomo 源码交叉验证，
详见 [`mihomo-delay-api-contract.md`](./mihomo-delay-api-contract.md)。

1. `GET /proxies/{name}/delay?url=&timeout=` → `200 {"delay":N}`（N≥1）；
   强制超时 `504 {"message":"Timeout"}`；未知节点 `404`；内建项 `503`；
   `timeout` 按 **16 位**解析（>32767 → 400），且**必须显式传**（不传 400）。
2. `GET /group/{name}/delay` **能用但是陷阱**：对 url-test 系组忽略传入 `url`、
   对非 Selector 组 `ForceSet("")` 清掉用户固定选择、无并发上限（每节点一 goroutine）、
   失败节点从结果 map 里**静默消失**，且可能返回 `200` + **部分**结果。
   → **本实现完全不用它**（套件里有负向断言）。
3. `(*Proxy).URLTest` 直接 `p.DialContext` 到出站适配器，**绕过 TUN 与规则引擎**
   → 只要内核已加载，测速与"VPN 是否连接"无关。
4. **已连接时隧道的 controller 就带着全部真实节点**（实测 128 条目 = 106 真实节点
   + 16 组 + 内建；全部在 `PROXY` 组内）→ 直接复用，零额外启动。
5. `history[last].delay == 0` 表示**失败**；`LastDelayForTestUrl` 用 `65535` 表示
   "没测过"。**两者都不是有效延迟**。
6. **取消不释放内核 socket**：`getProxyDelay` 用 `context.Background()`，abort 只是
   客户端行为，内核会继续拨号到自己的 timeout → 并发上限是控制负载的唯一手段。
7. `unified-delay` 下 `http://` 测速 URL 在劫持型代理里会失败（mihomo 官方警告）
   → 统一 HTTPS。

## 三、新架构

```
                      ┌─────────────────────────────────────────────┐
   已连接 ────────────► ① 复用隧道内核 controller（带全部真实节点）
                      │    零额外启动、零额外内存                    │
   未连接 ────────────► ② headless 测速内核（无 TUN，独立 secret）    │
                      │    mihomo 探测绕过 TUN，故能得到**真实**延迟  │
   内核不可用 ────────► ③ 离线直连探测（TCP/TLS/QUIC）                │
                      │    UI 显示 ≈123ms，只代表"服务器可达"         │
                      └─────────────────────────────────────────────┘
                                      │
                            LatencyEngine（唯一入口）
        · 有界并发 8（移动端，取主流客户端 5~16 的下沿；内核侧无上限，客户端必须自律）
        · 队列等待与探测计时**分离**（单节点预算 5000ms，不跨节点累计）
        · 首批请求错峰抖动 0~200ms，避免整批同时撞内核
        · 整批硬截止 90s：到点未完成的节点保持**未测**，绝不写失败
        · 单航班：新批次自动作废旧批次，旧回调丢弃结果
        · 进度：确定性 finished/total + 取消
```

**与初版设计的偏差（实现时修正，记录以免误导后来者）**：

- 初版想连"无头测速内核"一起删掉。**没有删**：mihomo 的探测需要**已加载的内核**
  才能拨出站适配器，未连接时若不启内核就只能给"离线粗略值"，而"未连接也要能测出
  真实延迟"是这次重做的核心诉求。因此保留内核，但把它收进 `ensureLatencyApi()`
  统一决策（已连接复用隧道 → 未连接起 headless → 都不行才降级），页面不再直接碰它。
- `TestCoreFlight` 单航班状态机与 90s 宽限回收**保留**（既有实现是可靠的、被
  LogicTest 覆盖的）。回收改为**由引擎在每批结束后挂起**，并在
  `scheduleTestCoreRecycle()` 里加了硬安全闸：`CONNECTED/CONNECTING/DISCONNECTING/
  RECOVERING` 四态直接拒绝回收 —— 因为测速内核与真实隧道**共用同一个
  VpnExtensionAbility 进程**，一次误回收就会把用户正在用的 VPN 停掉。
- 真正**删除**的是页面里那套 700 行并行管线（lane 池、整批级 URL 降级、通道熔断、
  整批零成功判定、负缓存、代次校验、directReachableNames）与
  `BackgroundLatencyService` 里第二套并行实现 + 手动/后台抢占机制。

## 四、状态语义（UI 必须可区分）

| 状态 | 含义 | 触发 |
|---|---|---|
| `MEASURED` | 实测代理延迟 N ms | `200 {"delay":N}`，N ≥ 1 |
| `TIMEOUT` | 内核侧超时 | `504 {"message":"Timeout"}` |
| `FAILED` | 探测失败（拨号失败/状态码不符/`delay==0`） | `503` |
| `CANCELLED` | 用户取消/网络切换中断，**不是节点结论** | 客户端 abort |
| `OFFLINE` | 离线粗略可达性（≈N ms），**不是代理延迟** | 兜底通道 |
| `TESTING` | 测试中（UI 显示 spinner） | 探测在途 |
| `UNTESTED` | 从未测过 | 初始态 |

外加 `atMs` 时间戳（>10 分钟灰显为"旧"）。状态必须**一路带到 UI / 日志 / 持久化**，
禁止把 `FAILED` 折叠成"超时"、禁止把通道不可用折叠成"超时"。

## 五、UI 规范（实现口径）

- **徽标**：`123ms` / `≈123ms`（离线）/ `超时` / `失败` / `--`（未测）/ spinner（测试中）。
- **配色**：沿用 `LatencyStyle` 既有阈值（`<180` 绿 / `<350` 琥珀 / 其余红）——
  这三个阈值被 `ohosTest/LogicTest.ets` 断言，本次**不动**；过期结果用次级文字色灰显。
- **排序**：实测升序 → 离线 → 未测/已取消 → 超时 → 失败。**失败永不排最前**
  （CMFA 的朴素升序把死节点顶到最上，是公认痛点）。
- **进度**：顶栏确定性 `finished/total` + **取消按钮**（旧实现没有取消）。
- **过滤**：只测真实出站节点，排除组类型（`Selector/URLTest/Fallback/LoadBalance/
  Relay`）与内建项（`DIRECT/REJECT/REJECT-DROP/COMPATIBLE/PASS/PASS-RULE/DNS`）。
  本项目 `PROXY.all` 里混着 14 个组条目，不过滤会把"组当前选择的那个节点"的延迟
  张冠李戴到组上。
- **测全部** = 当前筛选（订阅 chip）后的节点列表，且**总是强制重测**
  （修掉旧版"命中缓存所以什么都不做"）。
- **自动测速**：进页面时跑一次 `force=false` 的批次（跳过 5 分钟内的新鲜结果，
  计为 `skipped`），冷启动由 `BackgroundLatencyService.scheduleStartup` 静默补齐一次；
  两者都不弹提示、不阻塞渲染。
- **结果持久化**跨重启 + 显示新鲜度（主流客户端普遍不做，是我们的差异点）。

## 六、验证

- `scripts/test-latency-engine.js`（取代已删除的 `test-latency-pipeline.js`）：
  源码级接线与**旧缺陷不许复活**的负向断言 —— 唯一入口、禁止 `/group/*/delay`、
  未连接路径必须经 `ensureLatencyApi`、HTTPS URL、并发上限、`timeout` 显式且 ≤32767、
  硬截止不写失败、取消≠失败、通道不可用≠节点失败、组条目过滤、回收安全闸、
  生成器逐字节未变（指纹 `scripts/latency-gen-fingerprint.json`）。
- `scripts/verify-latency-cache.mjs`：把 `LatencyState.ets` / `LatencyController.ets`
  按 `.ts` 暂存后在 Node 里**真实驱动**（45 项）—— 五态迁移、`0ms` 不是延迟、
  `65535` 不是延迟、排序、组过滤、`retainOnly`。
  （Node 的 type-stripping 只接受可擦除语法，故 `LatencyState` 用 class +
  static readonly 而非 `enum`。）
- 真机实证：已连接（隧道 controller）与未连接（headless 内核）各测一轮，
  记录 106 节点的完成耗时与各状态分布。

## 七、2026-10-20 指纹变更说明（订阅解析内核化整改）

`scripts/latency-gen-fingerprint.json` 的 `sha256_16` 由 `24b343b951d49000` 更新为
`188c5f3fec6c65f5` —— 原因是**配置生成器按整改方案 C16/C17/C18/C19/C20/C21/C22/C24/C4
被修改**，与测速引擎本身无关。逐条改动如下（供日后回看「谁动了生成器」）：

| 项 | 改动 | 目的 |
|---|---|---|
| C16 | 新增公共 API `parseProviderBlocks` / `providerBlockKeyNames`（provider 块按**纯缩进层级**判定，不再用 `/^([A-Za-z0-9_-]+):$/`） | 点号 provider 名（`my.provider:`）不再被误判成字段行 → 修 R1（provider 块被拍平、引用它的 RULE-SET 被静默丢弃） |
| C19/C20 | provider 去重改为**整块丢弃**（键行 + 全部字段行）；「输出去重集合」与「RULE-SET 引用账本」拆成两个独立集合 | 修 R4（只丢键行 → 字段行落进上一条 provider → `mapping key "type" already defined`）与 R4'/R4'''（字段键名不撞时**静默并错** provider） |
| C17 | 覆盖层从「整段追加」改为「允许覆盖 + 结构化合并」：同名顶层段整段替换、覆盖层自身重复键留首个、未知顶层键**保留并 warn** | 修 R2（覆盖层写 `dns:` → 与生成段的 `dns:` 撞顶层键 → 整份拒载），同时保住用户能力 |
| C18 | 覆盖层布尔归一改为**路径感知**（只认已知 bool 字段路径） | 不做全局文本替换，不擅自改用户原文 |
| C21 | `rules` 行的 `- ` 前缀在生成入口自剥 | 修 R6（`- - RULE` → `cannot unmarshal !!seq into string`） |
| C22 | `profile.store-selections` → `profile.store-selected`；`find-process-mode: off` → `find-process-mode: "off"` | 前者是**错键名**（内核 `RawConfig.Profile.StoreSelected` 不认 `store-selections`，功能一直失效）；后者消除与布尔写法的歧义 |
| C4 | `safeGroupUrl` 兜底 `http://` → `https://`（用户/订阅自己声明的 url 原样不动） | 与 T1 的 https 化一致（明文测速地址会被出口劫持） |

同时纠正了生成器内两处**错误注释**：「mihomo 对同一 YAML 里的重复顶层键是后者覆盖前者」
—— 与 yaml.v3 的 `uniqueKeys` 相反，实际是**报错、整份拒载**；这正是 R2/R4/R5 三条
根因的认知根源。

> 补充（内核实测结论，与本文档早期推断相反）：
> `allow-lan: yes` 这类**不带引号**的 YAML 1.1 布尔，真实内核（mihomo Meta 1.10.0，
> `mihomo.exe -t` 逐例实测）是**接受**的 —— yaml.v3 对 **bool 目标**有 YAML 1.1 兼容分支；
> 真正会让整份配置拒载的是**带引号**的 `"true"/"false"/"1"/"0"`
> （`cannot unmarshal !!str \`true\` into bool`）。
> 交叉验证脚本：`scripts/verify-config-validator-kernel.mjs`。

## 八、2026-10-20 指纹变更说明（A12c：测速地址单一真源）

`scripts/latency-gen-fingerprint.json` 的 `sha256_16` 由 `a51e7dd946dcb136` 更新为
`4f1c772e9662ca2c` —— 原因是**测速地址此前有两份实现**（审计 F12），本次把规则收敛到唯一真源
`commons/latency/LatencyTestUrl.ets`（零 import ⇒ 不会形成循环依赖）。与测速引擎本身无关。

| 项 | 改动 | 目的 |
|---|---|---|
| A12c-1 | 新增 `import { LatencyTestUrl } from '../latency/LatencyTestUrl'` | 测速地址规则的唯一真源（`LatencyTestUrl.effective()`） |
| A12c-2 | `generate()` 末尾新增**可选**参数 `smartTestUrl: string = ''`；调用方（`RuntimeConfigBuilder`）传入用户填的原始值 | 生成器**不再自己读用户的测速设置**，也不再有「参数从哪来」的第二条通路 |
| A12c-3 | smart 组的 `url` 改由 `LatencyTestUrl.effective(smartTestUrl)` 决定 | 原来直接读 `settings.testLatencyUrl`，**非法值不校验**（能写进 YAML）；现在非法/空 → 默认 https（与内核默认一致） |
| A12c-4 | `safeGroupUrl()` 去掉自带的 `http(s)` 前缀判定与 gstatic 兜底常量，改调 `LatencyTestUrl.effective()` / `LatencyTestUrl.DEFAULT_URL` | 订阅自己声明的 url **仍原样保留**、YAML 安全检查与转义**不变**；只有「合法性/默认值」这一段规则改由真源决定（历史 http 默认值按真源口径升级为 https） |

> 复现门禁：`node scripts/verify-latency-core-v2.mjs`（A12c 项，本次 **65 passed / 0 failed**）
> 与 `node scripts/verify-generator-fingerprint.mjs`（指纹一致）。
> 与本次改动同批的还有 `scripts/verify-config-single-source.mjs`（唯一生成入口，42/0）。

## 九、2026-10-20 指纹变更说明（IPv6 双栈 + DNS 覆写开关）

`scripts/latency-gen-fingerprint.json` 的 `sha256_16` 由 `668f5269db380849` 更新为
`8490f80ef2985e3a` —— 原因是**设置页新增两个网络开关、配置生成器去掉 IPv4-only 硬编码**，
与测速引擎 / 延迟口径无关。逐条改动如下：

| 项 | 改动 | 目的 |
|---|---|---|
| V6-1 | 顶层 `ipv6:` 与 `dns.ipv6:` 改由 `generate()` 的 `ipv6Enabled` 参数驱动（默认 true）；调用方 `RuntimeConfigBuilder` 传 `settings.ipv6Enabled` | 原来 `ipv6: false` / `dns.ipv6: false` 是硬编码，`ipv6Enabled` 形参声明了却**从未被读** —— IPv6 在任何设置下都不可能生效 |
| V6-2 | ~~双栈开启时新增 `fake-ip-range6: fc00::/71`~~ → **当天即改回「不下发」**（真机取证后修正） | 2026-10-20 真机三次隧道在线逐次对账 `/proc/net/ipv6_route`：HarmonyOS **不安装 VpnConfig 里的任何 IPv6 路由** —— `::/0` 的三种写法（destination/gateway 带 `family:2`、不带 family、`interface` 留空）与 `fc00::/71` 具体前缀路由**全部被静默丢弃**，vpn-tun 上只剩地址派生的 `/126`、`fe80::/64`、`/128`、`ff00::/8`（v4 默认路由正常装上）。假 v6 池没有路由可达 ⇒ 拿到 `fc00::x` 的应用必然连不通，故删掉该行；`dns.ipv6` 保留 |
| V6-3 | 删除 `disable-ipv6: true`，并从 `KNOWN_TOP_LEVEL_KEYS` 移除该键 | 它不是 mihomo 顶层键（非 strict unmarshal ⇒ 静默忽略；实测塞 `totally-bogus-key` 后 `mihomo -t` 仍 successful），留着只会误导「IPv6 已关闭」 |
| L-TO | 2026-10-20 晚：单节点测速超时 5000ms → **3000ms**（LatencyTimeout.DEFAULT_TIMEOUT_MS / LatencyProbeLimits.NODE_TIMEOUT_MS / GROUP_TEST_TIMEOUT_MS / ClashApiService.testLatencyDetailed 的默认值四处同改） | 用户明确要求「超时判断现在是 5 秒改为 3 秒」；3s 有历史真机证据：飞鸟云 35 个 hysteria2 节点在 3s 下能测出 143/558/560ms，而 1s 时 31/31 全误杀 —— 3s 既能测出慢节点又比 5s 少等 2 秒/节点 |
| V6-4 | 2026-10-20 晚曾按方案 B 把 `dns.ipv6` 拆成独立开关、`fake-ip-range6` 做成高级项；**用户当天复核后要求精简** ⇒ 两处一起撤销：`dns.ipv6` 仍由 `ipv6Enabled` 统一驱动，`fake-ip-range6` 恢复「永不产出」 | 精简理由：`dns.ipv6` 只在 `dns:` 段存在时才有意义（关掉「DNS 覆写」整段 dns 都不生成），单独摆开关会出现「开着却无效」的死开关；`fake-ip-range6` 在 HarmonyOS 上因不装 v6 路由必然是黑洞，留一个能填的输入框只会误导。最终设置页只剩「IPv6 双栈 / DNS 覆写」两个开关 |
| DNS-1 | `dns:` 整段抽成 `private static pushDnsSection()`（唯一写入点，导出 YAML 字节不变；`blockSites` 由调用方规范化后传入，路由层兜底共用同一份） | 让「DNS 覆写」开关能整段关闭，而不必复制粘贴 150 行 |
| DNS-2 | 新增 `settings.dnsOverrideEnabled` 门：关闭时只写 `dns: { enable: false }`、不产 `tun.dns-hijack` | 内核不跑 DNS 却仍劫持 53 ⇒ 设备原本正常的系统 DNS 会被打断 |

> 复现门禁：`node scripts/verify-generator-fingerprint.mjs`、
> `node scripts/verify-vpn-architecture.mjs`（IPv6 / DNS 断言已同步改写）、
> `node scripts/verify-config-single-source.mjs`（唯一生成入口）、
> `node scripts/verify-config-generation-integrity.mjs`（真内核 `mihomo -t` 判定，61/0）。
> 真机取证：2026-10-20 hdc 实测设备有全局 IPv6（2409:8a55:d154:dae1::/64）而隧道在线时
> `ping6 2001:4860:4860::8888` 仍直连成功、`vpn-tun` 上 `::/0` 为 0 条 ⇒ v6 绕过代理；
> 本改动后需在真机复验：`::/0` 出现在 `vpn-tun`、隧道 DNS 对 AAAA 有 v6 应答。

## 十、2026-10-21 指纹变更说明（订阅 DNS 上游透传：修「测速几乎全部超时」）

指纹：`22c9d271de845e95`。改动**只发生在配置生成器的 DNS 段**（`generate()` 参数表 +
`pushDnsSection()` + 五个校验 helper），与测速引擎、延迟口径无关。

### 为什么必须改

用户报障：「这个订阅在 TunBox 测速几乎全部超时，FlClash 测速完全正常」（筋斗云 anytls）与
「FlClash 解析 36 个节点、TunBox 少了 20 个，测速也全部超时」（pronetwork hy2/tuic）。

真机 + 真实内核（Mihomo Meta 1.10.0）双重取证后的根因：**机场把「入口域名 → 真实入口 IP」
只告诉自家私有 DoH**，公共 DNS 解析出来的是 Cloudflare / 阿里 WAF 前置 IP：

| 订阅 | 承载「代理域名解析上游」的键 | 公共 DNS 的答案 | 私有 DoH 的答案 |
|---|---|---|---|
| 筋斗云 | `dns.proxy-server-nameserver` | `172.64.153.74`（CF），18104–18503 **全部 TCP timeout** | `35.220.165.7` 等 GCP 入口，**OPEN** |
| pronetwork | `dns.nameserver-policy`（`+.jushuitan.com`） | `60.205.172.133`（阿里 WAF），4430 可握手但**不服务** anytls/hy2/tuic | `64.120.95.49` / `36.226.53.194` 等真实机房 |

而本生成器此前把订阅 `dns:` **整段丢弃**、固定写公共 DoT ⇒ 两个订阅的域名节点必然全灭。
真实内核单变量实验（配置只差一行）：订阅1 原样 **20/23** 通 → 只删 `proxy-server-nameserver` 变 **7/23**；
订阅2 原样 **30/36** → 只删 `nameserver-policy` 变 **0/36**。

### 改了什么

| 项 | 改动 | 目的 |
|---|---|---|
| D1 | `generate()` 末尾新增 `subscriptionDnsProxyServers: string[] = []`、`subscriptionDnsPolicies: string[][] = []` | 给订阅 DNS 上游一条**显式入参**通道（生成器不自己读订阅，保持单一真源） |
| D2 | `pushDnsSection()` 的 `proxy-server-nameserver:` 改三分支：订阅上游 > 订阅 policy（**留空**）> 内置公共 DoT | 订阅1 走第一支；订阅2 必须走第二支——mihomo `hub/executor/executor.go:304-307` 里该键非空就用**专用解析器**且不查 `nameserver-policy`，留着 DoT 会把 policy 顶掉（实测 `31se.jushuitan.com → 60.205.172.133` 全灭） |
| D3 | 新增 `normalizeNameservers()` / `normalizeNameserver()`：上游白名单（https/tls/quic/h3/udp/tcp/system/dhcp/裸 IP:port），拒绝含空格/引号/反斜杠/逗号/括号的输入 | 订阅内容是不可信输入，拼进 YAML 前必须过关（防注入破坏行结构） |
| D4 | 新增 `normalizeDnsPolicies()` / `normalizePolicySuffix()` / `policyMatchesAny()`：只保留**后缀命中本份配置节点域名**的 policy 条目 | 机场常在 policy 里顺手写别的域名（如订阅1 的 `+.bestqaq.com`、订阅2 的 `+.bokecc.com`），注入进用户 DNS 策略属于越界 |
| D5 | 同一后缀的多个上游合并成**一个** policy 键 + 多值列表 | 机场常给两个私有 DoH 互为冗余；逐条 push 同名键 = YAML 重复键 ⇒ 内核整份拒载 |
| D6 | `Subscription` 新增 `subDnsProxyServers` / `subDnsPolicies`（JSON），`SubscriptionService.applyDnsSections()` 在三条导入/刷新路径落账，`subscriptionDnsProxyServers()/subscriptionDnsPolicies()` 聚合给 profile | 与 `subRules` / `subRuleProviders` 同一套模式：拉取时提取、生成时使用 |

### 复现与门禁

- `node scripts/verify-config-generation-integrity.mjs` 新增 **[14] 订阅 dns 上游透传** 五个场景
  （无订阅→DoT 兜底 / 有上游→整段替换 / 只有 policy→该键留空且 policy 生效 /
  policy 与节点无关→不注入 / 非法上游→过滤）
- `node scripts/verify-vpn-architecture.mjs` 新增 4 条分支形状与接线断言
  （`dns.subscription-upstream-branch` / `-policy-branch` / `-upstream-wired` / `-policy-wired`）
  —— 此前只锁「DoT 字面量还在源码里」，等于奖励把订阅分支写死成 DoT
- 本机真内核实测（`mihomo.exe -t` + `/proxies/{name}/delay`）：
  订阅1 修复后 `香港01 256ms / 美国03 501ms`；订阅2 修复后 `hy2 233ms / anytls 408ms / 280ms`（修复前全 503/504）
- 端到端取证报告：`C:\Worker\diag\DIAGNOSIS_2026-10-20.md`、`kernel-lab.md`、`device-flclash.md`

## 十一、2026-10-21 指纹变更说明（更正 IPv6/AAAA 事实 + 探针判据）

指纹：`22c9d271de845e95` → `5b482c987987d0db`。**只改了 `ClashConfigGenerator.ets` 的注释，导出的 YAML 逐字节不变**（`fake-ip-range6` 依旧不产出）。

> ⚠ 本节 P-1 / P-2 / T-2 三项（按 `isDnsOverrideEnabled()` 分流探针、`dnsOverrideActive` 快照、
> `TunFlags.dnsOverride` 默认 false）已在 §十二（2026-10-21 删除 DNS 覆写开关）中**整体废弃**：
> 开关不存在了，探针恢复严格判据，TUN 不再读 `dns.enable`。保留本节仅为还原当时的推理链。

### 为什么改

上一节（§九 V6-2）的结论只有一半：平台不装 v6 路由 ⇒ 删掉 `fake-ip-range6` 是对的；但随之写进生成器注释的「`dns.ipv6` 保留，AAAA 返回**真实** v6 地址，v6-only 站点可用」与内核源码矛盾：

- `dns/middleware.go:149-197` 的 `withFakeIP`：`fakePool6 == nil` 时 AAAA 直接 `handleMsgWithEmptyAnswer`，**比 `withResolver` 的 `ipv6` 判断（`:205-208`）更早短路**；
- `dns/enhancer.go:172-194` 的 `NewEnhancer`：只有 `cfg.IPv6` 为真**且** `FakeIPPool6 != nil` 才装配 v6 池；
- `config/config.go:1586-1600`：`FakeIPPool6` 仅在 `dns.fake-ip-range6` 有效时创建。

⇒ 当前配置下 AAAA **恒为空**，`dns.ipv6` 对客户端拿到的答案没有影响，v6-only 站点不可用。

### 连带修正

| 项 | 改动 | 目的 |
|---|---|---|
| P-1 | `OrchestratorHealthProbes.probeIpv6` 按 `isDnsOverrideEnabled()` 分流：覆写开 → `skip`（写明「已知限制，不是故障」）；覆写关 → `fail` + 建议关闭 IPv6 双栈，修复动作 `check-uplink` | 旧实现固定 `fail + 重启隧道`，在默认配置下每个用户都会看到一条永远修不好的红项 |
| P-2 | `ConnectionOrchestrator` 新增 `dnsOverrideActive` 快照 + `isDnsOverrideEnabled()`（与 `ipv6Active` 同源同时刻，断开时清零） | 探针需要可信的「本次连接是否接管 DNS」事实，不能回读可变设置 |
| T-1 | `VpnExtensionAbility.readTunFlagsFromConfig` 改用 `readTopLevelBool` / `readNestedBool`（容忍 `yes/on/1`、带引号、流式 `dns: {enable: true}`、行尾注释、CRLF） | 旧实现是整行字面量正则；覆盖层经 C17 结构化合并后一旦变成流式写法，TUN 会静默退回「IPv4-only + 不覆盖 DNS」，而内核照旧接管 DNS |
| D-1 | `DNS_SERVERS` 由公共 DNS `223.5.5.5/119.29.29.29` 改为 TUN 内 sentinel `172.19.0.2`（对齐 FlClash `android/service/.../VpnService.kt:300` 的 `DNS = "198.18.0.2"`；本仓 TUN 为 `172.19.0.1/30`，对端唯一地址）；**刻意不下发 v6 DNS** | 公共 DNS 能否被 `tun.dns-hijack: any:53` 截住取决于默认路由是否命中；sentinel 落在 TUN 自身子网（平台装 connected 路由），不依赖默认路由。劫持一旦失效，公共 DNS 是明文直连 + 真实 QNAME 外泄，sentinel 只会立刻失败。v6 DNS 不下发是因为本平台不装 v6 路由（下发即黑洞） |
| T-2 | `TunFlags.dnsOverride` 默认值 `true` → `false`，并新增门禁 `ext.dns-override-default-off` | catch 分支注释写的是「退回保守形态（IPv4-only + 不覆盖 DNS）」，但字段默认 true：读 YAML 失败时 TUN 会把系统 DNS 指到 sentinel，而内核没接管 ⇒ 整机解析黑洞 |
| D-2 | 文件头 IPv6 段落改为与 `buildTunRoutes` 真机取证一致（平台不装 v6 路由 ⇒ 双栈开启 ≠ v6 已接管，v6 仍走 wlan0） | 同一文件里两段注释互相矛盾（旧文写「双栈默认开后该通道被 TUN 接管」），是 I2「三处 v6 描述互斥」之一 |

### FlClash 对照（真机/源码取证，供后续 P0 整改用）

- TUN 构建：`VpnService.kt:179-229` —— v4 地址 + `addRoute("0.0.0.0", 0)`；`ipv6` 为真时才 `addAddress(fdfe:dcba:9876::1/126)` 并 `addRoute("::", 0)`，DNS 用 `198.18.0.2` / `fdfe:dcba:9876::2`（`:298-301`）。
- IPv6 默认值：`flutter_config.pretty.json:128,188,215` —— `vpnProps.ipv6=false`、`patchClashConfig.ipv6=false`、`dns.ipv6=false`，三层默认**全关**；TunBox 默认「开」但实际不生效（AAAA 恒空），这是文案与事实背离的根源。
- DNS：真机运行配置 `diag/device-flclash/flclash/runtime_config_dns_block.txt:8-60` —— `dns.enable: true`、`enhanced-mode: redir-host`（**不是 fake-ip**）、`fake-ip-range6: ""`、订阅的 `nameserver-policy` 原样透传、订阅没给 `proxy-server-nameserver` 时保持 `null`（主解析器才查 policy）。
- ⇒ FlClash 没有「DNS 覆写开关」：DNS 恒接管；`dnsHijacking` 只决定劫持目标是 sentinel 还是 `0.0.0.0`（`VpnService.kt:77-89`）。TunBox 把「应用劫持 / 内核解析 / 代理入口解析」捆在 `dns.enable` 一个开关上，是与 FlClash 最大的结构性差异。

### 复现门禁

- `node scripts/verify-generator-fingerprint.mjs`
- `node scripts/verify-vpn-architecture.mjs`（新增 `ext.tun-flags-*-tolerant`、`probe.ipv6-*`、`orch.dns-override-active-flag`）
- `node scripts/verify-logic-pure.mjs`

## 十二、2026-10-21 指纹变更说明（删除「DNS 覆写」开关 + v6 也走代理）

指纹：`5b482c987987d0db` → `17bcf4ec1a71c110` → `dc81cce4e9a28701`（本次）。

本次**导出 YAML 有实质变化**：`enhanced-mode` 为 `fake-ip`（v4 假池 `198.18.0.1/16`），
ipv6 开时额外下发 `fake-ip-range6: fdfe:dcba:9876::/64`；`dns.enable` 与 `tun.dns-hijack` 恒开。

### 产品决定

用户明确要求：**去掉设置页里那一大段 IPv6 解释，并且 v6 必须走代理（不能直连）**。

- 设置页 `SettingsPage` 的 IPv6 说明压缩成一句：「开启后 IPv6 与 IPv4 一样走代理（AAAA 返回隧道内地址，不直连）；关闭则纯 IPv4。」
  开关本身保留（唯一决策点 `ipv6Enabled`），没有第二个 fake 池高级项。
- 旧的「v6 直连物理网卡」文案与 redir-host 方案一并退场。

### 为什么是 fake-ip + range6（2026-10-21 真机复议）

| 配置 | 客户端拿到的 AAAA | v6 走向 |
|---|---|---|
| `redir-host` + `dns.ipv6: true`（上一版） | 上游真实地址 | **直连物理网卡**（设备 v6 完全绕过代理） |
| `fake-ip` 无 range6 | 空（`withFakeIP`：`fakePool6 == nil` 直接回空） | v6-only 站点不可用 |
| `fake-ip` + range6 **与 TUN 同段 /64**（本次） | 隧道内假 v6（`fdfe:dcba:9876::4` 起） | **进隧道 → 按域名交给代理拨号** |

关键取证（真机 192.168.10.5:39933，隧道在线）：

- 平台**丢弃** `VpnConfig.routes` 里的所有 v6 条目（`::/0` 三种写法、`fc00::/71` 实测全被静默丢弃）；
- 但平台**会按 `LinkAddress` 前缀派生 on-link 路由**：`TUN_PREFIX_V6 = 126` 时 `/proc/net/ipv6_route` 只有
  `fdfedcba987600000000000000000000 7e ... vpn-tun`；改成 `64` 后立刻出现
  `fdfedcba987600000000000000000000 40 ... vpn-tun`（`0x40` = /64）。
- 于是假 v6 池（`fake-ip-range6: fdfe:dcba:9876::/64`，gateway = `::1` = TUN 地址，首个假地址 `::4`）
  落在 on-link 网段内，`ping -6 fdfe:dcba:9876::4` 有回包，core.log 记 `[ICMP] ... using fake ping echo`。
- `config/config.go:parseIPV6` 只在 `!IPv6 || !verifyIP6()` 时清空 `FakeIPRange6`；本次 core.log 的
  `[TUN] ... ([198.18.0.1/30],[fdfe:dcba:9876::1/126])` 说明 v6 地址未被清空 ⇒ range6 生效。

### 连带行为变化

1. **DNS 假池回归**：`fake-ip-filter` 重新放行局域网 / STUN / NTP / 门户探活（这些必须拿真实地址）。
2. **DOMAIN 规则靠假 IP 映射**，`sniffer.force-dns-mapping` 保留作 SNI 不一致时的兜底。
3. **ipv6 关 ⇒ 不下发 range6** ⇒ `FakeIPPool6 == nil` ⇒ AAAA 恒空，与只装 v4 的 TUN 一致（不会留下无路由的假 v6）。
4. **v6-only 站点**：应用拿到假 AAAA → 进隧道 → 代理出口解析真实 v6 并连接。

### 复现门禁

- `node scripts/verify-generator-fingerprint.mjs`（17bcf4ec1a71c110）
- `node scripts/verify-vpn-architecture.mjs`（267 项；新增 `gen.dns.redir-host` / `ext.dns-always-sentinel` / `orch.no-dns-override-flag` 等反向断言）
- `node scripts/verify-config-generation-integrity.mjs`（70 项，含**真实内核** `mihomo -t` 接受新配置）
- `node scripts/verify-arkts-compile.mjs`（DevEco `assembleHap` 3/3）
## 十三、2026-10-21 指纹变更说明（测速并发 50 → 8 + 过载鉴别：修「测出一部分超时后就不测了」）

> 本节**不改配置指纹**（只动 App 侧测速引擎与闸门），单独记在这里是因为它推翻了
> `LATENCY_UNEFFECTIVE_FIX_2026-10-20.md` §8.3「8 → 50」的决定。

### 现象（用户报障）

飞鸟云（31 节点）「测全部」只测出**少数几个超时节点就不动了**，其余节点永远停在 `--`。

### 真机取证（192.168.10.5:39933，`com.tunbox.client`，hilog）

```
latency batch done nodes=31 measured=0 timeout=5 failed=0 ... notReady=6 unavailable=true
latency cleanup: 24 stranded stamped TIMEOUT
```

- 一次 `/delay` 都没成功：5 个节点得到内核回的真实 504（= 节点真的不通）；
- 紧接 6 次客户端侧 `code=2300028 Operation timeout`，被 `LatencyProbe.classify` 归为
  `core_not_ready`（没拿到 HTTP 响应 = 通道问题）→ 连续 6 次撞上
  `CORE_NOT_READY_ABORT_STREAK` → `invalidate()` **作废整批**；
- 剩余 24 个节点**一次请求都没发**，收尾还给它们补了「超时」章
  （`clearOwnTestingMarks` 的 coreUnavailable 兜底盖章）—— 于是用户看到
  「一批假超时 + 后面全是不动的 --」，与报障完全一致。

### 根因（两条，缺一不可）

1. **在途 50 路 = 主动制造栈内排队**。`LATENCY_INFLIGHT` 2026-10-20 被放开成 50，
   而 OHOS http 栈对**同一 host**（这里恒为 `127.0.0.1:9090`）只有约 8 条连接
   （2026-09-23 已实测）⇒ 其余请求在 **HTTP 栈内部**排队，排队时间被算进单请求预算
   ⇒ 到点抛客户端侧 `2300028`。这不是节点慢，是**我们**把 controller 打满了。
2. **过载被误判为通道死亡**。`classify` 只能看到「transport error」，分不清
   「controller 忙不过来」与「内核没了 / secret 被换掉」；旧实现一律 `streak++`，
   6 次就作废整批 —— 而这一步是**破坏性**的（剩余节点不再被测、还被补超时章）。

### 修复（`LatencyEngine.ets`，两条各自独立生效）

| # | 改动 | 为什么 |
|---|---|---|
| 1 | `LATENCY_INFLIGHT` 50 → **8** | 8 = OHOS 同 host 连接池容量 ⇒ 排队回到**应用层闸门**里发生，而闸门等待**不计入**单请求预算（C7 三条硬约束），读数仍是干净 RTT。历史基线同样支持：5.6.0 真机 59 节点 13.14s 跑通、`unavailable=false` |
| 2 | 新增 `controllerAnswers()` 过载鉴别 | 命中 `core_not_ready` 时先打一次廉价 `GET /version`（`ClashApiService.probeController`，800ms 预算、结论缓存 800ms）：能答 ⇒ **过载**，不计连击、不自愈、不中止，本节点保持「未测」（非判定）；连不上 ⇒ 才走原有的自愈 + 连击 + 作废路径 |

新增诊断计数 `LatencyProgress.coreOverloaded`：过载不再伪装成通道故障，但必须留痕
（`latency batch done ... notReady= overloaded= unavailable=`），否则「整批跑完却一堆未测」
在日志里仍然看不出原因。

### 真机验收（2026-10-21 15:13，设备 192.168.10.5:39933，MLR-AL00）

装法（复用既有配方，见 `docs/latency-ondevice-evidence.md` §0 与 `C:\Worker\TunBox\switch-signing.ps1`）：

```powershell
C:\Worker\TunBox\switch-signing.ps1 -Mode debug      # 切到本机 DevEco 托管调试证书
node hvigorw.js --mode module -p module=entry@default -p product=default -p buildMode=release assembleHap
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap   # install bundle successfully
```

飞鸟云（31 节点）「测全部」hilog 原文（**修后**）：

```
LatencyProbe: latency probe transport error node=美国01aws kind=core_not_ready verdict=false
              elapsed=4902ms inner=3000 outer=4200 error=code=2300028 Operation timeout
LatencyEngine: latency probe overloaded (controller alive): node=美国01aws http=0 elapsed=4902ms
              => 不计连击、不作废整批
LatencyEngine: latency cleanup: 3 node(s) left TESTING -> untested (cancelled=false
              userCancelled=false unavailable=false); stamped node verdicts kept
LatencyEngine: latency batch done nodes=31 channel=core measured=0 timeout=27 failed=1
              dnsUnresolved=0 queueTimeout=0 cancelled=0 skipped=0 notReady=0 overloaded=3
              unavailable=false elapsed=21196ms
```

| | 修前（本轮报障） | 修后（同一订阅、同一设备） |
|---|---|---|
| 批次收尾 | `notReady=6 unavailable=true`（整批作废） | `notReady=0 overloaded=3 unavailable=false`（跑完） |
| 未测节点 | 24 个**一次 `/delay` 都没发**，收尾还被补「超时」章 | 只有 3 个收尾保持「未测」，且**不补章**（`stamped node verdicts kept`） |
| 每一轮 | 测到第 7 个节点就停 | 31/31 全部拿到内核结论（`timeout=27 failed=1`），21.2s 走完 |

- `overloaded=3` 正是新计数：三次 `2300028` 都被 `controllerAnswers()` 判为**控制器过载**，
  于是不计连击、不作废整批 —— 这正是用户报障的那条路径，现在被截断了。
- 本批 `measured=0`：这 31 个节点在当前网络下**自身**全部拨号失败（内核直接回 504，
  `verdict=true`，属节点结论），与本缺陷无关；判定口径可以从 `timeout=27`（节点真慢/不通）
  与 `overloaded=3`（controller 忙）两个计数分开读出来 —— 这正是新增诊断计数的意义。
- ⚠ 验证完记得切回 `switch-signing.ps1 -Mode release`（`build-profile.json5` 的
  `signingConfigs` 必须保持为空，见 `scripts/verify-build-profile.mjs`）。

### 闸门同步（同一提交）

- `scripts/verify-latency-concurrency.mjs`：A1 常量（8 / 50 / 60s）、A2 `lanes=8`、
  A3 峰值在途 ≤ 8（40 节点 → 5 波 <3s）、A4 排队仍不计预算；**新增**
  A6「controller 仍能应答 ⇒ 过载不得作废整批、`finished==total`、不得补超时章」与
  A7「controller 不答 ⇒ 连击仍作废整批（`coreUnavailable`、`cancelled>0`、`finished<total`、
  不写 FAILED、不留 TESTING）」。
- `scripts/verify-latency-engine-runtime.mjs`：ClashApiService 桩显式提供
  `probeController`（默认不答 = 通道真的没了），原「作废整批 / 自愈」用例语义不变。
- `scripts/verify-latency-display.mjs`：在途并发断言改判 8。

### 复现门禁

- `node scripts/verify-latency-concurrency.mjs`（14）
- `node scripts/verify-latency-engine-runtime.mjs`（27）
- `node scripts/verify-latency-display.mjs`（41）

### 若日后仍要放开并发

前提是先把「栈内排队被算进超时」这条解决掉（自建连接池 / 换传输层 / 装**不同 host**
的独立 localhost 端口），否则放大在途数只会重新引入同一个缺陷。判定看四个计数：
`timeout=`（节点真慢）、`queueTimeout=`（应用层排队超限）、`overloaded=`（controller 忙）、
`unavailable=`（通道真的不可用）。

## 十四、2026-10-22 指纹变更说明（原文透传发射循环修正：修「节点被静默丢弃」）

`scripts/latency-gen-fingerprint.json` 的 `sha256_16` 由 `cdb37524fb1b89f8` 更新为
`6183fd516f78623c` —— 原因是**原文透传（2026-10-21 引入）的发射循环写错了结构**，
与测速引擎 / 延迟口径无关。

### 事故形态（真实内核抓到，不是推断）

原文透传把「按订阅建原文索引」和「逐节点发射」写成了**同一趟 for 循环**：

```ts
for (const n of staticNodes) {
  const subId = n.subscriptionId;
  if (subId.length === 0) { continue; }   // ← 手工节点在这里被整条吞掉
  ...建索引...
  lines.push(rawText ?? proxyYamlLine(n));
}
```

`subId` 为空的节点（手工导入 / 本地分组的节点）连发射都被跳过 ⇒ `proxies:` 后面空着
⇒ 内核报 `proxy group[0]: PROXY: '香港 01' not found` **整份拒载**。本机真实内核复现：

```
verify-smart-e2e → smart 配置被内核接受 ❌  (proxy group[0]: ♻️ 自动选择: '香港 01' not found)
```

### 修法

拆成两趟循环：**先**按订阅 ID 建原文索引（这一趟可以有 `continue`），**再**无条件遍历
`staticNodes` 发射（这一趟任何节点都不得被跳过）。行为不变：有原文且同名 → 发原文片段；
名字被去重改过 → `renameItem` 后再发；没有原文 → 退回 `proxyYamlLine()`。

### 新增/订正的门禁

| 脚本 | 断言 |
|---|---|
| `scripts/verify-config-generation-integrity.mjs` | **新增场景 16**：同一份配置里混入「有原文且同名 / 有原文但名字对不上 / 完全没有订阅归属」三种节点，三条都必须出现在 `proxies:` 段，且由**真实内核** `mihomo -t` 判定（123 passed） |
| `scripts/verify-proxy-name-uniqueness.mjs` | 唯一化入参断言改为 `staticNodes`（provider 覆盖的节点不再改名）；**新增**「发射循环 body 内不得有 continue」源码契约；订正「唯一化早于 `proxies:` 段」的断言方向（原断言要求晚于，与代码形态相反） |
| `scripts/verify-smart-e2e.mjs` | 补齐 stage（`RawProxyYaml` / `SubDnsUpstream`）；内核拒载时打印原始输出（原来只报 ❌，排查只能猜） |
| `scripts/verify-credential-isolation.mjs` | 补 `RawProxyYaml` 桩（`SubscriptionService` 新 import，缺桩会 `ERR_MODULE_NOT_FOUND`） |

### 同批订正的过期契约（不是放宽，而是改成当前口径）

- 单节点超时断言 3000 → **5000**（2026-10-21 用户拍板对齐三家）；
  `GROUP_TEST_TIMEOUT_MS` 与 `ClashApiService.testLatencyDetailed` 的默认值改为**转调**
  `LatencyPolicy.DEFAULT_TIMEOUT_MS`，不再留第二份字面量。
- 在途并发断言改为打**声明行**（`export const LATENCY_INFLIGHT = 32;`）。旧断言
  `LATENCY_INFLIGHT\s*=\s*8` 命中的是注释里的那行文字 —— 代码已是 32，闸门却照样绿。
- 组测速相关断言（`proxyTableNames` / `notInCore` / `latencyGroupDiagnosis`）随页面层
  组测实现一并退场，改锁「页面层无 `/group/` 端点、测速唯一入口是 LatencyEngine」。
- 过载 UI 出口从死页（`NodeSelectionPage`）迁到**真实入口**（订阅页闪电测速）：
  `BackgroundLatencyService.testSubscription()` 返回 `LatencyProgress`，过载数 > 0 时
  提示「N 个节点控制器过载未测，通道正常，可重测」。

## 十五、2026-10-22 指纹变更说明（原文透传循环修正 + provider 生成侧两处硬伤 + 大订阅阈值）

`sha256_16` 依次更新到 `06e3f8448db12d08`。三批改动，都是**生成侧/测速口径**，与延迟判定口径无关：

| 批次 | 改动 | 为什么 |
|---|---|---|
| 原文透传 | 「建原文索引」与「发射节点」拆成两趟循环 | 合并成一趟时 `subId` 为空的节点被 `continue` 吞掉 → `proxies:` 空 → 内核 `proxy not found` 整份拒载（真实内核 `-t` 抓到） |
| provider | `coveredNames` 过滤组内成员 + 补 `use:`；`planRawProviders` 新增「跨订阅重名 / 名字与原文不一致 → 回退内联」 | 订阅自带组按名引用已被 provider 覆盖的节点 ⇒ `proxy group[0]: ... not found` 整份拒载；名字不一致 ⇒ `/proxies/{name}/delay` 404 ⇒ 界面「未生效」 |
| provider 默认值 | 回退 false（`providerOffV6` 一次性迁移） | 设备上 provider 载不出节点（桌面同文件正常），未定论前不让所有用户踩 |
| 大订阅 | `deadlineForBatch` / `abortStreakFor` / `testGroupDetailedResult(expectedNodes)` / ≥120 节点走内核组测 | 547 节点真机 `measured=2 timeout=543` —— 四处算术/阈值把小批次的假设带进了大批次 |

## 十六、2026-10-23 指纹变更说明（去广告开关独立 + provider 段并集合并）

`sha256_16` 更新到 `cabba6616f9fad5d`。两批改动，都落在**配置生成侧**（规则表的第一条与
provider 声明段），与延迟判定口径无关：

| 批次 | 改动 | 为什么 |
|---|---|---|
| 去广告独立开关 | `generate()` 里 provider 声明与 `RULE-SET,hyper-adrules,REJECT` 的闸门由 `rulesEnabled && hyperAdRulesEnabled` 改为只判 `hyperAdRulesEnabled && ruleProviderReady` | 用户口径：去广告是独立开关，关掉「启用规则路由引擎」时它仍应生效；旧闸门会让去广告静默失效 |
| provider 段并集 | 与 `ProfileConfigMerger` 配套：overlay 的 `rule-providers` 不再被整段替换，改为按键并集（由合并器实现，生成器侧只是不再假设「声明一定存在」） | 修「开去广告后 VPN 起不来」：引用在、声明丢 → 内核 `rule set [hyper-adrules] not found` 整份拒载 |

回归：`verify-ad-rules-independence`（26 断言，含把闸门改回耦合的负对照）、
`verify-profile-merge-providers`（8 断言 + 负对照精确复现报障）、
`verify-config-generation-integrity`、`verify-vpn-architecture` 全绿；
真机（MLR-AL00）去广告开启 + 1.29MB MRS 在位实测「已连接」，公网 IP 正常。
