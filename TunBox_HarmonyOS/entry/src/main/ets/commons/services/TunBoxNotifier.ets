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
/** 内容未变时的重发心跳：卡片若被系统回收（非应用主动撤），最多 60s 内被补回来 */
const RESEND_HEARTBEAT_MS = 60000;

export class TunBoxNotifier {
  private static lastText: string = '';
  private static lastUpdateAt: number = 0;
  /** 最近一次成功发布时间（用于「内容没变但卡片丢了」的兜底重发） */
  private static lastPublishAt: number = 0;
  /** 退避截止时间戳（>now 表示通知当前不可用，跳过 publish） */
  private static disabledUntil: number = 0;
  /** 最近一次失败错误码（0 表示无失败），供 UI/诊断读取 */
  private static lastErrorCode: number = 0;
  /** 点击通知回前台的 WantAgent（懒构建、进程内复用；构建失败不影响通知发布） */
  private static clickAgent: WantAgent | null = null;
  private static agentBuilding: boolean = false;
  /** 本进程是否已弹过系统授权框（系统对同一应用只允许弹一次；仅用于去重） */
  private static permissionPrompted: boolean = false;
  /** 最近一次复核结论：通知是否可用（供 UI 提示 / 诊断读取） */
  private static permissionOk: boolean = true;

  /**
   * 通知可用性复核 —— **每次连接都调用**（2026-10-30 修正）。
   *
   * 旧实现用 `permissionRequested` 在本进程内只查一次：用户点过「暂不」之后，
   * 即便他后来在系统设置里手动打开通知，本进程内也**永远**不再复核 → 速率卡
   * 一直发不出去（通知栏只剩系统长时任务卡：没有速率、没有运行时长）。
   *
   * 真机日志实锤（旧注释保留）：通知未授权时 publish 一直 1600004（disabled）。
   * 现在的语义：
   *  · 每次连接都 `isNotificationEnabled()` 复核（开销极小）；
   *  · 已授予 → 立即解除 1600004 退避并返回 true（调用方据此补发首帧）；
   *  · 未授予且本进程还没弹过 → 弹一次系统框；拒绝后系统不允许再弹，返回 false。
   *
   * @returns true = 通知当前可用（可以发布常驻通知）
   */
  static async ensurePermission(context: Context): Promise<boolean> {
    let enabled = false;
    try {
      enabled = await notificationManager.isNotificationEnabled();
    } catch (e) {
      AppLogger.warn(TAG, `isNotificationEnabled failed: ${AppLogger.errText(e)}`);
      TunBoxNotifier.permissionOk = false;
      return false;
    }
    if (enabled) {
      TunBoxNotifier.permissionOk = true;
      // 用户可能刚在系统设置里打开通知：立刻解除退避，下一帧就能发出去
      TunBoxNotifier.disabledUntil = 0;
      TunBoxNotifier.lastErrorCode = 0;
      return true;
    }
    TunBoxNotifier.permissionOk = false;
    if (TunBoxNotifier.permissionPrompted) {
      return false;
    }
    TunBoxNotifier.permissionPrompted = true;
    try {
      await notificationManager.requestEnableNotification(context as common.UIAbilityContext);
      const granted = await notificationManager.isNotificationEnabled();
      TunBoxNotifier.permissionOk = granted;
      if (granted) {
        TunBoxNotifier.disabledUntil = 0;
        TunBoxNotifier.lastErrorCode = 0;
      }
      return granted;
    } catch (e) {
      AppLogger.warn(TAG, `notify permission request failed: ${AppLogger.errText(e)}`);
      return false;
    }
  }

  /** 通知当前是否可用（最近一次复核 / 发布结论；false 时速率卡发不出去）。 */
  static isAvailable(): boolean {
    return TunBoxNotifier.permissionOk;
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

  /**
   * 发布 / 更新常驻通知。
   *
   * @param force true = 跳过 900ms 节流，强制发一帧。连接成功时的**首帧**必须用它：
   *   内容与上一会话相同（例如刚断开又连同一节点）时，普通调用会被节流掉，
   *   卡片就会停在系统长时任务那张空卡上。
   */
  static async update(title: string, nodeLine: string, speedLine: string,
    force: boolean = false): Promise<void> {
    const now = Date.now();
    // 退避窗口内直接返回：通知禁用属于用户设置，重试没有意义
    if (now < TunBoxNotifier.disabledUntil) {
      return;
    }
    // 节流：内容与上次相同、且 900ms 内刚发过、且距上次成功发布不足 60s → 跳过。
    // 最后一项是兜底心跳：内容没变时也要定期重发，否则卡片一旦被系统回收
    // （权限变更 / 任务重启 / 通知被清理），就再也不会自己回来。
    const text = `${nodeLine}\n${speedLine}`;
    if (!force && text === TunBoxNotifier.lastText && now - TunBoxNotifier.lastUpdateAt < 900
      && now - TunBoxNotifier.lastPublishAt < RESEND_HEARTBEAT_MS) {
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
      TunBoxNotifier.permissionOk = true;
      TunBoxNotifier.lastPublishAt = now;
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
    TunBoxNotifier.lastPublishAt = 0;
    TunBoxNotifier.disabledUntil = 0;
  }
}
