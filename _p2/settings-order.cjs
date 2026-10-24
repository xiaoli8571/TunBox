/**
 * 设置页第二轮整理（2026-10-23 用户口径）：
 *  ① 订阅配额提醒：默认开启（模型层已 true），界面去掉这一行（不再让用户关掉）；
 *  ② 允许明文 HTTP 订阅：从「诊断」卡移到「外观与网络」卡的测速地址下面；
 *  ③ 订阅转换：挪到设置页最上面第一个；
 *  ④ 下载源偏好：保持默认（auto），去掉选择项 UI。
 * 只改展示与顺序，不改判定逻辑；assetSource 字段仍保留给 updateAsset 使用。
 */
const fs = require('node:fs');
const p = 'entry/src/main/ets/pages/SettingsPage.ets';
let t = fs.readFileSync(p, 'utf8');
const before = t;

function cut(startAnchor, endAnchorInclusive, label) {
  const si = t.indexOf(startAnchor);
  if (si < 0) { console.log('MISS start:', label); return false; }
  const ei = t.indexOf(endAnchorInclusive, si);
  if (ei < 0) { console.log('MISS end:', label); return false; }
  t = t.slice(0, si) + t.slice(ei + endAnchorInclusive.length);
  return true;
}

// ①② 整块删掉「诊断」卡（配额提醒行 + 明文 HTTP 行），HTTP 稍后插到测速地址下面
const diagStart = '            // ── 诊断（保留订阅配额提醒）──';
const diagEnd = '            .border({ width: 1, color: TunBoxColors.cardBorder })\n\n            // ── 订阅转换';
const di = t.indexOf(diagStart);
const dj = t.indexOf(diagEnd);
if (di < 0 || dj < 0) { console.log('DIAG MISS'); process.exit(1); }
const removedCard = t.slice(di, dj);
const httpBlock = `              Divider().color(TunBoxColors.cardBorder)

              Row() {
                Text('允许明文 HTTP 订阅')
                  .fontSize(14).fontColor(TunBoxColors.textPrimary).layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.allowInsecureSubscriptionHttp })
                  .selectedColor(TunBoxColors.primary)
                  .onChange((v: boolean): void => this.setAllowInsecureSubscriptionHttp(v))
              }.width('100%').alignItems(VerticalAlign.Center)
              Text('默认关闭；明文 http 不加密、可被篡改，仅自建面板无证书时临时开启。')
                .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')
`;
t = t.slice(0, di) + httpBlock + t.slice(dj + diagEnd.length);

// ② HTTP 段插到「外观与网络」卡里测速地址按钮之后（即该卡的收尾之前）
const anchorTail = `                  .onClick((): void => { this.resetTestUrl(); })
              }.width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)`;
if (!t.includes(anchorTail)) { console.log('TAIL MISS'); process.exit(1); }
t = t.replace(anchorTail, `                  .onClick((): void => { this.resetTestUrl(); })
              }.width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)`);

// ③ 取出订阅转换卡，插到内容列表最前面（应用分流卡之前）
const subStart = '            // ── 订阅转换（2026-10-22 用户要求：非 Clash 订阅 → mihomo 订阅）──';
const subEnd = '            .border({ width: 1, color: TunBoxColors.cardBorder })';
const si = t.indexOf(subStart);
const sj = t.indexOf(subEnd, si);
if (si < 0 || sj < 0) { console.log('SUBCONV MISS'); process.exit(1); }
const subCard = t.slice(si, sj + subEnd.length);
t = t.slice(0, si) + t.slice(sj + subEnd.length + 1);

// ④ 删除下载源偏好块
const srcStart = `              Column({ space: 8 }) {
                Text('下载源偏好')`;
const srcEnd = `              }.width('100%')
            }
            .width('100%').padding(TunBoxGeometry.cardPadding)`;
const pi = t.indexOf(srcStart);
if (pi < 0) { console.log('SOURCE PREF MISS'); process.exit(1); }
const pj = t.indexOf(srcEnd, pi);
if (pj < 0) { console.log('SOURCE PREF END MISS'); process.exit(1); }
t = t.slice(0, pi) + `            }\n            .width('100%').padding(TunBoxGeometry.cardPadding)` + t.slice(pj + srcEnd.length);

// 再把订阅转换卡放到列表首位（找列表开头：第一个应用分流卡）
const listAnchor = '            // ── 应用分流';
const li = t.indexOf(listAnchor);
if (li < 0) { console.log('LIST MISS'); process.exit(1); }
t = t.slice(0, li) + subCard + '\n\n' + t.slice(li);

fs.writeFileSync(p, t);
console.log('changed =', t !== before, '| bytes delta =', t.length - before.length);
console.log('checks:', ['订阅转换', '下载源偏好', '订阅配额提醒'].map((k) => `${k}=${(t.match(new RegExp(k, 'g')) || []).length}`).join(' '));
