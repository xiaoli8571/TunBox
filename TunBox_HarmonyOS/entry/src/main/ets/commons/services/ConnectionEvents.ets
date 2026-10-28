/**
 * 连接事件（2026-10-27：UI 去轮询的第一步）
 *
 * 页面层过去靠 `setInterval` 每 500~1000ms 拉一次 `orchestrator.state` / `traffic` /
 * 节点名，叠加起来是十几个独立定时器。这里把「状态变了」变成推送：
 *
 * ```
 * ConnectionOrchestrator.setState() ──► ConnectionEvents.emit ──► 页面回调
 * ```
 *
 * 约定：
 * - 事件**只**描述已经发生的事实（状态已变、流量已采到、出口已确认），不做推导；
 * - 监听器抛错会被隔离，不影响其他监听器，也不影响连接流程；
 * - 事件不带「上一次的值」：需要对比的订阅方自己保存快照。
 */
/**
 * 重连原因（2026-10-27 收敛：不再用 `reason + '-retry'` 这类字符串拼接）。
 *
 * 为什么必须枚举：日志/统计/埋点都要按原因聚合，字符串拼接会把
 * `network-changed` 和 `network-changed-retry` 变成两个"原因"，
 * 也会让「同一原因重试了几次」无法统计。
 */
export enum ReconnectReason {
  /** 网络恢复（从无网到有网） */
  NETWORK_RESTORED = 'network-restored',
  /** 网络切换（Wi-Fi ↔ 蜂窝等物理变化） */
  NETWORK_CHANGED = 'network-changed',
  /** 代理核被系统杀死 */
  CORE_KILLED_BY_SYSTEM = 'core-killed-by-system',
  /** 自检发现核不存活 */
  CORE_NOT_ALIVE = 'core-not-alive',
  /** 上一次重连失败后的重试（retry 次数单独记录，不并入原因） */
  RETRY = 'retry',
  /** 用户主动触发（快捷开关/卡片） */
  USER_REQUEST = 'user-request'
}

export enum ConnEventKind {
  /** 连接状态变化（state 字段有效） */
  STATE = 0,
  /** 流量采样（up/down speed+total 有效） */
  TRAFFIC = 1,
  /** 出口节点变化（groupName/nodeName 有效） */
  EXIT = 2
}

/** 事件载荷。全部字段有默认值，避免 ArkTS 无类型字面量限制。 */
export class ConnEvent {
  kind: ConnEventKind = ConnEventKind.STATE;
  /** ConnState 数值（STATE 事件有效） */
  state: number = 0;
  /** 会话开始时间（ms；STATE 事件有效，0 表示未开始） */
  startedAt: number = 0;
  /** 出口组名（EXIT 事件有效） */
  groupName: string = '';
  /** 出口节点名（EXIT 事件有效） */
  nodeName: string = '';
  /** 上行速率 B/s（TRAFFIC 事件有效） */
  upSpeed: number = 0;
  downSpeed: number = 0;
  upTotal: number = 0;
  downTotal: number = 0;

  constructor(kind: ConnEventKind = ConnEventKind.STATE) {
    this.kind = kind;
  }

  static state(next: number, startedAt: number): ConnEvent {
    const e = new ConnEvent(ConnEventKind.STATE);
    e.state = next;
    e.startedAt = startedAt;
    return e;
  }

  static exit(groupName: string, nodeName: string): ConnEvent {
    const e = new ConnEvent(ConnEventKind.EXIT);
    e.groupName = groupName;
    e.nodeName = nodeName;
    return e;
  }

  static traffic(upSpeed: number, downSpeed: number, upTotal: number, downTotal: number): ConnEvent {
    const e = new ConnEvent(ConnEventKind.TRAFFIC);
    e.upSpeed = upSpeed;
    e.downSpeed = downSpeed;
    e.upTotal = upTotal;
    e.downTotal = downTotal;
    return e;
  }
}

export type ConnListener = (e: ConnEvent) => void;

class Subscription {
  id: number = 0;
  listener: ConnListener;

  constructor(id: number, listener: ConnListener) {
    this.id = id;
    this.listener = listener;
  }
}

/**
 * 极简事件总线。刻意不引入泛型/Map 迭代/回调数组拷贝等易踩 ArkTS 限制的写法：
 * 订阅表是数组，派发时按索引遍历并容忍单个监听器抛错。
 */
export class ConnectionEvents {
  private static nextId: number = 1;
  private static subs: Subscription[] = [];

  static subscribe(listener: ConnListener): number {
    const id = ConnectionEvents.nextId++;
    ConnectionEvents.subs.push(new Subscription(id, listener));
    return id;
  }

  static unsubscribe(id: number): void {
    if (id <= 0) { return; }
    const kept: Subscription[] = [];
    for (const s of ConnectionEvents.subs) {
      if (s.id !== id) { kept.push(s); }
    }
    ConnectionEvents.subs = kept;
  }

  /** 派发；单个监听器异常被吞掉（记日志由调用方决定，避免递归打日志）。 */
  static emit(e: ConnEvent): void {
    // 快照：监听器在回调里退订不会打乱本次遍历
    const snapshot: Subscription[] = [];
    for (const s of ConnectionEvents.subs) { snapshot.push(s); }
    for (const s of snapshot) {
      try {
        s.listener(e);
      } catch (err) {
        // 静默：事件派发不得反向影响连接流程
      }
    }
  }

  /** 当前订阅数（自检/门禁用）。 */
  static count(): number {
    return ConnectionEvents.subs.length;
  }
}
