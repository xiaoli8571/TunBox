const fs = require('node:fs');
const p = 'entry/src/main/ets/pages/SettingsPage.ets';
const t = fs.readFileSync(p, 'utf8');
console.log('CRLF =', (t.match(/\r\n/g) || []).length, '| LF-only =', (t.match(/\n/g) || []).length - (t.match(/\r\n/g) || []).length);
