/**
 * Profile **Repository**（订阅原文 = 一份 Profile 文件）
 *
 * ⚠ 定位说明（2026-10-27 架构收口）：本类**不是**文件读写工具，而是配置仓库 ——
 * 它拥有「当前用哪份 profile」「校验后落盘」「revision 版本」「可用性判定」这些领域决策，
 * 全仓 122 处引用都依赖它做事实判定（`currentId` / `exists` / `revisionOf`）。
 *
 * 新代码请通过同文件导出的 `ProfileRepository` 别名引用，读代码的人一眼能看出它是仓库；
 * 历史 `ProfileRepository` 引用保留（纯改名会污染 diff，收益为零）。
 *
 * 来源：FlClash `lib/models/profile.dart` + `lib/core/controller.dart:101-127`
 *      （`Profile.file` / `saveFile` / `validateProfile`）。
 *
 * ## 与旧实现的结构差别（这次是刻意改的）
 *
 * 旧：订阅 → App 侧解析成 ProxyNode 表 → 生成配置时逐字段重建节点。
 * 新（FlClash 同构）：订阅 → **完整文档校验并规范化落盘** `<filesDir>/profiles/<id>.yaml` → 内核解析。
 *     App 侧不再持有节点清单，节点/分组一律从内核 `/proxies` 读（见 CoreCatalog）。
 *
 * ## 文件布局
 *
 * ```
 * <filesDir>/profiles/<subId>.yaml     校验后的完整 YAML（原始响应由 RawSubscriptionStore 保留）
 * preferences 'tunbox_profiles'        { current: '<id>', autoUpdate: {id:bool} }
 * ```
 *
 * ## 校验（等价 FlClash validateProfile，固定上游 be847366）
 *
 * 1. 原文 temp → 原生 validateProfile（`getProfileBase`，mihomo 同一解析器）；
 *    通过 → 原样落盘；
 * 2. age 加密内容 → 原始 AgeSecretKey 错误回 UI；
 * 3. 其他失败 → `SubConverter`（mihomo `convert.ConvertsV2Ray` 的移植）→ 再原生
 *    校验 → 通过写转换产物；
 * 4. 两者都失败 → 拒绝，**不覆盖已有文件**（旧 profile 保持可用）。
 */
import { preferences } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppLogger } from '../utils/AppLogger';
import { BodyDispatch } from '../subscription/BodyDispatch';
// FlClash saveFile 同构：订阅校验由内核完成（mihomo 同一解析器）
import { coreBridge } from '../../core/CoreBridge';

const TAG = 'ProfileRepository';
const PREF_NAME = 'tunbox_profiles';
const KEY_STATE = 'profile_state';
const KEY_AGE_PREFIX = 'profile_age_key.';
const DIR_NAME = 'profiles';
/** 单份 profile 上限（与订阅拉取上限一致：8MB） */
const MAX_PROFILE_BYTES = 8 * 1024 * 1024;

export class ProfileValidationResult {
  ok: boolean = false;
  /** 面向用户的失败文案（成功为空串，对齐 FlClash validateProfile 的返回） */
  message: string = '';
  /** 保留兼容：convert 回退已在 Go 内完成（bridge/profile.go），App 不再自转 */
  converted: boolean = false;
  /** age 加密订阅需要密钥（FlClash AgeSecretKeyRequiredException 同构；UI 弹框要 key 后重试） */
  needAgeSecretKey: boolean = false;
  /** 节点数（FlClash configCountsOf 口径：内核解析出的 proxies 数） */
  nodeCount: number = 0;
}

export class ProfileRepository {
  private static store: preferences.Preferences | null = null;
  private static dirPath: string = '';
  private static currentProfileId: string = '';
  private static loaded: boolean = false;
  private static preparedCache: Map<string, string> = new Map<string, string>();
  private static preparer: ((text: string) => Promise<string>) | null = null;

  static attachPreparer(preparer: (text: string) => Promise<string>): void {
    ProfileRepository.preparer = preparer;
  }

  /**
   * config/profile_prepare 严格校验**只留预览**：锚点展开 + 引用校验（Go
   * `PrepareProfile` 比原生 `UnmarshalRawConfig` 更严，会卡 `rule proxy not
   * found` 等）。预览失败绝不得卡 native 已通过的 profile —— 回退原文。
   */
  static async prepare(text: string): Promise<string> {
    if (ProfileRepository.preparer === null) {
      return text;
    }
    const key = ProfileRepository.fingerprint(text);
    const cached = ProfileRepository.preparedCache.get(key);
    if (cached !== undefined) { return cached; }
    let prepared = text;
    try {
      prepared = await ProfileRepository.preparer(text);
    } catch (e) {
      AppLogger.warn(TAG, `profile prepare failed, keep raw text: ${AppLogger.errText(e)}`);
      return text;
    }
    if (ProfileRepository.preparedCache.size >= 8) { ProfileRepository.preparedCache.clear(); }
    ProfileRepository.preparedCache.set(key, prepared);
    ProfileRepository.preparedCache.set(ProfileRepository.fingerprint(prepared), prepared);
    return prepared;
  }

  /** 原生错误是否为 age 加密 / 密钥缺失（bridge/profile.go `ErrAgeSecretKeyRequired`）。 */
  private static isAgeError(message: string): boolean {
    const msg = message.toLowerCase();
    if (msg.includes('agesecretkeyrequired')) {
      return true;
    }
    return msg.includes('age') && (msg.includes('decrypt') || msg.includes('secret'));
  }

  /**
   * FlClash `Profile.ageSecretKey`：按 profile 持久化的 age 密钥。
   * 首次校验返回 `AgeSecretKeyRequired` → UI 要 key → 写入后重试（上游同序）。
   */
  static async getAgeSecretKey(id: string): Promise<string> {
    if (ProfileRepository.store === null || id.length === 0) {
      return '';
    }
    try {
      const value = await ProfileRepository.store.get(`${KEY_AGE_PREFIX}${id}`, '');
      return typeof value === 'string' ? value : '';
    } catch (e) {
      AppLogger.warn(TAG, `read age key failed: ${AppLogger.errText(e)}`);
      return '';
    }
  }

  static async setAgeSecretKey(id: string, key: string): Promise<void> {
    if (ProfileRepository.store === null || id.length === 0) {
      return;
    }
    try {
      await ProfileRepository.store.put(`${KEY_AGE_PREFIX}${id}`, key);
      await ProfileRepository.store.flush();
    } catch (e) {
      AppLogger.warn(TAG, `persist age key failed: ${AppLogger.errText(e)}`);
    }
  }

  /** Content identity only; never include profile text or credentials in logs. */
  static fingerprint(text: string): string {
    let first = 2166136261;
    let second = 5381;
    for (let i = 0; i < text.length; i++) {
      first = Math.imul(first ^ text.charCodeAt(i), 16777619);
      second = Math.imul(second, 33) ^ text.charCodeAt(i);
    }
    return `${text.length}:${first >>> 0}:${second >>> 0}`;
  }

  static revisionOf(id: string): string {
    return id.length === 0 ? '' : ProfileRepository.fingerprint(ProfileRepository.read(id));
  }

  static async init(context: Context): Promise<void> {
    if (ProfileRepository.loaded) {
      return;
    }
    ProfileRepository.dirPath = `${context.filesDir}/${DIR_NAME}`;
    ProfileRepository.ensureDir(ProfileRepository.dirPath);
    ProfileRepository.store = await preferences.getPreferences(context, PREF_NAME);
    const raw = await ProfileRepository.store.get(KEY_STATE, '{}') as string;
    try {
      const obj = JSON.parse(raw) as Record<string, Object>;
      const current = obj['current'];
      if (typeof current === 'string') {
        ProfileRepository.currentProfileId = current;
      }
    } catch (e) {
      AppLogger.warn(TAG, 'invalid profile state ignored');
    }
    ProfileRepository.loaded = true;
    AppLogger.info(TAG, `profiles dir ready: ${ProfileRepository.dirPath} current=${ProfileRepository.currentProfileId}`);
  }

  /** 确保目录存在（应用私有目录，权限由系统沙箱保证）。 */
  private static ensureDir(dir: string): void {
    try {
      fs.mkdirSync(dir, true);
    } catch (e) {
      // 目录已存在属正常
    }
  }

  static isReady(): boolean {
    return ProfileRepository.loaded;
  }

  static dir(): string {
    return ProfileRepository.dirPath;
  }

  static pathOf(id: string): string {
    return `${ProfileRepository.dirPath}/${ProfileRepository.safeId(id)}.yaml`;
  }

  /** 订阅 id 里可能有路径分隔符/冒号：落盘文件名只允许 `[A-Za-z0-9_-]`。 */
  private static safeId(id: string): string {
    let out = '';
    for (let i = 0; i < id.length; i++) {
      const ch = id.charAt(i);
      const isDigit = ch >= '0' && ch <= '9';
      const isLower = ch >= 'a' && ch <= 'z';
      const isUpper = ch >= 'A' && ch <= 'Z';
      const isSafe = ch === '-' || ch === '_';
      out += (isDigit || isLower || isUpper || isSafe) ? ch : '_';
    }
    return out.length === 0 ? 'profile' : out;
  }

  /**
   * profile 文件是否**可用**（存在且非空）。
   *
   * ⚠ 不能用 accessSync 判存在：真机上出现过「accessSync 成功、statSync 报
   * No such file」的现场，于是 exists()=true 而 read()='' —— 调用方会把这个订阅
   * 当成「有 profile」切成 current，配置却拿不到基底，回落到「全部订阅合并」，
   * 界面上就出现「A 订阅里显示 B/C/D 的节点」（用户实锤：飞鸟云里出现另外三个订阅的节点）。
   * 这里以 statSync().size > 0 为唯一判据。
   */
  static exists(id: string): boolean {
    if (id.length === 0) {
      return false;
    }
    try {
      const stat = fs.statSync(ProfileRepository.pathOf(id));
      return stat.size > 0;
    } catch (e) {
      return false;
    }
  }

  /** 读原文；不存在/读取失败返回空串（调用方按「无 profile」处理）。 */
  static read(id: string): string {
    if (!ProfileRepository.exists(id)) {
      return '';
    }
    const path = ProfileRepository.pathOf(id);
    let file: fs.File | null = null;
    try {
      const stat = fs.statSync(path);
      if (stat.size <= 0 || stat.size > MAX_PROFILE_BYTES) {
        AppLogger.warn(TAG, `profile size out of range: ${path} size=${stat.size}`);
        return '';
      }
      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(stat.size);
      const read = fs.readSync(file.fd, buf);
      return ProfileRepository.decode(buf, read);
    } catch (e) {
      AppLogger.warn(TAG, `read profile failed: ${AppLogger.errText(e)}`);
      return '';
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e) {
          // 已关闭/句柄失效：忽略
        }
      }
    }
  }

  private static decode(buf: ArrayBuffer, bytes: number): string {
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(buf, 0, bytes));
  }

  /** 原子写（tmp → rename），权限 0600。 */
  static write(id: string, content: string): boolean {
    if (id.length === 0) {
      return false;
    }
    ProfileRepository.ensureDir(ProfileRepository.dirPath);
    const target = ProfileRepository.pathOf(id);
    const tmp = `${target}.tmp`;
    let file: fs.File | null = null;
    try {
      file = fs.openSync(tmp, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, content);
      fs.closeSync(file);
      file = null;
      // Same-directory rename replaces the previous file atomically.
      fs.renameSync(tmp, target);
      return true;
    } catch (e) {
      AppLogger.error(TAG, `write profile failed: ${AppLogger.errText(e)}`);
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (closeError) {
          // 忽略
        }
      }
      try {
        fs.unlinkSync(tmp);
      } catch (cleanupError) {
        // 忽略
      }
      return false;
    }
  }

  static remove(id: string): void {
    const path = ProfileRepository.pathOf(id);
    try {
      fs.unlinkSync(path);
    } catch (e) {
      // 不存在属正常
    }
  }

  static currentId(): string {
    return ProfileRepository.currentProfileId;
  }

  static async setCurrent(id: string): Promise<void> {
    ProfileRepository.currentProfileId = id;
    await ProfileRepository.persistState();
  }

  private static async persistState(): Promise<void> {
    if (ProfileRepository.store === null) {
      return;
    }
    const state: Record<string, string> = { 'current': ProfileRepository.currentProfileId };
    try {
      await ProfileRepository.store.put(KEY_STATE, JSON.stringify(state));
      await ProfileRepository.store.flush();
    } catch (e) {
      AppLogger.warn(TAG, `persist profile state failed: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * 校验并落盘（**FlClash `Profile.saveFile` + controller.validateProfile 同构**，
   * 固定上游 be847366）。整条链已在原生 `validateProfile` 内实现（bridge/profile.go）：
   *
   *   原文 → temp → age 解密（armor 头 + 空 key → 原始 `AgeSecretKeyRequired`）
   *   → validateConfig（`unmarshalRawConfig`，含 short-id retag）
   *   → 失败走转换器：`convert.ConvertsV2Ray` → 非空写 `{'proxies':...}` 再校验
   *   → 仍失败返回**首次** issue → 通过后把最终字节**原样** copy 到
   *   `profiles/<id>.yaml`（不展开锚点、不规范化）。
   *
   * App 侧只做三件事：解包裹层（BodyDispatch 不是准入闸）、把 age 密钥透传、
   * 把原生错误原样回 UI。没有文本闸（R5 反例：JSON 引号键 / `rules:`-only
   * 都必须直接交给原生判定），也没有 App 侧二次 convert。
   */
  static async validateAndStore(id: string, text: string, ageSecretKey?: string): Promise<ProfileValidationResult> {
    const out = new ProfileValidationResult();
    if (id.length === 0 || text.trim().length === 0) {
      out.message = '订阅内容或标识为空';
      return out;
    }
    let candidate = text;
    try {
      // 解包裹层（base64 包裹的 YAML），不是内容准入闸。
      candidate = BodyDispatch.classify(text).body;
    } catch (e) {
      out.message = `订阅校验失败，已保留旧配置：${AppLogger.errText(e)}`;
      return out;
    }
    let key: string = ageSecretKey ?? '';
    if (key.trim().length === 0) {
      key = await ProfileRepository.getAgeSecretKey(id);
    }
    const target = ProfileRepository.pathOf(id);
    try {
      await coreBridge.validateProfile(candidate, key, target);
      out.ok = true;
    } catch (e) {
      // 原生校验失败：错误原文就是用户需要的东西（FlClash 原样抛给 UI，§5.6）
      const message: string = AppLogger.errText(e);
      out.ok = false;
      out.message = message;
      // age 密钥需求：原始错误回 UI，UI 取 key 后带 ageSecretKey 重试（上游同序）。
      if (ProfileRepository.isAgeError(message)) {
        out.needAgeSecretKey = true;
      }
      return out;
    }
    if (key.trim().length > 0) {
      await ProfileRepository.setAgeSecretKey(id, key);
    }
    out.nodeCount = await ProfileRepository.countNodes(target);
    return out;
  }

  /** FlClash `configCountsOf` 口径：节点数 = 内核解析出的 proxies 数（失败不回打校验结果）。 */
  private static async countNodes(profilePath: string): Promise<number> {
    try {
      const base = await coreBridge.getProfileBase(profilePath);
      return base.proxies;
    } catch (e) {
      AppLogger.warn(TAG, `count profile nodes failed: ${AppLogger.errText(e)}`);
      return 0;
    }
  }
}

/**
 * 向后兼容别名：旧代码里的 `ProfileStore` 指向同一个配置仓库。
 * 新代码一律用 `ProfileRepository`（命名即契约：它是仓库，不是文件工具）。
 */
export const ProfileStore = ProfileRepository;
