#!/usr/bin/env node
/**
 * 内置 geo 资产 gzip 化闸门（Bundled Geo Asset Gate）
 *
 * ## 为什么要有这个闸门
 *
 * hvigor 的 `--compress-level` **只作用于 `libs/`**：`BasePackHapTask.checkCompressNativeLib()`
 * 里带 `existsSync(modulePath/libs)` 前置条件，`resources/rawfile` 一律 STORED 进 zip。
 * 0.7.9 实测：未签名 HAP 里 `geoip.metadb`(9.20MB) + `geosite.dat`(4.23MB) 原样躺平，
 * 占包体 35%。这两个文件本身可压到 48.6% / 29.5%，所以 0.8.0 起 rawfile 改存 `.gz`，
 * 由 `GeoDataInstaller` 读进来先 inflate 再落盘。
 *
 * 这个闸门守三件事：
 *  1. **包内只有 `.gz`**：rawfile 目录里不能同时存在 `x` 和 `x.gz`（否则两份都进包，
 *     白占体积；而且回落逻辑会让 `.gz` 永远命中不到）。
 *  2. **`.gz` 解压后与记录在案的 SHA-256 一致**：防止有人手工 gzip 了错误的文件、
 *     或 gzip 时用了非 gzip 的流（zlib/raw deflate 魔数不同，HttpBodyCodec 认得出，
 *     但内核认不出坏 MMDB）。
 *  3. **`.gz` 真的是 gzip**：魔数 `1f 8b`（HttpBodyCodec.looksCompressed 的第一条分支），
 *     且解压后通过 GeoDataInstaller 同款结构校验（MMDB 尾部标记 / GeoSite framing）。
 *
 * ## 跑法
 *
 *   node scripts/verify-bundled-geo-assets.mjs
 *   node scripts/verify-bundled-geo-assets.mjs --self-test   （负对照：故意破坏样本）
 *
 * 未构建也可跑（只读 rawfile 源目录，不依赖 build/ 产物）。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROJ = path.resolve(HERE, '..');
const RAWFILE = path.join(PROJ, 'entry', 'src', 'main', 'resources', 'rawfile');

/**
 * 受管资产：包内 `.gz` 名 → 内核 homeDir 查找名 + 解压后 SHA-256。
 *
 * SHA-256 记录的是**解压后明文**（也就是落盘内容），与 gzip 的实现/级别无关：
 * 只要明文不变，重新用任何工具压一遍都不会让闸门失败。
 */
const ASSETS = [
  {
    packed: 'geoip.metadb.gz',
    target: 'geoip.metadb',
    // 明文 SHA-256（0.8.0 基线；换资产时必须同步更新这里）
    sha256: '7722ab3c5518a27de61f4d444528dbdf3d6067d1614b6c84c66b732fbf9021d7',
    kind: 'mmdb'
  },
  {
    packed: 'geosite.dat.gz',
    target: 'geosite.dat',
    sha256: '098b98841c252e4b0c83cfea9fae19a97b018e142070406f019f7343b9784ad5',
    kind: 'geosite'
  }
];

/** GeoDataInstaller.bytesOk 的 MMDB 分支：尾部 4KB 内必须有 MaxMind 标记 */
const MMDB_MARKER = Buffer.from([
  0xAB, 0xCD, 0xEF, 0x4D, 0x61, 0x78, 0x4D, 0x69, 0x6E, 0x64, 0x2E, 0x63, 0x6F, 0x6D
]);

function mmdbOk(buf) {
  const from = Math.max(0, buf.length - 4096);
  for (let i = buf.length - MMDB_MARKER.length; i >= from; i--) {
    if (buf.compare(MMDB_MARKER, 0, MMDB_MARKER.length, i, i + MMDB_MARKER.length) === 0) {
      return true;
    }
  }
  return false;
}

/** GeoDataInstaller.bytesOk 的 GeoSite 分支：0x0A + varint 长度 + 负载，逐条走完 */
function geositeOk(buf) {
  let offset = 0;
  let entries = 0;
  while (offset < buf.length) {
    if (buf[offset++] !== 0x0a) {
      return false;
    }
    let length = 0;
    let complete = false;
    for (let shift = 0; shift < 35 && offset < buf.length; shift += 7) {
      const value = buf[offset++];
      length += (value & 0x7f) * Math.pow(2, shift);
      if ((value & 0x80) === 0) {
        complete = true;
        break;
      }
    }
    if (!complete || length <= 0 || length > buf.length - offset) {
      return false;
    }
    offset += length;
    entries++;
  }
  return entries > 0;
}

function structureOk(buf, kind) {
  return kind === 'mmdb' ? mmdbOk(buf) : geositeOk(buf);
}

const results = [];
function check(name, fn) {
  try {
    fn();
    results.push({ name, ok: true });
    console.log(`PASS  ${name}`);
  } catch (e) {
    results.push({ name, ok: false, err: e.message });
    console.log(`FAIL  ${name}\n      ${e.message}`);
  }
}

function main() {
  console.log('== 内置 geo 资产闸门 ==');
  console.log(`rawfile: ${RAWFILE}`);

  // ── 1. 目录里不能残留同名明文（两份都进包 = 白占体积） ──
  for (const asset of ASSETS) {
    check(`无重复明文 ${asset.target}`, () => {
      const plain = path.join(RAWFILE, asset.target);
      assert.equal(fs.existsSync(plain), false,
        `${asset.target} 仍然存在于 rawfile —— 它会被原样 STORED 进包（+${asset.packed} 白占）。` +
        ` 只保留 ${asset.packed}，由 GeoDataInstaller 解压落盘。`);
    });
  }

  // ── 2. 每个 .gz 存在、是 gzip、解压后结构正确、SHA-256 对得上 ──
  let rawTotal = 0;
  let packedTotal = 0;
  for (const asset of ASSETS) {
    const p = path.join(RAWFILE, asset.packed);
    check(`${asset.packed} 存在`, () => {
      assert.ok(fs.existsSync(p), `缺少 ${asset.packed}`);
    });
    if (!fs.existsSync(p)) {
      continue;
    }
    const packed = fs.readFileSync(p);
    packedTotal += packed.length;

    check(`${asset.packed} 是 gzip（1f 8b）`, () => {
      assert.ok(packed.length > 18, `只有 ${packed.length} 字节，连 gzip 头+尾都不够`);
      assert.equal(packed[0], 0x1f, '魔数第 1 字节不是 0x1f');
      assert.equal(packed[1], 0x8b, '魔数第 2 字节不是 0x8b');
      assert.equal(packed[2], 0x08, '压缩方法不是 08(deflate)');
    });

    let plain = null;
    check(`${asset.packed} 能解压`, () => {
      plain = zlib.gunzipSync(packed);
      assert.ok(plain.length > 1024, `解压后只有 ${plain.length} 字节，明显不对`);
    });
    if (plain === null) {
      continue;
    }
    rawTotal += plain.length;

    check(`${asset.packed} 解压后结构合法（${asset.kind}）`, () => {
      assert.ok(structureOk(plain, asset.kind),
        `${asset.target} 结构校验失败 —— 内核会整份拒载。` +
        (asset.kind === 'mmdb' ? '（尾部 4KB 内找不到 MaxMind 标记）' : '（GeoSite framing 走不完）'));
    });

    const digest = crypto.createHash('sha256').update(plain).digest('hex');
    if (asset.sha256.startsWith('TBD_')) {
      console.log(`NOTE  ${asset.packed} 明文 SHA-256 = ${digest}  （请写入 ASSETS 表）`);
    } else {
      check(`${asset.packed} 明文 SHA-256 匹配基线`, () => {
        assert.equal(digest, asset.sha256,
          `明文哈希不符：实际 ${digest}，基线 ${asset.sha256}。` +
          ` 换资产是预期变更 ⇒ 同步更新本脚本 ASSETS 表；否则说明压错了文件。`);
      });
    }
  }

  // ── 3. 体积收益（信息性，不做断言 —— 换资产后比例会变） ──
  if (rawTotal > 0) {
    console.log('');
    console.log(`体积：明文合计 ${(rawTotal / 1048576).toFixed(2)} MB → ` +
      `gzip 合计 ${(packedTotal / 1048576).toFixed(2)} MB ` +
      `(省 ${((rawTotal - packedTotal) / 1048576).toFixed(2)} MB, ` +
      `压到 ${(packedTotal / rawTotal * 100).toFixed(1)}%)`);
  }

  // ── 4. 负对照：确认上面的校验真的会失败 ──
  if (process.argv.includes('--self-test')) {
    console.log('');
    console.log('== 负对照 ==');
    const good = zlib.gzipSync(Buffer.from([0x0a, 0x01, 0x41]));
    check('[负对照] 非 gzip 应被拒', () => {
      // 明文的 geosite 帧：没有 1f 8b 魔数
      const notGzip = Buffer.from([0x0a, 0x01, 0x41]);
      assert.throws(() => {
        assert.equal(notGzip[0], 0x1f, '明文首字节不是 0x1f ⇒ 应被 gzip 判定拒绝');
        assert.equal(notGzip[1], 0x8b);
      });
    });
    check('[负对照] 合法 gzip 应通过魔数判定', () => {
      assert.equal(good[0], 0x1f);
      assert.equal(good[1], 0x8b);
    });
    check('[负对照] 截断的 gzip 应解压失败', () => {
      const full = fs.readFileSync(path.join(RAWFILE, ASSETS[0].packed));
      const cut = full.subarray(0, Math.floor(full.length / 2));
      assert.throws(() => zlib.gunzipSync(cut));
    });
    check('[负对照] 坏 MMDB 应被结构校验拒绝', () => {
      assert.equal(mmdbOk(Buffer.alloc(8192, 0x00)), false);
    });
    check('[负对照] 坏 GeoSite 应被结构校验拒绝', () => {
      assert.equal(geositeOk(Buffer.from([0x00, 0x01, 0x41])), false);
    });
    check('[负对照] 合法 GeoSite 应通过', () => {
      assert.equal(geositeOk(Buffer.from([0x0a, 0x01, 0x41])), true);
    });
  }

  const failed = results.filter(r => !r.ok);
  console.log('');
  console.log(`PASSED=${results.length - failed.length}  FAILED=${failed.length}  TOTAL=${results.length}`);
  if (failed.length > 0) {
    console.log('RESULT: BUNDLED GEO ASSETS FAILED');
    process.exitCode = 1;
  } else {
    console.log('RESULT: BUNDLED GEO ASSETS PASSED');
  }
}

main();
