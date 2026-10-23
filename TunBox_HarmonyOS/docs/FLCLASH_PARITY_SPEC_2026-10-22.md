# FlClash 1:1 复刻契约：订阅解析 + 节点测速（2026-10-22）

来源：`C:\Users\Administrator\AppData\Local\hermes\cache\scratch\ref\flclash`（chen08209/FlClash main 分支 tarball）。
所有条目都对应源码位置，改实现前先对照；**任何偏离都要在这里写明原因，否则视为 bug**。

---

## 一、订阅解析（Profile）

### 1.1 拉取

| 项 | FlClash | 源码 |
|---|---|---|
| 超时 | 20s（`downloadTimeoutDuration`） | `lib/common/constant.dart:64` |
| UA | `<AppName>/v<version> clash-verge Platform/<os>`，可被配置项 `global-ua` 覆盖 | `lib/common/package.dart:8`、`lib/state.dart:44` |
| 下载 | `GET`，`ResponseType.bytes`，**不做** gzip 头判断但要 `decompressUnlabeled` | `lib/common/request.dart:43-74`、`lib/models/profile.dart:196` |
| URL 内嵌凭据 | `user:pass@host` → 抽成 `Authorization: Basic base64(user:pass)` 并从 URL 去掉 userinfo | `lib/common/request.dart:152-170` |
| 失败处理 | 抛异常，profile 不落盘（旧文件保留） | `lib/models/profile.dart:185-215` |
| 走代理 | 通过 FlClash 自己的 http overrides（当前运行内核）下载 | `lib/common/request.dart:31` |

### 1.2 落盘与校验（关键：App 侧**不解析节点**）

`Profile.saveFile`：写临时文件 → `validate(path)` → 通过才 `copy` 成正式 `<id>.yaml`
（`lib/models/profile.dart:201-216`）

`CoreController.validateProfile`（`lib/core/controller.dart:101-127`）语义：

1. 若文件是 age 加密 → 解密后原地重写（TunBox 无此功能，跳过）。
2. `validateConfig(path)` = Go `handleValidateConfig` → `unmarshalRawConfig`（YAML → RawConfig）。成功 ⇒ 返回空串，**文件内容一字不改**。
3. 失败 ⇒ 调 `convertProxies(path)`（Go：`convert.ConvertsV2Ray(buf)`）：
   - `DecodeBase64(buf)`：先试 RawStd、再试 Std 解码；失败则当明文。
   - 按 `\n` 切行，`TrimRight(" \r")`，找第一个 `://`，scheme 小写后分发。
   - 支持：`hysteria` `hysteria2/hy2/hysteria2+realm/hy2+realm` `tuic` `trojan` `vless` `vmess` `ss` `ssr` `socks/socks5/socks5h/http/https` `anytls` `mierus`。
   - 重名规则 `uniqueName`：首次 `name` 原样，第二次 `name-02`、第三次 `name-03`（`-` + 两位数字）。
   - 一个都转不出来 ⇒ 返回错误（文案 `convert v2ray subscribe error: format invalid`）。
4. 转换成功且非空 ⇒ **把文件重写成** `proxies:\n  - {…}`（`encodeYamlTask({'proxies': proxies})`）→ 再 `validateConfig` 一次，结果就是最终返回。
5. 转换失败 ⇒ 把第一步的校验错误文案返回给用户。

⇒ **FlClash 从不把节点解析进 App 侧数据库**；节点永远由内核解析，App 只读内核。

### 1.3 元数据

- 标签：`content-disposition` 的 `filename*`（RFC 5987）→ `filename` → 最终回落 `url.host` → `id`。
  （`lib/common/request.dart:174-200`、`lib/models/profile.dart:141-143`）
- 流量/到期：`subscription-userinfo` 头，格式 `upload=1; download=2; total=3; expire=4`，分号分段、`key=value`、值可为小数（截断取整）；键名小写。缺失字段为 0。
  （`lib/models/profile.dart:28-53`）
- 更新时间：保存成功即 `lastUpdateDate = now`。
- 自动更新：`autoUpdate && type==url`，间隔 `defaultUpdateDuration = 1 天`；到期判断 `lastUpdateDate + duration`，过期为真才更新。
  （`lib/providers/actions/profiles.dart:42-60`、`lib/common/constant.dart:88`）

### 1.4 多订阅

- 每个 Profile 是一份独立配置，`currentProfileId` 只有一个；**从不合并**。
- 切 profile → `applyProfileDebounce(silence: true)`（重载内核配置）。

---

## 二、运行配置的生成（overlay 模型）

`mergeProfileBase`（`core/profile_base.go:120-155`）：

- 以 **overlay**（App 生成的运行配置）为根文档；
- 从 profile 原文取 `proxies`、`proxy-groups`、`sub-rules` 三段**整体替换**进根文档；
- `rules` = overlay.rules **在前** + profile.rules **在后**；
- 未列出的键以 overlay 为准（profile 的 tun/dns/ports 等被覆盖）。

App 侧 overlay 在 `lib/common/task.dart:115-300`，关键键（按源码逐条）：

```
external-controller / secret / external-controller-tls='' / -unix='' / -pipe=''
external-ui='' / external-ui-url=''
interface-name（按模式）
tcp-concurrent / unified-delay / ipv6 / log-level
port / socks-port / redir-port / tproxy-port / mixed-port
keep-alive-interval / keep-alive-idle / disable-keep-alive / routing-mark
find-process-mode / allow-lan / authentication / skip-auth-prefixes=[]
mode
tun{...原配置合并, dns-hijack, ...} + auto-detect-interface: true
geodata-loader / geo-auto-update / geo-update-interval
sniffer（有 override 才合并）
profile.store-selected = false
geox-url / global-ua / hosts
dns: 原文 dns.enable==true → 保留原文 dns；否则合并 baselineDns 后再合并用户 override
ntp / 其它 overrides
```

**DNS 语义（重要）**：`isEnableDns = rawDns['enable'] == true`；未启用才注入 baseline。
⇒ 订阅自带 DNS 时原样使用（这正是 TunBox 多订阅 DNS 互染问题的正解）。

---

## 三、节点/分组目录

- App 侧不持有节点清单；组/节点都从内核读（`handleGetProxies`，`core/proxy.go:84-110`）。
- 组类型判定：`Selector / URLTest / Fallback / Relay / LoadBalance`（`core/proxy.go:51-60`）。
- 内置 `GLOBAL` 组（来自保留 provider）标记 `hidden`（`core/proxy.go:132-142`）。
- 每个节点：`name`、`type`（非组只给这两项）；组额外给 `all`、`now`、`url`、`history` 等（mihomo MarshalJSON）。
- 选择：`changeProxy(group, proxy)`（`core/proxy.go:161-180`），写入后 `refreshRouteLocked`；Dart 侧 `changeProxy` 后再 `resetConnections/closeConnections`（`lib/providers/actions/proxies.dart:177-221`）。
- `patchSelectGroup`: 应用配置后按 `selectedMap` 逐组 `ForceSet`（`core/proxy.go:182-190`）。

---

## 四、节点测速（严格参数）

### 4.1 内核侧（`core/delay.go`）

```
delayTestConcurrency = 50          // 核内槽位，acquireWithin(ctx, timeout) 排队，排不到返回 nil
defaultTestURL = "https://www.gstatic.com/generate_204"
defaultDelayTestTimeout = 5s
delayTimedOut = -1                 // ctx.Err() != nil
delayFailed   = -2                 // 拨号/请求失败
delayValue: delay>0 → delay；timedOut → -1；否则 → -2
proxy 不存在 → 直接 -2 + 每秒一条日志 "delay test: %q is not part of the applied config"
URLTest(ctx, url, expectedStatus=204)
```

### 4.2 客户端侧（`lib/providers/actions/proxies.dart`）

```
maxConcurrentDelayTests = 32       // TaskPool
delayTestGuardDuration = 30s       // coreGuard
renderThrottleDuration = 300ms     // 结果合批刷新 UI
```

- 目标解析 `_resolveDelayTestTargets`：
  - 每个节点先 `computeRealSelectedProxyState`（节点若在组的链上是子组，则测**实际出口名**）；
  - **测速 URL 优先用该节点所在组配置的 `url`**，没有才回落全局 `testUrl`；
  - 去重键 `delayTestKey(url, proxyName)`。
- 并发：`TaskPool(32)`，逐节点 `getDelay(url, proxyName)`；`null` 结果 = 没排到槽，**不写结论**。
- 失败：`CoreMethodException.isCoreUnavailable` ⇒ 整个 job `cancelled`（后续任务直接 return）。
- 组测速 = 组内**所有节点逐个测**（`delayTest(groups.all)`），不是 `/group/{name}/delay`。
- 取消：内核状态非 connected 时 `cancelDelayTests()`（清空缓冲与 pending），不会反向写节点结论。

### 4.3 展示

- `delay > 0` → `"$delay ms"`；`-1` → 本地化 "超时"；其它负值 → "失败"；`null` → 不显示（`lib/common/app_localizations.dart:111`、`lib/views/dashboard/widgets/proxy_groups.dart:113-121`）。
- 颜色：`delay < 0 → error`；`< 600 → success`；`>= 600 → warning`（`lib/ui/color.dart:333-339`）。
- 排序 `DelayState.priority`：`>0 → 0`，`==0 → 1`，`==-1 → 2`，其它 → 3；同优先级按值升序，组优先于节点（`lib/models/common.dart:957-975`）。
- 「隐藏超时节点」开关：`hideTimeoutProxies`（默认关），按**上一批**结果计算（`delaysAtLastTestBatch`）。

### 4.4 FlClash **没有**的行为（TunBox 现有实现必须去掉）

- 没有离线 TCP/TLS 探活通道，没有 DNS 预解析判定，没有 core_not_ready 连击作废，没有批次硬截止，没有「5 分钟新鲜度跳过」。
- 没有 `/group/{name}/delay` 组测速。
- 没有后台静默自动测速（只在用户操作/托盘/快捷键时测）。
- 测速结果只在内存（`delayDataSourceProvider`），**不落盘**；切换 profile 时清空（`lib/providers/actions/setup.dart:78`）。

---

## 五、TunBox 侧映射（平台差异，不算偏离）

| FlClash | TunBox | 原因 |
|---|---|---|
| core IPC `getDelay` | REST `GET /proxies/{name}/delay?url&timeout` | 内核相同函数 `proxy.URLTest`，REST 只是入口 |
| 核内 50 槽排队 | 客户端 32 并发（32 < 50，等价） | REST 无槽位；32 已在客户端限流 |
| `convertProxies` in Go | ArkTS 移植 `ConvertsV2Ray` | 端侧无 Go 运行时 |
| profile 原文作为 base | 原文文本切片内联进主配置 | 设备侧 provider 有两个 home 目录问题（见 skill） |
| `core.getProxiesGroups` | REST `/proxies` | 同一份内核数据 |
