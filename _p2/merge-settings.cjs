const fs = require('node:fs');
const p = 'entry/src/main/ets/pages/SettingsPage.ets';
let lines = fs.readFileSync(p, 'utf8').split('\n');
const out = [];
let i = 0;
while (i < lines.length) {
  const line = lines[i];
  if (!line.startsWith('<<<<<<<')) { out.push(line); i++; continue; }
  i++;
  const ours = [];
  while (!lines[i].startsWith('=======')) { ours.push(lines[i]); i++; }
  i++;
  const theirs = [];
  while (!lines[i].startsWith('>>>>>>>')) { theirs.push(lines[i]); i++; }
  i++;
  const oursText = ours.join('\n');
  if (oursText.includes('规则引擎与去广告是**两个独立开关**')) {
    out.push(...ours); // 摘要：保留本地独立开关文案
  } else if (oursText.includes('删除资产（目前只剩 Smart 选点模型）')) {
    out.push(...ours); // 文档注释：保留本地
  } else if (oursText.includes("已删除选点模型，自动选择入口已隐藏")) {
    // 规则集已不在资产列表，删除分支只会是模型
    out.push(...ours);
  } else {
    out.push(...theirs);
  }
}
fs.writeFileSync(p, out.join('\n'));
console.log('resolved; conflict markers left =', out.filter(l => l.startsWith('<<<<<<<') || l.startsWith('>>>>>>>') || l.startsWith('=======')).length);
