# 自动选择启动报错修复（2026-10-25）

## 现象

自动选择（`autoSelectMode = AUTO`）模式下点连接，立即失败，UI 提示「已保留原配置」。

真机 hilog（`com.tunbox.client`）：

```
E ConnectionOrchestrator: connect failed: 配置校验未通过：最终配置未通过内核检查
  （proxy group[2]: ♻️ 自动选择: '\U0001F1EF\U0001F1F5日本•移联01' not found）。已保留原配置
```

关键点：**报错里的节点名带字面反斜杠 `\U0001F1EF`**，而用户屏幕上的节点名是 🇯🇵 国旗 emoji。

## 根因

三环相扣，缺一不成立：

1. **订阅导入时被重序列化。** `ProfileStore.validateAndStore` → `coreBridge.prepareProfile`
   → 内核 Go 侧 `config.PrepareProfile`（`mihomo-build/.../config/profile_prepare.go`）
   把整份 YAML `yaml.Unmarshal` 后又 `yaml.Marshal`，落盘到 `<filesDir>/profiles/<id>.yaml`。
   该 marshal 把**非 BMP 字符（国旗 emoji，U+1F1EF 等）写成双引号转义**：

   ```yaml
   name: "\U0001F1EF\U0001F1F5日本•移联01"      # 双引号：YAML 会解成真 emoji
   ```

2. **App 侧解码不完整（本 bug 的真正缺陷）。** `YamlMerger.decodeScalar` 处理双引号标量时
   只还原 `\"` 和 `\\`：

   ```ts
   return inner.replace(/\\"/g, '"').replace(/\\\\/g, '\\');   // 修复前
   ```

   不认 `\U` / `\u` / `\x` / `\t` 等转义 → `sequenceItemNames` 读出的节点名**带字面反斜杠**。

3. **注入把错名字写进配置。** `ProfileConfigMerger.injectSmartPrimary` 用这些名字
   （经 `yamlQuote` 包成**单引号**，单引号在 YAML 里不做转义）生成 smart 组成员：

   ```yaml
   proxies:
     - '🇯🇵日本•移联01'        # 期望：真 emoji
     - '\U0001F1EF\U0001F1F5日本•移联01'   # 实际：字面反斜杠，与节点名不等
   ```

内核在同一份文档里按 YAML 规范把 `proxies` 的 `"\U0001F1EF..."` 解成真 emoji，
而组成员是字面反斜杠 → **寻址失败 → `proxy group[N] ... not found` → 整份拒载**。
每次自动模式连接都会重现（注入无条件执行）。

## 修复

`entry/src/main/ets/commons/services/YamlMerger.ets`

- 新增 `YamlMerger.unescapeDoubleQuoted(inner)`：按 YAML 1.2 规范完整实现双引号标量转义
  —— `\0 \a \b \t \n \v \f \r \e \" \/ \\ \N \_ \L \P \xXX \uXXXX \UXXXXXXXX`，并处理行尾折行。
- `decodeScalar` 的双引号分支改为调用它。
- 无法识别的转义**原样保留**（不猜、不吞），避免改坏用户真实值。
- **单引号分支不动**：YAML 单引号不做转义，`'\U0001F1EF'` 必须保持字面。

## 验证

用真内核 `mihomo-smart`（与设备同款内核）直接 `-t` 校验同一份真实订阅生成的配置：

| 配置 | 结果 |
|---|---|
| 修复前（字面反斜杠成员） | `proxy group[2]: ♻️ 自动选择: '\U0001F1EF...日本•移联01' not found` → **test failed** |
| 修复后（真 emoji 成员） | `[Smart] Model file loaded successfully` → **test is successful** |

隔离实验（`quote-test.yaml`）证明引号语义是直接原因：

```yaml
proxy-groups:
  - name: 双引号组
    proxies: ["\U0001F1EF\U0001F1F5日本•移联01"]   # ✅ 匹配成功
  - name: 单引号组
    proxies: ['\U0001F1EF\U0001F1F5日本•移联01']   # ❌ not found
```

门禁：`scripts/verify-smart-inject-unicode-names.mjs`（新增，16 项断言）

- 直接加载 `YamlMerger.ets` / `ProfileConfigMerger.ets` **源文件本体**做断言，不在垫片里重写逻辑。
- **负对照已做实**：对 `HEAD`（修复前）源码跑同一门禁 → **7 项失败**（`\U`/`\u`/`\x`/`\t` 解码 +
  全链 emoji 断言）；对修复后源码 → **16 项全通过**。门禁不是空跑。

其余门禁：`verify-all --only yaml,merge,config,smart` = 10/10 PASS；
`verify-arkts-compile` 3/3 PASS（真 ArkTS 编译器）；`verify-ui-resource-bindings` PASS；
清理构建 `clean assembleHap` BUILD SUCCESSFUL。

既有失败（与本修复无关，`git stash` 基线复现同样 6 项）：
`verify-flclash-profile` / `verify-generator-fingerprint` / `verify-latency-concurrency` /
`verify-latency-engine-runtime` / `verify-review-runtime` / `verify-sub-parse-fidelity`。

## 教训

- **「同一份 YAML 里两个名字看起来一样」不等于内核认为一样。** 引号风格决定是否解码转义：
  双引号解，单引号不解。凡是从订阅原文抄名字再拼回 YAML 的地方，都要保证**解码后的名字**参与比对。
- **`PrepareProfile` 重序列化是名字的「变换点」**，它会把非 BMP 字符改成 `\U` 转义。
  任何读 profile 文本再寻址节点的代码路径都必须按 YAML 规范解码，不能只做「够用就行」的两次 replace。
- 排查顺序价值：先拿**设备真实 hilog + 设备真实 profile + 真实内核 `-t`** 三方对齐，
  再进代码。仅看代码会以为是注入缩进/格式问题（前两次提交 ca5504f / cd000a6 修的就是那类问题），
  实际是名字编码不一致。

## 真机复测（2026-10-25 已补做，通过）

原先卡在「装机装不上」，后来用仓库现成的 `switch-signing.ps1 -Mode debug` 切到 DevEco debug
签名（脚本内是 DevEco 的加密口令块，不需要明文密码），`clean assembleHap` 后
`install bundle successfully`，装机链路打通。

设备实测（`192.168.3.146:39933`）：

- 冷启动 + 自动选择模式连接成功，不再出现
  `proxy group[2]: ♻️ 自动选择: '...' not found` 这类整份配置被拒的错误；
- 切换订阅后 `smart group injected: primary=吹雪云 members=24`、`primary=PROXY members=5`
  均正常注入，`proxy group[...] not found` 计数为 **0**。

> 结论：修复已从「真内核 `-t` 静态验证」升级为「真机端到端验证通过」。
> 遗留的 debug/release 签名切换约定见根目录 `Nexus-HarmonyOS-开发踩坑记录.md` 坑 15。
