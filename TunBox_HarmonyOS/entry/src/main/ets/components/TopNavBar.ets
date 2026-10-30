/**
 * 顶部导航栏 —— 严格对齐《TunBox-UI重构笔记》§2.1 TopNavBar
 *
 * 结构：可选返回按钮 + 20fp Bold 标题 + Blank + 右侧操作区（36vp 圆形按钮）。
 * 背板：无（2026-10-17 用户要求去掉顶部白色横条，与页面底色同色，不自绘背板）。
 *
 * 相对文档的两处扩展（不改变文档形态，只为承载既有功能）：
 *  - rightSlot：@BuilderParam 扩展槽，供首页放「备份 / 主题切换」等既有入口；
 *  - onBack 缺省时回退 router.back()，与文档 onBack?: () => void 一致。
 */
import { router } from '@kit.ArkUI';
import { TunBoxColors, TunBoxGeometry } from '../theme/TunBoxTokens';
import { TunBoxTextColors } from '../theme/TextColors';

@Component
export struct TopNavBar {
  @StorageLink('theme_revision') themeRevision: number = 0;
  title: string = '';
  hasBack: boolean = false;
  onBack?: () => void;
  rightIcon?: Resource;
  onRightClick?: () => void;
  @BuilderParam rightSlot: () => void = this.emptyRight;

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
    Row() {
      if (this.hasBack) {
        Button() {
          Image($r('app.media.ic_arrow_left'))
            .width(22).height(24)
            .fillColor(TunBoxColors.textPrimary)
        }
        .type(ButtonType.Normal)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .width(36).height(36)
        .accessibilityText('返回')
        .onClick(() => this.handleBack())
      }
      Text(this.title)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(TunBoxTextColors.primary)
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
              .fillColor(TunBoxColors.textPrimary)
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
    .height(TunBoxGeometry.navHeight)
    .padding({ left: TunBoxGeometry.pagePadding, right: TunBoxGeometry.pagePadding })
  }
}
