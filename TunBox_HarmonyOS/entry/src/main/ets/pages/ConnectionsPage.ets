/**
 * 实时连接面板（对齐 Clash Verge / NekoBox 的连接查看器）
 *
 * 数据源：内核 GET /connections（ClashApiService.listConnections），2s 轮询；
 * 未连接/内核不可达时给出明确提示，不假装列表为空。
 * 操作：单条点击关闭（带确认）、一键关闭全部；展示流量/规则链/出口节点/持续时间。
 */
import { router, promptAction } from '@kit.ArkUI';
import { UnifiedScheduler } from '../commons/services/UnifiedScheduler';
import { TunBoxColors, TunBoxMotion } from '../theme/TunBoxTokens';
import { Ui } from '../theme/UiTokens';
import { TopNavBar } from '../components/TopNavBar';
import { AppLogger } from '../commons/utils/AppLogger';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';
import { SubscriptionService } from '../commons/services/SubscriptionService';
import { ConnectionEntry } from '../commons/services/ClashApiService';

const TAG = 'ConnectionsPage';
/** 轮询周期与主页流量采样一致（TRAFFIC_POLL_INTERVAL_MS 语义） */
const POLL_INTERVAL_MS = 2000;

@Entry
@Component
struct ConnectionsPage {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @State entries: ConnectionEntry[] = [];
  @State reachable: boolean = true;
  @State refreshing: boolean = false;
  /** 已知节点名（用于把 chains 还原成真实出口节点名；空数组 = 不做交集过滤） */
  private knownNames: string[] = [];
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private subs: SubscriptionService = SubscriptionService.instance();
  private pollTimer: number = -1;
  private bootstrapTimer: number = -1;
  private pageVisible: boolean = false;
  private pageGeneration: number = 0;

  onPageShow(): void {
    this.stopPoll();
    this.pageVisible = true;
    const generation = this.pageGeneration;
    // 入场转场期间不抢 UI 线程：首帧建表延到转场之后（2026-10-17 用户反馈进入页面卡顿）
    this.bootstrapTimer = setTimeout((): void => {
      this.bootstrapTimer = -1;
      this.bootstrap(generation).catch((e: Object): void => {
        AppLogger.warn(TAG, `bootstrap failed: ${AppLogger.errText(e)}`);
      });
    }, 240);
  }

  onPageHide(): void {
    this.stopPoll();
  }

  aboutToDisappear(): void {
    this.stopPoll();
  }

  private async bootstrap(generation: number): Promise<void> {
    if (!this.isCurrentPage(generation)) { return; }
    const ctx = getContext(this) as Context;
    this.orchestrator.init(ctx);
    await this.subs.init(ctx);
    if (!this.isCurrentPage(generation)) { return; }
    this.knownNames = this.subs.nodes.map((n) => n.name);
    await this.refreshOnce(generation);
    if (this.isCurrentPage(generation)) { this.startPoll(); }
  }

  private startPoll(): void {
    if (this.pollTimer >= 0) {
      return;
    }
    this.pollTimer = UnifiedScheduler.every((): void => {
      this.refreshOnce();
    }, POLL_INTERVAL_MS);
  }

  private stopPoll(): void {
    this.pageVisible = false;
    this.pageGeneration++;
    this.refreshing = false;
    if (this.bootstrapTimer >= 0) {
      clearTimeout(this.bootstrapTimer);
      this.bootstrapTimer = -1;
    }
    if (this.pollTimer >= 0) {
      UnifiedScheduler.clear(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  private isCurrentPage(generation: number): boolean {
    return this.pageVisible && generation === this.pageGeneration;
  }

  private async refreshOnce(generation: number = this.pageGeneration): Promise<void> {
    if (!this.isCurrentPage(generation) || this.refreshing) {
      return;
    }
    this.refreshing = true;
    try {
      const list = await this.orchestrator.api.listConnections(this.knownNames);
      if (!this.isCurrentPage(generation)) { return; }
      if (list === null) {
        this.reachable = false;
      } else {
        this.reachable = true;
        // 按下行+上行降序：活跃连接永远在最上面（对齐主流客户端）
        list.sort((a: ConnectionEntry, b: ConnectionEntry): number =>
          (b.download + b.upload) - (a.download + a.upload));
        this.entries = list;
      }
    } catch (e) {
      AppLogger.warn(TAG, `refresh failed: ${AppLogger.errText(e)}`);
    } finally {
      if (this.isCurrentPage(generation)) { this.refreshing = false; }
    }
  }

  private async closeEntry(entry: ConnectionEntry): Promise<void> {
    const ok = await this.orchestrator.api.closeConnection(entry.id);
    promptAction.showToast({
      message: ok ? '已关闭该连接' : '关闭失败，请重试'
    });
    await this.refreshOnce();
  }

  private async closeAll(): Promise<void> {
    const ok = await this.orchestrator.api.closeAllConnections();
    promptAction.showToast({
      message: ok ? '已关闭全部连接' : '操作失败，请重试'
    });
    await this.refreshOnce();
  }

  private formatBytes(total: number): string {
    if (total < 1024) {
      return `${Math.round(total)} B`;
    }
    const kb = total / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(1)} KB`;
    }
    const mb = kb / 1024;
    if (mb < 1024) {
      return `${mb.toFixed(1)} MB`;
    }
    return `${(mb / 1024).toFixed(2)} GB`;
  }

  private formatAge(startMs: number): string {
    if (startMs <= 0) {
      return '';
    }
    const sec = Math.max(0, Math.floor((Date.now() - startMs) / 1000));
    if (sec < 60) {
      return `${sec}s`;
    }
    const mm = Math.floor(sec / 60);
    if (mm < 60) {
      return `${mm}m${sec % 60}s`;
    }
    return `${Math.floor(mm / 60)}h${mm % 60}m`;
  }

  /** 连接行主标题：host（或 IP）:port，超长省略 */
  private titleOf(entry: ConnectionEntry): string {
    const host = entry.host.length > 0 ? entry.host : '(未知目标)';
    return entry.port > 0 ? `${host}:${entry.port}` : host;
  }

  /** 出口链摘要：chain 最多取末两级，避免超长 */
  private chainOf(entry: ConnectionEntry): string {
    if (entry.outbound.length > 0) {
      return entry.outbound;
    }
    if (entry.chains.length === 0) {
      return '';
    }
    return entry.chains.slice(-2).join(' → ');
  }

  build() {
    Stack() {
      Column().width('100%').height('100%')
        .backgroundColor(TunBoxColors.background(this.themeRevision))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      Column() {
        // ── 顶栏（文档 §2.1 TopNavBar，右侧保留既有「关闭全部 / 刷新」入口）──
        TopNavBar({ title: '实时连接', hasBack: true }) {
          Row({ space: 10 }) {
            Text('关闭全部')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.entries.length > 0 ? Ui.error : Ui.textTertiary)
              .onClick(() => {
                if (this.entries.length > 0) {
                  this.closeAll();
                }
              })
            Text(this.refreshing ? '刷新中' : '刷新')
              .fontSize(13).fontWeight(FontWeight.Medium).fontColor(Ui.primary)
              .onClick(() => this.refreshOnce())
          }
        }

        Text(`活动连接 ${this.entries.length} 条`)
          .fontSize(12).fontColor(Ui.textTertiary).width('100%').padding({ left: 18, right: 18 })

        if (!this.reachable) {
          Column({ space: 8 }) {
            Text('内核连接接口不可达').fontSize(15).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
            Text('未连接 VPN 或内核 controller 未就绪。连接成功后回到本页即可查看实时连接。')
              .fontSize(12).fontColor(Ui.textSecondary)
          }
          .width('100%').padding(18).margin({ left: 18, right: 18, top: 14 })
          .borderRadius(22).backgroundColor(Ui.surface(this.themeRevision))
          .borderWidth(1).borderColor(Ui.glassEdge(this.themeRevision))
          .alignItems(HorizontalAlign.Start)
          Blank().layoutWeight(1)
        } else if (this.entries.length === 0) {
          Column({ space: 6 }) {
            Text('当前没有活动连接').fontSize(14).fontColor(Ui.textSecondary)
            Text('产生流量后此处会实时列出每条连接的目标、规则链与出口节点')
              .fontSize(11).fontColor(Ui.textTertiary)
          }
          .width('100%').padding(24).margin({ left: 18, right: 18, top: 14 })
          .borderRadius(22).backgroundColor(Ui.surface(this.themeRevision))
          .borderWidth(1).borderColor(Ui.glassEdge(this.themeRevision))
          Blank().layoutWeight(1)
        } else {
          List({ space: 8 }) {
            ForEach(this.entries, (entry: ConnectionEntry) => {
              ListItem() {
                Column({ space: 4 }) {
                  Row({ space: 8 }) {
                    Text(entry.network.toUpperCase())
                      .fontSize(10).fontWeight(FontWeight.Bold)
                      .fontColor(entry.network === 'udp' ? Ui.warning : Ui.textBlue)
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .borderRadius(6)
                      .backgroundColor(Ui.surfaceMuted(this.themeRevision))
                    Text(this.titleOf(entry))
                      .fontSize(13).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
                      .layoutWeight(1).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.formatBytes(entry.upload + entry.download))
                      .fontSize(11).fontColor(Ui.textSecondary).fontFamily('monospace')
                  }.width('100%')
                  if (this.chainOf(entry).length > 0) {
                    Text(this.chainOf(entry))
                      .fontSize(11).fontColor(Ui.textSecondary).width('100%').maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  Row({ space: 8 }) {
                    Text(entry.rule.length > 0 ? entry.rule : '无规则')
                      .fontSize(10).fontColor(Ui.textTertiary).layoutWeight(1).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`↑${this.formatBytes(entry.upload)} ↓${this.formatBytes(entry.download)}`)
                      .fontSize(10).fontColor(Ui.textTertiary).fontFamily('monospace')
                    if (this.formatAge(entry.startMs).length > 0) {
                      Text(this.formatAge(entry.startMs))
                        .fontSize(10).fontColor(Ui.textTertiary).fontFamily('monospace')
                    }
                    Text('断开')
                      .fontSize(11).fontWeight(FontWeight.Bold).fontColor(Ui.error)
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .borderRadius(10).backgroundColor(Ui.statusTint)
                      .onClick(() => this.closeEntry(entry))
                  }.width('100%')
                }
                .width('100%')
                .padding(14)
                .borderRadius(16)
                .backgroundColor(Ui.surface(this.themeRevision))
                .borderWidth(1)
                .borderColor(Ui.glassEdge(this.themeRevision))
              }
            }, (entry: ConnectionEntry) => entry.id)
          }.edgeEffect(EdgeEffect.Spring)
          .width('100%').layoutWeight(1)
          .padding({ left: 18, right: 18, top: 10, bottom: 20 })
          .scrollBar(BarState.Auto)
        }
      }.width('100%').height('100%')
    }.width('100%').height('100%')
  }

  /** 路由推入式子页统一转场：水平滑动 + 淡入淡出（与页签切换同规格，见 TunBoxMotion） */
  pageTransition() {
    PageTransitionEnter({ duration: TunBoxMotion.ms, curve: TunBoxMotion.curve })
      .translate({ x: TunBoxMotion.slidePercent, y: 0 }).opacity(0)
    PageTransitionExit({ duration: TunBoxMotion.ms, curve: TunBoxMotion.curve })
      .translate({ x: `-${TunBoxMotion.slidePercent}`, y: 0 }).opacity(0)
  }
}
