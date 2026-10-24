const fs = require('node:fs');
const p = 'entry/src/main/ets/commons/services/ConnectionOrchestrator.ets';
const lines = fs.readFileSync(p, 'utf8').split('\n');
const out = [];
let i = 0, idx = 0;
while (i < lines.length) {
  if (!lines[i].startsWith('<<<<<<<')) { out.push(lines[i]); i++; continue; }
  idx++;
  i++;
  const ours = [], theirs = [];
  while (!lines[i].startsWith('=======')) { ours.push(lines[i]); i++; }
  i++;
  while (!lines[i].startsWith('>>>>>>>')) { theirs.push(lines[i]); i++; }
  i++;
  if (idx === 1) { out.push(...ours); }            // ① 独立开关闸门：保留本地
  else if (idx === 2) { out.push(...ours); }        // ② 规则集体校验（体积+zstd）：保留本地
  else if (idx === 3) {                            // ③ refreshGeoAsset：两边都要
    out.push('    // 【2026-10-22】模型下载成功后也要 bump 信号：订阅页的「自动选择」入口跟着');
    out.push('    // `smart_model_seq` 重算（与删除对称）。否则用户点「更新」把模型装回来了、');
    out.push('    // 入口却还藏着，得杀进程才会出现。');
    out.push(...theirs.filter((l) => l.includes('applyRulesChanged')));
    out.push('    if (ok && id === \'model\') {');
    out.push("      const seq = AppStorage.get<number>('smart_model_seq');");
    out.push("      AppStorage.setOrCreate<number>('smart_model_seq', (seq ?? 0) + 1);");
  } else { out.push(...ours); }                     // ④ 下载校验：保留本地
}
fs.writeFileSync(p, out.join('\n'));
const left = out.filter((l) => l.startsWith('<<<<<<<') || l.startsWith('>>>>>>>') || l === '=======').length;
console.log('conflicts resolved; markers left =', left);
