const fs = require('node:fs');
const p = 'scripts/verify-rule-provider-safety.mjs';
let t = fs.readFileSync(p, 'utf8');
t = t.replace(
  "  const download = methodBody(src, 'private async downloadRuleProviderAsset(source: string): Promise<boolean>');",
  "  // 2026-10-23：下载实现按 PR #5 拆成「单航班入口 + 真正执行体」，校验逻辑在后者的方法体里。\n"
  + "  const download = methodBody(src, 'private async performRuleProviderDownload(source: string): Promise<boolean>')\n"
  + "    || methodBody(src, 'private async downloadRuleProviderAsset(source: string): Promise<boolean>');");
fs.writeFileSync(p, t);
console.log('gate updated');
