# 测速启动、ikuuu 通道与结果显示修复（2026-11-04）

## 用户反馈与本轮约定

- 点击测速后等待较久；0.8.1 的 ikuuu 反复提示「测速通道未就绪」。
- 节点拨号失败统一显示「超时」。已执行但测不出结果的节点同样显示超时。
- 完成提示只显示 `测速完成：xx成功，xx超时`。
- 主动取消、切换订阅与整条通道失联仍独立处理，保留上次结论。

## 真机根因

设备 MLR-AL00，连接地址 `192.168.10.8:39933`，原安装版本 0.8.1 / 559。

独立测速结束后，UI 进程的 REST controller 仍监听 19090。后续 Extension 测速内核选中了同一端口。
原有端口检查只有 `listen()`，未排除已经接受连接的服务。

原始日志反复出现：

```text
10:09:16.740 External controller listen error: listen tcp 127.0.0.1:19090: bind: address already in use
10:09:29.926 ensureTestCore failed; negative cache 45000ms
10:09:31.429 delay batch failed: 测速通道未就绪，请稍后重试
```

本轮没有修改 Go 内核：修正应用层端口分配与就绪判定，避开仍占用的 controller。
独立 core 的旧 controller 生命周期仍由现有内核实现管理；再次启动该进程的 core 会替换自己的旧监听。

## 改动

1. `LocalPortProbe` 先尝试连接回环端口，再验证能否绑定；主测速核和独立测速核共用。
   候选端口都占用时直接报错，不再退回已占用端口。
2. controller 携带本次凭证返回成功即可放行，移除旧 HTTP 连接池留下的固定 1 秒预热补偿。
   401/403 直接识别为其他 controller，不再一直轮询。
3. 通道入口自身已经等待 single-flight 启动结果，移除调用方失败后的 1.5 秒重试睡眠。
4. 全量节点目录只获取一次，恢复分组选择和生成测速计划共用同一快照。
   没有旧扩展存活证据时，不因 stop API 返回成功而多等 600ms。
5. 启动静默准备通道由延迟 4 秒提前为 1 秒；只准备通道，不自动测速。
6. 单个 TCP 请求没有有效响应时，在批次收尾复探 controller；若仍健康且批次未取消，
   把该批仍在测试中的目标补记为超时。controller 失联、取消或订阅变化保留旧结论。
7. 拨号与 DNS 探测失败的节点徽标统一显示超时，内部失败原因继续保留供诊断使用。
   订阅面板与节点页统一使用成功/超时两项完成提示。

## 真机验收

| 场景 | 结果 |
|---|---|
| 已连接 ikuuu 时对 Nexpanel 独立测速 | 207ms 发出请求，5 成功；当前订阅和 VPN 不变 |
| 独立测速后断开 VPN，保留 UI 进程 19090 监听，再测 ikuuu | 新测速核监听 29090，正常出结果，未复现通道未就绪 |
| 最终包，已准备好通道后点 ikuuu 测速 | 两批 prepareMs 分别为 866ms、798ms |
| 最终包，缺少个别 TCP 响应 | 本批 4 个缺响应目标经 controller 健康复核后补为超时，cancelled=0 |
| 最终包完成提示与列表 | `测速完成：34成功，13超时`；底部失败节点均显示超时 |

最终一批设备时序（点击起点取 ArkUI 接受事件，未用 shell 发命令时间）：

```text
10:37:05.068 CLK RACC, T: Stack
10:37:05.868 delay dispatch: targets=47 isolated=false prepareMs=798
10:37:09.939 delay response missing: controller healthy; 4 targets timed out
10:37:09.940 delay batch done: total=47 measured=34 timeout=12 failed=1 cancelled=0
```

47 是测速目标数（包含该组可测的 DIRECT），卡片的 46 是代理节点数量。
UI 超时数为内部 timeout + failed，即 12 + 1 = 13。
以上约 0.8 秒为热通道结果，首次冷启动仍需生成配置并启动扩展，不能当作热通道耗时。

## 构建与验证

最终命令：

```powershell
hvigorw.bat --mode module -p module=entry@default -p product=default -p buildMode=release -p debugLine=false clean assembleHap --no-daemon
```

- 最终 `BUILD SUCCESSFUL`，34 个任务实际执行，2min 656ms。
- 17 组相关回归脚本确认通过；其中缓存和核心分类的旧文案断言按本轮用户口径更新后单独重跑通过。
- 资源编号门禁 4/4、构建配置门禁 13/13、HAP 身份门禁通过。
- 使用本机 DevEco device profile 临时签名；构建后已恢复项目空 signingConfigs。
- 首次构建发现工作区 `libgojni.so` 被截断，已从原 559 device HAP 恢复完整同版本库，
  SHA256 为 `D8CEC577DC79A076F2AFC494DAD549060E691C34BDFE58D054DFEC089D007282`，同步修正 sha256 文件。

最终装机包：`C:\Worker\TunBox\dist\TunBox-0.8.1-559-latency-device-signed.hap`。

SHA256：`3E589DF6736981C6FABCCE40A7371600492C96086DA495C29C05EBDCE08B979B`。

已覆盖安装并保留订阅和设置，版本仍为 0.8.1 / 559。此文件是本机验证候选包；未上传 AGC 或 GitHub。
