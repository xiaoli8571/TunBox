#!/usr/bin/env node
/**
 * 事件驱动 / 统一调度 / 状态单入口 门禁（2026-10-27）
 *
 * 守的是三条架构不变量：
 *   1. **只有一个底层定时器**：除 UnifiedScheduler 自己，全仓不得出现 `setInterval(`；
 *   2. **状态只有一个写入口**：`this.state = ConnState.X` 必须走 `setState()`，
 *      否则订阅方收不到变化，UI 会退化回轮询；
 *   3. **重连原因必须是枚举**：禁止 `reason + '-retry'` 这类字符串拼接（统计会碎）。
 *
 * 另外校验事件总线本身存在且带载荷（state / traffic / exit）。
 */
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, dirname, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const ETS = join(root, 'entry', 'src', 'main', 'ets');
const read = (p) => readFileSync(p, 'utf8');
const exists = (p) => { try { read(p); return true; } catch { return false; } };

let pass = 0, fail = 0;
function ok(name, cond, msg) {
  if (cond) { pass++; console.log(`  ✓ ${name}`); }
  else { fail++; console.log(`  ✗ ${name} — ${msg}`); }
}

function walk(dir, out) {
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    const st = statSync(full);
    if (st.isDirectory()) { walk(full, out); }
    else if (name.endsWith('.ets')) { out.push(full); }
  }
  return out;
}

const files = walk(ETS, []);
const rel = (f) => relative(ETS, f).split('\\').join('/');

const schedPath = join(ETS, 'commons', 'services', 'UnifiedScheduler.ets');
const evPath = join(ETS, 'commons', 'services', 'ConnectionEvents.ets');
const orchPath = join(ETS, 'commons', 'services', 'ConnectionOrchestrator.ets');

console.log('[EV1] 统一调度器：全仓只有一个底层定时器');
{
  ok('ev1.scheduler-exists', exists(schedPath), '缺少 UnifiedScheduler.ets');
  const sched = exists(schedPath) ? read(schedPath) : '';
  ok('ev1.single-tick', /private static readonly TICK_MS/.test(sched) && /tick\(\)/.test(sched),
    '调度器必须是「单一 tick + 任务表」');
  const offenders = [];
  for (const f of files) {
    if (f === schedPath) { continue; }
    if (read(f).includes('setInterval(')) { offenders.push(rel(f)); }
  }
  ok('ev1.no-raw-setinterval', offenders.length === 0,
    `仍有裸 setInterval：${offenders.join(', ')}`);
  let users = 0;
  for (const f of files) {
    if (f === schedPath) { continue; }
    if (read(f).includes('UnifiedScheduler.every(')) { users++; }
  }
  ok('ev1.adopted', users >= 5, `只有 ${users} 个文件接入统一调度器（要求 ≥5）`);
}

console.log('[EV2] 状态单入口：赋值即推送');
{
  const o = exists(orchPath) ? read(orchPath) : '';
  ok('ev2.setstate-exists', /private setState\(next: ConnState\): void/.test(o),
    '缺少 setState()：状态写入必须收敛到唯一入口');
  const rawAssign = (o.match(/this\.state = ConnState\./g) || []).length;
  ok('ev2.no-raw-assign', rawAssign === 0,
    `仍有 ${rawAssign} 处直接赋值 this.state = ConnState.*（订阅方收不到变化）`);
  ok('ev2.setstate-notifies', /setState[\s\S]{0,400}this\.notify\(\)/.test(o),
    'setState 必须触发既有 listeners');
  ok('ev2.setstate-emits', /setState[\s\S]{0,400}ConnectionEvents\.emit/.test(o),
    'setState 必须推送类型化事件');
}

console.log('[EV3] 事件总线：带载荷、可退订、异常隔离');
{
  const e = exists(evPath) ? read(evPath) : '';
  ok('ev3.bus-exists', e.length > 0, '缺少 ConnectionEvents.ets');
  ok('ev3.kinds', /STATE = 0/.test(e) && /TRAFFIC = 1/.test(e) && /EXIT = 2/.test(e),
    '事件种类必须覆盖 STATE/TRAFFIC/EXIT');
  ok('ev3.subscribe', /static subscribe\(/.test(e) && /static unsubscribe\(/.test(e),
    '事件总线必须支持订阅与退订（页面销毁要能摘掉）');
  ok('ev3.isolation', /catch \(err\)[\s\S]{0,160}静默|catch \(err\)/.test(e),
    '派发必须隔离监听器异常（否则一个页面报错会打断连接流程）');
  const o = exists(orchPath) ? read(orchPath) : '';
  ok('ev3.emit-traffic', /ConnectionEvents\.emit\(ConnEvent\.traffic/.test(o),
    '流量采样必须推送 TRAFFIC 事件（否则 UI 仍要轮询）');
  ok('ev3.emit-exit', /ConnectionEvents\.emit\(ConnEvent\.exit/.test(o),
    '出口变化必须推送 EXIT 事件');
  ok('ev3.api', /subscribeConnEvents\(/.test(o) && /unsubscribeConnEvents\(/.test(o),
    '编排器必须暴露订阅/退订 API');
}

console.log('[EV4] 重连原因枚举化');
{
  const e = exists(evPath) ? read(evPath) : '';
  ok('ev4.enum', /export enum ReconnectReason/.test(e), '缺少 ReconnectReason 枚举');
  ok('ev4.reasons', /NETWORK_RESTORED/.test(e) && /NETWORK_CHANGED/.test(e)
    && /CORE_KILLED_BY_SYSTEM/.test(e) && /CORE_NOT_ALIVE/.test(e) && /RETRY/.test(e),
    '枚举必须覆盖 network-restored/network-changed/core-killed/core-not-alive/retry');
  // 只扫「代码行」：注释里把旧写法当反例举例不算违规
  const codeOnly = (text) => text.split('\n')
    .filter((line) => {
      const t = line.trim();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');
  const bad = [];
  for (const f of files) {
    if (codeOnly(read(f)).includes('reason + ' + "'-retry'")) { bad.push(rel(f)); }
  }
  ok('ev4.no-string-concat', bad.length === 0, '仍有 reason 字符串拼接：' + bad.join(', '));
}

console.log('[EV5] 页面去轮询：节点就绪走事件');
{
  const hp = join(ETS, 'pages', 'HomePage.ets');
  const t = exists(hp) ? read(hp) : '';
  ok('ev5.node-ready-event', /onNodeSetChanged\(/.test(t), '首页节点就绪必须订阅事件（不再 400ms 轮询）');
  ok('ev5.node-ready-unsub', /offNodeSetChanged\(/.test(t), '首页销毁必须退订节点集事件（防泄漏）');
  const sub = join(ETS, 'commons', 'services', 'SubscriptionService.ets');
  ok('ev5.off-api', exists(sub) && /static offNodeSetChanged\(/.test(read(sub)),
    'SubscriptionService 必须提供 offNodeSetChanged');
}

console.log('-----------------------------------------');
if (fail === 0) {
  console.log(`PASSED=${pass} FAILED=0`);
  console.log('RESULT: EVENT-DRIVEN CONTRACT HOLDS');
  process.exit(0);
}
console.log(`PASSED=${pass} FAILED=${fail}`);
console.log('RESULT: EVENT-DRIVEN CONTRACT BROKEN');
process.exit(1);
