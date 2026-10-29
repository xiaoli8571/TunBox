/**
 * 天体轨域 · 亚克力轻拟物圆盘启动按钮（Celestial Orbit Orb）
 * （2026-10-17 用户指定按 stitch 设计稿「方案一：天体轨域 · 亚克力透光圆盘」重构首页启动按钮，
 *  整体替换原 StatusRing 240/200/150 三层同心环。）
 *
 * 结构（设计稿数值 → 320vp 呼吸光晕 / 280vp 点阵轨道 / 260vp 渐变轨环 / 200vp 核心盘）：
 *  - 玻璃盘面（2026-10-17 用户要求「中心要有玻璃透明感」）：200vp Column +
 *    backgroundEffect（背板模糊 radius 40 + 半透明着色）—— 背后的呼吸光晕与页面
 *    渐变透过盘面呈现磨砂质感；弥散投影挂在该组件 .shadow 上，仅连接后显示
 *    （空闲态无光晕；组件 shadow 按圆角轮廓渲染，沿用旧 StatusRing 已验证做法）。
 *  - 静态 Canvas 层（叠在玻璃上方）：2.5vp 镜面微内发光描边 + 内凹槽细环 #EDF4FD。
 *    仅在 onReady/主题切换时绘制一次；shadowBlur 不进逐帧路径（2026-10-17 性能修正）。
 *  - 动态 Canvas 层：弥散呼吸光晕（仅连接态显示，不启动无光晕）、
 *    两条虚线同心轨（dash 3:6，外轨连接态转翡翠绿）、
 *    蓝→青渐变轨环、两条动态电平弧线（#0A59F7→#2DD4BF 与 #00BA66）、
 *    两颗自转卫星节点（径向渐变光晕）。
 *    由 60ms(≈16fps) 定时器重绘 —— 旋转是慢速漂移，16fps 足够平滑且 CPU 减半。
 *    **2026-10-18 用户报障修复**：球与弧线原先各用不同角速度（spin / spin*0.55 /
 *    -spin*0.8），相对角度线性漂移 → 必然周期性叠在一起。现在四条元素共用同一
 *    轨道相位（角速度全等），并按**十字对称**排布：两球在竖直轴（同外轨 r=140，
 *    相隔 180°）、两条等长 42° 长条在水平轴（同轨环 r=130，相隔 180°），
 *    匀速转动时角间距恒为 90°/48° → 永不重叠，且任意相位都保持十字形态；
 *    几何集中在 `CelestialOrbLayout.ets`，由 `scripts/verify-orb-separation.mjs`
 *    真跑校验（当前最小间距 96.9vp，远大于视觉外延 13vp）。
 *  - 内容层：40vp 电源徽标胶囊（#EFF5FF）、标题（开启连接/已连接）、当前节点名
 *    （2026-10-17 用户要求：删掉副标题与 TUN 待命状态胶囊，节点名放回按钮内部，同旧 StatusRing）。
 *  - 生命周期：onVisibleAreaChange 在切页签/切后台时停掉定时器、回前台立即重绘再启表 ——
 *    修复「切走再切回动画卡住」（后台期间不再空转，回前台第一帧强制恢复）。
 *  - 交互：按下弹性缩放 0.95（springMotion），抬起触发触觉震动 + onToggle 回调；
 *    连接态光晕由品牌蓝平滑转为翡翠绿。
 *
 * 铁律（沿用 StatusRing 既有结论）：圆形视觉一律画进 Canvas 或用形状 .fill（Circle），
 * 不对圆形组件挂 .shadow/.linearGradient（按矩形盒渲染会透出方框）。
 */
import { curves } from '@kit.ArkUI';
import { UnifiedScheduler } from '../commons/services/UnifiedScheduler';
import { vibrator } from '@kit.SensorServiceKit';
import { TunBoxColors, TunBoxGeometry } from '../theme/TunBoxTokens';
import { ThemeService } from '../theme/ThemeService';
import { OrbLayout } from './CelestialOrbLayout';

/**
 * 呼吸层重绘周期（250ms）。
 *
 * 光晕画在**玻璃盘后面**，每次重绘都会触发背板模糊重算，
 * 所以它保持慢节奏；2026-10-29 用户报的「自转卡顿」不在这一层。
 */
const BREATH_TICK_MS = 250;
/**
 * 自转周期（毫秒/圈）—— 2026-10-29 修「启动后顺时针旋转卡顿掉帧」。
 *
 * 旧实现两个坑：
 *  1. 用 `UnifiedScheduler.every(cb, 60)` 驱动，而该调度器底层只有 250ms
 *     统一 tick（`step = max(250, 60) = 250`）→ 实际只有 **4fps**，
 *     而注释一直写着「≈16fps」。
 *  2. 即使换成 setInterval，重绘仍跑在 JS 线程：点「启动」时配置生成 /
 *     写盘 / 内核 IPC 全在同一线程，回调被挤掉就必然掉帧。
 *
 * 现在：转动层按相位 0 画**一次**，整层靠声明式 `animateTo` 无限循环
 * `rotate` 由渲染线程插帧，逐帧 JS 归零。转速与旧版一致：
 * 待命 4.5°/s（≈80s/圈）、连接后 12.5°/s（≈28.8s/圈）。
 */
const REV_IDLE_MS = 80000;
const REV_ACTIVE_MS = 28800;
/**
 * 弧线与卫星的角度槽位来自 `CelestialOrbLayout`（2026-10-18 修「转动时互相重叠」）。
 *
 * 旧实现三条元素各用不同角速度（`spin` / `spin*0.55` / `-spin*0.8`），相对角度线性
 * 漂移 → 必然周期性重合，调参救不了。现在**全部同速**、只保留固定偏移，
 * 角间距恒定 → 永不重叠；布局与最小间距由 `OrbLayout.minGapVp()` 保证，
 * 回归脚本 `scripts/verify-orb-separation.mjs` 真跑校验。
 */
const ARC1 = OrbLayout.ARC1;
const ARC2 = OrbLayout.ARC2;
const BALL1 = OrbLayout.BALL1;
const BALL2 = OrbLayout.BALL2;
/** 呼吸周期（秒），对齐旧 StatusRing 的 1.4s 交替呼吸 */
const BREATH_SEC = 1.4;
/** 2026-10-28 用户要求「启动按钮缩小一圈」：整体视觉缩到 0.9，外层占位同步收窄 */
const ORB_SCALE = 0.9;
/** 弧形 IP 文字：字号上限与自适应底弧几何（度，屏幕坐标系 y 向下） */
const ARC_IP_FONT = 11;
/** 长 IP（IPv6）允许缩到的最小字号：再小就不可读，宁可把弧度拉满 */
const ARC_IP_FONT_MIN = 8;
/**
 * 底弧角度范围（2026-10-28 用户报障「IPv6 地址被挤成一团」）。
 *
 * 旧实现把**固定** 130°→50°（总跨度 80°）平均分给每个字符：IPv4（≤15 字）每字约 5.7°
 * 够放；IPv6（39~45 字）每字只剩 1.8°，远小于一个字宽对应的圆心角 → 字符百分之百重叠。
 * 现在按字数自适应：先算「不叠字所需的最小圆心角」，取 max(基准跨度, 所需跨度) 并封顶；
 * 封顶后仍放不下时再逐级缩字号（ARC_IP_FONT → ARC_IP_FONT_MIN）。
 * IPv4 走基准跨度，视觉与旧版一致。
 */
const ARC_IP_SPAN_BASE_DEG = 80;
const ARC_IP_SPAN_MAX_DEG = 180;

@Component
export struct CelestialPowerOrb {
  @Link @Watch('onConnectionChanged') isConnected: boolean;
  @Prop isConnecting: boolean = false;
  /** 当前节点名：显示在启动按钮内部（空则显示占位，同旧 StatusRing 行为） */
  @Prop nodeName: string = '';
  /**
   * 出口公网 IP（2026-10-28 用户要求：放进启动按钮内部，沿底部半圆弧形显示；
   * 未连接时不显示任何东西）。
   */
  @Prop ipText: string = '';
  @StorageLink('theme_revision') @Watch('onThemeChanged') themeRevision: number = 0;
  onToggle: () => void = () => {};

  @State private pressed: boolean = false;
  /** 自转相位（度）：只在状态切换时改一次，逐帧插值交给渲染线程 */
  @State private rotAngle: number = 0;
  private glowSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private glowCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.glowSettings);
  private dynSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private dynCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.dynSettings);
  private rotSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private rotCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.rotSettings);
  private staticSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private staticCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.staticSettings);
  private glowReady: boolean = false;
  private dynReady: boolean = false;
  private rotReady: boolean = false;
  private staticReady: boolean = false;
  /** 呼吸层定时器（仅光晕，4fps 步进是故意的） */
  private ticker: number = -1;

  private readonly glowSize: number = TunBoxGeometry.orbGlow;
  private readonly trackSize: number = TunBoxGeometry.orbTrack;
  private readonly arcRingSize: number = TunBoxGeometry.orbArcRing;
  private readonly discSize: number = TunBoxGeometry.orbDisc;

  /**
   * 弧形 IP 文字的分字几何：把 IP 逐字符摆到盘心下方半圆弧上。
   * 角度以 90°（正下方）为中心左右**对称**展开，跨度按字数自适应（见 ARC_IP_SPAN_* 注释），
   * 每字按切向旋转，读起来像贴在弧上，且长 IPv6 不会叠字。
   */
  private ipChars(): string[] {
    const text: string = this.ipText;
    const out: string[] = [];
    for (let i = 0; i < text.length; i++) {
      out.push(text.charAt(i));
    }
    return out;
  }

  /** monospace 单字占位宽估计（vp）：0.6em 字宽 + 两侧留白 */
  private arcCharWidth(fontSize: number): number {
    return fontSize * 0.6 + 1.6;
  }

  /** 不叠字所需的总跨度（度，未截断） */
  private arcNeedSpanDeg(n: number, fontSize: number): number {
    if (n <= 1) {
      return 0;
    }
    const radius: number = this.arcRadius();
    if (radius <= 0) {
      return ARC_IP_SPAN_MAX_DEG;
    }
    const stepDeg: number = this.arcCharWidth(fontSize) / radius * 180 / Math.PI;
    return stepDeg * (n - 1);
  }

  /** 选定字号：从最大字号往下试，取「能塞进封顶跨度」的最大字号 */
  private arcFontSize(n: number): number {
    for (let f: number = ARC_IP_FONT; f > ARC_IP_FONT_MIN; f--) {
      if (this.arcNeedSpanDeg(n, f) <= ARC_IP_SPAN_MAX_DEG) {
        return f;
      }
    }
    return ARC_IP_FONT_MIN;
  }

  /** 实际跨度：短 IP 保持基准视觉，长 IP 展开到够用为止 */
  private arcSpanDeg(n: number): number {
    const need: number = this.arcNeedSpanDeg(n, this.arcFontSize(n));
    return Math.min(ARC_IP_SPAN_MAX_DEG, Math.max(ARC_IP_SPAN_BASE_DEG, need));
  }

  /** 第 i 个字符的角度（度） */
  private arcAngleDeg(i: number, n: number): number {
    if (n <= 1) {
      return 90;
    }
    const span: number = this.arcSpanDeg(n);
    return (90 + span / 2) - span * i / (n - 1);
  }

  /** 弧半径：落在玻璃盘外缘与轨道环之间，避免压住盘内的标题/节点名 */
  private arcRadius(): number {
    return this.discSize / 2 + (this.trackSize - this.discSize) / 4;
  }

  private arcPosX(i: number, n: number): number {
    const deg: number = this.arcAngleDeg(i, n);
    const rad: number = deg * Math.PI / 180;
    const font: number = this.arcFontSize(n);
    return this.glowSize / 2 + this.arcRadius() * Math.cos(rad) - font * 0.3;
  }

  private arcPosY(i: number, n: number): number {
    const deg: number = this.arcAngleDeg(i, n);
    const rad: number = deg * Math.PI / 180;
    const font: number = this.arcFontSize(n);
    return this.glowSize / 2 + this.arcRadius() * Math.sin(rad) - font * 0.95;
  }

  /** 逐字符沿底部半圆排列的出口 IP（未连接 / 无 IP 时不渲染） */
  @Builder
  ArcIpText() {
    Stack() {
      ForEach(this.ipChars(), (ch: string, idx: number) => {
        Text(ch)
          .fontSize(this.arcFontSize(this.ipChars().length))
          .fontFamily('monospace')
          .fontColor(TunBoxColors.textSecondary)
          .rotate({ angle: this.arcAngleDeg(idx, this.ipChars().length) - 90 })
          .position({ x: this.arcPosX(idx, this.ipChars().length), y: this.arcPosY(idx, this.ipChars().length) })
      }, (ch: string, idx: number) => `${this.ipText.length}:${idx}:${ch}`)
    }
    .width(this.glowSize)
    .height(this.glowSize)
    .hitTestBehavior(HitTestMode.None)
  }

  aboutToDisappear(): void {
    this.stopTicker();
  }

  private onThemeChanged(): void {
    this.redrawStatic();
    this.redrawAll();
  }

  /** 连接态切换：各层立即跟随（不等下一帧），并按新转速重启自转；
   *  投影由组件 .shadow 属性自动过渡 */
  private onConnectionChanged(): void {
    this.redrawAll();
    this.startSpin();
  }

  /** 可见性闸门：切页签/切后台停表，回前台先立即恢复画面再启表（修「切回动画卡住」） */
  private onVisible(isVisible: boolean): void {
    if (isVisible) {
      this.redrawStatic();
      this.redrawAll();
      this.startTicker();
      this.startSpin();
    } else {
      this.stopTicker();
      this.stopSpin();
    }
  }

  // ── 配色（深浅主题各一套；连接态光晕转翡翠绿）──
  private blueRgb(): string {
    return ThemeService.isDark() ? '59, 130, 246' : '10, 89, 247';
  }

  private greenRgb(): string {
    return ThemeService.isDark() ? '16, 185, 129' : '0, 186, 102';
  }

  private tealRgb(): string {
    return ThemeService.isDark() ? '94, 234, 212' : '45, 212, 191';
  }

  private tealHex(): string {
    return ThemeService.isDark() ? '#5EEAD4' : '#2DD4BF';
  }

  private blueHex(): string {
    return ThemeService.isDark() ? '#3B82F6' : '#0A59F7';
  }

  private greenHex(): string {
    return ThemeService.isDark() ? '#10B981' : '#00BA66';
  }

  /** 当前强调色：连接态转翡翠绿，其余品牌蓝 */
  private accent(): ResourceColor {
    return this.isConnected ? TunBoxColors.success : TunBoxColors.primary;
  }

  // ── 文案状态机 ──
  private titleText(): string {
    if (this.isConnecting) {
      return this.isConnected ? '正在断开' : '正在连接';
    }
    return this.isConnected ? '已连接' : '开启连接';
  }

  // ── 静态层：镜面描边 + 内凹槽环（盘面本体是 backgroundEffect 玻璃组件，见 build）──
  private redrawStatic(): void {
    if (!this.staticReady) {
      return;
    }
    const ctx = this.staticCtx;
    const c: number = this.glowSize / 2;
    const discR: number = this.discSize / 2;
    const dark: boolean = ThemeService.isDark();
    ctx.clearRect(0, 0, this.glowSize, this.glowSize);

    // 镜面高光微内发光描边（2.5vp，白 0.9 → 蓝 0.3 对角渐变）
    const rim = ctx.createLinearGradient(c - discR * 0.7, c - discR * 0.7, c + discR * 0.7, c + discR * 0.7);
    rim.addColorStop(0, dark ? 'rgba(255, 255, 255, 0.55)' : 'rgba(255, 255, 255, 0.90)');
    rim.addColorStop(0.4, dark ? 'rgba(120, 160, 235, 0.30)' : 'rgba(212, 228, 252, 0.60)');
    rim.addColorStop(1.0, dark ? 'rgba(90, 130, 220, 0.22)' : 'rgba(153, 190, 252, 0.30)');
    this.strokeArc(ctx, c, discR - 1, 2.5, rim, 0, 360);

    // 内凹槽细环（EDF4FD，2026-10-17 还原：不再承担连接态指示）
    this.strokeArc(ctx, c, discR * 0.87, 1.5,
      dark ? 'rgba(255, 255, 255, 0.10)' : '#EDF4FD', 0, 360);
  }

  // ── 动态层：光晕/轨道/弧线/卫星（逐帧重绘，全部轻量操作）──
  /** 1. 弥散呼吸光晕（仅连接态）：画在玻璃盘**后面**，每次重绘都会触发背板模糊重算，
   *  所以它走慢节奏的 BREATH_TICK_MS，不进自转的逐帧路径。*/
  private redrawGlow(): void {
    if (!this.glowReady) {
      return;
    }
    const ctx = this.glowCtx;
    const c: number = this.glowSize / 2;
    ctx.clearRect(0, 0, this.glowSize, this.glowSize);
    const glowRgb: string = this.isConnected ? this.greenRgb() : this.blueRgb();
    // 1. 弥散呼吸光晕：仅连接后显示（2026-10-17 用户要求「启动后才显示光晕，
    //    不启动不显示」），1.4s 呼吸、随连接态转翡翠绿
    if (this.isConnected) {
      // 2026-10-21 用户要求「光晕感再强一点」：呼吸基准与幅度同时抬高（0.10/0.045 → 0.17/0.06），
      // 并新增一圈贴近盘面的内层辉光，让玻璃盘边缘有一层实打实的光。
      const breath: number = 0.17 + 0.06 * Math.sin(Date.now() / 1000 * 2 * Math.PI / BREATH_SEC);
      const ambient = ctx.createRadialGradient(c, c, this.discSize * 0.1, c, c, c);
      ambient.addColorStop(0, `rgba(${glowRgb}, ${breath.toFixed(3)})`);
      ambient.addColorStop(0.55, `rgba(${glowRgb}, ${(breath * 0.42).toFixed(3)})`);
      ambient.addColorStop(0.82, `rgba(${glowRgb}, ${(breath * 0.12).toFixed(3)})`);
      ambient.addColorStop(1.0, `rgba(${glowRgb}, 0)`);
      ctx.fillStyle = ambient;
      ctx.fillRect(0, 0, this.glowSize, this.glowSize);
      const core = ctx.createRadialGradient(c, c, this.discSize * 0.16, c, c, this.discSize * 0.62);
      core.addColorStop(0, `rgba(${glowRgb}, ${(breath * 0.85).toFixed(3)})`);
      core.addColorStop(0.62, `rgba(${glowRgb}, ${(breath * 0.30).toFixed(3)})`);
      core.addColorStop(1.0, `rgba(${glowRgb}, 0)`);
      ctx.fillStyle = core;
      ctx.fillRect(0, 0, this.glowSize, this.glowSize);
    }

  }

  /** 2+3. 点阵轨道与渐变轨环：不随相位变化，只在连接态/主题切换时重画 */
  private redrawDyn(): void {
    if (!this.dynReady) {
      return;
    }
    const ctx = this.dynCtx;
    const c: number = this.glowSize / 2;
    ctx.clearRect(0, 0, this.glowSize, this.glowSize);
    const dark: boolean = ThemeService.isDark();
    // 2. 外层点阵虚线轨道（280，dash 3:6）：已连接整圈转翡翠绿
    //    （2026-10-17 用户要求外圈作连接态指示；每帧按 isConnected 取色）
    //    2026-10-21：待命态压暗、连接态加粗提亮 —— 启动前后靠这一圈就能一眼分开。
    this.dashedCircle(ctx, c, this.trackSize / 2, this.isConnected ? 2.0 : 1.5,
      this.isConnected
        ? `rgba(${this.greenRgb()}, ${dark ? '0.78' : '1.0'})`
        : (dark ? 'rgba(255, 255, 255, 0.14)' : 'rgba(198, 215, 240, 0.55)'));

    // 3. 渐变轨环（260，蓝 0.40 → 蓝 0.08 → 绿 0.30）
    const rArc: number = this.arcRingSize / 2;
    const ringGrad = ctx.createLinearGradient(c - rArc, c - rArc, c + rArc, c + rArc);
    ringGrad.addColorStop(0, `rgba(${this.blueRgb()}, 0.40)`);
    ringGrad.addColorStop(0.5, `rgba(${this.blueRgb()}, 0.08)`);
    ringGrad.addColorStop(1.0, `rgba(${this.greenRgb()}, 0.30)`);
    this.strokeArc(ctx, c, rArc, 2, ringGrad, 0, 360);

  }

  /**
   * 4+5. 转动层：两条电平弧线 + 弧头光点 + 两颗卫星，**按相位 0 画一次**。
   *
   * 四条元素共用同一角速度（`OrbLayout.speedFactor` 恒为 1、
   * `startAt = offset + spin`），所以整层刚性旋转与旧逐帧重算**数学等价**。
   * 转动由渲染线程插帧（见 build 里的 .rotate）。
   */
  private redrawRot(): void {
    if (!this.rotReady) {
      return;
    }
    const ctx = this.rotCtx;
    const c: number = this.glowSize / 2;
    ctx.clearRect(0, 0, this.glowSize, this.glowSize);
    const spin: number = 0;
    const dark: boolean = ThemeService.isDark();
    // 4. 两条动态电平弧线（与卫星共用同一轨道相位 → 角间距恒定，永不相交）
    //    2026-10-21：待命态细+暗、连接态粗+亮，并在弧头补一颗「领头光点」——
    //    转动方向与快慢因此一眼可辨（造型/半径/相位全不动，只改笔宽与亮度）。
    const arcWidth: number = this.isConnected ? 5.5 : 3.2;
    if (this.isConnected) {
      this.gradientArc(ctx, c, ARC1.radius, arcWidth, ARC1.startAt(spin), ARC1.sweepDeg,
        this.blueHex(), this.tealHex());
      const greenArcLit = `rgba(${this.greenRgb()}, 1)`;
      this.gradientArc(ctx, c, ARC2.radius, arcWidth, ARC2.startAt(spin), ARC2.sweepDeg,
        greenArcLit, greenArcLit);
    } else {
      const idleBlue = `rgba(${this.blueRgb()}, ${dark ? '0.40' : '0.42'})`;
      const idleTeal = `rgba(${this.tealRgb()}, ${dark ? '0.40' : '0.42'})`;
      this.gradientArc(ctx, c, ARC1.radius, arcWidth, ARC1.startAt(spin), ARC1.sweepDeg,
        idleBlue, idleTeal);
      const idleGreen = `rgba(${this.greenRgb()}, ${dark ? '0.26' : '0.30'})`;
      this.gradientArc(ctx, c, ARC2.radius, arcWidth, ARC2.startAt(spin), ARC2.sweepDeg,
        idleGreen, idleGreen);
    }
    // 弧头光点：连接态白心大点（转速快、指向明确），待命态小暗点（只留一丝动感）
    this.drawArcHead(ctx, c, ARC1.radius, ARC1.startAt(spin),
      this.isConnected ? this.tealRgb() : this.blueRgb(), this.isConnected);
    this.drawArcHead(ctx, c, ARC2.radius, ARC2.startAt(spin),
      this.greenRgb(), this.isConnected);

    // 5. 卫星节点：主卫星（白心蓝晕）沿外轨，次卫星（绿）沿轨环 —— 同速、固定错位
    //    连接态放大光晕与实心体，待命态收紧压暗（对比度来源之二）
    const sat1Rad: number = BALL1.startAt(spin) * Math.PI / 180;
    this.drawSatellite(ctx, c + BALL1.radius * Math.cos(sat1Rad),
      c + BALL1.radius * Math.sin(sat1Rad), this.blueRgb(), this.blueHex());
    const sat2Rad: number = BALL2.startAt(spin) * Math.PI / 180;
    this.drawSatellite(ctx, c + BALL2.radius * Math.cos(sat2Rad), c + BALL2.radius * Math.sin(sat2Rad),
      this.greenRgb(), `rgba(${this.greenRgb()}, ${this.isConnected ? '0.95' : '0.55'})`);  }

  private redrawAll(): void {
    this.redrawGlow();
    this.redrawDyn();
    this.redrawRot();
  }

  /** 弧头领头光点：光晕 + 实心体 + （连接态）白核，用来读转动方向与速度 */
  private drawArcHead(ctx: CanvasRenderingContext2D, c: number, r: number,
    startDeg: number, rgb: string, strong: boolean): void {
    const rad: number = startDeg * Math.PI / 180;
    const x: number = c + r * Math.cos(rad);
    const y: number = c + r * Math.sin(rad);
    const haloR: number = strong ? 9 : 6;
    const halo = ctx.createRadialGradient(x, y, 0, x, y, haloR);
    halo.addColorStop(0, `rgba(${rgb}, ${strong ? '0.60' : '0.22'})`);
    halo.addColorStop(1.0, `rgba(${rgb}, 0)`);
    ctx.fillStyle = halo;
    ctx.beginPath();
    ctx.arc(x, y, haloR, 0, 2 * Math.PI);
    ctx.fill();
    ctx.fillStyle = strong ? `rgba(${rgb}, 1)` : `rgba(${rgb}, 0.45)`;
    ctx.beginPath();
    ctx.arc(x, y, strong ? 3.4 : 2.2, 0, 2 * Math.PI);
    ctx.fill();
    if (strong) {
      ctx.fillStyle = 'rgba(255, 255, 255, 0.95)';
      ctx.beginPath();
      ctx.arc(x, y, 1.6, 0, 2 * Math.PI);
      ctx.fill();
    }
  }

  private strokeArc(ctx: CanvasRenderingContext2D, c: number, r: number, width: number,
    style: string | CanvasGradient, startDeg: number, sweepDeg: number): void {
    ctx.beginPath();
    ctx.arc(c, c, r, startDeg * Math.PI / 180, (startDeg + sweepDeg) * Math.PI / 180);
    ctx.strokeStyle = style;
    ctx.lineWidth = width;
    ctx.lineCap = 'round';
    ctx.stroke();
  }

  /** 渐变弧线：渐变沿弧线弦向（起点色→终点色），圆头端点 */
  private gradientArc(ctx: CanvasRenderingContext2D, c: number, r: number, width: number,
    startDeg: number, sweepDeg: number, fromColor: string, toColor: string): void {
    const rad1: number = startDeg * Math.PI / 180;
    const rad2: number = (startDeg + sweepDeg) * Math.PI / 180;
    const grad = ctx.createLinearGradient(
      c + r * Math.cos(rad1), c + r * Math.sin(rad1),
      c + r * Math.cos(rad2), c + r * Math.sin(rad2));
    grad.addColorStop(0, fromColor);
    grad.addColorStop(1, toColor);
    this.strokeArc(ctx, c, r, width, grad, startDeg, sweepDeg);
  }

  /** 点阵虚线圆：按周长均分 dash:gap 弧段（避开 setLineDash 兼容性差异） */
  private dashedCircle(ctx: CanvasRenderingContext2D, c: number, r: number, width: number,
    color: string): void {
    const dash: number = 3;
    const gap: number = 6;
    const step: number = dash + gap;
    const count: number = Math.floor(2 * Math.PI * r / step);
    ctx.strokeStyle = color;
    ctx.lineWidth = width;
    ctx.lineCap = 'butt';
    for (let i = 0; i < count; i++) {
      const start: number = i * step / r;
      ctx.beginPath();
      ctx.arc(c, c, r, start, start + dash / r);
      ctx.stroke();
    }
  }

  /** 微光卫星节点：径向渐变外晕（不用 shadowBlur，保持逐帧轻量）+ 实心体 + 白核
   *  2026-10-21：连接态放大提亮、待命态收紧压暗，作为启动前后的主要对比来源之一。 */
  private drawSatellite(ctx: CanvasRenderingContext2D, x: number, y: number,
    haloRgb: string, bodyColor: string): void {
    const on: boolean = this.isConnected;
    const haloR: number = on ? 14 : 9;
    const halo = ctx.createRadialGradient(x, y, 0, x, y, haloR);
    halo.addColorStop(0, `rgba(${haloRgb}, ${on ? '0.72' : '0.30'})`);
    halo.addColorStop(1.0, `rgba(${haloRgb}, 0)`);
    ctx.fillStyle = halo;
    ctx.beginPath();
    ctx.arc(x, y, haloR, 0, 2 * Math.PI);
    ctx.fill();
    ctx.fillStyle = bodyColor;
    ctx.beginPath();
    ctx.arc(x, y, on ? 5.2 : 3.9, 0, 2 * Math.PI);
    ctx.fill();
    ctx.fillStyle = on ? 'rgba(255, 255, 255, 0.95)' : 'rgba(255, 255, 255, 0.55)';
    ctx.beginPath();
    ctx.arc(x, y, on ? 2.6 : 1.7, 0, 2 * Math.PI);
    ctx.fill();
  }

  private startTicker(): void {
    if (this.ticker >= 0) {
      return;
    }
    this.ticker = UnifiedScheduler.every((): void => {
      this.redrawGlow();
    }, BREATH_TICK_MS);
  }

  private stopTicker(): void {
    if (this.ticker >= 0) {
      UnifiedScheduler.clear(this.ticker);
      this.ticker = -1;
    }
  }

  /**
   * 自转：声明式无限循环 `rotate`，由渲染线程插帧。
   *
   * 只在「连接态切换 / 回前台」时重启一次（因为转速要变），之后不再碰 JS。
   * 先无动画归位到「相位模 360」再起新动画：差值恰好是 360° 的整数倍，视觉上无跳变。
   */
  private startSpin(): void {
    const from: number = this.rotAngle % 360;
    this.rotAngle = from;
    this.getUIContext().animateTo({
      duration: this.isConnected ? REV_ACTIVE_MS : REV_IDLE_MS,
      curve: Curve.Linear,
      iterations: -1,
      playMode: PlayMode.Normal
    }, (): void => {
      this.rotAngle = from + 360;
    });
  }

  private stopSpin(): void {
    const to: number = this.rotAngle % 360;
    this.getUIContext().animateTo({ duration: 0, curve: Curve.Linear }, (): void => {
      this.rotAngle = to;
    });
  }

  /** 按下弹性缩放（物理弹簧曲线） */
  private setPressed(value: boolean): void {
    this.getUIContext().animateTo({ curve: curves.springMotion(0.28, 0.72) }, (): void => {
      this.pressed = value;
    });
  }

  /** 触觉震动反馈（无 VIBRATE 能力/权限时静默失败） */
  private haptic(): void {
    try {
      const effect: vibrator.VibrateTime = { type: 'time', duration: 18 };
      const attr: vibrator.VibrateAttribute = { usage: 'touch' };
      vibrator.startVibration(effect, attr).catch((): void => {});
    } catch (err) {
      // 设备不支持震动：忽略
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 弹性缩放容器：四层画布 + 玻璃盘面 + 内容层同步缩放
      Stack({ alignContent: Alignment.Center }) {
        // 光晕层（最下）：弥散呼吸光晕（仅连接态）—— 被玻璃盘面模糊透出
        Canvas(this.glowCtx)
          .width(this.glowSize)
          .height(this.glowSize)
          .onReady((): void => {
            this.glowReady = true;
            this.redrawGlow();
            this.startTicker();
          })

        // 静态轨道层（玻璃下方）：点阵轨道 + 渐变轨环（不随相位变化）
        Canvas(this.dynCtx)
          .width(this.glowSize)
          .height(this.glowSize)
          .onReady((): void => {
            this.dynReady = true;
            this.redrawDyn();
          })

        // 玻璃盘面（中层）：真磨砂 —— 背板模糊 + 半透明着色，透出光晕与页面渐变；
        // 弥散投影仅连接后显示（空闲态无光晕），350ms 平滑过渡
        Column()
          .width(this.discSize)
          .height(this.discSize)
          .borderRadius(this.discSize / 2)
          .backgroundEffect({
            radius: 40,
            // 2026-10-21 二次收敛：绿色只留在**最内圈**（电源徽标小圆），
            // 盘面保持原玻璃色，避免整个按钮泛绿。
            color: ThemeService.isDark() ? 'rgba(30, 41, 66, 0.55)' : 'rgba(255, 255, 255, 0.52)'
          })
          .shadow(this.isConnected
            ? {
              radius: 32,
              color: ThemeService.isDark() ? 'rgba(59, 130, 246, 0.34)' : 'rgba(10, 89, 247, 0.18)',
              offsetY: 16
            }
            : { radius: 0, color: 'rgba(0, 0, 0, 0)', offsetY: 0 })
          .animation({ duration: 350, curve: Curve.EaseOut })

        // 静态层（玻璃上方）：镜面描边 + 内凹槽环
        Canvas(this.staticCtx)
          .width(this.glowSize)
          .height(this.glowSize)
          .onReady((): void => {
            this.staticReady = true;
            this.redrawStatic();
          })

        // 自转层（最上）：两条电平弧线 + 弧头光点 + 两颗卫星。
        // 2026-10-29 修「启动后自转卡顿掉帧」：整层只画一次，转动交给渲染线程
        // 插帧（宣式无限循环 animateTo）——不再逐帧重绘 Canvas，
        // JS 线程被连接流程占满时也不会掉帧。这些元素半径 130/140vp
        // 全在 200vp 盘面之外，提到玻璃上方不改变观感（不会被模糊），
        // 也避开了背板模糊逐帧重算。
        Canvas(this.rotCtx)
          .width(this.glowSize)
          .height(this.glowSize)
          .rotate({ angle: this.rotAngle })
          .onReady((): void => {
            this.rotReady = true;
            this.redrawRot();
            this.startSpin();
          })

        Column({ space: 6 }) {
          // 顶部电源图标胶囊微标（40vp，#EFF5FF）
          Stack({ alignContent: Alignment.Center }) {
            if (this.isConnecting) {
              LoadingProgress()
                .width(22).height(22)
                .color(this.accent())
            } else {
              Image($r('app.media.ic_power'))
                .width(22).height(22)
                // 深色连接态：小圆是实心绿，图标必须反白，否则绿压绿看不见
                .fillColor(this.isConnected && ThemeService.isDark() ? '#04231A' : this.accent())
            }
          }
          .width(40)
          .height(40)
          .borderRadius(20)
          .backgroundColor(this.isConnected
            ? (ThemeService.isDark() ? 'rgba(16, 211, 138, 0.92)' : 'rgba(0, 186, 102, 0.16)')
            : (ThemeService.isDark() ? 'rgba(59, 130, 246, 0.20)' : '#EFF5FF'))
          .border({
            // 只给深色主题加描边：浅色主题已确认，保持原样不动
            width: (this.isConnected && ThemeService.isDark()) ? 1 : 0,
            color: 'rgba(52, 211, 153, 1.0)'
          })

          Text(this.titleText())
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(TunBoxColors.textPrimary)
            .maxLines(1)
          // 当前节点名（按钮内部，原 StatusRing 位置语义）
          Text(this.nodeName.length > 0 ? this.nodeName : '暂无可用节点')
            .fontSize(12)
            .fontColor(TunBoxColors.textMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: this.discSize - 40 })
        }
        .alignItems(HorizontalAlign.Center)
        .offset({ y: 4 })

        // 出口 IP：沿底部半圆弧形显示（2026-10-28 用户要求；未连接不显示）
        if (this.isConnected && this.ipText.length > 0) {
          this.ArcIpText()
        }
      }
      .width(this.glowSize)
      .height(this.glowSize)
      .scale({
        x: ORB_SCALE * (this.pressed ? 0.95 : 1.0),
        y: ORB_SCALE * (this.pressed ? 0.95 : 1.0)
      })
    }
    .width(this.glowSize * ORB_SCALE)
    .height(this.glowSize * ORB_SCALE)
    .accessibilityText(this.isConnected ? '断开连接' : '开启连接')
    .onVisibleAreaChange([0.05, 0.95], (isVisible: boolean) => {
      this.onVisible(isVisible);
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.setPressed(true);
      } else if (event.type === TouchType.Up) {
        this.haptic();
        this.onToggle();
        this.setPressed(false);
      } else if (event.type === TouchType.Cancel) {
        this.setPressed(false);
      }
    })
  }
}
