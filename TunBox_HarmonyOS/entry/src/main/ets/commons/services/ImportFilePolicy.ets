/**
 * 用户文件导入 / 长文本录入的统一上限策略（单一来源）。
 *
 * 为什么要有这个文件（2026-10-29 限制项全局审计）：
 *   同一类「大小上限」此前散落在各页面各写一遍字面量，导致两处不一致且互相漏改：
 *   · BackupPage 的 .json 导入曾限 4 MiB，SubscriptionSection 的 .yaml 导入也限 4 MiB，
 *     但下游 ProfileRepository / RawSubscriptionStore / BackupRestoreService /
 *     VpnExtensionAbility.readConfigText / SubscriptionFetchPolicy 全都是 8 MiB ——
 *     于是「同一份 5MB 配置走订阅 URL 能进、走文件导入被挡」。
 *   · 更严重的是这些字面量同时兼任**内存护栏**：导入路径普遍是
 *     `new ArrayBuffer(Number(stat.size))` 全量分配 + 整份 JSON.parse/YAML 解析，
 *     一旦「取消限制」被理解成「删掉判断」，护栏随之消失，用户误选大文件即 OOM。
 *
 * 因此本文件把「上限数值」与「面向用户的拒绝文案」一起收口，并遵循仓库既有范式
 * （见 AppRoutingPolicy.MAX_PACKAGES / SiteRoutingPolicy.MAX_SITES）：
 *   **显式拒绝，绝不静默截断。**
 *
 * 修改任何上限时只改这里，并同步检查对应 UI 文案是否引用了 describe()/tooLarge()。
 */
export class ImportFilePolicy {
  /**
   * 备份 .json 导入上限（32 MiB）。
   *
   * 取值依据：备份体是「订阅列表 + 每份 profile 原文 + 凭据」的 JSON，
   * 单份 profile 已受 YAML_MAX_BYTES(8 MiB) 约束，32 MiB 足够容纳多份大订阅；
   * 再往上不划算 —— 导入路径要一次性分配等量 ArrayBuffer 并 JSON.parse，
   * 解析后对象图的内存峰值是文本的数倍，属于主线程同步开销。
   */
  static readonly BACKUP_JSON_MAX_BYTES: number = 32 * 1024 * 1024;

  /**
   * 本地 Clash .yaml/.yml 导入上限（8 MiB）。
   * 必须与下游各处的 8 MiB 保持一致，否则文件导入会成为整条链路唯一的窄口。
   */
  static readonly YAML_MAX_BYTES: number = 8 * 1024 * 1024;

  /**
   * YAML 覆盖层（settings.yamlOverride）字符上限。
   * 与 AppSettings 反序列化侧的裁剪值同源；超过则拒绝保存而非截断。
   */
  static readonly YAML_OVERRIDE_MAX_CHARS: number = 8192;

  /** 人类可读的 MiB 数值（用于文案，去掉多余小数） */
  static mib(bytes: number): string {
    const v = bytes / (1024 * 1024);
    return Number.isInteger(v) ? `${v}` : v.toFixed(1);
  }

  /** 空文件拒绝文案 */
  static empty(): string {
    return '文件不能为空';
  }

  /** 超限拒绝文案（label 为场景名，如「备份文件」「配置文件」） */
  static tooLarge(label: string, limitBytes: number): string {
    return `${label}过大，不能超过 ${ImportFilePolicy.mib(limitBytes)} MiB`;
  }

  /**
   * 校验文件大小。返回空串表示通过；否则返回**面向用户的拒绝文案**。
   *
   * 统一在这里做 `<= 0` 与上限两侧判断，避免调用方各写一半（历史上正是
   * 「只删了上限、留下空文件判断」这种半改状态造成了护栏缺口）。
   *
   * @param sizeBytes fs.statSync().size（number 或 bigint 均可，调用方先 Number() 归一）
   * @param limitBytes 本文件定义的某个上限常量
   * @param label 场景名，用于文案
   */
  static validateSize(sizeBytes: number, limitBytes: number, label: string): string {
    if (!(sizeBytes > 0)) {
      // NaN / 0 / 负数一律按空文件拒绝
      return ImportFilePolicy.empty();
    }
    if (sizeBytes > limitBytes) {
      return ImportFilePolicy.tooLarge(label, limitBytes);
    }
    return '';
  }

  /**
   * 校验长文本录入长度。返回空串表示通过；否则返回面向用户的拒绝文案。
   * 供 TextArea 类输入在保存前调用 —— 保存时拒绝，而不是 slice 后谎报「已保存」。
   */
  static validateLength(text: string, limitChars: number, label: string): string {
    const len = typeof text === 'string' ? text.length : 0;
    if (len > limitChars) {
      return `${label}过长（${len}/${limitChars} 字符），请精简后保存；不会自动截断`;
    }
    return '';
  }
}
