/**
 * VPN 连接状态（2026-10-27 从 `ConnectionOrchestrator` 抽出）。
 *
 * 抽出的原因：状态机模块要引用这个枚举，如果枚举留在编排器里就会形成
 * `orchestrator → stateMachine → orchestrator` 的循环依赖（ArkTS 下表现为
 * 枚举在模块初始化时是 undefined）。这里做成零依赖叶子模块，
 * 编排器再 `export { ConnState }` 保持既有页面 import 不变。
 */
export enum ConnState {
  /** 未连接（含首次启动、用户主动断开之后）。 */
  DISCONNECTED = 0,
  /** 正在建立连接（配配置 / 拉起扩展 / 等控制器 / 钉选收敛）。 */
  CONNECTING = 1,
  /** 已连接，且出口已由内核回读确认。 */
  CONNECTED = 2,
  /** 正在断开（用户主动停止或会话回收）。 */
  DISCONNECTING = 3,
  /** 自愈/恢复流程中（修复内核、重建隧道）。 */
  RECOVERING = 4,
  /** 已连接但正在按策略重连（网络切换 / 内核被杀）。 */
  RECONNECTING = 5,
  /** 失败终态：需要用户动作或等待下一次显式重试。 */
  ERROR = 6
}

/** 人类可读名（日志/诊断用；UI 文案在外层映射）。 */
export function connStateName(state: ConnState): string {
  switch (state) {
    case ConnState.DISCONNECTED: return 'DISCONNECTED';
    case ConnState.CONNECTING: return 'CONNECTING';
    case ConnState.CONNECTED: return 'CONNECTED';
    case ConnState.DISCONNECTING: return 'DISCONNECTING';
    case ConnState.RECOVERING: return 'RECOVERING';
    case ConnState.RECONNECTING: return 'RECONNECTING';
    case ConnState.ERROR: return 'ERROR';
    default: return `UNKNOWN(${state})`;
  }
}

/** 是否处于「正在向连接推进」的过渡态（UI 显示转圈/禁止重复点击）。 */
export function isBusyState(state: ConnState): boolean {
  return state === ConnState.CONNECTING || state === ConnState.RECONNECTING
    || state === ConnState.RECOVERING || state === ConnState.DISCONNECTING;
}
