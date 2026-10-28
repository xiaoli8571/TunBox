/**
 * 主页订阅区块（对齐 ClashPlus 1.2.7 主页 profiles 卡片 + 全屏节点面板）
 *
 * ## 2026-10-28 定稿形态
 * 1. 卡片：图标 + 订阅名 + 更新时间/节点数；右上三个动作（测速 / 编辑 / 刷新）；
 *    ↑/↓/总量 + 流量进度条 + 到期文案。
 * 2. 点卡片 → **全屏覆盖**节点面板：顶部返回、底部玻璃返回按钮；
 *    面板顶部是**订阅自带分组**（PROXY / AUTO / …）chips，选组列成员；点节点即切换并退出。
 * 3. 区块标题右侧是**菜单按钮**（原「管理」入口已删除、订阅管理页已并入本区块）：
 *    添加订阅 / 刷新全部 / 测速全部 / 删除订阅。
 */
import { promptAction, window } from '@kit.ArkUI';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import scanBarcode from '@hms.core.scan.scanBarcode';
import { TunBoxColors, TunBoxGeometry, TunBoxPing } from '../theme/TunBoxTokens';
import { SubscriptionSummary } from '../commons/utils/SubscriptionSummary';
import { SubscriptionService } from '../commons/services/SubscriptionService';
import { Subscription, SubscriptionRefreshStatus } from '../commons/models/Subscription';
import { ProxyNode } from '../commons/models/ProxyNode';
import { ProxyGroup } from '../commons/models/ProxyGroup';
import { SettingsService } from '../commons/services/SettingsService';
import { AppSettings, AutoSelectModes } from '../commons/models/AppSettings';
import { ConnectionOrchestrator, ConnState } from '../commons/services/ConnectionOrchestrator';
import { LatencyStoreBridge } from '../commons/services/LatencyStoreBridge';
import { BackgroundLatencyService } from '../commons/services/BackgroundLatencyService';
import { NodeProtocolPolicy } from '../commons/services/NodeSortPersistence';
import { ProfileRepository } from '../commons/flclash/ProfileRepository';
import { ProfileConfigMerger } from '../commons/flclash/ProfileConfigMerger';
import { SubConverter } from '../commons/flclash/SubConverter';
import { SubscriptionFetchPolicy } from '../commons/services/SubscriptionFetchPolicy';
import { CoreNodeBridge } from '../commons/flclash/CoreNodeBridge';
import { CoreCatalogService } from '../commons/flclash/CoreCatalogService';
import { CoreGroup } from '../commons/flclash/CoreCatalog';
import { AppLogger } from '../commons/utils/AppLogger';

const TAG = 'SubscriptionSection';
/** 节点行高（vp） */
const NODE_ROW_H: number = 52;

/** 添加订阅弹窗：三种模式（URL / 扫码 / 文件），白底实色，水平垂直居中 */
@CustomDialog
struct AddSubDialog {
  controller?: CustomDialogController;
  @State mode: string = 'url';
  @State urlText: string = '';
  @State busy: boolean = false;
  @State allowInsecure: boolean = false;
  @State convertText: string = '';
  getAllowInsecure: () => boolean = () => false;
  onToggleInsecure: (v: boolean) => void = () => {};
  onAddUrl: (url: string) => void = () => {};
  onConvert: (text: string) => void = () => {};
  onScan: () => void = () => {};
  onPickFile: () => void = () => {};

  aboutToAppear(): void {
    this.allowInsecure = this.getAllowInsecure();
  }

  build() {
    Column({ space: 14 }) {
      Text('添加订阅')
        .fontSize(17).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
        .width('100%')

      // 三模式切换
      Row({ space: 6 }) {
        this.ModeChip('二维码', 'qr')
        this.ModeChip('URL', 'url')
        this.ModeChip('文件', 'file')
        this.ModeChip('转换', 'convert')
      }
      .width('100%')

      if (this.mode === 'url') {
        TextInput({ placeholder: 'https://example.com/sub', text: this.urlText })
          .onChange((v: string) => { this.urlText = v; })
          .height(44).borderRadius(12).fontSize(13)
          .backgroundColor(TunBoxColors.surfaceSubtle)
          .borderWidth(1).borderColor(TunBoxColors.cardBorder)
          .fontColor(TunBoxColors.textPrimary)
        // 2026-10-28 用户要求：明文 HTTP 开关从设置页挪到这里（只影响订阅拉取）
        Row() {
          Text('允许明文 HTTP 订阅')
            .fontSize(13).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.allowInsecure })
            .selectedColor(TunBoxColors.primary)
            .onChange((v: boolean) => {
              this.allowInsecure = v;
              this.onToggleInsecure(v);
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      } else if (this.mode === 'qr') {
        Column({ space: 8 }) {
          Image($r('app.media.ic_globe')).width(48).height(48).fillColor(TunBoxColors.textMuted)
          Text('扫描订阅二维码').fontSize(13).fontColor(TunBoxColors.textSecondary)
          Text('二维码内容需是 Clash 订阅链接').fontSize(11).fontColor(TunBoxColors.textMuted)
        }
        .width('100%')
        .padding({ top: 20, bottom: 20 })
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(TunBoxColors.surfaceSubtle)
        .borderRadius(12)
      } else if (this.mode === 'convert') {
        TextArea({ placeholder: '粘贴分享链接（单条/多条/base64）', text: this.convertText })
          .onChange((v: string) => { this.convertText = v; })
          .height(120).borderRadius(12).fontSize(12)
          .backgroundColor(TunBoxColors.surfaceSubtle)
          .borderWidth(1).borderColor(TunBoxColors.cardBorder)
          .fontColor(TunBoxColors.textPrimary)
        Text('分享链接会转换成本地 Clash 配置并加入订阅列表。')
          .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
      } else {
        Column({ space: 8 }) {
          Image($r('app.media.ic_doc')).width(48).height(48).fillColor(TunBoxColors.textMuted)
          Text('从文件导入').fontSize(13).fontColor(TunBoxColors.textSecondary)
          Text('支持 .yaml / .yml（Clash 配置，4MB 以内）').fontSize(11).fontColor(TunBoxColors.textMuted)
        }
        .width('100%')
        .padding({ top: 20, bottom: 20 })
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(TunBoxColors.surfaceSubtle)
        .borderRadius(12)
      }

      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).height(44).borderRadius(12).fontSize(14)
          .backgroundColor(TunBoxColors.surfaceSubtle).fontColor(TunBoxColors.textPrimary)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button(this.mode === 'url' ? '添加' : (this.mode === 'convert' ? '转换' : '开始'))
          .layoutWeight(1).height(44).borderRadius(12).fontSize(14)
          .backgroundColor(TunBoxColors.primary).fontColor(Color.White)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
            if (this.mode === 'url') {
              this.onAddUrl(this.urlText);
            } else if (this.mode === 'qr') {
              this.onScan();
            } else if (this.mode === 'convert') {
              this.onConvert(this.convertText);
            } else {
              this.onPickFile();
            }
          })
      }.width('100%')
    }
    .width('86%')
    .padding(20)
    .backgroundColor(TunBoxColors.surfaceCard)
    .borderRadius(20)
    .border({ width: 1, color: TunBoxColors.cardBorder })
  }

  @Builder
  ModeChip(label: string, value: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.mode === value ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.mode === value ? TunBoxColors.textOnPrimary : TunBoxColors.textSecondary)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(36)
      .borderRadius(10)
      .backgroundColor(this.mode === value ? TunBoxColors.primary : TunBoxColors.chipBg)
      .onClick(() => { this.mode = value; })
  }
}

/** 编辑配置信息弹窗（对齐 ClashPlus 的「编辑配置信息」：实色底、居中弹出） */
@CustomDialog
struct EditSubDialog {
  controller?: CustomDialogController;
  @State editName: string = '';
  @State editUrl: string = '';
  @State autoUpdate: boolean = true;
  getInitialName: () => string = () => '';
  getInitialUrl: () => string = () => '';
  getAutoUpdate: () => boolean = () => true;
  getIntervalText: () => string = () => '';
  onConfirm: (name: string, url: string, autoUpdate: boolean) => void = () => {};
  onDelete: () => void = () => {};

  aboutToAppear(): void {
    this.editName = this.getInitialName();
    this.editUrl = this.getInitialUrl();
    this.autoUpdate = this.getAutoUpdate();
  }

  build() {
    Column({ space: 12 }) {
      Text('编辑配置信息')
        .fontSize(17).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
        .width('100%')

      Text('配置名称').fontSize(12).fontColor(TunBoxColors.textMuted).width('100%')
      TextInput({ text: this.editName, placeholder: '配置名称' })
        .onChange((v: string) => { this.editName = v; })
        .height(44).borderRadius(12).fontSize(14)
        .backgroundColor(TunBoxColors.surfaceSubtle)
        .borderWidth(1).borderColor(TunBoxColors.cardBorder)
        .fontColor(TunBoxColors.textPrimary)

      Text('订阅链接或 URL').fontSize(12).fontColor(TunBoxColors.textMuted).width('100%')
      TextInput({ text: this.editUrl, placeholder: 'https://example.com/sub' })
        .onChange((v: string) => { this.editUrl = v; })
        .height(44).borderRadius(12).fontSize(13)
        .backgroundColor(TunBoxColors.surfaceSubtle)
        .borderWidth(1).borderColor(TunBoxColors.cardBorder)
        .fontColor(TunBoxColors.textPrimary)

      Row() {
        Text('自动更新').fontSize(14).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.autoUpdate })
          .selectedColor(TunBoxColors.primary)
          .onChange((v: boolean) => { this.autoUpdate = v; })
      }.width('100%').alignItems(VerticalAlign.Center)

      Text('自动更新间隔（分钟）').fontSize(12).fontColor(TunBoxColors.textMuted).width('100%')
      Row({ space: 6 }) {
        Image($r('app.media.ic_refresh')).width(14).height(14).fillColor(TunBoxColors.textMuted)
        Text(this.getIntervalText()).fontSize(14).fontColor(TunBoxColors.textPrimary)
        Blank()
        Text('跟随系统').fontSize(11).fontColor(TunBoxColors.textMuted)
      }
      .width('100%').height(44)
      .padding({ left: 12, right: 12 })
      .borderRadius(12)
      .backgroundColor(TunBoxColors.surfaceSubtle)
      .borderWidth(1).borderColor(TunBoxColors.cardBorder)
      .alignItems(VerticalAlign.Center)

      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).height(44).borderRadius(12).fontSize(14)
          .backgroundColor(TunBoxColors.surfaceSubtle).fontColor(TunBoxColors.textPrimary)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button('保存更改').layoutWeight(1).height(44).borderRadius(12).fontSize(14)
          .backgroundColor(TunBoxColors.primary).fontColor(Color.White)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onConfirm(this.editName, this.editUrl, this.autoUpdate);
          })
      }.width('100%')

      Button('删除').width('100%').height(44).borderRadius(12).fontSize(14)
        .backgroundColor(TunBoxColors.dangerLight).fontColor(TunBoxColors.danger)
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
          this.onDelete();
        })
    }
    .width('86%')
    .padding(20)
    // 实色底（2026-10-28 用户要求：不要沉浸材质，要白底实色卡片）
    .backgroundColor(TunBoxColors.surfaceCard)
    .borderRadius(20)
    .border({ width: 1, color: TunBoxColors.cardBorder })
  }
}

@Component
export struct SubscriptionSection {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @State private subs: Subscription[] = [];
  @State private showPanel: boolean = false;
  @State private panelSubId: string = '';
  @State private selectedGroup: string = '';
  @State private currentProfileId: string = '';
  @State private currentNodeName: string = '';
  @State private coreRevision: number = 0;
  @State private latencyRevision: number = 0;
  @State private refreshingIds: string[] = [];
  @State private testingIds: string[] = [];
  @State private sortByDelay: boolean = true;
  /** 状态栏高度（vp）：全屏覆盖层内容要从状态栏之下起排 */
  @State private statusBarH: number = 24;

  private service: SubscriptionService = SubscriptionService.instance();
  private settings: AppSettings = new AppSettings();
  private refreshing: boolean = false;
  private editTargetId: string = '';
  private editTargetName: string = '';
  /** 全局「自动更新订阅」开关（编辑弹框里展示/修改的就是它） */
  private autoUpdateGlobal: boolean = true;
  /** 允许明文 HTTP 订阅（2026-10-28 从设置页挪到「添加订阅 → URL」） */
  private allowInsecureSubscriptionHttp: boolean = false;
  private readonly addDialog: CustomDialogController = new CustomDialogController({
    builder: AddSubDialog({
      getAllowInsecure: (): boolean => this.allowInsecureSubscriptionHttp,
      onToggleInsecure: (v: boolean): void => { this.setAllowInsecure(v); },
      onAddUrl: (url: string): void => { this.applyAdd('', url); },
      onConvert: (text: string): void => { this.importFromConvert(text); },
      onScan: (): void => { this.importFromQr(); },
      onPickFile: (): void => { this.importYamlFile(); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true
  });
  private readonly editDialog: CustomDialogController = new CustomDialogController({
    builder: EditSubDialog({
      getInitialName: (): string => {
        const s: Subscription | null = this.subById(this.editTargetId);
        return s === null ? '' : s.name;
      },
      getInitialUrl: (): string => {
        const s: Subscription | null = this.subById(this.editTargetId);
        return s === null ? '' : s.url;
      },
      getAutoUpdate: (): boolean => this.autoUpdateGlobal,
      getIntervalText: (): string => this.refreshIntervalMinutesText(),
      onConfirm: (name: string, url: string, autoUpdate: boolean): void => {
        this.applyEdit(name, url, autoUpdate);
      },
      onDelete: (): void => { this.deleteSub(this.editTargetId, this.editTargetName); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true
  });

  private readonly latencyListener: () => void = (): void => {
    this.latencyRevision = this.latencyRevision + 1;
  };
  private latencyBound: boolean = false;
  private readonly nodeSetListener: (reason: string) => void = (reason: string): void => {
    AppLogger.info(TAG, `node set changed: ${reason}`);
    this.reload();
  };
  private nodeSetBound: boolean = false;
  private readonly orchListener: () => void = (): void => {
    this.reload();
    this.refreshCoreCatalog();
  };
  private orchBound: boolean = false;

  aboutToAppear(): void {
    if (!this.latencyBound) {
      this.latencyBound = true;
      LatencyStoreBridge.addListener(this.latencyListener);
    }
    if (!this.nodeSetBound) {
      this.nodeSetBound = true;
      SubscriptionService.onNodeSetChanged(this.nodeSetListener);
    }
    if (!this.orchBound) {
      this.orchBound = true;
      ConnectionOrchestrator.instance().addListener(this.orchListener);
    }
    this.reload();
    this.refreshCoreCatalog();
    this.measureStatusBar();
    if (this.subs.length === 0) {
      setTimeout((): void => { this.reload(); }, 600);
      setTimeout((): void => { this.reload(); }, 1600);
    }
  }

  aboutToDisappear(): void {
    if (this.latencyBound) {
      this.latencyBound = false;
      LatencyStoreBridge.removeListener(this.latencyListener);
    }
    if (this.nodeSetBound) {
      this.nodeSetBound = false;
      SubscriptionService.offNodeSetChanged(this.nodeSetListener);
    }
    if (this.orchBound) {
      this.orchBound = false;
      ConnectionOrchestrator.instance().removeListener(this.orchListener);
    }
  }

  /** 取系统状态栏高度（px → vp），失败保持默认 24vp */
  private measureStatusBar(): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      window.getLastWindow(ctx).then((win: window.Window): void => {
        const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const px: number = area.topRect.height;
        if (px > 0) {
          this.statusBarH = px2vp(px);
        }
      }).catch((): void => {});
    } catch (e) {
      AppLogger.warn(TAG, `measure status bar failed: ${AppLogger.errText(e)}`);
    }
  }

  // ────────────────────────── 数据 ──────────────────────────

  private reload(): void {
    this.subs = this.service.subscriptions.slice();
    this.currentProfileId = ProfileRepository.currentId();
    const orch: ConnectionOrchestrator = ConnectionOrchestrator.instance();
    const target = orch.getCurrentConnectionTarget();
    if (target !== null && target.nodeName.length > 0) {
      this.currentNodeName = target.nodeName;
    } else if (this.settings.preferredNodeName.length > 0) {
      this.currentNodeName = this.settings.preferredNodeName;
    }
    // 偏好必须从磁盘读：本组件此前从未 load 过 AppSettings，
    // 导致「选完节点→重进面板」时 preferredNodeName 恒为空 → 勾选丢失（真机复现）。
    SettingsService.load().then((loaded: AppSettings): void => {
      this.settings = loaded;
      this.autoUpdateGlobal = loaded.autoUpdateSubscription;
      this.allowInsecureSubscriptionHttp = loaded.allowInsecureSubscriptionHttp;
      if (this.currentNodeName.length === 0) {
        this.currentNodeName = loaded.preferredNodeName;
      }
    }).catch((): void => {});
  }

  private subById(id: string): Subscription | null {
    for (let i = 0; i < this.subs.length; i++) {
      if (this.subs[i].id === id) {
        return this.subs[i];
      }
    }
    return null;
  }

  /** 面板当前订阅（null = 无） */
  private panelSub(): Subscription | null {
    return this.subById(this.panelSubId);
  }

 

  private coreCatalogFor(subId: string): boolean {
    const state = ConnectionOrchestrator.instance().state;
    return (state === ConnState.CONNECTED || state === ConnState.CONNECTING)
      && CoreCatalogService.current() !== null
      && CoreCatalogService.profileIdOfSnapshot() === subId;
  }

  private groupsOf(subId: string): ProxyGroup[] {
    const core = CoreCatalogService.current();
    if (core !== null && subId === this.currentProfileId && this.coreCatalogFor(subId)) {
      const out: ProxyGroup[] = [];
      for (const source of core.groups) {
        if (source.hidden) {
          continue;
        }
        const group = new ProxyGroup();
        group.subscriptionId = subId;
        group.name = source.name;
        group.groupType = source.type;
        group.members = source.all.filter((node): boolean => !node.isGroup).map((node): string => node.name);
        out.push(group);
      }
      return out;
    }
    return this.service.groupsOf(subId);
  }

  private async refreshCoreCatalog(): Promise<void> {
    const orch: ConnectionOrchestrator = ConnectionOrchestrator.instance();
    if (orch.state !== ConnState.CONNECTED && orch.state !== ConnState.CONNECTING) {
      return;
    }
    const profileId = ProfileRepository.currentId();
    const model = await CoreCatalogService.refresh(orch.api, false, profileId);
    if (model !== null) {
      this.coreRevision = this.coreRevision + 1;
    }
  }

  private activeGroupOf(subId: string): ProxyGroup | null {
    if (this.selectedGroup.length === 0) {
      return null;
    }
    const list: ProxyGroup[] = this.groupsOf(subId);
    for (let i = 0; i < list.length; i++) {
      if (list[i].name === this.selectedGroup) {
        return list[i];
      }
    }
    return null;
  }

  private panelNodes(): ProxyNode[] {
    const core = CoreCatalogService.current();
    let arr: ProxyNode[];
    if (core !== null && this.panelSubId === this.currentProfileId && this.coreCatalogFor(this.panelSubId)) {
      const source: CoreGroup | null = core.findGroup(this.selectedGroup);
      const nodes = source !== null ? source.all.filter((node): boolean => !node.isGroup)
        : CoreCatalogService.flattenNodes('rule');
      arr = CoreNodeBridge.toProxyNodes(nodes, this.panelSubId);
    } else {
      const group: ProxyGroup | null = this.activeGroupOf(this.panelSubId);
      if (group !== null) {
        arr = this.service.expandProxyGroup(group);
      } else {
        arr = this.service.nodesOf(this.panelSubId).slice();
      }
    }
    if (!this.sortByDelay) {
      return arr;
    }
    return CoreNodeBridge.sortByDelay(arr, (name: string): number | null => {
      return LatencyStoreBridge.latencyFor(name);
    });
  }

  private protoOf(node: ProxyNode): string {
    if (CoreNodeBridge.isShadow(node)) {
      return CoreNodeBridge.protocolLabel(node);
    }
    return NodeProtocolPolicy.fromNode(node).display();
  }

  private pingText(node: ProxyNode): string {
    return TunBoxPing.recordText(LatencyStoreBridge.recordFor(node.name), this.latencyRevision);
  }

  private pingColor(node: ProxyNode): ResourceColor {
    return TunBoxPing.recordColor(LatencyStoreBridge.recordFor(node.name), this.latencyRevision);
  }

  private isActiveNode(node: ProxyNode): boolean {
    return this.currentNodeName.length > 0 && node.name === this.currentNodeName;
  }

  private isRefreshingSub(id: string): boolean {
    return this.refreshingIds.includes(id);
  }

  private isTestingSub(id: string): boolean {
    return this.testingIds.includes(id);
  }

  private upText(sub: Subscription): string {
    return SubscriptionSummary.bytes(sub.uploadBytes);
  }

  private downText(sub: Subscription): string {
    return SubscriptionSummary.bytes(sub.downloadBytes);
  }

  private totalText(sub: Subscription): string {
    return sub.totalBytes > 0 ? SubscriptionSummary.bytes(sub.totalBytes) : '不限';
  }

  /** 用量比例（0–1）；总量未知返回 -1（不画进度） */
  private usageRatio(sub: Subscription): number {
    if (sub.totalBytes <= 0) {
      return -1;
    }
    const used: number = Math.max(0, sub.uploadBytes) + Math.max(0, sub.downloadBytes);
    return Math.min(1, Math.max(0, used / sub.totalBytes));
  }

  private expiryText(sub: Subscription): string {
    if (sub.expireAt <= 0) {
      return '长期有效';
    }
    // 机场的 subscription-userinfo 有的给秒级时间戳、有的给毫秒（实测 ikuuu 是毫秒），
    // 用数量级判定：>= 1e12 视为毫秒，否则按秒。
    const expireMs: number = sub.expireAt >= 1e12 ? sub.expireAt : sub.expireAt * 1000;
    const remainMs: number = expireMs - Date.now();
    if (remainMs <= 0) {
      return '已到期';
    }
    const days: number = Math.floor(remainMs / 86400000);
    if (days >= 1) {
      return `剩余 ${days} 天`;
    }
    const hours: number = Math.floor(remainMs / 3600000);
    return hours >= 1 ? `剩余 ${hours} 小时` : '即将到期';
  }

  private updateText(sub: Subscription): string {
    return `${SubscriptionSummary.updateTime(sub.lastFetchedAt)}更新`;
  }

  private nodeCountText(sub: Subscription): string {
    const core = CoreCatalogService.current();
    if (core !== null && sub.id === this.currentProfileId && this.coreCatalogFor(sub.id)) {
      return `${CoreCatalogService.flattenNodes('rule').length} 节点`;
    }
    return `${this.service.nodesOf(sub.id).length} 节点`;
  }

  /** 写法与设置页同源：只改这一个字段，不整单覆盖 */
  private setAllowInsecure(v: boolean): void {
    this.allowInsecureSubscriptionHttp = v;
    SettingsService.patchSettings((s: AppSettings): void => {
      s.allowInsecureSubscriptionHttp = v;
    }).catch((): void => {});
  }

  /** 自动更新间隔展示：跟随系统级订阅过期判定（SUBSCRIPTION_STALE_MS = 6h） */
  private refreshIntervalMinutesText(): string {
    return '360';
  }

  // ────────────────────────── 动作 ──────────────────────────

  private onHeaderTap(sub: Subscription): void {
    this.panelSubId = sub.id;
    const groups: ProxyGroup[] = this.groupsOf(sub.id);
    this.selectedGroup = groups.length > 0 ? groups[0].name : '';
    this.showPanel = true;
    if (this.currentProfileId !== sub.id) {
      this.activateProfile(sub.id).catch((e: Object): void => {
        AppLogger.warn(TAG, `activate profile failed: ${AppLogger.errText(e)}`);
      });
    }
  }

  private closePanel(): void {
    this.showPanel = false;
  }

  private async activateProfile(id: string): Promise<void> {
    if (id.length === 0) {
      return;
    }
    if (ProfileRepository.currentId() === id) {
      return;
    }
    await ProfileRepository.setCurrent(id);
    this.currentProfileId = id;
    const rev: number = AppStorage.get<number>('public_ip_revision') ?? 0;
    AppStorage.setOrCreate('public_ip_revision', rev + 1);
    try {
      await ConnectionOrchestrator.instance().ensureProfileApplied('home-subscription-section');
    } catch (e) {
      AppLogger.warn(TAG, `ensure profile applied failed: ${AppLogger.errText(e)}`);
    }
    this.reload();
  }

  private async refreshOne(sub: Subscription): Promise<void> {
    if (this.refreshing || this.isRefreshingSub(sub.id)) {
      return;
    }
    this.refreshing = true;
    this.refreshingIds = this.refreshingIds.concat([sub.id]);
    try {
      const result = await this.service.refreshSubscription(sub.id);
      const ok: boolean = result.status === SubscriptionRefreshStatus.OK
        || result.status === SubscriptionRefreshStatus.NOT_MODIFIED;
      this.toast(ok ? `✓ ${sub.name} 已刷新` : `刷新失败：${sub.name}`);
    } catch (e) {
      AppLogger.warn(TAG, `refresh failed: ${AppLogger.errText(e)}`);
      this.toast('刷新失败，请重试');
    } finally {
      this.refreshing = false;
      this.refreshingIds = this.refreshingIds.filter((x: string): boolean => x !== sub.id);
      this.reload();
    }
  }

  private async refreshAll(): Promise<void> {
    const snapshot: Subscription[] = this.subs.slice();
    for (let i = 0; i < snapshot.length; i++) {
      await this.refreshOne(snapshot[i]);
    }
    this.toast('✓ 全部订阅已刷新');
  }

  private async testSub(subId: string, subName: string): Promise<void> {
    if (this.isTestingSub(subId)) {
      return;
    }
    this.testingIds = this.testingIds.concat([subId]);
    try {
      const context: Context = getContext(this) as Context;
      await BackgroundLatencyService.testSubscription(context, subId);
      this.toast(`✓ ${subName} 测速完成`);
    } catch (e) {
      AppLogger.warn(TAG, `latency test failed: ${AppLogger.errText(e)}`);
      this.toast('测速失败，请重试');
    } finally {
      this.testingIds = this.testingIds.filter((x: string): boolean => x !== subId);
      this.latencyRevision = this.latencyRevision + 1;
    }
  }

 

  private openEdit(sub: Subscription): void {
    this.editTargetId = sub.id;
    this.editTargetName = sub.name;
    this.editDialog.open();
  }

  /** 扫码导入（相机权限被拒 / 用户取消各有独立提示） */
  private async importFromQr(): Promise<void> {
    try {
      const result = await scanBarcode.startScanForResult(getContext(this) as Context, {
        enableMultiMode: false,
        enableAlbum: true
      });
      const raw: string = result.originalValue.trim();
      if (raw.length === 0) {
        this.toast('二维码内容为空');
        return;
      }
      const lower: string = raw.toLowerCase();
      if (!(lower.startsWith('https://') || lower.startsWith('http://'))) {
        this.toast('二维码里应是 Clash 订阅链接');
        return;
      }
      await this.applyAdd('', raw);
    } catch (e) {
      const err = e as BusinessError;
      if (err.code === 1000500002) {
        this.toast('已取消二维码扫描');
      } else if (err.code === 201) {
        this.toast('相机权限被拒绝，无法扫描二维码');
      } else {
        this.toast('二维码扫描失败，请重试');
      }
    }
  }

  /**
   * 「转换」模式：分享链接 / 非 Clash 订阅正文 → 本地 Clash 配置 → 加入订阅列表。
   * 与设置页原「订阅转换」同一套实现（ProfileConfigMerger + SubConverter），
   * 只是输出目标固定为订阅列表，不再落外部文件。
   */
  private async importFromConvert(text: string): Promise<void> {
    const raw: string = text.trim();
    if (raw.length === 0) {
      this.toast('请粘贴分享链接或订阅内容');
      return;
    }
    try {
      let body: string = raw;
      const lower: string = raw.toLowerCase();
      if (lower.startsWith('http://') || lower.startsWith('https://')) {
        const loaded: AppSettings = await SettingsService.load();
        const fetched = await SubscriptionFetchPolicy.fetch(raw, '', '',
          loaded.allowInsecureSubscriptionHttp, 'convert');
        body = fetched.body;
      }
      if (body.trim().length === 0) {
        this.toast('没有拿到内容，请检查链接是否可用');
        return;
      }
      let yaml: string = body;
      let count: number = 0;
      if (ProfileConfigMerger.isKernelLoadableConfig(body)) {
        count = ProfileConfigMerger.merge('a: 1', body).profileProxyItems;
      } else {
        const converted = SubConverter.convert(body);
        if (!converted.ok) {
          this.toast('无法识别内容：既不是 Clash 配置，也解析不出节点链接');
          return;
        }
        yaml = converted.proxiesYaml;
        count = converted.count;
      }
      const stat: Date = new Date();
      const fileName: string = `converted-${stat.getFullYear()}${String(stat.getMonth() + 1).padStart(2, '0')}`
        + `${String(stat.getDate()).padStart(2, '0')}-${String(stat.getHours()).padStart(2, '0')}`
        + `${String(stat.getMinutes()).padStart(2, '0')}.yaml`;
      const added: number = await this.service.addLocalYaml(fileName, yaml);
      if (added > 0) {
        this.toast(`转换成功，加入 ${added || count} 个节点`);
        this.reload();
      } else {
        this.toast('转换成功但没有可用节点');
      }
    } catch (e) {
      AppLogger.warn(TAG, `convert import failed: ${AppLogger.errText(e)}`);
      this.toast('转换失败，请重试');
    }
  }

  /** 从本地文件导入 Clash YAML */
  private async importYamlFile(): Promise<void> {
    try {
      const docPicker = new picker.DocumentViewPicker(getContext(this) as Context);
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      opts.fileSuffixFilters = ['.yaml', '.yml'];
      const uris = await docPicker.select(opts);
      if (uris.length === 0) {
        return;
      }
      const uri: string = uris[0];
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        const stat = fs.statSync(file.fd);
        if (stat.size <= 0 || stat.size > 4 * 1024 * 1024) {
          this.toast('文件大小需在 4MB 以内');
          return;
        }
        const buf = new ArrayBuffer(Number(stat.size));
        let readLen: number = 0;
        while (readLen < Number(stat.size)) {
          const chunk = fs.readSync(file.fd, buf, { offset: readLen, length: Number(stat.size) - readLen });
          if (chunk <= 0) {
            break;
          }
          readLen += chunk;
        }
        const text: string = util.TextDecoder.create('utf-8')
          .decodeToString(new Uint8Array(buf, 0, readLen));
        const fileName: string = uri.substring(uri.lastIndexOf('/') + 1);
        const count: number = await this.service.addLocalYaml(fileName, text);
        if (count > 0) {
          this.toast(`文件导入成功，解析出 ${count} 个节点`);
          this.reload();
        } else {
          this.toast('文件里没有可用的 Clash 节点');
        }
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      AppLogger.warn(TAG, `yaml import failed: ${AppLogger.errText(e)}`);
      this.toast('导入失败，请重试');
    }
  }

  private async applyAdd(name: string, url: string): Promise<void> {
    const nextUrl: string = url.trim();
    if (nextUrl.length === 0) {
      this.toast('请填写订阅链接');
      return;
    }
    // 只接受 Clash 订阅链接：单节点分享链接（ss/vmess/vless/trojan/hysteria2/…）一律拒绝
    if (SubscriptionService.isNodeUri(nextUrl)) {
      this.toast('只支持 Clash 订阅链接，不支持单节点分享链接');
      return;
    }
    const lower: string = nextUrl.toLowerCase();
    if (!(lower.startsWith('https://') || lower.startsWith('http://'))) {
      this.toast('订阅链接必须以 http:// 或 https:// 开头');
      return;
    }
    if (lower.startsWith('http://') && !this.allowInsecureSubscriptionHttp) {
      this.toast('明文 HTTP 订阅未开启，请先打开下方开关');
      return;
    }
    let nextName: string = name.trim();
    if (nextName.length === 0) {
      nextName = nextUrl.replace(/^https?:\/\//i, '').split('/')[0];
    }
    try {
      await this.service.addSubscription(nextName, nextUrl, '', '');
      this.toast('✓ 已添加订阅');
      this.reload();
      setTimeout((): void => { this.refreshAll(); }, 300);
    } catch (e) {
      AppLogger.warn(TAG, `add subscription failed: ${AppLogger.errText(e)}`);
      this.toast('添加失败，请检查链接');
    }
  }

  private async applyEdit(name: string, url: string, autoUpdate: boolean): Promise<void> {
    const target: Subscription | null = this.subById(this.editTargetId);
    if (target === null) {
      return;
    }
    const nextName: string = name.trim();
    const nextUrl: string = url.trim();
    if (nextName.length === 0) {
      this.toast('订阅名称不能为空');
      return;
    }
    const urlChanged: boolean = nextUrl.length > 0 && nextUrl !== target.url;
    target.name = nextName;
    if (nextUrl.length > 0) {
      target.url = nextUrl;
    }
    try {
      await this.service.updateSubscription(target);
      if (autoUpdate !== this.autoUpdateGlobal) {
        this.autoUpdateGlobal = autoUpdate;
        await SettingsService.patchSettings((s: AppSettings): void => {
          s.autoUpdateSubscription = autoUpdate;
        });
      }
      if (urlChanged) {
        await this.service.refreshSubscription(target.id);
      }
      this.toast('已保存');
    } catch (e) {
      AppLogger.warn(TAG, `update subscription failed: ${AppLogger.errText(e)}`);
      this.toast('保存失败，请重试');
    }
    this.reload();
  }

 

  private async deleteSub(id: string, name: string): Promise<void> {
    try {
      await this.service.removeSubscription(id);
      this.toast(`已删除 ${name}`);
      this.reload();
    } catch (e) {
      AppLogger.warn(TAG, `delete subscription failed: ${AppLogger.errText(e)}`);
      this.toast('删除失败，请重试');
    }
  }

  private async selectNode(node: ProxyNode): Promise<void> {
    // /proxies 只提供名字和类型；连接仍必须回查 profile 中的真实节点以取得凭据。
    if (CoreNodeBridge.isShadow(node)) {
      const local = this.service.nodesOf(this.panelSubId).find((candidate): boolean => candidate.name === node.name);
      if (local === undefined) {
        this.toast('该内核节点缺少可用凭据，请刷新订阅后重试');
        return;
      }
      node = local;
    }
    this.closePanel();
    if (this.settings.autoSelectMode === AutoSelectModes.AUTO) {
      this.settings.autoSelectMode = AutoSelectModes.MANUAL;
    }
    this.settings.preferredNodeId = node.id;
    this.settings.preferredNodeName = node.name;
    if (node.subscriptionId.length > 0) {
      this.settings.preferredNodeSubscriptionId = node.subscriptionId;
      this.settings.selectedSubscriptionId = node.subscriptionId;
      this.settings.preferredNodeNamesBySubscription = AppSettings.rememberPreferredNodeName(
        this.settings.preferredNodeNamesBySubscription, node.subscriptionId, node.name);
    }
    this.currentNodeName = node.name;
    await SettingsService.patchSettings((s: AppSettings): void => {
      s.autoSelectMode = AutoSelectModes.MANUAL;
      s.preferredNodeId = node.id;
      s.preferredNodeName = node.name;
      if (node.subscriptionId.length > 0) {
        s.preferredNodeSubscriptionId = node.subscriptionId;
        s.selectedSubscriptionId = node.subscriptionId;
        s.preferredNodeNamesBySubscription = AppSettings.rememberPreferredNodeName(
          s.preferredNodeNamesBySubscription, node.subscriptionId, node.name);
      }
    });
    let restarted: boolean = false;
    try {
      restarted = await ConnectionOrchestrator.instance()
        .reconnectWithNode(node, this.service, 'home-section=' + node.id);
    } catch (e) {
      AppLogger.warn(TAG, `reconnect after pick failed: ${AppLogger.errText(e)}`);
    }
    // 通知主页刷新「启动按钮内的节点名」（2026-10-28 用户报障：选完节点要等启动才更新）
    const nodeRev: number = AppStorage.get<number>('node_switch_revision') ?? 0;
    AppStorage.setOrCreate('node_switch_revision', nodeRev + 1);
    if (restarted) {
      const rev: number = AppStorage.get<number>('public_ip_revision') ?? 0;
      AppStorage.setOrCreate('public_ip_revision', rev + 1);
      this.toast(`已选择 ${node.name}，正在重连…`);
    } else {
      this.toast(`已选择 ${node.name}`);
    }
    this.reload();
  }

  private toast(message: string): void {
    promptAction.showToast({ message: message });
  }

  // ────────────────────────── 渲染 ──────────────────────────

  @Builder
  SectionHeader() {
    Row({ space: 8 }) {
      Text('订阅')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(TunBoxColors.textPrimary)
      Text(`${this.subs.length}`)
        .fontSize(11)
        .fontColor(TunBoxColors.primary)
        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
        .backgroundColor(TunBoxColors.primaryLight)
        .borderRadius(TunBoxGeometry.pillRadius)
      Blank()
      // 添加订阅：2026-10-28 用户要求「直接用 + 号，点击就弹添加订阅」
      Stack({ alignContent: Alignment.Center }) {
        Image($r('app.media.ic_plus')).width(18).height(18).fillColor(TunBoxColors.primary)
      }
      .width(32).height(32)
      .borderRadius(TunBoxGeometry.pillRadius)
      .backgroundColor(TunBoxColors.primaryLight)
      .accessibilityText('添加订阅')
      .onClick((): void => { this.addDialog.open(); })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 卡片右上动作图标：测速 / 编辑 / 刷新 */
  @Builder
  CardAction(icon: Resource, label: string, busy: boolean, onTap: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      if (busy) {
        LoadingProgress().width(18).height(18).color(TunBoxColors.primary)
      } else {
        Image(icon).width(18).height(18).fillColor(TunBoxColors.textMuted)
      }
    }
    .width(40).height(40)
    .borderRadius(TunBoxGeometry.pillRadius)
    .flexShrink(0)
    .accessibilityText(label)
    // 关键：动作图标必须**吞掉**触摸，否则点击会冒泡到整张卡的 onClick
    // 直接打开节点面板（真机实测：点 ⚙ 弹出的是节点列表）。
    .hitTestBehavior(HitTestMode.Block)
    .onClick(onTap)
  }

  @Builder
  SubCard(sub: Subscription, tapToClose: boolean) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Stack({ alignContent: Alignment.Center }) {
          Image($r('app.media.ic_nodes')).width(18).height(18).fillColor(TunBoxColors.primary)
        }
        .width(32).height(32)
        .borderRadius(8)
        .backgroundColor(TunBoxColors.primaryLight)

        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(sub.name.length > 0 ? sub.name : '未命名订阅')
              .fontSize(14).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (sub.id === this.currentProfileId) {
              Text('使用中')
                .fontSize(10).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.success)
                .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                .borderRadius(TunBoxGeometry.pillRadius)
                .backgroundColor(TunBoxColors.successLight)
                .flexShrink(0)
            }
          }.width('100%')
          Text(`${this.updateText(sub)} · ${this.nodeCountText(sub)}`)
            .fontSize(11).fontColor(TunBoxColors.textMuted)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 顺序（2026-10-28 用户定稿）：测速 → 刷新 → 设置
        this.CardAction($r('app.media.ic_bolt'), '订阅测速', this.isTestingSub(sub.id), (): void => {
          this.testSub(sub.id, sub.name);
        })
        this.CardAction($r('app.media.ic_refresh'), '刷新订阅', this.isRefreshingSub(sub.id), (): void => {
          this.refreshOne(sub);
        })
        this.CardAction($r('app.media.ic_tune'), '编辑订阅', false, (): void => {
          this.openEdit(sub);
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Text(`↑ ${this.upText(sub)}`)
          .fontSize(12).fontWeight(FontWeight.Medium).fontColor(TunBoxColors.primary)
          .maxLines(1)
        Text(`  ↓ ${this.downText(sub)}`)
          .fontSize(12).fontWeight(FontWeight.Medium).fontColor(TunBoxColors.success)
          .maxLines(1)
        Text(`  / ${this.totalText(sub)}`)
          .fontSize(11).fontColor(TunBoxColors.textMuted)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.expiryText(sub))
          .fontSize(11).fontColor(TunBoxColors.textSecondary)
          .maxLines(1)
          .flexShrink(0)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(6)
          .borderRadius(3)
          .backgroundColor(TunBoxColors.controlTrack)
        if (this.usageRatio(sub) >= 0) {
          Row()
            .width(`${Math.max(2, Math.round(this.usageRatio(sub) * 100))}%`)
            .height(6)
            .borderRadius(3)
            .linearGradient({
              angle: 90,
              colors: [[TunBoxColors.primary, 0.0], [TunBoxColors.success, 1.0]]
            })
        }
      }
      .width('100%')
      .height(6)
      .clip(true)
    }
    .width('100%')
    .padding(14)
    .alignItems(HorizontalAlign.Start)
    .borderRadius(TunBoxGeometry.cardRadiusSmall)
    .backgroundColor(TunBoxColors.surfaceCard)
    .border({
      width: sub.id === this.currentProfileId ? 1.5 : 1,
      color: sub.id === this.currentProfileId ? TunBoxColors.primary : TunBoxColors.cardBorder
    })
    .onClick((): void => {
      if (tapToClose) {
        this.closePanel();
      } else {
        this.onHeaderTap(sub);
      }
    })
  }

  /**
   * 分组 chip。**不要**把「是否选中」作为 @Builder 值参数传进来 —— ArkUI 的
   * @Builder 值参数不参与响应式更新，点完高亮不会切（真机复现：点了没反应）。
   * 这里直接读 state，点击即切换。
   */
  @Builder
  GroupChip(name: string) {
    Text(name)
      .fontSize(12)
      .fontWeight(this.selectedGroup === name ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.selectedGroup === name ? TunBoxColors.textOnPrimary : TunBoxColors.textSecondary)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(TunBoxGeometry.pillRadius)
      .backgroundColor(this.selectedGroup === name ? TunBoxColors.primary : TunBoxColors.chipBg)
      .maxLines(1)
      .flexShrink(0)
      .onClick((): void => { this.selectedGroup = name; })
  }

  /**
   * 节点行（2026-10-28 用户定稿，按 Plus 截图排布）：
   * 左：节点名（主行）+ 协议（小字灰色，名称下方）；中右：延迟；最右：单选圈。
   * 选中行整行浅绿底，行间用细分隔线（不再是独立卡片块）。
   */
  @Builder
  NodeRow(node: ProxyNode) {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text(node.name)
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor(TunBoxColors.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.protoOf(node))
          .fontSize(11).fontColor(TunBoxColors.textMuted)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(this.pingText(node))
        .fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.pingColor(node))
        .flexShrink(0)

      Stack({ alignContent: Alignment.Center }) {
        Circle({ width: 20, height: 20 })
          .fill(this.isActiveNode(node) ? TunBoxColors.success : Color.Transparent)
          .stroke(this.isActiveNode(node) ? TunBoxColors.success : TunBoxColors.textMuted)
          .strokeWidth(1.6)
        if (this.isActiveNode(node)) {
          Circle({ width: 7, height: 7 }).fill(Color.White)
        }
      }.width(20).height(20)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .backgroundColor(this.isActiveNode(node) ? TunBoxColors.successTint : Color.Transparent)
    .border({ width: { bottom: 1 }, color: TunBoxColors.cardBorder })
    .alignItems(VerticalAlign.Center)
    .onClick((): void => { this.selectNode(node); })
  }

  /**
   * 全屏覆盖层（2026-10-28 第二次定稿）：
   * 顶部不再是标题栏，而是**订阅卡片本身当固定表头**（点卡片或底部按钮都可返回）；
   * 其下只有订阅自带的分组 chips（不再有「全部」「按延迟」），再下面是节点列表。
   */
  @Builder
  NodePanelCover() {
    Column({ space: 0 }) {
      Column({ space: 10 }) {
        if (this.panelSub() !== null) {
          this.SubCard(this.panelSub() as Subscription, true)
        }

        // 分组 chips + 排序方式同一行（分组左、排序右；分组多了左侧横向滚动）
        Row({ space: 8 }) {
          Scroll() {
            Row({ space: 8 }) {
              if (this.groupsOf(this.panelSubId).length > 0) {
                ForEach(this.groupsOf(this.panelSubId), (g: ProxyGroup) => {
                  this.GroupChip(g.name)
                }, (g: ProxyGroup) => `${g.subscriptionId}|${g.name}`)
              }
            }
            .padding({ left: TunBoxGeometry.pagePadding, right: 8 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .layoutWeight(1)

          Row({ space: 4 }) {
            Image($r('app.media.ic_sort')).width(13).height(13).fillColor(TunBoxColors.textMuted)
            Text(this.sortByDelay ? '按延迟' : '原始')
              .fontSize(11).fontColor(TunBoxColors.textMuted).maxLines(1)
          }
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(TunBoxGeometry.pillRadius)
          .backgroundColor(TunBoxColors.chipBg)
          .margin({ right: TunBoxGeometry.pagePadding })
          .accessibilityText('切换节点排序')
          .onClick((): void => { this.sortByDelay = !this.sortByDelay; })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })

      if (this.panelNodes().length === 0) {
        Column({ space: 6 }) {
          Text('该分组暂无可用节点')
            .fontSize(13).fontColor(TunBoxColors.textMuted)
          Text('换一个分组，或用卡片上的刷新按钮更新订阅')
            .fontSize(11).fontColor(TunBoxColors.textMuted)
        }
        .width('100%')
        .padding({ top: 40 })
        .alignItems(HorizontalAlign.Center)
        .layoutWeight(1)
      } else {
        List({ space: 0 }) {
          ForEach(this.panelNodes(), (node: ProxyNode) => {
            ListItem() {
              this.NodeRow(node)
            }
          }, (node: ProxyNode) => `${node.id}|${this.selectedGroup}|${this.latencyRevision}|${this.coreRevision}|${this.sortByDelay}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: TunBoxGeometry.pagePadding, right: TunBoxGeometry.pagePadding })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }

      // 底部返回：与页面背景同色，融为一体
      Button('返回')
        .width('100%')
        .height(44)
        .fontSize(14)
        .fontColor(TunBoxColors.textPrimary)
        .backgroundColor(TunBoxColors.background)
        .borderRadius(TunBoxGeometry.controlRadius)
        .margin({ left: TunBoxGeometry.pagePadding, right: TunBoxGeometry.pagePadding, top: 4, bottom: 12 })
        .onClick((): void => this.closePanel())
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TunBoxColors.background)
    .padding({ top: this.statusBarH })
  }

  build() {
    Column({ space: 10 }) {
      this.SectionHeader()

      if (this.subs.length === 0) {
        Row({ space: 8 }) {
          Image($r('app.media.ic_nodes')).width(18).height(18).fillColor(TunBoxColors.textMuted)
          Text('还没有订阅，点右上菜单「添加订阅」')
            .fontSize(12).fontColor(TunBoxColors.textMuted)
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding(TunBoxGeometry.cardPadding)
        .borderRadius(TunBoxGeometry.cardRadiusSmall)
        .backgroundColor(TunBoxColors.surfaceCard)
        .border({ width: 1, color: TunBoxColors.cardBorder })
        .onClick((): void => { this.addDialog.open(); })
      } else {
        ForEach(this.subs, (sub: Subscription) => {
          this.SubCard(sub, false)
        }, (sub: Subscription) => `${sub.id}|${this.currentProfileId}|${this.currentNodeName}`
          + `|${sub.uploadBytes}|${sub.downloadBytes}|${this.refreshingIds.length}|${this.testingIds.length}`)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .bindContentCover(this.showPanel, this.NodePanelCover(), {
      modalTransition: ModalTransition.DEFAULT,
      backgroundColor: TunBoxColors.background,
      onDisappear: (): void => {
        this.showPanel = false;
      }
    })
  }
}
