/**
 * 节点编辑页（手工添加/编辑节点）— 视觉对齐 upstream 新令牌（UiTokens）
 * 移植自 upstream: TunBox_Android/lib/screens/node_edit_screen.dart
 */
import { router, promptAction } from '@kit.ArkUI';
import { TunBoxColors, TunBoxMotion } from '../theme/TunBoxTokens';
import { util } from '@kit.ArkTS';
import { Ui } from '../theme/UiTokens';
import { ProxyNode, ProxyNodeType } from '../commons/models/ProxyNode';
import { ManualNodeStore } from '../commons/services/SubscriptionService';
import { SettingsService } from '../commons/services/SettingsService';

@Entry
@Component
struct NodeEditPage {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @State name: string = '';
  @State server: string = '';
  @State port: string = '';
  @State password: string = '';
  @State method: string = 'aes-256-cfb';
  @State protocol: string = 'origin';
  @State obfs: string = 'plain';
  @State rawImport: string = '';
  /** 端口跳跃（P2）：hysteria2 节点的 ports 区间/列表，如 1000-2000 或 1000,2000,3000 */
  @State portsHopping: string = '';
  onPageShow(): void {
    this.bootstrap();
  }

  private async bootstrap(): Promise<void> {
    const context = getContext(this) as Context;
    await SettingsService.init(context);
    await ManualNodeStore.init(context);
  }

  /** 从 ssr:// / ss:// 链接一键导入（对应 subscription_node_editor 的导入行为） */
  private importFromUri(): void {
    const node = ProxyNode.fromUri(this.rawImport.trim(), 'direct', util.generateRandomUUID());
    if (node === null) {
      promptAction.showToast({ message: '链接解析失败，请检查格式' });
      return;
    }
    this.name = node.name;
    this.server = node.server;
    this.port = `${node.port}`;
    this.password = node.password;
    this.method = node.method;
    this.protocol = node.protocol.length > 0 ? node.protocol : 'origin';
    this.obfs = node.obfs.length > 0 ? node.obfs : 'plain';
    this.portsHopping = this.readPortsOpt(node.extraOpts);
  }

  /** extraOpts JSON（对数组）里读 ports 键；空 extraOpts 返回 '' */
  private readPortsOpt(extraOpts: string): string {
    if (extraOpts.length === 0) {
      return '';
    }
    try {
      const pairs = JSON.parse(extraOpts) as string[][];
      for (const pair of pairs) {
        if (pair.length === 2 && pair[0] === 'ports') {
          return pair[1];
        }
      }
    } catch (e) {
      return '';
    }
    return '';
  }

  private async save(): Promise<void> {
    const portNum = parseInt(this.port);
    if (this.server.length === 0 || !(portNum > 0 && portNum < 65536)) {
      promptAction.showToast({ message: '服务器地址或端口无效' });
      return;
    }
    // 端口跳跃（P2）：只接受 数字、逗号、连字符 的组合（对齐 splitPortHopping 白名单）
    const hopping = this.portsHopping.trim();
    if (hopping.length > 0 && !/^[0-9,-]+$/.test(hopping)) {
      promptAction.showToast({ message: '端口跳跃格式无效（如 1000-2000 或 1000,2000,3000）' });
      return;
    }
    const node = new ProxyNode();
    node.id = util.generateRandomUUID();
    node.subscriptionId = 'direct';
    node.type = ProxyNodeType.SSR;
    node.name = this.name.length > 0 ? this.name : this.server;
    node.server = this.server.trim();
    node.port = portNum;
    node.password = this.password;
    node.method = this.method;
    node.protocol = this.protocol;
    node.protocolParam = '';
    node.obfs = this.obfs;
    node.obfsParam = '';
    // 端口跳跃写入 extraOpts 的 ports 键（生成配置时回写为 mihomo 的 ports 键）
    if (hopping.length > 0) {
      node.extraOpts = JSON.stringify([['ports', hopping]]);
    }
    const duplicate = ManualNodeStore.all().some((existing: ProxyNode) =>
      existing.server === node.server && existing.port === node.port && existing.type === node.type);
    if (duplicate) {
      promptAction.showToast({ message: '该节点已存在' });
      return;
    }
    await ManualNodeStore.addNode(node);
    promptAction.showToast({ message: '节点已保存' });
    router.back();
  }

  build() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .backgroundColor(TunBoxColors.background(this.themeRevision))
        // 背景延伸到状态栏/底部导航条之下, 消除底部白条
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        Row() {
          Row() {
            Image($r('app.media.ic_arrow_left'))
              .width(20).height(20)
              .fillColor(Ui.textPrimary)
          }
          .width(36).height(36)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .borderRadius(18)
          .backgroundColor(Ui.surfaceMuted(this.themeRevision))
            .onClick(() => router.back())
          Blank()
          Text('编辑节点')
            .fontSize(17).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
          Blank()
          Text('保存')
            .fontSize(15).fontColor(Ui.textBlue)
            .onClick(() => this.save())
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 10, bottom: 6 })

        Scroll() {
          Column({ space: 12 }) {
            Column({ space: 12 }) {
              Column({ space: 12 }) {
                Text('从链接导入').fontSize(13).fontColor(Ui.textTertiary)
                TextInput({ placeholder: '粘贴 ssr:// 或 ss:// 链接', text: this.rawImport })
                  .onChange((v: string) => { this.rawImport = v; })
                  .height(88)
                  .borderRadius(14)
                  .backgroundColor(Ui.inputBackground(this.themeRevision))
                  .borderWidth(1)
                  .borderWidth(1)
                  .borderColor(Ui.glassEdge(this.themeRevision))
                  .fontColor(Ui.textPrimary)
                  .placeholderColor(Ui.textTertiary)
                Button('解析并填充')
                  .width('100%')
                  .height(44)
                  .backgroundColor(Ui.inputBackground(this.themeRevision))
                  .borderWidth(1)
                  .borderWidth(1)
                  .borderColor(Ui.glassEdge(this.themeRevision))
                  .fontColor(Ui.textViolet)
                  .borderRadius(12)
                  .onClick(() => this.importFromUri())
              }
              .width('100%')
              .padding(18)
              .borderRadius(22)
              .backgroundColor(Ui.surface(this.themeRevision))
              .borderWidth(1)
              .borderWidth(1)
              .borderColor(Ui.glassEdge(this.themeRevision))
            }

            Column({ space: 12 }) {
              Column({ space: 12 }) {
                Text('节点信息').fontSize(13).fontColor(Ui.textTertiary)
                TextInput({ placeholder: '节点名称', text: this.name })
                  .onChange((v: string) => { this.name = v; })
                  .height(46).borderRadius(12).backgroundColor(Ui.inputBackground(this.themeRevision))
                  .borderWidth(1)
                  .borderWidth(1).borderColor(Ui.glassEdge(this.themeRevision)).fontColor(Ui.textPrimary).placeholderColor(Ui.textTertiary)
                TextInput({ placeholder: '服务器地址', text: this.server })
                  .onChange((v: string) => { this.server = v; })
                  .height(46).borderRadius(12).backgroundColor(Ui.inputBackground(this.themeRevision))
                  .borderWidth(1)
                  .borderWidth(1).borderColor(Ui.glassEdge(this.themeRevision)).fontColor(Ui.textPrimary).placeholderColor(Ui.textTertiary)
                TextInput({ placeholder: '端口', text: this.port })
                  .onChange((v: string) => { this.port = v; })
                  .height(46).borderRadius(12).backgroundColor(Ui.inputBackground(this.themeRevision))
                  .borderWidth(1)
                  .borderWidth(1).borderColor(Ui.glassEdge(this.themeRevision)).fontColor(Ui.textPrimary).placeholderColor(Ui.textTertiary)
                TextInput({ placeholder: '密码', text: this.password })
                  .onChange((v: string) => { this.password = v; })
                  .type(InputType.Password)
                  .height(46).borderRadius(12).backgroundColor(Ui.inputBackground(this.themeRevision))
                  .borderWidth(1)
                  .borderWidth(1).borderColor(Ui.glassEdge(this.themeRevision)).fontColor(Ui.textPrimary).placeholderColor(Ui.textTertiary)
                Row({ space: 8 }) {
                  TextInput({ placeholder: '加密方法', text: this.method })
                    .onChange((v: string) => { this.method = v; })
                    .height(46).borderRadius(12).backgroundColor(Ui.inputBackground(this.themeRevision))
                    .borderWidth(1)
                    .borderWidth(1).borderColor(Ui.glassEdge(this.themeRevision))
                    .fontColor(Ui.textPrimary).placeholderColor(Ui.textTertiary).layoutWeight(1)
                  TextInput({ placeholder: '协议', text: this.protocol })
                    .onChange((v: string) => { this.protocol = v; })
                    .height(46).borderRadius(12).backgroundColor(Ui.inputBackground(this.themeRevision))
                    .borderWidth(1)
                    .borderWidth(1).borderColor(Ui.glassEdge(this.themeRevision))
                    .fontColor(Ui.textPrimary).placeholderColor(Ui.textTertiary).layoutWeight(1)
                  TextInput({ placeholder: '混淆', text: this.obfs })
                    .onChange((v: string) => { this.obfs = v; })
                    .height(46).borderRadius(12).backgroundColor(Ui.inputBackground(this.themeRevision))
                    .borderWidth(1)
                    .borderWidth(1).borderColor(Ui.glassEdge(this.themeRevision))
                    .fontColor(Ui.textPrimary).placeholderColor(Ui.textTertiary).layoutWeight(1)
                }
                .width('100%')
              }
              TextInput({ placeholder: '端口跳跃（可选，如 1000-2000 或 1000,2000,3000）', text: this.portsHopping })
                .onChange((v: string) => { this.portsHopping = v; })
                .height(46).borderRadius(12).backgroundColor(Ui.inputBackground(this.themeRevision))
                .borderWidth(1)
                .borderWidth(1).borderColor(Ui.glassEdge(this.themeRevision))
                .fontColor(Ui.textPrimary).placeholderColor(Ui.textTertiary).width('100%')
              .width('100%')
              .padding(18)
              .borderRadius(22)
              .backgroundColor(Ui.surface(this.themeRevision))
              .borderWidth(1)
              .borderWidth(1)
              .borderColor(Ui.glassEdge(this.themeRevision))
            }
          }
          .padding({ left: 18, right: 18, bottom: 40 })
          .width('100%')
        }.edgeEffect(EdgeEffect.Spring)
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%').height('100%')
    }
    .width('100%').height('100%')
  }

  /** 路由推入式子页统一转场：水平滑动 + 淡入淡出（与页签切换同规格，见 TunBoxMotion） */
  pageTransition() {
    PageTransitionEnter({ duration: TunBoxMotion.ms, curve: TunBoxMotion.curve })
      .translate({ x: TunBoxMotion.slidePercent, y: 0 }).opacity(0)
    PageTransitionExit({ duration: TunBoxMotion.ms, curve: TunBoxMotion.curve })
      .translate({ x: `-${TunBoxMotion.slidePercent}`, y: 0 }).opacity(0)
  }
}
