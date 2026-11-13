/** 官方发布源及更新检查；失败与无更新是不同结果。 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { AppInfo } from '../utils/AppInfo';

export const RELEASE_REPOSITORY: string = 'xiaoli8571/Nexus-VPN-HarmonyOS';
export const RELEASES_PAGE: string = 'https://github.com/' + RELEASE_REPOSITORY + '/releases';
const RELEASES_API = 'https://api.github.com/repos/' + RELEASE_REPOSITORY + '/releases/latest';

export class UpdateCheckResult {
  ok: boolean = false;
  latest: string = '';
  available: boolean = false;
  message: string = '';
  releaseUrl: string = RELEASES_PAGE;
}

export class UpdateChecker {
  static async check(): Promise<UpdateCheckResult> {
    const out = new UpdateCheckResult();
    const req = http.createHttp();
    try {
      const headers: Record<string, string> = {};
      headers['User-Agent'] = 'TunBox-HarmonyOS';
      headers['Accept'] = 'application/vnd.github+json';
      const resp = await req.request(RELEASES_API, {
        method: http.RequestMethod.GET, header: headers,
        connectTimeout: 8000, readTimeout: 10000, usingCache: false
      });
      let body: string = '';
      if (typeof resp.result === 'string') {
        body = resp.result;
      } else if (resp.result instanceof ArrayBuffer) {
        body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
      }
      if (resp.responseCode !== 200 || body.length === 0 || body.length > 1024 * 1024) {
        out.message = resp.responseCode === 403 || resp.responseCode === 429
          ? '更新服务暂时限流，请稍后重试' : `更新检查失败（HTTP ${resp.responseCode}）`;
        return out;
      }
      const json = JSON.parse(body) as Record<string, Object>;
      const tag = json['tag_name'];
      if (typeof tag !== 'string' || !UpdateChecker.validVersion(tag)) {
        out.message = '发布版本信息无效';
        return out;
      }
      out.latest = UpdateChecker.normalize(tag);
      out.available = UpdateChecker.hasUpdate(out.latest);
      out.ok = true;
      out.message = out.available ? `发现新版本 ${out.latest}` : '当前已是最新版本';
      return out;
    } catch (e) {
      out.message = '无法访问更新服务，请检查网络后重试';
      return out;
    } finally {
      req.destroy();
    }
  }

  /** 兼容旧调用；新 UI 使用 check()，不把空串当作已是最新版。 */
  static async latestVersion(): Promise<string> {
    const result = await UpdateChecker.check();
    return result.ok ? result.latest : '';
  }

  static validVersion(version: string): boolean {
    return /^v?\d+(\.\d+){1,3}$/i.test(version.trim());
  }

  static hasUpdate(latest: string): boolean {
    return UpdateChecker.validVersion(latest) && UpdateChecker.compare(latest, UpdateChecker.currentVersion()) > 0;
  }

  static compare(a: string, b: string): number {
    if (!UpdateChecker.validVersion(a) || !UpdateChecker.validVersion(b)) {
      return 0;
    }
    const pa = UpdateChecker.normalize(a).split('.').map((x: string): number => Number(x));
    const pb = UpdateChecker.normalize(b).split('.').map((x: string): number => Number(x));
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
      const va = i < pa.length ? pa[i] : 0;
      const vb = i < pb.length ? pb[i] : 0;
      if (va !== vb) {
        return va > vb ? 1 : -1;
      }
    }
    return 0;
  }

  static normalize(tag: string): string {
    return tag.trim().replace(/^v/i, '');
  }

  static currentVersion(): string {
    return UpdateChecker.normalize(AppInfo.version());
  }
}
