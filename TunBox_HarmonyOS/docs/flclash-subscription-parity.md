# 订阅链路 vs FlClash：逐环节对照（2026-10-22）

> 目的：回答「订阅解析还有哪些地方跟 FlClash 不一样」。逐环节列 FlClash 的**实际实现**
> （带源码位置）与 TunBox 现状，并标明是「已对齐」「有意的产品差异」还是「平台限制做不到」。
>
> FlClash 源码位置说明：`flclash-dart/` 只有 14 个扁平副本（`lib__xxx__yyy.dart`），
> 完整快照在 `_archive\TunBox-Windows-flclash-2026-10-21\lib\`，两者内容一致。

## 0. 一句话结论

订阅链路上「**谁解析节点、谁决定节点能不能用**」已经与 FlClash 一致：App 只搬运字节与
元数据，节点表/可用性/测速目标全部来自内核。剩下 3 处差异**不在解析层**：UA 内容协商、
单链接转换（需要内核 encode API）、profile 预校验（需要内核 `-t` 或 `validateConfig`）。

## 1. 逐环节对照

| # | 环节 | FlClash 行为（证据） | TunBox 现状 | 结论 |
| --- | --- | --- | --- | --- |
| 1 | 下载通道 | `dio` + `findProxy`：内核在跑就**走内核代理**（`lib/common/request.dart:27-41`） | `usingProxy: AppProxyRoute.activePort() > 0`，隧道连接时走本地 mixed 端口（`SubscriptionFetchPolicy.ets:411`） | ✅ 已对齐 |
| 2 | UA | 默认 = 配置 `global-ua`，为空则用**自身 App UA**（`lib/state.dart:44-46`；`lib/models/config.dart:33` 的两个 clash 系 UA 只是下拉候选） | 固定 UA 链，首个 `clash-verge/v2.4.2`（`SubscriptionFetchPolicy.ets:60-66`） | ⚠️ 有意的产品差异：真机实测 `TunBox/<version>` UA 会让部分面板回 400，clash-verge UA 才能拿到完整 Clash 字段；换 UA 会改变面板返回内容，不属于解析 |
| 3 | 超时/重试 | 单次请求，总超时 20s（`lib/common/constant.dart:62`） | connect 15s + read 20s；传输层失败按时间预算重试（`SubscriptionFetchPolicy.ets:36-38`） | ⚠️ TunBox 更宽容（重试只为绕过概率性问题），不影响解析正确性 |
| 4 | 响应体解码 | 魔数识别**未声明 Content-Encoding** 的 gzip/zlib 并解压（`lib/common/request.dart:132-148`） | **本次新增**：`HttpBodyCodec`（纯 TS inflate + gzip/zlib 包装），`SubscriptionFetchPolicy` 在 UTF-8 解码前调用 | ✅ 本次对齐 |
| 5 | 基本鉴权 | URL 里的 `user:pass@` 剥出来转 `Authorization: Basic`（`lib/common/request.dart:150-165`） | **本次新增**：`authTarget()`；跨主机重定向不转发 Authorization | ✅ 本次对齐 |
| 6 | 订阅元数据 | 只取 `subscription-userinfo`（流量/到期）与 `content-disposition`（标题）（`lib/models/profile.dart:186-198`） | `subscription-userinfo` 早已解析；**本次新增** `content-disposition` → 订阅名（默认名时） | ✅ 本次对齐 |
| 7 | 落盘 | 原始字节写临时文件 → 校验 → 原子替换；**从不解析** `proxies`（`lib/models/profile.dart:201-216`） | 原始文本落 profile 文件（`ProfileStore.write`），`proxies` 段由 `ProfileConfigMerger` 整段透传给内核 | ✅ 已对齐（TunBox 多存了一份凭据用于节点编辑/备份，属额外功能，不参与判词） |
| 8 | 保存前校验 | **内核** `validateConfig`（Go `config.UnmarshalRawConfig`），失败保留旧文件（`lib/core/profile_base.go:74-77`） | App 侧文本启发式 `ProfileConfigMerger.isKernelLoadableConfig` + 非 YAML 时转链接列表（`ProfileStore.validateAndStore`） | ❌ 平台限制：设备侧内核只有 controller 通道、**没有 `-t` / validate API**；TunBox 用「生成配置→启动内核→失败回滚」兜底，但无法在**保存前**问内核 |
| 9 | 覆盖合并 | `mergeProfileBase`：`proxies` / `proxy-groups` / `sub-rules` 三段整段覆盖，其它键用 App 生成（`lib/core/profile_base.go:120-160`；`lib/common/task.dart:115-378`） | `ProfileConfigMerger.merge`：同三段 + dns/hosts/providers 透传（平台差异） | ✅ 本质相同（TunBox 多透传 dns/providers，是产品功能） |
| 10 | 节点表来源 | 内核 IPC `getProxiesGroups` → Go `tunnel.AllProxies()`；Dart 的 `Proxy` 只有 name/type/now（`lib/providers/actions/proxies.dart:129`；`lib/models/clash_config.dart:225-233`；`core/proxy.go:85-101`） | **当前订阅**：内核 REST `GET /proxies` → `CoreCatalogService` → 页面节点表（与内核三重一致才用，切换中回落 App 表）；**其它订阅**：App 解析表预览（FlClash 根本没有"别的 profile 的节点列表"这个概念） | ✅ 当前订阅对齐；别订阅列表属产品差异（用户要求节点必须立刻可见，不接受"切换后由内核提供"的占位提示） |
| 11 | 节点判词（能不能用） | **没有**字段级 required 校验；只有空名/重名/引用/环路/`coreRejected`（`lib/models/clash_config.dart:787-826`） | 2026-10-22 已删除 YAML 路径的「定义不完整」判词（`YamlNodeAdapter.plan` 不再产出 excluded/reason） | ✅ 已对齐 |
| 12 | 测速 | 按**名字**测内核里的节点：`getDelay(url, proxyName)` → `lookupProxy(name).URLTest()`（`core/delay.go:73-99`） | `GET /proxies/{name}/delay`（`FlclashLatencyService`），目标来自内核目录 | ✅ 已对齐 |
| 13 | 节点计数 | 内核 counts（`base.proxies`）或对 profile 文件 `loadYaml` 数段（`lib/providers/actions/setup.dart:513-517`；`lib/views/profiles/profile_detail.dart:76`） | 当前订阅 = 内核目录数量；其它订阅 = App 解析表长度（与展开区列表一致，避免"N 个节点"和实际卡片数对不上）；`sub.nodeCount` 另存原文条目数，按 FlClash 口径兜底 | ✅ 当前订阅对齐；`sub.nodeCount` 的口径已改成原文条目数（远程刷新/本地导入/本地伪订阅三条路径） |
| 14 | 节点命名 | 内核原文名；App 不重命名（`additional-prefix` 由内核加） | `ensureUniqueNames()` 已改成 no-op（2026-10-22）；名字一律以内核为准 | ✅ 已对齐 |
| 15 | 单链接（分享链接导入） | 链接列表交给**内核** `encodeYamlTask` 转成 proxies（`lib/core/controller.dart` 的 validateProfile 分支） | App 自己解析（`UriNodeParser`）后写进生成配置 | ❌ 平台限制：TunBox 内核桥没有 encode API；这条链路没有「内核另有一份原文」可对照，App 解析是唯一途径（且无 UI 判词） |
| 16 | providers | 内核自取；App 只显示内核给的 provider 状态（`core/provider.go`） | profile 里的 provider 段透传给内核，内核自取 | ✅ 等价 |

## 2. 本次实际改动（对应上表 #4/#5/#6/#10/#13）

1. **响应体解码**：新增 `entry/src/main/ets/commons/subscription/HttpBodyCodec.ets`
   （纯 TS inflate + gzip/zlib 包装，CRC32/Adler-32/ISIZE 校验，16 MiB 上限），
   `SubscriptionFetchPolicy` 在 UTF-8 解码前按魔数解压；损坏的压缩流直接报「解压失败」，
   不再把乱码当成「不是 Clash 订阅」。
2. **Basic 鉴权**：`SubscriptionFetchPolicy.authTarget()` 剥 URL userinfo + 生成
   `Authorization: Basic`；重定向跨主机时丢弃该头。同时修了一个连带问题：
   ArkTS 的 `URL.host` 把 `user:pass@` 算进 host，`redactUrl()` 直接打印会把凭据写进
   日志/诊断 —— 现在先剥 userinfo 再脱敏（闸门 `verify-sub-fetch-parity.mjs` 断言这一点）。
3. **订阅标题**：`SubscriptionFetchPolicy.fileNameFromDisposition()`（`filename*` 优先，
   其次 `filename`）→ `SubscriptionService` 在订阅仍是默认名时用它命名。
4. **节点表与计数**：
   - 当前订阅：节点表/计数都来自内核目录（切换过程中三重一致才用，否则回落 App 表；
     宁可显示旧数据也不把上一份订阅的节点画进来）。
   - 其它订阅：FlClash 没有"别的 profile 的节点列表"这种东西，所以这里没有可对齐的对象；
     为不让节点列表消失、也为了不被"切换后才有列表"的占位提示挡住，**保留 App 解析表的
     预览**（2026-10-22 用户明确要求去掉占位提示、节点要立刻可见）。
   - `sub.nodeCount`（远程刷新 / 本地导入 / 本地伪订阅三条路径）改成**原文 proxies 条目数**，
     与 FlClash 的 profile 计数同口径；页面上的"N 个节点"仍与展开区实际列表一致。

## 3. 闸门

- `node scripts/verify-http-body-codec.mjs`：gzip/zlib 与 `node:zlib` 逐字节对拍
  （含 stored/fixed/dynamic 块、中文、1 MiB 样本、损坏流必须抛错），`--self-test` 负对照。
- `node scripts/verify-sub-parse-fidelity.mjs`：YAML 路径「无判词、全部保留」断言。
- `node scripts/verify-arkts-compile.mjs`：整体编译 + assembleHap。

## 4. 已知、明确不做的差异

- **UA 内容协商**（#2）：改 UA 会改变面板返回的节点集合；真机实测 TunBox 自身 UA 会被
  部分面板 400。这是「拉取层」差异，不是解析层。
- **保存前内核校验**（#8）：内核桥没有 validate 接口。
- **单链接下沉内核**（#15）：内核桥没有 encode 接口；要做必须先给 core 加 NAPI。

这三项要动，需要改内核桥（C++/Go 侧）或产品口径，属于单独决策，不在本次「解析对齐」范围。
