/**
 * 设置中心（2026-10-18 UI 精简：隐藏网络重连 / 故障切换 / 诊断三项高级选项）
 *
 * 职责：把第二阶段新增的设置项以分组形式呈现，读写均走既有服务：
 *   - 读取：SettingsService.load() → AppSettings（页面首次进入取持久化真实值）
 *   - 写入：SettingsService.save()（内部 fromJson(toJson()) 归一化，与 UI 夹取形成双重夹取）
 * 每项改动即时落盘并 showToast 反馈；返回主页后再次进入仍读回真实值（不丢状态）。
 *
 * 约束：本文件只调用既有服务的公开接口，不修改 Orchestrator/AppSettings/SettingsService。
 * 2026-10-17 用户要求：设置页不再暴露「重连退避上限」三档时间 —— 编排器固定用
 * 内置最优默认 8s（RECONNECT_MAX_MS），用户只需控制「自动重连」开关。
 *
 * 2026-10-18 用户要求：简化设置，不要让用户选择复杂的配置项
 * - 网络重连 → 默认开启，完全隐藏
 * - 故障切换 → 默认开启，完全隐藏（3 次失败即切换、60 秒冷却为最优值）
 * - 诊断自检 → 默认开启，完全隐藏（自动修复、最多 2 步）
 * 用户感知：无感保障连接质量，无需任何配置。
 */
import { router, promptAction } from '@kit.ArkUI';
import { RulesEditorSnapshot, RulesPageParams } from '../commons/models/RulesEditorSnapshot';
import { TabLifecycleBridge } from '../commons/utils/TabLifecycleBridge';
import { common } from '@kit.AbilityKit';
import { privacyManager } from '@kit.AppGalleryKit';
import { TunBoxColors, TunBoxGeometry } from '../theme/TunBoxTokens';
import { ThemeService, AppThemeMode } from '../theme/ThemeService';
import { TopNavBar } from '../components/TopNavBar';
import { AppInfo } from '../commons/utils/AppInfo';
import { SettingsService } from '../commons/services/SettingsService';
import { AppSettings, AutoSelectModes } from '../commons/models/AppSettings';
import { LatencyTestUrl } from '../commons/latency/LatencyProbe';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';
import { SubscriptionService } from '../commons/services/SubscriptionService';
import { GeoAssetStatus } from '../commons/services/ConnectionOrchestrator';
import { LocalSubConverter } from '../commons/services/LocalSubConverter';
// 订阅转换：URL 拉取 + 与订阅解析同一条转换实现（SubConverter = mihomo ConvertsV2Ray 移植）
import { SubscriptionFetchPolicy } from '../commons/services/SubscriptionFetchPolicy';
import { SubConverter } from '../commons/flclash/SubConverter';
import { ProfileConfigMerger } from '../commons/flclash/ProfileConfigMerger';
import { AppLogger } from '../commons/utils/AppLogger';
import { picker, fileIo as fs } from '@kit.CoreFileKit';

/**
 * 2026-10-17 用户要求：重连退避上限不再暴露三档时间选项 —— 固定为 8s
 * （与 Orchestrator 的 RECONNECT_MAX_MS 一致的最优默认值），用户只需
 * 开/关「自动重连」。退避上限的进程内记忆与设置 UI 一并移除。
 */
/** 内容列最大宽度（与原 UiTokens.pageMaxWidth 取值一致，平板/折叠屏防过宽） */

/** geo 资产下载源偏好选项（与 AppSettings.assetSource 白名单一致） */
const ASSET_SOURCE_OPTIONS: string[] = ['auto', 'jsdelivr', 'ghproxy', 'github'];
const ASSET_SOURCE_LABELS: Record<string, string> = {
  'auto': '默认',
  'jsdelivr': 'CDN',
  'ghproxy': '加速',
  'github': '官方'
};

function formatGeoSize(bytes: number): string {
  if (bytes <= 0) {
    return '-';
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(0)} KB`;
  }
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

@Component
export struct SettingsView {
  @StorageLink('theme_revision') themeRevision: number = 0;
  /** 宿主（底部页签 MainPage / 路由包装页 SettingsPage）「重新展示」通知桥（替代 onPageShow 语义） */
  shownBridge?: TabLifecycleBridge;
  /** 订阅转换弹窗（分享链接 → 本地 mihomo 订阅） */
  private subConvertDialog: CustomDialogController = new CustomDialogController({
    builder: SubConvertDialog({}),
    autoCancel: true
  });
  @State appRoutingSummary: string = '正在读取应用分流…';
  /** 广告拦截规则状态（原首页「规则模式」卡片迁入，语义与首页 rulesStatusText 一致） */
  @State adRulesSummary: string = '正在读取规则状态…';
  // ── 选点 ──
  @State autoSelectMode: string = AutoSelectModes.MANUAL;
  @State currentNodeName: string = '';
  @State switchReason: string = '';
  @State switchFrom: string = '';
  @State switchTo: string = '';
  // ── 数据与规则（geo 资产） ──
  @State geoAssets: GeoAssetStatus[] = [];
  @State assetSource: string = 'auto';
  @State geoUpdatingId: string = '';
  @State quotaNotifyEnabled: boolean = true;
  @State audioKeepAliveEnabled: boolean = false;
  // ── 网络（IPv6 双栈，产品默认开）──
  @State ipv6Enabled: boolean = true;
  /** 是否允许明文 HTTP 订阅（默认关闭；关闭时只接受 https） */
  @State allowInsecureSubscriptionHttp: boolean = false;
  /**
   * 深浅色主题（2026-10-20 新增）：直接镜像 ThemeService 在 AppStorage 里的 theme_mode，
   * 因此主页太阳按钮改了它也会同步（StorageLink 双向）。
   * SYSTEM = 跟随系统（默认）；LIGHT / DARK = 用户固定。
   */
  @StorageLink('theme_mode') themeMode: AppThemeMode = AppThemeMode.SYSTEM;
  // ── 测速地址 ──
  /** 输入框里的测速地址（未保存的编辑态） */
  @State testLatencyUrl: string = '';
  /** 合法性提示（空串 = 合法） */
  @State testUrlError: string = '';
  // ── 关于与隐私 ──
  @State privacyUrl: string = '';
  /** 顶栏标题（app.string.settings_title 的本地化取值；TopNavBar.title 为 string 型） */
  private settingsTitle: string = '';

  private settings: AppSettings = new AppSettings();
  private openingRules: boolean = false;
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private subs: SubscriptionService = SubscriptionService.instance();

  aboutToAppear(): void {
    // 顶栏标题：读取当前语言的本地化文案（与原 Text($r(...)) 呈现一致）
    try {
      this.settingsTitle = getContext(this).resourceManager.getStringSync($r('app.string.settings_title'));
    } catch (e) {
      this.settingsTitle = '设置';
    }
    if (this.shownBridge !== undefined) {
      this.shownBridge.setShowHandler((): void => { this.bootstrap(); });
    }
  }

  aboutToDisappear(): void {
    if (this.shownBridge !== undefined) {
      this.shownBridge.setShowHandler(null);
    }
  }

  private async bootstrap(): Promise<void> {
    const ctx = getContext(this) as Context;
    this.orchestrator.init(ctx);
    await SettingsService.init(ctx);
    await this.subs.init(ctx);
    this.settings = await SettingsService.load();
    this.refreshAppRoutingSummary();
    // 每次进入：从持久化读取真实值回填（缺字段/脏值由 AppSettings.fromJson 兜底）
    this.autoSelectMode = AutoSelectModes.normalize(this.settings.autoSelectMode);
    this.quotaNotifyEnabled = this.settings.quotaNotifyEnabled;
    this.audioKeepAliveEnabled = this.settings.audioKeepAliveEnabled;
    this.ipv6Enabled = this.settings.ipv6Enabled;
    this.allowInsecureSubscriptionHttp = this.settings.allowInsecureSubscriptionHttp;
    this.assetSource = this.settings.assetSource;
    this.testLatencyUrl = this.settings.testLatencyUrl;
    this.refreshGeoStatuses();
    this.refreshNodeAndSwitchInfo();
    this.refreshPrivacyLink();
  }

  private async openRulesPage(): Promise<void> {
    if (this.openingRules) { return; }
    this.openingRules = true;
    try {
      await SettingsService.init(getContext(this) as Context);
      const settings = await SettingsService.load();
      const params = new RulesPageParams();
      params.initialRules = RulesEditorSnapshot.fromSettings(settings);
      await router.pushUrl({ url: 'pages/RulesPage', params: params });
    } catch (e) {
      promptAction.showToast({ message: '读取规则设置失败，请重试' });
    } finally {
      this.openingRules = false;
    }
  }

  /** 查询华为应用市场托管的隐私声明链接（AppGallery Kit 隐私管理服务，官方要求应用内入口与弹窗内容一致） */
  private refreshPrivacyLink(): void {
    try {
      const info: privacyManager.AppPrivacyMgmtInfo = privacyManager.getAppPrivacyMgmtInfo();
      const links: privacyManager.AppPrivacyLink[] = info.privacyInfo;
      for (let i = 0; i < links.length; i++) {
        const url = links[i].url;
        if (typeof url === 'string' && url.length > 0) {
          this.privacyUrl = url;
          break;
        }
      }
    } catch (e) {
      // 未关联隐私托管（debug 包 / 未在 AGC 生成协议）时接口抛错：保持空值，点击时给出提示
    }
  }

  private openPrivacyPolicy(): void {
    if (this.privacyUrl.length === 0) {
      promptAction.showToast({ message: $r('app.string.settings_privacy_unavailable') });
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.openLink(this.privacyUrl)
      .catch(() => {
        promptAction.showToast({ message: $r('app.string.settings_privacy_unavailable') });
      });
  }

  /** 只展示当前模式对应的数量，切回本页时与保存结果同步。 */
  private refreshAppRoutingSummary(): void {
    let summary = '全部应用 · 不限应用（0 个筛选项）';
    if (this.settings.appRoutingMode === 'exclude') {
      summary = `绕过所选应用 · 已选 ${this.settings.excludedApps.length} 个`;
    } else if (this.settings.appRoutingMode === 'include') {
      summary = `仅所选应用 · 已选 ${this.settings.includedApps.length} 个`;
    }
    // 规则引擎与去广告是**两个独立开关**（2026-10-23 用户口径）：分开写，
    // 避免「去广告开、规则引擎关」被显示成「规则已关闭」。
    const engine = this.settings.rulesEnabled ? '规则引擎开' : '规则引擎关';
    const ad = this.settings.hyperAdRulesEnabled ? '去广告开' : '去广告关';
    this.adRulesSummary = `${engine} · ${ad}`;
    this.appRoutingSummary = this.settings.appRoutingNeedsReview
      ? summary + ' · 待确认，请进入检查' : summary;
  }

  private refreshNodeAndSwitchInfo(): void {
    const node = this.subs.findNode(this.settings.preferredNodeId);
    if (node !== null) {
      this.currentNodeName = node.name;
    } else {
      this.currentNodeName = this.subs.nodes.length > 0 ? this.subs.nodes[0].name : '';
    }
    this.switchReason = this.orchestrator.autoSwitchReason();
    this.switchFrom = this.orchestrator.lastFailoverFromName();
    this.switchTo = this.orchestrator.lastFailoverToName();
  }

  /** 订阅配额提醒开关 */
  private setQuotaNotify(v: boolean): void {
    this.quotaNotifyEnabled = v;
    this.settings.quotaNotifyEnabled = v;
    // 字段级写：只改这一个字段（整单覆盖会把别的写者刚写的值盖回旧值）
    SettingsService.patchSettings((s: AppSettings): void => {
      s.quotaNotifyEnabled = v;
    }).then((): void => {
      promptAction.showToast({ message: $r('app.string.settings_saved_toast') });
    }).catch((): void => {
      promptAction.showToast({ message: $r('app.string.settings_save_failed_toast') });
    });
  }

  private setAudioKeepAlive(v: boolean): void {
    const previous = this.audioKeepAliveEnabled;
    this.audioKeepAliveEnabled = v;
    SettingsService.patchSettings((s: AppSettings): void => {
      s.audioKeepAliveEnabled = v;
    }).then((): void => {
      this.audioKeepAliveEnabled = v;
      this.settings.audioKeepAliveEnabled = v;
      promptAction.showToast({ message: '已保存，重新连接后生效' });
    }).catch((): void => {
      this.audioKeepAliveEnabled = previous;
      promptAction.showToast({ message: $r('app.string.settings_save_failed_toast') });
    });
  }

  // ── 网络（IPv6 双栈）─────────────────────────────────────────────

  /**
   * 把转换出来的本地订阅链接交给订阅页导入。
   *
   * 复用 `tunbox://import` 的同一条通道（`import_request_url` + `import_request_seq` + @Watch），
   * 不另写一套导入逻辑：格式判定、去重、明文 http 闸门、失败提示仍由订阅页那一条链路负责。
   */
  /**
   * 是否允许明文 HTTP 订阅。只改写设置字段，不触发重连（只影响下一次拉订阅）。
   */
  private setAllowInsecureSubscriptionHttp(v: boolean): void {
    this.allowInsecureSubscriptionHttp = v;
    this.settings.allowInsecureSubscriptionHttp = v;
    // 字段级写：只改这一个字段（整单覆盖会把别的写者刚写的值盖回旧值）
    SettingsService.patchSettings((s: AppSettings): void => {
      s.allowInsecureSubscriptionHttp = v;
    }).catch((): void => {
      promptAction.showToast({ message: $r('app.string.settings_save_failed_toast') });
    });
  }

  /**
   * IPv6 双栈开关。
   *
   * 这个开关同时改两处，且两处必须一起改（否则 v6 会黑洞或被绕过）：
   *   ① 生成的 YAML：`ipv6:` / `dns.ipv6:`（enhanced-mode 为 redir-host，AAAA 走真实上游）；
   *   ② TUN：扩展进程读**同一份 YAML 的 ipv6 行**决定是否装 v6 地址与 ::/0。
   * 也就是说这里只负责把值写进设置，其余联动都是「一份配置、两处读同一真源」。
   *
   * DNS 不在这里：内核 DNS 恒接管（生成器恒写 enable/dns-hijack，扩展恒下发 sentinel），
   * 原来的「DNS 覆写」开关已于 2026-10-21 随产品定案删除。
   */
  private setIpv6Enabled(v: boolean): void {
    this.ipv6Enabled = v;
    this.settings.ipv6Enabled = v;
    // 字段级写：只改这一个字段（整单覆盖会把别的写者刚写的值盖回旧值）
    SettingsService.patchSettings((s: AppSettings): void => {
      s.ipv6Enabled = v;
    }).then((): void => {
      this.applyNetworkSwitch();
    }).catch((): void => {
      promptAction.showToast({ message: $r('app.string.settings_save_failed_toast') });
    });
  }


  /**
   * 深浅色主题：默认跟随系统（SYSTEM）。关掉「跟随系统」时固定为当前外观，
   * 之后由主页太阳按钮在浅色/深色之间切换（ThemeService.toggle）。
   * setMode 内部会 setColorMode + 刷新 AppStorage 的 theme_mode / theme_revision，
   * 全 App 立即重绘；不涉及隧道，所以不需要重连。
   */
  private setFollowSystemTheme(follow: boolean): void {
    const next: AppThemeMode = follow
      ? AppThemeMode.SYSTEM
      : (ThemeService.isDark() ? AppThemeMode.DARK : AppThemeMode.LIGHT);
    ThemeService.setMode(next).then((): void => {
      promptAction.showToast({
        message: follow ? '主题已跟随系统' : '已固定当前主题（主页太阳按钮可切换）'
      });
    }).catch((): void => {
      promptAction.showToast({ message: $r('app.string.settings_save_failed_toast') });
    });
  }

  /**
   * 两个开关都改变「TUN + 内核配置」，热更新改不了 —— 已连接时必须重建隧道。
   * restartIfConnected 内部会重新 `SettingsService.load()`，所以拿到的一定是刚落盘的新值；
   * 未连接时它直接返回 false，下次手动连接自然带上新配置。
   */
  private applyNetworkSwitch(): void {
    this.orchestrator.restartIfConnected('network-settings').then((restarted: boolean): void => {
      promptAction.showToast({
        message: restarted
          ? '已保存，隧道正在按新配置重连'
          : $r('app.string.settings_saved_toast')
      });
    }).catch((): void => {
      promptAction.showToast({ message: $r('app.string.settings_saved_toast') });
    });
  }

  // ── 数据与规则（geo 资产管理） ────────────────────────────────────

  private refreshGeoStatuses(): void {
    this.geoAssets = this.orchestrator.geoAssetStatuses();
  }

  private geoStatusText(asset: GeoAssetStatus): string {
    if (!asset.ready) {
      // 用户口径（2026-10-22）：Smart 选点模型不随连接后台补齐，必须用户手动更新；
      // GeoIP 仍会在连接成功后自动补齐。
      // （去广告规则集已随包内置，不再是本页的资产，见 2026-10-23 口径。）
      return asset.id === 'model' ? '未就绪（需要手动更新）' : '未就绪（连接后自动补齐）';
    }
    let age = '';
    if (asset.mtimeMs > 0) {
      const days = Math.floor((Date.now() - asset.mtimeMs) / 86400000);
      age = days <= 0 ? '今天更新' : `${days} 天前更新`;
    }
    return `就绪 · ${formatGeoSize(asset.sizeBytes)} · ${age}`;
  }

  /** 只有 Smart 模型允许删除（GeoIP/GeoSite 删了内核会起不来） */
  private canDeleteAsset(id: string): boolean {
    return id === 'model';
  }

  /**
   * 删除资产（目前只剩 Smart 选点模型）：删除后订阅页的「自动选择」入口会自动隐藏
   * （走 smart_model_seq 信号）。去广告规则集已随包内置，不再提供删除入口。
   */
  private async deleteAsset(id: string): Promise<void> {
    const err = this.orchestrator.deleteGeoAsset(id);
    if (err.length > 0) {
      promptAction.showToast({ message: err });
      return;
    }
    this.refreshGeoStatuses();
    promptAction.showToast({ message: '已删除选点模型，自动选择入口已隐藏' });
  }

  private async updateAsset(id: string): Promise<void> {
    if (this.geoUpdatingId.length > 0) {
      return;
    }
    this.geoUpdatingId = id;
    try {
      const err = await this.orchestrator.refreshGeoAsset(id, this.assetSource);
      promptAction.showToast({ message: err.length > 0 ? err : '更新完成' });
    } catch (e) {
      promptAction.showToast({ message: '更新失败，请重试' });
    } finally {
      this.geoUpdatingId = '';
      this.refreshGeoStatuses();
    }
  }

  private setAssetSource(source: string): void {
    if (this.assetSource === source) {
      return;
    }
    this.assetSource = source;
    this.settings.assetSource = source;
    // 字段级写：只改这一个字段
    SettingsService.patchSettings((s: AppSettings): void => {
      s.assetSource = source;
    }).then((): void => {
      promptAction.showToast({ message: $r('app.string.settings_saved_toast') });
    }).catch((): void => {
      promptAction.showToast({ message: $r('app.string.settings_save_failed_toast') });
    });
  }

  // ── 测速地址（前台批 / 后台批 / 生成器 smart 组共用同一真源）──

  /**
   * 测速地址的合法性校验（**判定表唯一真源在测速内核**：
   * `LatencyTestUrl.isValid` —— 同一套规则既管「能不能存」也管「怎么回落」，
   * 免得 UI 判一套、内核判另一套，审计 F12）。
   * @return 空串 = 合法；非空 = 提示文案（此时**不落盘**，绝不静默改写用户填的值）
   */
  private validateTestUrl(raw: string): string {
    const url: string = raw.trim();
    if (url.length === 0) {
      return '';
    }
    if (!LatencyTestUrl.isValid(url)) {
      return '格式无效：需以 http:// 或 https:// 开头，且不能含空格';
    }
    return '';
  }

  /** 保存测速地址（字段级写：只改这一个字段） */
  private async saveTestUrl(): Promise<void> {
    const raw: string = this.testLatencyUrl.trim();
    const problem: string = this.validateTestUrl(raw);
    this.testUrlError = problem;
    if (problem.length > 0) {
      // 非法值**不落盘**：宁可让用户看见报错，也不替他猜一个地址。
      promptAction.showToast({ message: problem });
      return;
    }
    // 留空 = 用默认地址（https）。用户自填的 http 原样保存（个别出口掐 TLS SNI，
    // http 才能测通 —— 真机 a3fe45d）。
    const value: string = raw.length === 0 ? LatencyTestUrl.DEFAULT_URL : raw;
    await SettingsService.patchSettings((s: AppSettings): void => {
      s.testLatencyUrl = value;
    });
    this.settings.testLatencyUrl = value;
    this.testLatencyUrl = value;
    promptAction.showToast({ message: '测速地址已保存' });
  }

  /** 恢复默认测速地址 */
  private async resetTestUrl(): Promise<void> {
    this.testLatencyUrl = LatencyTestUrl.DEFAULT_URL;
    this.testUrlError = '';
    await this.saveTestUrl();
  }

  // ── UI ────────────────────────────────────────────────────────────

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column().width('100%').height('100%')
        .linearGradient({ angle: 180, colors: [[TunBoxColors.bgGradientStart, 0.0], [TunBoxColors.bgGradientEnd, 1.0]] })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        // ── 顶栏（底部页签页：无返回）──
        TopNavBar({ title: this.settingsTitle })

        Scroll() {
          Column({ space: 14 }) {
            // ── 应用分流：进入统一页面，不在设置页维护第二份编辑状态 ──
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                Row() {
                  Image($r('app.media.ic_apps'))
                    .width(16).height(16).fillColor(TunBoxColors.primary)
                }
                .width(28).height(28).borderRadius(8)
                .backgroundColor(TunBoxColors.primaryLight)
                .justifyContent(FlexAlign.Center)
                Text('应用分流').fontSize(15).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
                Blank()
                Image($r('app.media.ic_arrow_right'))
                  .width(16).height(16).fillColor(TunBoxColors.textMuted)
              }.width('100%').alignItems(VerticalAlign.Center)
              Text(this.appRoutingSummary)
                .fontSize(12).fontColor(TunBoxColors.textSecondary).width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })
            .onClick(() => router.pushUrl({ url: 'pages/AppRoutingPage' }))

            // ── 网站分流策略：进入统一页面配置（2026-10-17 自首页「规则模式」卡片迁入）──
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                Row() {
                  Image($r('app.media.ic_swap'))
                    .width(16).height(16).fillColor(TunBoxColors.primary)
                }
                .width(28).height(28).borderRadius(8)
                .backgroundColor(TunBoxColors.primaryLight)
                .justifyContent(FlexAlign.Center)
                Text('网站分流策略').fontSize(15).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
                Blank()
                Image($r('app.media.ic_arrow_right'))
                  .width(16).height(16).fillColor(TunBoxColors.textMuted)
              }.width('100%').alignItems(VerticalAlign.Center)
              Text(`代理 ${this.settings.forceProxySites.length} · 直连 ${this.settings.forceDirectSites.length}`)
                .fontSize(12).fontColor(TunBoxColors.textSecondary).width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })
            .onClick(() => router.pushUrl({ url: 'pages/SiteRoutingPage' }))

            // ── 广告拦截规则：进入统一页面配置（2026-10-17 自首页「规则模式」卡片迁入）──
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                Row() {
                  Image($r('app.media.ic_shield'))
                    .width(16).height(16).fillColor(TunBoxColors.primary)
                }
                .width(28).height(28).borderRadius(8)
                .backgroundColor(TunBoxColors.primaryLight)
                .justifyContent(FlexAlign.Center)
                Text('路由与规则').fontSize(15).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
                Blank()
                Image($r('app.media.ic_arrow_right'))
                  .width(16).height(16).fillColor(TunBoxColors.textMuted)
              }.width('100%').alignItems(VerticalAlign.Center)
              Text(this.adRulesSummary)
                .fontSize(12).fontColor(TunBoxColors.textSecondary).width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })
            .onClick(() => { this.openRulesPage(); })

            // ── 外观与网络（2026-10-23 用户要求「更简洁」：三张卡合成一张）──
            // 主题跟随系统 / IPv6 双栈 / 测速地址，都是「一次性设定、平时不碰」的项目，
            // 合成一张卡后设置页少两次视觉跳档；每条之间用 Divider 分隔，说明各压到一行。
            Column({ space: 10 }) {
              this.SectionHeader($r('app.media.ic_globe'), $r('app.string.settings_appearance_network'))

              Row() {
                Text('主题跟随系统')
                  .fontSize(14).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.themeMode === AppThemeMode.SYSTEM })
                  .selectedColor(TunBoxColors.primary)
                  .onChange((v: boolean): void => this.setFollowSystemTheme(v))
              }.width('100%').alignItems(VerticalAlign.Center)
              Text('关闭后由主页太阳按钮手动切换深浅色。')
                .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')

              Divider().color(TunBoxColors.cardBorder)

              Row() {
                Text('IPv6 双栈')
                  .fontSize(14).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.ipv6Enabled })
                  .selectedColor(TunBoxColors.primary)
                  .onChange((v: boolean): void => this.setIpv6Enabled(v))
              }.width('100%').alignItems(VerticalAlign.Center)
              Text('IPv6 也走代理；关闭则纯 IPv4。改动会自动重连。')
                .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')

              Divider().color(TunBoxColors.cardBorder)

              Text('测速地址').fontSize(14).fontColor(TunBoxColors.textPrimary).width('100%')
              TextInput({ text: this.testLatencyUrl, placeholder: LatencyTestUrl.DEFAULT_URL })
                .height(40)
                .fontSize(13)
                .backgroundColor(TunBoxColors.surfaceSubtle)
                .borderRadius(10)
                .onChange((value: string): void => {
                  this.testLatencyUrl = value;
                  this.testUrlError = this.validateTestUrl(value);
                })
              if (this.testUrlError.length > 0) {
                Text(this.testUrlError)
                  .fontSize(11).fontColor(TunBoxColors.danger).width('100%')
              } else {
                Text('留空＝默认 HTTPS 地址；自填 http 会原样使用。')
                  .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
              }
              Row({ space: 8 }) {
                Text('保存')
                  .fontSize(13).fontWeight(FontWeight.Bold)
                  .fontColor(this.testUrlError.length > 0 ? TunBoxColors.textMuted : TunBoxColors.primary)
                  .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                  .borderRadius(12)
                  .backgroundColor(TunBoxColors.surfaceCard)
                  .border({ width: 1, color: TunBoxColors.cardBorder })
                  .onClick((): void => { this.saveTestUrl(); })
                Text('恢复默认')
                  .fontSize(13).fontWeight(FontWeight.Bold)
                  .fontColor(TunBoxColors.textSecondary)
                  .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                  .borderRadius(12)
                  .backgroundColor(TunBoxColors.surfaceCard)
                  .border({ width: 1, color: TunBoxColors.cardBorder })
                  .onClick((): void => { this.resetTestUrl(); })
              }.width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })

Column({ space: 12 }) {
              this.SectionHeader($r('app.media.ic_shield'), $r('app.string.settings_background_connection'))
              Row() {
                Text('音频保活（下次连接）')
                  .fontSize(14).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.audioKeepAliveEnabled })
                  .selectedColor(TunBoxColors.primary)
                  .onChange((v: boolean): void => this.setAudioKeepAlive(v))
              }.width('100%').alignItems(VerticalAlign.Center)
              Text('小音量播放 + 媒体卡片维持后台（会增加耗电）；连接期间每 30 秒自检一次。')
                .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })

            // ── 诊断（保留订阅配额提醒）──
            Column({ space: 12 }) {
              this.SectionHeader($r('app.media.ic_shield'), $r('app.string.settings_diagnostics_title'))
              Divider().color(TunBoxColors.cardBorder)
              Column({ space: 4 }) {
                Row() {
                  Text('订阅配额提醒')
                    .fontSize(14).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.quotaNotifyEnabled })
                    .selectedColor(TunBoxColors.primary)
                    .onChange((v: boolean): void => this.setQuotaNotify(v))
                }.width('100%').alignItems(VerticalAlign.Center)
                Text('剩余 <10% 或 3 天内到期时通知，每天最多一次。')
                  .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
              }.width('100%')
              Divider().color(TunBoxColors.cardBorder)
              Column({ space: 4 }) {
                Row() {
                  Text('允许明文 HTTP 订阅')
                    .fontSize(14).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.allowInsecureSubscriptionHttp })
                    .selectedColor(TunBoxColors.primary)
                    .onChange((v: boolean): void => this.setAllowInsecureSubscriptionHttp(v))
                }.width('100%').alignItems(VerticalAlign.Center)
                Text('默认关闭；明文 http 不加密、可被篡改，仅自建面板无证书时临时开启。')
                  .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
              }.width('100%')
              Divider().color(TunBoxColors.cardBorder)
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })

            // ── 订阅转换（2026-10-22 用户要求：非 Clash 订阅 → mihomo 订阅）──
            Column({ space: 8 }) {
              Row() {
                Column({ space: 3 }) {
                  Text('订阅转换').fontSize(14).fontWeight(FontWeight.Bold)
                    .fontColor(TunBoxColors.textPrimary).width('100%')
                  Text('分享链接转成 mihomo 配置，可保存到本地或一键导入订阅列表。')
                    .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Text('打开').fontSize(13).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.primary)
                  .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                  .borderRadius(12)
                  .backgroundColor(TunBoxColors.primaryLight)
                  .onClick(() => { this.subConvertDialog.open(); })
              }.width('100%').alignItems(VerticalAlign.Center)
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })

            // ── 数据与规则 ──
            Column({ space: 12 }) {
              this.SectionHeader($r('app.media.ic_doc'), $r('app.string.settings_geo_title'))
              ForEach(this.geoAssets, (asset: GeoAssetStatus) => {
                Row({ space: 10 }) {
                  Column({ space: 3 }) {
                    Row({ space: 6 }) {
                      Text(asset.label).fontSize(14).fontWeight(FontWeight.Bold)
                        .fontColor(TunBoxColors.textPrimary)
                      Circle({ width: 8, height: 8 })
                        .fill(asset.ready ? TunBoxColors.success : TunBoxColors.textMuted)
                    }.width('100%').alignItems(VerticalAlign.Center)
                    Text(`${asset.detail} · ${this.geoStatusText(asset)}`)
                      .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
                      .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  if (this.canDeleteAsset(asset.id)) {
                    Text('删除')
                      .fontSize(13)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(asset.ready ? TunBoxColors.danger : TunBoxColors.textMuted)
                      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                      .borderRadius(12)
                      .backgroundColor(TunBoxColors.surfaceCard)
                      .border({ width: 1, color: TunBoxColors.cardBorder })
                      .onClick(() => {
                        if (this.geoUpdatingId.length === 0) {
                          this.deleteAsset(asset.id);
                        }
                      })
                  }
                  Text(this.geoUpdatingId === asset.id ? '更新中…' : '更新')
                    .fontSize(13)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.geoUpdatingId === asset.id ? TunBoxColors.textMuted : TunBoxColors.primary)
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .borderRadius(12)
                    .backgroundColor(TunBoxColors.surfaceCard)
                    .border({ width: 1, color: TunBoxColors.cardBorder })
                    .onClick(() => {
                      if (this.geoUpdatingId.length === 0) {
                        this.updateAsset(asset.id);
                      }
                    })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                .padding(10)
                .borderRadius(14)
                .backgroundColor(TunBoxColors.surfaceSubtle)
              }, (asset: GeoAssetStatus) => `${asset.id}-${asset.ready}-${asset.sizeBytes}`)

              Column({ space: 8 }) {
                Text('下载源偏好')
                  .fontSize(14).fontColor(TunBoxColors.textPrimary).width('100%')
                Row({ space: 8 }) {
                  ForEach(ASSET_SOURCE_OPTIONS, (src: string) => {
                    Text(ASSET_SOURCE_LABELS[src] ?? src)
                      .fontSize(13)
                      .fontWeight(this.assetSource === src ? FontWeight.Bold : FontWeight.Normal)
                      .fontColor(this.assetSource === src ? TunBoxColors.primary : TunBoxColors.textSecondary)
                      .layoutWeight(1)
                      .textAlign(TextAlign.Center)
                      .padding({ top: 7, bottom: 7 })
                      .borderRadius(12)
                      .backgroundColor(this.assetSource === src ? TunBoxColors.primaryLight : TunBoxColors.surfaceSubtle)
                      .border({
                        width: 1,
                        color: this.assetSource === src ? TunBoxColors.primaryBorder : TunBoxColors.cardBorder
                      })
                      .onClick(() => this.setAssetSource(src))
                  }, (src: string) => src)
                }.width('100%')
                Text('默认按实测可达性排序；CDN=jsdelivr 优先，加速=gh-proxy 前缀优先，官方=GitHub 直链优先。偏好源失败仍自动回退其余源。')
                  .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
              }.width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })

            // ── 关于与隐私 ──
            Column({ space: 12 }) {
              this.SectionHeader($r('app.media.ic_globe'), $r('app.string.settings_about_title'))
              Row() {
                Text($r('app.string.settings_version_label'))
                  .fontSize(14).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
                Text(AppInfo.version())
                  .fontSize(13).fontColor(TunBoxColors.textSecondary)
              }.width('100%')
              Divider().color(TunBoxColors.cardBorder)
              Row() {
                Text($r('app.string.settings_privacy_policy_row'))
                  .fontSize(14).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
                Image($r('app.media.ic_arrow_right'))
                  .width(16).height(16).fillColor(TunBoxColors.textMuted)
              }.width('100%').alignItems(VerticalAlign.Center)
              .onClick(() => this.openPrivacyPolicy())
              Text($r('app.string.settings_privacy_policy_desc'))
                .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })

            // 页签页底部为悬浮 Dock 预留（契约：≥ TunBoxGeometry.dockClearance）
            Blank().height(TunBoxGeometry.dockClearance)
          }
          .width('100%')
          .padding({
            left: TunBoxGeometry.pagePadding, right: TunBoxGeometry.pagePadding, top: 8, bottom: 24
          })
        }.edgeEffect(EdgeEffect.Spring)
        .width('100%').layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%').height('100%')
    }
    .width('100%').height('100%')
  }

  @Builder
  SectionHeader(icon: Resource, title: Resource) {
    Row({ space: 8 }) {
      Image(icon).width(18).height(18).fillColor(TunBoxColors.primary)
      Text(title).fontSize(15).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
      Blank()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

}

/**
 * 路由兼容入口（2026-10-17 UI 重构）：设置页内容已抽为 SettingsView，
 * 底部页签（MainPage）直接挂 SettingsView；外部深链仍走本 @Entry 页。
 */

/**
 * 订阅转换弹窗（2026-10-22 用户要求：**转换结果直接导出 YAML 文件**）。
 *
 * 只做两件事：① 把粘贴进来的分享链接（单条 / 多行 / 整体 base64）转成 mihomo YAML；
 * ② 转换成功后立刻弹系统文件选择器，让用户自己选保存位置（与「导出备份」同一套交互）。
 * 不再生成 `127.0.0.1` 的本地订阅链接 —— 用户要的是文件。
 */
@CustomDialog
struct SubConvertDialog {
  controller?: CustomDialogController;
  @State input: string = '';
  @State busy: boolean = false;
  /** 转换成功后的提示（节点数 / 保存位置） */
  @State summary: string = '';
  @State errorText: string = '';
  /** 最近一次转换结果（两个动作共用，避免重复请求订阅链接） */
  private pendingYaml: string = '';
  private pendingCount: number = 0;

  /**
   * 输入解析：既可以是**订阅链接**（http/https，拉下来再转），也可以是
   * **分享链接文本**（单条 / 多行 / 整体 base64）。返回可直接转换的正文。
   *
   * 走的是与「导入订阅」完全相同的拉取链路：UA 链、20s 超时、8MB 上限、
   * 明文 http 闸门（设置页开关），没有第二套网络实现。
   */
  private async resolveSource(): Promise<string> {
    const text = this.input.trim();
    // 用 startsWith 而不是正则字面量：正则里的 `//` 会让逐字符配平检查（以及部分
    // 语法高亮/静态检查）把后半行当成注释，出现过误报「括号不配平」。
    const lower = text.toLowerCase();
    const isHttpUrl = lower.startsWith('http://') || lower.startsWith('https://');
    if (!isHttpUrl) {
      return text;
    }
    const settings = await SettingsService.load();
    const insecureAllowed: boolean = settings.allowInsecureSubscriptionHttp;
    const fetched = await SubscriptionFetchPolicy.fetch(text, '', '', insecureAllowed, '');
    return fetched.body;
  }

  /** 文件名时间戳（本地时区，分钟精度：同一分钟内重复转换不覆盖上一个动作的语义） */
  private stampName(): string {
    const stat = new Date();
    return `${stat.getFullYear()}${String(stat.getMonth() + 1).padStart(2, '0')}`
      + `${String(stat.getDate()).padStart(2, '0')}-${String(stat.getHours()).padStart(2, '0')}`
      + `${String(stat.getMinutes()).padStart(2, '0')}`;
  }

  /**
   * 只做「解析 + 转换」，把结果放进 pendingYaml/pendingCount。
   *
   * 拆出来是为了「保存到本地」和「一键导入」共用同一份转换结果：
   * 订阅链接只需拉一次，用户先点导入不满意还能接着存文件。
   *
   * @returns 成功返回 true；失败/空内容返回 false（errorText 已写）
   */
  private async prepareConverted(): Promise<boolean> {
    try {
      const body = await this.resolveSource();
      if (body.trim().length === 0) {
        this.errorText = '没有拿到内容：请检查订阅链接是否可用，或直接粘贴分享链接';
        return false;
      }
      // 已经是 Clash 配置：原样保留（不重新序列化，字段一个不丢）
      if (ProfileConfigMerger.isKernelLoadableConfig(body)) {
        const merged = ProfileConfigMerger.merge('a: 1', body);
        this.pendingYaml = body;
        this.pendingCount = merged.profileProxyItems;
        return true;
      }
      // 非 Clash（base64 / 分享链接列表）→ 与订阅解析同一条转换实现
      const converted = SubConverter.convert(body);
      if (!converted.ok) {
        this.errorText = '无法识别内容：既不是 Clash 配置，也解析不出节点链接';
        return false;
      }
      this.pendingYaml = converted.proxiesYaml;
      this.pendingCount = converted.count;
      return true;
    } catch (e) {
      this.errorText = '转换失败，请重试';
      AppLogger.warn('SubConvertDialog', `convert failed: ${AppLogger.errText(e)}`);
      return false;
    }
  }

  /** 动作①：转换 → 系统文件选择器保存（用户取消就什么都不做） */
  private async saveToFile(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.errorText = '';
    this.summary = '';
    try {
      if (!(await this.prepareConverted())) {
        return;
      }
      const yaml = this.pendingYaml;
      const count = this.pendingCount;
      const docPicker = new picker.DocumentViewPicker(getContext(this) as Context);
      const opts = new picker.DocumentSaveOptions();
      opts.newFileNames = [`TunBox订阅-${this.stampName()}.yaml`];
      opts.fileSuffixChoices = ['YAML 文件|.yaml'];
      const uris = await docPicker.save(opts);
      if (uris.length === 0) {
        this.summary = '已取消保存';
        return;
      }
      const file = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, yaml);
      } finally {
        fs.closeSync(file);
      }
      const slash = uris[0].lastIndexOf('/');
      const savedName = slash >= 0 ? uris[0].substring(slash + 1) : 'YAML 文件';
      this.summary = `✓ 已保存 ${count} 个节点到 ${savedName}`;
      AppLogger.info('SubConvertDialog', `converted yaml saved: nodes=${count} uri=${uris[0]}`);
    } catch (e) {
      this.errorText = '保存失败，请重试';
      AppLogger.warn('SubConvertDialog', `save failed: ${AppLogger.errText(e)}`);
    } finally {
      this.busy = false;
    }
  }

  /**
   * 动作②：转换 → **一键导入 TunBox**（落成一条本地订阅，不用绕文件选择器）。
   *
   * 走的是与「+ → 文件」完全相同的入库链路（`SubscriptionService.addLocalYaml`）：
   * profile 原文落盘、凭据封存、规则/DNS 段落账、节点集变化通知 —— 一条都不少，
   * 只是省掉了「先存到文件、再去订阅页找文件」的两步。
   */
  private async importToTunBox(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.errorText = '';
    this.summary = '';
    try {
      if (!(await this.prepareConverted())) {
        return;
      }
      const service = SubscriptionService.instance();
      await service.init(getContext(this) as Context);
      const fileName = `TunBox转换-${this.stampName()}.yaml`;
      const count = await service.addLocalYaml(fileName, this.pendingYaml);
      if (count <= 0) {
        this.errorText = '转换出来的内容里没有可用节点（已过滤不支持的协议）';
        return;
      }
      this.summary = `✓ 已导入 ${count} 个节点，到「订阅」页即可看到「本地:${fileName.replace(/\.yaml$/, '')}」`;
      AppLogger.info('SubConvertDialog', `converted yaml imported: nodes=${count} file=${fileName}`);
    } catch (e) {
      const msg = AppLogger.errText(e);
      this.errorText = msg.indexOf('请提供 YAML') >= 0
        ? '转换结果不是可用的 Clash 配置，请检查内容' : '导入失败，请重试';
      AppLogger.warn('SubConvertDialog', `import failed: ${AppLogger.errText(e)}`);
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column({ space: 10 }) {
      Text('订阅转换').fontSize(16).fontWeight(FontWeight.Bold)
        .fontColor(TunBoxColors.textPrimary).width('100%')
      Text('粘贴订阅链接（非 Clash 的 v2ray/base64 订阅也可以），或直接粘贴分享链接（一行一条、整体 base64 都行）。'
        + '转完可以「保存到本地」留档，也可以「一键导入」直接进订阅列表（全程本地处理，不上传任何内容）。')
        .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
      TextArea({ placeholder: 'https://… 订阅链接，或 vless://… / ss://…（一行一条）、整段 base64', text: this.input })
        .onChange((v: string): void => { this.input = v; })
        .height(132).borderRadius(8).fontSize(12)
        .backgroundColor(TunBoxColors.surfaceSubtle)
        .borderWidth(1).borderColor(TunBoxColors.cardBorder)
        .fontColor(TunBoxColors.textPrimary)
      if (this.summary.length > 0) {
        Text(this.summary).fontSize(11).fontColor(TunBoxColors.success).width('100%')
      }
      if (this.errorText.length > 0) {
        Text(this.errorText).fontSize(11).fontColor(TunBoxColors.warning).width('100%')
      }
      Row({ space: 8 }) {
        Button('返回').layoutWeight(1).borderRadius(8)
          .backgroundColor(TunBoxColors.surfaceSubtle).fontColor(TunBoxColors.textPrimary).fontSize(13)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button(this.busy ? '处理中…' : '保存到本地').layoutWeight(1).borderRadius(8)
          .backgroundColor(TunBoxColors.surfaceSubtle).fontColor(TunBoxColors.primary).fontSize(13)
          .border({ width: 1, color: TunBoxColors.primaryBorder })
          .onClick(() => { this.saveToFile(); })
        Button(this.busy ? '处理中…' : '一键导入').layoutWeight(1).borderRadius(8)
          .backgroundColor(TunBoxColors.primary).fontColor(Color.White).fontSize(13)
          .onClick(() => { this.importToTunBox(); })
      }.width('100%').margin({ top: 2 })
    }
    .padding(20)
    .borderRadius(20)
  }
}

@Entry
@Component
struct SettingsPage {
  @StorageLink('theme_revision') themeRevision: number = 0;
  private bridge: TabLifecycleBridge = new TabLifecycleBridge();

  onPageShow(): void {
    this.bridge.notifyShown();
  }

  build() {
    // @Entry 的 build 根必须是容器组件，故用 Stack 承载页签内容视图
    Stack() {
      SettingsView({ shownBridge: this.bridge })
    }
    .width('100%')
    .height('100%')
  }
}
