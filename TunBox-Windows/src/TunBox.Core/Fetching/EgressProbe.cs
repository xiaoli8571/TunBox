using System.Text.Json;
using System.Text.Json.Nodes;

namespace TunBox.Core.Fetching;

/// <summary>一次出口信息查询的结果。全空 = 还没查过。</summary>
public readonly record struct EgressSnapshot(
    string EgressIp, string Location, string Carrier, string Asn,
    string LocalIp, bool Connected, string? Error, DateTime At)
{
    public static readonly EgressSnapshot Empty = new("", "", "", "", "", false, null, DateTime.MinValue);

    public bool HasEgress => EgressIp.Length > 0;
    public bool HasLocal => LocalIp.Length > 0;

    /// <summary>出口和本机同一个 IP，就是「压根没走代理」—— 这正是这张卡最有用的时候。</summary>
    public bool SameAsLocal => HasEgress && HasLocal && string.Equals(EgressIp, LocalIp, StringComparison.OrdinalIgnoreCase);

    public string LocationText => Location.Length > 0 ? Location : "位置未知";
    public string CarrierText => Carrier.Length > 0 ? Carrier : (Asn.Length > 0 ? Asn : "运营商未知");
}

/// <summary>
/// 查出口 IP 与归属地：走内核的混合端口发一次 HTTP 请求，查回来的就是流量真实的出站地址
/// （对齐 Clash Verge / FlClash 的「出口信息」）。用 ip-api.com：免 key、支持中文、一次给齐
/// IP / 国家 / 城市 / 运营商 / ASN。
/// </summary>
public static class EgressProbe
{
    /// <summary>字段与 lang 都在这里：ip-api 免费端点走 http，HTTPS 版要付费。</summary>
    public const string Endpoint =
        "http://ip-api.com/json/?lang=zh-CN&fields=status,message,query,country,regionName,city,isp,org,as";

    private static readonly HttpClient Direct = New(null);

    /// <summary>解析 ip-api 的响应。status 不是 success 时把它的 message 当成错误带回去。</summary>
    public static EgressSnapshot Parse(string json, bool connected, string? localIp, string? error)
    {
        string Str(string key) =>
            JsonNode.Parse(json)?[key]?.GetValue<string>() ?? "";
        try
        {
            if (!string.IsNullOrEmpty(error))
                return new EgressSnapshot("", "", "", "", localIp ?? "", connected, error, DateTime.Now);

            var status = Str("status");
            if (!string.Equals(status, "success", StringComparison.OrdinalIgnoreCase))
                return new EgressSnapshot("", "", "", "", localIp ?? "", connected,
                    Str("message").Length > 0 ? Str("message") : "查询没返回结果", DateTime.Now);

            var place = new[] { Str("country"), Str("regionName"), Str("city") }
                .Where(s => s.Length > 0)
                // ip-api 中文版里国家与城市常重复出现，去重后拼起来更短更好读
                .Distinct(StringComparer.Ordinal);
            return new EgressSnapshot(Str("query"), string.Join(" · ", place), Str("isp"), Str("as"),
                localIp ?? "", connected, null, DateTime.Now);
        }
        catch (JsonException)
        {
            // 运营商面板/认证门户劫持 DNS 时会返回一个 HTML 登录页：说清现象，别只报解析失败
            var head = json.TrimStart().Length > 40 ? json.TrimStart()[..40] : json.TrimStart();
            return new EgressSnapshot("", "", "", "", localIp ?? "", connected,
                "接口没返回 JSON（被网络劫持了？）：" + head, DateTime.Now);
        }
    }

    /// <summary>取一次 JSON。proxy 为空就是直连（查本机真实出口）。</summary>
    public static async Task<string> FetchJsonAsync(Uri? proxy, CancellationToken ct)
    {
        using var http = New(proxy);
        return await http.GetStringAsync(Endpoint, ct).ConfigureAwait(false);
    }

    public static Task<string> FetchDirectAsync(CancellationToken ct) => FetchJsonAsync(null, ct);

    /// <summary>出口查询：把混合端口当 HTTP 代理用；端口为 0（没开 HTTP 入口）就查不到，直说。</summary>
    public static Task<string> FetchViaProxyAsync(int port, CancellationToken ct) =>
        port <= 0
            ? Task.FromException<string>(new InvalidOperationException("代理端口还没开，先点连接。"))
            : FetchJsonAsync(new Uri($"http://127.0.0.1:{port}"), ct);

    private static HttpClient New(Uri? proxy)
    {
        var handler = new HttpClientHandler();
        if (proxy != null)
        {
            handler.Proxy = new System.Net.WebProxy(proxy);
            handler.UseProxy = true;
        }
        else
        {
            // 直连这一路必须绕开系统代理：否则「本机 IP」查出来的其实是出口 IP，两者一比一等零
            handler.UseProxy = false;
        }
        return new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(10) };
    }

    /// <summary>本机真实出口（直连查）。用独立的 HttpClient，避免连接池复用把代理那一轮的结果串过来。</summary>
    public static Task<string> FetchLocalAsync(CancellationToken ct) => Direct.GetStringAsync(Endpoint, ct);
}
