# 订阅解析：参数表与保真规则

> 落地代码：
> - `entry/src/main/ets/commons/subscription/ProtocolParamTable.ets`（参数表，唯一真源）
> - `entry/src/main/ets/commons/subscription/UriNodeParser.ets`（纯函数解析器）
> - `entry/src/main/ets/commons/subscription/RuntimeProfile.ets`（IR + 画像指纹）
> - `scripts/verify-sub-parse-fidelity.mjs`（保真闸门，含负对照）
> - `scripts/fixtures/subs/*.txt`（真实机场形态的样本，凭据全假）
>
> 闸门跑法：`node scripts/verify-sub-parse-fidelity.mjs` ／ 负对照 `node scripts/verify-sub-parse-fidelity.mjs --self-test`

> ## ⚠ 2026-10-22 口径变更（FlClash 同构）：YAML 订阅不再有「定义不完整」
>
> 真机实证：`ermaozi` 订阅里 `47.238.210.5:13779` 同时挂了两条不同节点
> （裸 vless `tls:false` + 同址 REALITY vless）。App 侧的 reality 旁挂表按
> `server|port` 记账 ⇒ 两条互相串台 ⇒ 那条**内核完全能用**的节点被判
> 「定义不完整：vless 缺少必填参数 reality-public-key」，整条踢出列表。
>
> 根因不是这一个地址，而是**架构上多了一份裁判**：订阅原文本来就整份进内核配置
> （`RuntimeConfigBuilder` → `ProfileConfigMerger`，`proxies` 段由原文接管），
> 内核自己解析、自己裁决；App 再给一份「定义完整/不完整」的结论 = 第二意见，
> 必然与内核分叉。FlClash 从不产生这种分叉：它**不解析**订阅的 `proxies`
> （`lib/models/core.dart` 的 `Proxy` 只有 name/type/now），节点列表来自内核
> `getProxiesGroups`（Go 侧 `tunnel.AllProxies()`），字段级判断一律交回内核
> `adapter.ParseProxy` 拿错误字符串。
>
> 因此从 2026-10-22 起：
> - **YAML 订阅路径**：`YamlNodeAdapter.plan()` 只做映射与对账，**不再判可用性**；
>   `mergedToNodes()` **全部保留**节点，不写「定义不完整」台账；
>   订阅卡片与展开区的「N 条定义不完整 / N 条信息条目已跳过」角标与说明**删除**。
> - **节点的可不可用只由内核决定**：`/proxies`（`CoreCatalogService`）里有没有、
>   配置载入是否成功；测速目标同样来自内核目录。
> - **单链接导入路径**（`UriNodeParser`）不受影响：那份链接只有 App 自己解析，
>   没有"内核另有一份原文"可对照，缺参仍按整条 ParseError 处理（且无 UI 判词）。
>
> 下文第 4bis / 4ter 两节保留为**历史口径**（描述单链接路径与旧 YAML 判词），
> 阅读时以本节的变更说明为准。
>
> 完整逐环节对照（含拉取层：UA / 超时 / gzip 解压 / Basic 鉴权 / `content-disposition`
> 命名 / 计数口径 / 单链接 / 校验）见 [`docs/flclash-subscription-parity.md`](flclash-subscription-parity.md)。

---

## 0. 为什么要重做（事故背景）

2026-10-20 真机报障：**mitce.io 的 34 个 VLESS·REALITY 节点测速全部秒失败**
（mihomo 503，5-10ms），同一次测速里别的订阅节点正常、隧道用同一个节点也能连通。

mihomo 的 503 语义是 URLTest 返回了 error（`hub/route/proxies.go:135-143`，
只有 `err != nil` 或 `delay == 0` 才给 "An error occurred in the delay test"）。
所以：

- 节点**进了内核代理表**（所以不是 404、不是订阅拉取失败）；
- 但 REALITY 握手参数（`public-key` / `short-id` / `servername`）不完整
  → 拨号立刻失败 → 整片判失败。

同型事故还有一次：「**36 个 anytls 因解析丢凭据被丢弃**」。

两次事故的根因是同一个：**参数在解析层被改名 / 丢弃 / 改写，而没有任何闸门能证明它没丢**。
解析器看起来"成功"了 —— 节点建出来了、名字有了、服务器地址有了 —— 只是**少了一个参数**，
而这个"少"要到真机拨号那一刻才暴露，暴露的形式是一整片节点全红。

⇒ 本次重做的目标只有一条：**逐字段保真，缺必填就整条不可用，绝不半条**。

---

## 1. 三个文件各管什么

| 文件 | 职责 | 明确不做什么 |
| --- | --- | --- |
| `ProtocolParamTable.ets` | 每个协议有哪些参数、参数叫什么、哪些必填、哪些敏感、最终写进 mihomo 的哪个字段 | 不解析任何 URI |
| `UriNodeParser.ets` | `parse(uri) → ParsedNode \| ParseError`，纯函数 | 不碰存储、不碰配置生成、不 import 任何 kit |
| `RuntimeProfile.ets` | IR（节点 / 组 / 规则 / provider 引用）+ `profileFingerprint()` | 不认识任何协议，不 import 解析器 |

三者都不 import `@kit.*`：纯逻辑 ⇒ ArkTS 侧能编译、Node 侧能直接跑（闸门就是这么跑的）。

### 1.1 接入导入链路后新增的模块（2026-10-20）

| 文件 | 职责 | 明确不做什么 |
| --- | --- | --- |
| `NodeUsability.ets` | 可用性判定 + **两类原因分类**（`incomplete` 定义不完整 / `dns` 域名无法解析） | 不发起 DNS 探测（结论由编排器回填） |
| `UnusableLedger.ets` | 旁挂台账：不可用节点 + 原因（UI 可见） | **不存原始 URI**（凭据泄漏红线） |
| `YamlNodeAdapter.ets` | YAML 路径 → 同一套规范键 + 判定计划（`plan` / `declaredItems`） | 不改 `YamlMerger`（合并器不在本次范围） |
| `ProxyNodeAdapter.ets` | 规范键 → 旧 ProxyNode 字段的**纯**映射 | 不 import `ProxyNode`（避免循环） |
| `BodyDispatch.ets` | 正文体裁判定（明文 / base64 → YAML 或 URI） | 不解析节点 |

`NodeUsability` / `UnusableLedger` / `ProxyNodeAdapter` / `BodyDispatch` **零 import**（不拖 kit）
⇒ Node 侧闸门只需多暂存它们，不必拖进 `@kit.*` 那一串依赖。

---

## 2. 参数表

### 2.1 表里每一项声明什么

| 字段 | 含义 |
| --- | --- |
| `key` | **规范键**。解析结果一律用规范键，URI 里的别名只用于定位 |
| `valueType` | `string` / `int` / `bool` / `port` / `list` / `enum` |
| `required` | **必填**。缺了 ⇒ 整条节点 unusable |
| `requiredWhen` | **条件必填**，形如 `security=reality` |
| `sensitive` | **敏感**（凭据类）。闸门逐字节对账，日志须脱敏 |
| `mihomoField` | **写进 mihomo 配置的哪个字段**（`reality-opts.public-key` 这种层级写法） |
| `aliases` | 同一个参数在分享链接里的不同写法 |
| `source` | `authority` / `fragment` / `query` / `body` |
| `transport` | 仅在某种传输下生效（`ws` / `grpc` / `http` / `h2` / `xhttp`），否则 `any` |

### 2.2 为什么要有 `transport` 这一维

分享链接里 `path=` / `host=` 是**通用写法**，落到 mihomo 的哪个字段取决于传输方式：

| 传输 | `path=` | `host=` |
| --- | --- | --- |
| ws | `ws-opts.path` | `ws-opts.headers.Host` |
| grpc | `grpc-opts.grpc-service-name` | — |
| h2 | `h2-opts.path` | `h2-opts.host` |
| http | `http-opts.path` | `http-opts.headers.Host` |
| xhttp | `xhttp-opts.path` | `xhttp-opts.host` |

靠正则猜协议形态就会写错字段 —— 写错字段 = 内核拿不到参数 = 拨号失败。
所以 `path` / `host` 的归属由 URI 里的 `type=` / `net=` 决定，表里用 `transport` 维度表达。

### 2.3 覆盖的协议

`vless` / `vmess` / `trojan` / `ss` / `ssr` / `hysteria2` / `tuic` / `anytls` / `snell` / `http` / `socks`（11 个）

外加三组横切参数：

- **REALITY**：`reality-public-key`（→ `reality-opts.public-key`）、
  `reality-short-id`（→ `reality-opts.short-id`）、`reality-spider-x`（mihomo 无对应字段，但要认出来）
- **uTLS**：`client-fingerprint`（→ `client-fingerprint`）—— 与证书指纹 `fingerprint`（→ `fingerprint`）是**两个独立的键**
- **传输层**：`ws-*` / `grpc-*` / `h2-*` / `http-*` / `xhttp-*`（见 2.2）

### 2.4 REALITY 的条件必填（本次事故的直接抓手）

```
security=reality  ⇒  reality-public-key 必填
```

`security=reality` 却没带 `pbk` 的链接，**整条标记不可用**并说明缺哪个参数。
不这么做的后果就是本次事故：节点建出来了 → 进内核代理表 → 拨号秒失败 → 整片测速红。

`reality-short-id` 在 mihomo 里允许为空，故**不**设为必填（但值必须原样保留）。

### 2.5 几个容易写错、值得单列的点

| 点 | 说明 |
| --- | --- |
| vmess 的 `type` | 是**伪装头类型**（none/http），**不是**传输方式；传输方式是 `net`。早前把 `type` 认成 `network` 会把 tcp 节点写成 http |
| hysteria2 的 `sni` | mihomo 的 hysteria2 用 `sni` 键，**不接受** `servername`；vless/trojan/vmess 用 `servername` |
| hysteria2 的端口跳跃 | authority 的端口段可能是 `20000-30000`。原始段**原样保留**在 `params['port']`，`port`（数值）取首端口。历史上 `parseInt` 截断属于"参数被改写" |
| snell 的 userinfo | 是 **psk**，不是 password。写成 password 会把整条节点判成缺必填 |
| TUIC v4 vs v5 | v5 `uuid:口令@`，v4（token）`口令@`。userinfo 里有 `:` 才拆两段，否则整段是口令 |
| SSR 的 base64 | SSR 载荷里的 `remarks` / `obfsparam` / `protoparam` 规范上是 base64；也有面板直接塞百分号编码文本。两种都认，不丢 |
| `encryption=none` | VLESS 链接恒带，mihomo 的 vless **无此字段**。认出来、不写、但不丢 |

---

## 3. 保真规则

### 规则 1：参数名只有一个真源

URI 里的 `pbk` / `sid` / `fp` / `scy` / `serviceName` … 只是**别名**，用于在表里定位；
解析结果一律用**规范键**。

### 规则 2：表里没声明的参数**不丢弃**

进 `unknownParams`，让上层可见。
静默丢弃正是"参数被改名"事故的温床 —— 看不见就没人修。
（表里也把 `encryption` / `headerType` / `spx` / `mode` / `authority` 这些"mihomo 用不到但机场会给"的
键显式声明成 `mihomoField: （mihomo 无对应字段）`，这样常见链接不会有 unknown。）

### 规则 3：值只做一次百分号解码，其余原样

不 trim、不改大小写、不截断、不补默认值、不"清洗"。
敏感值（凭据）由闸门用 **sha256 前 8 位**与原文摘要对账，证明一字未改。

### 规则 4：空值等于"没给"

`?flow=` 这种空值不落键。键集因此是诚实的，缺必填也判得准。

### 规则 5：缺必填 ⇒ **整条 ParseError**，绝不半条

见下一节。

---

## 4. 缺参数的处理：整条不可用 + 原因

### 4.1 行为

解析器在返回节点**之前**先按表（含条件必填）过一遍必填：

- 缺 ⇒ 返回 `ParseError`，`missing` 列出缺哪些**规范键**，`reason` 给人话说明；
- **不返回半条节点**（没有 `ParsedNode`、没有"凑合的" params）；
- 空值同样算缺。

示例：

```
vless://@host:443?security=reality&pbk=xxx…
  → ParseError{ missing: ['uuid'], reason: '缺少必填参数（uuid）—— 整条节点不可用，绝不半条' }

vless://uuid@host:443?security=reality&sid=a1b2c3d4…
  → ParseError{ missing: ['reality-public-key'], reason: '同上' }
```

### 4.2 为什么不能"半条"

| 做法 | 后果 |
| --- | --- |
| 缺参数就丢一半继续 | 节点建出来 → 进内核代理表 → 握手参数不全 → **拨号秒失败** → 整片测速红（本次 34 个节点全灭） |
| 缺参数就整条不可用 | 节点不进代理表（或进表时带明确标记），**测速只反映真实可用性**，日志/UI 能说清"缺 REALITY 公钥" |

节点"存在但握手失败"是 mihomo 返回 503 的主因；**半条节点 = 批量制造 503**。

### 4.3 缺必填的清单（当前）

| 协议 | 必填 |
| --- | --- |
| vless | server / port / uuid（+ `security=reality` ⇒ reality-public-key） |
| vmess | server / port / uuid |
| trojan | server / port / password |
| ss | server / port / cipher / password |
| ssr | server / port / protocol / cipher / obfs / password |
| hysteria2 | server / port / password |
| tuic | server / port / password（uuid 是 v5 才有的，可选） |
| anytls | server / port / password |
| snell | server / port / psk |
| http / socks | server / port（username / password 可选） |

> `reality-short-id` **不是**必填（mihomo 允许空）—— 别把它当必填，否则正常节点会被误杀。

---

## 4bis. 不可用（unusable）的口径：两类原因，严格分开

> 2026-10-20 接入导入链路时定稿。本节是**用户可见口径**的唯一真源。

### 4bis.1 两类"节点不可用"不是一回事

| 类别 | `UnusableCategory` | 含义 | 是谁的问题 | 节点还进不进代理表/测速集合 |
| --- | --- | --- | --- | --- |
| **定义不完整** | `incomplete` | 解析层丢了参数（缺 uuid / 缺 REALITY 公钥 / 缺 password…） | **我们**（解析层 bug） | **不进**（半条节点 = 批量 503） |
| **域名无法解析** | `dns` | 定义完全正确，但服务器域名在公网 DNS 上查不到 | **机场 / 线路** | **进**（定义是对的，只是这次没解析出来） |
| **订阅信息条目** | `info` | 压根不是节点：机场把「剩余流量 / 到期时间 / 群链接」写成了节点 | **机场的订阅内容** | **不进**（不是节点，见 [4ter](#4ter-订阅信息条目不是节点)） |

真机 2026-10-20 的 mitce 34 节点事件是**第二类**：
`de152710bb8b70d108ec13c7.mitce-nocontact.com` 在阿里/腾讯/Cloudflare/Google 四个解析器上全部 NXDOMAIN，
而节点参数（uuid / flow / client-fingerprint / reality-opts.public-key / short-id / tls / servername）**全部正确**。
这种节点进内核代理表只会批量制造 mihomo 503（"An error occurred in the delay test"），
让人误以为是"TunBox 解析坏了"。

⇒ **DNS 结论绝不能反过来越权**：它只是运行层结论，不许把定义正确的节点踢出代理表。

### 4bis.2 unusable 的定义（唯一）

> **unusable = 定义不完整**（`category === 'incomplete'`）。
>
> - **不进**内核代理表；
> - **不进**测速集合；
> - **UI 可见并带原因**（旁挂台账 + 导入诊断 `invalidReasons`）；
> - **不伪装成"节点失败/网络不可达"** —— 这是参数问题，是我们的锅。

判定实现：`NodeUsability.assess(protocol, params, server, name)`（按参数表 + 条件必填 + 名字内容判信息条目）。
`NodeAvailability.usable()` ⇒ `category === 'ok' || category === 'dns'` ⇒ **DNS 结论不影响入表**，但 `info` 不入表（它不是节点）。

### 4bis.3 节点模型放不下怎么办 ⇒ 旁挂台账

导入链路的节点表放不下"不可用节点"（内核代理表只收能用的），
所以不可用节点进**旁挂台账** `UnusableLedger`（进程内静态，导入期写、读取后即清）：

```ts
export class UnusableRecord {
  subscriptionId: string; source: string;   // 'uri' | 'yaml'
  protocol: string; name: string; server: string; port: number;
  category: string;                          // 'incomplete' | 'dns'
  excluded: boolean;                         // true = 不进代理表/不进测速集合
  reason: string;                            // 一句话原因（UI 直接展示）
  detail: string;                            // 补充说明（UI 直接展示）
  missing: string[];                         // 缺哪些规范键
  dnsState: string;
}
```

取值 API（`SubscriptionService` 静态方法）：

| API | 用途 |
| --- | --- |
| `SubscriptionService.unusableDefinitions(): UnusableRecord[]` | 只取"定义不完整"的条目（UI 列"定义不完整 N 条"） |
| `SubscriptionService.unusableSummary(): string` | 一行摘要（诊断面板用） |
| `UnusableLedger.excludedList()` | 被排除的（定义不完整） |
| `UnusableLedger.dnsList()` | DNS 类的（**与上一条严格分开**） |
| `UnusableLedger.listFor(subscriptionId)` | 某个订阅的全部记录 |

台账**不存原始 URI**（凭据泄漏红线）：只存 protocol / name / server / port / 原因。

### 4bis.4 两条导入路径的口径必须一致

| 路径 | 入口 | 判定 |
| --- | --- | --- |
| 分享链接（URI） | `UriNodeParser.parse()` → `ParsedNode` / `ParseError` | 缺必填 ⇒ `ParseError`（`missing` + 人话原因）⇒ 调用方 `continue` ⇒ 不进节点表 |
| Clash YAML | `YamlMerger.merge()` → `YamlNodeAdapter.plan()` | 缺必填 ⇒ `excluded = true` ⇒ 不进节点表 |

两条路径**同一张参数表、同一套必填规则、同一句原因文案**（`NodeUsability`）——
闸门里有一条断言专门盯这件事（改 YAML 路径的判定 ⇒ 闸门必须变红）。

### 4bis.5 YAML 路径的"原文有、合并没产出"

`YamlMerger` 自己有一道凭据闸：**缺 uuid / password 的条目根本不会产出 `MergedProxy`**。
只看合并结果，这些节点就"人间蒸发"（既不进代理表，也没有任何原因可查 —— 用户只看到"节点少了几个"）。

⇒ `YamlNodeAdapter.declaredItems(body)` 从原文把声明过的条目捞出来，与合并结果**对账**，
差集记成 unusable（原因：`定义不完整：… 在合并阶段未产出节点（凭据/地址不完整）`）。

### 4bis.6 DNS 结论从哪来（不许造第二份 DNS 探测）

系统里**没有** `getHostByName` 这类系统 API；DNS 结论只有一个来源：
编排器的 `hostSnapshot(): LatencyHostSnapshot`（`pins` + `attempted`）。
⇒ `NodeUsability.withDns(availability, dnsState)` 只负责**回填 + 改文案**，
不自己发起探测；**不新建 `DnsPrecheck.ets`**（避免第二份真相）。

---

## 4ter. 订阅信息条目（不是节点）

> 2026-10-20 真机事件（飞鸟云那批 35 个节点）新增的第三类。

机场把**订阅信息**当成一个普通 YAML 节点写进来（server / port / 密码齐全）：

| 原文 | 判据命中 |
| --- | --- |
| `剩余流量：596.22 GB` | 关键词「剩余 / 流量」 |
| `套餐到期：长期有效 (2)` | 关键词「套餐 / 到期」 |
| `有超过20多个节点，不够请到官网使用文档…` | 关键词「官网 / 使用文档」 |
| `每次使用前更新订阅到最新…` | 关键词「更新订阅」 |
| `电报群https://t.me/feiniaoyunjichang` | **名字里带 http(s) URL** |
| `防失联页https://github.com/feiniaoyun` | **名字里带 http(s) URL** |

⇒ 这类条目**参数齐全**，`incomplete` 检测**抓不到**（实测有 2 条在真机上显示成「网络不可达」）。
只能按**名字内容**判：`NodeUsability.isInfoEntry(name)`。

### 口径

- 判为 `category === 'info'`，原因写 **`订阅信息条目，非节点：<名字>`**；
- **不进**内核代理表、**不进**测速集合；
- **在 `UnusableLedger` 里留一条账**（用户能看到"这个订阅里有 N 条信息被跳过"，不许静默消失）；
- **不是 DNS 类**（`dns` = 节点定义正确、只是这次域名没解析出来）—— 两者原因必须分开说；
- 原因文案**不许**出现「网络 / 不可达 / 超时 / 失败」（它既没失败，也不是网络问题）。

### 判据为什么保守

- 硬判据是**名字里带 http(s) URL** —— 机场信息条最稳定的特征，零误杀；
- 关键词表是**补充**（给没有 URL 的那几条），刻意保守：
  `剩余流量 / 剩余 / 流量 / 套餐 / 到期 / 过期 / 官网 / 使用文档 / 电报 / 防失联 / 公告 / 更新订阅 / 客户端版本太老 / 版本太老 / 请到文档下载 / 无法正常使用 / 下载新版`；
  （后 5 条 2026-10-20 补：按 UA 裁剪的面板会塞「客户端版本太老」假 ss 广告条，其中 3 条名字不带 URL，旧表拦不住）
- **没有单字「群」** —— 节点名带「群」太常见（群组 / 专线群），误杀真节点的代价远大于放过一条信息条目
  （信息条目还有 URL 判据兜底）；
- 「香港 01」「IEPL 专线」这类正常名不会命中（闸门里有一条真节点 `Y-HK-01` 盯着不许误杀）。

两条导入路径（YAML / 分享链接）同一套判据：YAML 路径在 `YamlNodeAdapter.canonical` 里把
`merged.name` 交给 `assess()`；分享链接路径在 `UriNodeParser.finish()` 里判。

---

## 5. RuntimeProfile：IR 与画像指纹

### 5.1 IR 组成

- `ProfileNode`：**节点**（id / 名称 / 协议 / 地址 / 端口 / **usable** / **unusableReason** / 逐字段 params）
- `ProfileGroup`：**组**（select / url-test / fallback / load-balance / relay + 成员）
- `ProfileRule`：**规则**（type + payload + target）
- `ProfileProviderRef`：**provider 引用**（rule-provider / proxy-provider + behavior / url / path）

它回答三个以前回答不了的问题：

1. 「这份配置比上次变了什么？」→ `profileFingerprint()`；
2. 「这个节点为什么不可用？」→ `ProfileNode.unusableReason`；
3. 「RULE-SET 引用的 provider 声明了吗？」→ `providerRefs` 对账。

### 5.2 指纹口径

`profileFingerprint(profile)` = `profileCanonicalText(profile)` 的 **SHA-256**（64 位十六进制）。

规范化文本按 `节点(按 id 排序) / 组(按名排序) / 规则(按内容排序) / provider(按名排序)` 逐行展开，
节点内参数按键排序 ⇒ **顺序无关、内容敏感**。

SHA-256 是**文件内自带的纯实现**（不 import 任何 kit）。闸门用 `node:crypto` 对同一份规范化文本
独立算一遍，两边不一致就红 —— 自带实现写错了不会被静默放过。

---

## 6. 闸门：证明"没丢"，而不是声称"没丢"

`scripts/verify-sub-parse-fidelity.mjs` 对 `scripts/fixtures/subs/` 下每一条 URI 断言：

| 组 | 断言 |
| --- | --- |
| **A 键集合** | 解析出的规范键集合 **==** 参数表声明并由该 URI 供给的键集合（多了是凭空造字段，少了是丢参数） |
| **B 值保真** | 每个键的值与「URI 原文**独立解码**出的值」**sha256 前 8 位**一致（敏感值即凭据，同样逐字节对账） |
| **C 必填完整** | 按独立手写的必填清单（含条件必填）算出缺哪些键；缺了就必须**整条 ParseError**，且 `missing` 与独立计算一致 |
| **D 不丢未知参数** | 表里没声明的 URI 参数必须出现在 `unknownParams`，值也不得被改写 |
| **E 结构字段** | server / 端口段（含跳跃区间）/ 显示名与原文一致 |
| **F 指纹** | `profileFingerprint()` == 规范化文本的 `node:crypto` SHA-256；且对顺序不敏感、对内容敏感 |
| **G YAML 路径保真** | 同一张表产出的规范键视图 == 闸门里**手写**的期望（键集合 + 每个值）；合并后的结构化槽位逐字相符；无"原文有但表没声明"的残留字段 |
| **H 缺必填 ⇒ 整条不可用** | 分类 = `incomplete`、原因含"定义不完整"、缺失键正确、**原因不含"不可达/网络/超时/失败"**；坏节点不在可入集合里；台账条目带原因与"不进代理表"说明；DNS 结论严格分开（`dns` 类别 ⇒ 仍可用、不进不可用台账） |
| **I base64 分派** | base64 包着的 Clash YAML ⇒ 判为 YAML 分支且已解码、解码后仍是 N 个 proxies 条目；**旧口径（只探明文）确实认不出来**（证明缺陷真实存在过）；明文 YAML ⇒ YAML 分支；链接列表 ⇒ URI 分支 |
| **J vless 的 sni** | 参数表里 vless 有 `sni` 声明且落在 mihomo 的 `servername` 键（REALITY 的 servername 不许丢） |

补充自检：参数表别名不打架；**参数表的 `required` 与闸门里独立手写的清单一致**
（表写错了闸门也要能发现，否则解析器与表同错同过）。

### 6.1 负对照（闸门必须真的会红）

`node scripts/verify-sub-parse-fidelity.mjs --self-test` 做三件事：

1. **改坏样本**：删掉一条样本的 UUID → 闸门必须报 FAILED（"缺必填"路径）；
2. **改坏解析器**（这才是真事故的形态 —— 样本没变，解析器少给了一个参数）：

| 注入的缺陷 | 闸门的判决 |
| --- | --- |
| 解析器丢掉 REALITY 公钥（`pbk` 不落 params） | 被抓住（键集合不符 + 缺必填） |
| 解析器把参数改名（`reality-public-key` → `reality-pbk`） | 被抓住 |
| 解析器截断参数值（只留前 8 个字符） | 被抓住（sha256 摘要不符） |

3. **改坏 YAML 路径 / 不可用口径 / base64 分派**（本次接入链路的要害）：

| 注入的缺陷 | 闸门的判决 |
| --- | --- |
| YAML 路径不再判"定义不完整"（坏节点照旧进代理表） | 被抓住（G/H 组） |
| 不可用口径把"DNS 结论"也算成不可用 | 被抓住（H 组：DNS 节点被踢出代理表） |
| base64 分派退回旧口径（base64 YAML 掉进 URI 分支） | 被抓住（I 组） |
| 参数表删掉 vless 的 `sni` 声明 | 被抓住（G/J 组：REALITY 的 servername 丢） |

七种改坏都被抓住 ⇒ 闸门确实能证明保真与口径；抓不住就等于没闸门。

### 6.2 样本

`scripts/fixtures/subs/` 下的样本**照抄真实机场分享链接的形态**（含 `encryption=none` / `pbk` / `sid` /
`spx` / `fp` / `flow` / `mode` / `authority` / 百分号编码的中文名 / vmess 的 base64(JSON) /
SSR 的 base64 载荷 / SIP002 与旧形态两种 ss / `hy2://` 别名 scheme / 端口跳跃区间），
但**凭据全是假的**：域名一律 `example.test`，UUID / 公钥 / short-id / 口令都是占位串。
仓库里**没有任何一条来自真实机场的真实凭据**。

负例单独放在 `negative-missing-required.txt`，`## negative` 之后的行按负例处理
（必须返回 ParseError，且不得出现半条节点）。

YAML 样本在 `scripts/fixtures/subs/yaml/`（子目录 ⇒ 顶层 .txt 链接读取器看不见）：

| 样本 | 内容 |
| --- | --- |
| `clash-valid.yaml` | 5 个完整节点（vless+REALITY+ws / vmess+ws / trojan / ss / hysteria2）⇒ G 组保真正例 |
| `clash-missing-required.yaml` | 4 个不完整节点（vless 缺 uuid / trojan 缺 password / hysteria2 缺 password / **vless 的 reality-opts 只有 short-id 没有 public-key**）⇒ H 组"整条不可用"正例 |

---

## 7. 与旧解析器（`ProxyNode.ets` 的 `ModernUriCodec`）的关系

- `ProxyNode.ets` 是**存储与 UI 侧**的既有模型，本模块**不替换**它；
- 本模块是**新解析层**：参数表 + 纯函数解析器 + IR，
  由它产出的字段再灌进既有模型。**2026-10-20 起已接进 `SubscriptionService` 的导入链路**（见 §9）。
- 本次**不改动** `ClashConfigGenerator.ets`（有指纹闸门）与 `ConnectionOrchestrator.ets`。
- 迁移时应注意：旧解析器把部分参数**塞进 `rawTemplate`**（`extra` 之类的键），
  新解析层产出的是**规范键 + 明确的 mihomo 字段映射**，接进配置生成器时以新层为准。
- 旧 `ModernUriCodec.parse*` / `SsrCodec.parse*` 已于 **2026-10-20（B6 旧解析器退场）整体删除**：
  `ProxyNode.ets` 从 1256 行缩到 376 行，只剩 `ProxyNode`（模型 + `fromUri` → `parseUriNode` → `fromCanonical`）
  与 `Base64Codec`（**纯 base64url 工具**：`b64` / `decoder` / `decodeBase64Url`）。

  **2026-10-20 lead 拍板改名 `SsrCodec` → `Base64Codec`**：旧名名不副实 —— 它早已不含
  任何 SSR 编解码逻辑，只剩 base64 工具，名字却让人以为还有 SSR 解析残留。
  调用方共 3 处（`SubscriptionParser` / `SubscriptionService` / `compare_forms.mjs`），
  已同步改完；3 个 credential 闸门的 `ProxyNode.ts` 桩也一并改名。
  删旧解析器时**没有丢协议**：`hysteria v1`（`hysteria://`）在同一天并入了规范层
  （`ProtocolParamTable` 的 `hysteria` 项 + `ProxyNodeAdapter.supportsUdp`），
  并在 `scripts/fixtures/subs/hysteria1.txt` 留了样本盯着。
- `ProxyNode.fromUri(` 的调用方**只剩手动单条导入**（`pages/NodeEditPage.ets`）；
  订阅导入/刷新路径（`SubscriptionParser.addFromUri`、`SubscriptionService` 的凭据回退与直链导入）
  全部改走 `UriNodeParser.parse()` + `ProxyNode.fromCanonical()`。

### 7.1 规范键 → 旧字段的映射（`ProxyNodeAdapter`）

`ProxyNodeAdapter` 是**纯映射**（不 import `ProxyNode`）：

| 规范键 | 旧 ProxyNode 字段 | 规范键 | 旧 ProxyNode 字段 |
| --- | --- | --- | --- |
| `uuid` | `uuid` | `sni` / `servername` | `servername` |
| `password` | `password` | `skip-cert-verify` | `skipCertVerify` |
| `cipher` | `method` | `flow` | `flow` |
| `protocol` | `protocol` | `client-fingerprint` | `clientFingerprint` |
| `protocol-param` | `protocolParam` | `fingerprint` | `certFingerprint` |
| `obfs` | `obfs` | `reality-public-key` | `realityPublicKey` |
| `obfs-param` / `obfs-password` | `obfsParam` | `reality-short-id` | `realityShortId` |
| `alter-id` | `alterId` | `ws-path` | `wsPath` |
| `network` | `network` | `ws-host` | `wsHost` |
| `tls` | `tls`（布尔） | `grpc-service-name` | `grpcServiceName` |
| `alpn` | `alpnList` | `up` / `down` | `hyUp` / `hyDown` |

- **回写**（把规范键写进旧模型）留在 `ProxyNode` 类里：`ProxyNode.applyCanonical()` / `assignField()`。
  这样 `ProxyNode.ets ⇄ ProxyNodeAdapter.ets` 的**循环 import 被消掉**（适配器不再 import ProxyNode）。
- `security`（tls / reality / none）**不是** mihomo 的原样值（mihomo 的 `tls` 是布尔）：
  单独走 `ProxyNodeAdapter.securityToTls(params)` ⇒ `tls: true|false`。
  早先若直接回写会生成 `tls: reality` 这种非法值 ⇒ 内核整份配置拒载。
- `name` / `server` / `port` 是**结构字段**（生成端自己写）⇒ **绝不进 `extraOpts`**：
  重复键会让 mihomo 的 YAML 报 `mapping key "x" already defined` ⇒ 整份配置拒载。

---

## 8. 遗留 / 下一步

1. **别名补全**：表里的别名目前覆盖常见面板写法；遇到新写法先补表（表是唯一真源），
   **不要**在解析器里加特例。
2. **mihomo 字段落地**：`mihomoField` 只声明映射，**实际写进 YAML 的一步**由配置生成器负责
   （本次未动 `ClashConfigGenerator.ets`）。
3. **条件必填扩展**：目前只有 `security=reality ⇒ reality-public-key` 一条；
   若后续接了别的协议（如某些面板的 `tls+reality` 变体），按同样方式在表里加 `requiredWhen`。
4. **UI 接线**：`unusableDefinitions()` / `unusableSummary()` 已有取值 API，
   但**页面还没消费**（`pages/**` 是 settings-ui 的在途文件，本次没动）——
   UI 必须把"定义不完整"与"域名无法解析"分开呈现，不许都写成"失败"。

---

## 9. 导入链路接入（2026-10-20）

### 9.1 改了哪些文件

| 文件 | 改动 |
| --- | --- |
| `commons/subscription/NodeUsability.ets` | **新增**：可用性判定 + 两类原因分类（`incomplete` / `dns`） |
| `commons/subscription/UnusableLedger.ets` | **新增**：旁挂台账（不存原始 URI） |
| `commons/subscription/YamlNodeAdapter.ets` | **新增**：YAML 路径 → 规范键视图 + 判定计划（`plan` / `declaredItems`） |
| `commons/subscription/ProxyNodeAdapter.ets` | **新增**：规范键 → 旧字段的**纯**映射（无 ProxyNode import ⇒ 无循环） |
| `commons/subscription/BodyDispatch.ets` | **新增**：正文体裁判定（明文 / base64 → YAML 或 URI） |
| `commons/models/ProxyNode.ets` | `fromUri` 改走规范解析层；`applyCanonical` / `assignField` 落进类内；`ModernUriCodec.finish` 改 public |
| `commons/services/SubscriptionService.ets` | 三处分派点改用 `BodyDispatch`；YAML 路径用 `YamlNodeAdapter.plan` 判定；不可用节点记台账；本地 YAML 导入也走同一分派 |
| `scripts/verify-sub-parse-fidelity.mjs` | 暂存新模块 + 新增 G/H/I/J 四组断言 + 4 条新负对照 |
| `scripts/verify-mihomo-alignment.mjs` | 暂存 5 个订阅模块（否则 import 解析不到直接挂） |
| `scripts/verify-credential-isolation.mjs` | 补 `../subscription/*` 的暂存重写 + 四个新模块的垫片 |

### 9.2 base64 包着的 Clash YAML（真实缺陷，已修）

**旧口径**：一级分派只看**明文**正文里有没有 `proxies:` ⇒
一份 **base64 包裹的 Clash YAML** 认不出来 ⇒ 掉进 **URI 分支** ⇒
`SubscriptionParser.parseDetailed` 把它当链接列表逐行解 ⇒ **每行都判 invalid**（节点全军覆没）。

**新口径**（`BodyDispatch.classify`）：

1. 明文里有 `proxies:` ⇒ YAML 分支；
2. 否则若像 base64 ⇒ 解码 ⇒ **再判一次**是不是 YAML 文档 ⇒ 是则 YAML 分支（`body` = 解码后的正文）；
3. 否则 ⇒ URI 分支（base64 的链接列表仍走原路）。

闸门 I 组里有两条断言盯着它：一条证新口径判对，一条证**旧口径确实认不出来**（缺陷真实存在过）。

### 9.3 vless 的 `sni` 丢失（真实缺陷，已修）

参数表里 **vless 没有 `sni` 声明** ⇒ 链接里的 `sni=` 落进 `unknownParams`（不丢，但没规范键）
⇒ **REALITY 的 `servername` 丢了** ⇒ 节点变成"有公钥没 servername"的半条节点。
已补声明（`mihomoField = 'servername'`），闸门 J 组盯着。

### 9.4 端口跳跃与早数据（mihomo 对齐）

- hysteria2 的 `host:1000-2000` ⇒ `port` 取**首个**端口、原始区间落 `ports` 键
  （对齐 mihomo `common/convert/v.go`；`verify-mihomo-alignment.mjs` 有对拍）。
- `ed`（早数据长度）：`ws` ⇒ `ws-opts.max-early-data` + 缺省 `ws-opts.early-data-header-name: Sec-WebSocket-Protocol`；
  `httpupgrade` ⇒ `ws-opts.v2ray-http-upgrade-fast-open: true`（`ed` 只表示"有早数据"，数值不落地）。
  **非数字的 `ed` 一律不落地**（坏值会让 mihomo 整份配置拒载）。
