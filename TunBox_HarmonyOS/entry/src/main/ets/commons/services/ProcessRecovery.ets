import { appRecovery } from '@kit.AbilityKit';
import { AppLogger } from '../utils/AppLogger';

/** 系统支持的 JS 崩溃/冻屏恢复；SIGKILL/强行停止不属于此 API 的恢复承诺。 */
export class ProcessRecovery {
  private static installed: boolean = false;

  static install(): void {
    if (ProcessRecovery.installed) { return; }
    try {
      appRecovery.enableAppRecovery(appRecovery.RestartFlag.ALWAYS_RESTART,
        appRecovery.SaveOccasionFlag.SAVE_WHEN_ERROR | appRecovery.SaveOccasionFlag.SAVE_WHEN_BACKGROUND,
        appRecovery.SaveModeFlag.SAVE_WITH_FILE);
      // 故障重启始终消费持久连接意图，不能重放快捷宿主的 toggle 动作。
      appRecovery.setRestartWant({
        bundleName: 'com.tunbox.client',
        abilityName: 'EntryAbility'
      });
      ProcessRecovery.installed = true;
      AppLogger.info('ProcessRecovery', 'system fault recovery enabled; connection intent decides VPN restore');
    } catch (e) {
      AppLogger.warn('ProcessRecovery', `system fault recovery unavailable: ${AppLogger.errText(e)}`);
    }
  }
}
