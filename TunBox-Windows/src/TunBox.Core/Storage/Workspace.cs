using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using TunBox.Core.Config;
using TunBox.Core.Geo;
using TunBox.Core.Models;

namespace TunBox.Core.Storage;

public sealed class NodeLibrary
{
    // 集合属性必须带 setter：System.Text.Json 能写出「只读集合」，读回来却是空的（它不会往只读属性里 Add）。
    // 少一个 set 就等于「存得进去、重启就没了」——订阅与节点全部消失，正是「装新版数据被清空」的真身。
    public List<ProxyNode> Nodes { get; set; } = new();
    public List<ProxyGroup> Groups { get; set; } = new();
    public List<Subscription> Subscriptions { get; set; } = new();

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

    /// <summary>读写共用这一套参数；外面（测试、诊断）要解析同一份文件时也走这里。</summary>
    public static T? Deserialize<T>(string json) => JsonSerializer.Deserialize<T>(json, Json);

    public static string Serialize<T>(T value) => JsonSerializer.Serialize(value, Json);

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
        var s = ReadJson<AppSettings>(SettingsPath);
        if (s != null)
        {
            if (string.IsNullOrEmpty(s.ApiSecret)) s.ApiSecret = NewSecret();
            return s;
        }
        var fresh = new AppSettings { ApiSecret = NewSecret() };
        SaveSettings(fresh);
        return fresh;
    }

    /// <summary>落盘失败不能让应用起不来：只读配置、杀软拦截都走到这里，设置在内存里仍是好的。</summary>
    public bool SaveSettings(AppSettings s) => WriteAtomic(SettingsPath, JsonSerializer.Serialize(s, Json));

    public NodeLibrary LoadNodes() => ReadJson<NodeLibrary>(NodesPath) ?? new NodeLibrary();

    public bool SaveNodes(NodeLibrary lib) => WriteAtomic(NodesPath, JsonSerializer.Serialize(lib, Json));

    /// <summary>
    /// 读主文件，坏了再读上一次存盘的好副本。
    /// 直接覆盖写会在「写一半进程被杀」（升级安装、注销、断电）时留下半截 JSON，
    /// 那时若无条件回落默认值，下一次保存就把用户的数据冲掉了 —— 表现为「装新版数据被清空」。
    /// 损坏的原文件改名留档，不删。
    /// </summary>
    private static T? ReadJson<T>(string path) where T : class
    {
        try
        {
            if (File.Exists(path))
            {
                var main = JsonSerializer.Deserialize<T>(File.ReadAllText(path), Json);
                if (main != null) return main;
            }
        }
        catch
        {
            Quarantine(path);
        }
        try
        {
            if (File.Exists(path + ".bak"))
                return JsonSerializer.Deserialize<T>(File.ReadAllText(path + ".bak"), Json);
        }
        catch { /* 备份也坏了就回落默认值 */ }
        return null;
    }

    private static void Quarantine(string path)
    {
        try
        {
            var bad = $"{path}.bad-{DateTime.Now:yyyyMMdd-HHmmss}";
            File.Move(path, bad, overwrite: true);
        }
        catch { /* 留档失败也不能挡住启动 */ }
    }

    /// <summary>先写临时文件，备份旧副本，再原子替换；任何一步失败都不会让主文件变成半截。</summary>
    private static bool WriteAtomic(string path, string json)
    {
        var tmp = path + ".tmp";
        try
        {
            File.WriteAllText(tmp, json);
            if (File.Exists(path)) File.Copy(path, path + ".bak", overwrite: true);
            File.Move(tmp, path, overwrite: true);
            return true;
        }
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
