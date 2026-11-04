# 2026-11-03 全面复查：在线重启与转换导出

版本：0.8.1（559）。本轮遵循用户最新要求：连接中选择节点/子组，或切换规则、全局、直连模式，都完整重启代理。此前文档中的“优先热切”“直连不重启”是历史实现，不再代表当前行为。

## 修复

| 问题 | 当前行为 |
| --- | --- |
| 同一订阅选点、模式切换仍可能只 PUT 内核，未执行用户要求的重启 | 节点页、订阅面板、主页模式切换统一进入重启协调器，停止旧会话后生成新配置并重建代理。 |
| 选子组后面板的父组可能覆盖真正的流量出口，宽泛兜底还会把无关组改成 DIRECT | 移除面板热切及 `pinTrafficExit` 兜底；保存所选父子关系及 preferred group intent，再走已有的完整配置生成/启动选点链。 |
| 模式改变后使用旧节点快照，丢失“台湾手动”等子组意图 | 重启优先解析已保存的选组意图，再考虑原会话节点；直连作为本次启动参数传入，在线换节点时保留当前模式。 |
| 连续选择、切模式、停止操作竞争，旧任务可能重新拉起代理 | 重启代次、连接序列和 profile 内容修订联合校验；最后一次请求生效，显式停止取消等待中的重启；预检查失败不拆旧连接。 |
| 选点后主页等待连接完成才更新，失败仍显示成功 | 保存后立即触发选点刷新；出口 IP 只在连接成功后刷新；重启失败显示实际失败，旧模式操作不能覆盖新操作的提示。 |
| VPN 重启清零 protect 回执编号，旧会话迟到回执可能误授权新会话同 fd | 回执编号进程内单调递增，不再随会话清零；编号耗尽拒绝拨号，不循环复用。已重新编译 ARM64 Go 库。 |
| 转换功能只能直接导入 | 转换页提供“直接导入 TunBox”和“导出 YAML 文件”，默认直接导入。两条路径共用转换结果；导出打开系统保存器，取消不创建订阅。 |
| 导出需保证可用配置与完整落盘 | 分享链接转换后补齐选择组及 MATCH；已有 Clash YAML 保留原文；8 MiB UTF-8 大小限制，循环处理部分写入，fsync/close 成功后才提示已保存。provider-only 导入成功不误报“0 节点失败”。 |

## 验证

- `verify-selection-restart-runtime.mjs`：21 个生产代码运行场景通过，覆盖在线选点、三模式、直连保持、已保存子组、连续请求、显式停止、配置变化、预检查失败、启动失败、离线选择、冷接管与主页并发操作。平台资源执行由桩替代，不等同于真机网络验收。
- `verify-conversion-output-runtime.mjs`：14 个生产处理器场景通过，覆盖直接导入、原文导出、UTF-8/部分写入、Base64、订阅 URL、取消、写入/保存器失败、大小限制、provider-only、空导入结果及防重复。转换后的配置通过本机 Mihomo `-t` 校验。
- `verify-proxy-panel-members.mjs`：17 项；`verify-latency-scope-runtime.mjs`：18 项；`verify-app-routing.mjs`：74 项通过。
- `verify-headless-socket-bind.mjs`：实际 Go 钩子/回执策略通过，新增跨会话迟到回执及编号耗尽用例；`go test -count=1 ./dns ./component/loopback` 通过（loopback 无测试文件）。
- 全量非打包门禁首跑 86 个脚本：81 PASS、2 FAIL、3 SKIP。旧 provider 断言已改为当前重启契约，复跑通过；用户 YAML fixture 和 Windows Mihomo 路径补齐后，订阅保真 17 项及 FlClash profile 真实内核校验通过。加上本轮新增转换门禁，合计 85 PASS、2 SKIP。两项跳过为可选 ArkTS 分支和需要真实 Smart 活动连接抓包的门禁，不作为已通过。
- 转换改动后再次通过括号、节点卡片、面板门禁。最终验收以 DevEco 的真实 ArkTS/C++ 编译为准；轻量 linter 的 SDK 解析限制不能替代真实编译。

## 构建、签名与装机

最终命令（DevEco 自带 Node 和 hvigorw.js）：

```text
hvigorw.js --mode module -p module=entry@default -p product=default -p requiredDeviceType=tablet -p buildMode=release clean assembleHap --no-daemon
node scripts/verify-ui-resource-bindings.mjs
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-signing-identity.ps1 -HapPath entry/build/default/outputs/default/entry-default-unsigned.hap
powershell -NoProfile -ExecutionPolicy Bypass -File ../sign-nexus-package.ps1 -Kind hap
```

用户最后明确要求：只负责装机、打包 APP 和 HAP，功能测试由用户自行完成。因此停止设备 UI/网络验收，交付本次发布签名 APP/HAP 和用于侧载的设备调试签名 HAP；不提交或推送代码。

实际结果：

- release HAP 清理构建成功，1 分 57 秒；资源编号门禁四项 PASS：`ic_dashboard=16777396`、`ic_chart=16777391`、`ic_settings=16777414`、`ic_power=16777408`。
- 发布签名包通过校验，但设备拒绝 store profile 直接侧载（9568322）。随后通过既有 `switch-signing.ps1 -Mode debug` 临时使用本机 DevEco 设备签名，以同样的 `buildMode=release clean assembleHap` 构建装机包，1 分 41 秒成功。`build-profile.json5` 原始字节在 finally 中恢复，签名材料护栏 13/13 通过；未把本机签名材料留在源码中。
- `hdc -t 192.168.3.146:39933 install -r .../TunBox-0.8.1-559-device-signed.hap` 返回 `install bundle successfully`。`bm dump -n com.tunbox.client` 确认 `versionName=0.8.1`、`versionCode=559`、`debug=false`、`appProvisionType=debug`。未卸载或清空数据，未继续设备功能测试。
- APP 通过 `hvigorw.js --mode project -p product=default -p requiredDeviceType=tablet -p buildMode=release clean assembleApp --no-daemon` 构建，1 分 5 秒成功；紧接着四项资源编号校验通过。`sign-nexus-package.ps1 -Kind app` 完成内层 HAP 与外层 APP 的签名及验签，并同步独立发布 HAP。
- APP 内嵌 HAP 与独立发布 HAP 的 SHA-256 完全一致。最终发布 HAP 与已安装的设备 HAP 有 54 个代码/资源/模块描述条目逐字节一致，剩余 `pack.info` 仅 JSON 缩进不同，解析后内容相同。
- 原始 Go 库与构建拷贝哈希一致；HAP 中的库与本次 release strip 产物一致（strip 会改变库文件哈希）。包内库 SHA-256：`D8CEC577DC79A076F2AFC494DAD549060E691C34BDFE58D054DFEC089D007282`。已签名包的 DNS 字节码门禁与最终包身份门禁均通过。

产物位于 `C:\Worker\TunBox\dist`：

| 文件 | bytes | SHA-256 |
| --- | ---: | --- |
| `TunBox_HarmonyOS-0.8.1-release-signed.app` | 23533824 | `ACBD2761CC19C3F5E0EDAA83002D8B79B94578DB285B0CFE02FF6096C7D7069E` |
| `TunBox-0.8.1-release-signed.hap` | 25484591 | `B894B2CF66376B42BB5627BBF4A411F1F02228B58C2B79BC07D57B72D92371B2` |
| `TunBox-0.8.1-559-device-signed.hap`（已安装） | 25484771 | `CDE1DE8F3270DB48165D498D285D3601B873715D30450F5DDCFE9990A40567E1` |

收尾已执行清理脚本的 `DRY_RUN=1`，发现其全局前缀会覆盖其他任务的临时产物，故尝试缩小为已核实的本轮 `tunbox-probe-rereview*` 路径。自动审批策略拒绝删除；进一步缩小为本轮普通文件、取消递归删除后仍返回 `blocked by policy`，未给出更具体原因。临时文件和设备布局文件尚未删除，正式产物不受影响。保留其他任务、原有未提交改动及正式回归脚本。

## 验收边界

本地运行回归和真实内核校验覆盖配置、选点、重启与转换契约；用户机场延迟、出口地区、蜂窝切换、长时后台及 Smart 活动链路需要相应设备条件，不能由主机 loopback 或 UI 名称推断成功。
