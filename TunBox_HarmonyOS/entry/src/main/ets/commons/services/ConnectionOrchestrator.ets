/**
 * 连接编排器：管理连接状态机、VPN 能力拉起、Clash API 就绪等待
 * 移植自 upstream: TunBox_Android/lib/services/connection_orchestrator.dart
 *                packages/tunbox_shared/lib/utils/connection_intent_tracker.dart
 *                connection_transition_queue.dart / core_recovery_policy.dart
 *
 * 链路（API 26 实测形态）：
 *   connect() → 写 Mihomo YAML 到 cacheDir → startVpnExtensionAbility(want.parameters.configPath)
 *   → VpnExtensionAbility：create() 得到 TUN fd → coreBridge.attachTun + startCore
 *   → 本编排器轮询 Clash API 就绪 → selectNode → CONNECTED
 */
import { vpnExtension, http, webSocket, socket, connection } from '@kit.NetworkKit';
import { UnifiedScheduler } from './UnifiedScheduler';
import type Want from '@ohos.app.ability.Want';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { notificationManager } from '@kit.NotificationKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { coreBridge } from '../../core/CoreBridge';
import { ClashApiService, KernelGroupSelection, TrafficSnapshot } from './ClashApiService';
import { KernelSelectionManager } from './KernelSelectionManager';
import { ConnectionEvents, ConnEvent, ConnListener, ReconnectReason } from './ConnectionEvents';
import { ConnectionTarget, ConnectionTargetSource, RuntimeConfigBuilder, RuntimeConfigMode, RuntimeConfigProfile } from '../config/RuntimeConfigBuilder';
import { ClashConfigGenerator } from './ClashConfigGenerator';
import { ConfigValidator } from './ConfigValidator';
import { DoHResolver } from './DoHResolver';

import { SubscriptionService } from './SubscriptionService';
import { SubscriptionRefreshStatus, SubscriptionRefreshResult } from '../models/Subscription';
import { SettingsService, ConnectionSnapshot, AppRoutingSnapshot } from './SettingsService';
import { TunBoxNotifier } from './TunBoxNotifier';
import { TaskProgressUpdater } from './TaskProgressUpdater';
import { TunnelAuthorityState, resolveAuthority, parseExtensionStatus, ExtensionStatusView, deriveUiPhase } from './TunnelAuthority';
import {
  MAX_STATE_FILE_BYTES, PRIVATE_TEST_CONFIG_FILE,
  SyncReadResult, clearPrivateArtifacts, heartbeatAgeFromText
} from './RuntimeFilePolicy';
import { chmodPrivate, ensurePrivateDir, privateFs } from './PrivateFileStore';
import { ConnState } from './connection/ConnState';
import { ConnectionStateMachine } from './connection/ConnectionStateMachine';
import { ConnectionAttempt, ConnectionAttemptClock } from './connection/ConnectionAttempt';
import {
  ReconnectAttemptOutcome, ReconnectHost, ReconnectManager, ReconnectRuntimeState, ReconnectTelemetry
} from './connection/ReconnectManager';

import { SingleFlightTestCore, TestCoreStatus } from './TestCoreFlight';
import { NetworkStateWatcher, NetworkStateListener, NetTypes } from './NetworkStateWatcher';
import {
  LinkHealthReport, LinkHealthSummary, runLinkHealthCheck, summarize, repairSteps, RepairActions
} from './LinkHealthChecker';
import { OrchestratorHealthProbes, OrchestratorHealthView } from './OrchestratorHealthProbes';
import { NodeSortSnapshot, NodeLatencyRecord } from './NodeSortPersistence';
import {
  NodeCandidate, SelectorOptions, nextBestNode, failoverAllowed, LATENCY_UNTESTED, LATENCY_FAILED
} from './SmartSelector';
import { AppSettings, AutoSelectModes } from '../models/AppSettings';
import { AppRoutingPolicy, AppRoutingRuntime } from './AppRoutingPolicy';
import { ProxyNode } from '../models/ProxyNode';
import { AppDiagnostics } from '../models/PublicIpInfo';
import { AppProxyRoute } from './AppProxyRoute';
import { AppLogger } from '../utils/AppLogger';
// FlClash 同构：当前 Profile 原文（配置基底）
import { ProfileRepository } from '../flclash/ProfileRepository';
import { CoreCatalogService } from '../flclash/CoreCatalogService';
import { CoreNodeBridge } from '../flclash/CoreNodeBridge';

// 状态枚举已抽到零依赖叶子模块（避免 stateMachine ↔ orchestrator 循环依赖）；
// 这里再导出，保持既有 `import { ConnState } from '.../ConnectionOrchestrator'` 不变。
export { ConnState };
// 重连运行态快照已随 ReconnectManager 迁到 connection/（Phase 3）；同样再导出，
// 保证 `import { ReconnectRuntimeState } from '.../ConnectionOrchestrator'` 的调用点不改。
export { ReconnectRuntimeState, ReconnectTelemetry };

const TAG = 'ConnectionOrchestrator';
const MIXED_PORT = 7890;
const API_PORT = 9090;
const DNS_LISTEN_PORT = 1053;
/**
 * 端口候选组（用户真机实证 2026-09-18）：NekoBox/v2rayNG 等 mihomo 系 VPN 默认
 * 同样占用 9090/7890/1053，任一被占都会导致内核 controller bind 失败 → 看似"无法启动"。
 * 三组候选依次 TCP 探测，全部空闲才采用；组间错开 10000，避免与常见服务冲突。
 */
const PORT_CANDIDATE_SETS: number[][] = [
  [9090, 7890, 1053],
  [19090, 17890, 11053],
  [29090, 27890, 21053]
];
const CONFIG_FILE = 'mihomo_config.yaml';
/**
 * 最后一份「内核真的连上过」的配置快照。
 *
 * 设备侧没有可以单独跑 `-t` 的内核（core 只对外暴露 controller 通道），
 * 所以冷启动**无法**在写盘前预校验。冷启动改用等价保证：
 *   连上成功 → 快照；下次被内核拒载（parse config）→ 自动回滚到快照。
 * 效果与 FlClash 的「校验通过才替换」一致：坏配置永不永久顶掉能用的配置。
 */
const LAST_GOOD_CONFIG_FILE = 'mihomo_config.lastgood.yaml';
/** 内核 home 下的规则集子目录（config 里写作 ./ruleset/xxx.mrs） */
const RULESET_SUBDIR = 'ruleset';
/** 去广告规则集（rule-providers: hyper-adrules, type: http） */
const HYPER_AD_RULES_FILE = 'hyper_adrules_ads.mrs';
/**
 * 去广告 MRS 体积下限（byte）。真源数 MB；这里只兜「空文件/半截下载」，
 * 真正的格式判据是下面的 zstd 魔数（错误页也常大于 1KB，只查体积挡不住）。
 */
const RULE_SET_MIN_BYTES = 1024;
/**
 * MRS 的落盘形态是 **zstd frame**（内层才是 `MRS\x01 | behavior | count …`，
 * 见 mihomo `rules/provider/mrs_converter.go`），所以合法 .mrs 的前 4 字节必为
 * zstd 魔数 0x28 0xB5 0x2F 0xFD。用它把 GitHub 加速代理返回的 HTML/JSON 错误页挡住。
 */
const ZSTD_MAGIC: number[] = [0x28, 0xB5, 0x2F, 0xFD];
/**
 * 「上一次连接成功时那份规则集」的副本后缀：内核能成功加载 = 文件与当前配置的
 * behavior/format 匹配。之后更新到坏文件导致启动失败时，用它回滚（见 healRuleSet）。
 */
const RULE_SET_GOOD_SUFFIX = '.good';
/**
 * 随包内置的去广告规则集（`entry/src/main/resources/rawfile/` 下的名字）。
 *
 * 2026-10-23 用户口径：规则集不再作为「数据」页里的可更新资产暴露，安装包自带一份，
 * 去广告开关打开即可用；需要更新时后台自动拉取覆盖（见 downloadRuleProviderInBackground）。
 */
const BUNDLED_RULE_SET_RAWFILE = 'hyper_adrules_ads.mrs';
/**
 * geo 资产候选镜像。tag 标记来源类型，供按用户偏好（assetSource）重排：
 * jsdelivr=CDN / ghproxy=加速前缀 / github=官方直链。auto 偏好 = 保持实测可达性排序。
 */
class AssetMirror {
  url: string = '';
  tag: string = 'auto';

  constructor(url: string, tag: string) {
    this.url = url;
    this.tag = tag;
  }
}

/** geoip.metadb 候选源（jsdelivr 取仓库 release 分支直链可用；release asset 才走前缀代理） */
const GEOIP_MIRRORS: AssetMirror[] = [
  new AssetMirror('https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb', 'jsdelivr'),
  new AssetMirror('https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb', 'jsdelivr'),
  new AssetMirror('https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb', 'jsdelivr'),
  new AssetMirror('https://gh-proxy.com/https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geoip.metadb', 'ghproxy'),
  new AssetMirror('https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geoip.metadb', 'github')
];
/** LightGBM Model.bin（release asset：jsdelivr 不可用，实测仅前缀代理可达但限速） */
const MODEL_MIRRORS: AssetMirror[] = [
  new AssetMirror('https://gh-proxy.com/https://github.com/vernesong/mihomo/releases/download/LightGBM-Model/Model.bin', 'ghproxy'),
  new AssetMirror('https://ghproxy.net/https://github.com/vernesong/mihomo/releases/download/LightGBM-Model/Model.bin', 'ghproxy'),
  new AssetMirror('https://github.com/vernesong/mihomo/releases/download/LightGBM-Model/Model.bin', 'github')
];
/**
 * 去广告规则集下载源。注意：这是 GitHub **release 资产**，jsdelivr 的 gh 通道
 * 不覆盖 release asset，因此官方直链 + 通用 GitHub 加速前置代理依次回退。
 */
const HYPER_AD_RULES_MIRRORS: AssetMirror[] = [
  new AssetMirror('https://github.com/Lynricsy/HyperADRules/releases/latest/download/hyper_adrules_ads.mrs', 'github'),
  new AssetMirror('https://gh-proxy.com/https://github.com/Lynricsy/HyperADRules/releases/latest/download/hyper_adrules_ads.mrs', 'ghproxy'),
  new AssetMirror('https://ghfast.top/https://github.com/Lynricsy/HyperADRules/releases/latest/download/hyper_adrules_ads.mrs', 'ghproxy')
];

/** geo 资产状态（设置页「数据与规则」展示用） */
export class GeoAssetStatus {
  /** geoip | model | ruleset */
  id: string = '';
  /** 展示名 */
  label: string = '';
  /** 用途说明 */
  detail: string = '';
  ready: boolean = false;
  sizeBytes: number = 0;
  mtimeMs: number = 0;
}

/** 按用户偏好重排镜像：偏好 tag 提前（保持相对顺序），auto/未知 = 原序 */
function reorderAssetMirrors(mirrors: AssetMirror[], source: string): AssetMirror[] {
  if (source !== 'jsdelivr' && source !== 'ghproxy' && source !== 'github') {
    return mirrors.slice();
  }
  const preferred = mirrors.filter((m: AssetMirror): boolean => m.tag === source);
  const rest = mirrors.filter((m: AssetMirror): boolean => m.tag !== source);
  return preferred.concat(rest);
}
const START_ERROR_FILE = 'vpn_start_error.txt';
const START_OK_FILE = 'vpn_start_ok.txt';
/** 本次拉起的路由参数快照（扩展进程在 want 被系统丢弃时回退读取，见 VpnExtensionAbility） */
const START_PARAMS_FILE = 'vpn_start_params.json';
/** 扩展进程 onCreate 送达标记（识别被系统吞并的 start；与扩展侧常量同名同值） */
const LAUNCH_EPOCH_FILE = 'vpn_launch_epoch.txt';
/** 拉起后等待 onCreate epoch 出现的窗口（ms）；超时按"start 被吞"重发一次 */
const LAUNCH_EPOCH_WAIT_MS = 5000;
/**
 * epoch 轮询步长（ms）。扩展进程把 writeLaunchEpoch 作为 onCreate 的第一条语句，
 * 所以正常情况下标记几乎立刻出现 —— 步长直接等于"每次成功连接白白多付的等待上限"。
 * 原为 250ms，这里降到 30ms：文件只有十几字节，readCapped 开销可忽略，
 * 而 5s 窗口内的轮询次数（约 170 次）依然远低于系统调度噪声。
 */
const LAUNCH_EPOCH_POLL_MS = 30;
/** Extension 主导的权威运行态文件（事件驱动写入）。 */
const EXTENSION_STATUS_FILE = 'vpn_status.json';
/** 扩展进程心跳文件（扩展侧每 5s 原子覆写时间戳） */
const HEARTBEAT_FILE = 'vpn_heartbeat.txt';
/** 存活租约的原子替换临时文件（与扩展侧同名同值，清理时一并删除） */
const HEARTBEAT_TMP_FILE = 'vpn_heartbeat.txt.tmp';
/**
 * 心跳超过该时长视为**扩展进程失联**（ms）。
 *
 * 2026-10-20 自动断开整改：心跳语义从「内核活着」收敛为「扩展进程还活着」——
 * 扩展侧改为 5s 独立定时器无条件刷新（见 VpnExtensionAbility.LEASE_REFRESH_MS），
 * 且不再在探针判死时删掉心跳文件。「内核是否活着」改由 vpn_status.json 的
 * coreAlive 字段表达。两个维度混成一个信号，正是假判死的源头。
 */
const HEARTBEAT_STALE_MS = 15000;
/**
 * 连续多少次「非存活」观测才升级为内核死亡并触发自愈。
 *
 * 观测分两档：
 *  - STALE / UNKNOWN 都必须先复探真实 controller，再跨至少 6s 连续确认 3 次。
 *    锁屏可能暂停 ArkTS 的租约定时器，而原生代理仍在转发；旧心跳不是死亡证明。
 */
const CORE_DEATH_CONFIRMATIONS = 3;
const CORE_LIVENESS_POLL_MS = 3000;
const CORE_DEATH_CONFIRM_MS = (CORE_DEATH_CONFIRMATIONS - 1) * CORE_LIVENESS_POLL_MS;
/**
 * 扩展侧恢复「卡死」阈值：recovering 相位下 status 文件 ts 停更超过该时长即视为
 * 恢复编排不再前进（有界预算耗尽后的终态）。须大于扩展最大恢复退避间隔。
 */
const CORE_RECOVERY_STUCK_MS = 90000;

/** 心跳观测的三态判定结果 */
enum LivenessVerdict {
  /** 心跳新鲜：扩展进程与隧道都在 */
  ALIVE = 0,
  /** 心跳过期：刷新方失联（强证据） */
  STALE = 1,
  /** 心跳读不到：文件缺失/空/损坏（弱证据，不等于已死） */
  UNKNOWN = 2
}
/** 同一状态同步周期内复用文件探针，避免 heartbeat/start-ok 被重复同步读取。 */
const STATE_PROBE_CACHE_MS = 120;
/**
 * API readiness 快速起步并有上限退避，总超时仍由调用方 deadline 决定。
 *
 * 2026-10-19 稳定性回退：上限 150ms → 300ms（回到 0.3.3 取值）。
 * 0.4.0 曾为提速砍到 150ms，收益是「内核已就绪但未被探测到」的滞后上限减半
 * （真机 100–500ms 级），但代价是连接成功判定整体提前，把「已连接」上屏与
 * 「节点钉选/首个请求可用」之间的窗口拉大 —— 见 connect() 里 selectNode 的
 * 恢复注释。稳定性优先，故退回 300ms；后续若再提速，必须与 selectNode 的
 * await 语义一起评估，不能单独改。
 */
const READINESS_INITIAL_DELAY_MS = 40;
const READINESS_MAX_DELAY_MS = 300;
/** Two-second traffic sampling reduces /connections allocations and UI redraws. */
const TRAFFIC_POLL_INTERVAL_MS = 2000;
/** 测速内核停扩展的重试次数与间隔：停失败必须重试，或至少让下次启动能正确重建 */
const TEST_CORE_STOP_ATTEMPTS = 2;
const TEST_CORE_STOP_RETRY_DELAY_MS = 300;
/** 测速内核启动失败后的负缓存冷却：避免每次测速都白等一次 15~20s 启动超时 */
const TEST_CORE_NEGATIVE_COOLDOWN_MS = 45000;
/**
 * 测速内核「预热」时长（毫秒）。
 *
 * 背景（真机取证 2026-10-17）：headless 内核 ready 后 controller API 仍是冷的
 * （首批连接/凭证初始化未完成），立刻放行整批并发会把 API 打到
 * Operation timeout（code=2300028，整批中止）。
 *
 * 口径（2026-10-20 整改）：这个窗口是**内核的属性**，不是调用方的固定等待。
 * 旧实现在 ensureLatencyApi 里无条件睡 1500ms —— **复用路径**（内核已经在服务）
 * 也要白等这 1.5s，这正是「点了测速，等几秒钟才开始测速」的直接来源之一。
 * 现在内核就绪时登记「预计变热时刻」（testCoreWarmAt），调用方只等到那一刻：
 * 复用路径窗口早已过去 → 一句都不等 → 秒开。
 */
const TEST_CORE_WARMUP_MS = 1000;
/**
 * 预热/测速内核的空闲回收窗口（毫秒）。
 *
 * 【2026-10-26 由 90s 放宽到 10 分钟】用户反馈「点了测速，要先『准备测速通道』
 * 好几秒才开始，别的客户端点下去就测」。真机时间线（冷通道）：点击 →
 * 读 profile 1.1MB + 合并生成配置 ~1.5s → 停旧扩展 600ms → 启扩展 ~165ms →
 * 就绪轮询 ~200ms → 预热窗口 1.0s ⇒ 约 3.5~5s 才有第一个探测。
 * 90s 的回收窗口意味着用户看完结果、翻两下页面再点一次，就要把这 5s 重付一遍。
 *
 * 代价：测速核（headless mihomo）在空闲期常驻（约 30~60MB 内存 + 一个回环端口）。
 * 这是「点下去立刻开测」必须付的成本 —— 三家桌面端内核本身就常驻，不存在
 * 「每次测速都冷启动一个内核」的行为。空闲回收仍在（不是永不回收），
 * 只是窗口改成与用户操作节奏同量级。
 */
const TEST_CORE_IDLE_RECYCLE_MS = 600000;

/** vpn_start_params.json 的落盘结构（键名与扩展侧 readStartParamsFallback 解析一致） */
class StartParamsRecord {
  public configPath: string = '';
  public appRoutingMode: string = '';
  public appRoutingNeedsReview: boolean = false;
  public appRoutingPackagesJson: string = '';
  public ts: number = 0;
}

export function nextReadinessDelayMs(currentMs: number): number {
  if (currentMs <= 0) {
    return READINESS_INITIAL_DELAY_MS;
  }
  return Math.min(currentMs * 2, READINESS_MAX_DELAY_MS);
}

/** 单个修复动作的执行结果（内部结构） */
class RepairOutcome {
  text: string = '';
  /** 是否执行了重建/重连 */
  usedReconnect: boolean = false;
  /** 是否应终止后续修复（需要用户介入） */
  stop: boolean = false;
}

/** 网络类型变化重建连的退避基准（ms）：1s/2s/4s/8s */
const RECONNECT_BASE_MS: number = 1000;
/** 退避上限（ms），可经 setReconnectBackoffMax 覆盖 */
const RECONNECT_MAX_MS: number = 8000;
/** 网络切换触发的最大重连尝试次数 */
const RECONNECT_MAX_ATTEMPTS: number = 3;

/**
 * 一次内核会话的端口三元组。
 *
 * 刻意做成**不可变输入**而不是共享可变字段：测速核与隧道核各自持有一份，
 * 互不写回（审计 F1：旧实现里测速核的端口探测会改写隧道核正在用的端口）。
 */
export class RuntimePorts {
  apiPort: number = 0;
  mixedPort: number = 0;
  dnsPort: number = 0;
}

/**
 * DoH 快照（节点域名 → 固定 IP + 本次尝试解析过的域名名单）。
 *
 * 测速侧靠它区分「域名无法解析」（在名单里、却没解析出 IP）与「没试过解析」（不在名单里）——
 * 后者必须记 unknown，不能误报成解析失败。
 */
export class LatencyHostSnapshot {
  /** 小写域名 → 固定 IP（没解析出来的域名不在表里）。 */
  pins: Record<string, string> = {};
  /** 本次**实际尝试过**解析的域名（小写）。 */
  attempted: string[] = [];
  /** 预解析**查到了地址**的域名（小写；含被丢弃的 ⇒ 不能误报失败）。 */
  resolved: string[] = [];
  /** 预解析**查了但没查到地址**的域名（小写）⇒ 真·解析失败。 */
  failed: string[] = [];
}

export class ConnectionOrchestrator implements NetworkStateListener, OrchestratorHealthView {
  /**
   * 进程级单例: 每个页面必须共享同一个 orchestrator 实例。
   * 此前各页面各 new 一个, 新实例 state 永远是 DISCONNECTED —— 切换页面时
   * 主页 onPageShow 误判"未连接"触发重连, 且 connect() 每次生成新 API secret,
   * 其他页面持有的旧 secret 全部 401(延迟测试"超时"的根因)。
   */
  private static shared: ConnectionOrchestrator | null = null;

  static instance(): ConnectionOrchestrator {
    if (ConnectionOrchestrator.shared === null) {
      ConnectionOrchestrator.shared = new ConnectionOrchestrator();
    }
    return ConnectionOrchestrator.shared;
  }

  /**
   * 内核即将停止（拆隧道 / 回收测速核）前的收尾钩子。
   *
   * 记账侧（TrafficStatsStore）在此注册：内核进程一停，它那份累计计数器就随之消失，
   * 尚未落盘的增量会永久丢失。用"注册表"而不是直接 import，是为了避免与
   * TrafficStatsStore 形成循环依赖（后者已 import 本类）。
   */
  static readonly preCoreStopHooks: (() => void)[] = [];

  /** 内核（含测速核）即将停止：先让记账侧把未落盘的增量补齐并落盘。 */
  private flushTrafficAccounting(): void {
    for (const hook of ConnectionOrchestrator.preCoreStopHooks) {
      try {
        hook();
      } catch (e) {
        AppLogger.warn(TAG, `traffic flush hook failed: ${AppLogger.errText(e)}`);
      }
    }
  }

  state: ConnState = ConnState.DISCONNECTED;
  traffic: TrafficSnapshot = { uploadBytes: 0, downloadBytes: 0, uploadSpeed: 0, downloadSpeed: 0 };
  /**
   * 内核**累计**流量（仅成功轮询时更新；失败/未连接时保持上一次值）。
   *
   * 为什么单列一份：记账（TrafficStatsStore）必须拿到"只增不减"的可信累计值。
   * `traffic` 在探测失败时会被清零（UI 语义），拿它做差分会把"探测失败"误判成
   * "内核归零"，既丢量也虚高。`-1` = 本进程尚未拿到任何有效样本。
   */
  coreTotalUp: number = -1;
  coreTotalDown: number = -1;
  publicIp: string = '';
  startedAt: number = 0;
  lastError: string = '';
  api: ClashApiService = new ClashApiService();
  /** 本次连接是否启用 IPv6 入站（连接时探测, 无 IPv6 环境自动绕过） */
  ipv6Active: boolean = false;
  private monitorTimer: number = -1;
  private trafficTimer: number = -1;
  /** Prevent overlapping requests when a traffic poll is slow. */
  private trafficPollRunning: boolean = false;
  private connectSeq: number = 0; // 进程内启动序列，仅用于取消同进程旧连接流程
  /**
   * 持久化 VPN 会话代次。每次用户连接或主动停止前递增并写入 ConnectionSnapshot；
   * 所有跨进程、延迟及异步结果必须校验此值，不能只依靠会随 UI 进程回收而丢失的 connectSeq。
   */
  private sessionGeneration: number = 0;
  /** 连接期间收到的断开意图。requestDisconnect 会立即使旧连接代际失效。 */
  private disconnectRequested: boolean = false;
  /** 重复 Form 事件复用同一停止 Promise，避免重复停止扩展和 native core。 */
  private disconnectTask: Promise<void> | null = null;
  /** 真实会话启停和热加载共用资源队列；恢复逻辑在事务释放后运行。 */
  private lifecycleWrites: Promise<void> = Promise.resolve();
  private failedConnectSeq: number = -1;
  private context: Context | null = null;
  private apiSecret: string = '';
  private stateProbeCachedAt: number = 0;
  private stateProbeStartOk: boolean = false;
  private stateProbeHeartbeatAge: number = -1;
  private lastSubs: SubscriptionService | null = null;
  private lastNode: ProxyNode | null = null;
  /**
   * 当前出口的**单一事实源**（已拆为独立管理器，2026-10-27 架构收口）。
   * UI/日志/快照只读它，禁止再各自用 preferredNode* 推出「当前节点」。
   */
  private kernelSelection: KernelSelectionManager = new KernelSelectionManager();
  /** 内核出口轮询节拍计数（每 N 次流量轮询对齐一次内核）。 */
  private exitPollTick: number = 0;
  /** 后台订阅刷新互斥（连接路径不再等待它）。 */
  private backgroundRefreshRunning: boolean = false;
  /**
   * 本次查询是否已经为「零节点」自动拉取过一次订阅。
   *
   * 全新安装的用户进应用就点连接：订阅已添加但从未拉取成功 → nodes 为空。
   * 旧实现对此毫无拦截，照样拉起 VPN 扩展，交出一份 1861 字节的空壳配置，
   * 内核 20s 不响应后报「规则集缺失请重试」——把用户引向完全错误的方向
   * （见 docs/first-connect-empty-nodes-rootcause.md）。
   * 这里自动补一次拉取；只补一次，避免无网时反复拉取把连接流程拖死。
   */
  private zeroNodeAutoRefreshDone: boolean = false;
  /** 上次连接写入配置的 DoH pin 结果 + GEOIP 判定，供热重载复用（避免重建隧道）。 */
  private lastProxyHosts: Record<string, string> = {};
  /**
   * 本次 DoH 预解析**实际尝试过**的域名名单（小写）。
   *
   * 测速侧要靠它区分「解析失败」与「根本没试过」：只有**在名单里**且没解析出 IP 的
   * 域名才算「域名无法解析」；不在名单里的一律记 unknown（不能误报）。
   */
  private lastProxyHostAttempted: string[] = [];
  /**
   * 本次预解析**查到了地址**的域名（小写）。
   *
   * 为什么单独存：`pins` 只含**被 pin 住**（写进 hosts）的域名；
   * 「查到了但因易变/劫持嫌疑被丢弃」的域名不在 pins 里，却**确实解析成功** ⇒
   * 只看 pins 会把它误判成「解析失败」。
   */
  private lastProxyHostResolved: string[] = [];
  /**
   * 本次预解析**查了但没查到地址**的域名（小写）⇒ 真·解析失败。
   *
   * 这是「域名下线」的唯一可靠判据：只有**真的查过**且失败才算；
   * 「没查过」（短 TTL 故意不 pin）绝不能算失败。
   */
  private lastProxyHostFailed: string[] = [];
  private lastGeoipReady: boolean = false;
  /** 上次连接是否启用了内核 smart 组（热重载复用同一决策，避免两次生成不一致） */
  private lastSmartModelReady: boolean = false;
  /** 去广告规则集文件是否已就绪（事实位；是否声明由 builder 统一决策）。 */
  private lastRuleProviderFileReady: boolean = false;
  /**
   * 真实隧道当前配置所对应的**节点集指纹**（'' = 未登记）。
   * 隧道配置同样只在连接那一刻生成一次；订阅集合变了之后隧道里就缺新节点，
   * 新节点不在内核代理表 → 测速 404 → UI「未生效」。测速取通道前用它判断
   * 隧道配置是否过期（过期就热重载，不拆隧道）。
   */
  private tunnelConfigFingerprint: string = '';
  /** 本次会话实际启用的 mihomo 端口（reservePorts 探测后更新；热重载必须复用，禁止重选）。 */
  private apiPort: number = API_PORT;
  private mixedPort: number = MIXED_PORT;
  private dnsPort: number = DNS_LISTEN_PORT;
  /** 规则/站点等变更触发的热重载在途门控（防并发重载）。 */
  private reloading: boolean = false;
  /**
   * 最近一次**生成配置时**使用的 profile id（FlClash 的「已生效 profile」）。
   *
   * 内核只有一份配置；订阅切换/刷新后若这里与 `ProfileRepository.currentId()` 不一致，
   * 说明内核里还是旧订阅的节点 —— 此时`/proxies`读到的是旧集合，
   * 测速就会出现「测的是 A 订阅、界面显示 B 订阅 → 全是 --」。
   */
  private appliedProfileId: string = '';
  /** 最近一次**生成**配置用的 profile id（还没被内核确认）。 */
  private pendingProfileId: string = '';
  private pendingProfileRevision: string = '';
  private appliedProfileRevision: string = '';
  private recoveryAttempts: number = 0; // 内核恢复退避计数（对应 core_recovery_policy）
  private lastNodeName: string = '';

  // ── 第二阶段：网络切换感知 → 退避智能重连 ──────────────────────────
  private netWatcher: NetworkStateWatcher | null = null;
  /** 上一次已上报的网络类型（'' = 尚未建立基线） */
  private lastNetType: string = '';
  /** 上一次处理过的网络事件代数（防重复处理） */
  private lastNetGeneration: number = -1;
  private reconnects: ReconnectManager | null = null;

  /**
   * 连接事务时钟（2026-10-27 P0）。
   * `connectSeq` 仍管请求排队；这里管「单次连接事务是否还有效」，
   * 每个长 await 之后统一 checkpoint，旧事务不得再写状态/设置/出口。
   */
  private readonly attempts: ConnectionAttemptClock = new ConnectionAttemptClock();
  /** 最近一次用户主动断开的时间（诊断用；不影响判断，判断看 disconnectRequested）。 */
  private lastUserDisconnectAt: number = 0;

  // ── 第二阶段：链路自检 → 有限自动修复 ──────────────────────────────
  private healthReport: LinkHealthReport | null = null;
  private healthSummaryCache: LinkHealthSummary | null = null;
  private healthRepairCache: string[] = [];
  private healthRunning: boolean = false;
  private coreLossHandling: boolean = false;
  /** 连续「非存活」观测票数（累计到 CORE_DEATH_CONFIRMATIONS 才升级为内核死亡）。 */
  private coreDeathStrikes: number = 0;
  private coreDeathFirstAt: number = 0;
  private coreDeathLastAt: number = 0;
  /**
   * 「心跳新鲜但内核已死」（终态黑洞）观测票（2026-10-24 P1 修复，独立于上面的
   * 心跳死亡三票）：扩展侧恢复预算（3 热恢复 + 2 重建）耗尽后 scheduleCoreRecovery/
   * scheduleTunnelRebuild 静默 no-op，TUN 因 Kill Switch 保留、租约定时器照刷 ——
   * UI 停在 CONNECTED、流量黑洞、健康自检永不触发（它只由心跳丢失唤醒）。
   * 凭 vpn_status.json 的 coreAlive=false + 本地 API 探针确认后，走既有 handleCoreLoss
   * 自愈（disconnect+connect），把黑洞变成可恢复。
   */
  private coreDownStrikes: number = 0;
  private coreDownFirstAt: number = 0;
  private coreDownLastAt: number = 0;
  private monitorGeneration: number = 0;
  private livenessPollRunning: boolean = false;
  private inRepairConnect: boolean = false;

  // ── 第二阶段：连续失败 → 自动切换节点 ──────────────────────────────
  private failoverRunning: boolean = false;
  private lastFailoverAt: number = 0;
  private lastFailoverFrom: string = '';
  private lastFailoverTo: string = '';
  private autoSwitchReasonText: string = '';

  listeners: (() => void)[] = [];
  addListener(listener: () => void): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  removeListener(listener: () => void): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  notify(): void {
    for (const l of this.listeners) {
      l();
    }
  }

  init(context: Context): void {
    this.context = context;
    this.invalidateStateProbeCache();
    // 第二阶段集成点①：进程级启动网络状态监听（幂等，失败静默降级）
    this.startNetworkWatch();
    // 节点集变化 → 作废测速核（幂等注册：同一回调只入队一次）
    SubscriptionService.onNodeSetChanged((reason: string): void => {
      this.onSubscriptionNodeSetChanged(reason);
    });
  }

  /**
   * 订阅集合变化后的测速核处置。
   *
   * 内核里的 mihomo 配置**只在启动那一刻**按当时的节点集生成一次；订阅导入/
   * 刷新/增删之后它就与当前节点集脱节 —— 新节点不在内核代理表里，/delay 404，
   * UI 整屏显示「未生效」（真机 2026-10-20：用户导入新订阅后测速全屏未生效，
   * 而 /version 探活照样通过 —— 「活着的内核」不等于「配置是新的」）。
   *
   * 这里做两件事：作废（下次取通道按新节点集重建）+ 后台预热（用户下一次点
   * 测速时内核既热又新，不必等一次冷启动）。真实隧道在场时一律不动：测速核
   * 与真实隧道共用同一个扩展进程，停它等于停用户的 VPN。
   */
  private onSubscriptionNodeSetChanged(reason: string): void {
    if (this.state === ConnState.CONNECTED || this.state === ConnState.CONNECTING) {
      // 真实隧道在场：测速复用隧道 controller，隧道配置的新鲜度由
      // ensureTunnelConfigFresh() 在取通道时判定（必要时热重载，不拆隧道）。
      return;
    }
    this.invalidateTestCoreForSubscriptionChange(reason)
      .then((): void => {
        this.prewarmLatencyChannel().catch((): void => {});
      })
      .catch((): void => {});
  }

  requestDisconnect(): void {
    this.invalidateStateProbeCache();
    this.disconnectRequested = true;
    this.lastUserDisconnectAt = Date.now();
    this.connectSeq = this.connectSeq + 1;
    this.testCoreLaunchGeneration++;
    // 用户主动断开 → 作废进行中的连接事务（旧事务的所有 await 之后都会被拒）。
    this.attempts.cancelCurrent();
    // 用户主动断开 → 取消一切挂起的退避重连并复位预算（禁止重连风暴）
    this.reconnectManager().resetAttempts();
    this.reconnectManager().cancel('user-disconnect');
  }

  /**
   * 原子推进持久化会话代次并写入用户意图。调用方必须在启动或停止 Extension 前 await。
   * Preferences 本身串行落盘；本进程再保存返回的 generation，供后续异步结果门控。
   */
  private async advanceSessionIntent(desiredConnected: boolean, phase: string,
    nodeName: string, startedAt: number): Promise<number> {
    const previous = await SettingsService.loadSnapshot();
    const next = new ConnectionSnapshot();
    next.desiredConnected = desiredConnected;
    next.phase = phase;
    next.sessionGeneration = previous.sessionGeneration + 1;
    next.nodeName = nodeName;
    next.savedAt = Date.now();
    next.startedAt = startedAt;
    await SettingsService.saveSnapshot(next);
    this.sessionGeneration = next.sessionGeneration;
    return next.sessionGeneration;
  }

  /** 仅当持久化用户意图和会话代次仍属于本次连接时，异步结果才允许提交。 */
  private async isCurrentSession(generation: number, requireConnectedIntent: boolean = true): Promise<boolean> {
    try {
      const snap = await SettingsService.loadSnapshot();
      if (snap.sessionGeneration !== generation) {
        return false;
      }
      return !requireConnectedIntent || snap.desiredConnected;
    } catch (e) {
      return false;
    }
  }

  /** 同代更新快照，不覆盖用户在此期间推进的新 generation。 */
  private async updateSessionSnapshot(generation: number, desiredConnected: boolean,
    phase: string, nodeName: string, startedAt: number): Promise<boolean> {
    if (!await this.isCurrentSession(generation, false)) {
      return false;
    }
    const snap = new ConnectionSnapshot();
    snap.desiredConnected = desiredConnected;
    snap.phase = phase;
    snap.sessionGeneration = generation;
    snap.nodeName = nodeName;
    snap.savedAt = Date.now();
    snap.startedAt = startedAt;
    await SettingsService.saveSnapshot(snap);
    return true;
  }

  /**
   * 落盘"用户已断开"（desiredConnected=false），并推进会话代次。
   *
   * 与 updateSessionSnapshot 同代保护：expectedGeneration > 0 时，磁盘代次已被推进
   * （即期间有更新的连接接管）就放弃写入 —— 否则旧连接的失败回滚会把新连接刚写下
   * 的 true 覆盖掉，后台自愈就再也读不到"用户仍想连着"。
   */
  private async clearSessionIntent(expectedGeneration: number): Promise<void> {
    try {
      const previous = await SettingsService.loadSnapshot();
      if (expectedGeneration > 0 && previous.sessionGeneration !== expectedGeneration) {
        AppLogger.info(TAG, `skip intent clear: generation moved (${previous.sessionGeneration}`
          + ` != ${expectedGeneration}); newer session owns the state`);
        return;
      }
      const snap = new ConnectionSnapshot();
      snap.desiredConnected = false;
      snap.phase = 'disconnected';
      snap.sessionGeneration = previous.sessionGeneration + 1;
      snap.nodeName = previous.nodeName;
      snap.savedAt = Date.now();
      snap.startedAt = 0;
      await SettingsService.saveSnapshot(snap);
      this.sessionGeneration = snap.sessionGeneration;
    } catch (e) {
      AppLogger.warn(TAG, `clear session intent failed: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * 进程被杀 / 回前台时的状态自愈入口。
   *
   * 只接管现有会话，不自动拉起 VPN。租约过期时先检查认证 controller；证据不足
   * 也不改写用户意图。真正失联交给已有监控的有限确认/修复，或用户主动连接。
   *
   * 判定链（任一命中即不动）：
   *  1. 磁盘上没有"用户想连"的意图 → 用户从未连过，或已明确断开
   *  2. 意图相位是 failed/disconnecting/disconnected → 上次确实没连成/已结束
   *  3. 隧道其实还活着（心跳新鲜）→ 不打断正常会话，仅复用真实状态
   *  4. 本进程已有连接在途（CONNECTING/RECOVERING）→ 让在途流程自己走完
   *  5. 以上都不是 → 运行态尚未确认，保留意图，等待监控复核或用户操作。
   *     打开页面本身不应清除会话意图，更不应启动/拆除隧道。
   *
   * 返回判定原因字符串供日志观察；页面可 await 以同步完成状态接管。
   */
  async restoreKilledSession(context: Context): Promise<string> {
    try {
      await SettingsService.init(context);
      this.init(context);
      const snap = await SettingsService.loadSnapshot();
      if (!snap.desiredConnected) {
        return 'no-intent';
      }
      if (snap.phase !== 'connecting' && snap.phase !== 'connected' && snap.phase !== 'recovering') {
        AppLogger.info(TAG, `restore skipped: snapshot phase=${snap.phase}`);
        return `phase-${snap.phase}`;
      }
      const seq = this.connectSeq;
      if (this.state === ConnState.CONNECTING || this.state === ConnState.RECOVERING
        || this.state === ConnState.DISCONNECTING) {
        return 'operation-in-flight';
      }
      const authority = await this.authorityState();
      if (authority.connected) {
        // UI 进程重建只接管仍在运行的会话，不调用 connect()，不刷新 startedAt。
        await this.restoreTunnelController(snap, false);
        if (seq !== this.connectSeq || this.disconnectRequested
          || !await this.isCurrentSession(snap.sessionGeneration)) {
          return 'session-changed';
        }
        const changedSession = this.sessionGeneration !== snap.sessionGeneration;
        this.sessionGeneration = snap.sessionGeneration;
        if (changedSession || this.startedAt <= 0) { this.startedAt = snap.startedAt; }
        this.lastNodeName = snap.nodeName;
        this.lastSubs = SubscriptionService.instance();
        this.lastNode = this.lastSubs.nodes.find((node: ProxyNode): boolean => node.name === snap.nodeName) ?? null;
        this.setState(ConnState.CONNECTED);
        if (changedSession || this.monitorTimer < 0) { this.startMonitors(); }
        this.notify();
        return 'already-connected';
      }
      AppLogger.warn(TAG, `foreground inspection: runtime unconfirmed (${authority.reason}); `
        + 'preserve session intent; no connect/disconnect from opening the app');
      return 'runtime-unconfirmed';
    } catch (e) {
      AppLogger.warn(TAG, `self-heal error: ${AppLogger.errText(e)}`);
      return 'error';
    }
  }

  isDisconnectRequested(): boolean {
    return this.disconnectRequested;
  }

  /**
   * 隧道是否存活。优先看进程内状态; 进程新起(单例状态丢失)时以扩展进程
   * 心跳文件为准 —— 供桌面快捷方式/服务卡片等无页面入口判断"已连接"。
   */
  isTunnelAlive(): boolean {
    if (this.state === ConnState.CONNECTED || this.state === ConnState.CONNECTING) {
      return true;
    }
    return this.context !== null && this.isCoreAliveByHeartbeat();
  }

  /** 心跳文件年龄；-1 = 无心跳/读取失败（对外暴露供权威状态与专项验证使用） */
  heartbeatAgeMs(): number {
    return this.readHeartbeatAge();
  }

  /** 隧道存活标记：内核成功启动后由扩展进程写入（当前复用 START_OK_FILE 语义） */
  tunnelMarkerExists(): boolean {
    return this.readStartOk();
  }

  /**
   * 权威状态：唯一真值 = 持久化用户意图(desiredConnected) ∧ 内核存活证据。
   * 卡片/通知/页面一律以此为"已连接"判据，绝不再各自依赖易漂移的进程内 state。
   * 需要 await 读取 preferences；调用方在异步上下文使用。
   */
  async authorityState(): Promise<TunnelAuthorityState> {
    let desired = false;
    let snapshot: ConnectionSnapshot | null = null;
    const seq = this.connectSeq;
    try {
      const snap = await SettingsService.loadSnapshot();
      snapshot = snap;
      desired = snap.desiredConnected;
    } catch (e) {
      desired = false;
    }
    // START_OK_FILE 仅用于启动握手，不能作为长期存活证据。
    const state = resolveAuthority(desired, await this.readHeartbeatAgeAsync(), false);
    // 租约可能只是锁屏时停更。先用该会话的私有端口 + AssetStore secret 认证探活。
    // 启动标记、旧 status 文件、无认证的端口响应都不作为此处的存活证明。
    if (desired && !state.coreAlive && snapshot !== null && !this.disconnectRequested
      && await this.restoreTunnelController(snapshot, true)) {
      state.coreAlive = true;
      state.connected = true;
      state.reason = 'controller-alive';
    }
    if (seq !== this.connectSeq
      || !await this.isCurrentSession(snapshot === null ? -1 : snapshot.sessionGeneration, false)) {
      return resolveAuthority(false, -1, false);
    }
    return state;
  }

  /** 把 App 自身的 HTTP 请求接入当前 mixed-port，并在发 CONNECTED 事件前确认监听已就绪。 */
  private async activateAppHttpProxy(source: string): Promise<boolean> {
    AppProxyRoute.apply(this.mixedPort);
    const ready: boolean = await AppProxyRoute.waitUntilReady(4000);
    if (!ready) {
      AppLogger.warn(TAG, `app http proxy not ready (${source}): port=${this.mixedPort}`);
    }
    return ready;
  }

  /** 恢复真实隧道的 controller；只读本机配置头，凭据仍只从 AssetStore 获取。 */
  private async restoreTunnelController(snapshot: ConnectionSnapshot, verifyResponse: boolean): Promise<boolean> {
    if (this.context === null || !snapshot.desiredConnected
      || (snapshot.phase !== 'connected' && snapshot.phase !== 'recovering')
      || this.state === ConnState.CONNECTING || this.state === ConnState.DISCONNECTING
      || (this.testCoreFlight !== null && this.testCoreFlight.isActive())) {
      return false;
    }
    const seq = this.connectSeq;
    try {
      // 生成器把 external-controller 放在第二行；只取 4 KiB，不扫描/记录整份订阅配置。
      const header = await privateFs.readCappedAsync(`${this.context.cacheDir}/${CONFIG_FILE}`, 4096);
      const match = header.ok
        ? /^external-controller:[ \t]*127\.0\.0\.1:(\d{1,5})[ \t]*\r?$/m.exec(header.text) : null;
      const port = match === null ? 0 : Number(match[1]);
      if (port <= 0 || port > 65535) { return false; }
      const secret = await SettingsService.getApiSecret();
      if (secret.length === 0) { return false; }
      const probe = new ClashApiService();
      probe.setEndpoint(port, secret);
      if (verifyResponse && !await probe.healthProbe()) { return false; }
      if (seq !== this.connectSeq || this.disconnectRequested
        || !await this.isCurrentSession(snapshot.sessionGeneration)) {
        return false;
      }
      this.apiPort = port;
      const mixed = /^mixed-port:[ \t]*(\d{1,5})[ \t]*\r?$/m.exec(header.text);
      const dns = /^  listen:[ \t]*127\.0\.0\.1:(\d{1,5})[ \t]*\r?$/m.exec(header.text);
      if (mixed !== null && Number(mixed[1]) > 0 && Number(mixed[1]) <= 65535) {
        this.mixedPort = Number(mixed[1]);
      }
      if (dns !== null && Number(dns[1]) > 0 && Number(dns[1]) <= 65535) {
        this.dnsPort = Number(dns[1]);
      }
      this.apiSecret = secret;
      this.api.setEndpoint(port, secret);
      await this.activateAppHttpProxy('restore');
      if (seq !== this.connectSeq || this.disconnectRequested
        || !await this.isCurrentSession(snapshot.sessionGeneration)) {
        return false;
      }
      return true;
    } catch (e) {
      AppLogger.warn(TAG, `runtime controller restore failed: ${AppLogger.errText(e)}`);
      return false;
    }
  }

  /**
   * 读取 Extension 进程写入的权威运行态（vpn_status.json）。UI 进程冷启动或被
   * 系统回收后重新打开时，直接以此还原真实 VPN 状态，无需重启隧道（对应文档
   * "打开 App → 直接显示真实 VPN 状态"）。缺文件/损坏返回 ok=false 视图。
   */
  extensionStatus(): ExtensionStatusView {
    if (this.context === null) {
      return new ExtensionStatusView();
    }
    const res: SyncReadResult = privateFs.readCapped(
      `${this.context.cacheDir}/${EXTENSION_STATUS_FILE}`, MAX_STATE_FILE_BYTES);
    const view = parseExtensionStatus(res.ok ? res.text : '');
    // UI 呈现相位：结合租约新鲜度归一（running→connected，recovering/leak-blocked 原样）。
    this.uiPhase = deriveUiPhase(view, this.isCoreAliveByHeartbeat());
    return view;
  }

  /** 最近一次从 Extension 状态还原的 UI 相位（connected/recovering/leak-blocked/...）。 */
  uiPhase: string = '';

  /**
   * 权威判定"是否已连接"。内核退出/心跳超时后立即返回 false —— 卡片随即
   * 更新为已断开（修复卡片长期停留在「已连接」的核心）。
   */
  async isAuthoritativelyConnected(): Promise<boolean> {
    const state = await this.authorityState();
    return state.connected;
  }

  /** 配置变更后自动重启隧道：仅当前处于已连接/连接中时才断开并用同一节点重连
   *  （重连会重新生成含新 mode/规则/hosts 的 YAML 并重建带新 blockedApplications 的 TUN）。
   *  未连接时不动 —— 下次手动连接自然带上最新配置。 */
  private restarting: boolean = false;

  /**
   * 用户切换节点后执行完整重连。必须在断开前把目标节点提交为 lastNode，
   * 否则通用 restartIfConnected() 会继续使用旧节点，表现为界面已选中新节点，
   * 但 VPN 实际仍连接旧节点。
   */
  async reconnectWithNode(node: ProxyNode, subs: SubscriptionService, reason: string): Promise<boolean> {
    // UI 进程冷启动后可以从 Extension 权威状态恢复 CONNECTED，但内存中的
    // lastSubs/lastNode 已丢失。节点页必须把刚完成初始化的订阅实例传进来，
    // 不能因 lastSubs 为 null 静默跳过重连。
    if (this.state !== ConnState.CONNECTED && this.state !== ConnState.CONNECTING) {
      const authority = await this.authorityState();
      if (!authority.connected) {
        return false;
      }
      this.setState(ConnState.CONNECTED);
    }
    if (this.restarting) {
      return false;
    }
    this.lastSubs = subs;
    this.lastNode = node;
    this.lastNodeName = node.name;
    this.restarting = true;
    AppLogger.info(TAG, `node switch reconnect (${reason}): ${node.name}`);
    try {
      await this.disconnect();
      await new Promise<void>((resolve) => setTimeout(() => resolve(), 600));
      const ok = await this.connect(node, subs);
      AppLogger.info(TAG, `node switch reconnect (${reason}) completed, result=${ok}`);
      return ok;
    } finally {
      this.restarting = false;
    }
  }

  async restartIfConnected(reason: string): Promise<boolean> {
    if (this.state !== ConnState.CONNECTED && this.state !== ConnState.CONNECTING) {
      return false;
    }
    if (this.restarting) {
      return false; // 已有重启在途, 忽略重复触发(防抖)
    }
    const subs = this.lastSubs;
    const node = this.lastNode;
    if (subs === null || node === null) {
      return false;
    }
    // 保存分流后先预检，再拆旧隧道；非法新设置不能使仍有效的旧连接断开。
    const settings = await SettingsService.load();
    AppRoutingPolicy.runtime(settings.appRoutingMode, settings.includedApps,
      settings.excludedApps, settings.appRoutingNeedsReview);
    if (this.restarting) {
      return false; // 异步设置加载期间可能已有另一次重启抢先启动
    }
    this.restarting = true;
    AppLogger.info(TAG, `auto-restart (${reason}): 断开并重连以应用新配置`);
    try {
      await this.disconnect();
      await new Promise<void>((resolve) => setTimeout(() => resolve(), 600));
      const ok = await this.connect(node, subs);
      AppLogger.info(TAG, `auto-restart (${reason}) 完成, 结果=${ok}`);
      if (!ok) {
        throw new Error(this.lastError.length > 0 ? this.lastError : '应用分流已保存，但 VPN 重连失败，请手动重新连接');
      }
      return true;
    } finally {
      this.restarting = false;
    }
  }

  /**
   * 运行时切换代理模式：优先通过 Mihomo controller 热更新，保持 TUN、VPN 与 Core。
   * controller 不可用或热更新失败时才回退到完整重连，确保配置最终生效。
   */
  async applyProxyMode(mode: string): Promise<void> {
    if (this.state === ConnState.CONNECTED) {
      const updated = await this.api.setMode(mode);
      if (updated) {
        AppLogger.info(TAG, `proxy mode hot-updated: ${mode}`);
        this.notify();
        return;
      }
      AppLogger.warn(TAG, `proxy mode hot-update failed; fallback to reconnect: ${mode}`);
    }
    await this.restartIfConnected('proxyMode=' + mode);
  }

  /**
   * 写盘前的配置校验闸门（C23 / C23b / C23c）。
   *
   * 为什么必须有这道闸门：mihomo 用 go.yaml.in/yaml/v3 v3.0.5，`uniqueKeys` 默认开启 →
   * 同层级重复键 = TypeError → **整份配置拒载**（不是跳过那个节点）。
   * 于是「一个节点的字段写坏了」会升级成「用户的整个 VPN 起不来」——
   * 这正是用户报障原文「VPN 扩展启动异常: parse config:yaml: unmarshal errors:」的形态。
   *
   * 策略（受控降级，不是全有全无）：
   *   · 能安全降级的问题（重复键 / YAML 1.1 布尔）→ **就地降级**并记录到日志；
   *   · 降级后仍有无法降级的问题 → **保留上一份可用配置**（不覆盖磁盘）并中止本次连接，
   *     给出可行动的提示（请更新订阅后重试），而不是写出一份内核一定拒载的配置。
   *
   * @param yaml 生成的配置文本
   * @param scene 场景标签（main / hot-reload / test-core），只进日志
   * @returns 可以安全写盘的配置文本
   */
  private async prepareConfigYaml(yaml: string, scene: string): Promise<string> {
    const result = ConfigValidator.repair(yaml);
    if (result.issues.length > 0) {
      AppLogger.warn(TAG, `[config-gate/${scene}] ${result.summary()}`);
    }
    if (!result.ok) {
      const blocking = result.blocking();
      const head = blocking.length > 0
        ? `首个问题在第 ${blocking[0].line} 行（${blocking[0].key}）`
        : '存在无法自动降级的问题';
      // 关键：**不覆盖磁盘上的旧配置** —— 旧配置是用户最后一份能用的配置。
      throw new Error(`配置校验未通过（${head}）：${result.summary()}。`
        + '已保留上一份可用配置未覆盖；请更新订阅后重试，或反馈该订阅链接');
    }
    const candidate = result.text.length > 0 ? result.text : yaml;
    // 订阅原文通过校验，不代表与本地规则/覆盖合并后的引用仍然有效。
    // 原生校验器不应用配置、不建立监听，也不初始化/下载 provider。
    // 它只验证最终文档结构；Geo 文件等设备依赖仍由资源就绪检查负责。
    try {
      await coreBridge.prepareProfile(candidate);
    } catch (e) {
      throw new Error(`配置校验未通过：最终配置未通过内核检查（${AppLogger.errText(e)}）。已保留原配置`);
    }
    return candidate;
  }

  /**
   * 记下最后一份「内核接受并成功连上」的配置。
   *
   * 文档预检不能证明设备资源和真实会话已经可用，快照仍须在真实就绪之后提交。
   * 记录本次被接受的字节；正式文件提升失败时也不能误把更旧的磁盘内容记成可用版本。
   */
  private snapshotLastGoodConfig(content: string = ''): void {
    if (this.context === null) {
      return;
    }
    try {
      const src = `${this.context.cacheDir}/${CONFIG_FILE}`;
      const snapshot = content.length > 0 ? content : privateFs.readCapped(src, 8 * 1024 * 1024).text;
      if (snapshot.length === 0) { return; }
      const dst = `${this.context.cacheDir}/${LAST_GOOD_CONFIG_FILE}`;
      privateFs.writePrivate(`${dst}.tmp`, snapshot);
      fs.renameSync(`${dst}.tmp`, dst);
      chmodPrivate(dst, 0o600);
    } catch (e) {
      AppLogger.warn(TAG, `last-good snapshot failed: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * 内核已接受暂存配置 → 把**这份字节**原子替换到正式配置路径。
   *
   * 2026-10-22（用户要求「冷启动也走临时文件 → 内核校验 → 成功才替换」，对齐 FlClash）：
   * 设备侧 core 没有 `-t` CLI，所以校验器就是扩展自己 —— 暂存路径交给它拉起，
   * readiness 通过（controller 真的答了）才调本方法。拒载路径不会走到这里，
   * 正式配置因此永远保持上一份「内核真的加载过」的字节。
   *
   * 原子性：先写 `${target}.tmp` 再同目录 rename（rename 在 POSIX 语义下原子），
   * 任何时刻磁盘上都有一份完整文件；写完再收权限 0600（含 API secret 与节点口令）。
   *
   * @param staged 扩展实际加载的暂存文件（保留不删：扩展后续可能再读它）
   * @param target 正式配置路径（下一轮冷启动 / 热重载的基准）
   * @param content 已过写盘闸门的配置文本（不回读暂存文件，避免并发改写）
   */
  private acceptStagedConfig(staged: string, target: string, content: string): void {
    try {
      if (content.length === 0) {
        AppLogger.warn(TAG, 'staged config promote skipped: empty content');
        return;
      }
      const tmp = `${target}.tmp`;
      privateFs.writePrivate(tmp, content);
      fs.renameSync(tmp, target);
      chmodPrivate(target, 0o600);
      AppLogger.info(TAG, `config promoted: kernel accepted ${staged} → ${CONFIG_FILE} (${content.length} bytes)`);
    } catch (e) {
      // 提升失败不撤销已建立的连接：隧道用的是暂存文件，功能不受影响；
      // 代价只是「下次冷启动的基准配置」仍是旧的一份（并且 last-good 会照常更新）。
      AppLogger.warn(TAG, `staged config promote failed: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * 内核拒载（parse config）时把最后一份能连上的配置写回去，供用户下一次连接直接起。
   * @returns 是否真的回滚成功（false = 没有快照或回滚失败，调用方按原错误上报）
   */
  private restoreLastGoodConfig(): boolean {
    if (this.context === null) {
      return false;
    }
    try {
      const snapshot = `${this.context.cacheDir}/${LAST_GOOD_CONFIG_FILE}`;
      if (!privateFs.exists(snapshot)) {
        return false;
      }
      const stored = privateFs.readCapped(snapshot, 8 * 1024 * 1024);
      if (!stored.ok || stored.truncated || stored.text.length === 0) { return false; }
      const target = `${this.context.cacheDir}/${CONFIG_FILE}`;
      privateFs.writePrivate(`${target}.tmp`, stored.text);
      fs.renameSync(`${target}.tmp`, target);
      chmodPrivate(target, 0o600);
      AppLogger.warn(TAG, 'kernel rejected generated config; restored last-good snapshot');
      return true;
    } catch (e) {
      AppLogger.warn(TAG, `last-good restore failed: ${AppLogger.errText(e)}`);
      return false;
    }
  }

  /**
   * 规则/强制站点/DNS 等变更的热重载：重写当前节点的 YAML 到同一配置路径，
   * 通过 Mihomo controller 的 PUT /configs?path= 在内核内重建规则链，保持 VPN/TUN
   * 与既有连接不被拆除（对应文档"减少 TUN/Core 重建"）。仅当内核可控时生效；
   * 未确认应用时返回 false；不以重连重试坏配置，避免拆掉可用会话。
   */
  async reloadRulesHot(reason: string): Promise<boolean> {
    if (this.reloading) { return false; }
    const seq = this.connectSeq;
    const generation = this.sessionGeneration;
    const task = this.lifecycleWrites.then((): Promise<boolean> => {
      if (!this.isRuleSessionCurrent(seq, generation)) { return Promise.resolve(false); }
      return this.reloadRulesHotExclusive(reason);
    });
    this.lifecycleWrites = task.then((): void => {}, (): void => {});
    return task;
  }

  private async reloadRulesHotExclusive(reason: string): Promise<boolean> {
    const subs = this.lastSubs;
    const node = this.lastNode;
    if (this.state !== ConnState.CONNECTED || subs === null || node === null || this.context === null) {
      return false;
    }
    if (this.reloading) {
      return false;
    }
    this.reloading = true;
    const seq = this.connectSeq;
    const generation = this.sessionGeneration;
    try {
      const settings: AppSettings = await SettingsService.load();
      let target = node;
      const requestedProfile = ProfileRepository.currentId();
      if (requestedProfile.length > 0 && requestedProfile !== this.appliedProfileId) {
        // preferredNode* 只是**用户偏好缓存**（2026-10-27 契约，见 AppSettings 类注释）：
        // 切订阅时要先认内核**已经生效**的出口（ConnectionTarget，来源 /proxies），
        // 它才是「当前是什么节点」；偏好只作同订阅内的兜底提示。
        const liveName: string = this.kernelSelection.nodeName();
        let liveNode: ProxyNode | null = null;
        if (liveName.length > 0) {
          for (const n of subs.nodesOf(requestedProfile)) {
            if (n.name === liveName) { liveNode = n; break; }
          }
        }
        const preferred = subs.findNode(settings.preferredNodeId);
        const fallback = subs.fallbackConnectionNode();
        if (liveNode !== null) {
          target = liveNode;
        } else {
          target = preferred !== null && preferred.subscriptionId === requestedProfile
            ? preferred : (fallback !== null ? fallback : node);
        }
      }
      const ruleProviderFileReady = this.isRuleProviderReady();
      // 凭据回填收敛在 hydrateAndBuildProfile（生成配置的唯一入口）。
      // 唯一配置生成入口：热重载与隧道/测速核走同一条生成路径（决策一处、事实同源）。
      const hotPorts = new RuntimePorts();
      hotPorts.apiPort = this.apiPort;
      hotPorts.mixedPort = this.mixedPort;
      hotPorts.dnsPort = this.dnsPort;
      const hotProfile = await this.hydrateAndBuildProfile(subs, settings, target.name, hotPorts, this.apiSecret,
        this.lastProxyHosts, this.lastSmartModelReady, this.lastGeoipReady, ruleProviderFileReady);
      const hotBuilt = await RuntimeConfigBuilder.buildRuntimeConfig(hotProfile, RuntimeConfigMode.TUNNEL);
      // 与 connect 同口径：钉选必须钉最终 YAML 的 PROXY 组首成员，否则 PUT 400 →
      // 回滚热重载（节点被 validNodes 过滤 / 原文接管时尤其常见）。
      const hotEffectiveName: string = (hotBuilt.effectiveNodeName ?? '').length > 0
        ? hotBuilt.effectiveNodeName : target.name;
      const hotEffectiveNode: ProxyNode | null =
        (hotProfile.nodes ?? []).find((n: ProxyNode): boolean => n.name === hotEffectiveName) ?? null;
      const hotPinNode: ProxyNode = hotEffectiveNode !== null ? hotEffectiveNode : target;
      if (!this.isRuleSessionCurrent(seq, generation)) {
        return false;
      }
      const yaml = hotBuilt.yaml;
      // 写盘前闸门：坏配置绝不落盘（内核对重复键是整份拒载）
      const safeYaml = await this.prepareConfigYaml(yaml, 'hot-reload');
      if (!this.isRuleSessionCurrent(seq, generation)) { return false; }
      const configPath = `${this.context.cacheDir}/${CONFIG_FILE}`;
      const lastGoodPath = `${this.context.cacheDir}/${LAST_GOOD_CONFIG_FILE}`;
      const rollbackPath = privateFs.exists(lastGoodPath) ? lastGoodPath : configPath;
      ensurePrivateDir(this.context.cacheDir);
      // 两步落盘（对齐 FlClash：临时文件 → 内核校验 → 成功才替换）：
      // 先把新配置写成 .next 暂存文件，让内核加载校验；只有内核接受才原子替换正式配置。
      // 内核拒载时磁盘上那份「上次能用的配置」保持原样 —— 否则一次坏规则就是重启即整份拒载。
      const stagedPath = `${configPath}.next`;
      privateFs.writePrivate(stagedPath, safeYaml);
      const reloaded = await this.api.reloadFromPath(stagedPath);
      if (!this.isRuleSessionCurrent(seq, generation)) {
        return false;
      }
      if (!reloaded) {
        try {
          fs.unlinkSync(stagedPath);
        } catch (cleanupError) {
          // 暂存文件已不存在属正常
        }
        // HTTP 超时也会返回 false，不能据此宣称内核一定没有应用。
        AppLogger.warn(TAG, `[hot-reload] candidate not confirmed; accepted file kept (${reason})`);
        return false;
      }
      // 热重载会重置 select 组；选点确认前不能提交新的 Profile 身份或磁盘基准。
      const pinned = (hotEffectiveName === target.name && target.id.startsWith('profile:'))
        || await this.api.selectNode(hotEffectiveName);
      if (!this.isRuleSessionCurrent(seq, generation)) { return false; }
      if (!pinned) {
        const restored = await this.api.reloadFromPath(rollbackPath);
        if (!this.isRuleSessionCurrent(seq, generation)) { return false; }
        if (restored) { await this.api.selectNode(this.lastNodeName); }
        AppLogger.warn(TAG, `[hot-reload] selection failed; rollback accepted=${restored}`);
        return false;
      }
      this.confirmProfileApplied('hot-reload');
      // 内核已接受暂存配置 → 原子替换正式配置（同目录 rename）。
      // 即便这一步失败，内核已按暂存文件生效，本轮功能不受影响，只是下次连接会重写。
      try {
        fs.renameSync(stagedPath, configPath);
      } catch (promoteError) {
        AppLogger.warn(TAG, `[hot-reload] staged config accepted but promote failed: ${AppLogger.errText(promoteError)}`);
      }
      // 隧道配置已按当前节点集重写 → 登记新指纹（测速前的过期判定用）
      this.tunnelConfigFingerprint = SubscriptionService.nodeSetFingerprint(subs.nodes);
      this.lastRuleProviderFileReady = ruleProviderFileReady;
      this.lastNode = hotPinNode;
      this.lastNodeName = hotEffectiveName;
      this.snapshotLastGoodConfig(safeYaml);
      await this.updateSessionSnapshot(generation, true, 'connected', hotEffectiveName, this.startedAt);
      if (!this.isRuleSessionCurrent(seq, generation)) { return false; }
      // mode 已在本次最终 YAML 中，不额外发送一个可能迟到的异步模式更新。
      AppLogger.info(TAG, `[hot-reload] rules applied without TUN rebuild (${reason})`);
      this.notify();
      return true;
    } catch (e) {
      AppLogger.warn(TAG, `[hot-reload] exception: ${AppLogger.errText(e)} (${reason})`);
      return false;
    } finally {
      this.reloading = false;
    }
  }

  /**
   * 运行中直接切换节点：通过 controller PUT /proxies 热切换，保持 VPN/TUN/Core。
   * 仅在当前已连接且节点存在于上次订阅快照时生效；否则返回 false 由调用方回退重连。
   */
  async switchNodeHot(nodeName: string): Promise<boolean> {
    if (this.state !== ConnState.CONNECTED || this.lastSubs === null) {
      return false;
    }
    const node = this.findNodeByName(this.lastSubs, nodeName);
    if (node === null) {
      return false;
    }
    const snapshot = await SettingsService.loadSnapshot();
    const seq = this.connectSeq;
    const ok = await this.api.selectNode(nodeName);
    if (!ok || seq !== this.connectSeq || this.disconnectRequested) {
      return false;
    }
    this.lastNode = node;
    this.lastNodeName = nodeName;
    try {
      await SettingsService.patchActiveSnapshot(snapshot.sessionGeneration, nodeName, this.startedAt);
    } catch (e) {
      AppLogger.warn(TAG, `switchNodeHot snapshot save failed: ${AppLogger.errText(e)}`);
    }
    AppLogger.info(TAG, `node hot-switched to ${nodeName} (no TUN rebuild)`);
    this.notify();
    return true;
  }

  /** 热重载后尽力把运行时模式对齐持久化设置，忽略单次失败（不影响隧道连续性）。 */
  private applyProxyModeSilent(mode: string): void {
    this.api.setMode(mode).catch((): void => {});
  }

  /**
   * 规则变更统一入口：优先热重载，失败回退完整重连（保证最终生效）。
   * 应用排除/白名单（包名级）变更仍需重建 TUN，不走此路径。
   * @returns hot / reconnect / none；ad-unavailable=需手动下载规则集；pending=另一热更进行中
   */
  /**
   * 确保「内核里的配置」就是 `ProfileRepository.currentId()` 指向的那份。
   *
   * 订阅导入/切换后必须调一次再测速：否则内核仍是旧订阅的节点，
   * `/proxies` 返回旧集合，测速结果对不上界面（用户报障：新订阅测速全是 `--`）。
   * 已连接时走热重载（不断线）；未连接时下次起内核自然用新配置。
   */
  /** 当前**内核里真正生效**的 profile id（空串 = 还没生成过配置）。 */
  appliedProfile(): string {
    return this.appliedProfileId;
  }

  /**
   * 内核确认配置生效时调用（connect readiness / reloadFromPath 成功 / 测速核 ready）。
   *
   * 为什么不能"生成即生效"：`buildRuntimeProfile` 只是产出文本，内核可能还在加载，
   * 也可能整份拒载。提前把 applied 改掉，UI 就会用旧内核目录渲染新订阅
   * （用户实锤：来回切订阅后节点串到别的订阅下面）。
   */
  private confirmProfileApplied(stage: string): void {
    if (this.pendingProfileId.length === 0) {
      return;
    }
    AppLogger.info(TAG, `profile applied: ${this.appliedProfileId || '<none>'} -> ${this.pendingProfileId} (${stage})`);
    this.appliedProfileId = this.pendingProfileId;
    this.appliedProfileRevision = this.pendingProfileRevision;
  }

  async ensureProfileApplied(reason: string): Promise<boolean> {
    const current = ProfileRepository.currentId();
    if (current.length === 0 || !ProfileRepository.exists(current)) {
      return false;
    }
    if (this.appliedProfileId === current
      && this.appliedProfileRevision === ProfileRepository.revisionOf(current)) {
      return true;
    }
    if (this.state !== ConnState.CONNECTED && this.state !== ConnState.CONNECTING) {
      // 未连接：没有真实隧道，但**测速核可能还在跑旧配置** —— 必须作废它，
      // 否则 `/proxies` 还是旧订阅的节点（用户报障：新订阅测速后节点全是 `--`）。
      await this.invalidateTestCoreForSubscriptionChange(`profile:${reason}`);
      // 不在这里改 applied：等测速核/隧道真的按新 profile 起来后由 confirmProfileApplied 落定。
      return true;
    }
    // ── 自动选择模式：切换订阅必须完整重连（2026-10-25 用户口径）────────────
    // 热重载（PUT /configs）刻意不拆隧道：它保留旧会话与旧出口，对「只是规则变了」
    // 是对的，用户也不会掉线。但自动选择模式下用户的意图是「让内核重新优选」——
    // 新订阅的节点集、smart 组的候选池、LightGBM 的评分都需要重新评估，
    // 而热重载会沿用旧的内核选择状态（store-selected 也按旧节点名记住了旧出口），
    // 表现为**切了订阅却还用旧订阅的出口**，用户必须手动断开再连才生效。
    //
    // 与手动选节点保持一致：那条路径走 reconnectWithNode（disconnect + connect），
    // 所以「手动指定节点会自动重连，自动选择却不动」成了可感知的不对称。
    // 这里对齐：自动选择模式下走同一条完整重连路径。
    // 手动模式保持热重载不变（不打断用户正在用的固定节点）。
    if (await this.shouldFullReconnectOnProfileSwitch(current)) {
      const switched = await this.reconnectForProfileSwitch(current, reason);
      if (switched) {
        return true;
      }
      // 拿不到可拨号的目标节点时退回热重载：至少让内核配置跟上新 profile，
      // 不要把「重连不了」变成「连原本能用的配置也不更新」。
      AppLogger.warn(TAG, `auto-select profile switch: no dial target; falling back to hot reload (${reason})`);
    }
    AppLogger.info(TAG, `profile changed (${this.appliedProfileId} -> ${current}); hot reload for ${reason}`);
    const result = await this.applyRulesChanged(reason);
    const ok = result === 'hot' || result === 'reconnect' || result === 'ad-unavailable';
    // applied 由 reloadFromPath 成功时的 confirmProfileApplied('hot-reload') 落定
    return ok;
  }

  /**
   * 切换订阅时是否应该完整重连而不是热重载。
   *
   * 两种情况必须重连：
   * ① 自动选择模式：用户意图是「让内核按新订阅重新优选」，热重载会沿用旧选择；
   * ② 手动模式但**钉住的出口不属于新 profile**（2026-10-28 用户报障）：旧节点名在
   *    新配置里不存在，内核只能自己挑一个，而 App 侧 ConnectionTarget 仍写着旧订阅的
   *    节点 → 主页 /「当前连接节点」显示旧订阅、订阅页复选框显示新订阅（偏好被
   *    restoreRememberedNode 改成新订阅节点），三处互相矛盾。跨 profile 的钉节点在
   *    物理上不可能成立，必须重新拨号把出口与真源一起落到新订阅。
   *
   * 手动模式且出口仍属于新 profile 时保持热重载（不打断用户正在用的固定节点）。
   */
  private async shouldFullReconnectOnProfileSwitch(profileId: string): Promise<boolean> {
    if (this.state !== ConnState.CONNECTED) {
      return false;
    }
    if (this.restarting) {
      // 已有重启在途：让编排器按原路径收敛，避免叠加第二条连接流水线。
      return false;
    }
    // 2026-10-28：订阅切换语义统一为“切订阅 = 切出口”。
    // 之前仅在 AUTO 模式或出口不属于目标 profile 时才完整重连，
    // 导致已连接状态下切换订阅经常只做热重载：UI 提示正在切换，
    // 实际 ConnectionTarget 仍保持旧节点，主页继续显示旧出口。
    // 这里统一要求 profile 发生切换时执行完整 reconnect，
    // 让当前出口、内核选择、主页显示、订阅页状态始终收敛到同一事实来源。
    return true;
  }

  /**
   * 当前出口节点是否属于指定 profile。
   *
   * 名字是跨数据源唯一稳定的节点标识（内核影子节点 id 是 `core:<name>`，与解析节点 id
   * 不同），因此按名字 + 订阅作用域判定，而不是比 id。
   */
  private exitBelongsToProfile(profileId: string): boolean {
    if (profileId.length === 0) {
      return false;
    }
    const target: ConnectionTarget | null = this.kernelSelection.current();
    const name: string = target !== null && target.nodeName.length > 0
      ? target.nodeName : this.lastNodeName;
    if (name.length === 0) {
      // 没有可靠出口记录：按「不属于」处理，重连一次把事实落定，别让显示层继续挂旧值。
      return false;
    }
    const subs: SubscriptionService = this.lastSubs !== null
      ? this.lastSubs : SubscriptionService.instance();
    return subs.nodes.some((n: ProxyNode): boolean =>
      n.subscriptionId === profileId && n.name === name);
  }

  /**
   * 自动选择模式下切换订阅：按新订阅重新拨号（完整 disconnect + connect）。
   *
   * 目标节点必须属于**新 profile**：跨订阅旧偏好会让重连钉到新配置里不存在的名字，
   * 表现为「选择未生效」——与 SubscriptionPage.enableAutoSelect 的取舍一致。
   * smart 组本身不是可拨号目标，仍需一个真实节点做初始拨号。
   */
  private async reconnectForProfileSwitch(profileId: string, reason: string): Promise<boolean> {
    const subs: SubscriptionService = this.lastSubs !== null
      ? this.lastSubs : SubscriptionService.instance();
    let target: ProxyNode | null = null;
    try {
      const preferred = await subs.resolvePreferenceHint();
      target = preferred !== null && preferred.subscriptionId === profileId ? preferred : null;
    } catch (e) {
      target = null;
    }
    if (target === null) {
      const fallback = subs.fallbackConnectionNode();
      target = fallback !== null && fallback.subscriptionId === profileId ? fallback : null;
    }
    if (target === null) {
      return false;
    }
    AppLogger.info(TAG, `auto-select profile switch: full reconnect (${reason}) target=${target.name}`);
    return this.reconnectWithNode(target, subs, `profile-switch:${reason}`);
  }

  async applyRulesChanged(reason: string): Promise<string> {
    const seq = this.connectSeq;
    const generation = this.sessionGeneration;
    const task = this.ruleApplyQueue.then((): Promise<string> =>
      this.applyRulesChangedNow(reason, seq, generation));
    this.ruleApplyQueue = task.catch((e: Object): string => {
      AppLogger.warn(TAG, `apply rules failed: ${AppLogger.errText(e)}`);
      return 'none';
    });
    return task;
  }

  private ruleApplyQueue: Promise<string> = Promise.resolve('none');

  private isRuleSessionCurrent(seq: number, generation: number): boolean {
    return this.state === ConnState.CONNECTED && !this.disconnectRequested
      && seq === this.connectSeq && generation === this.sessionGeneration;
  }

  private async applyRulesChangedNow(reason: string, seq: number, generation: number): Promise<string> {
    if (!this.isRuleSessionCurrent(seq, generation)) {
      return 'none';
    }
    const settings = await SettingsService.load();
    if (!this.isRuleSessionCurrent(seq, generation)) {
      return 'none';
    }
    // 资产仅由手动下载/内置副本来源；缺文件也要应用其余规则，并移除旧 provider。
    // 去广告是独立开关（2026-10-23 用户口径）：这里只看 hyperAdRulesEnabled，
    // 不能因为「规则引擎关着」就把去广告判定成不可用。
    const adUnavailable = settings.hyperAdRulesEnabled && !this.isRuleProviderReady();
    if (this.reloading) {
      return 'pending';
    }
    const hot = await this.reloadRulesHot(reason);
    if (!this.isRuleSessionCurrent(seq, generation)) {
      return 'none';
    }
    if (hot) {
      return adUnavailable ? 'ad-unavailable' : 'hot';
    }
    // 坏配置、资源错误和控制器暂时不可用均不能通过拆掉现有会话来重试。
    // 真正的会话失效由存活监控按独立证据和用户意图处理。
    return 'apply-failed';
  }

  // ══════════════════════════════════════════════════════════════════
  // 第二阶段集成点①：网络切换感知 → 指数退避 + 单航班 + 最大次数重连
  // ══════════════════════════════════════════════════════════════════

  /** 启动网络状态监听（幂等）。register 失败只降级，不影响主流程。 */
  startNetworkWatch(): void {
    if (this.context === null) {
      return;
    }
    if (this.netWatcher === null) {
      this.netWatcher = new NetworkStateWatcher();
    }
    // addListener 幂等（watcher 内部按引用去重），确保 stop 后再 start 仍能收到回调
    this.netWatcher.addListener(this);
    if (!this.netWatcher.isSubscribed()) {
      const ok = this.netWatcher.start(this.context);
      // 建立基线：首个事件（prev=''）只记录不触发重连
      this.lastNetType = this.netWatcher.networkType();
      this.lastNetGeneration = this.netWatcher.generation();
      AppLogger.info(TAG, `[reconnect] network watcher start=${ok} subscribed=${this.netWatcher.isSubscribed()} type=${this.lastNetType}`);
    }
  }

  /** 停止网络状态监听并彻底解绑 */
  stopNetworkWatch(): void {
    if (this.netWatcher !== null) {
      this.netWatcher.stop();
    }
    this.reconnectManager().cancel('watch-stopped');
  }

  /** 退避上限可配（ms）；重连状态归 ReconnectManager，这里只转发配置 */
  setReconnectBackoffMax(ms: number): void {
    this.reconnectManager().setMaxDelay(ms > 0 ? ms : RECONNECT_MAX_MS);
  }

  /**
   * NetworkStateListener 回调。
   * 只对「物理网络类型」之间的真实切换做响应；UNKNOWN（多为本应用自身 TUN 承载）
   * 一律忽略，避免 VPN 起来后自触发重连风暴。
   */
  onNetworkTypeChanged(netType: string, generation: number): void {
    try {
      if (generation <= this.lastNetGeneration) {
        return; // 同一代际重复回调，忽略
      }
      this.lastNetGeneration = generation;
      const prev = this.lastNetType;
      this.lastNetType = netType;
      AppLogger.info(TAG, `[reconnect] net change gen=${generation} ${prev.length === 0 ? '(init)' : prev} -> ${netType}`);
      if (netType === NetTypes.NONE) {
        this.reconnectManager().cancel('network-lost');
        AppLogger.info(TAG, '[reconnect] network lost; wait for recovery (no reconnect)');
        return;
      }
      if (!this.isPhysicalNetType(netType) || !this.isPhysicalNetType(prev)) {
        AppLogger.info(TAG, `[reconnect] ignore non-physical transition ${prev} -> ${netType}`);
        return;
      }
      if (prev.length === 0) {
        AppLogger.info(TAG, '[reconnect] baseline recorded, no action');
        return;
      }
      if (prev === netType) {
        return;
      }
      const restored = prev === NetTypes.NONE;
      this.reconnectManager().request(restored ? ReconnectReason.NETWORK_RESTORED
        : ReconnectReason.NETWORK_CHANGED);
    } catch (e) {
      AppLogger.warn(TAG, `[reconnect] listener error: ${AppLogger.errText(e)}`);
    }
  }

  private isPhysicalNetType(t: string): boolean {
    return t === NetTypes.NONE || t === NetTypes.WIFI
      || t === NetTypes.CELLULAR || t === NetTypes.ETHERNET;
  }

  /**
   * 重连管理器（Phase 3）：重连的**全部状态**（定时器 / 尝试计数 / 退避预算 / 原因）
   * 都归 `ReconnectManager` 所有。编排器这里只做一次装配，并提供只读能力。
   *
   * 为什么用「懒装配 + 宿主回调」而不是把字段留在本类：
   *   ① 宿主能力（意图、代数、单航班、网络）全是编排器的私有状态，用箭头闭包注入
   *      可以避免为此新增一批 public getter（对外 API 表面最小）；
   *   ② 管理器在第一次需要时才创建，避免字段初始化阶段就依赖 `this` 的其它字段。
   */
  private reconnectManager(): ReconnectManager {
    let manager = this.reconnects;
    if (manager === null) {
      const host = new ReconnectHost();
      host.wantsConnected = (): Promise<boolean> => this.isUserIntentConnected();
      host.userDisconnected = (): boolean => this.disconnectRequested;
      host.networkDown = (): boolean => this.lastNetType === NetTypes.NONE;
      host.connectInFlight = (): boolean => this.state === ConnState.CONNECTING;
      host.hasEndpoint = (): boolean => this.lastSubs !== null && this.lastNodeName.length > 0;
      host.sessionGeneration = (): number => this.connectSeq;
      host.networkType = (): string => this.currentNetworkType();
      host.networkGeneration = (): number => this.networkGeneration();
      host.watcherSubscribed = (): boolean => this.isNetworkWatcherSubscribed();
      host.runAttempt = (reason: string): Promise<ReconnectAttemptOutcome> =>
        this.runReconnectAttempt(reason);
      host.onChanged = (): void => {
        this.notify();
      };
      host.onGiveUp = (message: string): void => {
        this.lastError = message;
        this.notify();
      };
      manager = new ReconnectManager(host, RECONNECT_BASE_MS, RECONNECT_MAX_MS,
        RECONNECT_MAX_ATTEMPTS);
      this.reconnects = manager;
    }
    return manager;
  }

  /**
   * 真正执行一次重连尝试（由 `ReconnectManager` 在退避到点后调用）。
   *
   * 这里只做编排器才能做的事：取上一次端点、找节点、`connect()`，以及**代数判定**
   * （`connectSeq` 变了 ⇒ 本次尝试已被新事务取代，旧链路必须停，绝不排重试）。
   */
  private async runReconnectAttempt(reason: string): Promise<ReconnectAttemptOutcome> {
    const subs = this.lastSubs;
    if (subs === null || this.lastNodeName.length === 0) {
      AppLogger.warn(TAG, '[reconnect] no previous endpoint; abort');
      return ReconnectAttemptOutcome.SUPERSEDED;
    }
    const node = this.findNodeByName(subs, this.lastNodeName);
    if (node === null) {
      AppLogger.warn(TAG, '[reconnect] node not found; abort');
      return ReconnectAttemptOutcome.FAILED;
    }
    const attemptSeq = this.connectSeq + 1;
    const ok = await this.connect(node, subs);
    if (attemptSeq !== this.connectSeq) {
      // 期间又开了新事务（用户手动连接 / 切订阅）⇒ 本次尝试的结论无效。
      return ReconnectAttemptOutcome.SUPERSEDED;
    }
    if (ok) {
      return ReconnectAttemptOutcome.SUCCESS;
    }
    return this.disconnectRequested ? ReconnectAttemptOutcome.SUPERSEDED
      : ReconnectAttemptOutcome.FAILED;
  }

  /** 用户连接意图（进程内状态优先，否则读持久化快照） */
  private async isUserIntentConnected(): Promise<boolean> {
    if (this.disconnectRequested) {
      return false;
    }
    if (this.state === ConnState.CONNECTED || this.state === ConnState.CONNECTING
      || this.state === ConnState.RECOVERING) {
      return true;
    }
    try {
      const snap = await SettingsService.loadSnapshot();
      return snap.desiredConnected;
    } catch (e) {
      return false;
    }
  }

  // ── 只读访问器（供第三轮 UI 读取，无副作用） ──────────────────────

  /** 当前网络类型（watcher 视图） */
  currentNetworkType(): string {
    return this.netWatcher === null ? NetTypes.UNKNOWN : this.netWatcher.networkType();
  }

  /** 网络事件代数 */
  networkGeneration(): number {
    return this.netWatcher === null ? 0 : this.netWatcher.generation();
  }

  /** 网络监听是否已订阅 */
  isNetworkWatcherSubscribed(): boolean {
    return this.netWatcher !== null && this.netWatcher.isSubscribed();
  }

  /** 重连运行态快照（重连状态全部归 ReconnectManager） */
  reconnectState(): ReconnectRuntimeState {
    return this.reconnectManager().snapshot(this.state === ConnState.CONNECTING);
  }

  // ══════════════════════════════════════════════════════════════════
  // 第二阶段集成点②：链路自检 → 有限自动修复（自检报告缓存供 UI）
  // ══════════════════════════════════════════════════════════════════

  /** 最近一次自检报告（可读，供 UI）；从未自检为 null */
  lastHealthReport(): LinkHealthReport | null {
    return this.healthReport;
  }

  /** 最近一次自检汇总 */
  lastHealthSummary(): LinkHealthSummary | null {
    return this.healthSummaryCache;
  }

  /** 最近一次自检推导出的修复动作序列 */
  healthRepairStepsLast(): string[] {
    return this.healthRepairCache.slice();
  }

  /** 是否正在执行自检/修复 */
  isHealthCheckRunning(): boolean {
    return this.healthRunning;
  }

  /**
   * 自检 + 有限修复一条龙。
   * 顺序：先跑一次自检 → 缓存报告 → 按 repairSteps(受 healthRepairMaxSteps 限制)
   * 顺序执行修复 → 重新自检一次；仍失败则以明确原因结束，不再盲目重试。
   * @returns 最终是否恢复为已连接
   */
  private async runHealthSelfCheckAndRepair(reason: string): Promise<boolean> {
    if (this.healthRunning) {
      AppLogger.info(TAG, `[health] already running; skip (${reason})`);
      return this.state === ConnState.CONNECTED;
    }
    let settings: AppSettings;
    try {
      settings = await SettingsService.load();
    } catch (e) {
      settings = new AppSettings();
    }
    if (!settings.healthCheckEnabled) {
      AppLogger.info(TAG, `[health] disabled by settings; skip (${reason})`);
      return false;
    }
    this.healthRunning = true;
    try {
      AppLogger.info(TAG, `[health] self-check start (reason=${reason})`);
      const report = await runLinkHealthCheck(new OrchestratorHealthProbes(this));
      this.healthReport = report;
      const summary = summarize(report);
      this.healthSummaryCache = summary;
      AppLogger.info(TAG, `[health] report overall=${summary.overall} pass=${summary.passCount} fail=${summary.failCount} skip=${summary.skipCount} firstFail=${summary.firstFailId}`);
      this.notify();

      const steps = repairSteps(report, settings.healthRepairMaxSteps);
      this.healthRepairCache = steps;
      AppLogger.info(TAG, `[health] repair steps(max=${settings.healthRepairMaxSteps})=${steps.length === 0 ? '(none)' : steps.join(' > ')}`);
      let reconnectUsed = false;
      for (const step of steps) {
        if (this.disconnectRequested) {
          AppLogger.info(TAG, '[health] user disconnected; abort repair chain');
          break;
        }
        const r = await this.executeRepair(step, reconnectUsed);
        if (r.usedReconnect) {
          reconnectUsed = true;
        }
        AppLogger.info(TAG, `[health] repair ${step}: ${r.text}`);
        if (r.stop) {
          AppLogger.warn(TAG, `[health] repair halted: ${r.text}`);
          break;
        }
      }

      // 修复后重新自检一次
      const report2 = await runLinkHealthCheck(new OrchestratorHealthProbes(this));
      this.healthReport = report2;
      const summary2 = summarize(report2);
      this.healthSummaryCache = summary2;
      AppLogger.info(TAG, `[health] recheck overall=${summary2.overall} pass=${summary2.passCount} fail=${summary2.failCount} skip=${summary2.skipCount}`);
      this.notify();
      if (summary2.isOk()) {
        return true;
      }
      if (this.state === ConnState.CONNECTED) {
        AppLogger.info(TAG, '[health] degraded but connected; treat as recovered');
        return true;
      }
      this.lastError = summary2.failCount > 0
        ? `链路自检未通过（${summary2.firstFailLabel}：${summary2.firstFailDetail}）`
        : '链路自检未通过（存在无法判定项），已停止自动重试';
      AppLogger.warn(TAG, `[health] still broken after repair: ${this.lastError}`);
      return false;
    } catch (e) {
      AppLogger.warn(TAG, `[health] self-check failed: ${AppLogger.errText(e)}`);
      return false;
    } finally {
      this.healthRunning = false;
    }
  }

  /** 执行单个修复动作（有限、有序；重建类动作全链路最多一次） */
  private async executeRepair(action: string, reconnectUsed: boolean): Promise<RepairOutcome> {
    const r = new RepairOutcome();
    switch (action) {
      case RepairActions.REFRESH_SUBSCRIPTION: {
        const subs = this.lastSubs;
        if (subs === null) {
          r.text = '无订阅可刷新';
          r.stop = true;
          return r;
        }
        let okCount = 0;
        let failedCount = 0;
        const failedStatuses: string[] = [];
        for (const s of subs.subscriptions) {
          try {
            const result = await subs.refreshSubscription(s.id);
            if (result.status === SubscriptionRefreshStatus.OK
              || result.status === SubscriptionRefreshStatus.NOT_MODIFIED) {
              okCount = okCount + 1;
            } else {
              failedCount = failedCount + 1;
              failedStatuses.push(result.status);
              AppLogger.warn(TAG, `[health] refresh ${s.name} failed: ${result.status} ${result.message}`);
            }
          } catch (e) {
            failedCount = failedCount + 1;
            failedStatuses.push('exception');
            AppLogger.warn(TAG, `[health] refresh ${s.name} failed: ${AppLogger.errText(e)}`);
          }
        }
        const details = failedStatuses.length > 0 ? `，失败 ${failedCount}（${failedStatuses.join('/')}）` : '';
        r.text = `已刷新 ${okCount}/${subs.subscriptions.length} 个订阅${details}`;
        return r;
      }
      case RepairActions.RESELECT_NODE: {
        const switched = await this.tryFailover('health-reselect');
        r.text = switched ? '已切换到备用节点' : '未找到更优节点，保持当前节点';
        r.usedReconnect = switched;
        return r;
      }
      case RepairActions.REBUILD_TUN:
      case RepairActions.RESTART_CORE:
      case RepairActions.RESTART_CLASH_API: {
        if (reconnectUsed) {
          r.text = '本次已执行过重建，跳过多余重启（避免重连风暴）';
          return r;
        }
        const done = await this.repairReconnect();
        r.text = done ? '已重建隧道并重连' : '重建隧道失败';
        r.usedReconnect = true;
        if (!done) {
          r.stop = true;
        }
        return r;
      }
      case RepairActions.RECONCILE_INTENT: {
        const snap = await SettingsService.loadSnapshot();
        // 启动成功标记不是存活证据；无租约不能抹掉用户尚待恢复的连接意图。
        const alive = this.isCoreAliveByHeartbeat();
        const patched = alive && !this.disconnectRequested
          && await SettingsService.patchActiveSnapshot(snap.sessionGeneration,
            this.lastNodeName, this.startedAt, true);
        r.text = patched ? '已对齐同一会话的运行状态' : '保留用户意图：无有效运行证据或会话已变更';
        return r;
      }
      case RepairActions.FIX_DNS:
        r.text = 'DNS 由内核内置处理，已随隧道重建生效';
        return r;
      case RepairActions.CHECK_UPLINK:
        r.text = '上层物理网络受限，本地修复无法解决，请检查运营商/路由';
        return r;
      case RepairActions.GRANT_VPN_PERMISSION:
        r.text = '需要用户在系统弹窗中授予 VPN 权限，停止自动修复';
        r.stop = true;
        return r;
      case RepairActions.ENABLE_NOTIFICATIONS:
        r.text = '需要用户开启通知权限，停止自动修复';
        r.stop = true;
        return r;
      default:
        r.text = `未知修复动作(${action})，忽略`;
        return r;
    }
  }

  /** 重建隧道（有限一次）：断开 → 等待 → 用上次节点重连 */
  private async repairReconnect(): Promise<boolean> {
    const subs = this.lastSubs;
    if (subs === null || this.lastNodeName.length === 0) {
      return false;
    }
    if (this.state === ConnState.CONNECTING) {
      return false; // 单航班
    }
    const node = this.findNodeByName(subs, this.lastNodeName);
    if (node === null) {
      return false;
    }
    this.inRepairConnect = true;
    try {
      await this.disconnect();
      await new Promise<void>((resolve) => setTimeout(() => resolve(), 600));
      return await this.connect(node, subs);
    } catch (e) {
      AppLogger.warn(TAG, `[health] repairReconnect failed: ${AppLogger.errText(e)}`);
      return false;
    } finally {
      this.inRepairConnect = false;
    }
  }

  /** 内核死亡入口（监控循环调用）：有界，单航班 */
  private handleCoreLoss(): void {
    this.handleCoreLossAsync();
  }

  private async handleCoreLossAsync(): Promise<void> {
    if (this.coreLossHandling) {
      return;
    }
    this.coreLossHandling = true;
    try {
      let healthEnabled = true;
      try {
        const s = await SettingsService.load();
        healthEnabled = s.healthCheckEnabled;
      } catch (e) {
        healthEnabled = true;
      }
      if (healthEnabled) {
        // 集成点②：内核已死 → 先自检 → 有限修复 → 复核
        const recovered = await this.runHealthSelfCheckAndRepair('core-death');
        if (recovered) {
          AppLogger.info(TAG, '[health] core restored');
          return;
        }
        // 2026-10-19 保活整改：进程被系统 LowMemoryKill 回收是**外部事件**，
        // 不是用户意图。原实现自愈失败后直接落 DISCONNECTED 并放弃，导致
        // 被杀一次就永久断线、必须用户手动重进 App（真机取证：11 分钟内被杀
        // 3 次，每次都要手动恢复）。这里改为交给既有退避重连：用户意图仍为
        // "连接"时按指数退避重试，只有 intent=disconnected 或重试耗尽才放弃。
        if (this.disconnectRequested) {
          this.setState(ConnState.DISCONNECTED);
          if (this.lastError.length === 0) {
            this.lastError = '内核已死，链路自检与有限修复未能恢复，已停止自动重试';
          }
          this.notify();
          return;
        }
        AppLogger.warn(TAG, '[health] repair failed after core-death; '
          + 'escalating to bounded backoff reconnect (external kill is not user intent)');
        // 保留 lastError 供 UI 提示，但状态保持 RECOVERING，避免 UI 闪成"已断开"
        if (this.lastError.length === 0) {
          this.lastError = '内核已被系统回收，正在自动重连…';
        }
        this.setState(ConnState.RECOVERING);
        this.notify();
        this.reconnectManager().request(ReconnectReason.CORE_KILLED_BY_SYSTEM);
        return;
      }
      // 自检被关闭：退回既有有界恢复策略（最多 2 次）
      AppLogger.info(TAG, '[health] disabled; fallback to legacy bounded recovery');
      if (this.recoveryAttempts < 2 && this.lastSubs !== null) {
        this.recoveryAttempts = this.recoveryAttempts + 1;
        const node = this.findNodeByName(this.lastSubs, this.lastNodeName);
        if (node !== null) {
          await this.connect(node, this.lastSubs);
          return;
        }
      }
      this.setState(ConnState.DISCONNECTED);
      this.lastError = '内核异常退出，自动恢复失败，请手动重连';
      this.notify();
    } finally {
      this.coreLossHandling = false;
    }
  }

  // ══════════════════════════════════════════════════════════════════
  // 第二阶段集成点③：节点统计 + 连续失败 → 自动切换节点
  // ══════════════════════════════════════════════════════════════════

  /** 自动切换原因（最近一次，供 UI/通知展示）；空 = 从未切换 */
  autoSwitchReason(): string {
    return this.autoSwitchReasonText;
  }

  lastFailoverFromName(): string {
    return this.lastFailoverFrom;
  }

  lastFailoverToName(): string {
    return this.lastFailoverTo;
  }

  private findNodeByName(subs: SubscriptionService, name: string): ProxyNode | null {
    for (const n of subs.nodes) {
      if (n.name === name) {
        return n;
      }
    }
    // FlClash 同构（2026-10-22）：节点名以内核为准。订阅原文里的节点可能不在
    // App 解析表里（新协议 / 信息条目 / 被解析器丢弃）—— 此时用内核目录里的同名
    // 节点构造一个只读影子（配置由原文决定，节点对象只提供名字与延迟）。
    const model = CoreCatalogService.current();
    if (model !== null) {
      const entry = model.byName[name];
      if (entry !== undefined && !entry.isGroup) {
        return CoreNodeBridge.toProxyNode(entry);
      }
    }
    return subs.fallbackConnectionNode();
  }

  /** 连接成功：复位该节点连续失败计数（复用 NodeSortPersistence 快照记录） */
  private async recordNodeSuccess(name: string): Promise<void> {
    await this.updateNodeStats(name, true);
  }

  /** 连接失败：累加该节点连续失败计数 */
  private async recordNodeFailure(name: string): Promise<void> {
    await this.updateNodeStats(name, false);
  }

  /**
   * 更新节点统计并落盘（复用 AppSettings.nodeSortSnapshot = NodeSortSnapshot JSON）。
   * @returns 该节点更新后的连续失败次数
   */
  private async updateNodeStats(name: string, ok: boolean): Promise<number> {
    if (name.length === 0) {
      return 0;
    }
    try {
      const settings = await SettingsService.load();
      // 读也走分片视图（不再直接读整单里的旧字段 —— 那又是一份真源，审计 F2 / ND07）。
      let snap = NodeSortSnapshot.fromJsonText(await SettingsService.loadNodeSortSnapshot());
      if (snap === null) {
        snap = new NodeSortSnapshot();
      }
      let rec = snap.recordFor(name);
      if (rec === null) {
        rec = new NodeLatencyRecord();
        rec.name = name;
        rec.latency = LATENCY_UNTESTED;
        snap.records.push(rec);
      }
      if (ok) {
        rec.failCount = 0;
        rec.lastOk = true;
        // 只清理**旧版自动切换记账**留下的失败标记（latency=-1 且没有失败分类）：
        // 那不是测速结论，节点既然连上了就不该再顶着「超时」。
        // 真实的测速失败（带失败分类）保留 —— 它是一次真实结论，由 UI 按新鲜度展示。
        if (rec.latency < 0 && rec.failKind.length === 0) {
          rec.latency = LATENCY_UNTESTED; // 由后续测速填充
        }
      } else {
        rec.failCount = rec.failCount + 1;
        rec.lastOk = false;
        // ⚠ **不要**在这里写 `rec.latency = LATENCY_FAILED`（2026-10-20 真机反馈修复）：
        // 「一次连接失败」是**自动切换的记账**，不是「测速结论」。
        // 旧实现把两者写进同一个字段，后果是：
        //   ① 节点的**真实测速延迟被抹掉**；
        //   ② 冷启动恢复快照时，这条 -1 被渲染成一颗新鲜的红「超时」——
        //      用户看到的正是「刚打开软件还没测速就显示超时，测完发现节点是好的」。
        // 失败记账走 failCount / lastOk（选点评分照旧，见 candidateFromRecord），
        // 测速结论只由测速批次写。
      }
      // 字段级写入（F2 根因修复 + ND07 写者唯一）：
      // 连接记账（failCount / lastOk）只写**记账分片**，
      // 测速结论（latency / failKind / testedAt）由测速批次写**测速分片** ——
      // 两者互不覆盖；整单 save() 会把对方刚写的结论盖回旧值（审计 F2）。
      await SettingsService.saveNodeSortStats(snap.toJsonText());
      AppLogger.info(TAG, `[failover] node stat ${name}: ok=${ok} consecutiveFailures=${rec.failCount}`);
      return rec.failCount;
    } catch (e) {
      AppLogger.warn(TAG, `[failover] update node stats failed: ${AppLogger.errText(e)}`);
      return 0;
    }
  }

  private candidateFromRecord(name: string, snap: NodeSortSnapshot | null): NodeCandidate {
    const rec = snap === null ? null : snap.recordFor(name);
    if (rec === null) {
      return NodeCandidate.make(name, LATENCY_UNTESTED);
    }
    // 评分用的**有效延迟**：失败记账优先（与旧实现同口径 —— 旧实现是把
    // `rec.latency` 直接覆写成 -1，现在改成在这里派生，快照里的测速结论不再被污染）：
    //   · 有失败记账（failCount>0 且上次失败）→ 按失败计分；
    //   · 上次成功但没有有效测速结论 → 按未测计分；
    //   · 其余 → 用真实测速延迟。
    let effective: number = rec.latency;
    if (rec.failCount > 0 && !rec.lastOk) {
      effective = LATENCY_FAILED;
    } else if (rec.lastOk && rec.latency < 0) {
      effective = LATENCY_UNTESTED;
    }
    return NodeCandidate.fromStats(name, effective, rec.failCount, rec.lastOk, 0, 0);
  }

  private buildCandidates(subs: SubscriptionService, snap: NodeSortSnapshot | null): NodeCandidate[] {
    const list: NodeCandidate[] = [];
    for (const n of subs.nodes) {
      if (ClashConfigGenerator.proxyYamlLine(n).length === 0) {
        continue; // 仅有效节点参与评分
      }
      list.push(this.candidateFromRecord(n.name, snap));
    }
    return list;
  }

  /**
   * 连续失败达阈值 → 按 SmartSelector 选点并切换（受 failoverEnabled /
   * autoSelectMode=auto / 冷却 / 单航班约束）。切换后通知卡片与通知。
   * @returns 是否成功切换到并连上新的节点
   */
  private async tryFailover(trigger: string): Promise<boolean> {
    if (this.failoverRunning) {
      AppLogger.info(TAG, `[failover] already running; skip (${trigger})`);
      return false;
    }
    if (this.disconnectRequested) {
      AppLogger.info(TAG, `[failover] user-disconnected; skip (${trigger})`);
      return false;
    }
    const subs = this.lastSubs;
    if (subs === null || subs.nodes.length === 0) {
      return false;
    }
    let settings: AppSettings;
    try {
      settings = await SettingsService.load();
    } catch (e) {
      return false;
    }
    if (!settings.failoverEnabled) {
      AppLogger.info(TAG, `[failover] disabled by settings; skip (${trigger})`);
      return false;
    }
    if (settings.autoSelectMode !== AutoSelectModes.AUTO) {
      AppLogger.info(TAG, `[failover] autoSelectMode=manual (用户固定节点); skip (${trigger})`);
      return false;
    }
    if (this.state === ConnState.CONNECTING) {
      AppLogger.info(TAG, `[failover] connect in flight; skip (${trigger})`); // 单航班
      return false;
    }
    const now = Date.now();
    const cooldownMs = settings.failoverCooldownSec * 1000;
    if (this.lastFailoverAt > 0 && now - this.lastFailoverAt < cooldownMs) {
      AppLogger.info(TAG, `[failover] cooldown active ${now - this.lastFailoverAt}ms < ${cooldownMs}ms; skip (${trigger})`);
      return false;
    }
    const snap = NodeSortSnapshot.fromJsonText(await SettingsService.loadNodeSortSnapshot());
    const opts = new SelectorOptions();
    opts.failThreshold = settings.failoverFailureThreshold;
    opts.cooldownMs = cooldownMs;
    opts.autoSwitch = true;
    const cur = this.lastNodeName.length > 0 ? this.candidateFromRecord(this.lastNodeName, snap) : null;
    const fails = cur === null ? settings.failoverFailureThreshold : cur.consecutiveFailures;
    if (cur !== null && !failoverAllowed(cur, fails, now, opts)) {
      AppLogger.info(TAG, `[failover] not allowed (fails=${fails}, threshold=${opts.failThreshold}); skip (${trigger})`);
      return false;
    }
    const list = this.buildCandidates(subs, snap);
    const next = nextBestNode(cur, list, now, opts);
    if (next === null) {
      AppLogger.info(TAG, `[failover] no better eligible node; keep current (${trigger})`);
      return false;
    }
    this.lastFailoverFrom = this.lastNodeName;
    this.lastFailoverTo = next.name;
    this.lastFailoverAt = now;
    this.autoSwitchReasonText = `节点「${this.lastNodeName}」连续失败 ${fails} 次，自动切换至「${next.name}」`;
    AppLogger.info(TAG, `[failover] ${this.autoSwitchReasonText} (trigger=${trigger})`);
    // 通知卡片/通知状态
    this.notify();
    try {
      TaskProgressUpdater.updateLive(this.notifyNodeText(next.name),
        `↓ 0 B/s  ↑ 0 B/s`, this.connDurationText());
    } catch (e) {
      AppLogger.warn(TAG, `[failover] notify update failed: ${AppLogger.errText(e)}`);
    }
    const node = this.findNodeByName(subs, next.name);
    if (node === null) {
      return false;
    }
    this.failoverRunning = true;
    try {
      this.reconnectManager().resetAttempts();
      this.reconnectManager().cancel('failover-switch');
      const ok = await this.connect(node, subs);
      AppLogger.info(TAG, `[failover] switch to ${next.name} result=${ok}`);
      return ok;
    } finally {
      this.failoverRunning = false;
    }
  }

  // ══════════════════════════════════════════════════════════════════
  // OrchestratorHealthView：向链路自检探针暴露只读运行态
  // ══════════════════════════════════════════════════════════════════

  hasSubscriptions(): boolean {
    return this.lastSubs !== null && this.lastSubs.subscriptions.length > 0;
  }

  subsNodeCount(): number {
    return this.lastSubs === null ? 0 : this.lastSubs.nodes.length;
  }

  currentNodeName(): string {
    return this.lastNodeName;
  }

  /**
   * 展示用「当前连接节点」名称 —— **主页启动按钮与订阅页顶部概览卡共用这一个方法**，
   * 两处显示必然是同一节点（2026-10-25 用户要求：接口完全一致，不许各写一套）。
   *
   * 取值顺序（2026-10-27 架构收口：**内核真源优先**）：
   *   ① 自动模式且 smart 模型就位 → 「♻️ 自动选择」（出口由内核挑，名字不固定）
   *   ② `KernelSelectionManager` 记录的当前出口（本次/上次真实出口，连接期间由 refreshExitFromKernel
   *      持续与内核对齐）→ 用它。**这是唯一有资格代表"当前节点"的来源。**
   *   ③ preferredNodeId 在当前订阅内命中 → 该节点名（偏好缓存：仅未连接且无出口时）
   *   ④ fallbackConnectionNode() → 当前订阅第一个可用真实节点
   *   ⑤ '' → 当前订阅确实没有可用节点，由调用方给可行动文案
   *
   * 为什么 ② 不再限定 `state === CONNECTED`：用户在内核里换了出口（通知栏/组内自动
   * 切换/另一个入口），而偏好没同步时，只有内核真源能反映事实。旧实现以连接状态分叉
   * 或只读偏好，才会出现「UI 香港、实际新加坡」。
   */
  /** 订阅连接事件（状态/流量/出口）。返回 token，页面 aboutToDisappear 时退订。 */
  subscribeConnEvents(listener: ConnListener): number {
    return ConnectionEvents.subscribe(listener);
  }

  unsubscribeConnEvents(token: number): void {
    ConnectionEvents.unsubscribe(token);
  }

  /**
   * 状态写入的**唯一入口**（2026-10-27）：赋值 + 变化时推送事件。
   *
   * 直接写 `this.state = X` 会让订阅方收不到变化，退化成轮询 ——
   * 因此所有转换必须走这里（门禁 pc9 会检查）。
   */
  private setState(next: ConnState): void {
    if (this.state === next) { return; }
    if (!this.stateTransitionAllowed(next)) { return; }
    this.state = next;
    // 双通道：① 既有 listeners（HomePage 等）② 新事件总线（带载荷，供后续去轮询）
    this.notify();
    ConnectionEvents.emit(ConnEvent.state(next, this.startedAt));
  }

  /**
   * 状态迁移门禁（与 `setState` 分开只为让「赋值 + 推送」保持单入口且可读）。
   *
   * ① 用户主动断开后的「复活屏障」：迟到的网络/恢复回调不得把状态推回连接态；
   * ② 合法迁移动表：表外迁移直接拒绝并记录（不再允许任何代码随手赋值）。
   */
  private stateTransitionAllowed(next: ConnState): boolean {
    if (this.disconnectRequested && ConnectionStateMachine.blockedByUserDisconnect(true, next)) {
      AppLogger.warn(TAG, `state transition blocked after user disconnect: `
        + `${this.state} -> ${next}`);
      return false;
    }
    const violation: string | null = ConnectionStateMachine.explain(this.state, next);
    if (violation !== null) {
      AppLogger.warn(TAG, `${violation}（已拒绝；当前=${this.state}）`);
      return false;
    }
    return true;
  }

  /**
   * 「当前出口节点名」的统一读取口（2026-10-27，P1 命名收口）。
   *
   * 与旧的 `displayNodeName(preferredNodeId, autoSelectMode)` 的差别：
   * 调用方**不再传偏好相关参数** —— 偏好只是缓存，由本方法内部按优先级降级，
   * 接口本身就不给"用偏好决定当前节点"留口子。
   */
  getCurrentNodeName(): string {
    const s: AppSettings | null = SettingsService.peek();
    const autoMode: string = s !== null ? s.autoSelectMode : '';
    const preferredId: string = s !== null ? s.preferredNodeId : '';
    return this.displayNodeName(preferredId, autoMode);
  }

  /** 当前连接目标（组 + 节点 + 来源）；未确认过返回 null。 */
  getCurrentConnectionTarget(): ConnectionTarget | null {
    return this.kernelSelection.current();
  }

  /** @deprecated 用 getCurrentNodeName()；保留只为兼容既有调用点。 */
  displayNodeName(preferredNodeId: string, autoSelectMode: string): string {
    if (autoSelectMode === AutoSelectModes.AUTO && this.ensureSmartModelReady()) {
      return ClashConfigGenerator.SMART_GROUP_NAME;
    }
    // ① 已连接：**只认内核真源**（连接期间由 refreshExitFromKernel 与 /proxies 对齐）。
    //    「界面显示香港、实际走新加坡」从显示层消失的关键一步（2026-10-27 架构收口）：
    //    已连接时 preferredNode* 无权决定「当前是什么节点」。
    //
    // ② 未连接：**必须读用户意图**（偏好缓存）。原因：内核出口只有在连接/切换发生时
    //    才会更新；用户刚在节点页手选了一个节点、还没连接时，内核里仍是上一个出口。
    //    2026-10-27 真机回归：这里不看状态一律先读内核，导致「手选节点后，主页按钮和
    //    订阅页顶部仍显示上次那个节点，连接后才变」——本函数因此按状态分流。
    const svc = SubscriptionService.instance();
    const liveName: string = this.kernelSelection.nodeName();
    if (this.state === ConnState.CONNECTED && liveName.length > 0
      && svc.nodeByNameCurrent(liveName) !== null) {
      return liveName;
    }
    const peeked = SettingsService.peek();
    const preferredName: string = peeked !== null ? peeked.preferredNodeName : '';
    const preferred = svc.resolveUserPreference(preferredNodeId, preferredName);
    if (preferred !== null) {
      return preferred.name;
    }
    const fallback = svc.fallbackConnectionNode();
    if (fallback !== null) {
      return fallback.name;
    }
    return '';
  }

  /**
   * 用内核真源刷新「当前出口」（2026-10-27，显示层不再依赖偏好）。
   *
   * 连接期间周期调用：用户在内核里换了出口（通知栏/组内自动切换/其它入口），
   * 或自动模式优选到了别的节点，这里把当前出口与偏好缓存一起对齐；
   * UI 下一次渲染（`displayNodeName`）读到的就是事实，而不是旧偏好。
   */
  async refreshExitFromKernel(): Promise<void> {
    if (this.state !== ConnState.CONNECTED || this.api === null) {
      return;
    }
    try {
      const changed: ConnectionTarget | null =
        await this.kernelSelection.syncFromKernel(this.api, this.kernelSelection.groupName(),
          ProfileRepository.currentId());
      if (changed === null) { return; }
      this.lastNodeName = changed.nodeName;
      AppLogger.info(TAG, `exit changed on kernel: ${changed.label()}`);
      ConnectionEvents.emit(ConnEvent.exit(changed.groupName, changed.nodeName));
      await this.selfHealPreferredNode(changed.nodeName, [], '');
    } catch (e) {
      AppLogger.warn(TAG, `refresh exit from kernel failed: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * 「出口组 → 当前节点」的统一展示值（2026-10-27 架构收口）。
   * 例如 `吹雪云 → 🇭🇰香港•移联01`；尚未成功连接过则返回空串，由调用方回退到
   * preferredNode* 推导的「上次选择」。主页若要显示"组"，只读这一个方法。
   */
  connectionTargetLabel(): string {
    return this.kernelSelection.label();
  }

  /**
   * 内核真相的当前出口节点名：从规则面 PROXY 组（表里没有 PROXY 则 GLOBAL）沿
   * `now` 链下钻到叶子（PROXY → ♻️ 自动选择 → 具体节点），最多三层。
   * 返回 '' = 内核不可达 / 表里两个组都没有。
   * 供「当前连接节点」类展示用 —— lastNodeName 是连接时**请求**的节点，
   * 自动(smart)模式下内核实际选中的节点可能不同（0.6.3 用户实锤：订阅页
   * 显示「未选择」/上一次手动节点，而内核实际走的是智能优选的另一个节点）。
   */
  async resolveLiveNodeName(): Promise<string> {
    if (this.api === null) {
      AppLogger.info(TAG, 'resolveLiveNodeName: no api channel');
      return '';
    }
    const json = await this.api.proxiesJson();
    if (json === null) {
      AppLogger.info(TAG, 'resolveLiveNodeName: /proxies unavailable');
      return '';
    }
    try {
      const parsed = JSON.parse(json) as Record<string, Object>;
      const table = parsed['proxies'] as Record<string, Object>;
      if (table === undefined || table === null) { return ''; }
      // 入口优先级：PROXY → GLOBAL → smart 组直连（2026-10-25 真机：自动模式下
      // 订阅页拿不到内核真相，兜底直接读 smart 组自身的 now）。
      const hasProxy = table['PROXY'] !== undefined;
      const hasGlobal = table['GLOBAL'] !== undefined;
      if (!hasProxy && !hasGlobal && table[ClashConfigGenerator.SMART_GROUP_NAME] === undefined) {
        AppLogger.info(TAG, 'resolveLiveNodeName: no PROXY/GLOBAL/smart group in table');
        return '';
      }
      const name = hasProxy ? 'PROXY' : (hasGlobal ? 'GLOBAL' : ClashConfigGenerator.SMART_GROUP_NAME);
      let cursor = name;
      for (let depth = 0; depth < 3; depth++) {
        const entry = table[cursor] as Record<string, Object>;
        if (entry === undefined || entry === null) {
          return depth === 0 ? '' : cursor;
        }
        const now = entry['now'];
        if (typeof now !== 'string' || now.length === 0 || now === cursor) { return cursor; }
        const next = table[now] as Record<string, Object>;
        const type = (next !== undefined && next !== null && typeof next['type'] === 'string')
          ? next['type'] as string : '';
        if (type === 'Selector' || type === 'URLTest' || type === 'Fallback' || type === 'Smart') {
          cursor = now;
          continue;
        }
        return now;
      }
      return cursor;
    } catch (e) {
      return '';
    }
  }

  isCurrentNodeValid(): boolean {
    return this.lastNode !== null && ClashConfigGenerator.proxyYamlLine(this.lastNode).length > 0;
  }

  isHeartbeatAlive(): boolean {
    return this.isCoreAliveByHeartbeat();
  }

  isTunnelMarkerPresent(): boolean {
    return this.readStartOk();
  }

  async isDesiredConnected(): Promise<boolean> {
    try {
      const snap = await SettingsService.loadSnapshot();
      return snap.desiredConnected === true;
    } catch (e) {
      return false;
    }
  }

  async isIntentConsistent(): Promise<boolean> {
    const desired = await this.isDesiredConnected();
    const alive = this.isCoreAliveByHeartbeat() || this.readStartOk();
    return desired === alive;
  }

  startErrorText(): string {
    return this.readStartError();
  }

  isIpv6Enabled(): boolean {
    return this.ipv6Active;
  }

  async checkClashApiReachable(): Promise<boolean> {
    try {
      return await this.api.healthProbe();
    } catch (e) {
      return false;
    }
  }

  /**
   * DNS 自检：**问系统解析器**，而不是自己再去 doh.pub 问一遍。
   *
   * 旧实现拿 www.gstatic.com 去 doh.pub/alidns 做一次 DoH，判据是"第三方端点通不通"：
   *  - 通了只能证明公网 HTTPS 通，证明不了内核 DNS 是否正常；
   *  - 不通则报 fix-dns，而那个修复动作本来就是空操作，用户被误导。
   * 另外它还会把用户的探测域名再泄露一次给两家第三方解析商。
   *
   * 改用系统解析器后：隧道在时该查询走 VpnConfig.dnsAddresses（TUN sentinel 172.19.0.2）
   * → 被 TUN 接管 → any:53 劫持进内核 DNS 解析链路（redir-host：拿回真实地址）——
   * 这一次探测真正走的就是用户业务流量所走的那条 DNS 路径。隧道不在时它退化为
   * 普通系统解析，符合探针语义。
   */
  async checkDnsResolvable(): Promise<boolean> {
    try {
      const addresses = await connection.getAddressesByName('www.gstatic.com');
      return Array.isArray(addresses) && addresses.length > 0;
    } catch (e) {
      AppLogger.info(TAG, `dns self-check failed: ${AppLogger.errText(e)}`);
      return false;
    }
  }

  /**
   * IPv6 双栈端到端探针：客户端侧（系统解析器 → 隧道 DNS）能否拿到 AAAA。
   *
   * 必须用 `connection.getAddressesByName` 走**系统解析路径**（与普通应用一致）。
   * 不能用 Clash REST `/dns/query`：mihomo 那条路由绕过了 withResolver(ipv6=false)
   * （hub/route/dns.go:44），即使 dns.ipv6=false 也会返回 AAAA —— 会给出假阳性，
   * 正是这次报障里「看着有 v6、实际 AAAA 被清空」最容易踩的坑。
   */
  async checkIpv6Resolvable(): Promise<boolean> {
    try {
      // 注意：`getAddressesByName` 返回的是 **NetAddress 对象**（{address, family}），
      // 不是字符串数组（SDK @ohos.net.connection.d.ts:2258-2267，family 1=IPv4 / 2=IPv6）。
      const addresses = await connection.getAddressesByName('ipv6.google.com');
      if (!Array.isArray(addresses)) {
        return false;
      }
      for (let i = 0; i < addresses.length; i++) {
        const entry = addresses[i];
        if (entry === null || entry === undefined) {
          continue;
        }
        // family 优先；拿不到 family 时退回「地址里含冒号 ⇒ v6 字面量」。
        if (entry.family === 2) {
          return true;
        }
        if (typeof entry.address === 'string' && entry.address.indexOf(':') >= 0) {
          return true;
        }
      }
      return false;
    } catch (e) {
      AppLogger.info(TAG, `ipv6 self-check failed: ${AppLogger.errText(e)}`);
      return false;
    }
  }

  async checkEgressReachable(): Promise<boolean> {
    const client = http.createHttp();
    try {
      const resp = await client.request('https://www.gstatic.com/generate_204', {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 1500,
        readTimeout: 1500
      });
      return resp.responseCode === 204 || resp.responseCode === 200;
    } catch (e) {
      return false;
    } finally {
      client.destroy();
    }
  }

  /** 读取 VPN Extension 进程回写的启动错误（跨进程文件通道） */
  private readStartError(): string {
    if (this.context === null) {
      return '';
    }
    // fd 释放与长度上限统一由 privateFs.readCapped 保证（finally closeSync）
    const res: SyncReadResult = privateFs.readCapped(
      `${this.context.cacheDir}/${START_ERROR_FILE}`, MAX_STATE_FILE_BYTES);
    return res.ok ? res.text.trim() : '';
  }

  private clearStartError(): void {
    if (this.context === null) {
      return;
    }
    try {
      fs.unlinkSync(`${this.context.cacheDir}/${START_ERROR_FILE}`);
    } catch (e) {
      // 文件不存在属正常
    }
    try {
      fs.unlinkSync(`${this.context.cacheDir}/${START_OK_FILE}`);
    } catch (e) {
      // 文件不存在属正常
    }
    // Extension 权威态与心跳租约同属隧道生命周期，断开时一并清除，
    // 防止 UI 冷启动读到上一会话的陈旧 running 而误判为已连接。
    try {
      fs.unlinkSync(`${this.context.cacheDir}/${EXTENSION_STATUS_FILE}`);
    } catch (e) {
      // 文件不存在属正常
    }
    // 拉起送达标记随启动生命周期复位（判定本身按时间戳过滤，清盘只为留痕干净）
    try {
      fs.unlinkSync(`${this.context.cacheDir}/${LAUNCH_EPOCH_FILE}`);
    } catch (e) {
      // 文件不存在属正常
    }
  }

  /**
   * 把本次隧道路由参数快照写入共享文件，供扩展进程在 want.parameters 被系统
   * 丢弃时回退（真机实证 2026-09-19：新装首连经授权弹窗重建扩展 want →
   * 防泄漏门禁误杀首连）。文件只含模式/包名/复核标记，无凭据；仍按 0600 写，
   * 且带 configPath+ts 双校验绑定本次拉起。写失败不阻断连接 —— 参数完整的
   * want 本身就是主通道，扩展侧另有同指纹的 UI 重试兜底。
   */
  private writeStartParamsFile(configPath: string, mode: string, needsReview: boolean,
    packagesJson: string): void {
    if (this.context === null) {
      return;
    }
    try {
      // arkts-no-untyped-obj-literals：落盘结构用显式类声明（字段名即 JSON 键）
      const rec = new StartParamsRecord();
      rec.configPath = configPath;
      rec.appRoutingMode = mode;
      rec.appRoutingNeedsReview = needsReview;
      rec.appRoutingPackagesJson = packagesJson;
      rec.ts = Date.now();
      privateFs.writePrivate(`${this.context.cacheDir}/${START_PARAMS_FILE}`, JSON.stringify(rec));
    } catch (e) {
      AppLogger.warn(TAG, `start params snapshot failed: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * 轮询扩展进程 onCreate 落下的 epoch 标记；出现 ≥floorTs 的时间戳即确认本次
   * 拉起送达。stop→start 在旧进程退出未完成时被系统吞并没有任何错误可查
   * （VpnExtensionAbility 只有 onCreate，存活进程不回调），只能靠这个正向信号。
   */
  private async awaitLaunchEpoch(floorTs: number): Promise<boolean> {
    if (this.context === null) {
      return false;
    }
    const deadline = Date.now() + LAUNCH_EPOCH_WAIT_MS;
    while (Date.now() < deadline) {
      const res: SyncReadResult = privateFs.readCapped(
        `${this.context.cacheDir}/${LAUNCH_EPOCH_FILE}`, MAX_STATE_FILE_BYTES);
      if (res.ok) {
        const epoch = Number(res.text.trim());
        if (Number.isFinite(epoch) && epoch >= floorTs) {
          return true;
        }
      }
      await new Promise<void>((resolve) => setTimeout(() => resolve(), LAUNCH_EPOCH_POLL_MS));
    }
    return false;
  }

  private invalidateStateProbeCache(): void {
    this.stateProbeCachedAt = 0;
    this.stateProbeStartOk = false;
    this.stateProbeHeartbeatAge = -1;
  }

  /**
   * 同步刷新探针缓存（**仅限同步上下文**，如 readStartOk 的既有调用点）。
   *
   * 2026-10-19 保活整改（真机取证 THREAD_BLOCK_3S，pid 4616 主线程卡 3 秒）：
   * 本函数内含 fs.statSync + 同步读文件，每次都是主线程阻塞 IO。原实现被
   * 3 秒存活监控定时器每轮直接调用（缓存仅 120ms，等于每轮必刷），
   * 主线程因此被反复阻塞 —— 自愈/重连逻辑跑在主线程上，一卡就整个失效。
   * 监控循环已改走 refreshStateProbeCacheAsync()，本函数只保留给同步调用点。
   */
  private refreshStateProbeCache(nowMs: number): void {
    if (this.context === null) {
      this.invalidateStateProbeCache();
      return;
    }
    if (this.stateProbeCachedAt > 0 && nowMs - this.stateProbeCachedAt < STATE_PROBE_CACHE_MS) {
      return;
    }
    try {
      fs.statSync(`${this.context.cacheDir}/${START_OK_FILE}`);
      this.stateProbeStartOk = true;
    } catch (e) {
      this.stateProbeStartOk = false;
    }
    const res: SyncReadResult = privateFs.readCapped(
      `${this.context.cacheDir}/${HEARTBEAT_FILE}`, MAX_STATE_FILE_BYTES);
    this.stateProbeHeartbeatAge = res.ok ? heartbeatAgeFromText(res.text, nowMs) : -1;
    this.stateProbeCachedAt = nowMs;
  }

  /**
   * 异步刷新探针缓存（监控定时器等异步上下文专用）。
   * 用 promise 版 stat/read 把阻塞 IO 让出主线程，避免 THREAD_BLOCK_3S。
   */
  private async refreshStateProbeCacheAsync(nowMs: number): Promise<void> {
    if (this.context === null) {
      this.invalidateStateProbeCache();
      return;
    }
    if (this.stateProbeCachedAt > 0 && nowMs - this.stateProbeCachedAt < STATE_PROBE_CACHE_MS) {
      return;
    }
    // 先占位时间戳，避免同一事件循环内并发重入重复读盘
    this.stateProbeCachedAt = nowMs;
    const startOkPath = `${this.context.cacheDir}/${START_OK_FILE}`;
    const heartbeatPath = `${this.context.cacheDir}/${HEARTBEAT_FILE}`;
    try {
      await fs.stat(startOkPath);
      this.stateProbeStartOk = true;
    } catch (e) {
      this.stateProbeStartOk = false;
    }
    try {
      const text = await privateFs.readCappedAsync(heartbeatPath, MAX_STATE_FILE_BYTES);
      this.stateProbeHeartbeatAge = text.ok ? heartbeatAgeFromText(text.text, nowMs) : -1;
    } catch (e) {
      this.stateProbeHeartbeatAge = -1;
    }
  }

  /** 异步版心跳年龄（供监控循环使用，不阻塞主线程） */
  private async readHeartbeatAgeAsync(): Promise<number> {
    const nowMs = Date.now();
    await this.refreshStateProbeCacheAsync(nowMs);
    if (this.stateProbeHeartbeatAge < 0) {
      return -1;
    }
    return this.stateProbeHeartbeatAge + Math.max(0, nowMs - this.stateProbeCachedAt);
  }

  /**
   * 异步版存活三态判定（监控循环用）。
   *
   * 2026-10-20 自动断开整改：旧实现只返回 true/false，把「心跳读不到」与
   * 「心跳过期」压成同一个 false，UI 于是把一次读失败当成分身死亡直接拆隧道。
   * 现在区分三态：
   *  - ALIVE   心跳新鲜
   *  - STALE   心跳过期（强证据：刷新方失联）
   *  - UNKNOWN 心跳读不到（弱证据：可能只是读失败，或文件刚被清理）
   */
  private async probeLivenessAsync(): Promise<LivenessVerdict> {
    const age = await this.readHeartbeatAgeAsync();
    if (age < 0) {
      return LivenessVerdict.UNKNOWN;
    }
    return age < HEARTBEAT_STALE_MS ? LivenessVerdict.ALIVE : LivenessVerdict.STALE;
  }

  /** 扩展进程是否已回写启动成功标记；同一同步周期复用短时探针缓存。 */
  private readStartOk(): boolean {
    this.refreshStateProbeCache(Date.now());
    return this.stateProbeStartOk;
  }

  /** 读取扩展进程心跳距今毫秒数；-1 = 无心跳/读取失败 */
  private readHeartbeatAge(): number {
    const nowMs = Date.now();
    this.refreshStateProbeCache(nowMs);
    if (this.stateProbeHeartbeatAge < 0) {
      return -1;
    }
    return this.stateProbeHeartbeatAge + Math.max(0, nowMs - this.stateProbeCachedAt);
  }

  /** 内核存活判定：扩展进程心跳新鲜即存活（UI 进程的 coreBridge 实例与扩展进程无关，不可用） */
  private isCoreAliveByHeartbeat(): boolean {
    const age = this.readHeartbeatAge();
    return age >= 0 && age < HEARTBEAT_STALE_MS;
  }

  /** headless 测速内核: 未连接时预启动真实协议栈做端到端测速 */
  /** @deprecated 仅作兼容读出口，真实状态看 testCoreFlight.getStatus() */
  testCoreActive: boolean = false;
  private testCoreSecret: string = '';
  /**
   * 测速核**实际**使用的 api 端口（可能与隧道核不同 —— 测速核用自己探测的端口，
   * 不写回共享字段，审计 F1）。客户端 setEndpoint 必须用这个端口。
   */
  private testCoreApiPort: number = 0;
  /**
   * 测速内核「预计变热」的时间戳（ms）。0 = 无预热窗口（不是测速核）。
   * 内核刚就绪时设成 now + TEST_CORE_WARMUP_MS；复用时窗口早已过去 → 不等待。
   */
  private testCoreWarmAt: number = 0;
  /** 单航班状态机：并发启动只生效一次，超时可取消，启停不互损 */
  private testCoreFlight: SingleFlightTestCore | null = null;
  /**
   * 启动失败后的负缓存截止时间戳（ms）。0 = 无冷却。
   * 内核确实拉不起来时不能每次测速都白等 15~20s 的启动超时；冷却期内直接返回
   * false，页面按既有约定降级成「端口可达」，绝不冒充代理延迟。
   */
  private testCoreNegativeUntil: number = 0;
  /**
   * 测速核当前配置所对应的**节点集指纹**（'' = 未登记 / 无有效配置）。
   * 复用测速核前必须比对：探活只能证明 controller 活着，证明不了「配置里含有
   * 当前这些节点」（真机 2026-10-20：导入新订阅后 /version 200，但 /delay 全
   * 404 → UI 整屏「未生效」）。指纹口径见 SubscriptionService.nodeSetFingerprint。
   */
  private testCoreNodeFingerprint: string = '';
  /** 超时/停止后，即使 DoH 或原生校验晚到，也不能继续拉起共享扩展。 */
  private testCoreLaunchGeneration: number = 0;

  /** 懒建状态机（依赖 this.context，调用前须已 init） */
  private getTestCoreFlight(): SingleFlightTestCore {
    if (this.testCoreFlight === null) {
      this.testCoreFlight = new SingleFlightTestCore({
        startFn: (): Promise<boolean> => this.launchTestCore(),
        cancelFn: (): Promise<void> => this.teardownTestCore(),
        timeoutMs: 15000,
        onStatusChange: (status: TestCoreStatus): void => {
          this.testCoreActive = status === TestCoreStatus.ACTIVE;
        }
      });
    }
    return this.testCoreFlight;
  }

  /**
   * 单飞状态机是否自认 ACTIVE（**仅进程内状态**，不代表 controller 可用）。
   * 生产判定必须用 verifyTestCoreChannel() / isTestCoreServing()：ACTIVE 只说明
   * 「本进程里曾经启动成功过」，与扩展进程是否还在、跑的是哪份配置/secret 无关。
   * 二次进入节点页全部 /delay 非 200 的根因就是只信了这个布尔量。
   */
  isTestCoreActive(): boolean {
    return this.testCoreFlight !== null && this.testCoreFlight.isActive();
  }

  /**
   * 测速内核通道真实可用判据（四者一致才算就绪）：
   *   1) 本进程持有本班次的测速 secret；
   *   2) endpoint 端口 = 测速核自己的 api 端口（不与隧道核共用）；
   *   3) endpoint secret = 本班次 secret；
   *   4) 真实探测 GET /version 返回 200（进程存活 + secret 被内核接受）。
   */
  async verifyTestCoreChannel(): Promise<boolean> {
    if (this.testCoreSecret.length === 0) {
      return false;
    }
    if (this.testCoreApiPort <= 0 || this.api.currentPort() !== this.testCoreApiPort
      || !this.api.hasSecret(this.testCoreSecret)) {
      AppLogger.warn(TAG, 'test core channel verify failed: endpoint port/secret mismatch');
      return false;
    }
    const probe = await this.api.probeController(1500);
    if (!probe.secretAccepted) {
      AppLogger.warn(TAG, `test core channel verify failed: reachable=${probe.reachable} `
        + `code=${probe.httpCode} detail=${probe.detail}`);
      return false;
    }
    return true;
  }

  /** 测速内核是否正在服务（状态机 ACTIVE + 通道真实可用） */
  async isTestCoreServing(): Promise<boolean> {
    if (this.testCoreFlight === null || !this.testCoreFlight.isActive()) {
      return false;
    }
    return this.verifyTestCoreChannel();
  }

  /** 启动失败负缓存是否生效（页面据此直接走「端口可达」降级，不白等启动超时） */
  isTestCoreNegativeCached(): boolean {
    return Date.now() < this.testCoreNegativeUntil;
  }

  /**
   * 为延迟测试提供一个**带全部真实节点**的 controller 句柄（延迟测试重做的唯一入口）。
   *
   * 为什么需要它：mihomo 的探测直接 `p.DialContext` 到出站适配器、绕过 TUN，
   * 所以只要内核已加载就能测出真实代理延迟 —— 与 VPN 是否连接无关。于是有两条
   * 路径，优先复用已存在的内核，避免任何多余的启动：
   *
   *  1. **已连接**：隧道内核就在 `apiPort` 且带着全部节点（实测 106 节点 / 16 组）
   *     → 直接返回 `this.api`，零额外启动、零额外内存。
   *  2. **未连接**：复用既有的 headless 测速内核（无 TUN、独立 secret），
   *     它解析配置是毫秒级。
   *
   * 两条都不可用时返回 **null** —— 调用方必须据此走「离线粗略通道」或明确提示，
   * **绝不能把 null 当成"全部节点超时"**（旧实现的 143 节点全超时就是这么来的）。
   */
  async ensureLatencyApi(manual: boolean = false): Promise<ClashApiService | null> {
    // 1) 真实隧道优先：它已经带着完整节点表，且是唯一权威的运行时配置
    if (this.state === ConnState.CONNECTED || this.state === ConnState.CONNECTING) {
      if (await this.api.healthProbe()) {
        // 隧道配置新鲜度（2026-10-20）：订阅集合变了以后隧道配置里缺新节点，
        // 新节点不在内核代理表 → 测速 /delay 404 → UI「未生效」。热重载把当前
        // 节点集重新写进内核（不拆隧道、不掉线）。
        await this.ensureTunnelConfigFresh();
        AppLogger.info(TAG, 'latency channel: reusing connected tunnel controller');
        return this.api;
      }
      AppLogger.warn(TAG, 'latency channel: tunnel state is CONNECTED but controller is unresponsive');
    }
    // 2) 未连接：尝试 headless 测速内核（复用既有 ensureTestCore，含负缓存与安全门禁）
    //    订阅来源优先用本次会话连接过的，其次用全局单例 —— 冷启动后用户可能一次都
    //    没连接过（lastSubs 为 null），此时仍应能测速，否则未连接测速会退化成离线粗略值。
    const subs: SubscriptionService = this.lastSubs !== null
      ? this.lastSubs : SubscriptionService.instance();
    if (this.context !== null && (subs.nodes.length > 0 || subs.hasUsableProfile())) {
      try {
        const ready = await this.ensureTestCore(subs, await this.lastSettingsForLatency(), manual);
        if (ready) {
          AppLogger.info(TAG, 'latency channel: headless test core ready');
          // 预热等待（2026-10-20 整改）：不再是「无条件睡 1500ms」，
          // 而是「等到这个内核真正变热的时刻」。
          //  - 新鲜启动：预热窗口刚开 → 等满剩余窗口（与旧实现同长，总耗时不变）；
          //  - 复用已在服务的内核：窗口早已过去 → **不等待 → 秒开**。
          // 旧实现那句无条件 1500ms 正是「点了测速要等一秒半才开始」的直接来源之一。
          await this.awaitTestCoreWarmup();
          // 每一次取通道都把回收窗口往后推 90s：否则「进页面预热」挂的那次回收
          // 可能在用户随后发起的一批测速**进行中**触发 → 把正在服务的测速核停掉，
          // 整批中止。回收窗口应当从「最后一次使用」起算。
          this.scheduleTestCoreRecycle(TEST_CORE_IDLE_RECYCLE_MS);
          return this.api;
        }
      } catch (e) {
        AppLogger.warn(TAG, `latency channel: ensureTestCore failed: ${AppLogger.errText(e)}`);
      }
    } else {
      AppLogger.info(TAG, `latency channel: headless core not attempted `
        + `(context=${this.context !== null} nodes=${subs.nodes.length})`);
    }
    AppLogger.info(TAG, 'latency channel: no core available (offline fallback applies)');
    return null;
  }

  /**
   * 等到「测速内核真正变热」为止。
   *
   * 背景：headless 内核 ready 后 controller API 仍是冷的（首批连接/凭证初始化
   * 未完成），立刻放行整批并发会把 API 打到 Operation timeout（真机取证
   * 2026-10-17：code=2300028，整批中止）。所以内核刚起来后有一个**预热窗口**。
   *
   * 关键设计（2026-10-20）：预热窗口是**内核的属性**（testCoreWarmAt），
   * 不是调用方的固定等待：
   *  - 复用已在服务的内核 → 窗口早已过去 → 一句都不等 → **秒开**；
   *  - 新鲜启动 → 等满剩余窗口（与旧实现同长）。
   * 旧实现是在 ensureLatencyApi 里无条件睡 1500ms，复用路径也在白等 ——
   * 这正是用户反馈「点了测速要等几秒才开始」的直接来源之一。
   */
  private async awaitTestCoreWarmup(): Promise<void> {
    const warmAt = this.testCoreWarmAt;
    if (warmAt <= 0) {
      return;
    }
    const waitMs = warmAt - Date.now();
    if (waitMs <= 0) {
      return;
    }
    await new Promise<void>((resolve) => setTimeout(() => resolve(), waitMs));
    AppLogger.info(TAG, `latency channel: test core warm-up wait ${waitMs}ms`);
  }

  /**
   * 预热测速通道（**不发起任何探测**，只让内核进入可服务状态）。
   *
   * ## 为什么需要它（真机取证 2026-10-20）
   *
   * 用户反馈「点了测速以后，等几秒钟才开始测速」。实测时间线（未连接场景）：
   *
   *   tap → ensureLatencyApi() → ensureTestCore() → DoH 预解析 133 个域名（~850ms）
   *        → 生成/写配置（~55ms）→ 停旧扩展（+600ms 固定等待）→ 启扩展进程（~165ms）
   *        → 内核就绪轮询（~190ms）→ **固定预热 1500ms** → 才发出第一个探测
   *
   * 也就是说用户点下去后要等 ~3s 才看到第一个结果 —— 而这些准备**与用户意图无关**，
   * 完全可以提前做完。预热把这段准备挪到「进入订阅页 / 节点选择页」时后台进行，
   * 用户点「测速」时通道已经热好 → **秒开**。
   *
   * ## 安全边界
   *
   *  - 已连接/连接中 → 复用真实隧道 controller，无需预热（ensureLatencyApi 内已判）；
   *  - 编排器忙（连接中/断开中/恢复中）或真实隧道是权威 → ensureTestCore 内部的安全门禁会拒绝启动；
   *  - 预热**不产生任何网络探测**，不写延迟结论，不动排序快照；
   *  - 预热成功后必须挂回收，否则内核会一直常驻（与批测后的回收同窗口）。
   */
  async prewarmLatencyChannel(): Promise<boolean> {
    try {
      const api = await this.ensureLatencyApi();
      if (api === null) {
        AppLogger.info(TAG, 'latency channel prewarm: no core available');
        return false;
      }
      // 预热本身没有批次跑完 → 引擎的「批后回收」不会被挂上，这里补挂一次，
      // 否则内核会常驻到进程结束（空转发、占端口）。
      this.scheduleTestCoreRecycle(TEST_CORE_IDLE_RECYCLE_MS);
      AppLogger.info(TAG, 'latency channel prewarmed');
      return true;
    } catch (e) {
      AppLogger.warn(TAG, `latency channel prewarm failed: ${AppLogger.errText(e)}`);
      return false;
    }
  }

  /**
   * 批测中途通道失联时的自愈：重新下发内核凭证并复探。
   *
   * 为什么需要它（真机实证）：一次 106 节点的批测跑到 53 个时隧道内核重启
   * （扩展进程 PID 变更、external-controller 的 secret 随之失效），其后所有
   * `/delay` 全部连接异常 —— 旧实现把这一片异常盖章成"节点失败"，用户看到
   * 半张列表变红。现在引擎连续失联时会调这里救一次。
   *
   * 凭证来源用**既有的权威通道**：`SettingsService.getApiSecret()`（系统加密
   * AssetStore，connect() 每次生成并落盘）+ `applyRealTunnelEndpoint()`（内含
   * "测速内核正在服务时不得覆盖"的保护）。不要自己去解析 yaml —— secret 的
   * 权威存储是 AssetStore，配置文件只是它的下游产物。
   *
   * @returns 是否恢复成功（重新下发后复探通过）
   */
  async refreshLatencyEndpoint(api: ClashApiService): Promise<boolean> {
    try {
      const secret = await SettingsService.getApiSecret();
      if (secret.length === 0) {
        AppLogger.warn(TAG, 'latency channel recovery: no stored api secret');
        return false;
      }
      const applied = await this.applyRealTunnelEndpoint(secret);
      if (!applied) {
        // 测速内核正在服务（未连接场景）：那它用的就是本进程持有的测速 secret
        if (this.testCoreSecret.length > 0) {
          // 测速核的端口**不与隧道核共用**（审计 F1 / F9）：这里下发的是测速核
          // 自己的端口，否则会对着隧道端口发测速 secret ⇒ 整批「内核未就绪」。
          const corePort = this.testCoreApiPort > 0 ? this.testCoreApiPort : this.apiPort;
          api.setEndpoint(corePort, this.testCoreSecret);
        } else {
          return false;
        }
      }
      if (await api.healthProbe()) {
        this.apiSecret = secret;
        AppLogger.info(TAG, 'latency channel recovered: endpoint re-issued and probe passed');
        return true;
      }
      AppLogger.warn(TAG, 'latency channel recovery: endpoint re-issued but probe still failed');
      return false;
    } catch (e) {
      AppLogger.warn(TAG, `latency channel recovery failed: ${AppLogger.errText(e)}`);
      return false;
    }
  }

  /** 取当前设置（延迟测试路径用；读盘失败回落默认值，不阻断测速） */
  private async lastSettingsForLatency(): Promise<AppSettings> {
    try {
      return await SettingsService.load();
    } catch (e) {
      return new AppSettings();
    }
  }

  /**
   * 零节点时补一次订阅拉取（每个会话只补一次）。
   *
   * 为什么放在连接漏斗里而不是各调用方：连连接口有 9 个调用点（主页、节点页、
   * 快捷方式、卡片、故障切换、自检修复…），逐个加护栏必然漏。漏斗内部拦一次，
   * 任何入口都拦得住 —— 且这里能拿到最权威的 nodes 视图。
   */
  private async autoRefreshForZeroNodes(subs: SubscriptionService): Promise<void> {
    if (this.zeroNodeAutoRefreshDone) {
      return;
    }
    this.zeroNodeAutoRefreshDone = true;
    const enabled = subs.subscriptions.filter((s) => s.enabled);
    if (enabled.length === 0) {
      AppLogger.warn(TAG, 'zero nodes and no enabled subscription; nothing to auto-refresh');
      return;
    }
    AppLogger.info(TAG, `zero nodes on connect; auto-refreshing ${enabled.length} subscription(s)`);
    for (const s of enabled) {
      try {
        const result = await subs.refreshSubscription(s.id);
        if (result.status !== SubscriptionRefreshStatus.OK
          && result.status !== SubscriptionRefreshStatus.NOT_MODIFIED) {
          AppLogger.warn(TAG, `zero-node auto refresh ${s.name} failed: ${result.status} ${result.message}`);
        }
      } catch (e) {
        AppLogger.warn(TAG, `zero-node auto refresh ${s.name} threw: ${AppLogger.errText(e)}`);
      }
    }
    AppLogger.info(TAG, `zero-node auto refresh done: nodes=${subs.nodes.length}`);
  }

  /**
   * 确保 headless 测速内核在跑。并发调用共享同一航班：
   * 只有第一次真正走 stop→start，其余复用同一 Promise，
   * 避免「后到的启动把先到的扩展停掉」的互相 stop。
   */
  async ensureTestCore(subs: SubscriptionService, settings: AppSettings, manual: boolean = false): Promise<boolean> {
    if (this.context === null || (subs.nodes.length === 0 && !subs.hasUsableProfile())) {
      return false;
    }
    const flight = this.getTestCoreFlight();
    if (flight.isActive()) {
      // 配置新鲜度闸门（2026-10-20 整改）：内核代理表必须与当前节点集一致。
      // **探活证明不了配置是新的**：/version 照样 200，但配置里没有新节点时
      // /delay 全 404 → UI「未生效」（真机：导入新订阅后测速整屏未生效）。
      // 不一致就重建（配置按当前节点集重新生成），再谈探活。
      const staleConfig: boolean = this.testCoreNodeFingerprint.length > 0
        && (this.testCoreNodeFingerprint !== SubscriptionService.nodeSetFingerprint(subs.nodes)
          || this.appliedProfileId !== ProfileRepository.currentId()
          || this.appliedProfileRevision !== ProfileRepository.revisionOf(ProfileRepository.currentId()));
      if (staleConfig) {
        AppLogger.info(TAG, 'test core config is stale (node set changed); rebuilding test core');
        await this.stopTestCore();
      } else {
        // 就绪判据 = controller 实际可用（端口 + secret + 真实 /version 探测），
        // 不能只看进程内状态机 ACTIVE：内核已死或 secret 被别的路径覆盖时，
        // 旧实现直接 return true，导致整批 /delay 非 200（真机 143 节点全超时）。
        if (await this.verifyTestCoreChannel()) {
          this.testCoreNegativeUntil = 0;
          return true;
        }
        // 通道可能只是被覆盖了 secret：先用本班次 secret 重新下发并复探一次
        if (this.testCoreSecret.length > 0) {
          // 测速核的端口不与隧道核共用：优先用本班次记录的测速核端口 ✓
          const corePort = this.testCoreApiPort > 0 ? this.testCoreApiPort : this.apiPort;
          this.api.setEndpoint(corePort, this.testCoreSecret);
          if (await this.verifyTestCoreChannel()) {
            AppLogger.info(TAG, 'test core channel recovered by re-issuing endpoint secret');
            this.testCoreNegativeUntil = 0;
            return true;
          }
        }
        AppLogger.warn(TAG,
          'test core marked ACTIVE but controller unusable; tearing down and relaunching');
        await this.stopTestCore();
      }
    }
    // 安全门禁（防「互相 stop」）：headless 测速内核的启动流程第一步就是
    // stopVpnExtensionAbility —— 若此刻真实隧道正在建立/已连接/恢复中，那一步
    // 会把用户正在用的 VPN 直接停掉。不能只信任调用方传入的进程内 state
    // （新进程 state 恒为 DISCONNECTED），必须用权威判据再复判一次。
    if (this.state === ConnState.CONNECTING || this.state === ConnState.CONNECTED
      || this.state === ConnState.DISCONNECTING || this.state === ConnState.RECOVERING) {
      AppLogger.info(TAG, `ensureTestCore skipped: orchestrator busy (state=${this.state})`);
      return false;
    }
    try {
      const authority = await this.authorityState();
      if (authority.connected) {
        AppLogger.info(TAG, `ensureTestCore skipped: real tunnel is authoritative (${authority.reason})`);
        return false;
      }
      const snapshot = await SettingsService.loadSnapshot();
      if (snapshot.desiredConnected
        && ['connecting', 'connected', 'recovering'].includes(snapshot.phase)) {
        // 冷启动暂未确认存活时，也不能让预热测速核 stop 掉可能仍在转发的真实隧道。
        if (!manual || snapshot.phase !== 'connected' || Date.now() - snapshot.savedAt < 30000) {
          AppLogger.info(TAG, 'ensureTestCore skipped: real session intent is still active/unconfirmed');
          return false;
        }
        // Only an explicit test may recover an abandoned upgrade session.
        // Never stop a responding controller, including one rejecting our secret.
        if (!await this.restoreTunnelController(snapshot, false)) { return false; }
        const probe = await this.api.probeController(1000);
        if (probe.reachable) { return false; }
        await new Promise<void>((resolve) => setTimeout(resolve, 250));
        const confirmed = await this.authorityState();
        if (confirmed.coreAlive || !await this.isCurrentSession(snapshot.sessionGeneration)
          || this.state !== ConnState.DISCONNECTED) { return false; }
        AppLogger.info(TAG, 'manual delay: abandoned session has no controller; starting headless core');
      }
    } catch (error) {
      // 读不到持久化意图时按「未连接」继续：不能因一次读盘失败就永久禁用测速内核。
      AppLogger.warn(TAG,
        `ensureTestCore authority probe failed: ${AppLogger.errText(error)}`);
    }
    if (this.isTestCoreNegativeCached()) {
      AppLogger.info(TAG, 'ensureTestCore skipped: negative cache cooling down');
      return false;
    }
    this.testCoreSubs = subs;
    this.testCoreSettings = settings;
    const started = await flight.ensure();
    if (started) {
      this.testCoreNegativeUntil = 0;
    } else {
      this.testCoreNegativeUntil = Date.now() + TEST_CORE_NEGATIVE_COOLDOWN_MS;
      AppLogger.warn(TAG,
        `ensureTestCore failed; negative cache ${TEST_CORE_NEGATIVE_COOLDOWN_MS}ms`);
    }
    return started;
  }

  /** 本次航班的输入（启动时才读取，避免并发覆盖） */
  private testCoreSubs: SubscriptionService | null = null;
  private testCoreSettings: AppSettings | null = null;

  /** 内核日志流（/logs WebSocket）：测速诊断用，随 teardown 释放 */
  private coreLogSocket: webSocket.WebSocket | null = null;

  /** 订阅内核日志流并转发进 AppLogger（hilog 可远程排查拨号失败原因） */
  private startCoreLogStream(secret: string): void {
    if (this.coreLogSocket !== null) {
      return;
    }
    try {
      const ws = webSocket.createWebSocket();
      ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
        if (err) {
          return;
        }
        const text = typeof value === 'string'
          ? value
          : util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(value));
        AppLogger.info('CoreLog', text);
      });
      ws.on('close', () => {
        if (this.coreLogSocket === ws) {
          this.coreLogSocket = null;
        }
      });
      ws.on('error', (err: BusinessError) => {
        AppLogger.warn(TAG, `core log stream error: ${err.message ?? ''}`);
        if (this.coreLogSocket === ws) {
          this.coreLogSocket = null;
        }
      });
      ws.connect(`ws://127.0.0.1:${this.apiPort}/logs?token=${encodeURIComponent(secret)}`, (err: BusinessError) => {
        if (err) {
          AppLogger.warn(TAG, `core log stream connect failed: ${err.message ?? ''}`);
          if (this.coreLogSocket === ws) {
            this.coreLogSocket = null;
          }
        }
      });
      this.coreLogSocket = ws;
    } catch (e) {
      AppLogger.warn(TAG, `core log stream start failed: ${AppLogger.errText(e)}`);
    }
  }

  private stopCoreLogStream(): void {
    const ws = this.coreLogSocket;
    this.coreLogSocket = null;
    if (ws !== null) {
      try {
        ws.off('message');
        ws.off('close');
        ws.off('error');
        ws.close();
      } catch (e) {
        // 已断开属正常
      }
    }
  }

  /**
   * DoH 快照（只读）：节点域名 → 固定 IP，以及本次**尝试过**的域名名单。
   *
   * 测速侧据此判定「域名无法解析」（dns_unresolved）与「没试过解析」（unknown）的区别：
   * 只有在 attempted 里、且 pins 里查不到的域名才算解析失败。
   */
  hostSnapshot(): LatencyHostSnapshot {
    const snap = new LatencyHostSnapshot();
    snap.pins = this.lastProxyHosts;
    snap.attempted = this.lastProxyHostAttempted;
    snap.resolved = this.lastProxyHostResolved;
    snap.failed = this.lastProxyHostFailed;
    return snap;
  }
  /**
   * 生成配置前把节点凭据回填到内存。
   *
   * 导入/刷新订阅后，凭据会被封存进加密层并**清掉内存明文**
   * （SubscriptionService.sealPlaintext），而回填（initNodes）只在 App 启动
   * 与备份恢复时做。同一会话里紧接着生成配置时，那些节点会因「缺凭据」被
   * 生成器整条跳过 → 节点不在内核代理表 → 测速显示「未生效」、连接也找不到
   * 该节点（真机 2026-10-20）。
   */
  private async hydrateNodeCredentials(subs: SubscriptionService): Promise<void> {
    try {
      await subs.initNodes(subs.nodes);
    } catch (e) {
      AppLogger.warn(TAG, `node credential hydrate failed: ${AppLogger.errText(e)}`);
    }
  }


  /** 真正的启动动作（由状态机单次调用） */
  private async launchTestCore(): Promise<boolean> {
    const subs = this.testCoreSubs;
    const settings = this.testCoreSettings;
    if (this.context === null || subs === null || settings === null) {
      return false;
    }
    const generation = ++this.testCoreLaunchGeneration;
    const seq = this.connectSeq;
    try {

      let hosts: Record<string, string> = {};
      try {
        // hosts 的**唯一来源**是 RuntimeConfigBuilder.resolveSharedHosts（审计 F10 / ND11）：
        // 隧道与测速核共用同一次 DoH 解析 ⇒ 同一域名在两份 YAML 里钉到同一个 IP，
        // 不会再出现「同一节点隧道里能用、测速核里 pin 不上」。
        const testPriority: string[] = subs.nodes.length > 0 && subs.nodes[0].server.length > 0
          ? [subs.nodes[0].server] : [];
        hosts = await RuntimeConfigBuilder.resolveSharedHosts(subs.nodes, testPriority);
      } catch (e) {
        AppLogger.warn(TAG, `test-core DoH pre-resolve failed: ${AppLogger.errText(e)}`);
      }
      if (!this.isCurrentTestCoreLaunch(generation, seq)) { return false; }
      // 与隧道**共用同一份「节点域名 → 固定 IP」状态**：隧道建立时已经解析成功的
      // 域名直接复用（lastProxyHosts）。隧道里能连上的节点，测速核必须也能连上 ——
      // 两边各自解析 = 同一节点在两条路径上表现不同（真机 2026-10-20：DoH 在当前
      // 网络不通时测速核 pin 不到 → 运行期回退明文 DNS → 全部 503 失败）。
      const sharedHostKeys: string[] = Object.keys(this.lastProxyHosts);
      for (const k of sharedHostKeys) {
        if (hosts[k] === undefined) {
          hosts[k] = this.lastProxyHosts[k];
        }
      }
      // ⚠ 这两个集合**必须来自 DoH 的过程报告**，不能用「入参域名表」：
      //   attempted = **真的查过**的域名（查了没查到 ⇒ 真·解析失败）；
      //   resolved = 查到了地址的域名（含后来被丢弃的 ⇒ 不能误报失败）。
      // 用入参域名表会把「故意不查的短 TTL 域名」算成解析失败（假 dns_unresolved）。
      const dohReport = DoHResolver.lastReport;
      this.lastProxyHostAttempted = dohReport.queried.concat(dohReport.failed);
      this.lastProxyHostResolved = dohReport.resolved.slice(0);
      this.lastProxyHostFailed = dohReport.failed.slice(0);
      const testDomainCount = RuntimeConfigBuilder.proxyServerDomains(subs.nodes).length;
      AppLogger.info(TAG, `test-core proxy hosts: ${Object.keys(hosts).length}/${testDomainCount} `
        + `(shared from tunnel: ${sharedHostKeys.length})`);
      this.testCoreSecret = `ssr-test-${Date.now().toString(36)}-${Math.floor(Math.random() * 0x7FFFFFFF).toString(36)}`;
      // 端口探测：其他 mihomo 系应用（NekoBox 等）可能占用默认 9090/7890/1053
      // 测速核用**自己探测的**端口，且**不写回**共享端口字段（审计 F1）：
      // 写回会让隧道 YAML 里的端口与客户端 setEndpoint 用的端口对不上。
      const testPorts = await this.pickPorts(this.apiPort);
      if (!this.isCurrentTestCoreLaunch(generation, seq)) { return false; }
      // 测速核不启用 smart 组：它只做延迟探测，多一层内核选点会让测速结果失真
      // 凭据回填收敛在 hydrateAndBuildProfile（生成配置的唯一入口）。
      // 唯一配置生成入口：测速核与隧道共用同一份事实与同一处决策，
      // 选中的节点也一致（审计 F6：旧实现测速核写死 subs.nodes[0]）。
      const testProfile = await this.hydrateAndBuildProfile(subs, settings, this.lastNodeName, testPorts,
        this.testCoreSecret, hosts, this.isSmartModelReady(), this.isGeoipReady(), this.isRuleProviderReady());
      const testBuilt = await RuntimeConfigBuilder.buildRuntimeConfig(testProfile, RuntimeConfigMode.TEST);
      if (!this.isCurrentTestCoreLaunch(generation, seq)) { return false; }
      const yaml = testBuilt.yaml;
      // 登记「这份配置对应哪个节点集」：复用测速核前要比对，不一致就重建。
      this.testCoreNodeFingerprint = SubscriptionService.nodeSetFingerprint(subs.nodes);
      const configPath = `${this.context.cacheDir}/${PRIVATE_TEST_CONFIG_FILE}`;
      // 最小权限私有目录 + 0600 文件（含 api secret 与节点口令）
      ensurePrivateDir(this.context.cacheDir);
      // 写盘前闸门：测速核用的是同一套生成器，坏配置同样会让内核整份拒载
      const preparedConfig = await this.prepareConfigYaml(yaml, 'test-core');
      if (!this.isCurrentTestCoreLaunch(generation, seq)) { return false; }
      privateFs.writePrivate(configPath, preparedConfig);
      this.clearStartError();
      const stopWant: Want = {
        bundleName: 'com.tunbox.client',
        abilityName: 'VpnExtensionAbility'
      };
      // 停旧扩展。**只在扩展确实在跑时**才等它真正退出：
      // stop 抛错 = 本来就没跑（未运行属正常），此时固定 600ms 是纯白等 ——
      // 对齐 connect() 的既有优化（no live tunnel → skip exit grace）。
      // 真机证据：冷启动后第一次测速（从未连接过）白白多付 600ms。
      let extWasRunning: boolean = false;
      try {
        await vpnExtension.stopVpnExtensionAbility(stopWant);
        extWasRunning = true;
      } catch (e) {
        // 未运行属正常
      }
      if (extWasRunning) {
        await new Promise<void>((resolve) => setTimeout(() => resolve(), 600));
      } else {
        AppLogger.info(TAG, 'test core: no running extension to tear down; skip 600ms exit grace');
      }
      if (!this.isCurrentTestCoreLaunch(generation, seq)) { return false; }
      const launchParams: Record<string, string | number> = {};
      launchParams['configPath'] = configPath;
      launchParams['headless'] = 1;
      const want: Want = {
        bundleName: 'com.tunbox.client',
        abilityName: 'VpnExtensionAbility',
        parameters: launchParams
      };
      // 扩展是**独立进程**，它读的是磁盘上的设置：拉起前强制刷一次，避免防抖窗口未落盘。
      await SettingsService.flushNow();
      await vpnExtension.startVpnExtensionAbility(want);
      if (!this.isCurrentTestCoreLaunch(generation, seq)) { return false; }
      this.invalidateStateProbeCache();
      this.testCoreApiPort = testPorts.apiPort;
      this.api.setEndpoint(this.testCoreApiPort, this.testCoreSecret);
      const deadline = Date.now() + 20000;
      let readinessDelayMs = 0;
      while (Date.now() < deadline) {
        if (!this.isCurrentTestCoreLaunch(generation, seq)) { return false; }
        const extErr = this.readStartError();
        if (extErr.length > 0) {
          throw new Error(`测速内核启动失败: ${extErr}`);
        }
        if (this.readStartOk() && await this.api.healthProbe()) {
          if (!this.isCurrentTestCoreLaunch(generation, seq)) { return false; }
          AppLogger.info(TAG, 'headless test core ready');
          this.confirmProfileApplied('test-core');
          // 挂载内核日志流: 拨号失败的真实原因(DNS/握手/路由)只在内核日志里,
          // API 的 503 响应体是固定文案。转发进 AppLogger → hilog 可远程排查。
          this.startCoreLogStream(this.testCoreSecret);
          // 预热窗口：ready ≠ 可服务，controller 还要把首批连接/凭证初始化完
          // （见 TEST_CORE_WARMUP_MS 注释）。
          //
          // 这里**只登记「预计何时变热」，不真的睡**：把 1.5s 塞进启动 Promise
          // 会顶高 SingleFlightTestCore 的 15s 超时上限（慢 DoH + 慢就绪时
          // 本来能成功的启动会突然被判超时 → 白拆一次再重启）。
          // 真正等待放在 ensureLatencyApi（awaitTestCoreWarmup）：
          //  - 新鲜启动 → 等满剩余预热窗口（与旧实现同长，总耗时不变）；
          //  - 复用已在服务的内核 → 窗口早已过去 → **不等待 → 秒开**。
          this.testCoreWarmAt = Date.now() + TEST_CORE_WARMUP_MS;
          return true;
        }
        readinessDelayMs = nextReadinessDelayMs(readinessDelayMs);
        const remainingMs = deadline - Date.now();
        if (remainingMs > 0) {
          await new Promise<void>((resolve) =>
            setTimeout(() => resolve(), Math.min(readinessDelayMs, remainingMs)));
        }
      }
      const finalError = this.readStartError();
      if (finalError.length > 0) {
        throw new Error(`测速内核启动失败: ${finalError}`);
      }
      throw new Error('测速内核就绪超时(20s)');
    } catch (e) {
      AppLogger.warn(TAG, `ensureTestCore failed: ${AppLogger.errText(e)}`);
      return false;
    }
  }

  private isCurrentTestCoreLaunch(generation: number, seq: number): boolean {
    return generation === this.testCoreLaunchGeneration && seq === this.connectSeq;
  }

  /**
   * 释放测速内核：停扩展 + 删除测速配置（含 secret）+ 抹掉内存 secret。
   * 扩展未运行时 stopVpnExtensionAbility 抛错属正常，配置删除逐文件独立容错。
   */
  private async teardownTestCore(): Promise<void> {
    this.testCoreLaunchGeneration++;
    this.stopCoreLogStream();
    const stopWant: Want = {
      bundleName: 'com.tunbox.client',
      abilityName: 'VpnExtensionAbility'
    };
    let stopped = false;
    for (let attempt = 1; attempt <= TEST_CORE_STOP_ATTEMPTS && !stopped; attempt++) {
      try {
        await vpnExtension.stopVpnExtensionAbility(stopWant);
        stopped = true;
      } catch (e) {
        AppLogger.warn(TAG, `stopTestCore attempt ${attempt}/${TEST_CORE_STOP_ATTEMPTS} failed: `
          + (AppLogger.errText(e)));
        if (attempt < TEST_CORE_STOP_ATTEMPTS) {
          await new Promise<void>((resolve) =>
            setTimeout(() => resolve(), TEST_CORE_STOP_RETRY_DELAY_MS));
        }
      }
    }
    if (!stopped) {
      // 停失败不能只吞日志：下次启动的第一步就是 stop + 覆盖测速配置（含新
      // secret），因此扩展会被正确重建而不是复用旧配置，这里如实记录即可。
      AppLogger.warn(TAG,
        'stopTestCore: extension stop failed after retries; next launch rebuilds it');
    }
    this.resetTestCoreChannelState();
  }

  /**
   * 显式复位测速通道的全部本地状态：清 secret、清 endpoint、清单飞状态、清启动
   * 失败负缓存、删残余测速配置与隧道状态文件。
   * stopTestCore / teardownTestCore 之后必须走这里，否则页面级 testCoreOk 与真实
   * 通道脱钩，二次进入页面会继续按「内核就绪」走 CHANNEL_KERNEL 而全部失败。
   */
  resetTestCoreChannelState(): void {
    this.testCoreSecret = '';
    this.api.setEndpoint(this.apiPort, '');
    this.testCoreActive = false;
    this.testCoreNegativeUntil = 0;
    this.testCoreWarmAt = 0;
    this.testCoreNodeFingerprint = '';
    this.invalidateStateProbeCache();
    this.clearTestCoreArtifacts();
    if (this.testCoreFlight !== null) {
      this.testCoreFlight.resetIdle();
    }
  }

  /**
   * 页面进入时同步「真实隧道」controller 凭证。
   *
   * 必须拒绝在 headless 测速内核仍在服务时覆盖：两者共用 9090 端口，但 secret
   * 完全不同（测速内核每次随机生成）。旧实现无条件 setEndpoint(9090, 真实secret)
   * 会让内核侧所有 /delay 返回 401 → UI 全显超时，且不重启应用就一直错。
   * @returns 是否真的写入了真实隧道凭证
   */
  async applyRealTunnelEndpoint(realSecret: string): Promise<boolean> {
    if (this.state === ConnState.CONNECTED || this.state === ConnState.CONNECTING) {
      this.api.setEndpoint(this.apiPort, realSecret);
      return true;
    }
    if (await this.isTestCoreServing()) {
      AppLogger.info(TAG, 'skip real-tunnel endpoint override: headless test core is serving');
      return false;
    }
    this.api.setEndpoint(this.apiPort, realSecret);
    return true;
  }

  /**
   * 真实隧道接管扩展进程后，测速内核的进程内状态全部失效（同一扩展、不同配置与
   * secret）。必须显式复位，否则下次测速会因状态机仍 ACTIVE 而跳过重建。
   */
  invalidateTestCoreAfterRealTunnel(): void {
    this.testCoreLaunchGeneration++;
    this.testCoreNegativeUntil = 0;
    this.testCoreSecret = '';
    this.testCoreActive = false;
    this.testCoreNodeFingerprint = '';
    if (this.testCoreFlight !== null) {
      this.testCoreFlight.resetIdle();
    }
  }

  /**
   * 真实隧道的配置新鲜度：订阅集合变了以后，隧道配置里缺新节点。
   *
   * 热重载（PUT /configs?path=）按当前节点集重写内核配置，不拆隧道、不掉线；
   * 失败**不重连**（连接是用户资产），只记日志：此时新节点会显示「未生效」，
   * 下一次热重载或用户重连后恢复。
   */
  private async ensureTunnelConfigFresh(): Promise<void> {
    if (this.state !== ConnState.CONNECTED) {
      return;
    }
    const subs: SubscriptionService = this.lastSubs !== null
      ? this.lastSubs : SubscriptionService.instance();
    if ((subs.nodes.length === 0 && !subs.hasUsableProfile()) || this.tunnelConfigFingerprint.length === 0) {
      return;
    }
    if (this.tunnelConfigFingerprint === SubscriptionService.nodeSetFingerprint(subs.nodes)
      && this.appliedProfileRevision === ProfileRepository.revisionOf(ProfileRepository.currentId())) {
      return;
    }
    AppLogger.info(TAG, 'tunnel config is stale (node set changed); hot reloading');
    const ok = await this.reloadRulesHot('node-set-changed');
    if (ok) {
      AppLogger.info(TAG, 'tunnel config refreshed with current node set');
    } else {
      AppLogger.warn(TAG, 'tunnel config refresh failed; new nodes may show as not effective');
    }
  }

  /**
   * 订阅增删/刷新后作废测速核。
   *
   * 内核里的配置与新节点集不再对应时，继续复用会让新节点全部「未生效」
   * （真机 2026-10-20：导入新订阅后测速整屏未生效，/version 探活却通过）。
   * 作废后下一次取通道会按当前节点集重建；调用方可紧接着预热一次，让用户
   * 下一次点测速时内核既是热的、配置也是新的。
   *
   * 真实隧道在场时不动：测速核与真实隧道共用同一个扩展进程，停它等于停 VPN。
   */
  async invalidateTestCoreForSubscriptionChange(reason: string): Promise<void> {
    if (this.state === ConnState.CONNECTED || this.state === ConnState.CONNECTING) {
      return;
    }
    if (this.testCoreFlight === null || !this.testCoreFlight.isActive()) {
      this.testCoreNodeFingerprint = '';
      return;
    }
    AppLogger.info(TAG, `test core invalidated by subscription change (${reason})`);
    await this.stopTestCore();
  }

  /** 单独抽出便于验证：删除测速配置 + 隧道状态文件，逐文件独立容错 */
  clearTestCoreArtifacts(): string[] {
    if (this.context === null) {
      return [];
    }
    return clearPrivateArtifacts(this.context.cacheDir, privateFs);
  }

  async stopTestCore(): Promise<void> {
    if (this.testCoreFlight === null) {
      // 状态机未建但可能有残留配置（进程重启后），仍然完整复位一次
      this.resetTestCoreChannelState();
      return;
    }
    // 测速核与真实隧道共用同一个 VpnExtensionAbility 进程：停测速核会连带停扩展，
    // 先 flush，避免隧道那份尚未落盘的累计增量随进程消失。
    this.flushTrafficAccounting();
    await this.testCoreFlight.stop();
    // 状态机只负责状态位；secret / endpoint / 负缓存 / 单飞复位统一在这里显式清零
    this.testCoreActive = false;
    this.testCoreNegativeUntil = 0;
    this.testCoreNodeFingerprint = '';
    if (this.testCoreFlight.isActive()) {
      AppLogger.warn(TAG, 'stopTestCore: flight still ACTIVE after stop(); forcing idle');
      this.testCoreFlight.resetIdle();
    }
  }

  /**
   * 待回收定时器句柄（-1 = 无挂起回收）。
   * 测速内核在「连续多次测速 / 节点页来回切换」之间必须复用：重建一次要
   * DoH 预解析 + 停旧扩展 + 600ms 等待 + 启新扩展 + 健康轮询（秒级），
   * 用户感受就是「每点一次测速先卡一两秒」。所以离开测速场景时不立即回收，
   * 而是挂一个宽限回收；期间再次进入测速会 cancel 掉它（继续用同一内核）。
   */
  private testCoreIdleTimer: number = -1;

  /**
   * 「测速是否在跑」探针注册表（引擎侧注册，避免静态循环依赖：
   * LatencyEngine/FlclashLatencyService 都依赖本类，本类不能反向 import 它们）。
   * 回收定时器到点时若任一探针报忙，本轮回收顺延——否则 600 节点的批
   * （引擎预算 ~138s）会在第 90s 被自己停核，剩余节点成片盖章超时。
   */
  static readonly testCoreBusyProbes: (() => boolean)[] = [];

  /** 挂起「延迟回收测速内核」；重复调用只保留最后一次。 */
  scheduleTestCoreRecycle(delayMs: number): void {
    // 安全闸（延迟测试重做新增）：测速内核与真实隧道**共用同一个 VpnExtensionAbility
    // 进程**，stopTestCore 的第一步就是 stopVpnExtensionAbility —— 若此刻用户正在用
    // VPN，这一次回收会把用户的隧道直接停掉。旧实现只在页面离开时挂回收，且调用点
    // 都绕着"已连接"走；现在回收由 LatencyEngine 在每批测速后统一挂起，因此必须在这里
    // 硬性拦住「连接中/已连接/断开中/恢复中」四种状态，任何调用方都不得把用户的隧道回收掉。
    if (this.state === ConnState.CONNECTED || this.state === ConnState.CONNECTING
      || this.state === ConnState.DISCONNECTING || this.state === ConnState.RECOVERING) {
      AppLogger.info(TAG, `test core recycle skipped: orchestrator busy (state=${this.state})`);
      return;
    }
    this.cancelTestCoreRecycle();
    this.testCoreIdleTimer = setTimeout((): void => {
      this.testCoreIdleTimer = -1;
      // 批次进行中不回收：到点时引擎仍在跑 ⇒ 顺延一个完整窗口再查。
      // （批次的单节点请求不再经过 ensureLatencyApi，取通道时挂的那次 90s
      // 无法被批次自身续期 —— 引擎预算对 600 节点约 138s，远超 90s。）
      for (const probe of ConnectionOrchestrator.testCoreBusyProbes) {
        if (probe()) {
          AppLogger.info(TAG, 'test core recycle deferred: latency batch still running');
          this.scheduleTestCoreRecycle(delayMs);
          return;
        }
      }
      // 定时器回调必须收敛异步异常，避免未处理的 Promise rejection 干扰后台进程。
      this.stopTestCore().catch((e: Object): void => {
        AppLogger.warn(TAG,
          `delayed test core recycle failed: ${AppLogger.errText(e)}`);
      });
    }, delayMs);
  }

  /** 取消挂起的回收（真实连接 / 重新进入测速场景时调用）。 */
  cancelTestCoreRecycle(): void {
    if (this.testCoreIdleTimer >= 0) {
      clearTimeout(this.testCoreIdleTimer);
      this.testCoreIdleTimer = -1;
    }
  }

  /** TCP 探测 127.0.0.1 端口是否空闲：listen 成功即可用，占用/异常都视为不可用。 */
  private static async portIsFree(port: number): Promise<boolean> {
    const server = socket.constructTCPSocketServerInstance();
    try {
      await server.listen({ address: '127.0.0.1', port: port, family: 1 });
      return true;
    } catch (e) {
      return false;
    } finally {
      try {
        await server.close();
      } catch (e) {
        // 探测失败时 close 也可能失败，忽略
      }
    }
  }

  /**
   * 构造运行配置输入（IR）。
   *
   * 隧道与测速核**共用同一份事实**（节点集 / 设置 / 代理组 / 订阅规则 / DoH 快照 /
   * 三个就绪标志），差异只有 mode 决定的 tun.enable、端口与 secret。
   * 决策（useSmart / ruleProviderReady / selectedNode / useGeoip）全部在
   * RuntimeConfigBuilder.decideRuntimeOptions 一处做（审计 F5 / F6 / F11）。
   */
  /**
   * 生成配置前的**唯一入口**：先回填凭据，再建事实（profile）。
   *
   * 为什么必须是唯一入口：凭据封存/回填散在多处时，某条路径漏了回填 ⇒
   * 生成器按「缺凭据」把节点整条跳过 ⇒ 节点不在内核代理表 ⇒
   * 测速/连接都找不到节点（真机 2026-10-20：34/34 秒败）。
   * 收敛到一处之后，「配置里没有节点」这件事只可能来自这一处。
   */
  /**
   * 后台刷新订阅（**不阻塞连接**，2026-10-27）。
   *
   * 为什么必须后台：冷启动点连接时若节点表尚未就绪，旧实现会串行刷新全部订阅并 await，
   * 死订阅还要吃满 3 次重试 —— 实测把「立即连接」拖到 11~12s，而等 2s 再点只要 0.7s。
   * 现在连接只用现成节点（或 profile 原文接管）先连上，刷新在后台跑，失败的订阅
   * 记入待补拉，由连接成功后的 self-heal 补。
   */
  private refreshSubscriptionsInBackground(subs: SubscriptionService): void {
    if (this.backgroundRefreshRunning) { return; }
    this.backgroundRefreshRunning = true;
    const run = async (): Promise<void> => {
      // 串行：并发写订阅仓会互相打断（凭据规范化较重），这里要的是不阻塞而非更快。
      for (const s of subs.subscriptions) {
        try {
          const r: SubscriptionRefreshResult = await subs.refreshSubscription(s.id);
          if (r.status !== SubscriptionRefreshStatus.OK
            && r.status !== SubscriptionRefreshStatus.NOT_MODIFIED) {
            AppLogger.warn(TAG, `background refresh ${s.name}: ${r.status} ${r.message}`);
            if (r.status === SubscriptionRefreshStatus.NETWORK_ERROR) {
              subs.markNetworkFetchFailure(s.id);
            }
          }
        } catch (e) {
          AppLogger.warn(TAG, `background refresh ${s.name} failed: ${AppLogger.errText(e)}`);
        }
      }
    };
    run().then((): void => {
      this.backgroundRefreshRunning = false;
    }, (e: Error): void => {
      this.backgroundRefreshRunning = false;
      AppLogger.warn(TAG, `background refresh chain failed: ${AppLogger.errText(e)}`);
    });
  }

  private async hydrateAndBuildProfile(subs: SubscriptionService, settings: AppSettings,
    selectedNodeName: string, ports: RuntimePorts, secret: string,
    proxyHosts: Record<string, string>, smartModelReady: boolean,
    geoipReady: boolean, ruleProviderFileReady: boolean): Promise<RuntimeConfigProfile> {
    // 冷启动时凭据引导在后台跑（列表先上屏）；这里把它等齐再生成配置 ——
    // 生成配置/测速是唯一真正需要凭据的入口。
    await subs.ensureCredentials();
    await this.hydrateNodeCredentials(subs);
    return this.buildRuntimeProfile(subs, settings, selectedNodeName, ports, secret,
      proxyHosts, smartModelReady, geoipReady, ruleProviderFileReady);
  }
  private async buildRuntimeProfile(subs: SubscriptionService, settings: AppSettings,
    selectedNodeName: string, ports: RuntimePorts, secret: string,
    proxyHosts: Record<string, string>, smartModelReady: boolean,
    geoipReady: boolean, ruleProviderFileReady: boolean): Promise<RuntimeConfigProfile> {
    const profile = new RuntimeConfigProfile();
    profile.nodes = subs.nodes;
    profile.settings = settings;
    profile.proxyGroups = subs.proxyGroups;
    profile.subscriptionRules = subs.subscriptionRulesLines();
    profile.subscriptionRuleProviders = subs.subscriptionRuleProvidersBlock();
    // 订阅自带 DNS 上游：机场入口域名的真实 IP 只在自家私有 DoH 里，
    // 丢掉 → 公共 DNS 给出 CF/WAF 前置 IP → 该订阅节点全部超时（2026-10-20 定案）。
    profile.subscriptionDnsUpstreams = subs.subscriptionDnsUpstreams();
    profile.subscriptionDnsPolicies = subs.subscriptionDnsPolicies();
    profile.selectedNodeName = selectedNodeName;
    profile.mixedPort = ports.mixedPort;
    profile.apiPort = ports.apiPort;
    profile.dnsPort = ports.dnsPort;
    profile.apiSecret = secret;
    profile.smartModelReady = smartModelReady;
    profile.geoipReady = geoipReady;
    profile.ruleProviderFileReady = ruleProviderFileReady;
    profile.proxyHosts = proxyHosts;
    // ── FlClash 同构：当前 Profile 的订阅原文（配置基底）───────────────────
    // 当前 profile 未设置时回落第一个启用订阅的 id（旧数据：升级后第一次连接也能用）。
    // 原文缺失（未迁移/写盘失败）→ 空串 → builder 保持旧的 overlay 全量生成。
    let profileId = ProfileRepository.currentId();
    if (profileId.length === 0 || !ProfileRepository.exists(profileId)) {
      // 回落顺序：当前 profile 失效 → 第一个**已落盘**的启用订阅（有 profile 文件才能当基底）
      for (const candidate of subs.subscriptions) {
        if (candidate.enabled && ProfileRepository.exists(candidate.id)) {
          profileId = candidate.id;
          break;
        }
      }
    }
    if (profileId.length > 0) {
      const sourceYaml = ProfileRepository.read(profileId);
      this.pendingProfileRevision = ProfileRepository.fingerprint(sourceYaml);
      profile.profileYaml = sourceYaml.length > 0 ? await ProfileRepository.prepare(sourceYaml) : '';
      if (profile.profileYaml.length === 0) {
        // 文件读不出来（被删/写盘中断）：**不要**把它当配置基底，也不要把
        // applied 记成它 —— 否则界面会认为内核里是这份 profile，
        // 实际跑的是「全部订阅合并」的兜底配置（节点全串）。
        AppLogger.warn(TAG, `profile ${profileId} exists but empty; falling back to full overlay`);
        profileId = '';
      }
    }
    this.pendingProfileId = profileId;
    AppLogger.info(TAG, `profile base: id=${profileId.length > 0 ? profileId : '<none>'} `
      + `bytes=${profile.profileYaml.length} exists=${profileId.length > 0 ? ProfileRepository.exists(profileId) : false}`);
    return profile;
  }

  /**
   * 为一次内核会话选端口三元组：**不写任何共享字段**。
   *
   * 测速核必须用自己的一套端口：旧实现里测速核的端口探测会写回共享的
   * this.apiPort / this.mixedPort / this.dnsPort，导致测速核换了端口后，
   * 隧道那份 YAML 里的端口与客户端 setEndpoint 用的端口对不上（审计 F1）。
   *
   * @param excludeApiPort 需要避开的 api 端口（正在运行的隧道核）；-1 = 不避让。
   */
  private async pickPorts(excludeApiPort: number): Promise<RuntimePorts> {
    const picked = new RuntimePorts();
    picked.apiPort = this.apiPort;
    picked.mixedPort = this.mixedPort;
    picked.dnsPort = this.dnsPort;
    for (const candidate of PORT_CANDIDATE_SETS) {
      if (excludeApiPort > 0 && candidate[0] === excludeApiPort) {
        continue;
      }
      let allFree = true;
      for (const port of candidate) {
        if (!(await ConnectionOrchestrator.portIsFree(port))) {
          allFree = false;
          break;
        }
      }
      if (allFree) {
        picked.apiPort = candidate[0];
        picked.mixedPort = candidate[1];
        picked.dnsPort = candidate[2];
        return picked;
      }
    }
    AppLogger.warn(TAG, 'all port candidate sets busy; keeping current ports');
    return picked;
  }

  /**
   * 为即将启动的内核选定端口三元组（API/混合代理/DNS 监听）。
   * 依次尝试候选组，三端口全部空闲才采用；全部被占则保持默认（行为与旧版一致，
   * 由 API 就绪检查给出明确错误）。必须在停止测速核之后、写配置之前调用；
   * 热重载严禁调用（必须复用运行中内核的端口）。
   */
  private async reservePorts(): Promise<void> {
    const picked = await this.pickPorts(-1);
    this.apiPort = picked.apiPort;
    this.mixedPort = picked.mixedPort;
    this.dnsPort = picked.dnsPort;
    if (picked.apiPort !== API_PORT) {
      AppLogger.warn(TAG, `default ports busy; shifted to api=${this.apiPort} mixed=${this.mixedPort} dns=${this.dnsPort}`);
    }
  }

  /**
   * 判别「自己的内核不可达」与「别的 Clash/mihomo 内核占着端口」。
   * 真机实证（2026-09-18，NekoBox 2.0.1 共存事故）：另一款 Clash 系的 VPN 扩展进程
   * 驻留时会话槽位与回环端口 9090 都可能被它持有，且它可能在 reservePorts 探测
   * 之后、本端内核 bind 之前的窗口里抢回端口（TOCTOU）。探测特征：/version 可达
   * 但携带本端 secret 返回 401/403 —— 端口上活着的是一个不认我们凭证的外来控制器。
   */
  private async detectForeignControllerBusy(): Promise<boolean> {
    try {
      const probe = await this.api.probeController(1500);
      return probe.reachable && !probe.secretAccepted
        && (probe.httpCode === 401 || probe.httpCode === 403);
    } catch (e) {
      return false;
    }
  }

  async connect(node: ProxyNode, subs: SubscriptionService): Promise<boolean> {
    // 先登记意图再等待任何异步读取，用户停止可以使排队请求立即失效。
    this.disconnectRequested = false;
    const seq = ++this.connectSeq;
    // 连接事务：带上「这次连的是哪份配置的哪个版本」。之后每个长 await 后
    // 都用 attempt.checkpoint() 判断是否还该继续（旧事务不得再写任何状态）。
    const startProfileId: string = ProfileRepository.currentId();
    const attempt: ConnectionAttempt = this.attempts.begin(startProfileId,
      ProfileRepository.revisionOf(startProfileId), 'connect');
    const task = this.lifecycleWrites.then((): Promise<boolean> => {
      if (seq !== this.connectSeq || this.disconnectRequested) { return Promise.resolve(false); }
      return this.connectExclusive(node, subs, seq, attempt);
    });
    this.lifecycleWrites = task.then((): void => {}, (): void => {});
    const connected = await task;
    if (seq !== this.connectSeq || this.disconnectRequested) { return false; }
    if (connected) { return true; }
    if (this.failedConnectSeq !== seq) { return false; }
    // 修复可能再次调用 disconnect/connect，必须在资源队列释放后执行。
    const configRejected = this.lastError.indexOf('配置校验未通过') >= 0;
    const nested = this.inRepairConnect || this.failoverRunning;
    if (!configRejected && !nested && !this.healthRunning) {
      const recovered = await this.runHealthSelfCheckAndRepair('connect-failed');
      if (recovered) { return true; }
      if (seq !== this.connectSeq || this.disconnectRequested) { return false; }
      return await this.tryFailover('connect-failed');
    }
    return false;
  }

  private async connectExclusive(node: ProxyNode, subs: SubscriptionService, seq: number,
    attempt: ConnectionAttempt): Promise<boolean> {
    this.failedConnectSeq = -1;
    // 策略拒绝不是网络故障：在任何状态变化/拆隧道/修复与故障切换前退出。
    let settings: AppSettings;
    let appRouting: AppRoutingRuntime;
    try {
      settings = await SettingsService.load();
      if (seq !== this.connectSeq || this.disconnectRequested) { return false; }
      appRouting = AppRoutingPolicy.runtime(settings.appRoutingMode, settings.includedApps,
        settings.excludedApps, settings.appRoutingNeedsReview);
    } catch (e) {
      if (seq !== this.connectSeq || this.disconnectRequested) { return false; }
      this.lastError = AppLogger.errText(e);
      this.notify();
      return false;
    }

    // 性能（2026-10-17 启动速度）：secret 读盘提前发起，与下面的节点检查/意图落盘/
    // 旧隧道拆除并行推进 —— 串行等于白等一次 preferences 往返；await 仍在原语义位置。
    const secretTask: Promise<string> = SettingsService.getApiSecret()
      .catch((e: Object): string => {
        AppLogger.warn(TAG, `api secret read failed: ${AppLogger.errText(e)}`);
        return '';
      });
    const connectT0 = Date.now();
    let tPrep = 0;
    let tPrelaunch = 0;
    let tLaunch = 0;
    let tReady = 0;

    // ── 冷启动 hydration 竞态保护（2026-10-17 真机日志实证）─────────────────
    // 完全退出重进后 ~1.4s 内点连接：SubscriptionService 的进程级 hydrate
    // （凭据迁移 + 节点回填，真机实测 +1133ms 才完成）尚未结束 → subs.nodes
    // 为空或节点尚缺凭据/原始 YAML → 误入下方「零节点/无有效节点」分支，
    // 串行重拉全部订阅（此刻无隧道、订阅域名直连 15s 超时 × 重试）→
    // connect timing prep 实测 38s；同进程第二次连接仅 0.6s。
    // init() 进程内记忆化：已完成立即返回、进行中等待完成、失败放行
    // 走下方既有校验与报错，不改变任何语义，只是不再抢跑。
    if (this.context !== null) {
      try {
        await subs.init(this.context);
      } catch (e) {
        AppLogger.warn(TAG, `subs hydration wait failed: ${AppLogger.errText(e)}`);
      }
    }
    if (!attempt.checkpoint(this.attempts.currentGeneration())
      || seq !== this.connectSeq || this.disconnectRequested) { return false; }

    // ── 硬门禁：一个节点都没有时，绝不拉起 VPN 扩展 ─────────────────────────
    // 全新安装的典型路径：订阅已添加但尚未拉取成功 → subs.nodes 为空。
    // 旧实现不做拦截，直接生成一份 1861 字节的空壳配置拉起扩展，内核在
    // 「没有任何可用 outbound」的启动路径上 20s 无响应（CORE_START_TIMEOUT_MS），
    // 最终抛「内核启动超时（20s 无响应）」，再被 VpnRecoveryPolicy 翻译成
    // 「卡在联网下载，请等 10 秒后再点一次连接」—— 真机实证该文案是误判，
    // 用户被指向完全无关的方向，而且重试必然同样失败（订阅仍是空的）。
    // 正确做法：先自动补一次订阅拉取，仍为空就明确报错并立刻返回，
    // 不进入 CONNECTING、不写配置、不拉起扩展、不占用 20s。
    if (subs.nodes.length === 0 && !subs.hasUsableProfile()) {
      await this.autoRefreshForZeroNodes(subs);
      if (!attempt.checkpoint(this.attempts.currentGeneration())
        || seq !== this.connectSeq || this.disconnectRequested) { return false; }
      if (subs.nodes.length === 0 && !subs.hasUsableProfile()) {
        this.setState(ConnState.DISCONNECTED);
        this.lastError = '没有可用节点：请先到主页「订阅」里添加订阅并点击刷新，等节点列表出现后再连接';
        this.notify();
        AppLogger.warn(TAG, 'connect refused: zero nodes available '
          + '(subscription empty or never fetched); VPN extension NOT launched');
        return false;
      }
    }

    const stateBeforeConnect: ConnState = this.state;
    this.setState(ConnState.CONNECTING);
    this.lastError = '';
    this.lastSubs = subs;
    this.lastNodeName = node.name;
    this.notify();
    // 【P2-11 修复】try 从这里开始：state 已置 CONNECTING，下面的 stopTestCore /
    // advanceSessionIntent（preferences IO 可 reject）任一抛异常都必须走统一回滚
    // （disconnectInternal + 置回 DISCONNECTED），否则状态永久卡在 CONNECTING，
    // 后续所有按 state 门禁的逻辑持续误判「orchestrator busy」。
    let intentGeneration: number = 0;
    try {
    // 先作废并等待测速启动/清理结算，再把共享扩展交给真实隧道。
    this.cancelTestCoreRecycle();
    this.testCoreLaunchGeneration++;
    if (this.testCoreFlight !== null) { await this.stopTestCore(); }
    if (seq !== this.connectSeq || this.disconnectRequested) { return false; }

    // 真实连接会重启扩展进程, headless 测速内核随之失效；同时必须取消
    // 挂起的「回收测速内核」定时器 —— 否则它会在真实隧道起来之后再执行
    // stopVpnExtensionAbility，把用户正在用的 VPN 停掉。
    this.cancelTestCoreRecycle();
    // 真实连接会重建扩展进程（同一 9090 端口换成隧道配置 + 真实 secret）：
    // 测速内核的进程内状态与本班次 secret 在此刻全部作废。
    this.invalidateTestCoreAfterRealTunnel();
    // 记录**本次连接开始前**的状态：后面判断"是否真有旧隧道需要拆除并等待其退出"
    // 必须用它 —— 此刻 this.state 已/即将被 CONNECTING 覆盖，且编译器会把它
    // 窄化成常量，直接比较会被判为恒不成立。

    // ── 用户意图必须**先于**拉起落盘 ───────────────────────────────
    // 后台保活自愈的基石：整个建连过程有 30s 就绪窗口 + 系统授权弹窗，
    // 这期间进程随时可能被系统回收。原来只在 state=CONNECTED 之后才写
    // desiredConnected，一旦在这段窗口里被杀，磁盘上的意图仍是 false ——
    // 冷启动/回前台时无从判断"用户本来是想连着的"，只能让用户手动再点一次。
    // 写入点前移后：任何时刻被杀，磁盘上的意图都是诚实的。
    intentGeneration = await this.advanceSessionIntent(true, 'connecting', node.name, 0);
    if (seq !== this.connectSeq || this.disconnectRequested) {
      await this.clearSessionIntent(intentGeneration);
      return false;
    }

    if (this.context === null) {
        throw new Error('orchestrator 未初始化（init(context) 缺失）');
      }
      // 节点有效性检查：旧版本持久化的节点缺 rawYaml 且非 ss/ssr 字段不完整时无法生成配置。
      // 自动降级到第一个可用节点；全部无效时自动刷新一次订阅（修复升级后旧数据不可用）。
      // FlClash 同构（2026-10-22）：节点来自内核 `/proxies`（影子节点 `core:<name>`）时，
      // 配置由订阅原文决定，App 侧不需要「能序列化成 YAML」——名字在内核里就是有效节点。
      // 旧判据会把影子节点判成无效并回落到 subs.nodes[0]（真机实测：点了香港Z09、连的是 hy2台湾）。
      // 【2026-10-27 冷启动 12s 定案】凭据引导在后台跑（冷启动 +980ms 才就绪），而这里
      // 的有效性判据依赖 `proxyYamlLine()` —— 凭据没回填时它对每个节点都返回空串，
      // 于是「刚点连接」被误判成「没有任何有效节点」，接着串行刷新订阅（死订阅还要
      // 重试 3×700ms），实测把立即连接拖到 11~12s；等 2s 再点则只要 0.7s。
      // 修法：先在**这里**等凭据就绪（幂等，后面的 hydrateAndBuildProfile 再调是 no-op），
      // 再做有效性判定。代价 0：这笔等待本来就在连接路径上，只是提前了。
      await subs.ensureCredentials();
      const profileExists: boolean = ProfileRepository.exists(ProfileRepository.currentId());
      const isValidNode = (n: ProxyNode): boolean =>
        CoreNodeBridge.isShadow(n) || n.id.startsWith('profile:')
          || ClashConfigGenerator.proxyYamlLine(n).length > 0
          // 原文接管（FlClash 同构）时 nodes 由 profile 原文决定，App 侧能否序列化
          // 与「能否连上」无关 —— 拿序列化能力判有效性会制造假阴性。
          || profileExists;
      let target: ProxyNode = node;
      if (!isValidNode(target)) {
        const firstValid = subs.nodes.find((n) => isValidNode(n)) ?? null;
        if (firstValid !== null) {
          target = firstValid;
          AppLogger.warn(TAG, `preferred node invalid; fall back to ${target.name}`);
        } else {
          AppLogger.warn(TAG, 'no valid node config; refreshing subscriptions in background');
          // 【2026-10-27】连接路径**绝不等待**订阅刷新：实测死订阅的 3 次重试就能把
          // 「立即连接」拖到 11~12s，而用户等 2s 再点只要 0.7s —— 差别全在这里。
          // 现在只做两件事：① 后台串行刷新（不 await，成功后自愈）；② 最多等 1200ms
          // 拿现成节点，超时就继续（配置由 profile 原文接管，不依赖订阅刷新）。
          this.refreshSubscriptionsInBackground(subs);
          const waitDeadline = Date.now() + 1200;
          let retry: ProxyNode | null = subs.nodes.find((n) => isValidNode(n)) ?? null;
          while (retry === null && Date.now() < waitDeadline) {
            await new Promise<void>((resolve) => setTimeout((): void => resolve(), 120));
            retry = subs.nodes.find((n) => isValidNode(n)) ?? null;
          }
          if (retry === null) {
            // 仍然没有可序列化节点：只要 profile 原文在，目标节点依旧有效（见上面注释）。
            if (profileExists) {
              AppLogger.warn(TAG, 'still no serializable node; continuing with profile takeover');
              retry = target;
            } else {
              throw new Error('订阅节点配置无效：请到主页「订阅」里点击刷新，确认节点已成功导入后再连接');
            }
          }
          target = retry;
        }
      }
      this.lastNodeName = target.name;
      this.lastNode = target;

      // API secret 保持稳定(首次生成后复用): 每次重连都换 secret 会让其他页面
      // 持有的旧 secret 全部 401, 延迟测试/节点切换集体失败(表现全是"超时")。
      const savedSecret = await secretTask;
      if (seq !== this.connectSeq || this.disconnectRequested) {
        await this.clearSessionIntent(intentGeneration);
        return false;
      }
      if (savedSecret.length > 0) {
        this.apiSecret = savedSecret;
      } else {
        const random = cryptoFramework.createRandom();
        const randomBlob = await random.generateRandom(24);
        let randomHex = '';
        for (const value of randomBlob.data) {
          randomHex += value.toString(16).padStart(2, '0');
        }
        this.apiSecret = `ssr-${randomHex}`;
        await SettingsService.setApiSecret(this.apiSecret);
      }

      // 测速内核已在推进真实连接意图前结算，后续旧测速收尾不能再停止新隧道。
      // 关键：扩展进程存活时再次 startVpnExtensionAbility 只会累加 startId，
      // 系统不会重新回调 onCreate（TUN/内核启动逻辑不会重放）。
      // 因此每次连接前先停掉既有 VPN 扩展（触发 onDestroy → 内核停止），
      // 等待进程退出后重新拉起，保证新配置/新节点真正生效。
      // 注意: 停旧隧道也必须在任何「本机出网能力」探测之前 —— 隧道存活时默认路由
      // （v4 0.0.0.0/0、双栈时还有 ::/0）指向隧道自身，探测会测到隧道而不是物理承载。
      try {
        const stopWant: Want = {
          bundleName: 'com.tunbox.client',
          abilityName: 'VpnExtensionAbility'
        };
        await vpnExtension.stopVpnExtensionAbility(stopWant);
      } catch (e) {
        // 未运行时停止会报错，属正常
      }
      // 等待旧扩展进程真正退出，否则紧接着的 start 会被系统静默吞并
      // （真机实证：无 onCreate、无错误，readiness 只能干等 30s）。
      // **仅在确有旧隧道时才等**：没东西可停时 stop 立即返回，这 400ms 纯属白等 ——
      // 冷启动首连因此白付 400ms。判据：进入本次连接前的状态 + 权威心跳租约。
      // 注意必须用**进入前捕获的状态**：`this.state` 在本函数开头已被赋成
      // CONNECTING，若在此处直接比较，编译器会把它窄化成常量并判定比较恒不成立。
      const hadLiveTunnel = stateBeforeConnect === ConnState.CONNECTED
        || stateBeforeConnect === ConnState.RECOVERING
        || stateBeforeConnect === ConnState.DISCONNECTING
        || this.isCoreAliveByHeartbeat();
      if (hadLiveTunnel) {
        await new Promise<void>((resolve) => setTimeout(() => resolve(), 400));
      } else {
        AppLogger.info(TAG, 'no live tunnel to tear down; skip 400ms extension-exit grace');
      }
      tPrep = Date.now() - connectT0;

      // geoip.metadb 缺失/损坏时降级生成（不含 GEOIP 规则、不含 dns.fallback）,
      // 避免内核在 config.Parse 阶段联网下载 MMDB 失败导致启动卡死;
      // 连接成功后后台补齐, 下次连接生效。
      const geoipReady = this.isGeoipReady();
      if (!geoipReady) {
        AppLogger.info(TAG, 'geoip.metadb missing/invalid; generate config without GEOIP rule or dns.fallback');
      }

      // hyper-adrules(去广告) 是 type: http 的 rule-provider：本地文件缺失时内核会在
      // TunBoxStart() 内同步联网拉取并阻塞启动协程（不返回、不报错 → 扩展 30s 静默）。
      // 与 GEOIP 同策略：文件未就绪就不声明该 provider，后台补齐后下次连接生效。
      //
      // 2026-10-23 产品口径变更：
      //  ① 去广告是**独立开关**（只判 hyperAdRulesEnabled），不再要求「启用规则路由引擎」；
      //  ② 规则集随安装包内置（rawfile → cacheDir/ruleset），开箱即用、不依赖首次联网；
      //  ③ 仍未就绪时不阻塞连接：配置不带 RULE-SET，连接成功后台补一份。
      const adRulesOn = settings.hyperAdRulesEnabled;
      const ruleProviderFileReady = this.isRuleProviderReady();
      if (adRulesOn && !ruleProviderFileReady) {
        AppLogger.info(TAG, 'ruleset/hyper_adrules_ads.mrs missing; generate config without RULE-SET');
        this.downloadRuleProviderAsset('auto').catch((e: Object): void => {
          AppLogger.warn(TAG, `hyper-adrules background download error: ${e}`);
        });
      } else if (!adRulesOn) {
        AppLogger.info(TAG, 'ad-block rules disabled; skipping hyper-adrules ruleset provisioning');
      }

      // ── 代理服务器域名防投毒解析(UI 进程, 此刻 VPN 未起、网络干净) ──
      // 明文 UDP DNS 会往代理域名的应答里追加假记录, 内核拨假地址全线超时。
      // 用 DoH 预解析所有节点入口域名(与权威应答验证一致), 结果写进 YAML hosts:,
      // 内核直接命中真实 IP。带缓存 + 6s 全局预算 + 失败二轮重试。
      //
      // 性能：DoH 结果已跨进程落盘(DoHResolver.ensureLoaded)，第二次起的连接通常
      // 全部命中缓存，这一步直接归零；真正要联网的只有新增/过期的域名。
      // 并且把**本次要连的节点**排在最前解析，预算再紧也先把它 pin 住 ——
      // 连不上当前节点的代价远高于漏 pin 几个备用节点。

      // IPv6 双栈（设置页开关，默认开）：这里只做「记录意图」，真正落地的两处分别是
      //   ① YAML：RuntimeConfigBuilder 把 settings.ipv6Enabled 传给生成器（ipv6 / dns.ipv6
      //      两行同开同关；DNS 段是 redir-host，AAAA 走真实上游）；
      //   ② TUN：VpnExtensionAbility 读**同一份 YAML 的 ipv6 行**决定是否装 v6 地址与 ::/0。
      // 之所以不在这里额外下发 want 参数：TUN 与内核必须同源，YAML 已经是唯一真源，
      // 多一条 want 通道就多一个「两处不一致 ⇒ v6 黑洞/泄漏」的机会。
      // ipv6Active 仅供诊断/健康探针展示真实意图，不再参与任何下发决策。
      this.ipv6Active = settings.ipv6Enabled !== false;
      const priorityDomains: string[] = (target.server.length > 0) ? [target.server] : [];
      // 端口探测提前发起，与下面的 DoH 预解析并行推进：两者互不依赖
      // （端口探测只 bind/close 本地回环，DoH 只发 HTTPS 查询），
      // 串行等于白等——端口探测最坏 9 组 socket 往返，DoH 最坏吃满 6s 预算。
      const portsTask: Promise<void> = this.reservePorts().catch((e: Object): void => {
        // reservePorts 内部已逐候选容错；这里只是不让异常变成游离的未处理拒绝
        AppLogger.warn(TAG, `reservePorts rejected: ${AppLogger.errText(e)}`);
      });
      // 过期 pin 的刷新刻意放在**隧道建立之前**，而不是连接成功之后：
      // 放到连接后就是"隧道已起、UI 进程却还在对 doh.pub / alidns 裸发查询"，
      // 等于在刚建好的防泄露链路上又开一个明文的洞。放这里既保持网络干净，
      // 又与 resolveMany 并行推进，不额外占用启动时间。
      let proxyHosts: Record<string, string> = {};
      // 2026-10-19 稳定性回退：预算恢复为固定 6000ms（0.3.3 口径）。
      //
      // 0.4.0 曾在「目标域名已 pin」时把预算收紧到 1500ms，收益是首连少等最多 4.5s；
      // 但代价是**备用节点域名几乎必然解析不到** → 不进 YAML `hosts:` → 内核运行期
      // 退回 proxy-server-nameserver 现解析 → 切节点/故障切换时可能拿到被污染的 IP。
      // 稳定性优先：所有节点域名一律给足 6s，宁可首连慢一点，也不留"某些节点不通"的坑。
      // （注意：DoHResolver 内部对短 TTL 域名不再 pin，那部分见该文件头注释。）
      try {
        // 同上：hosts 唯一来源 = RuntimeConfigBuilder.resolveSharedHosts（ND11）。
        proxyHosts = await RuntimeConfigBuilder.resolveSharedHosts(subs.nodes, priorityDomains);
        const tunnelReport = DoHResolver.lastReport;
        this.lastProxyHostAttempted = tunnelReport.queried.concat(tunnelReport.failed);
        this.lastProxyHostResolved = tunnelReport.resolved.slice(0);
        this.lastProxyHostFailed = tunnelReport.failed.slice(0);
      } catch (e) {
        proxyHosts = {};
        AppLogger.warn(TAG, `proxy-server DoH pre-resolution failed: ${AppLogger.errText(e)}`);
      }
      // 域名清单来自唯一实现（RuntimeConfigBuilder.proxyServerDomains）——
      // 隧道与测速核用的是同一份清单，不能各算各的。
      const serverDomains: string[] = RuntimeConfigBuilder.proxyServerDomains(subs.nodes);
      AppLogger.info(TAG, `DoH pinned ${Object.keys(proxyHosts).length}/${serverDomains.length} proxy servers`);
      const unpinnedDomains: string[] = [];
      for (const d of serverDomains) {
        if (proxyHosts[d.toLowerCase()] === undefined) {
          unpinnedDomains.push(d);
        }
      }
      if (unpinnedDomains.length > 0) {
        // 未 pin 的域名运行期回退 proxy-server-nameserver(明文 UDP, 有被投毒风险),
        // 点名记录便于排查"个别节点不通"类问题。
        AppLogger.warn(TAG, `unpinned servers: ${unpinnedDomains.slice(0, 12).join(', ')}`);
      }

      // 端口探测：测速核已在此前停止；若其他 VPN 应用占用默认端口则整体换组。
      // 与 DoH 预解析**并行**：两者互不依赖（端口探测只 bind/close 本地回环，
      // DoH 只发 HTTPS 查询），串行等于白等两段。
      await portsTask;
      if (seq !== this.connectSeq || this.disconnectRequested) {
        await this.disconnectInternal(intentGeneration);
        return false;
      }
      tPrelaunch = Date.now() - connectT0;
      // ── 内核 smart 组（自动选择）────────────────────────────────────────
      // 只有「用户选了自动模式」且「Model.bin 已就绪」才声明 type: smart。
      // 模型缺失时若仍声明，内核 GetModel() 会在启动路径同步下载 github 上的
      // Model.bin（实测阻塞 90.1s），与坑 24/40 同类；这里直接降级回
      // 应用侧 SmartSelector 选点，行为与换核前一致。
      //
      // 但**模型下载不能只在 auto 模式下做**：默认模式就是 manual（用户开箱即是），
      // 若只在 auto 下载，用户切到 auto 时还要再等一轮连接才拿得到模型。
      // 所以在任一模式下、只要模型没就绪就先补齐，切模式时即可立刻生效。
      //
      // 性能：seedSmartModelFromRawfile 会同步读+写 9.3MB（rawfile → cacheDir）。
      // manual（默认模式）根本不会用到 smart 组，却要为这份用不上的拷贝付出
      // 几百毫秒主线程 I/O —— 因此只在**真的要声明 smart 组**（auto 模式）时才播种。
      // manual 模式下模型就绪与否由后台下载保证，下次切到 auto 即刻可用。
      const autoMode = settings.autoSelectMode === AutoSelectModes.AUTO;
      const smartReady = (autoMode && this.seedSmartModelFromRawfile()) || this.isSmartModelReady();
      if (!smartReady) {
        // 用户口径（2026-10-22）：**不再在连接/启动代理后自动下载 Model.bin**。
        // 理由：模型 9.3MB，绝大多数用户用不到自动优选；后台下载既占流量，又让
        // 「没模型时不显示自动选择」这条 UI 规则永远不成立（一连接就偷偷补上了）。
        // 需要模型的用户在启动代理后由内核侧更新，UI 上已写明这句话。
        AppLogger.info(TAG, 'smart model missing; auto-download disabled by policy');
      }
      // 保持字面量表达：架构自检（scripts/verify-vpn-architecture.mjs 的
      // orch.smart.gated-by-auto）就是靠这段文本锁定"smart 组只由 auto 模式启用"，
      // 换成中间变量会让这道闸门失效。
      const configGenT0 = Date.now();
      // 凭据回填收敛在 hydrateAndBuildProfile（生成配置的唯一入口）。
      // 唯一配置生成入口：隧道与测速核共用同一份事实与同一处决策。
      const tunnelPorts = new RuntimePorts();
      tunnelPorts.apiPort = this.apiPort;
      tunnelPorts.mixedPort = this.mixedPort;
      tunnelPorts.dnsPort = this.dnsPort;
      const tunnelProfile = await this.hydrateAndBuildProfile(subs, settings, target.name, tunnelPorts, this.apiSecret,
        proxyHosts, smartReady, geoipReady, ruleProviderFileReady);
      const built = await RuntimeConfigBuilder.buildRuntimeConfig(tunnelProfile, RuntimeConfigMode.TUNNEL);
      // 配置构建含 DoH 刷新/合并/校验，是连接中最长的一步之一：用户可能已停止，
      // 或订阅已被刷新（revision 变了）—— 旧事务不得把旧配置推到内核上。
      if (!attempt.checkpoint(this.attempts.currentGeneration())
        || seq !== this.connectSeq || this.disconnectRequested) { return false; }
      const yaml = built.yaml;
      // ── 冷启动「节点选择未生效」根治（2026-10-27 用户报障）───────────────
      // `target` 来自 App 侧节点表（可能是上次落盘的旧名字），而最终 YAML 的
      // PROXY 组由「validNodes 过滤 + 订阅原文接管」决定，未必包含它。旧代码仍拿
      // `target.name` 去 PUT /proxies → 必然 400 → 整个连接失败，用户只能手动重新
      // 测速/刷新后再连一次。这里改用构建结果里的 `effectiveNodeName`（最终 YAML
      // PROXY 组首成员）钉选，并把偏好自愈成它，下一次冷启动不再踩同一个旧名字。
      const effectiveName: string = (built.effectiveNodeName ?? '').length > 0
        ? built.effectiveNodeName : target.name;
      const effectiveNode: ProxyNode | null =
        (tunnelProfile.nodes ?? []).find((n: ProxyNode): boolean => n.name === effectiveName) ?? null;
      const pinNode: ProxyNode = effectiveNode !== null ? effectiveNode : target;
      if (effectiveName !== target.name && !built.pinMatched) {
        AppLogger.warn(TAG, `pin target "${target.name}" missing from final PROXY group; `
          + `pinning "${effectiveName}" instead`);
        this.lastNode = pinNode;
        this.lastNodeName = effectiveName;
        try {
          await SettingsService.patchSettings((p: AppSettings): void => {
            p.preferredNodeId = effectiveNode !== null ? effectiveNode.id : '';
            p.preferredNodeName = effectiveName;
            p.preferredNodeSubscriptionId = effectiveNode !== null
              ? effectiveNode.subscriptionId : target.subscriptionId;
            p.preferredNodeNamesBySubscription = AppSettings.rememberPreferredNodeName(
              p.preferredNodeNamesBySubscription,
              effectiveNode !== null ? effectiveNode.subscriptionId : target.subscriptionId,
              effectiveName);
          });
        } catch (e) {
          AppLogger.warn(TAG, `self-heal preferred node failed: ${AppLogger.errText(e)}`);
        }
      }
      if (settings.autoSelectMode === AutoSelectModes.AUTO && !built.options.useSmart) {
        AppLogger.info(TAG, 'auto mode but Model.bin not ready; using app-side selection '
          + '(smart group disabled this session; downloading in background)');
      }
      AppLogger.info(TAG, `config generated: ${Date.now() - configGenT0}ms (${yaml.length} bytes)`);
      // 登记「隧道配置对应哪个节点集」：测速取通道前用它判断隧道配置是否过期
      // （订阅集合变了 → 隧道配置缺新节点 → 测速 404「未生效」）。
      this.tunnelConfigFingerprint = SubscriptionService.nodeSetFingerprint(subs.nodes);
      // 缓存本次连接的配置输入，供规则/站点热重载复用（不重跑 DoH、不重建隧道）。
      this.lastProxyHosts = proxyHosts;
      // 注意：lastProxyHostAttempted / Resolved / Failed 在上面由 DoH 过程报告赋值，
      // 这里**不再**用入参域名表覆盖 —— 用域名表会把「故意没查的短 TTL 域名」
      // 误报成解析失败（假 dns_unresolved）。
      this.lastGeoipReady = geoipReady;
      this.lastSmartModelReady = smartReady;
      this.lastRuleProviderFileReady = ruleProviderFileReady;
      const configPath = `${this.context.cacheDir}/${CONFIG_FILE}`;
      // 含 API secret 与节点口令：最小权限目录(0700) + 文件(0600)，fd 由 writePrivate 兜底关闭
      ensurePrivateDir(this.context.cacheDir);
      // ── 冷启动也「写暂存 → 内核校验 → 成功才替换」（2026-10-22，对齐 FlClash）──
      // 设备侧 core 没有 `-t` CLI，但**扩展自己就是校验器**：把暂存路径交给它拉起，
      // 内核能加载（readiness 通过）才把这份字节原子替换到正式配置路径。
      // 这样「拿最后一份能用的配置去赌」的窗口消失：拒载时正式配置一个字节都没动。
      // 写盘前闸门（C23）仍在前面：内核对 yaml 重复键是整份拒载，能拦就早拦，
      // 不通过 → 不写任何文件、直接中止本次连接并给可行动提示。
      const stagedConfigPath = `${configPath}.next`;
      // 闸门产物（可能已按受控降级修过）留在变量里：内核确认接受后要原样提升为正式配置，
      // 重新读盘既多一次 IO 也可能读到被并发改写的版本。
      const preparedConfig = await this.prepareConfigYaml(yaml, 'main');
      if (seq !== this.connectSeq || this.disconnectRequested) {
        await this.disconnectInternal(intentGeneration);
        return false;
      }
      privateFs.writePrivate(stagedConfigPath, preparedConfig);
      AppLogger.info(TAG, `config staged: ${stagedConfigPath} (${yaml.length} bytes)`);
      this.clearStartError();
      // want 可能被系统丢弃（新装首连授权弹窗链路，真机实证 2026-09-19）——
      // 把本次分流三元组同步落盘，扩展侧丢参时按 configPath+新鲜度回退读取。
      // 这里必须记**暂存路径**：那才是扩展实际加载的文件。
      const packagesJson = JSON.stringify(appRouting.packages);
      this.writeStartParamsFile(stagedConfigPath, appRouting.mode, appRouting.needsReview, packagesJson);
      // 再落一份到 preferences：cacheDir 那份只认 3 分钟内，进程被回收后由系统
      // 重新拉起扩展时几乎必然过期 → 扩展硬拒绝恢复，隧道再也起不来。
      // preferences 与扩展进程同沙箱同库，这条是不限时长的恢复来源。
      const routingSnap = new AppRoutingSnapshot();
      routingSnap.appRoutingMode = appRouting.mode;
      routingSnap.appRoutingPackagesJson = packagesJson;
      routingSnap.appRoutingNeedsReview = appRouting.needsReview;
      routingSnap.configPath = stagedConfigPath;
      routingSnap.ts = Date.now();
      SettingsService.saveAppRoutingSnapshot(routingSnap).catch((e: Error): void => {
        AppLogger.warn(TAG, `app routing snapshot persist failed: ${AppLogger.errText(e)}`);
      });

      // 拉起 VPN 能力（首次会弹系统 VPN 授权框）；TUN 建立 + 内核启动都在扩展进程完成。
      // 扩展进程把启动结果写入 vpn_start_error.txt（空文件/不存在 = 成功，非空 = 失败原因），
      // 并写入 vpn_start_ok.txt 成功标记 —— UI 进程通过文件轮询确认，绕开跨进程 loopback 探测的不确定性。
      // IPv6 双栈**不走** want：扩展进程读的是这份已落盘的 YAML
      // （readTunFlagsFromConfig 解析 `ipv6:`），保证 TUN 与内核同源。
      // DNS 恒接管，不需要任何开关下发（生成器恒写 enable/dns-hijack）。
      // 传明确模式及单一激活名单；JSON 保留包名边界，不再通过 CSV 猜测模式。
      const vpnParams: Record<string, string | number | boolean> = {};
      vpnParams['configPath'] = stagedConfigPath;
      vpnParams['appRoutingMode'] = appRouting.mode;
      vpnParams['appRoutingNeedsReview'] = appRouting.needsReview;
      vpnParams['appRoutingPackagesJson'] = packagesJson;
      const want: Want = {
        bundleName: 'com.tunbox.client',
        abilityName: 'VpnExtensionAbility',
        parameters: vpnParams
      };
      // 关键防护: startVpnExtensionAbility 的 Promise 在系统授权链路异常时
      // (真机实证: checkVpnPermission datashare Query error → vpndialog 后无响应)
      // 可能永不 resolve —— 加 15s 竞速超时, 保证 UI 不会无限转圈。
      const launchFloorTs = Date.now();
      await Promise.race([
        (async (): Promise<void> => {
          await SettingsService.flushNow();
          await vpnExtension.startVpnExtensionAbility(want);
        })(),
        new Promise<void>((resolve, reject) => {
          setTimeout(() => {
            reject(new Error('VPN 扩展拉起超时（15s）：系统授权弹窗未完成或扩展无法启动，请重试'));
          }, 15000);
        })
      ]);
      // 送达确认：start 落在旧扩展进程退出窗口内会被系统静默吞并（无 onCreate、
      // 无错误），readiness 只能干等 30s。5s 内未见 onCreate epoch → 重发一次；
      // 仍无送达则报可行动的专属错误（不计入节点失败）。
      if (!(await this.awaitLaunchEpoch(launchFloorTs))) {
        AppLogger.warn(TAG, 'launch epoch missing (start swallowed by system exit window?); re-launching once');
        try {
          const stopAgain: Want = {
            bundleName: 'com.tunbox.client',
            abilityName: 'VpnExtensionAbility'
          };
          await vpnExtension.stopVpnExtensionAbility(stopAgain);
        } catch (stopError) {
          // 未运行时停止报错属正常
        }
        await new Promise<void>((resolve) => setTimeout(() => resolve(), 600));
        this.clearStartError();
        const retryFloorTs = Date.now();
        await Promise.race([
          (async (): Promise<void> => {
          await SettingsService.flushNow();
          await vpnExtension.startVpnExtensionAbility(want);
        })(),
          new Promise<void>((resolve, reject) => {
            setTimeout(() => {
              reject(new Error('VPN 扩展重试拉起超时（15s）'));
            }, 15000);
          })
        ]);
        if (!(await this.awaitLaunchEpoch(retryFloorTs))) {
          throw new Error('VPN 扩展进程未接收本次拉起（系统竞态，已自动重发一次仍无响应），'
            + '请稍等几秒后再点连接；反复出现请重启手机清除驻留进程');
        }
      }
      tLaunch = Date.now() - connectT0;

      this.api.resetTrafficBaseline();
      this.api.setEndpoint(this.apiPort, this.apiSecret);
      const deadline = Date.now() + 30000;
      let apiReady = false;
      let readinessDelayMs = 0;
      let launchRetryDone = false;
      try {
      while (Date.now() < deadline) {
        if (seq !== this.connectSeq) {
          await this.disconnectInternal(intentGeneration);
          return false;
        }
        // 1) 失败信号优先：扩展进程回写的错误
        const extErr = this.readStartError();
        if (extErr.length > 0) {
          if (extErr.indexOf('应用分流参数缺失或冲突') >= 0 && !launchRetryDone) {
            // want 被系统整体丢弃且参数回退文件也不可用 —— 静默重跑一次完整
            // stop → 快照 → start：第二次要么参数完整抵达, 要么落盘文件已可用。
            // 属系统竞态, 与节点质量无关: 不计失败、不惊动用户。
            launchRetryDone = true;
            AppLogger.warn(TAG, 'extension lost want params (system restart path); retrying stop→start once');
            try {
              const retryStop: Want = {
                bundleName: 'com.tunbox.client',
                abilityName: 'VpnExtensionAbility'
              };
              await vpnExtension.stopVpnExtensionAbility(retryStop);
            } catch (stopError) {
              // 扩展未运行时停止报错属正常
            }
            await new Promise<void>((resolve) => setTimeout(() => resolve(), 600));
            this.writeStartParamsFile(stagedConfigPath, appRouting.mode, appRouting.needsReview, packagesJson);
            this.clearStartError();
            await Promise.race([
              (async (): Promise<void> => {
          await SettingsService.flushNow();
          await vpnExtension.startVpnExtensionAbility(want);
        })(),
              new Promise<void>((resolve, reject) => {
                setTimeout(() => {
                  reject(new Error('VPN 扩展重试拉起超时（15s）'));
                }, 15000);
              })
            ]);
            continue;
          }
          throw new Error(`Clash 内核启动失败: ${extErr}`);
        }
        // 2) 成功信号：扩展回写 OK 标记，且 loopback 探测通过（此时接口必然已绑定）
        if (this.readStartOk() && await this.api.healthProbe()) {
          apiReady = true;
          break;
        }
        readinessDelayMs = nextReadinessDelayMs(readinessDelayMs);
        const remainingMs = deadline - Date.now();
        if (remainingMs > 0) {
          await new Promise<void>((resolve) =>
            setTimeout(() => resolve(), Math.min(readinessDelayMs, remainingMs)));
        }
      }
      if (!apiReady) {
        const extErr = this.readStartError();
        if (extErr.length > 0) {
          throw new Error(`Clash 内核启动失败: ${extErr}`);
        }
        // 端口上有活着的控制器、却不认我们的 secret → 是别的 Clash/mihomo 系应用在
        // 占用（其 VPN 扩展常驻 + 自动重连会把本端挤死）。给出可行动的提示，替代
        // 原来那句只能「反馈日志」的死胡同报错。
        if (await this.detectForeignControllerBusy()) {
          throw new Error(`端口 ${this.apiPort} 上检测到其他代理应用的内核在运行（如 NekoBox 等 Clash/mihomo 系`
            + '应用）。两者不能同时工作：请先在对方应用内断开并停用其后台 VPN 扩展，或直接卸载，再重试；'
            + '仍失败请重启手机清除驻留进程');
        }
        if (this.readStartOk()) {
          throw new Error(`内核已启动但 API 探测失败（端口 ${this.apiPort} 跨进程不可达），请反馈日志`);
        }
        throw new Error('Clash API 未就绪（30s 超时）：VPN 扩展未上报启动结果，请重试或反馈日志');
      }
      } catch (startError) {
        // 内核拒载（parse config / unmarshal）⇒ 落盘这份配置是坏的。
        // 回滚到最后一份真正连上过的配置，用户下一次点连接就能起来，
        // 而不是每次都被同一份坏配置挡住（内核对坏配置是整份拒载）。
        const errorText = AppLogger.errText(startError);
        // 规则集坏文件自愈（2026-10-23）：配置文本本身没问题、但 rule-provider 文件
        // 解不开时，内核同样整份拒载。这类失败必须**隔离坏文件**而不是回滚配置，
        // 否则回滚后的配置依旧引用同一个坏 .mrs，用户会一直连不上（用户实测：
        // 手动更新去广告规则后必失败，删掉规则集就正常）。
        if (this.looksLikeRuleSetFailure(errorText)) {
          const outcome = this.healRuleSet('kernel rejected rule-provider');
          if (outcome === 'restored') {
            throw new Error(`${errorText}\n已回滚到上一份可用去广告规则集，再点一次连接即可。`);
          }
          if (outcome === 'quarantined') {
            throw new Error(`${errorText}\n已自动隔离损坏的去广告规则集，再点一次连接即可`
              + '（本次不带去广告规则；可在「设置 → 数据与规则」重新更新）。');
          }
        }
        if (errorText.indexOf('parse config') >= 0 || errorText.indexOf('unmarshal') >= 0) {
          if (this.restoreLastGoodConfig()) {
            throw new Error(`${errorText}\n已自动回滚到上一份可用配置，再点一次连接即可。`);
          }
        }
        throw new Error(errorText);
      }
      tReady = Date.now() - connectT0;
      this.confirmProfileApplied('tunnel');
      // 内核已经成功吃到这份配置（含 rule-provider）→ 当前规则集记为 last-good，
      // 供下次更新到坏文件时回滚（见 healRuleSet / snapshotRuleSetGood）。
      this.snapshotRuleSetGood();

      // ── 节点钉选：**必须**在 state=CONNECTED 之前完成（2026-10-19 稳定性回退）──
      //
      // 0.4.0 曾把这段改成「先上屏已连接、再 fire-and-forget 补钉选」，理由是省掉
      // PUT /proxies 的 100–500ms 内核往返。但 YAML 里开着 `store-selections: true`
      // （ClashConfigGenerator 的 experimental 段），内核冷启动会**恢复上次持久化的
      // 组选点**，而不是用配置里 unshift 到首位的目标节点。于是「已连接」上屏到钉选
      // 真正生效之间存在一个 100–500ms 的窗口，窗口内新建的连接走的是**上一次选过的
      // 节点**（可能已失效/已被用户换掉）—— 真机表现就是「连上了但代理不生效、公网
      // IP 查不到、个别用户整条链路不通」，且只在选点与上次不同时才复现。
      //
      // 现在的语义（与 0.3.3 一致，另加读回校验）：
      //   ① await 钉选 → ② 读回 PROXY 组 `now` 确认真的生效 → ③ 才置 CONNECTED。
      //
      // ⚠ 钉选失败**只 warn、不抛错**（严格对齐 0.3.3）：
      //   曾经考虑「钉选失败就抛错，别让连接假装成功」，但那会引入**新的失败面**：
      //   `generate()` 会把被丢弃的非法节点过滤掉（validNodes），此时 target 可能
      //   根本不在 PROXY 组里 → PUT 必然 400 → 用户从"能连但慢"变成"完全连不上"。
      //   用户的要求是「任何场景都不能出现启动代理不可用」，所以宁可保留 0.3.3 的
      //   宽松语义：钉选失败 = 内核按配置里 PROXY 组首个成员（=本次目标节点）走，
      //   这正是我们生成 YAML 时 unshift 保证的顺序。读回日志用于事后定位。
      const pinSmartGroup = built.options.useSmart && settings.autoSelectMode === AutoSelectModes.AUTO
        // 生成器写的是带引号形式（`- name: "♻️ 自动选择"`）；旧检查不带引号永远匹配
        // 不上 → 自动模式一直在钉选用户手动节点（2026-10-25 真机实证「没有去优选」）。
        && yaml.includes(`name: "${ClashConfigGenerator.SMART_GROUP_NAME}"`);
      const pinTargetName: string = pinSmartGroup ? ClashConfigGenerator.SMART_GROUP_NAME : effectiveName;
      // A provider-only profile can start with its own default group policy.
      // Explicit user picks must be confirmed through the actual group graph.
      // 只有「目标本来就是 profile 伪节点且没有被改名」时才跳过钉选。
      // 钉选阶段硬预算（2026-10-27 二次修）：任何一条兜底路径都不得把用户按在
      // 「正在连接」上爬几分钟。实测旧实现这里会空转 134s。
      const pinT0: number = Date.now();
      // 钉选阶段开始前再过一道事务门禁：用户可能刚刚停止/切了节点。
      if (!attempt.checkpoint(this.attempts.currentGeneration())
        || seq !== this.connectSeq || this.disconnectRequested) { return false; }
      const PIN_PHASE_BUDGET_MS: number = 12000;
      // ── 内核优先（2026-10-27 架构收口，用户报障定案）────────────────────
      // `profile.store-selected: true` 已开、设备 cache.db 也在 ⇒ 内核**本来就把每个
      // 组的当前选择持久化了**。旧实现却每次冷启动拿 `settings.preferredNodeName`
      // 去覆盖它：换机场后那个名字属于旧订阅（真机 `新加坡01aws`）→ 覆盖必然失败 →
      // 134s 空转 →「节点选择未生效」。现在按 FlClash 口径，优先级：
      //   ① 用户偏好**严格命中**主组叶子成员 → 钉它（保留用户意图）；
      //   ② 主组 `now` 是合法叶子 → **直接采用，不 PUT**（这就是上次的真实出口）；
      //   ③ 都不成立 → 才走 resolvePinTarget（地区自愈）/ 内核叶子兜底。
      const kernelSel: KernelGroupSelection | null =
        await this.api.readKernelSelection(built.ruleGroupName);
      // 用户意图是否**真的落在本次配置里**（精确/归一化命中，见 RuntimeConfigResult.pinMatched）。
      // 地区自愈 / 组内首叶子都是替身，不算意图落地。
      // 2026-10-28 用户报障定案：未连接时在同一订阅里改选节点，连上却用回「切订阅时
      // 第一个选的节点」—— 根因就是这里：旧代码**逐字节**比较内核成员名，差一个 emoji
      // 就判 userPickValid=false，于是走进「认内核旧出口」分支，把用户刚选的节点抛了。
      const intentLive: boolean = built.pinMatched && target.name.length > 0;
      let userPickValid: boolean = false;
      // PUT 必须发**内核里的真实名字**（App 侧名字可能与内核对不上，差 emoji/空格）。
      let kernelPickName: string = '';
      if (kernelSel !== null && !pinSmartGroup) {
        kernelPickName = RuntimeConfigBuilder.kernelLeafFor(kernelSel.leafMembers,
          intentLive ? target.name : effectiveName);
        userPickValid = kernelPickName.length > 0;
      }
      let finalNodeName: string = effectiveName;
      let fallbackNode: ProxyNode | null = null;
      let pinned: boolean = false;
      if (userPickValid) {
        pinned = await this.api.selectNode(kernelPickName);
        if (pinned) { finalNodeName = kernelPickName; }
      }
      if (!pinned && (effectiveName === target.name && target.id.startsWith('profile:'))) {
        pinned = true;
      }
      // 显式钉选（本次配置里的目标节点）优先于内核旧状态：用户刚选的必须赢。
      if (!pinned && pinTargetName.length > 0) {
        pinned = await this.api.selectNode(pinTargetName);
        if (pinned) { finalNodeName = pinTargetName; }
      }
      // 只有**没有可用用户意图**时，才认内核既有出口（store-selected 持久化的上次选择）。
      // 有意图却因为名字差异落不下去时，诚实地用配置里的目标 + 日志，不得拿旧出口顶替。
      let adoptedByKernel: boolean = false;
      if (!pinned && !intentLive && kernelSel !== null && !pinSmartGroup && kernelSel.nowIsLeaf) {
        pinned = true;
        adoptedByKernel = true;
        finalNodeName = kernelSel.now;
        AppLogger.info(TAG, `pin adopted kernel selection: group="${kernelSel.group}" `
          + `now="${kernelSel.now}" (skipped PUT)`);
      }
      if (adoptedByKernel && target.name.length === 0) {
        // 没有任何用户偏好时才把内核出口记成偏好；有偏好却落不下去的场合必须保留
        // 用户选择，否则节点页的勾选会被默默改掉（用户会以为 App 在跟他抢控制权）。
        await this.selfHealPreferredNode(finalNodeName, tunnelProfile.nodes ?? [],
          target.subscriptionId);
      }
      // provider-only 订阅：文本里的组只有内部占位符，真实成员由内核 `use: provider`
      // 运行时注入，文本无法预知。此时按当前订阅的节点表逐个试钉（只限同一订阅，
      // 绝不跨订阅猜），成功即自愈偏好。
      const candidates: ProxyNode[] = target.subscriptionId.length > 0
        ? subs.nodesOf(target.subscriptionId) : tunnelProfile.nodes;
      if (!pinned && candidates.length > 0) {
        let attempted: number = 0;
        for (const cand of candidates) {
          if (attempted >= 8 || Date.now() - pinT0 >= PIN_PHASE_BUDGET_MS) { break; }
          if (cand.name.length === 0 || cand.name === pinTargetName
            || cand.name.startsWith('__') || cand.id.startsWith('profile:')
            || cand.server.length === 0
            || cand.name.includes('剩余') || cand.name.includes('到期')) {
            continue;
          }
          attempted++;
          if (await this.api.selectNode(cand.name)) {
            pinned = true;
            finalNodeName = cand.name;
            fallbackNode = cand;
            break;
          }
        }
        if (pinned && fallbackNode !== null) {
          AppLogger.warn(TAG, `pin "${pinTargetName}" failed; auto-pinned "${finalNodeName}" `
            + `from current subscription instead`);
          this.lastNode = fallbackNode;
          this.lastNodeName = finalNodeName;
          // 只有用户本就没选（intentLive=false）时才把这枚兵子记成偏好；
          // 用户明确选了却钉不上，保留他的选择，下次刷新/重连再试（不默默改勾选）。
          if (!intentLive) {
            try {
              await SettingsService.patchSettings((p: AppSettings): void => {
                p.preferredNodeId = fallbackNode !== null ? fallbackNode.id : '';
                p.preferredNodeName = finalNodeName;
                p.preferredNodeSubscriptionId = fallbackNode !== null
                  ? fallbackNode.subscriptionId : target.subscriptionId;
                p.preferredNodeNamesBySubscription = AppSettings.rememberPreferredNodeName(
                  p.preferredNodeNamesBySubscription,
                  fallbackNode !== null ? fallbackNode.subscriptionId : target.subscriptionId,
                  finalNodeName);
              });
            } catch (e) {
              AppLogger.warn(TAG, `self-heal fallback node failed: ${AppLogger.errText(e)}`);
            }
          }
        }
      }
      if (!pinned && Date.now() - pinT0 < PIN_PHASE_BUDGET_MS) {
        AppLogger.warn(TAG, `pin failed for ${pinTargetName}; retrying before fail-fast`);
        const retryDelays: number[] = [500, 1000, 1500];
        for (const delayMs of retryDelays) {
          if (Date.now() - pinT0 >= PIN_PHASE_BUDGET_MS) { break; }
          await new Promise<void>((resolve) => setTimeout((): void => resolve(), delayMs));
          if (await this.api.selectNode(pinTargetName)) {
            pinned = true;
            break;
          }
        }
      }

      if (!pinned && Date.now() - pinT0 < PIN_PHASE_BUDGET_MS) {
        // ── 冷启动竞态容错（2026-10-27 二次修，真机实测 21:08:52→21:10:37）──────
        // 旧实现拿 **App 侧节点表**逐个试钉：换机场/机场改名后那份表全是**旧订阅的
        // 名字**，每个候选还要吃满 3s 收敛窗口 —— 实测 47 个候选 ≈ 134s 静默空转，
        // 用户看到的就是「一直正在连接」，最后才报「节点选择未生效」。
        // 现在只走两条快路，整段受 PIN_PHASE_BUDGET_MS 约束，且逐次可追：
        //   ① 最终 YAML 认定的节点（buildRuntimeConfig 已按地区关键词自愈过）；
        //   ② 内核 /proxies 里该策略组真实存在的第一个叶子节点（唯一事实源）。
        const yamlFirst: string = built.effectiveNodeName ?? '';
        if (yamlFirst.length > 0 && yamlFirst !== pinTargetName
          && Date.now() - pinT0 < PIN_PHASE_BUDGET_MS) {
          if (await this.api.selectNode(yamlFirst)) {
            pinned = true;
            finalNodeName = yamlFirst;
            AppLogger.warn(TAG, `pin fallback: yaml-first "${yamlFirst}" accepted`);
          }
        }
        if (!pinned && Date.now() - pinT0 < PIN_PHASE_BUDGET_MS) {
          const kernelPick: string | null = await this.api.selectLeafFromKernelGroup(built.ruleGroupName);
          if (kernelPick !== null) {
            pinned = true;
            finalNodeName = kernelPick;
            AppLogger.warn(TAG, `pin fallback: kernel pick "${kernelPick}" accepted`);
          }
        }
        if (pinned) {
          // 落到的节点与用户偏好不一致时必须自愈偏好，否则下次冷启动再踩同一个死名字。
          await this.selfHealPreferredNode(finalNodeName, tunnelProfile.nodes ?? [],
            target.subscriptionId);
        } else {
          AppLogger.warn(TAG, `pin fallback exhausted in ${Date.now() - pinT0}ms `
            + `(node="${pinTargetName}" group="${built.ruleGroupName}")`);
        }
      }

      if (!pinned) {
        // 最后一道闸（唯一判定点）：链路其实已经可用时**绝不能**判失败。
        // 重新问一次内核 —— 只要放弃钉选的这段时间里内核已落到某个叶子节点，
        // 就认它并把偏好回写成内核真相；否则才 fail-fast（b9.no-fake-success 契约）。
        const recheck: KernelGroupSelection | null =
          await this.api.readKernelSelection(built.ruleGroupName);
        if (recheck !== null && recheck.nowIsLeaf) {
          pinned = true;
          adoptedByKernel = true;
          finalNodeName = recheck.now;
          AppLogger.warn(TAG, `pin "${pinTargetName}" gave up but kernel already routes via `
            + `"${recheck.now}" (group="${recheck.group}"); adopting it`);
          await this.selfHealPreferredNode(finalNodeName, tunnelProfile.nodes ?? [],
            target.subscriptionId);
        } else {
          AppLogger.error(TAG, `pin failed for "${pinTargetName}" `
            + `(group="${built.ruleGroupName}" elapsed=${Date.now() - pinT0}ms)`);
          throw new Error(`节点选择未生效：${pinTargetName}，未将本次连接标记为成功`);
        }
      }

      // ── 单一事实源：本次连接目标（组 + 节点 + 来源）──────────────────────
      // 之后 UI/日志/快照一律读它，不再各自维护「显示节点」与「连接节点」两套状态。
      // 2026-10-27：节点名来自内核回读收敛（finalNodeName），来源用枚举，
      // 并带上 profileRevision + generation —— 迟到的旧事务写回可被直接丢弃。
      const chosenSource: ConnectionTargetSource = adoptedByKernel
        ? ConnectionTargetSource.KERNEL
        : (finalNodeName === target.name ? ConnectionTargetSource.USER : ConnectionTargetSource.YAML);
      this.kernelSelection.set(new ConnectionTarget(built.ruleGroupName, finalNodeName,
        chosenSource, attempt.profileId, Date.now(),
        this.pendingProfileRevision, attempt.generation));
      ConnectionEvents.emit(ConnEvent.exit(built.ruleGroupName, finalNodeName));
      AppLogger.info(TAG, `connection target: ${this.kernelSelection.label()} `
        + `source=${chosenSource} ${attempt.label()}`);

      // 提交前的最后一道事务门禁：任何旧事务/用户停止都在这里出局。
      if (!attempt.checkpoint(this.attempts.currentGeneration()) || seq !== this.connectSeq
        || this.disconnectRequested) {
        await this.disconnectInternal(intentGeneration);
        return false; // 已被更新的连接请求/用户停止取代
      }

      // 连接成功事件会同步通知数据页；必须先把 App HTTP 请求接入 mixed-port 并探测就绪，
      // 否则订阅方在事件回调里立刻查询出口 IP 时，usingProxy 会是 false，绕过代理。
      await this.activateAppHttpProxy('connect');
      this.setState(ConnState.CONNECTED);
      attempt.complete();
      this.startedAt = Date.now();
      this.recoveryAttempts = 0;
      this.startMonitors();
      this.clearStartError(); // 连接成功，清掉启动标记文件
      // 内核已接受本次配置 ⇒ 才把暂存文件提升为**正式配置**（2026-10-22 冷启动口径）：
      // 写 `${configPath}.tmp` 再 rename（同目录 rename 原子），任何时刻磁盘上都有一份完整文件；
      // 拒载路径从来不走到这里 ⇒ 正式配置保持上一份能用的字节。
      this.acceptStagedConfig(stagedConfigPath, configPath, preparedConfig);
      // 本次配置已被内核接受并真的连上 → 留作 last-good，供未来拒载时回滚。
      this.snapshotLastGoodConfig(preparedConfig);
      // 重连成功 → 取消挂起的退避定时器并复位尝试计数（禁止重连风暴）
      this.reconnectManager().resetAttempts();
      this.reconnectManager().cancel('connected');
      this.notify();
      AppLogger.info(TAG, `connect timing: prep=${tPrep}ms prelaunch=${tPrelaunch}ms`
        + ` launch=${tLaunch}ms ready=${tReady}ms pinned=${Date.now() - connectT0}ms`
        + ` total=${Date.now() - connectT0}ms`);
      // 连接快照升格为 connected：同代写入。期间若用户已推进新代次（又点了
      // 断开或连接）则放弃写入 —— 绝不用旧结果覆盖更新的用户意图。
      const committed = await this.updateSessionSnapshot(intentGeneration, true, 'connected',
        finalNodeName, this.startedAt);
      if (!committed) {
        AppLogger.warn(TAG, 'session generation moved on during connect; snapshot not overwritten');
      }
      // 集成点③：连接成功 → 复位该节点连续失败统计（复用 NodeSortPersistence 记录结构）
      await this.recordNodeSuccess(finalNodeName);
      if (seq !== this.connectSeq || this.disconnectRequested) {
        await this.disconnectInternal(intentGeneration);
        return false;
      }
      // 通知权限从未授予时弹一次系统授权框（真机 1600004 disabled 实锤：
      // 不授权则常驻通知发不出，通知栏只剩系统 VPN 通知的运行时长）
      TunBoxNotifier.ensurePermission(this.context).catch((e: Object): void => {
        AppLogger.warn(TAG, `ensure notification permission failed: ${AppLogger.errText(e)}`);
      });
      // 节点/速率/时长合并进系统长时任务通知（LIVE_VIEW），应用自有常驻通知已废除
      // —— 两条通知重复（用户实锤），这里只清掉可能残留的旧 id-1001
      TunBoxNotifier.cancel().catch((): void => {});
      this.notify();
      AppLogger.info(TAG, `connected to node ${finalNodeName}`);
      // 隧道就绪时 App HTTP 代理已在 CONNECTED 事件发出前挂好（见上方），
      // 避免 IP 查询先于 apply() 启动而从物理网卡直连。
      // P0-2 订阅自救：连接成功 → 隧道已可用（拉订阅天然走 VPN 出网），
      // 把此前网络性拉取失败（被阻断面板）的订阅自动补拉一次。只记日志不弹 UI：
      // 这是无感修复，失败也不影响本次连接结果（advice 已在原失败时提示过用户）。
      this.retryPendingSubscriptionFetches(subs);
      if (!geoipReady) {
        // 后台补齐 geoip.metadb（多镜像）, 下次连接即可启用 GEOIP 直连规则
        this.downloadGeoipInBackground(settings.assetSource);
      }
      return true;
    } catch (e) {
      const errorMessage = AppLogger.errText(e);
      try {
        await this.disconnectInternal(intentGeneration);
      } catch (cleanupError) {
        AppLogger.warn(TAG, `connect rollback failed: ${AppLogger.errText(cleanupError)}`);
      }
      if (seq !== this.connectSeq || this.disconnectRequested) { return false; }
      this.setState(ConnState.DISCONNECTED);
      this.startedAt = 0;
      this.ipv6Active = false;
      this.traffic = { uploadBytes: 0, downloadBytes: 0, uploadSpeed: 0, downloadSpeed: 0 };
      this.api.resetTrafficBaseline();
      this.api.setEndpoint(this.apiPort, '');
      this.lastError = errorMessage;
      this.notify();
      AppLogger.error(TAG, `connect failed: ${errorMessage}`);
      // 集成点③：连接失败 → 累加节点连续失败统计（复用 NodeSortPersistence 记录结构）
      // want 丢参 / start 被系统竞态吞没 / 内核启动期联网下载阻塞均属拉起环节系统问题
      // （与节点质量无关），不惩罚节点 —— 否则会把可用节点误标失败并触发无谓换节点。
      // 配置校验未通过同理：**换节点也救不了**（同一份订阅生成的配置一样坏），
      // 所以既不记节点失败，也不做健康自检/换节点 —— 否则会拿着同一份坏配置反复重连。
      const configRejected = errorMessage.indexOf('配置校验未通过') >= 0;
      if (!configRejected &&
        errorMessage.indexOf('应用分流参数缺失或冲突') < 0 &&
        errorMessage.indexOf('VPN 扩展进程未接收本次拉起') < 0 &&
        errorMessage.indexOf('内核启动超时') < 0) {
        await this.recordNodeFailure(this.lastNodeName);
      }
      this.failedConnectSeq = seq;
      return false;
    }
  }

  /**
   * 把「这次实际钉上的节点」写回偏好，避免下次冷启动继续拿旧名字撞墙
   * （2026-10-27 二次修：换机场后 preferredNodeName 是旧订阅的 `新加坡01aws`，
   *  最终 YAML 里只有 `🇸🇬新加坡•移联01` —— 不自愈就会永久复现「节点选择未生效」）。
   */
  private async selfHealPreferredNode(nodeName: string, nodes: ProxyNode[],
    fallbackSubId: string): Promise<void> {
    let matched: ProxyNode | null = null;
    for (const n of nodes) {
      if (n.name === nodeName) { matched = n; break; }
    }
    if (matched === null) {
      // 节点表没带全（例如内核回报了别的订阅里的出口）时按名再查一次。
      // 先按「当前 profile」作用域查找，避免把别家订阅的同名节点当成本次偏好。
      const svc = SubscriptionService.instance();
      const scoped = svc.resolveUserPreference('', nodeName);
      matched = scoped !== null ? scoped : svc.nodeByNameCurrent(nodeName);
    }
    this.lastNode = matched;
    this.lastNodeName = nodeName;
    const subId: string = matched !== null ? matched.subscriptionId : fallbackSubId;
    try {
      await SettingsService.patchSettings((p: AppSettings): void => {
        // 2026-10-27 真机回归修复：matched=null 时**不得清空 preferredNodeId**。
        // id 只是快速索引，名称才是跨刷新稳定锚；清空 id 会让节点页的
        // 「已选」复选框变空，而内核实际仍走该节点（用户看到的就是“没勾选却连着它”）。
        if (matched !== null) {
          p.preferredNodeId = matched.id;
        }
        p.preferredNodeName = nodeName;
        if (subId.length > 0) {
          p.preferredNodeSubscriptionId = subId;
          p.preferredNodeNamesBySubscription = AppSettings.rememberPreferredNodeName(
            p.preferredNodeNamesBySubscription, subId, nodeName);
        }
      });
    } catch (e) {
      AppLogger.warn(TAG, `self-heal preferred node failed: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * P0-2 订阅自救：连接成功后补拉此前网络性失败的订阅（fire-and-forget）。
   *
   * 只取 SubscriptionService.pendingNetworkRetry 中仍在 TTL 内的 id，
   * 走既有 refreshSubscription（304/ETag/诊断语义零改动），结果只写日志。
   * 延迟 3s 启动：给 readiness 轮询/流量监控留出稳定的隧道建立窗口，
   * 避免与首包探测抢带宽造成误判。
   */
  private retryPendingSubscriptionFetches(subs: SubscriptionService): void {
    setTimeout((): void => {
      try {
        const ids = subs.takePendingNetworkRetries();
        if (ids.length === 0) {
          return;
        }
        AppLogger.info(TAG, `subscription self-heal after connect: ${ids.length} pending`);
        for (const id of ids) {
          subs.refreshSubscription(id)
            .then((result): void => {
              AppLogger.info(TAG, `self-heal refresh ${id}: status=${result.status} `
                + `nodes=${result.nodeCount}`);
            })
            .catch((e: Object): void => {
              AppLogger.warn(TAG, `self-heal refresh ${id} failed: ${String(e)}`);
            });
        }
      } catch (e) {
        AppLogger.warn(TAG, `subscription self-heal error: ${String(e)}`);
      }
    }, 3000);
  }

  disconnect(): Promise<void> {
    this.requestDisconnect();
    if (this.disconnectTask !== null) {
      return this.disconnectTask;
    }
    const task = this.lifecycleWrites.then((): Promise<void> => this.disconnectExclusive());
    this.lifecycleWrites = task.then((): void => {}, (): void => {});
    this.disconnectTask = task;
    const clear = (): void => {
      if (this.disconnectTask === task) {
        this.disconnectTask = null;
      }
    };
    task.then(clear, clear);
    return task;
  }

  private async disconnectExclusive(): Promise<void> {
    // 2026-10-20 自动断开整改：修复期重连（repairReconnect）里的"断开"只是
    // 重建隧道的一步，不该把 UI 落成"已断开"——那会让用户以为掉线，卡片也会在
    // 重连窗口里闪断。修复全程保持 RECOVERING。
    // 2026-10-27：改走 setState（唯一写入口），否则订阅方收不到事件，UI 会滞后。
    this.setState(this.inRepairConnect ? ConnState.RECOVERING : ConnState.DISCONNECTING);
    await this.disconnectInternal();
    this.setState(this.inRepairConnect ? ConnState.RECOVERING : ConnState.DISCONNECTED);
    this.startedAt = 0;
    this.traffic = { uploadBytes: 0, downloadBytes: 0, uploadSpeed: 0, downloadSpeed: 0 };
    this.api.resetTrafficBaseline();
    this.disconnectRequested = false;
    this.notify();
    AppLogger.info(TAG, this.inRepairConnect ? 'repair-disconnected (kept RECOVERING)' : 'disconnected');
  }

  /** 后台下载 geoip.metadb 到内核 home 目录（cacheDir），成功后下次连接启用 GEOIP 直连规则 */
  private geoipDownloading: boolean = false;

  /** 校验下载 buffer 的魔数（geoip=AB CD EF 4D；model="tree"；ruleset 仅查体积） */
  private static bufferMagicOk(buf: ArrayBuffer, magic: number[]): boolean {
    if (buf.byteLength < magic.length) {
      return false;
    }
    const head = new Uint8Array(buf, 0, magic.length);
    for (let i = 0; i < magic.length; i++) {
      if (head[i] !== magic[i]) {
        return false;
      }
    }
    return true;
  }

  /**
   * 共享的可等待资产下载：镜像按偏好重排后逐个尝试，成功（状态 200 + 体积 + 魔数）
   * 才落盘，绝不把错误页写进内核 home（坏文件会让内核删档重下 → 90s 阻塞坑）。
   */
  private async downloadAsset(mirrors: AssetMirror[], destPath: string, minSize: number,
    validate: (buf: ArrayBuffer) => boolean, source: string, what: string): Promise<boolean> {
    const ordered = reorderAssetMirrors(mirrors, source);
    // Bounded transport allocation + validation; magic is format checking, NOT authenticity.
    const maxSize = 64 * 1024 * 1024;
    let idx = 0;
    for (const mirror of ordered) {
      const tempPath = `${destPath}.download-${Date.now()}-${idx}.tmp`;
      const client = http.createHttp();
      try {
        const resp = await client.request(mirror.url, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: 15000,
          // geo/规则集/模型都托管在 GitHub：必须跟着隧道走，否则国内必失败
          usingProxy: AppProxyRoute.isReady(),
          // Model.bin 9.3MB 而且只能从 GitHub release 资产的限速前缀代理取
          // （实测 gh-proxy 120s 只下到 5.9MB ⇒ 至少需要 ~190s），所以保留长超时；
          // 代价是设置页会一直显示「更新中…」，由 downloadSmartModelAsset 的
          // 并发守卫 + 手动更新提示来解释，而不是把慢但能成的下载改成必失败。
          readTimeout: what === 'Model.bin' ? 300000 : 90000,
          maxLimit: maxSize
        });
        const buf = resp.result as ArrayBuffer;
        if (resp.responseCode === 200 && buf instanceof ArrayBuffer
          && buf.byteLength > minSize && buf.byteLength <= maxSize && validate(buf)) {
          const file = fs.openSync(tempPath,
            fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          try {
            const written = fs.writeSync(file.fd, buf);
            if (written !== buf.byteLength) { throw new Error('short asset write'); }
            fs.fsyncSync(file.fd);
          } finally {
            fs.closeSync(file);
          }
          // Same-directory rename replaces atomically; never unlink the old asset first.
          fs.renameSync(tempPath, destPath);
          AppLogger.info(TAG, `${what} downloaded (${buf.byteLength} bytes, source=${mirror.tag})`);
          return true;
        }
        AppLogger.warn(TAG, `${what} mirror ${idx}(${mirror.tag}) returned ${resp.responseCode},`
          + ` size ${buf.byteLength}`);
      } catch (e) {
        AppLogger.warn(TAG, `${what} mirror ${idx}(${mirror.tag}) failed: ${e}`);
      } finally {
        client.destroy();
        try { fs.unlinkSync(tempPath); } catch (e) { /* renamed or never created */ }
      }
      idx = idx + 1;
    }
    return false;
  }

  /** 等待型 geoip.metadb 下载（设置页手动更新与连接后台补齐共用） */
  private async downloadGeoipAsset(source: string): Promise<boolean> {
    if (this.geoipDownloading || this.context === null) {
      return false;
    }
    this.geoipDownloading = true;
    try {
      const dest = `${this.context.cacheDir}/geoip.metadb`;
      // 校验 MMDB 魔数（0xAB 0xCD 0xEF 'M'），不能只看体积：坑 39 的教训是
      // CDN 错误页/拦截页同样可能很大，一旦把非 MMDB 内容按 geoip.metadb 落盘，
      // 内核侧 mmdb.Verify 会判定无效并**删除文件后重新联网下载**，等于把坑 40
      // 又引回来（config.Parse 阶段同步阻塞）。宁可下载失败，也不要写坏文件。
      // 真源 8.4MB：体积下限 4MB（半截下载必小于它），标记在**尾部**而非头部
      // （旧头部魔数判据把合法文件全判成坏，见 isGeoipReady 注释）。
      return await this.downloadAsset(GEOIP_MIRRORS, dest, 1024 * 1024 * 4,
        (buf: ArrayBuffer): boolean => ConnectionOrchestrator.bufferTailMagicOk(buf),
        source, 'geoip.metadb');
    } finally {
      this.geoipDownloading = false;
    }
  }

  /** 连接路径的后台补齐（fire-and-forget，失败下次连接重试） */
  private downloadGeoipInBackground(source: string = 'auto'): void {
    this.downloadGeoipAsset(source).then((ok: boolean): void => {
      if (!ok) {
        AppLogger.warn(TAG, 'geoip.metadb download failed from all mirrors; will retry on next connect');
      }
    }).catch((e: Object): void => {
      AppLogger.warn(TAG, `geoip download task error: ${e}`);
    });
  }

  /**
   * geoip.metadb 是否**真正可用**（存在 + 体积够 + MMDB 魔数正确）。
   *
   * 只判 `size > 0` 是不够的：文件存在但内容损坏时，`useGeoip` 会误判为就绪，
   * 于是生成带 GEOIP 规则 / dns.fallback 的配置，内核在 config.Parse 阶段
   * `mmdb.Verify` 判定无效 → **删除文件并重新联网下载** → 启动期同步阻塞
   * （国内直连 github 不可达），等于把坑 40 重新引回来。
   * 魔数：MMDB 文件头前 4 字节固定为 0xAB 0xCD 0xEF 'M'。
   */
  /** geoip.metadb 尾部 MMDB 标记（`«ÍïMaxMind.com`）查找窗口 */
  private static bufferTailMagicOk(buf: ArrayBuffer): boolean {
    const marker: number[] = [0xAB, 0xCD, 0xEF, 0x4D, 0x61, 0x78, 0x4D, 0x69, 0x6E, 0x64, 0x2E,
      0x63, 0x6F, 0x6D];
    const b = new Uint8Array(buf);
    if (b.byteLength < marker.length) {
      return false;
    }
    for (let i = b.byteLength - marker.length; i >= 0; i--) {
      let hit = true;
      for (let j = 0; j < marker.length; j++) {
        if (b[i + j] !== marker[j]) {
          hit = false;
          break;
        }
      }
      if (hit) {
        return true;
      }
    }
    return false;
  }

  private isGeoipReady(): boolean {
    if (this.context === null) {
      return false;
    }
    const path = `${this.context.cacheDir}/geoip.metadb`;
    let file: fs.File | null = null;
    try {
      const size = fs.statSync(path).size;
      if (size < 1024 * 100) {
        return false;
      }
      // MMDB 元数据标记 `«ÍïMaxMind.com` 在**文件尾部**（实测 meta-rules-dat
      // geoip.metadb 8.4MB，标记位于倒数 ~185 字节；文件头是 `00 00 01 15 ...`）。
      // 旧版读头部 4 字节判魔数，真文件永远判「损坏」→ GEOIP 分流被降级；
      // 更糟的是内核 mmdb.Verify 判定损坏时会**删档并同步联网重下**，国内不可达
      // → config.Parse 阻塞 20s 超时（真机表现为「内核启动超时」）。
      // 判据改为：体积够 + 尾部窗口内存在标记。
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const window = 4096;
      const readLen = Math.min(window, size);
      const tail = new ArrayBuffer(readLen);
      // HarmonyOS fileIo 无 lseekSync：readSync 支持 options.offset（**文件内**偏移）
      // + length（读多少），第四参误传会落到缓冲区长度上。直接用 options 定位读取。
      const got = fs.readSync(file.fd, tail, { offset: size - readLen, length: readLen });
      if (got < readLen) {
        return false;
      }
      return ConnectionOrchestrator.bufferTailMagicOk(tail);
    } catch (e) {
      return false;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // ignore
        }
      }
    }
  }

  /**
   * LightGBM 模型（`Model.bin`）是否已就绪可用。
   *
   * 与 geoip.metadb 完全同源的风险：内核 `lightgbm.GetModel()` 在文件缺失时会
   * **同步联网下载** `https://github.com/vernesong/mihomo/releases/.../Model.bin`，
   * 国内直连不可达 → 实测在 config.Parse 阶段阻塞 **90.1s** 后才软失败降级
   * （比 MMDB 温和：不 hard fail，但连接已经卡到用户以为挂死）。
   * 所以只有文件真正就绪时才允许生成 `type: smart` 组。
   *
   * 魔数：LightGBM 文本模型首 4 字节为 "tree"。
   */
  private isSmartModelReady(): boolean {
    if (this.context === null) {
      return false;
    }
    const path = `${this.context.cacheDir}/Model.bin`;
    let file: fs.File | null = null;
    try {
      // 模型 9.3MB；小于 1MB 必为截断/错误页
      if (fs.statSync(path).size < 1024 * 1024) {
        return false;
      }
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const head = new ArrayBuffer(4);
      const read = fs.readSync(file.fd, head);
      if (read < 4) {
        return false;
      }
      const b = new Uint8Array(head);
      return b[0] === 0x74 && b[1] === 0x72 && b[2] === 0x65 && b[3] === 0x65; // "tree"
    } catch (e) {
      return false;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // ignore
        }
      }
    }
  }

  /**
   * 从 HAP 内置 rawfile 把 `Model.bin` 铺到内核 home（首选路径）。
   *
   * 为什么内置而不是纯联网下载：实测国内直连可达的 github 镜像里，
   * `testingcf.jsdelivr.net/gh/vernesong/mihomo@LightGBM-Model/Model.bin` **404**
   * （`LightGBM-Model` 是 release tag，不是仓库 ref，jsdelivr 取不到 release 附件），
   * `ghfast.top` / `gh.llkk.cc` / `github.moeyy.xyz` 直接连不通，
   * 只有 `gh-proxy.com` / `ghproxy.net` 可用但**限速严重**（120s 只下到 5.9MB / 9.3MB）。
   * 也就是说纯下载路径在真机上大概率失败 —— 而失败的表现就是「自动选择一直不出现」。
   * 内置后本地拷贝即可，无网络依赖、离线可用、首次连接就能生效。
   *
   * @returns 是否已就绪（铺好或本来就在）
   */
  private seedSmartModelFromRawfile(): boolean {
    if (this.context === null) {
      return false;
    }
    if (this.isSmartModelReady()) {
      return true;
    }
    const dst = `${this.context.cacheDir}/Model.bin`;
    let file: fs.File | null = null;
    try {
      const bytes: Uint8Array = this.context.resourceManager.getRawFileContentSync('Model.bin');
      if (bytes.byteLength < 1024 * 1024) {
        AppLogger.warn(TAG, `bundled Model.bin too small (${bytes.byteLength} bytes); ignoring`);
        return false;
      }
      // 魔数 "tree"：坏文件比没文件更糟 —— 内核会删掉它再联网重下（90s 阻塞）
      if (!(bytes[0] === 0x74 && bytes[1] === 0x72 && bytes[2] === 0x65 && bytes[3] === 0x65)) {
        AppLogger.warn(TAG, 'bundled Model.bin has wrong magic; ignoring');
        return false;
      }
      file = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      // fs.writeSync 只吃 ArrayBuffer。若 Uint8Array 是某个更大 buffer 的视图，
      // 直接传 .buffer 会把多余字节一起写进去 → 必须按 byteOffset/byteLength 取准。
      const ab: ArrayBuffer = (bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength)
        ? bytes.buffer as ArrayBuffer
        : bytes.slice().buffer as ArrayBuffer;
      fs.writeSync(file.fd, ab);
      AppLogger.info(TAG, `Model.bin seeded from bundle (${bytes.byteLength} bytes); smart group enabled`);
      return true;
    } catch (e) {
      AppLogger.warn(TAG, `seed Model.bin from bundle failed: ${e}`);
      return false;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // ignore
        }
      }
    }
  }

  /**
   * UI 入口：确保内置模型已铺盘，并返回内核 smart 组当前是否可用。
   *
   * 节点列表页用它决定是否展示「♻️ 自动选择」入口。这里顺带触发一次铺盘，
   * 否则用户**首次打开节点列表（还没连过）时看不到该入口** ——
   * 铺盘是本地拷贝，代价可以忽略，且只成功一次。
   */
  ensureSmartModelReady(): boolean {
    return this.seedSmartModelFromRawfile() || this.isSmartModelReady();
  }

  /**
   * 纯查询：内核 smart 选点模型是否已就位（`cacheDir/Model.bin` 非空且魔数正确）。
   *
   * 与 ensureSmartModelReady 的区别：**绝不播种、绝不下载、不碰网络**。
   * 订阅页用它决定要不要渲染「自动选择 · 内核智能优选」入口 —— 用户明确要求
   * 没有模型时把这块隐藏，所以这个判断必须是零副作用的。
   */
  isSmartModelAvailable(): boolean {
    return this.isSmartModelReady();
  }

  /** 后台下载 LightGBM 模型到内核 home（照搬 geoip 的多镜像 + 校验模式） */
  private smartModelDownloading: boolean = false;

  /** 是否有 Model.bin 下载在飞行中（设置页据此区分「正在下」与「下载失败」） */
  isSmartModelDownloading(): boolean {
    return this.smartModelDownloading;
  }

  /** 等待型 Model.bin 下载（仅内置 rawfile 铺盘失败时的兜底路径） */
  private async downloadSmartModelAsset(source: string): Promise<boolean> {
    if (this.smartModelDownloading || this.context === null) {
      return false;
    }
    this.smartModelDownloading = true;
    try {
      const dest = `${this.context.cacheDir}/Model.bin`;
      // LightGBM 文本模型魔数 "tree"；体积必须够（9.3MB）。
      // 同 geoip 的理由：坏文件比没有文件更糟 —— 内核会删掉它再联网重下。
      return await this.downloadAsset(MODEL_MIRRORS, dest, 1024 * 1024,
        (buf: ArrayBuffer): boolean => ConnectionOrchestrator.bufferMagicOk(buf,
          [0x74, 0x72, 0x65, 0x65]), source, 'Model.bin');
    } finally {
      this.smartModelDownloading = false;
    }
  }

  private downloadSmartModelInBackground(source: string = 'auto'): void {
    this.downloadSmartModelAsset(source).then((ok: boolean): void => {
      if (!ok) {
        AppLogger.warn(TAG, 'Model.bin download failed from all mirrors; '
          + 'smart group stays disabled (bundled copy also unavailable?)');
      }
    }).catch((e: Object): void => {
      AppLogger.warn(TAG, `Model.bin download task error: ${e}`);
    });
  }

  /**
   * 去广告规则集是否**可用**（存在 + 体积下限 + zstd 魔数）。
   *
   * 【2026-10-23 用户报障】手动更新去广告规则后 VPN 启动失败，删掉规则集就正常。
   *
   * 根因：手动更新走的是 GitHub 加速前缀（gh-proxy / ghfast），代理返回 **HTML/JSON
   * 错误页**（都大于 1KB，旧校验只有 `size > 0` 与下载侧 `byteLength > 1024`），
   * 坏内容被当成 .mrs 落盘。内核加载 rule-provider 时 `zstd` 解不开 / 内层头不是
   * `MRS\x01` / behavior 不匹配 → **config.Parse 整份失败 → 隧道起不来**。
   * 删掉文件后 `ruleProviderReady=false`，配置里不声明 RULE-SET，于是又能连。
   *
   * .mrs 的真实形态（mihomo `rules/provider/mrs_converter.go` + `mrs_reader.go`）：
   *   zstd frame（首 4 字节 0x28 0xB5 0x2F 0xFD）→ 解压后才是 `MRS\x01 | behavior | count …`
   * 所以「前 4 字节是 zstd 魔数」足以把错误页/半截下载挡在门外。
   *
   * 判据变了之后：文件损坏 = 视为未就绪 = 本轮配置不带 RULE-SET（隧道照常能起，
   * 只是没有去广告），而不是「带着坏文件必起不来」。
   */
  private isRuleProviderReady(): boolean {
    // 内置规则集随包发布：首次（或文件被删/坏了）就地铺一份，去广告开箱即用，
    // 不依赖「用户先手动点更新」也不依赖首次联网（2026-10-23 产品口径）。
    this.seedRuleSetFromRawfile();
    return this.ruleSetFileOk();
  }

  /**
   * 把随包内置的去广告规则集（rawfile/hyper_adrules_ads.mrs）铺到
   * `cacheDir/ruleset/hyper_adrules_ads.mrs`。
   *
   * 为什么内置（2026-10-23 用户要求）：
   *  · 规则集是去广告能力的**唯一必需品**，让它依赖一次 GitHub 下载 = 首次开开关
   *    十有八九失败（真机实测加速代理限速严重）；
   *  · 用户把「数据」页里的手动更新入口去掉后，更需要一个开箱即用的基线版本；
   *  · 之后想更新仍可走后台自动拉取（`downloadRuleProviderInBackground`）。
   *
   * 只在「目标不存在或不合法」时才写盘；已就绪（可能是更新的版本）一律不动。
   *
   * @returns 目标文件当前是否可用（铺好或本来就在）
   */
  private seedRuleSetFromRawfile(): boolean {
    if (this.context === null) {
      return false;
    }
    if (this.ruleSetFileOk()) {
      return true;
    }
    const dir = `${this.context.cacheDir}/${RULESET_SUBDIR}`;
    const dst = `${dir}/${HYPER_AD_RULES_FILE}`;
    let file: fs.File | null = null;
    try {
      try {
        ensurePrivateDir(dir);
      } catch (e) {
        AppLogger.warn(TAG, `ruleset dir create failed: ${AppLogger.errText(e)}`);
      }
      const bytes: Uint8Array = this.context.resourceManager.getRawFileContentSync(BUNDLED_RULE_SET_RAWFILE);
      if (bytes.byteLength < RULE_SET_MIN_BYTES) {
        AppLogger.warn(TAG, `bundled ruleset too small (${bytes.byteLength} bytes); ignoring`);
        return false;
      }
      // zstd 魔数与下载侧同一判据：坏文件比没文件更糟（内核会整份拒载）
      const head = bytes.slice(0, ZSTD_MAGIC.length).buffer as ArrayBuffer;
      if (!ConnectionOrchestrator.bufferMagicOk(head, ZSTD_MAGIC)) {
        AppLogger.warn(TAG, 'bundled ruleset has wrong magic; ignoring');
        return false;
      }
      file = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const ab: ArrayBuffer = (bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength)
        ? bytes.buffer as ArrayBuffer
        : bytes.slice().buffer as ArrayBuffer;
      fs.writeSync(file.fd, ab);
      AppLogger.info(TAG, `ad ruleset seeded from bundle (${bytes.byteLength} bytes); ad-block ready offline`);
      return true;
    } catch (e) {
      AppLogger.warn(TAG, `seed ad ruleset from bundle failed: ${AppLogger.errText(e)}`);
      return false;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // ignore
        }
      }
    }
  }

  /**
   * 内核启动错误文本是否指向「规则集/规则提供者」损坏。
   *
   * 覆盖 mihomo 侧可能的几类措辞：
   *  · `initial rule provider ...` / `rule-provider` / `ruleset`
   *  · `invalid MrsMagic bytes`、`invalid behavior`（mrs_reader.go 的两个显式报错）
   *  · `zstd: ...` 解压失败、`unexpected EOF`（半截下载）
   */
  private looksLikeRuleSetFailure(errorText: string): boolean {
    if (errorText.length === 0) {
      return false;
    }
    const t = errorText.toLowerCase();
    if (t.indexOf('mrs') >= 0 || t.indexOf('rule-provider') >= 0
      || t.indexOf('rule provider') >= 0 || t.indexOf('ruleset') >= 0
      || t.indexOf('rule-set') >= 0 || t.indexOf('invalid behavior') >= 0) {
      return this.ruleSetFileExists();
    }
    // zstd 解压类报错只有在规则集文件存在时才可能是它
    if (t.indexOf('zstd') >= 0 || t.indexOf('unexpected eof') >= 0) {
      return this.ruleSetFileExists();
    }
    return false;
  }

  /** 规则集文件是否存在（不看是否有效：自愈要处理的就是无效文件） */
  private ruleSetFileExists(): boolean {
    if (this.context === null) {
      return false;
    }
    try {
      fs.statSync(`${this.context.cacheDir}/${RULESET_SUBDIR}/${HYPER_AD_RULES_FILE}`);
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 规则集文件本体校验（stat 体积 + 头部 zstd 魔数），任何异常都按不可用处理 */
  private ruleSetFileOk(): boolean {
    if (this.context === null) {
      return false;
    }
    const p = `${this.context.cacheDir}/${RULESET_SUBDIR}/${HYPER_AD_RULES_FILE}`;
    try {
      const size = Number(fs.statSync(p).size);
      if (!(size >= RULE_SET_MIN_BYTES)) {
        return false;
      }
      const file = fs.openSync(p, fs.OpenMode.READ_ONLY);
      try {
        const head = new ArrayBuffer(ZSTD_MAGIC.length);
        const read = fs.readSync(file.fd, head);
        if (read < ZSTD_MAGIC.length) {
          return false;
        }
        return ConnectionOrchestrator.bufferMagicOk(head, ZSTD_MAGIC);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      return false;
    }
  }

  /**
   * 内核因规则集起不来时的自愈（2026-10-23 用户报障）。
   *
   * 两级策略：
   *  1) 有 `last-good` 副本 → **回滚**到上一份被内核成功加载过的规则集
   *     （用户在「设置 → 数据与规则」更新后坏掉时，去广告能力不丢）；
   *  2) 没有副本 → 把坏文件**隔离**成 `.bad-<时间戳>`（不删，便于排查），
   *     下一次连接生成不带 RULE-SET 的配置。
   *
   * 为什么不能只靠回滚配置：坏的是 rule-provider 文件本身，配置文本是好的；
   * 回滚后的配置照样引用同一个坏文件，用户会一直连不上（实测症状就是
   * 「更新去广告规则后起不来，删掉规则集就好了」）。
   */
  private healRuleSet(reason: string): string {
    if (this.context === null) {
      return '';
    }
    const dir = `${this.context.cacheDir}/${RULESET_SUBDIR}`;
    const p = `${dir}/${HYPER_AD_RULES_FILE}`;
    const good = `${p}${RULE_SET_GOOD_SUFFIX}`;
    try {
      const goodSize = Number(fs.statSync(good).size);
      if (goodSize >= RULE_SET_MIN_BYTES) {
        fs.renameSync(good, p);
        AppLogger.warn(TAG, `ad ruleset restored from last-good copy (${reason}, ${goodSize} bytes)`);
        return 'restored';
      }
    } catch (e) {
      // 没有 last-good 副本：走隔离
    }
    try {
      fs.renameSync(p, `${p}.bad-${Date.now()}`);
      AppLogger.warn(TAG, `ad ruleset quarantined (${reason}); next connect runs without RULE-SET`);
      return 'quarantined';
    } catch (e) {
      AppLogger.warn(TAG, `ad ruleset quarantine failed: ${AppLogger.errText(e)}`);
      return '';
    }
  }

  /**
   * 连接成功后把当前规则集留一份 last-good 副本（供 healRuleSet 回滚）。
   * 只在规则集文件本体校验通过时快照，避免把坏文件当"good"存下来。
   */
  private snapshotRuleSetGood(): void {
    if (this.context === null || !this.ruleSetFileOk()) {
      return;
    }
    const dir = `${this.context.cacheDir}/${RULESET_SUBDIR}`;
    const p = `${dir}/${HYPER_AD_RULES_FILE}`;
    const tmp = `${p}${RULE_SET_GOOD_SUFFIX}.tmp`;
    try {
      fs.copyFileSync(p, tmp);
      fs.renameSync(tmp, `${p}${RULE_SET_GOOD_SUFFIX}`);
    } catch (e) {
      AppLogger.warn(TAG, `ad ruleset last-good snapshot failed: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * geo 资产状态快照（设置页「数据」）。就绪判定与连接路径同源：
   * geoip/model 走魔数校验；mtime 供「多久没更新」展示。
   *
   * 去广告规则集**不在这里**（2026-10-23）：它随安装包内置、开关打开即生效，
   * 不再是需要用户手动更新/删除的独立资产 —— 用户口径「去广告规则集去掉，
   * 默认自带这个数据」。
   */
  geoAssetStatuses(): GeoAssetStatus[] {
    const out: GeoAssetStatus[] = [];
    const stat = (relPath: string): number[] => {
      if (this.context === null) {
        return [-1, 0];
      }
      try {
        const s = fs.statSync(`${this.context.cacheDir}/${relPath}`);
        return [Number(s.size), Number(s.mtime) * 1000];
      } catch (e) {
        return [-1, 0];
      }
    };
    const geoip = stat('geoip.metadb');
    const model = stat('Model.bin');
    const item = (id: string, label: string, detail: string, info: number[],
      ready: boolean): GeoAssetStatus => {
      const g = new GeoAssetStatus();
      g.id = id;
      g.label = label;
      g.detail = detail;
      g.sizeBytes = info[0] < 0 ? 0 : info[0];
      g.mtimeMs = info[1];
      g.ready = ready;
      return g;
    };
    out.push(item('geoip', 'GeoIP 数据库', 'GEOIP,CN 直连分流与 DNS fallback 依赖', geoip,
      this.isGeoipReady()));
    out.push(item('model', 'Smart 选点模型', 'LightGBM 自动选点依赖（需手动更新）', model,
      this.ensureSmartModelReady()));
    return out;
  }

  /**
   * 手动更新 geo 资产（设置页触发，可等待）。
   * @returns '' = 成功；非空 = 用户可读的失败原因
   */
  async refreshGeoAsset(id: string, source: string): Promise<string> {
    if (this.context === null) {
      return '应用尚未初始化完成';
    }
    const seq = this.connectSeq;
    const generation = this.sessionGeneration;
    let ok = false;
    if (id === 'geoip') {
      ok = await this.downloadGeoipAsset(source);
    } else if (id === 'model') {
      // 后台任务正持有下载锁时，downloadSmartModelAsset 会立刻返回 false，
      // 旧实现把它报成「全部下载源均失败」—— 与事实相反（正在下）。
      if (this.smartModelDownloading) {
        return '模型正在后台下载，请稍候再看状态';
      }
      ok = await this.downloadSmartModelAsset(source);
    } else if (id === 'ruleset') {
      ok = await this.downloadRuleProviderAsset(source);
    } else {
      return '未知的数据项';
    }
    // 去广告规则集更新成功 → 热加载新规则；失败保留当前会话，不自动重连。
    // 会话代次不符说明用户已重连/断开：迟到的下载结果不能改写新会话的配置。
    if (ok && id === 'ruleset' && this.isRuleSessionCurrent(seq, generation)) {
      await this.applyRulesChanged('ruleset-updated');
    }
    // 【2026-10-22】模型下载成功后也要 bump 信号：订阅页的「自动选择」入口跟着
    // `smart_model_seq` 重算（与删除对称）。否则用户点「更新」把模型装回来了、
    // 入口却还藏着，得杀进程才会出现。
    if (ok && id === 'model') {
      const seq = AppStorage.get<number>('smart_model_seq');
      AppStorage.setOrCreate<number>('smart_model_seq', (seq ?? 0) + 1);
    }
    return ok ? '' : '全部下载源均失败，请稍后重试或切换下载源';
  }

  /**
   * 删除可按需重下的资产（**仅** Smart 选点模型与去广告规则集）。
   *
   * 用户口径（2026-10-22）：这两个都不是必需品，允许用户删掉腾空间；
   * 删除后：
   *  · 模型消失 → 订阅页/节点页的「自动选择」入口自动隐藏（见 smartModelSeq 信号）；
   *  · 规则集消失 → 调用方触发一次代理重启，让内核换用不含 RULE-SET 的配置。
   * GeoIP/GeoSite **不允许删**：内核缺它们会在 config.Parse 阶段直接退出。
   *
   * @returns '' = 成功；非空 = 用户可读的失败原因
   */
  deleteGeoAsset(id: string): string {
    if (this.context === null) {
      return '应用尚未初始化完成';
    }
    try {
      if (id === 'model') {
        const path = `${this.context.cacheDir}/Model.bin`;
        try {
          fs.unlinkSync(path);
        } catch (e) {
          // 文件本来就不存在：按成功处理
        }
        // 通知所有页面重算「自动选择」是否该显示
        const seq = AppStorage.get<number>('smart_model_seq');
        AppStorage.setOrCreate<number>('smart_model_seq', (seq === undefined ? 0 : seq) + 1);
        AppLogger.info(TAG, 'smart model deleted; auto-select entry hidden');
        return '';
      }
      if (id === 'ruleset') {
        const path = `${this.context.cacheDir}/${RULESET_SUBDIR}/${HYPER_AD_RULES_FILE}`;
        try {/* 连同 last-good 副本一起删：否则下次启动失败时会被自愈逻辑"复活" */
          fs.unlinkSync(`${path}${RULE_SET_GOOD_SUFFIX}`);
        } catch (e) {
          // 副本不存在属正常
        }
        try {
          fs.unlinkSync(path);
        } catch (e) {
          // 同上
        }
        this.lastRuleProviderFileReady = false;
        AppLogger.info(TAG, 'ad-block ruleset deleted; next rules reload drops RULE-SET');
        return '';
      }
      return '该数据项不支持删除（删掉会导致内核无法启动）';
    } catch (e) {
      return `删除失败：${AppLogger.errText(e)}`;
    }
  }

  /** 多个入口共享同一下载，避免重复写入和把「正在下载」误判为失败。 */
  private ruleProviderDownloadTask: Promise<boolean> | null = null;

  /** 等待型去广告规则集下载 */
  private async downloadRuleProviderAsset(source: string): Promise<boolean> {
    if (this.context === null) {
      return false;
    }
    if (this.ruleProviderDownloadTask !== null) {
      return this.ruleProviderDownloadTask;
    }
    const task = this.performRuleProviderDownload(source);
    this.ruleProviderDownloadTask = task;
    try {
      return await task;
    } catch (e) {
      AppLogger.warn(TAG, `hyper-adrules download task error: ${AppLogger.errText(e)}`);
      return false;
    } finally {
      if (this.ruleProviderDownloadTask === task) {
        this.ruleProviderDownloadTask = null;
      }
    }
  }

  private async performRuleProviderDownload(source: string): Promise<boolean> {
    if (this.context === null) {
      return false;
    }
    try {
      const dir = `${this.context.cacheDir}/${RULESET_SUBDIR}`;
      const dest = `${dir}/${HYPER_AD_RULES_FILE}`;
      // ruleset 子目录可能不存在，写盘前必须先建（openSync CREATE 不递归建目录）
      try {
        ensurePrivateDir(dir);
      } catch (e) {
        AppLogger.warn(TAG, `ruleset dir create failed: ${AppLogger.errText(e)}`);
      }
      // 体积下限 + zstd 魔数：加速代理的错误页（HTML/JSON）体积也常超 1KB，
      // 只查体积会把坏内容写进内核 home，导致下次启动 config.Parse 整份失败。
      return await this.downloadAsset(HYPER_AD_RULES_MIRRORS, dest, RULE_SET_MIN_BYTES - 1,
        (buf: ArrayBuffer): boolean => buf.byteLength >= RULE_SET_MIN_BYTES
          && ConnectionOrchestrator.bufferMagicOk(buf, ZSTD_MAGIC),
        source, 'hyper-adrules');
    } catch (e) {
      AppLogger.warn(TAG, `hyper-adrules download failed: ${AppLogger.errText(e)}`);
      return false;
    }
  }

  /**
   * 真实断开（拆隧道 + 清工件 + 落盘"用户已断开"）。
   *
   * @param expectedGeneration >0 时做**同代保护**：只有磁盘上的会话代次仍等于本次
   *        连接写入的代次，才允许把 desiredConnected 写成 false。并发场景下
   *        （旧连接失败回滚撞上新连接已写入 true）跳过写入，避免把用户"想连着"
   *        的意图抹掉 —— 那会让后台自愈误判为"用户已断开"而不再复活隧道。
   *        隧道拆除本身不受影响，始终照常执行。
   */
  private async disconnectInternal(expectedGeneration: number = 0): Promise<void> {
    this.invalidateStateProbeCache();
    this.stopMonitors();
    // 隧道要没了：立刻撤销 App 级 HTTP 代理，否则后续请求全打到空端口
    AppProxyRoute.clear();
    // 测速内核与真实隧道互斥：断开/回滚路径一并回收单航班状态机（含配置清理）
    if (this.testCoreFlight !== null) {
      try {
        await this.testCoreFlight.stop();
      } catch (e) {
        AppLogger.warn(TAG, `test core stop during disconnect failed: ${AppLogger.errText(e)}`);
      }
    }
    await this.clearSessionIntent(expectedGeneration);
    // 内核一停，它的累计计数器就没了：先把当前增量补记并落盘，否则这段流量永久丢失。
    this.flushTrafficAccounting();
    try {
      await coreBridge.stopCore();
    } catch (e) {
      AppLogger.warn(TAG, `stopCore error: ${e}`);
    }
    if (this.context === null) {
      return;
    }
    try {
      const want: Want = {
        bundleName: 'com.tunbox.client',
        abilityName: 'VpnExtensionAbility'
      };
      await vpnExtension.stopVpnExtensionAbility(want);
    } catch (e) {
      AppLogger.warn(TAG, `stopVpnExtensionAbility error: ${e}`);
    }
    // 立即清理心跳/启动标记文件: 否则断开后 15s 内心跳文件仍是"新鲜"的,
    // isTunnelAlive() 会把"已断开"误判为"还活着" —— 真机实证: 卡片连续
    // 开关两次后就再也启动不了(每次都被误判 alive 而走 disconnect 分支)。
    this.clearTunnelMarkers();
    // 凭据清理：主配置 + 测速配置（内含 API secret / 节点口令）随隧道一并删除。
    // 逐文件独立容错: 任一文件不存在或删除失败都不阻断其余文件。
    const removed = clearPrivateArtifacts(this.context.cacheDir, privateFs);
    this.apiSecret = '';
    AppLogger.info(TAG, `runtime artifacts cleared: ${removed.join(',')}`);
  }

  private clearTunnelMarkers(): void {
    this.invalidateStateProbeCache();
    if (this.context === null) {
      return;
    }
    const dir = this.context.cacheDir;
    for (const f of [HEARTBEAT_FILE, HEARTBEAT_TMP_FILE, START_OK_FILE, START_ERROR_FILE]) {
      try {
        fs.unlinkSync(`${dir}/${f}`);
      } catch (e) {
        // 文件不存在属正常
      }
    }
  }

  /** 存活监控 + 流量轮询 + 常驻通知（对应 CoreLivenessMonitor / VpnTrafficTracker / NotificationUpdatePolicy） */
  private startMonitors(): void {
    this.stopMonitors();
    const generation = this.monitorGeneration;
    this.monitorTimer = UnifiedScheduler.every(() => {
      this.pollRuntimeLiveness(generation).catch((e: Error): void => {
        AppLogger.warn(TAG, `liveness probe failed: ${AppLogger.errText(e)}`);
      });
    }, CORE_LIVENESS_POLL_MS);
    this.trafficPollRunning = false;
    this.trafficTimer = UnifiedScheduler.every(() => {
      if (this.trafficPollRunning || this.state !== ConnState.CONNECTED) {
        return;
      }
      this.trafficPollRunning = true;
      const seq = this.connectSeq;
      this.api.traffic().then((t: TrafficSnapshot | null) => {
        if (!this.isCurrentMonitor(generation, seq)) { return; }
        if (t !== null) {
          this.traffic = t;
          // 只有成功样本才推进累计基线；失败时保留上次值，供记账跨进程/跨后台对齐
          this.coreTotalUp = t.uploadBytes;
          this.coreTotalDown = t.downloadBytes;
        } else {
          // 探测失败：保留总量、只把速率清零（卡片不跳 0，记账不受影响）
          this.traffic = {
            uploadBytes: this.traffic.uploadBytes,
            downloadBytes: this.traffic.downloadBytes,
            uploadSpeed: 0,
            downloadSpeed: 0
          };
        }
        const snap: TrafficSnapshot = this.traffic;
        ConnectionEvents.emit(ConnEvent.traffic(snap.uploadSpeed, snap.downloadSpeed,
          snap.uploadBytes, snap.downloadBytes));
        if (this.state === ConnState.CONNECTED) {
          this.exitPollTick++;
          if (this.exitPollTick % 5 === 0) {
            this.refreshExitFromKernel().catch((e: Error): void => {
              AppLogger.warn(TAG, `exit poll failed: ${AppLogger.errText(e)}`);
            });
          }
          TaskProgressUpdater.updateLive(
            this.notifyNodeText(this.lastNodeName.length > 0 ? this.lastNodeName : '已连接'),
            // 2026-10-19：实况通知单行宽度有限，速率串用紧凑写法（去掉多余空格），
            // 配合 TaskProgressUpdater 里「只放速率、不放时长」的改动，避免被截断。
            `↓${this.formatSpeed(snap.downloadSpeed)} ↑${this.formatSpeed(snap.uploadSpeed)}`,
            this.connDurationText());
        }
        this.notify();
      }).catch((e: Object): void => {
        if (this.isCurrentMonitor(generation, seq)) {
          AppLogger.warn(TAG, `traffic poll failed: ${AppLogger.errText(e)}`);
        }
      }).finally(() => {
        if (generation === this.monitorGeneration) { this.trafficPollRunning = false; }
      });
    }, TRAFFIC_POLL_INTERVAL_MS);
  }

  /** 慢探针不得并发投票；旧监控/旧会话的晚到结果不得修复新会话。 */
  private async pollRuntimeLiveness(generation: number): Promise<void> {
    if (generation !== this.monitorGeneration || this.livenessPollRunning
      || this.state !== ConnState.CONNECTED || this.disconnectRequested) {
      return;
    }
    this.livenessPollRunning = true;
    const seq = this.connectSeq;
    try {
      let verdict = await this.probeLivenessAsync();
      if (!this.isCurrentMonitor(generation, seq)) { return; }
      if (verdict !== LivenessVerdict.ALIVE) {
        // Go 转发可能仍在运行，而 ArkTS 租约定时器刚从锁屏暂停中恢复。
        // 本地认证探活通过时，保留 TUN/Core 与原始连接时刻。
        const responsive = await this.api.healthProbe();
        if (!this.isCurrentMonitor(generation, seq)) { return; }
        if (responsive) {
          verdict = LivenessVerdict.ALIVE;
        } else {
          // HTTP 探测期间扩展可能已补写租约，读一次新值再决定是否记负票。
          this.invalidateStateProbeCache();
          verdict = await this.probeLivenessAsync();
          if (!this.isCurrentMonitor(generation, seq)) { return; }
        }
      }
      if (verdict === LivenessVerdict.ALIVE) {
        // ── 终态黑洞检测（心跳新鲜 ≠ 内核活着）─────────────────────────
        // 分层判定，正常态只多读一次状态文件（廉价预判）：
        //   ① coreAlive=true / 文件不可信 → 真 ALIVE；
        //   ② phase 在恢复中且 status 仍在更新（ts 前进 <90s）→ 扩展在自救，不抢跑；
        //   ③ 本地 API 探针（127.0.0.1 回环，不受物理断网影响）再确认一次；
        //   ④ 连续 3 票（时间间隔与心跳死亡同口径）才升级 handleCoreLoss。
        const view = this.extensionStatus();
        const stuckBlackhole = view.ok && !view.coreAlive
          && (view.phase === 'running'
            || (view.phase === 'recovering' && Date.now() - view.ts > CORE_RECOVERY_STUCK_MS));
        if (!stuckBlackhole) {
          this.coreDownStrikes = 0;
          this.coreDownFirstAt = 0;
          this.coreDownLastAt = 0;
          this.resetCoreDeathConfirmation();
          return;
        }
        const coreApiAlive = await this.api.healthProbe();
        if (!this.isCurrentMonitor(generation, seq)) { return; }
        if (coreApiAlive) {
          // 状态文件落后于实际（内核已自行恢复/重启成功）：不投负票
          this.coreDownStrikes = 0;
          this.resetCoreDeathConfirmation();
          return;
        }
        const downNow = Date.now();
        if (this.coreDownStrikes > 0 && downNow - this.coreDownLastAt < CORE_LIVENESS_POLL_MS) {
          return;
        }
        if (this.coreDownStrikes === 0) { this.coreDownFirstAt = downNow; }
        this.coreDownLastAt = downNow;
        this.coreDownStrikes++;
        if (this.coreDownStrikes < CORE_DEATH_CONFIRMATIONS
          || downNow - this.coreDownFirstAt < CORE_DEATH_CONFIRM_MS) {
          AppLogger.warn(TAG, `extension alive but core down (${view.phase}); `
            + `strikes=${this.coreDownStrikes}/${CORE_DEATH_CONFIRMATIONS}`);
          return;
        }
        this.coreDownStrikes = 0;
        this.coreDownFirstAt = 0;
        this.coreDownLastAt = 0;
        if (!await this.isCurrentSession(this.sessionGeneration)
          || !this.isCurrentMonitor(generation, seq)) {
          this.resetCoreDeathConfirmation();
          return;
        }
        this.resetCoreDeathConfirmation();
        this.setState(ConnState.RECOVERING);
        this.notify();
        AppLogger.warn(TAG, 'terminal black hole confirmed: lease fresh but core dead '
          + 'and extension recovery exhausted; escalating to full reconnect');
        this.handleCoreLoss();
        return;
      }
      const now = Date.now();
      if (this.coreDeathStrikes > 0 && now - this.coreDeathLastAt < CORE_LIVENESS_POLL_MS) {
        return; // 解锁后的积压定时器不能在同一瞬间投满三票。
      }
      if (this.coreDeathStrikes === 0) { this.coreDeathFirstAt = now; }
      this.coreDeathLastAt = now;
      this.coreDeathStrikes++;
      if (this.coreDeathStrikes < CORE_DEATH_CONFIRMATIONS
        || now - this.coreDeathFirstAt < CORE_DEATH_CONFIRM_MS) {
        AppLogger.info(TAG, `runtime unconfirmed (${verdict}); `
          + `strikes=${this.coreDeathStrikes}/${CORE_DEATH_CONFIRMATIONS}`);
        return;
      }
      // 最后再核对持久化意图；用户可能从另一 Ability/进程停止了 VPN。
      if (!await this.isCurrentSession(this.sessionGeneration)
        || !this.isCurrentMonitor(generation, seq)) {
        this.resetCoreDeathConfirmation();
        return;
      }
      this.resetCoreDeathConfirmation();
      this.setState(ConnState.RECOVERING);
      this.notify();
      AppLogger.warn(TAG, 'runtime unresponsive: lease and authenticated controller '
        + `failed ${CORE_DEATH_CONFIRMATIONS} spaced checks; escalating to health self-check`);
      this.handleCoreLoss();
    } finally {
      if (generation === this.monitorGeneration) { this.livenessPollRunning = false; }
    }
  }

  private isCurrentMonitor(generation: number, seq: number): boolean {
    return generation === this.monitorGeneration && seq === this.connectSeq
      && this.state === ConnState.CONNECTED && !this.disconnectRequested;
  }

  private resetCoreDeathConfirmation(): void {
    this.coreDeathStrikes = 0;
    this.coreDeathFirstAt = 0;
    this.coreDeathLastAt = 0;
  }

  private stopMonitors(): void {
    this.monitorGeneration++;
    this.livenessPollRunning = false;
    this.resetCoreDeathConfirmation();
    if (this.monitorTimer >= 0) {
      UnifiedScheduler.clear(this.monitorTimer);
      this.monitorTimer = -1;
    }
    if (this.trafficTimer >= 0) {
      UnifiedScheduler.clear(this.trafficTimer);
      this.trafficTimer = -1;
    }
    this.trafficPollRunning = false;
  }

  async diagnostics(): Promise<AppDiagnostics> {
    const d = new AppDiagnostics();
    d.coreRunning = this.state === ConnState.CONNECTED;
    d.vpnActive = this.state === ConnState.CONNECTED;
    d.clashApiReachable = await this.api.healthProbe();
    d.clashApiPort = this.apiPort;
    d.startedAt = this.startedAt;
    d.uptimeSeconds = this.startedAt > 0 ? Math.floor((Date.now() - this.startedAt) / 1000) : 0;
    d.lastError = this.lastError;
    d.connectionState = String(this.state);
    d.currentNode = this.lastNodeName;
    d.uploadSpeed = this.traffic.uploadSpeed;
    d.downloadSpeed = this.traffic.downloadSpeed;
    d.uploadBytes = this.traffic.uploadBytes;
    d.downloadBytes = this.traffic.downloadBytes;
    return d;
  }

  formatSpeed(bytesPerSecond: number): string {
    if (bytesPerSecond < 1024) {
      return `${bytesPerSecond.toFixed(0)} B/s`;
    }
    if (bytesPerSecond < 1024 * 1024) {
      return `${(bytesPerSecond / 1024).toFixed(1)} KB/s`;
    }
    return `${(bytesPerSecond / 1024 / 1024).toFixed(2)} MB/s`;
  }

  /**
   * 常驻通知栏的连接时长（H:MM:SS）。startedAt=0（未连接）时不显示时长段。
   */
  private connDurationText(): string {
    if (this.startedAt <= 0) {
      return '';
    }
    let s = Math.floor((Date.now() - this.startedAt) / 1000);
    if (s < 0) {
      s = 0;
    }
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    const mm = m < 10 ? `0${m}` : `${m}`;
    const ss = sec < 10 ? `0${sec}` : `${sec}`;
    return `${h}:${mm}:${ss}`;
  }

  /** 通知标题里的节点名：截断过长的名字，避免通知栏标题被挤没 */
  private notifyNodeText(name: string): string {
    const n = name.trim();
    if (n.length <= 24) {
      return n;
    }
    return `${n.substring(0, 24)}…`;
  }

  formatBytes(total: number): string {
    if (total < 1024) {
      return `${total} B`;
    }
    if (total < 1024 * 1024) {
      return `${(total / 1024).toFixed(1)} KB`;
    }
    if (total < 1024 * 1024 * 1024) {
      return `${(total / 1024 / 1024).toFixed(1)} MB`;
    }
    return `${(total / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }
}
