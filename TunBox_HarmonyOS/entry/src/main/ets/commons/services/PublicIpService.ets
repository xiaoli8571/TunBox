/**
 * 节点国家识别策略 + 公网 IP 服务
 * 移植自 upstream: packages/tunbox_shared/lib/utils/node_country_policy.dart
 *                packages/tunbox_shared/lib/services/public_ip_info_service.dart
 *
 * ## 2026-10-19 稳定性加固（0.4.0「取不到公网 IP」复盘的直接产物）
 *
 * 0.4.0 的失败不是"端点挂了"，而是**这条链路没有任何容错**：
 *   · 单端点 `http://ip-api.com`，明文 HTTP（免费版 HTTPS 是付费端点，403 实证）；
 *   · 免费版限流是 **45 次/分钟按出口 IP** 计，超限返回 **HTTP 200 +
 *     `{"status":"fail","message":"..."}`** —— 旧实现只判 `responseCode === 200`
 *     且不读 `status`，于是把"被限流/内网地址/保留地址"全当成成功再判空 IP；
 *   · 失败无重试、无备用端点、无日志 → UI 只能显示「获取公网 IPv4 失败」，
 *     而排查时日志里**一条痕迹都没有**。
 *
 * 现在的策略（顺序固定，逐级降级，全部失败才返回空）：
 *   1. `ip-api.com`（明文，带 status 解析）：拿到 IP + 国家/城市/ISP（UI 需要）；
 *   2. 失败 → 退避重试一次（仅网络类失败；`status=fail` 的限流/内网不重试，
 *      重试只会让限流更久）；
 *   3. 仍失败 → 备用端点 `https://api64.ipify.org?format=json`（HTTPS、无字段、
 *      只给 IP）——**IP 显示优先**，宁可没有国家信息也不能显示"获取失败"；
 *   4. 全失败 → 返回空对象，由 UI 显示失败并允许点击重试。
 *
 * 每次查询都记一行**不含 IP 本身**的日志（trigger/端点/耗时/结果类别），
 * 供用户反馈日志时定案。
 */
import { http } from '@kit.NetworkKit';
import { AppProxyRoute } from './AppProxyRoute';
import { util } from '@kit.ArkTS';
import { PublicIpInfo } from '../models/PublicIpInfo';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'PublicIp';

/** 单次请求预算：连接 5s / 读 8s（0.3.3 口径，未改）。 */
const CONNECT_TIMEOUT_MS = 5000;
const READ_TIMEOUT_MS = 8000;
/** 响应体上限：正常应答 <1KB，超过即视为异常（防解析大对象）。 */
const MAX_RESPONSE_BYTES = 64 * 1024;
/** 网络类失败（超时/断连）的重试间隔；`status=fail` 不重试（见文件头）。 */
const RETRY_DELAY_MS = 400;

/** 查询结果类别：只用于日志与 UI 文案，不参与逻辑判断。 */
export enum IpQueryOutcome {
  OK = 'ok',
  /** ip-api 明确拒绝（限流 / 内网地址 / 保留地址 / 无效查询） */
  REJECTED = 'rejected',
  /** 网络层失败（超时、DNS、连接被拒） */
  NETWORK = 'network',
  /** HTTP 非 200 */
  HTTP = 'http',
  /** 200 但响应体无法解析 */
  MALFORMED = 'malformed'
}

/** 一次查询的完整结果（内部用；对外仍是 PublicIpInfo，保持调用方零改动）。 */
class IpQueryResult {
  info: PublicIpInfo = PublicIpInfo.empty();
  outcome: IpQueryOutcome = IpQueryOutcome.NETWORK;
  /** 端点标识（ip-api / ipify），用于日志。 */
  endpoint: string = '';
  /** ip-api 的 status 字段（ok / fail）；ipify 无此字段，留空。 */
  status: string = '';
  /** ip-api 失败时的 message（已脱敏，仅取前 80 字符）。 */
  message: string = '';
  elapsedMs: number = 0;
}

export interface CountryDef {
  code: string;
  nameZh: string;
  flagEmoji: string;
  keywords: string[];
}

/** 国家关键词表（与 upstream node_country_policy 的识别词一致的核心子集） */
export const COUNTRY_TABLE: CountryDef[] = [
  { code: 'HK', nameZh: '香港', flagEmoji: '🇭🇰', keywords: ['香港', 'hong kong', 'hongkong', 'hk'] },
  { code: 'TW', nameZh: '台湾', flagEmoji: '🇹🇼', keywords: ['台湾', '台灣', 'taiwan', 'tw'] },
  { code: 'JP', nameZh: '日本', flagEmoji: '🇯🇵', keywords: ['日本', 'japan', 'jp'] },
  { code: 'SG', nameZh: '新加坡', flagEmoji: '🇸🇬', keywords: ['新加坡', '狮城', 'singapore', 'sg'] },
  { code: 'US', nameZh: '美国', flagEmoji: '🇺🇸', keywords: ['美国', '美國', 'united states', 'usa', 'us'] },
  { code: 'KR', nameZh: '韩国', flagEmoji: '🇰🇷', keywords: ['韩国', '韓國', 'korea', 'kr'] },
  { code: 'DE', nameZh: '德国', flagEmoji: '🇩🇪', keywords: ['德国', '德國', 'germany', 'de'] },
  { code: 'GB', nameZh: '英国', flagEmoji: '🇬🇧', keywords: ['英国', '英國', 'united kingdom', 'uk', 'gb'] },
  { code: 'MY', nameZh: '马来西亚', flagEmoji: '🇲🇾', keywords: ['马来西亚', 'malaysia', 'my'] },
  { code: 'TH', nameZh: '泰国', flagEmoji: '🇹🇭', keywords: ['泰国', 'thailand', 'th'] },
  { code: 'VN', nameZh: '越南', flagEmoji: '🇻🇳', keywords: ['越南', 'vietnam', 'vn'] },
  { code: 'PH', nameZh: '菲律宾', flagEmoji: '🇵🇭', keywords: ['菲律宾', 'philippines', 'ph'] }
];

export class NodeCountryPolicy {
  /** 从节点名识别国家（小写包含匹配，与 upstream 顺序一致：先匹配中文关键词再英文） */
  static detect(nodeName: string): CountryDef {
    const lower = nodeName.toLowerCase();
    for (const c of COUNTRY_TABLE) {
      for (const k of c.keywords) {
        if (lower.includes(k)) {
          return c;
        }
      }
    }
    return { code: 'XX', nameZh: '其他', flagEmoji: '🌐', keywords: [] };
  }

  /** 展示名规整（对应 node_display_policy.dart）：去协议前缀/线路数字之外的冗余 */
  static displayName(nodeName: string): string {
    return nodeName.replace(/^(ssr?|ss|vmess|trojan)\s*[:|]\s*/i, '').trim();
  }

  /** 排序：按国家表顺序，再按名称（对应 upstream 节点排序） */
  static compare(a: string, b: string): number {
    const ca = COUNTRY_TABLE.findIndex((c) => c.code === NodeCountryPolicy.detect(a).code);
    const cb = COUNTRY_TABLE.findIndex((c) => c.code === NodeCountryPolicy.detect(b).code);
    if (ca !== cb) {
      return ca - cb;
    }
    return a.localeCompare(b);
  }
}

export class PublicIpService {
  /**
   * 查询当前出口公网 IP。
   *
   * @param trigger 触发来源（只用于日志定位：home-bootstrap / after-connect / retry …）
   */
  static async query(trigger: string = 'unknown'): Promise<PublicIpInfo> {
    const first = await PublicIpService.queryPrimary(trigger);
    if (first.info.ip.length > 0) {
      return first.info;
    }
    // 网络类失败才重试：限流/内网地址重试只会加剧限流，且必定同样失败。
    if (first.outcome === IpQueryOutcome.NETWORK) {
      await PublicIpService.delay(RETRY_DELAY_MS);
      const retry = await PublicIpService.queryPrimary(`${trigger}/retry`);
      if (retry.info.ip.length > 0) {
        return retry.info;
      }
    }
    // 备用端点：只保证「有 IP 可显示」，不带国家/城市/ISP。
    const fallback = await PublicIpService.queryFallback(trigger);
    if (fallback.info.ip.length > 0) {
      return fallback.info;
    }
    AppLogger.warn(TAG, `ip query exhausted: trigger=${trigger} `
      + `primary=${first.outcome}/${first.endpoint}(${first.elapsedMs}ms) `
      + `fallback=${fallback.outcome}(${fallback.elapsedMs}ms)`);
    return PublicIpInfo.empty();
  }

  /** 主端点：ip-api（免费版仅 HTTP；HTTPS 是付费 pro 端点，实测 403）。 */
  private static async queryPrimary(trigger: string): Promise<IpQueryResult> {
    const result = new IpQueryResult();
    result.endpoint = 'ip-api';
    const t0 = Date.now();
    const req = http.createHttp();
    try {
      const resp = await req.request('http://ip-api.com/json/?fields=status,message,query,country,countryCode,city,isp,as,timezone', {
        method: http.RequestMethod.GET,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        usingCache: false,
        // 出口 IP 必须经由隧道查询，否则拿到的是本机物理出口（或直接失败）
        usingProxy: AppProxyRoute.activePort() > 0
      });
      result.elapsedMs = Date.now() - t0;
      if (resp.responseCode !== 200) {
        result.outcome = IpQueryOutcome.HTTP;
        PublicIpService.log(trigger, result, `http=${resp.responseCode}`);
        return result;
      }
      const body = PublicIpService.bodyText(resp.result);
      if (body.length === 0) {
        result.outcome = IpQueryOutcome.MALFORMED;
        PublicIpService.log(trigger, result, 'empty body');
        return result;
      }
      let json: Record<string, Object>;
      try {
        json = JSON.parse(body) as Record<string, Object>;
      } catch (parseError) {
        result.outcome = IpQueryOutcome.MALFORMED;
        PublicIpService.log(trigger, result, 'json parse failed');
        return result;
      }
      const status = typeof json['status'] === 'string' ? json['status'] as string : '';
      result.status = status;
      const message = typeof json['message'] === 'string' ? json['message'] as string : '';
      result.message = message.length > 80 ? message.substring(0, 80) : message;
      // 免费版限流 / 内网 / 保留地址 / 非法查询：HTTP 200 但 status=fail
      if (status === 'fail') {
        result.outcome = IpQueryOutcome.REJECTED;
        PublicIpService.log(trigger, result, `status=fail msg=${result.message}`);
        return result;
      }
      const ip = typeof json['query'] === 'string' ? (json['query'] as string).trim() : '';
      if (!PublicIpService.isPlausibleIp(ip)) {
        result.outcome = IpQueryOutcome.MALFORMED;
        PublicIpService.log(trigger, result, 'no plausible ip in payload');
        return result;
      }
      result.info.ip = ip;
      result.info.country = typeof json['country'] === 'string' ? json['country'] as string : '';
      result.info.countryCode = typeof json['countryCode'] === 'string' ? json['countryCode'] as string : '';
      result.info.city = typeof json['city'] === 'string' ? json['city'] as string : '';
      result.info.isp = typeof json['isp'] === 'string' ? json['isp'] as string : '';
      // 数据页「出口 IP」卡片需要 ASN 与时区（对齐 ClashPlus _IpInfoContent 的四行信息）
      result.info.asn = typeof json['as'] === 'string' ? json['as'] as string : '';
      result.info.timezone = typeof json['timezone'] === 'string' ? json['timezone'] as string : '';
      result.info.queryTime = Date.now();
      result.outcome = IpQueryOutcome.OK;
      PublicIpService.log(trigger, result, '');
      return result;
    } catch (e) {
      result.elapsedMs = Date.now() - t0;
      result.outcome = IpQueryOutcome.NETWORK;
      PublicIpService.log(trigger, result, `error=${AppLogger.errText(e)}`);
      return result;
    } finally {
      req.destroy();
    }
  }

  /** 备用端点：ipify（HTTPS，只返回 IP）。与桌面卡片同源，已在真机长期可用。 */
  private static async queryFallback(trigger: string): Promise<IpQueryResult> {
    const result = new IpQueryResult();
    result.endpoint = 'ipify';
    const t0 = Date.now();
    const req = http.createHttp();
    try {
      const resp = await req.request('https://api64.ipify.org?format=json', {
        method: http.RequestMethod.GET,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        usingCache: false,
        // 出口 IP 必须经由隧道查询，否则拿到的是本机物理出口（或直接失败）
        usingProxy: AppProxyRoute.activePort() > 0
      });
      result.elapsedMs = Date.now() - t0;
      if (resp.responseCode !== 200) {
        result.outcome = IpQueryOutcome.HTTP;
        PublicIpService.log(trigger, result, `http=${resp.responseCode}`);
        return result;
      }
      const body = PublicIpService.bodyText(resp.result);
      if (body.length === 0) {
        result.outcome = IpQueryOutcome.MALFORMED;
        PublicIpService.log(trigger, result, 'empty body');
        return result;
      }
      let json: Record<string, Object>;
      try {
        json = JSON.parse(body) as Record<string, Object>;
      } catch (parseError) {
        result.outcome = IpQueryOutcome.MALFORMED;
        PublicIpService.log(trigger, result, 'json parse failed');
        return result;
      }
      const ip = typeof json['ip'] === 'string' ? (json['ip'] as string).trim() : '';
      if (!PublicIpService.isPlausibleIp(ip)) {
        result.outcome = IpQueryOutcome.MALFORMED;
        PublicIpService.log(trigger, result, 'no plausible ip in payload');
        return result;
      }
      result.info.ip = ip;
      result.info.queryTime = Date.now();
      result.outcome = IpQueryOutcome.OK;
      PublicIpService.log(trigger, result, '');
      return result;
    } catch (e) {
      result.elapsedMs = Date.now() - t0;
      result.outcome = IpQueryOutcome.NETWORK;
      PublicIpService.log(trigger, result, `error=${AppLogger.errText(e)}`);
      return result;
    } finally {
      req.destroy();
    }
  }

  /** 响应体转字符串（string / ArrayBuffer 两种返回形态都处理，超限返回空）。 */
  private static bodyText(raw: Object | string | ArrayBuffer): string {
    if (typeof raw === 'string') {
      const encoded = util.TextEncoder.create('utf-8').encodeInto(raw);
      return encoded.length > MAX_RESPONSE_BYTES ? '' : raw;
    }
    if (raw instanceof ArrayBuffer) {
      return raw.byteLength > MAX_RESPONSE_BYTES
        ? '' : util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(raw));
    }
    return '';
  }

  /** IP 字面量粗校验（IPv4/IPv6 字符集；不做严格语义校验，交给服务端）。 */
  private static isPlausibleIp(value: string): boolean {
    if (value.length < 3 || value.length > 45) {
      return false;
    }
    return /^[0-9a-fA-F:.]+$/.test(value);
  }

  /**
   * 记一行可定案的日志。**刻意不打印 IP 本身**（AppLogger 的 LogRedactor 也会把它
   * 打成 <ip>，这里不依赖那层，直接不写），只记录端点/耗时/结果类别/失败原因。
   */
  private static log(trigger: string, result: IpQueryResult, detail: string): void {
    const tail = detail.length > 0 ? ` ${detail}` : '';
    const line = `ip query: trigger=${trigger} endpoint=${result.endpoint} `
      + `outcome=${result.outcome} elapsed=${result.elapsedMs}ms${tail}`;
    if (result.outcome === IpQueryOutcome.OK) {
      AppLogger.info(TAG, line);
    } else {
      AppLogger.warn(TAG, line);
    }
  }

  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => setTimeout(() => resolve(), ms));
  }
}
