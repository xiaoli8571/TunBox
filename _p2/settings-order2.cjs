/**
 * ①「订阅转换」卡挪到设置页最上面（用户：订阅转换挪到顶部第一个）；
 * ② 去掉「下载源偏好」选择项（用户：保持默认就行）。
 */
const fs = require('node:fs');
const p = 'entry/src/main/ets/pages/SettingsPage.ets';
let t = fs.readFileSync(p, 'utf8');

// ── 取出订阅转换卡（注释行到卡片 .border 收尾）──
const subStart = '            // ── 订阅转换（2026-10-22 用户要求：非 Clash 订阅 → mihomo 订阅）──';
const cardTail = `            .width('100%').padding(TunBoxGeometry.cardPadding)
            .borderRadius(TunBoxGeometry.cardRadius)
            .backgroundColor(TunBoxColors.surfaceCard)
            .border({ width: 1, color: TunBoxColors.cardBorder })`;
const si = t.indexOf(subStart);
if (si < 0) { console.log('SUB MISS'); process.exit(1); }
const sj = t.indexOf(cardTail, si);
if (sj < 0) { console.log('SUB TAIL MISS'); process.exit(1); }
const subCard = t.slice(si, sj + cardTail.length);
t = t.slice(0, si) + t.slice(sj + cardTail.length).replace(/^\n+/, '\n');

// ── 插到列表最前面（应用分流卡之前）──
const listAnchor = '            // ── 应用分流';
const li = t.indexOf(listAnchor);
if (li < 0) { console.log('LIST MISS'); process.exit(1); }
t = t.slice(0, li) + subCard + '\n\n' + t.slice(li);

// ── 删除「下载源偏好」块（含说明），只保留默认 auto ──
const srcStart = `              Column({ space: 8 }) {
                Text('下载源偏好')`;
const sp = t.indexOf(srcStart);
if (sp < 0) { console.log('SRC MISS'); process.exit(1); }
const srcEnd = `              }.width('100%')
            }`;
const se = t.indexOf(srcEnd, sp);
if (se < 0) { console.log('SRC TAIL MISS'); process.exit(1); }
t = t.slice(0, sp) + '            }' + t.slice(se + srcEnd.length);

fs.writeFileSync(p, t);
console.log('ok | 订阅转换 rows =', (t.match(/Text\('订阅转换'\)/g) || []).length,
  '| 下载源偏好 =', (t.match(/下载源偏好/g) || []).length);
