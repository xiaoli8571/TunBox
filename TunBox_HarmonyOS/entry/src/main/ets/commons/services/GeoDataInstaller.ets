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
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'GeoDataInstaller';

/** 随包资源名 → 落盘文件名（mihomo homeDir 内的固定查找名） */
interface GeoAsset {
  raw: string;
  target: string;
}

const GEO_ASSETS: GeoAsset[] = [
  { raw: 'geoip.metadb', target: 'geoip.metadb' },
  { raw: 'geosite.dat', target: 'geosite.dat' }
];

export class GeoDataInstaller {
  /** 文件变化后重检；失败不记为成功，资源只在修复时读取。 */
  private static checked: Map<string, string> = new Map<string, string>();

  /**
   * 确保 geo 文件就位；按结构检查缺失/损坏文件，失败允许下次重试。
   */
  static ensure(context: common.Context): void {
    const dir = context.cacheDir;
    for (const asset of GEO_ASSETS) {
      const path = `${dir}/${asset.target}`;
      let temporary = '';
      try {
        if (GeoDataInstaller.fileOk(path, asset.target)) { continue; }
        let raw: Uint8Array | null = null;
        try {
          raw = context.resourceManager.getRawFileContentSync(asset.raw);
        } catch (e) {
          AppLogger.warn(TAG, `raw asset missing: ${asset.raw}`);
          continue;
        }
        if (raw === null || !GeoDataInstaller.bytesOk(raw, asset.target)) {
          continue;
        }
        temporary = `${path}.bundled-${util.generateRandomUUID(false)}.tmp`;
        const file = fs.openSync(temporary, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        let written = 0;
        try {
          // 资源可能是共享 ArrayBuffer 的视图，不能写入视图外的字节。
          written = fs.writeSync(file.fd, raw.slice().buffer as ArrayBuffer);
        } finally {
          fs.closeSync(file);
        }
        if (written !== raw.byteLength || !GeoDataInstaller.fileOk(temporary, asset.target)) {
          throw new Error('geo asset write incomplete');
        }
        // UI/扩展使用独立临时文件，完整写入后再原子替换，不截断正在使用的文件。
        fs.renameSync(temporary, path);
        GeoDataInstaller.checked.delete(temporary);
        temporary = '';
        GeoDataInstaller.checked.delete(path);
        AppLogger.info(TAG, `geo installed locally: ${asset.target} ${raw.length} bytes`);
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

  private static fileOk(path: string, name: string): boolean {
    let file: fs.File | null = null;
    try {
      const stat = fs.statSync(path);
      if (stat.size < 16 || stat.size > 128 * 1024 * 1024) { return false; }
      const stamp = `${stat.size}:${stat.mtime}:${stat.ino}`;
      if (GeoDataInstaller.checked.get(path) === stamp) { return true; }
      const length = name === 'geoip.metadb' ? Math.min(4096, stat.size) : stat.size;
      const buffer = new ArrayBuffer(length);
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const count = fs.readSync(file.fd, buffer, { offset: stat.size - length, length: length });
      if (count !== length || !GeoDataInstaller.bytesOk(new Uint8Array(buffer), name)) { return false; }
      GeoDataInstaller.checked.set(path, stamp);
      return true;
    } catch (e) {
      GeoDataInstaller.checked.delete(path);
      return false;
    } finally {
      if (file !== null) { try { fs.closeSync(file); } catch (e) { /* cleanup */ } }
    }
  }

  /** MMDB 尾部标记；GeoSite framing 对齐同源内核的 verifyGeodata。 */
  private static bytesOk(bytes: Uint8Array, name: string): boolean {
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
      if (bytes[offset++] !== 0x0A) { return false; }
      let length = 0;
      let complete = false;
      for (let shift = 0; shift < 35 && offset < bytes.length; shift += 7) {
        const value = bytes[offset++];
        length += (value & 0x7F) * Math.pow(2, shift);
        if ((value & 0x80) === 0) { complete = true; break; }
      }
      if (!complete || length <= 0 || length > bytes.length - offset) { return false; }
      offset += length;
      entries++;
    }
    return entries > 0;
  }
}
