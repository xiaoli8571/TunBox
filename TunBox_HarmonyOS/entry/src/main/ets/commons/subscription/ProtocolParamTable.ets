/**
 * 协议参数表（Protocol Parameter Table）
 *
 * ## 为什么要它
 *
 * 2026-10-20 真机报障：mitce.io 的 34 个 VLESS·REALITY 节点测速**全部秒失败**
 * （mihomo 503，5-10ms），而同一次测速里别的订阅节点正常、隧道用同一个节点也能连通。
 * mihomo 的 503 语义是 URLTest 返回了 error（hub/route/proxies.go:135-143，
 * 只有 err!=nil 或 delay==0 才给 "An error occurred in the delay test"）。
 * 也就是说：**节点进了内核代理表（所以不是 404），但握手参数不完整 → 拨号立刻失败**。
 *
 * 历史上就出过同型事故：「36 个 anytls 因解析丢凭据被丢弃」。
 * 根因都是同一个：**参数在解析层被改名/丢弃/写错字段，且没有任何闸门能证明它没丢**。
 *
 * ⇒ 本文件把「每个协议有哪些参数、参数叫什么、哪些必填、哪些敏感、
 *   最终写进 mihomo 配置的哪个字段」写成**机器可读的表**，
 *   解析器按表消费、闸门按表核对 —— 参数的「保真」从此有唯一真源。
 *
 * ## 表的字段语义
 *
 * - `key`：**规范键**（canonical key）。解析结果一律用规范键，URI 里的别名只用于定位。
 * - `valueType`：string / int / bool / port / list / enum。
 * - `required`：**必填**。缺了 → 整条节点 unusable（见 UriNodeParser），**绝不半条**。
 * - `requiredWhen`：条件必填，形如 `security=reality`。
 *   REALITY 的 public-key 就是这么表达的：**security=reality 时缺 public-key ⇒ 整条不可用**，
 *   这正是「节点在内核里存在但握手秒失败」的那一类事故，必须在解析层就拦住。
 * - `sensitive`：**敏感**（凭据类）。闸门对这些值用 sha256 前 8 位比对摘要，
 *   既证明值没被改写/截断，又避免把明文凭据写进日志。
 * - `mihomoField`：**写进 mihomo 配置的哪个字段**（`reality-opts.public-key` 这种带层级的写法）。
 * - `aliases`：同一个参数在分享链接里的不同写法（面板之间不统一）。
 * - `source`：authority（userinfo@host:port）/ fragment（#名称）/ query（?k=v）/ body（vmess/ssr 的 base64 载荷）。
 * - `transport`：仅在某种传输下生效（ws / grpc / http / h2 / xhttp），否则为 any。
 *   作用：`path`/`host` 在 ws 是 `ws-opts.*`、在 h2 是 `h2-opts.*`、在 http 是 `http-opts.*`，
 *   靠 URI 里那个 `type=`/`net=` 决定 —— 靠正则猜协议形态就会写错字段。
 *
 * ## ArkTS 纪律
 *
 * 本文件不使用 enum / interface / 未标注对象字面量（`arkts-no-untyped-obj-literals`），
 * 一律 `export class` + 字段赋值；不 import 任何 kit（纯逻辑，可在 Node 侧直接跑）。
 */

/** 单个参数的声明 */
export class ParamSpec {
  /** 规范键（解析结果里的键） */
  key: string = '';
  /** 值类型：string / int / bool / port / list / enum */
  valueType: string = 'string';
  /** 必填：缺了整条节点 unusable */
  required: boolean = false;
  /** 敏感（凭据类）：闸门用摘要比对，日志须脱敏 */
  sensitive: boolean = false;
  /** 写进 mihomo 配置的字段（层级用 '.'） */
  mihomoField: string = '';
  /** URI 里的别名写法 */
  aliases: string[] = [];
  /** 来源：authority / fragment / query / body */
  source: string = 'query';
  /** 仅在指定传输下生效：any / ws / grpc / http / h2 / xhttp */
  transport: string = 'any';
  /** 条件必填，形如 'security=reality' */
  requiredWhen: string = '';
  /** 备注 */
  note: string = '';
}

/** 一个协议的参数表 */
export class ProtocolParamTable {
  /** 规范协议名（vless / vmess / trojan / ss / ssr / hysteria2 / tuic / anytls / snell / http / socks） */
  protocol: string = '';
  /** 显示名 */
  title: string = '';
  /** 参数声明（顺序即文档顺序） */
  specs: ParamSpec[] = [];

  /** 本表声明的全部规范键 */
  declaredKeys(): string[] {
    const out: string[] = [];
    for (const spec of this.specs) {
      out.push(spec.key);
    }
    return out;
  }

  /** 按规范键取声明 */
  specOf(key: string): ParamSpec | null {
    for (const spec of this.specs) {
      if (spec.key === key) {
        return spec;
      }
    }
    return null;
  }

  /** 敏感键清单 */
  sensitiveKeys(): string[] {
    const out: string[] = [];
    for (const spec of this.specs) {
      if (spec.sensitive) {
        out.push(spec.key);
      }
    }
    return out;
  }
}

/** 参数声明构造辅助（flags 串：R=必填 S=敏感 B=bool I=int P=port L=list E=enum） */
export class ProtocolParamTableRegistry {
  private static tables: Map<string, ProtocolParamTable> = ProtocolParamTableRegistry.build();

  /** 全部协议名 */
  static protocols(): string[] {
    const out: string[] = [];
    for (const key of ProtocolParamTableRegistry.tables.keys()) {
      out.push(key);
    }
    out.sort();
    return out;
  }

  /** 取协议表；未知协议返回 null */
  static of(protocol: string): ProtocolParamTable | null {
    const t = ProtocolParamTableRegistry.tables.get(protocol);
    return t === undefined ? null : t;
  }

  /** URI scheme → 规范协议名；'' 表示不支持 */
  static protocolOfScheme(scheme: string): string {
    const s = scheme.toLowerCase();
    if (s === 'vless') {
      return 'vless';
    }
    if (s === 'vmess') {
      return 'vmess';
    }
    if (s === 'trojan') {
      return 'trojan';
    }
    if (s === 'ss') {
      return 'ss';
    }
    if (s === 'ssr') {
      return 'ssr';
    }
    if (s === 'hysteria') {
      // hysteria v1（UDP/QUIC）。2026-10-20 旧解析器退场时并入规范层，
      // 否则删掉旧实现就等于**丢掉这个协议**（机场还在发 hysteria:// 链接）。
      return 'hysteria';
    }
    if (s === 'hysteria2' || s === 'hy2') {
      return 'hysteria2';
    }
    if (s === 'tuic') {
      return 'tuic';
    }
    if (s === 'anytls') {
      return 'anytls';
    }
    if (s === 'snell') {
      return 'snell';
    }
    if (s === 'http' || s === 'https') {
      return 'http';
    }
    if (s === 'socks' || s === 'socks5') {
      return 'socks';
    }
    return '';
  }

  /**
   * 别名 → 规范键。network 决定传输类参数（path/host 在 ws/h2/http/xhttp 下落在不同字段）。
   * 找不到返回 ''（**未知参数不得静默丢弃**，解析器会放进 unknownParams 让上层可见）。
   */
  static resolveAlias(protocol: string, network: string, alias: string): string {
    const table = ProtocolParamTableRegistry.of(protocol);
    if (table === null) {
      return '';
    }
    const wanted = alias.toLowerCase();
    let anyMatch: string = '';
    for (const spec of table.specs) {
      let hit = false;
      for (const a of spec.aliases) {
        if (a.toLowerCase() === wanted) {
          hit = true;
          break;
        }
      }
      if (!hit) {
        continue;
      }
      if (spec.transport === 'any') {
        if (anyMatch.length === 0) {
          anyMatch = spec.key;
        }
        continue;
      }
      if (spec.transport === network.toLowerCase()) {
        return spec.key;
      }
    }
    return anyMatch;
  }

  /** 按规范键取声明（未知协议返回 null） */
  static specOf(protocol: string, key: string): ParamSpec | null {
    const table = ProtocolParamTableRegistry.of(protocol);
    if (table === null) {
      return null;
    }
    return table.specOf(key);
  }

  /** 必填键清单（不含条件必填） */
  static requiredKeys(protocol: string): string[] {
    const out: string[] = [];
    const table = ProtocolParamTableRegistry.of(protocol);
    if (table === null) {
      return out;
    }
    for (const spec of table.specs) {
      if (spec.required) {
        out.push(spec.key);
      }
    }
    return out;
  }

  /** 敏感键清单 */
  static sensitiveKeys(protocol: string): string[] {
    const table = ProtocolParamTableRegistry.of(protocol);
    if (table === null) {
      return [];
    }
    return table.sensitiveKeys();
  }

  /** 某键在给定参数集下是否必填（处理 requiredWhen 条件必填） */
  static isRequired(protocol: string, key: string, params: Map<string, string>): boolean {
    const spec = ProtocolParamTableRegistry.specOf(protocol, key);
    if (spec === null) {
      return false;
    }
    if (spec.required) {
      return true;
    }
    if (spec.requiredWhen.length === 0) {
      return false;
    }
    const parts = spec.requiredWhen.split('=');
    if (parts.length !== 2) {
      return false;
    }
    const condKey = parts[0];
    const condValue = parts[1];
    const actual = params.get(condKey);
    if (actual === undefined) {
      return false;
    }
    return actual === condValue;
  }

  // ─────────────────────────── 表的构造 ───────────────────────────

  private static build(): Map<string, ProtocolParamTable> {
    const m: Map<string, ProtocolParamTable> = new Map<string, ProtocolParamTable>();
    m.set('vless', ProtocolParamTableRegistry.vless());
    m.set('vmess', ProtocolParamTableRegistry.vmess());
    m.set('trojan', ProtocolParamTableRegistry.trojan());
    m.set('ss', ProtocolParamTableRegistry.ss());
    m.set('ssr', ProtocolParamTableRegistry.ssr());
    m.set('hysteria2', ProtocolParamTableRegistry.hysteria2());
    m.set('hysteria', ProtocolParamTableRegistry.hysteria());
    m.set('tuic', ProtocolParamTableRegistry.tuic());
    m.set('anytls', ProtocolParamTableRegistry.anytls());
    m.set('snell', ProtocolParamTableRegistry.snell());
    m.set('http', ProtocolParamTableRegistry.http());
    m.set('socks', ProtocolParamTableRegistry.socks());
    return m;
  }

  /** 构造一条参数声明 */
  private static p(key: string, mihomoField: string, aliases: string[],
    flags: string, source: string, transport: string, requiredWhen: string, note: string): ParamSpec {
    const s = new ParamSpec();
    s.key = key;
    s.valueType = 'string';
    if (flags.includes('B')) {
      s.valueType = 'bool';
    } else if (flags.includes('I')) {
      s.valueType = 'int';
    } else if (flags.includes('P')) {
      s.valueType = 'port';
    } else if (flags.includes('L')) {
      s.valueType = 'list';
    } else if (flags.includes('E')) {
      s.valueType = 'enum';
    }
    s.required = flags.includes('R');
    s.sensitive = flags.includes('S');
    s.mihomoField = mihomoField;
    s.aliases = aliases;
    s.source = source;
    s.transport = transport;
    s.requiredWhen = requiredWhen;
    s.note = note;
    return s;
  }

  /** 结构性三件套：name / server / port */
  private static structural(t: ProtocolParamTable, nameAlias: string, nameSource: string,
    serverAlias: string, portAlias: string, addrSource: string): void {
    const n = ProtocolParamTableRegistry.p('name', 'name', [nameAlias], '', nameSource, 'any', '',
      '显示名；缺失时回落到 server');
    t.specs.push(n);
    const s = ProtocolParamTableRegistry.p('server', 'server', [serverAlias], 'R', addrSource, 'any', '',
      '节点地址');
    t.specs.push(s);
    const po = ProtocolParamTableRegistry.p('port', 'port', [portAlias], 'RP', addrSource, 'any', '',
      '端口；hysteria2 的端口跳跃区间原样保留（生成端再按 mihomo 的 ports 键回写）');
    t.specs.push(po);
  }

  /** 传输层参数（ws / grpc / http / h2 / xhttp） */
  private static transports(t: ProtocolParamTable): void {
    t.specs.push(ProtocolParamTableRegistry.p('network', 'network', ['type', 'network', 'net'], 'E',
      'query', 'any', '', '传输方式；决定 path/host 落在哪个 opts 结构里'));
    t.specs.push(ProtocolParamTableRegistry.p('ws-path', 'ws-opts.path', ['path'], '', 'query', 'ws', '',
      'WebSocket 路径'));
    t.specs.push(ProtocolParamTableRegistry.p('ws-host', 'ws-opts.headers.Host', ['host'], '', 'query', 'ws', '',
      'WebSocket Host 头'));
    t.specs.push(ProtocolParamTableRegistry.p('ws-early-data', 'ws-opts.max-early-data', ['ed'], 'I', 'query', 'ws',
      '', 'ws 早数据长度（0-65535）'));
    t.specs.push(ProtocolParamTableRegistry.p('ws-early-data-header-name', 'ws-opts.early-data-header-name',
      ['eh'], '', 'query', 'ws', '', '早数据请求头名'));
    // httpupgrade 的早数据是**开关**而不是长度：mihomo 用
    // `ws-opts.v2ray-http-upgrade-fast-open: true` 表示，链接里的 `ed` 只说明
    // "有早数据"（数值不落地）—— 与旧实现（mihomo common/convert/v.go）同语义。
    t.specs.push(ProtocolParamTableRegistry.p('ws-early-data-fast-open',
      'ws-opts.v2ray-http-upgrade-fast-open', ['ed'], 'B', 'query', 'httpupgrade',
      '', 'httpupgrade 早数据开关（链接里的 ed 数值不落地，只表示"有早数据"）'));
    t.specs.push(ProtocolParamTableRegistry.p('grpc-service-name', 'grpc-opts.grpc-service-name',
      ['serviceName', 'servicename', 'grpc-service-name'], '', 'query', 'grpc', '', 'gRPC 服务名'));
    t.specs.push(ProtocolParamTableRegistry.p('grpc-mode', '（mihomo 无对应字段）', ['mode'], '', 'query', 'grpc', '',
      'gRPC 模式（gun/multi）；mihomo 不支持，但机场链接普遍带'));
    t.specs.push(ProtocolParamTableRegistry.p('grpc-authority', '（mihomo 无对应字段）', ['authority'], '', 'query',
      'grpc', '', 'gRPC authority；mihomo 不支持'));
    t.specs.push(ProtocolParamTableRegistry.p('h2-host', 'h2-opts.host', ['host'], '', 'query', 'h2', '',
      'HTTP/2 host'));
    t.specs.push(ProtocolParamTableRegistry.p('h2-path', 'h2-opts.path', ['path'], '', 'query', 'h2', '',
      'HTTP/2 路径'));
    t.specs.push(ProtocolParamTableRegistry.p('http-path', 'http-opts.path', ['path'], '', 'query', 'http', '',
      'HTTP 路径'));
    t.specs.push(ProtocolParamTableRegistry.p('http-host', 'http-opts.headers.Host', ['host'], '', 'query', 'http',
      '', 'HTTP Host 头'));
    t.specs.push(ProtocolParamTableRegistry.p('xhttp-path', 'xhttp-opts.path', ['path'], '', 'query', 'xhttp', '',
      'XHTTP 路径'));
    t.specs.push(ProtocolParamTableRegistry.p('xhttp-host', 'xhttp-opts.host', ['host'], '', 'query', 'xhttp', '',
      'XHTTP host'));
  }

  /** uTLS / 证书指纹 */
  private static fingerprints(t: ProtocolParamTable, allowUtls: boolean, allowPin: boolean): void {
    if (allowUtls) {
      t.specs.push(ProtocolParamTableRegistry.p('client-fingerprint', 'client-fingerprint',
        ['fp', 'client-fingerprint', 'utls-fingerprint'], '', 'query', 'any', '',
        'uTLS 指纹（chrome/firefox/safari/ios/…）；与证书指纹 fingerprint 是两个独立的键'));
    }
    if (allowPin) {
      t.specs.push(ProtocolParamTableRegistry.p('fingerprint', 'fingerprint',
        ['pcs', 'pinSHA256', 'fingerprint'], '', 'query', 'any', '', '证书指纹 pinSHA256'));
    }
  }

  /** 通用补充键（mihomo 顶层有效键，分享链接常见） */
  private static extras(t: ProtocolParamTable, source: string): void {
    t.specs.push(ProtocolParamTableRegistry.p('skip-cert-verify', 'skip-cert-verify',
      ['allowInsecure', 'allow-insecure', 'allow_insecure', 'insecure', 'skip-cert-verify'], 'B', source, 'any',
      '', '跳过证书校验'));
    t.specs.push(ProtocolParamTableRegistry.p('alpn', 'alpn', ['alpn'], 'L', source, 'any', '', 'ALPN 列表'));
    t.specs.push(ProtocolParamTableRegistry.p('packet-encoding', 'packet-encoding',
      ['packet-encoding', 'packetencoding'], '', source, 'any', '', '数据包编码'));
    t.specs.push(ProtocolParamTableRegistry.p('tfo', 'tfo', ['tfo'], 'B', source, 'any', '', 'TCP Fast Open'));
    t.specs.push(ProtocolParamTableRegistry.p('mptcp', 'mptcp', ['mptcp'], 'B', source, 'any', '', 'MPTCP'));
    t.specs.push(ProtocolParamTableRegistry.p('smux', 'smux', ['smux'], '', source, 'any', '', 'smux 复用'));
    t.specs.push(ProtocolParamTableRegistry.p('ip-version', 'ip-version', ['ip-version', 'ipversion'], '',
      source, 'any', '', 'IP 版本'));
    t.specs.push(ProtocolParamTableRegistry.p('dialer-proxy', 'dialer-proxy', ['dialer-proxy', 'dialerproxy'], '',
      source, 'any', '', '链式出站'));
  }

  private static vless(): ProtocolParamTable {
    const t = new ProtocolParamTable();
    t.protocol = 'vless';
    t.title = 'VLESS';
    ProtocolParamTableRegistry.structural(t, 'name', 'fragment', 'server', 'port', 'authority');
    t.specs.push(ProtocolParamTableRegistry.p('uuid', 'uuid', [], 'RS', 'authority', 'any', '',
      '用户 UUID（userinfo 部分）'));
    t.specs.push(ProtocolParamTableRegistry.p('flow', 'flow', ['flow'], '', 'query', 'any', '',
      '流控（xtls-rprx-vision 等）'));
    // ⚠ vless 的 SNI 必须单独声明：mihomo 的 vless 用 servername 键，
    //   REALITY 节点几乎必填（填目标站域名），漏了会被当成"没填 SNI"→ 握手失败。
    t.specs.push(ProtocolParamTableRegistry.p('sni', 'servername', ['sni', 'peer'], '', 'query', 'any', '',
      'SNI（REALITY 节点通常填目标站域名；mihomo 的 vless 用 servername 键）'));
    t.specs.push(ProtocolParamTableRegistry.p('security', 'tls', ['security'], 'E', 'query', 'any', '',
      'security=reality ⇒ tls: true 且必须带 public-key'));
    t.specs.push(ProtocolParamTableRegistry.p('reality-public-key', 'reality-opts.public-key',
      ['pbk', 'public-key', 'reality-pbk'], 'S', 'query', 'any', 'security=reality',
      'REALITY 公钥；security=reality 时条件必填（缺了就是握手秒失败那类事故）'));
    t.specs.push(ProtocolParamTableRegistry.p('reality-short-id', 'reality-opts.short-id',
      ['sid', 'short-id', 'reality-sid'], 'S', 'query', 'any', '',
      'REALITY short-id；mihomo 允许为空，但机场通常给 0-16 位十六进制'));
    t.specs.push(ProtocolParamTableRegistry.p('reality-spider-x', '（mihomo 无对应字段）', ['spx'], '',
      'query', 'any', '', 'REALITY spiderX；mihomo 用不到，但必须识别出来而不是当垃圾丢掉'));
    t.specs.push(ProtocolParamTableRegistry.p('encryption', '（mihomo 无对应字段）', ['encryption'], '',
      'query', 'any', '', 'VLESS 加密方式，机场恒为 none；mihomo 的 vless 无此字段'));
    t.specs.push(ProtocolParamTableRegistry.p('header-type', '（mihomo 无对应字段）', ['headerType'], '',
      'query', 'any', '', '伪装头类型（none/http）；mihomo 无此字段'));
    ProtocolParamTableRegistry.transports(t);
    ProtocolParamTableRegistry.fingerprints(t, true, true);
    ProtocolParamTableRegistry.extras(t, 'query');
    return t;
  }

  private static vmess(): ProtocolParamTable {
    const t = new ProtocolParamTable();
    t.protocol = 'vmess';
    t.title = 'VMess';
    ProtocolParamTableRegistry.structural(t, 'ps', 'body', 'add', 'port', 'body');
    t.specs.push(ProtocolParamTableRegistry.p('uuid', 'uuid', ['id'], 'RS', 'body', 'any', '',
      '用户 UUID（v2rayN JSON 的 id 字段）'));
    t.specs.push(ProtocolParamTableRegistry.p('alter-id', 'alterId', ['aid'], 'I', 'body', 'any', '',
      'alterId'));
    t.specs.push(ProtocolParamTableRegistry.p('cipher', 'cipher', ['scy'], '', 'body', 'any', '',
      '加密方式（v2rayN JSON 的 scy 字段）'));
    t.specs.push(ProtocolParamTableRegistry.p('tls', 'tls', ['tls'], 'B', 'body', 'any', '',
      '是否启用 TLS'));
    t.specs.push(ProtocolParamTableRegistry.p('sni', 'servername', ['sni'], '', 'body', 'any', '', 'SNI'));
    // ⚠ vmess 的 JSON 里 'type' 是**伪装头类型**（none/http），不是传输方式 ——
    //   传输方式是 'net'。早前把 'type' 认成 network 会把 tcp 节点写成 http。
    t.specs.push(ProtocolParamTableRegistry.p('network', 'network', ['net'], 'E', 'body', 'any', '',
      '传输方式'));
    t.specs.push(ProtocolParamTableRegistry.p('header-type', '（mihomo 无对应字段）', ['type'], '', 'body', 'any', '',
      '伪装头类型（none/http）；⚠ 不是传输方式，别当 network'));
    t.specs.push(ProtocolParamTableRegistry.p('ws-path', 'ws-opts.path', ['path'], '', 'body', 'ws', '',
      'WebSocket 路径'));
    t.specs.push(ProtocolParamTableRegistry.p('ws-host', 'ws-opts.headers.Host', ['host'], '', 'body', 'ws', '',
      'WebSocket Host 头'));
    t.specs.push(ProtocolParamTableRegistry.p('grpc-service-name', 'grpc-opts.grpc-service-name',
      ['serviceName', 'path'], '', 'body', 'grpc', '', 'gRPC 服务名'));
    t.specs.push(ProtocolParamTableRegistry.p('h2-host', 'h2-opts.host', ['host'], '', 'body', 'h2', '', 'HTTP/2 host'));
    t.specs.push(ProtocolParamTableRegistry.p('h2-path', 'h2-opts.path', ['path'], '', 'body', 'h2', '', 'HTTP/2 路径'));
    t.specs.push(ProtocolParamTableRegistry.p('http-path', 'http-opts.path', ['path'], '', 'body', 'http', '',
      'HTTP 路径'));
    t.specs.push(ProtocolParamTableRegistry.p('http-host', 'http-opts.headers.Host', ['host'], '', 'body', 'http',
      '', 'HTTP Host 头'));
    ProtocolParamTableRegistry.fingerprints(t, false, true);
    ProtocolParamTableRegistry.extras(t, 'body');
    return t;
  }

  private static trojan(): ProtocolParamTable {
    const t = new ProtocolParamTable();
    t.protocol = 'trojan';
    t.title = 'Trojan';
    ProtocolParamTableRegistry.structural(t, 'name', 'fragment', 'server', 'port', 'authority');
    t.specs.push(ProtocolParamTableRegistry.p('password', 'password', [], 'RS', 'authority', 'any', '',
      '口令（userinfo 部分）'));
    t.specs.push(ProtocolParamTableRegistry.p('sni', 'servername', ['sni', 'peer'], '', 'query', 'any', '', 'SNI'));
    ProtocolParamTableRegistry.transports(t);
    ProtocolParamTableRegistry.fingerprints(t, true, true);
    ProtocolParamTableRegistry.extras(t, 'query');
    return t;
  }

  private static ss(): ProtocolParamTable {
    const t = new ProtocolParamTable();
    t.protocol = 'ss';
    t.title = 'Shadowsocks';
    ProtocolParamTableRegistry.structural(t, 'name', 'fragment', 'server', 'port', 'authority');
    t.specs.push(ProtocolParamTableRegistry.p('cipher', 'cipher', [], 'R', 'authority', 'any', '',
      '加密方式（userinfo 的 method:password 前半段）'));
    t.specs.push(ProtocolParamTableRegistry.p('password', 'password', [], 'RS', 'authority', 'any', '',
      '口令（userinfo 的 method:password 后半段）'));
    t.specs.push(ProtocolParamTableRegistry.p('plugin', 'plugin', ['plugin'], '', 'query', 'any', '', 'SIP003 插件'));
    t.specs.push(ProtocolParamTableRegistry.p('plugin-opts', 'plugin-opts', ['plugin-opts'], '', 'query', 'any', '',
      'SIP003 插件参数'));
    ProtocolParamTableRegistry.extras(t, 'query');
    return t;
  }

  private static ssr(): ProtocolParamTable {
    const t = new ProtocolParamTable();
    t.protocol = 'ssr';
    t.title = 'ShadowsocksR';
    ProtocolParamTableRegistry.structural(t, 'remarks', 'body', 'server', 'port', 'body');
    t.specs.push(ProtocolParamTableRegistry.p('cipher', 'cipher', [], 'R', 'body', 'any', '',
      '加密方式（载荷第 4 段）'));
    t.specs.push(ProtocolParamTableRegistry.p('password', 'password', [], 'RS', 'body', 'any', '',
      '口令（载荷第 6 段）'));
    t.specs.push(ProtocolParamTableRegistry.p('protocol', 'protocol', [], 'R', 'body', 'any', '',
      '协议插件（载荷第 3 段）'));
    t.specs.push(ProtocolParamTableRegistry.p('obfs', 'obfs', [], 'R', 'body', 'any', '',
      '混淆插件（载荷第 5 段）'));
    t.specs.push(ProtocolParamTableRegistry.p('protocol-param', 'protocol-param', ['protoparam'], '', 'body', 'any',
      '', '协议插件参数'));
    t.specs.push(ProtocolParamTableRegistry.p('obfs-param', 'obfs-param', ['obfsparam'], '', 'body', 'any', '',
      '混淆插件参数'));
    ProtocolParamTableRegistry.extras(t, 'query');
    return t;
  }

  private static hysteria2(): ProtocolParamTable {
    const t = new ProtocolParamTable();
    t.protocol = 'hysteria2';
    t.title = 'Hysteria2';
    ProtocolParamTableRegistry.structural(t, 'name', 'fragment', 'server', 'port', 'authority');
    t.specs.push(ProtocolParamTableRegistry.p('password', 'password', [], 'RS', 'authority', 'any', '',
      '认证口令（userinfo 部分）'));
    t.specs.push(ProtocolParamTableRegistry.p('sni', 'sni', ['sni', 'peer'], '', 'query', 'any', '',
      'SNI（mihomo 的 hysteria2 用 sni 键，不接受 servername）'));
    t.specs.push(ProtocolParamTableRegistry.p('obfs', 'obfs', ['obfs'], '', 'query', 'any', '', '混淆方式'));
    t.specs.push(ProtocolParamTableRegistry.p('obfs-password', 'obfs-password',
      ['obfs-password', 'obfs_password'], 'S', 'query', 'any', '', '混淆口令'));
    t.specs.push(ProtocolParamTableRegistry.p('up', 'up', ['up', 'upmbps'], '', 'query', 'any', '', '上行带宽'));
    t.specs.push(ProtocolParamTableRegistry.p('down', 'down', ['down', 'downmbps'], '', 'query', 'any', '',
      '下行带宽'));
    t.specs.push(ProtocolParamTableRegistry.p('ports', 'ports', ['ports'], '', 'query', 'any', '',
      '端口跳跃区间/列表（部分面板放在 query 里）'));
    ProtocolParamTableRegistry.fingerprints(t, false, true);
    ProtocolParamTableRegistry.extras(t, 'query');
    return t;
  }

  /**
   * Hysteria v1（`hysteria://`）。
   *
   * 2026-10-20：旧解析器（ModernUriCodec.parseHysteria）退场时并入规范层 ——
   * 不并入就等于**删掉这个协议**（机场仍在发 hysteria:// 链接）。
   * 字段口径沿用旧实现：认证口令来自 userinfo 或 `auth`/`auth_str`/`auth-str`，
   * SNI 在 `peer`/`sni`，带宽在 `up`/`upmbps`、`down`/`downmbps`。
   */
  private static hysteria(): ProtocolParamTable {
    const t = new ProtocolParamTable();
    t.protocol = 'hysteria';
    t.title = 'Hysteria v1';
    ProtocolParamTableRegistry.structural(t, 'name', 'fragment', 'server', 'port', 'authority');
    t.specs.push(ProtocolParamTableRegistry.p('password', 'password',
      ['auth', 'auth_str', 'auth-str'], 'RS', 'authority', 'any', '',
      '认证口令（userinfo 或 auth/auth_str/auth-str；面板两种写法都有）'));
    t.specs.push(ProtocolParamTableRegistry.p('sni', 'sni', ['peer', 'sni'], '', 'query', 'any', '',
      'SNI（mihomo 的 hysteria v1 用 sni 键）'));
    t.specs.push(ProtocolParamTableRegistry.p('obfs', 'obfs', ['obfs'], '', 'query', 'any', '', '混淆方式'));
    t.specs.push(ProtocolParamTableRegistry.p('up', 'up', ['up', 'upmbps'], '', 'query', 'any', '', '上行带宽'));
    t.specs.push(ProtocolParamTableRegistry.p('down', 'down', ['down', 'downmbps'], '', 'query', 'any', '',
      '下行带宽'));
    t.specs.push(ProtocolParamTableRegistry.p('protocol', 'protocol', ['protocol'], '', 'query', 'any', '',
      '传输协议（udp / wechat-video / faketcp）'));
    t.specs.push(ProtocolParamTableRegistry.p('recv-window', 'recv-window',
      ['recv_window', 'recv-window'], 'I', 'query', 'any', '', '接收窗口'));
    t.specs.push(ProtocolParamTableRegistry.p('recv-window-conn', 'recv-window-conn',
      ['recv_window_conn', 'recv-window-conn'], 'I', 'query', 'any', '', '单连接接收窗口'));
    t.specs.push(ProtocolParamTableRegistry.p('disable-mtu-discovery', 'disable-mtu-discovery',
      ['disable_mtu_discovery', 'disable-mtu-discovery'], 'B', 'query', 'any', '', '禁用 MTU 探测'));
    ProtocolParamTableRegistry.fingerprints(t, true, true);
    ProtocolParamTableRegistry.extras(t, 'query');
    return t;
  }

  private static tuic(): ProtocolParamTable {
    const t = new ProtocolParamTable();
    t.protocol = 'tuic';
    t.title = 'TUIC';
    ProtocolParamTableRegistry.structural(t, 'name', 'fragment', 'server', 'port', 'authority');
    t.specs.push(ProtocolParamTableRegistry.p('uuid', 'uuid', [], 'S', 'authority', 'any', '',
      'TUIC v5 的 uuid（userinfo 的冒号前段；v4 token 形态没有它）'));
    t.specs.push(ProtocolParamTableRegistry.p('password', 'password', [], 'RS', 'authority', 'any', '',
      '口令（userinfo 的冒号后段；v4 token 形态整段都是它）'));
    t.specs.push(ProtocolParamTableRegistry.p('sni', 'sni', ['sni', 'sni-host', 'peer'], '', 'query', 'any', '',
      'SNI（mihomo 的 tuic 用 sni 键）'));
    t.specs.push(ProtocolParamTableRegistry.p('congestion-controller', 'congestion-controller',
      ['congestion_control', 'congestion-controller', 'cc'], '', 'query', 'any', '', '拥塞控制算法'));
    t.specs.push(ProtocolParamTableRegistry.p('udp-relay-mode', 'udp-relay-mode',
      ['udp_relay_mode', 'udp-relay-mode'], '', 'query', 'any', '', 'UDP 中继模式'));
    t.specs.push(ProtocolParamTableRegistry.p('disable-sni', 'disable-sni', ['disable_sni', 'disable-sni'], 'B',
      'query', 'any', '', '禁用 SNI'));
    t.specs.push(ProtocolParamTableRegistry.p('reduce-rtt', 'reduce-rtt', ['reduce_rtt', 'reduce-rtt'], 'B',
      'query', 'any', '', '降低 RTT'));
    t.specs.push(ProtocolParamTableRegistry.p('udp-over-stream', 'udp-over-stream',
      ['udp_over_stream', 'udp-over-stream'], 'B', 'query', 'any', '', 'UDP over stream'));
    t.specs.push(ProtocolParamTableRegistry.p('max-udp-relay-packet-size', 'max-udp-relay-packet-size',
      ['max_udp_relay_packet_size', 'max-udp-relay-packet-size'], 'I', 'query', 'any', '', 'UDP 中继包上限'));
    ProtocolParamTableRegistry.fingerprints(t, true, true);
    ProtocolParamTableRegistry.extras(t, 'query');
    return t;
  }

  private static anytls(): ProtocolParamTable {
    const t = new ProtocolParamTable();
    t.protocol = 'anytls';
    t.title = 'AnyTLS';
    ProtocolParamTableRegistry.structural(t, 'name', 'fragment', 'server', 'port', 'authority');
    t.specs.push(ProtocolParamTableRegistry.p('password', 'password', [], 'RS', 'authority', 'any', '',
      '口令（userinfo 部分）；历史上「36 个 anytls 丢凭据」就是这里没落到位'));
    t.specs.push(ProtocolParamTableRegistry.p('sni', 'sni', ['sni', 'peer'], '', 'query', 'any', '',
      'SNI（mihomo 的 anytls 用 sni 键）'));
    t.specs.push(ProtocolParamTableRegistry.p('idle-session-check-interval', 'idle-session-check-interval',
      ['idle_session_check_interval', 'idle-session-check-interval'], 'I', 'query', 'any', '', '空闲会话检查间隔'));
    t.specs.push(ProtocolParamTableRegistry.p('idle-session-timeout', 'idle-session-timeout',
      ['idle_session_timeout', 'idle-session-timeout'], 'I', 'query', 'any', '', '空闲会话超时'));
    t.specs.push(ProtocolParamTableRegistry.p('min-idle-session', 'min-idle-session',
      ['min_idle_session', 'min-idle-session'], 'I', 'query', 'any', '', '最小空闲会话数'));
    ProtocolParamTableRegistry.fingerprints(t, true, true);
    ProtocolParamTableRegistry.extras(t, 'query');
    return t;
  }

  private static snell(): ProtocolParamTable {
    const t = new ProtocolParamTable();
    t.protocol = 'snell';
    t.title = 'Snell';
    ProtocolParamTableRegistry.structural(t, 'name', 'fragment', 'server', 'port', 'authority');
    t.specs.push(ProtocolParamTableRegistry.p('psk', 'psk', [], 'RS', 'authority', 'any', '',
      '预共享密钥（userinfo 部分）'));
    t.specs.push(ProtocolParamTableRegistry.p('version', 'version', ['version', 'ver'], '', 'query', 'any', '',
      'Snell 协议版本'));
    t.specs.push(ProtocolParamTableRegistry.p('obfs-mode', 'obfs-opts.mode', ['obfs-mode', 'obfsMode'], '',
      'query', 'any', '', '混淆模式'));
    t.specs.push(ProtocolParamTableRegistry.p('obfs-host', 'obfs-opts.host', ['obfs-host', 'obfsHost'], '',
      'query', 'any', '', '混淆 host'));
    ProtocolParamTableRegistry.fingerprints(t, true, true);
    ProtocolParamTableRegistry.extras(t, 'query');
    return t;
  }

  private static http(): ProtocolParamTable {
    const t = new ProtocolParamTable();
    t.protocol = 'http';
    t.title = 'HTTP(S)';
    ProtocolParamTableRegistry.structural(t, 'name', 'fragment', 'server', 'port', 'authority');
    t.specs.push(ProtocolParamTableRegistry.p('username', 'username', [], '', 'authority', 'any', '',
      '用户名（userinfo 的冒号前段）'));
    t.specs.push(ProtocolParamTableRegistry.p('password', 'password', [], 'S', 'authority', 'any', '',
      '口令（userinfo 的冒号后段）'));
    t.specs.push(ProtocolParamTableRegistry.p('sni', 'sni', ['sni', 'peer'], '', 'query', 'any', '',
      'SNI（mihomo 的 http 用 sni 键）'));
    ProtocolParamTableRegistry.fingerprints(t, true, true);
    ProtocolParamTableRegistry.extras(t, 'query');
    return t;
  }

  private static socks(): ProtocolParamTable {
    const t = new ProtocolParamTable();
    t.protocol = 'socks';
    t.title = 'SOCKS5';
    ProtocolParamTableRegistry.structural(t, 'name', 'fragment', 'server', 'port', 'authority');
    t.specs.push(ProtocolParamTableRegistry.p('username', 'username', [], '', 'authority', 'any', '',
      '用户名（userinfo 的冒号前段）'));
    t.specs.push(ProtocolParamTableRegistry.p('password', 'password', [], 'S', 'authority', 'any', '',
      '口令（userinfo 的冒号后段）'));
    t.specs.push(ProtocolParamTableRegistry.p('sni', 'sni', ['sni', 'peer'], '', 'query', 'any', '',
      'SNI（mihomo 的 socks5 用 sni 键）'));
    ProtocolParamTableRegistry.fingerprints(t, true, true);
    ProtocolParamTableRegistry.extras(t, 'query');
    return t;
  }
}
