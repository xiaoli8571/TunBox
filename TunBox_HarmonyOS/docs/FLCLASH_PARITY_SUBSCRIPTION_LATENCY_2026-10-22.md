# FlClash 1:1 复刻：订阅解析 + 节点测速（2026-10-22）

目标（用户原话）：**按 FlClash 1:1 重做 TunBox 的订阅解析与节点测速，不允许有任何不同**；
**取消多订阅合并**（smart 自动优选也只在当前订阅内）。规格与源码依据见
`docs/FLCLASH_PARITY_SPEC_2026-10-22.md`（每条都带 FlClash 源码行号）。

---

## 一、口径（现在的事实）

### 订阅解析

| 环节 | 现在的行为 | 依据 |
|---|---|---|
| 拉取 | 现有 `SubscriptionFetchPolicy`（UA 链、20s 超时、大小上限、明文 HTTP 开关） | FlClash 用单 UA + 20s；TunBox 保留既有加固，语义不冲突 |
| 判定 | 内容含 `proxies:` / `proxy-groups:` / `proxy-providers:` → 内核可解析 | FlClash `validateProfile` |
| 非 YAML | 走 `SubConverter`（mihomo `convert.ConvertsV2Ray` 的 ArkTS 逐行移植）→ 重写成 `proxies:` 列表 | FlClash `convertProxies` |
| 落盘 | `<filesDir>/profiles/<subId>.yaml`，原文一字不改 | FlClash `<id>.yaml` |
| App 侧节点表 | **不再作为权威**；配置由原文决定 | FlClash 从不把节点解析进 App |
| 节点名 | **不再改名**（`ensureUniqueNames` 变 no-op） | FlClash 从不重命名 |
| 多订阅 | 只有一个 `currentProfileId` 生效；点订阅头部切换 | FlClash `currentProfileId` |

### 配置生成

`RuntimeConfigBuilder` 生成 overlay（端口 / secret / tun / mode / dns / 规则）后，走
`ProfileConfigMerger.merge(overlay, profile)`：

- 原文的 `proxies` / `proxy-groups` / `sub-rules` / `proxy-providers` / `rule-providers`
  / `tunnels` / `listeners` 整段接管；
- `rules` = overlay 在前 + 原文在后（`appendRules`）；
- 原文 `dns.enable: true` → 整段 dns 用原文（FlClash `isEnableDns`）；
- 原文 `hosts` / `sniffer` 在 overlay 未声明时搬入；
- **overlay 里目标不存在的规则被丢弃**（原文组名接管后，`MATCH,PROXY` 会造成内核整份拒载 ——
  本地真实内核已抓到 `rules[1] [MATCH,PROXY] error: proxy [PROXY] not found`）。

### 节点测速

| 项 | 值 | 依据 |
|---|---|---|
| 接口 | `GET /proxies/{name}/delay?url=…&timeout=5000` | 内核 `proxy.URLTest`（与 FlClash IPC 同一函数） |
| 并发 | 32（客户端池） | `maxConcurrentDelayTests = 32` |
| 超时 | 5000ms | `defaultDelayTestTimeout = 5s` |
| 守护 | 30000ms（不写结论） | `delayTestGuardDuration` |
| URL | `https://www.gstatic.com/generate_204` | `defaultTestURL` |
| 结果 | `>0` 延迟 / `-1` 超时 / `-2` 失败；拿不到响应不写结论 | `delayValue()` |
| 组测速 | 组内节点**逐个**测 | `delayTest(group.all)` |
| 自动测速 | **无**（`scheduleStartup` 变 no-op） | FlClash 只在用户操作时测 |
| 已删除 | 离线 TCP 探活、DNS 预解析判定、core_not_ready 连击作废、批次硬截止、5 分钟新鲜度、`/group/{name}/delay` | FlClash 都没有 |

---

## 二、改动文件

**新增（`entry/src/main/ets/commons/flclash/`）**

| 文件 | 作用 |
|---|---|
| `SubConverter.ets` | mihomo `convert.ConvertsV2Ray` 逐行移植（hysteria/hy2(+realm)/tuic/trojan/vless/vmess/ss/ssr/socks/http/anytls/mierus，含 `uniqueName` 重名规则） |
| `ProfileStore.ets` | profile 文件读写（原子写、0600、8MB 上限）+ current id + `validateAndStore`（校验→convert→落盘） |
| `ProfileConfigMerger.ets` | `mergeProfileBase` 的 ArkTS 等价（含规则目标过滤、dns/hosts/sniffer 语义） |
| `CoreCatalog.ets` | `/proxies` → 组/节点模型、组类型判定、GLOBAL hidden、排序、隐藏超时、文案/配色 |
| `CoreCatalogService.ets` | 目录快照（800ms TTL）+ 拍平节点 + 组归属推断 + 选点 |
| `CoreNodeBridge.ets` | CoreNode → ProxyNode 影子（`core:<name>`，名字/协议来自内核） |
| `FlclashDelay.ets` | 32 并发测速引擎（transport 可注入，便于 Node 单测） |
| `FlclashLatencyService.ets` | 测速服务（写 LatencyLiveView、批次进度、取消、`wait()`） |

**改动**

- `commons/config/RuntimeConfigBuilder.ets`：`profileYaml` 字段 + merge 接线。
- `commons/services/SubscriptionService.ets`：ProfileStore 初始化/convert 注入、刷新时落 profile、
  首个订阅设 current、删除/撤销同步 profile、`ensureUniqueNames` no-op、`findNode('core:…')` 回落。
- `commons/services/ConnectionOrchestrator.ets`：配置基底取当前 profile；`findNodeByName` 支持内核影子。
- `commons/services/ClashApiService.ets`：`proxiesJson()` / `selectProxyInGroup()` /
  `endpointBase()` / `endpointSecret()`；`selectNode` 不再假设组名是 `PROXY`（先按 `/proxies` 找真正包含该节点的组）。
- `commons/services/BackgroundLatencyService.ets`：重写为 FlClash 语义薄层（逐节点、无自动测速、无组测速端点）。
- `pages/SubscriptionPage.ets`：订阅头部点击切换 current profile（热重载、不断线）；节点区数据源切到内核目录；
  卡片/概览节点数用内核数；protocol 标签用内核 type。

**验证脚本（新增）**

- `scripts/verify-sub-converter.mjs`：107 项（含真实 mihomo `-t`）
- `scripts/verify-flclash-delay.mjs`：9 项（桩内核：32 并发 / -1 / -2 / 取消 / 守护 / 排队不计时）
- `scripts/verify-core-catalog.mjs`：39 项
- `scripts/verify-flclash-profile.mjs`：merge 语义 + **真实内核接受**

**契约更新（过期断言改成当前口径）**

- `scripts/verify-vpn-architecture.mjs`：`latency.group-test-single-entry` 改为
  「唯一入口 = FlclashLatencyService.start」，并新增 `notHas(testGroupDetailedResult)` 与 32/5000/gstatic 断言。
- `scripts/verify-config-single-source.mjs`：补 `../flclash/ProfileConfigMerger` 的转译映射。

---

## 三、验证证据

| 项 | 结果 |
|---|---|
| `verify-sub-converter.mjs` | 107 passed, 0 failed（含真实内核 `-t` 接受 47 节点订阅转换结果） |
| `verify-flclash-delay.mjs` | ALL PASS 9/9（桩内核实测：在途峰值 32、504→-1、503/404→-2、取消零结论、守护零结论、排队不计入） |
| `verify-core-catalog.mjs` | 39 passed |
| `verify-flclash-profile.mjs` | ALL PASS（含真实内核 `-t`） |
| `verify-vpn-architecture.mjs` | 303 passed, 0 failed |
| `verify-config-single-source.mjs` | 42 passed, 0 failed |
| `verify-subscription-parse-integrity.mjs` | 71 passed, 0 failed |
| `verify-config-generation-integrity.mjs` | 126 passed, 0 failed |
| 真实订阅 merge | 本机 5 份真实 profile（7/24/26/28/46 节点）全部 merge 后 `mihomo -t` 通过 |
| `assembleHap` | BUILD SUCCESSFUL |
| 真机安装 | `hdc install -r entry-default-signed.hap` 成功 |

真机日志（设备 192.168.10.7:39933）：

```
ProfileStore: profiles dir ready: …/files/profiles current=268b99d0-…
SubscriptionService: profile saved as-is: id=268b99d0-… bytes=30834 items=24
ConnectionOrchestrator: profile base: id=268b99d0-… bytes=30834 exists=true
RuntimeConfigBuilder: profile merged: mode=tunnel applied=proxies,proxy-groups,dns,rules items=24
FlclashLatencyService: delay batch start: nodes=24 url=https://www.gstatic.com/generate_204 source=manual
FlclashLatencyService: delay batch done: total=24 measured=24 timeout=0 failed=0 cancelled=0
SubscriptionPage: core catalog nodes=26
VpnExtensionAbility: core start result: true
ConnectionOrchestrator: connect timing: prep=29ms prelaunch=35ms launch=278ms ready=574ms pinned=628ms total=628ms
ConnectionOrchestrator: connected to node hy2台湾
```

界面（`uitest dumpLayout` 回读，节点区来自内核目录）：

```
VLESS | 81ms | VLESS | 82ms | 🇸🇬新加坡•移联02 | VLESS | 94ms | … | HYSTERIA2 | 47ms | SHADOWSOCKS | 31ms
```

---

## 四、已知限制（不是“后续建议”，是当前边界）

1. ~~节点选择后连接的目标可能仍是上一次的节点~~ —— **已修**：`connect()` 的 `isValidNode` 用
   `ClashConfigGenerator.proxyYamlLine()` 判节点是否可序列化，影子节点（server 为空）被判无效后
   回落到 `subs.nodes[0]`。现已改为「影子节点直接有效」（配置由原文决定）。
   真机复测：选 `core:🇭🇰 香港Z09 | IEPL` → 连接日志 `connected to node YF香港-VLESS-WS-CF`
   （即所选节点），`connect timing total=810ms`。
2. **provider-only 订阅**（只有 `proxy-providers`，没有静态 `proxies`）：原文段会搬进配置，
   但设备侧 provider 加载此前有「0 节点」记录（见 skill「provider 权威模式」），本机未复测。
3. **信息条目**（订阅里的流量/到期/官网伪节点）现在是内核节点（FlClash 也如此），
   会出现在节点列表并可被测速；这与旧版的「剔除信息条目」行为不同，是 1:1 的必然结果。
4. `verify-types` 的 `[A]` 段仍是存量红（SDK 自带 `@ohos.annotation.d.ets` 污染），非本轮引入。
5. `NodeSelectionPage`（从主页进入的独立节点页）仍用 App 解析表 + 旧 `LatencyEngine`，
   尚未切到内核目录/新引擎；订阅页已切完。
6. 未提交 git：工作区里混有本轮与用户既有改动（`LocalSubConverter.ets`、`SettingsPage.ets`、
   `SubscriptionFetchPolicy.ets`），且当前分支为 `main`；按「只提交本轮文件」的纪律，
   提交动作留给分支整理时执行。

## 五、回退

- 配置合并：`RuntimeConfigBuilder` 里 `profile.profileYaml` 为空即回到旧的 overlay 全量生成
  （`ProfileStore` 目录删掉 / current 置空即可）。
- 测速：`BackgroundLatencyService` 的唯一入口是 `FlclashLatencyService.start`；
  旧 `LatencyEngine` 仍在仓库里（未被调用），需要回退时可把入口改回 `LatencyEngine.start`。
- 订阅：profile 文件是**新增**的旁路产物，删掉不影响已存节点表；旧解析链仍在（配置生成时会用它的 groups）。


---

## 六、2026-10-22 追加修复（用户反馈三项）

### 1. 来回切订阅后节点串到别的订阅下

根因：`appliedProfileId` 在**生成配置文本时**就写入，内核可能还在加载/整份拒载；
界面据此认为"内核里是这份 profile"，于是用旧内核目录渲染新订阅的卡片
（实测：吹雪云卡片里出现 oc2 的 7 个节点）。

修法：

- `appliedProfileId` 改由 `confirmProfileApplied(stage)` 在**内核真的确认**后落定：
  `reloadFromPath` 成功（hot-reload）/ 隧道 readiness 通过（tunnel）/ 测速核 ready（test-core）。
- 新增 `pendingProfileId`（生成时记录）与 `appliedProfile()` getter。
- `ensureProfileApplied()`：current 与 applied 不一致时，已连接走热重载、未连接则作废测速核；
  不再直接改 applied。
- 界面三重一致才用内核目录：`appliedProfile() === ProfileStore.currentId() === 卡片 subId`，
  任一不一致回落该订阅自己的解析表（宁显示旧数据，绝不把别人的节点画进来）。
- `reload()` 不再把 `activeSubId` 覆盖成 `nodes[0].subscriptionId`（影子节点在解析表里找不到是正常的）。
- "使用中"徽标与卡片描边改绑 `ProfileStore.currentId()`；ForEach key 也换成
  `nodeCountOf(sub)` + currentProfileId，避免切换后不重渲染。
- `activateProfile(id)` 加 800ms 同 id 防抖（onPageShow + bootstrap + 点击会同时触发）。
- 预览版真机复测：吹雪云 24 节点 ↔ oc2 7 节点来回切，`profile applied` 与
  `profile activated coreNodes=` 一一对应，卡片节点始终属于本订阅。

关于"两种版本"：选**方案 B**（当前实现）——**内核优选只作用于当前订阅**（单 profile）。
方案 A（复制合并一份给 smart 用）等于恢复多订阅合并，与"取消合并"的定案冲突，未采用。

### 2. 订阅展开区"已去掉 N 个节点"提示

已删除 `infoHint()` 的整块 UI（"N 条信息条目已跳过…"）。节点仍按内核原样显示
（信息条目在 FlClash 里也是节点），只是不再提示。

### 3. 设置页「订阅转换」改为导出 YAML 文件

`SubConvertDialog` 重写：转换成功后直接弹 `picker.DocumentViewPicker.save()`
（与「导出备份」同一套交互），文件名 `TunBox订阅-YYYYMMDD-HHmm.yaml`，
后缀过滤 `YAML 文件|.yaml`，写入 `ConvertOutcome.yaml`；不再生成
`127.0.0.1:65530/localsub/*.yaml` 伪订阅链接，"导入为订阅"按钮一并移除。
