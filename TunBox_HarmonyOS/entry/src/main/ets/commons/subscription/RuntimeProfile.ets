/**
 * 运行时配置画像（RuntimeProfile）——「一份配置长什么样」的**唯一中间表示**
 *
 * ## 为什么要有 IR
 *
 * 订阅原文 → 节点列表 → 内核配置，这条链路上现在有两套表示：
 * 一套是 `ProxyNode`（面向存储与 UI，带 id/subscriptionId/持久化字段），
 * 一套是 mihomo 的 YAML 行（面向内核）。中间没有一个**稳定的、可比对的**结构，
 * 于是「这次订阅和上次到底变了什么」只能靠 diff 文本，
 * 「节点是不是完整」只能靠人眼看。
 *
 * RuntimeProfile 把中间那层显式化：
 * - **节点**（含可用性 + 不可用原因 + 逐字段参数）
 * - **组**（选择器 / url-test / fallback / load-balance / relay）
 * - **规则**（type + payload + 目标）
 * - **provider 引用**（rule-provider / proxy-provider）
 *
 * 有了它才能回答三个以前回答不了的问题：
 * 1. 「这份配置比上次变了什么？」→ `profileFingerprint()` 比对。
 * 2. 「这个节点为什么不可用？」→ `ProfileNode.unusableReason`（缺哪个参数）。
 * 3. 「RULE-SET 引用的 provider 声明了吗？」→ `providerRefs` 对账。
 *
 * ## 指纹口径
 *
 * `profileFingerprint()` = 对**规范化文本**求 SHA-256（64 位十六进制）。
 * 规范化文本由 `profileCanonicalText()` 生成：**排序稳定、字段齐全**，
 * 所以「内容没变 ⇒ 指纹不变；内容变 ⇒ 指纹变」。
 *
 * SHA-256 是**在本文件内自带的纯实现**（不 import 任何 kit）：
 * - ArkTS 侧无 kit 依赖，纯逻辑；
 * - Node 侧测试台可以直接跑，闸门用 node:crypto 对账同一份规范化文本，
 *   两边算出同一个摘要才算过（实现错了闸门会红，不会静默）。
 *
 * ## ArkTS 纪律
 *
 * 不用 enum / interface / 未标注对象字面量；不 import 任何 kit；纯逻辑、可在 Node 侧跑。
 */

/** 画像里的一个节点 */
export class ProfileNode {
  /** 稳定 id（同一订阅同一节点跨刷新不变） */
  id: string = '';
  /** 显示名 */
  name: string = '';
  /** 规范协议名 */
  protocol: string = '';
  /** 地址 */
  server: string = '';
  /** 端口 */
  port: number = 0;
  /** 是否可用（缺必填参数 ⇒ false，且给出原因） */
  usable: boolean = true;
  /** 不可用原因（中文，直接可展示） */
  unusableReason: string = '';
  /** 逐字段参数（规范键 → 值） */
  params: Map<string, string> = new Map<string, string>();
}

/** 画像里的一个组 */
export class ProfileGroup {
  /** 组名 */
  name: string = '';
  /** 组类型：select / url-test / fallback / load-balance / relay */
  kind: string = 'select';
  /** 成员（节点名或组名，按序） */
  members: string[] = [];
}

/** 画像里的一条规则 */
export class ProfileRule {
  /** 规则类型：DOMAIN / DOMAIN-SUFFIX / GEOIP / RULE-SET / MATCH … */
  type: string = '';
  /** 规则载荷（域名 / 网段 / provider 名 …） */
  payload: string = '';
  /** 目标（组名 / 节点名） */
  target: string = '';
}

/** 画像里的一个 provider 引用 */
export class ProfileProviderRef {
  /** provider 名 */
  name: string = '';
  /** 种类：rule-provider / proxy-provider */
  kind: string = 'rule-provider';
  /** 行为（rule-provider 的 behavior；proxy-provider 留空） */
  behavior: string = '';
  /** 下载地址 */
  url: string = '';
  /** 本地路径 */
  path: string = '';
}

/** 一份完整的运行时画像 */
export class RuntimeProfile {
  /** 节点 */
  nodes: ProfileNode[] = [];
  /** 组 */
  groups: ProfileGroup[] = [];
  /** 规则 */
  rules: ProfileRule[] = [];
  /** provider 引用 */
  providerRefs: ProfileProviderRef[] = [];
}

/** 纯 JS SHA-256（ArkTS / Node 通用，不依赖任何 kit） */
export class Sha256 {
  private static readonly K: number[] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ];

  /** 文本 → UTF-8 字节 */
  static utf8Bytes(text: string): number[] {
    const out: number[] = [];
    let i = 0;
    while (i < text.length) {
      const code = text.charCodeAt(i);
      if (code < 0x80) {
        out.push(code);
        i += 1;
      } else if (code < 0x800) {
        out.push(0xC0 | (code >> 6), 0x80 | (code & 0x3F));
        i += 1;
      } else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length) {
        const next = text.charCodeAt(i + 1);
        if (next >= 0xDC00 && next <= 0xDFFF) {
          const cp = 0x10000 + ((code - 0xD800) << 10) + (next - 0xDC00);
          out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F),
            0x80 | (cp & 0x3F));
          i += 2;
        } else {
          out.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
          i += 1;
        }
      } else {
        out.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
        i += 1;
      }
    }
    return out;
  }

  /** 32 位右循环 */
  private static rotr(x: number, n: number): number {
    return ((x >>> n) | (x << (32 - n))) | 0;
  }

  /** 8 位十六进制（不用 padStart，ArkTS 兼容更稳） */
  private static hex8(value: number): string {
    const digits = '0123456789abcdef';
    let out = '';
    for (let shift = 28; shift >= 0; shift -= 4) {
      out += digits.charAt((value >>> shift) & 0xF);
    }
    return out;
  }

  /** 文本 → SHA-256 十六进制（64 字符，小写） */
  static digestHex(text: string): string {
    const msg: number[] = Sha256.utf8Bytes(text);
    const bitLen = msg.length * 8;
    msg.push(0x80);
    while (msg.length % 64 !== 56) {
      msg.push(0);
    }
    const high = Math.floor(bitLen / 4294967296);
    const low = bitLen >>> 0;
    msg.push((high >>> 24) & 0xFF, (high >>> 16) & 0xFF, (high >>> 8) & 0xFF, high & 0xFF);
    msg.push((low >>> 24) & 0xFF, (low >>> 16) & 0xFF, (low >>> 8) & 0xFF, low & 0xFF);

    const h: number[] = [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ];
    const w: number[] = new Array<number>(64);
    for (let offset = 0; offset < msg.length; offset += 64) {
      for (let i = 0; i < 16; i++) {
        w[i] = (msg[offset + i * 4] << 24) | (msg[offset + i * 4 + 1] << 16)
          | (msg[offset + i * 4 + 2] << 8) | msg[offset + i * 4 + 3];
      }
      for (let i = 16; i < 64; i++) {
        const s0 = Sha256.rotr(w[i - 15], 7) ^ Sha256.rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
        const s1 = Sha256.rotr(w[i - 2], 17) ^ Sha256.rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
      }
      let a = h[0];
      let b = h[1];
      let c = h[2];
      let d = h[3];
      let e = h[4];
      let f = h[5];
      let g = h[6];
      let hh = h[7];
      for (let i = 0; i < 64; i++) {
        const S1 = Sha256.rotr(e, 6) ^ Sha256.rotr(e, 11) ^ Sha256.rotr(e, 25);
        const ch = (e & f) ^ ((~e) & g);
        const temp1 = (hh + S1 + ch + Sha256.K[i] + w[i]) | 0;
        const S0 = Sha256.rotr(a, 2) ^ Sha256.rotr(a, 13) ^ Sha256.rotr(a, 22);
        const maj = (a & b) ^ (a & c) ^ (b & c);
        const temp2 = (S0 + maj) | 0;
        hh = g;
        g = f;
        f = e;
        e = (d + temp1) | 0;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) | 0;
      }
      h[0] = (h[0] + a) | 0;
      h[1] = (h[1] + b) | 0;
      h[2] = (h[2] + c) | 0;
      h[3] = (h[3] + d) | 0;
      h[4] = (h[4] + e) | 0;
      h[5] = (h[5] + f) | 0;
      h[6] = (h[6] + g) | 0;
      h[7] = (h[7] + hh) | 0;
    }
    let out = '';
    for (let i = 0; i < 8; i++) {
      out += Sha256.hex8(h[i]);
    }
    return out;
  }
}

/** 画像的规范化文本（排序稳定、字段齐全；同一份画像必得同一串） */
export function profileCanonicalText(profile: RuntimeProfile): string {
  const lines: string[] = [];
  const nodes = profile.nodes.slice();
  nodes.sort((a: ProfileNode, b: ProfileNode): number => (a.id < b.id ? -1 : (a.id > b.id ? 1 : 0)));
  for (const node of nodes) {
    const keys: string[] = [];
    for (const key of Array.from(node.params.keys())) {
      keys.push(key);
    }
    keys.sort();
    const parts: string[] = [];
    for (const key of keys) {
      parts.push(`${key}=${node.params.get(key) ?? ''}`);
    }
    lines.push(`node\t${node.id}\t${node.name}\t${node.protocol}\t${node.server}\t${node.port}`
      + `\t${node.usable ? '1' : '0'}\t${node.unusableReason}\t${parts.join(',')}`);
  }
  const groups = profile.groups.slice();
  groups.sort((a: ProfileGroup, b: ProfileGroup): number => (a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)));
  for (const group of groups) {
    const members = group.members.slice();
    lines.push(`group\t${group.name}\t${group.kind}\t${members.join(',')}`);
  }
  const rules = profile.rules.slice();
  rules.sort((a: ProfileRule, b: ProfileRule): number => {
    const left = `${a.type}|${a.payload}|${a.target}`;
    const right = `${b.type}|${b.payload}|${b.target}`;
    return left < right ? -1 : (left > right ? 1 : 0);
  });
  for (const rule of rules) {
    lines.push(`rule\t${rule.type}\t${rule.payload}\t${rule.target}`);
  }
  const providers = profile.providerRefs.slice();
  providers.sort((a: ProfileProviderRef, b: ProfileProviderRef): number =>
    (a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)));
  for (const provider of providers) {
    lines.push(`provider\t${provider.name}\t${provider.kind}\t${provider.behavior}`
      + `\t${provider.url}\t${provider.path}`);
  }
  return lines.join('\n');
}

/**
 * 画像指纹 = 规范化文本的 SHA-256（64 位十六进制）。
 *
 * 用途：判断「这份配置相对上次变了没有」—— 变了才需要重建内核配置 / 重测速。
 */
export function profileFingerprint(profile: RuntimeProfile): string {
  return Sha256.digestHex(profileCanonicalText(profile));
}
