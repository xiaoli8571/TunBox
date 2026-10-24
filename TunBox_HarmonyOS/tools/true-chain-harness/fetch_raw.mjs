// tools/true-chain-harness/fetch_raw.mjs
// 用与 App 相同的 UA 链抓取真实订阅原文，落盘到 _audit/input/raw/ ，只打印数量口径。
// 目的：补齐「原始订阅内容 → 解析」这一层，用于对比「其他客户端正常 / TunBox 少节点」。
// 不打印也不落盘订阅地址、UUID、密码（文件本身含节点凭据，仅本地审计用）。
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..');
const audit = join(repo, '..', '_audit');
const { YamlMerger } = await import(pathToFileURL(join(here, 'generated', 'YamlMerger.ts')).href);

const subsPath = process.argv[2] || join(audit, 'device', 'extracted', 'subscriptions_json.txt');
const outDir = process.argv[3] || join(audit, 'input', 'raw');
mkdirSync(outDir, { recursive: true });

const subs = JSON.parse(readFileSync(subsPath, 'utf8'));
const UAS = ['clash-verge/v2.4.2', 'clash.meta/v1.19.32'];
const rows = [];
for (const s of subs) {
  if (s.url.startsWith('local://')) continue;
  const safe = s.name.replace(/[^\w\u4e00-\u9fa5.-]/g, '_');
  let done = false;
  for (const ua of UAS) {
    try {
      const res = await fetch(s.url, { headers: { 'User-Agent': ua, Accept: '*/*' } });
      const body = await res.text();
      const file = join(outDir, `${safe}.yaml`);
      writeFileSync(file, body, 'utf8');
      const groups = YamlMerger.proxyItemGroups(body);
      rows.push({
        name: s.name, ua, status: res.status, bytes: Buffer.byteLength(body),
        lines: body.split('\n').length,
        hasProxiesKey: /(^|\n)proxies:/.test(body),
        contentKind: groups.length > 0 ? 'clash-yaml'
          : (/^[A-Za-z0-9+/=_\-\s]+$/.test(body.trim().slice(0, 400)) ? 'base64/links' : 'text/other'),
        clashEntries: groups.length,
        file,
      });
      done = true;
      break;
    } catch (e) {
      rows.push({ name: s.name, ua, status: 'ERR', error: String(e).slice(0, 120) });
    }
  }
  if (!done) rows.push({ name: s.name, ua: '-', status: 'ALL-FAILED' });
}
for (const r of rows) console.log(JSON.stringify(r));
