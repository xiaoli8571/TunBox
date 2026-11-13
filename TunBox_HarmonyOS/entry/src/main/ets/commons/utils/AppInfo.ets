/**
 * 应用版本信息（单一来源: AppScope/app.json5 的 versionName）
 *
 * 通过 bundleManager 运行时读取自身包信息 —— 此前 HomePage/SubscriptionPage/
 * UpdateChecker/FetchPolicy 四处硬编码 '4.0.28', 升版本时全部漏改导致
 * "关于/底部版本不更新、检查更新比对错版本"。以后只需改 app.json5。
 */
import { bundleManager } from '@kit.AbilityKit';

export class AppInfo {
  private static cached: string = '';

  /** versionName（如 "4.0.34"）；取不到时返回 "0.0.0" */
  static version(): string {
    if (AppInfo.cached.length === 0) {
      try {
        const info = bundleManager.getBundleInfoForSelfSync(
          bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
        const name = info.versionName;
        AppInfo.cached = name.length > 0 ? name : '0.0.0';
      } catch (e) {
        AppInfo.cached = '0.0.0';
      }
    }
    return AppInfo.cached;
  }
}
