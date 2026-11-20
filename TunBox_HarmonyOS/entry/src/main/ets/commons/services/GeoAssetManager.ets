/**
 * Geo / LightGBM / Rule-Set asset lifecycle manager.
 *
 * Handles magic-byte validation, mirror reordering, atomic downloads, rawfile
 * seeding, last-good snapshot/quarantine healing, status inspection, and deletion
 * for geoip.metadb, Model.bin, and hyper_adrules_ads.mrs.
 */
import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { ensurePrivateDir, privateFs } from './PrivateFileStore';
import { AppProxyRoute } from './AppProxyRoute';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'GeoAssetManager';

/** Internal kernel ruleset subdirectory under cacheDir. */
export const RULESET_SUBDIR = 'ruleset';
/** Ad-block rule-provider binary file name. */
export const HYPER_AD_RULES_FILE = 'hyper_adrules_ads.mrs';
/** Minimum valid size for .mrs binaries; rejects empty files and tiny stubs. */
export const RULE_SET_MIN_BYTES = 1024;
/** zstd frame header magic checked on every downloaded or seeded .mrs file. */
export const ZSTD_MAGIC: number[] = [0x28, 0xB5, 0x2F, 0xFD];
/** Backup suffix holding the last kernel-verified ruleset binary. */
export const RULE_SET_GOOD_SUFFIX = '.good';
/** Bundled offline fallback ruleset shipped in rawfile/. */
export const BUNDLED_RULE_SET_RAWFILE = 'hyper_adrules_ads.mrs';

const MODEL_MAGIC: number[] = [0x74, 0x72, 0x65, 0x65]; // "tree"
const MMDB_TAIL_MARKER: number[] = [
  0xAB, 0xCD, 0xEF, 0x4D, 0x61, 0x78, 0x4D, 0x69, 0x6E, 0x64, 0x2E, 0x63, 0x6F, 0x6D
];

export type AssetDownloadFn = (mirrors: AssetMirror[], destPath: string, minSize: number,
  validate: (buf: ArrayBuffer) => boolean, source: string, what: string) => Promise<boolean>;

/** Mirror endpoint paired with a CDN/proxy source tag for preference sorting. */
export class AssetMirror {
  url: string = '';
  tag: string = 'auto';

  constructor(url: string, tag: string) {
    this.url = url;
    this.tag = tag;
  }
}

export const GEOIP_MIRRORS: AssetMirror[] = [
  new AssetMirror('https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb', 'jsdelivr'),
  new AssetMirror('https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb', 'jsdelivr'),
  new AssetMirror('https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb', 'jsdelivr'),
  new AssetMirror('https://gh-proxy.com/https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geoip.metadb', 'ghproxy'),
  new AssetMirror('https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/release/geoip.metadb', 'github')
];

export const MODEL_MIRRORS: AssetMirror[] = [
  new AssetMirror('https://gh-proxy.com/https://github.com/vernesong/mihomo/releases/download/LightGBM-Model/Model.bin', 'ghproxy'),
  new AssetMirror('https://ghproxy.net/https://github.com/vernesong/mihomo/releases/download/LightGBM-Model/Model.bin', 'ghproxy'),
  new AssetMirror('https://github.com/vernesong/mihomo/releases/download/LightGBM-Model/Model.bin', 'github')
];

export const HYPER_AD_RULES_MIRRORS: AssetMirror[] = [
  new AssetMirror('https://github.com/Lynricsy/HyperADRules/releases/latest/download/hyper_adrules_ads.mrs', 'github'),
  new AssetMirror('https://gh-proxy.com/https://github.com/Lynricsy/HyperADRules/releases/latest/download/hyper_adrules_ads.mrs', 'ghproxy'),
  new AssetMirror('https://ghfast.top/https://github.com/Lynricsy/HyperADRules/releases/latest/download/hyper_adrules_ads.mrs', 'ghproxy')
];

/** Settings page snapshot describing local asset readiness and disk metadata. */
export class GeoAssetStatus {
  id: string = '';
  label: string = '';
  detail: string = '';
  ready: boolean = false;
  sizeBytes: number = 0;
  mtimeMs: number = 0;
}

/** Reorder candidate mirrors so the preferred source tag is tried first. */
export function reorderAssetMirrors(mirrors: AssetMirror[], source: string): AssetMirror[] {
  if (source !== 'jsdelivr' && source !== 'ghproxy' && source !== 'github') {
    return mirrors.slice();
  }
  const preferred = mirrors.filter((m: AssetMirror): boolean => m.tag === source);
  const rest = mirrors.filter((m: AssetMirror): boolean => m.tag !== source);
  return preferred.concat(rest);
}

function removeFileQuiet(path: string): void {
  try {
    fs.unlinkSync(path);
  } catch (_e) {
    // Missing file is normal during deletion/cleanup.
  }
}

function readHeaderIfValidSize(path: string, minSize: number, magicLen: number): ArrayBuffer | null {
  let file: fs.File | null = null;
  try {
    const size = Number(fs.statSync(path).size);
    if (!(size >= minSize)) {
      return null;
    }
    file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    const head = new ArrayBuffer(magicLen);
    const read = fs.readSync(file.fd, head);
    return read >= magicLen ? head : null;
  } catch (_e) {
    return null;
  } finally {
    if (file !== null) {
      try {
        fs.closeSync(file);
      } catch (_e) {
        // ignore close errors on readonly fd
      }
    }
  }
}

/** Manages GeoIP, LightGBM model, and ad-block rule-provider files under cacheDir. */
export class GeoAssetManager {
  geoipDownloading: boolean = false;
  smartModelDownloading: boolean = false;
  private ruleProviderDownloadTask: Promise<boolean> | null = null;

  /** Check leading magic bytes of an asset buffer or file header. */
  static bufferMagicOk(buf: ArrayBuffer, magic: number[]): boolean {
    if (buf.byteLength < magic.length) {
      return false;
    }
    const head = new Uint8Array(buf, 0, magic.length);
    for (let i = 0; i < magic.length; i++) {
      if (head[i] !== magic[i]) {
        return false;
      }
    }
    return true;
  }

  /** Search the trailing MMDB metadata marker near the end of geoip.metadb. */
  static bufferTailMagicOk(buf: ArrayBuffer): boolean {
    const b = new Uint8Array(buf);
    if (b.byteLength < MMDB_TAIL_MARKER.length) {
      return false;
    }
    for (let i = b.byteLength - MMDB_TAIL_MARKER.length; i >= 0; i--) {
      let hit = true;
      for (let j = 0; j < MMDB_TAIL_MARKER.length; j++) {
        if (b[i + j] !== MMDB_TAIL_MARKER[j]) {
          hit = false;
          break;
        }
      }
      if (hit) {
        return true;
      }
    }
    return false;
  }

  /** Atomic multi-mirror asset download with size and content validation before replace. */
  static async downloadAsset(mirrors: AssetMirror[], destPath: string, minSize: number,
    validate: (buf: ArrayBuffer) => boolean, source: string, what: string): Promise<boolean> {
    const ordered = reorderAssetMirrors(mirrors, source);
    const maxSize = 64 * 1024 * 1024;
    let idx = 0;
    for (const mirror of ordered) {
      const tempPath = `${destPath}.download-${Date.now()}-${idx}.tmp`;
      const client = http.createHttp();
      try {
        const resp = await client.request(mirror.url, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: 15000,
          usingProxy: AppProxyRoute.isReady(),
          readTimeout: what === 'Model.bin' ? 300000 : 90000,
          maxLimit: maxSize
        });
        const buf = resp.result as ArrayBuffer;
        if (resp.responseCode === 200 && buf instanceof ArrayBuffer
          && buf.byteLength > minSize && buf.byteLength <= maxSize && validate(buf)) {
          const file = fs.openSync(tempPath,
            fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          try {
            const written = fs.writeSync(file.fd, buf);
            if (written !== buf.byteLength) { throw new Error('short asset write'); }
            fs.fsyncSync(file.fd);
          } finally {
            fs.closeSync(file);
          }
          fs.renameSync(tempPath, destPath);
          AppLogger.info(TAG, `${what} downloaded (${buf.byteLength} bytes, source=${mirror.tag})`);
          return true;
        }
        AppLogger.warn(TAG, `${what} mirror ${idx}(${mirror.tag}) returned ${resp.responseCode}, size ${buf.byteLength}`);
      } catch (e) {
        AppLogger.warn(TAG, `${what} mirror ${idx}(${mirror.tag}) failed: ${e}`);
      } finally {
        client.destroy();
        removeFileQuiet(tempPath);
      }
      idx = idx + 1;
    }
    return false;
  }

  /** Whether cacheDir/geoip.metadb exists with sufficient size and tail MMDB marker. */
  static isGeoipReady(context: Context | null): boolean {
    if (context === null) {
      return false;
    }
    const path = `${context.cacheDir}/geoip.metadb`;
    let file: fs.File | null = null;
    try {
      const size = fs.statSync(path).size;
      if (size < 1024 * 100) {
        return false;
      }
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const readLen = Math.min(4096, size);
      const tail = new ArrayBuffer(readLen);
      const got = fs.readSync(file.fd, tail, { offset: size - readLen, length: readLen });
      return got >= readLen && GeoAssetManager.bufferTailMagicOk(tail);
    } catch (_e) {
      return false;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (_e) {
          // ignore
        }
      }
    }
  }

  /** Whether LightGBM Model.bin was manually installed and passes header verification. */
  static isSmartModelReady(context: Context | null): boolean {
    if (context === null) {
      return false;
    }
    const path = `${context.cacheDir}/Model.bin`;
    try {
      if (!fs.accessSync(`${path}.manual`)) { return false; }
      const head = readHeaderIfValidSize(path, 1024 * 1024, MODEL_MAGIC.length);
      return head !== null && GeoAssetManager.bufferMagicOk(head, MODEL_MAGIC);
    } catch (_e) {
      return false;
    }
  }

  /** Ensure bundled ad-block ruleset is materialized into cacheDir/ruleset when missing/corrupt. */
  static seedRuleSetFromRawfile(context: Context | null): boolean {
    if (context === null) {
      return false;
    }
    if (GeoAssetManager.ruleSetFileOk(context)) {
      return true;
    }
    const dir = `${context.cacheDir}/${RULESET_SUBDIR}`;
    const dst = `${dir}/${HYPER_AD_RULES_FILE}`;
    let file: fs.File | null = null;
    try {
      try {
        ensurePrivateDir(dir);
      } catch (e) {
        AppLogger.warn(TAG, `ruleset dir create failed: ${AppLogger.errText(e)}`);
      }
      const bytes: Uint8Array = context.resourceManager.getRawFileContentSync(BUNDLED_RULE_SET_RAWFILE);
      if (bytes.byteLength < RULE_SET_MIN_BYTES) {
        AppLogger.warn(TAG, `bundled ruleset too small (${bytes.byteLength} bytes); ignoring`);
        return false;
      }
      const head = bytes.slice(0, ZSTD_MAGIC.length).buffer as ArrayBuffer;
      if (!GeoAssetManager.bufferMagicOk(head, ZSTD_MAGIC)) {
        AppLogger.warn(TAG, 'bundled ruleset has wrong magic; ignoring');
        return false;
      }
      file = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      const ab: ArrayBuffer = (bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength)
        ? bytes.buffer as ArrayBuffer
        : bytes.slice().buffer as ArrayBuffer;
      fs.writeSync(file.fd, ab);
      AppLogger.info(TAG, `ad ruleset seeded from bundle (${bytes.byteLength} bytes); ad-block ready offline`);
      return true;
    } catch (e) {
      AppLogger.warn(TAG, `seed ad ruleset from bundle failed: ${AppLogger.errText(e)}`);
      return false;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (_e) {
          // ignore
        }
      }
    }
  }

  static ruleSetFileExists(context: Context | null): boolean {
    if (context === null) {
      return false;
    }
    try {
      fs.statSync(`${context.cacheDir}/${RULESET_SUBDIR}/${HYPER_AD_RULES_FILE}`);
      return true;
    } catch (_e) {
      return false;
    }
  }

  static ruleSetFileOk(context: Context | null): boolean {
    if (context === null) {
      return false;
    }
    const p = `${context.cacheDir}/${RULESET_SUBDIR}/${HYPER_AD_RULES_FILE}`;
    const head = readHeaderIfValidSize(p, RULE_SET_MIN_BYTES, ZSTD_MAGIC.length);
    return head !== null && GeoAssetManager.bufferMagicOk(head, ZSTD_MAGIC);
  }

  static isRuleProviderReady(context: Context | null): boolean {
    GeoAssetManager.seedRuleSetFromRawfile(context);
    return GeoAssetManager.ruleSetFileOk(context);
  }

  static looksLikeRuleSetFailure(context: Context | null, errorText: string): boolean {
    if (errorText.length === 0) {
      return false;
    }
    const t = errorText.toLowerCase();
    if (t.indexOf('mrs') >= 0 || t.indexOf('rule-provider') >= 0
      || t.indexOf('rule provider') >= 0 || t.indexOf('ruleset') >= 0
      || t.indexOf('rule-set') >= 0 || t.indexOf('invalid behavior') >= 0
      || t.indexOf('zstd') >= 0 || t.indexOf('unexpected eof') >= 0) {
      return GeoAssetManager.ruleSetFileExists(context);
    }
    return false;
  }

  /** Restore last-good ruleset copy if available, otherwise quarantine the corrupted file. */
  static healRuleSet(context: Context | null, reason: string): string {
    if (context === null) {
      return '';
    }
    const p = `${context.cacheDir}/${RULESET_SUBDIR}/${HYPER_AD_RULES_FILE}`;
    const good = `${p}${RULE_SET_GOOD_SUFFIX}`;
    try {
      const goodSize = Number(fs.statSync(good).size);
      if (goodSize >= RULE_SET_MIN_BYTES) {
        fs.renameSync(good, p);
        AppLogger.warn(TAG, `ad ruleset restored from last-good copy (${reason}, ${goodSize} bytes)`);
        return 'restored';
      }
    } catch (_e) {
      // Fall through to quarantine when no valid last-good snapshot exists.
    }
    try {
      fs.renameSync(p, `${p}.bad-${Date.now()}`);
      AppLogger.warn(TAG, `ad ruleset quarantined (${reason}); next connect runs without RULE-SET`);
      return 'quarantined';
    } catch (e) {
      AppLogger.warn(TAG, `ad ruleset quarantine failed: ${AppLogger.errText(e)}`);
      return '';
    }
  }

  /** Save a verified last-good backup of the active ruleset after tunnel startup succeeds. */
  static snapshotRuleSetGood(context: Context | null): void {
    if (context === null || !GeoAssetManager.ruleSetFileOk(context)) {
      return;
    }
    const p = `${context.cacheDir}/${RULESET_SUBDIR}/${HYPER_AD_RULES_FILE}`;
    const tmp = `${p}${RULE_SET_GOOD_SUFFIX}.tmp`;
    try {
      fs.copyFileSync(p, tmp);
      fs.renameSync(tmp, `${p}${RULE_SET_GOOD_SUFFIX}`);
    } catch (e) {
      AppLogger.warn(TAG, `ad ruleset last-good snapshot failed: ${AppLogger.errText(e)}`);
    }
  }

  /** Return settings-page status cards for GeoIP and Smart LightGBM model files. */
  static geoAssetStatuses(context: Context | null): GeoAssetStatus[] {
    const out: GeoAssetStatus[] = [];
    const stat = (relPath: string): number[] => {
      if (context === null) {
        return [-1, 0];
      }
      try {
        const s = fs.statSync(`${context.cacheDir}/${relPath}`);
        return [Number(s.size), Number(s.mtime) * 1000];
      } catch (_e) {
        return [-1, 0];
      }
    };
    const item = (id: string, label: string, detail: string, info: number[],
      ready: boolean): GeoAssetStatus => {
      const g = new GeoAssetStatus();
      g.id = id;
      g.label = label;
      g.detail = detail;
      g.sizeBytes = info[0] < 0 ? 0 : info[0];
      g.mtimeMs = info[1];
      g.ready = ready;
      return g;
    };
    out.push(item('geoip', 'GeoIP 数据库', 'GEOIP,CN 直连分流与 DNS fallback 依赖',
      stat('geoip.metadb'), GeoAssetManager.isGeoipReady(context)));
    out.push(item('model', 'Smart 选点模型', 'LightGBM 自动选点依赖（需手动更新）',
      stat('Model.bin'), GeoAssetManager.isSmartModelReady(context)));
    return out;
  }

  /** Remove downloaded LightGBM model and its manual-install marker. */
  static deleteModel(context: Context): void {
    const path = `${context.cacheDir}/Model.bin`;
    if (fs.accessSync(path)) { fs.unlinkSync(path); }
    if (fs.accessSync(`${path}.manual`)) { fs.unlinkSync(`${path}.manual`); }
  }

  /** Remove downloaded/seeded ruleset and its last-good copy so recovery cannot resurrect it. */
  static deleteRuleset(context: Context): void {
    const path = `${context.cacheDir}/${RULESET_SUBDIR}/${HYPER_AD_RULES_FILE}`;
    removeFileQuiet(`${path}${RULE_SET_GOOD_SUFFIX}`);
    removeFileQuiet(path);
  }

  async downloadGeoipAsset(context: Context | null, source: string,
    transport: AssetDownloadFn = GeoAssetManager.downloadAsset): Promise<boolean> {
    if (this.geoipDownloading || context === null) {
      return false;
    }
    this.geoipDownloading = true;
    try {
      const dest = `${context.cacheDir}/geoip.metadb`;
      return await transport(GEOIP_MIRRORS, dest, 1024 * 1024 * 4,
        (buf: ArrayBuffer): boolean => GeoAssetManager.bufferTailMagicOk(buf),
        source, 'geoip.metadb');
    } finally {
      this.geoipDownloading = false;
    }
  }

  async downloadSmartModelAsset(context: Context | null, source: string,
    transport: AssetDownloadFn = GeoAssetManager.downloadAsset): Promise<boolean> {
    if (this.smartModelDownloading || context === null) {
      return false;
    }
    this.smartModelDownloading = true;
    try {
      const dest = `${context.cacheDir}/Model.bin`;
      const ok = await transport(MODEL_MIRRORS, dest, 1024 * 1024,
        (buf: ArrayBuffer): boolean => GeoAssetManager.bufferMagicOk(buf, MODEL_MAGIC),
        source, 'Model.bin');
      if (ok) { privateFs.writePrivate(`${dest}.manual`, 'manual-v1'); }
      return ok && GeoAssetManager.isSmartModelReady(context);
    } finally {
      this.smartModelDownloading = false;
    }
  }

  /** Coalesce concurrent ad-rule downloads into one shared in-flight promise. */
  async downloadRuleProviderAsset(context: Context | null, source: string,
    transport: AssetDownloadFn = GeoAssetManager.downloadAsset): Promise<boolean> {
    if (context === null) {
      return false;
    }
    if (this.ruleProviderDownloadTask !== null) {
      return this.ruleProviderDownloadTask;
    }
    const task = this.performRuleProviderDownload(context, source, transport);
    this.ruleProviderDownloadTask = task;
    try {
      return await task;
    } catch (e) {
      AppLogger.warn(TAG, `hyper-adrules download task error: ${AppLogger.errText(e)}`);
      return false;
    } finally {
      if (this.ruleProviderDownloadTask === task) {
        this.ruleProviderDownloadTask = null;
      }
    }
  }

  async performRuleProviderDownload(context: Context | null, source: string,
    transport: AssetDownloadFn = GeoAssetManager.downloadAsset): Promise<boolean> {
    if (context === null) {
      return false;
    }
    try {
      const dir = `${context.cacheDir}/${RULESET_SUBDIR}`;
      const dest = `${dir}/${HYPER_AD_RULES_FILE}`;
      try {
        ensurePrivateDir(dir);
      } catch (e) {
        AppLogger.warn(TAG, `ruleset dir create failed: ${AppLogger.errText(e)}`);
      }
      return await transport(HYPER_AD_RULES_MIRRORS, dest, RULE_SET_MIN_BYTES - 1,
        (buf: ArrayBuffer): boolean => buf.byteLength >= RULE_SET_MIN_BYTES
          && GeoAssetManager.bufferMagicOk(buf, ZSTD_MAGIC),
        source, 'hyper-adrules');
    } catch (e) {
      AppLogger.warn(TAG, `hyper-adrules download failed: ${AppLogger.errText(e)}`);
      return false;
    }
  }
}
