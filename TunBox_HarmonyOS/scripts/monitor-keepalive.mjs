#!/usr/bin/env node
/**
 * 保活观测器（真机、只读、日常使用场景）
 *
 * 设计前提：**观测期间不操作被测设备**。不点击、不截图、不 dump 界面，
 * 只执行只读 shell 命令（ps / ifconfig / ls / cat）+ 抓 hilog 缓冲。
 * 你可以正常用手机：切前后台、熄屏、进出 App、断线重连都不用管。
 *
 * ## 采什么
 *
 *   main   主进程 pid + CPU 时间（ps 的 TIME 列）—— pid 变了 = 被杀后重启
 *   vpn    :vpn 进程 pid —— 没了 = 隧道进程没了
 *   tun    vpn-tun 网卡 —— 这是本机隧道接口的真实名字（不是 tun0/utun）
 *   stats  tunbox_traffic_stats 的 mtime/大小 —— 推进说明主进程还在算/写
 *   log    hilog 里 TunBox 关键行（可关），增量去重后落 .log
 *
 * ## 怎么判
 *
 *   MAIN_GONE   连接中主进程消失            ← 保活失败（硬证据）
 *   RESTART     主进程 pid 变了             ← 被杀后自己起来，中间断过
 *   VPN_DOWN    隧道进程/网卡消失           ← 连接真断了（可能是你手动断开）
 *   CPU_STALL   主进程在但 CPU 时间不涨     ← 仅提示：可能是空闲，也可能被冻结
 *   DISCONNECTED 从连接态回到非连接态        ← 记录，不当故障
 *
 * 汇总里 MAIN_GONE / RESTART 才是保活结论，CPU_STALL 需要结合「通知卡数字是否停住」人工确认。
 *
 * ## 用法
 *
 *   # 常用：每 20s 采一次，跑 1 小时，数据追加到固定文件（被打断也不丢）
 *   node scripts/monitor-keepalive.mjs --device 192.168.3.146:39933 \
 *     --interval 20 --duration 3600 --out C:/tmp/keepalive-live.jsonl
 *
 *   # 只看已有数据出汇总（随时可以跑）
 *   node scripts/monitor-keepalive.mjs --report C:/tmp/keepalive-live.jsonl
 *
 *   # 顺带抓 hilog（每 3 轮抓一次）
 *   node scripts/monitor-keepalive.mjs --device ... --with-log --log-every 3
 */
import { spawnSync } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

const HDC_DEFAULT = 'C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe';
const BUNDLE = 'com.tunbox.client';
const TUN_IFACE = 'vpn-tun';
const PREFS = `/data/app/el2/100/base/${BUNDLE}/haps/entry/preferences`;
const STATS = `${PREFS}/tunbox_traffic_stats`;
const LOG_KEYS = /TunBox|UiGuardian|TaskProgress|guardian|continuous task|background task|onBackground|onForeground|VpnExtension|TunBoxNotifier|notification/i;

function parseArgs(argv) {
  const o = {
    device: '', interval: 20, duration: 0, out: '', report: '', hdc: HDC_DEFAULT,
    withLog: false, logEvery: 3, quiet: false, once: false
  };  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--device') { o.device = argv[++i]; }
    else if (a === '--interval') { o.interval = Math.max(5, Number(argv[++i]) || 20); }
    else if (a === '--duration') { o.duration = Math.max(0, Number(argv[++i]) || 0); }
    else if (a === '--out') { o.out = argv[++i]; }
    else if (a === '--report') { o.report = argv[++i]; }
    else if (a === '--hdc') { o.hdc = argv[++i]; }
    else if (a === '--with-log') { o.withLog = true; }
    else if (a === '--log-every') { o.logEvery = Math.max(1, Number(argv[++i]) || 3); }
    else if (a === '--once') { o.once = true; }
    else if (a === '--quiet') { o.quiet = true; }
  }
  return o;
}

const args = parseArgs(process.argv.slice(2));

/* ── 报告模式：只读已有 JSONL，出汇总 ─────────────────────────────── */
if (args.report) {
  report(args.report);
  process.exit(0);
}

if (!args.device) {
  console.log('用法: node scripts/monitor-keepalive.mjs --device <hdc-target|auto> [--interval 20] [--duration 3600] [--out file.jsonl] [--with-log]');
  console.log('      node scripts/monitor-keepalive.mjs --report <file.jsonl>');
  process.exit(1);
}

/** --device auto：取 hdc 在线列表的第一个（设备换 IP 后计划任务不用改） */
if (args.device === 'auto') {
  const r = spawnSync(args.hdc, ['list', 'targets'], { encoding: 'utf8', timeout: 10000, windowsHide: true });
  const first = (r.stdout || '').split('\n').map((s) => s.trim())
    .find((s) => s.length > 0 && s.indexOf('Empty') < 0);
  if (first === undefined) {
    console.log('没有在线设备（hdc list targets 为空）');
    process.exit(2);
  }
  args.device = first;
}

const startedAt = Date.now();
const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
const outPath = resolve(args.out || `C:/tmp/keepalive-${stamp}.jsonl`);
const logPath = outPath.replace(/\.jsonl$/, '') + '.log';
mkdirSync(dirname(outPath), { recursive: true });

/** 只读 hdc shell；spawnSync 自带超时，读不完也会被强杀，不会卡住 */
function hdc(shellCmd, timeoutMs = 10000) {
  const r = spawnSync(args.hdc, ['-t', args.device, 'shell', shellCmd], {
    encoding: 'utf8', timeout: timeoutMs, windowsHide: true, maxBuffer: 32 * 1024 * 1024
  });
  if (r.error && !r.stdout) { return null; }
  return typeof r.stdout === 'string' ? r.stdout : null;
}

function sample() {
  // 一次往返拿全部只读状态
  const raw = hdc(
    `date +%s; echo '|P|'; ps -ef | grep ${BUNDLE} | grep -v grep; ` +
    `echo '|T|'; ifconfig ${TUN_IFACE} 2>/dev/null | head -4; ` +
    `echo '|S|'; ls -l ${STATS} 2>/dev/null`);
  if (raw === null) { return null; }
  const [epochPart, psPart, tunPart, lsPart] = raw.split('|P|').length >= 2
    ? split4(raw)
    : [raw, '', '', ''];
  const epoch = Number((epochPart || '').trim()) || 0;

  const main = [];   // [{pid, cpu}]
  const vpn = [];
  for (const line of (psPart || '').split('\n')) {
    const t = line.trim();
    if (t.length === 0 || t.indexOf(BUNDLE) < 0) { continue; }
    const c = t.split(/\s+/);
    if (c.length < 7) { continue; }
    const pid = Number(c[1]);
    if (!Number.isFinite(pid) || pid <= 0) { continue; }
    const cpu = c[6] || '';
    if (t.indexOf(`${BUNDLE}:vpn`) >= 0) { vpn.push({ pid, cpu }); }
    else { main.push({ pid, cpu }); }
  }
  const tunUp = /UP|RUNNING|Link encap/i.test((tunPart || ''));
  let statsMtime = 0;
  let statsSize = 0;
  const m = (lsPart || '').match(/(\d+)\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})/);
  if (m) {
    statsSize = Number(m[1]);
    statsMtime = Date.parse(`${m[2]}T${m[3]}:00+08:00`);
  }
  return { epoch, main, vpn, tunUp, statsMtime, statsSize };
}

function split4(raw) {
  const a = raw.split('|P|');
  const epoch = a[0] || '';
  const rest = a[1] || '';
  const b = rest.split('|T|');
  const ps = b[0] || '';
  const c = (b[1] || '').split('|S|');
  return [epoch, ps, c[0] || '', c[1] || ''];
}

/** hilog 缓冲是全量 dump 且不退出：靠 spawnSync 超时强杀，取已读到的部分 */
const seenLog = new Set();
function grabLog() {
  const raw = hdc('hilog -x', 7000);
  if (raw === null) { return; }
  const fresh = [];
  for (const line of raw.split('\n')) {
    const t = line.trimEnd();
    if (t.length === 0 || !LOG_KEYS.test(t)) { continue; }
    const key = t.replace(/\s+/g, ' ').slice(0, 400);
    if (seenLog.has(key)) { continue; }
    seenLog.add(key);
    fresh.push(t);
  }
  if (fresh.length > 0) {
    appendFileSync(logPath, fresh.join('\n') + '\n');
  }
}

const st = {
  ticks: 0, failed: 0, connectedTicks: 0,
  mainGone: 0, restarts: 0, vpnDown: 0, cpuStalls: 0, disconnects: 0,
  everConnected: false, lastMainPid: 0, lastMainCpu: '', stallTicks: 0, maxStall: 0,
  lastStatsMtime: 0, connectedSince: 0, longestSessionSec: 0
};

function tick() {
  st.ticks++;
  const s = sample();
  if (s === null) {
    st.failed++;
    if (!args.quiet) { console.log(`[+${elapsed()}s] 采样失败（设备离线/超时）`); }
    return;
  }
  const connected = s.vpn.length > 0 || s.tunUp;
  const events = [];
  const mainPids = s.main.map((x) => x.pid);
  const mainCpu = s.main.length > 0 ? s.main[0].cpu : '';

  if (connected) {
    st.connectedTicks++;
    if (!st.everConnected) { st.everConnected = true; events.push('CONNECTED'); }
    if (st.connectedSince === 0) { st.connectedSince = Date.now(); }
    if (s.main.length === 0) {
      st.mainGone++;
      events.push('MAIN_GONE');
    } else if (st.lastMainPid > 0 && !mainPids.includes(st.lastMainPid)) {
      st.restarts++;
      events.push(`RESTART(${st.lastMainPid}->${mainPids.join(',')})`);
    } else if (st.lastMainCpu !== '' && mainCpu === st.lastMainCpu) {
      // CPU 时间没涨：可能真空闲，也可能被冻结。只提示，不算故障。
      st.stallTicks++;
      st.maxStall = Math.max(st.maxStall, st.stallTicks);
      if (st.stallTicks === 5) { st.cpuStalls++; events.push('CPU_STALL(5 轮 CPU 时间未涨，需看通知卡是否停更)'); }
    } else {
      st.stallTicks = 0;
    }
    if (s.vpn.length === 0 && !s.tunUp) { st.vpnDown++; events.push('VPN_DOWN'); }
    else if (s.vpn.length === 0) { events.push('VPN_PROC_GONE(网卡在)'); }
  } else if (st.everConnected) {
    st.disconnects++;
    events.push('DISCONNECTED');
    if (st.connectedSince > 0) {
      st.longestSessionSec = Math.max(st.longestSessionSec, Math.round((Date.now() - st.connectedSince) / 1000));
      st.connectedSince = 0;
    }
    st.stallTicks = 0;
  }

  if (mainPids.length > 0) { st.lastMainPid = mainPids[0]; }
  st.lastMainCpu = mainCpu;
  if (s.statsMtime > 0) { st.lastStatsMtime = s.statsMtime; }

  const record = {
    at: Date.now(), deviceEpoch: s.epoch, connected,
    main: s.main, vpn: s.vpn, tunUp: s.tunUp,
    statsMtime: s.statsMtime, statsSize: s.statsSize,
    stallTicks: st.stallTicks, events
  };
  appendFileSync(outPath, `${JSON.stringify(record)}\n`);

  if (!args.quiet) {
    const mainTxt = s.main.length > 0 ? s.main.map((x) => `${x.pid}/${x.cpu}`).join(',') : 'GONE';
    const vpnTxt = s.vpn.length > 0 ? s.vpn.map((x) => `${x.pid}/${x.cpu}`).join(',') : '-';
    const age = s.statsMtime > 0
      ? `${Math.max(0, Math.round((s.epoch * 1000 - s.statsMtime) / 1000))}s` : 'n/a';
    const flag = events.length > 0 ? `  <<< ${events.join(' ')}` : '';
    console.log(`[+${elapsed()}s] ${connected ? 'LINK' : 'idle'} main=${mainTxt} vpn=${vpnTxt} tun=${s.tunUp ? 'up' : '-'} statsAge=${age}${flag}`);
  }

  if (args.withLog && st.ticks % args.logEvery === 0) { grabLog(); }
}

function elapsed() {
  return ((Date.now() - startedAt) / 1000).toFixed(0).padStart(4, ' ');
}

function summary() {
  const mins = ((Date.now() - startedAt) / 60000).toFixed(1);
  const idle = st.connectedTicks === 0;
  const healthy = st.mainGone === 0 && st.restarts === 0 && st.vpnDown === 0;
  console.log('');
  console.log('── 本次观测汇总 ─────────────────────────────────────');
  console.log(`时长 ${mins} 分钟 / 采样 ${st.ticks} 次（失败 ${st.failed}）`);
  console.log(`连接中采样 ${st.connectedTicks} 次 · 最长连续连接 ${st.longestSessionSec}s`);
  console.log(`主进程消失 ${st.mainGone} 次 · 主进程重启 ${st.restarts} 次 · 隧道断开 ${st.vpnDown} 次`);
  console.log(`CPU 停滞提示 ${st.cpuStalls} 次（最长连续 ${st.maxStall} 轮）· 中途断开记录 ${st.disconnects} 次`);
  console.log(`结论：${idle ? '这段时间没抓到连接，无意义（先开代理再观测）'
    : (healthy ? '主进程未被杀、隧道未断 —— 保活稳' : '出现 MAIN_GONE/RESTART/VPN_DOWN，见上表事件')}`);
  console.log(`明细：${outPath}${args.withLog ? `　日志：${logPath}` : ''}`);
}

/* ── 报告模式实现 ─────────────────────────────────────────────────── */
function report(file) {
  const p = resolve(file);
  if (!existsSync(p)) {
    console.log(`找不到文件：${p}`);
    return;
  }
  const rows = readFileSync(p, 'utf8').split('\n').filter((l) => l.trim().length > 0)
    .map((l) => { try { return JSON.parse(l); } catch { return null; } })
    .filter((r) => r !== null);
  if (rows.length === 0) { console.log('文件里没有有效记录'); return; }
  const t0 = rows[0].at;
  const t1 = rows[rows.length - 1].at;
  const conn = rows.filter((r) => r.connected);
  const count = (name) => rows.filter((r) => (r.events || []).some((e) => e.startsWith(name))).length;
  let longest = 0;
  let cur = 0;
  for (const r of rows) {
    if (r.connected) { cur++; longest = Math.max(longest, cur); } else { cur = 0; }
  }
  console.log('── 汇总（来自已有数据）─────────────────────────────');
  console.log(`时间跨度 ${((t1 - t0) / 60000).toFixed(1)} 分钟 · 采样 ${rows.length} 次 · 连接中 ${conn.length} 次`);
  console.log(`主进程消失 ${count('MAIN_GONE')} · 重启 ${count('RESTART')} · 隧道断开 ${count('VPN_DOWN')} · CPU 停滞提示 ${count('CPU_STALL')}`);
  console.log(`连续连接最长 ${longest} 个采样周期`);
  const pids = [...new Set(rows.flatMap((r) => (r.main || []).map((m) => m.pid)))];
  console.log(`出现过的主进程 pid：${pids.length > 0 ? pids.join(', ') : '（无）'}${pids.length > 1 ? '  ← 多于 1 个 = 期间被杀过' : ''}`);
  const vpns = [...new Set(rows.flatMap((r) => (r.vpn || []).map((m) => m.pid)))];
  console.log(`出现过的 :vpn pid：${vpns.length > 0 ? vpns.join(', ') : '（无）'}`);
}

process.on('SIGINT', () => { summary(); process.exit(0); });

console.log(`观测开始（只读，不操作设备）：${args.device}　间隔 ${args.interval}s` +
  `${args.duration > 0 ? `　时长 ${args.duration}s` : '　Ctrl+C 结束'}`);
console.log(`数据：${outPath}${args.withLog ? `\n日志：${logPath}` : ''}`);
console.log('提示：期间正常用手机即可，熄屏、切前后台都不影响。');

if (args.once) {
  // 单次采样模式：给系统定时器（schtasks）每分钟拉起一个独立进程，
  // 不常驻、不占会话；设备断线也只是一个空采样。
  tick();
  process.exit(0);
}

tick();
const timer = setInterval(() => {
  tick();
  if (args.duration > 0 && Date.now() - startedAt >= args.duration * 1000) {
    clearInterval(timer);
    summary();
    process.exit(0);
  }
}, args.interval * 1000);
