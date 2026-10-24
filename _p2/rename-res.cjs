const fs = require('node:fs');
const map = { base: '系统', en_US: 'System', zh_CN: '系统' };
for (const loc of Object.keys(map)) {
  const p = `entry/src/main/resources/${loc}/element/string.json`;
  let t = fs.readFileSync(p, 'utf8');
  // 用 settings_system_title 取代 settings_appearance_network
  if (t.includes('settings_appearance_network')) {
    t = t.replace(/\{ "name": "settings_appearance_network", "value": "[^"]*" \}/,
      `{ "name": "settings_system_title", "value": "${map[loc]}" }`);
  } else if (!t.includes('settings_system_title')) {
    const m = /\{ "name": "settings_geo_title", "value": "([^"]*)" \}/.exec(t);
    t = t.replace(m[0], `${m[0]},\n    { "name": "settings_system_title", "value": "${map[loc]}" }`);
  }
  fs.writeFileSync(p, t);
  const obj = JSON.parse(t.replace(/^\uFEFF/, ''));
  console.log(loc, 'system =', obj.string.find((s) => s.name === 'settings_system_title')?.value,
    '| 旧键残留 =', !!obj.string.find((s) => s.name === 'settings_appearance_network'));
}
