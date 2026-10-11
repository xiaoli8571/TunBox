using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32;

namespace TunBox.Core.Runtime;

/// <summary>系统代理（WinINet）。写 HKCU 的 Internet Settings 再广播变更，不需要管理员。</summary>
public static class SystemProxy
{
    private const string KeyPath = @"Software\Microsoft\Windows\CurrentVersion\Internet Settings";
    private const uint INTERNET_OPTION_SETTINGS_CHANGED = 39;
    private const uint INTERNET_OPTION_REFRESH = 37;

    [DllImport("wininet.dll", SetLastError = true)]
    private static extern bool InternetSetOption(IntPtr hInternet, uint dwOption, IntPtr lpBuffer, uint dwBufferLength);

    private sealed record Backup(int? Enabled, string? Server, string? Override);

    private static string BackupFile => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "TunBox", "proxy-backup.json");

    public static bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(KeyPath);
        return key?.GetValue("ProxyEnable") as int? == 1;
    }

    /// <summary>把系统代理指向 127.0.0.1:port。已有第三方代理先备份，退出时原样还原。</summary>
    public static void Enable(int port)
    {
        var server = $"127.0.0.1:{port}";
        using (var key = Registry.CurrentUser.OpenSubKey(KeyPath, writable: true)
                       ?? Registry.CurrentUser.CreateSubKey(KeyPath))
        {
            if (!File.Exists(BackupFile))
            {
                var backup = new Backup(
                    key.GetValue("ProxyEnable") as int?,
                    key.GetValue("ProxyServer") as string,
                    key.GetValue("ProxyOverride") as string);
                Directory.CreateDirectory(Path.GetDirectoryName(BackupFile)!);
                File.WriteAllText(BackupFile, JsonSerializer.Serialize(backup));
            }
            key.SetValue("ProxyServer", server, RegistryValueKind.String);
            key.SetValue("ProxyEnable", 1, RegistryValueKind.DWord);
            // 局域网/回环不走代理，否则本机服务与打印机会被一起劫持掉。
            key.SetValue("ProxyOverride", "localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;"
                + "172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;"
                + "172.29.*;172.30.*;172.31.*;192.168.*;<local>", RegistryValueKind.String);
        }
        Refresh();
    }

    /// <summary>恢复启用前的设置。没有备份文件就什么都不做——那时进程没开过系统代理。</summary>
    public static void Disable()
    {
        Backup? backup = null;
        var hadBackup = false;
        try
        {
            if (File.Exists(BackupFile))
            {
                backup = JsonSerializer.Deserialize<Backup>(File.ReadAllText(BackupFile));
                File.Delete(BackupFile);
                hadBackup = true;
            }
        }
        catch { backup = null; }
        if (!hadBackup) return;

        using var key = Registry.CurrentUser.OpenSubKey(KeyPath, writable: true)
                        ?? Registry.CurrentUser.CreateSubKey(KeyPath);
        if (backup?.Server is { Length: > 0 } server)
        {
            key.SetValue("ProxyServer", server, RegistryValueKind.String);
            key.SetValue("ProxyEnable", backup.Enabled == 1 ? 1 : 0, RegistryValueKind.DWord);
            if (backup.Override != null) key.SetValue("ProxyOverride", backup.Override, RegistryValueKind.String);
        }
        else
        {
            key.SetValue("ProxyEnable", 0, RegistryValueKind.DWord);
        }
        Refresh();
    }

    /// <summary>启动时清理上次崩溃留下的系统代理。</summary>
    public static bool RestoreIfStale()
    {
        if (!File.Exists(BackupFile)) return false;
        Disable();
        return true;
    }

    private static void Refresh()
    {
        InternetSetOption(IntPtr.Zero, INTERNET_OPTION_SETTINGS_CHANGED, IntPtr.Zero, 0);
        InternetSetOption(IntPtr.Zero, INTERNET_OPTION_REFRESH, IntPtr.Zero, 0);
    }
}

/// <summary>TUN 的前置判断与虚拟网卡确认。内核建卡失败只打一行日志就静默关闭 TUN。</summary>
public static class Elevation
{
    public static bool IsAdmin
    {
        get
        {
            try
            {
                using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
                return new System.Security.Principal.WindowsPrincipal(identity)
                    .IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
            }
            catch { return false; }
        }
    }

    public static string TunBlocker()
    {
        if (Environment.OSVersion.Version.Major < 10) return "虚拟网卡模式需要 Windows 10 或更高版本。";
        if (!IsAdmin) return "虚拟网卡（TUN）需要管理员权限：创建网卡和改路由表都要提权。";
        return "";
    }
}

public static class TunAdapter
{
    public static bool Exists(string name)
    {
        try
        {
            return System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()
                .Any(n => string.Equals(n.Name, name, StringComparison.OrdinalIgnoreCase));
        }
        catch { return false; }
    }

    /// <summary>网卡可用 = 存在且 Up，或已拿到 fake-ip 段（198.18.0.0/16）里的地址。</summary>
    public static bool IsReady(string name)
    {
        try
        {
            var nic = System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()
                .FirstOrDefault(n => string.Equals(n.Name, name, StringComparison.OrdinalIgnoreCase));
            if (nic == null) return false;
            if (nic.OperationalStatus == System.Net.NetworkInformation.OperationalStatus.Up) return true;
            return nic.GetIPProperties().UnicastAddresses.Any(a =>
            {
                var b = a.Address.GetAddressBytes();
                return b.Length == 4 && b[0] == 198 && b[1] == 18;
            });
        }
        catch { return false; }
    }

    /// <summary>轮询等网卡就绪：驱动首次安装会慢于内核写完配置。100ms 一轮，别把 363ms 的事等成半秒。</summary>
    public static bool WaitFor(string name, TimeSpan budget, CancellationToken ct = default)
    {
        var deadline = DateTime.UtcNow + budget;
        while (true)
        {
            if (IsReady(name)) return true;
            if (DateTime.UtcNow >= deadline || ct.IsCancellationRequested) return false;
            Thread.Sleep(100);
        }
    }
}

/// <summary>开机自启：与安装器共用同一个 Run 键名与值名（有单测对照）。</summary>
public static class AutoStart
{
    public const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public const string RunValueName = "TunBox";

    public static string CommandLine(string exePath) => "\"" + exePath + "\" --minimized";

    /// <summary>当前有没有自启值。指向别处的旧值也算「有」，不然用户关不掉它。</summary>
    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(RunValueName) is string v && v.Contains("TunBox", StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    public static bool Set(bool on, string exePath)
    {
        try
        {
            if (on)
            {
                using var key = Registry.CurrentUser.CreateSubKey(RunKey);
                key.SetValue(RunValueName, CommandLine(exePath), RegistryValueKind.String);
                return true;
            }
            using (var probe = Registry.CurrentUser.OpenSubKey(RunKey))
                if (probe?.GetValue(RunValueName) == null) return true;
            using var writable = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            writable?.DeleteValue(RunValueName, throwOnMissingValue: false);
            return true;
        }
        catch { return false; }
    }
}
