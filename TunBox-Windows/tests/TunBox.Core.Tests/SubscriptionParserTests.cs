using TunBox.Core.Config;
using TunBox.Core.Models;
using TunBox.Core.Parsing;
using Xunit;

namespace TunBox.Core.Tests;

/// <summary>
/// 订阅解析的契约。这里每一条都对应一次真实事故：
/// YAML 的逐字模板（丢字段 → 节点连不上）、重名去重、坏节点拦截（一个坏节点 = 整份配置 fatal）。
/// </summary>
public class SubscriptionParserTests
{
    [Fact]
    public void Ss_link_decodes_method_and_password()
    {
        var r = SubscriptionParser.Parse("ss://YWVzLTI1Ni1nY206cEBzcw==@1.2.3.4:8389#HK%2001");
        var n = Assert.Single(r.Nodes);
        Assert.Equal(ProxyKind.Ss, n.Kind);
        Assert.Equal("aes-256-gcm", n.Method);
        Assert.Equal("p@ss", n.Password);
        Assert.Equal("1.2.3.4", n.Server);
        Assert.Equal(8389, n.Port);
        Assert.Equal("HK 01", n.Name);
    }

    [Fact]
    public void Ss_link_with_plain_credentials_still_parses()
    {
        var r = SubscriptionParser.Parse("ss://aes-256-gcm:p%40ss@1.2.3.4:8389#HK");
        var n = Assert.Single(r.Nodes);
        Assert.Equal("p@ss", n.Password);
    }

    [Fact]
    public void Vless_reality_params_map_to_model_fields()
    {
        const string link = "vless://b1b7c1d0-1111-2222-3333-444455556666@1.2.3.4:443"
            + "?encryption=none&security=reality&sni=www.example.com&fp=chrome&pbk="
            + "SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRQ&sid=6ba85179&type=tcp&flow=xtls-rprx-vision#JP%2002";
        var r = SubscriptionParser.Parse(link);
        var n = Assert.Single(r.Nodes);
        Assert.Equal(ProxyKind.Vless, n.Kind);
        Assert.Equal("www.example.com", n.Servername);
        Assert.True(n.Tls);
        Assert.Equal("chrome", n.ClientFingerprint);
        Assert.Equal("xtls-rprx-vision", n.Flow);
        Assert.Equal(43, n.RealityPublicKey.Length);
        Assert.Equal("6ba85179", n.RealityShortId);
    }

    [Fact]
    public void Vmess_legacy_base64_json_is_parsed()
    {
        const string link = "vmess://eyJhZGQiOiI1LjYuNy44IiwiYWlkIjoiMCIsImlkIjoiYjFiN2MxZDAtMTExMS0yMjIyLTMzMzMtNDQ0NDU1NTU2NjY2IiwibmV0Ijoid3MiLCJwb3J0IjoiNDQzIiwidHlwZSI6Im5vbmUiLCJ2IjoiMiIsInBzIjoiSlAgMDIiLCJob3N0IjoiY2RuLmV4YW1wbGUuY29tIiwicGF0aCI6Ii9wYXRoIiwidGxzIjoidGxzIn0=";
        var r = SubscriptionParser.Parse(link);
        var n = Assert.Single(r.Nodes);
        Assert.Equal(ProxyKind.Vmess, n.Kind);
        Assert.Equal("5.6.7.8", n.Server);
        Assert.Equal(443, n.Port);
        Assert.Equal("JP 02", n.Name);
        Assert.True(n.Tls);
        Assert.Equal("ws", n.Network);
        Assert.Equal("/path", n.WsPath);
        Assert.Equal("cdn.example.com", n.WsHost);
    }

    [Fact]
    public void Hysteria2_link_with_empty_path_before_query_is_parsed()
    {
        // 有些面板生成 hysteria2://pass@host:port?sni=...（没有 path 段），SplitUri 必须容忍
        var r = SubscriptionParser.Parse("hysteria2://pw@1.2.3.4:8443/?sni=a.com&insecure=1#HY2");
        var n = Assert.Single(r.Nodes);
        Assert.Equal(ProxyKind.Hysteria2, n.Kind);
        Assert.Equal("a.com", n.Servername);
        Assert.True(n.SkipCertVerify);
    }

    [Fact]
    public void Base64_blob_subscription_with_unpadded_urlsafe_alphabet()
    {
        var inner = "ss://YWVzLTI1Ni1nY206cEBzcw==@1.1.1.1:8389#HK\n"
            + "ss://YWVzLTI1Ni1nY206cEBzcw==@2.2.2.2:8389#JP\n";
        var b64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(inner))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var r = SubscriptionParser.Parse(b64);
        Assert.Equal(2, r.Nodes.Count);
    }

    [Fact]
    public void Yaml_subscription_keeps_unknown_fields_via_raw_template()
    {
        // xhttp-opts / dialer-proxy / smux 都是过去「解析→重生成丢字段」炸掉过的写法
        const string sub = """
proxies:
  - {name: X, type: vless, server: 1.2.3.4, port: 443, uuid: keep-me, network: xhttp,
     xhttp-opts: {mode: stream-up, extra: {c0: "a;b(c)%d"}}, dialer-proxy: 中转,
     tls: true, servername: a.com, client-fingerprint: firefox, smux: {enabled: true}}
proxy-groups:
  - {name: 自动, type: url-test, proxies: [X], url: "http://www.gstatic.com/generate_204", interval: 60}
""";
        var r = SubscriptionParser.Parse(sub);
        var n = Assert.Single(r.Nodes);
        Assert.True(r.LooksLikeYaml);
        Assert.Equal(ProxyKind.Vless, n.Kind);
        // 未知字段进 Extras 与 RawTemplate；凭据绝不进模板（模板要能安全持久化）
        Assert.Contains("xhttp-opts", n.RawTemplate);
        Assert.Contains("dialer-proxy", n.RawTemplate);
        Assert.Contains("smux", n.RawTemplate);
        Assert.DoesNotContain("keep-me", n.RawTemplate);
        Assert.DoesNotContain("uuid", n.RawTemplate);
        Assert.Equal(1, r.Groups.Count);
        Assert.Equal("自动", r.Groups[0].Name);
        Assert.Equal("url-test", r.Groups[0].GroupType);
        Assert.Equal("X", Assert.Single(r.Groups[0].Members));
    }

    [Fact]
    public void Bare_yaml_null_is_not_the_string_null()
    {
        const string sub = "proxies:\n  - {name: X, type: ss, server: 1.2.3.4, port: 8389, cipher: aes-256-gcm, password: pw, udp: null}\n";
        var r = SubscriptionParser.Parse(sub);
        var n = Assert.Single(r.Nodes);
        Assert.False(n.Extras.ContainsKey("udp") && n.Extras["udp"] == "null");
    }

    [Fact]
    public void Unsupported_protocol_is_dropped_with_a_counted_reason()
    {
        const string sub = "proxies:\n  - {name: X, type: sukka, server: 1.2.3.4, port: 443}\n";
        var r = SubscriptionParser.Parse(sub);
        Assert.Empty(r.Nodes);
        Assert.Contains(r.Warnings, w => w.Contains("协议不支持"));
    }
    /// <summary>
    /// 节点身份以订阅原文的名字为准：中转/落地分离的机场会让所有节点共用同一个
    /// 入口服务器+UUID，只有名字不同 —— 按端点去重会把它们整批吃掉（真机实测，24 只剩 12）。
    /// </summary>
    [Fact]
    public void Same_entry_with_different_names_are_distinct_nodes()
    {
        var link = "ss://YWVzLTI1Ni1nY206cEBzcw==@1.1.1.1:8389#HK%2001\n"
            + "ss://YWVzLTI1Ni1nY206cEBzcw==@1.1.1.1:8389#HK%2002\n";
        var r = SubscriptionParser.Parse(link);
        Assert.Equal(2, r.Nodes.Count);
        Assert.Equal(new[] { "HK 01", "HK 02" }, r.Nodes.Select(n => n.Name));
    }

    [Fact]
    public void Fully_identical_entries_are_deduped()
    {
        var link = "ss://YWVzLTI1Ni1nY206cEBzcw==@1.1.1.1:8389#A\n"
            + "ss://YWVzLTI1Ni1nY206cEBzcw==@1.1.1.1:8389#A\n";   // 同名同端点才是重复
        var r = SubscriptionParser.Parse(link);
        Assert.Single(r.Nodes);
        Assert.Contains(r.Warnings, w => w.Contains("重复"));
    }
}

/// <summary>配置生成：这些不变量错一条，用户就连不上或者路由全错。</summary>
public class ClashConfigGeneratorTests
{
    private static ProxyNode Node(string name) => new()
    {
        Id = name, Name = name, OriginalName = name, Kind = ProxyKind.Ss,
        Server = "127.0.0.1", Port = 8389, Password = "pw", Method = "aes-256-gcm", Udp = true,
    };

    private static AppSettings Settings() => new() { ApiPort = 9099, MixedPort = 7899 };

    [Fact]
    public void Geoip_and_adrules_are_omitted_until_files_are_ready()
    {
        var yaml = ClashConfigGenerator.Generate(new[] { Node("a") }, Array.Empty<ProxyGroup>(), Settings(),
            new ClashConfigGenerator.FeatureGate(false, false));
        Assert.DoesNotContain("GEOIP,CN", yaml);
        Assert.DoesNotContain("rule-providers", yaml);
        Assert.DoesNotContain("fallback:", yaml);
        Assert.Contains("DOMAIN-SUFFIX,cn,DIRECT", yaml);   // 降级路径仍要国内直连
        Assert.Contains("MATCH,PROXY", yaml);

        var s = Settings();
        s.AdRulesEnabled = true;
        var full = ClashConfigGenerator.Generate(new[] { Node("a") }, Array.Empty<ProxyGroup>(), s,
            new ClashConfigGenerator.FeatureGate(true, true));
        Assert.Contains("GEOIP,CN,DIRECT", full);
        Assert.Contains("RULE-SET,hyper-adrules,REJECT", full);
        Assert.Contains("fallback:", full);
    }

    /// <summary>
    /// PROXY 组必须把用户的选择写成 `now`。没有 now 时内核默认取成员表第一个，而我们第一位放的是
    /// ♻️ 自动选择 —— 用户点了具体节点，一重启/热重载就悄悄变回「每条连接由模型挑」，
    /// 查到的出口 IP 跟所选节点对不上（真机现象）。
    /// </summary>
    [Fact]
    public void Proxy_group_carries_the_users_choice_as_now()
    {
        var nodes = new[] { Node("hk"), Node("sg") };
        var gate = new ClashConfigGenerator.FeatureGate(true, true, true);

        var s = Settings();
        s.SelectedNodeId = "sg";
        Assert.Contains("    now: \"sg\"", ClashConfigGenerator.Generate(nodes, Array.Empty<ProxyGroup>(), s, gate));

        // 自动优选态（哨兵值，或从没选过）才把 now 交给 smart 组
        s.SelectedNodeId = AppSettings.AutoNodeId;
        Assert.Contains($"    now: \"{ClashConfigGenerator.SmartGroupName}\"",
            ClashConfigGenerator.Generate(nodes, Array.Empty<ProxyGroup>(), s, gate));
        Assert.Contains($"    now: \"{ClashConfigGenerator.SmartGroupName}\"",
            ClashConfigGenerator.Generate(nodes, Array.Empty<ProxyGroup>(), Settings(), gate));

        // 选中的节点被订阅更新删掉了：now 回落真实存在的节点，绝不写一个不存在的名字
        var ghost = Settings();
        ghost.SelectedNodeId = "does-not-exist";
        Assert.Contains("    now: \"hk\"", ClashConfigGenerator.Generate(nodes, Array.Empty<ProxyGroup>(), ghost, gate));
    }

    [Fact]
    public void Kernel_geo_auto_update_points_at_a_domestic_reachable_mirror()    {
        // 内核的 RegisterGeoUpdater 是后台 ticker，不参与启动路径，保鲜交给它；
        // 但默认地址是 GitHub release，国内直连多半下不动 —— 必须换成拿得到的镜像。
        var yaml = ClashConfigGenerator.Generate(new[] { Node("a") }, Array.Empty<ProxyGroup>(), Settings(),
            new ClashConfigGenerator.FeatureGate(true, true, true));
        Assert.Contains("geo-auto-update: true", yaml);
        Assert.Contains("testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.metadb", yaml);
    }

    [Fact]
    public void Suppressed_log_levels_are_clamped_this_kernel_stalls_without_it()
    {
        // 实测：log-level 取 warning/error/silent 时内核停在 Initial configuration complete 之后
        var s = Settings();
        s.CoreLogLevel = "warning";
        var yaml = ClashConfigGenerator.Generate(new[] { Node("a") }, Array.Empty<ProxyGroup>(), s,
            new ClashConfigGenerator.FeatureGate(false, false));
        Assert.Contains("log-level: info", yaml);
    }

    [Fact]
    public void Smart_group_is_omitted_until_the_lightgbm_model_is_on_disk()
    {
        // 模型不在盘上就绝不发射 smart 组：缺模型时内核会在启动路径同步去 GitHub 下载 Model.bin，
        // 国内不可达就是「点了连接一直转圈」（鸿蒙侧实测阻塞 ~90s）。
        var yaml = ClashConfigGenerator.Generate(new[] { Node("a"), Node("b") }, Array.Empty<ProxyGroup>(), Settings(),
            new ClashConfigGenerator.FeatureGate(false, false, SmartModelReady: false));
        Assert.DoesNotContain("type: smart", yaml);
        Assert.DoesNotContain("uselightgbm", yaml);
    }

    [Fact]
    public void Tun_block_carries_device_stack_routes_and_dns_hijack()
    {
        var s = Settings();
        s.TunEnabled = true;
        var yaml = ClashConfigGenerator.Generate(new[] { Node("a") }, Array.Empty<ProxyGroup>(), s,
            new ClashConfigGenerator.FeatureGate(false, false));
        Assert.Contains("device: TunBox", yaml);
        Assert.Contains("stack: system", yaml);
        Assert.Contains("auto-route: true", yaml);
        Assert.Contains("any:53", yaml);
        Assert.Contains("enhanced-mode: fake-ip", yaml);
    }

    [Fact]
    public void Empty_node_list_throws_a_readable_error_instead_of_an_unloadable_config()
    {
        var ex = Assert.Throws<InvalidOperationException>(() =>
            ClashConfigGenerator.Generate(Array.Empty<ProxyNode>(), Array.Empty<ProxyGroup>(), Settings(),
                new ClashConfigGenerator.FeatureGate(false, false)));
        Assert.Contains("没有可用的节点配置", ex.Message);
    }

    [Fact]
    public void Raw_template_flows_back_without_the_outer_braces()
    {
        var n = new ProxyNode
        {
            Id = "x", Name = "X", OriginalName = "X", Kind = ProxyKind.Vless, Server = "1.2.3.4",
            Port = 443, Uuid = "keep-me", Network = "xhttp",
            RawTemplate = "{type: \"vless\", server: \"1.2.3.4\", port: 443, network: \"xhttp\", "
                + "xhttp-opts: {mode: \"stream-up\"}}",
        };
        var yaml = ClashConfigGenerator.NodeYaml(n);
        // 名字注入 + 模板逐字 + 凭据注入，且没有「映射套映射」的嵌套（那种 YAML 内核会整份 fatal）
        Assert.StartsWith("  - {name: \"X\"", yaml);
        Assert.Contains("xhttp-opts: {mode: \"stream-up\"}", yaml);
        Assert.Contains("uuid: \"keep-me\"", yaml);
        Assert.False(yaml.Contains("{name: \"X\", {"), "模板外壳没剥掉");
    }

    [Fact]
    public void Ipv6_switch_reaches_both_the_kernel_and_dns()
    {
        // 只开顶层 ipv6 而 dns.ipv6 仍为 false 的话，AAAA 根本不查，v6 站点照样打不开。
        var s = Settings();
        Assert.Contains("ipv6: false", ClashConfigGenerator.Generate(new[] { Node("a") },
            Array.Empty<ProxyGroup>(), s, new ClashConfigGenerator.FeatureGate(false, false)));

        s.Ipv6Enabled = true;
        var yaml = ClashConfigGenerator.Generate(new[] { Node("a") }, Array.Empty<ProxyGroup>(), s,
            new ClashConfigGenerator.FeatureGate(false, false));
        Assert.Contains("ipv6: true", yaml);
        Assert.Contains("  ipv6: true", yaml);
    }

    [Fact]
    public void Dns_override_replaces_nameserver_but_keeps_the_bootstrapper()
    {
        var s = Settings();
        s.DnsOverrideEnabled = true;
        s.DnsServers.AddRange(new[]
        {
            "tls://223.5.5.5:853", "https://doh.pub/dns-query", "8.8.8.8:53",
            "not a dns server", "ftp://1.1.1.1",
        });
        var yaml = ClashConfigGenerator.Generate(new[] { Node("a") }, Array.Empty<ProxyGroup>(), s,
            new ClashConfigGenerator.FeatureGate(true, false));
        Assert.Contains("- \"tls://223.5.5.5:853\"", yaml);
        Assert.Contains("- \"https://doh.pub/dns-query\"", yaml);
        Assert.Contains("- \"8.8.8.8:53\"", yaml);
        Assert.DoesNotContain("not a dns server", yaml);
        Assert.DoesNotContain("ftp://", yaml);
        Assert.DoesNotContain("tls://1.12.12.12", yaml);   // 内置那组被换掉了
        Assert.Contains("default-nameserver:", yaml);      // 引导 DNS 必须留着，否则 DoH 域名自己解析不了
        Assert.DoesNotContain("fallback:", yaml);          // 接管了就不塞内置兜底
    }

    [Theory]
    [InlineData("223.5.5.5", "")]
    [InlineData("8.8.8.8:53", "")]
    [InlineData("tls://1.12.12.12:853", "")]
    [InlineData("https://doh.pub/dns-query", "")]
    [InlineData("quic://dns.alidns.com", "")]
    [InlineData("system", "")]
    [InlineData("dns.google", "")]
    [InlineData("[2001:4860:4860::8888]:53", "")]
    [InlineData("", "地址为空")]
    [InlineData("223.5.5.5:0", "端口应为 1-65535")]
    [InlineData("ftp://1.1.1.1", "不支持的协议 ftp（可用 udp / tcp / tls / https / quic / h3）")]
    [InlineData("hello world", "地址不能包含空白或引号")]
    public void Dns_server_validation_says_why_a_line_is_rejected(string value, string expected)
        => Assert.Contains(expected, ClashConfigGenerator.ValidateDnsServer(value));

    [Fact]
    public void App_routing_rules_come_before_geo_rules()
    {
        var s = Settings();
        s.AppRouting = AppRoutingMode.BypassSelected;
        s.AppProcesses.Add("WeChat.exe");
        var yaml = ClashConfigGenerator.Generate(new[] { Node("a") }, Array.Empty<ProxyGroup>(), s,
            new ClashConfigGenerator.FeatureGate(true, false));
        Assert.True(yaml.IndexOf("PROCESS-NAME,WeChat.exe,DIRECT", StringComparison.Ordinal)
            < yaml.IndexOf("GEOIP,CN,DIRECT", StringComparison.Ordinal));
    }

    [Fact]
    public void OnlySelected_mode_flips_the_fallback_to_direct()
    {
        var s = Settings();
        s.AppRouting = AppRoutingMode.OnlySelected;
        s.AppProcesses.Add("Game.exe");
        var yaml = ClashConfigGenerator.Generate(new[] { Node("a") }, Array.Empty<ProxyGroup>(), s,
            new ClashConfigGenerator.FeatureGate(false, false));
        Assert.Contains("MATCH,DIRECT", yaml);
        Assert.DoesNotContain("MATCH,PROXY", yaml);
    }
}
