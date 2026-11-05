# 交接：订阅域 FlClash 全量照抄 · 四项待办完成（2026-11-05）

> 给接手 Agent。只写已核实事实；未验证的标「未验证」。

## 0. 一句话现状

四项待办（provider 交给内核 / profile 解析合并 / 节点准入 / 状态文案）**代码已全部落地，
门禁 94/95 绿**（唯一红是设计上必须私样本的 verify-subscription-fidelity），签名 HAP 已产出。
**只剩真机 A/B 未做**（无线调试端口未开，机主侧需重新开启并提供端口）。

## 1. 包与构建

| 项 | 值 |
|---|---|
| 签名 HAP | `C:\Worker\TunBox\dist\tunbox-flclash-fullport-20261105-signed.hap`（36,382,819 B） |
| 内核 | `entry/libs/arm64-v8a/libgojni.so` = 66,208,416 B（HAP 内同值；含 `TunBoxGetProfileBase`/`TunBoxDecodeYaml` 导出） |
| 分支 | `backup/pre-fullport-20261104`，工作区未提交（166 个路径，含上一轮取回层遗留改动） |
| 上轮快照 | `C:\Worker\_snapshots\TunBox-pre-fullport-20261104-214946.zip`（本轮改动前基线仍可用） |
| FlClash 参考 | `C:\Worker\REA\flclash_re\repo`（旧快照）+ upstream main（chen08209/FlClash，`core/profile_base.go` 才是真合并语义） |

**重要**：本地参考库的 FlClash 是旧版；真正的 `mergeProfileBase`（overlay 为根 + 三段接管 +
appendRules）与 `_makeRealProfileTask`（patch 链）在 **upstream main**。本轮语义全部对齐
upstream main（TunBox 旧 merger 头注释引用的就是它）。

## 2. 四项待办的落地形态

### 2.1 provider 交给内核拉（任务1）
- **删除**：SubscriptionService 的 provider App 侧拉取（`ProxyProviderParser` fetch 循环、
  `appendProviderNodes`、`parseProviderBody` 全删）；`ProfileOverrideStore` 之外无引用。
- **新增**：`TunBoxProfileBuilder.compose` 的 confineProviders（FlClash main 语义）：
  非 inline 且带 url 的 provider → `path = <profilesDir>/providers/<profileId>/<proxies|rules>/<md5(name@url)>`；
  file/inline 型不动（file 相对内核 HomeDir 解析，现状语义）。
- `global-ua` = `tunboxUserAgent()`（`<AppName>/v<version> clash-verge Platform/<os>`，FlClash
  packageInfo.ua 同款）→ mihomo 拉 provider 用这个 UA。**未验证**（需真机 + provider 订阅）。

### 2.2 profile 解析/合并按 FlClash 语义（任务2）
- **新链路**（`commons/tunbox/TunBoxProfileBuilder.ets`）：
  1. `coreBridge.getProfileBase(profilePath)` —— **内核用 mihomo 同一解析器**
     （`config.UnmarshalRawConfig`）读 profile 原文成 map（= FlClash `getConfig`）；
  2. overlay（ClashConfigGenerator 产物 = 本仓 patchClashConfig 等价物）经
     `coreBridge.decodeYaml` 解成 map（ArkTS 无 YAML 解析器，由内核同一 yaml 库承担
     FlClash Dart loadYaml 的角色）；
  3. FlClash main patch 链逐键落地：端口清零/keep-alive-interval=30/find-process-mode=off(ohos)/
     allow-lan=false/authentication=[]/tun 合成/profile.store-selected=false/
     sniffer ports 字符串化/geox-url 默认镜像/global-ua；
  4. JSON dump（JSON ⊂ YAML；mihomo `-t` 实测通过；等价 FlClash `_encodeYaml`）。
- **dns 语义（FlClash main 原样）**：profile dns 启用 → 订阅 dns **原样**（无「应用 DNS
  整段接管」模式；私有 proxy-server-nameserver 天然存活，2026-10-20 全超时修复由该行为
  天然满足）；订阅禁用 dns → 应用 DNS 按键覆盖 + nameserver 追加 `system://`。
  **`settings.dnsOverrideEnabled` 不再参与判断**（FlClash 无此模式；开关保留但无效）。
- **ProfileRepository.validateAndStore** = FlClash `Profile.saveFile` 同构：temp 文件 →
  内核校验 → **原文落盘**（不再 prepare 规范化/合成组后落盘）。
- **ProfileConfigMerger 瘦身**（1002→347 行）：merge/withSyntheticGroups/ensureGroupMember/
  injectSmartPrimary 等文本手术全删；只剩 enforceTunnelContract（非 profile 兜底路径用）+
  isKernelLoadableConfig + hasKey/sectionText/dnsFlowLines。
- 转换导出的「裸节点表补骨架」保留为 **导出链路专用**：`SubscriptionSection.withExportSkeleton`
  （文件级函数；仅用户产物，绝不进内核配置链）。

### 2.3 节点准入不做自有过滤/改名/推断（任务3）
- 删除 `isInfoEntry` 全部 6 处调用（SubscriptionService 水合/兜底/偏好重锚、
  SubscriptionParser 解析层、UriNodeParser URI 层、VpnQuickStart）——信息条目原样进内核。
- 删除 Go 侧 `PrepareProfile` 的合成组注入（手动选择/自动选择）。
- 删除 `ensureUniqueNames` 旧改名（此前已是 no-op）。
- 删除 `ensureGroupMember`（组成员注入）与 `resolvePinTarget` 的地区关键词自愈/
  首叶子替换/任意叶子兜底 —— 选点 = 内核成员表精确名（含归一化等价），选不到如实
  unmatched，由连接路径报错（FlClash selectedMap 语义）。
- **保留**（产品功能，非 FlClash 行为，已在代码注释标注）：smart 组注入（compose map 级，
  含**同名组防重守卫**——profile 已有 `♻️ 自动选择` 组时跳过，防内核重复名拒载）；
  隐藏节点台账（UI 显示过滤，不影响内核集合）。

### 2.4 状态文案按 FlClash badResponse 口径（任务4）
- SubscriptionService 刷新 catch：HTTP 错误（**含 429/403**）→ 「网络异常，请检查连接后重试」
  （FlClash `networkException`）；传输层/unknown → 原始错误文本（FlClash rethrow 语义）。
  RATE_LIMITED 状态分类保留（供批次统计），文案与 FlClash 逐字一致。
- 顺带删除了死代码：旧 @ohos.net.http 拉取路径（`requestWithRedirectValidation`/
  `responseEtag`/`headerValue`/`resolveRedirectUrl`/`redirectHeaders`）—— 取回层已 utls 单路径。

## 3. 内核（Go）改动

| 文件 | 内容 |
|---|---|
| `cshared_main.go` | +`TunBoxGetProfileBase(path)`（UnmarshalRawConfig → JSON map，`rule`→`rules` 改名，附 sha256/counts/matchRules）；+`TunBoxDecodeYaml(text)`（mihomo 同库 yaml→JSON map） |
| `config/profile_prepare.go` | 删合成组注入；只剩锚点展开 + 校验（App 预览解析用） |
| NAPI | `tunbox_core_napi.cpp`：`getProfileBase`/`decodeYaml` 绑定（复用 text→JSON worker）；`index.d.ts` + `CoreBridge.ets` 同步 |

## 4. 门禁状态（2026-11-05 03:00 实测）

| 门禁 | 结果 |
|---|---|
| verify-all.mjs | **94 PASS / 1 FAIL / 2 SKIP** |
| 唯一红 | `verify-subscription-fidelity.mjs` —— 设计上必须 `TUNBOX_SUBSCRIPTION_FIXTURE=<本地真实订阅.yaml>`；用合成 fixture 实测 91 项全绿（含「INFO 条目按普通节点解析」新契约） |
| verify-tunbox-profile | ALL PASSED（compose 真跑 + **真实 mihomo `-t` 接受 JSON 产物**） |
| verify-config-single-source | 70/0（native fixture 走新链路，mini-yaml 沙箱桥） |
| verify-profile-merge-providers | 6/0（重写为 compose provider 断言） |
| verify-mihomo-alignment | 93/0（第 7 段重写：无 If-None-Match = FlClash 无条件请求） |
| verify-smart-injection | 16/0（重写为 compose map 级 + 碰撞用例） |
| verify-smart-inject-unicode-names | 14/0（C 段改 compose unicode） |
| verify-startup-assets-runtime | 46/0（**真内核启动 profile-backed JSON 配置**） |
| verify-review-runtime / verify-node-selection-logic / verify-conversion-output-runtime / verify-sub-fetch-parity | 全绿（死行为断言删除/改写） |
| verify-arkts-compile | PASS（真编译 + assembleHap） |
| verify-build-profile | 13/13（签名配置已还原空数组） |
| 共享工具 | `scripts/fixtures/mini-yaml.mjs`（门禁用受控子集 YAML 解析/序列化） |

## 5. 真机 A/B（**未做**，被阻塞）

阻塞原因：`hdc tconn 192.168.3.146:39933` Connect failed；39933/5555/邻近端口 TCP 探测全关
——设备无线调试端口已轮换或关闭。**按仓库铁律「真机被机主占用需即停」，未继续扫端口语。**

机主侧操作后执行：
```powershell
# 1) 设备上打开 开发者选项 → 无线调试，读出新的 端口
hdc tconn 192.168.3.146:<新端口>
# 2) 安装
hdc -t 192.168.3.146:<端口> install -r C:\Worker\TunBox\dist\tunbox-flclash-fullport-20261105-signed.hap
# 3) 验证点（对照 FlClash 同订阅）：
#    a. 导入/刷新同一订阅 → app.log「subscription fetched via core」+ 节点集合与 FlClash 一致
#    b. provider 订阅：节点数应含 provider 成员（内核 /providers），无 App 侧预取日志
#    c. 断网点一次刷新 → 卡片文案 = 「网络异常，请检查连接后重试」（403/429 同文案）
#    d. 连接后内核配置文件（cacheDir 下）应为 JSON 形态；tun/mtu/dns 与 FlClash 行为同源
#    e. 「剩余流量」类条目应出现在节点列表（FlClash 行为，无过滤）
# 4) 设备日志: /data/app/el2/100/base/com.tunbox.client/haps/entry/files/diagnostics/app.log
```

## 6. 已知坑（本轮实际踩过/新增）

1. **JSON dump 会破坏文本合同**：VpnExtensionAbility 的 `  mtu:` 正则 / `dns.enable` 扫描 /
   `ipv6` 顶层布尔都按 YAML 文本读 —— 已改为 JSON 优先、YAML 回退
   （`tryParseConfigJson`/`patchConfigMtu`/`readTopLevelBoolAny`/`readDnsEnableAny`）。
2. **RawConfig.Rule 的 json tag 是 `rule`**（mihomo 上游怪癖）——GetProfileBase 导出里已改名
   `rules`，App 侧统一读 `rules`。
3. **枚举必须经 MarshalText**：TunnelMode/LogLevel/DNSMode/TUNStack/FindProcessMode 都有
   MarshalText → JSON 序列化为字符串，round-trip 保真（已逐一核实）。
4. **本 fork 的 inline provider 形状是 `payload: [map...]`**（upstream 是 payload 字符串）——
   门禁 fixture 踩过。
5. **ArkTS 严格模式**：`Array.isArray` 窄化出 any 要 `as Object[]`；结构化类型不可用
   （CoreProfileBase→TunBoxBaseData 需显式拷贝）；对象字面量必须带类型；无 delete 属性
   （用空串占位）；无 `?? {}`。
6. **Md5**：纯 ArkTS 实现（`TunBoxProfileBuilder.md5Hex`），已对拍 node crypto（含 UTF-8）。
7. **门禁的 fixture 沙箱**：harness `prepare.mjs` 的 FILES 必须登记每个新模块与每个新 import
   （TunBoxProfileBuilder/ProfileRepository 的 coreBridge 都补过）；`verify-credential-isolation`
   的手工桩不需新增（没有新 import）。
8. **git checkout 会洗掉未提交工作**：本轮曾误 checkout SubscriptionSection.ets，
   已从改前快照 zip 恢复（快照 = 工作树基线，115,901 字节，无一丢失）。
   **教训：worktree 有未提交改动时禁用 checkout 恢复，用快照 zip。**

## 7. 文件地图（本轮新增/重写）

| 作用 | 文件 |
|---|---|
| map 级构建器（核心） | `commons/tunbox/TunBoxProfileBuilder.ets`（build=薄异步壳，compose=纯函数） |
| 接线 | `commons/config/RuntimeConfigBuilder.ets`（profile 分支 + resolvePinTargetFromProfile） |
| profile 仓库 | `commons/tunbox/ProfileRepository.ets`（validateAndStore 原文落盘 + 内核校验） |
| 内核导出 | `mihomo-build/.../cshared_main.go`（GetProfileBase/DecodeYaml） |
| NAPI/桥 | `cpp/tunbox_core_napi.cpp`、`cpp/types/libtunbox_core_napi/index.d.ts`、`core/CoreBridge.ets` |
| 订阅服务 | `commons/services/SubscriptionService.ets`（provider 拉取/信息条目过滤删除、badResponse 文案） |
| VPN 层 | `ets/vpnability/VpnExtensionAbility.ets`（JSON 优先读配置） |
| 门禁 | `scripts/verify-{flclash-profile,profile-merge-providers,smart-injection,mihomo-alignment,...}` |
| 共享工具 | `scripts/fixtures/mini-yaml.mjs` |
