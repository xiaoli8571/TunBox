/**
 * YAML 订阅路径的规范键适配（Yaml Node Adapter）
 *
 * ## 为什么 URI 路径做好了还不够
 *
 * 真机 2026-10-20 的 mitce.io 34 个 VLESS·REALITY 节点**走的是 Clash YAML 路径**
 * （明文 YAML 的 `proxies:` 段、裸连字符块序列），不是分享链接路径。
 * ⇒ URI 路径的保真层根本没覆盖到出问题的这批节点，**YAML 路径必须用同一张参数表**。
 *
 * ## 本文件做什么
 *
 * `YamlMerger` 已经把 YAML 节点解析成 `MergedProxy`（结构化槽位 + extraOpts），
 * 但它的槽位名与本项目的**规范键**不是一回事（realityPublicKey ≠ reality-public-key，
 * servername 在 hysteria2 又是 sni …）。本文件把两者对上：
 *
 * 1. `MergedProxy` 的结构化槽位 + extraOpts → **mihomo 字段值**（mihomoField → 值）；
 * 2. mihomoField → **规范键**：用参数表反查（`ProtocolParamTable` 里每个声明都带
 *    `mihomoField`），所以**两条导入路径共用同一张表、同一套必填口径**，
 *    不会出现"YAML 路径认 uuid、URI 路径认 id"这种两套真源。
 * 3. 规范键 → 只做**映射视图**（凭据/诊断用）。**不再**调用
 *    `NodeUsability.assess()` 去判「定义不完整」——
 *    2026-10-22 FlClash 同构：节点可用性只有内核有话语权（订阅原文进内核配置，
 *    见 `ProfileConfigMerger`），App 侧的第二意见会与内核分叉（真机实证：
 *    同 `server:port` 的两条节点互相串台 ⇒ 一条正常节点被误判踢出）。
 *
 * ## REALITY 的判定差异（两条路径的表达不同，但语义必须一致）
 *
 * - URI 路径：显式 `security=reality` ⇒ 必须有 `reality-public-key`。
 * - YAML 路径：**没有** security 键 —— REALITY 由 `reality-opts:` 段的存在来表达。
 *   所以本文件在 YAML 路径上**补出 `security=reality`**，让参数表的
 *   `requiredWhen: security=reality` 这条条件必填在两条路径上语义一致。
 *
 *   ⚠ 「reality-opts 段存在但 public-key 缺失」是解析层丢参数的高发形态
 *   （flow-map 解析失败会被降级成"未提供"），必须能识别出来判整条不可用，
 *   否则节点会以「普通 TLS vless」的形态进内核代理表 → 握手秒失败 → 整片 503。
 *   因此除了结构化槽位，本文件还从**订阅原文**取「reality-opts 段是否存在」这个事实。
 *
 * ## ArkTS 纪律
 *
 * 不用 enum / interface / 未标注对象字面量；不 import 任何 kit。
 */
import { MergedProxy, YamlMerger } from '../services/YamlMerger';
import { ProtocolParamTable, ProtocolParamTableRegistry } from './ProtocolParamTable';

/** 一个 YAML 节点的规范键视图 */
export class YamlNodeCanonical {
  /** 规范键 → 值（两条导入路径的规范键完全一致） */
  params: Map<string, string> = new Map<string, string>();
  /** 参数表未声明、但原文里有的 mihomo 字段（mihomoField → 值）：不丢，只是没有规范键 */
  extras: Map<string, string> = new Map<string, string>();
}

export class YamlNodeAdapter {
  /**
   * 把 MergedProxy 转成规范键视图。
   *
   * @param merged 合并引擎产出的节点
   * @param realityDeclared 该节点是否**在原文里声明过** reality-opts 段
   *        （结构化槽位为空但原文有该段时的补键依据；**不**代表节点不可用）
   */
  static canonical(merged: MergedProxy, realityDeclared: boolean): YamlNodeCanonical {
    const out = new YamlNodeCanonical();
    const protocol = YamlNodeAdapter.protocolOf(merged.type);
    const table = ProtocolParamTableRegistry.of(protocol);
    if (table === null) {
      return out;
    }

    // 1) 结构化槽位 → mihomo 字段值
    const fields: Map<string, string> = new Map<string, string>();
    YamlNodeAdapter.putIfPresent(fields, 'name', merged.name);
    YamlNodeAdapter.putIfPresent(fields, 'server', merged.server);
    if (merged.port > 0) {
      fields.set('port', String(merged.port));
    }
    YamlNodeAdapter.putIfPresent(fields, 'uuid', merged.uuid);
    YamlNodeAdapter.putIfPresent(fields, 'password', merged.password);
    YamlNodeAdapter.putIfPresent(fields, 'cipher', merged.cipher);
    YamlNodeAdapter.putIfPresent(fields, 'protocol', merged.protocol);
    YamlNodeAdapter.putIfPresent(fields, 'protocol-param', merged.protocolParam);
    YamlNodeAdapter.putIfPresent(fields, 'obfs', merged.obfs);
    YamlNodeAdapter.putIfPresent(fields, 'network', merged.network);
    YamlNodeAdapter.putIfPresent(fields, 'flow', merged.flow);
    YamlNodeAdapter.putIfPresent(fields, 'client-fingerprint', merged.clientFingerprint);
    YamlNodeAdapter.putIfPresent(fields, 'fingerprint', merged.certFingerprint);
    YamlNodeAdapter.putIfPresent(fields, 'reality-opts.public-key', merged.realityPublicKey);
    YamlNodeAdapter.putIfPresent(fields, 'reality-opts.short-id', merged.realityShortId);
    YamlNodeAdapter.putIfPresent(fields, 'grpc-opts.grpc-service-name', merged.grpcServiceName);
    YamlNodeAdapter.putIfPresent(fields, 'alpn', merged.alpnList);
    YamlNodeAdapter.putIfPresent(fields, 'up', merged.hyUp);
    YamlNodeAdapter.putIfPresent(fields, 'down', merged.hyDown);
    if (merged.alterId > 0) {
      fields.set('alterId', String(merged.alterId));
    }
    if (merged.tls) {
      fields.set('tls', 'true');
    }
    if (merged.skipCertVerify) {
      fields.set('skip-cert-verify', 'true');
    }
    // obfsParam 在 ssr 是 obfs-param、在 hysteria2 是 obfs-password —— 由 mihomo 字段名区分
    YamlNodeAdapter.putIfPresent(fields, 'obfs-param', merged.obfsParam);
    if (protocol === 'hysteria2') {
      fields.delete('obfs-param');
      YamlNodeAdapter.putIfPresent(fields, 'obfs-password', merged.obfsParam);
    }
    // servername 槽位：vless/vmess/trojan 写 servername，hysteria2/tuic/anytls/… 写 sni
    const sniField = YamlNodeAdapter.sniFieldOf(table);
    YamlNodeAdapter.putIfPresent(fields, sniField, merged.servername);
    // 传输层的 path/host：同一个槽位，落在哪个 opts 结构里由 network 决定
    YamlNodeAdapter.putTransportFields(fields, merged.network, merged.wsPath, merged.wsHost);

    // 2) extraOpts（结构化槽位之外的额外 mihomo 键）→ 字段值
    const extraPairs: string[][] = YamlMerger.parseExtraOpts(merged.extraOpts);
    for (const pair of extraPairs) {
      YamlNodeAdapter.putIfPresent(fields, pair[0], pair[1]);
    }

    // 3) mihomo 字段值 → 规范键（用参数表反查，两条路径同一张表）
    const reverse: Map<string, string> = YamlNodeAdapter.reverseIndex(table);
    for (const field of fields.keys()) {
      const value = fields.get(field);
      if (value === undefined) {
        continue;
      }
      const key = reverse.get(field);
      if (key === undefined) {
        // 参数表没声明这个字段：不丢（原文有就必须在 extras 里看得见），只是没有规范键
        out.extras.set(field, value);
        continue;
      }
      out.params.set(key, value);
    }

    // 4) REALITY：YAML 路径没有 security 键，由 reality-opts 段的存在来表达
    const realityPresent = realityDeclared
      || merged.realityPublicKey.length > 0
      || merged.realityShortId.length > 0;
    if (realityPresent && protocol === 'vless') {
      out.params.set('security', 'reality');
    }

    // 5) 到此为止：**只产出映射视图，不做必填校验**。
    //    2026-10-22 FlClash 同构：节点能不能用由内核解析原文决定，App 不再出结论。
    //    （历史：这里曾调 NodeUsability.assess 判「定义不完整」并整条排除 ——
    //     真机实证该判词会与内核分叉，见本文件头与 plan() 的注释。）
    return out;
  }

  /**
   * 扫订阅原文，取出「哪些节点在原文里声明过 reality-opts 段」。
   *
   * 返回 key → 是否声明过。key 由 `name|server|port` 组成（用 `nodeKey` 生成），
   * 与合并后的节点按基础名对齐（合并器会加 " (2)" 这类重名后缀，故用 `stripNameSuffix`）。
   *
   * 成本：只做行切分 + 正则，**不做第二次完整解析**。
   */
  static realityDeclaredMap(body: string): Map<string, boolean> {
    const out: Map<string, boolean> = new Map<string, boolean>();
    const groups: string[][] = YamlMerger.proxyItemGroups(body);
    for (const itemLines of groups) {
      const server = YamlNodeAdapter.scalarOf(itemLines, 'server');
      const port = YamlNodeAdapter.scalarOf(itemLines, 'port');
      if (server.length === 0 && port.length === 0) {
        continue;
      }
      let declared = false;
      for (const line of itemLines) {
        const trimmed = line.trim();
        if (trimmed.length === 0 || trimmed.startsWith('#')) {
          // 注释行不算声明（真实订阅里常有 "# 这里原本有 reality-opts" 之类的说明）
          continue;
        }
        if (trimmed.indexOf('reality-opts:') >= 0) {
          declared = true;
          break;
        }
      }
      out.set(YamlNodeAdapter.nodeKey(server, port), declared);
    }
    return out;
  }

  /**
   * 节点对齐键：server|port。
   *
   * 不用 name：合并器会给重名节点加 " (2)" 后缀，名字对不上就取不到标志；
   * server|port 在两条路径（原文 / 合并结果）里是稳定的。
   */
  static nodeKey(server: string, port: string): string {
    return `${server}|${port}`;
  }

  /** 去掉合并器加的重名后缀 " (2)" */
  static stripNameSuffix(name: string): string {
    if (!name.endsWith(')')) {
      return name;
    }
    const open = name.lastIndexOf(' (');
    if (open <= 0) {
      return name;
    }
    const digits = name.substring(open + 2, name.length - 1);
    if (digits.length === 0) {
      return name;
    }
    for (let i = 0; i < digits.length; i++) {
      const c = digits.charAt(i);
      if (c < '0' || c > '9') {
        return name;
      }
    }
    return name.substring(0, open);
  }

  /** 协议名归一（YAML 的 type 字段） */
  static protocolOf(type: string): string {
    const t = type.toLowerCase();
    if (t === 'hy2') {
      return 'hysteria2';
    }
    return t;
  }

  // ───────────────────── 内部工具 ─────────────────────

  private static putIfPresent(fields: Map<string, string>, key: string, value: string): void {
    if (value.length === 0) {
      return;
    }
    fields.set(key, value);
  }

  /** 该协议的 SNI 落在 mihomo 的哪个键（servername 还是 sni） */
  private static sniFieldOf(table: ProtocolParamTable): string {
    const spec = table.specOf('sni');
    if (spec !== null && spec.mihomoField.length > 0) {
      return spec.mihomoField;
    }
    return 'servername';
  }

  /** 传输层的 path/host 落到哪个 opts 结构（由 network 决定，不靠猜） */
  private static putTransportFields(fields: Map<string, string>, network: string,
    path: string, host: string): void {
    const n = network.toLowerCase();
    if (n === 'ws') {
      YamlNodeAdapter.putIfPresent(fields, 'ws-opts.path', path);
      YamlNodeAdapter.putIfPresent(fields, 'ws-opts.headers.Host', host);
      return;
    }
    if (n === 'h2') {
      YamlNodeAdapter.putIfPresent(fields, 'h2-opts.path', path);
      YamlNodeAdapter.putIfPresent(fields, 'h2-opts.host', host);
      return;
    }
    if (n === 'http') {
      YamlNodeAdapter.putIfPresent(fields, 'http-opts.path', path);
      YamlNodeAdapter.putIfPresent(fields, 'http-opts.headers.Host', host);
      return;
    }
    if (n === 'xhttp') {
      YamlNodeAdapter.putIfPresent(fields, 'xhttp-opts.path', path);
      YamlNodeAdapter.putIfPresent(fields, 'xhttp-opts.host', host);
      return;
    }
    // tcp/grpc：grpc 的服务名走 grpcServiceName 槽位（已单独处理）
  }

  /** 参数表反查：mihomo 字段 → 规范键 */
  private static reverseIndex(table: ProtocolParamTable): Map<string, string> {
    const out: Map<string, string> = new Map<string, string>();
    for (const spec of table.specs) {
      if (spec.mihomoField.length === 0 || spec.mihomoField.startsWith('（')) {
        continue;
      }
      if (!out.has(spec.mihomoField)) {
        out.set(spec.mihomoField, spec.key);
      }
    }
    return out;
  }

  /** 从条目行里取一个顶层标量（仅用于对齐键，不参与保真判定） */
  private static scalarOf(itemLines: string[], key: string): string {
    for (const line of itemLines) {
      const trimmed = line.trim();
      if (trimmed.startsWith('- ')) {
        // flow-map：- {name: x, server: y}
        const inner = trimmed.substring(2);
        const at = inner.indexOf(key + ':');
        if (at < 0) {
          continue;
        }
        let rest = inner.substring(at + key.length + 1);
        const stop = rest.search(/[,}]/);
        if (stop >= 0) {
          rest = rest.substring(0, stop);
        }
        return YamlNodeAdapter.unquote(rest.trim());
      }
      if (!trimmed.startsWith(key + ':')) {
        continue;
      }
      const rest = trimmed.substring(key.length + 1);
      if (rest.indexOf('{') >= 0) {
        continue;
      }
      return YamlNodeAdapter.unquote(rest.trim());
    }
    return '';
  }

  /** 去掉 YAML 标量的引号 */
  private static unquote(text: string): string {
    if (text.length >= 2) {
      const first = text.charAt(0);
      const last = text.charAt(text.length - 1);
      if ((first === '\'' && last === '\'') || (first === '"' && last === '"')) {
        return text.substring(1, text.length - 1);
      }
    }
    return text;
  }

  /**
   * 订阅原文里**声明过**的节点（proxies 段的每个条目）。
   *
   * 为什么需要：合并器（`YamlMerger`）有一道自己的凭据闸 —— 缺 uuid/password
   * 的条目**根本不会产出 MergedProxy**。如果只看合并结果，这些节点就"人间蒸发"：
   * 既不进代理表，也没有任何原因可查（用户只会看到"节点少了几个"）。
   * ⇒ 这里从原文把声明过的条目捞出来，和合并结果对账，差集就是
   * 「原文有、合并没产出」的节点 —— 只进**诊断账**（App 读不出来），
   * 节点本身仍由内核按原文解析（FlClash 同构，App 不下不可用结论）。
   */
  static declaredItems(body: string): DeclaredItem[] {
    const out: DeclaredItem[] = [];
    const groups: string[][] = YamlMerger.proxyItemGroups(body);
    for (const itemLines of groups) {
      const item = new DeclaredItem();
      item.name = YamlNodeAdapter.scalarOf(itemLines, 'name');
      item.server = YamlNodeAdapter.scalarOf(itemLines, 'server');
      item.port = YamlNodeAdapter.scalarOf(itemLines, 'port');
      item.type = YamlNodeAdapter.scalarOf(itemLines, 'type');
      if (item.name.length === 0 && item.server.length === 0) {
        continue;
      }
      out.push(item);
    }
    return out;
  }

  /**
   * YAML 路径的节点判定计划（App 能读到什么 / 原文有但没产出）。
   *
   * ## 2026-10-22 口径变更 · FlClash 同构：App **不再判**节点可用性
   *
   * 订阅原文是内核配置的基底（`RuntimeConfigBuilder` → `ProfileConfigMerger`，
   * `proxies` 段由原文**整段接管**），节点能不能用由内核解析后的结果说了算。
   * App 侧再出一份"定义完整/不完整"的结论 = **第二意见**，而第二意见必然与内核分叉：
   * 2026-10-22 真机实证 —— 订阅在同一 `server:port` 上挂了两条不同节点
   * （裸 vless + 同址 REALITY vless），按地址记的 reality 旁挂表串台 ⇒
   * 一条**内核完全能用的节点**被 App 判成「定义不完整」并整条踢出列表。
   *
   * ⇒ 本函数只做**映射与对账**，不做裁决：
   * - 每条合并结果都保留（`YamlNodeEntry` 没有"不可用"这个字段）；
   * - 原文声明但合并阶段没产出的条目只进 `dropped`（**诊断用**），同样不判死刑。
   *
   * 与 FlClash 一致：判词只可能来自内核（`/proxies` 里有没有、配置载入是否成功）。
   */
  static plan(merged: MergedProxy[], body: string): YamlNodePlan {
    const out = new YamlNodePlan();
    const flags = YamlNodeAdapter.realityDeclaredMap(body);
    for (const m of merged) {
      const entry = new YamlNodeEntry();
      entry.merged = m;
      entry.canonical = YamlNodeAdapter.canonical(m, YamlNodeAdapter.declaredReality(flags, m));
      out.entries.push(entry);
    }
    // 原文声明 vs 合并产出：对账差集
    const produced: Set<string> = new Set<string>();
    for (const entry of out.entries) {
      produced.add(YamlNodeAdapter.stripNameSuffix(entry.merged.name));
    }
    for (const item of YamlNodeAdapter.declaredItems(body)) {
      if (produced.has(item.name)) {
        continue;
      }
      const dropped = new DroppedItem();
      dropped.name = item.name;
      dropped.server = item.server;
      dropped.port = item.port;
      dropped.protocol = YamlNodeAdapter.protocolOf(item.type);
      // 只是「App 侧读不出来」的记账（诊断用），**不是**对节点下的结论：
      // 节点本身仍在订阅原文里，内核照常解析它（FlClash 同构：判词归内核）。
      dropped.reason = `App 未能解析：${dropped.protocol.length > 0 ? dropped.protocol : '未知协议'} `
        + '在合并阶段未产出节点（凭据/地址不完整），内核仍按原文处理';
      out.dropped.push(dropped);
    }
    return out;
  }

  /** 该节点在原文里是否声明过 reality-opts 段 */
  private static declaredReality(flags: Map<string, boolean>, merged: MergedProxy): boolean {
    const byAddr = flags.get(`${merged.server}|${merged.port}`);
    if (byAddr !== undefined) {
      return byAddr;
    }
    const byName = flags.get(`${merged.name}|${merged.server}|${merged.port}`);
    if (byName !== undefined) {
      return byName;
    }
    return false;
  }
}

/** 原文里声明过的一个节点（proxies 段的一条） */
export class DeclaredItem {
  name: string = '';
  server: string = '';
  port: string = '';
  type: string = '';
}

/** 原文声明、但合并阶段没产出的节点（缺凭据/地址不完整） */
export class DroppedItem {
  name: string = '';
  server: string = '';
  port: string = '';
  protocol: string = '';
  reason: string = '';
}

/**
 * 一条合并结果的视图（映射用，**不含**可用性结论）。
 *
 * 2026-10-22 FlClash 同构：App 不再给节点下「定义不完整」这类判词 ——
 * 内核按订阅原文解析，节点在不在、能不能用由内核说了算（`/proxies`）。
 */
export class YamlNodeEntry {
  merged: MergedProxy = new MergedProxy();
  /** 规范键视图（两条导入路径同一套键；凭据映射/诊断用，不参与裁决） */
  canonical: YamlNodeCanonical = new YamlNodeCanonical();
}

/** 整份 YAML 订阅的节点判定计划 */
export class YamlNodePlan {
  entries: YamlNodeEntry[] = [];
  dropped: DroppedItem[] = [];
}
