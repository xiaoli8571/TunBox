/**
 * 订阅 YAML 合并引擎
 * 移植自 upstream: packages/tunbox_shared/lib/services/subscription_yaml_merger.dart
 *                packages/tunbox_shared/lib/utils/bounded_yaml.dart
 *
 * 语义对齐：proxies 分节提取与缩进规整、条目切分、按内容指纹跨订阅去重（保留归属）、
 *           与 previousYaml 的同名节点保留（刷新不重排名称）、唯一名 "(n)" 后缀、全部限额。
 * 解析范围：flow-map 与块式两种写法、块标量（`|`/`>` 及其缩进/裁剪/显式缩进指示符）、
 *           锚点/别名（含链式、顶层与跨分节定义、限深环保护）与 `<<` 合并键（含嵌套容器深链）、
 *           dialer-proxy 依赖校验、单节点/单字段限额的逐条降级。
 * 已知极限（不做全量 YAML 语义）：多行 literal 块体进入单行槽位时按该字段缺失处理；
 *           别名只解到锚点的原始文本，不做锚点内嵌锚点的深度再解析；不支持 YAML 标签、
 *           复杂键（`? key`）、`!!binary`/时间戳等类型化标量、以及流式多文档合并。
 */
import { util } from '@kit.ArkTS';

/**
 * 错误 → 文本（本文件保持零额外依赖）：解析路径抛出的常是普通对象（{message}），
 * Error 实例判断会丢消息（[object Object] 类问题）；与 AppLogger.errText 同语义。
 */
function errorTextOr(e: Object, fallback: string): string {
  if (e !== null && e !== undefined) {
    const msgVal = (e as Record<string, Object>).message;
    if (typeof msgVal === 'string' && (msgVal as string).length > 0) {
      return msgVal as string;
    }
    const text = String(e);
    if (text.length > 0 && text !== '[object Object]') {
      return text;
    }
  }
  return fallback;
}

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
  /** 证书指纹 pinSHA256（mihomo 键 `fingerprint`），与 uTLS 的 clientFingerprint 分开 */
  certFingerprint: string = '';
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
  /**
   * 原始节点行的逐字模板（flow-map 内部键值），已剔除 name 与凭据键
   * (uuid/password/protocol-param/obfs-param/obfs-password)。生成配置时
   * 直接回写这段 + 注入 name/凭据，避免「解析→重生成」丢失任何传输字段
   * （xhttp-opts、reality-opts、headers、null 值等）。块式写法或 URI 导入
   * 的节点无此模板，回退到结构化生成路径。
   */
  rawTemplate: string = '';
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
  /** Read names without interpreting a proxy protocol or rebuilding its fields. */
  static sequenceItemNames(yaml: string, section: string): string[] {
    const out: string[] = [];
    const lines = YamlMerger.normalizedSectionLines(yaml, section);
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (!line.startsWith('  -')) { continue; }
      const first = line.substring(3).trim();
      if (first.startsWith('{')) {
        const end = first.lastIndexOf('}');
        for (const field of YamlMerger.splitFlowMap(first.substring(1, end))) {
          const colon = YamlMerger.findUnquotedColon(field);
          if (colon >= 0 && YamlMerger.decodeScalar(field.substring(0, colon)) === 'name') {
            out.push(YamlMerger.decodeScalar(field.substring(colon + 1)));
          }
        }
      } else {
        const fields: string[] = [first];
        for (let j = i + 1; j < lines.length && !lines[j].startsWith('  -'); j++) {
          if (lines[j].startsWith('    ') && !lines[j].startsWith('     ')) {
            fields.push(lines[j].trim());
          }
        }
        for (const field of fields) {
          const colon = YamlMerger.findUnquotedColon(field);
          if (colon >= 0 && YamlMerger.decodeScalar(field.substring(0, colon)) === 'name') {
            out.push(YamlMerger.decodeScalar(field.substring(colon + 1)));
          }
        }
      }
    }
    return out;
  }
  /** 提取指定顶层分节并归一化缩进为 2 空格（对齐 _normalizedSectionLines） */
  static extractSection(yaml: string, sectionName: string): string {
    const lines = YamlMerger.normalizedSectionLines(yaml, sectionName);
    return lines.join('\n');
  }

  // ─────────────────── 订阅 dns 段提取（2026-10-20 全超时定案） ───────────────────
  //
  // 机场把「入口域名 → 真实入口 IP」只告诉自家私有 DoH，公共 DNS 给出的是
  // Cloudflare / WAF 前置 IP（那些 IP 上代理端口不通或不提供协议服务）。
  // 因此 `dns.proxy-server-nameserver` / `dns.nameserver-policy` 必须原样保留到
  // 运行配置里 —— 否则订阅里所有域名节点必然超时（真机与真实内核双重取证）。
  //
  // 这里只做「取值」，不做协议判定与安全校验：上游字符串的白名单/上限在
  // ClashConfigGenerator 写入 YAML 前统一做（单一真源，避免两处口径不一致）。

  /**
   * 取 `dns.proxy-server-nameserver` 的上游列表（去引号 / 去重 / 上限 8 条）。
   *
   * 支持三种写法：行内流式序列 `[a, b]`、块式序列（`- a` 逐行）、单标量。
   */
  static extractDnsProxyServers(dnsText: string): string[] {
    const out: string[] = [];
    const seen: Set<string> = new Set<string>();
    const values = YamlMerger.dnsScalarValues(dnsText, 'proxy-server-nameserver');
    for (const raw of values) {
      const v = YamlMerger.unquoteYamlScalar(raw);
      if (v.length === 0 || v.length > 512 || seen.has(v)) {
        continue;
      }
      if (out.length >= 8) {
        break;
      }
      seen.add(v);
      out.push(v);
    }
    return out;
  }

  /**
   * 取 `dns.nameserver-policy` 与 `dns.proxy-server-nameserver-policy` 的条目，
   * 展平为 `[[后缀, 上游], …]`（一个后缀多个上游 = 多行；去重 / 上限 64 对）。
   *
   * 调用方（生成器）只保留后缀命中**节点域名**的条目，不会把机场针对其它域名的
   * 策略带进用户的 DNS 策略里。
   */
  static extractDnsPolicyPairs(dnsText: string): string[][] {
    const out: string[][] = [];
    const seen: Set<string> = new Set<string>();
    const keys: string[] = ['nameserver-policy', 'proxy-server-nameserver-policy'];
    for (const key of keys) {
      for (const pair of YamlMerger.dnsPolicyEntries(dnsText, key)) {
        const suffix = YamlMerger.unquoteYamlScalar(pair[0]).trim();
        const server = YamlMerger.unquoteYamlScalar(pair[1]).trim();
        if (suffix.length === 0 || suffix.length > 253 || server.length === 0
          || server.length > 512) {
          continue;
        }
        const id = `${suffix}\u0000${server}`;
        if (seen.has(id)) {
          continue;
        }
        if (out.length >= 64) {
          return out;
        }
        seen.add(id);
        out.push([suffix, server]);
      }
    }
    return out;
  }

  /** 去掉一层匹配的引号（'…' / "…"）；DNS 上游与后缀里不会出现转义引号。 */
  private static unquoteYamlScalar(raw: string): string {
    let v = raw.trim();
    if (v.length >= 2) {
      const first = v.charAt(0);
      const last = v.charAt(v.length - 1);
      const quoted = (first === '\'' && last === '\'') || (first === '"' && last === '"');
      if (quoted) {
        v = v.substring(1, v.length - 1);
      }
    }
    return v;
  }

  /** 行首缩进宽度（空格/Tab 都计数，dns 段里两者不会混用） */
  private static indentOf(line: string): number {
    let n = 0;
    while (n < line.length) {
      const ch = line.charAt(n);
      if (ch !== ' ' && ch !== '\t') {
        break;
      }
      n++;
    }
    return n;
  }

  /** 找到 `  <key>:` 这一行（要求缩进 ≥ 2 且 key 后紧跟空白或行尾） */
  private static dnsKeyIndex(lines: string[], key: string): number {
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const indent = YamlMerger.indentOf(line);
      if (indent < 2) {
        continue;
      }
      const text = line.substring(indent);
      if (!text.startsWith(`${key}:`)) {
        continue;
      }
      const rest = text.substring(key.length + 1);
      if (rest.length > 0) {
        const ch = rest.charAt(0);
        if (ch !== ' ' && ch !== '\t') {
          continue; // `nameserver-policy-extra:` 之类的近名键
        }
      }
      return i;
    }
    return -1;
  }

  /** 从 openIdx 处的 `[`/`{` 找到配对的闭括号下标（找不到返回文本末尾） */
  private static matchClose(text: string, openIdx: number): number {
    let depth = 0;
    let quote = '';
    for (let i = openIdx; i < text.length; i++) {
      const ch = text.charAt(i);
      if (quote.length > 0) {
        if (ch === quote) {
          quote = '';
        }
        continue;
      }
      if (ch === '\'' || ch === '"') {
        quote = ch;
        continue;
      }
      if (ch === '[' || ch === '{') {
        depth++;
        continue;
      }
      if (ch === ']' || ch === '}') {
        depth--;
        if (depth === 0) {
          return i;
        }
      }
    }
    return text.length;
  }

  /** 按顶层逗号切分（跳过引号内与括号内的逗号） */
  private static splitFlow(text: string): string[] {
    const out: string[] = [];
    let depth = 0;
    let quote = '';
    let start = 0;
    for (let i = 0; i < text.length; i++) {
      const ch = text.charAt(i);
      if (quote.length > 0) {
        if (ch === quote) {
          quote = '';
        }
        continue;
      }
      if (ch === '\'' || ch === '"') {
        quote = ch;
        continue;
      }
      if (ch === '[' || ch === '{') {
        depth++;
        continue;
      }
      if (ch === ']' || ch === '}') {
        depth--;
        continue;
      }
      if (ch === ',' && depth === 0) {
        const piece = text.substring(start, i).trim();
        if (piece.length > 0) {
          out.push(piece);
        }
        start = i + 1;
      }
    }
    const tail = text.substring(start).trim();
    if (tail.length > 0) {
      out.push(tail);
    }
    return out;
  }

  /** 按**第一个**顶层冒号切 `key: value`（返回 [key, value]，无冒号时 value 为空） */
  private static splitMapEntry(entry: string): string[] {
    let depth = 0;
    let quote = '';
    for (let i = 0; i < entry.length; i++) {
      const ch = entry.charAt(i);
      if (quote.length > 0) {
        if (ch === quote) {
          quote = '';
        }
        continue;
      }
      if (ch === '\'' || ch === '"') {
        quote = ch;
        continue;
      }
      if (ch === '[' || ch === '{') {
        depth++;
        continue;
      }
      if (ch === ']' || ch === '}') {
        depth--;
        continue;
      }
      if (ch === ':' && depth === 0) {
        return [entry.substring(0, i).trim(), entry.substring(i + 1).trim()];
      }
    }
    return [entry.trim(), ''];
  }

  /** 一个 `key:` 下的标量序列值（流式 `[…]` / 块式 `- x` / 单标量） */
  private static dnsScalarValues(dnsText: string, key: string): string[] {
    const out: string[] = [];
    const lines = dnsText.split('\n');
    const idx = YamlMerger.dnsKeyIndex(lines, key);
    if (idx < 0) {
      return out;
    }
    const line = lines[idx].replace(/\r$/, '');
    const indent = YamlMerger.indentOf(line);
    const rest = line.substring(indent + key.length + 1).trim();
    if (rest.length > 0) {
      if (rest.startsWith('[')) {
        const close = YamlMerger.matchClose(rest, 0);
        for (const item of YamlMerger.splitFlow(rest.substring(1, close))) {
          out.push(item);
        }
        return out;
      }
      if (!rest.startsWith('{')) {
        out.push(rest); // 单标量写法
      }
      return out;
    }
    // 块式序列：缩进更深的 `- x` 行
    for (let i = idx + 1; i < lines.length; i++) {
      const cur = lines[i].replace(/\r$/, '');
      const trimmed = cur.trim();
      if (trimmed.length === 0) {
        continue;
      }
      const curIndent = YamlMerger.indentOf(cur);
      if (curIndent <= indent) {
        break;
      }
      if (trimmed.startsWith('#')) {
        continue;
      }
      if (trimmed === '-') {
        out.push('');
        continue;
      }
      if (trimmed.startsWith('- ')) {
        out.push(trimmed.substring(2).trim());
        continue;
      }
      break;
    }
    return out;
  }

  /** 一个 `key:` 下的 mapping 条目 → 展平的 [后缀, 上游] 对（流式 `{…}` / 块式） */
  private static dnsPolicyEntries(dnsText: string, key: string): string[][] {
    const out: string[][] = [];
    const lines = dnsText.split('\n');
    const idx = YamlMerger.dnsKeyIndex(lines, key);
    if (idx < 0) {
      return out;
    }
    const line = lines[idx].replace(/\r$/, '');
    const indent = YamlMerger.indentOf(line);
    const rest = line.substring(indent + key.length + 1).trim();
    if (rest.startsWith('{')) {
      const close = YamlMerger.matchClose(rest, 0);
      for (const entry of YamlMerger.splitFlow(rest.substring(1, close))) {
        const pair = YamlMerger.splitMapEntry(entry);
        if (pair[0].length === 0) {
          continue;
        }
        YamlMerger.pushPolicyValues(out, pair[0], pair[1]);
      }
      return out;
    }
    // 块式 mapping：`    "+.x":` 后跟 `      - 上游`
    let currentKey = '';
    let keyIndent = -1;
    for (let i = idx + 1; i < lines.length; i++) {
      const cur = lines[i].replace(/\r$/, '');
      const trimmed = cur.trim();
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      const curIndent = YamlMerger.indentOf(cur);
      if (curIndent <= indent) {
        break;
      }
      const isItem = trimmed.startsWith('- ') || trimmed === '-';
      if (!isItem) {
        if (keyIndent < 0) {
          keyIndent = curIndent;
        }
        if (curIndent === keyIndent) {
          const pair = YamlMerger.splitMapEntry(trimmed);
          currentKey = pair[0];
          if (pair[1].length > 0) {
            YamlMerger.pushPolicyValues(out, currentKey, pair[1]);
          }
          continue;
        }
        break;
      }
      if (currentKey.length === 0) {
        continue;
      }
      YamlMerger.pushPolicyValues(out, currentKey,
        trimmed === '-' ? '' : trimmed.substring(2).trim());
    }
    return out;
  }

  /** 把 `后缀 → 值`（值是单标量或流式序列）展开成 [后缀, 上游] 对 */
  private static pushPolicyValues(out: string[][], rawKey: string, rawValue: string): void {
    const suffix = YamlMerger.unquoteYamlScalar(rawKey);
    if (suffix.length === 0) {
      return;
    }
    let value = rawValue.trim();
    if (value.length === 0) {
      return;
    }
    if (value.startsWith('[')) {
      const close = YamlMerger.matchClose(value, 0);
      for (const item of YamlMerger.splitFlow(value.substring(1, close))) {
        out.push([suffix, item]);
      }
      return;
    }
    value = YamlMerger.unquoteYamlScalar(value);
    if (value.length > 0) {
      out.push([suffix, value]);
    }
  }

  /**
   * 删除指定顶层分节（其余内容原样保留，行序不变）。
   * 分节不存在时原样返回。供 YAML 覆盖层的 rules/rule-providers 段合并
   * （合并进生成器的同段后，原文不能再携带这两个键，否则 mihomo 按重复键
   * 「后者覆盖前者」整段替换掉已合并的规则）。
   */
  static removeSection(yaml: string, sectionName: string): string {
    const out: string[] = [];
    let inSection = false;
    for (const raw of yaml.split('\n')) {
      const line = raw.endsWith('\n') ? raw.substring(0, raw.length - 1) : raw;
      if (!line.startsWith(' ') && !line.startsWith('\t')) {
        const trimmed = line.trim();
        if (trimmed.startsWith(`${sectionName}:`)) {
          inSection = true;
          continue;
        }
        if (inSection && trimmed.length > 0 && !trimmed.startsWith('#')
          && !trimmed.startsWith('- ')) {
          inSection = false; // 下一顶层键行 = 分节结束
        }
      }
      if (!inSection) {
        out.push(line);
      }
    }
    return out.join('\n');
  }

  /**
   * 已知的 mihomo/clash 顶层配置键。proxies 分节提取以此为「分节结束」的判定依据：
   * 只有顶层键行才可能结束分节，`<<:` 合并键、`...`/`---` 文档标记、锚点定义行
   * （`key: &anchor`）与零缩进的序列项（顶格写法 `- {...}`）都不再截断分节。
   * 历史缺陷：sectionLines 对**任何** 0 缩进行都 break，顶格 proxies 列表与多文档
   * 订阅因此整体解析出 0 个节点。
   */
  private static readonly TOP_LEVEL_KEYS: Set<string> = new Set<string>([
    'proxies', 'proxy-groups', 'proxy-providers', 'rules', 'rule-providers',
    'sub-rules', 'dns', 'hosts', 'tun', 'sniffer', 'experimental', 'profile',
    'authentication', 'listeners', 'interface-name', 'geox-url', 'geodata-mode',
    'geodata-loader', 'geosite-matcher', 'external-controller',
    'external-controller-cors', 'external-controller-tls', 'external-ui',
    'external-ui-name', 'external-ui-url', 'mixed-port', 'mixed-port-range',
    'port', 'socks-port', 'redir-port', 'tproxy-port', 'allow-lan', 'bind-address',
    'mode', 'log-level', 'ipv6', 'disable-ipv6', 'secret', 'unified-delay',
    'tcp-concurrent', 'udp-timeout', 'global-client-fingerprint',
    'find-process-mode', 'keep-alive-interval', 'keep-alive-idle', 'routing-mark',
    'cfw-latency-url', 'cfw-bypass', 'etag-support', 'iptables'
  ]);

  /** 0 缩进行是否是顶层键行（`key: ...`）；序列项 / 文档标记 / 合并键都返回 false。 */
  private static isTopLevelKeyLine(trimmed: string): boolean {
    if (trimmed.startsWith('- ') || trimmed === '-') {
      return false;
    }
    if (trimmed.startsWith('<<') || trimmed.startsWith('...') || trimmed.startsWith('---')) {
      return false;
    }
    return YamlMerger.topLevelKeyOf(trimmed).length > 0;
  }

  /** 顶层键名（`key:` 形式的 0 缩进行）；非键行返回 ''。 */
  private static topLevelKeyOf(trimmed: string): string {
    const m = trimmed.match(/^([A-Za-z_][A-Za-z0-9_.-]*)[ \t]*:/);
    return m === null ? '' : m[1];
  }

  /** `name: &anchor` 形态的锚点定义行：它是 YAML 锚点定义段，不是分节边界。 */
  private static isAnchorDefinitionLine(trimmed: string): boolean {
    const idx = trimmed.indexOf(':');
    if (idx <= 0) {
      return false;
    }
    return trimmed.substring(idx + 1).trim().startsWith('&');
  }

  private static sectionLines(yaml: string, sectionName: string): string[] {
    const out: string[] = [];
    let inSection = false;
    const rawLines = yaml.split('\n');
    for (let raw of rawLines) {
      let line = raw;
      // CRLF 归一：行尾 \r 若进入标量，会被 validateNodeText 判成控制字符而丢掉节点。
      if (line.length > 0 && line.charAt(line.length - 1) === '\r') {
        line = line.substring(0, line.length - 1);
      }
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
        if (inSection && trimmed.length > 0 && !trimmed.startsWith('#')) {
          const sequenceItem = trimmed.startsWith('- ') || trimmed === '-';
          if (!sequenceItem) {
            if (!YamlMerger.isTopLevelKeyLine(trimmed)) {
              // `---` / `...` 文档标记：多文档订阅不得因此截断，跳过即可。
              continue;
            }
            const key = YamlMerger.topLevelKeyOf(trimmed);
            if (key === '<<' || YamlMerger.isAnchorDefinitionLine(trimmed)) {
              // 顶层 `<<: *base` 合并键与锚点定义段：不是分节边界，跳过继续收集。
              continue;
            }
            if (YamlMerger.TOP_LEVEL_KEYS.has(key)) {
              break; // 已知顶层键 = 分节结束
            }
            // 未列出的顶层键同样结束分节：同一个 YAML 映射的条目必然连续，分节内不会
            // 再出现兄弟顶层键；继续吸收只会把下一分节的缩进内容误当成代理条目。
            break;
          }
          // 顶格序列项（`proxies:` 后不缩进的 `- {...}` 写法）属于本分节：继续收集。
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
    let listIndent = 999;
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
      // 基准缩进以条目行为准：既有 `- {...}` 带尾随空格，也有部分面板/生成器
      //（如 mitce v2Net 订阅）写成裸连字符 `  -` 且后续键缩进承载的块式条目。
      // 裸 `-` 行同样是序列项起点，必须计入基准，否则 listIndent 退化为 999 →
      // minIndent 取最小缩进，全部条目被额外缩进，proxyItemGroups 切出 0 个条目组。
      if ((trimmed.startsWith('- ') || trimmed === '-') && indent < listIndent) {
        listIndent = indent;
      }
    }
    if (listIndent !== 999) {
      minIndent = listIndent;
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
    // 锚点/别名是文件级作用域：解析条目前先收集整份文档里的 `&anchor` 定义，
    // 条目内部的 `*alias` / `<<: *base` 才能解引用。未命中的别名按「字段缺失」
    // 处理（绝不因为一个别名丢掉整条节点）。
    YamlMerger.collectAnchors(yaml.split('\n'));
    const lines = YamlMerger.normalizedSectionLines(yaml, 'proxies');
    const items: string[][] = [];
    let current: string[] | null = null;
    for (const line of lines) {
      // 条目起点兼容两种 YAML 块序列写法：
      //   1) "  - {...}" / "  - key: value"（带尾随空格，绝大多数 Clash 生成器）
      //   2) "  -"（裸连字符，name/type/server 等键由后续更深缩进行承载 ——
      //      mitce v2Net 等面板的订阅格式）。此前只认 1)，第 2) 种订阅整份
      //      切出 0 个条目组，表现为「导入失败 / 0 节点」。
      if (line.startsWith('  - ') || YamlMerger.isBareSequenceItem(lines, line)) {
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
   * 裸连字符序列项（`  -`，无尾随空格）判定：该行恰为缩进 + `-`，且其后第一个
   * 非空行缩进**更深**（键由子行承载）才算真条目。用于兼容块式写法，避免把
   * 普通缩进内容误当条目。lines 为 normalizedSectionLines 的输出。
   */
  private static isBareSequenceItem(lines: string[], line: string): boolean {
    if (!line.startsWith('  ') || line.trim() !== '-') {
      return false;
    }
    const baseIndent = line.length - line.trimStart().length;
    for (let j = lines.indexOf(line) + 1; j < lines.length; j++) {
      const next = lines[j];
      if (next.trim().length === 0) {
        continue;
      }
      return (next.length - next.trimStart().length) > baseIndent;
    }
    return false;
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

  /** 从 `openIndex` 处的 `{`/`[` 起找匹配的闭合符；引号与嵌套深度都被跟踪，未闭合返回 -1。 */
  private static matchingClose(text: string, openIndex: number): number {
    let depth = 0;
    let quote = '';
    let escaped = false;
    for (let i = openIndex; i < text.length; i++) {
      const ch = text.charAt(i);
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
          if (quote === "'" && i + 1 < text.length && text.charAt(i + 1) === "'") {
            i = i + 1;
          } else {
            quote = '';
          }
        }
        continue;
      }
      if (ch === '"' || ch === "'") {
        quote = ch;
      } else if (ch === '{' || ch === '[') {
        depth = depth + 1;
      } else if (ch === '}' || ch === ']') {
        depth = depth - 1;
        if (depth <= 0) {
          return depth === 0 ? i : -1;
        }
      }
    }
    return -1;
  }

  /** 从 `openIndex` 处的引号起找配对的结束引号（含 `''` 与 `\"` 转义）；未闭合返回 -1。 */
  private static quotedClose(text: string, openIndex: number): number {
    const quote = text.charAt(openIndex);
    let escaped = false;
    for (let i = openIndex + 1; i < text.length; i++) {
      const ch = text.charAt(i);
      if (quote === '"' && escaped) {
        escaped = false;
        continue;
      }
      if (quote === '"' && ch === '\\') {
        escaped = true;
        continue;
      }
      if (ch === quote) {
        if (quote === "'" && i + 1 < text.length && text.charAt(i + 1) === "'") {
          i = i + 1;
          continue;
        }
        return i;
      }
    }
    return -1;
  }

  /** 剥离标量前缀修饰符：`&anchor` 定义、`!tag` / `!!str` 标签（可叠加）。 */
  private static stripModifiers(input: string): string {
    let value = input.trim();
    for (let guard = 0; guard < 4; guard++) {
      if (value.length === 0) {
        break;
      }
      if (value.charAt(0) === '&') {
        const m = value.match(/^&[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}[ \t]*(.*)$/);
        value = m === null ? '' : m[1].trim();
        continue;
      }
      if (value.charAt(0) === '!') {
        const m = value.match(/^!{1,2}[A-Za-z0-9_:-]*[ \t]*(.*)$/);
        value = m === null ? '' : m[1].trim();
        continue;
      }
      break;
    }
    return value;
  }

  /** 同一文件内已解析的锚点：名称 → 原始值文本（标量 / flow-map / 合成的块式 map）。 */
  private static anchors: Map<string, string> = new Map<string, string>();

  /** 别名解引用最大跳数（自引用/互引用/递归锚点超过它就按「字段缺失」处理，绝不递归失控）。 */
  private static readonly MAX_ALIAS_DEPTH: number = 8;
  /** `<<` 合并键最大展开层数（嵌套容器深链）。 */
  private static readonly MAX_MERGE_DEPTH: number = 8;

  /** `*name` 别名解引用：命中返回锚点原始值文本；未命中返回 ''（按字段缺失处理）。 */
  private static resolveAlias(raw: string): string {
    return YamlMerger.resolveAliasDepth(raw, 0, new Set<string>());
  }

  /**
   * 限深别名解引用。支持 `*a`（值）与 `*a → *b → 值` 的链式引用；锚点定义可以是
   * 标量、flow-map，也可以是块式子键合成的 map（collectAnchors/nestedValueOf）。
   *
   * 环保护：自引用 `&a *a`、互引用 `&a *b` / `&b *a`、以及嵌套在锚点值里的自引用
   * 都在这里被 `seen` 集合拦住；超过 MAX_ALIAS_DEPTH 的深链同样返回 ''。
   * 两种超限都只是「该字段缺失」（由调用方计入 invalid），绝不会死循环或丢整条节点。
   */
  private static resolveAliasDepth(raw: string, depth: number, seen: Set<string>): string {
    const value = raw.trim();
    if (value.length === 0 || value.charAt(0) !== '*') {
      return raw;
    }
    const m = value.match(/^\*([A-Za-z0-9_][A-Za-z0-9_.-]{0,63})/);
    if (m === null) {
      return '';
    }
    const name = m[1];
    if (depth >= YamlMerger.MAX_ALIAS_DEPTH || seen.has(name)) {
      return '';
    }
    seen.add(name);
    const hit = YamlMerger.anchors.get(name);
    if (hit === undefined || hit.length === 0) {
      return '';
    }
    if (hit.trim().charAt(0) === '*') {
      return YamlMerger.resolveAliasDepth(hit, depth + 1, seen);
    }
    return hit;
  }

  /**
   * 扫描整份文本收集 `&name value` 锚点定义。值一律保留原始文本（标量 / flow-map），
   * 块式锚点（`key: &base` 后跟缩进子键）用 nestedValueOf 合成为 flow-map。
   */
  private static collectAnchors(lines: string[]): void {
    YamlMerger.anchors.clear();
    for (let i = 0; i < lines.length; i++) {
      const text = lines[i].trim();
      if (text.length === 0 || text.startsWith('#')) {
        continue;
      }
      let from = 0;
      while (from < text.length) {
        const chunk = text.substring(from);
        const m = chunk.match(/(?:^|[\s,{[(-])&([A-Za-z0-9_][A-Za-z0-9_.-]{0,63})(?=[\s,}\]]|$)/);
        if (m === null) {
          break;
        }
        const name = m[1];
        const matched = m.index === undefined ? 0 : m.index;
        const start = from + matched + m[0].length;
        let value = text.substring(start).trim();
        if (value.startsWith('#')) {
          value = '';
        }
        if (value.length === 0) {
          // 块式锚点：值由缩进子键承载。序列项锚点(`- &base`)的子键与父行同缩进级别。
          const seqBase = text.startsWith('- ') || text === '-';
          value = YamlMerger.nestedValueOf(lines, i, seqBase, 1);
        }
        if (value.length > 0 && value.length <= 4096 && !YamlMerger.anchors.has(name)) {
          YamlMerger.anchors.set(name, value);
        }
        from = start;
      }
    }
  }

  /**
   * 把块式缩进子键合成为 flow 表示：`key:` 子键 → `{k: v, ...}`，`- v` 子项 → `[v, ...]`。
   * `seqBase` 用于「父行是序列项(`- key:`)」的情形（此时子键缩进级别与父行文本同级）。
   * 找不到子键返回 ''（调用方按字段缺失处理）；绝不抛错。
   */
  private static nestedValueOf(lines: string[], index: number, seqBase: boolean,
    depth: number): string {
    if (index < 0 || index >= lines.length || depth > 8) {
      return '';
    }
    const line = lines[index];
    const lead = line.length - line.trimStart().length;
    const base = seqBase ? lead : YamlMerger.lineIndent(line);
    const children: number[] = [];
    let childIndent = -1;
    for (let j = index + 1; j < lines.length; j++) {
      const raw = lines[j];
      const t = raw.trimStart();
      if (t.length === 0 || t.startsWith('#')) {
        continue;
      }
      const indent = YamlMerger.lineIndent(raw);
      if (indent <= base) {
        break;
      }
      if (childIndent < 0) {
        childIndent = indent;
      }
      if (indent === childIndent) {
        children.push(j);
      }
    }
    if (children.length === 0) {
      return '';
    }
    const firstText = lines[children[0]].trim();
    if (firstText === '-' || firstText.startsWith('- ')) {
      const items: string[] = [];
      for (const j of children) {
        const raw = lines[j].trim();
        const item = raw.startsWith('- ') ? raw.substring(2).trim() : '';
        let value = YamlMerger.stripModifiers(item);
        if (YamlMerger.isBlockScalarHeader(value)) {
          // `- |` / `- >` 序列项里的块标量体
          value = YamlMerger.blockScalarBody(lines, j, value);
        }
        if (value.length === 0) {
          continue;
        }
        const colon = YamlMerger.findUnquotedColon(value);
        if (colon > 0 && !value.startsWith('{') && !value.startsWith('[')
          && !value.startsWith('"') && !value.startsWith("'")) {
          // `- key: value` 形态：包成 flow-map，否则序列里会出现裸键值对。
          const k = value.substring(0, colon).trim();
          let v = value.substring(colon + 1).trim();
          if (v.length === 0) {
            v = YamlMerger.nestedValueOf(lines, j, true, depth + 1);
          }
          if (k.length === 0 || v.length === 0) {
            continue;
          }
          value = `{${k}: ${v}}`;
        }
        items.push(value);
      }
      return items.length > 0 ? `[${items.join(', ')}]` : '';
    }
    const pairs: string[] = [];
    for (const j of children) {
      const t = lines[j].trim();
      const colon = YamlMerger.findUnquotedColon(t);
      if (colon <= 0) {
        continue;
      }
      const k = t.substring(0, colon).trim();
      let value = t.substring(colon + 1).trim();
      if (value.length === 0) {
        value = YamlMerger.nestedValueOf(lines, j, false, depth + 1);
      } else if (YamlMerger.isBlockScalarHeader(value)) {
        // `path: |` + 缩进块体：嵌套容器里的块标量同样是「值」
        value = YamlMerger.blockScalarBody(lines, j, value);
      }
      value = YamlMerger.stripModifiers(value);
      if (k.length === 0 || value.length === 0) {
        continue;
      }
      pairs.push(`${k}: ${value}`);
    }
    return pairs.length > 0 ? `{${pairs.join(', ')}}` : '';
  }

  /**
   * 把 flow-map / 别名序列（`*base` 或 `[*a, *b]`）展开为 [key, rawValue] 列表。
   * 容器内的 `<<` 合并键同样会被递归展开（见 flowPairsDepth）。
   */
  private static flowPairs(raw: string): string[][] {
    return YamlMerger.flowPairsDepth(raw, 0);
  }

  /**
   * 展开 flow-map / 别名序列为 [key, rawValue] 列表（最多 MAX_MERGE_DEPTH 层）：
   * `*base`、`[*a, *b]`、`{...}` 都支持；容器里的 `<<` 合并键递归展开，**显式键优先**
   * （合并键只补缺失项）。递归/环形引用在限深处停止。结构不合法时返回已收得的部分，
   * 调用方逐项降级 —— 绝不因为一个坏引用丢掉整条节点。
   */
  private static flowPairsDepth(raw: string, depth: number): string[][] {
    const out: string[][] = [];
    if (depth > YamlMerger.MAX_MERGE_DEPTH) {
      return out;
    }
    const value = YamlMerger.resolveAlias(raw.trim());
    if (value.length === 0) {
      return out;
    }
    if (value.charAt(0) === '[') {
      const close = YamlMerger.matchingClose(value, 0);
      if (close < 0) {
        return out;
      }
      for (const item of YamlMerger.splitTopLevel(value.substring(1, close), ',')) {
        for (const pair of YamlMerger.flowPairsDepth(item, depth + 1)) {
          out.push(pair);
        }
      }
      return out;
    }
    if (value.charAt(0) !== '{') {
      return out;
    }
    const close = YamlMerger.matchingClose(value, 0);
    if (close < 0) {
      return out;
    }
    const merges: string[] = [];
    for (const pair of YamlMerger.splitTopLevel(value.substring(1, close), ',')) {
      const idx = YamlMerger.findUnquotedColon(pair);
      if (idx <= 0) {
        continue;
      }
      const key = pair.substring(0, idx).trim();
      if (key.length === 0) {
        continue;
      }
      if (key === '<<') {
        merges.push(pair.substring(idx + 1).trim());
        continue;
      }
      out.push([key, YamlMerger.resolveAlias(pair.substring(idx + 1).trim())]);
    }
    const seen = new Set<string>();
    for (const pair of out) {
      seen.add(pair[0]);
    }
    for (const mergeRaw of merges) {
      for (const inherited of YamlMerger.flowPairsDepth(mergeRaw, depth + 1)) {
        if (inherited[0].length === 0 || inherited[0] === '<<' || seen.has(inherited[0])) {
          continue; // 显式键优先：合并键只补缺失项
        }
        seen.add(inherited[0]);
        out.push(inherited);
      }
    }
    return out;
  }

  /**
   * 解码双引号标量内的 YAML 转义序列。
   *
   * 为什么不能只还原 `\"` 和 `\\`（2026-10-25 真机定案）：
   * 订阅导入时 `config.PrepareProfile`（内核 Go 侧）会把整份文档重新 marshal，
   * 非 BMP 字符（节点名里的国旗 emoji）被写成 `"\U0001F1EF\U0001F1F5日本•移联01"`。
   * 内核按 YAML 规范把它解成真 emoji，但本函数此前只还原 `\"`/`\\`，读出的名字
   * 带着字面反斜杠 —— 于是「名为 emoji 的节点」与「引用字面反斜杠的组成员」
   * 永远对不上，内核报 `proxy group[N]: ♻️ 自动选择: '\U0001F1EF...' not found`
   * 整份拒载，自动选择启动即失败。
   *
   * 覆盖 YAML 1.2 双引号标量允许的全部转义：`\0 \a \b \t \n \v \f \r \e \" \/
   * \\ \N \_ \L \P \xXX \uXXXX \UXXXXXXXX`，以及行尾折行（`\` 后换行折叠）。
   * 无法识别的转义原样保留（不猜、不吞），避免把用户的真实值改坏。
   */
  static unescapeDoubleQuoted(inner: string): string {
    if (inner.indexOf('\\') < 0) {
      return inner;
    }
    let out: string = '';
    let i: number = 0;
    while (i < inner.length) {
      const ch = inner.charAt(i);
      if (ch !== '\\') {
        out += ch;
        i += 1;
        continue;
      }
      if (i + 1 >= inner.length) {
        out += ch;
        i += 1;
        continue;
      }
      const esc = inner.charAt(i + 1);
      i += 2;
      if (esc === '0') {
        out += String.fromCharCode(0x00);
      } else if (esc === 'a') {
        out += String.fromCharCode(0x07);
      } else if (esc === 'b') {
        out += String.fromCharCode(0x08);
      } else if (esc === 't') {
        out += String.fromCharCode(0x09);
      } else if (esc === 'n') {
        out += String.fromCharCode(0x0a);
      } else if (esc === 'v') {
        out += String.fromCharCode(0x0b);
      } else if (esc === 'f') {
        out += String.fromCharCode(0x0c);
      } else if (esc === 'r') {
        out += String.fromCharCode(0x0d);
      } else if (esc === 'e') {
        out += String.fromCharCode(0x1b);
      } else if (esc === '"') {
        out += '"';
      } else if (esc === '/') {
        out += '/';
      } else if (esc === '\\') {
        out += '\\';
      } else if (esc === 'N') {
        out += String.fromCharCode(0x85);
      } else if (esc === '_') {
        out += String.fromCharCode(0xa0);
      } else if (esc === 'L') {
        out += String.fromCharCode(0x2028);
      } else if (esc === 'P') {
        out += String.fromCharCode(0x2029);
      } else if (esc === 'x') {
        const hex = inner.substring(i, i + 2);
        if (/^[0-9a-fA-F]{2}$/.test(hex)) {
          out += String.fromCharCode(parseInt(hex, 16));
          i += 2;
        } else {
          out += '\\x';
        }
      } else if (esc === 'u') {
        const hex = inner.substring(i, i + 4);
        if (/^[0-9a-fA-F]{4}$/.test(hex)) {
          out += String.fromCharCode(parseInt(hex, 16));
          i += 4;
        } else {
          out += '\\u';
        }
      } else if (esc === 'U') {
        const hex = inner.substring(i, i + 8);
        if (/^[0-9a-fA-F]{8}$/.test(hex)) {
          const cp = parseInt(hex, 16);
          if (cp <= 0x10ffff) {
            out += String.fromCodePoint(cp);
            i += 8;
          } else {
            out += '\\U';
          }
        } else {
          out += '\\U';
        }
      } else if (esc === '\n') {
        // 行尾折行：续行开头的缩进由下面的空白跳过逻辑处理
        while (i < inner.length && (inner.charAt(i) === ' ' || inner.charAt(i) === '\t')) {
          i += 1;
        }
      } else {
        // 未知转义：原样保留，绝不猜
        out += '\\' + esc;
      }
    }
    return out;
  }

  /**
   * 解码受限 YAML 标量。支持常见标量修饰符（`&anchor` / `!tag` / `|` `>` 块标量指示符）、
   * 单双引号与转义、`*alias` 别名、flow 序列/映射（`[h3]`、`{a: b}`，跨行会被折叠），
   * 以及行内注释。仅对**未闭合**的引号/集合与无法承载的块标量体抛 YamlNodeError。
   */
  private static decodeScalar(input: string): string {
    let value = YamlMerger.stripModifiers(input);
    if (value.length === 0) {
      return '';
    }
    if (value.charAt(0) === '*') {
      // 别名：命中锚点则递归解码其值；未命中 = 字段缺失（不是整条节点失败）。
      const target = YamlMerger.resolveAlias(value);
      if (target.length === 0) {
        return '';
      }
      return YamlMerger.decodeScalar(target);
    }
    if (value.charAt(0) === '|' || value.charAt(0) === '>') {
      // 块标量指示符：块体由缩进行承载，纯标量上下文里没有可用内容。
      if (/^[|>][0-9+-]*$/.test(value)) {
        return '';
      }
      value = value.substring(1).replace(/^[0-9+-]*/, '').trim();
      if (value.length === 0) {
        return '';
      }
    }
    const first = value.charAt(0);
    if (first === '[' || first === '{') {
      // flow 序列/映射：作为标量上下文时保留原始文本（alpn/ports 等按原文消费），
      // 跨行书写折叠为单空格；结构不平衡才是真的不可用。
      const close = YamlMerger.matchingClose(value, 0);
      if (close < 0) {
        throw new YamlNodeError('代理节点包含未闭合的 YAML 集合');
      }
      return value.substring(0, close + 1).replace(/[\r\n\t]+/g, ' ');
    }
    if (value.includes('\n') || value.includes('\r')) {
      throw new YamlNodeError('代理节点包含不受支持的 YAML 标量');
    }
    if (first === '"' || first === "'") {
      const close = YamlMerger.quotedClose(value, 0);
      if (close < 0) {
        throw new YamlNodeError('代理节点包含未闭合的 YAML 引号');
      }
      const inner = value.substring(1, close);
      if (first === "'") {
        return inner.replace(/''/g, "'");
      }
      return YamlMerger.unescapeDoubleQuoted(inner);
    }
    // 裸标量里的 " #" 之后是 YAML 行内注释, 截掉; 值本身含 '#'(如密码)则保留
    const commentIdx = value.indexOf(' #');
    if (commentIdx >= 0) {
      value = value.substring(0, commentIdx).trim();
    }
    // YAML 裸 null 归一化: 面板常把可选字段写成 `short-id: null` / `sni: ~` /
    // `password: null`（YAML 里这些是 null 值, 等价于「不填」）。此前把字面量
    // "null"/"~" 当字符串保留 → reality 的 short-id 变成非法 hex 被校验误杀、
    // 或 sni/password 被塞进 "null" 污染配置。引号形态的 "null" 在上面已原样
    // 返回, 不受影响(那是用户真实值)。
    if (value.length === 0 || value === '~'
      || value === 'null' || value === 'Null' || value === 'NULL') {
      return '';
    }
    return value;
  }

  /**
   * 解析受限 flow-map，并确保只有指定键；嵌套值仍由调用方按白名单解析。
   * 容器内的 `<<` 合并键（`{<<: *base, path: /x}`）会被展开，显式键优先。
   */
  private static parseRestrictedFlowMap(input: string, allowedKeys: Set<string>): Map<string, string> {
    const value = input.trim();
    if (!value.startsWith('{') || !value.endsWith('}')) {
      throw new YamlNodeError('代理节点嵌套字段必须使用合法 flow-map');
    }
    const result = new Map<string, string>();
    YamlMerger.applyRestrictedPairs(value.substring(1, value.length - 1), allowedKeys, result, false, 0);
    return result;
  }

  /**
   * 受限 flow-map 的键值收集（`<<` 合并键递归展开，最多 MAX_MERGE_DEPTH 层）。
   *
   * 第一遍收集显式键（重复键仍按结构错误上报，与既有语义一致），第二遍补 `<<` 继承来的
   * 缺失键 —— 显式键优先。合并键指向的锚点解析不了时按「未提供」降级（不抛错、不丢节点）；
   * 环形/超深的合并链在限深处停止，绝不递归失控。
   */
  private static applyRestrictedPairs(inner: string, allowedKeys: Set<string>,
    result: Map<string, string>, fillOnly: boolean, depth: number): void {
    if (depth > YamlMerger.MAX_MERGE_DEPTH) {
      return;
    }
    const merges: string[] = [];
    for (const pair of YamlMerger.splitFlowMap(inner)) {
      const idx = YamlMerger.findUnquotedColon(pair);
      if (idx <= 0) {
        if (fillOnly) {
          continue;
        }
        throw new YamlNodeError('代理节点嵌套 flow-map 字段格式无效');
      }
      const key = YamlMerger.decodeScalar(pair.substring(0, idx));
      if (key === '<<') {
        merges.push(pair.substring(idx + 1).trim());
        continue;
      }
      // 真实面板会在嵌套结构里附带扩展键（reality-opts._spider-x、
      // ws-opts.v2ray-http-upgrade、grpc-opts.* 等）。未知键必须逐项忽略，
      // 一旦抛错就会让调用方丢弃整段嵌套配置 —— 典型后果是 REALITY 的
      // public-key/short-id 全部丢失，内核退化成普通 TLS 并握手失败。
      if (!allowedKeys.has(key)) {
        continue;
      }
      if (result.has(key)) {
        if (fillOnly) {
          continue;
        }
        throw new YamlNodeError(`代理节点包含重复嵌套字段：${key}`);
      }
      result.set(key, pair.substring(idx + 1).trim());
    }
    for (const mergeRaw of merges) {
      for (const target of YamlMerger.mergeTargetMaps(mergeRaw, depth)) {
        const close = YamlMerger.matchingClose(target, 0);
        if (close < 0) {
          continue;
        }
        YamlMerger.applyRestrictedPairs(target.substring(1, close), allowedKeys, result,
          true, depth + 1);
      }
    }
  }

  /** `<<: *a` / `<<: [*a, *b]` / `<<: {..}` → 目标映射文本列表（别名链限深解引用）。 */
  private static mergeTargetMaps(raw: string, depth: number): string[] {
    const out: string[] = [];
    if (depth > YamlMerger.MAX_MERGE_DEPTH) {
      return out;
    }
    const value = raw.trim();
    if (value.length === 0) {
      return out;
    }
    if (value.charAt(0) === '[') {
      const close = YamlMerger.matchingClose(value, 0);
      if (close < 0) {
        return out;
      }
      for (const item of YamlMerger.splitTopLevel(value.substring(1, close), ',')) {
        for (const target of YamlMerger.mergeTargetMaps(item, depth + 1)) {
          out.push(target);
        }
      }
      return out;
    }
    if (value.charAt(0) === '*') {
      const resolved = YamlMerger.resolveAliasDepth(value, 0, new Set<string>());
      if (resolved.length === 0) {
        return out;
      }
      for (const target of YamlMerger.mergeTargetMaps(resolved, depth + 1)) {
        out.push(target);
      }
      return out;
    }
    if (value.charAt(0) === '{') {
      out.push(value);
    }
    return out;
  }

  /** 行有效缩进 = 前导空格数 + (`- ` 占 2 列, 列表项键位右移)。块式嵌套判定用。 */
  private static lineIndent(line: string): number {
    const trimmed = line.trimStart();
    const lead = line.length - trimmed.length;
    return trimmed.startsWith('- ') ? lead + 2 : lead;
  }

  /**
   * 块标量头部判定：`|` / `>` 后只允许缩进指示符(1-9)、裁剪指示符(-/+)与行内注释。
   * `password: |` / `password: >-` / `plugin: |2` 都算块标量头；`name: |x` 不算。
   */
  private static isBlockScalarHeader(raw: string): boolean {
    const v = raw.trim();
    if (v.length === 0 || (v.charAt(0) !== '|' && v.charAt(0) !== '>')) {
      return false;
    }
    const hash = v.indexOf('#');
    const head = (hash >= 0 ? v.substring(0, hash) : v).trim();
    return (head.charAt(0) === '|' || head.charAt(0) === '>')
      && /^[|>]([1-9]?[+-]?|[+-]?[1-9]?)$/.test(head);
  }

  /**
   * 抽取块标量体（`key: |` / `key: >` 后面按缩进承载的多行内容）。
   *
   * - 内容缩进：显式数字指示符优先（父级缩进 + N），否则取块体首个非空行的缩进；
   * - `|` 保留换行（literal），`>` 把普通换行折叠成空格、空行折叠成换行（folded）；
   * - 裁剪指示符 `-`(strip) / `+`(keep) / 默认(clip) 的差别只体现在**尾部换行**上，
   *   而本解析器的字段链路是单行标量，因此尾部空白统一裁掉（不产生假的换行值）；
   * - 块体为空（没有更深的行 / 内容缩进不比键深）返回 ''，由调用方按「字段缺失」计入 invalid。
   *
   * 绝不抛错：任何异常都退化为空串，不会因为一个块标量丢掉整条节点。
   */
  private static blockScalarBody(lines: string[], headerIndex: number, header: string): string {
    if (headerIndex < 0 || headerIndex >= lines.length) {
      return '';
    }
    const headerLine = lines[headerIndex];
    const headerTrimmed = headerLine.trimStart();
    const lead = headerLine.length - headerTrimmed.length;
    const parentIndent = headerTrimmed.startsWith('- ') ? lead + 2 : lead;
    const hash = header.indexOf('#');
    const head = (hash >= 0 ? header.substring(0, hash) : header).trim();
    const style = head.charAt(0);
    const digitMatch = head.match(/[1-9]/);
    const explicitIndent = digitMatch === null ? -1 : parseInt(digitMatch[0], 10);
    const body: string[] = [];
    for (let j = headerIndex + 1; j < lines.length; j++) {
      const raw = lines[j];
      const t = raw.trimStart();
      if (t.length === 0) {
        body.push('');
        continue;
      }
      const indent = raw.length - t.length;
      if (indent <= parentIndent) {
        break;
      }
      body.push(raw);
    }
    let last = body.length;
    while (last > 0 && body[last - 1].trim().length === 0) {
      last = last - 1;
    }
    const meaningful = body.slice(0, last);
    if (meaningful.length === 0) {
      return '';
    }
    let contentIndent = explicitIndent > 0 ? parentIndent + explicitIndent : -1;
    if (contentIndent < 0) {
      for (const raw of meaningful) {
        const t = raw.trimStart();
        if (t.length === 0) {
          continue;
        }
        contentIndent = raw.length - t.length;
        break;
      }
    }
    if (contentIndent <= parentIndent) {
      return '';
    }
    const content: string[] = [];
    for (const raw of meaningful) {
      const t = raw.trimStart();
      if (t.length === 0) {
        content.push('');
        continue;
      }
      const indent = raw.length - t.length;
      const cut = indent > contentIndent ? contentIndent : indent;
      content.push(raw.substring(cut));
    }
    let value = '';
    if (style === '|') {
      value = content.join('\n');
    } else {
      // `>` 折叠：连续普通行之间是空格，空行折算成换行
      let pending = 0;
      for (const line of content) {
        if (line.length === 0) {
          pending = pending + 1;
          continue;
        }
        if (value.length === 0) {
          value = line;
          pending = 0;
          continue;
        }
        if (pending > 0) {
          for (let k = 0; k < pending; k++) {
            value += '\n';
          }
        } else {
          value += ' ';
        }
        value += line;
        pending = 0;
      }
    }
    // 尾部空白（换行/空格）不进入单行字段链路：clip/strip/keep 在此归一
    return value.replace(/[ \t]+$/, '').replace(/[\r\n]+$/, '');
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
    itemLines: string[], extras: string[][]): void {
    // ws-opts 的高级子键（路径/Host 之外）：max-early-data、early-data-header-name、
    // v2ray-http-upgrade(+fast-open)。丢失会导致 early-data/v2ray upgrade 模式节点
    // 在内核侧退化为普通 WS 甚至不可用 —— 以 `ws-opts.<key>` 形式存 extras，
    // 生成端把它们合并回 ws-opts 结构。
    const wsExtraKeys = new Set<string>(['max-early-data', 'early-data-header-name',
      'v2ray-http-upgrade', 'v2ray-http-upgrade-fast-open']);
    const pushWsExtra = (k: string, v: string): void => {
      const value = v.trim();
      if (value.length === 0 || value.length > 512 || value.includes('\n') || value.includes('\r')) {
        return;
      }
      for (const pair of extras) {
        if (pair[0] === 'ws-opts.' + k) {
          return;
        }
      }
      extras.push(['ws-opts.' + k, value]);
    };
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
        const ws = YamlMerger.parseRestrictedFlowMap(wsFlow,
          new Set<string>(['path', 'headers', 'max-early-data', 'early-data-header-name',
            'v2ray-http-upgrade', 'v2ray-http-upgrade-fast-open']));
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
        for (const ek of wsExtraKeys) {
          const ev = ws.get(ek);
          if (ev !== undefined) {
            pushWsExtra(ek, ev);
          }
        }
      } catch (e) {
        // 结构异常按「未提供」降级
      }
    }
    const wsBlock = YamlMerger.extractBlockBody(itemLines, 'ws-opts');
    if (wsBlock.length > 0) {
      if (p.wsPath.length === 0 && p.wsHost.length === 0) {
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
      // 块式 ws-opts 的高级子键同样保全（与 flow 来源幂等：先到先得）
      try {
        const wsExtra = YamlMerger.parseSimpleBlock(wsBlock, wsExtraKeys);
        for (const ek of wsExtraKeys) {
          const ev = wsExtra.get(ek);
          if (ev !== undefined) {
            pushWsExtra(ek, ev);
          }
        }
      } catch (e) {
        // 结构异常按「未提供」降级
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
      // 单字段超限只跳过这条节点（计 invalid + 限额统计），不能因一条脏节点让整批导入失败。
      throw YamlMerger.limitNodeError(`订阅字段 ${fieldName} 长度超过上限 (64KB)，已跳过该节点`);
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

  /**
   * 有独立结构化槽位的协议。注意不能反过来用 isRelayType 判定「无结构化槽位」:
   * isRelayType 为「订阅升级后未知协议也不丢」对任意合法小写类型都放行(见下方正则),
   * 因此它对 vless/vmess/ss/ssr/trojan/hysteria2 同样返回 true。若据此启用中继透传,
   * 这些协议的 uuid/password/cipher/reality-opts 等会整批进入 extraOpts、结构化槽位为空,
   * 随后「缺少 uuid / 缺少 password / 缺少 cipher」的必需字段校验会把整条节点判错丢弃。
   */
  private static readonly STRUCTURED_TYPES: Set<string> = new Set<string>([
    'ss', 'ssr', 'vless', 'vmess', 'trojan', 'hysteria2',
    // anytls 同样有独立结构化槽位（password/sni/tls/skip-cert-verify）。若不列入，
    // 它会走 isRelayType 的中继透传分支 —— 该分支只保留 name/type/server/port 四个
    // 核心字段，password/sni 落进 extraOpts，ProxyNode.password 为空，随后
    // ClashConfigGenerator.dropReasonFor 把整批判为「缺必需字段：凭据缺失」丢弃
    // （真机实证：某订阅 36 个 anytls 全部丢失，测速全部 404「Resource not found」，
    // UI 表现为「全部超时/失败」，而节点实际可用）。
    'anytls'
  ]);

  /** 支持 alpn 的协议 (ss/ssr 不支持 alpn 键) */
  private static readonly ALPN_TYPES: Set<string> = new Set<string>([
    'vless', 'vmess', 'trojan', 'hysteria2', 'hysteria', 'tuic', 'anytls'
  ]);

  /**
   * 中继透传（relayMode）下**额外回填**到结构化槽位的键。
   *
   * 中继分支默认只保留 name/type/server/port 四个核心字段，其余键原样进 extraOpts。
   * 但「凭据类」键如果只留在 extraOpts，ProxyNode 的结构化槽位就是空的，而
   * ClashConfigGenerator.dropReasonFor 按**结构化槽位**判定内核必填字段
   * （`has unset fields:password` 会让整份配置起不来），于是整批节点被丢弃、
   * 内核代理表里没有它们、测速全部 404「Resource not found」。
   *
   * 回填只**增加**结构化槽位的值，extraOpts 里的原键仍保留（生成时
   * 「与已输出键重名以结构化字段为准」，不会重复输出；未被结构化覆盖的键
   * 仍原样透传）。口径与 URI 导入路径完全一致（见 ProxyNode.parseHysteria /
   * parseTuic：口令进 password 槽，hysteria v1 的 auth-str 同样进 password 槽，
   * up/down 进 hyUp/hyDown）。
   *
   * 注意 `token` **不**在此表：tuic v5 的凭据键是 token，回填到 password 槽会让
   * 生成端输出 `password:` 而内核 v5 只认 token → 反而生成非法配置。
   * tuic v5 的 token 保持透传，由 dropReasonFor 查 extraOpts 判定。
   */
  private static readonly RELAY_CREDENTIAL_SLOTS: Map<string, string> = new Map<string, string>([
    ['password', 'password'],
    ['uuid', 'uuid'],
    // hysteria v1 的凭据键（mihomo 用 auth-str/auth_str，订阅里也常见 auth）
    ['auth-str', 'password'],
    ['auth_str', 'password'],
    ['auth', 'password'],
    // 带宽（hysteria/hysteria2）
    ['up', 'up'],
    ['upmbps', 'up'],
    ['down', 'down'],
    ['downmbps', 'down'],
    // hysteria v1 的传输协议（udp/wechat-video/faketcp）——不是凭据，但归一化槽位
    ['protocol', 'protocol']
  ]);

  /**
   * 允许回填「口令/uuid」槽位的中继协议。
   *
   * 只有**有认证概念**的协议才回填：tuic(v4 uuid+password)、hysteria(v1 auth-str)、
   * http/socks5(代理认证)、naive、anytls。snell 用 psk、wireguard/mieru/ssh
   * 没有口令概念，回填只会给生成端塞一个内核不认的 password 键。
   *
   * ⚠⚠ **回填是按「类型字符串精确匹配」做的**（`RELAY_CREDENTIAL_TYPES.has(type)`），
   * **不做任何同族推断**。原文这里写的是「naive(anytls 同族)」—— 作者以为 naive 已经
   * 覆盖了 anytls，可 `anytls` ≠ `naive`，精确匹配匹配不上 ⇒ anytls 的 password
   * **只进 extraOpts、不回填结构化槽** ⇒ ProxyNode.password 为空 ⇒
   * ClashConfigGenerator.dropReasonFor 判「缺必需字段：凭据缺失」把**整批**节点丢弃 ⇒
   * 节点不在内核 `proxies:` 段 ⇒ REST `/proxies/{name}/delay` 返回 404 ⇒ 测速全红。
   * **真机实证：某订阅 36 个 anytls 全部丢失，而节点实际可用、代理正常。**
   * ⇒ 结论（后人务必记住）：本表**必须逐个类型显式列出**，
   * 「看着像同族」绝不能作为不列出的理由。
   *
   * 附注（当前 HEAD 状态，2026-10-20 逐行核实）：`anytls` 同时列在下面的
   * `STRUCTURED_TYPES` 里 ⇒ `relayMode = isRelayType('anytls') && !hasStructuredSlots('anytls')`
   * 为 false ⇒ anytls 走**结构化白名单**路径，本闸门当前**不命中**。
   * 但本表条目是**防回归的兜底**：一旦 anytls 被移出 STRUCTURED_TYPES（改回中继透传），
   * 这里就能把 password 救回结构化槽，而不是重演「36 个 anytls 全丢」。
   * ⇒ 结论不变：anytls **必须**在本表里显式列出。
   */
  private static readonly RELAY_CREDENTIAL_TYPES: Set<string> = new Set<string>([
    'tuic', 'hysteria', 'http', 'socks5', 'naive', 'anytls'
  ]);

  /**
   * 允许回填「带宽/传输协议」槽位的中继协议。
   *
   * hysteria v1 的 `protocol` 是**传输协议**（udp/wechat-video/faketcp），
   * 不是 hysteria2 那种混淆协议；`up`/`down` 是带宽。放在独立表里，
   * 避免把 hysteria2 的 obfs 语义套到 v1 上。
   */
  private static readonly RELAY_BANDWIDTH_TYPES: Set<string> = new Set<string>([
    'hysteria'
  ]);

  /** 本轮解析因「协议不支持/缺关键字段」被跳过的节点统计, 供上层提示用户 */
  static lastSkippedCount: number = 0;
  static lastSkippedTypes: string = '';

  /**
   * 本轮解析因「缺少/非法必需字段」被拒绝的节点统计(用户可见), 供上层提示用户。
   * parseProxyItem 抛出 YamlNodeError 时逐条登记; resetSkipStats() 一并重置。
   */
  static lastInvalidCount: number = 0;
  static lastInvalidReasons: string[] = [];

  /**
   * 本轮因**单节点/单字段限额**被跳过的节点数(用户可见)。
   *
   * 语义: 这些节点也计入 lastInvalidCount(它们确实是「没进来的节点」), 但原因是限额而不是
   * 内容格式, 所以单独再给一份统计 —— 上层可以提示「N 条因超过单节点/单字段限额被跳过」,
   * 而不是笼统报「解析失败」。全局限额(节点总数/来源数/输出体积)仍然抛 YamlMergeError。
   */
  static lastLimitSkippedCount: number = 0;
  /** 单节点/单字段限额跳过原因(中文, 去重, 最多 12 条) */
  static lastLimitSkippedReasons: string[] = [];

  /**
   * dialer-proxy(mihomo 中继依赖)诊断, 供上层读取:
   * - lastDialerProxyMissing: 依赖指向本次导入节点列表里不存在的名称数(字段保留, 只诊断);
   * - lastDialerProxyBroken: 检测到依赖环(含自环)并已移除环上依赖的节点数;
   * - lastDialerProxyReasons: 上述情况的中文说明(去重, 最多 12 条)。
   */
  static lastDialerProxyMissing: number = 0;
  static lastDialerProxyBroken: number = 0;
  static lastDialerProxyReasons: string[] = [];

  /**
   * flow-map 节点内**重复键**的诊断（用户可见）。
   *
   * 背景：mihomo 用 go.yaml.in/yaml/v3 v3.0.5，`uniqueKeys` **默认开启**
   * （decode.go:344）：同层级重复键 = TypeError = **整份配置拒载**（全有全无：
   * 一个节点坏 → 整个 VPN 起不来）。而 rawTemplate 是**逐字**保留订阅 flow-map 原文的，
   * 订阅里写了 `cipher: aes-256-gcm, cipher: aes-128-gcm` 就会原样进产物 → 拒载。
   * 触发面很宽：各类「转换器/聚合面板」生成的订阅极常见，用户**不需要做任何事**。
   *
   * 降级规则（**必须显式化**）：重复键**保留首次出现**的那一对。这是**产品策略**，
   * **不代表第一个值正确** —— 所以必须同时留下诊断，让上层/日志能看见「这个节点有重复键、
   * 已按首个保留」，而不是静默改掉订阅语义。
   *
   * 诊断通道选择：**本文件的静态统计机制**（与 lastInvalidCount / lastInvalidReasons /
   * lastSkippedCount / lastLimitSkippedCount 同款），**不**在 MergedProxy 上加字段 ——
   * MergedProxy 会被持久化（见 SubscriptionService），加字段会牵动持久化格式；
   * 而「解析期统计」本就是本文件的既有惯例（上层通过 resetSkipStats + 这些静态量读取）。
   *
   * 语义：lastDuplicateKeyCount = **受影响节点数**（不是被去重的键数）。
   */
  static lastDuplicateKeyCount: number = 0;
  /** 重复键降级明细（中文，去重，最多 12 条） */
  static lastDuplicateKeyReasons: string[] = [];

  static resetSkipStats(): void {
    YamlMerger.lastSkippedCount = 0;
    YamlMerger.lastSkippedTypes = '';
    YamlMerger.lastInvalidCount = 0;
    YamlMerger.lastInvalidReasons = [];
    YamlMerger.lastLimitSkippedCount = 0;
    YamlMerger.lastLimitSkippedReasons = [];
    YamlMerger.lastDialerProxyMissing = 0;
    YamlMerger.lastDialerProxyBroken = 0;
    YamlMerger.lastDialerProxyReasons = [];
    YamlMerger.lastDuplicateKeyCount = 0;
    YamlMerger.lastDuplicateKeyReasons = [];
  }

  /** 登记一个因单节点/单字段限额被跳过的节点(计数 + 去重原因, 最多 12 条) */
  static noteLimitSkip(reason: string): void {
    YamlMerger.lastLimitSkippedCount = YamlMerger.lastLimitSkippedCount + 1;
    const text = reason.length > 80 ? reason.substring(0, 80) : reason;
    if (text.length === 0 || YamlMerger.lastLimitSkippedReasons.length >= 12) {
      return;
    }
    for (const it of YamlMerger.lastLimitSkippedReasons) {
      if (it === text) {
        return;
      }
    }
    YamlMerger.lastLimitSkippedReasons.push(text);
  }

  /**
   * 单节点/单字段超限: 只跳过这一个节点(计 invalid + 限额统计), 不抛全局限额错误,
   * 因此一条畸形节点永远不会让整批订阅导入失败。
   */
  private static limitNodeError(reason: string): YamlNodeError {
    YamlMerger.noteLimitSkip(reason);
    return YamlMerger.invalidNode(reason);
  }

  /** 登记一条 dialer-proxy 依赖诊断(去重, 最多 12 条) */
  static noteDialerReason(reason: string): void {
    const text = reason.length > 80 ? reason.substring(0, 80) : reason;
    if (text.length === 0 || YamlMerger.lastDialerProxyReasons.length >= 12) {
      return;
    }
    for (const it of YamlMerger.lastDialerProxyReasons) {
      if (it === text) {
        return;
      }
    }
    YamlMerger.lastDialerProxyReasons.push(text);
  }

  /** 登记一个因缺少/非法必需字段(或结构错误)被拒绝的节点: 计数 + 去重理由(最多 12 条) */
  private static noteInvalid(reason: string): void {
    YamlMerger.lastInvalidCount = YamlMerger.lastInvalidCount + 1;
    const text = reason.length > 80 ? reason.substring(0, 80) : reason;
    if (text.length === 0 || YamlMerger.lastInvalidReasons.length >= 12) {
      return;
    }
    for (const it of YamlMerger.lastInvalidReasons) {
      if (it === text) {
        return;
      }
    }
    YamlMerger.lastInvalidReasons.push(text);
  }

  /** 构造「缺少/非法必需字段」的节点错误并登记用户可见原因。 */
  private static invalidNode(reason: string): YamlNodeError {
    YamlMerger.noteInvalid(reason);
    return new YamlNodeError(reason);
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

  /** 该协议是否有结构化槽位: 有则必须走白名单结构化解析, 禁止中继透传 */
  static hasStructuredSlots(type: string): boolean {
    return YamlMerger.STRUCTURED_TYPES.has(type.trim().toLowerCase());
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
    // anytls 的内核选项只认 sni 键（AnytlsOption.SNI tag: proxy:"sni"），
    // 写成 servername 会被丢弃，TLS Host 回退用 server 地址，与证书不匹配时全部超时。
    return t === 'hysteria2' || t === 'hysteria' || t === 'tuic' || t === 'anytls';
  }

  /** 预读条目声明的 type(键顺序不定, 结构化映射前先判定是否走中继) */
  private static peekType(text: string): string {
    // 类型名允许 `-`/`.`(future-quic、hy2-legacy 等未来协议), 否则会被截断成前缀,
    // 让 relayMode 判定落到错误的协议分支上。
    const m = text.match(/(?:^|[\s,{-])type\s*:\s*["']?([A-Za-z][A-Za-z0-9._-]{0,31})/);
    return m === null ? '' : m[1].toLowerCase();
  }

  /**
   * 白名单外额外字段捕获: 键名受限、值长度受限、禁止换行与注释符; 容器值({...}/[...])
   * 必须括号平衡且仅含安全字符 —— 防止破坏 flow-map 结构或注入额外配置行。
   * 非法时返回 null(仅丢该键, 绝不影响节点其余部分)。
   */
  /** 额外字段键必须是普通 Mihomo 键（含 auth_str 等下划线键），并拒绝原型污染保留名。 */
  static isSafeExtraKey(key: string): boolean {
    return /^[a-z][a-z0-9_-]{0,63}$/.test(key)
      && key !== '__proto__' && key !== 'prototype' && key !== 'constructor';
  }

  private static captureExtraOpt(key: string, rawValue: string): string | null {
    if (!YamlMerger.isSafeExtraKey(key)) {
      return null;
    }
    const raw = rawValue.trim();
    // 512 → 8192: 面板生成的 xhttp-opts（XHTTP 传输）普遍 600+ 字符且含嵌套
    // reuse-settings，512 上限会把整批 XHTTP 节点静默降级成「无传输参数」，
    // 在内核侧表现为测速全部超时。流式结构(大括号)走下方深度+字符集校验，
    // 下游 validateNodeText 仍有 64KB 兜底。
    if (raw.length === 0 || raw.length > 8192 || raw.includes('\n') || raw.includes('\r')
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
        } else if (!/[A-Za-z0-9_ \t.,:\/=\-+"'();%<>!@^&*?~]/.test(c)) {
          // 白名单需覆盖真实面板值: http 中转节点的 headers 里
          // User-Agent 含 '(' ')' ';' '%' (如 'Dalvik/2.1.0 (Linux; U; Android 9; ...)'),
          // Host 含 ':'。曾因白名单过窄把整个 headers 键静默丢弃 →
          // 中转鉴权头丢失 → 依赖该中转的全部节点拨号瞬间失败。
          // '#' 仍拒绝(注释符), 换行/控制字符仍拒绝, 大括号走深度校验。
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

  /** dialer-proxy（mihomo/clash 的「通过哪个节点拨号」依赖）键名 */
  private static readonly DIALER_PROXY_KEY: string = 'dialer-proxy';

  /**
   * 读取节点的 dialer-proxy 依赖名。
   *
   * 该键不是本客户端的结构化槽位（不同内核版本对它的取值规则不同），因此与其它客户端一致
   * 按原样保留在 extraOpts 里回写配置；这里只做读取与依赖校验。
   */
  static dialerProxyTarget(p: MergedProxy): string {
    for (const pair of YamlMerger.parseExtraOpts(p.extraOpts)) {
      if (pair[0] === YamlMerger.DIALER_PROXY_KEY) {
        return pair[1];
      }
    }
    return '';
  }

  /** 从 extraOpts(JSON 数组) 里移除一个键; 结构异常时原样返回(不破坏其它键) */
  private static dropExtraOpt(extraOpts: string, key: string): string {
    const kept: string[][] = [];
    let removed = false;
    for (const pair of YamlMerger.parseExtraOpts(extraOpts)) {
      if (pair[0] === key) {
        removed = true;
        continue;
      }
      kept.push(pair);
    }
    if (!removed) {
      return extraOpts;
    }
    return kept.length > 0 ? JSON.stringify(kept) : '';
  }

  /**
   * dialer-proxy 依赖校验（节点级，绝不影响其它节点，也不死循环）：
   *
   * 1) 指向本次导入列表里不存在的节点名 → **保留字段**并给出明确诊断
   *    （lastDialerProxyMissing + lastDialerProxyReasons）。目标可能来自没导入的
   *    proxy-provider 或外部配置，直接删掉反而改变用户配置。
   * 2) 依赖成环（A→B→A、自环）→ **打破环**：移除环上节点的 dialer-proxy 并计入
   *    lastDialerProxyBroken。环会让内核反复互相拨号，必须在生成配置前打破。
   *
   * 依赖链遍历有界（每个节点最多入栈一次，环立即收敛），不会死循环。
   */
  private static resolveDialerProxyDependencies(proxies: MergedProxy[]): void {
    if (proxies.length === 0) {
      return;
    }
    const names = new Set<string>();
    const indexByName = new Map<string, number>();
    for (let i = 0; i < proxies.length; i++) {
      names.add(proxies[i].name);
      if (!indexByName.has(proxies[i].name)) {
        indexByName.set(proxies[i].name, i);
      }
    }
    const targets: string[] = [];
    for (const p of proxies) {
      const target = YamlMerger.dialerProxyTarget(p);
      targets.push(target);
      if (target.length === 0 || names.has(target)) {
        continue;
      }
      YamlMerger.lastDialerProxyMissing = YamlMerger.lastDialerProxyMissing + 1;
      YamlMerger.noteDialerReason(`dialer-proxy 指向的节点「${target}」不在本次导入的节点列表里`
        + `（字段已保留，内核可能忽略该依赖）`);
    }
    const broken = new Set<number>();
    for (let i = 0; i < proxies.length; i++) {
      if (targets[i].length === 0 || broken.has(i)) {
        continue;
      }
      const path: number[] = [];
      const seenAt = new Map<number, number>();
      let cur = i;
      while (cur >= 0) {
        if (seenAt.has(cur)) {
          // 回到路径上的节点 = 环: 只打破环本身的成员（进入环之前的链保持原样）
          const start = seenAt.get(cur);
          if (start !== undefined) {
            for (let k = start; k < path.length; k++) {
              broken.add(path[k]);
            }
          }
          break;
        }
        if (targets[cur].length === 0) {
          break;
        }
        const next = indexByName.get(targets[cur]);
        if (next === undefined) {
          break; // 目标不在列表里（上面已经诊断过）
        }
        seenAt.set(cur, path.length);
        path.push(cur);
        cur = next;
      }
    }
    if (broken.size === 0) {
      return;
    }
    YamlMerger.lastDialerProxyBroken = YamlMerger.lastDialerProxyBroken + broken.size;
    YamlMerger.noteDialerReason(`dialer-proxy 依赖成环 ${broken.size} 个节点，`
      + '已移除环上依赖以避免内核反复互相拨号');
    for (const idx of Array.from(broken)) {
      proxies[idx].extraOpts = YamlMerger.dropExtraOpt(
        proxies[idx].extraOpts, YamlMerger.DIALER_PROXY_KEY);
    }
  }

  /**
   * 统一处理一个 key/value 对(flow-map 与块式两种写法共用):
   * - 中继协议: 核心四字段入 fields, 其余全部键值经校验后进 extras(原样透传);
   * - 结构化协议: 白名单键入 fields, 白名单外的安全键进 extras(不静默丢弃)。
   */
  private static applyPair(key: string, rawValue: string, relayMode: boolean,
    supportedKeys: Set<string>, fields: Map<string, string>, extras: string[][],
    extraSeen: Set<string>, type: string = ''): void {
    // `*alias` 别名先解引用: 命中锚点则用锚点原始值继续解析, 未命中等价于「字段缺失」。
    const value = YamlMerger.resolveAlias(rawValue);
    if (relayMode) {
      if (key === 'name' || key === 'type' || key === 'server' || key === 'port') {
        try {
          fields.set(key, YamlMerger.decodeScalar(value));
        } catch (e) {
          // 核心字段无法解析: 交由后续必需字段校验拒绝该节点
        }
      } else {
        // 凭据/带宽类键**额外**回填结构化槽位：只放进 extraOpts 时 ProxyNode 的
        // password/uuid/hyUp/hyDown 为空，dropReasonFor 会把整批判为「缺凭据」
        // 丢弃（内核里根本没有这些节点 → 测速全部 404）。原键仍保留在 extraOpts，
        // 生成时「重名以结构化字段为准」不会重复输出。
        // 回填**按协议限定**：只有真的有认证/带宽概念的协议才回填，
        // 免得给 snell/wireguard 这类塞一个内核不认的键。
        const normalizedType = type.trim().toLowerCase();
        if (YamlMerger.RELAY_CREDENTIAL_TYPES.has(normalizedType)) {
          if (key === 'password' || key === 'uuid') {
            if (!fields.has(key)) {
              try {
                fields.set(key, YamlMerger.decodeScalar(value));
              } catch (e) {
                // 值解析失败: 留空，由后续必需字段校验按「缺凭据」处理
              }
            }
          }
        }
        if (YamlMerger.RELAY_BANDWIDTH_TYPES.has(normalizedType)) {
          if (key === 'auth-str' || key === 'auth_str' || key === 'auth') {
            if (!fields.has('password')) {
              try {
                fields.set('password', YamlMerger.decodeScalar(value));
              } catch (e) {
                // 同上
              }
            }
          } else if (key === 'up' || key === 'upmbps' || key === 'down'
            || key === 'downmbps' || key === 'protocol') {
            const slot = YamlMerger.RELAY_CREDENTIAL_SLOTS.get(key);
            if (slot !== undefined && !fields.has(slot)) {
              try {
                fields.set(slot, YamlMerger.decodeScalar(value));
              } catch (e) {
                // 同上
              }
            }
          }
        }
        const captured = YamlMerger.captureExtraOpt(key, value);
        if (captured !== null) {
          extraSeen.add(key);
          extras.push([key, captured]);
        }
      }
      return;
    }
    if (!supportedKeys.has(key)) {
      const captured = YamlMerger.captureExtraOpt(key, value);
      if (captured !== null) {
        extraSeen.add(key);
        extras.push([key, captured]);
      }
      return;
    }
    if (key === 'reality-opts' || key === 'ws-opts' || key === 'grpc-opts' || key === 'alpn') {
      fields.set(key, value);
    } else {
      try {
        fields.set(key, YamlMerger.decodeScalar(value));
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
      // 单条 128KB 超限: 只跳过这一条(计 invalid + 限额统计)。历史上这里抛 YamlMergeError,
      // 会让整个订阅因一条脏数据直接判「合并超限/解析失败」。
      throw YamlMerger.limitNodeError('单个节点内容大小超过上限 (128KB)，已跳过该节点');
    }
    // YAML 注释行与空行属于语法噪声, 不是节点内容: proxies 节内的顶层 `# ...` 注释
    // 会被归并到上一条目的行组尾部。若它参与 flow-map 闭合判定, 上一条节点就会因
    // 尾随注释被判成"未闭合"而整条丢弃 —— 节点去留不能由注释决定。
    const contentLines: string[] = [];
    for (const l of itemLines) {
      const t = l.trim();
      if (t.length === 0 || t.startsWith('#')) {
        continue;
      }
      contentLines.push(l);
    }
    const contentText = contentLines.length > 0 ? contentLines.join('\n').trim() : text;
    const parseLines = contentLines.length > 0 ? contentLines : itemLines;
    const fields = new Map<string, string>();
    const extras: string[][] = [];
    const extraSeen = new Set<string>();
    const mergeValues: string[] = [];
    // 中继协议(tuic/hysteria/http/socks5/...)无结构化槽位: 除核心四字段外全部原样透传,
    // 避免键名映射差异(如 sni/servername、obfs-password)让 mihomo 收到错误的键。
    // 判定必须排除有结构化槽位的协议(ss/ssr/vless/vmess/trojan/hysteria2):
    // isRelayType 对任意合法小写类型都返回 true, 直接使用会让这些协议也走中继透传,
    // uuid/password/cipher/reality-opts 全部落进 extraOpts, 结构化槽位为空,
    // 随后必需字段校验把它们整批判为「缺少 uuid / 缺少 password」而丢弃。
    const declaredType = YamlMerger.peekType(text);
    const relayMode = YamlMerger.isRelayType(declaredType)
      && !YamlMerger.hasStructuredSlots(declaredType);
    const supportedKeys = new Set<string>([
      'name', 'type', 'server', 'port', 'cipher', 'password',
      'protocol', 'protocol-param', 'protocol_param', 'obfs', 'obfs-param', 'obfs_param',
      'uuid', 'alterId', 'alter-id', 'udp', 'network', 'tls', 'servername', 'sni',
      'skip-cert-verify', 'flow', 'client-fingerprint', 'reality-opts', 'ws-opts', 'grpc-opts',
      'up', 'down', 'upmbps', 'downmbps', 'alpn', 'obfs-password', 'fingerprint',
      // 部分面板不用 ws-opts 嵌套, 而是把 WS 参数平铺为顶层别名
      'ws-path', 'ws-host', 'ws-headers'
    ]);
    let body = contentText.startsWith('- ') ? contentText.substring(2) : contentText;
    // `- &anchor {..}` / `- !!map {..}`: 先剥离前导锚点/标签修饰符再判定写法。
    body = YamlMerger.stripModifiers(body);
    // flow-map 原文（用于生成逐字模板）；块式写法保持 null → 回退结构化生成。
    let flowInner: string | null = null;
    try {
      if (body.trimStart().startsWith('{')) {
        const trimmedBody = body.trim();
        const open = trimmedBody.indexOf('{');
        const close = YamlMerger.matchingClose(trimmedBody, open);
        if (close < 0) {
          throw new YamlNodeError('代理节点 flow-map 未闭合');
        }
        // 只取**第一个闭合** flow-map 的内容: 跨行书写的 flow-map 会被完整拼合,
        // 其后的行内注释与挂在本条目行组尾部的噪声行一律忽略 —— 节点去留不能由它们决定。
        const content = trimmedBody.substring(open + 1, close);
        flowInner = content;
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
          if (key.length === 0) {
            continue;
          }
          if (key === '<<') {
            mergeValues.push(pair.substring(idx + 1).trim());
            continue;
          }
          // 重复键忽略; 白名单外的安全键不再丢弃, 而是进入 extraOpts 中继。
          if (fields.has(key) || extraSeen.has(key)) {
            continue;
          }
          YamlMerger.applyPair(key, pair.substring(idx + 1).trim(), relayMode, supportedKeys,
            fields, extras, extraSeen, declaredType);
        }
      } else {
        // 块式条目: 只有条目自身层级(`- ` 行及其同级键)的行参与字段解析。缩进更深的
        // 子键(ws-opts/reality-opts/grpc-opts/smux/headers 后的 path/Host/...)属于
        // 上级键的嵌套值, 由 nestedValueOf 合成 flow 结构 —— 历史缺陷是它们被当成
        // 顶层键, 于是 `path:` 以额外字段身份漏到生成的配置里。
        //
        // 基准缩进有两种形态:
        //  - `- name: x` + 同级键(缩进相同) → 基准 = `- ` 行缩进;
        //  - 裸 `-` 单独一行 + 更深缩进的键(块式序列, mitce v2Net 等面板)→
        //    基准必须取**首个键行**的缩进, 否则所有键都被当成"缩进子键"跳过,
        //    节点因缺 name/type/server 被整条丢弃。
        let baseIndent = YamlMerger.lineIndent(parseLines[0]);
        if (parseLines[0].trim() === '-') {
          for (let bi = 1; bi < parseLines.length; bi++) {
            const bl = parseLines[bi];
            if (bl.trim().length === 0 || bl.trim().startsWith('#')) {
              continue;
            }
            baseIndent = YamlMerger.lineIndent(bl);
            break;
          }
        }
        for (let li = 0; li < parseLines.length; li++) {
          const line = parseLines[li];
          const t = line.trim().replace(/^- /, '');
          if (t.length === 0 || t === '-' || t.startsWith('#') || t.startsWith('- ')) {
            continue; // 空行/裸连字符标记/注释/数组子项, 跳过
          }
          if (YamlMerger.lineIndent(line) > baseIndent) {
            continue; // 缩进子键
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
          if (key.length === 0) {
            continue;
          }
          if (key === '<<') {
            mergeValues.push(t.substring(idx + 1).trim());
            continue;
          }
          // 重复键忽略; 白名单外的安全键不再丢弃, 而是进入 extraOpts 中继。
          if (fields.has(key) || extraSeen.has(key)) {
            continue;
          }
          let rawValue = t.substring(idx + 1).trim();
          if (rawValue.length === 0) {
            // 块式值: 缩进子键合成 flow-map(ws-opts/smux/reality-opts)或序列(alpn/ports)
            rawValue = YamlMerger.nestedValueOf(parseLines, li, false, 1);
          } else if (YamlMerger.isBlockScalarHeader(rawValue)) {
            // 块标量（`password: |` / `password: >-` / `plugin: |2`）：把缩进块体抽成值，
            // 只把**值**交给后面的字段链路（白名单结构化槽位 / extraOpts 中继）。
            // 块体为空或含无法进入单行槽位的换行时，该字段按「缺失/无法承载」降级。
            rawValue = YamlMerger.blockScalarBody(parseLines, li, rawValue);
          }
          YamlMerger.applyPair(key, rawValue, relayMode, supportedKeys,
            fields, extras, extraSeen, declaredType);
        }
      }
    } catch (e) {
      // 结构错误(flow-map 未闭合、未闭合集合/引号…): 登记用户可见原因后按节点级
      // 失败上报 —— merge 只跳过这一个节点, 不影响其余条目。
      if (e instanceof YamlNodeError) {
        YamlMerger.noteInvalid(e.message);
      }
      throw e as Error;
    }
    // YAML 合并键(`<<: *base` / `<<: [*a, *b]`): 显式键优先, 合并键只补缺失项;
    // 引用无法解析时等价于「字段缺失」, 不丢节点。
    for (const mergeRaw of mergeValues) {
      for (const pair of YamlMerger.flowPairs(mergeRaw)) {
        let mk = '';
        try {
          mk = YamlMerger.decodeScalar(pair[0]);
        } catch (e) {
          continue;
        }
        if (mk.length === 0 || mk === '<<' || fields.has(mk) || extraSeen.has(mk)) {
          continue;
        }
        YamlMerger.applyPair(mk, pair[1], relayMode, supportedKeys, fields, extras, extraSeen,
          declaredType);
      }
    }
    const name = fields.get('name') ?? '';
    const server = fields.get('server') ?? '';
    const portStr = fields.get('port') ?? '0';
    const proxyType = (fields.get('type') ?? '').toLowerCase();
    // mihomo 的 direct 出站只有 name/type（无 server/port），必须放行否则被当缺字段丢弃
    const isDirectOutbound = proxyType === 'direct';
    if (name.length === 0 || proxyType.length === 0
      || (server.length === 0 && !isDirectOutbound)) {
      throw YamlMerger.invalidNode('代理节点缺少 name、type 或 server');
    }
    if (proxyType !== 'ss' && proxyType !== 'ssr' && proxyType !== 'vless'
      && proxyType !== 'vmess' && proxyType !== 'trojan' && proxyType !== 'hysteria2'
      && !YamlMerger.isRelayType(proxyType)) {
      // 记录被跳过的协议类型, 由订阅刷新流程提示用户(不再静默丢弃)
      YamlMerger.noteSkipped(proxyType);
      throw new YamlNodeError(`不支持的代理类型：${proxyType}`);
    }
    if (!/^\d{1,5}$/.test(portStr)) {
      throw YamlMerger.invalidNode('代理节点端口格式无效');
    }
    const portNum = parseInt(portStr);
    if ((portNum <= 0 || portNum > 65535) && !isDirectOutbound) {
      throw YamlMerger.invalidNode('代理节点端口超出范围');
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
      throw YamlMerger.invalidNode('代理节点 alterId 格式无效');
    }
    p.alterId = parseInt(alterIdText);
    p.udp = YamlMerger.parseBoolean(fields.get('udp') ?? 'false', 'udp');
    p.network = fields.get('network') ?? '';
    p.tls = YamlMerger.parseBoolean(fields.get('tls') ?? 'false', 'tls');
    p.servername = fields.get('servername') ?? fields.get('sni') ?? '';
    p.skipCertVerify = YamlMerger.parseBoolean(fields.get('skip-cert-verify') ?? 'false',
      'skip-cert-verify');
    p.flow = fields.get('flow') ?? '';
    // 两个指纹是**不同语义的键**，必须各归各位：
    //   client-fingerprint = uTLS 指纹（TLS 客户端伪装）
    //   fingerprint        = 证书指纹 pinSHA256（校验对端证书）
    // 此前 fingerprint 被当成 client-fingerprint 的兜底塞进同一槽位，导致同时带
    // 两键的 hysteria2 节点把真正的 pin 丢掉、并被回写成 `fingerprint: chrome`。
    p.clientFingerprint = fields.get('client-fingerprint') ?? '';
    p.certFingerprint = fields.get('fingerprint') ?? '';
    if (proxyType === 'hysteria2' || proxyType === 'hysteria') {
      p.hyUp = YamlMerger.normalizeBandwidth(fields.get('up') ?? fields.get('upmbps') ?? '');
      p.hyDown = YamlMerger.normalizeBandwidth(fields.get('down') ?? fields.get('downmbps') ?? '');
    }
    if (YamlMerger.supportsAlpn(proxyType)) {
      // alpn 不再只限 hysteria2: vless/vmess/trojan 的 ALPN 协商同样需要它
      p.alpnList = YamlMerger.normalizeAlpnList(fields.get('alpn') ?? '');
    }
    try {
      YamlMerger.parseNestedOptions(fields, p, itemLines, extras);
    } catch (e) {
      // reality-opts/ws-opts/grpc-opts 结构异常时忽略嵌套项, 不丢弃整个节点
      if (e instanceof YamlMergeError) {
        throw e;
      }
    }
    const values: string[] = [p.name, p.server, p.cipher, p.password, p.protocol, p.protocolParam,
      p.obfs, p.obfsParam, p.uuid, p.network, p.servername, p.flow, p.clientFingerprint,
      p.certFingerprint, p.realityPublicKey, p.realityShortId, p.wsPath, p.wsHost, p.grpcServiceName,
      p.hyUp, p.hyDown, p.alpnList];
    // 与 values 一一对应的字段名：限额/控制字符诊断里直接给出用户看得懂的字段名
    const valueNames: string[] = ['name', 'server', 'cipher', 'password', 'protocol',
      'protocol-param', 'obfs', 'obfs-param', 'uuid', 'network', 'servername', 'flow',
      'client-fingerprint', 'fingerprint', 'reality-public-key', 'reality-short-id', 'ws-path',
      'ws-host', 'grpc-service-name', 'up', 'down', 'alpn'];
    for (let i = 0; i < values.length; i++) {
      YamlMerger.validateNodeText(values[i], i < valueNames.length ? valueNames[i] : `field-${i}`);
    }
    for (const pair of extras) {
      YamlMerger.validateNodeText(pair[1], 'extra-value');
    }
    p.extraOpts = extras.length > 0 ? JSON.stringify(extras) : '';
    if ((p.type === 'ss' || p.type === 'ssr') && (p.cipher.length === 0 || p.password.length === 0)) {
      throw YamlMerger.invalidNode(`代理节点「${p.name}」缺少 cipher 或 password`);
    }
    if (p.type === 'ssr' && (p.protocol.length === 0 || p.obfs.length === 0)) {
      throw YamlMerger.invalidNode(`SSR 节点「${p.name}」缺少 protocol 或 obfs`);
    }
    if ((p.type === 'vless' || p.type === 'vmess') && p.uuid.length === 0) {
      throw YamlMerger.invalidNode(`代理节点「${p.name}」缺少 uuid`);
    }
    if (p.type === 'vmess' && p.cipher.length === 0) {
      throw YamlMerger.invalidNode(`VMess 节点「${p.name}」缺少 cipher`);
    }
    if (p.type === 'trojan' && p.password.length === 0) {
      throw YamlMerger.invalidNode(`Trojan 节点「${p.name}」缺少 password`);
    }
    if (p.type === 'hysteria2' && p.password.length === 0) {
      throw YamlMerger.invalidNode(`Hysteria2 节点「${p.name}」缺少 password`);
    }
    // 逐字模板：flow-map 原文剔除 name 与凭据键（凭据走加密层，模板可安全持久化）。
    // 块式写法/URI 节点无模板 → 生成端回退结构化路径。
    p.rawTemplate = flowInner !== null ? YamlMerger.buildRawTemplate(flowInner, p.name) : '';
    return p;
  }

  /** 从模板里剔除的键：name（生成时用去重后的显示名注入）+ 全部凭据键（走加密层）。 */
  private static readonly RAW_TEMPLATE_STRIP_KEYS: Set<string> = new Set<string>([
    'name', 'uuid', 'password', 'protocol-param', 'protocol_param',
    'obfs-param', 'obfs_param', 'obfs-password'
  ]);

  /**
   * rawTemplate 去重的**最大嵌套层数**（flow-map 里的 map 再嵌 map）。
   * mihomo 的传输选项实际最多嵌 2 层（`ws-opts` / `headers`），4 层足够；
   * 超限时该层**原样保留**（不删内容）—— 极端病态输入才可能命中。
   */
  private static readonly RAW_TEMPLATE_MAX_NEST_DEPTH: number = 4;

  /**
   * 由 flow-map 原文构造逐字模板：保留除 name/凭据外所有键的**原始文本**
   * （含 xhttp-opts、reality-opts、headers、null 值等），生成端原样回写。
   * 结构异常或超长返回 ''（回退结构化路径）。
   *
   * 【C15】**按 key 去重（留首次出现）**。
   * 为什么必须去重：mihomo 用 go.yaml.in/yaml/v3 v3.0.5，`uniqueKeys` **默认开启**
   * （decode.go:344），同层级重复键 = TypeError = **整份配置拒载**（全有全无：
   * 一个节点坏 → 整个 VPN 起不来）。本模板**逐字**保留订阅原文，订阅里写了
   * `cipher: aes-256-gcm, cipher: aes-128-gcm` 就会原样进产物 → 拒载。
   * 只有 **flow-map 写法**会炸（块式写法走结构化路径，解析期「重复键取首个」已消化）。
   *
   * ⚠ **降级规则必须显式化**：两个 `cipher` 时留第一个是**产品策略**，
   * **不代表第一个正确**。所以同时留下一条诊断（节点名 + 被去重的 key 名列表），
   * 让上层/日志能看见「这个节点有重复键、已按首个保留」—— 诊断通道是本文件的静态统计机制
   * （`lastDuplicateKeyCount` / `lastDuplicateKeyReasons`，见其上方注释）。
   *
   * 其它约定：
   * - 去重只在**保留的键之间**进行（name/凭据类键本就被剔除，不参与去重）；
   * - 嵌套 map（`ws-opts: {path: /a, path: /b}`，R0b）同样按 key 去重；
   * - `<<`（YAML 合并键）不参与去重（多个合并键另有语义，不在此处裁剪）；
   * - 有重复键但**无法安全重建**（结构异常）时，**返回 '' 回退结构化路径**——
   *   与「结构异常/超长返回 ''」的既有行为一致，绝不产出会让内核拒载的模板。
   */
  private static buildRawTemplate(inner: string, nodeName: string): string {
    const trimmed = inner.trim();
    if (trimmed.length === 0 || trimmed.length > 8192) {
      return '';
    }
    const kept: string[] = [];
    const keptKeys: Set<string> = new Set<string>();
    /** 被去重掉的 key（留首次出现） */
    const dupKeys: string[] = [];
    /** 检出但无法安全重建的重复键（→ 回退结构化路径） */
    const unremovable: string[] = [];
    try {
      for (const pair of YamlMerger.splitFlowMap(trimmed)) {
        const pairText = pair.trim();
        const idx = YamlMerger.findUnquotedColon(pairText);
        if (idx <= 0) {
          continue;
        }
        let key = '';
        try {
          key = YamlMerger.decodeScalar(pairText.substring(0, idx).trim());
        } catch (e) {
          continue;
        }
        if (key.length === 0 || YamlMerger.RAW_TEMPLATE_STRIP_KEYS.has(key) || key === '<<') {
          continue;
        }
        if (pairText.includes('\n') || pairText.includes('\r')) {
          continue;
        }
        // 重复键：**留首次出现**（显式降级规则，见上方注释）
        if (keptKeys.has(key)) {
          dupKeys.push(key);
          continue;
        }
        keptKeys.add(key);
        kept.push(YamlMerger.dedupeNestedFlowMap(pairText, idx, dupKeys, unremovable, 0));
      }
    } catch (e) {
      return '';
    }
    if (unremovable.length > 0) {
      // 检出重复键但无法安全重建 → 宁可回退结构化路径（既有行为），也不能产出会被内核拒载的模板
      YamlMerger.noteRawTemplateDuplicate(nodeName, unremovable.concat(dupKeys));
      return '';
    }
    if (dupKeys.length > 0) {
      YamlMerger.noteRawTemplateDuplicate(nodeName, dupKeys);
    }
    return kept.join(', ');
  }

  /**
   * flow-map 内部的 pair 列表按 key 去重（保留首次出现），并递归处理嵌套 map。
   * 非 key:value 片段（无法识别的裸文本）原样保留，不计入重复键；
   * `<<`（合并键）不参与去重。dupKeys 收集被去掉的 key，unremovable 收集检出去不掉的。
   */
  private static dedupeFlowMapPairs(inner: string, dupKeys: string[], unremovable: string[],
    depth: number): string {
    const kept: string[] = [];
    const seen: Set<string> = new Set<string>();
    for (const pair of YamlMerger.splitFlowMap(inner)) {
      const pairText = pair.trim();
      const idx = YamlMerger.findUnquotedColon(pairText);
      if (idx <= 0) {
        kept.push(pairText);
        continue;
      }
      let key = '';
      try {
        key = YamlMerger.decodeScalar(pairText.substring(0, idx).trim());
      } catch (e) {
        kept.push(pairText);
        continue;
      }
      if (key.length === 0 || key === '<<') {
        kept.push(pairText);
        continue;
      }
      if (seen.has(key)) {
        dupKeys.push(key);
        continue;
      }
      seen.add(key);
      if (depth < YamlMerger.RAW_TEMPLATE_MAX_NEST_DEPTH) {
        kept.push(YamlMerger.dedupeNestedFlowMap(pairText, idx, dupKeys, unremovable, depth));
      } else {
        kept.push(pairText);
      }
    }
    return kept.join(', ');
  }

  /**
   * 对一个 pair 的**值**做嵌套 map 去重（`ws-opts: {path: /a, path: /b}` 这类 R0b 形态）。
   * 值里没有重复键时**原文逐字返回**（不重建、不改任何空白）；有重复键才重建该 pair。
   */
  private static dedupeNestedFlowMap(pair: string, idx: number, dupKeys: string[],
    unremovable: string[], depth: number): string {
    const value = pair.substring(idx + 1).trim();
    if (!value.startsWith('{')) {
      return pair;
    }
    const close = YamlMerger.matchingClose(value, 0);
    if (close < 0) {
      // 未闭合的嵌套 map：无法安全重建（交由调用方回退结构化路径）
      unremovable.push('(nested-map)');
      return pair;
    }
    const before = dupKeys.length;
    const deduped = YamlMerger.dedupeFlowMapPairs(value.substring(1, close), dupKeys, unremovable,
      depth + 1);
    if (dupKeys.length === before) {
      return pair; // 无重复键 → 原文逐字保留
    }
    return pair.substring(0, idx + 1) + ' {' + deduped + '}' + value.substring(close + 1);
  }

  /**
   * 登记「flow-map 节点含重复键」的诊断（计数 + 去重理由，最多 12 条）。
   * 诊断通道 = 本文件的静态统计机制（见 lastDuplicateKeyCount 上方注释）。
   */
  private static noteRawTemplateDuplicate(nodeName: string, dupKeys: string[]): void {
    YamlMerger.lastDuplicateKeyCount = YamlMerger.lastDuplicateKeyCount + 1;
    const uniq: string[] = [];
    for (const k of dupKeys) {
      if (uniq.indexOf(k) < 0) {
        uniq.push(k);
      }
    }
    let text = `节点「${nodeName}」含重复键（${uniq.join('、')}），已按首次出现保留`
      + '（重复键会让 mihomo 整份配置拒载）';
    if (text.length > 120) {
      text = text.substring(0, 120);
    }
    for (const it of YamlMerger.lastDuplicateKeyReasons) {
      if (it === text) {
        return;
      }
    }
    if (YamlMerger.lastDuplicateKeyReasons.length < 12) {
      YamlMerger.lastDuplicateKeyReasons.push(text);
    }
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

  /**
   * 节点身份指纹：**包含 name** + 全部协议及白名单嵌套字段。
   *
   * name 必须参与指纹：机场把面板推广 / 公告做成「与真实节点同 server:port 同凭据、
   * 仅名字不同」的条目（如「剩余流量」「套餐到期」「有超过20多个节点」）。指纹里不含
   * name 时这些条目会被判成重复而整条删除 —— 这是本客户端比其它客户端节点数少的
   * 第一号原因（其它客户端不做跨订阅去重）。含 name 后：内容完全相同且同名者仍去重，
   * 「同 server:port 但 path/uuid 不同」依旧判定为不同节点（这些字段本来就在指纹里）。
   */
  static identityFingerprint(p: MergedProxy): string {
    const parts: string[] = [];
    parts.push(`name=${JSON.stringify(p.name)}`);
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
    parts.push(`certFingerprint=${JSON.stringify(p.certFingerprint)}`);
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
        // uTLS 指纹固定发 `client-fingerprint`（hysteria2 也支持该键，不要改写成 fingerprint）
        fields.push(`client-fingerprint: ${YamlMerger.encodeScalar(p.clientFingerprint)}`);
      }
      if (p.certFingerprint.length > 0) {
        // 证书指纹 pinSHA256 → `fingerprint`。此前这里把 clientFingerprint 当成 pin 发成
        // `fingerprint`，结果是 `fingerprint: chrome`（内核拿到非法 pin）且真正的 pin 丢失。
        fields.push(`fingerprint: ${YamlMerger.encodeScalar(p.certFingerprint)}`);
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
          throw new YamlMergeError(errorTextOr(e, '代理节点解析发生未知错误'));
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
          throw new YamlMergeError(errorTextOr(e, '代理节点解析发生未知错误'));
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
    // dialer-proxy 依赖校验：目标缺失只诊断（字段保留），依赖成环则打破（移除环上依赖）
    YamlMerger.resolveDialerProxyDependencies(merged);
    return merged;
  }
}
