#!/usr/bin/env node
/**
 * HTTP 正文解码闸门（Http Body Codec Gate）
 *
 * ## 为什么要有这道闸门
 *
 * 部分机场的订阅响应是 **gzip / zlib 压缩流，却没有 `Content-Encoding` 头**。
 * FlClash 在 `lib/common/request.dart` 的 `decompressUnlabeled()` 里按魔数识别、
 * 解压后再交给内核；TunBox 之前没有等价实现，同一份订阅会被当成乱码正文，
 * base64 / YAML 分派全落空 ⇒ 用户看到「导入失败 / 0 节点」。
 *
 * 设备侧 `@ohos.zlib` 只有文件级 GZip，没有内存 buffer 的 inflate，所以
 * `HttpBodyCodec.ets` 用纯 TypeScript 实现了 RFC1951 inflate + RFC1952 gzip
 * + RFC1950 zlib。**纯逻辑的价值必须被证明**：本闸门把真源码 stage 到临时目录
 * （Node 24 type-stripping，`from './X'` → `from './X.ts'` 的改写机制照抄
 * `verify-sub-parse-fidelity.mjs`），再用 `node:zlib` 当独立编码器对账。
 *
 * ## 闸门断言什么
 *
 *   A. 源码卫生：没有 `@kit.*` / `@ohos.*` import、没有任何 import、没有 `any`、
 *      没有 `@ts-*` 指令（否则"能在 Node 里跑"就只是碰巧）。
 *   B. 魔数识别：gzip `1f 8b`、zlib `0x78 + FCHECK`；空 / 过短 / 坏 FCHECK ⇒ false。
 *   C. 逐字节保真：空、1 字节、全 256 字节值、ASCII JSON、中文+emoji、1 MiB 长重复、
 *      1 MiB 伪随机 —— 每种都过 8 个编码变体（gzip/zlib × 默认/stored/fixed/
 *      Huffman-only），解压结果必须与原文**逐字节相等**。
 *   D. 裸 deflate（`deflateRawSync`）没有 gzip/zlib 包装 ⇒ 不被误判、原样返回。
 *   E. gzip 可选字段：FTEXT/FHCRC/FEXTRA（little-endian XLEN，含 0 与 260 两种）/
 *      FNAME/FCOMMENT 全带时仍能定位 deflate 起点。
 *   F. 明文正文（非压缩）⇒ `looksCompressed=false`、`decompress` 原样返回。
 *   G. 负向：截断 / CRC32 坏 / ISIZE 坏 / CM 非 deflate / 保留位非 0 / FNAME 无 0 结尾 /
 *      zlib 尾部截断 / Adler-32 坏 / FDICT / FCHECK 坏 / 非法块类型 3 /
 *      Huffman 表过订阅 / 回溯距离越界 / stored LEN·NLEN 不符 ——
 *      损坏的**必须抛带可读原因的 Error，绝不返回半截数据**；识别不了的原样返回。
 *   H. 大小上限：17 MiB 输出必须被拒（防压缩炸弹），16 MiB 必须仍能解。
 *
 * ## 负对照（闸门必须真的会红）
 *
 *   node scripts/verify-http-body-codec.mjs --self-test
 * 会把 HttpBodyCodec.ets 复制一份、**故意改坏**（解压退化成原样返回 / 魔数恒 false /
 * gzip 分支摘掉），再跑同一套断言 —— 必须报 FAILED。闸门咬不住改坏 = 闸门没用。
 *
 * ## 跑法
 *
 *   node scripts/verify-http-body-codec.mjs              # 正常跑
 *   node scripts/verify-http-body-codec.mjs --self-test  # 附带负对照
 *
 * 退出码：0 = 全过；1 = 有断言失败（或负对照没被抓住）。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const codecFile = path.join(root, 'entry/src/main/ets/commons/subscription/HttpBodyCodec.ets');
const MIB = 1024 * 1024;

/** ── 加载 .ets（Node 侧 type-stripping；只 stage 这一个文件，它没有依赖）── */

function stageModule() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tunbox-http-body-'));
  fs.writeFileSync(path.join(tmp, 'package.json'), JSON.stringify({ type: 'module' }), 'utf8');
  const text = fs.readFileSync(codecFile, 'utf8');
  // 目前 HttpBodyCodec 没有相对 import；仍保留改写，和仓库其它闸门的 stage 机制一致
  const patched = text.replace(/from '\.\/([A-Za-z0-9_]+)'/g, "from './$1.ts'");
  fs.writeFileSync(path.join(tmp, 'HttpBodyCodec.ts'), patched, 'utf8');
  return { dir: tmp, source: text };
}

async function loadModule(dir) {
  const url = pathToFileURL(path.join(dir, 'HttpBodyCodec.ts')).href;
  return import(url);
}

/** ── 样本与编码器（编码侧全部用 node:zlib，独立实现，才能当真 oracle）── */

function repeatPattern(length) {
  const unit = Buffer.from('{"name":"HK-01","type":"ss"},', 'utf8');
  const out = new Uint8Array(length);
  for (let i = 0; i < length; i++) {
    out[i] = unit[i % unit.length];
  }
  return out;
}

/** 确定性 PRNG（xorshift32）：伪随机样本必须可复现，闸门不能随机飘 */
function pseudoRandom(seed, length) {
  let state = seed >>> 0;
  const out = new Uint8Array(length);
  for (let i = 0; i < length; i++) {
    state ^= state << 13;
    state >>>= 0;
    state ^= state >>> 17;
    state ^= state << 5;
    state >>>= 0;
    out[i] = state & 0xff;
  }
  return out;
}

function buildSamples() {
  const everyByte = new Uint8Array(64 * 1024);
  for (let i = 0; i < everyByte.length; i++) {
    everyByte[i] = i & 0xff;
  }
  return [
    { name: '空正文（0 字节）', bytes: new Uint8Array(0) },
    { name: '1 字节（0x41）', bytes: Uint8Array.from([0x41]) },
    { name: '全部 256 个字节值（64 KiB 循环 0x00..0xff）', bytes: everyByte },
    {
      name: 'ASCII JSON 正文',
      bytes: Buffer.from('{"proxies":[{"name":"HK-01","type":"ss","server":"1.2.3.4",'
        + '"port":8388,"cipher":"aes-128-gcm"}],"rules":[]}', 'utf8'),
    },
    {
      name: '含中文 / emoji 的 UTF-8 正文',
      bytes: Buffer.from('{"剩余流量":"596.22 GB","套餐到期":"长期有效 🚀",'
        + '"节点":["香港 01","日本 02","新加坡 03"]}', 'utf8'),
    },
    { name: '1 MiB 长重复串', bytes: repeatPattern(MIB) },
    { name: '1 MiB 伪随机字节', bytes: pseudoRandom(0x5eed1234, MIB) },
  ];
}

// Node 的 zlib.constants 没有 Z_STORED（那是压缩级别而不是策略）；
// "stored 块"用 level=0（= Z_NO_COMPRESSION）生成，fixed / Huffman-only 用 strategy。
const VARIANTS = [
  { name: 'gzip 默认级（dynamic 块）', encode: (b) => zlib.gzipSync(b) },
  { name: 'gzip level=0（stored 块）', encode: (b) => zlib.gzipSync(b, { level: 0 }) },
  {
    name: 'gzip Z_FIXED（fixed 块）',
    encode: (b) => zlib.gzipSync(b, { strategy: zlib.constants.Z_FIXED }),
  },
  {
    name: 'gzip Z_HUFFMAN_ONLY',
    encode: (b) => zlib.gzipSync(b, { strategy: zlib.constants.Z_HUFFMAN_ONLY }),
  },
  { name: 'zlib 默认级（dynamic 块）', encode: (b) => zlib.deflateSync(b) },
  { name: 'zlib level=0（stored 块）', encode: (b) => zlib.deflateSync(b, { level: 0 }) },
  {
    name: 'zlib Z_FIXED（fixed 块）',
    encode: (b) => zlib.deflateSync(b, { strategy: zlib.constants.Z_FIXED }),
  },
  {
    name: 'zlib Z_HUFFMAN_ONLY',
    encode: (b) => zlib.deflateSync(b, { strategy: zlib.constants.Z_HUFFMAN_ONLY }),
  },
];

/** ── 手工构造的 gzip 头（Node 生成不了 FEXTRA/FNAME/FCOMMENT/FHCRC）── */

function u32le(value) {
  const out = Buffer.alloc(4);
  out.writeUInt32LE(value >>> 0, 0);
  return out;
}

function gzipWithOptionalFields(payload, extraLen, flags) {
  const raw = zlib.deflateRawSync(payload);
  const header = [0x1f, 0x8b, 0x08, flags, 0, 0, 0, 0, 0x00, 0xff];
  if ((flags & 0x04) !== 0) {
    // FEXTRA 的 XLEN 是 little-endian：读成 big-endian 会把 0x0104 当成 4 而错位
    header.push(extraLen & 0xff, (extraLen >> 8) & 0xff);
    for (let i = 0; i < extraLen; i++) {
      header.push(i & 0xff);
    }
  }
  const parts = [Buffer.from(header)];
  if ((flags & 0x08) !== 0) {
    parts.push(Buffer.from('subscription.txt', 'utf8'), Buffer.from([0]));
  }
  if ((flags & 0x10) !== 0) {
    parts.push(Buffer.from('tunbox', 'utf8'), Buffer.from([0]));
  }
  if ((flags & 0x02) !== 0) {
    // FHCRC 只要求跳过 2 字节（头 CRC 不校验），填任意值
    parts.push(Buffer.from([0xde, 0xad]));
  }
  parts.push(raw, u32le(zlib.crc32(payload)), u32le(payload.length));
  return Buffer.concat(parts);
}

/** ── 手工构造的损坏 deflate（zlib 自己不会产出坏流）── */

class BitWriter {
  constructor() {
    this.bytes = [];
    this.cur = 0;
    this.n = 0;
  }

  bit(value) {
    this.cur |= (value & 1) << this.n;
    this.n += 1;
    if (this.n === 8) {
      this.bytes.push(this.cur);
      this.cur = 0;
      this.n = 0;
    }
  }

  /** 按 inflate 的读取顺序（LSB 在前）写 value 的低 count 位 */
  bitsLSB(value, count) {
    for (let i = 0; i < count; i++) {
      this.bit((value >>> i) & 1);
    }
  }

  /** Huffman 码字在线上是 MSB 在前（逐位读时先读最高位） */
  bitsMSB(value, count) {
    for (let i = count - 1; i >= 0; i--) {
      this.bit((value >>> i) & 1);
    }
  }

  align() {
    if (this.n > 0) {
      this.bytes.push(this.cur);
      this.cur = 0;
      this.n = 0;
    }
  }

  toBuffer() {
    this.align();
    return Buffer.from(this.bytes);
  }
}

function wrapZlib(deflateBytes) {
  return Buffer.concat([Buffer.from([0x78, 0x01]), deflateBytes, Buffer.alloc(4)]);
}

/** dynamic 块：257 个 literal 码长全是 1 ⇒ Huffman 表过订阅（zlib 也会拒绝） */
function malformedOversubscribedDynamic() {
  const writer = new BitWriter();
  writer.bitsLSB(1, 1); // BFINAL=1
  writer.bitsLSB(2, 2); // BTYPE=10（dynamic）
  writer.bitsLSB(0, 5); // HLIT=257
  writer.bitsLSB(0, 5); // HDIST=1
  writer.bitsLSB(15, 4); // HCLEN=19（覆盖到符号 1）
  const order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];
  for (const symbol of order) {
    writer.bitsLSB(symbol === 0 || symbol === 1 ? 1 : 0, 3);
  }
  // 码长码树：符号 0 的码是 0、符号 1 的码是 1（长度都是 1）
  for (let i = 0; i < 258; i++) {
    writer.bitsLSB(1, 1); // 258 个码长值全 = 1
  }
  return wrapZlib(writer.toBuffer());
}

/** fixed 块：literal 257（长度 3）+ 距离码 0（距离 1），但输出还是 0 字节 ⇒ 距离越界 */
function malformedDistanceOutOfRange() {
  const writer = new BitWriter();
  writer.bitsLSB(1, 1); // BFINAL=1
  writer.bitsLSB(1, 2); // BTYPE=01（fixed）
  writer.bitsMSB(0b0000001, 7); // fixed 树里 literal/length 257 的码字
  writer.bitsMSB(0, 5); // fixed 距离树里符号 0 ⇒ 距离 1
  return wrapZlib(writer.toBuffer());
}

/** stored 块：LEN=5 但 NLEN 不是 ~5（RFC1951 要求逐位取反） */
function malformedStoredLength() {
  return Buffer.concat([
    Buffer.from([0x78, 0x01, 0x01, 0x05, 0x00, 0xfb, 0xff, 0x41, 0x42, 0x43, 0x44, 0x45]),
    Buffer.alloc(4),
  ]);
}

function buildNegatives() {
  const payload = Buffer.from('{"proxies":[{"name":"HK-01","type":"ss"}],"emoji":"🚀"}', 'utf8');
  const gz = zlib.gzipSync(payload);
  const def = zlib.deflateSync(payload);

  const truncatedGzip = Buffer.from(gz.subarray(0, Math.floor(gz.length / 2)));
  const badCrc = Buffer.from(gz);
  badCrc[badCrc.length - 8] ^= 0xff;
  const badIsize = Buffer.from(gz);
  badIsize[badIsize.length - 1] ^= 0xff;
  const badCm = Buffer.from(gz);
  badCm[2] = 0x07;
  const reservedFlags = Buffer.from(gz);
  reservedFlags[3] = 0xe0;
  const noNulName = Buffer.concat([
    Buffer.from([0x1f, 0x8b, 0x08, 0x08, 0, 0, 0, 0, 0x00, 0xff]),
    Buffer.from('subscription-with-a-very-long-name-and-no-terminator', 'utf8'),
  ]);
  const truncatedGzipHeader = Buffer.from(gz.subarray(0, 5));

  const truncatedZlib = Buffer.from(def.subarray(0, def.length - 2));
  const badAdler = Buffer.from(def);
  badAdler[badAdler.length - 1] ^= 0xff;
  const badFcheck = Buffer.from([0x78, 0x00, 0x03, 0x00, 0, 0, 0, 0]);
  const fdict = Buffer.from([0x78, 0x20, 0, 0, 0, 0, 0, 0, 0, 0]);
  const illegalBlockType = Buffer.concat([Buffer.from([0x78, 0x01, 0x07, 0x00]), Buffer.alloc(4)]);

  return [
    {
      name: 'gzip 去掉一半（截断）',
      bytes: truncatedGzip,
      magic: true,
      kind: 'throw',
      reason: /截断/,
    },
    {
      name: 'gzip 头部只剩 5 字节（截断）',
      bytes: truncatedGzipHeader,
      magic: true,
      kind: 'throw',
      reason: /截断|过短/,
    },
    {
      name: 'gzip CRC32 被改坏',
      bytes: badCrc,
      magic: true,
      kind: 'throw',
      reason: /CRC|校验/,
    },
    {
      name: 'gzip ISIZE 被改坏',
      bytes: badIsize,
      magic: true,
      kind: 'throw',
      reason: /ISIZE|长度/,
    },
    {
      name: 'gzip 压缩方法不是 deflate（CM=7）',
      bytes: badCm,
      magic: true,
      kind: 'throw',
      reason: /deflate|压缩方法/,
    },
    {
      name: 'gzip FLG 保留位非 0',
      bytes: reservedFlags,
      magic: true,
      kind: 'throw',
      reason: /保留位/,
    },
    {
      name: 'gzip FNAME 没有 0 结尾',
      bytes: noNulName,
      magic: true,
      kind: 'throw',
      reason: /FNAME/,
    },
    {
      name: 'zlib 尾部少 2 字节（截断）',
      bytes: truncatedZlib,
      magic: true,
      kind: 'throw',
      reason: /Adler|截断|校验/,
    },
    {
      name: 'zlib Adler-32 被改坏',
      bytes: badAdler,
      magic: true,
      kind: 'throw',
      reason: /Adler|校验/,
    },
    {
      name: 'zlib FDICT（声明了预置字典）',
      bytes: fdict,
      magic: true,
      kind: 'throw',
      reason: /FDICT|字典/,
    },
    {
      name: 'zlib 头 0x78 但 FLG 校验失败（非压缩，原样返回）',
      bytes: badFcheck,
      magic: false,
      kind: 'same',
    },
    {
      name: 'deflate 非法块类型 3',
      bytes: illegalBlockType,
      magic: true,
      kind: 'throw',
      reason: /块类型/,
    },
    {
      name: 'dynamic 块 Huffman 表过订阅',
      bytes: malformedOversubscribedDynamic(),
      magic: true,
      kind: 'throw',
      reason: /Huffman/,
    },
    {
      name: 'fixed 块回溯距离越界',
      bytes: malformedDistanceOutOfRange(),
      magic: true,
      kind: 'throw',
      reason: /距离越界/,
    },
    {
      name: 'stored 块 LEN/NLEN 不匹配',
      bytes: malformedStoredLength(),
      magic: true,
      kind: 'throw',
      reason: /LEN|NLEN/,
    },
    {
      name: '空数据（0 字节，非压缩）',
      bytes: new Uint8Array(0),
      magic: false,
      kind: 'same',
    },
    {
      name: 'gzip 第一个字节单独出现（1 字节，非压缩）',
      bytes: Uint8Array.from([0x1f]),
      magic: false,
      kind: 'same',
    },
    {
      name: '明文 JSON（非压缩）',
      bytes: Buffer.from('{"proxies":[]}', 'utf8'),
      magic: false,
      kind: 'same',
    },
  ];
}

/** ── 比对工具 ── */

function bytesEqual(a, b) {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

function diffDetail(actual, expected) {
  const n = Math.min(actual.length, expected.length);
  for (let i = 0; i < n; i++) {
    if (actual[i] !== expected[i]) {
      return `长度 ${actual.length}/${expected.length}，首个差异 @${i}: `
        + `0x${actual[i].toString(16)} != 0x${expected[i].toString(16)}`;
    }
  }
  return `长度 ${actual.length} != ${expected.length}`;
}

/** ── 检查器 ──────────────────────────────────────────────────────────────── */

function runChecks(codec, source) {
  const lines = [];
  let passed = 0;
  let failed = 0;
  let forwardCount = 0;
  let negativeCount = 0;
  let extraCount = 0;
  const ok = (cond, label, detail) => {
    if (cond) {
      passed += 1;
    } else {
      failed += 1;
      lines.push(`  ❌ ${label}${detail ? ` — ${detail}` : ''}`);
    }
  };

  // ── A. 源码卫生：纯逻辑、零 kit 依赖、无 any ──
  // 只看真正的 import 语句（注释里提到 @kit.* / @ohos.* 是正常的说明文字）
  ok(!/^\s*import\s[^\n]*@(kit|ohos)\./m.test(source) && !/from\s+'@(kit|ohos)\./.test(source),
    '源码不 import 任何 @kit.* / @ohos.*（Node 侧能直接跑）');
  ok(!/^\s*import\s/m.test(source), '源码没有任何 import（纯逻辑、零依赖）');
  ok(!/(:\s*any\b|\bas\s+any\b|<any>)/.test(source), '源码没有 any（ArkTS 严格模式可通过）');
  ok(!/@ts-(ignore|nocheck|expect-error)/.test(source), '源码没有 @ts-* 指令（不靠放宽类型检查过闸）');

  // ── B. 魔数识别 ──
  const u8 = (values) => Uint8Array.from(values);
  ok(codec.looksCompressed(u8([0x1f, 0x8b])) === true, '魔数：gzip 头 1f 8b ⇒ true');
  ok(codec.looksCompressed(u8([0x78, 0x9c])) === true, '魔数：zlib 头 78 9c ⇒ true');
  ok(codec.looksCompressed(u8([0x78, 0x01])) === true, '魔数：zlib 头 78 01 ⇒ true');
  ok(codec.looksCompressed(u8([0x78, 0xda])) === true, '魔数：zlib 头 78 da ⇒ true');
  ok(codec.looksCompressed(u8([0x78, 0x00])) === false,
    '魔数：0x78 但 FLG 校验失败 ⇒ false（FlClash 同口径）');
  ok(codec.looksCompressed(u8([0x1f])) === false, '魔数：只有 1 字节 ⇒ false（过短）');
  ok(codec.looksCompressed(new Uint8Array(0)) === false, '魔数：空数据 ⇒ false');
  ok(codec.looksCompressed(u8([0x1f, 0x8c])) === false, '魔数：1f 8c 不是 gzip ⇒ false');

  // ── C. 逐字节保真：8 个编码变体 × 7 组数据 ──
  const samples = buildSamples();
  for (const sample of samples) {
    for (const variant of VARIANTS) {
      forwardCount += 1;
      const encoded = variant.encode(sample.bytes);
      const tag = `「${sample.name}」× ${variant.name}`;
      ok(codec.looksCompressed(encoded) === true, `${tag} ⇒ 魔数识别为压缩流`);
      let out = null;
      let err = null;
      try {
        out = codec.decompress(encoded);
      } catch (e) {
        err = e;
      }
      ok(out !== null, `${tag} ⇒ 解压成功（${encoded.length} → ${sample.bytes.length} 字节）`,
        err && err.message);
      if (out !== null) {
        ok(out.length === sample.bytes.length && bytesEqual(out, sample.bytes),
          `${tag} ⇒ 输出与原文逐字节相等`, diffDetail(out, sample.bytes));
      }
    }
  }

  // ── D. 裸 deflate 不该被魔数识别（FlClash 也只认 gzip/zlib 包装）──
  for (const sample of samples) {
    forwardCount += 1;
    const raw = zlib.deflateRawSync(sample.bytes);
    const tag = `「${sample.name}」× 裸 deflate（无 gzip/zlib 包装）`;
    ok(codec.looksCompressed(raw) === false, `${tag} ⇒ 不被魔数误判（${raw.length} 字节）`);
    let out = null;
    let err = null;
    try {
      out = codec.decompress(raw);
    } catch (e) {
      err = e;
    }
    ok(err === null && out !== null, `${tag} ⇒ 不抛错（不是压缩流）`, err && err.message);
    if (out !== null) {
      ok(bytesEqual(out, raw), `${tag} ⇒ 原样返回（不解压）`);
    }
  }

  // ── E. gzip 可选字段：FEXTRA（XLEN 两种）+ FNAME + FCOMMENT + FHCRC ──
  const flaggedPayload = Buffer.from('{"name":"香港 01 🚀","type":"ss"}', 'utf8');
  const flaggedCases = [
    { name: '全字段（FTEXT|FHCRC|FEXTRA|FNAME|FCOMMENT，XLEN=260）', extraLen: 260, flags: 0x1f },
    { name: '只有 FEXTRA（XLEN=0）', extraLen: 0, flags: 0x04 },
  ];
  for (const flagged of flaggedCases) {
    forwardCount += 1;
    const encoded = gzipWithOptionalFields(flaggedPayload, flagged.extraLen, flagged.flags);
    const tag = `gzip ${flagged.name}`;
    ok(codec.looksCompressed(encoded) === true, `${tag} ⇒ 魔数识别为 gzip`);
    let out = null;
    let err = null;
    try {
      out = codec.decompress(encoded);
    } catch (e) {
      err = e;
    }
    ok(err === null && out !== null, `${tag} ⇒ 跳过可选字段后能解压`, err && err.message);
    if (out !== null) {
      ok(bytesEqual(out, flaggedPayload), `${tag} ⇒ 输出与原文逐字节相等`, diffDetail(out, flaggedPayload));
    }
  }

  // ── F. 明文正文：不识别、原样返回 ──
  const plainCases = [
    samples[3], samples[4], samples[1], samples[0],
  ];
  for (const plain of plainCases) {
    forwardCount += 1;
    ok(codec.looksCompressed(plain.bytes) === false, `明文「${plain.name}」⇒ 不识别为压缩流`);
    const out = codec.decompress(plain.bytes);
    ok(bytesEqual(out, plain.bytes), `明文「${plain.name}」⇒ 原样返回`);
  }

  // ── G. 负向：坏流必须抛错且不返回数据 ──
  const negatives = buildNegatives();
  for (const negative of negatives) {
    negativeCount += 1;
    ok(codec.looksCompressed(negative.bytes) === negative.magic,
      `负向「${negative.name}」⇒ looksCompressed === ${negative.magic}`);
    let out = null;
    let err = null;
    try {
      out = codec.decompress(negative.bytes);
    } catch (e) {
      err = e;
    }
    if (negative.kind === 'throw') {
      ok(err !== null && out === null, `负向「${negative.name}」⇒ 抛错且不返回半截数据`);
      if (err !== null) {
        ok(err instanceof Error && typeof err.message === 'string' && err.message.length > 0
          && negative.reason.test(err.message),
        `负向「${negative.name}」⇒ Error 带可读原因`, err && err.message);
      } else {
        ok(false, `负向「${negative.name}」⇒ Error 带可读原因`, '没有抛错');
      }
    } else {
      ok(err === null && out !== null, `负向「${negative.name}」⇒ 不抛错（本来就不是压缩流）`,
        err && err.message);
      if (out !== null) {
        ok(bytesEqual(out, negative.bytes), `负向「${negative.name}」⇒ 原样返回`);
      }
    }
  }

  // ── H. 大小上限：16 MiB 以内可解，17 MiB 必须拒绝 ──
  extraCount += 1;
  const sixteen = Buffer.alloc(16 * MIB, 0x61);
  const sixteenGz = zlib.gzipSync(sixteen, { level: 1 });
  let sixteenOut = null;
  let sixteenErr = null;
  try {
    sixteenOut = codec.decompress(sixteenGz);
  } catch (e) {
    sixteenErr = e;
  }
  ok(sixteenErr === null && sixteenOut !== null && sixteenOut.length === sixteen.length,
    '16 MiB（上限之内）⇒ 解压成功且长度一致', sixteenErr && sixteenErr.message);

  extraCount += 1;
  const seventeenGz = zlib.gzipSync(Buffer.alloc(17 * MIB, 0x61), { level: 1 });
  let limitErr = null;
  let limitOut = null;
  try {
    limitOut = codec.decompress(seventeenGz);
  } catch (e) {
    limitErr = e;
  }
  ok(limitErr !== null && limitOut === null, '17 MiB（超过上限）⇒ 拒绝解压（防压缩炸弹）');
  ok(limitErr !== null && /上限/.test(String(limitErr.message)),
    '17 MiB ⇒ 错误信息写明大小上限', limitErr && limitErr.message);

  // ── I. 稳定性：不改写入参、连续两次结果一致 ──
  extraCount += 1;
  const stablePayload = samples[3].bytes;
  const stableGz = Buffer.from(zlib.gzipSync(stablePayload));
  const snapshot = Buffer.from(stableGz);
  const first = codec.decompress(stableGz);
  ok(bytesEqual(stableGz, snapshot), '解压不改写入参（调用方仍可复用原始字节）');
  const second = codec.decompress(stableGz);
  ok(bytesEqual(first, second) && bytesEqual(first, stablePayload),
    '同一个缓冲区连续解压两次结果一致且等于原文');

  return { passed, failed, lines, forwardCount, negativeCount, extraCount };
}

/** ── 主流程 ──────────────────────────────────────────────────────────────── */

async function main() {
  if (typeof zlib.crc32 !== 'function') {
    console.error('FATAL: 本闸门需要 Node >= 22.2（node:zlib 的 crc32），当前 ' + process.version);
    process.exit(1);
  }
  const selfTest = process.argv.includes('--self-test');
  const staged = stageModule();
  let mod;
  try {
    mod = await loadModule(staged.dir);
  } catch (err) {
    console.error('加载 HttpBodyCodec.ets 失败：', err && err.message);
    process.exit(1);
  }

  console.log('── HTTP 正文解码闸门（没有 Content-Encoding 的 gzip / zlib）──');
  const result = runChecks(mod.HttpBodyCodec, staged.source);
  console.log(`  覆盖：${result.forwardCount} 组正向（7 组数据 × 8 个编码变体 + 裸 deflate`
    + ` + gzip 可选字段 + 明文）、${result.negativeCount} 条负向、${result.extraCount} 项上限/稳定性`);
  console.log(`  断言：${result.passed} passed, ${result.failed} failed`);
  if (result.failed > 0) {
    console.log('');
    for (const line of result.lines) {
      console.log(line);
    }
  }

  let selfTestOk = true;
  if (selfTest) {
    console.log('');
    console.log('── 负对照（故意改坏 HttpBodyCodec.ets，闸门必须 FAILED）──');
    const mutations = [
      {
        name: '解压退化成原样返回（FlClash 式回退）',
        apply: (text) => text.replace(
          '  static decompress(bytes: Uint8Array): Uint8Array {',
          '  static decompress(bytes: Uint8Array): Uint8Array {\n'
          + '    if (bytes.length >= 0) { return bytes; }'),
      },
      {
        name: '魔数识别失灵（looksCompressed 恒 false）',
        apply: (text) => text.replace(
          '  static looksCompressed(bytes: Uint8Array): boolean {',
          '  static looksCompressed(bytes: Uint8Array): boolean {\n'
          + '    if (bytes.length >= 0) { return false; }'),
      },
      {
        name: 'gzip 分支被摘掉（gzip 正文当未压缩返回）',
        apply: (text) => text.replace(
          '      return HttpBodyCodec.inflateGzip(bytes, MAX_OUTPUT_BYTES);',
          '      return bytes;'),
      },
    ];
    for (const mutation of mutations) {
      const dir = stageModule().dir;
      const target = path.join(dir, 'HttpBodyCodec.ts');
      const before = fs.readFileSync(target, 'utf8');
      const after = mutation.apply(before);
      if (after === before) {
        console.log(`  ❌ 负对照「${mutation.name}」无法注入（源码形态变了，需更新本脚本）`);
        selfTestOk = false;
        fs.rmSync(dir, { recursive: true, force: true });
        continue;
      }
      fs.writeFileSync(target, after, 'utf8');
      let mutatedMod;
      try {
        mutatedMod = await loadModule(dir);
      } catch (err) {
        console.log(`  ❌ 负对照「${mutation.name}」改坏后无法加载（${err && err.message}）`);
        selfTestOk = false;
        fs.rmSync(dir, { recursive: true, force: true });
        continue;
      }
      const mutated = runChecks(mutatedMod.HttpBodyCodec, after);
      console.log(`  · ${mutation.name} → 闸门判决 ${mutated.passed} passed, ${mutated.failed} failed`);
      if (mutated.failed <= 0) {
        console.log('    ❌ 负对照失败：闸门没抓住这一次改坏 —— 解码能力没被证明');
        selfTestOk = false;
      } else {
        console.log('    ✅ 被抓住');
        for (const line of mutated.lines.slice(0, 2)) {
          console.log(`      ${line}`);
        }
      }
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }

  fs.rmSync(staged.dir, { recursive: true, force: true });
  console.log('');
  const totalFailed = result.failed + (selfTestOk ? 0 : 1);
  console.log(`PASSED=${result.passed}  FAILED=${totalFailed}  TOTAL=${result.passed + totalFailed}`);
  console.log(totalFailed === 0 ? 'RESULT: HTTP BODY CODEC PASSED' : 'RESULT: HTTP BODY CODEC FAILED');
  process.exit(totalFailed === 0 ? 0 : 1);
}

main();
