using System.Text;
using System.Text.RegularExpressions;
using TunBox.Core.Models;
using YamlDotNet.RepresentationModel;

namespace TunBox.Core.Parsing;

public sealed class SubscriptionResult
{
    public List<ProxyNode> Nodes { get; } = new();
    public List<ProxyGroup> Groups { get; } = new();
    public List<string> Warnings { get; } = new();
    public bool LooksLikeYaml { get; set; }
}

/// <summary>
/// 订阅内容解析：分享链接（ss/ssr/vmess/vless/trojan/hysteria2/hysteria/tuic/anytls/socks5）、
/// 整段 base64、以及 YAML 订阅（proxies / proxy-groups）。
///
/// YAML 路径的要点是 RawTemplate：把订阅原文里每个代理的映射**逐字**保留下来（只剥 name
/// 与凭据键），生成配置时原样回写。xhttp-opts、headers、dialer-proxy、smux 这类字段
/// app 不去理解它，就不会在「解析→重生成」里丢掉或理解错。
/// </summary>
public static class SubscriptionParser
{
    /// <summary>只有带 proxies: / proxy-groups: / proxy-providers: 顶层键的文本才当 YAML。</summary>
    private static readonly Regex YamlMarker = new(@"(?m)^\s*(proxies|proxy-groups|proxy-providers)\s*:", RegexOptions.Compiled);

    public static SubscriptionResult Parse(string content, string subscriptionId = "")
        => Parse(content, subscriptionId, dedupe: true);

    public static SubscriptionResult Parse(string content, string subscriptionId, bool dedupe)
    {
        var result = new SubscriptionResult();
        var text = (content ?? "").Trim().Replace("\r\n", "\n");
        if (text.Length == 0) return result;

        if (YamlMarker.IsMatch(text))
        {
            result.LooksLikeYaml = true;
            ParseYaml(text, subscriptionId, result);
        }
        else
        {
            var body = TryDecodeBase64Blob(text, out var decoded) ? decoded : text;
            foreach (var rawLine in body.Split('\n'))
            {
                var line = rawLine.Trim();
                if (line.Length == 0 || line.StartsWith('#') || line.StartsWith("//")) continue;
                if (TryParseLink(line, subscriptionId, result)) continue;
                result.Warnings.Add("无法解析的链接（协议不支持或字段残缺）：" + SafePreview(line));
            }
        }

        if (dedupe)
        {
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var kept = new List<ProxyNode>();
            foreach (var n in result.Nodes)
            {
                // 身份以订阅原文的名字为准：中转/落地分离的机场会让所有节点共用
                // 同一个入口服务器+UUID，只有名字不同 —— 按端点去重会把它们整批吃掉（真机实测）。
                var key = $"{n.OriginalName}|{n.Kind}|{n.Server}|{n.Port}|{n.Uuid}|{n.Password}|{n.Method}|{n.Obfs}|{n.ObfsParam}";
                if (seen.Add(key)) kept.Add(n);
            }
            if (kept.Count != result.Nodes.Count)
                result.Warnings.Add($"已合并 {result.Nodes.Count - kept.Count} 个重复节点");
            result.Nodes.Clear();
            result.Nodes.AddRange(kept);
        }

        var i = 1;
        foreach (var n in result.Nodes) if (n.Id.Length == 0) n.Id = "n" + i++;
        return result;
    }

    private static string SafePreview(string line) => line.Length <= 80 ? line : line[..80] + "…";

    // ── 分享链接 ──────────────────────────────────────────────────────────

    private static bool TryParseLink(string line, string subscriptionId, SubscriptionResult result)
    {
        var schemeEnd = line.IndexOf("://", StringComparison.Ordinal);
        if (schemeEnd <= 0) return false;
        var scheme = line[..schemeEnd].ToLowerInvariant();
        try
        {
            var node = scheme switch
            {
                "ss" => ParseSs(line),
                "ssr" => ParseSsr(line),
                "vmess" => ParseVmess(line),
                "vless" => ParseVlessTrojan(line, ProxyKind.Vless),
                "trojan" => ParseVlessTrojan(line, ProxyKind.Trojan),
                "hysteria2" or "hy2" => ParseHysteria2(line),
                "hysteria" or "hy" => ParseHysteria(line),
                "tuic" => ParseTuic(line),
                "anytls" => ParseAnytls(line),
                "socks5" or "socks" => ParseSocks(line),
                _ => null,
            };
            if (node == null) return false;
            node.SubscriptionId = subscriptionId;
            if (node.OriginalName.Length == 0) node.OriginalName = node.Name;
            result.Nodes.Add(node);
            return true;
        }
        catch { return false; }
    }

    private readonly record struct UriParts(string Host, int Port, string Query, string Fragment);

    private static UriParts SplitUri(string body)
    {
        var hash = body.IndexOf('#');
        var fragment = hash >= 0 ? Uri.UnescapeDataString(body[(hash + 1)..]) : "";
        if (hash >= 0) body = body[..hash];
        var q = body.IndexOf('?');
        var query = q >= 0 ? body[(q + 1)..] : "";
        if (q >= 0) body = body[..q];

        var at = body.LastIndexOf('@');
        if (at >= 0) body = body[(at + 1)..];
        body = body.TrimEnd('/');      // 面板常生成 host:port/?query，尾斜杠会把端口切坏

        var host = ""; var port = 0;
        if (body.StartsWith('['))
        {
            var close = body.IndexOf(']');
            if (close > 0)
            {
                host = body[1..close];
                var rest = body[(close + 1)..];
                if (rest.StartsWith(':')) int.TryParse(rest[1..], out port);
            }
        }
        else
        {
            var colon = body.LastIndexOf(':');
            if (colon >= 0 && int.TryParse(body[(colon + 1)..], out port)) host = body[..colon];
            else if (colon < 0) host = body;
        }
        host = Uri.UnescapeDataString(host);
        return new UriParts(host, port, query, fragment);
    }

    private static Dictionary<string, string> QueryParams(string query)
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in query.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = pair.IndexOf('=');
            var k = eq >= 0 ? pair[..eq] : pair;
            var v = eq >= 0 ? pair[(eq + 1)..] : "";
            map[Uri.UnescapeDataString(k)] = Uri.UnescapeDataString(v).Replace('+', ' ');
        }
        return map;
    }

    private static ProxyNode BaseNode(ProxyKind kind, string name, string host, int port) => new()
    {
        Kind = kind,
        Name = name.Length > 0 ? name : $"{host}:{port}",
        Server = host,
        Port = port,
    };

    private static ProxyNode? ParseSs(string line)
    {
        var body = line["ss://".Length..];
        var hash = body.IndexOf('#');
        var fragment = hash >= 0 ? Uri.UnescapeDataString(body[(hash + 1)..]) : "";
        if (hash >= 0) body = body[..hash];
        var q = body.IndexOf('?');
        var query = q >= 0 ? body[(q + 1)..] : "";
        if (q >= 0) body = body[..q];

        string userinfo, hostport;
        var at = body.LastIndexOf('@');
        if (at >= 0)
        {
            userinfo = Uri.UnescapeDataString(body[..at]);
            hostport = body[(at + 1)..];
            // 面板常把凭据段也 base64 一遍（没有冒号可辨认时先试解码）
            if (!userinfo.Contains(':') && TryBase64(userinfo, out var decoded) && decoded!.Contains(':'))
                userinfo = decoded;
        }
        else
        {
            // 整段 base64(method:pass@host:port)
            if (!TryBase64(body, out var decoded) || decoded == null || !decoded.Contains('@')) return null;
            var a = decoded.LastIndexOf('@');
            userinfo = decoded[..a];
            hostport = decoded[(a + 1)..];
        }

        var colon = userinfo.IndexOf(':');
        if (colon < 0) return null;
        var (host, port, _, _) = SplitUri(hostport);
        if (!ValidHost(host) || port <= 0) return null;
        var node = BaseNode(ProxyKind.Ss, fragment, host, port);
        node.Method = userinfo[..colon];
        node.Password = userinfo[(colon + 1)..];
        ApplySsPlugin(node, query);
        return node;
    }

    private static void ApplySsPlugin(ProxyNode node, string query)
    {
        foreach (var kv in QueryParams(query))
        {
            if (!kv.Key.Equals("plugin", StringComparison.OrdinalIgnoreCase) || !kv.Value.StartsWith("obfs-local")) continue;
            foreach (var opt in kv.Value.Split(';'))
            {
                if (opt.StartsWith("obfs=")) node.Obfs = opt[5..];
                else if (opt.StartsWith("obfs-host=")) node.ObfsParam = opt[10..];
            }
        }
    }

    private static ProxyNode? ParseSsr(string line)
    {
        if (!TryBase64(line["ssr://".Length..], out var plain) || plain == null) return false_or_null();
        var main = plain.Split('/')[0];
        var parts = main.Split(':');
        if (parts.Length < 6 || !int.TryParse(parts[1], out var port)) return null;
        var node = BaseNode(ProxyKind.Ssr, "", parts[0], port);
        node.Protocol = parts[2];
        node.Method = parts[3];
        node.Obfs = parts[4];
        node.Password = TryBase64(parts[5], out var p) ? p ?? "" : parts[5];
        var rest = plain[main.Length..];
        if (rest.StartsWith('/'))
        {
            foreach (var kv in rest[1..].Split('&'))
            {
                var eq = kv.IndexOf('=');
                if (eq < 0) continue;
                var k = kv[..eq];
                var v = TryBase64(kv[(eq + 1)..], out var d) ? d ?? "" : kv[(eq + 1)..];
                if (k == "remarks") node.Name = v;
                else if (k == "protoparam") node.ProtocolParam = v;
                else if (k == "obfsparam") node.ObfsParam = v;
                else if (k == "group") node.Extras["group"] = v;
            }
        }
        if (node.Name.Length == 0) node.Name = $"{node.Server}:{node.Port}";
        return node;
    }

    private static ProxyNode? false_or_null() => null;

    private static ProxyNode? ParseVmess(string line)
    {
        if (!TryBase64(line["vmess://".Length..], out var json) || json == null) return null;
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            var root = doc.RootElement;
            string S(string name) => root.TryGetProperty(name, out var e)
                ? (e.ValueKind == System.Text.Json.JsonValueKind.String ? e.GetString() ?? "" : e.ValueKind == System.Text.Json.JsonValueKind.Number ? e.GetRawText() : "")
                : "";
            if (!int.TryParse(S("port"), out var port)) return null;
            var host = S("add");
            if (!ValidHost(host) || !root.TryGetProperty("id", out _)) return null;
            var node = BaseNode(ProxyKind.Vmess, S("ps"), host, port);
            node.Uuid = S("id");
            node.Network = S("net");
            node.Method = S("scy").Length > 0 ? S("scy") : "auto";
            node.Tls = S("tls") is "tls" or "reality";
            node.Servername = S("sni").Length > 0 ? S("sni") : S("host");
            int.TryParse(S("aid"), out var aid);
            node.AlterId = aid;
            node.WsPath = node.Network == "ws" ? S("path") : "";
            node.WsHost = node.Network == "ws" ? S("host") : "";
            node.SkipCertVerify = S("allowInsecure") is "1" or "true";
            return node;
        }
        catch { return null; }
    }

    private static ProxyNode? ParseVlessTrojan(string line, ProxyKind kind)
    {
        var prefix = kind == ProxyKind.Vless ? "vless://" : "trojan://";
        var body = line[prefix.Length..];
        var (host, port, query, fragment) = SplitUri(body);
        if (!ValidHost(host) || port <= 0) return null;
        var userinfo = body.Split('?')[0].Split('#')[0];
        var at = userinfo.LastIndexOf('@');
        if (at < 0) return null;
        userinfo = Uri.UnescapeDataString(userinfo[..at]);
        var q = QueryParams(query);
        var node = BaseNode(kind, fragment, host, port);
        node.Uuid = kind == ProxyKind.Vless ? userinfo : "";
        node.Password = kind == ProxyKind.Trojan ? userinfo : "";
        node.Network = q.GetValueOrDefault("type", "tcp").ToLowerInvariant();
        node.Tls = q.GetValueOrDefault("security", kind == ProxyKind.Trojan ? "tls" : "none") is "tls" or "reality";
        node.Servername = q.GetValueOrDefault("sni", q.GetValueOrDefault("host", ""));
        node.Flow = q.GetValueOrDefault("flow", "");
        node.ClientFingerprint = q.GetValueOrDefault("fp", "");
        node.SkipCertVerify = q.GetValueOrDefault("allowInsecure", q.GetValueOrDefault("insecure", "")) is "1" or "true";
        node.GrpcServiceName = node.Network == "grpc" ? q.GetValueOrDefault("serviceName", "") : "";
        if (node.Network == "ws")
        {
            node.WsPath = q.GetValueOrDefault("path", "/");
            node.WsHost = q.GetValueOrDefault("host", "");
        }
        if (q.TryGetValue("alpn", out var alpn)) node.AlpnList = alpn.Replace(" ", "");
        if (q.GetValueOrDefault("security") == "reality")
        {
            node.RealityPublicKey = q.GetValueOrDefault("pbk", "");
            node.RealityShortId = q.GetValueOrDefault("sid", "");
        }
        if (kind == ProxyKind.Vless ? node.Uuid.Length == 0 : node.Password.Length == 0) return null;
        return node;
    }

    private static ProxyNode? ParseHysteria2(string line)
    {
        var body = line["hysteria2://".Length..];
        var (host, port, query, fragment) = SplitUri(body);
        if (!ValidHost(host) || port <= 0) return null;
        var userinfo = body.Split('?')[0].Split('#')[0];
        var at = userinfo.LastIndexOf('@');
        if (at < 0) return null;
        var q = QueryParams(query);
        var node = BaseNode(ProxyKind.Hysteria2, fragment, host, port);
        node.Password = Uri.UnescapeDataString(userinfo[..at]);
        node.Servername = q.GetValueOrDefault("sni", "");
        node.Obfs = q.GetValueOrDefault("obfs", "");
        node.ObfsParam = q.GetValueOrDefault("obfs-password", "");
        node.SkipCertVerify = q.GetValueOrDefault("insecure", q.GetValueOrDefault("allowInsecure", "")) is "1" or "true";
        return node.Password.Length == 0 ? null : node;
    }

    private static ProxyNode? ParseHysteria(string line)
    {
        var body = line["hysteria://".Length..];
        var (host, port, query, fragment) = SplitUri(body);
        if (!ValidHost(host) || port <= 0) return null;
        var userinfo = body.Split('?')[0].Split('#')[0];
        var at = userinfo.LastIndexOf('@');
        var q = QueryParams(query);
        var node = BaseNode(ProxyKind.Hysteria, fragment, host, port);
        node.Password = at >= 0 ? Uri.UnescapeDataString(userinfo[..at]) : q.GetValueOrDefault("auth", "");
        node.Servername = q.GetValueOrDefault("sni", q.GetValueOrDefault("peer", ""));
        node.Protocol = q.GetValueOrDefault("protocol", "udp");
        node.HyUp = q.GetValueOrDefault("up", q.GetValueOrDefault("upmbps", ""));
        node.HyDown = q.GetValueOrDefault("down", q.GetValueOrDefault("downmbps", ""));
        node.Obfs = q.GetValueOrDefault("obfs", "");
        node.AlpnList = q.GetValueOrDefault("alpn", "h3");
        node.SkipCertVerify = q.GetValueOrDefault("insecure", "") is "1" or "true";
        return node.Password.Length == 0 ? null : node;
    }

    private static ProxyNode? ParseTuic(string line)
    {
        var body = line["tuic://".Length..];
        var (host, port, query, fragment) = SplitUri(body);
        if (!ValidHost(host) || port <= 0) return null;
        var userinfo = body.Split('?')[0].Split('#')[0];
        var at = userinfo.LastIndexOf('@');
        if (at < 0) return null;
        var cred = Uri.UnescapeDataString(userinfo[..at]);
        var colon = cred.IndexOf(':');
        var q = QueryParams(query);
        var node = BaseNode(ProxyKind.Tuic, fragment, host, port);
        node.Uuid = colon >= 0 ? cred[..colon] : cred;
        node.Password = colon >= 0 ? cred[(colon + 1)..] : "";
        node.Servername = q.GetValueOrDefault("sni", "");
        node.SkipCertVerify = q.GetValueOrDefault("allow_insecure", q.GetValueOrDefault("insecure", "")) is "1" or "true";
        node.AlpnList = q.GetValueOrDefault("alpn", "h3");
        return node.Uuid.Length == 0 ? null : node;
    }

    private static ProxyNode? ParseAnytls(string line)
    {
        var body = line["anytls://".Length..];
        var (host, port, query, fragment) = SplitUri(body);
        if (!ValidHost(host) || port <= 0) return null;
        var userinfo = body.Split('?')[0].Split('#')[0];
        var at = userinfo.LastIndexOf('@');
        if (at < 0) return null;
        var q = QueryParams(query);
        var node = BaseNode(ProxyKind.AnyTls, fragment, host, port);
        node.Password = Uri.UnescapeDataString(userinfo[..at]);
        node.Servername = q.GetValueOrDefault("sni", "");
        node.SkipCertVerify = q.GetValueOrDefault("insecure", "") is "1" or "true";
        return node.Password.Length == 0 ? null : node;
    }

    private static ProxyNode? ParseSocks(string line)
    {
        var body = line[(line.IndexOf("://", StringComparison.Ordinal) + 3)..];
        var (host, port, _, fragment) = SplitUri(body);
        if (!ValidHost(host) || port <= 0) return null;
        var userinfo = body.Split('?')[0].Split('#')[0];
        var at = userinfo.LastIndexOf('@');
        var node = BaseNode(ProxyKind.Socks5, fragment, host, port);
        if (at >= 0)
        {
            var cred = Uri.UnescapeDataString(userinfo[..at]);
            var colon = cred.IndexOf(':');
            node.Uuid = colon >= 0 ? cred[..colon] : "";
            node.Password = colon >= 0 ? cred[(colon + 1)..] : "";
        }
        return node;
    }

    private static bool ValidHost(string host) =>
        host.Length > 0 && !host.Contains('/') && !host.Contains(' ') && !host.Contains(':');

    // ── base64 ────────────────────────────────────────────────────────────

    private static bool TryDecodeBase64Blob(string text, out string decoded)
    {
        decoded = "";
        var compact = string.Concat(text.Where(c => !char.IsWhiteSpace(c)));
        if (compact.Length < 16 || compact.Contains("://")) return false;
        if (!TryBase64(compact, out var s) || s == null) return false;
        var trimmed = s.Trim();
        if (!trimmed.Contains("://") && !YamlMarker.IsMatch(trimmed)) return false;
        decoded = trimmed;
        return true;
    }

    /// <summary>允许 url-safe 字母表与缺省 padding。全字符必须可打印（控制字符 = 二进制垃圾）。</summary>
    private static bool TryBase64(string? value, out string? decoded)
    {
        decoded = null;
        if (string.IsNullOrWhiteSpace(value)) return false;
        var compact = string.Concat(value.Where(c => !char.IsWhiteSpace(c)));
        if (compact.Length == 0) return false;
        var fixed1 = compact.Replace('-', '+').Replace('_', '/').Replace("=", "").TrimEnd('=');
        // 内层 padding（订阅套 base64 时很常见）会让 FromBase64String 抛异常：
        // '=' 不在 base64 字母表里，先全部去掉再补齐是各客户端通用的容错。
        foreach (var variant in new[] { fixed1.PadRight(fixed1.Length + (4 - fixed1.Length % 4) % 4, '='), fixed1 })
        {
            try
            {
                var bytes = Convert.FromBase64String(variant);
                var text = Encoding.UTF8.GetString(bytes);
                // 换行/回车是订阅的合法分隔符，不算「二进制垃圾」
                if (text.Length == 0 || text.Any(c => c is not ('\n' or '\r' or '\t') && char.IsControl(c))) continue;
                decoded = text;
                return true;
            }
            catch { /* 换下一个变体 */ }
        }
        return false;
    }

    // ── YAML ──────────────────────────────────────────────────────────────

    private static void ParseYaml(string text, string subscriptionId, SubscriptionResult result)
    {
        var stream = new YamlStream();
        try { stream.Load(new StringReader(text)); }
        catch (Exception e) { result.Warnings.Add("YAML 解析失败：" + e.Message); return; }
        if (stream.Documents.Count == 0 || stream.Documents[0].RootNode is not YamlMappingNode root) return;

        if (root.Children.FirstOrDefault(c => Key(c) == "proxies").Value is YamlSequenceNode proxies)
        {
            foreach (var item in proxies)
            {
                if (item is not YamlMappingNode map) { result.Warnings.Add("跳过无法识别的 proxy 项（不是映射）"); continue; }
                var node = NodeFromYaml(map, subscriptionId, result);
                if (node != null) result.Nodes.Add(node);
                else result.Warnings.Add("跳过无法识别的 proxy 项（缺 type/name 或协议不支持）");
            }
        }

        if (root.Children.FirstOrDefault(c => Key(c) == "proxy-groups").Value is YamlSequenceNode groups)
        {
            foreach (var item in groups)
            {
                if (item is not YamlMappingNode map) continue;
                var name = Val(map, "name");
                var type = Val(map, "type").ToLowerInvariant();
                if (name.Length == 0 || type.Length == 0) continue;
                var g = new ProxyGroup { Name = name, GroupType = type, SubscriptionId = subscriptionId };
                g.Url = Val(map, "url");
                _ = int.TryParse(Val(map, "interval"), out var interval);
                g.IntervalSec = interval;
                _ = int.TryParse(Val(map, "tolerance"), out var tol);
                g.ToleranceMs = tol;
                g.ExpectedStatus = Val(map, "expected-status");
                if (map.Children.FirstOrDefault(c => Key(c) == "proxies").Value is YamlSequenceNode members)
                    foreach (var m in members) g.Members.Add(Val(m));
                result.Groups.Add(g);
            }
        }
    }

    private static ProxyNode? NodeFromYaml(YamlMappingNode map, string subscriptionId, SubscriptionResult result)
    {
        var name = Val(map, "name");
        var type = Val(map, "type").ToLowerInvariant();
        if (name.Length == 0 || type.Length == 0) return null;
        var kind = type switch
        {
            "ss" or "shadowsocks" => ProxyKind.Ss,
            "ssr" or "shadowsocks-r" => ProxyKind.Ssr,
            "vless" => ProxyKind.Vless,
            "vmess" => ProxyKind.Vmess,
            "trojan" => ProxyKind.Trojan,
            "hysteria2" => ProxyKind.Hysteria2,
            "hysteria" => ProxyKind.Hysteria,
            "tuic" => ProxyKind.Tuic,
            "anytls" => ProxyKind.AnyTls,
            "socks5" => ProxyKind.Socks5,
            "http" => ProxyKind.Http,
            "direct" => ProxyKind.Direct,
            _ => ProxyKind.Unknown,
        };
        _ = int.TryParse(Val(map, "port"), out var port);
        var node = new ProxyNode
        {
            Kind = kind, Name = name, OriginalName = name,
            Server = Val(map, "server"), Port = port, SubscriptionId = subscriptionId,
        };
        node.Uuid = Val(map, "uuid");
        node.Password = Val(map, "password");
        node.Method = Val(map, "cipher");
        node.Protocol = Val(map, "protocol");
        node.ProtocolParam = Val(map, "protocol-param");
        node.Obfs = Val(map, "obfs");
        node.ObfsParam = Val(map, "obfs-param").Length > 0 ? Val(map, "obfs-param") : Val(map, "obfs-password");
        node.Network = Val(map, "network");
        node.Servername = Val(map, "servername").Length > 0 ? Val(map, "servername") : Val(map, "sni");
        node.Flow = Val(map, "flow");
        node.ClientFingerprint = Val(map, "client-fingerprint");
        node.CertFingerprint = Val(map, "fingerprint");
        node.AlterId = int.TryParse(Val(map, "alterId"), out var aid) ? aid : 0;
        node.Tls = Val(map, "tls") == "true";
        node.Udp = Val(map, "udp") != "false";
        node.SkipCertVerify = Val(map, "skip-cert-verify") == "true";
        if (map.Children.FirstOrDefault(c => Key(c) == "alpn").Value is YamlSequenceNode alpn)
            node.AlpnList = string.Join(',', alpn.Children.Select(Val).Where(x => x.Length > 0));
        if (map.Children.FirstOrDefault(c => Key(c) == "reality-opts").Value is YamlMappingNode reality)
        {
            node.RealityPublicKey = Val(reality, "public-key");
            node.RealityShortId = Val(reality, "short-id");
        }
        if (map.Children.FirstOrDefault(c => Key(c) == "ws-opts").Value is YamlMappingNode ws)
        {
            node.WsPath = Val(ws, "path");
            if (ws.Children.FirstOrDefault(c => Key(c) == "headers").Value is YamlMappingNode headers)
                node.WsHost = Val(headers, "Host");
        }
        if (map.Children.FirstOrDefault(c => Key(c) == "grpc-opts").Value is YamlMappingNode grpc)
            node.GrpcServiceName = Val(grpc, "grpc-service-name");
        if (kind is ProxyKind.Hysteria or ProxyKind.Hysteria2)
        {
            node.HyUp = Val(map, "up");
            node.HyDown = Val(map, "down");
        }

        // 凭据之外的未知键逐字收进 Extras，再生成时原样回写
        foreach (var child in map.Children)
        {
            var key = Key(child);
            if (ReservedKeys.Contains(key)) continue;
            var value = InlineFlow(child.Value);
            if (value.Length > 0) node.Extras[key] = value;
        }

        // RawTemplate：整张映射按 flow-map 重排（保留未知字段原文），剥掉 name 与凭据键
        node.RawTemplate = TemplateOf(map);

        var reason = DropReason(node);
        if (reason.Length > 0) { result.Warnings.Add($"跳过节点 {name}：{reason}"); return null; }
        return node;
    }

    private static readonly HashSet<string> ReservedKeys = new(StringComparer.Ordinal)
    {
        "name", "type", "server", "port", "uuid", "password", "cipher", "protocol", "protocol-param",
        "obfs", "obfs-param", "obfs-password", "network", "servername", "sni", "flow",
        "client-fingerprint", "fingerprint", "alterId", "tls", "udp", "skip-cert-verify", "alpn",
        "reality-opts", "ws-opts", "grpc-opts", "up", "down",
    };

    /// <summary>生成配置前复检：一个坏节点会让内核拒掉**整份**配置，必须先拦。</summary>
    internal static string DropReason(ProxyNode n)
    {
        if (n.Kind == ProxyKind.Unknown) return "协议不支持";
        if (n.Name.Length == 0 || n.Server.Length == 0) return "缺 name/server";
        if (n.Port is <= 0 or > 65535) return "端口非法";
        if (n.Kind is ProxyKind.Ss or ProxyKind.Ssr && n.Method.Length == 0) return "缺 cipher";
        if (n.Kind is ProxyKind.Vless or ProxyKind.Vmess && n.Uuid.Length == 0) return "缺 uuid";
        if (n.Kind is ProxyKind.Trojan or ProxyKind.Hysteria2 or ProxyKind.AnyTls && n.Password.Length == 0) return "缺 password";
        if (n.Kind == ProxyKind.Tuic && (n.Uuid.Length == 0 || n.Password.Length == 0)) return "缺 uuid/password";
        foreach (var v in new[] { n.Name, n.Server, n.Password, n.Method, n.Uuid, n.Network, n.Servername, n.WsPath, n.WsHost })
            if (v.Contains('\n') || v.Contains('\r') || v.Contains('\0')) return "字段含换行/NUL";
        return "";
    }

    /// <summary>
    /// 整张映射按 flow-map 重排：`{type: "vless", server: ...}`。
    /// 只剥 name 与凭据键 —— 这是「解析→重生成丢字段」的根治方案：模板里有的就回写，
    /// app 不再逐个理解 xhttp-opts / headers / dialer-proxy / smux。
    /// </summary>
    private static string TemplateOf(YamlMappingNode map)
    {
        var parts = new List<string>();
        foreach (var child in map.Children)
        {
            var key = Key(child);
            if (key is "name" or "uuid" or "password" or "protocol-param" or "obfs-param" or "obfs-password") continue;
            var value = InlineFlow(child.Value);
            if (value.Length == 0) continue;
            parts.Add(FlowKey(key) + ": " + value);
        }
        return "{" + string.Join(", ", parts) + "}";
    }

    private static string FlowKey(string key) =>
        Regex.IsMatch(key, @"^[A-Za-z0-9_\-]+$") ? key : "\"" + EscapeFlow(key) + "\"";

    private static string InlineFlow(YamlNode node)
    {
        switch (node)
        {
            case YamlScalarNode s:
            {
                var v = s.Value ?? "";
                if (v.Length == 0) return "\"\"";
                // 纯数字/布尔保持原样（mihomo 期待 int/bool），其余一律加引号防歧义
                if (Regex.IsMatch(v, @"^-?[0-9]+(\.[0-9]+)?$") || v is "true" or "false" or "null") return v;
                return "\"" + EscapeFlow(v) + "\"";
            }
            case YamlMappingNode m:
                return "{" + string.Join(", ", m.Children.Select(c => FlowKey(Key(c)) + ": " + InlineFlow(c.Value))) + "}";
            case YamlSequenceNode seq:
                return "[" + string.Join(", ", seq.Children.Select(InlineFlow)) + "]";
            default:
                return "";
        }
    }

    private static string EscapeFlow(string v) => v.Replace("\\", "\\\\").Replace("\"", "\\\"")
        .Replace("\n", "\\n").Replace("\r", "\\r").Replace("\t", "\\t");

    private static string Key(KeyValuePair<YamlNode, YamlNode> child) => (child.Key as YamlScalarNode)?.Value ?? "";

    private static string Val(YamlMappingNode map, string key)
    {
        var child = map.Children.FirstOrDefault(c => Key(c) == key).Value;
        return child == null ? "" : Val(child);
    }

    private static string Val(YamlNode node)
    {
        if (node is not YamlScalarNode s) return "";
        var v = s.Value ?? "";
        // 裸 null / ~ 是 YAML 的空值，不能当成字符串 "null"
        if ((v == "null" || v == "~" || v == "Null" || v == "NULL") && s.Style == YamlDotNet.Core.ScalarStyle.Plain) return "";
        return v;
    }
}
