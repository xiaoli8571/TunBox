/**
 * FlClash 等价节点测速引擎（ArkTS 复刻）
 *
 * 职责：以固定 32 个 worker 的并发池，逐节点打内核 REST 测速接口
 *       `GET /proxies/{name}/delay?url=…&timeout=…`，产出与 FlClash 同口径的
 *       >0 / -1 / -2 结论，并把每个结论即时回调给调用方。
 *
 * 来源（逐条对齐，偏离即 bug）：
 *   FlClash  lib/providers/actions/proxies.dart  _runDelayTests / _runDelayTest / cancelDelayTests
 *            （TaskPool(maxConcurrentDelayTests) 逐节点 getDelay；getDelay 返回 null ⇒ 不写结论；
 *              job.cancelled 后既不启动新任务也不落结论）
 *   FlClash  lib/common/constant.dart            maxConcurrentDelayTests = 32
 *                                                delayTestGuardDuration = 30s
 *   TunBox 产品要求：单节点超时固定 5000ms（不提供用户设置）。
 *                                                renderThrottleDuration = 300ms（合批由 UI 侧做，本文件不掺和）
 *   FlClash  lib/core/interface.dart             asyncTestDelay(timeout: delayTestGuardDuration)
 *   FlClash  core/delay.go                       delayTestConcurrency = 50、缺省 5s（内核兜底）
 *                                                空 expected-status 范围、provider 超时特例在内核侧
 *   mihomo   hub/route/proxies.go getProxyDelay  200 {"delay":n} / 504 ctx 超时 / 503 失败 / 404 proxy 不存在
 *   mihomo   core/delay.go                       delayTimedOut = -1、delayFailed = -2
 *   mihomo   core/delay.go defaultTestURL        https://www.gstatic.com/generate_204
 *
 * 关键口径：
 *   1. 结果三态：>0 延迟、-1 超时（内核 ctx 超时，REST 表现为 504）、-2 失败（503 / 404 / 其它非 200）。
 *   2. **只有真正拿到 HTTP 响应才写结论**。拿不到响应（30s 守护到期、被取消、socket 异常）
 *      ＝ 不作结论，不回调；这批任务只体现在 summary.cancelled。
 *   3. 并发池固定 32 个 worker，FIFO 取任务；「排队等待」不计入 30s 守护
 *      —— 守护从请求**真正发出**那一刻才开始计时（FlClash 的 guard 包的是单次 IPC）。
 *   4. 取消：在途请求全部 abort、未开始的任务直接跳过，两者都不写结论。
 *   5. 明确不实现（FlClash 也没有，规格 §4.4）：离线 TCP/TLS 探活、DNS 预解析判定、
 *      core_not_ready 连击作废、批次硬截止、5 分钟新鲜度跳过、/group/{name}/delay 组测速。
 *
 * 平台差异（规格 §五，不算偏离）：FlClash 走 core IPC，TunBox 走内核 REST；
 * 内核 `delayTestConcurrency = 50 > 32`，客户端 32 并发天然落在核内槽位之内。
 *
 * 测试：scripts/verify-tunbox-delay.mjs（网络层通过 DelayHttpTransport 注入桩，
 *       默认实现 ArkDelayHttpTransport 用 @kit.NetworkKit）。
 */
import { http, socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { LatencyTestUrl } from '../latency/LatencyTestUrl';
import { AppSettings } from '../models/AppSettings';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'TunBoxDelay';

/**
 * 并发池：固定 32（FlClash `maxConcurrentDelayTests`，constant.dart:100）。
 * 无自适应、无上限抬升 —— FlClash TaskPool(32) 就是这么跑的。
 */
export const TUNBOX_DELAY_CONCURRENCY: number = 32;
/**
 * TunBox 产品固定 5000ms；与 FlClash 可配置档位有意不同。
 */
export const TUNBOX_DELAY_TIMEOUT_OPTIONS: number[] = [5000];
/** 单节点超时与 AppSettings 同源，旧设置不能改变生产策略。 */
export const TUNBOX_DELAY_DEFAULT_TIMEOUT_MS: number = AppSettings.DEFAULT_DELAY_TEST_TIMEOUT;
/**
 * 客户端守护 30s（FlClash `delayTestGuardDuration`，constant.dart:63）。
 * 从请求发出起算，覆盖「排槽 + 本次探测」和 IPC 余量。
 * 到期不作结论（与 FlClash `getDelay` 返回 null 同语义）。
 */
export const TUNBOX_DELAY_GUARD_MS: number = 30000;
/** 是否用 TCP 直连传输层（false = 回退 @ohos.net.http，见 ArkTcpDelayHttpTransport 注释） */
export const TUNBOX_DELAY_USE_TCP_TRANSPORT: boolean = true;

/** 默认测速 URL（mihomo defaultTestURL，调用方可按节点/组覆盖） */
// 测速地址的真源在 commons/latency/LatencyTestUrl（ND06：默认地址常量只允许一处）。
// 这里只是给 FlClash 复刻层一个本地命名，**不得**再写第二份字面量。
export const TUNBOX_DELAY_URL: string = LatencyTestUrl.DEFAULT_URL;

/** delayTimedOut：内核对 context 超时的取值 */
export const TUNBOX_DELAY_TIMED_OUT: number = -1;
/** delayFailed：内核拨号/请求失败的取值 */
export const TUNBOX_DELAY_FAILED: number = -2;

/** delayTestKey 的分隔符（FlClash common/compute.dart：'$testUrl\u0000$proxyName'） */
const DELAY_KEY_SEP: string = '\u0000';

/**
 * 去重键（FlClash delayTestKey）：同一个节点配不同测速 URL 是**两个**任务。
 */
export function delayTestKey(testUrl: string, proxyName: string): string {
  return `${testUrl}${DELAY_KEY_SEP}${proxyName}`;
}

/** 单个测速目标（FlClash _DelayTestTarget 的等价物） */
export class DelayTarget {
  /** 真正被内核拨测的出口名（组链路末端节点名，由调用方解析） */
  proxyName: string = '';
  /** 该节点/该组配置的测速 URL */
  testUrl: string = TUNBOX_DELAY_URL;
  /** 去重键 = delayTestKey(testUrl, proxyName) */
  key: string = '';
  /**
   * 废弃：FlClash 取的是空 expected-status 范围（core/delay.go:99），不再透传组
   * 的 expected-status。字段保留仅供既有调用点赋值，引擎永不使用。
   */
  expected: string = '';
  /**
   * 废弃：provider 成员同样直测 /proxies（FlClash 无 provider 专属路由）。
   * 字段保留仅供既有调用点赋值，引擎永不使用。
   */
  providerName: string = '';

  constructor(proxyName: string = '', testUrl: string = TUNBOX_DELAY_URL, key: string = '',
    expected: string = '', providerName: string = '') {
    this.proxyName = proxyName;
    this.testUrl = testUrl.length > 0 ? testUrl : TUNBOX_DELAY_URL;
    this.key = key.length > 0 ? key : delayTestKey(this.testUrl, proxyName);
    this.expected = expected;
    this.providerName = providerName;
  }
}

/** 一条测速结论（仅在三态之一成立时才产生） */
export class DelayResult {
  key: string = '';
  /** 被测出口名 */
  proxyName: string = '';
  /** 本次使用的测速 URL */
  testUrl: string = '';
  /** >0 延迟 ms；-1 超时；-2 失败 */
  value: number = TUNBOX_DELAY_FAILED;
  /** 内核返回的 HTTP 状态码（200 / 503 / 504 / 404 …） */
  httpCode: number = 0;
  /** 客户端侧观测到的往返耗时（从请求发出到响应抵达，ms） */
  elapsedMs: number = 0;
}

/** 一批测速的汇总（total = measured + timedOut + failed + cancelled） */
export class TunBoxDelaySummary {
  /** 本批目标总数 */
  total: number = 0;
  /** 真正发出过请求的任务数（含被取消/守护到期而没结论的） */
  started: number = 0;
  /** 拿到 >0 结论的任务数 */
  measured: number = 0;
  /** 拿到 -1 的任务数 */
  timedOut: number = 0;
  /** 拿到 -2 的任务数 */
  failed: number = 0;
  /**
   * 未产出结论的任务数：取消时在途被 abort、取消后未开始、30s 守护到期、传输层异常
   */
  cancelled: number = 0;
  /** 只有 cancel() 置位；缺失回复本身不表示整批被取消。 */
  wasCancelled: boolean = false;
  /**
   * 内核不可用判定。REST 通道无法把「内核没起来」与「单个节点失败」区分开
   * （404 是 proxy 不存在，503 是拨测失败，都不是内核不可用），
   * 规格 §4.4 又明确要求去掉 core_not_ready 连击作废 ⇒ 恒为 false，仅为契约占位。
   */
  coreUnavailable: boolean = false;

  // ── 性能画像（2026-10-26 提速轮加的现场指标，只写日志，不参与判定） ──
  /** 本批实际使用的并发路数 */
  concurrency: number = 0;
  /** 在途请求峰值（验证「客户端真并发」是否等于配置值） */
  peakInflight: number = 0;
  /** 从领到任务到请求真正发出的平均等待（ms）——大批次排队瓶颈看这个 */
  avgQueueWaitMs: number = 0;
  /** 客户端侧单请求耗时分位（ms） */
  p50ElapsedMs: number = 0;
  p90ElapsedMs: number = 0;
  /** 整批墙钟耗时（ms） */
  wallMs: number = 0;
}

/** 结果回调：每拿到一条真结论调用一次 */
export type DelayResultSink = (result: DelayResult) => void;
/** 批次结束回调：只调用一次（含取消后的收尾） */
export type DelayDoneSink = (summary: TunBoxDelaySummary) => void;

/** 一次 HTTP 往返的回复 */
export class DelayHttpReply {
  /** HTTP 状态码（0 表示没拿到响应） */
  responseCode: number = 0;
  /** 响应体原文 */
  body: string = '';

  constructor(responseCode: number = 0, body: string = '') {
    this.responseCode = responseCode;
    this.body = body;
  }
}

/**
 * 一次在途请求的句柄：promise 拿回复，abort() 立刻掐断。
 * 取消语义要求「在途全部 abort ⇒ 不写结论」，因此 abort 必须是一等公民。
 */
export class DelayRequestHandle {
  promise: Promise<DelayHttpReply>;
  abort: () => void;

  constructor(promise: Promise<DelayHttpReply>, abort: () => void) {
    this.promise = promise;
    this.abort = abort;
  }
}

/**
 * 可注入的传输层（生产实现 = ArkDelayHttpTransport；验证脚本注入桩）。
 * 约定：**只有真正拿到 HTTP 响应才 resolve**（非 2xx 也是 resolve，交给上层分类）；
 *       网络错误 / 被 abort ⇒ reject。
 */
export interface DelayHttpTransport {
  send(url: string, headers: Record<string, string>, timeoutMs: number): DelayRequestHandle;
}

/** 生产传输层：@kit.NetworkKit 单发 GET，不重试 */
export class ArkDelayHttpTransport implements DelayHttpTransport {
  send(url: string, headers: Record<string, string>, timeoutMs: number): DelayRequestHandle {
    const req = http.createHttp();
    let destroyed: boolean = false;
    const abort = (): void => {
      if (destroyed) {
        return;
      }
      destroyed = true;
      try {
        req.destroy();
      } catch (e) {
        // destroy 失败无需上报：请求已经被取消，结论本来就不写
      }
    };
    const promise: Promise<DelayHttpReply> = req.request(url, {
      method: http.RequestMethod.GET,
      header: headers,
      connectTimeout: timeoutMs,
      readTimeout: timeoutMs,
      usingCache: false
    }).then((resp: http.HttpResponse): DelayHttpReply => {
      // 状态码原样交给 classifyDelayReply；响应体只处理字符串形态（mihomo 返回 JSON 文本）
      const raw = resp.result;
      const body: string = typeof raw === 'string' ? raw as string : '';
      return new DelayHttpReply(resp.responseCode, body);
    }).finally((): void => {
      // settle（成功或失败）后必须释放原生 http 句柄：不 destroy 的话每个请求泄一个，
      // 600 节点一批就漏 600 个，反复测速直接耗尽网络栈资源。abort 自带 destroyed 防重入。
      abort();
    });
    return new DelayRequestHandle(promise, abort);
  }
}

/**
 * HTTP 报文行分隔符（CR + LF）。
 *
 * 用 `String.fromCharCode` 构造而不是写转义字面量：本仓库曾经因为
 * 「python heredoc / 工具层吃掉一层反斜杠」把 `\r\n` 写成真实换行，
 * 源码被切成多行、编译直接报 `Expected ',', got 'string literal'`。
 * 这样写既不会坏，也一眼看得出是 CRLF。
 */
const HTTP_CRLF: string = String.fromCharCode(13, 10);

/**
 * 本地核心 REST 的 URL 拆解（手写：ArkTS 没有 WHATWG URL）。
 * 只服务 `http://host:port/path?...` 这种形态，够用且零依赖。
 */
class LocalHttpTarget {
  host: string = '127.0.0.1';
  port: number = 9090;
  /** 含 query 的 path（已编码，直接进请求行） */
  path: string = '/';
  /** Host 头里的 authority（host:port） */
  authority: string = '127.0.0.1:9090';
}

function parseLocalHttpUrl(url: string): LocalHttpTarget {
  const out = new LocalHttpTarget();
  let rest: string = url;
  if (rest.startsWith('http://')) {
    rest = rest.substring('http://'.length);
  } else if (rest.startsWith('https://')) {
    rest = rest.substring('https://'.length);
  }
  const slash: number = rest.indexOf('/');
  let authority: string = rest;
  if (slash >= 0) {
    authority = rest.substring(0, slash);
    rest = rest.substring(slash);
  } else {
    rest = '/';
  }
  const colon: number = authority.lastIndexOf(':');
  if (colon > 0) {
    out.host = authority.substring(0, colon);
    out.port = parseInt(authority.substring(colon + 1), 10);
    if (!(out.port > 0)) {
      out.port = 9090;
    }
  } else {
    out.host = authority.length > 0 ? authority : '127.0.0.1';
  }
  out.authority = authority.length > 0 ? authority : '127.0.0.1:9090';
  out.path = rest.length > 0 ? rest : '/';
  return out;
}

/**
 * TCP 直连传输层（HTTP/1.1 over `@kit.NetworkKit` TCPSocket）。
 *
 * 【为什么需要它 —— 2026-10-26 真机取证】
 * `@ohos.net.http` 对**同一个 host** 的并发连接只有个位数容量：80 个并发 delay
 * 请求时 hilog 同时出现 285 次 `code=2300028 Operation timeout`，
 * 批次画像 `p50=10000ms p90=10001ms`（= 全部排在 http 栈里等守护）、
 * `measured=23 cancelled=46` —— 并发越高反而越测不出来。
 * 客户端并发要真正落到内核，必须自己开连接：每个 delay 请求一条 TCP 到本地内核。
 *
 * 语义与 ArkDelayHttpTransport 完全一致：拿到 HTTP 响应才 resolve（非 2xx 也 resolve），
 * 连接失败/超时/abort ⇒ reject。每请求独立连接，按 HTTP 帧收全再主动关闭。
 * 真机证实 close 可早于已排队的 message；不能靠 close 判定回复已收完。
 */
export class ArkTcpDelayHttpTransport implements DelayHttpTransport {
  send(url: string, headers: Record<string, string>, timeoutMs: number): DelayRequestHandle {
    const target: LocalHttpTarget = parseLocalHttpUrl(url);
    const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
    let settled: boolean = false;
    // 字符值逐一对应原始字节，Content-Length/chunk-size 不按 UTF-16 字符数计算。
    let text: string = '';
    let peerClosed: boolean = false;
    let timer: number = -1;
    let resolveFn: (value: DelayHttpReply) => void = (): void => {};
    let rejectFn: (reason: Object) => void = (): void => {};

    const cleanup = (): void => {
      if (timer >= 0) {
        clearTimeout(timer);
        timer = -1;
      }
      try {
        tcp.off('message');
        tcp.off('close');
        tcp.off('error');
      } catch (e) {
        // 已注销 / 未注册：忽略
      }
    };
    const closeQuietly = (): void => {
      try {
        tcp.close().catch((): void => {});
      } catch (e) {
        // 已关闭：忽略
      }
    };
    const fail = (err: Object): void => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      closeQuietly();
      rejectFn(err);
    };
    const succeed = (reply: DelayHttpReply): void => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      closeQuietly();
      resolveFn(reply);
    };

    const promise: Promise<DelayHttpReply> = new Promise<DelayHttpReply>(
      (resolve: (value: DelayHttpReply) => void, reject: (reason: Object) => void) => {
        resolveFn = resolve;
        rejectFn = reject;
      });

    tcp.on('message', (info: socket.SocketMessageInfo): void => {
      if (settled) { return; }
      try {
        const bytes = new Uint8Array(info.message);
        if (text.length + bytes.length > 65536) { throw new Error('delay HTTP reply too large'); }
        for (const byte of bytes) { text += String.fromCharCode(byte); }
        const reply = ArkTcpDelayHttpTransport.parseReply(text);
        if (reply.responseCode > 0) { succeed(reply); }
      } catch (e) {
        fail(e);
      }
    });
    tcp.on('close', (): void => {
      // close 不是收包队列的屏障。继续接收排队中的 message，完整帧才兑现。
      // 真正缺失/截断的回复仍由现有 guard 收尾，不凭 EOF 伪造节点结论。
      peerClosed = true;
    });
    tcp.on('error', (err: BusinessError): void => {
      fail(err);
    });

    timer = setTimeout((): void => {
      fail(new Error(`tcp transport incomplete: bytes=${text.length} peerClosed=${peerClosed}`));
    }, timeoutMs);

    const requestLines: string[] = [];
    requestLines.push(`GET ${target.path} HTTP/1.1`);
    requestLines.push(`Host: ${target.authority}`);
    requestLines.push('Accept: application/json');
    const auth: string | undefined = headers['Authorization'];
    if (auth !== undefined) {
      requestLines.push(`Authorization: ${auth}`);
    }
    // 不要求服务端主动 EOF；收齐本次帧后仍立即关 socket，不引入复用池或重试。
    requestLines.push('Connection: keep-alive');
    requestLines.push('');
    requestLines.push('');
    const payload: string = requestLines.join(HTTP_CRLF);

    tcp.connect({
      address: { address: target.host, port: target.port, family: 1 },
      timeout: timeoutMs
    }).then((): Promise<void> => {
      if (settled) {
        return Promise.resolve();
      }
      return tcp.send({ data: payload });
    }).catch((e: Object): void => {
      fail(e);
    });

    return new DelayRequestHandle(promise, (): void => {
      fail(new Error('aborted'));
    });
  }

  /** 原始字节字符串 → 完整 HTTP 回复；不完整返回 0，格式错误抛错。 */
  static parseReply(raw: string): DelayHttpReply {
    const headEnd: number = raw.indexOf(HTTP_CRLF + HTTP_CRLF);
    if (headEnd < 0) {
      return new DelayHttpReply(0, '');
    }
    const head: string = raw.substring(0, headEnd);
    let body: string = raw.substring(headEnd + 4);
    const firstLineEnd: number = head.indexOf(HTTP_CRLF);
    const statusLine: string = firstLineEnd >= 0 ? head.substring(0, firstLineEnd) : head;
    const status = /^HTTP\/1\.[01] (\d{3})(?: |$)/.exec(statusLine);
    if (status === null) { throw new Error('invalid delay HTTP status'); }
    const code = parseInt(status[1], 10);
    if (code === 204 || code === 304) { return new DelayHttpReply(code, ''); }
    const length = /(?:^|\r\n)content-length:[ \t]*(\d+)[ \t]*(?:\r\n|$)/i.exec(head);
    const transfer = /(?:^|\r\n)transfer-encoding:[ \t]*([^\r\n]+)/i.exec(head);
    if (transfer !== null) {
      if (length !== null || transfer[1].trim().toLowerCase() !== 'chunked') {
        throw new Error('unsupported delay HTTP framing');
      }
      let offset: number = 0;
      let decoded: string = '';
      while (true) {
        const lineEnd = body.indexOf(HTTP_CRLF, offset);
        if (lineEnd < 0) { return new DelayHttpReply(); }
        const sizeText = body.substring(offset, lineEnd).split(';')[0];
        if (!/^[0-9a-f]+$/i.test(sizeText)) { throw new Error('invalid delay HTTP chunk size'); }
        const size = parseInt(sizeText, 16);
        if (size > 65536) { throw new Error('delay HTTP chunk too large'); }
        offset = lineEnd + 2;
        if (size === 0) {
          // 空 trailer 或完整的 trailer 区；不能把缺最后 CRLF 的帧当作完成。
          if (body.substring(offset, offset + 2) !== HTTP_CRLF
            && body.indexOf(HTTP_CRLF + HTTP_CRLF, offset) < 0) { return new DelayHttpReply(); }
          body = decoded;
          break;
        }
        if (body.length < offset + size + 2) { return new DelayHttpReply(); }
        if (body.substring(offset + size, offset + size + 2) !== HTTP_CRLF) {
          throw new Error('invalid delay HTTP chunk boundary');
        }
        decoded += body.substring(offset, offset + size);
        offset += size + 2;
      }
    } else if (length !== null) {
      const size = parseInt(length[1], 10);
      if (size > 65536) { throw new Error('delay HTTP body too large'); }
      if (body.length < size) { return new DelayHttpReply(); }
      body = body.substring(0, size);
    } else {
      // 本地 /delay 是有边界的 JSON 响应；不凭乱序 close 猜测 close-delimited body。
      throw new Error('missing delay HTTP body framing');
    }
    const bytes = new Uint8Array(body.length);
    for (let i = 0; i < body.length; i++) { bytes[i] = body.charCodeAt(i); }
    return new DelayHttpReply(code, util.TextDecoder.create('utf-8').decodeWithStream(bytes));
  }
}

/** 单批运行的策略（默认值 = FlClash 常量；显式构造仅供验证脚本压缩时间） */
export class TunBoxDelayPolicy {
  /** 固定并发（默认 32；显式构造时按传入值封顶 —— 门禁压缩时间用） */
  concurrency: number = TUNBOX_DELAY_CONCURRENCY;
  /** 单节点超时：生产固定 5000；显式构造仅供验证脚本缩短等待。 */
  timeoutMs: number = 0;
  guardMs: number = TUNBOX_DELAY_GUARD_MS;
  /**
   * 废弃：FlClash 无自适应并发，恒为 min(32, total)。字段保留仅供旧调用点传参，
   * 一律忽略，widthFor 永远取固定 32 封顶。
   */
  adaptive: boolean = false;

  constructor(concurrency: number = TUNBOX_DELAY_CONCURRENCY,
    timeoutMs: number = 0,
    guardMs: number = TUNBOX_DELAY_GUARD_MS,
    adaptive: boolean = false) {
    this.concurrency = concurrency > 0 ? concurrency : TUNBOX_DELAY_CONCURRENCY;
    this.timeoutMs = timeoutMs;
    this.guardMs = guardMs > 0 ? guardMs : TUNBOX_DELAY_GUARD_MS;
    this.adaptive = adaptive;
  }

  /** 本批实际使用的并发路数：固定 min(32, total)，无自适应 */
  widthFor(total: number): number {
    return Math.max(1, Math.min(this.concurrency, total));
  }

  /** 生产调用均使用缺省策略；测试可显式压缩等待。 */
  effectiveTimeoutMs(): number {
    return this.timeoutMs > 0 ? this.timeoutMs : TUNBOX_DELAY_DEFAULT_TIMEOUT_MS;
  }
}

/** 单批运行的可变状态（只活在一次 start…onDone 之间，类字段不跨批共享） */
class DelayRunState {
  /** 用户取消标记：置位后不再启动新任务，也不落任何结论 */
  cancelled: boolean = false;
  /** FIFO 游标 */
  nextIndex: number = 0;
  started: number = 0;
  measured: number = 0;
  timedOut: number = 0;
  failed: number = 0;
  cancelledCount: number = 0;
  /** key → 在途句柄（cancel 时逐个 abort） */
  inflight: Map<string, DelayRequestHandle> = new Map<string, DelayRequestHandle>();
  /** key → 强制收尾（保证 abort 后立刻解开 worker，不依赖 promise 必然 reject） */
  pending: Map<string, () => void> = new Map<string, () => void>();
  // ── 性能画像（2026-10-26） ──
  /** 批次开始时刻（墙钟） */
  beganAt: number = Date.now();
  /** 在途峰值 */
  peakInflight: number = 0;
  /** 领任务 → 请求发出的累计等待（ms） */
  queueWaitSumMs: number = 0;
  queueWaitCount: number = 0;
  /** 单请求耗时样本（最多 512 条，够算 p50/p90，不随 600 节点线性涨内存） */
  elapsedSamples: number[] = [];
  elapsedDropped: number = 0;
}

/**
 * 一批测速的运行体。语义等价于 FlClash 的 `_runDelayTests`：
 * TaskPool(32) + 逐节点 getDelay + guard 30s + cancel 只清状态不写结论。
 */
export class TunBoxDelayRun {
  private baseUrl: string;
  private secret: string;
  private transport: DelayHttpTransport;
  private policy: TunBoxDelayPolicy;
  private running: boolean = false;
  private state: DelayRunState | undefined = undefined;

  /**
   * @param baseUrl 内核 REST 基址（如 http://127.0.0.1:9090）
   * @param secret  控制面密钥（空串 = 不带 Authorization 头）
   * @param transport 传输层，默认 @kit.NetworkKit 实现
   * @param policy  并发/超时/守护，默认 FlClash 常量
   */
  constructor(baseUrl: string, secret: string,
    transport: DelayHttpTransport = TUNBOX_DELAY_USE_TCP_TRANSPORT
      ? new ArkTcpDelayHttpTransport() : new ArkDelayHttpTransport(),
    policy: TunBoxDelayPolicy = new TunBoxDelayPolicy()) {
    this.baseUrl = baseUrl;
    this.secret = secret;
    this.transport = transport;
    this.policy = policy;
  }

  /**
   * 发起一批测速。同一实例同时只跑一批：已在跑则忽略并告警
   * （FlClash 一个 job 一个 cancel 标记，同样不允许叠批）。
   *
   * 去重由调用方完成（FlClash 在 _resolveDelayTestTargets 里按 delayTestKey 去重），
   * 本引擎按传入顺序 FIFO 派发，不再自作主张合并。
   */
  start(targets: DelayTarget[], onResult: DelayResultSink, onDone: DelayDoneSink): void {
    if (this.running) {
      AppLogger.warn(TAG, 'start ignored: a batch is already running');
      return;
    }
    const state = new DelayRunState();
    this.state = state;
    this.running = true;
    const queue: DelayTarget[] = targets.slice();
    this.drive(queue, onResult, onDone);
  }

  /** 取消：在途 abort、未开始跳过，绝不写结论；onDone 仍会以 cancelled 计数收尾 */
  cancel(): void {
    const state = this.state;
    if (state === undefined || state.cancelled) {
      return;
    }
    state.cancelled = true;
    let aborted: number = 0;
    // 先 abort 再强制收尾：abort 让内核/协议栈立刻停下，收尾让 worker 立刻退出
    state.inflight.forEach((handle: DelayRequestHandle, key: string) => {
      try {
        handle.abort();
        aborted += 1;
      } catch (e) {
        AppLogger.warn(TAG, `cancel abort failed for ${key}: ${AppLogger.errText(e)}`);
      }
    });
    const finishes: (() => void)[] = [];
    state.pending.forEach((finish: () => void) => {
      finishes.push(finish);
    });
    for (const finish of finishes) {
      finish();
    }
    AppLogger.info(TAG, `cancelled: abortedInflight=${aborted} queued=${this.queuedCount()}`);
  }

  /** 是否有一批在跑（含正在收尾的） */
  isRunning(): boolean {
    return this.running;
  }

  // ── 内部 ────────────────────────────────────────────────────────────────

  private queuedCount(): number {
    return this.state === undefined ? 0 : this.state.nextIndex;
  }

  private async drive(queue: DelayTarget[], onResult: DelayResultSink,
    onDone: DelayDoneSink): Promise<void> {
    const state = this.state;
    if (state === undefined) {
      return;
    }
    // 让 start() 先返回，回调永不在调用栈里重入（含 0 目标的分支）
    await Promise.resolve();
    try {
      const workers: Promise<void>[] = [];
      const width: number = this.policy.widthFor(queue.length);
      if (width > 1 || queue.length > 1) {
        AppLogger.info(TAG, `batch dispatchable: nodes=${queue.length} concurrency=${width}`);
      }
      for (let i = 0; i < width; i++) {
        workers.push(this.worker(queue, state, onResult));
      }
      await Promise.all(workers);
      // 取消后未取到的任务＝直接跳过，同样不作结论
      const undispatched: number = queue.length - state.started;
      if (undispatched > 0) {
        state.cancelledCount += undispatched;
      }
    } catch (e) {
      AppLogger.error(TAG, `batch failed: ${AppLogger.errText(e)}`);
      state.cancelledCount += queue.length - state.started;
    } finally {
      const summary = this.buildSummary(state, queue.length);
      this.state = undefined;
      this.running = false;
      try {
        onDone(summary);
      } catch (e) {
        AppLogger.error(TAG, `onDone threw: ${AppLogger.errText(e)}`);
      }
    }
  }

  /** 固定 worker：FIFO 领任务，直到队尾或取消 */
  private async worker(queue: DelayTarget[], state: DelayRunState,
    onResult: DelayResultSink): Promise<void> {
    while (true) {
      if (state.cancelled) {
        return;
      }
      const index: number = state.nextIndex;
      if (index >= queue.length) {
        return;
      }
      state.nextIndex = index + 1;
      await this.runOne(queue[index], state, onResult, Date.now());
    }
  }

  /**
   * 单任务：发请求 → 起 30s 守护 → 等响应。
   * 守护计时起点是「请求真正发出」（排队时间不计入）。
   *
   * @param queuedAt 领到任务墙钟时刻；与发出时刻之差就是排队等待（性能画像用）
   */
  private runOne(target: DelayTarget, state: DelayRunState,
    onResult: DelayResultSink, queuedAt: number = 0): Promise<void> {
    if (state.cancelled) {
      return Promise.resolve();
    }
    const url: string = this.delayUrl(target.proxyName, target.testUrl);
    let handle: DelayRequestHandle;
    try {
      // 传输层自带的超时与守护同值：谁先到都等价于「不作结论」
      handle = this.transport.send(url, this.authHeaders(), this.policy.guardMs);
    } catch (e) {
      // 同步抛错 = 连请求都没发出去，同样不写结论
      AppLogger.warn(TAG, `send failed for ${target.proxyName}: ${AppLogger.errText(e)}`);
      return Promise.resolve();
    }
    state.started += 1;
    const startedAt: number = Date.now();
    if (queuedAt > 0) {
      state.queueWaitSumMs += startedAt - queuedAt;
      state.queueWaitCount += 1;
    }
    state.inflight.set(target.key, handle);
    if (state.inflight.size > state.peakInflight) {
      state.peakInflight = state.inflight.size;
    }
    return new Promise<void>((resolve: () => void) => {
      let settled: boolean = false;
      let timer: number = -1;
      const finish = (result: DelayResult | null): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer >= 0) {
          clearTimeout(timer);
          timer = -1;
        }
        state.inflight.delete(target.key);
        state.pending.delete(target.key);
        // 性能画像：单请求墙钟（含排队后发出到收尾），最多留 512 个样本
        const elapsed: number = Date.now() - startedAt;
        if (state.elapsedSamples.length < 512) {
          state.elapsedSamples.push(elapsed);
        } else {
          state.elapsedDropped += 1;
        }
        if (result !== null && !state.cancelled) {
          if (result.value > 0) {
            state.measured += 1;
          } else if (result.value === TUNBOX_DELAY_TIMED_OUT) {
            state.timedOut += 1;
          } else {
            state.failed += 1;
          }
          try {
            onResult(result);
          } catch (e) {
            AppLogger.error(TAG, `onResult threw for ${target.proxyName}: ${AppLogger.errText(e)}`);
          }
        } else {
          // 取消 / 守护到期 / 传输异常：不作结论（FlClash 的 null 分支）
          state.cancelledCount += 1;
        }
        resolve();
      };
      state.pending.set(target.key, (): void => {
        finish(null);
      });
      timer = setTimeout((): void => {
        AppLogger.warn(TAG, `guard expired for ${target.proxyName} after ${this.policy.guardMs}ms`);
        try {
          handle.abort();
        } catch (e) {
          // 忽略：结论本来就不写
        }
        finish(null);
      }, this.policy.guardMs);
      handle.promise.then((reply: DelayHttpReply): void => {
        if (reply.responseCode <= 0) {
          AppLogger.warn(TAG, `no HTTP reply for ${target.proxyName}: elapsed=${Date.now() - startedAt}ms`);
        }
        finish(TunBoxDelayRun.classify(target, reply, Date.now() - startedAt));
      }).catch((e: Object): void => {
        AppLogger.warn(TAG, `request error for ${target.proxyName}: ${AppLogger.errText(e)}`);
        finish(null);
      });
    });
  }

  /**
   * 响应 → 结论（严格按 mihomo getProxyDelay 的分支）：
   *   200 + delay > 0  → 延迟
   *   504              → -1（ctx.Err() != nil，即内核侧 ctx 超时）
   *   其它非 200（503/404/400/…）→ -2
   *   200 但 delay 缺失/<=0 → -2（内核 delay == 0 本身就是错误分支）
   *   没拿到响应（code <= 0）→ null，不写结论
   */
  static classify(target: DelayTarget, reply: DelayHttpReply, elapsedMs: number): DelayResult | null {
    if (reply.responseCode <= 0) {
      return null;
    }
    const result = new DelayResult();
    result.key = target.key;
    result.proxyName = target.proxyName;
    result.testUrl = target.testUrl;
    result.httpCode = reply.responseCode;
    result.elapsedMs = elapsedMs;
    if (reply.responseCode === 200) {
      const delay: number = TunBoxDelayRun.parseDelay(reply.body);
      result.value = delay > 0 ? delay : TUNBOX_DELAY_FAILED;
    } else if (reply.responseCode === 504) {
      result.value = TUNBOX_DELAY_TIMED_OUT;
    } else {
      result.value = TUNBOX_DELAY_FAILED;
    }
    return result;
  }

  /** 从 `{"delay":123}` 里取 delay；异常/缺失一律 0 */
  static parseDelay(body: string): number {
    if (body.length === 0) {
      return 0;
    }
    try {
      const parsed = JSON.parse(body) as Record<string, Object>;
      const raw = parsed['delay'];
      if (typeof raw === 'number') {
        return raw as number;
      }
      return 0;
    } catch (e) {
      return 0;
    }
  }

  /**
   * 请求形态（FlClash core/delay.go:99）：直测 `/proxies/{name}/delay`，
   * 空 expected-status 范围（不传 expected 参数），provider 成员同此路由。
   * timeout 生产固定 5000；测试策略可显式缩短。
   */
  private delayUrl(proxyName: string, testUrl: string): string {
    let base: string = this.baseUrl;
    while (base.length > 0 && base.charAt(base.length - 1) === '/') {
      base = base.substring(0, base.length - 1);
    }
    const name: string = encodeURIComponent(proxyName);
    const url: string = encodeURIComponent(testUrl);
    return `${base}/proxies/${name}/delay?url=${url}&timeout=${this.policy.effectiveTimeoutMs()}`;
  }

  private authHeaders(): Record<string, string> {
    const headers: Record<string, string> = {};
    headers['Accept'] = 'application/json';
    if (this.secret.length > 0) {
      headers['Authorization'] = `Bearer ${this.secret}`;
    }
    return headers;
  }

  private buildSummary(state: DelayRunState, total: number): TunBoxDelaySummary {
    const summary = new TunBoxDelaySummary();
    summary.total = total;
    summary.started = state.started;
    summary.measured = state.measured;
    summary.timedOut = state.timedOut;
    summary.failed = state.failed;
    summary.cancelled = state.cancelledCount;
    summary.wasCancelled = state.cancelled;
    // ── 性能画像 ──
    summary.concurrency = this.policy.widthFor(total);
    summary.peakInflight = state.peakInflight;
    summary.avgQueueWaitMs = state.queueWaitCount > 0
      ? Math.round(state.queueWaitSumMs / state.queueWaitCount) : 0;
    summary.wallMs = Date.now() - state.beganAt;
    const sorted: number[] = state.elapsedSamples.slice();
    sorted.sort((a: number, b: number): number => a - b);
    summary.p50ElapsedMs = TunBoxDelayRun.percentile(sorted, 0.5);
    summary.p90ElapsedMs = TunBoxDelayRun.percentile(sorted, 0.9);
    AppLogger.info(TAG, `batch profile: concurrency=${summary.concurrency} peakInflight=${summary.peakInflight} `
      + `avgQueueWait=${summary.avgQueueWaitMs}ms p50=${summary.p50ElapsedMs}ms `
      + `p90=${summary.p90ElapsedMs}ms wall=${summary.wallMs}ms samples=${sorted.length}`);
    return summary;
  }

  /** 顺序数组的分位值（q∈[0,1]），空数组返回 0 */
  static percentile(sorted: number[], q: number): number {
    if (sorted.length === 0) {
      return 0;
    }
    const idx: number = Math.floor(q * (sorted.length - 1));
    if (idx <= 0) {
      return sorted[0];
    }
    if (idx >= sorted.length) {
      return sorted[sorted.length - 1];
    }
    return sorted[idx];
  }
}
