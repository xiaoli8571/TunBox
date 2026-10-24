// 只统计形状与关键字出现次数，绝不输出任何真实名称/凭据。
const fs = require('fs');
const path = require('path');
const dir = process.argv[2] || __dirname;
for (const fname of ['tunbox_subscriptions_r4', 'tunbox_subscriptions']) {
  const p = path.join(dir, fname);
  if (!fs.existsSync(p)) { console.log(fname + ': MISSING'); continue; }
  const xml = fs.readFileSync(p, 'utf8');
  const keys = [...xml.matchAll(/<string key="([^"]+)">/g)].map((m) => m[1]);
  console.log('FILE=' + fname + ' STRING_KEYS=' + keys.length);
  console.log('  keynames(shapes only)=' + JSON.stringify(keys.map((k) => k.replace(/[^\[\]_a-z]/g, '?').slice(0, 40))));
  const count = (pat) => (xml.match(new RegExp(pat, 'g')) || []).length;
  for (const pat of ['include-all', 'exclude-filter', 'filter:', 'proxy-groups', 'proxies:', 'subprocess', 'sorter', 'icon', 'GEOIP', 'MATCH', 'FE0F', '\\\\u2764']) {
    console.log('  ' + pat + '=' + count(pat));
  }
  // 提取每个 yaml_cache 值，看 proxy-groups 形状（掩码非 ASCII）
  const re = /<string key="(yaml_cache_[^"]+)">([\s\S]*?)<\/string>/g;
  let m;
  let idx = 0;
  while ((m = re.exec(xml))) {
    idx++;
    let v = m[2].split('&quot;').join('"').split('&lt;').join('<').split('&gt;').join('>').split('&amp;').join('&');
    const gi = v.indexOf('proxy-groups');
    console.log('  CACHE#' + idx + ' bytes=' + v.length + ' hasProxyGroups=' + (gi >= 0) + ' hasProxies=' + (v.indexOf('proxies:') >= 0) + ' hasIncludeAll=' + (v.indexOf('include-all') >= 0) + ' hasExcludeFilter=' + (v.indexOf('exclude-filter') >= 0) + ' hasFilter=' + (v.indexOf('filter:') >= 0));
    if (gi >= 0) {
      const lines = v.slice(gi).split('\n').slice(0, 26);
      for (const l of lines) {
        const shape = l.replace(/[^\x20-\x7e]/g, '*');
        console.log('    | ' + shape.slice(0, 110));
      }
    }
  }
}
