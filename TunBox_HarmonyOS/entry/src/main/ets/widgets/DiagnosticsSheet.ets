/**
 * 诊断面板（底部弹出）
 * 移植自 upstream: TunBox_Android/lib/widgets/android_diagnostics_sheet.dart
 *                packages/tunbox_shared/lib/widgets/app_diagnostics_view.dart
 *
 * 第二阶段·第三轮增强：新增「链路健康自检」区域
 *   - 展示 lastHealthReport() 的分项（label/status/detail/耗时）
 *   - 最近修复步数 healthRepairStepsLast()、是否正在自检 isHealthCheckRunning()
 *   - 当前网络类型与 generation、重连状态 reconnectState()
 *   - 「立即自检」按钮：复用既有纯逻辑服务 runLinkHealthCheck + OrchestratorHealthProbes
 *     （均为既有的公开入口，未新增任何后端逻辑，也未修改服务模块）
 *   - 「复制脱敏报告」：复用既有 LogRedactor 脱敏能力 + AppLogger 已脱敏日志
 */
import { Ui } from '../theme/UiTokens';
import { AppDiagnostics } from '../commons/models/PublicIpInfo';
import { AppLogger, LogRedactor } from '../commons/utils/AppLogger';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { ConnectionOrchestrator, ReconnectRuntimeState } from '../commons/services/ConnectionOrchestrator';
import { SettingsService } from '../commons/services/SettingsService';
import {
  LinkHealthItem, LinkHealthReport, summarize, runLinkHealthCheck,
  repairSteps, HealthStatus, HealthOverall
} from '../commons/services/LinkHealthChecker';
import { OrchestratorHealthProbes, OrchestratorHealthView } from '../commons/services/OrchestratorHealthProbes';
import { CoreLogStream, CoreLogLine } from '../commons/services/CoreLogStream';

/**
 * 编排器只读运行态的**名义类型适配器**。
 *
 * ArkTS 不支持结构化类型（`arkts-no-structural-typing`）：把
 * `ConnectionOrchestrator` 直接当 `OrchestratorHealthView`（interface）传是不允许的
 * —— 只有**显式 `implements`** 的 class 才是名义类型。
 * 这里做一层薄适配：只读转发，不改任何状态（探针契约：只读 + 无副作用）。
 */
class OrchestratorHealthViewAdapter implements OrchestratorHealthView {
  private orch: ConnectionOrchestrator;

  constructor(orch: ConnectionOrchestrator) {
    this.orch = orch;
  }

  hasSubscriptions(): boolean {
    return this.orch.hasSubscriptions();
  }

  subsNodeCount(): number {
    return this.orch.subsNodeCount();
  }

  currentNodeName(): string {
    return this.orch.currentNodeName();
  }

  isCurrentNodeValid(): boolean {
    return this.orch.isCurrentNodeValid();
  }

  isHeartbeatAlive(): boolean {
    return this.orch.isHeartbeatAlive();
  }

  isTunnelMarkerPresent(): boolean {
    return this.orch.isTunnelMarkerPresent();
  }

  isDesiredConnected(): Promise<boolean> {
    return this.orch.isDesiredConnected();
  }

  isIntentConsistent(): Promise<boolean> {
    return this.orch.isIntentConsistent();
  }

  startErrorText(): string {
    return this.orch.startErrorText();
  }

  isIpv6Enabled(): boolean {
    return this.orch.isIpv6Enabled();
  }

  checkClashApiReachable(): Promise<boolean> {
    return this.orch.checkClashApiReachable();
  }

  checkDnsResolvable(): Promise<boolean> {
    return this.orch.checkDnsResolvable();
  }

  checkIpv6Resolvable(): Promise<boolean> {
    return this.orch.checkIpv6Resolvable();
  }

  checkEgressReachable(): Promise<boolean> {
    return this.orch.checkEgressReachable();
  }
}

/** 日志区 tab：应用运行日志 / 内核实时日志流 */
class LogTab {
  static readonly APP: string = 'app';
  static readonly CORE: string = 'core';
}

/** 内核日志级别筛选（all = 不过滤） */
const CORE_LOG_LEVELS: string[] = ['all', 'debug', 'info', 'warning', 'error'];

@Component
export struct DiagnosticsSheet {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @Prop diag: AppDiagnostics | null = null;
  onRefresh: () => void = () => {};
  onClose: () => void = () => {};

  // ── 链路健康自检状态 ──
  @State healthItems: LinkHealthItem[] = [];
  @State hasReport: boolean = false;
  @State overall: string = '';
  @State passCount: number = 0;
  @State failCount: number = 0;
  @State skipCount: number = 0;
  @State repairCount: number = 0;
  @State running: boolean = false;
  // ── 运行态 ──
  @State netType: string = 'unknown';
  @State generation: number = 0;
  @State reconnectActive: boolean = false;
  @State reconnectConnecting: boolean = false;
  @State reconnectPendingMs: number = 0;
  // ── 内核实时日志流 ──
  @State logTab: string = LogTab.APP;
  @State coreLines: CoreLogLine[] = [];
  @State coreLevelFilter: string = 'all';
  @State coreSearch: string = '';
  @State coreStreamState: string = 'idle';

  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private logStream: CoreLogStream = CoreLogStream.instance();
  private boundCb: (() => void) | null = null;
  private logListener: ((lines: CoreLogLine[]) => void) | null = null;
  /** 日志刷新节流：ws 每条消息都 emit，250ms 合并一次数组重建 */
  private logDirty: boolean = false;
  private logFlushTimer: number = -1;

  aboutToAppear(): void {
    this.orchestrator.init(getContext(this) as Context);
    this.syncFromOrchestratorReport();
    this.syncRuntimeView();
    if (this.boundCb === null) {
      // 订阅既有 orchestrator 通知：网络类型/代际、重连退避、自检运行态变化即时刷新
      const cb: () => void = (): void => {
        this.syncRuntimeView();
      };
      this.boundCb = cb;
      this.orchestrator.listeners.push(cb);
    }
    if (this.logListener === null) {
      this.logListener = (lines: CoreLogLine[]): void => {
        this.coreStreamState = this.logStream.phase();
        this.scheduleLogFlush(lines);
      };
      this.logStream.addListener(this.logListener);
    }
    this.coreStreamState = this.logStream.phase();
    if (this.logTab === LogTab.CORE) {
      this.connectCoreLogStream();
    }
  }

  aboutToDisappear(): void {
    const cb = this.boundCb;
    if (cb !== null) {
      const idx = this.orchestrator.listeners.indexOf(cb);
      if (idx >= 0) {
        this.orchestrator.listeners.splice(idx, 1);
      }
      this.boundCb = null;
    }
    if (this.logListener !== null) {
      this.logStream.removeListener(this.logListener);
      this.logListener = null;
    }
    // 面板关闭即断开 /logs 流（重开面板时重新连接，缓冲保留）
    this.logStream.close();
    if (this.logFlushTimer >= 0) {
      clearTimeout(this.logFlushTimer);
      this.logFlushTimer = -1;
    }
  }

  /** 面板打开/切换到内核 tab 时连接日志流：端点取 orchestrator 当前 API（端口+secret 同源） */
  private connectCoreLogStream(): void {
    const port = this.orchestrator.api.currentPort();
    const secret = this.orchestrator.api.currentSecret();
    this.logStream.connect(port, secret, 'info');
  }

  /** 切换日志 tab；进入内核 tab 时确保流已连接 */
  private switchLogTab(tab: string): void {
    if (this.logTab === tab) {
      return;
    }
    this.logTab = tab;
    if (tab === LogTab.CORE) {
      this.connectCoreLogStream();
    }
  }

  /** 250ms 合并 ws 消息触发的数组重建，避免高频重渲染 */
  private scheduleLogFlush(lines: CoreLogLine[]): void {
    this.logDirty = true;
    if (this.logFlushTimer >= 0) {
      return;
    }
    this.logFlushTimer = setTimeout((): void => {
      this.logFlushTimer = -1;
      if (this.logDirty) {
        this.logDirty = false;
        this.coreLines = this.logStream.snapshot();
      }
    }, 250);
  }

  /** 客户端级级别过滤 + 搜索（内核侧已按 info 下发；debug 需内核 log-level 配合） */
  private visibleCoreLines(): CoreLogLine[] {
    const needle = this.coreSearch.trim().toLowerCase();
    return this.coreLines.filter((l: CoreLogLine): boolean => {
      if (this.coreLevelFilter !== 'all' && l.level !== this.coreLevelFilter) {
        return false;
      }
      if (needle.length > 0 && !l.text.toLowerCase().includes(needle)) {
        return false;
      }
      return true;
    });
  }

  /** 读取编排器缓存的自检报告/汇总/修复步数（不触发任何检查） */
  private syncFromOrchestratorReport(): void {
    const report = this.orchestrator.lastHealthReport();
    if (report !== null) {
      this.applyReport(report);
    }
    this.repairCount = this.orchestrator.healthRepairStepsLast().length;
  }

  /** 读取运行态：网络类型/代际/重连快照/自检运行中 */
  private syncRuntimeView(): void {
    this.running = this.orchestrator.isHealthCheckRunning();
    this.netType = this.orchestrator.currentNetworkType();
    this.generation = this.orchestrator.networkGeneration();
    const r: ReconnectRuntimeState = this.orchestrator.reconnectState();
    this.reconnectActive = r.active;
    this.reconnectConnecting = r.connecting;
    this.reconnectPendingMs = r.pendingDelayMs;
  }

  private applyReport(report: LinkHealthReport): void {
    const summary = summarize(report);
    this.overall = summary.overall;
    this.passCount = summary.passCount;
    this.failCount = summary.failCount;
    this.skipCount = summary.skipCount;
    this.healthItems = report.items.slice();
    this.hasReport = report.items.length > 0;
  }

  /**
   * 「立即自检」：复用既有纯逻辑自检服务与既有探针实现。
   * 不新增后端逻辑，不写编排器缓存（只影响本弹窗展示）。
   */
  private async runNow(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    try {
      const report = await runLinkHealthCheck(new OrchestratorHealthProbes(
        new OrchestratorHealthViewAdapter(this.orchestrator)));
      this.applyReport(report);
      let maxSteps = 2;
      try {
        const s = await SettingsService.load();
        maxSteps = s.healthRepairMaxSteps;
      } catch (e) {
        maxSteps = 2;
      }
      this.repairCount = repairSteps(report, maxSteps).length;
    } catch (e) {
      // runLinkHealthCheck 内部已把异常收敛为 fail 项，这里仅兜底
    }
    this.running = false;
  }

  /** 复制/导出脱敏报告：复用既有 LogRedactor；AppLogger.dump() 本身已脱敏 */
  private copyReport(): void {
    try {
      const parts: string[] = [];
      parts.push(`TunBox diagnostics @ ${new Date().toISOString()}`);
      const d = this.diag;
      const coreUp = d !== null && d.coreRunning;
      const vpnOn = d !== null && d.vpnActive;
      const apiUp = d !== null && d.clashApiReachable;
      const uptime = d !== null ? d.uptimeSeconds : 0;
      parts.push(`core=${coreUp ? 'up' : 'down'} vpn=${vpnOn ? 'on' : 'off'} `
        + `api=${apiUp ? 'reachable' : 'unreachable'} uptime=${uptime}s`);
      parts.push(`health overall=${this.overall.length > 0 ? this.overall : 'n/a'} `
        + `pass=${this.passCount} fail=${this.failCount} skip=${this.skipCount} `
        + `repairSteps=${this.repairCount} running=${this.running}`);
      for (const it of this.healthItems) {
        const val = it.value.length > 0 ? ` => ${it.value}` : '';
        const dur = it.durationMs > 0 ? ` [${it.durationMs}ms]` : '';
        parts.push(`[${it.status}] ${it.id} (${it.label}): ${it.detail}${val}${dur}`);
      }
      const rc = this.reconnectConnecting ? 'connecting'
        : (this.reconnectActive ? `backoff:${this.reconnectPendingMs}ms` : 'idle');
      parts.push(`net=${this.netType} gen=${this.generation} reconnect=${rc}`);
      parts.push('');
      parts.push(AppLogger.dump().join('\n'));
      const safe = LogRedactor.redact(parts.join('\n'));
      const data = pasteboard.getSystemPasteboard();
      data.setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, safe));
      promptAction.showToast({ message: $r('app.string.diagnostics_health_report_copied') });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.diagnostics_health_copy_failed') });
    }
  }

  // ── 展示辅助 ──

  private statusLabel(status: string): Resource {
    if (status === HealthStatus.PASS) {
      return $r('app.string.diagnostics_status_pass');
    }
    if (status === HealthStatus.FAIL) {
      return $r('app.string.diagnostics_status_fail');
    }
    return $r('app.string.diagnostics_status_skip');
  }

  private statusColor(status: string): ResourceColor {
    if (status === HealthStatus.PASS) {
      return Ui.success;
    }
    if (status === HealthStatus.FAIL) {
      return Ui.error;
    }
    return Ui.textTertiary;
  }

  private overallLabel(): Resource {
    if (this.overall === HealthOverall.OK) {
      return $r('app.string.diagnostics_health_overall_ok');
    }
    if (this.overall === HealthOverall.BROKEN) {
      return $r('app.string.diagnostics_health_overall_broken');
    }
    return $r('app.string.diagnostics_health_overall_degraded');
  }

  private overallColor(): ResourceColor {
    if (this.overall === HealthOverall.OK) {
      return Ui.success;
    }
    if (this.overall === HealthOverall.BROKEN) {
      return Ui.error;
    }
    return Ui.warning;
  }

  private reconnectLabel(): Resource {
    if (this.reconnectConnecting) {
      return $r('app.string.diagnostics_health_reconnect_connecting');
    }
    if (this.reconnectActive) {
      return $r('app.string.diagnostics_health_reconnect_active', this.reconnectPendingMs);
    }
    return $r('app.string.diagnostics_health_reconnect_idle');
  }

  build() {
    Column({ space: 10 }) {
      Row() {
        Text($r('app.string.diagnostics_title'))
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(Ui.textPrimary)
        Blank()
        Text($r('app.string.diagnostics_refresh'))
          .fontSize(14)
          .fontColor(Ui.primary)
          .onClick(() => this.onRefresh())
        Text($r('app.string.diagnostics_close'))
          .fontSize(14)
          .fontColor(Ui.textSecondary)
          .onClick(() => this.onClose())
          .padding({ left: 16 })
      }
      .width('100%')

      Row() {
        Text($r('app.string.diagnostics_core_running')).fontSize(14).fontColor(Ui.textSecondary).layoutWeight(1)
        Text(this.diag !== null && this.diag.coreRunning
          ? $r('app.string.diagnostics_core_ok') : $r('app.string.diagnostics_core_stopped'))
          .fontSize(14)
          .fontColor(this.diag !== null && this.diag.coreRunning ? Ui.success : Ui.error)
      }.width('100%')

      Row() {
        Text($r('app.string.diagnostics_vpn_active')).fontSize(14).fontColor(Ui.textSecondary).layoutWeight(1)
        Text(this.diag !== null && this.diag.vpnActive
          ? $r('app.string.diagnostics_vpn_on') : $r('app.string.diagnostics_vpn_off'))
          .fontSize(14)
          .fontColor(this.diag !== null && this.diag.vpnActive ? Ui.success : Ui.warning)
      }.width('100%')

      Row() {
        Text($r('app.string.diagnostics_clash_api')).fontSize(14).fontColor(Ui.textSecondary).layoutWeight(1)
        Text(this.diag !== null && this.diag.clashApiReachable
          ? $r('app.string.diagnostics_api_reachable', this.diag.clashApiPort)
          : $r('app.string.diagnostics_api_unreachable'))
          .fontSize(14)
          .fontColor(this.diag !== null && this.diag.clashApiReachable ? Ui.success : Ui.error)
      }.width('100%')

      Row() {
        Text($r('app.string.diagnostics_uptime')).fontSize(14).fontColor(Ui.textSecondary).layoutWeight(1)
        Text(`${this.diag !== null ? this.diag.uptimeSeconds : 0}s`)
          .fontSize(14).fontColor(Ui.textPrimary)
      }.width('100%')

      if (this.diag !== null && this.diag.lastError.length > 0) {
        Text($r('app.string.diagnostics_last_error', this.diag.lastError))
          .fontSize(13)
          .fontColor(Ui.error)
          .width('100%')
      }

      Divider().color(Ui.border)

      // ── 链路健康自检 ──
      Row() {
        Text($r('app.string.diagnostics_health_title'))
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor(Ui.textPrimary)
        if (this.hasReport) {
          Text(this.overallLabel())
            .fontSize(12)
            .fontColor(this.overallColor())
            .padding({ left: 8 })
        }
        Blank()
        Text(this.running
          ? $r('app.string.diagnostics_health_running')
          : $r('app.string.diagnostics_health_run_now'))
          .fontSize(13)
          .fontColor(this.running ? Ui.textTertiary : Ui.primary)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(10)
          .backgroundColor(Ui.surfaceTranslucent(this.themeRevision))
          .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
            colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
          })
          .backgroundEffect({ radius: Ui.glassControlBlurRadius, saturation: Ui.glassControlSaturation, brightness: Ui.glassControlBrightness })
          .borderWidth(1)
          .borderColor(Ui.glassEdge(this.themeRevision))
          .onClick(() => {
            if (!this.running) {
              this.runNow();
            }
          })
        Text($r('app.string.diagnostics_health_copy_report'))
          .fontSize(13)
          .fontColor(Ui.textBlue)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .onClick(() => this.copyReport())
      }
      .width('100%')

      if (this.hasReport) {
        Row() {
          Text($r('app.string.diagnostics_health_counts', this.passCount, this.failCount, this.skipCount))
            .fontSize(12).fontColor(Ui.textSecondary).layoutWeight(1)
          Text($r('app.string.diagnostics_health_repair_steps'))
            .fontSize(12).fontColor(Ui.textSecondary)
          Text(this.repairCount > 0 ? `${this.repairCount}` : $r('app.string.diagnostics_health_repair_none'))
            .fontSize(12).fontColor(Ui.textPrimary).padding({ left: 6 })
        }.width('100%')
      } else {
        Text($r('app.string.diagnostics_health_not_run'))
          .fontSize(12).fontColor(Ui.textTertiary).width('100%')
      }

      Row({ space: 12 }) {
        Row({ space: 4 }) {
          Text($r('app.string.diagnostics_health_network')).fontSize(11).fontColor(Ui.textTertiary)
          Text(this.netType.length > 0 ? this.netType : '-').fontSize(11).fontColor(Ui.textSecondary)
        }
        Row({ space: 4 }) {
          Text($r('app.string.diagnostics_health_generation')).fontSize(11).fontColor(Ui.textTertiary)
          Text(`${this.generation}`).fontSize(11).fontColor(Ui.textSecondary)
        }
        Row({ space: 4 }) {
          Text($r('app.string.diagnostics_health_reconnect')).fontSize(11).fontColor(Ui.textTertiary)
          Text(this.reconnectLabel())
            .fontSize(11)
            .fontColor(this.reconnectActive || this.reconnectConnecting ? Ui.warning : Ui.textSecondary)
        }
      }
      .width('100%')

      if (this.hasReport) {
        List({ space: 4 }) {
          ForEach(this.healthItems, (item: LinkHealthItem) => {
            ListItem() {
              Column({ space: 2 }) {
                Row({ space: 6 }) {
                  Text(this.statusLabel(item.status))
                    .fontSize(11)
                    .fontColor(this.statusColor(item.status))
                    .constraintSize({ minWidth: 30 })
                  Text(item.label)
                    .fontSize(12).fontColor(Ui.textPrimary).layoutWeight(1).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`${item.durationMs}ms`)
                    .fontSize(10).fontColor(Ui.textTertiary)
                }.width('100%')
                Text(item.detail.length > 0 ? item.detail : item.advice)
                  .fontSize(10).fontColor(Ui.textSecondary).width('100%').maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
            }
          }, (item: LinkHealthItem) => item.id + '#' + item.status + '#' + item.durationMs.toString())
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
      } else {
        Blank().layoutWeight(1)
      }

      Divider().color(Ui.border)

      // ── 日志区：应用运行日志 / 内核实时日志流 双 tab ──
      Row({ space: 8 }) {
        Text($r('app.string.diagnostics_log_title'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(Ui.textPrimary)
        Blank()
        Text('运行日志')
          .fontSize(12)
          .fontWeight(this.logTab === LogTab.APP ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.logTab === LogTab.APP ? Ui.primary : Ui.textSecondary)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(10)
          .backgroundColor(this.logTab === LogTab.APP ? Ui.selectedBackground(this.themeRevision) : Color.Transparent)
          .borderWidth(1)
          .borderColor(this.logTab === LogTab.APP ? Ui.primary : Ui.border)
          .onClick(() => this.switchLogTab(LogTab.APP))
        Text('内核日志')
          .fontSize(12)
          .fontWeight(this.logTab === LogTab.CORE ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.logTab === LogTab.CORE ? Ui.primary : Ui.textSecondary)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(10)
          .backgroundColor(this.logTab === LogTab.CORE ? Ui.selectedBackground(this.themeRevision) : Color.Transparent)
          .borderWidth(1)
          .borderColor(this.logTab === LogTab.CORE ? Ui.primary : Ui.border)
          .onClick(() => this.switchLogTab(LogTab.CORE))
      }
      .width('100%')

      if (this.logTab === LogTab.APP) {
        List() {
          ForEach(AppLogger.dump(), (line: string) => {
            ListItem() {
              Text(line)
                .fontSize(11)
                .fontFamily('monospace')
                .fontColor(Ui.textSecondary)
                .width('100%')
                .padding({ top: 1, bottom: 1 })
            }
          }, (line: string, idx: number) => `${idx}-${line.length}`)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
      } else {
        Column({ space: 6 }) {
          Row({ space: 6 }) {
            Text(this.coreStreamState === 'open' ? '● 已连接'
              : (this.coreStreamState === 'connecting' ? '● 连接中…' : '● 未连接'))
              .fontSize(10)
              .fontColor(this.coreStreamState === 'open' ? Ui.success
                : (this.coreStreamState === 'connecting' ? Ui.warning : Ui.textTertiary))
            Blank()
            ForEach(CORE_LOG_LEVELS, (lv: string) => {
              Text(lv)
                .fontSize(10)
                .fontWeight(this.coreLevelFilter === lv ? FontWeight.Bold : FontWeight.Normal)
                .fontColor(this.coreLevelFilter === lv ? Ui.primary : Ui.textTertiary)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(8)
                .backgroundColor(this.coreLevelFilter === lv ? Ui.selectedBackground(this.themeRevision) : Color.Transparent)
                .borderWidth(1)
                .borderColor(this.coreLevelFilter === lv ? Ui.primary : Ui.border)
                .onClick(() => {
                  this.coreLevelFilter = lv;
                })
            }, (lv: string) => lv)
          }.width('100%')
          TextInput({
            placeholder: '搜索内核日志…',
            text: this.coreSearch
          })
            .height(32)
            .fontSize(11)
            .onChange((value: string) => {
              this.coreSearch = value;
            })
            .backgroundColor(Ui.inputBackground(this.themeRevision))
            .borderRadius(10)
          if (this.visibleCoreLines().length === 0) {
            Text(this.coreStreamState === 'open'
              ? '暂无匹配日志。产生流量后此处会实时滚动内核日志（warning 级别优先出现）。'
              : '内核日志流未连接：连接 VPN 后打开本面板即可实时查看。')
              .fontSize(11)
              .fontColor(Ui.textTertiary)
              .width('100%')
              .padding(8)
          } else {
            List() {
              ForEach(this.visibleCoreLines(), (line: CoreLogLine) => {
                ListItem() {
                  Row({ space: 6 }) {
                    Text(line.level)
                      .fontSize(9)
                      .fontColor(line.level === 'error' ? Ui.error
                        : (line.level === 'warning' ? Ui.warning : Ui.textTertiary))
                      .constraintSize({ minWidth: 44 })
                    Text(line.text)
                      .fontSize(10.5)
                      .fontFamily('monospace')
                      .fontColor(Ui.textSecondary)
                      .layoutWeight(1)
                  }.width('100%').padding({ top: 1, bottom: 1 })
                }
              }, (line: CoreLogLine) => `${line.receivedAt}-${line.text.length}`)
            }
            .layoutWeight(1)
            .scrollBar(BarState.Auto)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
    }
    .padding(20)
    .backgroundColor(Ui.surfaceTranslucent(this.themeRevision))
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.SYSTEM, adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({
      radius: Ui.glassBlurRadius,
      saturation: Ui.glassSaturationSoft,
      brightness: Ui.glassBrightnessSoft
    })
    .borderWidth({ top: 1 })
    .borderColor(Ui.glassEdge(this.themeRevision))
    .shadow({ radius: 32, color: Ui.shadow, offsetY: -10 })
    .borderRadius({ topLeft: 20, topRight: 20 })
  }
}
