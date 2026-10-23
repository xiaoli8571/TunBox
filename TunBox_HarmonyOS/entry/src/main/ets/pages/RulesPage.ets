import { promptAction, LengthMetrics } from '@kit.ArkUI';
import { TabLifecycleBridge } from '../commons/utils/TabLifecycleBridge';
import { TunBoxColors, TunBoxGeometry, TunBoxMotion } from '../theme/TunBoxTokens';
import { TopNavBar } from '../components/TopNavBar';
import { AppSettings, CustomRuleSet } from '../commons/models/AppSettings';
import { SettingsService } from '../commons/services/SettingsService';
import { ClashConfigGenerator } from '../commons/services/ClashConfigGenerator';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';

/** 内容列最大宽度（与原 UiTokens.pageMaxWidth 取值一致，平板/折叠屏防过宽） */

@Component
export struct RulesView {
  @StorageLink('theme_revision') themeRevision: number = 0;
  /** 宿主（底部页签 MainPage / 路由包装页 RulesPage）「重新展示」通知桥（替代 onPageShow 语义） */
  shownBridge?: TabLifecycleBridge;
  /** 延迟加载定时器（转场后再读盘校验） */
  private bootstrapTimer: number = -1;
  @State rulesEnabled: boolean = true;
  /** 去广告默认关闭：与 AppSettings.hyperAdRulesEnabled 的默认值保持一致 */
  @State hyperAdRulesEnabled: boolean = false;
  @State customRulesText: string = '';
  /** 逐行校验错误（"第 N 行：原因"），输入即刷新（M8：所见校验 = 实际落盘） */
  @State ruleErrors: string[] = [];
  /** 用户自定义远程规则集（P1-2）：条目列表 + 新增表单状态 */
  @State ruleSets: CustomRuleSet[] = [];
  @State rsName: string = '';
  @State rsUrl: string = '';
  @State rsBehavior: string = 'domain';
  @State rsPolicy: string = 'REJECT';
  @State rsFormat: string = 'yaml';
  /** 规则调试（P1-5）：输入域名 → 实时命中判定 */
  @State debugDomain: string = '';
  @State debugResult: string = '';
  /** YAML 覆盖层（P2）：settings.yamlOverride 双向绑定 */
  @State yamlOverrideText: string = '';
  private settings: AppSettings = new AppSettings();
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();

  aboutToAppear(): void {
    if (this.shownBridge !== undefined) {
      this.shownBridge.setShowHandler((): void => { this.scheduleBootstrap(); });
    }
  }

  aboutToDisappear(): void {
    if (this.bootstrapTimer >= 0) {
      clearTimeout(this.bootstrapTimer);
      this.bootstrapTimer = -1;
    }
    if (this.shownBridge !== undefined) {
      this.shownBridge.setShowHandler(null);
    }
  }

  /**
   * 读盘 + 逐行规则校验（SettingsService.load / refreshRuleErrors）会占满 UI 线程，
   * 入场转场期间执行会让页面进入明显掉帧 —— 让转场先跑完再加载（2026-10-17 用户反馈卡顿）。
   */
  private scheduleBootstrap(): void {
    if (this.bootstrapTimer >= 0) {
      clearTimeout(this.bootstrapTimer);
    }
    this.bootstrapTimer = setTimeout((): void => {
      this.bootstrapTimer = -1;
      this.bootstrap();
    }, 240);
  }

  /** 输入变化时逐行校验；规则为空的行跳过（不报错） */
  private refreshRuleErrors(): void {
    const errors: string[] = [];
    const lines = this.customRulesText.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      const error = ClashConfigGenerator.validateCustomRuleDetailed(line);
      if (error.length > 0) {
        errors.push(`第 ${i + 1} 行：${error}`);
      }
    }
    this.ruleErrors = errors;
  }

  private async bootstrap(): Promise<void> {
    await SettingsService.init(getContext(this) as Context);
    this.settings = await SettingsService.load();
    this.rulesEnabled = this.settings.rulesEnabled;
    this.hyperAdRulesEnabled = this.settings.hyperAdRulesEnabled;
    this.customRulesText = this.settings.customRules.join('\n');
    this.ruleSets = this.settings.customRuleSets;
    this.yamlOverrideText = this.settings.yamlOverride;
    this.refreshRuleErrors();
  }

  /** 保存 YAML 覆盖层（P2）：生成器侧 validateYamlOverride 白名单在生成时把关 */
  private async saveYamlOverride(): Promise<void> {
    const text = this.yamlOverrideText.slice(0, 8192);
    this.settings.yamlOverride = text;
    // 字段级写入口（审计 F2）：只写覆盖层这一个字段。
    await SettingsService.patchSettings((s: AppSettings): void => {
      s.yamlOverride = text;
    });
    promptAction.showToast({ message: '覆盖层已保存，下次连接/热重载生效' });
  }

  /** 新增自定义规则集（P1-2）：走 normalizeRuleSets 统一校验（名称/URL/白名单） */
  private async addRuleSet(): Promise<void> {
    const name = this.rsName.trim();
    const url = this.rsUrl.trim();
    if (name.length === 0 || url.length === 0) {
      promptAction.showToast({ message: '请填写规则集名称与 https URL' });
      return;
    }
    if (this.ruleSets.length >= 20) {
      promptAction.showToast({ message: '最多 20 条自定义规则集' });
      return;
    }
    const candidate = new CustomRuleSet();
    candidate.name = name;
    candidate.url = url;
    candidate.behavior = this.rsBehavior;
    candidate.format = this.rsFormat;
    candidate.policy = this.rsPolicy;
    candidate.interval = 86400;
    const merged = this.ruleSets.slice(0);
    merged.push(candidate);
    const normalized = AppSettings.normalizeRuleSets(merged);
    if (normalized.length === this.ruleSets.length) {
      promptAction.showToast({ message: '规则集无效：名称限字母数字-_，URL 必须 https 且 ≤512 字符' });
      return;
    }
    this.ruleSets = normalized;
    this.settings.customRuleSets = normalized;
    this.rsName = '';
    this.rsUrl = '';
    // 字段级写入口（审计 F2）：只写规则集这一个字段。
    await SettingsService.patchSettings((s: AppSettings): void => {
      s.customRuleSets = normalized;
    });
    const outcome = await this.orchestrator.applyRulesChanged('rulesChanged');
    const effect = outcome === 'hot' ? '已即时生效（未重建隧道）'
      : (outcome === 'reconnect' ? '正在自动重连' : '下次连接生效');
    promptAction.showToast({ message: `规则集已添加，${effect}` });
  }

  private async removeRuleSet(name: string): Promise<void> {
    const kept: CustomRuleSet[] = [];
    for (const entry of this.ruleSets) {
      if (entry.name !== name) {
        kept.push(entry);
      }
    }
    this.ruleSets = kept;
    this.settings.customRuleSets = kept;
    // 字段级写入口（审计 F2）：只写规则集这一个字段。
    await SettingsService.patchSettings((s: AppSettings): void => {
      s.customRuleSets = kept;
    });
    const outcome = await this.orchestrator.applyRulesChanged('rulesChanged');
    const effect = outcome === 'hot' ? '已即时生效（未重建隧道）'
      : (outcome === 'reconnect' ? '正在自动重连' : '下次连接生效');
    promptAction.showToast({ message: `规则集已删除，${effect}` });
  }

  private async save(): Promise<void> {
    const supplied = this.customRulesText.split('\n')
      .map((v: string) => v.trim()).filter((v: string) => v.length > 0);
    const normalized = ClashConfigGenerator.normalizeCustomRules(supplied);
    const invalidCount = Math.max(0, supplied.length - normalized.length);
    this.settings.rulesEnabled = this.rulesEnabled;
    this.settings.hyperAdRulesEnabled = this.hyperAdRulesEnabled;
    this.settings.customRules = normalized;
    this.settings.customRuleSets = this.ruleSets;
    this.customRulesText = normalized.join('\n');
    this.refreshRuleErrors();
    // 字段级写入口（审计 F2）：只写这四个字段，其余字段从盘上最新值原样带走。
    await SettingsService.patchSettings((s: AppSettings): void => {
      s.rulesEnabled = this.rulesEnabled;
      s.hyperAdRulesEnabled = this.hyperAdRulesEnabled;
      s.customRules = normalized;
      s.customRuleSets = this.ruleSets;
    });
    const outcome = await this.orchestrator.applyRulesChanged('rulesChanged');
    const suffix = invalidCount > 0 ? `，已忽略 ${invalidCount} 条无效规则` : '';
    const effect = outcome === 'hot' ? '已即时生效（未重建隧道）'
      : (outcome === 'reconnect' ? '正在自动重连' : '下次连接生效');
    promptAction.showToast({
      message: `规则已保存，${effect}${suffix}`
    });
  }

  /**
   * 模版注入（doc §3.6）：把四条示例规则确定性并入既有自定义规则文本。
   * 幂等：已存在的行不重复追加；只写 @State customRulesText，并复用既有逐行校验刷新错误展示。
   */
  private injectRuleTemplate(): void {
    const template: string[] = [
      'DOMAIN-SUFFIX,apple.com,DIRECT',
      'DOMAIN-KEYWORD,google,PROXY',
      'DOMAIN-SUFFIX,analytics.local,REJECT',
      'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve'
    ];
    const merged: string[] = this.customRulesText.split('\n')
      .map((v: string) => v.trim()).filter((v: string) => v.length > 0);
    for (const t of template) {
      if (!merged.includes(t)) {
        merged.push(t);
      }
    }
    this.customRulesText = merged.join('\n');
    this.refreshRuleErrors();
  }

  /** 调试结果拆分（沿用 ClashConfigGenerator.debugDomainMatch 的 "TYPE,value → TARGET" 输出格式） */
  private debugMatchedRule(): string {
    const idx = this.debugResult.indexOf(' → ');
    return idx >= 0 ? this.debugResult.substring(0, idx) : '';
  }

  private debugTargetPolicy(): string {
    const idx = this.debugResult.indexOf(' → ');
    return idx >= 0 ? this.debugResult.substring(idx + 3) : '';
  }

  /** 「路由去向」文案：由命中策略翻译（不新增判定逻辑） */
  private policyDesc(policy: string): string {
    if (policy === 'DIRECT') {
      return '直连 (DIRECT)';
    }
    if (policy === 'PROXY') {
      return '代理 (PROXY)';
    }
    if (policy === 'REJECT') {
      return '拦截 (REJECT)';
    }
    if (policy === 'REJECT-DROP') {
      return '丢弃 (REJECT-DROP)';
    }
    if (policy === 'PASS') {
      return '跳过 (PASS)';
    }
    return policy;
  }

  /** 策略徽章文字色（doc §3.6：DIRECT=success / PROXY=primary / REJECT=danger） */
  private policyColor(policy: string): ResourceColor {
    if (policy === 'PROXY') {
      return TunBoxColors.primary;
    }
    if (policy === 'REJECT' || policy === 'REJECT-DROP') {
      return TunBoxColors.danger;
    }
    if (policy === 'DIRECT') {
      return TunBoxColors.success;
    }
    return TunBoxColors.textSecondary;
  }

  /** 策略徽章底色（对应浅底） */
  private policyBg(policy: string): ResourceColor {
    if (policy === 'PROXY') {
      return TunBoxColors.primaryLight;
    }
    if (policy === 'REJECT' || policy === 'REJECT-DROP') {
      return TunBoxColors.dangerLight;
    }
    if (policy === 'DIRECT') {
      return TunBoxColors.successLight;
    }
    return TunBoxColors.chipBg;
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column().width('100%').height('100%')
        .linearGradient({ angle: 180, colors: [[TunBoxColors.bgGradientStart, 0.0], [TunBoxColors.bgGradientEnd, 1.0]] })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      Column() {
        // ── 顶栏（doc §3.6：页签页无返回；既有「保存」入口放 rightSlot 扩展槽）──
        TopNavBar({ title: '路由与规则' }) {
          Button('保存')
            .fontSize(14)
            .backgroundColor(TunBoxColors.primary)
            .fontColor(TunBoxColors.textOnPrimary)
            .borderRadius(TunBoxGeometry.controlRadius)
            .onClick(() => { this.save(); })
        }
        Scroll() {
          Column({ space: 14 }) {
            // ── 卡片 1：核心开关（doc §3.6）──
            Column({ space: 12 }) {
              Row() {
                Column({ space: 2 }) {
                  Text('启用规则路由引擎')
                    .fontSize(15).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
                  Text('全局或自定义规则将在网络连接建立时立即生效')
                    .fontSize(11).fontColor(TunBoxColors.textMuted)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.rulesEnabled })
                  .selectedColor(TunBoxColors.primary)
                  .onChange((value: boolean) => { this.rulesEnabled = value; })
              }.width('100%').alignItems(VerticalAlign.Center)
              Divider().strokeWidth(1).color(TunBoxColors.cardBorder)
              Row() {
                Column({ space: 2 }) {
                  Row({ space: 6 }) {
                    Text('HyperADRules 智能去广告')
                      .fontSize(15).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
                    Text('官方 MRS')
                      .fontSize(9).fontColor(TunBoxColors.primary)
                      .backgroundColor(TunBoxColors.primaryLight)
                      .padding({ left: 4, right: 4, top: 2, bottom: 2 })
                      .borderRadius(4)
                  }.alignItems(VerticalAlign.Center)
                  // 独立开关（2026-10-23 用户口径）：不依赖上面的规则引擎；
                  // 规则集随包内置，打开即用，后台再自动增量更新。
                  Text('独立开关 · 内置规则集随包自带，开箱即用 · 来源：Lynricsy')
                    .fontSize(11).fontColor(TunBoxColors.textMuted)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.hyperAdRulesEnabled })
                  .selectedColor(TunBoxColors.primary)
                  .onChange((value: boolean) => { this.hyperAdRulesEnabled = value; })
              }.width('100%').alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .padding(TunBoxGeometry.cardPadding)
            .backgroundColor(TunBoxColors.surfaceCard)
            .borderRadius(TunBoxGeometry.cardRadius)
            .border({ width: 1, color: TunBoxColors.cardBorder })
            // ── 卡片 2：自定义域名与 IP 规则（doc §3.6：等宽代码编辑器 + 模版注入）──
            Column({ space: 10 }) {
              Row() {
                Text('自定义域名与 IP 规则')
                  .fontSize(14).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
                Blank()
                Text('模版注入')
                  .fontSize(12).fontColor(TunBoxColors.primary)
                  .padding({ left: 8, right: 4, top: 6, bottom: 6 })
                  .onClick(() => { this.injectRuleTemplate(); })
              }.width('100%').alignItems(VerticalAlign.Center)
              Text('每行一条，例如 DOMAIN-SUFFIX,example.com,REJECT')
                .fontSize(12).fontColor(TunBoxColors.textMuted).width('100%')
              TextArea({
                placeholder: 'DOMAIN-SUFFIX,example.com,REJECT\nDOMAIN,example.org,DIRECT',
                text: this.customRulesText
              })
                .enabled(this.rulesEnabled)
                .onChange((value: string) => {
                  this.customRulesText = value;
                  this.refreshRuleErrors();
                })
                .width('100%').height(260)
                .fontSize(12).fontFamily('monospace').lineHeight(20)
                .fontColor(TunBoxColors.codeText)
                .placeholderColor(TunBoxColors.textMuted)
                .backgroundColor(TunBoxColors.codeBg)
                .borderRadius(14)
                .padding(12)
                .border({
                  width: 1,
                  color: this.ruleErrors.length > 0 ? TunBoxColors.danger : TunBoxColors.codeBorder
                })
              if (this.ruleErrors.length > 0) {
                Column({ space: 4 }) {
                  ForEach(this.ruleErrors, (err: string) => {
                    Row({ space: 6 }) {
                      Image($r('app.media.ic_warning'))
                        .width(12).height(12).fillColor(TunBoxColors.danger).margin({ top: 2 })
                      Text(err).fontSize(11).fontColor(TunBoxColors.danger).layoutWeight(1)
                    }.width('100%').alignItems(VerticalAlign.Top)
                  }, (err: string, idx: number) => `${idx}-${err}`)
                }
                .width('100%')
                .padding(10)
                .borderRadius(12)
                .backgroundColor(TunBoxColors.dangerLight)
                .border({ width: 1, color: TunBoxColors.danger })
                .alignItems(HorizontalAlign.Start)
              }
              Text('支持 DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、IP-CIDR、IP-CIDR6、GEOIP；策略支持 DIRECT、PROXY、REJECT、PASS、REJECT-DROP；IP 类规则可追加 no-resolve。')
                .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
            }
            .width('100%')
            .padding(TunBoxGeometry.cardPadding)
            .backgroundColor(TunBoxColors.surfaceCard)
            .borderRadius(TunBoxGeometry.cardRadius)
            .border({ width: 1, color: TunBoxColors.cardBorder })
            // ── 卡片 3：规则命中快速调试（doc §3.6：沙盒模拟）──
            Column({ space: 12 }) {
              Row() {
                Text('规则命中快速调试')
                  .fontSize(14).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary)
                Blank()
                Text('沙盒模拟').fontSize(11).fontColor(TunBoxColors.textMuted)
              }.width('100%')
              Row({ space: 8 }) {
                TextInput({ placeholder: 'developer.apple.com', text: this.debugDomain })
                  .layoutWeight(1).height(40)
                  .fontSize(13)
                  .fontColor(TunBoxColors.textPrimary)
                  .placeholderColor(TunBoxColors.textMuted)
                  .backgroundColor(TunBoxColors.surfaceSubtle)
                  .borderRadius(10)
                  .padding({ left: 10, right: 10 })
                  .onChange((value: string) => {
                    this.debugDomain = value;
                    this.debugResult = ClashConfigGenerator.debugDomainMatch(value, this.customRulesText.split('\n'));
                  })
                Text('诊断')
                  .fontSize(14).fontWeight(FontWeight.Medium)
                  .fontColor(TunBoxColors.primary)
                  .backgroundColor(TunBoxColors.primaryLight)
                  .height(40)
                  .padding({ left: 16, right: 16 })
                  .borderRadius(10)
                  .onClick(() => {
                    this.debugResult = ClashConfigGenerator.debugDomainMatch(this.debugDomain,
                      this.customRulesText.split('\n'));
                  })
              }.width('100%').alignItems(VerticalAlign.Center)
              if (this.debugDomain.trim().length > 0) {
                Row() {
                  Circle({ width: 6, height: 6 })
                    .fill(this.debugResult.length > 0 ? TunBoxColors.success : TunBoxColors.textMuted)
                    .margin({ right: 8 })
                  Column({ space: 2 }) {
                    Text(this.debugResult.length > 0
                      ? `匹配规则: ${this.debugMatchedRule()}` : '未命中自定义域名规则')
                      .fontSize(12).fontWeight(FontWeight.Medium).fontColor(TunBoxColors.textPrimary)
                    Text(this.debugResult.length > 0
                      ? `路由去向: ${this.policyDesc(this.debugTargetPolicy())}`
                      : '（走 DIRECT/PROXY 名单或 GEOIP/MATCH）')
                      .fontSize(11).fontColor(TunBoxColors.textMuted)
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  if (this.debugResult.length > 0) {
                    Text(this.debugTargetPolicy())
                      .fontSize(12).fontWeight(FontWeight.Bold)
                      .fontColor(this.policyColor(this.debugTargetPolicy()))
                      .backgroundColor(this.policyBg(this.debugTargetPolicy()))
                      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                      .borderRadius(6)
                  }
                }
                .width('100%').alignItems(VerticalAlign.Center)
                .padding(12)
                .backgroundColor(TunBoxColors.surfaceSubtle)
                .borderRadius(12)
              }
            }
            .width('100%')
            .padding(TunBoxGeometry.cardPadding)
            .backgroundColor(TunBoxColors.surfaceCard)
            .borderRadius(TunBoxGeometry.cardRadius)
            .border({ width: 1, color: TunBoxColors.cardBorder })
            // ── 自定义远程规则集（P1-2）：条目列表 + 新增表单，对标 iOS 六家 RULE-SET 能力 ──
            Column({ space: 10 }) {
              Text('自定义规则集').fontSize(16).fontWeight(FontWeight.Bold)
                .fontColor(TunBoxColors.textPrimary).width('100%')
              Text('添加远程 RULE-SET（URL+格式+策略），命中后整体应用一条策略，比逐条规则更高效。内核自动下载与定时更新，失败保留上一版。')
                .fontSize(12).fontColor(TunBoxColors.textMuted).width('100%')
              ForEach(this.ruleSets, (rs: CustomRuleSet) => {
                Row({ space: 8 }) {
                  Column({ space: 2 }) {
                    Text(`${rs.name} → ${rs.policy}`)
                      .fontSize(13).fontWeight(FontWeight.Medium).fontColor(TunBoxColors.textPrimary)
                    Text(`${rs.behavior}/${rs.format} · ${rs.url}`)
                      .fontSize(11).fontColor(TunBoxColors.textMuted).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Text('删除').fontSize(12).fontColor(TunBoxColors.danger).padding(6)
                    .onClick(() => this.removeRuleSet(rs.name))
                }.width('100%').padding(10).borderRadius(12)
                  .backgroundColor(TunBoxColors.surfaceSubtle)
                  .border({ width: 1, color: TunBoxColors.cardBorder })
              }, (rs: CustomRuleSet) => rs.name)
              TextInput({ placeholder: '名称（字母数字-_，如 my-rules）', text: this.rsName })
                .enabled(this.rulesEnabled)
                .onChange((value: string) => { this.rsName = value; })
                .height(40).fontSize(13).fontColor(TunBoxColors.textPrimary)
                .placeholderColor(TunBoxColors.textMuted)
                .backgroundColor(TunBoxColors.surfaceSubtle)
                .borderRadius(12).padding({ left: 10, right: 10 })
                .border({ width: 1, color: TunBoxColors.cardBorder })
              TextInput({ placeholder: 'https://… 规则集 URL（yaml/text/mrs）', text: this.rsUrl })
                .enabled(this.rulesEnabled)
                .onChange((value: string) => { this.rsUrl = value; })
                .height(40).fontSize(13).fontColor(TunBoxColors.textPrimary)
                .placeholderColor(TunBoxColors.textMuted)
                .backgroundColor(TunBoxColors.surfaceSubtle)
                .borderRadius(12).padding({ left: 10, right: 10 })
                .border({ width: 1, color: TunBoxColors.cardBorder })
              // 格式 chip 换行（Flex wrap，Row 无 flexWrap 属性）：窄屏下 chip 挤一行
              // 会超出卡片边界，允许换行。
              Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
                Text('格式').fontSize(12).fontColor(TunBoxColors.textMuted)
                ForEach(['yaml', 'text', 'mrs'], (f: string) => {
                  Text(f).fontSize(12).padding({ left: 10, right: 10, top: 4, bottom: 4 })
                    .borderRadius(TunBoxGeometry.pillRadius)
                    .fontColor(this.rsFormat === f ? TunBoxColors.textOnPrimary : TunBoxColors.textSecondary)
                    .backgroundColor(this.rsFormat === f ? TunBoxColors.primary : TunBoxColors.chipBg)
                    .onClick(() => { this.rsFormat = f; })
                }, (f: string) => f)
              }.width('100%')
              // 策略 chip 换行（Flex wrap）：窄屏下 REJECT/DIRECT/PROXY 三枚 chip
              // 与「策略」标签挤在一行会超出卡片边界，允许换行。
              Flex({ wrap: FlexWrap.Wrap, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
                Text('策略').fontSize(12).fontColor(TunBoxColors.textMuted)
                ForEach(['REJECT', 'DIRECT', 'PROXY'], (p: string) => {
                  Text(p).fontSize(12).padding({ left: 10, right: 10, top: 4, bottom: 4 })
                    .borderRadius(TunBoxGeometry.pillRadius)
                    .fontColor(this.rsPolicy === p ? TunBoxColors.textOnPrimary : TunBoxColors.textSecondary)
                    .backgroundColor(this.rsPolicy === p ? TunBoxColors.primary : TunBoxColors.chipBg)
                    .onClick(() => { this.rsPolicy = p; })
                }, (p: string) => p)
              }.width('100%')
              Text('添加').fontSize(14).fontWeight(FontWeight.Bold)
                .fontColor(this.rulesEnabled ? TunBoxColors.textOnPrimary : TunBoxColors.textMuted)
                .textAlign(TextAlign.Center).width('100%').padding(10)
                .borderRadius(TunBoxGeometry.controlRadius)
                .backgroundColor(this.rulesEnabled ? TunBoxColors.primary : TunBoxColors.surfaceSubtle)
                .onClick(() => this.addRuleSet())
              Text('behavior 由格式推断：yaml/text 默认 domain，可在生成器侧自动匹配 ipcidr/classical；名称将生成 rs-<名称> 的 provider 键。')
                .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
            }
            .width('100%')
            .padding(TunBoxGeometry.cardPadding)
            .backgroundColor(TunBoxColors.surfaceCard)
            .borderRadius(TunBoxGeometry.cardRadius)
            .border({ width: 1, color: TunBoxColors.cardBorder })
            // ── YAML 覆盖层（P2）：对标 Stash JS Override 的无脚本形态 ──
            Column({ space: 10 }) {
              Text('YAML 覆盖层').fontSize(16).fontWeight(FontWeight.Bold)
                .fontColor(TunBoxColors.textPrimary).width('100%')
              Text('追加在生成配置尾部的高级 YAML 片段，同名键覆盖默认值（如 sniffer/keep-alive/profile）。rules/proxies/proxy-groups/external-controller/secret/tun 六键被拦截，由程序管理。')
                .fontSize(12).fontColor(TunBoxColors.textMuted).width('100%')
              TextArea({ placeholder: '如：\nprofile:\n  store-selected: true', text: this.yamlOverrideText })
                .enabled(true)
                .onChange((value: string) => { this.yamlOverrideText = value; })
                .width('100%').height(120)
                .fontSize(12).fontFamily('monospace').lineHeight(20)
                .fontColor(TunBoxColors.codeText)
                .placeholderColor(TunBoxColors.textMuted)
                .backgroundColor(TunBoxColors.codeBg)
                .borderRadius(14)
                .padding(12)
                .border({ width: 1, color: TunBoxColors.codeBorder })
              Text('保存').fontSize(14).fontWeight(FontWeight.Bold)
                .fontColor(TunBoxColors.textOnPrimary)
                .textAlign(TextAlign.Center).width('100%').padding(10)
                .borderRadius(TunBoxGeometry.controlRadius)
                .backgroundColor(TunBoxColors.primary)
                .onClick(() => this.saveYamlOverride())
            }
            .width('100%')
            .padding(TunBoxGeometry.cardPadding)
            .backgroundColor(TunBoxColors.surfaceCard)
            .borderRadius(TunBoxGeometry.cardRadius)
            .border({ width: 1, color: TunBoxColors.cardBorder })
            // 页签页底部为悬浮 Dock 预留（契约：≥ TunBoxGeometry.dockClearance）
            Blank().height(TunBoxGeometry.dockClearance)
          }.width('100%')
          .padding({
            left: TunBoxGeometry.pagePadding, right: TunBoxGeometry.pagePadding, top: 8, bottom: 8
          })
        }.width('100%').layoutWeight(1).scrollBar(BarState.Off) .edgeEffect(EdgeEffect.Spring)
      }.width('100%').height('100%')
    }.width('100%').height('100%')
  }
}

/**
 * 路由兼容入口（2026-10-17 UI 重构）：规则页内容已抽为 RulesView，
 * 底部页签（MainPage）直接挂 RulesView；外部推入 / 深链仍走本 @Entry 页。
 */
@Entry
@Component
struct RulesPage {
  @StorageLink('theme_revision') themeRevision: number = 0;
  private bridge: TabLifecycleBridge = new TabLifecycleBridge();

  onPageShow(): void {
    this.bridge.notifyShown();
  }

  build() {
    // @Entry 的 build 根必须是容器组件，故用 Stack 承载页签内容视图
    Stack() {
      RulesView({ shownBridge: this.bridge })
    }
    .width('100%')
    .height('100%')
  }

  /** 路由推入式子页统一转场：水平滑动 + 淡入淡出（与页签切换同规格，见 TunBoxMotion） */
  pageTransition() {
    PageTransitionEnter({ duration: TunBoxMotion.ms, curve: TunBoxMotion.curve })
      .translate({ x: TunBoxMotion.slidePercent, y: 0 }).opacity(0)
    PageTransitionExit({ duration: TunBoxMotion.ms, curve: TunBoxMotion.curve })
      .translate({ x: `-${TunBoxMotion.slidePercent}`, y: 0 }).opacity(0)
  }
}
