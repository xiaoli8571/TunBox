import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { window } from '@kit.ArkUI';

const PREF_NAME = 'tunbox_theme';
const KEY_THEME_MODE = 'theme_mode';
const KEY_BG_THEME = 'bg_theme';

export enum AppThemeMode {
  SYSTEM = 'system',
  LIGHT = 'light',
  DARK = 'dark'
}

/**
 * 浅色模式背景配色（2026-10-28 用户要求：浅色下可选 Mint / Homebrew / Noctis Hibernus）。
 *
 * 三套配色都只替换**背景渐变**（顶部 → 底部）与页面平色底，卡片/文字/主色一律不动：
 * 卡片是纯白面，任何一套背景下对比度都够；若连卡片一起换色，等于把「浅色主题」
 * 变成三套独立主题，收益低而回归面大。
 * 深色模式不受影响（深色只有一套已验证的夜间配色）。
 */
export enum AppBgTheme {
  DEFAULT = 'default',
  MINT = 'mint',
  HOMEBREW = 'homebrew',
  NOCTIS = 'noctis'
}

/** 一套浅色背景的两个端点（页面渐变起止 / 平色回退） */
export class BgThemeColors {
  /** 页面渐变起点（也是窗口底色、状态栏底色） */
  readonly start: string;
  /** 页面渐变终点（也是底部导航条底色、底栏渐隐底基色） */
  readonly end: string;

  constructor(start: string, end: string) {
    this.start = start;
    this.end = end;
  }
}

/**
 * 应用级主题服务。
 * 未手动选择时使用 COLOR_MODE_NOT_SET 跟随系统；手动选择后持久化 LIGHT/DARK。
 */
export class ThemeService {
  private static context: common.UIAbilityContext | null = null;
  private static store: preferences.Preferences | null = null;
  private static mode: AppThemeMode = AppThemeMode.SYSTEM;
  /**
   * 系统最近一次下发的深浅色（仅「跟随系统」时记录）。
   * 2026-10-28：`onConfigurationUpdate` 回调到达时 `context.config` 可能还没换好，
   * 以回调参数为权威值，避免用旧值刷错系统栏颜色。
   */
  private static systemColorMode: ConfigurationConstant.ColorMode =
    ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  /** 浅色模式背景配色（深色模式忽略，见 AppBgTheme 注释） */
  private static bgTheme: AppBgTheme = AppBgTheme.DEFAULT;

  static async init(context: common.UIAbilityContext): Promise<AppThemeMode> {
    ThemeService.context = context;
    ThemeService.store = await preferences.getPreferences(context, { name: PREF_NAME });
    const saved = await ThemeService.store.get(KEY_THEME_MODE, AppThemeMode.SYSTEM) as string;
    ThemeService.mode = ThemeService.parseMode(saved);
    const savedBg = await ThemeService.store.get(KEY_BG_THEME, AppBgTheme.DEFAULT) as string;
    ThemeService.bgTheme = ThemeService.parseBgTheme(savedBg);
    ThemeService.applyColorMode(ThemeService.mode);
    AppStorage.setOrCreate('theme_mode', ThemeService.mode);
    AppStorage.setOrCreate('bg_theme', ThemeService.bgTheme);
    AppStorage.setOrCreate('theme_revision', 0);
    return ThemeService.mode;
  }

  // ── 浅色背景配色（2026-10-28 用户要求）──

  static currentBgTheme(): AppBgTheme {
    return ThemeService.bgTheme;
  }

  /**
   * 取当前生效的背景两端色。
   * 深色模式恒返回深色那一套（bgTheme 只影响浅色），状态栏/窗口底色也走这里，
   * 保证「页面顶部色 == 状态栏色」的 AGC 要求在三套浅色配色下都成立。
   */
  static bgColors(): BgThemeColors {
    if (ThemeService.isDark()) {
      return new BgThemeColors('#0B1220', '#0F131D');
    }
    return ThemeService.previewBgColors(ThemeService.bgTheme);
  }

  /** 指定配色的两端色（不受当前深浅色影响）：设置页预览块用，选之前就能看到实际颜色。 */
  static previewBgColors(theme: AppBgTheme): BgThemeColors {
    if (theme === AppBgTheme.MINT) {
      // 薄荷：冷调青绿，饱和度压低到几乎中性，避免整屏发绿影响白卡对比
      return new BgThemeColors('#F1FAF6', '#E2F3EC');
    }
    if (theme === AppBgTheme.HOMEBREW) {
      // Homebrew：暖米色（终端/酿造桶的纸感），偏黄但保持明亮
      return new BgThemeColors('#FBF6ED', '#F3E8D6');
    }
    if (theme === AppBgTheme.NOCTIS) {
      // Noctis Hibernus：蓝紫冷调（原主题的冬季夜蓝在浅色下的对应），带一点灰紫
      return new BgThemeColors('#F3F4FC', '#E6E8F7');
    }
    return new BgThemeColors('#F4F6FB', '#EBF1FD');
  }

  static async setBgTheme(theme: AppBgTheme): Promise<void> {
    ThemeService.bgTheme = theme;
    AppStorage.setOrCreate('bg_theme', theme);
    const revision = (AppStorage.get<number>('theme_revision') ?? 0) + 1;
    AppStorage.setOrCreate('theme_revision', revision);
    const win = AppStorage.get<window.Window>('main_window');
    if (win !== undefined) {
      await ThemeService.syncSystemBars(win);
    }
    if (ThemeService.store !== null) {
      await ThemeService.store.put(KEY_BG_THEME, theme);
      await ThemeService.store.flush();
    }
  }

  private static parseBgTheme(value: string): AppBgTheme {
    if (value === AppBgTheme.MINT) {
      return AppBgTheme.MINT;
    }
    if (value === AppBgTheme.HOMEBREW) {
      return AppBgTheme.HOMEBREW;
    }
    if (value === AppBgTheme.NOCTIS) {
      return AppBgTheme.NOCTIS;
    }
    return AppBgTheme.DEFAULT;
  }

  static currentMode(): AppThemeMode {
    return ThemeService.mode;
  }

  static isDark(): boolean {
    if (ThemeService.mode === AppThemeMode.DARK) {
      return true;
    }
    if (ThemeService.mode === AppThemeMode.LIGHT) {
      return false;
    }
    if (ThemeService.systemColorMode !== ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET) {
      return ThemeService.systemColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    return ThemeService.context?.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  /**
   * 系统配置变化（EntryAbility.onConfigurationUpdate 转发，2026-10-28 用户报障）。
   *
   * 现象：「跟随系统」时系统切深浅色，App 内容跟着变了，但**状态栏 / 导航条不变**，
   * 必须重启 App 才恢复。
   * 根因：状态栏颜色与图标色是我们用 `setWindowSystemBarProperties` 写死的窗口属性，
   * 系统换配色不会替我们重刷；旧实现只在 `onWindowStageCreate` 里刷一次，
   * 之后没有任何人调它。
   *
   * 现在：跟随系统时把新配色记下、递增 `theme_revision`（所有 `@StorageLink` 组件重绘），
   * 并重刷一次窗口系统栏。手动指定浅/深色时不响应系统变化。
   */
  static async onSystemColorModeChanged(
    colorMode: ConfigurationConstant.ColorMode | undefined): Promise<void> {
    if (colorMode === undefined
      || colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET) {
      return;
    }
    if (ThemeService.mode !== AppThemeMode.SYSTEM) {
      return;
    }
    ThemeService.systemColorMode = colorMode;
    const revision = (AppStorage.get<number>('theme_revision') ?? 0) + 1;
    AppStorage.setOrCreate('theme_revision', revision);
    const win = AppStorage.get<window.Window>('main_window');
    if (win !== undefined) {
      await ThemeService.syncSystemBars(win);
    }
  }

  /** 主页太阳按钮在明确的 LIGHT 与 DARK 之间切换。 */
  static async toggle(): Promise<AppThemeMode> {
    const next = ThemeService.isDark() ? AppThemeMode.LIGHT : AppThemeMode.DARK;
    await ThemeService.setMode(next);
    return next;
  }

  static async setMode(mode: AppThemeMode): Promise<void> {
    ThemeService.mode = mode;
    if (mode === AppThemeMode.SYSTEM) {
      // 交还给系统：丢掉缓存值，让 isDark() 回落到 context.config
      // （下一次 onConfigurationUpdate 会写入真实值并重刷系统栏）。
      ThemeService.systemColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    }
    ThemeService.applyColorMode(mode);
    AppStorage.setOrCreate('theme_mode', mode);
    const revision = (AppStorage.get<number>('theme_revision') ?? 0) + 1;
    AppStorage.setOrCreate('theme_revision', revision);
    if (ThemeService.store !== null) {
      await ThemeService.store.put(KEY_THEME_MODE, mode);
      await ThemeService.store.flush();
    }
  }

  /**
   * 状态栏 / 底部导航条适配（华为 AGC 审核意见 2026-10-23）。
   *
   * 审核原文：「采用沉浸一体化的背景设计，避免状态栏区域被单独切割；根据页面内
   * 状态栏区域的背景色选择合适的状态栏颜色（黑/白）；避免左右半区对比差异过大」。
   *
   * 做法：
   *  1) 状态栏底色 = **页面背景色本身**（浅 #F4F6FB / 深 #0F131D），整条单一颜色，
   *     不再是透明让系统/窗口底色透出来的独立色条 —— 页面顶部与状态栏同色，
   *     视觉上是一个整体，也不会出现左右半区深浅不一（整条一个色）。
   *  2) 状态栏图标颜色跟随主题：浅色底用深色字 (#171B2A)，深色底用浅色字 (#F5F7FF)，
   *     保证时间/电量/SIM 图标在每个主题下都清晰可读。
   *  3) 底部导航条同色（页面底部渐变终点色），不出现底部白条。
   */
  static async syncSystemBars(win: window.Window): Promise<void> {
    const dark = ThemeService.isDark();
    // 深色底取 #0B1220：与 ui_background（平板/页面平色底）和渐变起点同值，
    // 状态栏、页面顶部、平色页三者同色，整条不会被切成独立色带。
    // 浅色：三套背景配色（AppBgTheme）各自取自己的起止色，状态栏随背景一起换，
    // 否则选了薄荷/暖米后状态栏还留着旧的蓝灰，顶上就断出一条色带。
    const palette = ThemeService.bgColors();
    const pageBg = palette.start;
    const bottomBg = palette.end;
    const contentColor = dark ? '#F5F7FF' : '#171B2A';
    // 窗口底色与页面同色：加载首帧/页面切换的缝隙也不会露出另一层颜色。
    win.setWindowBackgroundColor(pageBg);
    await win.setWindowSystemBarProperties({
      statusBarColor: pageBg,
      statusBarContentColor: contentColor,
      navigationBarColor: bottomBg,
      navigationBarContentColor: contentColor
    });
  }

  private static applyColorMode(mode: AppThemeMode): void {
    if (ThemeService.context === null) {
      return;
    }
    let colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (mode === AppThemeMode.LIGHT) {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (mode === AppThemeMode.DARK) {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    ThemeService.context.getApplicationContext().setColorMode(colorMode);
  }

  private static parseMode(value: string): AppThemeMode {
    if (value === AppThemeMode.LIGHT) {
      return AppThemeMode.LIGHT;
    }
    if (value === AppThemeMode.DARK) {
      return AppThemeMode.DARK;
    }
    return AppThemeMode.SYSTEM;
  }
}
