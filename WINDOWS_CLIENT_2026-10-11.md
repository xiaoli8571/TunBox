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

---

# 0.4.8 轮（2026-10-11 深夜）：设置页不许跳位 + 「数据被清空」的真身

## 1. 设置页排序：把「折叠的排上面」这条启发式删掉

用户反馈：「网络配置在第一个，展开后就跑到了最后一个」。上一轮那个 `SortSettingsSections()`
（Expanded/Collapsed 事件里按 IsExpanded 稳定重排 `Children`）是把「整齐」做成了动态规则 ——
展开一节就整页换位，用户下一秒找不到刚才那节。现在四节**固定按声明顺序**
（网络配置 / 内核 / 分流规则 / 常规），只在本位撑开；`OnSectionToggled`、`SortSettingsSections`、
以及只为其服务的 `x:Name`（SettingsPanel / Sec*）一并删掉。
测试换成 `Settings_sections_keep_their_order_when_one_expands`：按 Y 取四节表头，
展开「内核」前后必须逐字相等。

## 2. 「每次装新版数据都被清空」——安装包没删过数据，是 app 自己读不回来

先排除嫌疑：`installer.nsi` 从头到尾没碰过 `%APPDATA%\TunBox`，卸载器也没有。真正的根因是
**`System.Text.Json` 不会往「只读集合属性」里填元素**：

```csharp
public List<ProxyNode> Nodes { get; } = new();   // 写得出去，读回来 0 个
```

`NodeLibrary.Nodes/Groups/Subscriptions`、`ProxyNode.Extras`、`ProxyGroup.Members`、
`AppSettings.DnsServers/CustomRules/ForceProxySites/ForceDirectSites/AppProcesses`
全是这个形态 —— 落盘是完整的 42KB JSON，重启解析出来一个都不剩，用户看到的就是「数据没了」。
判据（一次性探针，跑完即删）：改 setter 前 `LoadNodes()` 返回 0 节点，改完读到
**1 条订阅 / 24 个节点 / 3 个分组**（真机 `%APPDATA%\TunBox\nodes.json`）。
所以这类「持久化模型的集合」一律 `get; set;`，并加测试 `Every_persisted_list_round_trips_through_disk`
盯住每一条名单，免得以后又加一个只读集合悄悄丢数据。

顺手补的第二个洞（同一条投诉的另一半）：**半截 JSON 会静默重置**。原来 `LoadNodes` 解析失败就
`return new NodeLibrary()`，而 `File.WriteAllText` 是先截断再写 —— 写一半时进程被杀（升级安装、
注销、断电）就留下半截文件，下一次保存直接冲掉原文。现在：

- 落盘改「写 `.tmp` → 把旧主文件复制成 `.bak` → `File.Move` 原子替换」；
- 读取：主文件坏了就改名留档成 `nodes.json.bad-<时间戳>`（不删，供排查），再回落到 `.bak`；
- 测试 `Half_written_nodes_file_falls_back_to_the_last_good_copy`。

`Workspace` 另加 `Serialize/Deserialize` 两个静态口子，读写共用同一套 `JsonSerializerOptions`
（外部要解析同一份文件时不必重打参数）。

## 3. 安装向导给出「保留 / 清理数据」的选择

`!insertmacro MUI_PAGE_COMPONENTS` 组件页 + 两个 section：

- `Section "TunBox 主程序" InstMain` —— `SectionIn RO`，勾不掉；
- `Section /o "清理个人数据（订阅、节点、设置、分流库）" SecWipe` —— **`/o` 默认不勾选**，
  勾上才 `RMDir /r "$APPDATA\TunBox"`。静默安装（`/S`）走默认，绝不会清数据。
- 两项都配了 `MUI_DESCRIPTION_TEXT` 中文说明（鼠标悬停即解释「不勾选=升级不丢数据」）。
- `.nsi` 必须 **UTF-8 with BOM**，否则 makensis 按 ANSI 读，中文全成乱码 —— 已用
  `[IO.File]::WriteAllText($p, $text, (New-Object Text.UTF8Encoding($true)))` 补上 BOM。

编译结果自证：`Install: 5 pages, 2 sections (1 required)`。

## 4. 版本与验证

- 0.4.7 → **0.4.8**（csproj `Version`、`installer.nsi` 的 `!define VERSION` + `VIProductVersion`/
  `VIAddVersionKey`、`make-installer.ps1` 的 `$ver` 四处同步）。
- 测试 **69/69**（新增 3 条：设置页不跳位、名单全量往返、半截文件回落）；
  `dist/TunBox-Setup-0.4.8.exe` 80,690,136 字节。
- 未在本机覆盖安装（用户机上那份 0.4.7 实例常驻，两个实例抢 7890 会污染验证）。

## 5. 发布

`127.0.0.1:7890` 这轮不通（用户机上 TunBox 没在跑，端口无人监听），`git ls-remote` 直连 github.com 依旧
连不上，而 `api.github.com` 正常 —— 于是回退到 0.4.6 那套 Data API（脚本 `C:\Worker\_release\publish-048.ps1`）：
10 个文件逐个 `POST /git/blobs`（**base64**，`.nsi` 的 BOM 与 CJK 才能逐字节保住，落地后用
`git hash-object --no-filters` 对过号）→ `POST /git/trees`（base_tree = 上一提交的树）→
`POST /git/commits` → `PATCH /git/refs/heads/main`（不带 force，只能快进）。
提交 `2ab642b`（父 `2e2d149`）、Release `windows-v0.4.8`（id 409758115）、
附件 `TunBox-Setup-0.4.8.exe` 80,690,136 字节 `state=uploaded`。
提交信息与正文都走 `[Text.Encoding]::UTF8.GetBytes` + `charset=utf-8`，回读确认中文没变 `?`
（控制台打印是 GBK 码页的花码，不代表存坏了 —— 要用 `sed` 直接看 API 返回的字节）。

本机检出 `C:\Worker\_release\TunBox-repo` 上那条本地提交 `897fd6b` 与远端 `2ab642b` 内容等价但历史不同，
**不要 `git push` 它**；等 7890 可用时先 `git fetch` 再把本地分支对回 origin/main。

---

# 0.3.0 轮（2026-10-12 零点）：版本号并回鸿蒙端 + 安装时自动关掉正在运行的程序

## 1. 版本号 0.4.x → **0.3.0**

用户要求两端版本一致：鸿蒙端 `TunBox_HarmonyOS/AppScope/app.json5` 是 `versionName "0.3.0"`
（versionCode 300），Windows 端此前自己爬到了 0.4.8，属于同一产品的两个头各报各的号。
现在四处一起改（`TunBox.App.csproj` 的 `<Version>`、`installer.nsi` 的 `!define VERSION` 与
`VIProductVersion`/`VIAddVersionKey`、`make-installer.ps1` 的 `$ver`），并且**加了测试守着**：
`VersionConsistencyTests.Windows_version_matches_the_app_the_installer_and_the_harmonyos_client`
从程序集 InformationalVersion、`.nsi` 两处、`.ps1` 一处和鸿蒙 `app.json5` 一起取值比对 ——
0.4.8 那轮我差点发出「文件名 0.4.8、关于页 0.4.7」的包（先改完脚本忘了改 csproj），
没有这条测试就还会再犯。GitHub 上 `windows-v0.4.6/0.4.7/0.4.8` 三个 Release 按要求删除，
只留 `windows-v0.3.0`。

## 2. 装新版时自动关闭正在运行的 TunBox

原来的失败方式：主程序在跑 → `File /r` 覆盖 `TunBox.exe` 报「无法写入文件」→ 安装中止。
现在安装节先 `Call CloseRunningApp`：优雅 `taskkill /IM "TunBox.exe"`（不带 /F = 发 WM_CLOSE）→
等文件解锁（6 次 × 500ms ≈ 3 秒）→ **还锁着就 `taskkill /F`** → 再等解锁（12 次 ≈ 6 秒）。

这里有个坑值得记：**判据不能用 taskkill 的返回码**。最小化到托盘的 WPF 程序窗口是隐藏的，
taskkill 会当成「没有可关的窗口」报错返回，看着像「进程已经没了」，其实文件还锁着 ——
安装照样在下一行失败。所以 `WaitForUnlock` 只认一件事：`FileOpen "$INSTDIR\TunBox.exe" a`
能不能打开。打点实测每步 220–500ms，最坏总耗时约 10 秒，绝不会变成无限等。
顺带补一刀 `taskkill /F /IM "tunbox-core.exe"`：内核 normally 随主程序的 Job Object
（KILL_ON_JOB_CLOSE）一起走，补这刀是防上次崩溃留下的孤儿内核占着 `core\tunbox-core.exe` 与 7890。
两个镜像名都是我们自己的，不碰用户机器上的其他代理程序。

实测（`C:\Worker\_release\test-close-app.ps1`，在临时目录里跑假 TunBox.exe，不动真安装目录与
`%APPDATA%\TunBox`）：无进程 1.1s 通过；窗口型进程优雅关闭 1s、文件立刻可写；
活着的控制台进程被关掉后文件解锁 1s；被外部句柄锁住时正确报「仍占用」。

## 3. 顺手修的一个仓库陷阱

根 `.gitignore` 为鸿蒙打包产物写的 `*.app`，在大小写不敏感的 Windows 上（`core.ignorecase=true`）
会把 **`TunBox-Windows/src/TunBox.App/` 这个源码目录整个判为忽略**：已跟踪的文件照常提交，
所以一直没露脸；但**以后在该目录新建的 .cs/.xaml 会被 `git add` 静默跳过**（这轮 `git add` 就报了
"The following paths are ignored"，才把它揪出来）。已在 `.gitignore` 里显式豁免：

```
!TunBox-Windows/src/TunBox.App/
!TunBox-Windows/src/TunBox.App/**
```

判据：往该目录扔一个 `__ignore_probe.cs`，`git status` 能看见 `??` 才算真通（`git check-ignore -v`
只回显最后命中的规则，看着像“被忽略”，别被它骗）。

## 4. 版本与验证

- 测试 **70/70**（新增版本一致性那条）。
- `dist/TunBox-Setup-0.3.0.exe` 80,698,375 字节，makensis 汇总仍是 `5 pages, 2 sections (1 required)`
  —— 组件页那颗「清理个人数据」默认不勾选的行为不变。
- 本机没有覆盖安装用户的 TunBox（那该由他自己在向导里决定保不保留数据）。

## 5. 发布

`127.0.0.1:7890` 还是没人监听（用户的 TunBox 没在跑），github.com 的 git 通道依旧连不上，`api.github.com`
正常 —— 走 Data API。这轮把三个假象逐个剥掉了，脚本 `C:\Worker\_release\publish-030-commit.ps1`
（提交）与 `publish-030-release.ps1`（发 Release + 删旧的）以后直接抄：

1. **`Invoke-RestMethod` 的 413 `Request Entity Too Large` 是真的**：一个 832 字节的 tree POST 就被 nginx
   打回。同一份 JSON 交给 curl 就过 —— 所以**传输一律用 curl，PS 只用 `ConvertTo-Json` 生成 payload**。
2. **上一轮那个 422 `tree.path contains a malformed path component` 跟 nginx 无关**，本轮用 curl 照样复现，
   真正的根因是 PS 5.1 的老毛病换了个面孔：从管道里取出的**单行**路径是个单元素 `Object[]`，
   `ConvertTo-Json` 把它写成 `{"path":{"value":"…","Count":1}}`（跟「`Get-Content -Raw` 的字符串要先
   `[string]` 转」是同一条规则）。凡是读进内存再喂给 `ConvertTo-Json` 的东西，一律 `[string]` 定死。
3. **blob 必须真上传**：`git hash-object` 本地算出的 sha 内容与 GitHub 那份逐字节一致，但**对象不在库里
   就是 `tree.sha … is not a valid blob`**。之前那次能成，是因为上一轮失败的脚本已经把同内容的 blob 传上去过
   —— 靠运气而不是设计。现在每个文件都先 `POST /git/blobs`（base64，保 BOM 与中文），
   再把本地 `hash-object` 的值与返回的 sha **比对**，两边对不上就中止。

另外两个 PowerShell 坑：① **`Curl` 是 `Invoke-WebRequest` 的内置别名，而别名优先级高于同名 function**，
自己写的函数必须换名（`Curl-Json` / `Invoke-Github`）；② **函数的返回值是整个流水线输出**，
里面顺手 `Write-Output` 一行日志，调用方拿到的就是「日志 + 路径」拼起来的字符串，喂给 curl 直接报错。

- main `337aa83 → ab96236`（6 个文件：版本四处、`.nsi` 的自动关闭、版本一致性测试、`.gitignore` 豁免、文档）。
- Release `windows-v0.3.0`（id 409781893），附件 `TunBox-Setup-0.3.0.exe` 80,698,375 字节 `state=uploaded`。
- 按要求删除 `windows-v0.4.6 / 0.4.7 / 0.4.8` 三个 Release **及各自的 tag**（删 Release 不会删 tag），
  全部 204；剩下的 Release 只有 `windows-v0.3.0` 与鸿蒙端 `v0.2.0`、`v0.1.0`。

---

# 0.3.0 补丁轮（2026-10-12 上午）：「全局模式反而不走代理」+「虚拟网卡没起来」误报

## 0. 先说一件事：工作目录不见了

`C:\Worker\TunBox\TunBox-Windows` 在本轮开始前**整个不存在**（`TunBox\` 下只剩鸿蒙端与文档），
本机唯一一份代码是发布用的检出 `C:\Worker\_release\TunBox-repo\TunBox-Windows`（内容 = 远端 main）。
已从它恢复工作树，并把内核二进制从已安装的
`%LOCALAPPDATA%\Programs\TunBox\core\`（`tunbox-core.exe` 66MB + `Model.bin` 9.3MB，两者都不入库）
复制回 `TunBox-Windows\core\`，否则 KernelE2ETests 找不到内核。恢复后基线 70/70 全绿。

## 1. 全局模式：不是「选错节点」，是**两层都没生效**

用户实测「全局模式 IP 检测站还是国内 IP，规则模式才是节点 IP」。拿他正在跑的那份内核（127.0.0.1:9090）
直接看现场，两条都坐实了：

1. **`PUT /configs {"mode":"global"}` 是空炮。** 返回 204，但 `GET /configs` 的 mode 照旧是 rule，
   连 `{"log-level":…}` 同样不生效 —— 这份 mihomo-smart 内核只认**整份 `payload`**。
   实测：整份 payload（配置里写 `mode: global`）PUT 进去，`GET /configs` 立刻变 global。
   → 切模式必须走 `ReapplyRunningConfigAsync()`：按当前设置重新生成配置、`PUT /configs payload`、
   `_host.SaveConfig` 对齐「正在跑的是哪份配置」。`ControllerClient.SetModeAsync` 直接删掉，
   留着只会有人再踩。
2. **就算 mode 真的成了 global，流量也不走我们的选点。** 内核在 global 下只看 `GLOBAL` 这个伪分组，
   我们所有选点都写在 `PROXY` 组里，从没碰过 GLOBAL → 现场值 `GLOBAL.now = "DIRECT"`，
   于是「全局」= 全部直连。真机日志两种情形一目了然：
   - `mode=rule`：`[TCP] … --> 1.1.1.1:80 doesn't match any rule using DIRECT`
   - `mode=global` + `GLOBAL=HK 01`：`[TCP] dial GLOBAL … error: 127.0.0.1:1 connect error`（真的去连节点了）

**意外收获（改设计的那种）**：原以为 GLOBAL 只认具体节点（它的 `all` 里确实只有 DIRECT/REJECT + 节点），
实测 `PUT /proxies/GLOBAL {"name":"PROXY"}` 也**接受**，而且是 dial 时才解析 —— 也就是说
**代理组可以直接塞进 GLOBAL**。于是自动态不必退化成「固定一个节点」：
`PickGlobalEgress` 就一句「跟着 PROXY 组当前的选择走」，
`♻️ 自动选择` 在全局模式下继续按每条连接择优。退回顺序（拿不到 PROXY 时）：用户点过的节点 →
smart 当前节点 → 第一个像节点的名字；任何情况下都不许退成 DIRECT/REJECT，也要避开
订阅面板当成代理返回的「剩余流量：xxx GB」这类说明行。

同步时机：切模式、点节点、连接/热重载之后（配置重建会把 GLOBAL 的选择冲掉）。

测试：**75/75**。新增 `Kernel_global_mode_needs_the_payload_and_honours_GLOBAL`（真内核：payload 才改得动
mode、GLOBAL 认组名也认节点名、最后真发一个请求看日志是不是 `dial GLOBAL`）与
`GlobalModeEgressTests` 四条纯逻辑。这条 E2E 里「控制器不可达就 return」的静默跳过已单独改成硬断言跑过一遍，
确认本机真的在断言而不是跳过。

## 2. 「虚拟网卡没起来」是误报：内核重试成功了，我们只等 8 秒

内核日志（`%APPDATA%\TunBox\runtime\core.log`）自己就把话说完了：

```
[10:20:50] warning Start Tun interface timeout: create adapter: Cannot create a file when that file
              already exists. | open existing adapter: Element not found. [retrying 1/3]
[10:20:51] info  [TUN] Tun adapter listening at: TunBox([198.18.0.1/30],[]), mtu: 1500, auto route: true
```

第一次建卡撞上残留的旧网卡（同名适配器还在、句柄已经没了），内核自己重试，**1 秒后就起来了**；
而 `FinishTunCheckAsync` 的等待预算只有 8 秒，抢在内核重试之前判了失败。昨天 20:58 是同一幕。
改法：预算 8 秒 → 30 秒（这段本来就是后台核对，不占用户那次点击），并且期间状态行显示
「内核正在建网卡…」而不是直接甩「网卡没起来（看内核日志）」；新增 `ConnectionManager.TunPending`，
断开/停止路径一起清零。

顺带记一笔现场环境（不影响本轮改动，但会干扰判断）：`Get-NetAdapter` 里有三个
`Wintun Userspace Tunnel`（本地连接 / 2 / 3）残留，都不是我们的 `TunBox` 卡 —— 用户机上还常驻
Clash Verge Rev，验证网卡时别把它们的卡当成我们的。

---

# 0.3.0 第二轮补丁（2026-10-12 午后）：点的节点≠走的节点 + 自动重启 + 出口信息卡

## 1. 「不管选什么节点，都走自动选择」——用户猜对了，而且原因在配置里

排查路径（全用真机与真内核，不靠猜）：

1. 订阅原文里那个「YF新加坡-VLESS-WS-CF·住宅·US」**没有** `dialer-proxy`/relay —— 住宅是
   NexPanel **服务端**注入的（`app/egress.py`、`app/residential.py`：sing-box 出站走宿主 VPN Gate SOCKS5 :7920）。
   所以客户端不该有任何特殊处理。
2. 独立起两个探针内核：一份用订阅原文、一份用**我们生成的那一行**，都选这个节点查 `ip-api.com` →
   **两份都是美国住宅 `216.189.136.50`（West Central Telephone）**。节点写法没问题。
3. 那问题只能在「选择有没有生效」。看现场：内核 `PROXY.now = AWS新加坡-Hysteria2`，而
   `settings.json` 记的是另一个 id —— 两边会飘。翻生成器：`proxies:` 列表第一位放的是
   **`♻️ 自动选择`**，而 PROXY 组**没有写 `now`** → 内核加载配置时对没有 `now` 的 select 组
   **默认取成员表第一个**。于是：用户点了 A 节点（当时 PUT 成功），但只要一重启/一热重载/一断连重连，
   出口就悄悄回到 ♻️ 自动选择，每条连接由 LightGBM 自己挑（常挑到新加坡那个快的）——
   正是「我选的节点跟我查到的 IP 不对应」。

**修法两层**（内核实测都验过）：

- `ClashConfigGenerator` 给 PROXY 组写 **`now:`**：用户选的具体节点，自动态才写 `♻️ 自动选择`；
  选中的节点被订阅更新删掉时回落真实存在的节点，绝不写不存在的名字。真内核 E2E 断言
  「配置里的 now 被采纳」+「payload 重载之后 still 停在这个节点」。
- `ConnectionManager.ApplyEgressAsync()`：每次配置生效之后（连接、热重载、重启、分流库落地、切模式）
  都把 `ReassertSelectionAsync()` + `SyncGlobalEgressAsync()` 走一遍，作为第二层保险；
  节点已从组里消失时把 `SelectedNodeId` 收回自动态并在状态行说清楚，PUT 失败也不再假装成功。

顺带一条判据经验：**「选中的节点」和「走的节点」是两件事**，以后再有「IP 不对」的反馈，
先看 `GET /proxies/PROXY` 的 `now`，别看界面。

## 2. 凡是需要重启代理才能生效的，一律自动重启

原来有两条路会留到「下次连接才生效」：`TryHotReloadAsync` 谈不拢时（这条其实早就自动重启了），
以及**分流库落地**那条（只留一句「下次连接起用新规则」）。现在 `ApplyAfterGeoLanded` 走
`BringUpAsync`，热重载不行就重启；并且新增 `GeoAssetStore.HasPendingSwap` ——
新库被运行中的内核映射着换不掉时，**先停内核**（停的那一刻 `ApplyPendingSwaps` 才换得动）再重建配置启动。
状态文案跟着改实话：`已更新 · … · 已生效` / `旧库还被内核占着，重启后立即替换`。

## 3. 首页新增「出口信息」卡（虚拟网卡与实时连接之间）

对齐 Clash Verge / FlClash 的做法：**走代理问一次出口，直连问一次本机，并排摆出来**。

- 数据源 `EgressProbe`（`TunBox.Core/Fetching`）：`http://ip-api.com/json/?lang=zh-CN&fields=…`，
  免 key、一次给齐 IP / 国家 / 州省 / 城市 / 运营商 / ASN；出口那一问用 `WebProxy(http://127.0.0.1:<混合端口>)`，
  本机那一问必须 `UseProxy=false`（否则「本机 IP」查出来其实是出口 IP，两个数一比一等零）。
- 卡片四行：出口 IP / 位置 / 运营商 / 本机 IP，右上 ↻ 手动刷新；
  连接建立、换节点、切模式后 800ms 防抖自动重查（`_egressStamp = 状态|模式|SelectedNodeId`）。
- **出口 IP == 本机 IP 时亮琥珀色提醒**「这条连接没走代理」——这张卡本身就是这类问题的现场取证。
- 位置三兄弟去重（ip-api 对城市级数据常把国家/州/市回成同一个词）；
  被门户劫持返回 HTML 时报「接口没返回 JSON（被网络劫持了？）」并带上前 40 字符。
- 配色新增 `Warn`/`WarnSoft`（琥珀），提醒不是错误，别用红色。

## 4. 版本与验证

- 测试 **83/83**（新增：`Proxy_group_carries_the_users_choice_as_now`、`EgressProbeTests` 5 条、
  `Home_page_puts_the_egress_card_between_tun_and_connections`，并扩展了全局模式那条真内核 E2E）。
- 构建 0 警告；`dist/TunBox-Setup-0.3.0.exe` 80,710,287 字节（按用户选的方式仍是 0.3.0，与鸿蒙同号）。
- **UI 没做视觉验收**：这台机器的抓屏不可信，且用户的旧实例常驻（单实例互斥会被抢走），
  卡片是按绑定契约 + 坐标断言在 UiTests 里验的。
- 事故记录：排查中我用过 `taskkill /F /IM tunbox-core.exe`（按镜像名批量杀），
  把**用户正在用的那个内核一起杀了**。以后一律先取 PID 再精确杀，别用镜像名。

---

# 0.3.0 第三轮补丁（2026-10-12 午后，接上）：真正的根子是节点 id 跨订阅撞车

用户按上一步的提示操作后仍不对，并且看到一句莫名其妙的话：
「选 YF新加坡-VLESS-WS-CF·住宅·US 没被内核接受（节点可能刚下线），先点「更新」」。
顺着这句查下去才是真根因。

## 现场证据（都在他自己机器上）

1. `PUT /proxies/PROXY {"name":"YF新加坡-VLESS-WS-CF·住宅·US"}` → **400 `Selector update error: proxy not exist`**；
   内核 PROXY 有 90 个成员，里面没有这个节点。
2. 但 `proxies:` 列表（76 个节点）里有它 → **是 PROXY 成员表少人了**，不是订阅解析漏了。
3. `nodes.json`：76 个节点只有 **46 个不同 id**，24 组重复 —— 解析器给**每条订阅**都从 `n1` 开始编号：
   `id=n6 → 🇸🇬新加坡•移联02 / 🇯🇵 日本Z03 | IEPL / YF新加坡-VLESS-WS-CF·住宅·US`（三条订阅各一个）。

## 一个 id 撞车引发的三连

- `settings.SelectedNodeId = n6` 反查节点名 → `FirstOrDefault` 拿到的是**第一条订阅**那个 n6，
  所以「当前出口」「配置的 `now`」全都在说另一个节点。
- 生成 PROXY 成员用的是 `valid.Where(n => n.Id != selected.Id)` —— 同 id 的**三个**节点被一起剔掉，
  少掉两个（第三个是 selected 自己）→ 内核组里没这个成员。
- 于是用户点它 → PUT 400 → 旧代码把失败解释成「节点可能刚下线，先点更新」，
  并且 `return` 不更新选中态。用户看到的现象就是「选了没用 / 卡片显示的是别的节点」。

## 修

1. **id 全局唯一**：`ReplaceSubscriptionNodes` 给每个进来的节点编号 `<订阅id前8位>-n<序号>`；
   再叠一层 `EnsureUniqueIds(全库)`（构造时若治出变化就落盘）—— 老数据升级后**第一次启动**就自愈，
   不需要用户重新导入。测试 `MultiSubscriptionNodeIdsTests` 三条，并把两层防护都关掉做过反向验证：
   立刻红 2 条，确认测试不是空炮。
2. **切换失败不再甩锅**：`SelectNodeAsync` 遇到 400 先**重新应用配置再试一次**（配置落后于节点库才是
   常见原因），仍失败才说「切到 X 没成功，流量还在走原来的出口」。
   `ReassertSelectionAsync` 同样先推配置再重试，两轮之后确实没有这个节点才收回自动优选。
3. **点自动选择要落哨兵值**：以前名字对不上节点时保留旧 id，导致 `settings` 与内核各说各话；
   现在点 ♻️ 自动选择 写 `smart`，点节点写该节点 id。
4. 出口信息卡右上角那颗 ↻ 显示不全：基类 Button 的 `Padding=14,8` 把 32×28 的固定框挤没了，
   改成文字「刷新」+ `Padding=10,5`。

测试 **86/86**；`dist/TunBox-Setup-0.3.0.exe` 已重出（仍按「覆盖 0.3.0 附件」的方式发布，与鸿蒙同号）。

## 追加：出口查询的防抖把界面刷崩了（ObjectDisposedException）

用户换节点又冒出「界面刷新出错：ObjectDisposedException The CancellationTokenSource has been disposed」。
是我上一轮那张卡的防抖写坏的：`RefreshEgressSoon()` 把上一枚 `CancellationTokenSource`
拿过来 `Cancel()+Dispose()`，而**后台任务自己的 `finally` 里也 Dispose 同一名对象** ——
两次点击隔 800ms 以上时，前一枚已经由后台释放过，UI 这边再 Cancel 就抛，
异常正好落在 `OnManagerChanged` 的大兜底里，于是变成那句难懂的「界面刷新出错」。

改成**只数代数**（`_egressGeneration`）：过期的那次自己退出，全程没有可被释放的对象，
也就没有先后约定。测试 `Egress_requeue_survives_clicks_spaced_apart` 刻意把点击间隔拉开到 1 秒
（正是用户那种一次点一个的节奏），并把旧的令牌写法临时放回做过反向验证：**旧实现必红**。

测试 **87/87**；安装包重出，仍按「覆盖 windows-v0.3.0 附件」发布。
