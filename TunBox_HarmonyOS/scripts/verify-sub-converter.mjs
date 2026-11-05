#!/usr/bin/env node
/**
 * mihomo `convert.ConvertsV2Ray`（Go）→ ArkTS 移植版（SubConverter.ets）对拍门禁。
 *
 * 为什么这么写：这个转换器是「文本 → 节点映射表」的纯函数，判定标准不是「看起来对」，
 * 而是**与上游 Go 实现逐字段一致**。所以这里不手写期望值，而是拿上游真实现跑出来的
 * golden（scripts/fixtures/subconverter-golden.json，由 kernel/Clash.Meta 的
 * convert.ConvertsV2Ray 生成）做逐字段对拍。
 *
 * 三层校验：
 *   [1] 值语义：SubConverter.convertToJson() vs golden（43 个用例、覆盖全部 scheme）
 *   [2] 形态契约：proxiesYaml 的缩进/引号/端口裸值/名前缀规则（给下游 YAML 切片器与内核看）
 *   [3] 真内核：把生成的 YAML 交给 mihomo.exe `-t` 判定（找不到内核则跳过）
 *
 * 跑法：node scripts/verify-sub-converter.mjs
 * 退出码 0 = 全通。
 *
 * 相关文件（三者一起才是完整的证据链）：
 *   entry/src/main/ets/commons/tunbox/SubConverter.ets   被测的 ArkTS 移植
 *   scripts/fixtures/subconverter-cases.json              46 个用例（明文/base64/畸形/回归）
 *   scripts/fixtures/subconverter-golden.json             Go 真实现的输出（对拍基准）
 *   scripts/fixtures/golden-gen/main.go                   golden 的生成器（改了用例才需要重跑，用法见文件头）
 *
 * 备注（UA）：Go 的 RandUserAgent() 每次随机取 250+ 条 UA 之一，移植版按节点内容做稳定散列
 * 在 8 条子集里取（保证转换可重复）。对拍时把 ws 头里的 User-Agent 值归一成 <UA>，
 * 另外单独断言「确实填了一条 Mozilla/5.0 UA」。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');

let passed = 0;
const fails = [];
function ok(cond, label, detail = '') {
  if (cond) {
    passed++;
    console.log(`  ✅ ${label}`);
  } else {
    fails.push(label);
    console.log(`  ❌ ${label}${detail ? '\n       ' + detail : ''}`);
  }
}
function eq(actual, expected, label) {
  ok(same(actual, expected), label,
    `期望 ${JSON.stringify(expected)}\n       实际 ${JSON.stringify(actual)}`);
}

/** 结构化相等（对象键序无关） */
function stable(v) {
  if (Array.isArray(v)) return '[' + v.map(stable).join(',') + ']';
  if (v && typeof v === 'object') {
    return '{' + Object.keys(v).sort().map((k) => JSON.stringify(k) + ':' + stable(v[k])).join(',') + '}';
  }
  return JSON.stringify(v === undefined ? null : v);
}
function same(a, b) {
  return stable(a) === stable(b);
}

/** ws 握手的 User-Agent 取值在两侧必然不同（Go 随机）→ 归一后比较 */
function normalizeUA(v) {
  if (Array.isArray(v)) return v.map(normalizeUA);
  if (v && typeof v === 'object') {
    const out = {};
    for (const k of Object.keys(v)) {
      out[k] = (k === 'User-Agent' || k === 'user-agent') ? '<UA>' : normalizeUA(v[k]);
    }
    return out;
  }
  return v;
}

// ── 加载 .ets（Node 的类型剥离只认 .ts/.mts，先复制影子） ──────────────────
const etsPath = path.join(root, 'entry/src/main/ets/commons/tunbox/SubConverter.ets');
if (!fs.existsSync(etsPath)) {
  console.log(`  ❌ 找不到 ${etsPath}`);
  process.exit(1);
}
const shadowDir = fs.mkdtempSync(path.join(os.tmpdir(), 'subconv-'));
const shadowPath = path.join(shadowDir, 'SubConverter.ts');
fs.copyFileSync(etsPath, shadowPath);
let SubConverter;
try {
  const mod = await import(pathToFileURL(shadowPath).href);
  SubConverter = mod.SubConverter;
} catch (e) {
  console.log('  ❌ 加载 SubConverter.ets 失败：' + (e && e.message ? e.message : e));
  process.exit(1);
}
if (!SubConverter) {
  console.log('  ❌ 没有导出 SubConverter');
  process.exit(1);
}
fs.rmSync(shadowDir, { recursive: true, force: true });

console.log('SubConverter 对拍门禁（ArkTS 移植 vs mihomo convert.ConvertsV2Ray）');
console.log(`源码：entry/src/main/ets/commons/tunbox/SubConverter.ets`);

// ────────────────────────────────────────────────────────────────────────────
// [1] 与 Go golden 逐字段对拍
// ────────────────────────────────────────────────────────────────────────────
const casesPath = path.join(here, 'fixtures/subconverter-cases.json');
const goldenPath = path.join(here, 'fixtures/subconverter-golden.json');
if (!fs.existsSync(goldenPath)) {
  console.log(`  ❌ 缺少 golden：${goldenPath}`);
  process.exit(1);
}
const cases = JSON.parse(fs.readFileSync(casesPath, 'utf8'));
const golden = JSON.parse(fs.readFileSync(goldenPath, 'utf8'));
const goldenById = new Map(golden.map((g) => [g.id, g]));

function textOf(c) {
  const text = c.lines.join('\n');
  if (c.encode === 'base64') return Buffer.from(text, 'utf8').toString('base64');
  if (c.encode === 'base64-raw') return Buffer.from(text, 'utf8').toString('base64').replace(/=+$/, '');
  return text;
}

console.log(`\n[1] 值语义对拍（${cases.length} 例，含 vless/vmess/trojan/ss/ssr/hysteria/hysteria2/tuic/anytls/mierus/socks/http）`);
const jsonById = new Map();
let mismatched = 0;
for (const c of cases) {
  const text = textOf(c);
  const g = goldenById.get(c.id);
  if (!g) {
    ok(false, `${c.id}：golden 缺失`);
    continue;
  }
  let actual;
  let actualOk = false;
  let actualError = '';
  try {
    const out = SubConverter.convert(text);
    actualOk = out.ok;
    actualError = out.error;
    actual = JSON.parse(SubConverter.convertToJson(text));
  } catch (e) {
    actual = null;
    actualError = 'THROW: ' + (e && e.message ? e.message : e);
  }
  jsonById.set(c.id, actual);

  const okExpected = g.ok;
  const probOk = actualOk === okExpected;
  const probErr = okExpected ? (actualError === '') : (actualError === g.error);
  const probCount = g.count === (actual ? actual.length : -1);
  const probBody = same(normalizeUA(actual), normalizeUA(g.proxies || []));
  if (probOk && probErr && probCount && probBody) {
    passed++;
    console.log(`  ✅ ${c.id}（${g.count} 节点${g.ok ? '' : '，ok=false'}）`);
  } else {
    mismatched++;
    fails.push(`对拍失败：${c.id}`);
    console.log(`  ❌ ${c.id}`);
    if (!probOk) console.log(`       ok 期望 ${okExpected} 实际 ${actualOk}`);
    if (!probErr) console.log(`       error 期望 ${JSON.stringify(g.error)} 实际 ${JSON.stringify(actualError)}`);
    if (!probCount) console.log(`       count 期望 ${g.count} 实际 ${actual ? actual.length : -1}`);
    if (!probBody) {
      console.log(`       proxies 不一致：\n       期望 ${stable(normalizeUA(g.proxies || []))}\n       实际 ${stable(normalizeUA(actual))}`);
    }
  }
}
ok(mismatched === 0, `${cases.length} 例全部与 Go 实现逐字段一致`, `${mismatched} 例不一致`);

// ────────────────────────────────────────────────────────────────────────────
// [2] 关键分支的明面断言（对拍之外，把「用户视角」的字段点出来）
// ────────────────────────────────────────────────────────────────────────────
console.log('\n[2] 关键分支明面断言');
const get = (id) => jsonById.get(id) || [];

{
  const ss = get('ss-userinfo-plain')[0] || {};
  eq([ss.type, ss.cipher, ss.password, ss.server, ss.port, ss.udp],
    ['ss', 'aes-256-gcm', 'pw123456', '5.6.7.8', '8388', true],
    'ss · 明文 userinfo（cipher:password 直接落字段）');
  const ssB64 = get('ss-userinfo-b64-pad')[0] || {};
  eq([ssB64.cipher, ssB64.password], ['aes-256-gcm', 'pw123456'],
    'ss · userinfo 整体 base64（解出 cipher:password）');
  const ssWhole = get('ss-whole-b64')[0] || {};
  eq([ssWhole.server, ssWhole.port, ssWhole.cipher, ssWhole.password],
    ['9.9.9.9', '8443', 'chacha20-ietf-poly1305', 'pw9'],
    'ss · 整条 base64（无 @ 的机场写法）');
  const ssObfs = get('ss-plugin-obfs')[0] || {};
  eq([ssObfs.plugin, ssObfs['plugin-opts'] && ssObfs['plugin-opts'].mode,
    ssObfs['plugin-opts'] && ssObfs['plugin-opts'].host, ssObfs['udp-over-tcp']],
    ['obfs', 'http', 'bing.com', true], 'ss · plugin=obfs + udp-over-tcp');
  const ssV2 = get('ss-plugin-v2ray')[0] || {};
  eq([ssV2.plugin, ssV2['plugin-opts'] && ssV2['plugin-opts'].mode,
    ssV2['plugin-opts'] && ssV2['plugin-opts'].path, ssV2['plugin-opts'] && ssV2['plugin-opts'].tls],
    ['v2ray-plugin', 'websocket', '/ws', true], 'ss · plugin=v2ray-plugin');
}

{
  const vm = get('vmess-json-ws')[0] || {};
  eq([vm.type, vm.uuid, vm.network, vm.tls, vm.servername, vm.alterId, vm.cipher, vm.xudp],
    ['vmess', '11111111-2222-4333-8444-555555555555', 'ws', true, 'sni.example.com', '0', 'auto', true],
    'vmess · v2rayN JSON（ws + tls + sni + alpn）');
  eq(vm.alpn, ['h2', 'http/1.1'], 'vmess · alpn 按逗号拆成数组');
  eq([vm['ws-opts'] && vm['ws-opts'].path, vm['ws-opts'] && vm['ws-opts']['max-early-data'],
    vm['ws-opts'] && vm['ws-opts']['early-data-header-name'],
    vm['ws-opts'] && vm['ws-opts'].headers && vm['ws-opts'].headers.Host],
  ['/ws', 2048, 'Sec-WebSocket-Protocol', 'cdn.example.com'],
  'vmess · ws 的 ed=2048 摘掉并转成 max-early-data（path 不再带 ?ed）');
  const aead = get('vmess-aead')[0] || {};
  eq([aead.uuid, aead.alterId, aead.cipher, aead.network, aead['client-fingerprint'],
    aead['grpc-opts'] && aead['grpc-opts']['grpc-service-name']],
    ['11111111-2222-4333-8444-555555555555', 0, 'auto', 'grpc', 'chrome', 'gs'],
    'vmess · AEAD URL（alterId=0/cipher=auto/fp=chrome）');
  const h2 = get('vmess-json-h2')[0] || {};
  eq([h2.network, h2['h2-opts'] && h2['h2-opts'].path, h2['h2-opts'] && h2['h2-opts'].host],
    ['h2', '/h2', ['h2.example.com']], 'vmess · net=http → network=h2（h2-opts）');
  const hu = get('vmess-json-httpupgrade')[0] || {};
  eq([hu.network, hu['ws-opts'] && hu['ws-opts']['v2ray-http-upgrade-fast-open']],
    ['httpupgrade', true], 'vmess · httpupgrade + ed → fast-open');
}

{
  const vl = get('vless-reality-ws')[0] || {};
  eq([vl.type, vl.network, vl.tls, vl['client-fingerprint'], vl.xudp],
    ['vless', 'ws', true, 'chrome', true], 'vless · reality + ws');
  eq(vl['reality-opts'], { 'public-key': 'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0', 'short-id': 'ab12' },
    'vless · reality-opts 完整（pbk/sid 缺一就握手全红）');
  eq([vl.servername, vl.encryption], ['sni.example.com', 'none'], 'vless · servername + encryption');
  const flow = get('vless-grpc-flow')[0] || {};
  eq([flow.flow, flow['grpc-opts'] && flow['grpc-opts']['grpc-service-name']],
    ['xtls-rprx-vision', 'gsvc'], 'vless · flow 小写 + grpc');
  const xh = get('vless-xhttp')[0] || {};
  eq([xh.network, xh['xhttp-opts'] && xh['xhttp-opts'].mode,
    xh['xhttp-opts'] && xh['xhttp-opts']['x-padding-bytes'],
    xh['xhttp-opts'] && xh['xhttp-opts']['reuse-settings'] && xh['xhttp-opts']['reuse-settings']['max-connections']],
    ['xhttp', 'packet-up', '100-1000', '4'], 'vless · xhttp extra → xhttp-opts（padding/xmux）');
}

{
  const tj = get('trojan-ws')[0] || {};
  eq([tj.type, tj.password, tj.sni, tj['skip-cert-verify'], tj['client-fingerprint'], tj['ws-opts'] && tj['ws-opts'].path],
    ['trojan', 'pw123', 's1.example.com', true, 'chrome', '/ws'], 'trojan · ws + allowInsecure');
  ok(/^Mozilla\/5\.0/.test((tj['ws-opts'] && tj['ws-opts'].headers && tj['ws-opts'].headers['User-Agent']) || ''),
    'trojan · ws 头里填了浏览器 UA',
    JSON.stringify(tj['ws-opts'] && tj['ws-opts'].headers));
  const tg = get('trojan-grpc')[0] || {};
  eq([tg['client-fingerprint'], tg.fingerprint], ['firefox', '3f7e5f2c1a9b8d6e4c2a1b0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d'], 'trojan · fp/pcs 分别落 client-fingerprint/fingerprint');
}

{
  const hy = get('hysteria')[0] || {};
  eq([hy.type, hy.sni, hy.obfs, hy.auth_str, hy.protocol, hy.up, hy.down, hy['skip-cert-verify']],
    ['hysteria', 'p.example.com', 'xplus', 'abc', 'udp', '100', '200', true], 'hysteria · peer/obfs/auth/protocol/up/down');
  const h2 = get('hysteria2')[0] || {};
  eq([h2.type, h2.password, h2['obfs-password'], h2.fingerprint, h2.alpn],
    ['hysteria2', 'authpw', 'op', '3f7e5f2c1a9b8d6e4c2a1b0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d', ['h3']], 'hysteria2 · 密码/obfs-password/pinSHA256');
  const hp = get('hysteria2-ports')[0] || {};
  eq([hp.port, hp.ports], ['443', '443,8443-8445'], 'hysteria2 · 端口跳跃区间保留在 ports，port 取首端口');
  const hr = get('hysteria2-realm')[0] || {};
  eq(hr['realm-opts'], {
    enable: true,
    'server-url': 'https://r.example.com:443',
    'realm-id': 'realm-1',
    token: 'realm-token',
    'stun-servers': ['stun1.example.com', 'stun2.example.com'],
  }, 'hysteria2+realm · realm-opts（server-url/token/realm-id/stun-servers）');
  eq(hr.password, 'pw', 'hysteria2+realm · auth 参数覆盖 password');
}

{
  const t5 = get('tuic-v5')[0] || {};
  eq([t5.uuid, t5.password, t5['congestion-controller'], t5['udp-relay-mode'], t5['disable-sni']],
    ['11111111-2222-4333-8444-555555555555', 'tpass', 'bbr', 'native', true], 'tuic · v5（uuid:password）');
  const t4 = get('tuic-v4')[0] || {};
  eq([t4.token, t4.uuid, t4.password], ['tokentoken', undefined, undefined], 'tuic · v4（token 形态）');
  const at = get('anytls')[0] || {};
  eq([at.username, at.password, at.sni, at.fingerprint, at['skip-cert-verify']],
    ['atuser', 'atpass', 's.example.com', '3f7e5f2c1a9b8d6e4c2a1b0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d', true], 'anytls · 凭据/sni/hpkp/insecure');
  const at2 = get('anytls-nopw')[0] || {};
  eq([at2.username, at2.password], ['onlyuser', 'onlyuser'], 'anytls · 无密码时 password 回落为 username');
  const mi = get('mierus');
  eq([mi.length, mi[0] && mi[0].name, mi[0] && mi[0].port, mi[1] && mi[1].name, mi[1] && mi[1].port],
    [2, 'M:2090/TCP', 2090, 'M:9999/UDP', 9999], 'mierus · 多 port/protocol 对展开成两个节点');
  eq([mi[0] && mi[0]['port-range']], [undefined], 'mierus · 单端口走 port（数字），区间才走 port-range');
  const mr = get('mierus-range')[0] || {};
  eq([mr['port-range'], mr.port], ['2090-2099', undefined], 'mierus · 区间端口走 port-range 字符串');
  const ssr = get('ssr')[0] || {};
  eq([ssr.server, ssr.port, ssr.cipher, ssr.protocol, ssr.obfs, ssr['obfs-param'], ssr['protocol-param'], ssr.password, ssr.name],
    ['ssr.example.com', '8388', 'aes-256-cfb', 'auth_aes128_md5', 'tls1.2_ticket_auth', 'obfs.example.com', '32:abc', 'ssrpass', 'SSR 节点'],
    'ssr · url-safe base64 的 pass/remarks/param 全部解出');
}

{
  const socks = get('socks-http');
  eq(socks.map((s) => s.type), ['socks5', 'socks5', 'http', 'http', 'http' /* 第 5 条被丢 */].slice(0, socks.length),
    'socks/http · scheme 归一到 socks5 / http');
  eq([socks[0].username, socks[0].password, socks[0]['skip-cert-verify']], ['su', 'sp', true],
    'socks · userinfo 反 base64');
  eq([socks[3].type, socks[3].tls], ['http', true], 'https:// → type=http + tls');
}

{
  // 这三条是「随机对拍」撞出来的真实差异，逐条锁住：
  // 脏端口 / 非法 %转义 在 Go 里让 url.Parse 报错 ⇒ 整行丢弃（不校验就会多出节点）；
  // 2022 密码非 base64 时 Go 用「部分解码」结果 ⇒ 密码被截断一个字符。
  const bad = jsonById.get('bad-port-and-escape') || [];
  eq([bad.length, bad[0] && bad[0].name], [1, 'good'],
    '脏端口(:abc) 与非法转义(#a%b) 的行被丢弃，只剩正常行');
  const partial = jsonById.get('ss-partial-b64') || [];
  eq([partial[0] && partial[0].cipher, partial[0] && partial[0].password],
    ['2022-blake3-aes-128-gcm', 'plainp'],
    'ss · 2022 密码非 base64 时沿用 Go 的「部分解码」结果（密码被截断）');
  const crlf = jsonById.get('crlf') || [];
  eq(crlf.map((n) => n.name), ['crlf1', 'crlf2'], 'CRLF 行尾（\r）能被正确裁掉');
}

// ── 重名规则（上游 uniqueName） ──────────────────────────────────────────
{
  const dup = jsonById.get('dup-names') || [];
  const names = dup.map((d) => d.name);
  console.log(`  ℹ️  重名用例实际输出：${JSON.stringify(names)}`);
  eq(names, ['香港 01', '香港 01-01', '香港 01-02', '香港 01-03'],
    '重名规则 = 首次原名 / 第二次 -01 / 第三次 -02（照抄 Go uniqueName 的计数器起点）');
  console.log('       （契约文档里写的「第二次 -02」与 Go 源码不符：converter.go 的');
  console.log('        uniqueName 首插计数为 0、命中先自增 ⇒ 第二条是 -01。此处以源码为准。）');
}

// ────────────────────────────────────────────────────────────────────────────
// [3] proxiesYaml 形态契约（下游 RawProxyYaml 切片 + 内核解析都依赖它）
// ────────────────────────────────────────────────────────────────────────────
console.log('\n[3] YAML 形态契约');
{
  const text = ['ss://aes-256-gcm:pw@1.2.3.4:8388#节点 A', 'trojan://pw@t.example.com:443?sni=s#T'].join('\n');
  const out = SubConverter.convert(text);
  ok(out.ok && out.count === 2, `两行转换成功（count=${out.count}）`);
  ok(out.proxiesYaml.startsWith('proxies:\n  - '), '以 `proxies:` + 2 空格 + `- ` 开头');
  ok(/^  - name: /m.test(out.proxiesYaml), '首条节点名折在 `- ` 同一行');
  ok(/^    type: /m.test(out.proxiesYaml), '后续字段 4 空格缩进');
  ok(/^    port: 8388$/m.test(out.proxiesYaml), '端口裸输出（不进引号）');
  ok(!/^\t/m.test(out.proxiesYaml), '没有 tab 缩进');
  ok(out.proxiesYaml.endsWith('\n'), '以换行结尾');
  ok((out.proxiesYaml.match(/^  - /gm) || []).length === 2, '`  - ` 条数 = 节点数');
  ok(out.proxiesYaml.includes('节点 A'), '中文名不用引号也安全（无特殊字符）');

  // 特殊字符必须被引号包住，且转义正确
  const tricky = 'trojan://pw@t.example.com:443#a: b "c" \\d';
  const t2 = SubConverter.convert(tricky);
  ok(t2.ok, '带特殊字符的 fragment 也能转');
  ok(/name: "a: b \\"c\\" \\\\d"/.test(t2.proxiesYaml),
    '冒号+引号+反斜杠的名字被双引号包裹并转义',
    t2.proxiesYaml.split('\n')[1]);
  // 看起来像数字的名字必须引号（否则名字变成数字类型）
  const numName = SubConverter.convert('trojan://pw@t.example.com:443#12345');
  ok(/name: "12345"/.test(numName.proxiesYaml), '纯数字名字加引号（避免被解析成数字）');
  // 数组用流式
  const alpn = SubConverter.convert('hysteria2://pw@h.example.com:443?alpn=h3,h2#x');
  ok(/alpn: \[h3, h2\]/.test(alpn.proxiesYaml), '数组输出为 [a, b]', alpn.proxiesYaml);
}

// ────────────────────────────────────────────────────────────────────────────
// [4] 空 / 垃圾输入
// ────────────────────────────────────────────────────────────────────────────
console.log('\n[4] 空输入与垃圾输入');
{
  const empty = SubConverter.convert('');
  ok(!empty.ok && empty.count === 0 && empty.proxiesYaml === ''
    && empty.error === 'convert v2ray subscribe error: format invalid',
  '空串 → ok=false + 与 Go 一致的错误文本', empty.error);

  const blank = SubConverter.convert('   \n\n  \r\n');
  ok(!blank.ok && blank.error === 'convert v2ray subscribe error: format invalid', '纯空白 → ok=false');

  const junk = SubConverter.convert('这不是链接\nhello world\nhttp://\n://\nss://');
  ok(!junk.ok, '乱码 → ok=false（不抛异常）');

  const half = SubConverter.convert('ss://!!not-base64!!@1.2.3.4:8388#x\nvmess://\nunknown://a.b:1#n');
  ok(!half.ok, '半残链接一条都救不回来 → ok=false');

  // 混合：垃圾行不影响正常行
  const mixed = SubConverter.convert(['# 注释', '', 'garbage', 'hysteria2://pw@h.example.com:443#好'].join('\n'));
  ok(mixed.ok && mixed.count === 1 && mixed.proxiesYaml.includes('name: 好'), '垃圾行被跳过，正常行照常转');

  let threw = '';
  try {
    SubConverter.convert('a'.repeat(200000));
  } catch (e) {
    threw = String(e);
  }
  ok(threw === '', '超长单行不抛异常');
}

// ────────────────────────────────────────────────────────────────────────────
// [5] 真实内核：mihomo -t 判定生成的 YAML
// ────────────────────────────────────────────────────────────────────────────
console.log('\n[5] 真实内核 mihomo -t 判定');
{
  let kernel = '';
  const buildRoot = path.join(root, '..', 'mihomo-build');
  if (fs.existsSync(buildRoot)) {
    for (const d of fs.readdirSync(buildRoot)) {
      const cand = path.join(buildRoot, d, 'mihomo.exe');
      if (fs.existsSync(cand)) {
        kernel = cand;
        break;
      }
    }
  }
  if (kernel === '') {
    console.log('  ⏭️  未找到 mihomo.exe，跳过（不影响上面的对拍结论）');
  } else {
    // 把「全部 scheme」拼成一份订阅，一次性交给内核判。
    // 跳过「故意带坏凭据」的用例：ss-partial-b64 的 2022 密码是被 Go 的
    // 部分解码截断过的（上游同样会产出这个坏节点），拿它判 YAML 合法性没有意义。
    const SKIP_IN_KERNEL = ['ss-partial-b64'];
    const lines = [];
    for (const c of cases) {
      if (c.encode || SKIP_IN_KERNEL.includes(c.id)) continue;
      for (const l of c.lines) {
        if (l.includes('://')) lines.push(l);
      }
    }
    const out = SubConverter.convert(lines.join('\n'));
    ok(out.ok && out.count > 20, `汇总订阅转换出 ${out.count} 个节点`);
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'subconv-k-'));
    const cfg = path.join(dir, 'c.yaml');
    const full = 'mixed-port: 17898\nmode: rule\nlog-level: warning\n'
      + out.proxiesYaml
      + '\nproxy-groups:\n  - name: PROXY\n    type: select\n    proxies:\n'
      + out.proxiesYaml.split('\n').filter((l) => l.startsWith('  - name: '))
        .map((l) => '      - ' + l.substring('  - name: '.length).replace(/^"(.*)"$/, '"$1"')).join('\n')
      + '\nrules:\n  - MATCH,PROXY\n';
    fs.writeFileSync(cfg, full, 'utf8');
    let log = '';
    let code = 0;
    try {
      log = execFileSync(kernel, ['-t', '-d', dir, '-f', cfg], { encoding: 'utf8' });
    } catch (e) {
      log = String((e.stdout || '') + (e.stderr || '') + (e.message || ''));
      code = e.status === undefined ? 1 : e.status;
    }
    ok(code === 0 && /test is successful/.test(log), '内核接受生成的 YAML（-t 通过）',
      code === 0 ? '' : log.split('\n').slice(0, 6).join(' | '));
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

console.log(`\n${passed} passed, ${fails.length} failed`);
if (fails.length > 0) {
  console.log('失败：\n  - ' + fails.join('\n  - '));
  process.exit(1);
}
process.exit(0);
