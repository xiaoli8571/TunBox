# 「手动更新去广告规则后 VPN 起不来」—— 根因与修复（2026-10-23）

> 用户报障（0.5.4）：「手动更新去广告规则后 vpn 就启动失败，删掉就启动正常了」。
> 版本：0.5.5（versionCode 519）。闸门：`scripts/verify-profile-merge-providers.mjs`（8 断言 + 负对照）。
> 真机证据：`docs/evidence/2026-10-23-do-ad-rules/ad-rules-connected.jpg`（MLR-AL00，去广告开启 + 1.29MB MRS 在位，已连接）。

## 1. 现象与第一手日志

真机 `hilog` 里扩展进程的原话（这次不是猜测，内核自己说的）：

```
VpnExtensionAbility: stage startCore done: ok=false
vpn onCreate failed: code=-1 msg=parse config:
  rules[0] [RULE-SET,hyper-adrules,REJECT] error: rule set [hyper-adrules] not found
```

即：最终配置里 `rules` 第一条引用了 provider `hyper-adrules`，但整份配置**没有**
`rule-providers:` 段 —— 引用在、声明丢，内核按「整份拒载」处理，隧道起不来。

用户侧的两种表现因此完全自洽：

| 操作 | 配置里有什么 | 结果 |
|---|---|---|
| 打开去广告 + 规则集文件在位 | `rules` 有 `RULE-SET,hyper-adrules,REJECT`；`rule-providers` **缺失** | 拒载，连不上 |
| 删掉规则集文件后重连 | `ruleProviderReady=false` → 规则行不生成、声明也不生成 | 正常连上（只是没有去广告） |

## 2. 根因：合并器把 overlay 的 provider 段「整段删掉」

`ProfileConfigMerger.merge(overlay, profile)` 的语义是「以 App 生成的 overlay 为根文档，
把订阅原文的 proxies / proxy-groups / … 搬进来」。原来的 `REPLACE_KEYS` 里有
`rule-providers`，处理方式是**先从 overlay 删掉、再追加原文的同名段**：

```ts
const REPLACE_KEYS = ['proxies','proxy-groups','sub-rules','proxy-providers',
                      'rule-providers','tunnels','listeners','rules'];
base = removeKey(base, 'rule-providers');   // ← overlay 的 hyper-adrules / rs-* 声明没了
```

而订阅原文（机场 YAML）**根本没有 `rule-providers` 段**，于是：

- overlay 的 `rules:` 走的是另一条路（overlay 规则 + 原文规则的拼接，**保留**），
  `RULE-SET,hyper-adrules,REJECT` 这一行活了下来；
- overlay 的 `rule-providers:` 被删掉且无人补上 → 声明消失。

`proxies` / `proxy-groups` 用「整体替换」是对的（原文才是节点与组的真源），
但 provider 是**按名字寻址的命名空间**，两边各自声明互不冲突，语义应该是**并集**，
同名时 overlay 优先（overlay 的 `path` 指向内核 home 里真实落盘的文件、URL 是用户填的）。

同一个缺陷也影响「自定义规则集（rs-*）」：只要订阅原文没有 provider 段，
用户自己加的 RULE-SET 同样会「引用在、声明丢」。

## 3. 修复

`entry/src/main/ets/commons/flclash/ProfileConfigMerger.ets`

- 新增 `PROVIDER_MERGE_KEYS = ['proxy-providers', 'rule-providers']`；
- provider 段不再走「整段替换」：
  - 仍从根文档移除（避免出现两个同名顶层键 → 内核报 duplicate key），
  - 随后**按键取并集**重新拼回：overlay 的块全保留，原文只补 overlay 没声明过的名字，
    同名丢弃并记日志（`profile provider(s) shadowed by overlay`）；
- 新增 `parseProviderSectionBlocks()`（纯缩进层级判定，字段行绝不外漏到顶层）
  与 `mergeProviderSection()`；两边都没有 provider 时不凭空造空段。

## 4. 验证

### 闸门（可重复跑，带负对照）

`node scripts/verify-profile-merge-providers.mjs --self-test`

- 8 条断言全部走**真实的** `ProfileConfigMerger`（true-chain-harness 生成的真源码）：
  原文无 provider 时 overlay 声明必须保留、RULE-SET 引用 ⊆ 声明、rules 首条顺序不变、
  原文自带 provider 取并集、同名 overlay 优先、`proxy-providers` 同理、
  不凭空造空段、字段行缩进不外漏。
- 负对照把常量改空（等价旧的整段替换）→ 结果 `rule-providers=[] refs=[hyper-adrules,rs-my-rules]`，
  **精确复现用户报障**，闸门判红。

### 真机（MLR-AL00）

```
RuntimeConfigBuilder: profile merged: mode=tunnel
  applied=proxies,proxy-groups,rule-providers,hosts,dns,rules items=46 bytes=405125
ConnectionOrchestrator: config promoted: kernel accepted ... (405125 bytes)
ConnectionOrchestrator: connected to node AWS-L-Hysteria2
```

去广告开关打开、`hyper_adrules_ads.mrs`（1.29MB / 162241 条）在位，界面「已连接，
公网 IP 141.11.146.77」，连接时长持续累加；live 配置里 `RULE-SET` 1 条、`hyper-adrules`
出现 2 次（声明 + 引用），自洽。

## 5. 顺带加固（同一轮，属另一类风险）

`ConnectionOrchestrator` 增加了规则集本体校验与失败自愈（防的是「下载到错误页/半截文件」
这一类，和本次「声明丢失」不是同一个根因，但同样会让内核拒载）：

- 下载校验从「体积 > 1024」升级为「体积下限 + **zstd 魔数** 0x28B5 2FFD」
  （合法 .mrs 是 zstd frame；GitHub 加速代理返回的 HTML/JSON 错误页体积也常超 1KB）；
- 就绪判定同源校验：坏文件 = 未就绪 = 本轮配置不带 RULE-SET（隧道照常能起）；
- 连接成功时把当前规则集快照成 `.good`；启动失败且错误文本指向规则集时先回滚 `.good`，
  没有副本则隔离成 `.bad-<时间戳>`（`scripts/verify-rule-provider-safety.mjs`，30 断言 + 3 负对照）。

## 6. 教训

1. **「引用」和「声明」必须由一个不变量保证**（引用 ⊆ 声明），不能靠两处独立判断碰巧一致；
   本次两类代码路径（provider 声明走「替换」，规则引用走「拼接」）分头演化就撞上了。
2. 报障里的「删掉就好」是最强的定位线索：删掉的东西只影响一个闸门 → 顺着闸门找谁把声明吃了。
3. 合并语义要按「键的性质」分类：资源集合（proxies/groups）替换、命名空间（providers）并集、
   序列（rules）拼接。一个 REPLACE_KEYS 一刀切必然埋雷。
