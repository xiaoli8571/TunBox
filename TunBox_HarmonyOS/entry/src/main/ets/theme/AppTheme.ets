/**
 * TunBox Premium Theme — HarmonyOS 版本
 * 移植自 upstream: TunBox_Android/lib/theme/app_theme.dart
 * 色值逐项照抄，不得改动。
 */
export class AppTheme {
  // ── 品牌色 ──
  static readonly primaryColor: string = '#2E64E6';
  static readonly primaryLight: string = '#5B8CFF';
  static readonly primaryDark: string = '#1E49D8';
  static readonly accentColor: string = '#14B8A6';

  // ── 状态色 ──
  static readonly successColor: string = '#18A957';
  static readonly successLight: string = '#34D399';
  static readonly successMuted: string = '#0E7A3E';
  static readonly warningColor: string = '#F59E0B';
  static readonly errorColor: string = '#F87171';

  // ── 暗色主题（默认） ──
  static readonly darkBg: string = '#08090B';
  static readonly darkSurface: string = '#101114';
  static readonly darkCard: string = '#15171B';
  static readonly darkCardHover: string = '#1C2026';
  static readonly darkBorder: string = '#2A2E36';
  static readonly darkBorderLight: string = '#3A414D';
  static readonly darkTextPrimary: string = '#F4F6F8';
  static readonly darkTextSecondary: string = '#A4ACB8';
  static readonly darkTextHint: string = '#8A94A6';

  // ── 亮色主题 ──
  static readonly lightBg: string = '#F4F6F8';
  static readonly lightSurface: string = '#FFFFFF';
  static readonly lightCard: string = '#FFFFFF';
  static readonly lightBorder: string = '#D8DEE8';
  static readonly lightTextPrimary: string = '#111827';
  static readonly lightTextSecondary: string = '#5F6B7A';
  static readonly lightTextHint: string = '#8A94A6';

  // 与 upstream 保持一致的旧别名（dark 为主）
  static readonly bg: string = AppTheme.darkBg;
  static readonly surface: string = AppTheme.darkSurface;
  static readonly card: string = AppTheme.darkCard;
  static readonly border: string = AppTheme.darkBorder;

  // ── 尺寸规格（照抄 upstream ThemeData） ──
  static readonly cardRadius: number = 16;
  static readonly inputRadius: number = 12;
  static readonly appBarTitleSize: number = 17;

  static isDark(darkMode: boolean): Palette {
    return darkMode ? new Palette(true) : new Palette(false);
  }
}

/** 语义化调色板：一次解析当前主题下的所有取色，等价于 upstream 的 darkTheme/lightTheme getter */
export class Palette {
  readonly dark: boolean;
  readonly bg: string;
  readonly surface: string;
  readonly card: string;
  readonly cardHover: string;
  readonly border: string;
  readonly borderLight: string;
  readonly textPrimary: string;
  readonly textSecondary: string;
  readonly textHint: string;

  constructor(dark: boolean) {
    this.dark = dark;
    if (dark) {
      this.bg = AppTheme.darkBg;
      this.surface = AppTheme.darkSurface;
      this.card = AppTheme.darkCard;
      this.cardHover = AppTheme.darkCardHover;
      this.border = AppTheme.darkBorder;
      this.borderLight = AppTheme.darkBorderLight;
      this.textPrimary = AppTheme.darkTextPrimary;
      this.textSecondary = AppTheme.darkTextSecondary;
      this.textHint = AppTheme.darkTextHint;
    } else {
      this.bg = AppTheme.lightBg;
      this.surface = AppTheme.lightSurface;
      this.card = AppTheme.lightCard;
      this.cardHover = AppTheme.lightSurface;
      this.border = AppTheme.lightBorder;
      this.borderLight = AppTheme.lightBorder;
      this.textPrimary = AppTheme.lightTextPrimary;
      this.textSecondary = AppTheme.lightTextSecondary;
      this.textHint = AppTheme.lightTextHint;
    }
  }

  get primary(): string {
    return AppTheme.primaryColor;
  }

  get accent(): string {
    return AppTheme.accentColor;
  }

  get success(): string {
    return AppTheme.successColor;
  }

  get warning(): string {
    return AppTheme.warningColor;
  }

  get error(): string {
    return AppTheme.errorColor;
  }
}
