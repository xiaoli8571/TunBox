/** 设置页长文案压缩（按行处理，避免缩进/换行差异）：保留样式链，只替换文案本体。 */
const fs = require('node:fs');
const p = 'entry/src/main/ets/pages/SettingsPage.ets';
const lines = fs.readFileSync(p, 'utf8').split('\n');

const jobs = [
  { anchor: '可选：持续播放低音量音频', text: '小音量播放 + 媒体卡片维持后台（会增加耗电）；连接期间每 30 秒自检一次。' },
  { anchor: '订阅流量剩余不足 10%', text: '剩余 <10% 或 3 天内到期时通知，每天最多一次。' },
  { anchor: '默认关闭：只接受 https 订阅链接', text: '默认关闭；明文 http 不加密、可被篡改，仅自建面板无证书时临时开启。' },
  { anchor: '粘贴分享链接（单条', text: '分享链接转成 mihomo 配置，可保存到本地或一键导入订阅列表。' },
];

let done = 0;
for (const job of jobs) {
  const at = lines.findIndex((l) => l.includes(job.anchor));
  if (at < 0) { console.log('MISS', job.anchor); continue; }
  // 语句结束：找到带 `.width('100%')` 或 `.fontSize(` 的那一行之后的第一处样式终点
  let end = at;
  while (end < lines.length && !/\.width\('100%'\)/.test(lines[end])) { end++; }
  if (end >= lines.length) { console.log('NO END', job.anchor); continue; }
  const indent = lines[at].match(/^\s*/)[0];
  const styleLines = [];
  for (let i = at + 1; i <= end; i++) {
    if (/^\s*\./.test(lines[i])) { styleLines.push(lines[i]); }
  }
  const style = styleLines.length > 0 ? styleLines : [`${indent}  .fontSize(11).fontColor(TunBoxColors.textMuted).width('100%')`];
  const replacement = [`${indent}Text('${job.text}')`, ...style];
  lines.splice(at, end - at + 1, ...replacement);
  done++;
}
fs.writeFileSync(p, lines.join('\n'));
console.log('compressed =', done, '/', jobs.length);
