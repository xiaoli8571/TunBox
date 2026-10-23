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
    const node = options.selectedNode;
    if (node === null) {
      throw new Error('runtime config: 节点集为空，无法生成配置');
    }

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
      node, profile.nodes, profile.settings,
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
    // 原文段整体替换进来；原文 dns.enable=true 时整段 dns 用原文。
    // 合并失败（原文为空或没有代理定义）→ 保持 overlay，不阻断连接。
    let finalYaml = yaml;
    if (profile.profileYaml.trim().length > 0) {
      const merged = ProfileConfigMerger.merge(yaml, profile.profileYaml);
      if (merged.ok) {
        finalYaml = merged.yaml;
        AppLogger.info(TAG, `profile merged: mode=${mode} applied=${merged.applied} `
          + `items=${merged.profileProxyItems} bytes=${finalYaml.length}`);
      } else {
        AppLogger.warn(TAG, `profile merge skipped: ${merged.error}`);
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
    AppLogger.info(TAG, `runtime config built: mode=${mode} bytes=${finalYaml.length} `
      + `hosts=${result.hostsCount} useSmart=${options.useSmart} `
      + `ruleProviderReady=${options.ruleProviderReady} useGeoip=${options.useGeoip} `
      + `ipv6=${ipv6Enabled} node="${options.selectedNodeName}"`);
    return result;
  }
}
