# 审计底稿：订阅域 FlClash 全量照抄四项待办（2026-11-05，供复查 Agent 使用）

> 写给复查 Agent。目标：**逐条可机械复核**。每一条都给出：做了什么 / 在哪个文件哪一行 /
> FlClash 依据（哪个文件哪个语义）/ 判定理由 / 复核方法。
> 三类要重点盯的：**我做的自由裁量（judgment calls）**、**我删的门禁断言**、**我没有做/被阻塞的**。
>
> 本轮会话前的工作树包含上一轮（取回层，2026-11-04）的未提交改动约 118 路径；本轮只碰
> 下文明确列出的文件。改前基线快照：`C:\Worker\_snapshots\TunBox-pre-fullport-20261104-214946.zip`
> （本轮开始时的完整工作树）。复核「本轮改了什么」的最硬手段：把本轮会话产生的新文件/改动
> 与该快照 diff。

---

## 0. 本轮会话的改动清单（精确范围）

### 0.1 内核（Go，已重建，产物已入 HAP）
| 文件 | 改动 | 复核方法 |
|---|---|---|
| `mihomo-build/mihomo-smart-462455136157a760937c666bba71afe33b1a809e/cshared_main.go` | 新增 `TunBoxGetProfileBase(path)`：`os.ReadFile` → `config.UnmarshalRawConfig` → `json.Marshal` → map（`rule`→`rules` 改名）→ 附 sha256 digest / proxies / proxyGroups / rules / matchRules（首段为 MATCH 的规则，`strings.Cut(rule, ",")` + `EqualFold`，照抄 FlClash upstream main `core/profile_base.go isMatchRule`）；新增 `TunBoxDecodeYaml(text)`：`common/yaml.Unmarshal`（= go.yaml.in/yaml/v3 原样）→ JSON map | `grep TunBoxGetProfileBase cshared_main.go`；对照 FlClash `core/hub.go handleGetConfig`、`core/profile_base.go handleGetProfileBase`；`strings/grep -c TunBoxGetProfileBase entry/libs/arm64-v8a/libgojni.so`（应为 4） |
| `.../config/profile_prepare.go` | 删除合成组注入块（`document["proxy-groups"] = 手动选择/自动选择` + `MATCH,手动选择`）；保留锚点展开 + UnmarshalRawConfig + parseProxies/parseRuleProviders/checkRules | git diff 该文件；对照 FlClash（无任何合成组逻辑） |

注意：`config/profile_prepare_test.go` 的改动**不是本轮**做的（上一轮遗留的未提交改动）。

### 0.2 NAPI / 桥
| 文件 | 改动 |
|---|---|
| `entry/src/main/cpp/tunbox_core_napi.cpp` | `ProfileWork` 增加 `symbol` 字段泛化成「字符串入/JSON 出」worker；新增 `GetProfileBase`/`DecodeYaml` 两个 napi 函数（dlsym `TunBoxGetProfileBase`/`TunBoxDecodeYaml`）；模块注册表加 `getProfileBase`/`decodeYaml` |
| `entry/src/main/cpp/types/libtunbox_core_napi/index.d.ts` | 两个新导出的声明 |
| `entry/src/main/ets/core/CoreBridge.ets` | `NativeCoreModule` 接口 + `getProfileBase()`（返回 `CoreProfileBase`：config/digest/proxies/proxyGroups/rules/matchRules）+ `decodeYaml()`（返回 `Record<string,Object>`）；错误从 reply.error 抛出 |

### 0.3 ArkTS 生产代码（任务1/2/3/4 的主战场）
| 文件 | 改动摘要 | 详见 |
|---|---|---|
| `commons/tunbox/TunBoxProfileBuilder.ets`（**新文件**） | map 级构建器：`build`（异步壳：getProfileBase + decodeYaml）+ `compose`（纯函数 patch 链 + JSON dump）+ `md5Hex`（纯 ArkTS MD5）+ `TunBoxBaseData/TunBoxProfileInput/TunBoxProfileResult/TunBoxGroupInfo` | §2 |
| `commons/config/RuntimeConfigBuilder.ets` | profile 分支改调 builder；`RuntimeConfigProfile.profileId` 新字段；`resolvePinTargetFromProfile`（map 级钉选）；`resolvePinTarget` 删自愈；providerIntent 放宽 | §2.2/§3.3 |
| `commons/tunbox/ProfileRepository.ets` | `validateAndStore` 重写：temp 文件 → `coreBridge.getProfileBase` 校验 → **原文**落盘（nodeCount = base.proxies）；新增 coreBridge import | §2.3 |
| `commons/tunbox/ProfileConfigMerger.ets` | 1002→347 行：删 merge/withSyntheticGroups/ensureGroupMember/injectSmartPrimary/hasEnabledDns/providerBlocks/providerKey/sectionBody/ruleTarget/ruleTargetExists/hasMatchRule/collectTargets/itemName/unquote/countProxyItems/ensureFakeIpForProfileDns/yamlQuote + SmartInjectResult/GroupMemberResult 类 + PROVIDER_MERGE_KEYS/PROFILE_KEYS/REPLACE_KEYS/RUNTIME_KEYS 常量；留 enforceTunnelContract/isKernelLoadableConfig/hasKey/sectionText/dnsFlowLines/ProfileMergeResult | §2.4 |
| `commons/services/SubscriptionService.ets` | 删 provider 拉取（fetch 循环/appendProviderNodes/parseProviderBody/ProxyProviderParser import）；删 isInfoEntry 6 处；catch 文案改 badResponse 口径（`userMessage` 变量）；EMPTY_ENTRIES 文案改写 | §2.1/§3.1/§4 |
| `commons/services/SubscriptionParser.ets` | 删 isInfoEntry 过滤 + UnusableLedger INFO 记账；删对应 import | §3.1 |
| `commons/subscription/UriNodeParser.ets` | 删 URI 路径的 isInfoEntry 剔除（**保留** INCOMPLETE 缺参记账——那是解析错误记录，不是按名字过滤） | §3.1 |
| `commons/services/VpnQuickStart.ets` | 删首选节点 isInfoEntry 过滤 + import | §3.1 |
| `commons/services/SubscriptionFetchPolicy.ets` | 删死代码：`requestWithRedirectValidation`/`responseEtag`/`headerValue`/`resolveRedirectUrl`/`redirectHeaders` + `http` import（只剩 `connection`）。fetch 主路径本轮未改（上轮已 utls 单路径） | §4.4 |
| `components/SubscriptionSection.ets` | `withSyntheticGroups` 调用改为文件级函数 `withExportSkeleton`（实现移入本文件，仅导出/导入产物链路）；+YamlMerger import | §5.3 |
| `ets/vpnability/VpnExtensionAbility.ets` | 配置读取改 JSON 优先/YAML 回退：`tryParseConfigJson`/`patchConfigMtu`/`readTopLevelBoolAny`/`readDnsEnableAny`；mtu 同步走 `patchConfigMtu` | §5.4 |
| `commons/services/ConnectionOrchestrator.ets` | 仅一行：`profile.profileId = profileId;`（buildRuntimeProfile 内） | §2.2 |

### 0.4 门禁/harness（复查重点：见 §6 全表）
改动门禁 13 个、新增共享工具 1 个（`scripts/fixtures/mini-yaml.mjs`）、harness 登记若干。
**全部细节与理由见 §6**——复查 Agent 请把「改断言 = 掩盖代码问题」当作头号嫌疑逐个过。

### 0.5 产物
| 项 | 值 | 复核 |
|---|---|---|
| 内核 | `entry/libs/arm64-v8a/libgojni.so` 66,208,608 B（2026-11-05 00:35 构建） | `scripts/build-ohos-core.ps1` 可复跑 |
| HAP | `C:\Worker\TunBox\dist\tunbox-flclash-fullport-20261105-signed.hap` 36,382,819 B | 包内 `libs/arm64-v8a/libgojni.so` = 66,208,416 B（hvigor 打包 strip 掉 192 B，四个 TunBox* 导出符号均在；非 45MB 截断档） |
| 签名配置 | `build-profile.json5` 已还原为空 `signingConfigs`（verify-build-profile 13/13） | `node scripts/verify-build-profile.mjs` |

---

## 1. 权威语义来源的裁定（复查 Agent 必须先认这个，否则全盘结论不同）

本地参考库 `C:\Worker\REA\flclash_re\repo`（commit a2e8f13 "support ohos"）是 **FlClash 旧快照**：
- 它没有 `core/profile_base.go`（upstream main 才有）；
- 它的 `core/Clash.Meta` 子模块是空目录；
- 它的 `_makeRealProfileTask` 读 `rawConfig['rules']`，而 mihomo RawConfig 的 json tag 是 `rule`
  （已核实 upstream mihomo 与 tljk/Clash.Meta FlClash 分支 `config/config.go:443`：
  `Rule []string \`yaml:"rules" json:"rule"\``）——旧快照的 apply 链存在 rules 键名错位问题。

**本轮裁定：以 upstream main（chen08209/FlClash，GitHub）为准**，理由：
1. TunBox 旧 ProfileConfigMerger 的头注释引用的 `core/profile_base.go:120-260 mergeProfileBase/appendRules`
   只存在于 upstream main —— 上一轮移植者参照的就是它；
2. upstream main 的 `mergeProfileBase`（内核 YAML-node 级合并：overlay 为根 + proxies/proxy-groups/sub-rules
   三段从 profile 注入 + `appendRules`=overlay 规则在前/profile 在后）与本轮 compose 的语义一一对应；
3. upstream main 修掉了旧版的键名错位（`getProfileBase` 返回 MatchRules，rules 在内核侧合并）。

复核：`curl https://raw.githubusercontent.com/chen08209/FlClash/main/core/profile_base.go`
与 `lib/common/task.dart`、`lib/providers/actions/setup.dart` 对照。

---

## 2. 任务2「profile 解析/合并按 FlClash 语义」的实现明细

### 2.1 compose 的 patch 链顺序（逐键对照 upstream `_makeRealProfileTask`）
| FlClash main（task.dart） | TunBox compose（TunBoxProfileBuilder.ets） | 裁量说明 |
|---|---|---|
| external-controller（safeMode/secret 判空） | external-controller/secret/mixed-port/mode/log-level/ipv6/unified-delay/tcp-concurrent/allow-lan/bind-address 取自 overlay（= 本仓 patchClashConfig 等价物），随后 FlClash 清零默认 | overlay 即生成器产物，本仓的 patch 值单一来源（verify-config-single-source 门禁契约） |
| external-ui/external-ui-url/interface-name 清空、tls/unix/pipe 控制器清空 | 同样清空 + `external-ui-name` | 照抄 |
| port/socks-port/redir-port/tproxy-port = patch 值（默认 0） | 强制 0（本仓只有 mixed-port） | FlClash 默认 socks/port=0 |
| keep-alive-interval=30 / routing-mark / find-process-mode | interval=30、routing-mark=0、find-process-mode='off' | 'off' 来自 FlClash ohos 分支（旧快照 task.dart：`system.isOhos ? FindProcessMode.off.name : ...`）。**裁量**：upstream main 已改为 patch 值（默认 always），本仓保留 ohos=off —— fd 注入沙箱里进程枚举无意义，且旧快照在 ohos 就是 off。**请复查此项** |
| allow-lan / authentication / skip-auth-prefixes | false / [] / [] | FlClash 默认（本仓无认证 UI） |
| unified-delay/tcp-concurrent 默认 true | overlay 有值用 overlay，否则 true | FlClash patch 默认 |
| geo-auto-update=false / geo-update-interval=24 | 同 | FlClash 默认 |
| tun = {profile tun, dns-hijack:any:53, overrides, patch tun, auto-detect-interface:true} | `{...raw.tun, dns-hijack:['any:53'], ...overlay.tun, enable:input.tunEnabled, auto-detect-interface: overlay 有则用否则 true}` + mtu=input.mtu | overlay.tun = 本仓 VPN 合同（stack:mips/mtu/congestion-controller:bbr3/auto-route:false/udp-timeout:300）。**auto-detect-interface: bridge.Start 在 tunFd>0 时硬编码 false**（fd 注入模式），YAML 值照抄 FlClash 的 true 不影响。请复查 YAML/内核双写一致性 |
| sniffer 键级合并 + sniff ports 字符串化 | 同（`scalarText`） | FlClash `mergeSnifferOverride` + ports 归一化（mihomo RawSniffer.Ports 是 []string） |
| profile.store-selected=false | 同 | 照抄 |
| confineProviders：**所有**非 inline provider 都改 path（file 也搬进 provider 缓存目录）；key=`$name@$url`（有 url）或 `$section/$name` | **只收容有 url 的**；file/inline 原样 | **裁量（重要，请复查）**：FlClash main 的 file 型 provider 由它自己的注入系统**写进**缓存目录，所以它敢改 path；本仓的 file 型 provider（如 hyper-adrules.mrs）文件实体在 ruleset 目录，改 path 会指向不存在的文件 → provider 初始化失败 → 整份拒载。本仓语义：file 相对路径由内核按 HomeDir 解析（现状已验证可用）。影响面：仅 http 型被收容 —— 与任务1 目标一致 |
| injectUnconfinedProviders（custom profile 注入） | 无此概念（本仓无 custom profile 类型） | — |
| geox-url=默认镜像 / global-ua=packageInfo.ua | GEOX_URL 四个 MetaCubeX release URL / tunboxUserAgent() | UA 格式 `TunBox/v<版本> clash-verge Platform/OpenHarmony`（FlClash `<AppName>/v<版本> clash-verge Platform/<os>` 同构，App 名换成 TunBox）。**请复查是否要求与 FlClash 字面同串**（现与取回层 tunboxUserAgent 同源） |
| hosts = profile hosts + patch.hosts per-key 覆盖 | 同（overlay.hosts 覆盖 raw.hosts，profile 键保留） | 照抄。注：profile-backed 时生成器 overlay.hosts 为空（DoH pin 只在 legacy 路径启用，与改造前一致） |
| dns：`if (!isEnableDns) mergeDnsOverride(rawDns, baseline.overrideJson(...))` + 用户 per-key dns overrides + appendSystemDns | `if (!isEnableDns) {profile 键打底, app dns 键覆盖, nameserver 追加 system://}`；profile dns 启用 → 原样 | 见 §3.2 专项说明（裁量最大处） |
| rules：custom 替换 / addedRules 在前 + profile 规则在后（内核 appendRules） | overlay 规则按目标存在性过滤 + profile MATCH 冲突时丢 overlay MATCH → `[...appRules, ...profileRules]` | appendRules 顺序一致；目标过滤是旧 merger 已有语义的保留（FlClash main 的等价物 = `matchTarget`：应用附加规则只指向 profile 自己的 MATCH 目标）。**请复查过滤集合**：目标 ∈ profile proxies 名 ∪ 组名 ∪ 内置策略（DIRECT/REJECT/REJECT-DROP/PASS/COMPATIBLE/GLOBAL） |
| safeMode 清 listeners/tunnels 等 | 无此概念 | — |
| mitm 模块 | 无此概念 | — |

### 2.2 生产链路接线
- `ConnectionOrchestrator.buildRuntimeProfile`：仅加 `profile.profileId = profileId`。
- `RuntimeConfigBuilder.buildRuntimeConfig`：profileBacked 分支 → `TunBoxProfileBuilder.build(input)`；
  失败抛错（FlClash applyProfile 抛错同构）。smart 注入条件与改造前一致
  （`useSmart && mode===TUNNEL && autoSelectMode===AUTO`）。
- 钉选：`resolvePinTargetFromProfile(groups, rules, proxyNames, preferred)`（map 级）——
  组解析顺序（首个非 GLOBAL select 组 → rules 反查 select → rules 反查任意组 → 首组）与旧
  `resolvePinTarget` 相同；成员匹配 = 精确名 + `kernelLeafFor`（精确→归一化）；provider 成员
  放行原名（`proxy-providers` 存在时）。**删除**：地区关键词自愈、首叶子替换、任意叶子兜底、
  `ensureGroupMember` 注入。
- legacy（无 profile）路径原样保留（生成器 + enforceTunnelContract + 文本 resolvePinTarget 减自愈）。

### 2.3 dump 形态：JSON（**实现差异，语义等价，请复查**）
FlClash 用 Dart yaml writer dump；ArkTS 无 YAML emitter（鸿蒙生态无可用 yaml 库，ohpm 无包、
node_modules 无依赖——已查证）。compose 用 `JSON.stringify(raw)`。
论证：JSON ⊂ YAML 1.2，内核 `config.Parse` 的 `yaml.Unmarshal`（go.yaml.in/yaml/v3）接受
JSON 文档——**实测**：`mihomo.exe -t -f <纯 JSON 配置>` 通过（含 tun.stack:"mips"、
enhanced-mode:"fake-ip"、nameserver-policy 等字段）。所有枚举字段经 `MarshalText` 序列化为
字符串（TunnelMode/LogLevel/DNSMode/DNSPrefer/FilterMode/TUNStack/FindProcessMode 已逐一
在 fork 源码确认）。风险点（复查建议）：1) Windows 上用 mihomo.exe -t 验过、**设备端 arm64
未实测**；2) json 键序 = Go struct 字段序，与 FlClash 的 YAML 输出顺序不同——对内核解析无影响。

### 2.4 ProfileRepository.validateAndStore
FlClash `Profile.saveFile`：bytes → temp → `validateConfig`（UnmarshalRawConfig）→ copy 到
`profiles/<id>.yaml`。本仓对齐，仅两处本仓既有差异（**请复查是否接受**）：
1. 非 Clash 内容先过 `SubConverter`（base64/URI 列表 → Clash YAML）——本仓产品功能，FlClash 无；
2. 校验点是 `getProfileBase`（UnmarshalRawConfig + 计数），错误文本原样带回 UI。
注意不对称：**导入**校验 = UnmarshalRawConfig（FlClash 口径）；**预览解析**仍用
`ProfileRepository.prepare`（= Go `PrepareProfile`，比 FlClash 严：parseProxies/checkRules）。
prepare 只影响 App 侧预览，不影响内核准入。

---

## 3. 三个专项裁量（最需要复查的地方）

### 3.1 dnsOverrideEnabled（DNS 接管开关）—— 本轮**废除其行为**
- 改造前（旧 merge）：开关开（默认）→ 应用 DNS **整段**替换订阅 dns；关 → 订阅 dns 原样
  （但强制 app listen + 镜像 proxy-server-nameserver）。
- FlClash main 事实：**不存在**整段接管模式。唯一逻辑：
  `if (!isEnableDns) mergeDnsOverride(rawDns, baseline...)`——订阅 dns 禁用才由 baseline 填；
  用户 per-key dns override 是另一个 UI（本仓没有）。
- 本轮实现：compose 只实现 FlClash main 的这条逻辑；`input.dnsOverrideEnabled` 字段保留在
  接口上但 **compose 不再读它**。设置页开关**未删除**（它现在是无效开关）。
- **复查建议**：① 确认接受「开关变摆设」还是要求从设置页删掉；② 真机验证订阅 dns 原样生效
  （含 `dns.listen: 0.0.0.0:53` 这类订阅值——**端口 53 绑定在设备上是否成功未验证**）；
  ③ 2026-10-20 的「机场入口域名私有上游」修复是否仍然成立（FlClash 行为下私有上游天然
  存活，理论成立，真机未验）。

### 3.2 provider 收容只覆盖 url 型（file 型不动）
见 §2.1 表格裁量行。复查点：若 FlClash 语义要求 file provider 也搬缓存目录，需要先把
ruleset 文件复制逻辑建起来——本轮判定为「超出照抄范围且会破坏现状」。

### 3.3 钉选自愈删除的行为回退风险
2026-10-28 的真机修复「选香港连成日本」当时靠 `ensureGroupMember` 注入 + 地区自愈。
本轮按 FlClash 语义全部删除：所选节点不在主组成员表 → PUT 失败 → **如实报错，不换节点**。
复查点：真机上用「主组只列部分节点」的机场订阅验证这个新行为是「明确失败提示」而不是静默
错节点。（FlClash 的 UI 根本不会提供这种选择——它只显示组内成员。）

---

## 4. 任务1/任务3/任务4 的删除清单（复查「删没删错」）

### 4.1 任务1：provider App 侧拉取
- `SubscriptionService.ets`：主刷新路径 fetch 循环（原 ~2480-2524 行）、
  `appendProviderNodes` 整函数、`parseProviderBody` 整函数、`ProxyProviderEntry/ProxyProviderParser` import。
- 留下的痕迹：`SubscriptionImportDiagnostics.providerCount/providerSkippedCount/providerFailedCount/providerTypes`
  字段还在（数据模型未清，恒为 0）；`EMPTY_ENTRIES` 文案改为「provider 订阅的节点由内核拉取后可见」。
- **未做**：诊断面板里 provider 相关计数的 UI 展示清理（不在四项任务范围）。
- 复核：`grep -rn "ProxyProviderParser" entry/src/main/ets` 应只剩 `ProxyProviderParser.ets` 自身
  与 harness 映射；`grep -rn "appendProviderNodes\|parseProviderBody" entry/src/main/ets` 应为 0。

### 4.2 任务3：节点准入
- `isInfoEntry` 6 处调用删除：SubscriptionService（水合过滤、fallbackConnectionNode、
  resolveUserPreference、偏好重锚×2、restoreRememberedPreferredNode×2——共 7 处调用点、
  覆盖此前 6 处的统计口径）、SubscriptionParser.parseClashYaml 尾部过滤、UriNodeParser URI 路径、
  VpnQuickStart。
- `NodeUsability`/`UnusableLedger`/`UnusableCategory`/`UnusableRecord` 类型**保留**
  （UriNodeParser 的 INCOMPLETE 缺参记账仍用；SubscriptionService 仅留 `UnusableLedger.clearFor`）。
- Go `PrepareProfile` 合成组删除（见 §0.1）。
- `ensureUniqueNames` 本轮未动（上一轮已是 no-op，返回 false）。
- **复核注意**：`NodeUsability.isInfoEntry` 函数本体还在 `NodeUsability.ets`（无调用方）——
  要不要连类一起删，复查定夺。

### 4.3 任务4：状态文案
- 位置：`SubscriptionService.refreshSubscription` catch 分支。
- 新文案：RATE_LIMITED（429）与 HTTP_ERROR（其它非 2xx）→ `网络异常，请检查连接后重试`；
  NETWORK（传输层）→ 原始错误（FlClash rethrow），advice 保留（本仓产品字段）；EMPTY_RESPONSE/
  DECODE 文案未动（FlClash 无对应场景——它是把空体交给校验失败的）。
- **保留的偏差（请复查）**：429 仍归类为 RATE_LIMITED 状态（驱动批次统计/UI 状态点），
  但用户文案与 FlClash 一致；advice 字段保留。

### 4.4 死代码清理（与四项任务无直接关系，但属于「照抄后不应存在」）
- `SubscriptionFetchPolicy`：旧 @ohos.net.http 拉取路径 5 个私有方法 + `http` import
  （上轮取回层改造后已无调用方，仅自递归）。复核：`grep -c "http\." SubscriptionFetchPolicy.ets` = 0。
- **未清理**：`RawSubscriptionStore`（双轨 file-provider 实验特性，默认关）、`RawProxyYaml`、
  `LocalSubConverter`、`ManualNodeStore`——均为本仓产品功能或默认关闭特性，不在四项范围。

---

## 5. 鸿蒙平台限制清单（「鸿蒙不具备」的正式答复 + 本轮绕行方式）

| # | 限制 | FlClash 怎么做 | 本轮绕行 | 复核要点 |
|---|---|---|---|---|
| 1 | ArkTS 无 YAML 解析器（官方/三方库均无，ohpm 不可离线引入） | Dart `loadYaml` | 内核新增 `TunBoxDecodeYaml`（mihomo 同一 yaml 库）——解码方言与内核 100% 一致 | 这不是"绕过 FlClash"，是把 loadYaml 的职责交给内核。查 cshared_main.go |
| 2 | ArkTS 无 YAML 序列化器 | Dart `yaml` 包 `Writer` | `JSON.stringify` dump（JSON ⊂ YAML，内核同一解析器加载；mihomo -t 实测通过） | 语义等价论证见 §2.3；设备端未实测 |
| 3 | ArkTS 无同步 MD5（cryptoFramework.Md 只有异步；util 无 md5） | Dart `crypto` md5 | 纯 ArkTS MD5 实现（`md5Hex`），对拍 node crypto（5 组向量含空串/中文/长串） | 门禁 §6 verify-tunbox-profile [8] 每次真跑 |
| 4 | ArkTS 严格模式：无结构化类型/对象字面量必须带类型/无 delete 属性/`Array.isArray` 窄化产 any | Dart 无此限制 | 显式类型转换、`{} as Record<string,Object>`、置空串代替 delete、`as Object[]` | 纯编译层，无语义影响 |
| 5 | ohos fd 注入 TUN 模式：`auto-route/auto-detect-interface` 由 bridge.Start 硬编码 | FlClash ohos 同为 fd 模式 | YAML 值照抄 FlClash（true），内核硬覆盖——双写不一致但行为由内核决定 | 复查 bridge.Start 与 YAML 的关系 |
| 6 | find-process-mode 在 ohos 无意义 | FlClash ohos 强制 off | patch 强制 'off' | 沿用 FlClash ohos 分支行为 |

**没有一条是「鸿蒙不支持所以没做」**——全部四项任务都做了；上表是「鸿蒙不支持 A，所以用 B
等价实现」的清单，每条 B 都给了复核锚点。

---

## 6. 门禁改动全表（复查 Agent 的头号嫌疑区：改断言 ≠ 改对代码）

| 门禁 | 改动类型 | 具体内容 | 为什么不是"改测试掩盖问题" |
|---|---|---|---|
| `verify-tunbox-profile.mjs` | **整体重写** | 旧版断言 `ProfileConfigMerger.merge` 文本语义（该函数已删）。新版：compose 真跑（内核桥数据手喂）+ md5 对拍 node crypto + **compose 产物交真实 mihomo.exe `-t`** | 旧断言对象是死代码；新版测的就是生产实现，且新增了旧版没有的真内核校验 |
| `verify-profile-merge-providers.mjs` | **整体重写** | merge→compose；断言 provider 并集/同名优先/url 收容/RULE-SET 自洽/不造空头 | 同上；旧断言的 RULE-SET 悬空拒载缺陷在 compose 里由结构化合并天然消除（有负对照缺位——建议复查补一个「overlay 悬空目标被过滤」的负对照，现有 F 项已覆盖大半） |
| `verify-smart-injection.mjs` | **整体重写** | injectSmartPrimary（删）→ compose map 级注入 7 用例（含同名组碰撞→不注入） | 同上；碰撞用例是真 bug 的回归网 |
| `verify-smart-inject-unicode-names.mjs` | C 段重写 | merge→inject 文本链改 compose unicode 链（防重守卫 + emoji 逐字一致） | A/B 段（YamlMerger 转义解码）未动 |
| `verify-config-single-source.mjs` | 局部重写 | native fixture 走新链路：沙箱 coreBridge（mini-yaml 承接 getProfileBase/decodeYaml）+ `profileId` 注入 + JSON→canonical YAML 喂旧差异机器；断言更新：keep-alive-interval 17→**30**（FlClash patch 强制）、listen 归订阅（override 不再生效）、sniffer enable 归应用键 | 语义断言全部对照 FlClash main 源码；mini-yaml 是门禁私有工具（生产解码在内核） |
| `verify-mihomo-alignment.mjs` | 第 7 段重写 | 旧断言 If-None-Match/304 发送逻辑——**这些断言在上一轮取回层改造后就已经红**（死路径），非本轮引入。新断言：取回走内核 utls、无 If-None-Match（FlClash 无条件请求）、provider App 拉取=0 | FlClash `request.dart` 本身没有 304 逻辑；旧断言描述的是本仓自造增量刷新（已随照抄移除） |
| `verify-provider-node-visibility.mjs` | 未改 | — | 通过（9/0） |
| `verify-node-selection-logic.mjs` | 删 C 段 | ensureGroupMember 死行为测试 | A/B 段（意图判定/优先级）未动，12/0 |
| `verify-review-runtime.mjs` | 多处 | 沙箱补 fs 代理（路径重定向/OpenMode/fd 包装）+ coreBridge 桩（用门禁自编 helper 校验）；5 个 merge 依赖测试改写为 compose/内核校验语义；appendProviderNodes 切片边界换锚点；provider parse 计数 3→0 | helper 是按当前 fork 源码现编的（`go build scripts/fixtures/profile-prepare/main.go`），校验语义与内核同步 |
| `verify-conversion-output-runtime.mjs` | 小改 | 沙箱加载 `withExportSkeleton`（生产实现移到了 SubscriptionSection 文件级） | 导出补骨架语义未变（旧 via withSyntheticGroups） |
| `verify-sub-convert-protocols.mjs` | [D] 段重写 | withSyntheticGroups/merge 断言改为「源码已不含死函数」的静态检查 | 裸表不再合成组 = 任务3 语义 |
| `verify-subscription-fidelity.mjs` | 契约反转 | INFO 排除台账 → 「INFO 条目按普通节点解析」；`explicit INFO exclusions: 1` → `: 0` | 任务3 的直接后果；旧契约断言的是已删除的自造过滤 |
| `verify-release-gates-runtime.mjs` | 期望值 | INFO exclusions 1→0 | 跟随 fidelity 契约 |
| `verify-vpn-architecture.mjs` | 一个模式 | `readTopLevelBool(text,'ipv6')` → `readTopLevelBoolAny(text,'ipv6')`（VpnExt 函数改名） | 跟随实现 |
| `verify-sub-fetch-parity.mjs` | 补 shim | 沙箱补 `core/CoreBridge.ts` 垫片（fetch-parity 用例本就静态断言，无需注入内核） | 取回层 import 变化的跟随 |
| `verify-credential-isolation.mjs` | 未改 | 通过（7/7） | — |
| `tools/true-chain-harness/prepare.mjs` | 登记 | +TunBoxProfileBuilder（含 AppLogger 映射）、ProfileRepository +coreBridge 映射、stubs.ts +tunboxUserAgent/harnessCoreBridge | 交接文档坑 #1 的例行公事 |
| `scripts/fixtures/mini-yaml.mjs` | **新文件** | 门禁共享受控子集 YAML 解析/序列化（流式优先于冒号启发式——修过一个把 `- {name: A}` 拆坏的 bug） | 仅门禁用；生产解码在内核 |
| `verify-startup-assets-runtime.mjs` | 接新链路 | 沙箱注入 builder（独立 vm context）+ coreBridge（mini-yaml）+ LatencyTestUrl/ProfileRepository/tunboxUserAgent 全局 + profileId + live 端口替换兼容 JSON | **64 项真内核 `-t` + 4 项活内核启动全绿（含 profile-backed JSON 配置）** |

### 6.1 门禁最终数字（2026-11-05 03:0x 实测）
verify-all：**PASS=94 FAIL=1 SKIP=2**。唯一 FAIL = verify-subscription-fidelity（设计要求
`TUNBOX_SUBSCRIPTION_FIXTURE` 私样本；合成 fixture 实测 91 项全绿）。未执行的
verify-ui-resource-bindings 是「需要先 assembleHap」的既有 SKIP 语义（assembleHap 后单独跑即绿，
verify-arkts-compile 里已包含等价检查并通过）。

---

## 7. 没做的事 / 被阻塞的事（完整清单）

1. **真机 A/B（全部四项的最终验收）**：`hdc tconn 192.168.3.146:39933` Connect failed；
   5555/39932-39934/38933/40333/41933 TCP 全关；ping 通但无线调试端口不在。
   按仓库铁律「真机可能被机主占用需即停」停止扫描。机主侧开启无线调试后按交接文档 §5 步骤执行。
2. **dnsOverrideEnabled 设置项 UI 清理**：开关已无效但仍在设置页（删 UI 不在四项范围，怕越权）。
3. **SubscriptionImportDiagnostics 的 provider 字段**：恒 0，数据模型与 UI 展示未清。
4. **NodeUsability 类本体**：isInfoEntry 已无调用方，类未删（避免连锁改动，复查定夺）。
5. **RawSubscriptionStore 双轨机制**：默认关，未动（与真 provider 通道并存的实验特性；
   照抄后它已无必要，但删除超出四项范围）。
6. **私样本 fidelity 跑批**：需要真实订阅文件（不入库）。
7. **FlClash 对照真机同跑**（交接文档判定标准「同一台机器同时跑 FlClash 与 TunBox」）：
   需设备上装有 FlClash HAP + 同订阅——被设备阻塞。
8. **设备端 JSON 配置的 arm64 内核解析**：Windows mihomo.exe -t 验过，同源代码的 arm64
   产物未实测（startup-assets 门禁里的 4 次**活内核启动**是 Windows exe；设备端待装包验证）。
9. **提交**：工作树 166 路径未提交（含上一轮遗留）；按仓库规则签名口令/证书不入库，
   提交窗口留给复查后。

---

## 8. 本轮事故与自纠（如实陈述）

1. **git checkout 误恢复**：`git checkout HEAD -- SubscriptionSection.ets` 洗掉了工作树未提交
   状态。**恢复**：改前快照 zip 内同名文件（115,901 B）与所有 %TEMP% 门禁转译副本字节数一致
   ——确认快照即工作树基线，无一丢失；随后用 Edit 工具干净重打两处补丁。
   **教训已写进交接文档 §6.8：worktree 未提交期间禁用 checkout 恢复。**
2. **ProfileConfigMerger 首次瘦身脚本剪破文件**（花括号配对被字符串里的 `{` 干扰）：
   从备份恢复后改用「签名行→两空格闭括号行」的行级删除，过 hvigor 真编译验证。
3. **中途若干脚本 heredoc 的反斜杠被传输层吃掉**：全部改用 Write 工具落盘 Python 脚本执行；
   SubscriptionSection 一度被这类脚本写坏过一次（同一次事故链），已随快照恢复。
4. **发现并修复的真 bug**（非引入）：profile 已有 `♻️ 自动选择` 组时 smart 注入会产生
   重复组名 → 内核整份拒载（旧文本注入同样有此问题）；现 compose 有防重守卫 + 门禁用例。

---

## 9. 复查优先级建议（如果只查 8 件事）

1. **§3.1 dnsOverrideEnabled 废除**——最大的行为变更，确认产品上可接受（开关处理方式）。
2. **§2.3 JSON dump**——设备端 arm64 实测一次 `bridge.Start` 读 JSON 配置（装包即验）。
3. **§2.1 confineProviders 只收 url 型**——对照 FlClash main `confineProviders` 判断 file 型处理是否可接受。
4. **§3.3 钉选自愈删除**——真机复测「主组只列部分节点」的订阅。
5. **§6 门禁全表**——逐个 diff 断言，确认没有把「代码错」改成了「断言迁就」。
6. **global-ua 字符串**——是否要求与 FlClash 字面同串（现 `TunBox/v… clash-verge Platform/OpenHarmony`）。
7. **订阅 dns.listen 落到订阅值**（如 0.0.0.0:53）——设备上内核能否绑定（我未验证）。
8. **profile_prepare.go 合成组删除**——裸 proxies 表在内核里的最终形态（GLOBAL 兜底、无规则路由）
   在设备上确认可用。
