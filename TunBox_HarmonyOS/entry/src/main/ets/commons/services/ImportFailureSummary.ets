/**
 * 失败原因的展示折叠（**单一实现**：导入 / 导出 / 刷新三处共用）。
 *
 * ## 为什么要有它
 *
 * 用户报障「导入失败 / 订阅解析失败 / 刷新失败」时，页面此前只弹一句
 * `导入失败，请重试` / `刷新失败：<订阅名>`，而真正的判词其实**已经算出来了**：
 *   · `SubscriptionService.refreshSubscription` 的 `message`（含空响应字节数、
 *     校验失败原因、HTTP 状态码）；
 *   · `ProfileRepository.validateAndStore` 的 `message`（含"已保留旧配置"）；
 *   · 系统 picker / 文件读写的 `BusinessError`（含 `code`）。
 * 这些字符串被 catch 分支丢掉，用户只能反复试 —— 这是"小问题不断"里
 * **唯一无法自查**的一类，因为原因没有到达用户。
 *
 * 本类只做两件事，保持纯函数、无 kit 依赖，便于门禁直接执行：
 *   1. 把多行/超长原因压成一行并限长（toast 有显示上限，整段会截断到看不出重点）；
 *   2. 统一「前缀｜原因」的拼装，避免三处各写一遍（历史上正是各写一遍导致口径漂移）。
 *
 * ⚠ 不含凭据脱敏：`message` 来自订阅层，已经过 `SubscriptionFetchPolicy.redactUrl`；
 * 本类不接收 URL，也不拼接任何订阅原文。
 */
export class ImportFailureSummary {
  /** 一行原因的最大显示长度（toast 常见可视宽度；超出加省略号） */
  static readonly MAX_LENGTH: number = 88;

  /**
   * 折叠成一行：空白归一（含换行）→ 去首尾空白 → 超长截断加 `…`。
   *
   * @param reason 原始原因（可为空串）
   * @returns 可直接放进 toast 的一行文本（空串表示没有原因）
   */
  static brief(reason: string): string {
    const oneLine: string = reason.replace(/\s+/g, ' ').trim();
    if (oneLine.length <= ImportFailureSummary.MAX_LENGTH) {
      return oneLine;
    }
    return `${oneLine.substring(0, ImportFailureSummary.MAX_LENGTH)}…`;
  }

  /**
   * 拼装失败提示：`<前缀>｜<原因>`；没有原因时**只返回前缀**，
   * 不会留下孤零零的分隔符。
   *
   * @param prefix 场景前缀，例如 `导入失败：a.yaml`
   * @param reason 原始原因（空串表示未知）
   */
  static line(prefix: string, reason: string): string {
    const brief: string = ImportFailureSummary.brief(reason);
    return brief.length > 0 ? `${prefix}｜${brief}` : prefix;
  }
}
