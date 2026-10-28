/**
 * 订阅服务：增删改查 + 刷新 + 撤销；手工节点独立存储（ManualNodeStore）
 * 移植自 upstream: TunBox_Android/lib/services/subscription_service.dart
 *                packages/tunbox_shared/lib/services/subscription_service_*.dart
 *                subscription_processing.dart / subscription_undo_record.dart
 *
 * 敏感凭据存储策略（对齐 SettingsService.apiSecret 的 AssetStore 先例）：
 * - 节点 password/uuid/protocolParam/obfsParam/extraOpts/rawUri、订阅 headerValue
 *   只允许写入系统加密 AssetStore（@ohos.security.asset / @kit.AssetStoreKit），
 *   禁止降级为明文 preferences。extraOpts 可内嵌 obfs-password、rawUri 是整条节点
 *   链接，两者与 password 同级敏感，不能按字段名猜测是否安全。
 * - 其余节点元数据（server/port/method/network/TLS 参数/rawTemplate 等）仍存 preferences。
 *   rawTemplate 由 YamlMerger.buildRawTemplate 在构造期剔除全部凭据键，故可持久化。
 *   alias 采用稳定键 "tunbox_node|<nodeId>|<field>" / "tunbox_sub|<subId>|headerValue"。
 * - 写 preferences 前**逐字段**确认加密层已回读一致，才允许清空该字段的明文；
 *   加密层不可用或回读不一致时保留明文（fail-closed：宁可多留一份也不丢凭据），
 *   并由 credentialMissingCount 与诊断面板如实告知用户。
 * - 一次性迁移：把历史明文 preferences 中的凭据写入 Asset 并回读校验，成功后才删除明文；
 *   任一步失败保留明文并记录，绝不丢数据。迁移幂等（重跑只重写加密层，不清明文）。
 */
import { RawBodyCache } from './RawProxyYaml';
// FlClash 同构：订阅原文 = profile 文件（App 侧不再把节点当作权威来源）
import { ProfileRepository } from '../flclash/ProfileRepository';
import { coreBridge } from '../../core/CoreBridge';
// convertProxies（mihomo convert.ConvertsV2Ray 的 ArkTS 移植）：base64 / URI 列表订阅
import { SubConverter } from '../flclash/SubConverter';
import { CoreCatalogService } from '../flclash/CoreCatalogService';
import { CoreNodeBridge } from '../flclash/CoreNodeBridge';
import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import {
  Subscription, SubscriptionImportDiagnostics, SubscriptionRefreshResult, SubscriptionRefreshStatus
} from '../models/Subscription';
import { ProxyNode, ProxyNodeType, Base64Codec } from '../models/ProxyNode';
import { ProxyGroup, ProxyGroupJson } from '../models/ProxyGroup';
import { AppSettings } from '../models/AppSettings';
import { SubDnsUpstream } from '../models/SubDnsUpstream';
import { SubscriptionParseResult, SubscriptionParser } from './SubscriptionParser';
import {
  SubscriptionFetchPolicy, SubscriptionFetchError, SubscriptionFetchErrorKind, SubscriptionFetchResult
} from './SubscriptionFetchPolicy';
import { SubscriptionQuotaService } from './SubscriptionQuotaService';
import { SettingsService } from './SettingsService';
import { YamlMerger, MergedProxy, YamlMergeError, YamlNodeError } from './YamlMerger';
import { ClashConfigGenerator, ProxyDropStats } from './ClashConfigGenerator';
import { ProxyProviderEntry, ProxyProviderParser } from './ProxyProviderParser';
import {
  RawProviderEntry, RawProviderStates, RawProviderStatus, RawSubscriptionStore, RawWriteResult
} from './RawSubscriptionStore';
import { LocalSubConverter } from './LocalSubConverter';
import {
  CredentialStore, CredentialMigrationReport, NodeCredentialValues, SubscriptionCredentialSource,
  CRED_PREF_NAME, NODE_CRED_FIELDS, baseNodeName, nodeAlias, nodeCredentialId, setCredentialLogger, subAlias
} from './CredentialStore';
import { AppLogger } from '../utils/AppLogger';
import {
  ConcurrentRefresh, RefreshBatchProgress, RefreshBatchSummary, RefreshItemOutcome, RefreshPrepOutcome
} from './ConcurrentRefresh';
import { BodyDispatch, BodyDispatchResult, BodyKind } from '../subscription/BodyDispatch';
import { YamlNodeAdapter } from '../subscription/YamlNodeAdapter';
// 2026-10-20（B6 旧解析器退场）：直链导入/凭据回退走**规范解析层**，不再走 ProxyNode.fromUri
import { parse as parseUriNode, ParseError, ParsedNode } from '../subscription/UriNodeParser';
import { NodeUsability, UnusableCategory } from '../subscription/NodeUsability';
import { UnusableLedger, UnusableRecord } from '../subscription/UnusableLedger';

const TAG = 'SubscriptionService';
const PREF_NAME = 'tunbox_subscriptions';

/** rules/rule-providers 段提取结果（模块级显式类，满足 arkts-no-untyped-obj-literals） */
class SubscriptionRulesSections {
  rules: string = '';
  providers: string = '';
}
const KEY_SUBS = 'subscriptions_json';
const KEY_NODES = 'nodes_json';
const KEY_HIDDEN = 'hidden_nodes_json';
const KEY_GROUPS = 'proxy_groups_json';
const KEY_ALIAS_CACHE = 'sealed_alias_cache_json';
/**
 * 旧版「单节点」虚拟分组的 id。分组本身已经退场（2026-10-22 用户口径：
 * 单节点走「设置 → 订阅转换」），这个常量只剩两个用途：
 *   1) 启动时清理旧版本遗留的直链节点/虚拟分组（purgeDirectGroup）；
 *   2) 页面里对历史数据做兜底判断（不会再出现）。
 */
export const DIRECT_GROUP_ID = 'direct';

/**
 * 并发预取结果的存活上限。批次被中断（页面销毁 / 用户连点被拦）后残留的 body
 * 绝不允许被后续刷新误当成最新内容写进节点表：宁可多打一次请求，也不能写错数据。
 */
const PREFETCH_TTL_MS = 60 * 1000;

/**
 * 并发批次「网络阶段」的唯一产物：拉取结果或拉取错误（二选一，无 null 字段以便严格模式收窄）。
 * 只放内存、只由 prefetchSubscription 写入、只由 takePrefetch 取走（取走即删）。
 */
class PrefetchedSubscription {
  url: string = '';
  headerName: string = '';
  headerValue: string = '';
  at: number = 0;
  /** 是否命中预取（false = 未预取，由串行阶段自行拉取） */
  hit: boolean = false;
  /** 命中时携带的是错误还是结果 */
  hasError: boolean = false;
  fetched: SubscriptionFetchResult = new SubscriptionFetchResult();
  error: SubscriptionFetchError = new SubscriptionFetchError(SubscriptionFetchErrorKind.NETWORK, '');

  static body(url: string, headerName: string, headerValue: string,
    fetched: SubscriptionFetchResult): PrefetchedSubscription {
    const p = new PrefetchedSubscription();
    p.url = url;
    p.headerName = headerName;
    p.headerValue = headerValue;
    p.at = Date.now();
    p.hit = true;
    p.hasError = false;
    p.fetched = fetched;
    return p;
  }

  static failure(url: string, headerName: string, headerValue: string,
    error: SubscriptionFetchError): PrefetchedSubscription {
    const p = new PrefetchedSubscription();
    p.url = url;
    p.headerName = headerName;
    p.headerValue = headerValue;
    p.at = Date.now();
    p.hit = true;
    p.hasError = true;
    p.error = error;
    return p;
  }
}

/** 一次性回退源（rawUri）在偏好中的键；节点凭据加密写入成功后即删除 */
function nodeUriKey(nodeId: string): string {
  return `rawuri|${nodeId}`;
}

export class SubscriptionService {
  /**
   * 进程级单例（先例：ConnectionOrchestrator.instance()）。
   * 此前每个页面/卡片同步/快捷启动各自 new 一个实例，导致：
   * 1) 每个实例各自 init()：重复读库 + 重复凭据迁移/回填（多轮全量 Asset 查询），
   *    页面切换时表现为「列表空白数秒」；
   * 2) 各实例内存态互不同步，谁后 persist 谁覆盖 —— 数据一致性隐患。
   */
  private static shared: SubscriptionService | null = null;

  static instance(): SubscriptionService {
    if (SubscriptionService.shared === null) {
      SubscriptionService.shared = new SubscriptionService();
    }
    return SubscriptionService.shared;
  }

  private constructor() {
  }

  /** 已通知过的节点集指纹（'' = 尚未通知过） */
  private lastNotifiedNodeFingerprint: string = '';

  /**
   * 节点集指纹：内核代理表里「有哪些节点」的身份集合。
   *
   * 口径（与编排器的测速核配置闸门共用同一份实现）：
   *  - 身份部分（subscriptionId + name + server + port）：节点增删/改名/换服务器；
   *  - 凭据完整度（password/uuid 非空的节点数）：导入/刷新后凭据被封存时，
   *    生成器会按「缺凭据」把节点整条跳过 → 节点不在内核代理表里。
   * 两者任一变化，都意味着「已生成的内核配置不再对应当前节点集」。
   *
   * 用长度前缀拼串而不是直接拼接，避免节点名里含分隔符时出现碰撞。
   */
  static nodeSetFingerprint(nodes: ProxyNode[]): string {
    let acc: string = `${nodes.length}`;
    let credFilled: number = 0;
    for (const n of nodes) {
      acc += `|${n.subscriptionId.length}:${n.subscriptionId}`;
      acc += `|${n.name.length}:${n.name}`;
      acc += `|${n.server.length}:${n.server}|${n.port}`;
      if (n.password.length > 0 || n.uuid.length > 0) {
        credFilled += 1;
      }
    }
    const current = ProfileRepository.currentId();
    const details = ProfileRepository.fingerprint(JSON.stringify(nodes));
    return `${acc}|cred=${credFilled}|details=${details}|profile=${current}:${ProfileRepository.revisionOf(current)}`;
  }

  /**
   * 节点集变化监听（编排器注册）。
   *
   * 用途：订阅导入/刷新/增删之后，「已生成的 mihomo 配置」与当前节点集脱节
   * —— 配置**只在内核启动那一刻生成一次**，不重建就等于让新节点永远测不了
   * （/delay 404 → UI「未生效」，真机 2026-10-20）。监听方据此作废测速核
   * 并按新节点集重建，用户点测速时通道既是热的、配置也是新的。
   */
  private static nodeSetListeners: Array<(reason: string) => void> = [];

  static onNodeSetChanged(listener: (reason: string) => void): void {
    if (SubscriptionService.nodeSetListeners.indexOf(listener) < 0) {
      SubscriptionService.nodeSetListeners.push(listener);
    }
  }

  static offNodeSetChanged(listener: (reason: string) => void): void {
    const i = SubscriptionService.nodeSetListeners.indexOf(listener);
    if (i >= 0) { SubscriptionService.nodeSetListeners.splice(i, 1); }
  }

  private static notifyNodeSetChanged(reason: string): void {
    for (const l of SubscriptionService.nodeSetListeners) {
      try {
        l(reason);
      } catch (e) {
        AppLogger.warn(TAG, `node set listener failed: ${AppLogger.errText(e)}`);
      }
    }
  }

  private store: preferences.Preferences | null = null;
  /** 敏感凭据专用偏好（只放一次性绑定，不放凭据本体） */
  private credStore: preferences.Preferences | null = null;
  /** 明文清扫是否已结束（结束后节点凭据完全由 AssetStore 承担） */
  private sealedPlaintextKeys: boolean = false;
  subscriptions: Subscription[] = [];
  nodes: ProxyNode[] = [];
  /** 订阅内代理组（静态成员 + 已物化的动态分组成员），随订阅增删/刷新同步 */
  proxyGroups: ProxyGroup[] = [];
  /** 用户手动删除的节点指纹清单: 订阅刷新时过滤, 防止已删节点"复活" */
  private hiddenNodes: string[] = [];
  /** 撤销记录（对应 subscription_undo_record.dart）：最近一次删除的订阅与节点 */
  private undoSnapshot: SubscriptionUndoSnapshot | null = null;
  /** 敏感凭据已由本实例加载/写入加密层（幂等闸门） */
  private credentialsReady: boolean = false;
  /**
   * 最近一次凭据回填后仍缺凭据（password/uuid 为空但协议需要）的节点数。
   * >0 表示加密层不可用或凭据已丢失 —— UI 必须明确提示, 而不是让节点在
   * 生成配置阶段被静默丢成空行（「列表有、内核无」）。
   */
  credentialMissingCount: number = 0;
  /** 最近一次导入（刷新/本地 YAML/直链）的诊断, 供页面直接展示 */
  lastImportDiagnostics: SubscriptionImportDiagnostics = new SubscriptionImportDiagnostics();
  /** 最近一次节点恢复（nodes_json → 内存）被丢弃的记录数与原因 */
  lastRestoreInvalidCount: number = 0;
  lastRestoreInvalidReasons: string = '';
  /**
   * 最近一次合并 rule-providers 时丢弃的**孤儿字段行**数。
   * 孤儿 = 出现在任何 provider 键行**之前**、没有归属 provider 的字段行。
   * 这些行**绝不**塞进上一条 provider（那会造成「字段并错 provider」而且不报错）。
   */
  lastProviderOrphanLineCount: number = 0;

  // 【2026-10-22 · FlClash 同构】原来这里导出了 `unusableDefinitions()` /
  // `unusableSummary()`（"定义不完整 N 条"角标的数据源）。
  // YAML 订阅不再产生这类判词（节点可用性归内核），UI 也不再展示；单链接路径
  // 的台账由 `UriNodeParser` 直写、无 UI 消费者 ⇒ 两个导出已删除。

  /**
   * 网络性拉取失败待重试标记（订阅 id → 失败时刻）。
   *
   * 为什么需要（P0-2 订阅自救，对齐 iOS「先连 VPN 再刷新」的自动版）：
   * 拉取全走直连（SubscriptionFetchPolicy 无 per-request proxy，ArkTS http
   * 不支持 usingProxy），被阻断的面板在未连接时必然失败 —— advice 已提示
   * 「请先连接 VPN 后重试」，但用户手动重试是多余的一步。现在把
   * NETWORK_ERROR 失败记进本表，VPN 连接成功后（ConnectionOrchestrator
   * connect() 成功路径）自动补拉一次，用户无感修复。
   */
  private pendingNetworkRetry: Map<string, number> = new Map();
  /** 标记有效期：超过后视为陈旧（用户可能已手动修好），不再自动补拉 */
  private static readonly PENDING_RETRY_TTL_MS: number = 30 * 60 * 1000;

  /** 记一次网络性拉取失败（幂等：同一条订阅只保留最新时刻） */
  markNetworkFetchFailure(id: string): void {
    this.pendingNetworkRetry.set(id, Date.now());
    // 顺带清理陈旧标记，防止长期未连接时无限堆积
    const cutoff = Date.now() - SubscriptionService.PENDING_RETRY_TTL_MS;
    const staleKeys: string[] = [];
    this.pendingNetworkRetry.forEach((at: number, key: string): void => {
      if (at < cutoff) {
        staleKeys.push(key);
      }
    });
    for (const key of staleKeys) {
      this.pendingNetworkRetry.delete(key);
    }
  }

  /** 取出并清空待补拉标记（只返回仍在 TTL 内的 id），无标记时返回空数组 */
  takePendingNetworkRetries(): string[] {
    const now = Date.now();
    const ids: string[] = [];
    this.pendingNetworkRetry.forEach((at: number, key: string): void => {
      if (now - at <= SubscriptionService.PENDING_RETRY_TTL_MS) {
        ids.push(key);
      }
    });
    this.pendingNetworkRetry.clear();
    return ids;
  }
  /**
   * 双轨（原始订阅 → file provider）最近一次的诊断口径字符串：
   * 「解析到 N / provider 读到 M」，诊断面板直接展示（任何差额可见）。
   */
  lastRawProviderSummary: string = '';
  /** 最近一次开关切换/清理的结果文案（诊断面板提示用） */
  lastRawProviderMessage: string = '';
  /**
   * 并发批次的预取缓存（key = 订阅 id）。这是并发阶段**唯一**被写入的状态：
   * 并发阶段只做网络拉取并暂存结果，绝不碰 this.nodes / 订阅统计 / preferences，
   * 因此不会出现「两个刷新同时落盘互相覆盖」。串行阶段 takePrefetch 取走即删。
   */
  private prefetchCache: Map<string, PrefetchedSubscription> = new Map<string, PrefetchedSubscription>();

  /**
   * 进程内只做一次真正的加载（initPromise 记忆化）。
   * 此前每个页面 aboutToAppear 都 await init()：清空内存数组 → 重读 preferences →
   * 重跑凭据迁移（最多 70×4 次串行 Asset IPC）→ 逐节点回填（70 次全量 query），
   * 这既是「切页面后列表空白数秒」也是「切换比以前慢很多」的根因。
   * 单例数据常驻内存后，页面切换即时渲染，重活只在进程首次 init 发生一次。
   */
  private initPromise: Promise<void> | null = null;

  async init(context: Context): Promise<void> {
    if (this.initPromise !== null) {
      return this.initPromise;
    }
    const pending = this.doInit(context);
    this.initPromise = pending;
    // 失败允许重试：清掉记忆化，下次调用重新走一遍（不吞异常，调用方仍会收到 rejection）
    pending.catch((_e: Object) => {
      if (this.initPromise === pending) {
        this.initPromise = null;
      }
    });
    return pending;
  }

  private async doInit(context: Context): Promise<void> {
    // 双轨落盘仓先就位（cacheDir 与内核 HomeDir 一致，见 RawSubscriptionStore 顶部注释）
    RawSubscriptionStore.init(context.cacheDir);
    // FlClash 同构：订阅原文落盘目录（filesDir/profiles/<id>.yaml）+ 当前 profile
    await ProfileRepository.init(context);
    ProfileRepository.attachPreparer((text: string): Promise<string> => coreBridge.prepareProfile(text));
    // convertProxies：非 YAML 订阅（整体 base64 / 逐行分享链接）转成 proxies 列表
    ProfileRepository.attachConverter((text: string): string => SubConverter.convert(text).proxiesYaml);
    // 本地转换订阅（设置页「订阅转换」产出的伪链接由它渲染）：必须在任何 fetch 之前就绪，
    // 否则首次刷新会读到空仓 → 被当成「一条不存在」的订阅
    await LocalSubConverter.init(context);
    this.store = await preferences.getPreferences(context, PREF_NAME);
    this.subscriptions = [];
    this.nodes = [];
    this.proxyGroups = [];
    this.hiddenNodes = [];

    // 敏感凭据专用 preferences（仅存放一次性绑定字段与别名标记，凭据本体在 AssetStore）
    if (this.credStore === null) {
      this.credStore = await preferences.getPreferences(context, CRED_PREF_NAME);
    }
    // 恢复已封存别名标记（仅标记、不含值）；必要时以新格式重写该键，
    // 净化历史版本遗留的明文凭据缓存（旧格式 [[alias, value], ...] 的值一律丢弃）。
    //
    // 只在**内容确实变化**时才回写：每次启动都无条件 put+flush 是两次无谓 IPC，
    // 而且此刻能力尚未经真实查询确认，写回的仍是"怀疑值"。净化仍然保留 ——
    // 旧格式或含值的缓存必然与新导出结果不同，因此必定被重写。
    const prevAliasCache = await this.credStore.get(KEY_ALIAS_CACHE, '[]') as string;
    CredentialStore.importAliasCache(prevAliasCache);
    const nextAliasCache = CredentialStore.exportAliasCache();
    if (nextAliasCache !== prevAliasCache) {
      await this.credStore.put(KEY_ALIAS_CACHE, nextAliasCache);
      await this.credStore.flush();
    }
    setCredentialLogger((msg: string) => AppLogger.info(TAG, msg));

    try {
      const subsRaw = await this.store.get(KEY_SUBS, '[]') as string;
      this.subscriptions = SubscriptionService.mapSubs(JSON.parse(subsRaw) as Object);
    } catch (e) {
      AppLogger.warn(TAG, 'invalid subscriptions preferences ignored');
    }

    try {
      const nodesRaw = await this.store.get(KEY_NODES, '[]') as string;
      const restoreDiagnostics = new SubscriptionImportDiagnostics();
      const restored = SubscriptionService.mapNodes(JSON.parse(nodesRaw) as Object, restoreDiagnostics);
      // 存量表信息条目过滤（2026-10-25 真机实锤：冷启动显示「剩余流量：596.2GB」）：
      // 解析/刷新路径已过滤（e3e7a37），但旧版本落盘的节点表在**水合**时原样回来，
      // 假节点常驻表内直到下次成功刷新 —— 显示回退（nodes[0]）就会拿它当当前节点。
      const infoBefore = restored.length;
      this.nodes = restored.filter((n: ProxyNode): boolean => !NodeUsability.isInfoEntry(n.name));
      if (this.nodes.length < infoBefore) {
        AppLogger.warn(TAG, `hydrate dropped ${infoBefore - this.nodes.length} info-entry node(s) `
          + '(e.g. 剩余流量/到期时间; persisted by pre-filter versions)');
      }
      this.lastRestoreInvalidCount = restoreDiagnostics.invalidCount;
      this.lastRestoreInvalidReasons = restoreDiagnostics.invalidReasons;
      if (restoreDiagnostics.invalidCount > 0) {
        AppLogger.warn(TAG, `restore dropped ${restoreDiagnostics.invalidCount} node record(s): `
          + `${restoreDiagnostics.invalidReasons}`);
      }
    } catch (e) {
      AppLogger.warn(TAG, 'invalid nodes preferences ignored');
    }

    try {
      const hiddenRaw = await this.store.get(KEY_HIDDEN, '[]') as string;
      const arr = JSON.parse(hiddenRaw) as string[];
      if (Array.isArray(arr)) {
        this.hiddenNodes = arr.filter((x): boolean => typeof x === 'string');
      }
    } catch (e) {
      AppLogger.warn(TAG, 'invalid hidden nodes preferences ignored');
    }

    try {
      const groupsRaw = await this.store.get(KEY_GROUPS, '[]') as string;
      this.proxyGroups = SubscriptionService.mapGroups(JSON.parse(groupsRaw) as Object);
    } catch (e) {
      AppLogger.warn(TAG, 'invalid proxy groups preferences ignored');
    }

    // 分阶段计时（真机排查用）：订阅页加载慢时，日志能直接指出时间花在哪一段。
    // 每条日志都在"阶段完成"时打出，比较相邻两条的时间差即为该阶段耗时。
    const t0 = Date.now();
    // 凭据回填作用域（2026-10-16 冷启动 4.5s 的修复）：批量查询不可用的固件上，
    // 回填是逐条 Asset IPC，而 knownAliases 是历史累积的（634 条里活跃约 130 条）。
    // 这里把"当前还活着的节点 + 手工节点 + 当前订阅"的候选别名交给凭据层，
    // 回填只真读这一部分；作用域外的孤儿别名不会被读、更不会被删（用到时逐条兜底）。
    SubscriptionService.applyHydrateScope(this.subscriptions, this.nodes);
    // ── 凭据引导（2026-10-21 冷启动优化）─────────────────────────────
    // 真机实测：stage1 的凭据迁移/回填占冷启动 ~1.36s（Asset 批量查询不可用的固件
    // 只能逐条 IPC），而列表渲染根本不需要凭据 —— 只有「生成配置/测速」才需要。
    // 所以这里**不 await**，把三件事合并成一条后台引导链；
    // 任何需要凭据的入口（ConnectionOrchestrator.hydrateAndBuildProfile）先 await ensureCredentials()。
    this.startCredentialBootstrap();
    // ── 原文透传：把已落盘的订阅原文装进进程内缓存 ────────────────────
    // 与三家一致：订阅原文（profile 文件）落在应用私有目录，冷启动直接读文件，
    // 不联网、不依赖用户先刷新一次。读失败就退回解析发射，不会让配置变坏。
    this.loadRawBodiesIntoCache();
    // ── current profile 自愈（2026-10-22 真机）──────────────────────────
    // 刷新失败/写盘中断会让 current 指向一个**没有 profile 文件**的订阅，
    // 此时生成配置拿不到基底、回落到「全部订阅合并」，界面顶部却写着这个订阅名，
    // 用户看到的就是「飞鸟云里全是另外三个订阅的节点」。
    // 启动时校正一次：current 不可用 → 落到第一个「已落盘且启用」的订阅。
    try {
      const currentProfile = ProfileRepository.currentId();
      if (currentProfile.length === 0 || !ProfileRepository.exists(currentProfile)) {
        for (const candidate of this.subscriptions) {
          if (candidate.id !== DIRECT_GROUP_ID && candidate.enabled
            && ProfileRepository.exists(candidate.id)) {
            await ProfileRepository.setCurrent(candidate.id);
            AppLogger.info(TAG, `current profile self-healed: ${currentProfile || '<none>'} -> ${candidate.id}`);
            break;
          }
        }
      }
    } catch (e) {
      AppLogger.warn(TAG, `current profile self-heal failed: ${AppLogger.errText(e)}`);
    }
    AppLogger.info(TAG, `[perf] stage1 credentials deferred to background at +${Date.now() - t0}ms`);

    // 4) 明文清扫：加密层验证通过的记录删除 preferences 明文字段
    //    （上面的凭据引导会在后台完成，这里只做不依赖凭据的结构性工作）
    // 历史数据可能存在重名节点(内核会拒绝启动), 加载时即去重并落库
    const renamed = this.ensureUniqueNames();

    // 4.5) 分组恢复兜底：旧存储没有 proxy_groups_json 但存在 yaml_cache_ 的订阅，
    //      从结构化缓存重解析分组并按当前节点池物化（升级后首次启动即可用）。
    const groupsRebuilt = await this.rebuildGroupsFromCacheIfMissing();
    AppLogger.info(TAG, `[perf] stage3 groups done at +${Date.now() - t0}ms`);

    // 【2026-10-22 用户口径】「单节点」虚拟分组整体退场：单节点一律走
    // 「设置 → 订阅转换」（导出 YAML 再以文件方式导入）。旧版本把直链节点
    // 存在这个虚拟分组里，这里一并清掉 —— 否则界面上看不见它们，内核配置里却有。
    const purgedDirectGroup = this.purgeDirectGroup();

    // 5) 双轨 provider 对账：清理孤儿落盘文件 + 回填每订阅 provider 状态
    //    （开关关闭时只清孤儿文件，绝不读订阅原文）
    const rawReconciled = this.reconcileRawProviders();

    AppLogger.info(TAG, `loaded ${this.subscriptions.length} subscriptions, `
      + `${this.nodes.length} nodes, ${this.proxyGroups.length} proxy groups`);
    if (renamed || purgedDirectGroup || rawReconciled || groupsRebuilt) {
      await this.persist();
    }
  }

  /**
   * 升级恢复路径：proxy_groups_json 缺失（旧版本存储）但有 yaml_cache_ 结构化缓存的
   * 订阅，从缓存重解析分组并物化动态成员。结果随后随 init 末尾的 persist 落盘，
   * 幂等（有持久化分组的订阅不重建）。
   */
  private async rebuildGroupsFromCacheIfMissing(): Promise<boolean> {
    if (this.store === null) {
      return false;
    }
    const hasGroupsFor = new Set<string>();
    for (const g of this.proxyGroups) {
      hasGroupsFor.add(g.subscriptionId);
    }
    let rebuilt = false;
    for (const s of this.subscriptions) {
      if (s.id === DIRECT_GROUP_ID || hasGroupsFor.has(s.id)) {
        continue;
      }
      let cached = '';
      try {
        cached = await this.store.get(`yaml_cache_${s.id}`, '') as string;
      } catch (e) {
        continue;
      }
      if (cached.length === 0) {
        continue;
      }
      const groups = SubscriptionParser.parseProxyGroups(cached, s.id);
      if (groups.length === 0) {
        continue;
      }
      SubscriptionParser.materializeDynamicGroups(groups, this.nodesOf(s.id));
      this.proxyGroups = this.proxyGroups.concat(groups);
      rebuilt = true;
      AppLogger.info(TAG, `rebuilt ${groups.length} proxy group(s) from cached yaml `
        + `for subscription ${s.id}`);
    }
    return rebuilt;
  }

  /**
   * 双轨 provider 对账（启动时调用一次）：
   * 1) 删除不属于任何现存订阅的孤儿文件（订阅在应用被杀时被删的场景）；
   * 2) 开关开启时：文件存在 → 状态 ready 并登记 provider（条目数从落盘原文读回估算）；
   *    文件缺失 → 状态 missing（节点仍保留在列表里，UI 明确提示，绝不因此删节点）。
   * 返回是否需要重新持久化（订阅元数据发生变化）。
   */
  private reconcileRawProviders(): boolean {
    if (!RawSubscriptionStore.isReady()) {
      return false;
    }
    const ids: string[] = [];
    for (const s of this.subscriptions) {
      ids.push(s.id);
    }
    RawSubscriptionStore.removeOrphans(ids);
    if (!RawSubscriptionStore.enabled) {
      // 开关关闭：落盘仓已被 SettingsService 闸门清空，订阅状态无需改写
      return false;
    }
    let changed = false;
    for (const s of this.subscriptions) {
      if (s.id === DIRECT_GROUP_ID) {
        continue;
      }
      if (RawSubscriptionStore.has(s.id)) {
        const estimate = SubscriptionService.countRawEntries(s.id);
        if (s.rawProviderState !== RawProviderStates.READY
          || s.rawProviderNodeEstimate !== estimate) {
          changed = true;
        }
        s.rawProviderState = RawProviderStates.READY;
        s.rawProviderNodeEstimate = estimate;
        this.registerRawProvider(s.id, estimate);
        continue;
      }
      if (s.rawProviderState !== RawProviderStates.INELIGIBLE
        && s.rawProviderState !== RawProviderStates.FAILED) {
        // 开关开着但文件没了（被清理 / 上次写入未完成）：显式标 missing，节点不删
        if (s.rawProviderState !== RawProviderStates.MISSING) {
          changed = true;
        }
        s.rawProviderState = RawProviderStates.MISSING;
        s.rawProviderNodeEstimate = 0;
      }
      RawSubscriptionStore.drop(s.id);
    }
    return changed;
  }

  /** 落盘原文的条目数估算（与生成配置时的条目口径一致；失败返回 0） */
  private static countRawEntries(subscriptionId: string): number {
    const body = RawSubscriptionStore.readRaw(subscriptionId);
    if (body.length === 0) {
      return 0;
    }
    try {
      return YamlMerger.proxyItemGroups(body).length;
    } catch (e) {
      return 0;
    }
  }

  /**
   * 从订阅原文提取 rules / rule-providers 段（YamlMerger 归一化：2 空格基准缩进）。
   * 任何解析异常都返回空段 —— 订阅自带规则的提取绝不影响节点导入主流程。
   */
  private static extractRulesSections(body: string): SubscriptionRulesSections {
    const out = new SubscriptionRulesSections();
    try {
      out.rules = YamlMerger.extractSection(body, 'rules').trim();
      out.providers = YamlMerger.extractSection(body, 'rule-providers').trim();
    } catch (e) {
      // 提取失败按「订阅未携带规则」处理，节点导入不受影响
    }
    return out;
  }

  /** 订阅原文 → 该订阅的自带 rules/rule-providers 落账（无规则段时清空旧值） */
  private static applyRulesSections(sub: Subscription, body: string): void {
    const sections = SubscriptionService.extractRulesSections(body);
    sub.subRules = sections.rules;
    sub.subRuleProviders = sections.providers;
  }

  /**
   * 订阅原文 → 该订阅的 **dns 上游**落账（2026-10-20「测速全超时」定案）。
   *
   * 机场把「入口域名 → 真实入口 IP」只告诉自家私有 DoH；公共 DNS 给出的是
   * Cloudflare / 阿里 WAF 前置 IP，那些 IP 上代理端口不通或不提供协议服务。
   * 因此 `dns.proxy-server-nameserver` 与 `dns.nameserver-policy` 必须带进运行配置：
   * 真实内核单变量实验里，订阅1 只删 `proxy-server-nameserver` 就从 20/23 掉到 7/23，
   * 订阅2 只删 `nameserver-policy` 就从 30/36 掉到 0/36。
   *
   * 任何异常都按「订阅未提供 dns 上游」处理（退回内置公共 DoT），绝不影响节点导入。
   */
  private static applyDnsSections(sub: Subscription, body: string): void {
    let servers: string[] = [];
    let pairs: string[][] = [];
    try {
      const dnsText = YamlMerger.extractSection(body, 'dns');
      if (dnsText.trim().length > 0) {
        servers = YamlMerger.extractDnsProxyServers(dnsText);
        pairs = YamlMerger.extractDnsPolicyPairs(dnsText);
      }
    } catch (e) {
      // 提取失败 = 无 dns 上游（生成时走内置公共 DoT）
    }
    sub.subDnsProxyServers = servers.length > 0 ? JSON.stringify(servers) : '';
    sub.subDnsPolicies = pairs.length > 0 ? JSON.stringify(pairs) : '';
  }

  /** 登记 provider（生成器 planRawProviders 只认登记表 + 文件存在性） */
  private registerRawProvider(subscriptionId: string, nodeEstimate: number): void {
    const entry = new RawProviderEntry();
    entry.subscriptionId = subscriptionId;
    entry.providerName = RawSubscriptionStore.providerNameFor(subscriptionId);
    entry.providerPath = RawSubscriptionStore.providerPathFor(subscriptionId);
    entry.filePath = RawSubscriptionStore.filePathFor(subscriptionId);
    entry.bytes = RawSubscriptionStore.sizeOf(subscriptionId);
    entry.nodeEstimate = nodeEstimate;
    RawSubscriptionStore.upsert(entry);
  }

  /**
   * 计算并设置凭据回填作用域：当前订阅 + 当前节点 + 手工节点的候选别名。
   * 只对"批量查询不可用、需要逐条回填"的固件有意义（可用时批量一次拿全，无成本）。
   * called from doInit（回填前）——重建作用域而不是增量维护，幂等且无遗漏。
   */
  private static applyHydrateScope(subs: Subscription[], nodes: ProxyNode[]): void {
    const scope = new Set<string>();
    for (const s of subs) {
      if (s.id.length > 0) {
        scope.add(subAlias(s.id));
      }
    }
    for (const n of nodes) {
      const nodeId = nodeCredentialId(n);
      if (nodeId.length === 0) {
        continue;
      }
      for (const f of NODE_CRED_FIELDS) {
        scope.add(nodeAlias(nodeId, f));
      }
    }
    // 手工节点（NodeEditPage 的常驻分组）不在本服务节点池里，但凭据在同一键空间，
    // 同样纳入作用域；没有任何手工节点时这段循环是空转，成本为零。
    for (const n of ManualNodeStore.all()) {
      const nodeId = nodeCredentialId(n);
      if (nodeId.length === 0) {
        continue;
      }
      for (const f of NODE_CRED_FIELDS) {
        scope.add(nodeAlias(nodeId, f));
      }
    }
    CredentialStore.setHydrateScope(Array.from(scope));
  }

  /** 把私有目录里已落盘的订阅原文读进内存缓存（冷启动用；失败静默跳过）。 */
  private loadRawBodiesIntoCache(): void {
    let loaded = 0;
    for (const s of this.subscriptions) {
      if (s.id.length === 0) {
        continue;
      }
      const body = RawSubscriptionStore.readRaw(s.id);
      if (body.length > 0) {
        RawBodyCache.put(s.id, body);
        loaded++;
      }
    }
    if (loaded > 0) {
      AppLogger.info(TAG, `[perf] raw bodies cached: ${loaded}/${this.subscriptions.length}`);
    }
    // 缺原文的订阅：后台补拉一次（三家都是「导入即落盘」，用户不该为此手动刷新）。
    // 只在启动后跑一次、串行、失败静默；不影响首屏，也不触发重连。
    if (loaded < this.subscriptions.length && !SubscriptionService.rawBackfillDone) {
      SubscriptionService.rawBackfillDone = true;
      const missing: string[] = [];
      for (const s of this.subscriptions) {
        if (s.id.length > 0 && !s.legacyFormat && RawBodyCache.get(s.id).length === 0) {
          missing.push(s.id);
        }
      }
      if (missing.length > 0) {
        AppLogger.info(TAG, `[perf] raw backfill scheduled: ${missing.length} subscription(s)`);
        setTimeout((): void => {
          SubscriptionService.backfillRawBodies(this, missing);
        }, 2500);
      }
    }
  }

  private static rawBackfillDone: boolean = false;

  /** 串行补拉缺失原文（失败静默；只落盘，不改用户当前连接） */
  private static backfillRawBodies(svc: SubscriptionService, ids: string[]): void {
    const run = async (): Promise<void> => {
      for (const id of ids) {
        try {
          await svc.refreshSubscription(id);
        } catch (e) {
          AppLogger.warn(TAG, `raw backfill failed for ${id}: ${AppLogger.errText(e)}`);
        }
      }
      AppLogger.info(TAG, `[perf] raw backfill done (${ids.length})`);
    };
    run();
  }

  /** 凭据引导链（一次性）：迁移 → 订阅 header 回填 → 节点凭据回填。 */
  private credentialBootstrap: Promise<void> | null = null;

  /**
   * 启动后台凭据引导（幂等）。失败不抛给调用方：引导链自己 warn 并继续，
   * 真正需要凭据的地方还有 pickOrRead 逐条兜底。
   */
  private startCredentialBootstrap(): Promise<void> {
    if (this.credentialBootstrap === null) {
      const t = Date.now();
      this.credentialBootstrap = (async (): Promise<void> => {
        // 1) 一次性凭据迁移（必须在任何 persist 之前，避免明文被再次写回）
        await this.runCredentialMigrationOnce();
        // 2) 从加密层回填订阅凭据（headerValue 从不落 preferences）
        await this.hydrateSubscriptionCredentials();
        // 3) 节点凭据回填（Asset 缺失时用一次性 rawUri 解析兜底）
        await this.initNodes(this.nodes);
        AppLogger.info(TAG, `[perf] credentials ready (background) at +${Date.now() - t}ms`);
      })().catch((e: Error): void => {
        AppLogger.warn(TAG, `credential bootstrap failed: ${AppLogger.errText(e)}`);
      });
    }
    return this.credentialBootstrap;
  }

  /**
   * 等凭据就绪。**所有需要节点凭据的路径都必须先调它**（生成配置、测速核）。
   * 冷启动时它通常已跑完（后台），用户点连接时不会有额外等待。
   */
  async ensureCredentials(): Promise<void> {
    await this.startCredentialBootstrap();
  }

  /**
   * 一次性迁移：把历史 preferences 明文凭据写入 AssetStore（写后回读校验），
   * 全部成功后才清除明文键。任一失败保留明文并记录，绝不丢数据。
   * 幂等：非首启时不再改写凭据本体（只补建缺失项），也不重复清明文。
   */
  private async runCredentialMigrationOnce(): Promise<void> {
    await CredentialStore.loadMigrationFlag();
    const firstRun = CredentialStore.isFirstRun();
    let plainKeys: string[] = [];
    if (this.credStore !== null) {
      const raw = await this.credStore.get('sealed_node_keys_json', '[]') as string;
      plainKeys = SubscriptionService.readJsonStringArray(raw);
    }

    const sources: SubscriptionCredentialSource[] = [];
    for (const s of this.subscriptions) {
      const src = new SubscriptionCredentialSource();
      src.id = s.id;
      src.headerValue = s.headerValue;
      if (s.headerValue.length > 0) {
        sources.push(src);
      }
    }

    let report: CredentialMigrationReport;
    try {
      report = await CredentialStore.canonicalize(this.nodes, sources, !firstRun);
    } catch (e) {
      AppLogger.warn(TAG, `credential canonicalize aborted: ${AppLogger.errText(e)}`);
      return;
    }

    // 节点若仍受明文约束（Asset 写入/校验失败），其 rawUri 必须继续保留作回退源
    const keepIds = new Set<string>();
    for (const n of this.nodes) {
      let bound = false;
      let boundField = '';
      for (const f of NODE_CRED_FIELDS) {
        if (f === 'password' && n.password.length > 0) {
          bound = true;
          boundField = f;
        } else if (f === 'uuid' && n.uuid.length > 0) {
          bound = true;
          boundField = f;
        } else if (f === 'protocolParam' && n.protocolParam.length > 0) {
          bound = true;
          boundField = f;
        } else if (f === 'obfsParam' && n.obfsParam.length > 0) {
          bound = true;
          boundField = f;
        }
      }
      if (bound && !report.fieldFailed(nodeCredentialId(n), boundField)) {
        keepIds.add(nodeCredentialId(n));
      }
    }

    this.credentialsReady = true;

    if (report.failed > 0) {
      // Asset 不可用或个别凭据校验失败：绝不清明文，也不做任何持久化（保留现状）
      CredentialStore.logAssetUnavailable('migration');
      AppLogger.warn(TAG,
        `credential migration incomplete: ${report.failed} field(s) failed; plaintext preserved`);
      return;
    }
    if (!firstRun) {
      // 幂等：非首启不重复清除
      AppLogger.info(TAG, `credential migration idempotent: ${report.alreadyStored} verified, ${report.addedNew} added`);
      return;
    }

    // 首启且全部校验通过 → 清 preferences 明文凭据（节点 JSON 字段 + 订阅 headerValue 已由 toJson 恒空）
    await this.sealPlaintext(plainKeys, keepIds);
    await this.markMigrationDone();
    AppLogger.info(TAG,
      `credential migration done: ${report.migratedNodes} node(s) / ${report.migratedSubscriptions} sub credential(s) moved to asset store`);
  }

  /**
   * 残留一键扫描（专项验证用）：返回 preferences 中仍可枚举到的明文凭据键。
   *
   * 必须扫描**全部**出现位置：只查第一处会漏报 —— 第一个节点该字段是空串、
   * 后面的节点却有值时，第一个匹配点恰好是空串，审计会误判为"无残留"。
   * 凭据残留是安全结论，宁可多报也不能漏报。
   */
  async scanPlaintextResidue(): Promise<string[]> {
    const out: string[] = [];
    if (this.store === null) {
      return out;
    }
    const nodesRaw = await this.store.get(KEY_NODES, '[]') as string;
    const subsRaw = await this.store.get(KEY_SUBS, '[]') as string;
    for (const field of CredentialStore.plaintextFieldKeys()) {
      const needle = `"${field}":"`;
      const probe = `"${field}":""`;
      if (SubscriptionService.hasNonEmptyField(nodesRaw, needle, probe)) {
        out.push(`nodes_json.${field}`);
      }
      if (SubscriptionService.hasNonEmptyField(subsRaw, needle, probe)) {
        out.push(`subscriptions_json.${field}`);
      }
    }
    return out;
  }

  /**
   * 该 JSON 文本中是否存在**任一**非空的指定字段（空串是规范化目标，不算残留）。
   * 公开：纯谓词、无副作用，供残留审计单测直接断言（安全结论必须能被测试覆盖）。
   */
  static hasNonEmptyField(text: string, needle: string, probe: string): boolean {
    let from = 0;
    for (;;) {
      const hit = text.indexOf(needle, from);
      if (hit < 0) {
        return false;
      }
      if (!text.startsWith(probe, hit)) {
        return true;
      }
      from = hit + needle.length;
    }
  }

  /**
   * 清除已迁移成功的明文凭据。
   * 节点：清 preferences JSON 字段并 flush；确认写入成功后才释放 rawUri 回退源。
   * 订阅：headerValue 已不参与序列化（Subscription.toJson 恒空），无需额外处理。
   */
  private async sealPlaintext(plainKeys: string[], keepIds: Set<string>): Promise<void> {
    let sealedNodes = 0;
    let unverifiedNodes = 0;
    if (this.store !== null) {
      try {
        for (const n of this.nodes) {
          if (keepIds.has(nodeCredentialId(n))) {
            continue;
          }
          // 只有能从加密层「原值回读」的节点才允许清明文。否则一旦 Asset 缺失
          // （清理数据/升级/写入失败），重启后 password/uuid 为空 → 生成配置时整条被丢。
          const verifiable = await SubscriptionService.hasVerifiableStoredCredentials(n);
          if (!verifiable) {
            if (n.password.length > 0 || n.uuid.length > 0
              || n.protocolParam.length > 0 || n.obfsParam.length > 0) {
              unverifiedNodes = unverifiedNodes + 1;
            }
            continue;
          }
          n.password = '';
          n.uuid = '';
          n.protocolParam = '';
          n.obfsParam = '';
          n.rawYaml = '';
          n.rawUri = '';
          sealedNodes = sealedNodes + 1;
        }
        // report 传 null：明文清理由本方法**逐节点**用 hasVerifiableStoredCredentials
        // 验证后直接改内存完成，不再走 nodesToJson 的二次判定（避免两套判据不一致）。
        // 未通过验证的节点保留明文 = fail-closed，宁可多留一份也不丢凭据。
        await this.store.put(KEY_NODES, JSON.stringify(SubscriptionService.nodesToJson(this.nodes, null)));
        await this.store.flush();
      } catch (e) {
        AppLogger.warn(TAG,
          `plaintext seal failed (plaintext kept in memory only, no credential loss): ${AppLogger.errText(e)}`);
      }
    }
    if (unverifiedNodes > 0) {
      AppLogger.warn(TAG,
        `plaintext seal skipped for ${unverifiedNodes} node(s): credentials are not readable from asset store `
        + '— plaintext kept so that connection keeps working');
    }
    if (sealedNodes > 0) {
      AppLogger.info(TAG, `plaintext seal done for ${sealedNodes} node(s) (credentials verified in asset store)`);
    }
    if (this.nodes.length > 0 || plainKeys.length > 0) {
      this.sealedPlaintextKeys = true;
    }
  }

  /**
   * 加密层回读校验（漏洞 A 第二半：凭据封存后未回填）。
   * 只有节点内存中每个非空凭据字段都能从 AssetStore 原值读回时才返回 true;
   * Asset 缺失/写入失败/回读不一致一律返回 false → 明文保留, 保证连接时凭据可用。
   * 无需凭据的节点（如 anytls/tuic 中继型）直接视为可封存。
   */
  private static async hasVerifiableStoredCredentials(n: ProxyNode): Promise<boolean> {
    // extraOpts / rawUri 自 2026-10 起同样是 Asset 字段（写入端见 CredentialStore.
    // NODE_CRED_FIELDS），因此"可封存"判定必须一并校验，否则会出现
    // 「明文已清、加密层却没存」→ hysteria2 混淆/端口跳跃/直链回退静默失效。
    const needed = n.password.length > 0 || n.uuid.length > 0
      || n.protocolParam.length > 0 || n.obfsParam.length > 0
      || n.extraOpts.length > 0 || n.rawUri.length > 0;
    if (!needed) {
      return true;
    }
    const empty = new NodeCredentialValues();
    let stored: NodeCredentialValues;
    try {
      stored = await CredentialStore.nodeCredentials(nodeCredentialId(n), empty);
    } catch (e) {
      return false;
    }
    if (n.password.length > 0 && stored.password !== n.password) {
      return false;
    }
    if (n.uuid.length > 0 && stored.uuid !== n.uuid) {
      return false;
    }
    if (n.protocolParam.length > 0 && stored.protocolParam !== n.protocolParam) {
      return false;
    }
    if (n.obfsParam.length > 0 && stored.obfsParam !== n.obfsParam) {
      return false;
    }
    if (n.extraOpts.length > 0 && stored.extraOpts !== n.extraOpts) {
      return false;
    }
    if (n.rawUri.length > 0 && stored.rawUri !== n.rawUri) {
      return false;
    }
    return true;
  }

  /**
   * 迁移标记写入：与 loadMigrationFlag（从 Asset 读）**同一存储**。
   *
   * 历史 bug：这里写 preferences、那里读 Asset，永远读不到 → isFirstRun() 恒为
   * true → sealPlaintext（130 节点循环 + 一次大 JSON 落盘）每次启动都重跑。
   * 真机实测这一条就占 1.6s。
   */
  private async markMigrationDone(): Promise<void> {
    await CredentialStore.markMigrationFlagInAsset();
  }

  private static readJsonStringArray(raw: string): string[] {
    try {
      const arr = JSON.parse(raw) as string[];
      return Array.isArray(arr) ? arr : [];
    } catch (e) {
      return [];
    }
  }

  /**
   * 回填订阅凭据：Asset 缺失时保持内存态原值（本进程内新输入），
   * 不回退任何持久化明文来源。
   */
  private async hydrateSubscriptionCredentials(): Promise<void> {
    for (const s of this.subscriptions) {
      const value = await CredentialStore.subscriptionCredential(s.id, s.headerValue);
      s.headerValue = value;
    }
  }

  /**
   * 节点凭据回填：Asset 优先。
   * 缺失时回退一次性绑定的 rawUri（解析仅驻留内存；绑定本身在解除前会短暂驻留
   * preferences，见 storeCredentials —— 写入成功后由 markNodeSealed 立即删除）。
   */
  async initNodes(nodes: ProxyNode[]): Promise<void> {
    if (this.credStore === null) {
      return;
    }
    const raw = await this.credStore.get('sealed_node_keys_json', '[]') as string;
    const sealed = new Set<string>();
    for (const k of SubscriptionService.readJsonStringArray(raw)) {
      sealed.add(k);
    }
    // 批量加载：全量凭据 1 次 asset.query + 全部一次性 rawUri 1 次 getAll。
    // 此前每节点 1 次全量 query + 1 次 preferences.get（70 节点 = 140 次 IPC 且 O(N²)）。
    const assetMap = await CredentialStore.loadAllCredentials();
    let rawUriAll: Record<string, Object> = {};
    try {
      rawUriAll = await this.credStore.getAll() as Record<string, Object>;
    } catch (e) {
      // getAll 失败按无回退源处理：凭据缺失在下方审计中可见
    }
    for (const n of nodes) {
      let uri = '';
      if (!sealed.has(nodeCredentialId(n))) {
        const stored = rawUriAll[nodeUriKey(nodeCredentialId(n))];
        if (typeof stored === 'string') {
          uri = stored as string;
        }
      }
      const fallback = SubscriptionService.parseFallbackCredentials(n, uri);
      const values = CredentialStore.nodeCredentialsFromCache(assetMap, nodeCredentialId(n), fallback);
      n.password = values.password;
      n.uuid = values.uuid;
      n.protocolParam = values.protocolParam;
      n.obfsParam = values.obfsParam;
      // extraOpts 可内嵌 obfs-password / ports，rawUri 是整条节点链接：两者都已从
      // Preferences 剥离，必须在这里回填，否则 hysteria2 混淆与端口跳跃会静默失效。
      // 只在加密层确实有值时才覆盖，避免把解析阶段刚得到的值抹成空串。
      if (values.extraOpts.length > 0) {
        n.extraOpts = values.extraOpts;
      }
      if (values.rawUri.length > 0) {
        n.rawUri = values.rawUri;
      }
      if (uri.length > 0) {
        await this.markNodeSealed(nodeCredentialId(n), n, sealed);
      }
    }
    // 回填后审计：仍缺凭据的节点必须在 UI 可见（否则连接时生成配置会整批丢成空行）
    const dropStats = ClashConfigGenerator.countDroppedNodes(nodes);
    this.credentialMissingCount = dropStats.missingCredential;
    if (dropStats.missingCredential > 0) {
      AppLogger.warn(TAG,
        `${dropStats.missingCredential} node(s) still missing credentials after hydrate `
        + '(asset store unavailable or credential lost) — 连接时这些节点无法写入内核配置');
    }
  }

  /** 一次性回退源用完后移除 preferences 中的副本（Asset 已持有加密凭据） */
  private async markNodeSealed(nodeId: string, node: ProxyNode, sealed: Set<string>): Promise<void> {
    if (this.credStore === null) {
      return;
    }
    try {
      await this.credStore.delete(nodeUriKey(nodeId));
      sealed.add(nodeId);
      await this.credStore.put('sealed_node_keys_json', JSON.stringify(Array.from(sealed)));
      await this.credStore.flush();
    } catch (e) {
      AppLogger.warn(TAG, `sealed node record update failed: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * 一次性回退源解析：优先 rawUri（历史版本持久化的原始节点链接），
   * 其次从节点自身字段（老版本明文，尚未被清扫时）还原。结果只驻留内存。
   */
  private static parseFallbackCredentials(n: ProxyNode, uri: string): NodeCredentialValues {
    const out = new NodeCredentialValues();
    out.password = n.password;
    out.uuid = n.uuid;
    out.protocolParam = n.protocolParam;
    out.obfsParam = n.obfsParam;
    if (uri.length === 0) {
      return out;
    }
    let parsed: ProxyNode | null = null;
    try {
      // 2026-10-20（B6）：走规范解析层（旧解析器已退场）
      const canonical: ParsedNode | ParseError = parseUriNode(uri, n.subscriptionId);
      if (!(canonical instanceof ParseError)) {
        parsed = ProxyNode.fromCanonical(canonical, n.subscriptionId, n.id);
      }
    } catch (e) {
      AppLogger.warn(TAG, 'rawUri fallback parse failed');
      return out;
    }
    if (parsed === null) {
      return out;
    }
    if (parsed.password.length > 0) {
      out.password = parsed.password;
    }
    if (parsed.uuid.length > 0) {
      out.uuid = parsed.uuid;
    }
    if (parsed.protocolParam.length > 0) {
      out.protocolParam = parsed.protocolParam;
    }
    if (parsed.obfsParam.length > 0) {
      out.obfsParam = parsed.obfsParam;
    }
    return out;
  }

  /** 节点稳定指纹（跨刷新不变, 用于删除记忆）。name 用去重前的原始名, 与刷新解析结果一致 */
  static nodeKey(n: ProxyNode): string {
    return `${n.subscriptionId}|${n.server}|${n.port}|${SubscriptionService.baseName(n.name)}`;
  }

  /**
   * 去掉去重后缀, 还原节点原始名。
   * 两种历史形态都要剥: " #2"（ensureUniqueNames 旧形态）与 " (2)"（YamlMerger.uniqueProxyName
   * 形态, 现已统一为该形态）。只剥其中一种会让「改名后的节点」与加密层 alias / 隐藏清单失配 ——
   * 表现为凭据回填失败（生成配置时整条丢成空行）或已删节点刷新后复活。
   */
  private static baseName(name: string): string {
    return baseNodeName(name);
  }

  /**
   * 全局节点名去重: mihomo 对 proxies 段重名直接拒绝启动
   * ("parse config: proxy X is the duplicate name") —— 一个重名会让
   * 整个内核起不来, 所有节点都连不上。按列表顺序给重名节点追加
   * " #2/#3..." 后缀; UI/PROXY 组/内核配置/API 选节点共用此名, 天然一致。
   * 返回是否发生了改名。
   */
  ensureUniqueNames(): boolean {
    // ── FlClash 同构（2026-10-22）：**不改节点名** ─────────────────────────
    // FlClash 从不重命名节点：内核加载的原文名就是 App 显示/选择/测速用的名字。
    // 跨订阅去重改名会让「App 名字」与「内核名字」分叉，`PUT /proxies/{group}`
    // 与 `GET /proxies/{name}/delay` 全部 404（真机表现为「点了没反应 / 全超时」）。
    // 重名由订阅原文自身负责（内核会整份拒载，与 FlClash 行为一致）。
    return false;
  }

  /** 旧实现（保留说明，勿恢复）：按列表顺序给重名节点追加 " (n)" 后缀。 */
  private legacyEnsureUniqueNames(): boolean {
    const used = new Set<string>();
    let changed = false;
    for (const n of this.nodes) {
      if (used.has(n.name)) {
        // 统一后缀形态为 "name (n)"（与 YamlMerger.uniqueProxyName 一致）,
        // 这样 nodeKey/baseName 只需要剥一种形态, 隐藏清单与加密层 alias 才稳定。
        const rawBase = SubscriptionService.baseName(n.name);
        const base = rawBase.length > 0 ? rawBase : (n.name.length > 0 ? n.name : 'node');
        let k = 2;
        while (used.has(`${base} (${k})`)) {
          k = k + 1;
        }
        n.name = `${base} (${k})`;
        changed = true;
      }
      used.add(n.name);
    }
    return changed;
  }

  /**
   * 删除单个节点（订阅页长按）: 从列表移除并记入隐藏清单,
   * 后续订阅刷新自动过滤; 手动直连节点同样支持（重新导入链接可再次添加）。
   */
  async removeNode(nodeId: string): Promise<boolean> {
    const n = this.findNode(nodeId);
    if (n === null) {
      return false;
    }
    const key = SubscriptionService.nodeKey(n);
    if (!this.hiddenNodes.includes(key)) {
      this.hiddenNodes.push(key);
    }
    this.nodes = this.nodes.filter((x) => x.id !== nodeId);
    const sub = this.subscriptions.find((s) => s.id === n.subscriptionId);
    if (sub !== undefined) {
      sub.nodeCount = this.nodesOf(sub.id).length;
    }
    await this.persist();
    AppLogger.info(TAG, `node removed: ${n.name} (hidden total ${this.hiddenNodes.length})`);
    return true;
  }

  private static validString(value: Object, maxLength: number, allowEmpty: boolean = true): boolean {
    return typeof value === 'string' && value.length <= maxLength && (allowEmpty || value.length > 0);
  }

  private static validInteger(value: Object, min: number, max: number): boolean {
    return typeof value === 'number' && Number.isInteger(value) && value >= min && value <= max;
  }

  /**
   * 落盘的 lastRefreshResult 白名单。
   *
   * ⚠ 这里漏掉任何一个**会被写入**的枚举值，都会造成**订阅静默丢失**：
   * mapSubs 对白名单外的值走 `skipped++; continue;`，整条订阅记录被丢弃 ——
   * 用户下次启动时那条订阅直接不见了，且只有一行 warn 日志。
   *
   * 曾经真实踩到：RATE_LIMITED / EMPTY_ENTRIES 会被 1869/1788/1989 写入，
   * 但不在白名单里 ⇒ 一次 429 限流或「200 但 0 条目」之后，重启即丢订阅。
   * 因此本函数改为**遍历枚举全集**，新增枚举值自动纳入，不会再漏。
   */
  private static validRefreshStatus(value: string): boolean {
    if (value === '') {
      return true;
    }
    const all: string[] = [
      SubscriptionRefreshStatus.OK,
      SubscriptionRefreshStatus.NOT_MODIFIED,
      SubscriptionRefreshStatus.NETWORK_ERROR,
      SubscriptionRefreshStatus.HTTP_ERROR,
      SubscriptionRefreshStatus.EMPTY_RESPONSE,
      SubscriptionRefreshStatus.DECODE_ERROR,
      SubscriptionRefreshStatus.PARSE_ERROR,
      SubscriptionRefreshStatus.LIMIT_EXCEEDED,
      SubscriptionRefreshStatus.PERSIST_ERROR,
      SubscriptionRefreshStatus.RATE_LIMITED,
      SubscriptionRefreshStatus.EMPTY_ENTRIES
    ];
    return all.indexOf(value) >= 0;
  }

  private static mapSubs(json: Object): Subscription[] {
    const out: Subscription[] = [];
    if (!Array.isArray(json)) {
      AppLogger.warn(TAG, 'subscriptions preferences root is not an array');
      return out;
    }
    let skipped = 0;
    for (const item of json as Object[]) {
      if (item === null || typeof item !== 'object') {
        skipped++;
        continue;
      }
      const j = item as SubscriptionJson;
      if (!SubscriptionService.validString(j.id, 256, false)
        || !SubscriptionService.validString(j.name, 4096)
        || !SubscriptionService.validString(j.url, 8192, false)
        || !SubscriptionService.validString(j.headerName, 256)
        || !SubscriptionService.validString(j.headerValue, 16 * 1024)
        || !SubscriptionService.validString(j.lastRefreshResult, 64)
        || !SubscriptionService.validRefreshStatus(j.lastRefreshResult)
        || !SubscriptionService.validInteger(j.lastFetchedAt, 0, Number.MAX_SAFE_INTEGER)
        || !SubscriptionService.validInteger(j.nodeCount, 0, 100000)
        || typeof j.enabled !== 'boolean'
        || !SubscriptionService.validInteger(j.sortOrder, 0, 100000)) {
        skipped++;
        continue;
      }
      // 双轨附加字段：非法值就地归一（旧存储无这些键），绝不因附加字段丢弃整条订阅
      if (typeof j.rawProviderState !== 'string' || !RawProviderStates.isValid(j.rawProviderState)) {
        j.rawProviderState = '';
      }
      if (typeof j.rawProviderNodeEstimate !== 'number'
        || !Number.isInteger(j.rawProviderNodeEstimate)
        || j.rawProviderNodeEstimate < 0 || j.rawProviderNodeEstimate > 100000) {
        j.rawProviderNodeEstimate = 0;
      }
      // etag 同为后加字段：非法/缺失一律归零（= 下次做完整拉取），不丢订阅
      if (typeof j.etag !== 'string' || j.etag.length > 1024) {
        j.etag = '';
      }
      // 订阅自带 rules/rule-providers：非法值就地归一（旧存储无这些键），绝不丢订阅
      if (typeof j.subRules !== 'string' || j.subRules.length > 256 * 1024) {
        j.subRules = '';
      }
      if (typeof j.subRuleProviders !== 'string' || j.subRuleProviders.length > 256 * 1024) {
        j.subRuleProviders = '';
      }
      // 订阅 dns 上游：非法值就地归一（旧存储无这些键），绝不丢订阅
      if (typeof j.subDnsProxyServers !== 'string' || j.subDnsProxyServers.length > 8 * 1024) {
        j.subDnsProxyServers = '';
      }
      if (typeof j.subDnsPolicies !== 'string' || j.subDnsPolicies.length > 64 * 1024) {
        j.subDnsPolicies = '';
      }
      out.push(Subscription.fromPersistJson(j));
    }
    if (skipped > 0) {
      AppLogger.warn(TAG, `ignored ${skipped} invalid subscription records`);
    }
    return out;
  }

  /** 追加一条无效原因明细（去重、最多 3 条、';' 分隔）；只做明细，不做计数 */
  private static appendInvalidReason(d: SubscriptionImportDiagnostics, reason: string): void {
    const text = reason.trim();
    if (text.length === 0) {
      return;
    }
    if (d.invalidReasons.length === 0) {
      d.invalidReasons = text;
      return;
    }
    const parts = d.invalidReasons.split(';');
    if (parts.length >= 3) {
      return;
    }
    for (const it of parts) {
      if (it === text) {
        return;
      }
    }
    d.invalidReasons = `${d.invalidReasons};${text}`;
  }

  /**
   * 把「无效 / 缺字段条目」的原因计入诊断：invalidCount 自增，并把原因追加进
   * invalidReasons（最多 3 条、去重、';' 分隔）。d 为 undefined（调用方没有诊断
   * 对象）时只返回，不抛错 —— 三入口统一走这里，避免任何静默丢弃。
   *
   * 注：参数写成 `d: SubscriptionImportDiagnostics | undefined` 而不是 `d?:`，
   * 因为 TS/ArkTS 不允许「必选参数跟在可选参数之后」（TS1016）。
   */
  private static noteInvalid(d: SubscriptionImportDiagnostics | undefined, reason: string): void {
    if (d === undefined) {
      return;
    }
    d.invalidCount = d.invalidCount + 1;
    SubscriptionService.appendInvalidReason(d, reason);
  }

  /**
   * 批量登记无效条目：invalidCount 一次加 count，只追加一条汇总原因。
   * 用于 YamlMerger 这类上游（它只给「失败条数 + 明细」）。
   */
  private static noteInvalidBulk(d: SubscriptionImportDiagnostics | undefined,
    count: number, reason: string): void {
    if (d === undefined || count <= 0) {
      return;
    }
    d.invalidCount = d.invalidCount + count;
    SubscriptionService.appendInvalidReason(d, reason);
  }

  /** 把 YamlMerger 的跳过/无效统计并入统一诊断（不再只写日志） */
  private static absorbYamlMergeStats(d: SubscriptionImportDiagnostics): void {
    if (YamlMerger.lastSkippedCount > 0) {
      d.unsupportedCount = d.unsupportedCount + YamlMerger.lastSkippedCount;
      d.unsupportedTypes = SubscriptionService.mergeTypes(d.unsupportedTypes, YamlMerger.lastSkippedTypes);
    }
    if (YamlMerger.lastInvalidCount > 0) {
      const detail = YamlMerger.lastInvalidReasons.join('；');
      SubscriptionService.noteInvalidBulk(d, YamlMerger.lastInvalidCount,
        `YAML 节点无效 ${YamlMerger.lastInvalidCount} 条：`
        + `${detail.length > 0 ? detail : '字段缺失或格式错误'}`);
    }
  }

  /** 逗号分隔的类型清单合并（去重，保持原有顺序） */
  private static mergeTypes(current: string, extra: string): string {
    if (extra.length === 0) {
      return current;
    }
    if (current.length === 0) {
      return extra;
    }
    const seen = new Set<string>();
    const out: string[] = [];
    for (const raw of `${current},${extra}`.split(',')) {
      const t = raw.trim();
      if (t.length === 0 || seen.has(t)) {
        continue;
      }
      seen.add(t);
      out.push(t);
    }
    return out.join(',');
  }

  /** provider 拉取/解析失败明细（去重、最多 3 条、';' 分隔） */
  private static appendProviderFailure(d: SubscriptionImportDiagnostics, reason: string): void {
    const text = reason.trim();
    if (text.length === 0) {
      return;
    }
    if (d.providerFailureReasons.length === 0) {
      d.providerFailureReasons = text;
      return;
    }
    const parts = d.providerFailureReasons.split(';');
    if (parts.length >= 3) {
      return;
    }
    for (const it of parts) {
      if (it === text) {
        return;
      }
    }
    d.providerFailureReasons = `${d.providerFailureReasons};${text}`;
  }

  /** 统一异常文案（不输出 URL / 凭据，只输出错误消息） */
  private static describeError(e: Object): string {
    return AppLogger.errText(e);
  }

  /**
   * 生成配置阶段丢弃账本并入诊断：列表显示 N 个节点，内核实际可写入 N-configDroppedCount 个。
   * 导入后立即算一次，用户就能在导入提示里看到「列表有、内核无」的风险（而不是等到连接）。
   */
  private noteConfigDrops(d: SubscriptionImportDiagnostics): void {
    const dropStats = ClashConfigGenerator.countDroppedNodes(this.nodes);
    d.configDroppedCount = dropStats.dropped();
    d.configMissingCredentialCount = dropStats.missingCredential;
    if (dropStats.hasDrop()) {
      d.configDropReasons = dropStats.reasons();
    }
  }

  // ── 双轨（原始订阅 → 内核 file provider；开关默认关闭）──────────────────

  /** 追加一条双轨原因明细（去重、最多 3 条、'；' 分隔） */
  private static appendRawReason(d: SubscriptionImportDiagnostics, reason: string): void {
    const text = reason.trim();
    if (text.length === 0) {
      return;
    }
    if (d.rawProviderReasons.length === 0) {
      d.rawProviderReasons = text;
      return;
    }
    const parts = d.rawProviderReasons.split('；');
    if (parts.length >= 3) {
      return;
    }
    for (const it of parts) {
      if (it === text) {
        return;
      }
    }
    d.rawProviderReasons = `${d.rawProviderReasons}；${text}`;
  }

  /**
   * 双轨：把订阅原文落盘为内核 `type: file` provider。
   *
   * 铁律（与任务约束一致）：
   * - 开关关闭 → 什么都不做（且诊断文案为空，与现状完全一致）；
   * - 落盘失败 → 绝不抛出、绝不影响导入结果，只记诊断并降级为「仅解析链」；
   * - 原文不是 Clash YAML（内核 file provider 只认带 proxies 的 YAML / 代理列表）→
   *   标「不适用」并显式写进诊断，避免被误认为 provider 丢了节点。
   * 返回是否落盘成功。
   */
  private writeRawProvider(sub: Subscription, body: string, eligible: boolean,
    diagnostics: SubscriptionImportDiagnostics): boolean {
    diagnostics.rawProviderEnabled = RawSubscriptionStore.enabled;
    if (!RawSubscriptionStore.enabled) {
      return false;
    }
    if (!eligible) {
      diagnostics.rawProviderIneligible = diagnostics.rawProviderIneligible + 1;
      sub.rawProviderState = RawProviderStates.INELIGIBLE;
      sub.rawProviderNodeEstimate = 0;
      RawSubscriptionStore.drop(sub.id);
      SubscriptionService.appendRawReason(diagnostics,
        `${sub.name}：原文不是 Clash YAML（如 base64 链接列表），不能作为 file provider`);
      return false;
    }
    const result: RawWriteResult = RawSubscriptionStore.writeRaw(sub.id, body);
    if (!result.ok) {
      diagnostics.rawProviderFailed = diagnostics.rawProviderFailed + 1;
      sub.rawProviderState = RawProviderStates.FAILED;
      sub.rawProviderNodeEstimate = 0;
      RawSubscriptionStore.drop(sub.id);
      SubscriptionService.appendRawReason(diagnostics,
        `${sub.name}：原文落盘失败（${result.reason}），已降级为仅解析链`);
      AppLogger.warn(TAG, `raw provider write failed for ${sub.name}: ${result.reason}`);
      return false;
    }
    let estimate = 0;
    try {
      estimate = YamlMerger.proxyItemGroups(body).length;
    } catch (e) {
      estimate = 0;
    }
    diagnostics.rawProviderWritten = diagnostics.rawProviderWritten + 1;
    diagnostics.rawProviderNodeEstimate = diagnostics.rawProviderNodeEstimate + estimate;
    sub.rawProviderState = RawProviderStates.READY;
    sub.rawProviderNodeEstimate = estimate;
    this.registerRawProvider(sub.id, estimate);
    AppLogger.info(TAG, `raw provider written: ${sub.name} -> ${RawSubscriptionStore.fileNameFor(sub.id)}`
      + ` (${result.bytes} bytes, ${estimate} entries)`);
    return true;
  }

  /**
   * 明文 HTTP 订阅是否被用户显式允许（默认拒绝，对齐 FlClash / Verge / CMFA）。
   * 读设置失败一律按「不允许」处理 —— 安全开关的失败方向必须朝严格一侧。
   */
  private static async insecureSubscriptionHttpAllowed(): Promise<boolean> {
    try {
      const settings = await SettingsService.load();
      return settings.allowInsecureSubscriptionHttp;
    } catch (e) {
      return false;
    }
  }

  /**
   * 双轨诊断汇总（「解析到 N / provider 读到 M」+ 生成配置时实际发出的 provider 条数）。
   * 「配置内 provider 条数」直接复用 ClashConfigGenerator.planRawProviders，与真正写进配置
   * 的逻辑同源，避免诊断与实际不一致。
   */
  private updateRawProviderSummary(diagnostics: SubscriptionImportDiagnostics): void {
    diagnostics.rawProviderEnabled = RawSubscriptionStore.enabled;
    const probe = new AppSettings();
    probe.useRawProviderConfig = RawSubscriptionStore.enabled;
    const plan = ClashConfigGenerator.planRawProviders(probe, this.nodes);
    diagnostics.rawProviderEmitted = plan.stats.emitted;
    if (!diagnostics.rawProviderEnabled) {
      this.lastRawProviderSummary = '双轨 provider 关闭（原文未落盘，配置与旧版一致）';
      RawSubscriptionStore.lastDiagnosticLine = this.lastRawProviderSummary;
      return;
    }
    let text = `${diagnostics.parsedVsProviderText()}；配置内 provider ${plan.stats.emitted} 条`
      + `（候选 ${plan.stats.candidates}，缺失文件 ${plan.stats.missingFiles}，无对应节点 ${plan.stats.orphaned}）`;
    if (diagnostics.rawProviderFailed > 0 || diagnostics.rawProviderIneligible > 0) {
      text += '；注意：部分订阅未落盘，见明细';
    }
    this.lastRawProviderSummary = text;
    RawSubscriptionStore.lastDiagnosticLine = text;
  }

  /**
   * 双轨开关切换（设置/诊断面板调用）：写盘由调用方（SettingsService）负责，
   * 这里负责落盘仓闸门 + 每订阅状态 + 文案。
   *
   * 2026-10-22：**关闭双轨不再删除落盘原文**。原文现在是「节点定义原文透传」的数据源，
   * 与 provider 开关解耦 —— 删掉会让下一次冷启动只能重新联网补拉，离线或订阅过期时
   * 直接退化成解析发射（丢字段/丢新协议）。要清磁盘请走 `purgeRawProviders()`。
   */
  async setRawProviderEnabled(enabled: boolean): Promise<number> {
    RawSubscriptionStore.setEnabled(enabled, false);
    let changed = false;
    for (const s of this.subscriptions) {
      if (s.id === DIRECT_GROUP_ID) {
        continue;
      }
      const exists = enabled ? RawSubscriptionStore.has(s.id) : false;
      const next = enabled
        ? (exists ? RawProviderStates.READY : RawProviderStates.MISSING)
        : RawProviderStates.OFF;
      const estimate = exists ? SubscriptionService.countRawEntries(s.id) : 0;
      if (s.rawProviderState !== next || s.rawProviderNodeEstimate !== estimate) {
        changed = true;
      }
      s.rawProviderState = next;
      s.rawProviderNodeEstimate = estimate;
      if (exists) {
        this.registerRawProvider(s.id, estimate);
      }
      // 注意：这里**不再** RawSubscriptionStore.drop(s.id) —— 关闭 provider 只是不使用它，
      // 原文文件要留着给原文透传用（见方法头注释）。
    }
    if (changed) {
      try {
        await this.persist();
      } catch (e) {
        AppLogger.warn(TAG, `raw provider state persist failed: ${SubscriptionService.describeError(e)}`);
      }
    }
    this.lastRawProviderSummary = enabled
      ? '双轨 provider 已开启：下次刷新/连接起生效（原文按订阅 id 落盘，由内核自行解析）'
      : '双轨 provider 已关闭（落盘原文保留，原文透传仍用它）';
    this.lastRawProviderMessage = this.lastRawProviderSummary;
    AppLogger.info(TAG, this.lastRawProviderSummary);
    return 0;
  }

  /** 手动清理落盘原文（诊断面板入口）；节点列表不受影响 */
  async purgeRawProviders(): Promise<number> {
    const removed = RawSubscriptionStore.removeAll();
    let changed = false;
    for (const s of this.subscriptions) {
      if (s.id === DIRECT_GROUP_ID) {
        continue;
      }
      if (s.rawProviderState === RawProviderStates.READY) {
        s.rawProviderState = RawProviderStates.MISSING;
        s.rawProviderNodeEstimate = 0;
        changed = true;
      }
    }
    if (changed) {
      try {
        await this.persist();
      } catch (e) {
        AppLogger.warn(TAG, `raw provider purge persist failed: ${SubscriptionService.describeError(e)}`);
      }
    }
    this.lastRawProviderMessage = `已清理 ${removed} 个 provider 落盘文件（节点列表不受影响；刷新订阅可重新落盘）`;
    AppLogger.info(TAG, this.lastRawProviderMessage);
    return removed;
  }

  /** 订阅卡/诊断：单个订阅的双轨 provider 状态（节点永远不因 provider 缺失被删除） */
  rawProviderStatusFor(subscriptionId: string): RawProviderStatus {
    const sub = this.subscriptions.find((s) => s.id === subscriptionId);
    const state = sub === undefined ? '' : sub.rawProviderState;
    const status = RawSubscriptionStore.statusFor(subscriptionId, state);
    if (sub !== undefined && status.fileExists && sub.rawProviderNodeEstimate > 0) {
      // 以落库的估算值为准（registerRawProvider 与之一致）
      status.nodeEstimate = sub.rawProviderNodeEstimate;
    }
    return status;
  }

  /**
   * provider 内容按「普通订阅内容」解析：Clash YAML 走合并引擎，链接 / 整体 Base64
   * 走统一解析器，统计并入同一次导入的 diagnostics（来源标注为 provider）。
   */
  private static parseProviderBody(body: string, subscriptionId: string,
    providerLabel: string, diagnostics: SubscriptionImportDiagnostics): ProxyNode[] {
    YamlMerger.resetSkipStats();
    // 先解码再判是不是 YAML 文档（base64 包裹的 Clash YAML 不能掉进链接分支）
    const dispatch = BodyDispatch.classify(body);
    if (dispatch.kind === BodyKind.YAML) {
      const merged: MergedProxy[] = YamlMerger.merge([dispatch.body],
        providerLabel.length > 0 ? providerLabel : 'provider', '');
      SubscriptionService.absorbYamlMergeStats(diagnostics);
      const nodes = SubscriptionService.mergedToNodes(merged, subscriptionId, diagnostics, dispatch.body);
      diagnostics.inputCount = diagnostics.inputCount + nodes.length + diagnostics.invalidCount
        + diagnostics.unsupportedCount;
      return nodes;
    }
    const parseResult = SubscriptionParser.parseDetailed(body, subscriptionId);
    diagnostics.inputCount = diagnostics.inputCount + parseResult.diagnostics.inputCount;
    diagnostics.duplicateCount = diagnostics.duplicateCount + parseResult.diagnostics.duplicateCount;
    if (parseResult.diagnostics.invalidCount > 0) {
      SubscriptionService.noteInvalidBulk(diagnostics, parseResult.diagnostics.invalidCount,
        `provider 无效链接 ${parseResult.diagnostics.invalidCount} 条`);
    }
    diagnostics.unsupportedCount = diagnostics.unsupportedCount + parseResult.diagnostics.unsupportedCount;
    diagnostics.unsupportedTypes = SubscriptionService.mergeTypes(diagnostics.unsupportedTypes,
      parseResult.diagnostics.unsupportedTypes);
    return parseResult.nodes;
  }

  /**
   * 合并结果 → 节点模型（仅映射白名单结构化字段，proxyType 保留真实类型）。
   * server/port 缺失的条目必须计数并回报（漏洞 E：此前是静默丢弃）。
   *
   * 【2026-10-22 · FlClash 同构】**App 不再判节点可用性**：
   * 订阅原文是内核配置的基底（`RuntimeConfigBuilder` → `ProfileConfigMerger`，
   * `proxies` 段整段由原文接管），节点在不在、能不能用由内核解析结果说话。
   * 真机实证：同一 `server:port` 上挂两条不同节点时，App 侧「reality 旁挂表 +
   * 必填闸门」会串台，把一条内核完全能用的节点判成「定义不完整」并踢出列表。
   * ⇒ 这里**全部保留**：不再 `continue`、不再写「定义不完整」台账；
   * 合并阶段没产出的条目只进诊断（App 读不出来 ≠ 节点有问题）。
   *
   * @param sourceBody 订阅原文（对账用：原文声明过、合并却没产出的条目进诊断）
   */
  private static mergedToNodes(merged: MergedProxy[], subscriptionId: string,
    diagnostics?: SubscriptionImportDiagnostics, sourceBody?: string): ProxyNode[] {
    const out: ProxyNode[] = [];
    let counter = 0;
    let dropped = 0;
    // ── 映射 + 对账（不做裁决）──
    // plan 一次算清两件事：
    //   ① 每条合并结果的规范键视图（凭据映射/诊断）；
    //   ② 原文声明但合并阶段没产出的条目（App 读不出来 —— 只进诊断）。
    const plan = YamlNodeAdapter.plan(merged, sourceBody !== undefined ? sourceBody : '');
    for (const item of plan.dropped) {
      AppLogger.warn(TAG, `yaml item not produced by App parser: ${item.reason}`);
    }
    for (const entry of plan.entries) {
      const m = entry.merged;
      const n = new ProxyNode();
      n.id = `${subscriptionId}-m${counter++}`;
      n.subscriptionId = subscriptionId;
      n.name = m.name;
      // 合并引擎输出的即订阅原始名（yaml_cache 跨刷新保名），冻结给分组匹配用
      n.originalName = m.name;
      n.server = m.server;
      n.port = m.port;
      n.password = m.password;
      n.method = m.cipher;
      n.protocol = m.protocol;
      n.protocolParam = m.protocolParam;
      n.obfs = m.obfs;
      n.obfsParam = m.obfsParam;
      n.proxyType = m.type;
      n.uuid = m.uuid;
      n.alterId = m.alterId;
      n.udp = m.udp;
      n.network = m.network;
      n.tls = m.tls;
      n.servername = m.servername;
      n.skipCertVerify = m.skipCertVerify;
      n.flow = m.flow;
      n.clientFingerprint = m.clientFingerprint;
      n.certFingerprint = m.certFingerprint;
      n.realityPublicKey = m.realityPublicKey;
      n.realityShortId = m.realityShortId;
      n.wsPath = m.wsPath;
      n.wsHost = m.wsHost;
      n.grpcServiceName = m.grpcServiceName;
      n.hyUp = m.hyUp;
      n.hyDown = m.hyDown;
      n.alpnList = m.alpnList;
      n.extraOpts = m.extraOpts;
      n.rawYaml = '';
      n.rawTemplate = m.rawTemplate;
      if (m.type === 'ssr') {
        n.type = ProxyNodeType.SSR;
      } else if (m.type === 'ss') {
        n.type = ProxyNodeType.SS;
      } else {
        n.type = ProxyNodeType.UNKNOWN;
      }
      // direct 出站没有 server/port（mihomo 合法节点），不能按缺字段丢弃
      if ((n.server.length > 0 && n.port > 0) || n.proxyType === 'direct') {
        out.push(n);
      } else {
        dropped = dropped + 1;
      }
    }
    if (dropped > 0) {
      SubscriptionService.noteInvalid(diagnostics, `合并映射丢弃 ${dropped} 条（缺 server 或 port）`);
      AppLogger.warn(TAG, `mergedToNodes dropped ${dropped} node(s) without server/port`);
    }
    return out;
  }

  public static mapNodes(json: Object, diagnostics?: SubscriptionImportDiagnostics): ProxyNode[] {
    const out: ProxyNode[] = [];
    if (!Array.isArray(json)) {
      AppLogger.warn(TAG, 'nodes preferences root is not an array');
      SubscriptionService.noteInvalid(diagnostics, '节点存储根节点不是数组');
      return out;
    }
    let skipped = 0;
    for (const item of json as Object[]) {
      if (item === null || typeof item !== 'object') {
        skipped++;
        continue;
      }
      const j = item as ProxyNodeJson;
      // direct 出站允许 server 为空、port 为 0（mihomo 合法节点）
      const isDirect = j.proxyType === 'direct';
      const validType = j.type === 'ss' || j.type === 'ssr' || j.type === 'other';
      if (!SubscriptionService.validString(j.id, 256, false)
        || !SubscriptionService.validString(j.subscriptionId, 256, false)
        || !SubscriptionService.validString(j.name, 4096)
        || (!isDirect && (!SubscriptionService.validString(j.server, 4096, false)
          || !SubscriptionService.validInteger(j.port, 1, 65535)))
        || !SubscriptionService.validString(j.password, 64 * 1024)
        || !SubscriptionService.validString(j.method, 256)
        || !SubscriptionService.validString(j.protocol, 256)
        || !SubscriptionService.validString(j.protocolParam, 64 * 1024)
        || !SubscriptionService.validString(j.obfs, 256)
        || !SubscriptionService.validString(j.obfsParam, 64 * 1024)
        || !SubscriptionService.validString(j.type, 32, false)
        || !validType
        || !SubscriptionService.validString(j.proxyType, 64)
        || !SubscriptionService.validString(j.uuid, 4096)
        || !SubscriptionService.validInteger(j.alterId, 0, 2147483647)
        || typeof j.udp !== 'boolean'
        || !SubscriptionService.validString(j.network, 256)
        || typeof j.tls !== 'boolean'
        || !SubscriptionService.validString(j.servername, 4096)
        || typeof j.skipCertVerify !== 'boolean'
        || !SubscriptionService.validString(j.flow, 4096)
        || !SubscriptionService.validString(j.clientFingerprint, 256)
        // certFingerprint 是**后加**字段：老 nodes_json 里没有这个键，
        // 必须按可选校验，否则整条节点记录会被丢弃（同 validRefreshStatus 那类坑）。
        || (j.certFingerprint !== undefined && !SubscriptionService.validString(j.certFingerprint, 256))
        || !SubscriptionService.validString(j.realityPublicKey, 4096)
        || !SubscriptionService.validString(j.realityShortId, 4096)
        || !SubscriptionService.validString(j.wsPath, 64 * 1024)
        || !SubscriptionService.validString(j.wsHost, 4096)
        || !SubscriptionService.validString(j.grpcServiceName, 64 * 1024)
        || (j.hyUp !== undefined && !SubscriptionService.validString(j.hyUp, 256))
        || (j.hyDown !== undefined && !SubscriptionService.validString(j.hyDown, 256))
        || (j.alpnList !== undefined && !SubscriptionService.validString(j.alpnList, 256))
        || (j.extraOpts !== undefined && !SubscriptionService.validString(j.extraOpts, 64 * 1024))
        || (j.rawTemplate !== undefined && !SubscriptionService.validString(j.rawTemplate, 64 * 1024))
        || !SubscriptionService.validString(j.rawYaml, 128 * 1024)
        || !SubscriptionService.validString(j.rawUri, 128 * 1024)
        || (j.originalName !== undefined && !SubscriptionService.validString(j.originalName, 4096))) {
        skipped++;
        continue;
      }
      const n = new ProxyNode();
      n.id = j.id;
      n.subscriptionId = j.subscriptionId;
      n.name = j.name;
      // 旧存储没有 originalName 键：用剥掉历史唯一名后缀的显示名回填，
      // 保证升级后代理组成员（引用订阅原始名）仍能匹配到节点。
      n.originalName = j.originalName !== undefined
        ? j.originalName : SubscriptionService.baseName(j.name);
      n.server = j.server;
      n.port = j.port;
      n.password = j.password;
      n.method = j.method;
      n.protocol = j.protocol;
      n.protocolParam = j.protocolParam;
      n.obfs = j.obfs;
      n.obfsParam = j.obfsParam;
      n.type = j.type === 'ss' ? ProxyNodeType.SS : (j.type === 'ssr' ? ProxyNodeType.SSR : ProxyNodeType.UNKNOWN);
      n.proxyType = j.proxyType.length > 0 ? j.proxyType : j.type;
      n.uuid = j.uuid;
      n.alterId = j.alterId;
      n.udp = j.udp;
      n.network = j.network;
      n.tls = j.tls;
      n.servername = j.servername;
      n.skipCertVerify = j.skipCertVerify;
      n.flow = j.flow;
      n.clientFingerprint = j.clientFingerprint;
      n.certFingerprint = j.certFingerprint ?? '';
      n.realityPublicKey = j.realityPublicKey;
      n.realityShortId = j.realityShortId;
      n.wsPath = j.wsPath;
      n.wsHost = j.wsHost;
      n.grpcServiceName = j.grpcServiceName;
      n.hyUp = j.hyUp ?? '';
      n.hyDown = j.hyDown ?? '';
      n.alpnList = j.alpnList ?? '';
      n.extraOpts = j.extraOpts ?? '';
      n.rawTemplate = j.rawTemplate ?? '';
      n.rawYaml = '';
      n.rawUri = j.rawUri;
      out.push(n);
    }
    if (skipped > 0) {
      // 恢复阶段的丢弃必须计数并回报（此前只写日志，界面与诊断都无从得知）
      AppLogger.warn(TAG, `ignored ${skipped} invalid node records (restore stage)`);
      SubscriptionService.noteInvalidBulk(diagnostics, skipped,
        `恢复阶段丢弃 ${skipped} 条无效节点记录`);
    }
    return out;
  }

  /**
   * 持久化元数据 + 凭据。返回「写加密层失败的凭据字段数」（0=全部成功, -1=写入过程异常）,
   * 供导入诊断的 persistFailedCount 使用 —— 凭据没写进去必须让用户看到, 不能静默。
   */
  /** 恢复阶段的代理组校验：坏记录跳过（与 mapNodes 同口径），成员列表逐项过滤 */
  private static mapGroups(json: Object): ProxyGroup[] {
    const out: ProxyGroup[] = [];
    if (!Array.isArray(json)) {
      AppLogger.warn(TAG, 'proxy groups preferences root is not an array');
      return out;
    }
    for (const item of json as Object[]) {
      if (item === null || typeof item !== 'object') {
        continue;
      }
      const j = item as ProxyGroupJson;
      if (!SubscriptionService.validString(j.subscriptionId, 256, false)
        || !SubscriptionService.validString(j.name, 4096, false)
        || !SubscriptionService.validString(j.groupType, 64)
        || !Array.isArray(j.members)) {
        continue;
      }
      const members: string[] = [];
      for (const m of j.members as Object[]) {
        if (typeof m === 'string' && m.length > 0 && m.length <= 4096) {
          members.push(m);
        }
      }
      const g = ProxyGroup.fromJson(j as ProxyGroupJson);
      g.members = members;
      out.push(g);
    }
    return out;
  }

  private async persist(): Promise<number> {
    if (this.store === null) {
      return 0;
    }
    // 凭据先写加密层（订阅 headerValue / 节点 rawUri 一并入 Asset），再落元数据。
    // 报告决定元数据里哪些节点的明文凭据**可以**被安全清空（见 nodesToJson）。
    const report = await this.storeCredentials();
    // 返回给调用方的仍是"凭据未落盘字段数"（>0 即失败，调用方据此写诊断）。
    // 加密层不可用/未初始化时没有任何字段能确认入库，按节点数计，确保非零。
    const credentialFailed = report === null
      ? this.nodes.length
      : report.failed + (report.storeUnavailable ? this.nodes.length : 0);
    const subsJson: SubscriptionJson[] = [];
    for (const s of this.subscriptions) {
      subsJson.push(Subscription.toJson(s));
    }
    await this.store.put(KEY_SUBS, JSON.stringify(subsJson));
    await this.store.put(KEY_NODES, JSON.stringify(SubscriptionService.nodesToJson(this.nodes, report)));
    await this.store.put(KEY_HIDDEN, JSON.stringify(this.hiddenNodes));
    const groupsJson: ProxyGroupJson[] = [];
    for (const g of this.proxyGroups) {
      groupsJson.push(ProxyGroup.toJson(g));
    }
    await this.store.put(KEY_GROUPS, JSON.stringify(groupsJson));
    await this.store.flush();
    // 订阅集合（含节点/分组）发生任何持久化变更 → 推进 revision。
    // 节点页用它决定「是否要重新自动测速」：revision 变了说明订阅被导入/刷新/增删，
    // 此时旧延迟大概率失效，值得再测一轮；revision 没变就不再重复测。
    // 放在唯一 persist 收口点，避免逐个入口（导入/刷新/删订阅/加本地 yaml…）漏改。
    AppStorage.setOrCreate('subscription_revision',
      (AppStorage.get<number>('subscription_revision') ?? 0) + 1);
    // 节点集变化通知（2026-10-20 整改）：订阅导入/刷新/增删之后，内核里已生成的
    // 配置与当前节点集脱节（配置只在启动那一刻生成一次）。通知编排器作废测速核
    // 并按新节点集重建 —— 否则新节点在核心里查不到，测速整屏显示「未生效」。
    const fingerprint: string = SubscriptionService.nodeSetFingerprint(this.nodes);
    if (fingerprint !== this.lastNotifiedNodeFingerprint) {
      this.lastNotifiedNodeFingerprint = fingerprint;
      SubscriptionService.notifyNodeSetChanged('subscription set changed');
    }
    return credentialFailed;
  }

  /**
   * 敏感凭据落盘（透明写入路径）：节点凭据写 AssetStore；
   * 订阅 headerValue 同样入加密层。**绝不把凭据写入普通 Preferences**。
   * 返回迁移报告（null = 加密层不可用/写出异常）；调用方据此决定是否清明文。
   */
  private async storeCredentials(): Promise<CredentialMigrationReport | null> {
    if (this.credStore === null) {
      // 凭据偏好未初始化：本进程无法确认任何凭据已入库 → 必须按"未验证"处理，
      // 既不写明文也不清明文（上层用 credentialMissingCount 如实提示）。
      AppLogger.warn(TAG, 'credential preferences unavailable: credentials not persisted this round');
      return null;
    }
    let report: CredentialMigrationReport;
    try {
      report = await CredentialStore.canonicalize(this.nodes, this.subscriptionCredentialSources(), false);
      if (report.storeUnavailable) {
        // 加密层整体不可用：绝不写明文, 但凭据确实没有落盘, 上层必须据此提示用户
        AppLogger.warn(TAG,
          'credential store unavailable: credentials not persisted; plaintext retained so connection keeps working');
      }
    } catch (e) {
      AppLogger.warn(TAG, `credential store write aborted: ${AppLogger.errText(e)}`);
      return null;
    }
    // 会话级别名标记持久化（仅别名、不含值）：批量查询不可用的固件重启后，
    // 靠这份标记逐条从 AssetStore 回填凭据 —— 值绝不落 preferences。
    await this.credStore.put(KEY_ALIAS_CACHE, CredentialStore.exportAliasCache());
    await this.credStore.flush();
    return report;
  }

  private subscriptionCredentialSources(): SubscriptionCredentialSource[] {
    const out: SubscriptionCredentialSource[] = [];
    for (const s of this.subscriptions) {
      if (s.headerValue.length === 0) {
        continue;
      }
      const src = new SubscriptionCredentialSource();
      src.id = s.id;
      src.headerValue = s.headerValue;
      out.push(src);
    }
    return out;
  }

  /**
   * 普通 Preferences 持久化专用的（近乎）无凭据 DTO。
   *
   * Preferences 是**明文**存储：任何凭据写进去都等于绕过 AssetStore 加密层。
   * 因此凭据字段默认清空，只由 CredentialStore 持有、加载时经 initNodes 逐字段回填。
   *
   * 但清空必须 fail-closed 的**反面** —— 没验证过入库就绝不能清：加密层不可用
   * （probe 失败）或该字段回读不一致时，Preferences 里那份明文是用户唯一可用的
   * 副本。此时保留该字段明文，并由 credentialMissingCount 与诊断面板如实告知，
   * 而不是让"保存成功"变成一次静默的数据丢失。
   *
   * 按**字段**而非整节点判定：每个字段在 initNodes 里各自独立回填，没有跨字段
   * 依赖，所以只清已验证的那些能把明文暴露面压到最小且不丢任何数据。
   *
   * 与 CredentialStore.NODE_CRED_FIELDS 对齐（含 extraOpts 与 rawUri：两者都可能
   * 内嵌 obfs-password / 完整节点链接，不能按字段名猜测是否敏感）。
   * rawTemplate 例外：YamlMerger.buildRawTemplate 在构造期就剔除了全部凭据键，
   * 它是生成端逐字回写所依赖的非敏感模板，必须持久化。
   */
  private static nodesToJson(nodes: ProxyNode[], report: CredentialMigrationReport | null): ProxyNodeJson[] {
    const out: ProxyNodeJson[] = [];
    for (const n of nodes) {
      const j = ProxyNodeJson.fromNode(n);
      const id = nodeCredentialId(n);
      // 只有确认入库（回读一致）的字段才允许清空；未验证的一律保留明文
      const clearable = (field: string, value: string): boolean => {
        return report !== null && !report.storeUnavailable
          && value.length > 0 && report.fieldStored(id, field);
      };
      if (clearable('password', j.password)) { j.password = ''; }
      if (clearable('uuid', j.uuid)) { j.uuid = ''; }
      if (clearable('protocolParam', j.protocolParam)) { j.protocolParam = ''; }
      if (clearable('obfsParam', j.obfsParam)) { j.obfsParam = ''; }
      if (clearable('extraOpts', j.extraOpts ?? '')) { j.extraOpts = ''; }
      if (clearable('rawUri', j.rawUri)) { j.rawUri = ''; }
      out.push(j);
    }
    return out;
  }

  /**
   * 只认 Clash 配置：判定依据是**内容**（顶层 proxies / proxy-providers / proxy-groups），
   * 不是链接。JSON / CONF / base64 节点串 / 纯链接列表一律判为非 Clash。
   * 与 BodyDispatch 共用同一套分类，避免"这里说是 YAML、那里又当链接"两套口径。
   */
  static isClashBody(body: string): boolean {
    if (body.length === 0) {
      return false;
    }
    return BodyDispatch.classify(body).kind === BodyKind.YAML;
  }

  /** 非 Clash 订阅的统一用户文案（刷新、文件导入、扫码共用，避免三处话术不一致） */
  static readonly NON_CLASH_ADVICE: string =
    '该订阅返回的不是 Clash 配置（可能是 base64 节点串 / JSON / 明文链接列表）。'
      + '请向机场索取 Clash 订阅链接后，点「编辑」替换地址；现有节点仍可正常使用，不会丢失。';

  async addSubscription(name: string, url: string, headerName: string, headerValue: string): Promise<Subscription> {
    const s = Subscription.newSubscription(util.generateRandomUUID(), name, url);
    s.headerName = headerName;
    s.headerValue = headerValue;
    s.sortOrder = this.subscriptions.length;
    this.subscriptions.push(s);
    await this.persist();
    // FlClash 同构：第一个订阅成为当前 Profile（同一时刻只有一份配置生效）
    if (ProfileRepository.currentId().length === 0) {
      await ProfileRepository.setCurrent(s.id);
    }
    AppLogger.info(TAG, `subscription added: ${s.name}`);
    return s;
  }

  async removeSubscription(id: string): Promise<void> {
    if (id === DIRECT_GROUP_ID) {
      return;
    }
    const t0 = Date.now();
    // 双轨：删除订阅前先取出落盘原文（撤销窗口内可回写），随后立即删文件
    const rawBody = RawSubscriptionStore.readRaw(id);
    // 事务化快照以支持撤销
    this.undoSnapshot = new SubscriptionUndoSnapshot(this.subscriptions.slice(), this.nodes.slice(),
      id, rawBody, this.proxyGroups.filter((g) => g.subscriptionId === id));
    this.subscriptions = this.subscriptions.filter((s) => s.id !== id);
    this.nodes = this.nodes.filter((n) => n.subscriptionId !== id);
    this.proxyGroups = this.proxyGroups.filter((g) => g.subscriptionId !== id);
    // 「不再需要即删干净」：删订阅即删其 provider 落盘原文与登记项
    RawSubscriptionStore.remove(id);
    RawBodyCache.drop(id);
    ProfileRepository.remove(id);
    if (ProfileRepository.currentId() === id) {
      const next = this.subscriptions.find((x) => x.enabled);
      await ProfileRepository.setCurrent(next !== undefined ? next.id : '');
    }
    await this.persist();
    // 分阶段计时（真机排查用）：删除慢时据此区分"落盘"与"其余"
    AppLogger.info(TAG, `[perf] subscription removed at +${Date.now() - t0}ms`);
  }

  async undoRemove(): Promise<boolean> {
    if (this.undoSnapshot === null) {
      return false;
    }
    const snapshot = this.undoSnapshot;
    this.subscriptions = this.undoSnapshot.subs;
    this.nodes = this.undoSnapshot.nodes;
    this.proxyGroups = this.proxyGroups.filter((g) => g.subscriptionId !== snapshot.rawSubscriptionId)
      .concat(snapshot.proxyGroups);
    this.undoSnapshot = null;
    // FlClash 同构：撤销删除时把 profile 文件一起写回（否则「恢复」后没有可运行配置）
    if (snapshot.rawSubscriptionId.length > 0 && snapshot.rawBody.length > 0) {
      await ProfileRepository.validateAndStore(snapshot.rawSubscriptionId, snapshot.rawBody);
      if (ProfileRepository.currentId().length === 0) {
        await ProfileRepository.setCurrent(snapshot.rawSubscriptionId);
      }
    }
    if (snapshot.rawSubscriptionId.length > 0 && snapshot.rawBody.length > 0
      && RawSubscriptionStore.enabled) {
      const restored = RawSubscriptionStore.writeRaw(snapshot.rawSubscriptionId, snapshot.rawBody);
      const sub = this.subscriptions.find((s) => s.id === snapshot.rawSubscriptionId);
      if (sub !== undefined) {
        if (restored.ok) {
          const estimate = SubscriptionService.countRawEntries(sub.id);
          sub.rawProviderState = RawProviderStates.READY;
          sub.rawProviderNodeEstimate = estimate;
          this.registerRawProvider(sub.id, estimate);
        } else {
          sub.rawProviderState = RawProviderStates.FAILED;
          sub.rawProviderNodeEstimate = 0;
          AppLogger.warn(TAG, `raw provider restore failed after undo: ${restored.reason}`);
        }
      }
    }
    await this.persist();
    return true;
  }

  /**
   * 并发阶段（纯网络 I/O）：只做单条订阅的拉取，结果暂存到 prefetchCache。
   * **不改任何共享状态**（不碰 this.nodes / 订阅统计 / preferences / YamlMerger 静态状态），
   * 所以多条订阅同时预取不会互相覆盖。失败（含 429/403）也存进缓存，交给串行阶段复用
   * **同一条**错误 —— 不重试、不对同一面板再打一次请求（限流风暴的主要来源）。
   */
  async prefetchSubscription(id: string): Promise<RefreshPrepOutcome> {
    const sub = this.subscriptions.find((s) => s.id === id);
    if (sub === undefined) {
      return RefreshPrepOutcome.skipped(id);
    }
    if (sub.url.startsWith('local://')) {
      // 本地 YAML 伪订阅没有网络源：串行阶段按既有语义以现有节点数报成功，这里不预取
      return RefreshPrepOutcome.skipped(id);
    }
    if (!SubscriptionFetchPolicy.isValidSubscriptionUrl(sub.url,
      await SubscriptionService.insecureSubscriptionHttpAllowed())) {
      // 地址非法交给串行阶段按原样报错（提示文案与单条刷新逐字一致），这里不预取
      return RefreshPrepOutcome.skipped(id);
    }
    try {
      // 明文 http 是否放行先取好再进实参：设置读取塞进实参既难读，
      // 也会被静态检查的调用点参数扫描误判（嵌套括号会截断参数列表）。
      const insecureAllowed: boolean = await SubscriptionService.insecureSubscriptionHttpAllowed();
      const fetched = await SubscriptionFetchPolicy.fetch(sub.url, sub.headerName, sub.headerValue,
        insecureAllowed, sub.etag);
      this.prefetchCache.set(id,
        PrefetchedSubscription.body(sub.url, sub.headerName, sub.headerValue, fetched));
      return RefreshPrepOutcome.prefetched(id);
    } catch (e) {
      if (e instanceof SubscriptionFetchError) {
        this.prefetchCache.set(id,
          PrefetchedSubscription.failure(sub.url, sub.headerName, sub.headerValue, e));
        AppLogger.warn(TAG, `prefetch ${id} failed: ${e.message}`);
        return RefreshPrepOutcome.failed(id, e.message, e.isRateLimited());
      }
      const message = SubscriptionService.describeError(e);
      AppLogger.warn(TAG, `prefetch ${id} failed: ${message}`);
      return RefreshPrepOutcome.unexpected(id, message);
    }
  }

  /**
   * 取走某条订阅的预取结果（取走即删）。
   * 只有 url / 自定义 UA 与当前订阅完全一致、且未过期才复用：
   * 批次中断后残留的旧内容宁可丢掉重拉，也绝不能写错数据。
   */
  private takePrefetch(sub: Subscription): PrefetchedSubscription {
    const miss = new PrefetchedSubscription();
    if (!this.prefetchCache.has(sub.id)) {
      return miss;
    }
    const cached = this.prefetchCache.get(sub.id) as PrefetchedSubscription;
    this.prefetchCache.delete(sub.id);
    if (cached.url !== sub.url || cached.headerName !== sub.headerName) {
      return miss;
    }
    if (cached.headerValue !== sub.headerValue) {
      return miss;
    }
    if (Date.now() - cached.at > PREFETCH_TTL_MS) {
      return miss;
    }
    return cached;
  }

  /**
   * 「全部刷新」（订阅页 refreshAll / 节点页 refreshNodes 共用）：有上限的并发批次。
   * 网络拉取并发（<= lanes 路，默认 ConcurrentRefresh.DEFAULT_LANES=4），
   * 解析 → 改内存 → 落盘 由 ConcurrentRefresh 串行保证：不丢节点、不丢订阅统计、
   * 不互相覆盖、单条失败不影响其它条。onProgress 每条完成后回调一次（串行、顺序确定），
   * 页面据此边到边刷 UI；shouldStop 返回 true 时不再启动新条目（在途条目仍会走完并落盘）。
   */
  async refreshSubscriptionsConcurrently(ids: string[], lanes: number,
    onProgress: (progress: RefreshBatchProgress, item: RefreshItemOutcome) => void,
    shouldStop: () => boolean): Promise<RefreshBatchSummary> {
    // 批次开始先清空可能残留的预取：上一次中断的批次不得影响这一次
    this.prefetchCache.clear();
    try {
      return await ConcurrentRefresh.run(ids, lanes,
        (id: string): Promise<RefreshPrepOutcome> => this.prefetchSubscription(id),
        (id: string): Promise<RefreshItemOutcome> => this.applyRefreshedSubscription(id),
        onProgress, shouldStop);
    } finally {
      // 批次结束不留任何 body / 错误残片（并发期的额外内存峰值 = lanes 份响应体）
      this.prefetchCache.clear();
    }
  }

  /** 串行阶段：走既有的 refreshSubscription（解析/合并/限流/诊断/落盘语义零改动） */
  private async applyRefreshedSubscription(id: string): Promise<RefreshItemOutcome> {
    const result = await this.refreshSubscription(id);
    const ok = result.status === SubscriptionRefreshStatus.OK
      || result.status === SubscriptionRefreshStatus.NOT_MODIFIED;
    if (ok) {
      return RefreshItemOutcome.success(id, result.nodeCount);
    }
    return RefreshItemOutcome.failure(id, result.message.length > 0 ? result.message : `${result.status}`,
      result.status === SubscriptionRefreshStatus.RATE_LIMITED, result.advice);
  }

  /**
   * 进程级刷新写链（2026-10-24 P1 修复）。
   *
   * ConcurrentRefresh 只保证**批内** apply 串行；`refreshSubscription` 公开可直调
   * （页面单条刷新、启动 2.5s 补拉 backfillRawBodies），与并发批次/其它单条刷新
   * 的落地交错会造成：nodes 读-改-写互相覆盖、整表 persist 后写盖先写、
   * lastImportDiagnostics 张冠李戴。这里把「落地写路径」统一挂到同一条链上，
   * 与批次 apply（内部同样走 refreshSubscription 的落地段）天然互斥。
   * 锁只包写路径；网络 fetch/provider 拉取仍在锁外，并发拉取能力不变。
   */
  private refreshWriteChain: Promise<void> = Promise.resolve();

  private runRefreshExclusive<T>(task: () => Promise<T>): Promise<T> {
    const mine: Promise<T> = this.refreshWriteChain.then(task);
    // 链上异常必须吞掉：否则一次失败断链，后续所有刷新永远排队等一个 rejected promise
    this.refreshWriteChain = mine.then((): void => {
    }, (): void => {
    });
    return mine;
  }

  async refreshSubscription(id: string): Promise<SubscriptionRefreshResult> {
    const sub = this.subscriptions.find((s) => s.id === id);
    if (sub === undefined) {
      return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.HTTP_ERROR, 'subscription not found');
    }
    // 三入口统一诊断：本次刷新的所有计数（输入/成功/重复/无效/不支持/超限/持久化失败/配置丢弃）
    const diagnostics = new SubscriptionImportDiagnostics();
    this.lastImportDiagnostics = diagnostics;
    // 本地 YAML 导入的伪订阅: 刷新 = 从落盘原文重解析 + 重拉 providers（provider
    // 内容可能已更新，或上次导入时拉取失败——刷新就是重试入口），不是空转报成功。
    if (sub.url.startsWith('local://')) {
      return await this.refreshLocalSubscription(sub, diagnostics);
    }
    try {
      // 并发批次（refreshSubscriptionsConcurrently）已在网络阶段拉过这条订阅时直接复用：
      // 不重复打同一面板（429 风险），失败也复用**同一条**错误 → 状态分类 / 订阅状态落盘 /
      // 诊断与串行路径完全一致（下面统一 catch 里走 RATE_LIMITED 等既有分支）。
      const prefetched = this.takePrefetch(sub);
      if (prefetched.hit && prefetched.hasError) {
        throw prefetched.error;
      }
      const insecureAllowed: boolean = await SubscriptionService.insecureSubscriptionHttpAllowed();
      const fetched: SubscriptionFetchResult = prefetched.hit
        ? prefetched.fetched
        : await SubscriptionFetchPolicy.fetch(sub.url, sub.headerName, sub.headerValue,
          insecureAllowed, sub.etag);
      // 304：面板确认内容未变。直接按「未变更」返回，沿用已落盘节点，
      // **不重新解析**（没有响应体可解析），也绝不把空体会当成 EMPTY_RESPONSE 报错。
      if (fetched.notModified) {
        sub.lastFetchedAt = Date.now();
        if (fetched.etag.length > 0) {
          sub.etag = fetched.etag;
        }
        sub.lastRefreshResult = SubscriptionRefreshStatus.NOT_MODIFIED;
        try {
          await this.persist();
        } catch (persistError) {
          return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PERSIST_ERROR,
            `刷新成功但状态持久化失败：${SubscriptionService.describeError(persistError)}`, diagnostics);
        }
        AppLogger.info(TAG, `subscription ${id} not modified (304)`);
        // 配额提醒（fire-and-forget）：304 时 userinfo 沿用既有值，也值得复查阈值
        SubscriptionQuotaService.run(this.subscriptions)
          .catch((quotaError: Object): void => {
            AppLogger.warn(TAG, `quota check failed: ${String(quotaError)}`);
          });
        return SubscriptionRefreshResult.ok(sub.nodeCount, diagnostics);
      }
      const body = fetched.body;
      // ── 只支持 Clash 订阅（2026-10-21）────────────────────────────
      // 判内容不判链接：非 Clash ⇒ 保留已存节点、打旧格式标记、停自动更新、给可执行提示。
      // 原文落盘 + 进进程内缓存：生成运行配置时原样透传。
      // 与 FlClash/Verge/CMFA 同形——订阅原文作为 profile 文件存在私有目录，
      // 内核/生成器直接吃原文，App 不重写节点定义。
      // ── FlClash 同构（2026-10-22）：原文落成 profile 文件 ───────────────
      // FlClash `CoreController.validateProfile`：Clash YAML 原样通过；不是 YAML
      // 时用 convertProxies（base64 / URI 列表）转成 proxies 列表再通过；两者都失败才拒。
      // 这里必须**先**判定，不能再用旧的 isClashBody 一刀切 —— 否则 base64 订阅会被
      // 误判成「非 Clash」而 FlClash 是能导入的。
      const profileValidation = await ProfileRepository.validateAndStore(sub.id, body);
      // 首个成功落盘的订阅立刻成为当前 Profile（FlClash putProfile 语义），
      // 必须在**生成配置之前**定下来，否则本次刷新生成的仍是旧的全量配置。
      if (profileValidation.ok) {
        const currentNow = ProfileRepository.currentId();
        if (currentNow.length === 0 || !ProfileRepository.exists(currentNow)) {
          await ProfileRepository.setCurrent(sub.id);
          AppLogger.info(TAG, `current profile initialized: ${sub.id}`);
        }
      }
      if (!profileValidation.ok) {
        RawBodyCache.drop(sub.id);
        sub.lastRefreshResult = SubscriptionRefreshStatus.PARSE_ERROR;
        await this.persist();
        AppLogger.warn(TAG, `subscription profile rejected: ${SubscriptionFetchPolicy.redactUrl(sub.url)} `
          + `reason=${profileValidation.message}`);
        // 把**真实原因**带给用户（不要统一说成「请开启代理」）：
        // 面板返回 4 字节、返回 JSON、返回 base64 都会走到这里，三者处理方式不同。
        const bodyLen = body.trim().length;
        // 真机实证：部分机场的链接在无效/过期时返回一个换行
        // （HTTP body = `Cg==` → 4 字节 base64，trim 后 0 字节）。这不是网络问题，
        // 也不是 UA 问题 —— 必须让用户看到「空内容」，而不是「请开启代理」。
        const reason = bodyLen < 16
          ? `订阅地址返回空内容（${bodyLen} 字节）：请重新从机场面板复制 Clash 订阅链接`
          : profileValidation.message;
        const rejected = SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PARSE_ERROR, reason);
        rejected.advice = SubscriptionService.NON_CLASH_ADVICE;
        return rejected;
      }
      const rawWrite = RawSubscriptionStore.writeRaw(sub.id, body);
      if (!rawWrite.ok) {
        AppLogger.warn(TAG, `raw profile write failed: ${rawWrite.reason}`);
      }
      RawBodyCache.put(sub.id, body);
      sub.legacyFormat = false;
      // 记住 ETag 供下次条件请求（服务端没给就保持空串 = 下次完整拉取）
      if (fetched.etag.length > 0) {
        sub.etag = fetched.etag;
      }
      sub.uploadBytes = fetched.userInfo.uploadBytes;
      sub.downloadBytes = fetched.userInfo.downloadBytes;
      sub.totalBytes = fetched.userInfo.totalBytes;
      sub.expireAt = fetched.userInfo.expireAt;

      // 自动命名（FlClash 同构，2026-10-22）：订阅仍是默认名时，先用服务端
      // `Content-Disposition` 里的文件名（FlClash `lib/models/profile.dart:186-198`
      // 就是拿它当标题），拿不到再从正文提取机场名（本端增强）。
      if (SubscriptionService.isDefaultName(sub.name)) {
        const fromHeader = SubscriptionFetchPolicy.fileNameFromDisposition(fetched.disposition);
        if (fromHeader.length > 0) {
          sub.name = fromHeader;
          AppLogger.info(TAG, `subscription named from content-disposition: "${fromHeader}"`);
        } else {
          const detected = SubscriptionService.detectProviderName(body);
          if (detected.length > 0) {
            sub.name = detected;
            AppLogger.info(TAG, `auto-named subscription to "${detected}"`);
          }
        }
      }

      let parsed: ProxyNode[];
      let parsedGroups: ProxyGroup[] = [];
      YamlMerger.resetSkipStats();
      // 该订阅的不可用台账先清空（重新导入 ⇒ 台账反映最新一次结果）
      UnusableLedger.clearFor(sub.id);
      // 先解码再判是不是 YAML 文档（base64 包裹的 Clash YAML 不能掉进链接分支）
      const dispatch = BodyDispatch.classify(body);
      const structuredYaml = dispatch.kind === BodyKind.YAML;
      if (structuredYaml) {
        // Clash YAML 订阅：走合并引擎（跨刷新保留节点名称，限额与去重对齐 upstream）
        const prev = this.store !== null ? await this.store.get(`yaml_cache_${id}`, '') as string : '';
        let merged: MergedProxy[] = [];
        try {
          merged = YamlMerger.merge([dispatch.body], sub.name, prev);
        } catch (mergeError) {
          if (mergeError instanceof YamlMergeError) {
            // 合并引擎限额（10k 节点 / 1000 来源 / 字段长度 / 单条大小）属「超限」，
            // 不能笼统报成解析失败：用户看到的应是「超限」而不是「内容坏了」。
            diagnostics.limitCount = diagnostics.limitCount + 1;
            SubscriptionService.appendInvalidReason(diagnostics, `合并超限：${mergeError.message}`);
            sub.lastRefreshResult = SubscriptionRefreshStatus.LIMIT_EXCEEDED;
            try {
              await this.persist();
            } catch (persistError) {
              return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PERSIST_ERROR,
                `节点超限状态保存失败：${SubscriptionService.describeError(persistError)}`, diagnostics);
            }
            return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.LIMIT_EXCEEDED,
              `订阅内容超出合并限额：${mergeError.message}`, diagnostics);
          }
          throw mergeError as Error;
        }
        // 合并阶段被跳过的节点（不支持的协议类型）与逐条失败的原因并入同一次诊断
        SubscriptionService.absorbYamlMergeStats(diagnostics);
        parsed = SubscriptionService.mergedToNodes(merged, sub.id, diagnostics, dispatch.body);
        parsedGroups = SubscriptionParser.parseProxyGroups(dispatch.body, sub.id);
        // 订阅自带 rules/rule-providers 段落账（无规则段时清空旧值）
        SubscriptionService.applyRulesSections(sub, dispatch.body);
        // 订阅自带 dns 上游（proxy-server-nameserver / nameserver-policy）落账
        SubscriptionService.applyDnsSections(sub, dispatch.body);
        diagnostics.inputCount = diagnostics.inputCount + parsed.length + diagnostics.invalidCount
          + diagnostics.unsupportedCount;
        if (this.store !== null) {
          // 缓存只保存白名单结构化节点的安全 YAML，禁止缓存或回放订阅原文。
          await this.store.put(`yaml_cache_${id}`, YamlMerger.toYaml(merged));
        }
      } else {
        const parseResult = SubscriptionParser.parseDetailed(body, sub.id);
        parsed = parseResult.nodes;
        parsedGroups = parseResult.groups;
        diagnostics.inputCount = diagnostics.inputCount + parseResult.diagnostics.inputCount;
        diagnostics.duplicateCount = diagnostics.duplicateCount + parseResult.diagnostics.duplicateCount;
        if (parseResult.diagnostics.invalidCount > 0) {
          SubscriptionService.noteInvalidBulk(diagnostics, parseResult.diagnostics.invalidCount,
            `无效链接 ${parseResult.diagnostics.invalidCount} 条`);
        }
        diagnostics.unsupportedCount = diagnostics.unsupportedCount + parseResult.diagnostics.unsupportedCount;
        diagnostics.unsupportedTypes = SubscriptionService.mergeTypes(diagnostics.unsupportedTypes,
          parseResult.diagnostics.unsupportedTypes);
      }
      if (YamlMerger.lastSkippedCount > 0) {
        // 不再静默丢弃: 记录被跳过的节点数与协议类型, 供诊断与界面提示
        AppLogger.warn(TAG, `subscription ${id} skipped ${YamlMerger.lastSkippedCount} node(s) `
          + `of unsupported type(s): ${YamlMerger.lastSkippedTypes}`);
      }
      if (YamlMerger.lastDuplicateKeyCount > 0) {
        // 【C15】flow-map 节点里含重复键（同一 map 内同名字段）——mihomo 的
        // yaml.v3 uniqueKeys 默认开启, 重复键会让**整份配置**拒载, 所以解析层
        // 按「首次出现」保留并去重。这是**降级**不是丢弃(节点仍然可用),
        // 因此不计入 invalidCount, 只记日志 + 保留 YamlMerger 的静态统计。
        AppLogger.warn(TAG, `subscription ${id} ${YamlMerger.lastDuplicateKeyCount} node(s) had `
          + `duplicate keys (kept the first): ${YamlMerger.lastDuplicateKeyReasons.join('; ')}`);
      }

      // ---- proxy-providers：节点放在 provider 段而 proxies 为空的配置也必须导入 ----
      const providerEntries = ProxyProviderParser.parse(body);
      let providerImported = 0;
      if (providerEntries.length > 0) {
        const fetchable = ProxyProviderParser.fetchable(providerEntries);
        diagnostics.providerSkippedCount = providerEntries.length - fetchable.length;
        diagnostics.providerTypes = ProxyProviderParser.unsupportedTypes(providerEntries);
        if (diagnostics.providerSkippedCount > 0) {
          AppLogger.warn(TAG, `subscription ${id} has ${diagnostics.providerSkippedCount} proxy-provider(s) `
            + `of unsupported type(s): ${diagnostics.providerTypes}`);
        }
        const missingUrl = ProxyProviderParser.missingUrl(providerEntries);
        if (missingUrl > 0) {
          diagnostics.providerFailedCount = diagnostics.providerFailedCount + missingUrl;
          SubscriptionService.appendProviderFailure(diagnostics, `provider 缺少 url ${missingUrl} 个`);
        }
        for (let pi = 0; pi < fetchable.length; pi++) {
          const entry = fetchable[pi];
          try {
            // 与主订阅完全相同的 UA 降级链 / 重定向校验 / 大小上限
            const providerInsecureAllowed: boolean =
              await SubscriptionService.insecureSubscriptionHttpAllowed();
            const providerFetched = await SubscriptionFetchPolicy.fetch(
              entry.url, sub.headerName, sub.headerValue, providerInsecureAllowed);
            const providerNodes = SubscriptionService.parseProviderBody(providerFetched.body, sub.id,
              entry.name, diagnostics);
            // 节点来源标注为 provider（id 前缀 -p 与主订阅条目区分，避免 id 冲突）
            for (let ni = 0; ni < providerNodes.length; ni++) {
              providerNodes[ni].id = `${sub.id}-p${pi}-${ni}`;
            }
            if (providerNodes.length > 0) {
              parsed = parsed.concat(providerNodes);
              providerImported = providerImported + providerNodes.length;
            }
          } catch (providerError) {
            diagnostics.providerFailedCount = diagnostics.providerFailedCount + 1;
            SubscriptionService.appendProviderFailure(diagnostics,
              `${entry.name.length > 0 ? entry.name : 'provider'}: `
              + `${SubscriptionService.describeError(providerError)}`);
            AppLogger.warn(TAG, `proxy-provider fetch/parse failed: `
              + `${SubscriptionService.describeError(providerError)}`);
          }
        }
        diagnostics.providerCount = providerImported;
        diagnostics.inputCount = diagnostics.inputCount + providerImported;
      }

      // ── 订阅信息条目统一过滤（2026-10-24）────────────────────────────
      // YAML 原文/provider 里的「剩余流量：xxx GB」类条目字段完整、会进内核代理表但
      // 永远拨不通，还可能被选为连接目标（真机取证：connected to node 剩余流量：
      // 596.2 GB）。URI 路径已在 UriNodeParser 拦截；此处统一覆盖 YAML 与 provider
      // 引入的全部节点（parseClashYaml 源头过滤覆盖导入路径，此处覆盖刷新路径）。
      if (parsed.length > 0) {
        let infoDropped = 0;
        const kept: ProxyNode[] = [];
        for (const n of parsed) {
          if (NodeUsability.isInfoEntry(n.name)) {
            infoDropped = infoDropped + 1;
            const infoRecord = new UnusableRecord();
            infoRecord.subscriptionId = n.subscriptionId;
            infoRecord.source = 'yaml';
            infoRecord.protocol = n.proxyType;
            infoRecord.name = n.name;
            infoRecord.server = n.server;
            infoRecord.port = n.port;
            infoRecord.category = UnusableCategory.INFO;
            infoRecord.excluded = true;
            infoRecord.reason = NodeUsability.infoReason(n.name);
            infoRecord.detail = '订阅信息条目，非节点（刷新统一过滤）：不进代理表、不参与测速。';
            UnusableLedger.record(infoRecord);
            continue;
          }
          kept.push(n);
        }
        if (infoDropped > 0) {
          AppLogger.info(TAG, `subscription ${id}: dropped ${infoDropped} info-entry node(s)`);
          parsed = kept;
        }
      }

      // ── 进程级刷新写锁：以下写路径（状态落盘/节点 concat/整表 persist/current
      // 指针）与并发批次 apply、其它单条刷新互斥。内段保持原缩进（闭包仅作互斥包裹）。
      return await this.runRefreshExclusive(async (): Promise<SubscriptionRefreshResult> => {
      // 【P0 修复】刷新期间订阅可能已被用户删除（网络拉取+解析横跨多个 await）。
      // removeSubscription 已清理该订阅的节点/组/profile/raw 文件；这里若继续落地，
      // nodes concat 会把已删节点复活、writeRawProvider 重建 raw 文件、
      // ProfileRepository.setCurrent 把 current 指回已删 id —— 存储与内存永久分叉。
      if (!this.subscriptions.some((s) => s.id === id)) {
        AppLogger.info(TAG, `subscription ${id} removed during refresh; results dropped`);
        // 刷新中途 validateAndStore/writeRawProvider 可能已重建 removeSubscription
        // 删掉的文件：按同一套清理幂等收尾（RawBodyCache/ProfileRepository 均可安全重复调用）。
        RawSubscriptionStore.remove(id);
        RawBodyCache.drop(id);
        ProfileRepository.remove(id);
        return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PARSE_ERROR,
          '订阅已在刷新期间删除，本次结果已丢弃', diagnostics);
      }
      // FlClash 同构：profile 已落盘 ⇒ 节点由内核解析，App 侧解析出 0 条不是失败。
      // （典型：订阅只有 proxy-providers 段，或含 App 解析器不认识的协议。）
      const profileReady = ProfileRepository.exists(sub.id);
      if (parsed.length === 0 && !profileReady) {
        // HTTP 200 但 0 条目：与「响应为空」「内容无法识别」区分，且给出 provider 专用提示
        sub.lastRefreshResult = SubscriptionRefreshStatus.EMPTY_ENTRIES;
        let message = '内容未解析出节点（支持 ss/ssr/vless/vmess/trojan/hysteria2/tuic/hysteria '
          + '与 Clash YAML）';
        if (providerEntries.length > 0 && !structuredYaml) {
          message = providerImported > 0
            ? '配置未包含 proxies 节点，节点来自 proxy-providers'
            : '配置只有 proxy-providers 段且未导入任何节点（请检查 provider 类型 http/https 与链接可用性）';
        }
        try {
          await this.persist();
        } catch (persistError) {
          return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PERSIST_ERROR,
            `解析失败状态保存失败：${SubscriptionService.describeError(persistError)}`, diagnostics);
        }
        return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.EMPTY_ENTRIES, message, diagnostics);
      }
      if (!SubscriptionFetchPolicy.isNodeCountAllowed(parsed.length)) {
        sub.lastRefreshResult = SubscriptionRefreshStatus.LIMIT_EXCEEDED;
        diagnostics.limitCount = diagnostics.limitCount + 1;
        SubscriptionService.appendInvalidReason(diagnostics, `节点数量 ${parsed.length} 超过 2000 上限`);
        try {
          await this.persist();
        } catch (persistError) {
          return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PERSIST_ERROR,
            `节点超限状态保存失败：${SubscriptionService.describeError(persistError)}`, diagnostics);
        }
        return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.LIMIT_EXCEEDED,
          `节点数量 ${parsed.length} 超过 2000 个上限，未写入任何节点`, diagnostics);
      }
      // 用户手动删除过的节点: 刷新后不再复活
      if (this.hiddenNodes.length > 0) {
        const visible = parsed.filter((n) => !this.hiddenNodes.includes(SubscriptionService.nodeKey(n)));
        diagnostics.hiddenCount = parsed.length - visible.length;
        parsed = visible;
      }
      // 动态分组物化（include-all/filter/exclude-filter → members），再整体替换该订阅的组
      SubscriptionParser.materializeDynamicGroups(parsedGroups, parsed);
      this.proxyGroups = this.proxyGroups.filter((g) => g.subscriptionId !== id).concat(parsedGroups);
      // 过渡期：profile 已落盘但 App 侧解析为 0 时**保留旧节点**（不清空 UI），
      // 节点真源由内核 /proxies 提供（CoreCatalog）。待 UI 全面切到内核后删除此分支。
      if (parsed.length > 0 || !profileReady) {
        const oldSubNodes = this.nodes.filter((n) => n.subscriptionId === id);
        this.nodes = this.nodes.filter((n) => n.subscriptionId !== id).concat(parsed);
        await this.reanchorPreferredAfterReplace(id, oldSubNodes);
      }
      this.ensureUniqueNames();
      // 【2026-10-22 · FlClash 同构】节点数 = **原文 proxies 条目数**（FlClash
      // `configCountsOf(loadYaml(profile))` 的口径），不是 App 解析结果的长度：
      // App 解析不了的协议（未支持类型）会被跳过，用它计数会比内核少，而内核照样加载。
      sub.nodeCount = profileValidation.nodeCount > 0 ? profileValidation.nodeCount : parsed.length;
      sub.lastFetchedAt = Date.now();
      sub.lastRefreshResult = SubscriptionRefreshStatus.OK;
      diagnostics.addedCount = parsed.length;
      diagnostics.configMissingCredentialCount = this.credentialMissingCount;
      // ── 双轨：原始原文同步落盘（开关开启时才发生；失败自动降级为仅解析链）──
      this.writeRawProvider(sub, body, structuredYaml, diagnostics);
      this.updateRawProviderSummary(diagnostics);
      let credentialFailed = 0;
      try {
        credentialFailed = await this.persist();
      } catch (persistError) {
        sub.lastRefreshResult = SubscriptionRefreshStatus.PERSIST_ERROR;
        return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PERSIST_ERROR,
          `节点持久化失败：${SubscriptionService.describeError(persistError)}`, diagnostics);
      }
      if (credentialFailed > 0) {
        // 凭据写入加密层失败（异常或回读校验不一致）: 重启后这些节点可能缺凭据
        diagnostics.persistFailedCount = credentialFailed;
        AppLogger.warn(TAG, `subscription ${id} refreshed with ${credentialFailed} `
          + 'credential field(s) not persisted');
      }
      this.noteConfigDrops(diagnostics);
      // 配额提醒（fire-and-forget）：userinfo 已随本次刷新更新
      SubscriptionQuotaService.run(this.subscriptions)
        .catch((quotaError: Object): void => {
          AppLogger.warn(TAG, `quota check failed: ${String(quotaError)}`);
        });
      // current profile 失效（被删/写盘失败）时回落到本次刷新成功的订阅
      const currentId = ProfileRepository.currentId();
      if (currentId.length === 0 || !ProfileRepository.exists(currentId)) {
        await ProfileRepository.setCurrent(id);
        AppLogger.info(TAG, `current profile set to ${id}`);
      }
      return SubscriptionRefreshResult.ok(parsed.length, diagnostics);
      }); // ── 刷新写锁结束 ──
    } catch (e) {
      const msg = AppLogger.errText(e);
      let status = SubscriptionRefreshStatus.PARSE_ERROR;
      let advice = '';
      if (e instanceof SubscriptionFetchError) {
        if (e.isRateLimited()) {
          // HTTP 429/403：面板限流/拒绝访问，与「地址写错」的用户提示完全不同
          status = SubscriptionRefreshStatus.RATE_LIMITED;
          advice = '面板限流或拒绝访问，请稍后重试或更换订阅链接。';
        } else if (e.kind === SubscriptionFetchErrorKind.HTTP) {
          status = SubscriptionRefreshStatus.HTTP_ERROR;
        } else if (e.kind === SubscriptionFetchErrorKind.EMPTY_RESPONSE) {
          status = SubscriptionRefreshStatus.EMPTY_RESPONSE;
          advice = '订阅响应为空，请确认订阅是否已过期或被重置。';
        } else if (e.kind === SubscriptionFetchErrorKind.DECODE) {
          status = SubscriptionRefreshStatus.DECODE_ERROR;
        } else {
          status = SubscriptionRefreshStatus.NETWORK_ERROR;
          // 传输层失败的可读原因 + 下一步（拉取不走代理，被阻断域名必然失败）
          advice = e.advice;
          // P0-2 订阅自救：网络性失败记入待补拉标记，VPN 连接成功后自动重试一次
          this.markNetworkFetchFailure(id);
        }
      }
      sub.lastRefreshResult = status;
      try {
        await this.persist();
      } catch (persistError) {
        return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PERSIST_ERROR,
          `刷新失败且状态持久化失败：${SubscriptionService.describeError(persistError)}`, diagnostics);
      }
      const failure = SubscriptionRefreshResult.fail(status, msg, diagnostics);
      failure.advice = advice;
      return failure;
    }
  }

  /**
   * 导入本地 YAML 文件（订阅页"导入文件"入口）: 建 local:// 伪订阅,
   * 复用与网络订阅完全相同的解析链（Clash YAML proxies / base64 链接列表 /
   * 明文链接行, 含 hysteria2 全协议）。返回导入节点数, 0=解析失败。
   */
  /**
   * 拉取并解析 provider 列表，把节点追加进 parsed（id 前缀 -p 与主条目区分）。
   * 单个 provider 失败只降级计数（静态节点仍在），绝不影响整份导入/刷新。
   * 导入与本地刷新共用；URL 订阅刷新路径保留原内联实现（带订阅级 header）。
   */
  private async appendProviderNodes(providerEntries: ProxyProviderEntry[], subscriptionId: string,
    headerName: string, headerValue: string, parsed: ProxyNode[],
    diagnostics: SubscriptionImportDiagnostics): Promise<number> {
    let providerImported = 0;
    const fetchable = ProxyProviderParser.fetchable(providerEntries);
    diagnostics.providerSkippedCount = diagnostics.providerSkippedCount
      + providerEntries.length - fetchable.length;
    diagnostics.providerTypes = SubscriptionService.mergeTypes(diagnostics.providerTypes,
      ProxyProviderParser.unsupportedTypes(providerEntries));
    const missingUrl = ProxyProviderParser.missingUrl(providerEntries);
    if (missingUrl > 0) {
      diagnostics.providerFailedCount = diagnostics.providerFailedCount + missingUrl;
      SubscriptionService.appendProviderFailure(diagnostics, `provider 缺少 url ${missingUrl} 个`);
    }
    for (let pi = 0; pi < fetchable.length; pi++) {
      const entry = fetchable[pi];
      try {
        const providerInsecureAllowed: boolean =
          await SubscriptionService.insecureSubscriptionHttpAllowed();
        const providerFetched = await SubscriptionFetchPolicy.fetch(entry.url, headerName, headerValue,
          providerInsecureAllowed);
        const providerNodes = SubscriptionService.parseProviderBody(providerFetched.body, subscriptionId,
          entry.name, diagnostics);
        for (let ni = 0; ni < providerNodes.length; ni++) {
          providerNodes[ni].id = `${subscriptionId}-p${pi}-${ni}`;
        }
        for (const pn of providerNodes) {
          parsed.push(pn);
        }
        providerImported = providerImported + providerNodes.length;
      } catch (providerError) {
        diagnostics.providerFailedCount = diagnostics.providerFailedCount + 1;
        SubscriptionService.appendProviderFailure(diagnostics,
          `${entry.name.length > 0 ? entry.name : 'provider'}: `
          + `${SubscriptionService.describeError(providerError)}`);
        AppLogger.warn(TAG, `proxy-provider fetch/parse failed: `
          + `${SubscriptionService.describeError(providerError)}`);
      }
    }
    diagnostics.providerCount = diagnostics.providerCount + providerImported;
    diagnostics.inputCount = diagnostics.inputCount + providerImported;
    return providerImported;
  }

  /**
   * 本地 YAML 伪订阅的刷新：从落盘原文（双轨 raw，缺失时退 yaml_cache）重解析
   * 静态节点与分组，并**重拉 providers** —— 这是 provider 拉取失败后的重试入口，
   * 也让 provider 内容能随刷新更新（对齐 mihomo 的 interval 行为的用户侧等价物）。
   * 原文与缓存都缺失时保持旧行为（按现有节点数报成功，不动任何数据）。
   */
  private async refreshLocalSubscription(sub: Subscription,
    diagnostics: SubscriptionImportDiagnostics): Promise<SubscriptionRefreshResult> {
    const id = sub.id;
    const localCount = this.nodesOf(id).length;
    let body = RawSubscriptionStore.isReady() ? RawSubscriptionStore.readRaw(id) : '';
    if (body.length === 0 && this.store !== null) {
      try {
        body = await this.store.get(`yaml_cache_${id}`, '') as string;
      } catch (e) {
        body = '';
      }
    }
    if (body.trim().length === 0) {
      diagnostics.inputCount = localCount;
      diagnostics.addedCount = localCount;
      diagnostics.configMissingCredentialCount = this.credentialMissingCount;
      return SubscriptionRefreshResult.ok(localCount, diagnostics);
    }
    // 旧格式（JSON / CONF / 链接列表）的文件导入：保留现有节点，不再尝试重解析
    if (!SubscriptionService.isClashBody(body)) {
      // 对齐三家：直接拒，不写任何冻结标记
      const rejected = SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PARSE_ERROR,
        `不是 Clash 配置：${sub.name}`);
      rejected.advice = SubscriptionService.NON_CLASH_ADVICE;
      return rejected;
    }
    try {
      YamlMerger.resetSkipStats();
      let parsed: ProxyNode[];
      let parsedGroups: ProxyGroup[] = [];
      // 该订阅的不可用台账先清空（重新导入 ⇒ 台账反映最新一次结果）
      UnusableLedger.clearFor(id);
      // 先解码再判是不是 YAML 文档（base64 包裹的 Clash YAML 不能掉进链接分支）
      const dispatch = BodyDispatch.classify(body);
      const structuredYaml = dispatch.kind === BodyKind.YAML;
      if (structuredYaml) {
        const merged: MergedProxy[] = YamlMerger.merge([dispatch.body], sub.name, '');        SubscriptionService.absorbYamlMergeStats(diagnostics);
        parsed = SubscriptionService.mergedToNodes(merged, id, diagnostics, dispatch.body);
        parsedGroups = SubscriptionParser.parseProxyGroups(dispatch.body, id);
        // 本地伪订阅刷新：自带 rules/rule-providers 段同样重新落账（原文可能已变化）
        SubscriptionService.applyRulesSections(sub, dispatch.body);
        // dns 上游同理（本地文件可能换了订阅源）
        SubscriptionService.applyDnsSections(sub, dispatch.body);
        diagnostics.inputCount = diagnostics.inputCount + parsed.length
          + diagnostics.invalidCount + diagnostics.unsupportedCount;
      } else {
        const parseResult = SubscriptionParser.parseDetailed(body, id);
        parsed = parseResult.nodes;
        parsedGroups = parseResult.groups;
        diagnostics.inputCount = diagnostics.inputCount + parseResult.diagnostics.inputCount;
        diagnostics.duplicateCount = diagnostics.duplicateCount + parseResult.diagnostics.duplicateCount;
        if (parseResult.diagnostics.invalidCount > 0) {
          SubscriptionService.noteInvalidBulk(diagnostics, parseResult.diagnostics.invalidCount,
            `无效链接 ${parseResult.diagnostics.invalidCount} 条`);
        }
        diagnostics.unsupportedCount = diagnostics.unsupportedCount + parseResult.diagnostics.unsupportedCount;
        diagnostics.unsupportedTypes = SubscriptionService.mergeTypes(diagnostics.unsupportedTypes,
          parseResult.diagnostics.unsupportedTypes);
      }
      const providerEntries = ProxyProviderParser.parse(body);
      if (providerEntries.length > 0) {
        const providerImported = await this.appendProviderNodes(providerEntries, id,
          '', '', parsed, diagnostics);
        AppLogger.info(TAG, `local refresh imported ${providerImported} provider node(s) `
          + `for subscription ${id}`);
      }
      // ── 进程级刷新写锁（与 refreshSubscription 主路径同一把链）：本地伪订阅的
      // 落地同样写 this.nodes / 整表 persist，不得与并发批次/其它单条刷新交错。
      return await this.runRefreshExclusive(async (): Promise<SubscriptionRefreshResult> => {
      if (parsed.length === 0 && !ProfileRepository.exists(id)) {
        sub.lastRefreshResult = SubscriptionRefreshStatus.EMPTY_ENTRIES;
        return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.EMPTY_ENTRIES,
          '重解析未得到节点（原文件内容可能已变化）', diagnostics);
      }
      if (!SubscriptionFetchPolicy.isNodeCountAllowed(parsed.length)) {
        sub.lastRefreshResult = SubscriptionRefreshStatus.LIMIT_EXCEEDED;
        diagnostics.limitCount = diagnostics.limitCount + 1;
        SubscriptionService.appendInvalidReason(diagnostics, `节点数量 ${parsed.length} 超过 2000 上限`);
        return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.LIMIT_EXCEEDED,
          `节点数量 ${parsed.length} 超过 2000 个上限，未写入任何节点`, diagnostics);
      }
      if (this.hiddenNodes.length > 0) {
        parsed = parsed.filter((n) => !this.hiddenNodes.includes(SubscriptionService.nodeKey(n)));
      }
      SubscriptionParser.materializeDynamicGroups(parsedGroups, parsed);
      // 分组仅在有新解析结果时替换（yaml_cache 退路无组信息，不能因此清空既有组）
      if (parsedGroups.length > 0) {
        this.proxyGroups = this.proxyGroups.filter((g) => g.subscriptionId !== id).concat(parsedGroups);
      }
      const oldSubNodesLocal = this.nodes.filter((n) => n.subscriptionId === id);
      this.nodes = this.nodes.filter((n) => n.subscriptionId !== id).concat(parsed);
      await this.reanchorPreferredAfterReplace(id, oldSubNodesLocal);
      this.ensureUniqueNames();
      // 本地伪订阅：节点数同样取原文 proxies 条目数（与远程刷新/FlClash 同口径）
      const declaredLocal = structuredYaml ? YamlMerger.proxyItemGroups(dispatch.body).length : 0;
      sub.nodeCount = declaredLocal > 0 ? declaredLocal : parsed.length;
      sub.lastFetchedAt = Date.now();
      sub.lastRefreshResult = SubscriptionRefreshStatus.OK;
      diagnostics.addedCount = parsed.length;
      diagnostics.configMissingCredentialCount = this.credentialMissingCount;
      try {
        await this.persist();
      } catch (persistError) {
        sub.lastRefreshResult = SubscriptionRefreshStatus.PERSIST_ERROR;
        return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PERSIST_ERROR,
          `刷新结果持久化失败：${SubscriptionService.describeError(persistError)}`, diagnostics);
      }
      this.noteConfigDrops(diagnostics);
      AppLogger.info(TAG, `local subscription refreshed: ${sub.name} (${parsed.length} nodes, `
        + `${this.groupsOf(id).length} groups)`);
      return SubscriptionRefreshResult.ok(parsed.length, diagnostics);
      }); // ── 刷新写锁结束（local 路径）──
    } catch (e) {
      sub.lastRefreshResult = SubscriptionRefreshStatus.PARSE_ERROR;
      return SubscriptionRefreshResult.fail(SubscriptionRefreshStatus.PARSE_ERROR,
        SubscriptionService.describeError(e), diagnostics);
    }
  }

  async addLocalYaml(fileName: string, content: string): Promise<number> {
    // 只接受 Clash 配置：JSON / CONF / 节点链接列表在入口就拦掉，
    // 不要先建订阅再在刷新时失败（会留下一条永远刷不动的卡）。
    if (!SubscriptionService.isClashBody(content)) {
      throw new Error('请提供 YAML 订阅文件（Clash 配置）');
    }

    // 三入口统一诊断：本地 YAML 与 URL 订阅 / 链接文本展示同一组指标
    const diagnostics = new SubscriptionImportDiagnostics();
    this.lastImportDiagnostics = diagnostics;
    const base = fileName.replace(/\.(ya?ml|txt)$/i, '');
    const trimmed = content.trim();
    if (trimmed.length === 0) {
      SubscriptionService.noteInvalid(diagnostics, '文件内容为空');
      return 0;
    }
    const sub = Subscription.newSubscription(util.generateRandomUUID(),
      `本地:${base.length > 0 ? base : '订阅'}`, `local://${base}`);
    sub.sortOrder = this.subscriptions.length;
    // FlClash 同构：本地文件同样落成 profile 文件（内核直接吃原文）
    const localProfile = await ProfileRepository.validateAndStore(sub.id, content);
    if (!localProfile.ok) {
      throw new Error(localProfile.message);
    }
    let parsed: ProxyNode[];
    let parsedGroups: ProxyGroup[] = [];
    /** 双轨：原文是否为 Clash YAML（决定能否作为内核 file provider 落盘） */
    let localEligible = false;
    try {
      YamlMerger.resetSkipStats();
      const localDispatch = BodyDispatch.classify(trimmed);
      localEligible = localDispatch.kind === BodyKind.YAML;
      if (localEligible) {
        const merged: MergedProxy[] = YamlMerger.merge([localDispatch.body], sub.name, '');
        SubscriptionService.absorbYamlMergeStats(diagnostics);
        parsed = SubscriptionService.mergedToNodes(merged, sub.id, diagnostics, localDispatch.body);
        parsedGroups = SubscriptionParser.parseProxyGroups(localDispatch.body, sub.id);
        // 本地 YAML 导入：自带 rules/rule-providers 段随订阅一并落账
        SubscriptionService.applyRulesSections(sub, localDispatch.body);
        // 本地 YAML 导入同样保留 dns 上游
        SubscriptionService.applyDnsSections(sub, localDispatch.body);
        diagnostics.inputCount = diagnostics.inputCount + parsed.length + diagnostics.invalidCount
          + diagnostics.unsupportedCount;
        if (this.store !== null) {
          await this.store.put(`yaml_cache_${sub.id}`, YamlMerger.toYaml(merged));
        }
      } else {
        const parseResult = SubscriptionParser.parseDetailed(trimmed, sub.id);
        parsed = parseResult.nodes;
        parsedGroups = parseResult.groups;
        diagnostics.inputCount = diagnostics.inputCount + parseResult.diagnostics.inputCount;
        diagnostics.duplicateCount = diagnostics.duplicateCount + parseResult.diagnostics.duplicateCount;
        if (parseResult.diagnostics.invalidCount > 0) {
          SubscriptionService.noteInvalidBulk(diagnostics, parseResult.diagnostics.invalidCount,
            `无效链接 ${parseResult.diagnostics.invalidCount} 条`);
        }
        diagnostics.unsupportedCount = diagnostics.unsupportedCount + parseResult.diagnostics.unsupportedCount;
        diagnostics.unsupportedTypes = SubscriptionService.mergeTypes(diagnostics.unsupportedTypes,
          parseResult.diagnostics.unsupportedTypes);
      }
      if (YamlMerger.lastSkippedCount > 0) {
        AppLogger.warn(TAG, `local yaml skipped ${YamlMerger.lastSkippedCount} node(s) `
          + `of unsupported type(s): ${YamlMerger.lastSkippedTypes}`);
      }

      // ---- proxy-providers：本地 YAML 的 provider 段同样拉取（对齐 mihomo 语义）----
      // mihomo 的 include-all/use 组包含 provider 节点；本地导入不拉取的话，
      // 「全部节点/国家组」与内核客户端（BettBox 等）的分组内容差距巨大。
      const providerEntries = ProxyProviderParser.parse(trimmed);
      if (providerEntries.length > 0) {
        const providerImported = await this.appendProviderNodes(providerEntries, sub.id,
          '', '', parsed, diagnostics);
        AppLogger.info(TAG, `local yaml imported ${providerImported} provider node(s) `
          + `from ${providerEntries.length} provider declaration(s)`);
      }
    } catch (e) {
      if (e instanceof YamlMergeError) {
        // 合并限额与解析失败分开：超限必须能被用户看见，而不是笼统「解析失败」
        diagnostics.limitCount = diagnostics.limitCount + 1;
        SubscriptionService.appendInvalidReason(diagnostics, `合并超限：${e.message}`);
      } else {
        SubscriptionService.noteInvalid(diagnostics, `解析异常：${SubscriptionService.describeError(e)}`);
      }
      AppLogger.warn(TAG, `local yaml parse failed: ${SubscriptionService.describeError(e)}`);
      parsed = [];
      parsedGroups = [];
    }
    if (parsed.length === 0 && !localProfile.ok) {
      SubscriptionService.noteInvalid(diagnostics, '内容未解析出节点');
      return 0;
    }
    if (!SubscriptionFetchPolicy.isNodeCountAllowed(parsed.length)) {
      AppLogger.warn(TAG, `local import rejected: ${parsed.length} nodes exceed 2000 limit`);
      diagnostics.limitCount = diagnostics.limitCount + 1;
      SubscriptionService.appendInvalidReason(diagnostics, `节点数量 ${parsed.length} 超过 2000 上限`);
      return 0;
    }
    if (this.hiddenNodes.length > 0) {
      const visible = parsed.filter((n) => !this.hiddenNodes.includes(SubscriptionService.nodeKey(n)));
      diagnostics.hiddenCount = parsed.length - visible.length;
      parsed = visible;
    }
    // 动态分组物化后随本地导入一并入库
    SubscriptionParser.materializeDynamicGroups(parsedGroups, parsed);
    this.proxyGroups = this.proxyGroups.filter((g) => g.subscriptionId !== sub.id).concat(parsedGroups);
    this.subscriptions.push(sub);
    if (ProfileRepository.currentId().length === 0) {
      await ProfileRepository.setCurrent(sub.id);
    }
    this.nodes = this.nodes.concat(parsed);
    this.ensureUniqueNames();
    // 【2026-10-22 · FlClash 同构】本地导入与远程刷新同口径：节点数取原文条目数
    sub.nodeCount = localProfile.nodeCount > 0 ? localProfile.nodeCount : parsed.length;
    sub.lastFetchedAt = Date.now();
    sub.lastRefreshResult = SubscriptionRefreshStatus.OK;
    diagnostics.addedCount = parsed.length;
    diagnostics.configMissingCredentialCount = this.credentialMissingCount;
    // ── 双轨：本地导入的原文同样落盘作为 provider（开关开启时；失败自动降级）──
    this.writeRawProvider(sub, trimmed, localEligible, diagnostics);
    this.updateRawProviderSummary(diagnostics);
    let credentialFailed = 0;
    try {
      credentialFailed = await this.persist();
    } catch (e) {
      // 落盘异常不再只抛给页面（页面只会说「导入失败」），而是计入诊断的持久化失败
      diagnostics.persistFailedCount = this.nodes.length;
      AppLogger.warn(TAG, `local yaml persist failed: ${SubscriptionService.describeError(e)}`);
    }
    if (credentialFailed > 0 && diagnostics.persistFailedCount === 0) {
      diagnostics.persistFailedCount = credentialFailed;
    }
    this.noteConfigDrops(diagnostics);
    AppLogger.info(TAG, `local yaml imported: ${sub.name} (${parsed.length} nodes)`);
    return Math.max(parsed.length, localProfile.nodeCount, 1);
  }

  /**
   * 按名字在**全部启用订阅**里找节点（显示层守卫用，不做任何偏好推导）。
   *
   * 用途：内核真源给出的出口名只有在当前节点表里真实存在时才能显示，
   * 否则说明刚切过订阅，应回退到该订阅的偏好提示。
   */
  nodeByNameCurrent(name: string): ProxyNode | null {
    if (name.length === 0) { return null; }
    for (const n of this.nodes) {
      if (n.name === name) { return n; }
    }
    return null;
  }

  nodesOf(subscriptionId: string): ProxyNode[] {
    return this.nodes.filter((n) => n.subscriptionId === subscriptionId);
  }

  /** 某订阅的全部代理组（保持声明顺序） */
  groupsOf(subscriptionId: string): ProxyGroup[] {
    return this.proxyGroups.filter((g) => g.subscriptionId === subscriptionId);
  }

  /**
   * 全部启用订阅的自带规则行（去重、按订阅顺序，上限 1000 条）。
   * 供配置生成器写入 rules 段 —— 订阅自带的分流规则必须真实生效。
   */
  subscriptionRulesLines(): string[] {
    const out: string[] = [];
    const seen = new Set<string>();
    for (const s of this.subscriptions) {
      if (!s.enabled || s.id === DIRECT_GROUP_ID || s.subRules.length === 0) {
        continue;
      }
      for (const line of s.subRules.split('\n')) {
        let t = line.trim();
        // 落账行保留着 yaml 序列项的 "- " 前缀：生成时外层再加一层会变成 "- - RULE"（嵌套 seq），内核报「cannot unmarshal !!seq into string」拒载。
        if (t.startsWith('- ')) {
          t = t.substring(2).trim();
        }
        if (t.length === 0 || t.startsWith('#') || t.startsWith('- ') || seen.has(t)) {
          continue;
        }
        if (out.length >= 1000) {
          return out;
        }
        seen.add(t);
        out.push(t);
      }
    }
    return out;
  }

  /**
   * 全部启用订阅的 **dns 上游**，**按订阅分组返回**（不再是扁平并集）。
   *
   * 为什么必须按订阅分组（2026-10-21 根因收口）：内核的 `proxy-server-nameserver`
   * 是全局单值，专用解析器只认 `proxy-server-nameserver-policy`、不查
   * `nameserver-policy`。把多份订阅的上游并成一个全局列表，会让公共 DNS 在
   * batchExchange（dns/resolver.go:227，并发取首个应答）里抢跑私有 DoH，
   * 把别的订阅的入口域名解析到 WAF/CDN 诱饵 IP → 那份订阅全部超时。
   *
   * 返回 `SubDnsUpstream[]`：调用方（生成器）按 `ProxyNode.subscriptionId`
   * 把每个上游绑定到它自己的节点域名后缀，等价于「一份订阅一份配置」。
   */
  subscriptionDnsUpstreams(): SubDnsUpstream[] {
    const out: SubDnsUpstream[] = [];
    for (const s of this.subscriptions) {
      if (!s.enabled || s.id === DIRECT_GROUP_ID || s.subDnsProxyServers.length === 0) {
        continue;
      }
      let list: string[] = [];
      try {
        list = JSON.parse(s.subDnsProxyServers) as string[];
      } catch (e) {
        list = [];
      }
      const servers: string[] = [];
      const seen: Set<string> = new Set<string>();
      for (const raw of list) {
        const value = raw.trim();
        if (value.length === 0 || seen.has(value) || servers.length >= 8) {
          continue;
        }
        seen.add(value);
        servers.push(value);
      }
      if (servers.length > 0) {
        out.push(SubDnsUpstream.of(s.id, servers));
      }
    }
    return out;
  }

  /**
   * 全部启用订阅的 `nameserver-policy` 条目（[后缀, 上游] 对，去重、上限 64 对）。
   *
   * 生成器只保留**后缀命中节点域名**的条目 —— 订阅2（pronetwork）就是靠
   * `+.jushuitan.com → 私有 DoH` 这一条把入口解析对，删掉即 0/36 全灭。
   */
  subscriptionDnsPolicies(): string[][] {
    const out: string[][] = [];
    const seen: Set<string> = new Set<string>();
    for (const s of this.subscriptions) {
      if (!s.enabled || s.id === DIRECT_GROUP_ID || s.subDnsPolicies.length === 0) {
        continue;
      }
      let pairs: string[][] = [];
      try {
        pairs = JSON.parse(s.subDnsPolicies) as string[][];
      } catch (e) {
        pairs = [];
      }
      for (const pair of pairs) {
        if (pair.length < 2) {
          continue;
        }
        const suffix = pair[0].trim();
        const server = pair[1].trim();
        if (suffix.length === 0 || server.length === 0) {
          continue;
        }
        const id = `${suffix}\u0000${server}`;
        if (seen.has(id)) {
          continue;
        }
        if (out.length >= 64) {
          return out;
        }
        seen.add(id);
        out.push([suffix, server]);
      }
    }
    return out;
  }

  /**
   * 全部启用订阅的 rule-providers 块（按订阅顺序合并，同名 provider 先到先得）。
   * 返回的是 2 空格缩进的块式原文（可直接跟在 `rule-providers:` 头之后）。
   *
   * 【C16】键行识别改用 **ClashConfigGenerator.parseProviderBlocks**——与配置生成器
   * **完全同一套**「纯缩进层级」判定（不再另写一份正则）。
   * 旧实现用 `/^([A-Za-z0-9_-]+):$/` 认 provider 键行，点号名（`my.provider:`）、
   * 中文名、带引号的名**都不被认成键行** ⇒ 两个后果：
   * ① 同名 provider **不去重** → 顶层重复键 → mihomo 整份配置拒载（R5）；
   * ② 引用这些 provider 的 RULE-SET 规则被**静默丢弃**（R1，比拒载更隐蔽：规则不生效、无报错）。
   *
   * 去重语义：**同名 provider 整块丢弃**（连同它的**全部**字段行）。绝不只丢键行——
   * 只丢键行会让字段行落进**上一条** provider 的 mapping → `mapping key "type" already defined`；
   * 字段键名与上一条不同时**不报错、静默并错 provider**（更隐蔽）。
   *
   * 孤儿字段行（任何键行之前出现、没有归属 provider 的字段行）：**丢弃 + 计数 + 日志**。
   * 绝不静默塞进上一条 provider。
   */
  subscriptionRuleProvidersBlock(): string {
    const lines: string[] = [];
    const seen = new Set<string>();
    let orphanCount = 0;
    for (const s of this.subscriptions) {
      if (!s.enabled || s.id === DIRECT_GROUP_ID || s.subRuleProviders.length === 0) {
        continue;
      }
      const parsed = ClashConfigGenerator.parseProviderBlocks(s.subRuleProviders.split('\n'));
      orphanCount = orphanCount + parsed.orphanLines.length;
      for (const block of parsed.blocks) {
        if (seen.has(block.name)) {
          // 同名 provider：**整块丢弃**（键行 + 全部字段行一起丢，绝不只丢键行）
          continue;
        }
        seen.add(block.name);
        lines.push(block.keyLine);
        for (const field of block.fieldLines) {
          lines.push(field);
        }
      }
    }
    this.lastProviderOrphanLineCount = orphanCount;
    if (orphanCount > 0) {
      AppLogger.warn(TAG, `rule-providers: ${orphanCount} orphan line(s) before any provider key `
        + '(dropped, not merged into any provider)');
    }
    return lines.join('\n');
  }

  /**
   * 展开代理组成员为具体节点（Clash Meta 语义）：
   * - 成员先按「NFKC + 去 U+FE0F」归一再匹配（emoji 变体选择符/全半角兼容）；
   * - 命中节点（originalName 优先，其次显示名）→ 收入结果，按节点 id 去重；
   * - 命中同订阅嵌套组 → 递归展开（含环保护）；DIRECT/REJECT/GLOBAL、
   *   GEO/规则型成员无法映射为节点，直接跳过，绝不误配。
   */
  expandProxyGroup(group: ProxyGroup): ProxyNode[] {
    const out: ProxyNode[] = [];
    const seenNodeIds = new Set<string>();
    const visitedGroups = new Set<string>();
    SubscriptionService.expandGroupInto(group, this.proxyGroups, this.nodes, out, seenNodeIds, visitedGroups);
    return out;
  }

  private static expandGroupInto(group: ProxyGroup, allGroups: ProxyGroup[], nodes: ProxyNode[],
    out: ProxyNode[], seenNodeIds: Set<string>, visitedGroups: Set<string>): void {
    const groupKey = `${group.subscriptionId}\u0000${SubscriptionParser.normalizeGroupName(group.name)}`;
    if (visitedGroups.has(groupKey)) {
      return;
    }
    visitedGroups.add(groupKey);
    // originalName → 节点列表（一对多）：订阅里两个节点原名相同时，组成员引用该原名
    // 必须同时展开出两个节点（显示名已被去重改名，但原始声明只有一个名字）。
    const nodesByOriginal = new Map<string, ProxyNode[]>();
    const nodesByName = new Map<string, ProxyNode>();
    for (const n of nodes) {
      if (n.subscriptionId !== group.subscriptionId) {
        continue;
      }
      const original = n.originalName.length > 0 ? n.originalName : n.name;
      const oKey = SubscriptionParser.normalizeGroupName(original);
      const bucket = nodesByOriginal.get(oKey);
      if (bucket === undefined) {
        nodesByOriginal.set(oKey, [n]);
      } else {
        bucket.push(n);
      }
      const nKey = SubscriptionParser.normalizeGroupName(n.name);
      if (!nodesByName.has(nKey)) {
        nodesByName.set(nKey, n);
      }
    }
    const groupsByName = new Map<string, ProxyGroup>();
    for (const g of allGroups) {
      if (g.subscriptionId !== group.subscriptionId) {
        continue;
      }
      const key = SubscriptionParser.normalizeGroupName(g.name);
      if (!groupsByName.has(key)) {
        groupsByName.set(key, g);
      }
    }
    for (const member of group.members) {
      const key = SubscriptionParser.normalizeGroupName(member);
      if (SubscriptionService.isBuiltinGroupMember(key)) {
        continue;
      }
      const originals = nodesByOriginal.get(key);
      if (originals !== undefined) {
        for (const node of originals) {
          if (!seenNodeIds.has(node.id)) {
            seenNodeIds.add(node.id);
            out.push(node);
          }
        }
        continue;
      }
      const named = nodesByName.get(key);
      if (named !== undefined) {
        if (!seenNodeIds.has(named.id)) {
          seenNodeIds.add(named.id);
          out.push(named);
        }
        continue;
      }
      const nested = groupsByName.get(key);
      if (nested !== undefined) {
        SubscriptionService.expandGroupInto(nested, allGroups, nodes, out, seenNodeIds, visitedGroups);
      }
    }
  }

  /** DIRECT/REJECT/GLOBAL 等内置成员与通配规则成员不可展开为节点 */
  private static isBuiltinGroupMember(normalized: string): boolean {
    const v = normalized.toUpperCase();
    return v === 'DIRECT' || v === 'REJECT' || v === 'REJECT-DROP' || v === 'PASS'
      || v === 'GLOBAL' || v === 'COMPATIBLE';
  }

  /**
   * 组的**直接成员**视图（不递归，mihomo 客户端同款展示语义）：
   * 成员解析为节点（originalName 一对多）或嵌套组；DIRECT/REJECT 与
   * GEO/规则型成员忽略。嵌套组由调用方决定是否继续展开。
   */
  groupMembersOf(group: ProxyGroup): GroupMembers {
    const out = new GroupMembers();
    const seenNodeIds = new Set<string>();
    const seenGroupKeys = new Set<string>();
    const nodesByOriginal = new Map<string, ProxyNode[]>();
    const nodesByName = new Map<string, ProxyNode>();
    for (const n of this.nodes) {
      if (n.subscriptionId !== group.subscriptionId) {
        continue;
      }
      const original = n.originalName.length > 0 ? n.originalName : n.name;
      const oKey = SubscriptionParser.normalizeGroupName(original);
      const bucket = nodesByOriginal.get(oKey);
      if (bucket === undefined) {
        nodesByOriginal.set(oKey, [n]);
      } else {
        bucket.push(n);
      }
      const nKey = SubscriptionParser.normalizeGroupName(n.name);
      if (!nodesByName.has(nKey)) {
        nodesByName.set(nKey, n);
      }
    }
    const groupsByName = new Map<string, ProxyGroup>();
    for (const g of this.proxyGroups) {
      if (g.subscriptionId !== group.subscriptionId) {
        continue;
      }
      const key = SubscriptionParser.normalizeGroupName(g.name);
      if (!groupsByName.has(key)) {
        groupsByName.set(key, g);
      }
    }
    for (const member of group.members) {
      const key = SubscriptionParser.normalizeGroupName(member);
      if (SubscriptionService.isBuiltinGroupMember(key)) {
        continue;
      }
      const originals = nodesByOriginal.get(key);
      if (originals !== undefined) {
        for (const node of originals) {
          if (!seenNodeIds.has(node.id)) {
            seenNodeIds.add(node.id);
            out.nodes.push(node);
          }
        }
        continue;
      }
      const named = nodesByName.get(key);
      if (named !== undefined) {
        if (!seenNodeIds.has(named.id)) {
          seenNodeIds.add(named.id);
          out.nodes.push(named);
        }
        continue;
      }
      const nested = groupsByName.get(key);
      if (nested !== undefined) {
        const gKey = SubscriptionParser.normalizeGroupName(nested.name);
        if (!seenGroupKeys.has(gKey)) {
          seenGroupKeys.add(gKey);
          out.groups.push(nested);
        }
      }
    }
    return out;
  }

  /**
   * 清掉旧版的「单节点」虚拟分组与它名下的直链节点（幂等）。
   *
   * 【2026-10-22 用户口径】单节点不再有独立分组：单节点用户自己走
   * 「设置 → 订阅转换」生成配置、再以文件方式导入。返回是否真的改动了
   * 存储，调用方据此决定要不要 persist。
   */
  private purgeDirectGroup(): boolean {
    const nodeCountBefore = this.nodes.length;
    const subCountBefore = this.subscriptions.length;
    this.nodes = this.nodes.filter((n: ProxyNode): boolean => n.subscriptionId !== DIRECT_GROUP_ID);
    this.subscriptions = this.subscriptions.filter((s: Subscription): boolean => s.id !== DIRECT_GROUP_ID);
    const removedNodes = nodeCountBefore - this.nodes.length;
    const removedSubs = subCountBefore - this.subscriptions.length;
    if (removedNodes > 0 || removedSubs > 0) {
      AppLogger.info(TAG, `purged legacy single-node group: `
        + `${removedSubs} group(s), ${removedNodes} node(s)`);
      return true;
    }
    return false;
  }

  hasUsableProfile(): boolean {
    const id = ProfileRepository.currentId();
    return (id.length > 0 && ProfileRepository.exists(id))
      || this.subscriptions.some((sub: Subscription): boolean => sub.enabled && ProfileRepository.exists(sub.id));
  }

  fallbackConnectionNode(): ProxyNode | null {
    const current = ProfileRepository.currentId();
    // 【2026-10-24 加固】存量节点表可能残留订阅信息条目（「剩余流量：xxx GB」这类，
    // 旧解析混入、刷新后清除）——绝不能当连接目标（内核里没有这个名字，钉选必失败）。
    const local = this.nodes.find((node: ProxyNode): boolean =>
      node.subscriptionId === current && !NodeUsability.isInfoEntry(node.name));
    if (local !== undefined) { return local; }
    if (this.hasUsableProfile()) {
      const node = new ProxyNode();
      node.id = `profile:${current}`;
      node.name = '订阅默认出口';
      node.subscriptionId = current;
      return node;
    }
    // 【2026-10-25 产品口径：单订阅作用域】最后回落不再跨订阅抓节点（旧实现 anyReal
    // 会把别家订阅的节点当连接目标 → 配置里没有这个名字 → 钉选必失败「选择未生效」）。
    // 当前订阅确实没有任何可用节点时如实返回 null，由调用方给出可行动提示。
    return null;
  }

  /**
   * 订阅刷新重解析按位置重排节点 id（`<subId>-mN`）。若用户偏好节点属于本订阅，
   * 在旧表被替换的同一时刻按 (订阅, 节点名) 重锚 preferredNodeId —— 否则旧 id
   * 在新表里可能指向**另一个节点**（2026-10-25 真机实证：关应用前选 YF香港，
   * 冷启动自动刷新后同 id 变成 新加坡01AWS，连接钉错节点报「选择未生效」）。
   * 写时重锚兜住**存量数据**（无 preferredNodeName 快照的旧选择，并顺手回填快照）；
   * 读时重锚（resolvePreferenceHint）继续兜其余漂移路径。机场下架该节点 → 清偏好
   * 回落 fallback，绝不让漂移 id 静默指错人。
   */
  private async reanchorPreferredAfterReplace(subId: string, oldSubNodes: ProxyNode[]): Promise<void> {
    if (oldSubNodes.length === 0) {
      return;
    }
    try {
      const s: AppSettings = await SettingsService.load();
      if (s.preferredNodeId.length === 0) {
        return;
      }
      const old = oldSubNodes.find((n: ProxyNode): boolean => n.id === s.preferredNodeId);
      if (old === undefined) {
        return; // 偏好不在本订阅，不越界处理
      }
      const fresh = this.nodes.find((n: ProxyNode): boolean =>
        n.subscriptionId === subId && n.name === old.name);
      if (fresh === undefined) {
        await SettingsService.patchSettings((p: AppSettings): void => {
          p.preferredNodeId = '';
          p.preferredNodeSubscriptionId = '';
          p.preferredNodeName = '';
          // 该订阅记住的也是这个已下架节点：一并忘掉，切回时不再尝试还原它。
          p.preferredNodeNamesBySubscription = AppSettings.forgetPreferredNodeName(
            p.preferredNodeNamesBySubscription, subId, old.name);
        });
        AppLogger.info(TAG, `preferred node gone after refresh (sub=${subId}, name=${old.name}); cleared`);
        return;
      }
      if (fresh.id === old.id && s.preferredNodeName === old.name) {
        return; // 无漂移
      }
      await SettingsService.patchSettings((p: AppSettings): void => {
        p.preferredNodeId = fresh.id;
        p.preferredNodeSubscriptionId = subId;
        p.preferredNodeName = fresh.name;
        p.preferredNodeNamesBySubscription = AppSettings.rememberPreferredNodeName(
          p.preferredNodeNamesBySubscription, subId, fresh.name);
      });
      AppLogger.info(TAG, `preferred node re-anchored on refresh: ${old.name} ${old.id} -> ${fresh.id}`);
    } catch (e) {
      AppLogger.warn(TAG, `preferred re-anchor failed: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * 同步作用域校验（展示路径用）：偏好节点只有属于**当前激活订阅**才算数。
   * 切换订阅后遗留的旧偏好（findNode 是全局搜、不分订阅）在这里判无效 → 调用方
   * 回落 fallbackConnectionNode()。不做重锚、不写盘。
   */
  preferredNodeInCurrentProfile(preferredNodeId: string): ProxyNode | null {
    if (preferredNodeId.length === 0) {
      return null;
    }
    const n = this.findNode(preferredNodeId);
    if (n === null) {
      return null;
    }
    if (n.subscriptionId.length > 0 && n.subscriptionId !== ProfileRepository.currentId()) {
      return null;
    }
    return n;
  }

  /**
   * 用户偏好在**当前 profile** 内的稳定解析（id + 名称双锚，只读，不写盘）。
   *
   * ## 为什么需要它（2026-10-27 真机回归：手动选择后复选框变空、实际仍走该节点）
   *
   * 偏好落盘有两份事实：`preferredNodeId`（订阅刷新按位置重排会漂移，连接自愈
   * 还可能把它清空）与 `preferredNodeName`（跨刷新稳定）。旧展示路径**只看 id**：
   * 只要 id 被清空/漂移，即使 name 仍精确命中节点，复选框也会变空 —— 而内核侧
   * 出口并未改变，于是出现「没勾选但连接的还是它」的割裂。
   *
   * 解析顺序（**名称是稳定锚，id 只作快速索引**）：
   *   ① 名称在当前 profile 内精确命中 → 用它（订阅刷新后 id 变了也能找回）；
   *   ② 名称缺失/未命中时，id 命中且属于当前 profile → 用它（兼容老数据）；
   *   ③ 都不成立 → null（调用方回落 fallbackConnectionNode）。
   */
  resolveUserPreference(preferredId: string, preferredName: string): ProxyNode | null {
    const current = ProfileRepository.currentId();
    if (preferredName.length > 0) {
      const byName = this.nodes.find((n: ProxyNode): boolean =>
        n.name === preferredName
          && !NodeUsability.isInfoEntry(n.name)
          && (current.length === 0 || n.subscriptionId === current));
      if (byName !== undefined) {
        return byName;
      }
    }
    if (preferredId.length === 0) {
      return null;
    }
    const byId = this.findNode(preferredId);
    if (byId === null) {
      return null;
    }
    if (byId.subscriptionId.length > 0 && current.length > 0
      && byId.subscriptionId !== current) {
      return null;
    }
    return byId;
  }

  /**
   * 解析**用户偏好缓存**给出的候选节点（提示用，不是"当前状态"）。
   *
   * ⚠ 契约（2026-10-27 架构收口）：本方法的返回值只能当"用户上次选了哪个"的提示，
   * 由连接路径在内核主组成员里校验后才会真正 PUT；「当前是什么节点」的唯一真源是
   * 内核 `/proxies` 主组 `now`（见 `ConnectionOrchestrator.lastConnectionTarget`）。
   * 因此任何"当前节点"显示都不得直接读它 —— 必须走 `displayNodeName()` /
   * `connectionTargetLabel()`。
   *
   * 三层语义：
   * ① id 命中、属于当前订阅、名字与快照一致（防位置 id 漂移指错节点）→ 直接用；
   * ② id 悬空/漂移，但偏好本就属于当前订阅（preferredNodeSubscriptionId 相符）
   *    → 按 preferredNodeName 在当前订阅内重锚，命中即回写自愈
   *    （订阅刷新按位置重排 id、冷启动自动更新后手动选择不再丢）；
   * ③ 偏好指向其他订阅（切换订阅后的遗留）→ 判无效返回 null，不跨订阅猜。
   * 返回 null = 当前订阅下无可用偏好，调用方回落 fallbackConnectionNode()。
   */
  async resolvePreferenceHint(): Promise<ProxyNode | null> {
    const s: AppSettings = await SettingsService.load();
    const current = ProfileRepository.currentId();
    // 本订阅**上次手动选的**节点名（切订阅后仍保留，用于切回时还原）。
    const remembered = AppSettings.rememberedPreferredNodeName(
      s.preferredNodeNamesBySubscription, current);

    // 冷启动强制以当前订阅记忆为准：日志已证明 UI 显示节点与 connect() 实际
    // 使用节点发生漂移（例如页面显示香港移联01，而连接链路进入新加坡01aws）。
    // 当前订阅存在记忆节点且与全局 preferredNodeName 不一致时，先重锚再继续解析。
    if (remembered.length > 0 && remembered !== s.preferredNodeName) {
      const restored = await this.restoreRememberedPreferredNode(remembered, current);
      if (restored !== null) {
        return restored;
      }
    }

    if (s.preferredNodeId.length === 0 && s.preferredNodeName.length === 0) {
      return await this.restoreRememberedPreferredNode(remembered, current);
    }
    const byId = s.preferredNodeId.length > 0 ? this.findNode(s.preferredNodeId) : null;
    const idOk = byId !== null
      && (byId.subscriptionId.length === 0 || byId.subscriptionId === current)
      && (s.preferredNodeName.length === 0 || byId.name === s.preferredNodeName);
    if (idOk && byId !== null) {
      return byId;
    }
    // 跨订阅遗留：先看目标订阅自己记住的节点，绝不按名猜到别的订阅
    if (s.preferredNodeSubscriptionId.length > 0 && s.preferredNodeSubscriptionId !== current) {
      return await this.restoreRememberedPreferredNode(remembered, current);
    }
    if (s.preferredNodeName.length > 0 && current.length > 0) {
      const byName = this.nodes.find((n: ProxyNode): boolean =>
        n.subscriptionId === current && n.name === s.preferredNodeName
        && !NodeUsability.isInfoEntry(n.name));
      if (byName !== undefined) {
        await SettingsService.patchSettings((p: AppSettings): void => {
          p.preferredNodeId = byName.id;
          p.preferredNodeSubscriptionId = current;
        });
        AppLogger.info(TAG, `preferred node re-anchored by name: ${byName.name} (${byName.id})`);
        return byName;
      }
    }
    return await this.restoreRememberedPreferredNode(remembered, current);
  }

  /**
   * 把「目标订阅上次手动选的节点」还原成当前生效偏好。
   *
   * 场景（2026-10-27 用户报障）：在吹雪云选了新加坡01 → 切到飞鸟云选了日本01 →
   * 切回吹雪云时偏好仍是飞鸟云的节点，按跨订阅作用域判无效后掉到该订阅第一个
   * 节点（用户感知为「随机选了一个」）。这里按订阅分槽记住的名字还原，命中即把
   * preferredNode* 三件套改回该节点；节点已不存在则放弃（调用方回落第一个节点）。
   */
  private async restoreRememberedPreferredNode(remembered: string,
    current: string): Promise<ProxyNode | null> {
    if (remembered.length === 0 || current.length === 0) {
      return null;
    }
    const target = this.nodes.find((n: ProxyNode): boolean =>
      n.subscriptionId === current && n.name === remembered
      && !NodeUsability.isInfoEntry(n.name));
    if (target === undefined) {
      return null;
    }
    await SettingsService.patchSettings((p: AppSettings): void => {
      p.preferredNodeId = target.id;
      p.preferredNodeSubscriptionId = current;
      p.preferredNodeName = target.name;
    });
    AppLogger.info(TAG, `preferred node restored from subscription memory: `
      + `${target.name} (${target.id}, sub=${current})`);
    return target;
  }

  /**
   * 冷启动/其他入口兜底：把**当前订阅**记住的节点还原成生效偏好。
   *
   * 正常切订阅走 SubscriptionPage.activateProfile（切过去之前就还原）；这里覆盖
   * 「App 冷启动 / 订阅被自动删切换」等不经过那个页面的路径，避免首页继续显示
   * 上一个订阅的节点或该订阅第一个节点。
   */
  async restoreRememberedNodeForCurrentProfile(): Promise<ProxyNode | null> {
    const s: AppSettings = await SettingsService.load();
    const current = ProfileRepository.currentId();
    const remembered = AppSettings.rememberedPreferredNodeName(
      s.preferredNodeNamesBySubscription, current);
    return await this.restoreRememberedPreferredNode(remembered, current);
  }

  findNode(id: string): ProxyNode | null {
    const n = this.nodes.find((x) => x.id === id);
    if (n !== undefined) {
      return n;
    }
    // 内核影子节点（`core:<name>`）：节点清单由内核 `/proxies` 提供（FlClash 同构）
    if (id.startsWith('core:')) {
      const name = id.substring('core:'.length);
      const model = CoreCatalogService.current();
      if (model !== null) {
        const entry = model.byName[name];
        if (entry !== undefined && !entry.isGroup) {
          return CoreNodeBridge.toProxyNode(entry);
        }
      }
    }
    return null;
  }

  /** 更新订阅名称/URL（对应 upstream SubscriptionEditStatus.saved 持久化路径） */
  async updateSubscription(target: Subscription): Promise<void> {
    const index = this.subscriptions.findIndex((s) => s.id === target.id);
    if (index < 0) {
      return;
    }
    this.subscriptions[index] = target;
    await this.persist();
  }

  /**
   * Nexus 备份恢复入口：整体覆盖订阅/节点/代理组/隐藏名单后全量落盘。
   * 调用方（BackupRestoreService）负责 JSON 结构校验与字段清洗，这里只做覆盖 + persist。
   */
  async restoreBackup(subs: Subscription[], nodes: ProxyNode[],
    groups: ProxyGroup[], hidden: string[]): Promise<void> {
    this.subscriptions = subs;
    this.nodes = nodes;
    this.proxyGroups = groups;
    this.hiddenNodes = hidden;
    await this.initNodes(this.nodes);
    await this.persist();
  }

  /** 代理组备份解析（复用 mapGroups 校验口径：坏记录跳过） */
  static parseGroups(json: Object): ProxyGroup[] {
    return SubscriptionService.mapGroups(json);
  }

  /** 已隐藏节点 key 快照（Nexus 备份导出用） */
  listHiddenKeys(): string[] {
    return this.hiddenNodes.slice();
  }

  /** 判断是否为默认占位名（"订阅 N"） */
  static isDefaultName(name: string): boolean {
    return /^订阅\s*\d+$/.test(name.trim());
  }

  /**
   * 从订阅内容提取机场名（对齐常见订阅面板的 userinfo / 标题行约定）：
   * 1) Base64 整体解码后首行 `name=xxx` 或 `title=xxx`（V2Board 惯例）
   * 2) 解码后首行纯文本（非节点链接）视为品牌名，如 "吹雪云"
   * 3) Clash YAML 无用户信息头时返回 ''
   */
  static detectProviderName(body: string): string {
    let text = body;
    // 尝试整体 Base64 解码
    try {
      const cleaned = body.replace(/\s+/g, '');
      if (!/[:{]/.test(cleaned.substring(0, 200)) && /^[A-Za-z0-9+/=_-]+$/.test(cleaned)) {
        const decoded = Base64Codec.decodeBase64Url(cleaned);
        if (decoded.length > 0) {
          text = decoded;
        }
      }
    } catch (e) {
      // 保持原文
    }

    const lines = text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0);
    if (lines.length === 0) {
      return '';
    }
    // 跳过 YAML/节点链接内容找头部信息行
    for (const line of lines.slice(0, 5)) {
      if (line.startsWith('ssr://') || line.startsWith('ss://') || line.startsWith('vless://')
        || line.startsWith('vmess://') || line.startsWith('trojan://')) {
        break; // 直接是节点列表，无头部
      }
      // name=xxx / title=xxx（URL 编码的中文需解码）
      const kv = line.match(/^(?:name|title)=(.+)$/i);
      if (kv !== null) {
        let val = kv[1].trim();
        try {
          val = decodeURIComponent(val);
        } catch (e) {
          // 已是明文
        }
        if (val.length > 0 && val.length <= 60) {
          return val;
        }
      }
      // 纯文本首行（含中文/字母，不含 yaml 冒号结构）视为品牌名
      if (!line.includes('://') && !line.startsWith('{') && !line.startsWith('-')
        && !/^[\w-]+\s*:/.test(line) && /[A-Za-z\u4e00-\u9fa5]/.test(line) && line.length <= 60) {
        return line;
      }
      break; // 首行不匹配即停止（YAML 等格式）
    }
    return '';
  }

  /** 判断是否为节点直链（与 ProxyNode.fromUri 支持的 scheme 一致） */
  static isNodeUri(input: string): boolean {
    const t = input.trim();
    const m = t.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):\/\//);
    return m !== null && ProxyNode.hasUriCodec(m[1]);
  }
}

/** 手工节点的独立持久化桶（对应 node_edit_screen 手工添加） */
export class ManualNodeStore {
  private static store: preferences.Preferences | null = null;
  private static credStore: preferences.Preferences | null = null;
  private static nodes: ProxyNode[] = [];
  private static listeners: (() => void)[] = [];

  static async init(context: Context): Promise<void> {
    ManualNodeStore.store = await preferences.getPreferences(context, PREF_NAME);
    if (ManualNodeStore.credStore === null) {
      ManualNodeStore.credStore = await preferences.getPreferences(context, CRED_PREF_NAME);
    }
    ManualNodeStore.nodes = [];
    try {
      const raw = await ManualNodeStore.store.get('manual_nodes_json', '[]') as string;
      ManualNodeStore.nodes = SubscriptionService.mapNodes(JSON.parse(raw) as Object);
    } catch (e) {
      AppLogger.warn(TAG, 'invalid manual nodes preferences ignored');
    }
    // 手工节点同样走凭据分离：迁移 → 加密回填 → 清扫明文 → 落库
    await ManualNodeStore.migrateCredentials();
    CredentialStore.canonicalizeNodes(ManualNodeStore.nodes, false)
      .catch((e: Object) => AppLogger.warn(TAG, `manual node credential sync failed: ${AppLogger.errText(e)}`));
  }

  /** 手工节点一次性迁移（与订阅节点同一套 Asset 键空间，幂等） */
  private static async migrateCredentials(): Promise<void> {
    if (ManualNodeStore.nodes.length === 0) {
      return;
    }
    const report = await CredentialStore.canonicalizeNodes(ManualNodeStore.nodes, !CredentialStore.isFirstRun());
    if (report.failed > 0) {
      AppLogger.warn(TAG, `manual node credential migration incomplete: ${report.failed} field(s) failed; plaintext preserved`);
      return;
    }
    // 全部回读校验通过 → 清明文并落库（凭据已只存在于 AssetStore）
    for (const n of ManualNodeStore.nodes) {
      n.password = '';
      n.uuid = '';
      n.protocolParam = '';
      n.obfsParam = '';
      n.rawYaml = '';
      n.rawUri = '';
    }
    await ManualNodeStore.persist();
  }

  static all(): ProxyNode[] {
    return ManualNodeStore.nodes;
  }

  static async addNode(node: ProxyNode): Promise<void> {
    ManualNodeStore.nodes.push(node);
    await ManualNodeStore.persist();
    for (const l of ManualNodeStore.listeners) {
      l();
    }
  }

  static addListener(listener: () => void): void {
    ManualNodeStore.listeners.push(listener);
  }

  private static async persist(): Promise<void> {
    if (ManualNodeStore.store === null) {
      return;
    }
    // 凭据先入加密层，元数据 JSON 里的敏感字段已在 fromNode 中恒为空
    const report = await CredentialStore.canonicalizeNodes(ManualNodeStore.nodes, false);
    const out: ProxyNodeJson[] = [];
    for (const n of ManualNodeStore.nodes) {
      out.push(ProxyNodeJson.fromNode(n));
    }
    await ManualNodeStore.store.put('manual_nodes_json', JSON.stringify(out));
    await ManualNodeStore.store.flush();
    if (report.failed > 0) {
      AppLogger.warn(TAG, `manual node credential store incomplete: ${report.failed} field(s)`);
    }
  }
}

/** 撤销快照（对应 subscription_undo_record.dart） */
/** 代理组的直接成员视图（groupMembersOf 返回值；不递归） */
export class GroupMembers {
  /** 可直接挂在本组下的节点（originalName 一对多，去重） */
  nodes: ProxyNode[] = [];
  /** 成员里引用的同订阅嵌套组（声明顺序） */
  groups: ProxyGroup[] = [];
}

export class SubscriptionUndoSnapshot {
  subs: Subscription[];
  nodes: ProxyNode[];
  /** 双轨：被删订阅 id 与其落盘原文（撤销时回写 provider 文件；空串 = 无） */
  rawSubscriptionId: string = '';
  rawBody: string = '';
  /** 被删订阅的代理组（撤销时一并恢复） */
  proxyGroups: ProxyGroup[];

  constructor(subs: Subscription[], nodes: ProxyNode[],
    rawSubscriptionId: string = '', rawBody: string = '', proxyGroups: ProxyGroup[] = []) {
    this.subs = subs;
    this.nodes = nodes;
    this.rawSubscriptionId = rawSubscriptionId;
    this.rawBody = rawBody;
    this.proxyGroups = proxyGroups;
  }
}

/** 持久化 JSON 形状（显式类，满足 arkts-no-untyped-obj-literals） */
export class ProxyNodeJson {
  id: string = '';
  subscriptionId: string = '';
  name: string = '';
  server: string = '';
  port: number = 0;
  password: string = '';
  method: string = '';
  protocol: string = '';
  protocolParam: string = '';
  obfs: string = '';
  obfsParam: string = '';
  type: string = 'ssr';
  proxyType: string = '';
  uuid: string = '';
  alterId: number = 0;
  udp: boolean = false;
  network: string = '';
  tls: boolean = false;
  servername: string = '';
  skipCertVerify: boolean = false;
  flow: string = '';
  clientFingerprint: string = '';
  /** 可选：老存储无此键（新增字段必须允许 undefined，见 ValidProxyNodeJson 校验） */
  certFingerprint?: string = '';
  realityPublicKey: string = '';
  realityShortId: string = '';
  wsPath: string = '';
  wsHost: string = '';
  grpcServiceName: string = '';
  /** hysteria2 扩展字段（可选: 旧存储无这些键, 读取端 ?? '' 兜底） */
  hyUp?: string;
  hyDown?: string;
  alpnList?: string;
  /** 结构化槽位之外的额外键值(JSON 数组)，旧存储无此键，读取端 ?? '' 兜底 */
  extraOpts?: string;
  /** 订阅原始节点名（旧存储无此键，读取端 ?? '' 兜底），代理组成员匹配依赖它 */
  originalName?: string;
  /** 去凭据逐字模板（旧存储无此键，读取端 ?? '' 兜底）；不含明文凭据，可持久化 */
  rawTemplate?: string;
  rawYaml: string = '';
  rawUri: string = '';

  static fromNode(n: ProxyNode): ProxyNodeJson {
    const j = new ProxyNodeJson();
    j.id = n.id;
    j.subscriptionId = n.subscriptionId;
    j.name = n.name;
    j.originalName = n.originalName;
    j.server = n.server;
    j.port = n.port;
    j.password = n.password;
    j.method = n.method;
    j.protocol = n.protocol;
    j.protocolParam = n.protocolParam;
    j.obfs = n.obfs;
    j.obfsParam = n.obfsParam;
    j.type = n.type === ProxyNodeType.SS ? 'ss' : (n.type === ProxyNodeType.SSR ? 'ssr' : 'other');
    j.proxyType = n.proxyType;
    j.uuid = n.uuid;
    j.alterId = n.alterId;
    j.udp = n.udp;
    j.network = n.network;
    j.tls = n.tls;
    j.servername = n.servername;
    j.skipCertVerify = n.skipCertVerify;
    j.flow = n.flow;
    j.clientFingerprint = n.clientFingerprint;
    j.certFingerprint = n.certFingerprint;
    j.realityPublicKey = n.realityPublicKey;
    j.realityShortId = n.realityShortId;
    j.wsPath = n.wsPath;
    j.wsHost = n.wsHost;
    j.grpcServiceName = n.grpcServiceName;
    j.hyUp = n.hyUp;
    j.hyDown = n.hyDown;
    j.alpnList = n.alpnList;
    j.extraOpts = n.extraOpts;
    j.rawTemplate = n.rawTemplate;
    j.rawYaml = '';
    j.rawUri = n.rawUri;
    return j;
  }
}

/** 持久化 JSON 形状 */
export class SubscriptionJson {
  id: string = '';
  name: string = '';
  url: string = '';
  headerName: string = '';
  headerValue: string = '';
  lastFetchedAt: number = 0;
  lastRefreshResult: string = '';
  nodeCount: number = 0;
  uploadBytes?: number;
  downloadBytes?: number;
  totalBytes?: number;
  expireAt?: number;
  enabled: boolean = true;
  sortOrder: number = 0;
  /** 双轨 provider 状态（见 Subscription.rawProviderState；旧存储无此键，读取端 ?? '' 兜底） */
  /** 旧格式（非 Clash）标记：停止刷新但节点仍可用 */
  legacyFormat: boolean = false;
  rawProviderState?: string;
  /** 双轨 provider 落盘原文条目估算（旧存储无此键，读取端 ?? 0 兜底） */
  rawProviderNodeEstimate?: number;
  /** ETag/Last-Modified 条件请求凭据（旧存储无此键，读取端 ?? '' 兜底） */
  etag?: string;
  /** 订阅 yaml 自带 rules 段（后加字段，旧存储无此键，读取端 ?? '' 兜底） */
  subRules?: string;
  /** 订阅 yaml 自带 rule-providers 段（后加字段，旧存储无此键，读取端 ?? '' 兜底） */
  subRuleProviders?: string;
  /** 订阅 dns.proxy-server-nameserver 上游（JSON 字符串数组；后加字段，?? '' 兜底） */
  subDnsProxyServers?: string;
  /** 订阅 dns nameserver-policy 条目（JSON 二维数组；后加字段，?? '' 兜底） */
  subDnsPolicies?: string;
}
