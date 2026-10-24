/**
 * 常驻通知（对应 upstream VpnNotificationSupport / NotificationUpdatePolicy）
 * 连接期间显示节点名与实时速率；每秒由编排器刷新。
 *
 * 通知被系统禁用时（错误码 1600004 / "disabled"）不再每秒重试造成日志与
 * 调度风暴：进入退避窗口（默认 60s）内直接跳过，窗口结束后再探测一次；
 * 通知重新可用（或主动 cancel/重连）即恢复。可观察状态经 isSuppressed() 暴露。
 */
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'TunBoxNotifier';
const NOTIFICATION_ID = 1001;
/** 通知被禁用后的退避时长：避免每秒 publish 失败风暴 */
const DISABLED_BACKOFF_MS = 60000;

export class TunBoxNotifier {
  private static lastText: string = '';
  private static lastUpdateAt: number = 0;
  /** 退避截止时间戳（>now 表示通知当前不可用，跳过 publish） */
  private static disabledUntil: number = 0;
  /** 最近一次失败错误码（0 表示无失败），供 UI/诊断读取 */
  private static lastErrorCode: number = 0;
  /** 点击通知回前台的 WantAgent（懒构建、进程内复用；构建失败不影响通知发布） */
  private static clickAgent: WantAgent | null = null;
  private static agentBuilding: boolean = false;
  /** 通知授权是否已问过（每进程一次；用户拒绝后系统不允许再弹框） */
  private static permissionRequested: boolean = false;

  /**
   * 通知权限从未授予时弹一次系统授权框（连接成功时调用）。
   * 真机日志实锤：通知权限未授予时 publish 一直 1600004（disabled），通知栏
   * 只剩系统自己的 VPN 通知（只有运行时长）。isNotificationEnabled() 对
   * 「从未问过」与「用户已拒绝」都返回 false；拒绝后 requestEnableNotification
   * 无法再弹框（系统限制），失败静默——发布路径的退避语义不变。
   */
  static async ensurePermission(context: Context): Promise<void> {
    if (TunBoxNotifier.permissionRequested) {
      return;
    }
    TunBoxNotifier.permissionRequested = true;
    try {
      const enabled = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        await notificationManager.requestEnableNotification(context as common.UIAbilityContext);
      }
    } catch (e) {
      AppLogger.warn(TAG, `notify permission request failed: ${AppLogger.errText(e)}`);
    }
  }

  /** 通知当前是否因被禁用而处于退避抑制状态 */
  static isSuppressed(): boolean {
    return Date.now() < TunBoxNotifier.disabledUntil;
  }

  /** 最近一次通知失败错误码（0=无失败）；1600004 表示通知被用户/系统禁用 */
  static lastCode(): number {
    return TunBoxNotifier.lastErrorCode;
  }

  /**
   * 懒构建「点击通知 → EntryAbility」的 WantAgent。
   * 官方《连接VPN》指南要求"点击该通知能够将您的VPN应用调入前台"；
   * 构建失败只记录并返回 null：通知照常发布，仅缺点击动作。
   */
  private static async ensureClickAgent(): Promise<WantAgent | null> {
    if (TunBoxNotifier.clickAgent !== null) {
      return TunBoxNotifier.clickAgent;
    }
    if (TunBoxNotifier.agentBuilding) {
      return null;
    }
    TunBoxNotifier.agentBuilding = true;
    try {
      const agentRequest: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: 'com.tunbox.client',
          moduleName: 'entry',
          abilityName: 'EntryAbility'
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      TunBoxNotifier.clickAgent = await wantAgent.getWantAgent(agentRequest);
      return TunBoxNotifier.clickAgent;
    } catch (e) {
      AppLogger.warn(TAG, `click agent build failed: ${AppLogger.errText(e)}`);
      return null;
    } finally {
      TunBoxNotifier.agentBuilding = false;
    }
  }

  static async update(title: string, nodeLine: string, speedLine: string): Promise<void> {
    const now = Date.now();
    // 退避窗口内直接返回：通知禁用属于用户设置，重试没有意义
    if (now < TunBoxNotifier.disabledUntil) {
      return;
    }
    // 节流：内容未变化或距上次刷新不足 900ms 则跳过
    const text = `${nodeLine}\n${speedLine}`;
    if (text === TunBoxNotifier.lastText && now - TunBoxNotifier.lastUpdateAt < 900) {
      return;
    }
    TunBoxNotifier.lastText = text;
    TunBoxNotifier.lastUpdateAt = now;
    try {
      const contentBody: notificationManager.NotificationBasicContent = {
        title: title,
        text: speedLine,
        additionalText: nodeLine
      };
      const request: notificationManager.NotificationRequest = {
        id: NOTIFICATION_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: contentBody
        },
        isOngoing: true,
        isUnremovable: true
      };
      // 官方 VPN 指南要求：点击通知将应用调入前台（wantAgent 默认为空 = 点击无动作）
      const agent = await TunBoxNotifier.ensureClickAgent();
      if (agent !== null) {
        request.wantAgent = agent;
      }
      await notificationManager.publish(request);
      TunBoxNotifier.lastErrorCode = 0;
      TunBoxNotifier.disabledUntil = 0;
    } catch (e) {
      const err = e as BusinessError;
      const code = (err !== undefined && err !== null) ? err.code : 0;
      const message = (err !== undefined && err !== null) ? err.message : String(e);
      TunBoxNotifier.lastErrorCode = code;
      // 1600004 = 通知已被禁用；同类文案也一并识别，进入退避窗口
      const disabled = code === 1600004 || message.indexOf('disabled') >= 0
        || message.indexOf('not enabled') >= 0;
      if (disabled) {
        TunBoxNotifier.disabledUntil = now + DISABLED_BACKOFF_MS;
        AppLogger.warn(TAG, `notify disabled (code=${code}); backing off ${DISABLED_BACKOFF_MS}ms`);
      } else {
        AppLogger.warn(TAG, `notify failed: code=${code} ${message}`);
      }
    }
  }

  static async cancel(): Promise<void> {
    try {
      await notificationManager.cancel(NOTIFICATION_ID);
    } catch (e) {
      // 忽略：通知可能本就不存在
    }
    TunBoxNotifier.lastText = '';
    TunBoxNotifier.lastUpdateAt = 0;
    TunBoxNotifier.disabledUntil = 0;
  }
}
