// [harness] generated from entry/src/main/ets/commons/models/Subscription.ets — 仅 import 目标被重写
/**
 * 数据模型：订阅
 * 移植自 upstream: packages/tunbox_shared/lib/models/subscription.dart
 */
import { SubscriptionJson } from './stubs.ts';

export class Subscription {
  id: string = '';
  name: string = '';
  url: string = '';
  /** 自定义请求头名（UA 协商时用户可覆盖默认 UA），对应 upstream subscription_header_name_parser */
  headerName: string = '';
  /**
   * 自定义请求头值（等价于订阅鉴权 token）：敏感凭据，只允许写入 AssetStore。
   * 该字段从不参与 preferences JSON 序列化（Subscription.toJson 恒写空串），
   * 仅在内存中持有；进程重启后由 CredentialStore 从加密层回填。
   */
  headerValue: string = '';
  /** 上次成功拉取的原始内容缓存 key（源缓存） */
  lastFetchedAt: number = 0;
  lastRefreshResult: string = '';
  nodeCount: number = 0;
  uploadBytes: number = -1;
  downloadBytes: number = -1;
  totalBytes: number = -1;
  expireAt: number = -1;
  enabled: boolean = true;
  /**
   * 旧格式订阅标记（2026-10-21「只支持 Clash 订阅」收口）。
   *
   * 判定依据是**下载到的内容**而不是链接：JSON / CONF / base64 节点串 / 纯链接列表都算旧格式。
   * 策略：已解析的节点保留可用（不清空、不影响选点/测速/连接），只做三件事——
   *   ① 停止自动更新（避免每天报错刷屏）；② 卡片显示「旧格式」角标；③ 提示换成 Clash 链接。
   * 用户把订阅 URL 换成 Clash 订阅后，下一次刷新成功会自动清掉本标记。
   */
  legacyFormat: boolean = false;
  sortOrder: number = 0;
  /**
   * 双轨「原始订阅 provider」状态（持久化，供订阅卡/诊断并列展示）：
   * '' 未尝试 / 'off' 开关关闭 / 'ready' 原文已落盘可读回 /
   * 'ineligible' 原文不是 Clash YAML（不能作为 file provider）/
   * 'failed' 上次落盘失败（已降级为仅解析链）/ 'missing' 开关开启但文件缺失。
   */
  rawProviderState: string = '';
  /** 落盘原文读回的条目估算（0 = 未知/无；与 nodeCount 并列展示差额） */
  rawProviderNodeEstimate: number = 0;
  /**
   * 上次成功拉取的 ETag / Last-Modified，用于 `If-None-Match` 条件请求。
   * 面板内容未变时返回 304，省掉整份订阅的下载与解析。
   * 非敏感（只是缓存校验值），随 preferences 正常持久化。
   */
  etag: string = '';
  /**
   * 订阅 yaml 自带的 rules 段（解析归一后的规则行，每行一条、不含 `rules:` 头）。
   * 生成内核配置时按序写入 rules 段，让订阅自带的分流规则真实生效 ——
   * 此前订阅导入只保留节点与组，rules 段被整段丢弃，全部流量落到内置 MATCH,PROXY。
   * 非敏感，随 preferences 正常持久化。
   */
  subRules: string = '';
  /**
   * 订阅 yaml 自带的 rule-providers 段（归一化后的块式原文，2 空格缩进）。
   * 与 subRules 配套：RULE-SET 引用的 provider 必须声明，二者缺一不可。
   */
  subRuleProviders: string = '';
  /**
   * 订阅 `dns.proxy-server-nameserver`：**解析代理服务器域名**用的上游
   * （JSON 字符串数组，已去引号 / 去重 / 上限 8 条）。
   *
   * 为什么必须保留（2026-10-20 真机定案）：机场普遍只把「入口域名 → 真实入口 IP」
   * 告诉自家私有 DoH（如 `https://ns1.pubdns.co/dns-hyy/…`），公共 DNS 解析出来的是
   * Cloudflare / WAF 前置 IP —— 那些 IP 上代理端口要么不通、要么不提供协议服务。
   * 丢掉这一路 ⇒ 该订阅所有域名节点必然超时。实测（真实内核单变量）：
   * 订阅1 原样 20/23 通，**只删这一行**就变 7/23；订阅2 原样 30/36，删掉 policy 变 0/36。
   *
   * 非敏感（只是 DNS 上游 URL），随 preferences 正常持久化。
   */
  subDnsProxyServers: string = '';
  /**
   * 订阅 `dns.nameserver-policy` / `proxy-server-nameserver-policy` 的条目，
   * 展平成 `[["+.入口域名", "私有 DoH"], …]` 的 JSON 二维数组。
   *
   * 生成配置时**只保留与节点 server 域名匹配的条目**（订阅自己的入口域名），
   * 不会把机场针对其它域名的策略带进用户的 DNS 策略里。
   */
  subDnsPolicies: string = '';

  static newSubscription(id: string, name: string, url: string): Subscription {
    const s = new Subscription();
    s.id = id;
    s.name = name;
    s.url = url;
    return s;
  }

  static toJson(s: Subscription): SubscriptionJson {
    const j = new SubscriptionJson();
    j.id = s.id;
    j.name = s.name;
    j.url = s.url;
    j.headerName = s.headerName;
    // headerValue 属敏感凭据：永不写 preferences（加密层由 SubscriptionService.persist 负责）
    j.headerValue = '';
    j.lastFetchedAt = s.lastFetchedAt;
    j.lastRefreshResult = s.lastRefreshResult;
    j.nodeCount = s.nodeCount;
    j.uploadBytes = s.uploadBytes;
    j.downloadBytes = s.downloadBytes;
    j.totalBytes = s.totalBytes;
    j.expireAt = s.expireAt;
    j.enabled = s.enabled;
    j.sortOrder = s.sortOrder;
    j.legacyFormat = s.legacyFormat;
    j.rawProviderState = s.rawProviderState;
    j.rawProviderNodeEstimate = s.rawProviderNodeEstimate;
    j.etag = s.etag;
    j.subRules = s.subRules;
    j.subRuleProviders = s.subRuleProviders;
    j.subDnsProxyServers = s.subDnsProxyServers;
    j.subDnsPolicies = s.subDnsPolicies;
    return j;
  }

  static fromPersistJson(j: SubscriptionJson): Subscription {
    const s = new Subscription();
    s.id = j.id;
    s.name = j.name;
    s.url = j.url;
    s.headerName = j.headerName;
    s.headerValue = j.headerValue;
    s.lastFetchedAt = j.lastFetchedAt;
    s.lastRefreshResult = j.lastRefreshResult;
    s.nodeCount = j.nodeCount;
    s.uploadBytes = j.uploadBytes ?? -1;
    s.downloadBytes = j.downloadBytes ?? -1;
    s.totalBytes = j.totalBytes ?? -1;
    s.expireAt = j.expireAt ?? -1;
    s.enabled = j.enabled;
    s.sortOrder = j.sortOrder;
    // 旧版本存储无这两个键（可选字段），缺失一律按「未尝试」处理
    s.legacyFormat = j.legacyFormat === true;
    s.rawProviderState = j.rawProviderState ?? '';
    s.rawProviderNodeEstimate = j.rawProviderNodeEstimate ?? 0;
    // 同理：etag 是后加字段，旧存储没有 → 空串 = 下次做完整拉取
    s.etag = j.etag ?? '';
    // 订阅自带 rules/rule-providers 同为后加字段，旧存储没有 → 空串
    s.subRules = j.subRules ?? '';
    s.subRuleProviders = j.subRuleProviders ?? '';
    // 订阅 dns 上游同为后加字段：旧存储没有 → 空串（生成时退回内置公共 DoT）
    s.subDnsProxyServers = j.subDnsProxyServers ?? '';
    s.subDnsPolicies = j.subDnsPolicies ?? '';
    return s;
  }
}

export enum SubscriptionRefreshStatus {
  OK = 'ok',
  NOT_MODIFIED = 'notModified',
  NETWORK_ERROR = 'networkError',
  HTTP_ERROR = 'httpError',
  EMPTY_RESPONSE = 'emptyResponse',
  DECODE_ERROR = 'decodeError',
  PARSE_ERROR = 'parseError',
  LIMIT_EXCEEDED = 'limitExceeded',
  PERSIST_ERROR = 'persistError',
  /**
   * 面板限流/拒绝（HTTP 429/403）。与 httpError 分开：摘要里必须能看出
   * 「是被限流」而不是「地址写错」。新增枚举值向后兼容（旧的 httpError 分支保留）。
   */
  RATE_LIMITED = 'rateLimited',
  /**
   * 拉取成功（HTTP 200、响应非空）但解析出 0 个条目。与 emptyResponse（响应体为空）
   * 和 parseError（内容无法识别）区分开，提示可能是面板按 UA 返回空列表。
   */
  EMPTY_ENTRIES = 'emptyEntries'
}

/** 三种导入入口共用的诊断统计，所有跳过原因均显式可见。 */
export class SubscriptionImportDiagnostics {
  inputCount: number = 0;
  addedCount: number = 0;
  duplicateCount: number = 0;
  invalidCount: number = 0;
  unsupportedCount: number = 0;
  hiddenCount: number = 0;
  limitCount: number = 0;
  unsupportedTypes: string = '';
  /** 无效/缺字段条目的原因摘要（最多 3 条，供界面直接展示，脱敏：只有原因文本） */
  invalidReasons: string = '';
  /** 敏感凭据写入加密层失败（回读校验不一致）的字段数：>0 表示重启后可能凭据缺失 */
  persistFailedCount: number = 0;
  /** 已导入但生成内核配置时被丢弃的节点数（列表有、内核无的显式计数） */
  configDroppedCount: number = 0;
  /** 上述丢弃中因 password/uuid/protocolParam/obfsParam 为空（凭据未回填）造成的数量 */
  configMissingCredentialCount: number = 0;
  /** 生成配置阶段丢弃原因明细（中文，供界面直接展示） */
  configDropReasons: string = '';
  /** 从 proxy-providers 成功导入的节点数（来源标注为 provider） */
  providerCount: number = 0;
  /** proxy-providers 中类型不支持而未能导入的 provider 数 */
  providerSkippedCount: number = 0;
  /** 不支持的 provider 类型清单（去重） */
  providerTypes: string = '';
  /** provider 拉取/解析失败的条数与明细（中文） */
  providerFailedCount: number = 0;
  providerFailureReasons: string = '';
  // ── 双轨（原始订阅 → file provider，开关默认关闭）────────────────────
  /** 双轨开关本次是否开启（关闭时下列字段恒为 0，诊断文案与现状一致） */
  rawProviderEnabled: boolean = false;
  /** 本次落盘成功的订阅原文数 */
  rawProviderWritten: number = 0;
  /** 落盘失败数（已自动降级为「仅解析链」，不影响导入结果） */
  rawProviderFailed: number = 0;
  /** 原文不是 Clash YAML（内核 file provider 只认带 proxies 的 YAML）而无法落盘使用的订阅数 */
  rawProviderIneligible: number = 0;
  /** 从落盘原文读回的条目数估算（「provider 读到 M」；内核侧真实值需真机查询 /providers） */
  rawProviderNodeEstimate: number = 0;
  /** 生成配置时实际发出的 proxy-provider 条数 */
  rawProviderEmitted: number = 0;
  /** 关闭开关/清理时删除的落盘文件数 */
  rawProviderPurged: number = 0;
  /** 双轨明细（中文，界面直接展示） */
  rawProviderReasons: string = '';

  skippedCount(): number {
    return this.duplicateCount + this.invalidCount + this.unsupportedCount
      + this.hiddenCount + this.limitCount + this.providerSkippedCount;
  }

  /** 生成配置阶段丢弃总数（列表显示 N 个，内核实际只有 N-configDroppedCount 个） */
  kernelDroppedCount(): number {
    return this.configDroppedCount + this.providerFailedCount;
  }

  unsupportedDetail(): string {
    return this.unsupportedTypes.length > 0 ? `（${this.unsupportedTypes}）` : '';
  }

  providerDetail(): string {
    const bits: string[] = [];
    if (this.providerCount > 0) {
      bits.push(`导入 ${this.providerCount}`);
    }
    if (this.providerSkippedCount > 0) {
      bits.push(`不支持 ${this.providerSkippedCount}`
        + (this.providerTypes.length > 0 ? `（类型 ${this.providerTypes} 暂不支持）` : ''));
    }
    if (this.providerFailedCount > 0) {
      bits.push(`失败 ${this.providerFailedCount}`);
    }
    return bits.length > 0 ? `；proxy-providers ${bits.join('，')}` : '';
  }

  /**
   * 「解析到 N / provider 读到 M」并列口径（仅日志留痕，界面不再展示）：
   * N = 本次解析链落库的节点数（addedCount），M = 落盘原文读回的条目估算。
   */
  parsedVsProviderText(): string {
    return `解析到 ${this.addedCount} / provider 读到 ${this.rawProviderNodeEstimate}`;
  }

  /** 双轨明细（中文）：仅写入运行日志，用户可见摘要不再展示内部账本 */
  rawProviderDetail(): string {
    if (!this.rawProviderEnabled) {
      return '';
    }
    const bits: string[] = [];
    bits.push(`落盘 ${this.rawProviderWritten}`);
    if (this.rawProviderFailed > 0) {
      bits.push(`落盘失败 ${this.rawProviderFailed}（已降级为仅解析链）`);
    }
    if (this.rawProviderIneligible > 0) {
      bits.push(`不适用 ${this.rawProviderIneligible}（原文非 Clash YAML）`);
    }
    if (this.rawProviderEmitted > 0) {
      bits.push(`配置内 provider ${this.rawProviderEmitted} 条`);
    }
    if (this.rawProviderPurged > 0) {
      bits.push(`已清理 ${this.rawProviderPurged} 个文件`);
    }
    let text = `；双轨 provider ${bits.join('，')}；${this.parsedVsProviderText()}`;
    if (this.rawProviderReasons.length > 0) {
      text += `〔${this.rawProviderReasons}〕`;
    }
    return text;
  }

  /** 完整账本（仅 hilog 留痕用；用户可见摘要见 summary） */
  debugSummary(): string {
    return this.summary() + this.rawProviderDetail();
  }

  /**
   * 用户可见摘要：只保留需要用户做决定的信息（成功数与非零的失败/异常计数）。
   * 输入数、配置丢弃、双轨账本等内部对账口径只进 hilog（debugSummary）。
   */
  summary(): string {
    const bits: string[] = [];
    bits.push(`成功 ${this.addedCount}`);
    if (this.duplicateCount > 0) {
      bits.push(`重复 ${this.duplicateCount}`);
    }
    if (this.invalidCount > 0) {
      bits.push(`无效 ${this.invalidCount}`);
    }
    if (this.unsupportedCount > 0) {
      bits.push(`不支持 ${this.unsupportedCount}${this.unsupportedDetail()}`);
    }
    if (this.limitCount > 0) {
      bits.push(`超限 ${this.limitCount}`);
    }
    if (this.persistFailedCount > 0) {
      bits.push(`保存失败 ${this.persistFailedCount}`);
    }
    if (this.hiddenCount > 0) {
      bits.push(`已隐藏 ${this.hiddenCount}`);
    }
    if (this.configMissingCredentialCount > 0) {
      bits.push(`凭据缺失 ${this.configMissingCredentialCount}`);
    }
    let text = bits.join('，');
    text += this.providerDetail();
    if (this.providerFailureReasons.length > 0) {
      text += `〔${this.providerFailureReasons}〕`;
    }
    return text;
  }
}

/** 刷新结果分类，移植自 subscription_refresh_result.dart */
export class SubscriptionRefreshResult {
  status: SubscriptionRefreshStatus = SubscriptionRefreshStatus.OK;
  message: string = '';
  nodeCount: number = 0;
  diagnostics: SubscriptionImportDiagnostics = new SubscriptionImportDiagnostics();
  /**
   * 面向用户的可操作建议（人话 + 下一步）。message 里含 URL 与原始错误码，适合日志；
   * 卡片/弹窗应当展示本字段。空串表示没有额外建议。
   */
  advice: string = '';

  static ok(nodeCount: number, diagnostics?: SubscriptionImportDiagnostics): SubscriptionRefreshResult {
    const r = new SubscriptionRefreshResult();
    r.status = SubscriptionRefreshStatus.OK;
    r.nodeCount = nodeCount;
    if (diagnostics !== undefined) {
      r.diagnostics = diagnostics;
    } else {
      r.diagnostics.addedCount = nodeCount;
    }
    return r;
  }

  static fail(status: SubscriptionRefreshStatus, message: string,
    diagnostics?: SubscriptionImportDiagnostics): SubscriptionRefreshResult {
    const r = new SubscriptionRefreshResult();
    r.status = status;
    r.message = message;
    if (diagnostics !== undefined) {
      r.diagnostics = diagnostics;
    }
    return r;
  }

  /** 面向用户的一句话原因 + 建议（无建议时退回 message / status 文本）。 */
  userText(fallback: string): string {
    if (this.advice.length > 0) {
      return this.advice;
    }
    if (this.message.length > 0) {
      return this.message;
    }
    return fallback;
  }
}
