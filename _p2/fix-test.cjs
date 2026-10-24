const fs = require('node:fs');
const p = 'scripts/verify-ad-rules-runtime.mjs';
let t = fs.readFileSync(p, 'utf8');
// ① 替身 builder 与真身同口径：去广告只看 hyperAdRulesEnabled（2026-10-23 独立开关）
t = t.replace("    return { yaml: JSON.stringify({ adRule: profile.ready && profile.settings.rulesEnabled\n      && profile.settings.hyperAdRulesEnabled }) };",
              "    return { yaml: JSON.stringify({ adRule: profile.ready\n      && profile.settings.hyperAdRulesEnabled }) };");
// ② 该用例语义反转：规则引擎关掉时去广告照样生效
t = t.replace(`await test('disabled rule system does not fetch the provider', async () => {
  const h = fixture(); h.settings.rulesEnabled = false;
  assert.equal(await h.orch.applyRulesChanged('rules-off'), 'hot');
  assert.equal(h.downloads, 0); assert.equal(h.configs.at(-1).adRule, false);
});`,
`await test('rule engine off does not disable ad blocking (independent switch)', async () => {
  const h = fixture(); h.settings.rulesEnabled = false; h.ruleReady = true;
  // 2026-10-23 用户口径：去广告是独立开关 —— 规则引擎关掉时它仍要生效。
  assert.equal(await h.orch.applyRulesChanged('rules-off'), 'hot');
  assert.equal(h.downloads, 0); assert.equal(h.configs.at(-1).adRule, true);
});`);
fs.writeFileSync(p, t);
console.log('test updated:', t.includes('rule engine off does not disable ad blocking') ? 'ok' : 'MISS');
