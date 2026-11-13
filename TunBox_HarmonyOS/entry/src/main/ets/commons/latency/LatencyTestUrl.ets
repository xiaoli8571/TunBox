/**
 * 测速 URL 的**单一真源**（零依赖 —— 任何层都能安全 import）。
 *
 * ## 为什么单独一个文件（而不是放在 LatencyProbe.ets 里）
 *
 * 规则本体必须**零 import**：
 *  - `services/`（SettingsService、BackgroundLatencyService、ClashConfigGenerator）、
 *    `pages/`（节点页）、`models/`（AppSettings）都要引用它；
 *  - 如果它住在 `LatencyProbe.ets` 里，而 `LatencyProbe.ets` 又 import 了
 *    `models/AppSettings`（`models` → `services/NodeSortPersistence` → …），
 *    那么 `services/SettingsService` 一 import 就可能形成
 *    services → latency → models → services 的**循环依赖**。
 *  - 零 import 的纯函数文件从根上杜绝这件事：谁都能引，引谁都安全。
 *
 * ## 规则（精确匹配 + 单向，绝不改写用户的合法配置）
 *
 *  - 恰好等于本客户端历史上写过的两个 http 默认值 → 升级为对应 https
 *    （存量用户落盘的旧默认值在**加载**时也会被迁移，用户不需要手动改；
 *      这里再兜一次，保证「直接调本函数」与「加载期迁移」口径一致）；
 *  - 其余任何值（用户自填的 http、https、带路径/参数/端口的地址）→ **原样保留**；
 *  - 空串 / 非法值（不是 `http(s)://` 开头的地址 / 超长）→ 回落默认 https。
 *
 * ## 为什么不把用户自填的 http 改成 https
 *
 * 真机 commit `a3fe45d` 实证：个别出口会掐 gstatic 的 TLS SNI —— 同一个出口
 * **https Timeout 而 http 1158ms**。用户自填 http 是有意为之，客户端无权替他改。
 *
 * ## 为什么默认必须是 https
 *
 * 明文测速地址会被机场/落地劫持（mihomo 官方点名 `provider.health-check.url` /
 * `group.url` 应使用 HTTPS），5.6.0 真机基线也是 https。
 *
 * ⚠ 本类**绝不**把 https 降级回 http：用户手填 https 是明确意图。
 *
 * ## 调用方（前台批 / 后台批 / smart 组 / 内核健康检查）必须走这里
 *
 * ⚠ 仓库里**不允许**出现第二份实现（审计 F12）。闸门：
 * `scripts/verify-latency-core-v2.mjs` 的 A12（规则唯一 + 调用点不自带规则）。
 */
export class LatencyTestUrl {
  /** 默认测速地址（与 FlClash 出厂默认同值） */
  static readonly DEFAULT_URL: string = 'https://www.gstatic.com/generate_204';
  /** 备用测速地址（**不会自动回退**；见类注释） */
  static readonly ALT_URL: string = 'https://cp.cloudflare.com/generate_204';
  /** 历史默认值（http）：升级到 https */
  static readonly LEGACY_GSTATIC_HTTP: string = 'http://www.gstatic.com/generate_204';
  /** 历史默认值（http）：升级到 https */
  static readonly LEGACY_CLOUDFLARE_HTTP: string = 'http://cp.cloudflare.com/generate_204';
  /** URL 长度上限（超过视为非法 → 回落默认） */
  static readonly MAX_LENGTH: number = 2048;

  /** 是否是一个合法的 http(s) 测速地址 */
  static isValid(raw: string): boolean {
    return raw.length > 0 && raw.length <= LatencyTestUrl.MAX_LENGTH && /^https?:\/\/\S+$/.test(raw);
  }

  /**
   * **单一真源**：从任意原始值推导本轮测速 URL。
   *
   * 前台批 / 后台批 / smart 组 / 内核健康检查**全部**走这一个函数。
   */
  static effective(raw: string): string {
    const v: string = raw === undefined || raw === null ? '' : raw.trim();
    if (v.length === 0) {
      return LatencyTestUrl.DEFAULT_URL;
    }
    if (v === LatencyTestUrl.LEGACY_GSTATIC_HTTP) {
      return 'https://www.gstatic.com/generate_204';
    }
    if (v === LatencyTestUrl.LEGACY_CLOUDFLARE_HTTP) {
      return 'https://cp.cloudflare.com/generate_204';
    }
    if (!LatencyTestUrl.isValid(v)) {
      return LatencyTestUrl.DEFAULT_URL;
    }
    return v;
  }
}
