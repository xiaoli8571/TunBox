using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using TunBox.Core.Config;
using TunBox.Core.Geo;
using TunBox.Core.Models;

namespace TunBox.Core.Storage;

public sealed class NodeLibrary
{
    public List<ProxyNode> Nodes { get; } = new();
    public List<ProxyGroup> Groups { get; } = new();
    public List<Subscription> Subscriptions { get; } = new();

    [JsonIgnore]
    public static NodeLibrary Empty => new();
}

/// <summary>本地工作区：设置、节点库、内核 home 目录，全部落在 %APPDATA%\TunBox。</summary>
public sealed class Workspace
{
    public string HomeDir { get; }
    public string RuntimeDir { get; }
    private string SettingsPath => Path.Combine(HomeDir, "settings.json");
    private string NodesPath => Path.Combine(HomeDir, "nodes.json");
    private GeoAssetStore? _geo;

    /// <summary>分流库状态。内核 home 就是 RuntimeDir；门禁必须认这里的路径。</summary>
    public GeoAssetStore GeoAssets => _geo ??= new GeoAssetStore(RuntimeDir);

    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public Workspace() : this(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "TunBox")) { }

    public Workspace(string home)
    {
        HomeDir = home;
        RuntimeDir = Path.Combine(home, "runtime");
        Directory.CreateDirectory(home);
        Directory.CreateDirectory(RuntimeDir);
    }

    public AppSettings LoadSettings()
    {
        try
        {
            if (File.Exists(SettingsPath))
            {
                var s = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath), Json);
                if (s != null)
                {
                    if (string.IsNullOrEmpty(s.ApiSecret)) s.ApiSecret = NewSecret();
                    return s;
                }
            }
        }
        catch { /* 设置损坏不能阻止启动：回落默认值，保留原文件供排查 */ }
        var fresh = new AppSettings { ApiSecret = NewSecret() };
        SaveSettings(fresh);
        return fresh;
    }

    /// <summary>落盘失败不能让应用起不来：只读配置、杀软拦截都走到这里，设置在内存里仍是好的。</summary>
    public bool SaveSettings(AppSettings s)
    {
        try { File.WriteAllText(SettingsPath, JsonSerializer.Serialize(s, Json)); return true; }
        catch { return false; }
    }

    public NodeLibrary LoadNodes()
    {
        try
        {
            if (File.Exists(NodesPath))
                return JsonSerializer.Deserialize<NodeLibrary>(File.ReadAllText(NodesPath), Json) ?? new NodeLibrary();
        }
        catch { /* 同上 */ }
        return new NodeLibrary();
    }

    public bool SaveNodes(NodeLibrary lib)
    {
        try { File.WriteAllText(NodesPath, JsonSerializer.Serialize(lib, Json)); return true; }
        catch { return false; }
    }

    /// <summary>
    /// 门禁：geoip / 去广告 / smart 模型是否就绪。缺文件还声明的话内核会同步联网下载。
    /// 路径口径必须与内核一致：geoip 认 -d 目录（= RuntimeDir）下的三个文件名之一，
    /// rule-providers 的 ./ruleset 相对 -d 解析。
    /// </summary>
    public ClashConfigGenerator.FeatureGate DetectGates() => new(
        GeoAssets.GeoIpReady,
        GeoAssets.AdRulesReady,
        File.Exists(Path.Combine(RuntimeDir, "Model.bin")) || File.Exists(Path.Combine(HomeDir, "Model.bin")));

    /// <summary>把随程序发布的 Model.bin 放进内核 home：缺它 smart 组会在启动路径同步去 GitHub 下载。</summary>
    public bool EnsureSmartModelInPlace()
    {
        var target = Path.Combine(RuntimeDir, "Model.bin");
        if (File.Exists(target)) return true;
        var source = new[]
        {
            Path.Combine(AppContext.BaseDirectory, "core", "Model.bin"),
            Path.Combine(AppContext.BaseDirectory, "Model.bin"),
        }.FirstOrDefault(File.Exists);
        if (source == null) return false;
        try { File.Copy(source, target, overwrite: true); return true; }
        catch { return false; }
    }

    private static string NewSecret()
    {
        var bytes = RandomNumberGenerator.GetBytes(16);
        return Convert.ToHexString(bytes).ToLowerInvariant();
    }
}
