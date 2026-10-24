/**
 * TunBox 2x4 信息桌面服务卡片。
 * 展示 VPN 状态、当前节点、内存、实时上下行速率和缓存的公网 IP。
 * 公网 IP 仅在用户明确刷新、缓存过期的低频刷新或 VPN 切换成功后由服务端更新。
 */
let infoCardStorage = new LocalStorage();

@Entry(infoCardStorage)
@Component
struct InfoCard {
  @LocalStorageProp('stateCode') stateCode: string = 'disconnected';
  @LocalStorageProp('stateLabel') stateLabel: string = '未连接';
  @LocalStorageProp('nodeName') nodeName: string = '未选择节点';
  @LocalStorageProp('actionLabel') actionLabel: string = '连接';
  @LocalStorageProp('busy') busy: boolean = false;
  @LocalStorageProp('memoryText') memoryText: string = '--';
  @LocalStorageProp('publicIp') publicIp: string = '--';
  @LocalStorageProp('uploadSpeedText') uploadSpeedText: string = '0 B/s';
  @LocalStorageProp('downloadSpeedText') downloadSpeedText: string = '0 B/s';
  @LocalStorageProp('accessibilityLabel') accessibilityLabel: string = 'TunBox 信息卡片，未连接';

  private statusColor(): ResourceColor {
    if (this.stateCode === 'connected') {
      return $r('app.color.form_status_connected');
    }
    if (this.stateCode === 'connecting' || this.stateCode === 'disconnecting' || this.stateCode === 'recovering') {
      return $r('app.color.form_status_busy');
    }
    if (this.stateCode === 'failed') {
      return $r('app.color.form_status_failed');
    }
    return $r('app.color.form_status_idle');
  }

  private toggleVpn(): void {
    if (this.busy) {
      return;
    }
    if (this.stateCode === 'no_node') {
      postCardAction(this, {
        'action': 'router',
        'abilityName': 'EntryAbility',
        'params': { 'targetPage': 'pages/SubscriptionPage' }
      });
      return;
    }
    // 与 ToggleCard 同路径：router 直达无界面守护宿主，见 ToggleCard 注释。
    postCardAction(this, {
      'action': 'router',
      'abilityName': 'QuickToggleAbility',
      'params': { 'vpn_shortcut': 'toggle' }
    });
  }

  private refreshPublicIp(): void {
    if (this.busy) {
      return;
    }
    postCardAction(this, {
      'action': 'message',
      'params': { 'command': 'refresh_public_ip' }
    });
  }

  build() {
    Column({ space: 5 }) {
      Row({ space: 6 }) {
        Text($r('app.string.form_info_title'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.form_text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Circle({ width: 10, height: 10 })
          .fill(this.statusColor())
          .accessibilityDescription(this.stateLabel)
        Text(this.stateLabel)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.statusColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Column({ space: 5 }) {
        Row({ space: 8 }) {
          Text($r('app.string.form_current_node'))
            .width(72)
            .fontSize(12)
            .fontColor($r('app.color.form_text_secondary'))
          Text(this.nodeName)
            .layoutWeight(1)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.form_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')

        Row({ space: 8 }) {
          Row({ space: 4 }) {
            Text($r('app.string.form_memory_usage'))
              .fontSize(12)
              .fontColor($r('app.color.form_text_secondary'))
            Text(this.memoryText)
              .fontSize(13)
              .fontColor($r('app.color.form_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)
          Row({ space: 4 }) {
            Text($r('app.string.form_traffic_speed'))
              .fontSize(12)
              .fontColor($r('app.color.form_text_secondary'))
            Text(`↓ ${this.downloadSpeedText}`)
              .fontSize(13)
              .fontColor($r('app.color.form_download_speed'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`↑ ${this.uploadSpeedText}`)
              .fontSize(13)
              .fontColor($r('app.color.form_upload_speed'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .layoutWeight(2)
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row({ space: 8 }) {
          Text($r('app.string.form_public_ip'))
            .width(72)
            .fontSize(12)
            .fontColor($r('app.color.form_text_secondary'))
          Text(this.publicIp)
            .layoutWeight(1)
            .fontSize(13)
            .fontColor($r('app.color.form_text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Button($r('app.string.form_refresh'))
            .height(30)
            .fontSize(11)
            .fontColor($r('app.color.form_button_background'))
            .backgroundColor($r('app.color.form_refresh_background'))
            .borderRadius(10)
            .enabled(!this.busy)
            .accessibilityDescription($r('app.string.form_refresh_accessibility'))
            .onClick(() => {
              this.refreshPublicIp();
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ left: 10, right: 10, top: 7, bottom: 7 })
      .backgroundColor($r('app.color.form_panel_background'))
      .borderWidth(1)
      .borderColor($r('app.color.ui_glass_edge'))
      .borderRadius(14)

      Button(this.actionLabel)
        .width('100%')
        .height(36)
        .margin({ top: 5 })
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.form_button_text'))
        .backgroundColor(this.busy ? $r('app.color.form_button_disabled') : $r('app.color.form_button_background'))
        .borderRadius(12)
        .enabled(!this.busy)
        .accessibilityDescription(this.accessibilityLabel)
        .onClick(() => {
          this.toggleVpn();
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
    .justifyContent(FlexAlign.Start)
    .backgroundColor($r('app.color.form_background'))
    // Form 卡片不支持 backgroundEffect / ThemeColorMode。
    // 使用半透明语义颜色、玻璃描边和柔和阴影保留同一视觉语言。
    .borderWidth(1)
    .borderColor($r('app.color.ui_glass_edge'))
    .shadow({ radius: 24, color: $r('app.color.ui_shadow'), offsetX: 0, offsetY: 10 })
    .borderRadius(18)
    .accessibilityDescription(this.accessibilityLabel)
  }
}
