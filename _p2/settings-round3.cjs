/**
 * 设置页第三轮（2026-10-23 用户口径）：
 *  ① 订阅转换卡补图标（ic_swap）：设置页所有卡统一「图标 + 标题」的 SectionHeader 节奏；
 *  ② 主题跟随系统 从「外观与网络」挪到「关于与隐私」卡里，夹在 版本 与 查看隐私政策 中间；
 *  ③ 「外观与网络」改名「系统」，并把「音频保活」并进来（删掉独立的「后台连接」卡）。
 */
const fs = require('node:fs');
const p = 'entry/src/main/ets/pages/SettingsPage.ets';
const raw = fs.readFileSync(p, 'utf8');
const crlf = raw.includes('\r\n');
let t = raw.replace(/\r\n/g, '\n');

// ── ① 订阅转换卡加图标 ──
const oldHead = `            // ── 订阅转换（2026-10-22 用户要求：非 Clash 订阅 → mihomo 订阅）──
            Column({ space: 8 }) {
              Row() {
                Column({ space: 3 }) {
                  Text('订阅转换').fontSize(14).fontWeight(FontWeight.Bold)
                    .fontColor(TunBoxColors.textPrimary).width('100%')
                  Text('分享链接转成 mihomo 配置，可保存到本地或一键导入订阅列表。')
                    .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Text('打开').fontSize(13).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.primary)`;
const newHead = `            // ── 订阅转换（2026-10-22 用户要求：非 Clash 订阅 → mihomo 订阅）──
            // 2026-10-23：补图标（ic_swap），与其余卡片统一「图标 + 标题」的抬头节奏。
            Column({ space: 8 }) {
              Row({ space: 8 }) {
                Image($r('app.media.ic_swap')).width(18).height(18).fillColor(TunBoxColors.primary)
                Column({ space: 3 }) {
                  Text('订阅转换').fontSize(15).fontWeight(FontWeight.Bold)
                    .fontColor(TunBoxColors.textPrimary).width('100%')
                  Text('分享链接转成 mihomo 配置，可保存到本地或一键导入订阅列表。')
                    .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Text('打开').fontSize(13).fontWeight(FontWeight.Bold).fontColor(TunBoxColors.primary)`;
if (!t.includes(oldHead)) { console.log('CONV HEAD MISS'); process.exit(1); }
t = t.replace(oldHead, newHead);

// ── ② 摘出「主题跟随系统」那一组（标题行 + 说明 + 分区分隔线） ──
const themeStart = `              Row() {
                Text('主题跟随系统')`;
const themeEnd = `              Divider().color(TunBoxColors.cardBorder)

              Row() {
                Text('IPv6 双栈')`;
const ti = t.indexOf(themeStart);
if (ti < 0) { console.log('THEME MISS'); process.exit(1); }
const tj = t.indexOf(themeEnd, ti);
if (tj < 0) { console.log('THEME END MISS'); process.exit(1); }
const themeBlock = `              Row() {
                Text('主题跟随系统')
                  .fontSize(14).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.themeMode === AppThemeMode.SYSTEM })
                  .selectedColor(TunBoxColors.primary)
                  .onChange((v: boolean): void => this.setFollowSystemTheme(v))
              }.width('100%').alignItems(VerticalAlign.Center)
              Text('关闭后由主页太阳按钮手动切换深浅色。')
                .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
`;
// 从系统卡里删掉主题块（保留其后的 Divider + 测速地址）
t = t.slice(0, ti) + t.slice(tj + `              Divider().color(TunBoxColors.cardBorder)\n\n`.length);

// ── ③ 系统卡：改名 + 合并音频保活 ──
t = t.replace(`              this.SectionHeader($r('app.media.ic_globe'), $r('app.string.settings_appearance_network'))`,
              `              this.SectionHeader($r('app.media.ic_settings'), $r('app.string.settings_system_title'))`);

// 取出后台连接卡整块（注释 + Column … .border）
const bgStart = `            Column({ space: 12 }) {
              this.SectionHeader($r('app.media.ic_shield'), $r('app.string.settings_background_connection'))`;
const cardTail = `            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })`;
const bi = t.indexOf(bgStart);
if (bi < 0) { console.log('BG MISS'); process.exit(1); }
const bj = t.indexOf(cardTail, bi);
if (bj < 0) { console.log('BG TAIL MISS'); process.exit(1); }
// 音频保活内容（标题行 + 说明），抬头行不要
const keepAlive = `              Row() {
                Text('音频保活（下次连接）')
                  .fontSize(14).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.audioKeepAliveEnabled })
                  .selectedColor(TunBoxColors.primary)
                  .onChange((v: boolean): void => this.setAudioKeepAlive(v))
              }.width('100%').alignItems(VerticalAlign.Center)
              Text('小音量播放 + 媒体卡片维持后台（会增加耗电）；连接期间每 30 秒自检一次。')
                .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
`;
// 删掉整个后台连接卡（含注释行与块后空行）
const commentStart = t.lastIndexOf('            //', bi);
const cutFrom = commentStart >= 0 && bi - commentStart < 200 ? commentStart : bi;
t = t.slice(0, cutFrom) + t.slice(bj + cardTail.length).replace(/^\n+/, '\n');

// 音频保活并到系统卡：明文 HTTP 之后（系统卡收尾之前）
const sysTail = `              Text('默认关闭；明文 http 不加密、可被篡改，仅自建面板无证书时临时开启。')
                .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)`;
if (!t.includes(sysTail)) { console.log('SYS TAIL MISS'); process.exit(1); }
t = t.replace(sysTail, `              Text('默认关闭；明文 http 不加密、可被篡改，仅自建面板无证书时临时开启。')
                .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')

              Divider().color(TunBoxColors.cardBorder)

${keepAlive}            }
            .width('100%').padding(TunBoxGeometry.cardPadding)`);

// ── ② 主题块插到「关于与隐私」里：版本 与 隐私政策 中间 ──
const aboutVersion = `              }.width('100%')
              Divider().color(TunBoxColors.cardBorder)
              Row() {
                Text($r('app.string.settings_privacy_policy_row'))`;
if (!t.includes(aboutVersion)) { console.log('ABOUT MISS'); process.exit(1); }
t = t.replace(aboutVersion, `              }.width('100%')
              Divider().color(TunBoxColors.cardBorder)
${themeBlock}              Divider().color(TunBoxColors.cardBorder)
              Row() {
                Text($r('app.string.settings_privacy_policy_row'))`);

fs.writeFileSync(p, crlf ? t.replace(/\n/g, '\r\n') : t);
console.log('ok | ic_swap =', (t.match(/ic_swap/g) || []).length,
  '| 后台连接 =', (t.match(/settings_background_connection/g) || []).length,
  '| appearance_network =', (t.match(/settings_appearance_network/g) || []).length,
  '| 主题跟随系统 =', (t.match(/主题跟随系统/g) || []).length);
