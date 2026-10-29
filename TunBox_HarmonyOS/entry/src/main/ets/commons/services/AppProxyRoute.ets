/**
 * AppProxyRoute —— 让 **App 自身**的 HTTP 请求走本地内核代理。
 *
 * 职责：
 *  · VPN 隧道就绪后，把应用级 HTTP 代理指向 `127.0.0.1:<mixed-port>`，
 *    于是出口 IP 查询、geo/规则集/模型下载这些「App 自己发的请求」
 *    会经内核出代理，而不是从物理网卡直连。
 *  · 断开时清除该代理，避免隧道没了以后所有请求打到一个空端口上全部失败。
 *
 * 为什么必须这么做（2026-10-22 真机）：
 *  · 隧道里 App 自身流量被 protect 掉（绕过 TUN 直连），所以
 *    `api64.ipify.org`（查出口 IP）和 GitHub 镜像（下载 geoip/规则集/模型）
 *    全部走物理网卡直连 —— 国内环境下前者超时、后者被墙，
 *    表现就是「节点测速正常，但获取出口 IP 失败」「数据与规则点更新提示全部源下载失败」。
 *  · 这与「启动代理后更新全量数据」的设计一致：有代理时才更新，没代理就不更新。
 *
 * 关键口径：
 *  · 只在隧道已连接时设置；端口随 mixed-port 变化自动更新。
 *  · 幂等：同一端口重复设置直接返回，不重复 IPC。
 *  · 任何失败只记日志，不影响连接本身。
 */

import { connection, http } from '@kit.NetworkKit';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'AppProxyRoute';

export class AppProxyRoute {
  /** 当前已生效的端口（-1 = 未设置） */
  private static appliedPort: number = -1;
  /** setAppHttpProxy 成功不代表 mixed-port 已开始监听，单独记录探针结果。 */
  private static readyPort: number = -1;

  /**
   * 指向本地内核 mixed 端口。`port <= 0` 视为无效，直接返回。
   */
  static apply(port: number): void {
    if (port <= 0) {
      return;
    }
    if (AppProxyRoute.appliedPort === port) {
      return;
    }
    const proxy: connection.HttpProxy = {
      host: '127.0.0.1',
      port: port,
      // 本机回环与局域网不走代理，否则内核自己的 controller 调用会被绕一圈
      exclusionList: ['127.0.0.1', 'localhost']
    };
    try {
      // SDK：setAppHttpProxy 是**同步**接口（返回 void），失败抛 BusinessError
      connection.setAppHttpProxy(proxy);
      AppProxyRoute.appliedPort = port;
      AppProxyRoute.readyPort = -1;
      AppLogger.info(TAG, `app http proxy -> 127.0.0.1:${port} (app requests now egress via tunnel)`);
    } catch (e) {
      AppLogger.warn(TAG, `set app http proxy failed: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * 断开隧道时撤销。
   *
   * ⚠ SDK 的 `setAppHttpProxy` **不接受 null**（真机 16:39:00 报 `401 Parameter error`），
   * 也没有 clear/restore 接口；传 `{host:'', port:0}` 会被判 `2100001 Invalid http proxy`。
   * 因此这里只重置内部状态，真正的「绕过残留代理」由**每个外网请求的 usingProxy 标志**
   * 保证：请求依据 `AppProxyRoute.isReady()` 决定是否走代理 —— 断开后 isReady() 为 false，
   * 请求一律直连，不再受残留配置影响。
   */
  static clear(): void {
    if (AppProxyRoute.appliedPort < 0) {
      return;
    }
    AppProxyRoute.appliedPort = -1;
    AppProxyRoute.readyPort = -1;
    AppLogger.info(TAG, 'app http proxy marked inactive (usingProxy=false from now on)');
  }

  /** 当前是否已把 App 请求导向本地代理（排障用） */
  static activePort(): number {
    return AppProxyRoute.appliedPort;
  }

  /** 只有本地 mixed-port 已实际响应后，订阅请求才使用代理。 */
  static isReady(): boolean {
    return AppProxyRoute.appliedPort > 0 && AppProxyRoute.readyPort === AppProxyRoute.appliedPort;
  }

  /**
   * 探测 mixed-port 是否已经开始监听。请求不使用代理，避免探针递归经过自身；
   * mixed-port 返回任意 HTTP 状态都说明本地监听已建立。
   */
  static async waitUntilReady(timeoutMs: number = 4000): Promise<boolean> {
    const port = AppProxyRoute.appliedPort;
    if (port <= 0) {
      return false;
    }
    if (AppProxyRoute.readyPort === port) {
      return true;
    }
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline && AppProxyRoute.appliedPort === port) {
      const req = http.createHttp();
      try {
        const resp = await req.request(`http://127.0.0.1:${port}/version`, {
          method: http.RequestMethod.GET,
          connectTimeout: 500,
          readTimeout: 500,
          usingCache: false,
          usingProxy: false
        });
        AppProxyRoute.readyPort = port;
        AppLogger.info(TAG, `mixed-port ready: 127.0.0.1:${port} (HTTP ${resp.responseCode})`);
        return true;
      } catch (e) {
        // 内核启动窗口内连接拒绝是正常现象，稍后重试。
      } finally {
        try {
          req.destroy();
        } catch (e) {
          // 已结束的请求销毁失败不影响探测结果。
        }
      }
      await new Promise<void>((resolve) => {
        setTimeout(() => resolve(), 150);
      });
    }
    return AppProxyRoute.isReady();
  }
}
