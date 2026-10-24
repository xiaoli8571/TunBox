# TunBox for HarmonyOS（鸿蒙 NEXT）  已正式上架，应用商店切外区下载。

Nexus 是一款鸿蒙 NEXT（纯 ArkTS）原生 VPN 客户端，内核采用 **Mihomo（Clash Meta）** 以
`c-shared` 库形式进程内嵌入，通过 `VpnExtensionAbility` + TUN（gVisor 用户态协议栈）
实现全局代理。品牌包名 `com.tunbox.client`。

> ⚠️ 本项目仅供学习与技术研究。使用者需自行遵守所在地法律法规及所用网络服务条款。
> 仓库内 HAP 为**未签名**产物，不能直接安装，需自行签名（见下文）。
> 欢迎加入交流群：https://t.me/+x9D290Stp9NhYWU9


## 主要能力

- 订阅管理：订阅/节点链接导入、扫码导入、本地 YAML 文件导入、base64/明文解析、
  更新与去重、导入后订阅卡即时上屏
- 订阅分组：手风琴展开/收起（记住状态）、分组标题栏改名/删除/单个刷新、
  节点按延迟实时排序（边测边排）
- **内核智能选点（自动选择分组）**：mihomo-smart LightGBM 跨全部订阅优选出口，
  故障自动切换 + 断网自动重连
- 测速：32 路并发、3 秒超时、组测一次请求测全部、延迟配色对标主流客户端
  （<300ms 绿 / 300~800ms 橙 / ≥800ms 红）
- 连接编排：`VpnExtensionAbility` 创建 TUN，进程内加载 `libgojni.so`（Mihomo）并启动内核；
  状态环启动按钮 + 已连接呼吸动效
- **防杀进程**：连接成功后注册 dataTransfer 连续任务（App 内手动连接与卡片路径同款守护），
  UI 进程退后台不再被系统回收
- **被后台杀掉后自动自愈**：用户连接意图先于拉起落盘，冷启动 / 回前台检测到「意图仍为
  连接但隧道已消失」即自动重建；卡片守护者丢失会话租约时先自愈重连（退避重试）而非直接放弃
- **会话守护与自愈**：订阅网络切换自动重连、内核崩溃就地热恢复、
  连续失败自动切换节点、链路自检
- 防回环：`connection.protectProcessNet()`（API 22+）保护内核自身 socket，避免自连死循环
- **DNS 防泄露**：业务解析全部走加密 DoT（境内 AliDNS/DNSPod 为 primary，境外仅在
  非 CN 应答时由 Cloudflare 兜底），明文 UDP/53 已退出业务解析路径；DNS 仍直连不改路由，
  以保证国内 CDN 调度正确；fake-ip 模式 + TUN `dns-hijack any:53`（常开）；
  连接前 UI 进程 DoH（doh.pub/alidns）预解析节点入口域名写入 YAML `hosts:`，
  规避国内 UDP DNS 投毒，结果跨进程落盘（第二次连接零网络等待）
- 代理模式：智能（规则分流大陆与境外）/ 全局，已连接时热更新不重建隧道
- 规则：HyperADRules 去广告（**默认关闭**，需在「规则」页自行开启；开启后每日自动更新
  MRS 规则集）、自定义规则、强制代理 / 强制直连站点、应用分流（绕过/仅代理名单）
- 配置备份与恢复：订阅、节点、代理组、隐藏名单与全部设置一键导出/导入 JSON
- 诊断与运行日志：订阅页「日志」→ 居中弹窗，诊断项检查、分级运行记录、
  双轨 provider 开关（订阅原文以 `proxy-providers` 交给内核自行解析）、技术明细（已脱敏）
- 主题：深浅色全适配，右上角一键切换
- 桌面服务卡片：2×2 快捷开关、2×4 信息卡片

## 仓库结构

```
Nexus-VPN-HarmonyOS/
├── TunBox_HarmonyOS/             # HarmonyOS 工程（ArkTS + 原生 NAPI + 内核库）
│   ├── entry/
│   │   ├── libs/arm64-v8a/libgojni.so   # 交叉编译好的 Mihomo 内核（c-shared）
│   │   ├── src/main/ets/                # ArkTS：UI / 服务 / VpnExtensionAbility
│   │   ├── src/main/cpp/                # NAPI 桥（dlopen libgojni.so）
│   │   └── src/main/module.json5        # 声明 VpnExtensionAbility
│   ├── scripts/build-ohos-core.{ps1,sh} # 重编内核的交叉编译脚本
│   └── build-profile.json5 / AppScope/
├── mihomo-build/                # Mihomo Go 源码（含 smart 内核 + bridge 改动）
├── Nexus-Logo/                  # 品牌视觉资产
└── sign-nexus-package.ps1       # release 包签名脚本（证书不入库）
```

## 构建 HAP（拉取即可构建）

前置：安装 DevEco Studio（含 OpenHarmony SDK 与自带 JDK）。

```powershell
cd TunBox_HarmonyOS
# 先安装依赖
& 'C:\Program Files\Huawei\DevEco Studio\tools\ohpm\bin\ohpm.bat' install

$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'   # 必须是 sdk 目录本身
$env:JAVA_HOME       = 'C:\Program Files\Huawei\DevEco Studio\jbr'
$env:Path            = "$env:JAVA_HOME\bin;$env:Path"
node "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" `
  --mode module -p product=default -p module=entry@default -p buildMode=release `
  assembleHap --no-daemon
```

产物：`entry\build\default\outputs\default\entry-default-unsigned.hap`（未签名）。

也可用命令行出 .app（上架包）：

```powershell
node "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js" `
  --mode project -p product=default -p buildMode=release assembleApp --no-daemon
```

## 签名与安装（未签名 HAP → 可安装）

未签名 HAP **无法直接安装**，需签名。任选其一：

1. **DevEco Studio**：File → Project Structure → Signing Configs → 勾选 Automatically
   generate signature（登录华为账号），然后 Build → Build Hap(s)。
2. **本仓库签名脚本**（release 包 + 两层 verify，需自备 AGC 证书材料）：

```powershell
$env:NEXUS_KEY_PASSWORD = '<你的keystore密码>'
powershell -ExecutionPolicy Bypass -File sign-nexus-package.ps1 `
  -SourceRepo <仓库根> -Kind app    # 或 -Kind hap
```

安装（开启 USB 调试 / 无线调试后）：

```powershell
hdc install -r entry-default-signed.hap
```

## 重新编译内核（可选）

`entry/libs/arm64-v8a/libgojni.so` 已随仓库提供，正常打包无需重编。若要改 Go 层内核：

```powershell
# 需要 OpenHarmony 版 Go 工具链(GOOS=openharmony) + DevEco native SDK
powershell -ExecutionPolicy Bypass -File TunBox_HarmonyOS\scripts\build-ohos-core.ps1
```

关键环境变量（脚本会读取，缺省用相对仓库根的路径）：`MIHOMO_SRC`、`DEVECO_NATIVE_SDK`、
`OHOS_GO_ROOT`、`PROJ_ROOT`。链接阶段约占 4GB 提交内存。详见 `BUILD_README.md`。

## 内核与平台关键实现点

- **c-shared ABI**：`cshared_main.go` 导出 `NexusInit/Start/Stop/IsRunning/Version/LastError`，
  由 `ssrvpn_core_napi.cpp` 以 `dlsym` 加载。
- **TLS 模型**：OHOS 下 CGO 需 `-ftls-model=global-dynamic`，否则运行期 TLS 重定位失败。
- **gvisor fd 注入**：`tun` 用 `stack: gvisor` + 文件描述符注入（`FileDescriptor`），配合
  对 `gvisor` 的 `fdbased.isSocketFD`（`Fstat` 失败回退）补丁，规避沙箱无 `iptables` 的限制。
- **日志重定向**：内核 stdout/stderr 经 `dup3` 重定向到 `core.log`，供诊断弹窗「技术明细」读取。
- **代理服务器解析**：`pinProxyServerHosts` 预解析代理域名写入 hosts，避免 fake-ip 把代理
  服务器域名解析成假地址导致拨号超时；`interface-name` 绑定物理网卡防回环。
- **smart 内核组**：mihomo-smart 系 fork 独有的 `smart` 代理组（LightGBM 按连接目标优选出口），
  支持 `policy-priority` 按节点名加权；当前基线为 `vernesong/mihomo@Alpha`（= 上游 v1.19.33 + Smart 层）。

完整进度/规格见 `TunBox_HarmonyOS/PORTING_STATUS.md`、`SPEC.md`。

## 致谢 / 许可

- 内核：[MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo)（GPL-3.0）及
  [vernesong/mihomo](https://github.com/vernesong/mihomo) smart fork（smart 组 + LightGBM 优选）
- 参考实现：NekoBox4Harmony、Hey 等同平台移植项目
- 集成 Mihomo 须遵守 GPL-3.0（提供内核源码构建方式，见 `mihomo-build/`）；
  其余代码遵循 MIT 许可
