const fs = require('node:fs');
const add = {
  base:   { name: 'settings_background_connection', value: '后台连接' },
  en_US:  { name: 'settings_background_connection', value: 'Background connection' },
  zh_CN:  { name: 'settings_background_connection', value: '后台连接' },
};
for (const loc of Object.keys(add)) {
  const p = `entry/src/main/resources/${loc}/element/string.json`;
  let t = fs.readFileSync(p, 'utf8').replace(/^\uFEFF/, '');
  if (t.includes('settings_background_connection')) { console.log(loc, 'already has key'); continue; }
  const obj = JSON.parse(t);
  obj.string.push({ name: add[loc].name, value: add[loc].value });
  fs.writeFileSync(p, JSON.stringify(obj, null, 2) + '\n');
  console.log(loc, 'added; geo title =', obj.string.find(s => s.name === 'settings_geo_title').value);
}
