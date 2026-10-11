using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using TunBox.App;
using TunBox.Core.Api;
using TunBox.Core.Fetching;
using TunBox.Core.Storage;
using Xunit;

namespace TunBox.Core.Tests;

/// <summary>
/// 端到端：把生成器产出的配置喂给**真内核进程**，以它自己打印的
/// "RESTful API listening at: 127.0.0.1:&lt;port&gt;" 为「配置被接受且已开始服务」的判据。
/// 为什么判据是 stdout 而不是 HTTP：受限环境里回环 HTTP 可能被拦，用 HTTP 当判据会把
/// 「环境限制」误报成「产品坏了」（CoreHost 的三重就绪判定正是为这条现实设计的）。
/// </summary>
public sealed class KernelE2ETests
{
    private static string? FindShipped(string fileName)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        for (var depth = 0; dir != null && depth < 8; depth++, dir = dir.Parent)
        {
            foreach (var candidate in new[]
                     {
                         Path.Combine(dir.FullName, "core", fileName),
                         Path.Combine(dir.FullName, "TunBox-Windows", "core", fileName),
                     })
                if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    private static int FreePort()
    {
        var l = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        l.Start();
        var p = ((System.Net.IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return p;
    }

    private static string FreshHome() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "TunBox", "e2e-" + Guid.NewGuid().ToString("N")[..6]);

    /// <summary>
    /// 把生成器产出的配置喂给真内核，以它自己打印的 API 监听行为「配置被接受」的判据。
    /// 任何 level=fatal 都当成失败并把原文带进断言消息——用户看到的「点了没反应」在这里最容易被抓住。
    /// </summary>
    private static async Task<(bool Listening, string Fatal, List<string> Lines)> RunKernelAsync(
        TunBox.Core.Models.AppSettings s, bool tun)
    {
        var exe = FindShipped("tunbox-core.exe");
        Assert.NotNull(exe);
        var home = FreshHome();
        var lines = new List<string>();
        try
        {
            Directory.CreateDirectory(home);
            var apiPort = FreePort();
            s.ApiPort = apiPort;
            if (s.MixedPort == 0) s.MixedPort = FreePort();
            s.ApiSecret = "e2e-secret";
            var nodes = new List<TunBox.Core.Models.ProxyNode>
            {
                new()
                {
                    Id = "1", Name = "HK 01", OriginalName = "HK 01", Kind = TunBox.Core.Models.ProxyKind.Ss,
                    Server = "127.0.0.1", Port = 1, Password = "pw", Method = "aes-256-gcm",
                },
            };
            var yaml = TunBox.Core.Config.ClashConfigGenerator.Generate(nodes,
                Array.Empty<TunBox.Core.Models.ProxyGroup>(), s, new Workspace(home).DetectGates(),
                tunOverride: tun ? true : null);
            var cfg = Path.Combine(home, "config.yaml");
            await File.WriteAllTextAsync(cfg, yaml, new UTF8Encoding(false));

            var psi = new ProcessStartInfo
            {
                FileName = exe!, Arguments = $"-d \"{home}\" -f \"{cfg}\"",
                UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true,
                CreateNoWindow = true,
            };
            using var p = Process.Start(psi)!;
            p.OutputDataReceived += (_, e) => { if (e.Data != null) lock (lines) lines.Add(e.Data); };
            p.ErrorDataReceived += (_, e) => { if (e.Data != null) lock (lines) lines.Add(e.Data); };
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            try
            {
                var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(40);
                var listening = false;
                var fatal = "";
                while (DateTime.UtcNow < deadline)
                {
                    lock (lines)
                    {
                        listening = lines.Any(l => l.Contains($"RESTful API listening at: 127.0.0.1:{apiPort}"));
                        fatal = lines.FirstOrDefault(l => l.Contains("level=fatal")) ?? "";
                    }
                    if (listening || fatal.Length > 0) break;
                    await Task.Delay(250);
                }
                return (listening, fatal, lines);
            }
            finally
            {
                try { if (!p.HasExited) p.Kill(entireProcessTree: true); } catch { }
            }
        }
        finally
        {
            try { Directory.Delete(home, true); } catch { }
        }
    }

    [Fact]
    public async Task Generated_config_makes_the_kernel_listen()
    {
        var s = new TunBox.Core.Models.AppSettings { HttpPort = 0, SocksPort = 0 };
        var (listening, fatal, lines) = await RunKernelAsync(s, tun: true);
        Assert.True(listening, "内核没有打印 API 监听行。fatal: " + fatal + "\n日志：\n" + string.Join("\n", lines.Take(30)));
    }

    /// <summary>
    /// IPv6 + DNS 复写是新增的两条发射路径：内核要是不认这份配置，界面上就是
    /// 「点了连接一直转圈」，所以用真内核验，而不是只看字符串。
    /// </summary>
    [Fact]
    public async Task Kernel_accepts_ipv6_plus_dns_override()
    {
        var s = new TunBox.Core.Models.AppSettings
        {
            HttpPort = 0, SocksPort = 0, Ipv6Enabled = true, DnsOverrideEnabled = true,
        };
        s.DnsServers.AddRange(new[]
        {
            "tls://223.5.5.5:853", "https://doh.pub/dns-query", "system",
        });
        var (listening, fatal, lines) = await RunKernelAsync(s, tun: true);
        Assert.True(listening, "内核拒绝了 IPv6 + DNS 复写的配置。fatal: " + fatal
            + "\n日志：\n" + string.Join("\n", lines.Take(30)));
    }
}

public class ControllerClientTests
{
    private static int EphemeralPort()
    {
        var l = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        l.Start();
        var p = ((System.Net.IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return p;
    }

    /// <summary>
    /// 本内核 /version 实测返回 {"meta":true,"version":"1.10.0"} —— meta 是**布尔**。
    /// 之前按 meta.version 取，索引布尔值抛 InvalidOperationException，被外层 catch 当成
    /// 「控制器不通」：就绪只能退回等监听行，测速与热重载整条链路降级。这条把形状锁死。
    /// </summary>
    [Fact]
    public async Task Kernel_version_json_has_boolean_meta_and_still_parses()
    {
        var port = EphemeralPort();
        using var listener = new System.Net.HttpListener();
        listener.Prefixes.Add($"http://127.0.0.1:{port}/");
        try { listener.Start(); }
        catch (System.Net.HttpListenerException) { return; }   // 环境不允许监听
        var served = new TaskCompletionSource();
        _ = Task.Run(async () =>
        {
            // 一直应答：WaitReadyAsync 会再打一次，只服务一个请求会让它挂在预算上。
            while (listener.IsListening)
            {
                try
                {
                    var ctx = await listener.GetContextAsync();
                    var bytes = Encoding.UTF8.GetBytes("""{"meta":true,"version":"1.10.0"}""");
                    ctx.Response.StatusCode = 200;
                    ctx.Response.ContentType = "application/json";
                    await ctx.Response.OutputStream.WriteAsync(bytes);
                    ctx.Response.Close();
                    served.TrySetResult();
                }
                catch { return; }
            }
        });
        using var api = new ControllerClient();
        api.Configure(port, "secret");
        Assert.Equal("1.10.0", await api.VersionAsync());
        Assert.True(await api.WaitReadyAsync(TimeSpan.FromSeconds(3)));
        listener.Stop();
    }

    /// <summary>内核 /connections 的字段形状。id 是 UUID、chains 是字符串数组、destinationPort 是字符串。</summary>
    private const string KernelSnapshot = """
    {
      "downloadTotal": 4000000, "uploadTotal": 120000,
      "connections": [
        { "id": "0f7f2a3e-6a30-4a6d-9e1c-7f0f3a3c1b11",
          "metadata": { "network": "tcp", "destinationIP": "198.18.0.12", "destinationPort": "443",
                        "host": "api.openai.com", "process": "ChatGPT.exe" },
          "upload": 2048, "download": 913000, "start": "2026-10-11T14:02:11+08:00",
          "chains": ["HK 01", "PROXY"], "rule": "DOMAIN-SUFFIX" },
        { "id": "5b1c9d0e-1f2a-4b3c-8d9e-0f1a2b3c4d5e",
          "metadata": { "network": "udp", "destinationIP": "223.5.5.5", "destinationPort": "53" },
          "upload": 120, "download": 340, "start": "2026-10-11T14:05:41+08:00",
          "chains": ["DIRECT"], "rule": "MATCH" }
      ]
    }
    """;

    [Fact]
    public void Kernel_connection_json_parses_into_usable_rows()
    {
        var snap = ControllerClient.ParseSnapshot(JsonNode.Parse(KernelSnapshot));
        Assert.Equal(120000, snap.UploadTotal);
        Assert.Equal(4000000, snap.DownloadTotal);
        Assert.Equal(2, snap.Connections.Count);
        var first = snap.Connections[0];
        // id 必须是那串 UUID：按 long 解析恒为 0，之后 DELETE /connections/0 一条都关不掉
        Assert.Equal("0f7f2a3e-6a30-4a6d-9e1c-7f0f3a3c1b11", first.Id);
        Assert.Equal("HK 01", first.Chain);
        Assert.Equal("api.openai.com", first.Target);   // 域名优先：fake-ip 没有解释力
        Assert.Equal(443, first.Port);
        Assert.Equal("ChatGPT.exe", first.Process);
    }

    [Fact]
    public void Old_clash_chain_shape_still_resolves()
    {
        var json = "{\"uploadTotal\":0,\"downloadTotal\":0,\"connections\":["
            + "{\"id\":\"x\",\"metadata\":{\"host\":\"a.com\"},\"chains\":[{\"runtime\":{\"selected\":\"JP 02\"}}]}]}";
        var snap = ControllerClient.ParseSnapshot(JsonNode.Parse(json));
        Assert.Equal("JP 02", Assert.Single(snap.Connections).Chain);
    }

    [Fact]
    public void Kernel_errors_are_translated_into_chinese_a_user_can_act_on()
    {
        var explained = ControllerClient.Explain("dial tcp 1.2.3.4:443: connect: connection refused", 503);
        Assert.Contains("端口不通", explained);
        Assert.DoesNotContain("connection refused", explained);
    }
}

public class SubscriptionFetcherTests
{
    [Fact]
    public void Ua_chain_leads_with_the_clients_panels_actually_whitelist()
    {
        // 机场面板按 UA 做内容协商：不认识的客户端拿到的可能是一段提示文字。
        Assert.Equal("clash-verge/v1.7.7", SubscriptionFetcher.UaChain[0]);
        Assert.Contains(SubscriptionFetcher.UaChain, ua => ua.StartsWith("clash.meta"));
        Assert.Contains(SubscriptionFetcher.UaChain, ua => ua.StartsWith("TunBox/"));
    }

    [Fact]
    public void Html_notice_pages_are_detected_before_parsing()
    {
        Assert.True(SubscriptionFetcher.LooksLikeWebPage("<!DOCTYPE html><html>登录</html>"));
        Assert.True(SubscriptionFetcher.LooksLikeWebPage("{\"error\": \"forbidden\"}"));
        Assert.False(SubscriptionFetcher.LooksLikeWebPage("proxies:\n  - {name: a, type: ss}"));
        Assert.False(SubscriptionFetcher.LooksLikeWebPage("ss://YWVzLTI1Ni1nY206cEBzcw==@1.1.1.1:8389#HK"));
    }

    [Fact]
    public void Subscription_userinfo_header_is_parsed_for_the_traffic_card()
    {
        var handler = new System.Net.Http.HttpClientHandler();
        using var resp = new System.Net.Http.HttpResponseMessage
        {
            Headers = { },
        };
        resp.Headers.TryAddWithoutValidation("Subscription-Userinfo",
            "upload=1024; download=2048; total=1048576; expire=1798761600");
        resp.Headers.TryAddWithoutValidation("Profile-Update-Interval", "24");
        var (upload, download, total, expire, interval) = SubscriptionFetcher.ParseUserInfo(resp.Headers);
        Assert.Equal(1024, upload);
        Assert.Equal(2048, download);
        Assert.Equal(1048576, total);
        Assert.Equal(1798761600000, expire);
        Assert.Equal(24 * 60, interval);
    }
}
