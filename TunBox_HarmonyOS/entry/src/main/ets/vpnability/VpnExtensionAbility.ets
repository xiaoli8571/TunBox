/**
 * VPN 扩展能力：TUN 建立、fd 注入内核、长时任务
 * 移植自 upstream: android/.../TunBoxVpnService.kt
 *                VpnRouteInstaller.kt / VpnIpv6Config.kt / CoreLivenessMonitor.kt
 *
 * 真实 API（SDK @ohos.net.vpnExtension，API 11+ / 本机 SDK 26）：
 *   vpnExtension.createVpnConnection(context) → VpnConnection
 *   VpnConnection.create(VpnConfig) → Promise<number>（TUN fd）
 * 链路：UI 侧 ConnectionOrchestrator 写好配置文件并通过
 *   startVpnExtensionAbility(want.parameters.configPath) 拉起本能力 →
 *   本能力 onCreate 里 create() 拿到 fd → coreBridge.attachTun(fd) + startCore(configPath)。
 *
 * ⚠️ 生命周期回调名：VpnExtensionAbility 只有 onCreate(want) / onDestroy()，
 *    不存在 onStart/onStop（见 SDK @ohos.app.ability.VpnExtensionAbility.d.ts）。
 *    之前误用 onStart/onStop，系统回调命中基类空实现，TUN/内核从未启动，
 *    表现为 UI 侧 30s 超时报「9090 端口跨进程不可达」。
 *
 * IPv6 双栈（设置页开关，默认开）：TUN 的 v6 地址 / isIPv6Accepted 由**生成的那份 YAML**
 * 决定（readTunFlagsFromConfig 解析 `ipv6:`）。与内核同源，因此不会出现
 * 「TUN 装了 v6、内核 ipv6:false」的黑洞；want 丢失或进程重启后也不需要另存开关。
 *
 * DNS 接管（2026-10-21 起无开关）：生成器恒写 `dns.enable: true` + `tun.dns-hijack: any:53`，
 * 本层恒把 VpnConfig.dnsAddresses 指向 TUN sentinel（DNS_SERVERS）。设置页的
 * 「DNS 覆写」开关已删除 —— 只留一个恒真的事实，没有可漂移的第二决策点。
 *
 * ⚠ 2026-10-21 真机取证（改前缀后重测 /proc/net/ipv6_route）：
 *   · `VpnConfig.routes` 里的 v6 条目仍被平台静默丢弃（`::/0` 的三种写法、`fc00::/71`
 *     具体前缀，v4 默认路由正常）；
 *   · 但平台**会**按 LinkAddress 的前缀派生 on-link 路由：地址写 /126 时 vpn-tun 只有
 *     `fdfe:dcba:9876::/126`，地址写 /64 时立刻出现 `fdfe:dcba:9876::/64 ... vpn-tun`。
 *   ⇒ 本层把 TUN 的 v6 地址写成 /64（64 位前缀），生成器的 `fake-ip-range6` 用**同一个 /64**：
 *     内核给 AAAA 的假 v6 落在 on-link 网段内 ⇒ 进隧道 ⇒ 按域名交给代理拨号。
 *     v6 与 v4 一样走代理，设备侧不再有直连 v6 的路径（这正是旧 redir-host 方案的问题：
 *     真实 AAAA 只会把 v6 流量交给物理网卡）。
 *     池的 gateway = masked+1 = `fdfe:dcba:9876::1`，正是下面的 TUN_ADDRESS_V6。
 *     ipv6 关时生成器不写 range6 ⇒ 内核 AAAA 恒空，与只装 v4 的 TUN 一致。
 *
 * 隧道存续期间本进程是**网络与恢复的权威**：订阅网络切换、按承载动态调 MTU、
 * 内核崩溃后就地热恢复（必要时升级一次 TUN 重建）、以事件驱动写入 vpn_status.json
 * 供其他进程只读还原真实状态。
 *
 * 驻留边界（2026-09-18 真机修正）：本扩展进程**不**具备任何后台驻留资格 ——
 * 连续任务只支持 UIAbility 上下文（扩展内申请必然 401），宿主进程组失去凭证时
 * 系统会连带回收本进程（exit 0）。会话驻留由 QuickToggleAbility 的 dataTransfer
 * 守护承担；本文件只负责隧道数据面与其内部自愈。
 */
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import { UnifiedScheduler } from '../commons/services/UnifiedScheduler';
import { ReconnectReason } from '../commons/services/ConnectionEvents';
import { common } from '@kit.AbilityKit';
import { GeoDataInstaller } from '../commons/services/GeoDataInstaller';
import type Want from '@ohos.app.ability.Want';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';
import { coreBridge } from '../core/CoreBridge';
import { AppLogger } from '../commons/utils/AppLogger';
import { NetworkStateListener, NetworkStateWatcher, NetTypes } from '../commons/services/NetworkStateWatcher';
import {
  mtuForNetType, coreRecoveryDelayMs, tunnelRebuildDelayMs,
  MAX_CORE_RECOVERY_ATTEMPTS, MAX_TUNNEL_REBUILDS, friendlyVpnStartError
} from '../commons/services/VpnRecoveryPolicy';
import { BusinessError } from '@kit.BasicServicesKit';
import { AbilityConstant } from '@kit.AbilityKit';
import { AppRoutingModes, AppRoutingPolicy, AppRoutingRuntime } from '../commons/services/AppRoutingPolicy';
import { SettingsService } from '../commons/services/SettingsService';

const TAG = 'VpnExtensionAbility';
const VPN_MTU = 1400;
/** TUN 地址/前缀与 bridge/bridge.go 的 Inet4Address 严格一致（对齐 NekoBox 实测格式） */
const TUN_ADDRESS = '172.19.0.1';
const TUN_PREFIX = 30;
/** IPv6 入站地址：ULA + /64（64 位前缀）（同 FlClash 的 ULA 取值，但前缀放大到 /64）。
 *  必须是 ULA 而非全局地址：它是 TUN 的对端，不需要可路由。
 *  /64 是「v6 走代理」的前提：平台的 on-link 路由按此前缀派生（真机 /proc/net/ipv6_route
 *  取证），生成器的 fake-ip-range6 用同一个 /64，假 v6 才能落进隧道。 */
const TUN_ADDRESS_V6 = 'fdfe:dcba:9876::1';
/** 2026-10-21 真机取证：/126 → /64 后，/proc/net/ipv6_route 里出现
 *  dfe:dcba:9876::/64 ... vpn-tun（旧 /126 时只有 /126）⇒ 假 v6 池的 /64 有了 on-link 路由。
 *  这一条是「AAAA 走隧道、v6 走代理」的全部基础，不能改回 /126。 */
const TUN_PREFIX_V6 = 64;
const TUN_IFNAME = 'vpn-tun';
/**
 * DNS 指向 **TUN 内 sentinel**，对齐 FlClash 的 VpnService 构建方式：
 * `C:\Worker\flclash-src\android\service\src\main\java\com\follow\clash\service\VpnService.kt:298-301`
 *   IPV4_ADDRESS = 198.18.0.1/30 → addDnsServer(198.18.0.2)
 *   IPV6_ADDRESS = fdfe:dcba:9876::1/126 → addDnsServer(fdfe:dcba:9876::2)
 * 本仓 TUN 是 172.19.0.1/30（TUN_ADDRESS/TUN_PREFIX），同子网唯一对端即 172.19.0.2。
 *
 * 为什么不用旧值 223.5.5.5 / 119.29.29.29：
 *   1) 公共 DNS 能否被 `tun.dns-hijack: any:53` 劫持，取决于默认路由是否命中该地址；
 *      sentinel 落在 TUN 自身子网（平台会装 connected 路由），不依赖任何默认路由；
 *   2) 系统把「VPN 下发的 DNS 服务器」当作必须可达的配置项，指到 TUN 内地址最稳；
 *   3) 一旦劫持没生效，公共 DNS 就是明文直连 + 真实 QNAME 外泄 —— 正是旧注释担心的场景，
 *      而 sentinel 方案下这种失败模式根本不存在（发不出去 = 立刻失败，不会偷偷泄漏）。
 *
 * ⚠ 刻意**不加** v6 DNS（FlClash 在 ipv6 时 addDnsServer(DNS6)）：本平台不安装任何 v6
 * 路由（见 buildTunRoutes 的真机取证），把 DNS 指到 v6 sentinel 会让解析直接进黑洞。
 * AAAA 由内核解析器经 redir-host 返回真实地址，客户端拿到 v6 后走物理网卡直连。
 */
const DNS_SERVERS = ['172.19.0.2'];
/** 启动错误回传文件名（写入 configPath 同目录，UI 侧读取真实失败原因） */
const START_ERROR_FILE = 'vpn_start_error.txt';
/** 启动成功标记文件名（内核 API 就绪后写入，UI 侧轮询） */
const START_OK_FILE = 'vpn_start_ok.txt';
/** UI 每次拉起前重写的启动参数回退文件（want 被系统丢参时使用，见 readStartParamsFallback） */
const START_PARAMS_FILE = 'vpn_start_params.json';
/** 本次 onCreate 的发生时刻（UI 判定"拉起确实送达"，识别被系统吞掉的 start） */
const LAUNCH_EPOCH_FILE = 'vpn_launch_epoch.txt';
/** 回退文件可接受的写入年龄上限：超过即视为陈旧，宁可拒绝也不复用历史意图 */
const START_PARAMS_MAX_AGE_MS = 180000;
/** 兼容旧 UI 的事件状态快照文件，不再周期性写入。 */
/**
 * 进程内存采样文件（2026-10-28）：内核跑在**本扩展进程**里，所以本进程的
 * VmRSS 就是「内核进程内存占用」。App 侧 `/memory` 端点实测会 Operation timeout
 * （真机日志 code=2300028），因此由扩展进程自己采样写盘，UI 优先读 /memory、
 * 失败再回落到这个文件。
 */
const MEM_FILE = 'vpn_mem_kb.txt';
const MEM_TMP_FILE = 'vpn_mem_kb.txt.tmp';
/** 内存采样周期（ms）：比心跳慢，避免高频 stat 拖慢 ArkTS 线程 */
const MEM_SAMPLE_MS = 5000;
const HEARTBEAT_FILE = 'vpn_heartbeat.txt';
/** 存活租约的原子替换临时文件（先写 .tmp，再 rename 覆盖心跳本体） */
const HEARTBEAT_TMP_FILE = 'vpn_heartbeat.txt.tmp';
/**
 * 存活租约刷新周期（ms）。
 *
 * 2026-10-20 自动断开整改：租约刷新与内核探针**彻底解耦**。
 * 原实现把 `touchLivenessLease()` 放在 10s 的内核探针回调里，而那个回调**第一件事**
 * 就是同步调 `coreBridge.isCoreAlive()`。该原生调用在旧实现里会一路进入 Go 侧
 * `coreMu.Lock()`，而 Start()/Stop() 全程持有 coreMu（内含 ApplyConfig 与
 * executor.Shutdown，可达秒级）—— 于是扩展进程的 ArkTS 线程被阻塞、整条定时器链
 * 停摆 → 心跳停更 → UI 侧 15s 陈旧窗口判死 → 拆隧道重连。真机表现为 27~36s 一轮的
 * "自己把自己断掉"。
 * 现在租约由**独立定时器**刷新，回调内**不做任何原生调用、不做任何 stat**。
 */
const LEASE_REFRESH_MS = 5000;
/** 内核存活探针周期（ms）：只影响"要不要重启内核"，不再参与租约刷新。 */
const CORE_PROBE_MS = 10000;
/**
 * 连续多少次探针判定"内核已死"才动手。
 *
 * 误判代价 = 一次无谓的核心重启（不拆 TUN、不动 Kill Switch，代价低），但仍不应为 0：
 * 探针采样与内核状态切换之间存在瞬态错位，单次采样不足以定性。
 */
const CORE_DEATH_CONFIRMATIONS = 2;
/** Extension 主导的权威运行态文件（事件驱动写入，UI 打开时直接读取真实状态）。 */
const STATUS_FILE = 'vpn_status.json';
/**
 * 内核启动硬超时。mihomo 的 TunBoxStart() 若在启动路径里联网（典型：rule-provider /
 * MMDB 本地文件缺失时同步拉取远端），会一直阻塞不返回也不报错——UI 侧只能等到
 * 30s deadline 拿到"未上报启动结果"这种无用文案。这里在内核调用外加一层超时，
 * 把「静默挂起」转成明确错误并回传（真机实证 2026-09-19 全新安装首连）。
 * 取 20s：正常启动（含 attachTun/protect）实测 < 1s，留足弱网余量。
 */
const CORE_START_TIMEOUT_MS = 20000;
/** protect 轮询自适应节奏：命中请求后回到底线 10ms；空闲时指数退避、封顶 100ms */
const PROTECT_POLL_BASE_MS = 10;
const PROTECT_POLL_MAX_MS = 100;
/** 单轮最多排空的 protect 请求数（原实现常量，语义保持不变） */
const PROTECT_DRAIN_MAX = 16;

/** 单个 native 阶段的等待结果（ArkTS 不允许无类型对象字面量，显式声明类） */
class StageOutcome {
  /** 阶段真实结果（超时/异常时为 false） */
  public ok: boolean = false;
  /** 是否在超时窗口内既未 resolve 也未 reject（native 挂起） */
  public timedOut: boolean = false;

  constructor(ok: boolean, timedOut: boolean) {
    this.ok = ok;
    this.timedOut = timedOut;
  }
}

/** Extension 写入的权威运行态结构。 */
export class VpnRuntimeStatus {
  /** running | recovering | leak-blocked | stopped | failed */
  public phase: string = 'running';
  /** 当前 TUN 使用的 MTU（按物理承载动态）。 */
  public mtu: number = VPN_MTU;
  /** 归一化物理网络类型。 */
  public netType: string = NetTypes.UNKNOWN;
  /** 内核是否存活。 */
  public coreAlive: boolean = true;
  /** 本世代已尝试的 Core 恢复次数。 */
  public recoveryAttempts: number = 0;
  /** 本会话已执行的 TUN 重建次数。 */
  public rebuilds: number = 0;
  /** 递增序列号，供 UI 判定新旧与去重。 */
  public seq: number = 0;
  /** 写入时间戳。 */
  public ts: number = Date.now();
  /** 脱敏说明（绝不含 secret/订阅地址/节点口令）。 */
  public detail: string = '';

  public toJson(): string {
    return `{"phase":"${this.phase}","mtu":${this.mtu},"netType":"${this.netType}","` +
      `"coreAlive":${this.coreAlive ? 'true' : 'false'},"recoveryAttempts":${this.recoveryAttempts},` +
      `"rebuilds":${this.rebuilds},"seq":${this.seq},"ts":${this.ts},"detail":"${this.detail}"}`;
  }
}

/** want 丢参时从启动参数回退文件还原出的三元组（不含任何凭据）。 */
class StartParamsSnapshot {
  public mode: string = '';
  public packagesJson: string = '';
  public needsReview: boolean = false;
}

/**
 * TUN 层唯一开关：从生成的那份 YAML 里读回（见 readTunFlagsFromConfig）。
 * 不用 want 参数下发：内核认的配置和 TUN 装的地址必须是同一份事实，
 * YAML 是唯一真源，也就天然免疫 want 丢失 / 进程被杀重启后的参数陈旧。
 *
 * DNS 接管同样从这份 YAML 读回（`dns.enable`，见 readTunFlagsFromConfig）：
 * 开 ⇒ 下发 VpnConfig.dnsAddresses = sentinel；关 ⇒ **不下发**，系统沿用物理网络 DNS。
 * 唯一真源仍是 YAML，所以不会出现「内核不跑 DNS 却仍把设备 DNS 指过来」的黑洞。
 */
class TunFlags {
  /** 内核 ipv6 总闸（顶层 `ipv6:`）：同时决定 TUN 是否装 v6 地址 + ::/0 */
  public ipv6: boolean = false;
  /**
   * 内核 DNS 总闸（`dns.enable:`，与 `tun.dns-hijack` 同源同生灭）。
   *
   * 默认 **false**（读不到/读失败 ⇒ 保守：不把设备 DNS 指到 sentinel）。
   * 反了会怎样：YAML 读失败时内核没接管 DNS，而设备 DNS 被指到 TUN sentinel
   * ⇒ 整机解析黑洞（2026-10-21 前 TunFlags.dnsOverride 默认 true 踩过）。
   */
  public dnsOverride: boolean = false;
}

export default class TunBoxVpnExtension extends VpnExtensionAbility implements NetworkStateListener {
  /** 当前 VpnConnection（重入时先 destroy 旧的，避免 2200002 VPN already exist） */
  private connection: vpnExtension.VpnConnection | null = null;
  /** Borrowed platform fd; never pass native's private template back to attachTun. */
  private platformTunFd: number = -1;
  /** Invalidates in-flight recovery immediately when cleanup begins. */
  private lifecycleGeneration: number = 0;
  /** Extension 进程内的权威网络监听器，不依赖 UI 进程存活。 */
  private networkWatcher: NetworkStateWatcher | null = null;
  /** 最近一次物理网络类型与事件代数，用于去重和恢复编排。 */
  private lastNetworkType: string = NetTypes.UNKNOWN;
  private lastNetworkGeneration: number = 0;
  /** Core 存活监控与有界恢复状态。 */
  private coreMonitorTimer: number = -1;
  /** 存活租约独立刷新定时器（与内核探针解耦，见 LEASE_REFRESH_MS 注释）。 */
  private leaseTimer: number = -1;
  /** 进程内存采样定时器（与租约独立：一个证明活着，一个采样内存） */
  private memTimer: number = -1;
  private memSampleWarned: boolean = false;
  private memSampleLogged: boolean = false;
  /** 连续判定"内核已死"的次数（累计到 CORE_DEATH_CONFIRMATIONS 才动手）。 */
  private coreDeathStrikes: number = 0;
  private recoveryTimer: number = -1;
  /** TUN 重建专用定时器与门控（与内核热恢复互不干扰）。 */
  private rebuildTimer: number = -1;
  private rebuilding: boolean = false;
  /** Cleanup waits for native in-flight work before its final stop; late starts cannot escape teardown. */
  private rebuildFlight: Promise<void> | null = null;
  private recoveryFlight: Promise<void> | null = null;
  private stopped: boolean = false;
  /** Candidate used only for socket protection while startCore is pending, never published as running. */
  private protectCandidate: vpnExtension.VpnConnection | null = null;
  private recoveryAttempts: number = 0;
  private recoveryRunning: boolean = false;
  private networkAvailable: boolean = true;
  /** 当前实际 MTU，由网络类型决定并同时传给 TUN 与 native bridge。 */
  private activeMtu: number = VPN_MTU;
  /** 当前会话的 VpnConfig，MTU 变化触发隧道重建时复用其余字段。 */
  private tunConfig: vpnExtension.VpnConfig | null = null;
  /** 每次 onCreate 从显式 Want 更新；缺参不可沿用上次策略或推测为 all。 */
  private appRouting: AppRoutingRuntime = new AppRoutingRuntime();

  private applyAppRouting(config: vpnExtension.VpnConfig): void {
    const error = AppRoutingPolicy.runtimeError(this.appRouting);
    if (error.length > 0) {
      throw new Error(error);
    }
    // API 24 两字段互斥；清除旧值后只写所选名单，无差集、无截断、无兜底模式。
    config.trustedApplications = undefined;
    config.blockedApplications = undefined;
    if (this.appRouting.mode === AppRoutingModes.INCLUDE) {
      config.trustedApplications = this.appRouting.packages.slice();
    } else if (this.appRouting.mode === AppRoutingModes.EXCLUDE && this.appRouting.packages.length > 0) {
      config.blockedApplications = this.appRouting.packages.slice();
    }
  }
  /** 本会话已执行的 TUN 重建次数（MTU 变化 / Kill Switch 升级）。 */
  private tunnelRebuilds: number = 0;
  /** Extension 权威运行态序列号，事件每次递增。 */
  private statusSeq: number = 0;
  /** 上次落盘的状态 JSON，用于事件驱动去重（无变化不写盘）。 */
  private lastStatusJson: string = '';
  /** 事件状态快照所在目录（cleanup 时删除兼容快照文件）。 */
  private heartbeatDir: string = '';
  /** Protect socket 请求轮询器，由 Go 核心请求逐 socket 绕过 VPN。 */
  private protectTimer: number = -1;
  /** protect 轮询当前间隔（自适应：空闲退避 / 命中回底线） */
  private protectPollDelayMs: number = PROTECT_POLL_BASE_MS;
  /** 统一清理的幂等门控。 */
  private cleanupPromise: Promise<void> | null = null;
  /** 本次会话的配置路径（onDestroy 时删除含 API secret 的 YAML） */
  private configPathForCleanup: string = '';
  /** 该配置是否为临时测速配置（由 UI 侧生成为 mihomo_test_config.yaml） */
  private configIsTransient: boolean = false;

  /**
   * 删除含凭据的运行时配置。每个文件独立容错，缺失即跳过。
   * @param force 内核启动失败/无头测速失败时即使不是临时配置也删除
   */
  private removePrivateConfig(force: boolean): void {
    if (this.configPathForCleanup.length === 0) {
      return;
    }
    if (!force && !this.configIsTransient) {
      return;
    }
    try {
      fs.unlinkSync(this.configPathForCleanup);
    } catch (e) {
      // 已被 UI 侧删除属正常
    }
  }

  /** 判断配置是否为测速用临时文件（UI 侧命名约定） */
  private static isTransientConfig(path: string): boolean {
    return path.endsWith('mihomo_test_config.yaml');
  }

  /**
   * want.parameters 被系统整体丢弃时的分流参数回退（真机实证 2026-09-19：
   * 新装首连走 VPN 授权弹窗链路后，系统重建的扩展 want 只剩空参 → 防泄漏
   * 门禁把首连误杀，UI 读到「应用分流参数缺失或冲突」）。
   *
   * 两级来源，依次回退：
   *  1. cacheDir/vpn_start_params.json —— UI 每次拉起前原子重写的本次三元组；
   *     仅当「configPath 逐字相等 + 写入年龄 ≤3 分钟 + 三字段类型完整」才采信。
   *  2. preferences 里的持久化副本 —— 与扩展进程同沙箱同库，没有时间窗限制；
   *     但额外要求**持久化用户意图仍是"想连着"**，否则那是用户主动断开后的残留。
   * 两条来源都拿不到时返回 null 维持拒绝 —— 依然不猜默认值，防泄漏红线不变。
   */
  private async readStartParamsFallback(configPath: string): Promise<StartParamsSnapshot | null> {
    const fromFile = this.readStartParamsFile(configPath);
    if (fromFile !== null) {
      return fromFile;
    }
    return this.readStartParamsFromPreferences(configPath);
  }

  /** cacheDir 回退文件：只接受「≤3 分钟 + configPath 逐字相等」，防串用别的会话。 */
  private readStartParamsFile(configPath: string): StartParamsSnapshot | null {
    try {
      const file = fs.openSync(`${this.context.cacheDir}/${START_PARAMS_FILE}`, fs.OpenMode.READ_ONLY);
      let text = '';
      try {
        const buf = new ArrayBuffer(16384);
        const len = fs.readSync(file.fd, buf);
        text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, len));
      } finally {
        fs.closeSync(file);
      }
      const rec = JSON.parse(text) as Record<string, Object>;
      const filePath = typeof rec['configPath'] === 'string' ? rec['configPath'] as string : '';
      // ts 非法/缺失 → age=-1 哨兵，落入下方拒绝分支
      const age = typeof rec['ts'] === 'number' ? Date.now() - (rec['ts'] as number) : -1;
      const mode = typeof rec['appRoutingMode'] === 'string' ? rec['appRoutingMode'] as string : '';
      const packagesJson = typeof rec['appRoutingPackagesJson'] === 'string'
        ? rec['appRoutingPackagesJson'] as string : '';
      const needsReview = typeof rec['appRoutingNeedsReview'] === 'boolean'
        ? rec['appRoutingNeedsReview'] as boolean : false;
      if (filePath.length === 0 || filePath !== configPath || age < 0 || age > START_PARAMS_MAX_AGE_MS ||
        typeof rec['appRoutingMode'] !== 'string' ||
        typeof rec['appRoutingPackagesJson'] !== 'string' ||
        typeof rec['appRoutingNeedsReview'] !== 'boolean') {
        return null;
      }
      const snap = new StartParamsSnapshot();
      snap.mode = mode;
      snap.packagesJson = packagesJson;
      snap.needsReview = needsReview;
      AppLogger.warn(TAG, 'appRouting params recovered from start-params file (want lost by system restart)');
      return snap;
    } catch (e) {
      return null;
    }
  }

  /**
   * preferences 回退（第三道，也是后台被杀后唯一还能命中的那道）。
   *
   * cacheDir 那份 3 分钟就作废，而「进程被系统回收 → OS 重新拉起扩展」几乎必然
   * 超过 3 分钟，于是这里原本会硬拒绝恢复，表现为隧道再也起不来。UI 进程每次
   * 连接前把同一份三元组也写进 preferences（同 App 同沙箱，扩展读得到）。
   *
   * 仍然不猜任何默认值，三重校验缺一不可：
   *  1. 持久化用户意图仍是"想连着"（否则这是用户主动断开后的残留启动）；
   *  2. configPath 与本次解析出的路径逐字相等（防止串用别的会话的分流范围）；
   *  3. 三个字段类型完整（脏数据一律拒绝）。
   */
  private async readStartParamsFromPreferences(configPath: string): Promise<StartParamsSnapshot | null> {
    try {
      await SettingsService.init(this.context);
      const conn = await SettingsService.loadSnapshot();
      if (!conn.desiredConnected) {
        AppLogger.warn(TAG, 'appRouting params: persisted intent is not "connected"; keep refusing');
        return null;
      }
      const routing = await SettingsService.loadAppRoutingSnapshot();
      if (routing === null) {
        return null;
      }
      if (routing.configPath.length === 0 || routing.configPath !== configPath) {
        AppLogger.warn(TAG, `appRouting params: persisted snapshot belongs to another config`
          + ` (${routing.configPath}); keep refusing`);
        return null;
      }
      if (routing.appRoutingMode.length === 0) {
        return null;
      }
      const snap = new StartParamsSnapshot();
      snap.mode = routing.appRoutingMode;
      snap.packagesJson = routing.appRoutingPackagesJson;
      snap.needsReview = routing.appRoutingNeedsReview;
      AppLogger.warn(TAG, 'appRouting params recovered from persisted snapshot'
        + ' (start-params file expired; intent=connected)');
      return snap;
    } catch (e) {
      AppLogger.warn(TAG, `appRouting params recovery failed: ${AppLogger.errText(e)}`);
      return null;
    }
  }

  /**
   * onCreate 送达标记（时间戳）。UI 侧 stop→start 存在真机竞态：目标进程尚在退出
   * 时 start 会被系统吞并（既不回调 onCreate 也不报错），30s readiness 只能以
   * 「无响应」收场。UI 每次拉起后确认本文件时间戳晚于发起时刻，未送达则重试。
   */
  private writeLaunchEpoch(): void {
    try {
      const file = fs.openSync(`${this.context.cacheDir}/${LAUNCH_EPOCH_FILE}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, `${Date.now()}`);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      // 标记仅服务 UI 判定，写失败不得影响隧道启动
    }
  }

  /**
   * 带硬超时的阶段等待。返回 StageOutcome：
   * - timedOut=true 表示 native 调用在超时内既没 resolve 也没 reject（挂起）
   * - 否则 ok 为该阶段的真实布尔结果（异常按 false 处理并记录）
   * 之所以需要它：mihomo 在启动路径里联网（rule-provider / MMDB 本地缺失）时会一直
   * 阻塞，既不返回也不报错，UI 侧只能等到 30s deadline 拿到无信息量的文案。
   */
  private async runStage(label: string, stage: Promise<boolean>, timeoutMs: number): Promise<StageOutcome> {
    AppLogger.info(TAG, `stage ${label} starting`);
    const outcome = await new Promise<StageOutcome>((resolve) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (!settled) {
          settled = true;
          resolve(new StageOutcome(false, true));
        }
      }, timeoutMs);
      stage.then((ok: boolean) => {
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve(new StageOutcome(ok, false));
        }
        return ok;
      }).catch((e: Object) => {
        AppLogger.warn(TAG, `stage ${label} rejected: ${AppLogger.errText(e)}`);
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          resolve(new StageOutcome(false, false));
        }
      });
    });
    if (outcome.timedOut) {
      AppLogger.error(TAG, `stage ${label} TIMEOUT after ${timeoutMs}ms (native call blocked)`);
    } else {
      AppLogger.info(TAG, `stage ${label} done: ok=${outcome.ok}`);
    }
    return outcome;
  }

  /** 带硬超时的内核启动：把 native 侧的静默挂起转成可回传的明确错误 */
  private async startCoreWithTimeout(configPath: string): Promise<boolean> {
    const outcome = await this.runStage('startCore', coreBridge.startCore(configPath), CORE_START_TIMEOUT_MS);
    if (outcome.timedOut) {
      // 超时后不在此处 stopCore：native 可能仍在启动路径里，交给 cleanupResources 统一回收
      throw new Error('内核启动超时（20s 无响应）：配置引用的远程规则集或数据库缺失时，'
        + '内核会在启动阶段联网下载而长期阻塞。请稍后重试（规则集已在后台补齐）');
    }
    return outcome.ok;
  }

  /** 把扩展进程内的启动失败原因写回 UI 可读的目录（跨进程无法直接共享内存） */
  private reportStartError(configPath: string, message: string): void {
    try {
      const dir = configPath.substring(0, configPath.lastIndexOf('/'));
      const file = fs.openSync(`${dir}/${START_ERROR_FILE}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, message);
      } finally {
        // 写入失败也必须释放 fd（此前 writeSync 抛错会泄漏句柄）
        fs.closeSync(file);
      }
    } catch (e) {
      AppLogger.warn(TAG, `write start error file failed: ${AppLogger.errText(e)}`);
    }
  }

  /** 写入启动成功标记（内容为时间戳，便于排查） */
  private reportStartOk(configPath: string): void {
    try {
      const dir = configPath.substring(0, configPath.lastIndexOf('/'));
      const file = fs.openSync(`${dir}/${START_OK_FILE}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, `${Date.now()}`);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      AppLogger.warn(TAG, `write start ok file failed: ${AppLogger.errText(e)}`);
    }
  }

  private clearStartError(configPath: string): void {
    const dir = configPath.substring(0, configPath.lastIndexOf('/'));
    const targets: string[] = [START_ERROR_FILE, START_OK_FILE, HEARTBEAT_FILE, HEARTBEAT_TMP_FILE, STATUS_FILE];
    // 逐文件独立容错：一个文件不存在不得阻止其余文件删除
    for (const name of targets) {
      try {
        fs.unlinkSync(`${dir}/${name}`);
      } catch (e) {
        // 文件不存在属正常
      }
    }
  }

  /**
   * 事件驱动写入 Extension 权威运行态。仅在状态真正变化时落盘，避免固定周期写盘；
   * core 监控作为兜底对账（每 10s 最多一次），把恢复进度/MTU/网络类型变化推到 UI。
   */
  private writeStatus(phase: string, coreAlive: boolean, detail: string): void {
    if (this.heartbeatDir.length === 0) {
      return;
    }
    const st = new VpnRuntimeStatus();
    // No platform verification of blocking: report retained-TUN recovery, not proven safety.
    st.phase = phase === 'leak-blocked' ? (this.connection !== null ? 'recovering' : 'failed') : phase;
    st.mtu = this.activeMtu;
    st.netType = this.lastNetworkType;
    st.coreAlive = coreAlive;
    st.recoveryAttempts = this.recoveryAttempts;
    st.rebuilds = this.tunnelRebuilds;
    st.seq = ++this.statusSeq;
    st.ts = Date.now();
    st.detail = detail;
    // 存活租约**不再**由本函数维护，也**绝不**在这里删除心跳文件。
    //
    // 2026-10-20 自动断开整改：心跳文件的语义被收敛为「扩展进程还活着」
    // （由独立的 LEASE_REFRESH_MS 定时器无条件刷新）。旧实现把「内核不活」编码成
    // 「删掉心跳文件」，于是扩展侧一次探针误判就会把心跳删掉，UI 侧只看到
    // 「心跳缺失」——**两个不同维度的问题被压成同一个信号**，且无法区分
    // 「扩展进程死了」和「内核刚重启」，直接触发拆隧道重连。
    // 现在内核维度的信息走 STATUS_FILE 的 coreAlive 字段（由本类的恢复编排闭环），
    // 心跳只表示扩展进程存活。
    const text = st.toJson();
    if (text === this.lastStatusJson) {
      return; // 权威态无变化不重复写 STATUS_FILE（事件驱动）
    }
    this.lastStatusJson = text;
    try {
      const file = fs.openSync(`${this.heartbeatDir}/${STATUS_FILE}`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, text);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      AppLogger.warn(TAG, `status write failed: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * 低频存活租约：仅写一个时间戳到心跳文件，供 UI 判断扩展进程/隧道是否还活着。
   *
   * 2026-10-20 自动断开整改：改为**原子替换**。
   * 旧实现用 READ_WRITE|CREATE|TRUNC 打开后再 write —— TRUNC 与 write 之间存在一个
   * 「文件长度为 0」的窗口，UI 若恰好在此刻读到就是 0 字节（内容为空），而空内容
   * 此前被当作「无心跳 ⇒ 已死」处理 → 又一次假判死。
   * 现在写入临时文件后 rename 覆盖：读者要么看到旧内容、要么看到新内容，
   * **永远读不到半个文件**。
   */
  private touchLivenessLease(ts: number): void {
    if (this.heartbeatDir.length === 0) {
      return;
    }
    const target = `${this.heartbeatDir}/${HEARTBEAT_FILE}`;
    const tmp = `${this.heartbeatDir}/${HEARTBEAT_TMP_FILE}`;
    try {
      const hb = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(hb.fd, `${ts}`);
      } finally {
        fs.closeSync(hb);
      }
      fs.renameSync(tmp, target);
    } catch (e) {
      AppLogger.warn(TAG, `liveness lease write failed: ${AppLogger.errText(e)}`);
      // 原子替换失败时退回就地覆写：宁可读到旧时间戳，也别读到空文件。
      try {
        const hb = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(hb.fd, `${ts}`);
        } finally {
          fs.closeSync(hb);
        }
      } catch (e2) {
        AppLogger.warn(TAG, `liveness lease fallback write failed: ${AppLogger.errText(e2)}`);
      }
    }
  }

  /**
   * 把 mihomo 配置里的 `  mtu: NNNN`（tun 段，恰好 2 空格缩进）改写为当前 activeMtu，
   * 使内核 gvisor 与 VpnConfig.mtu 一致。仅匹配 tun 段的两空格 mtu 行，避免误改
   * 节点级（更深缩进）的 wireguard mtu。改写失败静默忽略（回落配置自带值）。
   *
   * 真机事故修复（2026-09-18，蜂窝网络必现「yaml: control characters are not
   * allowed」）：旧实现在**同一个已读过的 fd** 上 truncate(0) 后 writeSync——
   * POSIX 语义下 truncate 不重置文件偏移，写发生在旧偏移处，文件头部留下
   * 与旧长度等长的 NUL 稀疏空洞，mihomo 把 NUL 判为控制字符整份拒载。
   * Wi-Fi 下 MTU=1400 与配置默认值相同、走不到改写分支,所以只有蜂窝(1360)
   * 用户报错——这解释了「有人必现、有人从不复现」。现在改为读毕关 fd,以
   * CREATE|TRUNC 重新打开再写,新 fd 偏移恒为 0,杜绝空洞。
   */
  private ensureConfigMtu(): void {
    const path = this.configPathForCleanup;
    if (path.length === 0) {
      return;
    }
    const tmp = `${path}.mtu.tmp`;
    try {
      const text = this.readConfigText(path);
      const patched = text.replace(/^ {2}mtu: \d+$/m, `  mtu: ${this.activeMtu}`);
      if (patched === text) {
        // Wi-Fi / 以太网：activeMtu 与生成器缺省值（ClashConfigGenerator 的 1400）一致，
        // 无需改写。注意这是**只有蜂窝才会走下面写盘分支**的原因，也是本函数
        // 历次事故「蜂窝必现、Wi-Fi 从不复现」的共同根源。
        return;
      }
      // 显式 UTF-8 编码：配置里含中文注释，patched.length（JS 字符数）≠ 字节数。
      // 用字符数比对短写会对**每一份**配置误判为失败；writeSync 返回的是字节数，
      // 必须与 byteLength 同口径（PrivateFileStore.writePrivate 同款）。
      const bytes = util.TextEncoder.create('utf-8').encode(patched);
      const total = bytes.byteLength;
      // 原子替换（tmp → rename）：startCore 与本改写可能紧邻，半写文件会让内核
      // 撞上截断 YAML（unexpected end of stream）。同目录 rename 在 POSIX 语义下
      // 对读者要么旧文件、要么新文件，永不半份。
      const wf = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        // 【2026-10-29 蜂窝断网修复】循环写直到全部落盘。writeSync 是 POSIX write
        // 语义，**允许短写**：单次返回 < 请求字节数是合法的，大配置（真机 4846+ 行）
        // 尤其明显。旧实现忽略返回值直接 rename，等于把可能被截断的半份 YAML
        // 原子提升为正式配置 —— 内核整份拒载（unexpected end of stream）后，
        // TUN 默认路由（Kill Switch）仍在 → 全量黑洞，就是用户看到的「断网」。
        // 2026-10-24 已把**读**侧改成循环读到 EOF，写侧当时漏了，本次补齐。
        let remain: Uint8Array = bytes;
        let done = 0;
        while (remain.byteLength > 0) {
          const n = fs.writeSync(wf.fd, remain.slice().buffer as ArrayBuffer);
          if (n <= 0) {
            throw new Error(`config mtu write stalled at ${done}/${total} bytes`);
          }
          done += n;
          remain = remain.subarray(n);
        }
        if (done !== total) {
          throw new Error(`config mtu write incomplete: ${done}/${total} bytes`);
        }
        // rename 前 fsync（与 ConnectionOrchestrator 资产下载同口径）：避免 rename
        // 已生效而数据仍在页缓存，掉电/被杀后内核读到空洞。
        fs.fsyncSync(wf.fd);
      } finally {
        fs.closeSync(wf);
      }
      fs.renameSync(tmp, path);
      AppLogger.info(TAG, `config mtu synced to ${this.activeMtu} (${total} bytes)`);
    } catch (e) {
      // 改写失败时**保留原配置**（mtu 维持生成器缺省值），绝不把半份 YAML 提升上去。
      // 宁可 TUN 与内核 MTU 暂时不一致（只影响分片/吞吐），也不能让内核整份拒载
      // （那会直接黑洞全部流量）。残留 tmp 必须清掉，否则下次改写基于脏 tmp。
      try {
        fs.unlinkSync(tmp);
      } catch (ignore) {
        // tmp 可能尚未创建（openSync 就失败），忽略
      }
      // 用 error 而非 warn：这条路径失败意味着 MTU 不变量已被破坏，需要能被诊断到。
      AppLogger.error(TAG, `config mtu sync FAILED, kept original config `
        + `(activeMtu=${this.activeMtu}): ${AppLogger.errText(e)}`);
    }
  }

  /** 读配置全文（循环读到 EOF，无截断）。ensureConfigMtu 与 readTunFlagsFromConfig 共用。
   *
   * 【2026-10-24 蜂窝必现事故修复】旧实现单次 readSync 进固定 256KB buffer——
   * 大订阅配置（真机 4846+ 行，超 256KB）被静默截断，ensureConfigMtu 在蜂窝
   * （MTU=1360 ≠ 默认，必走改写分支）把半份 YAML TRUNC 重写回盘，内核报
   * `parse config: yaml: line N: found unexpected end of stream` 整份拒载。
   * WiFi（MTU 与默认一致）跳过改写所以从不复现——与 2026-09-18 那次
   * 「蜂窝必现、WiFi 不复现」同款模式。现循环读到 EOF，8MB 硬上限仅防失控
   * （2000 节点 + 规则集的极端配置也在 1MB 量级）。
   */
  private readConfigText(path: string): string {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const chunkSize = 262144;
      const hardCap = 8 * 1024 * 1024;
      const chunks: Uint8Array[] = [];
      let total = 0;
      while (total < hardCap) {
        const buf = new ArrayBuffer(chunkSize);
        const len = fs.readSync(file.fd, buf);
        if (len <= 0) {
          break;
        }
        chunks.push(new Uint8Array(buf).subarray(0, len));
        total += len;
      }
      const all = new Uint8Array(total);
      let offset = 0;
      for (const chunk of chunks) {
        all.set(chunk, offset);
        offset += chunk.length;
      }
      return util.TextDecoder.create('utf-8').decodeToString(all);
    } finally {
      fs.closeSync(file);
    }
  }

  /**
   * 从生成的那份 YAML 读回 TUN 需要知道的开关。
   *
   * 关键不变量：**TUN 装什么，必须与内核认的完全一致**。
   *   · `ipv6: true` → 内核开出站 v6 + dns.ipv6；TUN 必须同时装 v6 地址与 ::/0，
   *     否则 v6 要么被平台塞进 TUN 却无人处理（黑洞），要么绕过 TUN 直连（泄漏）。
   * DNS 也从这份 YAML 读回（`dns.enable`）：开 ⇒ 下发 sentinel，关 ⇒ 不下发 dnsAddresses。
   * 所以这里不接 want 参数、也不缓存：每次 onCreate 现读，天然与配置同源，
   * want 丢失 / 进程被杀重启 / 用户改完开关后重连，三种情况都不会参数陈旧。
   */
  private readTunFlagsFromConfig(path: string): TunFlags {
    const flags = new TunFlags();
    try {
      const text = this.readConfigText(path);
      // 2026-10-21：不再用「整行字面量」正则。覆盖层经 C17 结构化合并后可能出现
      // 流式 `ipv6: "true"` / `ipv6: yes`，旧正则对它们全部返回 false ⇒ TUN 静默
      // 退回「IPv4-only」，而内核仍按 YAML 开着双栈 —— 正是本文件头部警告的
      // 「TUN 与内核不一致」。
      flags.ipv6 = TunBoxVpnExtension.readTopLevelBool(text, 'ipv6');
      // DNS：同一份 YAML 的 dns.enable 行。读不到 ⇒ false（保守：不劫持、不改设备 DNS）
      flags.dnsOverride = TunBoxVpnExtension.readDnsEnable(text);
    } catch (e) {
      // 读不到 → 退回保守形态（IPv4-only）：宁可少开，也不要装一条
      // 内核并不认的 ::/0 把设备的 v6 打进黑洞。
      AppLogger.warn(TAG, `read tun flags failed: ${AppLogger.errText(e)}`);
    }
    return flags;
  }

  /**
   * 读顶层布尔：兼容 `true` / `yes` / `on` / `1`、带引号写法与行尾注释。
   *
   * 只用 `m` 标志 + `^`：顶层键必须**顶格**，因此不会误命中 `dns.ipv6` 这类子键。
   */
  private static readTopLevelBool(text: string, key: string): boolean {
    const re = new RegExp('^' + key + ':[ \\t]*("?)([A-Za-z0-9]+)\\1[ \\t]*(?:#.*)?$', 'm');
    const m: RegExpMatchArray | null = text.match(re);
    return m !== null && TunBoxVpnExtension.isTrueScalar(m[2]);
  }

  /** YAML 1.1/1.2 里所有被视为「真」的标量写法（内核用 yaml.v3，两种拼写都认）。 */
  private static isTrueScalar(raw: string): boolean {
    const v = raw.toLowerCase();
    return v === 'true' || v === 'yes' || v === 'on' || v === '1';
  }

  /**
   * 读 `dns.enable`（顶层 `dns:` 下二空格缩进的子键）。
   *
   * 两段式：先定位**顶格** `dns:` 行，再在其后第一段缩进内容里找 `enable:`，
   * 遇到下一个顶格键就结束 —— 不会误吃 YAML 覆盖层里别处的 `enable:`。
   * 值与内核同口径（yaml.v3 的 true/yes/on/1）；读不到/解析失败返回 false，
   * 宁可「不接管」也不要「内核没跑 DNS 却把设备 DNS 指过去」（解析黑洞）。
   */
  private static readDnsEnable(text: string): boolean {
    const lines: string[] = text.split('\n');
    let inDns: boolean = false;
    for (const raw of lines) {
      const line: string = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
      if (!inDns) {
        if (/^dns:[ \t]*(?:#.*)?$/.test(line)) {
          inDns = true;
        }
        continue;
      }
      const trimmed: string = line.trim();
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      // 回到顶格 ⇒ dns 段到此结束
      if (!/^[ \t]/.test(line)) {
        return false;
      }
      const m: RegExpMatchArray | null =
        line.match(/^[ \t]+enable:[ \t]*("?)([A-Za-z0-9]+)\1[ \t]*(?:#.*)?$/);
      if (m !== null) {
        return TunBoxVpnExtension.isTrueScalar(m[2]);
      }
    }
    return false;
  }

  /**
  /**
   * 构造 TUN 路由表：v4 默认 + （双栈时）v6 默认。
   *
   * ⚠ 2026-10-21 真机复议（本文件头部已记）：平台**丢弃** VpnConfig.routes 里的所有 v6 条目
   * （::/0 带 family / 不带 family / interface 为空三种写法，c00::/71 具体前缀 —— 全被
   * 静默丢弃）；v6 真正生效的是 **LinkAddress 前缀派生的 on-link 路由**：/126 只有 /126，
   * /64 就有 dfe:dcba:9876::/64 ... vpn-tun。所以 v6 的接管不靠这里，靠 TUN_PREFIX_V6。
   * 下面这条 v6 默认路由只为**向前兼容**保留（新系统版本若肯装，就自动生效）；
   * 假 v6 池（fake-ip-range6）与它无关 —— 那个 /64 已经在 on-link 上。
   */
  private buildTunRoutes(flags: TunFlags): vpnExtension.RouteInfo[] {
    const routes: vpnExtension.RouteInfo[] = [{
      interface: TUN_IFNAME,
      destination: { address: { address: '0.0.0.0', family: 1 }, prefixLength: 0 },
      gateway: { address: '0.0.0.0', family: 1 },
      hasGateway: false,
      isDefaultRoute: true
    }];
    if (!flags.ipv6) {
      return routes;
    }
    routes.push({
      interface: TUN_IFNAME,
      // 【family 必须显式给 2】SDK 定义：NetAddress.family 缺省为 **1（IPv4）**。
      // 旧实现漏写 family，这条 ::/0 会被平台当成「IPv4 族、目的地为 :: 字面量」的
      // 畸形路由：轻则整条被丢弃（v6 绕过 TUN 直连，泄露），重则与上面那条
      // 真正的 v4 默认路由冲突（两条 isDefaultRoute: true）→ 路由表错乱。
      // 为何只在蜂窝暂露：国内蜂窝普遍下发 v6 且常为 v6 优先，客户端真会走
      // AAAA；而家用 WiFi 多为 v4 优先，这条路由几乎不被命中——又是一例
      // 「蜂窝必现、WiFi 不复现」。gateway 同步改为 v6 字面量（hasGateway=false
      // 时不参与选路，但类型上不能给 v6 路由配 v4 网关）。
      destination: { address: { address: '::', family: 2 }, prefixLength: 0 },
      gateway: { address: '::', family: 2 },
      hasGateway: false,
      isDefaultRoute: true
    });
    return routes;
  }

  /**
   * 隧道建立成功后的事件驱动快照（替代旧版每 3s 心跳写盘）。
   * Core 存活由 Extension 进程直接探测，文件仅供旧 UI 跨进程读取。
   */
  private publishStateSnapshot(configPath: string): void {
    const dir = configPath.substring(0, configPath.lastIndexOf('/'));
    this.heartbeatDir = dir;
    this.writeStatus('running', true, 'tunnel-up');
  }

  /**
   * 排空 Go 内核的逐 fd protect 请求队列, 并发 protect 并按 fd 回执。
   *
   * 语义(v3, 真机双实证): protectProcessNet 在本机对 Go socket 不生效, "先
   * protect 后 connect" 的顺序保证全靠这条通道 —— 必须回执(Go 等自己的 fd 回执
   * 才放行 connect, 上限 800ms, 超时 fail-open)。同时按批排空 + 并发 promise,
   * 杜绝旧版"5s 串行等待→排队超时→会话退役→全线 unavailable"的死亡螺旋。
   *
   * 自适应节奏（2026-10-07 评审）：原实现固定 10ms 轮询（100Hz）在整个连接期空转，
   * 与官方对后台进程的 CPU 配额/长时任务"典型负载"管控口径相悖。现改为空闲指数
   * 退避（10→20→…→100ms 封顶），一旦本轮命中请求立即回到底线 —— 新请求最多多等
   * 一个退避窗口（≤100ms），远小于 Go 侧 800ms 回执预算。
   */
  private startProtectMonitor(): void {
    this.stopProtectMonitor();
    this.protectPollDelayMs = PROTECT_POLL_BASE_MS;
    this.scheduleProtectTick();
  }

  private scheduleProtectTick(): void {
    this.protectTimer = setTimeout((): void => {
      this.protectTimer = -1;
      this.drainProtectRequests();
      this.scheduleProtectTick();
    }, this.protectPollDelayMs);
  }

  /** 排空一批 protect 请求并更新自适应节奏。 */
  private drainProtectRequests(): void {
    // Rebuild publishes the candidate only after startCore succeeds; while start is
    // pending the candidate must still serve protect, otherwise Go's 800ms receipt
    // budget expires and dials fail open during the gap.
    const connection = this.connection !== null ? this.connection : this.protectCandidate;
    if (connection === null) {
      // 无连接的窗口（重入/清理间隙）：直接退到上限，避免固定 10ms 空转唤醒
      this.protectPollDelayMs = PROTECT_POLL_MAX_MS;
      return;
    }
    let drained = 0;
    for (let i = 0; i < PROTECT_DRAIN_MAX; i++) {
      const request: number[] = coreBridge.readProtectSocketFd();
      const fd: number = request[0];
      if (fd < 0) {
        break;
      }
      drained += 1;
      const seq: number = request[1];
      // protect 失败(fd 已关闭/复用等)也要回执: Go 侧收到回执(含 false)立即放行拨号。
      connection.protect(fd).then(() => {
        coreBridge.setProtectResultForFd(fd, seq, true);
      }).catch(() => {
        coreBridge.setProtectResultForFd(fd, seq, false);
      });
    }
    // 有请求 → 回底线（活跃期保持低延迟）；空闲 → 指数退避到上限
    this.protectPollDelayMs = drained > 0
      ? PROTECT_POLL_BASE_MS
      : Math.min(this.protectPollDelayMs * 2, PROTECT_POLL_MAX_MS);
  }

  private stopProtectMonitor(): void {
    if (this.protectTimer >= 0) {
      clearTimeout(this.protectTimer);
      this.protectTimer = -1;
    }
  }

  /** 根据物理承载选择保守 MTU：委托给可离线验证的纯策略函数（单一真值源）。 */
  private mtuForNetwork(netType: string): number {
    return mtuForNetType(netType);
  }

  /** Extension 进程内处理网络变化，不依赖 UI 进程。 */
  onNetworkTypeChanged(netType: string, generation: number): void {
    if (generation <= this.lastNetworkGeneration) {
      return;
    }
    const previous = this.lastNetworkType;
    this.lastNetworkGeneration = generation;
    this.lastNetworkType = netType;
    this.networkAvailable = netType !== NetTypes.NONE;
    const nextMtu = this.mtuForNetwork(netType);
    AppLogger.info(TAG, `extension network changed: ${previous} -> ${netType}, mtu=${nextMtu}`);
    if (!this.networkAvailable) {
      // 断网：保持 TUN 与默认路由（Kill Switch），内核无法拨出即天然阻断泄漏；
      // 取消恢复编排，等待网络恢复事件。
      this.cancelRecovery();
      this.writeStatus('leak-blocked', this.coreAliveGuess(), 'network-lost');
      return;
    }
    if (this.connection === null) {
      return;
    }
    if (nextMtu !== this.activeMtu && this.tunnelRebuilds < MAX_TUNNEL_REBUILDS) {
      // MTU 变化必须重建 TUN 才能生效：这是唯一必要的重建，其余情况只做内核热恢复。
      this.activeMtu = nextMtu;
      this.scheduleTunnelRebuild('mtu-change');
    } else {
      // 走到这里要么 MTU 没变，要么重建预算已封顶。**两种情况都不能动 activeMtu**：
      // 平台 TUN 的 MTU 只能随重建改变，而 ensureConfigMtu 会按 activeMtu 改写内核
      // YAML。旧实现在这里无条件 activeMtu = nextMtu，于是热恢复路径（也调
      // ensureConfigMtu）会得到「配置 1360 / TUN 仍 1400」——正是 onCreate 里
      // 「内核 MTU 必须与 VpnConfig.mtu 一致」不变量的反面：内核按 1400 出包、
      // 平台 TUN 只收 1360，大包全丢 → 同样是「断网」。
      if (nextMtu !== this.activeMtu) {
        AppLogger.warn(TAG, `mtu ${this.activeMtu}->${nextMtu} deferred: rebuild budget `
          + `exhausted (${this.tunnelRebuilds}/${MAX_TUNNEL_REBUILDS}), keeping TUN and `
          + `config consistent at ${this.activeMtu}`);
      }
      if (previous === NetTypes.NONE || previous !== netType) {
        this.scheduleCoreRecovery(ReconnectReason.NETWORK_CHANGED);
      }
    }
  }

  /** 无法直接问 native 时，用 running 相位近似内核存活（仅供状态文件呈现）。 */
  private coreAliveGuess(): boolean {
    return this.connection !== null;
  }

  /** 合并短时间内的多次隧道重建请求，指数退避，封顶 MAX_TUNNEL_REBUILDS 次。 */
  private scheduleTunnelRebuild(reason: string): void {
    if (this.stopped || this.cleanupPromise !== null || this.recoveryRunning || this.rebuilding || this.rebuildTimer >= 0 || this.tunnelRebuilds >= MAX_TUNNEL_REBUILDS) {
      return;
    }
    const delay = tunnelRebuildDelayMs(this.tunnelRebuilds);
    this.tunnelRebuilds = this.tunnelRebuilds + 1;
    this.rebuilding = true;
    AppLogger.warn(TAG, `schedule extension TUN rebuild #${this.tunnelRebuilds} in ${delay}ms (${reason})`);
    this.writeStatus('recovering', false, 'tun-rebuild-scheduled');
    this.rebuildTimer = setTimeout((): void => {
      this.rebuildTimer = -1;
      this.rebuildFlight = this.rebuildTunnel(reason).finally((): void => {
        this.rebuilding = false;
        this.rebuildFlight = null;
      });
    }, delay);
  }

  /** 平台只允许拆后重建；间隙不能宣称 Kill Switch 已阻断。 */
  private async rebuildTunnel(reason: string): Promise<void> {
    const config = this.tunConfig;
    const generation = this.lifecycleGeneration;
    const current = (): boolean => generation === this.lifecycleGeneration
      && !this.stopped && this.cleanupPromise === null;
    if (!current() || config === null || this.configPathForCleanup.length === 0) { return; }
    const routingError = AppRoutingPolicy.runtimeError(this.appRouting);
    if (routingError.length > 0) {
      this.writeStatus('failed', false, 'app-routing-invalid');
      return;
    }
    this.applyAppRouting(config);
    config.mtu = this.activeMtu;
    let candidate: vpnExtension.VpnConnection | null = null;
    let retired = this.connection;
    let committed = false;
    let retry = false;
    this.stopCoreMonitor();
    this.stopProtectMonitor();
    try {
      await coreBridge.stopCore();
      if (!current()) { return; }
      this.connection = null;
      this.platformTunFd = -1;
      this.writeStatus('recovering', false, 'tun-rebuild-gap-protection-unverified');
      if (retired !== null) {
        await retired.destroy();
        retired = null;
        if (!current()) { return; }
      }
      candidate = vpnExtension.createVpnConnection(this.context);
      const tunFd = await candidate.create(config);
      if (!current()) { return; }
      await candidate.protectProcessNet();
      if (!current()) { return; }
      const attached = await coreBridge.attachTun(tunFd, this.activeMtu);
      if (!current()) { return; }
      if (!attached) { throw new Error('内核桥重挂载失败（attachTun）'); }
      const protectReady = await coreBridge.initProtect();
      if (!current()) { return; }
      if (!protectReady) { throw new Error('内核 Protect 通道初始化失败'); }
      this.protectCandidate = candidate;
      this.startProtectMonitor();
      this.ensureConfigMtu();
      // 恢复/重建路径与 onCreate 同样可能因 provider/MMDB 联网下载而永不 settle，
      // 必须套 20s 硬超时（onCreate 路径的 startCoreWithTimeout 就是为此而设）。
      const ok = await this.startCoreWithTimeout(this.configPathForCleanup);
      if (!current()) { return; }
      if (!ok) {
        const error = await coreBridge.lastError();
        if (!current()) { return; }
        throw new Error(error);
      }
      this.connection = candidate;
      this.platformTunFd = tunFd;
      this.protectCandidate = null;
      candidate = null;
      committed = true;
      this.recoveryAttempts = 0;
      this.writeStatus('running', true, `tun-rebuilt:${reason}`);
    } catch (e) {
      if (current()) {
        AppLogger.warn(TAG, `TUN rebuild failed: ${AppLogger.errText(e)}`);
        retry = true;
      }
    } finally {
      if (!committed) {
        this.stopProtectMonitor();
        this.protectCandidate = null;
        // Cleanup waits for this flight: even an obsolete start must settle then stop.
        try { await coreBridge.stopCore(); } catch (e) { AppLogger.warn(TAG, 'rebuild rollback stop failed'); }
        if (candidate !== null) {
          try { await candidate.destroy(); } catch (e) { AppLogger.warn(TAG, 'candidate cleanup failed'); }
        }
        if (retired !== null && this.connection !== retired) {
          try { await retired.destroy(); } catch (e) { AppLogger.warn(TAG, 'retired TUN cleanup failed'); }
        }
        if (current()) {
          this.writeStatus('failed', false, 'tun-rebuild-failed-protection-unverified');
        }
      }
      if (current()) {
        this.startCoreMonitor();
        if (retry) {
          setTimeout((): void => {
            if (current()) { this.scheduleTunnelRebuild('retry'); }
          }, 0);
        }
      }
    }
  }

  private startNetworkAuthority(): void {
    if (this.networkWatcher === null) {
      this.networkWatcher = new NetworkStateWatcher();
    }
    this.networkWatcher.addListener(this);
    this.networkWatcher.start(this.context);
    this.lastNetworkType = this.networkWatcher.networkType();
    this.lastNetworkGeneration = this.networkWatcher.generation();
    this.networkAvailable = this.lastNetworkType !== NetTypes.NONE;
    this.activeMtu = this.mtuForNetwork(this.lastNetworkType);
  }

  private stopNetworkAuthority(): void {
    this.cancelRecovery();
    if (this.networkWatcher !== null) {
      this.networkWatcher.stop();
      this.networkWatcher = null;
    }
  }

  /**
   * 内核存活探针（10s）：只回答"内核是否还活着"，**不参与租约刷新**。
   *
   * 2026-10-20 自动断开整改，两处关键改动：
   * 1) 探针回调**不再**负责刷新心跳 —— 那件事已交给独立的租约定时器。探针链路上的
   *    任何阻塞（原生调用、Promise 调度延迟）都不再影响租约的连续性。
   * 2) 单次探针判死**不再**立即动手：必须连续 CORE_DEATH_CONFIRMATIONS 次为假。
   *    旧实现一次 false 就 writeStatus('recovering', false)，而 writeStatus 旧版会
   *    **删除心跳文件** → UI 侧立刻判死并拆隧道重连。
   */
  private startCoreMonitor(): void {
    this.stopCoreMonitor();
    this.startLeaseTimer();
    this.startMemSampler();
    this.coreDeathStrikes = 0;
    this.coreMonitorTimer = UnifiedScheduler.every((): void => {
      if (this.connection === null || this.recoveryRunning || this.rebuilding || !this.networkAvailable) {
        return;
      }
      coreBridge.isCoreAlive().then((alive: boolean): void => {
        if (this.connection === null || this.recoveryRunning || this.rebuilding) {
          return;
        }
        if (alive) {
          this.coreDeathStrikes = 0;
          return;
        }
        this.coreDeathStrikes = this.coreDeathStrikes + 1;
        if (this.coreDeathStrikes < CORE_DEATH_CONFIRMATIONS) {
          // 首次判死只记账、不动手，也**不**动心跳文件（心跳只表示扩展进程存活）。
          AppLogger.warn(TAG, `core liveness probe negative `
            + `(${this.coreDeathStrikes}/${CORE_DEATH_CONFIRMATIONS}), awaiting confirmation`);
          return;
        }
        this.coreDeathStrikes = 0;
        // 内核已死：保持 TUN（Kill Switch），进入恢复编排。
        this.writeStatus('recovering', false, 'core-not-alive');
        this.scheduleCoreRecovery(ReconnectReason.CORE_NOT_ALIVE);
      }).catch((e: Object): void => {
        // 探针异常（原生调用失败）不是"内核已死"的证据，只告警不升级。
        AppLogger.warn(TAG, `core liveness probe failed: ${AppLogger.errText(e)}`);
      });
    }, CORE_PROBE_MS);
  }

  private stopCoreMonitor(): void {
    if (this.coreMonitorTimer >= 0) {
      UnifiedScheduler.clear(this.coreMonitorTimer);
      this.coreMonitorTimer = -1;
    }
  }

  /**
   * 存活租约独立刷新定时器（5s）。
   *
   * 回调内**只做一件事**：把当前时间戳原子写进心跳文件。
   * **不做任何原生调用、不做任何 stat、不解析任何 JSON** —— 目的就是让这条链路的
   * 耗时恒定在几十微秒量级，绝不会被内核启动/停止这类秒级操作卡住。
   *
   * 租约语义 = 「扩展进程还活着且能写盘」，与「内核是否活着」是两个维度：
   * 后者由 STATUS_FILE 的 coreAlive 字段表达，由本类的恢复编排负责闭环。
   *
   * 注意：stopCoreMonitor() **不**停租约定时器 —— 重建 TUN（rebuildTunnel）与
   * 重启内核（recoverCore）期间隧道仍然存在（Kill Switch 生效中），扩展进程也是
   * 活着的，此时心跳必须继续刷新，否则 UI 会误以为扩展死了而拆隧道。
   */
  /**
   * 进程内存采样：读 `/proc/self/status` 的 VmRSS 写 `vpn_mem_kb.txt`（原子替换）。
   *
   * 与租约定时器**分离**：租约回调必须极轻（历史事故：回调里做原生调用把 ArkTS
   * 线程阻塞 → 心跳停更 → UI 判死拆隧道）。这里单独 5s 一次，失败只记一次日志。
   */
  private startMemSampler(): void {
    this.stopMemSampler();
    this.touchMemorySample();
    this.memTimer = UnifiedScheduler.every((): void => {
      if (this.cleanupPromise !== null) {
        return;
      }
      this.touchMemorySample();
    }, MEM_SAMPLE_MS);
  }

  private stopMemSampler(): void {
    if (this.memTimer >= 0) {
      UnifiedScheduler.clear(this.memTimer);
      this.memTimer = -1;
    }
  }

  private touchMemorySample(): void {
    if (this.heartbeatDir.length === 0) {
      return;
    }
    try {
      // 2026-10-28：鸿蒙沙箱的 /proc/self/status 被裁剪（实测拿不到 VmRSS 行），
      // 改用系统 API `hidebug.getPss()`（Pss+SwapPss，单位 KB）。
      // 内核就跑在本扩展进程里，所以这个值就是「内核进程内存占用」。
      const kb: number = Number(hidebug.getPss());
      if (!Number.isFinite(kb) || kb <= 0) {
        if (!this.memSampleWarned) {
          this.memSampleWarned = true;
          AppLogger.warn(TAG, `memory sample: getPss returned ${kb}`);
        }
        return;
      }
      if (!this.memSampleLogged) {
        this.memSampleLogged = true;
        AppLogger.info(TAG, `memory sample ok: ${kb} kB -> ${this.heartbeatDir}/${MEM_FILE}`);
      }
      const target = `${this.heartbeatDir}/${MEM_FILE}`;
      const tmp = `${this.heartbeatDir}/${MEM_TMP_FILE}`;
      const hb = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(hb.fd, `${kb}`);
      } finally {
        fs.closeSync(hb);
      }
      fs.renameSync(tmp, target);
    } catch (e) {
      if (!this.memSampleWarned) {
        this.memSampleWarned = true;
        AppLogger.warn(TAG, `memory sample failed: ${AppLogger.errText(e)}`);
      }
    }
  }

  private startLeaseTimer(): void {
    this.stopLeaseTimer();
    this.touchLivenessLease(Date.now());
    this.leaseTimer = UnifiedScheduler.every((): void => {
      if (this.cleanupPromise !== null) {
        return;
      }
      // 重建 TUN（rebuildTunnel）期间 connection 暂为 null（先拆后建），但扩展进程
      // 仍然活着、隧道语义仍在 —— 此刻心跳必须继续（上方注释的承诺）。若因
      // connection===null 停刷，UI 会在重建窗口内误判扩展死亡而拆隧道，与扩展内
      // 的重建互相打架。真正的清理/断开由 cleanupPromise 兜住（那时确实该停）。
      if (this.connection === null && !this.rebuilding && !this.recoveryRunning) {
        return;
      }
      this.touchLivenessLease(Date.now());
    }, LEASE_REFRESH_MS);
  }

  private stopLeaseTimer(): void {
    if (this.leaseTimer >= 0) {
      UnifiedScheduler.clear(this.leaseTimer);
      this.leaseTimer = -1;
    }
  }

  private cancelRecovery(): void {
    if (this.recoveryTimer >= 0) {
      clearTimeout(this.recoveryTimer);
      this.recoveryTimer = -1;
    }
    if (this.rebuildTimer >= 0) {
      clearTimeout(this.rebuildTimer);
      this.rebuildTimer = -1;
    }
    this.rebuilding = false;
  }

  /** 有界指数退避恢复，只重启 Core，保持 VPN/TUN 与 Kill Switch 路由不被拆除。 */
  private scheduleCoreRecovery(reason: ReconnectReason): void {
    if (this.recoveryRunning || this.recoveryTimer >= 0 || this.rebuilding || this.recoveryAttempts >= MAX_CORE_RECOVERY_ATTEMPTS
      || this.connection === null || !this.networkAvailable) {
      return;
    }
    const delay = coreRecoveryDelayMs(this.recoveryAttempts);
    this.recoveryAttempts = this.recoveryAttempts + 1;
    AppLogger.warn(TAG, `schedule extension core recovery ${this.recoveryAttempts}/${MAX_CORE_RECOVERY_ATTEMPTS} in ${delay}ms (${reason})`);
    this.recoveryTimer = setTimeout((): void => {
      this.recoveryTimer = -1;
      this.recoveryFlight = this.recoverCore(reason).finally((): void => { this.recoveryFlight = null; });
    }, delay);
  }

  private async recoverCore(reason: string): Promise<void> {
    if (this.recoveryRunning || this.rebuilding || this.cleanupPromise !== null || this.connection === null
      || this.platformTunFd < 0 || !this.networkAvailable || this.configPathForCleanup.length === 0) {
      return;
    }
    if (AppRoutingPolicy.runtimeError(this.appRouting).length > 0) {
      this.writeStatus('leak-blocked', false, 'app-routing-invalid');
      return;
    }
    const generation = this.lifecycleGeneration;
    const connection = this.connection;
    const tunFd = this.platformTunFd;
    const current = (): boolean => generation === this.lifecycleGeneration && this.connection === connection
      && this.platformTunFd === tunFd && this.cleanupPromise === null && !this.rebuilding;
    this.recoveryRunning = true;
    let retry = false;
    this.stopCoreMonitor();
    this.stopProtectMonitor();
    try {
      await coreBridge.stopCore();
      if (!current()) { return; }
      // stopCore resets the ArkTS fd. Reinject the platform-owned original,
      // never the native template (attach replaces/closes the previous template).
      const attached = await coreBridge.attachTun(tunFd, this.activeMtu);
      if (!current()) { return; }
      if (!attached) { throw new Error('core recovery attachTun failed'); }
      const protectReady = await coreBridge.initProtect();
      if (!current()) { return; }
      if (!protectReady) { throw new Error('core recovery initProtect failed'); }
      this.startProtectMonitor();
      this.ensureConfigMtu();
      // 热恢复路径同样要 20s 硬超时（与 onCreate/rebuild 同口径）：
      // provider/规则集联网下载阻塞时 startCore 可能永不 settle。
      const ok = await this.startCoreWithTimeout(this.configPathForCleanup);
      if (!current()) { return; }
      if (!ok) {
        throw new Error(await coreBridge.lastError());
      }
      if (!current()) { return; }
      this.recoveryAttempts = 0;
      // Recovery is not the initial startup handshake: do not recreate START_OK.
      this.writeStatus('running', true, `core-recovered:${reason}`);
      AppLogger.info(TAG, `extension core recovered without rebuilding TUN (${reason})`);
    } catch (e) {
      if (!current()) { return; }
      this.stopProtectMonitor();
      try {
        await coreBridge.stopCore();
      } catch (stopError) {
        AppLogger.warn(TAG, 'core recovery rollback failed');
      }
      if (!current()) { return; }
      AppLogger.warn(TAG, `extension core recovery failed: ${AppLogger.errText(e)}`);
      this.writeStatus('leak-blocked', false, 'core-recovery-failed');
      retry = true;
    } finally {
      this.recoveryRunning = false;
      if (current()) {
        this.startCoreMonitor();
        // Schedule only after releasing recoveryRunning; otherwise retries are dropped.
        if (retry && this.networkAvailable) {
          if (this.recoveryAttempts >= MAX_CORE_RECOVERY_ATTEMPTS && this.tunnelRebuilds < MAX_TUNNEL_REBUILDS) {
            this.recoveryAttempts = 0;
            this.scheduleTunnelRebuild('core-recovery-exhausted');
          } else {
            this.scheduleCoreRecovery(ReconnectReason.RETRY);
          }
        }
      }
    }
  }

  private cleanupResources(): Promise<void> {
    if (this.cleanupPromise !== null) {
      return this.cleanupPromise;
    }
    this.cleanupPromise = this.cleanupResourcesInternal().finally(() => {
      this.cleanupPromise = null;
    });
    return this.cleanupPromise;
  }

  private async cleanupResourcesInternal(): Promise<void> {
    this.stopped = true;
    this.lifecycleGeneration++;
    const connection = this.connection;
    this.connection = null;
    this.platformTunFd = -1;
    this.stopCoreMonitor();
    this.stopLeaseTimer();
    this.stopMemSampler();
    this.stopNetworkAuthority();
    this.stopProtectMonitor();
    // 状态文件清理：删除权威态与兼容心跳文件，防止其他进程在陈旧窗口内把
    // "已断开"误判为"内核还活着"（与 orchestrator.clearTunnelMarkers 双保险）。
    if (this.heartbeatDir.length > 0) {
      const stale: string[] = [HEARTBEAT_FILE, HEARTBEAT_TMP_FILE, STATUS_FILE, MEM_FILE, MEM_TMP_FILE];
      for (const name of stale) {
        try {
          fs.unlinkSync(`${this.heartbeatDir}/${name}`);
        } catch (e) {
          // 已被 UI 侧删除属正常
        }
      }
    }
    // Wait for obsolete native starts before the final stop; never race a new session.
    if (this.rebuildFlight !== null) { await this.rebuildFlight; }
    if (this.recoveryFlight !== null) { await this.recoveryFlight; }
    this.protectCandidate = null;
    // 临时测速配置随扩展退出删除（无头测速无 TUN，配置不会被内核长期需要）
    this.removePrivateConfig(false);
    try {
      await coreBridge.stopCore();
    } catch (e) {
      AppLogger.warn(TAG, 'core cleanup failed');
    }
    if (connection !== null) {
      try {
        await connection.destroy();
      } catch (e) {
        AppLogger.warn(TAG, 'VPN connection cleanup failed');
      }
    }
    // 连续任务归属 QuickToggleAbility（UIAbility 上下文），扩展侧无任务可注销。
  }

  async onCreate(want: Want): Promise<void> {
    if (this.cleanupPromise !== null) { await this.cleanupPromise; }
    this.stopped = false;
    this.lifecycleGeneration++;
    AppLogger.info(TAG, 'vpn onCreate');
    // 扩展进程可能先于 UIAbility 被系统拉起：geo 数据在这里也要保证就位
    GeoDataInstaller.ensure(this.context as common.Context);
    this.writeLaunchEpoch();
    this.appRouting = new AppRoutingRuntime();
    this.tunConfig = null;
    // 真机实证（2026-09-18）：backgroundTaskManager 只接受 UIAbility 上下文，在扩展
    // 进程申请连续任务必然 401 —— 旧代码在此空转失败并留下误导性日志。会话驻留
    // 改由 QuickToggleAbility 的 dataTransfer 守护（卡片/快捷方式/手动连接路径共有）。

    const params = want.parameters;
    let headless = (params !== undefined && params !== null)
      && ((params['headless'] as number) === 1);
    let configPath = (params !== undefined && params !== null) ? (params['configPath'] as string) : '';
    if (configPath === undefined || configPath.length === 0) {
      // 自愈：系统冷启动扩展时 want.parameters 可能整体丢失（实测偶发，
      // 表现为 configPath/headless 全空 → 走隧道分支建 TUN → 因找不到配置失败）。
      // 按 mtime 消歧恢复意图：测速配置较新 → headless；隧道配置存在 → 隧道。
      const cacheDir = this.context.cacheDir;
      const testCfg = `${cacheDir}/mihomo_test_config.yaml`;
      const tunCfg = `${cacheDir}/mihomo_config.yaml`;
      let testMtime = -1;
      let tunMtime = -1;
      try {
        testMtime = fs.statSync(testCfg).mtime;
      } catch (e) {
        testMtime = -1;
      }
      try {
        tunMtime = fs.statSync(tunCfg).mtime;
      } catch (e) {
        tunMtime = -1;
      }
      if (testMtime >= tunMtime && testMtime > 0) {
        configPath = testCfg;
        headless = true;
        AppLogger.warn(TAG, 'config params lost; recovered headless test config by mtime');
      } else if (tunMtime > 0) {
        configPath = tunCfg;
        AppLogger.warn(TAG, 'config params lost; recovered tunnel config by mtime');
      } else {
        configPath = tunCfg;
        AppLogger.warn(TAG, 'config path missing; using cache configuration');
      }
    }
    this.configPathForCleanup = configPath;
    this.configIsTransient = TunBoxVpnExtension.isTransientConfig(configPath);
    this.clearStartError(configPath);

    // 重入防护：Core 仍可能使用旧 TUN fd，必须先同步停止 Core，再销毁平台连接。
    // 反向顺序会让 fd 号在 Core 清理前被系统复用，形成误关新 fd 的竞态。
    try {
      await coreBridge.stopCore();
    } catch (e) {
      // 未启动过时停止属正常
    }
    const previousConnection = this.connection;
    this.connection = null;
    this.platformTunFd = -1;
    if (previousConnection !== null) {
      try {
        await previousConnection.destroy();
      } catch (e) {
        // 旧连接可能已失效，忽略
      }
    }

    // headless 测速模式(UI 预启动内核做真实协议测速): 不建 TUN、不请求 VPN
    // 授权、不启 protect/心跳 —— 只拉起内核开 127.0.0.1 的 mixed+API 端口。
    // (headless 已在 onCreate 顶部随 configPath 一并解析, 含参数丢失时的 mtime 自愈)
    if (headless) {
      this.runHeadless(configPath);
      return;
    }

    // 即使 configPath 由 mtime 恢复，应用分流参数也必须完整，不能从缓存猜测 all。
    // want 有效 → 直接用；want 丢参 → 唯一合法来源是 UI 每次拉起前重写的参数
    // 回退文件（configPath 逐字匹配 + ≤3 分钟新鲜度）；两者皆无 → 维持拒绝。
    try {
      let mode: string = '';
      let packagesJson: string = '';
      let needsReview: boolean = false;
      let gateOk: boolean = false;
      if (params !== undefined && params !== null) {
        if (typeof params['appRoutingMode'] === 'string' &&
          typeof params['appRoutingNeedsReview'] === 'boolean' &&
          typeof params['appRoutingPackagesJson'] === 'string' &&
          params['bypassPackages'] === undefined && params['proxyPackages'] === undefined) {
          mode = params['appRoutingMode'] as string;
          packagesJson = params['appRoutingPackagesJson'] as string;
          needsReview = params['appRoutingNeedsReview'] as boolean;
          gateOk = true;
        }
      }
      if (!gateOk) {
        const recovered = await this.readStartParamsFallback(configPath);
        if (recovered === null) {
          throw new Error('应用分流参数缺失或冲突，已拒绝恢复 VPN，请在应用内重新连接');
        }
        mode = recovered.mode;
        packagesJson = recovered.packagesJson;
        needsReview = recovered.needsReview;
      }
      this.appRouting = AppRoutingPolicy.fromTransport(mode, packagesJson, needsReview);
    } catch (e) {
      const message = AppLogger.errText(e);
      this.reportStartError(configPath, message);
      AppLogger.error(TAG, message);
      await this.cleanupResources();
      return;
    }

    // 建立 Extension 进程内的网络权威：在任何 TUN 参数计算之前读取当前物理承载，
    // 使 MTU、Kill Switch 与恢复编排完全由本进程掌控，UI 进程被回收也不受影响。
    this.startNetworkAuthority();

    // TUN 参数既要跟「设置页 IPv6 开关」一致，又要跟**内核实际加载的那份 YAML**一致。
    // YAML 是唯一真源（readTunFlagsFromConfig），所以这里不再从 want 收开关。
    // MTU 按当前物理承载动态取值（蜂窝链路降低分片风险，Wi-Fi/以太网 1400）。
    this.activeMtu = this.mtuForNetwork(this.lastNetworkType);
    const tunFlags = this.readTunFlagsFromConfig(configPath);
    // DNS 接管：与 YAML 的 `dns.enable` 同源（readTunFlagsFromConfig 读回）。
    // 开 ⇒ 设备 DNS 指向 TUN sentinel，53 被 tun.dns-hijack 送进内核解析；
    // 关 ⇒ **不下发** dnsAddresses（undefined = 字段省略），系统沿用物理网络 DNS ——
    // 与生成器不写 dns-hijack 严格配套，否则就是「劫持到没人应答的内核」黑洞。
    const dnsAddresses: string[] | undefined = tunFlags.dnsOverride ? DNS_SERVERS : undefined;
    // 路由表：v4 默认 + （双栈时）v6 默认，见 buildTunRoutes。
    const tunRoutes: vpnExtension.RouteInfo[] = this.buildTunRoutes(tunFlags);
    const config: vpnExtension.VpnConfig = tunFlags.ipv6 ? {
      addresses: [{
        address: { address: TUN_ADDRESS, family: 1 },
        prefixLength: TUN_PREFIX
      }, {
        address: { address: TUN_ADDRESS_V6, family: 2 },
        prefixLength: TUN_PREFIX_V6
      }],
      routes: tunRoutes,
      dnsAddresses: dnsAddresses,
      mtu: this.activeMtu,
      isIPv4Accepted: true,
      isIPv6Accepted: true
    } : {
      addresses: [{
        address: { address: TUN_ADDRESS, family: 1 },
        prefixLength: TUN_PREFIX
      }],
      routes: tunRoutes,
      dnsAddresses: dnsAddresses,
      mtu: this.activeMtu,
      isIPv4Accepted: true,
      isIPv6Accepted: false
    };
    this.tunConfig = config;
    AppLogger.info(TAG, `vpn config: ${tunFlags.ipv6 ? 'dual-stack' : 'ipv4-only'}, `
      + `dns=${tunFlags.dnsOverride ? DNS_SERVERS.join(',') : 'off'}, routes=${tunRoutes.length}, `
      + `mtu=${this.activeMtu}, net=${this.lastNetworkType}`);

    try {
      this.applyAppRouting(config);
      this.connection = vpnExtension.createVpnConnection(this.context);
      const tunFd = await this.connection.create(config);
      this.platformTunFd = tunFd;
      AppLogger.info(TAG, 'TUN created');

      // 同时启用进程级保护与逐 socket Protect 通道，避免出站流量回灌 TUN。
      await this.connection.protectProcessNet();
      AppLogger.info(TAG, 'protectProcessNet enabled');

      const attached = await coreBridge.attachTun(tunFd, this.activeMtu);
      if (!attached) {
        throw new Error('内核桥加载失败（attachTun）');
      }
      AppLogger.info(TAG, 'attachTun ok');
      const protectReady = await coreBridge.initProtect();
      if (!protectReady) {
        throw new Error('内核 Protect 通道初始化失败');
      }
      AppLogger.info(TAG, 'initProtect ok');
      this.startProtectMonitor();

      // 内核 gvisor 的 MTU 必须与 VpnConfig.mtu 一致：启动前把配置里的 tun.mtu 对齐。
      this.ensureConfigMtu();
      // startCore 在线程池执行，ArkTS 事件循环持续处理 Protect 请求。
      const ok = await this.startCoreWithTimeout(configPath);
      AppLogger.info(TAG, `core start result: ${ok}`);
      if (!ok) {
        const coreErr = await coreBridge.lastError();
        throw new Error(coreErr.length > 0 ? coreErr : '内核启动失败（未知原因）');
      }
      this.reportStartOk(configPath);
      this.publishStateSnapshot(configPath);
      this.startCoreMonitor();
    } catch (e) {
      const msg = AppLogger.errText(e);
      const err = e as BusinessError;
      const code = typeof err.code === 'number' ? err.code : -1;
      this.reportStartError(configPath, friendlyVpnStartError(code, msg));
      AppLogger.error(TAG, `vpn onCreate failed: code=${code} msg=${msg}`);
      // 启动失败即为本次会话终结：删掉含 API secret 的配置，避免凭据滞留磁盘
      this.removePrivateConfig(true);
      await this.cleanupResources();
    }
  }

  /** headless 测速内核: 仅 startCore + 回写启动结果标记, 失败走同一错误通道 */
  private async runHeadless(configPath: string): Promise<void> {
    try {
      AppLogger.info(TAG, 'headless test-core starting (no TUN / no VPN permission)');
      // 测速核同样可能被"启动期联网下载"卡住：这里也加硬超时，避免 20s 就绪窗口内
      // 只能报"就绪超时"而看不到真实原因（真机实证：全新安装 ruleset 缺失）。
      const outcome = await this.runStage('headless startCore', coreBridge.startCore(configPath),
        CORE_START_TIMEOUT_MS);
      if (outcome.timedOut) {
        throw new Error('测速内核启动超时（20s 无响应）：配置引用的远程规则集缺失导致内核联网下载阻塞');
      }
      if (!outcome.ok) {
        const coreErr = await coreBridge.lastError();
        throw new Error(coreErr.length > 0 ? coreErr : 'headless 内核启动失败');
      }
      this.reportStartOk(configPath);
      AppLogger.info(TAG, 'headless test-core started');
    } catch (e) {
      const msg = AppLogger.errText(e);
      this.reportStartError(configPath, `测速内核启动失败: ${msg}`);
      AppLogger.error(TAG, `headless start failed: ${msg}`);
      // 失败路径清理测速配置，但**保留** START_ERROR_FILE：reportStartError 刚把真实
      // 原因写进去给 UI 轮询读（UI 步长 ≥40ms），同 tick 删掉等于错误通道失效，
      // UI 只能白等 20s 报通用超时。错误文件由 UI 侧消费或下次启动覆盖，不含凭据。
      this.removePrivateConfig(true);
      await this.cleanupResources();
    }
  }

  /**
   * 内存压力自适应降级（P2，对标 iOS 50MB 上限的 oomKiller 自救）：
   * - MEMORY_LEVEL_MODERATE：记日志（观察点，不动隧道）；
   * - MEMORY_LEVEL_CRITICAL：写 warn 日志 + 经 writeStatus 把 memCritical 信号
   *   推到 UI 进程（detail 通道），UI 侧据此提示用户。不在扩展内主动断连接：
   *   mihomo 自带 gvisor 内存回收，主动断栈的收益 < 恢复成本。
   */
  onMemoryLevel(level: number): void {
    if (level === AbilityConstant.MemoryLevel.MEMORY_LEVEL_CRITICAL) {
      AppLogger.warn(TAG, 'memory pressure CRITICAL in vpn extension; notifying UI');
      this.writeStatus(this.connection !== null ? 'recovering' : 'failed',
        this.connection !== null, 'memCritical: 内存压力临界，隧道可能被系统回收');
    } else if (level === AbilityConstant.MemoryLevel.MEMORY_LEVEL_MODERATE) {
      AppLogger.info(TAG, 'memory pressure MODERATE in vpn extension');
    }
  }

  onDestroy(): void {
    AppLogger.info(TAG, 'vpn onDestroy');
    this.cleanupResources().catch((e: Error) => {
      AppLogger.warn(TAG, `vpn onDestroy cleanup failed: ${AppLogger.errText(e)}`);
    });
  }
}
