/**
 * 数据页（页签「数据」）—— 内容对齐 ClashPlus 1.2.7 `views/stats/stats.dart`
 *
 * ## 卡片
 * 1. 速率卡：实时速率双曲线（下载/上传）+ 峰值/平均 + 本次连接/累计总量/今日
 * 2. 内存占用 / 运行时间：**两张独立卡片**（2026-10-28 用户要求）+ 图标
 * 3. 出口 IP 卡：国旗 + 国家/城市 + ISP + ASN + 时区
 * 4. 连通性卡：默认 google.com / github.com，可增删；TCP443 直连或 HTTP(S) 经本机代理
 *
 * ## 注意（真机踩坑）
 * 动态数值一律在 build 里**直接读 this.<state>**，不要经 @Builder 的值参数传递：
 * ArkUI 的 @Builder 值参数不是响应式的，传进去的 string/number 变化不会重渲染 ——
 * 之前「内存占用 / 运行时间不显示（实际是永不刷新）」就是这个原因。
 */
import { promptAction } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { TunBoxColors, TunBoxGeometry } from '../theme/TunBoxTokens';
import { TopNavBar } from '../components/TopNavBar';
import { TabLifecycleBridge } from '../commons/utils/TabLifecycleBridge';
import { UnifiedScheduler } from '../commons/services/UnifiedScheduler';
import { ConnectionOrchestrator, ConnState } from '../commons/services/ConnectionOrchestrator';
import { TrafficStatsStore, TrafficStatsView } from '../commons/services/TrafficStatsStore';
import {
  ConnectivityProbe,
  ConnectivityEntry,
  ProbeKind,
  ProbeState,
  ProbeResult
} from '../commons/services/ConnectivityProbe';
import { PublicIpService } from '../commons/services/PublicIpService';
import { PublicIpInfo } from '../commons/models/PublicIpInfo';
import { AppLogger } from '../commons/utils/AppLogger';
import { ConnEvent, ConnEventKind } from '../commons/services/ConnectionEvents';

const TAG = 'StatsPage';
/** 速率曲线采样点数（与主页 RateChart 的 26 点窗口一致） */
const RATE_POINTS: number = 26;
/** 记账 tick 间隔（ms）—— Plus 数值卡轮询周期同为 1000ms */
const TICK_MS: number = 1000;
/** 每多少个 tick 落盘一次（5s） */
const PERSIST_EVERY: number = 5;
/** 内存端点轮询间隔（tick 数） */
const MEMORY_EVERY: number = 2;

function zeroRatePoints(): number[] {
  const out: number[] = [];
  for (let i = 0; i < RATE_POINTS; i++) {
    out.push(0);
  }
  return out;
}

/** 两位国家码 → 国旗 emoji（Plus `_countryCodeToEmoji` 同款） */
function countryCodeToFlag(code: string): string {
  const cc: string = code.trim().toUpperCase();
  if (cc.length !== 2) {
    return '';
  }
  const a: number = cc.charCodeAt(0) - 65;
  const b: number = cc.charCodeAt(1) - 65;
  if (a < 0 || a > 25 || b < 0 || b > 25) {
    return '';
  }
  return String.fromCharCode(0x1F1E6 + a) + String.fromCharCode(0x1F1E6 + b);
}

/**
 * 双线速率曲线（对齐 Plus `_TrafficChartPainter` 的双序列 + 平滑折线）。
 * 纵轴按窗口峰值归一化（下限 1 B/s 防除零），横轴等分。
 */
@Component
struct StatsRateChart {
  @Prop upPoints: number[] = [];
  @Prop downPoints: number[] = [];
  @State private chartW: number = 300;
  @State private chartH: number = 92;

  private toPoints(data: number[]): number[][] {
    const n: number = Math.max(2, data.length);
    const out: number[][] = [];
    for (let i = 0; i < data.length; i++) {
      const v: number = Math.min(1, Math.max(0, data[i]));
      const x: number = i * (this.chartW / (n - 1));
      const y: number = this.chartH - v * (this.chartH - 8) - 4;
      out.push([x, y]);
    }
    return out;
  }

  private areaOf(data: number[]): number[][] {
    const line: number[][] = this.toPoints(data);
    const closed: number[][] = line.slice();
    closed.push([this.chartW, this.chartH]);
    closed.push([0, this.chartH]);
    return closed;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Polygon({ width: this.chartW, height: this.chartH })
        .points(this.areaOf(this.downPoints))
        .fill(TunBoxColors.primaryLight)
        .stroke(Color.Transparent)
        .strokeWidth(0)
      Polyline({ width: this.chartW, height: this.chartH })
        .points(this.toPoints(this.downPoints))
        .stroke(TunBoxColors.primary)
        .strokeWidth(2.2)
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
        .fill(Color.Transparent)
      Polyline({ width: this.chartW, height: this.chartH })
        .points(this.toPoints(this.upPoints))
        .stroke(TunBoxColors.success)
        .strokeWidth(2)
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
        .fill(Color.Transparent)
    }
    .width('100%')
    .height(this.chartH)
    .onAreaChange((_old: Area, cur: Area) => {
      const w: number = Number(cur.width);
      const h: number = Number(cur.height);
      if (!Number.isNaN(w) && w > 0) {
        this.chartW = w;
      }
      if (!Number.isNaN(h) && h > 0) {
        this.chartH = h;
      }
    })
  }
}

@Component
export struct StatsPage {
  @StorageLink('theme_revision') themeRevision: number = 0;
  /** 页签宿主桥（MainPage 传入；切回本页时刷新一次） */
  shownBridge?: TabLifecycleBridge;

  @State private upPoints: number[] = zeroRatePoints();
  @State private downPoints: number[] = zeroRatePoints();
  @State private upSpeed: number = 0;
  @State private downSpeed: number = 0;
  @State private isConnected: boolean = false;

  @State private memoryText: string = '--';
  @State private uptimeText: string = '--:--:--';

  @State private ipText: string = '';
  @State private ipCountry: string = '';
  @State private ipFlag: string = '';
  @State private ipCity: string = '';
  @State private ipIsp: string = '';
  @State private ipAsn: string = '';
  @State private ipTimezone: string = '';
  /** 0=空 1=加载中 2=成功 3=失败 */
  @State private ipState: number = 0;

  @State private entries: ConnectivityEntry[] = [];
  @State private addingHost: boolean = false;
  @State private hostInput: string = '';
  @State private testingAll: boolean = false;

  @State private lifetimeUp: number = 0;
  @State private lifetimeDown: number = 0;
  @State private sessionUp: number = 0;
  @State private sessionDown: number = 0;
  @State private peakUp: number = 0;
  @State private peakDown: number = 0;
  @State private avgUp: number = 0;
  @State private avgDown: number = 0;
  @State private resetDay: number = 1;
  @State private todayUp: number = 0;
  @State private todayDown: number = 0;

  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private tickToken: number = -1;
  private tickCount: number = 0;
  private memoryBusy: boolean = false;
  private ipBusy: boolean = false;
  /** RSS 回落只记一次日志（避免每秒刷屏） */
  private rssReadLogged: boolean = false;
  private ipQueuedTrigger: string = '';
  private ipRequestId: number = 0;
  private pageMounted: boolean = false;
  private connEventToken: number = -1;
  private ready: boolean = false;
  private windowUpPeak: number = 1;
  private windowDownPeak: number = 1;

  aboutToAppear(): void {
    this.pageMounted = true;
    if (this.connEventToken < 0) {
      this.connEventToken = this.orchestrator.subscribeConnEvents((event: ConnEvent): void => {
        if (event.kind !== ConnEventKind.STATE) {
          return;
        }
        const connected: boolean = event.state === ConnState.CONNECTED;
        this.isConnected = connected;
        this.clearIpInfo();
        if (connected) {
          this.queryIp('stats-connected');
          this.refreshMemory();
        } else {
          this.memoryText = '--';
          this.uptimeText = '--:--:--';
          this.queryIp('stats-disconnected');
        }
      });
    }
    if (this.shownBridge !== undefined) {
      this.shownBridge.setShowHandler((): void => { this.onShown(); });
    }
    this.bootstrap();
  }

  aboutToDisappear(): void {
    if (this.connEventToken >= 0) {
      this.orchestrator.unsubscribeConnEvents(this.connEventToken);
      this.connEventToken = -1;
    }
    this.pageMounted = false;
    this.ipRequestId += 1;
    this.ipQueuedTrigger = '';
    if (this.shownBridge !== undefined) {
      this.shownBridge.setShowHandler(null);
    }
    this.stopTick();
    TrafficStatsStore.persist(true).catch((): void => {});
  }

  private onShown(): void {
    this.reloadStats();
    this.updateUptime();
    if (this.orchestrator.state === ConnState.CONNECTED) {
      this.queryIp('stats-shown');
      this.refreshMemory();
    }
  }

  private async bootstrap(): Promise<void> {
    if (this.ready) {
      return;
    }
    this.ready = true;
    try {
      const ctx: Context = getContext(this) as Context;
      await TrafficStatsStore.init(ctx);
      // 记账 tick 由 App 侧启动（TrafficStatsStore.startAccounting）；此处幂等兜底。
      TrafficStatsStore.startAccounting();
      await ConnectivityProbe.init(ctx);
      const hosts: string[] = await ConnectivityProbe.loadHosts();
      const list: ConnectivityEntry[] = [];
      for (let i = 0; i < hosts.length; i++) {
        const e: ConnectivityEntry = new ConnectivityEntry();
        e.host = hosts[i];
        e.kind = ProbeKind.HTTPS;
        list.push(e);
      }
      this.entries = list;
    } catch (e) {
      AppLogger.warn(TAG, `bootstrap failed: ${AppLogger.errText(e)}`);
    }
    this.isConnected = this.orchestrator.state === ConnState.CONNECTED;
    this.reloadStats();
    this.updateUptime();
    this.startTick();
    this.queryIp('stats-bootstrap');
    this.refreshMemory();
  }

  private reloadStats(): void {
    const v: TrafficStatsView = TrafficStatsStore.view();
    this.lifetimeUp = v.lifetimeUp;
    this.lifetimeDown = v.lifetimeDown;
    this.sessionUp = v.sessionUp;
    this.sessionDown = v.sessionDown;
    this.peakUp = v.peakUp;
    this.peakDown = v.peakDown;
    this.avgUp = v.avgUp;
    this.avgDown = v.avgDown;
    this.resetDay = v.resetDay;
    this.todayUp = v.todayUp;
    this.todayDown = v.todayDown;
  }

  private startTick(): void {
    if (this.tickToken >= 0) {
      return;
    }
    this.tickToken = UnifiedScheduler.every((): void => { this.tick(); }, TICK_MS);
  }

  private stopTick(): void {
    if (this.tickToken >= 0) {
      UnifiedScheduler.clear(this.tickToken);
      this.tickToken = -1;
    }
  }

  /** 每秒：曲线推点 + 读快照 + 运行时间 + 周期性取内存 */
  private tick(): void {
    this.tickCount += 1;
    const connected: boolean = this.orchestrator.state === ConnState.CONNECTED;
    this.isConnected = connected;
    // 记账（累计/按日/峰值/平均）由 TrafficStatsStore 的 App 级 tick 负责，这里只读。
    this.upSpeed = this.orchestrator.traffic.uploadSpeed;
    this.downSpeed = this.orchestrator.traffic.downloadSpeed;

    this.pushRatePoints();
    this.reloadStats();
    this.updateUptime();

    if (connected && !this.memoryBusy && this.tickCount % MEMORY_EVERY === 0) {
      this.refreshMemory();
    }
    if (!connected) {
      this.memoryText = '--';
    }
    if (this.tickCount % PERSIST_EVERY === 0) {
      TrafficStatsStore.persist(false).catch((): void => {});
    }
  }

  private pushRatePoints(): void {
    const ups: number[] = this.upPoints.slice();
    const downs: number[] = this.downPoints.slice();
    ups.push(this.upSpeed);
    downs.push(this.downSpeed);
    while (ups.length > RATE_POINTS) {
      ups.shift();
      downs.shift();
    }
    let upMax: number = 1;
    let downMax: number = 1;
    for (let i = 0; i < ups.length; i++) {
      if (ups[i] > upMax) {
        upMax = ups[i];
      }
      if (downs[i] > downMax) {
        downMax = downs[i];
      }
    }
    if (upMax > this.windowUpPeak) {
      this.windowUpPeak = upMax;
    }
    if (downMax > this.windowDownPeak) {
      this.windowDownPeak = downMax;
    }
    if (this.tickCount % 30 === 0 && this.upSpeed === 0 && this.downSpeed === 0) {
      this.windowUpPeak = 1;
      this.windowDownPeak = 1;
    }
    const nu: number[] = [];
    const nd: number[] = [];
    for (let i = 0; i < ups.length; i++) {
      nu.push(Math.min(1, ups[i] / this.windowUpPeak));
      nd.push(Math.min(1, downs[i] / this.windowDownPeak));
    }
    this.upPoints = nu;
    this.downPoints = nd;
  }

  private updateUptime(): void {
    if (this.orchestrator.state !== ConnState.CONNECTED || this.orchestrator.startedAt <= 0) {
      this.uptimeText = '--:--:--';
      return;
    }
    const secs: number = Math.max(0, Math.floor((Date.now() - this.orchestrator.startedAt) / 1000));
    const h: string = `${Math.floor(secs / 3600)}`.padStart(2, '0');
    const m: string = `${Math.floor((secs % 3600) / 60)}`.padStart(2, '0');
    const s: string = `${secs % 60}`.padStart(2, '0');
    this.uptimeText = `${h}:${m}:${s}`;
  }

  /**
   * 内存占用：优先内核 `/memory`；该端点在本内核上实测会 Operation timeout
   * （真机日志 code=2300028），因此失败时回落到**扩展进程写出的 VmRSS 采样**
   * （内核就活在扩展进程里，两者是同一份内存）。
   */
  private async refreshMemory(): Promise<void> {
    if (this.memoryBusy) {
      return;
    }
    this.memoryBusy = true;
    try {
      const inuse: number = await this.orchestrator.api.fetchMemoryInuse();
      if (inuse > 0) {
        this.memoryText = this.formatBytes(inuse);
        return;
      }
      const kb: number = this.readProcRssKb();
      this.memoryText = kb > 0 ? this.formatBytes(kb * 1024) : '--';
    } catch (e) {
      this.memoryText = '--';
    } finally {
      this.memoryBusy = false;
    }
  }

  /** 读扩展进程写出的 `vpn_mem_kb.txt`（VmRSS，单位 kB）；不可用返回 -1 */
  private readProcRssKb(): number {
    const ctx: Context = getContext(this) as Context;
    const path: string = `${ctx.cacheDir}/vpn_mem_kb.txt`;
    try {
      const text: string = fs.readTextSync(path);
      const kb: number = Number(text.trim());
      if (!this.rssReadLogged) {
        this.rssReadLogged = true;
        AppLogger.info(TAG, `rss sample read ok: ${kb} kB from ${path}`);
      }
      return Number.isFinite(kb) && kb > 0 ? kb : -1;
    } catch (e) {
      if (!this.rssReadLogged) {
        this.rssReadLogged = true;
        AppLogger.warn(TAG, `rss sample unreadable at ${path}: ${AppLogger.errText(e)}`);
      }
      return -1;
    }
  }

  private clearIpInfo(): void {
    this.ipRequestId += 1;
    this.ipText = '';
    this.ipCountry = '';
    this.ipFlag = '';
    this.ipCity = '';
    this.ipIsp = '';
    this.ipAsn = '';
    this.ipTimezone = '';
    this.ipState = 0;
  }

  private async queryIp(trigger: string): Promise<void> {
    if (this.ipBusy) {
      this.ipQueuedTrigger = trigger;
      return;
    }
    const requestId: number = ++this.ipRequestId;
    this.ipBusy = true;
    this.ipState = 1;
    try {
      const info: PublicIpInfo = await PublicIpService.query('stats/' + trigger);
      if (requestId !== this.ipRequestId) {
        return;
      }
      if (info.ip.length === 0) {
        this.ipState = 3;
        this.clearIpInfo();
        this.ipState = 3;
        return;
      }
      this.ipState = 2;
      this.ipText = info.ip;
      this.ipCountry = info.country;
      this.ipFlag = countryCodeToFlag(info.countryCode);
      this.ipCity = info.city;
      this.ipIsp = info.isp;
      this.ipAsn = info.asn;
      this.ipTimezone = info.timezone;
    } catch (e) {
      if (requestId === this.ipRequestId) {
        AppLogger.warn(TAG, `ip query failed: ${AppLogger.errText(e)}`);
        this.ipState = 3;
      }
    } finally {
      this.ipBusy = false;
      if (this.pageMounted && this.ipQueuedTrigger.length > 0) {
        const queued: string = this.ipQueuedTrigger;
        this.ipQueuedTrigger = '';
        this.queryIp(queued);
      }
    }
  }

  private formatBytes(bytes: number): string {
    if (!Number.isFinite(bytes) || bytes <= 0) {
      return '0 B';
    }
    const units: string[] = ['B', 'KB', 'MB', 'GB', 'TB'];
    let value: number = bytes;
    let idx: number = 0;
    while (value >= 1024 && idx < units.length - 1) {
      value = value / 1024;
      idx += 1;
    }
    const fixed: string = idx === 0 ? `${Math.round(value)}` : value.toFixed(2);
    return `${fixed} ${units[idx]}`;
  }

  private formatSpeed(bps: number): string {
    return `${this.formatBytes(bps)}/s`;
  }

  private async testEntry(entry: ConnectivityEntry): Promise<void> {
    const marked: ConnectivityEntry[] = this.entries.slice();
    for (let i = 0; i < marked.length; i++) {
      if (marked[i].host === entry.host) {
        marked[i].state = ProbeState.TESTING;
      }
    }
    this.entries = marked;
    const result: ProbeResult = await ConnectivityProbe.probe(entry.host, entry.kind);
    const next: ConnectivityEntry[] = this.entries.slice();
    for (let i = 0; i < next.length; i++) {
      if (next[i].host === entry.host) {
        next[i].state = result.state;
        next[i].delayMs = result.delayMs;
        next[i].detail = result.detail;
      }
    }
    this.entries = next;
  }

  private async testAll(): Promise<void> {
    if (this.testingAll) {
      return;
    }
    this.testingAll = true;
    try {
      const hosts: string[] = [];
      for (let i = 0; i < this.entries.length; i++) {
        hosts.push(this.entries[i].host);
      }
      for (let i = 0; i < hosts.length; i++) {
        const e: ConnectivityEntry = new ConnectivityEntry();
        e.host = hosts[i];
        e.kind = ProbeKind.HTTPS;
        await this.testEntry(e);
      }
      promptAction.showToast({ message: '✓ 连通性测试完成' });
    } finally {
      this.testingAll = false;
    }
  }

  private async addHost(): Promise<void> {
    const host: string = ConnectivityProbe.normalizeHost(this.hostInput);
    if (host.length === 0) {
      promptAction.showToast({ message: '请输入有效域名' });
      return;
    }
    let exists: boolean = false;
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].host === host) {
        exists = true;
      }
    }
    if (!exists) {
      const e: ConnectivityEntry = new ConnectivityEntry();
      e.host = host;
      e.kind = ProbeKind.HTTPS;
      this.entries = this.entries.concat([e]);
      await this.persistHosts();
    }
    this.hostInput = '';
    this.addingHost = false;
  }

  private async persistHosts(): Promise<void> {
    const hosts: string[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      hosts.push(this.entries[i].host);
    }
    await ConnectivityProbe.saveHosts(hosts);
  }

  private async removeHost(host: string): Promise<void> {
    this.entries = this.entries.filter((x: ConnectivityEntry): boolean => x.host !== host);
    await this.persistHosts();
  }

  private async cycleResetDay(): Promise<void> {
    const next: number = this.resetDay >= 28 ? 1 : this.resetDay + 1;
    await TrafficStatsStore.setResetDay(next);
    this.reloadStats();
    promptAction.showToast({ message: `每月 ${next} 日 00:00 清零累计` });
  }

  private probeStateText(state: ProbeState): string {
    if (state === ProbeState.TESTING) {
      return '测试中…';
    }
    if (state === ProbeState.TIMEOUT) {
      return '超时';
    }
    if (state === ProbeState.UNREACHABLE) {
      return '不可达';
    }
    if (state === ProbeState.FAILED) {
      return '失败';
    }
    if (state === ProbeState.IDLE) {
      return '--';
    }
    return '';
  }

  private probeStateColor(state: ProbeState, delayMs: number): ResourceColor {
    if (state === ProbeState.OK) {
      if (delayMs < 0 || delayMs < 300) {
        return TunBoxColors.success;
      }
      if (delayMs < 800) {
        return TunBoxColors.warning;
      }
      return TunBoxColors.danger;
    }
    if (state === ProbeState.IDLE || state === ProbeState.TESTING) {
      return TunBoxColors.textMuted;
    }
    return TunBoxColors.danger;
  }

  // ───────────────────────── 卡片 ─────────────────────────

  @Builder
  MetricRow(icon: Resource, label: string, value: string, valueColor: ResourceColor) {
    Row({ space: 6 }) {
      Image(icon).width(13).height(13).fillColor(TunBoxColors.textMuted)
      Text(label)
        .fontSize(11).fontColor(TunBoxColors.textMuted)
        .maxLines(1)
      Blank()
      Text(value)
        .fontSize(12).fontWeight(FontWeight.Medium).fontColor(valueColor)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  SpeedCard() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Column({ space: 2 }) {
          Row({ space: 4 }) {
            Image($r('app.media.ic_chevron_down')).width(12).height(12).fillColor(TunBoxColors.primary)
            Text('下载').fontSize(11).fontColor(TunBoxColors.textMuted)
          }
          Text(this.formatSpeed(this.downSpeed))
            .fontSize(18).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Column({ space: 2 }) {
          Row({ space: 4 }) {
            Image($r('app.media.ic_chevron_down'))
              .width(12).height(12).fillColor(TunBoxColors.success)
              .rotate({ angle: 180 })
            Text('上传').fontSize(11).fontColor(TunBoxColors.textMuted)
          }
          Text(this.formatSpeed(this.upSpeed))
            .fontSize(18).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      StatsRateChart({ upPoints: this.upPoints, downPoints: this.downPoints })

      this.MetricRow($r('app.media.ic_bolt'), '峰值',
        `${this.formatSpeed(this.peakDown)} / ${this.formatSpeed(this.peakUp)}`,
        TunBoxColors.textSecondary)
      this.MetricRow($r('app.media.ic_sort'), '平均',
        `${this.formatSpeed(this.avgDown)} / ${this.formatSpeed(this.avgUp)}`,
        TunBoxColors.textSecondary)

      Divider().color(TunBoxColors.cardBorder).strokeWidth(1)

      this.MetricRow($r('app.media.ic_swap'), '本次连接',
        `↓ ${this.formatBytes(this.sessionDown)}   ↑ ${this.formatBytes(this.sessionUp)}`,
        TunBoxColors.textPrimary)
      this.MetricRow($r('app.media.ic_doc'), '累计总量',
        `↓ ${this.formatBytes(this.lifetimeDown)}   ↑ ${this.formatBytes(this.lifetimeUp)}`,
        TunBoxColors.textPrimary)
      this.MetricRow($r('app.media.ic_globe'), '今日',
        `↓ ${this.formatBytes(this.todayDown)}   ↑ ${this.formatBytes(this.todayUp)}`,
        TunBoxColors.textSecondary)

      Text(`每月 ${this.resetDay} 日 00:00 自动清零累计（点按切换 1–28 日）`)
        .fontSize(10).fontColor(TunBoxColors.textMuted)
        .width('100%')
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .onClick((): void => { this.cycleResetDay(); })
    }
    .width('100%')
    .padding(TunBoxGeometry.cardPaddingLarge)
    .backgroundColor(TunBoxColors.surfaceCard)
    .borderRadius(TunBoxGeometry.cardRadius)
    .border({ width: 1, color: TunBoxColors.cardBorder })
    .clip(true)
  }

  /** 内存占用 / 运行时间：两张独立卡片（2026-10-28 用户要求改成卡片 + 加图标） */
  @Builder
  GridCard() {
    Row({ space: 12 }) {
      Column({ space: 6 }) {
        Row({ space: 5 }) {
          Image($r('app.media.ic_memory')).width(14).height(14).fillColor(TunBoxColors.primary)
          Text('内存占用')
            .fontSize(12).fontColor(TunBoxColors.textMuted)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        Text(this.memoryText)
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding(14)
      .backgroundColor(TunBoxColors.surfaceCard)
      .borderRadius(TunBoxGeometry.cardRadius)
      .border({ width: 1, color: TunBoxColors.cardBorder })

      Column({ space: 6 }) {
        Row({ space: 5 }) {
          Image($r('app.media.ic_clock')).width(14).height(14).fillColor(TunBoxColors.primary)
          Text('运行时间')
            .fontSize(12).fontColor(TunBoxColors.textMuted)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        Text(this.uptimeText)
          .fontSize(20).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding(14)
      .backgroundColor(TunBoxColors.surfaceCard)
      .borderRadius(TunBoxGeometry.cardRadius)
      .border({ width: 1, color: TunBoxColors.cardBorder })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  IpCard() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Image($r('app.media.ic_globe')).width(14).height(14).fillColor(TunBoxColors.primary)
        Text('出口 IP')
          .fontSize(13).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
        Blank()
        if (this.ipFlag.length > 0) {
          Text(this.ipFlag).fontSize(16).margin({ right: 6 })
        }
        Text(this.ipState === 1 ? '获取中…'
          : (this.ipState === 3 ? '获取失败，点按重试'
            : (this.ipText.length > 0 ? this.ipText : '--')))
          .fontSize(12)
          .fontColor(this.ipState === 3 ? TunBoxColors.danger
            : (this.ipState === 1 ? TunBoxColors.textMuted : TunBoxColors.textPrimary))
          .fontFamily('monospace')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .onClick((): void => { this.queryIp('user-retry'); })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.ipState === 2) {
        this.MetricRow($r('app.media.ic_globe'), '国家/地区',
          this.ipCountry.length > 0 ? this.ipCountry : '--', TunBoxColors.textSecondary)
        this.MetricRow($r('app.media.ic_globe'), '城市',
          this.ipCity.length > 0 ? this.ipCity : '--', TunBoxColors.textSecondary)
        this.MetricRow($r('app.media.ic_globe'), 'ISP',
          this.ipIsp.length > 0 ? this.ipIsp : '--', TunBoxColors.textSecondary)
        this.MetricRow($r('app.media.ic_globe'), 'ASN',
          this.ipAsn.length > 0 ? this.ipAsn : '--', TunBoxColors.textSecondary)
        this.MetricRow($r('app.media.ic_globe'), '时区',
          this.ipTimezone.length > 0 ? this.ipTimezone : '--', TunBoxColors.textSecondary)
      } else {
        Text(this.ipState === 3 ? '未取得出口信息（节点可能不可用，或查询被限流）'
          : (this.isConnected ? '正在通过隧道查询出口信息…' : '连接后显示出口信息'))
          .fontSize(11).fontColor(TunBoxColors.textMuted)
          .width('100%')
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding(TunBoxGeometry.cardPaddingLarge)
    .backgroundColor(TunBoxColors.surfaceCard)
    .borderRadius(TunBoxGeometry.cardRadius)
    .border({ width: 1, color: TunBoxColors.cardBorder })
    .clip(true)
  }

  @Builder
  ConnectivityRow(entry: ConnectivityEntry) {
    Row({ space: 10 }) {
      Circle({ width: 7, height: 7 })
        .fill(this.probeStateColor(entry.state, entry.delayMs))
      Text(entry.host)
        .fontSize(13).fontColor(TunBoxColors.textPrimary)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(entry.state === ProbeState.OK
        ? (entry.delayMs >= 0 ? `${entry.delayMs} ms` : '通')
        : this.probeStateText(entry.state))
        .fontSize(12).fontWeight(FontWeight.Medium)
        .fontColor(this.probeStateColor(entry.state, entry.delayMs))
        .flexShrink(0)
    }
    .width('100%')
    .height(40)
    .padding({ left: 12, right: 12 })
    .backgroundColor(TunBoxColors.surfaceSubtle)
    .borderRadius(12)
    .alignItems(VerticalAlign.Center)
    .onClick((): void => { this.testEntry(entry); })
  }

  @Builder
  DeleteAction(host: string) {
    Row() {
      Image($r('app.media.ic_delete')).width(18).height(18).fillColor(TunBoxColors.danger)
    }
    .width(64)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(TunBoxColors.dangerLight)
    .onClick((): void => { this.removeHost(host); })
  }

  @Builder
  ConnectivityCard() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Image($r('app.media.ic_shield')).width(14).height(14).fillColor(TunBoxColors.primary)
        Text('连通性')
          .fontSize(13).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
        Blank()
        Row({ space: 4 }) {
          if (this.testingAll) {
            LoadingProgress().width(12).height(12).color(TunBoxColors.primary)
          } else {
            Image($r('app.media.ic_bolt')).width(13).height(13).fillColor(TunBoxColors.primary)
          }
          Text('全部测试').fontSize(11).fontWeight(FontWeight.Medium).fontColor(TunBoxColors.primary)
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(TunBoxGeometry.pillRadius)
        .backgroundColor(TunBoxColors.primaryLight)
        .onClick((): void => { this.testAll(); })

        Row({ space: 4 }) {
          Image($r('app.media.ic_plus')).width(13).height(13).fillColor(TunBoxColors.textMuted)
          Text('添加').fontSize(11).fontColor(TunBoxColors.textMuted)
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(TunBoxGeometry.pillRadius)
        .backgroundColor(TunBoxColors.chipBg)
        .onClick((): void => { this.addingHost = !this.addingHost; })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.addingHost) {
        Row({ space: 8 }) {
          TextInput({ placeholder: 'example.com 或 https://example.com/path' })
            .height(36)
            .layoutWeight(1)
            .fontSize(12)
            .backgroundColor(TunBoxColors.surfaceSubtle)
            .borderRadius(10)
            .onChange((v: string): void => { this.hostInput = v; })
            .onSubmit((_key: EnterKeyType): void => { this.addHost(); })
          Text('确定')
            .fontSize(12).fontWeight(FontWeight.Medium).fontColor(TunBoxColors.primary)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .backgroundColor(TunBoxColors.primaryLight)
            .borderRadius(10)
            .onClick((): void => { this.addHost(); })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      if (this.entries.length > 0) {
        List({ space: 8 }) {
          ForEach(this.entries, (entry: ConnectivityEntry) => {
            ListItem() {
              this.ConnectivityRow(entry)
            }
            .swipeAction({ end: this.DeleteAction(entry.host) })
          }, (entry: ConnectivityEntry) => `${entry.host}|${entry.state}|${entry.delayMs}`)
        }
        .width('100%')
        .height(Math.min(this.entries.length * 48, 240))
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      } else {
        Text('暂无目标，点「添加」输入域名')
          .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
      }

      Text('TCP 直连目标 443；HTTP/HTTPS 在代理运行时经本机代理端口。点按单项重测，左滑删除。')
        .fontSize(10).fontColor(TunBoxColors.textMuted)
        .width('100%')
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding(TunBoxGeometry.cardPaddingLarge)
    .backgroundColor(TunBoxColors.surfaceCard)
    .borderRadius(TunBoxGeometry.cardRadius)
    .border({ width: 1, color: TunBoxColors.cardBorder })
    .clip(true)
  }

  build() {
    Column() {
      TopNavBar({ title: '数据' })

      Scroll() {
        Column({ space: 14 }) {
          this.SpeedCard()
          this.GridCard()
          this.IpCard()
          this.ConnectivityCard()
        }
        .width('100%')
        .padding({
          left: TunBoxGeometry.pagePadding,
          right: TunBoxGeometry.pagePadding,
          bottom: TunBoxGeometry.dockClearance
        })
      }
      .edgeEffect(EdgeEffect.Spring)
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
  }
}
