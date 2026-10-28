/**
 * VPN 恢复策略（纯函数，无 SDK 依赖，可离线自动验证）。
 *
 * 把 VpnExtensionAbility 的 MTU 选择、内核恢复退避、TUN 重建升级、Kill Switch
 * 泄漏阻断判定从进程里抽出来，供 Extension 运行时调用，也供
 * scripts/verify-vpn-architecture.mjs 做后台/锁屏/进程回收/网络切换/内核崩溃/
 * 弱网/长稳等场景的确定性仿真验证。语义必须与 Extension 内联实现保持一致。
 */

/** 网络类型常量（与 NetworkStateWatcher.NetTypes 数值语义一致，纯字符串）。 */
export class NetTypes {
  static readonly NONE: string = 'none';
  static readonly WIFI: string = 'wifi';
  static readonly CELLULAR: string = 'cellular';
  static readonly ETHERNET: string = 'ethernet';
  static readonly UNKNOWN: string = 'unknown';
}

/** Wi-Fi/以太网基线 MTU；蜂窝链路降 MTU 降低分片/PMTUD 黑洞风险。 */
export const BASE_MTU: number = 1400;
export const CELLULAR_MTU: number = 1360;
/** 内核热恢复最大次数，超过升级为一次 TUN 重建。 */
export const MAX_CORE_RECOVERY_ATTEMPTS: number = 3;
/** 单会话 TUN 重建上限（防重建风暴）。 */
export const MAX_TUNNEL_REBUILDS: number = 2;
/** 恢复退避基准与上限（ms）。 */
export const RECOVERY_BASE_DELAY_MS: number = 1000;
export const RECOVERY_MAX_DELAY_MS: number = 8000;
export const REBUILD_BASE_DELAY_MS: number = 1500;
export const REBUILD_MAX_DELAY_MS: number = 8000;

/** 按物理承载选择 MTU。蜂窝 → 1360，其余（含未知/以太网/无网）→ 1400 基线。 */
export function mtuForNetType(netType: string): number {
  return netType === NetTypes.CELLULAR ? CELLULAR_MTU : BASE_MTU;
}

/** 纯函数：第 attempt 次（从 0 起）内核恢复的退避延迟，指数增长并封顶。 */
export function coreRecoveryDelayMs(attempt: number): number {
  const a = attempt < 0 ? 0 : attempt;
  const raw = RECOVERY_BASE_DELAY_MS * Math.pow(2, a);
  return raw > RECOVERY_MAX_DELAY_MS ? RECOVERY_MAX_DELAY_MS : raw;
}

/** 纯函数：第 rebuild 次（从 0 起）TUN 重建的退避延迟，指数增长并封顶。 */
export function tunnelRebuildDelayMs(rebuild: number): number {
  const r = rebuild < 0 ? 0 : rebuild;
  const raw = REBUILD_BASE_DELAY_MS * Math.pow(2, r);
  return raw > REBUILD_MAX_DELAY_MS ? REBUILD_MAX_DELAY_MS : raw;
}

/** 网络类型是否为可承载恢复尝试的物理网络。 */
export function isRecoverableNetwork(netType: string): boolean {
  return netType === NetTypes.WIFI || netType === NetTypes.CELLULAR
    || netType === NetTypes.ETHERNET;
}

/**
 * Kill Switch / 断线防泄漏核心判定：返回本世代是否应「保持 TUN + 阻断泄漏」。
 *
 * 语义：只要不是用户主动断开（stopped），隧道默认路由与 IPv4-only 就必须保留 ——
 * 内核不可用时流量落入 TUN 而无出口 = 天然阻断，绝不回退物理网络造成泄漏。
 * 断网（NONE）时不进入恢复（无法拨出），但保持阻断。返回 'leak-blocked' 表示
 * 阻断中且不再消耗恢复预算；'recover' 表示应尝试恢复；'down' 表示可拆除。
 */
export function leakSwitchDecision(userStopped: boolean, netType: string, coreAlive: boolean): string {
  if (userStopped) {
    return 'down';
  }
  if (!coreAlive && netType === NetTypes.NONE) {
    return 'leak-blocked';
  }
  if (!coreAlive && isRecoverableNetwork(netType)) {
    return 'recover';
  }
  return 'keep';
}

/** 恢复调度决策输入/输出（显式类型，满足 ArkTS 严格模式）。 */
export class RecoveryInput {
  userStopped: boolean = false;
  netType: string = NetTypes.UNKNOWN;
  coreAlive: boolean = true;
  connectionUp: boolean = true;
  rebuilding: boolean = false;
  recoveryAttempts: number = 0;
  tunnelRebuilds: number = 0;
}

/** 恢复动作取值集合（用常量而非字面量联合类型，规避 ArkTS 严格模式限制）。 */
export class RecoveryAction {
  static readonly NONE: string = 'none';
  static readonly CORE_RECOVERY: string = 'core-recovery';
  static readonly TUN_REBUILD: string = 'tun-rebuild';
  static readonly LEAK_BLOCKED: string = 'leak-blocked';
}

/**
 * 纯函数：给定恢复上下文，决定本 tick 应执行的动作。把 Extension 的
 * scheduleCoreRecovery / scheduleTunnelRebuild / leak-block 门控收敛成一处，
 * 便于自动化覆盖「内核崩溃→有限热恢复→升级一次 TUN 重建→再耗尽→泄漏阻断」。
 * 返回值为 RecoveryAction.* 之一。
 */
export function decideRecoveryAction(inp: RecoveryInput): string {
  if (inp.userStopped || inp.rebuilding) {
    return RecoveryAction.NONE;
  }
  const switchDecision = leakSwitchDecision(inp.userStopped, inp.netType, inp.coreAlive);
  if (!inp.connectionUp) {
    return RecoveryAction.NONE;
  }
  if (inp.netType === NetTypes.NONE) {
    return switchDecision === 'leak-blocked' ? RecoveryAction.LEAK_BLOCKED : RecoveryAction.NONE;
  }
  if (inp.coreAlive) {
    return RecoveryAction.NONE;
  }
  // 内核已死且网络可用：先做有限次内核热恢复（不重建 TUN），耗尽后升级一次 TUN 重建。
  if (inp.recoveryAttempts < MAX_CORE_RECOVERY_ATTEMPTS) {
    return RecoveryAction.CORE_RECOVERY;
  }
  if (inp.tunnelRebuilds < MAX_TUNNEL_REBUILDS) {
    return RecoveryAction.TUN_REBUILD;
  }
  return RecoveryAction.LEAK_BLOCKED;
}

/**
 * 纯函数：长时间运行/弱网下是否应重置恢复计数。
 * 当内核重新存活（恢复成功）且网络可用时归零，避免跨事件累计导致过早放弃。
 */
export function shouldResetRecovery(coreAlive: boolean, netType: string): boolean {
  return coreAlive && isRecoverableNetwork(netType);
}

/**
 * 纯函数：VpnConnection.create() 失败码 → 用户可行动文案（@ohos.net.vpnExtension.d.ts 码表）。
 * 关键产品事实（真机证实 2026-09-18）：系统同一时刻只允许一个 VPN 会话，且
 * stopVpnExtensionAbility 只能停本应用 —— 第三方应用**无权限**挤掉其他 App 的 VPN，
 * 唯一正确行为是把 2203002 翻译成人话引导用户先断开对方。
 */
export function friendlyVpnStartError(code: number, rawMessage: string): string {
  if (code === 2203002) {
    return '无法建立 VPN：系统上已有另一个 VPN 连接在用。请先在对方应用（或 设置→网络→VPN）'
      + '中断开那个 VPN，再连接 TunBox。系统不允许第三方应用直接断开其他应用的 VPN。';
  }
  if (code === 2203001) {
    return '无法建立 VPN：系统拒绝了创建请求（需在弹框中允许 VPN 授权，或账号类型受限）。';
  }
  if (code === 2200002) {
    return '无法建立 VPN：与系统网络服务连接失败，请稍后重试。';
  }
  if (code === 2200001) {
    return '无法建立 VPN：隧道参数被系统拒绝（配置不完整或字段非法）。';
  }
  if (code === 2200003) {
    return '无法建立 VPN：系统服务内部错误。请清理内存后重试，或重启设备；'
      + '若持续出现请到「日志」页收集信息后反馈。';
  }
  if (code === 2203004) {
    return '无法建立 VPN：系统报告无效文件描述符（socket 链路建立失败）。'
      + '请稍后重试；若持续出现请重启设备。';
  }
  if (code === 19900001) {
    return '无法建立 VPN：系统拒绝了隧道参数（参数类型或数量错误）。'
      + '请到「日志」页查看详情并反馈。';
  }
  if (code === 19900002) {
    return '无法建立 VPN：VPN 系统内部错误。请重试或重启设备；'
      + '若持续出现请通过官方在线提单渠道反馈。';
  }
  // 内核配置解析失败(带 code=-1 走这里)：给出可行动的指引，而不是原始 Go 报错。
  if (rawMessage.indexOf('has unset fields') >= 0) {
    return '内核拒绝了订阅中的节点配置（存在缺少 password/uuid 等必填凭据的节点，'
      + '5.5.5 起此类节点会在生成配置前被隔离并计数）。请到主页「订阅」里刷新；'
      + '若仍失败，请删除日志中提示的节点。原始错误: ' + rawMessage;
  }
  if (rawMessage.indexOf('control characters are not allowed') >= 0) {
    return '内核拒绝了配置文件（文本含非法控制字符）。5.5.5 已修复蜂窝网络下扩展进程'
      + '改写 MTU 时损坏配置文件的根因；如仍出现，请到主页「订阅」里刷新后重连。原始错误: '
      + rawMessage;
  }
  if (rawMessage.indexOf('应用分流参数缺失或冲突') >= 0) {
    return '系统在拉起 VPN 扩展时丢失了本次连接的路由参数（新装首连的授权弹窗链路偶发；'
      + '5.5.6 起扩展会自动回退读取参数快照并重试一次）。请再点一次连接；若仍出现，'
      + '重启应用后再连。原始错误: ' + rawMessage;
  }
  // 零节点硬门禁（5.6.0）：连接漏斗在 nodes 为空时直接拒绝，根本没拉起扩展。
  // 这条必须排在"内核启动超时"之前判定 —— 否则会被上面的联网下载分支吃掉，
  // 又把用户引到"等 10 秒再点一次"（订阅是空的，重试必然同样失败）。
  if (rawMessage.indexOf('没有可用节点') >= 0) {
    return '还没有可用节点，本次没有启动 VPN。请到主页「订阅」里确认订阅已添加，'
      + '点击「刷新」并等节点列表出现后，再回首页点连接。原始错误: ' + rawMessage;
  }
  // 内核启动期联网下载阻塞（rule-provider / MMDB 本地文件缺失）：5.5.7 起生成配置时
  // 会先检查本地文件并在缺失时降级，同时后台补齐，正常不再触发本分支。
  if (rawMessage.indexOf('内核启动超时') >= 0 || rawMessage.indexOf('测速内核启动超时') >= 0) {
    return '内核启动卡在联网下载（配置引用的规则集/数据库文件缺失时，内核会在启动阶段'
      + '同步拉取，导致长时间无响应）。5.5.7 起已改为缺失即降级、后台补齐，'
      + '请等 10 秒后再点一次连接，即可正常启动并在下次连接启用完整规则。原始错误: '
      + rawMessage;
  }
  const detail: string = (rawMessage.length > 0 && rawMessage !== '[object Object]')
    ? rawMessage : '无详细信息（请到「日志」页查看完整堆栈）';
  return `VPN 扩展启动异常: ${detail}`;
}
