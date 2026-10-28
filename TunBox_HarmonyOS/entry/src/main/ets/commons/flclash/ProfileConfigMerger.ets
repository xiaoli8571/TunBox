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
  /**
   * 订阅原文是否是内核可解析的 Clash 配置。
   *
   * 等价 FlClash `validateProfile` 第一步（`unmarshalRawConfig` 成功）。这里只判
   * 「有代理定义的顶层 mapping」：含 `proxies:` / `proxy-groups:` /
   * `proxy-providers:` 之一。真正的 schema 校验由内核负责。
   */
  static isKernelLoadableConfig(text: string): boolean {
    if (text.length === 0) {
      return false;
    }
    return ProfileConfigMerger.hasKey(text, 'proxies')
      || ProfileConfigMerger.hasKey(text, 'proxy-groups')
      || ProfileConfigMerger.hasKey(text, 'proxy-providers');
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
  private static ensureFakeIpForProfileDns(dnsSection: string): string {
    const LF: string = String.fromCharCode(10);
    const rawLines: string[] = dnsSection.split(LF);
    // 1) 先**规范化缩进**：原文 dns 段经 extractSection 回来后，子键缩进可能已经丢了
    //    （真机实证：`dns:` 下面直接跟 0 缩进的 `enable: true`，导致这些键跑到顶层，
    //     dns 等于没启用、fake-ip 也不生效 → 污染 IP 命中 GEOIP,CN,DIRECT → 打不开 YouTube）。
    //    这里保证除 `dns:` 头以外，每一行至少 2 空格缩进。
    const lines: string[] = [];
    for (const line of rawLines) {
      const t = line.trimStart();
      if (t.length === 0) {
        continue;
      }
      if (t === 'dns:' || t === 'dns: {}') {
        lines.push('dns:');
        continue;
      }
      const indent = line.length - t.length;
      lines.push(indent >= 2 ? line : '  ' + t);
    }
    if (lines.length === 0) {
      lines.push('dns:');
    }
    // 2) 原文显式写了 enhanced-mode 就完全尊重
    const joined: string = lines.join(LF);
    // sectionText 已把 DNS 直接子键归一到两空格，hasKey 只识别顶层键，不能用在这里。
    const hasChild = (key: string): boolean =>
      lines.some((line: string): boolean => line.startsWith(`  ${key}:`));
    if (hasChild('enhanced-mode')) {
      return joined;
    }
    // 3) 否则补 fake-ip：境外域名交给节点侧解析，不吃国内 DNS 的污染结果
    const extra: string[] = ['  enhanced-mode: fake-ip'];
    if (!hasChild('fake-ip-range')) { extra.push('  fake-ip-range: 198.18.0.1/16'); }
    if (!hasChild('fake-ip-filter')) {
      extra.push('  fake-ip-filter:', '    - "*.lan"', '    - "*.local"',
        '    - localhost.ptlogin2.qq.com', '    - "+.msftconnecttest.com"', '    - "+.msftncsi.com"');
    }
    const head: string[] = lines.slice(0, 1);
    const tail: string[] = lines.slice(1);
    return head.concat(extra).concat(tail).join(LF);
  }

  /** YAML 单引号标量（名字里可能出现引号/冒号/emoji，必须转义） */
  static yamlQuote(value: string): string {
    const sq: string = String.fromCharCode(39);
    return sq + value.split(sq).join(sq + sq) + sq;
  }

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
  static ensureGroupMember(yaml: string, groupName: string, nodeName: string): GroupMemberResult {
    const out = new GroupMemberResult();
    out.yaml = yaml;
    if (groupName.length === 0 || nodeName.length === 0) {
      out.reason = '组名或节点名为空';
      return out;
    }
    const lines: string[] = yaml.replace(/\r/g, '').split('\n');
    const start: number = lines.findIndex((l: string): boolean => l.startsWith('proxy-groups:'));
    if (start < 0) {
      out.reason = '没有 proxy-groups 段';
      return out;
    }
    let end: number = lines.length;
    for (let i = start + 1; i < lines.length; i++) {
      const l: string = lines[i];
      if (l.trim().length > 0 && !l.startsWith(' ') && !l.startsWith('\t')
        && !l.trimStart().startsWith('#')) {
        end = i;
        break;
      }
    }
    // ① 定组项缩进（`- name:` 那一行的前导空格）
    let groupIndent: number = -1;
    for (let i = start + 1; i < end; i++) {
      const m = lines[i].match(/^(\s*)-\s*name:\s*(.+)$/);
      if (m !== null) {
        groupIndent = m[1].length;
        break;
      }
    }
    if (groupIndent < 0) {
      out.reason = '解析不出组项缩进';
      return out;
    }
    // ② 定位目标组块
    let gStart: number = -1;
    let gEnd: number = end;
    for (let i = start + 1; i < end; i++) {
      const m = lines[i].match(/^(\s*)-\s*name:\s*(.+)$/);
      if (m === null || m[1].length !== groupIndent) {
        continue;
      }
      if (gStart >= 0) {
        gEnd = i;
        break;
      }
      const name: string = ProfileConfigMerger.unquote(m[2].trim());
      if (name === groupName) {
        gStart = i;
      }
    }
    if (gStart < 0) {
      out.reason = `找不到策略组 ${groupName}`;
      return out;
    }
    // ③ 已是成员（逐字节比名字，调用方传的就是 YAML 里的写法）
    const memberPrefix: RegExp = /^(\s*)-\s+(.+)$/;
    let proxiesLine: number = -1;
    for (let i = gStart + 1; i < gEnd; i++) {
      const t: string = lines[i].trim();
      if (t === 'proxies:' || t.startsWith('proxies:') ) {
        proxiesLine = i;
        continue;
      }
      const m = lines[i].match(memberPrefix);
      if (m === null) {
        continue;
      }
      if (lines[i].match(/^\s*-\s*name:/) !== null) {
        break;
      }
      const member: string = ProfileConfigMerger.unquote(m[2].trim());
      if (member === nodeName) {
        out.ok = true;
        out.reason = '已是成员';
        return out;
      }
    }
    // ④ 插入成员：优先插到 `proxies:` 列表首位（与生成器 unshift 同语义）
    const indentOf = (line: string): number => line.length - line.trimStart().length;
    const quoted: string = ProfileConfigMerger.yamlQuote(nodeName);
    if (proxiesLine >= 0) {
      const raw: string = lines[proxiesLine];
      const indent: number = indentOf(raw);
      const inline: string = raw.trim().substring('proxies:'.length).trim();
      if (inline.length === 0) {
        lines.splice(proxiesLine + 1, 0, `${' '.repeat(indent + 2)}- ${quoted}`);
      } else if (inline === '[]') {
        lines[proxiesLine] = `${' '.repeat(indent)}proxies:`;
        lines.splice(proxiesLine + 1, 0, `${' '.repeat(indent + 2)}- ${quoted}`);
      } else if (inline.charAt(0) === '[') {
        const body: string = inline.substring(1, inline.length - 1).trim();
        const next: string = body.length === 0 ? quoted : `${quoted}, ${body}`;
        lines[proxiesLine] = `${' '.repeat(indent)}proxies: [${next}]`;
      } else {
        out.reason = 'proxies 段写法无法识别';
        return out;
      }
    } else {
      // 组里还没有成员表：补一个最小的 proxies: 块（放在 name 行之后）
      lines.splice(gStart + 1, 0,
        `${' '.repeat(groupIndent + 2)}proxies:`,
        `${' '.repeat(groupIndent + 4)}- ${quoted}`);
    }
    out.yaml = lines.join('\n');
    out.ok = true;
    out.reason = proxiesLine >= 0 ? '成员已插入组首位' : '已补建成员表';
    return out;
  }

  /**
   * 给「裸节点表」补上最简可用的分流骨架。
   *
   * 触发条件：原文有 `proxies`，但**既没有 proxy-groups 也没有 proxy-providers**
   * （也没有 rules）。这类文本不是一份完整订阅，只描述节点。
   * 补出来的骨架刻意保持最小、可预期：
   *   手动选择(select, 全部节点 + DIRECT) / 自动选择(url-test) / rules: MATCH,手动选择
   * 原文若已有任何组或规则，本方法原样返回，不介入。
   */
  static withSyntheticGroups(profileYaml: string): string {
    if (ProfileConfigMerger.hasKey(profileYaml, 'proxy-groups')
      || ProfileConfigMerger.hasKey(profileYaml, 'proxy-providers')
      || ProfileConfigMerger.hasKey(profileYaml, 'rules')) {
      return profileYaml;
    }
    const LF: string = String.fromCharCode(10);
    const names = YamlMerger.sequenceItemNames(profileYaml, 'proxies');
    if (names.length === 0) {
      return profileYaml;
    }
    const lines: string[] = [profileYaml.trimEnd(), '', 'proxy-groups:',
      '  - name: 手动选择', '    type: select', '    proxies:'];
    for (const n of names) {
      lines.push(`      - ${ProfileConfigMerger.yamlQuote(n)}`);
    }
    lines.push('      - DIRECT');
    // 刻意不写 url：mihomo 的 url-test 默认 URL 就是 generate_204（constant.DefaultURLTestURL），
    // 写死会违反 ND06「测速地址规则常量只能有一处」（真源在 FlclashDelay.FLCLASH_DELAY_URL）。
    lines.push('  - name: 自动选择', '    type: url-test',
      '    interval: 300', '    tolerance: 50', '    proxies:');
    for (const n of names) {
      lines.push(`      - ${ProfileConfigMerger.yamlQuote(n)}`);
    }
    lines.push('rules:', '  - MATCH,手动选择');
    return lines.join(LF);
  }

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
  static injectSmartPrimary(yaml: string, smartName: string, smartHead: string[]): SmartInjectResult {
    const out = new SmartInjectResult();
    out.yaml = yaml;
    if (!ProfileConfigMerger.hasKey(yaml, 'rules')) {
      out.reason = 'no rules section';
      return out;
    }
    // ① 主选择组：最后一条 MATCH 规则的 target（MATCH 是兜底规则，惯例在最后）
    const lines = yaml.replace(/\r/g, '').split('\n');
    let primary = '';
    for (const line of lines) {
      const m = line.trim().match(/^-\s*MATCH\s*,(.+)$/);
      if (m !== null) {
        primary = m[1].trim();
      }
    }
    if (primary.length === 0) {
      out.reason = 'no MATCH rule';
      return out;
    }
    primary = primary.replace(/^["']|["']$/g, '').trim();
    if (primary.length === 0 || primary === 'DIRECT' || primary === 'REJECT') {
      out.reason = `MATCH target not a selector: ${primary}`;
      return out;
    }
    // ② 定位 proxy-groups 段与主选择组块
    const sectionStart = lines.findIndex((l) => l.startsWith('proxy-groups:'));
    if (sectionStart < 0) {
      out.reason = 'no proxy-groups section';
      return out;
    }
    let sectionEnd = lines.length;
    for (let i = sectionStart + 1; i < lines.length; i++) {
      const l = lines[i];
      if (l.trim().length > 0 && !l.startsWith(' ') && !l.startsWith('\t')
        && !l.trimStart().startsWith('#') && !l.startsWith('-')) {
        sectionEnd = i;
        break;
      }
    }
    const namePrefixes = [
      `  - name: ${primary}`,
      `  - name: "${primary}"`,
      `  - name: '${primary}'`
    ];
    let groupStart = -1;
    for (let i = sectionStart + 1; i < sectionEnd; i++) {
      if (namePrefixes.includes(lines[i])) {
        groupStart = i;
        break;
      }
    }
    if (groupStart < 0) {
      out.reason = `primary group not found: ${primary}`;
      return out;
    }
    let groupEnd = sectionEnd;
    for (let i = groupStart + 1; i < sectionEnd; i++) {
      if (lines[i].startsWith('  - ')) {
        groupEnd = i;
        break;
      }
    }
    const groupBody = lines.slice(groupStart, groupEnd);
    const isSelect = groupBody.some((l) => l.trim().replace(/^["']|["']$/g, '') === 'type: select'
      || l.trim() === 'type: select');
    if (!isSelect) {
      out.reason = `primary group not select type: ${primary}`;
      return out;
    }
    // ③ smart 组成员 = 原文自己的节点名（proxies 段的 `- ` 条目，排除空段）
    const memberNames = YamlMerger.sequenceItemNames(yaml, 'proxies');
    if (memberNames.length === 0) {
      out.reason = 'profile has no static proxies (provider-only); smart pool unknown';
      return out;
    }
    // ③b 主选择组首位插入 smart 组
    // ③c 流式成员表（`proxies: [a, b]`）不介入：块/流两种写法并存 = 重复键整份拒载
    const flowProxies = groupBody.some((l) => /^proxies:\s*\[/.test(l.trim()));
    if (flowProxies) {
      out.reason = `primary group uses flow-style proxies: ${primary}`;
      return out;
    }
    const quotedSmart = ProfileConfigMerger.yamlQuote(smartName);
    const proxiesIdx = groupBody.findIndex((l) => l.trim() === 'proxies:');
    if (proxiesIdx >= 0) {
      // 成员缩进必须对齐既有成员（机场风格不一：`- a` 常见 4/6 空格两种，
      // 硬编码 6 空格插进 4 空格序列 = 缩进断裂 → did not find expected key，
      // 2026-10-25 真机实锤 16:33 那份坏配置的第二个雷）。
      let memberIndent = '      ';
      for (let i = proxiesIdx + 1; i < groupBody.length; i++) {
        const l = groupBody[i];
        if (l.trim().length === 0) { continue; }
        if (/^\s*-\s/.test(l)) {
          memberIndent = l.substring(0, l.length - l.trimStart().length);
        }
        break;
      }
      groupBody.splice(proxiesIdx + 1, 0, `${memberIndent}- ${quotedSmart}`);
    } else {
      // 组只有 use:（provider 组）或没写成员：补一个 proxies: 列表，与 use: 并存合法
      groupBody.splice(1, 0, '    proxies:', `      - ${quotedSmart}`);
    }
    // ④ smart 组定义追加到 proxy-groups 段尾。
    // ⚠⚠ 成员前必须有 `proxies:` 头 —— 2026-10-25 16:33 真机实锤：头一行漏写时
    // 成员行悬空在标量键后面，内核报 `yaml: line N: did not find expected key`
    // 整份拒载（自动模式每次连接都注入 → 每次连接都报错）。
    const smartBlock = smartHead.slice();
    smartBlock.push('    proxies:');
    for (const name of memberNames) {
      smartBlock.push(`      - ${ProfileConfigMerger.yamlQuote(name)}`);
    }
    const rebuilt = lines.slice(0, groupStart)
      .concat(groupBody)
      .concat(lines.slice(groupEnd, sectionEnd))
      .concat(smartBlock)
      .concat(lines.slice(sectionEnd));
    out.ok = true;
    out.reason = `primary=${primary} members=${memberNames.length}`;
    out.yaml = rebuilt.join('\n');
    return out;
  }

  /** 原文是否显式启用 dns（`dns.enable: true`）。 */
  static hasEnabledDns(profileYaml: string): boolean {
    if (!ProfileConfigMerger.hasKey(profileYaml, 'dns')) {
      return false;
    }
    const body = ProfileConfigMerger.sectionText(profileYaml, 'dns');
    for (const line of body.split('\n')) {
      // 只读 DNS 直接子键；嵌套 policy/注释中的 enable 不能打开 DNS。
      const match = /^  (?:enable|"enable"|'enable'):\s*(true|"true"|'true'|yes|on|1)\s*(?:#.*)?$/i.exec(line);
      if (match !== null) { return true; }
    }
    return false;
  }

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
    if (key === 'dns' && inline.startsWith('{')) {
      const fields: string[] = ProfileConfigMerger.dnsFlowLines(inline);
      return fields.length > 0 ? ['dns:'].concat(fields).join('\n') : head;
    }
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
  static merge(overlayYaml: string, profileYaml: string,
    allowProfileDns: boolean = true): ProfileMergeResult {
    const out = new ProfileMergeResult();
    if (overlayYaml.trim().length === 0) {
      out.error = 'overlay config is empty';
      return out;
    }
    if (!ProfileConfigMerger.isKernelLoadableConfig(profileYaml)) {
      out.error = 'profile has no proxies / proxy-groups / proxy-providers';
      return out;
    }
    // 裸节点表兜底（2026-10-22 真机）：只有 proxies、没有 proxy-groups 的 profile
    // （「订阅转换」导出的纯节点 YAML、手抄的节点片段）没有分流组也没有 MATCH 规则，
    // 直接合并出来是一份「没有 MATCH 的规则集」—— 内核要么拒载，要么所有 overlay
    // 规则因目标不存在被丢弃后**全量直连**。真机表现正是「能取到出口 IP 但打不开
    // YouTube、测速没有候选」。这里就地补一个 select 组 + MATCH，等价一份最简订阅。
    profileYaml = ProfileConfigMerger.withSyntheticGroups(profileYaml);

    let base = overlayYaml;
    for (const key of REPLACE_KEYS) {
      base = ProfileConfigMerger.removeKey(base, key);
    }

    const applied: string[] = [];
    const blocks: string[] = [];

    for (const key of PROFILE_KEYS) {
      const section = ProfileConfigMerger.sectionText(profileYaml, key);
      if (section.length === 0) {
        continue;
      }
      blocks.push(section);
      applied.push(key);
    }

    // overlay.rules 仍引用自产 hyper-adrules / rs-*；原文 rules 也可能引用自己的 provider。
    // provider 是名字寻址的命名空间：声明缺一个 = 内核整份拒载。两个段都按**完整块并集**，
    // 同名时 overlay 优先（与生成器「自产规则集优先」口径一致）。
    for (const providerKey of PROVIDER_MERGE_KEYS) {
      const providers = ProfileConfigMerger.providerBlocks(providerKey, overlayYaml);
      const profileProviders = ProfileConfigMerger.providerBlocks(providerKey, profileYaml);
      for (const entry of profileProviders) {
        if (!providers.has(entry[0])) {
          providers.set(entry[0], entry[1]);
        }
      }
      if (providers.size === 0) {
        continue;
      }
      const providerLines: string[] = [`${providerKey}:`];
      for (const entry of providers) {
        for (const line of entry[1]) {
          providerLines.push(line);
        }
      }
      blocks.push(providerLines.join('\n'));
      applied.push(providerKey);
    }

    // hosts / sniffer：overlay 未声明时搬入原文
    const extraKeys: string[] = ['hosts', 'sniffer'];
    for (const key of extraKeys) {
      if (ProfileConfigMerger.hasKey(base, key)) {
        continue;
      }
      const section = ProfileConfigMerger.sectionText(profileYaml, key);
      if (section.length === 0) {
        continue;
      }
      blocks.push(section);
      applied.push(key);
    }

    // dns：覆写关闭时订阅显式配置优先，保留其解析模式、上游与策略；
    // 覆写开启时保留 TunBox 生成的 DNS 配置。订阅没有启用 DNS 时不替换默认块。
    if (allowProfileDns && ProfileConfigMerger.hasEnabledDns(profileYaml)) {
      const dnsRaw = ProfileConfigMerger.sectionText(profileYaml, 'dns');
      if (dnsRaw.length > 0) {
        base = ProfileConfigMerger.removeKey(base, 'dns');
        blocks.push(ProfileConfigMerger.ensureFakeIpForProfileDns(dnsRaw));
        applied.push('dns');
      }
    }

    // rules：overlay 在前 + 原文在后（FlClash appendRules）
    //
    // ⚠ overlay 的规则是 App 自己加的，它的目标组名来自**旧的组集合**（PROXY 等），
    // 而原文的组已经整体替换了 overlay 的组 ⇒ 引用不存在目标的规则会让内核**整份拒载**
    // （真机/真实内核实测：`rules[1] [MATCH,PROXY] error: proxy [PROXY] not found`）。
    // FlClash 的做法是 overlay 只加「目标取自 profile 自己的 MATCH 规则」的少量规则
    // （setup.dart 的 matchTarget），从不硬编码组名。这里等价实现：
    //   ① 目标不在最终策略集合里的 overlay 规则直接丢弃；
    //   ② 原文已有 MATCH 时，丢弃 overlay 的 MATCH（否则 overlay 的 MATCH 会短路原文规则）。
    const targets = ProfileConfigMerger.collectTargets(profileYaml);
    const overlayRulesRaw = ProfileConfigMerger.sectionBody(overlayYaml, 'rules');
    const profileRules = ProfileConfigMerger.sectionBody(profileYaml, 'rules');
    const hasProfileMatch = ProfileConfigMerger.hasMatchRule(profileRules);
    const overlayRules: string[] = [];
    for (const line of overlayRulesRaw) {
      const text = line.trim();
      if (text.length === 0 || text.startsWith('- #') || text === '-') {
        continue;
      }
      const rule = text.startsWith('- ') ? text.substring(2).trim() : text;
      if (rule.length === 0) {
        continue;
      }
      if (hasProfileMatch && rule.toUpperCase().startsWith('MATCH,')) {
        continue;
      }
      if (!ProfileConfigMerger.ruleTargetExists(rule, targets)) {
        continue;
      }
      overlayRules.push(line);
    }
    if (overlayRules.length !== overlayRulesRaw.length) {
      AppLogger.info(TAG, `overlay rules filtered: ${overlayRulesRaw.length - overlayRules.length} `
        + `of ${overlayRulesRaw.length} dropped (target not in profile groups)`);
    }
    if (overlayRules.length > 0 || profileRules.length > 0) {
      const lines: string[] = ['rules:'];
      for (const line of overlayRules) {
        lines.push(line);
      }
      for (const line of profileRules) {
        lines.push(line);
      }
      blocks.push(lines.join('\n'));
      applied.push('rules');
    }

    const head = base.trimEnd();
    out.ok = true;
    out.yaml = `${head}\n\n${blocks.join('\n\n')}\n`;
    out.applied = applied.join(',');
    out.profileProxyItems = ProfileConfigMerger.countProxyItems(profileYaml);
    return out;
  }

  /**
   * 按 provider 顶层条目拆完整块，不重排字段或压平 payload / header 等嵌套内容。
   * 这里直接取原始缩进；通用序列分节归一化会把嵌套 payload 当作分节基准。
   *
   * @param key 顶层段名（`proxy-providers` / `rule-providers`）
   */
  private static providerBlocks(key: string, yaml: string): Map<string, string[]> {
    const body: string[] = [];
    let inSection = false;
    let minIndent = 999999;
    for (const raw of yaml.split('\n')) {
      const line = raw.replace(/\r$/, '').replace(/^\uFEFF/, '');
      const text = line.trim();
      if (!line.startsWith(' ') && !line.startsWith('\t')) {
        if (line.startsWith(`${key}:`)) {
          inSection = true;
          continue;
        }
        if (inSection && text.length > 0 && !text.startsWith('#')) {
          break;
        }
      }
      if (!inSection || text.length === 0 || text.startsWith('#')) {
        continue;
      }
      const indent = line.length - line.trimStart().length;
      minIndent = Math.min(minIndent, indent);
      body.push(line);
    }
    const providers: Map<string, string[]> = new Map<string, string[]>();
    let current: string[] = [];
    for (const line of body) {
      const indent = line.length - line.trimStart().length;
      if (indent === minIndent) {
        current = [];
        const key = ProfileConfigMerger.providerKey(line.trimStart());
        if (key.length > 0 && !providers.has(key)) {
          providers.set(key, current);
        }
      }
      current.push('  ' + line.substring(minIndent));
    }
    return providers;
  }

  /** provider 名支持带引号的冒号、点号、中文和 YAML 单引号转义。 */
  private static providerKey(line: string): string {
    const match = /^(?:"((?:\\.|[^"])*)"|'((?:''|[^'])*)'|([^:]+))\s*:/.exec(line);
    if (match === null) {
      return '';
    }
    if (match[1] !== undefined) {
      try {
        return JSON.parse('"' + match[1] + '"') as string;
      } catch (e) {
        return match[1];
      }
    }
    return match[2] !== undefined ? match[2].split("''").join("'") : match[3].trim();
  }

  /** 取某段的主体行（带 2 空格缩进），去空行。 */
  private static sectionBody(yaml: string, key: string): string[] {
    if (!ProfileConfigMerger.hasKey(yaml, key)) {
      return [];
    }
    let body = '';
    try {
      body = YamlMerger.extractSection(yaml, key);
    } catch (e) {
      return [];
    }
    // ⚠ 不能用 trim()：会把首行序列项的前导缩进吃掉（rules 首条变顶格 → 非法 YAML）
    const out: string[] = [];
    for (const raw of body.split('\n')) {
      if (raw.trim().length === 0) {
        continue;
      }
      if (raw.trim() === '[]') {
        return [];
      }
      out.push(raw);
    }
    return out;
  }

  /** 规则行的目标（最后一段）。`TYPE,args...,TARGET`。 */
  private static ruleTarget(rule: string): string {
    const idx = rule.lastIndexOf(',');
    if (idx < 0) {
      return '';
    }
    return rule.substring(idx + 1).trim();
  }

  /** 目标是否存在（组名 / 节点名 / 内置策略）。 */
  private static ruleTargetExists(rule: string, targets: Set<string>): boolean {
    const target = ProfileConfigMerger.ruleTarget(rule);
    if (target.length === 0) {
      return true;
    }
    return targets.has(target);
  }

  private static hasMatchRule(lines: string[]): boolean {
    for (const raw of lines) {
      const text = raw.trim();
      const rule = text.startsWith('- ') ? text.substring(2).trim() : text;
      if (rule.toUpperCase().startsWith('MATCH,')) {
        return true;
      }
    }
    return false;
  }

  /**
   * 最终配置里可被规则引用的目标集合：
   * 原文 `proxies` 的 name、`proxy-groups` 的 name，加上内核内置策略。
   */
  static collectTargets(profileYaml: string): Set<string> {
    const out: Set<string> = new Set<string>();
    const builtins: string[] = ['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE', 'GLOBAL'];
    for (const name of builtins) {
      out.add(name);
    }
    for (const key of ['proxies', 'proxy-groups']) {
      for (const name of YamlMerger.sequenceItemNames(profileYaml, key)) {
        if (name.length > 0) {
          out.add(name);
        }
      }
    }
    return out;
  }

  /** 从条目行里取 `name:`（块式 `- name: X` 或流式 `- {name: X, ...}`）。 */
  private static itemName(line: string): string {
    const text = line.trim();
    let body = text.startsWith('- ') ? text.substring(2).trim() : text;
    if (body.startsWith('{')) {
      body = body.substring(1);
      const close = body.lastIndexOf('}');
      if (close >= 0) {
        body = body.substring(0, close);
      }
    }
    const idx = body.indexOf('name:');
    if (idx !== 0) {
      if (idx < 0) {
        return '';
      }
    }
    let value = body.substring(idx + 'name:'.length).trim();
    const comma = value.indexOf(',');
    if (comma >= 0) {
      value = value.substring(0, comma).trim();
    }
    return ProfileConfigMerger.unquote(value);
  }

  private static unquote(value: string): string {
    if (value.length >= 2) {
      const first = value.charAt(0);
      const last = value.charAt(value.length - 1);
      const dq = String.fromCharCode(34);
      const sq = String.fromCharCode(39);
      const isDouble = first === dq && last === dq;
      const isSingle = first === sq && last === sq;
      if (isDouble || isSingle) {
        return value.substring(1, value.length - 1);
      }
    }
    return value;
  }

  private static countProxyItems(yaml: string): number {
    return YamlMerger.proxyItemGroups(yaml).length;
  }

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
