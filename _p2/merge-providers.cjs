const fs = require('node:fs');
const p = 'entry/src/main/ets/commons/flclash/ProfileConfigMerger.ets';
let t = fs.readFileSync(p, 'utf8');

// ① PROFILE_KEYS：两个 provider 段都不再从原文整段搬入（改由并集路径处理）
t = t.replace(`const PROFILE_KEYS: string[] = [`, `/**
 * 需要「按键并集」而不是「整段替换」的 provider 段。
 *
 * 为什么两个都要：provider 是**按名字寻址的命名空间** —— overlay 的 rules 里
 * RULE-SET,hyper-adrules（或原文 rules 里引用自己的 provider 名）只认名字，
 * 声明段丢一个就是内核整份拒载（`rule set [x] not found`，2026-10-23 真机报障）。
 * 所以两段都走「overlay 优先 + 原文补齐」的并集，而不是二选一。
 */
const PROVIDER_MERGE_KEYS: string[] = ['proxy-providers', 'rule-providers'];
const PROFILE_KEYS: string[] = [`);

// ② 原文 PROFILE_KEYS 里的两个 provider 键移除（并集路径负责）
t = t.replace(`  'proxy-providers',\n  'tunnels',`, `  'tunnels',`);

// ③ 并集块：两个键都做，用同一个块解析器
t = t.replace(`    // overlay.rules 仍引用自产 hyper-adrules / rs-*，不能只保留原文的 providers。
    // 按完整块合并；同名时 overlay 优先，与生成器的自产规则集优先级一致。
    const providers = ProfileConfigMerger.ruleProviders(overlayYaml);
    const profileProviders = ProfileConfigMerger.ruleProviders(profileYaml);
    for (const entry of profileProviders) {
      if (!providers.has(entry[0])) {
        providers.set(entry[0], entry[1]);
      }
    }
    if (providers.size > 0) {
      const providerLines: string[] = ['rule-providers:'];
      for (const entry of providers) {
        for (const line of entry[1]) {
          providerLines.push(line);
        }
      }
      blocks.push(providerLines.join('\\n'));
      applied.push('rule-providers');
    }`,
`    // overlay.rules 仍引用自产 hyper-adrules / rs-*，原文 rules 也可能引用自己的 provider。
    // provider 是名字寻址的命名空间：声明缺一个 = 内核整份拒载。两个段都按**完整块并集**，
    // 同名时 overlay 优先（与生成器「自产规则集优先」口径一致）。
    for (const providerKey of PROVIDER_MERGE_KEYS) {
      const providers = ProfileConfigMerger.providerBlocks(providerKey, overlayYaml);
      const profileProviders = ProfileConfigMerger.providerBlocks(providerKey, profileYaml);
      for (const entry of profileProviders) {
        if (!providers.has(entry[0])) {
          providers.set(entry[0], entry[1]);
        }
      }
      if (providers.size === 0) {
        continue;
      }
      const providerLines: string[] = [\`\${providerKey}:\`];
      for (const entry of providers) {
        for (const line of entry[1]) {
          providerLines.push(line);
        }
      }
      blocks.push(providerLines.join('\\n'));
      applied.push(providerKey);
    }`);

// ④ 解析器改名为 providerBlocks(key, yaml)，段名参数化
t = t.replace(`  private static ruleProviders(yaml: string): Map<string, string[]> {`,
              `  private static providerBlocks(key: string, yaml: string): Map<string, string[]> {`);
t = t.replace(`        if (line.startsWith('rule-providers:')) {`,
              `        if (line.startsWith(\`\${key}:\`)) {`);
fs.writeFileSync(p, t);
console.log('patched:', ['PROVIDER_MERGE_KEYS', 'providerBlocks'].map(k => k + '=' + (t.includes(k) ? 'yes' : 'NO')).join(' '),
  '| 残留 ruleProviders=', (t.match(/ruleProviders\(/g) || []).length);
