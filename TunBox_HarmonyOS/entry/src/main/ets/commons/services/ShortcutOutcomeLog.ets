/**
 * 无界面快捷入口（桌面「启动代理」静态快捷方式）执行结果的可观测通道。
 *
 * 背景：QuickToggleAbility 不加载任何页面，用户看不到任何 UI；出问题时只能靠
 * hilog，而 hilog 缓冲区会被桌面（sceneboard）日志淹没、且随会话消失。这里额外
 * 把「最后一次执行结果 + 失败原因 + 耗时」落到应用私有 cacheDir 的有界状态文件，
 * 便于事后取证（真机可直接读，无需 root）：
 *
 *   hdc shell cat /data/app/el2/100/base/com.tunbox.client/haps/entry/cache/vpn_shortcut_outcome.txt
 *
 * 约束：
 *  - 绝不外抛异常：可观测通道不得反过来破坏 VPN 主流程；
 *  - 有界：最多保留 SHORTCUT_OUTCOME_MAX_LINES 行，超出丢弃最旧行；
 *  - 只记录模式/结果/原因/耗时，不写节点凭据、配置内容或密钥。
 */
import { AppLogger } from '../utils/AppLogger';
import { ensurePrivateDir, privateFs } from './PrivateFileStore';
import { MAX_STATE_FILE_BYTES } from './RuntimeFilePolicy';

const TAG = 'ShortcutOutcome';
export const SHORTCUT_OUTCOME_FILE = 'vpn_shortcut_outcome.txt';
export const SHORTCUT_OUTCOME_MAX_LINES = 40;

/** 一次无界面快捷执行的终态记录（显式类，满足 arkts-no-untyped-obj-literals） */
export class ShortcutOutcomeRecord {
  /** 记录时间戳（毫秒） */
  at: number = 0;
  /** 请求模式：start（只连接）/ toggle（切换） */
  mode: string = '';
  /** 终态：on / off / already / no_node / failed */
  result: string = '';
  /** 判定原因（来自 VpnQuickStart.lastDetail），失败时即失败原因 */
  detail: string = '';
  /** 本次执行耗时（毫秒） */
  elapsedMs: number = 0;
}

/** 时间戳转 ISO 文本；非法输入返回空串（纯函数，可单测） */
export function isoTime(atMs: number): string {
  if (!Number.isFinite(atMs) || atMs <= 0) {
    return '';
  }
  return new Date(atMs).toISOString();
}

/** 单行格式化：<iso时间> mode=<m> result=<r> reason=<d> elapsed=<n>ms（纯函数） */
export function formatOutcomeLine(record: ShortcutOutcomeRecord): string {
  const detail = record.detail.length > 0 ? record.detail : '-';
  return `${isoTime(record.at)} mode=${record.mode} result=${record.result} `
    + `reason=${detail} elapsed=${record.elapsedMs}ms`;
}

/**
 * 有界追加：把 line 追加到 previous 之后，只保留最后 maxLines 行，
 * 返回以 '\n' 结尾的文本。纯函数，便于日志轮转的专项单测。
 */
export function appendBounded(previous: string, line: string, maxLines: number): string {
  const body = previous.length > 0 ? previous.trim() : '';
  const lines: string[] = body.length > 0 ? body.split('\n') : [];
  lines.push(line);
  const keep = maxLines > 0 ? maxLines : 1;
  const start = lines.length > keep ? lines.length - keep : 0;
  const kept: string[] = [];
  for (let i = start; i < lines.length; i++) {
    kept.push(lines[i]);
  }
  return `${kept.join('\n')}\n`;
}

export class ShortcutOutcomeLog {
  /** 追加一条结果记录（同时写 hilog 与私有状态文件）；任何失败都不外抛。 */
  static record(context: Context, record: ShortcutOutcomeRecord): void {
    const line = formatOutcomeLine(record);
    AppLogger.info(TAG, line);
    try {
      ensurePrivateDir(context.cacheDir);
      const path = `${context.cacheDir}/${SHORTCUT_OUTCOME_FILE}`;
      const previous = privateFs.readCapped(path, MAX_STATE_FILE_BYTES).text;
      privateFs.writePrivate(path, appendBounded(previous, line, SHORTCUT_OUTCOME_MAX_LINES));
    } catch (error) {
      AppLogger.warn(TAG,
        `outcome file write failed: ${AppLogger.errText(error)}`);
    }
  }

  /** 读取历史记录（诊断/专项验证用）；无文件返回空数组。 */
  static read(context: Context): string[] {
    const path = `${context.cacheDir}/${SHORTCUT_OUTCOME_FILE}`;
    const text = privateFs.readCapped(path, MAX_STATE_FILE_BYTES).text;
    const body = text.trim();
    if (body.length === 0) {
      return [];
    }
    return body.split('\n');
  }
}
