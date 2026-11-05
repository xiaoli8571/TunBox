import { AbilityStage } from '@kit.AbilityKit';
import { ProcessRecovery } from '../commons/services/ProcessRecovery';
import { StageSessionRecovery } from '../commons/services/StageSessionRecovery';

export default class EntryStage extends AbilityStage {
  onCreate(): void {
    ProcessRecovery.install();
    StageSessionRecovery.restore(this.context);
  }
}
