# TunBox 内核升级 + 品牌更名记录（2026-10-23）

**范围**：`TunBox-Window`（Windows 客户端）与 `TunBox_HarmonyOS`（鸿蒙客户端），两端同源同版本。
**结论**：内核从停更的 `lux5am/mihomo-smart@8d4c8c70` 换成 `vernesong/mihomo@Alpha 4624551`（= 上游 mihomo **v1.19.33** 稳定代码 + Smart 层）；同轮把 `SSRVPN` 品牌全量改名为 `TunBox`；鸿蒙端修了 3 处 UI，版本上到 **0.5.9 / 523**，两端产物已重新打包，鸿蒙已装真机验收。

本文合并了原根目录 `MIHOMO_SMART_KERNEL_SWAP.md` 的历史结论（该文件已删除，全文仍可用 `git log -- MIHOMO_SMART_KERNEL_SWAP.md` 追溯）。

---

## 0. 前史（2026-09 ~ 10，合并自旧文档）

- **2026-09-19**：内核从 `zeyugao/mihomo@7031b75` 换到 `lux5am/mihomo-smart`，目的是启用内核侧 smart 组（自动选择 / LightGBM）。
- 期间四轮真机反馈驱动补齐：**模型必须内置**（`Model.bin` 随包分发，不能只靠下载）、节点列表里的「♻️ 自动选择」入口、主页显示与测速频率、分组空白 / 手动选不了节点、订阅自带同名组不得混淆。
- 建立起三道回归：`verify-smart-e2e.mjs`（21 项）、`verify-config-validator-kernel.mjs`（37 项）、`verify-config-generation-integrity.mjs`（126 项）。
- 当时的 SSRVPN 集成补丁面（`bridge/`、`cshared_main.go`、`reality_legacy*`、`sniffer`、`tuic v4/v5`、gvisor replace）成为本次迁移的移植基准。

## 1. 为什么换内核

旧内核钉在 `lux5am/mihomo-smart@8d4c8c70faedc27fda176ee18742ab86b5835a83`（2026-07-12）：

| 事实 | 证据 |
| --- | --- |
| lux5am 仓库**已停更** | `git ls-remote` → `refs/heads/Alpha = 8d4c8c70…`；`pushed_at = 2026-07-11`，此后 ~3.5 个月无提交 |
| 旧基线**落后两个安全修复** | `v1.19.30` 修 CVE-2026-56862、`v1.19.33` 修 CVE-2026-97031，均在 `crypto/tls` |
| lux5am 的 smart 层**自身也旧** | 与 vernesong 当前树比：`adapter/outboundgroup/smart.go` +1592/−932，整树 336 文件有差异 |
| 上游稳定版已出 | `MetaCubeX/mihomo` 最新稳定 tag `v1.19.33`（2026-10-21），Alpha 与之同源 |

继续跟 lux5am 只能反复手工 rebase 它的 smart 层，直接换 vernesong 当前树更干净。

## 2. 新基线

| 项 | 值 |
| --- | --- |
| 仓库 / commit | `vernesong/mihomo` @ `Alpha` `462455136157a760937c666bba71afe33b1a809e`（2026-10-22 03:26:22 +0800） |
| 等价内容 | 上游 mihomo **v1.19.33 稳定版代码** + Smart 策略组层（`adapter/outboundgroup/smart.go`、`component/smart/*`、LightGBM 预测） |
| Go 模块 | `github.com/metacubex/mihomo`（`constant.Version` 仍是 fork 惯用的 `"1.10.0"`，不代表上游版本号） |
| 源码树 | `mihomo-build/mihomo-smart-462455136157a760937c666bba71afe33b1a809e/`（1,081 文件） |
| 模型 | `Model.bin` 不变：本地 sha256 `23633022…` 与 vernesong 官方 LightGBM-Model 资产逐字节一致 |

## 3. 迁移做法

**3.1 集成层移植**：以「旧 pristine 树 → 旧集成树」差异为补丁面（24 项）：纯新增 `bridge/{bridge.go,bridge_test.go}`、`cshared_main.go`、`component/tls/reality_legacy*`（4 个）；修改 `reality.go`、`base_sniffer.go`、`tuic v4/v5 packet.go`、`go.mod` 的 gvisor `replace`。
关键：这 4 个被改文件**上游从 8d4c8c70 到 v1.19.33 一行未动**，可直接取已打补丁版本，零三方合并（早先的“冲突”是旧 clone CRLF 的假象）。

**3.2 gvisor 补丁**：`v0.0.0-20251227095601-261ec13` → `v0.0.0-20260922041103-e2cbcd6e7400`，补丁仍只有 1 个 hunk（函数更名为导出的 `IsSocketFD`）：
`unix.Fstat` 失败时 `return false, nil`（HarmonyOS VPN fd 拒绝 Fstat，强制走非 socket Readv dispatcher）。

**3.3 鸿蒙工具链（唯一硬阻塞，已解决）**：本机原无 `GOOS=openharmony` 工具链。
1. 取 `openharmony-sig/ohos_golang_go` 源码 `go1.24.5.ohosv1r1`；
2. 以官方 go1.24.7 windows/amd64 作 `GOROOT_BOOTSTRAP`，`cmd /c make.bat` 重建 → `%USERPROFILE%\ohos-go-build\ohos_golang_go`；
3. NDK 实际为 `%LOCALAPPDATA%\OpenHarmony\Sdk\26.0.0\native`（脚本默认的 `Sdk\23` 已过时，用 `OHOS_NDK` 覆盖）。
（bootstrap 用的临时目录已清理，重跑时重新下载官方 go1.24.7 即可。）

**3.4 品牌更名（同轮完成）**：
- **C ABI**：9 个导出 `Ssrvpn*` → `TunBox*`（`Init/Start/Stop/Version/IsRunning/LastError/InitProtect/SetProtectResult/SetProtectResultForFd` + `VpnExtension`），Go `//export` 与 C++ `dlsym` 字符串同步；产物里已核验 `TunBoxInit` 存在、`SsrvpnInit` 不存在。
- **文件/目录**：`ssrvpn_core_napi.cpp`→`tunbox_core_napi.cpp`、`types/libssrvpn_core_napi/`→`types/libtunbox_core_napi/`、`SsrvpnNotifier.ets`→`TunBoxNotifier.ets`；CMake 目标、oh-package 依赖名、napi 模块名随之改。
- **存储键**：`ssrvpn_{profiles,credentials,subscriptions,settings,theme,form_info,forms}` → `tunbox_*`。
- **一次性迁移代码按用户决定移除**（升级后以空数据重开测），代码中 `ssrvpn` 出现 0 次；设备上旧 `ssrvpn_*` 偏好文件保留未删。

## 4. 产物与钉值

### Windows `TunBox-Window/extra/sidecar/mihomo-smart.exe`

| 项 | 值 |
| --- | --- |
| 大小 / SHA-256 | 61,563,904 B / `26ea5d68d29844b9c4103e1589c8c5a277a0f4e6381473c508964daeff36663f` |
| 构建 | `go1.27.0`，`GOOS=windows GOARCH=amd64`，`-tags cmfa,with_gvisor`，`-trimpath -ldflags "-s -w"` |
| 钉值 | `scripts/prepare.mjs` 的 `MIHOMO_SMART_PINNED_SHA256` 已同步 |
| 注 | 改名后重编仍**字节一致**（注释不影响机器码、`cshared_main.go` 是 `!windows`），钉值无需再动 |

### 鸿蒙 `TunBox_HarmonyOS/entry/libs/arm64-v8a/libgojni.so`

| 项 | 值 |
| --- | --- |
| 大小 | 66,012,000 B（旧 49,297,792，+34%） |
| SHA-256 | 改名后 `5388d922f8e354774c21954e47cbf70b4e17c1608c18150e37fb12fc63a30ea9`（改名前的上游版本为 `DB5A3181…`）；`libgojni.sha256` 已同步 |
| 构建 | OpenHarmony Go `go1.24.5`，`GOOS=openharmony GOARCH=arm64`，`-buildmode=c-shared`，`-tags with_gvisor,cmfa`，`-ldflags "-s -w -buildid="`，NDK 26.0.0 clang（`--target=aarch64-linux-ohos`） |
| ABI | `libgojni.h` 仅 `#line` 变化；9 个 `TunBox*` 导出 |

## 5. 鸿蒙 UI 三处修复（本次）

1. **图标全变**（底栏三图标、测速闪电、刷新、加号）：根因是构建模式 —— 用 `hvigorw --mode module` 默认产出 **debug** 包（`ets/modules.abc` 3.24MB + `ets/sourceMaps.map`），资源/图标渲染与 release 不同。改 `-p buildMode=release`（`modules.abc` 1.97MB）后全部还原。图标 SVG 自 0.4.0（10-18）未改，与旧 0.5.5 包的 34 个媒体资源逐字节相同。
2. **「0 个候选」**：`totalNodes()` 内部读 `this.coreNodes` / `ProfileStore`，ArkUI 定向刷新只登记 build 中**直接读**的 `@State`，方法内读取不算依赖 → 概览卡「24 节点」刷新了、智能优选卡停在首帧显示 0。新增 `@State candidateCount`，在 4 个数据变化点（`reload()`、切 profile 清空、`activateProfile` 拉内核目录、`refreshCoreNodes` 回调）同步，两处文案改读它。
3. **智能优选卡**：删掉行尾圆形闪电测速按钮（订阅行内「测速」入口保留）；说明文案从两行并为一行，最终精简为 **「smart 内核 · 订阅内自动优选 · 24 个候选」**。

## 6. 版本与发布产物

- 鸿蒙 **0.5.9 / versionCode 523**（0.5.7→521、0.5.8→522 的线性规则）；Windows **0.5.1**。

| 产物 | 大小 | SHA-256 | 用途 |
| --- | --- | --- | --- |
| `dist/TunBox_HarmonyOS-0.5.9-release-signed.app` | 30,900,985 B | `42BB4216FB0C61FA9CBE09CCDADA730319DDE4C3617CA44D562EEF69E42ADC83` | AGC 上架 |
| `dist/TunBox-0.5.9-release-signed.hap` | 40,347,453 B | `D62778236142C69DCA9A6EA2E5532E1AE85AF6D83C03D6BBACC32C74E70E4660` | 分发（不可侧载） |
| `TunBox-Window/dist/tunbox-windows-0.5.1-x64-setup.exe` | 210,663,485 B | `61fdea3fcaa48a4145e1a103ccb84ed84a749eda600275e8b3e287b5b5f8066a` | Windows 安装包 |

签名链路：`switch-signing.ps1 -Mode release` → `hvigorw --mode project -p buildMode=release assembleApp`（unsigned .app）→ `sign-nexus-package.ps1 -Kind app`（`General.p12` + `General.cer` + `TunBoxRelease.p7b`，双层签名 + verify-app）。侧载装机则用 `-Mode debug` 构建的 `entry-default-signed.hap`。

## 7. 验证证据

| 门禁 | 结果 |
| --- | --- |
| 新树 Windows 构建 | ✅ 85MB（未 strip）/ 61.5MB（strip），`-v` 自报 `cmfa, with_gvisor` |
| 新树 c-shared arm64 链接（linux/arm64 + NDK） | ✅ 118MB `.so`，证明集成层与新基线兼容 |
| 真实配置解析（smart 组 + `tolerance`） | ✅ `test is successful`，0.1s，未触发 Model.bin 下载 |
| `TunBox-Window` typecheck / vitest | ✅ 三套全过 / 38 文件 642 用例全过 |
| `prepare.mjs` | ✅ `reused from local build (sha256 26ea5d68…)` |
| `verify-smart-e2e` / `verify-config-validator-kernel` / `verify-config-generation-integrity` | ✅ 21 / 37 / 126 passed |
| `verify-types` / `verify-build-profile` | ✅ PASS / 13 项全过 |
| `verify-all` | ✅ 60 PASS / 1 既有失败（`verify-subscription-fidelity` 缺 fixture，与内核无关） |
| 树完整性 | ✅ 与 `vernesong@4624551` 逐文件比对，差异只有集成层，无一行 lux5am 代码 |
| 真机（192.168.10.3:39933） | ✅ 0.5.9/523 安装成功、冷启动正常、24 节点测速、自动选择「24 个候选」、VPN 已连接（`香港·移联02`）、图标正确、测速按钮已移除 |

## 8. 行为变化与风险

1. **TUN 默认 IP 栈由 `gvisor` 变 `mips`**（上游 v1.19.32 起），两端都没显式钉 `stack:`，跟随新默认；要回退可在生成侧写 `stack: gvisor`。
2. **`.so` +34%**（49.3→66.0MB），HAP 33→40MB；Windows exe 反而变小（66.2→61.6MB）。
3. **新协议 App 侧白名单未放开**：shadowquic / zerotier / easytier / jls / restls / shadowtls 仍会被丢弃（与升级前一致，非回归）。
4. **smart 层落盘改 bbolt**，旧智能缓存不复用，首启重建。
5. 候选数显示的是「当前订阅全部节点」（含机场信息条伪节点）；内核 `exclude-filter` 会剔除它们，实际候选可能更少（本次订阅 24 显示 / 22 实际）。

## 9. 复现步骤

```powershell
# Windows 内核
cd C:\Worker\TunBox\mihomo-build\mihomo-smart-462455136157a760937c666bba71afe33b1a809e
$env:GOFLAGS='-mod=mod'
go build -trimpath -tags "cmfa,with_gvisor" -ldflags "-s -w" -o mihomo.exe .
# 拷到 TunBox-Window\extra\sidecar\mihomo-smart.exe（字节一致时钉值无需改）

# 鸿蒙内核
$env:MIHOMO_SRC='C:\Worker\TunBox\mihomo-build\mihomo-smart-462455136157a760937c666bba71afe33b1a809e'
$env:OHOS_NDK="$env:LOCALAPPDATA\OpenHarmony\Sdk\26.0.0\native"
$env:OHOS_GOROOT="$env:USERPROFILE\ohos-go-build\ohos_golang_go"
powershell -ExecutionPolicy Bypass -File C:\Worker\TunBox\TunBox_HarmonyOS\scripts\build-ohos-core.ps1

# 鸿蒙装机包（release 构建 + debug 签名侧载）
powershell -File C:\Worker\TunBox\switch-signing.ps1 -Mode debug
hvigorw --mode module -p module=entry@default -p product=default -p buildMode=release assembleHap --no-daemon
hdc install -r TunBox_HarmonyOS\entry\build\default\outputs\default\entry-default-signed.hap
powershell -File C:\Worker\TunBox\switch-signing.ps1 -Mode release   # 用完还原

# AGC 发布包
hvigorw --mode project -p product=default -p buildMode=release assembleApp --no-daemon
$env:NEXUS_KEY_PASSWORD='<见 skills/nexus-pack>'; powershell -File C:\Worker\TunBox\sign-nexus-package.ps1 -Kind app
```

## 10. 收尾状态

- 已打包（.app / .hap / setup.exe 见第 6 节）、鸿蒙已真机验收；**Windows 安装包未在真机装过**。
- 代码与文档改动**未提交、未推送**（工作区约 1500 条变更，主要是内核树替换 + 改名）。
- 后续：新协议白名单放开、候选数是否按内核口径过滤、`stack: mips` 真机对比。
