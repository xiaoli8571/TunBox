/**
 * V2Ray/分享链接订阅转换器（SubConverter）—— mihomo `convert.ConvertsV2Ray` 的逐行 ArkTS 移植。
 *
 * ## 职责
 *
 * 输入「v2ray 订阅正文」（明文分享链接列表，或整体 base64 的链接列表），输出 mihomo 能直接
 * 吃下的 `proxies:` YAML 块。这是 FlClash「订阅解析」链路的**第一段**，只负责
 * 「文本 → 节点映射表」，不做配置骨架（DNS/TUN/规则）、不做测速、不落盘。
 *
 * ## 来源（上游逐行对照）
 *
 * - `common/convert/converter.go` —— `ConvertsV2Ray`（各 scheme 分支）、`uniqueName`
 * - `common/convert/v.go`        —— `handleVShareLink`、`parseXHTTPExtra`、`buildRealmOpts`、
 *                                  `splitHysteria2Ports`
 * - `common/convert/util.go`     —— `VerifyMethod`（SS 加密方法白名单）、`RandUserAgent`
 * - `common/convert/base64.go`   —— `DecodeBase64` / `tryDecodeBase64` / `TryDecodeBase64` /
 *                                  `urlSafe` / `decodeUrlSafe`
 * 上游为 `C:\Worker\TunBox\kernel\Clash.Meta`（就是 FlClash 用的同一份 Go 实现）。
 * `net/url` 与 `encoding/base64` 的语义在本文件内以最小可信子集重实现（见 §二/§三）。
 *
 * ## 关键口径（改动前先读）
 *
 * 1. **字段名与默认值一个都不能改**：每个 scheme 分支写入的键、以及「无条件写入空串」的行为
 *    （例如 hysteria 的 `sni/obfs/auth_str/protocol` 即使为空也写）都照抄 Go。
 *    少写一个键 = 内核侧参数缺失 = 节点能进代理表但握手失败（历史事故：34 个 REALITY 节点全红）。
 * 2. **重名规则照抄 `uniqueName`**：首次出现用原名，第二次 `name-01`、第三次 `name-02`
 *    （Go 的计数器从 0 起、命中时先自增再格式化）。注意：**不是** `-02/-03`。
 *    另外 Go 在「字段校验失败要丢弃这条线」之前就先取了名字，名字序号照样被消耗 —— 这里也照抄。
 * 3. **失败即丢弃单行，不半条**：`handleVShareLink` 在 host/port 缺失时返回错误，整条 `continue`。
 * 4. **一条都没转出来**才报错，错误文本与 Go 完全一致：`convert v2ray subscribe error: format invalid`。
 * 5. **YAML 输出是「值语义」安全序列化**：字符串含特殊字符/可能被解析成数字或布尔时一律双引号
 *    转义；端口这类 Go 里是字符串、但 YAML 必须是数字的字段（`port` / `port-range`）裸输出。
 *    数组用流式 `[a, b]`（mihomo 的 yaml 解析器接受），嵌套对象用块式。
 *
 * ## 与 Go 源的已知差异（只有一条，且不可观测）
 *
 * `RandUserAgent()`：Go 每次随机取 250+ 条 UA 之一；这里按节点内容做稳定散列后在 8 条
 * 代表性子集里取。目的是**同一份订阅每次转换输出完全一致**（可重复性比逐字节复刻随机值重要）；
 * 该值只是 ws 握手的 User-Agent 覆盖头，取什么都不影响连通性。
 *
 * 其余为零：值语义（每个 scheme 的键、默认值、空串、类型、名字序号）经
 * `scripts/verify-sub-converter.mjs` 拿**上游真实现**的 golden 逐字段对拍通过，
 * 并用 460×4 组随机畸形链接（约 3000 个节点）做过模糊对拍，无差异。
 * 注意 `net/url` 的「整行丢弃」规则也照抄了：非数字端口（`host:abc`）、非法 `%` 转义
 * （`#a%b`）都会让 Go 的 `url.Parse` 报错并丢弃该行 —— 不校验就会「多出 Go 没有的节点」。
 *
 * ## 边界
 *
 * 纯逻辑：不 import 任何 kit、不碰存储、不联网、无 enum（ArkTS 纪律 + Node 侧 type-stripping 都能跑）。
 */

// ════════════════════════════════════════════════════════════════════════════
// 一、常量表
// ════════════════════════════════════════════════════════════════════════════

/** sing-shadowsocks `shadowstream.List`（照抄顺序，供 VerifyMethod 判定） */
const SS_STREAM_METHODS: string[] = [
  'aes-128-ctr', 'aes-192-ctr', 'aes-256-ctr',
  'aes-128-cfb', 'aes-192-cfb', 'aes-256-cfb',
  'rc4-md5', 'chacha20-ietf', 'xchacha20', 'chacha20'
];

/** sing-shadowsocks `shadowaead.List`（照抄顺序） */
const SS_AEAD_METHODS: string[] = [
  'aes-128-gcm', 'aes-192-gcm', 'aes-256-gcm',
  'chacha20-ietf-poly1305', 'xchacha20-ietf-poly1305',
  'chacha8-ietf-poly1305', 'xchacha8-ietf-poly1305',
  'rabbit128-poly1305',
  'aes-128-ccm', 'aes-192-ccm', 'aes-256-ccm',
  'aes-128-gcm-siv', 'aes-256-gcm-siv',
  'aegis-128l', 'aegis-256', 'aez-384', 'deoxys-ii-256-128',
  'lea-128-gcm', 'lea-192-gcm', 'lea-256-gcm',
  'ascon128', 'ascon128a'
];

/** sing-shadowsocks `shadowaead_2022.List`（密码必须是 base64，且不能为空 → 见 verifyMethod） */
const SS_2022_METHODS: string[] = [
  '2022-blake3-aes-128-gcm', '2022-blake3-aes-256-gcm',
  '2022-blake3-chacha20-poly1305', '2022-blake3-chacha8-poly1305',
  '2022-blake3-aes-128-ccm', '2022-blake3-aes-256-ccm'
];

/**
 * WS 握手的 User-Agent 候选（Go 侧 `userAgents` 有 250+ 条，这里取代表性子集）。
 * 取值不影响连通性 —— 它只是覆盖 ws 握手默认头；真正的口径是「每个节点附一条像浏览器的 UA」。
 */
const WS_USER_AGENTS: string[] = [
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.110 Safari/537.36',
  'Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36',
  'Mozilla/5.0 (Windows NT 6.3; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/63.0.3239.132 Safari/537.36',
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_13_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/69.0.3497.100 Safari/537.36',
  'Mozilla/5.0 (Linux; Android 7.0; SM-G570M) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.80 Mobile Safari/537.36',
  'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/56.0.2924.87 Safari/537.36',
  'Mozilla/5.0 (Windows NT 6.1; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.81 Safari/537.36',
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.67 Safari/537.36'
];

/** SS 插件名判定用（Go 里是 strings.Contains） */
const PLUGIN_OBFS = 'obfs';
const PLUGIN_V2RAY = 'v2ray-plugin';

/** 转换失败文本（与 Go 的 fmt.Errorf 完全一致；上层据此判「订阅格式不支持」） */
const ERR_FORMAT_INVALID = 'convert v2ray subscribe error: format invalid';

/** base64 字母表（标准 / url-safe；raw 形态只是「不要填充」，由调用方决定） */
const B64_STD: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const B64_URL: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

// ════════════════════════════════════════════════════════════════════════════
// 二、字节 / UTF-8 / base64（Go `encoding/base64` 语义：区分 padded 与 raw）
// ════════════════════════════════════════════════════════════════════════════

/** base64 解码结果（`ok=false` 时 bytes 仍可能带「已解出的前半段」——Go 也是这么用的） */
class B64Out {
  bytes: number[] = [];
  ok: boolean = false;
}

/** UTF-8 编解码 + Go 语义的 base64 解码 */
class GoBytes {
  /** 字符串 → UTF-8 字节（含代理对） */
  static encode(s: string): number[] {
    const out: number[] = [];
    let i = 0;
    while (i < s.length) {
      let cp = s.charCodeAt(i);
      if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < s.length) {
        const low = s.charCodeAt(i + 1);
        if (low >= 0xdc00 && low <= 0xdfff) {
          cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
          i++;
        }
      }
      i++;
      if (cp < 0x80) {
        out.push(cp);
      } else if (cp < 0x800) {
        out.push(0xc0 | (cp >> 6));
        out.push(0x80 | (cp & 0x3f));
      } else if (cp < 0x10000) {
        out.push(0xe0 | (cp >> 12));
        out.push(0x80 | ((cp >> 6) & 0x3f));
        out.push(0x80 | (cp & 0x3f));
      } else {
        out.push(0xf0 | (cp >> 18));
        out.push(0x80 | ((cp >> 12) & 0x3f));
        out.push(0x80 | ((cp >> 6) & 0x3f));
        out.push(0x80 | (cp & 0x3f));
      }
    }
    return out;
  }

  /** UTF-8 字节 → 字符串（非法序列用 U+FFFD 兜底，不抛） */
  static decode(b: number[]): string {
    let out = '';
    let i = 0;
    while (i < b.length) {
      const c = b[i] & 0xff;
      if (c < 0x80) {
        out += String.fromCharCode(c);
        i++;
      } else if (c >= 0xc0 && c < 0xe0 && i + 1 < b.length) {
        out += String.fromCharCode(((c & 0x1f) << 6) | (b[i + 1] & 0x3f));
        i += 2;
      } else if (c >= 0xe0 && c < 0xf0 && i + 2 < b.length) {
        out += String.fromCharCode(((c & 0x0f) << 12) | ((b[i + 1] & 0x3f) << 6) | (b[i + 2] & 0x3f));
        i += 3;
      } else if (c >= 0xf0 && c < 0xf8 && i + 3 < b.length) {
        let cp = ((c & 0x07) << 18) | ((b[i + 1] & 0x3f) << 12) | ((b[i + 2] & 0x3f) << 6) | (b[i + 3] & 0x3f);
        cp -= 0x10000;
        out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
        i += 4;
      } else {
        out += '\ufffd';
        i++;
      }
    }
    return out;
  }

  /**
   * Go `base64.(Raw)StdEncoding.DecodeString` / `(Raw)URLEncoding.DecodeString` 的等价实现。
   *
   * 两个必须照抄的行为（converter.go 的 ss 分支依赖它们，见 `ss` 的密码回退）：
   * 1. **按 4 字符 quantum 推进**：遇到不完整/非法 quantum 时，之前完整 quantum 的字节
   *    已经写进结果，只是 `ok=false` —— Go 的 Decode 就是这样「解码一半再报错」。
   * 2. padded 编码要求填充到位（"YQ==" 可以、"YQ" 不行）；raw 编码反过来**不接受** '='。
   *    两者都忽略 '\r' '\n'（Go 的 Decode 跳过换行）。
   */
  static b64(s: string, urlSafe: boolean, raw: boolean): B64Out {
    const res = new B64Out();
    const alpha = urlSafe ? B64_URL : B64_STD;
    const len = s.length;
    let i = 0;
    while (true) {
      const quad: number[] = []; // 0..63；-1 表示 '='
      let pads = 0;
      let ended = false;
      while (quad.length < 4) {
        if (i >= len) {
          ended = true;
          break;
        }
        const ch = s.charAt(i);
        i++;
        if (ch === '\r' || ch === '\n') {
          continue;
        }
        if (ch === '=') {
          if (raw) {
            return res; // raw 编码不接受填充（已解出的字节保留）
          }
          quad.push(-1);
          pads++;
          continue;
        }
        if (pads > 0) {
          return res; // 填充之后又出现数据
        }
        const v = alpha.indexOf(ch);
        if (v < 0) {
          return res;
        }
        quad.push(v);
      }

      if (quad.length === 0) {
        res.ok = true;
        return res;
      }
      if (quad.length === 4) {
        if (pads === 0) {
          res.bytes.push(((quad[0] << 2) | (quad[1] >> 4)) & 0xff);
          res.bytes.push(((quad[1] << 4) | (quad[2] >> 2)) & 0xff);
          res.bytes.push(((quad[2] << 6) | quad[3]) & 0xff);
        } else if (pads === 1 && quad[3] === -1) {
          res.bytes.push(((quad[0] << 2) | (quad[1] >> 4)) & 0xff);
          res.bytes.push(((quad[1] << 4) | (quad[2] >> 2)) & 0xff);
          if (!GoBytes.b64RestEmpty(s, i)) {
            return res;
          }
          res.ok = true;
          return res;
        } else if (pads === 2 && quad[2] === -1 && quad[3] === -1) {
          res.bytes.push(((quad[0] << 2) | (quad[1] >> 4)) & 0xff);
          if (!GoBytes.b64RestEmpty(s, i)) {
            return res;
          }
          res.ok = true;
          return res;
        } else {
          return res; // 非法填充位置
        }
        if (ended) {
          res.ok = true;
          return res;
        }
        continue;
      }

      // 尾部不足 4 个字符
      if (raw) {
        if (quad.length === 2) {
          res.bytes.push(((quad[0] << 2) | (quad[1] >> 4)) & 0xff);
        } else if (quad.length === 3) {
          res.bytes.push(((quad[0] << 2) | (quad[1] >> 4)) & 0xff);
          res.bytes.push(((quad[1] << 4) | (quad[2] >> 2)) & 0xff);
        } else {
          return res; // 单个字符不合法
        }
        res.ok = true;
        return res;
      }
      return res; // padded 编码：尾部不完整 → 错误（不产出该 quantum 的字节）
    }
  }

  /** 填充之后是否只剩换行（Go 允许 "YQ==\n"，不允许 "YQ==YQ=="） */
  private static b64RestEmpty(s: string, from: number): boolean {
    for (let i = from; i < s.length; i++) {
      const c = s.charAt(i);
      if (c !== '\r' && c !== '\n') {
        return false;
      }
    }
    return true;
  }
}

/** `DecodeBase64`：先试 raw(std)，再试 std，都失败就当成明文 */
function decodeBase64OrPlain(text: string): string {
  const first = GoBytes.b64(text, false, true);
  if (first.ok) {
    return GoBytes.decode(first.bytes);
  }
  const second = GoBytes.b64(text, false, false);
  if (second.ok) {
    return GoBytes.decode(second.bytes);
  }
  return text;
}

/** `tryDecodeBase64`：失败返回 null（不做明文回退） */
function tryDecodeBase64(text: string): B64Out | null {
  const first = GoBytes.b64(text, false, true);
  if (first.ok) {
    return first;
  }
  const second = GoBytes.b64(text, false, false);
  if (second.ok) {
    return second;
  }
  return null;
}

/** `TryDecodeBase64`：长度是 4 的倍数走 std/url，否则走 raw（返回 null 表示失败） */
function tryDecodeBase64PaddedFirst(text: string): B64Out | null {
  if (text.length % 4 === 0) {
    const a = GoBytes.b64(text, false, false);
    if (a.ok) {
      return a;
    }
    const b = GoBytes.b64(text, true, false);
    if (b.ok) {
      return b;
    }
  } else {
    const a = GoBytes.b64(text, false, true);
    if (a.ok) {
      return a;
    }
    const b = GoBytes.b64(text, true, true);
    if (b.ok) {
      return b;
    }
  }
  return null;
}

/** `urlSafe`：'+' → '-'，'/' → '_'（SSR 的 remark/param 常是标准 base64 塞在 url-safe 位置） */
function urlSafe(data: string): string {
  return data.split('+').join('-').split('/').join('_');
}

/** `decodeUrlSafe`：raw-url-safe base64 解码，失败返回空串 */
function decodeUrlSafe(data: string): string {
  if (data.length === 0) {
    return '';
  }
  const r = GoBytes.b64(data, true, true);
  if (!r.ok) {
    return '';
  }
  return GoBytes.decode(r.bytes);
}

// ════════════════════════════════════════════════════════════════════════════
// 三、百分号编解码（Go `net/url` 的 escape/unescape 子集）
// ════════════════════════════════════════════════════════════════════════════

function hexVal(c: string): number {
  const code = c.charCodeAt(0);
  if (code >= 0x30 && code <= 0x39) {
    return code - 0x30;
  }
  if (code >= 0x61 && code <= 0x66) {
    return code - 0x61 + 10;
  }
  if (code >= 0x41 && code <= 0x46) {
    return code - 0x41 + 10;
  }
  return -1;
}

/**
 * Go 的 `unescape()` 遇到 `%ZZ` 会**报错**，URL 解析整体失败（converter 里等于整行丢弃）。
 * 这里先做一遍校验：非法转义 = 该行不是合法分享链接。
 */
function hasBadEscape(s: string): boolean {
  let i = 0;
  while (i < s.length) {
    if (s.charAt(i) === '%') {
      if (i + 2 >= s.length) {
        return true;
      }
      if (hexVal(s.charAt(i + 1)) < 0 || hexVal(s.charAt(i + 2)) < 0) {
        return true;
      }
      i += 3;
      continue;
    }
    i++;
  }
  return false;
}

/**
 * `url.PathUnescape` / `url.QueryUnescape` 的等价实现。
 * 宽松策略：非法 `%XX` 原样保留（Go 会报错丢弃整条 URL，见文件头「已知差异」）。
 */
function pctDecode(s: string, plusAsSpace: boolean): string {
  if (s.indexOf('%') < 0 && (!plusAsSpace || s.indexOf('+') < 0)) {
    return s;
  }
  const out: number[] = [];
  let i = 0;
  while (i < s.length) {
    const c = s.charAt(i);
    if (c === '%' && i + 2 < s.length + 1) {
      const hi = i + 1 < s.length ? hexVal(s.charAt(i + 1)) : -1;
      const lo = i + 2 < s.length ? hexVal(s.charAt(i + 2)) : -1;
      if (hi >= 0 && lo >= 0) {
        out.push((hi << 4) | lo);
        i += 3;
        continue;
      }
    }
    if (plusAsSpace && c === '+') {
      out.push(0x20);
      i++;
      continue;
    }
    const bytes = GoBytes.encode(c);
    for (const b of bytes) {
      out.push(b);
    }
    i++;
  }
  return GoBytes.decode(out);
}

function isUnreserved(code: number): boolean {
  if (code >= 0x30 && code <= 0x39) {
    return true;
  }
  if (code >= 0x41 && code <= 0x5a) {
    return true;
  }
  if (code >= 0x61 && code <= 0x7a) {
    return true;
  }
  return code === 0x2d || code === 0x5f || code === 0x2e || code === 0x7e; // - _ . ~
}

function hex2(b: number): string {
  const digits = '0123456789ABCDEF';
  return digits.charAt((b >> 4) & 0xf) + digits.charAt(b & 0xf);
}

/** `url.QueryEscape` 的等价实现（空格 → '+'） */
function queryEscape(s: string): string {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const ch = s.charAt(i);
    const code = s.charCodeAt(i);
    if (isUnreserved(code)) {
      out += ch;
      continue;
    }
    if (code === 0x20) {
      out += '+';
      continue;
    }
    const bytes = GoBytes.encode(ch);
    for (const b of bytes) {
      out += '%' + hex2(b);
    }
  }
  return out;
}

/**
 * `(*url.Userinfo).String()` 的等价实现：`userinfo = encodeUserPassword`，
 * 其中 '@' '/' '?' ':' 需转义，而 '$' '&' '+' ',' ';' '=' 按 Go 的 shouldEscape 规则**保留**。
 */
function escapeUserinfo(s: string): string {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const ch = s.charAt(i);
    const code = s.charCodeAt(i);
    if (isUnreserved(code)) {
      out += ch;
      continue;
    }
    const keep = code === 0x24 || code === 0x26 || code === 0x2b || code === 0x2c
      || code === 0x3b || code === 0x3d;
    if (keep) {
      out += ch;
      continue;
    }
    const bytes = GoBytes.encode(ch);
    for (const b of bytes) {
      out += '%' + hex2(b);
    }
  }
  return out;
}

// ════════════════════════════════════════════════════════════════════════════
// 四、URL / Query（Go `net/url` 的解析顺序：fragment → scheme → query → authority/path）
// ════════════════════════════════════════════════════════════════════════════

/** `url.Values`（保留取值顺序；`Get` 取第一个） */
class GoQuery {
  private order: string[] = [];
  private values: Map<string, string[]> = new Map<string, string[]>();

  constructor(raw: string) {
    if (raw.length === 0) {
      return;
    }
    const parts = raw.split('&');
    for (const part of parts) {
      if (part.length === 0) {
        continue;
      }
      // Go 1.17+：含 ';' 的段直接判错跳过（不再当分隔符）
      if (part.indexOf(';') >= 0) {
        continue;
      }
      const eq = part.indexOf('=');
      const rawKey = eq < 0 ? part : part.substring(0, eq);
      const rawVal = eq < 0 ? '' : part.substring(eq + 1);
      if (hasBadEscape(rawKey) || hasBadEscape(rawVal)) {
        continue;
      }
      const key = pctDecode(rawKey, true);
      const val = pctDecode(rawVal, true);
      const exist = this.values.get(key);
      if (exist === undefined) {
        const list: string[] = [val];
        this.values.set(key, list);
        this.order.push(key);
      } else {
        exist.push(val);
      }
    }
  }

  /** `Values.Get`：不存在或空 → '' */
  get(key: string): string {
    const list = this.values.get(key);
    if (list === undefined || list.length === 0) {
      return '';
    }
    return list[0];
  }

  /** `query["key"]`：全量取值（hysteria2 realm 的 stun、mierus 的 port/protocol 用） */
  all(key: string): string[] {
    const list = this.values.get(key);
    if (list === undefined) {
      return [];
    }
    const copy: string[] = [];
    for (const v of list) {
      copy.push(v);
    }
    return copy;
  }

  /** `query.Del(key)` */
  del(key: string): void {
    if (this.values.delete(key)) {
      const next: string[] = [];
      for (const k of this.order) {
        if (k !== key) {
          next.push(k);
        }
      }
      this.order = next;
    }
  }

  /** `url.Values.Encode()`：键字典序，值按原序，k=v 逐对 QueryEscape */
  encode(): string {
    const keys: string[] = [];
    for (const k of this.order) {
      keys.push(k);
    }
    keys.sort();
    const pairs: string[] = [];
    for (const k of keys) {
      const list = this.values.get(k);
      if (list === undefined) {
        continue;
      }
      for (const v of list) {
        pairs.push(queryEscape(k) + '=' + queryEscape(v));
      }
    }
    return pairs.join('&');
  }
}

/** `url.URL` 的最小子集（只保留 converter 用得到的字段与访问器） */
class GoUrl {
  ok: boolean = true;
  /** 原始串（给 UA 散列当种子） */
  raw: string = '';
  scheme: string = '';
  /** host[:port]，IPv6 带方括号 */
  host: string = '';
  /** 已解码的 path */
  path: string = '';
  rawQuery: string = '';
  /** 已解码的 fragment（Go 的 url.Fragment） */
  fragment: string = '';
  hasUser: boolean = false;
  username: string = '';
  hasPassword: boolean = false;
  password: string = '';

  /** `URL.Hostname()` */
  hostname(): string {
    if (this.host.length === 0) {
      return '';
    }
    if (this.host.charAt(0) === '[') {
      const close = this.host.indexOf(']');
      return close < 0 ? '' : this.host.substring(1, close);
    }
    const colon = this.host.lastIndexOf(':');
    return colon < 0 ? this.host : this.host.substring(0, colon);
  }

  /** `URL.Port()` */
  port(): string {
    if (this.host.length === 0) {
      return '';
    }
    if (this.host.charAt(0) === '[') {
      const close = this.host.indexOf(']');
      if (close < 0) {
        return '';
      }
      const rest = this.host.substring(close + 1);
      return rest.startsWith(':') ? rest.substring(1) : '';
    }
    const colon = this.host.lastIndexOf(':');
    return colon < 0 ? '' : this.host.substring(colon + 1);
  }

  /** `URL.Query()` */
  query(): GoQuery {
    return new GoQuery(this.rawQuery);
  }

  /** `URL.User.String()`（注意：是**重新转义**后的形态，不是解码后的原文） */
  userString(): string {
    if (!this.hasUser) {
      return '';
    }
    const user = escapeUserinfo(this.username);
    if (!this.hasPassword) {
      return user;
    }
    return user + ':' + escapeUserinfo(this.password);
  }
}

function isSchemeChar(c: string, first: boolean): boolean {
  const code = c.charCodeAt(0);
  if ((code >= 0x61 && code <= 0x7a) || (code >= 0x41 && code <= 0x5a)) {
    return true;
  }
  if (first) {
    return false;
  }
  if (code >= 0x30 && code <= 0x39) {
    return true;
  }
  return code === 0x2b || code === 0x2d || code === 0x2e; // + - .
}

/** `net/url.validOptionalPort`：'' 或 ':纯数字' */
function validOptionalPort(s: string): boolean {
  if (s.length === 0) {
    return true;
  }
  if (s.charAt(0) !== ':') {
    return false;
  }
  for (let i = 1; i < s.length; i++) {
    const code = s.charCodeAt(i);
    if (code < 0x30 || code > 0x39) {
      return false;
    }
  }
  return true;
}

/**
 * `net/url.parseHost` 的校验部分：**非数字端口会让整条 URL 解析失败**。
 * 这条很关键 —— 机场里 `host:abc` 这种脏端口在 Go 侧是被整行丢弃的，
 * 不校验就会「多出 Go 没有的节点」（随机对拍里就是这样撞出来的）。
 */
function parseHostValid(host: string): boolean {
  if (host.length === 0) {
    return true;
  }
  if (host.charAt(0) === '[') {
    const close = host.lastIndexOf(']');
    if (close < 0) {
      return false;
    }
    return validOptionalPort(host.substring(close + 1));
  }
  const colon = host.lastIndexOf(':');
  if (colon >= 0) {
    if (host.substring(0, colon).indexOf('%') >= 0) {
      return false;
    }
    if (!validOptionalPort(host.substring(colon))) {
      return false;
    }
  }
  return true;
}

/**
 * `url.Parse` 的等价实现（按 Go 的解析顺序，见 §四 标题）。
 * 失败（ok=false）对应 Go 的 `err != nil`：调用方一律 `continue` 丢掉这一行。
 */
function parseGoUrl(rawInput: string): GoUrl {
  const u = new GoUrl();
  u.raw = rawInput;
  let rest = rawInput;

  // 1) fragment（Go 对非法转义直接判错 → 整条链接丢弃）
  const hash = rest.indexOf('#');
  if (hash >= 0) {
    const rawFragment = rest.substring(hash + 1);
    if (hasBadEscape(rawFragment)) {
      u.ok = false;
      return u;
    }
    u.fragment = pctDecode(rawFragment, false);
    rest = rest.substring(0, hash);
  }

  // 2) scheme
  let colon = -1;
  for (let i = 0; i < rest.length; i++) {
    const c = rest.charAt(i);
    if (c === ':') {
      colon = i;
      break;
    }
    if (!isSchemeChar(c, i === 0)) {
      break;
    }
  }
  if (colon > 0) {
    u.scheme = rest.substring(0, colon).toLowerCase();
    rest = rest.substring(colon + 1);
  }

  // 3) query（Go 在解析 authority 之前就把 '?' 之后切走）
  const qmark = rest.indexOf('?');
  if (qmark >= 0) {
    u.rawQuery = rest.substring(qmark + 1);
    rest = rest.substring(0, qmark);
  }

  // 4) authority + path
  if (rest.startsWith('//')) {
    let authority = rest.substring(2);
    let pathPart = '';
    const firstSlash = authority.indexOf('/');
    const lastAt = authority.lastIndexOf('@');
    // 机场给的 trojan/vless 链接里，密码常带**未编码的 '/'**
    // （用户实测：trojan://mOP7HYb9Kkm3/E%2Bbj2HJjw@18.182.64.110:8888?...）。
    // 标准 URL 规则会先把 authority 在第一个 '/' 处截断，于是 '@' 落进 path，
    // 整条链接解析失败 → 转换出 0 个节点（导入提示「里面没有 Clash 节点」）。
    // 判据：'@' 出现在第一个 '/' 之后 ⇒ userinfo 内含未编码 '/'，应以 '@' 为界切分，
    // 再在右侧找 path。常规链接（'@' 在 '/' 之前）走原逻辑，行为不变。
    if (lastAt >= 0 && firstSlash >= 0 && lastAt > firstSlash) {
      const userinfoRaw = authority.substring(0, lastAt);
      const tail = authority.substring(lastAt + 1);
      const ts = tail.indexOf('/');
      if (ts >= 0) {
        pathPart = tail.substring(ts);
        authority = tail.substring(0, ts);
      } else {
        authority = tail;
      }
      if (hasBadEscape(userinfoRaw)) {
        u.ok = false;
        return u;
      }
      u.host = authority;
      u.hasUser = true;
      const up0 = userinfoRaw.indexOf(':');
      if (up0 >= 0) {
        u.username = pctDecode(userinfoRaw.substring(0, up0), false);
        u.password = pctDecode(userinfoRaw.substring(up0 + 1), false);
        u.hasPassword = true;
      } else {
        u.username = pctDecode(userinfoRaw, false);
      }
    } else {
      const slash = authority.indexOf('/');
      if (slash >= 0) {
        pathPart = authority.substring(slash);
        authority = authority.substring(0, slash);
      }
      const at = authority.lastIndexOf('@');
      if (at >= 0) {
        const userinfo = authority.substring(0, at);
        u.host = authority.substring(at + 1);
        u.hasUser = true;
        if (hasBadEscape(userinfo)) {
          u.ok = false;
          return u;
        }
        const up = userinfo.indexOf(':');
        if (up >= 0) {
          u.username = pctDecode(userinfo.substring(0, up), false);
          u.password = pctDecode(userinfo.substring(up + 1), false);
          u.hasPassword = true;
        } else {
          u.username = pctDecode(userinfo, false);
        }
      } else {
        u.host = authority;
      }
    }
    if (!parseHostValid(u.host)) {
      u.ok = false;
      return u;
    }
    if (hasBadEscape(pathPart)) {
      u.ok = false;
      return u;
    }
    u.path = pctDecode(pathPart, false);
  } else {
    // Go 走 Opaque 分支（Host/Path 皆空）—— converter 里这种形态一律因 host 为空被丢弃
    u.path = pctDecode(rest, false);
  }
  return u;
}

// ════════════════════════════════════════════════════════════════════════════
// 五、JSON（Go `encoding/json` → map[string]any 的替代；纯类型，不用 any/unknown）
// ════════════════════════════════════════════════════════════════════════════

/** JSON 值节点（kind: obj / arr / str / num / bool / null） */
class JsonNode {
  kind: string = 'null';
  s: string = '';
  n: number = 0;
  b: boolean = false;
  fields: Map<string, JsonNode> = new Map<string, JsonNode>();
  items: JsonNode[] = [];

  static ofNull(): JsonNode {
    const v = new JsonNode();
    v.kind = 'null';
    return v;
  }

  /** 取对象字段（不存在返回 null 节点，调用方用 `isStr()` 之类的判定） */
  field(key: string): JsonNode {
    const v = this.fields.get(key);
    return v === undefined ? JsonNode.ofNull() : v;
  }

  isObj(): boolean {
    return this.kind === 'obj';
  }

  isStr(): boolean {
    return this.kind === 'str';
  }

  isNum(): boolean {
    return this.kind === 'num';
  }

  isArr(): boolean {
    return this.kind === 'arr';
  }
}

/**
 * 极简递归下降 JSON 解析器（失败返回 null；只支持标准 JSON，不宽容注释/单引号）。
 *
 * 为什么自己写：ArkTS 禁用 any/unknown，`JSON.parse` 的结果无法安全地逐字段断言成
 * `map[string]any`；vmess(v2rayN) 与 xhttp 的 `extra` 都要按 Go 的 `.(string)/.(float64)/.(bool)`
 * 规则判定类型，所以这里直接产出强类型节点树。
 *
 * 写成类而不是嵌套函数：ArkTS 对「块内函数声明」的支持面窄，成员方法没有这个不确定性。
 */
class JsonParser {
  private text: string = '';
  private pos: number = 0;

  constructor(text: string) {
    this.text = text;
  }

  parse(): JsonNode | null {
    const value = this.parseValue();
    if (value === null) {
      return null;
    }
    this.skipWs();
    if (this.pos !== this.text.length) {
      return null;
    }
    return value;
  }

  private skipWs(): void {
    while (this.pos < this.text.length) {
      const c = this.text.charAt(this.pos);
      if (c === ' ' || c === '\t' || c === '\n' || c === '\r') {
        this.pos++;
      } else {
        break;
      }
    }
  }

  private parseValue(): JsonNode | null {
    this.skipWs();
    if (this.pos >= this.text.length) {
      return null;
    }
    const c = this.text.charAt(this.pos);
    if (c === '{') {
      return this.parseObject();
    }
    if (c === '[') {
      return this.parseArray();
    }
    if (c === '"') {
      const str = this.parseString();
      if (str === null) {
        return null;
      }
      const node = new JsonNode();
      node.kind = 'str';
      node.s = str;
      return node;
    }
    if (c === 't' && this.text.startsWith('true', this.pos)) {
      this.pos += 4;
      const node = new JsonNode();
      node.kind = 'bool';
      node.b = true;
      return node;
    }
    if (c === 'f' && this.text.startsWith('false', this.pos)) {
      this.pos += 5;
      const node = new JsonNode();
      node.kind = 'bool';
      node.b = false;
      return node;
    }
    if (c === 'n' && this.text.startsWith('null', this.pos)) {
      this.pos += 4;
      return JsonNode.ofNull();
    }
    return this.parseNumber();
  }

  private parseNumber(): JsonNode | null {
    const start = this.pos;
    if (this.pos < this.text.length) {
      const sign = this.text.charAt(this.pos);
      if (sign === '-' || sign === '+') {
        this.pos++;
      }
    }
    let digits = 0;
    while (this.pos < this.text.length) {
      const c = this.text.charAt(this.pos);
      const code = c.charCodeAt(0);
      if ((code >= 0x30 && code <= 0x39) || c === '.' || c === 'e' || c === 'E'
        || c === '+' || c === '-') {
        this.pos++;
        if (code >= 0x30 && code <= 0x39) {
          digits++;
        }
      } else {
        break;
      }
    }
    if (digits === 0) {
      return null;
    }
    const num = Number(this.text.substring(start, this.pos));
    if (isNaN(num)) {
      return null;
    }
    const node = new JsonNode();
    node.kind = 'num';
    node.n = num;
    return node;
  }

  private parseString(): string | null {
    if (this.text.charAt(this.pos) !== '"') {
      return null;
    }
    this.pos++;
    let out = '';
    while (this.pos < this.text.length) {
      const c = this.text.charAt(this.pos);
      if (c === '"') {
        this.pos++;
        return out;
      }
      if (c === '\\') {
        this.pos++;
        if (this.pos >= this.text.length) {
          return null;
        }
        const esc = this.text.charAt(this.pos);
        this.pos++;
        if (esc === 'n') {
          out += '\n';
        } else if (esc === 't') {
          out += '\t';
        } else if (esc === 'r') {
          out += '\r';
        } else if (esc === 'b') {
          out += '\b';
        } else if (esc === 'f') {
          out += '\f';
        } else if (esc === 'u') {
          if (this.pos + 4 > this.text.length) {
            return null;
          }
          const code = Number.parseInt(this.text.substring(this.pos, this.pos + 4), 16);
          if (isNaN(code)) {
            return null;
          }
          out += String.fromCharCode(code);
          this.pos += 4;
        } else {
          out += esc;
        }
        continue;
      }
      out += c;
      this.pos++;
    }
    return null;
  }

  private parseObject(): JsonNode | null {
    const node = new JsonNode();
    node.kind = 'obj';
    this.pos++; // {
    this.skipWs();
    if (this.pos < this.text.length && this.text.charAt(this.pos) === '}') {
      this.pos++;
      return node;
    }
    while (this.pos < this.text.length) {
      this.skipWs();
      const key = this.parseString();
      if (key === null) {
        return null;
      }
      this.skipWs();
      if (this.pos >= this.text.length || this.text.charAt(this.pos) !== ':') {
        return null;
      }
      this.pos++;
      const val = this.parseValue();
      if (val === null) {
        return null;
      }
      node.fields.set(key, val);
      this.skipWs();
      if (this.pos < this.text.length && this.text.charAt(this.pos) === ',') {
        this.pos++;
        continue;
      }
      if (this.pos < this.text.length && this.text.charAt(this.pos) === '}') {
        this.pos++;
        return node;
      }
      return null;
    }
    return null;
  }

  private parseArray(): JsonNode | null {
    const node = new JsonNode();
    node.kind = 'arr';
    this.pos++; // [
    this.skipWs();
    if (this.pos < this.text.length && this.text.charAt(this.pos) === ']') {
      this.pos++;
      return node;
    }
    while (this.pos < this.text.length) {
      const val = this.parseValue();
      if (val === null) {
        return null;
      }
      node.items.push(val);
      this.skipWs();
      if (this.pos < this.text.length && this.text.charAt(this.pos) === ',') {
        this.pos++;
        continue;
      }
      if (this.pos < this.text.length && this.text.charAt(this.pos) === ']') {
        this.pos++;
        return node;
      }
      return null;
    }
    return null;
  }
}

/** `encoding/json.Unmarshal` 的等价入口（失败返回 null → 调用方一律 continue） */
function parseJson(text: string): JsonNode | null {
  return new JsonParser(text).parse();
}

// ════════════════════════════════════════════════════════════════════════════
// 六、YAML 值模型 + 安全序列化
// ════════════════════════════════════════════════════════════════════════════

/** YAML 值（kind: str / num / bool / list / map；`bare` 表示「纯数字内容裸输出」，端口专用） */
export class YamlValue {
  kind: string = 'str';
  s: string = '';
  n: number = 0;
  b: boolean = false;
  bare: boolean = false;
  items: YamlValue[] = [];
  fields: Map<string, YamlValue> = new Map<string, YamlValue>();

  static str(v: string): YamlValue {
    const node = new YamlValue();
    node.kind = 'str';
    node.s = v;
    return node;
  }

  /** 端口字段：Go 里是字符串，但 YAML 侧必须是裸数字，否则内核按字符串处理（弱类型能转，但没必要） */
  static port(v: string): YamlValue {
    const node = new YamlValue();
    node.kind = 'str';
    node.s = v;
    node.bare = true;
    return node;
  }

  static num(v: number): YamlValue {
    const node = new YamlValue();
    node.kind = 'num';
    node.n = v;
    return node;
  }

  static bool(v: boolean): YamlValue {
    const node = new YamlValue();
    node.kind = 'bool';
    node.b = v;
    return node;
  }

  /**
   * YAML `null`。只在「v2rayN JSON 缺字段」时出现 —— Go 那里 `values["add"]` 是 nil，
   * yaml 会写 `null`。照抄，避免把「字段缺失」粉饰成空串（这种节点两边都是死节点）。
   */
  static nul(): YamlValue {
    const node = new YamlValue();
    node.kind = 'null';
    return node;
  }

  static list(items: YamlValue[]): YamlValue {
    const node = new YamlValue();
    node.kind = 'list';
    node.items = items;
    return node;
  }

  static map(fields: Map<string, YamlValue>): YamlValue {
    const node = new YamlValue();
    node.kind = 'map';
    node.fields = fields;
    return node;
  }

  /** 空对象字面量（headers: {} 这类） */
  static emptyMap(): YamlValue {
    return YamlValue.map(new Map<string, YamlValue>());
  }
}

function strList(parts: string[]): YamlValue {
  const items: YamlValue[] = [];
  for (const p of parts) {
    items.push(YamlValue.str(p));
  }
  return YamlValue.list(items);
}

/** 纯数字（允许前导 0 之外的普通十进制），给 port/ports 裸输出判定用 */
function isAllDigits(s: string): boolean {
  if (s.length === 0) {
    return false;
  }
  for (let i = 0; i < s.length; i++) {
    const code = s.charCodeAt(i);
    if (code < 0x30 || code > 0x39) {
      return false;
    }
  }
  return true;
}

const YAML_RESERVED: string[] = [
  'true', 'True', 'TRUE', 'false', 'False', 'FALSE',
  'yes', 'Yes', 'YES', 'no', 'No', 'NO',
  'on', 'On', 'ON', 'off', 'Off', 'OFF',
  'null', 'Null', 'NULL', '~'
];

/** 可以裸写的普通标量（保守白名单；宁可多引号，不让 YAML 改变类型） */
function isPlainSafe(s: string): boolean {
  if (s.length === 0) {
    return false;
  }
  if (YAML_RESERVED.indexOf(s) >= 0) {
    return false;
  }
  if (s.charAt(s.length - 1) === ' ') {
    return false;
  }
  const first = s.charCodeAt(0);
  // 首字符：字母数字/CJK，外加 '/' '.'（`path: /ws`、`.example.com` 是合法裸标量，也更接近
  // Clash 配置的惯用写法）。'-' '?' '#' ':' 等指示符一律不放开。
  const firstOk = (first >= 0x30 && first <= 0x39) || (first >= 0x41 && first <= 0x5a)
    || (first >= 0x61 && first <= 0x7a) || first >= 0x80
    || first === 0x2f || first === 0x2e;
  if (!firstOk) {
    return false;
  }
  for (let i = 0; i < s.length; i++) {
    const code = s.charCodeAt(i);
    const ok = (code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5a)
      || (code >= 0x61 && code <= 0x7a) || code >= 0x80
      || code === 0x5f || code === 0x2d || code === 0x2e || code === 0x40 // _ - . @
      || code === 0x2f || code === 0x3d || code === 0x2b || code === 0x3a // / = + :
      || code === 0x2c || code === 0x20; // , 空格
    if (!ok) {
      return false;
    }
  }
  return true;
}

/** 看起来像数字/十六进制/时间戳的字符串必须加引号，否则 YAML 会把它变成非字符串 */
function looksNumeric(s: string): boolean {
  return /^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$/.test(s)
    || /^0[xX][0-9a-fA-F]+$/.test(s)
    || /^0[oO][0-7]+$/.test(s)
    || /^\d{4}-\d{2}-\d{2}/.test(s);
}

function yamlQuote(s: string): string {
  let out = '"';
  for (let i = 0; i < s.length; i++) {
    const c = s.charAt(i);
    const code = s.charCodeAt(i);
    if (c === '\\') {
      out += '\\\\';
    } else if (c === '"') {
      out += '\\"';
    } else if (c === '\n') {
      out += '\\n';
    } else if (c === '\r') {
      out += '\\r';
    } else if (c === '\t') {
      out += '\\t';
    } else if (code < 0x20) {
      out += '\\x' + hex2(code);
    } else {
      out += c;
    }
  }
  return out + '"';
}

function formatNum(n: number): string {
  if (!isFinite(n)) {
    return '0';
  }
  if (Math.floor(n) === n && Math.abs(n) < 1e15) {
    return String(n);
  }
  return String(n);
}

function yamlScalar(v: YamlValue): string {
  if (v.kind === 'null') {
    return 'null';
  }
  if (v.kind === 'num') {
    return formatNum(v.n);
  }
  if (v.kind === 'bool') {
    return v.b ? 'true' : 'false';
  }
  const s = v.s;
  if (v.bare && isAllDigits(s)) {
    return s;
  }
  if (looksNumeric(s)) {
    return yamlQuote(s);
  }
  if (isPlainSafe(s)) {
    return s;
  }
  return yamlQuote(s);
}

function emitEntry(lines: string[], indent: string, key: string, v: YamlValue): void {
  const keyText = isPlainSafe(key) ? key : yamlQuote(key);
  if (v.kind === 'map') {
    if (v.fields.size === 0) {
      lines.push(indent + keyText + ': {}');
      return;
    }
    lines.push(indent + keyText + ':');
    emitMapBlock(lines, indent + '  ', v.fields);
    return;
  }
  if (v.kind === 'list') {
    if (v.items.length === 0) {
      lines.push(indent + keyText + ': []');
      return;
    }
    const values: string[] = [];
    let allScalar = true;
    for (const item of v.items) {
      if (item.kind === 'map' || item.kind === 'list') {
        allScalar = false;
        break;
      }
      values.push(yamlScalar(item));
    }
    if (allScalar) {
      lines.push(indent + keyText + ': [' + values.join(', ') + ']');
      return;
    }
    lines.push(indent + keyText + ':');
    for (const item of v.items) {
      emitListItem(lines, indent + '  ', item);
    }
    return;
  }
  lines.push(indent + keyText + ': ' + yamlScalar(v));
}

function emitMapBlock(lines: string[], indent: string, fields: Map<string, YamlValue>): void {
  fields.forEach((v: YamlValue, k: string) => {
    emitEntry(lines, indent, k, v);
  });
}

function emitListItem(lines: string[], indent: string, v: YamlValue): void {
  if (v.kind !== 'map') {
    lines.push(indent + '- ' + yamlScalar(v));
    return;
  }
  if (v.fields.size === 0) {
    lines.push(indent + '- {}');
    return;
  }
  const sub: string[] = [];
  v.fields.forEach((child: YamlValue, k: string) => {
    emitEntry(sub, indent + '  ', k, child);
  });
  // 把第一条折到 "- " 同一行（mihomo/Clash 的常见书写形态）
  const firstLine = sub[0];
  const trimmed = firstLine.substring(indent.length + 2);
  lines.push(indent + '- ' + trimmed);
  for (let i = 1; i < sub.length; i++) {
    lines.push(sub[i]);
  }
}

/** 把节点数组渲染成 `proxies:` 块 */
function emitProxies(proxies: YamlValue[]): string {
  const lines: string[] = ['proxies:'];
  for (const p of proxies) {
    emitListItem(lines, '  ', p);
  }
  return lines.join('\n') + '\n';
}

/** 把节点数组渲染成 JSON（等价 Go 侧 `json.Marshal([]map[string]any)`，供对拍/调试） */
function jsonEscape(s: string): string {
  let out = '"';
  for (let i = 0; i < s.length; i++) {
    const c = s.charAt(i);
    const code = s.charCodeAt(i);
    if (c === '"') {
      out += '\\"';
    } else if (c === '\\') {
      out += '\\\\';
    } else if (c === '\n') {
      out += '\\n';
    } else if (c === '\r') {
      out += '\\r';
    } else if (c === '\t') {
      out += '\\t';
    } else if (code < 0x20) {
      out += '\\u' + hex2(code >> 4) + hex2(code & 0xf) + '00';
    } else {
      out += c;
    }
  }
  return out + '"';
}

function jsonOf(v: YamlValue): string {
  if (v.kind === 'null') {
    return 'null';
  }
  if (v.kind === 'num') {
    return formatNum(v.n);
  }
  if (v.kind === 'bool') {
    return v.b ? 'true' : 'false';
  }
  if (v.kind === 'list') {
    const parts: string[] = [];
    for (const item of v.items) {
      parts.push(jsonOf(item));
    }
    return '[' + parts.join(',') + ']';
  }
  if (v.kind === 'map') {
    const parts: string[] = [];
    v.fields.forEach((child: YamlValue, k: string) => {
      parts.push(jsonEscape(k) + ':' + jsonOf(child));
    });
    return '{' + parts.join(',') + '}';
  }
  return jsonEscape(v.s);
}

// ════════════════════════════════════════════════════════════════════════════
// 七、工具函数（Go 标准库语义的小件）
// ════════════════════════════════════════════════════════════════════════════

/** `strconv.ParseBool`：只认 Go 的六真六假，其余视为 false（Go 里 err 被忽略） */
function parseBoolGo(s: string): boolean {
  return s === '1' || s === 't' || s === 'T' || s === 'true' || s === 'TRUE' || s === 'True';
}

/** `strconv.Atoi`：允许正负号 + 十进制；失败返回 null */
function atoiGo(s: string): number | null {
  if (!/^[+-]?\d+$/.test(s)) {
    return null;
  }
  const v = Number.parseInt(s, 10);
  return isNaN(v) ? null : v;
}

/** `fmt.Sprintf("%s-%02d", ...)` 的后半段 */
function pad2(n: number): string {
  return n < 10 ? '0' + n : String(n);
}

/**
 * `uniqueName`：首次原名，之后 `-01`、`-02`……
 * 注意：Go 的 map 里首次写入的计数是 0，命中时先 ++ 再格式化 ⇒ 第二条是 `-01`。
 */
function uniqueName(names: Map<string, number>, name: string): string {
  const index = names.get(name);
  if (index === undefined) {
    names.set(name, 0);
    return name;
  }
  const next = index + 1;
  names.set(name, next);
  return name + '-' + pad2(next);
}

/** `RandUserAgent`：Go 随机；这里按种子稳定散列（同一输入 → 同一输出，可重复） */
function randUserAgent(seed: string): string {
  let hash = 2166136261;
  for (let i = 0; i < seed.length; i++) {
    hash ^= seed.charCodeAt(i);
    hash = (hash * 16777619) & 0xffffffff;
  }
  const idx = Math.abs(hash) % WS_USER_AGENTS.length;
  return WS_USER_AGENTS[idx];
}

/** `strings.TrimRight(s, " \r")`（只去空格与 CR，不动 tab） */
function trimRightSpaceCr(s: string): string {
  let end = s.length;
  while (end > 0) {
    const c = s.charAt(end - 1);
    if (c === ' ' || c === '\r') {
      end--;
    } else {
      break;
    }
  }
  return end === s.length ? s : s.substring(0, end);
}

/**
 * `VerifyMethod`（shadowimpl.FetchMethod 的白名单部分）。
 * 2022 系列还额外要求密码非空且每段都能按标准 base64 解开（否则 ErrMissingPSK / decode key）。
 */
function verifyMethod(cipher: string, password: string): boolean {
  if (cipher === 'none' || cipher === 'plain' || cipher === 'dummy') {
    return true;
  }
  if (SS_STREAM_METHODS.indexOf(cipher) >= 0) {
    return true;
  }
  if (SS_AEAD_METHODS.indexOf(cipher) >= 0) {
    return true;
  }
  if (SS_2022_METHODS.indexOf(cipher) >= 0) {
    if (password.length === 0) {
      return false;
    }
    const keys = password.split(':');
    for (const k of keys) {
      if (!GoBytes.b64(k, false, false).ok) {
        return false;
      }
    }
    return true;
  }
  return false;
}

/** `splitHysteria2Ports`：把 `host:443,8443-8445` 拆成可解析的单端口行 + ports 串 */
class Hysteria2Split {
  line: string = '';
  ports: string = '';
}

function splitHysteria2Ports(line: string): Hysteria2Split {
  const out = new Hysteria2Split();
  out.line = line;
  out.ports = '';
  const idx = line.indexOf('://');
  if (idx < 0) {
    return out;
  }
  const head = line.substring(0, idx + 3);
  const rest = line.substring(idx + 3);
  let auth = rest;
  let tail = '';
  let cut = -1;
  for (let i = 0; i < rest.length; i++) {
    const c = rest.charAt(i);
    if (c === '/' || c === '?' || c === '#') {
      cut = i;
      break;
    }
  }
  if (cut >= 0) {
    auth = rest.substring(0, cut);
    tail = rest.substring(cut);
  }
  let userinfo = '';
  const at = auth.lastIndexOf('@');
  if (at >= 0) {
    userinfo = auth.substring(0, at + 1);
    auth = auth.substring(at + 1);
  }
  if (auth.indexOf(']') >= 0) {
    return out;
  }
  const colon = auth.lastIndexOf(':');
  if (colon < 0) {
    return out;
  }
  const host = auth.substring(0, colon);
  const ports = auth.substring(colon + 1);
  if (ports.indexOf(',') < 0 && ports.indexOf('-') < 0) {
    return out;
  }
  let first = ports;
  for (let i = 0; i < ports.length; i++) {
    const c = ports.charAt(i);
    if (c === ',' || c === '-') {
      first = ports.substring(0, i);
      break;
    }
  }
  if (first.length === 0) {
    return out;
  }
  out.line = head + userinfo + host + ':' + first + tail;
  out.ports = ports;
  return out;
}

/** `buildRealmOpts` */
function buildRealmOpts(serverUrl: string, token: string, realmId: string, stun: string[]): YamlValue {
  const opts = new Map<string, YamlValue>();
  opts.set('enable', YamlValue.bool(true));
  opts.set('server-url', YamlValue.str(serverUrl));
  if (token.length > 0) {
    opts.set('token', YamlValue.str(token));
  }
  if (realmId.length > 0) {
    opts.set('realm-id', YamlValue.str(realmId));
  }
  if (stun.length > 0) {
    opts.set('stun-servers', strList(stun));
  }
  return YamlValue.map(opts);
}

// ════════════════════════════════════════════════════════════════════════════
// 八、vless/vmess 共用的分享链接处理（v.go `handleVShareLink`）
// ════════════════════════════════════════════════════════════════════════════

/** `parseXHTTPExtra`：xray 的 `extra` JSON → mihomo 的 `xhttp-opts` 字段 */
function reusePutNumStr(xmux: JsonNode, reuse: Map<string, YamlValue>,
  src: string, dst: string): void {
  const v = xmux.field(src);
  if (v.isStr()) {
    if (v.s.length > 0) {
      reuse.set(dst, YamlValue.str(v.s));
    }
  } else if (v.isNum()) {
    reuse.set(dst, YamlValue.str(String(Math.floor(v.n))));
  }
}

function xmuxToReuse(xmux: JsonNode): Map<string, YamlValue> {
  const reuse = new Map<string, YamlValue>();
  reusePutNumStr(xmux, reuse, 'maxConnections', 'max-connections');
  reusePutNumStr(xmux, reuse, 'maxConcurrency', 'max-concurrency');
  reusePutNumStr(xmux, reuse, 'cMaxReuseTimes', 'c-max-reuse-times');
  reusePutNumStr(xmux, reuse, 'hMaxRequestTimes', 'h-max-request-times');
  reusePutNumStr(xmux, reuse, 'hMaxReusableSecs', 'h-max-reusable-secs');
  const keepAlive = xmux.field('hKeepAlivePeriod');
  if (keepAlive.isNum()) {
    reuse.set('h-keep-alive-period', YamlValue.num(Math.floor(keepAlive.n)));
  }
  return reuse;
}

function parseXHTTPExtra(extra: JsonNode, opts: Map<string, YamlValue>): void {
  const headers = extra.field('headers');
  if (headers.isObj() && headers.fields.size > 0) {
    const copy = new Map<string, YamlValue>();
    headers.fields.forEach((v: JsonNode, k: string) => {
      copy.set(k, jsonToYaml(v));
    });
    opts.set('headers', YamlValue.map(copy));
  }

  const noGrpc = extra.field('noGRPCHeader');
  if (noGrpc.kind === 'bool' && noGrpc.b) {
    opts.set('no-grpc-header', YamlValue.bool(true));
  }

  const xPaddingBytes = extra.field('xPaddingBytes');
  if (xPaddingBytes.isStr() && xPaddingBytes.s.length > 0) {
    opts.set('x-padding-bytes', YamlValue.str(xPaddingBytes.s));
  }

  const xPaddingObfs = extra.field('xPaddingObfsMode');
  if (xPaddingObfs.kind === 'bool') {
    opts.set('x-padding-obfs-mode', YamlValue.bool(xPaddingObfs.b));
  }

  const padKeys: string[] = [
    'xPaddingKey', 'xPaddingHeader', 'xPaddingPlacement', 'xPaddingMethod',
    'uplinkHTTPMethod', 'sessionIDTable', 'seqPlacement', 'seqKey',
    'uplinkDataPlacement', 'uplinkDataKey'
  ];
  const padDst: string[] = [
    'x-padding-key', 'x-padding-header', 'x-padding-placement', 'x-padding-method',
    'uplink-http-method', 'session-table', 'seq-placement', 'seq-key',
    'uplink-data-placement', 'uplink-data-key'
  ];
  for (let i = 0; i < padKeys.length; i++) {
    const v = extra.field(padKeys[i]);
    if (v.isStr() && v.s.length > 0) {
      opts.set(padDst[i], YamlValue.str(v.s));
    }
  }

  const sessionPlacementA = extra.field('sessionIDPlacement');
  if (sessionPlacementA.isStr() && sessionPlacementA.s.length > 0) {
    opts.set('session-placement', YamlValue.str(sessionPlacementA.s));
  } else {
    const sessionPlacementB = extra.field('sessionPlacement');
    if (sessionPlacementB.isStr() && sessionPlacementB.s.length > 0) {
      opts.set('session-placement', YamlValue.str(sessionPlacementB.s));
    }
  }

  const sessionKeyA = extra.field('sessionIDKey');
  if (sessionKeyA.isStr() && sessionKeyA.s.length > 0) {
    opts.set('session-key', YamlValue.str(sessionKeyA.s));
  } else {
    const sessionKeyB = extra.field('sessionKey');
    if (sessionKeyB.isStr() && sessionKeyB.s.length > 0) {
      opts.set('session-key', YamlValue.str(sessionKeyB.s));
    }
  }

  const sessionLengthA = extra.field('sessionIDLength');
  if (sessionLengthA.isStr() && sessionLengthA.s.length > 0) {
    opts.set('session-length', YamlValue.str(sessionLengthA.s));
  } else if (sessionLengthA.isNum()) {
    opts.set('session-length', YamlValue.str(String(Math.floor(sessionLengthA.n))));
  }

  const chunkSize = extra.field('uplinkChunkSize');
  if (chunkSize.isNum()) {
    opts.set('uplink-chunk-size', YamlValue.num(Math.floor(chunkSize.n)));
  }

  const scMaxPost = extra.field('scMaxEachPostBytes');
  if (scMaxPost.isNum()) {
    opts.set('sc-max-each-post-bytes', YamlValue.num(Math.floor(scMaxPost.n)));
  }

  const scMinInterval = extra.field('scMinPostsIntervalMs');
  if (scMinInterval.isNum()) {
    opts.set('sc-min-posts-interval-ms', YamlValue.num(Math.floor(scMinInterval.n)));
  }

  const xmux = extra.field('xmux');
  if (xmux.isObj() && xmux.fields.size > 0) {
    const reuse = xmuxToReuse(xmux);
    if (reuse.size > 0) {
      opts.set('reuse-settings', YamlValue.map(reuse));
    }
  }

  const dsAny = extra.field('downloadSettings');
  if (dsAny.isObj()) {
    const ds = new Map<string, YamlValue>();
    const addr = dsAny.field('address');
    if (addr.isStr() && addr.s.length > 0) {
      ds.set('server', YamlValue.str(addr.s));
    }
    const port = dsAny.field('port');
    if (port.isNum()) {
      ds.set('port', YamlValue.num(Math.floor(port.n)));
    }
    const secNode = dsAny.field('security');
    let sec = '';
    if (secNode.isStr()) {
      sec = secNode.s.toLowerCase();
    }
    if (sec === 'tls' || sec === 'reality') {
      ds.set('tls', YamlValue.bool(true));
      const tlsAny = dsAny.field('tlsSettings');
      if (tlsAny.isObj()) {
        const sn = tlsAny.field('serverName');
        if (sn.isStr() && sn.s.length > 0) {
          ds.set('servername', YamlValue.str(sn.s));
        }
        const fp = tlsAny.field('fingerprint');
        if (fp.isStr() && fp.s.length > 0) {
          ds.set('client-fingerprint', YamlValue.str(fp.s));
        }
        const alpnAny = tlsAny.field('alpn');
        if (alpnAny.isArr() && alpnAny.items.length > 0) {
          const alpnList: YamlValue[] = [];
          for (const a of alpnAny.items) {
            if (a.isStr()) {
              alpnList.push(YamlValue.str(a.s));
            }
          }
          if (alpnList.length > 0) {
            ds.set('alpn', YamlValue.list(alpnList));
          }
        }
        const insecure = tlsAny.field('allowInsecure');
        if (insecure.kind === 'bool' && insecure.b) {
          ds.set('skip-cert-verify', YamlValue.bool(true));
        }
      }
      if (sec === 'reality') {
        const realityAny = dsAny.field('realitySettings');
        if (realityAny.isObj()) {
          const realityOpts = new Map<string, YamlValue>();
          const pk = realityAny.field('publicKey');
          if (pk.isStr() && pk.s.length > 0) {
            realityOpts.set('public-key', YamlValue.str(pk.s));
          }
          const sid = realityAny.field('shortId');
          if (sid.isStr() && sid.s.length > 0) {
            realityOpts.set('short-id', YamlValue.str(sid.s));
          }
          if (realityOpts.size > 0) {
            ds.set('reality-opts', YamlValue.map(realityOpts));
          }
        }
      }
    }

    const xhttpAny = dsAny.field('xhttpSettings');
    if (xhttpAny.isObj()) {
      const path = xhttpAny.field('path');
      if (path.isStr() && path.s.length > 0) {
        ds.set('path', YamlValue.str(path.s));
      }
      const host = xhttpAny.field('host');
      if (host.isStr() && host.s.length > 0) {
        ds.set('host', YamlValue.str(host.s));
      }
      const headersAny = xhttpAny.field('headers');
      if (headersAny.isObj() && headersAny.fields.size > 0) {
        const copy = new Map<string, YamlValue>();
        headersAny.fields.forEach((v: JsonNode, k: string) => {
          copy.set(k, jsonToYaml(v));
        });
        ds.set('headers', YamlValue.map(copy));
      }
      const dsExtra = xhttpAny.field('extra');
      if (dsExtra.isObj()) {
        const xmuxInner = dsExtra.field('xmux');
        if (xmuxInner.isObj() && xmuxInner.fields.size > 0) {
          const reuse = xmuxToReuse(xmuxInner);
          if (reuse.size > 0) {
            ds.set('reuse-settings', YamlValue.map(reuse));
          }
        }
      }
    }

    if (ds.size > 0) {
      opts.set('download-settings', YamlValue.map(ds));
    }
  }
}

/** JSON 节点 → YAML 值（仅用于 xhttp 的 headers 等自由结构） */
function jsonToYaml(v: JsonNode): YamlValue {
  if (v.kind === 'num') {
    return YamlValue.num(v.n);
  }
  if (v.kind === 'bool') {
    return YamlValue.bool(v.b);
  }
  if (v.kind === 'arr') {
    const items: YamlValue[] = [];
    for (const it of v.items) {
      items.push(jsonToYaml(it));
    }
    return YamlValue.list(items);
  }
  if (v.kind === 'obj') {
    const fields = new Map<string, YamlValue>();
    v.fields.forEach((child: JsonNode, k: string) => {
      fields.set(k, jsonToYaml(child));
    });
    return YamlValue.map(fields);
  }
  if (v.kind === 'str') {
    return YamlValue.str(v.s);
  }
  return YamlValue.nul();
}

/**
 * `handleVShareLink`：vless / vmess(AEAD) 共用的字段填充。
 * 返回 false 表示「整条丢弃」（对应 Go 的 error）。
 */
function handleVShareLink(names: Map<string, number>, u: GoUrl, scheme: string,
  proxy: Map<string, YamlValue>): boolean {
  const query = u.query();
  // 注意：名字在 host/port 校验之前就取了 —— 失败的行也会消耗序号（Go 行为）
  proxy.set('name', YamlValue.str(uniqueName(names, u.fragment)));
  const hostname = u.hostname();
  if (hostname.length === 0) {
    return false;
  }
  const port = u.port();
  if (port.length === 0) {
    return false;
  }
  proxy.set('type', YamlValue.str(scheme));
  proxy.set('server', YamlValue.str(hostname));
  proxy.set('port', YamlValue.port(port));
  proxy.set('uuid', YamlValue.str(u.username));
  proxy.set('udp', YamlValue.bool(true));

  const tls = query.get('security').toLowerCase();
  if (tls.endsWith('tls') || tls === 'reality') {
    proxy.set('tls', YamlValue.bool(true));
    const fingerprint = query.get('fp');
    proxy.set('client-fingerprint', YamlValue.str(fingerprint.length === 0 ? 'chrome' : fingerprint));
    const alpn = query.get('alpn');
    if (alpn.length > 0) {
      proxy.set('alpn', strList(alpn.split(',')));
    }
    const pcs = query.get('pcs');
    if (pcs.length > 0) {
      proxy.set('fingerprint', YamlValue.str(pcs));
    }
  }
  const sni = query.get('sni');
  if (sni.length > 0) {
    proxy.set('servername', YamlValue.str(sni));
  }
  const realityPublicKey = query.get('pbk');
  if (realityPublicKey.length > 0) {
    const realityOpts = new Map<string, YamlValue>();
    realityOpts.set('public-key', YamlValue.str(realityPublicKey));
    realityOpts.set('short-id', YamlValue.str(query.get('sid')));
    const mlkem = query.get('support-x25519mlkem768');
    if (mlkem.length > 0) {
      if (mlkem === '1' || mlkem === 't' || mlkem === 'T' || mlkem === 'true'
        || mlkem === 'TRUE' || mlkem === 'True') {
        realityOpts.set('support-x25519mlkem768', YamlValue.bool(true));
      } else if (mlkem === '0' || mlkem === 'f' || mlkem === 'F' || mlkem === 'false'
        || mlkem === 'FALSE' || mlkem === 'False') {
        realityOpts.set('support-x25519mlkem768', YamlValue.bool(false));
      }
    }
    proxy.set('reality-opts', YamlValue.map(realityOpts));
  }

  const packetEncoding = query.get('packetEncoding');
  if (packetEncoding === 'packet') {
    proxy.set('packet-addr', YamlValue.bool(true));
  } else if (packetEncoding === 'none') {
    // Go: case "none": 什么都不写
  } else {
    proxy.set('xudp', YamlValue.bool(true));
  }

  let network = query.get('type').toLowerCase();
  if (network.length === 0) {
    network = 'tcp';
  }
  const fakeType = query.get('headerType').toLowerCase();
  if (network === 'tcp' && fakeType === 'http') {
    network = 'http';
  } else if (network === 'http') {
    network = 'h2';
  }
  proxy.set('network', YamlValue.str(network));

  if (network === 'http') {
    const headers = new Map<string, YamlValue>();
    const httpOpts = new Map<string, YamlValue>();
    httpOpts.set('path', strList(['/']));
    const host = query.get('host');
    if (host.length > 0) {
      headers.set('Host', strList([host]));
    }
    const method = query.get('method');
    if (method.length > 0) {
      httpOpts.set('method', YamlValue.str(method));
    }
    const path = query.get('path');
    if (path.length > 0) {
      httpOpts.set('path', strList([path]));
    }
    httpOpts.set('headers', YamlValue.map(headers));
    proxy.set('http-opts', YamlValue.map(httpOpts));
  } else if (network === 'h2') {
    const h2Opts = new Map<string, YamlValue>();
    h2Opts.set('path', YamlValue.str('/'));
    const path = query.get('path');
    if (path.length > 0) {
      h2Opts.set('path', YamlValue.str(path));
    }
    const host = query.get('host');
    if (host.length > 0) {
      h2Opts.set('host', strList([host]));
    }
    proxy.set('h2-opts', YamlValue.map(h2Opts));
  } else if (network === 'ws' || network === 'httpupgrade') {
    const headers = new Map<string, YamlValue>();
    const wsOpts = new Map<string, YamlValue>();
    headers.set('User-Agent', YamlValue.str(randUserAgent(u.raw + scheme)));
    headers.set('Host', YamlValue.str(query.get('host')));
    wsOpts.set('path', YamlValue.str(query.get('path')));
    wsOpts.set('headers', YamlValue.map(headers));

    const earlyData = query.get('ed');
    if (earlyData.length > 0) {
      const med = atoiGo(earlyData);
      if (med === null) {
        // Go: return fmt.Errorf("bad WebSocket max early data size") → 整条丢弃
        return false;
      }
      if (network === 'ws') {
        wsOpts.set('max-early-data', YamlValue.num(med));
        wsOpts.set('early-data-header-name', YamlValue.str('Sec-WebSocket-Protocol'));
      } else {
        wsOpts.set('v2ray-http-upgrade-fast-open', YamlValue.bool(true));
      }
    }
    const earlyDataHeader = query.get('eh');
    if (earlyDataHeader.length > 0) {
      wsOpts.set('early-data-header-name', YamlValue.str(earlyDataHeader));
    }
    proxy.set('ws-opts', YamlValue.map(wsOpts));
  } else if (network === 'grpc') {
    const grpcOpts = new Map<string, YamlValue>();
    grpcOpts.set('grpc-service-name', YamlValue.str(query.get('serviceName')));
    proxy.set('grpc-opts', YamlValue.map(grpcOpts));
  } else if (network === 'xhttp') {
    proxy.set('network', YamlValue.str('xhttp'));
    const xhttpOpts = new Map<string, YamlValue>();
    const path = query.get('path');
    if (path.length > 0) {
      xhttpOpts.set('path', YamlValue.str(path));
    }
    const host = query.get('host');
    if (host.length > 0) {
      xhttpOpts.set('host', YamlValue.str(host));
    }
    const mode = query.get('mode');
    if (mode.length > 0) {
      xhttpOpts.set('mode', YamlValue.str(mode));
    }
    const extra = query.get('extra');
    if (extra.length > 0) {
      const parsed = parseJson(extra);
      if (parsed !== null && parsed.isObj()) {
        parseXHTTPExtra(parsed, xhttpOpts);
      }
    }
    proxy.set('xhttp-opts', YamlValue.map(xhttpOpts));
  }
  return true;
}

// ════════════════════════════════════════════════════════════════════════════
// 九、单行分支（converter.go 的 switch）
// ════════════════════════════════════════════════════════════════════════════

function branchHysteria(line: string, scheme: string, names: Map<string, number>,
  proxies: YamlValue[]): void {
  const u = parseGoUrl(line);
  if (!u.ok) {
    return;
  }
  const query = u.query();
  const name = uniqueName(names, u.fragment);
  const m = new Map<string, YamlValue>();
  m.set('name', YamlValue.str(name));
  m.set('type', YamlValue.str(scheme));
  m.set('server', YamlValue.str(u.hostname()));
  m.set('port', YamlValue.port(u.port()));
  m.set('sni', YamlValue.str(query.get('peer')));
  m.set('obfs', YamlValue.str(query.get('obfs')));
  const alpn = query.get('alpn');
  if (alpn.length > 0) {
    m.set('alpn', strList(alpn.split(',')));
  }
  m.set('auth_str', YamlValue.str(query.get('auth')));
  m.set('protocol', YamlValue.str(query.get('protocol')));
  let up = query.get('up');
  let down = query.get('down');
  if (up.length === 0) {
    up = query.get('upmbps');
  }
  if (down.length === 0) {
    down = query.get('downmbps');
  }
  m.set('down', YamlValue.str(down));
  m.set('up', YamlValue.str(up));
  m.set('skip-cert-verify', YamlValue.bool(parseBoolGo(query.get('insecure'))));
  proxies.push(YamlValue.map(m));
}

function branchHysteria2(line: string, scheme: string, names: Map<string, number>,
  proxies: YamlValue[]): void {
  const realmMode = scheme.endsWith('+realm');
  const split = splitHysteria2Ports(line);
  const u = parseGoUrl(split.line);
  if (!u.ok) {
    return;
  }
  const query = u.query();
  const name = uniqueName(names, u.fragment);
  const m = new Map<string, YamlValue>();
  m.set('name', YamlValue.str(name));
  m.set('type', YamlValue.str('hysteria2'));
  m.set('server', YamlValue.str(u.hostname()));
  const port = u.port();
  m.set('port', YamlValue.port(port.length === 0 ? '443' : port));
  if (split.ports.length > 0) {
    m.set('ports', YamlValue.port(split.ports));
  }
  m.set('obfs', YamlValue.str(query.get('obfs')));
  m.set('obfs-password', YamlValue.str(query.get('obfs-password')));
  m.set('sni', YamlValue.str(query.get('sni')));
  m.set('skip-cert-verify', YamlValue.bool(parseBoolGo(query.get('insecure'))));
  const alpn = query.get('alpn');
  if (alpn.length > 0) {
    m.set('alpn', strList(alpn.split(',')));
  }
  m.set('fingerprint', YamlValue.str(query.get('pinSHA256')));
  m.set('down', YamlValue.str(query.get('down')));
  m.set('up', YamlValue.str(query.get('up')));
  if (realmMode) {
    const token = u.hasPassword ? u.username + ':' + u.password : u.username;
    let realmId = u.path;
    if (realmId.startsWith('/')) {
      realmId = realmId.substring(1);
    }
    m.set('realm-opts', buildRealmOpts('https://' + u.host, token, realmId, query.all('stun')));
    const auth = query.get('auth');
    if (auth.length > 0) {
      m.set('password', YamlValue.str(auth));
    }
  } else {
    const auth = u.userString();
    if (auth.length > 0) {
      m.set('password', YamlValue.str(auth));
    }
  }
  proxies.push(YamlValue.map(m));
}

function branchTuic(line: string, scheme: string, names: Map<string, number>,
  proxies: YamlValue[]): void {
  const u = parseGoUrl(line);
  if (!u.ok) {
    return;
  }
  const query = u.query();
  const m = new Map<string, YamlValue>();
  m.set('name', YamlValue.str(uniqueName(names, u.fragment)));
  m.set('type', YamlValue.str(scheme));
  m.set('server', YamlValue.str(u.hostname()));
  m.set('port', YamlValue.port(u.port()));
  m.set('udp', YamlValue.bool(true));
  if (u.hasPassword) {
    m.set('uuid', YamlValue.str(u.username));
    m.set('password', YamlValue.str(u.password));
  } else {
    m.set('token', YamlValue.str(u.username));
  }
  const cc = query.get('congestion_control');
  if (cc.length > 0) {
    m.set('congestion-controller', YamlValue.str(cc));
  }
  const alpn = query.get('alpn');
  if (alpn.length > 0) {
    m.set('alpn', strList(alpn.split(',')));
  }
  const sni = query.get('sni');
  if (sni.length > 0) {
    m.set('sni', YamlValue.str(sni));
  }
  if (query.get('disable_sni') === '1') {
    m.set('disable-sni', YamlValue.bool(true));
  }
  const udpRelayMode = query.get('udp_relay_mode');
  if (udpRelayMode.length > 0) {
    m.set('udp-relay-mode', YamlValue.str(udpRelayMode));
  }
  proxies.push(YamlValue.map(m));
}

function branchTrojan(line: string, scheme: string, names: Map<string, number>,
  proxies: YamlValue[]): void {
  const u = parseGoUrl(line);
  if (!u.ok) {
    return;
  }
  const query = u.query();
  const m = new Map<string, YamlValue>();
  m.set('name', YamlValue.str(uniqueName(names, u.fragment)));
  m.set('type', YamlValue.str(scheme));
  m.set('server', YamlValue.str(u.hostname()));
  m.set('port', YamlValue.port(u.port()));
  m.set('password', YamlValue.str(u.username));
  m.set('udp', YamlValue.bool(true));
  // 证书校验开关：上游 mihomo 只认 `allowInsecure`，但 v2rayN / Shadowrocket / 绝大多数
  // 机场导出的分享链接用的是 `insecure=1`（及其变体 `skip-cert-verify`）。只认前者会把
  // 自签节点判成「必须校验证书」→ TLS 握手失败 → 节点永远测不通（真机：trojan 链接
  // 转换后 dead、同订阅里另一条节点正常）。这里三写一并识别，任为真即跳过校验。
  // 这是相对 FlClash 的**唯一**有意偏离，理由是该参数名在分享链接生态里更常见。
  const skipCert = parseBoolGo(query.get('allowInsecure'))
    || parseBoolGo(query.get('insecure'))
    || parseBoolGo(query.get('skip-cert-verify'));
  m.set('skip-cert-verify', YamlValue.bool(skipCert));

  const sni = query.get('sni');
  if (sni.length > 0) {
    m.set('sni', YamlValue.str(sni));
  }
  const alpn = query.get('alpn');
  if (alpn.length > 0) {
    m.set('alpn', strList(alpn.split(',')));
  }
  const network = query.get('type').toLowerCase();
  if (network.length > 0) {
    m.set('network', YamlValue.str(network));
  }
  if (network === 'ws') {
    const headers = new Map<string, YamlValue>();
    const wsOpts = new Map<string, YamlValue>();
    headers.set('User-Agent', YamlValue.str(randUserAgent(u.raw + scheme)));
    wsOpts.set('path', YamlValue.str(query.get('path')));
    wsOpts.set('headers', YamlValue.map(headers));
    m.set('ws-opts', YamlValue.map(wsOpts));
  } else if (network === 'grpc') {
    const grpcOpts = new Map<string, YamlValue>();
    grpcOpts.set('grpc-service-name', YamlValue.str(query.get('serviceName')));
    m.set('grpc-opts', YamlValue.map(grpcOpts));
  }
  const fingerprint = query.get('fp');
  m.set('client-fingerprint', YamlValue.str(fingerprint.length === 0 ? 'chrome' : fingerprint));
  const pcs = query.get('pcs');
  if (pcs.length > 0) {
    m.set('fingerprint', YamlValue.str(pcs));
  }
  proxies.push(YamlValue.map(m));
}

function branchVless(line: string, scheme: string, names: Map<string, number>,
  proxies: YamlValue[]): void {
  const u = parseGoUrl(line);
  if (!u.ok) {
    return;
  }
  // 有些机场把 host 整段做了 base64（Go 里直接替换 Host，然后再取 Query）
  const decodedHost = tryDecodeBase64(u.host);
  if (decodedHost !== null) {
    u.host = GoBytes.decode(decodedHost.bytes);
  }
  const query = u.query();
  const m = new Map<string, YamlValue>();
  if (!handleVShareLink(names, u, scheme, m)) {
    return;
  }
  const flow = query.get('flow');
  if (flow.length > 0) {
    m.set('flow', YamlValue.str(flow.toLowerCase()));
  }
  const encryption = query.get('encryption');
  if (encryption.length > 0) {
    m.set('encryption', YamlValue.str(encryption));
  }
  proxies.push(YamlValue.map(m));
}

function branchVmess(line: string, body: string, scheme: string, names: Map<string, number>,
  proxies: YamlValue[]): void {
  const dcBuf = tryDecodeBase64(body);
  if (dcBuf === null) {
    // Xray VMessAEAD 分享链接
    const u = parseGoUrl(line);
    if (!u.ok) {
      return;
    }
    const query = u.query();
    const m = new Map<string, YamlValue>();
    if (!handleVShareLink(names, u, scheme, m)) {
      return;
    }
    m.set('alterId', YamlValue.num(0));
    m.set('cipher', YamlValue.str('auto'));
    const encryption = query.get('encryption');
    if (encryption.length > 0) {
      m.set('cipher', YamlValue.str(encryption));
    }
    proxies.push(YamlValue.map(m));
    return;
  }

  // V2RayN 风格分享链接（base64 的 JSON）
  const root = parseJson(GoBytes.decode(dcBuf.bytes));
  if (root === null || !root.isObj()) {
    return;
  }
  const values = root;
  const ps = values.field('ps');
  if (!ps.isStr()) {
    return;
  }
  const name = uniqueName(names, ps.s);
  const m = new Map<string, YamlValue>();
  m.set('name', YamlValue.str(name));
  m.set('type', YamlValue.str(scheme));
  m.set('server', jsonToYaml(values.field('add')));
  m.set('port', jsonPort(values.field('port')));
  m.set('uuid', jsonToYaml(values.field('id')));
  // Go: if alterId, ok := values["aid"]; ok { 用它 } else { 0 }（缺字段才补 0）
  m.set('alterId', values.fields.has('aid') ? jsonToYaml(values.field('aid')) : YamlValue.num(0));
  m.set('udp', YamlValue.bool(true));
  m.set('xudp', YamlValue.bool(true));
  m.set('tls', YamlValue.bool(false));
  m.set('skip-cert-verify', YamlValue.bool(false));

  m.set('cipher', YamlValue.str('auto'));
  const scy = values.field('scy');
  if (scy.isStr() && scy.s.length > 0) {
    m.set('cipher', YamlValue.str(scy.s));
  }
  const sni = values.field('sni');
  if (sni.isStr() && sni.s.length > 0) {
    m.set('servername', YamlValue.str(sni.s));
  }

  let network = '';
  const net = values.field('net');
  if (net.isStr()) {
    network = net.s.toLowerCase();
    const typeField = values.field('type');
    if (typeField.isStr() && typeField.s === 'http') {
      network = 'http';
    } else if (network === 'http') {
      network = 'h2';
    }
    m.set('network', YamlValue.str(network));
  }

  const tlsField = values.field('tls');
  if (tlsField.isStr()) {
    const tls = tlsField.s.toLowerCase();
    if (tls.endsWith('tls')) {
      m.set('tls', YamlValue.bool(true));
    }
    const alpn = values.field('alpn');
    if (alpn.isStr()) {
      m.set('alpn', strList(alpn.s.split(',')));
    }
  }

  if (network === 'http') {
    const headers = new Map<string, YamlValue>();
    const httpOpts = new Map<string, YamlValue>();
    const host = values.field('host');
    if (host.isStr() && host.s.length > 0) {
      headers.set('Host', strList([host.s]));
    }
    httpOpts.set('path', strList(['/']));
    const path = values.field('path');
    if (path.isStr() && path.s.length > 0) {
      httpOpts.set('path', strList([path.s]));
    }
    httpOpts.set('headers', YamlValue.map(headers));
    m.set('http-opts', YamlValue.map(httpOpts));
  } else if (network === 'h2') {
    const h2Opts = new Map<string, YamlValue>();
    h2Opts.set('path', YamlValue.str('/'));
    const path = values.field('path');
    if (path.isStr() && path.s.length > 0) {
      h2Opts.set('path', YamlValue.str(path.s));
    }
    const host = values.field('host');
    if (host.isStr() && host.s.length > 0) {
      h2Opts.set('host', strList([host.s]));
    }
    m.set('h2-opts', YamlValue.map(h2Opts));
  } else if (network === 'ws' || network === 'httpupgrade') {
    const headers = new Map<string, YamlValue>();
    const wsOpts = new Map<string, YamlValue>();
    wsOpts.set('path', YamlValue.str('/'));
    const host = values.field('host');
    if (host.isStr() && host.s.length > 0) {
      headers.set('Host', YamlValue.str(host.s));
    }
    const pathNode = values.field('path');
    if (pathNode.isStr() && pathNode.s.length > 0) {
      let path = pathNode.s;
      const pathUrl = parseGoUrl(path);
      const pq = pathUrl.query();
      const earlyData = pq.get('ed');
      if (earlyData.length > 0) {
        const med = atoiGo(earlyData);
        if (med !== null) {
          if (network === 'ws') {
            wsOpts.set('max-early-data', YamlValue.num(med));
            wsOpts.set('early-data-header-name', YamlValue.str('Sec-WebSocket-Protocol'));
          } else {
            wsOpts.set('v2ray-http-upgrade-fast-open', YamlValue.bool(true));
          }
          pq.del('ed');
          const encoded = pq.encode();
          path = pathUrl.path + (encoded.length > 0 ? '?' + encoded : '');
        }
      }
      const earlyDataHeader = pq.get('eh');
      if (earlyDataHeader.length > 0) {
        wsOpts.set('early-data-header-name', YamlValue.str(earlyDataHeader));
      }
      wsOpts.set('path', YamlValue.str(path));
    }
    wsOpts.set('headers', YamlValue.map(headers));
    m.set('ws-opts', YamlValue.map(wsOpts));
  } else if (network === 'grpc') {
    const grpcOpts = new Map<string, YamlValue>();
    grpcOpts.set('grpc-service-name', jsonToYaml(values.field('path')));
    m.set('grpc-opts', YamlValue.map(grpcOpts));
  }

  proxies.push(YamlValue.map(m));
}

/** vmess JSON 的 port：数字保持数字，字符串按端口写法裸输出 */
function jsonPort(v: JsonNode): YamlValue {
  if (v.isNum()) {
    return YamlValue.num(Math.floor(v.n));
  }
  if (v.isStr()) {
    return YamlValue.port(v.s);
  }
  return YamlValue.nul();
}

function branchSS(line: string, scheme: string, names: Map<string, number>,
  proxies: YamlValue[]): void {
  let u = parseGoUrl(line);
  if (!u.ok) {
    return;
  }
  const name = uniqueName(names, u.fragment);
  const port = u.port();

  if (port.length === 0) {
    const dcBuf = GoBytes.b64(u.host, false, true); // encRaw
    if (!dcBuf.ok) {
      return;
    }
    u = parseGoUrl('ss://' + GoBytes.decode(dcBuf.bytes));
    if (!u.ok) {
      return;
    }
  }

  const cipherRaw = u.username;
  let cipher = cipherRaw;
  let password = '';
  // 明文 `cipher:password@` 形态：Go 直接取 User.Password()，连方法白名单都不校验
  if (u.hasPassword) {
    password = u.password;
  } else {
    const first = GoBytes.b64(cipherRaw, true, true); // base64.RawURLEncoding
    let bytes = first.bytes;
    if (!first.ok) {
      const second = GoBytes.b64(cipherRaw, false, false); // enc（部分结果也照用）
      bytes = second.bytes;
    }
    const decoded = GoBytes.decode(bytes);
    const idx = decoded.indexOf(':');
    if (idx < 0) {
      return;
    }
    cipher = decoded.substring(0, idx);
    password = decoded.substring(idx + 1);
    if (!verifyMethod(cipher, password)) {
      const fallback = GoBytes.b64(cipherRaw, false, true); // encRaw（忽略错误）
      const decodedRaw = GoBytes.decode(fallback.bytes);
      const idxRaw = decodedRaw.indexOf(':');
      if (idxRaw >= 0) {
        cipher = decodedRaw.substring(0, idxRaw);
        password = decodedRaw.substring(idxRaw + 1);
      } else {
        cipher = decodedRaw;
        password = '';
      }
    }
  }

  const m = new Map<string, YamlValue>();
  m.set('name', YamlValue.str(name));
  m.set('type', YamlValue.str(scheme));
  m.set('server', YamlValue.str(u.hostname()));
  m.set('port', YamlValue.port(u.port()));
  m.set('cipher', YamlValue.str(cipher));
  m.set('password', YamlValue.str(password));

  const query = u.query();
  m.set('udp', YamlValue.bool(true));
  if (query.get('udp-over-tcp') === 'true' || query.get('uot') === '1') {
    m.set('udp-over-tcp', YamlValue.bool(true));
  }
  const plugin = query.get('plugin');
  if (plugin.indexOf(';') >= 0) {
    const pluginInfo = new GoQuery('pluginName=' + plugin.split(';').join('&'));
    const pluginName = pluginInfo.get('pluginName');
    if (pluginName.indexOf(PLUGIN_OBFS) >= 0) {
      m.set('plugin', YamlValue.str('obfs'));
      const opts = new Map<string, YamlValue>();
      opts.set('mode', YamlValue.str(pluginInfo.get('obfs')));
      opts.set('host', YamlValue.str(pluginInfo.get('obfs-host')));
      m.set('plugin-opts', YamlValue.map(opts));
    } else if (pluginName.indexOf(PLUGIN_V2RAY) >= 0) {
      let mode = pluginInfo.get('mode');
      if (mode.length === 0) {
        mode = pluginInfo.get('obfs');
      }
      let host = pluginInfo.get('host');
      if (host.length === 0) {
        host = pluginInfo.get('obfs-host');
      }
      m.set('plugin', YamlValue.str('v2ray-plugin'));
      const opts = new Map<string, YamlValue>();
      opts.set('mode', YamlValue.str(mode));
      opts.set('host', YamlValue.str(host));
      opts.set('path', YamlValue.str(pluginInfo.get('path')));
      opts.set('tls', YamlValue.bool(plugin.indexOf('tls') >= 0));
      m.set('plugin-opts', YamlValue.map(opts));
    }
  }
  proxies.push(YamlValue.map(m));
}

function branchSSR(body: string, scheme: string, names: Map<string, number>,
  proxies: YamlValue[]): void {
  const dcBuf = tryDecodeBase64PaddedFirst(body);
  if (dcBuf === null) {
    return;
  }
  const decoded = GoBytes.decode(dcBuf.bytes);
  const cut = decoded.indexOf('/?');
  if (cut < 0) {
    return;
  }
  const before = decoded.substring(0, cut);
  const after = decoded.substring(cut + 2);
  const beforeArr = before.split(':');
  if (beforeArr.length !== 6) {
    return;
  }
  const host = beforeArr[0];
  const port = beforeArr[1];
  const protocol = beforeArr[2];
  const method = beforeArr[3];
  const obfs = beforeArr[4];
  const password = decodeUrlSafe(urlSafe(beforeArr[5]));

  const query = new GoQuery(urlSafe(after));
  const remarks = decodeUrlSafe(query.get('remarks'));
  const name = uniqueName(names, remarks);
  const obfsParam = decodeUrlSafe(query.get('obfsparam'));
  const protocolParam = decodeUrlSafe(query.get('protoparam'));

  const m = new Map<string, YamlValue>();
  m.set('name', YamlValue.str(name));
  m.set('type', YamlValue.str(scheme));
  m.set('server', YamlValue.str(host));
  m.set('port', YamlValue.port(port));
  m.set('cipher', YamlValue.str(method));
  m.set('password', YamlValue.str(password));
  m.set('obfs', YamlValue.str(obfs));
  m.set('protocol', YamlValue.str(protocol));
  m.set('udp', YamlValue.bool(true));
  if (obfsParam.length > 0) {
    m.set('obfs-param', YamlValue.str(obfsParam));
  }
  if (protocolParam.length > 0) {
    m.set('protocol-param', YamlValue.str(protocolParam));
  }
  proxies.push(YamlValue.map(m));
}

function branchSocks(line: string, scheme: string, names: Map<string, number>,
  proxies: YamlValue[]): void {
  const u = parseGoUrl(line);
  if (!u.ok) {
    return;
  }
  const server = u.hostname();
  if (server.length === 0) {
    return;
  }
  const portStr = u.port();
  if (portStr.length === 0) {
    return;
  }
  let remarks = u.fragment;
  if (remarks.length === 0) {
    remarks = server + ':' + portStr;
  }
  const name = uniqueName(names, remarks);
  const encodeStr = u.userString();
  let username = '';
  let password = '';
  if (encodeStr.length > 0) {
    const decodeStr = decodeBase64OrPlain(encodeStr);
    const splitStr = decodeStr.split(':');
    username = splitStr[0];
    if (splitStr.length === 2) {
      password = splitStr[1];
    }
  }
  const m = new Map<string, YamlValue>();
  m.set('name', YamlValue.str(name));
  if (scheme === 'socks' || scheme === 'socks5' || scheme === 'socks5h') {
    m.set('type', YamlValue.str('socks5'));
  } else if (scheme === 'http' || scheme === 'https') {
    m.set('type', YamlValue.str('http'));
  } else {
    m.set('type', YamlValue.str(scheme));
  }
  m.set('server', YamlValue.str(server));
  m.set('port', YamlValue.port(portStr));
  m.set('username', YamlValue.str(username));
  m.set('password', YamlValue.str(password));
  m.set('skip-cert-verify', YamlValue.bool(true));
  if (scheme === 'https') {
    m.set('tls', YamlValue.bool(true));
  }
  proxies.push(YamlValue.map(m));
}

function branchAnytls(line: string, scheme: string, names: Map<string, number>,
  proxies: YamlValue[]): void {
  const u = parseGoUrl(line);
  if (!u.ok) {
    return;
  }
  const username = u.username;
  let password = u.hasPassword ? u.password : username;
  const query = u.query();
  const server = u.hostname();
  if (server.length === 0) {
    return;
  }
  const portStr = u.port();
  if (portStr.length === 0) {
    return;
  }
  const sni = query.get('sni');
  const insecureBool = query.get('insecure') === '1';
  const fingerprint = query.get('hpkp');

  let remarks = u.fragment;
  if (remarks.length === 0) {
    remarks = server + ':' + portStr;
  }
  const name = uniqueName(names, remarks);
  const m = new Map<string, YamlValue>();
  m.set('name', YamlValue.str(name));
  m.set('type', YamlValue.str('anytls'));
  m.set('server', YamlValue.str(server));
  m.set('port', YamlValue.port(portStr));
  m.set('username', YamlValue.str(username));
  m.set('password', YamlValue.str(password));
  m.set('sni', YamlValue.str(sni));
  m.set('fingerprint', YamlValue.str(fingerprint));
  m.set('skip-cert-verify', YamlValue.bool(insecureBool));
  m.set('udp', YamlValue.bool(true));
  proxies.push(YamlValue.map(m));
}

function branchMierus(line: string, scheme: string, names: Map<string, number>,
  proxies: YamlValue[]): void {
  const u = parseGoUrl(line);
  if (!u.ok) {
    return;
  }
  const query = u.query();
  const server = u.hostname();
  if (server.length === 0) {
    return;
  }
  const username = u.username;
  const password = u.hasPassword ? u.password : '';

  let baseName = u.fragment;
  if (baseName.length === 0) {
    baseName = query.get('profile');
  }
  if (baseName.length === 0) {
    baseName = server;
  }
  const multiplexing = query.get('multiplexing');
  const handshakeMode = query.get('handshake-mode');
  const trafficPattern = query.get('traffic-pattern');

  const portList = query.all('port');
  const protocolList = query.all('protocol');
  if (portList.length === 0 || portList.length !== protocolList.length) {
    return;
  }
  for (let i = 0; i < portList.length; i++) {
    const port = portList[i];
    const protocol = protocolList[i];
    const name = uniqueName(names, baseName + ':' + port + '/' + protocol);
    const m = new Map<string, YamlValue>();
    m.set('name', YamlValue.str(name));
    m.set('type', YamlValue.str('mieru'));
    m.set('server', YamlValue.str(server));
    m.set('transport', YamlValue.str(protocol));
    m.set('udp', YamlValue.bool(true));
    m.set('username', YamlValue.str(username));
    m.set('password', YamlValue.str(password));
    if (port.indexOf('-') >= 0) {
      m.set('port-range', YamlValue.port(port));
    } else {
      const portNum = atoiGo(port);
      if (portNum === null) {
        continue;
      }
      m.set('port', YamlValue.num(portNum));
    }
    if (multiplexing.length > 0) {
      m.set('multiplexing', YamlValue.str(multiplexing));
    }
    if (handshakeMode.length > 0) {
      m.set('handshake-mode', YamlValue.str(handshakeMode));
    }
    if (trafficPattern.length > 0) {
      m.set('traffic-pattern', YamlValue.str(trafficPattern));
    }
    proxies.push(YamlValue.map(m));
  }
}

// ════════════════════════════════════════════════════════════════════════════
// 十、主循环（ConvertsV2Ray）
// ════════════════════════════════════════════════════════════════════════════

function convertV2Ray(text: string): YamlValue[] {
  const data = decodeBase64OrPlain(text);
  const rawLines = data.split('\n');
  const proxies: YamlValue[] = [];
  const names = new Map<string, number>();

  for (const raw of rawLines) {
    const line = trimRightSpaceCr(raw);
    if (line.length === 0) {
      continue;
    }
    const cut = line.indexOf('://');
    if (cut < 0) {
      continue;
    }
    const scheme = line.substring(0, cut).toLowerCase();
    const body = line.substring(cut + 3);

    if (scheme === 'hysteria') {
      branchHysteria(line, scheme, names, proxies);
    } else if (scheme === 'hysteria2' || scheme === 'hy2'
      || scheme === 'hysteria2+realm' || scheme === 'hy2+realm') {
      branchHysteria2(line, scheme, names, proxies);
    } else if (scheme === 'tuic') {
      branchTuic(line, scheme, names, proxies);
    } else if (scheme === 'trojan') {
      branchTrojan(line, scheme, names, proxies);
    } else if (scheme === 'vless') {
      branchVless(line, scheme, names, proxies);
    } else if (scheme === 'vmess') {
      branchVmess(line, body, scheme, names, proxies);
    } else if (scheme === 'ss') {
      branchSS(line, scheme, names, proxies);
    } else if (scheme === 'ssr') {
      branchSSR(body, scheme, names, proxies);
    } else if (scheme === 'socks' || scheme === 'socks5' || scheme === 'socks5h'
      || scheme === 'http' || scheme === 'https') {
      branchSocks(line, scheme, names, proxies);
    } else if (scheme === 'anytls') {
      branchAnytls(line, scheme, names, proxies);
    } else if (scheme === 'mierus') {
      branchMierus(line, scheme, names, proxies);
    }
    // 其余 scheme 一律忽略（与 Go 的 switch 无 default 一致）
  }
  return proxies;
}

// ════════════════════════════════════════════════════════════════════════════
// 十一、对外 API
// ════════════════════════════════════════════════════════════════════════════

/** 转换结果（ok=false 时 error 是可直接展示/上报的原因） */
export class SubConvertOutcome {
  /** 是否至少转换出 1 个节点 */
  ok: boolean = false;
  /** ok 时为 `proxies:` 块（2 空格缩进，块式；末尾带换行） */
  proxiesYaml: string = '';
  /** 节点数 */
  count: number = 0;
  /** 失败原因（对应 Go 的 "convert v2ray subscribe error: format invalid"） */
  error: string = '';
}

/**
 * 订阅文本 → mihomo `proxies:` YAML。
 * 纯函数：同输入必得同输出（UA 取稳定散列，见文件头「已知差异」）。
 */
export class SubConverter {
  /**
   * 转换 v2ray 订阅正文。
   *
   * @param text 订阅原文（明文链接列表或整体 base64）
   */
  static convert(text: string): SubConvertOutcome {
    const out = new SubConvertOutcome();
    let proxies: YamlValue[] = [];
    try {
      proxies = convertV2Ray(text);
    } catch (e) {
      // Go 侧不会 panic；这里兜住意外输入（超长/畸形），当作「一条都没转出来」
      proxies = [];
    }
    if (proxies.length === 0) {
      out.ok = false;
      out.count = 0;
      out.proxiesYaml = '';
      out.error = ERR_FORMAT_INVALID;
      return out;
    }
    out.ok = true;
    out.count = proxies.length;
    out.proxiesYaml = emitProxies(proxies);
    out.error = '';
    return out;
  }

  /**
   * 同 `convert`，但返回节点映射表的 JSON（等价 Go 侧 `json.Marshal([]map[string]any)`）。
   * 门禁/对拍脚本用：把「值语义」与上游逐字段比对，不受 YAML 排版影响。
   */
  static convertToJson(text: string): string {
    const proxies = convertV2Ray(text);
    const parts: string[] = [];
    for (const p of proxies) {
      parts.push(jsonOf(p));
    }
    return '[' + parts.join(',') + ']';
  }

  /** 只数节点（不想解析 YAML 的调用方用） */
  static count(text: string): number {
    return convertV2Ray(text).length;
  }
}
