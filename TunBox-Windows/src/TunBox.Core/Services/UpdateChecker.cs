using System;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace TunBox.Core.Services;

/// <summary>
/// 检查更新：查 GitHub Release（仓库 xiaoli8571/TunBox），只认 <c>windows-v</c> 前缀的 tag。
/// 仓库里鸿蒙端（v0.2.0 这类）与 Windows 端（windows-v0.3.1 这类）共用一个 Releases 列表，
/// 绝不能拿 /releases/latest 一把抓 —— 会抓到鸿蒙的 Release，版本号还不一定比 Windows 大。
/// 网络路径：先直连 api.github.com；失败且本机混合端口在监听时，借自己的代理再试一次 ——
/// 用户开着 TunBox 本来就是为了「能到 GitHub」。
/// </summary>
public sealed class UpdateChecker
{
    public const string Repo = "xiaoli8571/TunBox";

    public sealed record UpdateInfo(string Version, string Tag, string Url);

    /// <summary>"windows-v0.3.1" → "0.3.1"；鸿蒙端的 tag（windows- 前缀之外的）一律不认。</summary>
    public static string? ParseWindowsTag(string? tag)
    {
        if (string.IsNullOrWhiteSpace(tag)) return null;
        var m = Regex.Match(tag, @"^windows-v(\d+\.\d+\.\d+)$");
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
        using var doc = await JsonDocument.ParseAsync(stream, cancellationToken: ct).ConfigureAwait(false);

        foreach (var rel in doc.RootElement.EnumerateArray())
        {
            var tag = rel.TryGetProperty("tag_name", out var t) ? t.GetString() : null;
            var ver = ParseWindowsTag(tag);
            if (ver is null) continue;
            // 列表按时间倒序：第一个 windows-v 条目就是 Windows 线的最新版
            if (!IsNewer(currentVersion, ver)) return null;
            var url = rel.TryGetProperty("html_url", out var u) && u.GetString() is { Length: > 0 } s
                ? s
                : $"https://github.com/{Repo}/releases";
            return new UpdateInfo(ver, tag ?? $"windows-v{ver}", url);
        }
        return null;
    }
}
