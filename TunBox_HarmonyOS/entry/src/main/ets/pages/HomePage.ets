/**
 * HomePage —— TunBox 主页（严格对齐《TunBox-UI重构笔记》§3.1 首页）
 * 布局：TopNavBar(TunBox + 主题按钮；备份入口已迁到设置页) → 天体轨域启动按钮(CelestialPowerOrb 320/280/200，
 *      2026-10-17 用户按 stitch 设计稿重构，原 StatusRing 三层同心环下架；按钮内含当前节点名)
 *      → 公网 IP(启动按钮正下方) → 代理模式三段按钮(规则/全局/直连) → 订阅区块 → 错误条
 * 2026-10-17：规则模式卡片下架，三项迁入 SettingsPage（用户 batch-2）。
 * 后端：复用 ConnectionOrchestrator / SubscriptionService / SettingsService / LatencyController 全量逻辑（未改动）。
 */
import { router, promptAction } from '@kit.ArkUI';
import { UnifiedScheduler } from '../commons/services/UnifiedScheduler';
import { ConnEvent, ConnEventKind, ConnListener } from '../commons/services/ConnectionEvents';
import { window } from '@kit.ArkUI';
import { TunBoxColors, TunBoxGeometry } from '../theme/TunBoxTokens';
import { TopNavBar } from '../components/TopNavBar';
import { CelestialPowerOrb } from '../components/CelestialPowerOrb';
import { SubscriptionSection } from '../components/SubscriptionSection';
import { TrafficStatsStore } from '../commons/services/TrafficStatsStore';
import { TabLifecycleBridge } from '../commons/utils/TabLifecycleBridge';
import { ConnectionOrchestrator, ConnState } from '../commons/services/ConnectionOrchestrator';
import { SubscriptionService } from '../commons/services/SubscriptionService';
import { SettingsService } from '../commons/services/SettingsService';
import { PublicIpService } from '../commons/services/PublicIpService';
import { PublicIpInfo, AppDiagnostics } from '../commons/models/PublicIpInfo';
import { AppSettings } from '../commons/models/AppSettings';
import { LatencyStoreBridge } from '../commons/services/LatencyStoreBridge';
import { FormStateSync } from '../commons/services/FormStateSync';
import { UiGuardian } from '../commons/services/UiGuardian';
import { DiagnosticsSheet } from '../widgets/DiagnosticsSheet';
import { AppLogger } from '../commons/utils/AppLogger';
import { ThemeService } from '../theme/ThemeService';
import { ProxyNode } from '../commons/models/ProxyNode';
import { NodeSortSnapshot } from '../commons/services/NodeSortPersistence';

const TAG = 'HomePage';

@Component
export struct HomePage {
  /**
   * 节点切换版本号：主页订阅区块选完节点后自增，用来**立刻**刷新启动按钮内的节点名
   * （2026-10-28 用户报障：选完节点要等启动后才更新）。
   */
  @StorageLink('node_switch_revision') @Watch('onNodeSwitched') nodeSwitchRevision: number = 0;
  @State isConnected: boolean = false;
  @State isConnecting: boolean = false;
  /** 乐观反馈（2026-10-17 用户反馈「点启动 1 秒多按钮才动」）：点击瞬间点亮「正在连接」，
   *  覆盖订阅 hydrate 等待（冷启最多 ~1.5s）与 connect 进入 CONNECTING 前的空窗；
   *  编排器状态翻转后由真实 isConnecting 接管，流程结束（含失败/无节点）即清除 */
  @State pendingStart: boolean = false;
  /**
   * 冷启动节点尚未就绪（订阅 hydrate / 首次刷新还没出节点）。
   * true 时启动按钮显示「节点加载中…」，用户点了也不能直接连 —— 否则
   * 立刻点启动会拿空/旧节点表生成配置，最后报「节点选择未生效」。
   */
  @State nodesLoading: boolean = true;
  /** 用户已在加载中点了启动：节点就绪后自动补一次连接（再点一次取消） */
  private pendingConnectAfterNodes: boolean = false;
  private nodeWatchTimer: number = -1;
  @State errorMessage: string = '';
  @State publicIp: string = '';
  @State publicIpRefreshing: boolean = false;
  @State publicIpError: string = '';
  /**
   * 公网 IP 查询代次（2026-10-19 稳定性）。
   * 每次 refreshPublicIp 自增；回调只在「自己仍是最新一次」时写 UI。
   * 详见 refreshPublicIp 的注释 —— 这是 0.4.0「取不到公网 IP」的直接修复。
   */
  private ipQuerySeq: number = 0;
  @State currentNodeName: string = '';
  @State showDiagnostics: boolean = false;
  @State diagData: AppDiagnostics | null = null;
  @State proxyMode: string = 'rule';
  @StorageLink('theme_revision') themeRevision: number = 0;
  @StorageLink('public_ip_revision') @Watch('onPublicIpRevision') publicIpRevision: number = 0;
  @StorageLink('vpn_request_seq') @Watch('onVpnRequest') vpnRequestSeq: number = 0;
  private pageReady: boolean = false;
  private bootstrapTask: Promise<void> | null = null;
  private pageMounted: boolean = false;
  /** 宿主（MainPage）「重新展示」通知桥：替代 @Entry 页面的 onPageShow（见 TabLifecycleBridge） */
  shownBridge?: TabLifecycleBridge;
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private subs: SubscriptionService = SubscriptionService.instance();
  private settings: AppSettings = new AppSettings();
  private readonly connectionListener: () => void = (): void => {
    this.applyOrchestratorState();
  };
  /** 类型化事件订阅（2026-10-27）：速率/出口/状态都走推送，页面不再自采样。 */
  private connEventsToken: number = -1;
  private readonly onConnEvent: ConnListener = (e: ConnEvent): void => {
    if (!this.pageMounted) { return; }
    if (e.kind === ConnEventKind.TRAFFIC) {
      // 速率/流量展示已全部迁到「数据」页（2026-10-28 用户要求：主页不再放信息卡）。
      // 这里只保留服务卡片（miniBar）消费的两个 AppStorage 速率信号。
      AppStorage.setOrCreate('mini_conn_up', e.upSpeed);
      AppStorage.setOrCreate('mini_conn_down', e.downSpeed);
      return;
    }
    if (e.kind === ConnEventKind.EXIT) {
      this.refreshDisplayNode();
      return;
    }
    // STATE：对齐整屏状态（含守护注册、miniBar、按钮态）
    this.applyOrchestratorState();
  };
  private listenerBound: boolean = false;
  /** 节点集变化监听（稳定引用，便于 aboutToDisappear 退订）。 */
  private readonly nodeSetListener: (reason: string) => void = (reason: string): void => {
    if (this.pageMounted && this.hasUsableNodes()) {
      this.onNodesBecameReady();
    }
  };

  aboutToAppear(): void {
    this.pageMounted = true;
    // 连接状态监听先于磁盘初始化绑定，避免恢复 UI 的异步窗口丢失状态变化。
    if (!this.listenerBound) {
      this.listenerBound = true;
      this.orchestrator.addListener(this.connectionListener);
      this.connEventsToken = this.orchestrator.subscribeConnEvents(this.onConnEvent);
    }
    if (this.shownBridge !== undefined) {
      this.shownBridge.setShowHandler((): void => { this.refreshForShown(); });
    }
    this.bootstrap();
  }

  /** 宿主通知的「重新展示」：已初始化时仅刷新轻量运行态。 */
  refreshForShown(): void {
    if (!this.pageReady) {
      this.bootstrap();
      return;
    }
    this.applyOrchestratorState();
  }

  aboutToDisappear(): void {
    this.pageMounted = false;
    this.pageReady = false;
    this.stopNodeReadinessWatch();
    SubscriptionService.offNodeSetChanged(this.nodeSetListener);
    if (this.shownBridge !== undefined) {
      this.shownBridge.setShowHandler(null);
    }
    if (this.connEventsToken >= 0) {
      this.orchestrator.unsubscribeConnEvents(this.connEventsToken);
      this.connEventsToken = -1;
    }
    if (this.listenerBound) {
      this.orchestrator.removeListener(this.connectionListener);
      this.listenerBound = false;
    }
  }

  private knownNodeNames(): string[] {
    return this.subs.nodes.map((n: ProxyNode): string => n.name);
  }


  private applyOrchestratorState(): void {
    const wasConnected: boolean = this.isConnected;
    this.isConnected = this.orchestrator.state === ConnState.CONNECTED;
    // 连接状态翻转时作废在飞的 IP 查询（2026-10-19 稳定性）：
    // 出口从「本机宽带」变成「代理」或反过来，旧查询的结论对新状态无意义；
    // 若让它晚到并写 UI，就会出现「刚连上显示的还是直连 IP / 刚断开显示代理 IP」。
    // 代次递增后，旧回调的结果会被 refreshPublicIp 直接丢弃。
    if (wasConnected !== this.isConnected) {
      this.invalidatePublicIpQueries();
    }
    // App 内手动连接路径的会话守护：连接成功注册 dataTransfer 连续任务（防杀），
    // 断开/失败释放。幂等，状态重复同步不会重复注册/释放。
    // 2026-10-19 保活整改：RECOVERING（内核被系统回收后的自愈/重连窗口）**不释放**。
    // 真机取证：原实现一旦进入非 CONNECTED 就 release，导致 VPN 进程被
    // LowMemoryKill 回收后守护立即撤销，后台彻底失去驻留凭证、再也拉不回来
    // （必须用户手动重进 App）。用户意图仍为连接时必须保持守护。
    if (this.isConnected && !UiGuardian.isRegistered()) {
      UiGuardian.engage(getContext(this) as Context, async (): Promise<boolean> => {
        const authority = await this.orchestrator.authorityState();
        return authority.connected && authority.desiredConnected;
      }).catch((): void => {});
    } else if (!this.isConnected && (UiGuardian.isRegistered() || UiGuardian.isWatching())
      && this.orchestrator.state !== ConnState.CONNECTING
      && this.orchestrator.state !== ConnState.DISCONNECTING
      && this.orchestrator.state !== ConnState.RECOVERING) {
      UiGuardian.release(getContext(this) as Context).catch((): void => {});
    }
    this.isConnecting = this.orchestrator.state === ConnState.CONNECTING
      || this.orchestrator.state === ConnState.DISCONNECTING
      || this.orchestrator.state === ConnState.RECOVERING;
    // miniBar（P1-3a）宿主信号：AppStorage 键供 MainPage 的 @StorageLink 消费
    AppStorage.setOrCreate('mini_conn_connected', this.isConnected);
    AppStorage.setOrCreate('mini_conn_connecting', this.isConnecting);
    AppStorage.setOrCreate('mini_conn_node', this.orchestrator.currentNodeName());
    this.errorMessage = this.orchestrator.lastError;
    this.refreshDisplayNode();
  }

  /** 订阅区块切换节点后刷新按钮内节点名（无需等连接） */
  onNodeSwitched(): void {
    if (this.nodeSwitchRevision <= 0) {
      return;
    }
    this.refreshDisplayNode();
  }

  private async toggleTheme(): Promise<void> {
    await ThemeService.toggle();
    const mainWindow = AppStorage.get<window.Window>('main_window');
    if (mainWindow !== undefined) {
      await ThemeService.syncSystemBars(mainWindow);
    }
  }

  private bootstrap(): Promise<void> {
    if (this.bootstrapTask !== null) { return this.bootstrapTask; }
    const task: Promise<void> = this.bootstrapImpl();
    this.bootstrapTask = task;
    task.finally((): void => {
      if (this.bootstrapTask === task) { this.bootstrapTask = null; }
    }).catch((): void => {});
    return task;
  }

  private async bootstrapImpl(): Promise<void> {
    const ctx = getContext(this) as Context;
    this.orchestrator.init(ctx);
    if (!this.listenerBound) {
      this.listenerBound = true;
      this.orchestrator.addListener(this.connectionListener);
    }
    await SettingsService.init(ctx);
    // 数据页流量记账：App 级每秒 tick（不依赖「数据」页是否被打开）
    await TrafficStatsStore.init(ctx);
    TrafficStatsStore.startAccounting();
    await this.subs.init(ctx);
    this.settings = await SettingsService.load();
    // 冷启动兜底：把当前订阅上次手动选的节点还原成生效偏好。
    // 否则「切到别家订阅再切回来」时全局偏好仍指向别家节点，首页/连接会掉到
    // 该订阅第一个节点（用户感知为随机选点）。
    await this.subs.restoreRememberedNodeForCurrentProfile();
    this.settings = await SettingsService.load();
    // 冷启动节点就绪看门狗：未就绪时启动按钮显示「节点加载中…」，
    // 避免用户秒点启动时拿空/旧节点表去生成配置（报「节点选择未生效」）。
    this.startNodeReadinessWatch();
    this.applyOrchestratorState();
    this.pageReady = true;
    // ── 测速结论恢复：**新真源**（LatencyStore，字段级落盘）────────────
    //
    // 旧形态是「进程内 Map」+「落盘 nodeSortSnapshot」两份源，冷启动时旧快照能把
    // 进程内更新的结论盖掉（用户：刚测出来是好的，重启后又变超时）。
    // 现在落盘结论只认 LatencyStore，恢复遵守「无记录或更新才覆盖」。
    //
    // 旧快照降级为**一次性迁移源**：老装机升级后第一次启动时把里面的结论搬进
    // 新仓（字段级），此后一律走新仓。
    await LatencyStoreBridge.ensureStore(ctx);
    const restored: string[] = await LatencyStoreBridge.restoreFromStore();
    if (restored.length === 0) {
      const latencySnapshot = NodeSortSnapshot.fromJsonText(this.settings.nodeSortSnapshot);
      if (latencySnapshot !== null) {
        const legacyNames: string[] = [];
        for (const rec of latencySnapshot.records) {
          if (rec.latency !== -2) {
            // 恢复**上一轮**的结论：必须带失败分类与真实时间戳。
            // 2026-10-20 真机反馈「刚打开软件还没测速就显示超时，测完发现节点是好的」
            // ——旧写法 `LatencyStoreBridge.set(rec.name, rec.latency)` 丢掉分类、
            // 并用 Date.now() 盖时间戳，把旧失败伪装成本次刚测出来的红「超时」。
            LatencyStoreBridge.restore(rec.name, rec.latency, rec.failKind, latencySnapshot.testedAt);
            legacyNames.push(rec.name);
          }
        }
        // 一次性迁移进新仓：迁移后旧快照不再是真源
        await LatencyStoreBridge.persistConclusions(legacyNames);
      }
    }
    LatencyStoreBridge.flushNow();
    const pm: string = this.settings.proxyMode;
    this.proxyMode = (pm === 'global' || pm === 'direct') ? pm : 'rule';
    // 会话接管由编排器统一校验代次；页面不得用异步读到的旧快照改写连接态。
    await this.orchestrator.restoreKilledSession(ctx);
    if (!this.pageMounted) { return; }
    if (this.publicIp.length === 0) {
      setTimeout((): void => {
        // 启动期这次查询发生在**隧道未建立**时：出口是本机宽带，弱网下容易超时。
        // 代次机制保证它晚到的失败结果不会覆盖连接后的正确结果。
        this.refreshPublicIp('home-bootstrap').catch((): void => {});
      }, 0);
    }
    // ── 冷启 DoH 预热：2026-10-19 **已移除**（稳定性回退）────────────────────
    //
    // 0.4.0 在这里加过一段 fire-and-forget 的 `DoHResolver.resolveMany(全部节点域名,
    // 6000, priority)`：16 个 worker 并发发 HTTPS 到 doh.pub / alidns，预算 6s。
    // 目的是把首连的 DoH 等待挪到「开应用的空闲时间」。实测/复盘后确认它有害：
    //   ① 它与上面那次**公网 IP 查询**必然重叠（预热预算 6s > ip-api 连接超时 5s），
    //      在移动数据/弱网/多订阅（实测 111 节点 → 58 个唯一域名）下把 ip-api 的
    //      连接握手挤到超时；ip-api 失败无重试，随后就被下一次成功结果之外的
    //      失败结果覆盖成「获取失败」。
    //   ② 预热产物大部分被「短 TTL 不 pin」策略丢弃（见 DoHResolver 文件头），
    //      实际收益远小于设计预期。
    //   ③ 每次回到首页（未连接时）都会重跑，弱网下形成持续后台流量。
    // 稳定性优先：预热整体删除，首连的 DoH 等待回到连接路径内（预算已恢复 6000ms，
    // 与 0.3.3 一致）。若将来要恢复预热，必须满足：延后到首屏之后 ≥3s、worker ≤4、
    // 只预热当前订阅、且与公网 IP 查询串行。
    if (!this.pageMounted) { return; }
    this.applyOrchestratorState();
    this.pageReady = true;
    this.consumeVpnRequest();
  }

  onPublicIpRevision(): void {
    if (!this.pageReady || this.publicIpRefreshing) {
      return;
    }
    this.publicIp = '';
    this.refreshPublicIp('node-switched', true).catch((): void => {});
  }

  onVpnRequest(): void {
    this.consumeVpnRequest();
  }

  private consumeVpnRequest(): void {
    if (!this.pageReady) {
      return;
    }
    const mode = AppStorage.get<string>('vpn_request_mode') ?? '';
    if (mode.length === 0) {
      return;
    }
    AppStorage.setOrCreate('vpn_request_mode', '');
    // 外部请求（卡片/快捷方式）= 显式用户操作：清除"用户主动停止后台任务"的抑制态
    UiGuardian.clearExternalCancelSuppression();
    if (mode === 'start') {
      this.startConnectionIfNeeded();
    } else if (mode === 'toggle') {
      this.toggleConnection();
    }
  }

  /** 连接入口的订阅就绪等待（冷启动 ~1.4s 内点连接时进程级 hydrate 可能未完成，
   *  提前解析节点会误报「暂无可用节点」；init 进程内记忆化，已加载立即返回） */
  private async awaitSubsReady(): Promise<void> {
    try {
      await this.subs.init(getContext(this) as Context);
    } catch (e) {
      AppLogger.warn(TAG, `subs hydration wait failed: ${AppLogger.errText(e)}`);
    }
  }

  /** 是否已经有可连接的节点集合（真实节点表或可用 profile 兜底） */
  private hasUsableNodes(): boolean {
    return this.subs.nodes.length > 0 || this.subs.hasUsableProfile();
  }

  /**
   * 冷启动节点就绪看门狗：最多等 20s，期间按钮显示「节点加载中…」。
   *
   * 订阅 auto-refresh 是后台并行的，没有回调能直接告诉首页「节点表已填充」；
   * 用 400ms 轮询比「等固定 2s」稳：就绪即放行，慢网也不会过早报空。
   * 就绪时若用户已经在加载中点了启动（pendingConnectAfterNodes），自动补连一次。
   */
  private startNodeReadinessWatch(): void {
    this.stopNodeReadinessWatch();
    // 已连接：无论节点表是否为空都不该把按钮打回「节点加载中」。
    if (this.isConnected || this.orchestrator.state === ConnState.CONNECTED) {
      this.nodesLoading = false;
      return;
    }
    if (this.hasUsableNodes()) {
      this.nodesLoading = false;
      return;
    }
    this.nodesLoading = true;
    const deadline: number = Date.now() + 20000;
    // 事件优先：节点集一变就放行（不再等下一次 tick）。
    SubscriptionService.onNodeSetChanged(this.nodeSetListener);
    this.nodeWatchTimer = UnifiedScheduler.every((): void => {
      if (this.hasUsableNodes()) {
        this.onNodesBecameReady();
        return;
      }
      if (Date.now() >= deadline) {
        this.nodesLoading = false;
        this.stopNodeReadinessWatch();
        if (this.pendingConnectAfterNodes) {
          this.pendingConnectAfterNodes = false;
          promptAction.showToast({ message: '节点加载超时，请到主页「订阅」里刷新后再连接' });
        }
      }
    }, 400);
  }

  /** 节点就绪：停看门狗 + 若用户在加载中点了启动则补连一次。 */
  private onNodesBecameReady(): void {
    this.nodesLoading = false;
    this.stopNodeReadinessWatch();
    if (this.pendingConnectAfterNodes) {
      this.pendingConnectAfterNodes = false;
      // 让「节点加载中…」先落一帧，再进入正在连接，避免按钮文案跳变
      setTimeout((): void => {
        this.toggleConnection();
      }, 0);
    }
  }

  private stopNodeReadinessWatch(): void {
    if (this.nodeWatchTimer >= 0) {
      UnifiedScheduler.clear(this.nodeWatchTimer);
      this.nodeWatchTimer = -1;
    }
  }

  private async startConnectionIfNeeded(): Promise<void> {
    // 显式用户操作（快捷方式 start）：清除长时任务抑制态
    UiGuardian.clearExternalCancelSuppression();
    if (this.isConnecting || this.isConnected || this.pendingStart) {
      return;
    }
    // 冷启动快捷启动：节点未就绪时排队，就绪后由看门狗补连（不报节点未生效）。
    if (this.nodesLoading) {
      this.pendingConnectAfterNodes = true;
      this.startNodeReadinessWatch();
      return;
    }
    // 乐观反馈同 toggleConnection：快捷方式路径同样不出现无响应空窗
    this.pendingStart = true;
    try {
      await this.awaitSubsReady();
      if (this.isConnecting || this.isConnected) {
        return;
      }
      const node = await this.selectedNode();
      if (node === null) {
        promptAction.showToast({ message: '暂无可用节点，请先在主页「订阅」里添加并刷新' });
        return;
      }
      const ok = await this.orchestrator.connect(node, this.subs);
      if (ok) {
        // 与 toggleConnection 同款：先作废启动期直连查询，再查隧道出口（并清掉旧值）。
        this.invalidatePublicIpQueries();
        this.refreshPublicIp('after-connect-shortcut', true);
      }
    } finally {
      this.pendingStart = false;
    }
  }

  private async selectedNode(): Promise<ProxyNode | null> {
    // 作用域化 + 重锚：切订阅后的旧偏好不再当连接目标；刷新导致 id 漂移时按名自愈
    const preferred = await this.subs.resolvePreferenceHint();
    return preferred !== null ? preferred : this.subs.fallbackConnectionNode();
  }

  private refreshDisplayNode(): void {
    // 与订阅页顶部概览卡共用同一条取值路径（orchestrator.displayNodeName），
    // 两处显示必然一致。旧实现在这里各算一套，订阅页那份按连接状态分叉 →
    // 未连接时显示「未选择」，与主页按钮不一致（2026-10-25 用户实锤）。
    // 统一读取口（2026-10-27）：不再传偏好参数，真源在内核侧。
    this.currentNodeName = this.orchestrator.getCurrentNodeName();
  }


  private refreshDiagnostics(): void {
    this.orchestrator.diagnostics().then((d: AppDiagnostics) => {
      this.diagData = d;
    }).catch(() => {
      this.diagData = null;
    });
  }

  /**
   * 查询并刷新首页公网 IP。
   *
   * ## 2026-10-19 稳定性加固（0.4.0「取不到公网 IP」的直接修复）
   *
   * 旧实现的三个缺陷，任何一个都会让 UI 停在「获取失败」且不自愈：
   *   ① **没有请求代次**：两个并发调用各自 `await` 后无条件写 `publicIp`/
   *      `publicIpError`。启动期那次「直连」查询（此时还没隧道，弱网下最长 5s+8s）
   *      晚于连接后那次「走隧道」的成功查询返回时，会把已经显示的正确 IP
   *      **清空成红字**。0.3.3 因为连接慢、两次查询不重叠所以没暴露；0.4.0 把连接
   *      提速 0.3–1.5s 后必然重叠 → 这就是"部分用户、0.4 才有"的根因。
   *   ② **失败就清空**：`this.publicIp = ''` 让一次瞬时失败抹掉上一次的可用结果。
   *   ③ **`publicIpRefreshing` 可能永久为 true**：`PublicIpService.query()` 若在
   *      建连阶段同步抛异常（旧实现 `http.createHttp()` 在 try 之外），标志位再也
   *      复位不了，IP 区一直转圈。
   *
   * 现在的语义：
   *   · 每次调用取一个**递增代次**；只有「自己仍是最新一次调用」时才允许写 UI，
   *     过期结果直接丢弃（不覆盖新结果、不重置刷新标志）；
   *   · 失败时**保留上一次成功的 IP**（只在从未成功过时才显示错误文案），
   *     并在错误文案里区分「还没连上/查询失败」，避免误导；
   *   · `try/finally` 保证刷新标志一定复位；
   *   · 所有触发点都带 trigger 名字，日志可定位是谁发起的。
   *
   * @param trigger 触发来源，仅用于日志
   * @param clearBefore true 时先清空旧值（用户主动换节点/断开后重查的场景）
   */
  private async refreshPublicIp(trigger: string = 'manual', clearBefore: boolean = false): Promise<void> {
    const seq = ++this.ipQuerySeq;
    if (clearBefore) {
      this.publicIp = '';
    }
    this.publicIpRefreshing = true;
    this.publicIpError = '';
    try {
      const info: PublicIpInfo = await PublicIpService.query(trigger);
      if (seq !== this.ipQuerySeq) {
        // 已有更新的一次查询在跑：本结果作废，绝不覆盖（这就是旧版的核心 bug）
        return;
      }
      if (info.ip.length > 0) {
        this.publicIp = info.ip;
        this.publicIpError = '';
      } else {
        // 保留上一次成功的值；只有从来没有成功过才显示失败文案。
        if (this.publicIp.length === 0) {
          // 已连接却连「主端点 + 备用端点」都拿不到 IP —— 这不是显示问题，
          // 而是**隧道可能没有可用出口**（节点失效 / 选点没生效 / DNS 被污染）。
          // 文案要指向可行动的操作（换节点/重试），而不是让用户以为只是"没显示出来"。
          // 注意：ip-api 被限流时也可能走到这里，所以措辞用「可能」而非断言。
          this.publicIpError = this.isConnected
            ? '未取到出口 IP，点击重试或更换节点'
            : '未连接，点击重试';
        }
      }
    } catch (e) {
      if (seq === this.ipQuerySeq) {
        AppLogger.warn('HomePage', `refreshPublicIp(${trigger}) threw: ${AppLogger.errText(e)}`);
        if (this.publicIp.length === 0) {
          this.publicIpError = this.isConnected
            ? '未取到出口 IP，点击重试或更换节点'
            : '未连接，点击重试';
        }
      }
    } finally {
      if (seq === this.ipQuerySeq) {
        this.publicIpRefreshing = false;
      }
    }
  }

  /**
   * 作废所有在飞的 IP 查询（连接状态切换时调用）。
   *
   * 为什么需要：连接成功后，启动期那次「直连出口」的查询结果已经**没有意义**
   * （它测的是本机宽带出口，不是代理出口）。只靠代次丢弃也能避免覆盖，但让它在
   * 隧道建好后继续占用连接/带宽、还可能撞上 ip-api 的按出口限流，得不偿失。
   * 递增代次后，那次调用的结果会被 `refreshPublicIp` 直接丢弃。
   */
  private invalidatePublicIpQueries(): void {
    this.ipQuerySeq = this.ipQuerySeq + 1;
    this.publicIpRefreshing = false;
  }

  private async toggleConnection(): Promise<void> {
    // 显式用户操作（电源按钮/卡片 toggle）：清除长时任务抑制态
    UiGuardian.clearExternalCancelSuppression();
    if (this.isConnecting || this.pendingStart) {
      return;
    }
    // 冷启动节点还没就绪：不让用户白点一次再吃「节点选择未生效」。
    // 记下意图，节点就绪后自动补连；再点一次可取消。
    if (!this.isConnected && this.nodesLoading) {
      this.startNodeReadinessWatch();
      if (this.pendingConnectAfterNodes) {
        this.pendingConnectAfterNodes = false;
        promptAction.showToast({ message: '已取消本次自动连接' });
      } else {
        this.pendingConnectAfterNodes = true;
        promptAction.showToast({ message: '节点加载中，就绪后自动连接…' });
      }
      return;
    }
    const context = getContext(this) as Context;
    // 乐观反馈：任何 await 之前先点亮「正在连接」—— 冷启订阅 hydrate 等待
    // （最多 ~1.5s）绝不能变成按钮无响应的空窗
    this.pendingStart = true;
    try {
      await this.awaitSubsReady();
      const node = await this.selectedNode();
      const nodeName = node === null ? '' : node.name;
      if (this.isConnected) {
        await FormStateSync.publish(context, FormStateSync.disconnecting(nodeName));
        await this.orchestrator.disconnect();
        await FormStateSync.publish(context,
          node === null ? FormStateSync.noNode() : FormStateSync.disconnected(nodeName));
        this.refreshPublicIp('after-disconnect', true);
        return;
      }
      if (node === null) {
        await FormStateSync.publish(context, FormStateSync.noNode());
        promptAction.showToast({ message: '暂无可用节点，请先在主页「订阅」里添加并刷新' });
        return;
      }
      await FormStateSync.publish(context, FormStateSync.connecting(node.name));
      const ok = await this.orchestrator.connect(node, this.subs);
      await FormStateSync.publish(context,
        ok ? FormStateSync.connected(node.name) : FormStateSync.failed(node.name));
      if (ok) {
        // 连接成功：先作废启动期那次「直连出口」的查询（结果已无意义，且可能仍在飞），
        // 再发一次走隧道的查询。代次保证：即使旧查询晚到，也绝不会覆盖这次的结果。
        // clearBefore=true：出口已经变了，旧值（本机宽带 IP）必须立刻丢弃 ——
        // 万一这次也失败，宁可显示「未取到出口 IP」也不能显示一个错的出口。
        this.invalidatePublicIpQueries();
        this.refreshPublicIp('after-connect', true);
      }
    } finally {
      this.pendingStart = false;
    }
  }

  private async applyProxyMode(mode: string): Promise<void> {
    if (mode === this.proxyMode) {
      return;
    }
    this.proxyMode = mode;
    this.settings.proxyMode = mode;
    // ── `direct` 不落盘（2026-10-19 稳定性裁定）──────────────────────────────
    //
    // 「直连」= 所有流量绕过代理。它是排查/临时需求，不是长期配置：
    // 一旦写进磁盘，用户误触后每次启动都直连，表现是「VPN 连上了但代理不生效、
    // 公网 IP 是本地出口」，而用户几乎不可能自己想到是模式问题。
    // 所以 direct 只在本次运行期生效（内存 + 内核热更新），磁盘上保持上一次的
    // rule/global；重启后由 AppSettings.fromJson 再兜一层（direct → rule）。
    // 需要直连时再点一次按钮，代价是一次点击，收益是不可能被粘死。
    if (mode !== 'direct') {
      // 字段级写入口（审计 F2）：整单 save 会把别的写者刚写进去的字段盖回旧值。
      // 这里只改 proxyMode 一个字段，其余字段从盘上最新值原样带走。
      await SettingsService.patchSettings((s: AppSettings): void => {
        s.proxyMode = mode;
      });
    }
    // 内存里保留 `settings.proxyMode = 'direct'`（上面已赋值），但要注意一个
    // **有意的行为**：自动重连（网络切换/故障切换）走的是
    // `ConnectionOrchestrator.connect()` 里 `SettingsService.load()` 的磁盘值，
    // 那里没有 direct → 重连后自动回到 rule。这符合"direct 是临时诊断态"的定位：
    // 用户不会因为一次误触而永久直连，代价只是重连后需要重新点一次。
    const label = mode === 'global' ? '全局模式' : (mode === 'direct' ? '直连模式（不保存）' : '规则模式');
    await this.orchestrator.applyProxyMode(mode);
    promptAction.showToast({
      message: this.orchestrator.state === ConnState.CONNECTED
        ? `已切换${label}` : `已切换${label}，下次连接生效`
    });
    // 模式切换会改变出口（尤其 direct），旧 IP 结论作废，立即重查
    if (this.orchestrator.state === ConnState.CONNECTED) {
      this.invalidatePublicIpQueries();
      this.refreshPublicIp('after-mode-change', true);
    }
  }

  /** 代理模式三段按钮（2026-10-26 用户定稿：透明按钮 + 小椭圆高亮）：
   *  整条三段按钮没有底；只有选中项带一个小胶囊（宽度=文字+左右 20vp，高 34vp），
   *  胶囊用 modeChipFill/modeChipBorder（比 primaryLight 蓝一档，用户要求「再加重一点点」）。
   *  胶囊不再铺满 1/3 栏宽（用户「椭圆范围小一点，不用这么长」），点击热区仍是整个 1/3 槽位。 */
  @Builder
  ProxyModeButton(mode: string, label: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontWeight(this.proxyMode === mode ? FontWeight.Bold : FontWeight.Medium)
        .fontColor(this.proxyMode === mode ? TunBoxColors.primary : TunBoxColors.textSecondary)
        .textAlign(TextAlign.Center)
        .height(34)
        .padding({ left: 20, right: 20 })
        .borderRadius(TunBoxGeometry.pillRadius)
        .backgroundColor(this.proxyMode === mode ? TunBoxColors.modeChipFill : Color.Transparent)
        .border({
          width: 1,
          color: this.proxyMode === mode ? TunBoxColors.modeChipBorder : Color.Transparent
        })
    }
    .layoutWeight(1)
    .height(40)
    .justifyContent(FlexAlign.Center)
    .onClick(() => this.applyProxyMode(mode))
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 底层背景列（文档骨架：纯色画布，不再用渐变/玻璃底）；
      // expandSafeArea 仅作用于背景，内容仍布局在安全区内（顶栏不被状态栏遮挡）。
      Column().width('100%').height('100%')
        .linearGradient({ angle: 180, colors: [[TunBoxColors.bgGradientStart, 0.0], [TunBoxColors.bgGradientEnd, 1.0]] })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        // ── 1. 顶部导航（文档 §2.1，无返回）：rightSlot 只保留主题切换（备份已迁到设置页） ──
        TopNavBar({ title: 'TunBox' }) {
          Row({ space: 8 }) {
            Button() {
              SymbolGlyph($r('sys.symbol.sun_max'))
                .fontSize(20)
                .fontColor([TunBoxColors.textMuted])
            }
            .width(40)
            .height(40)
            .borderRadius(20)
            .backgroundColor(Color.Transparent)
            .accessibilityText('切换浅色或深色主题')
            .onClick(() => this.toggleTheme())
          }
          .alignItems(VerticalAlign.Center)
        }

        Scroll() {
          Column({ space: 16 }) {
            // ── 2. 天体轨域启动按钮（2026-10-17 用户按 stitch 设计稿「方案一」重构；
            //       节点名放回按钮内部，副标题/状态胶囊按用户要求删除）──
            // 2026-10-19 用户要求「启动按钮缩小一点，下面整体往上挪一行」：
            // 按钮本体已在 TunBoxTokens 等比缩到 87.5%（省 40vp），
            // 这里再把上下内边距 8/4 收成 0 —— 合计上移约 52vp（≈ 一行内容）。
            // 首页下方（公网 IP / 模式按钮 / 订阅区块）因此整体上提。
            Column() {
              CelestialPowerOrb({
                isConnected: $isConnected,
                // 节点加载中不算「正在连接」：标题保持「开启连接」，副标题显示加载中，
                // 节点就绪并自动补连后才切到「正在连接」。
                isConnecting: this.isConnecting || (this.pendingStart && !this.nodesLoading),
                nodeName: this.nodesLoading ? '节点加载中…' : this.currentNodeName,
                // 出口 IP 现在画在按钮内部沿底部弧线（2026-10-28 用户要求）；未连接不显示
                ipText: this.isConnected ? this.publicIp : '',
                onToggle: (): void => {
                  this.toggleConnection();
                }
              })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 0, bottom: 0 })

            // ── 代理模式三段按钮：规则/全局/直连（2026-10-17 自分流模式卡片迁出，置于启动按钮下方）──
            Row({ space: 10 }) {
              this.ProxyModeButton('rule', '规则')
              this.ProxyModeButton('global', '全局')
              this.ProxyModeButton('direct', '直连')
            }
            .width('100%')

            // ── 订阅区块（2026-10-28：订阅从独立页签迁到主页，对齐 ClashPlus「内联 profiles」）──
            // 点订阅卡 → 全屏覆盖展开节点列表（bindContentCover），选完节点自动返回。
            SubscriptionSection()
              .width('100%')

            // ── 错误条（既有功能，令牌化）：点击打开诊断面板 ──
            if (this.errorMessage.length > 0) {
              Row({ space: 6 }) {
                Image($r('app.media.ic_warning'))
                  .width(16).height(16)
                  .fillColor(TunBoxColors.danger)
                Text(this.errorMessage)
                  .fontSize(12)
                  .fontColor(TunBoxColors.danger)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
              .padding(12)
              .borderRadius(TunBoxGeometry.cardRadius)
              .backgroundColor(TunBoxColors.dangerLight)
              .onClick(() => {
                this.showDiagnostics = true;
                this.refreshDiagnostics();
              })
            }

          }
          .width('100%')
          // 页签页底部为悬浮 Dock 留白（TunBoxGeometry.dockClearance = 96，契约硬性规则）
          .padding({
            left: TunBoxGeometry.pagePadding,
            right: TunBoxGeometry.pagePadding,
            bottom: TunBoxGeometry.dockClearance
          })
        }.edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')

      // 诊断面板（既有实现不动，仅蒙层色改令牌）
      if (this.showDiagnostics) {
        Column() {
          Blank()
          DiagnosticsSheet({
            diag: this.diagData,
            onRefresh: () => {
              this.refreshDiagnostics();
            },
            onClose: () => { this.showDiagnostics = false; }
          })
            .height('78%')
        }
        .width('100%')
        .height('100%')
        .backgroundColor(TunBoxColors.scrim)
        .onClick(() => { this.showDiagnostics = false; })
      }
    }
    .width('100%')
    .height('100%')
  }
}
