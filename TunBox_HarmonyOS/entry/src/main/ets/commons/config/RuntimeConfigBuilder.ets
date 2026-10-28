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
 * 2. 四个决策（useSmart / ruleProviderReady / selectedNode / useGeoip）
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
 *   （播种 seedSmartModelFromRawfile() 仍可保留在编排器里，但「要不要用 smart 组」
 *     的**判定**只在 builder 里做一次 —— 这里只给「事实」）
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
import { LatencyTestUrl } from '../latency/LatencyTestUrl';
import { DoHResolver } from '../services/DoHResolver';
// 订阅原文 → overlay 合并（FlClash mergeProfileBase 的等价实现）
import { ProfileConfigMerger } from '../flclash/ProfileConfigMerger';
import { AppLogger } from '../utils/AppLogger';

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
}

/** 四个决策的结果（两种 mode 共享同一份）。 */
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
   * 四个决策只在这里做一次，两种 mode 共享：
   *   · useSmart：自动模式 **且** Model.bin 就绪 —— 缺模型时若仍声明 smart 组，
   *     内核 GetModel() 会在启动路径同步下载 Model.bin（实测阻塞 90s）。
   *   · ruleProviderReady：**必须含 adRulesOn 闸门** —— 旧实现测速核漏了这个判断
   *     （只判「文件在不在」），于是「去广告开关关闭」时隧道不声明规则集、测速核
   *     却声明 → 两份 YAML 的规则集不一致（审计 F5）。
   *   · selectedNode：两种 mode 用**同一个**（审计 F6）。
   *   · useGeoip：两种 mode 用**同一个**（缺 GEOIP 时内核启动会联网下载 MMDB 卡死）。
   */
  static decideRuntimeOptions(profile: RuntimeConfigProfile): RuntimeConfigOptions {
    const options = new RuntimeConfigOptions();
    const settings = profile.settings;

    // ── useSmart ────────────────────────────────────────────────────────────
    const useSmart = settings.autoSelectMode === AutoSelectModes.AUTO && profile.smartModelReady;
    options.useSmart = useSmart;

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
    options.selectedNodeName = selectedNode === null ? '' : selectedNode.name;
    return options;
  }

  /**
   * 选出本次要用的节点。
   *
   * 口径：优先用户选中的节点（按名精确匹配 → 忽略大小写匹配），
   * 都没有则退回节点集第一个；节点集为空则返回 null（由调用方报错，不静默生成空配置）。
   */
  private static resolveSelectedNode(profile: RuntimeConfigProfile): ProxyNode | null {
    if (profile.nodes.length === 0) {
      return null;
    }
    const wanted = profile.selectedNodeName.trim();
    if (wanted.length > 0) {
      for (const node of profile.nodes) {
        if (node.name === wanted) {
          return node;
        }
      }
      const lower = wanted.toLowerCase();
      for (const node of profile.nodes) {
        if (node.name.toLowerCase() === lower) {
          return node;
        }
      }
      AppLogger.warn(TAG, `selected node "${wanted}" not in node set; fallback to first node`);
    }
    return profile.nodes[0];
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
    DoHResolver.refreshStale().catch((e: Error): void => {
      AppLogger.info(TAG, `doh stale refresh skipped: ${AppLogger.errText(e)}`);
    });
    // hosts：唯一来源。profile 带了快照就直接用（隧道路径会提前解析好以便与
    // 端口探测并行）；没带就用同一个来源解析一次 —— 两条路径都只经过
    // resolveSharedHosts，不存在第二套来源、也不做互相补洞。
    let hosts: Record<string, string> = profile.proxyHosts;
    if (Object.keys(hosts).length === 0) {
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
      options.ruleProviderReady, options.useSmart,
      profile.subscriptionRules, profile.subscriptionRuleProviders,
      // smart 组的测速地址：这里只传**用户填的原始值**，规则由生成器侧的
      // LatencyTestUrl.effective()（唯一真源）统一处理（审计 F12）。
      profile.settings.testLatencyUrl,
      // 订阅自带 DNS 上游（proxy-server-nameserver / nameserver-policy）：
      // 机场入口域名的真实 IP 只有这些上游知道，不能丢（2026-10-20 全超时定案）。
      profile.subscriptionDnsUpstreams, profile.subscriptionDnsPolicies);

    // ── FlClash 同构：订阅原文接管 proxies / proxy-groups / rules / dns ──────
    // overlay（上面生成的 yaml）只保留运行期参数（端口 / secret / tun / mode 等），
    // 原文代理/规则段整体替换；DNS 覆写开启时保留应用 DNS，关闭时采用订阅 DNS。
    // 有原文时合并失败必须拒绝，不能把内部占位节点当作用户的有效配置。
    let finalYaml = yaml;
    if (profile.profileYaml.trim().length > 0) {
      const merged = ProfileConfigMerger.merge(yaml, profile.profileYaml,
        profile.settings.dnsOverrideEnabled === false);
      if (merged.ok) {
        finalYaml = merged.yaml;
        AppLogger.info(TAG, `profile merged: mode=${mode} applied=${merged.applied} `
          + `items=${merged.profileProxyItems} bytes=${finalYaml.length}`);
        // ── smart 组注入（2026-10-25 定案）────────────────────────────
        // 原文接管模式下生成器的 ♻️ smart 组会被原文 proxy-groups 整段顶掉，
        // 自动模式在真实订阅上从未生效。这里把 smart 组接回分流结构：
        // 追加组定义（成员=原文自己的节点名，天然单订阅）+ 主选择组首位插入。
        // 注入失败（无 MATCH/主组非 select/纯 provider 订阅）只降级不报错——
        // 自动模式回落为钉选具体节点，与历史行为一致。
        if (mode === RuntimeConfigMode.TUNNEL && options.useSmart
          && profile.settings.autoSelectMode === AutoSelectModes.AUTO) {
          const smartUrl: string = LatencyTestUrl.effective(profile.settings.testLatencyUrl);
          const smartHead: string[] = [
            `  - name: "${ClashConfigGenerator.SMART_GROUP_NAME}"`,
            '    type: smart',
            '    uselightgbm: true',
            '    collectdata: false',
            '    prefer-asn: false',
            `    url: "${ClashConfigGenerator.escapeYaml(smartUrl)}"`,
            `    exclude-filter: "${ClashConfigGenerator.escapeYaml(ClashConfigGenerator.SMART_INFO_NODE_FILTER)}"`
          ];
          const priority: string = (profile.settings.smartPolicyPriority ?? '').trim();
          if (priority.length > 0) {
            smartHead.push(`    policy-priority: "${ClashConfigGenerator.escapeYaml(priority)}"`);
          }
          const injected = ProfileConfigMerger.injectSmartPrimary(
            finalYaml, ClashConfigGenerator.SMART_GROUP_NAME, smartHead);
          if (injected.ok) {
            finalYaml = injected.yaml;
            AppLogger.info(TAG, `smart group injected: ${injected.reason}`);
          } else {
            AppLogger.warn(TAG, `smart group injection skipped: ${injected.reason}`);
          }
        }
      } else {
        throw new Error(`订阅配置合并失败：${merged.error}`);
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
    let resolvedPin: ConnectionTarget = RuntimeConfigBuilder.resolvePinTarget(
      finalYaml, options.selectedNodeName);
    // ── 用户意图落地闸门（2026-10-28 收口）───────────────────────────────────
    // 机场组常只把一部分节点列进主选择组（因为「没列进去的节点不该让用户选」不是
    // 我们的产品口径）。此时用户在 App 里选得到、YAML 里 proxies 也有，但组的成员
    // 表里没有它 → 钉选 PUT 必 400 → 旧实现静默换成组内首个叶子（真机：香港 → 日本）。
    // 现在先把该节点补进规则组首位，让它成为**可钉的真实成员**；补不进去才降级。
    if (!resolvedPin.matched && resolvedPin.groupName.length > 0) {
      const yamlName: string = RuntimeConfigBuilder.proxyNameInYaml(finalYaml,
        options.selectedNodeName);
      if (yamlName.length > 0) {
        const inj = ProfileConfigMerger.ensureGroupMember(finalYaml, resolvedPin.groupName, yamlName);
        if (inj.ok) {
          finalYaml = inj.yaml;
          resolvedPin = RuntimeConfigBuilder.resolvePinTarget(finalYaml, yamlName);
          AppLogger.info(TAG, `selected node injected into group "${resolvedPin.groupName}": `
            + `"${yamlName}" (${inj.reason})`);
        } else {
          AppLogger.warn(TAG, `selected node "${yamlName}" not injectable into group `
            + `"${resolvedPin.groupName}": ${inj.reason}`);
        }
      }
    }
    result.ruleGroupName = resolvedPin.groupName;
    result.pinMatched = resolvedPin.matched;
    // provider-only 订阅的组在文本里只有内部占位 outbound（__tunbox_overlay__），
    // 真实节点由 `use: provider` 在运行时注入 —— 这个占位符绝不能当钉选目标。
    const fromGenerator: string = ClashConfigGenerator.lastEffectiveNodeName.startsWith('__')
      ? '' : ClashConfigGenerator.lastEffectiveNodeName;
    result.effectiveNodeName = resolvedPin.nodeName.length > 0
      ? resolvedPin.nodeName
      : (fromGenerator.length > 0 ? fromGenerator : options.selectedNodeName);
    AppLogger.info(TAG, `runtime config built: mode=${mode} bytes=${finalYaml.length} `
      + `hosts=${result.hostsCount} useSmart=${options.useSmart} `
      + `ruleProviderReady=${options.ruleProviderReady} useGeoip=${options.useGeoip} `
      + `ipv6=${ipv6Enabled} node="${options.selectedNodeName}" `
      + `group="${result.ruleGroupName}" effective="${result.effectiveNodeName}"`);
    return result;
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

    // ① 规则指向的 select 组（真正的用户可见选择组）；找不到就退首个组。
    for (const tgt of rules) {
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

    // ②③ 依次尝试：**规则组直连成员优先**（订阅里常有 PROXY/GLOBAL/自动选择/故障转移
    // 多个分组，只有直连成员能被 SET 到），再退到全量 proxies：
    // 精确命中 → 归一化命中 → 地区关键词命中 → 组内首个叶子节点 → 任意叶子节点。
    const preferred: string = preferredName.startsWith('__') ? '' : preferredName.trim();
    out.nodeName = RuntimeConfigBuilder.pickExisting(members, groupNames, preferred, true);
    if (out.nodeName.length === 0) {
      out.nodeName = RuntimeConfigBuilder.pickExisting(proxies, groupNames, preferred, true);
    }
    if (out.nodeName.length === 0) {
      // 组里第一个**真节点**（跳过策略组与「剩余流量/到期」信息条目）。
      for (const m of members) {
        if (RuntimeConfigBuilder.isInfoOrGroup(m, groupNames)) { continue; }
        out.nodeName = m;
        break;
      }
    }
    if (out.nodeName.length === 0) {
      for (const p of proxies) {
        if (RuntimeConfigBuilder.isInfoOrGroup(p, groupNames)) { continue; }
        out.nodeName = p;
        break;
      }
    }
    // 来源标注：与用户所选**逐字节相同**才算 user；地区自愈/组内首叶子都算 yaml。
    out.source = (out.nodeName.length > 0 && out.nodeName === preferred)
      ? ConnectionTargetSource.USER : ConnectionTargetSource.YAML;
    // 「是不是同一个节点」按归一化名判（emoji / 空格 / 分隔符差异不算换节点）。
    // 地区自愈（`新加坡01aws` → `🇸🇬新加坡•移联01`）与组内首叶子**一律不算**：
    // 它们是替身，不能让连接路径以为用户意图已经落地。
    const wantKey: string = RuntimeConfigBuilder.nodeKey(preferred);
    out.matched = wantKey.length > 0
      && RuntimeConfigBuilder.nodeKey(out.nodeName) === wantKey;
    return out;
  }

  /**
   * 在**内核**给回的成员名单里找用户所选节点（精确 → 归一化）。
   *
   * 为什么要单独一个函数（2026-10-28 真机定案）：连接路径旧实现用
   * `leaf === target.name` **逐字节**比较内核成员名，App 侧名字与内核名只要差一个
   * emoji/空格就判「不是这个节点」，于是走进「认内核旧出口」分支 —— 用户看到的
   * 就是「未连接时选了香港、一连接又变回上次那个节点」。
   *
   * 返回**内核里的真实名字**（PUT 必须用这个名字），找不到返回空串。
   */
  static kernelLeafFor(members: string[], preferred: string): string {
    const want: string = preferred.trim();
    if (want.length === 0 || members.length === 0) { return ''; }
    for (const m of members) {
      if (m === want) { return m; }
    }
    const key: string = RuntimeConfigBuilder.nodeKey(want);
    if (key.length === 0) { return ''; }
    for (const m of members) {
      if (RuntimeConfigBuilder.nodeKey(m) === key) { return m; }
    }
    return '';
  }

  /** 顶层 `proxies:` 里是否存在该节点；返回 YAML 里的真实写法（精确 → 归一化）。 */
  static proxyNameInYaml(yaml: string, preferred: string): string {
    const want: string = preferred.trim();
    if (want.length === 0) { return ''; }
    const names: string[] = RuntimeConfigBuilder.parseProxyNames(yaml);
    for (const n of names) {
      if (n === want) { return n; }
    }
    const key: string = RuntimeConfigBuilder.nodeKey(want);
    if (key.length === 0) { return ''; }
    for (const n of names) {
      if (RuntimeConfigBuilder.nodeKey(n) === key) { return n; }
    }
    return '';
  }

  /** 在候选名集合里找用户意图对应的真实节点（精确 / 归一化 / 地区关键词三级）。 */
  private static pickExisting(pool: string[], groupNames: Set<string>, preferred: string,
    leafOnly: boolean): string {
    if (pool.length === 0 || preferred.length === 0) { return ''; }
    for (const name of pool) {
      if (leafOnly && RuntimeConfigBuilder.isInfoOrGroup(name, groupNames)) { continue; }
      if (name === preferred) { return name; }
    }
    const wantKey: string = RuntimeConfigBuilder.nodeKey(preferred);
    if (wantKey.length === 0) { return ''; }
    for (const name of pool) {
      if (leafOnly && RuntimeConfigBuilder.isInfoOrGroup(name, groupNames)) { continue; }
      if (RuntimeConfigBuilder.nodeKey(name) === wantKey) { return name; }
    }
    // 地区关键词：`新加坡01aws` → 新加坡 ；`hy2台湾1` → 台湾
    const runs: string[] = RuntimeConfigBuilder.cjkRuns(preferred);
    for (const region of runs) {
      for (const name of pool) {
        if (leafOnly && RuntimeConfigBuilder.isInfoOrGroup(name, groupNames)) { continue; }
        if (RuntimeConfigBuilder.nodeKey(name).indexOf(region) >= 0) { return name; }
      }
    }
    return '';
  }

  private static isInfoOrGroup(name: string, groupNames: Set<string>): boolean {
    if (name.length === 0 || name.startsWith('__')) { return true; }
    if (groupNames.has(name)) { return true; }
    return name.indexOf('剩余') >= 0 || name.indexOf('到期') >= 0;
  }

  /** 去 emoji / 分隔符 / 大小写差异后的比较键（只保留 ASCII 字母数字与 CJK）。 */
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
