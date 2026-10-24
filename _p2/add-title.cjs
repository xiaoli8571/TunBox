const fs = require('node:fs');
const map = { base: '外观与网络', en_US: 'Appearance & Network', zh_CN: '外观与网络' };
for (const loc of Object.keys(map)) {
  const p = `entry/src/main/resources/${loc}/element/string.json`;
  let t = fs.readFileSync(p, 'utf8');
  if (t.includes('settings_appearance_network')) { console.log(loc, 'skip'); continue; }
  const m = /\{ "name": "settings_geo_title", "value": "([^"]*)" \}/.exec(t);
  const anchor = m ? m[0] : null;
  const ins = `{ "name": "settings_appearance_network", "value": "${map[loc]}" }`;
  if (anchor) { t = t.replace(anchor, `${anchor},\n    ${ins}`); }
  else { t = t.replace(/\n\s*\]\s*\n\}\s*$/, `,\n    ${ins}\n  ]\n}\n`); }
  fs.writeFileSync(p, t);
  const obj = JSON.parse(t.replace(/^\uFEFF/, ''));
  console.log(loc, 'ok; has =', !!obj.string.find((s) => s.name === 'settings_appearance_network'));
}
