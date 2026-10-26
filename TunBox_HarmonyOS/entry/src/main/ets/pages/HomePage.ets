/**
 * HomePage —— TunBox 主页（严格对齐《TunBox-UI重构笔记》§3.1 首页）
 * 布局：TopNavBar(TunBox + rightSlot 备份/主题) → 天体轨域启动按钮(CelestialPowerOrb 320/280/200，
 *      2026-10-17 用户按 stitch 设计稿重构，原 StatusRing 三层同心环下架；按钮内含当前节点名)
 *      → 代理模式三段按钮(规则/全局/直连，启动按钮下方) → 实时速率与流量卡(RateChart，含公网 IP) → 错误条
 * 2026-10-17：规则模式卡片下架，三项迁入 SettingsPage（用户 batch-2）。
 * 后端：复用 ConnectionOrchestrator / SubscriptionService / SettingsService / LatencyController 全量逻辑（未改动）。
 */
import { router, promptAction } from '@kit.ArkUI';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { window } from '@kit.ArkUI';
import { NexusSizes } from '../theme/NexusTokens';
import { TunBoxColors, TunBoxGeometry } from '../theme/TunBoxTokens';
import { TopNavBar } from '../components/TopNavBar';
import { CelestialPowerOrb } from '../components/CelestialPowerOrb';
import { RateChart } from '../components/RateChart';
import { TabLifecycleBridge } from '../commons/utils/TabLifecycleBridge';
import { ConnectionOrchestrator, ConnState } from '../commons/services/ConnectionOrchestrator';
import { ConnectionEntry } from '../commons/services/ClashApiService';
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
import { BackupRestoreService, RestoreOutcome } from '../commons/services/BackupRestoreService';
import { BackupCrypto } from '../commons/services/BackupCrypto';

const TAG = 'HomePage';
/** 连接卡展开时预览的活跃连接条数（全部连接走「连接管理」） */
const CONN_PREVIEW_MAX = 5;
/** 连接卡预览轮询周期（与 ConnectionsPage 一致） */
const CONN_PREVIEW_POLL_MS = 2000;

/** 配置备份与恢复弹窗（Nexus §9）：导出/导入订阅+自定义规则 JSON */
@CustomDialog
struct BackupDialog {
  controller?: CustomDialogController;
  @State toastMsg: string = '';
  onExport: () => void = () => {};
  onImport: () => void = () => {};
  getToast: () => string = (): string => '';

  aboutToAppear(): void {
    this.toastMsg = '';
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Image($r('app.media.ic_doc'))
          .width(20).height(20)
          .fillColor(TunBoxColors.primary)
        Text('配置备份与恢复').fontSize(16).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
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
      Text('备份范围包括当前全部已导入的订阅、节点以及自定义规则配置。')
        .fontSize(12).fontColor(TunBoxColors.textMuted).width('100%')
      Column({ space: 4 }) {
        Text('📤 导出当前配置备份').fontSize(13).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary).width('100%')
        Text('生成包含所有订阅和规则的 .json 备份文件，便于多设备同步或留存。')
          .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
        Button('导出备份文件 (.json)')
          .width('100%').borderRadius(8)
          .backgroundColor(TunBoxColors.primary).fontColor(Color.White).fontSize(12.5)
          .onClick(() => this.onExport())
      }
      .width('100%').padding(12).borderRadius(12)
      .backgroundColor(TunBoxColors.background)
      .borderWidth(1).borderColor(TunBoxColors.cardBorder)
      Column({ space: 4 }) {
        Text('📥 导入恢复配置').fontSize(13).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary).width('100%')
        Text('上传备份的 .json 配置文件，一键恢复所有订阅及自定义规则。')
          .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
        Button('选择备份文件并恢复')
          .width('100%').borderRadius(8)
          .backgroundColor(TunBoxColors.surfaceCard).fontColor(TunBoxColors.textPrimary).fontSize(12.5)
          .borderWidth(1.5).borderColor(TunBoxColors.cardBorder)
          .onClick(() => this.onImport())
      }
      .width('100%').padding(12).borderRadius(12)
      .backgroundColor(TunBoxColors.background)
      .borderWidth(1).borderColor(TunBoxColors.cardBorder)
      if (this.getToast().length > 0) {
        Text(this.getToast())
          .fontSize(11.5).fontWeight(FontWeight.Bold).fontColor(Color.White)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(9999).backgroundColor(TunBoxColors.success)
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

/**
 * 备份密码输入弹窗（P0-4 收尾）：导出/导入加密备份时收集密码。
 * mode: 'export'（确认导出，可选留空=明文）| 'import'（必填密码解密，失败可重试）
 * 结果通过 onSubmit(password) 回传，取消通过 onCancel() 回传。
 */
@CustomDialog
struct BackupPasswordDialog {
  controller?: CustomDialogController;
  @State mode: string = 'export';
  @State attemptHint: string = '';
  @State password: string = '';
  onSubmit: (password: string) => void = (_password: string) => {};
  onCancel: () => void = () => {};

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Image($r('app.media.ic_lock')).width(18).height(18).fillColor(TunBoxColors.primary)
        Text(this.mode === 'export' ? '设置备份密码' : '输入备份密码')
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
      }.width('100%')
      if (this.mode === 'export') {
        Text('使用 AES-256-GCM 加密备份。留空则导出明文；密码至少 4 个字符，遗忘后无法恢复。')
          .fontSize(11.5).fontColor(TunBoxColors.textMuted).width('100%')
      } else {
        Text(this.attemptHint.length > 0 ? this.attemptHint : '此备份已加密，请输入导出时设置的密码。')
          .fontSize(11.5).fontColor(TunBoxColors.textMuted).width('100%')
      }
      TextInput({ placeholder: this.mode === 'export' ? '密码（留空=明文备份）' : '备份密码', text: this.password })
        .type(InputType.Password)
        .width('100%').height(42).borderRadius(8)
        .fontSize(13)
        .onChange((value: string) => {
          this.password = value;
        })
      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1).height(38).borderRadius(8)
          .backgroundColor(TunBoxColors.surfaceCard).fontColor(TunBoxColors.textMuted).fontSize(13)
          .borderWidth(1).borderColor(TunBoxColors.cardBorder)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onCancel();
          })
        Button(this.mode === 'export' ? '确认导出' : '解密恢复')
          .layoutWeight(1).height(38).borderRadius(8)
          .backgroundColor(TunBoxColors.primary).fontColor(Color.White).fontSize(13)
          .onClick(() => {
            if (this.mode === 'import' && this.password.length < 4) {
              this.attemptHint = '密码至少 4 个字符，请重新输入。';
              return;
            }
            const pw = this.password;
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onSubmit(pw);
          })
      }.width('100%')
    }
    .padding(20)
    .borderRadius(20)
    // 沉浸光感适配（官方《组件适配沉浸光感》+《沉浸光感常见问题》）：应用级 enable
    // 后 CustomDialog 默认 ULTRA_THICK 沉浸材质背板；材质层级位于背景色/背景模糊之下，
    // 不透明背景色、背景模糊与自定义 shadow 都会遮挡材质（官方反模式），根容器不再设置，
    // 视觉交给系统材质统一接管；内容层（行卡片/输入框/按钮）样式保持不动。
  }
}

@Component
export struct HomePage {
  @State isConnected: boolean = false;
  @State isConnecting: boolean = false;
  /** 乐观反馈（2026-10-17 用户反馈「点启动 1 秒多按钮才动」）：点击瞬间点亮「正在连接」，
   *  覆盖订阅 hydrate 等待（冷启最多 ~1.5s）与 connect 进入 CONNECTING 前的空窗；
   *  编排器状态翻转后由真实 isConnecting 接管，流程结束（含失败/无节点）即清除 */
  @State pendingStart: boolean = false;
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
  @State upSpeed: number = 0;
  @State downSpeed: number = 0;
  @State upTotal: number = 0;
  @State downTotal: number = 0;
  @State connectionDuration: number = 0;
  @State proxyMode: string = 'rule';
  @State private connCardOpen: boolean = false;
  /** 连接卡预览：活跃连接前 5 条（按流量降序，全部连接走「连接管理」） */
  @State private connPreview: ConnectionEntry[] = [];
  @State private connPreviewReachable: boolean = true;
  private connPreviewTimer: number = -1;
  private connPreviewBusy: boolean = false;
@State ratePoints: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
  @State backupToast: string = '';
  @StorageLink('theme_revision') themeRevision: number = 0;
  @StorageLink('public_ip_revision') @Watch('onPublicIpRevision') publicIpRevision: number = 0;
  @StorageLink('vpn_request_seq') @Watch('onVpnRequest') vpnRequestSeq: number = 0;
  private pageReady: boolean = false;
  /** 宿主（MainPage）「重新展示」通知桥：替代 @Entry 页面的 onPageShow（见 TabLifecycleBridge） */
  shownBridge?: TabLifecycleBridge;
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private subs: SubscriptionService = SubscriptionService.instance();
  private settings: AppSettings = new AppSettings();
  private readonly connectionListener: () => void = (): void => {
    this.applyOrchestratorState();
  };
  private listenerBound: boolean = false;
  private connectionTimer: number = -1;
  private backupDialog: CustomDialogController = new CustomDialogController({
    builder: BackupDialog({
      getToast: (): string => this.backupToast,
      onExport: (): void => {
        this.exportBackup();
      },
      onImport: (): void => {
        this.importBackup();
      }
    }),
    autoCancel: true
  });
  private exportPassword: string = '';
  private exportPending: boolean = false;
  private exportPasswordAsked: boolean = false;
  private importPendingText: string = '';
  private importAttempt: number = 0;
  @State private importDialogMode: string = 'import';
  @State private importHint: string = '';
  private backupPasswordDialog: CustomDialogController = new CustomDialogController({
    builder: BackupPasswordDialog({
      mode: this.importDialogMode,
      attemptHint: this.importHint,
      onSubmit: (password: string): void => {
        if (this.exportPending) {
          this.exportPending = false;
          this.exportPassword = password;
          this.exportBackup();
        } else if (this.importPendingText.length > 0) {
          this.decryptImportedBackup(this.importPendingText, password);
        }
      },
      onCancel: (): void => {
        this.exportPending = false;
        this.exportPassword = '';
        this.importPendingText = '';
      }
    }),
    autoCancel: true
  });

  /** 对导入文本尝试解密：成功→继续导入；失败→重开密码弹窗（最多 3 次） */
  private decryptImportedBackup(text: string, password: string): void {
    const dec = BackupCrypto.decrypt(text, password);
    if (dec.ok) {
      this.importPendingText = '';
      this.importAttempt = 0;
      this.finishImport(dec.text);
      return;
    }
    promptAction.showToast({ message: dec.message });
    this.importAttempt += 1;
    if (this.importAttempt >= 3) {
      this.importAttempt = 0;
      this.importPendingText = '';
      return;
    }
    this.openImportPasswordDialog(text, `密码错误，还可尝试 ${2 - this.importAttempt} 次。`);
  }

  private openImportPasswordDialog(text: string, hint: string): void {
    this.importPendingText = text;
    // BackupPasswordDialog 按 exportPending 判定模式；导入前先确保非导出态
    this.exportPending = false;
    this.importHint = hint;
    this.importDialogMode = 'import';
    this.backupPasswordDialog.open();
  }

  /** 导入结果应用：恢复成功则重载设置并提示 */
  private applyImportOutcome(outcome: RestoreOutcome): void {
    if (outcome.ok) {
      SettingsService.load().then((loaded: AppSettings): void => {
        this.settings = loaded;
        const pm: string = this.settings.proxyMode;
    this.proxyMode = (pm === 'global' || pm === 'direct') ? pm : 'rule';
        this.refreshDisplayNode();
      });
      this.backupToast = `✓ 恢复成功！已导入 ${outcome.subCount} 个订阅及自定义规则`;
      promptAction.showToast({ message: this.backupToast });
    } else {
      promptAction.showToast({ message: outcome.message });
    }
  }

  /** finishImport：解密成功后的导入入口（复用 importBackup 的恢复逻辑） */
  private finishImport(text: string): void {
    BackupRestoreService.importJsonText(text).then((outcome: RestoreOutcome): void => {
      this.applyImportOutcome(outcome);
    }).catch((): void => {
      promptAction.showToast({ message: '导入失败，请重试' });
    });
  }

  aboutToAppear(): void {
    // 作为主页页签内容组件（非 @Entry 页）后：页签「重新展示」由宿主经桥通知，
    // 语义等价于原 onPageShow（从子页返回 / 切回页签时刷新）。
    if (this.shownBridge !== undefined) {
      this.shownBridge.setShowHandler((): void => { this.refreshForShown(); });
    }
  }

  /** 宿主通知的「重新展示」：执行原 onPageShow 的刷新 */
  refreshForShown(): void {
    this.bootstrap();
  }

  aboutToDisappear(): void {
    this.pageReady = false;
    this.stopConnectionTimer();
    this.stopConnPreview();
    if (this.shownBridge !== undefined) {
      this.shownBridge.setShowHandler(null);
    }
    if (this.listenerBound) {
      this.orchestrator.removeListener(this.connectionListener);
      this.listenerBound = false;
    }
  }

  private knownNodeNames(): string[] {
    return this.subs.nodes.map((n: ProxyNode): string => n.name);
  }

  /** 连接卡展开期间的 2s 轮询：活跃连接前 5 条（对齐 ConnectionsPage 排序口径） */
  private async refreshConnPreview(): Promise<void> {
    if (this.connPreviewBusy) {
      return;
    }
    this.connPreviewBusy = true;
    try {
      if (!this.isConnected) {
        this.connPreview = [];
        this.connPreviewReachable = true;
        return;
      }
      const list = await this.orchestrator.api.listConnections(this.knownNodeNames());
      if (list === null) {
        this.connPreviewReachable = false;
        return;
      }
      this.connPreviewReachable = true;
      list.sort((a: ConnectionEntry, b: ConnectionEntry): number =>
        (b.download + b.upload) - (a.download + a.upload));
      this.connPreview = list.slice(0, CONN_PREVIEW_MAX);
    } catch (e) {
      AppLogger.warn('HomePage', `conn preview failed: ${AppLogger.errText(e)}`);
    } finally {
      this.connPreviewBusy = false;
    }
  }

  private startConnPreview(): void {
    if (this.connPreviewTimer >= 0) {
      return;
    }
    this.refreshConnPreview();
    this.connPreviewTimer = setInterval((): void => {
      this.refreshConnPreview();
    }, CONN_PREVIEW_POLL_MS);
  }

  private stopConnPreview(): void {
    if (this.connPreviewTimer >= 0) {
      clearInterval(this.connPreviewTimer);
      this.connPreviewTimer = -1;
    }
  }

  private toggleConnCard(): void {
    this.connCardOpen = !this.connCardOpen;
    if (this.connCardOpen) {
      this.startConnPreview();
    } else {
      this.stopConnPreview();
    }
  }

  private formatConnBytes(total: number): string {
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
    this.upSpeed = this.orchestrator.traffic.uploadSpeed;
    this.downSpeed = this.orchestrator.traffic.downloadSpeed;
    this.upTotal = this.orchestrator.traffic.uploadBytes;
    this.downTotal = this.orchestrator.traffic.downloadBytes;
    if (!this.isConnected) {
      this.ratePoints = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    }
    if (this.pageReady) {
      this.syncConnectionTimer();
    }
    this.refreshDisplayNode();
  }

  private syncConnectionTimer(): void {
    if (this.orchestrator.state !== ConnState.CONNECTED || this.orchestrator.startedAt <= 0) {
      this.connectionDuration = 0;
      this.stopConnectionTimer();
      return;
    }
    this.connectionDuration = Math.max(0,
      Math.floor((Date.now() - this.orchestrator.startedAt) / 1000));
    if (this.connectionTimer >= 0) {
      return;
    }
    this.connectionTimer = setInterval(() => {
      if (this.orchestrator.state !== ConnState.CONNECTED || this.orchestrator.startedAt <= 0) {
        this.connectionDuration = 0;
        this.stopConnectionTimer();
        return;
      }
      this.connectionDuration = Math.max(0,
        Math.floor((Date.now() - this.orchestrator.startedAt) / 1000));
      // 速率采样：滑动窗口 26 点，量程 1500KB/s
      const speed = this.orchestrator.traffic.uploadSpeed + this.orchestrator.traffic.downloadSpeed;
      const ratio = Math.min(1, Math.max(0, speed / (1500 * 1024)));
      const next = this.ratePoints.slice();
      next.push(ratio);
      if (next.length > NexusSizes.ratePoints) {
        next.splice(0, next.length - NexusSizes.ratePoints);
      }
      this.ratePoints = next;
      this.upSpeed = this.orchestrator.traffic.uploadSpeed;
      this.downSpeed = this.orchestrator.traffic.downloadSpeed;
      this.upTotal = this.orchestrator.traffic.uploadBytes;
      this.downTotal = this.orchestrator.traffic.downloadBytes;
    }, 1000);
  }

  private stopConnectionTimer(): void {
    if (this.connectionTimer >= 0) {
      clearInterval(this.connectionTimer);
      this.connectionTimer = -1;
    }
  }

  private async toggleTheme(): Promise<void> {
    await ThemeService.toggle();
    const mainWindow = AppStorage.get<window.Window>('main_window');
    if (mainWindow !== undefined) {
      await ThemeService.syncSystemBars(mainWindow);
    }
  }

  private async bootstrap(): Promise<void> {
    const ctx = getContext(this) as Context;
    this.orchestrator.init(ctx);
    await SettingsService.init(ctx);
    await this.subs.init(ctx);
    this.settings = await SettingsService.load();
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
    if (!this.listenerBound) {
      this.listenerBound = true;
      this.orchestrator.addListener(this.connectionListener);
    }
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
    this.applyOrchestratorState();
    this.pageReady = true;
    this.syncConnectionTimer();
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

  private async startConnectionIfNeeded(): Promise<void> {
    // 显式用户操作（快捷方式 start）：清除长时任务抑制态
    UiGuardian.clearExternalCancelSuppression();
    if (this.isConnecting || this.isConnected || this.pendingStart) {
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
        promptAction.showToast({ message: '暂无可用节点，请先在「订阅」页添加并刷新' });
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
    const preferred = await this.subs.resolvePreferredNode();
    return preferred !== null ? preferred : this.subs.fallbackConnectionNode();
  }

  private refreshDisplayNode(): void {
    // 与订阅页顶部概览卡共用同一条取值路径（orchestrator.displayNodeName），
    // 两处显示必然一致。旧实现在这里各算一套，订阅页那份按连接状态分叉 →
    // 未连接时显示「未选择」，与主页按钮不一致（2026-10-25 用户实锤）。
    this.currentNodeName = this.orchestrator.displayNodeName(
      this.settings.preferredNodeId, this.settings.autoSelectMode);
  }

  /** 实时速率数值与单位拆分（文档 §3.1：数值 26 Bold + 单位 13 textSecondary） */
  private realtimeRateParts(): string[] {
    if (!this.isConnected) {
      return ['0.0', 'KB/s'];
    }
    return this.formatSpeedValue(this.upSpeed + this.downSpeed).split(' ');
  }

  private formatSpeedValue(bytesPerSecond: number): string {
    if (bytesPerSecond < 1024) {
      return `${Math.round(bytesPerSecond)} B/s`;
    }
    const kb = bytesPerSecond / 1024;
    if (kb < 1024) {
      return `${kb.toFixed(1)} KB/s`;
    }
    return `${(kb / 1024).toFixed(1)} MB/s`;
  }

  private formatTotalMB(): string {
    const total = this.upTotal + this.downTotal;
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

  private formatDuration(): string {
    const s = Math.max(0, Math.floor(this.connectionDuration));
    const hh = `0${Math.floor(s / 3600)}`.slice(-2);
    const mm = `0${Math.floor((s % 3600) / 60)}`.slice(-2);
    const ss = `0${s % 60}`.slice(-2);
    return this.connectionDuration > 0 ? `${hh}:${mm}:${ss}` : '--:--:--';
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
        promptAction.showToast({ message: '暂无可用节点，请先在「订阅」页添加并刷新' });
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

  /** Nexus §9 导出：快照 → JSON → 可选密码加密 → 系统文件选择器另存（用户自选导出位置） */
  private async exportBackup(): Promise<void> {
    try {
      // P0-4：先经密码弹窗收集可选密码（留空=明文），确认后再走文件选择器
      if (!this.exportPasswordAsked) {
        this.exportPasswordAsked = true;
        this.exportPending = true;
        this.importDialogMode = 'export';
        this.importHint = '';
        this.exportPassword = '';
        this.backupPasswordDialog.open();
        return;
      }
      this.exportPasswordAsked = false;
      const password = this.exportPassword;
      const docPicker = new picker.DocumentViewPicker(getContext(this) as Context);
      const opts = new picker.DocumentSaveOptions();
      opts.newFileNames = [BackupRestoreService.defaultFileName()];
      opts.fileSuffixChoices = ['JSON 备份|.json'];
      const uris = await docPicker.save(opts);
      if (uris.length === 0) {
        return;
      }
      let json = await BackupRestoreService.exportJsonWithSettings(this.settings);
      if (password.length >= 4) {
        const enc = BackupCrypto.encrypt(json, password);
        if (!enc.ok) {
          promptAction.showToast({ message: enc.message });
          return;
        }
        json = enc.text;
      }
      const f = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(f.fd, json);
      } finally {
        fs.closeSync(f);
      }
      const slash = uris[0].lastIndexOf('/');
      const savedName = slash >= 0 ? uris[0].substring(slash + 1) : '备份文件';
      this.backupToast = '✓ 备份文件已成功导出！';
      promptAction.showToast({ message: `备份已导出：${savedName}` });
      AppLogger.info(TAG, `backup exported: ${uris[0]}`);
    } catch (e) {
      this.backupToast = '';
      promptAction.showToast({ message: '导出备份失败，请重试' });
      AppLogger.error(TAG, `backup export failed: ${AppLogger.errText(e)}`);
    }
  }

  /** Nexus §9 导入：系统文件选择器挑 .json → 校验恢复 */
  private async importBackup(): Promise<void> {
    try {
      const docPicker = new picker.DocumentViewPicker(getContext(this) as Context);
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      opts.fileSuffixFilters = ['.json'];
      const uris = await docPicker.select(opts);
      if (uris.length === 0) {
        return;
      }
      const uri = uris[0];
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      let text = '';
      try {
        const stat = fs.statSync(file.fd);
        if (stat.size <= 0 || stat.size > 4 * 1024 * 1024) {
          promptAction.showToast({ message: '文件大小需在 4MB 以内' });
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
        text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, readLen));
      } finally {
        fs.closeSync(file);
      }
      // 加密备份探测与解密：TunBox-Encrypted 信封 → 密码弹窗（decryptImportedBackup 内可重试 3 次）
      if (BackupCrypto.isEncrypted(text)) {
        this.importAttempt = 0;
        this.openImportPasswordDialog(text, '');
        return;
      }
      const outcome = await BackupRestoreService.importJsonText(text);
      this.applyImportOutcome(outcome);
    } catch (e) {
      AppLogger.warn(TAG, `backup import failed: ${AppLogger.errText(e)}`);
      promptAction.showToast({ message: '导入失败，请重试' });
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
        // ── 1. 顶部导航（文档 §2.1，无返回）：rightSlot 承载既有「备份 / 主题切换」入口 ──
        TopNavBar({ title: 'TunBox' }) {
          Row({ space: 8 }) {
            Row() {
              Text('备份')
                .fontSize(12)
                .fontWeight(FontWeight.Bold)
                .fontColor(TunBoxColors.textPrimary)
            }
            .padding({ left: 11, right: 11, top: 5, bottom: 5 })
            .borderRadius(TunBoxGeometry.pillRadius)
            .backgroundColor(TunBoxColors.chipBg)
            .border({ width: 1, color: TunBoxColors.cardBorder })
            .accessibilityText('打开配置备份与恢复')
            .onClick(() => {
              this.backupToast = '';
              this.backupDialog.open();
            })
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
            // 首页下方（模式按钮 / 速率卡 / 连接卡）因此整体上提，连接卡不再被
            // 底部 Dock 遮挡。
            Column() {
              CelestialPowerOrb({
                isConnected: $isConnected,
                isConnecting: this.isConnecting || this.pendingStart,
                nodeName: this.currentNodeName,
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

            // ── 3. 实时速率与流量卡片（文档 §3.1 第 4 节）──
            Column({ space: 12 }) {
              // 2026-10-19：公网 IP 已移到下方「连接」卡片的中线位置（用户要求），
              // 本卡恢复两列：左「实时速率」+ 右「流量消耗 / 连接时长」。
              // 防溢出：两列等权 layoutWeight(1)，任何列都不能靠内容撑大自己；
              // 每个 Text 再叠 maxLines(1)+省略号，窄屏下只会截断、绝不越界。
              Row() {
                // ── 左 1/2：实时速率 ──
                Column({ space: 4 }) {
                  Text('实时速率')
                    .fontSize(12)
                    .fontColor(TunBoxColors.textMuted)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Row() {
                    Text(this.realtimeRateParts()[0])
                      .fontSize(26)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(TunBoxColors.textPrimary)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(` ${this.realtimeRateParts()[1]}`)
                      .fontSize(13)
                      .fontColor(TunBoxColors.textSecondary)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Bottom)
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                // ── 右 1/2：流量消耗 + 连接时长（子项等权，可压缩）──
                Row({ space: 8 }) {
                  Column({ space: 4 }) {
                    Text('流量消耗')
                      .fontSize(12)
                      .fontColor(TunBoxColors.textMuted)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.formatTotalMB())
                      .fontSize(14)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(TunBoxColors.textPrimary)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.End)
                  Column({ space: 4 }) {
                    Text('连接时长')
                      .fontSize(12)
                      .fontColor(TunBoxColors.textMuted)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.formatDuration())
                      .fontSize(14)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(TunBoxColors.textPrimary)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.End)
                }
                .layoutWeight(1)
                .alignItems(VerticalAlign.Top)
              }.width('100%').alignItems(VerticalAlign.Top)

              // 速率曲线容器（48 高，2026-10-17 用户要求去掉凹槽框，曲线直接坐在卡片上）
              Stack({ alignContent: Alignment.BottomStart }) {
                RateChart({ points: this.ratePoints, isConnected: this.isConnected })
                Text(`↓ ${this.formatSpeedValue(this.upSpeed)}`)
                  .fontSize(11)
                  .fontColor(TunBoxColors.textSecondary)
                  .margin({ left: 10, bottom: 6 })
                  // 防溢出：曲线区已 clip，这里再加单行+省略号约束
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .height(48)
              .clip(true)

            }
            .width('100%')
            .padding(TunBoxGeometry.cardPaddingLarge)
            .backgroundColor(TunBoxColors.surfaceCard)
            .borderRadius(TunBoxGeometry.cardRadius)
            .border({ width: 1, color: TunBoxColors.cardBorder })
            // 2026-10-19 用户硬性要求：卡片信息任何情况下都不得超出卡片边界。
            // 上面已用「等权列 + 省略号 + 自适应字号」保证不产生溢出；这里再加
            // clip 作为最后一道视觉保险，即使极端字号/系统字体放大也只会被卡片
            // 圆角裁掉，绝不会画到卡片外面。
            .clip(true)


            // ── 连接卡（2026-10-17 自速率卡下移为独立卡：可收起/展开显示连接信息）──
            Column({ space: 10 }) {
              // 2026-10-19 用户要求：公网 IP 放在连接卡**左侧**，紧跟「连接」之后
              // （既不是独立成行——那会撑高卡片把下面内容下移；也不是绝对居中）。
              //
              // 布局：连接 ●  |  公网 IP：x.x.x.x  |  ← 剩余空间  |  ›
              //   · IP 用 layoutWeight(1) 占据「连接」与箭头之间的全部剩余空间，
              //     左对齐紧随其后，不新增行 ⇒ 卡片高度不变。
              //   · maxLines(1)+省略号：IP 再长也只在自己的剩余宽度内截断，
              //     绝不会把右侧箭头挤出卡片。
              Row({ space: 8 }) {
                Text('连接')
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(TunBoxColors.textPrimary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Circle({ width: 6, height: 6 })
                  .fill(this.isConnecting ? TunBoxColors.primary
                    : (this.isConnected ? TunBoxColors.success : TunBoxColors.textMuted))
                if (this.isConnected) {
                  Text(this.publicIpRefreshing ? '公网 IP：获取中…'
                    : (this.publicIp.length > 0
                      ? `公网 IP：${this.publicIp}`
                      : (this.publicIpError.length > 0 ? this.publicIpError : '公网 IP：--')))
                    .fontSize(12)
                    .fontColor(this.publicIpRefreshing ? TunBoxColors.textMuted
                      : (this.publicIp.length > 0 ? TunBoxColors.textSecondary : TunBoxColors.danger))
                    .fontFamily('monospace')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .textAlign(TextAlign.Start)
                    .layoutWeight(1)
                    // 左侧留一点间距，与「●」分开
                    .margin({ left: 2 })
                    .onClick(() => {
                      if (!this.publicIpRefreshing) {
                        this.refreshPublicIp('user-retry');
                      }
                    })
                } else {
                  Blank()
                }
                Image($r('app.media.ic_arrow_right'))
                  .width(14).height(14)
                  .fillColor(TunBoxColors.textMuted)
                  .rotate({ angle: this.connCardOpen ? 90 : 0 })
                  .animation({ duration: 250, curve: Curve.EaseInOut })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .onClick(() => { this.toggleConnCard(); })

              if (this.connCardOpen) {
                Column({ space: 8 }) {
                  // 活跃连接前 5 条（要看全部走下方「连接管理」）
                  if (this.connPreview.length === 0) {
                    Text(this.isConnected
                      ? (this.connPreviewReachable ? '暂无活跃连接' : '内核无响应，稍后自动重试')
                      : '连接后显示活跃连接')
                      .fontSize(12)
                      .fontColor(TunBoxColors.textMuted)
                      .width('100%')
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  } else {
                    ForEach(this.connPreview, (item: ConnectionEntry) => {
                      Row({ space: 8 }) {
                        Text(item.port > 0 ? `${item.host}:${item.port}` : item.host)
                          .fontSize(12)
                          .fontColor(TunBoxColors.textPrimary)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .layoutWeight(1)
                        Text(item.outbound.length > 0 ? item.outbound
                          : (item.rule.length > 0 ? item.rule : item.network))
                          .fontSize(10)
                          .fontColor(TunBoxColors.textMuted)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          // 2026-10-19 防溢出：原为固定 constraintSize(maxWidth:130)，
                          // 不参与权重分配；改为 layoutWeight 让三列按可用宽度等分，
                          // 任何窄屏下都不会撑破卡片（内容超长由省略号截断）。
                          .layoutWeight(1)
                        Text(this.formatConnBytes(item.download + item.upload))
                          .fontSize(11)
                          .fontColor(TunBoxColors.textSecondary)
                          .fontFamily('monospace')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                      .width('100%')
                      .alignItems(VerticalAlign.Center)
                    }, (item: ConnectionEntry) => item.id)
                  }
                  Row() {
                    Blank()
                    Row({ space: 2 }) {
                      Text('连接管理')
                        .fontSize(12)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(TunBoxColors.primary)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Image($r('app.media.ic_arrow_right'))
                        .width(12).height(12)
                        .fillColor(TunBoxColors.primary)
                    }
                    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                    .borderRadius(TunBoxGeometry.pillRadius)
                    .backgroundColor(TunBoxColors.primaryLight)
                    .onClick(() => {
                      router.pushUrl({ url: 'pages/ConnectionsPage' });
                    })
                  }.width('100%')
                }
                .width('100%')
              }
            }
            .width('100%')
            .padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })
            // 同上：连接卡（含展开后的活跃连接列表）也做视觉裁剪兜底
            .clip(true)

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
