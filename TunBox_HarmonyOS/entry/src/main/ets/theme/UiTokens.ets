/**
 * TunBox UI Tokens — 1:1 对齐 upstream packages/tunbox_shared/lib/widgets/tunbox_app_surface.dart
 * 这是真实安卓版使用的现代色板（app_theme.dart 为旧版兼容色，勿再使用）。
 */
import { LatencyRecord, LatencyState, LatencyPolicy } from '../commons/services/LatencyState';
import { LatencyStore, LatencyViewLevel } from '../commons/latency/LatencyStore';
import { AppBgTheme, ThemeService } from './ThemeService';

/** 随系统深浅模式自动解析的语义设计令牌。 */
export class Ui {
  static readonly background: ResourceColor = $r('app.color.ui_background');
  static readonly backgroundRaised: ResourceColor = $r('app.color.ui_background_raised');
  /** 主页三张信息磁贴专用底色/渐变：深色主题下更实、去白纱，避免「透白」不协调 */
  static readonly tileFill: ResourceColor = $r('app.color.ui_tile_fill');
  static readonly tileGloss: ResourceColor = $r('app.color.ui_tile_gloss');
  static readonly tileDeep: ResourceColor = $r('app.color.ui_tile_deep');
  static readonly glassHighlight: ResourceColor = $r('app.color.ui_glass_highlight');
  static readonly glassHighlightSoft: ResourceColor = $r('app.color.ui_glass_highlight_soft');
  static readonly glassGlow: ResourceColor = $r('app.color.ui_glass_glow');
  static readonly primary: ResourceColor = $r('app.color.ui_primary');
  static readonly primaryBlue: ResourceColor = $r('app.color.ui_primary_blue');
  static readonly primaryBlueFill: ResourceColor = $r('app.color.ui_primary_blue_fill');
  static readonly accent: ResourceColor = $r('app.color.ui_accent');
  static readonly success: ResourceColor = $r('app.color.ui_success');
  static readonly warning: ResourceColor = $r('app.color.ui_warning');
  static readonly error: ResourceColor = $r('app.color.ui_error');
  static readonly textPrimary: ResourceColor = $r('app.color.ui_text_primary');
  static readonly textSecondary: ResourceColor = $r('app.color.ui_text_secondary');
  static readonly textTertiary: ResourceColor = $r('app.color.ui_text_tertiary');
  static readonly textOnBrand: ResourceColor = $r('app.color.ui_text_on_brand');
  static readonly textBlue: ResourceColor = $r('app.color.ui_text_blue');
  static readonly textError: ResourceColor = $r('app.color.ui_text_error');
  static readonly textViolet: ResourceColor = $r('app.color.ui_text_violet');
  static readonly border: ResourceColor = $r('app.color.ui_border');
  static readonly borderStrong: ResourceColor = $r('app.color.ui_border_strong');
  static readonly buttonDisabled: ResourceColor = $r('app.color.ui_button_disabled');
  static readonly overlay: ResourceColor = $r('app.color.ui_overlay');
  static readonly shadow: ResourceColor = $r('app.color.ui_shadow');
  static readonly navBackground: ResourceColor = $r('app.color.ui_nav_background');
  static readonly statusTint: ResourceColor = $r('app.color.ui_status_tint');
  static readonly powerGlowActive: ResourceColor = $r('app.color.ui_power_glow_active');
  static readonly powerGlowIdle: ResourceColor = $r('app.color.ui_power_glow_idle');
  static readonly powerRingActive: ResourceColor = $r('app.color.ui_power_ring_active');
  static readonly powerRingIdle: ResourceColor = $r('app.color.ui_power_ring_idle');
  static readonly powerInnerActive: ResourceColor = $r('app.color.ui_power_inner_active');
  static readonly powerInnerIdle: ResourceColor = $r('app.color.ui_power_inner_idle');

  // ── 随浅色背景配色派生的表面色（2026-10-28 用户要求「卡片/表面要跟着背景配色走，别是死白」）──
  //
  // 下面七个表面类令牌从 `static readonly` 改成**带 rev 参数的方法**。原因同 TunBoxTokens：
  // ArkUI V1 的 @StorageLink 依赖按**元素**登记，只有元素属性表达式里真的读到
  // `this.themeRevision`，该元素才会在修订号变化时重绘（真机像素取证，`.pi-captures`）。
  //
  // 取值口径：深色 / 默认蓝灰配色 → 原资源值（设计与 AGC 已验收，不动）；
  // 只有 Mint / Homebrew / Noctis 三套彩色浅色背景才用背景终点色向白混合出同色系表面色。

  private static hex2(v: number): string {
    const s = Math.round(v).toString(16);
    return s.length === 1 ? `0${s}` : s;
  }

  /** `#RRGGBB` 向白混合：t=0 原色，t=1 纯白 */
  private static mixToWhite(hex: string, t: number): string {
    const r = parseInt(hex.substring(1, 3), 16);
    const g = parseInt(hex.substring(3, 5), 16);
    const b = parseInt(hex.substring(5, 7), 16);
    return `#${Ui.hex2(r + (255 - r) * t)}${Ui.hex2(g + (255 - g) * t)}${Ui.hex2(b + (255 - b) * t)}`;
  }

  /** rev<0（退化调用）或深色/默认配色时走原资源值，否则从配色终点色派生 */
  private static tinted(whiteMix: number, fallback: ResourceColor, rev: number): ResourceColor {
    if (rev < 0 || ThemeService.isDark() || ThemeService.currentBgTheme() === AppBgTheme.DEFAULT) {
      return fallback;
    }
    return Ui.mixToWhite(ThemeService.bgColors().end, whiteMix);
  }

  /** 卡片/面板底色（原 ui_surface） */
  static surface(rev: number): ResourceColor {
    return Ui.tinted(0.62, $r('app.color.ui_surface'), rev);
  }

  /** 强调表面（原 ui_surface_strong） */
  static surfaceStrong(rev: number): ResourceColor {
    return Ui.tinted(0.80, $r('app.color.ui_surface_strong'), rev);
  }

  /** 半透表面（原 ui_surface_translucent） */
  static surfaceTranslucent(rev: number): ResourceColor {
    return Ui.tinted(0.55, $r('app.color.ui_surface_translucent'), rev);
  }

  /** 凹槽/次级底（原 ui_surface_muted） */
  static surfaceMuted(rev: number): ResourceColor {
    return Ui.tinted(0.30, $r('app.color.ui_surface_muted'), rev);
  }

  /** 输入框底（原 ui_input_background） */
  static inputBackground(rev: number): ResourceColor {
    return Ui.tinted(0.88, $r('app.color.ui_input_background'), rev);
  }

  /** 微光描边（原 ui_glass_edge） */
  static glassEdge(rev: number): ResourceColor {
    return Ui.tinted(0.22, $r('app.color.ui_glass_edge'), rev);
  }

  /** 选中态底（原 ui_selected_background） */
  static selectedBackground(rev: number): ResourceColor {
    return Ui.tinted(0.50, $r('app.color.ui_selected_background'), rev);
  }

  static readonly pagePadding: number = 20;
  static readonly cardRadius: number = 24;
  static readonly dialogRadius: number = 28;
  static readonly controlRadius: number = 14;
  static readonly glassBlurRadius: number = 28;
  /** 全局液态玻璃光学参数，避免各页面出现不同的雾化、亮度和景深。 */
  static readonly glassSaturation: number = 1.26;
  static readonly glassBrightness: number = 1.06;
  /** 次级卡片与浮层使用的轻量液态玻璃参数。 */
  static readonly glassSaturationSoft: number = 1.20;
  static readonly glassBrightnessSoft: number = 1.04;
  static readonly glassControlBlurRadius: number = 18;
  static readonly glassControlSaturation: number = 1.12;
  static readonly glassControlBrightness: number = 1.03;
  static readonly glassShadowRadius: number = 30;
  static readonly glassShadowOffsetY: number = 14;
  static readonly glassPressScale: number = 0.985;
  static readonly compactBreakpoint: number = 460;
  static readonly pageMaxWidth: number = 440;
  static readonly bottomNavMaxWidth: number = 380;
  static readonly currentNodeMaxWidth: number = 320;

  /** 背景渐变由 base/dark 同名资源自动切换。 */
  static readonly backdropColors: Array<[ResourceColor, number]> = [
    [$r('app.color.ui_backdrop_start'), 0.0],
    [$r('app.color.ui_backdrop_middle'), 0.48],
    [$r('app.color.ui_backdrop_end'), 1.0]
  ];
}

/** 延迟配色与文案（对齐 tunbox_node_selection_node_card / current_node_card 阈值） */
export class LatencyStyle {
  static readonly TIMEOUT_MS: number = 65535;

  static isTimeout(latency: number | null): boolean {
    return latency !== null && (latency <= 0 || latency >= LatencyStyle.TIMEOUT_MS);
  }

  static color(latency: number | null): ResourceColor {
    if (latency === null) {
      return Ui.textSecondary;
    }
    if (LatencyStyle.isTimeout(latency)) {
      return Ui.error;
    }
    if (latency < 300) {
      return Ui.success;
    }
    if (latency < 800) {
      return Ui.warning;
    }
    return Ui.error;
  }

  static text(latency: number | null): string {
    if (latency === null) {
      return '--';
    }
    if (LatencyStyle.isTimeout(latency)) {
      return '超时';
    }
    return `${latency}ms`;
  }

  /**
   * 状态化文案：五态必须可区分（旧实现把「没测过 / 失败 / 超时」一律画成
   * 「超时」，是"很难用"的主要来源之一）。
   * 离线粗略探测带 ≈ 前缀，绝不与真实代理延迟混淆。
   *
   * ⚠ 2026-10-18 用户裁定：**失败一律显示「超时/失败」，不再有「未测」这一档**。
   * 旧实现把 `source === 'auto'`（冷启动 / 进页面 / 导入订阅后的静默批）的失败
   * 显示成中性「未测」，真机表现为「导入订阅后一大片未测」，用户明确要求
   * 「要么显示延迟多少、要么显示超时」——已测出结论却显示成没测过，反而误导。
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
    // 上一轮（冷启动从快照恢复）的失败结论 → 标「·旧」并灰显，
    // 2026-10-20 真机反馈「刚打开软件还没测速就显示超时，测完发现节点是好的」。
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
   * 状态化配色：实测走既有阈值；过期结果与测试中为中性色；失败一律红。
   *
   * 例外：「节点未生效」（内核代理表里没有它 = 节点没进配置）用警告色 —— 红=「节点坏了」，
   * 但这种情况节点可能是好的、只是配置生成把它丢了（真机 2026-10-19：36 个 anytls
   * 被丢弃 → 内核 404 → UI 全红，节点实际可用）。
   */
  static recordColor(rec: LatencyRecord | null, nowMs: number): ResourceColor {
    if (rec === null) {
      return Ui.textSecondary;
    }
    if (rec.hasValue()) {
      if (LatencyPolicy.isStale(rec, nowMs)) {
        return Ui.textSecondary;
      }
      return LatencyStyle.color(rec.delayMs);
    }
    // 结论的**级别**（严重程度）同样归真源：describe().level
    // WARN = 「未生效」（内核表里没有它 = 配置把它丢了，节点可能是好的）→ 警告色；
    // BAD  = 真失败 → 红色。
    const view = LatencyStore.describe(rec.failKind, rec.delayMs, rec.atMs, nowMs);
    if (view.level === LatencyViewLevel.WARN) {
      return Ui.warning;
    }
    if (view.level === LatencyViewLevel.BAD) {
      // 陈旧的失败结论（上一轮的）→ 中性灰，不顶红字（与 recordText 同口径）
      if (LatencyPolicy.isStaleConclusion(rec, nowMs)) {
        return Ui.textSecondary;
      }
      return Ui.error;
    }
    // UNTESTED / TESTING / CANCELLED：中性，不吓唬用户
    return Ui.textSecondary;
  }
}

/** 节点显示规整（对齐 node_display_policy.dart） */
export class NodeDisplay {
  /** 去掉开头的国旗 emoji（upstream nodeDisplayNameWithoutLeadingFlag） */
  static withoutLeadingFlag(name: string): string {
    let out = name;
    // 移除开头的 regional-indicator emoji 对与其余前导旗帜符号
    while (out.length > 0) {
      const cp = out.codePointAt(0);
      if (cp === undefined) {
        break;
      }
      const isFlag = (cp >= 0x1F1E6 && cp <= 0x1F1FF) || cp === 0x1F3F3 || cp === 0xFE0F || cp === 0x200D;
      if (!isFlag) {
        break;
      }
      out = out.substring(String.fromCodePoint(cp).length);
    }
    return out.trimStart();
  }

  /** 截断过长的节点名（upstream compactNodeDisplayName：约 24 字符 + …） */
  static compact(name: string): string {
    if (name.length <= 24) {
      return name;
    }
    return `${name.substring(0, 23)}…`;
  }
}
