/**
 * 订阅卡片 —— 视觉按《TunBox-UI重构笔记》§1.3 卡片配方（纯白底 + 1vp #E5EDF8 描边 + 圆角 18），
 * 动作按钮改文档的圆角胶囊（弱化底 / 圆角 10）。刷新·编辑·删除回调逻辑不变。
 */
import { Ui } from '../theme/UiTokens';
import { Subscription } from '../commons/models/Subscription';

@Component
export struct SubscriptionCard {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @Prop sub: Subscription | null = null;
  @Prop darkMode: boolean = true;
  @Prop active: boolean = false;
  onRefresh: (id: string) => void = () => {};
  onEdit: (id: string) => void = () => {};
  onDelete: (id: string) => void = () => {};

  private subId(): string {
    return this.sub !== null ? this.sub.id : '';
  }

  build() {
    if (this.sub !== null) {
      Column({ space: 10 }) {
        Row({ space: 10 }) {
          Text(this.sub.name)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(Ui.textPrimary)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.active) {
            Text('当前')
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor(Ui.primary)
              .backgroundColor(Ui.primaryBlueFill)
              .borderRadius(100)
              .padding({ left: 10, right: 10, top: 3, bottom: 3 })
          }
        }
        .width('100%')

        Text(this.sub.url)
          .fontSize(12)
          .fontColor(Ui.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Row({ space: 8 }) {
          Text(`节点 ${this.sub.nodeCount}`)
            .fontSize(12)
            .fontColor(Ui.textSecondary)
          Blank()
          Text('刷新')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Ui.primary)
            .backgroundColor(Ui.surfaceMuted(this.themeRevision))
            .borderRadius(10)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .onClick(() => this.onRefresh(this.subId()))
          Text('编辑')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Ui.textSecondary)
            .backgroundColor(Ui.surfaceMuted(this.themeRevision))
            .borderRadius(10)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .onClick(() => this.onEdit(this.subId()))
          Text('删除')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Ui.error)
            .backgroundColor(Ui.surfaceMuted(this.themeRevision))
            .borderRadius(10)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .onClick(() => this.onDelete(this.subId()))
        }
        .width('100%')
      }
      .width('100%')
      .padding(16)
      .borderRadius(18)
      .backgroundColor(Ui.surface(this.themeRevision))
      .borderWidth(this.active ? 1.5 : 1)
      .borderColor(this.active ? Ui.primary : Ui.glassEdge(this.themeRevision))
    }
  }
}
