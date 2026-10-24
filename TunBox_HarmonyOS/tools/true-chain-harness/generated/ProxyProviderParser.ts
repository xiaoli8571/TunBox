// [harness] generated from entry/src/main/ets/commons/services/ProxyProviderParser.ets — 仅 import 目标被重写
/**
 * proxy-providers 提取器（漏洞 C）
 *
 * Clash / Mihomo 配置允许把节点放在   proxy-providers   段（远程 http(s) provider、内联
 * inline provider 或本地 file 文件），而   proxies   段只留少量甚至为空。此前 TunBox 只读
 * proxies，于是「订阅少节点」且界面没有任何提示（用户看到 0 节点或只剩几个节点）。
 *
 * 本文件做两件事：
 * 1) 从 YAML 文本中提取 provider 条目（name / type / url / path / interval / payload）；
 * 2) 把**不需要网络**的 inline provider 内容（payload / proxies 子块）抽取成普通订阅文本，
 *    交给 YamlMerger 走与主订阅**完全相同**的解析链（见 parseInline）。
 *
 * 各类型的处理约定（与用户可见文案一一对应，见 unsupportedReason）：
 *   - http / https: 由 SubscriptionService 拉取（同样的 UA 降级链/大小上限），本文件只提取；
 *   - inline:       内容就在配置里 —— 直接解析合并（parseInline），无需网络；
 *   - file:         path 是**面板本机**路径，手机上永远拿不到，必须给明确文案；
 *   - 其他/未知:    同理给明确文案，绝不静默丢弃。
 *
 * 支持的写法（均为常见面板输出形态）：
 *   proxy-providers:
 *     provider1:
 *       type: http
 *       url: "https://example.com/sub"
 *       interval: 3600
 *       path: ./providers/provider1.yaml
 *     provider2: {type: http, url: "https://example.com/sub2", interval: 7200}
 *   proxy-providers:
 *     - name: provider3
 *       type: file
 *       path: ./providers/p3.yaml
 *     - name: inline1
 *       type: inline
 *       payload:
 *         - {name: n1, type: ss, server: a.example.test, port: 8388, cipher: aes-256-gcm, password: REDACTED}
 *         - {name: n2, type: ss, server: b.example.test, port: 8389, cipher: aes-256-gcm, password: REDACTED}
 */
import { AppLogger } from './stubs.ts';
import { MergedProxy, YamlMerger } from './YamlMerger.ts';

const TAG = 'ProxyProviderParser';
/** 单次导入允许拉取的 provider 上限（防恶意配置把刷新变成 N 次网络请求） */
export const MAX_PROVIDERS = 64;
/** url/path 最大长度（超过视为脏数据直接忽略该字段） */
const MAX_VALUE_LENGTH = 8192;
/** inline payload 文本上限（单条 provider 内容；超过按「不可用」处理，不无限吃内存） */
const MAX_PAYLOAD_LENGTH = 512 * 1024;

export class ProxyProviderEntry {
  name: string = '';
  type: string = '';
  url: string = '';
  path: string = '';
  interval: number = 0;
  /**
   * inline provider 的内联内容原文（payload / proxies 子块，已去掉公共缩进）。
   * http/file 类型为空串。
   */
  payload: string = '';

  /** 类型是否支持「网络拉取」（http/https 指向远程订阅内容，本客户端可拉取） */
  isSupportedType(): boolean {
    return this.type === 'http' || this.type === 'https';
  }

  /** inline 类型：节点内容直接写在配置里，不需要网络拉取 */
  isInlineType(): boolean {
    return this.type === 'inline';
  }

  /** inline 且确实带了内容（空壳 inline provider 不算可用） */
  hasInlinePayload(): boolean {
    return this.isInlineType() && this.payload.trim().length > 0;
  }

  /** file 类型：path 指向**面板本机**文件，手机端不可用 */
  isFileType(): boolean {
    return this.type === 'file';
  }

  /** 是否具备拉取条件（类型支持且 url 非空） */
  isFetchable(): boolean {
    return this.isSupportedType() && this.url.length > 0;
  }
}

export class ProxyProviderParser {
  /** 去掉成对的引号（'...' / "..."），并裁剪空白 */
  private static unquote(raw: string): string {
    let value = raw.trim();
    if (value.length >= 2) {
      const first = value.charAt(0);
      const last = value.charAt(value.length - 1);
      if ((first === '"' && last === '"') || (first === '\'' && last === '\'')) {
        value = value.substring(1, value.length - 1).trim();
      }
    }
    return value;
  }

  /** 写入一个 key: value（仅识别 name/type/url/path/interval） */
  private static applyPair(entry: ProxyProviderEntry, rawKey: string, rawValue: string): void {
    const key = ProxyProviderParser.unquote(rawKey).toLowerCase();
    const value = ProxyProviderParser.unquote(rawValue);
    if (key === 'name') {
      if (value.length > 0 && value.length <= 4096) {
        entry.name = value;
      }
    } else if (key === 'type') {
      entry.type = value.toLowerCase();
    } else if (key === 'url') {
      if (value.length <= MAX_VALUE_LENGTH) {
        entry.url = value;
      }
    } else if (key === 'path') {
      if (value.length <= MAX_VALUE_LENGTH) {
        entry.path = value;
      }
    } else if (key === 'interval') {
      const seconds = Number(value);
      if (Number.isInteger(seconds) && seconds >= 0) {
        entry.interval = seconds;
      }
    }
  }

  /** 解析 "key: value" 行；无冒号或键为空时返回 false */
  private static applyLine(entry: ProxyProviderEntry, text: string): boolean {
    const idx = text.indexOf(':');
    if (idx <= 0) {
      return false;
    }
    ProxyProviderParser.applyPair(entry, text.substring(0, idx), text.substring(idx + 1));
    return true;
  }

  /** 解析 flow-map 值 {k: v, k2: v2}（引号内的逗号不参与切分） */
  private static applyFlowMap(entry: ProxyProviderEntry, flow: string): void {
    const text = flow.trim();
    if (!text.startsWith('{') || !text.endsWith('}')) {
      return;
    }
    const parts = ProxyProviderParser.splitFlowItems(text.substring(1, text.length - 1));
    for (const part of parts) {
      if (part.trim().length > 0) {
        ProxyProviderParser.applyLine(entry, part.trim());
      }
    }
  }

  /** 判断一行是否是 inline 内容键（payload / proxies）并返回它的值部分；否则返回 null */
  private static inlineKeyValue(text: string): string | null {
    if (text.startsWith('{') || text.startsWith('-')) {
      return null;
    }
    const idx = text.indexOf(':');
    if (idx <= 0) {
      return null;
    }
    const key = ProxyProviderParser.unquote(text.substring(0, idx)).toLowerCase();
    if (key !== 'payload' && key !== 'proxies') {
      return null;
    }
    return text.substring(idx + 1).trim();
  }

  /**
   * 提取 proxy-providers 条目。解析失败/脏条目直接忽略（不影响其它条目），
   * 超过 MAX_PROVIDERS 的部分截断（调用方通过返回值长度与日志可见）。
   */
  static parse(yaml: string): ProxyProviderEntry[] {
    const out: ProxyProviderEntry[] = [];
    if (yaml.indexOf('proxy-providers:') < 0) {
      return out;
    }
    const section = ProxyProviderParser.sectionLines(yaml);
    let current: ProxyProviderEntry | null = null;
    const flush = (): void => {
      if (current === null) {
        return;
      }
      const entry = current;
      current = null;
      if (entry.name.length === 0 && entry.url.length === 0 && entry.payload.length === 0) {
        return;
      }
      if (entry.name.length === 0) {
        entry.name = entry.url.length > 0 ? entry.url : 'inline-provider';
      }
      out.push(entry);
    };
    // 条目层级：以**第一条条目行**的缩进为准，缩进更深的行都算该条目的字段。
    // 历史实现用固定阈值（indent <= 2 即新条目），遇到常见写法 `- name: p0`（键在缩进 0/2）
    // 或深缩进面板时会错切条目、把 type/url/payload 挂到空条目上。
    let entryIndent = -1;
    // 条目自身字段的缩进（首个字段行实测）：更深的行属于子块（如 health-check 的
    // url/interval），绝不能覆盖 provider 自己的 url —— 否则下载地址会被换成
    // 健康检查的 204 测速地址（真机案例：良心云 provider 拉到 www.gstatic.com）。
    let fieldIndent = -1;
    for (let li = 0; li < section.length; li++) {
      const rawLine = section[li];
      const trimmed = rawLine.trim();
      if (trimmed.length === 0 || trimmed.startsWith('#')) {
        continue;
      }
      const indent = rawLine.length - rawLine.trimStart().length;
      const sequenceItem = trimmed === '-' || trimmed.startsWith('- ');
      const startsEntry = sequenceItem
        ? (entryIndent < 0 || indent <= entryIndent)
        : (entryIndent < 0 || indent === entryIndent);
      if (startsEntry) {
        // 顶层条目：映射形式 "name:" 或序列形式 "- name: x" / "- {..}"
        flush();
        current = new ProxyProviderEntry();
        entryIndent = indent;
        fieldIndent = -1;
        let body = trimmed;
        if (sequenceItem) {
          body = trimmed === '-' ? '' : trimmed.substring(2).trim();
        }
        if (body.length === 0) {
          continue;
        }
        if (body.endsWith(':') && body.indexOf('{') < 0) {
          current.name = ProxyProviderParser.unquote(body.substring(0, body.length - 1));
        } else if (body.indexOf('{') > 0) {
          const brace = body.indexOf('{');
          const head = body.substring(0, brace);
          if (head.trim().endsWith(':')) {
            current.name = ProxyProviderParser.unquote(head.trim().substring(0, head.trim().length - 1));
          }
          ProxyProviderParser.applyFlowMap(current, body.substring(brace));
        } else {
          ProxyProviderParser.applyLine(current, body);
        }
        continue;
      }
      if (current === null) {
        continue;
      }
      // inline 内容块：`payload:` / `proxies:` 后面缩进承载的 YAML（块式或行内 flow）
      const payloadValue = ProxyProviderParser.inlineKeyValue(trimmed);
      if (payloadValue !== null) {
        if (payloadValue.length > 0 && !payloadValue.startsWith('|') && !payloadValue.startsWith('>')) {
          current.payload = payloadValue;
          continue;
        }
        // 块式（含 `payload: |` 块标量）：整块抽出来，并跳过这些行，避免
        // 内联节点自己的 `type:`/`server:` 被当成 provider 的字段。
        const bodyLines: string[] = [];
        let endIndex = li;
        for (let j = li + 1; j < section.length; j++) {
          const rawBody = section[j];
          const bodyTrimmed = rawBody.trimStart();
          if (bodyTrimmed.length === 0) {
            endIndex = j;
            continue;
          }
          if (rawBody.length - bodyTrimmed.length <= indent) {
            break;
          }
          bodyLines.push(rawBody);
          endIndex = j;
        }
        current.payload = ProxyProviderParser.deindent(bodyLines);
        li = endIndex;
        continue;
      }
      if (trimmed.startsWith('{')) {
        ProxyProviderParser.applyFlowMap(current, trimmed);
      } else {
        // 只有条目字段层级的行才参与字段解析；更深的缩进属于子块（health-check 等）
        if (fieldIndent < 0) {
          fieldIndent = indent;
        }
        if (indent <= fieldIndent) {
          ProxyProviderParser.applyLine(current, trimmed);
        }
      }
    }
    flush();
    if (out.length > MAX_PROVIDERS) {
      AppLogger.warn(TAG, `proxy-providers truncated: ${out.length} -> ${MAX_PROVIDERS}`);
      return out.slice(0, MAX_PROVIDERS);
    }
    if (out.length > 0) {
      AppLogger.info(TAG, `parsed ${out.length} proxy-provider entr(ies)`);
    }
    return out;
  }

  /** 抽取 proxy-providers 段的原始行（保留缩进，便于判定层级） */
  private static sectionLines(yaml: string): string[] {
    const out: string[] = [];
    let inSection = false;
    for (let line of yaml.split('\n')) {
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      if (line.startsWith('\uFEFF')) {
        line = line.substring(1);
      }
      if (!line.startsWith(' ') && !line.startsWith('\t')) {
        const trimmed = line.trim();
        if (trimmed.startsWith('proxy-providers:')) {
          inSection = true;
          continue;
        }
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

  /** 去掉一组行的公共缩进（inline payload 子块用），保留相对层级 */
  private static deindent(lines: string[]): string {
    let minIndent = -1;
    for (const raw of lines) {
      const t = raw.trimStart();
      if (t.length === 0) {
        continue;
      }
      const indent = raw.length - t.length;
      if (minIndent < 0 || indent < minIndent) {
        minIndent = indent;
      }
    }
    if (minIndent < 0) {
      return '';
    }
    const out: string[] = [];
    for (const raw of lines) {
      const t = raw.trimStart();
      if (t.length === 0) {
        out.push('');
        continue;
      }
      const indent = raw.length - t.length;
      const cut = indent > minIndent ? minIndent : indent;
      out.push(raw.substring(cut));
    }
    return out.join('\n');
  }

  /** flow 集合的配对闭合下标（引号与嵌套深度都被跟踪）；未闭合返回 -1 */
  private static flowClose(text: string, openIndex: number): number {
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
          quote = '';
        }
        continue;
      }
      if (ch === '"' || ch === '\'') {
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

  /** 按顶层逗号切分 flow 集合内容（嵌套集合与引号内的逗号不切） */
  private static splitFlowItems(content: string): string[] {
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
          quote = '';
        }
        continue;
      }
      if (ch === '"' || ch === '\'') {
        quote = ch;
        current += ch;
      } else if (ch === '{') {
        braceDepth = braceDepth + 1;
        current += ch;
      } else if (ch === '}') {
        braceDepth = braceDepth - 1;
        current += ch;
      } else if (ch === '[') {
        bracketDepth = bracketDepth + 1;
        current += ch;
      } else if (ch === ']') {
        bracketDepth = bracketDepth - 1;
        current += ch;
      } else if (ch === ',' && braceDepth === 0 && bracketDepth === 0) {
        if (current.trim().length > 0) {
          out.push(current.trim());
        }
        current = '';
      } else {
        current += ch;
      }
    }
    if (current.trim().length > 0) {
      out.push(current.trim());
    }
    return out;
  }

  /**
   * inline 内容 → 可交给 YamlMerger 的 `proxies:` 订阅文本。
   * 支持三种形态：块序列（`- {..}` / `- name: x`）、flow 序列 `[{..}, {..}]`、
   * 单条 flow-map `{..}`，以及本来就是完整文档（含 `proxies:`）的文本。
   * 解析不出内容返回 ''（调用方按「无内容」降级，不抛错）。
   */
  static inlinePayloadDoc(payload: string): string {
    const text = payload.trim();
    if (text.length === 0 || text.length > MAX_PAYLOAD_LENGTH) {
      return '';
    }
    if (text.startsWith('[')) {
      const close = ProxyProviderParser.flowClose(text, 0);
      if (close < 0) {
        return '';
      }
      const lines: string[] = ['proxies:'];
      for (const item of ProxyProviderParser.splitFlowItems(text.substring(1, close))) {
        if (item.trim().length > 0) {
          lines.push(`  - ${item.trim()}`);
        }
      }
      return lines.length > 1 ? lines.join('\n') : '';
    }
    if (text.startsWith('{')) {
      const close = ProxyProviderParser.flowClose(text, 0);
      if (close < 0) {
        return '';
      }
      return `proxies:\n  - ${text.substring(0, close + 1)}`;
    }
    if (/^proxies\s*:/.test(text)) {
      return text;
    }
    const lines: string[] = ['proxies:'];
    for (const line of text.split('\n')) {
      if (line.trim().length === 0) {
        continue;
      }
      lines.push(`  ${line.trimEnd()}`);
    }
    return lines.length > 1 ? lines.join('\n') : '';
  }

  /** inline provider（带内容）条目 */
  static inlineProviders(entries: ProxyProviderEntry[]): ProxyProviderEntry[] {
    const out: ProxyProviderEntry[] = [];
    for (const e of entries) {
      if (e.hasInlinePayload()) {
        out.push(e);
      }
    }
    return out;
  }

  /**
   * 解析全部 inline provider 的内联内容（与主订阅/其它 provider 完全相同的解析链）。
   *
   * - 内容来自 `payload` / `proxies` 子块（块式或 flow 式）；
   * - 多个 inline provider 一起交给 YamlMerger.merge：跨 provider 同名同内容仍然去重，
   *   名称唯一化与限额规则与主订阅一致；
   * - 单个 provider 内容不可解析只影响它自己（返回条数少几条），不抛错、不影响 proxies 段。
   *
   * 上层拿到的是最终 MergedProxy 列表，可直接并入本次导入的节点集合。
   */
  static parseInline(entries: ProxyProviderEntry[], sourceName: string): MergedProxy[] {
    const docs: string[] = [];
    for (const entry of entries) {
      if (!entry.hasInlinePayload()) {
        continue;
      }
      const doc = ProxyProviderParser.inlinePayloadDoc(entry.payload);
      if (doc.length === 0) {
        AppLogger.warn(TAG, `inline provider "${entry.name}" payload 无法解析为节点列表`);
        continue;
      }
      docs.push(doc);
    }
    if (docs.length === 0) {
      return [];
    }
    try {
      return YamlMerger.merge(docs, sourceName, '');
    } catch (e) {
      AppLogger.warn(TAG, `inline provider merge failed: ${AppLogger.errText(e)}`);
      return [];
    }
  }

  /** 不支持（本客户端无法拉取/无法直接导入）的 provider 类型清单，去重后按 type 形式给出 */
  static unsupportedTypes(entries: ProxyProviderEntry[]): string {
    const seen = new Set<string>();
    for (const e of entries) {
      if (e.isSupportedType()) {
        continue;
      }
      // 带内容的 inline provider 已经由 parseInline 导入：不再报「不支持」，
      // 否则界面会同时出现「不支持 inline」与「已导入 N 个」两条互相矛盾的信息。
      if (e.hasInlinePayload()) {
        continue;
      }
      const type = e.type.length > 0 ? e.type : 'unknown';
      seen.add(type);
    }
    return Array.from(seen).join(',');
  }

  /** 支持的 http/https provider（需要拉取并合并） */
  static fetchable(entries: ProxyProviderEntry[]): ProxyProviderEntry[] {
    const out: ProxyProviderEntry[] = [];
    for (const e of entries) {
      if (e.isFetchable()) {
        out.push(e);
      }
    }
    return out;
  }

  /** 类型受支持但缺少 url 的 provider（提示用，不算失败） */
  static missingUrl(entries: ProxyProviderEntry[]): number {
    let count = 0;
    for (const e of entries) {
      if (e.isSupportedType() && e.url.length === 0) {
        count = count + 1;
      }
    }
    return count;
  }

  /**
   * 单个 provider 无法使用时的**明确文案**（供上层直接展示给用户）。
   *
   * 关键约定：file 类型指向的是**面板本机**路径（例如 ./providers/p.yaml），
   * 手机端无论如何都拿不到这个文件 —— 必须让用户看到「需要面板侧打包」，
   * 而不是笼统的「暂不支持」。
   */
  static unsupportedReason(entry: ProxyProviderEntry): string {
    const name = entry.name.length > 0 ? entry.name : 'provider';
    if (entry.isFileType()) {
      const pathText = entry.path.length > 0 ? `（${entry.path}）` : '';
      return `provider「${name}」是 file 类型${pathText}：节点内容放在面板本机的 file 类型`
        + ` provider 文件里，需要面板侧打包成 http 订阅，本应用无法拉取`;
    }
    if (entry.isInlineType()) {
      return `provider「${name}」是 inline 类型但没有 payload/proxies 内容，无法解析出节点`;
    }
    if (entry.isSupportedType() && entry.url.length === 0) {
      return `provider「${name}」缺少 url，无法拉取`;
    }
    const type = entry.type.length > 0 ? entry.type : 'unknown';
    return `provider「${name}」的类型 ${type} 暂不支持（本应用支持 http/https 拉取与 inline 内联解析，`
      + `file 类型需要面板侧打包成 http 订阅）`;
  }

  /** 全部无法使用 provider 的去重文案（';' 分隔，最多 3 条，供界面直接展示） */
  static unsupportedSummary(entries: ProxyProviderEntry[]): string {
    const seen = new Set<string>();
    const out: string[] = [];
    for (const e of entries) {
      if (e.isSupportedType() && e.url.length > 0) {
        continue;
      }
      const text = ProxyProviderParser.unsupportedReason(e);
      if (seen.has(text) || out.length >= 3) {
        continue;
      }
      seen.add(text);
      out.push(text);
    }
    return out.join(';');
  }
}
