import { ProxyNode } from '../models/ProxyNode';
import { ProxyGroup } from '../models/ProxyGroup';
import { CoreNode, CoreGroup, CoreCatalogModel } from './CoreCatalog';
import { CoreNodeBridge } from './CoreNodeBridge';

/** 一次测速计划：可拨测名字、被跳过（内核不认识）的数量、组内声明的成员总数。 */
export class PanelDelayTarget {
  name: string = '';
  url: string = '';
  expected: string = '';

  key(): string { return JSON.stringify([this.url, this.expected, this.name]); }
}

export class DelayPlan {
  targets: PanelDelayTarget[] = [];
  names: string[] = [];
  skipped: number = 0;
  declared: number = 0;
}

/** A panel shows direct members, not the recursively flattened connection pool. */
export class ProxyPanelMembers {
  static type(type: string): string {
    const lower = type.toLowerCase();
    if (lower === 'select' || lower === 'selector') { return 'Selector'; }
    if (lower === 'url-test' || lower === 'urltest') { return 'URLTest'; }
    if (lower === 'fallback') { return 'Fallback'; }
    if (lower === 'load-balance' || lower === 'loadbalance') { return 'LoadBalance'; }
    if (lower === 'relay') { return 'Relay'; }
    if (lower === 'smart') { return 'Smart'; }
    return type;
  }

  static isGroup(node: ProxyNode): boolean {
    return ['Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay', 'Smart']
      .includes(ProxyPanelMembers.type(node.proxyType));
  }

  /** Direct/reject/pass policies are not remote proxy servers, even with custom names. */
  static isProxy(node: ProxyNode): boolean {
    const type = node.proxyType.toLowerCase();
    return !ProxyPanelMembers.isGroup(node) && type.length > 0
      && !['direct', 'reject', 'rejectdrop', 'reject-drop', 'pass', 'passrule', 'compatible', 'unknown'].includes(type)
      && !['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE', 'GLOBAL', 'REMAIN'].includes(node.name);
  }

  /** Direct has a meaningful URL-test result (also shown by ClashPlus). Reject,
   * pass and the empty-provider COMPATIBLE fallback do not. */
  static isTestable(node: ProxyNode): boolean {
    return ProxyPanelMembers.isGroup(node) || ProxyPanelMembers.isProxy(node)
      || node.proxyType.toLowerCase() === 'direct';
  }

  /**
   * 真实代理节点数（DIRECT / REJECT / 策略组都不算）。
   * 卡片摘要与「内核侧还没加载出代理」的回落判据都走它，不再拿文案当哨兵。
   */
  static proxyCount(nodes: ProxyNode[]): number {
    const names: Set<string> = new Set<string>();
    for (const node of nodes) {
      if (ProxyPanelMembers.isProxy(node)) { names.add(node.originalName || node.name); }
    }
    return names.size;
  }

  /**
   * 订阅卡片摘要（2026-11-03 用户口径：去掉「· N 分组」）。
   *
   * ClashPlus / FlClash 的卡片只关心「有多少可用节点」，分组数对用户没有信息量；
   * 反过来「0 节点 · 33 分组」这种组合曾被当成「导入失败」报障。所以这里只报真实
   * 代理数，一个都没有时返回空串 —— 卡片只留更新时间，具体原因由面板空状态解释。
   */
  static summary(nodes: ProxyNode[]): string {
    const count: number = ProxyPanelMembers.proxyCount(nodes);
    return count > 0 ? `${count} 节点` : '';
  }

  /** Smart has no single current exit; an empty provider still is not a target. */
  private static hasTestableMember(model: CoreCatalogModel, name: string,
    seen: Set<string> = new Set<string>()): boolean {
    if (seen.has(name)) { return false; }
    seen.add(name);
    const node = model.byName[name];
    if (node === undefined) { return false; }
    if (!node.isGroup) { return ProxyPanelMembers.isTestable(CoreNodeBridge.toProxyNode(node)); }
    const group = model.findGroup(name);
    return group !== null && group.all.some((member: CoreNode): boolean =>
      ProxyPanelMembers.hasTestableMember(model, member.name, seen));
  }

  /**
   * 组链路末端出口（FlClash `computeRealSelectedProxyState` 等价物）。
   *
   * 面板行可能是一张策略组卡片：它自己不是出口，真正被拨测的是 `now` 一路往下
   * 追到的那个节点。空组或环返回空串，不能虚构一个出口或把环当成可测速节点。
   */
  static exitOf(model: CoreCatalogModel, name: string): string {
    let current: string = name;
    const seen: Set<string> = new Set<string>();
    for (let hop = 0; hop <= model.groups.length; hop++) {
      if (seen.has(current)) { return ''; }
      seen.add(current);
      const node: CoreNode | undefined = model.byName[current];
      if (node === undefined || !node.isGroup) { return current; }
      const group: CoreGroup | null = model.findGroup(current);
      if (group !== null && group.type === 'Smart' && !group.all.some((member: CoreNode): boolean => member.name === group.now)) {
        return ProxyPanelMembers.hasTestableMember(model, group.name) ? group.name : '';
      }
      const next: string = group !== null && group.now.length > 0 ? group.now
        : (group !== null && group.all.length > 0 ? group.all[0].name : '');
      if (next.length === 0) { return ''; }
      current = next;
    }
    return '';
  }

  /** Group rows read their current exit only. An old measurement under the group
   * name belongs to its previous selection and must not mask the new exit. */
  static delayLookupNames(model: CoreCatalogModel | null, name: string): string[] {
    if (model === null) { return [name]; }
    const exit: string = ProxyPanelMembers.exitOf(model, name);
    return exit.length === 0 ? [name] : [exit];
  }

  static coreProxies(model: CoreCatalogModel): CoreNode[] {
    const out: CoreNode[] = [];
    for (const name of Object.keys(model.byName)) {
      const node = model.byName[name];
      if (!node.isGroup && ProxyPanelMembers.isProxy(CoreNodeBridge.toProxyNode(node))) { out.push(node); }
    }
    return out;
  }

  /**
   * 当前可见组的测速目标 = 成员的**真实出口**（去重、保持声明顺序）。
   *
   * 2026-11-03 对齐 FlClash：`delayTest(groups.all)` 之后 `computeRealSelectedProxyState`
   * 会把子策略组解析成实际出口名再拨测，所以同一出口只测一次，延迟也归到出口上。
   * 组不存在时退回全量真实代理（订阅级测速）。
   */
  static delayNames(model: CoreCatalogModel, groupName: string, excluded: string): string[] {
    return ProxyPanelMembers.delayPlan(model, groupName, excluded).names;
  }

  /** Resolve policy and exit together, so UI lookup and probing cannot disagree.
   * expected-status 不再继承：FlClash 取空 expected-status 范围（core/delay.go:99），
   * 组 url 仍可覆盖默认 url。defaultExpected/expected 字段仅保留兼容，不参与测速。 */
  static delayTarget(model: CoreCatalogModel, name: string, parent: string, defaultUrl: string,
    defaultExpected: string = '', localGroups: ProxyGroup[] = [],
    selections: Map<string, string> | null = null): PanelDelayTarget | null {
    const target = new PanelDelayTarget();
    target.url = defaultUrl;
    const policy = (groupName: string): void => {
      const local = localGroups.find((g: ProxyGroup): boolean => g.name === groupName);
      const core = model.findGroup(groupName);
      const url = local !== undefined ? local.url : (core === null ? '' : core.url);
      if (url.trim().length > 0) { target.url = url.trim(); }
    };
    policy(parent);
    let current = name;
    const seen: Set<string> = new Set<string>();
    for (let hop = 0; hop <= model.groups.length; hop++) {
      if (seen.has(current)) { return null; }
      seen.add(current);
      const node = model.byName[current];
      if (node === undefined) { return null; }
      if (!node.isGroup) {
        if (!ProxyPanelMembers.isTestable(CoreNodeBridge.toProxyNode(node))) { return null; }
        target.name = current;
        return target;
      }
      policy(current);
      const group = model.findGroup(current);
      if (group !== null && group.type === 'Smart' && !group.all.some((member: CoreNode): boolean => member.name === group.now)) {
        if (!ProxyPanelMembers.hasTestableMember(model, group.name)) { return null; }
        target.name = group.name;
        return target;
      }
      const saved = selections === null ? '' : selections.get(current) ?? '';
      current = group !== null && group.type === 'Selector' && saved.length > 0
        && group.all.some((member: CoreNode): boolean => member.name === saved) ? saved
        : (group !== null && group.now.length > 0 ? group.now
          : (group !== null && group.all.length > 0 ? group.all[0].name : ''));
      if (current.length === 0) { return null; }
    }
    return null;
  }

  /**
   * 测速计划：真正可拨测的名字 + 被跳过的名字数。
   *
   * 目录须先合并 /providers/proxies；provider 节点不在 /proxies 中是正常的 API 分工，
   * 不能因此把它们跳过。只有完整目录仍缺失的节点、空组和环才计入 skipped。
   */
  static delayPlan(model: CoreCatalogModel, groupName: string, excluded: string,
    defaultUrl: string = '', defaultExpected: string = '', localGroups: ProxyGroup[] = []): DelayPlan {
    const group = model.findGroup(groupName);
    const raw: string[] = [];
    if (group === null) {
      for (const node of ProxyPanelMembers.coreProxies(model)) { raw.push(node.name); }
    } else {
      for (const node of group.all) {
        if (node.name === excluded) { continue; }
        if (!ProxyPanelMembers.isTestable(CoreNodeBridge.toProxyNode(node)) && node.type.length > 0) { continue; }
        raw.push(node.name);
      }
    }
    const plan = new DelayPlan();
    const seen: Set<string> = new Set<string>();
    for (const name of raw) {
      const target = ProxyPanelMembers.delayTarget(model, name, groupName, defaultUrl, defaultExpected, localGroups);
      if (target === null) { plan.skipped += 1; continue; }
      if (seen.has(target.key())) { continue; }
      seen.add(target.key());
      plan.targets.push(target);
      plan.names.push(target.name);
    }
    plan.declared = raw.length;
    return plan;
  }

  static fromCore(group: CoreGroup, profileId: string, excluded: string): ProxyNode[] {
    return CoreNodeBridge.toProxyNodes(group.all.filter((node: CoreNode): boolean =>
      node.name !== excluded && !node.hidden), profileId);
  }

  static fromLocal(group: ProxyGroup, groups: ProxyGroup[], nodes: ProxyNode[], excluded: string): ProxyNode[] {
    const out: ProxyNode[] = [];
    const seen: Set<string> = new Set<string>();
    for (const name of group.members) {
      if (name === excluded) { continue; }
      const child = groups.find((g: ProxyGroup): boolean =>
        g.subscriptionId === group.subscriptionId && g.name === name);
      if (child !== undefined) {
        const core = new CoreNode(child.name, ProxyPanelMembers.type(child.groupType));
        core.isGroup = true;
        const row = CoreNodeBridge.toProxyNode(core, group.subscriptionId);
        if (!seen.has(row.id)) { seen.add(row.id); out.push(row); }
        continue;
      }
      const matches = nodes.filter((node: ProxyNode): boolean => node.subscriptionId === group.subscriptionId
        && (node.name === name || node.originalName === name));
      for (const node of matches) {
        if (!seen.has(node.id)) { seen.add(node.id); out.push(node); }
      }
      // Explicit built-in policies are valid selector members, never fake server nodes.
      if (matches.length === 0 && ['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE'].includes(name)) {
        out.push(CoreNodeBridge.toProxyNode(new CoreNode(name, name === 'DIRECT' ? 'Direct' : name),
          group.subscriptionId));
      }
    }
    return out;
  }

  static selections(raw: string): Record<string, string> {
    try {
      const values = JSON.parse(raw) as Record<string, string>;
      const out: Record<string, string> = {};
      if (values === null || Array.isArray(values) || typeof values !== 'object') { return out; }
      for (const key of Object.keys(values)) {
        if (typeof values[key] === 'string') { out[key] = values[key]; }
      }
      return out;
    } catch (_e) { return {}; }
  }

  static selected(raw: string, profileId: string, group: string): string {
    return ProxyPanelMembers.selections(raw)[`${profileId}\u0000${group}`] ?? '';
  }

  /** 该订阅保存的全部组选择（group → member），供连接时按 FlClash patchSelectGroup 重放。 */
  static selectionsFor(raw: string, profileId: string): Map<string, string> {
    const values = ProxyPanelMembers.selections(raw);
    const out: Map<string, string> = new Map<string, string>();
    const prefix: string = `${profileId}\u0000`;
    for (const key of Object.keys(values)) {
      if (key.startsWith(prefix) && key.length > prefix.length) {
        out.set(key.substring(prefix.length), values[key]);
      }
    }
    return out;
  }

  static remember(raw: string, profileId: string, group: string, member: string): string {
    const values = ProxyPanelMembers.selections(raw);
    values[`${profileId}\u0000${group}`] = member;
    return JSON.stringify(values);
  }
}
