/**
 * 测速探针：FlClash 等价语义 + 单一真源
 *
 * ## 为什么重做（2026-10-20，FlClash 对照后的四条硬差异）
 *
 * 1) **一次请求语义**（探针侧）
 *
 *    mihomo 的 `adapter/adapter.go:202-278`（URLTest）上报的延迟 =
 *    **代理拨号 + TCP 建连 + TLS 握手 + HTTP 往返** 的总和（`start` 取在拨号之前）。
 *    `unified-delay: true` 时内核**复用同一个 Transport** 再发一次 HEAD 并把 `start`
 *    重置为第二次（adapter.go:259-274）⇒ 报的是**已建立连接**上的第二个 HEAD 耗时，
 *    少付 1~2 个 RTT ⇒ 这就是 FlClash 展示的那个口径。
 *    ⇒ 探针侧的语义必须是：**一次探测 = 一次请求**（本文件保证探针自己不重试、
 *      不发第二次）—— 内核侧那个「第二次 HEAD」是 mihomo 的**统一延迟语义**，
 *      不是重复探测，由生成配置的 `unified-delay: true` 决定（见 ClashConfigGenerator.ets）。
 *
 *    ⚠ 2026-10-20 二次取证修正：此前把「mitce 34 节点秒败 503」归因到 unified-delay
 *    的双 HEAD 是**错的** —— 503 真因是测速核配置里一个节点都没有（凭据被封存未回填），
 *    当时的旁证就是「装 unified-delay:false 后仍全 503」⇒ 本条已推翻，恢复
 *    `unified-delay: true`（本机真内核 A/B：unified=false 把 TLS 握手算进去，
 *    每次凭空多 1~2 个 RTT，实测 +50~1000ms）。
 *
 * 2) **失败响应体完整落日志**（不是 bodyLen）
 *
 *    旧实现只记 `bodyLen=50` + 240 字符的头部 → 「DNS 解析失败 / REALITY 握手失败 /
 *    出口拒连 / 测速地址不可达」四类完全不同的原因在日志里长得一模一样，只能靠猜。
 *    现在失败时把**完整响应体**写进日志（超长才截断并标注），能直接看出
 *    dial 错误 / 状态码 / 耗时三件事。
 *
 * 3) **失败分类单一表**（{@link LatencyProbe.classify}）
 *
 *    旧实现把「内核没就绪（通道坏了）」和「节点真的不通」压成同一种红 ——
 *    真机 2026-09-23 那次「内核一抖，半张列表变红」就是这么来的。
 *    现在只有一张表，并且**非判定类失败不产生节点结论**。
 *
 * 4) **单一 URL 真源**（{@link LatencyTestUrl}）
 *
 *    前台批 / 后台批 / smart 组 / 内核健康检查以前各算各的（四处实现、规则还不一致）。
 *    现在只有一个函数推导 URL：`LatencyTestUrl.effective()`
 *    （住在**零 import** 的 `LatencyTestUrl.ets` 里 —— services/pages/models 都能安全引）。
 *
 * ## 参数纪律
 *
 * 并发 / 超时 / 取消相关的**所有**数字集中在 {@link LatencyProbeLimits}，
 * 外部不得再散落魔数（改了只改一处，闸门会盯住）。
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { AppLogger } from '../utils/AppLogger';
import { AppSettings } from '../models/AppSettings';
import { LatencyTestUrl } from './LatencyTestUrl';
import { LatencyDnsStatus, LatencyDnsVerdict } from './LatencyDnsVerdict';
import { LatencyProbeKind, LatencyProbeResult } from './LatencyKinds';

// URL 规则本体住在零 import 的 LatencyTestUrl.ets（见该文件头注释）；
// 这里转出一下，方便「从 LatencyProbe 一次性拿到全部测速 API」的调用方。
export { LatencyTestUrl };
export { LatencyDnsStatus, LatencyDnsVerdict };
// 分类表与结果类型住在零 import 的 LatencyKinds.ets（见该文件头注释）；
// 这里转出一下，保持「从 LatencyProbe 一次性拿到全部测速 API」的既有路径。
export { LatencyProbeKind, LatencyProbeResult };

const TAG: string = 'LatencyProbe';

/**
 * 测速参数集中区（**唯一允许出现魔数的地方**）。
 *
 * 取值依据：
 *  - `NODE_TIMEOUT_MS` 3000：单个节点的一次测速预算（内核 timeout 参数）。
 *    2026-10-20 晚用户要求由 5000 改为 3000；与 `LatencyTimeout.DEFAULT_TIMEOUT_MS`
 *    必须同值（闸门 verify-latency-core-v2 断言两者相等）。
 *  - `OUTER_EXTRA_MS` 1200：外层 HTTP 超时相对内核预算的余量。内核在自己的
 *    timeout 到点后要先拆 dial 上下文、再序列化 504 回写 socket（弱网/高负载时
 *    可能上百毫秒）。余量太小 → 客户端先超时 → 拿到的是传输层错误而不是内核明确的
 *    504 → 「真超时」被误分类成「通道坏了」。
 *  - `WORKERS` 50：worker 数 = 队列深度（对齐 FlClash 的 client concurrency 50）。
 *  - `MAX_INFLIGHT` 8：**同时在途的 HTTP 请求数**（= 引擎在途闸门 `LATENCY_INFLIGHT`）。
 *    2026-10-20 曾放开到 50（与 worker 同宽），2026-10-21 真机回退：OHOS http 栈对
 *    **同一 host**（恒为 `127.0.0.1:9090`）只有约 8 条连接，超出部分会在栈内部排队、
 *    排队时间被算进单请求预算 ⇒ 客户端侧 `2300028` ⇒ 被归成 `core_not_ready` ⇒
 *    6 连击作废整批（飞鸟云 31 节点批：后 24 个一次 `/delay` 都没发）。
 *    8 是**容量事实**而非保守取值：排队必须发生在应用层闸门里（等待不计预算）。
 *  - `QUEUE_WAIT_MAX_MS` 60000：排队等待上限。排队等待**不计入**节点的超时预算；
 *    超了就是「排队超时」（根本没拨号），归非判定。
 */
export class LatencyProbeLimits {
  /** 单节点的测速预算（内核 timeout 参数，单位 ms）：2026-10-20 晚由 5000 改为 3000 */
  static readonly NODE_TIMEOUT_MS: number = 3000;
  /** 外层 HTTP 超时相对内核预算的余量 */
  static readonly OUTER_EXTRA_MS: number = 1200;
  /** worker 数 / 队列深度（对齐 FlClash 的 client concurrency 50） */
  static readonly WORKERS: number = 50;
  /** 同时在途的 HTTP 请求数（= 引擎在途闸门 LATENCY_INFLIGHT；2026-10-21 由 50 回退到 8） */
  static readonly MAX_INFLIGHT: number = 8;
  /** 排队等待上限（超过 = 排队超时；等待时间不计入节点超时预算） */
  static readonly QUEUE_WAIT_MAX_MS: number = 60000;
  /** 取消后等待在途请求收尾的宽限期 */
  static readonly CANCEL_GRACE_MS: number = 500;
  /** 失败响应体写日志的长度上限（超出截断并标注，绝不静默丢内容） */
  static readonly FAILURE_BODY_LOG_MAX: number = 4096;

  /** 外层 HTTP 超时预算 = 内核预算 + 余量 */
  static outerTimeoutMs(nodeTimeoutMs: number): number {
    return nodeTimeoutMs + LatencyProbeLimits.OUTER_EXTRA_MS;
  }
}

/**
 * 测速 URL 的调用方入口（**有 settings 的调用方用这个**）。
 *
 * 规则本体在 {@link LatencyTestUrl.effective}（零 import 的 `LatencyTestUrl.ets`，
 * services/pages/models 都能安全引）；这里只是给「手上有 AppSettings」的调用方
 * 一个入口，内部**只委托、不复制规则**。
 */
export function effectiveTestUrl(settings: AppSettings): string {
  return LatencyTestUrl.effective(settings.testLatencyUrl);
}


/** 失败分类表的一项 */
export class LatencyFailureClass {
  /** 分类（LatencyProbeKind.*） */
  kind: string = LatencyProbeKind.UNKNOWN;
  /** 是否构成「节点结论」（非判定类失败必须为 false） */
  isVerdict: boolean = false;
  /** 人类可读的说明（进日志与 UI 细节） */
  detail: string = '';
}


/** 内核 REST 端点（延迟探测用） */
export class LatencyKernelEndpoint {
  /** 内核控制面地址（本机） */
  baseUrl: string = 'http://127.0.0.1:9090';
  /** 控制面密钥（空 = 不带鉴权头） */
  secret: string = '';
  providerName: string = '';

  /** 鉴权头 */
  authHeaders(): Record<string, string> {
    const h: Record<string, string> = {};
    if (this.secret.length > 0) {
      h['Authorization'] = `Bearer ${this.secret}`;
    }
    return h;
  }
}

/** 一次 HTTP 往返的最小抽象（便于单测替换；实现**不得**自动重试） */
export interface LatencyHttpTransport {
  /** 发起**一次** GET */
  get(url: string, headers: Record<string, string>, timeoutMs: number): Promise<LatencyHttpReply>;
}

/** 一次 HTTP 往返的回复 */
export class LatencyHttpReply {
  /** HTTP 状态码（0 = 没有拿到响应） */
  responseCode: number = 0;
  /** 响应体（字符串形态） */
  body: string = '';
}

/** 生产用传输层（ArkTS http 栈） */
export class ArkHttpTransport implements LatencyHttpTransport {
  async get(url: string, headers: Record<string, string>, timeoutMs: number): Promise<LatencyHttpReply> {
    const reply = new LatencyHttpReply();
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        usingCache: false
      });
      reply.responseCode = resp.responseCode;
      if (typeof resp.result === 'string') {
        reply.body = resp.result as string;
      } else if (resp.result instanceof ArrayBuffer) {
        reply.body = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(resp.result));
      }
      return reply;
    } finally {
      req.destroy();
    }
  }
}

/**
 * 测速探针（单请求语义 + 单一失败分类表）。
 */
export class LatencyProbe {
  /** mihomo 的「全部成员失败」文案（hub/route/proxies.go:135-143） */
  static readonly MIHOMO_DELAY_TEST_FAILURE: string = 'An error occurred in the delay test';

  /**
   * dial 类错误特征串（用于判定「503 的体里有没有拨号错误」）。
   *
   * mihomo 的 URLTest 失败只可能来自：urlToMetadata / DialContext /
   * http.NewRequest / GetTLSConfig / **第一次 client.Do 失败**
   * （adapter.go:166-200）—— 也就是说「节点在内核表里但握手失败」= **dial 阶段就炸**，
   * 错误文案里必然带下面这些特征。
   */
  static readonly DIAL_ERROR_MARKERS: string[] = [
    'dial tcp', 'dial udp', 'dial tls', 'connection refused', 'connection reset',
    'connection timed out', 'no such host', 'i/o timeout', 'context deadline exceeded',
    'handshake', 'tls handshake', 'network is unreachable', 'host is unreachable',
    'unexpected eof', 'reset by peer', 'eof'
  ];


  /** 响应体里是否带 dial 类错误 */
  static hasDialError(body: string): boolean {
    const lower: string = body.toLowerCase();
    for (const marker of LatencyProbe.DIAL_ERROR_MARKERS) {
      if (lower.indexOf(marker) >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 是否是 mihomo 的「测速失败」通用文案 */
  static isMihomoDelayTestFailure(body: string): boolean {
    return body.indexOf(LatencyProbe.MIHOMO_DELAY_TEST_FAILURE) >= 0;
  }

  /** 从 200 响应体里取 delay（取不到返回 -1） */
  static parseDelay(body: string): number {
    if (body.length === 0) {
      return -1;
    }
    try {
      const json = JSON.parse(body) as Record<string, number>;
      const delay = json['delay'];
      if (delay === undefined || delay === null) {
        return -1;
      }
      return delay;
    } catch (e) {
      return -1;
    }
  }

  /** 失败体写日志前的处理：完整写出，超长才截断并标注（**绝不**只写长度） */
  static bodyForLog(body: string): string {
    if (body.length <= LatencyProbeLimits.FAILURE_BODY_LOG_MAX) {
      return body;
    }
    return `${body.substring(0, LatencyProbeLimits.FAILURE_BODY_LOG_MAX)}…(已截断，全文 ${body.length} 字符)`;
  }

  /** 构造延迟探测的 URL（与内核路由 `/proxies/{name}/delay` 对齐） */
  static delayUrl(endpoint: LatencyKernelEndpoint, nodeName: string, testUrl: string,
    nodeTimeoutMs: number): string {
    const name: string = encodeURIComponent(nodeName);
    const path: string = endpoint.providerName.length > 0
      ? `/providers/proxies/${encodeURIComponent(endpoint.providerName)}/${name}/healthcheck`
      : `/proxies/${name}/delay`;
    return `${endpoint.baseUrl}${path}`
      + `?url=${encodeURIComponent(testUrl)}&timeout=${nodeTimeoutMs}`;
  }

  /**
   * **失败分类单一表**。
   *
   * @param httpCode HTTP 状态码（0 = 没有拿到响应）
   * @param body 响应体（完整）
   * @param transportError 传输层异常文案（非空 = 压根没拿到 HTTP 响应）
   */
  static classify(httpCode: number, body: string, transportError: string,
    dns: LatencyDnsVerdict | null = null): LatencyFailureClass {
    const out = new LatencyFailureClass();
    // ① DNS 预检已经判定「域名解析不出来」⇒ 最高优先级。
    //    不管内核回的是 503 还是别的，都**不能**写成 network_unreachable：
    //    用户原话「你就把失败改成网络不可达，你糊弄谁呢」——
    //    解析失败（域名可能已下线）与拨号失败是两件事，混了就等于糊弄。
    if (dns !== null && dns.status === LatencyDnsStatus.UNRESOLVED) {
      out.kind = LatencyProbeKind.DNS_UNRESOLVED;
      out.isVerdict = true;
      out.detail = `DNS 预检未解析 ${dns.host}（${dns.detail}）`;
      return out;
    }
    if (transportError.length > 0) {
      // 本机控制器没能给出 HTTP 响应 → 通道不可用，**不是节点结论**。
      // 真机实证：隧道内核中途重启（secret 变更）后，其余节点全部拿到连接类异常；
      // 旧口径把它们盖成「失败」写进排序快照 —— 这就是「内核一抖，半张列表变红」。
      out.kind = LatencyProbeKind.CORE_NOT_READY;
      out.isVerdict = false;
      out.detail = `transport error: ${transportError}`;
      return out;
    }
    if (httpCode === 200) {
      const delay = LatencyProbe.parseDelay(body);
      if (delay >= 1) {
        out.kind = LatencyProbeKind.NONE;
        out.isVerdict = true;
        out.detail = `delay=${delay}`;
        return out;
      }
      // 200 但拿不到合法 delay：响应形状不对，认不出来 → 非判定。
      out.kind = LatencyProbeKind.UNKNOWN;
      out.isVerdict = false;
      out.detail = `http=200 但 delay 非法 body=${LatencyProbe.bodyForLog(body)}`;
      return out;
    }
    if (httpCode === 504) {
      // 内核明确说「这个节点超时了」→ 节点结论。
      out.kind = LatencyProbeKind.TIMEOUT;
      out.isVerdict = true;
      out.detail = `http=504 节点超时 body=${LatencyProbe.bodyForLog(body)}`;
      return out;
    }
    if (httpCode === 503) {
      // mihomo 的 /delay 只在 err!=null 或 delay==0 时返回 503（hub/route/proxies.go:135-143）
      // ⇒ 503 **就是**「这个节点的探测失败」。有 dial 细节时写进 detail；
      // 只有通用文案时注明「内核未回传 dial 细节，看内核日志」。
      if (LatencyProbe.hasDialError(body)) {
        out.kind = LatencyProbeKind.NETWORK_UNREACHABLE;
        out.isVerdict = true;
        out.detail = `http=503 拨号失败 body=${LatencyProbe.bodyForLog(body)}`;
        return out;
      }
      if (LatencyProbe.isMihomoDelayTestFailure(body)) {
        out.kind = LatencyProbeKind.NETWORK_UNREACHABLE;
        out.isVerdict = true;
        out.detail = `http=503 节点探测失败（内核未回传 dial 细节，见内核日志） `
          + `body=${LatencyProbe.bodyForLog(body)}`;
        return out;
      }
      out.kind = LatencyProbeKind.UNKNOWN;
      out.isVerdict = false;
      out.detail = `http=503 未识别的响应体 body=${LatencyProbe.bodyForLog(body)}`;
      return out;
    }
    if (httpCode === 404) {
      // 节点不在内核代理表里（配置/内核没同步上）→ 配置类结论「未生效」。
      out.kind = LatencyProbeKind.SWITCH_FAILED;
      out.isVerdict = true;
      out.detail = `http=404 节点不在内核代理表 body=${LatencyProbe.bodyForLog(body)}`;
      return out;
    }
    if (httpCode === 401 || httpCode === 403) {
      // 控制面凭证不对 → 通道问题，**不是节点结论**。
      out.kind = LatencyProbeKind.CORE_NOT_READY;
      out.isVerdict = false;
      out.detail = `http=${httpCode} 控制面凭证/通道不对 body=${LatencyProbe.bodyForLog(body)}`;
      return out;
    }
    out.kind = LatencyProbeKind.UNKNOWN;
    out.isVerdict = false;
    out.detail = `http=${httpCode} 未识别 body=${LatencyProbe.bodyForLog(body)}`;
    return out;
  }

  /**
   * 探测单个节点：**一次请求**（不重试、不发第二次）。
   *
   * 与 FlClash 的等价性就落在这一行：`await transport.get(...)` 只调用一次，
   * 失败也不重发（重试是引擎层的「通道故障复查」，不属于测量语义）。
   *
   * @param dns **可选**的 DNS 预检结论（见 {@link LatencyDnsVerdict}）。
   *   传入且状态为 `unresolved` ⇒ **一次请求都不发**，直接判 `dns_unresolved`
   *   （mihomo 的 503 是通用句，看不到 DNS 原因；再问它一次也只是浪费一轮超时）。
   */
  static async probeOne(nodeName: string, testUrl: string, endpoint: LatencyKernelEndpoint,
    transport: LatencyHttpTransport,
    nodeTimeoutMs: number = LatencyProbeLimits.NODE_TIMEOUT_MS,
    dns: LatencyDnsVerdict | null = null): Promise<LatencyProbeResult> {
    const out = new LatencyProbeResult();
    out.nodeName = nodeName;
    const startedAt: number = Date.now();
    const outerTimeoutMs: number = LatencyProbeLimits.outerTimeoutMs(nodeTimeoutMs);
    const url: string = LatencyProbe.delayUrl(endpoint, nodeName, testUrl, nodeTimeoutMs);
    // ① DNS 预检失败 ⇒ 一次请求都不发（内核看不到 DNS 原因，去了也只会回 503 通用句）。
    if (dns !== null && dns.status === LatencyDnsStatus.UNRESOLVED) {
      const cls = LatencyProbe.classify(0, '', '', dns);
      out.failKind = cls.kind;
      out.isVerdict = cls.isVerdict;
      out.detail = cls.detail;
      out.httpCode = 0;
      out.elapsedMs = Date.now() - startedAt;
      AppLogger.warn(TAG, `latency probe skipped (dns) node=${nodeName} kind=${out.failKind} `
        + `verdict=${out.isVerdict} elapsed=${out.elapsedMs}ms host=${dns.host} detail=${dns.detail}`);
      return out;
    }
    try {
      const reply = await transport.get(url, endpoint.authHeaders(), outerTimeoutMs);
      out.httpCode = reply.responseCode;
      out.bodyText = reply.body;
      const cls = LatencyProbe.classify(reply.responseCode, reply.body, '', dns);
      out.failKind = cls.kind;
      out.isVerdict = cls.isVerdict;
      out.detail = cls.detail;
      if (cls.kind === LatencyProbeKind.NONE) {
        out.delayMs = LatencyProbe.parseDelay(reply.body);
      }
      out.elapsedMs = Date.now() - startedAt;
      if (out.failKind !== LatencyProbeKind.NONE) {
        // 完整响应体进日志（不是 bodyLen）：一眼能看出 dial 错误 / 状态码 / 耗时。
        AppLogger.warn(TAG, `latency probe failed node=${nodeName} http=${out.httpCode} `
          + `kind=${out.failKind} verdict=${out.isVerdict} elapsed=${out.elapsedMs}ms `
          + `inner=${nodeTimeoutMs} outer=${outerTimeoutMs} url=${testUrl} `
          + `body=${LatencyProbe.bodyForLog(reply.body)}`);
      }
      return out;
    } catch (e) {
      const errText: string = AppLogger.errText(e);
      const cls = LatencyProbe.classify(0, '', errText, dns);
      out.failKind = cls.kind;
      out.isVerdict = cls.isVerdict;
      out.detail = cls.detail;
      out.httpCode = 0;
      out.elapsedMs = Date.now() - startedAt;
      AppLogger.warn(TAG, `latency probe transport error node=${nodeName} kind=${out.failKind} `
        + `verdict=${out.isVerdict} elapsed=${out.elapsedMs}ms inner=${nodeTimeoutMs} `
        + `outer=${outerTimeoutMs} error=${errText}`);
      return out;
    }
  }
}
