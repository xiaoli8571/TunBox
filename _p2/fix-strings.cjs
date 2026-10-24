const fs = require('node:fs');
const path = require('node:path');
for (const loc of ['base', 'en_US', 'zh_CN']) {
  const p = path.join('entry/src/main/resources', loc, 'element/string.json');
  let text = fs.readFileSync(p, 'utf8');
  if (!text.includes('<<<<<<<')) { console.log(loc, 'no conflict'); continue; }
  // 以 PR 版本为基（含 audio 保活键 + 原「数据与规则」），再改回「数据」/「Data」
  const m = /<<<<<<< HEAD\r?\n([\s\S]*?)=======\r?\n([\s\S]*?)>>>>>>> [^\n]*\n/.exec(text);
  if (!m) { console.log(loc, 'pattern miss'); continue; }
  const theirs = m[2];
  text = text.slice(0, m.index) + theirs + text.slice(m.index + m[0].length);
  text = text.replace('"settings_geo_title", "value": "数据与规则"', '"settings_geo_title", "value": "数据"')
             .replace('"settings_geo_title", "value": "Data & Rules"', '"settings_geo_title", "value": "Data"');
  fs.writeFileSync(p, text);
  console.log(loc, 'resolved;', /audio/i.test(text) ? 'has audio key' : 'no audio key');
}
