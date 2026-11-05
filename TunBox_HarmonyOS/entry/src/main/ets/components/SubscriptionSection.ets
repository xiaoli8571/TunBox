/**
 * 主页订阅区块（对齐 ClashPlus 1.2.7 主页 profiles 卡片 + 全屏节点面板）
 *
 * ## 2026-10-28 定稿形态
 * 1. 卡片：图标 + 订阅名 + 更新时间/节点数；右上三个动作（测速 / 编辑 / 刷新）；
 *    ↑/↓/总量 + 流量进度条 + 到期文案。
 * 2. 点卡片 → **全屏覆盖**节点面板：顶部返回、底部玻璃返回按钮；
 *    面板顶部是**订阅自带分组**（PROXY / AUTO / …）chips，选组列成员；点节点即切换并退出。
 * 3. 区块标题右侧是**菜单按钮**（原「管理」入口已删除、订阅管理页已并入本区块）：
 *    添加订阅 / 刷新全部 / 测速全部 / 删除订阅。
 */
import { promptAction, window, display , LengthMetrics} from '@kit.ArkUI';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import scanBarcode from '@hms.core.scan.scanBarcode';
import { TunBoxColors, TunBoxGeometry, TunBoxPing } from '../theme/TunBoxTokens';
import { TunBoxTextColors } from '../theme/TextColors';
import { SubscriptionSummary } from '../commons/utils/SubscriptionSummary';
import { SubscriptionService } from '../commons/services/SubscriptionService';
import { Subscription, SubscriptionRefreshStatus } from '../commons/models/Subscription';
import { ProxyNode } from '../commons/models/ProxyNode';
import { ProxyGroup } from '../commons/models/ProxyGroup';
import { SettingsService } from '../commons/services/SettingsService';
import { AppSettings, AutoSelectModes } from '../commons/models/AppSettings';
import { ConnectionOrchestrator, ConnState } from '../commons/services/ConnectionOrchestrator';
import { LatencyStoreBridge } from '../commons/services/LatencyStoreBridge';
import { BackgroundLatencyService } from '../commons/services/BackgroundLatencyService';
import { NodeProtocolPolicy } from '../commons/services/NodeSortPersistence';
import { ProfileRepository } from '../commons/tunbox/ProfileRepository';
import { ProfileConfigMerger } from '../commons/tunbox/ProfileConfigMerger';
// 转换导出物补骨架（仅导出/导入产物链路；内核准入不再合成组，见 withExportSkeleton）
import { YamlMerger } from '../commons/services/YamlMerger';
import { SubConverter } from '../commons/tunbox/SubConverter';
import { SubscriptionFetchPolicy } from '../commons/services/SubscriptionFetchPolicy';
import { ImportFilePolicy } from '../commons/services/ImportFilePolicy';
import { ImportFailureSummary } from '../commons/services/ImportFailureSummary';
import { MIN_UPDATE_INTERVAL_MINUTES, MAX_UPDATE_INTERVAL_MINUTES } from '../commons/services/SubscriptionUpdateScheduler';
import { CoreNodeBridge } from '../commons/tunbox/CoreNodeBridge';
import { CoreCatalogService } from '../commons/tunbox/CoreCatalogService';
import { CoreGroup, CoreCatalogModel } from '../commons/tunbox/CoreCatalog';
import { LatencyContext, LatencyRecord, LatencyState } from '../commons/services/LatencyState';
import { ProxyPanelMembers } from '../commons/tunbox/ProxyPanelMembers';
import { AppLogger } from '../commons/utils/AppLogger';

const TAG = 'SubscriptionSection';

/**
 * 文档 URI → 可显示文件名（解码 `%XX`；解不出就原样返回）。
 *
 * 系统 picker 返回的是编码过的 URI（`.../%E4%B8%AD%E6%96%87.yaml`），
 * 旧实现直接截最后一段当订阅名，卡片上就会出现一串 `%E4%B8%AD...`。
 */
function fileNameFromUri(uri: string): string {
  const raw: string = uri.substring(uri.lastIndexOf('/') + 1);
  try {
    return decodeURIComponent(raw);
  } catch (e) {
    return raw;
  }
}
/** 节点行高（vp） */
const NODE_ROW_H: number = 52;

/** 仅在原生校验明确要求密钥时打开，取消不会修改旧配置。 */
@CustomDialog
struct AgeKeyDialog {
  controller?: CustomDialogController;
  @StorageLink('theme_revision') themeRevision: number = 0;
  @State keyText: string = '';
  onComplete: (key: string) => void = () => {};

  build() {
    Column({ space: 16 }) {
      Text('解密订阅').fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
      Text('请输入此订阅的 age 密钥').fontSize(14)
        .fontColor(TunBoxTextColors.secondaryFor(this.themeRevision))
      TextInput({ placeholder: 'AGE-SECRET-KEY-…', text: this.keyText })
        .type(InputType.Password)
        .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
        .backgroundColor(TunBoxColors.surfaceSubtle(this.themeRevision))
        .onChange((value: string): void => { this.keyText = value; })
      Row({ space: 16 }) {
        Button('取消').onClick((): void => {
          this.keyText = '';
          this.onComplete('');
          this.controller?.close();
        })
        Button('解密').enabled(this.keyText.trim().length > 0).onClick((): void => {
          const key = this.keyText.trim();
          this.keyText = '';
          this.onComplete(key);
          this.controller?.close();
        })
      }
    }
    .padding(24).width('88%').constraintSize({ maxWidth: 420 })
    .backgroundColor(TunBoxColors.surfaceSubtle(this.themeRevision)).borderRadius(20)
  }
}

/** 添加订阅弹窗：三种模式（URL / 扫码 / 文件），白底实色，水平垂直居中 */
@CustomDialog
struct AddSubDialog {
  controller?: CustomDialogController;
  /** 仅供配色 token 登记重绘依赖：样式方法形参必须真的读到修订号，否则切背景不重绘（2026-10-28 真机取证） */
  @StorageLink('theme_revision') themeRevision: number = 0;
  @State mode: string = 'url';
  @State nameText: string = '';
  @State urlText: string = '';
  @State busy: boolean = false;
  @State allowInsecure: boolean = false;
  @State convertText: string = '';
  @State exportConvertedYaml: boolean = false;
  getAllowInsecure: () => boolean = () => false;
  onToggleInsecure: (v: boolean) => void = () => {};
  onAddUrl: (name: string, url: string) => void = () => {};
  onConvert: (text: string, exportFile: boolean) => void = () => {};
  onScan: () => void = () => {};
  onPickFile: () => void = () => {};

  aboutToAppear(): void {
    this.allowInsecure = this.getAllowInsecure();
  }

  build() {
    Column({ space: 14 }) {
      Text('添加订阅')
        .fontSize(17).fontWeight(FontWeight.Bold).fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
        .width('100%')

      // 三模式切换
      Row({ space: 6 }) {
        this.ModeChip('二维码', 'qr')
        this.ModeChip('URL', 'url')
        this.ModeChip('文件', 'file')
        this.ModeChip('转换', 'convert')
      }
      .width('100%')

      if (this.mode === 'url') {
        TextInput({ placeholder: '订阅名称（可选）', text: this.nameText })
          .onChange((v: string) => { this.nameText = v; })
          .height(44).borderRadius(12).fontSize(14)
          .backgroundColor(TunBoxColors.surfaceSubtle(this.themeRevision))
          .borderWidth(1).borderColor(TunBoxColors.cardBorder(this.themeRevision))
          .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
        TextInput({ placeholder: 'https://example.com/sub', text: this.urlText })
          .onChange((v: string) => { this.urlText = v; })
          .height(44).borderRadius(12).fontSize(13)
          .backgroundColor(TunBoxColors.surfaceSubtle(this.themeRevision))
          .borderWidth(1).borderColor(TunBoxColors.cardBorder(this.themeRevision))
          .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
        // 2026-10-28 用户要求：明文 HTTP 开关从设置页挪到这里（只影响订阅拉取）
        Row() {
          Text('允许明文 HTTP 订阅')
            .fontSize(13).fontColor(TunBoxTextColors.primaryFor(this.themeRevision)).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.allowInsecure })
            .selectedColor(TunBoxColors.primaryFor(this.themeRevision))
            .onChange((v: boolean) => {
              this.allowInsecure = v;
              this.onToggleInsecure(v);
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      } else if (this.mode === 'qr') {
        Column({ space: 8 }) {
          Image($r('app.media.ic_globe')).width(48).height(48).fillColor(TunBoxColors.textMutedFor(this.themeRevision))
          Text('扫描订阅二维码').fontSize(13).fontColor(TunBoxTextColors.secondaryFor(this.themeRevision))
          Text('二维码内容需是 Clash 订阅链接').fontSize(11).fontColor(TunBoxTextColors.mutedFor(this.themeRevision))
        }
        .width('100%')
        .padding({ top: 20, bottom: 20 })
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(TunBoxColors.surfaceSubtle(this.themeRevision))
        .borderRadius(12)
      } else if (this.mode === 'convert') {
        TextArea({ placeholder: '粘贴分享链接（单条/多条/base64）', text: this.convertText })
          .onChange((v: string) => { this.convertText = v; })
          .height(120).borderRadius(12).fontSize(12)
          .backgroundColor(TunBoxColors.surfaceSubtle(this.themeRevision))
          .borderWidth(1).borderColor(TunBoxColors.cardBorder(this.themeRevision))
          .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
        Row({ space: 8 }) {
          this.ConvertOutputChoice('直接导入 TunBox', false)
          this.ConvertOutputChoice('导出 YAML 文件', true)
        }.width('100%')
        Text(this.exportConvertedYaml ? '转换后选择本机保存位置。' : '转换后加入 TunBox 订阅列表。')
          .fontSize(11).fontColor(TunBoxTextColors.mutedFor(this.themeRevision)).width('100%')
      } else {
        Column({ space: 8 }) {
          Image($r('app.media.ic_doc')).width(48).height(48).fillColor(TunBoxColors.textMutedFor(this.themeRevision))
          Text('从文件导入').fontSize(13).fontColor(TunBoxTextColors.secondaryFor(this.themeRevision))
          Text('支持 .yaml / .yml（Clash 配置，8MB 以内）').fontSize(11).fontColor(TunBoxTextColors.mutedFor(this.themeRevision))
        }
        .width('100%')
        .padding({ top: 20, bottom: 20 })
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(TunBoxColors.surfaceSubtle(this.themeRevision))
        .borderRadius(12)
      }

      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).height(44).borderRadius(12).fontSize(14)
          .backgroundColor(TunBoxColors.surfaceSubtle(this.themeRevision)).fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button(this.mode === 'url' ? '添加' : (this.mode === 'convert' ? (this.exportConvertedYaml ? '转换并导出' : '转换并导入') : '开始'))
          .layoutWeight(1).height(44).borderRadius(12).fontSize(14)
          .backgroundColor(TunBoxColors.primaryFor(this.themeRevision)).fontColor(Color.White)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
            if (this.mode === 'url') {
              this.onAddUrl(this.nameText, this.urlText);
            } else if (this.mode === 'qr') {
              this.onScan();
            } else if (this.mode === 'convert') {
              this.onConvert(this.convertText, this.exportConvertedYaml);
            } else {
              this.onPickFile();
            }
          })
      }.width('100%')
    }
    .width('86%')
    .padding(20)
    .backgroundColor(TunBoxColors.surfaceCard(this.themeRevision))
    .borderRadius(20)
    .border({ width: 1, color: TunBoxColors.cardBorder(this.themeRevision) })
  }

  @Builder
  ConvertOutputChoice(label: string, exportFile: boolean) {
    Button(label)
      .layoutWeight(1).height(38).borderRadius(10).fontSize(12)
      .fontColor(this.exportConvertedYaml === exportFile ? TunBoxColors.textOnPrimary : TunBoxTextColors.secondaryFor(this.themeRevision))
      .backgroundColor(this.exportConvertedYaml === exportFile
        ? TunBoxColors.primaryFor(this.themeRevision) : TunBoxColors.chipBg(this.themeRevision))
      .onClick(() => { this.exportConvertedYaml = exportFile; })
  }

  @Builder
  ModeChip(label: string, value: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.mode === value ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.mode === value ? TunBoxColors.textOnPrimary : TunBoxTextColors.secondaryFor(this.themeRevision))
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(36)
      .borderRadius(10)
      .backgroundColor(this.mode === value ? TunBoxColors.primaryFor(this.themeRevision) : TunBoxColors.chipBg(this.themeRevision))
      .onClick(() => { this.mode = value; })
  }
}

/** 编辑配置信息弹窗（对齐 ClashPlus 的「编辑配置信息」：实色底、居中弹出） */
@CustomDialog
struct EditSubDialog {
  controller?: CustomDialogController;
  /** 仅供配色 token 登记重绘依赖（同 AddSubDialog，2026-10-28） */
  @StorageLink('theme_revision') themeRevision: number = 0;
  @State editName: string = '';
  @State editUrl: string = '';
  @State autoUpdate: boolean = true;
  /** 自动更新间隔（分钟）：可编辑（2026-10-29 用户要求） */
  @State editInterval: string = '360';
  /**
   * 字段区高度上限（vp）。
   * 2026-10-29 用户报「键盘弹出前弹窗大小正常，弹出后变细长」。
   * 真机量化：弹窗内容高约 490vp（平板 1078vp 屏上只整体上移、尺寸一字不变；
   * 手机竖屏可用高度仅约 480vp），放不下时 ArkUI 会压缩/缩放整个弹窗 ⇒ 宽度跟着缩。
   * 这里给字段区一个上限、超出部分内部滚动，弹窗总高就永远小于键盘上方空间。
   */
  @State private fieldsMaxH: number = 320;
  getInitialName: () => string = () => '';
  getInitialUrl: () => string = () => '';
  getAutoUpdate: () => boolean = () => true;
  getIntervalText: () => string = () => '360';
  onConfirm: (name: string, url: string, autoUpdate: boolean, intervalMinutes: number) => void = () => {};
  onDelete: () => void = () => {};

  aboutToAppear(): void {
    this.editName = this.getInitialName();
    this.editUrl = this.getInitialUrl();
    this.autoUpdate = this.getAutoUpdate();
    const init: string = this.getIntervalText();
    this.editInterval = init.length > 0 ? init : '360';
    // 字段区上限 = 屏幕高 60% 减标题/按钮/内边距等固定部分（约 190vp）。
    // 大屏（如平板 1078vp）算出的上限大于内容高度 ⇒ 完全不生效，尺寸与原来一致；
    // 小屏（如手机 780vp）上限约 278vp ⇒ 字段区滚动，弹窗总高约 458vp，放得进键盘上方。
    try {
      const disp = display.getDefaultDisplaySync();
      const screenH: number = px2vp(disp.height);
      this.fieldsMaxH = Math.max(160, Math.round(screenH * 0.6) - 190);
    } catch (e) {
      this.fieldsMaxH = 320;
    }
  }

  /**
   * 间隔输入解析：非数字 / 越界一律**夹到合法区间**（15 分钟~7 天）。
   * 不能直接透传用户输入 —— 存成 0 会让调度器每次都判定「过期」，一开机就疯狂拉订阅。
   */
  private intervalValue(): number {
    const n: number = Number(this.editInterval.trim());
    if (!Number.isFinite(n)) {
      return 360;
    }
    const m: number = Math.floor(n);
    if (m < MIN_UPDATE_INTERVAL_MINUTES) {
      return MIN_UPDATE_INTERVAL_MINUTES;
    }
    if (m > MAX_UPDATE_INTERVAL_MINUTES) {
      return MAX_UPDATE_INTERVAL_MINUTES;
    }
    return m;
  }

  build() {
    Column({ space: 12 }) {
      Text('编辑配置信息')
        .fontSize(17).fontWeight(FontWeight.Bold).fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
        .width('100%')

      // ── 字段区：可滚动 + 高度上限（2026-10-29 用户报「键盘弹出后弹窗变细长」）──
      Scroll() {
        Column({ space: 12 }) {
      Text('配置名称').fontSize(12).fontColor(TunBoxTextColors.mutedFor(this.themeRevision)).width('100%')
      TextInput({ text: this.editName, placeholder: '配置名称' })
        .onChange((v: string) => { this.editName = v; })
        .height(44).borderRadius(12).fontSize(14)
        .backgroundColor(TunBoxColors.surfaceSubtle(this.themeRevision))
        .borderWidth(1).borderColor(TunBoxColors.cardBorder(this.themeRevision))
        .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))

      Text('订阅链接或 URL').fontSize(12).fontColor(TunBoxTextColors.mutedFor(this.themeRevision)).width('100%')
      TextInput({ text: this.editUrl, placeholder: 'https://example.com/sub' })
        .onChange((v: string) => { this.editUrl = v; })
        .height(44).borderRadius(12).fontSize(13)
        .backgroundColor(TunBoxColors.surfaceSubtle(this.themeRevision))
        .borderWidth(1).borderColor(TunBoxColors.cardBorder(this.themeRevision))
        .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))

      Row() {
        Text('自动更新').fontSize(14).fontColor(TunBoxTextColors.primaryFor(this.themeRevision)).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.autoUpdate })
          .selectedColor(TunBoxColors.primaryFor(this.themeRevision))
          .onChange((v: boolean) => { this.autoUpdate = v; })
      }.width('100%').alignItems(VerticalAlign.Center)

      Text('自动更新间隔（分钟）').fontSize(12).fontColor(TunBoxTextColors.mutedFor(this.themeRevision)).width('100%')
      // 可自定义（2026-10-29 用户要求）：以前这里是一个只读 Row + 「跟随系统」文案，
      // 值由 `return '360'` 写死，用户根本改不了。现在换成数字输入框。
      Row({ space: 6 }) {
        Image($r('app.media.ic_refresh')).width(14).height(14).fillColor(TunBoxColors.textMutedFor(this.themeRevision))
        TextInput({ text: this.editInterval, placeholder: '360' })
          .type(InputType.Number)
          .maxLength(5)
          .onChange((v: string) => { this.editInterval = v; })
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .borderRadius(0)
          .padding({ left: 0, right: 0 })
          .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
        Text('分钟').fontSize(11).fontColor(TunBoxTextColors.mutedFor(this.themeRevision)).flexShrink(0)
      }
      .width('100%').height(44)
      .padding({ left: 12, right: 12 })
      .borderRadius(12)
      .backgroundColor(TunBoxColors.surfaceSubtle(this.themeRevision))
      .borderWidth(1).borderColor(TunBoxColors.cardBorder(this.themeRevision))
      .alignItems(VerticalAlign.Center)

      Text(`范围 ${MIN_UPDATE_INTERVAL_MINUTES}~${MAX_UPDATE_INTERVAL_MINUTES} 分钟，超出自动取边界值 · 只影响这一个订阅`)
        .fontSize(10).fontColor(TunBoxTextColors.mutedFor(this.themeRevision)).width('100%')
        }
        .width('100%')
      }
      .width('100%')
      .scrollBar(BarState.Off)
      .constraintSize({ maxHeight: this.fieldsMaxH })

      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).height(44).borderRadius(12).fontSize(14)
          .backgroundColor(TunBoxColors.surfaceSubtle(this.themeRevision)).fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
          })
        Button('保存更改').layoutWeight(1).height(44).borderRadius(12).fontSize(14)
          .backgroundColor(TunBoxColors.primaryFor(this.themeRevision)).fontColor(Color.White)
          .onClick(() => {
            if (this.controller !== undefined) {
              this.controller.close();
            }
            this.onConfirm(this.editName, this.editUrl, this.autoUpdate, this.intervalValue());
          })
      }.width('100%')

      Button('删除').width('100%').height(44).borderRadius(12).fontSize(14)
        .backgroundColor(TunBoxColors.dangerLight).fontColor(TunBoxColors.danger)
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
          this.onDelete();
        })
    }
    // 尺寸固定（2026-10-28 用户要求：居中弹窗，键盘弹出不改宽高）：
    // 宽度按屏宽比例、高度由内容决定 —— 两者都不跟随键盘变化（避让只用 OFFSET 上移）。
    .width('86%')
    .padding({ left: 20, right: 20, top: 24, bottom: 20 })
    // 实色底（2026-10-28 用户要求：不要沉浸材质，要白底实色卡片）
    .backgroundColor(TunBoxColors.surfaceCard(this.themeRevision))
    .borderRadius(20)
    .border({ width: 1, color: TunBoxColors.cardBorder(this.themeRevision) })
  }
}

/**
 * 订阅卡片纵向间距（vp）：必须与 build() 里 `Column({ space: 10 })` 一致。
 * 长按拖动排序用「实测卡片高度 + 本间距」累计，判断当前拖到了第几张。
 */
const SUB_CARD_SPACE: number = 10;

/**
 * 给「裸节点表」补上最简可用的分流骨架 —— **仅用于订阅转换的导出/导入产物**。
 *
 * FlClash 全量照抄（2026-11-05）后，内核配置链不再合成组（compose 接管，
 * GLOBAL 兜底，准入不做自有推断）；但转换导出的 YAML 是交给其他 Clash 客户端的
 * 用户产物，裸 proxies 表在那些客户端里没法直接路由，本函数只在导出/导入产物上补骨架。
 *
 * 触发条件：原文有 `proxies`，但没有 proxy-groups / proxy-providers / rules。
 * 骨架刻意最小：手动选择(select, 全部节点 + DIRECT) / 自动选择(url-test) /
 * rules: MATCH,手动选择。原文已有任何组或规则时原样返回，不介入。
 */
/**
 * R5 收口：内容是不是「分享链接列表」（FlClash convert.ConvertsV2Ray 的输入形态）。
 * 只识别上游 convert 覆盖的三种形态——逐行 scheme 链接、整体 base64、纯行文本——
 * 不再猜「是不是 Clash 配置」：Clash YAML/JSON 一律原样交给内核校验（§5.3）。
 */
function looksLikeShareLinkBody(body: string): boolean {
  const text = body.trim();
  if (text.length === 0) {
    return false;
  }
  const schemeRe = /^[a-z][a-z0-9+.-]*:\/\//i;
  const lines: string[] = text.split(/\r?\n/).map((l: string): string => l.trim())
    .filter((l: string): boolean => l.length > 0);
  const schemeLines = lines.filter((l: string): boolean => schemeRe.test(l)).length;
  if (lines.length > 0 && schemeLines === lines.length) {
    return true;
  }
  // 整体 base64（decode 后必然出现 scheme 链接）交给 BodyDispatch/SubConverter 判定
  if (!/[：:{}]/.test(text) && /^[A-Za-z0-9+/=\s]+$/.test(text) && text.replace(/\s+/g, '').length >= 32) {
    return true;
  }
  return false;
}

function withExportSkeleton(profileYaml: string): string {  if (profileYaml.includes('proxy-groups:')
    || profileYaml.includes('proxy-providers:')
    || profileYaml.includes('rules')) {
    return profileYaml;
  }
  const LF: string = String.fromCharCode(10);
  const SQ: string = String.fromCharCode(39);
  const names = YamlMerger.sequenceItemNames(profileYaml, 'proxies');
  if (names.length === 0) {
    return profileYaml;
  }
  const lines: string[] = [profileYaml.trimEnd(), '', 'proxy-groups:',
    '  - name: 手动选择', '    type: select', '    proxies:'];
  for (const n of names) {
    lines.push(`      - '${n.split(SQ).join(SQ + SQ)}'`);
  }
  lines.push('      - DIRECT');
  // 刻意不写 url：mihomo 的 url-test 默认 URL 就是 generate_204（constant.DefaultURLTestURL），
  // 写死会违反 ND06「测速地址规则常量只能有一处」（真源在 TunBoxDelay.TUNBOX_DELAY_URL）。
  lines.push('  - name: 自动选择', '    type: url-test',
    '    interval: 300', '    tolerance: 50', '    proxies:');
  for (const n of names) {
    lines.push(`      - '${n.split(SQ).join(SQ + SQ)}'`);
  }
  lines.push('rules:', '  - MATCH,手动选择');
  return lines.join(LF);
}

@Component
export struct SubscriptionSection {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @StorageLink('smart_model_seq') @Watch('refreshSmartEntry') smartModelSeq: number = 0;
  @State private smartVisible: boolean = false;
  @State private smartSelected: boolean = false;
  private smartRefreshRevision: number = 0;
  @State private subs: Subscription[] = [];
  @State private showPanel: boolean = false;
  @State private panelSubId: string = '';
  @State private selectedGroup: string = '';
  @State private currentProfileId: string = '';
  @State private currentNodeName: string = '';
  @State private coreRevision: number = 0;
  @State private latencyRevision: number = 0;
  @State private refreshingIds: string[] = [];
  @State private testingIds: string[] = [];
  @State private sortByDelay: boolean = true;
  /**
   * 节点列表排布（2026-11-03 用户要求：「按延迟」左边加一个双列 / 单列切换按钮）。
   * false = 单列（沿用原来一行一节点），true = 双列紧凑单元格（一行两个）。
   * 与 `sortByDelay` 一样是面板内的即时状态，不进 AppSettings。
   */
  @State private gridMode: boolean = false;
  @State private selectingMember: string = '';
  /**
   * 「长按删除节点」底部弹层（2026-10-29 用户要求：“长按任意节点底部弹删除框，
   * 可以多选也可以单独删除”）。
   * 长按时只勾中该节点（= 单独删除），再点其它行就变成多选，最后一次性提交。
   */
  @State private deleteSheetOn: boolean = false;
  @State private deleteSheetIds: string[] = [];
  /**
   * 节点集合变更计数。
   * 真删后 `service.nodes` 是内部数组变更，只调 `reload()` 拿到的是「同内容新数组」，
   * ForEach 的 key 拼了它才能判定「这一行真的没了」——否则删完列表还看得见。
   */
  @State private nodeRevision: number = 0;
  /**
   * 面板顶部「♻️ 自动选择」入口（2026-10-29 用户口径：
   * **每个订阅展开后都要有自己的自动选择行**）。
   * 展示条件：模型就绪 + 本订阅真实节点 ≥ 2（<2 时内核会退回全量池，展示反而误导）。
   * 选中条件：自动模式 + 作用域就是本订阅。
   * 之所以落到 @State：`settings` 是普通字段（非 @State），直接读它不会触发重算，
   * 真机表现就是「点了没高亮」。
   */
  /**
   * 长按后紧跟的那次 onClick 要丢掉。
   * 真机手势时序：LongPressGesture 触发后抬手仍会走 onClick，
   * 不拦就会「一边弹删除框、一边把这个节点设成当前节点并重连」。
   */
  private suppressClick: boolean = false;
  /**
   * 覆盖层展开/收起动画标志。
   * 2026-10-28 用户报障「第一条订阅展开是从上往下、后面的订阅展开效果不一样」：
   * 旧实现按卡片在列表中的下标算了一个 `panelOriginY` 作为展开起点偏移，
   * 首条（下标 0）偏移为 0、后面的卡片偏移越来越大 → 同一个弹层出现多种展开轨迹。
   * 现在**统一用首条订阅的展开效果**（纯缩放 + 淡入，无纵向位移）。
   */
  @State private panelAnimating: boolean = false;
  /** 状态栏高度（vp）：全屏覆盖层内容要从状态栏之下起排 */
  @State private statusBarH: number = 24;

  // ── 长按拖动排序（2026-10-30 用户要求：长按订阅可以拖动排序）──
  /** 正在拖动的订阅 id（'' = 未拖动）；同时用作「是否处于拖动中」的总闸门 */
  @State private dragSubId: string = '';
  /** 拖动纵向位移（vp）：被拖卡片跟手平移 */
  @State private dragDy: number = 0;
  /** 拖动起始下标 / 目标下标（松手时按目标重排并落盘） */
  private dragFromIndex: number = -1;
  private dragToIndex: number = -1;
  /**
   * 每张卡片的实测高度（vp）。卡片高度并不一致（有的带「使用中」角标、有的带旧格式提示），
   * 所以不用「固定行高 × 位移」估算，而是用 onAreaChange 实测值累计判断插入位置。
   */
  private subCardHeights: number[] = [];

  private service: SubscriptionService = SubscriptionService.instance();
  private settings: AppSettings = new AppSettings();
  private refreshing: boolean = false;
  /**
   * 本轮失败的订阅 id（用于「刷新全部」结束时的真实结果统计）。
   *
   * 单条刷新成功会把自己从集合里移除，失败会加入 —— 所以它跨多轮自然收敛，
   * 不需要在 refreshAll 开头重置（历史实现无条件弹「✓ 全部订阅已刷新」，
   * 即使每一条都失败）。
   */
  private refreshFailedIds: string[] = [];
  private converting: boolean = false;
  private editTargetId: string = '';
  private editTargetName: string = '';
  /** 全局「自动更新订阅」开关（编辑弹框里展示/修改的就是它） */
  private autoUpdateGlobal: boolean = true;
  /**
   * 自动更新间隔（分钟）—— 2026-10-29 用户报「一直是 360，改不了」。
   * 真因：弹窗里那行是只读 Text，`refreshIntervalMinutesText()` 直接 return '360'，
   * 而且 AppSettings 里压根没这个字段 ⇒ 改了也无处存。现在接上真实设置。
   */
  private autoUpdateIntervalMin: number = 360;
  /** 允许明文 HTTP 订阅（2026-10-28 从设置页挪到「添加订阅 → URL」） */
  private allowInsecureSubscriptionHttp: boolean = false;
  private ageKeyResolve: ((key: string) => void) | null = null;
  private readonly ageKeyDialog: CustomDialogController = new CustomDialogController({
    builder: AgeKeyDialog({ onComplete: (key: string): void => { this.finishAgeKey(key); } }),
    autoCancel: false,
    alignment: DialogAlignment.Center,
    customStyle: true,
    cancel: (): void => { this.finishAgeKey(''); }
  });

  private finishAgeKey(key: string): void {
    const resolve = this.ageKeyResolve;
    this.ageKeyResolve = null;
    if (resolve !== null) { resolve(key); }
  }

  private requestAgeKey(): Promise<string> {
    this.finishAgeKey('');
    return new Promise<string>((resolve) => {
      this.ageKeyResolve = resolve;
      this.ageKeyDialog.open();
    });
  }
  private readonly addDialog: CustomDialogController = new CustomDialogController({
    builder: AddSubDialog({
      getAllowInsecure: (): boolean => this.allowInsecureSubscriptionHttp,
      onToggleInsecure: (v: boolean): void => { this.setAllowInsecure(v); },
      onAddUrl: (name: string, url: string): void => { this.applyAdd(name, url); },
      onConvert: (text: string, exportFile: boolean): void => { this.importFromConvert(text, exportFile); },
      onScan: (): void => { this.importFromQr(); },
      onPickFile: (): void => { this.importYamlFile(); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true
  });
  private readonly editDialog: CustomDialogController = new CustomDialogController({
    builder: EditSubDialog({
      getInitialName: (): string => {
        const s: Subscription | null = this.subById(this.editTargetId);
        return s === null ? '' : s.name;
      },
      getInitialUrl: (): string => {
        const s: Subscription | null = this.subById(this.editTargetId);
        return s === null ? '' : s.url;
      },
      getAutoUpdate: (): boolean => {
        const s: Subscription | null = this.subById(this.editTargetId);
        return s === null ? this.autoUpdateGlobal : s.autoUpdate;
      },
      getIntervalText: (): string => this.refreshIntervalMinutesText(),
      onConfirm: (name: string, url: string, autoUpdate: boolean, intervalMinutes: number): void => {
        this.applyEdit(name, url, autoUpdate, intervalMinutes);
      },
      onDelete: (): void => { this.deleteSub(this.editTargetId, this.editTargetName); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true,
    // 2026-10-28 用户要求：编辑弹窗居中，**键盘弹出不能改变它的宽/高**。
    //
    // 这里只能用全局 `KeyboardAvoidMode`（只有 DEFAULT/NONE 两项），**不是**
    // `@kit.ArkUI` 导出的同名枚举（那个是 UIContext 里给页面用的 OFFSET/RESIZE，
    // 赋给 dialog 会直接编译报错：Type 'KeyboardAvoidMode.OFFSET' is not assignable）。
    //
    // 选 DEFAULT 而不是 NONE 的理由：DEFAULT 的语义是「先整体上移，**只有空间不够时**才压缩高度」。
    // 弹窗现在是 86% 宽 + 内容自适应高度的小卡片（约 260vp），竖屏键盘（约 300vp）上方
    // 仍有 500vp 可用空间，永远到不了压缩阀值 ⇒ 实际表现就是「只上移、尺寸一字不变」，
    // 正是用户要的效果；而 NONE 完全不避让，键盘会直接盖住 URL 输入框。
    keyboardAvoidMode: KeyboardAvoidMode.DEFAULT
  });

  private readonly latencyListener: () => void = (): void => {
    this.latencyRevision = this.latencyRevision + 1;
  };
  private latencyBound: boolean = false;
  private readonly nodeSetListener: (reason: string) => void = (reason: string): void => {
    AppLogger.info(TAG, `node set changed: ${reason}`);
    this.profileRevisions.clear();
    this.reload();
  };
  private nodeSetBound: boolean = false;
  private readonly orchListener: () => void = (): void => {
    this.reload();
    this.refreshCoreCatalog();
  };
  private orchBound: boolean = false;

  aboutToAppear(): void {
    this.profileRevisions.clear();
    if (!this.latencyBound) {
      this.latencyBound = true;
      LatencyStoreBridge.addListener(this.latencyListener);
    }
    if (!this.nodeSetBound) {
      this.nodeSetBound = true;
      SubscriptionService.onNodeSetChanged(this.nodeSetListener);
    }
    if (!this.orchBound) {
      this.orchBound = true;
      ConnectionOrchestrator.instance().addListener(this.orchListener);
    }
    this.reload();
    this.refreshCoreCatalog();
    this.measureStatusBar();
    if (this.subs.length === 0) {
      setTimeout((): void => { this.reload(); }, 600);
      setTimeout((): void => { this.reload(); }, 1600);
    }
  }

  aboutToDisappear(): void {
    this.finishAgeKey('');
    this.ageKeyDialog.close();
    if (this.latencyBound) {
      this.latencyBound = false;
      LatencyStoreBridge.removeListener(this.latencyListener);
    }
    if (this.nodeSetBound) {
      this.nodeSetBound = false;
      SubscriptionService.offNodeSetChanged(this.nodeSetListener);
    }
    if (this.orchBound) {
      this.orchBound = false;
      ConnectionOrchestrator.instance().removeListener(this.orchListener);
    }
  }

  /** 取系统状态栏高度（px → vp），失败保持默认 24vp */
  private measureStatusBar(): void {
    try {
      const ctx = this.getUIContext().getHostContext();
      if (ctx === undefined) {
        return;
      }
      window.getLastWindow(ctx).then((win: window.Window): void => {
        const area: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const px: number = area.topRect.height;
        if (px > 0) {
          this.statusBarH = px2vp(px);
        }
      }).catch((): void => {});
    } catch (e) {
      AppLogger.warn(TAG, `measure status bar failed: ${AppLogger.errText(e)}`);
    }
  }

  // ────────────────────────── 数据 ──────────────────────────

  private profileRevisions: Map<string, string> = new Map<string, string>();

  private profileRevisionFor(id: string): string {
    return this.profileRevisions.get(id) ?? '';
  }

  private reload(): void {
    for (const sub of this.service.subscriptions) {
      if (!this.profileRevisions.has(sub.id)) {
        this.profileRevisions.set(sub.id, ProfileRepository.revisionOf(sub.id));
      }
    }
    this.subs = this.service.subscriptions.slice();
    this.currentProfileId = ProfileRepository.currentId();
    const orch: ConnectionOrchestrator = ConnectionOrchestrator.instance();
    this.currentNodeName = orch.getCurrentNodeName();
    // 偏好必须从磁盘读：本组件此前从未 load 过 AppSettings，
    // 导致「选完节点→重进面板」时 preferredNodeName 恒为空 → 勾选丢失（真机复现）。
    SettingsService.load().then((loaded: AppSettings): void => {
      this.settings = loaded;
      this.sortByDelay = loaded.nodeListSortMode !== 'default';
      // 间隔是全局设置（2026-10-29）：跟着 settings 一起刷新，弹窗打开时就能看到真值
      this.autoUpdateIntervalMin = loaded.subscriptionUpdateIntervalMinutes;
      this.autoUpdateGlobal = loaded.autoUpdateSubscription;
      this.allowInsecureSubscriptionHttp = loaded.allowInsecureSubscriptionHttp;
      this.currentNodeName = orch.getCurrentNodeName();
      this.refreshSmartEntry();
    }).catch((): void => {});
  }

  private refreshSmartEntry(): void {
    const scope = this.panelSubId;
    const revision = ++this.smartRefreshRevision;
    this.smartSelected = this.settings.autoSelectMode === AutoSelectModes.AUTO
      && ConnectionOrchestrator.instance().isSmartModelAvailable()
      && this.settings.preferredNodeSubscriptionId === scope;
    ConnectionOrchestrator.instance().smartAvailableFor(scope, this.service).then((available: boolean): void => {
      if (revision === this.smartRefreshRevision && scope === this.panelSubId) { this.smartVisible = available; }
    }).catch((): void => {
      if (revision === this.smartRefreshRevision) { this.smartVisible = false; }
    });
  }

  private async selectSmart(): Promise<void> {
    if (this.selectingMember.length > 0) { return; }
    const scope = this.panelSubId;
    this.selectingMember = 'smart';
    try {
      const restarted = await ConnectionOrchestrator.instance().selectSmartSubscription(scope, this.service);
      if (this.panelSubId === scope) {
        this.settings = await SettingsService.load();
        this.refreshSmartEntry();
      }
      this.toast(restarted ? '已启用本订阅智能选择，代理已重启' : '已选择智能选点，下次连接生效');
    } catch (e) {
      this.toast(AppLogger.errText(e));
    } finally {
      this.selectingMember = '';
      this.reload();
    }
  }

  private subById(id: string): Subscription | null {
    for (let i = 0; i < this.subs.length; i++) {
      if (this.subs[i].id === id) {
        return this.subs[i];
      }
    }
    return null;
  }

  /** 面板当前订阅（null = 无） */
  private panelSub(): Subscription | null {
    return this.subById(this.panelSubId);
  }

 

  private catalogFor(subId: string): CoreCatalogModel | null {
    if (ConnectionOrchestrator.instance().appliedProfile() === subId
      && CoreCatalogService.profileIdOfSnapshot() === subId) { return CoreCatalogService.current(); }
    return CoreCatalogService.forProfile(subId, this.profileRevisionFor(subId));
  }

  private coreCatalogFor(subId: string): boolean { return this.catalogFor(subId) !== null; }

  private groupsOf(subId: string): ProxyGroup[] {
    const core = this.catalogFor(subId);
    if (core !== null) {
      const fromCore: ProxyGroup[] = [];
      const byName: Map<string, ProxyGroup> = new Map<string, ProxyGroup>();
      for (const source of core.groups) {
        // 订阅声明的 Smart / URLTest 组均是真实策略，不能按名字隐藏。
        if (source.hidden) {
          continue;
        }
        const group = new ProxyGroup();
        group.subscriptionId = subId;
        group.name = source.name;
        group.groupType = source.type;
        group.url = source.url;
        group.expectedStatus = source.expectedStatus;
        group.members = source.all.map((node): string => node.name);
        fromCore.push(group);
        byName.set(group.name, group);
      }
      // 2026-10-29 用户报「ikuuu 默认分组是选择节点，启动后却显示 OneDrive 分组」。
      // 真因：内核 `/proxies` 是 Go 的 map[string]X，encoding/json 序列化 map 时**按 key
      // 排序**输出 ⇒ core.groups 的顺序与订阅 YAML 里 proxy-groups 的数组顺序无关。
      // 例如 ☁️(U+2601) < 🇨🇳(U+1F1E8) < 🌏(U+1F30F) < … < 🔰(U+1F530)，
      // 「🔰 选择节点」被排到最后，于是 chips 首项和默认选中组都变成了 OneDrive。
      // 这里以**订阅配置里的数组顺序**为基准重排（配置才是用户眼里的「默认分组」），
      // 内核独有、配置里没有的组追加在末尾，一个都不丢。
      const cfgOrder: ProxyGroup[] = this.service.groupsOf(subId);
      if (cfgOrder.length === 0) {
        return fromCore;
      }
      const out: ProxyGroup[] = [];
      const used: Set<string> = new Set<string>();
      for (const cfg of cfgOrder) {
        const ordered: ProxyGroup | undefined = byName.get(cfg.name);
        if (ordered !== undefined && !used.has(cfg.name)) {
          out.push(ordered);
          used.add(cfg.name);
        }
      }
      if (out.length === 0) {
        return fromCore;
      }
      for (const g of fromCore) {
        if (!used.has(g.name)) {
          out.push(g);
        }
      }
      return out;
    }
    return this.service.groupsOf(subId);
  }

  /**
   * 拉内核快照并打上「**内核真正生效的那份订阅**」的戳。
   *
   * 关键：戳必须优先来自 `orch.appliedProfile()`（隧道/测速核真的按这份 profile 起来的），
   * 不能无条件用 `ProfileRepository.currentId()`（用户刚点的期望值）。切订阅是热重载/重连
   * 异步完成的（见 `ConnectionOrchestrator.confirmProfileApplied`），用期望值打戳会把
   * **上一份订阅的节点**盖成新订阅的戳 → `coreCatalogFor` 误判通过 → 展开订阅 B 看到
   * 订阅 A 的节点，重新点开才好（2026-10-30 用户报障）。
   *
   * 内核对不上当前选择时不刷新：快照保持旧戳，`coreCatalogFor` 判假，UI 自动退回
   * 「本订阅本地节点」这条已经写好且绝对隔离的分支。
   */
  private async refreshCoreCatalog(): Promise<void> {
    const orch: ConnectionOrchestrator = ConnectionOrchestrator.instance();
    if (orch.state !== ConnState.CONNECTED && orch.state !== ConnState.CONNECTING) {
      return;
    }
    const appliedId: string = orch.appliedProfile();
    const profileId: string = appliedId.length > 0 ? appliedId : ProfileRepository.currentId();
    const model = await CoreCatalogService.refresh(orch.api, false, profileId);
    if (model !== null) {
      this.coreRevision = this.coreRevision + 1;
    }
  }

  private activeGroupOf(subId: string): ProxyGroup | null {
    if (this.selectedGroup.length === 0) {
      return null;
    }
    const list: ProxyGroup[] = this.groupsOf(subId);
    for (let i = 0; i < list.length; i++) {
      if (list[i].name === this.selectedGroup) {
        return list[i];
      }
    }
    return null;
  }

  /**
   * 订阅里是否至少有一个真实代理（DIRECT/REJECT/策略组都不算）。
   * 只用于空状态文案：区分「这个组为空」和「整个订阅根本没有代理」。
   */
  private subHasRealProxy(): boolean {
    const nodes: ProxyNode[] = this.service.nodesOf(this.panelSubId);
    for (const node of nodes) {
      if (ProxyPanelMembers.isProxy(node)) {
        return true;
      }
    }
    return false;
  }

  private panelNodes(): ProxyNode[] {
    // 普通订阅以本地节点作归属证明；provider-only 配置没有本地节点，只有在内核
    // 快照的 profile 归属戳与面板订阅逐字匹配时，才允许展示运行期注入的节点。
    const localNodes = this.service.nodesOf(this.panelSubId);
    if (localNodes.length === 0 && !this.coreCatalogFor(this.panelSubId)
      && this.activeGroupOf(this.panelSubId) === null) {
      return [];
    }

    const core = this.catalogFor(this.panelSubId);
    let arr: ProxyNode[];
    if (core !== null) {
      arr = this.corePanelNodes(localNodes);
    } else {
      arr = this.localPanelNodes(localNodes);
    }
    // 2026-11-03 用户报障「jdydy 不按延迟排序」：原写法是「成员里有子策略组就整体不排序」，
    // 只要订阅带子组（jdydy / ikuuu / 模板）就永远排不了序。正确口径：
    // 子策略组是「文件夹」→ 保持声明顺序钉在顶部；真实代理按延迟升序；DIRECT/REJECT
    // 等策略成员与信息型伪节点排在末尾（同样保持声明顺序）。
    return this.sortPanelRows(arr);
  }

  /**
   * 面板行的统一排序口径（组 → 代理按延迟 → 策略/伪成员）。
   * 顶层列表与内联小分组的成员行共用同一份规则，避免两处排序口径漂移。
   */
  private sortPanelRows(list: ProxyNode[]): ProxyNode[] {
    if (!this.sortByDelay) {
      return list;
    }
    const groups: ProxyNode[] = [];
    const proxies: ProxyNode[] = [];
    const policies: ProxyNode[] = [];
    for (const node of list) {
      if (ProxyPanelMembers.isGroup(node)) {
        groups.push(node);
      } else if (ProxyPanelMembers.isProxy(node)) {
        proxies.push(node);
      } else {
        policies.push(node);
      }
    }
    return groups.concat(CoreNodeBridge.sortByDelay(proxies, (name: string): number | null => {
      const rec = this.pingRecordForName(name);
      return rec === null ? null : (rec.hasValue() ? rec.delayMs : (rec.isFailure() ? -1 : null));
    }), policies);
  }

  /**
   * 面板列表的分行结果：单列时一行一个节点，双列时一行两个（奇数个最后一个占半行）。
   * ForEach 只调用一次，内部也只算一次 `panelNodes()`，避免每行重复排序。
   */
  private panelNodeRows(): ProxyNode[][] {
    const nodes: ProxyNode[] = this.panelNodes();
    const rows: ProxyNode[][] = [];
    const step: number = this.gridMode ? 2 : 1;
    for (let i = 0; i < nodes.length; i += step) {
      rows.push(nodes.slice(i, i + step));
    }
    return rows;
  }

  /** 行级 ForEach key：沿用原来的失效条件集合，额外带上排布模式与行内每个节点的勾选态。 */
  private panelRowKey(row: ProxyNode[]): string {
    let ids: string = '';
    for (let i = 0; i < row.length; i++) {
      ids += `${row[i].id}:${this.isDeleteChecked(row[i].id)},`;
    }
    return `${ids}|${this.gridMode ? 'g' : 'l'}|${this.selectedGroup}|${this.latencyRevision}`
      + `|${this.coreRevision}|${this.sortByDelay}|${this.nodeRevision}|${this.deleteSheetOn}`;
  }

  /**
   * 内核快照路径的节点行。
   *
   * 必须先校验实际应用的 profile 归属戳，组不存在时回退本地解析。
   * 同一份图里的子策略组和 provider 节点都是合法成员，不能再用本地叶子名字
   * 交集过滤，否则会把它们一起隐藏。旧快照归属不匹配时 caller 不会进入此分支。
   */
  private corePanelNodes(localNodes: ProxyNode[]): ProxyNode[] {
    const core = this.catalogFor(this.panelSubId);
    if (core === null) {
      return this.localPanelNodes(localNodes);
    }
    const source: CoreGroup | null = core.findGroup(this.selectedGroup);
    if (source === null) {
      if (localNodes.length === 0) {
        return CoreNodeBridge.toProxyNodes(ProxyPanelMembers.coreProxies(core), this.panelSubId);
      }
      return this.localPanelNodes(localNodes);
    }
    // The caller already checks the applied profile stamp. Provider nodes and child
    // groups are both legitimate members of this exact graph, not foreign local nodes.
    return ProxyPanelMembers.fromCore(source, this.panelSubId, '');
  }

  /** 本地（订阅配置）路径的节点行：不经内核，天然按 subscriptionId 隔离。 */
  private localPanelNodes(localNodes: ProxyNode[]): ProxyNode[] {
    const group: ProxyGroup | null = this.activeGroupOf(this.panelSubId);
    if (group !== null) {
      return ProxyPanelMembers.fromLocal(group, this.service.groupsOf(this.panelSubId),
        localNodes, '');
    }
    return localNodes.slice();
  }

  private protoOf(node: ProxyNode): string {
    if (ProxyPanelMembers.isGroup(node)) {
      return ProxyPanelMembers.type(node.proxyType);
    }
    if (CoreNodeBridge.isShadow(node)) {
      return CoreNodeBridge.protocolLabel(node);
    }
    return NodeProtocolPolicy.fromNode(node).display();
  }

  /**
   * 行记录：先看自己的名字，再看（组行）末端口 —— 测速目标按 FlClash 口径解析成
   * 真实出口，结论记在出口名下，组卡片要借出口的记录显示。
   */
  private pingRecordForName(name: string): LatencyRecord | null {
    const profileId = this.panelSubId;
    const groups = this.service.groupsOf(profileId);
    const model = this.catalogFor(profileId);
    const globalUrl = BackgroundLatencyService.resolveTestUrl(this.settings);
    if (model !== null) {
      const orch = ConnectionOrchestrator.instance();
      const selections = orch.state === ConnState.CONNECTED && orch.appliedProfile() === profileId ? null
        : ProxyPanelMembers.selectionsFor(this.settings.proxyGroupSelections, profileId);
      const target = ProxyPanelMembers.delayTarget(model, name, this.selectedGroup, globalUrl, '', groups, selections);
      if (target === null) { return null; }
      return LatencyStoreBridge.recordFor(target.name,
        new LatencyContext(profileId, this.profileRevisionFor(profileId), target.url, target.expected));
    }
    // A group with no current graph has no proven exit. Never borrow a result
    // under its name or from another profile's graph.
    if (groups.some((group): boolean => group.name === name)) { return null; }
    const parent = groups.find((group): boolean => group.name === this.selectedGroup);
    const url = parent !== undefined && parent.url.length > 0 ? parent.url : globalUrl;
    const expected = parent === undefined ? '' : parent.expectedStatus;
    return LatencyStoreBridge.recordFor(name,
      new LatencyContext(profileId, this.profileRevisionFor(profileId), url, expected));
  }

  private pingRecord(node: ProxyNode): LatencyRecord | null {
    return this.pingRecordForName(node.name);
  }

  private pingText(node: ProxyNode): string {
    return TunBoxPing.recordText(this.pingRecord(node), Math.max(Date.now(), this.latencyRevision));
  }

  private pingColor(node: ProxyNode): ResourceColor {
    return TunBoxPing.recordColor(this.pingRecord(node), Math.max(Date.now(), this.latencyRevision), this.themeRevision);
  }

  /** 选中态来自父选择组的真实选择，未连接时读取该订阅保存的选择。 */
  private isActiveNode(node: ProxyNode): boolean {
    if (this.smartSelected && this.smartVisible) { return false; }
    const parent = this.activeGroupOf(this.panelSubId);
    if (parent !== null && ProxyPanelMembers.type(parent.groupType) === 'Selector') {
      const core = ConnectionOrchestrator.instance().state === ConnState.CONNECTED
        && this.coreCatalogFor(this.panelSubId) ? CoreCatalogService.current() : null;
      const group = core === null ? null : core.findGroup(parent.name);
      const selected = group !== null && group.now.length > 0 ? group.now
        : ProxyPanelMembers.selected(this.settings.proxyGroupSelections, this.panelSubId, parent.name);
      if (selected.length > 0) { return selected === node.name; }
    }
    return this.currentNodeName.length > 0 && node.name === this.currentNodeName;
  }

  private isRefreshingSub(id: string): boolean {
    return this.refreshingIds.includes(id);
  }

  private isTestingSub(id: string): boolean {
    return this.testingIds.includes(id);
  }

  private upText(sub: Subscription): string {
    return SubscriptionSummary.bytes(sub.uploadBytes);
  }

  private downText(sub: Subscription): string {
    return SubscriptionSummary.bytes(sub.downloadBytes);
  }

  private totalText(sub: Subscription): string {
    return sub.totalBytes > 0 ? SubscriptionSummary.bytes(sub.totalBytes) : '不限';
  }

  /** 用量比例（0–1）；总量未知返回 -1（不画进度） */
  private usageRatio(sub: Subscription): number {
    if (sub.totalBytes <= 0) {
      return -1;
    }
    const used: number = Math.max(0, sub.uploadBytes) + Math.max(0, sub.downloadBytes);
    return Math.min(1, Math.max(0, used / sub.totalBytes));
  }

  private expiryText(sub: Subscription): string {
    if (sub.expireAt <= 0) {
      return '长期有效';
    }
    // 机场的 subscription-userinfo 有的给秒级时间戳、有的给毫秒（实测 ikuuu 是毫秒），
    // 用数量级判定：>= 1e12 视为毫秒，否则按秒。
    const expireMs: number = sub.expireAt >= 1e12 ? sub.expireAt : sub.expireAt * 1000;
    const remainMs: number = expireMs - Date.now();
    if (remainMs <= 0) {
      return '已到期';
    }
    const days: number = Math.floor(remainMs / 86400000);
    if (days >= 1) {
      return `剩余 ${days} 天`;
    }
    const hours: number = Math.floor(remainMs / 3600000);
    return hours >= 1 ? `剩余 ${hours} 小时` : '即将到期';
  }

  private updateText(sub: Subscription): string {
    // 2026-11-04 用户报障：最后一条订阅显示「未更新更新」。
    // `updateTime(0)` 返回的就是完整状态词「未更新」，这里再拼一次「更新」会重复。
    // 只有真实的相对时间（刚刚 / N 分钟前 / N 小时前 / N 天前）才需要后缀。
    const relative: string = SubscriptionSummary.updateTime(sub.lastFetchedAt);
    if (!Number.isFinite(sub.lastFetchedAt) || sub.lastFetchedAt <= 0) {
      return relative;
    }
    return `${relative}更新`;
  }

  /**
   * 卡片副标题里的节点数（2026-11-03 用户口径：不再出现「N 分组」）。
   *
   * 内核快照里一个真实代理都没有时，不直接下结论：provider 还没拉完时 `/proxies`
   * 是空的，而订阅本身有节点（用户报障「本地 yaml 明明 64 个节点」），此时回落
   * App 自己落盘的节点数。两边都是 0 就返回空串 —— 卡片只留更新时间。
   */
  private nodeCountText(sub: Subscription): string {
    const core = this.catalogFor(sub.id);
    if (core !== null) {
      const coreRows: ProxyNode[] = CoreNodeBridge.toProxyNodes(ProxyPanelMembers.coreProxies(core), sub.id);
      if (ProxyPanelMembers.proxyCount(coreRows) === 0) {
        const localRows: ProxyNode[] = this.service.nodesOf(sub.id);
        if (ProxyPanelMembers.proxyCount(localRows) > 0) {
          return ProxyPanelMembers.summary(localRows);
        }
      }
      return ProxyPanelMembers.summary(coreRows);
    }
    return ProxyPanelMembers.summary(this.service.nodesOf(sub.id));
  }

  /** 写法与设置页同源：只改这一个字段，不整单覆盖 */
  private setAllowInsecure(v: boolean): void {
    this.allowInsecureSubscriptionHttp = v;
    SettingsService.patchSettings((s: AppSettings): void => {
      s.allowInsecureSubscriptionHttp = v;
    }).catch((): void => {});
  }

  /**
   * 自动更新间隔展示（2026-10-30 用户报障修根）：
   * 优先取**当前编辑订阅自己的**间隔；订阅没单独设过（0）→ 回退全局默认值。
   * 旧实现只读全局，于是「编 A 订阅填了 30 分钟」会把全局改掉，B/C 订阅跟着变 30 分钟。
   */
  private refreshIntervalMinutesText(): string {
    const s: Subscription | null = this.subById(this.editTargetId);
    if (s !== null && s.updateIntervalMinutes >= MIN_UPDATE_INTERVAL_MINUTES) {
      return `${s.updateIntervalMinutes}`;
    }
    return `${this.autoUpdateIntervalMin}`;
  }

  // ────────────────────────── 动作 ──────────────────────────

  private onHeaderTap(sub: Subscription): void {
    this.panelSubId = sub.id;
    this.smartVisible = false;
    this.refreshSmartEntry();
    const groups: ProxyGroup[] = this.groupsOf(sub.id);
    this.selectedGroup = groups.length > 0 ? groups[0].name : '';
    // 面板一打开就要算出「♻️ 自动选择」入口要不要出现/是否已选中
    // 不再按卡片下标算展开起点：所有订阅统一使用同一条（首条）展开动画。
    this.panelAnimating = true;
    this.showPanel = true;
    setTimeout((): void => {
      this.panelAnimating = false;
    }, 24);
    if (this.currentProfileId !== sub.id) {
      this.activateProfile(sub.id).catch((e: Object): void => {
        AppLogger.warn(TAG, `activate profile failed: ${AppLogger.errText(e)}`);
      });
    }
  }

  private closePanel(): void {
    this.showPanel = false;
    this.panelAnimating = false;
  }

  private async activateProfile(id: string): Promise<void> {
    if (id.length === 0) {
      return;
    }
    if (ProfileRepository.currentId() === id) {
      return;
    }
    await ProfileRepository.setCurrent(id);
    this.currentProfileId = id;
    const rev: number = AppStorage.get<number>('public_ip_revision') ?? 0;
    AppStorage.setOrCreate('public_ip_revision', rev + 1);
    try {
      await ConnectionOrchestrator.instance().ensureProfileApplied('home-subscription-section');
    } catch (e) {
      AppLogger.warn(TAG, `ensure profile applied failed: ${AppLogger.errText(e)}`);
    }
    this.reload();
  }

  private async refreshOne(sub: Subscription): Promise<void> {
    if (this.refreshing || this.isRefreshingSub(sub.id)) {
      return;
    }
    this.refreshing = true;
    this.refreshingIds = this.refreshingIds.concat([sub.id]);
    try {
      const result = await this.service.refreshSubscription(sub.id, (): Promise<string> => this.requestAgeKey());
      const ok: boolean = result.status === SubscriptionRefreshStatus.OK
        || result.status === SubscriptionRefreshStatus.NOT_MODIFIED;
      // 2026-11-03：本地 YAML 的 provider 地址是占位符时，刷新是「成功」的（原文没变），
      // 但一个节点都没进来。只弹「已刷新」会让用户以为应用坏了，这里把 provider 原因带上。
      const providerIssue: string = result.diagnostics.providerFailedCount > 0
        ? result.diagnostics.providerFailureReasons
        : '';
      const advice: string = result.advice.length > 0 ? result.advice : providerIssue;
      if (ok && advice.length > 0) {
        this.toast(`${sub.name} 已刷新，但节点未加载：${ImportFailureSummary.brief(advice)}`, 4000);
      } else if (!ok) {
        // 失败必须带真实原因：message 由订阅层算出（空响应字节数 / 校验判词 / HTTP 状态码），
        // advice 是面向用户的可操作建议。旧实现两者都丢，只剩「刷新失败：<名字>」，
        // 用户无法判断是链接过期、面板 4xx、还是内容不是 Clash。
        if (!this.refreshFailedIds.includes(sub.id)) {
          this.refreshFailedIds = this.refreshFailedIds.concat([sub.id]);
        }
        this.toast(ImportFailureSummary.line(`刷新失败：${sub.name}`,
          result.message.length > 0 ? result.message : result.advice), 4000);
      } else {
        this.refreshFailedIds = this.refreshFailedIds.filter((x: string): boolean => x !== sub.id);
        this.toast(`✓ ${sub.name} 已刷新`);
      }
    } catch (e) {
      AppLogger.warn(TAG, `refresh failed: ${AppLogger.errText(e)}`);
      this.toast('刷新失败，请重试');
    } finally {
      this.refreshing = false;
      this.refreshingIds = this.refreshingIds.filter((x: string): boolean => x !== sub.id);
      this.reload();
    }
  }

  private async refreshAll(): Promise<void> {
    const snapshot: Subscription[] = this.subs.slice();
    for (let i = 0; i < snapshot.length; i++) {
      await this.refreshOne(snapshot[i]);
    }
    // 旧实现无条件弹「✓ 全部订阅已刷新」：即使每条都失败，用户也会以为已更新。
    // 真实结果按单条刷新登记的失败集合统计（成功会把自己移出集合）。
    const failed: number = snapshot.filter((s: Subscription): boolean =>
      this.refreshFailedIds.includes(s.id)).length;
    if (failed === 0) {
      this.toast('✓ 全部订阅已刷新');
    } else {
      this.toast(`刷新完成：${snapshot.length - failed} 成功，${failed} 失败`, 4000);
    }
  }

  private async testSub(subId: string, subName: string): Promise<void> {
    if (this.isTestingSub(subId)) {
      return;
    }
    this.testingIds = this.testingIds.concat([subId]);
    try {
      const context: Context = getContext(this) as Context;
      const groupName = this.showPanel && this.panelSubId === subId ? this.selectedGroup : '';
      const progress = await BackgroundLatencyService.testSubscription(context, subId, null, groupName);
      if (progress === null) {
        this.toast('测速未执行，请稍后重试');
        return;
      }
      this.toast(progress.completionMessage());
    } catch (e) {
      AppLogger.warn(TAG, `latency test failed: ${AppLogger.errText(e)}`);
      this.toast('测速失败，请重试');
    } finally {
      this.profileRevisions.set(subId, ProfileRepository.revisionOf(subId));
      this.testingIds = this.testingIds.filter((x: string): boolean => x !== subId);
      this.latencyRevision = this.latencyRevision + 1;
    }
  }

 

  private openEdit(sub: Subscription): void {
    this.editTargetId = sub.id;
    this.editTargetName = sub.name;
    this.editDialog.open();
  }

  // ────────────────────── 长按拖动排序 ──────────────────────

  /** 长按达时：进入拖动态（订阅少于 2 条时没有排序意义，直接忽略） */
  private beginSubDrag(id: string, index: number): void {
    if (this.subs.length < 2) {
      return;
    }
    this.dragSubId = id;
    this.dragFromIndex = index;
    this.dragToIndex = index;
    this.dragDy = 0;
  }

  /** 取第 i 张卡片的实测高度（未实测到时给个保守默认值，避免除零/跳变） */
  private subCardHeight(i: number): number {
    const h: number = this.subCardHeights[i];
    return Number.isFinite(h) && h > 0 ? h : 120;
  }

  /**
   * 拖动中：跟手平移 + 按实际位移算出「松手后应该插到第几张」。
   * 判定规则：越过某张卡片高度的一半即视为跨过它（与系统列表拖拽排序手感一致）。
   */
  private updateSubDrag(dy: number): void {
    if (this.dragSubId.length === 0) {
      return;
    }
    this.dragDy = dy;
    const start: number = this.dragFromIndex;
    if (start < 0) {
      return;
    }
    let target: number = start;
    let acc: number = 0;
    if (dy > 0) {
      for (let i = start + 1; i < this.subs.length; i++) {
        acc = acc + this.subCardHeight(i) + SUB_CARD_SPACE;
        if (dy > acc - (this.subCardHeight(i) + SUB_CARD_SPACE) / 2) {
          target = i;
        } else {
          break;
        }
      }
    } else if (dy < 0) {
      for (let i = start - 1; i >= 0; i--) {
        acc = acc + this.subCardHeight(i) + SUB_CARD_SPACE;
        if (-dy > acc - (this.subCardHeight(i) + SUB_CARD_SPACE) / 2) {
          target = i;
        } else {
          break;
        }
      }
    }
    this.dragToIndex = target;
  }

  /** 松手：本地先重排（手感即时），再把新顺序落盘 */
  private endSubDrag(): void {
    const id: string = this.dragSubId;
    const from: number = this.dragFromIndex;
    const to: number = this.dragToIndex;
    this.dragSubId = '';
    this.dragDy = 0;
    this.dragFromIndex = -1;
    this.dragToIndex = -1;
    if (id.length === 0 || from < 0 || to < 0 || from === to) {
      return;
    }
    const list: Subscription[] = this.subs.slice();
    if (from >= list.length || list[from].id !== id) {
      // 拖动期间列表被后台刷新/重载替换过 → 放弃这次排序，避免插错位置
      return;
    }
    const moved: Subscription = list[from];
    list.splice(from, 1);
    const insertAt: number = to > list.length ? list.length : to;
    list.splice(insertAt, 0, moved);
    this.subs = list;
    this.service.reorderSubscriptions(list.map((s: Subscription): string => s.id))
      .then((): void => { this.toast('排序已保存'); })
      .catch((e: Object): void => {
        AppLogger.warn(TAG, `reorder subscriptions failed: ${AppLogger.errText(e)}`);
        this.toast('排序保存失败');
      });
  }

  /** 扫码导入（相机权限被拒 / 用户取消各有独立提示） */
  private async importFromQr(): Promise<void> {
    try {
      const result = await scanBarcode.startScanForResult(getContext(this) as Context, {
        enableMultiMode: false,
        enableAlbum: true
      });
      const raw: string = result.originalValue.trim();
      if (raw.length === 0) {
        this.toast('二维码内容为空');
        return;
      }
      const lower: string = raw.toLowerCase();
      if (!(lower.startsWith('https://') || lower.startsWith('http://'))) {
        this.toast('二维码里应是 Clash 订阅链接');
        return;
      }
      await this.applyAdd('', raw);
    } catch (e) {
      const err = e as BusinessError;
      if (err.code === 1000500002) {
        this.toast('已取消二维码扫描');
      } else if (err.code === 201) {
        this.toast('相机权限被拒绝，无法扫描二维码');
      } else {
        this.toast('二维码扫描失败，请重试');
      }
    }
  }

  /** 同一份转换结果可直接导入，或经系统保存器导出为本机 YAML 文件。 */
  private async importFromConvert(text: string, exportFile: boolean = false): Promise<void> {
    if (this.converting) { return; }
    const raw: string = text.trim();
    if (raw.length === 0) {
      this.toast('请粘贴分享链接或订阅内容');
      return;
    }
    if (raw.length > ImportFilePolicy.YAML_MAX_BYTES) {
      this.toast(ImportFilePolicy.tooLarge('订阅内容', ImportFilePolicy.YAML_MAX_BYTES));
      return;
    }
    this.converting = true;
    try {
      let body: string = text;
      const lower: string = raw.toLowerCase();
      if (lower.startsWith('http://') || lower.startsWith('https://')) {
        // fetch 签名收口（§5.1 allowInsecureHttp 已删）：本文件仅适配新签名。
        const fetched = await SubscriptionFetchPolicy.fetch(raw, '', '', 'convert');
        body = fetched.body;
      }
      if (body.trim().length === 0) {
        this.toast('没有拿到内容，请检查链接是否可用');
        return;
      }
      let yaml: string = body;
      // R5 收口（FlClash ConvertsV2Ray 语义，固定上游 be847366）：是否走链接转换
      // 只由「是不是分享链接/base64 列表」决定，不再用行首 proxies/proxy-groups/
      // proxy-providers 文本闸猜「是不是 Clash 配置」——JSON、带引号键、rules-only
      // 的合法 mapping 都必须原样交给内核校验（ProfileRepository.validateAndStore）。
      if (looksLikeShareLinkBody(body)) {
        const converted = SubConverter.convert(body);
        if (!converted.ok) {
          this.toast('无法识别内容：既不是 Clash 配置，也解析不出节点链接');
          return;
        }
        // 补齐选择组与 MATCH，让导出的链接转换结果可直接作为 Clash 配置使用。
        // （仅导出/导入产物；内核链路是 FlClash 语义：原文进内核，GLOBAL 兜底。）
        yaml = withExportSkeleton(converted.proxiesYaml);
      }
      const bytes = util.TextEncoder.create('utf-8').encodeInto(yaml);
      const sizeError = ImportFilePolicy.validateSize(bytes.byteLength, ImportFilePolicy.YAML_MAX_BYTES, '配置文件');
      if (sizeError.length > 0) { this.toast(sizeError); return; }
      const stat: Date = new Date();
      const fileName: string = `converted-${stat.getFullYear()}${String(stat.getMonth() + 1).padStart(2, '0')}`
        + `${String(stat.getDate()).padStart(2, '0')}-${String(stat.getHours()).padStart(2, '0')}`
        + `${String(stat.getMinutes()).padStart(2, '0')}${String(stat.getSeconds()).padStart(2, '0')}.yaml`;
      if (exportFile) {
        const docPicker = new picker.DocumentViewPicker(getContext(this) as Context);
        const opts = new picker.DocumentSaveOptions();
        opts.newFileNames = [fileName];
        opts.fileSuffixChoices = ['YAML 配置|.yaml'];
        const uris = await docPicker.save(opts);
        if (uris.length === 0) { return; }
        const file = await fs.open(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          let written: number = 0;
          while (written < bytes.byteLength) {
            const remaining = bytes.slice(written).buffer as ArrayBuffer;
            const count = await fs.write(file.fd, remaining);
            if (count <= 0 || count > remaining.byteLength) { throw new Error('文件写入未完成'); }
            written += count;
          }
          await fs.fsync(file.fd);
        } finally {
          await fs.close(file);
        }
        this.toast('YAML 文件已保存到本机');
        return;
      }
      const previousCount = this.service.subscriptions.length;
      const added: number = await this.service.addLocalYaml(fileName, yaml);
      if (added > 0) {
        this.toast(`转换成功，加入 ${added} 个节点`);
      } else if (this.service.subscriptions.length > previousCount) {
        // provider-only 配置可成功导入，即使尚无本地展开的叶子节点。
        this.toast('配置已导入 TunBox，节点将在加载订阅后显示');
      } else {
        this.toast('导入未完成，请检查订阅内容或节点数量限制');
      }
      this.reload();
    } catch (e) {
      const reason: string = AppLogger.errText(e);
      AppLogger.warn(TAG, `convert ${exportFile ? 'export' : 'import'} failed: ${reason}`);
      // 不能只说「重试」：这里的异常携带了真实判词（校验失败原因 / 保存器错误码），
      // 用户据此才能判断是内容问题还是保存位置问题。
      this.toast(ImportFailureSummary.line(exportFile ? '导出失败' : '导入失败', reason), 4000);
    } finally {
      this.converting = false;
    }
  }

  /** 从本地文件导入 Clash YAML */
  private async importYamlFile(): Promise<void> {
    try {
      const docPicker = new picker.DocumentViewPicker(getContext(this) as Context);
      const opts = new picker.DocumentSelectOptions();
      opts.maxSelectNumber = 1;
      // 2026-11-04 撤销"只列 YAML"的省事型限制（唯一边界：不得因省事造成导入异常）。
      // 机场/转换站导出的文件常见 `.txt` / `.conf`，旧实现让它们在选择器里根本点不到，
      // 用户看到「导入失败」而内容其实完全合法。真正的判词由
      // ProfileRepository.validateAndStore（FlClash validateProfile 同款）给出：
      // 原文可用 → 落原文；否则转换；都失败才拒绝，并展示真实原因。
      opts.fileSuffixFilters = ['.yaml', '.yml', '.txt', '.conf'];
      const uris = await docPicker.select(opts);
      if (uris.length === 0) {
        return;
      }
      const uri: string = uris[0];
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        const stat = fs.statSync(file.fd);
        // 8 MiB 与下游一致（ProfileRepository.MAX_PROFILE_BYTES /
        // RawSubscriptionStore.RAW_SUB_MAX_BYTES / BackupRestoreService /
        // VpnExtensionAbility.readConfigText / SubscriptionFetchPolicy）。
        // 此前这里独一份写 4 MiB，是整条链路唯一的窄口：同一份 5MB 配置走
        // 订阅 URL 能进、走文件导入却被挡。上限同样兼任下面全量分配的内存护栏。
        const sizeError: string = ImportFilePolicy.validateSize(
          Number(stat.size), ImportFilePolicy.YAML_MAX_BYTES, '配置文件');
        if (sizeError.length > 0) {
          this.toast(sizeError);
          return;
        }
        const buf = new ArrayBuffer(Number(stat.size));
        let readLen: number = 0;
        while (readLen < Number(stat.size)) {
          const chunk = fs.readSync(file.fd, buf, { offset: readLen, length: Number(stat.size) - readLen });
          if (chunk <= 0) {
            break;
          }
          readLen += chunk;
        }
        const text: string = util.TextDecoder.create('utf-8')
          .decodeToString(new Uint8Array(buf, 0, readLen));
        const fileName: string = fileNameFromUri(uri);
        const count: number = await this.service.addLocalYaml(fileName, text, (): Promise<string> => this.requestAgeKey());
        // count 的契约是「本次导入是否成功」（provider-only 配置也算成功，返回 ≥1），
        // 不能当节点数用：旧实现直接报「解析出 1 个节点」，而配置里可能一个静态节点都没有。
        const parsedNodes: number = this.service.lastLocalImportNodes;
        if (count > 0 && parsedNodes > 0) {
          this.toast(`文件导入成功，解析出 ${parsedNodes} 个节点`);
          this.reload();
        } else if (count > 0) {
          // 只有策略组 / proxy-providers：原文已可用，节点等 provider 拉取后由内核给出
          this.toast('配置已导入 TunBox，节点将在加载订阅后显示');
          this.reload();
        } else {
          this.toast('文件里没有可用的 Clash 节点');
        }
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      const reason: string = AppLogger.errText(e);
      AppLogger.warn(TAG, `yaml import failed: ${reason}`);
      // 真实原因必须到达用户：addLocalYaml 抛出的 message 是"已保留旧配置：<判词>"，
      // picker/文件读写的 BusinessError 带 code。旧实现只说"请重试"，用户无从下手。
      this.toast(ImportFailureSummary.line('导入失败', reason), 4000);
    }
  }

  private async applyAdd(name: string, url: string): Promise<void> {
    const nextUrl: string = url.trim();
    if (nextUrl.length === 0) {
      this.toast('请填写订阅链接');
      return;
    }
    // 只接受 Clash 订阅链接：单节点分享链接（ss/vmess/vless/trojan/hysteria2/…）一律拒绝
    if (SubscriptionService.isNodeUri(nextUrl)) {
      this.toast('只支持 Clash 订阅链接，不支持单节点分享链接');
      return;
    }
    const lower: string = nextUrl.toLowerCase();
    if (!(lower.startsWith('https://') || lower.startsWith('http://'))) {
      this.toast('订阅链接必须以 http:// 或 https:// 开头');
      return;
    }
    if (lower.startsWith('http://') && !this.allowInsecureSubscriptionHttp) {
      this.toast('明文 HTTP 订阅未开启，请先打开下方开关');
      return;
    }
    let nextName: string = name.trim();
    if (nextName.length === 0) {
      nextName = nextUrl.replace(/^https?:\/\//i, '').split('/')[0];
    }
    try {
      const added: Subscription = await this.service.addSubscription(nextName, nextUrl, '', '');
      this.toast('✓ 已添加订阅');
      this.reload();
      // 订阅隔离（2026-10-28 用户要求）：新导入只刷新**它自己**。
      // 旧实现在这里调 refreshAll()，会把已有订阅按顺序全部重拉一遍，新订阅排在最后，
      // 用户必须等前面所有订阅刷新完才能看到节点 —— 这是被报障的"导入后一直转圈"。
      this.refreshOne(added).catch((e: Object): void => {
        AppLogger.warn(TAG, `refresh new subscription failed: ${AppLogger.errText(e)}`);
      });
    } catch (e) {
      AppLogger.warn(TAG, `add subscription failed: ${AppLogger.errText(e)}`);
      this.toast('添加失败，请检查链接');
    }
  }

  private async applyEdit(name: string, url: string, autoUpdate: boolean, intervalMinutes: number): Promise<void> {
    const target: Subscription | null = this.subById(this.editTargetId);
    if (target === null) {
      return;
    }
    const nextName: string = name.trim();
    const nextUrl: string = url.trim();
    if (nextName.length === 0) {
      this.toast('订阅名称不能为空');
      return;
    }
    const urlChanged: boolean = nextUrl.length > 0 && nextUrl !== target.url;
    target.name = nextName;
    if (nextUrl.length > 0) {
      target.url = nextUrl;
    }
    try {
      // 自动更新开关与间隔都写到**这个订阅自己**身上（2026-10-30 用户报障）。
      // 旧实现：`autoUpdate` 与 `subscriptionUpdateIntervalMinutes` 都写全局 AppSettings，
      // 于是「改一个订阅的刷新时间」= 「把所有订阅的刷新时间都改成它」。
      // 现在一次 persist 落盘（名称/URL/开关/间隔同一笔），不再碰全局设置。
      const rawInterval: number = Math.floor(intervalMinutes);
      const nextInterval: number = (Number.isFinite(rawInterval)
        && rawInterval >= MIN_UPDATE_INTERVAL_MINUTES
        && rawInterval <= MAX_UPDATE_INTERVAL_MINUTES) ? rawInterval : 360;
      target.autoUpdate = autoUpdate;
      target.updateIntervalMinutes = nextInterval;
      await this.service.updateSubscription(target);
      if (urlChanged) {
        await this.service.refreshSubscription(target.id);
      }
      this.toast('已保存');
    } catch (e) {
      AppLogger.warn(TAG, `update subscription failed: ${AppLogger.errText(e)}`);
      this.toast('保存失败，请重试');
    }
    this.reload();
  }

 

  private async deleteSub(id: string, name: string): Promise<void> {
    try {
      await this.service.removeSubscription(id);
      this.toast(`已删除 ${name}`);
      this.reload();
    } catch (e) {
      AppLogger.warn(TAG, `delete subscription failed: ${AppLogger.errText(e)}`);
      this.toast('删除失败，请重试');
    }
  }

  /** 保存成员意图后完整重启；启动阶段统一校验实际流量入口与出口。 */
  private async selectPanelMember(parent: ProxyGroup, node: ProxyNode): Promise<void> {
    if (this.selectingMember.length > 0 || !parent.members.includes(node.originalName || node.name)) { return; }
    const scope = this.panelSubId;
    if (parent.subscriptionId !== scope || node.subscriptionId !== scope) { return; }
    this.selectingMember = node.name;
    let savedIntent = false;
    try {
      const orch = ConnectionOrchestrator.instance();
      await SettingsService.patchSettings((settings: AppSettings): void => {
        settings.proxyGroupSelections = ProxyPanelMembers.remember(
          settings.proxyGroupSelections, scope, parent.name, node.name);
        settings.autoSelectMode = AutoSelectModes.MANUAL;
        settings.preferredNodeId = ProxyPanelMembers.isGroup(node) ? '' : node.id;
        settings.preferredNodeName = node.name;
        settings.preferredNodeSubscriptionId = scope;
        settings.preferredNodeNamesBySubscription = AppSettings.rememberPreferredNodeName(
          settings.preferredNodeNamesBySubscription, scope, node.name);
      });
      savedIntent = true;
      const loaded = await SettingsService.load();
      if (this.panelSubId === scope) {
        this.settings = loaded;
        this.coreRevision++;
        this.nodeRevision++;
        this.currentNodeName = node.name;
        this.smartSelected = false;
      }
      // 先通知主页更新选择，再等待代理重启。
      const revision: number = AppStorage.get<number>('node_switch_revision') ?? 0;
      AppStorage.setOrCreate('node_switch_revision', revision + 1);
      const restarted = await orch.reconnectWithNode(node, this.service, 'panel-member=' + node.name);
      if (restarted) {
        const ipRevision: number = AppStorage.get<number>('public_ip_revision') ?? 0;
        AppStorage.setOrCreate('public_ip_revision', ipRevision + 1);
      }
      this.toast(restarted ? `已选择 ${node.name}，代理已重启` : `已保存 ${node.name}`);
    } catch (e) {
      AppLogger.warn(TAG, `select panel member failed: ${AppLogger.errText(e)}`);
      this.toast(savedIntent ? '已保存选择，但代理重启失败，请重试' : '保存策略选择失败，请重试');
    } finally { this.selectingMember = ''; }
  }

  private async selectNode(node: ProxyNode): Promise<void> {
    // 静态节点优先回查本地定义；provider-only 影子没有本地凭据，但连接编排器会
    // 复用 profile 原文并按内核成员名钉选，不能在 UI 层把它拒绝掉。
    if (CoreNodeBridge.isShadow(node)) {
      const local = this.service.nodesOf(this.panelSubId).find((candidate): boolean => candidate.name === node.name);
      if (local !== undefined) {
        node = local;
      }
    }
    if (this.settings.autoSelectMode === AutoSelectModes.AUTO) {
      this.settings.autoSelectMode = AutoSelectModes.MANUAL;
    }
    this.settings.preferredNodeId = node.id;
    this.settings.preferredNodeName = node.name;
    if (node.subscriptionId.length > 0) {
      this.settings.preferredNodeSubscriptionId = node.subscriptionId;
      this.settings.selectedSubscriptionId = node.subscriptionId;
      this.settings.preferredNodeNamesBySubscription = AppSettings.rememberPreferredNodeName(
        this.settings.preferredNodeNamesBySubscription, node.subscriptionId, node.name);
    }
    this.currentNodeName = node.name;
    this.smartSelected = false;
    await SettingsService.patchSettings((s: AppSettings): void => {
      s.autoSelectMode = AutoSelectModes.MANUAL;
      s.preferredNodeId = node.id;
      s.preferredNodeName = node.name;
      if (node.subscriptionId.length > 0) {
        s.preferredNodeSubscriptionId = node.subscriptionId;
        s.selectedSubscriptionId = node.subscriptionId;
        s.preferredNodeNamesBySubscription = AppSettings.rememberPreferredNodeName(
          s.preferredNodeNamesBySubscription, node.subscriptionId, node.name);
      }
    });
    const nodeRev: number = AppStorage.get<number>('node_switch_revision') ?? 0;
    AppStorage.setOrCreate('node_switch_revision', nodeRev + 1);
    let restarted: boolean = false;
    try {
      restarted = await ConnectionOrchestrator.instance()
        .reconnectWithNode(node, this.service, 'home-section=' + node.id);
    } catch (e) {
      AppLogger.warn(TAG, `reconnect after pick failed: ${AppLogger.errText(e)}`);
      this.toast('已保存选择，但代理重启失败，请重试');
      this.reload();
      return;
    }
    if (restarted) {
      const rev: number = AppStorage.get<number>('public_ip_revision') ?? 0;
      AppStorage.setOrCreate('public_ip_revision', rev + 1);
      this.toast(`已选择 ${node.name}，代理已重启`);
    } else {
      this.toast(`已选择 ${node.name}`);
    }
    this.reload();
  }

  private toast(message: string, duration: number = 2000): void {
    promptAction.showToast({ message: message, duration: duration });
  }

  // ────────────────────────── 渲染 ──────────────────────────

  @Builder
  SmartRow() {
    Row({ space: 12 }) {
      Image($r('app.media.ic_radar')).width(22).height(22)
        .fillColor(TunBoxColors.primaryFor(this.themeRevision))
      Column({ space: 4 }) {
        Text('♻️ 自动选择').fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
        Text('Smart 智能选点 · 只在本订阅内择优').fontSize(11)
          .fontColor(TunBoxTextColors.secondaryFor(this.themeRevision))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Stack({ alignContent: Alignment.Center }) {
        Circle({ width: 20, height: 20 })
          .fill(this.smartSelected ? TunBoxColors.success : Color.Transparent)
          .stroke(this.smartSelected ? TunBoxColors.success : TunBoxColors.textMutedFor(this.themeRevision))
          .strokeWidth(1.6)
        if (this.smartSelected) {
          Circle({ width: 7, height: 7 }).fill(Color.White)
        }
      }
      .width(20).height(20).flexShrink(0)
      .accessibilityText(this.smartSelected ? '自动选择：已选中' : '自动选择：未选中')
    }
    .width('100%').padding({ top: 14, bottom: 14, left: 10, right: 10 })
    .borderRadius(TunBoxGeometry.controlRadius)
    .backgroundColor(this.smartSelected ? TunBoxColors.successTint : Color.Transparent)
    .enabled(this.selectingMember.length === 0)
    .onClick(() => this.selectSmart())
  }

  @Builder
  SectionHeader() {
    Row({ space: 8 }) {
      Text('订阅')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
      Text(`${this.subs.length}`)
        .fontSize(11)
        .fontColor(TunBoxTextColors.accentBlueFor(this.themeRevision))
        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
        .backgroundColor(TunBoxColors.primaryLightFor(this.themeRevision))
        .borderRadius(TunBoxGeometry.pillRadius)
      Blank()
      // 添加订阅：2026-10-28 用户要求「直接用 + 号，点击就弹添加订阅」
      Stack({ alignContent: Alignment.Center }) {
        Image($r('app.media.ic_plus')).width(18).height(18).fillColor(TunBoxColors.primaryFor(this.themeRevision))
      }
      .width(32).height(32)
      .borderRadius(TunBoxGeometry.pillRadius)
      .backgroundColor(TunBoxColors.primaryLightFor(this.themeRevision))
      .accessibilityText('添加订阅')
      .onClick((): void => { this.addDialog.open(); })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 卡片右上动作图标：测速 / 编辑 / 刷新。
   *
   * 2026-10-28 用户报障「折叠状态下点了测速/刷新，操作没完就展开订阅，右上角转圈永远不停，
   * 必须收起来再展开才恢复」。根因是 @Builder **按值传参不刷新**：`busy` 在展开那一刻
   * 被当成 true 捕获进覆盖层那棵树，操作结束后 state 虽已清掉，但那棵树的 if 分支不会被重新
   * 求值 → LoadingProgress 一直转。
   * 现在改成传**取值函数**，`if (busyRef())` 在渲染该节点时现读 `testingIds/refreshingIds`，
   * 状态依赖登记在 if 节点本身上，操作结束能精确触发这一个节点重算（列表与覆盖层都生效）。
   */
  @Builder
  CardAction(icon: Resource, label: string, busyRef: () => boolean, onTap: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      if (busyRef()) {
        LoadingProgress().width(18).height(18).color(TunBoxColors.primaryFor(this.themeRevision))
      } else {
        Image(icon).width(18).height(18).fillColor(TunBoxColors.textMutedFor(this.themeRevision))
      }
    }
    .width(40).height(40)
    .borderRadius(TunBoxGeometry.pillRadius)
    .flexShrink(0)
    .accessibilityText(label)
    // 关键：动作图标必须**吞掉**触摸，否则点击会冒泡到整张卡的 onClick
    // 直接打开节点面板（真机实测：点 ⚙ 弹出的是节点列表）。
    .hitTestBehavior(HitTestMode.Block)
    .onClick(onTap)
  }

  @Builder
  SubCard(sub: Subscription, tapToClose: boolean) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Stack({ alignContent: Alignment.Center }) {
          Image($r('app.media.ic_nodes')).width(18).height(18).fillColor(TunBoxColors.primaryFor(this.themeRevision))
        }
        .width(32).height(32)
        .borderRadius(8)
        .backgroundColor(TunBoxColors.primaryLightFor(this.themeRevision))

        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(sub.name.length > 0 ? sub.name : '未命名订阅')
              .fontSize(14).fontWeight(FontWeight.Bold).fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (sub.id === this.currentProfileId) {
              Text('使用中')
                .fontSize(10).fontWeight(FontWeight.Bold).fontColor(TunBoxTextColors.tagTextGreen)
                .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                .borderRadius(TunBoxGeometry.pillRadius)
                .backgroundColor(TunBoxTextColors.tagBgGreen)
                .flexShrink(0)
            }
          }.width('100%')
          Text(this.nodeCountText(sub).length > 0
            ? `${this.updateText(sub)} · ${this.nodeCountText(sub)}`
            : this.updateText(sub))
            .fontSize(11).fontColor(TunBoxTextColors.secondaryFor(this.themeRevision))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 顺序（2026-10-28 用户定稿）：测速 → 刷新 → 设置
        this.CardAction($r('app.media.ic_bolt'), '订阅测速', (): boolean => this.isTestingSub(sub.id),
          (): void => {
            this.testSub(sub.id, sub.name);
          })
        this.CardAction($r('app.media.ic_refresh'), '刷新订阅', (): boolean => this.isRefreshingSub(sub.id),
          (): void => {
            this.refreshOne(sub);
          })
        this.CardAction($r('app.media.ic_tune'), '编辑订阅', (): boolean => false, (): void => {
          this.openEdit(sub);
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Text(`↑ ${this.upText(sub)}`)
          .fontSize(12).fontWeight(FontWeight.Medium).fontColor(TunBoxTextColors.accentBlueFor(this.themeRevision))
          .maxLines(1)
        Text(`  ↓ ${this.downText(sub)}`)
          .fontSize(12).fontWeight(FontWeight.Medium).fontColor(TunBoxTextColors.accentGreen)
          .maxLines(1)
        Text(`  / ${this.totalText(sub)}`)
          .fontSize(11).fontColor(TunBoxTextColors.mutedFor(this.themeRevision))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.expiryText(sub))
          .fontSize(11).fontColor(TunBoxTextColors.secondaryFor(this.themeRevision))
          .maxLines(1)
          .flexShrink(0)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(6)
          .borderRadius(3)
          .backgroundColor(TunBoxColors.controlTrack(this.themeRevision))
        if (this.usageRatio(sub) >= 0) {
          Row()
            .width(`${Math.max(2, Math.round(this.usageRatio(sub) * 100))}%`)
            .height(6)
            .borderRadius(3)
            .linearGradient({
              angle: 90,
              colors: [[TunBoxColors.primaryFor(this.themeRevision), 0.0], [TunBoxColors.success, 1.0]]
            })
        }
      }
      .width('100%')
      .height(6)
      .clip(true)
    }
    .width(tapToClose ? '94%' : '100%')
    .margin({ left: tapToClose ? '3%' : 0, right: tapToClose ? '3%' : 0 })
    .padding(14)
    .alignItems(HorizontalAlign.Start)
    .borderRadius(TunBoxGeometry.cardRadiusSmall)
    .backgroundColor(TunBoxColors.surfaceCard(this.themeRevision))
    .border({
      width: sub.id === this.currentProfileId ? 1.5 : 1,
      color: sub.id === this.currentProfileId ? TunBoxColors.primaryFor(this.themeRevision) : TunBoxColors.cardBorder(this.themeRevision)
    })
    .onClick((): void => {
      if (tapToClose) {
        this.closePanel();
      } else {
        this.onHeaderTap(sub);
      }
    })
  }

  /**
   * 分组 chip。**不要**把「是否选中」作为 @Builder 值参数传进来 —— ArkUI 的
   * @Builder 值参数不参与响应式更新，点完高亮不会切（真机复现：点了没反应）。
   * 这里直接读 state，点击即切换。
   */
  @Builder
  GroupChip(name: string) {
    Text(name)
      .fontSize(12)
      .fontWeight(this.selectedGroup === name ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.selectedGroup === name ? TunBoxColors.textOnPrimary : TunBoxTextColors.secondaryFor(this.themeRevision))
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(TunBoxGeometry.pillRadius)
      .backgroundColor(this.selectedGroup === name ? TunBoxColors.primaryFor(this.themeRevision) : TunBoxColors.chipBg(this.themeRevision))
      .maxLines(1)
      .flexShrink(0)
      .onClick((): void => { this.selectedGroup = name; })
  }

  /**
   * 节点行（2026-10-28 用户定稿，按 Plus 截图排布）：
   * 左：节点名（主行）+ 协议（小字灰色，名称下方）；中右：延迟；最右：单选圈。
   * 选中行整行浅绿底，行间用细分隔线（不再是独立卡片块）。
   */
  @Builder
  NodeRow(node: ProxyNode) {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text(node.name)
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.protoOf(node))
          .fontSize(11).fontColor(TunBoxTextColors.mutedFor(this.themeRevision))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(this.pingText(node))
        .fontSize(13).fontWeight(FontWeight.Bold).fontColor(this.pingColor(node))
        .flexShrink(0)

      // 右侧圆圈：删除选择态下是「勾选框」，平时是「当前节点单选圈」（2026-10-29）
      if (this.deleteSheetOn) {
        Stack({ alignContent: Alignment.Center }) {
          Circle({ width: 20, height: 20 })
            .fill(this.isDeleteChecked(node.id) ? TunBoxColors.danger : Color.Transparent)
            .stroke(this.isDeleteChecked(node.id) ? TunBoxColors.danger : TunBoxColors.textMutedFor(this.themeRevision))
            .strokeWidth(1.6)
          if (this.isDeleteChecked(node.id)) {
            Text('✓').fontSize(12).fontColor(Color.White).fontWeight(FontWeight.Bold)
          }
        }.width(20).height(20)
      } else {
        Stack({ alignContent: Alignment.Center }) {
          Circle({ width: 20, height: 20 })
            .fill(this.isActiveNode(node) ? TunBoxColors.success : Color.Transparent)
            .stroke(this.isActiveNode(node) ? TunBoxColors.success : TunBoxColors.textMutedFor(this.themeRevision))
            .strokeWidth(1.6)
          if (this.isActiveNode(node)) {
            Circle({ width: 7, height: 7 }).fill(Color.White)
          }
        }
        .width(20).height(20)
        // 圆圈 = 显式「选为当前组成员」（组行点行同样选为成员，圆圈留着给手滑/误触兜底）
        .onClick((): void => { this.selectAsMember(node); })
        .accessibilityText(`选为成员：${node.name}`)
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .backgroundColor(this.deleteSheetOn
      ? (this.isDeleteChecked(node.id) ? TunBoxColors.dangerLight : Color.Transparent)
      : (this.isActiveNode(node) ? TunBoxColors.successTint : Color.Transparent))
    .border({ width: { bottom: 1 }, color: TunBoxColors.cardBorder(this.themeRevision) })
    .alignItems(VerticalAlign.Center)
    // 长按任意节点 → 底部删除弹层（2026-10-29 用户要求）
    .gesture(LongPressGesture({ repeat: false, duration: 400 })
      .onAction((): void => { this.handleNodeLongPress(node); }))
    .onClick((): void => { this.handleNodeTap(node); })
  }

  /**
   * 双列模式下的紧凑单元格（2026-11-03 用户要求：节点页可切「双列 / 单列」）。
   * 与 `NodeRow` 同源：同样的 名称 / 协议 / 延迟 / 单选圈，只是排成竖版小卡，
   * 点击与长按直接复用 `handleNodeTap` / `handleNodeLongPress`，两列宽度各占一半。
   * 固定高度 68vp：两列里名称行数不同也不会把整行撑歪。
   */
  @Builder
  NodeCell(node: ProxyNode) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text(node.name)
          .fontSize(13).fontWeight(FontWeight.Medium).fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        // 右侧圆圈：与 NodeRow 一样，删除选择态下变勾选框（2026-10-29 语义保持不变）
        if (this.deleteSheetOn) {
          Stack({ alignContent: Alignment.Center }) {
            Circle({ width: 18, height: 18 })
              .fill(this.isDeleteChecked(node.id) ? TunBoxColors.danger : Color.Transparent)
              .stroke(this.isDeleteChecked(node.id) ? TunBoxColors.danger : TunBoxColors.textMutedFor(this.themeRevision))
              .strokeWidth(1.5)
            if (this.isDeleteChecked(node.id)) {
              Text('✓').fontSize(11).fontColor(Color.White).fontWeight(FontWeight.Bold)
            }
          }.width(18).height(18).flexShrink(0)
        } else {
          Stack({ alignContent: Alignment.Center }) {
            Circle({ width: 18, height: 18 })
              .fill(this.isActiveNode(node) ? TunBoxColors.success : Color.Transparent)
              .stroke(this.isActiveNode(node) ? TunBoxColors.success : TunBoxColors.textMutedFor(this.themeRevision))
              .strokeWidth(1.5)
            if (this.isActiveNode(node)) {
              Circle({ width: 6, height: 6 }).fill(Color.White)
            }
          }
          .width(18).height(18).flexShrink(0)
          .onClick((): void => { this.selectAsMember(node); })
          .accessibilityText(`选为成员：${node.name}`)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: 6 }) {
        Text(this.protoOf(node))
          .fontSize(10).fontColor(TunBoxTextColors.mutedFor(this.themeRevision))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.pingText(node))
          .fontSize(12).fontWeight(FontWeight.Bold).fontColor(this.pingColor(node))
          .flexShrink(0)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .layoutWeight(1)
    .height(68)
    .justifyContent(FlexAlign.SpaceBetween)
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(10)
    .backgroundColor(this.deleteSheetOn
      ? (this.isDeleteChecked(node.id) ? TunBoxColors.dangerLight : TunBoxColors.chipBg(this.themeRevision))
      : (this.isActiveNode(node) ? TunBoxColors.successTint : TunBoxColors.chipBg(this.themeRevision)))
    .border({ width: 1, color: TunBoxColors.cardBorder(this.themeRevision) })
    .gesture(LongPressGesture({ repeat: false, duration: 400 })
      .onAction((): void => { this.handleNodeLongPress(node); }))
    .onClick((): void => { this.handleNodeTap(node); })
  }

  /**
   * 节点行的点击行为（单列 `NodeRow` 与双列 `NodeCell` 共用，2026-11-03 抽取）。
   *
   * 2026-11-03 用户口径（对齐 FlClash）：**组行本身就是可选项**，点一下即把该子组
   * 选为当前组的成员；2026-11-05 按用户要求选择后保留面板，不自动返回主页。
   * 想单独看某个组的成员，用顶部那排分组 chips 切组。
   */
  private handleNodeTap(node: ProxyNode): void {
    if (this.suppressClick) {
      this.suppressClick = false;
      return;
    }
    // 选择态下点行 = 勾选/取消勾选，不再切换节点（2026-10-29 用户要求：
    // 「直接在节点页进行选择多个节点」）
    if (this.deleteSheetOn) {
      if (ProxyPanelMembers.isGroup(node)) { return; }
      this.toggleDeleteId(node.id);
      return;
    }
    const parent = this.activeGroupOf(this.panelSubId);
    // 组行直接当成员选中，保留面板；不下钻。
    if (ProxyPanelMembers.isGroup(node)) {
      this.selectAsMember(node);
      return;
    }
    if (parent !== null && ProxyPanelMembers.type(parent.groupType) === 'Selector') {
      this.selectPanelMember(parent, node);
    } else {
      this.selectNode(node);
    }
  }

  /** 组行右侧圆圈：把该子组/节点选为当前组（父组）的成员。 */
  private selectAsMember(node: ProxyNode): void {
    const parent = this.activeGroupOf(this.panelSubId);
    if (parent === null) { return; }
    this.selectPanelMember(parent, node);
  }

  /** 长按行为（单列与双列共用）：先吞掉抬手后的补发 onClick，再进入删除选择态。 */
  private handleNodeLongPress(node: ProxyNode): void {
    this.suppressClick = true;
    this.openDeleteSheet(node);
    // 长按抬手后系统还会补发一次 onClick（会把刚勾上的节点又取消掉），用一次性开关吞掉它。
    // 必须定时自动复位（2026-10-29 真机 bug）：原来靠「下一次点击」来清标志，
    // 但长按发生在 A 行、用户接着点 B 行，B 行那一下就被白白吃掉了（多选点不动）。
    setTimeout((): void => { this.suppressClick = false; }, 350);
  }

  /**
   * 长按节点进入删除选择态（2026-10-29 用户要求改版）：
   * 先勾中长按的这个（= 单独删除）；已在选择态时再长按就是切换勾选。
   * 选择本身全在节点列表里完成，底部只留一条「取消 / 删除」操作条。
   */
  private openDeleteSheet(node: ProxyNode): void {
    if (ProxyPanelMembers.isGroup(node)) {
      this.toast('策略组由配置管理，不能作为节点删除');
      return;
    }
    // provider-only 影子由远端 provider 管理，本地没有可删除的节点台账。
    if (CoreNodeBridge.isShadow(node)) {
      this.toast('该节点由远端 provider 管理，不能在本地删除');
      return;
    }
    if (!this.deleteSheetOn) {
      this.deleteSheetOn = true;
      this.deleteSheetIds = [node.id];
      return;
    }
    this.toggleDeleteId(node.id);
  }

  private closeDeleteSheet(): void {
    this.deleteSheetOn = false;
    this.deleteSheetIds = [];
  }

  private isDeleteChecked(id: string): boolean {
    return this.deleteSheetIds.indexOf(id) >= 0;
  }

  private toggleDeleteId(id: string): void {
    if (this.isDeleteChecked(id)) {
      this.deleteSheetIds = this.deleteSheetIds.filter((x: string): boolean => x !== id);
    } else {
      this.deleteSheetIds = this.deleteSheetIds.concat([id]);
    }
  }

  /**
   * 真删：逐个走 `service.removeNode`（失败不中断，最后汇报成功数）。
   * 与 `NodeSelectionPage` 的批量删除是同一套台账（拉黑进 hiddenNodes），
   * 订阅刷新时自动过滤，不是只在界面上抹掉。
   */
  private async applyDeleteNodes(): Promise<void> {
    const ids: string[] = this.deleteSheetIds.slice();
    if (ids.length === 0) {
      return;
    }
    let okCount: number = 0;
    let removedActive: boolean = false;
    for (const id of ids) {
      if (this.settings.preferredNodeId === id) {
        removedActive = true;
      }
      const ok: boolean = await this.service.removeNode(id);
      if (ok) {
        okCount += 1;
      }
    }
    if (removedActive) {
      // 删掉的正是当前节点：必须清空偏好三件套，否则启动/重连会去解析一个已不存在的节点
      this.settings.preferredNodeId = '';
      this.settings.preferredNodeName = '';
      await SettingsService.patchSettings((s: AppSettings): void => {
        s.preferredNodeId = '';
        s.preferredNodeName = '';
        s.preferredNodeSubscriptionId = '';
      });
      this.currentNodeName = '';
    }
    this.deleteSheetOn = false;
    this.deleteSheetIds = [];
    this.nodeRevision += 1;
    this.reload();
    this.toast(okCount === ids.length
      ? `已删除 ${okCount} 个节点`
      : `已删除 ${okCount}/${ids.length} 个（部分失败，可重试）`);
  }

  /** 底部删除操作条（只有取消/删除，选择在节点页完成；2026-10-29 用户要求） */
  @Builder
  NodeDeleteBar() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 不再有遮罩、也没有独立的勾选列表（2026-10-29 用户要求：
      // 「弹窗只有取消和删除按钮就行了，直接在节点页进行选择多个节点，
      //   不要单独再起一个页去选中节点」）。
      // 这里只留一条底部操作条：标题 + 取消 / 删除。没有遮罩，
      // 所以上方节点列表仍可直接点选（列表底部已预留 108vp 不被这条挡住）。
      Column({ space: 0 }) {
        Row({ space: 8 }) {
          Text('删除节点')
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
          Blank()
          Text(this.deleteSheetIds.length > 0 ? `已选 ${this.deleteSheetIds.length}` : '未选择')
            .fontSize(12).fontColor(TunBoxTextColors.mutedFor(this.themeRevision))
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 2 })

        Text('点上方节点可多选；删除后重新导入订阅可恢复。')
          .fontSize(11).fontColor(TunBoxTextColors.mutedFor(this.themeRevision))
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 4 })

        Row({ space: 10 }) {
          Button('取消')
            .layoutWeight(1).height(44).fontSize(14)
            .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
            .backgroundColor(TunBoxColors.chipBg(this.themeRevision))
            .borderRadius(TunBoxGeometry.controlRadius)
            .onClick((): void => { this.closeDeleteSheet(); })
          Button(this.deleteSheetIds.length > 0 ? `删除 ${this.deleteSheetIds.length} 个` : '删除')
            .layoutWeight(1).height(44).fontSize(14).fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .backgroundColor(this.deleteSheetIds.length > 0 ? TunBoxColors.danger : TunBoxColors.textMutedFor(this.themeRevision))
            .borderRadius(TunBoxGeometry.controlRadius)
            .enabled(this.deleteSheetIds.length > 0)
            .onClick((): void => { this.applyDeleteNodes(); })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 12 })
      }
      .width('100%')
      .backgroundColor(TunBoxColors.surfaceCard(this.themeRevision))
      .borderRadius({ topLeft: 20, topRight: 20 })
      .padding({ bottom: 22 })
      .transition(TransitionEffect.move(TransitionEdge.BOTTOM).animation({ duration: 240, curve: Curve.EaseOut }))
    }
    .width('100%')
    // ⚠ 绝不能写 .height('100%')：本 builder 是面板 Stack 的最后一个孩子，
    // 一个撑满全屏、又没有遮罩的空 Stack 在 ArkUI 默认 HitTestMode.Default 下
    // 会**拦住下方所有兄弟节点的触摸事件**。真机表现（2026-10-29 实测）：
    // 进入选择态后，点节点列表完全没反应（勾不上第二个），看着像手势没绑上。
    // 去掉后高度随内容收缩，只剩底部那条操作条占位，上方列表恢复可点。
  }

  /**
   * 全屏覆盖层（2026-10-28 第二次定稿）：
   * 顶部不再是标题栏，而是**订阅卡片本身当固定表头**（点卡片或底部按钮都可返回）；
   * 其下只有订阅自带的分组 chips（不再有「全部」「按延迟」），再下面是节点列表。
   */
  @Builder
  NodePanelCover() {
    // 外层 Stack 只为承载「长按删除」底部弹层（2026-10-29）；面板本体仍是下面这个全屏 Column，
    // 属性一个没动，所以内层缩进保持原样（不做大面积重排，避免引入无意义 diff）。
    Stack({ alignContent: Alignment.Bottom }) {
    Column({ space: 0 }) {
      Column({ space: 10 }) {
        if (this.panelSub() !== null) {
          // 用带忙碌态的 key 包一层 ForEach：@Builder 的按值传参不会随状态刷新，
          // 展开时若正好在测速/刷新，卡片会被「定格」在转圈状态（见 CardAction 注释）。
          ForEach([this.panelSub() as Subscription], (sub: Subscription): void => {
            this.SubCard(sub, true)
          }, (sub: Subscription): string => `${sub.id}|${this.currentNodeName}`
            + `|${sub.uploadBytes}|${sub.downloadBytes}|${this.refreshingIds.join(',')}|${this.testingIds.join(',')}`)
        }

        // 分组 chips + 排序方式同一行（分组左、排序右；分组多了左侧横向滚动）
        Row({ space: 8 }) {
          Scroll() {
            Row({ space: 8 }) {
              if (this.groupsOf(this.panelSubId).length > 0) {
                ForEach(this.groupsOf(this.panelSubId), (g: ProxyGroup) => {
                  this.GroupChip(g.name)
                }, (g: ProxyGroup) => `${g.subscriptionId}|${g.name}`)
              }
            }
            .padding({ left: 24, right: 8 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .layoutWeight(1)

          // 2026-11-03 用户要求：在「按延迟」左边加一个双列 / 单列显示切换按钮。
          // 图标表示「点一下会变成什么」：单列时显示双列图标，反之亦然。
          Row({ space: 4 }) {
            Image(this.gridMode ? $r('app.media.ic_view_list') : $r('app.media.ic_view_grid'))
              .width(13).height(13).fillColor(TunBoxColors.textMutedFor(this.themeRevision))
          }
          .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          .borderRadius(TunBoxGeometry.pillRadius)
          .backgroundColor(TunBoxColors.chipBg(this.themeRevision))
          .accessibilityText(this.gridMode ? '切换为单列显示' : '切换为双列显示')
          .onClick((): void => { this.gridMode = !this.gridMode; })

          Row({ space: 4 }) {
            Image($r('app.media.ic_sort')).width(13).height(13).fillColor(TunBoxColors.textMutedFor(this.themeRevision))
            Text(this.sortByDelay ? '按延迟' : '原始')
              .fontSize(11).fontColor(TunBoxTextColors.mutedFor(this.themeRevision)).maxLines(1)
          }
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(TunBoxGeometry.pillRadius)
          .backgroundColor(TunBoxColors.chipBg(this.themeRevision))
          .margin({ right: 24 })
          .accessibilityText('切换节点排序')
          .onClick((): void => {
            this.sortByDelay = !this.sortByDelay;
            // FlClash 记忆排序选择：写回 AppSettings（下次进面板仍按同一口径）
            SettingsService.patchSettings((s: AppSettings): void => {
              s.nodeListSortMode = this.sortByDelay ? 'delay' : 'default';
            }).catch((): void => {});
          })

        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ top: 8, bottom: 8 })

      if (this.panelNodes().length === 0 && !this.smartVisible) {
        Column({ space: 6 }) {
          // 2026-11-03 用户报障「本地 YAML 一直 0 节点、测速说没有可用代理」：那份模板里
          // 只有一个 `直连` + provider 占位符 url，本来就没有真实代理。空状态必须说清
          // 是「没有代理」还是「这个组为空」，否则用户会以为功能坏了。
          Text(this.subHasRealProxy() ? '该分组暂无可用节点' : '该订阅没有真实代理节点（0 节点）')
            .fontSize(13).fontColor(TunBoxTextColors.mutedFor(this.themeRevision))
          Text(this.subHasRealProxy()
            ? '换一个分组，或用卡片上的刷新按钮更新订阅'
            : '配置里只有策略组/直连：常见原因是 proxy-providers 的订阅地址还是模板占位符，'
              + '填好真实地址后重新导入或刷新')
            .fontSize(11).fontColor(TunBoxTextColors.mutedFor(this.themeRevision))
            .textAlign(TextAlign.Center)
            .padding({ left: 32, right: 32 })
        }
        .width('100%')
        .padding({ top: 40 })
        .alignItems(HorizontalAlign.Center)
        .layoutWeight(1)
      } else {
        List({ space: 0 }) {
          if (this.smartVisible && !this.deleteSheetOn) {
            ListItem() { this.SmartRow() }
          }
          // 2026-11-03 用户第二轮口径（对齐 FlClash）：组行就是可选项，点一下直接选中，
          // 不展开、不下钻，所以列表里没有「上级：xxx」这一行（ClashPlus/FlClash 都没有）。
          ForEach(this.panelNodeRows(), (row: ProxyNode[]) => {
            ListItem() {
              if (this.gridMode) {
                // 双列：一行两个紧凑单元格；节点总数为奇数时最后一行只占左半边。
                Row({ space: 10 }) {
                  this.NodeCell(row[0])
                  if (row.length > 1) {
                    this.NodeCell(row[1])
                  } else {
                    Blank().layoutWeight(1)
                  }
                }
                .width('100%')
                .padding({ top: 5, bottom: 5 })
              } else {
                this.NodeRow(row[0])
              }
            }
          }, (row: ProxyNode[]): string => this.panelRowKey(row))
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 24, right: 24 })
        // 选择态下给底部操作条让位（操作条高约 100vp）
        .margin({ bottom: this.deleteSheetOn ? 108 : 0 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .fadingEdge(true, { fadingEdgeLength: LengthMetrics.vp(TunBoxGeometry.scrollFadeEdge) })
      }

      // 底部返回：与页面背景同色，融为一体
      Button('返回')
        .width('100%')
        .height(44)
        .fontSize(14)
        .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
        .backgroundColor(TunBoxColors.background(this.themeRevision))
        .borderRadius(TunBoxGeometry.controlRadius)
        .margin({ left: 24, right: 24, top: 4, bottom: 12 })
        .onClick((): void => {
          // 删除选择态下「返回」先退出选择态（不直接关面板），否则误触会把整个面板关掉
          if (this.deleteSheetOn) {
            this.closeDeleteSheet();
            return;
          }
          this.closePanel();
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(TunBoxColors.background(this.themeRevision))
    .padding({ top: this.statusBarH })
    .opacity(this.panelAnimating ? 0 : 1)
    .scale({ x: this.panelAnimating ? 0.88 : 1, y: this.panelAnimating ? 0.88 : 1 })
    .animation({ duration: 260, curve: Curve.EaseOut })

    if (this.deleteSheetOn) {
      this.NodeDeleteBar()
    }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Column({ space: 10 }) {
      this.SectionHeader()

      if (this.subs.length === 0) {
        Row({ space: 8 }) {
          Image($r('app.media.ic_nodes')).width(18).height(18).fillColor(TunBoxColors.textMutedFor(this.themeRevision))
          Text('还没有订阅，点右上菜单「添加订阅」')
            .fontSize(12).fontColor(TunBoxTextColors.mutedFor(this.themeRevision))
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding(TunBoxGeometry.cardPadding)
        .borderRadius(TunBoxGeometry.cardRadiusSmall)
        .backgroundColor(TunBoxColors.surfaceCard(this.themeRevision))
        .border({ width: 1, color: TunBoxColors.cardBorder(this.themeRevision) })
        .onClick((): void => { this.addDialog.open(); })
      } else {
        ForEach(this.subs, (sub: Subscription, index: number) => {
          // 长按拖动排序（2026-10-30 用户要求）：长按 380ms 后进入拖动，竖向跟手移动，
          // 松手按实际位移重排并落盘。用 GestureGroup(Sequence) 保证「先长按、后拖拽」的时序，
          // 普通点击/卡片内按钮不受影响（长按不触发 onClick）。
          Column() {
            this.SubCard(sub, false)
          }
          .width('100%')
          .translate({ y: this.dragSubId === sub.id ? this.dragDy : 0 })
          .zIndex(this.dragSubId === sub.id ? 2 : 0)
          .opacity(this.dragSubId === sub.id ? 0.96 : 1)
          .scale(this.dragSubId === sub.id ? { x: 1.02, y: 1.02 } : { x: 1, y: 1 })
          .shadow(this.dragSubId === sub.id
            ? { radius: 16, color: '#33000000', offsetX: 0, offsetY: 6 }
            : { radius: 0, color: '#00000000', offsetX: 0, offsetY: 0 })
          .onAreaChange((_oldArea: Area, nextArea: Area): void => {
            this.subCardHeights[index] = Number(nextArea.height);
          })
          .gesture(
            GestureGroup(GestureMode.Sequence,
              LongPressGesture({ repeat: false, duration: 380 })
                .onAction((): void => {
                  this.beginSubDrag(sub.id, index);
                }),
              PanGesture({ direction: PanDirection.Vertical, distance: 3 })
                .onActionUpdate((event: GestureEvent): void => {
                  this.updateSubDrag(event.offsetY);
                })
                .onActionEnd((): void => {
                  this.endSubDrag();
                })
            )
          )
        }, (sub: Subscription) => `${sub.id}|${sub.name}|${this.currentProfileId}|${this.currentNodeName}`
          + `|${sub.uploadBytes}|${sub.downloadBytes}|${this.refreshingIds.join(',')}|${this.testingIds.join(',')}`)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .bindContentCover(this.showPanel, this.NodePanelCover(), {
      modalTransition: ModalTransition.NONE,
      backgroundColor: TunBoxColors.background(this.themeRevision),
      onDisappear: (): void => {
        this.showPanel = false;
        // 面板关闭时清掉删除选择态，否则下次进来还挂着上次的勾选
        this.closeDeleteSheet();
      }
    })
  }
}
