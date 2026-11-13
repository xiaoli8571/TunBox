/**
 * 规范节点 → 旧 ProxyNode 字段的适配器（Proxy Node Adapter）
 *
 * ## 存在的理由
 *
 * 新的解析层产出的是**规范键**（`reality-public-key` / `client-fingerprint` /
 * `ws-path` / `grpc-service-name` …），而内核配置生成器
 * （`ClashConfigGenerator.ets`）认的是**旧 ProxyNode 字段**
 * （`realityPublicKey` / `clientFingerprint` / `wsPath` / `grpcServiceName` …）。
 *
 * 本文件就是这两者之间**唯一**的翻译层 —— 有了它，生成器一行都不用改
 * （它有指纹闸门，改它等于改整份配置的字节）。
 *
 * ## 三条纪律
 *
 * 1. **映射表只有一份**（`fieldMap`）：规范键 → 旧字段名。两条导入路径
 *    （分享链接 / Clash YAML）都走它，不会出现"YAML 路径写 wsPath、链接路径写 wsPath2"。
 * 2. **没有旧字段的规范键不丢**：进 `extraOpts`（生成器会原样回写进内核配置），
 *    只有 mihomo 本身没有对应字段的键（grpc-mode / encryption / header-type…）
 *    才只留在规范键里，不写进配置（写进去会让 mihomo 整份配置拒载）。
 * 3. **本文件不做安全判定**：server/port/uuid 格式等安全性检查仍由
 *    `ProxyNode` 自己的收尾函数负责（单一真源，不在这里复制一份）。
 *
 * ## 为什么这里不 import ProxyNode（避免循环依赖）
 *
 * `ProxyNode.ets` 要 import 本适配器（它负责写值）；如果本文件再 import
 * `ProxyNode`（为了写字段），就形成 **ProxyNode ⇄ ProxyNodeAdapter** 的循环
 * import —— ArkTS 编译能过，但运行期容易在后续改动里变成 TDZ 错误。
 * ⇒ 本文件只做**纯映射**（规范键 → 旧字段名 → 值），**写值**由
 * `ProxyNode.applyCanonical()` 完成（字段的主人写自己的字段，最自然）。
 *
 * ## ArkTS 纪律
 *
 * 不用 enum / any / 未标注对象字面量；不 import 任何 kit。
 */
import { ProtocolParamTableRegistry } from './ProtocolParamTable';

/** 规范键 → 旧 ProxyNode 字段名（布尔/整型键在 apply() 里做类型转换） */
const FIELD_MAP: Map<string, string> = new Map<string, string>([
  ['uuid', 'uuid'],
  ['password', 'password'],
  ['cipher', 'method'],
  ['protocol', 'protocol'],
  ['protocol-param', 'protocolParam'],
  ['obfs', 'obfs'],
  ['obfs-param', 'obfsParam'],
  ['obfs-password', 'obfsParam'],
  ['alter-id', 'alterId'],
  ['network', 'network'],
  ['tls', 'tls'],
  ['sni', 'servername'],
  ['servername', 'servername'],
  ['skip-cert-verify', 'skipCertVerify'],
  ['flow', 'flow'],
  ['client-fingerprint', 'clientFingerprint'],
  ['fingerprint', 'certFingerprint'],
  ['reality-public-key', 'realityPublicKey'],
  ['reality-short-id', 'realityShortId'],
  ['ws-path', 'wsPath'],
  ['ws-host', 'wsHost'],
  ['grpc-service-name', 'grpcServiceName'],
  ['alpn', 'alpnList'],
  ['up', 'hyUp'],
  ['down', 'hyDown']
]);

/** 布尔型旧字段 */
const BOOL_FIELDS: Set<string> = new Set<string>(['tls', 'skipCertVerify']);
/** 整型旧字段 */
const INT_FIELDS: Set<string> = new Set<string>(['alterId']);
/**
 * 需要单独处理的规范键（值不是 mihomo 字段的原样值）。
 *
 * `security` 的取值是 tls/reality/none，而 mihomo 的 tls 是**布尔** ——
 * 直接回写会生成 `tls: reality` 这种非法值，让内核整份配置拒载。
 */
const SPECIAL_KEYS: Set<string> = new Set<string>(['security']);

/**
 * 结构字段：生成端自己写（name / server / port），
 * **绝不能**再进 extraOpts —— 重复键会让 mihomo 的 YAML 报
 * "mapping key already defined" ⇒ 整份配置拒载。
 */
const STRUCTURAL_KEYS: Set<string> = new Set<string>(['name', 'server', 'port']);

export class ProxyNodeAdapter {
  /**
   * 规范键 → 旧 ProxyNode 字段名 → 值（纯函数，可单测）。
   *
   * @param protocol 规范协议名
   * @param params 规范键 → 值
   */
  static fieldMap(protocol: string, params: Map<string, string>): Map<string, string> {
    const out: Map<string, string> = new Map<string, string>();
    for (const key of params.keys()) {
      const field = FIELD_MAP.get(key);
      if (field === undefined) {
        continue;
      }
      const value = params.get(key);
      if (value === undefined) {
        continue;
      }
      out.set(field, value);
    }
    return out;
  }

  /**
   * 没有旧字段的规范键 → extraOpts（JSON 串，生成器会原样回写）。
   *
   * @param protocol 规范协议名
   * @param params 规范键 → 值
   * @param unknown 解析层认出来的额外键（URI 路径的未声明参数；YAML 路径为空）
   */
  static extraOpts(protocol: string, params: Map<string, string>, unknown: Map<string, string>): string {
    const table = ProtocolParamTableRegistry.of(protocol);
    const pairs: string[][] = [];
    const seen: Set<string> = new Set<string>();
    if (table !== null) {
      const nested: string[][] = [];
      for (const spec of table.specs) {
        if (FIELD_MAP.has(spec.key)) {
          continue;
        }
        if (SPECIAL_KEYS.has(spec.key)) {
          // security 的值是 tls/reality/none，不是 mihomo 的原样值 → 单独处理，不进 extraOpts
          continue;
        }
        if (STRUCTURAL_KEYS.has(spec.key)) {
          // name / server / port 由生成端自己写 ⇒ 重复写会让 mihomo 的 YAML 出现重复键
          continue;
        }
        const value = params.get(spec.key);
        if (value === undefined || value.length === 0) {
          continue;
        }
        const field = spec.mihomoField;
        if (field.length === 0 || field.startsWith('（')) {
          // mihomo 没有对应字段（如 grpc-mode / encryption / header-type）：
          // 保留在规范键里供诊断，但不写进内核配置（写进去会让 mihomo 拒载整份配置）。
          continue;
        }
        if (field.startsWith('ws-opts.')) {
          // 生成器会把 ws-opts.* 合并回 ws-opts 结构，保持点号形态即可。
          if (!seen.has(field)) {
            seen.add(field);
            pairs.push([field, value]);
          }
          continue;
        }
        if (field.indexOf('.') > 0) {
          // h2-opts.* / http-opts.* / xhttp-opts.* / obfs-opts.* → 组装成父键的 flow-map
          nested.push([field, value]);
          continue;
        }
        if (!seen.has(field)) {
          seen.add(field);
          pairs.push([field, value]);
        }
      }
      const assembled: string[][] = ProxyNodeAdapter.assembleNested(nested);
      for (const pair of assembled) {
        if (!seen.has(pair[0])) {
          seen.add(pair[0]);
          pairs.push(pair);
        }
      }
    }
    // 解析层认出来的未声明键：不是 mihomo 的键，**不写进配置**
    // （垃圾键写进 flow-map 会让内核整份配置解析失败 —— 旧实现同口径）。
    // 它们仍留在 ParsedNode.unknownParams 里供诊断，不算参数丢失。
    for (const key of unknown.keys()) {
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
    }
    if (pairs.length === 0) {
      return '';
    }
    return JSON.stringify(pairs);
  }

  /**
   * 把点号形式的 mihomo 字段组装成父键的 flow-map 值。
   *
   * 例：`h2-opts.path=/x` + `h2-opts.host=h` → `['h2-opts', '{path: /x, host: h}']`
   *      `http-opts.path=/x` + `http-opts.headers.Host=h` → `['http-opts', '{path: /x, headers: {Host: h}}']`
   */
  static assembleNested(pairs: string[][]): string[][] {
    const order: string[] = [];
    const grouped: Map<string, string[][]> = new Map<string, string[][]>();
    for (const pair of pairs) {
      const field = pair[0];
      const dot = field.indexOf('.');
      if (dot <= 0) {
        continue;
      }
      const parent = field.substring(0, dot);
      const sub = field.substring(dot + 1);
      if (!grouped.has(parent)) {
        grouped.set(parent, []);
        order.push(parent);
      }
      const list = grouped.get(parent);
      if (list !== undefined) {
        list.push([sub, pair[1]]);
      }
    }
    const out: string[][] = [];
    for (const parent of order) {
      const list = grouped.get(parent);
      if (list === undefined || list.length === 0) {
        continue;
      }
      const parts: string[] = [];
      for (const item of list) {
        const sub = item[0];
        const value = item[1];
        if (sub.indexOf('.') > 0) {
          // 二级嵌套（如 headers.Host）→ 再包一层
          const inner = sub.substring(0, sub.indexOf('.'));
          const innerKey = sub.substring(sub.indexOf('.') + 1);
          parts.push(`${inner}: {${innerKey}: ${ProxyNodeAdapter.flowValue(value)}}`);
        } else {
          parts.push(`${sub}: ${ProxyNodeAdapter.flowValue(value)}`);
        }
      }
      out.push([parent, `{${parts.join(', ')}}`]);
    }
    return out;
  }

  /** flow-map 里的值：数字/布尔裸写，其余双引号 */
  static flowValue(value: string): string {
    if (value === 'true' || value === 'false') {
      return value;
    }
    if (/^-?[0-9]+(\.[0-9]+)?$/.test(value)) {
      return value;
    }
    return `"${ProxyNodeAdapter.escapeYaml(value)}"`;
  }

  /** YAML 双引号转义 */
  static escapeYaml(value: string): string {
    let out = '';
    for (let i = 0; i < value.length; i++) {
      const ch = value.charAt(i);
      if (ch === '\\' || ch === '"') {
        out = out + '\\' + ch;
      } else if (ch === '\n') {
        out = out + '\\n';
      } else {
        out = out + ch;
      }
    }
    return out;
  }


  /** 该旧字段是不是布尔型（写入时要转成 true/false，不能直接写字符串） */
  static isBooleanField(field: string): boolean {
    return BOOL_FIELDS.has(field);
  }

  /** 该旧字段是不是整型（写入时要 parseInt） */
  static isIntegerField(field: string): boolean {
    return INT_FIELDS.has(field);
  }

  /**
   * security（tls/reality/none）→ mihomo 的布尔 tls。
   *
   * ⚠ 不能把 security 原样回写：mihomo 的 tls 是布尔，写成 `tls: reality`
   *   会让内核整份配置拒载。
   *
   * @param params 规范键 → 值
   * @returns 布尔值；没有 security 键时返回空串（表示"未声明"）
   */
  static securityToTls(params: Map<string, string>): string {
    const security = params.get('security');
    if (security === undefined || security.length === 0) {
      return '';
    }
    return (security === 'tls' || security === 'reality') ? 'true' : 'false';
  }

  /**
   * 该协议是否带 udp 能力（ss/ssr/snell/http/socks 不带）。
   */
  static supportsUdp(protocol: string): boolean {
    return protocol === 'vless' || protocol === 'vmess' || protocol === 'trojan'
      || protocol === 'hysteria2' || protocol === 'hysteria' || protocol === 'tuic' || protocol === 'anytls';
  }
}
