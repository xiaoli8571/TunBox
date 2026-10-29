/**
 * 节点选择卡片 —— 视觉按《TunBox-UI重构笔记》§3.2 节点卡配方：
 * 纯白底 + 1vp 描边 + 圆角 16，选中态描边 1.5 品牌蓝 + 品牌浅底；延迟数字加粗。
 * 数据与回调（onSelect）逻辑不变。
 */
import { Ui, LatencyStyle } from '../theme/UiTokens';
import { ProxyNode } from '../commons/models/ProxyNode';
import { NodeCountryPolicy } from '../commons/services/PublicIpService';
import { CountryFlagIcon } from './CountryFlagIcon';

@Component
export struct NodeCard {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @Prop node: ProxyNode | null = null;
  @Prop darkMode: boolean = true;
  @Prop selected: boolean = false;
  @Prop latencyMs: number = -2; // -2 未测试, -1 失败
  onSelect: (node: ProxyNode) => void = () => {};

  private latencyText(): string {
    if (this.latencyMs === -2) {
      return '—';
    }
    if (this.latencyMs === -1) {
      return '超时';
    }
    return `${this.latencyMs}ms`;
  }

  private latencyColor(): ResourceColor {
    if (this.latencyMs === -2) return Ui.textTertiary;
    if (this.latencyMs === -1) return Ui.error;
    return LatencyStyle.color(this.latencyMs);
  }

  build() {
    if (this.node !== null) {
      Row({ space: 12 }) {
        CountryFlagIcon({ nodeName: this.node.name, iconSize: 20 })
        Column({ space: 2 }) {
          Text(NodeCountryPolicy.displayName(this.node.name))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.selected ? Ui.primary : Ui.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${this.node.server}:${this.node.port}`)
            .fontSize(11)
            .fontColor(Ui.textTertiary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.latencyText())
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.latencyColor())

        if (this.selected) {
          Image($r('app.media.ic_check'))
            .width(16).height(16)
            .fillColor(Ui.primary)
        }
      }
      .width('100%')
      .padding(14)
      .borderRadius(16)
      .backgroundColor(this.selected ? Ui.selectedBackground(this.themeRevision) : Ui.surface(this.themeRevision))
      .borderWidth(this.selected ? 1.5 : 1)
      .borderColor(this.selected ? Ui.primary : Ui.glassEdge(this.themeRevision))
      .onClick(() => {
        if (this.node !== null) {
          this.onSelect(this.node);
        }
      })
    }
  }
}
