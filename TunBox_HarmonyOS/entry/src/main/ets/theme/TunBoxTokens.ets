/**
 * TunBox UI 设计令牌 —— 严格对齐《TunBox-UI重构笔记》§1《设计系统与主题规范》
 * （文档来源：EdgeEver 笔记 TunBox-UI重构，2026-10-17）
 *
 * 文档 §1.1 给出的是浅色原值，逐字落在这里；深色按用户 2026-10-17 提供的
 * 《深色主题配色方案》逐值落地：底 #0A0E1A→#0F131D 渐变 / 卡 #141C2E / 微光描边
 * rgba(255,255,255,0.08) / 凹槽 #0C1220 / 高亮蓝 #3B82F6（浅亮态 #60A5FA）/
 * 荧光绿 #10B981 / 文字 #F8FAFC·#94A3B8·#64748B / Dock rgba(17,24,39,0.85)。
 * 浅色背景同为渐变：#F4F6FB → #EBF1FD。
 *
 * 全部以静态 getter 暴露，调用点写法与文档示例一致（TunBoxColors.primary / surfaceCard …），
 * 深浅切换在渲染时即时解析（页面持有 @StorageLink('theme_revision') 即重渲染）。
 */
import { AppBgTheme, ThemeService } from './ThemeService';
import { LatencyRecord, LatencyPolicy, LatencyState } from '../commons/services/LatencyState';
import { LatencyStore, LatencyViewLevel } from '../commons/latency/LatencyStore';

/**
 * 页面级动效参数（2026-10-17 用户规格：水平滑动 + 淡入淡出，时长 220–300ms，
 * 位移取屏宽 4%–8%；新页沿水平方向轻进入，旧页同步退出）。页签切换与路由推入式子页共用同一套。
 */
export class TunBoxMotion {
  /** 设计基线时长（ms）—— 手机档（<8.5 英寸）实测观感定版值 */
  static readonly BASE_MS: number = 260;

  /**
   * 转场时长（ms）——按屏幕对角线英寸分档，且不低于设计基线。
   *
   * 华为应用市场上架规范：全屏页面转场（层级/新建/编辑/搜索等）
   * · < 8.5 英寸 ≥ 200ms
   * · 8.5 ~ 12 英寸 ≥ 250ms
   * · > 12 英寸 ≥ 300ms
   *
   * 基线 260ms 已覆盖前两档，只有 12 英寸以上需要抬到 300；
   * 档位由 EntryAbility.onCreate 按 display 实测尺寸写入 `tb_motion_required_ms`，
   * 取 max(基线, 规范下限) —— 小屏保持既有观感，大屏自动合规。
   */
  static get ms(): number {
    const required = AppStorage.get<number>('tb_motion_required_ms');
    const floor = required !== undefined && required > 0 ? required : 0;
    return floor > TunBoxMotion.BASE_MS ? floor : TunBoxMotion.BASE_MS;
  }
  /** 转场位移：百分比字符串用于路由页（相对页宽），vp 数值用于页签（本机 800vp 宽 → 48vp ≈ 6%） */
  static readonly slidePercent: string = '6%';
  static readonly slideVp: number = 48;
  /** 转场曲线 */
  static readonly curve: Curve = Curve.Friction;
}

export class TunBoxColors {
  // ── 品牌与强调色（文档原值；深浅共用同一强调色，深色仅次级色阶提亮）──
  static get primary(): ResourceColor {
    // 深色为高亮蓝 #3B82F6（用户深色规范），浅色保持鸿蒙官方品牌蓝 #0A59F7
    return ThemeService.isDark() ? '#3B82F6' : '#0A59F7';
  }

  static get primaryHover(): ResourceColor {
    return ThemeService.isDark() ? '#60A5FA' : '#0047D4';
  }

  /** 弱化胶囊背景（primaryLight） */
  static get primaryLight(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(59, 130, 246, 0.20)' : '#EFF4FF';
  }

  static get primaryBorder(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(59, 130, 246, 0.42)' : '#D0E1FD';
  }

  /**
   * 底栏选中页签的胶囊底（2026-10-28 用户要求「高亮也改成透明的范围，带一点沉浸光感的底色就行」）。
   *
   * 不再用 `primaryLight`（浅色是实色 #EFF4FF，压在玻璃上会变成一块不透明奶白片，
   * 直接挡死底面模糊），改用**低 alpha 品牌蓝**：颜色本身就能透出背后的玻璃与粒子，
   * 叠在彩色背景配色上也只会染上一点蓝调，不会变成白色补丁。
   * 深色模式选更高的 alpha（玻璃本来就深，太低就看不见了）。
   */
  static get dockPillFill(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(96, 165, 250, 0.16)' : 'rgba(37, 99, 235, 0.09)';
  }

  /** 代理模式三段按钮的选中胶囊（2026-10-26 用户「蓝色再稍微加重一点点」）：
   *  比 primaryLight(#EFF4FF) 深一档，仍属低饱和品牌蓝，不是实心主色按钮。 */
  static get modeChipFill(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(59, 130, 246, 0.32)' : '#E1EBFF';
  }

  static get modeChipBorder(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(59, 130, 246, 0.60)' : '#BACFFA';
  }

  // ── 语义状态色 ──
  static get success(): ResourceColor {
    // 深色为荧光绿 #10B981（用户深色规范）
    return ThemeService.isDark() ? '#10B981' : '#00BA66';
  }

  static get successLight(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(16, 185, 129, 0.15)' : '#E8FAF0';
  }

  /** 智能优选卡专用：浅绿底 / 浅绿描边（文档 §3.2 内核智能优选条目） */
  static get successTint(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(16, 185, 129, 0.10)' : '#F1FBF5';
  }

  static get successBorder(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(16, 185, 129, 0.34)' : '#C8F2D7';
  }

  static get warning(): ResourceColor {
    return ThemeService.isDark() ? '#FF9F33' : '#FF8800';
  }

  static get danger(): ResourceColor {
    return ThemeService.isDark() ? '#FF5A5F' : '#FA2A2D';
  }

  static get dangerLight(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(250, 42, 45, 0.16)' : '#FEECEE';
  }

  // ── 背景配色（带修订号参数的取色方法）──
  /**
   * 2026-10-28 真机像素取证（`.pi-captures` 前后对比）确认的根因：
   *
   * ArkUI V1 的 `@StorageLink` 依赖是**按元素**登记的 —— 只有在某个元素的属性表达式里
   * 真的**读**到 `this.themeRevision`，该元素才会在修订号变化时重绘。此前 `themeRevision`
   * 在十几个页面里被声明、却从未出现在任何 build 表达式里，于是「换浅色背景 / 切深浅色」
   * 界面上一点变化都没有，必须重启 App（重启走全量重建）才生效。
   *
   * 所以所有随主题变化的颜色 token 都改成**带 `rev` 参数的方法**，调用点统一写
   * `TunBoxColors.surfaceCard(this.themeRevision)`：这个读取本身就是重绘依赖的登记动作。
   * `rev` 同时作为配色解析缓存的键，避免每帧重复解析字符串（见 syncPalette）。
   */
  private static paletteKey: string = '';
  private static paletteStartHex: string = '#F4F6FB';
  private static paletteEndHex: string = '#EBF1FD';

  /**
   * 解析并缓存当前背景配色两端色。
   * 缓存键包含 rev + 深浅 + 配色名：`theme_revision` 在 App 启动时被写成 0（与初始值同值），
   * 若只按 rev 做键，preferences 里读出的配色就要等到下一次 bump 才生效。
   */
  private static syncPalette(rev: number): void {
    const key = `${rev}:${ThemeService.isDark() ? 'd' : 'l'}:${ThemeService.currentBgTheme()}`;
    if (key === TunBoxColors.paletteKey) {
      return;
    }
    TunBoxColors.paletteKey = key;
    const palette = ThemeService.bgColors();
    TunBoxColors.paletteStartHex = palette.start;
    TunBoxColors.paletteEndHex = palette.end;
  }

  private static hex2(value: number): string {
    const s = Math.round(value).toString(16);
    return s.length === 1 ? `0${s}` : s;
  }

  /** `#RRGGBB` 向白色混合：t=0 得原色，t=1 得纯白（用于从背景色派生浅色表面色） */
  private static mixToWhite(hex: string, t: number): string {
    const r = parseInt(hex.substring(1, 3), 16);
    const g = parseInt(hex.substring(3, 5), 16);
    const b = parseInt(hex.substring(5, 7), 16);
    return `#${TunBoxColors.hex2(r + (255 - r) * t)}${TunBoxColors.hex2(g + (255 - g) * t)}`
      + `${TunBoxColors.hex2(b + (255 - b) * t)}`;
  }

  /**
   * 浅色表面色派生（2026-10-28 用户要求「卡片/表面要跟着背景配色走，别是死白」）。
   *
   * 默认蓝灰（AppBgTheme.DEFAULT）沿用已验证过的浅色规范原值（纯白卡 + #E5EDF8 描边）——
   * 那是设计稿定稿值，不动；只有 Mint / Homebrew / Noctis 三套彩色背景才取背景终点色
   * 向白色混合出同色系的表面色，否则彩色底上压一片纯白卡会「割裂」。
   */
  private static lightSurface(whiteMix: number, fallback: string, rev: number): ResourceColor {
    TunBoxColors.syncPalette(rev);
    if (ThemeService.currentBgTheme() === AppBgTheme.DEFAULT) {
      return fallback;
    }
    return TunBoxColors.mixToWhite(TunBoxColors.paletteEndHex, whiteMix);
  }

  /** 页面底色的平色回退（渐变起点色）；页面根容器请统一用 bgGradientStart/End 渐变 */
  static background(rev: number): ResourceColor {
    TunBoxColors.syncPalette(rev);
    return TunBoxColors.paletteStartHex;
  }

  /** 系统全局大背景渐变：浅色默认 #F4F6FB → #EBF1FD；深色 #0B1220 → #0F131D
   *  （深色起点 2026-10-23 由 #0A0E1A 调成 #0B1220：与 ui_background、
   *   状态栏底色取同一个值，页面顶部与状态栏之间不再出现一条更深的色带 —— AGC 状态栏整改）
   *  2026-10-28 用户要求：浅色可在设置里选 Mint / Homebrew / Noctis Hibernus，
   *  三套配色统一走 ThemeService.bgColors()（状态栏/窗口底色同源）。 */
  static bgGradientStart(rev: number): ResourceColor {
    TunBoxColors.syncPalette(rev);
    return TunBoxColors.paletteStartHex;
  }

  static bgGradientEnd(rev: number): ResourceColor {
    TunBoxColors.syncPalette(rev);
    return TunBoxColors.paletteEndHex;
  }

  /** `#RRGGBB` → `rgba(r, g, b, a)`；背景配色是运行时字符串，渐隐底需要同色不同透明度。 */
  private static rgba(hex: string, alpha: number): string {
    const r = parseInt(hex.substring(1, 3), 16);
    const g = parseInt(hex.substring(3, 5), 16);
    const b = parseInt(hex.substring(5, 7), 16);
    return `rgba(${r}, ${g}, ${b}, ${alpha})`;
  }

  // ── 底栏底部渐隐底（2026-10-26 二次修正）──
  /** 底栏下方一条全宽、无模糊的底部渐隐：从页面底色 0 透明度渐变到接近不透明，让滚到底的
   *  内容文字自然淡出。基色跟随当前背景配色（浅色三套 / 深色一套），与页面无缝衔接。
   *  2026-10-28 用户要求：去掉原来那条实化的渐隐条（内容直接透到栏体下方），
   *  MainPage 不再挂 dockScrim；这里保留以免其它页面/后续入口引用时再次手写颜色。 */
  static dockScrimTop(rev: number): ResourceColor {
    TunBoxColors.syncPalette(rev);
    return TunBoxColors.rgba(TunBoxColors.paletteEndHex, 0.0);
  }

  static dockScrimMid(rev: number): ResourceColor {
    TunBoxColors.syncPalette(rev);
    return TunBoxColors.rgba(TunBoxColors.paletteEndHex, 0.62);
  }

  static dockScrimBottom(rev: number): ResourceColor {
    TunBoxColors.syncPalette(rev);
    return TunBoxColors.rgba(TunBoxColors.paletteEndHex, 0.97);
  }

  /** 卡片表面：浅色=纯白高光卡片（2026-10-17 用户浅色规范「核心卡片容器 #FFFFFF」+ 1px #E5EDF8 内描边）。
   *  2026-10-17 性能修正：不再逐卡挂 blur（30+ 离屏模糊层拖慢切页/滚动），玻璃感靠半透明填充+渐变底；Dock/弹层等背后有滚动内容的组件才保留 blur */
  static surfaceCard(rev: number): ResourceColor {
    if (ThemeService.isDark()) {
      return 'rgba(20, 28, 46, 0.78)';
    }
    // 白卡：默认配色保持 #FFFFFF，彩色背景（Mint/Homebrew/Noctis）派生同色系近白
    return TunBoxColors.lightSurface(0.62, '#FFFFFF', rev);
  }

  /** 次级凹槽底色：浅色对齐用户规范「#F0F4FC 或 #EDF2FA」 */
  static surfaceSubtle(rev: number): ResourceColor {
    if (ThemeService.isDark()) {
      return '#232A35';
    }
    return TunBoxColors.lightSurface(0.42, '#F0F4FC', rev);
  }

  /** 微光内描边：深色 1px rgba(255,255,255,0.08)（用户规范），浅色 #E5EDF8 */
  static cardBorder(rev: number): ResourceColor {
    if (ThemeService.isDark()) {
      return 'rgba(255, 255, 255, 0.08)';
    }
    return TunBoxColors.lightSurface(0.22, '#E5EDF8', rev);
  }

  // ── 排版 ──
  static get textPrimary(): ResourceColor {
    return ThemeService.isDark() ? '#F8FAFC' : '#111827';
  }

  static get textSecondary(): ResourceColor {
    return ThemeService.isDark() ? '#94A3B8' : '#4B5563';
  }

  static get textMuted(): ResourceColor {
    return ThemeService.isDark() ? '#64748B' : '#9CA3AF';
  }

  static get textOnPrimary(): ResourceColor {
    return '#FFFFFF';
  }

  // ── 文档未逐字给出的控件底色（同设计语言派生，供分段器/标签/代码容器复用）──
  /** 分段器轨道（文档 §3.1 智能/全局 #EDF2FA） */
  static controlTrack(rev: number): ResourceColor {
    if (ThemeService.isDark()) {
      return '#0C1220';
    }
    return TunBoxColors.lightSurface(0.40, '#EDF2FA', rev);
  }

  /** 三段模式条轨道（文档 §3.3 #E9EFF9） */
  static controlTrackSoft(rev: number): ResourceColor {
    if (ThemeService.isDark()) {
      return '#0C1220';
    }
    return TunBoxColors.lightSurface(0.34, '#E9EFF9', rev);
  }

  /** 分段器选中块（文档：纯白） */
  static controlThumb(rev: number): ResourceColor {
    if (ThemeService.isDark()) {
      return '#3A4453';
    }
    return TunBoxColors.lightSurface(0.86, '#FFFFFF', rev);
  }

  /** 协议/类型标签底（文档 §3.2 #EFF3F9 / §3.3 #EEF2F8 / §3.5 #EFF4FD） */
  static chipBg(rev: number): ResourceColor {
    if (ThemeService.isDark()) {
      return '#2A323F';
    }
    return TunBoxColors.lightSurface(0.44, '#EFF3F9', rev);
  }

  /** 弹窗内选项行底（文档 §3.4 #F8FAFD） */
  static rowFill(rev: number): ResourceColor {
    if (ThemeService.isDark()) {
      return '#232A35';
    }
    return TunBoxColors.lightSurface(0.74, '#F8FAFD', rev);
  }

  /** 代码/等宽容器底与描边（文档 §3.6 #F8FAFC / #E2E8F0） */
  static codeBg(rev: number): ResourceColor {
    if (ThemeService.isDark()) {
      return '#151A22';
    }
    return TunBoxColors.lightSurface(0.70, '#F8FAFC', rev);
  }

  static codeBorder(rev: number): ResourceColor {
    if (ThemeService.isDark()) {
      return 'rgba(255, 255, 255, 0.08)';
    }
    return TunBoxColors.lightSurface(0.30, '#E2E8F0', rev);
  }

  static get codeText(): ResourceColor {
    return ThemeService.isDark() ? '#D7DEE8' : '#1E293B';
  }

  /** 速率曲线容器底（文档 §3.1 #F0F4FC） */
  static chartBox(rev: number): ResourceColor {
    if (ThemeService.isDark()) {
      return '#0C1220';
    }
    return TunBoxColors.lightSurface(0.42, '#F0F4FC', rev);
  }

  // ── 顶部导航栏 / 底部悬浮栏（文档 §2.1 / §2.2）──
  static navFill(rev: number): ResourceColor {
    TunBoxColors.syncPalette(rev);
    if (ThemeService.isDark()) {
      return 'rgba(18, 21, 28, 0.90)';
    }
    return TunBoxColors.rgba(TunBoxColors.paletteStartHex, 0.90);
  }

  /** 底栏填充：半透明底，配合 FloatingBottomBar 的渐变与毛玻璃使用。 */
  static dockFill(rev: number): ResourceColor {
    TunBoxColors.syncPalette(rev);
    if (ThemeService.isDark()) {
      return 'rgba(15, 19, 29, 0.50)';
    }
    return TunBoxColors.rgba(TunBoxColors.paletteStartHex, 0.50);
  }

  /**
   * 底栏渐变两端色 —— 液态玻璃的「染色层」。
   *
   * 2026-10-28「沉浸光感 + 液态玻璃」修正：alpha 由 0.42/0.80 降到 0.12/0.30。
   * 原来的 0.80 是**不透明级别**的填充，会连同 `backgroundEffect` 的模糊与饱和度提升
   * 一起盖死 —— 那就退化成一块「磨砂塑料板」，而不是玻璃。
   * 液态玻璃的观感来自「背后的画面透过玻璃被拉高饱和 + 轻微染色」，
   * 所以染色层只能**极淡**，主要靠 `backgroundEffect.saturation` 出效果。
   *
   * 终点色仍跟当前背景配色走（薄荷/暖米/暮蓝），否则选了彩色背景后底栏还留在蓝灰系，边边会脱开。
   */
  static dockGradientTop(rev: number): ResourceColor {
    TunBoxColors.syncPalette(rev);
    if (ThemeService.isDark()) {
      return 'rgba(15, 19, 29, 0.16)';
    }
    return TunBoxColors.rgba(TunBoxColors.paletteStartHex, 0.12);
  }

  static dockGradientBottom(rev: number): ResourceColor {
    TunBoxColors.syncPalette(rev);
    if (ThemeService.isDark()) {
      return 'rgba(15, 19, 29, 0.44)';
    }
    return TunBoxColors.rgba(TunBoxColors.paletteEndHex, 0.30);
  }

  /** 沉浸材质的染色层：必须带透明度，否则会把材质滤色挡死（官方 ImmersiveOptions.materialColor 约束）。 */
  static dockMaterialTint(rev: number): ResourceColor {
    return ThemeService.isDark() ? 'rgba(20, 26, 40, 0.32)' : 'rgba(255, 255, 255, 0.22)';
  }

  /** 光感反馈色（底栏按下时材质里亮起的那道「光」）：浅色用主色，深色用浅蓝，都不刺眼。 */
  static get dockLightEffect(): ResourceColor {
    return ThemeService.isDark() ? '#8EC5FF' : '#3B82F6';
  }

  /** 切页签粒子：主色 + 次级浅蓝交替，形成一点层次 */
  static get dockSparkAlt(): ResourceColor {
    return ThemeService.isDark() ? '#93C5FD' : '#60A5FA';
  }

  /**
   * 切页签粒子第三档配色（2026-10-28「粒子再多几倍」）：
   * 96 粒里每 3 粒有一颗用这个更淡的色，配合 `opacity × 0.55` 做「远景光尘」层，
   * 否则几十颗同亮度的点会糊成一片光斑，看不出纵深。
   */
  static get dockSparkSoft(): ResourceColor {
    return ThemeService.isDark() ? '#BFDBFE' : '#93C5FD';
  }

  /**
   * 液态玻璃滤色层（2026-10-28 用户要求）：`backgroundEffect.color` 的蒙层。
   * 必须**极低** alpha —— 这一层只是把模糊后的画面稍微拉向主题色，
   * alpha 一高就把 `saturation` 吸上来的背景色整个盖死，玻璃感立刻退化成塑料片。
   */
  static dockGlassTint(rev: number): ResourceColor {
    return ThemeService.isDark() ? 'rgba(20, 26, 40, 0.10)' : 'rgba(255, 255, 255, 0.06)';
  }

  /** 液态玻璃上沿的镜面高光起点：浅色接近纯白，深色只留一层冷调微光，避免夜间「发白发脏」 */
  static dockSheenStrong(rev: number): ResourceColor {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.14)' : 'rgba(255, 255, 255, 0.85)';
  }

  /** 镜面高光的过渡段：10% 处开始衰减，一半高度前彻底透明（只留棱边反光，不铺满整栏） */
  static dockSheenSoft(rev: number): ResourceColor {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.04)' : 'rgba(255, 255, 255, 0.30)';
  }

  /** 底栏描边
   *  2026-10-29 用户「深色模式下底部 dock 栏的边框特别明显」——真机实测（深色，1600×2560）：
   *  栏体内部 40，而下沿/左右沿的白边被抬到 68~75，**比内部亮 30 级**；
   *  外部背景只有 19~40。原因：栏体内部是上亮下暗的渐变（上沿 66~71 → 下沿 40~44），
   *  恒定 alpha 的白边在越暗的地方越跳，深色下就成了一道硬白环。
   *  浅色下 0.60 白描边压在近白玻璃上，实测与内部只差 2~3 级，根本看不出来，所以保持不动。
   *  深色下栏体内部（40~70）与页面背景（19~40）本身已有亮度差，边缘本就分得开；
   *  上沿也还有镜面高光兜底 ⇒ 深色直接不画描边（透明而不是删掉属性，保持两套结构一致）。 */
  static get dockEdge(): ResourceColor {
    return ThemeService.isDark() ? Color.Transparent : 'rgba(255, 255, 255, 0.60)';
  }

  /**
   * 底栏投影（2026-10-28 用户：「底框有一半是阴影的，不好看，只要上面留一点点阴影衬托一下」）。
   *
   * 之前用的是 `ImmersiveMaterial` 的 `applyShadow`，它给的是**环绕一整圈**的大阴影：
   * 栏体高度才 64vp，一圈阴影直接吃满下半栏（实测 y 2360–2420 比背景暗 20 级），
   * 看起来就像底栏自己发黑。现在改成只向上投影（`offsetY` 为负），阴影全部落在栏体上方。
   */
  static get dockShadow(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(0, 0, 0, 0.45)' : 'rgba(15, 23, 42, 0.10)';
  }

  /**
   * 切页签沿底滑动的「光影团」中心色（2026-10-28 用户要求）。
   * 两侧透明、中间亮，横向看就是一团拖在底部的光；alpha 比粒子的 0.92 低一档，
   * 因为它要叠在玻璃上，太亮会把栏体颜色抢掉。
   */
  static get dockSweepCore(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(147, 197, 253, 0.55)' : 'rgba(59, 130, 246, 0.45)';
  }

  /**
   * 渐变终点用的「同色透明」（2026-10-29）。
   *
   * ❗千万别在渐变里用 `Color.Transparent` 当端点：它是**透明黑** `rgba(0,0,0,0)`。
   * ArkUI 的 `linearGradient` 插值**不是预乘空间**（CSS 是预乘的，所以 CSS 里
   * 白→透明不会发灰），把 `rgba(255,255,255,0.30)` 插到 `rgba(0,0,0,0)` 时，
   * 中间段会被算成 `rgba(127,127,127,0.15)` 这种**中灰**：在一张 241 的浅背景上
   * 正好得到 224 —— 就是用户连报三次的「dock 栏一半是阴影」。
   * 真机取值验证（高光渐变 y=2376/2392/2408）：
   *   非预乘模型 227.5 / 220.1 / 230.5，实测 227.8 / 224.0 / 231.9 ✓
   *   预乘模型 243.9（差 16 级）✗
   * ⇒ 以后凡是「亮色渐隐到透明」，端点一律写成**同 RGB、alpha 0**。
   */
  static get dockSheenClear(): ResourceColor {
    return 'rgba(255, 255, 255, 0)';
  }

  /** 滑行光影两端的同色透明（RGB 必须与 `dockSweepCore` 一致，否则同样会发灰） */
  static get dockSweepClear(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(147, 197, 253, 0)' : 'rgba(59, 130, 246, 0)';
  }

  /**
   * 底栏未选中的图标与文字。
   * 2026-10-29 用户「dock 字体要清楚一点，现在有点模糊」：原来浅色用 #9CA3AF（gray-400），
   * 压在玻璃上的对比度只有约 2.1:1，12fp 细笔画直接糊进背景。提到 #6B7280（gray-500，
   * 对比度约 4.8:1）后笔画边界立得起来；深色侧同理从 #64748B 提亮到 #94A3B8。
   */
  static get dockIconInactive(): ResourceColor {
    return ThemeService.isDark() ? '#94A3B8' : '#6B7280';
  }

  /** 底栏点击瞬间光亮（用户 2026-10-17 要求「点哪个位置出现瞬间的光亮」）：亮帧满透明度呈现，靠 280ms 淡出收尾 */
  static get dockGlow(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(96, 165, 250, 0.50)' : 'rgba(10, 89, 247, 0.30)';
  }

  /** 弹窗蒙层（文档 §3.4 rgba(15, 23, 42, 0.35)） */
  static get scrim(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(0, 0, 0, 0.55)' : 'rgba(15, 23, 42, 0.35)';
  }

  // ── 顶部浮动提示胶囊（2026-10-18 用户要求：不要黑色底，跟软件整体配色一致）──
  /**
   * 底色：浅色=卡片白（与订阅卡/概览卡同一种表面），深色=半透明深卡底。
   * 旧实现是写死的 rgba(15,23,42,0.92) 黑底 —— 在浅色主题里像一块外来的黑膏药，
   * 用户明确要求换成与整体配色一致的底与字色。
   */
  static toastBg(rev: number): ResourceColor {
    if (ThemeService.isDark()) {
      return 'rgba(20, 28, 46, 0.94)';
    }
    return TunBoxColors.lightSurface(0.80, '#FFFFFF', rev);
  }

  /** 文字：跟随正文色（浅色墨黑 / 深色近白），不再一律白字 */
  static get toastText(): ResourceColor {
    return ThemeService.isDark() ? '#F8FAFC' : '#111827';
  }

  /** 描边：品牌蓝细线 —— 白色胶囊叠在白色卡片上时靠它勾出轮廓 */
  static get toastBorder(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(59, 130, 246, 0.42)' : '#D0E1FD';
  }

  /** 投影：浅色用极淡的品牌蓝投影（与底栏投影同源），深色用纯黑 */
  static get toastShadow(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(0, 0, 0, 0.60)' : 'rgba(10, 89, 247, 0.16)';
  }
}

/** 文档 §1.2 圆角与间距规范 */
export class TunBoxGeometry {
  /** 页面水平外边距 16vp */
  static readonly pagePadding: number = 16;
  /** 卡片曲率 20~24vp（标准卡 22 / 次级卡 20 / 大卡 26） */
  static readonly cardRadius: number = 22;
  static readonly cardRadiusSmall: number = 20;
  static readonly cardRadiusLarge: number = 26;
  /** 胶囊/小组件圆角 100vp（Full Pill） */
  static readonly pillRadius: number = 100;
  /** 控件圆角 14vp（按钮/输入框） */
  static readonly controlRadius: number = 14;
  /** 列表间距 12vp */
  static readonly listGap: number = 12;
  /** 卡片内边距 16~20vp */
  static readonly cardPadding: number = 16;
  static readonly cardPaddingLarge: number = 18;
  /** 顶部导航栏高 56vp */
  static readonly navHeight: number = 56;
  /** 底部悬浮栏：64 高 / 32 圆角；沉浸式下贴近系统手势区。 */
  static readonly dockHeight: number = 64;
  static readonly dockRadius: number = 32;
  static readonly dockBottomMargin: number = 0;
  /** 底栏底部渐隐底高度：盖住底栏本体 + 上方一段过渡，让内容在进入底栏前淡出 */
  static readonly dockScrimHeight: number = 170;
  /**
   * 页面底部为悬浮栏留白（栏高 + 下边距 + 余量）
   *
   * 2026-10-29 真机取证：70 太小，内容（末张卡片 + 其投影）底边落在 2347px，
   * 而栏体顶边在 2342px —— 内容正好卡在栏口。栏体的 `backgroundEffect` 模糊半径 26vp
   * 会把这弡暗边**向下抹进栏内约 62px**，于是栏内上半比下半暗 16~28 级，
   * 看上去就是用户报障的「底框一半是阴影」（与栏体自身 shadow 无关，删掉阴影像素纹丝不动）。
   * 现在抬到 112vp（≈266px），静止时内容底边约 2228px，高于模糊能够到的 2280px ——
   * 栏内上下亮度一致；滑动中内容从玻璃下穿过时仍然是正常的毛玻璃透出。
   */
  static readonly dockClearance: number = 112;
  /** 首页「天体轨域」启动按钮（CelestialPowerOrb）：
   *  最外呼吸光晕 / 点阵轨道 / 渐变轨环(弧线) / 核心亚克力盘。
   *
   *  2026-10-19 用户要求「启动按钮缩小一点，下面整体往上挪一行」：
   *  原 320/280/260/200 等比缩到约 87.5%（280/245/228/175），
   *  按钮整体高度减少 40vp —— 首页下方内容因此上移一行。
   *  ⚠ 改这四个值必须同步改 CelestialOrbLayout 的 OUTER_R / RING_R
   *  （它们分别定义为 orbTrack/2、orbArcRing/2），否则十字轨道半径与
   *  画布尺寸不一致，回归脚本 scripts/verify-orb-separation.mjs 会失败。 */
  static readonly orbGlow: number = 280;
  static readonly orbTrack: number = 245;
  static readonly orbArcRing: number = 228;
  static readonly orbDisc: number = 175;
}

/**
 * 节点延迟的文案与配色。
 *
 * 颜色角色取自文档（绿=极速 / 橙=偏高 / 红=拦截或错误），阈值与失败语义沿用本仓库
 * 既有产品决策（UiTokens.LatencyStyle）：<300ms 绿 / 300~800ms 橙 / ≥800ms 红；
 * 自动/静默批的失败显示中性「未测」（用户明确诉求），只有用户手测失败标红。
 */
export class TunBoxPing {
  static readonly TIMEOUT_MS: number = 65535;

  static isTimeout(latencyMs: number | null): boolean {
    return latencyMs !== null && (latencyMs <= 0 || latencyMs >= TunBoxPing.TIMEOUT_MS);
  }

  static color(latencyMs: number | null): ResourceColor {
    if (latencyMs === null) {
      return TunBoxColors.textMuted;
    }
    if (TunBoxPing.isTimeout(latencyMs)) {
      return TunBoxColors.danger;
    }
    if (latencyMs < 300) {
      return TunBoxColors.success;
    }
    if (latencyMs < 800) {
      return TunBoxColors.warning;
    }
    return TunBoxColors.danger;
  }

  static text(latencyMs: number | null): string {
    if (latencyMs === null) {
      return '--';
    }
    if (TunBoxPing.isTimeout(latencyMs)) {
      return '超时';
    }
    return `${latencyMs}ms`;
  }

  /** 状态化文案（五态可区分）。
   *
   * ⚠ 2026-10-18 用户裁定：**失败一律显示「超时/失败」，不再按来源分成「未测」**。
   * 旧实现把 `source === 'auto'`（冷启动 / 导入订阅后的静默批）的失败显示成中性
   * 「未测」，本意是避免冷内核假超时误导；但真机上表现为「导入订阅后一大片未测」，
   * 用户明确要求「要么显示延迟多少、要么显示超时，不要第三种结果」——已经测出结论
   * 却显示成"没测过"，比显示超时更让人误会（用户会以为根本没测速）。
   */
  static recordText(rec: LatencyRecord | null, nowMs: number): string {
    if (rec === null) {
      return '--';
    }
    if (rec.hasValue()) {
      const body = `${rec.delayMs}ms`;
      if (rec.state === LatencyState.OFFLINE) {
        return `≈${body}`;
      }
      return LatencyPolicy.isStale(rec, nowMs) ? `${body}·旧` : body;
    }
    // 失败结论也可能是**上一轮**的（冷启动从持久化快照恢复）。
    // 2026-10-20 真机反馈「刚打开软件还没测速就显示超时，测完发现节点是好的」：
    // 旧结论不能顶着一颗新鲜的红「超时」出现在列表里 → 标「·旧」并灰显，
    // 与「123ms·旧」的既有口径一致（过期 = 中性，不是当前结论）。
    // 瞬态（测试中 / 已取消）不是结论 —— 用状态词，不查结论表。
    if (rec.state === LatencyState.TESTING) {
      return '测试中';
    }
    if (rec.state === LatencyState.CANCELLED) {
      return '已取消';
    }
    // 结论文案**唯一真源** = LatencyStore.describe（live / 落盘 / 恢复三套渲染同表）。
    // 旧实现在这里另有一份 stateText 包装（两份一模一样 ⇒ 审计 LP05），
    // 现在只认内核那一张表：同一个 failKind 在任何来源都得到同一个文案与级别。
    const view = LatencyStore.describe(rec.failKind, rec.delayMs, rec.atMs, nowMs);
    // 失败结论也可能是**上一轮**的（冷启动从持久化快照恢复）。
    // 2026-10-20 真机反馈「刚打开软件还没测速就显示超时，测完发现节点是好的」：
    // 旧结论不能顶着一颗新鲜的红「超时」出现在列表里 → 标「·旧」并灰显，
    // 与「123ms·旧」的既有口径一致（过期 = 中性，不是当前结论）。
    if (LatencyPolicy.isStaleConclusion(rec, nowMs)) {
      return `${view.text}·旧`;
    }
    return view.text;
  }

  /**
   * 状态化配色：实测走阈值；过期结果中性；失败一律红（与 recordText 同口径）。
   *
   * 例外：「节点未生效」（内核代理表里没有它 = 节点根本没进配置）用**警告色**而不是红 ——
   * 红=「节点坏了」，但这种情况节点可能是好的、只是配置生成把它丢了（真机 2026-10-19：
   * 36 个 anytls 被丢弃导致全红，用户以为节点坏了，实际可用）。用警告色把
   * 「配置问题」与「节点问题」在视觉上分开。
   */
  static recordColor(rec: LatencyRecord | null, nowMs: number): ResourceColor {
    if (rec === null) {
      return TunBoxColors.textMuted;
    }
    if (rec.hasValue()) {
      if (LatencyPolicy.isStale(rec, nowMs)) {
        return TunBoxColors.textSecondary;
      }
      return TunBoxPing.color(rec.delayMs);
    }
    // 结论的**级别**（严重程度）同样归真源：describe().level
    // WARN = 「未生效」（内核表里没有它 = 配置把它丢了，节点可能是好的）→ 警告色；
    // BAD  = 真失败 → 红色。
    const view = LatencyStore.describe(rec.failKind, rec.delayMs, rec.atMs, nowMs);
    if (view.level === LatencyViewLevel.WARN) {
      return TunBoxColors.warning;
    }
    if (view.level === LatencyViewLevel.BAD) {
      // 陈旧的失败结论（上一轮的）→ 中性灰，不顶红字（与 recordText 同口径）
      if (LatencyPolicy.isStaleConclusion(rec, nowMs)) {
        return TunBoxColors.textSecondary;
      }
      return TunBoxColors.danger;
    }
    return TunBoxColors.textMuted;
  }
}
