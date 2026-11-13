/**
 * 订阅取回：单一 User-Agent、一次请求、原始响应交给内核校验。
 * 流程参考 FlClash v0.9.3 request.dart；TLS 栈与其 Dart HttpClient 不同。
 */
import { connection } from '@kit.NetworkKit';
import { AppProxyRoute } from './AppProxyRoute';
import { url, util } from '@kit.ArkTS';
import { AppLogger } from '../utils/AppLogger';
import { AppInfo } from '../utils/AppInfo';
import { LocalSubConverter } from './LocalSubConverter';
import { HttpBodyCodec } from '../subscription/HttpBodyCodec';
import { coreBridge } from '../../core/CoreBridge';
import { SettingsService } from './SettingsService';

const TAG = 'SubscriptionFetchPolicy';
const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;
const MAX_FIELD_LENGTH = 4096;
const MAX_REDIRECTS = 5;
// FlClash 的取回层没有传输层重试（`lib/common/request.dart`：一次请求，失败即抛）。
// 随 UA 链一并删除，避免再出现"我方自造行为"。

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
/**
 * User-Agent —— 照抄 FlClash `lib/common/package.dart` 的 `packageInfo.ua`：
 *   `<AppName>/v<version> clash-verge Platform/<os>`
 *
 * FlClash 只有**一个** UA（配置里可被 globalUa 覆盖），源码里没有 UA 链。
 * 真机取证（2026-11-04，dp3.config-sync.com，同一 URL / 同一 IP）：
 *   PC: curl -A clash-verge/v2.4.2 直连 → 200（34,727 字节真实配置）
 *   设备: app.log 五连 `HTTP 403`，把 UA 换成链里任意一个结果相同
 * 即 UA 轮换对这类拦截无效，它是自造行为，已按 FlClash 删除。
 */
export function tunboxUserAgent(): string {
  // Lead with the mature Clash-Verge token: some panels parse the first product/version pair.
  // Keeping TunBox metadata after it avoids being classified as an obsolete client.
  return `clash-verge/v2.4.2 TunBox/v${AppInfo.version()} Platform/OpenHarmony`;
}

/**
 * FlClash `globalState.ua` 同构：配置文件里写了 `globalUa` 就用它，否则用包 UA。
 * AppSettings 加该字段后自动生效；字段未加时恒走 tunboxUserAgent()（无凭据风险）。
 */
export async function resolveUserAgent(): Promise<string> {
  try {
    const settings = await SettingsService.load();
    const holder: Object = settings;
    const record = holder as Record<string, Object>;
    const globalUa = record['globalUa'];
    if (typeof globalUa === 'string' && globalUa.trim().length > 0) {
      return globalUa.trim();
    }
  } catch (e) {
    AppLogger.warn(TAG, `read globalUa failed: ${AppLogger.errText(e)}`);
  }
  return tunboxUserAgent();
}

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

  /**
   * 面板限流/拒绝访问。
   *
   * 只有 429 是「限流」。403 是**明确的拒绝**（Cloudflare 机器人判定、token 失效、
   * 面板封禁），FlClash 也把它当普通 bad response（`request.dart` 的
   * `DioExceptionType.badResponse`），不叫限流 —— 把 403 说成「请稍后重试」
   * 会把人引向错误方向。
   */
  isRateLimited(): boolean {
    return this.kind === SubscriptionFetchErrorKind.HTTP && this.httpStatus === 429;
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
    etag: string = ''): Promise<SubscriptionFetchResult> {
    // headerName/headerValue 仅为旧调用方兼容保留，FlClash 无此能力：**不透传**。
    // 唯一允许的鉴权是 URL userinfo → Authorization: Basic（见 authTarget）。
    // 本地转换订阅（`http://127.0.0.1:65530/localsub/<id>.yaml`）：由应用内渲染，
    // **不联网、不占端口**。必须在地址校验之前分流 —— 它是 loopback，公网守卫会拒。
    if (LocalSubConverter.isLocalUrl(urlStr)) {
      const id = LocalSubConverter.idOf(urlStr);
      const rendered = LocalSubConverter.render(id);
      if (!rendered.ok) {
        throw new SubscriptionFetchError(SubscriptionFetchErrorKind.HTTP,
          `local converter unavailable: ${rendered.reason}`);
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
    if (!SubscriptionFetchPolicy.isValidSubscriptionUrl(fetchUrl)) {
      throw new SubscriptionFetchError(SubscriptionFetchErrorKind.HTTP,
        'invalid subscription URL: only public http/https addresses allowed');
    }
    const attempts: string[] = [];
    // 一次请求的失败归类（FlClash 取回层没有重试，因此只保留首个失败原因）
    let rateLimitStatus = 0;
    let lastHttpStatus = 0;
    let transportMessage = '';
    let transportAttempts = 0;
    // ── FlClash 同构：单次请求 ─────────────────────────────────────
    // FlClash 的 `Request` 只用**一个** UA（`package.dart` 的 `packageInfo.ua`，
    // 可被配置里的 globalUa 覆盖），失败即失败（`lib/common/request.dart`），
    // 没有 UA 链，也没有传输层重试。我方此前自造的 UA 链已被真机证伪：
    // 同一 URL、同一 IP、同一 UA，PC 得 200 而设备得 403，换 UA 对结果没有任何影响。
    const ua = await resolveUserAgent();
    // 上游在启动时显式走 mixed-port。Go 不读取 setAppHttpProxy，必须跨 NAPI 接线。
    // 本项目使用 uTLS；不能把其 ClientHello 称为 Dart HttpClient 的相同指纹。
    try {
      const native = await coreBridge.fetchText(fetchUrl, ua, auth.header,
        AppProxyRoute.isReady() ? AppProxyRoute.activePort() : 0);
      const result = new SubscriptionFetchResult();
      result.body = native.body;
      result.etag = native.etag;
      result.userInfo = SubscriptionFetchPolicy.parseUserInfo(native.userInfo);
      result.disposition = native.disposition;
      // FlClash 同构：不设最小长度闸门 —— 短 body 也交给 validateAndStore 让原生
      // 解析器判定（R5 前禁文本闸）。空 body 由 CoreBridge 以 EMPTY_RESPONSE 区分。
      AppLogger.info(TAG, `subscription fetched via core (${result.body.length} bytes)`);
      return result;
    } catch (e) {
      const msg = AppLogger.errText(e);
      AppLogger.warn(TAG, `subscription fetch failed: ${msg}`);
      attempts.push(msg);
      if (msg.includes('内核未返回内容') || msg.includes('empty')) {
        throw new SubscriptionFetchError(SubscriptionFetchErrorKind.EMPTY_RESPONSE,
          `empty response (${SubscriptionFetchPolicy.redactUrl(urlStr)})`);
      }
      const status = SubscriptionFetchPolicy.extractHttpStatus(e, msg);
      if (status === 429) {
        rateLimitStatus = status;
      } else if (status > 0) {
        // 403 等明确拒绝走这里：如实报 HTTP 状态，不再冒充「限流」。
        lastHttpStatus = status;
      } else {
        transportAttempts = 1;
        transportMessage = msg;
      }
    }
    // FlClash 同构：错误原文透出（rethrow 语义），中文只在 UI 层映射。
    // kind/httpStatus 保留供调用方分类；message 保留原生原始文本（日志用）。
    const rawMessage = transportMessage.length > 0 ? transportMessage
      : (attempts.length > 0 ? attempts[0] : 'fetch failed');
    if (rateLimitStatus > 0) {
      throw new SubscriptionFetchError(SubscriptionFetchErrorKind.HTTP,
        rawMessage, rateLimitStatus);
    }
    if (lastHttpStatus > 0) {
      throw new SubscriptionFetchError(SubscriptionFetchErrorKind.HTTP,
        rawMessage, lastHttpStatus);
    }
    if (attempts.length > 0 && attempts.every((item: string) => item === 'empty response')) {
      throw new SubscriptionFetchError(SubscriptionFetchErrorKind.EMPTY_RESPONSE,
        rawMessage);
    }
    const err = new SubscriptionFetchError(SubscriptionFetchErrorKind.NETWORK,
      rawMessage);
    err.transportFailure = transportAttempts > 0;
    err.advice = SubscriptionFetchPolicy.transportAdvice(transportMessage, urlStr);
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

    // FlClash 同构：本层只给英文底层建议（日志/诊断用），中文在 UI 映射层产生（§5.6）。
    let advice = '';
    if (cause === 'dns') {
      advice = 'Cannot resolve the subscription hostname. Check the URL or change DNS/network.';
    } else if (cause === 'timeout') {
      advice = 'Connection to the subscription host timed out. If it needs a proxy to open, connect VPN first.';
    } else if (cause === 'reset') {
      advice = 'Connection was reset by the peer (common for blocked domains). Connect VPN first if needed.';
    } else if (cause === 'tls') {
      advice = 'TLS handshake failed (certificate check or a middlebox). Retry later or via VPN.';
    } else if (cause === 'reserved') {
      advice = 'Target is a private/reserved address and was rejected. Confirm it is a public hostname.';
    } else if (cause === 'toolarge') {
      advice = 'Subscription body exceeded the size limit (8 MiB). Confirm the URL is a subscription, not a page.';
    } else {
      advice = 'Cannot reach the subscription host. If it needs a proxy, connect VPN first.';
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

  /**
   * 取响应的 ETag 作为条件请求凭据；服务端只给 Last-Modified 时退而用后者
   * （两者都是合法的 If-None-Match 值来源）。
   */
  private static async validateResolvedTarget(urlStr: string): Promise<void> {
    if (LocalSubConverter.isLocalUrl(urlStr)) {
      // 本地转换订阅不会走到这里（fetch() 已提前分流），保留分支只为防御未来新入口
      return;
    }
    if (!SubscriptionFetchPolicy.isValidSubscriptionUrl(urlStr)) {
      throw new Error('subscription target is not an allowed public address');
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
    // Match downloadTarget in FlClash v0.9.3: decode each colon-separated
    // component, preserving malformed components and a username without ':'.
    const text = userinfo.split(':').map((part: string): string =>
      SubscriptionFetchPolicy.percentDecode(part)).join(':');
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

  /** Strict UTF-8 component decoding; malformed escapes retain the whole component. */
  private static percentDecode(value: string): string {
    try {
      return decodeURIComponent(value);
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

  /**
   * FlClash 同构：无自定义 header 功能 —— 唯一放行的 header 是 userinfo 派生的
   * Authorization: Basic（见 authTarget）。任意 headerValue 透传已删。
   */
  static maySendCustomHeader(urlStr: string, headerName: string): boolean {
    return false;
  }

  static isResponseSizeAllowed(size: number): boolean {
    return size >= 0 && size <= MAX_RESPONSE_BYTES;
  }

  static isFieldLengthAllowed(value: string): boolean {
    return value.length <= MAX_FIELD_LENGTH;
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

  /**
   * 订阅 URL 合法性：仅公开 HTTPS 地址。
   * FlClash 取回层无 http 放行开关（allowInsecureHttp 自创策略已删）：http/https
   * 都按原样放行；私网/回环/保留地址守卫保留（本仓既有安全闸）。
   */
  static isValidSubscriptionUrl(urlStr: string): boolean {
    // 本地转换订阅由应用内渲染（不发网络请求），不受「仅公开地址」约束
    if (LocalSubConverter.isLocalUrl(urlStr)) {
      return LocalSubConverter.idOf(urlStr).length > 0;
    }
    // 带 `user:pass@` 的地址先剥掉 userinfo 再校验（fetch 时会转成 Authorization:
    // Basic；校验规则本身不允许 authority 里出现 '@'）。
    const target = SubscriptionFetchPolicy.authTarget(urlStr).url;
    const lower = target.toLowerCase();
    if (target.length === 0 || target.length > 8192
      || (!lower.startsWith('https://') && !lower.startsWith('http://'))
      || target.includes('\n') || target.includes('\r') || target.includes('\t')) {
      return false;
    }
    try {
      const parsed = url.URL.parseURL(target);
      const proto = parsed.protocol.replace(/:/g, '').toLowerCase();
      let authority = parsed.host.toLowerCase();
      // FlClash 固定上游无 allowInsecureHttp 闸（§5.1）：http/https 都放行，
      // 私网/回环/保留地址仍由下方守卫拦下（这条守卫是本仓既有安全闸，保留）。
      if ((proto !== 'https' && proto !== 'http')
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
