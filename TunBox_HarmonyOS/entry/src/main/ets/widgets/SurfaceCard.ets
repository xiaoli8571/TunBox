/**
 * TunBoxSurfaceCard 等价物 —— 2026-10-17 按《TunBox-UI重构笔记》§1.3 改为白底卡片配方：
 * 纯白底 + 1vp 浅色描边(#E5EDF8) + 大圆角，无玻璃、无阴影（文档卡片靠描边区分层次）。
 * 深色底由同名 dark 资源解析（#16223A / #24344F），无需分支代码。
 * 对外属性名保持不变（radius/paddingV/paddingH/bgColor/edgeColor/content），未重构的页面照旧可用。
 */
import { Ui } from '../theme/UiTokens';

@Component
export struct SurfaceCard {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @Prop radius: number = 22;
  @Prop paddingV: number = 16;
  @Prop paddingH: number = 16;
  @Prop bgColor: ResourceColor = Ui.surface(-1);
  @Prop edgeColor: ResourceColor = Ui.glassEdge(-1);
  @BuilderParam content: () => void = this.empty;

  @Builder
  empty() {
  }

  build() {
    Column() {
      Column() {
        this.content()
      }
      .width('100%')
    }
    .padding({ top: this.paddingV, bottom: this.paddingV, left: this.paddingH, right: this.paddingH })
    .borderRadius(this.radius)
    .backgroundColor(this.bgColor)
    .borderWidth(1)
    .borderColor(this.edgeColor)
  }
}
