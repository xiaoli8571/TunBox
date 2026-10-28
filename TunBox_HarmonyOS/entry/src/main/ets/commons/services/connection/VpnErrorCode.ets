/**
 * 统一错误码（2026-10-27 P1）。
 *
 * ## 为什么要枚举
 * 旧实现靠中文字符串匹配判断错误类型（`lastError.indexOf('配置校验未通过') >= 0`），
 * 文案一改逻辑就静默失效。现在所有失败路径先落到枚举码，中文只在最外层
 * （UI/通知）映射一次；日志、统计、重试决策都只认枚举。
 *
 * ## 约定
 * - 新增码必须同步加进 `scripts/verify-error-model.mjs` 的期望表；
 * - 码本身是稳定标识，文案可随时调整；
 * - 不改动既有中文文案的**含义**，只把判断依据从字符串换成码。
 */
export enum VpnErrorCode {
  /** 没有任何可用节点/订阅为空。 */
  NO_USABLE_NODE = 'no-usable-node',
  /** DNS（DoH）引导失败，且没有可用的持久化 pin。 */
  DNS_BOOTSTRAP_FAILED = 'dns-bootstrap-failed',
  /** 生成的配置未通过校验 / 合并失败。 */
  PROFILE_INVALID = 'profile-invalid',
  /** 写配置文件失败（磁盘/权限）。 */
  PROFILE_WRITE_FAILED = 'profile-write-failed',
  /** 内核（VPN 扩展）启动失败或超时。 */
  CORE_START_FAILED = 'core-start-failed',
  /** 控制器端口未在预算内就绪。 */
  CONTROLLER_TIMEOUT = 'controller-timeout',
  /** 钉选请求失败（组不存在/节点不存在/400）。 */
  NODE_SELECTION_FAILED = 'node-selection-failed',
  /** 钉选 PUT 成功但内核 `now` 未收敛到目标。 */
  NODE_SELECTION_NOT_CONVERGED = 'node-selection-not-converged',
  /** 当前无物理网络。 */
  NETWORK_UNAVAILABLE = 'network-unavailable',
  /** 用户主动取消。 */
  USER_CANCELLED = 'user-cancelled',
  /** 未知/未分类。 */
  UNKNOWN = 'unknown'
}

/** 错误是否值得自动修复（自愈/故障切换会介入）。 */
export function isRepairableError(code: VpnErrorCode): boolean {
  switch (code) {
    case VpnErrorCode.CORE_START_FAILED:
    case VpnErrorCode.CONTROLLER_TIMEOUT:
    case VpnErrorCode.NODE_SELECTION_FAILED:
    case VpnErrorCode.NODE_SELECTION_NOT_CONVERGED:
    case VpnErrorCode.NETWORK_UNAVAILABLE:
      return true;
    case VpnErrorCode.NO_USABLE_NODE:
    case VpnErrorCode.DNS_BOOTSTRAP_FAILED:
    case VpnErrorCode.PROFILE_INVALID:
    case VpnErrorCode.PROFILE_WRITE_FAILED:
    case VpnErrorCode.USER_CANCELLED:
    case VpnErrorCode.UNKNOWN:
      return false;
    default:
      return false;
  }
}

/** 是否属于「用户主动」类（不得弹错误、不得自动重试）。 */
export function isUserInitiated(code: VpnErrorCode): boolean {
  return code === VpnErrorCode.USER_CANCELLED;
}

/**
 * 结构化错误：码 + 可选细节。
 *
 * 细节里**禁止**写订阅 token / 控制器 secret / 代理凭据；
 * 只允许节点名、组名、耗时、HTTP 状态这类可公开诊断信息。
 */
export class VpnError {
  code: VpnErrorCode = VpnErrorCode.UNKNOWN;
  /** 内部诊断细节（可公开；不要放凭据）。 */
  detail: string = '';
  /** 发生时间。 */
  at: number = 0;

  constructor(code: VpnErrorCode = VpnErrorCode.UNKNOWN, detail: string = '', at: number = 0) {
    this.code = code;
    this.detail = detail;
    this.at = at;
  }

  label(): string {
    return this.detail.length > 0 ? `${this.code}: ${this.detail}` : this.code;
  }
}
