import { AppSettings, CustomRuleSet } from './AppSettings';

/** 只传规则编辑字段；进入页面前准备好，避免首帧后回填开关和按钮状态。 */
export class RulesEditorSnapshot {
  rulesEnabled: boolean = true;
  hyperAdRulesEnabled: boolean = false;
  customRules: string[] = [];
  customRuleSets: CustomRuleSet[] = [];
  yamlOverride: string = '';

  static fromSettings(settings: AppSettings): RulesEditorSnapshot {
    const result = new RulesEditorSnapshot();
    result.rulesEnabled = settings.rulesEnabled;
    result.hyperAdRulesEnabled = settings.hyperAdRulesEnabled;
    result.customRules = settings.customRules.slice();
    result.customRuleSets = AppSettings.normalizeRuleSets(settings.customRuleSets);
    result.yamlOverride = settings.yamlOverride;
    return result;
  }
}

export class RulesPageParams {
  initialRules: RulesEditorSnapshot | null = null;
}
