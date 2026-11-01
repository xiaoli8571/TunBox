# 顶栏「渐变模糊」怎么做（2026-10-31，最终版）

诉求原话三句，方向差一点就做反，先钉死：

1. 「软件顶部和手机状态栏我要模糊渐变的效果，现在有一个很明显的边界感。」
2. 「我是让你搞顶部，就是例如『设置』这一行改成渐变模糊的，不是下面正文变模糊。」
3. 「我要透明渐变模糊，逐渐变的模糊的效果。」

即：**顶栏这一条要透明，内容越靠上越糊、往下逐渐清晰 —— 模糊强度本身是渐变的。**

## 一、正解：官方 `linearGradientBlur`，不是 backdrop 分带

SDK 依据（`sdk/default/openharmony/ets/component/common.d.ts`）：

- `linearGradientBlur(value, options)`（since 12，`:19107`）：**前景**渐变模糊。
- `LinearGradientBlurOptions`（`:23786`）：`fractionStops` 是 `[模糊度, 位置]` 二元数组，
  位置取组件自身 0..1，**必须严格递增**；`direction` 默认 `GradientDirection.Bottom`。
- `backgroundEffect`（`:17946`）只有**单一 radius**，没有位置参数；`linearGradientBlur` 与它
  是两套东西 —— 顶栏自己那块「背景模糊」永远只能是均匀的。

结论：**渐变模糊要对滚动容器用**。内容在容器里滚动，越靠近顶部越糊、往下越清晰，
这就是「逐渐变模糊」；顶栏自己只留一层很淡的染色渐变。

官方文档（同一条接口的说明页）：
- <https://developer.huawei.com/consumer/cn/doc/harmonyos-faqs-V5/faqs-arkui-55-V5>（图片如何添加渐变模糊）

## 二、为什么之前所有版本都不对（教训表，别再走回去）

| 版本 | 做法 | 结果 |
| --- | --- | --- |
| 六修 | 矩形 `backgroundEffect` + 下沿 1vp 描边 | 矩形到头就是一刀，用户：「很明显的边界」 |
| 七修 | 染色+模糊切 32 条 1vp 横带 | 落差挤在 40px 内，变成「坡起点+坡终点」两道台阶 |
| 八修 A | 渐隐尾巴伸出顶栏 84vp | 正文被糊，用户明确否定 |
| 八修 B | `DST_IN` + `BlendApplyType.OFFSCREEN` 遮罩 | 最上面的字直接消失（离屏组内 backdrop 取样失效） |
| 九～十三修 | 18 / 8 条横带各自 `backgroundEffect`，半径逐级降 | 数值剖面很漂亮，但**每条带子各自对背景取样**，拼缝就是马赛克；条数、条高怎么调都救不回来 |
| **十四修（现行）** | 滚动容器 `linearGradientBlur` + 顶栏淡染色 | 系统插值算模糊，**天然连续**，无条块；透明；越往上越糊 |
| 十五修（现行补丁） | 把 `linearGradientBlur` 从 14 处收到 3 处，收口点压到 0.98× | 之前全量替换导致**静止时首项也糊**（「点订阅后第一个节点变模糊」）；渐变模糊必须只加在真的从顶栏下穿过的容器上 |

关键认知：**只要还在把背景切成横带分别 `backgroundEffect`，就一定有马赛克**。
这不是参数问题，是机制问题 —— 每条带子只拿到自己那一小块的底图样本。

## 三、现在的实现

### 1. 滚动容器（只有 3 处：首页 / 设置 / 数据的主滚动）

```ts
.linearGradientBlur(TunBoxGeometry.topBlurRadius(), {
  fractionStops: TunBoxGeometry.topBlurStops(),
  direction: GradientDirection.Bottom
})
```

**只给「真的从顶栏底下穿过去」的容器加**（`HomePage` / `SettingsPage` / `StatsPage` 主 Scroll，
它们的 padding top 是 `headerReserve()`）。其余 11 处（订阅列表、节点列表、规则页、弹层内的
List/Scroll）保持原来的 `.fadingEdge(...)`。

> 十五修的教训：一开始全量替换了 14 处，结果**静止状态下首项也糊** ——
> 因为 `linearGradientBlur` 的模糊区是绑在**容器视口顶部**的，不区分「有没有内容压到这里」。
> 弹层/子页的列表本来就从自己的顶部开始，首行必然落在模糊区里，用户看到的就是
> 「点订阅后第一个节点变模糊了」。
>
> 同时收口点也要收进 `headerReserve()` 以内（用 0.98×）：列表静止时首项正好从
> `headerReserve()` 那一行开始，收口放到 1.15× 会把首项顶边一起糊掉。

`TunBoxGeometry.topBlurRadius()` = 16；`topBlurStops()` 按**滚动容器高度**归一化：

- 0 → 顶栏 50% 处：满强度（状态栏 + 标题行这一片就是玻璃）；
- 到顶栏 98% 处：平滑收到 0 —— 静止时首项完全在清晰区，滚动时进顶栏才糊、出顶栏即清晰。

### 2. 顶栏自己（`components/TopNavBar.ets`）

只剩一层淡染色：一整条 `linearGradient`，alpha 按 `1 − smoothstep(t)` 从
`TINT_TOP_LIGHT = 0.20`（深色 0.12）收到 0。**没有任何 `backgroundEffect` 横带。**

### 3. 参数在哪调

| 想要的效果 | 改哪里 |
| --- | --- |
| 更糊 / 更清 | `TunBoxGeometry.topBlurRadius()`（当前 16） |
| 渐变拉长 / 缩短 | `topBlurStops()` 里 `0.55` / `1.15` 两个系数 |
| 更透 / 更实 | `TopNavBar.TINT_TOP_LIGHT` / `TINT_TOP_DARK` |

## 四、验收（MatePad Mini 悦读版，真机截图）

- 设置页上滑：顶部「网站分流」被平滑糊掉 →「代理 0 · 直连 0」已完全清晰 → 再往下卡片正常；
  过渡是连续的，**没有条块、没有台阶**（放大 2 倍逐像素看过）。
- 首页：顶栏几乎无感（透明），圆环顶弧完整不再被吃掉。
- 构建：`clean assembleHap` 成功；`node scripts/verify-ui-resource-bindings.mjs` 4 项 PASS。

## 五、复现

```bash
hvigorw --mode module -p module=entry@default -p product=default clean assembleHap --no-daemon
node scripts/verify-ui-resource-bindings.mjs
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
# 取证用 PNG：JPEG 会把 1~2 级的细节抹平，看不清渐变是否连续
hdc shell 'uitest screenCap -p /data/local/tmp/tunbox-probe-h.png'
```

## 六、还没做

- 深色主题未逐像素量过（同一套参数，理论上同形）。
- `topBlurRadius = 16` 是观感试出来的；如果觉得顶栏还不够糊，可以往上调，
  但**不要再回去用 `backgroundEffect` 分带**。
