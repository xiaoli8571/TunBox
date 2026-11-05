# 失败原因透传与本地导入准确性（2026-11-04）

范围：只改**逻辑层与提示文案**，不动 UI 结构/配色、不动 mihomo-smart 内核、不动保活策略。
本批处理的正是用户反复报的「订阅解析失败 / 导入失败 / 测速失败」里**唯一可确定的一类**：
判词已经算出来了，但没有到达用户。

## 1. 事实与根因

核对当前工作树后，以下四个分支把真实原因丢掉了：

| 位置 | 旧行为 | 后果 |
|---|---|---|
| `importYamlFile` catch | 固定弹 `导入失败，请重试` | 校验失败原因（"已保留旧配置：…"）、picker/文件读写 `BusinessError.code` 全部丢失 |
| `importFromConvert` catch | 固定弹 `转换或导入失败，请重试` | 同上；导出失败也不说是内容问题还是保存位置问题 |
| `refreshOne` 失败分支 | 只弹 `刷新失败：<订阅名>` | `result.message`（空响应字节数 / 校验判词 / HTTP 状态码）与 `result.advice` 都不展示 |
| `refreshAll` 结束 | **无条件**弹 `✓ 全部订阅已刷新` | 即使每条都失败也报成功 |

另有三个本地导入的准确性问题：

- 文件选择器只列 `.yaml/.yml`：机场/转换站常见的 `.txt` / `.conf` / 大写 `.YAML` 在选择器里点不到，
  用户看到的是「导入不了」，而内容其实完全合法（本仓口径是**判内容不判链接**）。
- 文件名直接截 URI 最后一段：`%E4%B8%AD%E6%96%87.yaml` 会原样显示成订阅名。
- `addLocalYaml` 的返回值契约是「是否导入成功」（provider-only 也算成功，`Math.max(…, 1)`），
  页面却把它当节点数，于是 provider-only 配置被报成「解析出 1 个节点」。

## 2. 改动

1. 新增 `commons/services/ImportFailureSummary.ets`（纯函数、无 kit 依赖）：
   空白归一 → 限长 88 字加 `…` → 统一拼 `<前缀>｜<原因>`；无原因时不留孤零零的分隔符。
2. 三个入口统一改用它，原因必须到达用户：`导入失败｜…` / `导出失败｜…` / `刷新失败：<名>｜…`；
   日志里也统一先取 `reason` 再打印（避免同一条错误取两次）。
3. `refreshAll` 按失败集合给出真实统计：全成功仍旧 `✓ 全部订阅已刷新`，
   否则 `刷新完成：X 成功，Y 失败`。集合由单条刷新维护（成功移除、失败加入），跨轮自然收敛。
4. 本地导入两处修正：文件名 `decodeURIComponent`（原来是 `%E4%B8%AD%E6%96%87.yaml`）；
   节点数改用新增的 `SubscriptionService.lastLocalImportNodes`，
   provider-only 走「配置已导入 TunBox，节点将在加载订阅后显示」。

> 撤回一项：本轮曾把选择器扩展名放宽到 `.yaml/.yml/.txt/.conf`，
> 被 `verify-vpn-architecture.mjs` 的 `subs.file-yaml-only` 契约拦下 —— 该契约与
> 「订阅入口只支持 Clash」是同一组已定案口径，属**产品决策**，不在本轮范围。
> 已恢复 `['.yaml', '.yml']`，并在新闸门里加了 `wire.picker-stays-yaml-only` 防误删。

**没有改**：Clash-only 订阅定案（`isClashBody` + `NON_CLASH_ADVICE` 原样保留）、
3 s 单节点预算、32 并发、DNS 接管、内核与保活。

## 3. 门禁

- 新增 `scripts/verify-import-diagnostics.mjs`：21 条。执行生产 `ImportFailureSummary` 的 7 条行为断言
  （空白归一 / 88 字边界 / 89 字截断 / 无原因不留分隔符 / 换行折叠），
  加 12 条接线断言（三入口引用、通用文案消失、refreshAll 真实统计、文件名/节点数、
  选择器保持 YAML-only、以及**负对照**：Clash-only 守卫与建议文案仍在）。
- 更新 `scripts/verify-concurrent-refresh.mjs`：旧断言把 `刷新失败：${sub.name}` 钉成契约，
  等于把「原因被吞掉」固化；改为「失败分支必须携带 `result.message || result.advice`」，
  并新增 `wire.subPage.refreshAllHonest`。114 条全过。
- `scripts/verify-conversion-output-runtime.mjs` 沙箱补载新模块，14 场景 + 真实内核校验全过。

执行结果：

```text
verify-import-diagnostics.mjs        21 passed, 0 failed
verify-concurrent-refresh.mjs        114 条通过，0 条失败
verify-conversion-output-runtime.mjs 14 场景 + 真实 mihomo YAML 校验 全过
verify-vpn-architecture.mjs          PASS（含 subs.clash-only-guard / latency.* 契约）
verify-types.mjs                     TYPE/SYNTAX CHECK PASSED
verify-sub-parse-fidelity.mjs        727 passed, 0 failed（改动前基线）
```

## 4. 构建阻塞：工作区内核被截断（已修）

首次 `clean assembleHap` 在链接期失败，**与本轮代码无关**：

```text
ld.lld: error: entry/libs/arm64-v8a/libgojni.so:
  section header table goes past the end of the file: e_shoff = 0x3efca00
```

- 工作区文件：45,746,368 B（被截断）。
- 该 ELF 头声明 `e_shoff=66,046,336`、`e_shentsize=64`、`e_shnum=29` → 应有 66,048,192 B。
- `dist/TunBox-0.8.2-561-device-signed.hap` 内的 `libs/arm64-v8a/libgojni.so` 正是 66,048,192 B，
  且段表末尾恰好等于文件长度（结构完整）。
- 处理：从该**已发布、真机签名的 0.8.2 HAP** 还原同一份二进制，未重编内核、未改任何内核源码；
  `entry/libs/arm64-v8a/libgojni.sha256` 同步更新为实际字节的
  `078C803C9B0119D08312FE44999E51B93248215BAB4EE8259ADBBD821CCDA308`。

⚠ 需要用户确认的**既有不一致**：`THIRD_PARTY_NOTICES.md` 记录的内核产物是
62.9MB / 66,012,000 B / SHA-256 `DB5A3181…B59F94AD`，与 0.8.2 实发 HAP 内的
66,048,192 B / `078C803C…` 不是同一份构建。本文不擅自改许可证声明，
若要回归 `DB5A3181` 那份，请用 `scripts/build-ohos-core.ps1` 重新产出并同步声明。

## 5. 构建与产物

```text
hvigorw.bat --mode module -p module=entry@default -p product=default clean assembleHap --no-daemon
BUILD SUCCESSFUL in 54 s 758 ms（34 tasks，33 executed）
entry-default-unsigned.hap  30,682,668 B
SHA-256 7545C80DE21D74350A0D2C8393BBCA586C4858DDADA5440003C045B58F3FA2F5
verify-ui-resource-bindings.mjs 4/4 PASS（主页/数据/设置/电源）
```

未签名、未安装、未上传；真机验证仍需用户执行。
