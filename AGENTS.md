## 会话记忆（本环境约定）

- 本环境没有 recall MCP：`retrieve_memory` / `store_memory` 是旧 ZCode 内置记忆的约定，
  2026-10 从 ZCode 迁移到 MCode 后该能力没有跟过来，**不要再调用**。
- 长期记忆改用三层：
  1. 本仓库文档（踩坑记录、`*_2026-*.md` 修复/优化记录）承载项目事实与复盘；
  2. Agent Memory（`memory` 工具，target=main）承载跨项目、跨会话仍成立的教训与偏好；
  3. User Memory（`memory` 工具，target=user）承载用户专属偏好。
- 写记忆遵循同样的纪律：只存消化后的结论（做了什么 / 为什么 / 坑 / 下一步），不抄原文对话；
  **永远不要存**：API key、token、密码、私钥、cookie；读代码/git log 就能得到的东西；
  一次性任务状态。

## 打包必须「清理构建 + 资源编号门禁」（2026-10-23 事故规则）

- 打包/装机用的 HAP **必须** 先清理再编译：
  `hvigorw --mode module -p module=entry@default -p product=default assembleHap` 前先执行 `clean`（或 `clean assembleHap` 一条命令）。
  **禁止只跑增量 `assembleHap`**：新增/删除 media 资源会改变 `ResourceTable` 编号，而 `CompileArkTS` 缓存可能沿用旧数字，
  结果是图标/图片串位（530 曾把电源图标显示成订阅图标、底栏三个图标全部错位，源码与 SVG 均正常）。
- 构建后立即跑 `node scripts/verify-ui-resource-bindings.mjs`（比较编译产物里的 media 编号与当前 ResourceTable），
  失败禁止安装/发布；该脚本在未构建时明确 SKIP，不要把它当“已通过”。
- 打包记录里写明实际构建命令与门禁输出，便于复现。

## 打包与发布 Skill（Nexus 专属）

涉及「打包 HAP/APP、签名、推 GitHub、发 Release」时，先读对应 skill 再动手：

- 打包：`skills\nexus-pack\SKILL.md`（仓库内未入库副本；版本号规则、构建命令、签名流程，含签名密钥）
- 推送：`skills\nexus-push\SKILL.md`（git 白名单提交、token 推 neworigin、GitHub Release 与附件上传，含令牌）
- **主远程是 `neworigin`（xiaoli8571/Nexus-VPN-HarmonyOS）**；origin（SSRVPN_Harmony）已冻结，不要推。
- 两个 SKILL.md 含密钥，在仓库外、永不提交；不要把密钥写进任何被 git 跟踪的文件。
