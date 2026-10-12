using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace TunBox.Core.Services;

/// <summary>
/// 检查更新：查 GitHub Release（仓库 xiaoli8571/TunBox）。
/// 从 v0.3.1 起两端共用一个 Release：Windows 安装包与鸿蒙 .app 挂在同一个 <c>v*</c> tag 下，
/// 所以标签同时认历史的 <c>windows-v*</c> 与统一的 <c>v*</c>，在列表里取版本号最大的那个。
/// 仍然不拿 /releases/latest 一把抓 —— 旧线（windows-v0.3.0）与统一线并存时只有精确
/// 匹配的 tag 才算数。网络路径：先直连 api.github.com；失败且本机混合端口在监听时，
/// 借自己的代理再试一次 —— 用户开着 TunBox 本来就是为了「能到 GitHub」。
/// </summary>
public sealed class UpdateChecker
{
    public const string Repo = "xiaoli8571/TunBox";

    public sealed record UpdateInfo(string Version, string Tag, string Url);

    /// <summary>"v0.3.1" / "windows-v0.3.1" → "0.3.1"；其余（beta 后缀、其他前缀）一律不认。</summary>
    public static string? ParseReleaseTag(string? tag)
    {
        if (string.IsNullOrWhiteSpace(tag)) return null;
        var m = Regex.Match(tag, @"^(?:windows-)?v(\d+\.\d+\.\d+)$");
        return m.Success ? m.Groups[1].Value : null;
    }

    /// <summary>严格大于才算新版本；当前版本读不出来时按「有新版」处理（宁可提示，不可漏报）。</summary>
    public static bool IsNewer(string current, string candidate)
    {
        if (!Version.TryParse(candidate, out var c)) return false;
        if (!Version.TryParse(current, out var cur)) return true;
        return c > cur;
    }

    /// <summary>
    /// 从一串 tag 里挑版本号最大的可识别项；全都不认识返回 null。
    /// 列表按创建时间倒序不可靠（两端交替发版时会插队），必须显式比大小。
    /// </summary>
    public static (string Tag, string Version)? PickLatest(IEnumerable<string?> tags)
    {
        string? bestTag = null, bestVer = null;
        foreach (var tag in tags)
        {
            var ver = ParseReleaseTag(tag);
            if (ver is null) continue;
            if (bestVer is null || Version.Parse(ver) > Version.Parse(bestVer))
            {
                bestTag = tag;
                bestVer = ver;
            }
        }
        return bestTag is null || bestVer is null ? null : (Tag: bestTag, Version: bestVer);
    }

    /// <summary>
    /// 返回 null = 已是最新；抛异常 = 两条网络路径都没走通（调用方把话落在设置页）。
    /// </summary>
    public async Task<UpdateInfo?> CheckAsync(string currentVersion, int proxyPort = 0, CancellationToken ct = default)
    {
        try
        {
            return await FetchAsync(currentVersion, proxy: null, ct).ConfigureAwait(false);
        }
        catch (Exception) when (proxyPort > 0 && !ct.IsCancellationRequested)
        {
            return await FetchAsync(currentVersion, new WebProxy($"http://127.0.0.1:{proxyPort}"), ct).ConfigureAwait(false);
        }
    }

    private static async Task<UpdateInfo?> FetchAsync(string currentVersion, WebProxy? proxy, CancellationToken ct)
    {
        var handler = new HttpClientHandler { UseProxy = proxy is not null };
        if (proxy is not null) handler.Proxy = proxy;
        using var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(8) };
        using var req = new HttpRequestMessage(HttpMethod.Get, $"https://api.github.com/repos/{Repo}/releases?per_page=15");
        req.Headers.UserAgent.ParseAdd("TunBox/update-check");
        req.Headers.Accept.ParseAdd("application/vnd.github+json");
        using var resp = await http.SendAsync(req, ct).ConfigureAwait(false);
        resp.EnsureSuccessStatusCode();
        await using var stream = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        using var doc = await JsonDocument.ParseAsync(stream, cancellationToken: ct);

        var tags = new List<string?>();
        var urls = new Dictionary<string, string>();
        foreach (var rel in doc.RootElement.EnumerateArray())
        {
            // 预发布版不推给正式用户
            if (rel.TryGetProperty("prerelease", out var pre) && pre.GetBoolean()) continue;
            var tag = rel.TryGetProperty("tag_name", out var t) ? t.GetString() : null;
            if (ParseReleaseTag(tag) is null) continue;
            tags.Add(tag);
            var pageUrl = rel.TryGetProperty("html_url", out var u) && u.GetString() is { Length: > 0 } s
                ? s : $"https://github.com/{Repo}/releases";
            urls[tag!] = pageUrl;
        }

        if (PickLatest(tags) is not { } best) return null;
        if (!IsNewer(currentVersion, best.Version)) return null;
        return new UpdateInfo(best.Version, best.Tag,
            urls.TryGetValue(best.Tag, out var url) ? url : $"https://github.com/{Repo}/releases");
    }
}
