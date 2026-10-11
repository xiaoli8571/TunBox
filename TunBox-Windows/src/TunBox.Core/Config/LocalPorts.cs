using System.Net;
using System.Net.Sockets;
using TunBox.Core.Models;

namespace TunBox.Core.Config;

/// <summary>本地监听端口的校验与占用预检：端口被占时内核只打一行日志就退出，
/// 客户端却要等满启动预算才报「控制器未就绪」——必须动手前拦住。</summary>
public static class LocalPorts
{
    public const int Min = 1024;
    public const int Max = 65535;

    /// <summary>返回空串表示没问题，否则是给用户看的一句话。</summary>
    public static string Validate(AppSettings s)
    {
        foreach (var (label, port, optional) in new[]
                 {
                     ("混合端口", s.MixedPort, true),
                     ("HTTP 端口", s.HttpPort, true),
                     ("SOCKS 端口", s.SocksPort, true),
                     ("API 端口", s.ApiPort, false),
                 })
        {
            if (port == 0 && optional) continue;
            if (port is < Min or > Max)
                return optional
                    ? $"{label}要么填 0（不监听），要么落在 {Min}-{Max} 之间"
                    : $"{label}要落在 {Min}-{Max} 之间";
        }

        var enabled = new List<(string Label, int Port)>();
        if (s.MixedPort > 0) enabled.Add(("混合端口", s.MixedPort));
        if (s.HttpPort > 0) enabled.Add(("HTTP 端口", s.HttpPort));
        if (s.SocksPort > 0) enabled.Add(("SOCKS 端口", s.SocksPort));
        enabled.Add(("API 端口", s.ApiPort));
        var clash = enabled.GroupBy(x => x.Port).FirstOrDefault(g => g.Count() > 1);
        if (clash != null)
            return $"{string.Join(" 和 ", clash.Select(x => x.Label))}都是 {clash.Key}，同一端口只能有一个监听者";

        if (s.SystemProxyEnabled && s.SystemProxyPort() == 0)
            return "系统代理需要一个可用端口：请把混合端口（或 HTTP 端口）设为非 0";

        return "";
    }

    /// <summary>绑不上且是「地址已被使用」才判定占用；其他失败放行——预检只是提前报错。</summary>
    public static bool Available(int port)
    {
        if (port <= 0) return true;
        try
        {
            using var probe = new TcpListener(IPAddress.Loopback, port);
            probe.Start();
            return true;
        }
        catch (SocketException e) when (e.SocketErrorCode == SocketError.AddressAlreadyInUse)
        {
            return false;
        }
        catch { return true; }
    }

    public static int FirstOccupied(AppSettings s)
    {
        foreach (var port in new[] { s.MixedPort, s.HttpPort, s.SocksPort, s.ApiPort })
            if (port > 0 && !Available(port)) return port;
        return 0;
    }
}
