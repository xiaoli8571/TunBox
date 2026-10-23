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
import { ThemeService } from './ThemeService';
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

  // ── 背景与表面 ──
  /** 页面底色的平色回退（渐变终点色）；页面根容器请统一用 bgGradientStart/End 渐变 */
  static get background(): ResourceColor {
    return ThemeService.isDark() ? '#0F131D' : '#F4F6FB';
  }

  /** 系统全局大背景渐变：浅色 #F4F6FB → #EBF1FD；深色 #0B1220 → #0F131D
   *  （深色起点 2026-10-23 由 #0A0E1A 调成 #0B1220：与 ui_background、
   *   状态栏底色取同一个值，页面顶部与状态栏之间不再出现一条更深的色带 —— AGC 状态栏整改） */
  static get bgGradientStart(): ResourceColor {
    return ThemeService.isDark() ? '#0B1220' : '#F4F6FB';
  }

  static get bgGradientEnd(): ResourceColor {
    return ThemeService.isDark() ? '#0F131D' : '#EBF1FD';
  }

  /** 卡片表面：浅色=纯白高光卡片（2026-10-17 用户浅色规范「核心卡片容器 #FFFFFF」+ 1px #E5EDF8 内描边）。
   *  2026-10-17 性能修正：不再逐卡挂 blur（30+ 离屏模糊层拖慢切页/滚动），玻璃感靠半透明填充+渐变底；Dock/弹层等背后有滚动内容的组件才保留 blur */
  static get surfaceCard(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(20, 28, 46, 0.78)' : '#FFFFFF';
  }

  /** 次级凹槽底色：浅色对齐用户规范「#F0F4FC 或 #EDF2FA」 */
  static get surfaceSubtle(): ResourceColor {
    return ThemeService.isDark() ? '#232A35' : '#F0F4FC';
  }

  /** 微光内描边：深色 1px rgba(255,255,255,0.08)（用户规范），浅色 #E5EDF8 */
  static get cardBorder(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.08)' : '#E5EDF8';
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
  static get controlTrack(): ResourceColor {
    return ThemeService.isDark() ? '#0C1220' : '#EDF2FA';
  }

  /** 三段模式条轨道（文档 §3.3 #E9EFF9） */
  static get controlTrackSoft(): ResourceColor {
    return ThemeService.isDark() ? '#0C1220' : '#E9EFF9';
  }

  /** 分段器选中块（文档：纯白） */
  static get controlThumb(): ResourceColor {
    return ThemeService.isDark() ? '#3A4453' : '#FFFFFF';
  }

  /** 协议/类型标签底（文档 §3.2 #EFF3F9 / §3.3 #EEF2F8 / §3.5 #EFF4FD） */
  static get chipBg(): ResourceColor {
    return ThemeService.isDark() ? '#2A323F' : '#EFF3F9';
  }

  /** 弹窗内选项行底（文档 §3.4 #F8FAFD） */
  static get rowFill(): ResourceColor {
    return ThemeService.isDark() ? '#232A35' : '#F8FAFD';
  }

  /** 代码/等宽容器底与描边（文档 §3.6 #F8FAFC / #E2E8F0） */
  static get codeBg(): ResourceColor {
    return ThemeService.isDark() ? '#151A22' : '#F8FAFC';
  }

  static get codeBorder(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.08)' : '#E2E8F0';
  }

  static get codeText(): ResourceColor {
    return ThemeService.isDark() ? '#D7DEE8' : '#1E293B';
  }

  /** 速率曲线容器底（文档 §3.1 #F0F4FC） */
  static get chartBox(): ResourceColor {
    return ThemeService.isDark() ? '#0C1220' : '#F0F4FC';
  }

  // ── 顶部导航栏 / 底部悬浮毛玻璃栏（文档 §2.1 / §2.2）──
  static get navFill(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(18, 21, 28, 0.90)' : 'rgba(244, 246, 251, 0.90)';
  }

  static get dockFill(): ResourceColor {
    // 2026-10-17 用户要求「底部菜单栏整体实现全透明」：底栏不再有着色层，
    // 只保留 backdropBlur(24) 磨砂模糊 + 细描边/投影维持悬浮轮廓，
    // 背后滚动的内容与渐变底直接透出（深浅主题一致）。
    return Color.Transparent;
  }

  static get dockEdge(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(255, 255, 255, 0.14)' : 'rgba(255, 255, 255, 0.60)';
  }

  static get dockShadow(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(0, 0, 0, 0.60)' : 'rgba(10, 89, 247, 0.08)';
  }

  static get dockIconInactive(): ResourceColor {
    return ThemeService.isDark() ? '#64748B' : '#9CA3AF';
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
  static get toastBg(): ResourceColor {
    return ThemeService.isDark() ? 'rgba(20, 28, 46, 0.94)' : '#FFFFFF';
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
  /** 底部悬浮栏：64 高 / 32 圆角 / 下边距 20（文档 §2.2） */
  static readonly dockHeight: number = 64;
  static readonly dockRadius: number = 32;
  static readonly dockBottomMargin: number = 20;
  /** 页面底部为悬浮栏留白（栏高 + 下边距 + 余量） */
  static readonly dockClearance: number = 96;
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
