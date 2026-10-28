import { ConnState, connStateName } from './ConnState';

/**
 * 显式状态迁移表（2026-10-27，对齐 `docs/VPN_STATE_MACHINE.md`）。
 *
 * ## 为什么必须是表
 * 旧实现里 `this.state = X` 散落各处，谁都能从任何状态跳到任何状态。
 * 真机事故：用户点「停止」后，一个迟到的网络回调把状态又推回 CONNECTING，
 * 用户看到已经关掉的 VPN 自己"转圈"，再次点击时被 `busy` 门禁挡住。
 * 有了表之后，非法迁移会被拒绝并记录，恢复逻辑再也不能悄悄复活连接。
 *
 * ## 约定
 * - 表只描述**合法**迁移；同状态写入在 `setState` 里已提前返回，不在表内；
 * - `ERROR` 是失败终态，只能由显式重试/恢复离开；
 * - 用户主动断开后，任何异步回调都不得进入 CONNECTING/ RECONNECTING / RECOVERING
 *   （由 `blockedByUserDisconnect` 统一判定，而不是各回调自己记得检查）。
 */
export class StateTransition {
  from: ConnState;
  to: ConnState;
  note: string;

  constructor(from: ConnState, to: ConnState, note: string) {
    this.from = from;
    this.to = to;
    this.note = note;
  }
}

const T = (from: ConnState, to: ConnState, note: string): StateTransition =>
  new StateTransition(from, to, note);

export class ConnectionStateMachine {
  /** 合法迁移全集。新增迁移必须同时加进验证脚本的期望表。 */
  static readonly TRANSITIONS: StateTransition[] = [
    // ── 从「未连接」出发 ────────────────────────────────────────────────
    T(ConnState.DISCONNECTED, ConnState.CONNECTING, '用户/恢复发起连接'),
    T(ConnState.DISCONNECTED, ConnState.RECOVERING, '启动时发现残留会话，进入恢复'),
    T(ConnState.DISCONNECTED, ConnState.ERROR, '显式失败终态'),

    // ── 连接中 ──────────────────────────────────────────────────────────
    T(ConnState.CONNECTING, ConnState.CONNECTED, '内核回读确认出口'),
    T(ConnState.CONNECTING, ConnState.DISCONNECTED, '连接失败回滚 / 用户取消'),
    T(ConnState.CONNECTING, ConnState.DISCONNECTING, '连接中用户停止'),
    T(ConnState.CONNECTING, ConnState.RECOVERING, '连接失败转入自愈'),
    T(ConnState.CONNECTING, ConnState.ERROR, '连接失败且不再自动修复'),

    // ── 已连接 ──────────────────────────────────────────────────────────
    T(ConnState.CONNECTED, ConnState.CONNECTING, '用户切换节点触发完整重连'),
    T(ConnState.CONNECTED, ConnState.RECONNECTING, '网络变化/内核异常触发重连'),
    T(ConnState.CONNECTED, ConnState.DISCONNECTING, '用户主动停止'),
    T(ConnState.CONNECTED, ConnState.DISCONNECTED, '内核已退出/会话丢失'),
    T(ConnState.CONNECTED, ConnState.RECOVERING, '连接中自愈'),
    T(ConnState.CONNECTED, ConnState.ERROR, '已连接但出口不可用'),

    // ── 重连中 ──────────────────────────────────────────────────────────
    T(ConnState.RECONNECTING, ConnState.CONNECTING, '重连真正开始'),
    T(ConnState.RECONNECTING, ConnState.CONNECTED, '重连直接成功'),
    T(ConnState.RECONNECTING, ConnState.DISCONNECTING, '重连中用户停止'),
    T(ConnState.RECONNECTING, ConnState.DISCONNECTED, '重连放弃'),
    T(ConnState.RECONNECTING, ConnState.ERROR, '重连达最大次数'),
    T(ConnState.RECONNECTING, ConnState.RECOVERING, '重连失败转入自愈'),

    // ── 断开中 ──────────────────────────────────────────────────────────
    T(ConnState.DISCONNECTING, ConnState.DISCONNECTED, '资源回收完成'),
    T(ConnState.DISCONNECTING, ConnState.CONNECTING, '用户快速再次连接（显式覆盖）'),
    T(ConnState.DISCONNECTING, ConnState.ERROR, '断开时资源回收失败'),
    // 已是断开态时再次调用停止：允许落到 DISCONNECTING 做幂等回收。
    T(ConnState.DISCONNECTED, ConnState.DISCONNECTING, '幂等停止'),
    T(ConnState.ERROR, ConnState.DISCONNECTING, '从失败态执行停止'),

    // ── 恢复中 ──────────────────────────────────────────────────────────
    T(ConnState.RECOVERING, ConnState.CONNECTING, '恢复转入重新连接'),
    T(ConnState.RECOVERING, ConnState.CONNECTED, '恢复完成'),
    T(ConnState.RECOVERING, ConnState.DISCONNECTED, '恢复放弃/无会话可恢复'),
    T(ConnState.RECOVERING, ConnState.DISCONNECTING, '恢复中用户停止'),
    T(ConnState.RECOVERING, ConnState.ERROR, '恢复失败'),

    // ── 失败终态 ────────────────────────────────────────────────────────
    T(ConnState.ERROR, ConnState.CONNECTING, '用户显式重试'),
    T(ConnState.ERROR, ConnState.RECOVERING, '用户触发修复'),
    T(ConnState.ERROR, ConnState.DISCONNECTED, '用户清除错误')
  ];

  /** 合法迁移判定（同状态视为无变化，返回 true 以便调用方统一处理）。 */
  static canTransition(from: ConnState, to: ConnState): boolean {
    if (from === to) { return true; }
    for (const t of ConnectionStateMachine.TRANSITIONS) {
      if (t.from === from && t.to === to) { return true; }
    }
    return false;
  }

  /**
   * 用户主动断开后的「复活屏障」。
   *
   * 只拦**向连接推进**的迁移：DISCONNECTED / ERROR 仍然允许写入（回收流程要落终态），
   * 否则断开本身会被自己的屏障卡住。
   */
  static blockedByUserDisconnect(userDisconnected: boolean, next: ConnState): boolean {
    if (!userDisconnected) { return false; }
    return next === ConnState.CONNECTING || next === ConnState.RECONNECTING
      || next === ConnState.RECOVERING || next === ConnState.CONNECTED;
  }

  /** 非法迁移的可读说明；合法时返回 null。 */
  static explain(from: ConnState, to: ConnState): string | null {
    if (ConnectionStateMachine.canTransition(from, to)) { return null; }
    return `非法状态迁移 ${connStateName(from)} → ${connStateName(to)}`;
  }

  /** 该状态是否允许「用户停止」介入。 */
  static interruptible(state: ConnState): boolean {
    return state === ConnState.CONNECTING || state === ConnState.CONNECTED
      || state === ConnState.RECONNECTING || state === ConnState.RECOVERING;
  }
}
