/**
 * 节点列表排序持久化 与 协议类型展示
 *
 * 背景（排序丢失根因）:
 *   NodeSelectionPage 的排序开关是 @State sortByLatency，仅存在于页面实例内存中；
 *   退出页面 → 实例销毁；重新进入 bootstrap() 重建实例时该字段回到 false，
 *   rebuildRows() 因此跳过排序，列表回落到订阅原始顺序。
 *   同时 LatencyController 的延迟表也只是进程内 Map，应用重启即清空。
 *
 * 方案:
 *   把「最近一次测速结果 + 排序模式」序列化进 AppSettings（随设置持久化），
 *   页面初始化时反序列化恢复顺序；重新测速则整体覆盖旧快照。
 *
 * 模式:
 *   default 订阅默认顺序 / auto 按最近测速结果 / manual 用户手动固定顺序
 */
import { ProxyNode, ProxyNodeType } from '../models/ProxyNode';
import { LatencyPolicy } from './LatencyState';

/** 排序模式常量 */
export class NodeSortModes {
  /** 订阅原始顺序 */
  static readonly DEFAULT: string = 'default';
  /** 按最近一次测速结果自动排序 */
  static readonly AUTO: string = 'auto';
  /** 用户手动固定顺序（顺序在 snapshot.order 中显式记录） */
  static readonly MANUAL: string = 'manual';

  /** 归一化任意输入为合法模式，未知值回退 default */
  static normalize(mode: string | undefined): string {
    if (mode === NodeSortModes.AUTO || mode === NodeSortModes.MANUAL) {
      return mode;
    }
    return NodeSortModes.DEFAULT;
  }
}

/** 单个节点的最近测速记录 */
export class NodeLatencyRecord {
  /** 节点名（Clash 侧唯一键，与 LatencyController 一致） */
  name: string = '';
  /** 延迟毫秒；null=未测/不支持离线测试，-1=失败 */
  latency: number = 0;
  /** 连续失败次数（近期成功率派生依据） */
  failCount: number = 0;
  /** 最近一次是否成功 */
  lastOk: boolean = false;
  /**
   * 失败分类（LatencyFailKind.*；空串 = 无失败/未分类）。
   * 分类必须随快照一起持久化：否则「测速内核不可用」造成的一整批超时在重启后
   * 与真实节点失败无法区分，也没法据此决定是否参与排序。
   */
  failKind: string = '';

  /**
   * 是否为「非节点判定」结果：核心未就绪 / 仅端口可达（直连降级）。
   * 这类结果只说明测速通道或端口层面的事，不能当作节点的测速结论参与排序。
   */
  static isNonVerdict(failKind: string): boolean {
    // 语义：这些 failKind 都不是「节点层面的测速结论」——
    //  - core_not_ready     测速通道/凭证坏了
    //  - port_reachable_only 只证明端口可达（直连降级）
    //  - untested            整批硬截止，本次没测出来
    //  - unsupported         协议无法离线探测
    //  - queue_timeout       **根本没拨号**（C7 闸门排队超时），与节点通不通无关
    // 它们必须沿用上一次有效结论，绝不能把「整批未测」写成「全失败」。
    //
    // queue_timeout（C7 起）：排队超时 = 这一轮因为应用侧在途名额耗尽而**没有发起请求**，
    // 对节点健康度零信息量。若当成节点结论落盘 → 节点沉底、排序被「我们自己的排队」污染，
    // 与 core_not_ready 的处理同源，故归入非判定。
    //
    // ⚠ 判定表收敛到 **LatencyPolicy.isNonVerdictKind**（唯一真源）：
    // 冷启动恢复（LatencyController.restore）与快照合并（buildAuto）必须用同一张表，
    // 否则「写快照时算非判定、恢复时算判定」→ 通道故障又被渲染成红「超时」
    // （2026-10-20 真机反馈「刚打开软件还没测速就显示超时」）。
    // 注：**空分类（''）不在表内** —— 写快照时它是「一次没有分类的真实失败」（节点结论），
    // 必须写进去；只有恢复路径把它当非结论（旧版自动切换记账的残留，见 restore）。
    return LatencyPolicy.isNonVerdictKind(failKind);
  }

  /** 近期成功率: 从未测过为 -1，否则按失败次数估算（0 失败=1.0） */
  recentSuccessRate(): number {
    if (this.latency === -2) {
      return -1;
    }
    if (!this.lastOk) {
      return 0;
    }
    return 1 / (1 + this.failCount);
  }
}

/** 测速快照（持久化 JSON 形状，显式类满足 arkts-no-untyped-obj-literals） */
export class NodeSortSnapshotJson {
  scope: string = "";
  /** 测速完成时间戳（毫秒） */
  testedAt: number = 0;
  /** 排序模式（通常为 auto） */
  mode: string = NodeSortModes.AUTO;
  /** 参与测速的节点记录 */
  records: NodeLatencyRecord[] = [];
  /** 显式排序（manual 模式用）；auto 模式下由 records 延迟派生 */
  order: string[] = [];
}

/** 排序快照 + 纯函数排序逻辑（可单测，不依赖 UI 与 Preferences） */
export class NodeSortSnapshot {
  scope: string = "";

  /** Unscoped old latency data cannot acquire provenance during an upgrade. */
  retainScope(scope: string): void {
    if (this.scope !== scope) { this.records = []; this.testedAt = 0; }
    this.scope = scope;
  }
  /** 测速完成时间戳（毫秒） */
  testedAt: number = 0;
  mode: string = NodeSortModes.DEFAULT;
  records: NodeLatencyRecord[] = [];
  /** 手动固定顺序（节点名列表）；空表示未固定 */
  order: string[] = [];

  /** 按节点名取记录（找不到返回 null） */
  recordFor(name: string): NodeLatencyRecord | null {
    for (const r of this.records) {
      if (r.name === name) {
        return r;
      }
    }
    return null;
  }

  /** 是否含有可用于排序的测速数据（无数据时应回退默认顺序） */
  hasLatencyData(): boolean {
    for (const r of this.records) {
      if (r.latency !== -2) {
        return true;
      }
    }
    return false;
  }

  /** 延迟缓存 TTL：5 分钟内直接复用测速结果 */
  isCacheFresh(now: number = Date.now()): boolean {
    return this.testedAt > 0 && (now - this.testedAt) < 5 * 60 * 1000;
  }

  /** 由延迟值 + 失败次数派生排序权重: 0=成功 1=未测/不支持 2=失败 */
  static latencyRank(rec: NodeLatencyRecord | null): number {
    if (rec === null || rec.latency === -2) {
      return 1;
    }
    if (rec.latency < 0) {
      return 2;
    }
    return 0;
  }

  /**
   * 计算节点名的目标顺序:
   *  - manual: 按 snapshot.order 显式顺序，未列出的保持原相对顺序沉底
   *  - auto:   成功(延迟升序) → 未测/不支持 → 失败，稳定排序
   *  - default 或无测速数据: 返回空数组，由调用方保持订阅原始顺序
   */
  orderedNames(names: string[]): string[] {
    if (this.mode === NodeSortModes.MANUAL && this.hasOrderData()) {
      const out: string[] = [];
      const remaining: string[] = [];
      for (const n of names) {
        if (this.order.includes(n)) {
          out.push(n);
        } else {
          remaining.push(n);
        }
      }
      out.sort((a: string, b: string): number => this.order.indexOf(a) - this.order.indexOf(b));
      return out.concat(remaining);
    }
    if (this.mode !== NodeSortModes.AUTO || !this.hasLatencyData()) {
      return [];
    }
    const sorted = names.slice();
    // 稳定排序: ArkTS 的 Array.sort 在权重/延迟相同时保持原索引顺序
    const indexOf = new Map<string, number>();
    for (let i = 0; i < names.length; i++) {
      indexOf.set(names[i], i);
    }
    sorted.sort((a: string, b: string): number => {
      const ra = this.recordFor(a);
      const rb = this.recordFor(b);
      const rankA = NodeSortSnapshot.latencyRank(ra);
      const rankB = NodeSortSnapshot.latencyRank(rb);
      if (rankA !== rankB) {
        return rankA - rankB;
      }
      if (rankA === 0 && ra !== null && rb !== null && ra.latency !== rb.latency) {
        return ra.latency - rb.latency;
      }
      return (indexOf.get(a) ?? 0) - (indexOf.get(b) ?? 0);
    });
    return sorted;
  }

  private hasOrderData(): boolean {
    return this.order.length > 0;
  }

  /** 序列化（供 AppSettings.nodeSortSnapshot 落盘） */
  toJson(): NodeSortSnapshotJson {
    const j = new NodeSortSnapshotJson();
    j.scope = this.scope;
    j.testedAt = this.testedAt;
    j.mode = NodeSortModes.normalize(this.mode);
    j.records = this.records;
    j.order = this.order;
    return j;
  }

  toJsonText(): string {
    return JSON.stringify(this.toJson());
  }

  /** 反序列化: 损坏 / 空串 → 返回 null（调用方回退默认顺序） */
  static fromJsonText(raw: string): NodeSortSnapshot | null {
    if (raw.length === 0) {
      return null;
    }
    let j: NodeSortSnapshotJson;
    try {
      j = JSON.parse(raw) as NodeSortSnapshotJson;
    } catch (e) {
      return null;
    }
    if (j === null || j === undefined) {
      return null;
    }
    const snap = new NodeSortSnapshot();
    snap.scope = typeof j.scope === 'string' ? j.scope : '';
    snap.testedAt = typeof j.testedAt === 'number' ? j.testedAt : 0;
    snap.mode = NodeSortModes.normalize(j.mode);
    const recs: NodeLatencyRecord[] = [];
    if (Array.isArray(j.records)) {
      for (const r of j.records) {
        if (r === null || r === undefined || typeof r.name !== 'string' || r.name.length === 0) {
          continue;
        }
        const rec = new NodeLatencyRecord();
        rec.name = r.name;
        // 缺字段/非法值 → **未测(-2)**，不是失败(-1)：没有数据不等于"测出来超时"。
        // （旧实现默认 -1，2026-10-20 修复：冷启动恢复时会被渲染成红「超时」。）
        rec.latency = typeof r.latency === 'number' && Number.isFinite(r.latency) ? r.latency : -2;
        rec.failCount = typeof r.failCount === 'number' && r.failCount >= 0 ? Math.floor(r.failCount) : 0;
        rec.lastOk = r.lastOk === true;
        rec.failKind = typeof r.failKind === 'string' && r.failKind.length <= 32 ? r.failKind : '';
        recs.push(rec);
      }
    }
    snap.records = recs;
    const order: string[] = [];
    if (Array.isArray(j.order)) {
      for (const n of j.order) {
        if (typeof n === 'string' && n.length > 0) {
          order.push(n);
        }
      }
    }
    snap.order = order;
    return snap;
  }

  /**
   * 从一批「节点名 → 延迟」结果构建 auto 快照（测速完成时调用）。
   * @param previous 上一次快照，用于累计连续失败次数与「非节点判定」结果的沿用
   * @param keepNames 全量节点名（可选）。测速队列可能只是当前筛选的子集，传入后
   *   本次未覆盖的节点会沿用上一次的结论，避免一次筛选测速把整份快照截断成子集。
   */
  static buildAuto(testedAt: number, results: NodeLatencyRecord[],
    previous: NodeSortSnapshot | null, keepNames: string[] | null = null): NodeSortSnapshot {
    const snap = new NodeSortSnapshot();
    snap.scope = previous === null ? '' : previous.scope;
    snap.testedAt = testedAt;
    snap.mode = NodeSortModes.AUTO;
    const merged: NodeLatencyRecord[] = [];
    const covered = new Set<string>();
    for (const r of results) {
      covered.add(r.name);
      const rec = new NodeLatencyRecord();
      rec.name = r.name;
      rec.failKind = r.failKind;
      if (NodeLatencyRecord.isNonVerdict(r.failKind)) {
        // 核心未就绪 / 仅端口可达都不是节点结论：沿用上一次的有效记录，
        // 绝不把这类结果当成一次测速结果写进快照影响排序。
        const carried = previous === null ? null : previous.recordFor(r.name);
        if (carried !== null) {
          rec.latency = carried.latency;
          rec.failCount = carried.failCount;
          rec.lastOk = carried.lastOk;
          rec.failKind = carried.failKind;
        } else {
          rec.latency = -2;
          rec.lastOk = false;
          rec.failCount = 0;
        }
        merged.push(rec);
        continue;
      }
      rec.latency = r.latency;
      rec.lastOk = r.latency >= 0;
      if (rec.lastOk) {
        rec.failCount = 0;
      } else {
        const prev = previous === null ? null : previous.recordFor(r.name);
        rec.failCount = (prev === null ? 0 : prev.failCount) + 1;
      }
      merged.push(rec);
    }
    // 只有调用方给出全量节点名时才做「沿用旧结论」的合并（保持向后兼容语义）
    if (previous !== null && keepNames !== null) {
      const keep = new Set<string>(keepNames);
      for (const prevRec of previous.records) {
        if (covered.has(prevRec.name) || !keep.has(prevRec.name)) {
          continue;
        }
        merged.push(prevRec);
      }
    }
    snap.records = merged;
    snap.order = [];
    return snap;
  }
}

/** 协议类型展示用常量 */
export class NodeProtocolInfo {
  /** 小写协议标识 */
  key: string = '';
  /** 展示标签（大写） */
  label: string = '';
  /** 是否 REALITY 传输 */
  reality: boolean = false;

  constructor(key: string, label: string, reality: boolean) {
    this.key = key;
    this.label = label;
    this.reality = reality;
  }

  /** 完整展示文本，如 "VLESS·REALITY" / "TROJAN" / "未知" */
  display(): string {
    return this.reality ? this.label + '·REALITY' : this.label;
  }
}

/**
 * 由 ProxyNode 的 proxyType / type 字段派生协议展示信息。
 * 优先级: proxyType（现代协议真实类型） > type 枚举（ssr/ss） > 未知。
 * REALITY 通过 realityPublicKey / realityShortId 存在与否判定（vless 场景）。
 */
export class NodeProtocolPolicy {
  /**
   * 需要**规范化**的协议（展示名与键不一致的，或有别名的）。
   * 键 → 规范键。
   */
  private static readonly ALIAS: Map<string, string> = new Map([
    ['hy2', 'hysteria2'],
    ['hysteria2', 'hysteria2'],
    ['shadow-tls', 'shadowtls'],
    ['ss2022', 'ss2022'],
  ]);

  /**
   * 提取协议键（小写）。
   *
   * ⚠ 2026-10-19 修正：原实现是**白名单**语义 —— 不在白名单里的 proxyType 一律
   * 返回 ''，UI 显示「未知」。白名单漏了 `ss` → ikuuu 订阅的 34 个 ss 节点
   * 全部显示「未知」（同订阅的 vmess 正常，因为 vmess 在白名单里）。
   * 机场的协议种类不可穷举（ss/hysteria/snell/mieru/ssh/ss2022/juicity…），
   * 白名单模式等于"每加一个协议就坏一批节点"。
   *
   * 现在改成：**白名单内的按别名规范化，白名单外的原样返回（小写）**。
   * 展示层再把未知协议大写显示（SS/HYSTERIA/SNELL…），既不误报「未知」，
   * 也不丢信息。
   */
  static protocolKey(proxyType: string, typeValue: string, realityPubKey: string): string {
    const p = proxyType.length > 0 ? proxyType.toLowerCase() : '';
    if (p.length > 0) {
      const alias = NodeProtocolPolicy.ALIAS.get(p);
      return alias !== undefined ? alias : p;
    }
    const t = typeValue.length > 0 ? typeValue.toLowerCase() : '';
    if (t.length > 0) {
      const alias = NodeProtocolPolicy.ALIAS.get(t);
      return alias !== undefined ? alias : t;
    }
    return '';
  }

  /** 是否为 REALITY 节点（有 reality 公钥/短 id 即视为 REALITY） */
  static isReality(proxyType: string, realityPubKey: string, realityShortId: string): boolean {
    const key = NodeProtocolPolicy.protocolKey(proxyType, '', realityPubKey);
    if (key !== 'vless') {
      return false;
    }
    return realityPubKey.length > 0 || realityShortId.length > 0;
  }

  /** 派生协议展示信息（含未知值兜底） */
  static resolve(proxyType: string, typeValue: string,
    realityPubKey: string, realityShortId: string): NodeProtocolInfo {
    const key = NodeProtocolPolicy.protocolKey(proxyType, typeValue, realityPubKey);
    const reality = NodeProtocolPolicy.isReality(proxyType, realityPubKey, realityShortId);
    switch (key) {
      case 'vless':
        return new NodeProtocolInfo('vless', 'VLESS', reality);
      case 'vmess':
        return new NodeProtocolInfo('vmess', 'VMESS', false);
      case 'trojan':
        return new NodeProtocolInfo('trojan', 'TROJAN', false);
      case 'hysteria2':
        return new NodeProtocolInfo('hysteria2', 'HYSTERIA2', false);
      case 'tuic':
        return new NodeProtocolInfo('tuic', 'TUIC', false);
      case 'anytls':
        return new NodeProtocolInfo('anytls', 'AnyTLS', false);
      case 'naive':
        return new NodeProtocolInfo('naive', 'Naive', false);
      case 'shadowtls':
      case 'shadow-tls':
        return new NodeProtocolInfo('shadowtls', 'ShadowTLS', false);
      case 'wireguard':
        return new NodeProtocolInfo('wireguard', 'WireGuard', false);
      case 'ss':
        return new NodeProtocolInfo('ss', 'SS', false);
      case 'ssr':
        return new NodeProtocolInfo('ssr', 'SSR', false);
      // 2026-10-19 补的常见协议展示名（原来会落进 default → 大写原名，
      // hysteria 会显示成 HYSTERIA 而 HYSTERIA2 才规范；ss2022 同理）。
      case 'hysteria':
        return new NodeProtocolInfo('hysteria', 'HYSTERIA', false);
      case 'ss2022':
        return new NodeProtocolInfo('ss2022', 'SS2022', false);
      case 'snell':
        return new NodeProtocolInfo('snell', 'SNELL', false);
      case 'http':
        return new NodeProtocolInfo('http', 'HTTP', false);
      case 'socks5':
        return new NodeProtocolInfo('socks5', 'SOCKS5', false);
      case 'mieru':
        return new NodeProtocolInfo('mieru', 'MIERU', false);
      case 'ssh':
        return new NodeProtocolInfo('ssh', 'SSH', false);
      case 'juicity':
        return new NodeProtocolInfo('juicity', 'Juicity', false);
      default:
        // 兜底：至少显示协议本身（大写），不显示「未知」——
        // 「未知」只留给**真的**没有协议信息（proxyType 与 type 都空）的情况。
        return new NodeProtocolInfo(key, key.length > 0 ? key.toUpperCase() : '未知', false);
    }
  }

  /** 直接由 ProxyNode 派生（避免页面里对枚举做 as string 强转） */
  static fromNode(node: ProxyNode): NodeProtocolInfo {
    const typeKey = node.type === ProxyNodeType.SSR ? 'ssr'
      : (node.type === ProxyNodeType.SS ? 'ss' : '');
    return NodeProtocolPolicy.resolve(node.proxyType, typeKey,
      node.realityPublicKey, node.realityShortId);
  }

  /** 直接由 ProxyNode 判定 REALITY */
  static isRealityNode(node: ProxyNode): boolean {
    return node.proxyType.toLowerCase() === 'vless'
      && (node.realityPublicKey.length > 0 || node.realityShortId.length > 0);
  }
}
