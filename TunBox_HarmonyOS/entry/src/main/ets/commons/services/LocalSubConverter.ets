/**
 * 订阅转换（设置页「订阅转换」）—— 把**不是 Clash YAML** 的输入转成 mihomo 能吃的订阅。
 *
 * ## 为什么要有它
 * TunBox 的订阅入口只收 Clash YAML（产品定案：JSON / CONF / 裸链接列表一律拒）。
 * 但用户手里经常是另一种形态：一条 `vless://…`、一大段 base64 链接列表、或者几十行
 * 分享链接。让用户自己去在线转换站既麻烦也要把订阅贴到第三方 —— 所以内置一个最简转换：
 * **链接 → mihomo 配置**，然后以「本地订阅」的形式交给现有导入链路。
 *
 * ## 关键设计：不真起 HTTP 服务
 * HarmonyOS 的 `TCPSocketServer` 只暴露 send/close（没有读请求的接口），真起 HTTP 服务器
 * 读不到 Request。所以这里用**伪链接 + 应用内渲染**：
 *   `http://127.0.0.1:65530/localsub/<id>.yaml`
 * 该链接在 `SubscriptionFetchPolicy.fetch()` 入口被本模块直接接管（不联网、不占端口、
 * 离线可用），对上层仍然是「一条 http 订阅」，Clash-only 闸门与刷新链路都不必开洞。
 * 代价：这条链接只在 TunBox 内有效（不打算给别的客户端用）。
 *
 * ## 支持的输入（v1）
 * 1. **Clash YAML**（含 `proxies:`）→ 不需要转换（给出提示，直接导入即可）
 * 2. **分享链接列表**（每行一条，ss / ssr / vmess / vless / trojan / hysteria2 / tuic / anytls…）
 * 3. **整体 base64 的链接列表**（机场常见的 v2ray 订阅）
 * 4. 以上混合（行内既有链接又有空行/注释）
 *
 * 不支持（v1 明确不做，避免猜错格式）：sing-box JSON、v2rayN 导出 JSON、整体加密订阅。
 */

import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { ProxyNode } from '../models/ProxyNode';
import { ClashConfigGenerator } from './ClashConfigGenerator';
import { UriNodeParser, ParseError, ParsedNode, parse as parseUriNode } from '../subscription/UriNodeParser';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'LocalSubConverter';
const PREF_NAME = 'tunbox_local_subs';
const KEY_STORE = 'local_subs_json';
/** 伪链接前缀：127.0.0.1 + 固定端口 + 固定路径段（端口不会被真正监听，只为形似合法 URL） */
const LOCAL_URL_PREFIX = 'http://127.0.0.1:65530/localsub/';
const LOCAL_URL_SUFFIX = '.yaml';
/** 单个转换订阅的源文本上限（防止把整本电子书粘进来） */
const MAX_SOURCE_BYTES = 2 * 1024 * 1024;

/** 转换结果（ok=false 时 reason 是中文可展示原因） */
export class ConvertOutcome {
  ok: boolean = false;
  /** 生成的 mihomo YAML（可直接作为订阅正文） */
  yaml: string = '';
  /** 成功转换的节点数 */
  count: number = 0;
  /** 识别出的输入形态：clash / links / base64 / empty / unknown */
  kind: string = '';
  /** 失败原因（给用户看的一句话） */
  reason: string = '';
  /** 逐行失败摘要（最多 5 条，便于用户发现哪几行写错了） */
  failures: string[] = [];
}

/** 已保存的本地订阅（源文本 + 元信息；YAML 每次请求现渲染） */
export class LocalSubEntry {
  id: string = '';
  name: string = '';
  /** 用户最初粘进来的原文（唯一真源，YAML 由它渲染） */
  source: string = '';
  count: number = 0;
  createdAt: number = 0;
}

export class LocalSubConverter {
  private static store: preferences.Preferences | null = null;
  private static cache: Map<string, LocalSubEntry> = new Map<string, LocalSubEntry>();
  private static loaded: boolean = false;

  // ── 链接形态 ──────────────────────────────────────────────────────────

  /** 是否为「本地转换订阅」伪链接 */
  static isLocalUrl(urlStr: string): boolean {
    return urlStr.toLowerCase().startsWith(LOCAL_URL_PREFIX);
  }

  /** 从伪链接里取订阅 id（非法返回空串） */
  static idOf(urlStr: string): string {
    if (!LocalSubConverter.isLocalUrl(urlStr)) {
      return '';
    }
    const rest = urlStr.substring(LOCAL_URL_PREFIX.length);
    const cut = rest.indexOf(LOCAL_URL_SUFFIX);
    const id = (cut >= 0 ? rest.substring(0, cut) : rest).trim();
    return /^[A-Za-z0-9_-]{6,64}$/.test(id) ? id : '';
  }

  static urlOf(id: string): string {
    return `${LOCAL_URL_PREFIX}${id}${LOCAL_URL_SUFFIX}`;
  }

  // ── 转换核心（纯函数，便于门禁直接跑） ────────────────────────────────

  /**
   * 把任意输入转成 mihomo YAML。
   *
   * @param raw 用户粘贴的原文
   * @param nameHint 订阅显示名（为空时用「本地转换 N 个节点」）
   */
  static convert(raw: string, nameHint: string = ''): ConvertOutcome {
    const out = new ConvertOutcome();
    const text = raw.trim();
    if (text.length === 0) {
      out.kind = 'empty';
      out.reason = '没有内容：请粘贴分享链接或 base64 链接列表';
      return out;
    }
    if (text.length > MAX_SOURCE_BYTES) {
      out.kind = 'unknown';
      out.reason = '内容过大（超过 2MB），请只粘贴订阅正文';
      return out;
    }
    // 已经是 Clash：不转换（用户直接导入即可）
    if (LocalSubConverter.looksLikeClash(text)) {
      out.kind = 'clash';
      out.reason = '这已经是 Clash 配置，直接「导入订阅」即可，不需要转换';
      return out;
    }
    // 链接列表 / base64 链接列表
    let kind = 'links';
    let body = text;
    if (!LocalSubConverter.hasAnyScheme(text)) {
      // 没有协议头，可能是整体 base64
      const decoded = UriNodeParser.base64Decode(text.replace(/\s+/g, ''));
      if (decoded.length === 0 || !LocalSubConverter.hasAnyScheme(decoded)) {
        out.kind = 'unknown';
        out.reason = '认不出来：既不是 Clash 配置，也不是分享链接（或 base64 链接列表）';
        return out;
      }
      body = decoded;
      kind = 'base64';
    }
    const lines = body.split(/\r?\n/);
    const nodes: ProxyNode[] = [];
    const failures: string[] = [];
    let index = 0;
    for (const rawLine of lines) {
      const line = rawLine.trim();
      if (line.length === 0 || line.startsWith('#') || line.startsWith('//')) {
        continue;
      }
      index = index + 1;
      // 走**规范解析层**（与订阅导入同一条链路）：fromUri 只认 URI_CODECS 里的协议，
      // vless / hysteria2 / tuic 等会被它直接判 null → 这里必须用 parse() + fromCanonical()。
      const parsed: ParsedNode | ParseError = parseUriNode(line, '');
      if (parsed instanceof ParseError) {
        if (failures.length < 5) {
          const label = line.length > 40 ? `${line.substring(0, 40)}…` : line;
          failures.push(parsed.missing.length > 0 ? `${label}（缺 ${parsed.missing.join('/')}）` : label);
        }
        continue;
      }
      const node = ProxyNode.fromCanonical(parsed, '', `local-${index}`);
      if (node === null) {
        if (failures.length < 5) {
          failures.push(line.length > 40 ? `${line.substring(0, 40)}…` : line);
        }
        continue;
      }
      if (node.name.length === 0) {
        node.name = `${node.server}:${node.port}`;
      }
      node.originalName = node.name;
      nodes.push(node);
    }
    if (nodes.length === 0) {
      out.kind = kind;
      out.reason = '没有可识别的节点：每行需要一条分享链接（ss:// / vmess:// / vless:// / trojan:// …）';
      out.failures = failures;
      return out;
    }
    ClashConfigGenerator.ensureUniqueProxyNames(nodes);
    const yaml = LocalSubConverter.emitYaml(nodes, nameHint, index, failures.length);
    if (yaml.length === 0) {
      out.kind = kind;
      out.reason = '这些节点的必填参数不完整，无法生成合法配置（换一条链接再试）';
      out.failures = failures;
      return out;
    }
    out.ok = true;
    out.kind = kind;
    out.count = nodes.length;
    out.yaml = yaml;
    out.failures = failures;
    return out;
  }

  /** 是否是 Clash 配置（有顶层 proxies: 且不是纯链接列表） */
  static looksLikeClash(text: string): boolean {
    if (!/(^|\n)\s*proxies\s*:/.test(text)) {
      return false;
    }
    return !LocalSubConverter.hasAnyScheme(text.split(/\r?\n/)[0]);
  }

  /** 文本里是否出现任意受支持的分享链接协议头 */
  static hasAnyScheme(text: string): boolean {
    return /(^|\n)\s*(ss|ssr|vmess|vless|trojan|hysteria2?|hy2|tuic|anytls|snell|socks5?|https?):\/\//i
      .test(text);
  }

  /**
   * 生成 mihomo 订阅正文：`proxies` + 一个 select 组 + `MATCH` 兜底。
   *
   * 只写最小骨架：DNS/TUN/规则都由 TunBox 生成器在连接时补齐（订阅正文只提供节点），
   * 与三家「订阅只给节点」的形态一致。
   */
  private static emitYaml(nodes: ProxyNode[], nameHint: string, total: number,
    failedCount: number): string {
    const lines: string[] = [];
    lines.push('# TunBox 本地转换订阅');
    lines.push(`# 源形态：分享链接列表 · 识别 ${total} 行 · 成功 ${nodes.length} 行`
      + (failedCount > 0 ? ` · 跳过 ${failedCount} 行` : ''));
    if (nameHint.length > 0) {
      lines.push(`# ${nameHint}`);
    }
    lines.push('proxies:');
    let emitted = 0;
    const names: string[] = [];
    for (const n of nodes) {
      const line = ClashConfigGenerator.proxyYamlLine(n);
      if (line.length === 0) {
        continue;
      }
      lines.push(line);
      names.push(n.name);
      emitted = emitted + 1;
    }
    if (emitted === 0) {
      return '';
    }
    lines.push('proxy-groups:');
    lines.push('  - name: "PROXY"');
    lines.push('    type: select');
    lines.push('    proxies:');
    for (const name of names) {
      lines.push(`      - "${ClashConfigGenerator.escapeYaml(name)}"`);
    }
    lines.push('rules:');
    lines.push('  - MATCH,PROXY');
    lines.push('');
    return lines.join('\n');
  }

  // ── 存储与渲染 ────────────────────────────────────────────────────────

  static async init(context: Context): Promise<void> {
    try {
      LocalSubConverter.store = await preferences.getPreferences(context, PREF_NAME);
      LocalSubConverter.load();
    } catch (e) {
      AppLogger.warn(TAG, `local sub store init failed: ${AppLogger.errText(e)}`);
    }
  }

  private static load(): void {
    LocalSubConverter.cache.clear();
    const raw = LocalSubConverter.store === null
      ? '' : (LocalSubConverter.store.getSync(KEY_STORE, '') as string);
    if (raw.length === 0) {
      LocalSubConverter.loaded = true;
      return;
    }
    try {
      const arr = JSON.parse(raw) as LocalSubEntry[];
      for (const item of arr) {
        if (item.id.length > 0) {
          LocalSubConverter.cache.set(item.id, item);
        }
      }
    } catch (e) {
      AppLogger.warn(TAG, `local sub store parse failed: ${AppLogger.errText(e)}`);
    }
    LocalSubConverter.loaded = true;
  }

  private static async persist(): Promise<void> {
    if (LocalSubConverter.store === null) {
      return;
    }
    const arr: LocalSubEntry[] = [];
    LocalSubConverter.cache.forEach((v: LocalSubEntry): void => {
      arr.push(v);
    });
    LocalSubConverter.store.putSync(KEY_STORE, JSON.stringify(arr));
    await LocalSubConverter.store.flush();
  }

  /** 保存一条转换结果，返回可直接导入的伪链接 */
  static async save(source: string, outcome: ConvertOutcome, nameHint: string): Promise<string> {
    const id = util.generateRandomUUID(false).replace(/-/g, '').substring(0, 24);
    const entry = new LocalSubEntry();
    entry.id = id;
    entry.name = nameHint.length > 0 ? nameHint : `本地转换（${outcome.count} 节点）`;
    entry.source = source;
    entry.count = outcome.count;
    entry.createdAt = Date.now();
    LocalSubConverter.cache.set(id, entry);
    await LocalSubConverter.persist();
    AppLogger.info(TAG, `local sub saved: ${id} nodes=${outcome.count} kind=${outcome.kind}`);
    return LocalSubConverter.urlOf(id);
  }

  static entries(): LocalSubEntry[] {
    const out: LocalSubEntry[] = [];
    LocalSubConverter.cache.forEach((v: LocalSubEntry): void => {
      out.push(v);
    });
    out.sort((a: LocalSubEntry, b: LocalSubEntry): number => b.createdAt - a.createdAt);
    return out;
  }

  static async remove(id: string): Promise<void> {
    LocalSubConverter.cache.delete(id);
    await LocalSubConverter.persist();
  }

  /** 渲染某条本地订阅的 YAML（每次现渲染：源文本变了立刻生效，也不需要落盘第二份） */
  static render(id: string): ConvertOutcome {
    const entry = LocalSubConverter.cache.get(id);
    if (entry === undefined) {
      const miss = new ConvertOutcome();
      miss.kind = 'missing';
      miss.reason = '这条本地订阅不存在（可能已被删除）';
      return miss;
    }
    return LocalSubConverter.convert(entry.source, entry.name);
  }
}
