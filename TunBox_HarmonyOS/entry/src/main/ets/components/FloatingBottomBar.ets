/**
 * 底部悬浮导航栏 —— 严格对齐《TunBox-UI重构笔记》§2.2 FloatingBottomBar
 *
 * 几何：86% 宽 / 64 高 / 32 圆角 / 底部外边距 0（沉浸式贴手势区）。
 *  2026-10-26 用户要求「三个按钮间距稍微缩小一点点」：栏宽 92% → 86%
 *  （两侧各收 3%，三个页签整体向中间靠一点，页签间距随之略微变小）。
 *
 * 材质（2026-10-26 用户最终定稿「不折不扣的透明」）：**零渲染底**。
 * 栏体不再有任何可见像素——无着色填充、无 backdropBlur 模糊、无描边、无投影；
 * 只有三个页签项（图标 / 文字 / 选中胶囊 / 点击光晕）画在内容之上，背后内容
 * 1:1 透出。演进记录：backgroundBlurStyle 材质自带不透明蒙层 → backdropBlur(24)
 * 仍有磨砂白雾（在纯渐变页脚上读起来就是一条白胶囊，实测截图即为此现象）→ 全部移除。
 * 之所以不用 HdsTabs 的 systemMaterialEffect：IMMERSIVE/ADAPTIVE 本身就是磨砂材质
 * （做不到「完全透明」），MaterialType.NONE 才等价于无材质，而 HdsTabs 在 3 页签下
 * barFloatingStyle.barWidth 不生效（2026-10-26 dumpLayout 实测，见 docs/maintenance.md），
 * 自绘栏在「零材质」目标下视觉完全等价且不引入该回归。
 * 三项：主页(0) 订阅(1) 设置(2)；选中项=椭圆胶囊高亮（primaryLight 底 + primaryBorder 描边，
 * 图标与名称同一行、图标在前，2026-10-17 用户要求）；点击瞬间光亮：图标位置先满亮
 * dockGlow（瞬时上屏），50ms 后 280ms 扩散淡出、不常驻（2026-10-17 用户要求）。
 * 点击不直接写 currentTab：走 onSelect 回调交给宿主（MainPage 先落切页方向、下一帧再切页签，
 * 保证反向切页也有转场动画），未传回调时退化为直接写 currentTab。
 */
import { TunBoxColors, TunBoxGeometry } from '../theme/TunBoxTokens';
import { ThemeService } from '../theme/ThemeService';

interface DockTab {
  id: number;
  title: string;
  icon: Resource;
}

@Component
export struct FloatingBottomBar {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @Link currentTab: number;
  /** 点击回调（可选）：宿主据此控制切页签时机；不传则直接写 currentTab */
  onSelect?: (index: number) => void = undefined;
  /** 正在扩散光晕的项（-1 = 平静） */
  @State private rippleTab: number = -1;
  /** 光晕相位：false=刚点亮，true=已扩散并淡出 */
  @State private rippleSpread: boolean = false;
  private rippleTimer: number = -1;
  /** 淡出启动定时器：亮帧先直接上屏，隔 50ms 再启动淡出（同帧启动 animateTo 会把亮帧吞掉） */
  private rippleFadeTimer: number = -1;

  /** 点击瞬间光亮：tap 即满亮 → 50ms 后 280ms 扩散淡出，随后恢复平静 */
  private handleTap(index: number): void {
    if (this.rippleTimer >= 0) {
      clearTimeout(this.rippleTimer);
      this.rippleTimer = -1;
    }
    if (this.rippleFadeTimer >= 0) {
      clearTimeout(this.rippleFadeTimer);
      this.rippleFadeTimer = -1;
    }
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
    if (this.onSelect !== undefined) {
      this.onSelect(index);
    } else {
      this.currentTab = index;
    }
  }

  private tabs: DockTab[] = [
    { id: 0, title: '主页', icon: $r('app.media.ic_dashboard') },
    { id: 1, title: '数据', icon: $r('app.media.ic_chart') },
    { id: 2, title: '设置', icon: $r('app.media.ic_settings') }
  ];

  build() {
    Row() {
      ForEach(this.tabs, (item: DockTab) => {
        // 选中态：椭圆胶囊高亮，图标在前、名称在后同一行；点击时图标位置闪现瞬间光亮
        Row() {
          Stack({ alignContent: Alignment.Center }) {
            // 瞬间光亮层：dockGlow（深色 50% 亮蓝）tap 即满亮 → 280ms 扩散淡出
            Column()
              .width(56).height(56)
              .borderRadius(28)
              .backgroundColor(TunBoxColors.dockGlow)
              .opacity(this.rippleTab === item.id ? (this.rippleSpread ? 0 : 1) : 0)
              .scale({
                x: this.rippleTab === item.id && this.rippleSpread ? 1.55 : 0.75,
                y: this.rippleTab === item.id && this.rippleSpread ? 1.55 : 0.75
              })
            Row({ space: 6 }) {
              Image(item.icon)
                .width(21).height(21)
                .fillColor(this.currentTab === item.id ? TunBoxColors.primary : TunBoxColors.dockIconInactive)
              Text(item.title)
                .fontSize(12)
                .fontWeight(this.currentTab === item.id ? FontWeight.Medium : FontWeight.Regular)
                .fontColor(this.currentTab === item.id ? TunBoxColors.primary : TunBoxColors.dockIconInactive)
            }
            .alignItems(VerticalAlign.Center)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(TunBoxGeometry.pillRadius)
            .backgroundColor(this.currentTab === item.id ? TunBoxColors.primaryLight : Color.Transparent)
            .border({
              width: 1,
              color: this.currentTab === item.id ? TunBoxColors.primaryBorder : Color.Transparent
            })
            .animation({ duration: 220, curve: Curve.EaseOut })
          }
          .accessibilityText(item.title)
          .onClick(() => { this.handleTap(item.id); })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }, (item: DockTab) => `${item.id}`)
    }
    // 2026-10-26 用户要求「三个按钮间距稍微缩小一点点」：92% → 86%（页签向中间靠一点）
    .width('86%')
    .height(TunBoxGeometry.dockHeight)
    .borderRadius(TunBoxGeometry.dockRadius)
    // 保留内容透出感，只给 Dock 加一层极轻的半透明渐变底色，提升文字和图标在
    // 明暗内容上的可读性；不使用模糊、阴影或实心底色。
    .linearGradient({
      angle: 180,
      colors: ThemeService.isDark()
        ? [['rgba(15, 19, 29, 0.12)', 0.0], ['rgba(15, 19, 29, 0.24)', 1.0]]
        : [['rgba(255, 255, 255, 0.18)', 0.0], ['rgba(235, 241, 253, 0.30)', 1.0]]
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .margin({ bottom: TunBoxGeometry.dockBottomMargin })
  }
}
