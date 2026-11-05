/**
 * 订阅原文 → 运行配置的合并器（FlClash `mergeProfileBase` 的 ArkTS 对等实现）
 *
 * 来源：FlClash `core/profile_base.go:120-260`（mergeProfileBase / appendRules）。
 *
 * FlClash 的语义（必须逐条一致）：
 *  · 以 **overlay**（App 生成的运行配置）为根文档；
 *  · 从订阅原文整体搬入 `proxies` / `proxy-groups` / `sub-rules` 三段；
 *  · `rules` = overlay.rules **在前** + 原文 rules **在后**；
 *  · 其余键以 overlay 为准（原文的 tun / mixed-port / external-controller / mode
 *    等运行期参数一律被 overlay 覆盖，绝不外泄）。
 *
 * 本实现的平台差异（不算偏离，原因写在这里）：
 *  · 设备侧没有 FlClash 的 provider 预取目录，原文 `proxy-providers` 整段搬入；
 *    `rule-providers` 与 overlay 按名称合并，overlay 同名块优先
 *    （相对 path 由内核按自身 home 解析）；
 *    只用 provider 不给静态 proxies 的订阅由调用方先做内联。
 *  · 原文 `dns.enable == true` 时整段 dns 用原文（对齐 FlClash
 *    `_makeRealProfileTask` 的 `isEnableDns` 语义）。
 *  · 原文 `hosts` / `sniffer` 在 overlay 未声明时搬入。
 *
 * 纯字符串处理，零系统依赖 ⇒ 可在 Node 里真跑（tools/true-chain-harness）。
 */
import { YamlMerger } from '../services/YamlMerger';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'ProfileConfigMerger';

/**
 * 需要「按键并集」而不是「整段替换」的 provider 段。
 *
 * 为什么两个都要：provider 是**按名字寻址的命名空间** —— overlay 的 rules 里有
 * `RULE-SET,hyper-adrules`、原文 rules 里也可能引用自己的 provider 名；声明段
 * 少一个，内核就整份拒载（`rule set [x] not found`，2026-10-23 真机报障）。
 * 所以两段都是「overlay 优先 + 原文补齐」的并集，而不是二选一。
 */
const PROVIDER_MERGE_KEYS: string[] = ['proxy-providers', 'rule-providers'];

/** 原文里允许进入运行配置的顶层键（其余一律丢弃，由 overlay 决定）。 */
const PROFILE_KEYS: string[] = [
  'proxies',
  'proxy-groups',
  'sub-rules',
  'tunnels',
  'listeners'
];

/** overlay 里必须被原文替换掉的键（先删后追加）。 */
const REPLACE_KEYS: string[] = [
  'proxies',
  'proxy-groups',
  'sub-rules',
  'proxy-providers',
  'rule-providers',
  'tunnels',
  'listeners',
  'rules'
];

// Only listener ownership and platform integration belong to the application.
// Everything else is a native mihomo capability, including future config keys.
const RUNTIME_KEYS: string[] = [
  'mixed-port', 'port', 'socks-port', 'redir-port', 'tproxy-port', 'allow-lan', 'bind-address',
  'external-controller', 'external-controller-tls', 'external-controller-unix',
  'external-controller-pipe', 'external-controller-cors', 'secret', 'external-ui',
  'external-ui-url', 'external-ui-name', 'authentication', 'skip-auth-prefixes',
  'lan-allowed-ips', 'lan-disallowed-ips', 'tun', 'interface-name', 'routing-mark',
  'find-process-mode', 'ipv6', 'mode', 'log-level', 'dns', 'hosts'
];

export class ProfileMergeResult {
  ok: boolean = false;
  yaml: string = '';
  error: string = '';
  /** 诊断：从原文搬入了哪些段（逗号分隔） */
  applied: string = '';
  /** 原文节点条目数（`proxies:` 下的 `- ` 计数，仅用于日志） */
  profileProxyItems: number = 0;
}

/** smart 组注入结果（ok=false 时 reason 说明跳过原因，注入降级为节点钉选） */
export class SmartInjectResult {
  ok: boolean = false;
  yaml: string = '';
  reason: string = '';
}

/** 把节点补进指定策略组的结果（ok=false 时 yaml 原样返回，调用方降级处理） */
export class GroupMemberResult {
  ok: boolean = false;
  yaml: string = '';
  reason: string = '';
}

export class ProfileConfigMerger {
  /** Final platform invariants, after every user/profile merge (never change DNS upstreams). */
  static enforceTunnelContract(yaml: string, mtu: number, ipv6Enabled: boolean): string {
    let out = yaml;
    // mihomo's cache.db indexes selections by group name only. Two subscriptions
    // with the same names otherwise inherit each other's routing (including DIRECT).
    // The app restores explicit choices using profileId + group instead.
    const profile = ProfileConfigMerger.sectionText(out, 'profile');
    const profileLines = (profile.length > 0 ? profile.split('\n') : ['profile:'])
      .filter((line: string): boolean => !/^  store-selected:/.test(line));
    profileLines.splice(1, 0, '  store-selected: false');
    out = ProfileConfigMerger.removeKey(out, 'profile') + '\n' + profileLines.join('\n') + '\n';
    const tun = ProfileConfigMerger.sectionText(out, 'tun');
    if (tun.length > 0) {
      const clean = tun.split('\n').filter((line: string): boolean => !/^  mtu:/.test(line));
      clean.splice(1, 0, `  mtu: ${mtu}`);
      out = ProfileConfigMerger.removeKey(out, 'tun') + '\n' + clean.join('\n');
    }
    const dns = ProfileConfigMerger.sectionText(out, 'dns');
    if (dns.length === 0) { throw new Error('运行配置缺少 DNS 段'); }
    const read = (key: string): string => {
      for (const line of dns.split('\n')) {
        const match = line.match(new RegExp('^  ' + key + ':\\s*(.*?)\\s*(?:#.*)?$'));
        if (match !== null) { return match[1].replace(/^["']|["']$/g, '').trim(); }
      }
      return '';
    };
    const mode = read('enhanced-mode');
    const fake = mode === 'fake-ip';
    const dns6 = ipv6Enabled && fake && read('ipv6') !== 'false';
    // On affected OHOS versions only the ULA on-link route is reliable. Real AAAA
    // cannot be declared captured. Preserve explicit redir-host, use A-only DNS there.
    if (ipv6Enabled && !fake) {
      AppLogger.warn(TAG, 'real-address DNS mode: IPv6 answers disabled on this platform; DNS mode/upstreams preserved');
    }
    const lines = dns.split('\n').filter((line: string): boolean =>
      !/^  (ipv6|fake-ip-range6):/.test(line));
    lines.splice(1, 0, '  ipv6: ' + (dns6 ? 'true' : 'false'));
    if (dns6) { lines.splice(2, 0, '  fake-ip-range6: fdfe:dcba:9876::/64'); }
    out = ProfileConfigMerger.removeKey(out, 'dns') + '\n' + lines.join('\n') + '\n';
    return out;
  }

  /**
   * 原文 dns 接管时，保证它是 **fake-ip** 模式。
   *
   * 为什么（2026-10-22 真机，ikuuu 订阅打不开 YouTube）：
   *  · 大量机场的 dns 段只写国内解析器（119.29/223.5/国内 DoT），且不写 enhanced-mode，
   *    内核于是按真实 IP 解析 —— 境外域名被污染成国内 IP。
   *  · 生成配置的第一条规则是 `GEOIP,CN,DIRECT`，污染 IP 直接命中 → 直连 → 打不开，
   *    而节点本身完全正常（内核直接对 youtube.com 测速 415ms 通）。
   *  · 补成 fake-ip 后，系统/App 拿到的是 fake-ip，域名交给节点侧解析，
   *    既不中 GEOIP 误判也不吃污染结果。原文若显式写了 enhanced-mode 则一律尊重原文。
   */

  /** YAML 单引号标量（名字里可能出现引号/冒号/emoji，必须转义） */

  /**
   * 确保某节点是目标策略组的**真实成员**（原文接管模式下组常只列一部分节点）。
   *
   * ## 为什么需要它（2026-10-28 真机：选香港 → 连上变日本）
   *
   * 机场的 `proxy-groups` 只把部分节点列进主选择组；另外一些节点在 `proxies:` 里
   * 存在、App 节点页也选得到，但**不在组的成员表**里。此时 `PUT /proxies/<组>` 必
   * 被内核拒（不是成员），旧实现于是静默换成「组内首个叶子」。
   * 用户意图是明确的：他选的那个节点。内核允许 select 组把任意 `proxies` 成员列为
   * 成员，所以正确做法是把它补进组首位（与生成器 `unshift` 同一语义），而不是换节点。
   *
   * 只做「插入一行成员」，不重排、不重写其他段；任何结构不符合预期都返回 ok=false
   * 由调用方降级（绝不把坏 YAML 交出去：内核对重复键是整份拒载）。
   */

  /**
   * 给「裸节点表」补上最简可用的分流骨架。
   *
   * 触发条件：原文有 `proxies`，但**既没有 proxy-groups 也没有 proxy-providers**
   * （也没有 rules）。这类文本不是一份完整订阅，只描述节点。
   * 补出来的骨架刻意保持最小、可预期：
   *   手动选择(select, 全部节点 + DIRECT) / 自动选择(url-test) / rules: MATCH,手动选择
   * 原文若已有任何组或规则，本方法原样返回，不介入。
   */

  /**
   * 把 smart 组注入订阅原文的分流结构（2026-10-25，「自动选择」在原文接管模式下
   * 从未生效的定案修复）：原文的 proxy-groups 整段顶掉生成器的同名段 → 生成器的
   * ♻️ smart 组永远进不了最终配置，自动模式只能退化成钉选具体节点。
   *
   * 注入语义（用户拍板：插入主选择组首位）：
   *   ① 主选择组 = 原文 rules 里最后一条 `MATCH,<target>` 的 target；
   *   ② target 必须是 proxy-groups 里真实存在且 type: select 的组（url-test 等
   *      自动组不可钉选，注入进去也没有语义）；
   *   ③ 把 smart 组**首位**插进该组的 proxies 成员（内核默认即走 smart；用户仍可
   *      在该组手动固定任何节点/子组——与生成器给 PROXY 组的做法同构）；
   *   ④ smart 组定义整体追加到 proxy-groups 段尾，成员 = 原文自己的节点名
   *      （天然单订阅，满足「选了哪个订阅就只在它下面优选」）。
   * 任一前提不成立 → ok=false 原样返回（自动模式降级为节点钉选，绝不破坏原文）。
   *
   * @param yaml 合并后的最终配置（将被注入修改）
   * @param smartName smart 组名（须与生成器/钉选侧一致）
   * @param smartHead smart 组的头部键值行（name/type/uselightgbm/url/exclude-filter...，
   *                  由调用方按用户设置生成；成员 proxies 由本函数按原文节点补齐）
   */

  /** 原文是否显式启用 dns（`dns.enable: true`）。 */

  /** 拆开 DNS 行内 map 的直接成员；引号、嵌套 map/list 中的逗号不分割。 */
  private static dnsFlowLines(raw: string): string[] {
    const fields: string[] = [];
    let start: number = 1;
    let depth: number = 0;
    let quote: string = '';
    for (let i = 1; i < raw.length; i++) {
      const ch: string = raw.charAt(i);
      if (quote.length > 0) {
        if (quote === '"' && ch === '\\') { i++; continue; }
        if (ch === quote) {
          if (quote === "'" && raw.charAt(i + 1) === "'") { i++; continue; }
          quote = '';
        }
        continue;
      }
      if (ch === '"' || ch === "'") { quote = ch; continue; }
      if (ch === '[' || ch === '{') { depth++; continue; }
      if (ch === ']' || (ch === '}' && depth > 0)) { depth--; continue; }
      if ((ch === ',' || ch === '}') && depth === 0) {
        const field: string = raw.substring(start, i).trim();
        if (field.length > 0) { fields.push('  ' + field); }
        start = i + 1;
        if (ch === '}') { return fields; }
      }
    }
    return [];
  }

  /** 顶层是否存在该键（含 `key: []` / `key:` 空值写法）。 */
  static hasKey(yaml: string, key: string): boolean {
    const lines = yaml.split('\n');
    const prefix = `${key}:`;
    for (const raw of lines) {
      const line = raw.startsWith('\uFEFF') ? raw.substring(1) : raw;
      if (line.startsWith(' ') || line.startsWith('\t')) {
        continue;
      }
      if (line.trim().startsWith(prefix)) {
        return true;
      }
    }
    return false;
  }

  /**
   * 取整段（含 `key:` 头，body 缩进已归一成 2 空格基准）。
   * 键不存在返回空串；键存在但为空（`proxies: []`）返回 `key: []` 这类原样单行。
   */
  static sectionText(yaml: string, key: string): string {
    if (!ProfileConfigMerger.hasKey(yaml, key)) {
      return '';
    }
    const lines = yaml.replace(/\r/g, '').split('\n');
    const body: string[] = [];
    let head = '';
    let collecting = false;
    for (const raw of lines) {
      const line = raw.replace(/^\uFEFF/, '');
      if (!collecting) {
        if (line.startsWith(`${key}:`)) { head = line; collecting = true; }
        continue;
      }
      if (line.trim().length > 0 && !line.startsWith(' ') && !line.startsWith('\t')
        && !line.trimStart().startsWith('#') && !line.startsWith('-')) { break; }
      body.push(line);
    }
    const inline: string = head.substring(key.length + 1).trim();
    if (inline.startsWith('{')) {
      const fields: string[] = ProfileConfigMerger.dnsFlowLines(inline);
      return fields.length > 0 ? [`${key}:`].concat(fields).join('\n') : head;
    }
    if (/^[|>][+-]?\d?\s*(?:#.*)?$/.test(inline)) { return [head].concat(body).join('\n'); }
    // `dns: # comment` 仍是块式段，不能把其子键截掉。
    if (inline.length > 0 && !inline.startsWith('#')) { return head; }
    if (inline.startsWith('#')) { head = `${key}:`; }
    let indent = 999999;
    for (const line of body) {
      if (line.trim().length > 0 && !line.trimStart().startsWith('#')) {
        indent = Math.min(indent, line.length - line.trimStart().length);
      }
    }
    if (indent === 999999) { return head; }
    const normalized: string[] = [head];
    for (const line of body) {
      if (line.trim().length > 0) { normalized.push('  ' + line.substring(Math.min(indent, line.length - line.trimStart().length))); }
    }
    return normalized.join('\n');
  }

  /**
   * 合并。overlay = TunBox 生成的完整运行配置，profile = 订阅原文。
   *
   * `allowProfileDns=true`（DNS 覆写关闭）时采用订阅原文 DNS；
   * `allowProfileDns=false`（DNS 覆写开启）时保留应用生成的 DNS。
   */

  /**
   * 按 provider 顶层条目拆完整块，不重排字段或压平 payload / header 等嵌套内容。
   * 这里直接取原始缩进；通用序列分节归一化会把嵌套 payload 当作分节基准。
   *
   * @param key 顶层段名（`proxy-providers` / `rule-providers`）
   */

  /** provider 名支持带引号的冒号、点号、中文和 YAML 单引号转义。 */

  /** 取某段的主体行（带 2 空格缩进），去空行。 */

  /** 规则行的目标（最后一段）。`TYPE,args...,TARGET`。 */

  /** 目标是否存在（组名 / 节点名 / 内置策略）。 */


  /**
   * 最终配置里可被规则引用的目标集合：
   * 原文 `proxies` 的 name、`proxy-groups` 的 name，加上内核内置策略。
   */

  /** 从条目行里取 `name:`（块式 `- name: X` 或流式 `- {name: X, ...}`）。 */


  private static removeKey(yaml: string, key: string): string {
    if (!ProfileConfigMerger.hasKey(yaml, key)) {
      return yaml;
    }
    try {
      return YamlMerger.removeSection(yaml, key);
    } catch (e) {
      return yaml;
    }
  }
}
