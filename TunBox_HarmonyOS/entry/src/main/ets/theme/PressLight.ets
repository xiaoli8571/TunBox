/**
 * HDS 点按光效（点光源 + 按压阴影）—— 底栏「沉浸光感」的交互层。
 *
 * 2026-10-28 用户要求：底部 dock 要「沉浸光感 + 液态玻璃」。
 * 液态玻璃是**静态材质**（模糊/滤色/高光），沉浸光感是**交互态**：
 * 按下时有光从指尖亮起，并照亮周围声明了「受光」的兄弟组件。两者必须分开做，
 * 纯靠 `backgroundBlurStyle` 只能得到「糊一层玻璃」，按下时没有任何光反馈。
 *
 * ## 用的是 HDS（HarmonyOS Design System）的 hdsEffect，不是 oh_modules 三方包
 *  `@kit.UIDesignKit` 是 **DevEco SDK 自带的 HMS kit**（`sdk/default/hms/ets/kits/`），
 *  零依赖、无需 oh-package 声明、无需 module.json5 metadata。
 *  同机已验证可用的参照实现：NekoBox4Harmony `common/Effects.ets`（61 处调用，API 24 生效）。
 *
 * ## 官方约束（本机 SDK `@hms.hds.hdsBaseComponent.d.ets`，全部 @since 6.0.0(20)）
 *  · `pointLight` 的**宿主白名单**：Button / Toggle / Row / Column / Image / Flex / Stack /
 *    Select / Menu / MenuItem —— **没有 Text**。底栏页签宿主是 `Row`，在白名单内。
 *  · `pressShadow` **仅在 Button 上生效** ⇒ 底栏页签是 Row，这里传 NONE，不指望它。
 *  · `sourceType` 优先级高于 `options`（两个都写时 options 被吃掉）⇒ 只用 sourceType 预设。
 *  · `sourceType` = 自己**发光**并照亮**周围**声明了受光的组件；
 *    `illuminatedType` = 自己**受光**。两者语义别混，同一个 builder 里可以都写。
 *  · 光源位置固定在组件正中心、**不随位移变化**，官方不建议在滚动组件里挂点光源
 *    ⇒ 底栏是固定件，安全。
 *  · 受光组件若有 border，会**覆盖**受光效果 ⇒ 底栏页签的 Row 宿主本身不加 border
 *    （胶囊描边画在内层 Row 上，不冲突）。
 *
 * ## 为什么要有 `empty()` 兜底
 *  设备/系统版本不支持 HDS（`canIUse` 为 false，或 builder 抛错）时，
 *  `.visualEffect()` 仍需一个合法入参。`uiEffect.createEffect()` 返回一个**空效果**，
 *  即「什么都没加」，不会画错东西。这样调用点不需要分支，也不会因为一台老设备整栏不显示。
 */
import { hdsEffect } from '@kit.UIDesignKit';
import uiEffect from '@ohos.graphics.uiEffect';
import { AppLogger } from '../commons/utils/AppLogger';

const TAG = 'PressLight';

/** 能力探测只做一次（设备能力进程内不变） */
let probed: boolean = false;
let hdsOk: boolean = false;

function supported(): boolean {
  if (probed) {
    return hdsOk;
  }
  probed = true;
  try {
    hdsOk = canIUse('SystemCapability.UIDesign.HDSComponent.Core');
  } catch (e) {
    hdsOk = false;
  }
  if (!hdsOk) {
    AppLogger.info(TAG, 'HDS point light unsupported, press feedback falls back to scale only');
  }
  return hdsOk;
}

/** 空效果：不支持的设备上「什么都不加」 */
function empty(): VisualEffect {
  try {
    return uiEffect.createEffect();
  } catch (e) {
    // 连 uiEffect 都不可用（理论上不会发生）：退化为按压阴影，至少不崩
    return new hdsEffect.HdsEffectBuilder().buildEffect();
  }
}

/**
 * 页签按压光效：按下时该页签自己成为**点光源**（BRIGHT），
 * 同时它自己也声明 `BORDER_CONTENT` 受光 —— 于是按下 A 时，
 * 旁边同样挂了本效果的 B / C 会被一起照亮，形成「光在栏面上流动」的观感。
 *
 * @param pressed 当前是否按下（调用方用 `litTab === item.id` 判断「被按的是不是我」）
 */
export function dockPressLight(pressed: boolean): VisualEffect {
  if (!supported()) {
    return empty();
  }
  // 2026-10-29 真机取证的坑：以前未按压时也常驻挂着
  // `pointLight({ sourceType: NONE, illuminatedType: BORDER_CONTENT })`。
  // 看起来“没光源就不会有光”，但 **“受光”声明本身就是渲染指令**：
  // 每个页签用作宿主的 Stack 会被常驻画上一层矩形明暗（不遵守 borderRadius），
  // 而三个页签是紧挨的，拼起来就是一条**整栏宽的暗带**，位置在栏体上 1/3。
  // 量化后果：栏内 y≈2370-2420 比下半与栏外背景暗 16~25 级 ——
  // 就是用户连报三次的「dock 栏一半是阴影」。
  // （已排除：栏体自绘 `.shadow()` 删掉后像素纹丝不动；系统 `systemMaterial`
  //   在 hilog 里是 “Material inactive: out of scope”，根本没生效；
  //   抬高底部留白让内容退出模糊范围，像素也纹丝不动。）
  // ⇒ 未按压就返回**真正的空效果**，什么都不加；只有按下那一刻才上光。
  if (!pressed) {
    return empty();
  }
  try {
    return new hdsEffect.HdsEffectBuilder()
      // 页签宿主是 Row，pressShadow 只认 Button ⇒ 恒为 NONE，避免「看着像生效其实没生效」
      .pressShadow(hdsEffect.PressShadowType.NONE)
      .pointLight({
        sourceType: hdsEffect.PointLightSourceType.BRIGHT,
        illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT
      })
      .buildEffect();
  } catch (e) {
    AppLogger.warn(TAG, `build point light failed: ${AppLogger.errText(e)}`);
    return empty();
  }
}
