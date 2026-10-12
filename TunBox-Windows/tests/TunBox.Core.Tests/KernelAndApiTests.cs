using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using TunBox.App;
using TunBox.Core.Api;
using TunBox.Core.Fetching;
using TunBox.Core.Services;
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

    /// <summary>
    /// 「全局」模式的两条命门，都用真内核钉死（真机反馈：全局模式下 IP 检测站还是国内 IP）：
    /// ① mode 只能靠整份 payload 改 —— 这份 mihomo-smart 内核对 `PUT /configs {"mode":…}` 回 204
    ///    却什么都不换（log-level 同样无效），所以 SetProxyModeAsync 必须重新热应用配置；
    /// ② global 下内核只看 GLOBAL 这个伪分组，而它**既接受具体节点也接受代理组名**（dial 时才解析），
    ///    所以自动态可以把 ♻️ 自动选择 直接交给 GLOBAL，按连接择优在全局下照旧生效。
    /// 最后用一次真实请求验证流量确实走的是 GLOBAL 而不是 DIRECT。
    /// </summary>
    [Fact]
    public async Task Kernel_global_mode_needs_the_payload_and_honours_GLOBAL()
    {
        var exe = FindShipped("tunbox-core.exe");
        Assert.NotNull(exe);
        var home = FreshHome();
        Directory.CreateDirectory(home);
        var apiPort = FreePort();
        var s = new TunBox.Core.Models.AppSettings
        {
            HttpPort = 0, SocksPort = 0, MixedPort = FreePort(), ApiPort = apiPort,
            ApiSecret = "e2e-secret", ProxyMode = "rule", SelectedNodeId = "2",
        };
        var nodes = new List<TunBox.Core.Models.ProxyNode>
        {
            new() { Id = "1", Name = "HK 01", OriginalName = "HK 01", Kind = TunBox.Core.Models.ProxyKind.Ss,
                Server = "127.0.0.1", Port = 1, Password = "pw", Method = "aes-256-gcm" },
            new() { Id = "2", Name = "SG 02", OriginalName = "SG 02", Kind = TunBox.Core.Models.ProxyKind.Ss,
                Server = "127.0.0.1", Port = 2, Password = "pw", Method = "aes-256-gcm" },
        };
        var yaml = TunBox.Core.Config.ClashConfigGenerator.Generate(nodes,
            Array.Empty<TunBox.Core.Models.ProxyGroup>(), s, new Workspace(home).DetectGates(), tunOverride: false);
        var cfg = Path.Combine(home, "config.yaml");
        await File.WriteAllTextAsync(cfg, yaml, new UTF8Encoding(false));

        var lines = new List<string>();
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
            while (DateTime.UtcNow < deadline && !lines.Any(l => l.Contains($"RESTful API listening at: 127.0.0.1:{apiPort}")))
                await Task.Delay(250);

            using var api = new ControllerClient();
            api.Configure(apiPort, "e2e-secret");
            var proxies = await api.ProxiesAsync();
            // 环境连不上控制器不等于产品坏了：这条只在内核确实可问时才判
            if (proxies.Count == 0) return;

            Assert.Equal("rule", await api.ModeAsync());
            // 配置里写的 now 必须被采纳：不写 now 时内核取成员表第一个，用户选的节点就悄悄没了
            Assert.True(proxies.ContainsKey("PROXY"), "内核没给出 PROXY 组。日志：\n" + string.Join("\n", lines.Take(20)));
            Assert.Equal("SG 02", proxies["PROXY"].Now);
            s.ProxyMode = "global";
            var global = TunBox.Core.Config.ClashConfigGenerator.Generate(nodes,
                Array.Empty<TunBox.Core.Models.ProxyGroup>(), s, new Workspace(home).DetectGates(), tunOverride: false);
            var (ok, error) = await api.UpdateConfigAsync(global);
            Assert.True(ok, "整份 payload 热应用被拒：" + error);
            Assert.Equal("global", await api.ModeAsync());
            // 重载之后用户的选择还在（now 跟着配置走，不会被弹回成员表第一个）
            Assert.Equal("SG 02", (await api.ProxiesAsync())["PROXY"].Now);

            Assert.True(await api.SelectNodeAsync("GLOBAL", "PROXY"), "内核不肯让 GLOBAL 走代理组");
            Assert.Equal("PROXY", (await api.ProxiesAsync())["GLOBAL"].Now);
            Assert.True(await api.SelectNodeAsync("GLOBAL", "HK 01"), "内核不肯让 GLOBAL 走具体节点");
            Assert.Equal("HK 01", (await api.ProxiesAsync())["GLOBAL"].Now);

            // 决定性一步：真发一个请求（节点是 127.0.0.1:1 的死地址），日志必须显示它在 dial GLOBAL
            var handler = new System.Net.Http.HttpClientHandler
            {
                Proxy = new System.Net.WebProxy($"http://127.0.0.1:{s.MixedPort}"),
                UseProxy = true,
            };
            using var http = new System.Net.Http.HttpClient(handler);
            http.Timeout = TimeSpan.FromSeconds(8);
            try { await http.GetAsync("http://1.1.1.1/"); } catch { /* 节点本来就连不通 */ }
            await Task.Delay(500);
            string recent;
            lock (lines) recent = string.Join("\n", lines);
            Assert.Contains("dial GLOBAL", recent);
            Assert.DoesNotContain("--> 1.1.1.1:80 doesn't match any rule using DIRECT", recent);
        }
        finally
        {
            try { if (!p.HasExited) p.Kill(entireProcessTree: true); } catch { }
        }
        try { Directory.Delete(home, true); } catch { }
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

/// <summary>
/// 多订阅合并时的节点身份。真机踩过：解析器给每条订阅各自从 n1 编号，三条订阅就有 24 个 id 撞车 ——
/// 「选中的节点」按 id 反查会挑到别家订阅，生成 PROXY 成员时 `Id != selected.Id` 还会把同 id 的
/// 节点一起剔掉，用户点那些节点就被内核拒 400「proxy not exist」。
/// </summary>
public class MultiSubscriptionNodeIdsTests
{
    private static string Home() => Path.Combine(
        Path.GetTempPath(), "tunbox-ids-" + Guid.NewGuid().ToString("N").Substring(0, 6));

    /// <summary>从生成的配置里抠出 PROXY 组的成员表。</summary>
    private static List<string> ProxyMembers(string yaml)
    {
        var lines = yaml.Split('\n');
        var start = Array.FindIndex(lines, l => l.TrimEnd() == "  - name: \"PROXY\"");
        Assert.True(start >= 0, "配置里没有 PROXY 组");
        var members = new List<string>();
        for (var i = start + 1; i < lines.Length && !lines[i].StartsWith("  - name:"); i++)
        {
            var m = Regex.Match(lines[i].TrimEnd(), "^\\s+- \"(.+)\"$");
            if (m.Success) members.Add(m.Groups[1].Value);
        }
        return members;
    }

    [Fact]
    public async Task Every_node_from_every_subscription_reaches_the_PROXY_group()
    {
        var home = Home();
        try
        {
            var cm = new ConnectionManager(new Workspace(home));
            // 两条各两个节点，base64 的 ss:// 链接（解析器会各自从 n1 开始编号）
            Assert.True(await cm.AddSubscriptionAsync(
                "ss://YWVzLTI1Ni1nY206cEBzcw==@1.1.1.1:8389#A1\nss://YWVzLTI1Ni1nY206cEBzcw==@1.1.1.2:8389#A2"));
            Assert.True(await cm.AddSubscriptionAsync(
                "ss://YWVzLTI1Ni1nY206cEBzcw==@2.2.2.1:8389#B1\nss://YWVzLTI1Ni1nY206cEBzcw==@2.2.2.2:8389#B2"));

            var yaml = cm.BuildConfig();
            var members = ProxyMembers(yaml);
            foreach (var name in new[] { "A1", "A2", "B1", "B2" })
                Assert.Contains(name, members);
            Assert.True(members.Count >= 4, $"PROXY 成员表只有 {members.Count} 项");
        }
        finally { try { Directory.Delete(home, true); } catch { } }
    }

    [Fact]
    public async Task Selected_node_from_the_second_subscription_resolves_to_itself()
    {
        var home = Home();
        try
        {
            var cm = new ConnectionManager(new Workspace(home));
            await cm.AddSubscriptionAsync("ss://YWVzLTI1Ni1nY206cEBzcw==@1.1.1.1:8389#A1");
            await cm.AddSubscriptionAsync("ss://YWVzLTI1Ni1nY206cEBzcw==@2.2.2.1:8389#B1");
            await cm.SelectNodeAsync("B1");   // 内核没跑：只记选择
            var yaml = cm.BuildConfig();
            // 选中的是 B1，配置的 now 就必须是 B1；曾经是 n1 撞车后按「第一个」解析成 A1
            Assert.Contains("    now: \"B1\"", yaml.Split('\n'));
            Assert.Contains("A1", ProxyMembers(yaml));   // A1 不能被一起剔出成员表
        }
        finally { try { Directory.Delete(home, true); } catch { } }
    }

    /// <summary>
    /// 老数据（已经带着重复 id 落盘的）必须在启动这一刻被治好 —— 否则用户升级完还得重新更新一次订阅
    /// 才能点节点。这里直接伪造一份撞了 id 的 nodes.json 走启动路径。
    /// </summary>
    [Fact]
    public void Duplicate_ids_in_legacy_data_are_healed_on_startup()
    {
        var home = Home();
        try
        {
            var seed = new NodeLibrary();
            foreach (var (id, name, sub) in new[]
                     { ("n1", "A1", "sa"), ("n2", "A2", "sa"), ("n1", "B1", "sb"), ("n2", "B2", "sb") })
                seed.Nodes.Add(new TunBox.Core.Models.ProxyNode
                {
                    Id = id, Name = name, OriginalName = name, SubscriptionId = sub,
                    Kind = TunBox.Core.Models.ProxyKind.Ss, Server = "1.2.3.4", Port = 8389,
                    Password = "pw", Method = "aes-256-gcm",
                });
            foreach (var s in new[] { "sa", "sb" })
                seed.Subscriptions.Add(new TunBox.Core.Models.Subscription { Id = s, Name = s, Url = "" });
            Directory.CreateDirectory(home);
            File.WriteAllText(Path.Combine(home, "nodes.json"), Workspace.Serialize(seed));

            var cm = new ConnectionManager(new Workspace(home));
            var members = ProxyMembers(cm.BuildConfig());
            Assert.Contains("A1", members);
            Assert.Contains("A2", members);
            Assert.Contains("B1", members);
            Assert.Contains("B2", members);
            // 治完要落盘，别每次都重新治一遍
            var onDisk = Workspace.Deserialize<NodeLibrary>(File.ReadAllText(Path.Combine(home, "nodes.json")))!;
            Assert.Equal(onDisk.Nodes.Count, onDisk.Nodes.Select(n => n.Id).Distinct(StringComparer.Ordinal).Count());
        }
        finally { try { Directory.Delete(home, true); } catch { } }
    }
}

/// <summary>
/// 本地数据（订阅、节点、设置）不许「装新版/重启就没了」。两条路都盯着：
/// 一是只读集合属性让 STJ 写得出去读不回来；二是半截 JSON（写一半进程被杀：升级安装、注销、断电）
/// 解析失败后若无条件回落默认值，下一次保存就把原文冲掉了。
/// </summary>
public class WorkspaceDataTests
{
    private static string TempHome() => Path.Combine(
        Path.GetTempPath(), "tunbox-data-" + Guid.NewGuid().ToString("N")[..8]);

    [Fact]
    public void Half_written_nodes_file_falls_back_to_the_last_good_copy()
    {
        var home = TempHome();
        try
        {
            var ws = new Workspace(home);
            var lib = ws.LoadNodes();
            lib.Nodes.Add(new TunBox.Core.Models.ProxyNode
            { Id = "n1", Name = "香港 A", Server = "hk.example.com", Port = 443 });
            lib.Subscriptions.Add(new TunBox.Core.Models.Subscription
            { Id = "s1", Name = "吹雪云", Url = "https://example.com/sub" });
            Assert.True(ws.SaveNodes(lib));
            Assert.True(ws.SaveNodes(lib)); // 第二次保存才留下上一次的好副本 .bak

            var nodesPath = Path.Combine(home, "nodes.json");
            var bak = nodesPath + ".bak";
            Assert.True(File.Exists(bak), "第二次保存没留下 .bak 好副本");
            File.WriteAllText(nodesPath, "{ \"nodes\": [ { \"id\": \"n1\", \"na");

            var back = new Workspace(home).LoadNodes();
            Assert.Equal("香港 A", back.Nodes[0].Name);
            Assert.Single(back.Subscriptions);

            // 坏文件改名留档，不静默删除；主文件也不会留成半截
            Assert.True(Directory.GetFiles(home, "nodes.json.bad-*").Length > 0);
            Assert.False(File.Exists(nodesPath + ".tmp"));
        }
        finally { try { Directory.Delete(home, true); } catch { } }
    }

    /// <summary>
    /// 存得进去就必须读得回来。只读集合属性是这个坑的经典形态：STJ 能把 List 写出去，
    /// 读回来却一个元素都不填 —— 订阅、节点、分组名单、自定义规则会「重启就没了」。
    /// </summary>
    [Fact]
    public void Every_persisted_list_round_trips_through_disk()
    {
        var home = TempHome();
        try
        {
            var ws = new Workspace(home);
            var lib = ws.LoadNodes();
            var node = new TunBox.Core.Models.ProxyNode { Id = "n1", Name = "东京 B", Server = "tyo", Port = 8443 };
            node.Extras["alpn"] = "h3";
            lib.Nodes.Add(node);
            var group = new TunBox.Core.Models.ProxyGroup { Name = "自动选择", GroupType = "select" };
            group.Members.Add("东京 B");
            lib.Groups.Add(group);
            lib.Subscriptions.Add(new TunBox.Core.Models.Subscription { Id = "s1", Name = "吹雪云" });
            Assert.True(ws.SaveNodes(lib));

            var again = new Workspace(home).LoadNodes();
            Assert.Single(again.Nodes);
            Assert.Equal("h3", again.Nodes[0].Extras["alpn"]);
            Assert.Single(again.Groups);
            Assert.Equal(new[] { "东京 B" }, again.Groups[0].Members);
            Assert.Single(again.Subscriptions);

            var s = ws.LoadSettings();
            s.CustomRules.Add("DOMAIN-SUFFIX,example.com,Proxy");
            s.ForceProxySites.Add("example.com");
            s.ForceDirectSites.Add("lan.local");
            s.AppProcesses.Add("ChatGPT.exe");
            s.DnsServers.Add("tls://223.5.5.5:853");
            Assert.True(ws.SaveSettings(s));

            var settings = new Workspace(home).LoadSettings();
            Assert.Equal(new[] { "DOMAIN-SUFFIX,example.com,Proxy" }, settings.CustomRules);
            Assert.Equal(new[] { "example.com" }, settings.ForceProxySites);
            Assert.Equal(new[] { "lan.local" }, settings.ForceDirectSites);
            Assert.Equal(new[] { "ChatGPT.exe" }, settings.AppProcesses);
            Assert.Equal(new[] { "tls://223.5.5.5:853" }, settings.DnsServers);
        }
        finally { try { Directory.Delete(home, true); } catch { } }
    }

    [Fact]
    public void Settings_save_never_leaves_the_main_file_half_written()
    {
        var home = TempHome();
        try
        {
            var ws = new Workspace(home);
            var s = ws.LoadSettings();
            s.MixedPort = 17890;
            Assert.True(ws.SaveSettings(s));
            Assert.True(ws.SaveSettings(s));

            // 落盘走的是「临时文件 + 原子替换」：主文件任意时刻都是完整 JSON
            var raw = File.ReadAllText(Path.Combine(home, "settings.json"));
            Assert.NotNull(JsonNode.Parse(raw));
            Assert.Equal(17890, new Workspace(home).LoadSettings().MixedPort);
        }
        finally { try { Directory.Delete(home, true); } catch { } }
    }
}

/// <summary>
/// 首页出口信息卡的数据层。这张卡存在的理由就是用户报的「点的节点和查到的 IP 对不上」，
/// 所以解析与「出口=本机」的判定必须钉住，接口被劫持时也要说清现象而不是空白一片。
/// </summary>
public class EgressProbeTests
{
    [Fact]
    public void Parses_ip_api_success_and_collapses_repeated_place_parts()
    {
        const string json = """
            {"status":"success","country":"美国","regionName":"明尼苏达","city":"梅纳哈",
             "isp":"West Central Telephone Assn","as":"AS6434 West Central","query":"216.189.136.50"}
            """;
        var s = EgressProbe.Parse(json, connected: true, localIp: null, error: null);
        Assert.Equal("216.189.136.50", s.EgressIp);
        Assert.Equal("美国 · 明尼苏达 · 梅纳哈", s.Location);
        Assert.Equal("West Central Telephone Assn", s.Carrier);
        Assert.False(s.SameAsLocal);
    }

    /// <summary>国家与城市同名时不重复输出（ip-api 对城市级数据常这样回）。</summary>
    [Fact]
    public void Duplicate_place_parts_are_merged()
    {
        const string json = """
            {"status":"success","country":"新加坡","regionName":"新加坡","city":"新加坡",
             "isp":"AWS","as":"AS16509","query":"54.255.248.158"}
            """;
        Assert.Equal("新加坡", EgressProbe.Parse(json, true, null, null).Location);
    }

    /// <summary>运营商面板/认证门户劫持 DNS 时返回的是 HTML：要报「被劫持」并把前几个字符带出来。</summary>
    [Fact]
    public void Hijacked_html_response_is_reported_as_such()
    {
        var s = EgressProbe.Parse("<!DOCTYPE html><html><body>登录</body></html>", true, null, null);
        Assert.Equal("", s.EgressIp);
        Assert.Contains("劫持", s.Error);
    }

    [Fact]
    public void Api_failure_and_unreachable_proxy_leave_a_reason_not_a_blank()
    {
        var s = EgressProbe.Parse("", connected: true, localIp: "1.2.3.4", error: "连接被中止");
        Assert.Equal("连接被中止", s.Error);
        Assert.Equal("1.2.3.4", s.LocalIp);   // 本机 IP 还是要留住

        var denied = EgressProbe.Parse("""{"status":"fail","message":"reserved range"}""", true, null, null);
        Assert.Contains("reserved range", denied.Error);
    }

    /// <summary>出口 IP 与本机 IP 相同 = 这条连接压根没走代理 —— 卡片要能把这句话说出来。</summary>
    [Fact]
    public void Same_ip_as_local_means_traffic_never_left_the_machine()
    {
        var s = new EgressSnapshot("1.2.3.4", "中国 · 上海", "China Telecom", "AS4134", "1.2.3.4", true, null, DateTime.Now);
        Assert.True(s.SameAsLocal);
        Assert.False((s with { LocalIp = "9.9.9.9" }).SameAsLocal);
    }

    /// <summary>查出口走的是内核的混合端口；端口没开就别瞎试，直接给原因。</summary>
    [Fact]
    public async Task No_proxy_port_is_an_explicit_refusal()
    {
        await Assert.ThrowsAsync<InvalidOperationException>(
            async () => await EgressProbe.FetchViaProxyAsync(0, CancellationToken.None));
    }
}

/// <summary>
/// 版本号写死在四个地方（app 程序集、installer.nsi 的两处、make-installer.ps1），漏一个就会发出
/// 「文件名 0.3.0、关于页 0.4.8」这种自相矛盾的包 —— 0.4.8 那轮真就这么差点出事。
/// 两端还要对齐：鸿蒙端 AppScope/app.json5 的 versionName 是同一个产品的版本号。
/// </summary>
public class VersionConsistencyTests
{
    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        for (var depth = 0; dir != null && depth < 10; depth++, dir = dir.Parent)
            if (Directory.Exists(Path.Combine(dir.FullName, "TunBox-Windows"))) return dir.FullName;
        throw new DirectoryNotFoundException("找不到仓库根（应有 TunBox-Windows/）");
    }

    [Fact]
    public void Windows_version_matches_the_app_the_installer_and_the_harmonyos_client()
    {
        var root = RepoRoot();
        var nsi = File.ReadAllText(Path.Combine(root, "TunBox-Windows", "scripts", "installer.nsi"));
        var ps1 = File.ReadAllText(Path.Combine(root, "TunBox-Windows", "scripts", "make-installer.ps1"));

        string Grab(string text, string pattern) =>
            Regex.Match(text, pattern).Groups[1].Value;

        var appVersion = typeof(TunBox.App.MainViewModel).Assembly
            .GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
            .Cast<System.Reflection.AssemblyInformationalVersionAttribute>()
            .FirstOrDefault()?.InformationalVersion.Split('+')[0] ?? "";
        var nsiVersion = Grab(nsi, "!define VERSION \"([^\"]+)\"");
        var nsiResource = Grab(nsi, "VIAddVersionKey \"ProductVersion\" \"([^\"]+)\"");
        var scriptVersion = Grab(ps1, @"(?m)^\$ver = '([^']+)'");

        Assert.False(appVersion.Length == 0, "读不到程序集版本");
        Assert.Equal(appVersion, nsiVersion);
        Assert.Equal(nsiVersion, nsiResource);
        Assert.Equal(nsiVersion, scriptVersion);

        var json5 = File.ReadAllText(Path.Combine(root, "TunBox_HarmonyOS", "AppScope", "app.json5"));
        var harmonyVersion = Grab(json5, "\"versionName\":\\s*\"([^\"]+)\"");
        Assert.Equal(harmonyVersion, appVersion);
    }
}

/// <summary>
/// 全局模式的出口解析。真机反馈：切到「全局」后 IP 检测站还是国内 IP，「规则」反而是节点 IP ——
/// 因为内核在 global 下只看 GLOBAL 这个伪分组，而我们只改了 mode、从没选过它，它一直停在 DIRECT。
/// 这里盯死：出口要跟 PROXY 组当前的选择走（组名也算，内核实测认），且永远不许退成 DIRECT / REJECT，
/// 也不许选中订阅面板当成代理返回的「剩余流量：xxx GB」这类说明行。
/// </summary>
public class GlobalModeEgressTests
{
    private static readonly List<TunBox.Core.Models.ProxyNode> Nodes = new()
    {
        new() { Id = "info", Name = "剩余流量：954.24 GB", Kind = TunBox.Core.Models.ProxyKind.Unknown, Server = "" },
        new() { Id = "n1", Name = "HK 01", Kind = TunBox.Core.Models.ProxyKind.Vless, Server = "hk.example.com" },
        new() { Id = "n2", Name = "SG 02", Kind = TunBox.Core.Models.ProxyKind.Ss, Server = "sg.example.com" },
    };

    private static Dictionary<string, (string Now, List<string> All)> Proxies(
        string proxyNow = "♻️ 自动选择", string smartNow = "SG 02") => new()
    {
        [ConnectionManager.GlobalGroup] = ("DIRECT",
            new List<string> { "DIRECT", "REJECT", "剩余流量：954.24 GB", "HK 01", "SG 02" }),
        [ConnectionManager.ProxyGroup] = (proxyNow, new List<string> { "♻️ 自动选择", "HK 01", "SG 02" }),
        [TunBox.Core.Config.ClashConfigGenerator.SmartGroupName] = (smartNow, new List<string> { "HK 01", "SG 02" }),
    };

    /// <summary>自动态：GLOBAL 直接拿 PROXY 的当前选择（♻️ 自动选择），smart 的按连接择优在全局下照旧生效。</summary>
    [Theory]
    [InlineData(ConnectionManager.AutoEgressId)]
    [InlineData("")]
    public void Global_egress_mirrors_whatever_the_PROXY_group_chose(string selected)
    {
        Assert.Equal("♻️ 自动选择", ConnectionManager.PickGlobalEgress(selected, Nodes, Proxies()));
        Assert.Equal("HK 01", ConnectionManager.PickGlobalEgress(selected, Nodes, Proxies(proxyNow: "HK 01")));
    }

    /// <summary>PROXY 组停在 DIRECT（用户真选了直连）时不许拿它当出口，要退到别的可路由项。</summary>
    [Fact]
    public void Direct_is_never_the_global_egress()
    {
        Assert.Equal("SG 02", ConnectionManager.PickGlobalEgress(ConnectionManager.AutoEgressId, Nodes,
            Proxies(proxyNow: "DIRECT")));
        var onlyReject = new Dictionary<string, (string Now, List<string> All)>
        {
            [ConnectionManager.ProxyGroup] = ("REJECT", new List<string> { "REJECT" }),
        };
        Assert.Equal("HK 01", ConnectionManager.PickGlobalEgress(ConnectionManager.AutoEgressId, Nodes, onlyReject));
    }

    /// <summary>没有 PROXY 视图（内核刚起）时依次退回：用户点过的节点 → smart 当前节点 → 第一个像节点的名字。</summary>
    [Fact]
    public void Fallbacks_skip_the_info_lines_and_pick_a_real_node()
    {
        var noProxy = new Dictionary<string, (string Now, List<string> All)>
        {
            [TunBox.Core.Config.ClashConfigGenerator.SmartGroupName] = ("SG 02", new List<string> { "HK 01", "SG 02" }),
        };
        Assert.Equal("SG 02", ConnectionManager.PickGlobalEgress(ConnectionManager.AutoEgressId, Nodes, noProxy));
        Assert.Equal("HK 01", ConnectionManager.PickGlobalEgress("n1", Nodes, noProxy));

        var nothing = new Dictionary<string, (string Now, List<string> All)>();
        Assert.Equal("HK 01", ConnectionManager.PickGlobalEgress(ConnectionManager.AutoEgressId, Nodes, nothing));
    }
}
