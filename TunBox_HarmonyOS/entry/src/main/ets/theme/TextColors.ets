/**
 * TunBox 文本色彩统一色板（2026-10-30 用户定稿）
 *
 * 背景：首页 / 数据页 / 设置页原先散落 #9CA3AF、#94A3B8、#6B7280 等大量浅灰
 * 字色，在浅蓝灰底（#EFF3FA）与白卡上对比度不足——10~12vp 小字尤其发虚。
 * 本文件把这些字色收敛成一套语义 token，作为三个核心页面及其子组件的**唯一来源**。
 *
 * 使用约束（用户明确要求）：
 *   1. 只用于 `Text` 组件的 `.fontColor(...)`（以及作为文本语义的色参），
 *      **不要**拿来改背景、边框、图标 fillColor；
 *   2. 浅色模式下的取值即用户给定的规格值；深色模式自动映射到等效亮度，
 *      避免深色底上出现"黑字黑底"。
 *
 * 与 `TunBoxColors`（theme/TunBoxTokens.ets）的分工：
 *   - `TunBoxColors`       = 主题/材质/容器色（背景、卡片、描边、dock 玻璃…）
 *   - `TunBoxTextColors`   = 纯文本前景色（本文件），语义更细、对比度更高
 */

import { ThemeService } from './ThemeService';

export class TunBoxTextColors {
  /** L1 主标题 / 关键数值（如「内存占用」的 268 MB、节点名、订阅名） */
  static get primary(): string {
    return ThemeService.isDark() ? '#F8FAFC' : '#0F172A';
  }

  /** L2 次级正文（项目名、描述性说明、时间戳等需要读清的辅助信息） */
  static get secondary(): string {
    return ThemeService.isDark() ? '#A8B6C8' : '#334155';
  }

  /** L3 弱化注释 / 底部说明（**最小可用对比度**，不要比它更浅） */
  static get muted(): string {
    return ThemeService.isDark() ? '#7C8CA3' : '#475569';
  }

  /** 强调蓝：上行流量、选中态文字、可点击链接 */
  static get accentBlue(): string {
    return ThemeService.isDark() ? '#60A5FA' : '#0284C7';
  }

  /** 强调绿：下行流量、「使用中」等正向状态文字 */
  static get accentGreen(): string {
    return ThemeService.isDark() ? '#34D399' : '#059669';
  }

  /** 绿色标签底色（「使用中」微型胶囊） */
  static get tagBgGreen(): string {
    return ThemeService.isDark() ? 'rgba(5,150,105,0.22)' : '#E6F4EA';
  }

  /** 绿色标签文字（与 tagBgGreen 成对使用） */
  static get tagTextGreen(): string {
    return ThemeService.isDark() ? '#6EE7B7' : '#047857';
  }
}
