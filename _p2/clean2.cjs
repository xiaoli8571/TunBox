const fs = require('node:fs');
const p = 'entry/src/main/ets/pages/SettingsPage.ets';
const raw = fs.readFileSync(p, 'utf8');
const crlf = raw.includes('\r\n');
let t = raw.replace(/\r\n/g, '\n');

// 去掉已无 UI 的配额提醒状态与 setter（恒开，由模型层保证）
t = t.replace("  @State quotaNotifyEnabled: boolean = true;\n", '');
t = t.replace("    this.quotaNotifyEnabled = this.settings.quotaNotifyEnabled;\n", '');

const setterStart = t.indexOf('  private setQuotaNotify(v: boolean): void {');
if (setterStart >= 0) {
  const docStart = t.lastIndexOf('  /**', setterStart);
  const start = docStart >= 0 && setterStart - docStart < 300 ? docStart : setterStart;
  const end = t.indexOf('\n  }\n', setterStart);
  if (end > 0) { t = t.slice(0, start) + t.slice(end + 4); }
}
fs.writeFileSync(p, crlf ? t.replace(/\n/g, '\r\n') : t);
console.log('quotaNotify 残留 =', (t.match(/quotaNotifyEnabled/g) || []).length);
