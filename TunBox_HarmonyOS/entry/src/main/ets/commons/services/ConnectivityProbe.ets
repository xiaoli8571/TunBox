/**
 * 数据页「连通性」自测（对齐 ClashPlus 1.2.7 `_ConnectivitySection`）
 *
 * ## 对齐点
 * - 三种探测方式：`tcp`（直连目标 443 端口）/ `http` / `https`（应用代理运行时经本机
 *   代理端口，与其它应用内请求一致；未运行时直连）——与 Plus 设置项说明逐字同义。
 * - 目标列表默认 `google.com`、`github.com`（Plus `_loadHosts` 的默认值）。
 * - 添加时先剥 `http(s)://` 前缀、再剥路径，只留主机名（Plus `_addEntry` 的两条正则）。
 * - 结果三态文案：超时 / 不可达 / 失败（Plus `statsConnectivityTimeout` /
 *   `statsConnectivityUnreachable` / `statsConnectivityFailed`）。
 */
import { http, socket } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { AppProxyRoute } from './AppProxyRoute';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'ConnectivityProbe';
const PREF_NAME = 'tunbox_connectivity';
const KEY_HOSTS = 'connectivity_hosts';

/** 探测方式（与 Plus `ConnectivityTestMethod` 三值对齐；默认 https） */
export enum ProbeKind {
  TCP = 'tcp',
  HTTP = 'http',
  HTTPS = 'https'
}

/** 单条探测状态 */
export enum ProbeState {
  IDLE = 'idle',
  TESTING = 'testing',
  OK = 'ok',
  TIMEOUT = 'timeout',
  UNREACHABLE = 'unreachable',
  FAILED = 'failed'
}

/** 一次探测的结果 */
export class ProbeResult {
  state: ProbeState = ProbeState.FAILED;
  /** 成功时的手测延迟（ms）；非成功为 -1 */
  delayMs: number = -1;
  /** 补充说明（如 HTTP 状态码），点开详情时展示 */
  detail: string = '';
}

/** 列表里的一行（界面直接持有） */
export class ConnectivityEntry {
  host: string = '';
  kind: ProbeKind = ProbeKind.HTTPS;
  state: ProbeState = ProbeState.IDLE;
  delayMs: number = -1;
  detail: string = '';
}

/** 探测超时（ms）——与延迟测速同一量级，避免弱网下长时间挂起 */
const PROBE_TIMEOUT_MS: number = 5000;

export class ConnectivityProbe {
  private static store: preferences.Preferences | null = null;
  private static inited: boolean = false;

  /** 默认目标（Plus 默认值） */
  static defaults(): string[] {
    return ['google.com', 'github.com'];
  }

  static async init(context: Context): Promise<void> {
    if (ConnectivityProbe.inited) {
      return;
    }
    try {
      ConnectivityProbe.store = await preferences.getPreferences(context, PREF_NAME);
    } catch (e) {
      AppLogger.warn(TAG, `preferences init failed: ${AppLogger.errText(e)}`);
    } finally {
      ConnectivityProbe.inited = true;
    }
  }

  static async loadHosts(): Promise<string[]> {
    const p: preferences.Preferences | null = ConnectivityProbe.store;
    if (p === null) {
      return ConnectivityProbe.defaults();
    }
    try {
      const raw: string = await p.get(KEY_HOSTS, '') as string;
      if (raw.length === 0) {
        return ConnectivityProbe.defaults();
      }
      const arr: string[] = JSON.parse(raw) as string[];
      if (!Array.isArray(arr) || arr.length === 0) {
        return ConnectivityProbe.defaults();
      }
      return arr;
    } catch (e) {
      AppLogger.warn(TAG, `load hosts failed: ${AppLogger.errText(e)}`);
      return ConnectivityProbe.defaults();
    }
  }

  static async saveHosts(hosts: string[]): Promise<void> {
    const p: preferences.Preferences | null = ConnectivityProbe.store;
    if (p === null) {
      return;
    }
    try {
      await p.put(KEY_HOSTS, JSON.stringify(hosts));
      await p.flush();
    } catch (e) {
      AppLogger.warn(TAG, `save hosts failed: ${AppLogger.errText(e)}`);
    }
  }

  /**
   * 用户输入 → 主机名。Plus `_addEntry`：先按 `^https?://` 剥协议，再按 `/.*` 剥路径。
   * 输入非法（空/含空格）返回空串，由调用方提示。
   */
  static normalizeHost(input: string): string {
    let s: string = input.trim();
    if (s.length === 0) {
      return '';
    }
    s = s.replace(/^https?:\/\//i, '');
    const slash: number = s.indexOf('/');
    if (slash >= 0) {
      s = s.substring(0, slash);
    }
    const colon: number = s.indexOf(':');
    if (colon >= 0) {
      s = s.substring(0, colon);
    }
    if (s.length === 0 || s.indexOf(' ') >= 0) {
      return '';
    }
    return s;
  }

  /** 执行一次探测 */
  static async probe(host: string, kind: ProbeKind): Promise<ProbeResult> {
    if (kind === ProbeKind.TCP) {
      return ConnectivityProbe.probeTcp(host);
    }
    return ConnectivityProbe.probeHttp(host, kind);
  }

  /**
   * TCP 探测：直连 host:443（Plus 说明原文「TCP 直连目标主机 443 端口」）。
   *
   * 不经过代理：这是「裸网络可达性」探针，和代理是否可用相互独立 —— 用户在直连
   * 模式下也能看到本地网络对目标站点的可达性。
   */
  private static async probeTcp(host: string): Promise<ProbeResult> {
    const result: ProbeResult = new ProbeResult();
    const t0: number = Date.now();
    let sock: socket.TCPSocket | null = null;
    try {
      sock = socket.constructTCPSocketInstance();
      const timeout: Promise<void> = new Promise<void>((resolve: () => void, reject: (e: Error) => void): void => {
        setTimeout((): void => {
          reject(new Error('timeout'));
        }, PROBE_TIMEOUT_MS);
      });
      const work: Promise<void> = new Promise<void>((resolve: () => void, reject: (e: Error) => void): void => {
        const s: socket.TCPSocket = sock as socket.TCPSocket;
        s.connect({ address: { address: host, port: 443 }, timeout: PROBE_TIMEOUT_MS })
          .then((): void => { resolve(); })
          .catch((e: Error): void => { reject(e); });
      });
      await Promise.race([work, timeout]);
      result.state = ProbeState.OK;
      result.delayMs = Date.now() - t0;
      result.detail = 'TCP 443';
    } catch (e) {
      const msg: string = AppLogger.errText(e);
      result.state = msg.indexOf('timeout') >= 0 ? ProbeState.TIMEOUT : ProbeState.UNREACHABLE;
      result.delayMs = -1;
      result.detail = 'TCP 443';
      AppLogger.info(TAG, `tcp probe ${host} -> ${result.state} (${msg})`);
    } finally {
      if (sock !== null) {
        try {
          await (sock as socket.TCPSocket).close();
        } catch (e) {
          // 关闭失败不影响探测结论
        }
      }
    }
    return result;
  }

  /**
   * HTTP/HTTPS 探测：代理运行时经本机代理端口（与 Plus 说明一致），未运行则直连。
   *
   * 判定口径：拿到任何 HTTP 响应码即视为「通」——连通性关心的是「能不能到这站」，
   * 4xx/5xx 也证明链路与 TLS 握手都成立（Plus 同样只把网络级失败记为失败）。
   */
  private static async probeHttp(host: string, kind: ProbeKind): Promise<ProbeResult> {
    const result: ProbeResult = new ProbeResult();
    const scheme: string = kind === ProbeKind.HTTP ? 'http' : 'https';
    const url: string = `${scheme}://${host}/`;
    const t0: number = Date.now();
    const req: http.HttpRequest = http.createHttp();
    try {
      const port: number = AppProxyRoute.activePort();
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: PROBE_TIMEOUT_MS,
        readTimeout: PROBE_TIMEOUT_MS,
        usingCache: false,
        usingProxy: port > 0
      });
      result.state = ProbeState.OK;
      result.delayMs = Date.now() - t0;
      result.detail = `${scheme.toUpperCase()} ${resp.responseCode}`;
    } catch (e) {
      const msg: string = AppLogger.errText(e);
      const isTimeout: boolean = msg.toLowerCase().indexOf('timeout') >= 0
        || msg.indexOf('2300028') >= 0;
      result.state = isTimeout ? ProbeState.TIMEOUT : ProbeState.FAILED;
      result.delayMs = -1;
      result.detail = scheme.toUpperCase();
      AppLogger.info(TAG, `http probe ${url} -> ${result.state} (${msg})`);
    } finally {
      try {
        req.destroy();
      } catch (e) {
        // 销毁失败忽略
      }
    }
    return result;
  }
}
