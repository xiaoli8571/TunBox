namespace TunBox.Core.Models;

/// <summary>测速状态。超时与「节点报错」要分得开，用户才能决定换节点还是换测速地址。</summary>
public enum DelayState { Untested, Testing, Ok, Timeout, Failed }

/// <summary>节点协议。</summary>
public enum ProxyKind
{
    Ss, Ssr, Vless, Vmess, Trojan, Hysteria2, Hysteria, Tuic, AnyTls, Socks5, Http, Direct, Unknown
}

/// <summary>
/// 单个代理节点。字段名贴近 mihomo 的 YAML 键。
/// RawTemplate 是订阅原文里该节点的 flow-map（剥掉 name 与全部凭据后逐字保留）：
/// 生成配置时原样回写、只注入 name 与凭据，根治「解析→重生成丢字段」——
/// xhttp-opts / headers / dialer-proxy / smux 这类字段 app 不去「理解」它，就不会理解错。
/// 不含明文凭据，可安全持久化。
/// </summary>
public sealed class ProxyNode
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    /// <summary>去重前的原始名字；代理组按它引用成员，改名后仍能解析。</summary>
    public string OriginalName { get; set; } = "";
    public ProxyKind Kind { get; init; } = ProxyKind.Unknown;
    public string Server { get; set; } = "";
    public int Port { get; set; }
    public string Uuid { get; set; } = "";
    public string Password { get; set; } = "";
    public string Method { get; set; } = "";
    public string Protocol { get; set; } = "";
    public string ProtocolParam { get; set; } = "";
    public string Obfs { get; set; } = "";
    public string ObfsParam { get; set; } = "";
    public string Network { get; set; } = "";
    public string Servername { get; set; } = "";
    public string Flow { get; set; } = "";
    public string ClientFingerprint { get; set; } = "";
    public string CertFingerprint { get; set; } = "";
    public string RealityPublicKey { get; set; } = "";
    public string RealityShortId { get; set; } = "";
    public string WsPath { get; set; } = "";
    public string WsHost { get; set; } = "";
    public string GrpcServiceName { get; set; } = "";
    public string AlpnList { get; set; } = "";
    public string HyUp { get; set; } = "";
    public string HyDown { get; set; } = "";
    public int AlterId { get; set; }
    public bool Tls { get; set; }
    public bool Udp { get; set; } = true;
    public bool SkipCertVerify { get; set; }
    public string SubscriptionId { get; set; } = "";
    public Dictionary<string, string> Extras { get; } = new(StringComparer.Ordinal);
    public string RawTemplate { get; set; } = "";

    /// <summary>最近一次测速延迟（毫秒）；-1 失败，0 未测。</summary>
    public int LastLatency { get; set; }
    public DelayState State { get; set; } = DelayState.Untested;
    public string? DelayError { get; set; }
}

/// <summary>订阅里声明的代理组（select / url-test / fallback / load-balance / relay）。</summary>
public sealed class ProxyGroup
{
    public string Name { get; set; } = "";
    public string GroupType { get; set; } = "select";
    public List<string> Members { get; } = new();
    public string Url { get; set; } = "";
    public int IntervalSec { get; set; }
    public int ToleranceMs { get; set; }
    public string ExpectedStatus { get; set; } = "";
    public string SubscriptionId { get; set; } = "";
}

/// <summary>一条订阅及其解析出的流量/到期信息（subscription-userinfo 响应头）。</summary>
public sealed class Subscription
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Url { get; set; } = "";
    public long UpdatedAtMs { get; set; }
    public long UploadBytes { get; set; } = -1;
    public long DownloadBytes { get; set; } = -1;
    public long TotalBytes { get; set; } = -1;
    public long ExpireAtMs { get; set; } = -1;
    /// <summary>面板按 UA 返回不同内容时，用户可以在这里指定 UA（对齐 Clash Verge 的自定义 UA）。</summary>
    public string CustomUserAgent { get; set; } = "";
    /// <summary>自动更新的间隔分钟；0 = 只手动更新。</summary>
    public int UpdateIntervalMinutes { get; set; }
    /// <summary>上次成功拉取的 ETag，带 If-None-Match 让面板能回 304。</summary>
    public string Etag { get; set; } = "";
}

public enum AppRoutingMode
{
    /// <summary>不区分应用。</summary>
    All,
    /// <summary>仅名单内应用走代理，其余直连。</summary>
    OnlySelected,
    /// <summary>名单内应用直连，其余走规则。</summary>
    BypassSelected
}

/// <summary>点标题栏 X 时做什么。Ask = 每次都问，Tray/Exit = 记住的选择。</summary>
public enum CloseBehavior { Ask, Tray, Exit }

/// <summary>代理模式。内核认 rule / global / direct 三种。</summary>
public sealed class AppSettings
{
    public string ProxyMode { get; set; } = "rule";
    /// <summary>混合端口：同一端口同时讲 HTTP 与 SOCKS。0 = 不监听。</summary>
    public int MixedPort { get; set; } = 7890;
    /// <summary>独立 HTTP 端口，0 = 关。</summary>
    public int HttpPort { get; set; }
    /// <summary>独立 SOCKS 端口，0 = 关。</summary>
    public int SocksPort { get; set; }
    public int ApiPort { get; set; } = 9090;
    public string ApiSecret { get; set; } = "";
    /// <summary>允许局域网其他设备连本机代理（绑定地址从 127.0.0.1 变 0.0.0.0）。</summary>
    public bool AllowLan { get; set; }
    /// <summary>把流量交给内核后是否顺手改系统代理（WinINet）。</summary>
    public bool SystemProxyEnabled { get; set; } = true;
    /// <summary>虚拟网卡：接管全设备流量，不依赖应用自己认代理。</summary>
    public bool TunEnabled { get; set; }
    public bool RulesEnabled { get; set; } = true;
    public bool AdRulesEnabled { get; set; }
    public bool SniffingEnabled { get; set; } = true;
    public bool UseSmartGroup { get; set; } = true;
    /// <summary>内核的 ipv6 开关 + DNS 的 AAAA 解析。默认关：多数机场入口没有 v6，开了反而慢。</summary>
    public bool Ipv6Enabled { get; set; }
    /// <summary>DNS 复写：用户接管解析用的 nameserver（对齐 Verge / FlClash 的「DNS 覆写」）。</summary>
    public bool DnsOverrideEnabled { get; set; }
    /// <summary>复写用的 DNS 服务器；只换 nameserver，引导 DNS 与 fake-ip 规则不动。</summary>
    public List<string> DnsServers { get; } = new();
    public string CoreLogLevel { get; set; } = "info";
    /// <summary>国内可达性好的测速地址：gstatic 不通时整屏节点会一起报红。</summary>
    public string TestUrl { get; set; } = "http://cp.cloudflare.com/generate_204";
    public List<string> CustomRules { get; } = new();
    public List<string> ForceProxySites { get; } = new();
    public List<string> ForceDirectSites { get; } = new();
    public AppRoutingMode AppRouting { get; set; } = AppRoutingMode.All;
    /// <summary>进程名（如 ChatGPT.exe）。Windows 上内核能查到连接归属进程，应用分流走 PROCESS-NAME 规则。</summary>
    public List<string> AppProcesses { get; } = new();
    public string SelectedNodeId { get; set; } = "";
    public bool StartWithWindows { get; set; }
    public bool StartMinimized { get; set; }
    public CloseBehavior Close { get; set; } = CloseBehavior.Ask;

    /// <summary>系统代理指向哪个端口：混合优先，其次独立 HTTP。返回 0 表示不该开系统代理。</summary>
    public int SystemProxyPort() => MixedPort > 0 ? MixedPort : HttpPort;
}
