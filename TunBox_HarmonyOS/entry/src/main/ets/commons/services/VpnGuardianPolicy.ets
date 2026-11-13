/**
 * 会话守护者判定策略（纯逻辑，可离线执行验证）。
 *
 * 背景（2026-09-18 真机日志实证）：`:vpn` 扩展进程不持有驻留资格 —— 长时任务只能由
 * UIAbility 上下文申请（扩展里调用必然 401），卡片宿主（Form）进程被系统回收后，
 * 整个应用组失去前台/任务凭证，`:vpn` 在 0.3 秒内被连带回收（exit code 0）。
 * 修法：卡片点击路由到 QuickToggleAbility（无界面 UIAbility），由它在连接成功后
 * 用自身 UIAbility 上下文注册 dataTransfer 连续任务，成为会话守护者；连接终止时释放。
 */
export class VpnGuardianPolicy {
  /** 动作结果是否意味着“此刻存在一条需要守护的会话”（连接成功 / 幂等发现已连接） */
  static shouldGuard(result: string): boolean {
    return result === 'on' || result === 'already';
  }

  /** 权威状态连续缺失达到阈值才判定会话终结（容忍瞬时读失败/切换抖动） */
  static shouldReleaseOnLeaseLoss(consecutiveMisses: number, threshold: number): boolean {
    return threshold > 0 && consecutiveMisses >= threshold;
  }

  /** 缺失计数归一：非法值回落到 0，负值钳位，非整数向下取整 */
  static normalizeMisses(raw: number): number {
    if (!Number.isFinite(raw) || raw < 0) {
      return 0;
    }
    return Math.floor(raw);
  }
}
