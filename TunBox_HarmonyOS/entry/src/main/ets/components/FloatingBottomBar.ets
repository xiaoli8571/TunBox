/**
 * 底部悬浮导航栏 —— 严格对齐《TunBox-UI重构笔记》§2.2 FloatingBottomBar
 *
 * 几何：86% 宽 / 64 高 / 32 圆角 / 底部外边距 0（沉浸式贴手势区）。
 *  2026-10-26 用户要求「三个按钮间距稍微缩小一点点」：栏宽 92% → 86%
 *  （两侧各收 3%，三个页签整体向中间靠一点，页签间距随之略微变小）。
 *
 * 三项：主页(0) 订阅(1) 设置(2)；选中项=椭圆胶囊高亮（primaryLight 底 + primaryBorder 描边，
 * 图标与名称同一行、图标在前，2026-10-17 用户要求）。
 *
 * ── 液态玻璃 + 沉浸光感（2026-10-28 用户要求）──────────────────────────────
 * 这两件事必须**分开做**，缺一个都不是「液态玻璃」：
 *
 *  ① 液态玻璃（静态材质层）—— 三层叠加：
 *     a. `backgroundEffect({ radius, saturation, brightness })`：真·背景模糊 +
 *        **饱和度提升**。这一层是关键：`backgroundBlurStyle` 只能把背后「糊一层」，
 *        而 `saturation > 1` 会把背后的颜色**吸上来**，这才是玻璃「折射」的观感。
 *     b. 极淡的染色渐变（alpha 0.10~0.30）：把玻璃压到当前背景配色系里，
 *        不压的话磨砂层会发灰发白、和薄荷/暖米背景脱开。
 *     c. 顶部镜面高光（`sheenLayer()` overlay）：从亮白快速衰减到透明的窄带，
 *        模拟玻璃棱边反光。没有它，材质看起来是「塑料」而不是「玻璃」。
 *     `backgroundBlurStyle(COMPONENT_THICK)` 已**删除**：COMPONENT_* 自带一层近乎
 *     opaque 的填充色，会把 a/b 两层整个吃掉（实测观感「完全不透」）。
 *
 *  ② 沉浸光感（交互层）—— `theme/PressLight.ets` 的 HDS `hdsEffect` 点光源：
 *     按下页签时该页签成为点光源（BRIGHT），旁边同样挂了受光的页签会被一起照亮。
 *     同时保留 2026-10-17 的 `dockGlow` 瞬时亮帧 + 扩散淡出，以及
 *     `PRESS_SCALE` 级的 0.96 缩放兜底（点光源在不支持的设备上不显示时，
 *     用户仍能确认「点击有响应」）。
 *
 *  ③ 系统沉浸材质（`systemMaterial`，API 26）优先：设备支持时由系统材质接管，
 *     它会覆盖 backgroundColor / blur / shadow / border —— 所以自绘那套属性直接保留，
 *     不需要按能力分支写两份 UI。
 *     ⚠ 但材质自带的 `applyShadow` 是**环绕一整圈**的大阴影，已显式关掉，
 *     阴影改由下面 `dockShadow` 自绘（只留上沿一点点）。
 *
 * ── 切页签粒子（2026-10-28）──────────────────────────────────────────────
 * 用户先要求「切换菜单时增加粒子特效」，再要求「粒子再多几倍」⇒ 由 10 粒 → 24 粒 → **96 粒**：
 * 4 圈半径（18/30/42/56vp）× 4 档粒径（6/5/4/3）× 3 档配色 + 起跑延迟错峰，
 * 呈「一束光尘」而不是「一圈等距齿轮」。
 * 全部由**单一** `sparkProgress`（0→1，一次 `animateTo`，520ms）驱动 ——
 * 不跑逐帧定时器：UnifiedScheduler 最小帧间隔 250ms，520ms 的爆发只能拿到 2 帧，
 * 粒子会「跳」而不是「飞」。错峰靠每颗粒子自己的归一化延迟 `delay` 在表达式里做，
 * 不额外增加动画实例。
 *
 * ── 切页签滑行光影（2026-10-28 用户要求）──────────────────────────────
 * 用户描述：「切换菜单的同时会有光影从底部划过，滑到对应的菜单。例如从主页切换到
 * 设置，会有一团光影从主页一直滑动到设置下面然后消失」。
 * 与粒子同一套打法：单个 `sweepP`（0→1，一次 `animateTo`）同时驱动位移与透明度，
 * 不跑逐帧定时器。位移需要**页签中心 x**，而页签中心取决于栏体真实宽度，
 * 所以用 `onAreaChange` 量一次 `dockW`；量不到（=0）时直接不画光影，
 * 也不能按百分比猜位置 —— 百分比 `position` 不参与动画插值，会瞬移。
 */
import { TunBoxColors, TunBoxGeometry } from '../theme/TunBoxTokens';
import { TunBoxTextColors } from '../theme/TextColors';
import { ThemeService } from '../theme/ThemeService';
import { ImmersiveMaterial, ImmersiveMaterialAttr } from '../theme/ImmersiveMaterial';
import { dockPressLight } from '../theme/PressLight';

interface DockTab {
  id: number;
  title: string;
  icon: Resource;
}

/**
 * 光尘粒子：角度/半径/粒径/延迟全部在模块加载时算好并**固定**下来。
 * 不用 Math.random —— 每次点击形态都不一样会让动画看起来「抖」，
 * 用由索引派生的确定性抖动（`fract(sin(n)·k)`）既能打散「齿轮感」又完全可复现。
 */
class DockSpark {
  /** 飞行方向（弧度） */
  readonly angle: number;
  /** 最终位移距离（vp） */
  readonly dist: number;
  /** 粒径（vp） */
  readonly size: number;
  /** 归一化起跑延迟（0 = 立刻出发） */
  readonly delay: number;
  /** 1 - delay，预先算好避免每帧重复减法 */
  readonly span: number;
  /** 配色档 0/1/2 */
  readonly tone: number;

  constructor(angle: number, dist: number, size: number, delay: number, tone: number) {
    this.angle = angle;
    this.dist = dist;
    this.size = size;
    this.delay = delay;
    this.span = 1 - delay;
    this.tone = tone;
  }
}

/** 确定性伪随机：同一个 n 永远得到同一个 [0,1) 值 */
function fract01(n: number): number {
  const v = Math.sin(n * 12.9898) * 43758.5453;
  return v - Math.floor(v);
}

const DOCK_SPARK_COUNT: number = 96;
const SPARK_DURATION_MS: number = 520;

/**
 * 滑行光影时长比粒子短一档：光先到、尘后散，观感上像「光跑到那一格才踩炸粒子」，
 * 而不是两件事糊在一起。
 */
const SWEEP_DURATION_MS: number = 440;
/** 光团宽度占单格页签的比例（不足一格，才不会同时照亮两侧页签） */
const SWEEP_BLOB_RATIO: number = 0.78;
/** 光团高度与模糊半径（vp）：横向长、竖向短 + 大模糊 ⇒ 一团拖在底部的光 */
const SWEEP_BLOB_H: number = 20;
const SWEEP_BLOB_BLUR: number = 15;

/**
 * 96 粒：扇面 -176°→-4°（向上 172°）。
 * 角度仍按序号**均匀**铺开（保证左右对称、不留空档），只叠加 ±2.5° 抖动打散齿轮感。
 */
function buildSparks(): DockSpark[] {
  const list: DockSpark[] = [];
  for (let i = 0; i < DOCK_SPARK_COUNT; i++) {
    const jAngle = fract01(i + 1);
    const jDelay = fract01((i + 1) * 3.7);
    const jDist = fract01((i + 1) * 7.3);
    const deg = -176 + (168 * i) / (DOCK_SPARK_COUNT - 1) + (jAngle - 0.5) * 5;
    const rad = (deg * Math.PI) / 180;
    // 4 圈交错：内圈大而近、外圈小而远（像真实光尘，不是一圈等距齿轮）
    const ring = i % 4;
    const baseDist = ring === 0 ? 18 : (ring === 1 ? 30 : (ring === 2 ? 42 : 56));
    const baseSize = ring === 0 ? 6 : (ring === 1 ? 5 : (ring === 2 ? 4 : 3));
    // 错峰：外圈晚出发，形成「由内向外扩散」的一束
    const delay = ring * 0.055 + jDelay * 0.12;
    list.push(new DockSpark(rad, baseDist + jDist * 8, baseSize, delay, i % 3));
  }
  return list;
}

const DOCK_SPARKS: DockSpark[] = buildSparks();

@Component
export struct FloatingBottomBar {
  @StorageLink('theme_revision') @Watch('onThemeRevision') themeRevision: number = 0;
  @Link currentTab: number;
  /** 点击回调（可选）：宿主据此控制切页签时机；不传则直接写 currentTab */
  onSelect?: (index: number) => void = undefined;
  /** 正在扩散光晕的项（-1 = 平静） */
  @State private rippleTab: number = -1;
  /** 光晕相位：false=刚点亮，true=已扩散并淡出 */
  @State private rippleSpread: boolean = false;
  /** 粒子爆发归属页签（-1 = 无）/ 进度 0→1 */
  @State private sparkTab: number = -1;
  @State private sparkProgress: number = 0;
  /** HDS 点光源宿主：当前按下的页签（-1 = 无） */
  @State private litTab: number = -1;
  /**
   * 栏体实测宽度（vp）：滑行光影要按「页签中心」定位，必须先知道真实宽度。
   * 量不到时宁可不画 —— 按百分比猜位置会因为 `position` 不参与插值而直接瞬移。
   */
  @State private dockW: number = 0;
  /** 滑行光影：起点页签 / 终点页签（-1 = 未激活）/ 进度 0→1 / 是否在画 */
  @State private sweepFrom: number = -1;
  @State private sweepTo: number = -1;
  @State private sweepP: number = 0;
  @State private sweepOn: boolean = false;
  /**
   * 当前沉浸材质挂载器（空挂载器 = 设备/系统不支持 → 走自绘毛玻璃）。
   * 这里**不持有** `uiMaterial.Material`：原生对象留在 `ImmersiveMaterial` 内部。
   * 换主题时换一个新的挂载器实例，保证 `attributeModifier` 重新 apply 一次。
   */
  @State private dockAttr: ImmersiveMaterialAttr = new ImmersiveMaterialAttr();
  private rippleTimer: number = -1;
  /** 淡出启动定时器：亮帧先直接上屏，隔 50ms 再启动淡出（同帧启动 animateTo 会把亮帧吞掉） */
  private rippleFadeTimer: number = -1;
  private sparkTimer: number = -1;
  private sparkResetTimer: number = -1;
  private sweepStartTimer: number = -1;
  private sweepEndTimer: number = -1;

  aboutToAppear(): void {
    this.rebuildMaterial();
  }

  aboutToDisappear(): void {
    this.clearTimer(this.rippleTimer);
    this.clearTimer(this.rippleFadeTimer);
    this.clearTimer(this.sparkTimer);
    this.clearTimer(this.sparkResetTimer);
    this.clearTimer(this.sweepStartTimer);
    this.clearTimer(this.sweepEndTimer);
    this.rippleTimer = -1;
    this.rippleFadeTimer = -1;
    this.sparkTimer = -1;
    this.sparkResetTimer = -1;
    this.sweepStartTimer = -1;
    this.sweepEndTimer = -1;
  }

  onThemeRevision(): void {
    this.rebuildMaterial();
  }

  private clearTimer(id: number): void {
    if (id >= 0) {
      clearTimeout(id);
    }
  }

  /**
   * 材质随主题重建：浅色用 THIN（透光强，浮层轻盈），深色用 REGULAR（内容更花，需要压住）。
   * 每次 theme_revision 变化都重建一次（深/浅切换、浅色背景配色切换都会 bump 修订号）。
   */
  private rebuildMaterial(): void {
    const dark: boolean = ThemeService.isDark();
    // 为什么整段还包 try/catch：`ImmersiveMaterial.modifier` 内部已全部造错保护，
    // 但 `aboutToAppear` 里挂的东西不允许有任何漏网的异常（AGC 兼容性测试里
    // 0.7.1 就是在这里抛出去→「应用启动失败」），多一层兵不影响观感也几乎无开销。
    try {
      this.dockAttr = ImmersiveMaterial.modifier(
        dark,
        TunBoxColors.dockMaterialTint(this.themeRevision),
        TunBoxColors.dockLightEffect
      );
    } catch (e) {
      this.dockAttr = new ImmersiveMaterialAttr();
    }
  }

  /**
   * 单颗粒子的当前进度：`delay` 之前恒 0，之后在剩余时长里线性跑完 1。
   * 表达式里读 `this.sparkProgress` ⇒ 该属性天然成为本元素的依赖，动画每帧自动重算。
   */
  private sparkT(s: DockSpark): number {
    const raw = (this.sparkProgress - s.delay) / s.span;
    return raw < 0 ? 0 : (raw > 1 ? 1 : raw);
  }

  /** 点击瞬间光亮：tap 即满亮 → 50ms 后 280ms 扩散淡出，随后恢复平静 */
  private handleTap(index: number): void {
    // 光影起点必须是「本次点击之前」的选中页签，所以第一件事就把它抄下来：
    // 后面 currentTab 会被 onSelect（宿主控制）或直接赋值改掉，那时再读就只知道终点。
    const from: number = this.currentTab;
    this.clearTimer(this.rippleTimer);
    this.clearTimer(this.rippleFadeTimer);
    this.rippleTimer = -1;
    this.rippleFadeTimer = -1;
    this.rippleTab = index;
    this.rippleSpread = false;
    this.rippleFadeTimer = setTimeout((): void => {
      this.rippleFadeTimer = -1;
      this.getUIContext().animateTo({ duration: 280, curve: Curve.EaseOut }, (): void => {
        this.rippleSpread = true;
      });
    }, 50);
    this.rippleTimer = setTimeout((): void => {
      this.rippleTab = -1;
      this.rippleSpread = false;
      this.rippleTimer = -1;
    }, 420);
    this.fireSweep(from, index);
    this.fireSparks(index);
    if (this.onSelect !== undefined) {
      this.onSelect(index);
    } else {
      this.currentTab = index;
    }
  }

  /**
   * 切页签粒子。只用一个 animateTo 把 sparkProgress 0→1 推完，粒子的位移/缩放/淡出
   * 全部由这一个进度算出来 —— 不跑逐帧定时器，也不会随页签快速连点多开动画：
   * 连点时先复位进度再重启，只有最后一束在飞。
   */
  private fireSparks(index: number): void {
    this.clearTimer(this.sparkTimer);
    this.clearTimer(this.sparkResetTimer);
    this.sparkTimer = -1;
    this.sparkResetTimer = -1;
    // 进度归零 + 换归属页签：这一步必须落在 animateTo 之外，否则起点值会被动画吃掉
    this.sparkProgress = 0;
    this.sparkTab = index;
    this.sparkTimer = setTimeout((): void => {
      this.sparkTimer = -1;
      this.getUIContext().animateTo({ duration: SPARK_DURATION_MS, curve: Curve.EaseOut }, (): void => {
        this.sparkProgress = 1;
      });
    }, 16);
    this.sparkResetTimer = setTimeout((): void => {
      this.sparkTab = -1;
      this.sparkProgress = 0;
      this.sparkResetTimer = -1;
    }, SPARK_DURATION_MS + 80);
  }

  /** 第 index 个页签的中心 x（相对栏体左边，vp）；三栏等宽 ⇒ (i+0.5)/3 */
  private tabCenterX(index: number): number {
    return (this.dockW * (index + 0.5)) / 3;
  }

  /**
   * 光团水平位移（vp）：中心在两个页签中心之间插值，再减去栏宽一半。
   * 装饰层用 `alignContent: Bottom` ⇒ 光团默认已水平居中，所以位移以「中心偏移」表达，
   * 不需要再减光团自身宽度的一半（同尺寸居中，天然对齐）。
   */
  private sweepOffsetX(): number {
    const a: number = this.tabCenterX(this.sweepFrom);
    const b: number = this.tabCenterX(this.sweepTo);
    return a + (b - a) * this.sweepP - this.dockW / 2;
  }

  private sweepBlobW(): number {
    return (this.dockW / 3) * SWEEP_BLOB_RATIO;
  }

  /**
   * 光影透明度：前 12% 淡入、中段满亮、末 30% 淡出 ⇒ 到站就消失，
   * 不会留一个挂在错误页签上的亮点。表达式里读 `this.sweepP` ⇒ 该属性天然成为本元素的依赖。
   */
  private sweepAlpha(): number {
    const p: number = this.sweepP;
    const edge: number = p < 0.12 ? p / 0.12 : (p > 0.70 ? (1 - p) / 0.30 : 1);
    return edge < 0 ? 0 : (edge > 1 ? 1 : edge);
  }

  /**
   * 切页签滑行光影。同粒子：只用一个 animateTo 把 sweepP 0→1 推完，
   * 位移与淡入淡出全部由这一个进度算出来；连点时先复位再重启，只有最后一团在飞。
   * `from === to`（点已选中的页签）与宽度未量出时直接不画。
   */
  private fireSweep(from: number, to: number): void {
    if (from === to || this.dockW <= 0) {
      return;
    }
    this.clearTimer(this.sweepStartTimer);
    this.clearTimer(this.sweepEndTimer);
    this.sweepStartTimer = -1;
    this.sweepEndTimer = -1;
    // 起点值要先落在屏上，下一步 animateTo 才有东西可动画（同帧推会把起点吃掉、光团瞬移）
    this.sweepP = 0;
    this.sweepFrom = from;
    this.sweepTo = to;
    this.sweepOn = true;
    this.sweepStartTimer = setTimeout((): void => {
      this.sweepStartTimer = -1;
      this.getUIContext().animateTo({ duration: SWEEP_DURATION_MS, curve: Curve.EaseInOut }, (): void => {
        this.sweepP = 1;
      });
    }, 16);
    this.sweepEndTimer = setTimeout((): void => {
      this.sweepOn = false;
      this.sweepP = 0;
      this.sweepFrom = -1;
      this.sweepTo = -1;
      this.sweepEndTimer = -1;
    }, SWEEP_DURATION_MS + 60);
  }

  private sparkColor(tone: number): ResourceColor {
    if (tone === 0) {
      return TunBoxColors.primary;
    }
    return tone === 1 ? TunBoxColors.dockSparkAlt : TunBoxColors.dockSparkSoft;
  }

  /**
   * 玻璃装饰层（只挂**一次** overlay：同一组件连挂两次 overlay，后者会把前者顶掉）。
   * 里面两样东西：
   *  ① 顶部镜面高光：从亮白快速衰减到透明的窄带，贴在栏体上沿 —— 玻璃的「棱边反光」
   *     全靠这一层，去掉它材质就变成塑料。
   *  ② 切页签滑行光影：一团拖在底部的光，从旧页签中心滑到新页签中心再淡出。
   * 整层 `clip(true)` + `dockRadius` 圆角（光团不会溢到栏外），
   * 并 `hitTestBehavior None`（纯装饰，决不能吃掉页签点击）。
   */
  @Builder
  private glassDecorLayer() {
    // 顶层对齐：高光用**固定高度**的第 1 个孩子控制（2026-10-29）
    // 原来用整栏高度 + `angle:180` 靠 stop 位置猜方向，结果高光铺满全栏、
    // 整条 dock 变成一片均亮的 253（比背景亮 12 级），透明感全丢。
    // 现在高光只占上沿 42%，其余区域一点都不画 ⇒ 下半就是纯透出背景。
    Stack({ alignContent: Alignment.Top }) {
      // ① 顶部镜面高光：只有上沿那一条是亮的，到底部已经彻底同色透明
      Column()
        .width('100%')
        .height(TunBoxGeometry.dockHeight * 0.42)
        .linearGradient({
          angle: 180,
          colors: [
            [TunBoxColors.dockSheenStrong(this.themeRevision), 0.0],
            [TunBoxColors.dockSheenSoft(this.themeRevision), 0.30],
            // ⚠ 必须是「同色透明」：写 Color.Transparent（透明黑）会在插值中段变成
            //   中灰，在浅背景上压出 17 级暗带 —— 这就是「dock 一半阴影」的真因。
            [TunBoxColors.dockSheenClear, 1.0]
          ]
        })
      if (this.sweepOn) {
        Column()
          .width(this.sweepBlobW())
          .height(SWEEP_BLOB_H)
          .borderRadius(SWEEP_BLOB_H / 2)
          // angle 90 ⇒ 水平左右渐隐；竖向靠大 blur 把硬边抹成一团光
          .linearGradient({
            angle: 90,
            colors: [
              [TunBoxColors.dockSweepClear, 0.0],
              [TunBoxColors.dockSweepCore, 0.5],
              [TunBoxColors.dockSweepClear, 1.0]
            ]
          })
          .blur(SWEEP_BLOB_BLUR)
          .opacity(this.sweepAlpha())
          // Stack 现在是 Top 对齐，光团自己算到靠近底部的位置（纯 vp 几何，不靠百分比）
          .translate({ x: this.sweepOffsetX(), y: TunBoxGeometry.dockHeight - SWEEP_BLOB_H - 10 })
      }
    }
    .width('100%')
    .height('100%')
    .borderRadius(TunBoxGeometry.dockRadius)
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }

  private tabs: DockTab[] = [
    { id: 0, title: '主页', icon: $r('app.media.ic_dashboard') },
    { id: 1, title: '数据', icon: $r('app.media.ic_chart') },
    { id: 2, title: '设置', icon: $r('app.media.ic_settings') }
  ];

  build() {
    // 装饰层必须画在内容**下面**（2026-10-29 用户「dock 字体略微加粗、要清楚一点，现在有点模糊」）：
    // 原来装饰层挂在 `.overlay()` 上，而 overlay 画在**子节点之上** —— 上沿镜面高光
    // （浅色是 alpha 0.85 的白色渐变，覆盖栏体上方 42%）正好压过垂直居中的图标与文字行，
    // 把字的上半截洗成近白，笔画边界被抹平 ⇒ 观感发虚。实测未选中页签「文字 163 / 底 246」，
    // 对比跨度只有 83（选中页签 148）。玻璃高光本来就属于材质、属于内容底下，
    // 改成 Stack 里「先装饰、后内容」才是对的层次，文字立刻恢复清晰。
    Stack({ alignContent: Alignment.Center }) {
      this.glassDecorLayer()
      Row() {
      ForEach(this.tabs, (item: DockTab) => {
        // 选中态：椭圆胶囊高亮，图标在前、名称在后同一行
        Row() {
          Stack({ alignContent: Alignment.Center }) {
            // ① 瞬间光亮层：dockGlow（深色 50% 亮蓝）tap 即满亮 → 280ms 扩散淡出
            Column()
              .width(56).height(56)
              .borderRadius(28)
              .backgroundColor(TunBoxColors.dockGlow)
              .opacity(this.rippleTab === item.id ? (this.rippleSpread ? 0 : 1) : 0)
              .scale({
                x: this.rippleTab === item.id && this.rippleSpread ? 1.55 : 0.75,
                y: this.rippleTab === item.id && this.rippleSpread ? 1.55 : 0.75
              })
              // 沉浸光感（HDS 点光源）挂在这里，**不能挂在页签的 Stack 或胶囊 Row 上**：
              // 2026-10-29 用户「深色模式下底部每个按钮周围都有一个方形框，浅色看不出来」。
              // 真机 A/B（同一页面、同一位置，只差这一个属性）：
              //   挂在页签 Stack（空闲时传入 uiEffect.createEffect() 空效果）：
              //     未选中页签 胶囊内 26 / 胶囊外 34 → **Δ=−8**，四边对齐胶囊边界，就是一圈方框；
              //     选中页签 19 / 34（底色还被压暗）；
              //   去掉后：未选中 19 / 19 → **Δ=0**，选中 40 / 19（只剩正常的蓝色底色）。
              // 结论：**空 visualEffect 也是渲染指令** —— 它会把该节点单独合成进一个离屏图层，
              // 整块区域被重新合成一次（深色下比周围暗 8 级），浅色下 241 对 241 看不出来，
              // 深色下 15 对 26 就一目了然。（旧注释里“单独空效果不会画错东西”的判断是错的，已推翻。）
              // 挂在本层是安全的：空闲时 opacity 为 0，图层里没有任何像素；只有按下那一刻
              // 它才作为光源亮起，正好就是「沉浸光感」想要的效果。
              .visualEffect(dockPressLight(this.litTab === item.id))
            // ② 切页签粒子（96 粒）：从图标中心向上扇面散开，边飞边缩边淡出。
            //    位移/透明度全部由 sparkProgress 单值推导，宿主只跑一次 animateTo。
            if (this.sparkTab === item.id) {
              ForEach(DOCK_SPARKS, (s: DockSpark, i: number) => {
                Column()
                  .width(s.size).height(s.size)
                  .borderRadius(s.size / 2)
                  .backgroundColor(this.sparkColor(s.tone))
                  .translate({
                    x: Math.cos(s.angle) * s.dist * this.sparkT(s),
                    y: Math.sin(s.angle) * s.dist * this.sparkT(s)
                  })
                  .scale({
                    x: 1 - 0.55 * this.sparkT(s),
                    y: 1 - 0.55 * this.sparkT(s)
                  })
                  .opacity((1 - this.sparkT(s)) * (s.tone === 2 ? 0.55 : 0.92))
              }, (s: DockSpark, i: number) => `${item.id}-${i}`)
            }
            Row({ space: 6 }) {
              Image(item.icon)
                .width(21).height(21)
                .fillColor(this.currentTab === item.id ? TunBoxColors.primary : TunBoxColors.dockIconInactive)
              Text(item.title)
                .fontSize(12)
                // 2026-10-29 用户「字体略微加粗，要清楚一点」：整体上一档字重
                // （本 SDK 的 FontWeight 只有 Lighter/Normal/Regular/Medium/Bold/Bolder，
                // 没有 SemiBold）。12fp 的 Regular 笔画只有约 1 个物理像素宽，
                // 压在模糊玻璃上边缘立刻被抹平。
                .fontWeight(this.currentTab === item.id ? FontWeight.Bold : FontWeight.Medium)
                .fontColor(this.currentTab === item.id ? TunBoxTextColors.accentBlue : TunBoxTextColors.secondary)
            }
            .alignItems(VerticalAlign.Center)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(TunBoxGeometry.pillRadius)
            // 2026-10-28 用户要求「高亮也改成透明的范围，带一点沉浸光感的底色就行」：
            // 由 primaryLight（浅色为实色 #EFF4FF）换成低 alpha 品牌蓝 —— 只染一层蓝调，
            // 底下玻璃与粒子仍透得出来（实色会把它们整块挡死）。
            .backgroundColor(this.currentTab === item.id ? TunBoxColors.dockPillFill : Color.Transparent)
            // 2026-10-29 用户「去掉描边」：原来这里还有 1px 的 `dockPillEdge` 描边，
            // 但填充 alpha 只有 0.09、描边 alpha 0.16，描边比填充还深 ⇒ 人眼只读到一道
            // 闭合的边，看起来像「一个透明的方框围住图标和文字」，而不是一块柔和底色。
            // 真机量到的证据：胶囊内部亮度 227~231，描边线 205~213，台面 242。
            // 现在只保留填充，选中态靠“底色 + 蓝色 Bold 文字”表达，不再有框线。
            // 按压兜底：HDS 点光源不显示时，0.96 的轻微内缩仍能确认「点到了」
            .scale({ x: this.litTab === item.id ? 0.96 : 1, y: this.litTab === item.id ? 0.96 : 1 })
            .animation({ duration: 220, curve: Curve.EaseOut })
          }
          // 沉浸光感（HDS 点光源）已下移到内层光晕 Column 上：
          // 页签 Stack 本身一旦挂 visualEffect，空闲时的空效果也会把整块胶囊合成进离屏图层，
          // 深色下变成每个按钮一圈方框（见内层注释里的 A/B 数据）。
          .accessibilityText(item.title)
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.litTab = item.id;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.litTab = -1;
            }
          })
          .onClick(() => { this.handleTap(item.id); })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }, (item: DockTab) => `${item.id}`)
      }
      .width('100%')
      .height('100%')
    }
    // 2026-10-26 用户要求「三个按钮间距稍微缩小一点点」：92% → 86%（页签向中间靠一点）
    .width('86%')
    .height(TunBoxGeometry.dockHeight)
    .borderRadius(TunBoxGeometry.dockRadius)
    // ── 液态玻璃 ①a：真·背景模糊 + 微弱饱和度提升 ──
    // 2026-10-28 用户「底框可以再透明一点」：饱和度 1.9→1.28、亮度 1.06→1.0、radius 24→26。
    // 原来 1.9 + 1.06 会把通道推到削顶（实测底栏内部 G 通道恒为 255），观感发白、
    // 丢掉「玻璃应该跟着背后内容变」的信息 —— 透明感反而变差。
    .backgroundEffect({
      radius: 26,
      saturation: ThemeService.isDark() ? 1.18 : 1.28,
      brightness: ThemeService.isDark() ? 0.98 : 1.0,
      color: TunBoxColors.dockGlassTint(this.themeRevision)
    })
    // ── 液态玻璃 ①b：极淡染色渐变，把玻璃压进当前背景配色系（alpha 必须低，否则挡住模糊）──
    .linearGradient({
      angle: 180,
      colors: [[TunBoxColors.dockGradientTop(this.themeRevision), 0.0], [TunBoxColors.dockGradientBottom(this.themeRevision), 1.0]]
    })
    .border({ width: 1, color: TunBoxColors.dockEdge })
    // ── 不画阴影（2026-10-29 用户要求：「上半和下半部分一样就行了，不要设置阴影」）──
    // A/B 真机取证结论（含白底不透光对照）：栏体自身 `.shadow()`、`ImmersiveMaterial.applyShadow`、
    // 背后内容模糊、HDS 常驻受光、`backgroundEffect` **都不是**「一半阴影」的成因
    // （逐项去掉后栏内像素纹丝不动）。真因是高光渐变的终点写成了 `Color.Transparent`，
    // 详见 `TunBoxColors.dockSheenClear` 的注释。
    // 阴影仍保持不画：用户明确要求上下半一致，且透明玻璃背后画阴影确实会透出来。
    // ── 液态玻璃 ①c：顶部镜面高光 + 切页签滑行光影 ──
    // 2026-10-29 改成 build() 里 Stack 的第一个孩子（画在内容**之下**），不再用 `.overlay()`，
    // 原因见 build() 顶部注释（高光压在文字上会把 dock 字洗得发虚）。
    // 沉浸光感系统材质（2026-10-28）。**不能直接写 `.systemMaterial(this.dockMaterial)`**：
    // 那是 API 26 才有的 CommonMethod，旧系统上属性对象没有该方法，`build()` 里调用即 TypeError
    // （0.7.1 被 AGC 兼容性测试判「启动失败」的第二个隐患）。走属性修饰器，内部 try/catch。
    .attributeModifier(this.dockAttr)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .margin({ bottom: TunBoxGeometry.dockBottomMargin })
    // 量栏体真实宽度（vp）：只有知道宽度才能算出三个页签各自的中心，把光影落在正确的格子上
    .onAreaChange((_old: Area, cur: Area) => {
      const w: number = Number(cur.width);
      if (!Number.isNaN(w) && w > 0) {
        this.dockW = w;
      }
    })
  }
}
