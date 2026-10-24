// [harness] generated from entry/src/main/ets/commons/services/SubscriptionParser.ets — 仅 import 目标被重写
/**
 * 订阅解析器（统一入口）
 * 移植自 upstream: packages/tunbox_shared/lib/services/subscription_parser.dart
 *                subscription_parser_base64_part.dart
 *                subscription_parser_naming_part.dart
 *                subscription_parser_yaml_part.dart
 *
 * 支持：ssr:// / ss:// / vless:// / vmess:// / trojan:// / hysteria2://(hy2://) 单链接、
 *       Base64 批量列表、Clash YAML proxies。
 */
import { ProxyNode, ProxyNodeType, Base64Codec } from './ProxyNode.ts';
import { ProxyGroup } from './ProxyGroup.ts';
import { MergedProxy, YamlMergeError, YamlMerger, YamlNodeError } from './YamlMerger.ts';
import { AppLogger } from './stubs.ts';
// 2026-10-20（B6 旧解析器退场）：链接列表走**规范解析层**，不再走 ProxyNode.fromUri
import { parse as parseUriNode, ParseError, ParsedNode } from './UriNodeParser.ts';
import { NodeUsability, UnusableCategory } from './NodeUsability.ts';
import { UnusableLedger, UnusableRecord } from './UnusableLedger.ts';

const TAG = 'SubscriptionParser';

/** 动态分组物化时的节点池条目（归一名 → 原始名，首见序去重）。 */
interface DynamicPoolEntry {
  key: string;
  original: string;
}

/** 解析层诊断，不依赖服务层状态，避免三种入口各自猜测跳过数量。 */
export class SubscriptionParseDiagnostics {
  inputCount: number = 0;
  duplicateCount: number = 0;
  invalidCount: number = 0;
  unsupportedCount: number = 0;
  unsupportedTypes: string = '';
}

export class SubscriptionParseResult {
  nodes: ProxyNode[] = [];
  groups: ProxyGroup[] = [];
  diagnostics: SubscriptionParseDiagnostics = new SubscriptionParseDiagnostics();
}

/** 每次解析独立维护名称索引，避免每个节点重建已有节点集合。 */
export class SubscriptionNameAllocator {
  private names: Set<string> = new Set<string>();
  private nextSuffix: Map<string, number> = new Map<string, number>();

  reserve(name: string): void {
    this.names.add(name);
  }

  allocate(name: string): string {
    const base = name.length > 0 ? name : 'node';
    let finalName = base;
    if (this.names.has(base)) {
      let suffix = this.nextSuffix.get(base) ?? 2;
      do {
        finalName = `${base} ${suffix++}`;
      } while (this.names.has(finalName));
      this.nextSuffix.set(base, suffix);
    }
    this.names.add(finalName);
    return finalName;
  }
}

export class SubscriptionParser {
  /** 任意 scheme:// 形态都先按节点链接尝试；是否有解析器由 ProxyNode 注册表判定 */
  private static isProxyUri(trimmed: string): boolean {
    return /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(trimmed);
  }

  private static uriScheme(trimmed: string): string {
    const m = trimmed.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):\/\//);
    return m === null ? '' : m[1].toLowerCase();
  }

  /**
   * 解析订阅文本，返回节点列表。
   * 顺序与 upstream 一致：先按行找 ssr:///ss:// 链接 → 整体 base64 解码后再找 → Clash YAML。
   */
  static parse(text: string, subscriptionId: string): ProxyNode[] {
    return SubscriptionParser.parseDetailed(text, subscriptionId).nodes;
  }

  /**
   * 统一的可诊断解析入口。明文、整体 Base64 与 YAML 均逐条隔离失败，
   * 重复、无效和未知协议不会静默消失。
   */
  static parseDetailed(text: string, subscriptionId: string): SubscriptionParseResult {
    const result = new SubscriptionParseResult();
    const diagnostics = result.diagnostics;
    const nodes: ProxyNode[] = [];
    const seen = new Set<string>();
    // 名称分配器：共享一次遍历内的名称索引。旧实现每个节点都重建
    // `new Set(existing.map(...))`，1000 节点订阅即 ~50 万次 Set 插入（O(N²)），
    // 这是解析路径上最贵的一步；分配器把后缀起点也记住，重新分配同名不会从 2 重试。
    const nameAllocator = new SubscriptionNameAllocator();
    let counter = 0;

    const add = (node: ProxyNode | null): void => {
      if (node === null) {
        diagnostics.invalidCount = diagnostics.invalidCount + 1;
        return;
      }
      // 必须在任何 alias、订阅前缀或重名后缀处理前冻结订阅原始名称。
      // URI 与 Base64 分支都经过此入口；YAML 分支若已在映射层赋值则保持原值。
      if (node.originalName.length === 0) {
        node.originalName = node.name;
      }
      // 去重键须能区分"同地址不同凭据"的节点: YAML 条目无 rawUri, 只用 server:port 会
      // 误伤共用落地服务器的多账号/多协议节点; 通知型重复后端(全字段一致)仍正常去重。
      // name 必须参与去重键: 面板推广/公告条目常与真实节点共用 server:port:凭据, 仅
      // 名字不同; 不含 name 会把它们当重复删掉(与 YamlMerger.identityFingerprint 同理)。
      const key = `${node.name}:${node.server}:${node.port}:${node.proxyType.length > 0 ? node.proxyType : node.type}`
        + `:${node.password}:${node.uuid}:${node.rawUri}`;
      if (seen.has(key)) {
        diagnostics.duplicateCount = diagnostics.duplicateCount + 1;
        return;
      }
      seen.add(key);
      node.name = nameAllocator.allocate(node.name);
      nodes.push(node);
    };

    const normalized = text.replace(/^\uFEFF/, '');
    result.groups = SubscriptionParser.parseProxyGroups(normalized, subscriptionId);
    // scheme 注册表分发：有解析器 → 规范解析层 + add（去重/originalName 冻结），未识别 scheme → unsupported
    // 2026-10-20（B6）：不再调 ProxyNode.fromUri —— 订阅链路统一走规范解析层
    const addFromUri = (trimmed: string): void => {
      diagnostics.inputCount = diagnostics.inputCount + 1;
      const scheme = SubscriptionParser.uriScheme(trimmed);
      if (ProxyNode.hasUriCodec(scheme)) {
        const parsed: ParsedNode | ParseError = parseUriNode(trimmed, subscriptionId);
        if (parsed instanceof ParseError) {
          // 缺必填参数等 → 整条不可用（原因已进 UnusableLedger，UI 可见）
          diagnostics.invalidCount = diagnostics.invalidCount + 1;
          return;
        }
        const built = ProxyNode.fromCanonical(parsed, subscriptionId, `${subscriptionId}-${counter++}`);
        if (built === null) {
          diagnostics.invalidCount = diagnostics.invalidCount + 1;
          return;
        }
        add(built);
        return;
      }
      diagnostics.unsupportedCount = diagnostics.unsupportedCount + 1;
      SubscriptionParser.noteUnsupported(diagnostics, trimmed);
    };
    // 1) 明文链接逐行解析
    for (const line of normalized.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (trimmed.length === 0) {
        continue;
      }
      if (SubscriptionParser.isProxyUri(trimmed)) {
        addFromUri(trimmed);
      }
    }

    // 2) 整体 Base64 解码后再解析（对应 subscription_parser_base64_part）
    if (nodes.length === 0) {
      const decoded = Base64Codec.decodeBase64Url(normalized.replace(/\s+/g, ''));
      if (decoded.length > 0 && decoded.includes('://')) {
        for (const line of decoded.split(/\r?\n/)) {
          const trimmed = line.trim();
          if (trimmed.length === 0) {
            continue;
          }
          if (SubscriptionParser.isProxyUri(trimmed)) {
            addFromUri(trimmed);
          } else {
            diagnostics.inputCount = diagnostics.inputCount + 1;
            diagnostics.invalidCount = diagnostics.invalidCount + 1;
          }
        }
      }
    }

    // 3) Clash YAML proxies 提取（对应 subscription_parser_yaml_part；完整 YAML 语义由 ClashConfigGenerator 的解析支持）
    if (nodes.length === 0) {
      const groups = YamlMerger.proxyItemGroups(normalized);
      // 明文/base64 分支可能已计过数（链接全部解析失败时 nodes 仍为 0，会落到本分支）。
      // 覆盖式重算会吞掉那些失败计数，诊断显示"输入 0 条"，用户无从知道节点为何变少 —— 改为增量聚合。
      const priorInput = diagnostics.inputCount;
      const priorInvalid = diagnostics.invalidCount;
      diagnostics.inputCount = priorInput + groups.length;
      YamlMerger.resetSkipStats();
      const yamlNodes = SubscriptionParser.parseClashYaml(normalized, subscriptionId, counter);
      for (const n of yamlNodes) {
        add(n);
      }
      diagnostics.unsupportedCount = diagnostics.unsupportedCount + YamlMerger.lastSkippedCount;
      diagnostics.unsupportedTypes = YamlMerger.lastSkippedTypes;
      const accounted = nodes.length + diagnostics.duplicateCount + diagnostics.unsupportedCount;
      diagnostics.invalidCount = priorInvalid + Math.max(0, diagnostics.inputCount - accounted);
    }

    AppLogger.info(TAG, `parsed ${nodes.length} nodes for subscription ${subscriptionId}`);
    result.nodes = nodes;
    return result;
  }

  /**
   * 提取 Clash / Mihomo proxy-groups，保留组与成员的原始声明顺序。
   * 支持常见 block sequence 及 flow map/flow sequence；DIRECT、REJECT、GLOBAL
   * 等保留为普通成员，是否可展开为节点由消费层决定。
   */
  static parseProxyGroups(text: string, subscriptionId: string): ProxyGroup[] {
    const groups: ProxyGroup[] = [];
    const lines = text.replace(/\r/g, '').split('\n');
    let sectionIndent = -1;
    let itemIndent = -1;
    let itemLines: string[] = [];
    const flush = (): void => {
      if (itemLines.length === 0) {
        return;
      }
      const group = SubscriptionParser.parseProxyGroupItem(itemLines, subscriptionId);
      if (group !== null && group.name.length > 0) {
        groups.push(group);
      }
      itemLines = [];
    };
    for (const raw of lines) {
      const trimmed = raw.trim();
      const indent = raw.length - raw.trimStart().length;
      if (sectionIndent < 0) {
        if (/^proxy-groups\s*:\s*(?:#.*)?$/.test(trimmed)) {
          sectionIndent = indent;
        }
        continue;
      }
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      if (indent <= sectionIndent) {
        flush();
        break;
      }
      // 只有 proxy-groups 分节的直接子级序列项才是新分组。直接子级的缩进以**首个
      // 序列项的实测缩进为准**（面板模板有 2/4 空格与 Tab 等多种写法，硬编码 +2
      // 会让非标准缩进的订阅整节解析为 0 组）；组内 proxies: 的嵌套 "- member"
      // 缩进更深，原样下传给当前组解析（成员识别在 parseProxyGroupItem 内做）。
      if (itemIndent < 0 && /^-\s+/.test(trimmed)) {
        itemIndent = indent;
      }
      if (/^-\s+/.test(trimmed) && indent === itemIndent) {
        flush();
        itemLines.push(trimmed.substring(1).trim());
      } else if (itemLines.length > 0) {
        itemLines.push(trimmed);
      }
    }
    flush();
    AppLogger.info(TAG, `parsed ${groups.length} proxy group(s) for subscription ${subscriptionId}`);
    return groups;
  }

  private static parseProxyGroupItem(lines: string[], subscriptionId: string): ProxyGroup | null {
    const group = new ProxyGroup();
    group.subscriptionId = subscriptionId;
    let collectingMembers = false;
    for (const raw of lines) {
      const line = SubscriptionParser.stripYamlComment(raw).trim();
      if (line.length === 0) {
        continue;
      }
      if (collectingMembers && line.startsWith('- ')) {
        group.members.push(SubscriptionParser.yamlScalar(line.substring(2)));
        continue;
      }
      const fields = line.startsWith('{') && line.endsWith('}')
        ? SubscriptionParser.splitYamlFlow(line.substring(1, line.length - 1))
        : [line];
      for (const field of fields) {
        const colon = SubscriptionParser.topLevelColon(field);
        if (colon <= 0) {
          continue;
        }
        const key = SubscriptionParser.yamlScalar(field.substring(0, colon)).toLowerCase();
        const value = field.substring(colon + 1).trim().replace(/,$/, '').trim();
        collectingMembers = key === 'proxies' && value.length === 0;
        if (key === 'name') {
          group.name = SubscriptionParser.yamlScalar(value);
        } else if (key === 'type') {
          group.groupType = SubscriptionParser.yamlScalar(value).toLowerCase();
        } else if (key === 'proxies' && value.startsWith('[') && value.endsWith(']')) {
          group.members = SubscriptionParser.splitYamlFlow(value.substring(1, value.length - 1));
        } else if (key === 'include-all') {
          group.includeAll = value.toLowerCase() === 'true';
        } else if (key === 'include-all-proxies') {
          group.includeAllProxies = value.toLowerCase() === 'true';
        } else if (key === 'filter') {
          group.filterPattern = SubscriptionParser.yamlScalar(value);
        } else if (key === 'exclude-filter') {
          group.excludeFilterPattern = SubscriptionParser.yamlScalar(value);
        } else if (key === 'url') {
          // 组测速地址语义保真（url-test/fallback/load-balance）；非法值由生成端校验兜底
          group.url = SubscriptionParser.yamlScalar(value);
        } else if (key === 'interval') {
          // 自动测速间隔（秒）：面板常见 60~86400；非数字按未声明处理
          const interval = parseInt(value);
          group.intervalSec = isNaN(interval) || interval <= 0 ? 0 : interval;
        } else if (key === 'tolerance') {
          // url-test/load-balance 的切换容差（毫秒）
          const tolerance = parseInt(value);
          group.toleranceMs = isNaN(tolerance) || tolerance < 0 ? 0 : tolerance;
        } else if (key === 'expected-status') {
          group.expectedStatus = SubscriptionParser.yamlScalar(value);
        }
      }
    }
    return group.name.length > 0 ? group : null;
  }

  /**
   * 动态分组物化（Clash Meta 语义）：include-all / include-all-proxies /
   * filter / exclude-filter 组在解析链拿到同订阅节点池后，把匹配结果的
   * originalName 追加进 members，使 UI 与级联功能组能展开出节点。
   * - filter/exclude-filter 对节点名做不区分大小写正则；脏正则降级为不匹配并记日志；
   * - (?i) 前缀内联标志重写为 RegExp 'i' 标志（ArkTS/ECMAScript 不支持内联标志组）；
   * - 名称匹配前双方做 NFKC + 去 U+FE0F 归一（emoji 变体选择符兼容）；
   * - 仅匹配真实节点：GEO/IP-CIDR 等规则成员、未展开的嵌套组名不会被误当作节点；
   * - 结果确定性排序（节点池顺序），静态声明成员原样保留在前；幂等，可重复调用。
   */
  static materializeDynamicGroups(groups: ProxyGroup[], nodes: ProxyNode[]): void {
    const dynamic = groups.filter((g) => g.isDynamic());
    if (dynamic.length === 0 || nodes.length === 0) {
      return;
    }
    // 归一名 → originalName（首见序），同归一名多节点时收敛为一个成员声明。
    const pool: DynamicPoolEntry[] = [];
    const seenKey = new Set<string>();
    for (const n of nodes) {
      const original = n.originalName.length > 0 ? n.originalName : n.name;
      if (original.length === 0) {
        continue;
      }
      const key = SubscriptionParser.normalizeGroupName(original);
      if (!seenKey.has(key)) {
        seenKey.add(key);
        const entry: DynamicPoolEntry = { key: key, original: original };
        pool.push(entry);
      }
    }
    for (const g of dynamic) {
      const declared = new Set<string>(g.members);
      const result: string[] = g.members.slice();
      let filterRe: RegExp | null = null;
      let filterBad = false;
      if (g.filterPattern.length > 0) {
        filterRe = SubscriptionParser.compileGroupFilter(g.filterPattern);
        filterBad = filterRe === null;
      }
      let excludeRe: RegExp | null = null;
      let excludeBad = false;
      if (g.excludeFilterPattern.length > 0) {
        excludeRe = SubscriptionParser.compileGroupFilter(g.excludeFilterPattern);
        excludeBad = excludeRe === null;
      }
      if (filterBad || excludeBad) {
        AppLogger.warn(TAG, `dynamic group "${g.name}" has invalid regex, degraded to no-match filter`);
      }
      for (const c of pool) {
        if (filterRe !== null && !filterRe.test(c.key)) {
          continue;
        }
        if (excludeRe !== null && excludeRe.test(c.key)) {
          continue;
        }
        if (!declared.has(c.original)) {
          declared.add(c.original);
          result.push(c.original);
        }
      }
      g.members = result;
    }
  }

  /** 分组名称/成员匹配归一：NFKC + 去除 U+FE0F 变体选择符。 */
  static normalizeGroupName(value: string): string {
    let text = value;
    try {
      text = text.normalize('NFKC');
    } catch (e) {
      // 个别内核 ICU 缺失时降级为原文匹配
    }
    return text.replace(/\uFE0F/g, '');
  }

  /**
   * filter/exclude-filter → RegExp（对齐 mihomo/regexp2 语义）。
   * mihomo 用 regexp2：内联 (?i) 只让**其后**的模式大小写不敏感，之前的片段
   * （如 `(?=.*(美|US|...|(?i)States|...))` 里的 US）保持大小写敏感——
   * "US" 不应命中 "EUserv"。JS 无内联标志，故把 (?i) 之后的 ASCII 字母
   * 展开成 [cC] 类、整个正则按大小写敏感编译，等效还原该作用域语义。
   */
  private static compileGroupFilter(pattern: string): RegExp | null {
    try {
      const expanded = SubscriptionParser.expandInlineIgnoreCase(pattern);
      if (expanded.length === 0) {
        return null;
      }
      return new RegExp(expanded);
    } catch (e) {
      return null;
    }
  }

  /** 剥内联标志组；含 i 的（(?i)/(?is) 等）把其后 ASCII 字母展开成 [cC]（近似 regexp2 作用域） */
  private static expandInlineIgnoreCase(pattern: string): string {
    let out = '';
    let rest = pattern;
    const flagGroup = /\(\?([a-zA-Z]+)\)/;
    while (rest.length > 0) {
      const m = rest.match(flagGroup);
      if (m === null || m.index === undefined) {
        out += rest;
        return out;
      }
      out += rest.substring(0, m.index);
      rest = rest.substring(m.index + m[0].length);
      if (m[1].indexOf('i') >= 0) {
        // (?i) 之后按不敏感匹配：展开到模式结尾（regexp2 的组内作用域近似，实际订阅
        // 模板的 (?i) 均位于尾部备选分支，近似误差可忽略）
        out += SubscriptionParser.expandCaseInsensitiveLetters(rest);
        return out;
      }
      // 其它标志（?s/?m/?x...）仅剥离，不影响大小写
    }
    return out;
  }

  /** ASCII 字母 → [cC] 字符类；转义序列与字符类原样拷贝，非 ASCII（中文/emoji）不动 */
  private static expandCaseInsensitiveLetters(text: string): string {
    let out = '';
    let i = 0;
    while (i < text.length) {
      const ch = text.charAt(i);
      if (ch === '\\') {
        out += text.substring(i, Math.min(i + 2, text.length));
        i = i + 2;
        continue;
      }
      if (ch === '[') {
        const close = text.indexOf(']', i);
        const end = close < 0 ? text.length : close + 1;
        out += text.substring(i, end);
        i = end;
        continue;
      }
      const code = text.charCodeAt(i);
      if ((code >= 65 && code <= 90) || (code >= 97 && code <= 122)) {
        const upper = ch.toUpperCase();
        const lower = ch.toLowerCase();
        out += upper === lower ? ch : `[${upper}${lower}]`;
      } else {
        out += ch;
      }
      i = i + 1;
    }
    return out;
  }

  private static stripYamlComment(value: string): string {
    let quote = '';
    let escaped = false;
    for (let i = 0; i < value.length; i++) {
      const ch = value.charAt(i);
      if (escaped) {
        escaped = false;
        continue;
      }
      if (quote === '"' && ch === '\\') {
        escaped = true;
        continue;
      }
      if (ch === '"' || ch === "'") {
        quote = quote.length === 0 ? ch : (quote === ch ? '' : quote);
      } else if (ch === '#' && quote.length === 0) {
        return value.substring(0, i);
      }
    }
    return value;
  }

  private static topLevelColon(value: string): number {
    let quote = '';
    let square = 0;
    let curly = 0;
    for (let i = 0; i < value.length; i++) {
      const ch = value.charAt(i);
      if (ch === '"' || ch === "'") {
        quote = quote.length === 0 ? ch : (quote === ch ? '' : quote);
      } else if (quote.length === 0) {
        if (ch === '[') square++;
        else if (ch === ']') square--;
        else if (ch === '{') curly++;
        else if (ch === '}') curly--;
        else if (ch === ':' && square === 0 && curly === 0) return i;
      }
    }
    return -1;
  }

  private static splitYamlFlow(value: string): string[] {
    const out: string[] = [];
    let current = '';
    let quote = '';
    let escaped = false;
    let squareDepth = 0;
    let curlyDepth = 0;
    for (let i = 0; i < value.length; i++) {
      const ch = value.charAt(i);
      if (escaped) {
        current += ch;
        escaped = false;
        continue;
      }
      if (quote === '"' && ch === '\\') {
        current += ch;
        escaped = true;
        continue;
      }
      if (ch === '"' || ch === "'") {
        quote = quote.length === 0 ? ch : (quote === ch ? '' : quote);
        current += ch;
        continue;
      }
      if (quote.length === 0) {
        if (ch === '[') squareDepth++;
        else if (ch === ']') squareDepth--;
        else if (ch === '{') curlyDepth++;
        else if (ch === '}') curlyDepth--;
        else if (ch === ',' && squareDepth === 0 && curlyDepth === 0) {
          const member = SubscriptionParser.yamlScalar(current);
          if (member.length > 0) out.push(member);
          current = '';
          continue;
        }
      }
      current += ch;
    }
    const tail = SubscriptionParser.yamlScalar(current);
    if (tail.length > 0) out.push(tail);
    return out;
  }

  private static yamlScalar(value: string): string {
    const trimmed = value.trim().replace(/,$/, '').trim();
    if (trimmed.length >= 2) {
      const first = trimmed.charAt(0);
      const last = trimmed.charAt(trimmed.length - 1);
      if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
        return trimmed.substring(1, trimmed.length - 1);
      }
    }
    return trimmed;
  }

  private static noteUnsupported(diagnostics: SubscriptionParseDiagnostics, uri: string): void {
    const sep = uri.indexOf('://');
    const type = sep > 0 ? uri.substring(0, sep).toLowerCase() : 'unknown';
    const types = new Set<string>();
    for (const item of diagnostics.unsupportedTypes.split(',')) {
      if (item.length > 0) {
        types.add(item);
      }
    }
    if (types.size < 12) {
      types.add(type);
    }
    diagnostics.unsupportedTypes = Array.from(types).join(',');
  }

  /** 节点重名规整（对应 subscription_parser_naming_part）：重名追加序号 */
  static dedupName(existing: ProxyNode[], name: string): string {
    const base = name.length > 0 ? name : 'node';
    let finalName = base;
    let i = 2;
    const names = new Set<string>(existing.map((n) => n.name));
    while (names.has(finalName)) {
      finalName = `${base} ${i++}`;
    }
    return finalName;
  }

  /** Clash YAML 统一复用 YamlMerger 的受限结构化解析，坏节点按条目隔离。 */
  static parseClashYaml(text: string, subscriptionId: string, startCounter: number): ProxyNode[] {
    const out: ProxyNode[] = [];
    let counter = startCounter;
    for (const itemLines of YamlMerger.proxyItemGroups(text)) {
      let merged: MergedProxy | null = null;
      try {
        merged = YamlMerger.parseProxyItem(itemLines);
      } catch (e) {
        if (e instanceof YamlNodeError) {
          continue;
        }
        if (e instanceof YamlMergeError) {
          throw e;
        }
        continue;
      }
      if (merged === null) {
        continue;
      }
      const node = new ProxyNode();
      node.id = `${subscriptionId}-y${counter++}`;
      node.subscriptionId = subscriptionId;
      node.name = merged.name;
      node.server = merged.server;
      node.port = merged.port;
      node.password = merged.password;
      node.method = merged.cipher;
      node.protocol = merged.protocol;
      node.protocolParam = merged.protocolParam;
      node.obfs = merged.obfs;
      node.obfsParam = merged.obfsParam;
      node.proxyType = merged.type;
      node.type = merged.type === 'ssr' ? ProxyNodeType.SSR
        : (merged.type === 'ss' ? ProxyNodeType.SS : ProxyNodeType.UNKNOWN);
      node.uuid = merged.uuid;
      node.alterId = merged.alterId;
      node.udp = merged.udp;
      node.network = merged.network;
      node.tls = merged.tls;
      node.servername = merged.servername;
      node.skipCertVerify = merged.skipCertVerify;
      node.flow = merged.flow;
      node.clientFingerprint = merged.clientFingerprint;
      node.certFingerprint = merged.certFingerprint;
      node.realityPublicKey = merged.realityPublicKey;
      node.realityShortId = merged.realityShortId;
      node.wsPath = merged.wsPath;
      node.wsHost = merged.wsHost;
      node.grpcServiceName = merged.grpcServiceName;
      node.hyUp = merged.hyUp;
      node.hyDown = merged.hyDown;
      node.alpnList = merged.alpnList;
      node.extraOpts = merged.extraOpts;
      node.rawYaml = '';
      // 【2026-10-24】订阅信息条目过滤（与 URI 路径 UriNodeParser 同口径）：YAML 原文里
      // 「剩余流量：xxx GB / 套餐到期」这类条目字段完整、能进内核代理表但永远拨不通，
      // 还会被选为连接目标（真机取证：connected to node 剩余流量：596.2 GB）。
      // 剔除 + 台账留痕（用户可见「本订阅有 N 条信息条目被跳过」）。
      if (NodeUsability.isInfoEntry(node.name)) {
        const infoRecord = new UnusableRecord();
        infoRecord.subscriptionId = subscriptionId;
        infoRecord.source = 'yaml';
        infoRecord.protocol = merged.type;
        infoRecord.name = node.name;
        infoRecord.server = node.server;
        infoRecord.port = node.port;
        infoRecord.category = UnusableCategory.INFO;
        infoRecord.excluded = true;
        infoRecord.reason = NodeUsability.infoReason(node.name);
        infoRecord.detail = '订阅信息条目，非节点（YAML 路径）：不进代理表、不参与测速。';
        UnusableLedger.record(infoRecord);
        continue;
      }
      out.push(node);
    }
    return out;
  }
}
