import { promptAction } from '@kit.ArkUI';
import { TunBoxColors, TunBoxGeometry, TunBoxMotion } from '../theme/TunBoxTokens';
import { TunBoxTextColors } from '../theme/TextColors';
import { TopNavBar } from '../components/TopNavBar';
import { ProfileRepository } from '../commons/tunbox/ProfileRepository';
import { ProfileOverrideStore } from '../commons/services/ProfileOverrideStore';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';
import { SubscriptionService } from '../commons/services/SubscriptionService';
import { Subscription } from '../commons/models/Subscription';
import { ImportFilePolicy } from '../commons/services/ImportFilePolicy';
import { AppLogger } from '../commons/utils/AppLogger';

/**
 * 配置编辑器（FlClash profile 编辑器的鸿蒙等价物）。
 *
 * 1) 整份 YAML 编辑：保存前走与订阅导入同一条 `ProfileRepository.validateAndStore`
 *    （原生 preparer 展开锚点 + 校验）；失败**不覆盖旧文件**并显示真实原因。
 * 2) 每订阅 Override（FlClash `Profile.overrides`）：只作用于当前 profile 的 YAML 尾部
 *    覆盖，与全局 `yamlOverride` 合并语义相同但按 profile 隔离。
 *
 * 保存后若已连接，走 `ensureProfileApplied` 既有热重载（PUT /configs，不重建 TUN）。
 */
@Entry
@Component
struct ProfileEditorPage {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @State private text: string = '';
  @State private overrideText: string = '';
  @State private profileName: string = '';
  @State private profileId: string = '';
  @State private busy: boolean = false;
  @State private status: string = '';
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private subs: SubscriptionService = SubscriptionService.instance();

  aboutToAppear(): void {
    this.load();
  }

  private load(): void {
    const applied: string = this.orchestrator.appliedProfile();
    const id: string = applied.length > 0 ? applied : ProfileRepository.currentId();
    this.profileId = id;
    if (id.length === 0) {
      this.status = '还没有可编辑的订阅配置';
      return;
    }
    this.text = ProfileRepository.read(id);
    this.overrideText = ProfileOverrideStore.get(id);
    const sub: Subscription | undefined = this.subs.subscriptions.find(
      (s: Subscription): boolean => s.id === id);
    this.profileName = sub !== undefined ? sub.name : id;
    this.status = '';
  }

  private toast(message: string): void {
    try {
      promptAction.showToast({ message: message, duration: 3000 });
    } catch (e) {
      // 提示失败不影响保存结论
    }
  }

  private async save(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.profileId.length === 0) {
      this.toast('没有可保存的配置');
      return;
    }
    const body: string = this.text.trim();
    if (body.length === 0) {
      this.toast('配置内容为空');
      return;
    }
    if (body.length > ImportFilePolicy.YAML_MAX_BYTES) {
      this.toast(ImportFilePolicy.tooLarge('配置文件', ImportFilePolicy.YAML_MAX_BYTES));
      return;
    }
    if (this.overrideText.trim().length > ImportFilePolicy.YAML_OVERRIDE_MAX_CHARS) {
      this.toast(`覆盖层过长（上限 ${ImportFilePolicy.YAML_OVERRIDE_MAX_CHARS} 字符）`);
      return;
    }
    this.busy = true;
    this.status = '保存中…';
    try {
      const result = await ProfileRepository.validateAndStore(this.profileId, body);
      if (!result.ok) {
        this.status = result.message;
        this.toast(result.message);
        return;
      }
      const saved: boolean = await ProfileOverrideStore.set(this.profileId, this.overrideText);
      if (!saved && this.overrideText.trim().length > 0) {
        this.status = '配置已保存，但覆盖层落盘失败';
        this.toast(this.status);
        return;
      }
      const applied: boolean = await this.orchestrator.ensureProfileApplied('profile-editor');
      this.status = applied ? '已保存并应用' : '已保存；连接后生效';
      this.toast(this.status);
      // native preparer 会规范化（展开锚点/统一缩进），回读让用户看到内核将读到的文本
      this.text = ProfileRepository.read(this.profileId);
    } catch (e) {
      const reason: string = AppLogger.errText(e);
      this.status = `保存失败｜${reason}`;
      this.toast(this.status);
    } finally {
      this.busy = false;
    }
  }

  /** 路由推入式子页统一转场：水平滑动 + 淡入淡出（与页签切换同规格，见 TunBoxMotion） */
  pageTransition() {
    PageTransitionEnter({ duration: TunBoxMotion.ms, curve: TunBoxMotion.curve })
      .translate({ x: TunBoxMotion.slidePercent, y: 0 }).opacity(0)
    PageTransitionExit({ duration: TunBoxMotion.ms, curve: TunBoxMotion.curve })
      .translate({ x: `-${TunBoxMotion.slidePercent}`, y: 0 }).opacity(0)
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column()
        .width('100%').height('100%')
        .linearGradient({
          angle: 180,
          colors: [[TunBoxColors.bgGradientStart(this.themeRevision), 0.0],
            [TunBoxColors.bgGradientEnd(this.themeRevision), 1.0]]
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        TopNavBar({ title: '配置编辑', hasBack: true })
        Scroll() {
          Column({ space: 12 }) {
            Row({ space: 8 }) {
              Text(this.profileName.length > 0 ? this.profileName : '未选择')
                .fontSize(15).fontWeight(FontWeight.Bold)
                .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
                .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.busy ? '处理中' : '可编辑')
                .fontSize(11).fontColor(TunBoxTextColors.secondaryFor(this.themeRevision))
            }.width('100%')

            Text('整份配置（保存前走与导入相同的校验；失败保留旧配置）')
              .fontSize(12).fontColor(TunBoxTextColors.secondaryFor(this.themeRevision)).width('100%')
            TextArea({ text: this.text, placeholder: 'proxies:\nproxy-groups:\nrules:' })
              .height(340).width('100%').maxLength(ImportFilePolicy.YAML_MAX_BYTES)
              .fontSize(12)
              .backgroundColor(TunBoxColors.surfaceCard(this.themeRevision))
              .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
              .onChange((value: string) => { this.text = value; })
            Text(`${this.text.length} 字符`)
              .fontSize(10).fontColor(TunBoxTextColors.secondaryFor(this.themeRevision)).width('100%')

            Text(`覆盖层（仅本订阅；YAML 尾部合并，上限 ${ImportFilePolicy.YAML_OVERRIDE_MAX_CHARS} 字符）`)
              .fontSize(12).fontColor(TunBoxTextColors.secondaryFor(this.themeRevision)).width('100%')
            TextArea({ text: this.overrideText, placeholder: '如：\nprofile:\n  store-selected: true' })
              .height(150).width('100%').maxLength(ImportFilePolicy.YAML_OVERRIDE_MAX_CHARS)
              .fontSize(12)
              .backgroundColor(TunBoxColors.surfaceCard(this.themeRevision))
              .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
              .onChange((value: string) => { this.overrideText = value; })

            Row({ space: 12 }) {
              Button('保存并应用')
                .layoutWeight(2).enabled(!this.busy)
                .backgroundColor(this.busy ? TunBoxColors.textMutedFor(this.themeRevision)
                  : TunBoxColors.primaryFor(this.themeRevision))
                .fontColor(TunBoxColors.textOnPrimary)
                .onClick(() => { this.save(); })
              Button('还原')
                .layoutWeight(1).enabled(!this.busy)
                .backgroundColor(TunBoxColors.surfaceCard(this.themeRevision))
                .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
                .onClick(() => { this.load(); this.toast('已还原为磁盘内容'); })
            }.width('100%')

            if (this.status.length > 0) {
              Text(this.status)
                .fontSize(12).width('100%')
                .fontColor(TunBoxTextColors.secondaryFor(this.themeRevision))
            }
          }
          .width('100%')
          .padding({
            left: TunBoxGeometry.pagePadding, right: TunBoxGeometry.pagePadding,
            top: 8, bottom: 40
          })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
