#!/usr/bin/env node
/**
 * 订阅解析保真闸门（Sub Parse Fidelity Gate）
 *
 * ## 为什么要有这道闸门
 *
 * 2026-10-20 真机报障：mitce.io 的 34 个 VLESS·REALITY 节点测速**全部秒失败**
 * （mihomo 503，5-10ms），同一次测速里别的订阅节点正常、隧道用同一个节点也能连通。
 * mihomo 的 503 语义是 URLTest 返回了 error（hub/route/proxies.go:135-143，
 * 只有 err!=nil 或 delay==0 才给 "An error occurred in the delay test"）。
 *
 * ⇒ 节点进了内核代理表（所以不是 404），但 REALITY 握手参数（public-key /
 *   short-id / servername）不完整 → 拨号立刻失败 → 整片判失败。
 * 历史上同型事故还有一次：「36 个 anytls 因解析丢凭据被丢弃」。
 *
 * 根因是同一个：**参数在解析层被改名 / 丢弃 / 改写，而没有任何闸门能证明它没丢**。
 * 本闸门就是来证明「没丢」的。
 *
 * ## 闸门断言什么（对 scripts/fixtures/subs/ 下每一条 URI）
 *
 *   A. 键集合：解析出的规范键集合 **==** 参数表声明并由该 URI 供给的键集合
 *      （不多、不少 —— 多了是凭空造字段，少了是丢参数）
 *   B. 值保真：每个键的值与「URI 原文独立解码出的值」sha256 前 8 位一致
 *      （证明值没被改写 / 截断 / 改名；敏感值即凭据，同样逐字节对账）
 *   C. 必填完整性：按参数表（含条件必填 security=reality ⇒ public-key）
 *      算出缺哪些键；缺了就必须**整条 ParseError**，绝不能出现半条节点
 *   D. 未知参数不丢：参数表没声明的 URI 参数必须出现在 unknownParams 里
 *      （静默丢弃就是「参数被改名」的真凶）
 *   E. 结构字段：server / port / 端口跳跃区间 / 显示名与原文一致
 *   F. 指纹：RuntimeProfile.profileFingerprint() 必须等于同一份规范化文本的
 *      node:crypto SHA-256（自带的纯 JS SHA-256 实现要能被独立实现对账）
 *
 * ## 负对照（闸门必须真的会红）
 *
 *   node scripts/verify-sub-parse-fidelity.mjs --self-test
 * 会把 fixtures 复制一份、**故意改坏**（截断 REALITY 公钥 / 删掉 UUID），
 * 再跑一遍检查器 —— 检查器必须报 FAILED。闸门咬不住坏样本 = 闸门没用。
 *
 * ## 跑法
 *
 *   node scripts/verify-sub-parse-fidelity.mjs              # 正常跑
 *   node scripts/verify-sub-parse-fidelity.mjs --self-test  # 附带负对照
 *
 * 退出码：0 = 全过；1 = 有断言失败（或负对照没被抓住）。
 */
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const srcDir = path.join(root, 'entry/src/main/ets/commons/subscription');
const fixtureDir = path.join(here, 'fixtures', 'subs');
const yamlFixtureDir = path.join(fixtureDir, 'yaml');
const servicesDir = path.join(root, 'entry/src/main/ets/commons/services');

/** 订阅解析层要一起暂存的真源码（两条导入路径共用同一张表/同一套口径） */
const SUB_MODULES = [
  'ProtocolParamTable', 'UriNodeParser', 'RuntimeProfile',
  'NodeUsability', 'UnusableLedger', 'YamlNodeAdapter', 'BodyDispatch',
];

/**
 * YAML 样本（scripts/fixtures/subs/yaml/clash-valid.yaml）的**手写期望**。
 *
 * 故意不引用实现里的参数表 —— 期望值直接抄自 YAML 原文，
 * 这样"合并器/参数表把字段丢了或改写了"会被闸门抓住。
 */
const YAML_VALID_EXPECT = [
  {
    name: 'Y-REALITY-01',
    merged: {
      type: 'vless', server: 'de152710bb8b70d108ec13c7.mitce-nocontact.com', port: 443,
      uuid: '11111111-2222-3333-4444-555555555555', network: 'ws', tls: true,
      servername: 'www.example.test', clientFingerprint: 'chrome', flow: 'xtls-rprx-vision',
      realityPublicKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      realityShortId: '0123456789abcdef', wsPath: '/ray', wsHost: 'www.example.test',
    },
    canonical: {
      'name': 'Y-REALITY-01',
      'server': 'de152710bb8b70d108ec13c7.mitce-nocontact.com',
      'port': '443',
      'uuid': '11111111-2222-3333-4444-555555555555',
      'network': 'ws',
      'flow': 'xtls-rprx-vision',
      'client-fingerprint': 'chrome',
      'reality-public-key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      'reality-short-id': '0123456789abcdef',
      'security': 'reality',
      'sni': 'www.example.test',
      'ws-path': '/ray',
      'ws-host': 'www.example.test',
    },
  },
  {
    name: 'Y-VMESS-01',
    merged: {
      type: 'vmess', server: 'vmess.example.test', port: 443,
      uuid: '66666666-7777-8888-9999-000000000000', alterId: 0, cipher: 'auto',
      tls: true, servername: 'vmess.example.test', network: 'ws',
      wsPath: '/vm', wsHost: 'vmess.example.test',
    },
    canonical: {
      'name': 'Y-VMESS-01',
      'server': 'vmess.example.test',
      'port': '443',
      'uuid': '66666666-7777-8888-9999-000000000000',
      'cipher': 'auto',
      'network': 'ws',
      'tls': 'true',
      'sni': 'vmess.example.test',
      'ws-path': '/vm',
      'ws-host': 'vmess.example.test',
    },
  },
  {
    name: 'Y-TROJAN-01',
    merged: {
      type: 'trojan', server: 'trojan.example.test', port: 443,
      password: 'trojan-pass-001', servername: 'trojan.example.test', tls: false,
    },
    canonical: {
      'name': 'Y-TROJAN-01',
      'server': 'trojan.example.test',
      'port': '443',
      'password': 'trojan-pass-001',
      'sni': 'trojan.example.test',
    },
  },
  {
    name: 'Y-SS-01',
    merged: {
      type: 'ss', server: 'ss.example.test', port: 8388,
      cipher: 'aes-256-gcm', password: 'ss-pass-001',
    },
    canonical: {
      'name': 'Y-SS-01',
      'server': 'ss.example.test',
      'port': '8388',
      'password': 'ss-pass-001',
      'cipher': 'aes-256-gcm',
    },
  },
  {
    name: 'Y-HY2-01',
    merged: {
      type: 'hysteria2', server: 'hy2.example.test', port: 443,
      password: 'hy2-pass-001', servername: 'hy2.example.test', tls: false,
      obfs: 'salamander', obfsParam: 'hy2-obfs-001',
      hyUp: '50Mbps', hyDown: '200Mbps',
    },
    canonical: {
      'name': 'Y-HY2-01',
      'server': 'hy2.example.test',
      'port': '443',
      'password': 'hy2-pass-001',
      'obfs': 'salamander',
      'obfs-password': 'hy2-obfs-001',
      'sni': 'hy2.example.test',
      'up': '50Mbps',
      'down': '200Mbps',
    },
  },
];

/**
 * 每协议的必填键 —— 这份清单是**独立手写**的，不从参数表推导。
 * 目的：参数表里的 required 写错了，闸门也要能发现（否则解析器与表同错同过）。
 */
const REQUIRED_BY_PROTOCOL = {
  vless: ['server', 'port', 'uuid'],
  vmess: ['server', 'port', 'uuid'],
  trojan: ['server', 'port', 'password'],
  ss: ['server', 'port', 'cipher', 'password'],
  ssr: ['server', 'port', 'protocol', 'cipher', 'obfs', 'password'],
  hysteria2: ['server', 'port', 'password'],
  // 2026-10-20（B6）：hysteria v1 并入规范解析层（旧解析器退场后不许丢这个协议）
  hysteria: ['server', 'port', 'password'],
  tuic: ['server', 'port', 'password'],
  anytls: ['server', 'port', 'password'],
  snell: ['server', 'port', 'psk'],
  http: ['server', 'port'],
  socks: ['server', 'port'],
};

/** 条件必填：security=reality ⇒ 必须带 REALITY 公钥 */
function conditionalRequired(protocol, params) {
  if (protocol !== 'vless') return [];
  if (params.get('security') !== 'reality') return [];
  return ['reality-public-key'];
}

/** sha256 前 8 位十六进制（比对的"指纹"） */
function digest8(text) {
  return crypto.createHash('sha256').update(text, 'utf8').digest('hex').slice(0, 8);
}

/** 独立实现的百分号解码（Node 自带，与解析器内部实现互为对照） */
function pctDecode(input) {
  try {
    return decodeURIComponent(input);
  } catch {
    return input;
  }
}

/** 独立实现的 base64 判定（严格：长度是 4 的倍数、只含 base64 字符） */
function isBase64Text(input) {
  if (!input || input.length % 4 !== 0) return false;
  let core = input;
  let pad = 0;
  while (core.endsWith('=')) {
    core = core.slice(0, -1);
    pad += 1;
  }
  if (!core || pad > 2) return false;
  return /^[A-Za-z0-9+/]+$/.test(core);
}

function b64Decode(input) {
  return Buffer.from(String(input).replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8');
}

function setIfPresent(map, key, value) {
  if (value === undefined || value === null || value === '') return;
  if (!map.has(key)) map.set(key, value);
}

/** ── 期望值计算（oracle）：独立于解析器实现，只借参数表当"规范" ───────────── */

function splitUri(uri) {
  const raw = uri.trim();
  const sep = raw.indexOf('://');
  if (sep <= 0) return null;
  const scheme = raw.slice(0, sep).toLowerCase();
  let rest = raw.slice(sep + 3);
  let name = '';
  const hash = rest.indexOf('#');
  if (hash >= 0) {
    name = pctDecode(rest.slice(hash + 1));
    rest = rest.slice(0, hash);
  }
  let query = '';
  const q = rest.indexOf('?');
  if (q >= 0) {
    query = rest.slice(q + 1);
    rest = rest.slice(0, q);
  }
  return { scheme, rest, query, name };
}

function queryMap(query) {
  const out = new Map();
  if (!query) return out;
  for (const kv of query.split('&')) {
    if (!kv) continue;
    const eq = kv.indexOf('=');
    const key = eq < 0 ? kv : kv.slice(0, eq);
    const rawValue = eq < 0 ? '' : kv.slice(eq + 1);
    if (!key) continue;
    if (!out.has(key)) out.set(key, pctDecode(rawValue));
  }
  return out;
}

function splitAuthority(authority) {
  const at = authority.lastIndexOf('@');
  if (at < 0) return null;
  const userInfo = authority.slice(0, at);
  const hostPart = authority.slice(at + 1);
  if (hostPart.startsWith('[')) {
    const close = hostPart.indexOf(']');
    if (close < 0 || hostPart[close + 1] !== ':') return null;
    return { userInfo, server: hostPart.slice(1, close), portRaw: hostPart.slice(close + 2) };
  }
  const colon = hostPart.lastIndexOf(':');
  if (colon < 0) return null;
  return { userInfo, server: hostPart.slice(0, colon), portRaw: hostPart.slice(colon + 1) };
}

function jsonField(obj, key) {
  const v = obj[key];
  if (v === undefined || v === null) return '';
  if (typeof v === 'string') return v;
  if (typeof v === 'number') return String(v);
  if (typeof v === 'boolean') return String(v);
  return '';
}

/**
 * 算出一条 URI 的"期望"：规范键 → 期望值。
 * @returns {ok:true, protocol, params, unknown, name, server, portRaw, network}
 *        | {ok:false, reason}
 */
function oracle(uri, table) {
  const parts = splitUri(uri);
  if (!parts) return { ok: false, reason: 'URI 缺少协议头' };
  const protocol = table.ProtocolParamTableRegistry.protocolOfScheme(parts.scheme);
  if (!protocol) return { ok: false, reason: `不支持的协议: ${parts.scheme}` };

  const params = new Map();
  const unknown = new Map();

  if (protocol === 'vmess') {
    let json;
    try {
      json = JSON.parse(b64Decode(parts.rest));
    } catch {
      return { ok: false, reason: 'vmess 载荷不是合法 JSON' };
    }
    const network = jsonField(json, 'net');
    const keys = ['ps', 'add', 'port', 'id', 'aid', 'scy', 'tls', 'sni', 'net', 'alpn',
      'path', 'host', 'serviceName', 'type', 'fp', 'pcs'];
    for (const key of keys) {
      const value = jsonField(json, key);
      if (value === '') continue;
      const canonical = table.ProtocolParamTableRegistry.resolveAlias('vmess', network, key);
      if (!canonical) {
        if (!unknown.has(key)) unknown.set(key, value);
        continue;
      }
      setIfPresent(params, canonical, value);
    }
    return {
      ok: true,
      protocol,
      params,
      unknown,
      name: jsonField(json, 'ps'),
      server: jsonField(json, 'add'),
      portRaw: jsonField(json, 'port'),
      network: network || 'tcp',
    };
  }

  if (protocol === 'ssr') {
    const decoded = b64Decode(parts.rest);
    const idx = decoded.indexOf('/?');
    const head = idx < 0 ? decoded : decoded.slice(0, idx);
    const tail = idx < 0 ? '' : decoded.slice(idx + 2);
    const segments = head.split(':');
    if (segments.length < 6) return { ok: false, reason: 'ssr 载荷字段数不足' };
    const t = segments.length - 5;
    setIfPresent(params, 'server', segments.slice(0, t).join(':'));
    setIfPresent(params, 'port', segments[t]);
    setIfPresent(params, 'protocol', segments[t + 1]);
    setIfPresent(params, 'cipher', segments[t + 2]);
    setIfPresent(params, 'obfs', segments[t + 3]);
    setIfPresent(params, 'password', segments[t + 4]);
    let name = '';
    if (tail) {
      for (const kv of tail.split('&')) {
        const eq = kv.indexOf('=');
        if (eq < 0) continue;
        const key = kv.slice(0, eq);
        const rawValue = kv.slice(eq + 1);
        let value = '';
        if (isBase64Text(rawValue)) value = b64Decode(rawValue);
        if (value === '') value = pctDecode(rawValue);
        if (key === 'remarks') name = value;
        else if (key === 'protoparam') setIfPresent(params, 'protocol-param', value);
        else if (key === 'obfsparam') setIfPresent(params, 'obfs-param', value);
        else if (value !== '') unknown.set(key, value);
      }
    }
    setIfPresent(params, 'name', name);
    return { ok: true, protocol, params, unknown, name, server: params.get('server') || '',
      portRaw: params.get('port') || '', network: 'tcp' };
  }

  if (protocol === 'ss') {
    const authority = parts.rest;
    let userInfo = '';
    let server = '';
    let portRaw = '';
    const at = authority.lastIndexOf('@');
    if (at >= 0) {
      userInfo = authority.slice(0, at);
      const host = splitAuthority(authority);
      if (!host) return { ok: false, reason: 'ss 地址格式不对' };
      server = host.server;
      portRaw = host.portRaw;
    } else {
      const decoded = b64Decode(authority);
      const at2 = decoded.lastIndexOf('@');
      if (at2 < 0) return { ok: false, reason: 'ss 载荷不是合法 base64' };
      userInfo = decoded.slice(0, at2);
      const hostPart = decoded.slice(at2 + 1);
      const colon = hostPart.lastIndexOf(':');
      if (colon < 0) return { ok: false, reason: 'ss 载荷里的地址格式不对' };
      server = hostPart.slice(0, colon);
      portRaw = hostPart.slice(colon + 1);
    }
    const userRaw = b64Decode(userInfo);
    const colon2 = userRaw.indexOf(':');
    if (colon2 < 0) return { ok: false, reason: 'ss 的 userinfo 不是合法 base64(method:password)' };
    setIfPresent(params, 'cipher', userRaw.slice(0, colon2));
    setIfPresent(params, 'password', userRaw.slice(colon2 + 1));
    setIfPresent(params, 'server', server);
    setIfPresent(params, 'port', portRaw);
    setIfPresent(params, 'name', parts.name);
    for (const [k, v] of queryMap(parts.query)) {
      const canonical = table.ProtocolParamTableRegistry.resolveAlias('ss', 'tcp', k);
      if (!canonical) {
        if (v !== '' && !unknown.has(k)) unknown.set(k, v);
        continue;
      }
      setIfPresent(params, canonical, v);
    }
    return { ok: true, protocol, params, unknown, name: parts.name, server, portRaw, network: 'tcp' };
  }

  // 通用 authority 形态
  const host = splitAuthority(parts.rest);
  if (!host) return { ok: false, reason: '地址格式不对（应为 [凭据@]host:port）' };
  const userInfo = pctDecode(host.userInfo);
  const raw = queryMap(parts.query);
  let network = 'tcp';
  const typeRaw = raw.get('type') ?? raw.get('network') ?? raw.get('net') ?? '';
  if (typeRaw) network = typeRaw.toLowerCase();

  for (const [k, v] of raw) {
    const canonical = table.ProtocolParamTableRegistry.resolveAlias(protocol, network, k);
    if (!canonical) {
      if (v !== '' && !unknown.has(k)) unknown.set(k, v);
      continue;
    }
    if (v === '') continue;
    setIfPresent(params, canonical, v);
  }

  if (protocol === 'vless') {
    setIfPresent(params, 'uuid', userInfo);
  } else if (protocol === 'tuic') {
    const colon = userInfo.indexOf(':');
    if (colon >= 0) {
      setIfPresent(params, 'uuid', userInfo.slice(0, colon));
      setIfPresent(params, 'password', userInfo.slice(colon + 1));
    } else {
      setIfPresent(params, 'password', userInfo);
    }
  } else if (protocol === 'http' || protocol === 'socks') {
    const colon = userInfo.indexOf(':');
    if (colon >= 0) {
      setIfPresent(params, 'username', userInfo.slice(0, colon));
      setIfPresent(params, 'password', userInfo.slice(colon + 1));
    } else {
      setIfPresent(params, 'username', userInfo);
    }
  } else if (protocol === 'snell') {
    setIfPresent(params, 'psk', userInfo);
  } else {
    setIfPresent(params, 'password', userInfo);
  }
  // hysteria2 的端口跳跃：链接里 `host:20000-30000` ⇒ port 取首个端口，
  // 原始区间另存 ports（mihomo 的 hysteria2 语义，见 common/convert/v.go）。
  let portRaw = host.portRaw;
  if (protocol === 'hysteria2') {
    const hop = portRaw.trim().replace(/\/+$/, '');
    if (/^[0-9,-]+$/.test(hop) && (hop.includes(',') || hop.includes('-'))) {
      const first = hop.match(/\d{1,5}/);
      if (first) {
        portRaw = first[0];
        setIfPresent(params, 'ports', hop);
      }
    }
  }
  setIfPresent(params, 'server', host.server);
  setIfPresent(params, 'port', portRaw);
  setIfPresent(params, 'name', parts.name);

  return { ok: true, protocol, params, unknown, name: parts.name, server: host.server,
    portRaw, network };
}

/** ── 加载 .ets（Node 侧 type-stripping；必要时用 --experimental-transform-types 重启） ── */

async function loadModules(sourceDir = srcDir) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tunbox-sub-parse-'));
  fs.writeFileSync(path.join(tmp, 'package.json'), JSON.stringify({ type: 'module' }), 'utf8');
  // YamlMerger 只依赖 @kit.ArkTS 的 util（TextEncoder.create）—— 给最小垫片
  fs.writeFileSync(path.join(tmp, 'shim_appkit.ts'), [
    'class Encoder {',
    '  static create(_e?: string): Encoder { return new Encoder(); }',
    '  encodeInto(s: string): { read: number } { return { read: Buffer.byteLength(s, "utf8") }; }',
    '}',
    'class Decoder {',
    '  static create(_e?: string): Decoder { return new Decoder(); }',
    '  decodeToString(b: Uint8Array): string { return Buffer.from(b).toString("utf8"); }',
    '}',
    'export const util = { TextDecoder: Decoder, TextEncoder: Encoder };',
    'export const BusinessError = class extends Error { code: number = 0; };',
  ].join('\n'), 'utf8');
  for (const name of SUB_MODULES) {
    const text = fs.readFileSync(path.join(sourceDir, `${name}.ets`), 'utf8');
    const patched = text
      .replace(/from '\.\/([A-Za-z0-9_]+)'/g, "from './$1.ts'")
      .replace(/from '\.\.\/services\/YamlMerger'/g, "from './YamlMerger.ts'");
    fs.writeFileSync(path.join(tmp, `${name}.ts`), patched, 'utf8');
  }
  // 真 YamlMerger（两条路径的 YAML 侧都走它）——始终用仓库里的那份
  const merger = fs.readFileSync(path.join(servicesDir, 'YamlMerger.ets'), 'utf8')
    .replace(/from '@kit\.ArkTS'/g, "from './shim_appkit.ts'");
  fs.writeFileSync(path.join(tmp, 'YamlMerger.ts'), merger, 'utf8');

  const out = { dir: tmp };
  for (const name of SUB_MODULES) {
    out[name] = await import(pathToFileURL(path.join(tmp, `${name}.ts`)).href);
  }
  out.merger = await import(pathToFileURL(path.join(tmp, 'YamlMerger.ts')).href);
  out.table = out.ProtocolParamTable;
  out.parser = out.UriNodeParser;
  out.profile = out.RuntimeProfile;
  return out;
}

/** 复制订阅解析层的 .ets 源文件到临时目录（负对照要在这里做「故意改坏」） */
function copySources(dest) {
  fs.mkdirSync(dest, { recursive: true });
  for (const name of SUB_MODULES) {
    fs.copyFileSync(path.join(srcDir, `${name}.ets`), path.join(dest, `${name}.ets`));
  }
  return dest;
}

/** ── 读样本 ──────────────────────────────────────────────────────────────── */

function readFixtures(dir) {
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.txt')).sort();
  const cases = [];
  for (const file of files) {
    const text = fs.readFileSync(path.join(dir, file), 'utf8');
    let negative = false;
    for (const rawLine of text.split(/\r?\n/)) {
      const line = rawLine.trim();
      if (!line) continue;
      if (line.startsWith('##')) {
        const directive = line.replace(/^#+/, '').trim().toLowerCase();
        if (directive === 'negative') negative = true;
        continue;
      }
      cases.push({ file, uri: line, negative });
    }
  }
  return cases;
}

/** ── 检查器 ──────────────────────────────────────────────────────────────── */

function runChecks(dir, mods, opts = {}) {
  const { table, parser, profile } = mods;
  const cases = readFixtures(dir);
  const lines = [];
  let passed = 0;
  let failed = 0;
  const ok = (cond, label, detail) => {
    if (cond) {
      passed += 1;
      if (opts.verbose) lines.push(`  ✅ ${label}`);
    } else {
      failed += 1;
      lines.push(`  ❌ ${label}${detail ? ` — ${detail}` : ''}`);
    }
  };

  // 表自检：每协议一份，别名不得互相打架
  const protocols = table.ProtocolParamTableRegistry.protocols();
  ok(protocols.length === 12, `参数表覆盖 12 个协议（实际 ${protocols.length}）`);
  for (const protocol of protocols) {
    const tbl = table.ProtocolParamTableRegistry.of(protocol);
    const seen = new Map();
    let clash = '';
    for (const spec of tbl.specs) {
      for (const alias of spec.aliases) {
        const key = `${spec.transport}|${alias.toLowerCase()}`;
        const owner = seen.get(key);
        if (owner !== undefined && owner !== spec.key) {
          clash = `别名 ${alias} 同时属于 ${owner} 与 ${spec.key}`;
        } else {
          seen.set(key, spec.key);
        }
      }
    }
    ok(clash === '', `${protocol} 参数表别名无冲突`, clash);
  }

  // 独立手写的必填清单 vs 参数表的 required（表写错了要能发现）
  for (const protocol of protocols) {
    const declared = table.ProtocolParamTableRegistry.requiredKeys(protocol).slice().sort();
    const expected = (REQUIRED_BY_PROTOCOL[protocol] || []).slice().sort();
    ok(JSON.stringify(declared) === JSON.stringify(expected),
      `${protocol} 的必填清单与独立手写清单一致`,
      `表=${declared.join(',')} 手写=${expected.join(',')}`);
  }

  const nodes = [];
  let sensitiveChecked = 0;

  for (const c of cases) {
    const tag = `${c.file} :: ${c.uri.slice(0, 60)}${c.uri.length > 60 ? '…' : ''}`;
    const expect = oracle(c.uri, table);
    const result = parser.parse(c.uri);

    if (!expect.ok) {
      // 结构就不合法的 URI：必须整条报错，且不能返回半条节点
      ok(result.ok === false, `${tag} → 整条 ParseError（结构不合法）`);
      if (result.ok === false) {
        ok(typeof result.reason === 'string' && result.reason.length > 0,
          `${tag} → 错误带原因`);
      }
      continue;
    }

    const required = (REQUIRED_BY_PROTOCOL[expect.protocol] || []).slice();
    for (const key of conditionalRequired(expect.protocol, expect.params)) required.push(key);
    const missing = required.filter((k) => !expect.params.has(k) || expect.params.get(k) === '');

    if (missing.length > 0) {
      // 负例：必须整条 ParseError
      ok(c.negative === true, `${tag} → 缺必填的样本被放在 negative 段`);
      ok(result.ok === false, `${tag} → 缺必填（${missing.join('、')}）时整条 ParseError`);
      if (result.ok === false) {
        const got = (result.missing || []).slice().sort();
        ok(JSON.stringify(got) === JSON.stringify(missing.slice().sort()),
          `${tag} → 错误列出的缺失键与独立计算一致`,
          `期望 ${missing.join('、')} / 实际 ${got.join('、')}`);
        ok(typeof result.reason === 'string' && result.reason.length > 0,
          `${tag} → 错误带人话原因`);
      }
      continue;
    }

    // 正例
    ok(c.negative === false, `${tag} → 完整的样本没有被放进 negative 段`);
    if (result.ok === false) {
      ok(false, `${tag} → 应解析成功却报错：${result.reason}`);
      continue;
    }
    const node = result;

    // A. 键集合
    const parsedKeys = Array.from(node.params.keys()).sort();
    const expectedKeys = Array.from(expect.params.keys()).sort();
    ok(JSON.stringify(parsedKeys) === JSON.stringify(expectedKeys),
      `${tag} → 键集合与参数表一致`,
      `解析=${parsedKeys.join(',')} 期望=${expectedKeys.join(',')}`);

    // B. 值保真（sha256 前 8 位；敏感值同样逐字节对账）
    const sensitive = new Set(table.ProtocolParamTableRegistry.sensitiveKeys(expect.protocol));
    for (const key of expectedKeys) {
      const got = node.params.get(key);
      const want = expect.params.get(key);
      const same = got !== undefined && digest8(got) === digest8(want);
      ok(same, `${tag} → [${key}] 值未被改写（sha256:${digest8(want)}）`,
        `解析=${got ?? '(缺失)'} 期望=${want}`);
      if (sensitive.has(key)) {
        sensitiveChecked += 1;
        ok(got !== undefined && got.length > 0, `${tag} → [${key}] 敏感值非空`);
      }
    }

    // D. 未知参数不丢
    const parsedUnknown = Array.from(node.unknownParams.keys()).sort();
    const expectedUnknown = Array.from(expect.unknown.keys()).sort();
    ok(JSON.stringify(parsedUnknown) === JSON.stringify(expectedUnknown),
      `${tag} → 未声明的 URI 参数全部进 unknownParams（没被静默丢掉）`,
      `解析=${parsedUnknown.join(',')} 期望=${expectedUnknown.join(',')}`);
    for (const key of expectedUnknown) {
      const got = node.unknownParams.get(key);
      const want = expect.unknown.get(key);
      ok(got !== undefined && digest8(got) === digest8(want),
        `${tag} → unknown[${key}] 值未被改写`);
    }

    // E. 结构字段
    ok(node.server === expect.server, `${tag} → server 与原文一致`);
    ok(node.portRaw === expect.portRaw, `${tag} → 端口段原样保留`,
      `解析=${node.portRaw} 期望=${expect.portRaw}`);
    ok(node.name === (expect.name || expect.server), `${tag} → 显示名与原文一致`);

    nodes.push(node);
  }

  // F. 指纹：自带纯 JS SHA-256 必须与 node:crypto 对得上
  const prof = new profile.RuntimeProfile();
  for (const n of nodes) {
    const pn = new profile.ProfileNode();
    pn.id = `${n.protocol}|${n.server}|${n.portRaw}|${n.name}`;
    pn.name = n.name;
    pn.protocol = n.protocol;
    pn.server = n.server;
    pn.port = n.port;
    pn.usable = true;
    pn.params = n.params;
    prof.nodes.push(pn);
  }
  const group = new profile.ProfileGroup();
  group.name = 'PROXY';
  group.kind = 'select';
  group.members = prof.nodes.map((n) => n.name);
  prof.groups.push(group);
  const rule = new profile.ProfileRule();
  rule.type = 'MATCH';
  rule.payload = '';
  rule.target = 'PROXY';
  prof.rules.push(rule);
  const provider = new profile.ProfileProviderRef();
  provider.name = 'fake-rule-set';
  provider.kind = 'rule-provider';
  provider.behavior = 'domain';
  provider.url = 'https://example.test/rules.list';
  provider.path = './rules.list';
  prof.providerRefs.push(provider);

  const canonical = profile.profileCanonicalText(prof);
  const expectedDigest = crypto.createHash('sha256').update(canonical, 'utf8').digest('hex');
  ok(profile.profileFingerprint(prof) === expectedDigest,
    'profileFingerprint() == 规范化文本的 SHA-256（与 node:crypto 对账）');

  // 指纹对顺序不敏感、对内容敏感
  const reordered = new profile.RuntimeProfile();
  reordered.nodes = prof.nodes.slice().reverse();
  reordered.groups = prof.groups.slice();
  reordered.rules = prof.rules.slice();
  reordered.providerRefs = prof.providerRefs.slice();
  ok(profile.profileFingerprint(reordered) === profile.profileFingerprint(prof),
    'profileFingerprint() 与节点顺序无关（规范化稳定）');

  const mutated = new profile.RuntimeProfile();
  mutated.nodes = prof.nodes.map((n) => {
    const copy = new profile.ProfileNode();
    copy.id = n.id;
    copy.name = n.name;
    copy.protocol = n.protocol;
    copy.server = n.server;
    copy.port = n.port;
    copy.params = new Map(n.params);
    return copy;
  });
  if (mutated.nodes.length > 0) {
    const first = mutated.nodes[0];
    first.params.set('probe-key', 'probe-value');
    ok(profile.profileFingerprint(mutated) !== profile.profileFingerprint(prof),
      'profileFingerprint() 对参数改动敏感');
  } else {
    ok(false, 'profileFingerprint() 对参数改动敏感（没有可比对的节点）');
  }

  ok(sensitiveChecked > 0, `敏感值确实被逐条对账（${sensitiveChecked} 处）`);

  // ── G/H/I/J：YAML 路径保真 + 缺必填口径 + base64 分派 + vless SNI ──
  runYamlAndUsabilityChecks(dir, mods, ok);

  return { passed, failed, lines, caseCount: cases.length };
}

/**
 * YAML 路径保真 / 不可用口径 / base64 分派 / vless SNI 的断言。
 *
 * 全部用**独立手写**的期望值（不读实现里的表），实现改错要能被发现。
 */
function runYamlAndUsabilityChecks(dir, mods, ok) {
  const merger = mods.merger;
  const YamlMerger = merger.YamlMerger;
  // 模块命名空间 → 具体类（ArkTS/ESM 下类在命名空间里）
  const YamlNodeAdapter = mods.YamlNodeAdapter.YamlNodeAdapter;
  const NodeUsability = mods.NodeUsability.NodeUsability;
  const UnusableLedgerMod = mods.UnusableLedger;
  const UnusableLedger = UnusableLedgerMod.UnusableLedger;
  const UnusableRecord = UnusableLedgerMod.UnusableRecord;
  const BodyDispatch = mods.BodyDispatch.BodyDispatch;
  const BodyKind = mods.BodyDispatch.BodyKind;

  const validPath = path.join(yamlFixtureDir, 'clash-valid.yaml');
  const brokenPath = path.join(yamlFixtureDir, 'clash-missing-required.yaml');
  if (!fs.existsSync(validPath) || !fs.existsSync(brokenPath)) {
    ok(false, 'YAML 样本存在（clash-valid.yaml / clash-missing-required.yaml）');
    return;
  }
  const validYaml = fs.readFileSync(validPath, 'utf8');
  const brokenYaml = fs.readFileSync(brokenPath, 'utf8');

  // ── G. YAML 路径保真（合并器 + 规范键视图）──
  YamlMerger.resetSkipStats();
  const merged = YamlMerger.merge([validYaml], 'fidelity-fixture', '');
  ok(merged.length === YAML_VALID_EXPECT.length,
    `YAML 样本合并出 ${YAML_VALID_EXPECT.length} 条节点（实际 ${merged.length}）`);

  const plan = YamlNodeAdapter.plan(merged, validYaml);
  const byName = new Map();
  for (const entry of plan.entries) {
    byName.set(entry.merged.name, entry);
  }
  for (const expect of YAML_VALID_EXPECT) {
    const entry = byName.get(expect.name);
    if (entry === undefined) {
      ok(false, `YAML 节点 ${expect.name} 被合并产出`);
      continue;
    }
    const m = entry.merged;
    // G1 结构化槽位逐字保真（这些字段就是最终写进 ProxyNode 的值）
    for (const field of Object.keys(expect.merged)) {
      const got = String(m[field] === undefined ? '' : m[field]);
      const want = String(expect.merged[field]);
      ok(digest8(got) === digest8(want),
        `YAML ${expect.name} → 槽位 ${field} 未被改写（sha256:${digest8(want)}）`,
        `合并=${got} 期望=${want}`);
    }
    // G2 规范键视图：键集合与值都与手写期望一致（两条路径同一套规范键）
    const gotKeys = Array.from(entry.canonical.params.keys()).sort();
    const wantKeys = Object.keys(expect.canonical).sort();
    ok(JSON.stringify(gotKeys) === JSON.stringify(wantKeys),
      `YAML ${expect.name} → 规范键集合与手写期望一致`,
      `实际=${gotKeys.join(',')} 期望=${wantKeys.join(',')}`);
    for (const key of wantKeys) {
      const got = entry.canonical.params.get(key);
      const want = expect.canonical[key];
      ok(got !== undefined && digest8(got) === digest8(want),
        `YAML ${expect.name} → 规范键 [${key}] 值保真（sha256:${digest8(want)}）`,
        `实际=${got ?? '(缺失)'} 期望=${want}`);
    }
    // G3 【2026-10-22 · FlClash 同构】展示视图里**没有**可用性判词：
    // 节点能不能用只由内核决定（订阅原文进内核配置，内核 `/proxies` 说了算），
    // App 侧只做映射（规范键/凭据），不再产出"定义完整/不完整"。
    ok(entry.excluded === undefined,
      `YAML ${expect.name} → 展示视图里没有"不可用"判词字段`);
    ok(entry.canonical.availability === undefined,
      `YAML ${expect.name} → 规范键视图不含可用性结论`);
    ok(entry.canonical.extras.size === 0,
      `YAML ${expect.name} → 没有"原文有但参数表没声明"的字段`,
      JSON.stringify(Array.from(entry.canonical.extras.keys())));
  }

  // ── H. 缺必填的节点：App **不再判死刑**（2026-10-22 FlClash 同构）──
  //
  // 旧口径（已废弃）：缺必填 ⇒ 整条不可用 + 进台账 + UI 角标。
  // 新口径：订阅原文是内核配置的基底（`ProfileConfigMerger` 把 `proxies` 整段搬到
  // 运行配置），节点在不在、能不能用**由内核解析决定**；App 侧的第二意见必然与
  // 内核分叉（2026-10-22 真机实证：同一 server:port 上两条不同节点，地址键串台
  // ⇒ 一条内核完全可用的节点被误标「定义不完整」并踢出列表）。
  YamlMerger.resetSkipStats();
  const brokenMerged = YamlMerger.merge([brokenYaml], 'fidelity-broken', '');
  const brokenPlan = YamlNodeAdapter.plan(brokenMerged, brokenYaml);
  ok(brokenPlan.entries.length === brokenMerged.length,
    `合并产出的每条节点都留在展示视图里（${brokenMerged.length} 条，实际 ${brokenPlan.entries.length}）`);
  ok(brokenPlan.entries.some((e) => e.merged.name === 'Y-BAD-REALITY-NO-PBK'),
    'Y-BAD-REALITY-NO-PBK（reality 缺 public-key）⇒ 仍在展示视图里（App 不判死刑）');
  for (const entry of brokenPlan.entries) {
    ok(entry.excluded === undefined, `YAML ${entry.merged.name} → 没有"不可用"判词字段`);
    ok(entry.reason === undefined, `YAML ${entry.merged.name} → 没有"定义不完整"原因文本`);
  }
  // 合并阶段就没产出的条目（缺 uuid / 缺 password）只进**诊断账**：
  // 它们在内核那边照样按原文解析 —— App 读不出来 ≠ 节点有问题。
  ok(brokenPlan.dropped.length === 3,
    `YAML 缺凭据的 3 条被记为"App 未解析"（诊断用，实际 ${brokenPlan.dropped.length}）`,
    JSON.stringify(brokenPlan.dropped.map((d) => d.name)));
  for (const item of brokenPlan.dropped) {
    ok(String(item.reason).indexOf('App 未能解析') >= 0,
      `YAML ${item.name} → 诊断原因写明"App 未能解析"（不是对节点下结论）`, item.reason);
    ok(String(item.reason).indexOf('定义不完整') < 0,
      `YAML ${item.name} → 原因里不得再出现"定义不完整"判词`, item.reason);
  }
  // 台账：YAML 路径不再写「定义不完整」——判词只可能来自内核。
  UnusableLedger.clear();
  ok(UnusableLedger.excludedList().length === 0,
    'YAML 路径不产生「定义不完整」台账（App 不再对节点下结论）');

  // ── H2. 域名无法解析 ≠ 不可用（解析结论，不是定义问题）──
  const okAvail = NodeUsability.assess('vless', new Map([
    ['server', 'a.example.test'], ['port', '443'], ['uuid', 'u-1'],
  ]), 'a.example.test', '正常节点名');
  ok(okAvail.usable(), '定义完整的节点默认可用');
  const dnsAvail = NodeUsability.withDns(okAvail, 'nxdomain');
  ok(dnsAvail.category === 'dns',
    '域名无法解析 ⇒ 归到独立的 dns 类别（不是 incomplete）', dnsAvail.category);
  ok(dnsAvail.usable() === true,
    '域名无法解析 ⇒ 仍然可用（定义是对的，不许因此踢出代理表）');
  ok(dnsAvail.defined() === true,
    '域名无法解析 ⇒ 定义轴仍判完整');
  ok(dnsAvail.dns === 'nxdomain', '域名无法解析 ⇒ 单独记在 dns 维度', dnsAvail.dns);
  ok(String(dnsAvail.reason).indexOf('域名无法解析') >= 0,
    '域名无法解析 ⇒ 原因单独表述', dnsAvail.reason);
  ok(String(dnsAvail.reason).indexOf('定义不完整') < 0,
    '域名无法解析 ⇒ 不得混进"定义不完整"');
  ok(String(dnsAvail.detail).indexOf('不是 TunBox 的问题') >= 0,
    '域名无法解析 ⇒ 文案点明不是本端的问题', dnsAvail.detail);
  ok(UnusableLedger.excludedList().length === 0,
    'DNS 结论不进不可用台账（YAML 路径也不再写台账）');
  ok(UnusableLedger.dnsList().length === 0, 'DNS 结论不混进不可用台账');

  // ── K. 订阅信息条目：机场把「剩余流量/到期/群链接」写成了节点（2026-10-20 真机）──
  //
  // 【2026-10-22 · FlClash 同构】App 不再把这类条目"跳过"或"判为非节点"：
  // 它们是订阅原文 `proxies` 里的条目，内核照常解析成节点（FlClash 里同样会
  // 出现在节点列表里）。App 侧只保证**不改写、不丢弃**（名字原样保留）。
  const infoPath = path.join(yamlFixtureDir, 'clash-info-entries.yaml');
  if (!fs.existsSync(infoPath)) {
    ok(false, 'YAML 样本存在（clash-info-entries.yaml）');
  } else {
    const infoYaml = fs.readFileSync(infoPath, 'utf8');
    YamlMerger.resetSkipStats();
    const infoMerged = YamlMerger.merge([infoYaml], 'fidelity-info', '');
    const infoPlan = YamlNodeAdapter.plan(infoMerged, infoYaml);
    const INFO_NAMES = [
      '剩余流量：596.22 GB',
      '套餐到期：长期有效 (2)',
      '有超过20多个节点，不够请到官网使用文档',
      '每次使用前更新订阅到最新',
      '电报群https://t.me/feiniaoyunjichang',
      '防失联页https://github.com/feiniaoyun',
    ];
    for (const infoName of INFO_NAMES) {
      const found = infoPlan.entries.find((e) => e.merged.name === infoName);
      ok(found !== undefined,
        `信息条目「${infoName}」⇒ 仍在展示视图里（名字原样、不丢）`);
      if (found === undefined) continue;
      ok(found.excluded === undefined,
        `信息条目「${infoName}」⇒ 没有"非节点/不可用"判词字段（App 不下结论）`);
    }
    // 真节点同样原样保留（判词消失后不存在"误杀"这一说，但仍要防止丢节点）
    ok(infoPlan.entries.some((e) => e.merged.name === 'Y-HK-01'),
      '正常节点（Y-HK-01）⇒ 仍在展示视图里');
  }

  // ── I. base64 包着的 Clash YAML 必须走 YAML 分支（不再掉进 URI 分支）──
  const b64 = Buffer.from(validYaml, 'utf8').toString('base64');
  const dispatch = BodyDispatch.classify(b64);
  ok(dispatch.kind === BodyKind.YAML,
    'base64 包着的 Clash YAML ⇒ 判定为 YAML 分支（不再掉进 URI 分支）', dispatch.kind);
  ok(dispatch.decoded === true, 'base64 包着的 Clash YAML ⇒ 已解码');
  ok(YamlMerger.proxyItemGroups(dispatch.body).length === YAML_VALID_EXPECT.length,
    'base64 包着的 Clash YAML ⇒ 解码后仍是 5 个 proxies 条目',
    String(YamlMerger.proxyItemGroups(dispatch.body).length));
  // 旧口径（只看明文）确实认不出来 —— 证明这个缺陷真实存在过
  const oldProbe = YamlMerger.proxyItemGroups(b64).length;
  ok(oldProbe === 0,
    '旧口径（明文探测）对 base64 YAML 认不出 proxies（缺陷确实存在）', String(oldProbe));
  ok(BodyDispatch.classify(validYaml).kind === BodyKind.YAML, '明文 Clash YAML ⇒ YAML 分支');
  ok(BodyDispatch.classify('vless://11111111-1111-4111-8111-111111111111@example.com:443#x').kind
    === BodyKind.URI, '分享链接 ⇒ URI 分支');

  // ── J. vless 的 sni（REALITY 的 servername）不许丢 ──
  const vlessSpec = mods.table.ProtocolParamTableRegistry.specOf('vless', 'sni');
  ok(vlessSpec !== null, '参数表里 vless 有 sni 声明（REALITY 的 servername 不能丢）');
  if (vlessSpec !== null) {
    ok(vlessSpec.mihomoField === 'servername',
      'vless 的 sni 落在 mihomo 的 servername 键', vlessSpec.mihomoField);
  }
}

/** ── 负对照：故意改坏样本，闸门必须红 ──────────────────────────────────── */

function makeBrokenFixtureCopy() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tunbox-sub-parse-broken-'));
  for (const file of fs.readdirSync(fixtureDir)) {
    if (!file.endsWith('.txt')) continue;
    fs.copyFileSync(path.join(fixtureDir, file), path.join(tmp, file));
  }
  const vlessPath = path.join(tmp, 'vless-reality.txt');
  const text = fs.readFileSync(vlessPath, 'utf8');
  const lines = text.split(/\r?\n/);
  let changed = 0;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.startsWith('vless://')) continue;
    if (changed === 0) {
      // 破坏 1：删掉一条样本的 UUID（缺必填 ⇒ 必须整条不可用，而不是半条节点）
      lines[i] = line.replace(/vless:\/\/[^@]+@/, 'vless://@');
      changed += 1;
    }
  }
  fs.writeFileSync(vlessPath, lines.join('\n'), 'utf8');
  return { dir: tmp, changed };
}

/** ── 主流程 ──────────────────────────────────────────────────────────────── */

async function main() {
  const selfTest = process.argv.includes('--self-test');
  let mods;
  try {
    mods = await loadModules();
  } catch (err) {
    // Node 的 type-stripping 不吃某些语法（enum 等）⇒ 用 transform 模式重启一次
    if (process.env.SUBPARSE_RETRY === '1') {
      console.error('加载 .ets 失败：', err && err.message);
      process.exit(1);
    }
    const res = spawnSync(process.execPath, ['--experimental-transform-types', fileURLToPath(import.meta.url),
      ...process.argv.slice(2)], {
      env: { ...process.env, SUBPARSE_RETRY: '1' },
      stdio: 'inherit',
    });
    process.exit(res.status === null ? 1 : res.status);
  }

  console.log('── 订阅解析保真闸门 ──');
  const result = runChecks(fixtureDir, mods, { verbose: false });
  console.log(`  样本：${result.caseCount} 条 URI`);
  console.log(`  断言：${result.passed} passed, ${result.failed} failed`);
  if (result.failed > 0) {
    console.log('');
    for (const line of result.lines) console.log(line);
  }

  let selfTestOk = true;
  if (selfTest) {
    console.log('');
    console.log('── 负对照（故意改坏样本，闸门必须 FAILED）──');
    const broken = makeBrokenFixtureCopy();
    const brokenResult = runChecks(broken.dir, mods, { verbose: false });
    console.log(`  改坏 ${broken.changed} 处（删掉一条样本的 UUID → 缺必填必须整条不可用）`);
    console.log(`  闸门对改坏样本的判决：${brokenResult.passed} passed, ${brokenResult.failed} failed`);
    if (brokenResult.failed <= 0) {
      console.log('  ❌ 负对照失败：闸门对被改坏的样本没有报错 —— 这道闸门咬不住东西，等于没有');
      selfTestOk = false;
    } else {
      console.log('  ✅ 负对照通过：改坏样本被闸门抓住');
      for (const line of brokenResult.lines.slice(0, 6)) console.log(`     ${line}`);
    }
    fs.rmSync(broken.dir, { recursive: true, force: true });

    // 负对照之二：**改坏解析器**。这才是真事故的形态 ——
    // 「参数在解析层被丢掉 / 改名 / 截断」，而样本本身没变。
    // 闸门必须每一种都抓住，否则它证明不了"保真"。
    const parserMutations = [
      {
        name: '解析器丢掉 REALITY 公钥（pbk 不落 params）',
        apply: (text) => text.replace(
          "      if (!params.has(canonical)) {\n        params.set(canonical, value);\n      }",
          "      if (canonical === 'reality-public-key') { continue; }\n"
          + "      if (!params.has(canonical)) {\n        params.set(canonical, value);\n      }"),
      },
      {
        name: '解析器把参数改名（reality-public-key → reality-pbk）',
        apply: (text) => text.replace(
          "      if (!params.has(canonical)) {\n        params.set(canonical, value);\n      }",
          "      if (!params.has(canonical)) {\n"
          + "        params.set(canonical === 'reality-public-key' ? 'reality-pbk' : canonical, value);\n"
          + "      }"),
      },
      {
        name: '解析器截断参数值（只留前 8 个字符）',
        apply: (text) => text.replace(
          "      const value = raw.get(key) ?? '';",
          "      const value = (raw.get(key) ?? '').substring(0, 8);"),
      },
    ];
    for (const mutation of parserMutations) {
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tunbox-sub-parse-mut-'));
      copySources(dir);
      const parserPath = path.join(dir, 'UriNodeParser.ets');
      const before = fs.readFileSync(parserPath, 'utf8');
      const after = mutation.apply(before);
      if (after === before) {
        console.log(`  ❌ 负对照「${mutation.name}」无法注入（源码形态变了，需更新本脚本）`);
        selfTestOk = false;
        fs.rmSync(dir, { recursive: true, force: true });
        continue;
      }
      fs.writeFileSync(parserPath, after, 'utf8');
      const mutatedMods = await loadModules(dir);
      const mutatedResult = runChecks(fixtureDir, mutatedMods, { verbose: false });
      console.log(`  · ${mutation.name} → 闸门判决 ${mutatedResult.passed} passed, ${mutatedResult.failed} failed`);
      if (mutatedResult.failed <= 0) {
        console.log('    ❌ 负对照失败：闸门没抓住这一次改坏 —— 保真没被证明');
        selfTestOk = false;
      } else {
        console.log('    ✅ 被抓住');
        for (const line of mutatedResult.lines.slice(0, 2)) console.log(`       ${line}`);
      }
      fs.rmSync(dir, { recursive: true, force: true });
    }

    // 负对照之三：**改坏 YAML 路径 / 不可用口径 / base64 分派**。
    // 这几处正是本次接入链路的要害：
    // 「YAML 路径与分享链接路径同一套口径」「缺必填整条不可用」「base64 包的 YAML 不掉进 URI 分支」。
    const pathMutations = [
      {
        name: 'YAML 路径重新开始"判死刑"（App 把节点踢出展示视图）',
        file: 'YamlNodeAdapter.ets',
        apply: (text) => text.replace(
          '      out.entries.push(entry);',
          "      if (m.name.indexOf('REALITY') < 0) { out.entries.push(entry); }"),
      },
      {
        name: '不可用口径把"DNS 结论"也算成不可用（DNS 节点被踢出代理表）',
        file: 'NodeUsability.ets',
        apply: (text) => text.replace(
          '  usable(): boolean {\n'
          + '    return this.category === UnusableCategory.OK || this.category === UnusableCategory.DNS;\n'
          + '  }',
          '  usable(): boolean {\n'
          + '    return this.category === UnusableCategory.OK;\n'
          + '  }'),
      },
      {
        name: 'base64 分派退回旧口径（base64 包的 Clash YAML 掉进 URI 分支）',
        file: 'BodyDispatch.ets',
        apply: (text) => text.replace(
          '    const decoded = UriNodeParser.base64Decode(compact);',
          '    const decoded = \'\';'),
      },
      {
        name: '参数表删掉 vless 的 sni 声明（REALITY 的 servername 丢）',
        file: 'ProtocolParamTable.ets',
        apply: (text) => text.replace(
          "t.specs.push(ProtocolParamTableRegistry.p('sni', 'servername', ['sni', 'peer'], '', 'query', 'any', '',",
          "t.specs.push(ProtocolParamTableRegistry.p('sni-unused', 'servername', ['sni', 'peer'], '', 'query', 'any', '',"),
      },
    ];
    for (const mutation of pathMutations) {
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'tunbox-sub-parse-mut2-'));
      copySources(dir);
      const targetPath = path.join(dir, mutation.file);
      const before = fs.readFileSync(targetPath, 'utf8');
      const after = mutation.apply(before);
      if (after === before) {
        console.log(`  ❌ 负对照「${mutation.name}」无法注入（源码形态变了，需更新本脚本）`);
        selfTestOk = false;
        fs.rmSync(dir, { recursive: true, force: true });
        continue;
      }
      fs.writeFileSync(targetPath, after, 'utf8');
      const mutatedMods = await loadModules(dir);
      const mutatedResult = runChecks(fixtureDir, mutatedMods, { verbose: false });
      console.log(`  · ${mutation.name} → 闸门判决 ${mutatedResult.passed} passed, ${mutatedResult.failed} failed`);
      if (mutatedResult.failed <= 0) {
        console.log('    ❌ 负对照失败：闸门没抓住这一次改坏 —— 新口径没被证明');
        selfTestOk = false;
      } else {
        console.log('    ✅ 被抓住');
        for (const line of mutatedResult.lines.slice(0, 2)) console.log(`       ${line}`);
      }
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }

  console.log('');
  const totalFailed = result.failed + (selfTestOk ? 0 : 1);
  console.log(`RESULT: ${result.passed} passed, ${totalFailed} failed`);
  process.exit(totalFailed === 0 ? 0 : 1);
}

main();
