/**
 * FlClash 同构 profile 构建器（map 级，零文本手术）。
 *
 * 对齐 FlClash（upstream main）的 apply 链：
 *   `setup.dart getProfile` → `_makeRealProfileTask`（lib/common/task.dart）→
 *   写 `homeDir/config.yaml` → `core applyConfig`（executor.Parse + patchSelectGroup）。
 *
 * 本仓对应流程（2026-11-05 全量照抄改造）：
 *   1. **内核解析 profile**：`coreBridge.getProfileBase(profilePath)` —— mihomo 自己的
 *      解析器（`config.UnmarshalRawConfig`），锚点/合并键/类型与最终加载完全一致。
 *      这是 FlClash `CoreController.getConfig` 的等价物。App 侧**不再**解析/切片 YAML。
 *   2. **overlay = patch 源**：ClashConfigGenerator.generate() 的产物（本仓
 *      patchClashConfig 等价物：端口/secret/mode/tun/dns/hosts/sniffer），经内核
 *      `decodeYaml` 解成 map（ArkTS 无 YAML 解析器，由内核同一 yaml 库承担
 *      FlClash Dart loadYaml 的角色）。
 *   3. **patch 链**：按 upstream `_makeRealProfileTask` 的逐键顺序落在 profile map 上
 *      （端口清零/keep-alive/find-process-mode=off(ohos)/tun/dns/hosts/provider path
 *      收容/global-ua/geox-url/store-selected=false/sniffer ports 归一化…）。
 *   4. **dump**：`JSON.stringify(map)`。JSON 是 YAML 的子集，内核用同一解析器加载
 *      （mihomo `-t` 实测通过）；等价 FlClash 的 `_encodeYaml` 步骤。
 *
 * provider 语义（任务1「provider 交给内核拉」）：App 把**全部**非 inline provider 条目
 * `path` 收容到本仓 provider 缓存目录（FlClash `confineProviders` +
 * `getProvidersFilePathInner` 语义：有 URL key=name@url，无 URL key=section/name），
 * **从不**预取/解析 provider 内容 —— 由 mihomo 按 `url/interval/health-check` 自己
 * 拉取与缓存（`global-ua` 与 FlClash 同为单一 UA）。旧 URL-only 缓存 best-effort 迁移。
 * overlay 注入声明（injected）先铺、profile 后铺，同名 profile 赢；注入声明路径原样。
 *
 * 规则语义：附加规则不设目标白名单，全部保留前置；仅 target=MATCH 的项替换为
 * 选定 matchTarget（缺省 = 最后 profile MATCH），no-resolve 等参数原样。
 * DNS 三段合并（baseline → overrides → appendSystemDns）；无 dns.ipv6 强改。
 * TunBox 的可选 Smart 增强在同一 map 上执行，仅在当前订阅明确选中 AUTO 且模型就绪时启用。
 */
import { coreBridge } from '../../core/CoreBridge';
import { fileIo as fs } from '@kit.CoreFileKit';
import { tunboxUserAgent } from '../services/SubscriptionFetchPolicy';
import { AppLogger } from '../utils/AppLogger';
import { ClashConfigGenerator } from '../services/ClashConfigGenerator';
import { LatencyTestUrl } from '../latency/LatencyTestUrl';

const TAG = 'TunBoxProfileBuilder';

/** FlClash `defaultGeoXUrl`（MetaCubeX meta-rules-dat release 镜像）。 */
const GEOX_URL: Record<string, string> = {
  'mmdb': 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb',
  'asn': 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb',
  'geoip': 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat',
  'geosite': 'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat'
};

/** FlClash `defaultKeepAliveInterval`（PatchClashConfig 默认 30）。 */
const KEEP_ALIVE_INTERVAL = 30;
/** FlClash ohos 专用：find-process-mode 恒为 off（FlClash ohos task.dart 同款）。 */
const FIND_PROCESS_MODE_OHOS = 'off';
/** FlClash `defaultDnsHijack`（Tun.safeFormJson 默认 ['any:53']）。 */
const DEFAULT_DNS_HIJACK = 'any:53';

/** 构建入参（两种 mode 用同一份）。 */
export class TunBoxProfileInput {
  /** 订阅 id（= FlClash profileId；provider 缓存目录用它隔离）。 */
  profileId: string = '';
  /** profile 文件绝对路径（`<filesDir>/profiles/<id>.yaml`）。 */
  profilePath: string = '';
  /** profile 目录（provider 缓存根：`<profilesDir>/providers/<id>/<type>/<md5>`）。 */
  profilesDir: string = '';
  /** 生成器 overlay（本仓 patchClashConfig 等价物；仅取运行期键）。 */
  overlayYaml: string = '';
  /** 每 profile 覆盖层（effectiveOverride：per-profile > 全局；空串 = 无）。 */
  overrideYaml: string = '';
  /** 废弃（FlClash 无此开关；保留字段仅供旧调用点赋值，构建器不再使用）。
   * 注：调用点在 RuntimeConfigBuilder（作用域外），接线待 lead 安排。 */
  dnsOverrideEnabled: boolean = true;
  /** TUN 开关（测速核 false）。 */
  tunEnabled: boolean = true;
  /** 废弃（FlClash 无 dns.ipv6 强改；保留字段仅供旧调用点赋值，构建器不再使用）。 */
  ipv6Enabled: boolean = true;
  /** TUN mtu（与 VpnExtensionAbility 同源）。 */
  mtu: number = 0;
  useSmart: boolean = false;
  smartTestUrl: string = '';
  smartPolicyPriority: string = '';
  /** 选定 matchTarget（FlClash setupState.matchTarget；空 = 回退最后 profile MATCH）。 */
  matchTarget: string = '';
  /** 是否向 dns.nameserver 追加 system://（FlClash networkSetting.appendSystemDns，默认 false）。 */
  appendSystemDns: boolean = false;
  /** global-ua 设置值（FlClash realPatchConfig.globalUa；空 = 默认 UA）。 */
  globalUa: string = '';
}

/** 构建结果（ok=false 时 error 说明原因，调用方必须拒绝启动）。 */
export class TunBoxProfileResult {
  ok: boolean = false;
  smartGroupName: string = '';
  smartParentGroupName: string = '';
  /** 最终配置文本（JSON 形态，可直接落盘交给内核）。 */
  yaml: string = '';
  error: string = '';
  /** patch 链落过的键（诊断日志用，逗号分隔）。 */
  applied: string = '';
  /** 收容了 path 的 provider 数（proxy + rule）。 */
  confinedProviders: number = 0;
  /** legacy→新 provider 缓存迁移（旧 URL-only MD5 → name@url MD5；build best-effort 改名）。 */
  providerMigrations: TunBoxProviderMigration[] = [];
  /** 内核解析出的节点/组/规则计数（ProfileBase，节点数显示用）。 */
  profileProxies: number = 0;
  profileGroups: number = 0;
  profileRules: number = 0;
  /** 最终配置的组投影（name/type/成员，保留 profile 原有 Smart 策略）。 */
  groups: TunBoxGroupInfo[] = [];
  /** 最终规则序列（按序；钉选反查组名用）。 */
  rules: string[] = [];
  /** 静态 proxies 名（内核 map 原样顺序）。 */
  proxyNames: string[] = [];
}

/** legacy provider 缓存迁移（旧 md5(url) → 新 md5(name@url)；build 侧 best-effort 改名）。 */
export class TunBoxProviderMigration {
  from: string = '';
  to: string = '';
}

/** proxy-groups 一项的只读投影（ArkTS 显式类，满足 strict 规则）。 */
export class TunBoxGroupInfo {
  name: string = '';
  type: string = '';
  members: string[] = [];
}

/**
 * compose 的基座数据（内核 `getProfileBase` 的解耦形态）。
 * 生产路径由 CoreBridge.getProfileBase 填充；门禁/测试直接构造。
 */
export class TunBoxBaseData {
  config: Record<string, Object> = {} as Record<string, Object>;
  digest: string = '';
  proxies: number = 0;
  proxyGroups: number = 0;
  rules: number = 0;
  matchRules: string[] = [];
}

/** UTF-8 编码（纯 ArkTS；md5Hex 自包含，不依赖 kit——门禁在 Node 里真跑同一实现）。 */
function utf8Bytes(text: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < text.length; i++) {
    let code = text.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
      const lo = text.charCodeAt(i + 1);
      if (lo >= 0xdc00 && lo <= 0xdfff) {
        code = 0x10000 + ((code - 0xd800) << 10) + (lo - 0xdc00);
        i++;
      }
    }
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code < 0x10000) {
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    } else {
      out.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f),
        0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    }
  }
  return Uint8Array.from(out);
}

/** md5(str) -> 小写 hex（FlClash `toMd5()` 等价；UTF-8 编码）。 */
export function md5Hex(text: string): string {
  const md5 = new Md5();
  md5.update(utf8Bytes(text));
  return md5.hex();
}

/** MD5 实现（RFC 1321；provider 缓存键与 FlClash `toMd5()` 完全同值）。 */
class Md5 {
  private a: number = 1732584193;
  private b: number = -271733879;
  private c: number = -1732584194;
  private d: number = 271733878;
  private buffer: number[] = [];
  private length: number = 0;

  private static rotl(x: number, n: number): number {
    return ((x << n) | (x >>> (32 - n))) | 0;
  }

  private static add(x: number, y: number): number {
    return (x + y) | 0;
  }

  private ff(a: number, b: number, c: number, d: number, x: number, s: number, t: number): number {
    return Md5.add(Md5.rotl(Md5.add(Md5.add(a, (b & c) | (~b & d)), Md5.add(x, t)), s), b);
  }

  private gg(a: number, b: number, c: number, d: number, x: number, s: number, t: number): number {
    return Md5.add(Md5.rotl(Md5.add(Md5.add(a, (b & d) | (c & ~d)), Md5.add(x, t)), s), b);
  }

  private hh(a: number, b: number, c: number, d: number, x: number, s: number, t: number): number {
    return Md5.add(Md5.rotl(Md5.add(Md5.add(a, b ^ c ^ d), Md5.add(x, t)), s), b);
  }

  private ii(a: number, b: number, c: number, d: number, x: number, s: number, t: number): number {
    return Md5.add(Md5.rotl(Md5.add(Md5.add(a, c ^ (b | ~d)), Md5.add(x, t)), s), b);
  }

  private static wordsOf(bytes: number[]): number[] {
    const words: number[] = [];
    for (let i = 0; i < 16; i++) {
      words.push((bytes[i * 4]) | (bytes[i * 4 + 1] << 8) | (bytes[i * 4 + 2] << 16) | (bytes[i * 4 + 3] << 24));
    }
    return words;
  }

  private block(words: number[]): void {
    let a = this.a;
    let b = this.b;
    let c = this.c;
    let d = this.d;
    a = this.ff(a, b, c, d, words[0], 7, -680876936);
    d = this.ff(d, a, b, c, words[1], 12, -389564586);
    c = this.ff(c, d, a, b, words[2], 17, 606105819);
    b = this.ff(b, c, d, a, words[3], 22, -1044525330);
    a = this.ff(a, b, c, d, words[4], 7, -176418897);
    d = this.ff(d, a, b, c, words[5], 12, 1200080426);
    c = this.ff(c, d, a, b, words[6], 17, -1473231341);
    b = this.ff(b, c, d, a, words[7], 22, -45705983);
    a = this.ff(a, b, c, d, words[8], 7, 1770035416);
    d = this.ff(d, a, b, c, words[9], 12, -1958414417);
    c = this.ff(c, d, a, b, words[10], 17, -42063);
    b = this.ff(b, c, d, a, words[11], 22, -1990404162);
    a = this.ff(a, b, c, d, words[12], 7, 1804603682);
    d = this.ff(d, a, b, c, words[13], 12, -40341101);
    c = this.ff(c, d, a, b, words[14], 17, -1502002290);
    b = this.ff(b, c, d, a, words[15], 22, 1236535329);
    a = this.gg(a, b, c, d, words[1], 5, -165796510);
    d = this.gg(d, a, b, c, words[6], 9, -1069501632);
    c = this.gg(c, d, a, b, words[11], 14, 643717713);
    b = this.gg(b, c, d, a, words[0], 20, -373897302);
    a = this.gg(a, b, c, d, words[5], 5, -701558691);
    d = this.gg(d, a, b, c, words[10], 9, 38016083);
    c = this.gg(c, d, a, b, words[15], 14, -660478335);
    b = this.gg(b, c, d, a, words[4], 20, -405537848);
    a = this.gg(a, b, c, d, words[9], 5, 568446438);
    d = this.gg(d, a, b, c, words[14], 9, -1019803690);
    c = this.gg(c, d, a, b, words[3], 14, -187363961);
    b = this.gg(b, c, d, a, words[8], 20, 1163531501);
    a = this.gg(a, b, c, d, words[13], 5, -1444681467);
    d = this.gg(d, a, b, c, words[2], 9, -51403784);
    c = this.gg(c, d, a, b, words[7], 14, 1735328473);
    b = this.gg(b, c, d, a, words[12], 20, -1926607734);
    a = this.hh(a, b, c, d, words[5], 4, -378558);
    d = this.hh(d, a, b, c, words[8], 11, -2022574463);
    c = this.hh(c, d, a, b, words[11], 16, 1839030562);
    b = this.hh(b, c, d, a, words[14], 23, -35309556);
    a = this.hh(a, b, c, d, words[1], 4, -1530992060);
    d = this.hh(d, a, b, c, words[4], 11, 1272893353);
    c = this.hh(c, d, a, b, words[7], 16, -155497632);
    b = this.hh(b, c, d, a, words[10], 23, -1094730640);
    a = this.hh(a, b, c, d, words[13], 4, 681279174);
    d = this.hh(d, a, b, c, words[0], 11, -358537222);
    c = this.hh(c, d, a, b, words[3], 16, -722521979);
    b = this.hh(b, c, d, a, words[6], 23, 76029189);
    a = this.hh(a, b, c, d, words[9], 4, -640364487);
    d = this.hh(d, a, b, c, words[12], 11, -421815835);
    c = this.hh(c, d, a, b, words[15], 16, 530742520);
    b = this.hh(b, c, d, a, words[2], 23, -995338651);
    a = this.ii(a, b, c, d, words[0], 6, -198630844);
    d = this.ii(d, a, b, c, words[7], 10, 1126891415);
    c = this.ii(c, d, a, b, words[14], 15, -1416354905);
    b = this.ii(b, c, d, a, words[5], 21, -57434055);
    a = this.ii(a, b, c, d, words[12], 6, 1700485571);
    d = this.ii(d, a, b, c, words[3], 10, -1894986606);
    c = this.ii(c, d, a, b, words[10], 15, -1051523);
    b = this.ii(b, c, d, a, words[1], 21, -2054922799);
    a = this.ii(a, b, c, d, words[8], 6, 1873313359);
    d = this.ii(d, a, b, c, words[15], 10, -30611744);
    c = this.ii(c, d, a, b, words[6], 15, -1560198380);
    b = this.ii(b, c, d, a, words[13], 21, 1309151649);
    a = this.ii(a, b, c, d, words[4], 6, -145523070);
    d = this.ii(d, a, b, c, words[11], 10, -1120210379);
    c = this.ii(c, d, a, b, words[2], 15, 718787259);
    b = this.ii(b, c, d, a, words[9], 21, -343485551);
    this.a = Md5.add(this.a, a);
    this.b = Md5.add(this.b, b);
    this.c = Md5.add(this.c, c);
    this.d = Md5.add(this.d, d);
  }

  update(bytes: Uint8Array): void {
    this.length += bytes.length;
    for (let i = 0; i < bytes.length; i++) {
      this.buffer.push(bytes[i] & 0xff);
      if (this.buffer.length === 64) {
        this.block(Md5.wordsOf(this.buffer));
        this.buffer = [];
      }
    }
  }

  private padding(): number[] {
    const tail: number[] = this.buffer.slice();
    tail.push(0x80);
    while (tail.length % 64 !== 56) {
      tail.push(0);
    }
    const bits = this.length * 8;
    // 64-bit little-endian bit length（JS 位运算 32 位，分两段写）
    const low = bits | 0;
    const high = Math.floor(bits / 4294967296) | 0;
    for (let i = 0; i < 4; i++) {
      tail.push((low >>> (i * 8)) & 0xff);
    }
    for (let i = 0; i < 4; i++) {
      tail.push((high >>> (i * 8)) & 0xff);
    }
    return tail;
  }

  hex(): string {
    const tail = this.padding();
    for (let i = 0; i < tail.length; i += 64) {
      this.block(Md5.wordsOf(tail.slice(i, i + 64)));
    }
    let hexStr = '';
    for (const word of [this.a, this.b, this.c, this.d]) {
      for (let i = 0; i < 4; i++) {
        const byte = (word >>> (i * 8)) & 0xff;
        hexStr += (byte < 16 ? '0' : '') + byte.toString(16);
      }
    }
    return hexStr;
  }
}

/** 严格模式收窄：字符串数组读取（非数组/含非字符串元素一律跳过）。 */
function stringListOf(value: Object | undefined): string[] {
  const out: string[] = [];
  if (Array.isArray(value)) {
    const items = value as Object[];
    for (const item of items) {
      if (typeof item === 'string') {
        out.push(item);
      }
    }
  }
  return out;
}

/** 严格模式收窄：map 读取（数组/标量返回 null）。 */
function mapOf(value: Object | undefined): Record<string, Object> | null {
  if (value !== null && value !== undefined && typeof value === 'object' && !Array.isArray(value)) {
    return value as Record<string, Object>;
  }
  return null;
}

export class TunBoxProfileBuilder {
  static smartAvailable(config: Record<string, Object>): boolean {
    const input = new TunBoxProfileInput();
    input.useSmart = true;
    const result = new TunBoxProfileResult();
    const copy = JSON.parse(JSON.stringify(config)) as Record<string, Object>;
    TunBoxProfileBuilder.addSmart(copy, input, result);
    return result.error.length === 0 && result.smartGroupName.length > 0;
  }

  static async enhanceStandalone(yaml: string, input: TunBoxProfileInput): Promise<TunBoxProfileResult> {
    const raw = await coreBridge.decodeYaml(yaml);
    const result = new TunBoxProfileResult();
    TunBoxProfileBuilder.addSmart(raw, input, result);
    return TunBoxProfileBuilder.finish(raw, result);
  }

  private static uniqueGroupName(base: string, names: Set<string>): string {
    let name = base;
    let suffix = 2;
    while (names.has(name)) { name = `${base} (TunBox ${suffix++})`; }
    names.add(name);
    return name;
  }

  private static addSmart(raw: Record<string, Object>, input: TunBoxProfileInput,
    result: TunBoxProfileResult): void {
    if (!input.useSmart) { return; }
    const names: Set<string> = new Set<string>(['GLOBAL', 'DIRECT', 'REJECT', 'PASS']);
    const candidates: string[] = [];
    const excluded = new RegExp(ClashConfigGenerator.SMART_INFO_NODE_FILTER, 'i');
    if (Array.isArray(raw['proxies'])) {
      for (const item of raw['proxies'] as Object[]) {
        const proxy = mapOf(item);
        const name = proxy === null ? undefined : proxy['name'];
        if (typeof name !== 'string' || name.length === 0) { continue; }
        const reserved = names.has(name);
        names.add(name);
        const type = proxy !== null && typeof proxy['type'] === 'string' ? proxy['type'] as string : '';
        if (!reserved && !excluded.test(name) && !name.startsWith('__')
          && !['direct', 'reject', 'reject-drop', 'pass', 'compatible'].includes(type.toLowerCase())) { candidates.push(name); }
      }
    }
    const providers = mapOf(raw['proxy-providers']);
    const providerNames = providers === null ? [] : Object.keys(providers);
    if (candidates.length < 2 && providerNames.length === 0) {
      result.error = '本订阅没有足够的智能选点候选节点';
      return;
    }
    const groups: Object[] = Array.isArray(raw['proxy-groups']) ? raw['proxy-groups'] as Object[] : [];
    let primary: Record<string, Object> | null = null;
    for (const item of groups) {
      const group = mapOf(item);
      if (group === null || typeof group['name'] !== 'string') { continue; }
      names.add(group['name'] as string);
      if (primary === null && group['type'] === 'select' && group['name'] !== 'GLOBAL') { primary = group; }
    }
    const catchall = TunBoxProfileBuilder.lastMatchTarget(stringListOf(raw['rules']));
    if (catchall.length > 0 && !['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS'].includes(catchall)) {
      primary = null;
      for (const item of groups) {
        const group = mapOf(item);
        if (group !== null && group['name'] === catchall && group['type'] === 'select') { primary = group; break; }
      }
    }
    const smartName = TunBoxProfileBuilder.uniqueGroupName(ClashConfigGenerator.SMART_GROUP_NAME, names);
    const smart: Record<string, Object> = {};
    smart['name'] = smartName;
    smart['type'] = 'smart';
    smart['hidden'] = true;
    smart['proxies'] = candidates;
    if (providerNames.length > 0) { smart['use'] = providerNames; }
    smart['url'] = input.smartTestUrl || LatencyTestUrl.DEFAULT_URL;
    smart['interval'] = 300;
    smart['timeout'] = 5000;
    smart['uselightgbm'] = true;
    smart['collectdata'] = false;
    smart['prefer-asn'] = false;
    smart['exclude-type'] = 'Direct|Reject|RejectDrop|Pass|Compatible';
    smart['exclude-filter'] = ClashConfigGenerator.SMART_INFO_NODE_FILTER;
    if (input.smartPolicyPriority.length > 0) { smart['policy-priority'] = input.smartPolicyPriority; }
    if (primary !== null) {
      primary['proxies'] = [smartName, ...stringListOf(primary['proxies'])];
      result.smartParentGroupName = primary['name'] as string;
    } else {
      const rules = stringListOf(raw['rules']);
      let target = TunBoxProfileBuilder.lastMatchTarget(rules);
      if (target.length === 0 && groups.length > 0) {
        const first = mapOf(groups[0]);
        if (first !== null && typeof first['name'] === 'string') { target = first['name'] as string; }
      }
      if (target.length === 0 || ['DIRECT', 'REJECT', 'REJECT-DROP', 'PASS'].includes(target)) {
        result.error = '本订阅没有可用于智能选择的代理出口';
        return;
      }
      const parentName = TunBoxProfileBuilder.uniqueGroupName('TunBox 代理选择', names);
      const parent: Record<string, Object> = {};
      parent['name'] = parentName;
      parent['type'] = 'select';
      parent['hidden'] = true;
      parent['proxies'] = [smartName, target];
      groups.unshift(parent);
      raw['rules'] = rules.map((rule: string): string => {
        const parts = rule.split(',');
        const index = TunBoxProfileBuilder.ruleTargetIndex(rule);
        if (index > 0 && parts[index].trim() === target) { parts[index] = parentName; }
        return parts.join(',');
      });
      result.smartParentGroupName = parentName;
    }
    groups.push(smart);
    for (const item of groups) {
      const group = mapOf(item);
      if (group !== null && group['name'] === 'GLOBAL' && group['type'] === 'select') {
        group['proxies'] = [smartName, ...stringListOf(group['proxies'])];
      }
    }
    raw['proxy-groups'] = groups;
    result.smartGroupName = smartName;
  }

  /**
   * FlClash 同构构建（异步壳）：内核解析 profile + overlay 解码 → 纯函数 compose。
   * 任何一步失败都返回 ok=false（调用方拒绝启动内核，与 FlClash applyProfile 抛错一致）。
   */
  static async build(input: TunBoxProfileInput): Promise<TunBoxProfileResult> {
    if (input.profilePath.length === 0 || input.overlayYaml.trim().length === 0) {
      const empty = new TunBoxProfileResult();
      empty.error = 'profile 路径或 overlay 为空';
      return empty;
    }
    // ① 内核解析 profile（FlClash getConfig；解析失败 = 订阅坏，如实上抛）
    const base = await coreBridge.getProfileBase(input.profilePath);
    // ② overlay（生成器产物）→ map：本仓 patchClashConfig 等价物
    const overlay = await coreBridge.decodeYaml(input.overlayYaml);
    // 每 profile 覆盖层（FlClash generalOverrideJson 语义：先于显式 patch 键）
    let overrides: Record<string, Object> | null = null;
    if (input.overrideYaml.trim().length > 0) {
      overrides = await coreBridge.decodeYaml(input.overrideYaml);
    }
    const data = new TunBoxBaseData();
    data.config = base.config;
    data.digest = base.digest;
    data.proxies = base.proxies;
    data.proxyGroups = base.proxyGroups;
    data.rules = base.rules;
    data.matchRules = base.matchRules;
    const result = TunBoxProfileBuilder.compose(data, overlay, overrides, input);
    // legacy provider 缓存迁移（FlClash `_migrateLegacyProviderFile`：best-effort，
    // 失败只留文件下次重下；新路径已存在或源不存在都跳过）。
    for (const migration of result.providerMigrations) {
      try {
        if (migration.from === migration.to) {
          continue;
        }
        if (fs.accessSync(migration.to)) {
          continue;
        }
        if (!fs.accessSync(migration.from)) {
          continue;
        }
        const slash = migration.to.lastIndexOf('/');
        if (slash > 0) {
          fs.mkdirSync(migration.to.substring(0, slash), true);
        }
        fs.renameSync(migration.from, migration.to);
      } catch (e) {
        AppLogger.warn(TAG, `provider cache migrate skipped: ${AppLogger.errText(e)}`);
      }
    }
    return result;
  }

  /**
   * 纯函数 compose：map patch 链 + JSON dump（build 的同步主体）。
   * 单独拆出来是为了让门禁在 Node 里直接喂 map 真跑（内核桥打桩），
   * 与生产路径共用同一份实现 —— 门禁测的就是上线代码。
   */
  static compose(base: TunBoxBaseData, overlay: Record<string, Object>,
    overrides: Record<string, Object> | null, input: TunBoxProfileInput): TunBoxProfileResult {
    const out = new TunBoxProfileResult();
    const raw = base.config;
    out.profileProxies = base.proxies;
    out.profileGroups = base.proxyGroups;
    out.profileRules = base.rules;
    const applied: string[] = [];
    // overrides 顶层键先进 raw（FlClash generalOverrideJson 语义）；
    // dns/tun/sniffer/ntp 四段**按按键合并**（同 mergeDnsOverride/mergeSnifferOverride，
    // 不能整段替换），各在本段处理时读 overrides，不在这里整段铺。
    if (overrides !== null) {
      const top: Record<string, Object> = {};
      for (const key of Object.keys(overrides)) {
        if (key === 'dns' || key === 'tun' || key === 'sniffer' || key === 'ntp') {
          continue;
        }
        const value = overrides[key];
        if (value !== undefined && value !== null) {
          top[key] = value;
        }
      }
      TunBoxProfileBuilder.setAll(raw, top);
    }
    // ③ patch 链（upstream _makeRealProfileTask 逐键顺序）
    // 3.1 控制器 / 端口 / 杂项运行期键（overlay 值 + FlClash 清零默认）
    for (const key of ['external-controller', 'secret', 'mixed-port', 'mode', 'log-level',
      'ipv6', 'unified-delay', 'tcp-concurrent', 'allow-lan', 'bind-address']) {
      const value = overlay[key];
      if (value !== undefined && value !== null) {
        raw[key] = value;
        applied.push(key);
      }
    }
    raw['external-ui'] = '';
    raw['external-ui-url'] = '';
    raw['external-ui-name'] = '';
    raw['external-controller-tls'] = '';
    raw['external-controller-unix'] = '';
    raw['external-controller-pipe'] = '';
    // iptables 多接口（FlClash task.dart:172-178）：inbound-interface 含空格 ⇒
    // 内核无法确定入口接口，整段禁用，不留歧义。
    const iptables = mapOf(raw['iptables']);
    if (iptables !== null) {
      const inboundInterface = iptables['inbound-interface'];
      if (typeof inboundInterface === 'string' && inboundInterface.indexOf(' ') >= 0) {
        const iptablesOff: Record<string, Object> = {};
        iptablesOff['enable'] = false;
        raw['iptables'] = iptablesOff;
      }
    }
    raw['interface-name'] = '';
    raw['port'] = 0;
    raw['socks-port'] = 0;
    raw['redir-port'] = 0;
    raw['tproxy-port'] = 0;
    raw['keep-alive-interval'] = KEEP_ALIVE_INTERVAL;
    raw['routing-mark'] = 0;
    raw['find-process-mode'] = FIND_PROCESS_MODE_OHOS;
    raw['allow-lan'] = false;
    raw['authentication'] = [];
    raw['skip-auth-prefixes'] = [];
    // FlClash patch 默认（PatchClashConfig @Default(true)）
    if (raw['unified-delay'] === undefined || raw['unified-delay'] === null) {
      raw['unified-delay'] = true;
    }
    if (raw['tcp-concurrent'] === undefined || raw['tcp-concurrent'] === null) {
      raw['tcp-concurrent'] = true;
    }
    raw['geo-auto-update'] = false;
    raw['geo-update-interval'] = 24;

    // 3.2 tun（FlClash task.dart:214-227）：{...profile tun, dns-hijack: default,
    //     ...overrides.tun 按键, ...patch tun coreJson, auto-detect-interface: true}
    //     —— dns-hijack 在 overrides 之前，用户可改；auto-detect-interface 恒 true 压轴。
    const tunPatch = mapOf(overlay['tun']);
    const tun: Record<string, Object> = {};
    const rawTun = mapOf(raw['tun']);
    if (rawTun !== null) {
      TunBoxProfileBuilder.setAll(tun, rawTun);
    }
    tun['dns-hijack'] = [DEFAULT_DNS_HIJACK];
    const overridesTun = overrides !== null ? mapOf(overrides['tun']) : null;
    if (overridesTun !== null) {
      TunBoxProfileBuilder.setAll(tun, overridesTun);
    }
    if (tunPatch !== null) {
      TunBoxProfileBuilder.setAll(tun, tunPatch);
    }
    tun['enable'] = input.tunEnabled;
    tun['auto-detect-interface'] = true;
    if (input.mtu > 0) {
      tun['mtu'] = input.mtu;
    }
    raw['tun'] = tun;
    applied.push('tun');

    // 3.3 sniffer（FlClash task.dart:230-248）：mergeSnifferOverride 按键合并
    //     （sniff 子表按协议名大小写无关替换），ports 归一化为字符串。
    //     overlay sniffer = App 设置块；overrides sniffer 再在其后按键合并。
    const rawSniffer = mapOf(raw['sniffer']);
    const overlaySniffer = mapOf(overlay['sniffer']);
    const overridesSniffer = overrides !== null ? mapOf(overrides['sniffer']) : null;
    if (overlaySniffer !== null || overridesSniffer !== null) {
      const sniffer: Record<string, Object> = {};
      if (rawSniffer !== null) {
        TunBoxProfileBuilder.setAll(sniffer, rawSniffer);
      }
      if (overlaySniffer !== null) {
        TunBoxProfileBuilder.mergeSnifferOverride(sniffer, overlaySniffer);
      }
      if (overridesSniffer !== null) {
        TunBoxProfileBuilder.mergeSnifferOverride(sniffer, overridesSniffer);
      }
      raw['sniffer'] = sniffer;
    }
    const snifferMap = mapOf(raw['sniffer']);
    if (snifferMap !== null) {
      const sniff = mapOf(snifferMap['sniff']);
      if (sniff !== null) {
        for (const key of Object.keys(sniff)) {
          const entry = mapOf(sniff[key]);
          if (entry === null || entry['ports'] === undefined || !Array.isArray(entry['ports'])) {
            continue;
          }
          const ports: string[] = [];
          for (const item of entry['ports'] as Object[]) {
            ports.push(TunBoxProfileBuilder.scalarText(item));
          }
          entry['ports'] = ports;
        }
      }
    }

    // 3.4 profile.store-selected = false（FlClash；选择由 App 的 selectedMap 恢复）
    const existingProfileSection = mapOf(raw['profile']);
    const profileSection: Record<string, Object> =
      existingProfileSection !== null ? existingProfileSection : {} as Record<string, Object>;
    profileSection['store-selected'] = false;
    raw['profile'] = profileSection;
    applied.push('profile');

    // 3.5 provider 全部收容（FlClash task.dart:135-160 confineProviders）：
    //     全部非 inline（含 file 型）→ path = <profiles>/providers/<id>/<type>/<md5(key)>
    //     有 URL：key = name@url；无 URL：key = section/name（proxies/rules 归属）。
    //     有 URL 的旧 URL-only 缓存记一笔迁移（build 侧 best-effort 改名）。
    let confined = 0;
    const providerSections: string[][] = [['proxy-providers', 'proxies'], ['rule-providers', 'rules']];
    for (const pair of providerSections) {
      const section = pair[0];
      const type = pair[1];
      const providers = mapOf(raw[section]);
      if (providers === null) {
        continue;
      }
      for (const name of Object.keys(providers)) {
        const provider = mapOf(providers[name]);
        if (provider === null) {
          continue;
        }
        if (provider['type'] === 'inline') {
          continue;
        }
        const url = provider['url'];
        const hasUrl = typeof url === 'string' && url.length > 0;
        const key = hasUrl ? `${name}@${url}` : `${section}/${name}`;
        provider['path'] = `${input.profilesDir}/providers/${input.profileId}/${type}/${md5Hex(key)}`;
        if (hasUrl) {
          const migration = new TunBoxProviderMigration();
          migration.from = `${input.profilesDir}/providers/${input.profileId}/${type}/${md5Hex(url as string)}`;
          migration.to = provider['path'] as string;
          out.providerMigrations.push(migration);
        }
        confined += 1;
      }
      applied.push(section);
    }
    out.confinedProviders = confined;

    // 3.6 geox-url / global-ua（FlClash task.dart:280-281）：
    //     geox-url 整段取补丁值（profile 自己的值丢弃）；
    //     global-ua 取设置值，空 = 默认 UA（provider 拉取 UA 同样取此值）。
    const geox: Record<string, Object> = {};
    for (const key of Object.keys(GEOX_URL)) {
      geox[key] = GEOX_URL[key];
    }
    raw['geox-url'] = geox;
    raw['global-ua'] = input.globalUa.trim().length > 0 ? input.globalUa.trim() : tunboxUserAgent();
    applied.push('global-ua');

    // 3.7 hosts：profile hosts + overlay hosts per-key 覆盖（FlClash hosts 语义）
    const overlayHosts = mapOf(overlay['hosts']);
    if (overlayHosts !== null) {
      const hosts: Record<string, Object> = {};
      const rawHosts = mapOf(raw['hosts']);
      if (rawHosts !== null) {
        TunBoxProfileBuilder.setAll(hosts, rawHosts);
      }
      TunBoxProfileBuilder.setAll(hosts, overlayHosts);
      raw['hosts'] = hosts;
      applied.push('hosts');
    } else if (raw['hosts'] === undefined || raw['hosts'] === null) {
      raw['hosts'] = {} as Record<string, Object>;
    }

    // 3.8 dns（FlClash task.dart:288-321）：三段合并
    //     ① baseline（应用 DNS 按键集）仅在订阅 dns 未启用时进；
    //     ② 用户 overrides 按键合并（恒进）；
    //     ③ appendSystemDns 时 nameserver 尾部追加 system://（已含则不重加）。
    //     mergeDnsOverride 按键覆盖，仅 fallback-filter 子表深合并。
    //     FlClash 无 dns.ipv6 强改：ipv6 按三段合并后的值原样落内核。
    let rawDns: Record<string, Object> = {};
    const baseDns = mapOf(raw['dns']);
    if (baseDns !== null) {
      TunBoxProfileBuilder.setAll(rawDns, baseDns);
    }
    const isEnableDns = baseDns !== null && baseDns['enable'] === true;
    const overlayDns = mapOf(overlay['dns']);
    if (overlayDns !== null && !isEnableDns) {
      rawDns = TunBoxProfileBuilder.mergeDnsOverride(rawDns, overlayDns);
    }
    const overridesDns = overrides !== null ? mapOf(overrides['dns']) : null;
    if (overridesDns !== null) {
      rawDns = TunBoxProfileBuilder.mergeDnsOverride(rawDns, overridesDns);
    }
    raw['dns'] = rawDns;
    applied.push('dns');
    if (input.appendSystemDns) {
      const nameserver = stringListOf(rawDns['nameserver']);
      if (!nameserver.includes('system://')) {
        rawDns['nameserver'] = [...nameserver, 'system://'];
      }
    }

    // 3.8b ntp（FlClash task.dart:307-313）：仅 overrides 非空时按键合并进 raw.ntp。
    const overridesNtp = overrides !== null ? mapOf(overrides['ntp']) : null;
    if (overridesNtp !== null && Object.keys(overridesNtp).length > 0) {
      const rawNtp: Record<string, Object> = {};
      const existingNtp = mapOf(raw['ntp']);
      if (existingNtp !== null) {
        TunBoxProfileBuilder.setAll(rawNtp, existingNtp);
      }
      TunBoxProfileBuilder.setAll(rawNtp, overridesNtp);
      raw['ntp'] = rawNtp;
      applied.push('ntp');
    }

    // 3.9 providers 声明段合并（FlClash injectUnconfinedProviders: injected 先铺，
    //     profile 后铺，同名 profile 赢；injected 路径保持落盘原值，不二次收容）。
    for (const key of ['proxy-providers', 'rule-providers']) {
      const injected = mapOf(overlay[key]);
      if (injected === null || Object.keys(injected).length === 0) {
        continue;
      }
      const merged: Record<string, Object> = {};
      TunBoxProfileBuilder.setAll(merged, injected);
      const rawProviders = mapOf(raw[key]);
      if (rawProviders !== null) {
        TunBoxProfileBuilder.setAll(merged, rawProviders);
      }
      raw[key] = merged;
    }

    // 3.10 rules（FlClash task.dart:338-373）：保留全部附加规则，不设目标白名单；
    //     仅把附加规则里 target=MATCH 的项替换为选定 matchTarget（缺省 = 最后 profile MATCH）。
    //     [...added, ...profile] 前置；no-resolve 等参数原样保留。
    const profileRules = stringListOf(raw['rules']);
    // The producer emits only intentional additions in profile mode, with MATCH
    // as the app's proxy-policy placeholder. Never silently drop user rules here.
    const addedRules = stringListOf(overlay['rules']);
    let replacementTarget = input.matchTarget.trim();
    if (replacementTarget.length === 0) {
      replacementTarget = TunBoxProfileBuilder.lastMatchTarget(profileRules);
    }
    const finalAddedRules: string[] = [];
    for (const rule of addedRules) {
      if (replacementTarget.length > 0 && TunBoxProfileBuilder.ruleTargetIsMatch(rule)) {
        finalAddedRules.push(TunBoxProfileBuilder.replaceMatchTarget(rule, replacementTarget));
      } else {
        finalAddedRules.push(rule);
      }
    }
    raw['rules'] = [...finalAddedRules, ...profileRules];
    applied.push('rules');

    TunBoxProfileBuilder.addSmart(raw, input, out);
    out.applied = applied.join(',');
    return TunBoxProfileBuilder.finish(raw, out);
  }

  private static finish(raw: Record<string, Object>, out: TunBoxProfileResult): TunBoxProfileResult {
    if (out.error.length > 0) { return out; }
    // ④ 结构化投影：组/规则/proxies（JSON dump 后的文本不再给 App 解析；
    //    钉选解析直接吃 map 数据）
    const groupInfos: TunBoxGroupInfo[] = [];
    if (Array.isArray(raw['proxy-groups'])) {
      for (const item of raw['proxy-groups'] as Object[]) {
        const group = mapOf(item);
        if (group === null || typeof group['name'] !== 'string') {
          continue;
        }
        const info = new TunBoxGroupInfo();
        info.name = group['name'];
        info.type = typeof group['type'] === 'string' ? group['type'] : '';
        for (const member of stringListOf(group['proxies'])) {
          info.members.push(member);
        }
        groupInfos.push(info);
      }
    }
    out.groups = groupInfos;
    out.rules = stringListOf(raw['rules']);
    const proxyNames: string[] = [];
    if (Array.isArray(raw['proxies'])) {
      for (const item of raw['proxies'] as Object[]) {
        const proxy = mapOf(item);
        const name = proxy !== null ? proxy['name'] : undefined;
        if (typeof name === 'string' && name.length > 0) {
          proxyNames.push(name);
        }
      }
    }
    out.proxyNames = proxyNames;

    // ⑤ dump：JSON（JSON ⊂ YAML；内核同一解析器加载，mihomo -t 实测通过）
    try {
      out.yaml = JSON.stringify(raw);
      out.ok = true;
    } catch (e) {
      out.error = `配置序列化失败：${String(e)}`;
    }
    return out;
  }

  /** 目标键覆盖（浅合并；undefined 值跳过）。 */
  private static setAll(target: Record<string, Object>, source: Record<string, Object>): void {
    for (const key of Object.keys(source)) {
      const value = source[key];
      if (value !== undefined && value !== null) {
        target[key] = value;
      }
    }
  }

  /** 标量 → 文本（sniffer ports 归一化用；FlClash `item.toString()` 同款）。 */
  private static scalarText(value: Object): string {
    if (typeof value === 'string') {
      return value;
    }
    if (typeof value === 'number' || typeof value === 'boolean') {
      return String(value);
    }
    return '';
  }

  /**
   * DNS 覆盖合并（FlClash clash_config.dart mergeDnsOverride）：
   * 逐键覆盖，仅 `fallback-filter` 子表为浅合并（{...raw, ...override}）。
   */
  private static mergeDnsOverride(
    raw: Record<string, Object>, override: Record<string, Object>): Record<string, Object> {
    const merged: Record<string, Object> = {};
    TunBoxProfileBuilder.setAll(merged, raw);
    for (const key of Object.keys(override)) {
      const value = override[key];
      if (value === undefined || value === null) {
        continue;
      }
      if (key === 'fallback-filter') {
        const current = mapOf(merged[key]);
        const next = mapOf(value);
        if (current !== null && next !== null) {
          const ff: Record<string, Object> = {};
          TunBoxProfileBuilder.setAll(ff, current);
          TunBoxProfileBuilder.setAll(ff, next);
          merged[key] = ff;
          continue;
        }
      }
      merged[key] = value;
    }
    return merged;
  }

  /**
   * Sniffer 覆盖合并（FlClash mergeSnifferOverride）：逐键覆盖；
   * `sniff` 子表按协议名大小写无关替换（mihomo 大小写无关匹配）。
   */
  private static mergeSnifferOverride(
    merged: Record<string, Object>, override: Record<string, Object>): void {
    for (const key of Object.keys(override)) {
      const value = override[key];
      if (value === undefined || value === null) {
        continue;
      }
      if (key !== 'sniff') {
        merged[key] = value;
        continue;
      }
      const next = mapOf(value);
      if (next === null) {
        continue;
      }
      const overridden = new Set<string>();
      for (const name of Object.keys(next)) {
        overridden.add(name.toUpperCase());
      }
      const nextSniff: Record<string, Object> = {};
      const rawSniff = mapOf(merged['sniff']);
      if (rawSniff !== null) {
        for (const name of Object.keys(rawSniff)) {
          if (!overridden.has(name.toUpperCase())) {
            nextSniff[name] = rawSniff[name];
          }
        }
      }
      TunBoxProfileBuilder.setAll(nextSniff, next);
      merged[key] = nextSniff;
    }
  }

  /** 最后一条 MATCH 规则的 target（FlClash lastMatchTarget：Rule.parse 语义，MATCH 取首字段）。
   * MATCH 行无 target 时继续往前找，找不到返回空串。 */
  private static lastMatchTarget(rules: string[]): string {
    for (let i = rules.length - 1; i >= 0; i--) {
      const parts = rules[i].split(',');
      if (parts.length < 2 || parts[0].trim().toUpperCase() !== 'MATCH') {
        continue;
      }
      const target = parts[1].trim();
      if (target.length > 0) {
        return target;
      }
    }
    return '';
  }

  /**
   * 规则 target 的字段下标（FlClash Rule.parse 语义，字符串级等价）：
   * 尾部 `src` / `no-resolve` 是 params 不是 target，跳过它们取第一个非参数字段。
   * MATCH 行 target 恒为字段 1，同样落在这个规律上。
   */
  private static ruleTargetIndex(rule: string): number {
    const parts = rule.split(',');
    let index = parts.length - 1;
    while (index > 1) {
      const field = parts[index].trim().toUpperCase();
      if (field === 'SRC' || field === 'NO-RESOLVE') {
        index -= 1;
      } else {
        break;
      }
    }
    return index;
  }

  private static ruleTargetIsMatch(rule: string): boolean {
    const index = TunBoxProfileBuilder.ruleTargetIndex(rule);
    const parts = rule.split(',');
    return index >= 0 && index < parts.length && parts[index].trim().toUpperCase() === 'MATCH';
  }

  /** 把规则里 target=MATCH 的字段替换为 replacement（参数原样保留）。 */
  private static replaceMatchTarget(rule: string, replacement: string): string {
    const index = TunBoxProfileBuilder.ruleTargetIndex(rule);
    const parts = rule.split(',').map((p: string): string => p.trim());
    if (index >= 0 && index < parts.length) {
      parts[index] = replacement;
    }
    return parts.join(',');
  }

}
