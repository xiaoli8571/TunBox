using System.Net;
using System.Net.Http.Headers;
using System.Text;
using TunBox.Core.Models;

namespace TunBox.Core.Fetching;

/// <summary>
/// 订阅拉取。核心经验（来自 Clash Verge / v2rayN / FlClash 与真机踩坑）：
/// 面板普遍按 User-Agent 做**内容协商**——同一个 URL，UA 是已知客户端时返回 YAML，
/// 不认识时可能返回一段提示文字甚至登录页。所以这里沿 UA 链逐个试，拿到非空、
/// 非网页的正文为止；全都失败时把最后一个正文的前 2KB 端给用户，让他自己看见
/// 「面板说了什么」，而不是一句没头没尾的「解析失败」。
/// </summary>
public static class SubscriptionFetcher
{
    /// <summary>与主流客户端同款 UA 链：机场面板只认它们认识的客户端。</summary>
    public static readonly string[] UaChain =
    {
        "clash-verge/v1.7.7",
        "clash.meta/v1.18.8",
        "TunBox/" + AppVersion,
        "v2rayN/6.23",
        "Shadowrocket/2077",
    };

    public const string AppVersion = "0.4.0";

    public sealed record FetchResult(
        string Body, string UsedUa, bool NotModified,
        long UploadBytes, long DownloadBytes, long TotalBytes, long ExpireAtMs,
        int UpdateIntervalMinutes, string Etag);

    public static async Task<FetchResult> FetchAsync(string url, string? customUa, string etag, CancellationToken ct = default)
    {
        var attempts = new List<string>();
        string? lastBody = null;
        string? lastUa = null;
        var sawRateLimit = 0;

        var chain = string.IsNullOrWhiteSpace(customUa) ? UaChain : new[] { customUa.Trim() };
        foreach (var ua in chain)
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(20));
            try
            {
                var (status, headers, body) = await RequestOnceAsync(url, ua, etag, cts.Token).ConfigureAwait(false);
                if (status == HttpStatusCode.NotModified)
                    return new FetchResult("", ua, NotModified: true, 0, 0, 0, 0, 0, ReadEtag(headers));
                if (!IsSuccess(status))
                {
                    if (status is HttpStatusCode.Forbidden or HttpStatusCode.TooManyRequests) sawRateLimit = (int)status;
                    attempts.Add($"{ua} → HTTP {(int)status}");
                    continue;
                }
                if (body.Length == 0)
                {
                    attempts.Add($"{ua} → 空响应");
                    continue;
                }
                if (LooksLikeWebPage(body))
                {
                    lastBody = body;
                    lastUa = ua;
                    attempts.Add($"{ua} → 返回的是网页/提示文字而不是订阅");
                    continue;   // 换一个 UA 再试：很多面板只对认识的客户端给 YAML
                }
                var info = ParseUserInfo(headers);
                return new FetchResult(body, ua, false, info.Upload, info.Download, info.Total, info.ExpireAtMs,
                    info.IntervalMinutes, ReadEtag(headers));
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception e) when (IsTlsError(e))
            {
                // 自签证书的机场面板很常见：标准校验失败放宽重试一次，让用户自己决定要不要用这个地址。
                try
                {
                    var (status, headers, body) = await RequestOnceAsync(url, ua, etag, cts.Token, acceptAnyCert: true).ConfigureAwait(false);
                    if (IsSuccess(status) && body.Length > 0 && !LooksLikeWebPage(body))
                    {
                        var info = ParseUserInfo(headers);
                        return new FetchResult(body, ua, false, info.Upload, info.Download, info.Total,
                            info.ExpireAtMs, info.IntervalMinutes, ReadEtag(headers));
                    }
                    attempts.Add($"{ua} → TLS 校验失败，放宽后返回 HTTP {(int)status}");
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                catch (Exception e2) { attempts.Add($"{ua} → {e2.Message}"); }
            }
            catch (Exception e)
            {
                attempts.Add($"{ua} → {e.Message}");
            }
        }

        var preview = lastBody is { Length: > 0 } b
            ? "面板返回的正文开头是：\n" + b[..Math.Min(b.Length, 2000)]
            : "";
        var reason = sawRateLimit > 0
            ? $"面板拒绝了这次请求（HTTP {sawRateLimit}，限流或禁止访问），过一会再试。"
            : "所有客户端 UA 都没拿到可用的订阅内容。很多面板只对已知客户端（Clash Verge / mihomo）返回订阅，" +
              "如果面板提供了「订阅转换」地址请使用它，或在订阅设置里填自定义 User-Agent。";
        throw new InvalidOperationException(reason + (attempts.Count > 0 ? "\n尝试记录：" + string.Join("；", attempts) : "") + preview);
    }

    private static bool IsSuccess(HttpStatusCode status) => (int)status is >= 200 and < 300;

    /// <summary>网页/提示文字判定：以 < 或 { 开头且带 html 标记的都是给人看的，不是订阅。</summary>
    public static bool LooksLikeWebPage(string body)
    {
        var head = body.TrimStart('\ufeff', ' ', '\t', '\r', '\n');
        if (head.StartsWith('<')) return true;
        if (head.StartsWith('{') && head.Contains("\"error\"", StringComparison.OrdinalIgnoreCase)) return true;
        return head.Contains("<html", StringComparison.OrdinalIgnoreCase)
            || head.Contains("<!DOCTYPE", StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsTlsError(Exception e)
    {
        for (var cur = (Exception?)e; cur != null; cur = cur.InnerException)
            if (cur is System.Security.Authentication.AuthenticationException
                or System.Security.Cryptography.CryptographicException) return true;
        var text = e.Message.ToLowerInvariant();
        return text.Contains("ssl") || text.Contains("tls") || text.Contains("certificate");
    }

    private static async Task<(HttpStatusCode Status, HttpResponseHeaders? Headers, string Body)>
        RequestOnceAsync(string url, string ua, string etag, CancellationToken ct, bool acceptAnyCert = false)
    {
        // 拉订阅绝不能走自己刚开的系统代理（那等于让代理服务器拉它自己的订阅）。
        using var handler = new HttpClientHandler
        {
            UseProxy = false,
            AllowAutoRedirect = true,
            ServerCertificateCustomValidationCallback = acceptAnyCert
                ? HttpClientHandler.DangerousAcceptAnyServerCertificateValidator
                : null,
        };
        using var http = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        http.DefaultRequestHeaders.UserAgent.ParseAdd(ua);
        http.DefaultRequestHeaders.Accept.ParseAdd("*/*");
        if (etag.Length > 0) http.DefaultRequestHeaders.TryAddWithoutValidation("If-None-Match", etag);

        using var resp = await http.GetAsync(url, HttpCompletionOption.ResponseContentRead, ct).ConfigureAwait(false);
        var bytes = await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
        return (resp.StatusCode, resp.Headers, Encoding.UTF8.GetString(bytes));
    }

    /// <summary>subscription-userinfo：upload=1, download=2, total=1024, expire=1700000000（秒）。</summary>
    internal static (long Upload, long Download, long Total, long ExpireAtMs, int IntervalMinutes)
        ParseUserInfo(HttpResponseHeaders? headers)
    {
        if (headers == null) return (0, 0, 0, 0, 0);
        string? userinfo = null, interval = null;
        foreach (var h in headers)
        {
            var name = h.Key.ToLowerInvariant();
            if (name.EndsWith("subscription-userinfo")) userinfo = string.Join(",", h.Value);
            else if (name.EndsWith("profile-update-interval")) interval = string.Join(",", h.Value);
        }
        long upload = 0, download = 0, total = 0, expire = 0;
        if (userinfo != null)
        {
            // 面板两种分隔符都有：逗号（标准示例）与分号（大多数面板实际输出）
            foreach (var part in userinfo.Split(new[] { ',', ';' }, StringSplitOptions.RemoveEmptyEntries))
            {
                var eq = part.IndexOf('=');
                if (eq < 0) continue;
                var k = part[..eq].Trim().ToLowerInvariant();
                _ = long.TryParse(part[(eq + 1)..].Trim(), out var v);
                if (k == "upload") upload = v;
                else if (k == "download") download = v;
                else if (k == "total") total = v;
                else if (k == "expire" && v > 0) expire = v * 1000;
            }
        }
        _ = int.TryParse(interval, out var minutes);
        return (upload, download, total, expire, minutes > 0 ? minutes * 60 : 0);
    }

    private static string ReadEtag(HttpResponseHeaders? headers)
    {
        if (headers == null) return "";
        if (headers.ETag != null) return headers.ETag.Tag;
        foreach (var h in headers)
            if (h.Key.Equals("ETag", StringComparison.OrdinalIgnoreCase))
                return string.Join(",", h.Value);
        return "";
    }
}
