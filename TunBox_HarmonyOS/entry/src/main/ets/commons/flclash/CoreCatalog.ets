/**
 * 内核节点目录（Core Catalog）：从 mihomo REST `GET /proxies` 构建 FlClash 同构的分组 / 节点视图。
 *
 * 职责：
 *  1) 解析 `{"proxies":{NAME:{...}}}` 响应为 CoreGroup / CoreNode 模型（不臆造字段）；
 *  2) 组类型判定（Selector / URLTest / Fallback / Relay / LoadBalance）；
 *  3) 内置 `GLOBAL` 组标记 hidden；
 *  4) 节点排序（延迟优先 / 名称）、隐藏超时节点；
 *  5) 延迟文案与配色；
 *  6) 选择节点的 REST 请求构造（**只造 method/path/body，不发 HTTP**）。
 *
 * 来源（逐条对齐；任何偏离都在下面的「关键口径」里写明）：
 *  - `ref/flclash/core/proxy.go:51-60`  isProxyGroupType：只有这 5 个 AdapterType 算组。
 *  - `ref/flclash/core/proxy.go:84-142` handleGetProxies / proxyView / isBuiltInGlobal：
 *      非组只给 {name,type}；组额外给 now / all / url / history；内置 GLOBAL（reserved
 *      provider）额外打 `"hidden": true`；组名列表里没有 GLOBAL 时把它插到**最前**。
 *  - `lib/providers/state/proxies.dart:4-25`  currentGroupsState：
 *      direct → 空列表；global → 全部组；rule → `hidden == false`。
 *  - `lib/common/compute.dart:65-107` computeHideTimeout：整组成员被隐藏光时**保留原组**
 *      （否则该组连测速入口一起消失）。
 *  - `lib/models/common.dart:957-975` DelayState.priority / compareTo。
 *  - `lib/ui/color.dart:333-339` delayColor；
 *    `lib/views/dashboard/widgets/proxy_groups.dart:113-121` 文案分支 +
 *    `delayColor(delay > 0 ? delay : -1)` 的取色包装。
 *  - `kernel/Clash.Meta/hub/route/proxies.go`：
 *      PUT `/proxies/{name}` body `{"name":"..."}`（updateProxy）；
 *      DELETE `/proxies/{name}`（unfixedProxy：只对**非 Selector** 的 SelectAble 生效，
 *      Selector 直接 400，所以「取消选择」只能用于 URLTest / Fallback / LoadBalance）。
 *  - `kernel/Clash.Meta/adapter/adapter.go:134-162`：每个代理条目都带
 *      `history:[{"time":..,"delay":..}]`（uint16，失败记 0）。
 *
 * 关键口径（含刻意偏离，勿随手改）：
 *  - `url` 键：上游 mihomo 用 `"url"`，本仓库内核（Clash.Meta fork）用 `"testUrl"`。
 *    解析时两者都认（`url` 优先），所以两份真实响应都能吃。
 *  - `hidden`：响应里的 `hidden === true` **或** 名字是 `GLOBAL`。
 *    取 OR 而不是「字段优先」：TunBox 直连的原版 mihomo 里内置 GLOBAL 的 Selector
 *    `Hidden()` 就是 false（`proxyView` 里那句 `view["hidden"]=true` 是 FlClash
 *    自己在 Go 侧补的），只信字段会让 GLOBAL 留在 rule 模式列表里。名字判定与
 *    `isBuiltInGlobal` 等价（内置 GLOBAL 恒来自 reserved provider）。
 *  - 排序**严格照 Dart compareTo**：priority → delay 升序 → 组优先 → 0。
 *    即「组优先」只是同优先级同延迟时的最后 tiebreak；把组提到 delay 之前会让
 *    900ms 的组排到 20ms 的节点前面，FlClash 不这么做。
 *    唯一增量：末级补 `name.localeCompare`，让全等价项顺序确定（Dart 返回 0 且
 *    `List.sort` 不稳定）。
 *  - 无延迟记录按 0 处理（priority 1），照 `computeProxyDelayState` 的
 *    `delayMap[...] ?? 0`；**不是** priority 3。
 *  - `lastDelay` 取 history 末条的 delay，history 缺失/为空 → -1；内核原值保留
 *    （失败时是 0），这里不改写成 -1，免得把「超时」和「拒绝连接」混成一种。
 *  - 0 的取色陷阱：`delayColor(0)` 按 Dart 是 success，但真机仪表盘从不传 0，
 *    统一走 `delayColor(delay > 0 ? delay : -1)`。要画「失败」请用 `displayColor()`。
 *  - 组顺序：解析结果把 GLOBAL 放最前（对齐 proxyGroupNames），其余保持响应出现顺序。
 *    `/proxies` 是 Go map 序列化，其余组的顺序本身不保证稳定 —— 需要配置声明顺序的
 *    调用方请自行按配置重排，本模块不猜。
 */

/**
 * 组类型白名单（`core/proxy.go:51-60` isProxyGroupType + FlClash fork 的 smart 组）。
 *
 * **必须与 `ClashApiService.GROUP_TYPES` 保持一致**。2026-10-30 真机报障：这里漏了
 * 'Smart'，于是 `type: smart` 的「♻️ 自动选择」组被当成**普通节点**（isGroup=false）
 * 混进节点列表，与 App 置顶的合成入口同屏出现两条「自动选择」（上面一条无延迟值）。
 */
export const CORE_GROUP_TYPES: string[] = [
  'Selector',
  'URLTest',
  'Fallback',
  'Relay',
  'LoadBalance',
  'Smart'
];

/** 内置全局组名（reserved provider 组；hidden 判定用） */
export const CORE_GLOBAL_GROUP: string = 'GLOBAL';

/** 延迟排序类型（对应 Dart ProxiesSortType 的 none / delay / name） */
export const CORE_SORT_NONE: string = 'none';
export const CORE_SORT_DELAY: string = 'delay';
export const CORE_SORT_NAME: string = 'name';

/**
 * 内核代理表里的单条记录（`/proxies` 的 value）。
 * 只声明真实存在的键；`history` 里是 {time, delay}，这里只需要 delay。
 */
export interface CoreProxyEntry {
  name?: string;
  type?: string;
  now?: string;
  all?: string[];
  /** 上游 mihomo 的测速地址键 */
  url?: string;
  /** 本仓库内核（Clash.Meta fork）的测速地址键 */
  testUrl?: string;
  hidden?: boolean;
  history?: CoreDelayHistoryEntry[];
}

export interface CoreDelayHistoryEntry {
  time?: string;
  delay?: number;
}

/**
 * 目录里的一个节点（也可能是组：`isGroup == true`）。
 * 组专属字段（now / all / url）在非组节点上为空，调用方靠 isGroup 区分。
 */
export class CoreNode {
  /** 内核里的唯一名（= /proxies 的 map 键；PUT body 的 name 必须与之逐字一致） */
  name: string = '';
  /** AdapterType 字符串，如 Selector / Shadowsocks / Direct */
  type: string = '';
  /** 组当前选中的成员名；非组为空 */
  now: string = '';
  /** 组成员名列表（声明顺序，含子组）；非组为空数组 */
  all: string[] = [];
  /** 内核 history 末条的延迟；-1 表示没有历史（无有效测速记录） */
  lastDelay: number = -1;
  /** 组测速地址；非组或未配置为空 */
  url: string = '';
  /** 是否在 rule 模式下隐藏（当前只有内置 GLOBAL） */
  hidden: boolean = false;
  /** 是否组（CORE_GROUP_TYPES 成员） */
  isGroup: boolean = false;

  constructor(name: string = '', type: string = '') {
    this.name = name;
    this.type = type;
  }
}

/** 一个组：成员已解析成 CoreNode 引用（顺序与内核 all 一致） */
export class CoreGroup {
  name: string = '';
  type: string = '';
  /** 组当前选中的成员名（内核 now；可能是子组名，也可能是空） */
  now: string = '';
  /** 成员节点（子组也是 CoreNode，其 isGroup 为 true） */
  all: CoreNode[] = [];
  /** 组测速地址（组未配置时为空，调用方回落全局 testUrl） */
  url: string = '';
  /** rule 模式下是否隐藏 */
  hidden: boolean = false;

  constructor(name: string = '', type: string = '') {
    this.name = name;
    this.type = type;
  }

  /** 浅拷贝并替换成员列表（不改动入参，hideTimeout 用） */
  static withNodes(group: CoreGroup, all: CoreNode[]): CoreGroup {
    const copy = new CoreGroup(group.name, group.type);
    copy.now = group.now;
    copy.url = group.url;
    copy.hidden = group.hidden;
    copy.all = all;
    return copy;
  }
}

/** 解析结果：组视图 + 名字索引（索引里也含组，方便按名查类型 / now） */
export class CoreCatalogModel {
  groups: CoreGroup[] = [];
  byName: Record<string, CoreNode> = {};

  findNode(name: string): CoreNode | null {
    const hit = this.byName[name];
    return hit === undefined ? null : hit;
  }

  findGroup(name: string): CoreGroup | null {
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].name === name) {
        return this.groups[i];
      }
    }
    return null;
  }

  /**
   * 按内核模式取「该显示的组」：direct → 空；global → 全部（含 hidden 的 GLOBAL）；
   * 其它（rule / 未知）→ 过滤 hidden。对齐 `currentGroupsState`。
   */
  groupsForMode(mode: string): CoreGroup[] {
    if (mode === 'direct') {
      return [];
    }
    if (mode === 'global') {
      return this.groups;
    }
    const shown: CoreGroup[] = [];
    for (let i = 0; i < this.groups.length; i++) {
      if (!this.groups[i].hidden) {
        shown.push(this.groups[i]);
      }
    }
    return shown;
  }
}

/** 选择节点用的最小请求描述（不含 baseUrl / 鉴权头，由调用方补） */
export class CoreSelectRequest {
  method: string = 'PUT';
  path: string = '';
  /** 空串表示无 body（DELETE） */
  body: string = '';

  constructor(method: string = 'PUT', path: string = '', body: string = '') {
    this.method = method;
    this.path = path;
    this.body = body;
  }
}

/** PUT /proxies/{group} 的 body 形状（显式声明，避免 ArkTS 无类型字面量） */
interface CoreSelectBody {
  name: string;
}

export class CoreSelection {
  /**
   * 在组里选中一个节点：PUT /proxies/{group}，body {"name":node}。
   * 内核 updateProxy：非 SelectAble（普通节点）→ 400 "Must be a Selector"；
   * name 不在组内 → 400 "Selector update error"。
   * FlClash 侧选完还会 resetConnections + closeConnections（见 actions/proxies.dart:177-221），
   * 那是调用方的后续动作，不在本类里。
   */
  static select(group: string, node: string): CoreSelectRequest {
    const body: CoreSelectBody = { name: node };
    return new CoreSelectRequest('PUT', `/proxies/${encodeURIComponent(group)}`, JSON.stringify(body));
  }

  /**
   * 取消组的固定选择：DELETE /proxies/{group}（内核 unfixedProxy → ForceSet("")）。
   * **只对 URLTest / Fallback / LoadBalance 等非 Selector 组有效**；Selector 会被
   * 内核直接 400 驳回（Selector 必须始终有选中项）。
   */
  static unselectAll(group: string): CoreSelectRequest {
    return new CoreSelectRequest('DELETE', `/proxies/${encodeURIComponent(group)}`, '');
  }
}

export class CoreCatalog {
  /** 是否组类型（精确匹配 AdapterType 字符串，大小写敏感） */
  static isGroupType(type: string): boolean {
    for (let i = 0; i < CORE_GROUP_TYPES.length; i++) {
      if (CORE_GROUP_TYPES[i] === type) {
        return true;
      }
    }
    return false;
  }

  /**
   * 解析 `GET /proxies` 的响应原文。
   * 返回 null 的三种情形（调用方必须当成「内核不可用 / 响应不可用」，
   * 不能当成「没有节点」）：JSON 解析失败、根对象不是 {proxies:{...}}、proxies 为空对象。
   */
  static parse(json: string): CoreCatalogModel | null {
    if (json.length === 0) {
      return null;
    }
    let root: Record<string, Object>;
    try {
      root = JSON.parse(json) as Record<string, Object>;
    } catch (e) {
      return null;
    }
    if (root === null || root === undefined) {
      return null;
    }
    const proxiesRaw = root['proxies'];
    if (proxiesRaw === undefined || proxiesRaw === null) {
      return null;
    }
    if (typeof proxiesRaw !== 'object' || Array.isArray(proxiesRaw)) {
      return null;
    }
    const table = proxiesRaw as Record<string, Object>;
    const keys = Object.keys(table);
    if (keys.length === 0) {
      return null;
    }

    const model = new CoreCatalogModel();
    const order: string[] = [];

    // 第一遍：建节点（不解析成员引用，成员可能比组先出现 / 后出现）
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      const rawEntry = table[key];
      if (rawEntry === undefined || rawEntry === null) {
        continue;
      }
      if (typeof rawEntry !== 'object' || Array.isArray(rawEntry)) {
        continue;
      }
      const entry = rawEntry as Record<string, Object>;
      const type = CoreCatalog.textOf(entry['type']);
      if (type.length === 0) {
        // 没有 type 的信息类条目（见 ClashApiService.testableProxyNames 的同款过滤）
        continue;
      }
      const node = new CoreNode(key, type);
      node.isGroup = CoreCatalog.isGroupType(type);
      node.now = CoreCatalog.textOf(entry['now']);
      node.all = CoreCatalog.namesOf(entry['all']);
      node.lastDelay = CoreCatalog.lastDelayOf(entry['history']);
      node.url = CoreCatalog.groupUrlOf(entry);
      node.hidden = node.isGroup ? CoreCatalog.hiddenOf(key, entry) : false;
      model.byName[key] = node;
      order.push(key);
    }

    if (order.length === 0) {
      return null;
    }

    // 第二遍：组视图（GLOBAL 提到最前，对齐 proxyGroupNames 的 append([]string{GLOBAL}, ...)）
    const groupNames: string[] = [];
    let hasGlobal = false;
    for (let i = 0; i < order.length; i++) {
      const node = model.byName[order[i]];
      if (!node.isGroup) {
        continue;
      }
      if (node.name === CORE_GLOBAL_GROUP) {
        hasGlobal = true;
        continue;
      }
      groupNames.push(node.name);
    }
    if (hasGlobal) {
      groupNames.unshift(CORE_GLOBAL_GROUP);
    }

    for (let i = 0; i < groupNames.length; i++) {
      const node = model.byName[groupNames[i]];
      const group = new CoreGroup(node.name, node.type);
      group.now = node.now;
      group.url = node.url;
      group.hidden = node.hidden;
      group.all = CoreCatalog.resolveMembers(node.all, model.byName);
      model.groups.push(group);
    }
    return model;
  }

  /**
   * 排序组成员。
   *
   * @param delays   延迟表（name → ms；-1 超时、-2 失败、其它负值也算失败）。缺键按 0（未测）处理。
   * @param sortType 'delay' | 'name' | 其它（'none'）→ 原顺序浅拷贝
   *
   * delay 排序键：priority（>0=0 / ==0=1 / ==-1=2 / 其它=3）→ delay 升序 →
   * 组优先 → name localeCompare。入参数组不被修改。
   */
  static sortedNodes(nodes: CoreNode[], delays: Record<string, number>, sortType: string): CoreNode[] {
    const out: CoreNode[] = nodes.slice();
    if (sortType === CORE_SORT_NAME) {
      out.sort((a: CoreNode, b: CoreNode): number => a.name.localeCompare(b.name));
      return out;
    }
    if (sortType !== CORE_SORT_DELAY) {
      return out;
    }
    out.sort((a: CoreNode, b: CoreNode): number => {
      const da = CoreCatalog.delayOf(a.name, delays);
      const db = CoreCatalog.delayOf(b.name, delays);
      const pa = CoreCatalog.delayPriority(da);
      const pb = CoreCatalog.delayPriority(db);
      if (pa !== pb) {
        return pa - pb;
      }
      if (da !== db) {
        return da - db;
      }
      if (a.isGroup !== b.isGroup) {
        return a.isGroup ? -1 : 1;
      }
      return a.name.localeCompare(b.name);
    });
    return out;
  }

  /** Dart DelayState.priority：>0 → 0，==0 → 1，==-1 → 2，其它 → 3 */
  static delayPriority(delay: number): number {
    if (delay > 0) {
      return 0;
    }
    if (delay === 0) {
      return 1;
    }
    if (delay === -1) {
      return 2;
    }
    return 3;
  }

  /** 取延迟；缺记录按 0（未测），对齐 `delayMap[...] ?? 0` */
  static delayOf(name: string, delays: Record<string, number>): number {
    const value = delays[name];
    if (value === undefined || value === null) {
      return 0;
    }
    if (!Number.isFinite(value)) {
      return 0;
    }
    return value;
  }

  /**
   * 隐藏超时节点（`computeHideTimeout` 的简化口径，入参不修改）：
   *  - hide=false → 原样返回（同一数组引用，省一次遍历）；
   *  - 剔除 delays[name] < 0 的成员（超时 / 失败）；
   *  - 若某组成员被剔光，**保留该组原成员**（否则组和它的测速入口一起消失）；
   *  - 组自身字段（now / url / hidden / type）原样保留，只换 all。
   */
  static hideTimeout(groups: CoreGroup[], delays: Record<string, number>, hide: boolean): CoreGroup[] {
    if (!hide) {
      return groups;
    }
    const out: CoreGroup[] = [];
    for (let i = 0; i < groups.length; i++) {
      const group = groups[i];
      const kept: CoreNode[] = [];
      for (let j = 0; j < group.all.length; j++) {
        const node = group.all[j];
        const delay = delays[node.name];
        if (delay !== undefined && delay !== null && delay < 0) {
          continue;
        }
        kept.push(node);
      }
      if (kept.length === 0 || kept.length === group.all.length) {
        out.push(group);
        continue;
      }
      out.push(CoreGroup.withNodes(group, kept));
    }
    return out;
  }

  /** 延迟配色（`lib/ui/color.dart:333-339`）：<0 → error；<600 → success；其余 → warning */
  static delayColor(delay: number): string {
    if (!Number.isFinite(delay)) {
      return '';
    }
    if (delay < 0) {
      return 'error';
    }
    if (delay < 600) {
      return 'success';
    }
    return 'warning';
  }

  /**
   * 仪表盘取色包装（`proxy_groups.dart:113-121` 的 `delayColor(delay > 0 ? delay : -1)`）：
   * 非正值一律按 -1 画 error，null → ''（不画）。想避免「绿色失败」就用这个。
   */
  static displayColor(delay: number | null): string {
    if (delay === null) {
      return '';
    }
    if (!Number.isFinite(delay)) {
      return '';
    }
    return CoreCatalog.delayColor(delay > 0 ? delay : -1);
  }

  /**
   * 延迟文案（`app_localizations.delayFailureText` + proxy_groups 分支）：
   * delay > 0 → "123 ms"；-1 → "超时"；0 与其它负值 → "失败"；null / 非有限数 → ""
   * （null 是「还没测」，不能显示成失败）。
   */
  static delayText(delay: number | null): string {
    if (delay === null) {
      return '';
    }
    if (!Number.isFinite(delay)) {
      return '';
    }
    if (delay > 0) {
      return `${Math.floor(delay)} ms`;
    }
    if (delay === -1) {
      return '超时';
    }
    return '失败';
  }

  // ---- 以下为解析辅助，均为静态私有语义（ArkTS 无 private 静态约束，保持 public 以便复用/测试） ----

  /** 任意 JSON 标量 → 字符串（缺失 / null → ''） */
  static textOf(value: Object | undefined): string {
    if (value === undefined || value === null) {
      return '';
    }
    return String(value);
  }

  /** JSON 数组 → 字符串数组（非数组 / 空 → []；元素 null 跳过） */
  static namesOf(value: Object | undefined): string[] {
    const out: string[] = [];
    if (value === undefined || value === null || !Array.isArray(value)) {
      return out;
    }
    const list = value as Object[];
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      if (item === undefined || item === null) {
        continue;
      }
      out.push(String(item));
    }
    return out;
  }

  /** history 末条的 delay；缺失 / 空 / 非法 → -1（内核失败写 0，原值保留） */
  static lastDelayOf(value: Object | undefined): number {
    if (value === undefined || value === null || !Array.isArray(value)) {
      return -1;
    }
    const list = value as Object[];
    if (list.length === 0) {
      return -1;
    }
    const last = list[list.length - 1];
    if (last === undefined || last === null || typeof last !== 'object') {
      return -1;
    }
    const record = last as Record<string, Object>;
    const raw = record['delay'];
    if (raw === undefined || raw === null) {
      return -1;
    }
    const delay = Number(CoreCatalog.textOf(raw));
    if (!Number.isFinite(delay)) {
      return -1;
    }
    return Math.floor(delay);
  }

  /** 组测速地址：上游 `url` 优先，本仓库内核的 `testUrl` 兜底 */
  static groupUrlOf(entry: Record<string, Object>): string {
    const url = CoreCatalog.textOf(entry['url']);
    if (url.length > 0) {
      return url;
    }
    return CoreCatalog.textOf(entry['testUrl']);
  }

  /**
   * hidden = 响应里的 true OR 名字是 GLOBAL。
   *
   * 不能写成「字段优先」：TunBox 直连的原版 mihomo 里内置 GLOBAL 的 Selector
   * `Hidden()` 就是 false，字段存在但为 false 会把 GLOBAL 放进 rule 模式列表；
   * FlClash 的 `proxyView` 是另加 hidden:true 才没这个问题。名字判定与
   * `isBuiltInGlobal` 等价（reserved provider 组恒名 GLOBAL），所以取 OR。
   */
  static hiddenOf(name: string, entry: Record<string, Object>): boolean {
    if (name === CORE_GLOBAL_GROUP) {
      return true;
    }
    const flag = entry['hidden'];
    if (flag === undefined || flag === null) {
      return false;
    }
    return flag === true || String(flag) === 'true';
  }

  /** 组 all 里的名字 → 节点引用；内核表里找不到的用同名占位节点（type 空、isGroup false） */
  static resolveMembers(names: string[], byName: Record<string, CoreNode>): CoreNode[] {
    const out: CoreNode[] = [];
    for (let i = 0; i < names.length; i++) {
      const name = names[i];
      const hit = byName[name];
      if (hit !== undefined) {
        out.push(hit);
        continue;
      }
      out.push(new CoreNode(name, ''));
    }
    return out;
  }
}
