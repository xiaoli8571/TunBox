/**
 * SubscriptionPage —— 订阅与节点页（严格对齐《TunBox-UI重构笔记》§3.2）
 * 布局：TopNav(单列/双列切换 · 刷新全部 · 添加订阅) → 全局概览卡
 *       → 内核智能优选条目（行尾带「内核组测速」按钮）
 *       → 折叠式订阅分组（展开后显示该订阅下的节点并单选；2026-10-17 用户要求去掉全量节点区）
 * 后端：复用 SubscriptionService / SettingsService / LatencyController / BackgroundLatencyService 全量逻辑。
 */
import { router, promptAction } from '@kit.ArkUI';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import scanBarcode from '@hms.core.scan.scanBarcode';
import { BusinessError } from '@kit.BasicServicesKit';
import { TunBoxColors, TunBoxGeometry, TunBoxPing } from '../theme/TunBoxTokens';
import { TopNavBar } from '../components/TopNavBar';
import { TabLifecycleBridge } from '../commons/utils/TabLifecycleBridge';
import { SubscriptionService, DIRECT_GROUP_ID } from '../commons/services/SubscriptionService';
import { Subscription, SubscriptionRefreshStatus } from '../commons/models/Subscription';
import { ProxyNode } from '../commons/models/ProxyNode';
import { NodeUsability } from '../commons/subscription/NodeUsability';
import { SubscriptionFetchPolicy } from '../commons/services/SubscriptionFetchPolicy';
import { SettingsService } from '../commons/services/SettingsService';
import { AppSettings, AutoSelectModes } from '../commons/models/AppSettings';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';
import { ClashApiService } from '../commons/services/ClashApiService';
import { AppLogger } from '../commons/utils/AppLogger';
import { ProfileStore } from '../commons/flclash/ProfileStore';
import { CoreCatalogService } from '../commons/flclash/CoreCatalogService';
import { CoreNodeBridge } from '../commons/flclash/CoreNodeBridge';
import { LatencyStoreBridge } from '../commons/services/LatencyStoreBridge';
import { effectiveTestUrl } from '../commons/latency/LatencyProbe';


// 【2026-10-22 · FlClash 同构】不再从 App 侧台账取"定义不完整/信息条目"判词
// （`UnusableRecord` / `UnusableCategory` 的导入已删除 —— 节点可用性归内核）。
import { NodeProtocolPolicy } from '../commons/services/NodeSortPersistence';
import { BackgroundLatencyService } from '../commons/services/BackgroundLatencyService';
import {
  ConcurrentRefresh, RefreshBatchProgress, RefreshItemOutcome
} from '../commons/services/ConcurrentRefresh';

const TAG = 'SubscriptionPage';

/** “+”导入三选一弹窗（扫描 / URL / 文件），对齐 HTML import-overlay */
@CustomDialog
struct ImportDialog {
  controller?: CustomDialogController;
  @State mode: string = 'main';
  @State urlText: string = '';
  onScan: () => void = () => {};
  onUrl: (url: string) => void = () => {};
  onFile: () => void = () => {};

  aboutToAppear(): void {
    this.mode = 'main';
  }

  @Builder
  OptionBtn(icon: string, title: string, desc: string, bg: ResourceColor, fg: ResourceColor, target: string) {
    Row({ space: 14 }) {
      Text(icon).fontSize(20).fontColor(fg)
        .width(40).height(40).textAlign(TextAlign.Center)
        .borderRadius(10).backgroundColor(bg)
      Column({ space: 1 }) {
        Text(title).fontSize(14).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary).width('100%')
        Text(desc).fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .borderRadius(12)
    .backgroundColor(TunBoxColors.surfaceCard)
    .borderWidth(1).borderColor(TunBoxColors.cardBorder)
    .onClick(() => {
      this.mode = target;
    })
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Text(this.mode === 'main' ? '导入订阅' : (this.mode === 'scan' ? '扫码导入' : (this.mode === 'url' ? '从 URL 链接导入' : '从本地文件导入')))
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
        Image($r('app.media.ic_close'))
          .width(16).height(16)
          .fillColor(TunBoxColors.textMuted)
          .padding(6)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
      }.width('100%')

      if (this.mode === 'main') {
        this.OptionBtn('☷', '扫描', '扫描屏幕或纸质二维码导入订阅',
          TunBoxColors.successLight, TunBoxColors.success, 'scan')
        this.OptionBtn('🔗', 'URL', '仅支持 Clash 订阅链接或单节点链接',
          TunBoxColors.primaryLight, TunBoxColors.primary, 'url')
        this.OptionBtn('📄', '文件', '仅支持本地 Clash 配置文件（.yaml / .yml）',
          'rgba(245, 158, 11, 0.12)', TunBoxColors.warning, 'file')
      } else if (this.mode === 'scan') {
        Column() {
          Text('[ 摄像头：请在系统扫码页对准二维码 ]')
            .fontSize(12).fontColor(TunBoxColors.success)
            .width('100%').textAlign(TextAlign.Center)
            .padding(30).borderRadius(10)
            .backgroundColor('#0f172a')
            .borderWidth(1).borderColor('rgba(16, 185, 129, 0.50)')
        }.width('100%')
        Row({ space: 8 }) {
          Button('返回').layoutWeight(1).borderRadius(8)
            .backgroundColor(TunBoxColors.surfaceSubtle).fontColor(TunBoxColors.textPrimary).fontSize(13)
            .onClick(() => { this.mode = 'main'; })
          Button('开始扫码').layoutWeight(1).borderRadius(8)
            .backgroundColor(TunBoxColors.primary).fontColor(Color.White).fontSize(13)
            .onClick(() => {
              if (this.controller !== undefined) {
                this.controller.close();
              }
              this.onScan();
            })
        }.width('100%').margin({ top: 2 })
      } else if (this.mode === 'url') {
        // 用户口径（2026-10-22）：这个入口只收订阅链接，单节点链接不再从这里导入
        // （单节点要走「设置 → 订阅转换」或节点编辑页），文案不要再提 vless/ss。
        Text('输入 Clash 订阅链接：').fontSize(12).fontColor(TunBoxColors.textMuted).width('100%')
        TextArea({ placeholder: 'https://...（Clash 订阅链接）', text: this.urlText })
          .onChange((v: string) => { this.urlText = v; })
          .height(88).borderRadius(8).fontSize(13)
          .backgroundColor(TunBoxColors.surfaceSubtle)
          .borderWidth(1).borderColor(TunBoxColors.cardBorder)
          .fontColor(TunBoxColors.textPrimary)
        Row({ space: 8 }) {
          Button('返回').layoutWeight(1).borderRadius(8)
            .backgroundColor(TunBoxColors.surfaceSubtle).fontColor(TunBoxColors.textPrimary).fontSize(13)
            .onClick(() => { this.mode = 'main'; })
          Button('确认导入').layoutWeight(1).borderRadius(8)
            .backgroundColor(TunBoxColors.primary).fontColor(Color.White).fontSize(13)
            .onClick(() => {
              if (this.controller !== undefined) {
                this.controller.close();
              }
              this.onUrl(this.urlText);
            })
        }.width('100%').margin({ top: 2 })
      } else {
        Column({ space: 2 }) {
          Text('选择本地 Clash 配置文件（.yaml / .yml）').fontSize(13).fontWeight(FontWeight.Bold)
            .fontColor(TunBoxColors.textPrimary).width('100%').textAlign(TextAlign.Center)
          Text('支持 .yaml / .yml（Clash 配置）').fontSize(11).fontColor(TunBoxColors.textMuted)
            .width('100%').textAlign(TextAlign.Center)
        }.width('100%').padding(16).borderRadius(8)
        .borderWidth(1.5).borderColor(TunBoxColors.cardBorder)
        Row({ space: 8 }) {
          Button('返回').layoutWeight(1).borderRadius(8)
            .backgroundColor(TunBoxColors.surfaceSubtle).fontColor(TunBoxColors.textPrimary).fontSize(13)
            .onClick(() => { this.mode = 'main'; })
          Button('选择文件').layoutWeight(1).borderRadius(8)
            .backgroundColor(TunBoxColors.primary).fontColor(Color.White).fontSize(13)
            .onClick(() => {
              if (this.controller !== undefined) {
                this.controller.close();
              }
              this.onFile();
            })
        }.width('100%').margin({ top: 2 })
      }
    }
    .padding(20)
    .borderRadius(20)
    // 沉浸光感适配（官方《组件适配沉浸光感》+《沉浸光感常见问题》）：应用级 enable
    // 后 CustomDialog 默认 ULTRA_THICK 沉浸材质背板；材质层级位于背景色/背景模糊之下，
    // 不透明背景色、背景模糊与自定义 shadow 都会遮挡材质（官方反模式），根容器不再设置，
    // 视觉交给系统材质统一接管；内容层（行卡片/输入框/按钮）样式保持不动。
  }
}

@CustomDialog
struct DeleteConfirmDialog {
  controller?: CustomDialogController;
  onConfirm: () => void = () => {};

  build() {
    Column({ space: 14 }) {
      Text('确认删除').fontSize(18).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
      Text('删除后将无法恢复，确定要删除吗？')
        .fontSize(13).fontColor(TunBoxColors.textMuted).textAlign(TextAlign.Center)
      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).borderRadius(10)
          .backgroundColor(TunBoxColors.surfaceSubtle).fontColor(TunBoxColors.textPrimary)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button('删除').layoutWeight(1).borderRadius(10)
          .backgroundColor(TunBoxColors.danger).fontColor(Color.White)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onConfirm();
          })
      }.width('100%')
    }
    .padding(24).borderRadius(20)
    // 沉浸光感适配（官方《组件适配沉浸光感》+《沉浸光感常见问题》）：应用级 enable
    // 后 CustomDialog 默认 ULTRA_THICK 沉浸材质背板；材质层级位于背景色/背景模糊之下，
    // 不透明背景色、背景模糊与自定义 shadow 都会遮挡材质（官方反模式），根容器不再设置，
    // 视觉交给系统材质统一接管；内容层（按钮）样式保持不动。
  }
}

/**
 * 长按节点后的单节点删除确认框。
 * 语义与 NodeSelectionPage.NodeDeleteDialog 一致：删除 = 移出节点表并记入隐藏清单，
 * 后续订阅刷新自动过滤，被删节点不会"复活"。
 */
@CustomDialog
struct NodeDeleteConfirmDialog {
  controller?: CustomDialogController;
  getNodeName: () => string = (): string => '';
  onConfirm: () => void = () => {};

  build() {
    Column({ space: 14 }) {
      Text('删除节点').fontSize(18).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
      Text(`确定删除「${this.getNodeName()}」吗？该节点在订阅刷新后不会再出现。`)
        .fontSize(13).fontColor(TunBoxColors.textMuted).textAlign(TextAlign.Center)
      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).borderRadius(10)
          .backgroundColor(TunBoxColors.surfaceSubtle).fontColor(TunBoxColors.textPrimary)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button('删除').layoutWeight(1).borderRadius(10)
          .backgroundColor(TunBoxColors.danger).fontColor(Color.White)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onConfirm();
          })
      }.width('100%')
    }
    .padding(24).borderRadius(20)
    // 沉浸光感适配（官方《组件适配沉浸光感》+《沉浸光感常见问题》）：应用级 enable
    // 后 CustomDialog 默认 ULTRA_THICK 沉浸材质背板；材质层级位于背景色/背景模糊之下，
    // 不透明背景色、背景模糊与自定义 shadow 都会遮挡材质（官方反模式），根容器不再设置，
    // 视觉交给系统材质统一接管；内容层（按钮）样式保持不动。
  }
}

@CustomDialog
struct EditSubscriptionDialog {
  controller?: CustomDialogController;
  @State editName: string = '';
  @State editUrl: string = '';
  @State isLocal: boolean = false;
  getInitialName: () => string = () => '';
  getInitialUrl: () => string = () => '';
  getIsLocal: () => boolean = () => false;
  onConfirm: (name: string, url: string) => void = () => {};

  aboutToAppear(): void {
    this.editName = this.getInitialName();
    this.editUrl = this.getInitialUrl();
    this.isLocal = this.getIsLocal();
  }

  build() {
    Column({ space: 14 }) {
      Text('编辑订阅').fontSize(16).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
      TextInput({ placeholder: '订阅名称', text: this.editName })
        .onChange((v: string) => { this.editName = v; })
        .height(40).borderRadius(8).fontSize(13)
        .backgroundColor(TunBoxColors.surfaceSubtle)
        .borderWidth(1).borderColor(TunBoxColors.cardBorder)
        .fontColor(TunBoxColors.textPrimary)
      if (!this.isLocal) {
        TextInput({ placeholder: '订阅链接', text: this.editUrl })
          .onChange((v: string) => { this.editUrl = v; })
          .height(40).borderRadius(8).fontSize(13)
          .backgroundColor(TunBoxColors.surfaceSubtle)
          .borderWidth(1).borderColor(TunBoxColors.cardBorder)
          .fontColor(TunBoxColors.textPrimary)
      } else {
        Text('本地导入的订阅仅支持改名')
          .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
      }
      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).borderRadius(8)
          .backgroundColor(TunBoxColors.surfaceSubtle).fontColor(TunBoxColors.textPrimary).fontSize(13)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button('保存').layoutWeight(1).borderRadius(8)
          .backgroundColor(TunBoxColors.primary).fontColor(Color.White).fontSize(13)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onConfirm(this.editName, this.editUrl);
          })
      }.width('100%')
    }
    .padding(20).borderRadius(20)
    // 沉浸光感适配（官方《组件适配沉浸光感》+《沉浸光感常见问题》）：应用级 enable
    // 后 CustomDialog 默认 ULTRA_THICK 沉浸材质背板；材质层级位于背景色/背景模糊之下，
    // 不透明背景色、背景模糊与自定义 shadow 都会遮挡材质（官方反模式），根容器不再设置，
    // 视觉交给系统材质统一接管；内容层（输入框/按钮）样式保持不动。
  }
}

@Component
export struct SubscriptionPage {
  @StorageLink('theme_revision') themeRevision: number = 0;
  /** 宿主（MainPage）「重新展示」通知桥：替代 @Entry 页面的 onPageShow（见 TabLifecycleBridge） */
  shownBridge?: TabLifecycleBridge;
  @State subs: Subscription[] = [];
  @State expandedIds: string[] = [];
  @State activeSubId: string = '';
  /**
   * 内核节点视图（FlClash 同构）：当前 Profile 的节点清单来自内核 `/proxies`，
   * 而不是 App 侧解析表。为空时回落旧解析表（离线/内核未起）。
   */
  @State coreNodes: ProxyNode[] = [];
  /** 「N 个候选」的可渲染副本（见 syncCandidateCount 注释：方法内读取不算 ArkUI 依赖） */
  @State candidateCount: number = 0;
  /** `coreNodes` 是哪份 profile 的目录（空 = 未知，不能用它算数量） */
  private coreNodesProfileId: string = '';
  /** 最近一次 activateProfile 的目标与时间（防抖用） */
  private activatedId: string = '';
  private activatedAt: number = 0;
  @State activeNodeId: string = '';
  /**
   * 「当前连接节点」显示值 —— 只用 orchestrator.displayNodeName 解析，与主页启动
   * 按钮同源同结果（2026-10-25 用户要求）。不要在这里另写取值逻辑。
   */
  @State currentNodeName: string = '';
  /** 自动选点模式（manual 手动固定 / auto 内核 smart 优选），与设置页同一份持久化 */
  @State autoSelectMode: string = AutoSelectModes.MANUAL;
  /**
   * 内核 smart 选点模型（Model.bin）是否可用。
   *
   * 用户口径（2026-10-22）：模型**不随包内置、也不在启动代理后自动下载**；
   * 没有模型时订阅页顶部的「自动选择 · 内核智能优选」整块隐藏 —— 大部分用户
   * 用不到自动优选，留一个点不动的入口只会制造疑问。
   */
  @State smartModelReady: boolean = false;
  /**
   * 模型删除/更新信号：设置页删除或更新 Model.bin 后自增。
   *
   * 【2026-10-22 真机 bug 修复】原来只在 build 里调 `smartModelOn()`（方法调用，
   * 不读任何状态），ArkUI 不会把它登记成本组件的依赖 —— 用户在设置里删掉模型、
   * 回到订阅页，卡片仍然挂着（用户实锤「我删了，没有隐藏」）。
   * 现在：seq 变化 ⇒ @Watch 重算 @State smartModelReady ⇒ build 真的重跑。
   */
  @StorageLink('smart_model_seq') @Watch('onSmartModelSeq') smartModelSeq: number = 0;
  /** 节点排布列数（1=单列 2=双列），用户在订阅分组展开区手动切换，选择持久化 */
  @State nodeColumns: number = 1;
  @State latencyTick: number = 0;
  @State isAdding: boolean = false;
  @State isRefreshing: boolean = false;
  @State refreshingIds: string[] = [];
  /** 分组头闪电测速按钮的防重入（对齐 refreshingIds 语义） */
  @State speedTestingIds: string[] = [];
  /** 内核组测速（整组）在途标记：一次请求、内核并发测完全部节点 */
  @State groupTesting: boolean = false;
  @State isImporting: boolean = false;
  @State isScanning: boolean = false;
  @State toastMsg: string = '';
  @State toastVisible: boolean = false;
  @State deleteTargetId: string = '';
  /** tunbox://import 导入请求 seq（EntryAbility.captureImportScheme 发布，@Watch 即时消费） */
  @StorageLink('import_request_seq') @Watch('onImportRequest') importRequestSeq: number = 0;
  /** 长按删除单个节点目标（确认框标题展示用） */
  @State deleteNodeTargetName: string = '';
  private deleteNodeTargetId: string = '';
  /**
   * 批量多选（2026-10-20，与节点页同一交互）：长按任一节点卡片进入选择态，
   * 卡片左上角圆圈变成勾选，底部浮出「取消 · 已选 N · 全选 · 删除」操作条。
   * 删除复用 SubscriptionService.removeNode（本地屏蔽台账：刷新后不再出现）。
   */
  @State nodeSelectMode: boolean = false;
  @State selectedNodeIds: string[] = [];
  @State spinTick: number = 0;
  private service: SubscriptionService = SubscriptionService.instance();
  private settings: AppSettings = new AppSettings();
  private readonly latencyListener: () => void = (): void => {
    this.latencyTick = this.latencyTick + 1;
  };
  private latencyBound: boolean = false;
  private deleteDialog: CustomDialogController = new CustomDialogController({
    builder: DeleteConfirmDialog({
      onConfirm: () => {
        this.doDelete(this.deleteTargetId);
      }
    })
  });
  /** 删除确认框（单个/批量共用：getNodeName 传的是节点名或「A、B、C 等 N 个节点」摘要） */
  private deleteNodeDialog: CustomDialogController = new CustomDialogController({
    builder: NodeDeleteConfirmDialog({
      getNodeName: (): string => this.deleteNodeTargetName,
      onConfirm: () => {
        this.doDeleteSelectedNodes();
      }
    }),
    autoCancel: true
  });
  private editTarget: Subscription | null = null;
  private editDialog: CustomDialogController = new CustomDialogController({
    builder: EditSubscriptionDialog({
      getInitialName: (): string => this.editTarget !== null ? this.editTarget.name : '',
      getInitialUrl: (): string => this.editTarget !== null ? this.editTarget.url : '',
      getIsLocal: (): boolean => this.editTarget !== null && this.editTarget.url.startsWith('local://'),
      onConfirm: (name: string, url: string) => {
        this.doEdit(name, url);
      }
    }),
    autoCancel: true
  });
  private importDialog: CustomDialogController = new CustomDialogController({    builder: ImportDialog({
      onScan: () => {
        this.importFromQr();
      },
      onUrl: (url: string) => {
        this.importFromUrl(url);
      },
      onFile: () => {
        this.importYamlFile();
      }
    }),
    autoCancel: true
  });

  aboutToAppear(): void {
    // 作为 HdsTabs 页签内容组件（非 @Entry 页）后：页签「重新展示」由宿主经桥通知，
    // 语义等价于原 onPageShow（从子页返回 / 首次切入 / 切回页签时刷新）。
    if (this.shownBridge !== undefined) {
      this.shownBridge.setShowHandler((): void => { this.refreshForShown(); });
    }
    // tunbox://import scheme（P1-3c）：@StorageLink 即时响应外部导入请求
    // （EntryAbility.captureImportScheme 解析 tunbox://import?url=… 后发布）。
    this.importRequestSeq = AppStorage.get<number>('import_request_seq') ?? 0;
  }

  /** 宿主通知的「重新展示」：执行原 onPageShow 的刷新 */
  refreshForShown(): void {
    this.bootstrap();
  }

  /** tunbox://import scheme 消费（P1-3c）：seq 变化即取 url 导入（一次性，取后清空） */
  onImportRequest(): void {
    const pendingUrl = AppStorage.get<string>('import_request_url') ?? '';
    if (pendingUrl.length === 0) {
      return;
    }
    AppStorage.setOrCreate('import_request_url', '');
    this.importFromUrl(pendingUrl).catch((): void => {});
  }

  aboutToDisappear(): void {
    if (this.shownBridge !== undefined) {
      this.shownBridge.setShowHandler(null);
    }
    if (this.latencyBound) {
      LatencyStoreBridge.removeListener(this.latencyListener);
      this.latencyBound = false;
    }
  }

  private async bootstrap(): Promise<void> {
    const ctx = getContext(this) as Context;
    ConnectionOrchestrator.instance().init(ctx);
    await SettingsService.init(ctx);
    await this.service.init(ctx);
    this.settings = await SettingsService.load();
    // 当前 Profile 是唯一真源（FlClash currentProfileId）；旧偏好只作回落。
    const currentProfile = ProfileStore.currentId();
    this.activeSubId = currentProfile.length > 0
      ? currentProfile : this.settings.preferredNodeSubscriptionId;
    // 作用域化：旧偏好指向其他订阅时不算「已选」（findNode 全局搜会拿错）
    const scopedPreferred = this.service.preferredNodeInCurrentProfile(this.settings.preferredNodeId);
    this.activeNodeId = scopedPreferred !== null ? scopedPreferred.id : '';
    this.autoSelectMode = AutoSelectModes.normalize(this.settings.autoSelectMode);
    // 只查模型是否已就位（本地文件判断，不播种、不下载、不联网）
    this.smartModelReady = ConnectionOrchestrator.instance().isSmartModelAvailable();
    this.nodeColumns = await SettingsService.loadNodeColumns();
    this.reload();
    this.refreshDisplayNode();
    if (!this.latencyBound) {
      this.latencyBound = true;
      LatencyStoreBridge.addListener(this.latencyListener);
    }
    // 预热测速通道（真机取证 2026-10-20）：「点了测速要等几秒才开始」的根因是
    // 测速通道的准备（未连接时要拉起 headless 测速内核）。进页面时后台把这段
    // 准备做完，用户点「测速」时通道已热 → 秒开。预热失败不影响任何功能。
    // 先预热测速通道（必要时拉起无头内核），就绪后再拉内核节点目录：
    // 目录是 `/proxies` 的实时数据，内核没起来时拉不到（FlClash 同样要求 core 在线）。
    BackgroundLatencyService.prewarmChannel(ctx)
      .then((): void => { this.refreshCoreNodes(); })
      .catch((): void => {});
  }

  private expandedInitialized: boolean = false;

  private reload(): void {
    this.subs = this.service.subscriptions.filter((s: Subscription) =>
      s.id !== DIRECT_GROUP_ID || s.nodeCount > 0);
    this.syncCandidateCount();
    // 展开状态只在首次进入时给默认值（活动订阅）；此后删/加订阅一律保持
    // 用户当前的展开/收起状态，不重置（此前 expandedIds 空了就自动展开第一个，
    // 表现为"每次删/加订阅都自动展开第一个分组"）。
    if (!this.expandedInitialized) {
      this.expandedInitialized = true;
      if (this.subs.length > 0) {
        const first = this.subs.find((s) => s.id === this.activeSubId) ?? this.subs[0];
        this.expandedIds = [first.id];
      }
    }
    // 同步活动节点展示。
    // ⚠ 影子节点（core:<name>）在解析表里找不到是**正常**的（节点来自内核）。
    // 【2026-10-25 二次修】兜底**只在当前订阅内**找展示替身，且**永不改 activeSubId**
    // —— 旧实现回落 nodes[0]（全表第一个，别家订阅）并把 activeSubId 一起带跑，
    // 顶部「当前使用订阅组」就跳到别的机场（真机两次实锤：oc2 节点/飞鸟云顶栏）。
    const node = this.service.findNode(this.activeNodeId);
    if (node === null && !this.activeNodeId.startsWith('core:')) {
      const current = ProfileStore.currentId();
      const scoped = this.service.nodesOf(current)
        .find((n: ProxyNode): boolean => !NodeUsability.isInfoEntry(n.name));
      if (scoped !== undefined) {
        this.activeNodeId = scoped.id;
      }
    }
  }

  private showToast(msg: string): void {
    this.toastMsg = msg;
    this.toastVisible = true;
    setTimeout(() => {
      this.toastVisible = false;
    }, 2400);
  }

  /** 节点排布单列/双列切换（订阅分组始终单行），选择经 SettingsService 持久化 */
  private toggleNodeColumns(): void {
    const next = this.nodeColumns === 2 ? 1 : 2;
    this.nodeColumns = next;
    SettingsService.saveNodeColumns(next);
    this.showToast(next === 2 ? '节点已切换为双列排布' : '节点已切换为单列排布');
  }

  /**
   * 节点卡片（文档 §3.2 节点网格）：两行信息列 —— 名称行（Radio 单选 + 名称）+
   * 协议行（协议标签 + 延迟文本）。单列/双列均由 GridRow 控宽，卡片自身 100% 填充。
   */
  @Builder
  nodeCard(node: ProxyNode) {
    Column({ space: 8 }) {
      // 第一行：单选圆圈 + 节点名称
      Row({ space: 6 }) {
        Stack({ alignContent: Alignment.Center }) {
          Circle({ width: 16, height: 16 })
            .fill(this.nodeSelectMode
              ? (this.isNodeSelected(node.id) ? TunBoxColors.primary : Color.Transparent)
              : (node.id === this.activeNodeId ? TunBoxColors.primary : Color.Transparent))
            .stroke(this.nodeSelectMode
              ? (this.isNodeSelected(node.id) ? TunBoxColors.primary : TunBoxColors.textMuted)
              : (node.id === this.activeNodeId ? TunBoxColors.primary : TunBoxColors.textMuted))
            .strokeWidth(1.6)
          if (this.nodeSelectMode ? this.isNodeSelected(node.id) : node.id === this.activeNodeId) {
            Circle({ width: 5, height: 5 }).fill(TunBoxColors.textOnPrimary)
          }
        }.width(16).height(16)
        Text(node.name)
          .fontSize(12).fontWeight(FontWeight.Medium).fontColor(TunBoxColors.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      // 第二行：协议标签 + 延迟
      Row() {
        Text(this.protoOf(node))
          .fontSize(10).fontColor(TunBoxColors.textSecondary)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor(TunBoxColors.chipBg)
          .borderRadius(4)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank()
        Text(this.nodePingText(node))
          .fontSize(11).fontWeight(FontWeight.Bold)
          .fontColor(this.nodePingColor(node))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(12)
    .borderRadius(16)
    .backgroundColor(TunBoxColors.surfaceCard)
    .border({
      width: node.id === this.activeNodeId ? 1.5 : 1,
      color: node.id === this.activeNodeId ? TunBoxColors.primary : TunBoxColors.cardBorder
    })
    .onClick(() => this.onNodeCardTap(node))
    // 长按进入批量多选（2026-10-20）：先勾上被长按的这个节点
    .gesture(LongPressGesture().onAction(() => {
      if (this.nodeSelectMode) {
        return;
      }
      this.enterNodeSelectMode(node.id);
    }))
  }

  /** 选择态下点卡片 = 勾选/取消；平时 = 选中该节点为当前出口 */
  private onNodeCardTap(node: ProxyNode): void {
    if (this.nodeSelectMode) {
      this.toggleSelectedNode(node.id);
      return;
    }
    this.selectNode(node);
  }

  private isOpen(id: string): boolean {
    return this.expandedIds.includes(id);
  }


  // 【2026-10-22 · FlClash 同构】这里原来有 `incompleteCount` / `incompleteHint` /
  // `infoCount` / `infoHint`（"N 条定义不完整 / N 条信息条目已跳过"角标与说明）。
  // 全部删除：**App 侧不再对节点下可用性判词** —— 订阅原文直接作为内核配置基底
  // （`ProfileConfigMerger`），节点在不在、能不能用由内核 `/proxies` 说了算；
  // App 再给一份结论必然与内核分叉（真机实证：同 server:port 两条节点串台，
  // 一条内核能用的节点被误标「定义不完整」）。

  /**
   * 订阅的**组级诊断**（空串 = 没有同因失败）。
   *
   * 聚合口径与结论文案都归测速内核（LatencyStore.summarize），
   * 这里只取结论那一行；节点页与订阅页共用同一句文案。
   */
  /** 「自动选择」入口是否该显示：模型必须真的在盘上（删掉就隐藏，用户要求） */
  private smartModelOn(): boolean {
    return this.smartModelReady;
  }

  /** 模型文件被更新/删除（设置页 bump smart_model_seq）：同步重算入口可见性 */
  onSmartModelSeq(): void {
    this.smartModelReady = ConnectionOrchestrator.instance().isSmartModelAvailable();
  }

  /**
   * 订阅头部点击（FlClash 语义）：**切换当前 Profile** + 展开。
   *
   * 同一时刻只有一份 profile 生效（FlClash 的 currentProfileId），切换后按
   * `applyProfileDebounce` 等价语义热重载内核配置（VPN 不断开）。
   */
  /**
   * 把某订阅设为当前 Profile，并**等内核配置真的切过去**再返回。
   *
   * FlClash 的 profile 切换是原子的：App 侧 currentProfileId 改了、内核也换成新配置，
   * 之后再读 `/proxies` 才是新订阅的节点。少了这一步就会出现
   * 「界面显示 A 订阅的卡片、节点却是 B 订阅的」/「测速完成但全是 --」。
   */
  private async activateProfile(id: string): Promise<void> {
    if (id.length === 0 || id === DIRECT_GROUP_ID) {
      return;
    }
    // FlClash 语义：切 profile 的前提是这份 profile **已经有内容**（原文落盘）。
    // 没落盘就切过去，内核拿不到基底会退回「全部订阅合并」的旧配置，
    // 于是这个订阅里全是别人的节点（真机实锤：飞鸟云刷新超时后出现另外三个订阅的节点）。
    if (!ProfileStore.exists(id)) {
      // 没有原文：先自动拉一次（FlClash `checkAndUpdateAndCopy` 同语义），
      // 拉不到就不切 —— 绝不能带着空基底切过去。
      this.showToast('该订阅还没有内容，正在刷新…');
      const refreshed = await this.service.refreshSubscription(id);
      this.reload();
      if (!ProfileStore.exists(id)) {
        this.showToast(refreshed.status === SubscriptionRefreshStatus.OK
          ? '刷新成功但没有解析出可用节点'
          : '刷新失败，请开启代理再次刷新');
        return;
      }
    }
    // 防抖：同一 id 在 800ms 内重复调用（onPageShow + bootstrap + 点击 会同时触发）
    // 会重复拉内核目录、甚至把 profile 又切回去，界面表现为节点一直闪。
    const now = Date.now();
    if (this.activatedId === id && now - this.activatedAt < 800) {
      return;
    }
    this.activatedId = id;
    this.activatedAt = now;
    const previous = ProfileStore.currentId();
    if (previous !== id) {
      await ProfileStore.setCurrent(id);
      this.activeSubId = id;
      this.coreNodes = [];
      this.coreNodesProfileId = '';
      this.syncCandidateCount();
      this.latencyTick = this.latencyTick + 1;
    }
    try {
      await ConnectionOrchestrator.instance().ensureProfileApplied('subscription-page');
    } catch (e) {
      AppLogger.warn(TAG, `ensure profile applied failed: ${AppLogger.errText(e)}`);
    }
    // 出口 IP 卡片必须跟着订阅走（2026-10-25 用户报障：切到别的订阅后公网 IP
    // 仍显示上一个订阅节点的出口）。
    // 根因：HomePage 的公网 IP 只在 after-connect / after-disconnect / node-switched
    // 三个钩子上刷新，而「切换订阅」走的是 ensureProfileApplied → 自动选择模式下
    // 会经 reconnectWithNode 重建隧道，但那条路径直接作用于 orchestrator，
    // HomePage 的 applyConnectResult 不会被执行 → 没有任何一方推进
    // public_ip_revision → 卡片保留旧值。内核与实际出口其实已经切过去了
    // （真机日志：`profile applied: ... -> 34df6fd6 (tunnel)` 之后内核配置里
    //  旧订阅节点归零），只是 UI 没有重新取数。
    // 这里在配置应用完成后统一推进一次 revision：无论本次是完整重连还是热重载，
    // 出口都可能已经变化，让 HomePage 重新查询是安全且必要的最小动作。
    const publicIpRevision: number = AppStorage.get<number>('public_ip_revision') ?? 0;
    AppStorage.setOrCreate('public_ip_revision', publicIpRevision + 1);
    // 配置就绪后再拉内核目录，保证显示的就是这份 profile 的节点
    let api: ClashApiService | null = null;
    try {
      api = await ConnectionOrchestrator.instance().ensureLatencyApi();
    } catch (e) {
      api = null;
    }
    await CoreCatalogService.refresh(api, true);
    const nodes = CoreCatalogService.flattenNodes(this.settings.proxyMode);
    this.coreNodes = CoreNodeBridge.toProxyNodes(nodes);
    // 只有内核确认已切到该 profile 时，这份目录才算它的
    const appliedNow = ConnectionOrchestrator.instance().appliedProfile();
    this.coreNodesProfileId = appliedNow === id ? id : '';
    this.syncCandidateCount();
    this.latencyTick = this.latencyTick + 1;
    // 切订阅后节点作用域变了：旧订阅的偏好在这里判无效，卡片要换成新订阅的节点。
    this.refreshDisplayNode();
    AppLogger.info(TAG, `profile activated: id=${id} coreNodes=${this.coreNodes.length} `
      + `previous=${previous}`);
  }

  /**
   * 订阅头部点击：**先展开/收起，再后台切 Profile**。
   *
   * 原来的写法把 toggleOpen 挂在 activateProfile().finally 上，等于「点一下要等
   * 内核 reloadFromPath 跑完（实测 1~5s）才展开」，用户感知就是卡死几秒。
   * 展开是纯 UI 操作，必须同步完成；切 profile 是后台副作用，失败只打日志。
   * 另外点已经激活的订阅不该再重载内核（每次重载都会重连内核、清空目录）。
   */
  private useProfileAndToggle(id: string): void {
    this.toggleOpen(id);
    if (ProfileStore.currentId() === id) {
      return;
    }
    this.activateProfile(id).catch((e: Object): void => {
      AppLogger.warn(TAG, `activate profile failed: ${AppLogger.errText(e)}`);
    });
  }

  private toggleOpen(id: string): void {
    if (this.isOpen(id)) {
      this.expandedIds = this.expandedIds.filter((x) => x !== id);
    } else {
      this.expandedIds = this.expandedIds.concat([id]);
    }
  }

  private activeSub(): Subscription | null {
    const s = this.subs.find((x) => x.id === this.activeSubId);
    if (s !== undefined) {
      return s;
    }
    return this.subs.length > 0 ? this.subs[0] : null;
  }

  /**
   * 刷新「当前连接节点」显示值。
   *
   * 取值**完全委托** `orchestrator.displayNodeName()` —— 与主页启动按钮调用的是
   * 同一个方法、同一套顺序，因此两处显示的必然是同一个节点（2026-10-25 用户要求：
   * 接口完全一致）。
   *
   * 旧实现在这里自己算，且按 `state === CONNECTED` 分叉：未连接时无条件返回
   * 「未选择」，完全无视用户已经手动选好的节点 —— 真机上「手动选了吹雪云节点、
   * 卡片仍显示未选择」就是这么来的。现在不再看连接状态。
   */
  private refreshDisplayNode(): void {
    this.currentNodeName = ConnectionOrchestrator.instance().displayNodeName(
      this.settings.preferredNodeId, this.settings.autoSelectMode);
  }

  /**
   * 内核目录能否用来渲染**当前订阅**。
   *
   * 三个条件同时成立才算：内核生效的 profile == 当前 profile，目录非空，
   * 且目录归属（若已知）也是这份 profile。任何一条不满足就回落解析表 ——
   * 三处展示（概览候选数 / 卡片节点数 / 节点列表）必须用同一个判定，
   * 否则会出现「卡片 24、候选 22」这种自相矛盾的数字。
   */
  private coreNodesUsable(): boolean {
    const current = ProfileStore.currentId();
    if (current.length === 0 || this.coreNodes.length === 0) {
      return false;
    }
    const applied = ConnectionOrchestrator.instance().appliedProfile();
    if (applied !== current) {
      return false;
    }
    return this.coreNodesProfileId.length === 0 || this.coreNodesProfileId === current;
  }

  private totalNodes(): number {
    // FlClash 同构：只有当前 Profile 生效 ⇒ 候选数就是**当前订阅**的节点数。
    // 绝不跨订阅求和（旧实现会回落到「所有订阅节点相加」，切换中出现怪数字）。
    const current = ProfileStore.currentId();
    if (current.length === 0) {
      return 0;
    }
    if (this.coreNodesUsable()) {
      return this.coreNodes.length;
    }
    return this.service.nodesOf(current).length;
  }

  /**
   * 「几个候选」的**可渲染副本**。
   *
   * totalNodes() 内部读的是 this.coreNodes / ProfileStore 这类非直接依赖，
   * ArkUI 的定向刷新不会把「方法内部读取的状态」登记成依赖 —— 表现就是
   * 概览卡的「24 节点」已刷新、智能优选卡的「0 个候选」还停在首帧
   * （2026-10-23 真机：24 节点 vs 0 候选同屏并存）。
   * 所以每次数据源变化后把结果抄进 @State，让 Text 直接依赖它。
   */
  private syncCandidateCount(): void {
    this.candidateCount = this.totalNodes();
  }

  /** 单个订阅卡片的节点数：当前 profile 用内核目录，其它用解析表。 */
  private nodeCountOf(sub: Subscription): number {
    if (sub.id === ProfileStore.currentId() && this.coreNodesUsable()) {
      return this.coreNodes.length;
    }
    // 【2026-10-22 · FlClash 同构】节点数取**原文 proxies 条目数**
    // （FlClash `configCountsOf(loadYaml(profile))` 的口径），不再用 App 解析结果：
    // App 解析不了的协议会被跳过，用它计数会比内核加载的少。
    if (sub.id === DIRECT_GROUP_ID) {
      // 手工直链分组是 App 自己的节点（不在任何 profile 原文里），只能数 App 模型
      return this.service.nodesOf(sub.id).length;
    }
    // 列表用的是 App 解析表（非当前订阅没有内核节点表），数量与列表保持一致，
    // 否则会出现"N 个节点"和实际卡片数对不上（用户实锤 32 vs 23）。
    const listed = this.service.nodesOf(sub.id).length;
    return listed > 0 ? listed : sub.nodeCount;
  }

  /**
   * 协议展示文本（协议标签）：VLESS·REALITY / VMESS / TROJAN / HYSTERIA2 / SS / SSR / 未知。
   *
   * 复用 NodeProtocolPolicy（与 NodeSelectionPage 同一口径），不再用旧的
   * proxyType.toUpperCase().slice(0, 8)：那是把「VLESS」「HYSTERIA2」硬截成
   * 8 字符的土办法，看不出 REALITY，且未知协议直接显示空串。
   */
  private protoOf(node: ProxyNode): string {
    if (CoreNodeBridge.isShadow(node)) {
      return CoreNodeBridge.protocolLabel(node);
    }
    return NodeProtocolPolicy.fromNode(node).display();
  }

  /** 节点延迟文案（TunBoxPing.recordText：五态语义；第二参为页面既有延迟触发变量） */
  private nodePingText(node: ProxyNode): string {
    return TunBoxPing.recordText(LatencyStoreBridge.recordFor(node.name), this.latencyTick);
  }

  /** 节点延迟配色（TunBoxPing.recordColor：实测走阈值，过期/未测中性，手测失败红） */
  private nodePingColor(node: ProxyNode): ResourceColor {
    return TunBoxPing.recordColor(LatencyStoreBridge.recordFor(node.name), this.latencyTick);
  }

  /**
   * 节点按延迟升序（边测边排）：有效延迟小的在前；未测(null)/超时沉底并保持
   * 原相对顺序。ForEach 键含 latencyTick，测速中每批新结果落地（控制器 200ms
   * 合并通知）即重渲染重排，用户实时看到快节点「冒泡」到前面。
   */
  private nodesSortedByLatency(subId: string): ProxyNode[] {
    // FlClash 同构：**只有内核里真正生效的那份 profile** 才用内核目录渲染。
    // 用 currentId 判断会把「刚设成 current、但内核还没换过来」的订阅渲染成
    // 上一份订阅的节点（用户实锤：吹雪云卡片里显示 oc2 的节点）。
    // 三重一致才用内核目录：内核里生效的 profile == 当前 profile == 这张卡片。
    // 任何一处不一致都回落该订阅自己的解析表 —— 宁可显示旧数据，也绝不把别人的节点画进来。
    const source: ProxyNode[] = (subId === ProfileStore.currentId() && this.coreNodesUsable())
      ? this.coreNodes : this.service.nodesOf(subId);
    const arr: ProxyNode[] = source.slice();
    return CoreNodeBridge.sortByDelay(arr, (name: string): number | null => {
      return LatencyStoreBridge.latencyFor(name);
    });
  }

  /** 从内核 `/proxies` 拉一次节点目录（只读渲染用；失败保留上一份）。 */
  private refreshCoreNodes(): void {
    const api = ConnectionOrchestrator.instance().api;
    CoreCatalogService.refresh(api, false).then((model): void => {
      if (model === null) {
        return;
      }
      const nodes = CoreCatalogService.flattenNodes(this.settings.proxyMode);
      this.coreNodes = CoreNodeBridge.toProxyNodes(nodes);
      // 归属用**内核真正生效**的那份 profile（不是 current）：
      // 切换过程中 current 已经变了、内核还是旧的，用 current 标归属会把旧节点
      // 记到新订阅头上（界面上就是「当前订阅是 A、候选数却是 B 的」）。
      this.coreNodesProfileId = ConnectionOrchestrator.instance().appliedProfile();
      this.syncCandidateCount();
      this.latencyTick = this.latencyTick + 1;
      AppLogger.info(TAG, `core catalog nodes=${this.coreNodes.length} `
        + `applied=${this.coreNodesProfileId} current=${ProfileStore.currentId()}`);
    }).catch((e: Object): void => {
      AppLogger.warn(TAG, `core catalog refresh failed: ${AppLogger.errText(e)}`);
    });
  }

  private async selectNode(node: ProxyNode): Promise<void> {
    // 真实节点必须退出自动模式（同 NodeSelectionPage 语义）：否则 orchestrator 的
    // pinSmartGroup 会把 PROXY 指向 smart 组，preferredNodeId 被架空，主页环永远显示“自动选择”。
    if (this.settings.autoSelectMode === AutoSelectModes.AUTO) {
      this.settings.autoSelectMode = AutoSelectModes.MANUAL;
      this.autoSelectMode = AutoSelectModes.MANUAL;
      AppLogger.info(TAG, `manual node pick (${node.name}); auto mode disabled`);
    }
    this.activeNodeId = node.id;
    if (node.subscriptionId.length > 0) {
      this.activeSubId = node.subscriptionId;
    }
    this.settings.preferredNodeId = node.id;
    this.settings.preferredNodeName = node.name;
    if (node.subscriptionId.length > 0) {
      this.settings.preferredNodeSubscriptionId = node.subscriptionId;
      this.settings.selectedSubscriptionId = node.subscriptionId;
    }
    await SettingsService.save(this.settings);
    // 选完立即刷新顶部「当前连接节点」，不等重连完成、也不依赖下次进页面。
    this.refreshDisplayNode();
    // 已连接时完整重连让新节点即时生效；未连接时仅保存选择。
    const didRestart = await ConnectionOrchestrator.instance()
      .reconnectWithNode(node, this.service, 'preferredNode=' + node.id);
    if (didRestart) {
      this.showToast(`已选择 ${node.name}，正在自动重连…`);
      AppStorage.setOrCreate('public_ip_revision', (AppStorage.get<number>('public_ip_revision') ?? 0) + 1);
    } else {
      this.showToast(`已选择 ${node.name}`);
    }
  }

  /**
   * 启用内核智能选点（mihomo-smart LightGBM）：跨全部订阅自动优选出口，
   * 故障自动切换 + 网络变化自动重连由编排器既有策略承担（默认全开）。
   * 语义同节点页 smart 合成行：重连仍需一个真实节点做拨号目标。
   */
  private async enableAutoSelect(): Promise<void> {
    if (this.autoSelectMode === AutoSelectModes.AUTO) {
      this.showToast('已在使用内核智能选点');
      return;
    }
    // 重连目标必须属于当前订阅：跨订阅旧偏好在这里只会让重连钉错节点
    let target: ProxyNode | null = await this.service.resolvePreferredNode();
    if (target === null) {
      target = this.service.fallbackConnectionNode();
    }
    if (target === null) {
      this.showToast('没有可用节点');
      return;
    }
    this.settings.autoSelectMode = AutoSelectModes.AUTO;
    await SettingsService.save(this.settings);
    this.autoSelectMode = AutoSelectModes.AUTO;
    // 模式已变：卡片应立刻显示「♻️ 自动选择」，与主页按钮同步。
    this.refreshDisplayNode();
    const didRestart = await ConnectionOrchestrator.instance()
      .reconnectWithNode(target, this.service, 'autoSelectMode=auto');
    if (didRestart) {
      AppStorage.setOrCreate('public_ip_revision', (AppStorage.get<number>('public_ip_revision') ?? 0) + 1);
    }
    this.showToast(didRestart ? '已启用内核智能选点，正在自动重连…' : '已启用内核智能选点，下次连接生效');
  }

  /**
   * 分组头闪电测速（单个订阅 / **单节点分组**）。
   *
   * 单节点分组（`DIRECT_GROUP_ID`）必须与普通订阅同权：手工导入的节点其
   * `subscriptionId` 就是 DIRECT_GROUP_ID，而 `BackgroundLatencyService.testSubscription`
   * 正是按 `node.subscriptionId` 过滤节点集合 —— 因此它走的是**完全相同**的
   * LatencyEngine 路径，没有任何特殊之处。此前这里把 direct 一并拦掉，
   * 配合按钮上同款 `sub.id !== DIRECT_GROUP_ID` 判定，使「单节点」分组头既没有
   * 闪电图标、展开区的提示文字却又写着「点行头闪电图标测速」——用户报障：
   * 单节点无法测速。
   */
  private async speedTestSub(subId: string): Promise<void> {
    if (this.speedTestingIds.includes(subId)) {
      return;
    }
    this.speedTestingIds = this.speedTestingIds.concat([subId]);
    try {
      // 两段式提示：通道还没就绪时（可能要拉起测速内核，秒级）先说「准备…」，
      // 就绪、开始发探测了再切到「正在测速…」。旧实现只提示「正在测速…」，
      // 用户看到的是「点了没反应，过几秒才出结果」（真机取证 2026-10-20）。
      this.showToast('准备测速通道…');
      // 先把该订阅设为当前并把内核切过去（FlClash：测速测的永远是当前 profile）
      await this.activateProfile(subId);
      const progress = await BackgroundLatencyService.testSubscription(getContext(this) as Context, subId,
        (): void => { this.showToast('正在测速…'); });
      if (progress === null) {
        this.showToast('测速通道未就绪或已有测速任务在跑，请稍后重试');
        return;
      }
      if (progress.measured + progress.timeout + progress.failed === 0) {
        this.showToast('本次未取得测速结果，请重试');
        return;
      }
      // 【2026-10-22】测速结论立刻落盘。
      // 此前只写进程内视图（LatencyLiveView），force-stop / 被系统清理后重启，
      // 刚测出来的 24 个绿值全变回 `--`（真机复现：测完全绿 → 杀进程 → 全 `--`）。
      // 落盘口径沿用本仓既有规则：只落判定类结论（静默批的失败不落），时间戳/
      // 失败分类原样保留，冷启动恢复后照常显示「123ms」或「超时·旧」。
      const testedNames: string[] = [];
      for (const n of this.coreNodes) {
        testedNames.push(n.name);
      }
      if (testedNames.length === 0) {
        for (const n of this.service.nodesOf(subId)) {
          testedNames.push(n.name);
        }
      }
      try {
        await LatencyStoreBridge.persistConclusions(testedNames);
      } catch (e) {
        AppLogger.warn(TAG, `persist latency conclusions failed: ${AppLogger.errText(e)}`);
      }
      if (progress !== null && progress.total === 0) {
        // 0 个目标绝不能报「测速完成」——真机实证：测速内核被系统回收后
        // `/proxies` 拿不到任何节点，批次 0 个目标立即结束，用户看到
        // 「点一下就说测速完成、节点全是 --」，误以为功能坏了。
        this.showToast('没有可测速的节点：测速内核未就绪或该订阅没有节点，请稍后重试');
      } else {
        this.showToast('✓ 测速完成');
      }
    } catch (e) {
      this.showToast('测速失败，请重试');
    } finally {
      this.speedTestingIds = this.speedTestingIds.filter((x: string) => x !== subId);
      this.refreshCoreNodes();
    }
  }

  /**
   * 内核组测速（整组）：一次 `GET /group/PROXY/delay`，由**内核**并发测完全部节点。
   *
   * 实现只有一处：`BackgroundLatencyService.runKernelGroupTest()`（订阅行闪电、冷启动静默批、
   * 这里的「测全部」按钮共用同一套 504/通道故障/未生效 判定）。本方法只负责取通道与提示。
   *
   * 为什么大订阅必须走组测（2026-10-22 真机 547 节点）：逐节点 REST 会把 controller 压到
   * /version 探针都超时 → 被判「通道不可用」→ 整批中止（measured=2）。核内并发（mBatch=50）
   * 不经过客户端连接池，同样节点数耗时是逐节点路径的几分之一。
   */
  private async runKernelGroupTest(): Promise<void> {
    if (this.groupTesting) {
      return;
    }
    const nodes: ProxyNode[] = this.service.nodes;
    if (nodes.length === 0) {
      this.showToast('没有可测速的节点');
      return;
    }
    this.groupTesting = true;
    try {
      const api = await ConnectionOrchestrator.instance().ensureLatencyApi(true);
      if (api === null) {
        this.showToast('内核不可用，已跳过（未写入超时）');
        return;
      }
      const settings = await SettingsService.load();
      const progress = await BackgroundLatencyService.runKernelGroupTest(
        api, nodes, effectiveTestUrl(settings), 'manual');
      this.latencyTick = this.latencyTick + 1;
      if (progress.coreUnavailable) {
        this.showToast('通道不可用，本轮结果无效，节点已恢复未测');
        return;
      }
      this.showToast('✓ 测速完成');
    } catch (e) {
      AppLogger.warn(TAG, `kernel group test failed: ${AppLogger.errText(e)}`);
      this.showToast('组测速失败，请重试');
    } finally {
      this.groupTesting = false;
      this.latencyTick = this.latencyTick + 1;
      this.refreshCoreNodes();
    }
  }

  private isRefreshingSub(id: string): boolean {
    return this.refreshingIds.includes(id);
  }

  private async refreshOne(sub: Subscription): Promise<void> {
    if (sub.id === DIRECT_GROUP_ID || this.isRefreshing || this.isRefreshingSub(sub.id)) {
      return;
    }
    this.spinTick += 1;
    this.refreshingIds = this.refreshingIds.concat([sub.id]);
    try {
      const result = await this.service.refreshSubscription(sub.id);
      this.reload();
      if (result.status === SubscriptionRefreshStatus.OK) {
        this.showToast(`✓ 已刷新「${sub.name}」及节点测速`);
      } else {
        // 只有**网络类**失败才提示开代理；内容类失败（4 字节响应 / 非订阅地址 /
        // 面板首页）必须说真实原因，否则用户开着代理刷十次也没用。
        const networkLevel: boolean = result.status === SubscriptionRefreshStatus.NETWORK_ERROR
          || result.status === SubscriptionRefreshStatus.HTTP_ERROR
          || result.status === SubscriptionRefreshStatus.RATE_LIMITED;
        this.showToast(networkLevel
          ? '刷新失败，请开启代理再次刷新'
          : (result.message.length > 0 ? result.message : '刷新失败，请检查订阅链接'));
      }
    } finally {
      this.refreshingIds = this.refreshingIds.filter((x) => x !== sub.id);
    }
  }

  private async refreshAll(): Promise<void> {
    if (this.isAdding || this.isRefreshing || this.refreshingIds.length > 0) {
      return;
    }
    const ids: string[] = [];
    for (const s of this.subs) {
      if (s.id !== DIRECT_GROUP_ID) {
        ids.push(s.id);
      }
    }
    if (ids.length === 0) {
      this.showToast('没有可刷新的订阅');
      return;
    }
    this.spinTick += 1;
    this.isRefreshing = true;
    this.refreshingIds = ids.slice();
    try {
      const summary = await this.service.refreshSubscriptionsConcurrently(ids,
        ConcurrentRefresh.DEFAULT_LANES,
        (progress: RefreshBatchProgress, item: RefreshItemOutcome) => {
          this.refreshingIds = this.refreshingIds.filter((x) => x !== item.id);
          this.reload();
        },
        (): boolean => !this.isRefreshing);
      if (summary.failCount === 0) {
        this.showToast(`✓ 已成功刷新全部 ${summary.total} 个订阅及节点！`);
      } else if (summary.okCount > 0) {
        this.showToast(`部分刷新成功（${summary.okCount} 成功 / ${summary.failCount} 失败）`);
      } else {
        this.showToast('刷新失败，请检查订阅链接或开启代理后重试');
      }
    } finally {
      this.refreshingIds = [];
      this.isRefreshing = false;
      this.reload();
    }
  }

  private subscriptionNameOf(id: string): string {
    const f = this.subs.find((s: Subscription) => s.id === id);
    return f === undefined ? id : f.name;
  }

  /** URL 导入（HTML importFromUrl 等价：按 host 自动命名） */
  private async importFromUrl(rawUrl: string): Promise<void> {
    const raw = rawUrl.trim();
    if (raw.length === 0 || this.isAdding || this.isRefreshing) {
      return;
    }
    // 【2026-10-22 用户口径】订阅 URL 输入框只收「订阅地址」：
    // 单节点链接一律拒绝，统一走「设置 → 订阅转换」（可保存到本地，也可一键导入）。
    // 旧实现会把这些链接解析成节点塞进「单节点」虚拟分组，那个分组已经退场。
    const nonEmptyLines = raw.split(/\r?\n/)
      .map((l: string): string => l.trim())
      .filter((l: string): boolean => l.length > 0);
    const hasNodeUri = nonEmptyLines.some((l: string): boolean => SubscriptionService.isNodeUri(l));
    if (hasNodeUri) {
      promptAction.showToast({
        message: '单节点链接不支持在这里添加：请到「设置 → 订阅转换」转换后点「一键导入」，或保存 YAML 再用「+ → 文件」导入'
      });
      return;
    }
    if (!SubscriptionFetchPolicy.isValidSubscriptionUrl(raw, this.settings.allowInsecureSubscriptionHttp)) {
      promptAction.showToast({ message: raw.trim().toLowerCase().startsWith('http://')
        && !this.settings.allowInsecureSubscriptionHttp
        ? '明文 HTTP 订阅已默认禁用：请改用机场的 https 链接，或在设置里打开「允许明文 HTTP 订阅」'
        : '请输入有效的URL地址' });
      return;
    }
    const dupe = this.subs.find((s) => s.url === raw);
    if (dupe !== undefined) {
      promptAction.showToast({ message: '该订阅已存在，无需重复添加' });
      return;
    }
    this.isAdding = true;
    try {
      let host = raw.replace(/^https?:\/\//, '').split('/')[0];
      if (host.length === 0) {
        host = '订阅';
      }
      const sub = await this.service.addSubscription(`🔗 ${host} 节点组`, raw, '', '');
      // 立刻上屏：订阅卡先出现（0 节点 · 刷新中），不等网络刷新完成。
      // 此前 reload 放在 refreshSubscription 之后，慢订阅要等十几秒才有可见反馈。
      this.expandedIds = [sub.id];
      this.activeSubId = sub.id;
      this.reload();
      this.showToast('已添加，正在获取节点…');
      const result = await this.service.refreshSubscription(sub.id);
      if (result.status === SubscriptionRefreshStatus.OK) {
        // 导入即激活（FlClash：新 profile 成为当前，内核配置跟着切）
        await this.activateProfile(sub.id);
        const nodes = this.service.nodesOf(sub.id);
        if (nodes.length > 0) {
          await this.selectNode(nodes[0]);
        }
      }
      this.reload();
      this.showToast(result.status === SubscriptionRefreshStatus.OK
        ? `✓ 订阅成功，获取到 ${result.nodeCount} 个节点` : '刷新失败，请开启代理再次刷新');
    } catch (e) {
      promptAction.showToast({ message: '添加失败，请检查链接是否有效' });
    }
    this.isAdding = false;
  }

  private async importFromQr(): Promise<void> {
    if (this.isScanning || this.isAdding || this.isRefreshing || this.isImporting) {
      return;
    }
    this.isScanning = true;
    try {
      const result = await scanBarcode.startScanForResult(getContext(this) as Context, {
        enableMultiMode: false,
        enableAlbum: true
      });
      const raw = result.originalValue.trim();
      if (raw.length === 0) {
        this.showToast('二维码内容为空');
        return;
      }
      // 2026-10-21：二维码只支持 Clash 订阅，扫到单节点链接不再导入
      if (SubscriptionService.isNodeUri(raw)) {
        this.showToast('扫码只支持 Clash 订阅二维码；单节点请到「设置 → 订阅转换」用「一键导入」添加');
        return;
      }
      const lower = raw.toLowerCase();
      if (!(lower.startsWith('https://') || lower.startsWith('http://'))
        || !SubscriptionFetchPolicy.isValidSubscriptionUrl(raw, this.settings.allowInsecureSubscriptionHttp)) {
        this.showToast('请提供 Clash 订阅二维码（二维码里应是 Clash 订阅链接）');
        return;
      }
      await this.importFromUrl(raw);
    } catch (e) {
      const err = e as BusinessError;
      if (err.code === 1000500002) {
        this.showToast('已取消二维码扫描');
      } else if (err.code === 201) {
        this.showToast('相机权限被拒绝，无法扫描二维码');
      } else {
        this.showToast('二维码扫描失败，请重试');
      }
    } finally {
      this.isScanning = false;
    }
  }

  private async importYamlFile(): Promise<void> {
    if (this.isImporting) {
      return;
    }
    this.isImporting = true;
    try {
      const docPicker = new picker.DocumentViewPicker(getContext(this) as Context);
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      // 2026-10-21：只接受 Clash 配置；JSON / CONF / TXT 不再支持
      opts.fileSuffixFilters = ['.yaml', '.yml'];
      const uris = await docPicker.select(opts);
      if (uris.length === 0) {
        return;
      }
      const uri = uris[0];
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        const stat = fs.statSync(file.fd);
        if (stat.size <= 0 || stat.size > 4 * 1024 * 1024) {
          this.showToast('文件大小需在 4MB 以内');
          return;
        }
        const buf = new ArrayBuffer(Number(stat.size));
        let readLen = 0;
        while (readLen < Number(stat.size)) {
          const chunk = fs.readSync(file.fd, buf, { offset: readLen, length: Number(stat.size) - readLen });
          if (chunk <= 0) {
            break;
          }
          readLen += chunk;
        }
        const text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, readLen));
        const fileName = uri.substring(uri.lastIndexOf('/') + 1);
        const count = await this.service.addLocalYaml(fileName, text);
        if (count > 0) {
          this.showToast(`文件导入成功，解析出 ${count} 个节点`);
          this.reload();
        } else {
          this.showToast('文件里没有可用的 Clash 节点，请提供 YAML 订阅文件（Clash 配置）');
        }
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      AppLogger.warn(TAG, `yaml file import failed: ${AppLogger.errText(e)}`);
      const msg = AppLogger.errText(e);
      this.showToast(msg.indexOf('请提供 YAML') >= 0
        ? '请提供 YAML 订阅文件（Clash 配置）'
        : '导入失败，请重试');
    } finally {
      this.isImporting = false;
    }
  }


  private async doDelete(id: string): Promise<void> {
    if (id === DIRECT_GROUP_ID) {
      this.showToast('单节点分组为常驻分组，不能删除');
      return;
    }
    await this.service.removeSubscription(id);
    this.expandedIds = this.expandedIds.filter((x) => x !== id);
    if (this.activeSubId === id) {
      this.activeSubId = '';
      this.activeNodeId = '';
    }
    this.reload();
    this.showToast('订阅已删除');
  }

  private openEdit(sub: Subscription): void {
    this.editTarget = sub;
    this.editDialog.open();
  }

  /**
   * 长按删除单个节点（语义与 NodeSelectionPage.doDeleteNode 一致）：
   * - 服务端 removeNode 会把节点指纹记入隐藏清单，订阅刷新后该节点不会"复活"；
   * - 删除的是当前选中节点时清空偏好（所有消费方都有 nodes[0] 兜底），并同步
   *   页面态 activeNodeId/activeSubId，避免状态卡仍显示已删节点。
   */
  // ── 批量多选：状态流转（2026-10-20）────────────────────────────────────

  private enterNodeSelectMode(nodeId: string): void {
    this.nodeSelectMode = true;
    this.selectedNodeIds = [nodeId];
  }

  private exitNodeSelectMode(): void {
    this.nodeSelectMode = false;
    this.selectedNodeIds = [];
  }

  private isNodeSelected(nodeId: string): boolean {
    return this.selectedNodeIds.indexOf(nodeId) >= 0;
  }

  private toggleSelectedNode(nodeId: string): void {
    const index = this.selectedNodeIds.indexOf(nodeId);
    const next: string[] = this.selectedNodeIds.slice();
    if (index >= 0) {
      next.splice(index, 1);
    } else {
      next.push(nodeId);
    }
    this.selectedNodeIds = next;
  }

  /** 全选/取消全选：范围 = 当前已展开订阅里的全部节点（未展开的不在视野里，不误选） */
  private toggleSelectAllNodes(): void {
    const ids: string[] = [];
    for (const sub of this.subs) {
      if (this.isOpen(sub.id)) {
        for (const node of this.nodesSortedByLatency(sub.id)) {
          ids.push(node.id);
        }
      }
    }
    this.selectedNodeIds = this.selectedNodeIds.length >= ids.length ? [] : ids;
  }

  private confirmDeleteSelectedNodes(): void {
    if (this.selectedNodeIds.length === 0) {
      return;
    }
    const names: string[] = [];
    for (const id of this.selectedNodeIds) {
      const node = this.service.findNode(id);
      if (node !== null) {
        names.push(`「${node.name}」`);
      }
    }
    if (names.length === 0) {
      this.exitNodeSelectMode();
      return;
    }
    const head: string = names.slice(0, 3).join('、');
    this.deleteNodeTargetName = names.length > 3 ? `${head} 等 ${names.length} 个节点` : head;
    this.deleteNodeDialog.open();
  }

  /** 批量删除：逐个 removeNode（失败不中断，最后汇报成功数） */
  private async doDeleteSelectedNodes(): Promise<void> {
    const ids: string[] = this.selectedNodeIds.slice();
    if (ids.length === 0) {
      return;
    }
    let removedCount = 0;
    let activeRemoved = false;
    for (const id of ids) {
      if (this.activeNodeId === id) {
        activeRemoved = true;
      }
      const ok = await this.service.removeNode(id);
      if (ok) {
        removedCount += 1;
      }
    }
    if (activeRemoved) {
      this.settings.preferredNodeId = '';
      this.settings.preferredNodeSubscriptionId = '';
      this.settings.preferredNodeName = '';
      await SettingsService.save(this.settings);
      this.activeNodeId = '';
      this.activeSubId = '';
    }
    this.exitNodeSelectMode();
    this.reload();
    this.refreshDisplayNode();
    this.showToast(removedCount === ids.length ? `已删除 ${removedCount} 个节点`
      : `已删除 ${removedCount}/${ids.length} 个（部分失败，可重试）`);
  }

  private async doDeleteNode(): Promise<void> {
    const nodeId = this.deleteNodeTargetId;
    this.deleteNodeTargetId = '';
    if (nodeId.length === 0) {
      return;
    }
    const node = this.service.findNode(nodeId);
    const wasSelected = this.activeNodeId === nodeId;
    const ok = await this.service.removeNode(nodeId);
    if (!ok) {
      this.showToast('删除失败，请重试');
      return;
    }
    if (wasSelected) {
      this.settings.preferredNodeId = '';
      this.settings.preferredNodeSubscriptionId = '';
      this.settings.preferredNodeName = '';
      await SettingsService.save(this.settings);
      this.activeNodeId = '';
      this.activeSubId = '';
    }
    this.reload();
    this.refreshDisplayNode();
    this.showToast(node !== null ? `已删除「${node.name}」` : '节点已删除');
  }

  private async doEdit(name: string, url: string): Promise<void> {
    const target = this.editTarget;
    if (target === null) {
      return;
    }
    if (name.trim().length === 0) {
      this.showToast('订阅名称不能为空');
      return;
    }
    const isLocal = target.url.startsWith('local://');
    if (target.id !== DIRECT_GROUP_ID && !isLocal && url.trim().length === 0) {
      this.showToast('订阅链接不能为空');
      return;
    }
    // 本地导入允许改名；http/https 走完整 URL 校验
    if (target.id !== DIRECT_GROUP_ID && !isLocal && !url.trim().startsWith('local://')
      && !SubscriptionFetchPolicy.isValidSubscriptionUrl(url.trim(), this.settings.allowInsecureSubscriptionHttp)) {
      this.showToast(url.trim().toLowerCase().startsWith('http://')
        && !this.settings.allowInsecureSubscriptionHttp
        ? '明文 HTTP 订阅已默认禁用：请改用 https 链接，或先在设置里打开对应开关'
        : '请输入有效的订阅链接');
      return;
    }
    const dupe = target.id === DIRECT_GROUP_ID ? undefined
      : this.subs.find((s) => s.url === url.trim() && s.id !== target.id);
    if (dupe !== undefined) {
      this.showToast('该订阅链接已存在');
      return;
    }
    target.name = name.trim();
    if (target.id !== DIRECT_GROUP_ID && !isLocal) {
      target.url = url.trim();
    }
    await this.service.updateSubscription(target);
    this.reload();
    this.editTarget = null;
    this.showToast('订阅已更新');
  }

  private formatUpdateTime(ts: number): string {
    if (ts <= 0) {
      return '未更新';
    }
    const diff = Date.now() - ts;
    const minutes = Math.floor(diff / 60000);
    if (minutes < 1) {
      return '刚刚';
    }
    if (minutes < 60) {
      return `${minutes}分钟前`;
    }
    const hours = Math.floor(minutes / 60);
    if (hours < 24) {
      return `${hours}小时前`;
    }
    const days = Math.floor(hours / 24);
    if (days < 7) {
      return `${days}天前`;
    }
    const d = new Date(ts);
    return `${d.getMonth() + 1}/${d.getDate()}`;
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 底层背景列（文档 §3.2：纯色底，不再用渐变/玻璃底）
      Column().width('100%').height('100%')
        .linearGradient({ angle: 180, colors: [[TunBoxColors.bgGradientStart, 0.0], [TunBoxColors.bgGradientEnd, 1.0]] })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        Scroll() {
          Column() {
            // ── 顶部导航（页签页，无返回；右侧保留全部既有入口） ──
            TopNavBar({ title: '订阅与节点' }) {
              Row({ space: 8 }) {
                // 单列/双列节点排布切换
                Stack({ alignContent: Alignment.Center }) {
                  Image($r('app.media.ic_apps')).width(20).height(20)
                    .fillColor(TunBoxColors.textPrimary)
                }
                .width(36).height(36)
                .borderRadius(TunBoxGeometry.pillRadius)
                .backgroundColor(TunBoxColors.chipBg)
                .accessibilityText('切换单列双列排布')
                .onClick(() => { this.toggleNodeColumns(); })
                // 刷新全部
                Stack({ alignContent: Alignment.Center }) {
                  if (this.isRefreshing) {
                    LoadingProgress().width(18).height(18).color(TunBoxColors.primary)
                  } else {
                    Image($r('app.media.ic_refresh')).width(20).height(20)
                      .fillColor(TunBoxColors.textPrimary)
                      .rotate({ angle: this.spinTick * 360 })
                      .animation({ duration: 650, curve: Curve.EaseInOut })
                  }
                }
                .width(36).height(36)
                .borderRadius(TunBoxGeometry.pillRadius)
                .backgroundColor(TunBoxColors.chipBg)
                .accessibilityText('刷新全部订阅')
                .onClick(() => { this.refreshAll(); })
                // “+”添加订阅
                Stack({ alignContent: Alignment.Center }) {
                  Image($r('app.media.ic_plus')).width(20).height(20)
                    .fillColor(TunBoxColors.primary)
                }
                .width(36).height(36)
                .borderRadius(TunBoxGeometry.pillRadius)
                .backgroundColor(TunBoxColors.primaryLight)
                .accessibilityText('添加订阅')
                .onClick(() => { this.importDialog.open(); })
              }.alignItems(VerticalAlign.Center)
            }

            // 顶部提示不再放在这里（2026-10-18）：它曾是 Scroll 内容里的条件 Text，
            // 每次「正在测速…/✓ 测速完成/刷新完成」出现时都把下面的订阅卡整体下推一行。
            // 现在改为根 Stack 上的浮动胶囊（见 build() 末尾），绝不参与布局。

            Column({ space: 14 }) {
              // ── 1. 顶部全局概览卡（文档 §3.2 第 1 节） ──
              Row() {
                Column({ space: 4 }) {
                  Row() {
                    Circle({ width: 6, height: 6 }).fill(TunBoxColors.success).margin({ right: 6 })
                    Text('当前使用订阅组').fontSize(12).fontColor(TunBoxColors.textMuted)
                  }
                  Text(this.activeSub() !== null ? (this.activeSub() as Subscription).name : '暂无')
                    .fontSize(15).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Row({ space: 6 }) {
                    Text('当前连接节点').fontSize(12).fontColor(TunBoxColors.textMuted)
                    Text(this.currentNodeName.length > 0 ? this.currentNodeName : '未选择')
                      .fontSize(12).fontColor(TunBoxColors.primary).fontWeight(FontWeight.Medium)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }.margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Blank()
                Row({ space: 4 }) {
                  Text(`${this.subs.length} 订阅 · ${this.candidateCount} 节点`)
                    .fontSize(11).fontColor(TunBoxColors.primary)
                }
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .backgroundColor(TunBoxColors.primaryLight)
                .borderRadius(12)
              }
              .width('100%')
              .padding(TunBoxGeometry.cardPadding)
              .backgroundColor(TunBoxColors.surfaceCard)
              .borderRadius(TunBoxGeometry.cardRadiusSmall)
              .border({ width: 1, color: TunBoxColors.cardBorder })

              // ── 2. 内核智能优选条目（文档 §3.2 第 2 节，整行点击沿用既有切换逻辑）
              //      行尾多一个**内核组测速**按钮（2026-10-22 用户要求：放在智能优选后面）──
              if (this.smartModelOn()) {
              Column({ space: 0 }) {
                Row() {
                  // 左：整行可点（切换自动选择）。包一层 Row 而不是把 onClick 挂到外层，
                  // 是为了让行尾的组测速按钮**不与切换动作争事件**（ArkUI 子节点点击会冒泡）。
                  Row() {
                    Row() {
                      Image($r('app.media.ic_radar')).width(24).height(24).fillColor(TunBoxColors.success)
                    }
                    .width(42).height(42)
                    .borderRadius(12)
                    .backgroundColor(TunBoxColors.successLight)
                    .justifyContent(FlexAlign.Center)
                    .margin({ right: 12 })
                    Column({ space: 2 }) {
                      Row() {
                        Text('自动选择 · 内核智能优选')
                          .fontSize(14).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                        Circle({ width: 6, height: 6 })
                          .fill(this.autoSelectMode === AutoSelectModes.AUTO
                            ? TunBoxColors.success : TunBoxColors.textMuted)
                          .margin({ left: 6 })
                      }
                      // 用户要求（2026-10-23）：精简成一行，去掉「启动代理后更新」提示
                      Text(`smart 内核 · 订阅内自动优选 · ${this.candidateCount} 个候选`)
                        .fontSize(11).fontColor(TunBoxColors.textMuted)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    Blank()
                    Stack({ alignContent: Alignment.Center }) {
                      Circle({ width: 18, height: 18 })
                        .fill(this.autoSelectMode === AutoSelectModes.AUTO
                          ? TunBoxColors.success : Color.Transparent)
                        .stroke(this.autoSelectMode === AutoSelectModes.AUTO
                          ? TunBoxColors.success : TunBoxColors.textMuted)
                        .strokeWidth(1.6)
                      if (this.autoSelectMode === AutoSelectModes.AUTO) {
                        Circle({ width: 6, height: 6 }).fill(TunBoxColors.textOnPrimary)
                      }
                    }.width(18).height(18)
                    Text(this.autoSelectMode === AutoSelectModes.AUTO ? '已启用' : '未启用')
                      .fontSize(12)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(this.autoSelectMode === AutoSelectModes.AUTO
                        ? TunBoxColors.success : TunBoxColors.textMuted)
                      .margin({ left: 6 })
                  }
                  .layoutWeight(1)
                  .alignItems(VerticalAlign.Center)
                  // 2026-10-17 用户要求：点整行即选中（不再展开子列表），语义等价原展开区里的 smart 行
                  .onClick(() => this.enableAutoSelect())
                }
                .width('100%')
                .padding(14)
                .alignItems(VerticalAlign.Center)
              }
              .width('100%')
              .borderRadius(18)
              .backgroundColor(TunBoxColors.successTint)
              .border({ width: 1, color: TunBoxColors.successBorder })
              .clip(true)
              }

              // ── 3. 折叠式订阅分组（保留既有展开/收起与行头全部按钮逻辑） ──
              ForEach(this.subs, (sub: Subscription) => {
                Column({ space: 0 }) {
                  // 头部（2026-10-19：间距 10→8，配合右侧图标紧凑组，给订阅名多留宽度）
                  Row({ space: 8 }) {
                    Stack({ alignContent: Alignment.Center }) {
                      Image($r('app.media.ic_nodes')).width(18).height(18)
                        .fillColor(TunBoxColors.primary)
                    }
                    .width(32).height(32)
                    .borderRadius(8)
                    .backgroundColor(TunBoxColors.primaryLight)
                    Column({ space: 2 }) {
                      Row({ space: 6 }) {
                        // ⚠ 名称必须 layoutWeight(1)：否则超长订阅名会按「理想宽度」撑开
                        // 这个 width('100%') 的 Row，把后面的「使用中」徽标挤出 Column 的
                        // 右边界，而 ArkUI 不裁剪溢出内容 —— 徽标会画到行头按钮区、与
                        // 闪电测速图标重叠（真机报障截图）。加权后名称吃掉剩余宽度并省略号，
                        // 徽标始终留在 Row 内。
                        Text(sub.name)
                          .fontSize(14).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                          .layoutWeight(1)
                        if (sub.id === ProfileStore.currentId()) {
                          Text('使用中')
                            .fontSize(10).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.success)
                            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                            .borderRadius(TunBoxGeometry.pillRadius)
                            .backgroundColor(TunBoxColors.successLight)
                            // 徽标永不压缩/永不被挤出去：它是状态标识，宽度必须完整
                            .flexShrink(0)
                        }
                        // 2026-10-20 用户要求：订阅卡片上**不再显示**「N 个域名无法解析」
                        // —— 节点行已经逐条写着「域名无法解析（节点域名可能已下线）」，
                        // 卡片再挂一个计数是**重复信息**（用户：「你在节点上显示了，
                        // 这里就不允许显示了」）⇒ 卡片只保留与节点无关的统计。
                        //
                        // 【2026-10-22 · FlClash 同构】「N 条定义不完整」角标已删除：
                        // App 侧不再对节点下可用性判词（节点可用性归内核 `/proxies`）。
                      }.width('100%')
                      Row({ space: 6 }) {
                        // 旧格式角标：非 Clash 内容已被停止刷新，但节点仍可用（策略 2）
                        if (sub.legacyFormat) {
                          Text('旧格式·不可刷新')
                            .fontSize(10).fontColor(TunBoxColors.danger)
                            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                            .borderRadius(6)
                            .backgroundColor(TunBoxColors.surfaceSubtle)
                            .borderWidth(1)
                            .borderColor(TunBoxColors.danger)
                        }
                        Text(`${this.nodeCountOf(sub)} 个节点 · 更新于 ${this.formatUpdateTime(sub.lastFetchedAt)}`)
                          .fontSize(11).fontColor(TunBoxColors.textMuted)
                          .layoutWeight(1)
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      }.width('100%').alignItems(VerticalAlign.Center)
                    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                    // 2026-10-19 用户要求（订阅卡片改版）：行头**只保留刷新**，
                    // 闪电测速 / 编辑 / 删除 全部下移到展开区操作行。
                    // 行头固定占用从约 218dp 降到约 114dp，订阅名获得充足宽度，
                    // 不再被图标挤到只剩几个字（真机报障截图：名字被遮住）。
                    //
                    // 注：原「闪电测速必须常驻行头、位于刷新左边、不得移动」的旧约定
                    // 已被本次用户明确要求取代（闪电改到展开区、位于编辑左边）。
                    Stack({ alignContent: Alignment.Center }) {
                      if (this.isRefreshingSub(sub.id)) {
                        LoadingProgress().width(15).height(15).color(TunBoxColors.primary)
                      } else {
                        Image($r('app.media.ic_refresh')).width(15).height(15)
                          .fillColor(TunBoxColors.textMuted)
                      }
                    }
                    .width(28).height(28)
                    .borderRadius(TunBoxGeometry.pillRadius)
                    .flexShrink(0)
                    .accessibilityText('刷新订阅')
                    .onClick(() => this.refreshOne(sub))
                    // 展开指示
                    Image($r('app.media.ic_arrow_right')).width(14).height(14)
                      .fillColor(TunBoxColors.textMuted)
                      .rotate({ angle: this.isOpen(sub.id) ? 90 : 0 })
                      .animation({ duration: 250, curve: Curve.EaseInOut })
                  }
                  .width('100%')
                  .padding(14)
                  .onClick(() => this.useProfileAndToggle(sub.id))

                  // 展开节点区
                  if (this.isOpen(sub.id)) {
                    Column({ space: 6 }) {
                      // 【2026-10-22 · FlClash 同构】「定义不完整」说明条已删除 ——
                      // App 不判节点可用性；节点能不用用只由内核决定（见卡片头注释）。
                      // 2026-10-19 用户要求：原「点击选用节点 · 长按可删除单个节点 ·
                      // 点行头闪电图标测速」提示行**去掉**，这一行改放操作按钮
                      // （当时顺序是 测速 / 编辑 / 删除，2026-10-26 已按用户要求改为
                      //   删除 / 编辑 / 测速，见下条）。
                      // 原来在节点下方的「编辑 / 删除」行同步删除，避免重复入口。
                      // [anchor] 订阅展开区操作行（删除 / 编辑 / 测速）
                      // 2026-10-26 用户要求：把「测速」和「删除」互换位置 ——
                      // 原顺序 测速·编辑·删除 改为 删除·编辑·测速（删除居左、测速居右）。
                      // 同一次要求：三个入口的字号抬到与订阅分组名称同一档（14），
                      // 并同步放大图标、补足上下内边距 —— 用户反馈 13 号字太小、
                      // 点击热区不够，手指不好点中。
                      // 用 Blank() 撑开三段（而不是 Row({ space })），间距天然均分且不随条件块漂移。
                      Row() {
                        // 手工导入分组（DIRECT_GROUP_ID）没有可编辑/可删除的订阅实体
                        if (sub.id !== DIRECT_GROUP_ID) {
                          // 删除（左）
                          Row({ space: 5 }) {
                            Image($r('app.media.ic_delete')).width(16).height(16)
                              .fillColor(TunBoxColors.danger)
                            Text('删除').fontSize(14).fontColor(TunBoxColors.danger)
                          }
                          .padding({ left: 2, right: 8, top: 8, bottom: 8 })
                          .accessibilityText('删除订阅')
                          .onClick(() => {
                            this.deleteTargetId = sub.id;
                            this.deleteDialog.open();
                          })
                          Blank()
                          // 编辑（中）
                          Row({ space: 5 }) {
                            Image($r('app.media.ic_tune')).width(16).height(16)
                              .fillColor(TunBoxColors.textMuted)
                            Text('编辑').fontSize(14).fontColor(TunBoxColors.textMuted)
                          }
                          .padding({ left: 8, right: 8, top: 8, bottom: 8 })
                          .accessibilityText('编辑订阅')
                          .onClick(() => this.openEdit(sub))
                          Blank()
                        } else {
                          // 单节点分组只有测速一个入口，同样贴右对齐，视觉与其它卡片一致
                          Blank()
                        }
                        // 闪电测速（右）
                        Row({ space: 5 }) {
                          if (this.speedTestingIds.includes(sub.id)) {
                            LoadingProgress().width(16).height(16).color(TunBoxColors.primary)
                          } else {
                            Image($r('app.media.ic_bolt')).width(16).height(16)
                              .fillColor(TunBoxColors.primary)
                          }
                          Text('测速').fontSize(14).fontColor(TunBoxColors.primary)
                        }
                        .padding({ left: 8, right: 2, top: 8, bottom: 8 })
                        .accessibilityText('闪电测速')
                        .onClick(() => this.speedTestSub(sub.id))
                      }
                      .width('100%')
                      .alignItems(VerticalAlign.Center)
                      .padding({ left: 2, right: 2, top: 2, bottom: 2 })
                      GridRow({ columns: this.nodeColumns, gutter: 10 }) {
                        ForEach(this.nodesSortedByLatency(sub.id), (node: ProxyNode) => {
                          GridCol() {
                            this.nodeCard(node)
                          }
                        }, (node: ProxyNode) => `${node.id}|${node.id === this.activeNodeId ? 1 : 0}|${this.latencyTick}`)
                      }
                      .width('100%')
                    }
                    .width('100%')
                    .padding({ left: 12, right: 12, bottom: 12, top: 4 })
                    .backgroundColor(TunBoxColors.surfaceSubtle)
                    .borderWidth({ top: 1 })
                    .borderColor(TunBoxColors.cardBorder)
                  }
                }
                .width('100%')
                .borderRadius(TunBoxGeometry.cardRadius)
                .backgroundColor(TunBoxColors.surfaceCard)
                .border({
                  width: sub.id === ProfileStore.currentId() ? 1.5 : 1,
                  color: sub.id === ProfileStore.currentId() ? TunBoxColors.primary : TunBoxColors.cardBorder
                })
                .clip(true)
              }, (sub: Subscription) => `${sub.id}|${sub.name}|${this.nodeCountOf(sub)}|${sub.lastFetchedAt}|${this.isOpen(sub.id) ? 1 : 0}|${sub.id === ProfileStore.currentId() ? 1 : 0}|${this.activeNodeId}`)

              if (this.subs.length === 0) {
                Column({ space: 10 }) {
                  Image($r('app.media.ic_nodes')).width(44).height(44)
                    .fillColor(TunBoxColors.textMuted)
                  Text('暂无订阅').fontSize(16).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textMuted)
                  Text('点击右上角 + 添加订阅').fontSize(12).fontColor(TunBoxColors.textMuted)
                }.width('100%').padding({ top: 50, bottom: 50 })
              }
            }
            .width('100%')
            // 底部为悬浮导航栏预留 TunBoxGeometry.dockClearance(96) 高度
            .padding({
              left: TunBoxGeometry.pagePadding,
              right: TunBoxGeometry.pagePadding,
              top: 4,
              bottom: TunBoxGeometry.dockClearance
            })
          }
          .width('100%')
        }.edgeEffect(EdgeEffect.Spring)
        .width('100%').height('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%').height('100%')

      // ── 顶部浮动提示（2026-10-18 用户要求：不挤占内容）──
      //
      // 为什么必须做成**叠层**而不是内容里的一行：
      // 测速/刷新的「正在测速…/✓ 测速完成/刷新完成…」是瞬态反馈，用户要的是
      // 「看得见、但不打断」；旧实现把它当 Scroll 内容里的条件 Text，出现一次就把
      // 下面所有订阅卡下推一行，反复测速时列表会持续跳动。
      //
      // 实现要点：
      //  · 根 Stack 的最后一个子节点 → 绘制在所有内容之上，且不参与 Column 布局；
      //  · 全屏透明容器 + 顶部内边距（让开 56vp 导航栏）→ 胶囊真正居中在顶部；
      //  · hitTestBehavior(None) → 提示层完全不拦截触摸（不会挡住底下的订阅卡/按钮）；
      //  · 只在 toastVisible 期间存在，配合 OPACITY 过渡淡入淡出。
      if (this.toastVisible) {
        Column() {
          Text(this.toastMsg)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            // 配色跟随主题（2026-10-18 用户要求）：白/深卡底 + 正文色字 + 品牌蓝描边，
            // 不再用写死的黑色底 + 白字（浅色主题里与整体白卡蓝调完全不搭）。
            .fontColor(TunBoxColors.toastText)
            .textAlign(TextAlign.Center)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(TunBoxGeometry.pillRadius)
            .backgroundColor(TunBoxColors.toastBg)
            .borderWidth(1)
            .borderColor(TunBoxColors.toastBorder)
            .shadow({ radius: 16, color: TunBoxColors.toastShadow, offsetX: 0, offsetY: 6 })
            .constraintSize({ maxWidth: '88%' })
            .transition(TransitionEffect.OPACITY.animation({ duration: 160, curve: Curve.EaseOut }))
        }
        .width('100%')
        .height('100%')
        .padding({ top: TunBoxGeometry.navHeight + 8, left: TunBoxGeometry.pagePadding, right: TunBoxGeometry.pagePadding })
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.None)
        .zIndex(20)
      }
      // ── 批量多选操作条（2026-10-20）：长按节点后浮在底部，对齐节点页交互 ──
      if (this.nodeSelectMode) {
        Row({ space: 10 }) {
          Text('取消')
            .fontSize(13).fontColor(TunBoxColors.textSecondary)
            .height(36).padding({ left: 14, right: 14 })
            .borderRadius(18).backgroundColor(TunBoxColors.chipBg)
            .textAlign(TextAlign.Center)
            .onClick(() => this.exitNodeSelectMode())
          Text(`已选 ${this.selectedNodeIds.length}`)
            .fontSize(14).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
            .layoutWeight(1)
          Text('全选')
            .fontSize(13).fontColor(TunBoxColors.primary)
            .height(36).padding({ left: 14, right: 14 })
            .borderRadius(18).backgroundColor(TunBoxColors.chipBg)
            .textAlign(TextAlign.Center)
            .onClick(() => this.toggleSelectAllNodes())
          Row({ space: 4 }) {
            Image($r('app.media.ic_delete')).width(14).height(14)
              .fillColor(this.selectedNodeIds.length > 0 ? TunBoxColors.danger : TunBoxColors.textMuted)
            Text('删除').fontSize(13).fontWeight(FontWeight.Medium)
              .fontColor(this.selectedNodeIds.length > 0 ? TunBoxColors.danger : TunBoxColors.textMuted)
          }
          .height(36).padding({ left: 14, right: 14 })
          .borderRadius(18).backgroundColor(TunBoxColors.chipBg)
          .onClick(() => this.confirmDeleteSelectedNodes())
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        .margin({ left: 12, right: 12, bottom: 100 })
        .height(52)
        .backgroundColor(TunBoxColors.surfaceCard)
        .borderRadius(20)
        .borderWidth(1)
        .borderColor(TunBoxColors.cardBorder)
        .shadow({ radius: 14, color: TunBoxColors.toastShadow, offsetX: 0, offsetY: 4 })
        .zIndex(30)
      }
    }
    .width('100%').height('100%')
  }
}
