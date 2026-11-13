/**
 * 配置写盘前校验闸门（C23 / C23b / C23c）
 *
 * ## 为什么需要它
 *
 * mihomo 用 yaml.v3 解配置（**本机实测的那份构建是 `gopkg.in/yaml.v3` v3.0.1**），
 * 而 **yaml.v3 的 `uniqueKeys` 默认开启**：
 * 同一个 mapping 里出现重复键 → 抛 `TypeError` → 错误文本是
 * `yaml: unmarshal errors:\n  line N: mapping key "xxx" already defined at line M`
 * → 内核 **整份拒载**（不是跳过那个节点）。
 *
 * 也就是说：**一个节点的字段写错，整个 VPN 起不来**（全有全无）。
 * 这正是用户报障原文「VPN 扩展启动异常: parse config:yaml: unmarshal errors:...」的形态。
 *
 * 生成侧已经在源头堵了大部分漏洞（rawTemplate 去重、provider 整块去重、覆盖层结构化合并、
 * rules 剥 `- ` 前缀），但**源头的修复是逐个 case 补的**，订阅内容千奇百怪，
 * 必须有一道**写盘前的最后闸门**：宁可让用户看到「配置有问题」并保留上一份可用配置，
 * 也不要写出一份内核一定拒载的配置，把「连不上」变成「整个 VPN 起不来」。
 *
 * ## 两层语义（严格 / 受控降级）
 *
 * 1. **严格层**（`validate`）：只报问题，不改文本。用于诊断与「要不要拦下」的判断。
 * 2. **受控降级层**（`repair`）：能安全降级的问题**就地降级**
 *    （删掉重复键那一行 / flow map 里的重复 pair / 去掉致命带引号布尔的引号），
 *    降级后重新校验，**仍有无法降级的问题**才算失败。
 *
 * ## 降级策略（必须显式，不要装作没发生）
 *
 * - 重复键：**保留首个**（与 YamlMerger 解析期的「重复键取首个」、以及
 *   `buildRawTemplate` 的降级口径一致），删掉后面的那一个（含它的子行）。
 * - flow map 内的重复 pair：保留首个，重建该 flow map。
 * - bool 字段上的**带引号**布尔（`"true"`/`"false"`/`"1"`/`"0"`）：去掉引号并归一为
 *   `true/false`（**只对已知布尔字段生效**，路径白名单见 BOOL_PATHS）。
 *   ⚠ 口径来自**真实内核实测**，与早期推断相反：不带引号的 `yes/no/on/off`
 *   内核是**接受**的（yaml.v3 对 bool 目标有 YAML 1.1 兼容分支），
 *   真正会炸的是**带引号**的 `"true"/"false"/"1"/"0"` 与**裸写**的 `1/0`。
 *   详见 judgeBoolLiteral 上方注释。
 * - 降级动作全部进 `issues`，由调用方写日志/提示用户（「这个节点的什么字段被降级了」）。
 *
 * ## 局限（诚实声明）
 *
 * 本校验器是**针对 yaml.v3 uniqueKeys 语义**的定向实现，**不是**完整 YAML 解析器：
 * 它不做锚点/别名（`&`/`*`）、多文档（`---`）、块标量（`|`/`>`）的完整语义解析。
 * 因此它是**闸门**（挡住已知的整份拒载形态），**不是** mihomo 语义的等价实现；
 * 「校验通过」不等于「内核一定能加载」。真机验证仍然是最终判据。
 */
import { AppLogger } from '../utils/AppLogger';

const TAG = 'ConfigValidator';

/**
 * 问题类型
 *
 * ⚠ 用「class + static readonly」而**不是**对象字面量 `const X = { ... }`：
 * ArkTS 禁止**无类型对象字面量**（`arkts-no-untyped-obj-literals`），
 * 对象字面量必须对应一个显式声明的 class/interface —— 直接写 `export const ConfigIssueKind = {…}`
 * 会让 **hvigor 编译直接失败**（本轮真实踩到：tsc 门禁全绿，DevEco 编译报 10605038）。
 * 也不用 `enum`：Node 侧的测试台（type-stripping）不吃 `export enum`。
 */
export class ConfigIssueKind {
  /** 同层级重复键（yaml.v3 uniqueKeys → 整份拒载） */
  static readonly DUPLICATE_KEY: string = 'DUPLICATE_KEY';
  /** flow map（`{a: 1, a: 2}`）内重复键（yaml.v3 uniqueKeys → 整份拒载） */
  static readonly DUPLICATE_KEY_FLOW: string = 'DUPLICATE_KEY_FLOW';
  /** rules 段出现嵌套 seq（`- - RULE`）→ `cannot unmarshal !!seq into string` */
  static readonly NESTED_SEQ: string = 'NESTED_SEQ';
  /** bool 字段上出现致命写法（带引号的 "true"/"1"/"0" 或裸写的 1/0）→ 内核整份拒载 */
  static readonly BOOL_AS_STR: string = 'BOOL_AS_STR';
}

/** 单条问题 */
export class ConfigIssue {
  /** ConfigIssueKind 之一 */
  kind: string = '';
  /** 行号（1 起） */
  line: number = 0;
  /** 出问题的键（路径或 flow map 内的键名） */
  key: string = '';
  /** 人读描述 */
  detail: string = '';
  /** 是否已被受控降级处理 */
  degraded: boolean = false;
}

/** 校验结果 */
export class ConfigValidationResult {
  /** 是否没有**未降级**的问题（true = 可写盘） */
  ok: boolean = true;
  /** 全部问题（含已降级的） */
  issues: ConfigIssue[] = [];
  /** 是否发生了降级 */
  degraded: boolean = false;
  /** 降级后的文本（未降级时为空串） */
  text: string = '';
  /** 降级丢弃的条目数（重复键行 / 重复 pair 数） */
  dropped: number = 0;

  /** 未降级的问题（真正会让内核拒载的） */
  blocking(): ConfigIssue[] {
    const out: ConfigIssue[] = [];
    for (const it of this.issues) {
      if (!it.degraded) {
        out.push(it);
      }
    }
    return out;
  }

  /** 一行摘要（给日志/提示用） */
  summary(): string {
    if (this.issues.length === 0) {
      return '配置校验通过';
    }
    const parts: string[] = [];
    for (const it of this.issues) {
      parts.push(`L${it.line} ${it.key}: ${it.detail}`);
    }
    return `${this.issues.length} 处问题（降级 ${this.dropped} 处）｜${parts.join('；')}`;
  }
}

/** 已知布尔字段路径（白名单）——只有这些路径上的值才需要按 bool 口径检查。
 *  口径与 mihomo RawConfig 的 bool 字段一致；白名单之外一律原样保留
 *  （内核对不认识的字段宽容，我们不擅自改用户的文本）。 */
const BOOL_PATHS: Set<string> = new Set<string>([
  'allow-lan', 'ipv6', 'unified-delay', 'tcp-concurrent', 'disable-keep-alive',
  'dns.enable', 'dns.ipv6', 'dns.disable-cache', 'dns.direct-nameserver-follow-policy',
  'dns.respect-rules',
  'tun.enable', 'tun.auto-route', 'tun.auto-detect-interface', 'tun.strict-route',
  'sniffer.enable', 'sniffer.override-destination', 'sniffer.parse-pure-ip',
  'sniffer.force-dns-mapping',
  'profile.store-selected', 'profile.store-fake-ip'
]);

/** 父段 → 它的子级布尔字段（用于 flow map 写法：`dns: {enable: "true"}`）。 */
const BOOL_CHILD_PATHS: Map<string, Set<string>> = new Map<string, Set<string>>([
  ['dns', new Set<string>(['enable', 'ipv6', 'disable-cache',
    'direct-nameserver-follow-policy', 'respect-rules'])],
  ['tun', new Set<string>(['enable', 'auto-route', 'auto-detect-interface', 'strict-route'])],
  ['sniffer', new Set<string>(['enable', 'override-destination', 'parse-pure-ip',
    'force-dns-mapping'])],
  ['profile', new Set<string>(['store-selected', 'store-fake-ip'])]
]);

/**
 * ⚠ 关于「YAML 1.1 布尔」的**内核实测口径**（不要凭印象改这段）：
 *
 * 本机用**真实内核**（mihomo Meta 1.10.0，与 App 内置的是同一份构建）跑 `-t` 逐个实测：
 *
 * | 写法 | 内核结果 |
 * |---|---|
 * | `allow-lan: yes` / `YES` / `on` / `ON`（**不带引号**） | **通过** |
 * | `allow-lan: "yes"` / `"on"` / `"no"` / `"OFF"`（带引号、属于 yaml.v3 兼容表） | **通过** |
 * | `allow-lan: true` / `false` / `TRUE`（裸写） | **通过** |
 * | `allow-lan: "true"` / `"True"` / `"TRUE"` / `"false"` / `"1"` / `"0"` | **整份拒载** |
 * | `allow-lan: 1` / `0` / `2`（**裸写数字**） | **整份拒载**（`cannot unmarshal !!int \`1\` into bool`） |
 *
 * 原因：yaml.v3 的 resolve 表只认 true/false 六种写法 → 其余（yes/no/on/off）解析为 **!!str**；
 * 但 decode 层对 **bool 目标**有一层 YAML 1.1 兼容分支，会把
 * y/Y/yes/Yes/YES/on/On/ON（→true）与 n/N/no/No/NO/off/Off/OFF（→false）转成 bool。
 * 白名单里**没有** true/True/TRUE/false/False/FALSE/1/0 —— 所以
 * **带引号的 "true"/"false"/"1"/"0" 与裸写的 1/0 才会炸**，而且炸的是整份配置。
 *
 * 结论（与早期推断相反，务必按本表执行）：
 *   ① 不带引号的 yes/no/on/off **不是**拒载原因 → 不拦、不改用户文本；
 *   ② 带引号的 "true"/"false"/"1"/"0" 与裸写的 1/0 **才是**拒载原因 → 归一为 true/false；
 *   ③ 裸写的**其它**数字（2、3、-1…）同样拒载，但意图无法判定 → **不猜**，
 *      判为阻塞（拦下写盘、保留上一份可用配置），由用户/订阅源改对。
 */

/** 带引号且属于 yaml.v3 兼容表 → 内核吃得下，无需处理。 */
const QUOTED_BOOL_COMPAT: Set<string> = new Set<string>([
  'y', 'Y', 'yes', 'Yes', 'YES', 'on', 'On', 'ON',
  'n', 'N', 'no', 'No', 'NO', 'off', 'Off', 'OFF'
]);

/** 带引号且不在兼容表里、但看起来是布尔 → 内核会报 cannot unmarshal !!str into bool。 */
const QUOTED_BOOL_FATAL: Set<string> = new Set<string>(['true', 'false', '1', '0']);

/** 布尔字面量的判定结果 */
export class BoolVerdict {
  /** 内核是否会拒载（致命） */
  fatal: boolean = false;
  /** 可安全归一成的字面量（'' = 无可安全归一的目标） */
  canonical: string = '';
  /** 致命但意图无法判定（如 `allow-lan: 2`）→ 只能拦下，不能猜 */
  ambiguous: boolean = false;
}

/**
 * 判断一个值在 bool 字段上是否会让内核拒载，以及能否安全归一。
 * @param value 值原文（未去引号）
 */
function judgeBoolLiteral(value: string): BoolVerdict {
  const v = value.trim();
  const out = new BoolVerdict();
  if (v.length === 0) {
    return out;
  }
  const first = v.charAt(0);
  const last = v.charAt(v.length - 1);
  const quoted = (first === '"' && last === '"') || (first === '\'' && last === '\'');
  if (quoted) {
    const inner = v.substring(1, v.length - 1);
    if (QUOTED_BOOL_COMPAT.has(inner)) {
      return out; // 内核吃得下
    }
    const lower = inner.toLowerCase();
    if (!QUOTED_BOOL_FATAL.has(lower)) {
      return out;
    }
    out.fatal = true;
    out.canonical = (lower === 'true' || lower === '1') ? 'true' : 'false';
    return out;
  }
  // 裸写：只有整数会炸（!!int into bool）。0/1 语义唯一 → 可安全归一；
  // 其它整数意图不明 → 致命但不可猜。
  if (/^-?\d+$/.test(v)) {
    out.fatal = true;
    if (v === '1') {
      out.canonical = 'true';
    } else if (v === '0') {
      out.canonical = 'false';
    } else {
      out.ambiguous = true;
    }
    return out;
  }
  return out;
}

/** flow map 内、指定子键集合中，值会让内核在 bool 目标上炸掉的键名列表 */
function flowFatalBools(text: string, childKeys: Set<string>): string[] {
  const trimmed = text.trim();
  if (!trimmed.startsWith('{')) {
    return [];
  }
  const end = trimmed.lastIndexOf('}');
  if (end <= 0) {
    return [];
  }
  const inner = trimmed.substring(1, end);
  const hits: string[] = [];
  for (const item of splitFlowItems(inner)) {
    const colon = topLevelColon(item);
    if (colon <= 0) {
      continue;
    }
    const key = unquote(item.substring(0, colon));
    if (!childKeys.has(key)) {
      continue;
    }
    const value = item.substring(colon + 1).trim();
    if (judgeBoolLiteral(value).fatal) {
      hits.push(key);
    }
  }
  return hits;
}

/** 修复 flow map 内指定子键的致命布尔写法（`enable: "true"` → `enable: true`）；无命中则原样返回 */
function repairFlowMapBools(text: string, childKeys: Set<string>): string {
  const trimmed = text.trim();
  if (!trimmed.startsWith('{')) {
    return text;
  }
  const end = trimmed.lastIndexOf('}');
  if (end <= 0) {
    return text;
  }
  const inner = trimmed.substring(1, end);
  const kept: string[] = [];
  let changed = false;
  for (const item of splitFlowItems(inner)) {
    const colon = topLevelColon(item);
    if (colon <= 0) {
      kept.push(item.trim());
      continue;
    }
    const key = unquote(item.substring(0, colon));
    const value = item.substring(colon + 1).trim();
    const verdict = childKeys.has(key) ? judgeBoolLiteral(value) : new BoolVerdict();
    if (verdict.canonical.length > 0) {
      changed = true;
      kept.push(`${item.substring(0, colon).trim()}: ${verdict.canonical}`);
    } else {
      kept.push(item.trim());
    }
  }
  if (!changed) {
    return text;
  }
  return `{${kept.join(', ')}}`;
}

/**
 * mapping 容器（一个层级）。
 * 容器由「一个键」打开，容纳它的子键；序列项（`- key: value`）另开一个容器，
 * 否则两个列表项的同名键会被误判成重复键。
 */
class Container {
  /** 容器开启时的缩进（根容器 = -1） */
  indent: number = -1;
  /** 容器内键的路径前缀（根容器 = ''） */
  path: string = '';
  /** 容器内已出现的键 */
  keys: string[] = [];

  has(key: string): boolean {
    return this.keys.indexOf(key) >= 0;
  }

  add(key: string): void {
    this.keys.push(key);
  }
}

/** 去掉行尾注释（只认「前导空白 + #」的形式，避免误伤 URL 里的 #） */
function stripTrailingComment(value: string): string {
  let quote = '';
  for (let i = 0; i < value.length; i++) {
    const ch = value.charAt(i);
    if (quote.length > 0) {
      if (ch === quote) {
        quote = '';
      }
      continue;
    }
    if (ch === '"' || ch === '\'') {
      quote = ch;
      continue;
    }
    if (ch === '#' && i > 0 && (value.charAt(i - 1) === ' ' || value.charAt(i - 1) === '\t')) {
      return value.substring(0, i);
    }
  }
  return value;
}

/** 去引号 */
function unquote(value: string): string {
  const v = value.trim();
  if (v.length >= 2) {
    const first = v.charAt(0);
    const last = v.charAt(v.length - 1);
    if ((first === '"' && last === '"') || (first === '\'' && last === '\'')) {
      return v.substring(1, v.length - 1);
    }
  }
  return v;
}

/** 行首缩进（tab 按 1 空格计） */
function indentOf(line: string): number {
  let n = 0;
  for (let i = 0; i < line.length; i++) {
    const ch = line.charAt(i);
    if (ch === ' ' || ch === '\t') {
      n++;
    } else {
      break;
    }
  }
  return n;
}

/** 是否空行/注释行 */
function isBlankOrComment(line: string): boolean {
  const t = line.trim();
  return t.length === 0 || t.charAt(0) === '#';
}

/** 找第一个「顶层」冒号的位置（顶层 = 不在引号内、不在嵌套集合内）；找不到返回 -1 */
function topLevelColon(text: string): number {
  let depth = 0;
  let quote = '';
  for (let i = 0; i < text.length; i++) {
    const ch = text.charAt(i);
    if (quote.length > 0) {
      if (ch === quote) {
        quote = '';
      }
      continue;
    }
    if (ch === '"' || ch === '\'') {
      quote = ch;
      continue;
    }
    if (ch === '{' || ch === '[') {
      depth++;
      continue;
    }
    if (ch === '}' || ch === ']') {
      depth--;
      continue;
    }
    if (ch === ':' && depth === 0) {
      return i;
    }
  }
  return -1;
}

/** 按顶层逗号切分 flow 集合内部 */
function splitFlowItems(inner: string): string[] {
  const items: string[] = [];
  let depth = 0;
  let quote = '';
  let current = '';
  for (let i = 0; i < inner.length; i++) {
    const ch = inner.charAt(i);
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
      continue;
    }
    if (ch === '{' || ch === '[') {
      depth++;
      current += ch;
      continue;
    }
    if (ch === '}' || ch === ']') {
      depth--;
      current += ch;
      continue;
    }
    if (ch === ',' && depth === 0) {
      items.push(current);
      current = '';
      continue;
    }
    current += ch;
  }
  if (current.trim().length > 0) {
    items.push(current);
  }
  return items;
}

/** flow map 文本（形如 `{a: 1, b: {c: 2}}`）→ 顶层重复键名列表 */
function flowDuplicateKeys(text: string): string[] {
  const trimmed = text.trim();
  if (!trimmed.startsWith('{')) {
    return [];
  }
  const end = trimmed.lastIndexOf('}');
  if (end <= 0) {
    return [];
  }
  const inner = trimmed.substring(1, end);
  const seen: string[] = [];
  const dups: string[] = [];
  for (const item of splitFlowItems(inner)) {
    const colon = topLevelColon(item);
    if (colon <= 0) {
      continue;
    }
    const key = unquote(item.substring(0, colon));
    if (key.length === 0) {
      continue;
    }
    if (seen.indexOf(key) >= 0) {
      if (dups.indexOf(key) < 0) {
        dups.push(key);
      }
    } else {
      seen.push(key);
    }
  }
  return dups;
}

/** 递归找出 flow map 内部（含嵌套）的全部重复键 */
function collectFlowDuplicates(text: string, out: string[]): void {
  const trimmed = text.trim();
  if (!trimmed.startsWith('{')) {
    return;
  }
  const end = trimmed.lastIndexOf('}');
  if (end <= 0) {
    return;
  }
  const inner = trimmed.substring(1, end);
  for (const item of splitFlowItems(inner)) {
    const colon = topLevelColon(item);
    if (colon <= 0) {
      continue;
    }
    const value = item.substring(colon + 1).trim();
    if (value.startsWith('{') || value.startsWith('[')) {
      collectFlowDuplicates(value, out);
    }
  }
  for (const d of flowDuplicateKeys(trimmed)) {
    if (out.indexOf(d) < 0) {
      out.push(d);
    }
  }
}

/**
 * 重建 flow map：保留每个键的**首个** pair，删掉后面的重复 pair；嵌套 flow map 递归处理。
 */
function repairFlowMap(text: string, dropped: string[]): string {
  const trimmed = text.trim();
  if (!trimmed.startsWith('{')) {
    return text;
  }
  const end = trimmed.lastIndexOf('}');
  if (end <= 0) {
    return text;
  }
  const inner = trimmed.substring(1, end);
  const seen: string[] = [];
  const kept: string[] = [];
  for (const item of splitFlowItems(inner)) {
    const colon = topLevelColon(item);
    if (colon <= 0) {
      kept.push(item.trim());
      continue;
    }
    const key = unquote(item.substring(0, colon));
    if (key.length > 0 && seen.indexOf(key) >= 0) {
      dropped.push(key);
      continue;
    }
    if (key.length > 0) {
      seen.push(key);
    }
    const value = item.substring(colon + 1).trim();
    let fixedValue = value;
    if (value.startsWith('{')) {
      fixedValue = repairFlowMap(value, dropped);
    }
    kept.push(`${item.substring(0, colon).trim()}: ${fixedValue}`);
  }
  return `{${kept.join(', ')}}`;
}

/** 修复一行里出现的所有最外层 flow map（嵌套由 repairFlowMap 递归处理） */
function repairLineFlowMaps(line: string, dropped: string[]): string {
  if (line.indexOf('{') < 0) {
    return line;
  }
  let out = '';
  let i = 0;
  let changed = false;
  while (i < line.length) {
    const ch = line.charAt(i);
    if (ch !== '{') {
      out += ch;
      i++;
      continue;
    }
    let depth = 0;
    let quote = '';
    let close = -1;
    for (let j = i; j < line.length; j++) {
      const c = line.charAt(j);
      if (quote.length > 0) {
        if (c === quote) {
          quote = '';
        }
        continue;
      }
      if (c === '"' || c === '\'') {
        quote = c;
        continue;
      }
      if (c === '{') {
        depth++;
      } else if (c === '}') {
        depth--;
        if (depth === 0) {
          close = j;
          break;
        }
      }
    }
    if (close < 0) {
      out += line.substring(i);
      break;
    }
    const segment = line.substring(i, close + 1);
    const fixed = repairFlowMap(segment, dropped);
    if (fixed !== segment) {
      changed = true;
    }
    out += fixed;
    i = close + 1;
  }
  return changed ? out : line;
}

/** 校验器 */
export class ConfigValidator {
  /**
   * 严格层：只报问题，不改文本。
   * @param text 完整配置文本
   */
  static validate(text: string): ConfigValidationResult {
    const result = new ConfigValidationResult();
    const lines = text.split('\n');
    const root = new Container();
    root.indent = -1;
    root.path = '';
    const stack: Container[] = [root];
    let inRules = false;

    for (let idx = 0; idx < lines.length; idx++) {
      const line = lines[idx];
      if (isBlankOrComment(line)) {
        continue;
      }
      const rawIndent = indentOf(line);
      const body = line.trim();

      // ── 序列项 ──
      if (body.startsWith('- ')) {
        const content = body.substring(2).trim();
        if (inRules && rawIndent > 0) {
          // rules 段：列表项必须是纯字符串（`- - RULE` → 嵌套 seq → 整份拒载）
          if (content.startsWith('- ') || content.startsWith('{') || content.startsWith('[')) {
            const issue = new ConfigIssue();
            issue.kind = ConfigIssueKind.NESTED_SEQ;
            issue.line = idx + 1;
            issue.key = 'rules';
            issue.detail = 'rules 段出现嵌套序列/集合，内核会报 cannot unmarshal !!seq into string';
            result.issues.push(issue);
          }
        }
        if (content.startsWith('{')) {
          const dups: string[] = [];
          collectFlowDuplicates(content, dups);
          if (dups.length > 0) {
            const issue = new ConfigIssue();
            issue.kind = ConfigIssueKind.DUPLICATE_KEY_FLOW;
            issue.line = idx + 1;
            issue.key = dups.join(', ');
            issue.detail = `flow map 内重复键（${dups.join(', ')}），内核会报 mapping key already defined`;
            result.issues.push(issue);
          }
          continue;
        }
        // `- key: value` → 该序列项自己的 mapping
        const colon = topLevelColon(content);
        if (colon <= 0) {
          continue;
        }
        const key = unquote(content.substring(0, colon));
        if (key.length === 0) {
          continue;
        }
        // 序列项容器：与外层容器同路径前缀，但独立持键（否则不同项的同名键会互相打架）
        while (stack.length > 1 && stack[stack.length - 1].indent > rawIndent) {
          stack.pop();
        }
        const item = new Container();
        item.indent = rawIndent + 1;
        item.path = stack[stack.length - 1].path;
        stack.push(item);
        ConfigValidator.applyKey(stack, item, key, content.substring(colon + 1).trim(),
          rawIndent + 2, idx + 1, result);
        continue;
      }

      // ── 普通键行 ──
      const colon = topLevelColon(body);
      if (colon <= 0) {
        continue;
      }
      const key = unquote(body.substring(0, colon));
      if (key.length === 0) {
        continue;
      }
      const value = stripTrailingComment(body.substring(colon + 1)).trim();
      if (rawIndent === 0) {
        inRules = key === 'rules';
      }
      // 弹出被本行关闭的容器（缩进 >= 本行缩进的容器已结束）
      while (stack.length > 1 && stack[stack.length - 1].indent >= rawIndent) {
        stack.pop();
      }
      ConfigValidator.applyKey(stack, stack[stack.length - 1], key, value, rawIndent, idx + 1, result);
    }

    result.ok = result.blocking().length === 0;
    return result;
  }

  /**
   * 受控降级层：能降级的问题就地降级，再重新校验。
   * @param text 完整配置文本
   */
  static repair(text: string): ConfigValidationResult {
    const first = ConfigValidator.validate(text);
    if (first.issues.length === 0) {
      // 没有问题：文本原样返回，调用方可以直接用 result.text 写盘
      first.text = text;
      return first;
    }
    const lines = text.split('\n');
    const dropLines: Set<number> = new Set<number>();
    const droppedFlowKeys: string[] = [];
    const root = new Container();
    root.indent = -1;
    root.path = '';
    const stack: Container[] = [root];

    for (let idx = 0; idx < lines.length; idx++) {
      const line = lines[idx];
      if (isBlankOrComment(line)) {
        continue;
      }
      const rawIndent = indentOf(line);
      const body = line.trim();

      if (body.startsWith('- ')) {
        const content = body.substring(2).trim();
        if (content.startsWith('{')) {
          const fixed = repairLineFlowMaps(content, droppedFlowKeys);
          const at = line.indexOf(content);
          if (fixed !== content && at >= 0) {
            lines[idx] = line.substring(0, at) + fixed;
          }
          continue;
        }
        const colon = topLevelColon(content);
        if (colon <= 0) {
          continue;
        }
        const key = unquote(content.substring(0, colon));
        if (key.length === 0) {
          continue;
        }
        while (stack.length > 1 && stack[stack.length - 1].indent > rawIndent) {
          stack.pop();
        }
        const item = new Container();
        item.indent = rawIndent + 1;
        item.path = stack[stack.length - 1].path;
        stack.push(item);
        ConfigValidator.applyKeyRepair(stack, item, key, content.substring(colon + 1).trim(),
          rawIndent + 2, idx, lines, dropLines);
        continue;
      }

      const colon = topLevelColon(body);
      if (colon <= 0) {
        continue;
      }
      const key = unquote(body.substring(0, colon));
      if (key.length === 0) {
        continue;
      }
      const value = stripTrailingComment(body.substring(colon + 1)).trim();
      if (value.startsWith('{')) {
        // 值是 flow map（如 ws-opts: {path: /a, path: /b}）→ 就地重建，删掉重复 pair
        const fixed = repairLineFlowMaps(value, droppedFlowKeys);
        if (fixed !== value) {
          const head = body.substring(0, colon);
          lines[idx] = line.substring(0, line.indexOf(body)) + `${head}: ${fixed}`;
        }
      }
      while (stack.length > 1 && stack[stack.length - 1].indent >= rawIndent) {
        stack.pop();
      }
      ConfigValidator.applyKeyRepair(stack, stack[stack.length - 1], key, value,
        rawIndent, idx, lines, dropLines);
    }

    // 应用：删掉重复键行（含其子行）
    const kept: string[] = [];
    for (let idx = 0; idx < lines.length; idx++) {
      if (dropLines.has(idx)) {
        continue;
      }
      kept.push(lines[idx]);
    }
    const repairedText = kept.join('\n');
    const second = ConfigValidator.validate(repairedText);

    const result = new ConfigValidationResult();
    result.issues = first.issues;
    // 复校验里仍然存在的布尔问题 → 说明这一处**降不掉**（如 `allow-lan: 2`：
    // 内核拒载，但取值意图无法判定，不擅自改写）→ 必须保持「未降级」＝阻塞。
    const remainingBoolKeys: Set<string> = new Set<string>();
    for (const issue of second.issues) {
      if (issue.kind === ConfigIssueKind.BOOL_AS_STR) {
        remainingBoolKeys.add(issue.key);
      }
    }
    for (const issue of first.issues) {
      if (issue.kind === ConfigIssueKind.DUPLICATE_KEY
        || issue.kind === ConfigIssueKind.DUPLICATE_KEY_FLOW) {
        issue.degraded = true;
      } else if (issue.kind === ConfigIssueKind.BOOL_AS_STR) {
        issue.degraded = !remainingBoolKeys.has(issue.key);
      }
    }
    // 降级后仍然存在、且无法降级的问题 → 阻塞
    for (const issue of second.issues) {
      if (issue.kind === ConfigIssueKind.BOOL_AS_STR) {
        // 第一遍已有同 key 的布尔问题 → 不重复登记（否则同一条问题在摘要里出现两次）
        let dup = false;
        for (const prev of first.issues) {
          if (prev.kind === ConfigIssueKind.BOOL_AS_STR && prev.key === issue.key) {
            dup = true;
            break;
          }
        }
        if (dup) {
          continue;
        }
      }
      result.issues.push(issue);
    }
    result.dropped = dropLines.size + droppedFlowKeys.length;
    result.degraded = result.dropped > 0;
    result.text = repairedText;
    result.ok = second.blocking().length === 0;
    if (result.dropped > 0) {
      AppLogger.warn(TAG, `degraded ${result.dropped} duplicate/ill-typed entr(ies) to keep the config loadable`);
    }
    return result;
  }

  /** 处理一个键：重复键检测 + 布尔字面量检测 + 值里的 flow map 检测 */
  private static applyKey(stack: Container[], container: Container, key: string, value: string,
    keyIndent: number, lineNo: number, result: ConfigValidationResult): void {
    if (container.has(key)) {
      const issue = new ConfigIssue();
      issue.kind = ConfigIssueKind.DUPLICATE_KEY;
      issue.line = lineNo;
      issue.key = key;
      issue.detail = `同层级重复键「${key}」，内核会报 mapping key already defined`;
      result.issues.push(issue);
    } else {
      container.add(key);
    }
    const path = ConfigValidator.joinPath(container.path, key);
    if (BOOL_PATHS.has(path)) {
      const verdict = judgeBoolLiteral(value);
      if (verdict.fatal) {
        const issue = new ConfigIssue();
        issue.kind = ConfigIssueKind.BOOL_AS_STR;
        issue.line = lineNo;
        issue.key = path;
        issue.detail = verdict.ambiguous
          ? `布尔字段写成裸数字 ${value.trim()}，内核会报 cannot unmarshal !!int into bool（整份拒载）；`
            + `取值意图无法判定，不擅自改写`
          : `布尔字段写成带引号的 "${value.trim()}"，内核会报 cannot unmarshal !!str into bool（整份拒载）`;
        result.issues.push(issue);
      }
    }
    if (value.startsWith('{')) {
      const dups: string[] = [];
      collectFlowDuplicates(value, dups);
      if (dups.length > 0) {
        const issue = new ConfigIssue();
        issue.kind = ConfigIssueKind.DUPLICATE_KEY_FLOW;
        issue.line = lineNo;
        issue.key = dups.join(', ');
        issue.detail = `flow map 内重复键（${dups.join(', ')}），内核会报 mapping key already defined`;
        result.issues.push(issue);
      }
      const childKeys = BOOL_CHILD_PATHS.get(path);
      if (childKeys !== undefined) {
        const badBools = flowFatalBools(value, childKeys);
        if (badBools.length > 0) {
          const issue = new ConfigIssue();
          issue.kind = ConfigIssueKind.BOOL_AS_STR;
          issue.line = lineNo;
          issue.key = `${path}.${badBools.join(', ')}`;
          issue.detail = `flow map 里的布尔字段写法会让内核报 cannot unmarshal into bool（整份拒载）：${badBools.join(', ')}`;
          result.issues.push(issue);
        }
      }
    }
    // 键开启的子容器（缩进 = 该键的缩进 → 遇到同级键时它会被正确关闭）
    const child = new Container();
    child.indent = keyIndent;
    child.path = path;
    stack.push(child);
  }

  /** 降级版：重复键 → 删本行及子行；布尔字面量 → 就地改写 */
  private static applyKeyRepair(stack: Container[], container: Container, key: string, value: string,
    keyIndent: number, idx: number, lines: string[], dropLines: Set<number>): void {
    if (container.has(key)) {
      dropLines.add(idx);
      const rawIndent = indentOf(lines[idx]);
      for (let j = idx + 1; j < lines.length; j++) {
        const next = lines[j];
        if (isBlankOrComment(next)) {
          continue;
        }
        if (indentOf(next) <= rawIndent) {
          break;
        }
        dropLines.add(j);
      }
    } else {
      container.add(key);
    }
    const path = ConfigValidator.joinPath(container.path, key);
    if (BOOL_PATHS.has(path)) {
      const verdict = judgeBoolLiteral(value);
      if (verdict.canonical.length > 0) {
        const line = lines[idx];
        const trimmed = line.trim();
        const colon = topLevelColon(trimmed);
        if (colon > 0) {
          // 保留原缩进（直接用 trim 后的文本会丢层级，YAML 层级一乱整份拒载）
          const pad = line.substring(0, line.length - trimmed.length);
          lines[idx] = `${pad}${trimmed.substring(0, colon)}: ${verdict.canonical}`;
        }
      }
      // verdict.ambiguous（裸数字且意图不明）→ 不猜、不改：留到复校验时判为阻塞
    }
    if (value.startsWith('{')) {
      const childKeys = BOOL_CHILD_PATHS.get(path);
      if (childKeys !== undefined) {
        const fixedMap = repairFlowMapBools(value, childKeys);
        if (fixedMap !== value) {
          const line = lines[idx];
          const at = line.indexOf(value);
          if (at >= 0) {
            lines[idx] = line.substring(0, at) + fixedMap + line.substring(at + value.length);
          }
        }
      }
    }
    const child = new Container();
    child.indent = keyIndent;
    child.path = path;
    stack.push(child);
  }

  /** 路径拼接 */
  private static joinPath(prefix: string, key: string): string {
    return prefix.length > 0 ? `${prefix}.${key}` : key;
  }
}
