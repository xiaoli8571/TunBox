/**
 * BackupPage —— 配置备份与恢复（2026-10-27 从主页右上角「备份」迁出）
 *
 * 功能与迁移前等价：导出订阅/节点/规则/设置的 .json（可选 AES-256-GCM 加密）、
 * 系统文件选择器导入、加密备份密码重试（最多 3 次）、恢复后重载设置。
 * 入口在「设置 → 关于与隐私 → 配置备份与恢复」。
 */
import { promptAction } from '@kit.ArkUI';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { TunBoxColors, TunBoxGeometry } from '../theme/TunBoxTokens';
import { TopNavBar } from '../components/TopNavBar';
import { SettingsService } from '../commons/services/SettingsService';
import { AppSettings } from '../commons/models/AppSettings';
import { BackupRestoreService, RestoreOutcome } from '../commons/services/BackupRestoreService';
import { BackupCrypto } from '../commons/services/BackupCrypto';
import { AppLogger } from '../commons/utils/AppLogger';

const TAG = 'BackupPage';

/**
 * 备份密码输入弹窗：导出/导入加密备份时收集密码。
 * mode: 'export'（确认导出，可选留空=明文）| 'import'（必填密码解密，失败可重试）
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
    // 沉浸光感：材质由系统托管，根容器不设不透明底色/模糊/自定义阴影。
  }
}

@Entry
@Component
struct BackupPage {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @State toastMsg: string = '';
  private settings: AppSettings = new AppSettings();
  private exportPassword: string = '';
  private exportPending: boolean = false;
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
          this.doExport();
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

  aboutToAppear(): void {
    this.bootstrap();
  }

  private async bootstrap(): Promise<void> {
    const ctx = getContext(this) as Context;
    await SettingsService.init(ctx);
    this.settings = await SettingsService.load();
  }

  private async onExportClick(): Promise<void> {
    // 打开密码弹窗前先取盘上最新设置，避免页面刚创建时导出到默认值。
    this.settings = await SettingsService.load();
    // 先经密码弹窗收集可选密码（留空=明文），确认后再走系统文件选择器。
    this.exportPending = true;
    this.importDialogMode = 'export';
    this.importHint = '';
    this.exportPassword = '';
    this.backupPasswordDialog.open();
  }

  /** 导出：快照 → JSON → 可选密码加密 → 系统文件选择器另存 */
  private async doExport(): Promise<void> {
    try {
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
      this.toastMsg = '✓ 备份文件已成功导出！';
      promptAction.showToast({ message: `备份已导出：${savedName}` });
      AppLogger.info(TAG, `backup exported: ${uris[0]}`);
    } catch (e) {
      this.toastMsg = '';
      promptAction.showToast({ message: '导出备份失败，请重试' });
      AppLogger.error(TAG, `backup export failed: ${AppLogger.errText(e)}`);
    }
  }

  /** 导入：系统文件选择器挑 .json → 加密则先要密码 → 校验恢复 */
  private async onImportClick(): Promise<void> {
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
    this.exportPending = false;
    this.importHint = hint;
    this.importDialogMode = 'import';
    this.backupPasswordDialog.open();
  }

  private finishImport(text: string): void {
    BackupRestoreService.importJsonText(text).then((outcome: RestoreOutcome): void => {
      this.applyImportOutcome(outcome);
    }).catch((): void => {
      promptAction.showToast({ message: '导入失败，请重试' });
    });
  }

  /** 导入结果应用：恢复成功则重载设置/订阅并提示 */
  private applyImportOutcome(outcome: RestoreOutcome): void {
    if (!outcome.ok) {
      promptAction.showToast({ message: outcome.message });
      return;
    }
    this.toastMsg = `✓ 恢复成功！已导入 ${outcome.subCount} 个订阅及自定义规则`;
    promptAction.showToast({ message: this.toastMsg });
    SettingsService.load().then((loaded: AppSettings): void => {
      this.settings = loaded;
      // 备份可能带走主题/订阅/节点，通知各页在下次展示时重载。
      AppStorage.setOrCreate('theme_revision', (AppStorage.get<number>('theme_revision') ?? 0) + 1);
      AppStorage.setOrCreate('subscription_revision',
        (AppStorage.get<number>('subscription_revision') ?? 0) + 1);
      AppStorage.setOrCreate('public_ip_revision',
        (AppStorage.get<number>('public_ip_revision') ?? 0) + 1);
    }).catch((): void => {});
  }

  @Builder
  BackupCard(title: string, desc: string, buttonLabel: string, primary: boolean, action: () => void) {
    Column({ space: 6 }) {
      Text(title).fontSize(13).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.textPrimary).width('100%')
      Text(desc).fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
      Button(buttonLabel)
        .width('100%').borderRadius(8).fontSize(12.5)
        .backgroundColor(primary ? TunBoxColors.primary : TunBoxColors.surfaceCard)
        .fontColor(primary ? Color.White : TunBoxColors.textPrimary)
        .borderWidth(primary ? 0 : 1.5)
        .borderColor(TunBoxColors.cardBorder)
        .onClick(action)
    }
    .width('100%').padding(12).borderRadius(12)
    .backgroundColor(TunBoxColors.background)
    .borderWidth(1).borderColor(TunBoxColors.cardBorder)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column().width('100%').height('100%')
        .linearGradient({ angle: 180, colors: [[TunBoxColors.bgGradientStart, 0.0], [TunBoxColors.bgGradientEnd, 1.0]] })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        TopNavBar({ title: '配置备份与恢复', hasBack: true })
        Scroll() {
          Column({ space: 14 }) {
            Column({ space: 8 }) {
              Row({ space: 8 }) {
                Image($r('app.media.ic_doc')).width(20).height(20).fillColor(TunBoxColors.primary)
                Text('配置备份与恢复').fontSize(16).fontWeight(FontWeight.Bold)
                  .fontColor(TunBoxColors.textPrimary).layoutWeight(1)
              }.width('100%')
              Text('备份范围包括当前全部已导入的订阅、节点以及自定义规则配置。')
                .fontSize(12).fontColor(TunBoxColors.textMuted).width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })

            this.BackupCard('📤 导出当前配置备份',
              '生成包含所有订阅和规则的 .json 备份文件，便于多设备同步或留存。',
              '导出备份文件 (.json)', true, (): void => {
                this.onExportClick();
              })
            this.BackupCard('📥 导入恢复配置',
              '上传备份的 .json 配置文件，一键恢复所有订阅及自定义规则。',
              '选择备份文件并恢复', false, (): void => {
                this.onImportClick();
              })

            if (this.toastMsg.length > 0) {
              Text(this.toastMsg)
                .fontSize(11.5).fontWeight(FontWeight.Bold).fontColor(Color.White)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .borderRadius(9999).backgroundColor(TunBoxColors.success)
                .width('100%').textAlign(TextAlign.Center)
            }
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
}
