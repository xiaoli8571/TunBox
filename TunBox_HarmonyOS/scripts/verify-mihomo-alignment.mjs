#!/usr/bin/env node
/**
 * mihomo 对齐验证：端口跳跃 / 指纹语义 / ws 早数据 / 生成配置端到端。
 *
 * 为什么要有这个套件：这三处都是「**不报错但静默降级**」的坑 ——
 *   - hysteria2 端口跳跃区间被 parseInt 截断，节点仍能连（只连一个端口）；
 *   - `fingerprint`(证书 pin) 与 `client-fingerprint`(uTLS) 混用，
 *     结果是 `fingerprint: chrome` 这种内核侧非法值，且真正的 pin 丢失；
 *   - ws 的 `ed` 早数据参数在 URI 路径完全没被读，只有从链接导入的节点退化。
 * 静默降级不会有任何日志，所以只能靠「跑真源码 + 断言产出」来证明。
 *
 * 断言基线取自 mihomo 内核源码（MetaCubeX/mihomo common/convert/v.go）：
 *   fp        → client-fingerprint（uTLS，默认 chrome）
 *   pcs       → fingerprint（证书 pinSHA256）
 *   ed + ws   → ws-opts.max-early-data + early-data-header-name
 *   ed + httpupgrade → ws-opts.v2ray-http-upgrade-fast-open: true
 *   host:1000-2000 → port=1000 且 ports="1000-2000"
 *
 * 跑法：node scripts/verify-mihomo-alignment.mjs
 * 退出码 0 = 全绿。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const ets = path.join(root, 'entry/src/main/ets');
const svc = path.join(ets, 'commons/services');
const models = path.join(ets, 'commons/models');

let passed = 0;
let failed = 0;
function ok(cond, label) {
  if (cond) { passed++; console.log(`  ✅ ${label}`); }
  else { failed++; console.log(`  ❌ ${label}`); }
}
function eq(actual, expected, label) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) { passed++; console.log(`  ✅ ${label}`); }
  else { failed++; console.log(`  ❌ ${label}\n       期望 ${e}\n       实际 ${a}`); }
}

// ── 暂存真源码（复用 fidelity 套件的 flatten + stripEnums 机制） ──────────────
const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'mihomo-align-'));
const w = (n, s) => fs.writeFileSync(path.join(stage, n), s, 'utf8');
const flatten = (s) => s.replace(
  /from '(?:\.\.?\/)+(?:[A-Za-z0-9_]+\/)*([A-Za-z0-9_]+)'/g, "from './$1.ts'");
const stripEnums = (s) => s.replace(/export enum (\w+) \{([\s\S]*?)\n\}/g, (m, name, body) => {
  const pairs = [...body.matchAll(/(\w+)\s*=\s*'([^']*)'/g)].map(x => [x[1], x[2]]);
  return `export class ${name} {\n${pairs.map(([k, v]) => `  static readonly ${k}: string = '${v}';`).join('\n')}\n}`;
});
const stage1 = (f) => stripEnums(flatten(fs.readFileSync(f, 'utf8')));

w('ProxyNode.ts', stage1(path.join(models, 'ProxyNode.ets')));
// 2026-10-20（yaml-sub 的订阅解析内核化）：ProxyNode 已改走规范解析层，
// 这几个模块是它的运行时依赖，必须一起暂存，否则 import 解析不到直接挂。
const subDir = path.join(ets, 'commons/subscription');
w('ProtocolParamTable.ts', stage1(path.join(subDir, 'ProtocolParamTable.ets')));
w('NodeUsability.ts', stage1(path.join(subDir, 'NodeUsability.ets')));
w('UnusableLedger.ts', stage1(path.join(subDir, 'UnusableLedger.ets')));
w('UriNodeParser.ts', stage1(path.join(subDir, 'UriNodeParser.ets')));
w('ProxyNodeAdapter.ts', stage1(path.join(subDir, 'ProxyNodeAdapter.ets')));
w('AppLogger.ts', `
export class AppLogger {
  static info() {}
  static warn() {}
  static error() {}
  static debug() {}
  static errText(e) { return String(e && e.message ? e.message : e); }
}
`);
const utilStub = `
class Decoder {
  static create() { return new Decoder(); }
  decodeToString(bytes) { return Buffer.from(bytes).toString('utf8'); }
}
class Encoder {
  static create() { return new Encoder(); }
  encodeInto(s) { return new Uint8Array(Buffer.from(s, 'utf8')); }
  encodeToString(s) { return Buffer.from(s, 'utf8').toString('base64'); }
}
class Base64Helper {
  constructor() {}
  decodeSync(input) {
    const s = typeof input === 'string' ? input : Buffer.from(input).toString('utf8');
    return new Uint8Array(Buffer.from(s, 'base64'));
  }
  decodeToStringSync(input) { return Buffer.from(this.decodeSync(input)).toString('utf8'); }
  encodeToStringSync(input) {
    return typeof input === 'string'
      ? Buffer.from(input, 'utf8').toString('base64')
      : Buffer.from(input).toString('base64');
  }
}
export const util = {
  TextDecoder: Decoder, TextEncoder: Encoder,
  Base64Helper: Base64Helper, base64Helper: new Base64Helper(),
  // 真源码里 SsrCodec.decodeBase64Url 会传 util.Type.MIME / util.Type.BASIC，
  // 桩缺了它会抛错 → decodeBase64Url 静默返回 '' → ss 节点被误判为无效。
  Type: { MIME: 'mime', BASIC: 'basic' }
};
`;
w('util.ts', utilStub);
w('@kit.ArkTS.ts', utilStub);
for (const f of fs.readdirSync(stage)) {
  if (!f.endsWith('.ts')) continue;
  const p = path.join(stage, f);
  fs.writeFileSync(p,
    fs.readFileSync(p, 'utf8').replace(/'@kit\.ArkTS'/g, "'./util.ts'"), 'utf8');
}

let ProxyNode = null;
try {
  const mod = await import(`file://${path.join(stage, 'ProxyNode.ts').replace(/\\/g, '/')}`);
  ProxyNode = mod.ProxyNode;
} catch (e) {
  console.log(`\nFAILED to stage ProxyNode: ${e && e.message ? e.message : e}`);
  process.exit(1);
}

const parse = (uri) => ProxyNode.fromUri(uri, 'sub-1', 'id-1');
const extraOf = (node) => {
  if (!node || !node.extraOpts) return [];
  try { return JSON.parse(node.extraOpts); } catch { return []; }
};
const extraValue = (node, key) => {
  const hit = extraOf(node).find(p => p[0] === key);
  return hit ? hit[1] : '';
};

// ── 1. hysteria2 端口跳跃 ──────────────────────────────────────────────────
console.log('\n[1] hysteria2 端口跳跃（mihomo: port=首个, ports=原始区间）');
{
  const n = parse('hysteria2://pass@example.com:1000-2000/?insecure=1&sni=a.com#hop');
  ok(n !== null, '区间写法能解析出节点');
  eq(n && n.port, 1000, 'port = 区间首个端口 1000');
  eq(extraValue(n, 'ports'), '1000-2000', 'ports 保留完整区间 "1000-2000"');

  const list = parse('hysteria2://pass@example.com:1000,2000,3000/?sni=a.com#list');
  ok(list !== null, '逗号列表写法能解析');
  eq(list && list.port, 1000, '列表写法 port = 首个 1000');
  eq(extraValue(list, 'ports'), '1000,2000,3000', '列表写法 ports 保留全列表');

  const single = parse('hysteria2://pass@example.com:443/?sni=a.com#single');
  ok(single !== null, '单端口写法仍能解析');
  eq(single && single.port, 443, '单端口 port = 443');
  eq(extraValue(single, 'ports'), '', '单端口不产生 ports 键（不发明字段）');

  // 反例：畸形区间不得被当成跳跃，且不得崩
  const bad = parse('hysteria2://pass@example.com:abc/?sni=a.com#bad');
  ok(bad === null, '非数字端口被拒绝（不静默产出 port=NaN 的节点）');
}

// ── 2. 指纹语义分离 ───────────────────────────────────────────────────────
console.log('\n[2] fp(uTLS) 与 pcs/pinSHA256(证书 pin) 分槽');
{
  const hy2 = parse('hysteria2://pass@example.com:443/?sni=a.com&pinSHA256=AB:CD:EF#pin');
  ok(hy2 !== null, 'hysteria2 带 pinSHA256 能解析');
  eq(hy2 && hy2.certFingerprint, 'AB:CD:EF', 'pinSHA256 → certFingerprint');
  eq(hy2 && hy2.clientFingerprint, '', 'pinSHA256 不污染 clientFingerprint');

  // hysteria2 只有 fingerprint（证书 pin），没有 client-fingerprint：
  // mihomo adapter/outbound/hysteria2.go 的 Hysteria2Option 里只有 Fingerprint 字段。
  const hy2fp = parse('hysteria2://pass@example.com:443/?sni=a.com&fp=firefox#fp');
  eq(hy2fp && hy2fp.clientFingerprint, '',
    'hysteria2 不落地 fp（内核无 client-fingerprint 键，发了也会被忽略）');

  // fp / pcs 的分离在 vless 上验证（两种键都真实存在）
  const both = parse('vless://11111111-1111-4111-8111-111111111111@example.com:443'
    + '?type=tcp&security=tls&fp=firefox&pcs=AB:CD#both');
  eq(both && both.clientFingerprint, 'firefox', '同时带 fp+pcs：uTLS 指纹保住');
  eq(both && both.certFingerprint, 'AB:CD', '同时带 fp+pcs：证书 pin 也保住（旧实现会丢 pin）');

  const vless = parse('vless://11111111-1111-4111-8111-111111111111@example.com:443'
    + '?type=tcp&security=reality&fp=chrome&pcs=DE:AD:BE:EF&pbk=KEY&sid=ab#r');
  eq(vless && vless.clientFingerprint, 'chrome', 'vless fp → clientFingerprint');
  eq(vless && vless.certFingerprint, 'DE:AD:BE:EF', 'vless pcs → certFingerprint（此前完全没读 pcs）');
}

// ── 3. ws 早数据 ──────────────────────────────────────────────────────────
console.log('\n[3] ws / httpupgrade 早数据（mihomo ed 参数）');
{
  const ws = parse('vless://11111111-1111-4111-8111-111111111111@example.com:443'
    + '?type=ws&security=tls&host=h.com&path=%2Fp&ed=2560#ws');
  ok(ws !== null, 'ws + ed 能解析');
  eq(extraValue(ws, 'ws-opts.max-early-data'), '2560', 'ed → ws-opts.max-early-data');
  eq(extraValue(ws, 'ws-opts.early-data-header-name'), 'Sec-WebSocket-Protocol',
    '默认补 early-data-header-name');
  eq(ws && ws.wsPath, '/p', 'ws 路径仍保留');

  // 关键：键必须以 ws-opts. 前缀存放，否则生成端不会并回 ws-opts 结构
  const keys = extraOf(ws).map(p => p[0]);
  ok(keys.every(k => k.startsWith('ws-opts.')),
    `早数据键全部带 ws-opts. 前缀（生成端只认该前缀）: ${JSON.stringify(keys)}`);

  const hu = parse('vless://11111111-1111-4111-8111-111111111111@example.com:443'
    + '?type=httpupgrade&security=tls&host=h.com&path=%2Fp&ed=2560#hu');
  ok(hu !== null, 'httpupgrade + ed 能解析');
  eq(extraValue(hu, 'ws-opts.v2ray-http-upgrade-fast-open'), 'true',
    'httpupgrade 的 ed → v2ray-http-upgrade-fast-open: true');

  const noEd = parse('vless://11111111-1111-4111-8111-111111111111@example.com:443'
    + '?type=ws&security=tls&host=h.com&path=%2Fp#noed');
  eq(extraOf(noEd).filter(p => p[0].includes('early-data')).length, 0,
    '没有 ed 时不发明早数据键');

  const badEd = parse('vless://11111111-1111-4111-8111-111111111111@example.com:443'
    + '?type=ws&security=tls&host=h.com&path=%2Fp&ed=abc#bad');
  eq(extraOf(badEd).filter(p => p[0].includes('early-data')).length, 0,
    '非数字 ed 被忽略（mihomo 对坏 ed 直接报错，这里选择不落地该键）');
}

// ── 4. 不回归：普通单端口节点 ─────────────────────────────────────────────
console.log('\n[4] 不回归（splitHostPort 改为原样返回端口后）');
{
  const ss = parse('ss://YWVzLTEyOC1nY206cGFzcw==@example.com:8388#ss');
  ok(ss !== null, 'ss 单端口仍能解析');
  eq(ss && ss.port, 8388, 'ss port 正常');
  eq(extraValue(ss, 'ports'), '', 'ss 不产生 ports');

  const trojan = parse('trojan://pw@example.com:443?sni=a.com#tj');
  ok(trojan !== null, 'trojan 仍能解析');
  eq(trojan && trojan.port, 443, 'trojan port 正常');

  // 端口位带路径的普通节点（不该被 / 影响）
  const vless = parse('vless://11111111-1111-4111-8111-111111111111@example.com:443/?type=tcp#p');
  ok(vless !== null, '端口后带斜杠的 vless 仍能解析');
  eq(vless && vless.port, 443, '带斜杠的端口仍解析为 443');
}

// ── 5. 生成端：extraOpts 回写与指纹键名 ───────────────────────────────────
console.log('\n[5] 生成端（ClashConfigGenerator / YamlMerger 源码契约）');
{
  const gen = fs.readFileSync(path.join(svc, 'ClashConfigGenerator.ets'), 'utf8');
  const ym = fs.readFileSync(path.join(svc, 'YamlMerger.ets'), 'utf8');

  ok(/client-fingerprint: \$\{q\(n\.clientFingerprint\)\}/.test(gen),
    '生成端固定发 client-fingerprint（不再按协议改写键名）');
  ok(/fingerprint: \$\{q\(n\.certFingerprint\)\}/.test(gen),
    '生成端独立发 fingerprint（证书 pin）');
  ok(!/proxyType === 'hysteria2' \? 'fingerprint' : 'client-fingerprint'/.test(gen),
    '旧的「hysteria2 就把 client-fingerprint 改写成 fingerprint」逻辑已删除');
  ok(!/p\.type === 'hysteria2' \? 'fingerprint' : 'client-fingerprint'/.test(ym),
    'YamlMerger 里同样的改写逻辑已删除');
  ok(/p\.certFingerprint = fields\.get\('fingerprint'\) \?\? ''/.test(ym),
    'YAML 路径：fingerprint → certFingerprint（不再当 uTLS 兜底）');
  // ports 必须能通过 extraOpts 中继回写
  ok(/ports/.test(gen), '生成端 extraOpts 回写注释涵盖 ports');
  ok(/'ports'/.test(gen) || /ports/.test(gen), 'ports 键可被中继');
}

// ── 6. 持久化契约 ─────────────────────────────────────────────────────────
console.log('\n[6] 持久化（certFingerprint 必须可选，避免丢节点）');
{
  const ss = fs.readFileSync(path.join(svc, 'SubscriptionService.ets'), 'utf8');
  ok(/j\.certFingerprint !== undefined && !SubscriptionService\.validString\(j\.certFingerprint/.test(ss),
    'certFingerprint 按可选校验（老存储无该键不能丢整条节点）');
  ok(/n\.certFingerprint = j\.certFingerprint \?\? ''/.test(ss),
    '读取时对缺失的 certFingerprint 回退空串');
  ok(/j\.certFingerprint = n\.certFingerprint/.test(ss), '写入时持久化 certFingerprint');
}

// ── 7. 取回路径（2026-11-05 FlClash 照抄收口） ─────────────────────────────
console.log('\n[7] 取回 = FlClash 单路径（内核 utls；无 304 条件请求）');
{
  const fp = fs.readFileSync(path.join(svc, 'SubscriptionFetchPolicy.ets'), 'utf8');
  // FlClash 的下载没有 If-None-Match/304 逻辑 —— 单次 GET，失败即失败。
  // 本仓照抄后取回走内核 utls（TunBoxFetchText），不再有 @ohos 双路径。
  ok(/coreBridge\.fetchText\(/.test(fp), '订阅取回走内核 utls（FlClash request 同构）');
  ok(!/headers\['If-None-Match'\]/.test(fp), '不再发送 If-None-Match（FlClash 无条件请求）');
  ok(!/responseCode === 304/.test(fp), '不再识别 304（无条件请求即无 304）');
  ok(/etag: string = ''/.test(fp), 'SubscriptionFetchResult 保留 etag 字段（兼容旧存储）');

  const sub = fs.readFileSync(path.join(models, 'Subscription.ets'), 'utf8');
  const ss = fs.readFileSync(path.join(svc, 'SubscriptionService.ets'), 'utf8');
  ok(/etag: string = ''/.test(sub), 'Subscription 模型带 etag 字段');
  ok(/fetched\.notModified/.test(ss), '304 分支保留（字段兼容，服务端未给 etag 时不可达）');

  // 订阅自身的两条拉取路径（串行 refresh + 并发 prefetch）必须复用同一策略；
  // provider 拉取已整体删除（任务1：由内核 confineProviders 交给 mihomo 自己拉）。
  const fetchCalls = [...ss.matchAll(/SubscriptionFetchPolicy\.fetch\(\s*([^)]*)\)/g)]
    .map(m => m[1].replace(/\s+/g, ' '));
  const subCalls = fetchCalls.filter(c => c.startsWith('sub.url'));
  ok(subCalls.length === 2, `订阅自身有 2 处 fetch 调用（实际 ${subCalls.length}）`);
  ok(fetchCalls.length === subCalls.length,
    `provider App 侧拉取已删除（fetch 调用只剩订阅自身，实际 ${fetchCalls.length}）`);
}

// ── 8. 失败原因分类（人话建议，真机实测的错误码都要有归宿） ────────────────
console.log('\n[8] transportAdvice：真机出现过的错误码都要归到人话');
{
  const fp = fs.readFileSync(path.join(svc, 'SubscriptionFetchPolicy.ets'), 'utf8');
  // 起点必须从 `static` 开始（前一行是 `private` 关键字，带进去会 SyntaxError）
  const body = fp.slice(fp.indexOf('static transportAdvice'),
    fp.indexOf('private static extractHttpStatus'));
  // 抽出来跑真实现（去掉 ArkTS 类型标注）
  const js = body
    .replace('static transportAdvice(rawMessage: string, urlStr: string): string {',
      'function transportAdvice(rawMessage, urlStr) {')
    .replace(/let cause = '';/, "let cause = '';")
    .replace(/const msg = rawMessage\.toLowerCase\(\);/, 'const msg = rawMessage.toLowerCase();');
  let adviceOf = null;
  try {
    adviceOf = new Function(`${js}\nreturn transportAdvice;`)();
  } catch (e) {
    console.log(`  ❌ 无法抽取 transportAdvice: ${e.message}`);
  }
  ok(adviceOf !== null, '能抽出并运行 transportAdvice 真实现');

  if (adviceOf) {
    // 真机实测过的原始消息
    // FlClash 口径（§5.6）：本层只给**英文**底层建议 + 原始错误原文，中文只在 UI
    // 映射层产生；断言按英文口径（旧的中文断言是自创策略的遗留）。
    const cases = [
      ['code=2300028 Operation timeout', 'timed out'],
      ['code=2300060 Invalid SSL peer certificate or SSH remote key', 'TLS handshake'],
      ['SSL handshake has read 0 bytes and written 325 bytes', 'TLS handshake'],
      ['write:errno=104', 'reset by the peer'],
      ['getAddressesByName failed: NODENAME_NOT_RESOLVED', 'Cannot resolve'],
      ['订阅域名解析到私网或保留地址', 'private/reserved'],
      ['订阅响应体超过 8 MiB 限制', 'size limit'],
      ['some brand new failure mode', 'Cannot reach'],
    ];
    for (const [raw, expect] of cases) {
      const got = adviceOf(raw, 'https://example.com/s/x');
      ok(got.toLowerCase().includes(expect.toLowerCase()), `"${raw.slice(0, 42)}…" → 含「${expect}」`);
    }
    // 被阻断类必须给出「先连接 VPN」这条可操作建议（英文表述）
    ok(adviceOf('code=2300060 Invalid SSL peer certificate', 'u').includes('VPN'),
      '阻断类（TLS/超时/重置）都提示 VPN 路径');
    // 但「地址写错」类不该甩锅给 VPN
    ok(!adviceOf('NODENAME_NOT_RESOLVED', 'u').includes('VPN'),
      '域名无法解析不提示 VPN（那是地址写错，不是被墙）');
    // 本层必须是英文（中文只在 UI 映射层产生，FlClash 原文透传口径）
    for (const [raw] of cases) {
      ok(!/[\u4e00-\u9fa5]/.test(adviceOf(raw, 'u')), `"${raw.slice(0, 30)}…" 建议为英文（中文归 UI 层）`);
    }
    // 每条建议都必须以句号结尾（要展示给用户）
    for (const [raw] of cases) {
      ok(adviceOf(raw, 'u').trim().endsWith('.'), `"${raw.slice(0, 30)}…" 建议以句号结尾`);
    }
  }
}

// ── 9. 落盘白名单必须覆盖枚举全集（否则新增枚举值 ⇒ 静默丢订阅） ──────────
console.log('\n[9] validRefreshStatus 白名单 == 枚举全集');
{
  const subModel = fs.readFileSync(path.join(models, 'Subscription.ets'), 'utf8');
  const ss = fs.readFileSync(path.join(svc, 'SubscriptionService.ets'), 'utf8');

  const enumBody = subModel.slice(subModel.indexOf('export enum SubscriptionRefreshStatus'),
    subModel.indexOf('}', subModel.indexOf('export enum SubscriptionRefreshStatus')));
  const members = [...enumBody.matchAll(/^\s*(\w+)\s*=\s*'([^']*)'/gm)].map(m => m[1]);
  ok(members.length >= 11, `解析出枚举成员 ${members.length} 个`);

  // 终点必须取「起点之后的」下一个 private static（validString 定义在更前面，
  // 直接用它的 indexOf 会得到小于起点的下标 → 切出空串）
  const fnStart = ss.indexOf('private static validRefreshStatus');
  const fnEnd = ss.indexOf('\n  private static ', fnStart + 1);
  const fn = ss.slice(fnStart, fnEnd > fnStart ? fnEnd : fnStart + 2000);
  ok(fn.includes('SubscriptionRefreshStatus.OK'), '抽到 validRefreshStatus 函数体');
  const whitelisted = [...fn.matchAll(/SubscriptionRefreshStatus\.(\w+)/g)].map(m => m[1]);
  ok(whitelisted.length > 0, `白名单引用 ${whitelisted.length} 个枚举成员`);

  const missing = members.filter(m => !whitelisted.includes(m));
  ok(missing.length === 0,
    `白名单覆盖全部枚举成员${missing.length ? `（缺: ${missing.join(', ')} —— 会静默丢订阅！）` : ''}`);

  // 反向：白名单里不该有枚举中不存在的名字（拼写错会静默失效）
  const bogus = whitelisted.filter(w => !members.includes(w));
  ok(bogus.length === 0, `白名单无拼写错误${bogus.length ? `（可疑: ${bogus.join(', ')}）` : ''}`);

  // 空串必须放行（direct 伪订阅的 lastRefreshResult 就是空串）
  ok(/if \(value === ''\) \{\s*return true;/.test(fn), '空串（direct 伪订阅）必须放行');
}

// ── 10. 取回层与 FlClash 同构：单一 UA、单次请求（无 UA 链 / 无传输重试）─────
console.log('\n[10] 取回层：单一 UA + 单次请求（FlClash 口径）');
{
  const fp = fs.readFileSync(path.join(svc, 'SubscriptionFetchPolicy.ets'), 'utf8');

  ok(!/UA_CHAIN/.test(fp), '不存在 UA 链（FlClash 只有一个 packageInfo.ua）');
  ok(!/TRANSPORT_RETRY_(MAX|BUDGET_MS)/.test(fp), '不存在传输层重试预算（失败即失败）');
  ok(!/uaIndex/.test(fp), '不存在 uaIndex 轮换残留');
  // 真机取证：@ohos.net.http 与 Go 默认 TLS 都被 Cloudflare 判成机器人 → 必须走内核 utls。
  ok(/coreBridge\.fetchText\(fetchUrl, ua, auth\.header\)/.test(fp),
    '取回走内核 utls（浏览器级 TLS 指纹）');
  ok(/const ua = await resolveUserAgent\(\);/.test(fp),
    '单次请求只取一个 UA');
  // 403 不是限流：FlClash 只把它当 badResponse。
  ok(/status === 429/.test(fp), '只有 429 归为限流');
  ok(/this\.httpStatus === 429/.test(fp), 'isRateLimited() 只认 429（403 如实报 HTTP）');
  ok(/const status = SubscriptionFetchPolicy\.extractHttpStatus\(e, msg\);/.test(fp),
    'HTTP 状态码从错误里如实提取');
}

console.log(`\n${passed} passed, ${failed} failed`);
fs.rmSync(stage, { recursive: true, force: true });
process.exit(failed === 0 ? 0 : 1);
