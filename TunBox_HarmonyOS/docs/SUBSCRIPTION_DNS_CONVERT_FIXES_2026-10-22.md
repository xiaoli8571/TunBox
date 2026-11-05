# 订阅 / DNS / 订阅转换：2026-10-22 收尾修复记录

本文记录本轮真机驱动修复的**根因与判据**，每条都带可复现的现场证据，供后续回归对照。
所有修复均已通过对应闸门；闸门名写在各节末尾。

---

## 1. 全新安装内核起不来（测速 0 目标、启动代理报错）

**现象**：新设备导入订阅后点测速「立刻完成」、节点全 `--`；启动代理直接报错。

**根因**：安装包内没有 geo 数据，内核启动时联网下载 MMDB 卡死。

```
cache/core.log:
  Geodata Loader mode: memconservative
  Can't find MMDB, start download          ← 停在这里
App:
  ensureTestCore failed: 测速内核就绪超时(20s)
```

**修复**：
- 包内携带 `geoip.metadb`(9.6MB) + `geosite.dat`(4.4MB)
- 新增 `GeoDataInstaller`：启动时（UI 进程与 VPN 扩展进程都调）把 rawfile 铺到 `cacheDir`，
  幂等且**只写比现有文件更大的那份**，避免把用户已更新的全量库覆盖回旧版

**判据**：`Initial configuration complete, total time: 17ms` → `Bridge: running without TUN`

闸门：`verify-vpn-architecture`

> 曾尝试「最小 geo」方案（geoip 1.5KB）：geoip 可以，**geosite 不行** ——
> `parse config: DNS FallbackGeosite[0] ... list gfw not found in geosite.dat`，
> 订阅规则引用的 geosite 名不可穷举，缺一个内核就整份拒载。故 geosite 必须全量。

---

## 2. 订阅自带的 dns 让境外网站打不开（ikuuu → YouTube）

**现象**：ikuuu 节点测速正常、能取到出口 IP，但 YouTube / Google 打不开；其他订阅正常。

**根因链**（三段，缺一不可）：
1. 该订阅自带 `dns.enable: true`，nameserver 全为国内解析器 → 境外域名被污染成国内 IP
2. 首次修复只补了 `enhanced-mode: fake-ip`，但 `dns` 段经 `extractSection` 回来后**子键缩进丢失**：
   `enable: true` 掉到顶层，等于 dns 没启用
3. 配置第一条规则是 `GEOIP,CN,DIRECT`，污染 IP 命中 → 直连 → 打不开

**修复**：`ProfileConfigMerger.ensureFakeIpForProfileDns`
- 先**规范化缩进**：除 `dns:` 头外每行强制 ≥2 空格
- 原文未写 `enhanced-mode` 时补 `fake-ip` + `fake-ip-range` + `fake-ip-filter`
- 原文显式写了 `enhanced-mode` 则完全尊重

**判据**（内核 `/connections` 实拍）：
```
yt3.ggpht.com        rule= Domain yt3.ggpht.com     chain= [🇭🇰 香港Z01, 🔰 选择节点]
accounts.youtube.com rule= DomainKeyword youtube    chain= [🇭🇰 香港Z01, 🔰 选择节点]
i.ytimg.com          rule= DomainSuffix ytimg.com   chain= [🇭🇰 香港Z01, 🔰 选择节点]
183.232.70.106       rule= GeoIp cn                 chain= [DIRECT]
```

闸门：`verify-tunbox-profile`

---

## 3. 订阅转换产物导入后不可用（0 节点、测速没反应）

**现象**：设置页「订阅转换」把分享链接转成 YAML，导入后测速无反应、代理不生效。

**根因**：导出文件只有 `proxies:`（真机落盘 14 行、393 字节），没有 proxy-groups / rules：
合并后是一份「没有 MATCH 的规则集」，overlay 规则因目标不存在被丢弃 → 内核 0 节点。

```
SubscriptionPage: profile activated: id=54ab0504... coreNodes=0
```

**修复**：`ProfileConfigMerger.withSyntheticGroups`
- 识别「有 proxies、无 proxy-groups/providers、无 rules」的裸节点表
- 补 `手动选择`(select, 全部节点 + DIRECT) / `自动选择`(url-test) + `rules: [GEOIP,CN,DIRECT, MATCH,手动选择]`
- 原文已有任何组或规则时不介入

闸门：`verify-sub-convert-protocols` [D]

---

## 4. trojan 链接转换后永远连不上（insecure=1 未识别）

**根因**：上游 mihomo 的 trojan 分支只读 `allowInsecure`（`strconv.ParseBool(query.Get("allowInsecure"))`），
而 v2rayN / Shadowrocket / 多数机场导出的是 `insecure=1` → 转出 `skip-cert-verify: false` →
自签证书握手失败 → 该节点恒 fail（同订阅另一条正常）。

**修复**：`SubConverter` 证书开关改为 `allowInsecure || insecure || skip-cert-verify`，
任为真即跳过校验。**这是相对 FlClash 唯一有意的偏离**，理由是该参数名在分享链接生态里更常见。

闸门：`verify-sub-convert-protocols` [B]

---

## 5. 分享链接密码含未编码 `/`

**现象**：`trojan://user/pass@host:port?...` 转出 0 个节点。

**根因**：标准 URL 解析把 authority 在第一个 `/` 处截断，`@` 落进 path。

**修复**：`SubConverter` 的 authority 解析增加分支 —— `@` 出现在第一个 `/` 之后时，
以最后一个 `@` 切分 userinfo，再在右侧找 path（常规链接行为不变）。

闸门：`verify-sub-convert-protocols` [C]

---

## 6. App 自身 HTTP 请求不走隧道（出口 IP、geo/规则集更新全失败）

**根因**：隧道里 App 进程流量被 protect 掉（直连物理网卡），
`api64.ipify.org` 超时、GitHub 镜像被墙 → 「节点能测速但取不到出口 IP」「数据与规则全部源下载失败」。

**修复**：新增 `AppProxyRoute`
- 连接成功后 `connection.setAppHttpProxy({host:'127.0.0.1', port: mixedPort})`
- SDK **不接受 null**（真机 `401 Parameter error`，也无 clear 接口）→ 断开时只重置内部状态，
  外网请求统一带 `usingProxy = AppProxyRoute.activePort() > 0`，断开后即直连
- 覆盖：订阅拉取、出口 IP（两处）、geo/规则集/模型下载、桌面卡片信息

**判据**：
```
app http proxy -> 127.0.0.1:7890 (app requests now egress via tunnel)
PublicIp: after-connect  ok 365ms
app http proxy marked inactive (usingProxy=false from now on)
PublicIp: after-disconnect ok 2208ms
```

---

## 7. 资产策略（用户口径）

| 资产 | 随包 | 更新方式 |
|---|---|---|
| `geoip.metadb` / `geosite.dat` | 全量 | 缺失时连接后台自动补 |
| Smart 选点模型 | 不带 | **手动更新**，可删除；删除后「自动选择」入口自动隐藏（`smart_model_seq` 信号） |
| 去广告规则集 | 不带 | **手动更新**，可删除；删除后自动重启代理以换用无 RULE-SET 配置 |

`deleteGeoAsset` 拒绝删除 geoip/geosite（删了内核起不来）。

---

## 8. 订阅切换 / 展开卡顿

- **串节点**：`ProfileStore.exists()` 改用 `statSync().size > 0`（`accessSync` 曾误判存在）；
  current 指向未落盘 profile 时**不切**、先自动刷新，拉不到就明确报错；启动时自愈 current
- **展开卡顿**：点击订阅头部改为**先同步 toggleOpen，再后台切 profile**（原来挂在
  `activateProfile().finally` 上，等于要等内核 reload 1~5s）；已激活的 profile 不再重载内核
- 组级诊断文案按 `latencyTick` 缓存；订阅卡片 ForEach key 去掉 `latencyTick`

---

## 9. 上架合规（华为商店反馈）

- 转场时长按屏幕对角线英寸分档：`<8.5"` ≥200ms、`8.5~12"` ≥250ms、`>12"` ≥300ms。
  `TunBoxMotion.ms = max(260 设计基线, 规范下限)`，档位由 `EntryAbility` 用 display 实测写入
- 9 个页面 11 个滚动容器显式 `.edgeEffect(EdgeEffect.Spring)`，边界有回弹反馈

---

## 10. 闸门清单（本轮新增/更新）

| 闸门 | 覆盖 |
|---|---|
| `verify-sub-convert-protocols.mjs` | 11 种协议转换 + insecure 三参数 + 未编码 `/` + 裸节点表补组（60 项） |
| `verify-tunbox-profile.mjs` | overlay/原文合并、dns 语义、真实内核 `-t` |
| `verify-vpn-architecture.mjs` | 架构不变量（303 项） |
| `verify-latency-display.mjs` | 延迟显示口径（50 项） |

> `verify-sub-convert-protocols.mjs` 每次运行都会先执行
> `tools/true-chain-harness/prepare.mjs` 重新生成 `.ts` 产物 ——
> 只判文件存在会让「改了 .ets 却忘了重新生成」的旧产物假绿（本轮踩过）。
