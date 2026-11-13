/**
 * 隧道权威状态判定（纯函数，无副作用，可专项单测）。
 *
 * 背景（真机实证根因）：
 *  1) 桌面服务卡片点击 → QuickToggleAbility/EntryFormAbility 拉起 VPN 后进程很快退出，
 *     ConnectionOrchestrator 的 isCoreAliveByHeartbeat() 监控循环随进程一起消失，
 *     之后再无任何东西把"内核已死"同步回卡片 → 卡片长期停留在「已连接/断开」。
 *  2) 断开语义只看进程内 state + 心跳：新进程 state 恒为 DISCONNECTED，心跳一旦过期
 *     alive=false，toggle 就会走"连接"分支 → 点「断开」反而重连。
 *
 * 解决：把"是否已连接"收敛成单一权威判定 —— 持久化的**用户意图**
 * (desiredConnected) ∧ 内核真实存活证据(心跳新鲜 ∨ 隧道存活标记)。
 * 卡片 / 通知 / 页面一律走本模块，不再各自维护易漂移的进程内状态。
 */

/** 心跳新鲜窗口（ms）：Extension 存活租约（低频，10s 内核监控 + 事件刷新）15s 未更新即视为隧道死亡 */
export const HEARTBEAT_STALE_MS = 15000;

/** Extension 权威运行态的解析视图（跨进程 UI 只读，进程回收后仍能还原真实状态）。 */
export class ExtensionStatusView {
  /** running | recovering | leak-blocked | stopped | failed；'' = 无状态文件 */
  phase: string = '';
  mtu: number = 0;
  netType: string = '';
  coreAlive: boolean = false;
  recoveryAttempts: number = 0;
  rebuilds: number = 0;
  seq: number = 0;
  ts: number = 0;
  detail: string = '';
  /** 解析是否成功（false = 缺文件/损坏，调用方应回落心跳判定）。 */
  ok: boolean = false;
}

/**
 * 纯函数：解析 Extension 写入的 vpn_status.json。手写解析避免 JSON.parse 的 unknown，
 * 对缺字段/脏值全部安全回落（ok=false 表示不可信）。与 VpnRuntimeStatus.toJson 对应。
 */
export function parseExtensionStatus(text: string): ExtensionStatusView {
  const view = new ExtensionStatusView();
  const t = text.trim();
  if (t.length === 0 || !t.startsWith('{') || !t.endsWith('}')) {
    return view;
  }
  const strField = (key: string): string => {
    const k = `"${key}":"`;
    const i = t.indexOf(k);
    if (i < 0) {
      return '';
    }
    const start = i + k.length;
    const end = t.indexOf('"', start);
    return end < 0 ? '' : t.substring(start, end);
  };
  const numField = (key: string): number => {
    const k = `"${key}":`;
    const i = t.indexOf(k);
    if (i < 0) {
      return NaN;
    }
    const start = i + k.length;
    let end = start;
    while (end < t.length && (t.charAt(end) === '-' || (t.charAt(end) >= '0' && t.charAt(end) <= '9'))) {
      end++;
    }
    return end === start ? NaN : Number(t.substring(start, end));
  };
  const phase = strField('phase');
  if (phase.length === 0) {
    return view;
  }
  view.phase = phase;
  view.netType = strField('netType');
  view.detail = strField('detail');
  view.mtu = numField('mtu');
  view.recoveryAttempts = numField('recoveryAttempts');
  view.rebuilds = numField('rebuilds');
  view.seq = numField('seq');
  view.ts = numField('ts');
  view.coreAlive = t.indexOf('"coreAlive":true') >= 0;
  view.ok = true;
  return view;
}

/**
 * 纯函数：结合 Extension 权威相位与心跳新鲜度，给出 UI 应呈现的相位。
 * running 且租约新鲜 → connected；recovering/leak-blocked → blocked(不泄漏，正在自愈)；
 * 租约过期 → stale(进程可能已回收)。优先展示 Extension 主导相位，UI 进程被回收也不失真。
 */
export function deriveUiPhase(status: ExtensionStatusView, heartbeatFresh: boolean): string {
  if (!status.ok) {
    return heartbeatFresh ? 'connected' : 'stale';
  }
  if (status.phase === 'running') {
    return heartbeatFresh ? 'connected' : 'stale';
  }
  if (status.phase === 'recovering' || status.phase === 'leak-blocked') {
    return status.phase;
  }
  if (status.phase === 'stopped') {
    return 'disconnected';
  }
  return status.phase; // failed
}

/** 内核存活探针（可注入，便于专项验证各类崩溃/超时场景） */
export interface CoreLivenessProbe {
  /** 心跳文件距今毫秒；-1 表示无心跳/读取失败（内核从未启动或已退出） */
  heartbeatAgeMs(): number;
  /** 内核自报存活（可选；默认 false，扩展进程外的 coreBridge 实例不可信） */
  coreSelfAlive?(): boolean;
}

/** 权威快照：UI（卡片/通知/页面）唯一读取的状态来源 */
export class TunnelAuthorityState {
  /** 用户意图：期望处于连接态（持久化，跨进程/跨重启有效） */
  desiredConnected: boolean = false;
  /** 内核存活证据：心跳新鲜或存活标记存在 */
  coreAlive: boolean = false;
  /** 最终权威判定：已连接 */
  connected: boolean = false;
  /** 判定原因，便于日志与排障 */
  reason: string = '';
}

/**
 * 心跳是否新鲜。age < 0（无心跳文件）一律判死 —— 绝不能把"读不到"当作"活着"。
 */
export function isHeartbeatFresh(ageMs: number, staleMs: number = HEARTBEAT_STALE_MS): boolean {
  return ageMs >= 0 && ageMs < staleMs;
}

/**
 * 权威状态计算。任一输入变化都应重新调用并广播。
 *
 * @param desiredConnected 持久化的用户连接意图
 * @param heartbeatAgeMs 心跳文件年龄；-1 无心跳
 * @param tunnelMarkerExists 隧道存活标记文件是否存在（内核成功启动后写入）
 * @param staleMs 心跳过期阈值
 */
export function resolveAuthority(desiredConnected: boolean, heartbeatAgeMs: number,
  tunnelMarkerExists: boolean, staleMs: number = HEARTBEAT_STALE_MS): TunnelAuthorityState {
  const state = new TunnelAuthorityState();
  state.desiredConnected = desiredConnected;
  state.coreAlive = isHeartbeatFresh(heartbeatAgeMs, staleMs) || tunnelMarkerExists;
  state.connected = desiredConnected && state.coreAlive;
  if (!desiredConnected) {
    state.reason = 'user-disconnected';
  } else if (!state.coreAlive) {
    state.reason = heartbeatAgeMs < 0 ? 'core-exited' : 'heartbeat-timeout';
  } else {
    state.reason = 'core-alive';
  }
  return state;
}

/**
 * 断开是否应当真正执行：只要"用户意图已连接"或"内核仍有存活证据"，
 * 断开就必须执行真实停止。这样任意状态下点断开都绝不被反转成重连。
 */
export function shouldExecuteDisconnect(desiredConnected: boolean, heartbeatAgeMs: number,
  tunnelMarkerExists: boolean, staleMs: number = HEARTBEAT_STALE_MS): boolean {
  if (desiredConnected) {
    return true;
  }
  return isHeartbeatFresh(heartbeatAgeMs, staleMs) || tunnelMarkerExists;
}

/**
 * 连接请求去重：已在连接态且内核存活时，重复「连接」不再拉起新隧道。
 * （对应"重复点击去重"验收项）
 */
export function shouldSuppressConnect(desiredConnected: boolean, heartbeatAgeMs: number,
  tunnelMarkerExists: boolean, operationInFlight: boolean,
  staleMs: number = HEARTBEAT_STALE_MS): boolean {
  if (operationInFlight) {
    return true;
  }
  return resolveAuthority(desiredConnected, heartbeatAgeMs, tunnelMarkerExists, staleMs).connected;
}

/** 通过 probe 计算权威状态（读取真实文件/探针） */
export function resolveAuthorityWithProbe(desiredConnected: boolean,
  probe: CoreLivenessProbe, tunnelMarkerExists: boolean,
  staleMs: number = HEARTBEAT_STALE_MS): TunnelAuthorityState {
  return resolveAuthority(desiredConnected, probe.heartbeatAgeMs(), tunnelMarkerExists, staleMs);
}

/** 内核自报存活 + 心跳双通道（扩展进程内使用；默认探针不启用 self 判定） */
export function isCoreAlive(probe: CoreLivenessProbe, tunnelMarkerExists: boolean,
  staleMs: number = HEARTBEAT_STALE_MS): boolean {
  if (isHeartbeatFresh(probe.heartbeatAgeMs(), staleMs)) {
    return true;
  }
  if (tunnelMarkerExists) {
    return true;
  }
  if (probe.coreSelfAlive !== undefined) {
    try {
      return probe.coreSelfAlive();
    } catch (e) {
      return false;
    }
  }
  return false;
}
