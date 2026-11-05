#!/usr/bin/env node
/**
 * provider-only 节点可见性源码契约。
 *
 * 回归场景：mihomo `/proxies` 已有 80+ 个由 `proxy-providers/use` 动态注入的节点，
 * 但 App 本地 `subs.nodes` 为空。节点页与主页订阅面板必须使用带 profile 归属戳的
 * CoreCatalog 影子节点，且不能把影子当成可本地删除的静态节点。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const nodePage = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/pages/NodeSelectionPage.ets'), 'utf8').replace(/\r\n/g, '\n');
const section = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/components/SubscriptionSection.ets'), 'utf8').replace(/\r\n/g, '\n');
// 2026-11-04：节点真源收口到 NodeTruth（判定点单一化），归属校验搬到了它里面。
const nodeTruth = fs.readFileSync(
  path.join(root, 'entry/src/main/ets/commons/tunbox/NodeTruth.ets'), 'utf8').replace(/\r\n/g, '\n');

let passed = 0;
let failed = 0;
function check(name, condition) {
  if (condition) {
    passed++;
    console.log(`PASS ${name}`);
  } else {
    failed++;
    console.error(`FAIL ${name}`);
  }
}

check('节点页以内核为唯一真源（NodeTruth），不再把 App 本地表当基线合并',
  nodePage.includes('private displayNodes(): ProxyNode[]')
    && nodePage.includes('const truth: NodeTruthScope = NodeTruth.scope(appliedId);')
    && nodePage.includes("NodeTruth.leaves(truth, 'rule', excluded)")
    && nodePage.includes('CoreNodeBridge.toProxyNodes(')
    && !nodePage.includes('this.subs.nodes.slice()'));
check('节点页严格校验内核快照的 profile 归属',
  nodeTruth.includes('out.snapshotProfileId === profileId')
    && nodePage.includes('NodeTruth.appliedProfileId('));
check('节点列表不再只遍历 subs.nodes',
  nodePage.includes('for (const n of this.displayNodes())'));
check('provider 运行期成员不会被空的本地组视图遮住',
  nodePage.includes('const hasCoreOnlyRows: boolean = rows.some')
    && nodePage.includes('this.filterSubId.length > 0 && !hasCoreOnlyRows'));
check('未连接时会预热内核并刷新 provider 目录',
  nodePage.includes('private async refreshCoreBackedRows(): Promise<void>')
    && nodePage.includes('await this.orchestrator.prewarmLatencyChannel()')
    && nodePage.includes('CoreCatalogService.refresh(this.orchestrator.api, true, profileId)'));
check('provider 影子节点可选中但不能本地删除',
  nodePage.includes("await this.orchestrator.reconnectWithNode(node, this.subs, 'preferredNode=' + node.id)")
    && /if \(CoreNodeBridge\.isShadow\(row\.node\)\) \{\s*return;\s*\}\s*\/\/[^\n]*\n\s*this\.enterSelectMode\(row\.node\.id\)/.test(nodePage));
check('主页面板仅在归属匹配时接受空本地表的内核节点',
  section.includes('localNodes.length === 0 && !this.coreCatalogFor(this.panelSubId)')
    && section.includes('ProxyPanelMembers.coreProxies(core)')
    && section.includes('CoreCatalogService.forProfile(subId, this.profileRevisionFor(subId))'));
check('主页面板不再以缺少本地凭据拒绝 provider 节点',
  !section.includes('该内核节点缺少可用凭据，请刷新订阅后重试')
    && section.includes('if (local !== undefined) {\n        node = local;'));
check('主页面板禁止删除远端 provider 影子',
  section.includes('该节点由远端 provider 管理，不能在本地删除'));

console.log(`\n${passed} passed, ${failed} failed`);
if (failed > 0) {
  process.exit(1);
}
