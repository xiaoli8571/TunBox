const fs = require('node:fs');
for (const loc of ['base','en_US','zh_CN']) {
  const p = `entry/src/main/resources/${loc}/element/string.json`;
  let t = fs.readFileSync(p,'utf8').replace(/^\uFEFF/,'');
  // 去掉行尾多余逗号前先确认是 JSON 数组格式
  try { JSON.parse(t); console.log('OK', loc, 'entries=', JSON.parse(t).length, 'audioKey=', /audio/i.test(t)); }
  catch (e) { console.log('BAD', loc, e.message.slice(0,120)); }
}
