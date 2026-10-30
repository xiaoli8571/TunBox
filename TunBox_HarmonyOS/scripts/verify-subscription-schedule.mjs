#!/usr/bin/env node
/**
 * 订阅调度 / 排序回归护栏（对应 2026-10-30 用户报障两条）
 *
 * ## 守的是什么故障
 *
 * ① 「修改定时更新时间，改一个订阅，全部订阅都改成了这个时间」
 *    真因：编辑弹窗是**按单个订阅**开的，但保存时把开关与间隔写进了**全局**
 *    `AppSettings.autoUpdateSubscription` / `subscriptionUpdateIntervalMinutes`
 *    ⇒ 改 A 订阅 = 改所有订阅。现在开关/间隔落在订阅自己身上，全局值只作回退默认。
 *
 * ② 「长按订阅可以拖动排序」（缺功能）
 *    现在 SubscriptionSection 用 LongPressGesture + PanGesture（Sequence 组）实现
 *    长按拖动，松手后调 SubscriptionService.reorderSubscriptions 落盘 sortOrder。
 *
 * ## 断言分组
 *
 *   M 模型层：字段存在 + 两个方向的序列化都带上
 *   S 服务层：JSON 形状 / 旧数据归一化 / 重排落盘
 *   U UI：保存写订阅自己（且文件里不再出现「写全局间隔」）、弹窗按订阅取初始值
 *   T 调度器：按订阅自己的间隔与开关判定过期
 *   D 拖拽：手势组合 / 落盘调用 / 卡片间距常量
 *
 * 另有 4 条**反向对照**：故意把代码改回旧写法，断言必须被判红（证明这些检查真的有效）。
 *
 * ⚠ Windows 上是 CRLF 检出：所有断言前先 `replace(/\r\n/g, '\n')`，否则跨行断言假阴性。
 *
 * 用法：
 *   node scripts/verify-subscription-schedule.mjs
 */
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');
const ETS = resolve(ROOT, 'entry/src/main/ets');

const FILES = {
  model: resolve(ETS, 'commons/models/Subscription.ets'),
  service: resolve(ETS, 'commons/services/SubscriptionService.ets'),
  section: resolve(ETS, 'components/SubscriptionSection.ets'),
  scheduler: resolve(ETS, 'commons/services/SubscriptionUpdateScheduler.ets')
};

function loadAll() {
  const out = {};
  for (const key of Object.keys(FILES)) {
    out[key] = readFileSync(FILES[key], 'utf8').replace(/\r\n/g, '\n');
  }
  return out;
}

let pass = 0;
const fails = [];
function ok(name, cond, detail) {
  if (cond) {
    pass++;
    return;
  }
  fails.push(`${name}: ${detail}`);
}

/** 断言 4 组，全部是「源码里必须存在 / 必须不存在某个写法」 */
function checks(src) {
  const model = src.model;
  const service = src.service;
  const section = src.section;
  const scheduler = src.scheduler;

  // ── M 模型层 ──
  ok('m1.fields',
    /autoUpdate:\s*boolean\s*=\s*true;/.test(model) && /updateIntervalMinutes:\s*number\s*=\s*0;/.test(model),
    'Subscription 缺少 autoUpdate / updateIntervalMinutes 字段');
  ok('m2.to-json',
    /j\.autoUpdate\s*=\s*s\.autoUpdate;/.test(model)
    && /j\.updateIntervalMinutes\s*=\s*s\.updateIntervalMinutes;/.test(model),
    'toJson 未序列化 per-sub 开关/间隔');
  ok('m3.from-json',
    /s\.autoUpdate\s*=\s*j\.autoUpdate\s*!==\s*false;/.test(model)
    && /s\.updateIntervalMinutes\s*=\s*typeof j\.updateIntervalMinutes/.test(model),
    'fromPersistJson 未回读 per-sub 开关/间隔（旧存储需按默认兜底）');

  // ── S 服务层 ──
  ok('s1.json-shape',
    /autoUpdate\?:\s*boolean;/.test(service) && /updateIntervalMinutes\?:\s*number;/.test(service),
    'SubscriptionJson 缺少新字段声明（persist 会丢字段）');
  ok('s2.sanitize',
    /typeof j\.autoUpdate\s*!==\s*'boolean'/.test(service)
    && /typeof j\.updateIntervalMinutes\s*!==\s*'number'/.test(service),
    '缺少新字段的旧数据归一化（脏数据会整条订阅被丢弃）');
  ok('s3.reorder',
    /async reorderSubscriptions\(orderedIds:\s*string\[\]\)/.test(service)
    && /next\[i\]\.sortOrder\s*=\s*i;/.test(service)
    && /this\.subscriptions\s*=\s*next;\s*\n\s*await this\.persist\(\);/.test(service),
    'reorderSubscriptions 未重写 sortOrder 并落盘');

  // ── U UI ──
  ok('u1.write-per-sub',
    /target\.autoUpdate\s*=\s*autoUpdate;/.test(section)
    && /target\.updateIntervalMinutes\s*=\s*nextInterval;/.test(section),
    'applyEdit 没有把开关/间隔写到订阅自己身上');
  ok('u2.no-global-write',
    !/s\.subscriptionUpdateIntervalMinutes\s*=/.test(section)
    && !/s\.autoUpdateSubscription\s*=\s*autoUpdate/.test(section),
    'applyEdit 仍在写全局设置（正是被报障的 bug：改一个订阅 = 改全部）');
  ok('u3.dialog-per-sub',
    /const s:\s*Subscription \| null = this\.subById\(this\.editTargetId\);\s*\n\s*return s === null \? this\.autoUpdateGlobal : s\.autoUpdate;/.test(section)
    && /s\.updateIntervalMinutes >= MIN_UPDATE_INTERVAL_MINUTES/.test(section),
    '编辑弹窗的初始值没按当前订阅取（改完保存会把别的订阅的值显示出来）');

  // ── T 调度器 ──
  ok('t1.per-sub-threshold',
    /s\.updateIntervalMinutes > 0/.test(scheduler) && /staleThresholdMs\(subMinutes\)/.test(scheduler),
    '调度器没有按每个订阅自己的间隔判定过期');
  ok('t2.per-sub-flag',
    /if \(!s\.autoUpdate\)/.test(scheduler),
    '调度器忽略了每订阅的自动更新开关');
  ok('t3.no-global-only',
    !/configuredStaleMs/.test(scheduler),
    '调度器仍用全局阈值（会让「每个订阅自己的间隔」失效）');

  // ── D 拖拽排序 ──
  ok('d1.gesture',
    /GestureGroup\(GestureMode\.Sequence,\s*\n\s*LongPressGesture\(\{ repeat: false, duration: 380 \}\)/.test(section)
    && /PanGesture\(\{ direction: PanDirection\.Vertical, distance: 3 \}\)/.test(section),
    '缺少「长按后拖动」的手势组合');
  ok('d2.persist-order',
    /this\.service\.reorderSubscriptions\(list\.map/.test(section),
    '松手后没有把新顺序落盘');
  ok('d3.spacing',
    /const SUB_CARD_SPACE:\s*number = 10;/.test(section) && /SUB_CARD_SPACE\)/.test(section),
    '缺少卡片间距常量（插入位置会算偏）');
  ok('d4.measured-height',
    /this\.subCardHeights\[index\] = Number\(nextArea\.height\);/.test(section),
    '没有实测卡片高度（卡片高度不一致时排序会错位）');
}

// ── 反向对照：改回旧写法后，对应的检查必须变成失败 ──
function anyFail(fn) {
  const localPass = pass;
  const localFails = fails.length;
  pass = 0;
  fails.length = 0;
  try {
    fn();
    return fails.length > 0;
  } finally {
    pass = localPass;
    fails.length = localFails;
  }
}

const base = loadAll();
checks(base);

const negatives = [
  ['N1 写回全局间隔', { ...base, section: base.section.replace('target.updateIntervalMinutes = nextInterval;',
    'this.autoUpdateIntervalMin = nextInterval;\n      await SettingsService.patchSettings((s: AppSettings): void => {\n        s.subscriptionUpdateIntervalMinutes = nextInterval;\n      });') }],
  ['N2 调度器忽略订阅开关', { ...base, scheduler: base.scheduler.replace('if (!s.autoUpdate) {', 'if (false) {') }],
  ['N3 重排不落盘', { ...base, service: base.service.replace('next[i].sortOrder = i;', '') }],
  ['N4 去掉长按手势', { ...base, section: base.section.replace('LongPressGesture({ repeat: false, duration: 380 })', 'TapGesture()') }]
];
for (const [label, mutated] of negatives) {
  const caught = anyFail(() => checks(mutated));
  ok(`neg.${label}`, caught, `反向对照未被捕获（说明该检查是空转的）`);
}

console.log('-----------------------------------------');
console.log(`PASSED=${pass}  FAILED=${fails.length}  TOTAL=${pass + fails.length}`);
if (fails.length > 0) {
  for (const f of fails) {
    console.log('  FAIL ' + f);
  }
  console.log('RESULT: SUBSCRIPTION SCHEDULE CHECKS FAILED');
  process.exit(1);
}
console.log(`RESULT: ALL SUBSCRIPTION SCHEDULE CHECKS PASSED (${negatives.length} negative controls caught)`);
