#!/usr/bin/env node
/**
 * 测速内核 v2 闸门（LatencyProbe / LatencyStore）
 *
 * ## 为什么要有这道闸门
 *
 * 审计点 F2/F4/F12/F13 的共同根因是「同一个语义散在多处、各算各的」：
 *  - **URL 派生**散在 4 处（前台批 / 后台批 / smart 组 / 内核健康检查）→ 口径不一致；
 *  - **失败分类**散在多处 → 「内核没就绪」被写成「节点失败」→ 整片变红；
 *  - **落盘**是整单覆盖 → 与自动切换记账互相覆盖；
 *  - **渲染**有三套（live / 落盘 / 恢复）→ 同一个 failKind 不同页面显示不一样。
 *
 * 这道闸门跑**真代码**（把真实 .ets 暂存成 .ts 后 import），不是读源码断言。
 *
 * ## 覆盖的断言（每条都有负对照）
 *
 *  A 单 URL 单一真源（11 条 + 跨文件收口 3 条）
 *  B 一次请求语义（unified-delay 必须 false + 探针只发一次）
 *  C 失败分类表完备 + 非判定失败不落结论
 *  D 落盘字段级（不整单覆盖）
 *  E restore 不覆盖更新的结论
 *  F 三套渲染合成一张表
 *  G 并发/超时/取消参数集中在常量区
 *  H DNS 预检（2026-10-20 真机根因：域名解析失败 ≠ 网络不可达）+ 组级聚合
 *
 * ## 跑法
 *
 *   node scripts/verify-latency-core-v2.mjs
 *   node scripts/verify-latency-core-v2.mjs --arkts   # 额外跑 ArkTS 真编译（新包桥接）
 *
 * `--arkts` 的做法：新包还没被任何入口 import（接线是 UI/引擎侧的事），
 * 所以仓库的 verify-arkts-compile.mjs **看不见**它。该模式会在
 * `entryability/EntryAbility.ets` 里临时插一行带标记的 import，跑完真编译后
 * **精确删掉那一行**（不整文件还原，避免覆盖别人的并发改动）。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const here = path.dirname(fileURLToPath(import.meta.url));
const appRoot = path.join(here, '..');
const latencyDir = path.join(appRoot, 'entry/src/main/ets/commons/latency');
const servicesDir = path.join(appRoot, 'entry/src/main/ets/commons/services');
const pagesDir = path.join(appRoot, 'entry/src/main/ets/pages');
const modelsDir = path.join(appRoot, 'entry/src/main/ets/commons/models');

let passed = 0;
let failed = 0;
const failures = [];
function check(name, fn) {
  try {
    fn();
    passed++;
    console.log(`PASS ${name}`);
  } catch (e) {
    failed++;
    failures.push(`${name} :: ${e.message}`);
    console.log(`FAIL ${name} :: ${e.message}`);
  }
}
async function checkAsync(name, fn) {
  try {
    await fn();
    passed++;
    console.log(`PASS ${name}`);
  } catch (e) {
    failed++;
    failures.push(`${name} :: ${e.message}`);
    console.log(`FAIL ${name} :: ${e.message}`);
  }
}
function eq(a, b, label) {
  if (a !== b) {
    throw new Error(`${label}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
  }
}
function ok(c, label) {
  if (!c) throw new Error(label);
}

/** 去掉注释（只留代码）—— 源码类断言必须看代码，不能被文档里的字样误导 */
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/^\s*\/\/.*$/gm, '');
}

// ── 暂存真实实现 ───────────────────────────────────────────────────────────
const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'latency-v2-'));
const w = (n, s) => fs.writeFileSync(path.join(stage, n), s, 'utf8');

function stageEts(fileName) {
  const src = fs.readFileSync(path.join(latencyDir, fileName), 'utf8');
  return src
    .replace(/from '@kit\.NetworkKit'/g, "from './fakeNetworkKit.ts'")
    .replace(/from '@kit\.ArkTS'/g, "from './fakeArkTS.ts'")
    .replace(/from '@kit\.ArkData'/g, "from './fakeArkData.ts'")
    .replace(/from '\.\.\/utils\/AppLogger'/g, "from './AppLogger.ts'")
    .replace(/from '\.\.\/models\/AppSettings'/g, "from './AppSettings.ts'")
    .replace(/from '\.\/LatencyProbe'/g, "from './LatencyProbe.ts'")
    .replace(/from '\.\/LatencyTestUrl'/g, "from './LatencyTestUrl.ts'")
    .replace(/from '\.\/LatencyDnsVerdict'/g, "from './LatencyDnsVerdict.ts'")
    .replace(/from '\.\/LatencyKinds'/g, "from './LatencyKinds.ts'");
}

w('LatencyTestUrl.ts', stageEts('LatencyTestUrl.ets'));
w('LatencyKinds.ts', stageEts('LatencyKinds.ets'));
w('LatencyDnsVerdict.ts', stageEts('LatencyDnsVerdict.ets'));
w('LatencyProbe.ts', stageEts('LatencyProbe.ets'));
w('LatencyStore.ts', stageEts('LatencyStore.ets'));

// 桩：AppLogger（**记录日志**：要断言「完整失败体进日志」）
w('AppLogger.ts', `
export const LOGS: Array<{ tag: string, msg: string, level: string }> = [];
export class AppLogger {
  static info(tag: string, msg: string): void { LOGS.push({ tag, msg, level: 'info' }); }
  static warn(tag: string, msg: string): void { LOGS.push({ tag, msg, level: 'warn' }); }
  static error(tag: string, msg: string): void { LOGS.push({ tag, msg, level: 'error' }); }
  static errText(e: Object): string {
    if (e === null || e === undefined) return String(e);
    return (e as Error).message ? (e as Error).message : String(e);
  }
}
`);

// 桩：AppSettings（只有测速 URL 字段）
w('AppSettings.ts', `
export class AppSettings {
  testLatencyUrl: string = 'https://www.gstatic.com/generate_204';
}
`);

// 桩：@kit.NetworkKit
w('fakeNetworkKit.ts', `
export const http = {
  RequestMethod: { GET: 0, POST: 1 },
  createHttp(): Object { return { request: async (): Promise<Object> => ({}), destroy: (): void => {} }; }
};
`);

// 桩：@kit.ArkTS
w('fakeArkTS.ts', `
export const util = {
  TextDecoder: {
    create(_enc: string): Object {
      return { decodeToString: (a: Uint8Array): string => Buffer.from(a).toString('utf8') };
    }
  }
};
`);

// 桩：@kit.ArkData
w('fakeArkData.ts', `
export const preferences = {
  getPreferences: async (_ctx: Object, _name: string): Promise<Object> => ({
    get: async (_k: string, d: Object): Promise<Object> => d,
    put: async (_k: string, _v: Object): Promise<void> => {},
    flush: async (): Promise<void> => {},
    getAll: async (): Promise<Object> => ({})
  })
};
`);

const modProbe = await import(pathToFileURL(path.join(stage, 'LatencyProbe.ts')).href);
const modStore = await import(pathToFileURL(path.join(stage, 'LatencyStore.ts')).href);
const modUrl = await import(pathToFileURL(path.join(stage, 'LatencyTestUrl.ts')).href);
const modLogger = await import(pathToFileURL(path.join(stage, 'AppLogger.ts')).href);

const {
  LatencyProbe, LatencyProbeKind, LatencyProbeLimits, effectiveTestUrl
} = modProbe;
const {
  LatencyStore, LatencyStoreField, LatencyVerdict, LatencyVerdictView, LatencyViewLevel,
  MemoryLatencyPersistence, PreferencesLatencyPersistence, LatencyPersistence
} = modStore;
// 规则真源住在零 import 的 LatencyTestUrl.ets；LatencyProbe 只是转出
const { LatencyTestUrl } = modUrl;

// ── 测试工具 ───────────────────────────────────────────────────────────────
class FakeTransport {
  constructor(reply, error) {
    this.reply = reply;
    this.error = error;
    this.calls = [];
  }
  async get(url, headers, timeoutMs) {
    this.calls.push({ url, headers, timeoutMs });
    if (this.error) throw this.error;
    return this.reply;
  }
}
function endpoint() {
  const ep = new modProbe.LatencyKernelEndpoint();
  ep.baseUrl = 'http://127.0.0.1:9090';
  ep.secret = 'sec';
  return ep;
}
function settingsWith(url) {
  const s = new modStore.LatencyVerdict(); // 占位，避免用到未导入的类型
  void s;
  const st = { testLatencyUrl: url };
  return st;
}

console.log('── A. 单 URL 单一真源 ──');

check('A1 空 URL → 默认 https gstatic', () => {
  eq(LatencyTestUrl.effective(''), 'https://www.gstatic.com/generate_204', '空串');
});
check('A2 空白 URL → 默认 https gstatic', () => {
  eq(LatencyTestUrl.effective('   '), 'https://www.gstatic.com/generate_204', '空白');
});
check('A3 历史默认值 http gstatic → 升级为 https', () => {
  eq(LatencyTestUrl.effective('http://www.gstatic.com/generate_204'),
    'https://www.gstatic.com/generate_204', '历史 http');
});
check('A4 历史默认值 http cloudflare → 升级为 https', () => {
  eq(LatencyTestUrl.effective('http://cp.cloudflare.com/generate_204'),
    'https://cp.cloudflare.com/generate_204', '历史 http');
});
check('A5 负对照：用户自填的其它 http **原样保留**（不得升级）', () => {
  eq(LatencyTestUrl.effective('http://example.com/generate_204'),
    'http://example.com/generate_204', '用户 http');
});
check('A6 用户自填 https（带路径/端口/参数）原样保留', () => {
  eq(LatencyTestUrl.effective('https://probe.example.com:8443/gen?x=1'),
    'https://probe.example.com:8443/gen?x=1', '用户 https');
});
check('A7 非法 URL（无协议头）→ 默认', () => {
  eq(LatencyTestUrl.effective('gstatic.com/generate_204'),
    'https://www.gstatic.com/generate_204', '非法值');
});
check('A8 负对照：绝不把 https 降级成 http', () => {
  eq(LatencyTestUrl.effective('https://www.gstatic.com/generate_204'),
    'https://www.gstatic.com/generate_204', 'https 保持');
});
check('A9 超长 URL（>2048）→ 默认', () => {
  const long = 'https://a.example.com/' + 'x'.repeat(2100);
  eq(LatencyTestUrl.effective(long), 'https://www.gstatic.com/generate_204', '超长');
});
check('A10 两个入口同源：effectiveTestUrl(settings) === LatencyTestUrl.effective(raw)', () => {
  eq(effectiveTestUrl(settingsWith('http://example.com/x')), LatencyTestUrl.effective('http://example.com/x'),
    '入口一致');
});
check('A11 单一真源：延迟包内只有 LatencyTestUrl.ets 允许出现默认 URL 字面量', () => {
  for (const f of fs.readdirSync(latencyDir)) {
    if (!f.endsWith('.ets')) continue;
    if (f === 'LatencyTestUrl.ets') continue;
    const src = fs.readFileSync(path.join(latencyDir, f), 'utf8');
    ok(src.indexOf('gstatic.com/generate_204') < 0, `${f} 里出现了默认 URL 字面量（真源只能有一个）`);
  }
  const urlSrc = fs.readFileSync(path.join(latencyDir, 'LatencyTestUrl.ets'), 'utf8');
  const hits = urlSrc.split('gstatic.com/generate_204').length - 1;
  ok(hits >= 2 && hits <= 4, `LatencyTestUrl.ets 里默认 URL 字面量出现 ${hits} 次（应集中在常量区）`);
});
check('A11b LatencyProbe 转出同一个 LatencyTestUrl（没有第二份规则）', () => {
  eq(modProbe.LatencyTestUrl, LatencyTestUrl, 'LatencyProbe.LatencyTestUrl 应是同一个类');
});

// 「独立实现」的判定：函数体里同时出现「合法性正则」与「默认地址兜底」
function findIndependentRuleImplementations() {
  const roots = [path.join(appRoot, 'entry/src/main/ets/services'), path.join(appRoot, 'entry/src/main/ets/pages'),
    path.join(appRoot, 'entry/src/main/ets/commons')];
  const allow = new Set(['AppSettings.ets::upgradeLegacyTestUrl']);
  const hits = [];
  for (const root of roots) {
    if (!fs.existsSync(root)) continue;
    const walk = (dir) => {
      for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) {
          if (e.name === 'latency') continue; // 真源自己
          walk(p);
          continue;
        }
        if (!e.name.endsWith('.ets')) continue;
        const src = fs.readFileSync(p, 'utf8');
        const lines = src.split('\n');
        for (let i = 0; i < lines.length; i++) {
          if (lines[i].indexOf('^https?:\\/\\/') < 0) continue;
          // 找所属函数名（往上找最近的函数签名）
          let fn = '?';
          for (let j = i; j >= 0 && j > i - 40; j--) {
            const m = lines[j].match(/^\s*(?:export\s+)?(?:static\s+|private\s+|public\s+|async\s+)*([A-Za-z_][A-Za-z0-9_]*)\s*\(/);
            if (m && m[1] !== 'if' && m[1] !== 'for' && m[1] !== 'while') { fn = m[1]; break; }
          }
          // 找默认地址兜底（同函数附近 20 行内）
          const near = lines.slice(Math.max(0, i - 20), Math.min(lines.length, i + 20)).join('\n');
          const hasDefault = near.indexOf('DEFAULT_TEST_URL') >= 0 || near.indexOf('gstatic.com/generate_204') >= 0;
          if (!hasDefault) continue;
          const key = `${e.name}::${fn}`;
          if (allow.has(key)) continue;
          hits.push({ file: p, line: i + 1, fn, key });
        }
      }
    };
    walk(root);
  }
  return hits;
}

check('A12a 探测期 URL 规则只有一处实现（真源在 latency/LatencyTestUrl.ets）', () => {
  const hits = findIndependentRuleImplementations();
  ok(hits.length === 0, hits.map((h) => `${path.basename(h.file)}:${h.line} ${h.fn}() 自带一份规则`).join(' | ')
    + ' —— 改成 import { LatencyTestUrl } from \'../latency/LatencyTestUrl\' 并 return LatencyTestUrl.effective(...)');
});
check('A12b 调用点收口：前台批/后台批 不再自带规则', () => {
  const sites = [
    { file: path.join(pagesDir, 'NodeSelectionPage.ets'), marker: 'testUrlForLatency' },
    { file: path.join(servicesDir, 'BackgroundLatencyService.ets'), marker: 'resolveTestUrl' }
  ];
  const bad = [];
  for (const item of sites) {
    if (!fs.existsSync(item.file)) continue;
    const src = fs.readFileSync(item.file, 'utf8');
    const idx = src.indexOf(item.marker);
    if (idx < 0) continue;
    const line = src.substring(0, idx).split('\n').length;
    const body = src.substring(idx, idx + 400);
    if (body.indexOf('^https?:\\/\\/') >= 0 || body.indexOf('DEFAULT_TEST_URL') >= 0
      || body.indexOf('gstatic.com/generate_204') >= 0) {
      bad.push(`${path.basename(item.file)}:${line} ${item.marker}() 自带规则`);
    }
  }
  ok(bad.length === 0, bad.join(' | '));
});
check('A12c smart 组 / 内核健康检查不再自带规则（config-gen 范围）', () => {
  const file = path.join(servicesDir, 'ClashConfigGenerator.ets');
  if (!fs.existsSync(file)) return;
  const src = fs.readFileSync(file, 'utf8');
  const bad = [];
  if (src.indexOf('settings.testLatencyUrl') >= 0) {
    const line = src.substring(0, src.indexOf('settings.testLatencyUrl')).split('\n').length;
    bad.push(`ClashConfigGenerator.ets:${line} 直接读 settings.testLatencyUrl`);
  }
  const idx = src.indexOf('safeGroupUrl');
  if (idx >= 0) {
    const body = src.substring(idx, idx + 600);
    if (body.indexOf('^https?:\\/\\/') >= 0 || body.indexOf('gstatic.com/generate_204') >= 0) {
      const line = src.substring(0, idx).split('\n').length;
      bad.push(`ClashConfigGenerator.ets:${line} safeGroupUrl() 自带规则`);
    }
  }
  ok(bad.length === 0, bad.join(' | ')
    + ' —— 改成 import { LatencyTestUrl } from \'../latency/LatencyTestUrl\' 并调用 LatencyTestUrl.effective(...)');
});

console.log('── B. 一次请求语义 ──');

await checkAsync('B1 一次探测只发一个 HTTP 请求', async () => {
  const t = new FakeTransport({ responseCode: 200, body: '{"delay":123}' });
  const r = await LatencyProbe.probeOne('n1', 'https://x.example.com/g', endpoint(), t);
  eq(t.calls.length, 1, '请求次数');
  eq(r.delayMs, 123, '延迟');
  eq(r.failKind, LatencyProbeKind.NONE, '分类');
});
await checkAsync('B2 负对照：失败也不重发（请求数仍为 1）', async () => {
  const t = new FakeTransport(null, new Error('boom'));
  const r = await LatencyProbe.probeOne('n2', 'https://x.example.com/g', endpoint(), t);
  eq(t.calls.length, 1, '请求次数');
  eq(r.failKind, LatencyProbeKind.CORE_NOT_READY, '传输层异常 → core_not_ready');
  eq(r.isVerdict, false, '传输层异常不是节点结论');
});
await checkAsync('B3 请求 URL 形状与内核路由一致（/proxies/{name}/delay）', async () => {
  const t = new FakeTransport({ responseCode: 200, body: '{"delay":10}' });
  await LatencyProbe.probeOne('香港 01', 'https://x.example.com/g', endpoint(), t);
  const u = t.calls[0].url;
  ok(u.indexOf('/proxies/') > 0, `URL 形状: ${u}`);
  ok(u.indexOf('%E9%A6%99%E6%B8%AF') > 0, `节点名未做 URL 编码: ${u}`);
  ok(u.indexOf('url=https%3A%2F%2Fx.example.com%2Fg') > 0, `url 参数未编码: ${u}`);
  ok(u.indexOf('timeout=3000') > 0, `timeout 参数不是内核预算: ${u}`);
});
await checkAsync('B4 外层超时 = 内核预算 + 余量（排队等待不计入节点预算）', async () => {
  const t = new FakeTransport({ responseCode: 200, body: '{"delay":10}' });
  await LatencyProbe.probeOne('n3', 'https://x.example.com/g', endpoint(), t);
  eq(t.calls[0].timeoutMs, LatencyProbeLimits.NODE_TIMEOUT_MS + LatencyProbeLimits.OUTER_EXTRA_MS,
    '外层超时');
  eq(t.calls[0].timeoutMs, 4200, '外层超时数值');
});
check('B5 源码断言：probeOne 里只有一次 transport.get（探针不重试）', () => {
  const src = fs.readFileSync(path.join(latencyDir, 'LatencyProbe.ets'), 'utf8');
  const start = src.indexOf('static async probeOne');
  ok(start > 0, '找不到 probeOne');
  const body = src.substring(start, src.indexOf('\n  }\n', start));
  const hits = body.split('transport.get(').length - 1;
  eq(hits, 1, `probeOne 里的 transport.get 调用次数（${hits}）`);
});
check('B6 统一延迟口径（配置侧）：生成配置开启 unified-delay（报第二次 HEAD 的耗时 = 真实 RTT）', () => {
  const src = fs.readFileSync(path.join(servicesDir, 'ClashConfigGenerator.ets'), 'utf8');
  ok(src.indexOf("'unified-delay: true'") >= 0, '生成配置里找不到 unified-delay: true（unified=false 会把 TLS 握手算进延迟，每次凭空多 1~2 个 RTT）');
  ok(src.indexOf("'unified-delay: false'") < 0, '生成配置里仍有 unified-delay: false');
});

console.log('── C. 失败分类表完备 + 非判定失败不落结论 ──');

const cases = [
  { name: '200 + 合法 delay → 成功（判定）', code: 200, body: '{"delay":87}', kind: '', verdict: true, delay: 87 },
  { name: '504 → timeout（判定）', code: 504, body: '{"message":"timeout"}', kind: 'timeout', verdict: true },
  { name: '503 + dial 错误 → network_unreachable（判定）', code: 503,
    body: '{"message":"dial tcp 1.2.3.4:443: i/o timeout"}', kind: 'network_unreachable', verdict: true },
  { name: '503 + mihomo 通用文案 → network_unreachable（判定）', code: 503,
    body: '{"message":"An error occurred in the delay test"}', kind: 'network_unreachable', verdict: true },
  { name: '负对照：503 + 无法识别的体 → unknown（非判定）', code: 503,
    body: '{"message":"something else entirely"}', kind: 'unknown', verdict: false },
  { name: '401 → core_not_ready（非判定）', code: 401, body: '{"message":"unauthorized"}',
    kind: 'core_not_ready', verdict: false },
  { name: '403 → core_not_ready（非判定）', code: 403, body: '{"message":"forbidden"}',
    kind: 'core_not_ready', verdict: false },
  { name: '404 → switch_failed（配置类判定）', code: 404, body: '{"message":"proxy not found"}',
    kind: 'switch_failed', verdict: true },
  { name: '200 + 非法 delay → unknown（非判定）', code: 200, body: '{"delay":0}',
    kind: 'unknown', verdict: false },
  { name: '200 + 非 JSON → unknown（非判定）', code: 200, body: 'not-json',
    kind: 'unknown', verdict: false }
];
for (const c of cases) {
  check(`C ${c.name}`, () => {
    const cls = LatencyProbe.classify(c.code, c.body, '');
    eq(cls.kind, c.kind, '分类');
    eq(cls.isVerdict, c.verdict, '是否节点结论');
    if (c.delay !== undefined) {
      eq(LatencyProbe.parseDelay(c.body), c.delay, 'delay');
    }
  });
}
check('C 传输层异常 → core_not_ready（非判定）', () => {
  const cls = LatencyProbe.classify(0, '', 'connect refused');
  eq(cls.kind, 'core_not_ready', '分类');
  eq(cls.isVerdict, false, '是否节点结论');
});
check('C 分类表完备：每个 kind 在渲染表里都有对应条目', () => {
  const kinds = ['timeout', 'switch_failed', 'core_not_ready', 'network_unreachable', 'unknown',
    'queue_timeout', 'untested', 'cancelled', 'unsupported', 'port_reachable_only',
    'dns_unresolved', ''];
  for (const k of kinds) {
    const view = LatencyStore.describe(k, -1, Date.now(), Date.now());
    ok(view.text.length > 0 || k === '', `kind=${k} 没有渲染文案`);
  }
});
// ── H. DNS 预检（2026-10-20 真机根因：域名解析失败 ≠ 网络不可达）──────────
//
// 真机取证：mitce 34 个节点的服务器域名 de152710bb8b70d108ec13c7.mitce-nocontact.com
// 在阿里/Cloudflare/Google/腾讯**四个解析器全部 NXDOMAIN**（2026-10-19 复现同结论）
// ⇒ 失败发生在**域名解析**这一步。mihomo 的 503 body 是通用句，看不到 DNS 原因
// ⇒ 判定必须来自**我们自己的 DoH 预解析**（当天日志：DoH pinned 0/135）。
check('H1 dns_unresolved 是判定类（是节点结论，不是「我们自己的问题」）', () => {
  eq(LatencyProbeKind.isVerdictKind('dns_unresolved'), true, 'dns_unresolved 应是判定类');
  eq(LatencyProbeKind.DNS_UNRESOLVED, 'dns_unresolved', '常量值');
});
check('H2 DNS 预检失败 ⇒ failKind=dns_unresolved，且绝不是 network_unreachable', () => {
  const dns = new modProbe.LatencyDnsVerdict();
  dns.nodeName = 'nDNS';
  dns.host = 'de152710bb8b70d108ec13c7.mitce-nocontact.com';
  dns.status = modProbe.LatencyDnsStatus.UNRESOLVED;
  dns.detail = 'DoH 预解析未返回地址（NXDOMAIN / 无应答）';
  const cls = LatencyProbe.classify(503, '{"message":"An error occurred in the delay test"}', '', dns);
  eq(cls.kind, 'dns_unresolved', '分类');
  ok(cls.kind !== 'network_unreachable', '不得被写成 network_unreachable');
  eq(cls.isVerdict, true, '应产生节点结论');
  ok(cls.detail.indexOf('de152710bb8b70d108ec13c7.mitce-nocontact.com') >= 0, 'detail 应带上域名');
});
await checkAsync('H3 DNS 预检失败 ⇒ 一次请求都不发（不打扰内核）', async () => {
  const dns = new modProbe.LatencyDnsVerdict();
  dns.host = 'x.mitce-nocontact.com';
  dns.status = modProbe.LatencyDnsStatus.UNRESOLVED;
  const t = new FakeTransport({ responseCode: 503, body: '{"message":"An error occurred in the delay test"}' });
  const r = await LatencyProbe.probeOne('nDNS2', 'https://x.example.com/g', endpoint(), t, 5000, dns);
  eq(t.calls.length, 0, '请求次数（DNS 已判失败就不该再问内核）');
  eq(r.failKind, 'dns_unresolved', '分类');
  eq(r.isVerdict, true, '是否节点结论');
});
await checkAsync('H4 DNS 状态 unknown（没试过解析）⇒ 照常走内核探测', async () => {
  const dns = new modProbe.LatencyDnsVerdict();
  dns.host = 'y.example.com';
  dns.status = modProbe.LatencyDnsStatus.UNKNOWN;
  const t = new FakeTransport({ responseCode: 200, body: '{"delay":66}' });
  const r = await LatencyProbe.probeOne('nDNS3', 'https://x.example.com/g', endpoint(), t, 5000, dns);
  eq(t.calls.length, 1, '请求次数');
  eq(r.failKind, '', '分类');
  eq(r.delayMs, 66, '延迟');
});
check('H5 负对照：DNS resolved + 503 dial 错误 ⇒ 仍是 network_unreachable（不是 dns_unresolved）', () => {
  const dns = new modProbe.LatencyDnsVerdict();
  dns.host = 'z.example.com';
  dns.status = modProbe.LatencyDnsStatus.RESOLVED;
  const cls = LatencyProbe.classify(503, '{"message":"dial tcp 1.2.3.4:443: i/o timeout"}', '', dns);
  eq(cls.kind, 'network_unreachable', '分类');
  ok(cls.kind !== 'dns_unresolved', '解析成功时不得判 dns_unresolved');
});
check('H6 负对照：没有 DNS 结论时，503+dial 仍判 network_unreachable（老口径不被改坏）', () => {
  const cls = LatencyProbe.classify(503, '{"message":"dial tcp 1.2.3.4:443: i/o timeout"}', '');
  eq(cls.kind, 'network_unreachable', '分类');
});
check('H7 fromPins：命中=resolved / 试过没命中=unresolved / 没试过=unknown', () => {
  const pins = { 'ok.example.com': '1.2.3.4' };
  const attempted = ['ok.example.com', 'bad.example.com'];
  const v1 = modProbe.LatencyDnsVerdict.fromPins('n1', 'OK.example.com', pins, attempted);
  eq(v1.status, 'resolved', '命中 pin');
  const v2 = modProbe.LatencyDnsVerdict.fromPins('n2', 'bad.example.com', pins, attempted);
  eq(v2.status, 'unresolved', '试过但没解析出来');
  const v3 = modProbe.LatencyDnsVerdict.fromPins('n3', 'untried.example.com', pins, attempted);
  eq(v3.status, 'unknown', '没试过 ≠ 解析失败');
  const v4 = modProbe.LatencyDnsVerdict.fromPins('n4', '', pins, attempted);
  eq(v4.status, 'unknown', 'IP 直连不需要 DNS');
});
check('H8 文案：dns_unresolved 与「网络不可达」严格区分', () => {
  const dnsView = LatencyStore.describe('dns_unresolved', -1, Date.now(), Date.now());
  eq(dnsView.text, '域名无法解析（节点域名可能已下线）', 'dns_unresolved 文案');
  const netView = LatencyStore.describe('network_unreachable', -1, Date.now(), Date.now());
  ok(dnsView.text !== netView.text, '两者文案必须不同');
  ok(netView.text.indexOf('域名') < 0, 'network_unreachable 不得出现「域名」字样');
  eq(dnsView.level, LatencyViewLevel.BAD, 'dns_unresolved 级别');
});
check('H9 组级聚合：34 个 dns_unresolved ⇒ 一条组级结论', () => {
  LatencyStore.clear();
  const names = [];
  for (let i = 0; i < 34; i++) {
    const n = `mitce-${i}`;
    names.push(n);
    LatencyStore.applyProbeResult(n, -1, 'dns_unresolved', Date.now());
  }
  const summary = LatencyStore.summarize(names);
  eq(summary.total, 34, '总数');
  eq(summary.failedCount, 34, '失败数');
  eq(summary.dominantKind, 'dns_unresolved', '主导分类');
  eq(summary.isUniformFailure, true, '整组同因');
  ok(summary.conclusion.indexOf('34/34') >= 0, `组级结论应带 34/34，实际：${summary.conclusion}`);
  ok(summary.conclusion.indexOf('域名无法解析') >= 0, '组级结论应说明是域名问题');
  const counts = LatencyStore.aggregateByKind(names);
  const dnsCount = counts.find((c) => c.kind === 'dns_unresolved');
  ok(dnsCount !== undefined, 'aggregateByKind 应有 dns_unresolved 桶');
  eq(dnsCount.count, 34, 'dns_unresolved 计数');
  eq(Math.round(dnsCount.ratio * 100), 100, '占比');
});
check('H10 组级聚合：分类分散 ⇒ 不是同因，结论不硬套单一原因', () => {
  LatencyStore.clear();
  const names = ['m1', 'm2', 'm3', 'm4'];
  LatencyStore.applyProbeResult('m1', -1, 'dns_unresolved', Date.now());
  LatencyStore.applyProbeResult('m2', -1, 'dns_unresolved', Date.now());
  LatencyStore.applyProbeResult('m3', -1, 'network_unreachable', Date.now());
  LatencyStore.applyProbeResult('m4', -1, 'timeout', Date.now());
  const summary = LatencyStore.summarize(names);
  eq(summary.failedCount, 4, '失败数');
  eq(summary.dominantKind, 'dns_unresolved', '主导分类（并列按优先级）');
  eq(summary.isUniformFailure, false, '不是同因');
  ok(summary.conclusion.indexOf('分散') >= 0, `结论应说明分类分散，实际：${summary.conclusion}`);
});
check('H11 组级聚合：只读（不改进程内结论、不落盘）', () => {
  LatencyStore.clear();
  const backend = new MemoryLatencyPersistence();
  LatencyStore.setBackend(backend);
  LatencyStore.applyProbeResult('r1', -1, 'timeout', Date.now());
  const before = LatencyStore.recordFor('r1');
  const writesBefore = MemoryLatencyPersistence.writeCount;
  const summary = LatencyStore.summarize(['r1']);
  eq(summary.failedCount, 1, '失败数');
  const after = LatencyStore.recordFor('r1');
  eq(after.failKind, before.failKind, '聚合不得改动结论');
  eq(after.testedAt, before.testedAt, '聚合不得改动时间戳');
  eq(MemoryLatencyPersistence.writeCount, writesBefore, '聚合不得落盘');
});
check('H12 负对照：非判定失败不进组级失败统计', () => {
  LatencyStore.clear();
  const names = ['x1', 'x2'];
  LatencyStore.applyProbeResult('x1', -1, 'dns_unresolved', Date.now());
  eq(LatencyStore.applyProbeResult('x2', -1, 'core_not_ready', Date.now()), false, 'core_not_ready 不产生结论');
  const summary = LatencyStore.summarize(names);
  eq(summary.failedCount, 1, '失败数只算判定类');
  eq(summary.untestedCount, 1, '没有结论的算未测');
  eq(summary.isUniformFailure, true, '剩下的全是同因');
});
check('C 非判定失败不产生节点结论（applyProbeResult 直接丢弃）', () => {
  LatencyStore.clear();
  const produced = LatencyStore.applyProbeResult('nA', -1, 'core_not_ready', Date.now());
  eq(produced, false, 'core_not_ready 是否产生结论');
  eq(LatencyStore.recordFor('nA'), null, 'core_not_ready 之后不应有结论');
  const produced2 = LatencyStore.applyProbeResult('nB', -1, 'unknown', Date.now());
  eq(produced2, false, 'unknown 是否产生结论');
  eq(LatencyStore.recordFor('nB'), null, 'unknown 之后不应有结论');
});
check('C 负对照：判定失败/实测成功才产生结论', () => {
  LatencyStore.clear();
  eq(LatencyStore.applyProbeResult('nC', -1, 'timeout', Date.now()), true, 'timeout 应产生结论');
  ok(LatencyStore.recordFor('nC') !== null, 'timeout 后应有结论');
  eq(LatencyStore.applyProbeResult('nD', 42, '', Date.now()), true, '实测应产生结论');
  eq(LatencyStore.recordFor('nD').delayMs, 42, '实测延迟');
});
check('C 失败响应体完整进日志（不是 bodyLen）', () => {
  const src = stripComments(fs.readFileSync(path.join(latencyDir, 'LatencyProbe.ets'), 'utf8'));
  ok(src.indexOf('bodyLen=') < 0, '源码里还有 bodyLen= 这种旧写法');
  ok(src.indexOf('bodyForLog') > 0, '源码里没有 bodyForLog（完整体的日志处理）');
});
await checkAsync('C 运行时：完整失败体（含 dial 错误）写进日志', async () => {
  modLogger.LOGS.length = 0;
  const body = '{"message":"dial tcp 10.0.0.1:443: connect: connection refused"}';
  const t = new FakeTransport({ responseCode: 503, body });
  const r = await LatencyProbe.probeOne('nE', 'https://x.example.com/g', endpoint(), t);
  eq(r.failKind, 'network_unreachable', '分类');
  const logged = modLogger.LOGS.map((l) => l.msg).join('\n');
  ok(logged.indexOf('connection refused') >= 0, `日志里没有失败体原文：${logged}`);
  ok(logged.indexOf('dial tcp') >= 0, '日志里没有 dial 错误');
  ok(logged.indexOf('http=503') >= 0, '日志里没有状态码');
  ok(logged.indexOf('elapsed=') >= 0, '日志里没有耗时');
  ok(logged.indexOf('bodyLen') < 0, '日志里还在写 bodyLen');
});

console.log('── D. 落盘字段级 ──');

await checkAsync('D1 落盘写三个字段槽（不是整单）', async () => {
  MemoryLatencyPersistence.reset();
  LatencyStore.clear();
  LatencyStore.setBackend(new MemoryLatencyPersistence());
  LatencyStore.applyProbeResult('nF', 123, '', 1000);
  await LatencyStore.persist('nF');
  eq(MemoryLatencyPersistence.valueOf('nF', LatencyStoreField.DELAY_MS), '123', 'delayMs 槽');
  eq(MemoryLatencyPersistence.valueOf('nF', LatencyStoreField.FAIL_KIND), '', 'failKind 槽');
  eq(MemoryLatencyPersistence.valueOf('nF', LatencyStoreField.TESTED_AT), '1000', 'testedAt 槽');
});
await checkAsync('D2 负对照：写延迟不会覆盖别的写者写的字段（整单覆盖会丢更新）', async () => {
  MemoryLatencyPersistence.reset();
  LatencyStore.clear();
  LatencyStore.setBackend(new MemoryLatencyPersistence());
  // 另一个写者（自动切换记账）先写了自己拥有的字段
  await LatencyStore.backendRef().saveField('nG', 'failCount', '3');
  LatencyStore.applyProbeResult('nG', 55, '', 2000);
  await LatencyStore.persist('nG');
  eq(MemoryLatencyPersistence.valueOf('nG', 'failCount'), '3',
    '整单覆盖会把这个字段冲掉');
  eq(MemoryLatencyPersistence.valueOf('nG', LatencyStoreField.DELAY_MS), '55', 'delayMs 应写入');
});
await checkAsync('D2b 字段级：只写一个字段，其余字段原样保留', async () => {
  MemoryLatencyPersistence.reset();
  LatencyStore.setBackend(new MemoryLatencyPersistence());
  await LatencyStore.backendRef().saveField('nG2', LatencyStoreField.DELAY_MS, '7');
  await LatencyStore.backendRef().saveField('nG2', LatencyStoreField.FAIL_KIND, 'timeout');
  await LatencyStore.backendRef().saveField('nG2', LatencyStoreField.TESTED_AT, '99');
  await LatencyStore.backendRef().saveField('nG2', LatencyStoreField.TESTED_AT, '100');
  eq(MemoryLatencyPersistence.valueOf('nG2', LatencyStoreField.DELAY_MS), '7', 'delayMs 未被动');
  eq(MemoryLatencyPersistence.valueOf('nG2', LatencyStoreField.FAIL_KIND), 'timeout', 'failKind 未被动');
  eq(MemoryLatencyPersistence.valueOf('nG2', LatencyStoreField.TESTED_AT), '100', 'testedAt 应被更新');
});
await checkAsync('D2c 没有「整单 blob」槽：每节点只有我们拥有的字段', async () => {
  MemoryLatencyPersistence.reset();
  LatencyStore.clear();
  LatencyStore.setBackend(new MemoryLatencyPersistence());
  LatencyStore.applyProbeResult('nG3', 8, '', 1000);
  await LatencyStore.persist('nG3');
  const slots = MemoryLatencyPersistence.slotsOf('nG3').sort();
  eq(JSON.stringify(slots), JSON.stringify([LatencyStoreField.DELAY_MS, LatencyStoreField.FAIL_KIND,
    LatencyStoreField.TESTED_AT].sort()), '字段槽集合');
});
await checkAsync('D3 不同节点互不影响', async () => {
  MemoryLatencyPersistence.reset();
  LatencyStore.clear();
  LatencyStore.setBackend(new MemoryLatencyPersistence());
  LatencyStore.applyProbeResult('nH', 11, '', 1000);
  await LatencyStore.persist('nH');
  LatencyStore.applyProbeResult('nI', 22, '', 1000);
  await LatencyStore.persist('nI');
  eq(MemoryLatencyPersistence.valueOf('nH', LatencyStoreField.DELAY_MS), '11', 'nH');
  eq(MemoryLatencyPersistence.valueOf('nI', LatencyStoreField.DELAY_MS), '22', 'nI');
});
check('D4 preferences 后端：一个 (节点, 字段) 一个 key', () => {
  const k1 = PreferencesLatencyPersistence.key('香港 01', LatencyStoreField.DELAY_MS);
  const k2 = PreferencesLatencyPersistence.key('香港 01', LatencyStoreField.FAIL_KIND);
  const k3 = PreferencesLatencyPersistence.key('日本 02', LatencyStoreField.DELAY_MS);
  ok(k1 !== k2, '同节点不同字段必须不同 key');
  ok(k1 !== k3, '不同节点必须不同 key');
  eq(PreferencesLatencyPersistence.nameOfKey(k1), '香港 01', 'key 反解节点名');
  eq(PreferencesLatencyPersistence.nameOfKey(k3), '日本 02', 'key 反解节点名');
  eq(PreferencesLatencyPersistence.nameOfKey('other_key'), '', '非本后端的 key 应被忽略');
});

console.log('── E. restore 不覆盖更新的结论 ──');

check('E1 无进程内记录 → 落盘结论可恢复', () => {
  LatencyStore.clear();
  const rec = new LatencyVerdict();
  rec.name = 'nJ'; rec.delayMs = 77; rec.failKind = ''; rec.testedAt = 5000;
  eq(LatencyStore.restore('nJ', rec), true, '应恢复');
  eq(LatencyStore.recordFor('nJ').delayMs, 77, '恢复后的延迟');
});
check('E2 负对照：进程内结论更新 → 旧快照不得覆盖', () => {
  LatencyStore.clear();
  LatencyStore.applyProbeResult('nK', 999, '', 9000);
  const old = new LatencyVerdict();
  old.name = 'nK'; old.delayMs = 111; old.failKind = ''; old.testedAt = 1000;
  eq(LatencyStore.restore('nK', old), false, '旧快照必须被拒绝');
  eq(LatencyStore.recordFor('nK').delayMs, 999, '进程内新结论被旧快照盖掉了');
});
check('E3 进程内结论更旧 → 落盘更新结论可覆盖', () => {
  LatencyStore.clear();
  LatencyStore.applyProbeResult('nL', 10, '', 1000);
  const fresh = new LatencyVerdict();
  fresh.name = 'nL'; fresh.delayMs = 20; fresh.failKind = ''; fresh.testedAt = 8000;
  eq(LatencyStore.restore('nL', fresh), true, '更新的落盘结论应覆盖');
  eq(LatencyStore.recordFor('nL').delayMs, 20, '覆盖后的延迟');
});
check('E4 落盘是非判定失败 → 不产生结论（沿用上次有效结论）', () => {
  LatencyStore.clear();
  const rec = new LatencyVerdict();
  rec.name = 'nM'; rec.delayMs = -1; rec.failKind = 'core_not_ready'; rec.testedAt = 9000;
  eq(LatencyStore.restore('nM', rec), false, '非判定失败不应恢复成结论');
  eq(LatencyStore.recordFor('nM'), null, '不应产生结论');
});
await checkAsync('E5 restoreAll 只恢复该恢复的', async () => {
  MemoryLatencyPersistence.reset();
  LatencyStore.clear();
  LatencyStore.setBackend(new MemoryLatencyPersistence());
  LatencyStore.applyProbeResult('nN', 33, '', 1000);
  await LatencyStore.persist('nN');
  LatencyStore.applyProbeResult('nO', 44, '', 9000);
  await LatencyStore.persist('nO');
  // 进程内 nO 已是最新（9000），落盘也是 9000 → 不算「恢复」
  LatencyStore.clear();
  const restored = await LatencyStore.restoreAll();
  eq(restored, 2, '应恢复两条');
  eq(LatencyStore.recordFor('nN').delayMs, 33, 'nN');
  eq(LatencyStore.recordFor('nO').delayMs, 44, 'nO');
});

console.log('── F. 三套渲染合成一张表 ──');

check('F1 同一 failKind：live / 落盘 / 恢复三条路径渲染一致', () => {
  const now = Date.now();
  const kind = 'timeout';
  const live = LatencyStore.describe(kind, -1, now, now);
  const disk = LatencyStore.describe(kind, -1, now, now);
  const restored = LatencyStore.describe(kind, -1, now, now);
  eq(live.text, disk.text, 'live vs 落盘');
  eq(live.text, restored.text, 'live vs 恢复');
  eq(live.level, disk.level, '级别一致');
  eq(live.level, restored.level, '级别一致');
});
check('F2 非判定失败绝不渲染成红色', () => {
  const now = Date.now();
  for (const k of ['core_not_ready', 'unknown', 'queue_timeout', 'untested', 'cancelled']) {
    const v = LatencyStore.describe(k, -1, now, now);
    ok(v.level !== LatencyViewLevel.BAD, `kind=${k} 被渲染成红色（${v.level}）`);
    eq(v.isVerdict, false, `kind=${k} 的判定标记`);
  }
});
check('F3 陈旧结论标记（超过 TTL 灰显但保留）', () => {
  const now = Date.now();
  const old = LatencyStore.describe('', 100, now - 11 * 60 * 1000, now);
  eq(old.stale, true, '陈旧标记');
  const fresh = LatencyStore.describe('', 100, now, now);
  eq(fresh.stale, false, '新鲜结论不应标陈旧');
});

console.log('── G. 参数集中在常量区 ──');

check('G1 参数常量区的取值', () => {
  eq(LatencyProbeLimits.NODE_TIMEOUT_MS, 3000, 'NODE_TIMEOUT_MS');
  eq(LatencyProbeLimits.OUTER_EXTRA_MS, 1200, 'OUTER_EXTRA_MS');
  eq(LatencyProbeLimits.WORKERS, 50, 'WORKERS');
  // 2026-10-21 真机回退：在途请求数 50 → 8（= OHOS 同 host 连接池容量）。
  // 50 路在途会让超出连接池的请求在 http 栈内部排队，排队时间被算进单请求预算 ⇒
  // 客户端侧 2300028 ⇒ 被归成 core_not_ready ⇒ 6 连击作废整批（飞鸟云 31 节点批：
  // 后 24 个节点一次 /delay 都没发）。必须与引擎闸门 LATENCY_INFLIGHT 同值。
  eq(LatencyProbeLimits.MAX_INFLIGHT, 8, 'MAX_INFLIGHT（= 引擎在途闸门 LATENCY_INFLIGHT）');
  eq(LatencyProbeLimits.QUEUE_WAIT_MAX_MS, 60000, 'QUEUE_WAIT_MAX_MS');
});
check('G2 源码断言：超时/并发魔数只出现在 LatencyProbeLimits 类里', () => {
  const src = stripComments(fs.readFileSync(path.join(latencyDir, 'LatencyProbe.ets'), 'utf8'));
  const start = src.indexOf('export class LatencyProbeLimits {');
  ok(start > 0, '找不到 LatencyProbeLimits');
  const end = src.indexOf('\nexport ', start + 10);
  const region = src.substring(start, end < 0 ? src.length : end);
  const outside = src.substring(0, start) + (end < 0 ? '' : src.substring(end));
  for (const num of ['3000', '1200', '60000']) {
    ok(region.indexOf(num) >= 0, `常量区里找不到 ${num}`);
    ok(outside.indexOf(num) < 0, `魔数 ${num} 散落在常量区之外`);
  }
  const storeSrc = stripComments(fs.readFileSync(path.join(latencyDir, 'LatencyStore.ets'), 'utf8'));
  for (const num of ['3000', '1200', '60000']) {
    ok(storeSrc.indexOf(num) < 0, `LatencyStore.ets 里出现了魔数 ${num}`);
  }
});

console.log('── 可选：ArkTS 真编译（新包桥接）──');

if (process.argv.includes('--arkts')) {
  const deveco = process.env.DEVECO_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio';
  const nodeExe = path.join(deveco, 'tools', 'node', 'node.exe');
  const hvigorw = path.join(deveco, 'tools', 'hvigor', 'bin', 'hvigorw.js');
  const sdkHome = process.env.DEVECO_SDK_HOME || path.join(deveco, 'sdk');
  const javaHome = process.env.JAVA_HOME || path.join(deveco, 'jbr');
  const entryAbility = path.join(appRoot, 'entry/src/main/ets/entryability/EntryAbility.ets');
  const MARK = '// __latency_v2_compile_probe__';
  if (!fs.existsSync(nodeExe) || !fs.existsSync(hvigorw) || !fs.existsSync(sdkHome)) {
    console.log('SKIP 找不到完整 DevEco 工具链 → 跳过 ArkTS 真编译');
  } else {
    const original = fs.readFileSync(entryAbility, 'utf8');
    // import 必须放在其它语句之前（arkts-no-misplaced-imports）→ 插到最后一条 import 之后
    const lines = original.split('\n');
    let lastImport = -1;
    for (let i = 0; i < Math.min(lines.length, 60); i++) {
      if (lines[i].startsWith('import ')) {
        lastImport = i;
      }
    }
    if (lastImport < 0) {
      console.log('SKIP EntryAbility.ets 里找不到 import 行 → 无法桥接');
    } else {
      const marker = `${MARK}\nimport { LatencyProbe } from '../commons/latency/LatencyProbe';`;
      const patched = [
        ...lines.slice(0, lastImport + 1),
        ...marker.split('\n'),
        ...lines.slice(lastImport + 1)
      ].join('\n');
      fs.writeFileSync(entryAbility, patched, 'utf8');
      let out = '';
      try {
        const r = spawnSync(nodeExe, [
          hvigorw, '--mode', 'module', '-p', 'module=entry@default', '-p', 'product=default',
          '-p', 'requiredDeviceType=tablet', 'assembleHap', '--analyze=normal', '--parallel', '--incremental'
        ], {
          env: {
            ...process.env,
            DEVECO_SDK_HOME: sdkHome,
            JAVA_HOME: javaHome,
            PATH: `${path.join(javaHome, 'bin')};${process.env.PATH || ''}`
          },
          cwd: appRoot,
          encoding: 'utf8',
          maxBuffer: 128 * 1024 * 1024
        });
        out = `${r.stdout || ''}\n${r.stderr || ''}`;
      } finally {
        // 精确还原：内容没被别人动过 → 原样写回；被别人动过 → 只删掉我插的那两行
        const current = fs.readFileSync(entryAbility, 'utf8');
        if (current === patched) {
          fs.writeFileSync(entryAbility, original, 'utf8');
        } else {
          const cleaned = current.split('\n')
            .filter((line) => !line.includes(MARK)
              && !line.includes("from '../commons/latency/LatencyProbe'"))
            .join('\n');
          fs.writeFileSync(entryAbility, cleaned, 'utf8');
        }
      }
      const arktsErrors = out.split('\n')
        // arkts-no-* 也可能仅是 WARN；不能把成功构建中的 warning 误判成编译失败。
        .filter((l) => /ArkTS Compiler Error|ERROR: 10605\d+|ERROR: ArkTS|Failed :entry:default@CompileArkTS/i.test(l));
      const buildOk = /BUILD SUCCESSFUL/.test(out);
      const logPath = path.join(os.tmpdir(), 'latency-v2-arkts-build.log');
      fs.writeFileSync(logPath, out, 'utf8');
      check('G3 ArkTS 真编译：新延迟包可编译（临时接入 import 图）', () => {
        ok(arktsErrors.length === 0,
          `ArkTS 编译错误：${arktsErrors.slice(0, 5).join(' | ')}（完整日志：${logPath}）`);
        ok(buildOk, `assembleHap 未成功（完整日志：${logPath}）`);
      });
    }
  }
} else {
  console.log('SKIP ArkTS 真编译未启用（加 --arkts 打开）');
}


// ── I 组：接线（唯一测速路径）────────────────────────────────────────────────
// 背景（2026-10-20 lead 裁定）：内核里已经有唯一真源（LatencyProbe.probeOne），
// 但**引擎仍旧走旧通道**（ClashApiService 自己发 http、自己分类）⇒ 真源形同虚设。
// 这组断言就是钉死「引擎 → API 服务 → 测速内核」这条链真的接上了。
const apiSrc = stripComments(fs.readFileSync(path.join(servicesDir, 'ClashApiService.ets'), 'utf8'));
const engineSrc = stripComments(fs.readFileSync(path.join(servicesDir, 'LatencyEngine.ets'), 'utf8'));
const dnsVerdictSrc = fs.readFileSync(path.join(latencyDir, 'LatencyDnsVerdict.ets'), 'utf8');
const probeSrc = stripComments(fs.readFileSync(path.join(latencyDir, 'LatencyProbe.ets'), 'utf8'));
const kindsSrc = fs.readFileSync(path.join(latencyDir, 'LatencyKinds.ets'), 'utf8');
const kindsStripped = stripComments(kindsSrc);

/** 取某个方法体（源码断言用）：从方法声明到下一个同缩进的闭合花括号 */
function methodBody(src, signature) {
  const i = src.indexOf(signature);
  if (i < 0) throw new Error(`method not found: ${signature}`);
  const end = src.indexOf('\n  }', i);
  if (end < 0) throw new Error(`method end not found: ${signature}`);
  return src.slice(i, end);
}

check('I1 API 服务把探测委托给测速内核（不再自己发 http 请求）', () => {
  const body = methodBody(apiSrc, 'async testLatencyDetailed(');
  ok(body.includes('CoreLatencyProbe.probeOne('), 'testLatencyDetailed 必须调用 LatencyProbe.probeOne');
  ok(!body.includes('http.createHttp()'), 'testLatencyDetailed 不得自己创建 http 请求（旧通道必须死绝）');
  ok(!body.includes('classifyStatusCode('), '旧的状态码分类口径不得再参与测速路径');
  ok(!body.includes('classifyTransportError('), '旧的传输层分类口径不得再参与测速路径');
});

check('I2 API 服务的探测入口接受 DNS 预检结论（可选第 5 参）', () => {
  const body = methodBody(apiSrc, 'async testLatencyDetailed(');
  ok(/dns\s*:\s*LatencyDnsVerdict\s*\|\s*null/.test(body),
    'testLatencyDetailed 必须接受 dns: LatencyDnsVerdict | null');
  ok(body.includes('probeOne(') && body.includes('dns)'),
    'dns 结论必须原样传给 probeOne（内核据此短路）');
});

check('I3 引擎把每节点的 DNS 结论传给 API 层', () => {
  const body = methodBody(engineSrc, 'private async gatedProbe(');
  ok(body.includes('testLatencyDetailed('), 'gatedProbe 必须调用 testLatencyDetailed');
  ok(/testLatencyDetailed\([\s\S]*this\.dnsVerdictFor\(node\)/.test(body),
    'gatedProbe 必须把 dnsVerdictFor(node) 传给 testLatencyDetailed');
});

check('I4 引擎每批取一次 DNS 快照（不逐节点去问编排器）', () => {
  const hits = engineSrc.split('hostSnapshot()').length - 1;
  eq(hits, 1, 'hostSnapshot() 只能有一个调用点（run() 开头取一次）');
  ok(engineSrc.includes('private dnsVerdictFor(node: ProxyNode)'),
    '每节点的结论必须由 dnsVerdictFor(node) 现算（快照是批次级、结论是节点级）');
  ok(engineSrc.includes('fromPins(node.name, node.server'),
    '每节点结论必须用节点自己的 server 域名去查快照');
});

check('I5 失败分类词表补齐 dns_unresolved / unknown（真源在 LatencyKinds）', () => {
  ok(/static readonly DNS_UNRESOLVED: string = 'dns_unresolved';/.test(kindsStripped),
    'LatencyKinds.LatencyProbeKind 必须有 DNS_UNRESOLVED');
  ok(/static readonly UNKNOWN: string = 'unknown';/.test(kindsStripped),
    'LatencyKinds.LatencyProbeKind 必须有 UNKNOWN');
  // ⚠ 分类常量**只允许**住在零 import 的分类表模块里（services 侧的值依赖）
  ok(!/class LatencyFailKind/.test(apiSrc), 'ClashApiService 不许再自带一份分类表');
  ok(!/class LatencyFailKind/.test(engineSrc), 'LatencyEngine 不许再自带一份分类表');
});

check('I6 引擎发布路径：dns_unresolved 落节点结论，非判定类不落结论', () => {
  // ⚠ 发布判定（recordFor）是引擎里**唯一**的落结论入口；判定权在内核的 isVerdictKind。
  const body = methodBody(engineSrc, 'private recordFor(');
  const dnsAt = body.indexOf('LatencyProbeKind.DNS_UNRESOLVED');
  ok(dnsAt >= 0, 'recordFor 必须处理 dns_unresolved');
  ok(body.includes('isVerdictKind('),
    '落不落结论必须由内核的判定表回答（引擎不得自带 publishable 语义）');
  const dnsBlock = body.slice(dnsAt, dnsAt + 600);
  ok(dnsBlock.includes('LatencyRecord.failed('),
    'dns_unresolved 必须作为节点结论发布');
  ok(dnsBlock.includes('LatencyState.FAILED'), 'dns_unresolved 的状态是 FAILED（节点结论，不是通道问题）');
  ok(body.includes('LatencyProbeKind.QUEUE_TIMEOUT'),
    '排队超时必须单列（节点级「没排上队」，与通道故障严格分开）');
});

check('I7 DNS 结论模块零 import（扁平沙箱闸门能跑的结构性保证）', () => {
  const imports = dnsVerdictSrc.split('\n').filter((l) => /^\s*import\s/.test(l));
  eq(imports.length, 0, `LatencyDnsVerdict.ets 必须零 import（实际 ${imports.length} 条）`);
  ok(dnsVerdictSrc.includes('static fromPins('), '判定规则本体必须在这里（唯一真源）');
});

check('I9 dns_unresolved 是**节点结论**（不进非判定清单）', () => {
  // 非判定清单是「我们自己的问题 vs 节点结论」的分界。
  // 2026-10-20 lead 拍板：**唯一判定表** = 内核分类表 LatencyKinds.isNonVerdictKind
  // （恢复路径的 UI 策略层只能转调它，不得自带第二份清单）。
  const m = kindsStripped.match(/static isNonVerdictKind\(kind: string\): boolean \{([\s\S]*?)\n  \}/);
  ok(m !== null, '必须能定位 LatencyProbeKind.isNonVerdictKind（唯一判定表）');
  for (const konst of ['DNS_UNRESOLVED', 'TIMEOUT', 'SWITCH_FAILED', 'NETWORK_UNREACHABLE']) {
    ok(!m[1].includes(`LatencyProbeKind.${konst}`),
      `${konst} 是节点结论，不得进非判定清单（否则 UI 会退化成「失败」）`);
  }
  // 恢复路径（services/LatencyState.ets）若还留着反表，必须**转调**内核
  const stateSrc = stripComments(
    fs.readFileSync(path.join(servicesDir, 'LatencyState.ets'), 'utf8'));
  const legacy = stateSrc.match(/static isNonVerdictKind\(failKind: string\): boolean \{([\s\S]*?)\n  \}/);
  if (legacy !== null) {
    ok(legacy[1].includes('LatencyProbeKind.isNonVerdictKind('),
      'LatencyPolicy.isNonVerdictKind 必须转调内核判定表（不得自带清单）');
  }
  // 「认不出来」（unknown）不是结论：引擎侧保证**不发布**它（见 engine-runtime 的 D5）。
});

check('I12 陈旧判定与阈值只有一份（下沉到零 import 的内核分类表）', () => {
  // 2026-10-20 lead 拍板：阈值 STALE_MS 与陈旧判定 isStale 的**唯一**真源在
  // 零 import 的 LatencyKinds（services 侧只允许转调 ⇒ 扁平暂存闸门不用加桩）。
  ok(/static readonly STALE_MS: number = 10 \* 60 \* 1000;/.test(kindsStripped),
    'LatencyKinds 必须有唯一的 STALE_MS 阈值');
  ok(/static isStale\(testedAtMs: number, nowMs: number, isFailure: boolean\): boolean \{/.test(kindsStripped),
    'LatencyKinds 必须有唯一的 isStale 判定');
  const storeSrc = fs.readFileSync(path.join(latencyDir, 'LatencyStore.ets'), 'utf8');
  ok(storeSrc.includes('LatencyProbeKind.isStale('),
    'LatencyStore.describe 必须转调内核的 isStale（不得自己算年龄）');
  ok(!/static\s+readonly\s+STALE_MS\s*:\s*number\s*=\s*\d/.test(storeSrc),
    'LatencyStore 不许再留第二份 STALE_MS 字面量');
  ok(!/nowMs\s*-\s*testedAt/.test(storeSrc),
    'LatencyStore 不许自己算结论年龄（陈旧判定只有一份）');
});

check('I13 唯一判定表的行为钉死（非判定类不得变成节点结论）', () => {
  // 2026-10-20 lead 拍板：判定表只有一张（LatencyKinds.isNonVerdictKind），
  // 正表由它派生。⇒ 这里用**行为**钉死，防以后再漏某一类（cancelled 就漏过一次）。
  for (const k of [LatencyProbeKind.CORE_NOT_READY, LatencyProbeKind.QUEUE_TIMEOUT,
    LatencyProbeKind.UNTESTED, LatencyProbeKind.CANCELLED, LatencyProbeKind.UNSUPPORTED,
    LatencyProbeKind.PORT_ONLY, LatencyProbeKind.UNKNOWN]) {
    eq(LatencyProbeKind.isNonVerdictKind(k), true, `${k} 必须是非判定类`);
    eq(LatencyProbeKind.isVerdictKind(k), false, `${k} 不得成为节点结论`);
  }
  // 真·节点结论：必须留在正侧（dns_unresolved 尤其不能退化）
  for (const k of [LatencyProbeKind.TIMEOUT, LatencyProbeKind.SWITCH_FAILED,
    LatencyProbeKind.NETWORK_UNREACHABLE, LatencyProbeKind.DNS_UNRESOLVED]) {
    eq(LatencyProbeKind.isNonVerdictKind(k), false, `${k} 不得进非判定表`);
    eq(LatencyProbeKind.isVerdictKind(k), true, `${k} 必须是节点结论`);
  }
  // 空串 = 实测出了延迟 = 一个真结论（写路径 LatencyStore.applyProbeResult 依赖它）
  eq(LatencyProbeKind.isNonVerdictKind(LatencyProbeKind.NONE), false, '空串不得进非判定表');
  eq(LatencyProbeKind.isVerdictKind(LatencyProbeKind.NONE), true, '空串必须是结论（实测延迟不能丢）');
});

check('I8 探针再导出 DNS 结论（外部 import 路径保持稳定）', () => {
  ok(probeSrc.includes('export { LatencyDnsStatus, LatencyDnsVerdict };'),
    'LatencyProbe.ets 必须再导出 DNS 结论（避免调用方路径漂移）');
  ok(probeSrc.includes("from './LatencyDnsVerdict'"),
    'LatencyProbe.ets 必须从零 import 的模块取 DNS 结论');
});

check('I10 旧延迟通道已删：API 兼容口 / 本地分类表 / 引擎自带失败映射', () => {
  // LP02 / LP03：旧兼容口（任何非 200 ⇒ null；失败 ⇒ -1）不许复活
  ok(!/testGroupDetailed\s*\(/.test(apiSrc), 'ClashApiService 不许再有 testGroupDetailed（LP02）');
  ok(!/\btestLatency\s*\(/.test(apiSrc), 'ClashApiService 不许再有 testLatency（LP03）');
  // 本地分类表 / 旧分类口径
  ok(!/class LatencyFailKind/.test(apiSrc), 'ClashApiService 不许自带分类表');
  ok(!/classifyStatusCode\s*\(/.test(apiSrc), '旧的状态码分类口径必须已删');
  ok(!/classifyTransportError\s*\(/.test(apiSrc), '旧的传输层分类口径必须已删');
  // 引擎：不得再有自带的失败映射 / 发布语义 / 自己的 http 通道
  ok(!/mapFailure/.test(engineSrc), 'LatencyEngine 不许自带失败映射（真源在内核）');
  ok(!/publishable|notPublishable|deadlineSkipped/.test(engineSrc),
    'LatencyEngine 不许再有 publishable/notPublishable/deadlineSkipped 语义');
  ok(!/http\.createHttp\(/.test(engineSrc), 'LatencyEngine 不许自己发 http 请求');
  ok(engineSrc.includes('private recordFor('),
    '落结论必须收敛到 recordFor（单一入口）');
});

check('I11 分类表模块零 import（扁平暂存沙箱能跑的结构性保证）', () => {
  const imports = kindsSrc.split('\n').filter((l) => /^\s*import\s/.test(l));
  eq(imports.length, 0, `LatencyKinds.ets 必须零 import（实际 ${imports.length} 条）`);
  ok(kindsSrc.includes('static isVerdictKind('), '判定表本体必须在这里（唯一真源）');
  ok(probeSrc.includes('export { LatencyProbeKind, LatencyProbeResult };'),
    'LatencyProbe.ets 必须再导出分类表与结果类型（外部 import 路径保持稳定）');
});

console.log('');console.log(`RESULT: ${passed} passed, ${failed} failed`);
if (failed > 0) {
  console.log('');
  for (const f of failures) console.log(`  · ${f}`);
}
process.exit(failed === 0 ? 0 : 1);
