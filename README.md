![TunBox for HarmonyOS](docs/screenshots/banner.png)

# TunBox for HarmonyOS

TunBox 的 **HarmonyOS NEXT** 客户端：基于 mihomo（Clash Meta）内核的原生代理工具，界面与交互按移动端重新设计，订阅、规则、分流与测速全部在本机完成。

> 本仓库同时包含 HarmonyOS 客户端（`TunBox_HarmonyOS/`）、Windows 客户端（`TunBox-Window/`，独立仓库形式的子目录）与内核构建产物（`kernel/`、`mihomo-build/`）。

---

## 功能

**连接与节点**
- 主页一键连接 / 断开，实时上下行速率、流量消耗、连接时长、公网出口 IP。
- 节点列表按订阅分组，支持单列 / 双列排布与逐节点测速、整组批量测速。
- 三种代理模式：规则 / 全局 / 直连；切换规则与全局热切换，不打断已建立连接。

**订阅**
- 直接保存订阅原文（Clash YAML 按原文落盘；分享链接经内置转换器转成节点表），节点与分组以内核 `/proxies` 为准。
- 多订阅并存、单一当前订阅热切换；订阅自带的 `proxy-groups` / `rules` / `rule-providers` 随配置下发给内核。
- 订阅刷新支持 ETag / User-Agent 链与明文 HTTP 开关（默认拒绝明文 HTTP）。
- DNS 按订阅分域：每个订阅的节点域名走自己的解析器，避免多订阅互相污染。

**分流**
- 应用分流：全部代理 / 排除所选 / 仅限所选，支持常用应用目录、手动导入与批量删除；手动导入支持 `名称|包名` 每行一条。
- 网站分流：强制代理 / 强制直连 / 强制拦截三类名单。
- 规则页：可视化规则编辑、`RULE-SET` 引用校验、去广告规则集开关。

**内核与稳定性**
- 配置生成后先交内核校验、通过才原子替换正式配置；启动失败自动回退上一份可用配置并保留现场日志。
- `geoip.metadb` / `geosite.dat` 随包携带，首装离线可用，避免内核启动期联网下载卡死。
- 测速走本地内核 controller 的 TCP 通道，高并发下仍能稳定返回。
- 凭据（节点密码 / 订阅 header）保存在系统凭据存储（Asset Store），不落明文。

**隐私**
- 无遥测、无统计上报、无第三方 SDK；除订阅、规则集等用户主动触发的请求外不上传任何数据。

---

## 安装

正式分发包通过 AppGallery / 自签名 HAP 安装。**Releases 里的 `TunBox-<版本>-unsigned.hap` 是未签名产物，仅供开发者与测试使用，不能直接安装到普通设备。**

自签安装流程（概要）：

1. 用 DevEco Studio 打开 `TunBox_HarmonyOS/`，登录华为开发者账号。
2. `File > Project Structure > Signing Configs` 勾选自动签名，或在命令行使用 `hap-sign-tool` 用自有证书签名。
3. `hdc install -r <signed.hap>`。

> `ohos.permission.VPN` 是受限开放权限，需要在 AppGallery Connect 为对应应用申请 ACL 后才能使用 VPN 能力。

---

## 从源码构建

环境：DevEco Studio 5.0+ / HarmonyOS SDK（`compatibleSdkVersion 6.1.1(24)`，`targetSdkVersion 26.0.0`），真机 arm64。

```bash
cd TunBox_HarmonyOS
export PATH="/path/to/DevEco Studio/jbr/bin:$PATH"   # hvigor 需要 java

# 调试签名（本机 DevEco 托管证书）用 -Mode debug，发布前用 -Mode release 清空签名配置
../switch-signing.ps1 -Mode debug

node "/path/to/DevEco Studio/tools/hvigor/bin/hvigorw.js" \
  --mode module -p product=default -p module=entry@default \
  -p buildMode=debug assembleHap --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-signed.hap`（debug 签名）或 `entry-default-unsigned.hap`（release）。

内核：`kernel/` 与 `mihomo-build/` 存放 OHOS 交叉编译产物与补丁源码；需要重新编译时见 `TunBox_HarmonyOS/scripts/` 下的构建脚本与 `TunBox_HarmonyOS/README_HarmonyOS.md`。

---

## 目录结构

```
TunBox_HarmonyOS/            HarmonyOS 客户端
  entry/src/main/ets/pages/  主页 / 订阅 / 规则 / 设置 / 分流等页面
  entry/src/main/ets/commons/ 模型、服务、Clash 配置生成、测速引擎
  entry/src/main/ets/vpnability/ VPN 扩展能力（TUN、长时任务、通知）
  entry/src/main/cpp/        NAPI 内核桥
  scripts/verify-*.mjs       自检闸门（配置生成、架构不变量、UI 契约等）
  docs/                      工程复盘与设计记录
TunBox-Window/               Windows 客户端（独立仓库）
kernel/ , mihomo-build/      mihomo 内核构建产物与补丁源码
docs/                        项目级文档与素材
```

---

## 许可与第三方

- 本项目代码遵循 **MIT**。
- 内置/捆绑的 mihomo（Clash Meta）内核遵循 **GPL-3.0**，相关声明见 `TunBox_HarmonyOS/THIRD_PARTY_NOTICES.md`。
- 其他第三方组件与许可证见各自目录下的说明文件。

## 免责声明

本项目仅供学习网络代理协议、客户端工程实现与安全研究使用。请遵守所在地法律法规与网络服务提供方的使用条款，不要将本软件用于任何违法用途。
