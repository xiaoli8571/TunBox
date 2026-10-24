# START HERE — 给 DevEco Studio Agent 的接续说明

> 你（Agent）在本工程内的任务：继续完成 TunBox 的 HarmonyOS 移植。
> 本工程 **已经可以完整编译出 HAP**（ArkTS + 原生 NAPI 全部通过，BUILD SUCCESSFUL）。
> 开始任何修改前，先读完本文件和 `PORTING_STATUS.md`（真实进度账本）、`SPEC.md`（完整规格书：§1.4 功能清单、§1.5 UI 色值、§4 验收标准）。

## 工程现状（一句话）

TunBox（Flutter/Mihomo 客户端，upstream 在 `..\..\TunBox-upstream\`）已按 ArkTS + ArkUI（Stage 模型）1:1 移植出可编译骨架：
三个页面 + widgets + 订阅解析/UA 协商/配置生成/Clash API/连接编排/国家策略等逻辑层 + VpnExtensionAbility（真实 vpnExtension API）+ NAPI 内核桥 + 服务卡片 + zh/en 资源。

## 构建（命令行已验证，DevEco IDE 内直接 Run 即可）

```powershell
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
$env:Path = 'C:\Program Files\Huawei\DevEco Studio\jbr\bin;' + $env:Path   # 打包需要 java
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' --mode module -p module=entry@default -p product=default assembleHap --no-daemon
```

- 产物：`entry\build\default\outputs\default\entry-default-unsigned.hap`
- SDK 基线：API 26（`compatibleSdkVersion: "26.0.0"`，**不要**写成 `6.0.0(21)` 这类带括号格式，hvigor 会校验失败）
- 权限：`ohos.permission.MANAGE_VPN`（本 SDK 中 VPN 权限的真实名称，`ohos.permission.VPN` 不存在）

## 最优先的下一步（按顺序）

1. ~~内核 libgojni.so~~ **已完成**，且**已换成 lux5am/mihomo-smart 内核**：`entry\libs\arm64-v8a\libgojni.so`
   （46.9MB，ELF64 AArch64，SHA256=F197E5F7…F01F63F）已就位。
   仅当需要改 Go 内核代码时才重编：`powershell -ExecutionPolicy Bypass -File scripts\build-ohos-core.ps1`
   （脚本会在 `mihomo-build\mihomo-smart-*` 中自动选中内核源码树，GOPROXY 已设为 goproxy.cn；
   链接期约需 4GB+ 提交内存，脚本已用 `-p 1`）。换内核的完整记录见 `docs/KERNEL_UPGRADE_2026-10-23.md`。
2. **真机冒烟**（需先在 File > Project Structure 配置签名）：订阅导入 → 连接 → Clash API 9090 → TUN 流量 → 断开/恢复。
3. **P2 功能补全清单**：见 `PORTING_STATUS.md`「剩余工作」P2-4 至 P2-16（设置页、批量测延迟、apiSecret 加密、连接快照、开机自启、应用分流、通知速率、撤销 UI、更新检查、崩溃报告、启动编排、内核恢复策略）。
4. **P3 质量项**：hypium 单测、THIRD_PARTY_NOTICES 补 ohos 构建来源、对照 SPEC §1.5/§4 逐项复核。

## 硬性规则

- 所有修改保持 ArkTS 严格模式合规（无 any/unknown、无 @ts-ignore、对象字面量必须有显式类型、List 子组件必须 ListItem）
- 修改后必须重新执行上面的构建命令直到 BUILD SUCCESSFUL，再对照 `PORTING_STATUS.md` 打勾更新
- upstream 目录只读，不要改
- 不许留 TODO、不许占位实现

## 关键文件地图

| 文件 | 职责 |
|---|---|
| `entry/src/main/ets/vpnability/VpnExtensionAbility.ets` | VPN TUN 建立（vpnExtension.create→fd）→ 注入内核 |
| `entry/src/main/ets/core/CoreBridge.ets` + `cpp/tunbox_core_napi.cpp` | ArkTS ↔ libgojni.so 的 NAPI 桥（dlsym 符号见 cpp/types/） |
| `entry/src/main/cpp/bridge/bridge.go` | Go 桥占位说明（真实 bridge 包在 mihomo-build 源码树内） |
| `entry/src/main/ets/commons/services/ConnectionOrchestrator.ets` | 连接状态机：写配置→拉起 VPN→等 Clash API→选节点 |
| `entry/src/main/ets/commons/services/` 其余 | 订阅解析/UA 协商/配置生成/设置/公网IP/国家策略 |
| `entry/src/main/ets/pages/` | 主页/订阅/节点编辑 |
| `scripts/build-ohos-core.ps1` | 内核交叉编译脚本（本机已验证路径） |
