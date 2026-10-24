const fs = require('node:fs');
let s = fs.readFileSync('settings-round3.cjs', 'utf8');
s = s.replace(String.raw`const themeEnd = ` + '`' + String.raw`              Divider().color(TunBoxColors.cardBorder)

              Row({ space: 8 }) {
                Text('测速地址')` + '`' + ';',
  'const themeEnd = `' + String.raw`              Divider().color(TunBoxColors.cardBorder)

              Row() {
                Text('IPv6 双栈')` + '`;');
fs.writeFileSync('settings-round3.cjs', s);
console.log('anchor fixed:', s.includes("Text('IPv6 双栈')`;"));
