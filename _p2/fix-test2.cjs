const fs = require('node:fs');
const p = 'scripts/verify-ad-rules-runtime.mjs';
const lines = fs.readFileSync(p, 'utf8').split('\n');
// builder stub: 去掉 rulesEnabled（与真身一致）
const b = lines.findIndex((l) => l.includes('adRule: profile.ready && profile.settings.rulesEnabled'));
if (b < 0) { console.log('builder MISS'); } else {
  lines[b] = '    return { yaml: JSON.stringify({ adRule: profile.ready';
  lines[b + 1] = '      && profile.settings.hyperAdRulesEnabled }) };';
}
// 用例：语义反转
const s = lines.findIndex((l) => l.includes("disabled rule system does not fetch the provider"));
if (s < 0) { console.log('test MISS'); } else {
  lines[s] = "await test('rule engine off does not disable ad blocking (independent switch)', async () => {";
  lines[s + 1] = "  const h = fixture(); h.settings.rulesEnabled = false; h.ruleReady = true;";
  lines[s + 2] = "  // 2026-10-23 用户口径：去广告是独立开关 —— 规则引擎关掉时它仍要生效。";
  lines[s + 3] = "  assert.equal(await h.orch.applyRulesChanged('rules-off'), 'hot');";
  lines[s + 4] = "  assert.equal(h.downloads, 0); assert.equal(h.configs.at(-1).adRule, true);";
}
fs.writeFileSync(p, lines.join('\n'));
console.log('done');
