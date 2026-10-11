using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TunBox.Core.Models;

namespace TunBox.Core.Api;

public sealed record DelayResult(string Name, int DelayMs, DelayState State, string? Error = null)
{
    public bool Ok => State == DelayState.Ok;

    public string Text => State switch
    {
        DelayState.Ok => $"{DelayMs} ms",
        DelayState.Testing => "测速中…",
        DelayState.Timeout => "超时",
        DelayState.Failed => "不通",
        _ => "测速",
    };
}

/// <summary>一条活动连接。字段名照内核 tracker.go 的 JSON 输出：
/// id 是 UUID 字符串、chains 是字符串数组、destinationPort 带 `,string` 标签。</summary>
public sealed record Connection(string Id, string Chain, string Host, string Destination, int Port,
    string Process, string Network, string Rule, DateTime Start, long Upload, long Download)
{
    /// <summary>域名优先：fake-ip 下目的 IP 是 198.18.x.x，对用户没有意义。</summary>
    public string Target => Host.Length > 0 ? Host : Destination;
}

/// <summary>一次连接快照：整张表 + 内核累计字节数（用来差分算实时速率）。</summary>
public sealed record Snapshot(long UploadTotal, long DownloadTotal, IReadOnlyList<Connection> Connections);

/// <summary>
/// mihomo external-controller 的 REST 客户端。
/// 所有调用都带超时并失败降级——控制器不可达不能让 UI 卡死。
/// 注意 UseProxy=false：控制器走 loopback，绝不能被自己设的系统代理绕一圈。
/// </summary>
public sealed class ControllerClient : IDisposable
{
    /// <summary>内核侧测速超时：5s 足够区分「能用」和「不能用」，又不会把整批拖成假超时。</summary>
    public const int DefaultTimeoutMs = 5000;

    /// <summary>并发上限：几十个节点同时打同一个测速地址会把出口和机场拖成一片假超时。</summary>
    public const int DefaultConcurrency = 10;

    private readonly HttpClient _http;
    private string _baseUrl = "";
    private string _secret = "";

    public ControllerClient()
    {
        _http = new HttpClient(new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false })
        {
            // 必须大于「内核超时 + 余量」：比内核先掐连接，一整批节点会齐刷刷报失败。
            Timeout = TimeSpan.FromMilliseconds(DefaultTimeoutMs + 3000),
        };
    }

    public void Configure(int apiPort, string secret)
    {
        _baseUrl = $"http://127.0.0.1:{apiPort}";
        _secret = secret ?? "";
    }

    private HttpRequestMessage New(HttpMethod method, string path)
    {
        var req = new HttpRequestMessage(method, _baseUrl + path);
        if (_secret.Length > 0)
            req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + _secret);
        return req;
    }

    private async Task<JsonNode?> GetJsonAsync(string path, CancellationToken ct)
    {
        using var resp = await _http.SendAsync(New(HttpMethod.Get, path), ct).ConfigureAwait(false);
        resp.EnsureSuccessStatusCode();
        var text = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        return JsonNode.Parse(text);
    }

    /// <summary>
    /// 本内核的 /version 实测返回 <c>{"meta":true,"version":"1.10.0"}</c> —— meta 是布尔，不是对象。
    /// 之前按 <c>meta.version</c> 取，索引布尔值直接抛 InvalidOperationException，被外层 catch
    /// 当成「控制器不通」：就绪只能退回等监听行 + 白烧佐证预算，测速与热重载整条链路降级。
    /// （同一端口 curl 拿 200，证明不是机器拦回环 HTTP。）
    /// </summary>
    public async Task<string?> VersionAsync(CancellationToken ct = default)
    {
        var n = await GetJsonAsync("/version", ct).ConfigureAwait(false);
        return AsText(n?["version"]) ?? AsText(n?["meta"] is JsonObject m ? m["version"] : null);
    }

    private static string? AsText(JsonNode? node) =>
        node != null && node.GetValueKind() == JsonValueKind.String ? node.GetValue<string>() : null;

    /// <summary>控制器是否已就绪（内核起来后要轮询这个，不能盲等固定时长）。</summary>
    public async Task<bool> WaitReadyAsync(TimeSpan budget, CancellationToken ct = default)
    {
        var deadline = DateTime.UtcNow + budget;
        while (DateTime.UtcNow < deadline)
        {
            ct.ThrowIfCancellationRequested();
            try
            {
                await VersionAsync(ct).ConfigureAwait(false);
                return true;
            }
            catch { await Task.Delay(250, ct).ConfigureAwait(false); }
        }
        return false;
    }

    public async Task<string> ModeAsync(CancellationToken ct = default)
    {
        try
        {
            var n = await GetJsonAsync("/configs", ct).ConfigureAwait(false);
            return n?["mode"]?.GetValue<string>() ?? "rule";
        }
        catch { return "rule"; }
    }

    /// <summary>切换 规则/全局/直连。热更新，不重建内核。</summary>
    public async Task<bool> SetModeAsync(string mode, CancellationToken ct = default)
    {
        try
        {
            var payload = JsonSerializer.Serialize(new { mode = mode == "global" ? "global" : mode == "direct" ? "direct" : "rule" });
            var request = New(HttpMethod.Put, "/configs");
            request.Content = new StringContent(payload, Encoding.UTF8, "application/json");
            using var resp = await _http.SendAsync(request, ct).ConfigureAwait(false);
            return resp.IsSuccessStatusCode;
        }
        catch { return false; }
    }

    /// <summary>
    /// 热应用一份新配置（PUT /configs 的 payload 形式）：内核 ParseWithBytes + ApplyConfig，
    /// 不重启进程、不断已有连接。内核拒收时返回原因，调用方退回重启。
    /// </summary>
    public async Task<(bool Ok, string? Error)> UpdateConfigAsync(string yaml, CancellationToken ct = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(25));
        try
        {
            var payload = JsonSerializer.Serialize(new { payload = yaml });
            var request = New(HttpMethod.Put, "/configs");
            request.Content = new StringContent(payload, Encoding.UTF8, "application/json");
            using var resp = await _http.SendAsync(request, timeout.Token).ConfigureAwait(false);
            if (resp.IsSuccessStatusCode) return (true, null);
            var text = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            return (false, TryMessage(text) ?? $"内核返回 HTTP {(int)resp.StatusCode}");
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception e) { return (false, e.Message); }
    }

    /// <summary>代理组与当前选中项；用于把内核状态回填给 UI。</summary>
    public async Task<Dictionary<string, (string Now, List<string> All)>> ProxiesAsync(CancellationToken ct = default)
    {
        var outDict = new Dictionary<string, (string, List<string>)>(StringComparer.Ordinal);
        try
        {
            var n = (await GetJsonAsync("/proxies", ct).ConfigureAwait(false))?["proxies"]?.AsObject();
            if (n == null) return outDict;
            foreach (var kv in n)
            {
                var now = kv.Value?["now"]?.GetValue<string>() ?? "";
                var all = new List<string>();
                if (kv.Value?["all"] is JsonArray arr)
                    foreach (var item in arr) all.Add(item?.GetValue<string>() ?? "");
                outDict[kv.Key] = (now, all);
            }
        }
        catch { /* 内核未就绪时返回空表，UI 保持上一次视图 */ }
        return outDict;
    }

    public async Task<bool> SelectNodeAsync(string group, string node, CancellationToken ct = default)
    {
        try
        {
            var payload = JsonSerializer.Serialize(new { name = node });
            var request = New(HttpMethod.Put, "/proxies/" + Uri.EscapeDataString(group));
            request.Content = new StringContent(payload, Encoding.UTF8, "application/json");
            using var resp = await _http.SendAsync(request, ct).ConfigureAwait(false);
            return resp.IsSuccessStatusCode;
        }
        catch { return false; }
    }

    /// <summary>
    /// 单节点延迟：走内核的 /delay，测的是完整代理链的 HTTP 往返，
    /// 不是到服务器的 TCP 握手（后者会把「服务器活着但节点已过期」也报成绿灯）。
    /// </summary>
    public async Task<DelayResult> DelayAsync(string proxy, string testUrl, int timeoutMs = DefaultTimeoutMs,
        CancellationToken ct = default)
    {
        var url = $"/proxies/{Uri.EscapeDataString(proxy)}/delay?url={Uri.EscapeDataString(testUrl)}"
                  + $"&timeout={timeoutMs}";
        try
        {
            using var resp = await _http.SendAsync(New(HttpMethod.Get, url), ct).ConfigureAwait(false);
            var text = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode)
            {
                var msg = TryMessage(text) ?? $"HTTP {(int)resp.StatusCode}";
                return new DelayResult(proxy, -1,
                    resp.StatusCode == HttpStatusCode.GatewayTimeout ? DelayState.Timeout : DelayState.Failed,
                    Explain(msg, (int)resp.StatusCode));
            }
            var delay = JsonNode.Parse(text)?["delay"]?.GetValue<int>() ?? -1;
            return new DelayResult(proxy, delay, delay > 0 ? DelayState.Ok : DelayState.Failed,
                delay > 0 ? null : "内核返回 0：这条节点没能建链");
        }
        catch (OperationCanceledException) { return new DelayResult(proxy, -1, DelayState.Untested, "已取消"); }
        catch (Exception e) { return new DelayResult(proxy, -1, DelayState.Failed, Explain(e.Message, 0)); }
    }

    /// <summary>把内核的英文报错翻译成人话。</summary>
    public static string Explain(string raw, int status)
    {
        var message = raw ?? "";
        var t = message.ToLowerInvariant();
        if (t.Contains("timeout") || t.Contains("deadline") || status == 504)
            return "超时：代理建链后 5 秒内没等到目标站点响应（节点慢或测速地址被墙，可换测速地址）";
        if (t.Contains("no such host") || t.Contains("server misbehaving") || t.Contains("lookup"))
            return "域名解析失败：内核 DNS 没配好，或这个节点的域名解析不出来";
        if (t.Contains("connection refused"))
            return "节点端口不通：机场大概率已经换了这个端口/下线，请更新订阅";
        if (t.Contains("tls handshake") || t.Contains("certificate") || t.Contains("x509"))
            return "TLS 握手失败：节点的证书/SNI 配置和本机对不上";
        if (t.Contains("received status code") || t.Contains("unexpected status"))
            return "节点能连，但测速地址返回了非 2xx：多半是被目标站点风控，换个测速地址再试";
        if (t.Contains("proxy authentication") || t.Contains("407"))
            return "节点需要认证信息，订阅里缺字段";
        if (t.Contains("no such proxy") || status == 404)
            return "内核里没有这个节点：订阅已变更，请点「更新」";
        if (t.Contains("unauthorized") || status == 401)
            return "控制密钥不一致：需要重启内核";
        if (t.Contains("no route to host") || t.Contains("network is unreachable") || t.Contains("unreachable"))
            return "本机到节点服务器的网络不通：检查网络或换节点";
        return message;
    }

    private static string? TryMessage(string text)
    {
        try { return JsonNode.Parse(text)?["message"]?.GetValue<string>(); }
        catch { return null; }
    }

    /// <summary>
    /// 并发测速：限流 min(10, n) 并且每个请求错峰 0-200ms（Clash Verge / FlClash 同款收敛口径）。
    /// 每完成一个就往外报，UI 才能显「12/40」；排序留给调用方在整批结束后做一次。
    /// </summary>
    public async Task<IReadOnlyList<DelayResult>> DelayManyAsync(IEnumerable<string> proxies, string testUrl,
        int concurrency = DefaultConcurrency, int timeoutMs = DefaultTimeoutMs,
        Action<DelayResult>? onEach = null, CancellationToken ct = default)
    {
        var list = proxies.ToList();
        using var gate = new SemaphoreSlim(Math.Clamp(concurrency, 1, Math.Max(1, list.Count)));
        var tasks = list.Select(async p =>
        {
            await gate.WaitAsync(ct).ConfigureAwait(false);
            DelayResult r;
            try
            {
                await Task.Delay(Random.Shared.Next(0, 200), ct).ConfigureAwait(false);
                r = await DelayAsync(p, testUrl, timeoutMs, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { r = new DelayResult(p, -1, DelayState.Untested, "已取消"); }
            finally { gate.Release(); }
            onEach?.Invoke(r);
            return r;
        });
        return await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    public async Task<Snapshot> SnapshotAsync(CancellationToken ct = default)
    {
        try
        {
            var n = await GetJsonAsync("/connections", ct).ConfigureAwait(false);
            return ParseSnapshot(n);
        }
        catch (OperationCanceledException) { throw; }
        catch { return new Snapshot(0, 0, Array.Empty<Connection>()); }
    }

    internal static Snapshot ParseSnapshot(JsonNode? root)
    {
        var list = new List<Connection>();
        var arr = root?["connections"]?.AsArray();
        if (arr != null)
            foreach (var item in arr)
            {
                var meta = item?["metadata"];
                var chain = new List<string>();
                if (item?["chains"] is JsonArray c)
                    foreach (var s in c)
                    {
                        // 本内核是字符串数组；老 Clash 是 {runtime:{selected}}，两种都能读。
                        var text = s is JsonArray or JsonObject
                            ? (s?["runtime"]?["selected"]?.GetValue<string>() ?? "")
                            : (s?.GetValue<string>() ?? "");
                        if (text.Length > 0) chain.Add(text);
                    }
                list.Add(new Connection(
                    item?["id"]?.GetValue<string>() ?? "",
                    chain.Count > 0 ? chain[0] : "",
                    meta?["host"]?.GetValue<string>() ?? "",
                    meta?["destinationIP"]?.GetValue<string>() ?? "",
                    ReadInt(meta?["destinationPort"]),
                    meta?["process"]?.GetValue<string>() ?? "",
                    meta?["network"]?.GetValue<string>() ?? "",
                    item?["rule"]?.GetValue<string>() ?? "",
                    DateTime.TryParse(item?["start"]?.GetValue<string>(), out var st) ? st : DateTime.MinValue,
                    ReadLong(item?["upload"]), ReadLong(item?["download"])));
            }
        return new Snapshot(ReadLong(root?["uploadTotal"]), ReadLong(root?["downloadTotal"]), list);
    }

    private static int ReadInt(JsonNode? node)
    {
        if (node == null) return 0;
        try { return node.GetValue<int>(); }
        catch
        {
            var s = node.ToJsonString().Trim('"');
            return int.TryParse(s, out var v) ? v : 0;
        }
    }

    private static long ReadLong(JsonNode? node)
    {
        if (node == null) return 0;
        try { return node.GetValue<long>(); }
        catch { return long.TryParse(node.ToJsonString().Trim('"'), out var v) ? v : 0; }
    }

    public async Task<bool> CloseConnectionAsync(string id, CancellationToken ct = default)
    {
        try
        {
            using var resp = await _http.SendAsync(
                New(HttpMethod.Delete, "/connections/" + Uri.EscapeDataString(id)), ct).ConfigureAwait(false);
            return resp.IsSuccessStatusCode;
        }
        catch { return false; }
    }

    public async Task<bool> CloseAllConnectionsAsync(CancellationToken ct = default)
    {
        try
        {
            using var resp = await _http.SendAsync(New(HttpMethod.Delete, "/connections"), ct).ConfigureAwait(false);
            return resp.IsSuccessStatusCode;
        }
        catch { return false; }
    }

    public void Dispose() => _http.Dispose();
}
