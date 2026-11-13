/**
 * 节点真源（Node Truth）—— 「这份配置的节点/组到底以谁为准」的**唯一判定点**。
 *
 * ## 要修的病根
 *
 * 旧实现里同一个已应用订阅有两份真相同时参与渲染：
 *   1. App 解析表 `SubscriptionService.nodes`（订阅原文解析出来的节点）；
 *   2. 内核 `/proxies` 目录（`CoreCatalogService`）。
 * `NodeSelectionPage.displayNodes()` 把内核里的**影子节点追加到 App 表后面**，
 * 于是同一订阅既有 App 节点、又有内核节点：名字对不上时出现重复行，选点/测速/
 * 配置生成三处各读一份，UI 显示「香港」而内核实际走「新加坡」。
 * FlClash 没有这个问题——它的节点清单只存在于内核，App 只做展示。
 *
 * ## 本模块的口径（与 FlClash 对齐）
 *
 * - **已应用 profile**：内核是唯一真源。节点 = 内核叶子；组 = 内核 `all` 的**直接成员**；
 *   当前出口 = `now` 链末端。App 表**不参与**该 profile 的任何判定。
 * - **其它（未应用）profile**：App 表是**预览**（FlClash 没有这个概念，属本仓保留的
 *   提前查看能力），必须显式标注 preview，且绝不能被当作"当前"用于选点/出口。
 * - 内核快照的**归属戳**必须与目标 profile 逐字相等；否则一律按 preview 处理，
 *   绝不用旧 profile 的目录冒充新订阅（历史上「A 订阅里出现 B 的节点」就是这个）。
 *
 * ## 为什么单独成文件
 *
 * 判定散落在页面里就会出现两套口径（本项目已经吃过一次：面板认 YAML-only、
 * 导入认判内容）。集中后，页面只调用本模块，"到底谁说了算"只有一处答案。
 */
import { CoreCatalogModel, CoreGroup, CoreNode } from './CoreCatalog';
import { CoreCatalogService, isBuiltinPolicy } from './CoreCatalogService';
import { ProxyGroup } from '../models/ProxyGroup';

/** 一次读取的作用域：内核真源 或 App 预览。 */
export class NodeTruthScope {
  /** true = 目标 profile 的节点/组以内核为准（唯一真源） */
  kernel: boolean = false;
  /** 目标 profile（订阅 id） */
  profileId: string = '';
  /** 内核目录快照；preview 时为 null */
  model: CoreCatalogModel | null = null;
  /** 快照的归属戳（诊断用：与 profileId 不等即说明快照不属于它） */
  snapshotProfileId: string = '';
}

export class NodeTruth {
  /** 已应用 profile：orchestrator 的已应用值优先，回退 current profile。 */
  static appliedProfileId(applied: string, current: string): string {
    return applied.length > 0 ? applied : current;
  }

  /**
   * 解析作用域。**只有**「快照归属戳 === 目标 profile」时内核才是真源。
   * 空 profileId 一律 preview（没有目标就没有"当前"可言）。
   */
  static scope(profileId: string): NodeTruthScope {
    const out = new NodeTruthScope();
    out.profileId = profileId;
    out.snapshotProfileId = CoreCatalogService.profileIdOfSnapshot();
    const model: CoreCatalogModel | null = CoreCatalogService.current();
    if (model !== null && profileId.length > 0 && out.snapshotProfileId === profileId) {
      out.kernel = true;
      out.model = model;
    }
    return out;
  }

  /** 该 profile 是否由内核提供唯一真源（页面据此决定走内核路径还是预览路径）。 */
  static isKernel(profileId: string): boolean {
    return NodeTruth.scope(profileId).kernel;
  }

  /** 内核里"该显示"的组（direct → 空；global → 含 hidden；其它 → 过滤 hidden）。 */
  static groupsFor(scope: NodeTruthScope, mode: string): CoreGroup[] {
    if (!scope.kernel || scope.model === null) {
      return [];
    }
    const all: CoreGroup[] = scope.model.groupsForMode(mode);
    return all === undefined ? [] : all;
  }

  /**
   * 内核叶子节点（可拨测/可选的真实代理）。
   *
   * 排除：组本身、内置策略（DIRECT/REJECT/…）、空名、以及**用户已删除**的节点。
   *
   * `hiddenKeys` 是 `SubscriptionService.listHiddenKeys()` 的键
   * （`<subId>|<server>|<port>|<baseName>`）。内核不提供 server/port，所以这里按
   * 「键尾是否恰好是 `|<内核节点名>`」匹配——对静态节点是精确的（名字即 baseName），
   * 对 provider 影子节点不误伤（它们本来就不在删除台账里）。
   */
  static leaves(scope: NodeTruthScope, mode: string, hiddenKeys: string[] = []): CoreNode[] {
    if (!scope.kernel || scope.model === null) {
      return [];
    }
    const out: CoreNode[] = [];
    const seen: Set<string> = new Set<string>();
    for (const group of NodeTruth.groupsFor(scope, mode)) {
      for (const node of group.all) {
        if (node.isGroup || node.name.length === 0 || seen.has(node.name)) {
          continue;
        }
        if (isBuiltinPolicy(node.name)) {
          continue;
        }
        if (NodeTruth.hidden(node.name, hiddenKeys)) {
          continue;
        }
        seen.add(node.name);
        out.push(node);
      }
    }
    return out;
  }

  /** 节点是否在删除台账里（见 leaves 的匹配说明）。 */
  static hidden(name: string, hiddenKeys: string[]): boolean {
    const suffix: string = `|${name}`;
    for (const key of hiddenKeys) {
      if (key.length > suffix.length && key.endsWith(suffix)) {
        return true;
      }
    }
    return false;
  }

  /**
   * 组的**直接成员**（Clash 语义，不递归）。
   * 返回 null = 内核不是该 profile 的真源，调用方必须走预览路径。
   */
  static group(scope: NodeTruthScope, groupName: string): CoreGroup | null {
    if (!scope.kernel || scope.model === null) {
      return null;
    }
    return scope.model.findGroup(groupName);
  }

  /**
   * 当前出口：沿 `now` 链一路追到底（FlClash `computeRealSelectedProxyState`）。
   * 空组/环/未知名字一律返回空串——绝不虚构出口。
   */
  static exitOf(scope: NodeTruthScope, name: string): string {
    if (!scope.kernel || scope.model === null || name.length === 0) {
      return '';
    }
    let current: string = name;
    const seen: Set<string> = new Set<string>();
    const limit: number = scope.model.groups.length + 1;
    for (let hop = 0; hop <= limit; hop++) {
      if (seen.has(current)) {
        return '';
      }
      seen.add(current);
      const node: CoreNode | null = scope.model.findNode(current);
      if (node === null) {
        return '';
      }
      if (!node.isGroup) {
        return node.name;
      }
      if (node.now.length === 0) {
        return '';
      }
      current = node.now;
    }
    return '';
  }

  /**
   * 内核组 → 页面用的只读投影（`ProxyGroup`）。
   *
   * 只用于渲染/计数：`members` 是**直接**成员名，顺序与内核 `all` 一致。
   * 它不是可生成配置的真源——真源是订阅原文，这里绝不能回写。
   */
  static projectGroup(scope: NodeTruthScope, group: CoreGroup): ProxyGroup {
    const out = new ProxyGroup();
    out.subscriptionId = scope.profileId;
    out.name = group.name;
    out.groupType = group.type;
    const members: string[] = [];
    for (const node of group.all) {
      members.push(node.name);
    }
    out.members = members;
    out.url = group.url;
    out.expectedStatus = group.expectedStatus;
    return out;
  }
}
