using System.Text;
using TunBox.Core.Config;
using TunBox.Core.Models;

namespace TunBox.Core.Geo;

public enum GeoAssetState { Missing, Downloading, Ready, Failed, SwappedLater }

/// <summary>一个分流数据文件的落地情况，界面上「分流库」那一行直接显示它。</summary>
public sealed class GeoAssetStatus
{
    public required string Key { get; init; }
    public required string Title { get; init; }
    public GeoAssetState State { get; set; } = GeoAssetState.Missing;
    public string Detail { get; set; } = "还没下载";
    public long Bytes { get; set; }
    public DateTimeOffset? UpdatedAt { get; set; }
    public string Path { get; set; } = "";
}

/// <summary>
/// 分流数据文件（geoip.metadb / 去广告 mrs）的后台落地。
/// 为什么必须客户端先下好再声明规则：实测缺库时内核在 config.Parse 阶段**同步**下载
/// （"Can't find MMDB, start download"），国内不可达就是「点了连接一直转圈」；
/// 库坏它还会删掉重下一遍。所以配置按「文件是否就绪」决定是否发射（FeatureGate），
/// 下载放这里异步做，下成了再热重载。
/// </summary>
public sealed class GeoAssetStore
{
    public const string GeoIpKey = "geoip";
    public const string AdRulesKey = "adrules";
    public const string GeoIpFileName = "geoip.metadb";
    public const string AdRulesRelativePath = "ruleset/hyper_adrules_ads.mrs";

    /// <summary>mrs 是 zstd 容器（实测 HyperADRules release 资产首 4 字节）。</summary>
    private static readonly byte[] ZstdMagic = { 0x28, 0xB5, 0x2F, 0xFD };

    private sealed record Definition(
        string Key, string Title, string RelativePath, int MinBytes, int MaxAgeDays, string[] Urls, string PendingHint);

    private static readonly Definition[] Definitions =
    {
        new(GeoIpKey, "IP 分流库", GeoIpFileName, 512 * 1024, 7,
            new[]
            {
                "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb",
                "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb",
                "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb",
            },
            "没有它智能模式认不出国内地址，B 站、微信、网盘这些都会绕道代理。"),
        new(AdRulesKey, "去广告规则集", AdRulesRelativePath, 64 * 1024, 1,
            new[] { "https://github.com/Lynricsy/HyperADRules/releases/latest/download/hyper_adrules_ads.mrs" },
            "去广告开关打开后需要它才真正拦广告域名。"),
    };

    private readonly string _homeDir;
    private readonly Dictionary<string, GeoAssetStatus> _status = new(StringComparer.Ordinal);
    private readonly Dictionary<string, SemaphoreSlim> _locks = new(StringComparer.Ordinal);

    public event Action? Changed;

    /// <summary>返回 http://127.0.0.1:port 表示「现在可以走本机代理下载」，null 表示直连。</summary>
    public Func<string?>? ProxyProvider { get; set; }

    /// <summary>测试注入：绕开真网络验「半截下载绝不能落盘」这条。</summary>
    internal Func<string, CancellationToken, Task<byte[]>>? Fetcher { get; set; }

    /// <summary>去广告开关关掉时不下载那个 mrs。</summary>
    public bool AdRulesWanted { get; set; }

    public GeoAssetStore(string kernelHomeDir)
    {
        _homeDir = kernelHomeDir;
        foreach (var d in Definitions)
        {
            _status[d.Key] = new GeoAssetStatus { Key = d.Key, Title = d.Title, Path = Absolute(d) };
            _locks[d.Key] = new SemaphoreSlim(1, 1);
        }
        foreach (var d in Definitions) Scan(d);
    }

    public GeoAssetStatus StatusOf(string key) => _status[key];

    public IReadOnlyList<GeoAssetStatus> Statuses
    {
        get { var l = new List<GeoAssetStatus>(Definitions.Length); foreach (var d in Definitions) l.Add(StatusOf(d.Key)); return l; }
    }

    public bool GeoIpReady => IsReadyOnDisk(GeoIpKey);
    public bool AdRulesReady => IsReadyOnDisk(AdRulesKey);

    private string Absolute(Definition d) =>
        Path.Combine(_homeDir, d.RelativePath.Replace('/', Path.DirectorySeparatorChar));

    private static Definition Def(string key) => Definitions.First(d => d.Key == key);

    /// <summary>只看大小 + mrs 的 zstd 头。库内容是否合法交给内核的加载器判，客户端不复刻它。</summary>
    private bool IsReadyOnDisk(string key)
    {
        var d = Def(key);
        try
        {
            var path = Absolute(d);
            if (!File.Exists(path)) return false;
            var info = new FileInfo(path);
            if (info.Length < d.MinBytes) return false;
            if (d.Key == AdRulesKey && !ZstdHead(path)) return false;
            return info.LastWriteTimeUtc > DateTimeOffset.UtcNow.AddDays(-d.MaxAgeDays);
        }
        catch { return false; }
    }

    private static bool ZstdHead(string path)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            Span<byte> head = stackalloc byte[4];
            fs.ReadExactly(head);
            return head.SequenceEqual(ZstdMagic);
        }
        catch { return false; }
    }

    private void Scan(Definition d)
    {
        var s = StatusOf(d.Key);
        try
        {
            var path = Absolute(d);
            if (!File.Exists(path))
            {
                s.State = GeoAssetState.Missing;
                s.Detail = d.PendingHint;
                s.Bytes = 0;
                s.UpdatedAt = null;
                return;
            }
            var info = new FileInfo(path);
            s.Bytes = info.Length;
            s.UpdatedAt = info.LastWriteTimeUtc;
            if (info.Length < d.MinBytes || (d.Key == AdRulesKey && !ZstdHead(path)))
            {
                s.State = GeoAssetState.Failed;
                s.Detail = $"文件在，但内容不完整（{info.Length} 字节），会重新下载";
                return;
            }
            s.State = GeoAssetState.Ready;
            s.Detail = $"{Size(info.Length)} · {info.LastWriteTime.ToLocalTime():yyyy-MM-dd HH:mm}";
        }
        catch (Exception e)
        {
            s.State = GeoAssetState.Failed;
            s.Detail = "读不到这个文件：" + e.Message;
        }
    }

    /// <summary>重读磁盘现状：库可能是被内核自己的 geo-auto-update 更新过的。</summary>
    public void Rescan()
    {
        foreach (var d in Definitions) Scan(d);
        Changed?.Invoke();
    }

    public async Task<bool> EnsureAllAsync(CancellationToken ct = default)
    {
        var landed = false;
        foreach (var d in Definitions)
        {
            if (d.Key == AdRulesKey && !AdRulesWanted) continue;
            if (await EnsureAsync(d.Key, force: false, ct).ConfigureAwait(false)) landed = true;
        }
        return landed;
    }

    public async Task<bool> RefreshAllAsync(CancellationToken ct = default)
    {
        var landed = false;
        foreach (var d in Definitions)
        {
            if (d.Key == AdRulesKey && !AdRulesWanted) continue;
            if (await EnsureAsync(d.Key, force: true, ct).ConfigureAwait(false)) landed = true;
        }
        return landed;
    }

    public async Task<bool> EnsureAsync(string key, bool force, CancellationToken ct = default)
    {
        var d = Def(key);
        var gate = _locks[key];
        if (!await gate.WaitAsync(TimeSpan.FromMinutes(5), ct).ConfigureAwait(false)) return false;
        try
        {
            var path = Absolute(d);
            var fresh = File.Exists(path) && new FileInfo(path).Length >= d.MinBytes
                && new FileInfo(path).LastWriteTimeUtc > DateTimeOffset.UtcNow.AddDays(-d.MaxAgeDays)
                && (d.Key != AdRulesKey || ZstdHead(path));
            if (fresh && !force) { Scan(d); return false; }

            SetState(d, GeoAssetState.Downloading, force ? "正在更新…" : "正在下载…");

            byte[]? data = null;
            string? lastError = null;
            foreach (var url in d.Urls)
            {
                ct.ThrowIfCancellationRequested();
                try
                {
                    var bytes = Fetcher != null
                        ? await Fetcher(url, ct).ConfigureAwait(false)
                        : await DownloadAsync(url, ct).ConfigureAwait(false);
                    if (LooksLikeWebPage(bytes))
                    {
                        lastError = Host(url) + " 返回的是网页而不是数据文件（多半被网关拦了）";
                        continue;
                    }
                    if (bytes.Length < d.MinBytes || (d.Key == AdRulesKey && !IsZstd(bytes)))
                    {
                        lastError = Host(url) + $" 拿回来的内容不是有效的{d.Title}（{bytes.Length} 字节）";
                        continue;
                    }
                    data = bytes;
                    break;
                }
                catch (OperationCanceledException) { throw; }
                catch (Exception e) { lastError = Host(url) + "：" + e.Message; }
            }

            if (data == null)
            {
                SetState(d, GeoAssetState.Failed, "下载失败：" + (lastError ?? "所有地址都没连上")
                    + "。可以开着代理再点一次「更新分流库」。");
                return false;
            }
            return Write(d, data);
        }
        finally { gate.Release(); }
    }

    /// <summary>内核把 mmdb 映射在内存里，运行中换不掉同一个文件时写 .new，下次启动前替换。</summary>
    private bool Write(Definition d, byte[] data)
    {
        var path = Absolute(d);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temp = path + ".part";
            File.WriteAllBytes(temp, data);
            try
            {
                File.Move(temp, path, overwrite: true);
                Scan(d);
                if (StatusOf(d.Key).State == GeoAssetState.Ready)
                    SetState(d, GeoAssetState.Ready, $"已更新 · {Size(data.Length)} · 已生效");
                return true;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                var staged = path + ".new";
                File.Move(temp, staged, overwrite: true);
                var s = StatusOf(d.Key);
                s.State = GeoAssetState.SwappedLater;
                s.Detail = $"新库已下载（{Size(data.Length)}），旧库还被内核占着，重启后立即替换";
                Changed?.Invoke();
                return true;
            }
        }
        catch (Exception e)
        {
            SetState(d, GeoAssetState.Failed, "写不进去：" + e.Message);
            return false;
        }
    }

    /// <summary>有没有「下载好了但换不掉」的库：调用方据此决定要不要先停内核再启动。</summary>
    public bool HasPendingSwap => Definitions.Any(d => File.Exists(Absolute(d) + ".new"));

    /// <summary>内核即将启动前调用：那一刻没人映射着库文件。</summary>
    public int ApplyPendingSwaps()
    {
        var swapped = 0;
        foreach (var d in Definitions)
        {
            var path = Absolute(d);
            var staged = path + ".new";
            try
            {
                if (!File.Exists(staged)) continue;
                File.Move(staged, path, overwrite: true);
                swapped++;
                Scan(d);
            }
            catch { /* 换不掉就继续用旧库，别挡住连接 */ }
        }
        if (swapped > 0) Changed?.Invoke();
        return swapped;
    }

    public static bool LooksLikeWebPage(byte[] data)
    {
        if (data.Length == 0) return true;
        var head = Encoding.UTF8.GetString(data, 0, Math.Min(data.Length, 512))
            .TrimStart('\ufeff', ' ', '\t', '\r', '\n');
        if (head.StartsWith('<') || head.Contains("<html", StringComparison.OrdinalIgnoreCase)
            || head.Contains("DOCTYPE", StringComparison.OrdinalIgnoreCase)) return true;
        return head.StartsWith('{') && head.Contains("error", StringComparison.OrdinalIgnoreCase);
    }

    public static bool IsZstd(byte[] data) =>
        data.Length >= ZstdMagic.Length && data.AsSpan(0, ZstdMagic.Length).SequenceEqual(ZstdMagic);

    public static bool FormatOk(string key, byte[] data) => key switch
    {
        GeoIpKey => data.Length > 0 && !LooksLikeWebPage(data),
        _ => IsZstd(data),
    };

    private static string Size(long bytes) => bytes switch
    {
        >= 1_048_576 => $"{bytes / 1_048_576.0:0.0} MB",
        >= 1024 => $"{bytes / 1024.0:0} KB",
        _ => bytes + " B",
    };

    private static string Host(string url)
    {
        try { return new Uri(url).Host; } catch { return url; }
    }

    private void SetState(Definition d, GeoAssetState state, string detail)
    {
        var s = StatusOf(d.Key);
        s.State = state;
        s.Detail = detail;
        try
        {
            if (File.Exists(Absolute(d)))
            {
                var info = new FileInfo(Absolute(d));
                s.Bytes = info.Length;
                s.UpdatedAt = info.LastWriteTimeUtc;
            }
        }
        catch { /* 状态文案比数字重要 */ }
        Changed?.Invoke();
    }

    private static async Task<byte[]> DownloadAsync(string url, CancellationToken ct)
    {
        using var handler = new HttpClientHandler { UseProxy = false, AllowAutoRedirect = true };
        using var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(180) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("TunBox/0.4 (Windows; geodata)");
        return await http.GetByteArrayAsync(url, ct).ConfigureAwait(false);
    }
}
