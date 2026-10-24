import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { window } from '@kit.ArkUI';

const PREF_NAME = 'tunbox_theme';
const KEY_THEME_MODE = 'theme_mode';

export enum AppThemeMode {
  SYSTEM = 'system',
  LIGHT = 'light',
  DARK = 'dark'
}

/**
 * 应用级主题服务。
 * 未手动选择时使用 COLOR_MODE_NOT_SET 跟随系统；手动选择后持久化 LIGHT/DARK。
 */
export class ThemeService {
  private static context: common.UIAbilityContext | null = null;
  private static store: preferences.Preferences | null = null;
  private static mode: AppThemeMode = AppThemeMode.SYSTEM;

  static async init(context: common.UIAbilityContext): Promise<AppThemeMode> {
    ThemeService.context = context;
    ThemeService.store = await preferences.getPreferences(context, { name: PREF_NAME });
    const saved = await ThemeService.store.get(KEY_THEME_MODE, AppThemeMode.SYSTEM) as string;
    ThemeService.mode = ThemeService.parseMode(saved);
    ThemeService.applyColorMode(ThemeService.mode);
    AppStorage.setOrCreate('theme_mode', ThemeService.mode);
    AppStorage.setOrCreate('theme_revision', 0);
    return ThemeService.mode;
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
    return ThemeService.context?.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  /** 主页太阳按钮在明确的 LIGHT 与 DARK 之间切换。 */
  static async toggle(): Promise<AppThemeMode> {
    const next = ThemeService.isDark() ? AppThemeMode.LIGHT : AppThemeMode.DARK;
    await ThemeService.setMode(next);
    return next;
  }

  static async setMode(mode: AppThemeMode): Promise<void> {
    ThemeService.mode = mode;
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
    const pageBg = dark ? '#0B1220' : '#F4F6FB';
    const bottomBg = dark ? '#0F131D' : '#EBF1FD';
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
