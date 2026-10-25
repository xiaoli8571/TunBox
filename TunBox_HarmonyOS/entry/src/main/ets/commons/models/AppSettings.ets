/**
 * 数据模型：应用设置
 * 移植自 upstream: packages/tunbox_shared/lib/models/app_settings.dart
 * 字段与 upstream 保持一致；鸿蒙端持久化由 SettingsService（@ohos.data.preferences）承担。
 */
import { NodeSortModes } from '../services/NodeSortPersistence';
import { LatencyTestUrl } from '../latency/LatencyTestUrl';
import { AppRoutingCustomApp, AppRoutingPolicy } from '../services/AppRoutingPolicy';

/** 自动选点模式（第二阶段新增，语义同 NodeSortModes 风格） */
export class AutoSelectModes {
  /** 手动：使用用户在上一次连接/偏好中固定的节点（默认） */
  static readonly MANUAL: string = 'manual';
  /** 自动：按 SmartSelector 评分自动选点，失败达阈值时自动切换 */
  static readonly AUTO: string = 'auto';

  /** 归一化任意输入为合法模式，未知/缺省值一律回退 MANUAL */
  static normalize(mode: string | undefined): string {
    if (mode === AutoSelectModes.AUTO) {
      return AutoSelectModes.AUTO;
    }
    return AutoSelectModes.MANUAL;
  }
}

/** 整数夹取：缺失/非法（非有限数）取默认值，越界夹到 [min,max] */
function clampInt(v: number, def: number, min: number, max: number): number {
  if (typeof v !== 'number' || !Number.isFinite(v)) {
    return def;
  }
  const i = Math.floor(v);
  if (i < min) {
    return min;
  }
  if (i > max) {
    return max;
  }
  return i;
}

/** 自定义远程规则集条目（P1-2，对标 iOS 六家 RULE-SET/rule-provider 能力） */
export class CustomRuleSet {
  /** 规则集键（YAML provider 名），[a-z0-9_-]，生成器加 rs- 前缀防与内置冲突 */
  name: string = '';
  /** 远程 URL（https） */
  url: string = '';
  /** mihomo behavior: domain / ipcidr / classical */
  behavior: string = 'domain';
  /** 文件格式: yaml / text / mrs */
  format: string = 'yaml';
  /** 命中后策略: DIRECT / PROXY / REJECT */
  policy: string = 'REJECT';
  /** 自动更新间隔秒（最小 3600） */
  interval: number = 86400;
}

/** 持久化 JSON 形状（显式类，满足 arkts-no-untyped-obj-literals） */
export class AppSettingsJson {
  themeMode: number = 0;
  autoConnectOnBoot: boolean = true;
  bypassDomesticApps: boolean = true;
  excludedApps: string[] = [];
  includedApps: string[] = [];
  /** 缺失值必须保持 undefined，不能让默认 all 遮蔽旧数据迁移。 */
  appRoutingMode: string | undefined = undefined;
  appRoutingNeedsReview: boolean = false;
  appRoutingCustomApps: AppRoutingCustomApp[] = [];
  /**
   * 已被用户从「应用分流」目录里删除的**预置**包名（2026-10-18 用户要求：
   * 自带包名也要能删）。预置列表是代码里的常量、rebuild() 每次都会重新加入，
   * 所以必须单独记一份"用户已删除"的名单，否则删掉后立刻又冒出来。
   */
  appRoutingRemovedPresets: string[] = [];
  forceProxySites: string[] = [];
  forceDirectSites: string[] = [];
  /**
   * 强制拦截网站（P0-3 DNS 层 REJECT 预匹配）：生成 `nameserver-policy` 的
   * `rcode://refused` 条目 + 路由层 DOMAIN-SUFFIX,site,REJECT，广告/追踪域名
   * 在 DNS 层就被拒绝（不建立连接、不发出明文 QNAME），比仅路由层 REJECT
   * 少一次完整连接尝试。旧配置缺失时为空数组（行为不变）。
   */
  forceBlockSites: string[] = [];
  preferredNodeId: string = '';
  preferredNodeSubscriptionId: string = '';
  /** 偏好节点的名字快照：订阅重解析按位置重排 id 时用于重锚（冷启动不丢手动选择） */
  preferredNodeName: string = '';
  autoUpdateSubscription: boolean = true;
  selectedSubscriptionId: string = '';
  testLatencyUrl: string = LatencyTestUrl.DEFAULT_URL;
  proxyMode: string = 'rule';
  /** 节点列表排序模式: 'default' 订阅默认顺序 / 'auto' 按最近测速结果 / 'manual' 用户手动固定顺序 */
  nodeSortMode: string = 'default';
  /** 最近一次测速快照（JSON: NodeSortSnapshot），无测速数据为空串 */
  nodeSortSnapshot: string = '';
  /** 各订阅代理组当前策略选择（JSON 对象：稳定组键 -> 成员名）；旧配置缺失时为空串。 */
  proxyGroupSelections: string = '';
  // ── 第二阶段新增（旧版本配置缺这些字段时由 fromJson 取默认值） ──
  /** 网络类型变化时是否自动重连 */
  autoReconnectOnNetworkChange: boolean = true;
  /** 是否启用连续失败自动切换节点 */
  failoverEnabled: boolean = true;
  /** 触发切换的连续失败阈值（1..10） */
  failoverFailureThreshold: number = 3;
  /** 故障切换冷却秒数（0..3600） */
  failoverCooldownSec: number = 60;
  /** 自动选点模式：'manual'（默认，用户固定） / 'auto'（按评分自动选点） */
  autoSelectMode: string = 'manual';
  /** 是否启用链路自检与有限自动修复 */
  healthCheckEnabled: boolean = true;
  /** 自检后最多执行的修复步数（0..3） */
  healthRepairMaxSteps: number = 2;
  /**
   * 是否允许用明文 HTTP 拉取订阅/规则集。
   *
   * **默认 false** —— 与 FlClash / Clash Verge Rev / CMFA 一致，三家都只接受 https。
   * 明文订阅在本机与机场之间没有任何机密性/完整性保护：面板被劫持或 DNS 被污染时，
   * 返回的节点表可以指向任意服务器，而这份配置最终承载用户的全部流量。
   * 确有 http 需求的用户可在设置页显式打开。
   */
  allowInsecureSubscriptionHttp: boolean = false;
  rulesEnabled: boolean = false;
  /**
   * HyperADRules 去广告规则集开关。**默认关闭**，由用户在「规则」页自行打开。
   *
   * 关闭原因（2026 起）：全局模式下部分国内应用商店（华文应用商店等）会因去广告
   * 规则命中而加载失败 —— 商店首页/详情页聚合接口常与广告域名共用同一 CDN 或
   * 同一证书，去广告 REJECT 会连带打断正常业务请求。
   */
  hyperAdRulesEnabled: boolean = false;
  customRules: string[] = [];
  /**
   * 用户自定义远程规则集（P1-2）：生成 rule-providers + RULE-SET 规则。
   * 上限 20 条、单条 URL 512 字符（对标 Surge External Resources 的限额思路）。
   * 旧配置缺失时为空数组（行为不变）。
   */
  customRuleSets: CustomRuleSet[] = [];
  /**
   * YAML 覆盖层（P2，对标 Stash JS Override 的无脚本形态）：用户 YAML 原文追加在
   * 生成配置尾部，重复键后者覆盖前者。生成器侧 validateYamlOverride 白名单拦截
   * rules/proxies/proxy-groups/external-controller/secret/tun 六键。上限 8KB。
   * 旧配置缺失时为空串（行为不变）。
   */
  yamlOverride: string = '';
  /**
   * 订阅原文交给内核解析（provider 双轨）。
   *
   * true = 每个订阅的**原文**落盘，并在生成的 Mihomo 配置里以 `proxy-providers: {type: file}`
   * 交给内核自己解析（被覆盖的订阅不再由 App 重发射节点，组内只通过 `use:` 引用）；
   * false = 全部节点由 App 内联发射（行为与旧版一致）。
   *
   * **默认 true（2026-10-22 定案）**：与 FlClash / Clash Verge Rev / CMFA 同形 ——
   * 节点定义由内核解析，App 不再逐字段搬运。前两次失败的原因已逐条解决：
   *  ① 2026-10-21 绝对路径 → 内核 `path is not subpath of home directory` 拒载；
   *     现用相对路径 `raw_subscriptions/raw_<id>.yaml`；
   *  ② 「双核 home 不同」的旧结论**是错的**：NAPI `TunBoxInit` 的 homeDir 恒为
   *     entry cache（隧道核与无头测速核同目录），本机真实内核与真机双双验证过；
   *  ③ 跨订阅重名 → 该订阅整体退回内联发射（`planRawProviders` 的 nameConflicts），
   *     名字不再二义，`/proxies/{name}/delay` 与延迟表按名索引才成立。
   * 出问题可一键关回 false（设置页「订阅原文交给内核解析」）。
   */
  useRawProviderConfig: boolean = false;
  /**
   * 「provider 已切回默认关」的一次性迁移标记（providerOffV6，2026-10-22 21:50）。
   * 默认开的那一版在真机上出现「配置里 proxies: [] + provider 载不出节点」，
   * 靠这个标记把存量配置强制关回一次，之后尊重用户在设置页的开关。
   */
  providerOffV6: boolean = true;
  /** 内核 smart 组 policy-priority（见 AppSettings.smartPolicyPriority）；旧配置缺失时为空串。 */
  smartPolicyPriority: string = '';
  /**
   * 域名嗅探（sniffer）：从 TLS ClientHello / HTTP Host / QUIC 握手里还原真实目标域名。
   * DNS 恒由内核接管（redir-host：应答是真实地址），DOMAIN 规则靠 IP→域名映射反查；
   * TLS SNI 与 DNS 不一致的场景（CDN / 直连 IP 访问）仍必须靠嗅探才能分对流向。
   * 默认开启，与 Clash Verge / FlClash 等主流客户端一致。旧版本配置缺字段时取默认 true。
   */
  sniffingEnabled: boolean = true;
  /** 内核日志级别（log-level）：debug/info/warning/error/silent；默认 warning（现状）。 */
  coreLogLevel: string = 'warning';
  /**
   * IPv6 双栈开关（默认 **true**）。
   *
   * true  ⇒ 生成 ipv6: true + dns.ipv6: true + fake-ip-range6: fdfe:dcba:9876::/64
   *         （假 v6 池落在 TUN 自己的 /64 内）⇒ AAAA 返回隧道内地址，v6 与 v4 一样走代理；
   *         VpnExtensionAbility 装 fdfe:dcba:9876::1/64 + isIPv6Accepted: true。
   * false ⇒ 生成 ipv6: false + dns.ipv6: false（不下发 range6，AAAA 恒空），TUN 仅 IPv4。
   *
   * 真机取证（2026-10-21）：平台丢弃 VpnConfig.routes 的 v6 条目，但会按 LinkAddress 前缀
   * 派生 on-link 路由（/126 只有 /126，/64 就有 fdfe:dcba:9876::/64）⇒ 假 v6 有路可达、进隧道、
   * 由代理出口解析真实 v6；设备侧不存在直连 v6 的路径。
   *
   * 缺字段取 true（升级上来的老配置也默认开），显式 false 才关闭。
   */
  ipv6Enabled: boolean = true;
  /**
   * 订阅配额提醒（流量不足/即将到期发系统通知）。默认开启。
   * 阈值常量见 SubscriptionQuotaService：流量剩 <10% 或 3 天内到期。
   */
  quotaNotifyEnabled: boolean = true;
  /**
   * geo 资产下载源偏好（geoip.metadb / Model.bin / 去广告 MRS）：
   * auto=实测可达性默认序 / jsdelivr=CDN 优先 / ghproxy=加速前缀优先 / github=官方直链优先。
   * 偏好源排在候选表最前，失败仍按余下顺序回退；非法值回落 auto。
   */
  assetSource: string = 'auto';
  /** 配额提醒"当天已提醒"标记（JSON）；由 SubscriptionQuotaService 读写。 */
  quotaAlertMarks: string = '';
}

export class AppSettings {
  /**
   * 出厂默认测速地址（**HTTPS**）。
   *
   * 为什么默认 https（2026-10-20 定案）：
   *  - 5.6.0 真机基线就是 https（59 节点 13.14s 跑通，`unavailable=false`），
   *    后来版本改回 http 属于**退化**；
   *  - mihomo 官方明确告警：`provider.health-check.url` 与 `group.url` 应使用 HTTPS
   *    （明文测速地址会被机场/落地劫持 → 测速整批红）；
   *  - FlClash 的默认值同样是 https。
   *
   * ⚠ **只约束「出厂默认 / 历史默认值」**，绝不改写用户自填的 http 地址
   *   （见 `upgradeLegacyTestUrl`）。
   */
  static readonly DEFAULT_TEST_URL: string = LatencyTestUrl.DEFAULT_URL;
  /**
   * 本客户端历史上写过的两个 **http** 默认值（升级用）。
   *
   * 只有**恰好等于**这两个字符串的历史默认值才会被单向升级为 https；
   * 其余用户自填的 http 地址（带路径/参数/端口的）一律原样保留。
   */
  static readonly LEGACY_TEST_URL_GSTATIC: string = LatencyTestUrl.LEGACY_GSTATIC_HTTP;
  static readonly LEGACY_TEST_URL_CLOUDFLARE: string = LatencyTestUrl.LEGACY_CLOUDFLARE_HTTP;

  /** 跟随系统 / 暗色 / 亮色 */
  themeMode: number = 0; // 0=system, 1=dark, 2=light
  autoConnectOnBoot: boolean = true;
  bypassDomesticApps: boolean = true;
  excludedApps: string[] = [];
  /** 两份名单独立保留，只有 appRoutingMode 选中的一份参与运行。 */
  includedApps: string[] = [];
  appRoutingMode: string = 'all';
  /** 旧版双名单冲突/非法数据必须由 UI 保存确认，普通设置保存不得清除。 */
  appRoutingNeedsReview: boolean = false;
  appRoutingCustomApps: AppRoutingCustomApp[] = [];
  /** 用户已删除的预置包名（见 AppSettings.appRoutingRemovedPresets 注释） */
  appRoutingRemovedPresets: string[] = [];
  forceProxySites: string[] = [];
  /** 强制直连网站（始终 DIRECT, 不走代理） */
  forceDirectSites: string[] = [];
  /** 强制拦截网站（DNS 层 REJECT 预匹配，详见 AppSettingsJson.forceBlockSites 注释） */
  forceBlockSites: string[] = [];
  preferredNodeId: string = '';
  preferredNodeSubscriptionId: string = '';
  /** 偏好节点名字快照（重锚用），与 AppSettingsJson.preferredNodeName 对应 */
  preferredNodeName: string = '';
  autoUpdateSubscription: boolean = true;
  selectedSubscriptionId: string = '';
  testLatencyUrl: string = LatencyTestUrl.DEFAULT_URL;
  /** 代理模式：rule = 规则 / global = 全局 / direct = 直连（对应 upstream settings.proxyMode） */
  proxyMode: string = 'rule';
  /** 节点列表排序模式: 'default'=订阅默认顺序, 'auto'=按最近测速结果, 'manual'=手动固定顺序 */
  nodeSortMode: string = 'default';
  /** 最近一次测速快照序列化（NodeSortSnapshot JSON），无则空串。随设置一起落盘，
   *  使测速排序结果在退出页面/重启应用后仍然保持，直到用户重新测速才覆盖。 */
  nodeSortSnapshot: string = '';

  // ── 第二阶段新增设置 ────────────────────────────────────────────────
  /** 网络类型变化（含 none→有网恢复）时，若用户意图为已连接则自动退避重连。默认 true */
  autoReconnectOnNetworkChange: boolean = true;
  /** 是否启用「连续失败→自动切换节点」。默认 true */
  failoverEnabled: boolean = true;
  /** 触发自动切换的连续失败阈值，范围 1..10，默认 3 */
  failoverFailureThreshold: number = 3;
  /** 故障切换冷却秒数，范围 0..3600，默认 60（冷却期内禁止再次切换，防切换风暴） */
  failoverCooldownSec: number = 60;
  /** 自动选点模式：'manual'（默认，维持用户固定节点）/ 'auto'（按 SmartSelector 评分自动选点并允许切换） */
  autoSelectMode: string = 'manual';
  /** 是否启用链路自检与有限自动修复。默认 true */
  healthCheckEnabled: boolean = true;
  /** 自检后最多执行的修复步数，范围 0..3，默认 2 */
  healthRepairMaxSteps: number = 2;
  /** 是否允许明文 HTTP 订阅（默认 false；三家主流客户端都只接受 https） */
  allowInsecureSubscriptionHttp: boolean = false;
  /** 自定义规则路由默认关闭，用户可手动开启；去广告由独立开关控制。 */
  rulesEnabled: boolean = false;
  /**
   * HyperADRules 去广告规则集开关，默认 **false**（由用户在「规则」页自行打开）。
   *
   * 曾默认开启，但全局代理下会导致国内应用商店（华文应用商店等）加载失败 ——
   * 商店聚合接口与广告域名共用 CDN/证书，去广告 REJECT 会误伤正常业务请求。
   * 改为默认关闭，需要去广告的用户手动开启即可。
   * 已显式保存过 true/false 的老用户不受影响（fromJson 只在字段缺失时取默认值）。
   */
  hyperAdRulesEnabled: boolean = false;
  customRules: string[] = [];
  /** 用户自定义远程规则集（P1-2；见 AppSettingsJson.customRuleSets 注释） */
  customRuleSets: CustomRuleSet[] = [];
  /** YAML 覆盖层（P2）：追加在生成配置尾部的用户 YAML 片段（上限 8KB，白名单在生成器） */
  yamlOverride: string = '';
  /**
   * 订阅原文交给内核解析（provider 双轨）。
   *
   * **默认 false（2026-10-22 21:50 回退）**：默认开的那一版真机上出过「配置 `proxies: []` +
   * provider 一个节点也没载出来」（/proxies 只剩组和内置策略），隧道连上却无可用节点。
   * 关闭后全部节点由 App 内联发射（= 原文透传，字段同样不丢），行为可靠。
   * 开关仍在设置页（「订阅原文交给内核解析」），供 verify 通过后再逐台打开验证。
   */
  useRawProviderConfig: boolean = false;
  /** 一次性迁移标记：provider 默认值已切回 false（providerOffV6，见 fromJson） */
  providerOffV6: boolean = true;
  /** 各订阅代理组当前策略选择（JSON 对象：稳定组键 -> 成员名）。 */
  proxyGroupSelections: string = '';
  /**
   * 内核 smart 组的 `policy-priority`：按**节点名**给权重因子，格式 `模式:因子;模式:因子`。
   *
   * 这是 mihomo-smart 系 fork（当前基线 vernesong/mihomo@Alpha）独有的能力（mainline mihomo
   * 没有 smart 组，更没有这个键）。
   * 语义见 `adapter/outboundgroup/smart.go`：因子**大于** LightGBM 评分的排序优先级 ——
   * 只要两个节点的因子不同，就按因子降序排，分数再高也翻不过来（`smart.go:580`）。
   * 模式支持子串匹配（默认）或正则；**首个命中的规则生效**；因子必须为正数，非法规则内核
   * 只告警并跳过，不会导致启动失败，所以坏配置是安全的。
   *
   * 默认空串 = 不生成该键，排序完全交给 LightGBM（与之前行为一致）。
   */
  smartPolicyPriority: string = '';
  /** 域名嗅探开关（默认 true；见 AppSettingsJson.sniffingEnabled 注释） */
  sniffingEnabled: boolean = true;
  /** 内核日志级别：debug/info/warning/error/silent（默认 warning = 现状行为） */
  coreLogLevel: string = 'warning';
  /** IPv6 双栈开关（默认 true；语义见 AppSettingsJson.ipv6Enabled 注释） */
  ipv6Enabled: boolean = true;
  /** 订阅配额提醒开关（默认 true；阈值见 SubscriptionQuotaService） */
  quotaNotifyEnabled: boolean = true;
  /** geo 资产下载源偏好：auto/jsdelivr/ghproxy/github（非法回落 auto） */
  assetSource: string = 'auto';
  /**
   * 配额提醒"当天已提醒"标记（JSON：dedupeKey → dayKey）。
   * 由 SubscriptionQuotaService 读写；UI 不展示。旧标记 30 天后自动清理。
   */
  quotaAlertMarks: string = '';

  toJson(): AppSettingsJson {
    const j = new AppSettingsJson();
    j.themeMode = this.themeMode;
    j.autoConnectOnBoot = this.autoConnectOnBoot;
    j.bypassDomesticApps = this.bypassDomesticApps;
    j.excludedApps = this.excludedApps;
    j.includedApps = this.includedApps;
    j.appRoutingMode = this.appRoutingMode;
    j.appRoutingNeedsReview = this.appRoutingNeedsReview;
    j.appRoutingCustomApps = this.appRoutingCustomApps;
    j.appRoutingRemovedPresets = this.appRoutingRemovedPresets;
    j.forceProxySites = this.forceProxySites;
    j.forceDirectSites = this.forceDirectSites;
    j.forceBlockSites = this.forceBlockSites;
    j.preferredNodeId = this.preferredNodeId;
    j.preferredNodeSubscriptionId = this.preferredNodeSubscriptionId;
    j.preferredNodeName = this.preferredNodeName;
    j.autoUpdateSubscription = this.autoUpdateSubscription;
    j.selectedSubscriptionId = this.selectedSubscriptionId;
    j.testLatencyUrl = this.testLatencyUrl;
    j.proxyMode = this.proxyMode;
    j.nodeSortMode = this.nodeSortMode;
    j.nodeSortSnapshot = this.nodeSortSnapshot;
    j.proxyGroupSelections = this.proxyGroupSelections;
    j.autoReconnectOnNetworkChange = this.autoReconnectOnNetworkChange;
    j.failoverEnabled = this.failoverEnabled;
    j.failoverFailureThreshold = this.failoverFailureThreshold;
    j.failoverCooldownSec = this.failoverCooldownSec;
    j.autoSelectMode = this.autoSelectMode;
    j.healthCheckEnabled = this.healthCheckEnabled;
    j.healthRepairMaxSteps = this.healthRepairMaxSteps;
    j.allowInsecureSubscriptionHttp = this.allowInsecureSubscriptionHttp;
    j.rulesEnabled = this.rulesEnabled;
    j.hyperAdRulesEnabled = this.hyperAdRulesEnabled;
    j.customRules = this.customRules;
    j.customRuleSets = this.customRuleSets;
    j.yamlOverride = this.yamlOverride;
    j.useRawProviderConfig = this.useRawProviderConfig;
    j.providerOffV6 = this.providerOffV6;
    j.smartPolicyPriority = this.smartPolicyPriority;
    j.sniffingEnabled = this.sniffingEnabled;
    j.coreLogLevel = this.coreLogLevel;
    j.ipv6Enabled = this.ipv6Enabled;
    j.quotaNotifyEnabled = this.quotaNotifyEnabled;
    j.assetSource = this.assetSource;
    j.quotaAlertMarks = this.quotaAlertMarks;
    return j;
  }

  /**
   * 测速 URL 规范化：**只把本客户端自己写过的历史 http 默认值**单向升级为 https。
   *
   * ## 为什么不是「把所有 http 都改成 https」
   *
   * 明文测速地址确实有真实风险（机场/落地劫持 + mihomo 官方点名
   * `provider.health-check.url` / `group.url` 应使用 HTTPS），但**一刀切会改坏用户的
   * 合法配置**：真机 commit `a3fe45d` 实证 —— 个别出口会掐 gstatic 的 TLS SNI，
   * 同一个出口 **https Timeout 而 http 1158ms**。用户自填 http 是**有意为之**，
   * 客户端无权替他改。
   *
   * 所以规则是**精确匹配 + 单向**：
   *  - 恰好等于本客户端历史上写过的两个 http 默认值 → 升级为对应 https
   *    （存量用户落盘的旧默认值在**本次加载**时被迁移，用户不需要手动改）；
   *  - 其余任何值（用户自填的 http、https、带路径/参数/端口的地址）→ **原样保留**；
   *  - 空串 / 非法值（不是 `http(s)://` 开头的地址）→ 回落默认 https。
   *
   * ⚠ 本方法**绝不**把 https 降级回 http：用户手填 https 是明确意图。
   */
  static upgradeLegacyTestUrl(value: string): string {
    const raw: string = typeof value === 'string' ? value.trim() : '';
    if (raw.length === 0) {
      return AppSettings.DEFAULT_TEST_URL;
    }
    if (raw === AppSettings.LEGACY_TEST_URL_GSTATIC) {
      return LatencyTestUrl.DEFAULT_URL;
    }
    if (raw === AppSettings.LEGACY_TEST_URL_CLOUDFLARE) {
      return LatencyTestUrl.ALT_URL;
    }
    if (!/^https?:\/\/\S+$/.test(raw)) {
      // 非法值（没有协议头 / 带空白）→ 默认 https
      return AppSettings.DEFAULT_TEST_URL;
    }
    return raw;
  }

  static fromJson(j: AppSettingsJson): AppSettings {
    const s = new AppSettings();
    s.themeMode = j.themeMode === 1 || j.themeMode === 2 ? j.themeMode : 0;
    s.autoConnectOnBoot = typeof j.autoConnectOnBoot === 'boolean' ? j.autoConnectOnBoot : true;
    s.bypassDomesticApps = typeof j.bypassDomesticApps === 'boolean' ? j.bypassDomesticApps : true;
    // 不能 filter 无效项：丢掉仅代理名单会扩大接管，丢掉绕过名单会改变用户边界。
    s.excludedApps = Array.isArray(j.excludedApps) ? AppRoutingPolicy.normalizePackages(j.excludedApps)
      : (j.excludedApps === undefined ? [] : ['[无效名单] ' + String(j.excludedApps)]);
    s.includedApps = Array.isArray(j.includedApps) ? AppRoutingPolicy.normalizePackages(j.includedApps)
      : (j.includedApps === undefined ? [] : ['[无效名单] ' + String(j.includedApps)]);
    const legacyRouting = j.appRoutingMode === undefined;
    s.appRoutingMode = legacyRouting ? AppRoutingPolicy.legacyMode(s.includedApps, s.excludedApps)
      : (typeof j.appRoutingMode === 'string' ? j.appRoutingMode : 'invalid');
    s.appRoutingNeedsReview = j.appRoutingNeedsReview === true ||
      (j.appRoutingNeedsReview !== undefined && typeof j.appRoutingNeedsReview !== 'boolean') ||
      (legacyRouting && s.includedApps.length > 0 && s.excludedApps.length > 0);
    if (AppRoutingPolicy.validationError(s.appRoutingMode, s.includedApps, s.excludedApps, false).length > 0) {
      s.appRoutingNeedsReview = true;
    }
    if (Array.isArray(j.appRoutingCustomApps)) {
      for (const item of j.appRoutingCustomApps) {
        if (item === null || typeof item !== 'object') {
          s.appRoutingNeedsReview = true;
          continue;
        }
        const custom = new AppRoutingCustomApp();
        custom.bundleName = typeof item.bundleName === 'string' ? item.bundleName.trim() : '[无效包名]';
        custom.label = typeof item.label === 'string' ? item.label.trim() : '';
        s.appRoutingCustomApps.push(custom);
      }
    }
    // 用户已删除的预置包名（只接受合法字符串，长度与包名上限一致）
    s.appRoutingRemovedPresets = Array.isArray(j.appRoutingRemovedPresets)
      ? AppRoutingPolicy.normalizePackages(j.appRoutingRemovedPresets
        .filter((v: string) => typeof v === 'string'))
      : [];
    s.forceProxySites = Array.isArray(j.forceProxySites)
      ? j.forceProxySites.filter((v: string) => typeof v === 'string') : [];
    s.forceDirectSites = Array.isArray(j.forceDirectSites)
      ? j.forceDirectSites.filter((v: string) => typeof v === 'string') : [];
    s.forceBlockSites = Array.isArray(j.forceBlockSites)
      ? j.forceBlockSites.filter((v: string) => typeof v === 'string') : [];
    s.preferredNodeId = typeof j.preferredNodeId === 'string' ? j.preferredNodeId : '';
    s.preferredNodeSubscriptionId = typeof j.preferredNodeSubscriptionId === 'string'
      ? j.preferredNodeSubscriptionId : '';
    s.preferredNodeName = typeof j.preferredNodeName === 'string' ? j.preferredNodeName : '';
    s.autoUpdateSubscription = typeof j.autoUpdateSubscription === 'boolean' ? j.autoUpdateSubscription : true;
    s.selectedSubscriptionId = typeof j.selectedSubscriptionId === 'string' ? j.selectedSubscriptionId : '';
    // 测速地址：**只做「历史 http 默认值 → https」的单向升级**（C3）。
    // 早期版本在这里做过**反向降级**（把用户手填的 https 改回 http）—— 那是罪魁祸首：
    // 用户明确填 https 也会被悄悄改掉。现在不再有任何降级路径。
    s.testLatencyUrl = AppSettings.upgradeLegacyTestUrl(
      typeof j.testLatencyUrl === 'string' ? j.testLatencyUrl : '');
    // ── 代理模式恢复：`direct` **不跨重启持久化**（2026-10-19 稳定性裁定）──
    //
    // `direct` 是 0.4.0 新增的第三态（首页「直连」按钮）。它的语义是「所有流量
    // 绕过代理直连」，一旦被持久化，用户误触一次之后每次启动、每次连接都仍然直连，
    // 表现就是「VPN 连上了但代理完全不生效、公网 IP 是本地出口」——这正是 0.4.0
    // 被反馈的一类故障形态，而且用户很难自己发现是模式问题。
    //
    // 因此：`direct` 只在**本次运行期**有效（运行期切模式走 ClashApiService.setMode，
    // 热更新不改磁盘语义），重启后一律回落 `rule`。需要直连的场景重新点一下按钮即可，
    // 代价是点一次，收益是**不可能被粘在直连态**。
    const parsedMode: string = j.proxyMode;
    s.proxyMode = parsedMode === 'global' ? 'global' : 'rule';
    s.nodeSortMode = NodeSortModes.normalize(j.nodeSortMode);
    s.nodeSortSnapshot = typeof j.nodeSortSnapshot === 'string' ? j.nodeSortSnapshot : '';
    s.proxyGroupSelections = typeof j.proxyGroupSelections === 'string' ? j.proxyGroupSelections : '';
    // 旧版本配置缺字段 → 取默认值；非法值 → 回落/夹取（加载不炸、保存幂等）
    s.autoReconnectOnNetworkChange = typeof j.autoReconnectOnNetworkChange === 'boolean'
      ? j.autoReconnectOnNetworkChange : true;
    s.failoverEnabled = typeof j.failoverEnabled === 'boolean' ? j.failoverEnabled : true;
    s.failoverFailureThreshold = clampInt(j.failoverFailureThreshold, 3, 1, 10);
    s.failoverCooldownSec = clampInt(j.failoverCooldownSec, 60, 0, 3600);
    s.autoSelectMode = AutoSelectModes.normalize(j.autoSelectMode);
    s.healthCheckEnabled = typeof j.healthCheckEnabled === 'boolean' ? j.healthCheckEnabled : true;
    s.healthRepairMaxSteps = clampInt(j.healthRepairMaxSteps, 2, 0, 3);
    // 明文订阅默认拒绝：字段缺失（用户从未设置过）→ false，只认显式 true。
    s.allowInsecureSubscriptionHttp = j.allowInsecureSubscriptionHttp === true;
    s.rulesEnabled = typeof j.rulesEnabled === 'boolean' ? j.rulesEnabled : false;
    // 去广告规则默认关闭：字段缺失（用户从未设置过）→ false。
    // 老用户显式存过的 true/false 原样恢复，不会被这次改默认值覆盖。
    s.hyperAdRulesEnabled = typeof j.hyperAdRulesEnabled === 'boolean' ? j.hyperAdRulesEnabled : false;
    s.customRules = Array.isArray(j.customRules)
      ? j.customRules.filter((v: string) => typeof v === 'string').slice(0, 500) : [];
    // 自定义规则集（P1-2）：逐条规范化（名称/URL/behavior/format/policy/interval），
    // 上限 20 条；非法项跳过（加载不炸、保存幂等），合法性细则在生成器校验。
    s.customRuleSets = Array.isArray(j.customRuleSets)
      ? AppSettings.normalizeRuleSets(j.customRuleSets) : [];
    // YAML 覆盖层（P2）：缺字段/非字符串回落空串；上限 8KB，合法性（顶层键白名单）
    // 在生成器 validateYamlOverride 判定，不合法的覆盖层不追加（行为与旧版一致）。
    s.yamlOverride = typeof j.yamlOverride === 'string' ? j.yamlOverride.slice(0, 8192) : '';
    // 订阅原文交给内核解析（provider 双轨）：缺字段/脏值回落 **false**（默认关 = 全内联）
    s.useRawProviderConfig = typeof j.useRawProviderConfig === 'boolean' ? j.useRawProviderConfig : false;
    // 一次性迁移（2026-10-22 21:50）：默认开的那一版在真机上出现「proxies: [] + provider 空」
    // ⇒ 存量配置统一强制关回一次并写新标记；此后尊重用户在设置页的开关。
    if (j.providerOffV6 !== true) {
      s.useRawProviderConfig = false;
      s.providerOffV6 = true;
    }
    // policy-priority：缺字段/非字符串回落空串（=不生成该键，行为与旧版一致）。
    // 长度上限防止脏配置把生成的 YAML 撑爆；合法性（pattern:factor）交给内核判定，
    // 内核遇到非法规则只告警跳过，不会启动失败。
    s.smartPolicyPriority = typeof j.smartPolicyPriority === 'string'
      ? j.smartPolicyPriority.slice(0, 2000) : '';
    // 域名嗅探：缺字段取默认 true（对齐主流客户端）；显式 false 才关闭。
    s.sniffingEnabled = j.sniffingEnabled === false ? false : true;
    // 日志级别：仅接受白名单值，其余回落 warning（现状行为），防止脏值写进 YAML。
    const level = typeof j.coreLogLevel === 'string' ? j.coreLogLevel.trim().toLowerCase() : '';
    s.coreLogLevel = (level === 'debug' || level === 'info' || level === 'warning'
      || level === 'error' || level === 'silent') ? level : 'warning';
    // IPv6 双栈：缺字段取默认 true（升级上来的老配置默认开启），
    // 只有显式 false 才关闭 —— 与「默认开」的产品口径一致。
    // DNS 接管已无开关（恒开），老配置里残留的 dnsOverrideEnabled 直接忽略。
    s.ipv6Enabled = j.ipv6Enabled === false ? false : true;
    // 2026-10-23 用户口径：配额提醒恒开（设置页已去掉这个开关，默认就是开）。
    // 旧配置里存过 false 的也一律置 true —— 否则升级后「开关没了却也不提醒」，
    // 等于悄悄把功能弄丢。
    s.quotaNotifyEnabled = true;
    const source = typeof j.assetSource === 'string' ? j.assetSource.trim().toLowerCase() : '';
    s.assetSource = (source === 'jsdelivr' || source === 'ghproxy' || source === 'github')
      ? source : 'auto';
    s.quotaAlertMarks = typeof j.quotaAlertMarks === 'string'
      ? j.quotaAlertMarks.slice(0, 128 * 1024) : '';
    return s;
  }

  /**
   * 自定义规则集规范化（P1-2）：名称限 [a-zA-Z0-9_-]（≤48 字符）、URL 必须 https 且 ≤512、
   * behavior/format/policy 白名单、interval 夹取 [3600, 604800]；重名保留首条。
   * 无效条目跳过（加载不炸、保存幂等）。上限 20 条（对标 Surge External Resources 限额思路）。
   */
  static normalizeRuleSets(values: CustomRuleSet[]): CustomRuleSet[] {
    const out: CustomRuleSet[] = [];
    for (const raw of values) {
      if (raw === null || typeof raw !== 'object') {
        continue;
      }
      const entry = new CustomRuleSet();
      entry.name = typeof raw.name === 'string' ? raw.name.trim() : '';
      entry.url = typeof raw.url === 'string' ? raw.url.trim() : '';
      const behavior = typeof raw.behavior === 'string' ? raw.behavior.trim().toLowerCase() : '';
      entry.behavior = (behavior === 'domain' || behavior === 'ipcidr' || behavior === 'classical')
        ? behavior : 'domain';
      const format = typeof raw.format === 'string' ? raw.format.trim().toLowerCase() : '';
      entry.format = (format === 'yaml' || format === 'text' || format === 'mrs') ? format : 'yaml';
      const policy = typeof raw.policy === 'string' ? raw.policy.trim().toUpperCase() : '';
      entry.policy = (policy === 'DIRECT' || policy === 'PROXY' || policy === 'REJECT') ? policy : 'REJECT';
      let interval = typeof raw.interval === 'number' && Number.isFinite(raw.interval) ? raw.interval : 86400;
      if (interval < 3600) {
        interval = 3600;
      }
      if (interval > 604800) {
        interval = 604800;
      }
      entry.interval = Math.floor(interval);
      const nameOk = /^[a-zA-Z0-9_-]{1,48}$/.test(entry.name);
      const urlOk = entry.url.startsWith('https://') && entry.url.length <= 512;
      if (!nameOk || !urlOk) {
        continue;
      }
      const key = entry.name.toLowerCase();
      let dup = false;
      for (const existing of out) {
        if (existing.name.toLowerCase() === key) {
          dup = true;
          break;
        }
      }
      if (dup) {
        continue;
      }
      out.push(entry);
      if (out.length >= 20) {
        break;
      }
    }
    return out;
  }
}
