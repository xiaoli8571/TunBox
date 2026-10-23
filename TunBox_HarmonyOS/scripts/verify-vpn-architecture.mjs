#!/usr/bin/env node
/**
 * 架构与性能改造自动化验证（对应《SSRVPN HarmonyOS + mihomo VPN 架构与性能优化建议》
 * 全部尚未达标项）。分两层给出证据：
 *
 *   A) 可执行验证（真逻辑）：用 Node 24 原生 TS type-stripping 直接加载
 *      TunnelAuthority.ets 与 VpnRecoveryPolicy.ets（二者零 SDK 依赖，是 Extension
 *      运行态判定的单一真值源），对其纯函数逐分支断言，并仿真以下场景：
 *        - 后台 / 锁屏 / UI 进程被系统回收后：打开 App 直接还原真实 VPN 状态
 *        - 网络切换（Wi-Fi↔蜂窝↔断网）→ MTU 动态、恢复编排、去抖/退避
 *        - 内核崩溃 → 有限热恢复 → 升级一次 TUN 重建 → 耗尽 → Kill Switch 阻断
 *        - 弱网（恢复退避封顶、重连风暴抑制）
 *        - 长时间运行（恢复计数在存活时归零，不跨事件累计）
 *        - 心跳从 3s 定周期改为低频/事件驱动（陈旧窗口判定仍成立）
 *
 *   B) 源码级不变量断言：对 ClashConfigGenerator / VpnExtensionAbility /
 *      ConnectionOrchestrator 的真实 .ets 源文本，断言关键配置与结构约束
 *      （IPv4-only、DNS 分流/fallback/缓存、keepalive/连接池、动态 MTU 接线、
 *      移除周期心跳、热重载/热切换、Extension 状态消费）确实存在。
 *      这是对无法在离线 Node 里执行的 SDK 依赖代码的静态回归护栏，明确标注为
 *      SOURCE 断言，不冒充真机运行结果。
 *
 * 用法: node scripts/verify-vpn-architecture.mjs
 * 退出码: 0 = 全部通过；1 = 有断言失败
 */
import { readFileSync, readdirSync, writeFileSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';

const here = dirname(fileURLToPath(import.meta.url));
const appRoot = resolve(here, '..');
const svcDir = join(appRoot, 'entry', 'src', 'main', 'ets', 'commons', 'services');
const etsRoot = join(appRoot, 'entry', 'src', 'main', 'ets');

let passed = 0;
const failures = [];
function record(label, cond, detail) {
  if (cond) { passed += 1; } else { failures.push(label + (detail ? ' -> ' + detail : '')); }
}
function eq(label, actual, expected) {
  record(label, Object.is(actual, expected), 'expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
}
function ok(label, cond) { record(label, cond === true, 'expected true, got ' + JSON.stringify(cond)); }
function has(label, text, needle) { record(label, text.includes(needle), 'missing: ' + needle); }
function notHas(label, text, needle) { record(label, !text.includes(needle), 'must NOT contain: ' + needle); }

// ── A) 加载真实纯逻辑源码（零 SDK 依赖，直接 type-strip 导入）───────────
const sandbox = join(tmpdir(), 'ssrvpn-arch-verify-' + process.pid);
rmSync(sandbox, { recursive: true, force: true });
mkdirSync(sandbox, { recursive: true });
writeFileSync(join(sandbox, 'package.json'), JSON.stringify({ type: 'module' }), 'utf8');

function stageFrom(absPath, outName) {
  const src = readFileSync(absPath, 'utf8');
  const out = join(sandbox, outName + '.ts');
  writeFileSync(out, src, 'utf8');
  return out;
}
const taPath = stageFrom(join(svcDir, 'TunnelAuthority.ets'), 'TunnelAuthority');
const rpPath = stageFrom(join(svcDir, 'VpnRecoveryPolicy.ets'), 'VpnRecoveryPolicy');

let TA, RP;
try {
  TA = await import(pathToFileURL(taPath).href);
  RP = await import(pathToFileURL(rpPath).href);
} catch (e) {
  console.error('FATAL: 加载纯逻辑 .ets 源码失败: ' + (e && e.stack ? e.stack : e));
  process.exit(1);
}

// ── TunnelAuthority.parseExtensionStatus ────────────────────────────────
{
  const good = TA.parseExtensionStatus('{"phase":"running","mtu":1360,"netType":"cellular","coreAlive":true,"recoveryAttempts":0,"rebuilds":1,"seq":7,"ts":111,"detail":"tun-rebuilt:mtu-change"}');
  ok('parse.ok', good.ok === true);
  eq('parse.phase', good.phase, 'running');
  eq('parse.mtu', good.mtu, 1360);
  eq('parse.netType', good.netType, 'cellular');
  ok('parse.coreAlive', good.coreAlive === true);
  eq('parse.rebuilds', good.rebuilds, 1);
  eq('parse.seq', good.seq, 7);

  const notAlive = TA.parseExtensionStatus('{"phase":"leak-blocked","mtu":1400,"netType":"none","coreAlive":false,"recoveryAttempts":3,"rebuilds":0,"seq":9,"ts":222,"detail":"network-lost"}');
  ok('parse.coreAlive.false', notAlive.coreAlive === false);
  eq('parse.phase.blocked', notAlive.phase, 'leak-blocked');

  eq('parse.empty.ok=false', TA.parseExtensionStatus('').ok, false);
  eq('parse.garbage.ok=false', TA.parseExtensionStatus('not-json').ok, false);
  eq('parse.nophase.ok=false', TA.parseExtensionStatus('{"mtu":1400}').ok, false);
}

// ── TunnelAuthority.deriveUiPhase（UI 进程回收后还原真实状态）────────────
{
  const running = TA.parseExtensionStatus('{"phase":"running","mtu":1400,"netType":"wifi","coreAlive":true,"recoveryAttempts":0,"rebuilds":0,"seq":1,"ts":1,"detail":""}');
  eq('ui.running.fresh', TA.deriveUiPhase(running, true), 'connected');
  eq('ui.running.stale', TA.deriveUiPhase(running, false), 'stale');
  const rec = TA.parseExtensionStatus('{"phase":"recovering","mtu":1400,"netType":"wifi","coreAlive":false,"recoveryAttempts":1,"rebuilds":0,"seq":2,"ts":1,"detail":""}');
  eq('ui.recovering', TA.deriveUiPhase(rec, false), 'recovering');
  const blk = TA.parseExtensionStatus('{"phase":"leak-blocked","mtu":1400,"netType":"none","coreAlive":false,"recoveryAttempts":3,"rebuilds":2,"seq":3,"ts":1,"detail":""}');
  eq('ui.leak-blocked', TA.deriveUiPhase(blk, false), 'leak-blocked');
  const stopped = TA.parseExtensionStatus('{"phase":"stopped","mtu":1400,"netType":"wifi","coreAlive":false,"recoveryAttempts":0,"rebuilds":0,"seq":4,"ts":1,"detail":""}');
  eq('ui.stopped', TA.deriveUiPhase(stopped, true), 'disconnected');
  eq('ui.nostatus.fresh', TA.deriveUiPhase(new TA.ExtensionStatusView(), true), 'connected');
  eq('ui.nostatus.stale', TA.deriveUiPhase(new TA.ExtensionStatusView(), false), 'stale');
}

// ── TunnelAuthority.resolveAuthority（低频租约陈旧窗口判定）───────────────
{
  ok('auth.fresh.desired', TA.resolveAuthority(true, 3000, true).connected === true);
  ok('auth.stale.blocked', TA.resolveAuthority(true, TA.HEARTBEAT_STALE_MS + 1, false).connected === false);
  eq('auth.stale.reason', TA.resolveAuthority(true, TA.HEARTBEAT_STALE_MS + 1, false).reason, 'heartbeat-timeout');
  ok('auth.marker.keepalive', TA.resolveAuthority(true, -1, true).coreAlive === true);
  ok('auth.user-disc', TA.resolveAuthority(false, 0, true).connected === false);
  eq('auth.window', TA.HEARTBEAT_STALE_MS, 15000);
}

// ── VpnRecoveryPolicy: MTU 动态按承载 ────────────────────────────────────
eq('mtu.wifi', RP.mtuForNetType('wifi'), 1400);
eq('mtu.ethernet', RP.mtuForNetType('ethernet'), 1400);
eq('mtu.cellular', RP.mtuForNetType('cellular'), 1360);
eq('mtu.none.baseline', RP.mtuForNetType('none'), 1400);
eq('mtu.unknown.baseline', RP.mtuForNetType('unknown'), 1400);

// ── VpnRecoveryPolicy: 退避封顶（弱网重连风暴抑制）───────────────────────
eq('recover.delay0', RP.coreRecoveryDelayMs(0), 1000);
eq('recover.delay1', RP.coreRecoveryDelayMs(1), 2000);
eq('recover.delay2', RP.coreRecoveryDelayMs(2), 4000);
ok('recover.delayMonotonic', RP.coreRecoveryDelayMs(0) < RP.coreRecoveryDelayMs(1) && RP.coreRecoveryDelayMs(1) < RP.coreRecoveryDelayMs(2));
eq('recover.delayCap', RP.coreRecoveryDelayMs(20), 8000);
eq('recover.delayNeg', RP.coreRecoveryDelayMs(-3), 1000);
eq('rebuild.delay0', RP.tunnelRebuildDelayMs(0), 1500);
eq('rebuild.delay1', RP.tunnelRebuildDelayMs(1), 3000);
eq('rebuild.delayCap', RP.tunnelRebuildDelayMs(30), 8000);

// ── VpnRecoveryPolicy: Kill Switch / 泄漏阻断判定 ────────────────────────
eq('ks.userStopped.down', RP.leakSwitchDecision(true, 'wifi', false), 'down');
eq('ks.netlost.blocked', RP.leakSwitchDecision(false, 'none', false), 'leak-blocked');
eq('ks.coreDeadNetUp.recover', RP.leakSwitchDecision(false, 'wifi', false), 'recover');
eq('ks.alive.keep', RP.leakSwitchDecision(false, 'wifi', true), 'keep');

// ── VpnRecoveryPolicy: decideRecoveryAction 全场景状态机 ─────────────────
function inp(o) {
  const i = new RP.RecoveryInput();
  Object.assign(i, o);
  return i;
}
{
  eq('dec.none.alive', RP.decideRecoveryAction(inp({ coreAlive: true })), 'none');
  eq('dec.none.userStopped', RP.decideRecoveryAction(inp({ userStopped: true, coreAlive: false })), 'none');
  eq('dec.none.rebuilding', RP.decideRecoveryAction(inp({ rebuilding: true, coreAlive: false })), 'none');
  eq('dec.none.noConn', RP.decideRecoveryAction(inp({ connectionUp: false, coreAlive: false, netType: 'wifi' })), 'none');
  eq('dec.blocked.netlost', RP.decideRecoveryAction(inp({ coreAlive: false, netType: 'none', connectionUp: true })), 'leak-blocked');
  eq('dec.core0', RP.decideRecoveryAction(inp({ coreAlive: false, netType: 'wifi', connectionUp: true, recoveryAttempts: 0 })), 'core-recovery');
  eq('dec.core2', RP.decideRecoveryAction(inp({ coreAlive: false, netType: 'wifi', connectionUp: true, recoveryAttempts: 2 })), 'core-recovery');
  eq('dec.exhaust.rebuild', RP.decideRecoveryAction(inp({ coreAlive: false, netType: 'wifi', connectionUp: true, recoveryAttempts: 3, tunnelRebuilds: 0 })), 'tun-rebuild');
  eq('dec.exhaust.block', RP.decideRecoveryAction(inp({ coreAlive: false, netType: 'wifi', connectionUp: true, recoveryAttempts: 3, tunnelRebuilds: 2 })), 'leak-blocked');
}

// ── 场景仿真：内核崩溃 → 有限热恢复 → 一次 TUN 重建 → 耗尽 → 阻断 ─────────
{
  let attempts = 0, rebuilds = 0, actions = [];
  let coreAlive = false;
  for (let step = 0; step < 20 && !coreAlive; step++) {
    const a = RP.decideRecoveryAction(inp({ coreAlive: false, netType: 'wifi', connectionUp: true, recoveryAttempts: attempts, tunnelRebuilds: rebuilds }));
    actions.push(a);
    if (a === 'core-recovery') {
      attempts++;
      if (attempts >= 2) { coreAlive = true; } // 第 2 次恢复成功（弱网下多次才稳）
    } else if (a === 'tun-rebuild') { rebuilds++; coreAlive = true; }
    else if (a === 'leak-blocked') { break; }
  }
  ok('sim.core-crash.recovers', coreAlive === true);
  ok('sim.core-crash.first.core-recovery', actions[0] === 'core-recovery');
  ok('sim.core-crash.bounded', attempts <= RP.MAX_CORE_RECOVERY_ATTEMPTS && rebuilds <= RP.MAX_TUNNEL_REBUILDS);
}
// ── 场景仿真：无法恢复的持续内核死亡 → 必然收敛到 leak-blocked（不漏） ──────
{
  let attempts = 0, rebuilds = 0, last = '';
  for (let step = 0; step < 30; step++) {
    const a = RP.decideRecoveryAction(inp({ coreAlive: false, netType: 'wifi', connectionUp: true, recoveryAttempts: attempts, tunnelRebuilds: rebuilds }));
    last = a;
    if (a === 'core-recovery') { attempts++; }
    else if (a === 'tun-rebuild') { rebuilds++; }
    else if (a === 'leak-blocked') { break; }
  }
  eq('sim.hopeless.converge.blocked', last, 'leak-blocked');
  ok('sim.hopeless.attemptsCapped', attempts === RP.MAX_CORE_RECOVERY_ATTEMPTS);
  ok('sim.hopeless.rebuildsCapped', rebuilds === RP.MAX_TUNNEL_REBUILDS);
}
// ── 场景仿真：断网期间不消耗恢复预算，保持阻断 ──────────────────────────
{
  const a = RP.decideRecoveryAction(inp({ coreAlive: false, netType: 'none', connectionUp: true, recoveryAttempts: 0, tunnelRebuilds: 0 }));
  eq('sim.netlost.noBudgetBurn', a, 'leak-blocked');
}
// ── 场景仿真：网络恢复后应重新具备恢复能力（计数归零）───────────────────
{
  ok('sim.recovered.reset', RP.shouldResetRecovery(true, 'wifi') === true);
  ok('sim.recovered.reset.cell', RP.shouldResetRecovery(true, 'cellular') === true);
  ok('sim.notAlive.noReset', RP.shouldResetRecovery(false, 'wifi') === false);
  ok('sim.netNone.noReset', RP.shouldResetRecovery(true, 'none') === false);
}
// ── 场景仿真：长稳（存活 tick 不触发动作）───────────────────────────────
{
  let actionsIn20 = 0;
  for (let s = 0; s < 20; s++) {
    const a = RP.decideRecoveryAction(inp({ coreAlive: true, netType: 'wifi', connectionUp: true }));
    if (a !== 'none') actionsIn20++;
  }
  eq('sim.longrun.idle.noActions', actionsIn20, 0);
}

// ══════════════════════════════════════════════════════════════════════
// B) 源码级不变量断言（真实 .ets 源文本）
// ══════════════════════════════════════════════════════════════════════
const genSrc = readFileSync(join(svcDir, 'ClashConfigGenerator.ets'), 'utf8');
{
  // ── IPv6 双栈（设置页单开关，默认开）──
  // 2026-10-21 二次定案：v6 必须走代理 ⇒ DNS 回 fake-ip，ipv6 开时同时下发
  // fake-ip-range6 = TUN 自己的 fdfe:dcba:9876::/64。真机 /proc/net/ipv6_route 取证：
  // 平台只装 LinkAddress 前缀派生的 on-link 路由（/126 → /126，/64 → /64），所以 range6
  // 与 TUN 前缀必须成对：只写 range6（旧 /126）= 假 v6 无路由的黑洞；只放大前缀不写
  // range6 = AAAA 恒空。两者都由同一个 ipv6Enabled 驱动，没有第二个开关。
  has('gen.fake-ip-mode', genSrc, "lines.push('  enhanced-mode: fake-ip')");
  has('gen.fake-ip-range', genSrc, "lines.push('  fake-ip-range: 198.18.0.1/16')");
  has('gen.fake-ip-range6', genSrc, "lines.push('  fake-ip-range6: fdfe:dcba:9876::/64')");
  has('gen.fake-ip-filter', genSrc, "lines.push('  fake-ip-filter:')");
  notHas('gen.no.store-fake-ip', genSrc, 'store-fake-ip:');
  notHas('gen.no.redir-host-line', genSrc, 'enhanced-mode: redir-host');
  const extVpnSrc = readFileSync(join(appRoot, 'entry', 'src', 'main', 'ets',
    'vpnability', 'VpnExtensionAbility.ets'), 'utf8');
  has('ext.tun-v6-address-is-pool-gateway', extVpnSrc,
    "const TUN_ADDRESS_V6 = 'fdfe:dcba:9876::1';");
  has('ext.tun-v6-prefix-64', extVpnSrc, 'const TUN_PREFIX_V6 = 64;');
  has('gen.ipv6-from-flag', genSrc, "lines.push('ipv6: ' + (ipv6Enabled ? 'true' : 'false'))");
  has('gen.dns.ipv6-from-flag', genSrc, "lines.push('  ipv6: ' + (ipv6Enabled ? 'true' : 'false'))");
  notHas('gen.no.hardcoded-ipv6-false', genSrc, "lines.push('ipv6: false')");
  // `disable-ipv6` 不是 mihomo 的顶层键（非 strict unmarshal ⇒ 静默忽略的伪键）：必须彻底不再产出。
  notHas('gen.no.disable-ipv6', genSrc, "lines.push('disable-ipv6: true')");
  // tun.inet6-address 仍不声明：v6 地址是通过 VpnConfig.addresses 注入已有 fd 的 TUN，
  // 不是让内核自建 TUN，声明了反而会与注入 fd 冲突。
  notHas('gen.no.inet6-address', genSrc, 'inet6-address');
  // DNS 恒接管（2026-10-21 产品定案：设置页开关删除）：整段 dns 无条件产出。
  has('gen.dns.always-emitted', genSrc,
    'ClashConfigGenerator.pushDnsSection(lines, settings, dnsPort, useGeoip, ipv6Enabled, blockSites,');
  notHas('gen.dns.no-enable-false-branch', genSrc, "lines.push('  enable: false')");
  ok('gen.dns.no-override-setting', !genSrc.includes('dnsOverrideEnabled'));
  has('gen.keepalive-idle', genSrc, 'keep-alive-idle:');
  has('gen.keepalive-interval', genSrc, 'keep-alive-interval:');
  has('gen.udp-timeout', genSrc, 'udp-timeout:');
  has('gen.tcp-concurrent', genSrc, 'tcp-concurrent: true');
  has('gen.unified-delay', genSrc, 'unified-delay: true');
  has('gen.dns.fallback', genSrc, "lines.push('  fallback:')");
  // 坑 40：fallback 非空会让内核在 config.Parse 阶段加载 MMDB（默认
  // fallback-filter.geoip=true），geoip.metadb 未就绪时启动被联网下载挂死。
  // 因此 fallback 必须被 useGeoip 包住（与 GEOIP 规则同开关）。
  has('gen.dns.fallback-guarded', genSrc, 'if (useGeoip) {');
  notHas('gen.dns.no.explicit-fallback-filter', genSrc, "lines.push('  fallback-filter:')");
  // ── 内核 smart 组（自动选择 / LightGBM）──────────────────────────────────
  // 与坑 24/40 同类：smart 组一旦声明，内核 GetModel() 会在启动路径同步下载
  // Model.bin（实测 90.1s 阻塞）。所以整块必须被 useSmart 约束，
  // 且 prefer-asn 必须显式 false（否则 geodata.InitASN() 同样同步拉 ASN.mmdb）。
  has('gen.smart.type', genSrc, "lines.push('    type: smart')");
  has('gen.smart.gated', genSrc, 'const emitSmart = useSmart &&');
  has('gen.smart.uselightgbm', genSrc, "lines.push('    uselightgbm: true')");
  has('gen.smart.prefer-asn-false', genSrc, "lines.push('    prefer-asn: false')");
  has('gen.smart.collectdata-false', genSrc, "lines.push('    collectdata: false')");
  has('gen.smart.group-name', genSrc, 'SMART_GROUP_NAME');
  has('gen.smart.no-single-node', genSrc, 'validNodes.length >= 2');
  has('gen.dns.cache-arc', genSrc, 'cache-algorithm: arc');
  has('gen.dns.disable-cache-false', genSrc, 'disable-cache: false');
  has('gen.dns.strategy', genSrc, 'strategy: prefer_ipv4');
  has('gen.dns.proxy-server-nameserver', genSrc, 'proxy-server-nameserver:');
  // dns-hijack 必须恒开（内核 DNS 恒启用）：任何条件包裹都会重现「设备指过来但内核没接管」。
  has('gen.dns.hijack-any53', genSrc, "lines.push('    - any:53')");
  notHas('gen.dns.no-hijack-gate', genSrc, 'dnsOverrideEnabled');
  // C22：mihomo RawConfig.Profile 的正确键名是 `store-selected`
  // （`store-selections` 是错的 —— 内核不认这个键，配置里的「记住选中节点」不生效）
  has('gen.profile.store-selected', genSrc, 'store-selected: true');
  // C22：`find-process-mode` 是 string 字段，必须加引号（避免与布尔写法混淆）
  has('gen.find-process-off', genSrc, 'find-process-mode: "off"');
  // log-level 默认 warning：实现改为动态白名单（debug/info/warning/error/silent，
// 非法值回落 warning），断言改为检查回落分支仍包含 'warning'（保持默认口径不变）。
has('gen.log-warning', genSrc, "'warning'));");
  has('gen.auto-route-false', genSrc, 'auto-route: false');
}

const extSrc = readFileSync(join(etsRoot, 'vpnability', 'VpnExtensionAbility.ets'), 'utf8');
{
  // 双栈 TUN：::/0 与 isIPv6Accepted:true 必须同时出现 —— 缺前者 v6 不进隧道（泄漏），
  // 缺后者平台不接受 v6 地址。两条分支都要在（开关关闭时仍是纯 IPv4）。
  has('ext.ipv6Accepted-true', extSrc, 'isIPv6Accepted: true');
  has('ext.ipv6Accepted-false', extSrc, 'isIPv6Accepted: false');
  // v6 默认路由写法与 NekoBox4Harmony 一致：不写 family、gateway 用 v4 占位。
  // 写 `family: 2` 时真机平台会静默丢弃这条路由（v6 继续从 wlan0 泄漏）。
  has('ext.ipv6-route', extSrc, "destination: { address: { address: '::' }, prefixLength: 0 }");
  has('ext.ipv6-address-const', extSrc, "TUN_ADDRESS_V6 = 'fdfe:dcba:9876::1'");
  // 开关必须从**生成的 YAML** 读回，不能在 want/设置里另存一份 ——
  // 否则 TUN 与内核会分叉（v6 黑洞或泄漏）。
  has('ext.tun-flags-from-yaml', extSrc, 'readTunFlagsFromConfig(configPath)');
  // DNS 恒接管：dnsAddresses 恒为 sentinel，不能再有条件表达式（那是旧开关的残留）。
  has('ext.dns-always-sentinel', extSrc, 'const dnsAddresses: string[] = DNS_SERVERS;');
  ok('ext.no-dns-override-setting', !extSrc.includes('dnsOverride'));
  ok('ext.no-readNestedBool', !extSrc.includes('readNestedBool'));
  // DNS 必须指向 TUN 内 sentinel（对齐 FlClash VpnService.kt:300 `DNS = "198.18.0.2"`），
  // 不能是公共 DNS：后者能否被 `dns-hijack: any:53` 截住取决于默认路由，
  // 一旦失效就是明文直连 + QNAME 外泄。
  has('ext.dns-servers-tun-sentinel', extSrc, "DNS_SERVERS = ['172.19.0.2']");
  notHas('ext.dns-servers-no-public-dns', extSrc, "DNS_SERVERS = ['223.5.5.5'");
  // 2026-10-21：ipv6 的读取不再用「整行字面量」正则。覆盖层经 C17 结构化合并后
  // 可能出现 `ipv6: "true"` / `ipv6: yes`；旧正则对它们一律返回 false ⇒ TUN 静默
  // 退回「IPv4-only」，而内核仍按 YAML 开着双栈 —— 正是本文件头部警告的
  // 「TUN 与内核不一致」。
  has('ext.tun-flags-ipv6-tolerant', extSrc, "readTopLevelBool(text, 'ipv6')");
  has('ext.mtu-from-active', extSrc, 'mtu: this.activeMtu');
  has('ext.attachTun-activeMtu', extSrc, 'attachTun(tunFd, this.activeMtu)');
  has('ext.uses-policy', extSrc, "from '../commons/services/VpnRecoveryPolicy'");
  has('ext.mtuForNetType', extSrc, 'mtuForNetType(netType)');
  has('ext.coreRecoveryDelay', extSrc, 'coreRecoveryDelayMs(');
  has('ext.tunnelRebuildDelay', extSrc, 'tunnelRebuildDelayMs(');
  has('ext.watchNetwork', extSrc, 'new NetworkStateWatcher()');
  has('ext.coreMonitor', extSrc, 'startCoreMonitor');
  has('ext.networkListenerImpl', extSrc, 'implements NetworkStateListener');
  has('ext.statusFile', extSrc, "STATUS_FILE = 'vpn_status.json'");
  has('ext.writeStatus', extSrc, 'private writeStatus(');
  has('ext.lease', extSrc, 'touchLivenessLease(');
  has('ext.recoverCoreNoTun', extSrc, 'scheduleCoreRecovery');
  has('ext.rebuildTun', extSrc, 'private async rebuildTunnel');
  has('ext.ensureConfigMtu', extSrc, 'ensureConfigMtu()');
  has('ext.publishStatus', extSrc, 'publishStateSnapshot(');
  // 移除 3s 定周期心跳：不应再有周期 setInterval 写心跳 / HEARTBEAT_INTERVAL_MS 常量
  notHas('ext.no-heartbeat-interval-const', extSrc, 'HEARTBEAT_INTERVAL_MS');
  notHas('ext.no-periodic-heartbeat-fn', extSrc, 'startHeartbeat(');
  notHas('ext.no-3000-ms', extSrc, '3000)');
}

const orchSrc = readFileSync(join(svcDir, 'ConnectionOrchestrator.ets'), 'utf8');
const builderSrc = readFileSync(join(etsRoot, 'commons', 'config', 'RuntimeConfigBuilder.ets'), 'utf8');
const pageSrc = readFileSync(join(etsRoot, 'pages', 'NodeSelectionPage.ets'), 'utf8');
const subsSrc = readFileSync(join(svcDir, 'SubscriptionService.ets'), 'utf8');
const settingsSrc = readFileSync(join(etsRoot, 'commons', 'models', 'AppSettings.ets'), 'utf8');
{
  has('orch.consume-extension-status', orchSrc, 'privateFs.readCapped');
  has('orch.extensionStatus', orchSrc, 'extensionStatus()');
  has('orch.deriveUiPhase', orchSrc, 'deriveUiPhase(');
  has('orch.statusFileConst', orchSrc, "EXTENSION_STATUS_FILE = 'vpn_status.json'");
  has('orch.reloadHot', orchSrc, 'async reloadRulesHot');
  has('orch.applyRulesChanged', orchSrc, 'async applyRulesChanged');
  has('orch.switchNodeHot', orchSrc, 'async switchNodeHot');
  has('orch.reloadFromPath', orchSrc, 'this.api.reloadFromPath');
  // IPv6 双栈（默认开）：生成器调用的那一个参数由 settings.ipv6Enabled 决定，
  // 唯一入口仍是 RuntimeConfigBuilder（下面断言参数形状，防止有人改回硬编码 false）。
  has('orch.ipv6-from-settings', builderSrc, 'profile.settings.ipv6Enabled !== false');
  has('orch.ipv6-param-passed', builderSrc, 'options.useGeoip, ipv6Enabled, hosts, tunEnabled');
  // 仍然不允许「把 IPv6 再探测一遍」的老入口：开关是唯一决策源，不做运行时二次判定。
  ok('orch.no-ipv6-detect-call', !orchSrc.includes('Ipv6Detector.hasIPv6'));
  // DNS 恒接管后不再有「本次连接是否覆写 DNS」的快照位：残留即两份真源。
  ok('orch.no-dns-override-flag', !orchSrc.includes('dnsOverride'));
  // IPv6 探针：redir-host 下 AAAA 来自真实上游 ⇒ 「拿不到」就是真故障，
  // 只保留 pass / fail 两条分支，不再按旧开关把已知限制记成 skip。
  const probeSrc = readFileSync(join(svcDir, 'OrchestratorHealthProbes.ets'), 'utf8');
  has('probe.ipv6-pass-real-aaaa', probeSrc, "'IPv6 双栈生效（AAAA 解析正常）'");
  ok('probe.ipv6-no-override-branch', !probeSrc.includes('isDnsOverrideEnabled'));
  ok('probe.ipv6-no-known-limitation-skip', !probeSrc.includes('这是已知限制，不是故障'));
  has('probe.ipv6-no-restart-repair', probeSrc, "'当前网络/运营商未提供 IPv6");
  notHas('probe.ipv6-no-restart-tunnel-repair', probeSrc,
    "'请重启隧道；仍失败则检查上游 DNS 是否屏蔽 AAAA', 'restart-clash-api'");
  // ── smart 组在编排层的接线 ──────────────────────────────────────────────
  has('orch.smart.model-ready-check', orchSrc, 'private isSmartModelReady()');
  has('orch.smart.magic-tree', orchSrc, '0x74 && b[1] === 0x72');
  // 内置 rawfile 铺盘是首选路径：纯联网下载在国内基本不可用
  // （jsdelivr 取不到 release 附件 → 404；更可用的 gh-proxy 限速严重）
  has('orch.smart.seed-from-rawfile', orchSrc, 'private seedSmartModelFromRawfile()');
  has('orch.smart.rawfile-api', orchSrc, "getRawFileContentSync('Model.bin')");
  has('orch.smart.seed-first', orchSrc,
    'this.seedSmartModelFromRawfile() || this.isSmartModelReady()');
  has('orch.smart.background-download', orchSrc, 'downloadSmartModelInBackground(source');
  // ── 2026-10-22 真机回归：订阅页「自动选择」入口必须跟着模型文件实时显隐 ──────
  // 旧实现：build 里直接调 isSmartModelAvailable()（方法调用，不读任何状态）⇒
  // ArkUI 不把这个分支登记成依赖，用户在设置里删掉 Model.bin、回到订阅页，
  // 卡片还挂着（用户实锤「我删了，没有隐藏」）。现在 seq 变化 ⇒ @Watch 重算 @State。
  {
    const subPageSrc = readFileSync(join(etsRoot, 'pages', 'SubscriptionPage.ets'), 'utf8');
    has('sub.smart.seq-watch', subPageSrc, "@Watch('onSmartModelSeq')");
    has('sub.smart.guard-reads-state', subPageSrc, 'return this.smartModelReady;');
    has('sub.smart.state-recomputed', subPageSrc,
      'this.smartModelReady = ConnectionOrchestrator.instance().isSmartModelAvailable();');
    // 删除与下载成功都必须 bump 信号（只删不装 / 只装不删 都会让入口状态停在旧值）
    const seqBumps = orchSrc.match(/setOrCreate<number>\('smart_model_seq'/g) ?? [];
    ok('orch.smart.mutations-bump-seq', seqBumps.length >= 2, `${seqBumps.length} 处`);
  }
  // 模型准备必须与 autoSelectMode 解耦：默认就是 manual，只在 auto 下准备
  // 会让用户切到 auto 后还要再多等一轮连接
  has('orch.smart.prep-any-mode', orchSrc, 'if (!smartReady) {');
  // smart 组只由 auto 模式启用 —— 决策已收口到唯一生成入口的 decideRuntimeOptions()。
  has('orch.smart.gated-by-auto', builderSrc,
    'settings.autoSelectMode === AutoSelectModes.AUTO && profile.smartModelReady');
  // 热重载复用同一份事实位（模型是否就绪），由 builder 重新做同一处决策 ——
  // 隧道与热重载不可能因为「决策点不同」而声明出不同的 smart 组。
  has('orch.smart.reused-on-reload', orchSrc, 'this.lastSmartModelReady');
  // 关键：auto+smart 时不能把 PROXY 钉到具体节点，否则内核按连接选点被彻底架空
  has('orch.smart.pin-group', orchSrc, 'pinSmartGroup');
  has('orch.smart.select-group', orchSrc, 'ClashConfigGenerator.SMART_GROUP_NAME');
  // UI 入口：smart 组只在内核配置里，而节点列表页的数据源是**订阅**（subs.nodes），
  // 所以不补一个合成行，用户在「全部节点」里永远看不到它。
  has('orch.smart.ui-ready-api', orchSrc, 'ensureSmartModelReady()');
  has('page.smart.row-id', pageSrc, "const SMART_ROW_ID = '__smart_group__'");
  has('page.smart.mk-row', pageSrc, 'private mkSmartRow()');
  has('page.smart.selectable', pageSrc, 'private smartSelectable()');
  has('page.smart.unshift', pageSrc, 'rows.unshift(this.mkSmartRow())');
  has('page.smart.row-flag', pageSrc, 'isSmart?: boolean');
  // 合成行没有 server/port：必须排除在测速之外，否则永远显示「超时」
  has('page.smart.skip-latency', pageSrc, 'if (row.isSmart === true) {');
  has('page.smart.skip-delete', pageSrc, 'if (row.isSmart === true) {');
  // 选中合成行的语义 = 切到自动模式（不是把它当节点传给 reconnectWithNode）
  has('page.smart.select-sets-auto', pageSrc, 'this.settings.autoSelectMode = AutoSelectModes.AUTO');
  // 真机踩过的坑：auto 模式下点真实节点，preferredNodeId 被存下但 connect() 里
  // pinSmartGroup 仍把 PROXY 指向 smart 组 → 手动选择被静默架空（"没法手动选节点"）。
  // 手动点真实节点必须退出自动模式。
  {
    const pick = /private async selectNode\(node: ProxyNode\)[\s\S]*?\n  \}/.exec(pageSrc);
    const pickSrc = pick ? pick[0] : '';
    ok('page.select.manual-exits-auto',
      pickSrc.includes('this.settings.autoSelectMode = AutoSelectModes.MANUAL;'));
    // 顺序必须在设置 preferredNodeId 之前，否则中间态是"auto + 新偏好"，语义混乱
    const exitAt = pickSrc.indexOf('AutoSelectModes.MANUAL');
    const prefAt = pickSrc.indexOf('this.settings.preferredNodeId = node.id;');
    ok('page.select.exit-before-pref', exitAt >= 0 && prefAt > exitAt);
    // 横幅读的是 @State，不同步会继续显示"自动选点"，与落库值矛盾
    ok('page.select.syncs-banner-state', pickSrc.includes('this.autoSelectMode = AutoSelectModes.MANUAL;'));
    // 真实节点分支绝不能带 SMART_ROW_ID 的提前 return
    ok('page.select.real-node-not-shortcircuited',
      !/node\.id === SMART_ROW_ID[\s\S]{0,1200}?this\.settings\.preferredNodeId = node\.id;[\s\S]{0,80}?return;/.test(pickSrc));
  }
  // 空状态必须区分"没启用自动模式"与"暂时没流量"，否则用户以为功能坏了
  has('page.smart.empty-title', pageSrc, 'private smartEmptyTitle()');
  has('page.smart.empty-hint', pageSrc, 'private smartEmptyHint()');
  has('page.smart.empty-distinguishes-mode', pageSrc, "return '尚未启用自动选择';");
  has('page.smart.card', pageSrc, 'SmartCard(row: NodeRow)');
  has('page.smart.no-reconnect-fake-node', pageSrc, "'autoSelectMode=auto'");
  ok('page.smart.sorts-top', pageSrc.includes('rows[0].isSmart === true'));
  // ── 新内核能力落地：info-node 过滤 / testLatencyUrl / policy-priority ──
  has('gen.smart.exclude-filter-constant', genSrc, 'SMART_INFO_NODE_FILTER');
  has('gen.smart.exclude-filter-emitted', genSrc,
    'exclude-filter: "${ClashConfigGenerator.SMART_INFO_NODE_FILTER}"');
  // 2026-10-20（A12c / 审计 F12）：smart 组的测速地址改为**唯一真源**
  // LatencyTestUrl.effective()；生成器不再自己读用户设置、不再自带 url 规则。
  has('gen.smart.url-single-source', genSrc,
    'const smartUrl: string = LatencyTestUrl.effective(smartTestUrl);');
  has('gen.smart.url-imports-truth-source', genSrc,
    "import { LatencyTestUrl } from '../latency/LatencyTestUrl';");
  ok('gen.smart.url-not-read-from-settings', !genSrc.includes('settings.testLatencyUrl'));
  has('gen.smart.policy-priority-setting', settingsSrc, 'smartPolicyPriority: string = \'\';');
  has('gen.smart.policy-priority-emitted', genSrc, 'policy-priority:');
  has('settings.smart-policy-serialize', settingsSrc, 'j.smartPolicyPriority = this.smartPolicyPriority;');
  has('settings.smart-policy-deserialize', settingsSrc,
    "s.smartPolicyPriority = typeof j.smartPolicyPriority === 'string'");
  // ── 自动选择视图（分组 chips 里的第二个）──
  has('page.smart.view-state', pageSrc, '@State smartView: boolean = false;');
  has('page.smart.view-chip', pageSrc, "Text('自动选择')");
  has('page.smart.enter', pageSrc, 'private enterSmartView()');
  has('page.smart.exit', pageSrc, 'private exitSmartView()');
  // 轮询必须在 onPageHide 停掉，否则退到后台还在每 3s 打内核 API
  has('page.smart.poll-stop-on-hide', pageSrc, 'this.stopSmartPoll();');
  has('page.smart.active-source', pageSrc, 'smartActiveNodes');
  // 真机踩过的坑：refreshSmartActive() 只改了 @State 却没重建 this.nodes，
  // 而 UI 渲染的是 this.nodes → 分组永远空白。异步拉取完成后必须 rebuildRows()。
  {
    const body = /private async refreshSmartActive\(\)[\s\S]*?\n  \}/.exec(pageSrc);
    const bodySrc = body ? body[0] : '';
    ok('page.smart.refresh-found', bodySrc.length > 0);
    ok('page.smart.refresh-rebuilds', bodySrc.includes('this.rebuildRows();'));
    // rebuildRows 必须在 await 之后：在 await 之前重建拿到的还是旧（空）数组
    const awaitAt = bodySrc.indexOf('await this.orchestrator.api.smartActiveNodes');
    const lastRebuild = bodySrc.lastIndexOf('this.rebuildRows();');
    ok('page.smart.rebuild-after-await', awaitAt >= 0 && lastRebuild > awaitAt);
  }
  // 不能复用 filterSubId 表达自动选择视图：它是订阅 id，混用会让过滤分支误判合成行
  ok('page.smart.no-filterSubId-reuse',
    !pageSrc.includes('this.filterSubId = SMART_ROW_ID'));
  // ── 内核组测速：唯一真实入口 = 订阅页「内核智能优选」行尾按钮（2026-10-22）──────
  // 历史：组测只实现在没有导航入口的 NodeSelectionPage，与订阅页闪电测速形成两套口径，
  // 2026-10-21 随死页删除；2026-10-22 用户要求「补一个组测真实入口，放在智能优选后面」
  // ⇒ 在 SubscriptionPage 重新落地，走 ClashApiService.testGroupDetailedResult()。
  // 本节锁两件事：① 页面层**不得直接拼** `/group/{x}/delay` URL（必须走客户端方法）；
  //              ② 组测入口只有一个，且在订阅页。
  {
    const hits = [];
    const scan = (dir) => {
      for (const entry of readdirSync(dir, { withFileTypes: true })) {
        const full = join(dir, entry.name);
        if (entry.isDirectory()) {
          scan(full);
        } else if (entry.name.endsWith('.ets')) {
          // 只判**代码行**：注释里写 `/group/PROXY/delay` 是说明文字，
          // 曾因为把注释算成调用点而误判（2026-10-22）。
          const codeLines = readFileSync(full, 'utf8').split('\n').filter((l) => {
            const t = l.trim();
            return t.length > 0 && !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
          });
          if (codeLines.some((l) => /\/group\/[^"`\s]*\/delay/.test(l))) {
            hits.push(entry.name);
          }
        }
      }
    };
    scan(join(etsRoot, 'pages'));
    ok('latency.group-endpoint-not-hand-built-in-pages', hits.length === 0, `hits=${JSON.stringify(hits)}`);
    // 2026-10-22（用户要求「测速完全按 FlClash」）：组测速**不再**调
    // `GET /group/{name}/delay`，改为组内节点**逐个**走 FlclashLatencyService（32 并发）。
    // 唯一实现 = FlclashLatencyService.start（BackgroundLatencyService 只是薄适配层）。
    const bgSrc = readFileSync(join(svcDir, 'BackgroundLatencyService.ets'), 'utf8');
    has('latency.group-test-single-entry', bgSrc, 'FlclashLatencyService.start(');
    notHas('latency.no-kernel-group-endpoint', bgSrc, 'testGroupDetailedResult(');
    const flcDelay = readFileSync(join(etsRoot, 'commons/flclash/FlclashDelay.ets'), 'utf8');
    has('latency.flclash-concurrency-32', flcDelay, 'FLCLASH_DELAY_CONCURRENCY: number = 32');
    has('latency.flclash-timeout-5000', flcDelay, 'FLCLASH_DELAY_TIMEOUT_MS: number = 5000');
    has('latency.flclash-url-gstatic', flcDelay, 'https://www.gstatic.com/generate_204');
    has('latency.group-test-from-page', readFileSync(join(etsRoot, 'pages/SubscriptionPage.ets'), 'utf8'),
      'BackgroundLatencyService.runKernelGroupTest(');
    const nodePage = readFileSync(join(etsRoot, 'pages/NodeSelectionPage.ets'), 'utf8');
    notHas('latency.dead-page-no-group-test', nodePage, 'testGroupDetailedResult');
  }
  // ── 订阅只收 Clash（2026-10-21 用户定案）─────────────────────────────
  // 判「内容」不判「链接」：非 Clash ⇒ 保留已存节点 + 打旧格式标记 + 停自动更新 + 提示换链接。
  has('subs.clash-only-guard', subsSrc, 'static isClashBody(body: string): boolean');
  has('subs.clash-only-advice', subsSrc, 'NON_CLASH_ADVICE');
  // 2026-10-21 改：非 Clash 直接拒（对齐三家），不再写冻结标记
  notHas('subs.no-legacy-freeze-flag', subsSrc, 'sub.legacyFormat = true;');
  {
    const schedSrc = readFileSync(join(svcDir, 'SubscriptionUpdateScheduler.ets'), 'utf8');
    has('subs.legacy-skips-auto-update', schedSrc, 'if (s.legacyFormat) {');
  }
  {
    const subPage = readFileSync(join(etsRoot, 'pages', 'SubscriptionPage.ets'), 'utf8');
    has('subs.file-yaml-only', subPage, "opts.fileSuffixFilters = ['.yaml', '.yml'];");
    has('subs.qr-rejects-node-uri', subPage, '扫码只支持 Clash 订阅二维码');
    // 2026-10-21 用户二次定案：订阅刷新/新增/删除/编辑**不自动重连**（保持原行为，
    // 避免用户正在用网时被打断）；只有节点切换才即时重连。
    notHas('subs.no-reconnect-on-subscription-ops', subPage, 'syncTunnelAfterSubChange');
    has('subs.reconnect-on-node-select', subPage, 'reconnectWithNode(node,');
  }
  // ── 测速频率：只在本次启动 / 订阅变更后测一次 ──
  has('page.latency.session-gate', pageSrc, "AppStorage.get<string>('latency_session_stamp')");
  has('page.latency.revision-key', pageSrc, "'subscription_revision'");
  has('subs.revision-bump', subsSrc, "AppStorage.setOrCreate('subscription_revision'");
  // 注意只能查数组本体：源码注释里为了说明「为什么删掉」会提到这些域名，查全文会误报。
  // 文件里有多个 `const mirrors`（geoip 的在前），必须挑出 Model.bin 那一个。
  const mirrorBlock = (() => {
    // 旧实现是函数内 `const mirrors: string[] = [...]`；重构后镜像表提升为模块级
    // `const MODEL_MIRRORS: AssetMirror[] = [...]`（geoip/ruleset 同构，按名字排除）。
    const all = [...orchSrc.matchAll(/const [A-Z_]+: AssetMirror\[\] = \[([\s\S]*?)\];/g)]
      .map(m => m[1]);
    return all.find(b => b.includes('Model.bin')) || '';
  })();
  ok('orch.smart.mirror-block-found', mirrorBlock.length > 0);
  ok('orch.smart.no-dead-jsdelivr-mirror', !mirrorBlock.includes('@LightGBM-Model/Model.bin'));
  ok('orch.smart.no-dead-ghfast', !mirrorBlock.includes('ghfast.top'));
  ok('orch.smart.has-usable-mirror', mirrorBlock.includes('gh-proxy.com'));
  // 双栈开关**不**走 want：扩展进程读的是落盘 YAML（readTunFlagsFromConfig），
  // 多一条参数通道就多一个 TUN/内核分叉的机会。这里守住「不要把它加回来」。
  ok('orch.no-ipv6-inbound-param', !orchSrc.includes('ipv6Inbound'));
  // 运行时探测模块仍然移除：开关是唯一决策源，不做「有 v6 才开」的二次判定。
  ok('ipv4only.detector-removed', !existsSync(join(svcDir, 'Ipv6Detector.ets')));
}

const apiSrc = readFileSync(join(svcDir, 'ClashApiService.ets'), 'utf8');
{
  has('api.reloadFromPath', apiSrc, 'async reloadFromPath');
  has('api.putConfigs-force', apiSrc, '/configs?force=true');
  has('api.setMode-via-put', apiSrc, "payload['mode']");
}

const homeSrc = readFileSync(join(etsRoot, 'pages', 'HomePage.ets'), 'utf8');
const rulesSrc = readFileSync(join(etsRoot, 'pages', 'RulesPage.ets'), 'utf8');
has('home.hotmode', homeSrc, 'applyProxyMode');
// 2026-09-17 规则入口集中到主页「网络规则」4 选项弹窗；0.4.0 设置页精简后，
// 规则页入口**迁到设置页**（SettingsPage → router.pushUrl('pages/RulesPage')），
// 主页不再直接跳转。断言随之改为「入口仍然存在且可达」，而不是死守旧位置——
// 否则这条护栏会变成永远红的噪音（0.4.0 起就是如此，2026-10-19 修正）。
const rulesEntrySrc = readFileSync(join(etsRoot, 'pages', 'SettingsPage.ets'), 'utf8');
has('home.rules-entry', rulesEntrySrc, 'pages/RulesPage');
has('rules.hotmode', rulesSrc, 'applyRulesChanged');
const nselSrc = readFileSync(join(etsRoot, 'pages', 'NodeSelectionPage.ets'), 'utf8');
has('nsel.forceReconnectWithNode', nselSrc, 'reconnectWithNode(node, this.subs');
notHas('nsel.no-hot-node-switch', nselSrc, 'this.orchestrator.switchNodeHot(node.name)');
// 2026-09-17 规则入口已集中到主页卡片：网站规则改走 SiteRoutingPage（applyRulesChanged），
// 节点页不再承载规则编辑，因此这里断言节点页确实不再包含规则热更新入口。
const siteSrc = readFileSync(join(etsRoot, 'pages', 'SiteRoutingPage.ets'), 'utf8');
has('site.rules-changed', siteSrc, 'applyRulesChanged');
notHas('nsel.rules-entry-removed', nselSrc, 'openNetworkRules');

// ── 去广告默认关闭（2026-10）──────────────────────────────────────────
// 全局模式下 HyperADRules 会误伤应用商店（华文应用商店加载失败）：商店聚合接口与
// 广告域名共用 CDN/证书，REJECT 连带打断正常业务。改为默认关闭、由用户自行打开。
// 三处默认必须同时为 false：Json 模型字段、运行时 AppSettings 字段、fromJson 兜底；
// RulesPage 的 @State 初值也要一致，否则首帧会闪一下"已开启"。
{
  const settingsSrc = readFileSync(join(svcDir, '..', 'models', 'AppSettings.ets'), 'utf8');
  const modelDefaults = [...settingsSrc.matchAll(/hyperAdRulesEnabled:\s*boolean\s*=\s*(true|false);/g)]
    .map(m => m[1]);
  ok('adblock.default-off-in-model', modelDefaults.length >= 2 && modelDefaults.every(v => v === 'false'));
  has('adblock.fromJson-default-off', settingsSrc,
    "j.hyperAdRulesEnabled === 'boolean' ? j.hyperAdRulesEnabled : false");
  // 关键：老用户显式存过的 true 必须原样保留，所以兜底只能是 false，不能是 true。
  ok('adblock.legacy-choice-preserved', !settingsSrc.includes('j.hyperAdRulesEnabled === \'boolean\' ? j.hyperAdRulesEnabled : true'));
  has('adblock.rules-page-default-off', rulesSrc, 'hyperAdRulesEnabled: boolean = false');
  // 关闭时连后台规则集下载都要省掉：省带宽，也避免无意义的 GitHub 访问。
  has('adblock.connect-gated-by-toggle', orchSrc, 'settings.rulesEnabled && settings.hyperAdRulesEnabled');
  has('adblock.skip-provision-when-off', orchSrc, 'ad-block rules disabled; skipping hyper-adrules ruleset provisioning');
}

// ── 后台保活自愈（2026-10）─────────────────────────────────────────────
// 1) 用户意图必须先于拉起落盘：否则建连那 30s 就绪窗口里被系统杀掉，磁盘上仍是
//    false，冷启动无从判断"用户本来是想连着的"。
// 2) 断开回滚必须同代保护：否则旧连接失败回滚会抹掉新连接刚写下的 true。
// 3) 冷启动/回前台必须消费这份意图。
// 4) 守护者租约丢失时先自愈，不是一律放弃。
{
  has('heal.intent-before-launch', orchSrc,
    "await this.advanceSessionIntent(true, 'connecting', node.name, 0)");
  has('heal.intent-gated-commit', orchSrc, 'await this.updateSessionSnapshot(intentGeneration, true,');
  has('heal.rollback-generation-aware', orchSrc, 'private async clearSessionIntent(expectedGeneration: number)');
  has('heal.rollback-generation-check', orchSrc,
    'expectedGeneration > 0 && previous.sessionGeneration !== expectedGeneration');
  // 断开的真正执行必须无条件进行 —— 只有"写意图"才受代次保护，隧道照样拆。
  has('heal.teardown-not-generation-gated', orchSrc, 'await this.clearSessionIntent(expectedGeneration)');

  has('heal.restore-entry', orchSrc, 'async restoreKilledSession(context: Context)');
  has('heal.restore-not-on-user-stop', orchSrc, 'if (!snap.desiredConnected)');
  // 相位闸门：上次确实 failed/disconnected 的会话不得无限复活。
  has('heal.restore-phase-gate', orchSrc, "snap.phase !== 'connecting' && snap.phase !== 'connected'");

  const entrySrc = readFileSync(join(etsRoot, 'entryability', 'EntryAbility.ets'), 'utf8');
  has('heal.cold-start', entrySrc, "this.scheduleSelfHeal('cold-start')");
  has('heal.foreground', entrySrc, "this.scheduleSelfHeal('foreground')");
  has('heal.background-reengage', entrySrc, 'onBackground(): void');
  // 有明确用户请求时不介入自愈，否则会和 VpnQuickStart 的 toggle 抢 connectSeq。
  has('heal.skip-on-explicit-request', entrySrc, 'explicit request');

  const quickSrc = readFileSync(join(etsRoot, 'quicktoggleability', 'QuickToggleAbility.ets'), 'utf8');
  has('heal.guardian-selfheals', quickSrc, 'but intent still on; self-healing');
  has('heal.guardian-bounded', quickSrc, 'private scheduleHealRetry(reason: string)');
}

// ── DNS 防泄露（2026-10）───────────────────────────────────────────────
// 业务解析必须走加密上游：明文 UDP/53 会把用户访问的每一个域名以明文 QNAME
// 发到物理网卡，是本项目最主要的泄露通道。
{
  const cfgSrc = genSrc; // ClashConfigGenerator 源文本（模块级 genSrc，同一文件）
  has('dns.encrypted-nameserver', cfgSrc, "lines.push('    - tls://223.5.5.5:853')");
  has('dns.direct-nameserver', cfgSrc, "lines.push('  direct-nameserver:')");
  has('dns.direct-nameserver-encrypted', cfgSrc, "lines.push('    - tls://1.12.12.12:853')");
  has('dns.direct-follow-policy-off', cfgSrc, "lines.push('  direct-nameserver-follow-policy: false')");
  // proxy-server-nameserver 是防死锁的关键，绝不能因为"改加密"顺手删掉。
  has('dns.proxy-server-nameserver-kept', cfgSrc, "lines.push('  proxy-server-nameserver:')");
  // 订阅自带 DNS 上游必须真的接上（2026-10-20「测速全部超时」定案）：
  // 上面那条只锁「DoT 字面量还在源码里」，会奖励把订阅分支写死成 DoT ——
  // 这里补上「三分支形状 + 入参接线」的断言，改错了会红。
  has('dns.proxy-ns-policy-emitted', cfgSrc, "lines.push('  proxy-server-nameserver-policy:')");
  has('dns.proxy-ns-neutral-global', cfgSrc, "lines.push('    - tls://223.5.5.5:853')");
  has('dns.subscription-upstream-wired', cfgSrc, 'normalizeDnsUpstreams(subscriptionDnsUpstreams, allNodes)');
  has('dns.subscription-policy-wired', cfgSrc, 'normalizeDnsPolicies(subscriptionDnsPolicies, allNodes)');

  // ── 5.8.0 线上回归的闸门：华为应用商店在全局模式下加载失败 ──
  // 根因是 primary 设成海外解析器 + 开了 respect-rules，导致国内服务的域名
  // 也被推到境外节点上解析，拿到境外 CDN 边缘。这两条必须同时成立才算修好。
  ok('dns.no-respect-rules',
    !cfgSrc.includes("lines.push('  respect-rules: true')"),
    'respect-rules 会把国内域名 DNS 推到境外节点，全局模式下国内应用商店/CDN 会失效');
  // 注：仓库在 Windows 上以 CRLF 检出，逐字比较前先归一化换行，
  // 否则会像 verify-app-routing 那样在 LF-only 断言上假阴性。
  const cfgLf = cfgSrc.replace(/\r\n/g, '\n');
  // 从 `<key>:` 之后**紧邻**的连续上游条目（形如 `    - xxx`）中提取文本。
  // 必须先于下面所有用到它的断言声明（const 无提升，否则 TDZ 报错）。
  // 不能按空行截断 —— 源码里这些块之间夹着大段注释、没有空行分隔，
  // 按空行截会一路吞到文件末尾，把 proxy-server-nameserver 的明文条目也误判进来。
  const upstreamOf = (key) => {
    const start = cfgLf.indexOf("lines.push('  " + key + ":');");
    if (start < 0) { return ''; }
    const lines = cfgLf.slice(start).split('\n');
    const out = [lines[0]];
    for (let i = 1; i < lines.length; i++) {
      // 上游条目的缩进不固定：nameserver 是 4 空格，而 fallback 在
      // `if (useGeoip)` 块内是 6 空格 —— 所以不能写死缩进宽度。
      if (!/^\s*lines\.push\(' {4}- /.test(lines[i])) { break; }
      out.push(lines[i]);
    }
    return out.join('\n');
  };
  ok('dns.primary-is-domestic',
    cfgLf.includes("lines.push('  nameserver:');\n    lines.push('    - tls://223.5.5.5:853');"),
    '业务 primary 必须是境内 DoT，否则国内 CDN 会被解析到境外边缘');
  // 境外解析器只能出现在 fallback（需 geoip 就绪），且必须走 853：
  // 1.1.1.1:443 / 8.8.8.8:443 国内实测 TCP 超时，写进配置就是死条目。
  ok('dns.no-unreachable-443-resolvers',
    !cfgSrc.includes('https://1.1.1.1/dns-query') && !cfgSrc.includes('https://8.8.8.8/dns-query'),
    'Cloudflare/Google DoH 的 443 在国内实测不可达，不得写进 nameserver/fallback');
  const fbBlock = upstreamOf('fallback');
  ok('dns.fallback-is-dot-853', fbBlock.includes('tls://1.1.1.1:853'));
  // 不可达的境外端点不是冗余保险：每个境外域名解析都要多付一次连接超时。
  // 实测（2026-10 国内网络）只有 1.1.1.1:853 可直连，其余境外 853 全超时。
  ok('dns.no-dead-fallback-endpoints',
    !/8\.8\.8\.8|8\.8\.4\.4|9\.9\.9\.9|208\.67\.222\.222|149\.112\.112\.112/.test(fbBlock),
    'fallback 里存在国内不可达的端点，会给每次境外解析叠加一次连接超时');

  // nameserver-policy 只能用纯后缀：geosite: 会在 config.Parse 触发同步下载。
  // 判据锁「真的发射了 geosite:」（lines.push 字符串），不按 400 字窗口扫源码 ——
  // 窗口会把上面那句「不用 geosite:」的说明注释也算进去，注释一挪动就误红。
  ok('dns.no-geosite-policy', !/lines\.push\([^\n]*geosite:/.test(cfgSrc));
  // proxy-server-nameserver 是刻意的明文回环阻断器，不在业务解析路径上；
  // nameserver / direct-nameserver（业务解析）里不得再出现**明文** UDP。
  // 判据是"裸 IP 条目"（无 scheme），不能拿 IP 子串匹配 ——
  // `tls://223.5.5.5:853` 里同样含这个 IP，但它是加密的。
  // default-nameserver 也排除：内核要求它必须是裸 IP（引导解析用）。
  const plaintextUpstream = ['nameserver', 'direct-nameserver']
    .map(k => upstreamOf(k))
    .join('\n')
    .match(/lines\.push\('    - \d+\.\d+\.\d+\.\d+'\);/g) || [];
  ok('dns.no-plaintext-nameserver', plaintextUpstream.length === 0,
    '业务解析出现明文 UDP 上游: ' + plaintextUpstream.join(', '));

  // fake-ip（2026-10-21 二次定案）：v6 也必须走代理，所以假池回来了 —— 但必须
  // **同时**有 range6（假 v6 落在 TUN 的 /64 里才有路由）。STUN/NTP/门户探活仍靠
  // fake-ip-filter 拿真实地址，不能删。
  has('dns.fake-ip-mode', cfgSrc, "lines.push('  enhanced-mode: fake-ip')");
  has('dns.fake-ip-range', cfgSrc, "lines.push('  fake-ip-range: 198.18.0.1/16')");
  has('dns.fake-ip-range6', cfgSrc, "lines.push('  fake-ip-range6: fdfe:dcba:9876::/64')");
  has('dns.fake-ip-filter', cfgSrc, "lines.push('  fake-ip-filter:')");

  // DoH 预解析/刷新必须发生在隧道建立之前：隧道已起时再对 doh.pub 裸发查询，
  // 等于在刚建好的防泄露链路上又开一个明文的洞。
  // 锚点用 connect() 里隧道被判定为已建立的那一刻。全文件有两处
  // `this.state = ConnState.CONNECTED;`（另一处在热重连辅助路径），connect() 的是
  // 后者，故取 lastIndexOf；也不使用 startVpnExtensionAbility —— 该串在 headless
  // 测速核路径上更早出现，位置比较会被无关调用点带偏。
  // 刷新调用点已移入唯一生成入口 RuntimeConfigBuilder（整仓只剩这一处）：
  // buildRuntimeConfig() 内部刷新一次 —— 而 buildRuntimeConfig 的调用发生在隧道建立之前，
  // 所以「隧道已起后再对 doh.pub 裸发查询」这个洞仍然被堵住。
  const refreshIdx = builderSrc.indexOf('DoHResolver.refreshStale()');
  const buildCallIdx = orchSrc.indexOf('RuntimeConfigBuilder.buildRuntimeConfig(');
  const connectedIdx = orchSrc.lastIndexOf('this.state = ConnState.CONNECTED;');
  ok('dns.doh-refresh-pre-tunnel', refreshIdx > 0 && buildCallIdx > 0 && connectedIdx > 0
    && buildCallIdx < connectedIdx);

  ok('dns.doh-refresh-pre-tunnel', refreshIdx > 0 && connectedIdx > 0 && refreshIdx < connectedIdx);
  // 只有一个调用点：多处刷新会把过期域名在隧道内外都查一遍，正是要避免的形态。
  const refreshHits = (orchSrc + builderSrc).split('DoHResolver.refreshStale()').length - 1;
  ok('dns.doh-refresh-single-call-site', refreshHits === 1, `调用点 ${refreshHits} 处`);
  // DNS 自检必须问系统解析器（隧道在时被 any:53 劫持进内核），而不是再去 doh.pub。
  has('dns.selfcheck-tests-core', orchSrc, "connection.getAddressesByName('www.gstatic.com')");
}

// ── 连接路径性能（2026-10）─────────────────────────────────────────────
{
  // 没有旧隧道就别再白等 400ms。
  has('perf.conditional-extension-grace', orchSrc, 'skip 400ms extension-exit grace');
  // Model.bin 的 9.3MB 同步读写只在真的要用 smart 组时才付。
  has('perf.smart-seed-only-in-auto', orchSrc, 'autoMode && this.seedSmartModelFromRawfile()');
  // dropReasonFor 是本文件最贵的判定，一次 generate 只能算一遍。
  has('perf.drop-reason-memoized', genSrc, 'const dropReasons: Map<ProxyNode, string>');
  has('perf.drop-reason-reused', genSrc, 'ClashConfigGenerator.countDroppedNodes(allNodes, dropReasons)');
  // 逐字符净化前先做零分配扫描。
  has('perf.sanitize-fast-path', genSrc, 'let needsRewrite = false;');
  // DoH pin 必须跨进程落盘，否则每次冷启动都要重走一遍网络。
  has('perf.doh-pins-persisted', orchSrc, 'SettingsService.saveAppRoutingSnapshot');
  const dohSrc = readFileSync(join(svcDir, 'DoHResolver.ets'), 'utf8');
  has('perf.doh-pins-load', dohSrc, 'await SettingsService.loadDohPins()');
  has('perf.doh-priority-domains', dohSrc, 'priorityDomains: string[] = []');

  // ── 配置落盘安全：暂存 → 内核校验 → 才替换 ──────────────────────────
  // 内核对坏配置是**整份拒载**，所以热重载必须先让内核接受暂存文件，接受后才原子替换正式配置；
  // 否则一次坏规则/坏 DNS 落盘就是「重启即整份拒载」，用户最后一份能用的配置被顶掉。
  has('config.staged-write', orchSrc, 'const stagedPath = `${configPath}.next`;');
  has('config.staged-validate', orchSrc, 'await this.api.reloadFromPath(stagedPath)');
  has('config.staged-promote', orchSrc, 'fs.renameSync(stagedPath, configPath)');
  // 冷启动没有可预校验的内核（设备侧 core 只有 controller 接口，无 `-t` CLI），
  // 但 2026-10-22 起改成「**扩展自己当校验器**」：本次配置写 `${configPath}.next`，
  // 扩展按暂存路径拉起，readiness 通过（= 内核真的加载了它）才提升为正式配置。
  // 拒载路径不会走到提升 ⇒ 正式配置永远保持上一份「内核真的加载过」的字节。
  has('config.coldstart-staged-write', orchSrc, 'const stagedConfigPath = `${configPath}.next`;');
  has('config.coldstart-launch-staged', orchSrc, 'vpnParams[\'configPath\'] = stagedConfigPath;');
  has('config.coldstart-startparams-staged',
    orchSrc, 'this.writeStartParamsFile(stagedConfigPath, appRouting.mode, appRouting.needsReview, packagesJson);');
  has('config.coldstart-promote', orchSrc, 'this.acceptStagedConfig(stagedConfigPath, configPath, preparedConfig);');
  has('config.coldstart-promote-atomic', orchSrc, 'fs.renameSync(tmp, target);');
  has('config.coldstart-promote-after-connected', orchSrc,
    'this.state = ConnState.CONNECTED;');
  ok('config.coldstart-promote-order',
    orchSrc.indexOf('this.state = ConnState.CONNECTED;') >= 0
      && orchSrc.indexOf('this.acceptStagedConfig(stagedConfigPath') > orchSrc.indexOf('this.state = ConnState.CONNECTED;')
      && orchSrc.indexOf('this.acceptStagedConfig(stagedConfigPath') < orchSrc.indexOf('this.snapshotLastGoodConfig();'));
  // 等价兜底仍保留（内核拒载时回滚到最后一份能连上的配置）
  has('config.lastgood-snapshot', orchSrc, 'this.snapshotLastGoodConfig();');
  has('config.lastgood-restore', orchSrc, 'this.restoreLastGoodConfig()');

  // ── 明文 HTTP 订阅默认拒绝（对齐 FlClash / Clash Verge Rev / CMFA）──
  const fetchSrc = readFileSync(join(svcDir, 'SubscriptionFetchPolicy.ets'), 'utf8');
  ok('subs.insecure-http-default-false',
    fetchSrc.includes('allowInsecureHttp: boolean, etag: string') === true
      && fetchSrc.includes('isValidSubscriptionUrl(urlStr: string, allowInsecureHttp: boolean = false)') === true);
  has('subs.insecure-http-actionable', fetchSrc, '在「设置 → 允许明文 HTTP 订阅」中显式打开');
  has('settings.insecure-http-field', subsSrc, 'insecureSubscriptionHttpAllowed()');
}

// ── 汇总 ──────────────────────────────────────────────────────────────
console.log('===== SSRVPN 架构与性能改造自动化验证 =====');
console.log('[A] 可执行纯逻辑：TunnelAuthority.ets / VpnRecoveryPolicy.ets（Node 24 type-stripping）');
console.log('[B] 源码级不变量：ClashConfigGenerator / VpnExtensionAbility / ConnectionOrchestrator / ClashApiService / 页面');
console.log('-----------------------------------------');
console.log(`PASSED=${passed}  FAILED=${failures.length}  TOTAL=${passed + failures.length}`);
if (failures.length > 0) {
  for (const f of failures) console.log('  FAIL ' + f);
  console.log('RESULT: ARCHITECTURE CHECKS FAILED');
  process.exit(1);
}
console.log('RESULT: ALL ARCHITECTURE CHECKS PASSED');
