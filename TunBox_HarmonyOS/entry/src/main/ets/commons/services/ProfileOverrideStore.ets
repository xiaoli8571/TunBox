/**
 * 每订阅 Override 覆盖层（FlClash `Profile.overrides` 的鸿蒙等价物）。
 *
 * ## 为什么需要它
 * 旧实现只有**全局** `AppSettings.yamlOverride`：改一处，所有订阅一起变。
 * FlClash 的覆盖是按 profile 存的（`Profile.overrides`），换订阅就换覆盖；
 * 全局覆盖会让「只给 A 机场改 DNS」变成「把 B/C 也改了」。
 *
 * ## 为什么不学 FlClash 用 JS 脚本
 * FlClash 另有 `scripts`（Dart 侧 JS 引擎执行 profile 变换）。ArkTS **禁止 eval**，
 * 鸿蒙侧没有可用的 JS 运行时；要一模一样必须随包编译 QuickJS/NAPI（另立构建项）。
 * 本类先补齐**结构化覆盖**这一半：覆盖层是与 FlClash 相同的 YAML 尾部合并语义，
 * 按 profile 隔离存储，生成配置时只作用于该 profile。
 *
 * ## 存法
 * `preferences 'tunbox_profile_overrides'` → `{"<profileId>": "<yaml 文本>"}`
 * 上限与设置页 yamlOverride 同源（`ImportFilePolicy.YAML_OVERRIDE_MAX_CHARS`），
 * 超限**拒绝保存**而不是静默截断（仓库既有范式）。
 */
import { preferences } from '@kit.ArkData';
import { AppLogger } from '../utils/AppLogger';
import { AppSettings } from '../models/AppSettings';

const TAG = 'ProfileOverrideStore';
const PREF_NAME = 'tunbox_profile_overrides';
const KEY_STORE = 'overrides_json';
/** 与设置页 yamlOverride 同一上限（单一来源：ImportFilePolicy） */
const MAX_CHARS = 8192;

export class ProfileOverrideStore {
  private static store: preferences.Preferences | null = null;
  private static cache: Map<string, string> = new Map<string, string>();
  private static loaded: boolean = false;

  static isReady(): boolean {
    return ProfileOverrideStore.loaded;
  }

  static async init(context: Context): Promise<void> {
    if (ProfileOverrideStore.loaded) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, PREF_NAME);
      ProfileOverrideStore.store = store;
      const raw = await store.get(KEY_STORE, '') as string;
      ProfileOverrideStore.load(raw);
      ProfileOverrideStore.loaded = true;
    } catch (e) {
      AppLogger.warn(TAG, `init failed: ${AppLogger.errText(e)}`);
    }
  }

  private static load(raw: string): void {
    ProfileOverrideStore.cache.clear();
    if (raw.length === 0) {
      return;
    }
    try {
      const obj = JSON.parse(raw) as Record<string, Object>;
      if (obj === null || Array.isArray(obj)) {
        return;
      }
      for (const key of Object.keys(obj)) {
        const value = obj[key];
        if (typeof value === 'string') {
          ProfileOverrideStore.cache.set(key, value as string);
        }
      }
    } catch (e) {
      AppLogger.warn(TAG, `parse overrides failed: ${AppLogger.errText(e)}`);
    }
  }

  /** 该 profile 的覆盖层；没有则空串。 */
  static get(profileId: string): string {
    if (profileId.length === 0) {
      return '';
    }
    const text = ProfileOverrideStore.cache.get(profileId);
    return text === undefined ? '' : text;
  }

  /**
   * 生效覆盖层：profile 专属优先，否则回落全局 yamlOverride。
   * **返回值只用于生成配置**，不要写回设置（避免把 A 的覆盖扩散到 B）。
   */
  static effective(profileId: string, fallback: string): string {
    const own = ProfileOverrideStore.get(profileId);
    return own.length > 0 ? own : fallback;
  }

  /** 保存覆盖层（空串 = 删除该 profile 的覆盖）。返回是否落盘成功。 */
  static async set(profileId: string, text: string): Promise<boolean> {
    if (profileId.length === 0) {
      return false;
    }
    const trimmed = text.trim();
    if (trimmed.length > MAX_CHARS) {
      AppLogger.warn(TAG, `override rejected: ${trimmed.length} > ${MAX_CHARS}`);
      return false;
    }
    if (trimmed.length === 0) {
      ProfileOverrideStore.cache.delete(profileId);
    } else {
      ProfileOverrideStore.cache.set(profileId, trimmed);
    }
    return await ProfileOverrideStore.persist();
  }

  /** 删除订阅时一并清掉它的覆盖层（幂等）。 */
  static async remove(profileId: string): Promise<void> {
    if (ProfileOverrideStore.cache.delete(profileId)) {
      await ProfileOverrideStore.persist();
    }
  }

  /** 供设置页展示上限（不重复写字面量）。 */
  static maxChars(): number {
    return MAX_CHARS;
  }

  private static async persist(): Promise<boolean> {
    if (ProfileOverrideStore.store === null) {
      return false;
    }
    const out: Record<string, string> = {};
    ProfileOverrideStore.cache.forEach((value: string, key: string): void => {
      out[key] = value;
    });
    try {
      await ProfileOverrideStore.store.put(KEY_STORE, JSON.stringify(out));
      await ProfileOverrideStore.store.flush();
      return true;
    } catch (e) {
      AppLogger.warn(TAG, `persist failed: ${AppLogger.errText(e)}`);
      return false;
    }
  }
}
