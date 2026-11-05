/**
 * 内核节点 → 展示模型桥（CoreNode → ProxyNode 影子）
 *
 * 为什么需要：FlClash 的节点清单只存在于内核（`/proxies`），App 不持有节点定义；
 * 本仓库的页面/卡片仍以 `ProxyNode` 为展示类型。这里把内核节点映射成一个**只读影子**：
 *  · `name` 与内核完全一致（选点/测速都靠这个名字）；
 *  · `proxyType` 用内核的 `type`（Vless / Trojan / Hysteria2 …）；
 *  · `server` / `port` / 凭据字段一律为空 —— 内核不提供，也不允许编造；
 *  · `id` 用 `core:<name>` 稳定生成（页面 ForEach 的 key）。
 *
 * 排序严格照 FlClash `DelayState.priority`（models/common.dart:957）：
 *   >0 → 0；==0 → 1；==-1 → 2；其它/无 → 3；同优先级按延迟升序；组优先于节点。
 */
import { ProxyNode, ProxyNodeType } from '../models/ProxyNode';
import { CoreNode } from './CoreCatalog';

const PREFIX = 'core:';

export class CoreNodeBridge {
  static toProxyNode(node: CoreNode, subscriptionId: string = ''): ProxyNode {
    const out = new ProxyNode();
    out.id = `${PREFIX}${node.name}`;
    out.name = node.name;
    out.originalName = node.name;
    out.subscriptionId = subscriptionId;
    out.proxyType = node.type.length > 0 ? node.type : 'unknown';
    out.type = ProxyNodeType.UNKNOWN;
    out.server = '';
    out.port = 0;
    return out;
  }

  static toProxyNodes(nodes: CoreNode[], subscriptionId: string = ''): ProxyNode[] {
    const out: ProxyNode[] = [];
    for (const node of nodes) {
      out.push(CoreNodeBridge.toProxyNode(node, subscriptionId));
    }
    return out;
  }

  /** 是否本桥生成的影子节点 */
  static isShadow(node: ProxyNode): boolean {
    return node.id.startsWith(PREFIX);
  }

  /** 展示用协议标签（内核 type → 大写可读名）。 */
  static protocolLabel(node: ProxyNode): string {
    const raw = node.proxyType;
    if (raw.length === 0) {
      return '未知';
    }
    return raw.toUpperCase();
  }

  /** FlClash `DelayState.priority` */
  static delayPriority(delay: number | null): number {
    if (delay === null) {
      return 3;
    }
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

  /**
   * 排序（FlClash compareTo）：priority → delay 升序。
   * `delayOf` 由调用方提供（页面从 LatencyStoreBridge 取实时值）。
   */
  static sortByDelay(nodes: ProxyNode[], delayOf: (name: string) => number | null): ProxyNode[] {
    const arr = nodes.slice();
    arr.sort((a: ProxyNode, b: ProxyNode): number => {
      const da = delayOf(a.name);
      const db = delayOf(b.name);
      const pa = CoreNodeBridge.delayPriority(da);
      const pb = CoreNodeBridge.delayPriority(db);
      if (pa !== pb) {
        return pa - pb;
      }
      const va = da === null ? 0 : da;
      const vb = db === null ? 0 : db;
      if (va !== vb) {
        return va - vb;
      }
      return a.name.localeCompare(b.name);
    });
    return arr;
  }
}
