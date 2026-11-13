/**
 * DNS 预检结论（**零 import** 的纯数据文件）。
 *
 * 为什么要单独一个文件：`LatencyEngine.ets` / `ClashApiService.ets` 需要
 * 「每节点一个 DNS 结论」的类型与构造逻辑，而 Node 行为闸门
 * （verify-latency-concurrency / -engine-runtime）会把 `commons/services/*.ets`
 * **扁平暂存**成一个沙箱再 import —— 任何 `../latency/*` 的**值**依赖都会
 * 因为「那一层目录不存在」而整个闸门崩掉（ERR_MODULE_NOT_FOUND）。
 *
 * ⇒ 把「结论 + 判定规则」放进**零 import** 的文件，闸门只需暂存这一个文件
 * （无 @kit、无 AppSettings、无其它依赖）⇒ 扁平沙箱照样能跑。
 *
 * 规则本体仍只有一份：`LatencyDnsVerdict.fromPins`（下面）。
 * 探针侧（`LatencyProbe.ets`）只是**再导出**它，不复制规则。
 */

/**
 * DNS 预检状态（由**我们自己的** DoH 预解析给出）。
 *
 * ⚠ 为什么必须有它：mihomo 的 503 body 是**通用句**
 * （"An error occurred in the delay test"），**看不到 DNS 原因** ⇒
 * 「域名解析失败」这件事只有我们自己知道（2026-10-20 真机：四个解析器全部 NXDOMAIN，
 * 当天日志是 `DoH pinned 0/135` / `test-core proxy hosts: 0/135`）。
 */
export class LatencyDnsStatus {
  /** 解析成功 */
  static readonly RESOLVED: string = 'resolved';
  /** 解析失败（NXDOMAIN / 无应答）→ 节点结论 `dns_unresolved` */
  static readonly UNRESOLVED: string = 'unresolved';
  /** 没解析过 / 解析不了但也没失败（不据此下结论） */
  static readonly UNKNOWN: string = 'unknown';
}

/**
 * **单个节点的 DNS 预检结论**（调用方给探针）。
 *
 * 契约：
 *  - `status = unresolved` ⇒ 直接判 `dns_unresolved`，**不再打扰 mihomo**；
 *  - `status = resolved` / `unknown` ⇒ 照常走内核探测。
 */
export class LatencyDnsVerdict {
  /** 节点名 */
  nodeName: string = '';
  /** 节点服务器域名（IP 直连的节点为空） */
  host: string = '';
  /** 状态（见 {@link LatencyDnsStatus}） */
  status: string = LatencyDnsStatus.UNKNOWN;
  /** 说明（DoH 预解析的原文，如「NXDOMAIN」「未返回地址」） */
  detail: string = '';

  /**
   * 从 DoH 预解析结果构造结论。
   *
   * @param nodeName 节点名
   * @param host 节点服务器域名（空 = IP 直连，不需要 DNS）
   * @param pins DoH 预解析结果（**小写域名** → IP）；命中即解析成功
   * @param attempted 本次**尝试过**解析的域名（小写）；没试过 = unknown
   *   （⚠ 没试过 ≠ 解析失败：不能把「没解析」当成「解析失败」）
   */
  static fromPins(nodeName: string, host: string, pins: Record<string, string>,
    attempted: string[], failed?: string[], resolved?: string[]): LatencyDnsVerdict {
    const out = new LatencyDnsVerdict();
    out.nodeName = nodeName;
    out.host = host;
    if (host === undefined || host === null || host.length === 0) {
      out.status = LatencyDnsStatus.UNKNOWN;
      out.detail = 'IP 直连或未提供域名';
      return out;
    }
    const key = host.toLowerCase();
    // 精确口径（编排器给了 failed/resolved 时）：
    //   failed 里有 ⇒ 查过且没查到 ⇒ **真·解析失败**；
    //   resolved 里有 ⇒ 查到了（即便因易变/劫持嫌疑没写进 hosts）⇒ 解析成功；
    //   都不在 ⇒ 口径不足 ⇒ unknown（**不许**据此下结论）。
    if (failed !== undefined && resolved !== undefined) {
      for (const d of failed) {
        if (d.toLowerCase() === key) {
          out.status = LatencyDnsStatus.UNRESOLVED;
          out.detail = 'DoH 预解析未返回地址（NXDOMAIN / 无应答）';
          return out;
        }
      }
      for (const d of resolved) {
        if (d.toLowerCase() === key) {
          out.status = LatencyDnsStatus.RESOLVED;
          out.detail = `已解析 ${pins[key] !== undefined ? pins[key] : '(未写进 hosts)'}`;
          return out;
        }
      }
      out.status = LatencyDnsStatus.UNKNOWN;
      out.detail = '本次预解析未覆盖该域名（口径不足，不下结论）';
      return out;
    }
    const ip = pins[key];
    if (ip !== undefined && ip.length > 0) {
      out.status = LatencyDnsStatus.RESOLVED;
      out.detail = `已解析 ${ip}`;
      return out;
    }
    let tried = false;
    for (const d of attempted) {
      if (d.toLowerCase() === key) {
        tried = true;
        break;
      }
    }
    if (tried) {
      out.status = LatencyDnsStatus.UNRESOLVED;
      out.detail = 'DoH 预解析未返回地址（NXDOMAIN / 无应答）';
      return out;
    }
    out.status = LatencyDnsStatus.UNKNOWN;
    out.detail = '本次未做预解析';
    return out;
  }
}
