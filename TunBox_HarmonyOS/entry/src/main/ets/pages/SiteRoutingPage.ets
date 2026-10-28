import { router, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { Ui } from '../theme/UiTokens';
import { TunBoxColors, TunBoxGeometry, TunBoxMotion } from '../theme/TunBoxTokens';
import { TopNavBar } from '../components/TopNavBar';
import { SettingsService } from '../commons/services/SettingsService';
import { AppSettings } from '../commons/models/AppSettings';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';
import { SiteRoutingPolicy } from '../commons/services/SiteRoutingPolicy';

class SitePageParams { kind: string = 'proxy'; }

@CustomDialog
struct SiteInputDialog {
  controller?: CustomDialogController;
  @State text: string = '';
  onAdd: (text: string) => boolean = () => false;

  /** 输入即时预检：与页面 add() 用同一套域名规则，合法才允许提交。 */
  private entries(): string[] { return SiteRoutingPolicy.parseInput(this.text); }

  private errorText(): string {
    const entries = this.entries();
    if (entries.length === 0) { return ''; }
    for (const domain of entries) {
      const error = SiteRoutingPolicy.domainError(domain);
      if (error.length > 0) { return `${domain}：${error}`; }
    }
    return '';
  }

  private canAdd(): boolean { return this.entries().length > 0 && this.errorText().length === 0; }

  private previewText(): string {
    const entries = this.entries();
    const head = entries.slice(0, 2).join('；');
    return `已识别 ${entries.length} 个域名：${head}` + (entries.length > 2 ? ' …' : '');
  }

  build() {
    Column({ space: 12 }) {
      Text('添加 / 批量导入网站').fontSize(19).fontWeight(FontWeight.Bold).fontColor(Ui.textPrimary)
      Text('每行一个纯域名，例如 example.com。无需 https://，不要填写路径、端口或通配符；规则包含其子域名。')
        .fontSize(12).fontColor(Ui.textSecondary)
      TextArea({ text: this.text, placeholder: 'example.com\nexample.org' }).height(170).maxLength(131072)
        .backgroundColor(Ui.inputBackground).fontColor(Ui.textPrimary).onChange((value: string) => { this.text = value; })
      // 输入即识别：全部行都是合法域名时按钮立刻变实心蓝，不合法行就地标红。
      if (this.text.trim().length > 0) {
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
          .onClick(() => { if (this.onAdd(this.text)) { this.controller?.close(); } })
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

@Entry
@Component
struct SiteRoutingPage {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @State kind: string = 'proxy';
  @State proxy: string[] = [];
  @State direct: string[] = [];
  @State block: string[] = [];
  @State query: string = '';
  @State selected: string[] = [];
  @State selectedOnly: boolean = false;
  @State alphabetical: boolean = false;
  @State visible: string[] = [];
  @State ready: boolean = false;
  @State busy: boolean = true;
  @State dirty: boolean = false;
  @State notice: string = '';
  private originalProxy: string[] = [];
  private originalDirect: string[] = [];
  private originalBlock: string[] = [];
  private initial: string = '';
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private dialog: CustomDialogController = new CustomDialogController({
    builder: SiteInputDialog({ onAdd: (text: string): boolean => this.add(text) }), autoCancel: false
  });

  // 入场转场期间不抢 UI 线程：读配置延到转场之后（2026-10-17 用户反馈进入页面卡顿）
  aboutToAppear(): void { setTimeout((): void => { this.load(); }, 240); }
  private async load(): Promise<void> {
    try {
      const params = router.getParams() as SitePageParams;
      this.kind = params !== undefined && params !== null && params.kind === 'direct' ? 'direct' : 'proxy';
      const context = getContext(this) as Context;
      this.orchestrator.init(context);
      await SettingsService.init(context);
      const settings = await SettingsService.load();
      this.originalProxy = settings.forceProxySites.slice();
      this.originalDirect = settings.forceDirectSites.slice();
      this.originalBlock = settings.forceBlockSites.slice();
      this.proxy = SiteRoutingPolicy.normalizeList(settings.forceProxySites);
      this.direct = SiteRoutingPolicy.normalizeList(settings.forceDirectSites);
      this.block = SiteRoutingPolicy.normalizeList(settings.forceBlockSites);
      this.initial = this.fingerprint();
      this.ready = true;
      this.notice = settings.proxyMode === 'global' ? '当前是全局模式，切回智能规则模式后网站规则才参与分流。' : '';
      this.rebuild();
    } catch (e) { this.notice = '读取配置失败，请返回后重试；没有修改任何设置。'; }
    finally { this.busy = false; }
  }

  private current(): string[] {
    if (this.kind === 'direct') { return this.direct; }
    if (this.kind === 'block') { return this.block; }
    return this.proxy;
  }
  private other(): string[] {
    if (this.kind === 'direct') { return this.proxy; }
    if (this.kind === 'block') { return this.block; }
    return this.direct;
  }
  private fingerprint(): string { return JSON.stringify([this.proxy, this.direct, this.block]); }
  private rebuild(): void {
    const keyword = this.query.trim().toLowerCase();
    this.visible = this.current().filter((domain: string) => domain.includes(keyword) && (!this.selectedOnly || this.selected.includes(domain)));
    if (this.alphabetical) { this.visible.sort((a: string, b: string) => a.localeCompare(b)); }
    else { this.visible.sort((a: string, b: string) => Number(this.selected.includes(b)) - Number(this.selected.includes(a))); }
    this.dirty = this.fingerprint() !== this.initial;
  }
  private setCurrent(domains: string[]): void {
    if (this.kind === 'direct') { this.direct = domains; }
    else if (this.kind === 'block') { this.block = domains; }
    else { this.proxy = domains; }
    this.selected = this.selected.filter((domain: string) => domains.includes(domain));
    this.rebuild();
  }
  private switchKind(kind: string): void {
    this.kind = kind;
    this.selected = [];
    this.selectedOnly = false;
    this.rebuild();
  }
  private toggle(domain: string): void {
    this.selected = this.selected.includes(domain) ? this.selected.filter((item: string) => item !== domain) : this.selected.concat([domain]);
    this.rebuild();
  }
  private add(text: string): boolean {
    const added = SiteRoutingPolicy.parseInput(text);
    if (added.length === 0) { this.toast('请至少输入一个域名'); return false; }
    for (const domain of added) {
      const error = SiteRoutingPolicy.domainError(domain);
      if (error.length > 0) { this.toast(`${domain}：${error}`); return false; }
      if (this.other().includes(domain)) { this.toast(`${domain} 已在另一份名单，请先从另一侧移除`); return false; }
    }
    const next = SiteRoutingPolicy.normalizeList(this.current().concat(added));
    if (next.length > SiteRoutingPolicy.MAX_SITES) { this.toast('每份名单最多 500 个域名'); return false; }
    this.setCurrent(next);
    this.toast(`已添加 ${added.length} 项到草稿，保存后生效`);
    return true;
  }
  private async remove(domains: string[]): Promise<void> {
    if (domains.length === 0 || this.busy) { return; }
    try {
      const result = await promptAction.showDialog({ title: '移除网站', message: `从当前名单移除 ${domains.length} 项？保存前不影响已生效规则。`,
        buttons: [{ text: '取消', color: $r('app.color.ui_text_secondary') }, { text: '移除', color: $r('app.color.ui_text_blue') }] });
      if (result.index === 1) { this.setCurrent(this.current().filter((domain: string) => !domains.includes(domain))); }
    } catch (e) { /* 取消保持草稿。 */ }
  }
  private async exportList(): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.current().join('\n')));
      this.toast('当前网站名单已复制，每行一个域名');
    } catch (e) { this.toast('复制失败，请重试'); }
  }
  private async save(): Promise<void> {
    if (!this.ready || this.busy || !this.dirty) { return; }
    const error = SiteRoutingPolicy.validationError(this.proxy, this.direct, this.block);
    if (error.length > 0) { this.toast(error); return; }
    this.busy = true;
    try {
      const result = await promptAction.showDialog({ title: '保存网站规则',
        message: '三份名单同时保存。立即应用通过热更新规则生效；失败时保留当前连接，不自动重连。仅保存则下次连接或规则重新加载时生效。',
        buttons: [{ text: '取消', color: $r('app.color.ui_text_secondary') }, { text: '仅保存', color: $r('app.color.ui_text_blue') }, { text: '保存并应用', color: $r('app.color.ui_text_blue') }] });
      if (result.index === 0) { return; }
      // 字段级写入（patchSettings）：只覆盖本页三份名单。旧写法 `load() → 改字段 → save(整份)`
      // 会让「load 与 save 之间别的写者」（设置页改节点、订阅刷新改 preferredNode*）被本页快照
      // 整份盖掉 —— F2 类静默数据丢失。并发三向比较也搬进写锁内：mutator 返回 false ⇒ 不写盘。
      let conflict = false;
      let proxyMode = '';
      await SettingsService.patchSettings((current: AppSettings): boolean => {
        proxyMode = current.proxyMode;
        if (JSON.stringify(current.forceProxySites) !== JSON.stringify(this.originalProxy)
          || JSON.stringify(current.forceDirectSites) !== JSON.stringify(this.originalDirect)
          || JSON.stringify(current.forceBlockSites) !== JSON.stringify(this.originalBlock)) {
          conflict = true;
          return false;
        }
        current.forceProxySites = this.proxy.slice();
        current.forceDirectSites = this.direct.slice();
        current.forceBlockSites = this.block.slice();
        return true;
      });
      if (conflict) {
        this.toast('网站规则已被其他页面修改，请返回重新打开后编辑'); return;
      }
      this.originalProxy = this.proxy.slice();
      this.originalDirect = this.direct.slice();
      this.originalBlock = this.block.slice();
      this.initial = this.fingerprint();
      this.rebuild();
      this.notice = '已保存，下次连接或规则重新加载时生效。';
      if (result.index === 2) {
        try {
          const outcome = await this.orchestrator.applyRulesChanged('forceSitesChanged');
          this.notice = outcome === 'hot' ? '已保存并热更新规则，未重建 VPN。'
            : outcome === 'reconnect' ? '已保存并请求重连，请在主页确认连接状态。'
            : outcome === 'ad-unavailable' ? '已保存，广告规则尚未下载，请到设置的数据与规则手动更新。'
            : outcome === 'apply-failed' ? '已保存，但立即应用未完成；未主动断开当前连接，请检查配置后重试。'
            : outcome === 'pending' ? '已保存，另一规则更新进行中，请稍后重试立即应用。' : '已保存，下次连接生效。';
        } catch (e) { this.notice = '配置已保存，但立即应用失败；请检查配置后重试。'; }
      }
      if (proxyMode === 'global') { this.notice += ' 当前全局模式，请切回智能规则模式使用网站规则。'; }
      this.toast(this.notice);
    } catch (e) { this.toast('保存未完成，请重试'); }
    finally { this.busy = false; }
  }
  private toast(message: string): void { promptAction.showToast({ message: message }); }
  private async back(): Promise<void> {
    if (this.busy) { return; }
    if (!this.dirty) { router.back(); return; }
    try {
      const result = await promptAction.showDialog({ title: '尚未保存', message: '离开会丢弃两份网站名单的草稿。',
        buttons: [{ text: '继续编辑', color: $r('app.color.ui_text_blue') }, { text: '放弃并离开', color: $r('app.color.ui_text_secondary') }] });
      if (result.index === 1) { router.back(); }
    } catch (e) { /* 保持页面。 */ }
  }
  onBackPress(): boolean { this.back(); return true; }

  /** 数量必须在这里按 kind 现算：@Builder 的按值参数不会随状态刷新，
   *  之前把 count 当参数传进来，添加后标签一直停在 0（2026-10-26 真机反馈）。 */
  private countOf(kind: string): number {
    if (kind === 'direct') { return this.direct.length; }
    if (kind === 'block') { return this.block.length; }
    return this.proxy.length;
  }

  /**
   * 三态策略分段（2026-10-23 用户口径：**样式与应用分流页的三段条一致**——
   * 同宽 92% 轨道 / controlTrackSoft 底 / 圆角 12 / padding 4，选中块
   * surfaceCard 底 + primary Bold，未选中 textSecondary）。
   *
   * 与应用分流唯一的差别是**保留数量**（`强制代理 3`）：网站名单是多份并行生效的，
   * 数量是这一页最关键的上下文，去掉就只剩名字。kind 值与判定逻辑不变。
   */
  @Builder
  KindTab(kind: string, label: string) {
    Row({ space: 5 }) {
      Circle({ width: 6, height: 6 })
        .fill(kind === 'direct' ? TunBoxColors.success : kind === 'block' ? TunBoxColors.danger : TunBoxColors.primary)
        .opacity(this.kind === kind ? 1 : 0.45)
      Text(label).fontSize(13)
        .fontWeight(this.kind === kind ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.kind === kind ? TunBoxColors.primary : TunBoxColors.textSecondary)
        .maxLines(1)
      Text(`${this.countOf(kind)}`).fontSize(12)
        .fontWeight(this.kind === kind ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.kind === kind ? TunBoxColors.primary : TunBoxColors.textMuted)
        .maxLines(1)
    }
    .padding({ top: 8, bottom: 8 })
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .borderRadius(8)
    .backgroundColor(this.kind === kind ? TunBoxColors.surfaceCard : Color.Transparent)
    .onClick(() => this.switchKind(kind))
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
        TopNavBar({ title: '网站分流', hasBack: true, onBack: (): void => { this.back(); } }) {
          Row({ space: 8 }) {
            Button(this.busy ? '请稍候' : '保存').fontSize(14)
              .backgroundColor(TunBoxColors.primary).fontColor(TunBoxColors.textOnPrimary)
              .borderRadius(TunBoxGeometry.controlRadius)
              .enabled(this.ready && !this.busy && this.dirty)
              .onClick(() => { this.save(); })
          }
        }
        Column({ space: 12 }) {
          // 三态策略分段条（样式对齐应用分流页：92% 轨道 + controlTrackSoft + 圆角 12 + padding 4）
          Row({ space: 4 }) {
            this.KindTab('proxy', '强制代理')
            this.KindTab('direct', '强制直连')
            this.KindTab('block', '强制拦截')
          }.width('92%').padding(4).borderRadius(12).backgroundColor(TunBoxColors.controlTrackSoft)
            .alignSelf(ItemAlign.Center)
            .enabled(this.ready && !this.busy)
          // 既有说明卡（文案与判定不变；视觉换成描边卡配方，去掉玻璃/模糊/backgroundEffect/阴影）
          Column({ space: 6 }) {
            Text(this.kind === 'direct' ? '以下网站使用直连策略'
              : this.kind === 'block' ? '以下网站将被拦截（DNS 层拒绝）' : '以下网站使用代理策略')
              .fontSize(16).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
            Text(this.kind === 'block'
              ? '拦截名单在 DNS 解析层直接拒绝这些域名（含子域名），不建立连接。与代理/直连名单互斥，同名冲突需移除一侧。'
              : '三份名单同时生效，切换标签不会关闭其他两份。规则匹配域名及子域名；同名冲突需移除一侧。绕过 VPN 的应用不受此设置影响。')
              .fontSize(12).fontColor(TunBoxColors.textSecondary)
            Text('勾选仅用于批量操作，不是启用开关。网站规则位于广告 / 自定义规则之后；网站名单之间重叠时直连优先。')
              .fontSize(11).fontColor(TunBoxColors.textMuted)
          }.width('100%').padding(16).alignItems(HorizontalAlign.Start).borderRadius(TunBoxGeometry.cardRadiusSmall)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })
          // 既有搜索框（过滤逻辑不变；视觉改令牌配方：高 42 / surfaceCard / 圆角 14 / 描边 / 前置 ic_search）
          Row({ space: 8 }) {
            Image($r('app.media.ic_search')).width(16).height(16).fillColor(TunBoxColors.textMuted)
            TextInput({ text: this.query, placeholder: '搜索域名' })
              .fontSize(14).fontColor(TunBoxColors.textPrimary).placeholderColor(TunBoxColors.textMuted)
              .backgroundColor(Color.Transparent).padding(0).height('100%').layoutWeight(1)
              .onChange((value: string) => { this.query = value; this.rebuild(); })
          }.width('100%').height(42).padding({ left: 12, right: 12 })
            .backgroundColor(TunBoxColors.surfaceCard).borderRadius(TunBoxGeometry.controlRadius)
            .border({ width: 1, color: TunBoxColors.cardBorder })
          // 既有过滤行（切换逻辑不变；'▾' 文字符号去掉）
          Row() {
            Text(this.selectedOnly ? `已勾选 ${this.selected.length}` : `当前名单 ${this.current().length}`).fontSize(13)
              .fontColor(TunBoxColors.primary)
              .onClick(() => { this.selectedOnly = !this.selectedOnly; this.rebuild(); })
            Blank()
            Text(this.alphabetical ? '域名排序' : '已选置顶').fontSize(12).fontColor(TunBoxColors.textSecondary)
              .onClick(() => { this.alphabetical = !this.alphabetical; this.rebuild(); })
          }.width('100%')
          // 规则行（文档 §3.5：Checkbox + 域名 14 Bold + 类型标签 9 primary primaryLight 圆角 4 +
          // 校验错误行 11 danger + 右侧删除 ic_delete 16 textMuted；行卡 surfaceCard / 圆角 18 / 描边 cardBorder；
          // 勾选 guard、移除确认、ForEach 键均沿用既有实现）
          List({ space: 10 }) {
            ForEach(this.visible, (domain: string) => {
              ListItem() {
                Row({ space: 10 }) {
                  Checkbox({ name: domain }).select(this.selected.includes(domain)).selectedColor(TunBoxColors.primary)
                    .onChange((value: boolean) => { if (value !== this.selected.includes(domain)) { this.toggle(domain); } })
                  Column({ space: 4 }) {
                    Row({ space: 6 }) {
                      Text(domain || '（空域名）').fontSize(14).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
                        .wordBreak(WordBreak.BREAK_ALL).layoutWeight(1)
                      Text(this.kind === 'direct' ? '直连' : this.kind === 'block' ? '拦截' : '代理')
                        .fontSize(9).fontColor(TunBoxColors.primary)
                        .backgroundColor(TunBoxColors.primaryLight).borderRadius(4).padding(2)
                    }.width('100%')
                    if (this.other().includes(domain) || SiteRoutingPolicy.domainError(domain).length > 0) {
                      Text(this.other().includes(domain) ? '两份名单重复，请移除一侧' : '格式无效，请移除后重新添加')
                        .fontSize(11).fontColor(TunBoxColors.danger)
                    }
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                  Button() {
                    Image($r('app.media.ic_delete')).width(16).height(16).fillColor(TunBoxColors.textMuted)
                  }.type(ButtonType.Normal).backgroundColor(Color.Transparent)
                    .onClick(() => this.remove([domain]))
                }.padding(14).width('100%').borderRadius(18)
                  .backgroundColor(TunBoxColors.surfaceCard)
                  .border({ width: 1, color: TunBoxColors.cardBorder })
              }
            }, (domain: string) => `${domain}:${this.selected.includes(domain)}`)
            if (this.visible.length === 0) {
              ListItem() { Text('没有匹配的网站，可点击下方添加 / 导入。').fontSize(13).fontColor(TunBoxColors.textSecondary).padding(22) }
            }
          }.layoutWeight(1).width('100%').enabled(this.ready && !this.busy) .edgeEffect(EdgeEffect.Spring)
          if (this.notice.length > 0) { Text(this.notice).fontSize(11).fontColor(TunBoxColors.primary).width('100%') }
        }.width('100%').layoutWeight(1).padding({
          left: TunBoxGeometry.pagePadding, right: TunBoxGeometry.pagePadding, top: 8, bottom: 8
        }).width('100%')
        // 底部固定操作 Dock（文档 §3.5）：既有辅助行（全选/取消/移除 N 项 + 草稿状态）保留在主按钮上方；
        // 回调与可用条件（ready && !busy）不变
        Column({ space: 8 }) {
          Row({ space: 10 }) {
            Text('全选结果').fontSize(12).fontColor(TunBoxColors.primary).onClick(() => {
              this.selected = SiteRoutingPolicy.normalizeList(this.selected.concat(this.visible)); this.rebuild();
            })
            Text('取消勾选').fontSize(12).fontColor(TunBoxColors.textSecondary).onClick(() => { this.selected = []; this.rebuild(); })
            Text(`移除 ${this.selected.length} 项`).fontSize(12).fontColor(TunBoxColors.primary).onClick(() => this.remove(this.selected.slice()))
            Blank()
            Text(this.dirty ? '草稿未保存' : '无未保存更改').fontSize(10).fontColor(TunBoxColors.textMuted)
          }.width('100%').enabled(this.ready && !this.busy)
          Row({ space: 12 }) {
            Button() {
              Row({ space: 6 }) {
                Image($r('app.media.ic_plus')).width(16).height(16).fillColor(TunBoxColors.textOnPrimary)
                Text('添加/导入').fontSize(14).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textOnPrimary)
              }
            }
            .layoutWeight(1).height(46).backgroundColor(TunBoxColors.primary)
            .borderRadius(TunBoxGeometry.controlRadius)
            .onClick(() => this.dialog.open())
            Button('导出名单').height(46).padding({ left: 20, right: 20 })
              .fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(TunBoxColors.primary).backgroundColor(TunBoxColors.primaryLight)
              .borderRadius(TunBoxGeometry.controlRadius)
              .onClick(() => this.exportList())
          }.width('100%').enabled(this.ready && !this.busy)
        }.width('100%').padding({
          left: TunBoxGeometry.pagePadding, right: TunBoxGeometry.pagePadding, top: 10, bottom: 24
        }).backgroundColor(TunBoxColors.surfaceCard)
          .border({ width: { top: 1 }, color: TunBoxColors.cardBorder })
          .width('100%')
      }.width('100%').height('100%')
    }.width('100%').height('100%')
  }
}
