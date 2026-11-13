/**
 * 运行时配置唯一入口（一份 IR → 一份 YAML）
 *
 * ## 为什么要有这个文件（2026-10-20 真机症状的直接根因）
 *
 * 症状：「同一节点在隧道里能用、在测速核里失败」。
 *
 * 结构根因：App 里原本有**两份 YAML**，各自独立调用生成器：
 *   · 隧道：ConnectionOrchestrator.connect() → ClashConfigGenerator.generate(...)
 *   · 测速核：ConnectionOrchestrator.launchTestCore() → ClashConfigGenerator.generate(...)
 * 两次调用的**入参不同**（useSmart / ruleProviderReady / selectedNode / proxyHosts /
 * useGeoip / tun.enable / secret / 端口），于是 DNS 段、固定 IP、节点定义、代理组、
 * 规则都可能不一致 —— 隧道里 pin 住的节点在测速核里没 pin 住、隧道里启用的去广告
 * 规则集在测速核里没启用、隧道用用户选中的节点而测速核固定用 subs.nodes[0] …
 *
 * FlClash 只有**一份**配置 → 结构上没有这类分叉。
 * 本文件就是那个「一份」：**唯一**的决策点 + **唯一**的生成入口。
 *
 * ## 硬约束
 *
 * 1. **整仓只允许本文件调用 ClashConfigGenerator.generate(**（闸门：
 *    scripts/verify-config-single-source.mjs）。别处再调用 = 配置分叉回来了。
 * 2. 运行决策（ruleProviderReady / selectedNode / useGeoip）
 *    **只在 decideRuntimeOptions() 里做一次**，两种 mode 共享同一份结果。
 * 3. hosts（节点域名 → 固定 IP）**只从 DoHResolver 的共享快照取**，
 *    refreshStale() 也**只在这里调一处** —— 不做「自己解析一套 + 再用隧道结果补洞」。
 * 4. 端口（mixed-port / external-controller / dns.listen）是**显式入参**：
 *    隧道与测速核各自独立，**绝不写回任何共享状态**（审计 F1，高危）。
 *    YAML 里的端口与客户端 setEndpoint 用的端口必须来自**同一个局部变量**
 *    （本文件把用到的端口原样回传在 RuntimeConfigResult 里，调用方直接用）。
 *
 * ## 两种 mode 的差异白名单
 *
 * 除下面这些行以外，两份 YAML 必须**逐字节相同**：
 *   secret / mixed-port / external-controller / dns.listen / tun.enable / log-level
 * （闸门脚本按行比对，越界即失败。）
 *
 * 唯一的有意例外（2026-11-11）：订阅自带的 http 规则集**本地还没缓存**时，测速核里
 * 换成同名空 inline（TunBoxProfileInput.skipUncachedRuleProviders）。测速不走分流规则，
 * 不该为它在启动时等规则集下载；缓存一旦存在，两份配置在这一段又完全相同。
 *
 * ## 接线指南（ConnectionOrchestrator 侧）
 *
 * 隧道（connect / reloadRulesHot）：
 * ```
 * const profile: RuntimeConfigProfile = new RuntimeConfigProfile();
 * profile.nodes = subs.nodes;
 * profile.settings = settings;
 * profile.selectedNodeName = target.name;        // 用户当前选中的节点（两种 mode 共用）
 * profile.mixedPort = this.mixedPort;            // 隧道自己的端口
 * profile.apiPort = this.apiPort;
 * profile.dnsPort = this.dnsPort;
 * profile.apiSecret = this.apiSecret;
 * profile.smartModelReady = this.isSmartModelReady();  // Model.bin 是否就绪
 *   （只查询手动安装事实；构建、测速和启动均不得自动安装或下载模型）
 * profile.geoipReady = this.isGeoipReady();
 * profile.ruleProviderFileReady = this.isRuleProviderReady();
 * // hosts 提前解析（与端口探测并行推进），来源只有 DoHResolver 共享快照这一处
 * profile.proxyHosts = await RuntimeConfigBuilder.resolveSharedHosts(subs.nodes, [target.server]);
 * const res: RuntimeConfigResult =
 *   await RuntimeConfigBuilder.buildRuntimeConfig(profile, RuntimeConfigMode.TUNNEL);
 * // 端口与 YAML 里写进去的是同一个值：controller 连接用 res.apiPort
 * this.api.setEndpoint(res.apiPort, res.apiSecret);
 * ```
 *
 * 测速核（launchTestCore）：**同一个 profile**，mode 换成 RuntimeConfigMode.TEST；
 * 端口用**测速核自己探测的**端口，**不要写回 this.mixedPort / this.apiPort /
 * this.dnsPort**（审计 F1：写回会让隧道 YAML 里的端口与客户端 setEndpoint 用的
 * 端口对不上）。
 */
import { ProxyNode } from '../models/ProxyNode';
import { ProxyGroup } from '../models/ProxyGroup';
import { AppSettings, AutoSelectModes } from '../models/AppSettings';
import { SubDnsUpstream } from '../models/SubDnsUpstream';
import { ClashConfigGenerator } from '../services/ClashConfigGenerator';
import { DoHResolver } from '../services/DoHResolver';
// 订阅原文 → overlay 合并（FlClash mergeProfileBase 的等价实现）
import { ProfileConfigMerger } from '../tunbox/ProfileConfigMerger';
// FlClash 同构构建器（2026-11-05）：内核解析 → map patch → JSON dump
import { TunBoxProfileBuilder, TunBoxProfileInput, TunBoxProfileResult, TunBoxGroupInfo } from '../tunbox/TunBoxProfileBuilder';
import { ProfileRepository } from '../tunbox/ProfileRepository';
import { AppLogger } from '../utils/AppLogger';
import { BASE_MTU } from '../services/VpnRecoveryPolicy';

const TAG = 'RuntimeConfigBuilder';

/**
 * 运行模式。
 *
 * 不用 `enum`：Node 侧的 type-stripping 测试台（scripts/verify-*.mjs 的转译链）
 * 不吃 enum，字符串常量类是本仓库既有做法（见 AutoSelectModes）。
 */
export class RuntimeConfigMode {
  /** 隧道：用户真实流量走的那份配置。 */
  static readonly TUNNEL: string = 'tunnel';
  /** 测速核：headless 延迟探测用的那份配置（无 TUN）。 */
  static readonly TEST: string = 'test';
}

/**
 * 配置生成输入（IR）。
 *
 * 两种 mode **必须用同一个 profile 实例**（同一份决策输入）构建 ——
 * 这正是「一份配置」的前提：决策输入相同 → 决策结果相同 → YAML 只差白名单那几行。
 */
export class RuntimeConfigProfile {
  /** 全部节点（生成器用它铺 proxies: 段）。 */
  nodes: ProxyNode[] = [];
  /** 用户设置（代理模式、日志级别、规则开关等）。 */
  settings: AppSettings = new AppSettings();
  /** 订阅带来的代理组。 */
  proxyGroups: ProxyGroup[] = [];
  /** 订阅规则行。 */
  subscriptionRules: string[] = [];
  /** 订阅 rule-providers 段（原文）。 */
  subscriptionRuleProviders: string = '';
  /**
   * 订阅自带的 DNS 上游（`dns.proxy-server-nameserver` 条目，已去重）。
   *
   * 生成器按**订阅**把这一路绑定到它自己的入口域名后缀，最终写成
   * `proxy-server-nameserver-policy`；全局 `proxy-server-nameserver` 只留中性 DoT。
   * 丢或并成扁平列表都会让公共 DNS 抢跑私有 DoH，该订阅的域名节点全部超时
   * （2026-10-20 单订阅定案 / 2026-10-21 多订阅收口）。
   */
  subscriptionDnsUpstreams: SubDnsUpstream[] = [];
  /**
   * 订阅自带的 `nameserver-policy` 条目（[后缀, 上游] 对）。
   * 生成器只写「后缀命中节点域名」的那些（pronetwork 系订阅靠它把入口解析对）。
   */
  subscriptionDnsPolicies: string[][] = [];

  /**
   * 用户当前选中的节点**名**。
   *
   * 隧道与测速核共用同一个（审计 F6：旧实现测速核固定用 subs.nodes[0]，
   * 隧道用用户选中节点 → 两者测的根本不是同一个节点）。
   * 只用「名」而不是节点对象：名是唯一真源，节点对象由节点集反查，避免两份状态。
   */
  selectedNodeName: string = '';

  /**
   * 监听端口：**显式入参**，隧道与测速核各自独立。
   *
   * 审计 F1（高危）：旧实现里测速核的端口探测会写回共享的
   * this.apiPort / this.mixedPort / this.dnsPort → 测速核换了端口，隧道那份
   * YAML 里的端口与客户端 setEndpoint 用的端口就对不上了。
   * 这里**不持有任何共享状态**，端口只从入参来、只随结果回传。
   */
  mixedPort: number = 0;
  apiPort: number = 0;
  dnsPort: number = 0;
  /** controller secret（两种 mode 各自生成、各自独立）。 */
  apiSecret: string = '';

  /** Model.bin 是否就绪（决定能否声明 type: smart 组）。 */
  smartModelReady: boolean = false;
  /** GEOIP 数据是否就绪（缺失时内核启动会联网下载 MMDB 并卡死）。 */
  geoipReady: boolean = false;
  /** 去广告规则集文件是否已落盘（缺失时内核启动会联网下载并卡死）。 */
  ruleProviderFileReady: boolean = false;

  /**
   * 节点域名 → 固定 IP 的快照。
   *
   * **唯一来源**是 RuntimeConfigBuilder.resolveSharedHosts()（DoHResolver 的共享
   * 快照）。留空时 builder 会用同一个来源自行解析一次 —— 不存在第二套来源，
   * 也**不做**「自己解析一套 + 再用隧道结果补洞」那种合并（审计 F10：
   * 两套结果互相补洞 = 两边结果可以不一致 = 分叉）。
   */
  proxyHosts: Record<string, string> = {};

  /**
   * 当前 Profile 的**订阅原文**（FlClash 的 profile yaml 基底）。
   *
   * 非空时 `buildRuntimeConfig` 会在生成 overlay 之后走
   * `ProfileConfigMerger.merge(overlay, profile)`：原文的 proxies / proxy-groups /
   * sub-rules / rules 整体接管，隧道与测速核用同一份 → 与 FlClash 同构。
   * 空串 = 没有 profile（首次导入前/旧数据），保持旧的全量生成行为。
   */
  profileYaml: string = '';
  /**
   * 每 profile 覆盖层（FlClash `Profile.overrides` 的等价物）。
   * 空串 = 回落全局 `settings.yamlOverride`；非空时**只**作用于本 profile。
   * 由 `ConnectionOrchestrator.buildRuntimeProfile` 从 ProfileOverrideStore 注入。
   */
  overrideYaml: string = '';

  /**
   * 当前 Profile 的订阅 id（= FlClash profileId）。
   * FlClash 构建链用它在 provider 缓存目录里隔离各 profile
   * （`<profilesDir>/providers/<id>/<type>/<md5>`）；空串 = 无 profile。
   */
  profileId: string = '';
}

/** 运行决策的结果（连接与测速共享；Smart 按模型状态和订阅作用域决定）。 */
export class RuntimeConfigOptions {
  /** 是否声明内核 smart 组（type: smart）。 */
  useSmart: boolean = false;
  /** 去广告规则集是否可用（已含 adRulesOn 闸门）。 */
  ruleProviderReady: boolean = false;
  /** 去广告总开关是否打开（只看 hyperAdRulesEnabled，与规则引擎解耦）。 */
  adRulesOn: boolean = false;
  /** 是否生成 GEOIP 规则 / dns.fallback。 */
  useGeoip: boolean = false;
  /** 选中的节点名（解析失败时为空串）。 */
  selectedNodeName: string = '';
  /** 选中的节点（解析失败时为 null）。 */
  selectedNode: ProxyNode | null = null;
}

/** 生成结果：YAML 文本 + 本次实际用到的端口/密钥/决策（调用方按此接线）。 */
export class RuntimeConfigResult {
  smartGroupName: string = '';
  /** 最终 YAML（可直接落盘）。 */
  yaml: string = '';
  /** 本次构建的模式（tunnel / test）。 */
  mode: string = '';
  /** 本次 YAML 里用的端口（与 controller setEndpoint 用的端口必须同源）。 */
  mixedPort: number = 0;
  apiPort: number = 0;
  dnsPort: number = 0;
  /** 本次 YAML 里用的 controller secret。 */
  apiSecret: string = '';
  /** 是否启用 TUN（测速核为 false）。 */
  tunEnabled: boolean = false;
  /** hosts 条目数（诊断用）。 */
  hostsCount: number = 0;
  /**
   * 最终配置里由**内核自己加载**的 provider 数（proxy-providers + rule-providers，
   * 不含 inline）。内核启动时同步加载它们，本地没缓存就联网拉、每个最多等 20s ——
   * 启动路径据此向界面说明「内核在加载订阅规则集」，而不是让用户以为卡死。
   */
  providerCount: number = 0;
  /** 本次使用的决策（两种 mode 应完全一致）。 */
  options: RuntimeConfigOptions = new RuntimeConfigOptions();
  /**
   * 最终 YAML 里 PROXY 组**真正排第一**的成员名（2026-10-27）。
   * 用户选中的节点可能被 validNodes 过滤，或被订阅原文覆盖层换掉；钉选必须用
   * 这个名字，否则 PUT /proxies 400 → 「节点选择未生效」。
   */
  effectiveNodeName: string = '';
  /**
   * 规则实际指向的策略组名（2026-10-27 二次修）。
   * 原文接管时它是机场自己起的名字（如 `吹雪云`），**不是** `PROXY`；钉选兜底
   * 要靠它去内核 `/proxies` 里找真实成员。空串 = YAML 里没有可用的策略组。
   */
  ruleGroupName: string = '';
  /**
   * `effectiveNodeName` 是否就是用户所选节点（见 `ConnectionTarget.matched`）。
   * 连接路径据此决定「能不能覆盖内核旧出口」「要不要回写偏好」。
   */
  pinMatched: boolean = false;
}

/** proxy-groups 里一个组的解析结果（成员名已还原 YAML 转义）。 */
class YamlGroupInfo {
  name: string = '';
  type: string = '';
  members: string[] = [];
}

/**
 * 一次连接的**唯一目标描述**（2026-10-27 架构收口）。
 *
 * 旧架构同时维护三套状态：TunBox 节点列表 / `settings.preferredNode*` / 最终 YAML 里的
 * 真实 Group 结构 —— 三者会漂移（真机现场：UI 显示「香港移联01」、内核实际走
 * 「新加坡01aws」，最后报「节点选择未生效」）。现在统一收敛成这一个对象，
 * `source` 明确说明名字是怎么来的，谁都不能再自己"猜"一个节点名：
 *   - `user`   ：用户明确选择，且**在真实主组里严格存在**（可直接 SET）
 *   - `kernel` ：内核 `/proxies` 里该组当前的 `now`（store-selected 持久化，唯一真源）
 *   - `yaml`   ：从最终 YAML 解析得出（含地区自愈 / 组内首个叶子节点）
 */
/**
 * 出口来源（2026-10-27 架构收口：字符串枚举化）。
 *
 * 只允许这几种来源，新增来源必须同时在本枚举与验证脚本里登记：
 * UI/恢复/排查都靠它判断「这个节点名是谁定的、能不能信」。
 */
export enum ConnectionTargetSource {
  /** 从最终 YAML 解析得出（含地区自愈 / 组内首个叶子）。 */
  YAML = 'yaml',
  /** 内核 `/proxies` 里该组当前的 `now`（store-selected 持久化，唯一真源）。 */
  KERNEL = 'kernel',
  /** 用户明确选择，且在真实主组里严格存在。 */
  USER = 'user',
  /** 内核智能选点（mihomo-smart）给出的出口。 */
  AUTO = 'auto',
  /** 进程重启后从持久化会话恢复出来的出口。 */
  RESTORE = 'restore',
  /** 以上都拿不到时的兜底叶子。 */
  FALLBACK = 'fallback'
}

export class ConnectionTarget {
  /** 真实策略组名（规则指向的 select 组，不是硬编码的 PROXY）。 */
  groupName: string = '';
  /** 该组里真实存在、可作为出口的节点名。 */
  nodeName: string = '';
  /** 出口来源（枚举；不再允许随手传字符串）。 */
  source: ConnectionTargetSource = ConnectionTargetSource.YAML;
  /**
   * 确认该出口时生效的 profile id（2026-10-27 强化）。
   * 用途：切订阅后可直接判定「这份出口属于旧 profile」，恢复/重连/排查不必猜。
   */
  profileId: string = '';
  /** 确认该出口的时间戳（ms）。用于日志时序与「多久没重新确认过」。 */
  selectedAt: number = 0;
  /**
   * 确认该出口时 ProfileStore 的 revision（2026-10-27）。
   * 与 `profileId` 配合可判断「这份出口是否还属于当前配置版本」。
   * 取值与 `ProfileRepository.revisionOf()` 同源（内容指纹字符串）。
   */
  profileRevision: string = '';
  /**
   * 产生该出口的连接代数（2026-10-27）。
   * 旧代数的写回（迟到的 /proxies 回报、恢复回调）必须被丢弃，
   * 不能覆盖新一代已经确认的出口。
   */
  generation: number = 0;
  /**
   * 本次解析出的节点是否就是**用户所选的那一个节点**（精确或仅 emoji/标点差异，
   * 2026-10-28 收口）。
   *
   * `false` 只表示两种事实之一：① 用户根本没选（空偏好）；② 配置里找不到所选
   * 节点，下面退回的是「地区自愈 / 组内首个叶子」的替身。
   * 连接路径**必须**靠它区分「用户意图已落地」与「替身」，否则会把替身当成
   * 用户选择写回偏好 —— 真机症状：未连接时选了香港，一连上变成上次的日本节点。
   */
  matched: boolean = false;

  constructor(groupName: string = '', nodeName: string = '',
    source: ConnectionTargetSource = ConnectionTargetSource.YAML,
    profileId: string = '', selectedAt: number = 0,
    profileRevision: string = '', generation: number = 0) {
    this.groupName = groupName;
    this.nodeName = nodeName;
    this.source = source;
    this.profileId = profileId;
    this.selectedAt = selectedAt;
    this.profileRevision = profileRevision;
    this.generation = generation;
  }

  /** 是否属于指定 profile；profileId 为空（历史数据）时视为「不确定」。 */
  belongsTo(profileId: string): boolean {
    if (this.profileId.length === 0 || profileId.length === 0) { return false; }
    return this.profileId === profileId;
  }

  /** 是否与指定 profile 的指定 revision 一致（两者都已知才算一致）。 */
  matchesRevision(profileId: string, revision: string): boolean {
    return this.belongsTo(profileId) && this.profileRevision.length > 0
      && this.profileRevision === revision;
  }

  /** 是否是比 `generation` 更新的出口（用于丢弃迟到写回）。 */
  isNewerThan(generation: number): boolean {
    return this.generation > generation;
  }

  /** 展示用：`组名 → 节点名`；缺组名时只给节点名。 */
  label(): string {
    if (this.groupName.length === 0) { return this.nodeName; }
    if (this.nodeName.length === 0) { return this.groupName; }
    return `${this.groupName} → ${this.nodeName}`;
  }
}

/**
 * 运行时配置构建器：唯一的决策点 + 唯一的生成入口。
 */
export class RuntimeConfigBuilder {
  /** DoH 预解析预算（毫秒）：与既有实现一致（6000ms）。 */
  static readonly DOH_BUDGET_MS: number = 6000;

  /**
   * **唯一的决策点**（审计 F5 / F6）。
   *
   * 运行决策只在这里做一次，两种 mode 共享。
   * Smart 组来自最终 profile；模型按组的 uselightgbm 配置在启动前准备，
   * 不由 App 模式或模型文件存在与否生成策略组。
   *   · ruleProviderReady：**必须含 adRulesOn 闸门** —— 旧实现测速核漏了这个判断
   *     （只判「文件在不在」），于是「去广告开关关闭」时隧道不声明规则集、测速核
   *     却声明 → 两份 YAML 的规则集不一致（审计 F5）。
   *   · selectedNode：两种 mode 用**同一个**（审计 F6）。
   *   · useGeoip：两种 mode 用**同一个**（缺 GEOIP 时内核启动会联网下载 MMDB 卡死）。
   */
  static decideRuntimeOptions(profile: RuntimeConfigProfile): RuntimeConfigOptions {
    const options = new RuntimeConfigOptions();
    const settings = profile.settings;

    options.useSmart = settings.autoSelectMode === AutoSelectModes.AUTO && profile.smartModelReady
      && profile.profileId.length > 0
      && settings.preferredNodeSubscriptionId === profile.profileId;

    // ── ruleProviderReady（含 adRulesOn 闸门，审计 F5）───────────────────────
    // 2026-10-23：adRulesOn 只看去广告开关本体 —— 去广告是独立开关，
    // 不再要求「启用规则路由引擎」也打开（规则引擎关掉时 fallback rules 仍在）。
    const adRulesOn = settings.hyperAdRulesEnabled;
    options.adRulesOn = adRulesOn;
    const ruleProviderReady = adRulesOn && profile.ruleProviderFileReady;
    options.ruleProviderReady = ruleProviderReady;

    // ── useGeoip ────────────────────────────────────────────────────────────
    const useGeoip = profile.geoipReady;
    options.useGeoip = useGeoip;

    // ── selectedNode（两种 mode 共用同一个，审计 F6）─────────────────────────
    const selectedNode = RuntimeConfigBuilder.resolveSelectedNode(profile);
    options.selectedNode = selectedNode;
    options.selectedNodeName = profile.profileYaml.trim().length > 0
      ? profile.selectedNodeName.trim() : (selectedNode === null ? '' : selectedNode.name);
    return options;
  }

  /**
   * 选出本次要用的节点。
   *
   * FlClash 同构（core/proxy.go:39 lookupProxy 精确，§5.5）：用户所选名逐字精确命中
   * 才有效；无命中即如实返回 null（提示「节点未命中」，不推断、不退首个）。
   */
  private static resolveSelectedNode(profile: RuntimeConfigProfile): ProxyNode | null {
    if (profile.nodes.length === 0) {
      return null;
    }
    const wanted = profile.selectedNodeName.trim();
    if (wanted.length === 0) {
      return null;
    }
    for (const node of profile.nodes) {
      if (node.name === wanted) {
        return node;
      }
    }
    AppLogger.warn(TAG, `selected node "${wanted}" not found; no fallback (exact match only)`);
    return null;
  }

  /**
   * **唯一**的 hosts 来源（DoHResolver 共享快照）+ **唯一**的 refreshStale 调用点。
   *
   * 只做两件事，顺序固定：
   *   1. refreshStale()：刷新过期 pin（**全仓只在这里调**）。
   *   2. resolveMany()：按预算补齐未 pin 的域名；已 pin 的直接命中共享快照。
   *
   * 不做任何「结果合并 / 互相补洞」—— 那是分叉的来源（审计 F10）。
   */
  /**
   * 需要 pin 的**节点域名清单**（唯一实现）。
   *
   * 空域名 / IPv6 / 裸 IPv4 不需要 pin；同名域名只留一次（小写去重）。
   * 隧道与测速核共用这一份清单 —— 清单本身也是真源，不能各算各的。
   */
  static proxyServerDomains(nodes: ProxyNode[]): string[] {
    const domains: string[] = [];
    const seen: Set<string> = new Set<string>();
    for (const node of nodes) {
      const server = node.server;
      if (server.length === 0 || server.includes(':') || /^\d+\.\d+\.\d+\.\d+$/.test(server)) {
        continue; // 空 / IPv6 / 裸 IPv4 不需要 pin
      }
      const key = server.toLowerCase();
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      domains.push(key);
    }
    return domains;
  }

  static async resolveSharedHosts(nodes: ProxyNode[],
    priorityDomains: string[] = []): Promise<Record<string, string>> {
    const domains: string[] = RuntimeConfigBuilder.proxyServerDomains(nodes);
    try {
      return await DoHResolver.resolveMany(domains, RuntimeConfigBuilder.DOH_BUDGET_MS, priorityDomains);
    } catch (e) {
      AppLogger.warn(TAG, `proxy-server DoH pre-resolution failed: ${AppLogger.errText(e)}`);
      return {};
    }
  }

  /**
   * 构建运行时配置（**整仓唯一的生成入口**）。
   *
   * @param profile 输入（两种 mode 用**同一个** profile 实例）
   * @param mode RuntimeConfigMode.TUNNEL / RuntimeConfigMode.TEST
   * @returns YAML + 本次实际用到的端口/密钥/决策
   */
  static async buildRuntimeConfig(profile: RuntimeConfigProfile, mode: string): Promise<RuntimeConfigResult> {
    const options = RuntimeConfigBuilder.decideRuntimeOptions(profile);
    // 局部变量刻意不叫 selectedNode：闸门要靠「const selectedNode =」数**决策点**，
    // 这里只是把决策结果取出来用（不是第二次决策）。
    let node = options.selectedNode;
    const profileBacked = profile.profileYaml.trim().length > 0;
    if (node === null && !profileBacked) {
      throw new Error('runtime config: 节点集为空，无法生成配置');
    }

    // The overlay is infrastructure only when a profile supplies all outbounds.
    // This internal placeholder is always removed by the mandatory profile merge.
    const overlayNode = new ProxyNode();
    overlayNode.name = '__tunbox_overlay__';
    overlayNode.proxyType = 'socks5';
    overlayNode.server = '127.0.0.1';
    overlayNode.port = 9;
    if (node === null) { node = overlayNode; }

    // 过期 pin 的刷新全仓只在这一处（审计 F10）：**无论 profile 是否已带快照都刷新一次** ——
    // 否则「带快照的隧道路径」会永远不刷新过期 pin（快照是上一轮的结果）。
    //
    // ⚠ **刻意不 await**：refreshStale 的预算上限是 20s（DoHResolver 默认 budgetMs），
    // 而它在编排器里的定位是「与 resolveMany 并行推进、不额外占用启动时间」
    // （原 ConnectionOrchestrator 的原话）。await 会把这段 DoH 往返拖进配置生成的
    // 关键路径 —— 首连与测速核启动都可能多等几秒（极端 20s），那是纯白等。
    // 刷新照样每次都触发（这才是本条的目的），只是不挡住出配置。
    // DoHResolver 内部有 refreshing 单航班保护，并发调用共享同一个任务。
    if (!profileBacked) { DoHResolver.refreshStale().catch((e: Error): void => {
      AppLogger.info(TAG, `doh stale refresh skipped: ${AppLogger.errText(e)}`);
    }); }
    // hosts：唯一来源。profile 带了快照就直接用（隧道路径会提前解析好以便与
    // 端口探测并行）；没带就用同一个来源解析一次 —— 两条路径都只经过
    // resolveSharedHosts，不存在第二套来源、也不做互相补洞。
    let hosts: Record<string, string> = profileBacked ? {} : profile.proxyHosts;
    if (!profileBacked && Object.keys(hosts).length === 0) {
      const priority: string[] = node.server.length > 0 ? [node.server] : [];
      hosts = await RuntimeConfigBuilder.resolveSharedHosts(profile.nodes, priority);
    }

    // 测速核是 headless 的延迟探测内核：不开 TUN（避免抢设备的 TUN 设备）。
    const tunEnabled = mode !== RuntimeConfigMode.TEST;
    // IPv6 双栈：**唯一**决策点就在这里。生产值来自 settings.ipv6Enabled（设置页开关，
    // 默认开）；缺失/脏值按「开」处理，与 AppSettings.fromJson 的口径一致。
    // 生成器只收这一个布尔，不再自己读设置 —— 隧道与测速核共用同一决策结果。
    const ipv6Enabled: boolean = profile.settings.ipv6Enabled !== false;

    const yaml = ClashConfigGenerator.generate(
      profileBacked ? overlayNode : node, profileBacked ? [overlayNode] : profile.nodes, profile.settings,
      profile.mixedPort, profile.apiPort, profile.dnsPort, profile.apiSecret,
      options.useGeoip, ipv6Enabled, hosts, tunEnabled, profile.proxyGroups,
      options.ruleProviderReady,
      profile.subscriptionRules, profile.subscriptionRuleProviders,
      // 订阅自带 DNS 上游（proxy-server-nameserver / nameserver-policy）：
      // 机场入口域名的真实 IP 只有这些上游知道，不能丢（2026-10-20 全超时定案）。
      profile.subscriptionDnsUpstreams, profile.subscriptionDnsPolicies, !profileBacked);

    // ── FlClash 同构（2026-11-05 全量照抄）：内核解析 → map patch → JSON dump ──
    // FlClash apply 链：`getConfig`（内核解析 profile）→ `_makeRealProfileTask`
    // （map 级 patch）→ 写 config.yaml → 内核 Parse。本仓对应：
    //   1. TunBoxProfileBuilder.build() —— 内核 getProfileBase(profilePath) 解析
    //      profile 原文成 map（mihomo 同一解析器，锚点/类型与最终加载一致）；
    //   2. overlay（生成器产物 = 本仓 patchClashConfig 等价物）经内核 decodeYaml
    //      解成 map，按 FlClash patch 链逐键落在 profile map 上；
    //   3. provider path 收容（任务1）：带 url 的 provider 由 **mihomo 自己拉取**
    //      （global-ua 同 FlClash 单一 UA），App 不再预取/解析 provider；
    //   4. JSON dump（JSON ⊂ YAML，内核 -t 实测通过；等价 FlClash _encodeYaml）。
    // 有 profile 时构建失败必须拒绝，不能把内部占位节点当作用户的有效配置。
    let finalYaml = yaml;
    let builtProfile: TunBoxProfileResult | null = null;
    if (profile.profileYaml.trim().length > 0) {
      if (profile.profileId.length === 0) {
        throw new Error('订阅配置缺少 profile 标识，无法构建 FlClash 同构配置');
      }
      // 每 profile 覆盖优先（FlClash `Profile.overrides`）；否则回落全局 yamlOverride。
      // 这样「只给 A 机场改 DNS」不会波及 B/C（全局覆盖的旧行为会一起改）。
      const effectiveOverride: string = profile.overrideYaml.length > 0
        ? profile.overrideYaml : (profile.settings.yamlOverride ?? '');
      const input = new TunBoxProfileInput();
      input.profileId = profile.profileId;
      input.profilePath = ProfileRepository.pathOf(profile.profileId);
      input.profilesDir = ProfileRepository.dir();
      input.overlayYaml = yaml;
      input.overrideYaml = effectiveOverride;
      input.dnsOverrideEnabled = profile.settings.dnsOverrideEnabled !== false;
      input.tunEnabled = tunEnabled;
      input.ipv6Enabled = ipv6Enabled;
      input.mtu = BASE_MTU;
      input.useSmart = options.useSmart;
      input.smartPolicyPriority = profile.settings.smartPolicyPriority;
      // 测速核不等规则集下载：本地还没缓存的 http 规则集换成同名空 inline
      //（2026-11-11 真机：14 个规则集下载超时，点了测速 21 秒后才开始测）。
      // 测速只打 /proxies/{name}/delay，不走分流规则；隧道不受影响，仍由内核自己拉。
      // 想恢复「测速核也下载规则集」，把这一行改成 false 即可。
      input.skipUncachedRuleProviders = mode === RuntimeConfigMode.TEST;
      const built = await TunBoxProfileBuilder.build(input);
      if (!built.ok) {
        throw new Error(`订阅配置合并失败：${built.error}`);
      }
      builtProfile = built;
      finalYaml = built.yaml;
      AppLogger.info(TAG, `flclash profile built: mode=${mode} applied=${built.applied} `
        + `proxies=${built.profileProxies} groups=${built.profileGroups} rules=${built.profileRules} `
        + `providers=${built.confinedProviders} offlineRuleProviders=${built.offlineRuleProviders} `
        + `bytes=${finalYaml.length}`);
    }

    if (!profile.profileYaml.trim().length) {
      finalYaml = ProfileConfigMerger.enforceTunnelContract(finalYaml, BASE_MTU, ipv6Enabled);
      if (options.useSmart) {
        const input = new TunBoxProfileInput();
        input.useSmart = true;
        input.smartPolicyPriority = profile.settings.smartPolicyPriority;
        builtProfile = await TunBoxProfileBuilder.enhanceStandalone(finalYaml, input);
        if (!builtProfile.ok) { throw new Error(builtProfile.error); }
        finalYaml = builtProfile.yaml;
      }
    }
    const result = new RuntimeConfigResult();
    result.yaml = finalYaml;
    result.mode = mode;
    result.mixedPort = profile.mixedPort;
    result.apiPort = profile.apiPort;
    result.dnsPort = profile.dnsPort;
    result.apiSecret = profile.apiSecret;
    result.tunEnabled = tunEnabled;
    result.hostsCount = Object.keys(hosts).length;
    result.providerCount = builtProfile !== null ? builtProfile.confinedProviders : 0;
    result.options = options;
    // ── 钉选目标解析（2026-10-27 二次修，真机复现后定案）───────────────────
    // 旧实现把主组写死成字符串 PROXY：订阅原文接管后，规则指向
    // 的组名是机场自己起的（本次真机为 `吹雪云`），取不到 → 退回生成器的
    // lastEffectiveNodeName（**旧订阅残留名** `新加坡01aws`）→ 钉选必然失败 →
    // 「节点选择未生效」。而且这份 YAML 里的节点名是 `"\U0001F1ED..."` 转义写法，
    // 不还原转义就永远和内核对不上。这里改为一律从**最终 YAML** 解析：
    //   ① 组名 = 规则真正指向的 select 组（兜底 proxy-groups 首组）；
    //   ② 节点 = 用户所选节点若在该组/该配置里存在就用它，否则按「去 emoji 归一化 /
    //      地区关键词」自愈到组内同名地区的真实节点，再否则取组内首个叶子节点。
    // ── 钉选目标解析（FlClash selectedMap 语义：精确名，无注入、无自愈、无替换）──
    // FlClash 的选点 = 组内成员列表里精确名字（selectedMap[group] = proxyName），
    // 内核 patchSelectGroup/PUT 拒绝不存在的成员时**如实失败**。本仓对齐：
    // 名字来自内核目录（NodeTruth），App 不再「自愈地区关键词 / 补组成员 /
    // 替换首个叶子」（2026-11-05 删除 —— 那些是自造推断，违反「节点准入不做
    // 自有过滤/改名/推断」）。
    let resolvedPin: ConnectionTarget;
    if (builtProfile !== null) {
      resolvedPin = RuntimeConfigBuilder.resolvePinTargetFromProfile(
        builtProfile.groups, builtProfile.rules, builtProfile.proxyNames,
        options.selectedNodeName);
    } else {
      resolvedPin = RuntimeConfigBuilder.resolvePinTarget(finalYaml, options.selectedNodeName);
    }
    result.smartGroupName = builtProfile !== null ? builtProfile.smartGroupName : '';
    result.ruleGroupName = builtProfile !== null && builtProfile.smartParentGroupName.length > 0
      ? builtProfile.smartParentGroupName : resolvedPin.groupName;
    result.yaml = finalYaml;
    result.pinMatched = resolvedPin.matched;
    // provider-only 订阅的组在文本里只有内部占位 outbound（__tunbox_overlay__），
    // 真实节点由 `use: provider` 在运行时注入 —— 这个占位符绝不能当钉选目标。
    const fromGenerator: string = ClashConfigGenerator.lastEffectiveNodeName.startsWith('__')
      ? '' : ClashConfigGenerator.lastEffectiveNodeName;
    result.effectiveNodeName = resolvedPin.nodeName.length > 0
      ? resolvedPin.nodeName
      : (fromGenerator.length > 0 ? fromGenerator : options.selectedNodeName);
    AppLogger.info(TAG, `runtime config built: mode=${mode} bytes=${finalYaml.length} `
      + `hosts=${result.hostsCount} `
      + `ruleProviderReady=${options.ruleProviderReady} useGeoip=${options.useGeoip} `
      + `ipv6=${ipv6Enabled} node="${options.selectedNodeName}" `
      + `group="${result.ruleGroupName}" effective="${result.effectiveNodeName}"`);
    return result;
  }

  /**
   * map 级钉选解析（profile 路径专用；语义与 resolvePinTarget 相同但输入来自
   * TunBoxProfileBuilder 的结构化投影，不再解析 YAML 文本）。
   *
   * 删除项（FlClash 照抄收口）：地区关键词自愈、组内首个叶子替换、
   * 任意叶子兜底、成员注入 —— 选不到就如实 unmatched，由连接路径报错。
   */
  static resolvePinTargetFromProfile(groups: TunBoxGroupInfo[], rules: string[],
    proxies: string[], preferredName: string): ConnectionTarget {
    const out = new ConnectionTarget();
    const groupInfos: YamlGroupInfo[] = [];
    const groupNames: Set<string> = new Set<string>();
    for (const g of groups) {
      const info = new YamlGroupInfo();
      info.name = g.name;
      info.type = g.type;
      info.members = g.members.slice();
      groupInfos.push(info);
      groupNames.add(g.name);
    }
    // The first declared selector is the profile's primary panel. Rules are
    // ordered by traffic matching priority: the first one may target AI or
    // YouTube and must not become the app's default exit group.
    for (const g of groupInfos) {
      if (g.type === 'select' && g.name !== 'GLOBAL') { out.groupName = g.name; break; }
    }
    for (const tgt of rules) {
      if (out.groupName.length > 0) { break; }
      const g: YamlGroupInfo | null = RuntimeConfigBuilder.findGroup(groupInfos, tgt);
      if (g !== null && g.type === 'select') { out.groupName = g.name; break; }
    }
    if (out.groupName.length === 0) {
      for (const tgt of rules) {
        const g: YamlGroupInfo | null = RuntimeConfigBuilder.findGroup(groupInfos, tgt);
        if (g !== null) { out.groupName = g.name; break; }
      }
    }
    if (out.groupName.length === 0 && groupInfos.length > 0) { out.groupName = groupInfos[0].name; }
    // 成员 = 内核 map 里该组的直接成员（providers 动态成员此时还不在静态列表里，
    // 由 providerIntent 分支放行用户所选名——与内核目录对齐后由 PUT 校验）。
    const ruleGroup: YamlGroupInfo | null = out.groupName.length > 0
      ? RuntimeConfigBuilder.findGroup(groupInfos, out.groupName) : null;
    const members: string[] = ruleGroup !== null ? ruleGroup.members : [];
    const preferred: string = preferredName.startsWith('__') ? '' : preferredName.trim();
    out.nodeName = RuntimeConfigBuilder.kernelLeafFor(Array.from(groupNames), preferred);
    if (out.nodeName.length === 0) {
      for (const m of members) {
        if (m === preferred) { out.nodeName = m; break; }
      }
    }
    if (out.nodeName.length === 0 && preferred.length > 0) {
      // provider-only 订阅：所选名在静态 proxies/组里都没有（成员来自 provider）。
      // 放行原名由内核 PUT 校验，绝不替换成别的节点（FlClash 行为）。
      const providerIntent = proxies.length === 0;
      if (providerIntent) { out.nodeName = preferred; }
    }
    out.source = (out.nodeName.length > 0 && out.nodeName === preferred)
      ? ConnectionTargetSource.USER : ConnectionTargetSource.YAML;
    // FlClash 同构：matched 仅当精确名命中用户所选（无归一化等价）。
    out.matched = preferred.length > 0 && out.nodeName === preferred;
    return out;
  }

  // ── 钉选目标解析（2026-10-27 二次修）─────────────────────────────────────

  /**
   * 解析最终 YAML，得出「该钉哪个组的哪个节点」。
   *
   * 三条事实必须一起处理，缺一条就会退回「节点选择未生效」：
   *   ① 组名不一定是 `PROXY` —— 原文接管后是机场自己起的名字，只能从 rules 反查；
   *   ② 用户所选节点名可能是**换机场前的旧名字**（`新加坡01aws` vs `新加坡•移联01`），
   *      直接 PUT 必 400，必须按地区关键词自愈；
   *   ③ YAML 里的名字是 `"\U0001F1F8..."` 转义写法，必须还原成内核里的真实字符串，
   *      否则拿去和 `/proxies` 比对永远不相等。
   */
  static resolvePinTarget(yaml: string, preferredName: string): ConnectionTarget {
    const out = new ConnectionTarget();
    const groups: YamlGroupInfo[] = RuntimeConfigBuilder.parseProxyGroups(yaml);
    const rules: string[] = RuntimeConfigBuilder.parseRuleTargets(yaml);
    const proxies: string[] = RuntimeConfigBuilder.parseProxyNames(yaml);
    const groupNames: Set<string> = new Set<string>();
    for (const g of groups) { groupNames.add(g.name); }

    // The first declared selector is the profile's primary panel. Rules are
    // ordered by traffic matching priority: the first one may target AI or
    // YouTube and must not become the app's default exit group.
    for (const g of groups) {
      if (g.type === 'select' && g.name !== 'GLOBAL') { out.groupName = g.name; break; }
    }
    for (const tgt of rules) {
      if (out.groupName.length > 0) { break; }
      const g: YamlGroupInfo | null = RuntimeConfigBuilder.findGroup(groups, tgt);
      if (g !== null && g.type === 'select') { out.groupName = g.name; break; }
    }
    if (out.groupName.length === 0) {
      for (const tgt of rules) {
        const g: YamlGroupInfo | null = RuntimeConfigBuilder.findGroup(groups, tgt);
        if (g !== null) { out.groupName = g.name; break; }
      }
    }
    if (out.groupName.length === 0 && groups.length > 0) { out.groupName = groups[0].name; }
    const ruleGroup: YamlGroupInfo | null = out.groupName.length > 0
      ? RuntimeConfigBuilder.findGroup(groups, out.groupName) : null;
    const members: string[] = ruleGroup !== null ? ruleGroup.members : [];

    // FlClash 语义（2026-11-05 收口）：精确命中（含归一化名等价）→ 找不到就如实
    // unmatched。地区关键词自愈、组内首叶子替换、任意叶子兜底、信息条目过滤
    // 一律删除 —— 那些是自造推断；选不到由连接路径报错，绝不替用户挑节点。
    const preferred: string = preferredName.startsWith('__') ? '' : preferredName.trim();
    // A selected child strategy is a valid target, with its own selection and
    // policy. It must not be replaced by the first static leaf (often Direct).
    out.nodeName = RuntimeConfigBuilder.kernelLeafFor(Array.from(groupNames), preferred);
    if (out.nodeName.length === 0) {
      for (const m of members) {
        if (m === preferred) { out.nodeName = m; break; }
      }
    }
    if (out.nodeName.length === 0 && preferred.length > 0) {
      // provider 成员：所选名不在静态 proxies/组里（成员来自 provider 拉取）。
      // 配置声明了 proxy-providers 即放行原名，由内核 PUT 校验，绝不替换
      // （FlClash 的 provider 成员选点同此形态）。
      const providerIntent = RuntimeConfigBuilder.splitYamlLines(yaml).some((line: string): boolean =>
        line === 'proxy-providers:');
      if (providerIntent) { out.nodeName = preferred; }
    }
    out.source = (out.nodeName.length > 0 && out.nodeName === preferred)
      ? ConnectionTargetSource.USER : ConnectionTargetSource.YAML;
    // FlClash 同构：matched 仅当精确名命中用户所选（无归一化等价）。
    out.matched = preferred.length > 0 && out.nodeName === preferred;
    return out;
  }

  /**
   * 在**内核**给回的成员名单里找用户所选节点（FlClash 同构：精确名匹配）。
   *
   * `core/proxy.go:39 lookupProxy` 精确：App 不做归一化、不猜组、不首个回退。
   * 找不到返回空串，由调用方提示「节点未命中」。
   */
  static kernelLeafFor(members: string[], preferred: string): string {
    const want: string = preferred.trim();
    if (want.length === 0 || members.length === 0) { return ''; }
    for (const m of members) {
      if (m === want) { return m; }
    }
    return '';
  }

  /** 顶层 `proxies:` 里是否存在该节点；返回 YAML 里的真实写法（精确名匹配）。 */
  static proxyNameInYaml(yaml: string, preferred: string): string {
    const want: string = preferred.trim();
    if (want.length === 0) { return ''; }
    const names: string[] = RuntimeConfigBuilder.parseProxyNames(yaml);
    for (const n of names) {
      if (n === want) { return n; }
    }
    return '';
  }

  private static isInfoOrGroup(name: string, groupNames: Set<string>): boolean {
    if (name.length === 0 || name.startsWith('__')) { return true; }
    if (groupNames.has(name)) { return true; }
    return name.indexOf('剩余') >= 0 || name.indexOf('到期') >= 0;
  }

  /**
   * 去 emoji / 分隔符 / 大小写差异后的比较键（只保留 ASCII 字母数字与 CJK）。
   * 注（§5.5）：选点已不再用此键做匹配（FlClash 精确名）；仅保留供外部/诊断使用。
   */
  static nodeKey(raw: string): string {
    let out: string = '';
    for (let i = 0; i < raw.length; i++) {
      const c: number = raw.charCodeAt(i);
      const isDigit: boolean = c >= 0x30 && c <= 0x39;
      const isUpper: boolean = c >= 0x41 && c <= 0x5A;
      const isLower: boolean = c >= 0x61 && c <= 0x7A;
      const isCjk: boolean = (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF);
      if (isDigit || isCjk) { out += raw.charAt(i); continue; }
      if (isUpper) { out += String.fromCharCode(c + 32); continue; }
      if (isLower) { out += raw.charAt(i); }
    }
    return out;
  }

  /** 抽出 2 字及以上的中文串（地区关键词），长的优先。 */
  private static cjkRuns(raw: string): string[] {
    const runs: string[] = [];
    let cur: string = '';
    for (let i = 0; i < raw.length; i++) {
      const c: number = raw.charCodeAt(i);
      const isCjk: boolean = (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF);
      if (isCjk) { cur += raw.charAt(i); continue; }
      if (cur.length >= 2) { runs.push(cur); }
      cur = '';
    }
    if (cur.length >= 2) { runs.push(cur); }
    runs.sort((a: string, b: string): number => b.length - a.length);
    return runs;
  }

  private static findGroup(groups: YamlGroupInfo[], name: string): YamlGroupInfo | null {
    for (const g of groups) {
      if (g.name === name) { return g; }
    }
    return null;
  }

  /** 解析 `proxy-groups:` 段：组名、类型、成员（名字已还原转义）。 */
  static parseProxyGroups(yaml: string): YamlGroupInfo[] {
    const out: YamlGroupInfo[] = [];
    const lines: string[] = RuntimeConfigBuilder.splitYamlLines(yaml);
    let inSection: boolean = false;
    let collecting: boolean = false;
    let cur: YamlGroupInfo | null = null;
    for (const raw of lines) {
      const t: string = raw.trim();
      if (!inSection) {
        if (t === 'proxy-groups:' && raw.length === t.length) { inSection = true; }
        continue;
      }
      if (t.length === 0) { continue; }
      if (raw.charAt(0) !== ' ' && raw.charAt(0) !== '\t' && raw.charAt(0) !== '-') { break; }
      if (t.startsWith('- ')) {
        if (collecting && cur !== null) {
          cur.members.push(RuntimeConfigBuilder.unquoteYaml(t.substring(2).trim()));
          continue;
        }
        cur = new YamlGroupInfo();
        out.push(cur);
        const rest: string = t.substring(2);
        if (rest.startsWith('name:')) {
          cur.name = RuntimeConfigBuilder.unquoteYaml(rest.substring(5).trim());
        }
        continue;
      }
      if (cur === null) { continue; }
      if (t === 'proxies:') { collecting = true; continue; }
      if (t.startsWith('name:')) {
        cur.name = RuntimeConfigBuilder.unquoteYaml(t.substring(5).trim());
        collecting = false;
        continue;
      }
      if (t.startsWith('type:')) {
        cur.type = RuntimeConfigBuilder.decodeYamlEscapes(t.substring(5).trim());
        collecting = false;
        continue;
      }
      collecting = false;
    }
    return out;
  }

  /** 解析顶层 `proxies:` 段里的节点名（已还原转义）。 */
  static parseProxyNames(yaml: string): string[] {
    const out: string[] = [];
    const lines: string[] = RuntimeConfigBuilder.splitYamlLines(yaml);
    let inSection: boolean = false;
    for (const raw of lines) {
      const t: string = raw.trim();
      if (!inSection) {
        if (t === 'proxies:' && raw.length === t.length) { inSection = true; }
        continue;
      }
      if (t.length === 0) { continue; }
      if (raw.charAt(0) !== ' ' && raw.charAt(0) !== '\t') { break; }
      if (t.startsWith('- name:')) {
        out.push(RuntimeConfigBuilder.unquoteYaml(t.substring(7).trim()));
        continue;
      }
      if (t.startsWith('name:')) {
        out.push(RuntimeConfigBuilder.unquoteYaml(t.substring(5).trim()));
      }
    }
    return out;
  }

  /** 解析 `rules:` 段里每条规则的**目标**（最后一段），并还原转义。 */
  static parseRuleTargets(yaml: string): string[] {
    const out: string[] = [];
    const lines: string[] = RuntimeConfigBuilder.splitYamlLines(yaml);
    let inSection: boolean = false;
    for (const raw of lines) {
      const t: string = raw.trim();
      if (!inSection) {
        if (t === 'rules:' && raw.length === t.length) { inSection = true; }
        continue;
      }
      if (t.length === 0) { continue; }
      if (raw.charAt(0) !== ' ' && raw.charAt(0) !== '\t' && raw.charAt(0) !== '-') { break; }
      if (!t.startsWith('- ')) { continue; }
      const body: string = RuntimeConfigBuilder.decodeYamlEscapes(t.substring(2).trim());
      const parts: string[] = body.split(',');
      if (parts.length < 2) { continue; }
      const target: string = RuntimeConfigBuilder.unquoteYaml(parts[parts.length - 1].trim());
      if (target.length > 0) { out.push(target); }
    }
    return out;
  }

  /** 还原 YAML 双引号标量转义：`\U0001F1F8` `\uXXXX` `\xXX` `\"` `\\` `\n` `\t`。 */
  static decodeYamlEscapes(s: string): string {
    if (s.indexOf('\\') < 0) { return s; }
    let out: string = '';
    let i: number = 0;
    while (i < s.length) {
      const c: string = s.charAt(i);
      if (c !== '\\' || i + 1 >= s.length) { out += c; i++; continue; }
      const n: string = s.charAt(i + 1);
      if (n === 'U' && i + 9 < s.length) {
        const cp: number = RuntimeConfigBuilder.hexValue(s.substring(i + 2, i + 10));
        if (cp >= 0) { out += RuntimeConfigBuilder.codePointToString(cp); i += 10; continue; }
      }
      if (n === 'u' && i + 5 < s.length) {
        const cp: number = RuntimeConfigBuilder.hexValue(s.substring(i + 2, i + 6));
        if (cp >= 0) { out += String.fromCharCode(cp); i += 6; continue; }
      }
      if (n === 'x' && i + 3 < s.length) {
        const cp: number = RuntimeConfigBuilder.hexValue(s.substring(i + 2, i + 4));
        if (cp >= 0) { out += String.fromCharCode(cp); i += 4; continue; }
      }
      if (n === 'n') { out += '\n'; i += 2; continue; }
      if (n === 't') { out += '\t'; i += 2; continue; }
      if (n === 'r') { out += '\r'; i += 2; continue; }
      out += n; // \" \\ \/ 等一律还原成字符本身
      i += 2;
    }
    return out;
  }

  private static codePointToString(cp: number): string {
    if (cp <= 0xFFFF) { return String.fromCharCode(cp); }
    const v: number = cp - 0x10000;
    return String.fromCharCode(0xD800 + (v >> 10)) + String.fromCharCode(0xDC00 + (v & 0x3FF));
  }

  /** 严格十六进制解析：任何非 hex 字符都返回 -1（ArkTS 下不依赖 isNaN）。 */
  private static hexValue(s: string): number {
    let v: number = 0;
    for (let i = 0; i < s.length; i++) {
      const c: number = s.charCodeAt(i);
      let d: number = -1;
      if (c >= 0x30 && c <= 0x39) { d = c - 0x30; }
      else if (c >= 0x41 && c <= 0x46) { d = c - 0x37; }
      else if (c >= 0x61 && c <= 0x66) { d = c - 0x57; }
      if (d < 0) { return -1; }
      v = v * 16 + d;
    }
    return v;
  }

  /**
   * 行切分（**去 CRLF**）。真机 `mihomo_config.yaml` 是 CRLF 行尾（实测 1062 行
   * 1062 个 `\r`）；旧实现用 `raw.length === t.length` 判「顶层键」，在 CRLF 下永远
   * 不成立 → `firstProxyMember` 恒返回空 → 钉选退回生成器旧名字 →「节点选择未生效」。
   */
  private static splitYamlLines(yaml: string): string[] {
    const parts: string[] = yaml.split('\n');
    const out: string[] = [];
    for (const p of parts) {
      out.push(p.length > 0 && p.charCodeAt(p.length - 1) === 0x0D
        ? p.substring(0, p.length - 1) : p);
    }
    return out;
  }

  private static unquoteYaml(raw: string): string {
    let s: string = raw;
    if (s.length >= 2 && s.charAt(0) === '"' && s.charAt(s.length - 1) === '"') {
      s = s.substring(1, s.length - 1);
    }
    return RuntimeConfigBuilder.decodeYamlEscapes(s);
  }
}
