import { appManager } from '@kit.AbilityKit';
import process from '@ohos.process';
import { ConnectionOrchestrator } from './ConnectionOrchestrator';
import { PersistentLogStore } from './PersistentLogStore';
import { AppLogger } from '../utils/AppLogger';

/** 系统重建主进程但未创建 UIAbility 时，也消费尚未结束的连接意图。 */
export class StageSessionRecovery {
  private static uiLaunched: boolean = false;

  static noteUiLaunch(): void {
    StageSessionRecovery.uiLaunched = true;
  }

  static async restore(context: Context): Promise<void> {
    try {
      // API 11+ 只查询本应用进程信息，无需 GET_RUNNING_INFO 等受限权限。
      const infos = await appManager.getRunningProcessInformation();
      if (StageSessionRecovery.uiLaunched) { return; }
      const current = infos.find((info: appManager.ProcessInformation): boolean => info.pid === process.pid);
      // VPN/Form/Work 进程绝不创建第二个编排器恢复链。
      if (current === undefined || current.processName !== 'com.tunbox.client') { return; }
      PersistentLogStore.init(context, 'app');
      const reason = await ConnectionOrchestrator.instance().restoreKilledSession(context);
      AppLogger.info('StageSessionRecovery', `background process restore: ${reason}`);
    } catch (e) {
      AppLogger.warn('StageSessionRecovery', `background restore skipped: ${AppLogger.errText(e)}`);
    }
  }
}
