# Third-Party Notices

本工程为 TunBox 的 HarmonyOS 移植。upstream 项目的第三方声明（`TunBox-upstream/third_party/THIRD_PARTY_NOTICES.md`）在此整体适用，包括其中登记的 Mihomo 内核与 GeoIP 数据的 GPL-3.0 许可与来源记录。

鸿蒙移植新增/替换的第三方来源：

- **Mihomo 内核 (libgojni.so)** — 鸿蒙端内核
  - 上游模块：`github.com/metacubex/mihomo`
  - **内核分支**：**[vernesong/mihomo](https://github.com/vernesong/mihomo)，分支 `Alpha`，commit `462455136157a760937c666bba71afe33b1a809e`**（= 上游 mihomo `v1.19.33` 稳定版代码 + Smart 策略组层；已弃用停更的 lux5am/mihomo-smart）
  - 许可：GPL-3.0
  - 源码树：仓库内 `mihomo-build/mihomo-smart-462455136157a760937c666bba71afe33b1a809e/`，
    已含 TunBox 集成层（`bridge/`、`cshared_main.go`、REALITY legacy 协商补丁、
    sniffer/tuic 补丁、`replace .../gvisor => ../gvisor-patched`）——
    构建期不注入任何文件，`go build` 该目录即可复现产物。
  - **鸿蒙构建（已验证，2026-10-23）**：
    - 方式：`scripts/build-ohos-core.ps1`（c-shared，GOOS=openharmony GOARCH=arm64 + OHOS NDK 26.0.0 clang，
      `-tags with_gvisor,cmfa`，OpenHarmony Go 1.24.5，GOPROXY=goproxy.cn）
    - 产物：`entry/libs/arm64-v8a/libgojni.so`（ELF64 AArch64，62.9MB / 66,012,000 bytes）
    - SHA-256：`DB5A3181EA782F057D56CCD07291E19931FC9105E0E53346701C1CD4B59F94AD`（另见 libgojni.sha256）
    - 生成的 C 头 `libgojni.h` 与前一版内核仅 `#line` 指令不同（导出 ABI 未变）
    - 包装层：内核源码树内 `cshared_main.go`（导出 TunBoxInit/TunBoxStart/TunBoxInitProtect/
      TunBoxSetProtectResult/TunBoxSetProtectResultForFd/TunBoxStop/TunBoxIsRunning/TunBoxVersion/TunBoxLastError）；
      `bridge` 包为 upstream 原文件 `TunBox_Android/native/bridge/bridge.go`（含 bridge_test.go）
    - 与 upstream Android 的差异：upstream Android 经 gomobile bind（bionic libc，android 目标）
      且内核为 `zeyugao/mihomo@7031b75`；鸿蒙为 musl libc，改用 c-shared 直连方案，
      内核已按需求替换为 mihomo-smart，ABI 见 `entry/src/main/cpp/tunbox_core_napi.cpp` 的 dlsym
  - 对应源码获取方式：按 GPL-3.0 要求，任何分发的 HAP 须同时提供（或指明获取途径）libgojni.so 的
    对应源码（`vernesong/mihomo@4624551` + `bridge/` + `cshared_main.go` + `component/tls/reality_legacy*` +
    构建脚本）。换内核的完整审计记录见 `docs/KERNEL_UPGRADE_2026-10-23.md`。

- **gVisor（用户态协议栈，仅 TUN 的 gvisor stack 使用）**
  - 模块：`github.com/metacubex/gvisor`，版本 `v0.0.0-20260922041103-e2cbcd6e7400`
  - 许可：Apache-2.0
  - 源码树：`mihomo-build/gvisor-patched/`（相对同版本原始模块只改 1 处：
    `pkg/tcpip/link/fdbased/endpoint.go` 的 `IsSocketFD`，HarmonyOS VPN fd 拒绝 `Fstat`
    时回退到可移植的 Readv dispatcher，而不是直接报错）

- **upstream Android 版内核（仅作对照，不参与鸿蒙构建）**
  - `zeyugao/mihomo@7031b7569831677a8d89ad8a8a3347db116ba1a8`，见 upstream
    `TunBox_Android/assets/libgojni-source.txt`；鸿蒙端已不再使用。
