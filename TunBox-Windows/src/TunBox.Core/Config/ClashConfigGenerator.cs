using System.Text;
using System.Text.RegularExpressions;
using TunBox.Core.Models;

namespace TunBox.Core.Config;

public enum ProxyDropReason { None, UnsupportedProtocol, UnsafeText, MissingField, MissingCredential, InvalidPort }

/// <summary>「列表有、内核无」的显式账本：绝不静默丢节点。</summary>
public sealed class ProxyDropStats
{
    public int Total { get; set; }
    public int Kept { get; set; }
    public int UnsupportedProtocol { get; set; }
    public int UnsafeText { get; set; }
    public int MissingFields { get; set; }
    public int MissingCredential { get; set; }
    public int InvalidPort { get; set; }
    public List<string> Samples { get; } = new();
    public int Dropped => UnsupportedProtocol + UnsafeText + MissingFields + InvalidPort;
    public bool HasDrop => Dropped > 0;

    public string Summary() =>
        $"列表 {Total} 个节点，可写入内核 {Kept} 个，丢弃 {Dropped} 个" +
        (Samples.Count > 0 ? $"（示例：{string.Join('、', Samples)}）" : "");
}

/// <summary>
/// mihomo 配置生成器。
/// 刻意保留的既有结论：重名代理会让内核**拒绝整份配置**（必须发射前唯一化）；
/// GEOIP / RULE-SET 缺文件时绝不能发射（内核会在 config.Parse 阶段同步联网下载，
/// 国内不可达就是「点了连接一直转圈」）；所有出口做一次控制字符净化。
/// </summary>
public static class ClashConfigGenerator
{
    public const string SmartGroupName = "♻️ 自动选择";
    public const string TunDeviceName = "TunBox";

    /// <summary>smart 组排除机场塞进 proxies 的信息条伪节点。</summary>
    public const string SmartInfoNodeFilter =
        "(剩余流量|剩余|套餐到期|到期时间|到期|流量重置|距离下次|重置|官网|客服|订阅地址|更新订阅|Expire|Traffic|Reset|Website)";

    private static readonly HashSet<string> SupportedProtocols = new(StringComparer.Ordinal)
    {
        "ss", "ssr", "vless", "vmess", "trojan", "hysteria2", "hysteria", "tuic", "anytls",
        "socks5", "http", "direct", "shadowsocks", "shadowsocks-r",
    };

    /// <summary>fake-ip 豁免：联网探针、NTP、局域网、STUN 与国内直连域名。</summary>
    public static readonly string[] FakeIpFilter =
    {
        "localhost", "*.localhost", "*.local", "*.lan", "*.localdomain", "*.home.arpa",
        "*.msftconnecttest.com", "*.msftncsi.com", "time.windows.com",
        "time.*.com", "ntp.*.com", "+.pool.ntp.org", "*.nist.gov",
        "stun.*.*", "stun.*.*.*", "turn.*.*", "turn.*.*.*",
        "+.cn", "*.cn",
    };

    public sealed record FeatureGate(bool GeoipReady, bool AdRulesReady, bool SmartModelReady = false);

    public static string Generate(
        IReadOnlyList<ProxyNode> nodes,
        IReadOnlyList<ProxyGroup> groups,
        AppSettings settings,
        FeatureGate gate,
        IReadOnlyDictionary<string, string>? proxyHosts = null,
        bool? tunOverride = null)
    {
        var lines = new List<string>();
        var tunOn = tunOverride ?? settings.TunEnabled;

        lines.Add($"mixed-port: {settings.MixedPort}");
        // 内核的 portIsZero：0 就是「不建这个监听」，关掉的端口也要写出来避免热重载残留。
        lines.Add($"port: {settings.HttpPort}");
        lines.Add($"socks-port: {settings.SocksPort}");
        lines.Add($"allow-lan: {(settings.AllowLan ? "true" : "false")}");
        lines.Add($"external-controller: 127.0.0.1:{settings.ApiPort}");
        lines.Add($"secret: \"{Escape(settings.ApiSecret)}\"");
        lines.Add($"mode: {(settings.ProxyMode == "global" ? "global" : settings.ProxyMode == "direct" ? "direct" : "rule")}");
        // 实测：本份内核 log-level 取 warning/error/silent 时停在 Initial configuration complete
        // 之后不再监听任何端口且无报错。只放 debug/info 两个安全值。
        var level = (settings.CoreLogLevel ?? "").Trim().ToLowerInvariant();
        lines.Add("log-level: " + (level is "debug" or "info" ? level : "info"));
        var v6 = settings.Ipv6Enabled;
        lines.Add($"ipv6: {(v6 ? "true" : "false")}");
        lines.Add("unified-delay: true");
        lines.Add("tcp-concurrent: true");
        lines.Add("keep-alive-idle: 30");
        lines.Add("keep-alive-interval: 15");
        // Windows 上内核经 GetExtendedTcpTable 查归属进程，应用分流规则依赖它。
        lines.Add("find-process-mode: strict");
        lines.Add("");

        // DNS 复写：用户接管 nameserver 时，只换这一组。default-nameserver 是引导用的
        // （它负责解析 DoH / DoT 服务器自己的域名），换成用户的地址会自举失败。
        var userDns = settings.DnsOverrideEnabled ? NormalizeDnsServers(settings.DnsServers) : new List<string>();
        lines.Add("dns:");
        lines.Add("  enable: true");
        lines.Add($"  ipv6: {(v6 ? "true" : "false")}");
        lines.Add(tunOn ? "  enhanced-mode: fake-ip" : "  enhanced-mode: redir-host");
        if (tunOn)
        {
            lines.Add("  fake-ip-range: 198.18.0.1/16");
            lines.Add("  fake-ip-filter-mode: blacklist");
            lines.Add("  fake-ip-filter:");
            foreach (var f in FakeIpFilter) lines.Add($"    - \"{f}\"");
        }
        lines.Add("  cache-algorithm: arc");
        lines.Add("  default-nameserver:");
        lines.Add("    - 223.5.5.5");
        lines.Add("    - 119.29.29.29");
        lines.Add("  nameserver:");
        if (userDns.Count > 0)
            foreach (var d in userDns) lines.Add($"    - \"{Escape(d)}\"");
        else
        {
            lines.Add("    - tls://223.5.5.5:853");
            lines.Add("    - tls://1.12.12.12:853");
        }
        lines.Add("  proxy-server-nameserver:");
        lines.Add("    - 223.5.5.5");
        lines.Add("    - 119.29.29.29");
        // 接管了就别再塞我们的境外兜底：用户的地址表就是他的完整意图。
        if (userDns.Count == 0 && gate.GeoipReady) lines.Add("  fallback:");
        if (userDns.Count == 0 && gate.GeoipReady) lines.Add("    - tls://1.1.1.1:853");
        lines.Add("  strategy: prefer_ipv4");
        lines.Add("");

        if (settings.SniffingEnabled)
        {
            lines.Add("sniffer:");
            lines.Add("  enable: true");
            lines.Add("  parse-pure-ip: true");
            lines.Add("  sniff:");
            lines.Add("    HTTP: {}");
            lines.Add("    TLS: {}");
            lines.Add("    QUIC: {}");
            lines.Add("");
        }

        lines.Add("profile:");
        lines.Add("  store-selections: true");
        lines.Add("");

        // 分流库保鲜交给内核：RegisterGeoUpdater 是 goroutine + ticker，不进启动关键路径。
        // geox-url 用国内可达的镜像 —— GitHub direct 多数网络下不动。
        lines.Add("geo-auto-update: true");
        lines.Add("geo-update-interval: 24");
        lines.Add("geox-url:");
        lines.Add("  mmdb: \"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb\"");
        lines.Add("  geoip: \"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat\"");
        lines.Add("  geosite: \"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat\"");
        lines.Add("  asn: \"https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/GeoLite2-ASN.mmdb\"");
        lines.Add("");

        lines.Add("tun:");
        lines.Add($"  enable: {(tunOn ? "true" : "false")}");
        if (tunOn)
        {
            lines.Add($"  device: {TunDeviceName}");
            lines.Add("  stack: system");
            lines.Add("  auto-route: true");
            lines.Add("  auto-detect-interface: true");
            lines.Add("  dns-hijack:");
            lines.Add("    - any:53");
            // 9000 是默认值，走 Wi-Fi / 二级隧道时容易踩分片，1500 最稳。
            lines.Add("  mtu: 1500");
        }
        lines.Add("");

        var hosts = NormalizeHosts(proxyHosts);
        if (hosts.Count > 0)
        {
            lines.Add("hosts:");
            foreach (var kv in hosts.OrderBy(k => k.Key, StringComparer.Ordinal))
                lines.Add($"  \"{Escape(kv.Key)}\": \"{Escape(kv.Value)}\"");
            lines.Add("");
        }

        // ── 节点写入判定：一遍算好原因，保证「计数 == 实际写入」──
        var reasons = nodes.ToDictionary(n => n, DropReasonFor);
        var stats = CountDropped(nodes, reasons);
        if (stats.HasDrop) LastDropStats = stats;
        var valid = nodes.Where(n => reasons[n] == ProxyDropReason.None).ToList();
        if (valid.Count == 0)
            throw new InvalidOperationException(
                $"没有可用的节点配置：{stats.Summary()}。请重新导入或更新订阅。");

        EnsureUniqueNames(valid);

        lines.Add("proxies:");
        foreach (var n in valid) lines.Add(NodeYaml(n));

        var groupPlan = PlanGroups(groups, valid);
        var emitSmart = settings.UseSmartGroup && gate.SmartModelReady && valid.Count >= 2
            && !UsedName(valid, groupPlan, SmartGroupName);

        lines.Add("");
        lines.Add("proxy-groups:");
        lines.Add("  - name: \"PROXY\"");
        lines.Add("    type: select");
        var selected = valid.FirstOrDefault(n => n.Id == settings.SelectedNodeId) ?? valid[0];
        var smartFirst = emitSmart && settings.ProxyMode != "global";
        // 必须写出 now：内核没有 now 就默认取成员表的第一个，而我们排在第一位的是 ♻️ 自动选择 ——
        // 于是「用户点了 A 节点，重启/热重载之后每条连接又交回模型挑」，查到的 IP 跟所选对不上
        //（内核实测：配置里的 now 会被采纳，重载后停在选择的那个节点）。
        var wantAuto = settings.SelectedNodeId.Length == 0 || settings.SelectedNodeId == AppSettings.AutoNodeId;
        var egress = wantAuto && smartFirst ? SmartGroupName : selected.Name;
        lines.Add($"    now: \"{Escape(egress)}\"");
        lines.Add("    proxies:");
        if (smartFirst)
        {
            lines.Add($"      - \"{Escape(SmartGroupName)}\"");
            lines.Add($"      - \"{Escape(selected.Name)}\"");
        }
        else
        {
            lines.Add($"      - \"{Escape(selected.Name)}\"");
            if (emitSmart) lines.Add($"      - \"{Escape(SmartGroupName)}\"");
        }
        foreach (var g in groupPlan) lines.Add($"      - \"{Escape(g.Name)}\"");
        foreach (var n in valid.Where(n => n.Id != selected.Id))
            lines.Add($"      - \"{Escape(n.Name)}\"");

        foreach (var g in groupPlan)
        {
            lines.Add($"  - name: \"{Escape(g.Name)}\"");
            lines.Add($"    type: {g.GroupType}");
            if (g.GroupType is "url-test" or "fallback" or "load-balance")
            {
                lines.Add($"    url: \"{Escape(SafeUrl(g.Url))}\"");
                lines.Add($"    interval: {Math.Clamp(g.IntervalSec <= 0 ? 300 : g.IntervalSec, 30, 86400)}");
                if (g.GroupType is "url-test" or "load-balance" && g.ToleranceMs > 0)
                    lines.Add($"    tolerance: {Math.Min(g.ToleranceMs, 60000)}");
                if (!string.IsNullOrWhiteSpace(g.ExpectedStatus)
                    && Regex.IsMatch(g.ExpectedStatus.Trim(), @"^[0-9]{3}(,[0-9]{3})*$"))
                    lines.Add($"    expected-status: \"{Escape(g.ExpectedStatus.Trim())}\"");
                if (g.GroupType == "load-balance") lines.Add("    strategy: consistent-hashing");
            }
            lines.Add("    proxies:");
            foreach (var m in g.Members) lines.Add($"      - \"{Escape(m)}\"");
        }

        if (emitSmart)
        {
            lines.Add($"  - name: \"{Escape(SmartGroupName)}\"");
            lines.Add("    type: smart");
            lines.Add("    uselightgbm: true");
            lines.Add("    collectdata: false");
            // prefer-asn 会同步拉 ASN.mmdb，实测阻塞 ~90s，常关。
            lines.Add("    prefer-asn: false");
            if (!string.IsNullOrWhiteSpace(settings.TestUrl))
                lines.Add($"    url: \"{Escape(SafeUrl(settings.TestUrl))}\"");
            lines.Add($"    exclude-filter: \"{SmartInfoNodeFilter}\"");
            lines.Add("    proxies:");
            foreach (var n in valid) lines.Add($"      - \"{Escape(n.Name)}\"");
        }

        if (settings.RulesEnabled && settings.AdRulesEnabled && gate.AdRulesReady)
        {
            lines.Add("");
            lines.Add("rule-providers:");
            lines.Add("  hyper-adrules:");
            lines.Add("    type: http");
            lines.Add("    behavior: domain");
            lines.Add("    format: mrs");
            lines.Add("    interval: 86400");
            lines.Add("    path: ./ruleset/hyper_adrules_ads.mrs");
            lines.Add("    url: \"https://github.com/Lynricsy/HyperADRules/releases/latest/download/hyper_adrules_ads.mrs\"");
        }

        lines.Add("");
        lines.Add("rules:");
        AppendAppRules(lines, settings);
        if (settings.RulesEnabled && settings.AdRulesEnabled && gate.AdRulesReady)
            lines.Add("  - RULE-SET,hyper-adrules,REJECT");
        if (settings.RulesEnabled)
            foreach (var r in NormalizeCustomRules(settings.CustomRules)) lines.Add($"  - {r}");
        var directSites = NormalizeDomains(settings.ForceDirectSites);
        var proxySites = NormalizeDomains(settings.ForceProxySites);
        foreach (var s in directSites) lines.Add($"  - DOMAIN-SUFFIX,{s},DIRECT");
        foreach (var s in proxySites)
            if (!directSites.Contains(s)) lines.Add($"  - DOMAIN-SUFFIX,{s},PROXY");

        if (settings.AppRouting == AppRoutingMode.OnlySelected)
        {
            // 「仅所选应用走代理」= 其余一律直连，兜底必须是 DIRECT。
            lines.Add("  - GEOIP,LAN,DIRECT,no-resolve");
            if (gate.GeoipReady) lines.Add("  - GEOIP,CN,DIRECT");
            lines.Add("  - DOMAIN-SUFFIX,cn,DIRECT");
            lines.Add("  - MATCH,DIRECT");
            return Sanitize(string.Join('\n', lines) + "\n");
        }

        if (gate.GeoipReady) lines.Add("  - GEOIP,CN,DIRECT");
        lines.Add("  - DOMAIN-SUFFIX,cn,DIRECT");
        lines.Add("  - MATCH,PROXY");

        return Sanitize(string.Join('\n', lines) + "\n");
    }

    private static void AppendAppRules(List<string> lines, AppSettings settings)
    {
        if (settings.AppRouting == AppRoutingMode.All || settings.AppProcesses.Count == 0) return;
        var target = settings.AppRouting == AppRoutingMode.BypassSelected ? "DIRECT" : "PROXY";
        foreach (var p in settings.AppProcesses.Select(x => x.Trim()).Where(IsValidProcessName).Distinct())
            lines.Add($"  - PROCESS-NAME,{p},{target}");
    }

    private static bool IsValidProcessName(string name) =>
        name.Length is > 0 and <= 128 && !name.Contains(',') && !name.Contains('\n') && !name.Contains('\r')
        && !name.Contains('#') && !name.Contains('"') && !name.Contains('\'');

    public static ProxyDropStats LastDropStats { get; private set; } = new();

    public static string KindSlug(ProxyKind kind) => kind switch
    {
        ProxyKind.Ss => "ss",
        ProxyKind.Ssr => "ssr",
        ProxyKind.Vless => "vless",
        ProxyKind.Vmess => "vmess",
        ProxyKind.Trojan => "trojan",
        ProxyKind.Hysteria2 => "hysteria2",
        ProxyKind.Hysteria => "hysteria",
        ProxyKind.Tuic => "tuic",
        ProxyKind.AnyTls => "anytls",
        ProxyKind.Socks5 => "socks5",
        ProxyKind.Http => "http",
        ProxyKind.Direct => "direct",
        _ => "unknown",
    };

    public static ProxyDropReason DropReasonFor(ProxyNode n)
    {
        var kind = KindSlug(n.Kind);
        if (kind == "direct") return n.Name.Length == 0 ? ProxyDropReason.MissingField : ProxyDropReason.None;
        if (!SupportedProtocols.Contains(kind)) return ProxyDropReason.UnsupportedProtocol;
        foreach (var value in UnsafeCheckValues(n))
            if (!IsSafeText(value)) return ProxyDropReason.UnsafeText;
        if (n.Name.Length == 0 || n.Server.Length == 0) return ProxyDropReason.MissingField;
        if (n.Port is <= 0 or > 65535) return ProxyDropReason.InvalidPort;
        if (kind is "ss" or "ssr" or "shadowsocks" or "shadowsocks-r")
        {
            if (n.Method.Length == 0) return ProxyDropReason.MissingField;
            if (n.Password.Length == 0) return ProxyDropReason.MissingCredential;
        }
        if (kind == "ssr" && (n.Protocol.Length == 0 || n.Obfs.Length == 0)) return ProxyDropReason.MissingField;
        if ((kind == "vless" || kind == "vmess") && n.Uuid.Length == 0) return ProxyDropReason.MissingCredential;
        if (n.RealityPublicKey.Length > 0 && !Regex.IsMatch(n.RealityPublicKey, @"^[A-Za-z0-9_\-]{43}$"))
            return ProxyDropReason.MissingField;
        if (n.RealityShortId.Length > 0 && !Regex.IsMatch(n.RealityShortId, @"^([0-9a-fA-F]{2}){1,8}$"))
            return ProxyDropReason.MissingField;
        if (kind is "trojan" or "hysteria2" && n.Password.Length == 0) return ProxyDropReason.MissingCredential;
        // 内核对缺必填字段的代理是「整份配置解析失败」而非跳过，必须生成前拦下。
        if (kind == "tuic" && (n.Password.Length == 0 || n.Uuid.Length == 0)) return ProxyDropReason.MissingCredential;
        if (kind == "hysteria" && (n.Password.Length == 0 || n.Protocol.Length == 0
                || n.HyUp.Length == 0 || n.HyDown.Length == 0)) return ProxyDropReason.MissingCredential;
        if (kind == "anytls" && n.Password.Length == 0) return ProxyDropReason.MissingCredential;
        if (n.AlterId < 0) return ProxyDropReason.MissingField;
        return ProxyDropReason.None;
    }

    private static IEnumerable<string> UnsafeCheckValues(ProxyNode n) => new[]
    {
        n.Name, n.Server, n.Password, n.Method, n.Protocol, n.ProtocolParam, n.Obfs, n.ObfsParam,
        n.Uuid, n.Network, n.Servername, n.Flow, n.ClientFingerprint, n.CertFingerprint,
        n.RealityPublicKey, n.RealityShortId, n.WsPath, n.WsHost, n.GrpcServiceName, n.HyUp, n.HyDown, n.AlpnList,
    };

    public static ProxyDropStats CountDropped(IReadOnlyList<ProxyNode> nodes, IDictionary<ProxyNode, ProxyDropReason> precomputed)
    {
        var s = new ProxyDropStats { Total = nodes.Count };
        foreach (var n in nodes)
        {
            var reason = precomputed.TryGetValue(n, out var r) ? r : DropReasonFor(n);
            if (reason == ProxyDropReason.None) { s.Kept++; continue; }
            switch (reason)
            {
                case ProxyDropReason.UnsupportedProtocol: s.UnsupportedProtocol++; break;
                case ProxyDropReason.UnsafeText: s.UnsafeText++; break;
                case ProxyDropReason.InvalidPort: s.InvalidPort++; break;
                default:
                    s.MissingFields++;
                    if (reason == ProxyDropReason.MissingCredential) s.MissingCredential++;
                    break;
            }
            if (s.Samples.Count < 3) s.Samples.Add(n.Name.Length == 0 ? "(未命名)" : n.Name);
        }
        return s;
    }

    /// <summary>重名唯一化（就地改名，幂等）：内核遇到重名代理会拒掉整份配置。</summary>
    public static int EnsureUniqueNames(IList<ProxyNode> nodes)
    {
        var used = new HashSet<string>(StringComparer.Ordinal);
        var renamed = 0;
        foreach (var n in nodes)
        {
            var baseName = n.Name.Length > 0 ? n.Name : "node";
            var candidate = baseName;
            var i = 2;
            while (used.Contains(candidate)) candidate = $"{baseName} {i++}";
            if (candidate != n.Name) { n.Name = candidate; renamed++; }
            used.Add(candidate);
        }
        return renamed;
    }

    /// <summary>订阅声明的组要能经成员落到真实节点才可写入，否则内核报悬空引用。</summary>
    public static List<ProxyGroup> PlanGroups(IReadOnlyList<ProxyGroup> groups, IReadOnlyList<ProxyNode> validNodes)
    {
        var supported = new HashSet<string>(StringComparer.Ordinal) { "select", "url-test", "fallback", "load-balance", "relay" };
        var nodeNames = new HashSet<string>(validNodes.Select(n => n.Name), StringComparer.Ordinal);
        var originalToDisplay = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        var reserved = new HashSet<string>(StringComparer.Ordinal);
        foreach (var n in validNodes)
        {
            var original = n.OriginalName.Length > 0 ? n.OriginalName : n.Name;
            if (!originalToDisplay.TryGetValue(original, out var list)) originalToDisplay[original] = list = new List<string>();
            if (!list.Contains(n.Name)) list.Add(n.Name);
            reserved.Add(n.Name);
            reserved.Add(original);
        }

        var candidates = new List<ProxyGroup>();
        var accepted = new HashSet<string>(StringComparer.Ordinal);
        foreach (var g in groups)
        {
            var type = g.GroupType.Trim().ToLowerInvariant();
            var name = g.Name.Trim();
            if (!supported.Contains(type) || name.Length == 0 || name == "PROXY"
                || !IsSafeText(name) || reserved.Contains(name) || accepted.Contains(name)) continue;
            var copy = new ProxyGroup
            {
                Name = name, GroupType = type, SubscriptionId = g.SubscriptionId, Url = g.Url,
                IntervalSec = g.IntervalSec, ToleranceMs = g.ToleranceMs, ExpectedStatus = g.ExpectedStatus,
            };
            copy.Members.AddRange(g.Members);
            candidates.Add(copy);
            accepted.Add(name);
        }

        var grounded = new HashSet<string>(StringComparer.Ordinal);
        var order = new Dictionary<string, int>(StringComparer.Ordinal);
        var changed = true;
        while (changed)
        {
            changed = false;
            foreach (var g in candidates.Where(g => !grounded.Contains(g.Name)))
            {
                var isRelay = g.GroupType == "relay";
                foreach (var raw in g.Members)
                {
                    var reachesNode = nodeNames.Contains(raw)
                        || (originalToDisplay.TryGetValue(raw, out var d) && d.Count > 0);
                    var reachesGroup = !isRelay && grounded.Contains(raw) && raw != g.Name;
                    if (!reachesNode && !reachesGroup) continue;
                    order[g.Name] = order.Count;
                    grounded.Add(g.Name);
                    changed = true;
                    break;
                }
            }
        }

        var outList = new List<ProxyGroup>();
        foreach (var g in candidates.Where(g => grounded.Contains(g.Name)))
        {
            var isRelay = g.GroupType == "relay";
            var members = new List<string>();
            foreach (var raw in g.Members)
            {
                if (originalToDisplay.TryGetValue(raw, out var displays))
                {
                    foreach (var d in displays) if (!members.Contains(d)) members.Add(d);
                }
                else if (nodeNames.Contains(raw) && !members.Contains(raw)) members.Add(raw);
                else if (!isRelay && grounded.Contains(raw) && raw != g.Name
                         && order.TryGetValue(raw, out var o) && o < order[g.Name] && !members.Contains(raw))
                    members.Add(raw);
            }
            if (members.Count == 0) continue;
            g.Members.Clear();
            g.Members.AddRange(members);
            outList.Add(g);
        }
        return outList;
    }

    public static string NodeYaml(ProxyNode n)
    {
        if (DropReasonFor(n) != ProxyDropReason.None) return "  - {}";
        var kind = KindSlug(n.Kind);
        string Q(string v) => $"\"{Escape(v)}\"";

        // 逐字模板优先：模板里有的就回写，传输/选项字段全部保留，与桌面 Clash 用原始 YAML 等价。
        if (n.RawTemplate.Length > 0 && IsSafeText(n.RawTemplate))
        {
            var parts = new List<string> { $"name: {Q(n.Name)}", FlowBody(n.RawTemplate) };
            if (n.Uuid.Length > 0) parts.Add($"uuid: {Q(n.Uuid)}");
            if (n.Password.Length > 0) parts.Add($"password: {Q(n.Password)}");
            if (n.ProtocolParam.Length > 0) parts.Add($"protocol-param: {Q(n.ProtocolParam)}");
            if (n.ObfsParam.Length > 0)
                parts.Add($"{(kind == "hysteria2" ? "obfs-password" : "obfs-param")}: {Q(n.ObfsParam)}");
            if (kind is "vless" or "vmess" or "trojan" && n.Network == "ws" && !n.RawTemplate.Contains("ws-opts"))
            {
                var ws = new List<string> { "path: \"/\"" };
                if (n.Servername.Length > 0) ws.Add($"headers: {{Host: {Q(n.Servername)}}}");
                parts.Add($"ws-opts: {{{string.Join(", ", ws)}}}");
            }
            return "  - {" + string.Join(", ", parts) + "}";
        }

        // 无模板（URI 导入 / 块式写法）：结构化生成
        var f = new List<string> { $"name: {Q(n.Name)}", $"type: {kind}" };
        if (kind != "direct")
        {
            f.Add($"server: {Q(n.Server)}");
            f.Add($"port: {n.Port}");
        }
        if (kind is "ss" or "ssr" or "vmess" or "shadowsocks" or "shadowsocks-r")
            f.Add($"cipher: {Q(n.Method.Length > 0 ? n.Method : "auto")}");
        if (kind is "ss" or "ssr" or "trojan" or "hysteria2" or "shadowsocks" or "shadowsocks-r"
            || (kind != "vless" && kind != "vmess" && n.Password.Length > 0))
            f.Add($"password: {Q(n.Password)}");
        if (kind == "ssr")
        {
            f.Add($"protocol: {Q(n.Protocol)}");
            f.Add($"protocol-param: {Q(n.ProtocolParam)}");
            f.Add($"obfs: {Q(n.Obfs)}");
            f.Add($"obfs-param: {Q(n.ObfsParam)}");
        }
        if (kind is "vless" or "vmess" or "tuic" && n.Uuid.Length > 0) f.Add($"uuid: {Q(n.Uuid)}");
        if (kind == "vmess") f.Add($"alterId: {n.AlterId}");
        if (n.Udp) f.Add("udp: true");
        if (n.Network.Length > 0) f.Add($"network: {Q(n.Network)}");
        if (n.Tls) f.Add("tls: true");
        if (n.Servername.Length > 0)
            f.Add($"{(kind is "hysteria2" or "hysteria" or "tuic" ? "sni" : "servername")}: {Q(n.Servername)}");
        if (n.SkipCertVerify) f.Add("skip-cert-verify: true");
        if (n.Flow.Length > 0) f.Add($"flow: {Q(n.Flow)}");
        if (n.ClientFingerprint.Length > 0) f.Add($"client-fingerprint: {Q(n.ClientFingerprint)}");
        if (n.CertFingerprint.Length > 0) f.Add($"fingerprint: {Q(n.CertFingerprint)}");
        if (kind == "hysteria2")
        {
            if (n.Obfs.Length > 0) f.Add($"obfs: {Q(n.Obfs)}");
            if (n.ObfsParam.Length > 0) f.Add($"obfs-password: {Q(n.ObfsParam)}");
            if (n.HyUp.Length > 0) f.Add($"up: {Q(n.HyUp)}");
            if (n.HyDown.Length > 0) f.Add($"down: {Q(n.HyDown)}");
        }
        if (n.AlpnList.Length > 0 && kind is "vless" or "vmess" or "trojan" or "tuic" or "hysteria2" or "hysteria")
        {
            var items = n.AlpnList.Split(',').Select(x => x.Trim()).Where(x => x.Length > 0).Select(Q).ToList();
            if (items.Count > 0) f.Add($"alpn: [{string.Join(", ", items)}]");
        }
        if (n.RealityPublicKey.Length > 0 || n.RealityShortId.Length > 0)
        {
            var r = new List<string>();
            if (n.RealityPublicKey.Length > 0) r.Add($"public-key: {Q(n.RealityPublicKey)}");
            if (n.RealityShortId.Length > 0) r.Add($"short-id: {Q(n.RealityShortId)}");
            f.Add($"reality-opts: {{{string.Join(", ", r)}}}");
        }
        if (n.WsPath.Length > 0 || n.WsHost.Length > 0)
        {
            var ws = new List<string>();
            if (n.WsPath.Length > 0) ws.Add($"path: {Q(n.WsPath)}");
            if (n.WsHost.Length > 0) ws.Add($"headers: {{Host: {Q(n.WsHost)}}}");
            f.Add($"ws-opts: {{{string.Join(", ", ws)}}}");
        }
        else if (n.Network == "ws" && kind is "vless" or "vmess" or "trojan")
        {
            // Cloudflare 隧道类订阅常省略 ws-opts，缺 path/Host 会被 CF 拒。
            var ws = new List<string> { $"path: {Q("/")}" };
            if (n.Servername.Length > 0) ws.Add($"headers: {{Host: {Q(n.Servername)}}}");
            f.Add($"ws-opts: {{{string.Join(", ", ws)}}}");
        }
        if (n.GrpcServiceName.Length > 0) f.Add($"grpc-opts: {{grpc-service-name: {Q(n.GrpcServiceName)}}}");
        foreach (var kv in n.Extras)
        {
            if (!IsSafeKey(kv.Key) || !IsSafeText(kv.Value)) continue;
            if (kv.Key is "name" or "type" or "server" or "port") continue;
            var v = kv.Value;
            f.Add($"{kv.Key}: {(v.StartsWith('{') || v.StartsWith('[') || v is "true" or "false"
                || Regex.IsMatch(v, @"^-?-?[0-9]+(\.[0-9]+)?$") ? v : Q(v))}");
        }
        return "  - {" + string.Join(", ", f) + "}";
    }

    /// <summary>把存下来的 flow-map 模板剥掉最外层 { }：直接嵌套会被内核按「映射当标量」整份 fatal。</summary>
    internal static string FlowBody(string template)
    {
        var t = template.Trim();
        return t.Length >= 2 && t[0] == '{' && t[^1] == '}' ? t[1..^1].Trim() : t;
    }

    public static List<string> NormalizeCustomRules(IEnumerable<string> values)
    {
        var outList = new List<string>();
        foreach (var raw in values)
        {
            var rule = raw.Trim();
            if (rule.Length == 0 || ValidateCustomRule(rule).Length > 0) continue;
            var normalized = string.Join(',', rule.Split(',').Select(x => x.Trim()));
            if (!outList.Contains(normalized)) outList.Add(normalized);
        }
        return outList.Take(500).ToList();
    }

    /// <summary>
    /// 自定义规则白名单刻意保守：不开放 GEOSITE/RULE-SET（会在解析期同步联网下载），
    /// 不开放 DOMAIN-REGEX（payload 逗号与切分模型冲突），不开放 PROCESS-NAME（与应用分流两处口径打架）。
    /// </summary>
    public static string ValidateCustomRule(string rule)
    {
        var t = rule.Trim();
        if (t.Length == 0) return "规则为空";
        if (t.Length > 512) return "规则超过 512 字符";
        if (t.Contains('\n') || t.Contains('\r')) return "规则不能包含换行";
        if (t.Contains('#')) return "规则不能包含注释符 #";
        var parts = t.Split(',').Select(x => x.Trim()).ToArray();
        if (parts.Length is not (3 or 4)) return "格式应为 类型,值,策略[,no-resolve]";
        var type = parts[0].ToUpperInvariant();
        string[] allowed = { "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6", "GEOIP" };
        if (!allowed.Contains(type)) return $"不支持的规则类型 {parts[0]}";
        if (parts[1].Length == 0) return "匹配值为空";
        if (type is "DOMAIN" or "DOMAIN-SUFFIX" or "DOMAIN-KEYWORD")
        {
            if (parts[1].Any(char.IsWhiteSpace) || parts[1].Contains('"') || parts[1].Contains('\''))
                return "域名值不能包含空白或引号";
            if (type != "DOMAIN-KEYWORD" && parts[1].Contains("..")) return "域名不能包含连续点号";
        }
        else if (type == "IP-CIDR")
        {
            var m = Regex.Match(parts[1], @"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$");
            if (!m.Success) return "IPv4 CIDR 应为 a.b.c.d/掩码";
            for (var i = 1; i <= 4; i++) if (int.Parse(m.Groups[i].Value) > 255) return "IPv4 地址段超出 0-255";
            if (int.Parse(m.Groups[5].Value) > 32) return "IPv4 掩码超出 0-32";
        }
        else if (type == "GEOIP" && !Regex.IsMatch(parts[1], @"^[A-Za-z]{2,8}$"))
            return "GEOIP 值应为 2-8 位国家/地区代码";
        var target = parts[2].ToUpperInvariant();
        string[] targets = { "DIRECT", "PROXY", "REJECT", "PASS", "REJECT-DROP" };
        if (!targets.Contains(target)) return $"策略 {parts[2]} 不支持";
        if (parts.Length == 4)
        {
            if (parts[3] != "no-resolve") return "第四段只支持 no-resolve";
            if (type is not ("IP-CIDR" or "IP-CIDR6" or "GEOIP")) return "no-resolve 仅对 IP/GEOIP 规则有效";
        }
        return "";
    }

    /// <summary>DNS 复写地址表：逐条过校验、去重、限量（内核遇到一条不认的地址会拒掉整份配置）。</summary>
    public static List<string> NormalizeDnsServers(IEnumerable<string> values)
    {
        var outList = new List<string>();
        foreach (var raw in values)
        {
            var v = (raw ?? "").Trim();
            if (ValidateDnsServer(v).Length > 0 || outList.Contains(v, StringComparer.OrdinalIgnoreCase)) continue;
            outList.Add(v);
        }
        return outList.Take(20).ToList();
    }

    /// <summary>返回空串表示可用，否则给一句能直接显示给用户的原因。</summary>
    public static string ValidateDnsServer(string value)
    {
        var v = (value ?? "").Trim();
        if (v.Length == 0) return "地址为空";
        if (v.Length > 256) return "地址超过 256 字符";
        if (v.Any(c => c <= 0x20 || c == 0x7f || c == '"' || c == '\'')) return "地址不能包含空白或引号";
        if (v is "system") return "";
        var scheme = Regex.Match(v, @"^([a-z][a-z0-9]*)://(.+)$", RegexOptions.IgnoreCase);
        if (scheme.Success)
        {
            var name = scheme.Groups[1].Value.ToLowerInvariant();
            if (name is not ("udp" or "tcp" or "tls" or "https" or "quic" or "h3"))
                return $"不支持的协议 {scheme.Groups[1].Value}（可用 udp / tcp / tls / https / quic / h3）";
            var rest = scheme.Groups[2].Value;
            if (!rest.Contains('.') && !rest.Contains(':'))
                return $"{name}:// 后面要写服务器域名或 IP，如 {name}://223.5.5.5";
            return "";
        }
        if (v.Contains("://")) return "协议写法不完整，应为 协议://地址";
        var host = v.Contains(':') && !v.StartsWith('[') ? v[..v.IndexOf(':')] : v;
        if (IsIp(host))
        {
            if (v == host) return "";
            var portText = v[(host.Length + 1)..];
            if (portText.Contains(':')) return "IPv6 地址请写成 [::1]:53 的形式";
            return int.TryParse(portText, out var port) && port is > 0 and <= 65535 ? "" : "端口应为 1-65535";
        }
        if (v.StartsWith('[') && v.Contains(']')) return "";
        // 裸域名内核按 udp:53 处理，也收下
        if (NormalizeDomain(v).Length > 0) return "";
        return "请填写 DNS 地址，如 223.5.5.5、tls://223.5.5.5:853、https://doh.pub/dns-query";
    }

    public static string SafeUrl(string raw)
    {
        var u = raw.Trim();
        if (u.Length is 0 or > 2048 || !IsSafeText(u) || !(u.StartsWith("http://") || u.StartsWith("https://")))
            return "http://www.gstatic.com/generate_204";
        return Escape(u);
    }

    private static bool UsedName(IReadOnlyList<ProxyNode> nodes, IReadOnlyList<ProxyGroup> groups, string name) =>
        nodes.Any(n => n.Name == name) || groups.Any(g => g.Name == name) || name == "PROXY";

    private static Dictionary<string, string> NormalizeHosts(IReadOnlyDictionary<string, string>? hosts)
    {
        var outDict = new Dictionary<string, string>(StringComparer.Ordinal);
        if (hosts == null) return outDict;
        foreach (var kv in hosts)
        {
            var host = NormalizeDomain(kv.Key);
            if (host.Length > 0 && IsIp(kv.Value.Trim())) outDict[host] = kv.Value.Trim().ToLowerInvariant();
        }
        return outDict;
    }

    private static string NormalizeDomain(string value)
    {
        var d = (value ?? "").Trim().ToLowerInvariant().TrimEnd('.');
        if (d.Length is 0 or > 253) return "";
        if (d.IndexOfAny(new[] { '\n', '\r', ',', ':', '#', '[', ']', '{', '}', '*', ' ' }) >= 0) return "";
        if (d.StartsWith('.') || d.EndsWith('.') || d.Contains("..")) return "";
        foreach (var label in d.Split('.'))
        {
            if (label.Length is 0 or > 63) return "";
            if (label.StartsWith('-') || label.EndsWith('-')) return "";
            if (!label.All(c => char.IsAsciiLetterOrDigit(c) || c == '-')) return "";
        }
        return d;
    }

    private static List<string> NormalizeDomains(IEnumerable<string> values)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var outList = new List<string>();
        foreach (var v in values)
        {
            var d = NormalizeDomain(v);
            if (d.Length > 0 && seen.Add(d)) outList.Add(d);
        }
        return outList;
    }

    private static bool IsIp(string value)
    {
        if (value.Length == 0 || value.Any(c => c is '\n' or '\r' or ' ' or '\t' or '%' or ',' or '#')) return false;
        var m = Regex.Match(value, @"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$");
        if (m.Success)
        {
            for (var i = 1; i <= 4; i++) if (int.Parse(m.Groups[i].Value) > 255) return false;
            return true;
        }
        return value.Contains(':') && Regex.IsMatch(value, @"^[0-9a-fA-F:]+$");
    }

    private static bool IsSafeText(string value) =>
        value.Length <= 65536 && !value.Contains('\n') && !value.Contains('\r') && !value.Contains('\0');

    private static bool IsSafeKey(string key) =>
        key.Length is > 0 and <= 64 && Regex.IsMatch(key, @"^[a-z0-9\-]+$");

    public static string Escape(string value)
    {
        var sb = new StringBuilder(value.Length);
        foreach (var ch in value)
        {
            switch (ch)
            {
                case '\\': sb.Append("\\\\"); break;
                case '"': sb.Append("\\\""); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (ch < 0x20 || ch == 0x7f) sb.Append('?');
                    else sb.Append(ch);
                    break;
            }
        }
        return sb.ToString();
    }

    /// <summary>YAML 可打印净化：控制字符会让内核报 "control characters are not allowed" 并拒绝整份配置。</summary>
    public static string Sanitize(string value)
    {
        var needsRewrite = value.Any(c =>
            c == '\t' || c == '\r' || (c < 0x20 && c != '\n') || (c >= 0x7f && c <= 0x9f));
        if (!needsRewrite) return value;
        var sb = new StringBuilder(value.Length);
        foreach (var c in value)
        {
            if (c == '\t' || c == '\r') sb.Append(' ');
            else if (c == '\n' || (c >= 0x20 && c <= 0x7e) || c >= 0xa0) sb.Append(c);
            else sb.Append('?');
        }
        return sb.ToString();
    }
}
