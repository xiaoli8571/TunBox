#!/usr/bin/env node
/**
 * 常驻通知「速率 + 运行时长」可靠性回归护栏（2026-10-30 用户报障）
 *
 * ## 守的是什么故障
 *
 * 用户反馈：「很多用户只有这一个通知消息，没有上传下载速率和运行时间」。
 * 追下来是三条**彼此独立**的漏点，任何一条复发都会让通知栏只剩系统长时任务卡
 * （那张卡的内容按接入规范**不允许**应用修改，天生不可能有速率）：
 *
 * ① 连接成功先 `TunBoxNotifier.cancel()` 撤掉应用卡，再等 1s 流量轮询重建
 *    → 轮询没跑起来（监控启动失败 / 进程被冻结）就一直是空卡。
 *    现在：先复核权限，通过则**立即**补发首帧（force=true，绕过节流）。
 *
 * ② 通知权限审查被锁成「每进程只查一次」：用户点过「暂不」之后，即便他后来
 *    在系统设置里手动打开通知，本进程内也永远不再复核 → 速率卡再也不出现。
 *    现在：`ensurePermission()` **每次连接都复核**，只有「未授予 + 还没弹过」
 *    才弹框，已授予则立刻解除 1600004 退避。
 *
 * ③ 快捷开关 / 桌面卡片路径发的是 `TunBox 已连接 / ↓ 0 B/s ↑ 0 B/s`：
 *    标题口径与主页路径不同、没有运行时长，还会把刚补的首帧覆盖掉。
 *    现在：与主页同口径（`TunBox · 节点`），时长由流量轮询立即接上。
 *
 * 另外补了一条兜底：内容没变时也按 60s 心跳重发一帧，卡片被系统回收后能自己回来。
 *
 * ## 断言分组
 *
 *   N 通知层：force 参数 / 节流带 !force / 60s 重发心跳 / 权限每次复核
 *   P 内容层：updateLive 透传 force
 *   C 连接路径：不再 cancel + 首帧带时长 + force=true
 *   Q 快捷开关路径：标题口径一致 + force=true
 *
 * 另有 4 条**反向对照**：把代码改回旧写法，断言必须被判红（证明检查真的有效）。
 *
 * ⚠ Windows 上是 CRLF 检出：所有断言前先 `replace(/\r\n/g, '\n')`。
 *
 * 用法：
 *   node scripts/verify-notification-card.mjs
 */
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');
const ETS = resolve(ROOT, 'entry/src/main/ets');

const FILES = {
  notifier: resolve(ETS, 'commons/services/TunBoxNotifier.ets'),
  updater: resolve(ETS, 'commons/services/TaskProgressUpdater.ets'),
  orchestrator: resolve(ETS, 'commons/services/ConnectionOrchestrator.ets'),
  quickStart: resolve(ETS, 'commons/services/VpnQuickStart.ets')
};

const read = (p) => readFileSync(p, 'utf8').replace(/\r\n/g, '\n');

/** 连接成功段的判定区域：从权限复核调用起，到流量轮询接手为止 */
function connectRegion(src) {
  const at = src.indexOf('TunBoxNotifier.ensurePermission(this.context).then(');
  if (at < 0) {
    return '';
  }
  return src.slice(Math.max(0, at - 1200), at + 1400);
}

/** ensurePermission 函数体（到 isAvailable 定义为止） */
function ensurePermissionBody(src) {
  const start = src.indexOf('static async ensurePermission(context: Context)');
  const end = src.indexOf('static isAvailable()', start);
  if (start < 0) {
    return '';
  }
  return src.slice(start, end < 0 ? start + 2500 : end);
}

/* ── 谓词（都接受源码文本，便于反向对照时喂改坏的副本）────────────────── */

const P = {
  // N1 通知发布支持强制帧
  n1ForceParam: (s) => /static async update\(title: string, nodeLine: string, speedLine: string,\s*\n\s*force: boolean = false\)/.test(s),
  // N2 节流必须尊重 force
  n2ForceBypass: (s) => /if \(!force && text === TunBoxNotifier\.lastText/.test(s),
  // N3 内容未变时的 60s 重发心跳
  n3ResendHeartbeat: (s) => /const RESEND_HEARTBEAT_MS = 60000;/.test(s)
    && /now - TunBoxNotifier\.lastPublishAt < RESEND_HEARTBEAT_MS/.test(s),
  // N4 权限复核返回可用性
  n4ReturnsBool: (s) => /static async ensurePermission\(context: Context\): Promise<boolean>/.test(s),
  // N5 权限复核每次连接都做（isNotificationEnabled 在 permissionPrompted 门禁之前，
  //    且不存在旧的 permissionRequested 一次性锁）
  n5RecheckEveryConnect: (s) => {
    const body = ensurePermissionBody(s);
    if (body.length === 0) {
      return false;
    }
    if (body.indexOf('permissionRequested') >= 0) {
      return false;
    }
    const checkAt = body.indexOf('isNotificationEnabled');
    const gateAt = body.indexOf('permissionPrompted');
    return checkAt >= 0 && gateAt > checkAt;
  },
  // N6 publish 成功要记 lastPublishAt（心跳的基准）
  n6RecordsPublish: (s) => /notificationManager\.publish\(request\);[\s\S]{0,240}TunBoxNotifier\.lastPublishAt = now;/.test(s),
  // N7 cancel 要复位心跳（否则断开再连会被节流吃掉首帧）
  n7CancelResets: (s) => /static cancel\(\): Promise<void> \{[\s\S]*?TunBoxNotifier\.lastPublishAt = 0;/.test(s),

  // P1 内容层透传 force
  p1UpdaterForceParam: (s) => /static updateLive\(nodeText: string, speedLine: string, durationText: string,\s*\n\s*force: boolean = false\)/.test(s),
  p2UpdaterForwards: (s) => /liveLine, force\)\.catch/.test(s),

  // C1 连接成功不再撤通知
  c1NoCancelOnConnect: (s) => connectRegion(s).length > 0 && !/TunBoxNotifier\.cancel\(\)/.test(connectRegion(s)),
  // C2 连接成功补首帧（带运行时长）
  c2SeedsFirstFrame: (s) => /TunBoxNotifier\.ensurePermission\(this\.context\)\.then\(\(granted: boolean\): void => \{/.test(s)
    && /TaskProgressUpdater\.updateLive\(this\.notifyNodeText\(finalNodeName\),\s*\n\s*'↓ 0 B\/s  ↑ 0 B\/s', this\.connDurationText\(\), true\);/.test(s),
  // C3 首帧必须强制发布（否则同节点重连被 900ms 节流吃掉）
  c3SeedForced: (s) => /this\.connDurationText\(\), true\);/.test(connectRegion(s)),
  // C4 权限不通过时不发无意义的帧（只记 warn）
  c4SkipsWhenDenied: (s) => /if \(!granted\) \{[\s\S]{0,200}return;/.test(connectRegion(s)),

  // Q1 快捷开关路径标题口径与主页一致（不再有裸 'TunBox 已连接'）
  q1QuickTitleConsistent: (s) => !/'TunBox 已连接'/.test(s),
  // Q2 快捷开关路径首帧也强制发布
  q2QuickSeedForced: (s) => /TunBoxNotifier\.update\(`TunBox · \$\{node\.name\}`, node\.name, '↓0B\/s ↑0B\/s', true\);/.test(s)
};

/* ── 断言运行器 ───────────────────────────────────────────────────────── */

let passed = 0;
const failed = [];

function check(name, cond) {
  if (cond) {
    passed++;
    console.log(`PASS ${name}`);
  } else {
    failed.push(name);
    console.log(`FAIL ${name}`);
  }
}

const notifier = read(FILES.notifier);
const updater = read(FILES.updater);
const orchestrator = read(FILES.orchestrator);
const quickStart = read(FILES.quickStart);

console.log('── N 通知层 ─────────────────────────────────────────────');
check('N1 通知发布支持 force 参数', P.n1ForceParam(notifier));
check('N2 节流尊重 force（首帧不会被吃掉）', P.n2ForceBypass(notifier));
check('N3 内容未变时按 60s 心跳重发', P.n3ResendHeartbeat(notifier));
check('N4 权限复核返回可用性（boolean）', P.n4ReturnsBool(notifier));
check('N5 权限每次连接都复核（不再一次性锁死）', P.n5RecheckEveryConnect(notifier));
check('N6 发布成功记录 lastPublishAt', P.n6RecordsPublish(notifier));
check('N7 cancel 复位重发心跳', P.n7CancelResets(notifier));

console.log('── P 内容层 ─────────────────────────────────────────────');
check('P1 updateLive 暴露 force 参数', P.p1UpdaterForceParam(updater));
check('P2 updateLive 把 force 透传给通知层', P.p2UpdaterForwards(updater));

console.log('── C 连接成功路径 ───────────────────────────────────────');
check('C1 连接成功不再 cancel 应用卡', P.c1NoCancelOnConnect(orchestrator));
check('C2 连接成功立即补首帧（含运行时长）', P.c2SeedsFirstFrame(orchestrator));
check('C3 首帧为强制发布', P.c3SeedForced(orchestrator));
check('C4 通知不可用时不发无意义帧', P.c4SkipsWhenDenied(orchestrator));

console.log('── Q 快捷开关 / 卡片路径 ────────────────────────────────');
check('Q1 标题口径与主页一致（无裸「TunBox 已连接」）', P.q1QuickTitleConsistent(quickStart));
check('Q2 快捷路径首帧强制发布', P.q2QuickSeedForced(quickStart));

console.log('── X 反向对照（故意改坏，必须判红）──────────────────────');
{
  // X1 连接成功段塞回 cancel
  const broken = orchestrator.replace(
    'TunBoxNotifier.ensurePermission(this.context).then(',
    'TunBoxNotifier.cancel().catch((): void => {});\n      TunBoxNotifier.ensurePermission(this.context).then(');
  check('X1 塞回「连接成功先 cancel」→ C1 判红', P.c1NoCancelOnConnect(broken) === false
    && P.c1NoCancelOnConnect(orchestrator) === true);
}
{
  // X2 去掉 !force（旧节流语义）
  const broken = notifier.replace('if (!force && text === TunBoxNotifier.lastText',
    'if (text === TunBoxNotifier.lastText');
  check('X2 去掉 !force → N2 判红', P.n2ForceBypass(broken) === false
    && P.n2ForceBypass(notifier) === true);
}
{
  // X3 把权限门禁挪到复核之前（等价于旧的「每进程只查一次」）
  const broken = notifier.replace('  static async ensurePermission(context: Context): Promise<boolean> {\n    let enabled = false;',
    '  static async ensurePermission(context: Context): Promise<boolean> {\n    if (TunBoxNotifier.permissionPrompted) { return false; }\n    let enabled = false;');
  check('X3 权限门禁前置（等价旧一次性审查）→ N5 判红', P.n5RecheckEveryConnect(broken) === false
    && P.n5RecheckEveryConnect(notifier) === true);
}
{
  // X4 快捷路径退回旧标题/旧内容
  const broken = quickStart.replace(
    'TunBoxNotifier.update(`TunBox · ${node.name}`, node.name, \'↓0B/s ↑0B/s\', true);',
    'TunBoxNotifier.update(\'TunBox 已连接\', node.name, \'↓ 0 B/s  ↑ 0 B/s\');');
  check('X4 快捷路径退回旧口径 → Q1/Q2 判红', P.q1QuickTitleConsistent(broken) === false
    && P.q2QuickSeedForced(broken) === false
    && P.q1QuickTitleConsistent(quickStart) === true);
}

console.log('');
if (failed.length > 0) {
  console.log(`FAILED: ${failed.join(' | ')}`);
  console.log(`PASSED=${passed} FAILED=${failed.length} TOTAL=${passed + failed.length}`);
  process.exit(1);
}
console.log(`PASSED=${passed} FAILED=0 TOTAL=${passed}`);
