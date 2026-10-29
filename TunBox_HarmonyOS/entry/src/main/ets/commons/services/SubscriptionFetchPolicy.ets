/**
 * 订阅拉取策略：UA 协商
 * 移植自 upstream: packages/tunbox_shared/lib/services/subscription_fetch_policy.dart
 *
 * UA 顺序（必须一致）：TunBox → Clash Verge → v2rayN → Shadowrocket。
 * 每次降级重试都在 HTTP 403/406 或空结果时触发。
 */
import { http, connection } from '@kit.NetworkKit';
import { AppProxyRoute } from './AppProxyRoute';
import { url, util } from '@kit.ArkTS';
import { AppLogger } from '../utils/AppLogger';
import { AppInfo } from '../utils/AppInfo';
import { LocalSubConverter } from './LocalSubConverter';
import { HttpBodyCodec } from '../subscription/HttpBodyCodec';

const TAG = 'SubscriptionFetchPolicy';
const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;
const MAX_FIELD_LENGTH = 4096;
const MAX_NODE_COUNT = 2000;
const MAX_REDIRECTS = 5;
/**
 * 传输层失败的重试预算。
 *
 * 实测背景（2026-09-19 真机 + PC 对照）：ikuuu 面板本身完全健康 ——
 * 单条 A 记录（无多 IP）、ZeroSSL 证书有效、UA 无关、PC 上 11/11 稳定 200；
 * 但设备上偶发 `code=2300060 Invalid SSL peer certificate` / 连接重置，过一会儿又自愈。
 * 即故障在**设备到面板的网络路径**上（中间设备干扰/阻断呈概率性），
 * 面板、解析层、证书都不是原因。
 *
 * 概率性干扰下「换一条新连接」有机会绕过，所以值得重试；
 * 而 UA 链的用途是内容协商、不是可达性，拿它当重试手段会让一次被阻断的域名
 * 要用户干等 5 × 15s = 75s。
 * 这里用**时间预算**封顶：一次超时已吃掉 15s，预算即耗尽、不再重试；
 * 只有快速失败（RST / TLS 拒绝 / DNS 失败，通常 <1s）才真正重试。
 * 因此最坏总时长仍约等于一次超时 + 少量退避，不会退回 75s。
 */
const TRANSPORT_RETRY_MAX = 3;
const TRANSPORT_RETRY_BUDGET_MS = 20000;
const TRANSPORT_RETRY_BACKOFF_MS = 700;

/**
 * UA 顺序：优先 Clash 系 UA 让面板直接返回 Clash YAML（vmess/vless/trojan 字段最完整），
 * 其余 UA 依次兜底；解析层同时支持 vless/vmess/trojan 链接格式。
 * TunBox 自家 UA 携带实时版本（AppInfo 单一来源, 不再硬编码）。
 *
 * 【2026-10-20 版本上调：1.7.7 → 2.4.2】面板普遍按 UA **版本号**做内容协商，
 * 且 fetch() 命中第一个 200+非空 body 就返回（见本文件 fetch），后面的兜底 UA
 * 永远不会被用到 —— 所以**第一个 UA 的版本号就是实际生效的客户端版本**。
 * 实测（同一订阅 URL、同一时刻，仅换 UA）：
 *   clash-verge/v1.7.7  → 20 条（0 anytls，另塞 4 条「客户端太老」假 ss 广告）
 *   clash-verge/v2.4.2  → 36 条（20 anytls + 13 hy2 + 3 tuic）
 *   clash.meta/v1.19.32 → 36 条；  mihomo/1.19.32 → 36 条
 *   TunBox/<version>    → HTTP 400（面板不认）
 * 用户报「FlClash 解析 36 个、TunBox 只剩 20 个」的根因就在这里（不是解析层丢节点：
 * 解析层 36 进 36 出、mihomo -t 通过）。
 *
 * 选 v2.4.2 而不是 `mihomo/*`：两者都返回 36 条，但 mihomo UA 会让**部分**机场
 * 改成返回 base64 链接列表（多一条解析分支的差异），而 clash-verge 语义与解析层
 * 的 YAML 主路径完全一致。
 */
export const UA_CHAIN: string[] = [
  'clash-verge/v2.4.2',
  'clash.meta/v1.19.32',
  'TunBox/' + AppInfo.version(),
  'v2rayN/6.23',
  'Shadowrocket/2077'
];

export class SubscriptionUserInfo {
  uploadBytes: number = -1;
  downloadBytes: number = -1;
  totalBytes: number = -1;
  expireAt: number = -1;
}

/**
 * 易变/临时隧道域名清单（加固③）：quick tunnel / 内网穿透类域名轮换极快
 * （*.trycloudflare.com 每次都是随机子域），隧道域名轮换后旧节点全部超时。
 */
const EPHEMERAL_TUNNEL_DOMAINS: string[] = ['trycloudflare.com', 'loca.lt', 'serveo.net', 'localtunnel.me'];

/**
 * 节点 server 是否命中易变/临时隧道域名。命中时该订阅的刷新间隔压到
 * EPHEMERAL_SUBSCRIPTION_REFRESH_MS（见 SubscriptionUpdateScheduler 的消费）。
 */
export function isEphemeralHost(server: string): boolean {
  const h = server.trim().toLowerCase();
  for (const d of EPHEMERAL_TUNNEL_DOMAINS) {
    if (h === d || h.endsWith('.' + d)) {
      return true;
    }
  }
  return false;
}

/**
 * 易变域名订阅的有效刷新间隔（毫秒）：临时隧道域名轮换快，压到 6h ——
 * 与全局过期阈值 SUBSCRIPTION_STALE_MS 同值（当前语义下行为等价，契约显式化，
 * 全局阈值将来调大时易变订阅仍保持 6h 刷新）。
 */
export const EPHEMERAL_SUBSCRIPTION_REFRESH_MS: number = 6 * 60 * 60 * 1000;

/** `authTarget()` 的结果：剥掉 userinfo 后的地址 + 该带的 Authorization 头。 */
export class FetchAuthTarget {
  url: string = '';
  header: string = '';
}

export class SubscriptionFetchResult {
  body: string = '';
  userInfo: SubscriptionUserInfo = new SubscriptionUserInfo();
  /**
   * 服务端返回的 ETag（`ETag` / `Last-Modified`），供下次带 `If-None-Match` 条件请求。
   * 空串 = 服务端未给，下次仍做完整拉取。
   */
  etag: string = '';
  /**
   * 是否 304 Not Modified —— 服务端确认内容未变（本次没有响应体）。
   * 调用方据此走「未变更」路径（沿用已落盘节点），而不是把空响应当成失败。
   */
  notModified: boolean = false;
  /**
   * `Content-Disposition` 原始头（FlClash 用它给订阅起名：
   * `lib/models/profile.dart:186-198` 的 `getFileNameForDisposition(disposition)`）。
   * 空串 = 服务端没给，调用方沿用现有名称。
   */
  disposition: string = '';
}

export enum SubscriptionFetchErrorKind {
  NETWORK = 'network',
  HTTP = 'http',
  EMPTY_RESPONSE = 'emptyResponse',
  DECODE = 'decode'
}

/** 保留拉取失败边界，供 SubscriptionService 映射为准确的刷新状态。 */
export class SubscriptionFetchError extends Error {
  kind: SubscriptionFetchErrorKind;
  /**
   * 失败时的 HTTP 状态码（0 = 不适用/未知）。429/403 需要与普通 http 错误区分：
   * 面板限流与「地址写错」的用户提示完全不同（漏洞 6：429/403 vs 200 但 0 条目）。
   */
  httpStatus: number = 0;
  /**
   * 面向用户的可操作建议（如「请先连接 VPN 再重试」）。空串表示无需额外提示。
   * 与 message 分开是因为 message 里含 URL 与原始错误码，适合日志，
   * 而卡片/弹窗要展示的是人话 + 下一步该干什么。
   */
  advice: string = '';
  /** 传输层失败（无 HTTP 响应）：换 UA 不可能修好，用于终止 UA 链。 */
  transportFailure: boolean = false;

  constructor(kind: SubscriptionFetchErrorKind, message: string, httpStatus: number = 0) {
    super(message);
    this.kind = kind;
    this.httpStatus = httpStatus;
  }

  /** 面板限流/拒绝访问 */
  isRateLimited(): boolean {
    return this.kind === SubscriptionFetchErrorKind.HTTP
      && (this.httpStatus === 429 || this.httpStatus === 403);
  }
}

export class SubscriptionFetchPolicy {
  /**
   * 依次尝试 UA 链，返回第一个非空响应体。HTTP 与 HTTPS 同样允许（应用明确支持
   * http 订阅链接；SSRF 防护仍由公网地址校验保证）。
   *
   * @param etag 上次成功拉取拿到的 ETag（可空）。非空时带 `If-None-Match`：
   *   面板内容未变会回 304，省掉整份订阅的下载与解析（对齐 FlClash/Clash Verge
   *   的增量刷新语义）。
   */
  static async fetch(urlStr: string, headerName: string, headerValue: string,
    allowInsecureHttp: boolean, etag: string = ''): Promise<SubscriptionFetchResult> {
    // 本地转换订阅（`http://127.0.0.1:65530/localsub/<id>.yaml`）：由应用内渲染，
    // **不联网、不占端口**。必须在地址校验之前分流 —— 它是 loopback，公网守卫会拒。
    if (LocalSubConverter.isLocalUrl(urlStr)) {
      const id = LocalSubConverter.idOf(urlStr);
      const rendered = LocalSubConverter.render(id);
      if (!rendered.ok) {
        throw new SubscriptionFetchError(SubscriptionFetchErrorKind.HTTP,
          `本地转换订阅不可用：${rendered.reason}`);
      }
      const local = new SubscriptionFetchResult();
      local.body = rendered.yaml;
      local.etag = '';
      return local;
    }
    // ── FlClash 同构（`lib/common/request.dart:150-165` 的 `downloadTarget`）──
    // 订阅地址带 `user:pass@` 时把它从 URL 里剥掉、转成 `Authorization: Basic`：
    // 一部分面板用 HTTP Basic 鉴权而不是 token 路径，FlClash 支持这种写法。
    // 必须在地址校验**之前**剥：校验规则不允许 authority 里出现 '@'。
    const auth = SubscriptionFetchPolicy.authTarget(urlStr);
    const fetchUrl = auth.url;
    if (!SubscriptionFetchPolicy.isValidSubscriptionUrl(fetchUrl, allowInsecureHttp)) {
      // 明文 http 单独给可行动提示：它现在是「默认禁用」而不是「地址非法」。
      if (!allowInsecureHttp && fetchUrl.toLowerCase().startsWith('http://')) {
        throw new SubscriptionFetchError(SubscriptionFetchErrorKind.HTTP,
          '该订阅是明文 HTTP 链接：默认已禁用。请改用机场提供的 https 链接，'
            + '或在「设置 → 允许明文 HTTP 订阅」中显式打开');
      }
      throw new SubscriptionFetchError(SubscriptionFetchErrorKind.HTTP,
        '订阅地址无效：仅允许公开 HTTP/HTTPS 地址');
    }
    const customHeader = headerName.length > 0 && headerValue.length > 0;
    const attempts: string[] = [];
    // 整条 UA 链里出现过的 HTTP 状态码（用于区分限流与其它错误；优先保留 429/403）
    let rateLimitStatus = 0;
    let lastHttpStatus = 0;
    // 首个传输层失败（无 HTTP 状态）的原始消息，用于生成可读原因
    let transportMessage = '';
    let transportAttempts = 0;
    const transportStartedAt = Date.now();
    // 用尽预算/次数后才真正收束；否则同一 UA 重试（换连接 = 可能落到另一个 IP）
    let transportExhausted = false;
    let uaIndex = 0;
    while (uaIndex < UA_CHAIN.length) {
      const ua = customHeader ? headerValue : UA_CHAIN[uaIndex];
      // setAppHttpProxy 成功只表示代理配置已提交，mixed-port 可能仍在启动。
      // 先等本地端口真正响应，避免首个请求撞在内核启动窗口里。
      if (AppProxyRoute.activePort() > 0 && !AppProxyRoute.isReady()) {
        await AppProxyRoute.waitUntilReady(4000);
      }
      try {
        const headers: Record<string, string> = {};
        if (customHeader && SubscriptionFetchPolicy.maySendCustomHeader(urlStr, headerName)) {
          headers[headerName] = ua;
        } else {
          headers['User-Agent'] = ua;
        }
        if (etag.length > 0) {
          headers['If-None-Match'] = etag;
        }
        if (auth.header.length > 0) {
          headers['Authorization'] = auth.header;
        }
        const result = await SubscriptionFetchPolicy.requestWithRedirectValidation(
          fetchUrl, headers, allowInsecureHttp, 0);
        if (result.notModified) {
          // 304：内容未变。与「响应为空」是完全不同的语义，必须原样返回给调用方，
          // 绝不能落到下面的 EMPTY_RESPONSE 分支（那会把「没变化」报成「拉取失败」）。
          AppLogger.info(TAG, 'subscription not modified (304), reusing cached nodes');
          return result;
        }
        const trimmedLen = result.body.trim().length;
        if (trimmedLen > 0) {
          // 极短响应（<16 字节，典型是 `null` / `""` / `0`）说明面板按 UA 或
          // 凭证回了拒绝体，不是订阅内容 —— 继续换下一个 UA，别把它当成功。
          if (trimmedLen < 16) {
            AppLogger.warn(TAG, `subscription body too short (${trimmedLen} bytes): `
              + `${result.body.trim().substring(0, 32)} — trying next UA`);
            attempts.push(`响应过短(${trimmedLen}字节)`);
          } else {
            AppLogger.info(TAG, `subscription fetched (${result.body.length} bytes)`);
            return result;
          }
        } else {
          attempts.push('响应为空');
        }
      } catch (e) {
        const msg = AppLogger.errText(e);
        AppLogger.warn(TAG, `subscription fetch attempt failed: ${msg}`);
        attempts.push(msg);
        const status = SubscriptionFetchPolicy.extractHttpStatus(e, msg);
        if (status === 429 || status === 403) {
          if (rateLimitStatus !== 429) {
            rateLimitStatus = status;
          }
        } else if (status > 0) {
          lastHttpStatus = status;
        } else {
          // 传输层失败（DNS/连接/TLS/超时，拿不到任何 HTTP 状态）。
          //
          // UA 链的用途是**内容协商**（同一个 200 因 UA 不同而返回 YAML 或链接列表），
          // 它修不好「这个域名根本连不上」。此前这里继续把剩下 4 个 UA 跑完，
          // 每个都要吃满 connectTimeout，实测一次被阻断的域名要用户干等
          // 5 × 15s = 75s 才拿到结论。
          //
          // 但「换 UA 无用」不等于「重试无用」：设备到面板的路径存在**概率性**干扰
          // （ikuuu 实测：面板健康、PC 稳定 200，设备端偶发 TLS/RST 后自愈），
          // 换一条新连接有机会绕过。所以先在同一 UA 上重试，用**时间预算**封顶 ——
          // 快速失败（RST/TLS/DNS）能真正重试几次，而一次 15s 超时就会耗尽预算、
          // 立即收束，不会退回 75s。
          transportAttempts = transportAttempts + 1;
          if (transportMessage.length === 0) {
            transportMessage = msg;
          }
          const elapsed = Date.now() - transportStartedAt;
          const canRetry = transportAttempts < TRANSPORT_RETRY_MAX
            && elapsed < TRANSPORT_RETRY_BUDGET_MS;
          if (canRetry) {
            AppLogger.info(TAG, `transport failure ${transportAttempts}/${TRANSPORT_RETRY_MAX}, `
              + `retrying same UA after ${TRANSPORT_RETRY_BACKOFF_MS}ms (elapsed ${elapsed}ms)`);
            // 直连失败时，隧道可能刚好完成启动。等待一次 mixed-port 就绪，
            // 下一次请求会自动切换到代理；若仍未就绪则保持直连。
            if (AppProxyRoute.activePort() > 0 && !AppProxyRoute.isReady()) {
              await AppProxyRoute.waitUntilReady(3000);
            }
            await SubscriptionFetchPolicy.delay(TRANSPORT_RETRY_BACKOFF_MS);
            // uaIndex 不自增 → 重试同一个 UA
            continue;
          }
          transportExhausted = true;
          break;
        }
      }
      uaIndex = uaIndex + 1;
    }
    // 重试会让同一条消息重复入列，摘要按「去重后的前 2 条」展示，避免噪声
    const uniqueAttempts: string[] = [];
    for (const item of attempts) {
      if (!uniqueAttempts.includes(item)) {
        uniqueAttempts.push(item);
      }
    }
    const summary = uniqueAttempts.slice(0, 2).join(' / ');
    if (attempts.length > 0 && attempts.every((item: string) => item === '响应为空')) {
      throw new SubscriptionFetchError(SubscriptionFetchErrorKind.EMPTY_RESPONSE,
        `订阅响应为空（${SubscriptionFetchPolicy.redactUrl(urlStr)}）`);
    }
    if (rateLimitStatus > 0) {
      // 全 UA 链都拿到 429/403：面板限流/拒绝，而不是地址或网络问题
      throw new SubscriptionFetchError(SubscriptionFetchErrorKind.HTTP,
        `面板限流或拒绝访问（HTTP ${rateLimitStatus}，${UA_CHAIN.length} 个 UA 全部失败，`
        + `请稍后重试或更换订阅链接）：${summary}`, rateLimitStatus);
    }
    if (attempts.some((item: string) => item.startsWith('HTTP '))) {
      throw new SubscriptionFetchError(SubscriptionFetchErrorKind.HTTP,
        `订阅 HTTP 请求失败（${SubscriptionFetchPolicy.redactUrl(urlStr)}）：${summary}`,
        lastHttpStatus);
    }
    if (attempts.some((item: string) => item.includes('解码失败'))) {
      throw new SubscriptionFetchError(SubscriptionFetchErrorKind.DECODE,
        `订阅响应解码失败（${SubscriptionFetchPolicy.redactUrl(urlStr)}）：${summary}`);
    }
    // 网络失败：message 保留原始错误码（日志用），advice 给出人话 + 下一步（UI 用）
    const err = new SubscriptionFetchError(SubscriptionFetchErrorKind.NETWORK,
      `订阅拉取失败（${SubscriptionFetchPolicy.redactUrl(urlStr)}）：${summary}`);
    err.transportFailure = transportAttempts > 0;
    err.advice = SubscriptionFetchPolicy.transportAdvice(transportMessage, urlStr);
    if (transportAttempts > 1) {
      // 让用户知道「不是没试」：多次重试仍失败，通常说明该域名在当前网络确实不可达
      err.advice += `（已自动重试 ${transportAttempts} 次仍失败）`;
    }
    throw err;
  }

  /** 退避等待（与 ClashApiService.sleep 同款写法，ArkTS 下可直接 await） */
  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => resolve(), ms);
    });
  }

  /**
   * 把传输层原始错误翻译成用户能看懂的原因 + 该怎么做。
   * 只做关键词归类（各平台错误码不统一），拿不准就退回通用文案，
   * 绝不臆断具体原因。
   */
  static transportAdvice(rawMessage: string, urlStr: string): string {
    const msg = rawMessage.toLowerCase();
    // 分类只用于选「下一步建议」，所以这里保留 cause 键；
    // 展示句单独成句（不能用 `该订阅地址${cause}` 拼，会出现
    // 「该订阅地址TLS 握手失败」「该订阅地址地址被判定为…」这类病句）。
    let cause = '';
    if (msg.includes('未解析到地址') || msg.includes('enotfound')
      || msg.includes('nodename') || msg.includes('name not resolved')
      || msg.includes('getaddressesbyname')) {
      cause = 'dns';
    } else if (msg.includes('timeout') || msg.includes('超时') || msg.includes('2300028')
      || msg.includes('2300034') || msg.includes('timed out')) {
      cause = 'timeout';
    } else if (msg.includes('reset') || msg.includes('errno=104') || msg.includes('econnreset')
      || msg.includes('broken pipe') || msg.includes('aborted')) {
      cause = 'reset';
    } else if (msg.includes('ssl') || msg.includes('tls') || msg.includes('certificate')
      || msg.includes('handshake')) {
      cause = 'tls';
    } else if (msg.includes('私网') || msg.includes('保留地址')) {
      cause = 'reserved';
    } else if (msg.includes('超过') && msg.includes('限制')) {
      cause = 'toolarge';
    } else {
      cause = 'unreachable';
    }

    let advice = '';
    if (cause === 'dns') {
      advice = '无法解析该订阅地址的域名。请检查地址是否写错，或更换 DNS/网络后重试。';
    } else if (cause === 'timeout') {
      advice = '连接该订阅地址超时。若它在浏览器/电脑客户端也要挂代理才能打开，'
        + '请先连接 VPN 后重试；或改用可直连的订阅地址。';
    } else if (cause === 'reset') {
      advice = '连接该订阅地址时被重置（常见于域名被阻断）。若它在浏览器/电脑客户端也要挂代理才能打开，'
        + '请先连接 VPN 后重试；或改用可直连的订阅地址。';
    } else if (cause === 'tls') {
      advice = '与该订阅地址的 TLS 握手失败（证书校验未通过，或连接被中间设备干扰）。'
        + '若它在浏览器/电脑客户端也要挂代理才能打开，请先连接 VPN 后重试；'
        + '也可能是该面板证书本身异常，可稍后再试。';
    } else if (cause === 'reserved') {
      advice = '该订阅地址被判定为内网或保留地址，已按安全策略拒绝。请确认地址是否为公开域名。';
    } else if (cause === 'toolarge') {
      advice = '该订阅响应体超过大小限制（8 MiB），已拒绝。请确认地址指向的是订阅而不是网页。';
    } else {
      advice = '无法连接到该订阅地址。若它在浏览器/电脑客户端也要挂代理才能打开，'
        + '请先连接 VPN 后重试；或改用可直连的订阅地址。';
    }
    return advice;
  }

  /** 从错误对象或消息文本中提取 HTTP 状态码（0 = 无） */
  private static extractHttpStatus(e: Object, msg: string): number {
    if (e instanceof SubscriptionFetchError && e.httpStatus > 0) {
      return e.httpStatus;
    }
    const m = msg.match(/HTTP\s+(\d{3})/);
    if (m === null) {
      return 0;
    }
    const code = Number(m[1]);
    return Number.isInteger(code) ? code : 0;
  }

  private static async requestWithRedirectValidation(urlStr: string, headers: Record<string, string>,
    allowInsecureHttp: boolean, redirectCount: number): Promise<SubscriptionFetchResult> {
    if (redirectCount > MAX_REDIRECTS) {
      throw new Error('订阅重定向次数超限');
    }
    await SubscriptionFetchPolicy.validateResolvedTarget(urlStr, allowInsecureHttp);
    const req = http.createHttp();
    try {
      const resp = await req.request(urlStr, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 15000,
        readTimeout: 20000,
        usingCache: false,
        // 隧道已连接时走本地 mixed 端口（被墙面板/明文拦截才能刷新），
        // 断开或 mixed-port 尚未就绪时 false → 直连；就绪后才经隧道请求
        usingProxy: AppProxyRoute.isReady(),
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        maxRedirects: 0
      });
      if (resp.responseCode >= 300 && resp.responseCode < 400) {
        const location = SubscriptionFetchPolicy.headerValue(resp.header, 'location');
        if (location.length === 0) {
          throw new Error(`HTTP ${resp.responseCode} 重定向缺少 Location`);
        }
        const nextUrl = SubscriptionFetchPolicy.resolveRedirectUrl(urlStr, location);
        return SubscriptionFetchPolicy.requestWithRedirectValidation(
          nextUrl, SubscriptionFetchPolicy.redirectHeaders(headers, urlStr, nextUrl),
          allowInsecureHttp, redirectCount + 1);
      }
      if (resp.responseCode === 304) {
        // 条件请求命中：内容未变，无响应体。etag 原样回传（服务端可能刷新了 ETag）。
        const notModified = new SubscriptionFetchResult();
        notModified.notModified = true;
        notModified.etag = SubscriptionFetchPolicy.responseEtag(resp.header);
        notModified.userInfo = SubscriptionFetchPolicy.parseUserInfo(
          SubscriptionFetchPolicy.headerValue(resp.header, 'subscription-userinfo'));
        notModified.disposition = SubscriptionFetchPolicy.headerValue(resp.header, 'content-disposition');
        return notModified;
      }
      if (resp.responseCode !== 200) {
        throw new SubscriptionFetchError(SubscriptionFetchErrorKind.HTTP, `HTTP ${resp.responseCode}`);
      }
      let bytes = 0;
      let body = '';
      if (resp.result instanceof ArrayBuffer) {
        const raw = new Uint8Array(resp.result);
        bytes = raw.length;
        if (!SubscriptionFetchPolicy.isResponseSizeAllowed(bytes)) {
          throw new Error('订阅响应体超过 8 MiB 限制');
        }
        // ── FlClash 同构（`lib/common/request.dart` 的 `decompressUnlabeled`）──
        // 部分机场发的是**没有 Content-Encoding 头**的 gzip/zlib 流（内核读不了，
        // 按 UTF-8 解码会变乱码）。按魔数识别并解压，与 FlClash 一致。
        let payload: Uint8Array = raw;
        if (HttpBodyCodec.looksCompressed(raw)) {
          try {
            payload = HttpBodyCodec.decompress(raw);
          } catch (e) {
            throw new SubscriptionFetchError(SubscriptionFetchErrorKind.DECODE,
              `订阅响应解压失败（gzip/zlib 流损坏）：${AppLogger.errText(e)}`);
          }
          if (!SubscriptionFetchPolicy.isResponseSizeAllowed(payload.length)) {
            throw new Error('订阅响应体解压后超过 8 MiB 限制');
          }
        }
        try {
          body = util.TextDecoder.create('utf-8').decodeToString(payload);
        } catch (e) {
          throw new SubscriptionFetchError(SubscriptionFetchErrorKind.DECODE,
            `响应 UTF-8 解码失败：${AppLogger.errText(e)}`);
        }
      } else if (typeof resp.result === 'string') {
        body = resp.result as string;
        bytes = body.length;
        if (!SubscriptionFetchPolicy.isResponseSizeAllowed(bytes)) {
          throw new Error('订阅响应体超过 8 MiB 限制');
        }
      }
      const out = new SubscriptionFetchResult();
      out.body = body.trim();
      out.userInfo = SubscriptionFetchPolicy.parseUserInfo(
        SubscriptionFetchPolicy.headerValue(resp.header, 'subscription-userinfo'));
      out.etag = SubscriptionFetchPolicy.responseEtag(resp.header);
      out.disposition = SubscriptionFetchPolicy.headerValue(resp.header, 'content-disposition');
      return out;
    } finally {
      req.destroy();
    }
  }

  /**
   * 取响应的 ETag 作为条件请求凭据；服务端只给 Last-Modified 时退而用后者
   * （两者都是合法的 If-None-Match 值来源）。
   */
  private static responseEtag(header: Object): string {
    const etag = SubscriptionFetchPolicy.headerValue(header, 'etag');
    if (etag.length > 0) {
      return etag;
    }
    return SubscriptionFetchPolicy.headerValue(header, 'last-modified');
  }

  private static async validateResolvedTarget(urlStr: string, allowInsecureHttp: boolean): Promise<void> {
    if (LocalSubConverter.isLocalUrl(urlStr)) {
      // 本地转换订阅不会走到这里（fetch() 已提前分流），保留分支只为防御未来新入口
      return;
    }
    if (!SubscriptionFetchPolicy.isValidSubscriptionUrl(urlStr, allowInsecureHttp)) {
      throw new Error('订阅目标不是允许的公开地址');
    }
    const parsed = url.URL.parseURL(urlStr);
    const host = SubscriptionFetchPolicy.extractHost(parsed.host);
    if (host.includes(':') || /^\d{1,3}(\.\d{1,3}){3}$/.test(host)) {
      if (!SubscriptionFetchPolicy.isPublicIpAddress(host)) {
        throw new Error('订阅目标命中私网或保留地址');
      }
      return;
    }
    const addresses = await connection.getAddressesByName(host);
    if (addresses.length === 0) {
      throw new Error('订阅域名未解析到地址');
    }
    for (const address of addresses) {
      if (SubscriptionFetchPolicy.isPublicIpAddress(address.address)) {
        continue;
      }
      // 兼容路径：mihomo 的 fake-ip 把域名解析到 198.18.0.0/15（IPv6 fc00::/18）。
      // 本应用默认已改 redir-host（2026-10-21，见 ClashConfigGenerator.pushDnsSection），
      // 正常不会出现这些地址；但用户可以在 YAML 覆盖层里自己写回 fake-ip，所以这条
      // 放行必须保留。该网段不可能承载真实服务：无隧道时连它必然失败（无 SSRF 风险），
      // 有隧道时连接会被本应用 TUN 截获并按域名回源 —— 属预期路径。此前该场景被误判为
      // 「私网/保留地址」拦截，导致「VPN 开启后刷新订阅」必然失败，这里无条件放行。
      if (SubscriptionFetchPolicy.isFakeIp(address.address)) {
        continue;
      }
      throw new Error('订阅域名解析到私网或保留地址');
    }
  }

  private static headerValue(header: Object, name: string): string {
    const values = JSON.parse(JSON.stringify(header)) as Record<string, Object>;
    for (const key of Object.keys(values)) {
      if (key.toLowerCase() === name.toLowerCase()) {
        const value = values[key];
        if (typeof value === 'string') {
          return value as string;
        }
        if (Array.isArray(value) && value.length > 0) {
          return String(value[0]);
        }
      }
    }
    return '';
  }

  static parseUserInfo(value: string): SubscriptionUserInfo {
    const out = new SubscriptionUserInfo();
    for (const item of value.split(';')) {
      const pair = item.trim().split('=');
      if (pair.length !== 2 || !/^\d+$/.test(pair[1].trim())) {
        continue;
      }
      const numberValue = Number(pair[1].trim());
      if (!Number.isSafeInteger(numberValue) || numberValue < 0) {
        continue;
      }
      const key = pair[0].trim().toLowerCase();
      if (key === 'upload') out.uploadBytes = numberValue;
      else if (key === 'download') out.downloadBytes = numberValue;
      else if (key === 'total') out.totalBytes = numberValue;
      else if (key === 'expire') out.expireAt = numberValue * 1000;
    }
    return out;
  }

  private static resolveRedirectUrl(currentUrl: string, location: string): string {
    if (location.startsWith('https://') || location.startsWith('http://')) {
      return location;
    }
    const parsed = url.URL.parseURL(currentUrl);
    const origin = `${parsed.protocol}//${parsed.host}`;
    if (location.startsWith('/')) {
      return origin + location;
    }
    const slash = parsed.pathname.lastIndexOf('/');
    const base = slash >= 0 ? parsed.pathname.substring(0, slash + 1) : '/';
    return origin + base + location;
  }

  /**
   * 把「URL 里的 userinfo」转成 Authorization 头（FlClash `downloadTarget` 等价实现）。
   *
   * `https://user:pass@panel.example/sub` 这类地址一部分机场当 HTTP Basic 凭据用；
   * 直接带着 userinfo 请求会被部分 HTTP 实现拒绝或原样发出去。这里剥掉 userinfo、
   * 生成 `Basic base64(user:pass)`，并把请求地址换成不带凭据的形态。
   */
  static authTarget(urlStr: string): FetchAuthTarget {
    const out = new FetchAuthTarget();
    out.url = urlStr;
    const schemeAt = urlStr.indexOf('://');
    if (schemeAt < 0) {
      return out;
    }
    const authorityStart = schemeAt + 3;
    let authorityEnd = urlStr.length;
    const stops: string[] = ['/', '?', '#'];
    for (const stop of stops) {
      const index = urlStr.indexOf(stop, authorityStart);
      if (index >= 0 && index < authorityEnd) {
        authorityEnd = index;
      }
    }
    const authority = urlStr.substring(authorityStart, authorityEnd);
    const at = authority.lastIndexOf('@');
    if (at < 0) {
      return out;
    }
    const userinfo = authority.substring(0, at);
    const hostPart = authority.substring(at + 1);
    if (userinfo.length === 0 || hostPart.length === 0) {
      return out;
    }
    const colon = userinfo.indexOf(':');
    const user = SubscriptionFetchPolicy.percentDecode(colon >= 0 ? userinfo.substring(0, colon) : userinfo);
    const password = colon >= 0 ? SubscriptionFetchPolicy.percentDecode(userinfo.substring(colon + 1)) : '';
    const text = `${user}:${password}`;
    const bytes = util.TextEncoder.create('utf-8').encodeInto(text);
    out.header = `Basic ${new util.Base64Helper().encodeToStringSync(bytes)}`;
    out.url = urlStr.substring(0, authorityStart) + hostPart + urlStr.substring(authorityEnd);
    return out;
  }

  /**
   * `Content-Disposition` → 订阅名（FlClash `getFileNameForDisposition` 等价实现）。
   *
   * FlClash 在**首次添加**订阅时用这个文件名当标题（`lib/models/profile.dart:186-198`）；
   * 解析规则照抄：优先 `filename*=UTF-8''<pct-encoded>`（取 `''` 之后那段再解码），
   * 其次 `filename="..."`。拿不到返回空串（调用方保留现有名称）。
   */
  static fileNameFromDisposition(disposition: string): string {
    if (disposition.length === 0) {
      return '';
    }
    // HeaderValue.parse 的简化版：按 ';' 切参数，引号内的 ';' 不切
    const parts: string[] = [];
    let buffer = '';
    let quoted = false;
    for (let i = 0; i < disposition.length; i++) {
      const ch = disposition.charAt(i);
      if (ch === '"') {
        quoted = !quoted;
        buffer = buffer + ch;
        continue;
      }
      if (ch === ';' && !quoted) {
        parts.push(buffer);
        buffer = '';
        continue;
      }
      buffer = buffer + ch;
    }
    parts.push(buffer);
    let extended = '';
    let plain = '';
    for (let i = 1; i < parts.length; i++) {
      const item = parts[i].trim();
      const eq = item.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const key = item.substring(0, eq).trim().toLowerCase();
      let value = item.substring(eq + 1).trim();
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      if (key === 'filename*') {
        extended = value;
      } else if (key === 'filename') {
        plain = value;
      }
    }
    if (extended.length > 0) {
      const sep = extended.indexOf("''");
      if (sep >= 0) {
        const decoded = SubscriptionFetchPolicy.percentDecode(extended.substring(sep + 2)).trim();
        if (decoded.length > 0) {
          return decoded;
        }
      } else if (extended.trim().length > 0) {
        return extended.trim();
      }
    }
    return plain.trim();
  }

  /** 百分号解码（只处理 `%XX`，其余按字节透传后统一按 UTF-8 还原） */
  private static percentDecode(value: string): string {
    if (value.indexOf('%') < 0) {
      return value;
    }
    const bytes: number[] = [];
    let i = 0;
    while (i < value.length) {
      const ch = value.charAt(i);
      if (ch === '%' && i + 2 < value.length) {
        const code = Number.parseInt(value.substring(i + 1, i + 3), 16);
        if (!Number.isNaN(code)) {
          bytes.push(code & 0xff);
          i = i + 3;
          continue;
        }
      }
      bytes.push(value.charCodeAt(i) & 0xff);
      i = i + 1;
    }
    try {
      const buffer = new Uint8Array(bytes.length);
      for (let k = 0; k < bytes.length; k++) {
        buffer[k] = bytes[k];
      }
      return util.TextDecoder.create('utf-8').decodeToString(buffer);
    } catch (e) {
      return value;
    }
  }

  /** 取 URL 的 host（解析失败返回空串，用于判断重定向是否跨主机） */
  private static hostOf(value: string): string {
    try {
      return url.URL.parseURL(value).host;
    } catch (e) {
      return '';
    }
  }

  private static redirectHeaders(headers: Record<string, string>, fromUrl: string,
    nextUrl: string): Record<string, string> {
    const out: Record<string, string> = {};
    const crossHost = SubscriptionFetchPolicy.hostOf(nextUrl) !== SubscriptionFetchPolicy.hostOf(fromUrl);
    for (const key of Object.keys(headers)) {
      // 跨主机重定向不许转发 Authorization（Basic 凭据只属于原面板）
      if (crossHost && key.toLowerCase() === 'authorization') {
        continue;
      }
      if (SubscriptionFetchPolicy.maySendCustomHeader(nextUrl, key)) {
        out[key] = headers[key];
      }
    }
    return out;
  }

  private static extractHost(authority: string): string {
    const lower = authority.toLowerCase();
    if (lower.startsWith('[')) {
      const close = lower.indexOf(']');
      return close > 0 ? lower.substring(1, close) : '';
    }
    const colon = lower.lastIndexOf(':');
    return colon >= 0 && lower.indexOf(':') === colon ? lower.substring(0, colon) : lower;
  }

  private static parseIpv4(value: string): number[] | null {
    const match = value.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
    if (match === null) {
      return null;
    }
    const parts: number[] = [Number(match[1]), Number(match[2]), Number(match[3]), Number(match[4])];
    for (const part of parts) {
      if (part < 0 || part > 255) {
        return null;
      }
    }
    return parts;
  }

  private static expandIpv6(value: string): number[] | null {
    let normalized = value.toLowerCase();
    if (!/^[0-9a-f:.]+$/.test(normalized) || normalized.includes('%')) {
      return null;
    }
    const lastColon = normalized.lastIndexOf(':');
    const ipv4Tail = normalized.substring(lastColon + 1);
    if (ipv4Tail.includes('.')) {
      const ipv4 = SubscriptionFetchPolicy.parseIpv4(ipv4Tail);
      if (ipv4 === null) {
        return null;
      }
      normalized = normalized.substring(0, lastColon + 1)
        + ((ipv4[0] << 8) | ipv4[1]).toString(16) + ':'
        + ((ipv4[2] << 8) | ipv4[3]).toString(16);
    }
    const halves = normalized.split('::');
    if (halves.length > 2) {
      return null;
    }
    const left: string[] = halves[0].length === 0 ? [] : halves[0].split(':');
    const right: string[] = halves.length === 1 || halves[1].length === 0 ? [] : halves[1].split(':');
    if ((halves.length === 1 && left.length !== 8)
      || (halves.length === 2 && left.length + right.length >= 8)) {
      return null;
    }
    const groups: number[] = [];
    for (const item of left) {
      if (!/^[0-9a-f]{1,4}$/.test(item)) {
        return null;
      }
      groups.push(parseInt(item, 16));
    }
    if (halves.length === 2) {
      while (groups.length + right.length < 8) {
        groups.push(0);
      }
    }
    for (const item of right) {
      if (!/^[0-9a-f]{1,4}$/.test(item)) {
        return null;
      }
      groups.push(parseInt(item, 16));
    }
    return groups.length === 8 ? groups : null;
  }

  static isPublicIpAddress(address: string): boolean {
    const value = address.trim().toLowerCase();
    const ipv4 = SubscriptionFetchPolicy.parseIpv4(value);
    if (ipv4 !== null) {
      const a = ipv4[0];
      const b = ipv4[1];
      const c = ipv4[2];
      const d = ipv4[3];
      return !(a === 0 || a === 10 || a === 127 || a >= 224
        || (a === 100 && b >= 64 && b <= 127)
        || (a === 169 && b === 254)
        || (a === 172 && b >= 16 && b <= 31)
        || (a === 192 && b === 0)
        || (a === 192 && b === 168)
        || (a === 198 && (b === 18 || b === 19))
        || (a === 198 && b === 51 && c === 100)
        || (a === 203 && b === 0 && c === 113)
        || (a === 255 && b === 255 && c === 255 && d === 255));
    }
    const groups = SubscriptionFetchPolicy.expandIpv6(value);
    if (groups === null) {
      return false;
    }
    const allZero = groups.every((part) => part === 0);
    const loopback = groups.slice(0, 7).every((part) => part === 0) && groups[7] === 1;
    const mappedIpv4 = groups.slice(0, 5).every((part) => part === 0) && groups[5] === 0xffff;
    if (mappedIpv4) {
      return SubscriptionFetchPolicy.isPublicIpAddress(
        `${groups[6] >> 8}.${groups[6] & 255}.${groups[7] >> 8}.${groups[7] & 255}`);
    }
    return !(allZero || loopback
      || (groups[0] & 0xfe00) === 0xfc00
      || (groups[0] & 0xffc0) === 0xfe80
      || (groups[0] & 0xff00) === 0xff00
      || (groups[0] === 0x2001 && groups[1] === 0x0db8));
  }

  /**
   * Mihomo fake-ip 默认网段：IPv4 198.18.0.0/15（198.18/198.19，RFC 2544 基准测试保留段），
   * IPv6 为 fc00::/18。本应用默认用 redir-host（不发假地址），此判定只为兼容用户
   * 在 YAML 覆盖层里自行写回 fake-ip 的场景。
   */
  static isFakeIp(address: string): boolean {
    const value = address.trim().toLowerCase();
    const ipv4 = SubscriptionFetchPolicy.parseIpv4(value);
    if (ipv4 !== null) {
      return ipv4[0] === 198 && (ipv4[1] === 18 || ipv4[1] === 19);
    }
    const groups = SubscriptionFetchPolicy.expandIpv6(value);
    if (groups === null) {
      return false;
    }
    return (groups[0] & 0xffc0) === 0xfc00;
  }

  static maySendCustomHeader(urlStr: string, headerName: string): boolean {
    const lowerName = headerName.toLowerCase();
    if (lowerName === 'user-agent') {
      return true;
    }
    return urlStr.toLowerCase().startsWith('https://');
  }

  static isResponseSizeAllowed(size: number): boolean {
    return size >= 0 && size <= MAX_RESPONSE_BYTES;
  }

  static isFieldLengthAllowed(value: string): boolean {
    return value.length <= MAX_FIELD_LENGTH;
  }

  static isNodeCountAllowed(count: number): boolean {
    return count >= 0 && count <= MAX_NODE_COUNT;
  }

  /** URL 脱敏（只保留 host），配合 log_redactor */
  static redactUrl(urlStr: string): string {
    try {
      // 必须先剥 userinfo：ArkTS 的 `URL.host` 把 `user:pass@` 算在 host 里，
      // 直接打印会把 Basic 凭据写进日志/诊断文本。
      return url.URL.parseURL(SubscriptionFetchPolicy.authTarget(urlStr).url).host;
    } catch (e) {
      return '<invalid-url>';
    }
  }

  /** 订阅 URL 合法性：允许公开 HTTP/HTTPS 地址。 */
  static isValidSubscriptionUrl(urlStr: string, allowInsecureHttp: boolean = false): boolean {
    // 本地转换订阅由应用内渲染（不发网络请求），不受「仅公开地址 / 明文 http 禁用」约束
    if (LocalSubConverter.isLocalUrl(urlStr)) {
      return LocalSubConverter.idOf(urlStr).length > 0;
    }
    // 带 `user:pass@` 的地址先剥掉 userinfo 再校验（fetch 时会转成 Authorization:
    // Basic；校验规则本身不允许 authority 里出现 '@'）。
    const target = SubscriptionFetchPolicy.authTarget(urlStr).url;
    const lower = target.toLowerCase();
    if (target.length === 0 || target.length > 8192
      || (!lower.startsWith('https://') && !(allowInsecureHttp && lower.startsWith('http://')))
      || target.includes('\n') || target.includes('\r') || target.includes('\t')) {
      return false;
    }
    try {
      const parsed = url.URL.parseURL(target);
      const proto = parsed.protocol.replace(/:/g, '').toLowerCase();
      let authority = parsed.host.toLowerCase();
      if ((proto !== 'https' && !(allowInsecureHttp && proto === 'http'))
        || authority.length === 0 || authority.includes('@')) {
        return false;
      }

      let host = authority;
      let port = '';
      if (authority.startsWith('[')) {
        const close = authority.indexOf(']');
        if (close <= 1) {
          return false;
        }
        host = authority.substring(1, close);
        const suffix = authority.substring(close + 1);
        if (suffix.length > 0) {
          if (!suffix.startsWith(':')) {
            return false;
          }
          port = suffix.substring(1);
        }
      } else {
        const colon = authority.lastIndexOf(':');
        if (colon >= 0) {
          if (authority.indexOf(':') !== colon) {
            return false;
          }
          host = authority.substring(0, colon);
          port = authority.substring(colon + 1);
        }
      }
      if (host.length === 0 || (port.length > 0 && (!/^\d{1,5}$/.test(port)
        || parseInt(port) <= 0 || parseInt(port) > 65535))) {
        return false;
      }

      if (host === 'localhost' || host.endsWith('.localhost') || host.endsWith('.local')
        || host === 'localhost.localdomain' || host === 'ip6-localhost' || host === 'ip6-loopback'
        || host.endsWith('.internal') || host.endsWith('.home') || host.endsWith('.lan')) {
        return false;
      }

      if (SubscriptionFetchPolicy.parseIpv4(host) !== null || host.includes(':')) {
        return SubscriptionFetchPolicy.isPublicIpAddress(host);
      }

      if (host.length > 253 || host.startsWith('.') || host.endsWith('.') || host.includes('..')) {
        return false;
      }
      const labels = host.split('.');
      if (labels.length < 2) {
        return false;
      }
      for (const label of labels) {
        if (label.length === 0 || label.length > 63 || label.startsWith('-') || label.endsWith('-')
          || !/^[a-z0-9-]+$/.test(label)) {
          return false;
        }
      }
      return true;
    } catch (e) {
      return false;
    }
  }
}
