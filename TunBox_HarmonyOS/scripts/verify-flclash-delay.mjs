/**
 * FlClash 等价测速引擎的**行为**验证（跑真代码，不是读源码）。
 *
 * 做法同 verify-latency-concurrency.mjs：把真实现暂存成 .ts 后 import，
 * 只把「不可控的外部世界」换成桩：
 *   - FlclashDelay（真）＋可注入的 DelayHttpTransport 桩（真发 HTTP 到本地 127.0.0.1 桩内核）
 *   - 桩内核：node http server，按 proxy 名返回 200 {"delay":123} / 504 / 503 / 404 / 200 非法体 / 挂起 6s
 *
 * 验收门槛（规格 §4.2 / §4.4）：
 *   C1 并发池固定 32：桩内核实测在途 HTTP 不超过 32
 *   C2 -1/-2 语义：504 ⇒ -1；503/404/非法 200 ⇒ -2；200 delay>0 ⇒ 延迟
 *   C3 取消不写结论：在途 abort、未开始跳过，onResult 一次都不该回调，summary 计入 cancelled
 *   C4 排队不计入 30s 守护：并发 4 + 守护 400ms + 24 个 300ms 任务 ⇒ 全部拿到结论，
 *      总耗时远超守护窗口（若守护从批次开始计时，后面几波会整批作废）
 *   C5 守护到期 ⇒ 不作结论（不写 -1，不写 -2）
 *   C6 请求形态：/proxies/{encodeURIComponent(name)}/delay?url=…&timeout=5000 + Bearer 头
 *   C7 汇总恒等式：total = measured + timedOut + failed + cancelled
 *   C8 不许叠批：start 在跑时再 start 被忽略
 *   C9 不实现组测速/离线探活：文件里不得出现 /group/ 与 TCP 探活痕迹
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const appRoot = path.join(here, '..');
const SRC = path.join(appRoot, 'entry/src/main/ets/commons/flclash/FlclashDelay.ets');

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
function ok(cond, label) {
  if (!cond) throw new Error(label);
}
function eq(actual, expected, label) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const URL_DEFAULT = 'https://www.gstatic.com/generate_204';

// ── 暂存真实现（只替换 ArkTS 专属 import） ────────────────────────────────
const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'flclash-delay-'));
const write = (name, text) => fs.writeFileSync(path.join(stage, name), text, 'utf8');

write('fakeHttp.ts', `
// Node 侧不会被调用：引擎在脚本里一律注入桩 transport。
export const http = {
  RequestMethod: { GET: 'GET' },
  createHttp: (): Object => {
    throw new Error('@kit.NetworkKit 在 Node 侧不可用（必须注入 transport 桩）');
  }
};
export const socket = {
  constructTCPSocketInstance: (): Object => {
    throw new Error('@kit.NetworkKit TCPSocket 在 Node 侧不可用（必须注入 transport 桩）');
  }
};
`);

write('AppLogger.ts', `
export class AppLogger {
  static lines: string[] = [];
  static info(t: string, m: string): void { AppLogger.lines.push('INFO ' + t + ' ' + m); }
  static warn(t: string, m: string): void { AppLogger.lines.push('WARN ' + t + ' ' + m); }
  static error(t: string, m: string): void { AppLogger.lines.push('ERROR ' + t + ' ' + m); }
  static errText(e: Object): string { return e instanceof Error ? e.message : String(e); }
}
`);

const rawSrc = fs.readFileSync(SRC, 'utf8');
const stagedSrc = rawSrc
  .replace(/from '@kit\.NetworkKit'/g, "from './fakeHttp.ts'")
  // 2026-10-26：TCP 直连传输层引入 @kit.ArkTS（TextDecoder）与 @kit.BasicServicesKit
  // （BusinessError 类型）；沙箱仍需零 @kit 依赖，各补一个最小桩。
  .replace(/from '@kit\.ArkTS'/g, "from './fakeArkTs.ts'")
  .replace(/from '@kit\.BasicServicesKit'/g, "from './fakeKit.ts'")
  // 2026-10-22：测速地址改为引用单一真源 LatencyTestUrl（ND06），
  // 沙箱是扁平目录，specifier 要一起改写并补最小桩。
  .replace(/from '\.\.\/latency\/LatencyTestUrl'/g, "from './LatencyTestUrl.ts'")
  .replace(/from '\.\.\/utils\/AppLogger'/g, "from './AppLogger.ts'");

write('fakeArkTs.ts', `
// TextDecoder 桩：桩传输层不用它（引擎测试一律注入 NodeTransport）。
export const util = {
  TextDecoder: {
    create: (enc: string) => ({
      decodeWithStream: (buf: Uint8Array): string => new TextDecoder(enc).decode(buf)
    })
  }
};
`);

write('fakeKit.ts', `
export class BusinessError extends Error {
  code: number = 0;
}
`);

write('LatencyTestUrl.ts', `
export class LatencyTestUrl {
  static readonly DEFAULT_URL: string = 'https://www.gstatic.com/generate_204';
  static readonly LEGACY_GSTATIC_HTTP: string = 'http://www.gstatic.com/generate_204';
  static normalize(u: string): string { return u; }
  static effective(u: string): string { return u.length > 0 ? u : LatencyTestUrl.DEFAULT_URL; }
}
`);
ok(!/from '@kit\./.test(stagedSrc), 'staged FlclashDelay 不得残留 @kit 导入');
write('FlclashDelay.ts', stagedSrc);

const M = await import(pathToFileURL(path.join(stage, 'FlclashDelay.ts')).href);
const {
  DelayTarget, DelayResult, FlclashDelayRun, FlclashDelayPolicy,
  FLCLASH_DELAY_CONCURRENCY, FLCLASH_DELAY_MAX_CONCURRENCY, flclashDelayConcurrency,
  FLCLASH_DELAY_TIMEOUT_MS, FLCLASH_DELAY_GUARD_MS, FLCLASH_DELAY_URL,
  delayTestKey
} = M;
const { AppLogger } = await import(pathToFileURL(path.join(stage, 'AppLogger.ts')).href);

// ── 桩内核：127.0.0.1 上的 mihomo ──────────────────────────────────────────
const stats = {
  inflight: 0,
  maxInflight: 0,
  requests: [],
  earlyClose: 0,
  total: 0
};
function resetStats() {
  stats.inflight = 0;
  stats.maxInflight = 0;
  stats.requests = [];
  stats.earlyClose = 0;
  stats.total = 0;
}

const server = http.createServer((req, res) => {
  const parsed = new URL(req.url, 'http://127.0.0.1');
  const m = /^\/proxies\/([^/]+)\/delay$/.exec(parsed.pathname);
  if (m === null) {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ message: 'Resource not found' }));
    return;
  }
  const name = decodeURIComponent(m[1]);
  stats.total++;
  stats.requests.push({
    name,
    proxyNameParam: m[1],
    url: parsed.searchParams.get('url'),
    timeout: parsed.searchParams.get('timeout'),
    authorization: req.headers['authorization'] ?? '',
    accept: req.headers['accept'] ?? ''
  });
  stats.inflight++;
  stats.maxInflight = Math.max(stats.maxInflight, stats.inflight);
  let finished = false;
  const done = (status, body) => {
    if (finished) return;
    finished = true;
    stats.inflight--;
    res.writeHead(status, { 'Content-Type': 'application/json' });
    res.end(body);
  };
  let timer = null;
  const kind = name.replace(/\d+$/, '').replace(/[ _].*$/, '');
  if (kind === 'ok') {
    done(200, JSON.stringify({ delay: 123 }));
    return;
  }
  if (kind === 'slow') {
    timer = setTimeout(() => done(200, JSON.stringify({ delay: 250 })), 300);
  } else if (kind === 'timeout') {
    done(504, JSON.stringify({ message: 'Timeout' }));
    return;
  } else if (kind === 'fail') {
    done(503, JSON.stringify({ message: 'An error occurred in the delay test' }));
    return;
  } else if (kind === 'missing') {
    // mihomo：proxy 不在已加载配置里 ⇒ 路由层直接 404
    done(404, JSON.stringify({ message: 'Resource not found' }));
    return;
  } else if (kind === 'bad') {
    done(200, JSON.stringify({ delay: 0 }));
    return;
  } else {
    // hang：永不回包（桩内核「挂起 6s」；客户端守护/取消会先动手）
    timer = setTimeout(() => done(200, JSON.stringify({ delay: 6000 })), 6000);
  }
  res.on('close', () => {
    if (!finished) {
      finished = true;
      stats.inflight--;
      stats.earlyClose++;
      if (timer !== null) clearTimeout(timer);
    }
  });
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const BASE = `http://127.0.0.1:${server.address().port}`;

// ── 传输层桩：真发 HTTP（严格「只有拿到响应才 resolve」） ─────────────────
class NodeTransport {
  send(url, headers, timeoutMs) {
    let req = null;
    let aborted = false;
    const promise = new Promise((resolve, reject) => {
      req = http.request(url, { method: 'GET', headers, agent: false }, (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (c) => { body += c; });
        res.on('end', () => resolve({ responseCode: res.statusCode ?? 0, body }));
        res.on('error', (e) => reject(e));
      });
      req.on('error', (e) => reject(e));
      req.setTimeout(timeoutMs, () => req.destroy(new Error('transport timeout')));
      req.end();
    });
    return {
      promise,
      abort: () => {
        aborted = true;
        try { req?.destroy(new Error('aborted')); } catch { /* 已关闭 */ }
      },
      get aborted() { return aborted; }
    };
  }
}

function run(engine, targets) {
  const results = [];
  const summaries = [];
  engine.start(
    targets,
    (r) => results.push(r),
    (s) => summaries.push(s)
  );
  return new Promise((resolve) => {
    const tick = setInterval(() => {
      if (summaries.length > 0) {
        clearInterval(tick);
        resolve({ results, summaries });
      }
    }, 5);
  });
}
const byName = (results) => {
  const table = new Map();
  for (const r of results) table.set(r.proxyName, r);
  return table;
};

console.log(`桩内核已就绪：${BASE}`);
console.log(`常量：concurrency=${FLCLASH_DELAY_CONCURRENCY} timeout=${FLCLASH_DELAY_TIMEOUT_MS} guard=${FLCLASH_DELAY_GUARD_MS} url=${FLCLASH_DELAY_URL}`);

// ── C0 常量与非网络语义 ───────────────────────────────────────────────────
check('C0 常量口径（32 基线 / 64 上限 / 3000 / 10000 / gstatic 204）', () => {
  eq(FLCLASH_DELAY_CONCURRENCY, 32, 'concurrency 基线');
  eq(FLCLASH_DELAY_MAX_CONCURRENCY, 64, 'concurrency 上限');
  eq(FLCLASH_DELAY_TIMEOUT_MS, 3000, 'timeout');
  eq(FLCLASH_DELAY_GUARD_MS, 10000, 'guard');
  eq(FLCLASH_DELAY_URL, URL_DEFAULT, 'url');
  eq(delayTestKey(URL_DEFAULT, 'a'), `${URL_DEFAULT}\u0000a`, 'delayTestKey');
  const t = new DelayTarget('香港 01');
  eq(t.key, delayTestKey(URL_DEFAULT, '香港 01'), 'DelayTarget.key');
  eq(t.testUrl, URL_DEFAULT, 'DelayTarget.testUrl 默认');
});

// ── C0b 自适应并发曲线（2026-10-29 真机取证后封顶 32） ────────────────────────────────
check('C0b 并发自适应：≤32 一波、40 → 40、80 → 64、600 → 64', () => {
  eq(flclashDelayConcurrency(0), 1, '0 目标兜底 1');
  eq(flclashDelayConcurrency(1), 1, '1');
  eq(flclashDelayConcurrency(24), 24, '24 一波发完');
  eq(flclashDelayConcurrency(32), 32, '32 = 基线');
  eq(flclashDelayConcurrency(40), 40, '40 一波发完');
  eq(flclashDelayConcurrency(64), 64, '64 = 上限');
  eq(flclashDelayConcurrency(80), 64, '80 封顶 64');
  eq(flclashDelayConcurrency(600), 64, '600 封顶 64');
  eq(new FlclashDelayPolicy().widthFor(24), 24, '默认策略 24 目标用 24 路');
  eq(new FlclashDelayPolicy().widthFor(80), 64, '默认策略 80 目标用 64 路');
  eq(new FlclashDelayPolicy(32, 3000, 10000, false).widthFor(80), 32, '关闭自适应时严格 32');
});

// ── C1 固定并发上限（adaptive=false，显式策略） ───────────────────────────
await checkAsync('C1 关闭自适应时并发不超过策略值（40 个 300ms 任务，固定 32 路）', async () => {
  resetStats();
  AppLogger.lines.length = 0;
  const engine = new FlclashDelayRun(BASE, 'secret', new NodeTransport(),
    new FlclashDelayPolicy(32, 3000, 10000, false));
  const targets = Array.from({ length: 40 }, (_, i) => new DelayTarget(`slow${i}`));
  const t0 = Date.now();
  const { results, summaries } = await run(engine, targets);
  const ms = Date.now() - t0;
  eq(results.length, 40, '结果条数');
  ok(results.every((r) => r.value === 250), '全部应为 250ms');
  ok(stats.maxInflight <= 32, `在途峰值 ${stats.maxInflight} 超过 32`);
  eq(stats.maxInflight, 32, '在途峰值应稳定打满 32');
  ok(ms >= 550 && ms < 1200, `40 任务 / 32 并发应约 2 波 ≈ 600ms，实测 ${ms}ms`);
  eq(summaries.length, 1, 'onDone 只回调一次');
  eq(summaries[0].measured, 40, 'measured');
  eq(summaries[0].started, 40, 'started');
  eq(summaries[0].cancelled, 0, 'cancelled');
  eq(engine.isRunning(), false, '跑完应 isRunning=false');
  console.log(`     在途峰值=${stats.maxInflight} 耗时=${ms}ms 结果=${results.length}`);
});

// ── C1b 自适应用例：40 个任务一波发完（峰值 40 > 基线 32） ─────────────────
await checkAsync('C1b 自适应策略下 40 个 300ms 任务一波完成（峰值 40）', async () => {
  resetStats();
  AppLogger.lines.length = 0;
  const engine = new FlclashDelayRun(BASE, 'secret', new NodeTransport());
  const targets = Array.from({ length: 40 }, (_, i) => new DelayTarget(`slow${i}`));
  const t0 = Date.now();
  const { results, summaries } = await run(engine, targets);
  const ms = Date.now() - t0;
  eq(results.length, 40, '结果条数');
  eq(stats.maxInflight, 40, '自适应应把 40 个目标同时发出去');
  ok(ms >= 220 && ms < 600, `40 任务 / 40 并发应一波 ≈ 300ms，实测 ${ms}ms`);
  eq(summaries[0].concurrency, 40, 'summary.concurrency');
  eq(summaries[0].peakInflight, 40, 'summary.peakInflight');
  ok(summaries[0].wallMs >= 200, 'summary.wallMs 应被填充');
  ok(summaries[0].p50ElapsedMs >= 200, `p50=${summaries[0].p50ElapsedMs}`);
  console.log(`     在途峰值=${stats.maxInflight} 耗时=${ms}ms p50=${summaries[0].p50ElapsedMs}ms`);
});

// ── C2 -1 / -2 语义 ───────────────────────────────────────────────────────
await checkAsync('C2 200/504/503/404/非法 200 → 延迟 / -1 / -2 / -2 / -2', async () => {
  resetStats();
  const engine = new FlclashDelayRun(BASE, 'secret', new NodeTransport());
  const targets = [
    new DelayTarget('ok'),
    new DelayTarget('timeout'),
    new DelayTarget('fail'),
    new DelayTarget('missing'),
    new DelayTarget('bad')
  ];
  const { results, summaries } = await run(engine, targets);
  const table = byName(results);
  eq(results.length, 5, '五个目标都该有结论（都拿到了响应）');
  eq(table.get('ok').value, 123, 'ok');
  eq(table.get('ok').httpCode, 200, 'ok httpCode');
  eq(table.get('timeout').value, -1, '504 ⇒ -1');
  eq(table.get('timeout').httpCode, 504, 'timeout httpCode');
  eq(table.get('fail').value, -2, '503 ⇒ -2');
  eq(table.get('missing').value, -2, '404 ⇒ -2');
  eq(table.get('missing').httpCode, 404, '404 httpCode');
  eq(table.get('bad').value, -2, '200 {delay:0} ⇒ -2');
  ok(results.every((r) => r.elapsedMs >= 0), 'elapsedMs 应被填充');
  const s = summaries[0];
  eq([s.measured, s.timedOut, s.failed, s.cancelled], [1, 1, 3, 0], '汇总分桶');
  console.log(`     ${results.map((r) => `${r.proxyName}=${r.value}@${r.httpCode}`).join(' ')}`);
});

// ── C6 请求形态 ───────────────────────────────────────────────────────────
await checkAsync('C6 URL 编码 + url/timeout 参数 + Bearer 头', async () => {
  resetStats();
  const engine = new FlclashDelayRun(BASE, 'sekret', new NodeTransport());
  await run(engine, [new DelayTarget('香港 01', 'https://example.com/204')]);
  const req = stats.requests[0];
  ok(req !== undefined, '桩内核应收到请求');
  eq(req.name, '香港 01', 'proxy 名需 decode 回原文');
  ok(req.proxyNameParam !== '香港 01', `proxy 名必须 encodeURIComponent，实际 ${req.proxyNameParam}`);
  eq(req.url, 'https://example.com/204', '测速 URL 可被调用方覆盖');
  eq(req.timeout, '3000', 'timeout 参数');
  eq(req.authorization, 'Bearer sekret', 'Authorization 头');
  // secret 为空 ⇒ 不带鉴权头
  resetStats();
  const anon = new FlclashDelayRun(BASE, '', new NodeTransport());
  await run(anon, [new DelayTarget('ok')]);
  eq(stats.requests[0].authorization, '', 'secret 为空时不得带 Authorization');
  console.log(`     path-param=${stats.requests.length > 0 ? '已编码' : 'n/a'}`);
});

// ── C3 取消不写结论 ───────────────────────────────────────────────────────
await checkAsync('C3 取消：在途 abort、未开始跳过、一条结论都不写', async () => {
  resetStats();
  AppLogger.lines.length = 0;
  const engine = new FlclashDelayRun(BASE, 'secret', new NodeTransport(),
    new FlclashDelayPolicy(32, 3000, 10000, false));
  const targets = Array.from({ length: 40 }, (_, i) => new DelayTarget(`hang${i}`));
  const results = [];
  let doneCount = 0;
  let summary = null;
  engine.start(targets, (r) => results.push(r), (s) => { doneCount++; summary = s; });
  eq(engine.isRunning(), true, '启动后 isRunning 应为 true');
  await sleep(200);
  eq(stats.inflight, 32, `取消前应在途 32，实测 ${stats.inflight}`);
  engine.cancel();
  await sleep(300);
  eq(results.length, 0, '取消后不得有任何结论');
  eq(doneCount, 1, 'onDone 仍应只回调一次');
  ok(summary !== null, 'summary 必须存在');
  eq(summary.total, 40, 'total');
  eq(summary.started, 32, 'started 只算真正发出的');
  eq([summary.measured, summary.timedOut, summary.failed], [0, 0, 0], '取消不得产生结论分桶');
  eq(summary.cancelled, 40, 'cancelled = 在途 32 + 未开始 8');
  eq(engine.isRunning(), false, '取消后 isRunning 应为 false');
  ok(stats.earlyClose >= 30, `桩内核应看到在途连接被 abort，实测 earlyClose=${stats.earlyClose}`);
  console.log(`     在途=${stats.inflight} earlyClose=${stats.earlyClose} summary.cancelled=${summary.cancelled}`);
});

// ── C4 排队不计入守护 ─────────────────────────────────────────────────────
await checkAsync('C4 排队等待不计入守护（并发 4 / 守护 400ms / 24×300ms）', async () => {
  resetStats();
  AppLogger.lines.length = 0;
  const policy = new FlclashDelayPolicy(4, 5000, 400);
  const engine = new FlclashDelayRun(BASE, 'secret', new NodeTransport(), policy);
  const targets = Array.from({ length: 24 }, (_, i) => new DelayTarget(`slow${i}`));
  const t0 = Date.now();
  const { results, summaries } = await run(engine, targets);
  const ms = Date.now() - t0;
  const s = summaries[0];
  eq(results.length, 24, '排队任务必须全部拿到结论');
  eq([s.measured, s.cancelled], [24, 0], '不得因排队而守护到期');
  ok(ms > 400 * 2, `总耗时 ${ms}ms 必须远超单请求守护 400ms（证明守护不是批次截止）`);
  ok(stats.maxInflight <= 4, `在途峰值 ${stats.maxInflight} 超过并发 4`);
  const guardLogs = AppLogger.lines.filter((l) => l.includes('guard expired'));
  eq(guardLogs.length, 0, '不得出现守护到期');
  console.log(`     在途峰值=${stats.maxInflight} 总耗时=${ms}ms（≈6 波 × 300ms）measured=${s.measured}`);
});

// ── C5 守护到期不作结论 ───────────────────────────────────────────────────
await checkAsync('C5 守护到期：既不写 -1 也不写 -2（no conclusion）', async () => {
  resetStats();
  AppLogger.lines.length = 0;
  const policy = new FlclashDelayPolicy(32, 5000, 150);
  const engine = new FlclashDelayRun(BASE, 'secret', new NodeTransport(), policy);
  const targets = Array.from({ length: 10 }, (_, i) => new DelayTarget(`hang${i}`));
  const t0 = Date.now();
  const { results, summaries } = await run(engine, targets);
  const ms = Date.now() - t0;
  eq(results.length, 0, '守护到期必须不回调');
  const s = summaries[0];
  eq(s.started, 10, 'started');
  eq([s.measured, s.timedOut, s.failed, s.cancelled], [0, 0, 0, 10], '全部计入 cancelled（无结论）');
  ok(ms >= 140 && ms < 1000, `守护 150ms 应立刻收尾，实测 ${ms}ms`);
  ok(AppLogger.lines.some((l) => l.includes('guard expired')), '应有守护到期日志');
  console.log(`     耗时=${ms}ms cancelled=${s.cancelled}（-1/-2 均为 0）`);
});

// ── C7 汇总恒等式 ＋ C8 不许叠批 ──────────────────────────────────────────
await checkAsync('C7 total = measured + timedOut + failed + cancelled；C8 跑中再 start 被忽略', async () => {
  resetStats();
  const engine = new FlclashDelayRun(BASE, 'secret', new NodeTransport());
  const targets = [new DelayTarget('ok'), new DelayTarget('timeout'), new DelayTarget('missing')];
  let dones = 0;
  const summaries = [];
  engine.start(targets, () => {}, (s) => { dones++; summaries.push(s); });
  // 立刻再起一批：必须被忽略
  engine.start([new DelayTarget('ok')], () => {}, () => { dones += 100; });
  await sleep(400);
  eq(dones, 1, '跑中第二次 start 必须被忽略（只允许一次 onDone）');
  const s = summaries[0];
  eq(s.total, 3, 'total');
  eq(s.total, s.measured + s.timedOut + s.failed + s.cancelled, `恒等式 ${JSON.stringify(s)}`);
  // 一批跑完后可再次 start
  const again = await run(engine, [new DelayTarget('ok')]);
  eq(again.results.length, 1, '同一实例跑完可复用');
  eq(again.summaries[0].measured, 1, '复用批次的 measured');
});

// ── C9 不许出现被删掉的行为 ───────────────────────────────────────────────
check('C9 未实现组测速 / 离线探活 / 批次截止 / 新鲜度跳过', () => {
  // 只看**代码里的字符串字面量**（注释里提到「不实现组测速」是允许的）
  const banned = [/['"`]\/group\//, /createTCPSocket/, /createTLSSocket/, /resolveHostName/, /isCoreUnavailable/];
  for (const b of banned) {
    ok(!b.test(rawSrc), `实现里不得出现 ${b}`);
  }
  ok(rawSrc.includes('FLCLASH_DELAY_CONCURRENCY') && rawSrc.includes('FLCLASH_DELAY_GUARD_MS'),
    '必须导出 FlClash 常量');
});

server.close();
await sleep(50);

console.log('');
if (failed > 0) {
  console.log(`FAILED ${failed} / ${passed + failed}`);
  for (const f of failures) console.log(`  - ${f}`);
  process.exit(1);
}
console.log(`ALL PASS ${passed}/${passed}`);
process.exit(0);
