/**
 * 订阅配额提醒（对齐主流客户端的"流量不足/即将到期"通知）
 *
 * 纯逻辑评估与通知副作用分离：evaluate() 不碰任何系统能力（可单测/离线验证），
 * run() 负责读设置、发系统通知、持久化"当天已提醒"标记。
 *
 * 触发阈值（与主流客户端口径一致）：
 *  - 到期：expireAt 距今 ≤ 3 天（含已过期）
 *  - 流量：total > 0 且剩余 ≤ max(10% total, 1GB)
 *
 * 去重：每订阅每类别每天最多提醒一次（marks 持久化进设置 JSON，
 * 键为 `${subId}:${expire|traffic}:${dayKey}`，旧标记自动清理）。
 */
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLogger } from '../utils/AppLogger';
import { Subscription } from '../models/Subscription';
import { SettingsService } from './SettingsService';
import { AppSettings } from '../models/AppSettings';

const TAG = 'SubscriptionQuotaService';
/** 基础通知 ID（每个告警 +1，最多并发 8 条） */
const NOTIFICATION_ID_BASE = 1030;
/** marks 中超过 30 天的旧标记在下次评估时清理 */
const MARK_RETENTION_MS = 30 * 86400000;
/** 单次评估最多发出的通知条数上限（防订阅很多时通知风暴） */
const MAX_NOTIFICATIONS_PER_RUN = 8;

export class QuotaAlert {
  subscriptionId: string = '';
  subscriptionName: string = '';
  /** 用户可读告警文本 */
  text: string = '';
  /** 去重键：`${subId}:${category}:${dayKey}` */
  dedupeKey: string = '';
}

export class QuotaEvaluation {
  alerts: QuotaAlert[] = [];
  /** 清理+新增后的完整标记 JSON（调用方原样持久化） */
  marksJson: string = '';
}

export class SubscriptionQuotaService {
  /** 到期提醒窗口（天） */
  static readonly EXPIRE_WINDOW_DAYS: number = 3;
  /** 流量剩余比例阈值 */
  static readonly TRAFFIC_RATIO: number = 0.1;
  /** 流量剩余绝对值下限（1GB）：大流量套餐 10% 仍很大时按绝对值提醒 */
  static readonly TRAFFIC_FLOOR_BYTES: number = 1024 * 1024 * 1024;

  /** 本地日期键（YYYY-MM-DD），用于"每天最多一次"去重 */
  static dayKey(ms: number): string {
    const d = new Date(ms);
    const mm = `0${d.getMonth() + 1}`.slice(-2);
    const dd = `0${d.getDate()}`.slice(-2);
    return `${d.getFullYear()}-${mm}-${dd}`;
  }

  /** 解析 marks JSON（脏数据一律当作空标记，绝不抛出） */
  private static parseMarks(marksJson: string): Map<string, string> {
    const out = new Map<string, string>();
    if (marksJson.length === 0) {
      return out;
    }
    try {
      const parsed = JSON.parse(marksJson) as Record<string, string>;
      for (const key of Object.keys(parsed)) {
        const value = parsed[key];
        if (typeof value === 'string') {
          out.set(key, value);
        }
      }
    } catch (e) {
      // 标记损坏 → 视为未提醒过，最多多提醒一次，无害
    }
    return out;
  }

  /**
   * 评估订阅配额告警（纯逻辑，无副作用）。
   * @param marksJson 上次持久化的"已提醒"标记
   */
  static evaluate(subs: Subscription[], nowMs: number, marksJson: string): QuotaEvaluation {
    const result = new QuotaEvaluation();
    const marks = SubscriptionQuotaService.parseMarks(marksJson);
    const today = SubscriptionQuotaService.dayKey(nowMs);
    const cutoff = nowMs - MARK_RETENTION_MS;
    const staleEntries = Array.from(marks.entries());
    for (const entry of staleEntries) {
      const key = entry[0];
      const day = entry[1];
      // 旧标记清理：dayKey 格式 YYYY-MM-DD，按字典序比较足够（同格式）
      if (day.length === 10 && day < SubscriptionQuotaService.dayKey(cutoff)) {
        marks.delete(key);
      }
    }
    for (const sub of subs) {
      if (!sub.enabled || sub.url.length === 0) {
        continue;
      }
      // ── 到期告警 ──
      if (sub.expireAt > 0) {
        const daysLeft = Math.floor((sub.expireAt - nowMs) / 86400000);
        let expireText = '';
        if (daysLeft < 0) {
          expireText = `「${sub.name}」订阅已到期`;
        } else if (daysLeft <= SubscriptionQuotaService.EXPIRE_WINDOW_DAYS) {
          const date = SubscriptionQuotaService.dayKey(sub.expireAt);
          expireText = daysLeft === 0
            ? `「${sub.name}」订阅今天到期（${date}）`
            : `「${sub.name}」订阅将在 ${daysLeft} 天内到期（${date}）`;
        }
        if (expireText.length > 0) {
          const dedupeKey = `${sub.id}:expire:${today}`;
          if (marks.get(dedupeKey) !== today) {
            const alert = new QuotaAlert();
            alert.subscriptionId = sub.id;
            alert.subscriptionName = sub.name;
            alert.text = expireText;
            alert.dedupeKey = dedupeKey;
            result.alerts.push(alert);
          }
        }
      }
      // ── 流量告警 ──
      if (sub.totalBytes > 0) {
        const used = Math.max(0, sub.uploadBytes) + Math.max(0, sub.downloadBytes);
        const remaining = sub.totalBytes - used;
        const threshold = Math.max(sub.totalBytes * SubscriptionQuotaService.TRAFFIC_RATIO,
          SubscriptionQuotaService.TRAFFIC_FLOOR_BYTES);
        if (remaining <= threshold) {
          const remainingText = remaining <= 0 ? '已用尽'
            : `剩余不足 ${(SubscriptionQuotaService.TRAFFIC_RATIO * 100).toFixed(0)}%`;
          const dedupeKey = `${sub.id}:traffic:${today}`;
          if (marks.get(dedupeKey) !== today) {
            const alert = new QuotaAlert();
            alert.subscriptionId = sub.id;
            alert.subscriptionName = sub.name;
            alert.text = `「${sub.name}」流量${remainingText}，请及时更新订阅`;
            alert.dedupeKey = dedupeKey;
            result.alerts.push(alert);
          }
        }
      }
    }
    // 新告警写标记（无论最终是否真的发了通知：评估即代表用户已被触达一次）
    for (const alert of result.alerts) {
      marks.set(alert.dedupeKey, today);
    }
    // 序列化（Map → JSON）
    const outObj: Record<string, string> = {};
    const finalEntries = Array.from(marks.entries());
    for (const entry of finalEntries) {
      outObj[entry[0]] = entry[1];
    }
    result.marksJson = JSON.stringify(outObj);
    return result;
  }

  /**
   * 刷新订阅后调用：评估 → 发系统通知 → 持久化标记。
   * 通知开关关闭时只更新标记（跳过 publish，但绝不清空既有标记）。
   */
  static async run(subs: Subscription[]): Promise<void> {
    let settings: AppSettings;
    try {
      settings = await SettingsService.load();
    } catch (e) {
      return;
    }
    const evaluation = SubscriptionQuotaService.evaluate(subs, Date.now(),
      settings.quotaAlertMarks);
    if (evaluation.alerts.length > 0 && settings.quotaNotifyEnabled) {
      const batch = evaluation.alerts.slice(0, MAX_NOTIFICATIONS_PER_RUN);
      let id = NOTIFICATION_ID_BASE;
      for (const alert of batch) {
        const contentBody: notificationManager.NotificationBasicContent = {
          title: '订阅提醒',
          text: alert.text
        };
        const request: notificationManager.NotificationRequest = {
          id: id,
          content: {
            notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
            normal: contentBody
          }
        };
        id = id + 1;
        try {
          await notificationManager.publish(request);
        } catch (e) {
          const err = e as BusinessError;
          AppLogger.warn(TAG, `quota notify failed: code=${err !== undefined ? err.code : 0}`);
        }
      }
      AppLogger.info(TAG, `quota alerts published: ${batch.length}/${evaluation.alerts.length}`);
    }
    // 标记持久化（新增/清理过的 marks 都要写回，即使本次无新告警 —— 清理也是变更）
    if (evaluation.marksJson !== settings.quotaAlertMarks) {
      // 字段级写入：本服务只拥有 quotaAlertMarks 一个字段。旧写法 `settings.xxx = …; save(settings)`
      // 会把 run() 开头 load 的整份快照（可能已经过期）写回磁盘，盖掉期间用户改的节点/开关（审计 F2）。
      // 写锁内再比一次：两个进程/两次刷新并发时，后到者发现自己已不是最新判定就不覆盖。
      try {
        await SettingsService.patchSettings((current: AppSettings): boolean => {
          if (current.quotaAlertMarks === evaluation.marksJson) {
            return false;
          }
          current.quotaAlertMarks = evaluation.marksJson;
          return true;
        });
      } catch (e) {
        // 保存失败只影响去重（可能重复提醒一次），不影响主流程
      }
    }
  }
}
