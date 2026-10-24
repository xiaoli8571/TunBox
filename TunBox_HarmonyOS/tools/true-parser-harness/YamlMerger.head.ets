/**
 * 订阅 YAML 合并引擎
 * 移植自 upstream: packages/tunbox_shared/lib/services/subscription_yaml_merger.dart
 *                packages/tunbox_shared/lib/utils/bounded_yaml.dart
 *
 * 语义对齐：proxies 分节提取与缩进规整、条目切分、按内容指纹跨订阅去重（保留归属）、
 *           与 previousYaml 的同名节点保留（刷新不重排名称）、唯一名 "(n)" 后缀、全部限额。
 * 简化说明：upstream 用完整 YAML 解析器 + dialer-proxy 依赖解析；本移植针对 ss/ssr 节点
 *           的标量字段（flow-map 与块列表两种写法）做解析，dialer-proxy 依赖不在 ss/ssr
 *           订阅中出现，暂不实现（已记 PORTING_STATUS）。
 */
import { util } from '@kit.ArkTS';

/** 单个合并后的代理节点，仅保存受支持协议（ss/ssr/vless/vmess/trojan/hysteria2）的白名单结构化字段。 */
export class MergedProxy {
  name: string = '';
  type: string = 'ss';
  server: string = '';
  port: number = 0;
  cipher: string = '';
  password: string = '';
  protocol: string = '';
  protocolParam: string = '';
  obfs: string = '';
  obfsParam: string = '';
  uuid: string = '';
  alterId: number = 0;
  udp: boolean = false;
  network: string = '';
  tls: boolean = false;
  servername: string = '';
  skipCertVerify: boolean = false;
  flow: string = '';
  clientFingerprint: string = '';
  realityPublicKey: string = '';
  realityShortId: string = '';
  wsPath: string = '';
  wsHost: string = '';
  grpcServiceName: string = '';
  /** Hysteria2: up/down 带宽(Mbps 字符串)、alpn 逗号列表；obfs 族复用 obfs/obfsParam 槽位 */
  hyUp: string = '';
  hyDown: string = '';
  alpnList: string = '';
  /**
   * 结构化槽位未覆盖的额外 mihomo 字段, JSON 数组序列化: [[key, value], ...]。
   * 覆盖两类场景:
   * 1) 已知协议(ss/vmess/vless/trojan/hysteria2)的附加键: plugin/plugin-opts、
   *    h2-opts、ports、tfo、mptcp、ip-version、smux、packet-encoding 等;
   * 2) 中继协议(tuic/hysteria/http/socks5/snell/anytls/ssh/mieru/wireguard)
   *    的结构化槽位之外的全部专用键。
   * 键名与值在入库前均经白名单校验, 生成配置时原样回写 —— 不再静默丢字段。
   */
  extraOpts: string = '';
}

/** 合并限额（照抄 upstream SubscriptionYamlMerger 常量） */
export class MergeLimits {
  static readonly MAX_MERGED_PROXY_NODES: number = 10000;
  static readonly MAX_MERGE_SOURCES: number = 1000;
  static readonly MAX_PROXY_FIELD_LENGTH: number = 64 * 1024;
  static readonly MAX_PROXY_ITEM_BYTES: number = 128 * 1024;
  static readonly MAX_MERGED_OUTPUT_BYTES: number = 20 * 1024 * 1024;
}

export class YamlMergeError extends Error {
  constructor(message: string) {
    super(message);
  }
}

/** 单个节点格式或必需字段错误。合并时跳过该节点，不吞掉任何全局限额错误。 */
export class YamlNodeError extends Error {
  constructor(message: string) {
    super(message);
  }
}

export class YamlMerger {
  /** 提取指定顶层分节并归一化缩进为 2 空格（对齐 _normalizedSectionLines） */
  static extractSection(yaml: string, sectionName: string): string {
    const lines = YamlMerger.normalizedSectionLines(yaml, sectionName);
    return lines.join('\n');
  }

  private static sectionLines(yaml: string, sectionName: string): string[] {
    const out: string[] = [];
    let inSection = false;
    const rawLines = yaml.split('\n');
    for (let line of rawLines) {
      // UTF-8 BOM is legal at the beginning of a YAML stream. Remove it before
      // testing top-level keys, otherwise a leading `proxies:` is never found.
      if (line.startsWith('\uFEFF')) {
        line = line.substring(1);
      }
      if (!line.startsWith(' ') && !line.startsWith('\t')) {
        const trimmed = line.trim();
        if (trimmed.startsWith(`${sectionName}:`)) {
          inSection = true;
          continue;
        }
        // Any non-empty, non-comment zero-indentation line starts the next
        // top-level YAML construct. Stop immediately so anchors/merge keys or
        // malformed trailing content cannot contaminate previously extracted
        // proxy entries.
        if (inSection && trimmed.length > 0 && !trimmed.startsWith('#')) {
          break;
        }
      }
      if (inSection) {
        out.push(line);
      }
    }
    return out;
  }

  private static normalizedSectionLines(yaml: string, sectionName: string): string[] {
    const section = YamlMerger.sectionLines(yaml, sectionName);
    let minIndent = 999;
    for (const line of section) {
      const trimmed = line.trimStart();
      // 顶层注释可出现在 proxies 节内，但不能参与最小缩进计算；
      // 否则 minIndent 会被拉到 0，所有正常的 "  - " 条目会被额外缩进并提取为 0 条。
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      const indent = line.length - trimmed.length;
      if (indent < minIndent) {
        minIndent = indent;
      }
    }
    if (minIndent === 999) {
      minIndent = 0;
    }
    const out: string[] = [];
    for (const line of section) {
      const trimmed = line.trimStart();
      if (trimmed.length === 0) {
        continue;
      }
      const delta = line.length - trimmed.length - minIndent;
      let pad = '';
      for (let i = 0; i < delta + 2; i++) {
        pad += ' ';
      }
      out.push(`${pad}${trimmed}`);
    }
    return out;
  }

  /** proxies 条目切分（对齐 _proxyItemsFromLines：以 "  - " 起始，续行归并） */
  static proxyItemGroups(yaml: string): string[][] {
    const lines = YamlMerger.normalizedSectionLines(yaml, 'proxies');
    const items: string[][] = [];
    let current: string[] | null = null;
    for (const line of lines) {
      if (line.startsWith('  - ')) {
        if (current !== null) {
          items.push(current);
        }
        current = [line];
      } else if (current !== null) {
        current.push(line);
      }
    }
    if (current !== null) {
      items.push(current);
    }
    return items;
  }

  /**
   * 按 YAML 引号与集合深度切分 flow collection。分隔符仅在顶层生效，
   * 因此嵌套 map/sequence、带逗号的引号值、emoji 与裸 IPv6 都不会被误切。
   */
  private static splitTopLevel(content: string, separator: string): string[] {
    const out: string[] = [];
    let current = '';
    let quote = '';
    let escaped = false;
    let braceDepth = 0;
    let bracketDepth = 0;
    for (let i = 0; i < content.length; i++) {
      const ch = content.charAt(i);
      if (quote === '"' && escaped) {
        current += ch;
        escaped = false;
        continue;
      }
      if (quote === '"' && ch === '\\') {
        current += ch;
        escaped = true;
        continue;
      }
      if (quote.length > 0) {
        current += ch;
        if (ch === quote) {
          // YAML 单引号用两个连续单引号表示字面单引号。
          if (quote === "'" && i + 1 < content.length && content.charAt(i + 1) === "'") {
            current += content.charAt(i + 1);
            i = i + 1;
          } else {
            quote = '';
          }
        }
        continue;
      }
      if (ch === '"' || ch === "'") {
        quote = ch;
        current += ch;
      } else if (ch === '{') {
        braceDepth = braceDepth + 1;
        current += ch;
      } else if (ch === '}') {
        if (braceDepth <= 0) {
          throw new YamlNodeError('代理节点包含多余的右花括号');
        }
        braceDepth = braceDepth - 1;
        current += ch;
      } else if (ch === '[') {
        bracketDepth = bracketDepth + 1;
        current += ch;
      } else if (ch === ']') {
        if (bracketDepth <= 0) {
          throw new YamlNodeError('代理节点包含多余的右方括号');
        }
        bracketDepth = bracketDepth - 1;
        current += ch;
      } else if (ch === separator && braceDepth === 0 && bracketDepth === 0) {
        if (current.trim().length > 0) {
          out.push(current.trim());
        }
        current = '';
      } else {
        current += ch;
      }
    }
    if (quote.length > 0 || escaped || braceDepth !== 0 || bracketDepth !== 0) {
      throw new YamlNodeError('代理节点包含未闭合的 YAML 引号或集合');
    }
    if (current.trim().length > 0) {
      out.push(current.trim());
    }
    return out;
  }

  private static splitFlowMap(content: string): string[] {
    return YamlMerger.splitTopLevel(content, ',');
  }

  /** 查找顶层第一个分隔冒号；嵌套集合和裸 IPv6 内的冒号均不参与切键值。 */
  private static findUnquotedColon(value: string): number {
    let quote = '';
    let escaped = false;
    let braceDepth = 0;
    let bracketDepth = 0;
    for (let i = 0; i < value.length; i++) {
      const ch = value.charAt(i);
      if (quote === '"' && escaped) {
        escaped = false;
        continue;
      }
      if (quote === '"' && ch === '\\') {
        escaped = true;
        continue;
      }
      if (quote.length > 0) {
        if (ch === quote) {
          if (quote === "'" && i + 1 < value.length && value.charAt(i + 1) === "'") {
            i = i + 1;
          } else {
            quote = '';
          }
        }
      } else if (ch === '"' || ch === "'") {
        quote = ch;
      } else if (ch === '{') {
        braceDepth = braceDepth + 1;
      } else if (ch === '}') {
        braceDepth = Math.max(0, braceDepth - 1);
      } else if (ch === '[') {
        bracketDepth = bracketDepth + 1;
      } else if (ch === ']') {
        bracketDepth = Math.max(0, bracketDepth - 1);
      } else if (ch === ':' && braceDepth === 0 && bracketDepth === 0) {
        return i;
      }
    }
    return -1;
  }

  /** 解码受限 YAML 标量，拒绝标签、锚点、注释、换行和集合语法。 */
  private static decodeScalar(input: string): string {
    const value = input.trim();
    if (value.length === 0) {
      return '';
    }
    if (value.includes('\n') || value.includes('\r') || value.startsWith('!')
      || value.startsWith('&') || value.startsWith('*') || value.startsWith('|')
      || value.startsWith('>') || value.startsWith('[') || value.startsWith('{')) {
      throw new YamlNodeError('代理节点包含不受支持的 YAML 标量');
    }
    const first = value.charAt(0);
    if (first === '"' || first === "'") {
      if (value.length < 2 || value.charAt(value.length - 1) !== first) {
        throw new YamlNodeError('代理节点包含未闭合的 YAML 引号');
      }
      let inner = value.substring(1, value.length - 1);
      if (first === "'") {
        return inner.replace(/''/g, "'");
      }
      inner = inner.replace(/\\"/g, '"').replace(/\\\\/g, '\\');
      return inner;
    }
    // 裸标量里的 " #" 之后是 YAML 行内注释, 截掉; 值本身含 '#'(如密码)则保留
    const commentIdx = value.indexOf(' #');
    if (commentIdx >= 0) {
      return value.substring(0, commentIdx).trim();
    }
    return value;
  }

  /** 解析受限 flow-map，并确保只有指定键；嵌套值仍由调用方按白名单解析。 */
  private static parseRestrictedFlowMap(input: string, allowedKeys: Set<string>): Map<string, string> {
    const value = input.trim();
    if (!value.startsWith('{') || !value.endsWith('}')) {
      throw new YamlNodeError('代理节点嵌套字段必须使用合法 flow-map');
    }
    const result = new Map<string, string>();
    const pairs = YamlMerger.splitFlowMap(value.substring(1, value.length - 1));
    for (const pair of pairs) {
      const idx = YamlMerger.findUnquotedColon(pair);
      if (idx <= 0) {
        throw new YamlNodeError('代理节点嵌套 flow-map 字段格式无效');
      }
      const key = YamlMerger.decodeScalar(pair.substring(0, idx));
      // 真实面板会在嵌套结构里附带扩展键（reality-opts._spider-x、
      // ws-opts.v2ray-http-upgrade、grpc-opts.* 等）。未知键必须逐项忽略，
      // 一旦抛错就会让调用方丢弃整段嵌套配置 —— 典型后果是 REALITY 的
      // public-key/short-id 全部丢失，内核退化成普通 TLS 并握手失败。
      if (!allowedKeys.has(key)) {
        continue;
      }
      if (result.has(key)) {
        throw new YamlNodeError(`代理节点包含重复嵌套字段：${key}`);
      }
      result.set(key, pair.substring(idx + 1).trim());
    }
    return result;
  }

  /** 行有效缩进 = 前导空格数 + (`- ` 占 2 列, 列表项键位右移)。块式嵌套判定用。 */
  private static lineIndent(line: string): number {
    const trimmed = line.trimStart();
    const lead = line.length - trimmed.length;
    return trimmed.startsWith('- ') ? lead + 2 : lead;
  }

  /**
   * 提取块式（缩进多行）嵌套体的原始行。
   * 形如：
   *   ws-opts:
   *     path: /ws
   *     headers:
   *       Host: h.example.com
   * 返回 body 行；若该键为行内 flow-map（`ws-opts: {...}`）则返回空数组，交给 flow 解析。
   * 缩进异常/找不到该键时返回空数组，绝不抛错（调用方逐项降级）。
   */
  private static extractBlockBody(itemLines: string[], key: string): string[] {
    for (let i = 0; i < itemLines.length; i++) {
      const t = itemLines[i].trim().replace(/^-\s+/, '');
      const idx = YamlMerger.findUnquotedColon(t);
      if (idx <= 0) {
        continue;
      }
      let k = '';
      try {
        k = YamlMerger.decodeScalar(t.substring(0, idx).trim());
      } catch (e) {
        continue;
      }
      if (k !== key) {
        continue;
      }
      if (t.substring(idx + 1).trim().length > 0) {
        return []; // 行内 flow-map
      }
      const base = YamlMerger.lineIndent(itemLines[i]);
      const body: string[] = [];
      for (let j = i + 1; j < itemLines.length; j++) {
        const raw = itemLines[j];
        if (raw.trim().length === 0) {
          continue;
        }
        if (YamlMerger.lineIndent(raw) <= base) {
          break; // 回到同级 = 块体结束
        }
        body.push(raw);
      }
      return body;
    }
    return [];
  }

  /** 块体里的简单 key:value 白名单标量（reality-opts / grpc-opts）；未知键逐项忽略。 */
  private static parseSimpleBlock(bodyLines: string[], allowed: Set<string>): Map<string, string> {
    const out = new Map<string, string>();
    for (const raw of bodyLines) {
      const t = raw.trim().replace(/^-\s+/, '');
      if (t.length === 0 || t.startsWith('#')) {
        continue;
      }
      const idx = YamlMerger.findUnquotedColon(t);
      if (idx <= 0) {
        continue;
      }
      let k = '';
      try {
        k = YamlMerger.decodeScalar(t.substring(0, idx).trim());
      } catch (e) {
        continue;
      }
      if (!allowed.has(k) || out.has(k)) {
        continue;
      }
      const rawVal = t.substring(idx + 1).trim();
      if (rawVal.length === 0) {
        continue;
      }
      try {
        out.set(k, YamlMerger.decodeScalar(rawVal));
      } catch (e) {
        // 值异常, 忽略该项
      }
    }
    return out;
  }

  /**
   * 块式 ws-opts: 取 path 与 headers.Host（也容忍平铺的 Host）。
   * headers 支持行内 flow-map（`headers: {Host: x}`）与块式两种写法；
   * 未知键（v2ray-http-upgrade 等）逐项忽略，绝不抛错。
   */
  private static parseWsBlock(bodyLines: string[]): Map<string, string> {
    const out = new Map<string, string>();
    let headersIndent = -1;
    for (const raw of bodyLines) {
      const t = raw.trim().replace(/^-\s+/, '');
      if (t.length === 0 || t.startsWith('#')) {
        continue;
      }
      const idx = YamlMerger.findUnquotedColon(t);
      if (idx <= 0) {
        continue;
      }
      let k = '';
      try {
        k = YamlMerger.decodeScalar(t.substring(0, idx).trim());
      } catch (e) {
        continue;
      }
      const indent = YamlMerger.lineIndent(raw);
      const rawVal = t.substring(idx + 1).trim();
      if (k === 'path') {
        if (rawVal.length > 0 && !out.has('path')) {
          try {
            out.set('path', YamlMerger.decodeScalar(rawVal));
          } catch (e) {
          }
        }
        headersIndent = -1;
      } else if (k === 'headers') {
        if (rawVal.startsWith('{')) {
          try {
            const h = YamlMerger.parseRestrictedFlowMap(rawVal, new Set<string>(['Host', 'host']));
            const hv = h.get('Host') ?? h.get('host');
            if (hv !== undefined && !out.has('Host')) {
              out.set('Host', YamlMerger.decodeScalar(hv));
            }
          } catch (e) {
          }
          headersIndent = -1;
        } else {
          headersIndent = indent;
        }
      } else if (k === 'Host' || k === 'host') {
        if (rawVal.length > 0 && !out.has('Host')) {
          try {
            out.set('Host', YamlMerger.decodeScalar(rawVal));
          } catch (e) {
          }
        }
      } else if (headersIndent >= 0 && indent <= headersIndent) {
        headersIndent = -1;
      }
    }
    return out;
  }

  /** 顶层 ws-headers 别名取值：支持 `{Host: x}` / `Host: x` / `Host=x`；异常返回 ''。 */
  private static extractHeaderHost(value: string): string {
    const v = value.trim();
    if (v.length === 0) {
      return '';
    }
    if (v.startsWith('{')) {
      try {
        const h = YamlMerger.parseRestrictedFlowMap(v, new Set<string>(['Host', 'host']));
        const hv = h.get('Host') ?? h.get('host');
        return hv !== undefined ? YamlMerger.decodeScalar(hv) : '';
      } catch (e) {
        return '';
      }
    }
    const m = v.match(/host\s*[:=]\s*(.+)$/i);
    if (m !== null && m.length > 1) {
      try {
        return YamlMerger.decodeScalar(m[1].trim());
      } catch (e) {
        return '';
      }
    }
    return '';
  }

  /**
   * 解析 reality/ws/grpc 嵌套项。
   *
   * 三种来源按优先级合并，任一来源结构异常都只降级该项，绝不丢整段/整节点：
   *   1) 行内 flow-map（`ws-opts: {path: "/x", headers: {Host: "h"}}`）—— 原有行为；
   *   2) 块式（缩进多行，`ws-opts:` + `path:` + `headers:` + `Host:`）—— 新增；
   *   3) 顶层别名（ws-path / ws-host / ws-headers）—— 新增。
   * 已解析到的非空值不会被后续来源覆盖（“订阅给了就严格保留”）。
   */
  private static parseNestedOptions(fields: Map<string, string>, p: MergedProxy,
    itemLines: string[]): void {
    // 顶层别名（优先级最低，先落位，后续 ws-opts 非空值可补齐/覆盖）
    const aliasPath = fields.get('ws-path');
    if (aliasPath !== undefined && aliasPath.length > 0) {
      p.wsPath = aliasPath;
    }
    const aliasHost = fields.get('ws-host');
    if (aliasHost !== undefined && aliasHost.length > 0) {
      p.wsHost = aliasHost;
    }
    if (p.wsHost.length === 0) {
      const aliasHeaders = fields.get('ws-headers') ?? '';
      if (aliasHeaders.length > 0) {
        p.wsHost = YamlMerger.extractHeaderHost(aliasHeaders);
      }
    }

    // reality-opts：flow-map 优先，失败/缺失回退块式
    const realityFlow = fields.get('reality-opts');
    if (realityFlow !== undefined && realityFlow.trim().length > 0) {
      try {
        const reality = YamlMerger.parseRestrictedFlowMap(realityFlow,
          new Set<string>(['public-key', 'short-id']));
        const pk = reality.get('public-key');
        if (pk !== undefined) {
          p.realityPublicKey = YamlMerger.decodeScalar(pk);
        }
        const sid = reality.get('short-id');
        if (sid !== undefined) {
          p.realityShortId = YamlMerger.decodeScalar(sid);
        }
      } catch (e) {
        // 结构异常按「未提供」降级
      }
    }
    if (p.realityPublicKey.length === 0 && p.realityShortId.length === 0) {
      const realityBlock = YamlMerger.extractBlockBody(itemLines, 'reality-opts');
      if (realityBlock.length > 0) {
        const m = YamlMerger.parseSimpleBlock(realityBlock,
          new Set<string>(['public-key', 'short-id']));
        const pk = m.get('public-key');
        if (pk !== undefined && pk.length > 0) {
          p.realityPublicKey = pk;
        }
        const sid = m.get('short-id');
        if (sid !== undefined && sid.length > 0) {
          p.realityShortId = sid;
        }
      }
    }

    // ws-opts：flow-map 优先，失败/缺失回退块式
    const wsFlow = fields.get('ws-opts');
    if (wsFlow !== undefined && wsFlow.trim().length > 0) {
      try {
        const ws = YamlMerger.parseRestrictedFlowMap(wsFlow, new Set<string>(['path', 'headers']));
        const pathV = ws.get('path');
        if (pathV !== undefined && pathV.length > 0) {
          p.wsPath = YamlMerger.decodeScalar(pathV);
        }
        const headersRaw = ws.get('headers');
        if (headersRaw !== undefined) {
          const headers = YamlMerger.parseRestrictedFlowMap(headersRaw,
            new Set<string>(['Host', 'host']));
          const hostV = headers.get('Host') ?? headers.get('host');
          if (hostV !== undefined && hostV.length > 0) {
            p.wsHost = YamlMerger.decodeScalar(hostV);
          }
        }
      } catch (e) {
        // 结构异常按「未提供」降级
      }
    }
    if (p.wsPath.length === 0 && p.wsHost.length === 0) {
      const wsBlock = YamlMerger.extractBlockBody(itemLines, 'ws-opts');
      if (wsBlock.length > 0) {
        const ws = YamlMerger.parseWsBlock(wsBlock);
        const bp = ws.get('path');
        if (bp !== undefined && bp.length > 0) {
          p.wsPath = bp;
        }
        const bh = ws.get('Host');
        if (bh !== undefined && bh.length > 0) {
          p.wsHost = bh;
        }
      }
    }

    // grpc-opts：flow-map 优先，失败/缺失回退块式
    const grpcFlow = fields.get('grpc-opts');
    if (grpcFlow !== undefined && grpcFlow.trim().length > 0) {
      try {
        const grpc = YamlMerger.parseRestrictedFlowMap(grpcFlow,
          new Set<string>(['grpc-service-name']));
        const g = grpc.get('grpc-service-name');
        if (g !== undefined && g.length > 0) {
          p.grpcServiceName = YamlMerger.decodeScalar(g);
        }
      } catch (e) {
        // 结构异常按「未提供」降级
      }
    }
    if (p.grpcServiceName.length === 0) {
      const grpcBlock = YamlMerger.extractBlockBody(itemLines, 'grpc-opts');
      if (grpcBlock.length > 0) {
        const m = YamlMerger.parseSimpleBlock(grpcBlock, new Set<string>(['grpc-service-name']));
        const g = m.get('grpc-service-name');
        if (g !== undefined && g.length > 0) {
          p.grpcServiceName = g;
        }
      }
    }
  }

  private static parseBoolean(value: string, fieldName: string): boolean {
    // 容错: true/1/yes → true; 其余(含缺失/异常值) → false, 绝不因布尔字段丢弃节点
    const normalized = value.toLowerCase().trim();
    return normalized === 'true' || normalized === '1' || normalized === 'yes';
  }

  private static validateNodeText(value: string, fieldName: string): void {
    if (value.length > MergeLimits.MAX_PROXY_FIELD_LENGTH) {
      throw new YamlMergeError(`订阅字段 ${fieldName} 长度超过上限 (64KB)`);
    }
    for (let i = 0; i < value.length; i++) {
      const code = value.charCodeAt(i);
      if (code < 0x20 || code === 0x7f) {
        throw new YamlNodeError(`代理节点字段 ${fieldName} 包含控制字符`);
      }
    }
  }

  /** mihomo 原生支持、但本客户端无结构化槽位的协议: 校验后整条中继, 不丢弃。 */
  private static readonly RELAY_TYPES: Set<string> = new Set<string>([
    'tuic', 'hysteria', 'http', 'socks5', 'snell', 'anytls', 'naive', 'shadowtls',
    'shadow-tls', 'ssh', 'mieru', 'wireguard'
  ]);

  /** 支持 alpn 的协议 (ss/ssr 不支持 alpn 键) */
  private static readonly ALPN_TYPES: Set<string> = new Set<string>([
    'vless', 'vmess', 'trojan', 'hysteria2', 'hysteria', 'tuic', 'anytls'
  ]);

  /** 本轮解析因「协议不支持/缺关键字段」被跳过的节点统计, 供上层提示用户 */
  static lastSkippedCount: number = 0;
  static lastSkippedTypes: string = '';

  static resetSkipStats(): void {
    YamlMerger.lastSkippedCount = 0;
    YamlMerger.lastSkippedTypes = '';
  }

  /** 登记一个被跳过的节点(按协议类型去重, 最多记 12 种) */
  static noteSkipped(typeText: string): void {
    YamlMerger.lastSkippedCount = YamlMerger.lastSkippedCount + 1;
    const t = typeText.trim().length > 0 ? typeText.trim().toLowerCase() : 'unknown';
    const seen = new Set<string>();
    for (const it of YamlMerger.lastSkippedTypes.split(',')) {
      if (it.length > 0) {
        seen.add(it);
      }
    }
    if (!seen.has(t) && seen.size < 12) {
      seen.add(t);
      YamlMerger.lastSkippedTypes = Array.from(seen).join(',');
    }
  }

  /**
   * 无结构化槽位的协议全部按安全中继处理。显式集合记录已验证协议，合法的未知
   * type 同样保留核心字段与 extraOpts，避免订阅升级后节点被静默丢弃。
   */
  static isRelayType(type: string): boolean {
    const normalized = type.trim().toLowerCase();
    return YamlMerger.RELAY_TYPES.has(normalized)
      || /^[a-z][a-z0-9-]{0,31}$/.test(normalized);
  }

  /** 该协议是否支持 alpn 键 */
  static supportsAlpn(type: string): boolean {
    return YamlMerger.ALPN_TYPES.has(type.trim().toLowerCase());
  }

  /** SNI 键名方案: hysteria2/hysteria/tuic 用 sni, 其余用 servername */
  static usesSniKey(type: string): boolean {
    const t = type.trim().toLowerCase();
    return t === 'hysteria2' || t === 'hysteria' || t === 'tuic';
  }

  /** 预读条目声明的 type(键顺序不定, 结构化映射前先判定是否走中继) */
  private static peekType(text: string): string {
    const m = text.match(/(?:^|[\s,{-])type\s*:\s*"?([A-Za-z0-9]{1,16})"?/);
    return m === null ? '' : m[1].toLowerCase();
  }

  /**
   * 白名单外额外字段捕获: 键名受限、值长度受限、禁止换行与注释符; 容器值({...}/[...])
   * 必须括号平衡且仅含安全字符 —— 防止破坏 flow-map 结构或注入额外配置行。
   * 非法时返回 null(仅丢该键, 绝不影响节点其余部分)。
   */
  /** 额外字段键必须是普通 Mihomo 键，并拒绝原型污染保留名。 */
  static isSafeExtraKey(key: string): boolean {
    return /^[a-z][a-z0-9-]{0,63}$/.test(key)
      && key !== '__proto__' && key !== 'prototype' && key !== 'constructor';
  }

  private static captureExtraOpt(key: string, rawValue: string): string | null {
    if (!YamlMerger.isSafeExtraKey(key)) {
      return null;
    }
    const raw = rawValue.trim();
    if (raw.length === 0 || raw.length > 512 || raw.includes('\n') || raw.includes('\r')
      || raw.includes('#')) {
      return null;
    }
    if (raw.startsWith('{') || raw.startsWith('[')) {
      let depth = 0;
      for (let i = 0; i < raw.length; i++) {
        const c = raw.charAt(i);
        if (c === '{' || c === '[') {
          depth = depth + 1;
        } else if (c === '}' || c === ']') {
          depth = depth - 1;
          if (depth < 0) {
            return null;
          }
        } else if (!/[A-Za-z0-9_ \t.,:\/=\-+"']/.test(c)) {
          return null;
        }
      }
      return depth === 0 ? raw : null;
    }
    try {
      return YamlMerger.decodeScalar(raw);
    } catch (e) {
      return null;
    }
  }

  /** extraOpts(JSON 数组) → 键值对列表; 结构异常返回空(不影响主流程) */
  static parseExtraOpts(extraOpts: string): string[][] {
    const out: string[][] = [];
    if (extraOpts.length === 0) {
      return out;
    }
    try {
      const parsed = JSON.parse(extraOpts) as string[][];
      if (Array.isArray(parsed)) {
        for (const pair of parsed) {
          if (Array.isArray(pair) && pair.length === 2
            && typeof pair[0] === 'string' && typeof pair[1] === 'string') {
            out.push([pair[0], pair[1]]);
          }
        }
      }
    } catch (e) {
      return [];
    }
    return out;
  }

  /**
   * 统一处理一个 key/value 对(flow-map 与块式两种写法共用):
   * - 中继协议: 核心四字段入 fields, 其余全部键值经校验后进 extras(原样透传);
   * - 结构化协议: 白名单键入 fields, 白名单外的安全键进 extras(不静默丢弃)。
   */
  private static applyPair(key: string, rawValue: string, relayMode: boolean,
    supportedKeys: Set<string>, fields: Map<string, string>, extras: string[][],
    extraSeen: Set<string>): void {
    if (relayMode) {
      if (key === 'name' || key === 'type' || key === 'server' || key === 'port') {
        try {
          fields.set(key, YamlMerger.decodeScalar(rawValue));
        } catch (e) {
          // 核心字段无法解析: 交由后续必需字段校验拒绝该节点
        }
      } else {
        const captured = YamlMerger.captureExtraOpt(key, rawValue);
        if (captured !== null) {
          extraSeen.add(key);
          extras.push([key, captured]);
        }
      }
      return;
    }
    if (!supportedKeys.has(key)) {
      const captured = YamlMerger.captureExtraOpt(key, rawValue);
      if (captured !== null) {
        extraSeen.add(key);
        extras.push([key, captured]);
      }
      return;
    }
    if (key === 'reality-opts' || key === 'ws-opts' || key === 'grpc-opts' || key === 'alpn') {
      fields.set(key, rawValue);
    } else {
      try {
        fields.set(key, YamlMerger.decodeScalar(rawValue));
      } catch (e) {
        // 值解析失败, 跳过该字段
      }
    }
  }

  /**
   * 解析单个 proxies 条目。结构化白名单标量走专用槽位; 白名单外的安全键进入 extraOpts
   * 中继(不再静默丢弃)。节点格式错误抛出 YamlNodeError，由 merge 跳过；
   * 全局限额仍抛出 YamlMergeError。
   */
  static parseProxyItem(itemLines: string[]): MergedProxy | null {
    const text = itemLines.join('\n').trim();
    if (text.length > MergeLimits.MAX_PROXY_ITEM_BYTES) {
      throw new YamlMergeError('单个节点内容大小超过上限');
    }
    const fields = new Map<string, string>();
    const extras: string[][] = [];
    const extraSeen = new Set<string>();
    // 中继协议(tuic/hysteria/http/socks5/...)无结构化槽位: 除核心四字段外全部原样透传,
    // 避免键名映射差异(如 sni/servername、obfs-password)让 mihomo 收到错误的键。
    const relayMode = YamlMerger.isRelayType(YamlMerger.peekType(text));
    const supportedKeys = new Set<string>([
      'name', 'type', 'server', 'port', 'cipher', 'password',
      'protocol', 'protocol-param', 'protocol_param', 'obfs', 'obfs-param', 'obfs_param',
      'uuid', 'alterId', 'alter-id', 'udp', 'network', 'tls', 'servername', 'sni',
      'skip-cert-verify', 'flow', 'client-fingerprint', 'reality-opts', 'ws-opts', 'grpc-opts',
      'up', 'down', 'upmbps', 'downmbps', 'alpn', 'obfs-password', 'fingerprint',
      // 部分面板不用 ws-opts 嵌套, 而是把 WS 参数平铺为顶层别名
      'ws-path', 'ws-host', 'ws-headers'
    ]);
    const body = text.startsWith('- ') ? text.substring(2) : text;
    if (body.trimStart().startsWith('{')) {
      const inner = body.trim();
      if (!inner.endsWith('}')) {
        throw new YamlNodeError('代理节点 flow-map 未闭合');
      }
      const content = inner.substring(inner.indexOf('{') + 1, inner.length - 1);
      const pairs = YamlMerger.splitFlowMap(content);
      for (const pair of pairs) {
        const idx = YamlMerger.findUnquotedColon(pair);
        if (idx <= 0) {
          continue; // 无法识别的片段, 忽略该字段(不丢弃整个节点)
        }
        let key = '';
        try {
          key = YamlMerger.decodeScalar(pair.substring(0, idx).trim());
        } catch (e) {
          continue;
        }
        // 重复键忽略; 白名单外的安全键不再丢弃, 而是进入 extraOpts 中继。
        if (key.length === 0 || fields.has(key) || extraSeen.has(key)) {
          continue;
        }
        YamlMerger.applyPair(key, pair.substring(idx + 1).trim(), relayMode, supportedKeys,
          fields, extras, extraSeen);
      }
    } else {
      for (const line of itemLines) {
        const t = line.trim().replace(/^- /, '');
        if (t.length === 0 || t.startsWith('#') || t.startsWith('- ')) {
          continue; // 空行/注释/数组子项, 跳过
        }
        const idx = YamlMerger.findUnquotedColon(t);
        if (idx <= 0) {
          continue; // 非 key:value 行, 忽略
        }
        let key = '';
        try {
          key = YamlMerger.decodeScalar(t.substring(0, idx).trim());
        } catch (e) {
          continue;
        }
        // 重复键忽略; 白名单外的安全键不再丢弃, 而是进入 extraOpts 中继。
        if (key.length === 0 || fields.has(key) || extraSeen.has(key)) {
          continue;
        }
        YamlMerger.applyPair(key, t.substring(idx + 1).trim(), relayMode, supportedKeys,
          fields, extras, extraSeen);
      }
    }
    const name = fields.get('name') ?? '';
    const server = fields.get('server') ?? '';
    const portStr = fields.get('port') ?? '0';
    const proxyType = (fields.get('type') ?? '').toLowerCase();
    if (name.length === 0 || server.length === 0 || proxyType.length === 0) {
      throw new YamlNodeError('代理节点缺少 name、type 或 server');
    }
    if (proxyType !== 'ss' && proxyType !== 'ssr' && proxyType !== 'vless'
      && proxyType !== 'vmess' && proxyType !== 'trojan' && proxyType !== 'hysteria2'
      && !YamlMerger.isRelayType(proxyType)) {
      // 记录被跳过的协议类型, 由订阅刷新流程提示用户(不再静默丢弃)
      YamlMerger.noteSkipped(proxyType);
      throw new YamlNodeError(`不支持的代理类型：${proxyType}`);
    }
    if (!/^\d{1,5}$/.test(portStr)) {
      throw new YamlNodeError('代理节点端口格式无效');
    }
    const portNum = parseInt(portStr);
    if (portNum <= 0 || portNum > 65535) {
      throw new YamlNodeError('代理节点端口超出范围');
    }
    const p = new MergedProxy();
    p.name = name;
    p.type = proxyType;
    p.server = server;
    p.port = portNum;
    p.cipher = fields.get('cipher') ?? '';
    p.password = fields.get('password') ?? '';
    p.protocol = fields.get('protocol') ?? '';
    p.protocolParam = fields.get('protocol-param') ?? fields.get('protocol_param') ?? '';
    p.obfs = fields.get('obfs') ?? '';
    p.obfsParam = fields.get('obfs-param') ?? fields.get('obfs_param') ?? '';
    // hysteria2 的混淆口令键名是 obfs-password，与 ssr 的 obfs-param 复用同一槽位，
    // 序列化时按类型区分输出键名。
    if (p.obfsParam.length === 0) {
      p.obfsParam = fields.get('obfs-password') ?? '';
    }
    p.uuid = fields.get('uuid') ?? '';
    const alterIdText = fields.get('alterId') ?? fields.get('alter-id') ?? '0';
    if (!/^\d{1,10}$/.test(alterIdText)) {
      throw new YamlNodeError('代理节点 alterId 格式无效');
    }
    p.alterId = parseInt(alterIdText);
    p.udp = YamlMerger.parseBoolean(fields.get('udp') ?? 'false', 'udp');
    p.network = fields.get('network') ?? '';
    p.tls = YamlMerger.parseBoolean(fields.get('tls') ?? 'false', 'tls');
    p.servername = fields.get('servername') ?? fields.get('sni') ?? '';
    p.skipCertVerify = YamlMerger.parseBoolean(fields.get('skip-cert-verify') ?? 'false',
      'skip-cert-verify');
    p.flow = fields.get('flow') ?? '';
    p.clientFingerprint = fields.get('client-fingerprint') ?? '';
    if (p.clientFingerprint.length === 0) {
      // hysteria2 的证书指纹(pinSHA256)键名是 fingerprint
      p.clientFingerprint = fields.get('fingerprint') ?? '';
    }
    if (proxyType === 'hysteria2' || proxyType === 'hysteria') {
      p.hyUp = YamlMerger.normalizeBandwidth(fields.get('up') ?? fields.get('upmbps') ?? '');
      p.hyDown = YamlMerger.normalizeBandwidth(fields.get('down') ?? fields.get('downmbps') ?? '');
    }
    if (YamlMerger.supportsAlpn(proxyType)) {
      // alpn 不再只限 hysteria2: vless/vmess/trojan 的 ALPN 协商同样需要它
      p.alpnList = YamlMerger.normalizeAlpnList(fields.get('alpn') ?? '');
    }
    try {
      YamlMerger.parseNestedOptions(fields, p, itemLines);
    } catch (e) {
      // reality-opts/ws-opts/grpc-opts 结构异常时忽略嵌套项, 不丢弃整个节点
      if (e instanceof YamlMergeError) {
        throw e;
      }
    }
    const values: string[] = [p.name, p.server, p.cipher, p.password, p.protocol, p.protocolParam,
      p.obfs, p.obfsParam, p.uuid, p.network, p.servername, p.flow, p.clientFingerprint,
      p.realityPublicKey, p.realityShortId, p.wsPath, p.wsHost, p.grpcServiceName,
      p.hyUp, p.hyDown, p.alpnList];
    for (let i = 0; i < values.length; i++) {
      YamlMerger.validateNodeText(values[i], `field-${i}`);
    }
    for (const pair of extras) {
      YamlMerger.validateNodeText(pair[1], 'extra-value');
    }
    p.extraOpts = extras.length > 0 ? JSON.stringify(extras) : '';
    if ((p.type === 'ss' || p.type === 'ssr') && (p.cipher.length === 0 || p.password.length === 0)) {
      throw new YamlNodeError(`代理节点「${p.name}」缺少 cipher 或 password`);
    }
    if (p.type === 'ssr' && (p.protocol.length === 0 || p.obfs.length === 0)) {
      throw new YamlNodeError(`SSR 节点「${p.name}」缺少 protocol 或 obfs`);
    }
    if ((p.type === 'vless' || p.type === 'vmess') && p.uuid.length === 0) {
      throw new YamlNodeError(`代理节点「${p.name}」缺少 uuid`);
    }
    if (p.type === 'vmess' && p.cipher.length === 0) {
      throw new YamlNodeError(`VMess 节点「${p.name}」缺少 cipher`);
    }
    if (p.type === 'trojan' && p.password.length === 0) {
      throw new YamlNodeError(`Trojan 节点「${p.name}」缺少 password`);
    }
    if (p.type === 'hysteria2' && p.password.length === 0) {
      throw new YamlNodeError(`Hysteria2 节点「${p.name}」缺少 password`);
    }
    return p;
  }

  /** 带宽值规整（Hysteria2 up/down）: 仅接受 数字[单位]；非法则丢弃 */
  static normalizeBandwidth(value: string): string {
    const v = value.trim();
    if (v.length === 0) {
      return '';
    }
    return /^[0-9]+(\.[0-9]+)?[A-Za-z]{0,6}$/.test(v) ? v : '';
  }

  /** ALPN 规整: ["h3","h4"] / [h3] / h3,h4 → "h3,h4"；含非法字符则整体丢弃 */
  static normalizeAlpnList(value: string): string {
    const cleaned = value.replace(/[\[\]"\s']/g, '');
    if (cleaned.length === 0) {
      return '';
    }
    // HTTP ALPN 标识通常包含斜杠（例如 http/1.1），不能按非法字符丢弃。
    return /^[A-Za-z0-9.,\/-]+$/.test(cleaned) ? cleaned : '';
  }

  /** 内容指纹：除 name 外包含全部协议及白名单嵌套字段。 */
  static identityFingerprint(p: MergedProxy): string {
    const parts: string[] = [];
    parts.push(`type=${JSON.stringify(p.type)}`);
    parts.push(`server=${JSON.stringify(p.server)}`);
    parts.push(`port=${p.port}`);
    parts.push(`cipher=${JSON.stringify(p.cipher)}`);
    parts.push(`password=${JSON.stringify(p.password)}`);
    parts.push(`protocol=${JSON.stringify(p.protocol)}`);
    parts.push(`protocolParam=${JSON.stringify(p.protocolParam)}`);
    parts.push(`obfs=${JSON.stringify(p.obfs)}`);
    parts.push(`obfsParam=${JSON.stringify(p.obfsParam)}`);
    parts.push(`uuid=${JSON.stringify(p.uuid)}`);
    parts.push(`alterId=${p.alterId}`);
    parts.push(`udp=${p.udp ? 'true' : 'false'}`);
    parts.push(`network=${JSON.stringify(p.network)}`);
    parts.push(`tls=${p.tls ? 'true' : 'false'}`);
    parts.push(`servername=${JSON.stringify(p.servername)}`);
    parts.push(`skipCertVerify=${p.skipCertVerify ? 'true' : 'false'}`);
    parts.push(`flow=${JSON.stringify(p.flow)}`);
    parts.push(`clientFingerprint=${JSON.stringify(p.clientFingerprint)}`);
    parts.push(`realityPublicKey=${JSON.stringify(p.realityPublicKey)}`);
    parts.push(`realityShortId=${JSON.stringify(p.realityShortId)}`);
    parts.push(`wsPath=${JSON.stringify(p.wsPath)}`);
    parts.push(`wsHost=${JSON.stringify(p.wsHost)}`);
    parts.push(`grpcServiceName=${JSON.stringify(p.grpcServiceName)}`);
    parts.push(`hyUp=${JSON.stringify(p.hyUp)}`);
    parts.push(`hyDown=${JSON.stringify(p.hyDown)}`);
    parts.push(`alpn=${JSON.stringify(p.alpnList)}`);
    parts.push(`extra=${JSON.stringify(p.extraOpts)}`);
    return parts.join('|');
  }

  /** 将结构化节点安全序列化为可回读的 Clash YAML，绝不拼接原始 YAML。 */
  static toYaml(proxies: MergedProxy[]): string {
    const lines: string[] = ['proxies:'];
    for (const p of proxies) {
      const fields: string[] = [];
      fields.push(`name: ${YamlMerger.encodeScalar(p.name)}`);
      fields.push(`type: ${YamlMerger.encodeScalar(p.type)}`);
      fields.push(`server: ${YamlMerger.encodeScalar(p.server)}`);
      fields.push(`port: ${p.port}`);
      if (p.cipher.length > 0) {
        fields.push(`cipher: ${YamlMerger.encodeScalar(p.cipher)}`);
      }
      if (p.password.length > 0) {
        fields.push(`password: ${YamlMerger.encodeScalar(p.password)}`);
      }
      if (p.protocol.length > 0) {
        fields.push(`protocol: ${YamlMerger.encodeScalar(p.protocol)}`);
      }
      if (p.protocolParam.length > 0) {
        fields.push(`protocol-param: ${YamlMerger.encodeScalar(p.protocolParam)}`);
      }
      if (p.obfs.length > 0) {
        fields.push(`obfs: ${YamlMerger.encodeScalar(p.obfs)}`);
      }
      if (p.obfsParam.length > 0) {
        // hysteria2 用 obfs-password 键，ssr 用 obfs-param 键（同一槽位）
        fields.push(`${p.type === 'hysteria2' ? 'obfs-password' : 'obfs-param'}: ${YamlMerger.encodeScalar(p.obfsParam)}`);
      }
      if (p.uuid.length > 0) {
        fields.push(`uuid: ${YamlMerger.encodeScalar(p.uuid)}`);
      }
      if (p.type === 'vmess') {
        fields.push(`alterId: ${p.alterId}`);
      }
      if (p.udp) {
        fields.push('udp: true');
      }
      if (p.network.length > 0) {
        fields.push(`network: ${YamlMerger.encodeScalar(p.network)}`);
      }
      if (p.tls) {
        fields.push('tls: true');
      }
      if (p.servername.length > 0) {
        // hysteria2/hysteria/tuic 的 SNI 键名是 sni（无 servername 选项）
        fields.push(`${YamlMerger.usesSniKey(p.type) ? 'sni' : 'servername'}: ${YamlMerger.encodeScalar(p.servername)}`);
      }
      if (p.skipCertVerify) {
        fields.push('skip-cert-verify: true');
      }
      if (p.flow.length > 0) {
        fields.push(`flow: ${YamlMerger.encodeScalar(p.flow)}`);
      }
      if (p.clientFingerprint.length > 0) {
        fields.push(`${p.type === 'hysteria2' ? 'fingerprint' : 'client-fingerprint'}: ${YamlMerger.encodeScalar(p.clientFingerprint)}`);
      }
      if (p.type === 'hysteria2' || p.type === 'hysteria') {
        if (p.hyUp.length > 0) {
          fields.push(`up: ${YamlMerger.encodeScalar(p.hyUp)}`);
        }
        if (p.hyDown.length > 0) {
          fields.push(`down: ${YamlMerger.encodeScalar(p.hyDown)}`);
        }
      }
      if (p.alpnList.length > 0 && YamlMerger.supportsAlpn(p.type)) {
        const items = p.alpnList.split(',');
        const flowItems: string[] = [];
        for (const it of items) {
          if (it.length > 0) {
            flowItems.push(YamlMerger.encodeScalar(it));
          }
        }
        if (flowItems.length > 0) {
          fields.push(`alpn: [${flowItems.join(', ')}]`);
        }
      }
      if (p.realityPublicKey.length > 0 || p.realityShortId.length > 0) {
        const reality: string[] = [];
        if (p.realityPublicKey.length > 0) {
          reality.push(`public-key: ${YamlMerger.encodeScalar(p.realityPublicKey)}`);
        }
        if (p.realityShortId.length > 0) {
          reality.push(`short-id: ${YamlMerger.encodeScalar(p.realityShortId)}`);
        }
        fields.push(`reality-opts: {${reality.join(', ')}}`);
      }
      if (p.wsPath.length > 0 || p.wsHost.length > 0) {
        const ws: string[] = [];
        if (p.wsPath.length > 0) {
          ws.push(`path: ${YamlMerger.encodeScalar(p.wsPath)}`);
        }
        if (p.wsHost.length > 0) {
          ws.push(`headers: {Host: ${YamlMerger.encodeScalar(p.wsHost)}}`);
        }
        fields.push(`ws-opts: {${ws.join(', ')}}`);
      }
      if (p.grpcServiceName.length > 0) {
        fields.push(`grpc-opts: {grpc-service-name: ${YamlMerger.encodeScalar(p.grpcServiceName)}}`);
      }
      // extraOpts 中继(与 ClashConfigGenerator.proxyYamlLine 保持一致): 不在结构化槽位
      // 内的键原样回写, 与已输出键重名时以结构化字段为准。
      const emittedKeys = new Set<string>();
      for (const f of fields) {
        const ci = f.indexOf(':');
        if (ci > 0) {
          emittedKeys.add(f.substring(0, ci).trim());
        }
      }
      for (const pair of YamlMerger.parseExtraOpts(p.extraOpts)) {
        const key = pair[0];
        const value = pair[1];
        if (emittedKeys.has(key) || key === 'name' || key === 'type' || key === 'server'
          || key === 'port' || !/^[a-z][a-z0-9-]{0,24}$/.test(key)) {
          continue;
        }
        if (value.startsWith('{') || value.startsWith('[')
          || value === 'true' || value === 'false' || /^-?[0-9]+(\.[0-9]+)?$/.test(value)) {
          fields.push(`${key}: ${value}`);
        } else {
          fields.push(`${key}: ${YamlMerger.encodeScalar(value)}`);
        }
        emittedKeys.add(key);
      }
      lines.push(`  - {${fields.join(', ')}}`);
    }
    return lines.join('\n') + '\n';
  }

  /** YAML 双引号标量编码，覆盖反斜杠、引号及所有控制字符。 */
  private static encodeScalar(value: string): string {
    let out = '"';
    for (let i = 0; i < value.length; i++) {
      const ch = value.charAt(i);
      const code = value.charCodeAt(i);
      if (ch === '\\') {
        out += '\\\\';
      } else if (ch === '"') {
        out += '\\"';
      } else if (ch === '\n') {
        out += '\\n';
      } else if (ch === '\r') {
        out += '\\r';
      } else if (ch === '\t') {
        out += '\\t';
      } else if (code < 0x20 || code === 0x7f) {
        const hex = code.toString(16).padStart(2, '0');
        out += `\\x${hex}`;
      } else {
        out += ch;
      }
    }
    return out + '"';
  }

  /** 唯一名（对齐 uniqueProxyName：首个复用原名，之后 " (2)"、" (3)" 递增） */
  static uniqueProxyName(baseName: string, used: Set<string>, nextByBase: Map<string, number>): string {
    const tracked = nextByBase.get(baseName);
    if (tracked === undefined && !used.has(baseName)) {
      used.add(baseName);
      nextByBase.set(baseName, 2);
      return baseName;
    }
    let suffix = tracked !== undefined ? tracked : 2;
    let candidate = `${baseName} (${suffix})`;
    while (used.has(candidate)) {
      suffix = suffix + 1;
      candidate = `${baseName} (${suffix})`;
    }
    used.add(candidate);
    nextByBase.set(baseName, suffix + 1);
    return candidate;
  }

  /**
   * 合并多个订阅 YAML（对齐 mergeYamlConfigs 主流程）：
   * 跨订阅按内容指纹去重 → previousYaml 同内容节点保留名称 → 其余唯一名分配。
   */
  static merge(yamls: string[], sourceName: string, previousYaml: string): MergedProxy[] {
    if (yamls.length > MergeLimits.MAX_MERGE_SOURCES) {
      throw new YamlMergeError('订阅来源数量超过上限 (1000)');
    }
    if (sourceName.length > MergeLimits.MAX_PROXY_FIELD_LENGTH) {
      throw new YamlMergeError('订阅字段长度超过上限 (64KB)');
    }

    // 1) 收集全部新节点（限额：总数 / 单条大小 / 字段长度）
    const fresh: MergedProxy[] = [];
    let count = 0;
    for (const yaml of yamls) {
      for (const itemLines of YamlMerger.proxyItemGroups(yaml)) {
        count = count + 1;
        if (count > MergeLimits.MAX_MERGED_PROXY_NODES) {
          throw new YamlMergeError('订阅节点数量超过上限 (10000)');
        }
        let p: MergedProxy | null = null;
        try {
          p = YamlMerger.parseProxyItem(itemLines);
        } catch (e) {
          if (e instanceof YamlNodeError) {
            continue;
          }
          throw new YamlMergeError(e instanceof Error ? e.message : '代理节点解析发生未知错误');
        }
        if (p === null) {
          continue;
        }
        fresh.push(p);
      }
    }

    // 2) 上一轮缓存中的名称保留表：内容指纹 → 名称
    const previousNameByFingerprint = new Map<string, string>();
    if (previousYaml.length > 0) {
      let prevCount = 0;
      for (const itemLines of YamlMerger.proxyItemGroups(previousYaml)) {
        prevCount = prevCount + 1;
        if (prevCount > MergeLimits.MAX_MERGED_PROXY_NODES) {
          throw new YamlMergeError('历史缓存节点数量超过上限');
        }
        let old: MergedProxy | null = null;
        try {
          old = YamlMerger.parseProxyItem(itemLines);
        } catch (e) {
          if (e instanceof YamlNodeError) {
            continue;
          }
          throw new YamlMergeError(e instanceof Error ? e.message : '代理节点解析发生未知错误');
        }
        if (old === null) {
          continue;
        }
        const fp = YamlMerger.identityFingerprint(old);
        if (!previousNameByFingerprint.has(fp)) {
          previousNameByFingerprint.set(fp, old.name);
        }
      }
    }

    // 3) 跨订阅指纹去重 + 名称分配（旧名优先，其余唯一名）
    const used = new Set<string>();
    const seenFingerprints = new Set<string>();
    const nextByBase = new Map<string, number>();
    const merged: MergedProxy[] = [];
    let outputBytes = 9; // "proxies:\n"
    for (const p of fresh) {
      const fp = YamlMerger.identityFingerprint(p);
      if (seenFingerprints.has(fp)) {
        continue;
      }
      seenFingerprints.add(fp);
      const preserved = previousNameByFingerprint.get(fp);
      if (preserved !== undefined && !used.has(preserved)) {
        p.name = preserved;
        used.add(preserved);
      } else {
        p.name = YamlMerger.uniqueProxyName(p.name, used, nextByBase);
      }
      // 输出体积限额
      outputBytes = outputBytes + 5 + util.TextEncoder.create('utf-8').encodeInto(p.name).length
        + p.server.length + p.password.length + 80;
      if (outputBytes > MergeLimits.MAX_MERGED_OUTPUT_BYTES) {
        throw new YamlMergeError('合并结果大小超过上限 (20MB)');
      }
      merged.push(p);
    }
    return merged;
  }
}
