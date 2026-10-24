/**
 * TunBox 2x2 桌面服务卡片。
 * 使用结构化 BindingData 展示真实状态、当前节点和动态操作；忙碌时禁用重复点击。
 */
let storage = new LocalStorage();

@Entry(storage)
@Component
struct ToggleCard {
  @LocalStorageProp('stateCode') stateCode: string = 'disconnected';
  @LocalStorageProp('stateLabel') stateLabel: string = '未连接';
  @LocalStorageProp('nodeName') nodeName: string = '未选择节点';
  @LocalStorageProp('actionLabel') actionLabel: string = '连接';
  @LocalStorageProp('busy') busy: boolean = false;
  @LocalStorageProp('accessibilityLabel') accessibilityLabel: string = 'TunBox，未连接，未选择节点，连接';

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

  private sendAction(): void {
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
    // 真机取证(2026-09-18)：message 通道在 Form 宿主进程内执行连接，宿主被回收后
    // :vpn 连带被杀。改走 router 通道直达 QuickToggleAbility（无界面 UIAbility），
    // 连接成功后由该能力注册 dataTransfer 连续任务守护会话。
    postCardAction(this, {
      'action': 'router',
      'abilityName': 'QuickToggleAbility',
      'params': { 'vpn_shortcut': 'toggle' }
    });
  }

  build() {
    Column({ space: 7 }) {
      Row({ space: 6 }) {
        Text($r('app.string.app_name'))
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.form_text_primary'))
          .layoutWeight(1)
          .maxLines(1)
        Circle({ width: 9, height: 9 })
          .fill(this.statusColor())
          .accessibilityDescription(this.stateLabel)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.stateLabel)
        .width('100%')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.statusColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Row({ space: 5 }) {
        Text($r('app.string.form_current_node'))
          .fontSize(11)
          .fontColor($r('app.color.form_text_secondary'))
        Text(this.nodeName)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.form_text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

      Button(this.actionLabel)
        .width('100%')
        .height(34)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.form_button_text'))
        .backgroundColor(this.busy ? $r('app.color.form_button_disabled') : $r('app.color.form_button_background'))
        .borderRadius(12)
        .enabled(!this.busy)
        .accessibilityDescription(this.accessibilityLabel)
        .onClick(() => {
          this.sendAction();
        })
    }
    .width('100%')
    .height('100%')
    .padding(14)
    .justifyContent(FlexAlign.SpaceBetween)
    .backgroundColor($r('app.color.form_background'))
    // Form 卡片不支持 backgroundEffect / ThemeColorMode。
    // 使用半透明语义颜色、玻璃描边和柔和阴影保留同一视觉语言。
    .borderWidth(1)
    .borderColor($r('app.color.ui_glass_edge'))
    .shadow({ radius: 24, color: $r('app.color.ui_shadow'), offsetX: 0, offsetY: 10 })
    .borderRadius(16)
    .accessibilityDescription(this.accessibilityLabel)
  }
}
