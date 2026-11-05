import { TunBoxColors, TunBoxGeometry } from '../theme/TunBoxTokens';
import { ThemeService } from '../theme/ThemeService';

@Component
export struct FloatingQuickLaunchButton {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @StorageLink('mini_conn_connected') connected: boolean = false;
  @StorageLink('mini_conn_connecting') connecting: boolean = false;
  onToggle?: () => void = undefined;

  private requestToggle(): void {
    if (this.onToggle !== undefined) {
      this.onToggle();
    }
  }

  /** 每个形状的属性都显式读取修订号，连接中切主题也能单独重绘。 */
  private isDarkTheme(_revision: number): boolean {
    return ThemeService.isDark();
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 保留主页圆盘的深色玻璃质感：连接态只染一层浅绿，避免整块荧光绿。
      // 单独用 Circle 填色，保留原玻璃层与圆形轮廓。
      Circle({ width: 50, height: 50 })
        .fill(this.connected
          ? (this.isDarkTheme(this.themeRevision) ? 'rgba(16, 185, 129, 0.18)' : 'rgba(0, 186, 102, 0.16)')
          : Color.Transparent)
        .stroke(this.connected && this.isDarkTheme(this.themeRevision) ? 'rgba(52, 211, 153, 0.28)' : Color.Transparent)
        .strokeWidth(1)
        .hitTestBehavior(HitTestMode.None)
      Image($r('app.media.ic_power'))
        .width(22)
        .height(22)
        .fillColor(this.connected
          ? (this.isDarkTheme(this.themeRevision) ? '#34D399' : TunBoxColors.success)
          : (this.connecting ? Color.Orange : TunBoxColors.primaryFor(this.themeRevision)))
    }
    .width(50)
    .height(50)
    .borderRadius(25)
    .backgroundEffect({
      radius: 22,
      saturation: ThemeService.isDark() ? 1.18 : 1.28,
      brightness: ThemeService.isDark() ? 0.98 : 1.0,
      color: TunBoxColors.dockGlassTint(this.themeRevision)
    })
    .linearGradient({
      angle: 180,
      colors: [[TunBoxColors.dockGradientTop(this.themeRevision), 0.0], [TunBoxColors.dockGradientBottom(this.themeRevision), 1.0]]
    })
    .border({ width: 1, color: TunBoxColors.dockEdge })
    .margin({ bottom: TunBoxGeometry.dockBottomMargin() })
    .translate({ y: TunBoxGeometry.dockSink() })
    .accessibilityText(this.connecting ? '取消连接' : (this.connected ? '断开代理' : '启动代理'))
    .onClick((): void => this.requestToggle())
  }
}
