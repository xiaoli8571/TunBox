/**
 * 应用入口 Ability
 * 移植自 upstream: TunBox_Android/lib/main.dart + app.dart + startup/*（启动编排的 ArkTS 等价）
 */
import { UIAbility, AbilityConstant, Want } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SettingsService } from '../commons/services/SettingsService';
import { SubscriptionService } from '../commons/services/SubscriptionService';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';
import { UiGuardian } from '../commons/services/UiGuardian';
import { BackgroundTaskWatch } from '../commons/services/BackgroundTaskWatch';
import { SubscriptionUpdateScheduler } from '../commons/services/SubscriptionUpdateScheduler';
import { GeoDataInstaller } from '../commons/services/GeoDataInstaller';
import { AppLogger } from '../commons/utils/AppLogger';
import { ThemeService } from '../theme/ThemeService';


const TAG = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  private pendingMode: string = '';
  private windowReady: boolean = false;
  /** 自愈编排单航班：冷启动与回前台都走它，避免重复拉起隧道 */
  private healTask: Promise<string> | null = null;

  /**
   * 按屏幕对角线英寸设置转场时长的规范下限（华为应用市场上架要求）：
   * < 8.5" → 200ms；8.5~12" → 250ms；> 12" → 300ms。
   * 实际时长由 TunBoxMotion.ms 取 max(260 设计基线, 该下限)。
   *
   * 英寸换算：vp = px / densityPixels；1 英寸 = 160vp（display 的 density 以 160 为基准）。
   */
  /**
   * 按屏幕对角线英寸设置转场时长的规范下限（AGC 审核意见 2026-10-23）：
   * < 8.5" → 200ms；8.5~12" → 250ms；> 12" → 300ms。
   * 实际时长由 TunBoxMotion.ms 取 max(260 设计基线, 该下限)。
   *
   * 英寸换算必须用**物理像素 + 真实 DPI**：
   *   inches = sqrt(widthPx² + heightPx²) / densityDPI
   * 旧实现用 densityPixels 把 px 折成 vp 再除 160，而 densityPixels 会被系统
   * 显示缩放（字体/显示大小/折叠屏比例）改写——12.6" 平板会被算成 9.4"，
   * 转场落在 250ms 档，低于 >12" 要求的 300ms，正是本次审核被点名的原因。
   */
  private applyMotionFloorByScreenSize(): void {
    try {
      const d = display.getDefaultDisplaySync();
      let inches: number;
      const dpi = d.densityDPI > 0 ? d.densityDPI : (d.xDPI > 0 ? d.xDPI : 0);
      let basis: string;
      if (dpi > 0) {
        inches = Math.sqrt(d.width * d.width + d.height * d.height) / dpi;
        basis = `${d.width}x${d.height}px @${dpi}dpi`;
      } else {
        // 极端兜底：DPI 拿不到时退回 vp/160（只用于老设备/模拟器）
        const density = d.densityPixels > 0 ? d.densityPixels : 3;
        const wVp = d.width / density;
        const hVp = d.height / density;
        inches = Math.sqrt(wVp * wVp + hVp * hVp) / 160;
        basis = `${wVp.toFixed(0)}x${hVp.toFixed(0)}vp(兜底)`;
      }
      let floor = 200;
      if (inches > 12) {
        floor = 300;
      } else if (inches >= 8.5) {
        floor = 250;
      }
      AppStorage.setOrCreate<number>('tb_motion_required_ms', floor);
      AppLogger.info(TAG, `screen ${basis} ≈ ${inches.toFixed(2)}in → motion floor ${floor}ms`);
    } catch (e) {
      // 拿不到 display 时保持设计基线（260ms），不阻断启动
      AppLogger.warn(TAG, `display probe failed: ${AppLogger.errText(e)}`);
    }
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppLogger.info(TAG, 'onCreate');
    this.applyMotionFloorByScreenSize();
    // geo 数据随包携带：内核启动前必须就位，否则会卡在联网下载 MMDB（20s 超时）
    GeoDataInstaller.ensure(this.context);
    // 长时任务取消监听（进程级幂等，API 15+）：用户删除任务通知 = 用户主动停止，
    // 需刷新记账并抑制自动重挂（《Background Tasks Kit 接入规范》红线）
    BackgroundTaskWatch.ensure();
    ThemeService.init(this.context).catch((e: BusinessError) => {
      AppLogger.error(TAG, `theme init failed: ${e.message}`);
    });
    SettingsService.init(this.context).catch((e: BusinessError) => {
      AppLogger.error(TAG, `settings init failed: ${e.message}`);
    });
    // 启动速度（2026-10-17）：订阅 hydrate（凭据迁移 + 节点回填，真机 ~1.1-1.5s）
    // 原本要等首页首帧后由 bootstrap 触发，现在提前到 onCreate —— 与页面 inflated
    // 并行推进，用户冷启后立刻点连接时，connect 的就绪等待窗口显著缩短。
    // init 进程内记忆化：bootstrap 稍后的调用直接复用同一 Promise，不会重跑。
    SubscriptionService.instance().init(this.context).catch((e: Object): void => {
      AppLogger.warn(TAG, `early subs init failed: ${AppLogger.errText(e)}`);
    });
    this.captureWant(want);
    this.captureDeepLink(want);
    this.captureImportScheme(want);
    // 订阅自动刷新（双轨触发之一）：注册 WorkScheduler 周期任务 + 冷启动兜底检查。
    // autoUpdateSubscription 开关此前无任何调度器消费，节点池会随机场更新逐渐失效。
    SubscriptionUpdateScheduler.instance().onAppStart(this.context);
    // 冷启动仅接管已存在的真实会话；证据不足时保留意图，不因打开应用拆建隧道。
    this.scheduleSelfHeal('cold-start');
  }

  /** 应用已在前台/后台存活时, 快捷方式与卡片点击走这里 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.captureWant(want);
    this.captureDeepLink(want);
    this.captureImportScheme(want);
  }

  /**
   * 任务栈复用或后台恢复时再次投递尚未消费的快捷意图，并补做一次自愈。
   *
   * 为什么每次回前台都要查：`dataTransfer` 长时任务只是"尽量别被杀"，被杀是常态。
   * 进程重启后进程内一切归零（state / 心跳 / UiGuardian.registered 都不可信），
   * 只有磁盘上的用户意图 + 跨进程心跳租约还在 —— 自愈判定正是基于这两者。
   */
  onForeground(): void {
    this.publishPendingWant();
    // 订阅自动刷新的前台兜底（双轨触发之二，5 分钟节流）：
    // WorkScheduler 实际触发时机受系统调度影响，回前台立刻补一次过期检查。
    SubscriptionUpdateScheduler.instance().onForeground(this.context);
    this.scheduleSelfHeal('foreground');
  }

  onBackground(): void {
    // 进后台时若隧道确实活着，补一次驻留凭证：UiGuardian.registered 是进程级静态
    // 布尔，进程重启后必然为 false，只有 HomePage 存在时才会被重新 engage ——
    // 卡片/快捷方式路径拉起的会话没有页面，这里兜住最后一环。
    this.reengageGuardian().catch((e: Error): void => {
      AppLogger.warn(TAG, `background guardian re-engage failed: ${e.message}`);
    });
  }

  private scheduleSelfHeal(trigger: string): void {
    if (this.healTask !== null) {
      return;
    }
    // 有明确的用户请求（桌面快捷方式 / 服务卡片）时不介入：
    // 那条路径自己会走 VpnQuickStart，语义是"切换"，自愈再并行拉一次连接
    // 只会和它抢 connectSeq，把一次点击变成两次互相打断的建连。
    if (this.pendingMode.length > 0) {
      AppLogger.info(TAG, `self-heal(${trigger}) skipped: explicit request "${this.pendingMode}" in flight`);
      return;
    }
    const task = ConnectionOrchestrator.instance()
      .restoreKilledSession(this.context)
      .then((reason: string): string => {
        AppLogger.info(TAG, `self-heal(${trigger}): ${reason}`);
        return reason;
      })
      .catch((e: Error): string => {
        AppLogger.warn(TAG, `self-heal(${trigger}) failed: ${e.message}`);
        return 'error';
      })
      .finally((): void => {
        if (this.healTask === task) {
          this.healTask = null;
        }
      });
    this.healTask = task;
  }

  /** 仅在"权威状态确实已连接"时补驻留凭证，避免断开后残留空耗电。 */
  private async reengageGuardian(): Promise<void> {
    if (UiGuardian.isRegistered()) {
      return;
    }
    const authority = await ConnectionOrchestrator.instance().authorityState();
    if (authority.connected) {
      await UiGuardian.engage(this.context, async (): Promise<boolean> => {
        const current = await ConnectionOrchestrator.instance().authorityState();
        return current.connected && current.desiredConnected;
      });
    }
  }

  /**
   * 外部启动请求统一入口（对应 AutoConnectRequestRegistry）：
   * - vpn_shortcut=start      桌面图标长按「启动代理」快捷方式 → 未连接则连接
   * - auto_connect=1          服务卡片"连接/断开" → 切换语义
   * 通过 AppStorage 递增 seq + mode 交给 HomePage 消费（前台 @Watch 即时响应,
   * 冷启动由 onPageShow 兜底消费）。
   */
  private captureWant(want: Want): void {
    let mode = '';
    if (want.parameters && want.parameters['vpn_shortcut'] === 'start') {
      mode = 'start';
    } else if (want.parameters && want.parameters['auto_connect'] === '1') {
      mode = 'toggle';
    }
    if (mode.length === 0) {
      return;
    }
    // 单槽保留最后一次有效请求。页面未挂载或 Ability 正在恢复时不丢失意图。
    this.pendingMode = mode;
    this.publishPendingWant();
  }

  /**
   * 卡片 targetPage 深链（P1-3b）：卡片 router 通道带 targetPage 参数时，
   * 折算成 MainPage 页签索引经 AppStorage 投递（@StorageLink 即时切换，无需重启页面）。
   * EntryAbility 是单页应用（loadContent('pages/MainPage')），targetPage 只能映射到页签。
   */
  private captureDeepLink(want: Want): void {
    if (!want.parameters) {
      return;
    }
    const target = want.parameters['targetPage'];
    if (typeof target !== 'string' || target.length === 0) {
      return;
    }
    let index = -1;
    if (target.endsWith('SubscriptionPage')) {
      index = 1;
    }
    if (index < 0) {
      return;
    }
    AppStorage.setOrCreate('deep_link_tab', index);
    const seq = (AppStorage.get<number>('deep_link_seq') ?? 0) + 1;
    AppStorage.setOrCreate('deep_link_seq', seq);
    AppLogger.info(TAG, `deep link queued: target=${target} index=${index} seq=${seq}`);
  }

  /**
   * tunbox://import scheme（P1-3c）：外部应用/浏览器以 tunbox://import?url=<encoded>
   * 拉起本应用时（module.json5 skills 已声明 ohos.want.action.viewData + scheme tunbox），
   * 解析 url 参数经 AppStorage 投递给 SubscriptionPage 导入（@Watch 即时消费，取后清空）。
   */
  private captureImportScheme(want: Want): void {
    const uri = want.uri;
    if (typeof uri !== 'string' || !uri.startsWith('tunbox://import')) {
      return;
    }
    const qIndex = uri.indexOf('?');
    if (qIndex < 0) {
      return;
    }
    const params = uri.substring(qIndex + 1).split('&');
    for (const p of params) {
      const eq = p.indexOf('=');
      if (eq < 0) {
        continue;
      }
      const key = p.substring(0, eq);
      if (key === 'url') {
        const value = decodeURIComponent(p.substring(eq + 1));
        if (value.length > 0) {
          AppStorage.setOrCreate('import_request_url', value);
          const seq = (AppStorage.get<number>('import_request_seq') ?? 0) + 1;
          AppStorage.setOrCreate('import_request_seq', seq);
          AppLogger.info(TAG, `tunbox import queued: seq=${seq}`);
        }
        return;
      }
    }
  }

  private publishPendingWant(): void {
    if (!this.windowReady || this.pendingMode.length === 0) {
      return;
    }
    const mode = this.pendingMode;
    this.pendingMode = '';
    AppStorage.setOrCreate('vpn_request_mode', mode);
    const seq = (AppStorage.get<number>('vpn_request_seq') ?? 0) + 1;
    AppStorage.setOrCreate('vpn_request_seq', seq);
    AppLogger.info(TAG, `vpn request queued: mode=${mode} seq=${seq}`);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    ThemeService.init(this.context).then(() => {
      windowStage.loadContent('pages/MainPage', (err) => {
        if (err.code) {
          hilog.error(0x0, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
          return;
        }
        this.windowReady = true;
        this.publishPendingWant();
        windowStage.getMainWindow((err2, win) => {
          if (!err2.code) {
            ThemeService.syncSystemBars(win).catch(() => {});
            AppStorage.setOrCreate('main_window', win);
          }
        });
      });
    }).catch((e: BusinessError) => {
      AppLogger.error(TAG, `theme restore failed: ${e.message}`);
      windowStage.loadContent('pages/MainPage', (err) => {
        if (!err.code) {
          this.windowReady = true;
          this.publishPendingWant();
        }
      });
    });
  }

  onDestroy(): void {
    AppLogger.info(TAG, 'onDestroy: UI ability released; preserve active VPN runtime artifacts');
    // UI Ability 被系统回收不代表用户主动停止 VPN。运行配置、Extension 状态和恢复工件
    // 由 VpnExtensionAbility 在确认会话终止后统一清理，避免破坏仍在后台运行的隧道及其恢复链。
  }
}
