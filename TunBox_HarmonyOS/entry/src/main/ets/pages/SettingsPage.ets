/**
 * 设置中心（2026-10-18 UI 精简：隐藏网络重连 / 故障切换 / 诊断三项高级选项）
 *
 * 职责：把第二阶段新增的设置项以分组形式呈现，读写均走既有服务：
 *   - 读取：SettingsService.load() → AppSettings（页面首次进入取持久化真实值）
 *   - 写入：SettingsService.patchSettings(mutator)（字段级写入：mutator 拿到刚从盘上读出的
 *     最新设置，只改本页拥有的字段；内部 fromJson(toJson()) 归一化，与 UI 夹取形成双重夹取）。
 *     ⚠ 不要再用 load() → 改字段 → save(整份)：两个写者各持一份内存副本时后写者会把
 *     先写者的字段整片盖回旧值（审计 F2，2026-10-27 全量迁移完毕）。
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
import { TunBoxTextColors } from '../theme/TextColors';
import { ThemeService, AppThemeMode, AppBgTheme, BgThemeColors } from '../theme/ThemeService';
import { TopNavBar } from '../components/TopNavBar';
import { AppInfo } from '../commons/utils/AppInfo';
import { SettingsService } from '../commons/services/SettingsService';
import { AppSettings, AutoSelectModes } from '../commons/models/AppSettings';
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

/** 浅色背景配色选项（顺序即设置页展示顺序；默认排最前） */
const BG_THEME_OPTIONS: AppBgTheme[] = [
  AppBgTheme.DEFAULT, AppBgTheme.MINT, AppBgTheme.HOMEBREW, AppBgTheme.NOCTIS
];

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
  // ── 网络（IPv6 双栈，产品默认开）──
  @State ipv6Enabled: boolean = true;
  /** DNS 覆写开关（默认开）：关闭时优先保留订阅中的 DNS 上游与策略 */
  @State dnsOverrideEnabled: boolean = true;
  /**
   * 深浅色主题（2026-10-20 新增）：直接镜像 ThemeService 在 AppStorage 里的 theme_mode，
   * 因此主页太阳按钮改了它也会同步（StorageLink 双向）。
   * SYSTEM = 跟随系统（默认）；LIGHT / DARK = 用户固定。
   */
  @StorageLink('theme_mode') themeMode: AppThemeMode = AppThemeMode.SYSTEM;
  /** 浅色背景配色（2026-10-28 用户要求）：StorageLink 镜像 ThemeService，改完立即全 App 重绘 */
  @StorageLink('bg_theme') bgTheme: AppBgTheme = AppBgTheme.DEFAULT;
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
    this.ipv6Enabled = this.settings.ipv6Enabled;
    this.dnsOverrideEnabled = this.settings.dnsOverrideEnabled !== false;
    this.assetSource = this.settings.assetSource;
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
    // 作用域化：跨订阅旧偏好不再当「当前节点」显示；name+id 双锚防止只留 name 时丢选中。
    const node = this.subs.resolveUserPreference(
      this.settings.preferredNodeId, this.settings.preferredNodeName);
    if (node !== null) {
      this.currentNodeName = node.name;
    } else {
      this.currentNodeName = this.subs.nodes.length > 0 ? this.subs.nodes[0].name : '';
    }
    this.switchReason = this.orchestrator.autoSwitchReason();
    this.switchFrom = this.orchestrator.lastFailoverFromName();
    this.switchTo = this.orchestrator.lastFailoverToName();
  }


  // ── 网络（IPv6 双栈）─────────────────────────────────────────────

  /**
   * 把转换出来的本地订阅链接交给订阅页导入。
   *
   * 复用 `tunbox://import` 的同一条通道（`import_request_url` + `import_request_seq` + @Watch），
   * 不另写一套导入逻辑：格式判定、去重、明文 http 闸门、失败提示仍由订阅页那一条链路负责。
   */
  /**
   * IPv6 双栈开关。
   *
   * 这个开关同时改两处，且两处必须一起改（否则 v6 会黑洞或被绕过）：
   *   ① 生成的 YAML：`ipv6:` / `dns.ipv6:`（enhanced-mode 为 redir-host，AAAA 走真实上游）；
   *   ② TUN：扩展进程读**同一份 YAML 的 ipv6 行**决定是否装 v6 地址与 ::/0。
   * 也就是说这里只负责把值写进设置，其余联动都是「一份配置、两处读同一真源」。
   *
   * DNS 不在这里：DNS 覆写由下方 setDnsOverrideEnabled 单独控制
   * （生成器写 `dns.enable` / `dns-hijack`，扩展读同一份 YAML 决定是否下发 dnsAddresses）。
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
   * DNS 覆写开关（默认开）。开启时使用应用生成的 DNS；关闭时优先保留订阅 DNS
   * 上游、策略与 fake-ip 设置，不强制关闭内核 DNS。
   *
   * 联动同样只有「一份真源」：写进设置 → 生成器按开关决定 DNS 配置来源，扩展读
   * **同一份 YAML** 的 dns.enable 决定是否下发 dnsAddresses。
   * 三处不可能各说各话（这正是 2026-10-21 之前那版开关最致命的坑：扩展自己存了一个
   * 默认 true 的状态位，YAML 读失败时设备 DNS 被指向没接管的内核 ⇒ 整机解析黑洞）。
   *
   * 关闭时 DNS 层 REJECT 预匹配也一并退场，站点拦截仍由路由层规则兜底。
   */
  private setDnsOverrideEnabled(v: boolean): void {
    this.dnsOverrideEnabled = v;
    this.settings.dnsOverrideEnabled = v;
    SettingsService.patchSettings((s: AppSettings): void => {
      s.dnsOverrideEnabled = v;
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

  /** Smart 选点模型状态文案（原「数据与规则」卡片里的 model 行，现并入「网络与数据」） */
  private smartModelStatusText(): string {
    for (let i = 0; i < this.geoAssets.length; i++) {
      if (this.geoAssets[i].id === 'model') {
        return this.geoStatusText(this.geoAssets[i]);
      }
    }
    return '未就绪（需要手动更新）';
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



  // ── UI ────────────────────────────────────────────────────────────

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column().width('100%').height('100%')
        .linearGradient({ angle: 180, colors: [[TunBoxColors.bgGradientStart(this.themeRevision), 0.0], [TunBoxColors.bgGradientEnd(this.themeRevision), 1.0]] })
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
                Text('应用分流').fontSize(15).fontWeight(FontWeight.Bold).fontColor(TunBoxTextColors.primary)
                Blank()
                Image($r('app.media.ic_arrow_right'))
                  .width(16).height(16).fillColor(TunBoxColors.textMuted)
              }.width('100%').alignItems(VerticalAlign.Center)
              Text(this.appRoutingSummary)
                .fontSize(12).fontColor(TunBoxTextColors.secondary).width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard(this.themeRevision))
            .border({ width: 1, color: TunBoxColors.cardBorder(this.themeRevision) })
            .onClick(() => router.pushUrl({ url: 'pages/AppRoutingPage' }))

            // ── 网站分流：进入统一页面配置（2026-10-17 自首页「规则模式」卡片迁入）──
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                Row() {
                  Image($r('app.media.ic_route'))
                    .width(16).height(16).fillColor(TunBoxColors.primary)
                }
                .width(28).height(28).borderRadius(8)
                .backgroundColor(TunBoxColors.primaryLight)
                .justifyContent(FlexAlign.Center)
                Text('网站分流').fontSize(15).fontWeight(FontWeight.Bold).fontColor(TunBoxTextColors.primary)
                Blank()
                Image($r('app.media.ic_arrow_right'))
                  .width(16).height(16).fillColor(TunBoxColors.textMuted)
              }.width('100%').alignItems(VerticalAlign.Center)
              Text(`代理 ${this.settings.forceProxySites.length} · 直连 ${this.settings.forceDirectSites.length}`)
                .fontSize(12).fontColor(TunBoxTextColors.secondary).width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard(this.themeRevision))
            .border({ width: 1, color: TunBoxColors.cardBorder(this.themeRevision) })
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
                Text('路由与规则').fontSize(15).fontWeight(FontWeight.Bold).fontColor(TunBoxTextColors.primary)
                Blank()
                Image($r('app.media.ic_arrow_right'))
                  .width(16).height(16).fillColor(TunBoxColors.textMuted)
              }.width('100%').alignItems(VerticalAlign.Center)
              Text(this.adRulesSummary)
                .fontSize(12).fontColor(TunBoxTextColors.secondary).width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard(this.themeRevision))
            .border({ width: 1, color: TunBoxColors.cardBorder(this.themeRevision) })
            .onClick(() => { this.openRulesPage(); })

            // ── 网络与数据（2026-10-28 用户口径：IPv6 / DNS 覆写 / Smart 选点模型
            //    统一收到这一个分类；GeoIP 区块整块删除，不再让用户维护 geo 资产）──
            Column({ space: 10 }) {
              this.SectionHeader($r('app.media.ic_settings'), '网络与数据')

              Row() {
                Text('IPv6 双栈')
                  .fontSize(14).fontColor(TunBoxTextColors.primary).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.ipv6Enabled })
                  .selectedColor(TunBoxColors.primary)
                  .onChange((v: boolean): void => this.setIpv6Enabled(v))
              }.width('100%').alignItems(VerticalAlign.Center)
              Text('IPv6 也走代理；关闭则纯 IPv4。改动会自动重连。')
                .fontSize(11).fontColor(TunBoxTextColors.muted).width('100%')

              Divider().color(TunBoxColors.cardBorder(this.themeRevision))

              Row() {
                Text('DNS 覆写')
                  .fontSize(14).fontColor(TunBoxTextColors.primary).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.dnsOverrideEnabled })
                  .selectedColor(TunBoxColors.primary)
                  .onChange((v: boolean): void => this.setDnsOverrideEnabled(v))
              }.width('100%').alignItems(VerticalAlign.Center)
              Text('开启后使用 TunBox 配置的加密上游（DoT）；关闭后优先保留订阅 DNS。改动会自动重连。')
                .fontSize(11).fontColor(TunBoxTextColors.muted).width('100%')

              Divider().color(TunBoxColors.cardBorder(this.themeRevision))

              Divider().color(TunBoxColors.cardBorder(this.themeRevision))

              // Smart 选点模型（原「数据与规则」里的 model 资产，2026-10-28 并入本分类）
              Row({ space: 8 }) {
                Column({ space: 2 }) {
                  Text('Smart 选点模型')
                    .fontSize(14).fontColor(TunBoxTextColors.primary)
                    .maxLines(1)
                  Text(this.smartModelStatusText())
                    .fontSize(11).fontColor(TunBoxTextColors.muted)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Text(this.geoUpdatingId === 'model' ? '更新中…' : '更新')
                  .fontSize(13).fontWeight(FontWeight.Medium)
                  .fontColor(this.geoUpdatingId === 'model' ? TunBoxTextColors.muted : TunBoxTextColors.accentBlue)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(10)
                  .backgroundColor(TunBoxColors.primaryLight)
                  .onClick((): void => {
                    if (this.geoUpdatingId.length === 0) {
                      this.updateAsset('model');
                    }
                  })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard(this.themeRevision))
            .border({ width: 1, color: TunBoxColors.cardBorder(this.themeRevision) })

            // ── 关于与隐私 ──
            Column({ space: 12 }) {
              this.SectionHeader($r('app.media.ic_globe'), $r('app.string.settings_about_title'))
              Row() {
                Text($r('app.string.settings_version_label'))
                  .fontSize(14).fontColor(TunBoxTextColors.primary).layoutWeight(1)
                Text(AppInfo.version())
                  .fontSize(13).fontColor(TunBoxTextColors.secondary)
              }.width('100%')
              Divider().color(TunBoxColors.cardBorder(this.themeRevision))
              // 2026-10-23 用户口径：主题跟随系统放在「版本」和「隐私政策」中间
              Row() {
                Text('主题跟随系统')
                  .fontSize(14).fontColor(TunBoxTextColors.primary).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.themeMode === AppThemeMode.SYSTEM })
                  .selectedColor(TunBoxColors.primary)
                  .onChange((v: boolean): void => this.setFollowSystemTheme(v))
              }.width('100%').alignItems(VerticalAlign.Center)
              Text('关闭后由主页太阳按钮手动切换深浅色。')
                .fontSize(11).fontColor(TunBoxTextColors.muted).width('100%')
              Divider().color(TunBoxColors.cardBorder(this.themeRevision))
              // 2026-10-28 用户要求：浅色模式下背景色可选 Mint / Homebrew / Noctis Hibernus
              // （深色只有一套夜间配色，故深色下这组选择器隐藏而不是置灰 —— 置灰会让人以为选不了是 bug）
              if (!this.isDarkNow()) {
                this.BgThemePicker()
                Divider().color(TunBoxColors.cardBorder(this.themeRevision))
              }
              // 2026-10-27：主页右上角「备份」迁到这里（关于与隐私卡内），功能不变。
              Row() {
                Text('配置备份与恢复')
                  .fontSize(14).fontColor(TunBoxTextColors.primary).layoutWeight(1)
                Image($r('app.media.ic_arrow_right'))
                  .width(16).height(16).fillColor(TunBoxColors.textMuted)
              }.width('100%').alignItems(VerticalAlign.Center)
              .onClick(() => {
                router.pushUrl({ url: 'pages/BackupPage' }).catch((): void => {
                  promptAction.showToast({ message: '打开备份页面失败，请重试' });
                });
              })
              Text('导出/导入订阅、节点与自定义规则；支持 AES-256 加密备份。')
                .fontSize(11).fontColor(TunBoxTextColors.muted).width('100%')
              Divider().color(TunBoxColors.cardBorder(this.themeRevision))
              Row() {
                Text($r('app.string.settings_privacy_policy_row'))
                  .fontSize(14).fontColor(TunBoxTextColors.primary).layoutWeight(1)
                Image($r('app.media.ic_arrow_right'))
                  .width(16).height(16).fillColor(TunBoxColors.textMuted)
              }.width('100%').alignItems(VerticalAlign.Center)
              .onClick(() => this.openPrivacyPolicy())
              Text($r('app.string.settings_privacy_policy_desc'))
                .fontSize(11).fontColor(TunBoxTextColors.muted).width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard(this.themeRevision))
            .border({ width: 1, color: TunBoxColors.cardBorder(this.themeRevision) })

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
  SectionHeader(icon: Resource, title: ResourceStr) {
    Row({ space: 8 }) {
      Image(icon).width(18).height(18).fillColor(TunBoxColors.primary)
      Text(title).fontSize(15).fontWeight(FontWeight.Bold).fontColor(TunBoxTextColors.primary)
      Blank()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /** 当前是否深色（每次读 ThemeService，跟着 theme_revision 重算） */
  private isDarkNow(): boolean {
    return ThemeService.isDark();
  }

  private bgThemeLabel(t: AppBgTheme): string {
    if (t === AppBgTheme.MINT) {
      return 'Mint';
    }
    if (t === AppBgTheme.HOMEBREW) {
      return 'Homebrew';
    }
    if (t === AppBgTheme.NOCTIS) {
      return 'Noctis';
    }
    return '默认';
  }

  private bgThemeSwatch(t: AppBgTheme): BgThemeColors {
    return ThemeService.previewBgColors(t);
  }

  /**
   * 背景配色选择器（2026-10-28 用户要求）。
   * 每个选项直接用该配色自己的渐变做预览块 —— 选之前就能看到结果，不靠名字猜。
   */
  @Builder
  BgThemePicker() {
    Column({ space: 10 }) {
      Row() {
        Text('浅色背景')
          .fontSize(14).fontColor(TunBoxTextColors.primary).layoutWeight(1)
        Text(this.bgThemeLabel(this.bgTheme))
          .fontSize(12).fontColor(TunBoxTextColors.secondary)
      }.width('100%').alignItems(VerticalAlign.Center)
      Row({ space: 10 }) {
        ForEach(BG_THEME_OPTIONS, (item: AppBgTheme) => {
          Column({ space: 6 }) {
            Row()
              .width('100%').height(44)
              .borderRadius(12)
              .linearGradient({
                angle: 160,
                colors: [[this.bgThemeSwatch(item).start, 0.0], [this.bgThemeSwatch(item).end, 1.0]]
              })
              .border({
                width: this.bgTheme === item ? 2 : 1,
                color: this.bgTheme === item ? TunBoxColors.primary : TunBoxColors.cardBorder(this.themeRevision)
              })
            Text(this.bgThemeLabel(item))
              .fontSize(11)
              .fontColor(this.bgTheme === item ? TunBoxTextColors.accentBlue : TunBoxTextColors.secondary)
              .fontWeight(this.bgTheme === item ? FontWeight.Medium : FontWeight.Regular)
          }
          .layoutWeight(1)
          .onClick((): void => {
            if (this.bgTheme === item) {
              return;
            }
            ThemeService.setBgTheme(item).then((): void => {
              promptAction.showToast({ message: `背景已切换为 ${this.bgThemeLabel(item)}` });
            }).catch((): void => {
              promptAction.showToast({ message: $r('app.string.settings_save_failed_toast') });
            });
          })
        }, (item: AppBgTheme) => item)
      }.width('100%')
      Text('只影响浅色模式：页面背景、卡片与输入框会一起换成同色系；文字与品牌色不变。深色模式固定一套夜间配色。')
        .fontSize(11).fontColor(TunBoxTextColors.muted).width('100%')
    }
    .width('100%')
  }

}

/**
 * 路由兼容入口（2026-10-17 UI 重构）：设置页内容已抽为 SettingsView，
 * 底部页签（MainPage）直接挂 SettingsView；外部深链仍走本 @Entry 页。
 */

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
