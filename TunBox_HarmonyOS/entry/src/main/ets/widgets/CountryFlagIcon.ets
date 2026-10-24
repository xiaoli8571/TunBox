/**
 * 国家旗帜图标
 * 移植自 upstream: packages/tunbox_shared/lib/widgets/country_flag_icon.dart
 */
import { NodeCountryPolicy } from '../commons/services/PublicIpService';

@Component
export struct CountryFlagIcon {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @Prop nodeName: string = '';
  @Prop iconSize: number = 22;

  build() {
    Text(this.flag())
      .fontSize(this.iconSize)
      .width(this.iconSize + 4)
      .textAlign(TextAlign.Center)
  }

  private flag(): string {
    return NodeCountryPolicy.detect(this.nodeName).flagEmoji;
  }
}
