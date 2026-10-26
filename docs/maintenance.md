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

## 底栏「完全透明」定稿（2026-10-26，用户最终要求）

**结论：底栏栏体零渲染。** `FloatingBottomBar` 只画页签项（图标 / 文字 / 选中胶囊 / 点击光晕），
栏体本身不画任何像素：无 `backgroundColor` 填充、无 `backdropBlur` / `backgroundBlurStyle`、
无 `border` 描边、无 `shadow` 投影。背后内容 1:1 透出，不做磨砂。

实现位置（改之前先读完这段）：

- `entry/src/main/ets/components/FloatingBottomBar.ets` 的根 `Row` 属性链：
  `.width('92%')` / `.height(64)` / `.borderRadius(32)` 只用于布局与命中区，
  `.backgroundColor(Color.Transparent)` 是唯一与"面"有关的属性。**禁止再加回**
  `backdropBlur` / `backgroundBlurStyle` / `shadow` / `border` —— 任一项都会让底栏重新
  变成一条可见胶囊。
- 选中项的 `primaryLight` 胶囊 + `primaryBorder` 描边属于**页签项高亮**（前景），
  不是栏体底色；点击瞬间的 `dockGlow` 光晕同理。

为什么不是「HDS 沉浸光感材质」：

- 官方材质的 `IMMERSIVE` / `ADAPTIVE` 本身是磨砂材质，物理上做不到「完全透明」；
  官方材质枚举里 `hdsMaterial.MaterialType.NONE`（`=0`，注释 "No material effect."）
  才是「无材质」那一档。即：官方推荐配置做到「完全透明」= 材质选 NONE。
- 自绘零渲染栏与 NONE 的显示结果等价，且绕开 2026-10-26 实测到的 HdsTabs
  `barFloatingStyle.barWidth` 在 3 页签下不生效的问题（见上一节）。

真机取证（MLR-AL00，1600×2560，`com.tunbox.client`）：

- 改前（`backdropBlur(24)` + 白 60% 描边 + 投影）：首页渐变背景上目视为一条磨砂白胶囊；
  截图底栏区域像素均值 `(236.5, 240.8, 253.3)`，与页面同列背景 `(237, 241, 253)` 的差异
  主要来自 1px 白描边（≈255）与投影，肉眼看就是"一层白"。
- 改后：底栏区域与页面背景像素一致；订阅页列表滚到底时，节点卡文字在页签项下方
  **清晰可读、不模糊**（真透明，不是磨砂）；点击「订阅」页签仍能正常切页（透明不影响命中区）。
- 验证产物：`entry-default-signed.hap`（debug 签名）装真机；`verify-ui-resource-bindings.mjs`
  底栏三图标编号 PASS。

装机注意：真机只认 debug 签名（release 证书装上报 `9568322 not trusted app source`）。
流程是 `switch-signing.ps1 -Mode debug` → 构建 → `hdc install -r entry-default-signed.hap`；
**提交前必须** `switch-signing.ps1 -Mode release`，再跑 `verify-build-profile.mjs`。

