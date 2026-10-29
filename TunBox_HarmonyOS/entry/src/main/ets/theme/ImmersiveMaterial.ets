/**
 * 沉浸光感系统材质（HarmonyOS Design 的 `uiMaterial.ImmersiveMaterial`，API 26）。
 *
 * 2026-10-28 用户要求：底部 Dock 改成「沉浸光感 + 毛玻璃」。
 *
 * ## 为什么走系统材质，而不是自己调 blur
 * 自绘毛玻璃（半透明底 + `backgroundBlurStyle`）只能得到「糊一层」的效果：
 *  - 没有光感交互反馈（按下时材质里亮起一道光）；
 *  - 不会跟背景自适应互补色，浅色/深色下要么发灰要么发白；
 *  - 边缘高光（光学描边）与投影都得自己一条条调，和系统其它浮层（弹窗、Toast、
 *    bindSheet）材质观感不一致。
 * `ImmersiveMaterial` 把上面四件事都交给系统材质层，观感与系统浮层完全一致。
 *
 * ## 生效前提（缺一不可）
 *  1) `module.json5` 的 metadata 打开应用级开关：
 *     `{ "name": "ohos.arkui.UIMaterial.state", "value": "enable" }`（已配置）；
 *  2) `targetSdkVersion >= 26.0.0`（build-profile.json5 已配置；官方《开启沉浸光感》硬性要求）；
 *  3) 设备能力：`uiMaterial.isImmersiveMaterialSupported()` 为 true（低端机/旧设备可能为 false，
 *     此时必须回落到自绘毛玻璃，不能留一张透明片）。
 *
 * ## 为什么做成「可失败」的工厂而不是直接 new
 * 该 API 在 API 26 之前的设备/系统上不存在：`uiMaterial` 模块导入本身在旧版本上是可用的
 * （kit 桩存在），但调用 `isImmersiveMaterialSupported` 之外的行为可能抛错。这里统一
 * try/catch，失败一律返回 undefined，调用点只需要判空 —— 底栏永远能画出东西。
 *
 * ## 2026-10-29 复盘：AGC 兼容性测试报「应用启动失败」（0.7.1，崩溃在
 * `FloatingBottomBar.rebuildMaterial`）。两处漏防，都在本文件之外，只包工厂不够：
 *  ① 调用点把 `uiMaterial.ImmersiveStyle.REGULAR/THIN` 写在**实参位置** —— 实参先于
 *     被调函数求值，异常在 try/catch **之外**就抛了；
 *  ② `.systemMaterial()` 是 API 26 才加进 `CommonMethod` 的属性方法（common.d.ts:
 *     `systemMaterial(material: SystemUiMaterial | undefined): T`），旧系统运行时的
 *     属性对象上根本没有它，`build()` 里调用即 `TypeError`，整页渲染失败。
 * 现在改成：档位由布尔 `dark` 在**工厂内部**挑选；属性一律通过 `ImmersiveMaterialAttr`
 * （`AttributeModifier<CommonAttribute>`）挂载，其 `applyNormalAttribute` 是普通函数，
 * 调用失败只损失材质、不影响渲染。组件侧不再 import `uiMaterial`。
 */
import { uiMaterial } from '@kit.ArkUI';
import { AppLogger } from '../commons/utils/AppLogger';

const TAG = 'ImmersiveMaterial';

/** 一次能力探测（进程内缓存：设备能力不会中途变化，不必每次进页面都问一遍） */
let probeDone: boolean = false;
let supported: boolean = false;
/** 旧系统上 `CommonMethod` 没有 `systemMaterial`：撞一次就永久放弃，别每次重建都刷日志 */
let attrUnavailable: boolean = false;
/**
 * 当前生效的材质。挂载点（`applyNormalAttribute`）只读这份模块级引用，
 * 而不是自己持有一份 `uiMaterial.Material`：原生材质对象不该被塞进 `@State` 的观察代理里。
 */
let activeMaterial: uiMaterial.Material | undefined = undefined;
/** 材质成功上屏时打一条日志（仅一次）：用于确认 `attributeModifier` 链路真的被调用 */
let attrAppliedLogged: boolean = false;

export class ImmersiveMaterial {
  /** 当前设备是否支持沉浸光感材质 */
  static isSupported(): boolean {
    if (probeDone) {
      return supported;
    }
    probeDone = true;
    try {
      supported = uiMaterial.isImmersiveMaterialSupported();
    } catch (e) {
      supported = false;
      AppLogger.warn(TAG, `isImmersiveMaterialSupported failed: ${AppLogger.errText(e)}`);
    }
    if (!supported) {
      AppLogger.info(TAG, 'immersive material unsupported on this device, dock falls back to drawn glass');
    }
    return supported;
  }

  /**
   * 造一块沉浸材质。
   *
   * @param dark  深/浅色主题。**档位必须在内部挑**：`uiMaterial.ImmersiveStyle` 是 API 26
   *              才有的枚举，若由调用点解引用，旧系统上会在进入本函数前就抛 TypeError。
   *              深色用 REGULAR（内容更花，需要压住），浅色用 THIN（透光强，浮层轻盈）。
   * @param tint  染色层颜色，**必须带透明度**，否则会把材质滤色整个挡死（官方约束）
   * @param light 光感反馈色：按下时材质里亮起的那道光
   */
  static create(dark: boolean, tint: ResourceColor, light: ResourceColor): uiMaterial.Material | undefined {
    if (!ImmersiveMaterial.isSupported()) {
      return undefined;
    }
    try {
      const style: uiMaterial.ImmersiveStyle =
        dark ? uiMaterial.ImmersiveStyle.REGULAR : uiMaterial.ImmersiveStyle.THIN;
      // 光感交互反馈：这是「沉浸光感」的核心 —— 触摸位置亮起一道光。
      // 单独声明成 LightEffectOptions 局部变量：`lightEffect?: LightEffectOptions | null` 是联合类型，
      // 直接内联对象字面量会被 ArkTS 的 `arkts-no-untyped-obj-literals` 拦下（推不出具体类型）。
      const effect: uiMaterial.LightEffectOptions = { color: light };
      const options: uiMaterial.ImmersiveOptions = {
        style: style,
        materialColor: tint,
        // 交互形变：按下去材质本身轻微「压扁」，和系统浮层手感一致
        interactive: true,
        // 2026-10-28 用户「底框有一半是阴影的，不好看」⇒ 关掉材质自带阴影。
        // 材质阴影是**环绕一整圈**的，而底栏只有 64vp 高，一圈阴影直接吃满下半栏
        // （真机实测 y 2360–2420 比背背景暗约 20 级，看上去像底栏自己发黑）。
        // 改成由调用点自己画一个**只向上**的投影（offsetY 为负）。
        applyShadow: false,
        lightEffect: effect
      };
      return new uiMaterial.ImmersiveMaterial(options);
    } catch (e) {
      AppLogger.warn(TAG, `create immersive material failed: ${AppLogger.errText(e)}`);
      return undefined;
    }
  }

  /**
   * 造一个可挂到 `.attributeModifier(...)` 的挂载器（材质不支持的设备返回「空挂载器」，
   * 什么都不做 —— 调用点不需要判空，底栏始终能画出自绘毛玻璃）。
   */
  static modifier(dark: boolean, tint: ResourceColor, light: ResourceColor): ImmersiveMaterialAttr {
    activeMaterial = ImmersiveMaterial.create(dark, tint, light);
    return new ImmersiveMaterialAttr();
  }
}

/**
 * 沉浸材质挂载器。
 *
 * 为什么必须走 `AttributeModifier` 而不是直接 `.systemMaterial(m)`：
 *  `systemMaterial` 是 API 26 才加进 `CommonMethod` 的属性方法。旧系统（AGC 兼容性
 *  测试机很可能是这种）运行时的属性对象上没有这个方法，`build()` 里调用就抛
 *  `TypeError`，整页渲染失败 → 「应用启动失败」。
 *  `applyNormalAttribute` 是普通函数，可以 try/catch：调不到就只是没有系统材质，
 *  底栏退回自绘毛玻璃，绝不影响启动。
 *
 * 为什么不用字段持有材质：`@State` 会把实例包进观察代理，把原生 `uiMaterial.Material`
 *  挂在被观察对象上没有必要也有风险；材质放模块级 `activeMaterial`，这里只做转发。
 */
export class ImmersiveMaterialAttr implements AttributeModifier<CommonAttribute> {
  applyNormalAttribute(instance: CommonAttribute): void {
    const m: uiMaterial.Material | undefined = activeMaterial;
    if (m === undefined || attrUnavailable) {
      return;
    }
    try {
      instance.systemMaterial(m);
      if (!attrAppliedLogged) {
        attrAppliedLogged = true;
        AppLogger.info(TAG, 'systemMaterial applied via attributeModifier');
      }
    } catch (e) {
      attrUnavailable = true;
      AppLogger.warn(TAG, `systemMaterial unavailable, keep drawn glass: ${AppLogger.errText(e)}`);
    }
  }
}
