/**
 * 延迟显示契约自检（2026-10-18 用户裁定）。
 *
 * 契约：节点行只允许出现「实测延迟（含离线 ≈ms）」或「超时/失败」，
 * **不允许**把已经测出的失败按来源改写成中性「未测」。
 *
 * 背景：`TunBoxPing.recordText` / `LatencyStyle.recordText` 曾对
 * `source === 'auto'`（冷启动、进入节点页、导入订阅后的静默批）的失败返回
 * 「未测」。真机表现为「导入订阅后一大片未测」，用户明确指出这会误导
 * （以为根本没测速），要求「要么显示延迟多少、要么显示超时」。
 *
 * 本脚本读源码做结构断言，防止这条契约被无意改回去。
 * 用法: node scripts/verify-latency-display.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');

let pass = 0;
const fails = [];
function ok(name, cond, extra) {
  if (cond) { pass += 1; console.log(`  ✓ ${name}`); }
  else { fails.push(name + (extra ? ` (${extra})` : '')); console.log(`  ✗ ${name}${extra ? ` — ${extra}` : ''}`); }
}

/** 取出「静态方法名(」到其方法体结束的粗略区段（用于逐渲染器断言） */
function methodBody(src, signature) {
  const i = src.indexOf(signature);
  if (i < 0) return '';
  // 向后找到下一个同级方法声明作为终点，避免跨方法误判
  const rest = src.slice(i + signature.length);
  const next = rest.search(/\r?\n  static [A-Za-z]/);
  return next < 0 ? rest : rest.slice(0, next);
}

const targets = [
  { file: 'entry/src/main/ets/theme/TunBoxTokens.ets', ns: 'TunBoxPing' },
  { file: 'entry/src/main/ets/theme/UiTokens.ets', ns: 'LatencyStyle' },
];

console.log('\n延迟显示契约自检（失败一律显示超时/失败，不得按来源改写为未测）');

for (const t of targets) {
  const full = path.join(root, t.file);
  const src = fs.readFileSync(full, 'utf8');
  const text = methodBody(src, 'static recordText(rec: LatencyRecord | null, nowMs: number): string {');
  const color = methodBody(src, 'static recordColor(rec: LatencyRecord | null, nowMs: number): ResourceColor {');

  ok(`${t.ns}.recordText 存在`, text.length > 0);
  ok(`${t.ns}.recordColor 存在`, color.length > 0);

  // 核心契约：不得再有 "source === 'auto'" 的失败特判
  ok(`${t.ns}.recordText 不再按 source==='auto' 改写成未测`,
    !/source\s*===\s*'auto'/.test(text), 'auto-source failure special-case came back');
  ok(`${t.ns}.recordText 不再返回「未测」字面量`,
    !/return\s*'未测'/.test(text));
  ok(`${t.ns}.recordColor 不再按 source==='auto' 走中性色`,
    !/source\s*===\s*'auto'/.test(color));

  // 失败结论必须落到**唯一真源** LatencyStore.describe（审计 LP05：主题里那份
  // stateText 包装删掉了，两份一模一样 ⇒ 收敛成一张表）。
  // 2026-10-19 起 state 只有「失败」一档，分不出「内核里没这个节点」(switch_failed)
  // 与「真超时」(timeout)。describe 带 failKind ⇒ 不会退回"404 和 504 完全一样"。
  ok(`${t.ns}.recordText 失败走 LatencyStore.describe`,
    /LatencyStore\.describe\(rec\.failKind,\s*rec\.delayMs,\s*rec\.atMs,\s*nowMs\)/.test(text));
  ok(`${t.ns}.recordText 不再自己调 LatencyPolicy.stateText`,
    !/LatencyPolicy\.stateText\(/.test(text));
  // 必须仍然保留离线 ≈ 前缀与"没数据 = --"语义
  ok(`${t.ns}.recordText 保留离线 ≈ 前缀`,
    /`≈\$\{body\}`/.test(text) || /≈/.test(text));
  ok(`${t.ns}.recordText 无记录时仍为 --`, /return\s*'--'/.test(text));
  // 失败配色必须走真源的级别（BAD = 红）
  ok(`${t.ns}.recordColor 失败走真源的 BAD 级别`,
    /LatencyViewLevel\.BAD/.test(color) && /LatencyStore\.describe\(/.test(color));
  // 「节点未生效」（内核里没它）必须走警告色，不能和"节点坏了"一样红
  ok(`${t.ns}.recordColor 对未生效用警告色`,
    /LatencyViewLevel\.WARN[\s\S]{0,120}?warning/i.test(color));
}

// 反例守护：**别又长出第二张渲染表**（审计 LP05）。
// 渲染表（结论文案 + 级别）唯一真源 = commons/latency/LatencyStore.describe；
// 行为级断言在 verify-latency-core-v2（那里能真正执行 describe）。
const stateSrc = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/commons/services/LatencyState.ets'), 'utf8');
ok('LatencyState 不再自带第二张渲染表（stateText 已删）',
  !/static\s+stateText\s*\(/.test(stateSrc));
ok('LatencyState 不再自带 isNotEffective 分类表',
  !/static\s+isNotEffective\s*\(/.test(stateSrc));

// ── 失败分类必须一路带到 UI（2026-10-19 新增契约）────────────────────
// 反例守护：分类若在运行时被丢掉，switch_failed（节点没进内核配置）与 timeout
// （真超时）会再次在用户侧完全一样 —— 真机教训：36 个 anytls 被丢弃 → 内核 404
// → UI 全红，用户以为节点坏了（实际节点可用、代理正常）。
ok('LatencyRecord 带 failKind 字段',
  /class LatencyRecord[\s\S]{0,2000}?failKind\s*:\s*string\s*=\s*''/.test(stateSrc));
ok('渲染表在真源里（LatencyStore.describe 带 failKind + testedAt）',
  /static\s+describe\(failKind:\s*string,\s*delayMs:\s*number,\s*testedAt:\s*number,\s*nowMs:\s*number\)/.test(
    fs.readFileSync(path.join(root, 'entry/src/main/ets/commons/latency/LatencyStore.ets'), 'utf8')));
ok('「节点未生效」的判定归真源（LatencyStore.describe 对 switch_failed 给「未生效」）',
  /'未生效'/.test(
    fs.readFileSync(path.join(root, 'entry/src/main/ets/commons/latency/LatencyStore.ets'), 'utf8')));

const engineSrc = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/commons/services/LatencyEngine.ets'), 'utf8');
ok('LatencyEngine 把 probe.failKind 写进记录',
  /LatencyRecord\.failed\([^;]*probe\.failKind/.test(engineSrc));

const persistSrc = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/pages/NodeSelectionPage.ets'), 'utf8');
ok('持久化转换优先使用 rec.failKind（不再从 state 重新盖章）',
  /toPersistRecord[\s\S]{0,600}?rec\.failKind\.length\s*>\s*0/.test(persistSrc));

// ── 测速唯一入口 = LatencyEngine（2026-10-21 收敛，2026-10-22 补闸门）──────────
// 契约：页面层不得再实现「内核侧组测速」（`GET /group/{name}/delay`）。
// 历史形态：NodeSelectionPage 曾有一套 runGroupLatency，只有它自己用、且该页没有任何
// 导航入口 → 死路径，还会与订阅页闪电测速形成两套口径（超时判定/失败分类不同源）。
// 现在「测全部」与「单节点/单订阅测速」全部走同一个引擎。
ok('页面层不再实现内核侧组测速（无 /group/ 端点、无 runGroupLatency）',
  !/runGroupLatency/.test(persistSrc) && !/\/group\//.test(persistSrc));
ok('「测全部」统一走 LatencyEngine',
  /LatencyEngine\.start\(/.test(persistSrc));
// 2026-10-22 用户口径：测速完成提示**不许带计数**（"可用 X / 超时 Y / 未生效 Z" 是自造噪音，
// 用户点名「谁让你乱加的，赶快去掉」）。"没测成"的原因（过载/通道不可用）仍要单独说明。
ok('测速完成提示不带计数（只有「✓ 测速完成」）',
  /'✓ 测速完成'/.test(persistSrc)
  && !/可用 \$\{progress\.measured\}/.test(persistSrc)
  && !/可用 \$\{progress\.measured\}/.test(fs.readFileSync(
    path.join(root, 'entry/src/main/ets/pages/SubscriptionPage.ets'), 'utf8')));

// 2026-10-23 用户要求：所有组级失败统计提示一律移除，诊断数据仍留在日志。
const subPageSrc = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/pages/SubscriptionPage.ets'), 'utf8');
ok('测速完成提示不带控制器过载计数',
  !/coreOverloaded\s*>\s*0|个节点控制器过载未测/.test(subPageSrc));
ok('进度映射把 coreOverloaded 交给调用方（后台测速返回 progress）',
  /Promise<LatencyProgress\s*\|\s*null>/.test(fs.readFileSync(
    path.join(root, 'entry/src/main/ets/commons/services/BackgroundLatencyService.ets'), 'utf8'))
  && /return progress;/.test(fs.readFileSync(
    path.join(root, 'entry/src/main/ets/commons/services/BackgroundLatencyService.ets'), 'utf8')));

// ── 内核组测速：唯一实现 = BackgroundLatencyService.runKernelGroupTest（2026-10-22）──
// 订阅页行尾按钮 / 冷启动静默批 / 大订阅都调这一处，避免三套 504/通道/未生效判定。
const bgSrc = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/commons/services/BackgroundLatencyService.ets'), 'utf8');
// 2026-10-22（用户要求「测速完全按 FlClash」）：组测速 = 组内节点**逐个测**，
// 不再调内核 `GET /group/{name}/delay`；唯一实现是 FlclashLatencyService.start。
const flcSrc = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/commons/flclash/FlclashDelay.ets'), 'utf8');
ok('组测唯一入口 = FlclashLatencyService（逐节点，不再调内核组接口）',
  /FlclashLatencyService\.start\(/.test(bgSrc) && !/testGroupDetailedResult/.test(bgSrc));
ok('订阅展开区保留可访问的闪电测速入口',
  /accessibilityText\('闪电测速'\)/.test(subPageSrc)
  && /onClick\(\(\) => this.speedTestSub\(sub.id\)\)/.test(subPageSrc));
ok('组测在途有防重入 + 转圈',
  /if \(this\.groupTesting\) \{\s*return;/.test(subPageSrc)
  && /@State groupTesting: boolean = false;/.test(subPageSrc));
const flcServiceSrc = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/commons/flclash/FlclashLatencyService.ets'), 'utf8');
ok('组测/批量结果有可检索的完成日志（total/measured/timeout/failed/cancelled）',
  /delay batch done: total=\$\{summary\.total\} measured=\$\{summary\.measured\}/.test(flcServiceSrc)
  && /cancelled=\$\{summary\.cancelled\}/.test(flcServiceSrc));
// ── 2026-10-22 真机 bug：失败节点显示 "--" 而不是「超时/拨号失败」 ─────────────
// 根因：FlclashLatencyService.apply 把非超时失败写成表外字面量 `'failed'`，
// 而 LatencyStore.describe() 只认 LatencyProbeKind 里的分类，认不出就 else → '--'。
ok('失败结果写 LatencyProbeKind 真分类（timeout / switch_failed / network_unreachable）',
  /LatencyProbeKind\.TIMEOUT/.test(flcServiceSrc)
  && /LatencyProbeKind\.SWITCH_FAILED/.test(flcServiceSrc)
  && /LatencyProbeKind\.NETWORK_UNREACHABLE/.test(flcServiceSrc)
  && /import \{[^}]*LatencyProbeKind[^}]*\} from/.test(flcServiceSrc));
ok('不再写表外失败分类字面量（: \'failed\' 会让 describe() 落到 --）',
  !/result\.value === FLCLASH_DELAY_TIMED_OUT \? 'timeout' : 'failed'/.test(flcServiceSrc));
// 2026-10-26（用户拍板）：超时 5000 → 3000（「等 5 秒太久」）；并发基线仍 32，
// 上限由 FLCLASH_DELAY_MAX_CONCURRENCY 管（64，配 TCP 直连传输层才真的并发）。
ok('并发基线 32 / 单节点超时 3000ms / 测速地址 gstatic https',
  /FLCLASH_DELAY_CONCURRENCY: number = 32/.test(flcSrc)
  && /FLCLASH_DELAY_TIMEOUT_MS: number = 3000/.test(flcSrc)
  && /https:\/\/www\.gstatic\.com\/generate_204/.test(flcSrc));
ok('大订阅与小订阅同一条路径（不存在「≥120 节点改内核组测」的分叉）',
  !/KERNEL_GROUP_TEST_MIN_NODES/.test(bgSrc));

const apiSrc = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/commons/services/ClashApiService.ets'), 'utf8');
ok('ClashApiService 提供 proxyTableNames（内核代理表全名）',
  /async proxyTableNames\(\): Promise<string\[\] \| null>/.test(apiSrc));

// ── 测速超时与并发度（2026-10-19 用户要求：超时 5s、并发 88 → 2026-10-20 整改为 50）──
// 契约：单节点超时、组测预算、并发度三者必须一致 —— 同一节点在「测全部」
// 和「单节点测速」里用不同尺子，结论会相反。
//
// 2026-10-20（订阅解析内核化整改 C8b）：并发度由 88 收敛为 50。
//   88 是「并发 worker 数」口径下的旧值，与 FlClash 的核内批量限流数值对齐但机制不同；
//   50 = worker 数（队列深度）；2026-10-20 用户拍板：在途请求数也放开为 LATENCY_INFLIGHT=50
//   （不再有应用层排队 ⇒ 每个节点的 elapsed 就是它自己那次 /delay 的真实耗时）。
//   另注：C7 之后「排队等待」不再计入单请求超时预算，故并发度不再是超时算术的前提。
// 2026-10-20（lead 拍板迁移）：超时数值真源搬到零 import 的
// commons/latency/LatencyKinds.ets 的 LatencyTimeout；LatencyState.LatencyPolicy
// 只剩转调 getter ⇒ 断言改判**真源**，并额外要求转调关系存在（不许留第二份字面量）。
// 2026-10-21（真机回退）：在途并发由 50 收敛为 8 —— 50 路在途会把 controller 打满，
//   客户端侧 2300028 被归成 core_not_ready ⇒ 6 连击作废整批（飞鸟云 31 节点批只测了 7 个）。
//   8 = OHOS http 栈对同一 host 的连接池容量 ⇒ 排队改在应用层闸门里发生，不污染读数。
const kindsSrc = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/commons/latency/LatencyKinds.ets'), 'utf8');
// 2026-10-21（用户对标三家）：超时由 3s 回到 **5s**（FlClash 8s / Verge 10s / CMFA 5s），
// 在途并发由 50 收敛为 8 = OHOS http 栈对同一 host 的连接池容量（排队改在应用层闸门里发生）。
// 2026-10-26（用户第二次要求缩短）：5000 → 3000，与 FLCLASH_DELAY_TIMEOUT_MS 同值。
ok('单节点测速超时为 3000ms（真源 LatencyTimeout.DEFAULT_TIMEOUT_MS）',
  /DEFAULT_TIMEOUT_MS:\s*number\s*=\s*3000/.test(kindsSrc));
ok('LatencyPolicy 的超时是转调真源（不留第二份字面量）',
  /return\s+LatencyTimeout\.DEFAULT_TIMEOUT_MS;/.test(stateSrc)
  && !/DEFAULT_TIMEOUT_MS:\s*number\s*=\s*\d+/.test(stateSrc));
ok('并发测速数为 50（C8b：由 88 收敛，worker 口径）', /LATENCY_CONCURRENCY\s*=\s*50/.test(engineSrc));
// 2026-10-21：在途由 8 放开到 32（用户要求对齐 FlClash 客户端在途 32）。
// ⚠ 断言必须打**声明行**：曾经写成 `LATENCY_INFLIGHT\s*=\s*8`，结果命中的是注释里
// 那句「LATENCY_INFLIGHT=8」，代码改回 8→32 时闸门照样绿（假绿，2026-10-22 发现）。
ok('在途并发上限为 32（对齐 FlClash 客户端在途；回退点依次 16 → 8）',
  /export const LATENCY_INFLIGHT = 32;/.test(engineSrc));
ok('组测每节点预算转调单节点真源（不留第二份字面量）',
  /export const GROUP_TEST_TIMEOUT_MS = LatencyPolicy\.DEFAULT_TIMEOUT_MS;/.test(engineSrc));
ok('内核延迟探测默认超时转调同一真源（不留 3000/5000 字面量）',
  /timeoutMs: number = LatencyPolicy\.DEFAULT_TIMEOUT_MS/.test(apiSrc));
// 离线探测器（DirectLatencyTester）已被测速内核（LP07）取代 —— 文件不在了就跳过这条，
// 但**不许**因为文件缺失而整个闸门崩掉（那会让「文件已删」看起来像「契约破了」）。
const directTesterPath = path.join(root, 'entry/src/main/ets/commons/services/DirectLatencyTester.ets');
if (fs.existsSync(directTesterPath)) {
  ok('离线探测的阶段预算同步为 5s（不被 2.5s 截断）',
    /QUIC_TIMEOUT_MS\s*=\s*5000/.test(fs.readFileSync(directTesterPath, 'utf8')));
} else {
  ok('离线探测器已被测速内核取代（文件已删，跳过阶段预算断言）', true);
}
ok('批次硬截止可注入（0 = 自动，测试注入小值仍生效）',
  /batchDeadlineMs: number = 0;/.test(engineSrc)
  && /batchDeadlineMs > 0/.test(engineSrc)
  && /static deadlineForBatch\(nodeCount: number\): number/.test(engineSrc));

for (const name of ['SubscriptionPage', 'NodeSelectionPage']) {
  const page = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages', `${name}.ets`), 'utf8');
  ok(`${name} 不再展示组级失败诊断`,
    !/subDiagnosisText|latencyGroupDiagnosis|groupDiagnosis\(/.test(page));
  ok(`${name} 不再展示超时或过载数量提示`,
    !/全部节点超时|个节点控制器过载未测/.test(page));
}

console.log(`\n延迟显示契约自检：${pass} 条通过，${fails.length} 条失败`);
if (fails.length > 0) {
  console.error('失败：' + fails.join(' | '));
  process.exit(1);
}
console.log('全部通过（失败一律显示超时/失败，不再有按来源改写的「未测」）');
process.exit(0);
