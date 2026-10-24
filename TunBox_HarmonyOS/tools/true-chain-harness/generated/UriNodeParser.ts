// [harness] generated from entry/src/main/ets/commons/subscription/UriNodeParser.ets — 仅 import 目标被重写
/**
 * URI 订阅解析器（纯函数）
 *
 * ## 定位
 *
 * 「订阅原文 → 节点列表」这条链路上最容易出事的一环。2026-10-20 真机报障：
 * mitce.io 的 34 个 VLESS·REALITY 节点测速**全部秒失败**（mihomo 503，5-10ms），
 * 同一次测速里别的订阅节点正常、隧道用同一个节点也能连通 —— 节点进了内核代理表
 * （所以不是 404），但 REALITY 握手参数（public-key / short-id / servername）
 * 不完整 → 拨号立刻失败 → 整片判失败。
 *
 * 同型事故还有一次：「36 个 anytls 因解析丢凭据被丢弃」。
 *
 * ⇒ 本文件的设计目标只有一条：**逐字段保真，缺必填就整条不可用，绝不半条**。
 *
 * ## 三条硬规则
 *
 * 1. **参数名唯一真源是 ProtocolParamTable**：URI 里的别名（pbk/sid/fp/scy/…）
 *    只用于定位，解析结果一律用**规范键**。表里没声明的参数**不丢弃**，
 *    进 `unknownParams` 让上层可见 —— 静默丢弃就是「参数被改名/丢失」的真凶。
 * 2. **值不改写**：URI 里的值只做一次百分号解码，其余原样保留（不 trim 大小写、
 *    不截断、不补默认值）。敏感值（凭据）由闸门用 sha256 摘要比对证明没被动过。
 * 3. **缺必填 → 整条 ParseError**：`missing` 列出缺哪些规范键、给出人话原因，
 *    **不返回半条节点**。半条节点 = 内核里存在但握手失败 = 测速全红的那类事故。
 *    条件必填（`requiredWhen`）同样生效：security=reality 却没有 public-key
 *    ⇒ 整条不可用（REALITY 场景就是靠这条兜住的）。
 *
 * ## 边界
 *
 * 纯逻辑：不碰存储、不碰配置生成、不 import 任何 kit（ArkTS 编译与 Node 侧测试台都能跑）。
 * 不使用 enum / interface / 未标注对象字面量（ArkTS 纪律；Node 侧 type-stripping 也不吃 enum）。
 */
import { ProtocolParamTableRegistry } from './ProtocolParamTable.ts';
import { NodeUsability, UnusableCategory } from './NodeUsability.ts';
import { UnusableLedger, UnusableRecord } from './UnusableLedger.ts';

/** 解析成功的节点（逐字段保真） */
export class ParsedNode {
  /** 恒为 true（与 ParseError 用同一字段区分，省得调用方到处 instanceof） */
  ok: boolean = true;
  /** 规范协议名（vless / vmess / trojan / ss / ssr / hysteria2 / tuic / anytls / snell / http / socks） */
  protocol: string = '';
  /** 显示名（fragment 缺失时回落到 server） */
  name: string = '';
  /** 节点地址 */
  server: string = '';
  /** 端口（数值；hysteria2 的跳跃区间取首端口，原始区间在 portRaw 与 params['port']） */
  port: number = 0;
  /** 端口原始串（可能是区间 '1000-2000'） */
  portRaw: string = '';
  /** 传输方式（tcp / ws / grpc / http / h2 / xhttp） */
  network: string = 'tcp';
  /** 是否走 TLS */
  tls: boolean = false;
  /** 规范键 → 值（值只做过一次百分号解码，其余原样） */
  params: Map<string, string> = new Map<string, string>();
  /** 参数表未声明的 URI 参数（**不丢弃**，让上层可见） */
  unknownParams: Map<string, string> = new Map<string, string>();
  /** 本节点里的敏感键（凭据类；日志须脱敏） */
  sensitiveKeys: string[] = [];
  /** 原始 URI */
  rawUri: string = '';
}

/** 解析失败（整条不可用，附原因与缺失的规范键） */
export class ParseError {
  /** 恒为 false */
  ok: boolean = false;
  /** 已识别出的协议名（连协议都不认识时为空） */
  protocol: string = '';
  /** 人话原因（直接可展示） */
  reason: string = '';
  /** 缺失的规范键清单 */
  missing: string[] = [];
  /** 原始 URI */
  rawUri: string = '';
}

/** 解析器内部工具（纯函数） */
export class UriNodeParser {
  private static readonly B64: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  /**
   * 当前解析所属的订阅 id（不可用台账按订阅分组用）。
   *
   * 解析是**同步**的（没有 await），所以不存在并发覆盖；用静态字段传递比
   * 给 finish() 一层层加参数更省事，也不会把签名搞成 10 个位置参数。
   *
   * ⚠ ArkTS 的可见性是**类内**检查：模块级函数不能直接碰别的类的 private
   *   成员 ⇒ 对外只给这两个 public 方法，内部字段保持 private。
   */
  private static subId: string = '';

  /** 设置当前解析所属订阅 id（由 parse() 调用） */
  static setSubscriptionId(id: string): void {
    UriNodeParser.subId = id;
  }

  /** 取当前解析所属订阅 id（台账分组用） */
  static subscriptionId(): string {
    return UriNodeParser.subId;
  }

  /** 百分号解码（一次；UTF-8 多字节按字节序列还原） */
  static percentDecode(input: string): string {
    let out = '';
    let pending: number[] = [];
    let i = 0;
    while (i < input.length) {
      const ch = input.charAt(i);
      if (ch === '%' && i + 2 < input.length) {
        const v = parseInt(input.substring(i + 1, i + 3), 16);
        if (!isNaN(v)) {
          pending.push(v & 0xFF);
          i += 3;
          continue;
        }
      }
      if (pending.length > 0) {
        out += UriNodeParser.utf8Decode(pending);
        pending = [];
      }
      out += ch;
      i += 1;
    }
    if (pending.length > 0) {
      out += UriNodeParser.utf8Decode(pending);
    }
    return out;
  }

  /** UTF-8 字节序列 → 字符串 */
  static utf8Decode(bytes: number[]): string {
    let out = '';
    let i = 0;
    while (i < bytes.length) {
      const b = bytes[i];
      let cp = 0;
      let len = 1;
      if (b < 0x80) {
        cp = b;
      } else if ((b & 0xE0) === 0xC0) {
        cp = b & 0x1F;
        len = 2;
      } else if ((b & 0xF0) === 0xE0) {
        cp = b & 0x0F;
        len = 3;
      } else if ((b & 0xF8) === 0xF0) {
        cp = b & 0x07;
        len = 4;
      } else {
        cp = 0xFFFD;
      }
      if (i + len > bytes.length) {
        cp = 0xFFFD;
        len = bytes.length - i;
      }
      for (let k = 1; k < len; k++) {
        const cb = bytes[i + k];
        if ((cb & 0xC0) !== 0x80) {
          cp = 0xFFFD;
          len = k;
          break;
        }
        cp = (cp << 6) | (cb & 0x3F);
      }
      if (cp > 0xFFFF) {
        const v = cp - 0x10000;
        out += String.fromCharCode(0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF));
      } else {
        out += String.fromCharCode(cp);
      }
      i += len;
    }
    return out;
  }

  /** 判断一段文本是否**严格**像 base64（长度是 4 的倍数、只含 base64 字符、补位合法） */
  static isBase64Text(input: string): boolean {
    if (input.length === 0 || input.length % 4 !== 0) {
      return false;
    }
    let core = input;
    let pad = 0;
    while (core.endsWith('=')) {
      core = core.substring(0, core.length - 1);
      pad += 1;
    }
    if (core.length === 0 || pad > 2) {
      return false;
    }
    for (let i = 0; i < core.length; i++) {
      const ch = core.charAt(i);
      const ok = (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')
        || ch === '+' || ch === '/';
      if (!ok) {
        return false;
      }
    }
    return true;
  }

  /** base64 / base64url 解码（→ UTF-8 字符串）；非法输入返回 '' */
  static base64Decode(input: string): string {
    let s = input.replace(/-/g, '+').replace(/_/g, '/').replace(/[^A-Za-z0-9+/]/g, '');
    while (s.length % 4 !== 0) {
      s = s + '=';
    }
    const bytes: number[] = [];
    let i = 0;
    while (i < s.length) {
      const c1 = UriNodeParser.B64.indexOf(s.charAt(i));
      const c2 = UriNodeParser.B64.indexOf(s.charAt(i + 1));
      if (c1 < 0 || c2 < 0) {
        break;
      }
      bytes.push(((c1 << 2) | (c2 >> 4)) & 0xFF);
      const c3raw = s.charAt(i + 2);
      if (c3raw === '=') {
        break;
      }
      const c3 = UriNodeParser.B64.indexOf(c3raw);
      bytes.push(((c2 << 4) | (c3 >> 2)) & 0xFF);
      const c4raw = s.charAt(i + 3);
      if (c4raw === '=') {
        break;
      }
      const c4 = UriNodeParser.B64.indexOf(c4raw);
      bytes.push(((c3 << 6) | c4) & 0xFF);
      i += 4;
    }
    return UriNodeParser.utf8Decode(bytes);
  }

  /** 拆 fragment：返回 [主体, 名称] */
  static splitFragment(body: string): string[] {
    const hash = body.indexOf('#');
    if (hash < 0) {
      return [body, ''];
    }
    return [body.substring(0, hash), UriNodeParser.percentDecode(body.substring(hash + 1))];
  }

  /** 拆 query：返回 [主体, 查询串] */
  static splitQuery(body: string): string[] {
    const q = body.indexOf('?');
    if (q < 0) {
      return [body, ''];
    }
    return [body.substring(0, q), body.substring(q + 1)];
  }

  /** 查询串 → 原始键 → 百分号解码后的值（键保留原样，别名匹配时再大小写无关） */
  static parseQueryMap(query: string): Map<string, string> {
    const out: Map<string, string> = new Map<string, string>();
    if (query.length === 0) {
      return out;
    }
    for (const kv of query.split('&')) {
      if (kv.length === 0) {
        continue;
      }
      const eq = kv.indexOf('=');
      const key = eq < 0 ? kv : kv.substring(0, eq);
      const rawValue = eq < 0 ? '' : kv.substring(eq + 1);
      if (key.length === 0) {
        continue;
      }
      if (!out.has(key)) {
        out.set(key, UriNodeParser.percentDecode(rawValue));
      }
    }
    return out;
  }

  /** 拆 authority：返回 [userInfo, host, 原始端口段]；格式不符返回 []。userinfo 可省略
   * （hysteria v1 的 auth 在 query 参数里、部分转换器生成的 trojan/anytls 也发无凭据形态） */
  static splitAuthority(authority: string): string[] {
    const at = authority.lastIndexOf('@');
    const userInfo = at < 0 ? '' : authority.substring(0, at);
    const hostPart = at < 0 ? authority : authority.substring(at + 1);
    if (hostPart.startsWith('[')) {
      // IPv6：[::1]:443
      const close = hostPart.indexOf(']');
      if (close < 0 || close + 1 >= hostPart.length || hostPart.charAt(close + 1) !== ':') {
        return [];
      }
      return [userInfo, hostPart.substring(1, close), hostPart.substring(close + 2)];
    }
    const colon = hostPart.lastIndexOf(':');
    if (colon < 0) {
      return [];
    }
    return [userInfo, hostPart.substring(0, colon), hostPart.substring(colon + 1)];
  }

  /** 端口段 → 数值（取首个数字；'1000-2000' → 1000） */
  static portNumber(portRaw: string): number {
    let digits = '';
    for (let i = 0; i < portRaw.length; i++) {
      const ch = portRaw.charAt(i);
      if (ch >= '0' && ch <= '9') {
        digits += ch;
      } else {
        break;
      }
    }
    if (digits.length === 0) {
      return 0;
    }
    return parseInt(digits);
  }

  /**
   * 落一个参数：**空值不记录**。
   * 空值等于「没给」—— 不落键，键集才是诚实的（也才谈得上「缺必填 → 整条不可用」）。
   */
  static setIfPresent(params: Map<string, string>, key: string, value: string): void {
    if (value.length === 0) {
      return;
    }
    if (!params.has(key)) {
      params.set(key, value);
    }
  }

  /** 按参数表把原始 query 映射成规范键；未声明的进 unknown */
  static mapQueryParams(protocol: string, network: string, raw: Map<string, string>,
    params: Map<string, string>, unknown: Map<string, string>): void {
    for (const key of Array.from(raw.keys())) {
      const canonical = ProtocolParamTableRegistry.resolveAlias(protocol, network, key);
      const value = raw.get(key) ?? '';
      if (canonical.length === 0) {
        if (value.length > 0 && !unknown.has(key)) {
          unknown.set(key, value);
        }
        continue;
      }
      if (value.length === 0) {
        continue;
      }
      if (!params.has(canonical)) {
        params.set(canonical, value);
      }
    }
  }

  /** 收尾：必填校验 → 节点 或 整条错误 */
  static finish(protocol: string, rawUri: string, name: string, server: string, portRaw: string,
    network: string, tls: boolean, params: Map<string, string>,
    unknown: Map<string, string>): ParsedNode | ParseError {
    const missing: string[] = [];
    const table = ProtocolParamTableRegistry.of(protocol);
    if (table === null) {
      return UriNodeParser.error(rawUri, protocol, `未知协议: ${protocol}`, []);
    }
    for (const spec of table.specs) {
      if (!ProtocolParamTableRegistry.isRequired(protocol, spec.key, params)) {
        continue;
      }
      const value = params.get(spec.key);
      if (value === undefined || value.length === 0) {
        missing.push(spec.key);
      }
    }
    if (missing.length > 0) {
      // 定义不完整 → 整条不可用。写进旁挂台账（UI 可见 + 带原因），
      // 节点本身不进内核代理表、不进测速集合。
      const record = new UnusableRecord();
      record.subscriptionId = UriNodeParser.subId;
      record.source = 'uri';
      record.protocol = protocol;
      record.name = name.length > 0 ? name : server;
      record.server = server;
      const port = UriNodeParser.portNumber(portRaw);
      record.port = port;
      record.category = UnusableCategory.INCOMPLETE;
      record.excluded = true;
      record.missing = missing;
      record.reason = NodeUsability.incompleteReason(protocol, missing);
      record.detail = '定义不完整：解析层没能取到必填参数（我们的问题，需换订阅源或反馈）。'
        + '该节点不会进入内核代理表，也不会参与测速。';
      UnusableLedger.record(record);
      return UriNodeParser.error(rawUri, protocol,
        `缺少必填参数（${missing.join('、')}）—— 整条节点不可用，绝不半条`, missing);
    }
    // 「订阅信息条目」：机场把「剩余流量/到期时间/群链接」写成了节点（2026-10-20 真机事件）。
    // 它们参数齐全 ⇒ 缺参检测抓不到 ⇒ 只能按**名字内容**判。
    // 口径与 YAML 路径一致：不是节点 ⇒ 不进代理表、不进测速集合，但台账里留一条。
    if (NodeUsability.isInfoEntry(name)) {
      const infoRecord = new UnusableRecord();
      infoRecord.subscriptionId = UriNodeParser.subId;
      infoRecord.source = 'uri';
      infoRecord.protocol = protocol;
      infoRecord.name = name.length > 0 ? name : server;
      infoRecord.server = server;
      infoRecord.port = UriNodeParser.portNumber(portRaw);
      infoRecord.category = UnusableCategory.INFO;
      infoRecord.excluded = true;
      infoRecord.reason = NodeUsability.infoReason(name);
      infoRecord.detail = '订阅信息条目，非节点：机场把「剩余流量 / 到期时间 / 群链接」之类的信息'
        + '当成了一个节点写进订阅。它不会进入内核代理表，也不会参与测速。';
      UnusableLedger.record(infoRecord);
      return UriNodeParser.error(rawUri, protocol, infoRecord.reason, []);
    }
    const node = new ParsedNode();
    node.protocol = protocol;
    node.name = name.length > 0 ? name : server;
    node.server = server;
    node.portRaw = portRaw;
    node.port = UriNodeParser.portNumber(portRaw);
    node.network = network;
    node.tls = tls;
    node.params = params;
    node.unknownParams = unknown;
    node.sensitiveKeys = table.sensitiveKeys();
    node.rawUri = rawUri;
    return node;
  }

  /** 构造错误结果 */
  static error(rawUri: string, protocol: string, reason: string, missing: string[]): ParseError {
    const e = new ParseError();
    e.protocol = protocol;
    e.reason = reason;
    e.missing = missing;
    e.rawUri = rawUri;
    return e;
  }
  /**
   * 端口跳跃区间/列表拆分（hysteria2）。
   *
   * 链接形态：`hysteria2://pass@host:1000-2000/?insecure=1` —— 端口段尾部会带一个
   * 路径斜杠，必须先剥掉。只接受「数字 + 逗号 + 连字符」，畸形值按"无跳跃"处理
   * （宁可连单端口，也不要把畸形区间写进内核配置）。
   *
   * @returns [首端口, 原始跳跃串]；单端口时第二项为空串
   */
  static splitPortHopping(rawPortText: string): string[] {
    const raw = rawPortText.trim().replace(/\/+$/, '');
    if (raw.length === 0) {
      return ['', ''];
    }
    if (!raw.includes(',') && !raw.includes('-')) {
      return [/^\d{1,5}$/.test(raw) ? raw : '', ''];
    }
    if (!/^[0-9,-]+$/.test(raw)) {
      return ['', ''];
    }
    const match = raw.match(/\d{1,5}/);
    if (match === null) {
      return ['', ''];
    }
    const first = match[0];
    const firstPort = parseInt(first);
    if (isNaN(firstPort) || firstPort <= 0 || firstPort >= 65536) {
      return ['', ''];
    }
    return [first, raw];
  }

  /**
   * ws 早数据规范化（链接里的 `ed` / `eh`）。
   *
   * - `ed` 是数字 ⇒ ws：ws-opts.max-early-data + early-data-header-name
   *   （缺省 `Sec-WebSocket-Protocol`，与 mihomo common/convert/v.go 一致）；
   *   httpupgrade：ws-opts.v2ray-http-upgrade-fast-open = true
   *   （`ed` 只表示"有早数据"，数值不落地）。
   * - `ed` 不是数字 ⇒ **不落地该键**（mihomo 遇到坏 ed 直接报错整份拒载，
   *   宁可丢掉这个装饰参数，也不要让整份配置起不来）。
   */
  static normalizeEarlyData(network: string, params: Map<string, string>): void {
    const fast = params.get('ws-early-data-fast-open');
    if (fast !== undefined && fast.length > 0) {
      if (/^\d{1,6}$/.test(fast)) {
        params.set('ws-early-data-fast-open', 'true');
      } else {
        params.delete('ws-early-data-fast-open');
      }
    }
    const ed = params.get('ws-early-data');
    if (ed === undefined || ed.length === 0) {
      return;
    }
    if (!/^\d{1,6}$/.test(ed)) {
      params.delete('ws-early-data');
      return;
    }
    if (network === 'ws' && !params.has('ws-early-data-header-name')) {
      params.set('ws-early-data-header-name', 'Sec-WebSocket-Protocol');
    }
  }
}

/**
 * 解析一条订阅 URI。
 *
 * @param uri 一条分享链接（vless:// / vmess:// / trojan:// / ss:// / ssr:// /
 *             hysteria2:// / hy2:// / tuic:// / anytls:// / snell:// / http(s):// / socks5://）
 * @returns 解析成功给 ParsedNode，失败给 ParseError（**不返回半条节点**）
 */
export function parse(uri: string, subscriptionId: string = ''): ParsedNode | ParseError {
  const raw = uri.trim();
  UriNodeParser.setSubscriptionId(subscriptionId);
  if (raw.length === 0) {
    return UriNodeParser.error(raw, '', 'URI 为空', []);
  }
  const sep = raw.indexOf('://');
  if (sep <= 0) {
    return UriNodeParser.error(raw, '', 'URI 缺少协议头（形如 vless://…）', []);
  }
  const scheme = raw.substring(0, sep).toLowerCase();
  const protocol = ProtocolParamTableRegistry.protocolOfScheme(scheme);
  if (protocol.length === 0) {
    return UriNodeParser.error(raw, '', `不支持的协议: ${scheme}`, []);
  }
  const body = raw.substring(sep + 3);

  if (protocol === 'vmess') {
    return parseVmess(raw, body);
  }
  if (protocol === 'ssr') {
    return parseSsr(raw, body);
  }
  if (protocol === 'ss') {
    return parseSs(raw, body);
  }
  return parseAuthorityForm(raw, protocol, body, scheme);
}

/** vmess://base64(v2rayN JSON) */
function parseVmess(raw: string, body: string): ParsedNode | ParseError {
  const jsonText = UriNodeParser.base64Decode(body);
  if (jsonText.length === 0) {
    return UriNodeParser.error(raw, 'vmess', 'vmess 载荷不是合法的 base64', []);
  }
  let obj: Record<string, Object>;
  try {
    obj = JSON.parse(jsonText) as Record<string, Object>;
  } catch (e) {
    return UriNodeParser.error(raw, 'vmess', 'vmess 载荷不是合法的 JSON', []);
  }
  const params: Map<string, string> = new Map<string, string>();
  const unknown: Map<string, string> = new Map<string, string>();
  const network = jsonField(obj, 'net');
  const bodyKeys: string[] = ['ps', 'add', 'port', 'id', 'aid', 'scy', 'tls', 'sni', 'net', 'alpn',
    'path', 'host', 'serviceName', 'type', 'fp', 'pcs'];
  for (const key of bodyKeys) {
    const value = jsonField(obj, key);
    if (value.length === 0) {
      continue;
    }
    const canonical = ProtocolParamTableRegistry.resolveAlias('vmess', network, key);
    if (canonical.length === 0) {
      if (!unknown.has(key)) {
        unknown.set(key, value);
      }
      continue;
    }
    UriNodeParser.setIfPresent(params, canonical, value);
  }
  // vmess 的 network 规范键来自 'net'，但解析时先要拿到 network 才能定位传输类参数
  if (!params.has('network') && network.length > 0) {
    params.set('network', network);
  }
  const server = jsonField(obj, 'add');
  const portRaw = jsonField(obj, 'port');
  const name = jsonField(obj, 'ps');
  const tls = jsonField(obj, 'tls').toLowerCase() === 'tls';
  return UriNodeParser.finish('vmess', raw, name, server, portRaw,
    network.length > 0 ? network : 'tcp', tls, params, unknown);
}

/** ssr://base64(host:port:protocol:method:obfs:password/?obfsparam=&protoparam=&remarks=) */
function parseSsr(raw: string, body: string): ParsedNode | ParseError {
  const decoded = UriNodeParser.base64Decode(body);
  if (decoded.length === 0) {
    return UriNodeParser.error(raw, 'ssr', 'ssr 载荷不是合法的 base64', []);
  }
  const parts = decoded.split('/?');
  const segments = parts[0].split(':');
  if (segments.length < 6) {
    return UriNodeParser.error(raw, 'ssr', 'ssr 载荷字段数不足（应含 host:port:protocol:method:obfs:password）', []);
  }
  const tail = segments.length - 5;
  const params: Map<string, string> = new Map<string, string>();
  const unknown: Map<string, string> = new Map<string, string>();
  UriNodeParser.setIfPresent(params, 'server', segments.slice(0, tail).join(':'));
  UriNodeParser.setIfPresent(params, 'port', segments[tail]);
  UriNodeParser.setIfPresent(params, 'protocol', segments[tail + 1]);
  UriNodeParser.setIfPresent(params, 'cipher', segments[tail + 2]);
  UriNodeParser.setIfPresent(params, 'obfs', segments[tail + 3]);
  UriNodeParser.setIfPresent(params, 'password', segments[tail + 4]);
  let name = '';
  if (parts.length > 1) {
    for (const kv of parts[1].split('&')) {
      const eq = kv.indexOf('=');
      if (eq < 0) {
        continue;
      }
      const key = kv.substring(0, eq);
      const rawValue = kv.substring(eq + 1);
      // SSR 规范里这几个值是 base64；但也有面板直接塞百分号编码的文本 ——
      // 先按 base64 试，不合法再回落百分号解码（两种都不丢）
      let value = '';
      if (UriNodeParser.isBase64Text(rawValue)) {
        value = UriNodeParser.base64Decode(rawValue);
      }
      if (value.length === 0) {
        value = UriNodeParser.percentDecode(rawValue);
      }
      if (key === 'remarks') {
        name = value;
      } else if (key === 'protoparam') {
        UriNodeParser.setIfPresent(params, 'protocol-param', value);
      } else if (key === 'obfsparam') {
        UriNodeParser.setIfPresent(params, 'obfs-param', value);
      } else if (value.length > 0) {
        unknown.set(key, value);
      }
    }
  }
  UriNodeParser.setIfPresent(params, 'name', name);
  return UriNodeParser.finish('ssr', raw, name, params.get('server') ?? '', params.get('port') ?? '',
    'tcp', false, params, unknown);
}

/** ss://（SIP002：base64(method:password)@host:port；旧形态：整段 base64） */
function parseSs(raw: string, body: string): ParsedNode | ParseError {
  const split = UriNodeParser.splitFragment(body);
  const frag = UriNodeParser.splitQuery(split[0]);
  const authority = frag[0];
  const params: Map<string, string> = new Map<string, string>();
  const unknown: Map<string, string> = new Map<string, string>();
  UriNodeParser.mapQueryParams('ss', 'tcp', UriNodeParser.parseQueryMap(frag[1]), params, unknown);

  let server = '';
  let portRaw = '';
  let userInfo = '';
  const at = authority.lastIndexOf('@');
  if (at >= 0) {
    userInfo = authority.substring(0, at);
    const hostInfo = UriNodeParser.splitAuthority(authority);
    if (hostInfo.length === 3) {
      server = hostInfo[1];
      portRaw = hostInfo[2];
    } else {
      return UriNodeParser.error(raw, 'ss', 'ss 地址格式不对（应为 host:port）', []);
    }
  } else {
    const decoded = UriNodeParser.base64Decode(authority);
    const at2 = decoded.lastIndexOf('@');
    if (at2 < 0) {
      return UriNodeParser.error(raw, 'ss', 'ss 载荷不是合法的 base64(method:password@host:port)', []);
    }
    userInfo = decoded.substring(0, at2);
    const hostPart = decoded.substring(at2 + 1);
    const colon = hostPart.lastIndexOf(':');
    if (colon < 0) {
      return UriNodeParser.error(raw, 'ss', 'ss 载荷里的地址格式不对', []);
    }
    server = hostPart.substring(0, colon);
    portRaw = hostPart.substring(colon + 1);
  }
  const userRaw = UriNodeParser.base64Decode(userInfo);
  const colon2 = userRaw.indexOf(':');
  if (colon2 < 0) {
    return UriNodeParser.error(raw, 'ss', 'ss 的 userinfo 不是合法的 base64(method:password)', []);
  }
  UriNodeParser.setIfPresent(params, 'cipher', userRaw.substring(0, colon2));
  UriNodeParser.setIfPresent(params, 'password', userRaw.substring(colon2 + 1));
  UriNodeParser.setIfPresent(params, 'server', server);
  UriNodeParser.setIfPresent(params, 'port', portRaw);
  const name = split[1];
  UriNodeParser.setIfPresent(params, 'name', name);
  return UriNodeParser.finish('ss', raw, name, server, portRaw, 'tcp', false, params, unknown);
}

/** 通用形态：userinfo@host:port?query#name（vless/trojan/hysteria2/tuic/anytls/snell/http/socks） */
function parseAuthorityForm(raw: string, protocol: string, body: string, scheme: string): ParsedNode | ParseError {
  const split = UriNodeParser.splitFragment(body);
  const frag = UriNodeParser.splitQuery(split[0]);
  const hostInfo = UriNodeParser.splitAuthority(frag[0]);
  if (hostInfo.length !== 3) {
    return UriNodeParser.error(raw, protocol, '地址格式不对（应为 [凭据@]host:port）', []);
  }
  const userInfo = UriNodeParser.percentDecode(hostInfo[0]);
  const server = hostInfo[1];
  const portRaw = hostInfo[2];
  const rawQuery = UriNodeParser.parseQueryMap(frag[1]);

  // 先定 network（决定 path/host 落在 ws-opts / h2-opts / http-opts / xhttp-opts 哪个结构）
  let network = 'tcp';
  const typeRaw = rawQuery.get('type') ?? rawQuery.get('network') ?? rawQuery.get('net') ?? '';
  if (typeRaw.length > 0) {
    network = typeRaw.toLowerCase();
  }
  if (protocol === 'vless' || protocol === 'trojan') {
    network = network.length > 0 ? network : 'tcp';
  }

  const params: Map<string, string> = new Map<string, string>();
  const unknown: Map<string, string> = new Map<string, string>();
  UriNodeParser.mapQueryParams(protocol, network, rawQuery, params, unknown);

  // hysteria2 的端口段可能是跳跃区间/列表：`host:1000-2000` / `host:1000,2000`
  // （尾部常带一个路径斜杠）。取**首端口**做 port，原始串另存 ports
  // （对齐 mihomo 的 hysteria2 `ports` 键）。漏了这一步 ⇒ 端口跳跃退化成单端口，
  // 节点能连但连的不是机场期望的那一段。
  let effectivePortRaw = portRaw;
  if (protocol === 'hysteria2') {
    const hopping = UriNodeParser.splitPortHopping(portRaw);
    if (hopping.length === 2 && hopping[1].length > 0) {
      effectivePortRaw = hopping[0];
      UriNodeParser.setIfPresent(params, 'ports', hopping[1]);
    }
  }

  // ws 早数据规范化（ed / eh）
  UriNodeParser.normalizeEarlyData(network, params);

  let tls = false;
  if (protocol === 'vless') {
    const security = params.get('security') ?? '';
    tls = security === 'tls' || security === 'reality';
  } else if (protocol === 'trojan' || protocol === 'tuic' || protocol === 'anytls'
    || protocol === 'snell' || protocol === 'hysteria2') {
    tls = true;
  } else if (protocol === 'http') {
    tls = scheme === 'https';
  }

  // 凭据（userinfo）
  if (protocol === 'vless') {
    UriNodeParser.setIfPresent(params, 'uuid', userInfo);
  } else if (protocol === 'tuic') {
    const colon = userInfo.indexOf(':');
    if (colon >= 0) {
      UriNodeParser.setIfPresent(params, 'uuid', userInfo.substring(0, colon));
      UriNodeParser.setIfPresent(params, 'password', userInfo.substring(colon + 1));
    } else {
      UriNodeParser.setIfPresent(params, 'password', userInfo);
    }
  } else if (protocol === 'http' || protocol === 'socks') {
    const colon = userInfo.indexOf(':');
    if (colon >= 0) {
      UriNodeParser.setIfPresent(params, 'username', userInfo.substring(0, colon));
      UriNodeParser.setIfPresent(params, 'password', userInfo.substring(colon + 1));
    } else {
      UriNodeParser.setIfPresent(params, 'username', userInfo);
    }
  } else if (protocol === 'snell') {
    // snell 的 userinfo 是 psk，不是 password（写错就会把整条节点判成缺必填）
    UriNodeParser.setIfPresent(params, 'psk', userInfo);
  } else {
    UriNodeParser.setIfPresent(params, 'password', userInfo);
  }

  UriNodeParser.setIfPresent(params, 'server', server);
  UriNodeParser.setIfPresent(params, 'port', effectivePortRaw);
  const name = split[1];
  UriNodeParser.setIfPresent(params, 'name', name);
  return UriNodeParser.finish(protocol, raw, name, server, effectivePortRaw, network, tls, params, unknown);
}

/** 从 vmess JSON 里取一个字段（统一转成字符串；数字不丢精度） */
function jsonField(obj: Record<string, Object>, key: string): string {
  const v = obj[key];
  if (v === undefined || v === null) {
    return '';
  }
  if (typeof v === 'string') {
    return v as string;
  }
  if (typeof v === 'number') {
    return `${v as number}`;
  }
  if (typeof v === 'boolean') {
    return `${v as boolean}`;
  }
  return '';
}
