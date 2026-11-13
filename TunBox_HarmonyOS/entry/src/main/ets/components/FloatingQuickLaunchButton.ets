/**
 * 快捷启动钮 —— 底栏右侧的圆形电源键（设置里打开「悬浮快捷启动」后出现）。
 *
 * 它和底栏并排，必须是**同一块玻璃**：同一组模糊/饱和度（TunBoxGlass）、同一条染色渐变、
 * 同一道上沿镜面高光。2026-11-11 之前它只有模糊没有高光，放在底栏旁边像一枚塑料扣。
 *
 * 状态只用颜色说话：未连接=品牌蓝、连接中=警示橙、已连接=绿 + 一圈淡绿底。
 * 换色走 `TunBoxMotion.stateChange()` 过渡，不再硬切；按下由系统 clickEffect 给缩放回弹。
 */
import { TunBoxColors, TunBoxGeometry, TunBoxGlass, TunBoxMotion } from '../theme/TunBoxTokens';
import { ThemeService } from '../theme/ThemeService';

/** 圆钮直径（vp） */
const BUTTON_SIZE: number = 50;

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

  /** 电源图标颜色：已连接=绿 / 连接中=橙 / 其余=品牌蓝（门禁 verify-startup-feedback-runtime 直接执行本方法） */
  private powerColor(): ResourceColor {
    if (this.connected) {
      return this.isDarkTheme(this.themeRevision) ? '#34D399' : TunBoxColors.success;
    }
    return this.connecting ? TunBoxColors.warning : TunBoxColors.primaryFor(this.themeRevision);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 上沿镜面高光：与底栏同一组颜色、同样只占上沿 42%，终点是同色透明
      // （不能用 Color.Transparent，见 TunBoxColors.dockSheenClear 的注释）。
      Stack({ alignContent: Alignment.Top }) {
        Column()
          .width('100%')
          .height(BUTTON_SIZE * 0.42)
          .linearGradient({
            angle: 180,
            colors: [
              [TunBoxColors.dockSheenStrong(this.themeRevision), 0.0],
              [TunBoxColors.dockSheenSoft(this.themeRevision), 0.30],
              [TunBoxColors.dockSheenClear, 1.0]
            ]
          })
      }
      .width(BUTTON_SIZE)
      .height(BUTTON_SIZE)
      .borderRadius(BUTTON_SIZE / 2)
      .clip(true)
      .hitTestBehavior(HitTestMode.None)

      // 保留主页圆盘的深色玻璃质感：连接态只染一层浅绿，避免整块荧光绿。
      // 单独用 Circle 填色，保留原玻璃层与圆形轮廓。
      Circle({ width: BUTTON_SIZE, height: BUTTON_SIZE })
        .fill(this.connected
          ? (this.isDarkTheme(this.themeRevision) ? 'rgba(16, 185, 129, 0.18)' : 'rgba(0, 186, 102, 0.16)')
          : 'rgba(0, 186, 102, 0)')
        .stroke(this.connected && this.isDarkTheme(this.themeRevision)
          ? 'rgba(52, 211, 153, 0.28)' : 'rgba(52, 211, 153, 0)')
        .strokeWidth(1)
        .animation(TunBoxMotion.stateChange())
        .hitTestBehavior(HitTestMode.None)
      Image($r('app.media.ic_power'))
        .width(22)
        .height(22)
        .fillColor(this.powerColor())
        .animation(TunBoxMotion.stateChange())
    }
    .width(BUTTON_SIZE)
    .height(BUTTON_SIZE)
    .borderRadius(BUTTON_SIZE / 2)
    .backgroundEffect({
      radius: TunBoxGlass.BLUR_CONTROL,
      saturation: TunBoxGlass.saturation(this.themeRevision),
      brightness: TunBoxGlass.brightness(this.themeRevision),
      color: TunBoxColors.dockGlassTint(this.themeRevision)
    })
    .linearGradient({
      angle: 180,
      colors: [[TunBoxColors.dockGradientTop(this.themeRevision), 0.0], [TunBoxColors.dockGradientBottom(this.themeRevision), 1.0]]
    })
    .border({ width: 1, color: TunBoxColors.dockEdge })
    .clickEffect(TunBoxMotion.pressControl())
    .margin({ bottom: TunBoxGeometry.dockBottomMargin() })
    .translate({ y: TunBoxGeometry.dockSink() })
    .accessibilityText(this.connecting ? '取消连接' : (this.connected ? '断开代理' : '启动代理'))
    .onClick((): void => this.requestToggle())
  }
}
