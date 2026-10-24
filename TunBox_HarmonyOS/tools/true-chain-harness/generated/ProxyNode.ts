// [harness] generated from entry/src/main/ets/commons/models/ProxyNode.ets — 仅 import 目标被重写
/**
 * 数据模型：代理节点
 * 移植自 upstream: packages/tunbox_shared/lib/models/proxy_node.dart
 */
import { util } from './stubs.ts';
import { parse as parseUriNode, ParseError, ParsedNode } from './UriNodeParser.ts';
import { ProxyNodeAdapter } from './ProxyNodeAdapter.ts';

export enum ProxyNodeType {
  SSR = 'ssr',
  SS = 'ss',
  UNKNOWN = 'unknown'
}

export class ProxyNode {
  id: string = '';
  subscriptionId: string = '';
  /** 订阅中的原始节点名，用于代理组成员稳定解析；显示名加前缀或重名后缀时保持不变。 */
  originalName: string = '';
  name: string = '';
  server: string = '';
  port: number = 0;
  password: string = '';
  method: string = '';
  protocol: string = '';
  protocolParam: string = '';
  obfs: string = '';
  obfsParam: string = '';
  type: ProxyNodeType = ProxyNodeType.UNKNOWN;
  /** 真实代理类型字符串（vless/vmess/trojan/ss/ssr），用于展示与安全配置生成。 */
  proxyType: string = '';
  /** 现代协议白名单结构化字段。rawYaml 仅为旧存储兼容占位，禁止信任或输出。 */
  uuid: string = '';
  alterId: number = 0;
  udp: boolean = false;
  network: string = '';
  tls: boolean = false;
  servername: string = '';
  skipCertVerify: boolean = false;
  flow: string = '';
  /**
   * uTLS 指纹（mihomo 键 `client-fingerprint`，链接参数 `fp`，默认 chrome）。
   * ⚠ 与 certFingerprint **是两个不同的字段**，不可合并（曾经合并过，见下）。
   */
  clientFingerprint: string = '';
  /**
   * 证书指纹 pinSHA256（mihomo 键 `fingerprint`，链接参数 `pcs`/`pinSHA256`）。
   *
   * 为什么必须与 clientFingerprint 分开：mihomo 里
   *   `client-fingerprint` = uTLS 指纹（TLS 客户端伪装）
   *   `fingerprint`        = 证书指纹 pinSHA256（校验对端证书）
   * 是**语义完全不同的两个键**（见 mihomo common/convert/v.go：`fp`→client-fingerprint、
   * `pcs`→fingerprint）。此前两者共用一个槽位，于是 hysteria2 节点若同时带
   * `client-fingerprint` 与 `fingerprint`，前者会覆盖后者并被当成 pin 回写成
   * `fingerprint: chrome` —— 既丢了真正的 pin，又给内核一个非法的 pin 值。
   */
  certFingerprint: string = '';
  realityPublicKey: string = '';
  realityShortId: string = '';
  wsPath: string = '';
  wsHost: string = '';
  grpcServiceName: string = '';
  /** Hysteria2 (QUIC) 专属：带宽 up/down (Mbps)、口令混淆、ALPN。
   *  复用字段: password=认证口令, servername=sni, skipCertVerify=insecure,
   *  obfs=salamander/gecko, obfsParam=obfs-password, certFingerprint=pinSHA256。 */
  hyUp: string = '';
  hyDown: string = '';
  alpnList: string = '';
  /** 结构化槽位之外的额外 mihomo 键值(JSON 数组: [[key, value], ...])，生成配置时原样回写 */
  extraOpts: string = '';
  rawYaml: string = '';
  /**
   * 去凭据、去 name 的原始节点 flow-map 逐字模板（YamlMerger 构造）。
   * 与 rawYaml 不同：rawYaml 是旧存储占位（禁止输出），rawTemplate 已剔除
   * name/uuid/password/protocol-param/obfs-* 等，不含任何明文凭据，可安全
   * 持久化并在配置生成时原样回写（生成端再注入 name 与加密层回填的凭据）。
   */
  rawTemplate: string = '';
  rawUri: string = '';
  groupName: string = '';

  /** 已实现解析器的 URI scheme 注册表（与主流 Clash 客户端同构：认得的 scheme 逐个分发） */
  private static readonly URI_CODECS: Set<string> = new Set<string>([
    'ssr', 'ss', 'vless', 'vmess', 'trojan', 'hysteria2', 'hy2', 'tuic', 'anytls', 'hysteria'
  ]);

  /** scheme 是否有对应解析器（false = 未识别 scheme，由调用方计 unsupported 诊断） */
  static hasUriCodec(scheme: string): boolean {
    return ProxyNode.URI_CODECS.has(scheme.trim().toLowerCase());
  }

  /**
   * 解析一条分享链接 → ProxyNode。
   *
   * 【2026-10-20 起】统一走**新的规范解析层**（commons/subscription）：
   * 参数表（ProtocolParamTable）驱动的解析 + 规范键 → 旧 ProxyNode 字段的适配
   * （ProxyNodeAdapter）。这样分享链接路径与 Clash YAML 路径共用同一张参数表、
   * 同一套必填口径（缺必填 ⇒ 整条判不可用并给出原因，绝不半条节点）。
   *
   * 旧实现（ModernUriCodec.parse* / SsrCodec.parse*）已于 2026-10-20 **整体删除**：
   * 解析职责只剩规范解析层这一条路径（commons/subscription）。
   *
   * ⚠ hysteria v1（hysteria://）已并入新参数表（2026-10-20 B6），不再有旧分支。
   */
  static fromUri(uri: string, subscriptionId: string, id: string): ProxyNode | null {
    const trimmed = uri.trim();
    const schemeMatch = trimmed.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):\/\//);
    if (schemeMatch === null) {
      return null;
    }
    const scheme = schemeMatch[1].toLowerCase();
    if (!ProxyNode.URI_CODECS.has(scheme)) {
      return null;
    }
    const parsed: ParsedNode | ParseError = parseUriNode(trimmed, subscriptionId);
    if (parsed instanceof ParseError) {
      // 缺必填参数等：整条不可用（原因已进 UnusableLedger），绝不半条节点
      return null;
    }
    return ProxyNode.fromCanonical(parsed, subscriptionId, id);
  }

  /**
   * 规范解析结果 → ProxyNode（订阅导入/刷新链路用这个，不再走 fromUri）。
   *
   * 【2026-10-20 · B6】旧解析器退场后，**唯一**的「链接 → 节点」入口：
   *   规范解析层（UriNodeParser → ParsedNode）→ 这里落成旧 ProxyNode 字段。
   * fromUri 只剩「手动单条导入」（pages/NodeEditPage.ets）在用，内部也调这里。
   */
  static fromCanonical(parsed: ParsedNode, subscriptionId: string, id: string): ProxyNode | null {
    const node = new ProxyNode();
    node.id = id;
    node.subscriptionId = subscriptionId;
    node.name = parsed.name;
    node.server = parsed.server;
    node.port = parsed.port;
    node.rawUri = parsed.rawUri;
    node.rawYaml = '';
    ProxyNode.applyCanonical(node, parsed.protocol, parsed.params, parsed.unknownParams);
    if (parsed.protocol === 'ss') {
      node.type = ProxyNodeType.SS;
    } else if (parsed.protocol === 'ssr') {
      node.type = ProxyNodeType.SSR;
    } else {
      node.type = ProxyNodeType.UNKNOWN;
    }
    // 安全性收尾（server/port/uuid/network 合法性）——与旧实现同一处，不复制第二份
    return ProxyNode.finish(node);
  }

  // 说明: 旧版曾有一个 toClashProxy() 便捷方法, 它把一切非 ss/ssr 类型都当成 ss 输出,
  // 与 ClashConfigGenerator.proxyYamlLine() 的全协议实现冲突, 且全工程无人调用,
  // 已删除以免被误用导致 vless/vmess/trojan/hysteria2 节点被降级成 ss。
  /**
   * 把规范键落进旧 ProxyNode 字段（就地）。
   *
   * 映射表在 `ProxyNodeAdapter`（规范键 → 旧字段名，纯函数，可单测）；
   * **写值**在这里 —— 字段的主人写自己的字段，天然不会漏、也不会错位。
   * 拆成两半还有一个好处：适配器不必 import ProxyNode ⇒ 没有循环依赖。
   *
   * @param node 目标节点
   * @param protocol 规范协议名
   * @param params 规范键 → 值
   * @param unknown 解析层认出来的未声明键（不写进内核配置）
   */
  private static applyCanonical(node: ProxyNode, protocol: string, params: Map<string, string>,
    unknown: Map<string, string>): void {
    const fields = ProxyNodeAdapter.fieldMap(protocol, params);
    for (const field of fields.keys()) {
      const value = fields.get(field);
      if (value === undefined) {
        continue;
      }
      if (ProxyNodeAdapter.isBooleanField(field)) {
        // 分享链接里布尔常写 allow_insecure=1 / insecure=0（数字形态）；只认 'true' 会把
        // 「跳过证书校验」静默丢掉，自签证书机场的节点全部 TLS 握手失败。
        const boolValue = value === 'true' || value === '1';
        if (field === 'tls') {
          node.tls = boolValue;
        } else {
          node.skipCertVerify = boolValue;
        }
        continue;
      }
      if (ProxyNodeAdapter.isIntegerField(field)) {
        const n = parseInt(value);
        node.alterId = isNaN(n) ? 0 : n;
        continue;
      }
      ProxyNode.assignField(node, field, value);
    }
    // security（tls/reality/none）→ mihomo 的布尔 tls
    const tls = ProxyNodeAdapter.securityToTls(params);
    if (tls.length > 0) {
      node.tls = tls === 'true';
    }
    node.proxyType = protocol;
    if (ProxyNodeAdapter.supportsUdp(protocol)) {
      node.udp = true;
    }
    node.extraOpts = ProxyNodeAdapter.extraOpts(protocol, params, unknown);
  }

  /** 字段赋值（显式分支，避免动态索引在 ArkTS 下不可用） */
  private static assignField(node: ProxyNode, field: string, value: string): void {
    if (field === 'uuid') {
      node.uuid = value;
      return;
    }
    if (field === 'password') {
      node.password = value;
      return;
    }
    if (field === 'method') {
      node.method = value;
      return;
    }
    if (field === 'protocol') {
      node.protocol = value;
      return;
    }
    if (field === 'protocolParam') {
      node.protocolParam = value;
      return;
    }
    if (field === 'obfs') {
      node.obfs = value;
      return;
    }
    if (field === 'obfsParam') {
      node.obfsParam = value;
      return;
    }
    if (field === 'network') {
      node.network = value;
      return;
    }
    if (field === 'servername') {
      node.servername = value;
      return;
    }
    if (field === 'flow') {
      node.flow = value;
      return;
    }
    if (field === 'clientFingerprint') {
      node.clientFingerprint = value;
      return;
    }
    if (field === 'certFingerprint') {
      node.certFingerprint = value;
      return;
    }
    if (field === 'realityPublicKey') {
      node.realityPublicKey = value;
      return;
    }
    if (field === 'realityShortId') {
      node.realityShortId = value;
      return;
    }
    if (field === 'wsPath') {
      node.wsPath = value;
      return;
    }
    if (field === 'wsHost') {
      node.wsHost = value;
      return;
    }
    if (field === 'grpcServiceName') {
      node.grpcServiceName = value;
      return;
    }
    if (field === 'alpnList') {
      node.alpnList = value;
      return;
    }
    if (field === 'hyUp') {
      node.hyUp = value;
      return;
    }
    if (field === 'hyDown') {
      node.hyDown = value;
      return;
    }
  }

  /**
   * 节点安全性收尾（server/port/uuid/network 合法性 + 控制字符）。
   *
   * 【2026-10-20 · B6】从旧 ModernUriCodec.finish 搬进本类：旧解析器退场后
   * 这里就是**唯一**一道收尾闸，公开的原因：规范解析层（UriNodeParser →
   * ProxyNodeAdapter）产出的节点必须过**同一道**闸，不能复制第二份（复制就会漂移）。
   */
  private static finish(node: ProxyNode): ProxyNode | null {
    if (node.name.length === 0) {
      node.name = node.server;
    }
    const texts: string[] = [node.name, node.server, node.password, node.method, node.protocol,
      node.protocolParam, node.obfs, node.obfsParam, node.uuid, node.network, node.servername,
      node.flow, node.clientFingerprint, node.certFingerprint, node.realityPublicKey,
      node.realityShortId, node.wsPath,
      node.wsHost, node.grpcServiceName, node.hyUp, node.hyDown, node.alpnList];
    for (const value of texts) {
      if (!ProxyNode.isSafeText(value)) {
        return null;
      }
    }
    if (node.name.length === 0 || node.server.length === 0 || !/^([A-Za-z0-9.-]+|[0-9A-Fa-f:]+)$/.test(node.server)
      || node.server.includes('..') || node.server.startsWith('.') || node.server.endsWith('.')
      || isNaN(node.port) || !Number.isInteger(node.port) || node.port <= 0 || node.port >= 65536
      || node.alterId < 0 || !Number.isInteger(node.alterId)) {
      return null;
    }
    // 2026-10-24 修正：旧正则强制 RFC-4122 v4（版本位 [1-5]、variant 位 [89ABab]），
    // 比 mihomo 严格 —— 面板下发 version 位为 0/6-9/f 或 variant 位为 c 的 UUID 时
    // 整条静默丢弃（invalid 计数里看不出原因）。内核只要求 UUID 形态，此处对齐。
    if ((node.proxyType === 'vless' || node.proxyType === 'vmess')
      && !/^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/.test(node.uuid)) {
      return null;
    }
    // 支持的 network 取值必须与 mihomo 对齐：`httpupgrade` 是合法传输方式
    // （v2ray-http-upgrade，ws-opts 里配 v2ray-http-upgrade: true），
    // 此前不在白名单里 ⇒ 带 httpupgrade 的链接**整条被丢弃**。
    if (node.network.length > 0 && node.network !== 'tcp' && node.network !== 'ws'
      && node.network !== 'grpc' && node.network !== 'http' && node.network !== 'h2'
      && node.network !== 'xhttp' && node.network !== 'httpupgrade') {
      return null;
    }
    return node;
  }

  /** 控制字符/超长文本检查（与旧实现同口径） */
  private static isSafeText(value: string): boolean {
    if (value.length > 64 * 1024 || value.includes('\n') || value.includes('\r')
      || value.includes('\u0000')) {
      return false;
    }
    for (let i = 0; i < value.length; i++) {
      const code = value.charCodeAt(i);
      if (code < 0x20 || code === 0x7f) {
        return false;
      }
    }
    return true;
  }

}

/**
 * base64url 编解码工具（订阅正文、链接列表、SSR 载荷共用）。
 *
 * 2026-10-20（B6 旧解析器退场）：旧解析器本体（parseSsr / parseSs /
 * ModernUriCodec.parse*）已**全部删除** —— 解析职责由 commons/subscription 的
 * 规范解析层（参数表 + UriNodeParser + ProxyNodeAdapter）唯一承担。
 *
 * 2026-10-20（lead 拍板改名）：原名 `SsrCodec` **名不副实** —— 它早已不含任何
 * SSR 编解码逻辑，只剩**纯 base64url 工具**（订阅正文 / 链接列表的 base64 解码），
 * 名字却让人以为还有 SSR 解析残留。改名为 `Base64Codec`，职责与名字对齐。
 * 调用方仅三处（SubscriptionParser / SubscriptionService / compare_forms.mjs）。
 */
export class Base64Codec {
  private static b64 = new util.Base64Helper();
  private static decoder = util.TextDecoder.create('utf-8');

  /** URL-safe base64 → 文本（兼容缺少 padding 的情况） */
  static decodeBase64Url(input: string): string {
    let s = input.replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4 !== 0) {
      s += '=';
    }
    try {
      const bytes = Base64Codec.b64.decodeSync(s, util.Type.MIME);
      return Base64Codec.decoder.decodeToString(bytes);
    } catch (e) {
      try {
        const bytes = Base64Codec.b64.decodeSync(s, util.Type.BASIC);
        return Base64Codec.decoder.decodeToString(bytes);
      } catch (e2) {
        return '';
      }
    }
  }
}
