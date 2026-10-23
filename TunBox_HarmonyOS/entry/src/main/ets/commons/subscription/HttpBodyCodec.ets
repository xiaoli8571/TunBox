/**
 * HTTP 正文编解码（Http Body Codec）：认得出「没标 Content-Encoding」的 gzip / zlib。
 *
 * ## 为什么要有它
 *
 * 部分机场的订阅响应是 **gzip / zlib 压缩流，却没有 `Content-Encoding` 头**。
 * FlClash 在 `lib/common/request.dart` 的 `decompressUnlabeled()`（132-148 行）里
 * 按魔数识别并解压后再交给内核；TunBox 一直没有等价实现，于是同一份订阅
 * 在 FlClash 能导入、在 TunBox 里被当成乱码正文 —— base64 / YAML 分派全落空，
 * 用户看到的就是「导入失败 / 0 节点」。
 *
 * ## 设备侧为什么不能直接用 @ohos.zlib
 *
 * `@ohos.zlib` 只提供**文件级** GZip（gzopen / gzread 要路径）和 zip 解包，
 * 拿不到内存 buffer 的 inflate。所以这里按 RFC1951（DEFLATE）+ RFC1952（gzip）
 * + RFC1950（zlib）**纯 TypeScript** 实现一遍：
 * 不 import 任何 `@kit.*` / `@ohos.*`（本文件没有任何 import），因此能直接在
 * Node 里跑闸门 `scripts/verify-http-body-codec.mjs`。
 *
 * ## 行为口径（与 FlClash 对齐 / 有意收紧的地方）
 *
 * - `looksCompressed()`：gzip 魔数 `1f 8b`；zlib 头 `0x78` 且
 *   `(CMF << 8 | FLG) % 31 === 0`。空 / 少于 2 字节 ⇒ false。
 * - `decompress()`：**不是压缩流 ⇒ 原样返回**（FlClash 同款行为 ——
 *   正文本来就没压缩时绝不能动它）；是压缩流 ⇒ 按魔数解压。
 * - **损坏的压缩流一律抛 Error**（绝不返回半截数据）。这一点比 FlClash 严格：
 *   FlClash 的 `decompressUnlabeled` 在 `FormatException` 时回退成原始字节，
 *   坏流会被当成正文继续解析、最后表现成「0 节点」；TunBox 让调用方能明确
 *   区分「不是压缩流」和「是压缩流但坏了」，错误信息里带可读原因
 *   （截断 / 距离越界 / Huffman 表非法 / 校验和不符 / 超过大小上限 / FDICT）。
 * - 解压输出上限 16 MiB（FlClash 侧下载限制 8 MiB 的 2 倍余量），防压缩炸弹。
 *
 * ## 实现要点
 *
 * - inflate 支持 stored(00) / fixed(01) / dynamic(10) 三种块、BFINAL 多块串联、
 *   最大回溯距离 32768（由距离码表保证）、`MAX_BITS = 15`；规范 Huffman 用
 *   zlib puff.c 那套 count[] / symbol[] 表逐位解码，代码自写（不是抄第三方源码）。
 * - gzip：校验 `1f 8b 08` 与 flags；FEXTRA（**little-endian** XLEN）、FNAME、
 *   FCOMMENT 逐段跳过，FHCRC 跳过 2 字节（头 CRC 不校验：头本身已被结构校验，
 *   数据完整性由尾部 CRC32 覆盖）；尾部校验 CRC32 + ISIZE。
 *   只支持单成员 gzip（订阅正文不会是多成员；多成员会因尾部 ISIZE/CRC 不符被拒）。
 * - zlib：校验 CMF/FLG 与 `CM = 8`、`CINFO <= 7`；FDICT 直接拒绝（订阅流不会用
 *   预置字典）；尾部校验 Adler-32。
 */

/** 解压输出硬上限（字节）：16 MiB，超出视为压缩炸弹 */
const MAX_OUTPUT_BYTES: number = 16 * 1024 * 1024;

/** RFC1951 §3.2.5：长度码 257..285 的基准长度 */
const LEN_BASE: Int32Array = new Int32Array([
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
]);

/** RFC1951 §3.2.5：长度码的附加位数 */
const LEN_EXTRA: Int32Array = new Int32Array([
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
]);

/** RFC1951 §3.2.5：距离码 0..29 的基准距离 */
const DIST_BASE: Int32Array = new Int32Array([
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
  8193, 12289, 16385, 24577,
]);

/** RFC1951 §3.2.5：距离码的附加位数 */
const DIST_EXTRA: Int32Array = new Int32Array([
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
]);

/**
 * 位读取器：**LSB 在前**逐位读（RFC1951 的位序）。
 *
 * 位缓冲最多攒到 20 位左右（单次最多读 13 位），`number` 足够；
 * 读越界一律抛错，绝不返回半截数据。
 */
class BitReader {
  private data: Uint8Array;
  private end: number;
  private pos: number;
  private bitBuf: number = 0;
  private bitCnt: number = 0;

  constructor(data: Uint8Array, start: number, end: number) {
    this.data = data;
    this.pos = start;
    this.end = end;
  }

  /** 读 need 位（0 <= need <= 16），返回无符号值 */
  bits(need: number): number {
    let value: number = this.bitBuf;
    while (this.bitCnt < need) {
      if (this.pos >= this.end) {
        throw new Error('inflate: 输入被截断（位流提前结束）');
      }
      value |= this.data[this.pos] << this.bitCnt;
      this.pos += 1;
      this.bitCnt += 8;
    }
    this.bitBuf = value >>> need;
    this.bitCnt -= need;
    return value & ((1 << need) - 1);
  }

  /** 丢弃当前字节内的剩余位（stored 块按字节对齐） */
  alignToByte(): void {
    this.bitBuf = 0;
    this.bitCnt = 0;
  }

  /** 读一个**已对齐**的字节（stored 块的 LEN/NLEN 与原始数据） */
  readAlignedByte(): number {
    if (this.bitCnt !== 0) {
      throw new Error('inflate: 内部错误（stored 块未按字节对齐）');
    }
    if (this.pos >= this.end) {
      throw new Error('inflate: 输入被截断（stored 块数据不足）');
    }
    const value: number = this.data[this.pos];
    this.pos += 1;
    return value;
  }
}

/**
 * 输出缓冲：按需翻倍扩容，但**永远不超过上限**。
 * 超限立即抛错（不是截断 —— 截断会让调用方拿到半份订阅）。
 */
class ByteSink {
  private buf: Uint8Array;
  private len: number = 0;
  private limit: number;

  constructor(limit: number) {
    this.limit = limit;
    let cap: number = 1024;
    if (cap > limit) {
      cap = limit;
    }
    this.buf = new Uint8Array(cap);
  }

  size(): number {
    return this.len;
  }

  private ensure(extra: number): void {
    const need: number = this.len + extra;
    if (need > this.limit) {
      throw new Error('inflate: 解压后超过 ' + (this.limit / (1024 * 1024)) + ' MiB 上限（疑似压缩炸弹）');
    }
    if (need <= this.buf.length) {
      return;
    }
    let cap: number = this.buf.length > 0 ? this.buf.length : 1024;
    while (cap < need) {
      cap *= 2;
    }
    if (cap > this.limit) {
      cap = this.limit;
    }
    const next = new Uint8Array(cap);
    for (let i = 0; i < this.len; i++) {
      next[i] = this.buf[i];
    }
    this.buf = next;
  }

  /** 追加一个字节（literal） */
  push(value: number): void {
    this.ensure(1);
    this.buf[this.len] = value & 0xff;
    this.len += 1;
  }

  /** LZ77 回溯拷贝；distance <= 已输出长度由调用方保证 */
  copyBack(distance: number, count: number): void {
    this.ensure(count);
    let src: number = this.len - distance;
    for (let i = 0; i < count; i++) {
      this.buf[this.len] = this.buf[src];
      this.len += 1;
      src += 1;
    }
  }

  /** 精确长度的副本（不把扩容余量漏给调用方） */
  toBytes(): Uint8Array {
    const out = new Uint8Array(this.len);
    for (let i = 0; i < this.len; i++) {
      out[i] = this.buf[i];
    }
    return out;
  }
}

/**
 * 规范 Huffman 表（puff.c 的表结构，自写实现）：
 * - `count[len]`：长度为 len 的码字个数；
 * - `symbol[]`：按 (码长, 符号值) 升序排好的符号表。
 */
class HuffmanTable {
  count: Int32Array;
  symbol: Int32Array;

  constructor(size: number) {
    this.count = new Int32Array(16);
    this.symbol = new Int32Array(size);
  }
}

/**
 * 由码长数组构建 Huffman 表。
 *
 * 校验规则（与 zlib 一致）：
 * - 过订阅（left < 0）⇒ 非法；
 * - 不完整（left > 0）只允许「整棵树只有一个长度 1 的符号」这一种特例，
 *   否则解码时必然踩到空码字 —— 直接判非法；
 * - 全零（count[0] === n）返回空表（距离树允许整棵为空，用到时再报错）。
 */
function buildHuffman(lengths: Int32Array, offset: number, size: number): HuffmanTable {
  const table = new HuffmanTable(size);
  for (let i = 0; i < size; i++) {
    const len: number = lengths[offset + i];
    if (len < 0 || len > 15) {
      throw new Error('inflate: Huffman 码长非法（' + len + '）');
    }
    table.count[len] += 1;
  }
  if (table.count[0] === size) {
    return table;
  }
  let left: number = 1;
  for (let len = 1; len <= 15; len++) {
    left = (left << 1) - table.count[len];
    if (left < 0) {
      throw new Error('inflate: Huffman 表过订阅（码长组合非法）');
    }
  }
  const singleCode: boolean = table.count[1] === 1 && table.count[0] === size - 1;
  if (left > 0 && !singleCode) {
    throw new Error('inflate: Huffman 表不完整（码字覆盖不全）');
  }
  // 每个码长的起始下标；同码长内按符号值升序填 symbol[]
  const offs = new Int32Array(16);
  for (let len = 1; len < 15; len++) {
    offs[len + 1] = offs[len] + table.count[len];
  }
  for (let i = 0; i < size; i++) {
    const len: number = lengths[offset + i];
    if (len !== 0) {
      table.symbol[offs[len]] = i;
      offs[len] += 1;
    }
  }
  return table;
}

/** 逐位解码一个符号（LSB 读入、码字 MSB 累积，即 RFC1951 的位序） */
function decodeSymbol(reader: BitReader, table: HuffmanTable): number {
  let code: number = 0;
  let first: number = 0;
  let index: number = 0;
  for (let len = 1; len <= 15; len++) {
    code |= reader.bits(1);
    const count: number = table.count[len];
    if (code - first < count) {
      return table.symbol[index + (code - first)];
    }
    index += count;
    first = (first + count) << 1;
    code <<= 1;
  }
  throw new Error('inflate: 非法 Huffman 编码（码字不在表内）');
}

/**
 * RFC1951 inflate。
 *
 * `start` / `end` 圈定 deflate 位流范围（gzip / zlib 的包装头尾由调用方剥掉），
 * `limit` 是解压输出上限。返回**精确长度**的新 `Uint8Array`。
 */
class Inflate {
  static inflate(data: Uint8Array, start: number, end: number, limit: number): Uint8Array {
    const reader = new BitReader(data, start, end);
    const sink = new ByteSink(limit);
    let finalBlock: number = 0;
    do {
      finalBlock = reader.bits(1);
      const type: number = reader.bits(2);
      if (type === 0) {
        Inflate.storedBlock(reader, sink);
      } else if (type === 1) {
        Inflate.fixedBlock(reader, sink);
      } else if (type === 2) {
        Inflate.dynamicBlock(reader, sink);
      } else {
        throw new Error('inflate: 非法块类型 3（RFC1951 未定义）');
      }
    } while (finalBlock === 0);
    return sink.toBytes();
  }

  /** stored 块（BTYPE=00）：先按字节对齐，再校验 LEN/NLEN，最后原样搬数据 */
  private static storedBlock(reader: BitReader, sink: ByteSink): void {
    reader.alignToByte();
    const len: number = reader.readAlignedByte() | (reader.readAlignedByte() << 8);
    const nlen: number = reader.readAlignedByte() | (reader.readAlignedByte() << 8);
    if ((len ^ 0xffff) !== nlen) {
      throw new Error('inflate: stored 块 LEN/NLEN 校验失败（LEN=' + len + ', NLEN=' + nlen + '）');
    }
    for (let i = 0; i < len; i++) {
      sink.push(reader.readAlignedByte());
    }
  }

  /** fixed 块（BTYPE=01）：RFC1951 §3.2.6 的固定码长 */
  private static fixedBlock(reader: BitReader, sink: ByteSink): void {
    const litLens = new Int32Array(288);
    for (let i = 0; i < 144; i++) {
      litLens[i] = 8;
    }
    for (let i = 144; i < 256; i++) {
      litLens[i] = 9;
    }
    for (let i = 256; i < 280; i++) {
      litLens[i] = 7;
    }
    for (let i = 280; i < 288; i++) {
      litLens[i] = 8;
    }
    const distLens = new Int32Array(32);
    for (let i = 0; i < 32; i++) {
      distLens[i] = 5;
    }
    Inflate.decodeCodes(reader, sink, buildHuffman(litLens, 0, 288), buildHuffman(distLens, 0, 32));
  }

  /** dynamic 块（BTYPE=10）：先读码长表，再读 literal/距离码长，最后解数据 */
  private static dynamicBlock(reader: BitReader, sink: ByteSink): void {
    const hlit: number = reader.bits(5) + 257;
    const hdist: number = reader.bits(5) + 1;
    const hclen: number = reader.bits(4) + 4;
    if (hlit > 286) {
      throw new Error('inflate: HLIT 超出上限（' + hlit + ' > 286）');
    }
    if (hdist > 30) {
      throw new Error('inflate: HDIST 超出上限（' + hdist + ' > 30）');
    }
    // 码长码的传输顺序（RFC1951 §3.2.7）
    const order: Int32Array = new Int32Array([
      16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
    ]);
    const clLens = new Int32Array(19);
    for (let i = 0; i < hclen; i++) {
      clLens[order[i]] = reader.bits(3);
    }
    const clTable: HuffmanTable = buildHuffman(clLens, 0, 19);

    const total: number = hlit + hdist;
    const lengths = new Int32Array(total);
    let index: number = 0;
    while (index < total) {
      const sym: number = decodeSymbol(reader, clTable);
      if (sym < 16) {
        lengths[index] = sym;
        index += 1;
      } else if (sym === 16) {
        if (index === 0) {
          throw new Error('inflate: 码长重复符号 16 前面没有可复制的码长');
        }
        const prev: number = lengths[index - 1];
        const repeat: number = reader.bits(2) + 3;
        if (index + repeat > total) {
          throw new Error('inflate: 码长重复次数越过数组末尾');
        }
        for (let i = 0; i < repeat; i++) {
          lengths[index] = prev;
          index += 1;
        }
      } else if (sym === 17) {
        const repeat: number = reader.bits(3) + 3;
        if (index + repeat > total) {
          throw new Error('inflate: 码长零填充次数越过数组末尾');
        }
        for (let i = 0; i < repeat; i++) {
          lengths[index] = 0;
          index += 1;
        }
      } else if (sym === 18) {
        const repeat: number = reader.bits(7) + 11;
        if (index + repeat > total) {
          throw new Error('inflate: 码长零填充次数越过数组末尾');
        }
        for (let i = 0; i < repeat; i++) {
          lengths[index] = 0;
          index += 1;
        }
      } else {
        throw new Error('inflate: 非法码长符号 ' + sym);
      }
    }
    // 没有块结束符 256 的 literal 树一定解不出边界 → 提前判非法
    if (lengths[256] === 0) {
      throw new Error('inflate: 动态块缺少块结束符 256');
    }
    const litTable: HuffmanTable = buildHuffman(lengths, 0, hlit);
    const distTable: HuffmanTable = buildHuffman(lengths, hlit, hdist);
    Inflate.decodeCodes(reader, sink, litTable, distTable);
  }

  /** 解 literal / length + distance，直到块结束符 256 */
  private static decodeCodes(reader: BitReader, sink: ByteSink, lit: HuffmanTable,
    dist: HuffmanTable): void {
    for (;;) {
      const sym: number = decodeSymbol(reader, lit);
      if (sym < 256) {
        sink.push(sym);
        continue;
      }
      if (sym === 256) {
        return;
      }
      const lenIndex: number = sym - 257;
      if (lenIndex < 0 || lenIndex >= 29) {
        throw new Error('inflate: 非法长度符号 ' + sym + '（286/287 保留）');
      }
      const length: number = LEN_BASE[lenIndex] + reader.bits(LEN_EXTRA[lenIndex]);
      const distSym: number = decodeSymbol(reader, dist);
      if (distSym >= 30) {
        throw new Error('inflate: 非法距离符号 ' + distSym + '（30/31 保留）');
      }
      const distance: number = DIST_BASE[distSym] + reader.bits(DIST_EXTRA[distSym]);
      if (distance > sink.size()) {
        throw new Error('inflate: 回溯距离越界（' + distance + ' > 已解压 ' + sink.size() + '）');
      }
      sink.copyBack(distance, length);
    }
  }
}

/** RFC1952 / RFC1950 的校验和（自写表，避免依赖任何 kit） */
class Checksums {
  /** CRC32 查表；长度 0 表示还没构建（ArkTS 不兴用可空类型，用哨兵代替） */
  private static crcTable: Int32Array = new Int32Array(0);

  /** gzip 尾部 CRC32（多项式 0xEDB88320，与 zlib crc32 一致） */
  static crc32(data: Uint8Array): number {
    if (Checksums.crcTable.length === 0) {
      Checksums.buildCrcTable();
    }
    let crc: number = 0xffffffff;
    for (let i = 0; i < data.length; i++) {
      crc = (crc >>> 8) ^ Checksums.crcTable[(crc ^ data[i]) & 0xff];
    }
    return (crc ^ 0xffffffff) >>> 0;
  }

  private static buildCrcTable(): void {
    const table = new Int32Array(256);
    for (let n = 0; n < 256; n++) {
      let c: number = n;
      for (let k = 0; k < 8; k++) {
        c = (c & 1) !== 0 ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[n] = c;
    }
    Checksums.crcTable = table;
  }

  /** zlib 尾部 Adler-32（RFC1950 §9），按 NMAX=5552 分块取模防溢出 */
  static adler32(data: Uint8Array): number {
    let a: number = 1;
    let b: number = 0;
    let i: number = 0;
    while (i < data.length) {
      const end: number = Math.min(i + 5552, data.length);
      while (i < end) {
        a += data[i];
        b += a;
        i += 1;
      }
      a %= 65521;
      b %= 65521;
    }
    return ((b << 16) | a) >>> 0;
  }
}

/**
 * HTTP 正文编解码入口。
 *
 * 调用方拿到订阅响应字节后：
 * ```
 * const raw = new Uint8Array(resp.result);           // httpRequest 给的是 ArrayBuffer
 * const body = HttpBodyCodec.decompress(raw);        // 原样或解压后的明文
 * ```
 * 不是压缩流时返回的**就是传入的那个对象**（零拷贝、零改写）。
 */
export class HttpBodyCodec {
  /**
   * 魔数识别：gzip（`1f 8b`）或 zlib（`0x78` 且 `(0x78 << 8 | b1) % 31 === 0`）。
   * 空 / 少于 2 字节 ⇒ false（FlClash 的 pattern match 同样要求至少 2 字节）。
   */
  static looksCompressed(bytes: Uint8Array): boolean {
    if (bytes.length < 2) {
      return false;
    }
    if (bytes[0] === 0x1f && bytes[1] === 0x8b) {
      return true;
    }
    return HttpBodyCodec.isZlibHeader(bytes[0], bytes[1]);
  }

  /**
   * 按魔数解压；不是压缩流 ⇒ 原样返回；是压缩流但损坏 ⇒ 抛 Error（带可读原因）。
   * 同步方法（调用方在 async 里直接调用即可）。
   */
  static decompress(bytes: Uint8Array): Uint8Array {
    if (!HttpBodyCodec.looksCompressed(bytes)) {
      return bytes;
    }
    // gzip 的魔数更具体，先判；zlib 只剩 0x78 一种可能
    if (bytes[0] === 0x1f && bytes[1] === 0x8b) {
      return HttpBodyCodec.inflateGzip(bytes, MAX_OUTPUT_BYTES);
    }
    return HttpBodyCodec.inflateZlib(bytes, MAX_OUTPUT_BYTES);
  }

  /** zlib 头判定（RFC1950 §2.2）：CMF=0x78 且 CMF/FLG 拼成的 16 位数能被 31 整除 */
  private static isZlibHeader(b0: number, b1: number): boolean {
    return b0 === 0x78 && ((b0 << 8 | b1) % 31) === 0;
  }

  /** 小端 32 位（gzip 的 MTIME / CRC32 / ISIZE 都是 little-endian） */
  private static readU32LE(bytes: Uint8Array, offset: number): number {
    return (bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16)
      | (bytes[offset + 3] << 24)) >>> 0;
  }

  /** 大端 32 位（zlib 的 Adler-32 是 big-endian） */
  private static readU32BE(bytes: Uint8Array, offset: number): number {
    return ((bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8)
      | bytes[offset + 3]) >>> 0;
  }

  /**
   * RFC1952 gzip。
   *
   * 头：`1f 8b 08 FLG MTIME(4) XFL OS`，随后按 FLG 依次是
   * FEXTRA（XLEN little-endian + 数据）/ FNAME（NUL 结尾）/ FCOMMENT（NUL 结尾）
   * / FHCRC（2 字节头 CRC）。尾部固定 8 字节：CRC32(4, LE) + ISIZE(4, LE)。
   */
  private static inflateGzip(bytes: Uint8Array, limit: number): Uint8Array {
    // 10 字节头 + 8 字节尾；再短就不是一个完整成员
    if (bytes.length < 18) {
      throw new Error('gzip: 数据过短（头部或尾部被截断）');
    }
    if (bytes[0] !== 0x1f || bytes[1] !== 0x8b) {
      throw new Error('gzip: 魔数不是 1f 8b');
    }
    if (bytes[2] !== 0x08) {
      throw new Error('gzip: 压缩方法不是 deflate（CM=' + bytes[2] + '）');
    }
    const flags: number = bytes[3];
    if ((flags & 0xe0) !== 0) {
      throw new Error('gzip: 头部保留位非 0（FLG=0x' + flags.toString(16) + '）');
    }
    // mtime(4) + xfl + os = 6 字节，跳过
    let pos: number = 10;
    if ((flags & 0x04) !== 0) {
      // FEXTRA：XLEN 是 little-endian（读反了会把 0x0104 当成 4 而错位）
      if (pos + 2 > bytes.length) {
        throw new Error('gzip: FEXTRA 长度字段被截断');
      }
      const xlen: number = bytes[pos] | (bytes[pos + 1] << 8);
      pos += 2;
      if (pos + xlen > bytes.length) {
        throw new Error('gzip: FEXTRA 内容被截断（声明 ' + xlen + ' 字节）');
      }
      pos += xlen;
    }
    if ((flags & 0x08) !== 0) {
      pos = HttpBodyCodec.skipZeroTerminated(bytes, pos, 'FNAME');
    }
    if ((flags & 0x10) !== 0) {
      pos = HttpBodyCodec.skipZeroTerminated(bytes, pos, 'FCOMMENT');
    }
    if ((flags & 0x02) !== 0) {
      // FHCRC：只跳过 2 字节。头 CRC（CRC16）只覆盖头部，而头部已经逐字段校验过；
      // 数据完整性由尾部 CRC32 负责，所以这里不校验头 CRC。
      if (pos + 2 > bytes.length) {
        throw new Error('gzip: FHCRC 字段被截断');
      }
      pos += 2;
    }
    const bodyEnd: number = bytes.length - 8;
    if (pos > bodyEnd) {
      throw new Error('gzip: 头部长度超过压缩数据范围');
    }
    const out: Uint8Array = Inflate.inflate(bytes, pos, bodyEnd, limit);
    // 尾部 CRC32 + ISIZE；只支持单成员 gzip（多成员 ISIZE 必然对不上，会被这里拒绝）
    const wantCrc: number = HttpBodyCodec.readU32LE(bytes, bytes.length - 8);
    const wantSize: number = HttpBodyCodec.readU32LE(bytes, bytes.length - 4);
    if (wantSize !== (out.length >>> 0)) {
      throw new Error('gzip: ISIZE 与解压长度不一致（尾部 ' + wantSize + '，实际 ' + out.length + '）');
    }
    const actualCrc: number = Checksums.crc32(out);
    if (actualCrc !== wantCrc) {
      throw new Error('gzip: CRC32 校验失败（数据被截断或损坏）');
    }
    return out;
  }

  /** 从 from 开始找一个 NUL 结尾的字符串字段，返回 NUL 之后的下标 */
  private static skipZeroTerminated(bytes: Uint8Array, from: number, label: string): number {
    let pos: number = from;
    while (pos < bytes.length && bytes[pos] !== 0) {
      pos += 1;
    }
    if (pos >= bytes.length) {
      throw new Error('gzip: ' + label + ' 没有 0 结尾（头部被截断）');
    }
    return pos + 1;
  }

  /**
   * RFC1950 zlib。
   *
   * 头 2 字节：CMF（CM 低 4 位、CINFO 高 4 位）+ FLG（FCHECK / FDICT / FLEVEL），
   * `(CMF << 8 | FLG) % 31 === 0`。FDICT 占 FLG bit5，其后还有 4 字节 DICTID；
   * 订阅流不会用预置字典 ⇒ 直接拒绝（也避免把 DICTID 当成 deflate 数据）。
   * 尾部固定 4 字节 Adler-32（大端）。
   */
  private static inflateZlib(bytes: Uint8Array, limit: number): Uint8Array {
    // 2 字节头 + 最少 2 字节 deflate + 4 字节 Adler-32
    if (bytes.length < 8) {
      throw new Error('zlib: 数据过短（头部或 Adler-32 被截断）');
    }
    const cmf: number = bytes[0];
    const flg: number = bytes[1];
    if ((cmf & 0x0f) !== 8) {
      throw new Error('zlib: 压缩方法不是 deflate（CM=' + (cmf & 0x0f) + '）');
    }
    if ((cmf >> 4) > 7) {
      throw new Error('zlib: 窗口大小非法（CINFO=' + (cmf >> 4) + '）');
    }
    if (((cmf << 8 | flg) % 31) !== 0) {
      throw new Error('zlib: CMF/FLG 校验失败（头部损坏）');
    }
    if ((flg & 0x20) !== 0) {
      throw new Error('zlib: 数据流声明了预置字典（FDICT），订阅正文不会用到，拒绝解压');
    }
    const bodyEnd: number = bytes.length - 4;
    const out: Uint8Array = Inflate.inflate(bytes, 2, bodyEnd, limit);
    const want: number = HttpBodyCodec.readU32BE(bytes, bytes.length - 4);
    const actual: number = Checksums.adler32(out);
    if (actual !== want) {
      throw new Error('zlib: Adler-32 校验失败（数据被截断或损坏）');
    }
    return out;
  }
}
