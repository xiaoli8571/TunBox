# TunBox for Windows

WPF (.NET 8) 桌面客户端，内核是 mihomo（Clash Meta）的 smart 分支。竖屏窗口 + 底部三页签，
交互形态与鸿蒙端一致：一颗电源环总开关、订阅手风琴卡、分组筛选节点。

## 目录

```
TunBox-Windows/
├── TunBox.sln
├── src/TunBox.Core/      # 与界面无关的全部逻辑：订阅解析/拉取、配置生成、内核宿主、控制 API、分流库、系统代理/TUN
├── src/TunBox.App/       # WPF 界面（MainViewModel + MainWindow + 托盘 + 对话框）
├── tests/TunBox.Core.Tests/
└── scripts/              # 发布与打包
```

## 先决条件：内核文件（不入库）

`core/` 被 `.gitignore` 排除（66MB + 9.3MB 的二进制）。构建前需要放好两个文件：

| 文件 | 来源 |
| --- | --- |
| `core/tunbox-core.exe` | 仓库根 `mihomo-build/` 下的 mihomo-smart 构建产物 `mihomo.exe`，改名而来 |
| `core/Model.bin` | 仓库根 `mihomo-build/Model.bin`（smart 组的 LightGBM 模型） |

换内核的完整流程与踩坑见仓库根 `MIHOMO_SMART_KERNEL_SWAP.md`。缺这两个文件时
`scripts/publish.ps1` 会直接报错退出，不会给你一个装完打不开的安装包。

## 构建与测试

```powershell
dotnet build TunBox.sln -c Release
dotnet test  TunBox.sln -c Release      # 65 条：解析契约 / 配置生成不变量 / 真内核 E2E / UI 绑定与摆位
```

测试里有两条是「真起内核进程」的端到端：判据取内核 stdout 的 `RESTful API listening at:` 行，
不依赖本机回环 HTTP 是否通畅。

## 出包

```powershell
powershell -File scripts/publish.ps1          # 自包含目录 publish/（含 core/，缺文件即报错）
powershell -File scripts/make-installer.ps1   # NSIS 安装包 dist/TunBox-Setup-<版本>.exe
```

安装包是标准 NSIS 向导（欢迎 → 目录 → 进度 → 完成/运行），按当前用户装到
`%LOCALAPPDATA%\Programs\TunBox`，不需要管理员。`scripts/installer.nsi` 必须存成 **UTF-8 with BOM**，
否则 makensis 报 "Bad text version"。

## 运行期数据

- 配置与节点库：`%APPDATA%\TunBox\settings.json`、`nodes.json`
- 内核工作目录：`%APPDATA%\TunBox\runtime\`（`config.yaml`、`core.log`、`geoip.metadb`、`cache.db`）
- 崩溃与启动面包屑日志：`%APPDATA%\TunBox\logs\`

## 已知限制

- 安装包未做代码签名（SmartScreen 会拦一次）。
- 深色主题、配置备份/恢复未做。
- 只声明 `proxy-providers` 的订阅（节点要靠运行时下载）尚未支持。
