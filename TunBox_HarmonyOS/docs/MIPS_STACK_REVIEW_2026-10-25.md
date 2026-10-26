# mips 协议栈稳定性 / 性能评审（2026-10-25）

> 背景：TunBox 鸿蒙客户端当天把 TUN 用户态栈从 **gVisor** 切到 **mips**（mihomo 自研 mipstack）。
> 本文只回答一个问题：**在不再加功能的前提下，mips 这条栈还有哪些稳定性/性能可调项，哪些是
> 从 gVisor 时代遗留下来、现在已经完全失效的"假旋钮"。**
>
> 结论先行：**真正还能动的只有一个旋钮（`tun.congestion-controller`），其余 gVisor 时代的调优键
> 在 mips 下要么不生效、要么位置写错从来没生效过。**

---

## 1. 鸿蒙上 mips 的实际形态（决定了能力上限）

关键事实：鸿蒙走 **fd 注入**（`tun.file-descriptor` 由 `VpnExtensionAbility` 传入 tun fd）。

真机内核日志实证：

```
level=info  msg="Bridge: TUN descriptor attached; network parameters preserved from config"
level=warning msg="[TUN] get tun name failed for fd 39, fallback to use tun interface name "
```

对应 sing-tun v0.4.28 的 `tun_linux.go`：

- `New(options)`：`options.FileDescriptor > 0` → 走 `else` 分支，**只** new 一个裸 `NativeTun`，
  **不调用 `open()`**。
- 因此 `vnetHdr` 永远为 `false`（它只在 `open()` 里 `IFF_VNET_HDR` 成功后才置 true）。
- `NativeTun.FrontHeadroom()` → `vnetHdr=false` → 返回 **0**。
- `NativeTun.BatchSize()` → `!vnetHdr` → 返回 **1**。
- `stack_mipstack.go:readLoop()` 里批量读的条件是
  `linuxTUN.FrontHeadroom() > 0` → **不满足**，于是退化成通用单包循环：
  `device.Read(buffer)` 一次一个包。

**结论（能力天花板，改配置解决不了）**：鸿蒙上的 mips 是**单包 syscall** 路径，没有 GSO、
没有批量读、`BatchSize()==1`。吞吐上限由 syscall 频率决定，这是 fd 注入的固有代价，
不是调参能突破的，想要批量 IO 只能改内核/sing-tun。

**一个正面结论**：RX 校验和卸载是**开着**的。`readLoop()` 开头
`switch device.(type) { case WinTun, LinuxTUN, DarwinTUN: ... }` ——
`NativeTun` 实现了 `LinuxTUN` 接口，断言命中，所以
`offload.SetIPv4Header/TCP/UDP(true)` 生效，不需要额外配置。

---

## 2. 从 gVisor 继承来的"假旋钮"清单（重要，别再调它们）

| 配置键 | mips 下是否生效 | 证据 |
| --- | --- | --- |
| `tun.gso` / `tun.gso-max-size` | **无效** | GSO 只在 `open()` 自建 `/dev/net/tun` 且 `IFF_VNET_HDR` 成功时启用；fd 注入不走该分支。开了不会报错，但什么也不做。 |
| `tun.processors-per-channel` | **无效** | 内核注释明确写 "gvisor special config"，只透传到 gvisor。 |
| `tun.udp-timeout` | **无效** | `sing-tun` 里只有 `stack_gvisor.go:76` 消费 `options.UDPTimeout`；`stack_mipstack*.go` 全文无引用。 |
| 顶层 `udp-timeout` | **无效且键不存在** | 内核 RawConfig **没有**顶层 `udp-timeout`（`grep yaml:"udp-timeout"` 只有 `config.go:321` 的 `RawTun` 字段）。之前生成器一直在发顶层，被静默忽略。 |
| `tun.endpoint-independent-nat` | 本版本未见消费点 | sing-tun v0.4.28 里只有 `stack.go:29` 的结构体字段声明，无读取方。 |

> ⚠ 本轮之前，生成器把 `udp-timeout: 300` 发在**顶层**——即"键名不存在 + 即使改名也只有 gVisor 认"，
> 双重失效。**不要再指望用它调 UDP 老化。**

**UDP 会话到底谁回收？** mihomo 自己：`tunnel/tunnel.go:64` `udpTimeout = 60 * time.Second`，
配合 `tunnel/connection.go` 的 `pc.SetReadDeadline(now+udpTimeout)`。**与 tun 栈无关**，
所以 mips 不老化 UDP 是无害的，不会内存泄漏。

---

## 3. 唯一真正生效的栈级性能旋钮：`tun.congestion-controller`

链路（已逐段核对源码）：

```
tun.congestion-controller           (config/config.go RawTun)
  → options.CongestionController    (config.go:1758)
  → listener/sing_tun/server.go:507 StackOptions.TCPCongestionControl
  → stack_mipstack.go:48            NewMipstack 校验 + TCPSocketDefaults.CongestionControl
  → mipstack 每条被接管的 TCP 连接
```

**这是 mips 下唯一能真正改变性能的配置项**，作用在设备↔代理之间那条 TCP 上。

**取值必须已注册，否则 TUN 起不来**（`NewMipstack` 直接
`return invalid TCP congestion control: xxx`，不是静默忽略）。

运行时实测（用本项目 `go.mod` 同一 pin：`mipstack v0.0.0-20261019124225-9a80a07eaeb9`）：

```
available congestion controls: [bbr bbr3 cubic reno]
```

已确认 `congestion_api.go` 里 BBR3 是**无条件注册**（`congestion*.go` 无 `//go:build` 约束），
设备侧 `libgojni.so` 由同一份 go.mod 构建 → 必须可用。

**选 `bbr3`**：模型驱动 + 有界丢包，弱网 / 高 RTT（移动网络、跨境线路）下吞吐与丢包恢复
优于内核默认的 `cubic`（cubic 在丢包链路上会大幅退让窗口）。

> ⚠ 踩坑提醒：`mihomo -t` **不校验**算法名。本轮做过负对照，把 `bbr3` 改成不存在的 `bbr9`，
> `-t` 依然报 `test is successful` —— 因为 `-t` 不构造 TUN。**别用 `-t` 证明算法名合法**，
> 要用 `AvailableCongestionControls()` 或真机连接日志。

---

## 4. 明确"不要动"的地方（改了会变差或直接坏）

1. **`tun.auto-route` / `tun.auto-detect-interface` 必须保持 `false`。**
   - `server.go:340` 的条件是 `if options.AutoRoute || options.AutoDetectInterface` 才建
     `NetworkUpdateMonitor` / `DefaultInterfaceMonitor`；两者为 false → 不建。
   - 这是**对的**：鸿蒙/Android14+ 禁 netlink；而且本项目同时存在隧道核与测速核，
     `auto-detect-interface` 会撞 `not allowed two tun listener using auto-detect-interface`。
   - 网络切换时"内核状态没被 flush"这个缺口由 `VpnExtensionAbility` 的
     `scheduleTunnelRebuild('mtu-change')` **整体重建 TUN** 兜底，比 flush 更彻底。

2. **`tun.mtu: 1400` 保留，别删。**
   若省略该键，sing-tun 默认 `tunMTU = 9000`（`server.go:193`），mips 会按 9000 分配
   每包缓冲 —— 又大又没必要。显式 1400（蜂窝 1360）是对的。

3. **`stack: mips` 显式写没问题**：内核默认值本来就是 `TunMips`（`config.go:561`），
   显式写只是让配置自解释。

4. **不要为了"提升吞吐"去调大 MTU**：单包 syscall 路径下 1400→1500 只省约 7% 包数，
   却引入 VPN 分片/PMTUD 黑洞风险，不划算。

---

## 5. 本轮实际改动（`ClashConfigGenerator.ets`）

1. 顶层 `udp-timeout: 300` **下移到 `tun:` 段**（修正语义位置；顶层那个键内核根本不认）。
   保留而非删除的原因：仓内门禁 `scripts/verify-vpn-architecture.mjs` 断言源码含 `udp-timeout:`；
   且将来若回落 gVisor，这个位置才是对的。
2. 新增 `tun.congestion-controller: bbr3`（含完整注释说明证据链与回退方式）。

改动只碰 `tun` 段文本，`VpnExtensionAbility` 的 MTU 改写正则
`/^ {2}mtu: \d+$/m`（只匹配两空格缩进的 `mtu:` 行）不受影响。

---

## 6. 验证记录

| 项 | 结果 |
| --- | --- |
| `AvailableCongestionControls()`（项目 go.mod 同一 pin） | `[bbr bbr3 cubic reno]` ✅ |
| 真源码跑 `generate()`，tun 段输出 | 含 `congestion-controller: bbr3` + `udp-timeout: 300`，顶层无 `udp-timeout` ✅ |
| 真实内核 `mihomo -t` 校验上述产物 | `test is successful` ✅ |
| `-t` 负对照（`bbr9` 非法算法名） | 依然成功 → **证明 `-t` 不校验算法名**，此路不可作证据 ⚠ |
| `scripts/verify-config-generation-integrity.mjs` | 132 passed, 0 failed ✅ |
| `scripts/verify-vpn-architecture.mjs` | 313 passed, 0 failed ✅ |
| `scripts/verify-config-single-source.mjs` | 42 passed, 0 failed ✅ |
| `node scripts/verify-arkts-compile.mjs` | 3 passed（含 assembleHap）✅ |
| `scripts/verify-ui-resource-bindings.mjs` | PASS（debug 三个图标编号正确）✅ |
| 真机安装 | `install bundle successfully` ✅ |

**尚未完成（需要一次真机重连）**：设备上现有 `mihomo_config.yaml` 仍是旧会话产物，
应用重启后未自动重连，所以配置没有重新生成。需用户手动点一次连接，然后确认：

```bash
# 1) 配置里出现 bbr3
grep -n "congestion-controller" .../cache/mihomo_config.yaml
# 2) 内核日志无算法错误
grep -i "invalid TCP congestion control" .../cache/core.log   # 应为空
```

---

## 7. 一句话总结

mips 在鸿蒙上的能力被 fd 注入锁死在「单包 + 无 GSO」，这部分靠调参无法改善；
gVisor 时代那一批调优键（gso / processors-per-channel / udp-timeout）现在全是死键；
**唯一真正还能提升表现的是 `tun.congestion-controller`，已设为 `bbr3`**。
此外 `tun.udp-timeout` 的位置错误也顺手修正了。
