/**
 * 信息卡片补充指标。
 *
 * 内存口径：hidebug.getPss() 返回当前进程实际占用的物理内存（KB）。
 * 该值是实时 PSS，不是应用内存配额；VPN 独立进程不计入当前进程口径。
 *
 * 公网 IP：持久化缓存、单请求互斥、显式超时与低频刷新。普通卡片生命周期
 * 仅读缓存，不发起网络请求；仅用户手动刷新、缓存过期的受控刷新或 VPN 状态
 * 成功切换后异步刷新一次。日志中不记录 IP 地址或响应正文。
 */
import hidebug from '@ohos.hidebug';
import { AppProxyRoute } from './AppProxyRoute';
import { preferences } from '@kit.ArkData';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'FormInfoMetrics';
const PREF_NAME = 'tunbox_form_info';
const KEY_PUBLIC_IP = 'public_ip';
const KEY_PUBLIC_IP_TIME = 'public_ip_time';
const PUBLIC_IP_TTL_MS = 30 * 60 * 1000;
const REQUEST_TIMEOUT_MS = 6000;
const MAX_RESPONSE_BYTES = 16 * 1024;
const PUBLIC_IP_ENDPOINT = 'https://api64.ipify.org?format=json';

class PublicIpPayload {
  ip: string = '';
}

export class FormInfoMetrics {
  private static refreshTask: Promise<string> | null = null;

  static async memoryText(): Promise<string> {
    try {
      const memoryKb = hidebug.getPss();
      if (memoryKb < 0n) {
        return '--';
      }
      const memoryBytes = Number(memoryKb) * 1024;
      if (!Number.isFinite(memoryBytes)) {
        return '--';
      }
      return FormInfoMetrics.formatBytes(memoryBytes);
    } catch (error) {
      AppLogger.warn(TAG, 'get current process PSS failed');
      return '--';
    }
  }

  private static formatBytes(bytes: number): string {
    if (bytes < 1024) {
      return `${Math.round(bytes)} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  static async cachedPublicIp(context: Context): Promise<string> {
    try {
      const store = await preferences.getPreferences(context, { name: PREF_NAME });
      const value = await store.get(KEY_PUBLIC_IP, '') as string;
      return value.length > 0 ? value : '--';
    } catch (error) {
      AppLogger.warn(TAG, 'read public IP cache failed');
      return '--';
    }
  }

  static async refreshPublicIp(context: Context, force: boolean = false): Promise<string> {
    if (FormInfoMetrics.refreshTask !== null) {
      return FormInfoMetrics.refreshTask;
    }
    const task = FormInfoMetrics.refreshExclusive(context, force);
    FormInfoMetrics.refreshTask = task;
    task.finally((): void => {
      if (FormInfoMetrics.refreshTask === task) {
        FormInfoMetrics.refreshTask = null;
      }
    });
    return task;
  }

  static refreshAfterVpnTransition(context: Context): void {
    FormInfoMetrics.refreshPublicIp(context, true).catch((): void => {
      AppLogger.warn(TAG, 'post-transition public IP refresh failed');
    });
  }

  private static async refreshExclusive(context: Context, force: boolean): Promise<string> {
    const store = await preferences.getPreferences(context, { name: PREF_NAME });
    const cached = await store.get(KEY_PUBLIC_IP, '') as string;
    const cachedAt = await store.get(KEY_PUBLIC_IP_TIME, 0) as number;
    if (!force && cached.length > 0 && Date.now() - cachedAt < PUBLIC_IP_TTL_MS) {
      return cached;
    }

    const request = http.createHttp();
    try {
      const response = await request.request(PUBLIC_IP_ENDPOINT, {
        method: http.RequestMethod.GET,
        connectTimeout: REQUEST_TIMEOUT_MS,
        readTimeout: REQUEST_TIMEOUT_MS,
        usingCache: false,
        usingProxy: AppProxyRoute.activePort() > 0
      });
      let body = '';
      if (typeof response.result === 'string') {
        const bytes = util.TextEncoder.create('utf-8').encodeInto(response.result);
        if (bytes.length > MAX_RESPONSE_BYTES) {
          return cached.length > 0 ? cached : '--';
        }
        body = response.result;
      } else if (response.result instanceof ArrayBuffer) {
        if (response.result.byteLength > MAX_RESPONSE_BYTES) {
          return cached.length > 0 ? cached : '--';
        }
        body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(response.result));
      }
      if (response.responseCode !== 200 || body.length === 0) {
        return cached.length > 0 ? cached : '--';
      }
      const payload = JSON.parse(body) as PublicIpPayload;
      const publicIp = typeof payload.ip === 'string' ? payload.ip.trim() : '';
      if (!FormInfoMetrics.isPlausibleIp(publicIp)) {
        return cached.length > 0 ? cached : '--';
      }
      await store.put(KEY_PUBLIC_IP, publicIp);
      await store.put(KEY_PUBLIC_IP_TIME, Date.now());
      await store.flush();
      return publicIp;
    } catch (error) {
      AppLogger.warn(TAG, 'public IP request failed');
      return cached.length > 0 ? cached : '--';
    } finally {
      request.destroy();
    }
  }

  private static isPlausibleIp(value: string): boolean {
    if (value.length < 3 || value.length > 45) {
      return false;
    }
    return /^[0-9a-fA-F:.]+$/.test(value);
  }
}
