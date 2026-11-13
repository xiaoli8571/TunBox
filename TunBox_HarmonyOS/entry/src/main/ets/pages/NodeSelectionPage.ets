/**
 * 节点选择页 — 对齐 upstream TunBoxNodeSelectionPage + _NodeSelectionCard
 * 顶栏(返回/标题/测全部) + 订阅筛选 chips + 节点卡列表（旗帜/名称/延迟按钮/选中勾）。
 *
 * 测速统一经过 BackgroundLatencyService：按订阅分批，复用当前内核或独立测速核，
 * 结果以配置版本、URL、期望码和出口名隔离；页面只负责绘制进度。
 */
import { router, promptAction , LengthMetrics} from '@kit.ArkUI';
import { UnifiedScheduler } from '../commons/services/UnifiedScheduler';
import { SafeArea } from '../theme/SafeArea';
import { TunBoxColors, TunBoxMotion, TunBoxGeometry} from '../theme/TunBoxTokens';
import { Ui, LatencyStyle, NodeDisplay } from '../theme/UiTokens';
import { SubscriptionService } from '../commons/services/SubscriptionService';
import { LatencyStoreBridge } from '../commons/services/LatencyStoreBridge';
import { Subscription } from '../commons/models/Subscription';
import { SettingsService } from '../commons/services/SettingsService';
import { AppSettings, AutoSelectModes } from '../commons/models/AppSettings';
import { ProxyNode, ProxyNodeType } from '../commons/models/ProxyNode';
import { ProxyGroup } from '../commons/models/ProxyGroup';
import { ClashApiService } from '../commons/services/ClashApiService';
import { ConnectionOrchestrator, ConnState } from '../commons/services/ConnectionOrchestrator';
import { LatencyChannel, LatencyContext, LatencyPolicy, LatencyRecord, LatencyState } from '../commons/services/LatencyState';
import { LatencyProgress } from '../commons/services/LatencyEngine';
import { BackgroundLatencyService } from '../commons/services/BackgroundLatencyService';
import { TunBoxLatencyService } from '../commons/tunbox/TunBoxLatencyService';
import { effectiveTestUrl } from '../commons/latency/LatencyProbe';
// 失败分类常量**唯一真源** = 测速内核（LatencyKinds.LatencyProbeKind）——
// 旧的 ClashApiService.LatencyFailKind 已随内核收敛删除（审计 LP04）。
import { LatencyProbeKind } from '../commons/latency/LatencyKinds';
import { LatencyStore } from '../commons/latency/LatencyStore';
import { NodeCountryPolicy } from '../commons/services/PublicIpService';
import { AppLogger } from '../commons/utils/AppLogger';
import {
  NodeSortSnapshot, NodeSortModes, NodeLatencyRecord, NodeProtocolPolicy
} from '../commons/services/NodeSortPersistence';
import { NodeCandidate, scoreOf } from '../commons/services/SmartSelector';
import { CountryFlagIcon } from '../widgets/CountryFlagIcon';
import {
  ConcurrentRefresh, RefreshBatchProgress, RefreshItemOutcome
} from '../commons/services/ConcurrentRefresh';
import { CoreCatalogService } from '../commons/tunbox/CoreCatalogService';
import { CoreNodeBridge } from '../commons/tunbox/CoreNodeBridge';
import { CoreGroup } from '../commons/tunbox/CoreCatalog';
import { NodeTruth, NodeTruthScope } from '../commons/tunbox/NodeTruth';
import { ProxyPanelMembers } from '../commons/tunbox/ProxyPanelMembers';
import { ProfileRepository } from '../commons/tunbox/ProfileRepository';

const TAG = 'NodeSelectionPage';

interface NodeRow {
  node: ProxyNode;
  countryCode: string;
  /** 综合评分/状态（来自持久化测速快照；无数据时 hasData=false） */
  status: NodeStatusView;
}

/** 页面临时代理组视图。策略组与普通节点同级展示，不再维护二级展开层级。 */
interface ProxyGroupRow {
  group: ProxyGroup;
  /** 展平的全部有效节点（组卡计数与兜底展示用） */
  nodes: NodeRow[];
  /** 直接挂在本组下的普通节点成员（不递归） */
  memberNodes: NodeRow[];
  /** 直接引用的 url-test、fallback、load-balance 等可选策略组。 */
  strategyGroups: ProxyGroup[];
}

/**
 * 节点状态视图（第三轮 UI）：由持久化快照派生，纯展示用。
 *  - hasData: 快照中存在该节点且非「未测」
 *  - rateLabel: 近期成功率文本，如 "100%"
 *  - failCount: 连续失败次数
 *  - score: SmartSelector 综合评分（越小越好，ms 等价）
 */
class NodeStatusView {
  hasData: boolean = false;
  rateLabel: string = '';
  failCount: number = 0;
  score: number = 0;
}

/** 订阅筛选 chip 数据（按 id 过滤，避免同名订阅互相覆盖） */
interface SubChip {
  id: string;
  name: string;
}

/**
 * 批量删除确认对话框（2026-10-20 替换原来的单节点删除框）。
 * 语义不变：删掉的是本地台账，节点在订阅刷新后不会再出现。
 */
@CustomDialog
struct NodeBatchDeleteDialog {
  controller?: CustomDialogController;
  /** 仅供配色 token 登记重绘依赖（2026-10-28 真机取证） */
  @StorageLink('theme_revision') themeRevision: number = 0;
  getSummary: () => string = (): string => '';
  onConfirm: () => void = () => {};

  build() {
    Column({ space: 14 }) {
      Text('删除节点').fontSize(17).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimaryFor(this.themeRevision))
      Text(`确定删除 ${this.getSummary()} 吗？这些节点在订阅刷新后不会再出现。`)
        .fontSize(13).fontColor(Ui.textSecondaryFor(this.themeRevision))
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1).backgroundColor(Ui.surfaceMuted(this.themeRevision)).fontColor(Ui.textSecondaryFor(this.themeRevision))
          .borderRadius(14)
          .borderWidth(1).borderColor(Ui.border)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button('删除')
          .layoutWeight(1).backgroundColor(Ui.error).fontColor(Color.White)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onConfirm();
          })
      }
      .width('100%')
    }
    .padding(22)
    .borderRadius(26)
    // 沉浸光感适配（官方《组件适配沉浸光感》+《沉浸光感常见问题》）：应用级 enable
    // 后 CustomDialog 默认 ULTRA_THICK 沉浸材质背板；材质层级位于背景色/背景模糊之下，
    // 不透明背景色、背景模糊（COMPONENT_THICK）、backgroundEffect 与自定义 shadow
    // 都会遮挡材质（官方反模式），根容器不再设置，视觉交给系统材质统一接管；
    // 内容层（按钮）样式保持不动。
  }
}

@Entry
@Component
struct NodeSelectionPage {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @StorageLink('smart_model_seq') @Watch('refreshSmartEntry') smartModelSeq: number = 0;
  @State smartVisible: boolean = false;
  @State smartSelected: boolean = false;
  @State smartSelecting: boolean = false;
  private smartRefreshRevision: number = 0;
  @State nodes: NodeRow[] = [];
  @State groupRows: ProxyGroupRow[] = [];
  @State expandedGroupKeys: string[] = [];
  @State filterSubId: string = ''; // '' = 全部
  /** 节点搜索（P1-4）：输入即过滤本页 flat 列表，大小写不敏感 */
  @State searchText: string = '';
  private listScroller: Scroller = new Scroller();
  @State subChips: SubChip[] = [];
  @State selectedName: string = '';
  @State testingName: string = '';
  @State batchTesting: boolean = false;
  /**
   * 本轮测速进度（顶栏进度条直接绑定）。
   * 进度只有引擎是唯一来源：页面自己不再统计成功/失败，避免"UI 数字与结论不一致"。
   */
  @State latencyTotal: number = 0;
  @State latencyDone: number = 0;
  /** 本轮实际使用的通道（core / offline）；用于在顶栏标注「离线粗略」 */
  @State latencyChannelLabel: string = '';
  /** 本轮因通道（内核/凭证）不可用而中止：结果不能当节点结论，也不能落盘 */
  @State latencyCoreUnavailable: boolean = false;
  /**
   * 正在**准备测速通道**（未连接时要拉起 headless 测速内核，秒级）。
   * 这段等待必须有可见文案，否则用户看到「点了没反应，过几秒才出结果」
   * （真机取证 2026-10-20：通道准备 = DoH 预解析 + 启扩展 + 就绪轮询 + 预热）。
   */
  @State latencyPreparing: boolean = false;
  /** 准备阶段偏慢时的说明（内核在加载订阅自带规则集）；空 = 用默认文案 */
  @State latencyPrepareHint: string = '';
  /**
   * 本轮是否被取消（用户点取消 / 页面退出）。
   * 引擎的 LatencyProgress 只统计「取消时正好在探测的节点」，无法回答"这一批是否
   * 被取消"，所以取消动作在这里记账：被取消的批次不是完整结论 → 不落盘、不弹完成 toast。
   */
  private batchCancelled: boolean = false;
  /** 排序模式: default 订阅顺序 / auto 按持久化的最近测速结果 / manual 手动固定顺序。
   *  进页面时由 AppSettings.nodeSortMode + nodeSortSnapshot 恢复，测速完成后落盘。 */
  @State sortMode: string = NodeSortModes.DEFAULT;
  /** 最近一次测速快照（内存镜像，随设置持久化） */
  private sortSnapshot: NodeSortSnapshot | null = null;
  /**
   * 批量多选（2026-10-20，用户选定的方案 1「就地长按多选」）：
   * 长按任一节点进入选择态 —— 顶栏切成「取消 · 已选 N · 全选 · 删除」，行前出现勾选圆点；
   * 删除走一次确认后逐个 removeNode（复用「刷新后不再出现」的本地屏蔽台账）。
   */
  @State selectMode: boolean = false;
  @State selectedNodeIds: string[] = [];
  /** 确认框正文：把选中节点名摘要成一句（>3 个折叠为「A、B、C 等 N 个节点」） */
  @State batchDeleteSummary: string = '';
  private batchDeleteDialog: CustomDialogController = new CustomDialogController({
    builder: NodeBatchDeleteDialog({
      getSummary: (): string => this.batchDeleteSummary,
      onConfirm: () => {
        this.doDeleteSelected();
      }
    }),
    autoCancel: true
  });
  @State refreshing: boolean = false;
  /** 刷新批次进度：顶栏刷新图标上直接显示 done/total（边到边刷 UI） */
  @State refreshTotal: number = 0;
  @State refreshDone: number = 0;
  @State refreshOk: number = 0;
  @State refreshFail: number = 0;
  @State isConnected: boolean = false;

  @State latencyTick: number = 0;
  /** 固定监听器实例，避免每次返回节点页都追加匿名监听，造成重复刷新和页面卡顿。 */
  private readonly latencyListener: () => void = (): void => {
    this.latencyTick = this.latencyTick + 1;
    // 批量测速期间只刷新延迟显示，不再边测边重排列表。
    // 大订阅下频繁替换 this.nodes 会导致 List 在滚动期间持续重建/位移，造成明显掉帧；
    // 整批结束后由 commitLatencySnapshot + rebuildRows 一次性按最终测速结果排序。
  };
  private latencyListenerBound: boolean = false;
  /** 页面切入时先完成首帧绘制，再启动设置/订阅加载，避免初始化与转场争抢 UI 线程。 */
  private pageActive: boolean = false;
  /** 自动选点模式（'manual' 手动固定 / 'auto' 自动最优），进页面从持久化读取 */
  private subs: SubscriptionService = SubscriptionService.instance();
  private settings: AppSettings = new AppSettings();
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();

  onPageShow(): void {
    this.pageActive = true;
    // 入场转场期间不抢 UI 线程（原 32ms 会让读盘/建表与转场同帧）
    setTimeout(() => {
      if (this.pageActive) {
        this.bootstrap();
      }
    }, 240);
  }

  /**
   * 离开节点页：取消在途测速并摘掉监听器。
   *
   * 取消只是把结果标成 CANCELLED 并 destroy 掉客户端在途 HTTP —— mihomo 的
   * /delay 用 context.Background()，abort **不会**让内核停止拨号，所以真正限制
   * 负载的是引擎的并发上限，不是这里。已经落地的结果保持可见（不回滚）。
   * 不再需要「宽限回收测速内核」：内核生命周期完全归编排器（隧道或进程内无头内核），
   * 页面不再自己持有第二个内核。
   */
  onPageHide(): void {
    this.pageActive = false;
    this.batchCancelled = true;
    if (this.latencyRunActive) { BackgroundLatencyService.cancelCurrent(); }
    this.batchTesting = false;
    this.testingName = '';
    if (this.latencyListenerBound) {
      LatencyStoreBridge.removeListener(this.latencyListener);
      this.latencyListenerBound = false;
    }
  }

  /** 重建订阅筛选项，并在 direct 变空或订阅被删除时回退到“全部”。 */
  private refreshSubChips(): void {
    const chips: SubChip[] = [];
    for (const sub of this.subs.subscriptions) {
      if (sub.id === 'direct' && sub.nodeCount <= 0) {
        continue;
      }
      chips.push({ id: sub.id, name: sub.name });
    }
    this.subChips = chips;
    if (this.filterSubId.length > 0
      && !chips.some((chip: SubChip) => chip.id === this.filterSubId)) {
      this.filterSubId = '';
    }
  }

  private async bootstrap(): Promise<void> {
    const ctx = getContext(this) as Context;
    this.orchestrator.init(ctx);
    await SettingsService.init(ctx);
    const apiSecret = await SettingsService.getApiSecret();
    // 不能无条件覆盖 endpoint：无头测速内核与真实隧道共用 9090 端口但 secret 不同，
    // 覆盖会让内核侧所有请求返回 401 → 全显失败，且不重启应用就一直错。
    // 编排器只在「没有其它内核在服务」时才写入真实凭证。
    await this.orchestrator.applyRealTunnelEndpoint(apiSecret);
    await this.subs.init(ctx);
    this.settings = await SettingsService.load();
    this.refreshLatencyScopes();
    this.restoreSortState();
    this.isConnected = this.orchestrator.state === ConnState.CONNECTED;
    // 作用域化展示：跨订阅旧偏好不再当「已选」。
    // 2026-10-27：name+id 双锚解析 —— 连接自愈可能只保留 name，
    // 只按 id 找会让「实际连接中」的节点复选框变空（真机复现）。
    const scopedSel = this.subs.resolveUserPreference(
      this.settings.preferredNodeId, this.settings.preferredNodeName);
    this.selectedName = scopedSel !== null ? scopedSel.name
      : (this.subs.nodes.length > 0 ? this.subs.nodes[0].name : '');
    // 异步初始化完成后统一重建筛选项，隐藏空 direct 并清理失效筛选。
    this.refreshSubChips();
    // 进入页面定位到用户所选节点所属订阅并展开分组。
    if (this.filterSubId.length === 0 && this.settings.preferredNodeId.length > 0) {
      const cur = this.subs.resolveUserPreference(
        this.settings.preferredNodeId, this.settings.preferredNodeName);
      if (cur !== null && cur.subscriptionId.length > 0 && cur.subscriptionId !== 'direct'
        && this.subs.subscriptions.some((s: Subscription) => s.id === cur.subscriptionId)) {
        this.filterSubId = cur.subscriptionId;
        this.rebuildRows();
        this.expandAndScrollToNode(cur.name);
      }
    }
    this.rebuildRows();
    // 定位到当前选中节点行（等 nodes 状态驱动的 List 完成构建再滚动）
    const selectedIndex = this.nodes.findIndex((r) => r.node.name === this.selectedName);
    if (selectedIndex > 0) {
      setTimeout(() => {
        this.listScroller.scrollToIndex(selectedIndex, true);
      }, 350);
    }
    if (!this.latencyListenerBound) {
      LatencyStoreBridge.addListener(this.latencyListener);
      this.latencyListenerBound = true;
    }
    // 预热测速通道（真机取证 2026-10-20）：「点了测速要等几秒才开始」的根因是
    // 通道准备（未连接时要拉起 headless 测速内核）。进页面时后台做完这段准备，
    // 用户点「测全部」时通道已热 → 秒开。预热本身不发起任何探测。
    this.refreshCoreBackedRows().catch((e: Object): void => {
      AppLogger.warn(TAG, `provider node catalog warmup failed: ${AppLogger.errText(e)}`);
    });
    // 进页面不再自动测速（用户要求）：只有用户主动点「测全部」或单节点测速才运行。
  }

  /**
   * 由持久化测速快照派生单个节点的综合评分与状态（纯展示，不改任何持久化）。
   * 成功率沿用 NodeLatencyRecord.recentSuccessRate() 语义；评分复用 SmartSelector.scoreOf。
   * 「冷却中」= 近期已失败且连续失败次数达到「故障切换阈值」（该节点会被自动选点视为失效）。
   */
  private statusFor(node: ProxyNode): NodeStatusView {
    const name = node.name;
    const st = new NodeStatusView();
    if (node.subscriptionId !== this.latencyProfileId) { return st; }
    const snap = this.sortSnapshot;
    if (snap === null) {
      return st;
    }
    const rec = snap.recordFor(name);
    if (rec === null || rec.latency === -2) {
      return st;
    }
    st.hasData = true;
    st.failCount = rec.failCount;
    const rate = rec.recentSuccessRate();
    st.rateLabel = rate < 0 ? '--' : `${Math.round(rate * 100)}%`;
    const cand = NodeCandidate.fromStats(name, rec.latency, rec.failCount, rec.lastOk, 0, 0);
    st.score = Math.round(scoreOf(cand, Date.now()));
    return st;
  }

  /** 状态徽标数据来自普通字段 sortSnapshot（不是 @State），ForEach 的 key 不带状态签名时，
   *  同一节点的行会被复用，徽标会永远停在首次渲染的值。把状态签名并进 key 才会重建该行。 */
  private statusKey(st: NodeStatusView): string {
    return st.hasData ? `1-${st.failCount}-${st.rateLabel}` : '0';
  }

  /**
   * 节点页的显示真源（**单一真源**，2026-11-04 架构收口）。
   *
   * 旧实现把内核影子节点**追加**到 App 解析表后面，同一订阅于是同时存在两份真相：
   * 名字对不上就出现重复行，选点/测速/生成配置各读一份 → UI 显示与内核实际出口不一致。
   * 现在按 profile 分工（见 `NodeTruth`）：
   *   · 已应用 profile → **只**读内核目录（叶子节点，过滤删除台账）；
   *   · 其它 profile → App 表**预览**（FlClash 无此概念，本仓保留，绝不参与当前判定）。
   * 内核不可用时，已应用 profile 才回退 App 表——这是显式降级，不是两份合并。
   */
  private displayNodes(): ProxyNode[] {
    const appliedId: string = NodeTruth.appliedProfileId(
      this.orchestrator.appliedProfile(), ProfileRepository.currentId());
    const truth: NodeTruthScope = NodeTruth.scope(appliedId);
    const excluded: string[] = this.subs.listHiddenKeys();
    const out: ProxyNode[] = [];
    if (truth.kernel) {
      for (const node of CoreNodeBridge.toProxyNodes(NodeTruth.leaves(truth, 'rule', excluded), appliedId)) {
        out.push(node);
      }
    } else if (appliedId.length > 0) {
      // 显式降级：内核不在（未连接且无测速核）或快照不属于该 profile。
      for (const n of this.subs.nodes) {
        if (n.subscriptionId === appliedId && !NodeTruth.hidden(n.name, excluded)) {
          out.push(n);
        }
      }
    }
    // 预览：其它订阅的 App 表（不参与当前选点/出口判定，也不与内核合并）。
    for (const n of this.subs.nodes) {
      if (n.subscriptionId !== appliedId) {
        out.push(n);
      }
    }
    return out;
  }

  /** 预热/复用 mihomo 后刷新目录，使 provider-only 节点在未连接时也能进入列表。 */
  private async refreshCoreBackedRows(): Promise<void> {
    this.refreshLatencyScopes();
    const ready: boolean = await this.orchestrator.prewarmLatencyChannel();
    if (!ready || !this.pageActive) {
      return;
    }
    const appliedId: string = this.orchestrator.appliedProfile();
    const profileId: string = appliedId.length > 0 ? appliedId : ProfileRepository.currentId();
    if (profileId.length === 0) {
      return;
    }
    const model = await CoreCatalogService.refresh(this.orchestrator.api, true, profileId);
    if (model === null || !this.pageActive) {
      return;
    }
    // 本地节点表可能没有 provider 节点，选中态改由内核目录按名字确认。
    if (this.settings.preferredNodeName.length > 0
      && model.findNode(this.settings.preferredNodeName) !== null) {
      this.selectedName = this.settings.preferredNodeName;
    }
    this.refreshSubChips();
    this.rebuildRows();
  }

  private rebuildRows(): void {
    this.refreshSmartEntry();
    const rows: NodeRow[] = [];
    const activeNames: string[] = [];
    for (const n of this.displayNodes()) {
      activeNames.push(n.name);
      if (this.filterSubId.length > 0 && n.subscriptionId !== this.filterSubId) {
        continue;
      }
      const row: NodeRow = {
        node: n,
        countryCode: NodeCountryPolicy.detect(n.name).code,
        status: this.statusFor(n)
      };
      rows.push(row);
    }
    LatencyStoreBridge.retainOnly(activeNames, this.latencyContext());

    const groupRows: ProxyGroupRow[] = [];
    const hiddenKeys: string[] = this.subs.listHiddenKeys();
    // 预览分支沿用旧守卫：当前筛选里若已出现内核影子行，就不再渲染 App 空组。
    const hasCoreOnlyRows: boolean = rows.some((row: NodeRow): boolean =>
      CoreNodeBridge.isShadow(row.node));
    // ── 单一真源 / Group 语义（2026-11-04 架构收口）─────────────────────
    // 已应用 profile：组与成员一律取内核 `all` 的**直接成员**，不递归。
    // FlClash 面板就是「组的直接成员 + 组当前 now」；App 侧递归展开会把子组里的
    // 节点冒充成父组成员，选择链因此与内核不一致（真机表现：选父组某节点，
    // 内核实走子组另一个出口）。未应用 profile 仍走 App 预览分支。
    const truth: NodeTruthScope = NodeTruth.scope(this.filterSubId);
    if (truth.kernel) {
      for (const coreGroup of NodeTruth.groupsFor(truth, 'rule')) {
        const group: ProxyGroup = NodeTruth.projectGroup(truth, coreGroup);
        const memberRows: NodeRow[] = [];
        const strategyGroups: ProxyGroup[] = [];
        for (const member of coreGroup.all) {
          if (member.hidden) { continue; }
          if (member.isGroup) {
            const child: CoreGroup | null = NodeTruth.group(truth, member.name);
            if (child !== null) {
              strategyGroups.push(NodeTruth.projectGroup(truth, child));
            }
          } else if (member.name.length > 0 && !NodeTruth.hidden(member.name, hiddenKeys)) {
            memberRows.push(this.mkNodeRow(CoreNodeBridge.toProxyNode(member, this.filterSubId)));
          }
        }
        groupRows.push({ group: group, nodes: memberRows, memberNodes: memberRows,
          strategyGroups: strategyGroups });
      }
    } else if (this.filterSubId.length > 0 && !hasCoreOnlyRows) {
      // 预览路径（未应用 profile）：App 表是唯一可用来源，明确不参与当前选点。
      for (const group of this.subs.groupsOf(this.filterSubId)) {
        const groupNodes: NodeRow[] = [];
        for (const node of this.subs.expandProxyGroup(group)) {
          groupNodes.push(this.mkNodeRow(node));
        }
        // Selector 的直接成员保持订阅声明顺序。策略组与普通节点作为同级选项展示。
        const members = this.subs.groupMembersOf(group);
        const memberNodes: NodeRow[] = [];
        for (const node of members.nodes) {
          memberNodes.push(this.mkNodeRow(node));
        }
        const strategyGroups: ProxyGroup[] = members.groups;
        groupRows.push({ group: group, nodes: groupNodes,
          memberNodes: memberNodes, strategyGroups: strategyGroups });
      }
    }
    this.groupRows = groupRows;
    const validGroupKeys = new Set<string>();
    for (const row of groupRows) {
      validGroupKeys.add(row.group.subscriptionId + '\u0000' + row.group.name);
    }
    this.expandedGroupKeys = this.expandedGroupKeys.filter((key: string) => validGroupKeys.has(key));
    const sortable: NodeRow[] = rows;

    // Sort the actual rows. A name-indexed Map would drop one of two profiles'
    // same-name nodes; measurements are looked up with each row's full context.
    let ordered: NodeRow[] = sortable;
    if (this.sortMode === NodeSortModes.AUTO) {
      const records: Map<string, LatencyRecord> = new Map<string, LatencyRecord>();
      for (const row of sortable) {
        records.set(row.node.id, LatencyStoreBridge.recordFor(row.node.name, this.latencyContext(row.node))
          ?? LatencyRecord.untested(row.node.name));
      }
      ordered = sortable.slice().sort((left: NodeRow, right: NodeRow): number =>
        LatencyPolicy.compare(records.get(left.node.id) as LatencyRecord, records.get(right.node.id) as LatencyRecord));
    } else if (this.sortMode === NodeSortModes.MANUAL && this.sortSnapshot !== null) {
      const order = this.sortSnapshot.order;
      ordered = sortable.slice().sort((left: NodeRow, right: NodeRow): number => {
        const a = order.indexOf(left.node.name); const b = order.indexOf(right.node.name);
        return (a < 0 ? order.length : a) - (b < 0 ? order.length : b);
      });
    }
    this.nodes = ordered;
  }

  /** 节点搜索过滤（P1-4）：空串返回原列表；命中 node.name 小写包含 */
  private searchFiltered(rows: NodeRow[]): NodeRow[] {
    const q = this.searchText.trim().toLowerCase();
    if (q.length === 0) {
      return rows;
    }
    const out: NodeRow[] = [];
    for (const row of rows) {
      if (row.node.name.toLowerCase().indexOf(q) >= 0) {
        out.push(row);
      }
    }
    return out;
  }

  /**
   * 定位到 nodeName 所属的订阅分组（filterSubId），并把该分组**自动展开**，
   * 最后滚动到该节点行——用户不必再手动展开分组找节点。
   * 节点不在任何分组时只定位订阅、不展开。
   */
  private expandAndScrollToNode(nodeName: string): void {
    if (nodeName.length === 0) {
      return;
    }
    // 已应用 profile 走内核组语义（直接成员 + now），不再用 App 递归展开判断归属。
    const truth: NodeTruthScope = NodeTruth.scope(this.filterSubId);
    if (truth.kernel) {
      const owner: string = CoreCatalogService.groupOfNode(nodeName);
      if (owner.length > 0) {
        const key: string = `${this.filterSubId}\u0000${owner}`;
        if (!this.expandedGroupKeys.includes(key)) {
          this.expandedGroupKeys = this.expandedGroupKeys.concat([key]);
        }
        this.rebuildRows();
      }
    } else {
      for (const group of this.subs.groupsOf(this.filterSubId)) {
        const members = this.subs.groupMembersOf(group);
        const inMembers = members.nodes.some((n: ProxyNode) => n.name === nodeName);
        const inExpanded = this.subs.expandProxyGroup(group).some((n: ProxyNode) => n.name === nodeName);
        if (inMembers || inExpanded) {
          const key = this.groupKey(group);
          if (!this.expandedGroupKeys.includes(key)) {
            this.expandedGroupKeys = this.expandedGroupKeys.concat([key]);
          }
          this.rebuildRows();
          break;
        }
      }
    }
    const idx = this.nodes.findIndex((r: NodeRow) => r.node.name === nodeName);
    if (idx > 0) {
      setTimeout(() => {
        this.listScroller.scrollToIndex(idx, true);
      }, 350);
    }
  }


  private groupKey(group: ProxyGroup): string {
    return group.subscriptionId + '\u0000' + group.name;
  }

  /** 当前持久化的父组策略选择名（无选择或 JSON 损坏时返回空串）。 */
  private selectedStrategyName(parent: ProxyGroup): string {
    if (this.settings.proxyGroupSelections.length === 0) {
      return '';
    }
    try {
      const selections = JSON.parse(this.settings.proxyGroupSelections) as Record<string, string>;
      const value = ProxyPanelMembers.selected(this.settings.proxyGroupSelections, parent.subscriptionId, parent.name)
        || selections[this.groupKey(parent)];
      return typeof value === 'string' ? value : '';
    } catch (_) {
      return '';
    }
  }

  /** 组头摘要：类型 + 有效节点数，已选策略时附加展示。 */
  private groupSubtitle(groupRow: ProxyGroupRow): string {
    let text = `${groupRow.group.groupType} · ${groupRow.nodes.length} 个有效节点`;
    const selected = this.selectedStrategyName(groupRow.group);
    if (selected.length > 0) {
      text += ` · 已选 ${selected}`;
    }
    return text;
  }

  private mkNodeRow(node: ProxyNode): NodeRow {
    return {
      node: node,
      countryCode: NodeCountryPolicy.detect(node.name).code,
      status: this.statusFor(node)
    };
  }

  private isGroupExpanded(group: ProxyGroup): boolean {
    return this.expandedGroupKeys.includes(this.groupKey(group));
  }

  private toggleGroup(group: ProxyGroup): void {
    const key = this.groupKey(group);
    if (this.expandedGroupKeys.includes(key)) {
      this.expandedGroupKeys = this.expandedGroupKeys.filter((value: string) => value !== key);
      return;
    }
    this.expandedGroupKeys = this.expandedGroupKeys.concat([key]);
  }

  /**
   * 页面初始化时恢复**排序**状态:
   * 从设置里反序列化最近一次测速快照 + 排序模式。
   *
   * ⚠ 这里**不再**从快照回填测速结论（审计 F4）：
   * 结论的真源是 **LatencyStore**（字段级落盘），应用启动时已按
   * 「无记录或更新才覆盖」的规则恢复进进程内。
   * 若这里再用旧快照盖一遍，旧快照就能盖掉更新的结论 ——
   * 用户看到的就是「刚测出来是好的，一进节点页又变超时」。
   * 快照在这里只负责**排序**（手动固定顺序 / 自动排序的输入）。
   *
   * 快照损坏 / 无数据时回退 default（订阅原始顺序）。
   */
  private restoreSortState(): void {
    const snap = NodeSortSnapshot.fromJsonText(this.settings.nodeSortSnapshot);
    if (snap !== null) { snap.retainScope(this.latencyContext().key('')); }
    const mode = NodeSortModes.normalize(this.settings.nodeSortMode);
    if (snap === null || (mode === NodeSortModes.AUTO && !snap.hasLatencyData())
      || (mode === NodeSortModes.MANUAL && snap.order.length === 0)) {
      this.sortSnapshot = snap;
      this.sortMode = NodeSortModes.DEFAULT;
      return;
    }
    this.sortSnapshot = snap;
    this.sortMode = mode;
  }

  /**
   * 落盘排序模式 + 测速快照（**字段级**，审计 F2）。
   *
   * 两类字段各有各的主人，绝不互相覆盖：
   *  - 测速结论（latency / failKind / 手动顺序）→ 测速分片，**只有测速路径能写**；
   *  - 记账（failCount / lastOk）→ 记账分片，自动切换那条线的事，这里不碰。
   * 旧实现把整份快照塞进 AppSettings 再整单覆盖 → 自动切换记下的失败次数会被
   * 这里这份陈旧副本盖回 0（坏节点又被选中），新一轮测速结论也会被记账那次
   * 写入盖掉（审计 F2 的两个症状）。
   *
   * 注：旧实现里还有一个 `pruneStaleLatencyDisplay()`（按快照裁剪控制器里的
   * 旧值）。它的前提是「快照 = 结论真源」；新真源是 LatencyStore，控制器里的
   * 值本来就来自它，裁剪既无必要又会误伤（单节点手测的结论不在快照里），
   * 因此该方法已删除（订阅变更时的清理走 LatencyStoreBridge.retainOnly）。
   */
  private async persistSortState(): Promise<void> {
    this.settings.nodeSortMode = this.sortMode;
    const snapshotText: string = this.sortSnapshot === null ? '' : this.sortSnapshot.toJsonText();
    await SettingsService.nodeSortSnapshotWrite(snapshotText);
    // 排序模式是设置字段：走字段级写入口（mutator 拿到的是盘上最新值）。
    await SettingsService.patchSettings((s: AppSettings): void => {
      s.nodeSortMode = this.sortMode;
    });
    // 刷新内存副本：让它等于「盘上的合并视图」，后续任何整单写都不会带着
    // 陈旧的记账数据去覆盖自动切换刚记下的失败次数。
    this.settings.nodeSortSnapshot = await SettingsService.loadNodeSortSnapshot();
  }

  /** 排序模式中文说明（用于 toast） */
  private sortModeLabel(mode: string): string {
    if (mode === NodeSortModes.AUTO) {
      return '自动排序（按测速结果）';
    }
    if (mode === NodeSortModes.MANUAL) {
      return '手动固定顺序';
    }
    return '默认顺序';
  }

  /** 用户切换排序模式（点击排序按钮）: 循环 default → auto → manual → default 并持久化 */
  private cycleSortMode(): void {
    const next = this.sortMode === NodeSortModes.DEFAULT ? NodeSortModes.AUTO
      : (this.sortMode === NodeSortModes.AUTO ? NodeSortModes.MANUAL : NodeSortModes.DEFAULT);
    this.sortMode = next;
    // 切到 manual 时把当前可见顺序固化为固定顺序
    if (next === NodeSortModes.MANUAL) {
      const order: string[] = [];
      for (const r of this.nodes) {
        order.push(r.node.name);
      }
      const snap = this.sortSnapshot === null ? new NodeSortSnapshot() : this.sortSnapshot;
      snap.mode = NodeSortModes.MANUAL;
      snap.order = order;
      this.sortSnapshot = snap;
    } else if (this.sortSnapshot !== null) {
      this.sortSnapshot.mode = next;
    }
    this.rebuildRows();
    this.persistSortState();
    promptAction.showToast({ message: `排序方式：${this.sortModeLabel(next)}` });
  }

  /**
   * 刷新: 全部订阅重新拉取并重建节点列表(对齐原版顶栏刷新图标职责)。
   * 并发版：网络拉取并发（DEFAULT_LANES 路），解析/改内存/落盘逐条串行。
   * 进度边到边刷 UI：顶栏刷新图标显示 done/total，成功一条就把新节点立即上屏。
   * 防重入语义保留：refreshing 为真时直接返回，连点不会产生重叠批次。
   */
  private async refreshNodes(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    const ids: string[] = [];
    for (const s of this.subs.subscriptions) {
      ids.push(s.id);
    }
    if (ids.length === 0) {
      promptAction.showToast({ message: '没有可刷新的订阅' });
      return;
    }
    this.refreshing = true;
    this.refreshTotal = ids.length;
    this.refreshDone = 0;
    this.refreshOk = 0;
    this.refreshFail = 0;
    try {
      const summary = await this.subs.refreshSubscriptionsConcurrently(ids,
        ConcurrentRefresh.DEFAULT_LANES,
        (progress: RefreshBatchProgress, item: RefreshItemOutcome) => {
          this.refreshDone = progress.done;
          this.refreshOk = progress.okCount;
          this.refreshFail = progress.failCount;
          if (item.ok) {
            this.rebuildRows();
          }
        },
        (): boolean => !this.refreshing);
      // provider 内容可能由内核刚刚重新拉取；刷新 App 表后同步刷新 `/proxies` 目录。
      await this.refreshCoreBackedRows();
      this.rebuildRows();
      const reasons: string[] = [];
      for (const item of summary.outcomes) {
        if (!item.ok) {
          const reason = item.message.length > 0 ? item.message : '刷新失败';
          reasons.push(`${this.subscriptionNameOf(item.id)}: ${reason}`);
        }
      }
      let message = '';
      if (summary.failCount === 0) {
        message = `刷新完成，共 ${summary.nodeCount} 个节点（并发 ${summary.lanes} 路）`;
      } else if (summary.okCount > 0) {
        message = `刷新完成，共 ${summary.nodeCount} 个节点（${summary.okCount} 成功 / `
          + `${summary.failCount} 失败）；${this.summarizeReasons(reasons)}`;
      } else {
        message = `刷新失败：${this.summarizeReasons(reasons)}`;
      }
      if (summary.rateLimitedCount > 0) {
        message = message + `；${summary.rateLimitedCount} 条被面板限流(429/403)，已降速未重试`;
      }
      AppLogger.info(TAG, `refreshNodes done: ${summary.done}/${summary.total} ok=${summary.okCount} `
        + `fail=${summary.failCount} nodes=${summary.nodeCount} lanes=${summary.lanes}`);
      promptAction.showToast({ message: message });
    } catch (e) {
      promptAction.showToast({ message: '刷新失败，请开启代理再次刷新' });
      AppLogger.warn(TAG, `refreshNodes failed: ${AppLogger.errText(e)}`);
    } finally {
      this.refreshing = false;
      this.refreshTotal = 0;
      this.refreshDone = 0;
    }
  }

  /** 订阅 id → 显示名（失败原因要点名到具体订阅） */
  private subscriptionNameOf(id: string): string {
    const found = this.subs.subscriptions.find((s: Subscription) => s.id === id);
    return found === undefined ? id : found.name;
  }

  /** 失败原因摘要（toast 有长度上限：最多 2 条 + 总数） */
  private summarizeReasons(reasons: string[]): string {
    if (reasons.length === 0) {
      return '请检查网络';
    }
    const head = reasons.slice(0, 2).join('；');
    return reasons.length > 2 ? `${head} 等 ${reasons.length} 条` : head;
  }


  /** 本页要测的节点集合 = 当前列表里的真实节点行。 */
  private targetNodes(): ProxyNode[] {
    const out: ProxyNode[] = [];
    for (const row of this.nodes) {
      out.push(row.node);
    }
    return out;
  }

  /** 把引擎进度映射到顶栏 UI（唯一数据来源；页面不自己再统计成功/失败） */
  private applyProgress(p: LatencyProgress, driveHeader: boolean): void {
    this.latencyTotal = p.total;
    this.latencyDone = p.finished;
    this.latencyChannelLabel = p.channel;
    this.latencyCoreUnavailable = p.coreUnavailable;
    if (driveHeader) {
      // 顶栏「进度 + 取消」只在批量（含进页面自动补测）时出现：单节点测速的反馈
      // 是那一行的转圈，不该把整条顶栏换成进度条。
      this.batchTesting = p.running;
    }
  }

  /**
   * 本批使用的测速 URL。
   *
   * 口径（与 `BackgroundLatencyService` 完全一致）：
   *  - **兜底目标**（用户没填 / 填了非法值）→ 默认 **HTTPS** 测速地址
   *    （`AppSettings.DEFAULT_TEST_URL`）。理由：mihomo 官方明确告警
   *    `provider.health-check.url` 与 `group.url` 应使用 HTTPS —— 明文测速地址
   *    会被机场/落地劫持，导致整批测速红；5.6.0 真机基线也是 https。
   *  - **用户自填的 URL**（http 或 https 都算）→ **原样使用**，这里不做任何改写。
   *
   * ⚠ 为什么**不**把用户自填的 http 强制改成 https：
   *   真机 commit `a3fe45d` 实证 —— 个别出口掐 gstatic 的 TLS SNI，
   *   同一个出口 https Timeout 而 http 1158ms。用户自填 http 是**有意为之**，
   *   客户端无权替他改（旧实现在这里「非 https 一律回落」，注释与代码长期相反，
   *   且会静默改掉用户的合法配置）。
   *
   * ⚠ 这里**不再自己实现**这套口径：前台批 / 后台批 / 生成器 smart 组三处
   *   各写一份必然漂移（审计 F12）。统一走测速内核的**单一真源**
   *   `effectiveTestUrl`（commons/latency/LatencyProbe）—— 它同时负责
   *   「两个历史 http 默认值单向升级到 https」与「非法值回落默认 https」。
   */
  private latencyProfileId: string = '';
  private latencyRevisions: Map<string, string> = new Map<string, string>();
  private latencyRunActive: boolean = false;

  private refreshLatencyScopes(): void {
    this.latencyProfileId = ProfileRepository.currentId();
    this.latencyRevisions.clear();
    for (const sub of this.subs.subscriptions) {
      this.latencyRevisions.set(sub.id, ProfileRepository.revisionOf(sub.id));
    }
    if (!this.latencyRevisions.has(this.latencyProfileId)) {
      this.latencyRevisions.set(this.latencyProfileId, ProfileRepository.revisionOf(this.latencyProfileId));
    }
  }

  private latencyContext(node: ProxyNode | null = null): LatencyContext {
    const id = node !== null && node.subscriptionId.length > 0 ? node.subscriptionId : this.latencyProfileId;
    return new LatencyContext(id, this.latencyRevisions.get(id) ?? '', this.testUrlForLatency());
  }

  private testUrlForLatency(): string {
    return effectiveTestUrl(this.settings);
  }

  /** Run profile subsets serially through the shared latency service. Each
   * subset has its own core, cancellation owner and measurement identity. */
  private async runLatency(list: ProxyNode[], force: boolean,
    driveHeader: boolean): Promise<LatencyProgress | null> {
    if (list.length === 0 || BackgroundLatencyService.isRunning()) { return null; }
    this.refreshLatencyScopes();
    this.batchCancelled = false;
    this.latencyRunActive = true;
    this.latencyPreparing = true;
    if (driveHeader) {
      this.batchTesting = true; this.latencyTotal = list.length; this.latencyDone = 0;
    }
    const progress = new LatencyProgress();
    progress.total = list.length; progress.running = true;
    const byProfile: Map<string, string[]> = new Map<string, string[]>();
    for (const node of list) {
      const old = LatencyStoreBridge.recordFor(node.name, this.latencyContext(node));
      if (!force && old !== null && old.hasValue() && old.channel === LatencyChannel.CORE
        && !LatencyPolicy.isStale(old, Date.now())) {
        progress.skipped++; progress.finished++; continue;
      }
      const id = node.subscriptionId || this.latencyProfileId;
      const names = byProfile.get(id) ?? [];
      if (!names.includes(node.name)) { names.push(node.name); }
      byProfile.set(id, names);
    }
    let timer: number = -1;
    try {
      const context = getContext(this) as Context;
      for (const batch of byProfile) {
        if (this.batchCancelled) { break; }
        timer = UnifiedScheduler.every((): void => {
          // 准备阶段：内核启动偏慢（在加载订阅规则集）时把原因说出来
          if (this.latencyPreparing) {
            const hint = this.orchestrator.startupHint();
            if (hint !== this.latencyPrepareHint) { this.latencyPrepareHint = hint; }
          }
          const current = TunBoxLatencyService.currentProgress();
          if (driveHeader && current !== null && current.running) {
            this.latencyDone = progress.finished + current.started;
          }
        }, 200);
        const result = await BackgroundLatencyService.testNodes(context, batch[0], batch[1],
          (): void => { this.latencyPreparing = false; }, force ? 'manual' : 'auto');
        UnifiedScheduler.clear(timer); timer = -1;
        if (result === null) {
          progress.cancelled += batch[1].length;
          progress.message = '另一个测速批次正在运行，请稍后重试';
          break;
        }
        progress.finished += result.finished;
        progress.measured += result.measured; progress.timeout += result.timeout;
        progress.failed += result.failed; progress.cancelled += result.cancelled;
        progress.wasCancelled = progress.wasCancelled || result.wasCancelled;
        progress.skipped += result.skipped;
        if (result.message.length > 0) {
          progress.message = result.message;
          if (result.total === 0) { progress.cancelled += batch[1].length; }
        }
        this.applyProgress(progress, driveHeader);
      }
      if (this.batchCancelled) {
        progress.wasCancelled = true;
        progress.cancelled = Math.max(progress.cancelled, progress.total - progress.finished);
      }
      return progress;
    } finally {
      if (timer >= 0) { UnifiedScheduler.clear(timer); }
      progress.running = false;
      this.latencyRunActive = false; this.latencyPreparing = false;
      this.latencyPrepareHint = '';
      if (driveHeader) { this.batchTesting = false; }
      LatencyStoreBridge.flushNow();
    }
  }

  /** 单节点手动测速：与批量走同一引擎、同一套五态语义，只是列表里只有一个节点 */
  private async testOne(node: ProxyNode): Promise<void> {
    if (this.batchTesting || this.testingName.length > 0) {
      promptAction.showToast({ message: '测速进行中' });
      return;
    }
    this.testingName = node.name;
    try {
      // force=true：用户明确点了这一行就一定要重测，绝不拿缓存糊弄（旧实现用
      // 「5 分钟内的缓存」直接返回 toast，用户点了像没反应）。
      const result = await this.runLatency([node], true, false);
      if (this.pageActive && result !== null && result.message.length > 0) {
        promptAction.showToast({ message: result.message });
      }
      // The shared service persists each result with its exact test context.
    } finally {
      this.testingName = '';
    }
  }

  /**
   * 把本轮引擎结果落成持久化排序快照（只在用户主动「测全部」后调用）。
   *
   * 旧实现在 worker 里自己攒 NodeLatencyRecord；现在唯一的结果来源是控制器，
   * 于是这里做一次「状态 → 快照记录」的翻译。翻译必须保留五态语义：
   * 只有 MEASURED 是节点结论；TIMEOUT / FAILED 是结论性失败；OFFLINE（离线粗略，
   * 只证明端口可达）与 TESTING / CANCELLED / UNTESTED 都**不是**代理延迟结论，
   * 标成 PORT_ONLY / UNTESTED 交给 NodeSortSnapshot.buildAuto() 沿用上一次结论，
   * 绝不把通道故障写成"全超时"污染排序。
   *
   * @param tested 本轮参与测速的节点（快照只覆盖它们，其余节点沿用旧结论）
   */
  private async commitLatencySnapshot(tested: ProxyNode[]): Promise<void> {
    const collected: NodeLatencyRecord[] = [];
    for (const node of tested) {
      if (node.subscriptionId !== this.latencyProfileId) { continue; }
      const rec = LatencyStoreBridge.recordFor(node.name, this.latencyContext(node));
      collected.push(rec === null
        ? this.untestedPersistRecord(node.name) : this.toPersistRecord(rec));
    }
    const allNames: string[] = [];
    for (const n of this.subs.nodes) {
      if (n.subscriptionId === this.latencyProfileId) { allNames.push(n.name); }
    }
    if (this.sortSnapshot !== null) { this.sortSnapshot.retainScope(this.latencyContext().key('')); }
    this.sortSnapshot = NodeSortSnapshot.buildAuto(Date.now(), collected, this.sortSnapshot, allNames);
    this.sortSnapshot.scope = this.latencyContext().key('');
    this.sortMode = NodeSortModes.AUTO;
    // 状态徽标来自快照，重建行才会刷新
    this.rebuildRows();
    // 新真源：结论落进 LatencyStore（**字段级**：每个 (节点, 字段) 一个槽）。
    // 排序快照仍是「手动固定顺序 + 排序模式」的载体，而**测速结论**的落盘真源
    // 是 LatencyStore —— 两者不再互相整单覆盖（审计 F2/F4）。
    const names: string[] = [];
    for (const node of tested) {
      if (node.subscriptionId === this.latencyProfileId) { names.push(node.name); }
    }
    await LatencyStoreBridge.persistConclusions(names, this.latencyContext());
  }

  /** 无记录 = 本次没得出节点结论：保持「未测」，交给 buildAuto 沿用旧结论 */
  private untestedPersistRecord(name: string): NodeLatencyRecord {
    const out = new NodeLatencyRecord();
    out.name = name;
    out.latency = -2;
    out.failKind = LatencyProbeKind.UNTESTED;
    return out;
  }

  /** LatencyRecord（五态）→ NodeLatencyRecord（持久化形状），见 commitLatencySnapshot 注释 */
  private toPersistRecord(rec: LatencyRecord): NodeLatencyRecord {
    const out = new NodeLatencyRecord();
    out.name = rec.name;
    // 优先用探测侧给出的分类：state 只有「失败」一档，分不出「内核里没这个节点」
    // (switch_failed) 与「真超时」(timeout) —— 落盘后再分就晚了，只能重新盖章。
    if (rec.failKind.length > 0) {
      out.latency = rec.state === LatencyState.MEASURED ? rec.delayMs
        : (rec.state === LatencyState.OFFLINE ? -2 : -1);
      out.failKind = rec.failKind;
      if (NodeLatencyRecord.isNonVerdict(rec.failKind)) {
        // 非节点判定（通道未就绪/仅端口可达/整批未测）：不是失败结论
        out.latency = -2;
      }
      return out;
    }
    if (rec.state === LatencyState.MEASURED) {
      out.latency = rec.delayMs;
      out.failKind = LatencyProbeKind.NONE;
      return out;
    }
    if (rec.state === LatencyState.TIMEOUT) {
      out.latency = -1;
      out.failKind = LatencyProbeKind.TIMEOUT;
      return out;
    }
    if (rec.state === LatencyState.FAILED) {
      // ⚠ **不要**在这里编造失败分类（审计 F13）。
      // 旧实现把「没有分类的失败」一律盖成 network_unreachable（网络不可达），
      // 于是用户看到「网络不可达」→ 以为节点坏了；实际这次失败可能来自
      // 任何原因（甚至只是这一次探测异常），把它说成「网络不可达」是**假结论**。
      // 正确做法：分类留空（''），由唯一真源 LatencyPolicy.stateText 渲染成
      // 中性的「失败」；落盘后冷启动恢复时，'' 按既定口径算「非结论」
      // （见 LatencyStoreBridge.restore）→ 显示「--」，宁可少说也不说错。
      out.latency = -1;
      out.failKind = '';
      return out;
    }
    // OFFLINE（仅端口可达）/ TESTING / CANCELLED / UNTESTED：不是节点结论
    out.latency = -2;
    out.failKind = rec.state === LatencyState.OFFLINE
      ? LatencyProbeKind.PORT_ONLY : LatencyProbeKind.UNTESTED;
    return out;
  }

  /**
   * 把仍停在「测试中」的记录收回「未测」。
   *
   * 第一责任人是引擎（LatencyEngine.clearOwnTestingMarks，覆盖正常结束/取消/
   * 作废/worker 异常全部退出路径）。这里保留一次是**纵深防御**：页面拿到的 list
   * 可能包含引擎没跑到的节点（比如批次开始前就被取消），多清一次是幂等的，
   * 而漏清的代价是行上永久转圈。
   */
  private clearTestingMarks(_nodes: ProxyNode[]): void {
    // Session cleanup owns the exact runId and scope; pages must not clear another run.
  }

  // ── 批量多选：状态流转与小工具（2026-10-20）────────────────────────────

  /** 长按进入选择态，并把被长按的那个节点先勾上（符合「我长按谁就先选谁」的直觉） */
  private enterSelectMode(nodeId: string): void {
    this.selectMode = true;
    this.selectedNodeIds = [nodeId];
  }

  private exitSelectMode(): void {
    this.selectMode = false;
    this.selectedNodeIds = [];
  }

  private isNodeSelected(nodeId: string): boolean {
    return this.selectedNodeIds.indexOf(nodeId) >= 0;
  }

  /** 选择态下点行 = 勾选/取消勾选；非选择态仍是「选中该节点作为当前出口」 */
  private onNodeTap(node: ProxyNode): void {
    if (this.selectMode) {
      this.toggleSelectedNode(node.id);
      return;
    }
    this.selectNode(node);
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

  /** 全选/取消全选：作用范围 = 当前可见的普通节点（尊重搜索与订阅筛选） */
  private toggleSelectAllNodes(): void {
    const visible: NodeRow[] = this.searchFiltered(this.nodes);
    const ids: string[] = [];
    for (const row of visible) {
      ids.push(row.node.id);
    }
    this.selectedNodeIds = this.selectedNodeIds.length >= ids.length ? [] : ids;
  }

  /** 弹确认框（把名字摘要成一句，避免 30 个节点名把对话框撑爆） */
  private confirmDeleteSelected(): void {
    if (this.selectedNodeIds.length === 0) {
      return;
    }
    const picked: string[] = [];
    for (const id of this.selectedNodeIds) {
      const node = this.subs.findNode(id);
      if (node !== null) {
        picked.push(`「${node.name}」`);
      }
    }
    if (picked.length === 0) {
      this.exitSelectMode();
      return;
    }
    const head: string = picked.slice(0, 3).join('、');
    this.batchDeleteSummary = picked.length > 3 ? `${head} 等 ${picked.length} 个节点` : head;
    this.batchDeleteDialog.open();
  }

  /** 批量删除：逐个走同一 removeNode（失败不中断，最后汇报成功数） */
  private async doDeleteSelected(): Promise<void> {
    const ids: string[] = this.selectedNodeIds.slice();
    if (ids.length === 0) {
      return;
    }
    let removedCount = 0;
    let removedSelected = false;
    for (const id of ids) {
      if (this.settings.preferredNodeId === id) {
        removedSelected = true;
      }
      const ok = await this.subs.removeNode(id);
      if (ok) {
        removedCount += 1;
      }
    }
    if (removedSelected) {
      this.settings.preferredNodeId = '';
      this.settings.preferredNodeName = '';
      // 字段级写：只改偏好三件套，不覆盖别人刚写进去的值
      await SettingsService.patchSettings((s: AppSettings): void => {
        s.preferredNodeId = '';
        s.preferredNodeName = '';
        s.preferredNodeSubscriptionId = '';
      });
      this.selectedName = this.subs.nodes.length > 0 ? this.subs.nodes[0].name : '';
    }
    this.exitSelectMode();
    this.rebuildRows();
    promptAction.showToast({
      message: removedCount === ids.length ? `已删除 ${removedCount} 个节点`
        : `已删除 ${removedCount}/${ids.length} 个（部分失败，可重试）`
    });
  }

  /** Explicit test of the visible flat list, including inactive subscriptions. */
  private async testAll(): Promise<void> {
    if (this.batchTesting || BackgroundLatencyService.isRunning()) {
      promptAction.showToast({ message: '测速进行中' });
      return;
    }
    const list = this.targetNodes();
    if (list.length === 0) {
      promptAction.showToast({ message: '暂无可测速的节点' });
      return;
    }
    const progress = await this.runLatency(list, true, true);
    if (this.batchCancelled) {
      // 用户取消 / 离开页面：已落库的结果保持可见（不回滚）。
      return;
    }
    if (progress === null) {
      if (this.pageActive) {
        promptAction.showToast({ message: '内核不可用，已跳过（未写入超时）' });
      }
      return;
    }
    await this.commitLatencySnapshot(list);
    await this.persistSortState();
    // 组级诊断：整组同因全败 → 折叠成一条诊断条（不铺 N 条同色红条）
    AppLogger.info(TAG, `latency batch done: total=${progress.total} measured=${progress.measured} `
      + `timeout=${progress.timeout} failed=${progress.failed} channel=${progress.channel}`);
    if (this.pageActive) {
      // 0 个目标不叫「测速完成」：内核被回收/目录为空时批次立即结束。
      if (progress.total === 0) {
        promptAction.showToast({ message: '没有可测速的节点：测速内核未就绪，请稍后重试' });
        return;
      }
      promptAction.showToast({ message: progress.completionMessage() });
    }
  }

  private refreshSmartEntry(): void {
    const scope = this.filterSubId || ProfileRepository.currentId();
    const revision = ++this.smartRefreshRevision;
    this.smartSelected = this.settings.autoSelectMode === AutoSelectModes.AUTO
      && this.orchestrator.isSmartModelAvailable()
      && this.settings.preferredNodeSubscriptionId === scope;
    if (this.smartSelected) { this.selectedName = ''; }
    this.orchestrator.smartAvailableFor(scope, this.subs).then((available: boolean): void => {
      if (revision === this.smartRefreshRevision) { this.smartVisible = available; }
    }).catch((): void => {
      if (revision === this.smartRefreshRevision) { this.smartVisible = false; }
    });
  }

  private async selectSmart(): Promise<void> {
    if (this.smartSelecting) { return; }
    this.smartSelecting = true;
    try {
      const restarted = await this.orchestrator.selectSmartSubscription(
        this.filterSubId || ProfileRepository.currentId(), this.subs);
      this.settings = await SettingsService.load();
      this.rebuildRows();
      promptAction.showToast({ message: restarted ? '已启用本订阅智能选择，代理已重启' : '已选择智能选点，下次连接生效' });
    } catch (e) {
      promptAction.showToast({ message: AppLogger.errText(e) });
    } finally { this.smartSelecting = false; }
  }

  private async selectStrategy(parent: ProxyGroup, strategy: ProxyGroup): Promise<void> {
    if (parent.subscriptionId !== strategy.subscriptionId || !parent.members.includes(strategy.name)) { return; }
    const scope = strategy.subscriptionId;
    const intent = new ProxyNode();
    intent.id = 'core:' + strategy.name;
    intent.name = strategy.name;
    intent.originalName = strategy.name;
    intent.subscriptionId = scope;
    try {
      await SettingsService.patchSettings((s: AppSettings): void => {
        s.proxyGroupSelections = ProxyPanelMembers.remember(s.proxyGroupSelections, scope, parent.name, strategy.name);
        s.autoSelectMode = AutoSelectModes.MANUAL;
        s.preferredNodeId = intent.id;
        s.preferredNodeName = intent.name;
        s.preferredNodeSubscriptionId = scope;
        s.preferredNodeNamesBySubscription = AppSettings.rememberPreferredNodeName(
          s.preferredNodeNamesBySubscription, scope, strategy.name);
      });
      this.settings = await SettingsService.load();
      this.selectedName = strategy.name;
      this.refreshSmartEntry();
      this.latencyTick++;
      const revision = AppStorage.get<number>('node_switch_revision') ?? 0;
      AppStorage.setOrCreate('node_switch_revision', revision + 1);
      const didRestart = await this.orchestrator.reconnectWithNode(intent, this.subs, 'proxyGroup=' + strategy.name);
      if (didRestart) {
        const ipRevision = AppStorage.get<number>('public_ip_revision') ?? 0;
        AppStorage.setOrCreate('public_ip_revision', ipRevision + 1);
      }
      promptAction.showToast({ message: didRestart
        ? `已选择 ${strategy.name}，代理已重启` : `已保存 ${strategy.name}` });
    } catch (e) {
      AppLogger.warn(TAG, `select strategy failed: ${AppLogger.errText(e)}`);
      promptAction.showToast({ message: '切换策略失败，请重试' });
    }
  }

  private async selectNode(node: ProxyNode): Promise<void> {
    // 用户显式选节点时退出旧版 App 自动选点模式；订阅策略组选择另走 selectStrategy。
    if (this.settings.autoSelectMode === AutoSelectModes.AUTO) {
      this.settings.autoSelectMode = AutoSelectModes.MANUAL;
      AppLogger.info(TAG, `manual node pick (${node.name}); auto mode disabled`);
    }
    this.settings.preferredNodeId = node.id;
    this.settings.preferredNodeName = node.name;
    if (node.subscriptionId.length > 0) {
      this.settings.preferredNodeSubscriptionId = node.subscriptionId;
    }
    this.selectedName = node.name;
    this.smartSelected = false;
    // 字段级写：只改偏好三件套（id/名字快照/所属订阅）
    await SettingsService.patchSettings((s: AppSettings): void => {
      s.autoSelectMode = AutoSelectModes.MANUAL;
      s.preferredNodeId = node.id;
      s.preferredNodeName = node.name;
      s.preferredNodeSubscriptionId = node.subscriptionId;
      // 按订阅分槽记住手动选择：切走再切回来要还原这个节点（与订阅页同口径）。
      s.preferredNodeNamesBySubscription = AppSettings.rememberPreferredNodeName(
        s.preferredNodeNamesBySubscription, node.subscriptionId, node.name);
    });
    // 节点切换始终执行完整重连。Mihomo controller 返回 2xx 只能证明请求被接受，
    // 不能证明现有连接已迁移到新节点；此前因此错误提示“未重建隧道”，但流量仍走旧节点。
    const nodeRevision = AppStorage.get<number>('node_switch_revision') ?? 0;
    AppStorage.setOrCreate('node_switch_revision', nodeRevision + 1);
    let didRestart: boolean = false;
    try {
      didRestart = await this.orchestrator.reconnectWithNode(node, this.subs, 'preferredNode=' + node.id);
    } catch (e) {
      AppLogger.warn(TAG, `reconnect after node pick failed: ${AppLogger.errText(e)}`);
      promptAction.showToast({ message: '已保存选择，但代理重启失败，请重试' });
      return;
    }
    // 通知仍驻留在导航栈中的主页：重连完成后重新查询出口公网 IP，不能继续显示旧 @State 缓存。
    if (didRestart) {
      const revision = AppStorage.get<number>('public_ip_revision') ?? 0;
      AppStorage.setOrCreate('public_ip_revision', revision + 1);
    }
    promptAction.showToast({
      message: didRestart ? `已选择 ${node.name}，代理已重启` : `已选择 ${node.name}，下次连接生效`
    });
  }

  /** 路由推入式子页统一转场：水平滑动 + 淡入淡出（与页签切换同规格，见 TunBoxMotion） */
  pageTransition() {
    PageTransitionEnter({ duration: TunBoxMotion.ms, curve: TunBoxMotion.curve })
      .translate({ x: TunBoxMotion.slidePercent, y: 0 }).opacity(0)
    PageTransitionExit({ duration: TunBoxMotion.ms, curve: TunBoxMotion.curve })
      .translate({ x: `-${TunBoxMotion.slidePercent}`, y: 0 }).opacity(0)
  }

  build() {
    Stack() {
      Column()
        .width('100%').height('100%')
        // 与其余页面同一条背景渐变（原来是平色，转场时与渐变页之间底部颜色会跳）
        .linearGradient({ angle: 180, colors: [[TunBoxColors.bgGradientStart(this.themeRevision), 0.0], [TunBoxColors.bgGradientEnd(this.themeRevision), 1.0]] })
        // 背景延伸到状态栏/底部导航条之下, 消除底部白条
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        // ── 批量多选顶栏（长按任一节点进入；非选择态不渲染）──
        if (this.selectMode) {
          Row({ space: 10 }) {
            Row() {
              Image($r('app.media.ic_close'))
                .width(18).height(18).fillColor(Ui.textPrimaryFor(this.themeRevision))
            }
            .width(36).height(36)
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .borderRadius(18)
            .backgroundColor(Ui.surfaceMuted(this.themeRevision))
            .onClick(() => this.exitSelectMode())
            Text(`已选 ${this.selectedNodeIds.length}`)
              .fontSize(16).fontWeight(FontWeight.Bold)
              .fontColor(Ui.textPrimaryFor(this.themeRevision))
              .layoutWeight(1)
            Text('全选')
              .fontSize(13).fontColor(Ui.primaryFor(this.themeRevision))
              .height(36)
              .padding({ left: 12, right: 12 })
              .borderRadius(18)
              .backgroundColor(Ui.primaryBlueFillFor(this.themeRevision))
              .borderWidth(1).borderColor(Ui.borderStrong)
              .textAlign(TextAlign.Center)
              .onClick(() => this.toggleSelectAllNodes())
            Row({ space: 5 }) {
              Image($r('app.media.ic_delete'))
                .width(14).height(14)
                .fillColor(this.selectedNodeIds.length > 0 ? Ui.error : Ui.textTertiaryFor(this.themeRevision))
              Text('删除')
                .fontSize(13).fontWeight(FontWeight.Medium)
                .fontColor(this.selectedNodeIds.length > 0 ? Ui.error : Ui.textTertiaryFor(this.themeRevision))
            }
            .height(36)
            .padding({ left: 12, right: 12 })
            .borderRadius(18)
            .backgroundColor(Ui.surfaceMuted(this.themeRevision))
            .borderWidth(1).borderColor(Ui.border)
            .onClick(() => this.confirmDeleteSelected())
          }
          .width('100%')
          .height(56)
          .padding({ left: 16, right: 16 })
          // 进入/退出多选：操作栏淡入轻落，退出原路返回（原来是直接弹出，下面整页跟着跳 56vp）
          .transition(TunBoxMotion.revealDown())
        }

        // ── 顶栏（对齐原版: 返回 + 当前节点 + 刷新/闪电图标组） ──
        Row() {
          Row() {
            Image($r('app.media.ic_arrow_left'))
              .width(20).height(20)
              .fillColor(Ui.textPrimaryFor(this.themeRevision))
          }
          .width(36).height(36)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .borderRadius(18)
          .backgroundColor(Ui.surfaceMuted(this.themeRevision))
          .onClick(() => router.back())
          Row({ space: 7 }) {
            CountryFlagIcon({
              nodeName: this.selectedName.length > 0 ? this.selectedName : 'UN',
              iconSize: 22
            })
            Text(this.selectedName.length > 0 ? this.selectedName : '选择节点')
              .fontSize(16).fontWeight(FontWeight.Bold)
              .fontColor(Ui.textPrimaryFor(this.themeRevision))
              // 直接使用完整原始节点名。禁止 compact/去旗标/截断/maxLines/Ellipsis，
              // 让 MARQUEE 对完整字符串循环滚动。
              .textOverflow({ overflow: TextOverflow.MARQUEE })
              .layoutWeight(1)
          }
          .layoutWeight(1)
          .constraintSize({ minWidth: 0 })
          .margin({ left: 12, right: 12 })
          // 刷新 + 排序方式 + 测速（测速中变成「进度 + 取消」）
          Row({ space: 10 }) {
            Row() {
              Image($r('app.media.ic_refresh'))
                .width(20).height(20)
                .fillColor(this.refreshing ? Ui.primaryFor(this.themeRevision) : Ui.textPrimaryFor(this.themeRevision))
            }
            .width(36).height(36)
            .justifyContent(FlexAlign.Center)
            .alignItems(VerticalAlign.Center)
            .borderRadius(18)
            .backgroundColor(Ui.surfaceMuted(this.themeRevision))
            .onClick(() => this.refreshNodes())
            if (this.refreshing) {
              Text(`${this.refreshDone}/${this.refreshTotal}`)
                .fontSize(11)
                .fontWeight(FontWeight.Bold)
                .fontColor(Ui.primaryFor(this.themeRevision))
            }
            Row({ space: 4 }) {
              Image(this.sortMode === NodeSortModes.MANUAL
                ? $r('app.media.ic_lock') : $r('app.media.ic_sort'))
                .width(16).height(16)
                .fillColor(this.sortMode === NodeSortModes.DEFAULT ? Ui.textPrimaryFor(this.themeRevision) : Ui.primaryFor(this.themeRevision))
              Text(this.sortMode === NodeSortModes.AUTO ? '自动排序'
                : (this.sortMode === NodeSortModes.MANUAL ? '手动固定' : '默认顺序'))
                .fontSize(11)
                .fontColor(this.sortMode === NodeSortModes.DEFAULT ? Ui.textSecondaryFor(this.themeRevision) : Ui.primaryFor(this.themeRevision))
            }
            .height(36)
            .padding({ left: 10, right: 10 })
            .borderRadius(18)
            .backgroundColor(this.sortMode === NodeSortModes.DEFAULT ? Ui.surfaceMuted(this.themeRevision) : Ui.primaryBlueFillFor(this.themeRevision))
            .onClick(() => this.cycleSortMode())
            // 组测一起出结果（约 3 秒），进度条没有意义——已去掉（用户要求）。
            // 通道（内核/凭证）不可用时明确告诉用户原因。
            Row({ space: 8 }) {
              if (this.latencyPreparing) {
                // 通道还没就绪（要拉起测速内核，秒级）：明确告诉用户在等什么
                Text(this.latencyPrepareHint.length > 0 ? this.latencyPrepareHint : '准备测速通道…')
                  .fontSize(11)
                  .fontColor(Ui.textSecondaryFor(this.themeRevision))
              } else if (this.latencyCoreUnavailable) {
                Text('内核不可用，本轮未测')
                  .fontSize(11)
                  .fontColor(Ui.warning)
              }
              // 测试中「测全部」变成转圈反馈（用户要求）：不然以为没点上
              if (this.batchTesting) {
                LoadingProgress().width(20).height(20).color(Ui.primaryFor(this.themeRevision))
                  .onClick(() => this.testAll())
              } else {
                Row({ space: 5 }) {
                  Image($r('app.media.ic_bolt'))
                    .width(14).height(14)
                    .fillColor(Ui.primaryFor(this.themeRevision))
                  Text('测全部')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Ui.primaryFor(this.themeRevision))
                }
                .height(36)
                .padding({ left: 12, right: 12 })
                .borderRadius(18)
                .backgroundColor(Ui.primaryBlueFillFor(this.themeRevision))
                .borderWidth(1)
                .borderColor(Ui.borderStrong)
                .onClick(() => this.testAll())
              }
            }
          }
        }
        .width('100%')
        .height(56)
        .padding({ left: 16, right: 16 })
        // 选择态下整条常规顶栏让位给上面的「已选 N · 全选 · 删除」条
        .visibility(this.selectMode ? Visibility.None : Visibility.Visible)

        // ── 订阅筛选 chips ──
        if (this.subChips.length > 0) {
          Scroll() {
            Row({ space: 8 }) {
              Text('全部')
                .fontSize(13)
                .fontWeight(this.filterSubId.length === 0 ? FontWeight.Bold : FontWeight.Medium)
                .fontColor(this.filterSubId.length === 0 ? Ui.primaryFor(this.themeRevision) : Ui.textSecondaryFor(this.themeRevision))
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .borderRadius(100)
                .backgroundColor(this.filterSubId.length === 0 ? Ui.primaryBlueFillFor(this.themeRevision) : Ui.surfaceMuted(this.themeRevision))
                .borderWidth(1)
                .borderColor(this.filterSubId.length === 0 ? Ui.borderStrong : Ui.border)
                .onClick(() => {
                  this.filterSubId = '';
                  this.rebuildRows();
                })
              ForEach(this.subChips, (chip: SubChip) => {
                Text(chip.name)
                  .fontSize(13)
                  .fontWeight(this.filterSubId === chip.id ? FontWeight.Bold : FontWeight.Medium)
                  .fontColor(this.filterSubId === chip.id ? Ui.primaryFor(this.themeRevision) : Ui.textSecondaryFor(this.themeRevision))
                  .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                  .borderRadius(100)
                  .backgroundColor(this.filterSubId === chip.id ? Ui.primaryBlueFillFor(this.themeRevision) : Ui.surfaceMuted(this.themeRevision))
                  .borderWidth(1)
                  .borderColor(this.filterSubId === chip.id ? Ui.borderStrong : Ui.border)
                  .onClick(() => {
                    this.filterSubId = chip.id;
                    this.rebuildRows();
                  })
              }, (chip: SubChip) => chip.id + '#' + chip.name)
            }
          }.edgeEffect(EdgeEffect.Spring)
        .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(TunBoxGeometry.scrollFadeEdge) })
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
          // 与上方快捷按钮拉开间距
          .padding({ left: 18, right: 18, top: 18, bottom: 6 })
        }

        // 订阅的实际策略组决定选点，旧版 AUTO 偏好不能证明内核启用了 Smart。
        Row({ space: 6 }) {
          Image($r('app.media.ic_network'))
            .width(14).height(14)
            .fillColor(Ui.textSecondaryFor(this.themeRevision))
          Text('点击选择节点或策略组 · 长按节点可删除')
            .fontSize(11)
            .fontColor(Ui.textSecondaryFor(this.themeRevision))
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .borderRadius(14)
        .backgroundColor(Ui.surface(this.themeRevision))
        .borderWidth(1)
        .borderColor(Ui.glassEdge(this.themeRevision))
        .margin({ left: 18, right: 18, top: 10 })

        // ── 节点列表 ──
        // 说明文案只保留上方那条横幅（模式 + 长按删除提示），
        // 此前这里还有一行「排序：自动排序（按测速结果）」与横幅重复，已移除。
        if (this.smartVisible && !this.selectMode) {
          Row({ space: 10 }) {
            Image($r('app.media.ic_radar')).width(22).height(22)
              .fillColor(Ui.primaryFor(this.themeRevision))
            Column({ space: 4 }) {
              Text('♻️ 自动选择').fontSize(15).fontWeight(FontWeight.Bold)
                .fontColor(Ui.textPrimaryFor(this.themeRevision))
              Text('Smart 智能选点 · 只在本订阅内择优').fontSize(11)
                .fontColor(Ui.textSecondaryFor(this.themeRevision))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Stack({ alignContent: Alignment.Center }) {
              Circle({ width: 20, height: 20 })
                .fill(this.smartSelected ? Ui.primaryFor(this.themeRevision) : Color.Transparent)
                .stroke(this.smartSelected ? Ui.primaryFor(this.themeRevision) : Ui.textTertiaryFor(this.themeRevision))
                .strokeWidth(1.6)
              if (this.smartSelected) {
                Circle({ width: 7, height: 7 }).fill(Color.White)
              }
            }
            .width(20).height(20).flexShrink(0)
            .accessibilityText(this.smartSelected ? '自动选择：已选中' : '自动选择：未选中')
          }
          .padding(14).margin({ left: 18, right: 18, bottom: 8 }).borderRadius(16)
          .backgroundColor(this.smartSelected ? Ui.primaryBlueFillFor(this.themeRevision) : Ui.surface(this.themeRevision))
          .enabled(!this.smartSelecting).onClick(() => this.selectSmart())
        }
        if (this.nodes.length === 0) {
          Column({ space: 12 }) {
            Image($r('app.media.ic_network'))
              .width(46).height(46)
              .fillColor(Ui.textTertiaryFor(this.themeRevision))
            Text('暂无可用节点')
              .fontSize(15).fontColor(Ui.textSecondaryFor(this.themeRevision))
          }
          .width('100%')
          .margin({ top: 120 })
        } else if (this.groupRows.length > 0) {
          List({ space: 9, scroller: this.listScroller }) {
            ForEach(this.groupRows, (groupRow: ProxyGroupRow) => {
              ListItem() {
                Column({ space: 7 }) {
                  Row({ space: 10 }) {
                    Image(this.isGroupExpanded(groupRow.group)
                      ? $r('app.media.ic_chevron_down') : $r('app.media.ic_arrow_right'))
                      .width(18).height(18)
                      .fillColor(Ui.primaryFor(this.themeRevision))
                    Column({ space: 2 }) {
                      Text(groupRow.group.name)
                        .fontSize(16)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(Ui.textPrimaryFor(this.themeRevision))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(this.groupSubtitle(groupRow))
                        .fontSize(11)
                        .fontColor(Ui.textSecondaryFor(this.themeRevision))
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                  }
                  .width('100%')
                  .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                  .borderRadius(18)
                  .backgroundColor(Ui.surface(this.themeRevision))
                  .borderWidth(1)
                  .borderColor(Ui.glassEdge(this.themeRevision))
                  .onClick(() => this.toggleGroup(groupRow.group))

                  if (this.isGroupExpanded(groupRow.group)) {
                    // 自动选择、故障转移、负载均衡等策略作为 selector 的同级可选项。
                    ForEach(groupRow.strategyGroups, (strategy: ProxyGroup) => {
                      Row({ space: 10 }) {
                        Image($r('app.media.ic_tune'))
                          .width(18).height(18)
                          .fillColor(Ui.primaryFor(this.themeRevision))
                        Column({ space: 2 }) {
                          Text(strategy.name)
                            .fontSize(14)
                            .fontWeight(FontWeight.Medium)
                            .fontColor(Ui.textPrimaryFor(this.themeRevision))
                            .maxLines(1)
                            .textOverflow({ overflow: TextOverflow.Ellipsis })
                          Text(`${strategy.groupType} · ${strategy.members.length} 个节点`)
                            .fontSize(10)
                            .fontColor(Ui.textSecondaryFor(this.themeRevision))
                        }
                        .layoutWeight(1)
                        .alignItems(HorizontalAlign.Start)
                        Image(this.selectedStrategyName(groupRow.group) === strategy.name
                          ? $r('app.media.ic_check') : $r('app.media.ic_arrow_right'))
                          .width(18).height(18)
                          .fillColor(this.selectedStrategyName(groupRow.group) === strategy.name
                            ? Ui.primaryFor(this.themeRevision) : Ui.textTertiaryFor(this.themeRevision))
                      }
                      .width('100%')
                      .padding({ left: 14, right: 14, top: 11, bottom: 11 })
                      .borderRadius(14)
                      .backgroundColor(Ui.surfaceMuted(this.themeRevision))
                      .borderWidth(1)
                      .borderColor(Ui.glassEdge(this.themeRevision))
                      .onClick(() => this.selectStrategy(groupRow.group, strategy))
                    }, (strategy: ProxyGroup) => this.groupKey(groupRow.group) + '#strategy#'
                      + this.groupKey(strategy))

                    // 直接挂在本组下的普通节点成员
                    ForEach(groupRow.memberNodes, (row: NodeRow) => {
                      Row() {
                        this.NodeCard(row)
                      }
                      .gesture(LongPressGesture().onAction(() => {
                        // 长按进入批量多选（2026-10-20）：先勾上被长按的这个节点
                        this.enterSelectMode(row.node.id);
                      }))
                    }, (row: NodeRow) => this.groupKey(groupRow.group) + '#m#' + row.node.id + '#' + this.testingName
                      + '#' + this.statusKey(row.status))
                  }
                }
                .width('100%')
              }
            }, (groupRow: ProxyGroupRow) => this.groupKey(groupRow.group) + '#'
              + this.expandedGroupKeys.join('|') + '#' + this.testingName)
          }.edgeEffect(EdgeEffect.Spring)
        .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(TunBoxGeometry.scrollFadeEdge) })
          .layoutWeight(1)
          .padding({ left: 18, right: 18, top: 8, bottom: 20 })
          .scrollBar(BarState.Off)
        } else {
          TextInput({ placeholder: '搜索节点名…', text: this.searchText })
            .onChange((value: string) => { this.searchText = value; })
            .height(42).fontSize(13)
            .backgroundColor(Ui.inputBackground(this.themeRevision)).borderRadius(14)
            .borderWidth(1).borderColor(Ui.border)
            .padding({ left: 12, right: 12 })
            .margin({ left: 18, right: 18, top: 4 })
          List({ space: 7, scroller: this.listScroller }) {
            ForEach(this.searchFiltered(this.nodes), (row: NodeRow) => {
              ListItem() {
                this.NodeCard(row)
              }
              // 合成行不可删除：它不在订阅里，DELETE 会拿一个不存在的 id 去删。
              .gesture(LongPressGesture().onAction(() => {
                if (CoreNodeBridge.isShadow(row.node)) {
                  return;
                }
                // 长按进入批量多选（2026-10-20）
                this.enterSelectMode(row.node.id);
              }))
            }, (row: NodeRow) => row.node.id + '#' + this.testingName + '#' + this.statusKey(row.status))
          }.edgeEffect(EdgeEffect.Spring)
        .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(TunBoxGeometry.scrollFadeEdge) })
          .layoutWeight(1)
          .padding({ left: 18, right: 18, top: 8, bottom: 20 })
          .scrollBar(BarState.Off)
        }
      }
      .width('100%').height('100%')
      // 2026-10-30：窗口沉浸式后布局不再避让状态栏，自绘顶栏要自己让出这一条
      // （见 theme/SafeArea.ets；仍在避让的设备上 topPad() 为 0，不会重复留白）
      .padding({ top: SafeArea.topPad() })
    }
    .width('100%').height('100%')
  }

  /**
   * 协议小字（第二行，名称下方）：vless/vmess/trojan/ss/ssr/hysteria2，
   * REALITY 节点追加 ·REALITY 并以主题紫区分。
   * 与名称同行挤放时协议和名称都容易截断，改为独立小字行（无边框徽标，不占宽度）。
   */
  @Builder
  ProtocolText(node: ProxyNode) {
    Text(NodeProtocolPolicy.fromNode(node).display())
      .fontSize(10)
      .fontWeight(FontWeight.Medium)
      .fontColor(NodeProtocolPolicy.isRealityNode(node) ? Ui.textViolet : Ui.textTertiaryFor(this.themeRevision))
  }

  /** 通用小徽标 */
  @Builder
  Badge(text: ResourceStr, color: ResourceColor) {
    Text(text)
      .fontSize(10)
      .fontWeight(FontWeight.Medium)
      .fontColor(color)
      .padding({ left: 6, right: 6, top: 1, bottom: 1 })
      .borderRadius(6)
      .backgroundColor(Ui.statusTint)
  }

  /**
   * 节点状态徽标（来自持久化测速快照）。
   *
   * 只展示对用户可操作的状态：未测速 / 连续失败次数 / 成功率。数字「综合评分」
   * 不再展示 —— 它是 SmartSelector 内部用于自动选点与故障切换排序的代价
   * （ms 等价值，越小越好），对用户没有直接可操作性，显示反而造成困惑；
   * 评分计算保留，供将来开启自动选点时使用。
   *
   * 「冷却中」徽标已移除：冷却只影响 SmartSelector 内部选点权重（保留不动），
   * 对用户没有可操作动作，展示它只会造成「节点坏了」的误导。
   */
  @Builder
  NodeStatusBadge(st: NodeStatusView) {
    Row({ space: 5 }) {
      if (!st.hasData) {
        this.Badge($r('app.string.node_badge_untested'), Ui.textTertiaryFor(this.themeRevision))
      } else {
        if (st.failCount > 0) {
          this.Badge($r('app.string.node_badge_failed_count', st.failCount), Ui.warning)
        } else {
          this.Badge($r('app.string.node_badge_success_rate', st.rateLabel), Ui.success)
        }
      }
    }
  }

  /** 批量多选的勾选圆点（只在选择态渲染：未选空心、选中实心 + 白勾）。
   *  这里必须按 id 现查状态：@Builder 的按值参数不会随 @State 刷新，
   *  之前把 boolean 传进来，点一行圆点不变色（2026-10-26 排查同类显示 bug）。 */
  @Builder
  SelectDot(nodeId: string) {
    Row() {
      if (this.isNodeSelected(nodeId)) {
        Image($r('app.media.ic_check'))
          .width(12).height(12)
          .fillColor(Color.White)
      }
    }
    .width(20).height(20)
    .borderRadius(10)
    .borderWidth(1.5)
    .borderColor(this.isNodeSelected(nodeId) ? Ui.primaryFor(this.themeRevision) : Ui.borderStrong)
    .backgroundColor(this.isNodeSelected(nodeId) ? Ui.primaryFor(this.themeRevision) : Color.Transparent)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  NodeCard(row: NodeRow) {
    this.RealNodeCard(row)
  }

  @Builder
  RealNodeCard(row: NodeRow) {
    Row() {
      Row({ space: 12 }) {
        if (this.selectMode) {
          this.SelectDot(row.node.id)
        }
        CountryFlagIcon({ nodeName: row.node.name, iconSize: 26 })
        Column({ space: 3 }) {
          // ── 第一行：名称 + 延迟 ──
          // 延迟徽标从卡片右列移入名称行末：名称 layoutWeight(1) 吃满剩余宽度，
          // 延迟固定靠右；徽标/↻ 的 onClick 与「点行选中」是父子关系，
          // ArkUI 点击命中子组件即消费、不冒泡，测速不会误触发选中。
          Row({ space: 8 }) {
            Text(NodeDisplay.withoutLeadingFlag(row.node.name))
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor(row.node.name === this.selectedName ? Ui.primaryFor(this.themeRevision) : Ui.textPrimaryFor(this.themeRevision))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            // 延迟徽标：五态可区分（未测 `--` / 测试中转圈 / 实测 ms / 离线粗略 ≈ms / 超时·失败）。
            // 旧实现把「没测过」「失败」「超时」一律画成「超时」，这是本页最大的可信度问题。
            Row({ space: 2 }) {
              if (LatencyStoreBridge.stateFor(row.node.name, this.latencyContext(row.node)) === LatencyState.TESTING) {
                LoadingProgress()
                  .width(16)
                  .height(16)
                  .color(Ui.primaryFor(this.themeRevision))
              } else {
                Text(LatencyStyle.recordText(LatencyStoreBridge.recordFor(row.node.name, this.latencyContext(row.node)), Date.now()))
                  .fontSize(14)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(LatencyStyle.recordColor(LatencyStoreBridge.recordFor(row.node.name, this.latencyContext(row.node)), Date.now(), this.themeRevision))
              }
              Image($r('app.media.ic_refresh'))
                .width(14).height(14)
                .fillColor(Ui.textSecondaryFor(this.themeRevision))
                .padding({ left: 2, right: 6 })
                .onClick(() => this.testOne(row.node))
            }
            .onClick(() => this.testOne(row.node))
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          // ── 第二行：协议小字 + 状态徽标 ──
          Row({ space: 6 }) {
            this.ProtocolText(row.node)
            this.NodeStatusBadge(row.status)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .onClick(() => this.onNodeTap(row.node))

      Image($r('app.media.ic_check'))
        .width(18).height(18)
        .fillColor(Ui.primaryFor(this.themeRevision))
        .width(24)
        .opacity(row.node.name === this.selectedName ? 1 : 0)
    }
    .width('100%')
    .padding({ left: 14, right: 6, top: 10, bottom: 10 })
    .borderRadius(16)
    .backgroundColor(row.node.name === this.selectedName ? Ui.primaryBlueFillFor(this.themeRevision) : Ui.surface(this.themeRevision))
    .borderWidth(row.node.name === this.selectedName ? 1.5 : 1)
    .borderColor(row.node.name === this.selectedName ? Ui.primaryFor(this.themeRevision) : Ui.glassEdge(this.themeRevision))
  }

}
