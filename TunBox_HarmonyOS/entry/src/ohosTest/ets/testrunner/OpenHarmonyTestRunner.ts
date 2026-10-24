/**
 * hypium 单元测试 Runner（ohosTest 模块入口）。
 *
 * 修复说明：本文件原为 DevEco 早期模板，与 API 26 SDK 已不兼容 ——
 * `@ohos.application.testRunner` 导出的 TestRunner 是 **interface**（只有
 * onPrepare/onRun，旧模板写成了 `extends` 并实现不存在的 onPreparing/onRunning），
 * 且 `AbilityDelegator` 从未提供 `run()`（真机执行需自行 startAbility 拉起
 * TestAbility），`sendState()` 同样不存在。这里按当前 SDK 契约重写，
 * 使 entry/src/ohosTest 下的用例（LogicTest + VpnArchTest）可真正编译运行。
 *
 * bundleName 取运行期注入的 AbilityDelegatorArgs，不硬编码，避免换包名即失效。
 */
import TestRunner from '@ohos.application.testRunner';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import type Want from '@ohos.app.ability.Want';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'TunBoxTestRunner';
const TEST_ABILITY_NAME: string = 'TestAbility';

export default class OpenHarmonyTestRunner implements TestRunner {
  onPrepare(): void {
    hilog.info(0x0000, TAG, 'onPrepare: test environment ready');
  }

  onRun(): void {
    const args = AbilityDelegatorRegistry.getArguments();
    const delegator = AbilityDelegatorRegistry.getAbilityDelegator();
    // 把 `aa test` 下发的参数（-m 模块名 / -s 套件 / -c 用例）原样透传给 TestAbility，
    // hypium 依赖它们决定跑哪个套件；Want.parameters 是 Record<string, Object>，
    // 而 args.parameters 是 Record<string, string>，逐键复制以通过严格类型检查。
    const parameters: Record<string, Object> = {};
    const incoming: Record<string, string> = args.parameters;
    if (incoming !== undefined && incoming !== null) {
      for (const key of Object.keys(incoming)) {
        parameters[key] = incoming[key];
      }
    }
    const want: Want = {
      bundleName: args.bundleName,
      abilityName: TEST_ABILITY_NAME,
      parameters: parameters
    };
    delegator.startAbility(want).then((): void => {
      hilog.info(0x0000, TAG, 'TestAbility started, running hypium suites');
    }).catch((e: Object): void => {
      hilog.error(0x0000, TAG, `startAbility failed: ${e instanceof Error ? e.message : String(e)}`);
    });
  }
}
