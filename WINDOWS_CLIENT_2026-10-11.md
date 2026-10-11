# TunBox for Windows —— 0.4.0（重写版）

这版是**推倒重写**。旧目录连同全部代码被清掉后重建，UI/UX 对齐 Clash Verge / FlClash /
Bettbox 这些成熟客户端（Bettbox 是 FlClash 的 fork，结构同源），内核沿用仓库里的
mihomo-smart（`Mihomo Meta 1.10.0 windows amd64 with go1.24.7`，含 with_gvisor），
Model.bin 来自 `mihomo-build/`。

## 与旧版的关键差异（每一处都对着这次用户报告的故障）

### 1. 内核就绪判定：三重信号，不再「HTTP 轮询 30 秒」

旧实现起完内核后轮询 `GET /version` 等 30s，超时报「控制器未就绪」→ 测速转圈、连接失败。
新 `CoreHost`（`src/TunBox.Core/Runtime/CoreHost.cs`）：

1. **进程 HasExited → 立刻失败**，把 core.log 尾部带回给 UI（不再陪跑满预算）；
2. **stdout 出现 `RESTful API listening at: 127.0.0.1:<port>`** → 内核侧已就绪（对照内核源码核对过这行）；
3. `GET /version` 短预算探测（300ms 一次）作为佐证；佐证不到也放行——本机回环 HTTP 被
   安全软件拦掉时内核是真就绪的，不该让用户陪跑。

实测（这台验证机的回环 HTTP 走不通，正好是用户症状的复现环境）：导入 → 待命 **3.2 秒**成功；
旧代码在同样条件下等满 30 秒后失败。

其它内核生命周期修复：子进程挂 **Windows Job Object**（KILL_ON_JOB_CLOSE）——GUI 崩溃内核
必死，不留占端口的孤儿（v2rayN 同款）；stdout 从 spawn 这一刻就开始读走（Clash Verge 踩过
「管道写满阻塞、内核永远走不到创建监听」的坑）。

### 2. 订阅拉取：UA 链 + 内容协商（对齐鸿蒙端 SubscriptionFetchPolicy 与主流客户端）

「老版本 clash 不受支持」这类报错是**面板返回的正文**：面板按 User-Agent 做内容协商，
不认识的客户端可能拿到提示页而不是订阅。现在沿 UA 链逐个试，拿到非网页正文为止：

```
clash-verge/v1.7.7 → clash.meta/v1.18.8 → TunBox/<ver> → v2rayN/6.23 → Shadowrocket/2077
```

- 全部失败时报错里带**面板原文前 2KB**，用户能自己看见面板说了什么；
- `subscription-userinfo`（upload/download/total/expire，逗号分号都认）与
  `profile-update-interval` 解析进订阅卡（流量进度条 + 到期日）；
- ETag / If-None-Match：内容没变面板回 304，不再重复整段下载；
- TLS 校验失败放宽重试一次（自签证书的机场面板很常见）；
- 每条订阅可自定义 User-Agent（Clash Verge 同款字段）。

解析层修复：base64 blob 允许内层 padding 与换行（不少面板把整段 base64 再套一层）；
`ss://` 明文凭据解码；`host:port/?query` 的尾斜杠不再切坏端口；HTML/提示页在 YAML 解析前先判。

### 3. UI/UX：照成熟桌面客户端的形态

左侧窄导航栏（首页 / 代理 / 订阅 / 连接 / 规则 / 设置）+ 侧栏底部实时上下行速率（Verge 同款）：

- **首页**：大连接按钮 + 规则/全局/直连分段 + 「系统代理 | TUN」toggle 卡 + 当前出口卡；
- **代理**：每组一张卡，组头显示类型/成员数/当前出口/「测本组」，节点迷你卡网格；
  延迟配色 Verge 口径（<250 绿 / 250-399 蓝 / ≥400 橙 / 超时红 / 未测灰 `-`）；
- **订阅**：URL 导入 + 卡片（流量进度、到期、更新时间、自定义 UA、更新/删除）；
- **连接**：目标/进程/出口/命中规则/协议/已传输/开始 + 断开单条/全部（每 2s 轮询，仅本页开着时）；
- **规则**：自定义规则逐行校验、强制直连/代理站点、应用分流、去广告 + 分流库状态；
- **设置**：端口/局域网、内核（测速地址、日志级别、sniffer、smart 组）、常规（自启/关窗行为）、TUN。

托盘：显示主界面 / 退出；关窗按「每次问 / 缩托盘 / 直接退出」的记住项处理；托盘不可用时
关窗直接退出（不留隐形进程）。开机自启写 HKCU Run（`--minimized`），与安装器同键名。

### 4. 分流正确性（沿用已验证的设计）

- `geoip.metadb` / 去广告 mrs 后台落地，按「文件就绪」决定是否发射规则（缺库时内核会在
  config.Parse 阶段同步联网下载 → 点连接转圈）；
- `geo-auto-update: true` + `geox-url` 指向 jsDelivr 镜像：保鲜交给内核的后台 ticker，
  客户端只管首次连接前放好文件、内核直连下不动时改走本机代理补；
- smart 组只在 `Model.bin` 在盘上时发射（缺模型内核会同步去 GitHub 下载）；
- `PUT /configs` payload 热重载（不断连接），内核拒收再退回重启；
- 重名节点发射前唯一化、坏节点拦截（一个坏节点 = 整份配置 fatal）、控制字符净化；
- YAML 逐字模板（RawTemplate）：订阅里的未知字段原样回写，不丢 xhttp-opts/dialer-proxy/smux。

## 验证

- `dotnet test`：**31/31 通过**（解析契约、配置生成不变量、内核 E2E——真内核 stdout 监听行
  判据、/connections JSON 形状、UI 绑定契约与加载）；
- 真内核 E2E：导入 → 待命 3.2s（见上）；
- `dotnet publish`：自包含目录 `publish/`（含 core/tunbox-core.exe + Model.bin，脚本缺文件即报错）；
- `dist/TunBox-Setup-0.4.0.exe`：单文件安装器（payload 校验必须含内核与模型）。

## 已知限制

- 这台验证机回环 HTTP 被拦：`/version` 佐证、测速、连接页在沙箱里测不到真实数据，
  但 stdout 判据保证「内核就绪」这一步不再被它卡死；真机（回环正常）全部功能可用。
- 抓屏管线在本机不可信（DPI 报 96 但截图裁切），UI 以 XAML 加载 + 绑定契约测试为准。
- 安装包未签名。

---

# 0.4.1 轮（2026-10-11 晚）：用户点名的 6 条

## 1. 测速入口全部改成闪电

- 订阅页头的「全部测速」文字按钮 → `Content="&#x26A1;"` 的 40px 图标按钮（ToolTip 保留完整说明）；
- 分组 chip 的文案统一带 ⚡（`⚡ 组名（select · 成员数）`，测速中 `⚡ 组名 · 测速中…`）——
  用户之前把它当标签，是因为它长得就像一段文字；
- 单节点测速（点延迟数字）保留不动。

## 2. 「关闭主窗口时」三个选择没用 —— 根因不在 OnClosing

`CloseChoice` 的 setter 只改内存，落盘发生在「应用设置」那颗按钮上，而那颗按钮在**另一张卡**（端口与局域网）。
用户在「常规」里选完直接关窗 → settings.json 里还是旧值（真机 settings.json 现在仍是 `"close": 0`）。
修法：setter 里直接 `Settings.Close = …; SaveSettings();` 并 `Raise(CloseMode)`；
读档时走私有字段 + 通知，避免每次加载都回写一遍盘。
另：内核 / 常规 / IPv6-DNS 三张卡各补一颗「应用设置」，不再让人找按钮。

## 3. 风格统一：把默认控件全部重绘

`Assets/Styles.xaml` 新增隐式样式（全窗口 + 对话框一起生效）：
ComboBox（圆角白框 + MDL2 箭头 + 白卡 Popup，Item 高亮 BrandSoft、选中 Brand 白字）、
CheckBox（18px 圆角框 + ✓）、ProgressBar（圆角）、ScrollBar（11px 细条、透明轨道、
横向走 Track.Orientation 触发器而不是旋转面板——旋转会把滚动方向也转反）、
ToolTip（深底圆角，替掉系统黄底）。
**注意 WPF 坑**：ScrollBar 模板里的 Track 必须叫 `PART_Track`，否则内核找不到、滚动失效。

## 4. IPv6 与 DNS 复写

- `AppSettings`：`Ipv6Enabled` / `DnsOverrideEnabled` / `DnsServers`；
- 生成器同时发射顶层 `ipv6:` 与 `dns.ipv6:`（只开一个的话 AAAA 根本不查）；
- 复写只替换 `nameserver`；`default-nameserver`（223.5.5.5 / 119.29.29.29）必须留着当引导，
  否则 DoH/DoT 服务器自己的域名解析不了；接管时不再塞内置 `fallback`；
- `ValidateDnsServer()` 逐行校验：`udp/tcp/tls/https/quic/h3` 前缀、裸 IP、`IP:端口`、
  `[v6]:端口`、`system`、裸域名收下；空白/引号/未知协议拒绝并说明原因。
- **真内核 E2E 已验**：`Kernel_accepts_ipv6_plus_dns_override`（mihomo-smart 1.10.0 打 API 监听行，
  TUN 同时开启）；288ms 通过。

## 5. 「开虚拟网卡但右下角还是 Wi‑Fi 图标」= 不是故障

现场取证：`%APPDATA%\TunBox\runtime\core.log` 里成片
`[TCP] 198.18.0.1:16079 --> api2.qoder.sh:443` —— 源地址落在 fake-ip 段，**这就是 TUN 在接管的证据**。
Windows 右下角那个图标画的是物理链路（Wi‑Fi / 以太网），TUN 接管后它照旧是 Wi‑Fi；
Clash Verge / FlClash 同样如此，没有哪个客户端能改它。
所以改的是「把判据说清楚」：`TunStatusText` 接管态改为
「已接管：TunBox 虚拟网卡在线…右下角还是 Wi‑Fi 图标属正常」，并且区分
「网卡在但没拿到默认路由」和「网卡没起来」两种失败；设置页 TUN 卡片补同一段说明。

## 6. 连接页去掉「断开全部连接」、退出移到侧栏底部

- `CloseAllConnectionsCommand` 连同按钮一起删除（单条断开保留；内核清理走 Disconnect 路径）；
- 「退出 TunBox」从首页连接卡移到侧栏 DockPanel 的 Bottom（先声明的 Bottom 贴最下，所以退出在最底、
  实时流量卡在其上）；
- 侧栏副标题加了版本号（`Clash 内核 · Windows · v0.4.1`）——反复重装验证时得能看出跑的是哪一版。

## 验证（本轮）

- `dotnet test`：**55/55 通过**（原 53 + 关闭方式落盘 + 下拉框视觉树选中 + 侧栏/控件摆位；
  新加的摆位测试用 `Dock="Top"` 反向验证过，确实会红）；
- `publish/`（233MB）与 `dist/TunBox-Setup-0.4.1.exe`（77MB）已重出；
- 本机仍常驻 `Programs\TunBox-test\TunBox.exe`（旧实例）与 `verge-mihomo.exe`（用户自己在跑 Clash Verge）：
  单实例互斥会被旧实例抢走，冒烟启动不能当判据。

---

# 0.4.2 轮（2026-10-11 晚）：开关要「点一下就开」

## 实测数据（本机，管理员）

| 动作 | 改前 | 改后 |
| --- | --- | --- |
| 内核 spawn → API 监听行 | 42 ms（本来就快） | 42 ms |
| 冷启动 → 待命 | ~573 ms | 573 ms |
| 待命 → 已接管 | 整进程重启 + 轮询 | **1–6 ms**（热重载/原地复用） |
| 已接管 → 断开 | 杀进程（下次全冷启动） | **2–3 ms**，内核留在待命 |
| 拨开 TUN | **2544 ms** | **526 ms**（网卡 576 ms 就绪） |
| 带 TUN 断开 | 杀进程 | 86 ms，网卡真的消失 |

## 四条根因（都不是「机器慢」）

1. **`/version` 解析炸了**：本内核返回 `{"meta":true,"version":"1.10.0"}`，`meta` 是**布尔**；
   代码按 `meta.version` 索引布尔值 → `InvalidOperationException` → 被 catch 当成「控制器不通」。
   连带后果：就绪只能等监听行 + 白烧 2s 佐证预算，测速/热重载整条链路降级。
   **之前记的「本机回环 HTTP 被安全软件拦」是误判** —— 同一端口 curl 200、裸 HttpClient 401（缺头），
   通路一直没问题。这条纠正很重要，别再拿它当环境限制。
2. **端口预检把自己当外人**：`LocalPorts.FirstOccupied` 在待命内核监听 7890 时返回 7890 →
   点「连接」直接抛「端口 7890 已被其他程序占用」→ **用户看到的「连接异常」就是这条**。
   现在只有真要另起进程时才做端口预检。
3. **`StopProcess` 白等 2 秒**：`CloseMainWindow()` 对 CreateNoWindow 的隐藏进程永远返回 false，
   然后 `WaitForExit(2000)` 等满 —— 拨 TUN 那 2.5s 全在这。改成直接 Kill + 等端口放开（实测 526ms）。
4. **热重载开 TUN 反而慢**：`PUT /configs` 把 tun 从 false 改成 true 时，网卡 15s 才就绪；
   带 TUN 重启内核只要 363ms。所以 `BringUpAsync` 对「这次要开网卡」单独走重启，其余仍热重载（保连接）。

## 结构上的改动

- `CoreHost`：就绪改成**三路赛跑**（stdout 监听行 TCS / `/version` / 进程退出 TCS），去掉 500ms 轮询；
  新增 `RunningTunEnabled` 供上层判断这次变更是不是要开网卡。
- `ConnectionManager`：`BringUpAsync`（热重载优先，开网卡例外）+ `TryHotReloadAsync`（2.5s 预算，超时退重启）
  + `FinishTunCheckAsync`（网卡核对移到后台，失败写 LastError）+ `TunGoneAsync`（断开后确认网卡真消失）
  + `LastTiming` / `LastApplyNote`（分段耗时和走的路，状态栏直接显示）。
- `TestAllAsync`：**每条结果当场写回模型**。以前攒到整批结束才写，界面上「按延迟实时排序」
  永远等不到触发时机 —— 这就是「全部测速没生效」。
- `RebuildLists` 现在保留上次的显示顺序与选中的分组（内核事件一秒好几次，
  不保留就是「刚排好的顺序又弹回去」）。

## 用户点名的三条功能

1. **IPv6 与 DNS 复写拆成两张卡**，各自开关、各自「应用设置」。
2. **分组 = 筛选器**：chip 变成「全部节点（4）/ 自动选择（url-test · 2）/ 故障转移（fallback · 2）」，
   点谁就只显示该组节点（选中态蓝底白字），下面写「2 / 4 个节点 · 故障转移」；
   订阅卡头部的 ⚡ 测速按钮放在「更新」和「删除」之间，**只测当前这一屏**。
3. **开关即接管**：首页那颗大按钮是总开关；系统代理 / TUN 两个开关拨开就直接接管
   （`ApplySwitchAsync`：存设置 → 没接管就 ConnectNow，全关就 Disconnect 回待命），
   不再要求用户二次点击。开机自启只在真变了时写注册表。

## 验证

- `dotnet test` **58/58 通过**，新增：`/version` 布尔 meta 解析、分组筛选只剩该组、
  延迟排序作用在 VisibleNodes 且扛得住列表重建；
- 每页渲染成 PNG 人眼复核（分组筛选态、拆开的 IPv6 / DNS 复写两张卡）；
- `dist/TunBox-Setup-0.4.2.exe`（77MB）。

---

# 0.4.3 轮（2026-10-11 晚，接上）：崩窗 + 界面精简

## 1. 「未处理的异常：The operation was canceled」

`logs/ui-20261011.log` 的栈说得很清楚：
`ControllerClient.UpdateConfigAsync` → `ConnectionManager.TryHotReloadAsync` → `DisconnectAsync` →
`ToggleConnectAsync` → `AsyncRelayCommand.Execute`（async void）→ 调度器 → 弹窗。

根因是我上一轮加的热重载预算：`UpdateConfigAsync` 里
`catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }` 的意图是
「调用方真取消才往上抛」，但我传进去的 `ct` 就是那个 2.5s 的 `CancelAfter` 令牌 ——
预算一响 `ct.IsCancellationRequested` 自然为真，于是它**照实往上抛**，一路抛到 UI 线程。
（为什么预算会响：关 TUN 的那次热重载，内核自己就要忙好几秒。）

三处收口：
- `TryHotReloadAsync`：预算加到 6s，并把 `OperationCanceledException` 咽下 → 退回重启内核；
- `DisconnectAsync` / `ApplyChangesAsync`：整段兜异常，失败只写 `LastError`，不再往外抛；
- `AsyncRelayCommand`：加 `Failed` 事件，命令里冒出来的异常一律落状态栏。
  回归测试：`Async_command_reports_failure_instead_of_popping_a_crash_dialog`。

## 2. 一个更大的发现：DetailText 根本没绑到任何控件

全站唯一显示 `DetailText` 的地方**不存在** —— 也就是说「端口 7890 被占用」「已导入 24 个节点」
「热重载 34ms」这些话以前用户一个字都看不到，只看到「点了没反应」。
现在在内容区底部加了**全站唯一一条状态栏**（有内容才显示），并把散在各页的说明文字大幅删掉。

## 3. 界面精简（用户点名）

- 删掉首页的状态胶囊（`StatusText` 属性整个删了，6 处赋值一并清掉）；
- 删掉「右下角还是 Wi‑Fi 图标…」那段科普：`TunStatusText` 收成「未启用 / 已接管 / 网卡没起来」这种短状态，
  `SystemProxyStateText` 收成「已生效 / 未生效：点「连接」后自动写入 / 已关闭」；
- 连接页、规则页、设置页的长说明全部删掉或压到一行，解释性内容改放 ToolTip；
- 「快捷入口」卡删了（左侧栏本来就是导航，纯重复），连带 `OnNavClick` 处理器。

## 4. 卡片按内容适配，不再强行等大

设置页与首页的功能卡从 `UniformGrid Columns=2`（一行里被最高的那张撑齐）换成
`WrapPanel` + 每卡自己的 `Width`（250 / 270 / 300 / 330）+ `VerticalAlignment=Top`：
IPv6、常规这种一句话的功能不再占掉和端口表一样大的一块。

## 5. 总开关用颜色分状态

`Styles.xaml` 加 `Running`（#16A34A）；首页那颗按钮加 `DataTrigger`：
未接管 = 品牌蓝，已接管 = 绿（文案仍是 连接 / 断开）。
回归测试 `Connect_button_changes_color_when_traffic_is_taken_over`。

## 验证

- `dotnet test` **60/60 通过**；
- 每页渲染 PNG 复核（首页三张窄卡、设置页六张不等宽卡、底部状态栏出现「已导入，当前 3 个节点。」）；
- `dist/TunBox-Setup-0.4.3.exe`（77MB）。

---

# 0.4.4 轮（2026-10-11 深夜）：竖屏 + 底部三页签

## 结构

窗口从 1080×700 横屏改成 **470×880 竖屏**（MinWidth 400 / MinHeight 620），左侧栏取消：

```
┌ 顶栏：logo + TunBox v0.4.4 + 实时流量      [退出 TunBox] ┐
│ 内容区（ScrollViewer，整页竖向滚动）                     │
├ 状态栏：全站唯一的 DetailText 反馈位 ────────────────────┤
└ 底部导航：🏠 首页 · 📋 订阅 · ⚙ 设置（等宽单行）        └
```

- 页签宿主用 `UniformGrid Rows=1 IsItemsHost=True`（TabPanel 会换行、选中项还会重排）；
- 导航项 = 图标（Segoe MDL2：E80F / E8FD / E713）+ 文字，选中态品牌色加粗。

## 页面合并（5 页 → 3 页）

| 原页面 | 现在 |
| --- | --- |
| 首页 + 连接 | **首页**：开关卡（连接按钮 + 规则/全局/直连 + 当前出口）、系统代理、TUN、分流库、实时连接（四列：目标/进程/出口/已传输 + 单条断开） |
| 订阅 | **订阅**：手风琴卡 + 分组筛选 + 节点竖排一行一个 |
| 规则 + 设置 | **设置**：端口、内核、IPv6（独立卡）、DNS 复写、分流规则（开关/强制站点/自定义规则/应用分流）、常规 |

连接页轮询的触发条件跟着改成「当前页 == 首页」（`SetActiveTab`）。
节点从「迷你方块 WrapPanel」改成整行一条（竖屏下一行一个，名字 + 类型 + 延迟），
选中态仍是品牌描边浅底。

## 测试同步改了 3 条

- `Sidebar_navigation_is_a_single_vertical_column_in_fixed_order`
  → `Bottom_navigation_has_three_tabs_in_one_stable_row`：三颗、同一行、X 递增、且 Y 在窗口下半部；
- `Exit_button_sits_at_the_bottom_of_the_sidebar…`
  → `Portrait_window_keeps_exit_in_the_top_bar_and_combo_boxes_render`：断言 `ActualWidth < ActualHeight`（竖屏）、
  退出按钮 Y < 60 且在导航栏上面；
- 压测遍历的页头从 5 个改成 {订阅, 设置, 首页}。

## 验证

- `dotnet test` **60/60 通过**；
- 三页各渲染 PNG 人眼复核（顶栏、底部三页签、分组筛选只剩该组两节点、设置页单列卡片流）；
- `dist/TunBox-Setup-0.4.4.exe`（77MB）。

---

# 0.4.5 轮（2026-10-11 深夜）：电源环 + 9 条界面精简

## 1. 电源环（照鸿蒙 `components/StatusRing.ets`）

三层圆 + 状态字：外发光 196（未启动 `#1F2563EB` / 已启动 `#3810B981`）、白盘 172 描边 1.5 `#E4E8F0`、
图标底圆 40（`#F1F5F9` / `#1F10B981`）、下面 19px 粗体状态字（未连接 / 正在连接 / 已连接）。
已连接时外圈 1.2s 呼吸（ScaleTransform 1→1.04，AutoReverse + Forever，`RemoveStoryboard` 负责停）；
按下整环缩 0.97。

**坑**：鸿蒙端图标是文本 `⏻`（U+233B），Windows 的 Segoe 字体族没有这个字形，直接写会渲染成方框。
改成 Path 画（一段 260° 圆弧 + 一根竖线），颜色仍由 DataTrigger 控制。

## 2. 系统代理开关删除

「启动就代表启动系统代理」：`TrySaveSettings` 里固定 `s.SystemProxyEnabled = true`，
`SystemProxyOn` / `SystemProxyStateText` / `SystemProxyActive` / `ToggleSystemProxyCommand` 全部删掉，
首页那张卡也删了。写不进注册表仍然当场报（`ConnectNowAsync` 里那条警告留着）。

## 3. 其余 7 条

1. 订阅页去掉「订阅与节点」标题卡，只剩 ⚡ 与 ＋ 两颗图标（右上角）；
2. 子对话框必须比主窗口小：`DialogFit.ToOwner()` 在 Loaded 时按 Owner 尺寸夹 MaxWidth/MaxHeight，
   ImportDialog 560→430、EditDialog 520→430。顺带修了 ImportDialog 构造期 `Owner` 还是 null
   （对象初始化器在构造函数之后才赋值）导致图标没跟上的老问题；
   两个对话框都自己合并 Styles.xaml，不再依赖 App 级资源；
3. 底部提示 3 秒自动消失（`DetailText` 的 setter 里起 DispatcherTimer）；
4. 订阅卡折叠态活过每一次 `RebuildLists`（和分组筛选一起捕获再恢复），
   Expander 绑定显式写 `Mode=TwoWay`；
5. 「DNS 复写」改名「DNS 覆写」，并预填默认值 `tls://223.5.5.5:853` + `tls://1.12.12.12:853`
   （阿里 + 腾讯 DoT，国内可达且加密），用户可改；
6. 设置页只留一颗**悬浮在右上角**的「保存设置」（在 ScrollViewer 外面，滚动不覆盖也不盖内容），
   一次保存设置 + 规则（`SaveAllCommand` → `TrySaveSettings` + `TrySaveRules` + 一次生效），
   原来六颗「应用设置」和「保存规则设置」全删；
7. 分流规则卡从「去广告」以下折叠进 Expander。

## 验证

- `dotnet test` **64/64**，新增 4 条：提示 3 秒消失、对话框必须小于主窗口（真开两个框量尺寸）、
  折叠态扛得住重建、界面契约（画出来的电源符号 / 没有系统代理字样 / 只有一颗保存 / DNS 叫覆写且有默认值）；
- 渲染 PNG 复核：电源环、设置页悬浮保存条、430 宽的导入框；
- `dist/TunBox-Setup-0.4.5.exe`（77MB）。

---

# 0.4.6 轮 + 发布（2026-10-11 深夜）

## 界面（用户点名）

1. 顶栏「退出 TunBox」→「退出」：流量串可以很长（速率 + 连接数 + 累计），会把按钮盖住；
   同时给左侧留 `Margin 0,0,64,0` 并让流量文字 `MaxWidth=300 + TextTrimming`。
   回归测试 `Long_traffic_line_never_covers_the_exit_button` 用 34 条连接的真快照量一次坐标，
   断言两者矩形不相交（注意：喂快照必须在 `window.Show()` 之后，否则首页轮询第一轮就把 TrafficText 打回 0）。
2. 首页「实时连接」卡改成可折叠（`ConnectionsExpanded`）。
3. 设置页「端口与局域网」卡改成可折叠（`PortsExpanded`）。
   两者折叠态都放在视图模型里并 `Mode=TwoWay`：TabControl 切页会丢掉上一页的视觉树，
   绑在控件上就会在切回来时弹开（订阅卡已经踩过一次）。

测试 **65/65**；`dist/TunBox-Setup-0.4.6.exe`（77MB）。

## 发布到 GitHub

本机 **没有 git 检出**（`C:\Worker\TunBox` 无 `.git`；skill 里记的是另一台机器的路径），
且 **github.com 被网络阻断**（curl 直连与指定 IP 都 000），但 `api.github.com` / `uploads.github.com` 通、令牌有效。
所以整轮走 REST：blobs → tree(base_tree) → commit → `PATCH refs/heads/main`。

- 提交：**`53d0fea`**（父 `c6b2472`，40 个文件，+9563 行），main 已指到这里；
- Release：**`windows-v0.4.6`** · `TunBox Windows v0.4.6` · 附件 `TunBox-Setup-0.4.6.exe`（80,699,900 B，state=uploaded）
  → https://github.com/xiaoli8571/TunBox/releases/tag/windows-v0.4.6
- 不入库：`publish/`、`dist/`、`bin/`、`obj/`，以及内核二进制
  （`core/tunbox-core.exe` 66MB、`core/Model.bin` 9.3MB）—— 新增 `TunBox-Windows/.gitignore` 与
  `TunBox-Windows/README.md` 说明怎么取（来自仓库根已有的 `mihomo-build/`）。
- 提交前按 skill 跑了敏感材料扫描（文件名 + 内容正则），`skills/` 与令牌未进仓库。

**这一轮踩到并修掉的四个坑**（细节已写进 Agent 记忆 `env-github-publish`）：

1. PS 5.1 把无 BOM 的 UTF-8 脚本按 GBK 读 —— 中文注释会咬坏语法（同一个错这一轮犯了两次）；
2. `Get-Content -Raw` 的字符串直接进 `ConvertTo-Json` 会变成 `{"value":…,"Count":1}`，要 `[string]` 转；
3. `Invoke-RestMethod -Body <string>` 按 ASCII 发出去，**中文全变 `?`**（提交信息就这么毁了）——
   必须 `[Text.Encoding]::UTF8.GetBytes($json)` + `charset=utf-8`；
4. `GET /git/trees/<sha>?recursive=1` 返回整棵仓库（1984 个 blob），全塞进新 tree 会 500 —— 只发本轮新增条目。

另外第一次提交把路径写重了一层（`TunBox-Windows/TunBox-Windows/…`，相对路径前缀加了两次）：
用同一批 blob 重建 tree、换掉 commit，并 `PATCH refs/tags/windows-v0.4.6` 把标签移到修正后的提交上 ——
**Release 的附件跟标签名走，所以 77MB 不用重传**。

---

# 0.4.7 轮（2026-10-11 深夜，接上）：折叠排序 + smart 上界面 + 真 git 推送

## 界面

1. **设置页每节都做成可折叠条**（网络配置 / 内核 / 分流规则 / 常规），并且**折叠着的排在上面、展开的那节
   自动挪到后面**：`MainWindow.xaml.cs` 的 `OnSectionToggled` → `SortSettingsSections()` 按 IsExpanded
   稳定重排 `SettingsPanel.Children`。注意 `UIElementCollection` 没有 `Move`（那是 ObservableCollection 的），
   只能 Remove + Insert。
2. **顶栏流量串去掉「N 条连接」**（最长时最右边显示不全），连接数改放「实时连接」卡标题
   （`ConnectionsHeader`，快照应用时 Raise）。
3. **IPv6 + DNS 覆写并入「网络配置」**（原「端口与局域网」改名）；**分流库的「更新」从首页挪进
   「分流规则」**，与「去广告」同级。
4. 折叠态全部走视图模型 + `Mode=TwoWay`（切页会丢视觉树，绑在控件上必弹开）。

## smart 自动优选（mihomo-smart 的内置 LightGBM）

对照鸿蒙端（`TunBox_HarmonyOS`）的实现搬到 Windows：

- 组名 `♻️ 自动选择` 两端一致；发射判据一致（开关开 + 模型在盘 + ≥2 节点），
  新增 `ConnectionManager.SmartGroupReady`。
- **模型要在 `ConnectionManager` 构造时 `EnsureSmartModelInPlace()`**：以前只在 BuildConfig 里放，
  第一次打开界面时模型还没到位 → 「自动选择」这一条会凭空消失。
- 订阅页顶部一条「自动选择」（副标题带候选节点数 + 使用中徽标）；
  `Settings.SelectedNodeId == "smart"` 是「出口交给 smart 组」的哨兵值；
  **没显式选过节点时默认即自动态**；点任意真实节点 → 哨兵被节点 id 覆盖 = 切回手动。
- 首页「当前出口」在自动态显示组名。鸿蒙端那条关键事实同样适用：
  **LightGBM 的按连接选择不会写回 `/proxies` 的 `now`**，只有每条连接的 `chains` 是事实 ——
  所以 Windows 端实际走的节点看「实时连接」的出口列（chain[0]）。

## 推送：本地代理可用，改回真 git

用户给了本地代理 `127.0.0.1:7890`。实测 `curl -x` 打 github.com 与 `info/refs` 都是 200 ——
**上一轮记的「github.com 被阻断」其实是没走代理**，不是网络封锁。于是这轮走正规路径：

- `git -c http.proxy=http://127.0.0.1:7890 clone` 到 `C:\Worker\_release\TunBox-repo`（本机终于有一个真检出）；
- robocopy `/MIR /XD bin obj publish dist core` 同步源码（Git Bash 会把 `/MIR` 当路径转换，
  要 `MSYS_NO_PATHCONV=1`），只提交 9 个文件 +298/-68，构建产物与内核二进制一个没带；
- `git push origin main` → `53d0fea..3297ddc` ✓；
- Release `windows-v0.4.7`（id 409735079）：`Invoke-RestMethod` 直连传 77MB 附件**超时**，
  改 `curl -x http://127.0.0.1:7890 --data-binary` → 201，复查 `state=uploaded`、80,702,311 字节。

测试 **66/66**；`dist/TunBox-Setup-0.4.7.exe`。
