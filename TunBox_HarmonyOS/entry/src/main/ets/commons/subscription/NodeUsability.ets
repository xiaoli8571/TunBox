/**
 * 节点可用性判定与原因分类（Node Usability）
 *
 * ## 为什么要它
 *
 * 订阅导入层有两类**完全不同**的「节点不可用」，过去被混成一句话「失败」，
 * 导致用户完全不知道该找谁：
 *
 * | 类别 | 含义 | 谁的问题 | 用户该做什么 |
 * |---|---|---|---|
 * | **定义不完整** | 解析层丢了参数（缺 uuid / 缺 REALITY 公钥 / 缺 password…） | **我们**（解析层 bug） | 换订阅源 / 报 bug；节点绝不能进内核代理表 |
 * | **域名无法解析** | 定义完全正确，但服务器域名在公网 DNS 上查不到 | **机场/线路** | 找机场换入口域名或换订阅 |
 *
 * 真机 2026-10-20 的 mitce 34 节点事件正是第二类：
 * `de152710bb8b70d108ec13c7.mitce-nocontact.com` 在阿里/腾讯/Cloudflare/Google
 * 四个解析器上全部 NXDOMAIN，而节点参数（uuid/flow/client-fingerprint/
 * reality-opts.public-key/short-id/tls/servername）**全部正确**。
 * 这种节点进内核代理表只会批量制造 mihomo 503（"An error occurred in the delay test"），
 * 让人误以为是"TunBox 解析坏了"。
 *
 * ## 本文件的口径
 *
 * - `definition` 轴：**定义层**是否完整（由参数表 + 必填校验给出）。
 * - `dns` 轴：**运行层**域名是否解析得到（由上层做 DNS 预检后回填）。
 * - 两轴**独立**：`definition=ok` 且 `dns=nxdomain` 的节点是「定义完整但线路死了」，
 *   它与「定义不完整」必须给出**不同的文案**，不能混成"失败"。
 * - 定义不完整的节点**绝不进内核代理表、不进测速集合**（半条节点 = 批量 503），
 *   但**必须在 UI 可见并带原因**（见 docs/sub-parse.md 第 4 节）。
 *
 * ## ArkTS 纪律
 *
 * 不用 enum（Node 侧 type-stripping 测试台不吃），一律 `export class` + `static readonly`；
 * 不 import 任何 kit（纯逻辑，可在 Node 侧直接跑）。
 */
import { ProtocolParamTableRegistry } from './ProtocolParamTable';

/** 不可用原因分类 */
export class UnusableCategory {
  /** 可用 */
  static readonly OK: string = 'ok';
  /** 定义不完整：缺必填参数（参数问题 —— 我们的问题） */
  static readonly INCOMPLETE: string = 'incomplete';
  /** 域名无法解析：定义完整但域名查不到（机场/线路问题 —— 不是我们的问题） */
  static readonly DNS: string = 'dns';
  /**
   * 订阅信息条目：机场把「剩余流量 / 到期时间 / 群链接」当成一个节点写进了订阅。
   *
   * 【2026-10-20 真机事件】飞鸟云那批 35 个节点里混了 6 条**根本不是节点**的信息：
   *   「剩余流量：596.22 GB」「套餐到期：长期有效 (2)」「有超过20多个节点，不够请到官网使用文档…」
   *   「每次使用前更新订阅到最新…」「电报群https://t.me/…」「防失联页https://github.com/…」
   * 它们有完整的 server/port/密码字段 ⇒ **缺参检测抓不到**，只能按内容判。
   * 这类条目**不进代理表、不进测速集合**，但在台账里留一条（用户能看到"这个订阅里有 N 条信息被跳过"）。
   *
   * ⚠ 它**不是** DNS 类：DNS 类是「节点定义正确、域名这次没解析出来」；
   *   信息条目是**压根不是节点**，两者原因必须分开说。
   */
  static readonly INFO: string = 'info';
}

/** DNS 解析状态 */
export class DnsState {
  /** 未探测 */
  static readonly UNKNOWN: string = 'unknown';
  /** 解析成功 */
  static readonly RESOLVED: string = 'resolved';
  /** 权威 NXDOMAIN：域名不存在（机场下线/线路废弃） */
  static readonly NXDOMAIN: string = 'nxdomain';
  /** 解析不到但不是权威 NXDOMAIN（DoH 不可用/超时/被污染） */
  static readonly UNRESOLVED: string = 'unresolved';
}

/** 单个节点的可用性结论 */
export class NodeAvailability {
  /** 原因分类（UnusableCategory） */
  category: string = UnusableCategory.OK;
  /** DNS 状态（DnsState） */
  dns: string = DnsState.UNKNOWN;
  /** 缺失的必填键（规范键名） */
  missing: string[] = [];
  /** 节点地址（域名），供上层做 DNS 预检 */
  server: string = '';
  /** 协议 */
  protocol: string = '';
  /** 一句话原因（中文，UI 直接展示） */
  reason: string = '';
  /** 补充说明（中文，UI 直接展示） */
  detail: string = '';

  /**
   * 定义是否完整 —— **唯一**决定"能不能进内核代理表 / 测速集合"的维度。
   *
   * 只有 INCOMPLETE（缺必填参数）才是 false：那种节点进内核只会批量制造 503。
   * DNS 类结论不影响入表（节点定义是对的，只是这次域名没解析出来）。
   */
  defined(): boolean {
    return this.category !== UnusableCategory.INCOMPLETE;
  }

  /**
   * 是否可用（可进代理表/测速集合）。
   *
   * = 定义完整**且不是信息条目**。**DNS 结论不参与判定** —— 域名查不到是运行层的结论，
   * 不能反过来把定义正确的节点踢出代理表（那会让"机场域名下线"变成
   * "TunBox 把节点删了"）。它只影响 UI 上的原因文案。
   *
   * 「订阅信息条目」例外：它压根不是节点（机场把流量/到期/群链接写成了节点），
   * 进代理表只会制造永远超时的假节点 ⇒ 同样不进。
   */
  usable(): boolean {
    return this.category === UnusableCategory.OK || this.category === UnusableCategory.DNS;
  }

  /** 是不是「订阅信息条目」（不是节点） */
  infoEntry(): boolean {
    return this.category === UnusableCategory.INFO;
  }
}

/** 节点可用性判定 */
export class NodeUsability {
  /**
   * 「订阅信息条目」的补充关键词（保守集合）。
   *
   * 硬判据是「名字里带 http(s) URL」；这里只补上**没有 URL** 的那几条
   * （「剩余流量：596.22 GB」「套餐到期：长期有效」「有超过20多个节点，不够请到官网使用文档…」
   * 「每次使用前更新订阅到最新…」「防失联页」）。
   */
  private static readonly INFO_KEYWORDS: string[] = [
    // 2026-10-24 修正：去掉裸词「流量/剩余/到期/过期/套餐」——「不限流量专线」「套餐
    // 专线」「到期可续」这类**真实节点名**会单词命中被整条剔除（静默少节点）。
    // 只留组合词：真机事件里的信息条（剩余流量：xxx GB / 套餐到期：xxx）全部能被
    // 组合词或 URL 硬判据覆盖，误杀面归零。
    '剩余流量', '套餐到期', '到期时间', '过期时间', '流量重置', '流量已用',
    '官网', '使用文档', '电报', '防失联', '公告', '更新订阅',
    // 2026-10-20 新增：按 UA 版本裁剪的面板会在 proxies 里塞「客户端太老」广告条
    // （实测 4 条 ss 1.1.1.1:1080 fake_node_password，其中 3 条名字不带 URL，
    //  旧关键词表拦不住 ⇒ 进了代理表且永远测速失败）。
    '客户端版本太老', '版本太老', '请到文档下载', '无法正常使用', '下载新版'
  ];
  /**
   * 定义层判定：按参数表检查必填键。
   *
   * @param protocol 规范协议名（vless/vmess/trojan/ss/ssr/hysteria2/tuic/anytls/snell/http/socks）
   * @param params 规范键 → 值（两条导入路径产出的都是同一套规范键）
   * @param server 节点地址（域名或 IP），写入结论供上层做 DNS 预检
   * @param name 节点显示名（订阅里的原始名）—— 用于识别「订阅信息条目」
   */
  static assess(protocol: string, params: Map<string, string>, server: string, name: string): NodeAvailability {
    const out = new NodeAvailability();
    out.protocol = protocol;
    out.server = server;
    const table = ProtocolParamTableRegistry.of(protocol);
    if (table === null) {
      // 未知协议：不在表里就没有必填口径，按"可用"处理（由上游按 unsupported 分类）。
      // ⚠ 绝不能因为"表里没有"就判不可用 —— 那会把所有新协议批量干掉。
      out.category = UnusableCategory.OK;
      out.reason = '';
      return out;
    }
    const missing: string[] = [];
    for (const spec of table.specs) {
      if (!spec.required) {
        continue;
      }
      const v = params.get(spec.key);
      if (v === undefined || v.length === 0) {
        missing.push(spec.key);
      }
    }
    // 条件必填（如 vless 的 security=reality ⇒ reality-public-key）
    for (const spec of table.specs) {
      if (spec.required || spec.requiredWhen.length === 0) {
        continue;
      }
      if (!ProtocolParamTableRegistry.isRequired(protocol, spec.key, params)) {
        continue;
      }
      const v = params.get(spec.key);
      if (v === undefined || v.length === 0) {
        missing.push(spec.key);
      }
    }
    if (missing.length > 0) {
      out.category = UnusableCategory.INCOMPLETE;
      out.missing = missing;
      out.reason = NodeUsability.incompleteReason(protocol, missing);
      out.detail = '定义不完整：解析层没能取到必填参数（我们的问题，需换订阅源或反馈）。'
        + '该节点不会进入内核代理表，也不会参与测速。';
      return out;
    }
    // 「订阅信息条目」判据（2026-10-20 真机事件：飞鸟云那批订阅里混了 6 条信息）。
    // 放在**必填校验之后**：信息条目往往是"参数齐全但不是节点"，
    // 先判它会让真正缺参的节点被归错类。
    if (NodeUsability.isInfoEntry(name)) {
      out.category = UnusableCategory.INFO;
      out.reason = NodeUsability.infoReason(name);
      out.detail = '订阅信息条目，非节点：机场把「剩余流量 / 到期时间 / 群链接」之类的信息'
        + '当成了一个节点写进订阅。它不会进入内核代理表，也不会参与测速。';
    }
    return out;
  }

  /**
   * 「订阅信息条目」判据。
   *
   * 优先用**硬判据**：名字里带 http(s) URL —— 这是机场信息条最稳定的特征。
   * 关键词表只作补充，且刻意保守（宁可放过，也不误杀真节点）：
   * 「香港 01」「IEPL 专线」这类正常名不会命中。
   *
   * ⚠ 关键词表里**没有**单字「群」：节点名带「群」太常见（群组/专线群），
   *   误杀真节点的代价远大于放过一条信息条目（信息条目还有 URL 判据兜底）。
   */
  static isInfoEntry(name: string): boolean {
    const text = name.trim();
    if (text.length === 0) {
      return false;
    }
    const lower = text.toLowerCase();
    if (lower.indexOf('http://') >= 0 || lower.indexOf('https://') >= 0) {
      return true;
    }
    for (const keyword of NodeUsability.INFO_KEYWORDS) {
      if (text.indexOf(keyword) >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 「订阅信息条目」文案 */
  static infoReason(name: string): string {
    const text = name.trim();
    const shown = text.length > 0 ? text : '(空名)';
    return `订阅信息条目，非节点：${shown}`;
  }

  /**
   * 回填 DNS 状态并重算文案。
   *
   * 只在**定义完整**的节点上改分类：定义不完整的节点保持 INCOMPLETE
   * （那才是我们的问题，DNS 结论会把真正的原因盖掉）。
   */
  static withDns(availability: NodeAvailability, dnsState: string): NodeAvailability {
    if (availability.category !== UnusableCategory.OK) {
      return availability;
    }
    availability.dns = dnsState;
    if (dnsState === DnsState.NXDOMAIN) {
      availability.category = UnusableCategory.DNS;
      availability.reason = NodeUsability.dnsReason(availability.server);
      availability.detail = '节点定义完全正确，但服务器域名在公网 DNS 上已查不到'
        + '（机场侧入口域名下线或线路废弃，不是 TunBox 的问题）。'
        + '请找机场确认入口域名或更换订阅。';
    } else if (dnsState === DnsState.UNRESOLVED) {
      availability.category = UnusableCategory.DNS;
      availability.reason = NodeUsability.dnsReason(availability.server);
      availability.detail = '节点定义完全正确，但本次探测没能解析到服务器域名'
        + '（可能是 DNS 出口受限或临时抖动，不一定是机场的问题）。';
    }
    return availability;
  }

  /** 「定义不完整」文案 */
  static incompleteReason(protocol: string, missing: string[]): string {
    return `定义不完整：${protocol} 缺少必填参数 ${missing.join('、')}`;
  }

  /** 「域名无法解析」文案 */
  static dnsReason(server: string): string {
    const host = server.length > 0 ? server : '(空)';
    return `域名无法解析：${host} 在公网 DNS 上查不到`;
  }

  /** 汇总文案（给 UI 的"这批节点"提示用） */
  static summary(availability: NodeAvailability): string {
    if (availability.category === UnusableCategory.INCOMPLETE) {
      return `${availability.reason}（共缺 ${availability.missing.length} 项）`;
    }
    if (availability.category === UnusableCategory.DNS) {
      return availability.reason;
    }
    if (availability.category === UnusableCategory.INFO) {
      return availability.reason;
    }
    return '';
  }
}
