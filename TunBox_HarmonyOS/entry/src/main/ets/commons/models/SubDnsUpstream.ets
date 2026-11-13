/**
 * 单个订阅自带的「代理服务器域名解析上游」（`dns.proxy-server-nameserver`）。
 *
 * 为什么按订阅承载而不是一个扁平列表（2026-10-21 根因收口）：
 * 内核的解析器选择是**全局单值** —— `proxy-server-nameserver` 非空就为所有代理
 * 服务器域名建专用解析器，而专用解析器只认 `proxy-server-nameserver-policy`、
 * 永不查 `nameserver-policy`（dns/resolver.go 的 makePolicy(config.ProxyServerPolicy)）。
 * 多订阅合并时若把这些上游并成一个全局列表，公共 DNS 会在 batchExchange
 * （dns/resolver.go:227，并发取首个成功应答）里抢跑私有 DoH，把别的订阅的入口域名
 * 解析到 WAF/CDN 诱饵 IP。
 *
 * 因此：**上游必须跟着它自己的订阅走**，生成配置时按该订阅节点域名的后缀写进
 * `proxy-server-nameserver-policy`，等价于「一份订阅一份配置」的口径
 * （Clash Verge Rev / Clash Meta for Android / FlClash 都是单订阅运行，
 * 本类是把那个不变量在多订阅合并下还原出来的载体）。
 */
export class SubDnsUpstream {
  /** 订阅 id（ProxyNode.subscriptionId 与之对应，用于把上游绑定到该订阅的节点域名）。 */
  subId: string = '';
  /** 该订阅 `dns.proxy-server-nameserver` 的条目（已去重，未规范化）。 */
  servers: string[] = [];

  static of(subId: string, servers: string[]): SubDnsUpstream {
    const u = new SubDnsUpstream();
    u.subId = subId;
    u.servers = servers;
    return u;
  }
}

/**
 * 归一化后的「后缀 → 上游」条目：生成器最终写成
 * `dns.proxy-server-nameserver-policy` 的一项。
 *
 * 后缀来自该订阅自己的节点 `server`（`+.jushuitan.com` / 精确域名），
 * 所以上游只会作用于产生它的那份订阅，不会跨订阅抢答。
 */
export class SubDnsUpstreamPolicy {
  suffix: string = '';
  servers: string[] = [];
}
