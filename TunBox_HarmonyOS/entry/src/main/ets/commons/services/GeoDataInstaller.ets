/**
 * GeoDataInstaller —— 内置 geo 数据安装器。
 *
 * 职责：
 *  · 把随包携带的 `geoip.metadb` / `geosite.dat` 复制到内核的工作目录
 *    （`cacheDir`，也就是 mihomo 的 homeDir），供内核在启动时直接加载。
 *
 * 来源与事实依据（2026-10-22 真机取证）：
 *  · 全新安装（或清了数据）的设备上 cacheDir 里没有 geo 文件，内核日志停在
 *    `Geodata Loader mode: memconservative` → `Can't find MMDB, start download`，
 *    随后联网下载 MMDB 卡死，20s 硬超时 → 测速核/隧道核都起不来。
 *  · 外在表现就是用户报的两个现象：导入订阅后点测速「立刻返回测速完成」
 *    （0 个测速目标），以及启动 VPN 直接报错（内核启动失败）。
 *  · FlClash 之所以没这个问题，是因为它的安装包自带 geo 数据并在启动时落盘。
 *
 * 关键口径：
 *  · 幂等：结构检查通过的文件保留；缺失、残缺或明显损坏的文件从包内修复。
 *  · 纯本地：不联网；临时文件写完整后原子替换，失败可在本进程内重试。
 *  · 文件名必须与 mihomo 的查找名一致：`geoip.metadb`（MMDB）与 `geosite.dat`。
 *
 * ── 2026-10-31：包内改存 gzip（0.8.0 起）────────────────────────────────
 * hvigor 的 `--compress-level` 只作用于 `libs/`（`checkCompressNativeLib()` 里有
 * `existsSync(modulePath/libs)` 前置条件），`resources/rawfile` 一律 **STORED**
 * 零压缩进包 —— 实测 0.7.9 的未签名 HAP 里 geoip.metadb(9.20MB) + geosite.dat
 * (4.23MB) 原样躺在 zip 里，占总包体 35%。这两个文件本身高度可压：
 *
 *   geoip.metadb  9.20MB → 4.47MB (48.6%)
 *   geosite.dat   4.23MB → 1.25MB (29.5%)
 *
 * 所以 rawfile 改存 `.gz`，安装时解压落盘。落盘后的文件名、内容、校验方式
 * **与之前完全一致**，内核侧（读 cacheDir 里的裸文件）无感。
 *
 * ── 2026-10-31 二次返工：解压必须走原生 zlib ────────────────────────────
 * 首版用 `HttpBodyCodec.decompress()`（纯 TS inflate）解压，真机实测
 * `geoip.metadb.gz 4685418 -> 9643689` 花了 **11s**、`geosite.dat.gz` 再 4s，
 * 合计 ~15s 全在主线程（全新安装没有 AOT 缓存，纯解释执行），直接触发
 * 「TunBox没有响应」ANR。`setTimeout` 只能让出宏任务，不能换线程。
 *
 * 现在改用 `@ohos.zlib` 的 GZip 流式接口（native C 解压）：
 *  · 4.7MB→9.6MB 实测百毫秒级，主线程同步 I/O 只剩 `getRawFileContentSync`
 *    与按 1MB 分块的 `writeSync`；
 *  · 解压流尾部带 CRC32/ISIZE 校验，**整体完整性由 gzip 自身保证**，
 *    因此本地的结构校验改为「有界探测」（见 `PROBE_BYTES`），不再为了
 *    结构校验把 9.6MB 全量读回主线程再逐条走 framing；
 *  · 仍然保留 `.gz` 读不到时回落到旧裸文件的兼容路径（升级 / 手工排障）。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'GeoDataInstaller';

/** 解压分块大小：一次 1MB，避免在内存里攒满整个明文 */
const INFLATE_CHUNK = 1024 * 1024;

/** 结构探测预算：geoip 读尾部 4KB 找 MMDB 标记，geosite 只走头部 256KB 的 framing */
const MMDB_TAIL_BYTES = 4096;
const GEOSITE_PROBE_BYTES = 256 * 1024;

/** 随包资源名 → 落盘文件名（mihomo homeDir 内的固定查找名） */
interface GeoAsset {
  /** 包内 gzip 资源名（主路径） */
  raw: string;
  /** 包内未压缩资源名（兼容回落，通常不存在） */
  legacyRaw: string;
  /** mihomo homeDir 内的固定查找名 */
  target: string;
}

const GEO_ASSETS: GeoAsset[] = [
  { raw: 'geoip.metadb.gz', legacyRaw: 'geoip.metadb', target: 'geoip.metadb' },
  { raw: 'geosite.dat.gz', legacyRaw: 'geosite.dat', target: 'geosite.dat' }
];

export class GeoDataInstaller {
  /** 文件变化后重检；失败不记为成功，资源只在修复时读取。 */
  private static checked: Map<string, string> = new Map<string, string>();

  /**
   * 确保 geo 文件就位；按结构检查缺失/损坏文件，失败允许下次重试。
   *
   * **异步**（解压走 native zlib 的 Promise 接口），主线程只承担两段小 I/O：
   * 读出包内 `.gz`（4.7MB）、按 1MB 分块落盘。真机实测整轮百毫秒级，
   * 已不再是启动阻塞点；即便如此仍建议走 `ensureDeferred()`，把 I/O 排到首帧之后。
   *
   * 返回值仅为「本进程是否已尽力」；判定 geo 是否真就位用 `isReady()`。
   */
  static async ensure(context: common.Context): Promise<void> {
    const dir = context.cacheDir;
    for (const asset of GEO_ASSETS) {
      const path = `${dir}/${asset.target}`;
      let temporary = '';
      try {
        if (GeoDataInstaller.fileOk(path, asset.target)) { continue; }
        temporary = `${path}.bundled-${util.generateRandomUUID(false)}.tmp`;
        const written = await GeoDataInstaller.materialize(context, asset, temporary);
        if (written <= 0) {
          // 资源缺失或解压失败：不动目标文件，下次 ensure 重试。
          AppLogger.warn(TAG, `skip install ${asset.target}: no usable bundled asset`);
          continue;
        }
        if (!GeoDataInstaller.fileOk(temporary, asset.target)) {
          throw new Error('geo asset write incomplete or corrupt');
        }
        // UI/扩展使用独立临时文件，完整写入后再原子替换，不截断正在使用的文件。
        fs.renameSync(temporary, path);
        GeoDataInstaller.checked.delete(temporary);
        temporary = '';
        const installed = fs.statSync(path);
        GeoDataInstaller.checked.set(path, `${installed.size}:${installed.mtime}:${installed.ino}`);
        AppLogger.info(TAG, `geo installed locally: ${asset.target} ${written} bytes`);
      } catch (e) {
        AppLogger.warn(TAG, `install ${asset.target} failed; next ensure retries: ${AppLogger.errText(e)}`);
      } finally {
        if (temporary.length > 0) {
          GeoDataInstaller.checked.delete(temporary);
          try { fs.unlinkSync(temporary); } catch (e) { /* may not exist */ }
        }
      }
    }
  }

  /** 供测试/排障：重置本进程标记 */
  static resetForTest(): void {
    GeoDataInstaller.checked.clear();
  }

  /**
   * 只检查、不安装：geo 文件是否已全部就位。
   *
   * 给 `VpnExtensionAbility` 这类**不能阻塞**的进程用：它起来时先问一句
   * 「geo 好了没」，好了就正常生成带 GEOIP 的配置，没好就直接降级
   * （`RuntimeConfigBuilder` 的 `useGeoip = profile.geoipReady` 会自动丢掉
   * GEOIP 规则），绝不在这里解压。
   *
   * 成本：每个文件一次 statSync + 有界探测读（geoip 尾部 4KB、geosite 头部
   * 256KB），命中后由 `checked` 缓存短路，同进程内只剩 stat。
   */
  static isReady(context: common.Context): boolean {
    const dir = context.cacheDir;
    for (const asset of GEO_ASSETS) {
      if (!GeoDataInstaller.fileOk(`${dir}/${asset.target}`, asset.target)) {
        return false;
      }
    }
    return true;
  }

  /**
   * 启动路径专用：把 `ensure()` 推迟到首帧之后。
   *
   * UI 首帧完全不需要 geo 数据，只有内核启动（点连接 / 自动重连）才需要；
   * 解压已改走 native zlib（见文件头），主线程开销很小，但仍然只让出一次宏任务
   * 就开始跑，避免和 `loadContent` / 首屏渲染抢同一帧的 I/O。
   *
   * 失败只记 warn：`ensure()` 幂等，下次冷启动或下次连接会再试。
   */
  static ensureDeferred(context: common.Context): void {
    setTimeout((): void => {
      GeoDataInstaller.ensure(context).catch((e: Error) => {
        AppLogger.warn(TAG, `deferred geo install failed: ${AppLogger.errText(e)}`);
      });
    }, 0);
  }

  /**
   * 把包内资源还原成内核要的裸文件，写到 `out`，返回写入字节数（0 表示放弃）。
   *
   * 顺序：`.gz`（主路径，native 解压）→ 旧裸文件（兼容）→ 0。
   * 解压失败一律放弃本次修复（而不是写半截数据）：坏文件比没文件更糟
   * （内核会整份拒载），目标文件保持原样、下次 ensure 重试。
   */
  private static async materialize(context: common.Context, asset: GeoAsset, out: string): Promise<number> {
    const packed = GeoDataInstaller.readRaw(context, asset.raw);
    if (packed !== null) {
      return await GeoDataInstaller.inflateTo(context, asset, packed, out);
    }
    const legacy = GeoDataInstaller.readRaw(context, asset.legacyRaw);
    if (legacy !== null) {
      AppLogger.info(TAG, `legacy uncompressed asset used: ${asset.legacyRaw} ${legacy.length} bytes`);
      GeoDataInstaller.writeAll(out, legacy);
      return legacy.length;
    }
    AppLogger.warn(TAG, `no bundled asset for ${asset.target} (tried ${asset.raw}, ${asset.legacyRaw})`);
    return 0;
  }

  /** 包内资源读出为字节；不存在返回 null（不抛，让调用方走回落分支）。 */
  private static readRaw(context: common.Context, name: string): Uint8Array | null {
    try {
      return context.resourceManager.getRawFileContentSync(name);
    } catch (e) {
      return null;
    }
  }

  /**
   * native zlib 流式解压到目标文件。
   *
   * `@ohos.zlib` 的 GZip 只接受**文件路径/文件描述符**，所以先把包内 `.gz` 落成临时文件
   * （4.7MB，一次 `writeSync`），再流式解压、1MB 分块落盘；临时 `.gz` 与半成品都在
   * `finally` 里清理。
   *
   * 2026-10-31 真机实测：`gzopen` + `gzfread` 报 `17800009 Internal structure error`
   * （36ms 内抛，两侧文件同时失败——非慢、非脏数据，是这条 native 路径在真机上不可用）。
   * 因无法从一句笼统报错判到底是 open 还是 read 炸，这里**逐组合尝试**并把每种组合
   * 的失败原因单独打进 hilog：
   *   combo0 = gzopen  + gzread      combo1 = gzopen  + gzfread
   *   combo2 = gzdopen + gzread      combo3 = gzdopen + gzfread
   * 只要组合能跑通就用它；全失败则不落盘任何半成品，保留原文件等下轮重试。
   */
  private static async inflateTo(context: common.Context, asset: GeoAsset, packed: Uint8Array,
    out: string): Promise<number> {
    const staging = `${out}.gz`;
    try {
      GeoDataInstaller.writeAll(staging, packed);
    } catch (e) {
      AppLogger.warn(TAG, `stage ${asset.raw} failed: ${AppLogger.errText(e)}`);
      try { fs.unlinkSync(staging); } catch (err) { /* may not exist */ }
      return 0;
    }
    try {
      for (let combo = 0; combo < 4; combo++) {
        const useDopen = (combo & 2) !== 0;
        const useRead = (combo & 1) === 0;
        const total = await GeoDataInstaller.streamOut(out, staging, useDopen, useRead);
        if (total > 0) {
          AppLogger.info(TAG, `asset inflated: ${asset.raw} ${packed.length} -> ${total} bytes` +
            ` (${useDopen ? 'gzdopen' : 'gzopen'}+${useRead ? 'gzread' : 'gzfread'})`);
          return total;
        }
      }
      AppLogger.warn(TAG, `inflate ${asset.raw}: every gzip read path failed; keeping existing file`);
      return 0;
    } finally {
      try { fs.unlinkSync(staging); } catch (e) { /* may not exist */ }
    }
  }

  /**
   * 单条解压通道：`useDopen` 选 gzdopen(fd) / gzopen(path)，`useRead` 选 gzread / gzfread。
   *
   * 返回写入明文字节数；任何一步失败都只记日志并返回 0（由 `inflateTo` 换下一条通道），
   * 并在失败时删掉写了一半的临时目标，**绝不让半成品被 rename 成正式文件**。
   *
   * 读到的**负数**必须当错（`gzfread` 只用负表示错流，0 才是 EOF）：否则 CRC32 不匹配的
   * 截断流会被静默接受，而 geosite 的头部探测照样能通过，坏文件就成了好文件。
   */
  private static async streamOut(out: string, staging: string, useDopen: boolean,
    useRead: boolean): Promise<number> {
    const label = `${useDopen ? 'gzdopen' : 'gzopen'}+${useRead ? 'gzread' : 'gzfread'}`;
    let gz: zlib.GZip | null = null;
    let opened = false;
    let target: fs.File | null = null;
    let source: fs.File | null = null;
    let total = 0;
    try {
      gz = zlib.createGZipSync();
      if (useDopen) {
        source = fs.openSync(staging, fs.OpenMode.READ_ONLY);
        await gz.gzdopen(source.fd, 'rb');
        // gzdopen 接管 fd（zlib 语义：由 gzclose 关闭），本进程不再重复 close。
        source = null;
      } else {
        await gz.gzopen(staging, 'r');
      }
      opened = true;
      target = fs.openSync(out, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const chunk = new ArrayBuffer(INFLATE_CHUNK);
      for (;;) {
        const read = useRead ? await gz.gzread(chunk) : await gz.gzfread(chunk, 1, INFLATE_CHUNK);
        if (read < 0) { throw new Error(`gzip stream error ${read}`); }
        if (read === 0) { break; }
        // 两个读入口都从 chunk 起始处填，slice 出本次有效长度再写。
        const count = fs.writeSync(target.fd, chunk.slice(0, read));
        if (count !== read) { throw new Error(`geo asset short write ${count}/${read}`); }
        total += read;
      }
      // 循环正常走到 EOF 才说明 zlib 已校完 CRC32/ISIZE（错流在 read 就抛了）。
      if (total < 16) { throw new Error('geo asset inflate produced empty output'); }
      return total;
    } catch (e) {
      AppLogger.warn(TAG, `${label} unusable: ${AppLogger.errText(e)}`);
      return 0;
    } finally {
      if (target !== null) { try { fs.closeSync(target); } catch (e) { /* already closed */ } }
      if (source !== null) { try { fs.closeSync(source); } catch (e) { /* already closed */ } }
      if (gz !== null && opened) { try { await gz.gzclose(); } catch (e) { /* already closed */ } }
      if (total === 0) { try { fs.unlinkSync(out); } catch (e) { /* may not exist */ } }
    }
  }

  /** 整块写文件（临时件，失败即抛；调用方负责清理）。 */
  private static writeAll(path: string, bytes: Uint8Array): void {
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      // 资源可能是共享 ArrayBuffer 的视图，不能写入视图外的字节。
      const written = fs.writeSync(file.fd, bytes.slice().buffer as ArrayBuffer);
      if (written !== bytes.length) { throw new Error(`geo asset short write ${written}/${bytes.length}`); }
    } finally {
      fs.closeSync(file);
    }
  }

  private static fileOk(path: string, name: string): boolean {
    let file: fs.File | null = null;
    try {
      const stat = fs.statSync(path);
      if (stat.size < 16 || stat.size > 128 * 1024 * 1024) { return false; }
      const stamp = `${stat.size}:${stat.mtime}:${stat.ino}`;
      if (GeoDataInstaller.checked.get(path) === stamp) { return true; }
      const budget = name === 'geoip.metadb' ? MMDB_TAIL_BYTES : GEOSITE_PROBE_BYTES;
      const length = Math.min(budget, stat.size);
      const offset = name === 'geoip.metadb' ? stat.size - length : 0;
      const buffer = new ArrayBuffer(length);
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const count = fs.readSync(file.fd, buffer, { offset: offset, length: length });
      if (count !== length || !GeoDataInstaller.bytesOk(new Uint8Array(buffer, 0, count), name,
        length === stat.size)) {
        return false;
      }
      GeoDataInstaller.checked.set(path, stamp);
      return true;
    } catch (e) {
      GeoDataInstaller.checked.delete(path);
      return false;
    } finally {
      if (file !== null) { try { fs.closeSync(file); } catch (e) { /* cleanup */ } }
    }
  }

  /**
   * 结构探测（不追求全量校验：全量完整性由 gzip 的 CRC32/ISIZE 保证）。
   *
   * · MMDB：尾部 4KB 内必须出现 MaxMind 标记；
   * · GeoSite：`0x0A + varint 长度 + 负载` 的 framing，从头部逐条走；
   *   `wholeFile=true`（读到整个文件）时要求刚好走到结尾（截断即坏），
   *   `wholeFile=false`（只探头部预算）时允许最后一条被预算截断。
   */
  private static bytesOk(bytes: Uint8Array, name: string, wholeFile: boolean): boolean {
    if (name === 'geoip.metadb') {
      const marker: number[] = [0xAB, 0xCD, 0xEF, 0x4D, 0x61, 0x78, 0x4D, 0x69, 0x6E,
        0x64, 0x2E, 0x63, 0x6F, 0x6D];
      for (let i = bytes.length - marker.length; i >= Math.max(0, bytes.length - 4096); i--) {
        let hit = true;
        for (let j = 0; j < marker.length; j++) {
          if (bytes[i + j] !== marker[j]) { hit = false; break; }
        }
        if (hit) { return true; }
      }
      return false;
    }
    let offset = 0;
    let entries = 0;
    while (offset < bytes.length) {
      if (bytes[offset] !== 0x0A) {
        return false;
      }
      offset++;
      let length = 0;
      let varintDone = false;
      for (let shift = 0; shift < 35 && offset < bytes.length; shift += 7) {
        const value = bytes[offset++];
        length += (value & 0x7F) * Math.pow(2, shift);
        if ((value & 0x80) === 0) { varintDone = true; break; }
      }
      if (!varintDone || length <= 0) { return false; }
      if (length > bytes.length - offset) {
        // 整文件模式下这就是截断（坏文件）；预算探测模式下属于正常截止，
        // 只要前面已走通至少一条 framing 即可放行。
        return !wholeFile && entries > 0;
      }
      offset += length;
      entries++;
    }
    return entries > 0;
  }
}
