#!/usr/bin/env node
/**
 * 延迟结果存储回归（运行时，非源码断言）。
 *
 * 把 `LatencyState.ets` / `LatencyLiveView.ets` 按 .ts 暂存到临时目录后直接 import，
 * 真实驱动状态机与存储（Node 24 的 type-stripping 只接受可擦除语法，所以这两个文件
 * 必须避免 `enum`；LatencyState 因此用 class + static readonly）。
 *
 * 覆盖（延迟测试重做后新增的语义）：
 *  1. 旧数字入口的兼容语义：`set(n, >=1)` → 实测；`set(n, -1)` → 超时；`set(n, -2)` → 未测
 *  2. 五态可区分：未测**不是**超时（旧实现把 -2 也画成"超时"）
 *  3. `latencyFor` 兼容视图：TIMEOUT/FAILED → -1，UNTESTED/TESTING/CANCELLED → null
 *  4. 过期结果保留但可判旧（LatencyPolicy.isStale）
 *  5. retainOnly 回收已消失节点，且只在真正删除时通知
 *  6. `delay == 0` 绝不当有效延迟（mihomo 用 0 表示失败）
 *  7. 排序：失败**永不排最前**，实测按延迟升序
 *  8. 组对象与内建项必须被过滤（实测 PROXY.all 里混着 14 个组条目）
 */
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';

const appRoot = resolve(import.meta.dirname, '..');
const services = join(appRoot, 'entry', 'src', 'main', 'ets', 'commons', 'services');
const sandbox = join(tmpdir(), 'tunbox-latency-cache-' + process.pid);
rmSync(sandbox, { recursive: true, force: true });
mkdirSync(sandbox, { recursive: true });
writeFileSync(join(sandbox, 'package.json'), JSON.stringify({ type: 'module' }), 'utf8');

/** 暂存一个 .ets 为 .ts，并把无扩展名的相对 import 补成 .ts（Node ESM 要求显式扩展名） */
function stage(fileName) {
  const src = readFileSync(join(services, fileName + '.ets'), 'utf8')
    .replace(/from '(\.\/[A-Za-z0-9_]+)'/g, "from '$1.ts'")
    // 本闸门的沙箱是**扁平**的：跨目录的零 import 分类常量模块（LP04 新口径）
    // 要改指到沙箱根 —— LatencyKinds 已在 stageLatencyCore() 里暂存在根目录。
    .replace(/from '\.\.\/latency\/LatencyKinds'/g, "from './LatencyKinds.ts'");
  writeFileSync(join(sandbox, fileName + '.ts'), src, 'utf8');
}

stage('LatencyState');
stage('LatencyLiveView');

/**
 * 暂存测速内核（LatencyStore 及其依赖）+ @kit 桩。
 *
 * 为什么需要：主题的渲染表现在**唯一真源 = LatencyStore.describe**（审计 LP05），
 * 主题文件因此 import 了 commons/latency/LatencyStore —— 那条链带 @kit.ArkData /
 * @kit.NetworkKit / @kit.ArkTS 与 AppLogger/AppSettings，Node 下要桩掉。
 * （同一套桩见 verify-latency-core-v2 / verify-latency-restore。）
 */
function stageLatencyCore() {
  const latencyDir = join(appRoot, 'entry', 'src', 'main', 'ets', 'commons', 'latency');
  const core = ['LatencyStore', 'LatencyProbe', 'LatencyTestUrl', 'LatencyDnsVerdict', 'LatencyKinds'];
  for (const name of core) {
    const src = readFileSync(join(latencyDir, name + '.ets'), 'utf8')
      .replace(/from '@kit\.NetworkKit'/g, "from './fakeNetworkKit.ts'")
      .replace(/from '@kit\.ArkTS'/g, "from './fakeArkTS.ts'")
      .replace(/from '@kit\.ArkData'/g, "from './fakeArkData.ts'")
      .replace(/from '\.\.\/utils\/AppLogger'/g, "from './AppLogger.ts'")
      .replace(/from '\.\.\/models\/AppSettings'/g, "from './AppSettings.ts'")
      .replace(/from '\.\/(LatencyProbe|LatencyTestUrl|LatencyDnsVerdict|LatencyKinds)'/g, "from './$1.ts'");
    writeFileSync(join(sandbox, name + '.ts'), src, 'utf8');
  }
  writeFileSync(join(sandbox, 'AppLogger.ts'), `
export class AppLogger {
  static info(_tag: string, _msg: string): void {}
  static warn(_tag: string, _msg: string): void {}
  static error(_tag: string, _msg: string): void {}
  static errText(e: Object): string { return e === null || e === undefined ? String(e) : String(e); }
}
`, 'utf8');
  writeFileSync(join(sandbox, 'AppSettings.ts'), `
export class AppSettings {
  testLatencyUrl: string = 'https://www.gstatic.com/generate_204';
}
`, 'utf8');
  writeFileSync(join(sandbox, 'fakeNetworkKit.ts'), `
export const http = {
  RequestMethod: { GET: 0, POST: 1 },
  createHttp(): Object { return { request: async (): Promise<Object> => ({}), destroy: (): void => {} }; }
};
`, 'utf8');
  writeFileSync(join(sandbox, 'fakeArkTS.ts'), `
export const util = {
  TextDecoder: {
    create(_enc: string): Object {
      return { decodeToString: (a: Uint8Array): string => Buffer.from(a).toString('utf8') };
    }
  }
};
`, 'utf8');
  writeFileSync(join(sandbox, 'fakeArkData.ts'), `
export const preferences = {
  getPreferences: async (_ctx: Object, _name: string): Promise<Object> => ({
    get: async (_k: string, d: Object): Promise<Object> => d,
    put: async (_k: string, _v: Object): Promise<void> => {},
    flush: async (): Promise<void> => {},
    getAll: async (): Promise<Object> => ({})
  })
};
`, 'utf8');
}

stageLatencyCore();

const checks = [];
function check(label, ok) {
  checks.push([label, !!ok]);
}

try {
  const { LatencyLiveView } = await import(pathToFileURL(join(sandbox, 'LatencyLiveView.ts')).href);
  const { LatencyProbe } = await import(pathToFileURL(join(sandbox, 'LatencyProbe.ts')).href);
  const { LatencyState, LatencyPolicy, LatencyRecord, LatencyChannel } =
    await import(pathToFileURL(join(sandbox, 'LatencyState.ts')).href);

  // ---- 1/2/3 兼容入口与五态 ----
  LatencyLiveView.clearAll();
  LatencyLiveView.set('active-a', 31);
  LatencyLiveView.set('stale-b', 92);
  LatencyLiveView.set('active-c', -1);
  LatencyLiveView.set('untested-d', -2);
  check('set(>=1) 记为实测', LatencyLiveView.latencyFor('active-a') === 31);
  check('set(-1) 记为超时', LatencyLiveView.latencyFor('active-c') === -1);
  check('set(-1) 状态是 TIMEOUT', LatencyLiveView.stateFor('active-c') === LatencyState.TIMEOUT);
  check('set(-2) 状态是 UNTESTED（不是超时）',
    LatencyLiveView.stateFor('untested-d') === LatencyState.UNTESTED);
  check('未测节点的 latencyFor 是 null（UI 显示 --）',
    LatencyLiveView.latencyFor('untested-d') === null);
  // 渲染表（结论文案 + 级别）**唯一真源 = LatencyStore.describe**（审计 LP05）：
  // LatencyState 里那份 stateText 包装已删 —— 行为级断言在 verify-latency-core-v2
  // （那里能真正执行 LatencyStore.describe），这里只守「别又长出第二张表」。
  const stateSrcForTable = readFileSync(
    join(appRoot, 'entry/src/main/ets/commons/services/LatencyState.ets'), 'utf8');
  check('LatencyState 不再自带第二张渲染表（stateText 已删）',
    !/static\s+stateText\s*\(/.test(stateSrcForTable));
  check('LatencyState 不再自带 isNotEffective 分类表',
    !/static\s+isNotEffective\s*\(/.test(stateSrcForTable));
  // 陈旧判定（ND14）与「算不算结论」（ND13）：判定表**只有一份**，都在零 import 的
  // 内核分类表 LatencyKinds 里；LatencyState 这三个入口只做转调/别名。
  // 注释里的字面量不算「第二份阈值」⇒ 断言只看代码部分。
  const stateCodeOnly = stateSrcForTable
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\/\/.*$/gm, '');
  check('LatencyState 不再自带陈旧阈值字面量（阈值只一份，在内核分类表）',
    !/10\s*\*\s*60\s*\*\s*1000/.test(stateCodeOnly));
  check('LatencyPolicy.isStale 转调内核判定表（不自己判）',
    /static\s+isStale\s*\([^)]*\)\s*:\s*boolean\s*\{[\s\S]*?LatencyProbeKind\.isStale\(/.test(stateSrcForTable));
  check('LatencyPolicy.isStaleConclusion 转调内核判定表（年龄未知的失败仍算陈旧）',
    /static\s+isStaleConclusion\s*\([^)]*\)\s*:\s*boolean\s*\{[\s\S]*?LatencyProbeKind\.isStale\(/.test(stateSrcForTable));
  check('LatencyPolicy.isNonVerdictKind 转调内核唯一判定表（不自带第二份清单）',
    /static\s+isNonVerdictKind\s*\([^)]*\)\s*:\s*boolean\s*\{\s*return\s+LatencyProbeKind\.isNonVerdictKind\(/.test(stateSrcForTable));

  // markTesting 不产生数值结论
  LatencyLiveView.markTesting('testing-e');
  check('markTesting → TESTING 状态', LatencyLiveView.stateFor('testing-e') === LatencyState.TESTING);
  check('markTesting 期间 latencyFor 为 null（不显示旧数字）',
    LatencyLiveView.latencyFor('testing-e') === null);

  // ---- 4 过期判定 ----
  const fresh = LatencyRecord.measured('n1', 50, LatencyChannel.CORE, Date.now());
  const old = LatencyRecord.measured('n2', 50, LatencyChannel.CORE, Date.now() - LatencyPolicy.STALE_MS - 1000);
  check('新鲜结果不判旧', LatencyPolicy.isStale(fresh, Date.now()) === false);
  check('超阈值结果判旧（灰显但不删除）', LatencyPolicy.isStale(old, Date.now()) === true);
  check('未测结果不判旧（无时间戳可判）',
    LatencyPolicy.isStale(LatencyRecord.untested('n3'), Date.now()) === false);

  // ---- 5 retainOnly ----
  LatencyLiveView.retainOnly(['active-a', 'active-c', 'untested-d', 'testing-e']);
  check('已消失节点被回收', LatencyLiveView.latencyFor('stale-b') === null);
  check('保留节点数值不变', LatencyLiveView.latencyFor('active-a') === 31);

  // ---- 6 delay==0 不是有效延迟 ----
  check('0ms 不是有效延迟（mihomo 用 0 表示失败）', LatencyPolicy.isValidDelay(0) === false);
  check('负数不是有效延迟', LatencyPolicy.isValidDelay(-1) === false);
  check('1ms 是有效延迟', LatencyPolicy.isValidDelay(1) === true);
  check('65535（mihomo 的"没测过"哨兵）不是有效延迟',
    LatencyPolicy.isValidDelay(65535) === false);

  // ---- 7 分类与排序 ----
  // 失败分类**唯一真源 = 测速内核**（LatencyProbe.classify，审计 LP06：
  // LatencyState 里的旧数值状态机 classify 已删）。这里直接打内核那张表；
  // 行为级完整覆盖在 verify-latency-core-v2（C 组 10 例）。
  check('200 + 合法 delay → 成功结论（判定）',
    LatencyProbe.classify(200, '{"delay":87}', '').kind === ''
    && LatencyProbe.classify(200, '{"delay":87}', '').isVerdict === true);
  check('200 + delay=0 不是「0ms 很快」→ 认不出来（非判定）',
    LatencyProbe.classify(200, '{"delay":0}', '').kind === 'unknown'
    && LatencyProbe.classify(200, '{"delay":0}', '').isVerdict === false);
  check('504 归为超时（判定）',
    LatencyProbe.classify(504, '{"message":"timeout"}', '').kind === 'timeout');
  check('503 + dial 错误归为「拨号失败」（判定，不是超时）',
    LatencyProbe.classify(503, '{"message":"dial tcp 1.2.3.4:443: i/o timeout"}', '').kind
      === 'network_unreachable');
  check('404（节点已不存在）归为「未生效」（配置类判定）',
    LatencyProbe.classify(404, '{"message":"proxy not found"}', '').kind === 'switch_failed');
  check('传输层异常归为通道未就绪（非判定，不是节点结论）',
    LatencyProbe.classify(0, '', 'connect refused').kind === 'core_not_ready'
    && LatencyProbe.classify(0, '', 'connect refused').isVerdict === false);

  const measured = LatencyRecord.measured('m', 80, LatencyChannel.CORE, Date.now());
  const slow = LatencyRecord.measured('s', 400, LatencyChannel.CORE, Date.now());
  const offline = LatencyRecord.measured('o', 30, LatencyChannel.OFFLINE, Date.now());
  const untested = LatencyRecord.untested('u');
  const timedOut = LatencyRecord.failed('t', LatencyState.TIMEOUT, Date.now());
  const failed = LatencyRecord.failed('f', LatencyState.FAILED, Date.now());
  const order = [failed, timedOut, untested, offline, slow, measured].sort(LatencyPolicy.compare);
  check('排序：实测最快在最前', order[0].name === 'm');
  check('排序：实测慢的排在实测快的之后', order[1].name === 's');
  check('排序：离线粗略排在实测之后', order[2].name === 'o');
  check('排序：未测在失败之前', order.indexOf(untested) < order.indexOf(timedOut));
  check('排序：失败**永不排最前**', order[0].state !== LatencyState.FAILED && order[0].state !== LatencyState.TIMEOUT);
  check('排序：失败在最后', order[order.length - 1].name === 'f');
  check('离线结果带 OFFLINE 状态（UI 显示 ≈ 前缀）', offline.state === LatencyState.OFFLINE);

  // ---- 8 组对象 / 内建项过滤 ----
  check('Selector 组不可作为被测节点', LatencyPolicy.isTestableType('Selector') === false);
  check('URLTest 组不可测', LatencyPolicy.isTestableType('URLTest') === false);
  check('Fallback 组不可测', LatencyPolicy.isTestableType('Fallback') === false);
  check('LoadBalance 组不可测', LatencyPolicy.isTestableType('LoadBalance') === false);
  check('Relay 组不可测', LatencyPolicy.isTestableType('Relay') === false);
  check('Direct 内建项不可测', LatencyPolicy.isTestableType('Direct') === false);
  check('Reject 内建项不可测', LatencyPolicy.isTestableType('Reject') === false);
  check('Shadowsocks 真实节点可测', LatencyPolicy.isTestableType('Shadowsocks') === true);
  check('Hysteria2 真实节点可测', LatencyPolicy.isTestableType('Hysteria2') === true);
  check('Vless 真实节点可测', LatencyPolicy.isTestableType('Vless') === true);
  check('DIRECT 名字是内建项', LatencyPolicy.isBuiltinNode('DIRECT') === true);
  check('REJECT-DROP 名字是内建项', LatencyPolicy.isBuiltinNode('REJECT-DROP') === true);
  check('普通节点名不是内建项', LatencyPolicy.isBuiltinNode('hy2台湾01') === false);

  // ---- 9 用户可见的徽标文案/配色：必须真跑，不能只 grep 源码 ----
  // LatencyStyle.recordText/recordColor 是"五态可区分"这条 UX 要求的全部实现，
  // 但此前只被源码正则断言覆盖（从未执行）。这里把 UiTokens.ets 一并暂存后真实驱动。
  {
    const themeDir = join(appRoot, 'entry', 'src', 'main', 'ets', 'theme');
    let uiSrc = readFileSync(join(themeDir, 'UiTokens.ets'), 'utf8');
    // UiTokens 顶部依赖 ArkUI 的全局类型（ResourceColor/LengthMetrics 等）与 @ohos kit：
    // 只为取 LatencyStyle，注入最小桩并把 ohos import 换成空实现。
    // UiTokens 依赖 ArkUI 的全局 `$r()` 与全局类型 ResourceColor。只为取 LatencyStyle，
    // 注入最小桩：$r 返回"资源名字符串"（桩里正好当成颜色标签用），并让 Ui.* 变成
    // 可比较的独立标签，从而 recordColor 的相等/不等断言有意义。
    uiSrc = uiSrc
      // 只把 LatencyState 指向沙箱；LatencyStore 是内核真源（已暂存在沙箱里），
      // 指向它自己 —— 不能一股脑重写成 LatencyState（那会让主题拿不到 describe）。
      .replace(/from '\.\.\/commons\/services\/LatencyState'/g, "from './LatencyState.ts'")
      .replace(/from '\.\.\/commons\/latency\/LatencyStore'/g, "from './LatencyStore.ts'")
      .replace(/^import .*@ohos.*$/gm, '');
    const prelude = [
      'type ResourceColor = string;',
      'function $r(name: string): string { return "R:" + name; }',
      '',
    ].join('\n');
    writeFileSync(join(sandbox, 'UiTokens.ts'), prelude + uiSrc, 'utf8');
    const { LatencyStyle } = await import(pathToFileURL(join(sandbox, 'UiTokens.ts')).href);

    const now = 1_000_000;
    const fresh = LatencyRecord.measured('fresh', 90, LatencyChannel.CORE, now);
    const old = LatencyRecord.measured('old', 90, LatencyChannel.CORE, now - 11 * 60 * 1000);
    const off = LatencyRecord.measured('off', 25, LatencyChannel.OFFLINE, now);
    const unt = LatencyRecord.untested('unt');
    const testing = LatencyRecord.failed('testing', LatencyState.TESTING, now);
    const cancelled = LatencyRecord.failed('cancelled', LatencyState.CANCELLED, now);
    const to = LatencyRecord.failed('to', LatencyState.TIMEOUT, now);
    const bad = LatencyRecord.failed('bad', LatencyState.FAILED, now);
    // 新口径（审计 F13/LP05）：**没有失败分类 = 没有结论** ⇒ 渲染成「未测(--)」，
    // 不许渲染成一颗红「超时」。真正有分类的失败才带结论与红色。
    to.failKind = 'timeout';
    bad.failKind = 'network_unreachable';
    const legacyNoKind = LatencyRecord.failed('legacy-no-kind', LatencyState.FAILED, now);

    // 五态文案两两不同 —— 这就是"可区分"的可执行定义
    const texts = [fresh, old, off, unt, testing, cancelled, to, bad]
      .map((r) => LatencyStyle.recordText(r, now));
    check('未测显示 --，绝不是"超时"（旧实现最大的可信度问题）',
      LatencyStyle.recordText(unt, now) === '--');
    check('未测与超时文案不同',
      LatencyStyle.recordText(unt, now) !== LatencyStyle.recordText(to, now));
    check('无分类的失败不渲染成红「超时」（新口径：没有分类 = 没有结论）',
      LatencyStyle.recordText(legacyNoKind, now) === '--');
    check('取消与失败/超时文案都不同（取消不是结论）',
      LatencyStyle.recordText(cancelled, now) !== LatencyStyle.recordText(bad, now)
      && LatencyStyle.recordText(cancelled, now) !== LatencyStyle.recordText(to, now));
    check('五态以上文案两两可区分', new Set(texts).size === texts.length);
    check('null 记录显示 --', LatencyStyle.recordText(null, now) === '--');

    check('实测文案带 ms', LatencyStyle.recordText(fresh, now) === '90ms');
    check('离线粗略值带 ≈ 前缀（不冒充代理延迟）',
      LatencyStyle.recordText(off, now).startsWith('≈'));
    check('过期结果被标注但仍显示数值',
      LatencyStyle.recordText(old, now).startsWith('90ms')
      && LatencyStyle.recordText(old, now) !== '90ms');

    check('实测按阈值配色（<180 绿 / <350 黄 / >=350 红）',
      LatencyStyle.recordColor(LatencyRecord.measured('a', 100, LatencyChannel.CORE, now), now)
        === LatencyStyle.recordColor(fresh, now)
      && LatencyStyle.recordColor(LatencyRecord.measured('b', 400, LatencyChannel.CORE, now), now)
        !== LatencyStyle.recordColor(fresh, now));
    check('过期结果用中性色（不假装新鲜）',
      LatencyStyle.recordColor(old, now) !== LatencyStyle.recordColor(fresh, now));
    check('超时与失败用错误色',
      LatencyStyle.recordColor(to, now) === LatencyStyle.recordColor(bad, now));
    check('未测/测试中/取消用中性色（不吓用户）',
      LatencyStyle.recordColor(unt, now) === LatencyStyle.recordColor(testing, now)
      && LatencyStyle.recordColor(cancelled, now) === LatencyStyle.recordColor(unt, now));
    check('超时色与未测色不同（失败必须看得见）',
      LatencyStyle.recordColor(to, now) !== LatencyStyle.recordColor(unt, now));
    // 旧数字入口的兼容语义仍在（ohosTest LogicTest 也断言这三个）
    check('兼容入口 text(-1) = 超时', LatencyStyle.text(-1) === '超时');
    check('兼容入口 text(null) = --', LatencyStyle.text(null) === '--');
    check('兼容入口 color(120) 与 color(400) 不同',
      LatencyStyle.color(120) !== LatencyStyle.color(400));
  }
} finally {
  rmSync(sandbox, { recursive: true, force: true });
}

let failedCount = 0;
for (const [label, ok] of checks) {
  if (!ok) {
    failedCount++;
  }
  console.log((ok ? 'PASS ' : 'FAIL ') + label);
}
console.log(`\n${checks.length - failedCount}/${checks.length} passed, ${failedCount} failed`);
if (failedCount > 0) {
  process.exitCode = 1;
}
