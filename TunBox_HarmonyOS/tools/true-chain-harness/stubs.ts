// tools/true-chain-harness/stubs.ts
// 仅替换 HarmonyOS 系统能力与「持久化/网络」边界（测试替身），不包含任何解析逻辑。
// 所有解析/合并/映射/字段生成逻辑都来自 generated/*.ts（真实 .ets 源码）。
type AnyObj = Record<string, unknown>;

/** 与 @ohos.util.Type 对齐（BASIC=0 / MIME=1）。 */
const UTIL_TYPE = { BASIC: 0, MIME: 1, BASIC_URL_SAFE: 2, MIME_URL_SAFE: 3 };

/**
 * @ohos.util.Base64Helper 替身。decodeSync 按 BASIC 的严格度校验（非法字符/长度抛错），
 * 以贴近真机行为（HarmonyOS 在非法输入时抛错，而 Buffer 会静默容忍）。
 */
class Base64HelperStub {
  decodeSync(input: string, _type?: number): Uint8Array {
    const s = input.replace(/[\r\n\s]/g, '');
    if (!/^[A-Za-z0-9+/]*={0,2}$/.test(s) || s.length % 4 !== 0) {
      throw new Error('base64 stub: invalid input');
    }
    return new Uint8Array(Buffer.from(s, 'base64'));
  }
  encodeToStringSync(input: Uint8Array, _type?: number): string {
    return Buffer.from(input).toString('base64');
  }
}

/**
 * @kit.BasicServicesKit 的 BusinessError 替身。
 * 系统错误对象：{ code: number, message: string }。
 * 真实代码里用 `err.code` / `err.message` 取值，且会 `instanceof BusinessError` 判断；
 * 替身保持同样的字段与原型链。
 */
export class BusinessError extends Error {
  code: number = 0;
  constructor(code: number = 0, message: string = '') {
    super(message);
    this.code = code;
    this.name = 'BusinessError';
  }
}

/**
 * @kit.NotificationKit 替身：只提供被测代码真正用到的那几个成员
 * （ContentType 枚举 + publish），不做任何真实通知行为。
 */
export const notificationManager = {
  ContentType: {
    NOTIFICATION_CONTENT_BASIC_TEXT: 0,
    NOTIFICATION_CONTENT_LONG_TEXT: 1
  },
  async publish(_request: AnyObj): Promise<void> {
    // 替身：丢弃通知（测试不关心系统通知）
  }
};

/**
 * SettingsService 替身：load/save 走内存，测试里不碰 preferences。
 */
export class SettingsService {
  private static current: AnyObj = {};
  static async load(): Promise<AnyObj> {
    return SettingsService.current;
  }
  static async save(settings: AnyObj): Promise<void> {
    SettingsService.current = settings;
  }
}

/** CredentialStore 的别名生成器替身（与真实实现同构，避免链路里出现不同的 key）。 */
export function nodeAlias(nodeId: string, field: string): string {
  return `tunbox_node|${nodeId}|${field}`;
}

export function subAlias(subscriptionId: string): string {
  return `tunbox_sub|${subscriptionId}|headerValue`;
}

export const util = {
  Type: UTIL_TYPE,
  Base64Helper: Base64HelperStub,
  TextEncoder: {
    create(_enc: string): { encodeInto(s: string): Uint8Array } {
      return {
        encodeInto(s: string): Uint8Array {
          return new Uint8Array(Buffer.from(s, 'utf8'));
        },
      };
    },
  },
  TextDecoder: {
    create(_enc: string): { decodeToString(b: Uint8Array): string } {
      return {
        decodeToString(b: Uint8Array): string {
          return Buffer.from(b).toString('utf8');
        },
      };
    },
  },
  generateRandomUUID(): string {
    return globalThis.crypto.randomUUID();
  },
};

export class AppLogger {
  static lines: string[] = [];
  static info(tag: string, msg: string): void { AppLogger.lines.push(`INFO ${tag} ${msg}`); }
  static warn(tag: string, msg: string): void { AppLogger.lines.push(`WARN ${tag} ${msg}`); }
  static error(tag: string, msg: string): void { AppLogger.lines.push(`ERROR ${tag} ${msg}`); }
  static errText(e: Object): string { return String(e); }
  static addListener(_l: (line: string) => void): void {}
  static removeListener(_l: (line: string) => void): void {}
}

/** preferences 替身：内存实现，用于模拟 devices 上的持久化（可选注入初始值）。 */
export const harnessPrefs = new Map<string, string>();
export const preferences = {
  async getPreferences(_ctx: unknown): Promise<AnyObj> {
    return {
      async get(key: string, def: string): Promise<string> {
        return harnessPrefs.has(key) ? (harnessPrefs.get(key) as string) : def;
      },
      async put(key: string, value: string): Promise<void> { harnessPrefs.set(key, value); },
      async delete(key: string): Promise<void> { harnessPrefs.delete(key); },
      async flush(): Promise<void> {},
    };
  },
};

export const asset = {};

/** ClashApiService 边界替身：仅提供 NodeSortPersistence 使用的失败分类常量。 */
export class LatencyFailKind {
  static readonly NONE: string = '';
  static readonly CORE_NOT_READY: string = 'core_not_ready';
  static readonly SWITCH_FAILED: string = 'switch_failed';
  static readonly NETWORK_UNREACHABLE: string = 'network_unreachable';
  static readonly TIMEOUT: string = 'timeout';
  static readonly UNSUPPORTED: string = 'unsupported';
  static readonly PORT_ONLY: string = 'port_reachable_only';
  static readonly UNTESTED: string = 'untested';
}

/** RawSubscriptionStore 边界替身：只模拟生成器依赖的登记表与常量，不包含解析逻辑。 */
export const RAW_PROVIDER_HEALTH_CHECK_ENABLED: boolean = true;
export const RAW_PROVIDER_HEALTH_CHECK_URL = 'https://www.gstatic.com/generate_204';
export const RAW_PROVIDER_HEALTH_CHECK_INTERVAL = 300;
export const RAW_PROVIDER_PATH_MODE: string = 'relative';

export class RawProviderEntry {
  subscriptionId: string = '';
  providerName: string = '';
  providerPath: string = '';
  filePath: string = '';
  bytes: number = 0;
  nodeEstimate: number = 0;
}

export class RawProviderStats {
  enabled: boolean = false;
  candidates: number = 0;
  emitted: number = 0;
  missingFiles: number = 0;
  orphaned: number = 0;
  /** 与真实实现保持同名同语义：生成器在差额 > 0 时会调 detail() 打诊断 */
  nameConflicts: number = 0;
  nameMismatch: number = 0;
  pathMode: string = '';
  providerNames: string = '';

  detail(): string {
    return `stub provider：发出 ${this.emitted}/${this.candidates}`
      + `（缺失 ${this.missingFiles}，无节点 ${this.orphaned}，`
      + `重名 ${this.nameConflicts}，名字不一致 ${this.nameMismatch}）`;
  }
}

export class RawProviderPlan {
  entries: RawProviderEntry[] = [];
  stats: RawProviderStats = new RawProviderStats();
}

export class RawWriteResult {
  ok: boolean = false;
  bytes: number = 0;
  filePath: string = '';
  reason: string = '';
}

export class RawProviderStatus {
  subscriptionId: string = '';
  enabled: boolean = false;
  fileExists: boolean = false;
  ineligible: boolean = false;
  failed: boolean = false;
  bytes: number = 0;
  nodeEstimate: number = 0;
  label: string = '';
  tone: string = 'ok';
}

export class RawProviderStates {
  static readonly OFF: string = 'off';
  static readonly READY: string = 'ready';
  static readonly INELIGIBLE: string = 'ineligible';
  static readonly FAILED: string = 'failed';
  static readonly MISSING: string = 'missing';
  static isValid(value: string): boolean {
    return value === '' || value === RawProviderStates.OFF || value === RawProviderStates.READY
      || value === RawProviderStates.INELIGIBLE || value === RawProviderStates.FAILED
      || value === RawProviderStates.MISSING;
  }
}

export class RawSubscriptionStore {
  static enabled: boolean = false;
  static lastDiagnosticLine: string = '';
  /** id → 落盘原文（模拟双轨 raw 文件；refreshLocalSubscription 的读取路径依赖它） */
  static raws = new Map<string, string>();
  private static entries: RawProviderEntry[] = [];
  static init(_cacheDir: string): void {}
  static isReady(): boolean { return true; }
  static readRaw(subscriptionId: string): string {
    return RawSubscriptionStore.raws.get(subscriptionId) ?? '';
  }
  static writeRaw(subscriptionId: string, body: string): RawProviderWriteResult {
    RawSubscriptionStore.raws.set(subscriptionId, body);
    const out = new RawProviderWriteResult();
    out.ok = true;
    return out;
  }
  static removeOrphans(_ids: string[]): void {}
  static active(): RawProviderEntry[] { return RawSubscriptionStore.entries.slice(); }
  static has(subscriptionId: string): boolean {
    return RawSubscriptionStore.entries.some((entry) => entry.subscriptionId === subscriptionId);
  }
  static upsert(entry: RawProviderEntry): void {
    RawSubscriptionStore.entries = RawSubscriptionStore.entries
      .filter((item) => item.subscriptionId !== entry.subscriptionId).concat(entry);
  }
  static drop(subscriptionId: string): void {
    RawSubscriptionStore.entries = RawSubscriptionStore.entries
      .filter((entry) => entry.subscriptionId !== subscriptionId);
  }
}

/** 与真实 RawWriteResult 同形（stub 写入恒成功） */
export class RawProviderWriteResult {
  ok: boolean = false;
  reason: string = '';
}

/** SubscriptionJson 是纯数据类，这里按真实字段复刻（仅用于模型层往返，不含逻辑）。 */
export class SubscriptionJson {
  id: string = '';
  name: string = '';
  url: string = '';
  headerName: string = '';
  headerValue: string = '';
  lastFetchedAt: number = 0;
  lastRefreshResult: string = '';
  nodeCount: number = 0;
  uploadBytes?: number;
  downloadBytes?: number;
  totalBytes?: number;
  expireAt?: number;
  enabled: boolean = true;
  sortOrder: number = 0;
}

export class CredentialMigrationReport {
  migratedNodes: number = 0;
  migratedFields: number = 0;
  migratedSubscriptions: number = 0;
  alreadyStored: number = 0;
  addedNew: number = 0;
  failed: number = 0;
  fieldFailed(_id: string, _field: string): boolean { return false; }
  fieldStored(_id: string, _field: string): boolean { return false; }
}

export class NodeCredentialValues {
  password: string = '';
  uuid: string = '';
  protocolParam: string = '';
  obfsParam: string = '';
}

export class SubscriptionCredentialSource {
  id: string = '';
  headerValue: string = '';
}

export const CRED_PREF_NAME = 'tunbox_credentials';
export const MIGRATION_FLAG_KEY = 'migration_v1_done';
export const SUB_CRED_FIELD = 'headerValue';
export const NODE_CRED_FIELDS: string[] = ['password', 'uuid', 'protocolParam', 'obfsParam'];
export function baseNodeName(name: string): string {
  let out = name;
  let changed = true;
  while (changed) {
    changed = false;
    const next = out.replace(/\s#\d+$/, '').replace(/\s\(\d+\)$/, '');
    if (next !== out) {
      out = next;
      changed = true;
    }
  }
  return out;
}
export function nodeCredentialId(n: AnyObj): string {
  const name = typeof n['name'] === 'string' ? n['name'] : '';
  return `${n['subscriptionId']}|${n['server']}|${n['port']}|${baseNodeName(name)}`;
}
export function setCredentialLogger(_f: (msg: string) => void): void {}

export class CredentialStore {
  static async loadMigrationFlag(): Promise<void> {}
  static isFirstRun(): boolean { return false; }
  static async canonicalize(_n: AnyObj[], _s: AnyObj[], _b: boolean): Promise<CredentialMigrationReport> {
    return new CredentialMigrationReport();
  }
  static async canonicalizeNodes(_n: AnyObj[], _b: boolean): Promise<CredentialMigrationReport> {
    return new CredentialMigrationReport();
  }
  static logAssetUnavailable(_where: string): void {}
  static async nodeCredentials(_id: string, fallback: NodeCredentialValues): Promise<NodeCredentialValues> {
    return fallback;
  }
  static async subscriptionCredential(_id: string, fallback: string): Promise<string> { return fallback; }
  static plaintextFieldKeys(): string[] { return []; }
  static exportAliasCache(): string { return ''; }
  static importAliasCache(_json: string): void {}
  static setHydrateScope(_ids: string[]): void {}
  static async loadAllCredentials(): Promise<AnyObj> { return {}; }
  static async nodeCredentialsFromCache(_id: string, fallback: NodeCredentialValues): Promise<NodeCredentialValues> {
    return fallback;
  }
  static async markMigrationFlagInAsset(): Promise<void> {}
  static readonly NODE_CRED_FIELDS: string[] = [];
}

export class AppInfo {
  static version(): string { return '0.0.0-harness'; }
}

export class SubscriptionUserInfo {
  uploadBytes: number = -1;
  downloadBytes: number = -1;
  totalBytes: number = -1;
  expireAt: number = -1;
}

export class SubscriptionFetchResult {
  body: string = '';
  userInfo: SubscriptionUserInfo = new SubscriptionUserInfo();
}

/** 网络替身：body 由 chain.mjs 注入到 globalThis.__HARNESS_BODY__。 */
export class SubscriptionFetchPolicy {
  static async fetch(_url: string, _hn: string, _hv: string): Promise<AnyObj> {
    const g = globalThis as unknown as { __HARNESS_BODY__?: string; __HARNESS_FETCH_MODE__?: string };
    const body = g.__HARNESS_BODY__ ?? '';
    return { body, userInfo: new SubscriptionUserInfo() };
  }
  static isNodeCountAllowed(count: number): boolean { return count <= 2000; }
  static isValidSubscriptionUrl(_url: string, _qr?: boolean): boolean { return true; }
}

export const SubscriptionFetchErrorKind = {
  NETWORK: 'network', HTTP: 'http', EMPTY_RESPONSE: 'emptyResponse', DECODE: 'decode',
};

export class SubscriptionFetchError extends Error {
  kind: string = SubscriptionFetchErrorKind.NETWORK;
  constructor(kind: string, message: string) {
    super(message);
    this.kind = kind;
  }
}


/**
 * fileIo 替身：内存 Map 沙箱（tmp→rename 原子写语义保留；harnessPrefs.clear 不清文件）。
 * 路径按字符串原样作键；未写过的路径 access/stat/open 按不存在抛错。
 */
interface StubFile { fd: number; path: string; content: string }
const fsSandbox = new Map<string, string>();
let fdSeq = 3;
const openFiles = new Map<number, StubFile>();
export const fileIo = {
  OpenMode: { READ_ONLY: 0, READ_WRITE: 1, CREATE: 2, TRUNC: 4 },
  mkdirSync(_path: string, _recursive?: boolean): void {},
  accessSync(path: string): void { if (!fsSandbox.has(path)) { throw new Error('stub: not found'); } },
  statSync(path: string): { size: number } {
    const c = fsSandbox.get(path);
    if (c === undefined) { throw new Error('stub: not found'); }
    return { size: c.length };
  },
  openSync(path: string, _mode: number): { fd: number } {
    const content = fsSandbox.get(path) ?? '';
    const fd = fdSeq++;
    openFiles.set(fd, { fd, path, content });
    return { fd };
  },
  readSync(fd: number, buf: ArrayBuffer): number {
    const f = openFiles.get(fd);
    if (f === undefined) { return 0; }
    const bytes = new TextEncoder().encode(f.content);
    new Uint8Array(buf).set(bytes.subarray(0, buf.byteLength));
    return Math.min(bytes.length, buf.byteLength);
  },
  writeSync(fd: number, text: string): number {
    const f = openFiles.get(fd);
    if (f === undefined) { return 0; }
    f.content = text;
    fsSandbox.set(f.path, text);
    return text.length;
  },
  closeSync(_file: unknown): void {},
  unlinkSync(path: string): void { fsSandbox.delete(path); },
  renameSync(from: string, to: string): void {
    const c = fsSandbox.get(from);
    if (c !== undefined) { fsSandbox.set(to, c); fsSandbox.delete(from); }
  },
};


/** 内核目录服务替身（SubscriptionService 的节点回落路径；单测不触发）。 */
export class CoreCatalogService {
  static current(): { byName: Record<string, { name: string; type: string; isGroup: boolean }> } | null {
    return null;
  }
}

/** 内核节点影子桥替身。 */
export class CoreNodeBridge {
  static toProxyNode(_node: unknown): unknown {
    return null;
  }
}

export const coreBridge = { async prepareProfile(_text: string): Promise<string> { throw new Error("Inject a real profile validator in tests"); } };

// ArkUI AppStorage 沙箱（SubscriptionService.persist 里的 revision 计数）
(globalThis as AnyObj).AppStorage = {
  map: new Map<string, Object>(),
  setOrCreate(key: string, value: Object): void { (this.map as Map<string, Object>).set(key, value); },
  get<T>(key: string): T | undefined { return (this.map as Map<string, T>).get(key); },
};
