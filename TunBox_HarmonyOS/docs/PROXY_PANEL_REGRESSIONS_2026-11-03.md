# 节点面板回归修复：ikuuu 节点丢失、jdydy 不排序、本地模板测不了速

日期：2026-11-03（第二轮，接 `LOCAL_YAML_IMPORT_DEVICE_2026-11-03.md` 之后）。
版本：`0.8.1 / 557`（clean 构建 + 资源门禁 4/4 + build-profile 13/13，真机覆盖安装验证）。

## 用户报障（三条）

1. 本地 YAML 订阅一直显示 0 节点，测速提示「没有可用代理」。
2. codex 那轮修复后，ikuuu 订阅的节点全部加载不出来。
3. 导入的 jdydy 订阅不再按延迟排序。

## 根因与证据（都在真机上取过数据）

### A. ikuuu 节点消失 = 组员名被 YAML `\U` 转义，与节点名对不上

- 设备 `files/profiles/6c20de4d-….yaml`（native `PrepareProfile` 的产物）里组员写的是
  `"\U0001F1ED\U0001F1F0 香港Z01"`。原因是 mihomo 用的 `gopkg.in/yaml.v3` 在输出双引号
  标量时把**非 BMP 字符（emoji 国旗）**转成 `\Uxxxxxxxx`。
- 节点名来自原文解析（真 emoji `🇭🇰 香港Z01`）；组员名却由 `SubscriptionParser.yamlScalar`
  只剥引号**不解码转义**得到字面量 `\U0001F1ED…`。两边永不相等 →
  `ProxyPanelMembers.fromLocal` 一个都匹配不上 → 面板整组为空。
  `proxy_groups_json` 里 ikuuu 的 11 组共 47 个成员全部是转义串，实测命中 0。
- 修复：`SubscriptionParser.yamlScalar` 对双引号标量调用 `YamlMerger.unescapeDoubleQuoted`
  （单引号按 YAML 语义 `'' → '`）。修复后同一份存量数据在 `init` 阶段由
  `rebuildGroupsFromCacheIfMissing` 重新解析并落库：47 个成员全部还原成真 emoji，
  与节点名命中 46/47（剩下 1 个是 `DIRECT`），面板显示 `46 节点 · 11 分组`。

### B. jdydy 不排序 = 「成员里有子组就整体不排序」的懒规则

- `panelNodes()` 原来写的是：
  `if (!sortByDelay || arr.some(isGroup)) return arr;` —— 只要组里有子策略组就整列保持
  声明顺序，带子组的订阅（jdydy / ikuuu / 模板）永远排不了序。
- 修复口径：子策略组是「文件夹」→ 保持声明顺序钉在顶部；真实代理按延迟升序；
  DIRECT/REJECT 等策略成员与信息型伪成员排末尾（保持声明顺序）。
- 真机验证（jdydy / 筋斗云）：`台湾01 88ms → 日本03 98ms → 日本04 109ms → 韩国02 111ms
  → 美国02 195ms → 德国01原生 231ms`，其后是超时项。

### C. 本地模板「0 节点 + 测不了速」= 文件里本来就没有代理，但拒测逻辑比 FlClash 严

- 文件事实（`files/profiles/aa3701af-….yaml`）：`proxies` 只有 1 条 `直连(type: direct)`；
  `proxy-providers.HH.url` 是字面值 `订阅URL`（占位符，没有 scheme）。
  所以「0 节点」是**真实状态**，不是解析丢了节点：33 个组里除 `直连` 外全是策略组。
- 但 FlClash 导入同一份文件可以正常测速：它就是把组员（含子策略组）逐个丢给
  `/proxies/{name}/delay`，测不到就如实显示超时；TunBox 旧逻辑在
  `ProxyPanelMembers.delayNames` 里「没有任何真实代理 → 直接返回空表」，
  于是弹「没有可测速的代理节点」，用户看到的就是「点了没反应」。
- 修复：`delayNames` 去掉「无真实代理即拒测」的早退。组存在就测可见组员
  （子策略组算目标，DIRECT/REJECT 不算）；只有组里全是策略成员时才报
  「该分组没有可测速的成员（只有 DIRECT/REJECT 等策略）」。
  真机实测（本地模板 / 默认代理）：`delay batch start: nodes=17` →
  `total=17 measured=15 timeout=0 failed=0 cancelled=2 wall=262ms`，行内出现
  `30~34ms` 延迟，与 FlClash 行为一致。
- 顺带把「为什么 0 节点」讲清楚，不再让用户猜：
  - 导入/刷新前静态校验 provider url（`ProxyProviderParser.invalidUrlReason`），
    占位符/缺 scheme 的不再发无意义请求，日志记 `proxy-provider url invalid: HH url=订阅URL`。
  - 刷新 toast 从「✓ 已刷新」改成
    「本地:Ymihomo 已刷新，但节点未加载：provider「HH」的 url 不是可拉取链接（当前值：订阅URL）…」。
  - 面板空状态区分「该分组暂无可用节点」与「该订阅没有真实代理节点（0 节点）」，
    后者提示「proxy-providers 的订阅地址还是模板占位符」。

## 改动文件

- `entry/src/main/ets/commons/services/SubscriptionParser.ets`：`yamlScalar` 解码双引号转义。
- `entry/src/main/ets/commons/flclash/ProxyPanelMembers.ets`：`delayNames` 对齐 FlClash（组员即目标）。
- `entry/src/main/ets/commons/services/BackgroundLatencyService.ets`：空批次文案区分「组里没成员」与「订阅没代理」。
- `entry/src/main/ets/commons/services/ProxyProviderParser.ets`：`invalidUrlReason` / `invalidUrlEntries`。
- `entry/src/main/ets/commons/services/SubscriptionService.ets`：provider 拉取前静态校验占位符 url。
- `entry/src/main/ets/components/SubscriptionSection.ets`：排序按组/代理/策略三桶；空状态文案；
  刷新 toast 带上 provider 原因；`toast()` 支持 duration。
- `scripts/verify-proxy-panel-members.mjs`：延迟目标用例改为 FlClash 口径
  （模板也测组员；组里只有 DIRECT 时才报「没有可测速的成员」）。

## 回归

- `verify-proxy-panel-members.mjs` 17/17、`verify-logic-pure.mjs` 228/228、
  `verify-ui-resource-bindings.mjs` 4/4、`verify-build-profile.mjs` 13/13。
- 三次 clean 构建均 BUILD SUCCESSFUL；557 覆盖安装保留订阅与设置。
- 真机截图取证：ikuuu 面板 `46 节点 · 11 分组` 正常列出；jdydy 按延迟升序；
  本地模板 `测试中 → 30~34ms`，刷新 toast 明确指出 `HH.url = 订阅URL` 是占位符。

## 边界

模板里的 `HH.url` 仍是占位符，**没有远程节点**这件事只能由用户填真实订阅地址解决
（或换一份自带 `proxies` 的配置再导入）。应用侧不再假装成功，也不再用别人的机场链接顶替。

# 第二轮（同日 14:00–14:55）：FlClash 对齐 + 「未生效」定案 + 0.8.1/557 重打包

用户第二轮口径（原文）：「本地这个订阅还是显示 0 节点，测速正常了，并且我选择了节点，启动后就变成直连了。
2、你上面发现的这些没有对齐的全部实现对齐」；随后追加：「订阅里面怎么多了一个显示超时，这个完全去掉……
还是只保留按延迟和双列排布」「测试有些显示未生效」。

## 1. 已实现的对齐项

| 编号 | FlClash 行为 | 本轮实现 |
| --- | --- | --- |
| G1 | 行上显示的是组**真实出口**的延迟 | `ProxyPanelMembers.exitOf()`（沿 `now` 追 ≤6 跳、防环、退回首成员）；`delayLookupNames()` = `[name]` 或 `[name, exit]`；`pingRecord()/pingText()/pingColor()` 与排序都走出口记录 |
| G2 | 载入配置后重新施加已保存的组选择（`patchSelectGroup`） | `ClashApiService.applyGroupSelection()` + 连接编排在 `connectExclusive` 里重放 `ProxyPanelMembers.selectionsFor(proxyGroupSelections, profileId)`，被钉住的规则组直接 `pinned=true` |
| G3 | ~~组行**点进去**~~ → **组行直接选中**（第三轮用户口径，见 §6） | `handleNodeTap` 组行 → `selectAsMember()`（`PUT /proxies/{parent}`）；下钻与「← 上级」面包屑已整段删除 |
| G4 | 卡片只报真实代理数（第三轮：**去掉「N 分组」**，见 §6） | `ProxyPanelMembers.summary(nodes)` → `N 节点` / 空串；`proxyCount()` 单独做「内核还没加载」判据，卡片无节点时只留更新时间 |
| G5 | 「按延迟 / 原始」为持久化开关 | `nodeListSortMode` 写入 `SettingsService.patchSettings`，重开面板保持 |
| G6 | 组用**自己的**测速 URL / 期望码 | `testSubscription()` 取 `ProxyGroup.url`、`ProxyGroup.expectedStatus` 传给 `runNames(..., expected)`；`delayUrl()` 追加 `&expected=` |

**被用户否掉的一项**：`proxyPanelHideTimeout`（「隐藏超时」chip）已连同 `AppSettings` 字段、
过滤逻辑、行 key 一起整段删除，面板上只剩「按延迟/原始」和双列排布。

## 2. 「测试有些显示未生效」定案

真机日志（本地 `本地:mihomo1`，provider PQ）：

```
CoreCatalogService: provider PQ: type=HTTP nodes=62
BackgroundLatency: delay names group="默认代理" count=6 skipped=0/9:
  COMPATIBLE | 🇯🇵AWS日本01 | 电信移动联通推荐 | … | 🇸🇬AWS新加坡04 | 电信移动联通推荐
FlclashLatencyService: delay failed: 🇸🇬新加坡01-0.1倍 | 电信联通推荐 http=404 value=-2
…（5 个 404）
```

结论：面板把组里**声明的成员名**直接丢给 `/proxies/{name}/delay`，而这些名字此刻还没进
内核 `/proxies`（`proxies=28`，provider `PQ` 自己已拉满 62 个），404 被归类成
`SWITCH_FAILED` → 行上就是一片「未生效」。不是节点坏、也不是测速坏了。

修法：`ProxyPanelMembers.delayPlan()` 只交出**内核确实认识**的名字（未知名字计入
`skipped`，0 个目标时 toast 明说「该分组有 N 个成员还没进内核（provider 正在拉取或名字不匹配）」）。
修后同一动作：`count=1 skipped=8/9`，`total=1 measured=1 failed=0`，不再刷红。

新增诊断（只在日志里，不上 UI）：`CoreCatalogService.logProviders()` 打 `/providers/proxies`
的每个 provider 类型与节点数；`FlclashLatencyService.apply()` 打失败明细 `名字 + http 码`。

## 3. 内核库被截断的事故与修复

`clean assembleHap` 时链接失败：

```
ld.lld: error: …/libgojni.so: section header table goes past the end of the file: e_shoff = 0x2ba40e0
```

工作树里的 `libgojni.so` 比应有的 45,762,656 B 少了 16,288 B（尾部节头表被截掉），
增量构建因为没重链接所以一直没暴露。用 `scripts/build-ohos-core.ps1`（`OHOS_NDK=…\Sdk\26.0.0\native`，
脚本默认的 `Sdk\23` 已不存在）整份重编，产物 **45,762,656 B / SHA-256 `29068E0B…41631`**，
与 `libgojni.sha256` 记录一致，`TunBoxUpdateNetwork` 符号在；`clean` 构建随之恢复。

## 4. 0.8.1 重打包与上传

- `AppScope/app.json5`：`versionName 0.8.1` / `versionCode 557`（versionCode 是整数，只能递增，
  AGC 那栏显示 `0.8.1 (557)` 是「版本名（版本号）」两字段，不是两套版本号）。
- `sign-nexus-package.ps1 -Kind app` → `dist/TunBox_HarmonyOS-0.8.1-release-signed.app`
  （SHA-256 `6397D6AC…ECB4`，23,503,028 B）、`dist/TunBox-0.8.1-release-signed.hap`（`D1965F2F…F273`）。
- AGC 上传：`packageId 2075483057447539456`，`bound=true`，上传时间 2026-11-03 14:54；
  14:11 那次（`2075461411491845696`）被同版本新包取代。
- 门禁：`verify-proxy-panel-members` 17/17、`verify-logic-pure` 228/228、`verify-ui-resource-bindings` PASS、
  `verify-build-profile` 13/13。

## 5. 待用户自测的点

1. 本地订阅卡片应显示 `62 节点 · 21 分组`（不再只有分组）。
2. 点组行应**钻进子组**并出现「← 上级」，行尾圆圈才是选成员。
3. 选好成员后开连接：日志应出现 `saved group selections replayed: N rule=…`，且组 `now` 等于所选成员（不再回直连）。
4. 本地 YAML 的 provider 节点要等内核把 provider 拉完才可拨测；面板会如实显示 `--`/跳过数量，不再整片「未生效」。


# 第三轮（同日 19:30–20:05）：组行直接选中 + 选完即回主页 + 模式切换自动重启

## 6. 用户第三轮口径（原文）

1. 「去掉订阅里面的『上级：默认代理』，我看 clashplus 和 flclash 都没有。」
2. 「类似『台湾手动』这种小分组不需要再点击后进入查看节点。」
   → 追问后明确：「小分组不展开，你看看 flclash 展开吗？就直接选择。」
3. 「选择节点后立即回到主页，现在选完节点要么点返回要么点顶部的订阅。」
4. 「规则、全局、直连这三个切换的时候如果需要重启代理生效，你就帮我改成代理连接状态的时候自动启动代理。」
5. 「订阅卡片上的 xx 分组，这个提示去掉。」
6. 追加报障：「我选择『台湾手动』，启动代理后显示这个小组里面的节点，但是出口还是我的真实出口 IP，不是节点的 IP。」

## 7. 落地改动

| 项 | 文件 | 做法 |
| --- | --- | --- |
| ① 去掉「上级：xxx」 | `components/SubscriptionSection.ets` | 下钻整段删除（`drillInto`/`drillUp`/`groupPath`/「← 上级」ListItem 全部移除），面板只剩组 chips + 节点行 |
| ② 小分组直接选中 | 同上 | `handleNodeTap` 组行 → `selectAsMember()`；不再展开、不再进组（与 FlClash 截图一致） |
| ③ 选完即回主页 | 同上 | `selectPanelMember()` 成功/失败保存后都 `closePanel()`（原来只有 `selectNode`/`selectSmart` 关面板） |
| ④ 模式切换自动重启 | `pages/HomePage.ets`、`services/ConnectionOrchestrator.ets` | `applyProxyMode()` 返回 `ProxyModeApply`（hot/restarted/deferred/hot-failed）；连接态热更新失败 → `restartIfConnected('proxyMode=…')` 自动重连；toast 按落点措辞 |
| ④′ 冷启动也能重启 | `services/ConnectionOrchestrator.ets` | `restartIfConnected` 不再在 `lastNode === null` 时静默返回：用 `lastNodeName` 从当前订阅/内核影子反查节点；仍查不到才 warn 跳过 |
| ④″ 直连不开自动重启 | 同上 | `direct` 是运行期临时态（不落盘），重启会按磁盘值回到 `rule` → 直连热更新失败只如实报「内核未接受」，绝不重启 |
| ⑤ 卡片去掉分组数 | `commons/flclash/ProxyPanelMembers.ets` | `summary(nodes)` 只返回 `N 节点` 或空串；新增 `proxyCount()`；`nodeCountText()` 用 `proxyCount()` 判「内核还没加载」，空时卡片只显示更新时间 |

## 8. 「选小组后出口还是真实 IP」定案

真机日志（`files/diagnostics/app.log`）关键三行：

```
RuntimeConfigBuilder: runtime config built: … node="YF-美国-VLESS-WS-CF" group="默认代理" effective="YF-美国-VLESS-WS-CF"
ClashApiService: kernel selection: group="GLOBAL" now="DIRECT" nowIsLeaf=true members=9 leaves=7
ClashApiService: kernel selection: group="GLOBAL" now="YF-美国-VLESS-WS-CF" nowIsLeaf=true members=9 leaves=7
```

根因两条，缺一不成立：

1. **规则面那个组没人管**。规则是 `MATCH,PROXY`（全局模式是 `GLOBAL`），而面板只把
   **机场子组**（`默认代理 → 台湾手动`）钉住 → 隧道通了，但出站仍走 `PROXY`/`GLOBAL`，
   而它们的 `now` 可能是 `DIRECT`（上机日志第一行就是 `GLOBAL now=DIRECT`）。
2. **生成器把 PROXY 首位落到 `validNodes[0]`**。用户选的是**组名**，它不在 `validNodes`
   里 → `groupSelected = validNodes[0]`，很多机场第一个代理正好是 `直连` → 一启动就直连。
   界面读的是机场主组链路（`台湾01`），于是「显示小组节点、出口却是本地 IP」。

修法：

- `ClashConfigGenerator`：`settings.preferredNodeName` 命中已发射组名时，把**该组**放到
  `PROXY` 成员首位（日志 `PROXY primary member is a strategy group: …`）。
- `ConnectionOrchestrator.pinTrafficExit(groupName)`：把**流量真正走的组**
  （`kernelSelection.groupName()` = `GLOBAL` 或规则组）指向该组；内核不接受就退到该组
  链路里的真实叶子（`selectLeafFromKernelGroup`），再失败则 `selectNode()` 兜底。
- `selectPanelMember()` 在 `applied` 后调用它；失败时 toast 明说「内核未接受该分组，出口可能
  仍是直连」，不再假装成功。

## 9. 本轮门禁

- `hvigorw --mode module -p module=entry@default -p product=default clean assembleHap` → BUILD SUCCESSFUL
  （必须 clean：media 资源编号会漂）。
- `verify-proxy-panel-members` 17/17（含改后的「组行直接选中」用例）、`verify-logic-pure` 228/228、
  `verify-ui-resource-bindings` PASS、`verify-build-profile` 13/13。

## 10. 待用户自测

1. 面板里点「台湾手动」应**直接选中并回主页**，不再出现「上级：默认代理」。
2. 连接中切换：日志应出现 `traffic group "PROXY" now selects "台湾手动"`（或 `-> leaf`）。
3. 规则/全局切换：热更新成功 → 「已切换全局模式」；热更新失败 → 「正在重启代理以生效…」+ 自动重连。
4. 订阅卡片只显示 `更新时间 · N 节点`，不再出现「N 分组」。
