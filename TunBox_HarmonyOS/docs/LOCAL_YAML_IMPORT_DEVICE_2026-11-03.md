# 本地 Ymihomo YAML 真机导入取证

日期：2026-11-03。范围：用户要求查看设备上本地 YAML 导入后没有节点的原因；仅取证，不改订阅、不切换配置、不安装、不实现修复。

## 现场与证据

- 安装版本为 `0.8.1 / 554`；首页本地订阅 `本地:Ymihomo` 标为使用中、`1 节点`，打开面板显示“该分组暂无可用节点”。
- 从应用 profiles 中读取当前导入文件，并对照实际 headless runtime YAML：两份都只有一个静态 `proxies` 条目，名字“直连”、类型 `direct`；都有 33 个 `proxy-groups`。
- 两份配置均只有一个远程 proxy-provider：`HH`，`type: http`，`url` 的实际内容是**字面值 `订阅URL`**，没有 http/https scheme，无 inline payload。
- 11:52:07（设备当地时间）的应用导入记录：识别 1 个 provider，导入 0 个 provider 节点；本地静态导入 1 个条目。
- 11:52:20 的内核错误：`initial proxy provider HH error: Get "%E8%AE%A2%E9%98%85URL": unsupported protocol scheme ""`。
- 通过临时 HDC 转发只读查询当前内核 `/providers/proxies`：`HH.proxies=[]`，即 0 个 provider 节点。
- `/proxies` 共 40 个条目，类型为 Selector 21、URLTest 7、Fallback 5、Direct 2、Compatible 1、Pass 1、PassRule 1、Reject 1、RejectDrop 1。没有 SS/VMess/VLESS/Trojan/Hysteria 等真实出站节点。33 个选择/测速/故障转移条目是策略组，不是 33 个真实代理节点。

## 补充对比：原结论遗漏了子策略组展示缺陷

用户随后提供 FlClash 截图，并明确本机已安装 FlClash、原文件位于下载目录。进一步只读核对：

- `Downloads/Ymihomo.yaml`、`Downloads/Telegram Desktop/Ymihomo.yaml`、FlClash 保存的 `profiles/375856785363308544.yaml` 三份均为 14,299 字节，SHA-256 均为 `7fbc92f302970c989f4b07409a15a2336b845fc8501925fd2871f86534a5a371`。不是电脑换了另一份 YAML。
- FlClash 当前 `config.yaml` 的 33 个 `proxy-groups` 与下载原文件逐项相等。
- “默认代理”声明 18 个直接成员，其中 17 个是子策略组（5 个 fallback、6 个 select、6 个 url-test），另一个是“直连”。截图显示的 Fallback/Selector/URLTest 卡片正对应这些合法的组成员。
- TunBox `SubscriptionSection.groupsOf` 从 CoreGroup 转换时丢弃 `isGroup` 成员；`corePanelNodes` 同样过滤 `!node.isGroup`；本地 `localPanelNodes` 调用 `expandProxyGroup`，把子组递归展平为最终节点。这些路径都会丢失应可展示、可选择的子组卡片。
- 因而“HH 的订阅 URL 未填写、真实远程节点为零”只是另一个独立问题，**不能解释或合理化 TunBox 把合法子分组隐藏并显示空列表**。先前只解释 provider 失败，没有完成分组展示兼容性的诊断，结论不完整。
- Windows 窗口截图接口重试后返回 `FrameArrived timed out`，未继续操作 FlClash 界面；对比证据来自用户截图、原文件、FlClash 保存文件和当前运行配置、TunBox 源码。没有声称成功抓取本机 FlClash 窗口。

正确修复方向是保留组直接成员的类型和顺序，将子组作为合法可选项显示；最终出站节点数与策略组数分开统计。`HH.url` 仍为占位符，应独立提示订阅地址未填写，不能伪造远程节点或擅用其他机场订阅替换。

## 结论与边界

已确认 TunBox 首页订阅面板存在嵌套策略组展示缺陷。本轮只诊断并更正文档，没有修改应用源码、构建或覆盖安装。

TunBox 的独立可改进项：缺失有效 provider URL 应给用户明确提示；“直连”计为 1 节点容易误导。日志另有动态组正则不兼容 warning，但本次远程节点为零已经被无效 provider URL 和内核实态充分解释，不能把正则 warning 当作这份配置缺少真实节点的唯一原因。

本次未修改用户订阅内容，未使用现有其他机场链接替换模板，未重导入，也未把原始 YAML、API secret 或完整应用日志写入本报告。

## 后续实现：嵌套分组、锚点水合与测速口径

用户随后明确要求修复，以上“仅取证”描述只适用于前面的诊断阶段。

### 补充根因

原文件组项使用 `{name: 默认代理, <<: *S1}`。旧 `SubscriptionParser` 不展开 YAML 锚点，
直接解析原文会留下名字但丢掉继承的 `type/proxies`。`ProfileRepository.validateAndStore`
已经通过 native preparer 展开完整文档并保存，但导入、刷新仍解析原文，而初始化只在
完全没有组时才修复。因此仅去掉 UI 的 `isGroup` 过滤仍不足以修复已导入的空组。

### 修复内容

- 本地导入、远程刷新从已验证、展开别名的 profile 解析 UI 节点、分组和 provider；原文仓不改。
- 初始化从完整 profile 一次性校正存量组，即使组名已经存在也恢复继承成员；不用重新导入，
  不在每次 UI 渲染时重复读取文件。无完整 profile 时保留旧结构化缓存的缺组恢复路径。
- `ProxyPanelMembers` 保留直接成员顺序和组类型，严格隔离订阅，不把子策略组展平为最终节点。
  单列、双列共用点击逻辑；组不是可本地删除或凭据拨号的普通节点。
- Selector 的直接成员选择按“订阅 ID + 父组名”保存；已连接只向指定父组 PUT，
  离线仅保存意图。启动叶子钉选后限时恢复有效选择，跳过失效/跨订阅/只读组。
- 卡片分开统计真实代理与声明分组，排除自定义名字的 Direct/Reject/Pass 等策略。
  本文件显示 `0 节点 · 33 分组`；GLOBAL 是否在当前模式隐藏不会令声明计数跳动。
- 测速使用当前可见组的直接成员，子策略组也有自己的延迟记录；不再只测展平的叶子。
  没有真实代理时不启动空批次、不报完成；成功、超时、失败、取消按实态反馈。
- headless 测速核的已确认、带订阅归属的快照也可供离线面板显示 provider 成员；
  测速准备期间切订阅会拒绝迟到快照，不能串用别的订阅或覆盖新的归属戳。

### 已执行的回归与真机验证

- `verify-proxy-panel-members.mjs`：17 项真实生产方法运行测试通过；同时传入下载原文件
  与设备保存的 native-prepared 文件，验证原文锚点会使旧解析缺成员、升级水合恢复且幂等，
  以及 33 组 / 默认 18 个成员 / 17 个子组。平台、设置、网络边界有桩，不冒称完整设备测试。
- CoreCatalog 39/39、provider 可见性 9/9、VPN 架构 322/322、延迟显示契约 55/55；
  FlclashDelay 11/11、真实 LatencyEngine（边界有桩）27/27。
- 既有诊断日志 10/10、网络切换 21/21、配置单一真源 42/42、纯逻辑 228/228；
  启动资产 46/46（含参考 Windows 内核 64 次配置校验、4 次 live core 启动）。
- 中间构建 555、556 均 clean 编译成功并立即通过资源门禁 4/4，覆盖安装成功，订阅和设置保留。
  555 真机可见 Fallback/Selector/URLTest 卡片，单/双列均正常；556 真机在模板测速时明确提示
  “没有可测速的代理节点：请检查订阅地址和 provider 是否加载成功”。
- 556 在现有 Nexpanel 上实际点击测速：AUTO 子组 80ms，三个真实节点分别 84/107/74ms，
  另一个节点明确显示“拨号失败”；完成提示 `4 成功，0 超时，1 失败`。
  只是显式 headless 延迟探测，没有开启 VPN，也不以此声称模板 provider 已修复。
- 验证后切回 `本地:Ymihomo`。5 份 profile 文件 SHA-256 与装机前逐项一致。

限制：当前模板的 `HH.url` 仍是字面值 `订阅URL`，真实 provider 节点仍为零。
这里修复应用兼容性与错误反馈，不替用户填写机场地址，也不伪造节点或延迟。
已连接 PUT、重连后选择恢复在运行回归中验证；本模板缺少真实代理，未以它做 VPN 连通性验收。

### 最终真机安装：0.8.1 / 557

- 构建命令（本机 DevEco `tools/hvigor/bin/hvigorw.bat`）：
  `--mode module -p module=entry@default -p product=default -p buildMode=release -p debugLine=false clean assembleHap --no-daemon`。
  SDK=`C:/Program Files/Huawei/DevEco Studio/sdk`，Java=`.../jbr`，Java bin 已加入 PATH。
- BUILD SUCCESSFUL，1m11s563ms，34 个任务全部执行；随后立即执行
  `node scripts/verify-ui-resource-bindings.mjs`，4/4 PASS。仍有既有 SDK/废弃 API warning。
- 临时本地 debug profile 仅用于侧载签名；结束恢复 release 空签名配置，
  `verify-build-profile.mjs` 13/13 PASS。没有把本机证书材料纳入源码。
- 覆盖安装后 `bm dump` 复核 `0.8.1 / 557 / appProvisionType=debug`。
  557 真机截图显示 `0 节点 · 33 分组`、默认组的 18 个直接成员（双列完整可见），
  原来的“狮城手动”选择在重启后仍高亮；设置落盘值也保持 manual 与同一条父组选项。
- 557 再次实际点击模板测速，明确提示没有可测速的代理节点，计数仍为 33，不因 GLOBAL 隐藏跳为 32。
- 安装包与三次 clean 编译日志归档到 `C:/Worker/_archive/TunBox-0.8.1-557-validation/`；
  device HAP SHA-256=`487d2a3502b6624205752465ce83fb230d288222296d081d60f5dd51a05e3898`。
  证据截图 `final-panel.jpeg` 仅在该本地归档中，不提交个人截图。
- 本轮只生成、安装设备验证 HAP，没有替换 dist 中既有 554 发布 APP/HAP，也没有上传 AGC、发布或提交。
