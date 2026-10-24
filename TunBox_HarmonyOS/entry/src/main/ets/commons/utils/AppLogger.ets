/**
 * 日志工具：有界文件日志 + 脱敏
 * 移植自 upstream: packages/tunbox_shared/lib/utils/app_logger.dart
 *                packages/tunbox_shared/lib/utils/bounded_file_logger.dart
 *                packages/tunbox_shared/lib/utils/log_redactor.dart
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN: number = 0x5256; // "SR"
// Keep enough recent diagnostics for troubleshooting without retaining thousands of
// timestamped strings for the full lifetime of the UI process.
const MAX_FILE_LINES = 1000;
const TRIM_TO_LINES = 500;

export class AppLogger {
  private static lines: string[] = [];
  private static listeners: ((line: string) => void)[] = [];

  static info(tag: string, message: string): void {
    AppLogger.log('INFO', tag, message);
  }

  static warn(tag: string, message: string): void {
    AppLogger.log('WARN', tag, message);
  }

  static error(tag: string, message: string): void {
    AppLogger.log('ERROR', tag, message);
  }

  /**
   * 错误 → 人类可读文本（修复真机「VPN 启动异常: [object Object]」与
   * 「latency request error: error=[object Object]」类问题）。ArkTS 系统 API
   * 抛出的大量错误是普通对象（BusinessError 形态：{code,name,message}），
   * 并非 Error 实例，惯用写法 `String(e)` 只会渲染成 "[object Object]"。
   * 这里统一提取 message（附带非零 code），两者皆无时给出占位文案。
   * 全工程用户可见/日志的错误文本一律走本函数。
   */
  static errText(e: Object): string {
    try {
      if (e === null || e === undefined) {
        return '未知错误（错误对象为空）';
      }
      const biz = e as BusinessError;
      const msg: string = (typeof biz.message === 'string') ? biz.message : '';
      const code: number = (typeof biz.code === 'number') ? biz.code : 0;
      if (msg.length > 0) {
        return code !== 0 ? `code=${code} ${msg}` : msg;
      }
      if (code !== 0) {
        return `code=${code}`;
      }
      const s = String(e);
      return (s.length === 0 || s === '[object Object]') ? '未知错误（错误对象不含文本或代码）' : s;
    } catch (_castErr) {
      try {
        return String(e);
      } catch (_e2) {
        return '未知错误（错误对象不可序列化）';
      }
    }
  }

  private static log(level: string, tag: string, message: string): void {
    const safe = LogRedactor.redact(message);
    const line = `${new Date().toISOString()} ${level} ${tag}: ${safe}`;
    AppLogger.lines.push(line);
    if (AppLogger.lines.length > MAX_FILE_LINES) {
      // 有界日志：超过上限裁剪到保留行数（对应 bounded_file_logger）
      AppLogger.lines.splice(0, AppLogger.lines.length - TRIM_TO_LINES);
    }
    for (const l of AppLogger.listeners) {
      l(line);
    }
    if (level === 'ERROR') {
      hilog.error(DOMAIN, tag, '%{public}s', safe);
    } else if (level === 'WARN') {
      hilog.warn(DOMAIN, tag, '%{public}s', safe);
    } else {
      hilog.info(DOMAIN, tag, '%{public}s', safe);
    }
  }

  static dump(): string[] {
    return AppLogger.lines.slice();
  }

  static addListener(listener: (line: string) => void): void {
    // Page lifecycle callbacks can be repeated. Do not keep duplicate closures alive.
    if (!AppLogger.listeners.includes(listener)) {
      AppLogger.listeners.push(listener);
    }
  }

  static removeListener(listener: (line: string) => void): void {
    const idx = AppLogger.listeners.indexOf(listener);
    if (idx >= 0) {
      AppLogger.listeners.splice(idx, 1);
    }
  }

  static clear(): void {
    AppLogger.lines = [];
  }
}

/** 日志脱敏，移植自 log_redactor.dart：抹去 URL/密码/密钥类敏感字段 */
export class LogRedactor {
  private static patterns: [RegExp, string][] = [
    [/(password|secret|token|api[_-]?key|authorization)\s*[=:]\s*\S+/gi, '$1=***'],
    [/(ssr?:\/\/)[^\s]+/gi, '$1***'],
    [/\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/g, '<ip>']
  ];

  static redact(message: string): string {
    let out = message;
    for (const pair of LogRedactor.patterns) {
      out = out.replace(pair[0], pair[1]);
    }
    return out;
  }
}
