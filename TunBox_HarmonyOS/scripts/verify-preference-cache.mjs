#!/usr/bin/env node
/**
 * 偏好缓存契约门禁（2026-10-27 架构收口）
 *
 * ## 守的是什么
 *
 * `settings.preferredNode*` 只能是**用户偏好缓存**，「当前是什么节点」的唯一真源
 * 是内核 `/proxies` 里主出口组的 `now`。真机事故：UI 显示「香港移联01」、内核实际
 * 走「新加坡01aws」，最后空转 134s 报「节点选择未生效」—— 根因就是偏好被当成了
 * 当前状态：拿一个**属于旧订阅**的名字去 `PUT /proxies/<组>`，必然 400。
 *
 * 本门禁把这些不变量钉死，防止以后再退回去：
 *   1. 契约注释必须存在于 AppSettings（说明 preferredNode* 只是缓存）；
 *   2. connectExclusive 必须先读内核（readKernelSelection）再考虑 PUT；
 *   3. 已连接时 displayNodeName 必须读 ConnectionTarget，不得读偏好；
 *   4. ConnectionTarget 必须是连接目标的唯一产出点；
 *   5. 热重载切订阅时必须先认内核出口（liveNode），偏好只作兜底；
 *   6. 钉选组名不得再硬编码 'PROXY'，且 YAML 解析必须去 CRLF。
 */
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const ETS = join(root, 'entry', 'src', 'main', 'ets');
const read = (p) => readFileSync(p, 'utf8');
const exists = (p) => { try { read(p); return true; } catch { return false; } };

let pass = 0;
let fail = 0;
function ok(name, cond, msg) {
  if (cond) { pass++; console.log(`  ✓ ${name}`); }
  else { fail++; console.log(`  ✗ ${name} — ${msg}`); }
}
function methodBody(code, signature) {
  const idx = code.indexOf(signature);
  if (idx < 0) return null;
  const open = code.indexOf('{', idx + signature.length);
  if (open < 0) return null;
  let depth = 0;
  for (let i = open; i < code.length; i++) {
    if (code[i] === '{') depth++;
    else if (code[i] === '}') { depth--; if (depth === 0) return code.slice(open + 1, i); }
  }
  return null;
}

const settingsPath = join(ETS, 'commons', 'models', 'AppSettings.ets');
const orchPath = join(ETS, 'commons', 'services', 'ConnectionOrchestrator.ets');
const apiPath = join(ETS, 'commons', 'services', 'ClashApiService.ets');
const settingsServicePath = join(ETS, 'commons', 'services', 'SettingsService.ets');
const rcbPath = join(ETS, 'commons', 'config', 'RuntimeConfigBuilder.ets');

console.log('[PC1] preferredNode* 只是偏好缓存（契约注释 + 唯一真源声明）');
{
  const s = exists(settingsPath) ? read(settingsPath) : '';
  ok('pc1.settings-exists', s.length > 0, '找不到 AppSettings.ets');
  ok('pc1.contract-cache', /用户偏好缓存/.test(s), 'AppSettings 缺少「偏好缓存」契约注释');
  ok('pc1.contract-kernel-truth', /唯一真源/.test(s) && /\/proxies/.test(s),
    '契约必须写明「当前节点唯一真源 = 内核 /proxies」');
  ok('pc1.contract-forbidden', /禁止的写法/.test(s), '契约必须列出禁止写法');
}

console.log('[PC2] 连接路径：先读内核，再决定是否 PUT');
{
  const o = exists(orchPath) ? read(orchPath) : '';
  const body = o.length > 0 ? methodBody(o, 'private async connectExclusive(') : null;
  ok('pc2.connect-found', body !== null, '找不到 connectExclusive');
  const text = body ?? '';
  const kernelAt = text.indexOf('readKernelSelection(');
  const putAt = text.indexOf('this.api.selectNode(');
  ok('pc2.kernel-read-before-put', kernelAt >= 0 && putAt >= 0 && kernelAt < putAt,
    '必须先 readKernelSelection 再 selectNode（否则又拿偏好覆盖内核真源）');
  ok('pc2.kernel-adopt', /adoptedByKernel/.test(text), '缺少「采用内核当前出口」的分支');
  ok('pc2.target-object', /new ConnectionTarget\(/.test(text),
    '连接目标必须由 ConnectionTarget 承载（单一事实源）');
  ok('pc2.self-heal', /selfHealPreferredNode\(/.test(text),
    '落到与偏好不同的节点时必须回写偏好');
}

console.log('[PC3] 显示路径：内核真源优先，偏好只兜底');
{
  const o = exists(orchPath) ? read(orchPath) : '';
  const body = o.length > 0 ? methodBody(o, 'displayNodeName(preferredNodeId: string') : null;
  const text = body ?? '';
  ok('pc3.display-found', body !== null, '找不到 displayNodeName');
  const targetAt = Math.min(...[text.indexOf('kernelSelection.nodeName()'), text.indexOf('lastConnectionTarget')].filter((i) => i >= 0));
  const prefAt = Math.min(...[text.indexOf('preferredNodeInCurrentProfile'), text.indexOf('resolveUserPreference')]
    .filter((i) => i >= 0));
  ok('pc3.display-target-first', targetAt >= 0 && prefAt > targetAt,
    'displayNodeName 必须先读内核出口（kernelSelection）再用偏好兜底（顺序反了就会显示旧值）');
  ok('pc3.display-not-state-gated', !/ConnState\.CONNECTED[\s\S]{0,120}(kernelSelection|lastConnectionTarget)/.test(text),
    '显示不得以「已连接」为前提：内核换了出口而偏好没同步时也要显示事实');
  ok('pc3.display-label', /connectionTargetLabel\(\)/.test(o),
    '缺少 connectionTargetLabel()：「组 → 节点」的统一展示值');
}

console.log('[PC4] 内核出口变化必须自动同步到显示与偏好');
{
  const o = exists(orchPath) ? read(orchPath) : '';
  ok('pc4.hot-live-first', /liveNode/.test(o) && /kernelSelection\.nodeName\(\)/.test(o),
    '热重载必须先认内核出口（liveNode），不能直接用 preferredNodeId 定目标');
  ok('pc4.refresh-exists', /async refreshExitFromKernel\(/.test(o),
    '缺少 refreshExitFromKernel：内核出口变化后没人把真源同步给 UI');
  ok('pc4.refresh-wired', /refreshExitFromKernel\(\)\.catch\(/.test(o),
    'refreshExitFromKernel 必须挂在运行期轮询里（否则永不执行）');
  ok('pc4.refresh-self-heal', /refreshExitFromKernel[\s\S]{0,1200}selfHealPreferredNode\(/.test(o),
    '内核出口变化后必须回写偏好缓存，否则下次冷启动又读旧值');
}

console.log('[PC6] 旧「决策式」命名必须退役');
{
  const files = [orchPath, apiPath, settingsPath,
    join(ETS, 'commons', 'services', 'SubscriptionService.ets'),
    join(ETS, 'commons', 'services', 'VpnQuickStart.ets'),
    join(ETS, 'pages', 'HomePage.ets'),
    join(ETS, 'pages', 'SubscriptionPage.ets'),
    join(ETS, 'pages', 'NodeSelectionPage.ets')];
  let stale = '';
  for (const f of files) {
    if (!exists(f)) { continue; }
    if (/resolvePreferredNode\s*\(/.test(read(f))) { stale = f; break; }
  }
  ok('pc6.no-resolve-preferred', stale.length === 0,
    `仍有 resolvePreferredNode() 调用：${stale}（已改名 resolvePreferenceHint，语义=偏好提示）`);
  const sub = exists(join(ETS, 'commons', 'services', 'SubscriptionService.ets'))
    ? read(join(ETS, 'commons', 'services', 'SubscriptionService.ets')) : '';
  ok('pc6.hint-named', /async resolvePreferenceHint\(/.test(sub),
    'SubscriptionService 必须暴露 resolvePreferenceHint（名字即契约）');
  ok('pc6.hint-doc', /偏好缓存给[出的]*候选节点|用户偏好缓存/.test(sub),
    'resolvePreferenceHint 必须写明「提示，不是当前状态」');
}

console.log('[PC7] 设置写放大整治（内存 → 合并 → 防抖落盘）');
{
  const sp = exists(settingsServicePath) ? read(settingsServicePath) : '';
  ok('pc7.memory-cache', /private static cache: AppSettings \| null/.test(sp),
    'SettingsService 必须有进程内缓存（否则每次读盘）');
  ok('pc7.debounce', /FLUSH_DELAY_MS/.test(sp) && /scheduleFlush\(\)/.test(sp),
    '缺少防抖落盘（每次 save 直接 flush = 写放大）');
  ok('pc7.flush-now', /static async flushNow\(/.test(sp),
    '缺少 flushNow（关键点强制落盘，防抖窗口不丢数据）');
  ok('pc7.peek', /static peek\(\): AppSettings \| null/.test(sp),
    '缺少 peek()：UI 需要同步读取，否则退回传参旧模型');
  ok('pc7.save-coalesced', /SettingsService\.pending = AppSettings\.fromJson\(stored\)/.test(sp),
    'save() 必须先更新缓存+待落盘快照，而不是直接 put/flush');
  const o = exists(orchPath) ? read(orchPath) : '';
  ok('pc7.flush-before-launch', /SettingsService\.flushNow\(\)[\s\S]{0,120}startVpnExtensionAbility/.test(o),
    '拉起 VPN 扩展（独立进程）前必须强制刷盘');
}

console.log('[PC8] ConnectionOrchestrator 拆分边界与统一读取口');
{
  const kmPath = join(ETS, 'commons', 'services', 'KernelSelectionManager.ets');
  ok('pc8.manager-exists', exists(kmPath), '缺少 KernelSelectionManager.ets（第一个应拆出的边界）');
  const km = exists(kmPath) ? read(kmPath) : '';
  ok('pc8.manager-owns-target', /current\(\): ConnectionTarget \| null/.test(km) && /syncFromKernel\(/.test(km),
    '管理器必须独占「当前出口」状态与内核对齐职责');
  const o = exists(orchPath) ? read(orchPath) : '';
  ok('pc8.orchestrator-delegates', /private kernelSelection: KernelSelectionManager/.test(o)
    && !/private lastConnectionTarget/.test(o),
    '编排器必须委托管理器，不得自持一份出口状态');
  ok('pc8.unified-api', /getCurrentNodeName\(\): string/.test(o) && /getCurrentConnectionTarget\(\): ConnectionTarget \| null/.test(o),
    '缺少 getCurrentNodeName()/getCurrentConnectionTarget() 统一读取口');
  const hp = join(ETS, 'pages', 'HomePage.ets');
  const subp = join(ETS, 'pages', 'SubscriptionPage.ets');
  const hpText = exists(hp) ? read(hp) : '';
  const subText = exists(subp) ? read(subp) : '';
  ok('pc8.ui-uses-unified', /getCurrentNodeName\(\)/.test(hpText) && /getCurrentNodeName\(\)/.test(subText),
    '主页/订阅页必须调用 getCurrentNodeName()（不得再传 preferredNodeId）');
  ok('pc8.ui-no-legacy-args', !/displayNodeName\(\s*this\.settings\.preferredNodeId/.test(hpText + subText),
    '页面不得再用 displayNodeName(preferredNodeId, …) 旧签名');
}

console.log('[PC5] 钉选组名不得硬编码 PROXY；YAML 解析必须去 CRLF');
{
  const r = exists(rcbPath) ? read(rcbPath) : '';
  ok('pc5.no-hardcoded-proxy', !/firstProxyMember\(\s*finalYaml\s*,\s*'PROXY'/.test(r),
    '不得再用硬编码 PROXY 解析主组（必须从 rules 反查）');
  ok('pc5.rule-lookup', /parseRuleTargets\(/.test(r), '缺少 parseRuleTargets（从规则反查真实组）');
  ok('pc5.crlf', /splitYamlLines\(/.test(r), '缺少 splitYamlLines（CRLF 会让顶层键判定恒失败）');
  ok('pc5.escapes', /decodeYamlEscapes\(/.test(r), '缺少 YAML 转义还原（\\U0001F1ED… emoji）');
  ok('pc5.normalize', /nodeKey\(/.test(r) && /cjkRuns\(/.test(r),
    '缺少节点名归一化（emoji/地区前缀差异）');
  const a = exists(apiPath) ? read(apiPath) : '';
  ok('pc5.kernel-selection-api', /async readKernelSelection\(/.test(a),
    'ClashApiService 缺少 readKernelSelection（内核真源读取入口）');
}

console.log('-----------------------------------------');
if (fail === 0) {
  console.log(`PASSED=${pass} FAILED=0`);
  console.log('RESULT: PREFERENCE CACHE CONTRACT HOLDS');
  process.exit(0);
}
console.log(`PASSED=${pass} FAILED=${fail}`);
console.log('RESULT: PREFERENCE CACHE CONTRACT BROKEN');
process.exit(1);
