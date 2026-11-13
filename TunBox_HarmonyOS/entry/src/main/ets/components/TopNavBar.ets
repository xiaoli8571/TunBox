/**
 * 顶部导航栏 —— 严格对齐《TunBox-UI重构笔记》§2.1 TopNavBar
 *
 * 结构：可选返回按钮 + 20fp Bold 标题 + Blank + 右侧操作区（36vp 圆形按钮）。
 * 背板：覆盖状态栏的背景玻璃，下缘用 32vp 平滑衰减，避免矩形模糊产生硬边。
 *
 * 相对文档的两处扩展（不改变文档形态，只为承载既有功能）：
 *  - rightSlot：@BuilderParam 扩展槽，供首页放「备份 / 主题切换」等既有入口；
 *  - onBack 缺省时回退 router.back()，与文档 onBack?: () => void 一致。
 */
import { router } from '@kit.ArkUI';
import { TunBoxColors, TunBoxGeometry, TunBoxMotion } from '../theme/TunBoxTokens';
import { ThemeService } from '../theme/ThemeService';
import { TunBoxTextColors } from '../theme/TextColors';
import { SafeArea } from '../theme/SafeArea';

@Component
export struct TopNavBar {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @StorageProp('tb_inset_top') insetTop: number = 0;
  @StorageProp('tb_avoid_active') avoidActive: boolean = false;
  title: string = '';
  hasBack: boolean = false;
  onBack?: () => void;
  rightIcon?: Resource;
  onRightClick?: () => void;
  @BuilderParam rightSlot: () => void = this.emptyRight;
  /**
   * 顶栏只有一层**连续的淡染色**，自己不做任何背景模糊。
   *
   * 历史（2026-10-30 ~ 10-31，十五轮）：
   *  · 把背景切成横带、逐条 `backgroundEffect` → 每条各自取样，拼缝就是马赛克，调参救不回来；
   *  · 换成对滚动内容用官方 `linearGradientBlur` → 列表静止时首项也落进模糊区
   *    （用户报「点订阅后第一个节点变模糊了」），已整体撤掉。
   * 现在内容滚到顶栏下方时的柔化由各页滚动容器的 `fadingEdge`
   * （`TunBoxGeometry.scrollFadeEdge`）负责：边缘渐隐，没有接缝，也不会糊到静止内容。
   * 门禁 `verify-bottom-dock-immersive` 锁着「顶栏与三张页签页不得再出现 linearGradientBlur」。
   */
  private static readonly TINT_TOP_LIGHT: number = 0.20;
  private static readonly TINT_TOP_DARK: number = 0.12;

  /**
   * 染色 alpha 曲线：`A0 · (1 − smoothstep(t))`，t = 纵向位置 0..1。
   *
   * smoothstep 让**两端斜率都趋近 0**：顶部与状态栏同色无缝，底部与页面同色无缝，
   * 落差均匀摊在整条顶栏上，眼睛读不到「一条边」。
   */
  private tintAt(t: number): ResourceColor {
    const s: number = t * t * (3 - 2 * t);
    const a: number = (ThemeService.isDark() ? TopNavBar.TINT_TOP_DARK : TopNavBar.TINT_TOP_LIGHT) * (1 - s);
    return ThemeService.isDark() ? `rgba(24, 32, 48, ${a})` : `rgba(255, 255, 255, ${a})`;
  }

  private tintStops(): Array<[ResourceColor, number]> {
    const stops: number[] = [0, 0.2, 0.4, 0.6, 0.8, 1];
    const out: Array<[ResourceColor, number]> = [];
    for (let i = 0; i < stops.length; i++) {
      out.push([this.tintAt(stops[i]), stops[i]]);
    }
    return out;
  }

  @Builder
  emptyRight() {
  }

  private handleBack(): void {
    const cb = this.onBack;
    if (cb !== undefined) {
      cb();
      return;
    }
    router.back();
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      // ── 染色：一整条连续渐变，两端斜率都归零（见 tintAt 的注释），终点 alpha = 0 ──
      // 越往顶越白，到顶栏下沿归零；顶栏自己不做背景模糊（原因见上方类注释）。
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({ angle: 180, colors: this.tintStops() })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')

      Row() {
      if (this.hasBack) {
        Button() {
          Image($r('app.media.ic_arrow_left'))
            .width(22).height(24)
            .fillColor(TunBoxColors.textPrimaryFor(this.themeRevision))
        }
        .type(ButtonType.Normal)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .width(36).height(36)
        .accessibilityText('返回')
        .clickEffect(TunBoxMotion.pressControl())
        .onClick(() => this.handleBack())
      }
      Text(this.title)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
        .margin({ left: this.hasBack ? 8 : 0 })
        // 2026-10-19 防溢出：标题与右侧操作区共存时，标题过长不得撑破导航条。
        // 用 layoutWeight(1) 让标题占用剩余空间并可被压缩（原 Blank() 与权重
        // 会争抢空间，故移除 Blank，标题自身即充当弹性占位）。
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      // 右侧操作区（文档：Row({ space: 12 })；扩展槽优先，供既有功能入口使用）
      Row({ space: 12 }) {
        this.rightSlot()
        if (this.rightIcon !== undefined) {
          Button() {
            Image(this.rightIcon)
              .width(22).height(22)
              .fillColor(TunBoxColors.textPrimaryFor(this.themeRevision))
          }
          .type(ButtonType.Circle)
          .backgroundColor(TunBoxColors.chipBg(this.themeRevision))
          .width(36).height(36)
          .onClick(() => {
            const cb = this.onRightClick;
            if (cb !== undefined) {
              cb();
            }
          })
        }
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    // 2026-10-30 二修：顶栏从「实底一条」变成**浮层玻璃**。
    //  · 状态栏那段让白改用 padding（margin 只挪布局、画不到背景，玻璃就盖不住状态栏区）；
    //  · 高度 = 行高 + 让白，padding 让出同样的量，标题仍竖居中在 56vp 行里；
    //  · 顶栏只有淡染色、没有实底：内容滚过去时靠滚动容器的 fadingEdge 渐隐，
    //    而不是「被一块板完全遮挡」（用户 2026-10-30 两条反馈）。
    .height(TunBoxGeometry.navHeight + (this.avoidActive ? 0 : Math.max(0, this.insetTop - 12)))
    .padding({
      left: TunBoxGeometry.pagePadding,
      right: TunBoxGeometry.pagePadding,
      top: this.avoidActive ? 0 : Math.max(0, this.insetTop - 12)
    })
    .background(Color.Transparent)
    }
    .width('100%')
    .height(TunBoxGeometry.navHeight + (this.avoidActive ? 0 : Math.max(0, this.insetTop - 12)))
  }
}
