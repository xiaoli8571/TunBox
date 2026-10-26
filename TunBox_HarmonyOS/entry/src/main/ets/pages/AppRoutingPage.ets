import { router, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { Ui } from '../theme/UiTokens';
import { TunBoxColors, TunBoxGeometry, TunBoxMotion } from '../theme/TunBoxTokens';
import { TopNavBar } from '../components/TopNavBar';
import { AppSettings } from '../commons/models/AppSettings';
import { AppRoutingCustomApp, AppRoutingEntry, AppRoutingPolicy } from '../commons/services/AppRoutingPolicy';
import { SettingsService } from '../commons/services/SettingsService';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';

class RoutingRow {
  bundleName: string = '';
  label: string = '';
  source: string = '';
  selected: boolean = false;
}

@CustomDialog
struct RoutingInputDialog {
  controller?: CustomDialogController;
  @State label: string = '';
  @State packages: string = '';
  onAdd: (packages: string, label: string) => boolean = () => false;

  /** 实时解析：一行「名称|包名」也算一条；只填包名时用名称备注兜底。 */
  private entries(): AppRoutingEntry[] {
    return AppRoutingPolicy.parseEntries(this.packages, this.label);
  }

  private errorText(): string {
    if (this.packages.trim().length === 0) { return ''; }
    return AppRoutingPolicy.entriesError(this.entries());
  }

  private canAdd(): boolean {
    return this.errorText().length === 0 && this.entries().length > 0;
  }

  private previewText(): string {
    const entries = this.entries();
    const parts: string[] = [];
    for (const entry of entries) {
      parts.push((entry.label.length > 0 ? entry.label + ' · ' : '') + entry.bundleName);
    }
    return `已识别 ${entries.length} 项：` + parts.join('；');
  }

  build() {
    Column({ space: 12 }) {
      Text('添加 / 批量导入').fontSize(19).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
      Text('每行一条，支持「名称|包名」，例如 支付宝|com.alipay.mobile.client；也可以只填鸿蒙包名。请勿使用 Android 包名代替鸿蒙包名。')
        .fontSize(12).fontColor(Ui.textSecondary)
      TextInput({ text: this.label, placeholder: '名称备注（可选，只用于单条输入）' }).maxLength(40)
        .onChange((v: string) => { this.label = v; }).backgroundColor(Ui.inputBackground).fontColor(Ui.textPrimary)
      TextArea({ text: this.packages, placeholder: '支付宝|com.alipay.mobile.client' })
        .height(170).maxLength(65536).fontColor(Ui.textPrimary).backgroundColor(Ui.inputBackground)
        .onChange((v: string) => { this.packages = v; })
      // 输入即识别：合法包名全部解析成功时按钮立刻变实心蓝并可点，不合法的行就地标红。
      if (this.packages.trim().length > 0) {
        Text(this.errorText().length > 0 ? this.errorText() : this.previewText())
          .fontSize(11)
          .fontColor(this.errorText().length > 0 ? TunBoxColors.danger : TunBoxColors.textSecondary)
          .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }
      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).backgroundColor(Ui.surfaceStrong).fontColor(Ui.textPrimary)
          .onClick(() => this.controller?.close())
        Button('添加到当前名单').layoutWeight(2)
          .backgroundColor(this.canAdd() ? TunBoxColors.primary : Ui.buttonDisabled)
          .fontColor(this.canAdd() ? TunBoxColors.textOnPrimary : TunBoxColors.textSecondary)
          .enabled(this.canAdd())
          .onClick(() => { if (this.onAdd(this.packages, this.label)) { this.controller?.close(); } })
      }
    }
    // 沉浸光感适配（官方《组件适配沉浸光感》+《沉浸光感常见问题》）：应用级 enable
    // 后 CustomDialog 默认 ULTRA_THICK 沉浸材质背板；材质层级位于背景色/背景模糊之下，
    // 不透明背景色、背景模糊（COMPONENT_THICK）、backgroundEffect 与自定义 shadow
    // 都会遮挡材质（官方反模式），根容器不再设置，视觉交给系统材质统一接管；
    // 内容层（说明卡/列表行/输入框/按钮）样式保持不动。
    .padding(22).borderRadius(24)
  }
}

/** 预置鸿蒙常用应用（用户 2026-10-14 提供）。2026-10-18 起用户可删除：
 *  删除记录在 AppSettings.appRoutingRemovedPresets，rebuild() 据此跳过。 */
class PresetApp {
  bundleName: string = '';
  label: string = '';
  constructor(bundleName: string, label: string) {
    this.bundleName = bundleName;
    this.label = label;
  }
}

const PRESET_APPS: PresetApp[] = [
  new PresetApp('com.tencent.wechat', '微信'),
  new PresetApp('com.ss.hm.ugc.aweme', '抖音'),
  new PresetApp('com.alipay.mobile.client', '支付宝'),
  new PresetApp('com.amap.hmapp', '高德地图'),
  new PresetApp('com.cmbchina.harmony', '招商银行'),
  new PresetApp('com.taobao.taobao4hmos', '淘宝'),
  new PresetApp('com.taobao.idlefish4ohos', '闲鱼'),
  new PresetApp('com.sina.weibo.stage', '微博'),
  new PresetApp('app.huawei.hmos.motor', '鸿蒙智行'),
  new PresetApp('com.sankuai.hmeituan', '美团'),
  new PresetApp('com.jd.hm.mall', '京东'),
  new PresetApp('com.sdu.didi.hmos.psnger', '滴滴出行'),
];

/** 应用接管范围：先编辑草稿，统一保存；不将目录伪装为已安装列表。 */
@Entry
@Component
struct AppRoutingPage {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @State mode: string = 'all';
  @State included: string[] = [];
  @State excluded: string[] = [];
  @State customApps: AppRoutingCustomApp[] = [];
  /** 用户已删除的预置包名（持久化；rebuild 据此隐藏预置行） */
  @State removedPresets: string[] = [];
  @State needsReview: boolean = false;
  @State query: string = '';
  @State selectedOnly: boolean = false;
  @State nameSort: boolean = false;
  @State rows: RoutingRow[] = [];
  @State busy: boolean = true;
  @State ready: boolean = false;
  @State dirty: boolean = false;
  @State resultText: string = '';
  /** 批量删除：先勾选草稿，统一确认后移除；保存前不改当前 VPN。 */
  @State batchMode: boolean = false;
  @State pendingDeletes: string[] = [];
  private original: string = '';
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private inputDialog: CustomDialogController = new CustomDialogController({
    builder: RoutingInputDialog({ onAdd: (text: string, label: string): boolean => this.addPackages(text, label) }),
    autoCancel: false
  });

  // 入场转场期间不抢 UI 线程：读配置延到转场之后（2026-10-17 用户反馈进入页面卡顿）
  aboutToAppear(): void { setTimeout((): void => { this.load(); }, 240); }

  private async load(): Promise<void> {
    try {
      const context = getContext(this) as Context;
      this.orchestrator.init(context);
      await SettingsService.init(context);
      const settings = await SettingsService.load();
      this.mode = settings.appRoutingMode;
      this.included = settings.includedApps.slice();
      this.excluded = settings.excludedApps.slice();
      this.customApps = settings.appRoutingCustomApps.slice();
      this.removedPresets = settings.appRoutingRemovedPresets.slice();
      this.needsReview = settings.appRoutingNeedsReview;
      this.original = this.fingerprint();
      this.ready = true;
      this.rebuild();
    } catch (e) {
      this.resultText = '读取配置失败，请返回后重试；未更改任何设置。';
    } finally { this.busy = false; }
  }

  private fingerprint(): string {
    return JSON.stringify([this.mode, this.included, this.excluded,
      this.customApps, this.removedPresets, this.needsReview]);
  }

  private current(): string[] { return this.mode === 'include' ? this.included : this.excluded; }

  private setCurrent(packages: string[]): void {
    if (this.mode === 'include') { this.included = packages; } else { this.excluded = packages; }
    this.rebuild();
  }

  private addRow(rows: RoutingRow[], name: string, label: string, source: string): void {
    if (rows.some((r: RoutingRow) => r.bundleName === name)) { return; }
    const row = new RoutingRow();
    row.bundleName = name;
    row.label = label.length > 0 ? label : name;
    row.source = source;
    row.selected = this.mode !== 'all' && this.current().includes(name);
    rows.push(row);
  }

  private rebuild(): void {
    const rows: RoutingRow[] = [];
    // 预置鸿蒙常用应用包名（用户 2026-10-14 提供）：默认全部不勾选，
    // 用户按需勾选（selected 仅在已存名单中才置位，见 addRow）。
    // 2026-10-18 用户要求：**自带包名也必须能删** —— 这里跳过用户已删除的那些
    // （removedPresets 已持久化），否则删掉后 rebuild() 又把它们加回来。
    for (const preset of PRESET_APPS) {
      if (this.removedPresets.includes(preset.bundleName)) { continue; }
      this.addRow(rows, preset.bundleName, preset.label, '预置 · 常用应用');
    }
    for (const app of this.customApps) { this.addRow(rows, app.bundleName, app.label, '手动添加 · 安装状态未确认'); }
    for (const name of this.included.concat(this.excluded)) { this.addRow(rows, name, '', '已有名单 · 安装状态未确认'); }
    const keyword = this.query.trim().toLowerCase();
    // 顺序必须稳定（仅按名称）：此前"已选排前面"会让每次勾选都整列跳动，
    // ForEach 复用 Checkbox 时视觉/事件错位（第一次点落在错位的行上）。
    // 找已选的用顶栏「已选择」过滤器，不靠排序。
    this.rows = rows.filter((r: RoutingRow) => (!this.selectedOnly || r.selected)
      && (r.label.toLowerCase().includes(keyword) || r.bundleName.toLowerCase().includes(keyword)))
      .sort((a: RoutingRow, b: RoutingRow) => a.label.localeCompare(b.label));
    // 批量删除的勾选只保留仍存在的条目（搜索过滤不清空勾选，删除后不留幽灵计数）
    this.pendingDeletes = this.pendingDeletes.filter((name: string) => rows.some((r: RoutingRow) => r.bundleName === name));
    this.dirty = this.fingerprint() !== this.original;
  }

  private selectMode(mode: string): void {
    this.mode = mode;
    this.needsReview = false;
    this.selectedOnly = false;
    this.resultText = '';
    this.rebuild();
  }

  private toggle(name: string): void {
    if (this.mode === 'all' || this.busy) { return; }
    const current = this.current();
    const next = current.includes(name) ? current.filter((p: string) => p !== name) : current.concat([name]);
    if (next.length > 256 && next.length > current.length) { this.toast('每份名单最多 256 个应用'); return; }
    this.setCurrent(next);
  }

  private selectVisible(select: boolean): void {
    const names = this.rows.map((r: RoutingRow) => r.bundleName);
    const next = select ? AppRoutingPolicy.normalizePackages(this.current().concat(names))
      : this.current().filter((name: string) => !names.includes(name));
    if (next.length > 256 && next.length > this.current().length) { this.toast('当前结果超出 256 个上限，请缩小搜索范围'); return; }
    this.setCurrent(next);
  }

  private addPackages(text: string, label: string): boolean {
    // 每行支持「名称|包名」「包名|名称」与纯包名；名称逐条进手动目录用于显示。
    const entries = AppRoutingPolicy.parseEntries(text, label);
    const error = AppRoutingPolicy.entriesError(entries);
    if (error.length > 0) { this.toast(error); return false; }
    const packages = AppRoutingPolicy.normalizePackages(entries.map((entry: AppRoutingEntry) => entry.bundleName));
    const next = AppRoutingPolicy.normalizePackages(this.current().concat(packages));
    const validationError = AppRoutingPolicy.validationError(this.mode,
      this.mode === 'include' ? next : this.included,
      this.mode === 'exclude' ? next : this.excluded, this.needsReview);
    if (validationError.length > 0) { this.toast(validationError); return false; }
    const apps = this.customApps.slice();
    for (const entry of entries) {
      const name = entry.bundleName.trim();
      if (!apps.some((app: AppRoutingCustomApp) => app.bundleName === name)) {
        const app = new AppRoutingCustomApp();
        app.bundleName = name;
        app.label = entry.label.trim();
        apps.push(app);
      }
    }
    if (apps.length > 512) { this.toast('手动目录最多 512 项，请先整理已有条目'); return false; }
    this.customApps = apps;
    this.setCurrent(next);
    this.toast(`已添加到草稿：${packages.length} 项，保存后生效`);
    return true;
  }

  /** 进入/退出批量删除：进入时清空上一轮勾选，退出不改变草稿。 */
  private toggleBatchMode(): void {
    if (this.busy) { return; }
    this.batchMode = !this.batchMode;
    this.pendingDeletes = [];
  }

  private toggleDelete(name: string): void {
    if (this.busy) { return; }
    this.pendingDeletes = this.pendingDeletes.includes(name)
      ? this.pendingDeletes.filter((p: string) => p !== name)
      : this.pendingDeletes.concat([name]);
  }

  private selectVisibleForDelete(select: boolean): void {
    this.pendingDeletes = select ? this.rows.map((r: RoutingRow) => r.bundleName) : [];
  }

  /** 批量删除：一份确认，一次清掉两份名单 + 手动目录，预置条目同时记入已删除名单。 */
  private async deleteSelected(): Promise<void> {
    if (this.busy || !this.ready) { return; }
    const names = this.pendingDeletes.slice();
    if (names.length === 0) { this.toast('请先勾选要删除的应用'); return; }
    const presetCount = names.filter((name: string) => PRESET_APPS.some((p: PresetApp) => p.bundleName === name)).length;
    try {
      const response = await promptAction.showDialog({ title: '批量删除应用条目',
        message: `将移除 ${names.length} 项（两份名单及手动目录）`
          + `${presetCount > 0 ? `，其中 ${presetCount} 个预置条目保存后不再出现` : ''}。保存前不会改变当前 VPN。`,
        buttons: [{ text: '取消', color: $r('app.color.ui_text_secondary') }, { text: '删除', color: $r('app.color.ui_text_error') }] });
      if (response.index !== 1) { return; }
      this.included = this.included.filter((p: string) => !names.includes(p));
      this.excluded = this.excluded.filter((p: string) => !names.includes(p));
      this.customApps = this.customApps.filter((app: AppRoutingCustomApp) => !names.includes(app.bundleName));
      const removed = this.removedPresets.slice();
      for (const name of names) {
        if (PRESET_APPS.some((p: PresetApp) => p.bundleName === name) && !removed.includes(name)) {
          removed.push(name);
        }
      }
      this.removedPresets = removed;
      this.pendingDeletes = [];
      this.batchMode = false;
      this.rebuild();
      this.toast(`已移除 ${names.length} 项，点「保存」后生效`);
    } catch (e) { /* 取消不改变草稿。 */ }
  }

  private async removeEntry(name: string): Promise<void> {
    if (this.busy || !this.ready) { return; }
    const isPreset = PRESET_APPS.some((p: PresetApp) => p.bundleName === name);
    try {
      const response = await promptAction.showDialog({ title: '移除应用条目',
        message: `${name}\n从两份名单及手动目录移除`
          + `${isPreset ? '，并从预置常用应用里删除（保存后不会再出现）' : ''}。保存前不会改变当前 VPN。`,
        buttons: [{ text: '取消', color: $r('app.color.ui_text_secondary') }, { text: '移除', color: $r('app.color.ui_text_blue') }] });
      if (response.index !== 1) { return; }
      this.included = this.included.filter((p: string) => p !== name);
      this.excluded = this.excluded.filter((p: string) => p !== name);
      this.customApps = this.customApps.filter((app: AppRoutingCustomApp) => app.bundleName !== name);
      // 预置项：记入"已删除"名单，否则 rebuild() 会立刻把它加回来（删不掉的真因）
      if (isPreset && !this.removedPresets.includes(name)) {
        this.removedPresets = this.removedPresets.concat([name]);
      }
      this.rebuild();
      if (isPreset) { this.toast('已移除预置条目，点「保存」后永久生效'); }
    } catch (e) { /* 取消不改变草稿。 */ }
  }

  private async exportList(): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.current().join('\n')));
      this.toast('当前名单已复制，每行一个包名');
    } catch (e) { this.toast('复制失败，请重试'); }
  }

  private async save(): Promise<void> {
    if (this.busy || !this.ready || !this.dirty) { return; }
    const error = AppRoutingPolicy.validationError(this.mode, this.included, this.excluded, this.needsReview);
    if (error.length > 0) { this.toast(error); return; }
    this.busy = true;
    try {
      const response = await promptAction.showDialog({
        title: '应用分流变更',
        message: '保存不会改变网站规则。立即应用会在 VPN 已连接时重建隧道，网络可能短暂中断；也可以仅保存供下次连接使用。',
        buttons: [{ text: '取消', color: $r('app.color.ui_text_secondary') }, { text: '仅保存', color: $r('app.color.ui_text_blue') }, { text: '保存并应用', color: $r('app.color.ui_text_blue') }]
      });
      if (response.index === 0) { return; }
      // 加载最新设置，只覆盖本页字段，避免旧页面快照覆盖节点等其他设置。
      const settings = await SettingsService.load();
      settings.appRoutingMode = this.mode;
      settings.appRoutingNeedsReview = false;
      settings.includedApps = this.included.slice();
      settings.excludedApps = this.excluded.slice();
      settings.appRoutingCustomApps = this.customApps.slice();
      settings.appRoutingRemovedPresets = this.removedPresets.slice();
      await SettingsService.save(settings);
      this.original = this.fingerprint();
      this.rebuild();
      this.resultText = '已保存，下次连接生效；当前隧道接管范围尚未改变。';
      if (response.index === 2) {
        try {
          const restarted = await this.orchestrator.restartIfConnected('appRoutingChanged');
          this.resultText = restarted ? '已保存并请求重连，请在主页确认连接结果。' : '已保存，下次连接生效。';
        } catch (e) { this.resultText = '配置已保存，但重连未成功，请回主页手动连接。'; }
      }
      this.toast(this.resultText);
    } catch (e) { this.toast('保存未完成，请重试'); }
    finally { this.busy = false; }
  }

  private toast(message: string): void { promptAction.showToast({ message: message }); }

  private async back(): Promise<void> {
    if (this.busy) { return; }
    if (!this.dirty) { router.back(); return; }
    try {
      const response = await promptAction.showDialog({ title: '尚未保存', message: '离开会丢弃本页草稿，不会改变已保存的应用分流。',
        buttons: [{ text: '继续编辑', color: $r('app.color.ui_text_blue') }, { text: '放弃并离开', color: $r('app.color.ui_text_secondary') }] });
      if (response.index === 1) { router.back(); }
    } catch (e) { /* 系统取消对话框时留在编辑页。 */ }
  }

  onBackPress(): boolean { this.back(); return true; }

  /** 应用图标底色：按 bundleName 稳定哈希从文档 §1.1 色板的浅色底里固定取一。
   * 三个浅色底均为设计令牌（深色模式有对应派生值），取色确定、与勾选态无关。 */
  private iconBg(name: string): ResourceColor {
    let hash: number = 0;
    for (let i = 0; i < name.length; i++) {
      hash = (hash * 31 + name.charCodeAt(i)) % 9973;
    }
    const palette: ResourceColor[] = [
      TunBoxColors.primaryLight,
      TunBoxColors.successLight,
      TunBoxColors.dangerLight
    ];
    return palette[hash % palette.length];
  }

  /** 三段模式条分段（文档 §3.3：选中块 surfaceCard 底 / 圆角 8 / primary Bold；模式值与判定逻辑不变） */
  @Builder
  ModeChip(mode: string, label: string) {
    Text(label).fontSize(13)
      .fontWeight(this.mode === mode ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.mode === mode ? TunBoxColors.primary : TunBoxColors.textSecondary)
      .padding({ top: 8, bottom: 8 }).layoutWeight(1).textAlign(TextAlign.Center).borderRadius(8)
      .backgroundColor(this.mode === mode ? TunBoxColors.surfaceCard : Color.Transparent)
      .onClick(() => this.selectMode(mode))
  }

  /** 路由推入式子页统一转场：水平滑动 + 淡入淡出（与页签切换同规格，见 TunBoxMotion） */
  pageTransition() {
    PageTransitionEnter({ duration: TunBoxMotion.ms, curve: TunBoxMotion.curve })
      .translate({ x: TunBoxMotion.slidePercent, y: 0 }).opacity(0)
    PageTransitionExit({ duration: TunBoxMotion.ms, curve: TunBoxMotion.curve })
      .translate({ x: `-${TunBoxMotion.slidePercent}`, y: 0 }).opacity(0)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 底层背景列（文档 §1：系统全局底色，深浅色经 TunBoxColors 解析；不再用渐变/玻璃底）
      Column().width('100%').height('100%').linearGradient({ angle: 180, colors: [[TunBoxColors.bgGradientStart, 0.0], [TunBoxColors.bgGradientEnd, 1.0]] })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      Column() {
        // 顶部导航（文档 §2.1）：返回接既有 back()（含未保存草稿确认），rightSlot 承载既有「保存」按钮
        TopNavBar({ title: '应用分流', hasBack: true, onBack: (): void => { this.back(); } }) {
          Row({ space: 8 }) {
            Button(this.busy ? '请稍候' : '保存').fontSize(14)
              .backgroundColor(TunBoxColors.primary).fontColor(TunBoxColors.textOnPrimary)
              .borderRadius(TunBoxGeometry.controlRadius)
              .enabled(this.ready && !this.busy && this.dirty)
              .onClick(() => { this.save(); })
          }
        }
        Column({ space: 12 }) {
          // 三段分流模式条（文档 §3.3：整条 92% 宽 / controlTrackSoft 轨道 / 圆角 12 / padding 4；
          // 模式值 'all' | 'exclude' | 'include'、判定与保存格式全部沿用既有实现，只替换标签文案）
          Row({ space: 4 }) {
            this.ModeChip('all', '全部代理')
            this.ModeChip('exclude', '排除所选 (分流直连)')
            this.ModeChip('include', '仅限所选')
          }.width('92%').padding(4).borderRadius(12).backgroundColor(TunBoxColors.controlTrackSoft)
            .alignSelf(ItemAlign.Center)
            .enabled(this.ready && !this.busy)
          // 既有模式说明卡（文案与判定不变；视觉换成描边卡配方，去掉玻璃/模糊/backgroundEffect/阴影）
          Column({ space: 7 }) {
            Text(this.needsReview ? '旧名单存在冲突，请先明确选择一种模式'
              : this.mode === 'all' ? '所有应用进入 VPN'
              : `${this.mode === 'include' ? '仅接管' : '已排除'} ${this.current().length} 个应用`)
              .fontSize(16).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary).width('100%')
            Text(this.mode === 'all' ? '两份名单仍保留，但当前均不启用。'
              : this.mode === 'include' ? '仅所选应用进入 VPN，其余应用直接联网。' : '所选应用直接联网，其余应用进入 VPN。')
              .fontSize(12).fontColor(TunBoxColors.textSecondary).width('100%')
            Text('进入 VPN 后仍按规则 / 全局模式处理，不代表强制走代理节点。')
              .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
          }.width('100%').padding(16).borderRadius(TunBoxGeometry.cardRadiusSmall)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })
          Text('当前 SDK 不支持读取完整安装列表。以下是常用目录与手动名单，不代表本机已安装；字形为名称标识，并非应用图标。')
            .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
          // 搜索框（文档 §3.3：高 42 / surfaceCard 底 / 圆角 14 / 描边 cardBorder / 前置 ic_search 16 textMuted；
          // 搜索过滤逻辑不变）
          Row({ space: 8 }) {
            Image($r('app.media.ic_search')).width(16).height(16).fillColor(TunBoxColors.textMuted)
            TextInput({ text: this.query, placeholder: '搜索应用名称或鸿蒙包名 (BundleName)...' })
              .fontSize(14).fontColor(TunBoxColors.textPrimary).placeholderColor(TunBoxColors.textMuted)
              .backgroundColor(Color.Transparent).padding(0).height('100%').layoutWeight(1)
              .onChange((v: string) => { this.query = v; this.rebuild(); })
          }.width('100%').height(42).padding({ left: 12, right: 12 })
            .backgroundColor(TunBoxColors.surfaceCard).borderRadius(TunBoxGeometry.controlRadius)
            .border({ width: 1, color: TunBoxColors.cardBorder })
          // 过滤行：左侧统计与「已选择」筛选；右侧排序 + 批量删除入口（批量删除在任何模式下都能用）
          Row({ space: 12 }) {
            Text(this.batchMode ? `已勾选 (${this.pendingDeletes.length})`
              : (this.selectedOnly ? `已选择 (${this.current().length})` : `可用目录 (${this.rows.length})`))
              .fontColor(this.batchMode && this.pendingDeletes.length > 0 ? TunBoxColors.danger : TunBoxColors.primary).fontSize(13)
              .onClick(() => { if (this.batchMode) { return; } this.selectedOnly = !this.selectedOnly; this.rebuild(); })
            Blank()
            Text(this.nameSort ? '名称排序' : '已选置顶').fontSize(12).fontColor(TunBoxColors.textSecondary)
              .onClick(() => { if (this.batchMode) { return; } this.nameSort = !this.nameSort; this.rebuild(); })
            Text(this.batchMode ? '完成' : '批量删除').fontSize(12)
              .fontColor(this.batchMode ? TunBoxColors.primary : TunBoxColors.textSecondary)
              .padding({ left: 4, top: 4, bottom: 4 })
              .onClick(() => this.toggleBatchMode())
          }.width('100%')
          // 应用行（文档 §3.3：44 方形首字图标 / 应用名 15 Bold + 类别来源 chip /
          // bundleName 11 textMuted 单行省略 / 右侧 Checkbox select 色 primary；
          // 勾选 guard、移除条目入口、ForEach 键均沿用既有实现）
          List({ space: 10 }) {
            ForEach(this.rows, (row: RoutingRow) => {
              ListItem() {
                Row({ space: 12 }) {
                  Text(row.label.substring(0, 1)).fontSize(17).fontWeight(FontWeight.Bold)
                    .fontColor(TunBoxColors.primary)
                    .width(44).height(44).textAlign(TextAlign.Center).borderRadius(12)
                    .backgroundColor(this.iconBg(row.bundleName))
                  Column({ space: 4 }) {
                    Row({ space: 6 }) {
                      Text(row.label).fontSize(15).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                      Text(row.source).fontSize(10).fontColor(TunBoxColors.textSecondary).maxLines(1)
                        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                        .backgroundColor(TunBoxColors.chipBg).borderRadius(4)
                    }.width('100%')
                    Text(row.bundleName).fontSize(11).fontColor(TunBoxColors.textMuted).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                    if (!this.batchMode) {
                      Text('移除条目').fontSize(11).fontColor(TunBoxColors.primary)
                        .padding({ top: 5, bottom: 5 }).onClick(() => this.removeEntry(row.bundleName))
                    }
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                  Checkbox({ name: row.bundleName })
                    .select(this.batchMode ? this.pendingDeletes.includes(row.bundleName) : row.selected)
                    .selectedColor(this.batchMode ? TunBoxColors.danger : TunBoxColors.primary)
                    .enabled(this.batchMode ? !this.busy : (this.mode !== 'all' && !this.busy))
                    .onChange((checked: boolean) => {
                      if (this.batchMode) {
                        // 进入批量模式时 .select() 变化也会触发一次 onChange，必须先对齐模型状态再动手
                        if (checked !== this.pendingDeletes.includes(row.bundleName)) { this.toggleDelete(row.bundleName); }
                        return;
                      }
                      // guard 必须查实时名单状态（rebuild 每次 new 新 row 对象，
                      // ForEach 复用组件时闭包捕获的可能是旧对象）
                      if (checked !== this.current().includes(row.bundleName)) { this.toggle(row.bundleName); }
                    })
                }.width('100%').padding(14).borderRadius(18)
                  .backgroundColor(TunBoxColors.surfaceCard)
                  .border({
                    width: 1,
                    color: this.batchMode && this.pendingDeletes.includes(row.bundleName)
                      ? TunBoxColors.danger : TunBoxColors.cardBorder
                  })
              }
            }, (row: RoutingRow) => `${row.bundleName}:${row.selected}:`
              + `${this.batchMode && this.pendingDeletes.includes(row.bundleName) ? 1 : 0}`)
            if (this.rows.length === 0) {
              ListItem() { Text('没有匹配项，可手动添加鸿蒙包名。').fontSize(13).fontColor(TunBoxColors.textSecondary).padding(22) }
            }
          }.width('100%').layoutWeight(1).scrollBar(BarState.Auto) .edgeEffect(EdgeEffect.Spring)
          if (this.resultText.length > 0) { Text(this.resultText).fontSize(12).fontColor(TunBoxColors.primary).width('100%') }
        }.width('100%').layoutWeight(1).padding({
          left: TunBoxGeometry.pagePadding, right: TunBoxGeometry.pagePadding, top: 8, bottom: 8
        }).width('100%')
        // 底部固定操作 Dock（文档 §3.3）：批量删除模式换成「删除所选」，其余入口保持原样
        Column({ space: 8 }) {
          Row({ space: 16 }) {
            Text('全选当前结果').fontSize(12).fontColor(TunBoxColors.primary)
              .onClick(() => { if (this.batchMode) { this.selectVisibleForDelete(true); } else { this.selectVisible(true); } })
            Text(this.batchMode ? '取消全选' : '取消当前结果').fontSize(12).fontColor(TunBoxColors.textSecondary)
              .onClick(() => { if (this.batchMode) { this.selectVisibleForDelete(false); } else { this.selectVisible(false); } })
            Blank()
            Text(this.batchMode ? `已勾选 ${this.pendingDeletes.length} 项` : (this.dirty ? '草稿未保存' : '无未保存更改'))
              .fontSize(11)
              .fontColor(this.batchMode && this.pendingDeletes.length > 0 ? TunBoxColors.danger : TunBoxColors.textMuted)
          }.width('100%').enabled(this.ready && !this.busy && (this.batchMode || this.mode !== 'all'))
          Row({ space: 12 }) {
            if (this.batchMode) {
              Button(`删除所选（${this.pendingDeletes.length}）`).layoutWeight(1).height(46)
                .fontSize(14).fontWeight(FontWeight.Bold)
                .fontColor(this.pendingDeletes.length > 0 ? TunBoxColors.textOnPrimary : TunBoxColors.textSecondary)
                .backgroundColor(this.pendingDeletes.length > 0 ? TunBoxColors.danger : TunBoxColors.controlTrackSoft)
                .borderRadius(TunBoxGeometry.controlRadius)
                .enabled(this.pendingDeletes.length > 0 && !this.busy)
                .onClick(() => { this.deleteSelected(); })
              Button('完成').height(46).padding({ left: 20, right: 20 })
                .fontSize(14).fontWeight(FontWeight.Medium)
                .fontColor(TunBoxColors.primary).backgroundColor(TunBoxColors.primaryLight)
                .borderRadius(TunBoxGeometry.controlRadius)
                .onClick(() => this.toggleBatchMode())
            } else {
              Button() {
                Row({ space: 6 }) {
                  Image($r('app.media.ic_plus')).width(16).height(16).fillColor(TunBoxColors.textOnPrimary)
                  Text('添加/导入应用').fontSize(14).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textOnPrimary)
                }
              }
              .layoutWeight(1).height(46).backgroundColor(TunBoxColors.primary)
              .borderRadius(TunBoxGeometry.controlRadius)
              .onClick(() => this.inputDialog.open())
              Button('导出规则').height(46).padding({ left: 20, right: 20 })
                .fontSize(14).fontWeight(FontWeight.Medium)
                .fontColor(TunBoxColors.primary).backgroundColor(TunBoxColors.primaryLight)
                .borderRadius(TunBoxGeometry.controlRadius)
                .onClick(() => this.exportList())
            }
          }.width('100%').enabled(this.ready && !this.busy && (this.batchMode || this.mode !== 'all'))
        }.width('100%').padding({
          left: TunBoxGeometry.pagePadding, right: TunBoxGeometry.pagePadding, top: 10, bottom: 24
        }).backgroundColor(TunBoxColors.surfaceCard)
          .border({ width: { top: 1 }, color: TunBoxColors.cardBorder })
          .width('100%')
      }.width('100%').height('100%')
    }.width('100%').height('100%')
  }
}