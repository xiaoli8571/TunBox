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
 *  · 设备侧没有 FlClash 的 provider 预取目录，原文 `proxy-providers` /
 *    `rule-providers` 段整段搬入（相对 path 由内核按自身 home 解析）；
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

/** 原文里允许进入运行配置的顶层键（其余一律丢弃，由 overlay 决定）。 */
const PROFILE_KEYS: string[] = [
  'proxies',
  'proxy-groups',
  'sub-rules',
  'proxy-providers',
  'rule-providers',
  'tunnels',
  'listeners'
];

/**
 * overlay 里先从根文档删掉、随后重新拼回的键。
 *
 * ⚠ `proxy-providers` / `rule-providers` 虽然也在这里（删除是为了避免两份同名段
 * 造成重复顶层键），但它们**不是**整段替换，而是按键取并集后重新拼回 ——
 * 见 PROVIDER_MERGE_KEYS。
 */
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

/**
 * provider 段**不做整体替换**，而是按键取并集（overlay 优先）。
 *
 * 【2026-10-23 用户报障】「手动更新去广告规则后 VPN 启动失败，删掉规则集就正常」。
 *
 * 根因就在原来的「先删后追加」：overlay（App 生成的运行配置）里
 *   · `rule-providers:` 声明着 `hyper-adrules`（去广告）与 `rs-*`（自定义规则集），
 *   · `rules:` 里第一条是 `RULE-SET,hyper-adrules,REJECT`；
 * 合并时 `rule-providers` 被从 overlay 删掉、而订阅原文根本没有 provider 段，
 * 于是最终配置「引用在、声明丢」→ 内核整份拒载：
 *   `parse config: rules[0] [RULE-SET,hyper-adrules,REJECT] error: rule set [hyper-adrules] not found`
 * → 用户看到的就是「开了去广告就连不上，删掉规则集又能连」（删掉后 RULE-SET 行也不生成）。
 *
 * 正确语义与 `proxies` / `proxy-groups` 不同：provider 是**名字寻址**的命名空间，
 * 两边各自声明的 provider 互不冲突即可共存，overlay 同名优先（与生成器 ①自产优先 一致）。
 */
const PROVIDER_MERGE_KEYS: string[] = ['proxy-providers', 'rule-providers'];

/** provider 段里的一个命名块（key 行 + 其后的字段行） */
class ProviderSectionBlock {
  name: string = '';
  lines: string[] = [];
}

export class ProfileMergeResult {
  ok: boolean = false;
  yaml: string = '';
  error: string = '';
  /** 诊断：从原文搬入了哪些段（逗号分隔） */
  applied: string = '';
  /** 原文节点条目数（`proxies:` 下的 `- ` 计数，仅用于日志） */
  profileProxyItems: number = 0;
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
    if (ProfileConfigMerger.hasKey(joined, 'enhanced-mode')) {
      return joined;
    }
    // 3) 否则补 fake-ip：境外域名交给节点侧解析，不吃国内 DNS 的污染结果
    const extra: string[] = [
      '  enhanced-mode: fake-ip',
      '  fake-ip-range: 198.18.0.1/16',
      '  fake-ip-filter:',
      '    - "*.lan"',
      '    - "*.local"',
      '    - localhost.ptlogin2.qq.com',
      '    - "+.msftconnecttest.com"',
      '    - "+.msftncsi.com"'
    ];
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
    const names: string[] = [];
    const body = ProfileConfigMerger.sectionBody(profileYaml, 'proxies');
    for (const line of body) {
      const m = /^\s*-\s*name:\s*(.+)$/.exec(line);
      if (m !== null) {
        const raw = m[1].trim();
        const unquoted = (raw.startsWith('"') && raw.endsWith('"'))
          ? raw.substring(1, raw.length - 1) : raw;
        if (unquoted.length > 0) {
          names.push(unquoted);
        }
      }
    }
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
    lines.push('rules:', '  - GEOIP,CN,DIRECT', '  - MATCH,手动选择');
    return lines.join(LF);
  }

  /** 原文是否显式启用 dns（`dns.enable: true`）。 */
  static hasEnabledDns(profileYaml: string): boolean {
    if (!ProfileConfigMerger.hasKey(profileYaml, 'dns')) {
      return false;
    }
    const body = ProfileConfigMerger.sectionText(profileYaml, 'dns');
    for (const raw of body.split('\n')) {
      const line = raw.trim();
      if (!line.startsWith('enable:')) {
        continue;
      }
      const value = line.substring('enable:'.length).trim().toLowerCase();
      return value === 'true' || value === '"true"' || value === '\'true\'';
    }
    return false;
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
    let body = '';
    try {
      body = YamlMerger.extractSection(yaml, key);
    } catch (e) {
      body = '';
    }
    const trimmed = body.trim();
    if (trimmed.length === 0) {
      return `${key}:`;
    }
    if (trimmed === '[]') {
      return `${key}: []`;
    }
    return `${key}:\n${body}`;
  }

  /**
   * 把 provider 段拆成命名块（key 行缩进 2、字段行缩进 >2；`sectionText` 已把缩进归一）。
   * 解析不了的行按「并入当前块」处理，绝不丢字段（丢字段等于把 provider 改坏）。
   */
  private static parseProviderSectionBlocks(sectionText: string,
    key: string): ProviderSectionBlock[] {
    const out: ProviderSectionBlock[] = [];
    if (sectionText.length === 0) {
      return out;
    }
    const lines: string[] = sectionText.split('\n');
    let current: ProviderSectionBlock | null = null;
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i];
      const trimmed: string = line.trim();
      if (i === 0) {
        // 头行：`key:` / `key: []`
        continue;
      }
      if (trimmed.length === 0) {
        continue;
      }
      let indent = 0;
      while (indent < line.length && line.charAt(indent) === ' ') {
        indent++;
      }
      if (indent <= 2 && trimmed.endsWith(':')) {
        current = new ProviderSectionBlock();
        current.name = trimmed.substring(0, trimmed.length - 1).trim();
        current.lines.push(`  ${current.name}:`);
        if (current.name.length > 0) {
          out.push(current);
        } else {
          current = null;
        }
        continue;
      }
      if (current !== null) {
        current.lines.push(line);
      }
    }
    const kept: ProviderSectionBlock[] = out.filter((b: ProviderSectionBlock): boolean =>
      b.lines.length > 1);
    return kept;
  }

  /**
   * provider 段并集：overlay 的块全部保留，原文的块只补「overlay 未声明过的名字」。
   *
   * 为什么 overlay 优先：overlay 的 provider 是 App 自己生成/校验过的（去广告 MRS 的
   * `path` 指向内核 home 下真实落盘的文件、自定义规则集的 URL 由用户填写），
   * 原文同名块若反过来覆盖，就会出现「声明指向不存在的 path」或「行为不一致」。
   *
   * @returns '' = 两边都没有该段；否则为一段可直接拼进最终配置的 YAML 文本
   */
  static mergeProviderSection(key: string, overlayYaml: string,
    profileYaml: string): string {
    const overlayBlocks = ProfileConfigMerger.parseProviderSectionBlocks(
      ProfileConfigMerger.sectionText(overlayYaml, key), key);
    const profileBlocks = ProfileConfigMerger.parseProviderSectionBlocks(
      ProfileConfigMerger.sectionText(profileYaml, key), key);
    if (overlayBlocks.length === 0 && profileBlocks.length === 0) {
      return '';
    }
    const seen: Set<string> = new Set<string>();
    const lines: string[] = [`${key}:`];
    for (const block of overlayBlocks) {
      if (seen.has(block.name)) {
        continue;
      }
      seen.add(block.name);
      for (const line of block.lines) {
        lines.push(line);
      }
    }
    let dropped = 0;
    for (const block of profileBlocks) {
      if (seen.has(block.name)) {
        dropped++;
        continue;
      }
      seen.add(block.name);
      for (const line of block.lines) {
        lines.push(line);
      }
    }
    if (dropped > 0) {
      AppLogger.info(TAG, `${key}: ${dropped} profile provider(s) shadowed by overlay`);
    }
    return lines.length > 1 ? lines.join('\n') : '';
  }

  /**
   * 合并。overlay = TunBox 生成的完整运行配置，profile = 订阅原文。
   */
  static merge(overlayYaml: string, profileYaml: string): ProfileMergeResult {
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
      // provider 段走下面的并集合并（overlay 优先），不能在这里整段追加
      if (PROVIDER_MERGE_KEYS.indexOf(key) >= 0) {
        continue;
      }
      const section = ProfileConfigMerger.sectionText(profileYaml, key);
      if (section.length === 0) {
        continue;
      }
      blocks.push(section);
      applied.push(key);
    }

    // provider 段：overlay 与原文按键取并集（overlay 同名优先），绝不整体替换。
    // 见 PROVIDER_MERGE_KEYS 注释（2026-10-23 去广告开启后 VPN 起不来的根因）。
    for (const key of PROVIDER_MERGE_KEYS) {
      const merged = ProfileConfigMerger.mergeProviderSection(key, overlayYaml, profileYaml);
      if (merged.length === 0) {
        continue;
      }
      blocks.push(merged);
      applied.push(key);
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

    // dns：原文显式启用时整段用原文（FlClash isEnableDns 语义）
    if (ProfileConfigMerger.hasEnabledDns(profileYaml)) {
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
      for (const line of ProfileConfigMerger.sectionBody(profileYaml, key)) {
        const name = ProfileConfigMerger.itemName(line);
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
    const body = ProfileConfigMerger.sectionBody(yaml, 'proxies');
    let count = 0;
    for (const raw of body) {
      if (raw.trimStart().startsWith('- ') || raw.trim() === '-') {
        count = count + 1;
      }
    }
    return count;
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
