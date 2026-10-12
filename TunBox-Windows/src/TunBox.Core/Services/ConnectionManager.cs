using TunBox.Core.Api;
using TunBox.Core.Config;
using TunBox.Core.Fetching;
using TunBox.Core.Geo;
using TunBox.Core.Models;
using TunBox.Core.Parsing;
using TunBox.Core.Runtime;
using TunBox.Core.Storage;

namespace TunBox.Core.Services;

/// <summary>
/// Disconnected = 内核没跑；Standby = 内核在跑、控制器可达，但没接管流量；
/// Connected = 已接管。与 Clash Verge / Mihomo Party 同一形态：内核常驻待命，
/// 测速、切节点、看连接都不需要先「连接」，点连接只是把流量接过来。
/// </summary>
public enum TunnelState { Disconnected, Standby, Connecting, Connected, Error }

/// <summary>
/// 连接编排：生成配置 → 拉起内核 → 等控制器就绪 → 按需开系统代理 / TUN。
/// 断开按相反顺序，任何一步失败都要把系统代理摘掉，
/// 否则用户会留下一个指向死端口的系统代理。
/// </summary>
public sealed class ConnectionManager : IDisposable
{
    private readonly Workspace _ws;
    private readonly CoreHost _host;
    public ControllerClient Api { get; } = new();

    public event Action? Changed;
    public string? LastError { get; private set; }
    public ProxyDropStats? LastDrop { get; private set; }

    public TunnelState State { get; private set; } = TunnelState.Disconnected;

    /// <summary>内核进程活着且控制器可达（待命或已连接都算）。</summary>
    public bool CoreAlive => State is TunnelState.Connected or TunnelState.Standby;

    /// <summary>虚拟网卡是否真的建起来了（只在 TunEnabled 时有意义）。</summary>
    public bool TunActive { get; private set; }
    public IReadOnlyList<ProxyNode> Nodes => _lib.Nodes;
    public IReadOnlyList<ProxyGroup> Groups => _lib.Groups;
    public IReadOnlyList<Subscription> Subscriptions => _lib.Subscriptions;
    public AppSettings Settings { get; private set; }
    public IReadOnlyList<string> ImportWarnings { get; private set; } = Array.Empty<string>();

    /// <summary>热重载没谈拢时留下的那句话，UI 拿来解释「为什么还要下次连接才生效」。</summary>
    public string? PendingConfigNote { get; private set; }

    private NodeLibrary _lib;

    public ConnectionManager(Workspace workspace)
    {
        _ws = workspace;
        Settings = _ws.LoadSettings();
        _lib = _ws.LoadNodes();
        // 孤儿清理：订阅被删后残留的节点会让「计数 24、列表 12」——两套账必须对齐。
        var liveSubIds = _lib.Subscriptions.Select(s => s.Id).ToHashSet(StringComparer.Ordinal);
        _lib.Nodes.RemoveAll(n => !liveSubIds.Contains(n.SubscriptionId));
        _lib.Groups.RemoveAll(g => !liveSubIds.Contains(g.SubscriptionId));
        // 老数据里跨订阅重复的 id 在启动这一刻就治好并落盘（否则 PROXY 成员表会少节点，
        // 用户点那些节点就被内核拒「proxy not exist」）。
        if (EnsureUniqueIds(_lib.Nodes)) PersistNodes();
        Api.Configure(Settings.ApiPort, Settings.ApiSecret);
        // 先把随程序发布的 LightGBM 模型放进内核 home：不放到时候 smart 组不发射，
        // 界面上「自动选择」这一条会凭空消失（要等第一次 BuildConfig 才补上，太晚了）。
        _ws.EnsureSmartModelInPlace();
        _host = new CoreHost(_ws.RuntimeDir);
        _host.StateChanged += s =>
        {
            if (s != CoreState.Failed || State == TunnelState.Disconnected) return;
            State = TunnelState.Error;
            LastError = "内核异常退出，已停止自动恢复。" + _host.TailLog(4);
            TryDisableProxy();
            Changed?.Invoke();
        };
        _ws.GeoAssets.ProxyProvider = () => CoreAlive && Settings.MixedPort > 0
            ? $"http://127.0.0.1:{Settings.MixedPort}" : null;
        _ws.GeoAssets.AdRulesWanted = Settings.RulesEnabled && Settings.AdRulesEnabled;
        _ws.GeoAssets.Changed += () => Changed?.Invoke();
    }

    public GeoAssetStore GeoAssets => _ws.GeoAssets;
    public bool IsConnected => State == TunnelState.Connected;

    /// <summary>连接成功后核对系统代理真的写上了：注册表写失败不该静默成「已接管却没生效」。</summary>
    public bool EnsureSystemProxy()
    {
        var port = Settings.SystemProxyPort();
        if (!Settings.SystemProxyEnabled || port <= 0) return true;
        if (SystemProxy.IsEnabled()) return true;
        SystemProxy.Enable(port);
        return SystemProxy.IsEnabled();
    }

    public void RenameSubscription(string id, string newName)
    {
        var sub = _lib.Subscriptions.FirstOrDefault(s => s.Id == id);
        if (sub == null || string.IsNullOrWhiteSpace(newName)) return;
        sub.Name = newName.Trim();
        PersistNodes();
        Changed?.Invoke();
    }

    /// <summary>编辑订阅：改名 / 改订阅链接（改链接后点「更新」就会拉新地址）。</summary>
    public bool UpdateSubscriptionMeta(string id, string newName, string newUrl)
    {
        var sub = _lib.Subscriptions.FirstOrDefault(s => s.Id == id);
        if (sub == null) return false;
        var changed = false;
        if (!string.IsNullOrWhiteSpace(newName) && sub.Name != newName.Trim())
        {
            sub.Name = newName.Trim();
            changed = true;
        }
        if (newUrl != null && sub.Url != newUrl.Trim())
        {
            sub.Url = newUrl.Trim();
            changed = true;
        }
        if (!changed) return true;
        PersistNodes();
        Changed?.Invoke();
        return true;
    }

    /// <summary>从本地 yaml/yml/txt/conf 文件导入：内容就是订阅原文，名字用文件名。</summary>
    public async Task<bool> ImportFileAsync(string path, CancellationToken ct = default)
    {
        try
        {
            var content = await File.ReadAllTextAsync(path, ct).ConfigureAwait(false);
            if (content.Trim().Length == 0)
            {
                LastError = "文件是空的";
                Changed?.Invoke();
                return false;
            }
            var sub = new Subscription
            {
                Id = Guid.NewGuid().ToString("N"),
                Name = Path.GetFileNameWithoutExtension(path),
                Url = "",
            };
            ReplaceSubscriptionNodes(sub, content);
            if (!_lib.Nodes.Any(n => n.SubscriptionId == sub.Id))
            {
                LastError = "文件里没解析出任何可用节点（不是 yaml 订阅，或只有 proxy-providers）。";
                Changed?.Invoke();
                return false;
            }
            _lib.Subscriptions.Add(sub);
            PersistNodes();
            LastError = null;
            Changed?.Invoke();
            return true;
        }
        catch (Exception e)
        {
            LastError = "导入文件失败：" + e.Message;
            Changed?.Invoke();
            return false;
        }
    }

    // ── 订阅导入 ─────────────────────────────────────────────────────────

    /// <summary>从 URL 更新订阅。失败时保留既有节点，绝不清空库。</summary>
    public async Task<bool> RefreshSubscriptionAsync(string subscriptionId, CancellationToken ct = default)
    {
        var sub = _lib.Subscriptions.FirstOrDefault(s => s.Id == subscriptionId);
        if (sub == null) { LastError = "订阅不存在"; Changed?.Invoke(); return false; }
        if (string.IsNullOrEmpty(sub.Url))
        {
            LastError = "这条订阅是本地粘贴导入的，没有可拉取的地址";
            Changed?.Invoke();
            return false;
        }
        try
        {
            var fetched = await SubscriptionFetcher.FetchAsync(sub.Url, sub.CustomUserAgent, sub.Etag, ct).ConfigureAwait(false);
            if (fetched.NotModified)
            {
                sub.UpdatedAtMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                PersistNodes();
                LastError = null;
                Changed?.Invoke();
                return true;
            }
            ReplaceSubscriptionNodes(sub, fetched.Body);
            if (!_lib.Nodes.Any(n => n.SubscriptionId == sub.Id))
            {
                LastError = "更新后没有解析出任何可用节点，已保留上一次的节点库";
                Changed?.Invoke();
                return false;
            }
            sub.Etag = fetched.Etag;
            ApplyUserInfo(sub, fetched);
            PersistNodes();
            LastError = null;
            Changed?.Invoke();
            return true;
        }
        catch (Exception e)
        {
            LastError = $"更新订阅失败：{e.Message}";
            Changed?.Invoke();
            return false;
        }
    }

    /// <summary>添加订阅：给 URL 就联网拉，给节点链接文本就直接解析。失败必须留下可读原因。</summary>
    public async Task<bool> AddSubscriptionAsync(string urlOrContent, CancellationToken ct = default)
    {
        var input = (urlOrContent ?? "").Trim();
        if (input.Length == 0) { LastError = "输入为空"; Changed?.Invoke(); return false; }

        var isUrl = Uri.TryCreate(input, UriKind.Absolute, out var uri)
                    && (uri!.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps);
        var localCount = _lib.Subscriptions.Count(s => string.IsNullOrEmpty(s.Url)) + 1;
        var sub = new Subscription
        {
            Id = Guid.NewGuid().ToString("N"),
            Name = isUrl ? uri!.Host : $"本地导入 {localCount}",
            Url = isUrl ? input : "",
        };
        try
        {
            var content = input;
            if (isUrl)
            {
                var fetched = await SubscriptionFetcher.FetchAsync(input, null, "", ct).ConfigureAwait(false);
                content = fetched.Body;
                ApplyUserInfo(sub, fetched);
                sub.Etag = fetched.Etag;
            }
            ReplaceSubscriptionNodes(sub, content);
            if (!_lib.Nodes.Any(n => n.SubscriptionId == sub.Id))
            {
                LastError = "订阅内容里没解析出任何可用节点（格式不支持，或这是一页提示文字："
                    + "常见于链接需要登录、被面板按客户端 UA 拦截）。也可以把节点链接直接粘贴进来。";
                Changed?.Invoke();
                return false;
            }
            _lib.Subscriptions.Add(sub);
            PersistNodes();
            LastError = null;
            Changed?.Invoke();
            return true;
        }
        catch (Exception e)
        {
            LastError = (isUrl ? "拉取订阅失败：" : "解析失败：") + e.Message;
            Changed?.Invoke();
            return false;
        }
    }

    private static void ApplyUserInfo(Subscription sub, SubscriptionFetcher.FetchResult fetched)
    {
        sub.UploadBytes = fetched.UploadBytes;
        sub.DownloadBytes = fetched.DownloadBytes;
        sub.TotalBytes = fetched.TotalBytes;
        sub.ExpireAtMs = fetched.ExpireAtMs;
        sub.UpdateIntervalMinutes = fetched.UpdateIntervalMinutes;
    }

    private void ReplaceSubscriptionNodes(Subscription sub, string content)
    {
        var parsed = SubscriptionParser.Parse(content, sub.Id);
        ImportWarnings = parsed.Warnings;
        // id 必须全库唯一：解析器是按订阅各自从 n1 编号的，多条订阅一合并就撞车 ——
        // 「选中的节点」按 id 反查会挑到别家订阅的同名编号，而生成 PROXY 成员时
        // `n.Id != selected.Id` 会把所有同 id 的节点一起剔掉，内核于是回 400「proxy not exist」，
        // 用户看到的是「点了节点没反应」或「说节点刚下线」。
        var prefix = sub.Id.Length >= 8 ? sub.Id[..8] : sub.Id;
        var seq = 0;
        foreach (var n in parsed.Nodes) n.Id = $"{prefix}-n{++seq}";
        _lib.Nodes.RemoveAll(n => n.SubscriptionId == sub.Id);
        _lib.Groups.RemoveAll(g => g.SubscriptionId == sub.Id);
        _lib.Nodes.AddRange(parsed.Nodes);
        _lib.Groups.AddRange(parsed.Groups);
        EnsureUniqueIds(_lib.Nodes);   // 顺手把老数据里已经撞掉的 id 治好（升级后第一次更新订阅即生效）
        sub.UpdatedAtMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    }

    /// <summary>给重复/空缺的 id 重新编号；返回是否改过（改过就要落盘）。</summary>
    internal static bool EnsureUniqueIds(List<ProxyNode> nodes)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var changed = false;
        var salt = 0;
        foreach (var n in nodes)
        {
            if (n.Id.Length > 0 && seen.Add(n.Id)) continue;
            string id;
            do { id = $"node-{++salt:x}"; } while (!seen.Add(id));
            n.Id = id;
            changed = true;
        }
        return changed;
    }

    public void RemoveSubscription(string id)
    {
        _lib.Subscriptions.RemoveAll(s => s.Id == id);
        _lib.Nodes.RemoveAll(n => n.SubscriptionId == id);
        _lib.Groups.RemoveAll(g => g.SubscriptionId == id);
        PersistNodes();
        Changed?.Invoke();
    }
    public void SaveSettings()
    {
        PersistSettings();
        Api.Configure(Settings.ApiPort, Settings.ApiSecret);
        _ws.GeoAssets.AdRulesWanted = Settings.RulesEnabled && Settings.AdRulesEnabled;
        Changed?.Invoke();
    }

    /// <summary>落盘失败不能静默：订阅此刻只在内存里，用户看到的却是「导入成功」。</summary>
    public string? SaveWarning { get; private set; }

    private bool PersistNodes()
    {
        if (_ws.SaveNodes(_lib)) { SaveWarning = null; return true; }
        SaveWarning = "没能写入磁盘：" + _ws.HomeDir + " 不可写。现在能用，但关掉程序就会丢订阅和节点。";
        return false;
    }

    private bool PersistSettings()
    {
        if (_ws.SaveSettings(Settings)) { SaveWarning = null; return true; }
        SaveWarning = "设置没能写入磁盘：" + _ws.HomeDir + " 不可写，重启后会回到上次的设置。";
        return false;
    }

    // ── 连接生命周期 ─────────────────────────────────────────────────────

    public Task<bool> EnsureStandbyAsync(CancellationToken ct = default) => StartAsync(standby: true, ct);
    public Task<bool> ConnectAsync(CancellationToken ct = default) => StartAsync(standby: false, ct);

    private async Task<bool> StartAsync(bool standby, CancellationToken ct)
    {
        if (standby && CoreAlive) return true;
        if (!standby && State == TunnelState.Connected) return true;

        // 一个节点都没有不是「异常」：直接说明原因，别把状态机推进 Error 让界面亮红。
        if (_lib.Nodes.Count == 0)
        {
            LastError = "还没有可用节点，先到「订阅」页导入。";
            Changed?.Invoke();
            return false;
        }

        var wasAlive = CoreAlive;
        State = TunnelState.Connecting;
        LastError = null;
        Changed?.Invoke();
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var phases = new List<string>();
        try
        {
            Preflight(standby, spawnNew: !wasAlive);
            var yaml = BuildConfig(tunForcedOff: standby);
            phases.Add($"预检+生成 {sw.ElapsedMilliseconds}ms");

            // 待命 → 连接 = 一次热重载：整份配置 PUT /configs 就能把 fake-ip 等打开，不断连接。
            // Stop+Start 等于把冷启动、断连接、重建网卡全串进用户那一次点击里 ——
            // 内核实测 42ms 就能监听，慢的一直是我们自己。
            var how = "原地复用";
            if (!_host.IsRunningWith(yaml)) how = await BringUpAsync(yaml, wasAlive, ct).ConfigureAwait(false);
            phases.Add($"{how} {sw.ElapsedMilliseconds}ms");

            if (standby)
            {
                State = TunnelState.Standby;
                Changed?.Invoke();
                KickWarmup();
                return true;
            }

            EnableSystemProxyIfWanted();
            // mode 已经写在那份配置里了，这次调用只是兜底；等它 = 在回环 HTTP 被拦的机器上
            // 白等一个 HttpClient 超时，所以放后台。全局模式还要顺手把 GLOBAL 钉到出口节点上。
            Watch(ApplyEgressAsync(ct));
            TunActive = Settings.TunEnabled && TunAdapter.IsReady(ClashConfigGenerator.TunDeviceName);
            State = TunnelState.Connected;
            LastTiming = string.Join(" · ", phases) + $" · 已接管 {sw.ElapsedMilliseconds}ms";
            Changed?.Invoke();
            // 网卡核对移出这次点击：实测驱动 363ms 才把设备建出来，串行的话开关就会「卡一下」，
            // 而它失败也只是状态行晚一点变红，不影响「已接管」这件事本身。
            _ = FinishTunCheckAsync(ct);
            KickWarmup();
            return true;
        }
        catch (Exception e)
        {
            LastError = e.Message;
            TunActive = false;
            _host.Stop();
            TryDisableProxy();
            State = TunnelState.Error;
            Changed?.Invoke();
            return false;
        }
    }

    /// <summary>最近一次点开关的分段耗时（毫秒）。排障字段：不再上状态栏（用户嫌吵），
    /// 留给日志与诊断——「慢」必须能被说清在哪一段。</summary>
    public string? LastTiming { get; private set; }

    /// <summary>
    /// 让内核换到这份配置：能热重载就热重载（不断连接），否则重启。
    ///
    /// 唯一的例外是「这次要把虚拟网卡打开」：实测热重载时网卡 15s 才就绪，
    /// 而带 TUN 重启内核 363ms 就好 —— 为了保住几条连接把用户卡 15 秒不值。
    /// </summary>
    private async Task<string> BringUpAsync(string yaml, bool wasAlive, CancellationToken ct)
    {
        var tunTurnedOn = Settings.TunEnabled && !_host.RunningTunEnabled;
        if (wasAlive && !tunTurnedOn && await TryHotReloadAsync(yaml, ct).ConfigureAwait(false)) return "热重载";
        if (wasAlive) _host.Stop();
        await _host.StartWithParamsAsync(yaml, Settings.ApiPort, Settings.ApiSecret, ct).ConfigureAwait(false);
        return tunTurnedOn ? "重启内核·开网卡" : "重启内核";
    }

    /// <summary>
    /// 整份配置热重载：成功就不必重启内核。
    /// 预算 6s（要重建网卡的变更内核自己就要忙一会儿），超时必须咽下来退回重启 ——
    /// 让它逃出去就是用户看到的「未处理的异常：The operation was canceled」弹窗。
    /// </summary>
    private async Task<bool> TryHotReloadAsync(string yaml, CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(6));
        bool ok;
        string? error;
        try
        {
            (ok, error) = await Api.UpdateConfigAsync(yaml, timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) { ok = false; error = "热重载超时（6s）"; }
        catch (Exception e) { ok = false; error = e.Message; }
        if (!ok)
        {
            PendingConfigNote = "内核没接受这次热重载（" + error + "），改用重启内核生效。";
            return false;
        }
        _host.SaveConfig(yaml);
        PendingConfigNote = null;
        return true;
    }

    /// <summary>后台核对虚拟网卡到底建起来没有，并把结果落到状态行。</summary>
    private async Task FinishTunCheckAsync(CancellationToken ct)
    {
        if (!Settings.TunEnabled)
        {
            TunActive = false;
            TunPending = false;
            return;
        }
        try
        {
            // 预算要盖住内核自己的重试：真机日志里第一次建卡报
            // 「create adapter: Cannot create a file when that file already exists | open existing adapter:
            //  Element not found [retrying 1/3]」，1 秒后重试就成功了「Tun adapter listening at: TunBox」。
            // 只等 8 秒的话，网卡明明起来了却被我们判成「没起来」。
            TunPending = true;
            Changed?.Invoke();
            var up = await Task.Run(() => TunAdapter.WaitFor(
                ClashConfigGenerator.TunDeviceName, TimeSpan.FromSeconds(30), ct), ct).ConfigureAwait(false);
            TunActive = up;
            TunPending = false;
            // 内核建卡失败只打一行日志就静默关掉 TUN：不核对 + 不引用原话，用户就只能看到「已接管」。
            if (!up) LastError = "虚拟网卡没能创建：" + ExplainTunFailure(_host.TailLog(6))
                + " 内核原话：" + TailLine(_host.TailLog(6));
        }
        catch (Exception e)
        {
            TunPending = false;
            LastError = "虚拟网卡状态没核对成：" + e.Message;
        }
        Changed?.Invoke();
    }

    /// <summary>发出去就不管的调用：异常必须被观察，否则变成未观察任务异常。</summary>
    private static void Watch(Task task) =>
        _ = task.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted);

    /// <summary>动手之前先把「一定会失败」的情况拦在启动内核之前。</summary>
    private void Preflight(bool standby, bool spawnNew)
    {
        var problem = LocalPorts.Validate(Settings);
        if (problem.Length > 0) throw new InvalidOperationException("本地代理设置有问题：" + problem);
        if (!standby && Settings.TunEnabled)
        {
            var blocker = Elevation.TunBlocker();
            if (blocker.Length > 0) throw new InvalidOperationException(blocker);
        }
        // 端口预检只在「要另起一个进程」时做：待命中的内核自己就监听在这些端口上，
        // 一起床就报「端口 7890 已被其他程序占用」，把「待命 → 连接」这条路直接打死（实测）。
        if (!spawnNew) return;
        var occupied = LocalPorts.FirstOccupied(Settings);
        if (occupied > 0)
            throw new InvalidOperationException(
                $"端口 {occupied} 已被其他程序占用（可能有一个没退干净的内核），换个端口或重启电脑再连。");
    }

    private static string ExplainTunFailure(string tail)
    {
        var t = tail.ToLowerInvariant();
        if (t.Contains("privilege") || t.Contains("access is denied") || t.Contains("denied"))
            return "系统权限不够：请在「设置」里以管理员重启后再连。";
        if (t.Contains("wintun") || t.Contains("module") || t.Contains("driver"))
            return "wintun 驱动组件没装上或被安全软件拦了；确认 core 目录完整、允许驱动安装后重试。";
        return $"系统里等 8s 也没出现「{ClashConfigGenerator.TunDeviceName}」网卡。";
    }

    private static string TailLine(string tail)
    {
        var idx = tail.LastIndexOf("level=error", StringComparison.Ordinal);
        var line = idx >= 0 ? tail.Substring(idx) : tail;
        var cut = line.IndexOf('\n');
        line = cut > 0 ? line[..cut] : line;
        return line.Length > 240 ? line[..240] : line;
    }

    private void EnableSystemProxyIfWanted()
    {
        var port = Settings.SystemProxyPort();
        // TUN-only 的用户故意不要动系统代理：接管靠网卡路由。
        if (!Settings.SystemProxyEnabled || port <= 0) return;
        SystemProxy.Enable(port);
    }

    /// <summary>断开 = 不再接管流量，不等于关掉内核。TUN 必须靠重启拆网卡，这时才真的停进程。</summary>
    public async Task DisconnectAsync()
    {
        Watch(Api.CloseAllConnectionsAsync());
        TryDisableProxy();
        var wantedTun = TunActive || Settings.TunEnabled;
        var wasError = State == TunnelState.Error;
        TunActive = false;
        TunPending = false;
        LastError = null;

        // 拆网卡不必杀进程：把「TUN 关掉」的那份配置热重载回去，内核自己把设备删掉，进程留在待命。
        // 这样下一次点开关是毫秒级 —— 之前这里是整进程 Stop + 冷启动，用户每开关一次都要重付一遍。
        // 整段兜住：断开路径上抛出去的就是用户看到的「未处理的异常」弹窗。
        if (wantedTun && CoreAlive)
        {
            var reloaded = false;
            try
            {
                reloaded = await TryHotReloadAsync(BuildConfig(tunForcedOff: true), CancellationToken.None)
                    .ConfigureAwait(false) && await TunGoneAsync().ConfigureAwait(false);
            }
            catch (Exception e) { LastError = "停止接管时热重载没成：" + e.Message; }
            if (reloaded)
            {
                State = TunnelState.Standby;
                Changed?.Invoke();
                return;
            }
            _host.Stop();
            State = TunnelState.Disconnected;
            Changed?.Invoke();
            return;
        }
        if (wasError)
        {
            _host.Stop();
            State = TunnelState.Disconnected;
        }
        else State = CoreAlive ? TunnelState.Standby : TunnelState.Disconnected;
        Changed?.Invoke();
    }

    /// <summary>热重载说成功不算数：网卡真的从系统里消失才算（内核偶尔会留着旧设备）。</summary>
    private static async Task<bool> TunGoneAsync()
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(2);
        while (DateTime.UtcNow < deadline)
        {
            if (!TunAdapter.Exists(ClashConfigGenerator.TunDeviceName)) return true;
            await Task.Delay(100).ConfigureAwait(false);
        }
        return !TunAdapter.Exists(ClashConfigGenerator.TunDeviceName);
    }

    public async Task StopCoreAsync()
    {
        _host.Stop();
        TryDisableProxy();
        TunActive = false;
        TunPending = false;
        State = TunnelState.Disconnected;
        Changed?.Invoke();
        await Task.CompletedTask;
    }

    /// <summary>设置改完的收尾：配置真变了才动内核。</summary>
    public async Task<bool> ReconnectAsync(CancellationToken ct = default)
    {
        if (State == TunnelState.Connected) return await ConnectAsync(ct).ConfigureAwait(false);
        if (State == TunnelState.Standby) return await EnsureStandbyAsync(ct).ConfigureAwait(false);
        return true;
    }

    /// <summary>
    /// 规则类变更优先热重载（PUT /configs 的 payload 形式，不断连接）；
    /// 内核拒收再退回重启。已建好的连接不该因为「用户加了一条规则」被掐掉。
    /// </summary>
    public async Task<bool> ApplyChangesAsync(CancellationToken ct = default)
    {
        if (!CoreAlive) return true;
        var standby = State == TunnelState.Standby;
        var yaml = BuildConfig(tunForcedOff: standby);
        if (_host.IsRunningWith(yaml)) return true;

        // 规则类变更走热重载（不断连接）；内核拒收或这次要开网卡才重启。
        // 这里抛出去就是界面层的「未处理的异常」弹窗，所以兜住并说清失败原因。
        try
        {
            var how = await BringUpAsync(yaml, wasAlive: true, ct).ConfigureAwait(false);
            LastApplyNote = how;
        }
        catch (Exception e)
        {
            LastError = "改动没生效：" + e.Message;
            Changed?.Invoke();
            return false;
        }
        if (!standby) State = TunnelState.Connected;
        // 配置一重建，组选择就回到默认值：先按回用户的出口，再去核对网卡
        await ApplyEgressAsync(ct).ConfigureAwait(false);
        // 网卡核对放后台：拨一下开关先等满 30s 预算的话，「立刻接管」就白做了。
        _ = FinishTunCheckAsync(ct);
        Changed?.Invoke();
        return true;
    }

    /// <summary>最近一次生效变更走的是哪条路（热重载 / 重启内核 / 重启内核·开网卡）。</summary>
    public string? LastApplyNote { get; private set; }

    private void TryDisableProxy()
    {
        try { SystemProxy.Disable(); }
        catch (Exception e) { LastError = "系统代理恢复失败：" + e.Message; }
    }

    public string BuildConfig(bool tunForcedOff = false)
    {
        _ws.EnsureSmartModelInPlace();
        // 内核即将启动这一刻没人映射着库文件，把下载好但没换掉的库换上。
        GeoAssets.ApplyPendingSwaps();
        var generator = ClashConfigGenerator.Generate(_lib.Nodes, _lib.Groups, Settings, _ws.DetectGates(),
            tunOverride: tunForcedOff ? false : null);
        LastDrop = ClashConfigGenerator.LastDropStats;
        return generator;
    }

    // ── 后台补件（分流库）────────────────────────────────────────────────

    /// <summary>后台补分流库，绝不进连接关键路径；补齐后热重载接上新规则。</summary>
    private void KickWarmup()
    {
        _ = Task.Run(async () =>
        {
            try
            {
                GeoAssets.AdRulesWanted = Settings.RulesEnabled && Settings.AdRulesEnabled;
                if (await GeoAssets.EnsureAllAsync().ConfigureAwait(false))
                    await ApplyAfterGeoLanded().ConfigureAwait(false);
            }
            catch (Exception e) { LastError = "分流库下载失败：" + e.Message; Changed?.Invoke(); }
        });
    }

    public async Task<bool> RefreshGeoAsync()
    {
        try
        {
            GeoAssets.AdRulesWanted = Settings.RulesEnabled && Settings.AdRulesEnabled;
            var landed = await GeoAssets.RefreshAllAsync().ConfigureAwait(false);
            if (landed) await ApplyAfterGeoLanded().ConfigureAwait(false);
            Changed?.Invoke();
            return landed;
        }
        catch (Exception e)
        {
            LastError = "更新分流库失败：" + e.Message;
            Changed?.Invoke();
            return false;
        }
    }

    /// <summary>分流库落好了：立刻生效。热重载谈不拢就自动重启内核，绝不留到「下次连接」。</summary>
    private async Task ApplyAfterGeoLanded()
    {
        if (!CoreAlive) return;
        try
        {
            // 新库换不掉是因为内核把它映射在内存里 —— 想马上生效就得先停它一下，
            // 停掉的那一刻 BuildConfig 里的 ApplyPendingSwaps 才换得动。
            var restartForSwap = _ws.GeoAssets.HasPendingSwap;
            if (restartForSwap) _host.Stop();
            var yaml = BuildConfig(tunForcedOff: State == TunnelState.Standby);
            if (!restartForSwap && _host.IsRunningWith(yaml)) return;
            LastApplyNote = await BringUpAsync(yaml, wasAlive: !restartForSwap, CancellationToken.None)
                .ConfigureAwait(false);
            if (State == TunnelState.Connected) await ApplyEgressAsync().ConfigureAwait(false);
        }
        catch (Exception e)
        {
            // 这里是后台触发，抛出去就是没人接的异常
            LastError = "分流库就位后没能生效：" + e.Message;
        }
        Changed?.Invoke();
    }

    // ── 模式与选点 ───────────────────────────────────────────────────────

    /// <summary>SelectedNodeId 的这个哨兵值 = 「出口交给 smart 组按每条连接自动择优」。</summary>
    public const string AutoEgressId = AppSettings.AutoNodeId;

    /// <summary>正在后台等虚拟网卡建起来（内核会自己重试，别在此期间报「网卡没起来」）。</summary>
    public bool TunPending { get; private set; }

    /// <summary>内核的「全局」伪分组：mode=global 时所有流量只认它在选谁。</summary>
    public const string GlobalGroup = "GLOBAL";

    /// <summary>配置里始终跟着用户选择的代理组：「全局」的出口就是它当前选中的那一项。</summary>
    public const string ProxyGroup = "PROXY";

    /// <summary>
    /// 切模式不是 `PUT /configs {"mode":…}` 就完事：这份 mihomo-smart 内核对单独的运行时字段回 204
    /// 却什么都不改（实测 mode、log-level 都照旧），只认整份 payload。
    /// 所以模式要跟着重新生成的配置热应用一遍，之后再把 GLOBAL 钉到出口上。
    /// </summary>
    public async Task<bool> SetProxyModeAsync(string mode)
    {
        Settings.ProxyMode = mode is "global" or "direct" ? mode : "rule";
        SaveSettings();
        if (!CoreAlive)
        {
            Changed?.Invoke();
            return true;
        }
        var ok = await ReapplyRunningConfigAsync().ConfigureAwait(false);
        if (ok) await ApplyEgressAsync().ConfigureAwait(false);
        else Changed?.Invoke();
        return ok;
    }

    /// <summary>把当前设置生成的配置热应用回内核（模式就在这份配置里）；内核拒收时报出来，不静默。</summary>
    private async Task<bool> ReapplyRunningConfigAsync(CancellationToken ct = default)
    {
        if (!CoreAlive) return true;
        var yaml = BuildConfig(tunForcedOff: State == TunnelState.Standby);
        if (_host.IsRunningWith(yaml)) return true;
        var (ok, error) = await Api.UpdateConfigAsync(yaml, ct).ConfigureAwait(false);
        if (ok) _host.SaveConfig(yaml);
        else LastError = "模式没能应用到内核（" + error + "），流量走向还是旧的那份。";
        return ok;
    }

    public async Task<bool> SelectNodeAsync(string name, string group = ProxyGroup)
    {
        // 点的是自动优选组 → 记哨兵值；点的是具体节点 → 记它的 id。
        // 之前只在新名字能对上节点时才更新 id，结果 settings 里长期挂着「上一个节点」，
        // 与内核实际选择各行其是（一重载就把用户打回自动选择，或反过来）。
        Settings.SelectedNodeId = name == ClashConfigGenerator.SmartGroupName
            ? AutoEgressId
            : _lib.Nodes.FirstOrDefault(n => n.Name == name)?.Id ?? Settings.SelectedNodeId;
        PersistSettings();
        if (!CoreAlive) return true;
        var ok = await Api.SelectNodeAsync(group, name).ConfigureAwait(false);
        if (!ok)
        {
            // 内核那份配置里还没这个成员（多半是配置落后于节点库，刚更新过订阅）：
            // 先把配置推过去再试一次 —— 不能拿「节点可能刚下线」去打发用户，他点的就是库里有的节点。
            if (await ReapplyRunningConfigAsync().ConfigureAwait(false))
                ok = await Api.SelectNodeAsync(group, name).ConfigureAwait(false);
            if (!ok) LastError = $"切到「{name}」没成功，流量还在走原来的出口。";
        }
        // 全局模式下用户点的名片要同时落到 GLOBAL，否则切了节点流量照旧走 GLOBAL 里那个旧选择
        await SyncGlobalEgressAsync().ConfigureAwait(false);
        return ok;
    }

    /// <summary>
    /// 全局模式光改 mode 还不够：内核在 global 下只看 GLOBAL 这个伪分组，而我们的选点全写在 PROXY 组里，
    /// GLOBAL 会一直停在初始的 DIRECT —— 真机就是这样「全局模式 IP 检测站还是国内，规则模式才是节点 IP」。
    /// </summary>
    private async Task SyncGlobalEgressAsync(CancellationToken ct = default)
    {
        if (!CoreAlive || Settings.ProxyMode != "global") return;
        var name = PickGlobalEgress(Settings.SelectedNodeId, _lib.Nodes,
            await Api.ProxiesAsync(ct).ConfigureAwait(false));
        if (name.Length > 0) await Api.SelectNodeAsync(GlobalGroup, name, ct).ConfigureAwait(false);
    }

    /// <summary>
    /// 每次配置生效之后都要走一遍。内核加载一份新配置时，PROXY 组里没有 `now` 就默认取第一个成员
    /// —— 我们排在第一位的是 ♻️ 自动选择 —— 于是「用户点了 A 节点，实际每条连接由模型挑」，
    /// 这就是「选的节点和查到的 IP 对不上」的根因。按回用户的选择，再让 GLOBAL 跟着走。
    /// </summary>
    private async Task ApplyEgressAsync(CancellationToken ct = default)
    {
        await ReassertSelectionAsync(ct).ConfigureAwait(false);
        await SyncGlobalEgressAsync(ct).ConfigureAwait(false);
        Changed?.Invoke();
    }

    /// <summary>用户想要的出口名：具体节点，或「交给自动优选」；空 = 没什么要按的。</summary>
    internal static string WantedEgress(string selectedNodeId, IReadOnlyList<ProxyNode> nodes, bool smartReady) =>
        selectedNodeId.Length == 0 || selectedNodeId == AutoEgressId
            ? smartReady ? ClashConfigGenerator.SmartGroupName : ""
            : nodes.FirstOrDefault(n => n.Id == selectedNodeId)?.Name ?? "";

    private async Task ReassertSelectionAsync(CancellationToken ct)
    {
        if (!CoreAlive) return;
        var name = WantedEgress(Settings.SelectedNodeId, _lib.Nodes, SmartGroupReady);
        if (name.Length == 0)
        {
            // 订阅更新把选中的节点删掉了：交回自动优选，别在设置里挂着一个已经不存在的 id
            if (Settings.SelectedNodeId.Length > 0 && Settings.SelectedNodeId != AutoEgressId)
            {
                Settings.SelectedNodeId = AutoEgressId;
                PersistSettings();
            }
            return;
        }
        var proxies = await Api.ProxiesAsync(ct).ConfigureAwait(false);
        if (!proxies.TryGetValue(ProxyGroup, out var proxy)) return;   // 组还没建好，别抢
        if (proxy.Now == name) return;
        if (!proxy.All.Contains(name, StringComparer.Ordinal))
        {
            // 内核跑的那份配置里没有这个节点 = 配置落后于节点库（刚更新过订阅等）：
            // 先把配置推过去再试一次，不能反过来把用户的选择判成「节点已下线」。
            if (!await ReapplyRunningConfigAsync(ct).ConfigureAwait(false)) return;
            proxies = await Api.ProxiesAsync(ct).ConfigureAwait(false);
            if (!proxies.TryGetValue(ProxyGroup, out proxy)) return;
            if (proxy.Now == name) return;
            if (!proxy.All.Contains(name, StringComparer.Ordinal))
            {
                // 两轮之后仍然没有：这个节点确实不在库里了，收回自动优选并说清楚
                Settings.SelectedNodeId = AutoEgressId;
                PersistSettings();
                LastError = $"之前选的「{name}」在当前出口列表里没有了，改走自动优选。";
                return;
            }
        }
        if (!await Api.SelectNodeAsync(ProxyGroup, name, ct).ConfigureAwait(false))
            LastError = $"切到「{name}」没成功，流量还在走原来的出口。";
    }

    /// <summary>
    /// 「全局」的出口 = PROXY 组现在选中的那一项。内核实测 GLOBAL 既能选具体节点、也能选代理组名
    /// （dial 时才解析），所以自动态直接把 ♻️ 自动选择 交给 GLOBAL，smart 的按连接择优在全局下照旧生效。
    /// 拿不到 PROXY 时才依次退回：用户选过的节点 → smart 当前的节点 → 第一个像节点的名字；
    /// 任何情况下都不许退成 DIRECT / REJECT。挑兜底名字时要避开订阅面板当成代理返回的
    /// 「剩余流量：xxx GB」这类说明行（它们连不通）。
    /// </summary>
    internal static string PickGlobalEgress(string selectedNodeId, IReadOnlyList<ProxyNode> nodes,
        Dictionary<string, (string Now, List<string> All)> proxies)
    {
        bool Routed(string n) => !string.IsNullOrEmpty(n) && n != "DIRECT" && n != "REJECT";

        if (proxies.TryGetValue(ProxyGroup, out var proxy) && Routed(proxy.Now)) return proxy.Now;

        if (selectedNodeId != AutoEgressId
            && nodes.FirstOrDefault(n => n.Id == selectedNodeId) is { } picked && Routed(picked.Name))
            return picked.Name;

        if (proxies.TryGetValue(ClashConfigGenerator.SmartGroupName, out var smart) && Routed(smart.Now))
            return smart.Now;

        return nodes.FirstOrDefault(n => Routed(n.Name) && n.Server.Length > 0
            && n.Kind != ProxyKind.Unknown)?.Name ?? "";
    }

    /// <summary>能查出口了才有意义：隧道真的接管流量（Connected）且 HTTP 入口开着。
    /// 待命也算 CoreAlive，但系统代理与 TUN 都没开 —— 那时把「流量若走内核会从哪个节点出去」
    /// 当结果摆出来，用户读成「我没开代理、流量却在走国外」，出口卡反而变成惊吓卡。</summary>
    public bool EgressQueryable => State == TunnelState.Connected && Settings.SystemProxyPort() > 0;

    /// <summary>当前走的是哪个出口（PROXY 组在 kernel 里的 now），UI 拿来核对「选的是不是就是走的」。</summary>
    public async Task<string> EgressNowAsync(CancellationToken ct = default)
    {
        if (!CoreAlive) return "";
        var proxies = await Api.ProxiesAsync(ct).ConfigureAwait(false);
        return proxies.TryGetValue(ProxyGroup, out var p) ? p.Now : "";
    }

    /// <summary>
    /// 查一次出口信息：走内核的代理端口问 ip-api，同时（可选）直连问一次本机 IP ——
    /// 两者相同就说明这个连接压根没走代理，这正是「点了节点但 IP 没变」最直接的判据。
    /// </summary>
    public async Task<EgressSnapshot> QueryEgressAsync(bool withLocal, CancellationToken ct = default)
    {
        var connected = State == TunnelState.Connected;
        string egressJson = "", localJson = "";
        string? error = null;
        try { egressJson = await EgressProbe.FetchViaProxyAsync(Settings.SystemProxyPort(), ct).ConfigureAwait(false); }
        catch (Exception e) { error = e.Message; }
        if (withLocal)
        {
            try { localJson = await EgressProbe.FetchLocalAsync(ct).ConfigureAwait(false); }
            catch { /* 本机 IP 拿不到不碍事，别把整张卡判死 */ }
        }

        var via = egressJson.Length > 0 || error != null
            ? EgressProbe.Parse(egressJson, connected, null, error)
            : EgressSnapshot.Empty;
        var local = localJson.Length > 0 ? EgressProbe.Parse(localJson, connected, null, null).EgressIp : "";
        var localIp = local.Length > 0 ? local : _localIp;
        if (local.Length > 0) _localIp = local;
        return via with { LocalIp = localIp, Connected = connected };
    }

    private string _localIp = "";

    /// <summary>组测速：结果写回模型，UI 靠状态上色。内核没跑先待命起来。</summary>
    public async Task<int> TestAllAsync(Action<DelayResult>? onEach = null, CancellationToken ct = default)
    {
        if (!CoreAlive && !await EnsureStandbyAsync(ct).ConfigureAwait(false)) return 0;
        var names = _lib.Nodes.Select(n => n.Name).Distinct().ToList();
        foreach (var n in _lib.Nodes) n.State = DelayState.Testing;
        Changed?.Invoke();
        // 每回一个结果就立刻写回模型：攒到最后才写的话，界面上「按延迟实时排序」永远等不到
        // 触发时机（用户反馈的「全部测速没生效」就是这一条 —— 排序跑的时候所有节点还都是 Testing）。
        var results = await Api.DelayManyAsync(names, Settings.TestUrl,
            ControllerClient.DefaultConcurrency, ControllerClient.DefaultTimeoutMs,
            r =>
            {
                ApplyToModel(r);
                onEach?.Invoke(r);
            }, ct).ConfigureAwait(false);
        var ok = 0;
        foreach (var n in _lib.Nodes) if (n.State == DelayState.Ok) ok++;
        PersistNodes();
        Changed?.Invoke();
        return ok;
    }

    private void ApplyToModel(DelayResult r)
    {
        var n = _lib.Nodes.FirstOrDefault(x => x.Name == r.Name);
        if (n == null) return;
        n.LastLatency = r.Ok ? r.DelayMs : -1;
        n.State = r.State;
        n.DelayError = r.Error;
    }

    /// <summary>只测一个节点（点节点卡上的延迟徽章）。</summary>
    public async Task<DelayResult?> TestNodeAsync(string name, CancellationToken ct = default)
    {
        if (!CoreAlive && !await EnsureStandbyAsync(ct).ConfigureAwait(false)) return null;
        var node = _lib.Nodes.FirstOrDefault(n => n.Name == name);
        if (node == null) return null;
        node.State = DelayState.Testing;
        Changed?.Invoke();
        var r = await Api.DelayAsync(name, Settings.TestUrl, ControllerClient.DefaultTimeoutMs, ct)
            .ConfigureAwait(false);
        node.LastLatency = r.Ok ? r.DelayMs : -1;
        node.State = r.State;
        node.DelayError = r.Error;
        Changed?.Invoke();
        return r;
    }

    public bool TunAdapterPresent() => TunAdapter.Exists(ClashConfigGenerator.TunDeviceName);

    /// <summary>
    /// smart 组这次会不会被写进配置：开了开关 + LightGBM 模型在盘上 + 至少两个节点。
    /// 与鸿蒙端同一判据 —— 缺模型时绝不发射，否则内核会在启动路径同步去 GitHub 下 Model.bin（实测阻塞 ~90s）。
    /// </summary>
    public bool SmartGroupReady => Settings.UseSmartGroup
        && _ws.DetectGates().SmartModelReady && _lib.Nodes.Count >= 2;

    public void Dispose()
    {
        _host.Dispose();
        Api.Dispose();
    }
}
