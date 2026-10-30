#!/usr/bin/env node
/**
 * 保活效果观测器（真机、长时间轮询）
 *
 * ## 观察什么
 *
 * 去掉系统长时任务（`UiGuardian.CONTINUOUS_TASK_ENABLED = false`）之后，后台存活只剩
 * VPN 扩展能力撑着：隧道本身在 `:vpn` 进程里，不受影响；但**主进程**（发通知卡、
 * 算速率、写统计的那个）随时可能被系统冻结或回收。这个脚本就是量化这件事：
 *
 *   P   主进程 pid            —— 变了 = 被系统杀掉后重启（保活失败的硬证据）
 *   V   :vpn 进程 pid         —— 没了 = 隧道进程没了，连接实际已断
 *   T   隧道网卡              —— `ifconfig` 里有 tun/utun = 隧道在
 *   W   统计文件写入时间       —— 主进程还在算/写就推进；长时间不动 = 被冻结
 *
 * 判定：
 *   MAIN_GONE   主进程消失（最严重：通知卡和速率都没人更新）
 *   RESTART     主进程 pid 变了（被杀后自己起来，说明保活断过一次）
 *   VPN_GONE    :vpn 进程消失
 *   TUN_DOWN    隧道网卡消失
 *   FROZEN      主进程在但统计文件连续 N 个周期没推进（疑似冻结/无流量写入）
 *
 * ⚠ 只读设备状态，不点击、不截图、不修改任何数据，可以长时间挂着跑。
 *
 * ## 用法
 *
 *   # 默认：每 10s 采一次，一直跑，Ctrl+C 结束并打印汇总
 *   node scripts/monitor-keepalive.mjs --device 192.168.3.146:39933
 *
 *   # 跑 30 分钟，每 15s 一次，同时落 JSONL 便于事后分析
 *   node scripts/monitor-keepalive.mjs --device 192.168.3.146:39933 --interval 15 --duration 1800
 *
 * 典型实验协议：先开始监控 → 把 TunBox 切到后台 → 熄屏 → 放着不管 30~60 分钟 →
 * 回来看汇总里的 MAIN_GONE / RESTART / FROZEN 次数和最长冻结时长。
 */
import { spawnSync } from 'node:child_process';
import { appendFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

const HDC_DEFAULT = 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe';
const BUNDLE = 'com.tunbox.client';
const PREFS = `/data/app/el2/100/base/${BUNDLE}/haps/entry/preferences`;
const STATS = `${PREFS}/tunbox_traffic_stats`;

function parseArgs(argv) {
  const out = { device: '', interval: 10, duration: 0, out: '', hdc: HDC_DEFAULT, quiet: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--device') { out.device = argv[++i]; }
    else if (a === '--interval') { out.interval = Math.max(3, Number(argv[++i]) || 10); }
    else if (a === '--duration') { out.duration = Math.max(0, Number(argv[++i]) || 0); }
    else if (a === '--out') { out.out = argv[++i]; }
    else if (a === '--hdc') { out.hdc = argv[++i]; }
    else if (a === '--quiet') { out.quiet = true; }
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
if (!args.device) {
  console.log('用法: node scripts/monitor-keepalive.mjs --device <hdc-target> [--interval 10] [--duration 0] [--out file.jsonl]');
  console.log('例:   node scripts/monitor-keepalive.mjs --device 192.168.3.146:39933');
  process.exit(1);
}

const startedAt = Date.now();
const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const outPath = resolve(args.out || `C:/tmp/keepalive-${stamp}.jsonl`);
mkdirSync(dirname(outPath), { recursive: true });

function hdc(shellCmd, timeoutMs = 8000) {
  const r = spawnSync(args.hdc, ['-t', args.device, 'shell', shellCmd], {
    encoding: 'utf8', timeout: timeoutMs, windowsHide: true
  });
  if (r.error || typeof r.stdout !== 'string') { return null; }
  return r.stdout;
}

/** 一次采样：设备时间 + 进程表 + 网卡 + 统计文件 */
function sample() {
  const raw = hdc(
    `date +%s; echo '|'; ps -ef | grep ${BUNDLE} | grep -v grep; echo '|'; ` +
    `ifconfig 2>/dev/null | grep -E '^(tun|utun|ppp)'; echo '|'; ls -l ${STATS} 2>/dev/null`, 10000);
  if (raw === null) { return null; }
  const [epochPart, psPart, netPart, lsPart] = raw.split('|');
  const epoch = Number((epochPart || '').trim()) || 0;
  const mainPid = [];
  const vpnPid = [];
  for (const line of (psPart || '').split('\n')) {
    const cols = line.trim().split(/\s+/);
    if (cols.length < 8 || line.indexOf(BUNDLE) < 0) { continue; }
    const pid = Number(cols[1]);
    if (!Number.isFinite(pid) || pid <= 0) { continue; }
    if (line.indexOf(`${BUNDLE}:vpn`) >= 0) { vpnPid.push(pid); } else { mainPid.push(pid); }
  }
  const tun = (netPart || '').trim().split('\n').filter((s) => s.trim().length > 0);
  // ls -l 输出形如：-rw-rw---- 1 20020366 20020366 488 2026-10-30 20:17 /path
  let statsMtime = 0;
  const ls = (lsPart || '').trim();
  if (ls.length > 0) {
    const m = ls.match(/(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})/);
    if (m) { statsMtime = Date.parse(`${m[1]}T${m[2]}:00+08:00`); }
  }
  return { epoch, main: mainPid, vpn: vpnPid, tun: tun.map((s) => s.split(/\s+/)[0]), statsMtime };
}

const state = {
  ticks: 0, unknown: 0,
  lastMainKey: '', lastMainPid: 0,
  mainGone: 0, restarts: 0, vpnGone: 0, tunDown: 0, frozen: 0,
  lastStatsMtime: 0, stagnantTicks: 0, maxStagnantTicks: 0,
  firstTickAt: 0, lastTickAt: 0,
  /** 是否曾观察到「连接中」（有 :vpn 进程或隧道网卡）；没连过之前的消失不算故障 */
  connectedSeen: false,
  connectedTicks: 0
};

function emit(record, events) {
  appendFileSync(outPath, `${JSON.stringify(record)}\n`);
  if (args.quiet) { return; }
  const t = ((record.at - startedAt) / 1000).toFixed(0).padStart(4, ' ');
  const mainTxt = record.main.length > 0 ? record.main.join(',') : 'GONE';
  const vpnTxt = record.vpn.length > 0 ? record.vpn.join(',') : 'GONE';
  const tunTxt = record.tun.length > 0 ? record.tun.join(',') : '-';
  const statAge = record.statsMtime > 0
    ? `${Math.max(0, Math.round((record.deviceEpoch * 1000 - record.statsMtime) / 1000))}s`
    : 'n/a';
  const flags = events.length > 0 ? `  <<< ${events.join(' ')}` : '';
  console.log(`[+${t}s] main=${mainTxt} vpn=${vpnTxt} tun=${tunTxt} statsAge=${statAge}${flags}`);
}

function tick() {
  const s = sample();
  state.ticks++;
  if (s === null) {
    state.unknown++;
    console.log(`[+${((Date.now() - startedAt) / 1000).toFixed(0)}s] sample failed (device offline? hdc 超时)`);
    return;
  }
  const at = Date.now();
  const events = [];
  const mainKey = s.main.join(',');

  if (s.main.length === 0) {
    state.mainGone++;
    events.push('MAIN_GONE');
  } else {
    if (state.lastMainPid > 0 && !s.main.includes(state.lastMainPid)) {
      state.restarts++;
      events.push(`RESTART(${state.lastMainPid}->${s.main.join(',')})`);
    }
    state.lastMainPid = s.main[0];
  }
  if (state.lastMainKey !== '' && state.lastMainKey !== mainKey && s.main.length > 0
    && events.length === 0 && state.lastMainPid !== 0 && !mainKey.includes(String(state.lastMainPid))) {
    state.restarts++;
    events.push('RESTART');
  }
  state.lastMainKey = mainKey;

  // 连接状态判定：见过 :vpn 进程或隧道网卡才算「连接中」；
  // 没连过之前进程/网卡缺失是正常的，不应记成故障。
  const connected = s.vpn.length > 0 || s.tun.length > 0;
  if (connected) {
    if (!state.connectedSeen) { state.connectedSeen = true; events.push('CONNECTED'); }
    state.connectedTicks++;
    if (s.vpn.length === 0) { state.vpnGone++; events.push('VPN_GONE'); }
    if (s.tun.length === 0) { state.tunDown++; events.push('TUN_DOWN'); }
  } else if (state.connectedSeen) {
    state.vpnGone++;
    if (s.tun.length === 0) { state.tunDown++; }
    events.push('DISCONNECTED');
  }

  if (connected && s.statsMtime > 0) {
    if (s.statsMtime === state.lastStatsMtime) {
      state.stagnantTicks++;
      state.maxStagnantTicks = Math.max(state.maxStagnantTicks, state.stagnantTicks);
      // 连续 3 个周期没推进才算疑似冻结（统计按变化写，允许短时空转）
      if (state.stagnantTicks === 3) { state.frozen++; events.push('FROZEN(stats 3 周期未推进)'); }
    } else {
      state.stagnantTicks = 0;
      state.lastStatsMtime = s.statsMtime;
    }
  } else if (!connected) {
    state.stagnantTicks = 0;
    state.lastStatsMtime = s.statsMtime;
  }

  if (state.firstTickAt === 0) { state.firstTickAt = at; }
  state.lastTickAt = at;
  emit({
    at, deviceEpoch: s.epoch, main: s.main, vpn: s.vpn, tun: s.tun,
    statsMtime: s.statsMtime, stagnantTicks: state.stagnantTicks, events
  }, events);
}

function summary() {
  const minutes = ((Date.now() - startedAt) / 60000).toFixed(1);
  const ok = state.mainGone === 0 && state.vpnGone === 0 && state.restarts === 0 && state.frozen === 0;
  const idle = state.connectedTicks === 0;
  console.log('');
  console.log('── 汇总 ─────────────────────────────────────────────');
  console.log(`时长 ${minutes} 分钟 / 采样 ${state.ticks} 次（失败 ${state.unknown} 次）`);
  console.log(`主进程消失 ${state.mainGone} 次 · 主进程重启 ${state.restarts} 次`);
  console.log(`:vpn 消失 ${state.vpnGone} 次 · 隧道网卡消失 ${state.tunDown} 次（连接中采样 ${state.connectedTicks} 次）`);
  console.log(`疑似冻结 ${state.frozen} 次 · 统计文件最长停滞 ${state.maxStagnantTicks} 个周期`);
  console.log(`结论：${idle ? '全程没检测到连接（:vpn/隧道都没出现），本次观测无意义 —— 先点「开启连接」再跑' : (ok ? '这段时间内保活是稳的（无消失/重启/冻结）' : '出现过保活异常，见上面事件标记')}`);
  console.log(`明细 JSONL：${outPath}`);
}

process.on('SIGINT', () => { summary(); process.exit(0); });

console.log(`观测开始：device=${args.device} interval=${args.interval}s` +
  `${args.duration > 0 ? ` duration=${args.duration}s` : '（Ctrl+C 结束）'}`);
console.log(outPath);

tick();
const timer = setInterval(() => {
  tick();
  if (args.duration > 0 && Date.now() - startedAt >= args.duration * 1000) {
    clearInterval(timer);
    summary();
    process.exit(0);
  }
}, args.interval * 1000);
