#!/usr/bin/env node
/**
 * 单一真源 / Group 语义闸门（Single Source of Nodes Gate）
 *
 * ## 为什么要有这道闸门
 *
 * 用户报障的「UI 显示香港、内核实走新加坡」「A 订阅里出现 B 的节点」
 * 「选了父组成员却走到子组另一个出口」，根因不是某个 API 写错，而是**同一份配置
 * 有两份真相**：
 *   1. App 解析表 `SubscriptionService.nodes`；
 *   2. 内核 `/proxies` 目录。
 * 旧 `NodeSelectionPage.displayNodes()` 把内核影子**追加**到 App 表后面；
 * 组行又用 `expandProxyGroup()` 递归展开，把子组节点冒充成父组成员。
 * FlClash 只有一份真相（内核），面板语义是「组的直接成员 + 组当前 now」。
 *
 * ## 断言
 *
 *   A. `NodeTruth` 行为（执行生产 .ets，只替换平台/内核边界）
 *   B. 页面接线（按 profile 分工、组行内核优先、预览只允许在 else 分支）
 *   C. 负对照：Clash-only 订阅定案仍在（不属于本轮，不许顺手放宽）
 *
 * 退出码：0 = 全过；1 = 有断言失败。
 */
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const src = path.join(root, 'entry/src/main/ets');
const read = (p) => fs.readFileSync(path.join(src, p), 'utf8');

let passed = 0;
const failures = [];
function ok(name, condition) {
  if (condition) {
    passed += 1;
    console.log(`PASS ${name}`);
  } else {
    failures.push(name);
    console.log(`FAIL ${name}`);
  }
}

// ── 运行沙箱：只替换内核边界 ──────────────────────────────────────────
const ctx = vm.createContext({ console, Set, Map, JSON });
ctx.ProxyGroup = class ProxyGroup {
  constructor() {
    this.subscriptionId = '';
    this.name = '';
    this.groupType = '';
    this.members = [];
    this.url = '';
    this.expectedStatus = '';
  }
};
ctx.isBuiltinPolicy = (name) =>
  ['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE', 'REMAIN', 'GLOBAL'].includes(name);
const stamp = { profile: '', kernel: false, model: null };
ctx.CoreCatalogService = {
  current: () => stamp.model,
  profileIdOfSnapshot: () => stamp.profile
};
const code = read('commons/tunbox/NodeTruth.ets')
  .replace(/^import\b[\s\S]*?;\r?\n/gm, '')
  .replace(/^export /gm, '');
const { NodeTruth } = vm.runInContext(
  stripTypeScriptTypes(`(()=>{${code}\nreturn {NodeTruth,NodeTruthScope}})()`, { mode: 'transform' }), ctx);

// 假内核目录
function fakeModel() {
  const mk = (name, type, isGroup, now, all) =>
    ({ name, type, isGroup, now: now || '', all: all || [] });
  const leafA = mk('HK 01', 'Vless', false);
  const leafB = mk('JP 01', 'Trojan', false);
  const leafC = mk('SG 01', 'Hysteria2', false);
  const builtin = mk('DIRECT', 'Direct', false);
  const child = mk('自动', 'URLTest', true, 'JP 01', [leafB, leafC]);
  const parent = mk('PROXY', 'Selector', true, '自动', [leafA, child, builtin]);
  const byName = {};
  for (const n of [leafA, leafB, leafC, builtin, child, parent]) { byName[n.name] = n; }
  return {
    model: {
      groups: [parent, child],
      byName,
      groupsForMode: () => [parent, child],
      findGroup: (name) => [parent, child].find((g) => g.name === name) || null,
      findNode: (name) => byName[name] || null
    },
    leafA, leafB, leafC, parent, child
  };
}

// ── A1. 归属戳 ────────────────────────────────────────────────────────
{
  const { model } = fakeModel();
  stamp.model = model;
  stamp.profile = 'sub-B';
  const mismatch = NodeTruth.scope('sub-A');
  ok('truth.preview-on-stamp-mismatch', mismatch.kernel === false && mismatch.model === null);
  ok('truth.kernel-on-stamp-match', NodeTruth.scope('sub-B').kernel === true);
  ok('truth.preview-on-empty-profile', NodeTruth.scope('').kernel === false);
  stamp.model = null;
  ok('truth.preview-when-kernel-absent', NodeTruth.scope('sub-B').kernel === false);
}

// ── A2. 叶子：排除组/内置/重复/删除台账 ────────────────────────────────
{
  const { model } = fakeModel();
  stamp.model = model; stamp.profile = 'sub-B';
  const scope = NodeTruth.scope('sub-B');
  const names = NodeTruth.leaves(scope, 'rule', []).map((n) => n.name);
  ok('truth.leaves-exclude-groups', !names.includes('PROXY') && !names.includes('自动'));
  ok('truth.leaves-exclude-builtin', !names.includes('DIRECT'));
  ok('truth.leaves-dedupe', names.filter((n) => n === 'JP 01').length === 1);
  ok('truth.leaves-keep-all-leaves',
    names.includes('HK 01') && names.includes('JP 01') && names.includes('SG 01'));
  const hidden = NodeTruth.leaves(scope, 'rule', ['sub-B|1.2.3.4|443|JP 01']);
  ok('truth.leaves-respect-delete-ledger', !hidden.map((n) => n.name).includes('JP 01'));
  stamp.profile = 'sub-B';
  ok('truth.preview-has-no-kernel-leaves', NodeTruth.leaves(NodeTruth.scope('sub-A'), 'rule', []).length === 0);
}

// ── A3. 出口链 / Group 语义 ───────────────────────────────────────────
{
  const { model, parent } = fakeModel();
  stamp.model = model; stamp.profile = 'sub-B';
  const scope = NodeTruth.scope('sub-B');
  ok('truth.exit-follows-now-chain', NodeTruth.exitOf(scope, 'PROXY') === 'JP 01');
  ok('truth.exit-returns-leaf-itself', NodeTruth.exitOf(scope, 'HK 01') === 'HK 01');
  ok('truth.exit-unknown-is-empty', NodeTruth.exitOf(scope, 'NOPE') === '');
  const cycle = fakeModel();
  cycle.parent.now = '自动';
  cycle.child.now = 'PROXY';
  stamp.model = cycle.model;
  const cyc = NodeTruth.scope('sub-B');
  ok('truth.exit-cycle-is-empty', NodeTruth.exitOf(cyc, 'PROXY') === '');

  const projected = NodeTruth.projectGroup(scope, parent);
  ok('truth.project-direct-members-only',
    projected.members.length === 3 && projected.members.includes('自动')
    && !projected.members.includes('JP 01'));
  ok('truth.project-keeps-group-type', projected.groupType === 'Selector');
  ok('truth.project-stamps-profile', projected.subscriptionId === 'sub-B');
}

// ── B. 页面接线 ───────────────────────────────────────────────────────
const page = read('pages/NodeSelectionPage.ets');
{
  const display = (page.match(/private displayNodes\(\): ProxyNode\[\] \{[\s\S]*?\n  \}/) || [''])[0];
  ok('wire.display-uses-node-truth',
    display.includes('NodeTruth.appliedProfileId(') && display.includes('NodeTruth.scope(appliedId)')
    && display.includes('NodeTruth.leaves('));
  ok('wire.display-no-app-kernel-merge',
    !display.includes('CoreCatalogService.flattenNodes('));
  ok('wire.display-explicit-degrade', display.includes('显式降级'));

  const rebuild = (page.match(/private rebuildRows\(\): void \{[\s\S]*?\n  \}/) || [''])[0];
  const kernelAt = rebuild.indexOf('if (truth.kernel) {');
  const previewAt = rebuild.indexOf('} else if (this.filterSubId.length > 0 && !hasCoreOnlyRows) {');
  const expandAt = rebuild.indexOf('this.subs.expandProxyGroup(group)');
  ok('wire.group-kernel-first', kernelAt >= 0 && previewAt > kernelAt);
  ok('wire.group-preview-only-in-else', expandAt > previewAt);
  ok('wire.group-direct-members', rebuild.includes('NodeTruth.projectGroup(truth, coreGroup)'));

  ok('wire.scroll-kernel-aware',
    page.includes('CoreCatalogService.groupOfNode(nodeName)'));
  ok('wire.group-count-direct', page.includes('${strategy.members.length} 个节点'));
  ok('wire.smart-known-names-from-truth',
    /private knownNodeNames\(\): string\[\] \{[\s\S]*?for \(const n of this\.displayNodes\(\)\)/.test(page));
}

// ── C. 已定案不得被顺手放开 ───────────────────────────────────────────
{
  const service = read('commons/services/SubscriptionService.ets');
  ok('decision.node-delete-ledger-kept', service.includes('listHiddenKeys(): string[]'));
  ok('decision.clash-only-guard-still-exists',
    service.includes('static isClashBody(body: string): boolean'));
}

console.log(`\n单一真源 / Group 语义闸门：${passed} passed, ${failures.length} failed`);
if (failures.length > 0) {
  console.log(`FAILED: ${failures.join(', ')}`);
  process.exit(1);
}
