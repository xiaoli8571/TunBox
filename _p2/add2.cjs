const fs = require('node:fs');
const map = { base: '后台连接', en_US: 'Background connection', zh_CN: '后台连接' };
for (const loc of Object.keys(map)) {
  const p = `entry/src/main/resources/${loc}/element/string.json`;
  let t = fs.readFileSync(p, 'utf8');
  if (t.includes('settings_background_connection')) { console.log(loc, 'skip'); continue; }
  const m = /\{ "name": "settings_geo_title", "value": "([^"]*)" \}/.exec(t);
  if (!m) { console.log(loc, 'MISS geo title'); continue; }
  const ins = `${m[0]},\n    {"name": "settings_background_connection", "value": "${map[loc]}"}`;
  t = t.replace(m[0], ins);
  fs.writeFileSync(p, t);
  const obj = JSON.parse(t.replace(/^\uFEFF/, ''));
  console.log(loc, 'ok; keys=', obj.string.length, 'geo=', obj.string.find(s => s.name === 'settings_geo_title').value,
    'bg=', obj.string.find(s => s.name === 'settings_background_connection').value);
}
