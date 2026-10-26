# 维护约定：收尾清理（每个任务完成后执行）

> 2026-10-26 用户要求：每次干完活都要清理环境，并把这条约定记录在项目里。

## 为什么

调试过程会在三个地方留下垃圾：本机 `%LOCALAPPDATA%\Temp`（hdc 拉回的布局 dump 与截图）、设备 `/data/local/tmp`（同样的 dump）、仓库根目录（一次性 patch 脚本与构建日志）。越积越多会拖慢检索、混淆证据版本，还容易把带第三方信息的截图误提交。

## 命名约定（脚本据此删除，务必遵守）

| 位置 | 路径 | 命名 |
|---|---|---|
| 本机 | `%LOCALAPPDATA%\Temp` | `tunbox-probe-<用途>.json`（布局 dump）/ `.jpeg`（截图） |
| Hermes scratch | `%LOCALAPPDATA%\hermes\cache\scratch` | `tunbox-probe-*` |
| 设备 | `/data/local/tmp` | `tunbox-probe-*` |

例：`hdc file recv /data/local/tmp/tunbox-probe-approuting.json %LOCALAPPDATA%/Temp/tunbox-probe-approuting.json`

## 执行

```bash
# 先看会删什么
DRY_RUN=1 bash TunBox_HarmonyOS/scripts/clean-workspace.sh

# 实际清理（本机 Temp / scratch / 仓库内 *.log / 设备 /data/local/tmp）
bash TunBox_HarmonyOS/scripts/clean-workspace.sh
```

脚本只删约定前缀与 `TunBox_HarmonyOS/*.log`，不碰源码、`docs/`、`dist/`、签名材料。设备不在线会打印 `SKIP`，下次连上再跑。

## 该合并的合并进项目目录

| 内容 | 落地位置 |
|---|---|
| 单个版本的发布说明 | `docs/releases/v<版本>.md` |
| 技术复盘 / 根因分析 | `TunBox_HarmonyOS/docs/<主题>_<日期>.md` |
| 本机跑过的一次性验证 | 升级成 `TunBox_HarmonyOS/scripts/verify-*.mjs` 闸门 |
| 可复用的清理 / 运维动作 | `TunBox_HarmonyOS/scripts/*.sh` |

scratch 与 `%TEMP%` 里的东西默认都是临时的，不进仓库、不复用。

## 不要留在仓库里的东西

- 一次性 patch / debug 脚本（如历史上 `_p2/` 里几十个 `fix-*.cjs`，已在 0.6.7 发版后清理）。
- 构建日志（`TunBox_HarmonyOS/*.log`）、安装包、签名材料与 `dist/`（`.gitignore` 已覆盖，闸门也会拦）。
- 带真实订阅名 / 节点名 / 出口 IP / 个人路径的截图。

## 收尾检查清单

1. `bash TunBox_HarmonyOS/scripts/clean-workspace.sh` 通过，无 `SKIP`。
2. `git status` 只剩本轮要提交的文件，`TunBox-Window/` 的内容变动不属于本仓库。
3. `dist/` 只保留当前发布版本（必要时留上一版做回滚）；重复 `.zip`、更早版本删掉。
4. 本轮结论已写进 `docs/`（发布说明 / 复盘 / 闸门），不只在对话里。

## 底栏玻璃材质：HdsTabs 实验结论（2026-10-26，已回滚）

- 目标：按 HarmonyX（`entry/src/main/ets/pages/Index.ets`）的写法，用 `HdsTabs` +
  `barFloatingStyle.systemMaterialEffect(IMMERSIVE/ADAPTIVE)` 做系统沉浸光感底栏。
- 实测结论：`barFloatingStyle.barWidth`（无论百分比还是 vp 数值）在 3 个页签下**不生效**，
  `uitest dumpLayout` 里 `TabBar` 仍是全屏宽 `[0,2323]-[1600,2456]`（屏 1600×2560），
  页签命中区 28..1572，因此条体要么贴满整屏、要么与页签几何不一致（放大后错位）。
- HarmonyX 之所以正常，是因为它有 5 个页签，浮起条体按内容自然撑到接近满宽，
  它本身也没有设 `barWidth`；直接照抄结构在我们 3 页签场景拿不到同样宽度。
- 处理：`MainPage.ets` 回滚为自绘 `FloatingBottomBar`（92% 宽 + `backgroundBlurStyle` 玻璃），
  删除本轮的 `HdsTabs` 版本；2026-10-17 的重构也记录过同样结论（移除 HdsTabs 沉浸材质页签）。
- 若再尝试：必须先 `dumpLayout` 量到条体真实 bounds 再动样式，不允许按截图目测下结论。
