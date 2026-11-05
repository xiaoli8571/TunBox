# 交接：订阅域「全量照抄 FlClash」（2026-11-04）

> 给接手 Agent。只写已核实的事实；未验证的会标「未验证」。

## 0. 一句话现状

**取回层**已照抄 FlClash 并真机验证通过（原来 403 的订阅现在能拉下来）。
剩下 4 项仍是自造实现：**provider 交给内核 / profile 解析合并语义 / 节点准入 / 状态文案**。

## 1. 唯一工作目录（先确认改的是这里）

| 项 | 值 |
|---|---|
| 仓库根（git） | `C:\Worker\TunBox` |
| 工程 | `C:\Worker\TunBox\TunBox_HarmonyOS` |
| 分支 / HEAD | `backup/pre-fullport-20261104` / `2e0e161` |
| 工作区 | **未提交**（`TunBox_HarmonyOS/` 下约 118 个路径有改动） |
| 改前快照 | `C:\Worker\_snapshots\TunBox-pre-fullport-20261104-214946.zip` |
| FlClash 参考源 | `C:\Worker\REA\flclash_re\repo` |

**所有照抄代码都直接写在主线，没有旁支。** 2026-11-04 存在过的副本 `C:\Worker\TunBox-FL`
（无 `.git`）已按要求删除：全树 SHA256 比对 FL 498 文件 / 主线 515 文件、**FL 独有文件 = 0**，
且它的 `libgojni.so` 是 45,746,368 字节的截断档（用它启动必 SIGILL）。**不要恢复它。**

## 2. 已完成（含真机证据）

### 2.1 取回层 = FlClash 同构
- 单一 UA：`tunboxUserAgent()`（对应 `lib/common/package.dart` 的 `packageInfo.ua`）
- 删除 UA 链、删除传输层重试（FlClash `lib/common/request.dart` 失败即失败）
- 走内核 utls：`SubscriptionFetchPolicy` → `CoreBridge.fetchText` → NAPI `fetchText`
  → `cshared_main.go` 的 `TunBoxFetchText` → `bridge/fetch.go`（`utls.HelloChrome_Auto` + http2）
- 403 不再冒充「限流」：只有 429 进 `isRateLimited()`

**证据**
- 同 URL / 同 IP：PC `curl`(OpenSSL) 200 34,727B；Go 默认 TLS **403**；手机 `@ohos.net.http` **403**；utls-Chrome **200 34,727B**
- 真机 `app.log`：旧包 `HTTP 403` → 新包 `subscription fetched via core (31086 bytes)` / `(423326 bytes)`
- `libgojni.so` = 66,206,432 B，二进制内可检出 `TunBoxFetchText` 与 `github.com/metacubex/utls`

### 2.2 其它已落地
- 失败原因透传：`commons/services/ImportFailureSummary.ets`（导入/导出/刷新 catch 分支）
- 节点单一真源：`commons/tunbox/NodeTruth.ets`（已应用 profile 只读内核；预览 profile 隔离；组行取内核 `all` 直接成员）
- P1 页：`ProfileEditorPage.ets`（整份 YAML 编辑）、`ProfileOverrideStore.ets`（每 profile 覆盖，`RuntimeConfigProfile.overrideYaml`）、`DnsQueryPage.ets`（`/logs` DNS 视图）
- 测速超时 5000ms（FlClash `lib/common/constant.dart:50 httpTimeoutDuration = 5000`）

## 3. 待办（按这个顺序做，每项都要真机 A/B）

1. **provider 交给内核拉**
   现状：`SubscriptionService` 仍用 `ProxyProviderParser` 在 App 侧预拉/合并 provider。
   目标：App 只把 `proxy-providers` 原样写进 profile 文件，由 mihomo 按 `url/interval/health-check` 自己拉（FlClash 的 profile 就是这个语义）。
   落点：`SubscriptionService.ets`、`ProfileConfigMerger.ets`、`RawProxyYaml.ets`。
2. **profile 解析/合并按 FlClash 语义**
3. **节点准入不做自有过滤/改名/推断**
4. **状态文案按 FlClash `badResponse` 口径**

> 判定标准：同一台机器同时跑 FlClash 与 TunBox，同一条订阅要得到同样的节点集合与出口；
> 闸门全绿不等于对齐。

## 4. 构建 / 签名 / 安装

```powershell
# 1) 换本地签名 profile（仓库里的 build-profile.json5 必须保持 signingConfigs: []）
Copy-Item C:\Worker\TunBox\TunBox_HarmonyOS\build-profile.json5 <备份>
Copy-Item $env:USERPROFILE\.ohos\config\TunBox-build-profile.local-signing.json5 `
          C:\Worker\TunBox\TunBox_HarmonyOS\build-profile.json5

# 2) 构建
cd C:\Worker\TunBox\TunBox_HarmonyOS
hvigorw assembleHap --mode module -p product=default -p buildMode=debug

# 3) 立刻把签名配置还原成空数组，再跑门禁
Copy-Item <备份> C:\Worker\TunBox\TunBox_HarmonyOS\build-profile.json5
node scripts/verify-build-profile.mjs        # 必须 13/13 PASSED

# 4) 安装
hdc -t 192.168.3.146:39933 install -r C:\Worker\TunBox\dist\<你的包>.hap
```

设备日志：`/data/app/el2/100/base/com.tunbox.client/haps/entry/files/diagnostics/app.log`
订阅文件：`.../files/profiles/`；偏好：`.../preferences/tunbox_subscriptions`

## 5. 内核重建（只在改了 Go 侧代码时）

```powershell
cd C:\Worker\TunBox
powershell -File scripts\build-ohos-core.ps1     # 产出 entry/libs/arm64-v8a/libgojni.so
```
- 产物应约 66 MB；若明显小（如 45 MB）说明被截断，装上必 SIGILL。
- 改的是 `mihomo-build/mihomo-smart-462455136157a760937c666bba71afe33b1a809e/{bridge/fetch.go,cshared_main.go}`。
- NAPI 侧同步：`entry/src/main/cpp/tunbox_core_napi.cpp` + `types/libtunbox_core_napi/index.d.ts`。

## 6. 门禁

```powershell
cd C:\Worker\TunBox\TunBox_HarmonyOS
node scripts/verify-all.mjs        # 97 个脚本，跑完约 3-5 分钟，>30s 要放后台
```
与本次改动直接相关的：`verify-tunbox-profile`、`verify-config-generation-integrity`、
`verify-config-single-source`、`verify-credential-isolation`、`verify-latency-display`、
`verify-mihomo-alignment`、`verify-provider-node-visibility`、`verify-build-profile`。

## 7. 已知坑（都实际踩过）

1. **新增 ArkTS 模块被 harness 覆盖** → 必须登记到 `tools/true-chain-harness/prepare.mjs` 的 `FILES`
   并在使用方的 `map` 里加一行，否则 prepare `exit(2)`，`verify-tunbox-profile` / `verify-config-*` 连锁红。
   （`ProfileOverrideStore` 就是这么补的。）
2. **`verify-credential-isolation.mjs` 是手工搬运**：`SubscriptionService` 新增 import 要在这里补桩，否则 `ERR_MODULE_NOT_FOUND`。
3. **两个测速超时不许混改**：`TunBoxDelay.ets` 的 `TUNBOX_DELAY_TIMEOUT_MS = 5000`（FlClash 口径）vs
   `LatencyKinds.ets` 的 `LatencyPolicy.DEFAULT_TIMEOUT_MS = 3000`（旧 LatencyEngine 链路）。
4. **`libgojni.so` 只能用源码重建**，从旧 HAP 里回拷会 ILL_ILLOPC。
5. **提交门禁**：`build-profile.json5` 含签名路径时 pre-commit 直接拒绝；仓库根 `*.md`、`*.log`、`dist/` 也会被拦。

## 8. 关键文件地图

| 作用 | 文件 |
|---|---|
| 取回策略（UA/utls/状态码） | `commons/services/SubscriptionFetchPolicy.ets` |
| 内核取回桥 | `core/CoreBridge.ets` / `cpp/tunbox_core_napi.cpp` / `mihomo-build/.../bridge/fetch.go` |
| 订阅装配 | `commons/services/SubscriptionService.ets` |
| profile 存储与合并 | `commons/tunbox/{ProfileRepository,ProfileConfigMerger,ProfileOverrideStore}.ets` |
| 节点真源 | `commons/tunbox/NodeTruth.ets` |
| 测速 | `commons/tunbox/TunBoxDelay.ets` |
| UI | `components/SubscriptionSection.ets`、`pages/{NodeSelectionPage,ProfileEditorPage,DnsQueryPage}.ets` |
