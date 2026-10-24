# TunBox for HarmonyOS

TunBox 的 HarmonyOS NEXT 移植版（1:1 复刻 upstream Android 版的 UI 与功能）。upstream：`Elegying/TunBox`（MIT），内核 Mihomo（Clash Meta，GPL-3.0）。

## 构建

1. DevEco Studio 5.0+，HarmonyOS NEXT API 12+，真机 arm64。
2. 编译内核（先做一次）：
   ```bash
   # 先用 upstream 原文件覆盖占位桥接层
   cp ../TunBox-upstream/TunBox_Android/native/bridge/bridge.go entry/src/main/cpp/bridge/bridge.go
   OHOS_NDK=/path/to/ohos-sdk/native ./scripts/build-ohos-core.sh /path/to/mihomo-src
   ```
   产物 `entry/libs/arm64-v8a/libgojni.so`。详见 `PORTING_STATUS.md` P1-2。
3. DevEco Studio 打开工程 → File > Project Structure > Signing Configs 配置签名 → Run。
4. 注意事项：
   - `ohos.permission.VPN` 为受限开放权限，需在 AppGallery Connect 申请 ACL。
   - IPv4-only：与 upstream 一致，DNS 不解析 AAAA，TUN 只配 IPv4。
   - 详细剩余工作与移植映射表见 `PORTING_STATUS.md`。

## 目录

- `entry/src/main/ets/pages/` — 三个主页面（主页/订阅/节点编辑）
- `entry/src/main/ets/commons/` — 与 upstream `packages/tunbox_shared` 一一对应的逻辑层
- `entry/src/main/ets/vpnability/` — VPN 扩展能力（TUN、长时任务）
- `entry/src/main/cpp/` — NAPI 内核桥（dlopen libgojni.so）
- `scripts/build-ohos-core.sh` — Mihomo 内核交叉编译脚本

## 许可

本工程代码遵循 MIT（与 upstream 一致）；捆绑的 Mihomo 内核遵循 GPL-3.0，见 `THIRD_PARTY_NOTICES.md`。无遥测、无数据上传。
