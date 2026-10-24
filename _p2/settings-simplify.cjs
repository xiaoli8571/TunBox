/**
 * 设置页整理（2026-10-23 用户要求「功能多了，让页面更简洁」）：
 *  ① 主题 + 网络 + 测速地址 三张卡合并为一张「外观与网络」卡（少两张卡、少两次视觉跳档）；
 *  ② 说明文案统一压到一行以内（保留必要警示，删掉重复/教程式的长句）；
 *  ③ 卡片内统一用 Divider 分隔多条设置，标题行统一 18px 图标 + 15px 粗体。
 * 只改视觉与文案，不改任何功能与判定逻辑。
 */
const fs = require('node:fs');
const p = 'entry/src/main/ets/pages/SettingsPage.ets';
let t = fs.readFileSync(p, 'utf8');

const startMark = '            // ── 主题：跟随系统（2026-10-20 新增，默认跟随）──';
const si = t.indexOf(startMark);
const bgHeader = "this.SectionHeader($r('app.media.ic_shield'), $r('app.string.settings_background_connection'))";
const bgIdx = t.indexOf(bgHeader);
const ei = bgIdx < 0 ? -1 : t.lastIndexOf('Column(', bgIdx);
if (si < 0 || ei < 0 || ei < si) { console.log('ANCHOR MISS', si, ei); process.exit(1); }

const block = `            // ── 外观与网络（2026-10-23 用户要求「更简洁」：三张卡合成一张）──
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

`;
t = t.slice(0, si) + block + t.slice(ei);

// ② 其余长文案压到一行
const trims = [
  [`              Text('可选：持续播放低音量音频并显示媒体卡片，会增加耗电；电话或其他音频可能中断保活。更改后请重新连接。')
                .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
              Text('连接期间每 30 秒检查后台任务；系统暂停、用户停止时不会强制重启。')
                .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')`,
   `              Text('小音量播放 + 媒体卡片维持后台（会增加耗电）；连接期间每 30 秒自检一次。')
                .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')`],
  [`                Text('订阅流量剩余不足 10% 或 3 天内到期时发送系统通知（每次刷新订阅后检查，每天最多提醒一次）')
                  .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')`,
   `                Text('剩余 <10% 或 3 天内到期时通知，每天最多一次。')
                  .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')`],
  [`                Text('默认关闭：只接受 https 订阅链接。明文 http 既无加密也不防篡改——'
                  + '面板被劫持或被中间人替换时，返回的节点表可以把你的流量导向任意服务器。'
                  + '仅在自建面板确实没有证书时临时开启，用完建议关掉。')
                  .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')`,
   `                Text('默认关闭；明文 http 不加密、可被篡改，仅自建面板无证书时临时开启。')
                  .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')`],
  [`                  Text('粘贴分享链接（单条 / 一行一条 / 整体 base64），转换成 mihomo 配置；'
                    + '可「保存到本地」留档，或「一键导入」直接进订阅列表。内容不会上传。')
                    .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')`,
   `                  Text('分享链接转成 mihomo 配置，可保存到本地或一键导入订阅列表。')
                    .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')`],
];
let trimmed = 0;
for (const [from, to] of trims) {
  if (t.includes(from)) { t = t.replace(from, to); trimmed++; }
  else { console.log('trim miss:', from.split('\n')[0].trim().slice(0, 40)); }
}
fs.writeFileSync(p, t);
console.log('merged appearance+network card; trimmed texts =', trimmed, '/', trims.length);
