# Wi-Fi / 蜂窝网络差异审查（2026-11-02）

## 范围与证据等级

- 本轮由主代理独立审查，没有子代理；未修改业务源码、未构建、未安装、未提交。
- TunBox 当前源码：仓库最近的 HarmonyOS 提交为 `adbd697` / 0.8.0 发布记录；当前 HarmonyOS 工作树无业务修改。
- 对照：本机 `C:/Worker/REA/flclash_re/repo` 的 FlClash OHOS 源码（`a2e8f13`，2026-10-21）；另读 `C:/Worker/REA/flclash-dart/flclash-src/android` 本地源码快照。后者不是可验证 git checkout，不把它当已发布版本。
- `hdc list targets` 返回 `[Empty]`：没有真机切网、吞吐、耗电、IPv6 泄漏抓包证据。
- 离线复现采用 Node 24 `stripTypeScriptTypes` 执行生产 `.ets` 的真实方法，替换 SDK、时钟、定时器边界；不等同于真机。

## 当前 Wi-Fi / 蜂窝差异

| 项目 | Wi-Fi | 蜂窝 |
|---|---|---|
| 新会话初始 MTU | 1400 | 1360 |
| 配置生成缺省 | 两者都先生成 `tun.mtu: 1400` | 扩展启动前再改为 1360 |
| DNS / 规则 / 节点 / IPv6 开关 | 共用同一配置链 | 没有蜂窝专用默认 DNS、节点或 IPv6 策略 |
| 切换承载 | MTU 不同则计划重建 TUN | 相同 |
| MTU 不变或重建预算耗尽 | 网络类型变化计划重启整个 Core | 相同 |
| socket 绕过 VPN | protectProcessNet + 逐 fd protect 回执 | 相同 |

关键位置：
- `entry/src/main/ets/commons/services/VpnRecoveryPolicy.ets`：BASE_MTU=1400、CELLULAR_MTU=1360、MAX_TUNNEL_REBUILDS=2。
- `entry/src/main/ets/vpnability/VpnExtensionAbility.ets`：onNetworkTypeChanged、scheduleTunnelRebuild、rebuildTunnel、recoverCore、ensureConfigMtu。
- `entry/src/main/ets/commons/services/ClashConfigGenerator.ets`：默认 DNS 与 tun 配置。

MTU 1360/1400 是保守常量，不是实际读取底层链路 MTU 后算出的 PMTU。不能只凭常量推断蜂窝必然更慢，也不能把其他客户端的虚拟 TUN MTU=9000 当作运营商链路的物理 MTU。

## 已复现问题

### P0：所谓去抖实际丢弃尾事件

`NetworkStateWatcher.shouldEmit` 只检查距离上次上报是否达到 1500ms；被拒绝的事件没有 pending 值或尾部定时器。

生产方法离线序列：

- 10000ms：wifi，发布。
- 12000ms：none，发布。
- 12200ms：cellular，被拒绝。
- 再推进 10000ms：状态仍是 none，事件只有 wifi/none，没有定时器。

影响：若没有之后的新回调，网络已恢复但扩展仍认为离线；core monitor 又在 networkAvailable=false 时跳过，形成恢复停滞条件。

建议：把最新 NetworkSnapshot 放入 pending，在尾部定时器发布；网络丢失可立即标记，但恢复不得被窗口永久吞掉。

### P0：MTU 在重建获准前提前写入

`onNetworkTypeChanged` 先 `activeMtu=nextMtu`，再调用可能因 recoveryRunning/rebuilding/cleanup 等直接返回的 `scheduleTunnelRebuild`。

已复现：实际平台 config.mtu=1400、recoveryRunning=true，通知 cellular 后 activeMtu=1360，但没有重建定时器、没有预算消耗。后续热恢复若调用 ensureConfigMtu，就可能形成 YAML/attach MTU=1360、平台 TUN=1400。

建议：desiredMtu / committedMtu 分离；busy 时排队合并，平台重建提交后才更新 active/committed 值。不得只在调用点加一条 if 后丢掉最新期望。

### P1：正常切网消耗故障恢复重建预算

MTU 变化和 core 恢复升级共用 tunnelRebuilds，最大 2 次；成功重建只归零 recoveryAttempts，不归零 tunnelRebuilds。

已复现：wifi -> cellular -> wifi 后预算为 2/2；再到 cellular 保持 MTU=1400，改走 core recovery。

影响不应夸大为“第三次必断网”：MTU 留在 1400 本身未必失败。但普通用户切网耗尽了后续 core 故障的 TUN 重建兜底，且 MTU 策略后半会话不再一致。

建议：正常配置变化与故障恢复分预算；故障预算采用连续失败/时间窗，稳定运行后复位，避免无界重建风暴。

### P1：同承载网络身份和 DNS 变化不可表达

Watcher 所有系统回调都丢弃 handle/caps/properties 内容，只重新读取默认网络类型；相同 type 不推进 generation。

已复现真实方法的同 type 输入不产生新 generation。

因此 Wi-Fi A -> Wi-Fi B、同类型 netId 变化、IP/DNS/可用性改变，在 type 不变时不通知上层。它不是“这些情况下必然失败”的证明，但没有明确的主动修复/缓存刷新链路。

建议：保留 netId、bearer、DNS、地址族、validated 等快照，区分 network-replaced / dns-changed / availability-changed，只有有效变化才重置对应资源。

### P1：订阅 DNS 接管能移除应用假 IPv6 池

RuntimeConfigBuilder 在 dnsOverrideEnabled=false 时允许启用的订阅 DNS 整段替代默认段。ProfileConfigMerger.ensureFakeIpForProfileDns 只补缺失 mode/IPv4 pool/filter，不补 fake-ip-range6。

已复现：overlay 顶层 ipv6=true、默认 fake-ip-range6 有值；订阅 dns.enable=true、ipv6=true、只有 nameserver；合并后仍是 fake-ip，但 fake-ip-range6 消失。

该测试只证明合并配置不变量丢失，不宣称已测到设备泄漏。订阅显式 redir-host 或自定义 IPv6 假池也必须与平台路由逐项验收，不能从应用默认池直接推导全部配置都安全。

建议：合并后做 TUN/DNS IPv6 兼容性校验，明确保留订阅语义与平台可接管范围的冲突处理；检查 AAAA、实际 TUN 流量和出口，不能仅凭“解析有 IPv6”宣称接管成功。

## 其他已核实结构问题

### 两个切网执行者

- App：ConnectionOrchestrator.init -> startNetworkWatch -> onNetworkTypeChanged -> ReconnectManager -> runReconnectAttempt -> connect。
- connectExclusive 会 stopVpnExtensionAbility、等待旧扩展退出、重新拉起，属于整会话重连。
- Extension：独立 watcher -> 按 MTU 重建 TUN 或 stopCore/startCore。

两者之间没有共享切网事务锁；App 内 lifecycleWrites 和 Extension 内单航班不等于跨进程互斥。是否每次真机都会撞上尚未测，但前台两者可同时响应同一切网，造成重复动作的风险明确。

建议：Extension 是运行会话唯一切网执行者，App 只消费状态；App 只在扩展确实死亡时重新拉起，而非每次承载变化直接 connect。

### YAML 栈选择被实际构建桥覆盖

生成器输出 `stack: mips`、`congestion-controller: bbr3`；但构建脚本选用的 `mihomo-build/mihomo-smart-462455136157a760937c666bba71afe33b1a809e/bridge/bridge.go` 在 tunFd>0 时强制 `cfg.General.Tun.Stack=C.TunGvisor`。

因此按当前构建源码链不能声称真实 VPN 在使用 mips/bbr3；headless 测速不走同一 fd 分支。尚未反汇编 0.8.0 的 so 来证明其编译来源，需保留发布二进制身份的不确定性。

建议：移除无理由栈覆盖或统一为实际栈，并在启动日志/诊断状态中报 effective stack 和 MTU；实际运行栈必须作为验收项，而不是仅 grep YAML。

### 过时注释与探针文案

当前默认实际为 fake-ip，IPv6 开时有 fake-ip-range6；多个文件仍写 redir-host。OrchestratorHealthProbes 的 IPv6 判据仍只检查 AAAA，可将假地址存在误当作端到端 IPv6 正常。

需要清理旧注释、区分“DNS 有 AAAA”“流量进 TUN”“代理出口支持 IPv6”。这是验收可信度问题，不要把错误注释当产品事实。

## 对照客户端

### FlClash OHOS（本机 a2e8f13 源码）

- VpnExtAbility.toVpnConfig 固定 mtu=9000，不随 Wi-Fi/蜂窝动态重建。
- NetworkManager 保留网络 netId 映射及 DNS 列表；属性回调改变 DNS 后调用 updateDns。
- core/lib.go.handleUpdateDns 调用 dns.UpdateSystemDNS + FlushCacheWithDefaultResolver，无需重启整个 Core。
- IPv6 使用 ULA /126，并在开启时下发 IPv6 sentinel。平台是否接受其 IPv6 默认路由必须实机验证，不能盲抄。
- 它的网络选择代码本身也不完美：以 bearer enum 最大值选择 best，不能当通用最优网络优先级算法。

### FlClash Android 本地源码快照（不标为已发布版）

- NetworkObserveModule 显式排除 VPN，维护 Network 身份、DNS、onLosing 状态。
- DNS 更新做 200ms 尾部调度（移除旧 Runnable，重新 postDelayed）。
- network 身份变化时 Core.resetNetwork，让旧连接及时重连，而非重启整内核。
- VpnOptions 默认 MTU=9000，也允许显式 MTU，平台与内核使用同一个 tunMtu。

本轮没有重新获得 ClashPlus 原生网络模块的直接代码证据，因此不将此前聊天的 ClashPlus 结论作为当前确证事实。

## 推荐顺序

1. 先修尾事件丢失与 desired/committed MTU；补真实方法竞态回归。
2. 收口切网权威到 Extension，App 不再并行拆会话。
3. 引入网络身份快照，提供轻量 DNS 更新 / 旧网络连接失效通知，少做整 Core 重启。
4. 拆分正常切网与故障恢复预算，避免正常操作消耗兜底。
5. 对齐合并后 IPv6/TUN 假池不变量，以及 YAML/实际栈。
6. 最后做 MTU A/B：统一保守 MTU（例如 1360/1400 候选）对比动态策略；未测前不直接照抄 9000。
7. 真机覆盖 Wi-Fi/蜂窝反复互切、Wi-Fi A/B、飞行模式恢复、锁屏后台、IPv6-only/NAT64；记录切网到首个成功请求时延、失败率、重建次数、DNS/UDP/IPv6 出口。

## 本轮验证结果

- `node scripts/verify-vpn-architecture.mjs`：322 passed / 0 failed。
- `node scripts/verify-config-single-source.mjs`：42 passed / 0 failed。
- 临时审查脚本：上述 5 个生产方法边界均成功复现；临时文件按收尾约定删除，不入业务代码。
- `node scripts/verify-shipped-dns-fix.mjs` 默认路径不存在 signed HAP，首次失败属于路径错误；改为显式 `C:/Worker/TunBox/dist/TunBox-0.8.0-release-signed.hap` 后七项字符串断言通过。
- DNS HAP 门禁仅证明相关字面量在 abc 中，不证明 DNS 服务可达、路由接管或切网成功。
- 设备 `192.168.10.7:39933` 后续已在线，但当前运行的是旧安装实例；本轮没有覆盖安装、切换网络或重启 VPN，因此没有把设备在线误报为新代码真机验收。

## 8. 本轮已落地的优化（2026-11-02 续）

- **统一 MTU=1360**：Wi-Fi、蜂窝、以太网、未知网络均使用同一值；切网不再因为 bearer 差异重建 TUN。YAML、VpnConfig、native attachTun 三者共用同一常量。
- **NetworkStateWatcher**：保留 netId、接口名、地址、DNS、validated、metered；网络事件采用 200ms 尾部合并；断网立即发布，恢复不会被窗口吞掉；旧注册回调和失败注册不会污染重启后的 watcher。
- **Extension 单一网络权威**：App 侧切网只观察和取消重复重连，活动 TUN 由 Extension 处理；忙碌期间保存最新快照，不提前修改已提交 MTU。
- **轻量网络更新 ABI**：新增 `TunBoxUpdateNetwork` → NAPI `updateNetwork` → `CoreBridge.updateNetwork`，只刷新物理 DNS、清理 resolver cache/连接，网络身份变化时关闭旧跟踪连接；不重建 TUN、不重启 Core。DNS-only 更新不关闭现有连接。
- **恢复策略**：正常切网不消耗 TUN 重建预算；连续故障预算在稳定运行 60 秒后归零；迟到的旧网络更新失败不会丢弃较新的网络快照；Core 未启动完成前不执行更新。
- **IPv6 合并契约**：最终配置合并后补齐/校验 fake-ip IPv6 池；fake-ip 模式使用 `fdfe:dcba:9876::/64`，redir-host 等真实地址模式不虚报可捕获的 IPv6；探针文案区分“DNS 返回 AAAA”和“出口 IPv6 已验证”。
- **内核栈一致性**：移除 bridge 对 YAML 栈的静默 gvisor 覆盖，启动日志记录 effective stack、MTU 和 congestion；重新构建 arm64 `libgojni.so`，并更新头文件/哈希。
- **Protect 生命周期**：Stop 先取消等待者但保留会话写端归属，随后由 releaseProtectLocked 统一关闭，修复重复启动/停止时的管道读端永久阻塞和 fd 生命周期问题。
- **构建脚本**：修复 Windows PowerShell 中 `HTTPS_PROXY`/`https_proxy` 重复环境键导致的 Go 构建失败，改用直接 Go 调用。

## 9. 最终验证

- 清理构建 HAP：成功，`entry-default-unsigned.hap` 已重新打包最新 arm64 内核。
- UI 资源编号门禁：通过。
- 网络运行时回归：21/21 通过。
- 纯逻辑回归：228/228 通过。
- VPN 架构门禁：322/322 通过。
- 启动资源与真实内核组合：46/46 通过。
- 配置/发布相关回归：12/12 通过；`verify-flclash-profile.mjs` 因缺少严格模式所需环境而跳过，非本轮失败。
- mihomo DNS 单元测试：通过。
- Linux bridge 回归：新增网络更新、DNS-only 保持连接、切网清理旧连接、Protect Stop 生命周期用例均通过。
- 设备在线但未覆盖安装/切网：真机网络切换、吞吐、功耗和 IPv6 出口仍需单独验收。
