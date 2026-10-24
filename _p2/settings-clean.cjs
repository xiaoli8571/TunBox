const fs = require('node:fs');
const p = 'entry/src/main/ets/pages/SettingsPage.ets';
const raw = fs.readFileSync(p, 'utf8');
const crlf = raw.includes('\r\n');
let t = raw.replace(/\r\n/g, '\n');

// ① 删掉已无 UI 的「下载源偏好」常量
const optStart = `/** geo 资产下载源偏好选项（与 AppSettings.assetSource 白名单一致） */`;
const oi = t.indexOf(optStart);
if (oi >= 0) {
  const endMark = '};\n';
  const oe = t.indexOf(endMark, t.indexOf('ASSET_SOURCE_LABELS', oi));
  if (oe > 0) { t = t.slice(0, oi) + t.slice(oe + endMark.length + 1); }
}

// ② 删掉 setAssetSource（不再有入口；assetSource 走默认 auto）
const fnStart = '  private setAssetSource(source: string): void {';
const fi = t.indexOf(fnStart);
if (fi >= 0) {
  // 往回吃掉紧邻的注释块
  const before = t.lastIndexOf('/**', fi);
  const start = before >= 0 && fi - before < 400 ? before : fi;
  const marker = '\n  }\n';
  const fe = t.indexOf(marker, fi);
  if (fe > 0) { t = t.slice(0, start) + t.slice(fe + marker.length); }
}

// ③ 配额提醒：默认（模型层）恒开；UI 已去掉，所以加载时不再读旧值
t = t.replace("    s.quotaNotifyEnabled = j.quotaNotifyEnabled === false ? false : true;",
  "    // 2026-10-23 用户口径：配额提醒恒开（设置页已去掉这个开关）。旧版本存过 false 的也一律置 true，\n"
  + "    // 否则用户升级后「功能消失但也不提醒」，等于悄悄丢功能。\n"
  + "    s.quotaNotifyEnabled = true;");

fs.writeFileSync(p, crlf ? t.replace(/\n/g, '\r\n') : t);
console.log('ok | ASSET_SOURCE_OPTIONS =', (t.match(/ASSET_SOURCE_OPTIONS/g) || []).length,
  '| setAssetSource =', (t.match(/setAssetSource/g) || []).length,
  '| quotaNotifyEnabled = true =', t.includes('s.quotaNotifyEnabled = true;'));
