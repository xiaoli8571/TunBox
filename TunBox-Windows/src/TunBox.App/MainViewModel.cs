using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Data;
using System.Windows.Input;
using System.IO;
using TunBox.Core.Api;
using System.Windows.Media;
using TunBox.Core.Config;
using TunBox.Core.Fetching;
using TunBox.Core.Geo;
using TunBox.Core.Models;
using TunBox.Core.Runtime;
using TunBox.Core.Services;
using TunBox.Core.Storage;

namespace TunBox.App;

/// <summary>MVVM 的最小底座：通知 + 两种命令。</summary>
public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    protected void Raise([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }
}

public sealed class RelayCommand : ICommand
{
    private readonly Action<object?> _execute;
    private readonly Func<object?, bool>? _canExecute;
    public RelayCommand(Action<object?> execute, Func<object?, bool>? canExecute = null)
        => (_execute, _canExecute) = (execute, canExecute);
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => _canExecute?.Invoke(parameter) ?? true;
    public void Execute(object? parameter) => _execute(parameter);
    public void Refresh() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

public sealed class AsyncRelayCommand : ICommand
{
    private readonly Func<object?, Task> _execute;
    private readonly Func<object?, bool>? _canExecute;
    private bool _running;
    public AsyncRelayCommand(Func<object?, Task> execute, Func<object?, bool>? canExecute = null)
        => (_execute, _canExecute) = (execute, canExecute);
    public event EventHandler? CanExecuteChanged;

    /// <summary>
    /// 命令里漏出来的异常落到这里，而不是弹「未处理的异常」对话框：
    /// 用户点一下开关就吃一个模态窗，比功能没生效更让人不信任这个软件。
    /// </summary>
    public event Action<Exception>? Failed;

    /// <summary>正在跑时一律拒绝重入：连接被点两次会留下半启动的内核。</summary>
    public bool CanExecute(object? parameter) => !_running && (_canExecute?.Invoke(parameter) ?? true);
    public bool IsRunning => _running;

    /// <summary>供代码后置直接等待（async void 的 Execute 没法 await）。</summary>
    public Task ExecuteAsync(object? parameter) => RunAsync(parameter);

    private async Task RunAsync(object? parameter)
    {
        _running = true;
        Refresh();
        try
        {
            await _execute(parameter).ConfigureAwait(true);
        }
        catch (Exception e)
        {
            if (Failed != null) Failed(e);
            else Debug.WriteLine(e);
        }
        finally { _running = false; Refresh(); }
    }

    public async void Execute(object? parameter) => await RunAsync(parameter);
    public void Refresh() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

/// <summary>
/// 延迟配色照 Clash Verge 的收敛口径：&lt;250 绿 / 250-399 蓝 / ≥400 橙 / 超时与失败红 / 未测灰。
/// </summary>
public sealed class NodeItem : ObservableObject
{
    private static SolidColorBrush B(byte r, byte g, byte b)
    {
        var brush = new SolidColorBrush(System.Windows.Media.Color.FromRgb(r, g, b));
        brush.Freeze();
        return brush;
    }

    private static readonly SolidColorBrush Fast = B(0x16, 0xA3, 0x4A);
    private static readonly SolidColorBrush Good = B(0x25, 0x63, 0xEB);
    private static readonly SolidColorBrush Slow = B(0xD9, 0x77, 0x06);
    private static readonly SolidColorBrush Bad = B(0xDC, 0x26, 0x26);

    public ProxyNode Model { get; }
    public NodeItem(ProxyNode model) { Model = model; }

    public string Name => Model.Name;
    public string Kind => ClashConfigGenerator.KindSlug(Model.Kind).ToUpperInvariant();

    private bool _isSelectedNow;
    /// <summary>这一行是不是当前出口。选中态必须有视觉反馈，否则「点了没反应」。</summary>
    public bool IsSelectedNow
    {
        get => _isSelectedNow;
        set
        {
            if (Set(ref _isSelectedNow, value)) Raise(nameof(RowState));
        }
    }

    /// <summary>行背景：选中 = 品牌浅底（DataTrigger 绑它）。</summary>
    public string RowState => _isSelectedNow ? "selected" : "";

    public void Refresh()
    {
        Raise(nameof(LatencyText));
        Raise(nameof(LatencyBrush));
        Raise(nameof(LatencyTip));
    }

    public string LatencyText => Model.State switch
    {
        DelayState.Ok => $"{Model.LastLatency} ms",
        DelayState.Testing => "⚡",
        DelayState.Timeout => "超时",
        DelayState.Failed => "不通",
        _ => "-",
    };

    public System.Windows.Media.Brush LatencyBrush => Model.State switch
    {
        DelayState.Ok when Model.LastLatency < 250 => Fast,
        DelayState.Ok when Model.LastLatency < 400 => Good,
        DelayState.Ok => Slow,
        DelayState.Timeout or DelayState.Failed => Bad,
        DelayState.Testing => Slow,
        _ => System.Windows.Media.Brushes.Gray,
    };

    /// <summary>失败必须能说出原因，不然「不通」和「超时」在用户眼里是同一件事。</summary>
    public string LatencyTip => Model.State switch
    {
        DelayState.Ok => $"{Model.Name} · 延迟 {Model.LastLatency} ms，点击可重测",
        DelayState.Testing => "正在测这个节点…",
        DelayState.Untested => $"点击只测这一个节点（{Model.Server}:{Model.Port}）",
        _ => $"{Model.Name} · " + (Model.DelayError ?? "测速失败") + "（点击重试）",
    };

    public bool IsSelected => Model.Id.Length > 0;
}

/// <summary>
/// 一条订阅的手风琴卡：折叠时只占一行（名字 + 流量 + 更新时间），展开是该订阅的节点列表。
/// 与鸿蒙客户端的订阅页同形态。
/// </summary>
public sealed class SubscriptionItem : ObservableObject
{
    public Subscription Model { get; }
    public SubscriptionItem(Subscription model) { Model = model; }

    /// <summary>该订阅的节点行（全量）。实例与总表的 NodeItem 是**同一批对象**，测速结果自动跟着变。</summary>
    public System.Collections.ObjectModel.ObservableCollection<NodeItem> Nodes { get; } = new();

    /// <summary>当前页面真正显示的那一份：按选中的分组筛过。订阅上的 ⚡ 测速测的就是它。</summary>
    public System.Collections.ObjectModel.ObservableCollection<NodeItem> VisibleNodes { get; } = new();

    /// <summary>订阅声明的代理组（第一颗是「全部节点」）。点它 = 筛选，不是测速。</summary>
    public System.Collections.ObjectModel.ObservableCollection<GroupChip> Groups { get; } = new();

    private GroupChip? _activeGroup;
    public GroupChip? ActiveGroup
    {
        get => _activeGroup;
        set { if (!ReferenceEquals(_activeGroup, value)) { _activeGroup = value; ApplyFilter(); } }
    }

    private bool _isTesting;
    public bool IsTesting
    {
        get => _isTesting;
        set { if (Set(ref _isTesting, value)) { Raise(nameof(TestGlyph)); Raise(nameof(TestTip)); } }
    }

    public string TestGlyph => _isTesting ? "⚡…" : "⚡";
    public string TestTip => _isTesting
        ? "这一页的节点正在测…"
        : "只测当前页面显示的节点（选中分组就只测该组）；测完按延迟从低到高排";

    /// <summary>分组里存的是订阅原文里的成员名；显示名可能被唯一化改过，所以两边都比。</summary>
    public bool InGroup(NodeItem item, GroupChip chip) =>
        chip.Members.Contains(item.Model.OriginalName, StringComparer.Ordinal)
        || chip.Members.Contains(item.Model.Name, StringComparer.Ordinal);

    /// <summary>筛选只挪不重建：实例不变、滚动位置不丢，测速结果也不会被抹平。</summary>
    public void ApplyFilter()
    {
        var chip = ActiveGroup;
        var matched = chip == null || chip.Name.Length == 0
            ? Nodes.ToList()
            : Nodes.Where(n => InGroup(n, chip)).ToList();
        FilterNote = matched.Count == 0 && Nodes.Count > 0 && chip != null && chip.Name.Length > 0
            ? $"「{chip.Name}」里一个节点都没对上（机场可能改了成员名），先按全部节点显示。"
            : "";
        var want = matched.Count > 0 ? matched : Nodes.ToList();
        for (var i = 0; i < want.Count; i++)
        {
            var at = VisibleNodes.IndexOf(want[i]);
            if (at < 0) VisibleNodes.Insert(i, want[i]);
            else if (at != i) VisibleNodes.Move(at, i);
        }
        for (var i = VisibleNodes.Count - 1; i >= 0; i--)
            if (!want.Contains(VisibleNodes[i])) VisibleNodes.RemoveAt(i);
        foreach (var g in Groups) g.IsOn = ReferenceEquals(g, chip);
        Raise(nameof(VisibleCountText));
    }

    private string _filterNote = "";
    public string FilterNote { get => _filterNote; private set { if (Set(ref _filterNote, value)) Raise(nameof(ShowFilterNote)); } }
    public bool ShowFilterNote => _filterNote.Length > 0;

    public string VisibleCountText => ActiveGroup == null || ActiveGroup.Name.Length == 0
        ? $"{Nodes.Count} 个节点"
        : $"{VisibleNodes.Count} / {Nodes.Count} 个节点 · {ActiveGroup.Name}";

    private bool _isExpanded = true;
    public bool IsExpanded { get => _isExpanded; set => Set(ref _isExpanded, value); }

    public string Name => string.IsNullOrWhiteSpace(Model.Name) ? Model.Url : Model.Name;
    public string Updated => Model.UpdatedAtMs > 0
        ? DateTimeOffset.FromUnixTimeMilliseconds(Model.UpdatedAtMs).LocalDateTime.ToString("MM-dd HH:mm")
        : "未更新";

    public string TrafficText
    {
        get
        {
            if (Model.TotalBytes <= 0) return $"{Nodes.Count} 个节点";
            var used = Math.Max(0, Model.UploadBytes + Model.DownloadBytes);
            return $"{Fmt(used)} / {Fmt(Model.TotalBytes)}"
                + (Model.ExpireAtMs > 0 ? " · " + DateTimeOffset.FromUnixTimeMilliseconds(Model.ExpireAtMs).LocalDateTime.ToString("yyyy-MM-dd 到期") : "");
        }
    }

    public double TrafficRatio
    {
        get
        {
            if (Model.TotalBytes <= 0) return 0;
            var used = Math.Max(0, Model.UploadBytes + Model.DownloadBytes);
            return Math.Clamp((double)used / Model.TotalBytes, 0.01, 1.0);
        }
    }

    public void Refresh()
    {
        Raise(nameof(TrafficText));
        Raise(nameof(Updated));
    }

    private static string Fmt(long b) => b switch
    {
        >= 1_073_741_824 => $"{b / 1_073_741_824.0:0.00} GB",
        >= 1_048_576 => $"{b / 1_048_576.0:0.0} MB",
        >= 1024 => $"{b / 1024.0:0} KB",
        _ => b + " B",
    };
}

/// <summary>
/// 订阅声明的一个代理组。点它是**筛选**：把这张订阅卡切到只显示该组的节点
/// （用户要求的形态——之前点分组只测速，节点列表根本不动，等于没分组）。
/// </summary>
public sealed class GroupChip : ObservableObject
{
    /// <summary>所属订阅卡（chip 的 DataContext 只有它自己，点击事件要能找回父卡）。</summary>
    public SubscriptionItem? Owner { get; internal set; }
    public string Name { get; }
    public string Kind { get; }
    public List<string> Members { get; }

    /// <summary>空名字 = 「全部节点」那颗伪分组（每张卡第一颗）。</summary>
    public GroupChip(string name, string kind, IEnumerable<string> members)
    {
        Name = name;
        Kind = kind;
        Members = members.ToList();
    }

    public string DisplayName => Name.Length == 0 ? "全部节点" : Name;

    private bool _isOn;
    public bool IsOn { get => _isOn; set => Set(ref _isOn, value); }

    public string Label => Kind.Length == 0
        ? $"{DisplayName}（{Members.Count}）"
        : $"{DisplayName}（{Kind} · {Members.Count}）";
}

/// <summary>连接表的一行。按 Id 复用实例、只刷新数字，用户的鼠标底下不会换行。</summary>
public sealed class ConnectionItem : ObservableObject
{
    public string Id { get; }
    public ConnectionItem(string id) { Id = id; }

    private string _target = "";
    public string Target { get => _target; private set => Set(ref _target, value); }
    private string _chain = "";
    public string Chain { get => _chain; private set => Set(ref _chain, value); }
    private string _process = "";
    public string Process { get => _process; private set => Set(ref _process, value); }
    private string _rule = "";
    public string Rule { get => _rule; private set => Set(ref _rule, value); }
    private string _protocol = "";
    public string Protocol { get => _protocol; private set => Set(ref _protocol, value); }
    private string _started = "";
    public string Started { get => _started; private set => Set(ref _started, value); }
    private long _upload;
    public long Upload { get => _upload; private set => Set(ref _upload, value); }
    private long _download;
    public long Download { get => _download; private set { if (Set(ref _download, value)) Raise(nameof(DownloadText)); } }
    public string DownloadText => FmtBytes(Download);
    public DateTime StartAt { get; private set; }

    public void Apply(Connection c, DateTime now)
    {
        Target = c.Target;
        Chain = c.Chain;
        Process = c.Process;
        Rule = c.Rule;
        Protocol = c.Network.Length == 0 ? "" : c.Network.ToUpperInvariant() + (c.Port > 0 ? " " + c.Port : "");
        StartAt = c.Start == default ? DateTime.MinValue : c.Start.ToLocalTime();
        Started = c.Start == default ? "" : StartAt.ToString("HH:mm:ss");
        Upload = c.Upload;
        Download = c.Download;
    }

    internal static string FmtBytes(long b) => b switch
    {
        >= 1_073_741_824 => $"{b / 1_073_741_824.0:0.00} GB",
        >= 1_048_576 => $"{b / 1_048_576.0:0.0} MB",
        >= 1024 => $"{b / 1024.0:0} KB",
        _ => b + " B",
    };

    internal static string FmtSpeed(double perSecond) => perSecond switch
    {
        >= 1_048_576 => $"{perSecond / 1_048_576:0.0} MB/s",
        >= 1024 => $"{perSecond / 1024:0} KB/s",
        _ => $"{perSecond:0} B/s",
    };
}

/// <summary>主视图模型：页面共一份数据，导航只是切换显示哪一块。</summary>
public sealed class MainViewModel : ObservableObject, IDisposable
{
    private readonly Workspace _workspace;
    private readonly ConnectionManager _manager;

    public ObservableCollection<NodeItem> Nodes { get; } = new();
    public ObservableCollection<SubscriptionItem> Subscriptions { get; } = new();
    public ObservableCollection<ConnectionItem> Connections { get; } = new();

    private NodeItem? _selectedNode;
    public NodeItem? SelectedNode
    {
        get => _selectedNode;
        set
        {
            if (!Set(ref _selectedNode, value) || value == null) return;
            if (_rebuilding) return;
            _ = SelectNodeAsync(value);
        }
    }

    private async Task SelectNodeAsync(NodeItem item)
    {
        // 统一落在总出口 PROXY：与鸿蒙订阅页同口径，点了哪行哪行就是出口。
        var ok = await _manager.SelectNodeAsync(item.Model.Name, "PROXY");
        // 内核拒了（Manager 已经把原因写进 LastError）：不假装选中，也不给用户瞎指一条路
        if (!ok) { DetailText = _manager.LastError ?? $"内核没有接受这次切换：{item.Name}"; return; }
        foreach (var n in Nodes) n.IsSelectedNow = ReferenceEquals(n, item);
        Raise(nameof(SelectedNode));
        // 手点一个节点 = 退出自动优选（与鸿蒙端一致）
        Raise(nameof(SmartActive));
        Raise(nameof(SelectedEgressText));
    }

    /// <summary>SelectedNodeId 的这个取值表示「出口交给内核的 smart 组」，不是某个具体节点。</summary>
    public const string SmartEgressId = ConnectionManager.AutoEgressId;

    /// <summary>模型在盘上 + 开了开关 + 至少两个节点，才有自动优选可选。</summary>
    public bool SmartAvailable => _manager.SmartGroupReady;

    /// <summary>
    /// 当前出口是不是「自动选择」。**没显式选过节点时默认就是它** ——
    /// mihomo-smart 的卖点就是内置小模型按每条连接的目标自动择优，用户第一次打开就该在用它。
    /// </summary>
    public bool SmartActive => SmartAvailable &&
        (_manager.Settings.SelectedNodeId.Length == 0 || _manager.Settings.SelectedNodeId == SmartEgressId);

    public string SmartSubtitle => $"内核智能选点 · 按每条连接的目标自动择优 · {Nodes.Count} 个候选节点";

    /// <summary>首页「当前出口」：自动优选时显示组名，不假装是某个节点（内核的 now 也不会随每条连接变）。</summary>
    /// <summary>首页「当前出口」：自动优选时显示组名，不假装是某个节点（内核的 now 也不会随每条连接变）。
    /// 全局模式下 GLOBAL 跟着 PROXY 走（内核实测它也认代理组名），所以这个说法在两种模式下都成立。</summary>
    public string SelectedEgressText => SmartActive
        ? ClashConfigGenerator.SmartGroupName
        : SelectedNode?.Name ?? "还没选节点";

    public AsyncRelayCommand SelectSmartCommand { get; }

    /// <summary>手动查一次出口信息（卡片右上角那个刷新）。</summary>
    public AsyncRelayCommand RefreshEgressCommand { get; }

    /// <summary>把总出口交给 smart 组：PROXY 选到 ♻️ 自动选择，之后每条连接由模型决定走哪个节点。</summary>
    private async Task SelectSmartAsync()
    {
        if (!SmartAvailable)
        {
            DetailText = "自动优选现在不可用：需要至少两个节点，并且内核的 LightGBM 模型在位。";
            return;
        }
        var ok = await _manager.SelectNodeAsync(ClashConfigGenerator.SmartGroupName, "PROXY");
        // SelectNodeAsync 按节点名找 id，smart 组不是节点所以找不到 —— 出口标记要自己写
        _manager.Settings.SelectedNodeId = SmartEgressId;
        _manager.SaveSettings();
        foreach (var n in Nodes) n.IsSelectedNow = false;
        Raise(nameof(SmartActive));
        Raise(nameof(SelectedEgressText));
        DetailText = ok
            ? "已交给自动优选：内核按每条连接的目标自己挑节点，「实时连接」的出口列就是它选中的那个。"
            : "内核没接受切到自动优选（可能这份配置里还没发射 smart 组），点「连接」后重试。";
    }

    private string _detailText = "";

    /// <summary>
    /// 底部状态条：报完就自己消失（3 秒）。以前它会一直挂着，
    /// 用户下次看页面时满屏都是上一次操作的残留文字。
    /// </summary>
    public string DetailText
    {
        get => _detailText;
        set
        {
            if (_detailText == value && value.Length > 0) return;
            _detailText = value;
            Raise(nameof(DetailText));
            RestartHintTimer();
        }
    }

    private System.Windows.Threading.DispatcherTimer? _hintTimer;

    private void RestartHintTimer()
    {
        if (_detailText.Length == 0) return;
        _hintTimer ??= new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        _hintTimer.Stop();
        _hintTimer.Tick -= OnHintExpired;
        _hintTimer.Tick += OnHintExpired;
        _hintTimer.Start();
    }

    private void OnHintExpired(object? sender, EventArgs e)
    {
        _hintTimer?.Stop();
        _detailText = "";
        Raise(nameof(DetailText));
    }

    private bool _isConnected;
    private bool _isConnecting;
    public bool IsConnected { get => _isConnected; private set => Set(ref _isConnected, value); }
    public bool IsConnecting { get => _isConnecting; private set { if (Set(ref _isConnecting, value)) Raise(nameof(RingStateText)); } }

    /// <summary>电源环中间那行字：只有 未连接 / 正在连接 / 已连接 三种，别写成一整句状态报告。</summary>
    public string RingStateText => IsConnected ? "已连接" : IsConnecting ? "正在连接" : "未连接";

    private bool _isCoreAlive;
    public bool IsCoreAlive { get => _isCoreAlive; private set => Set(ref _isCoreAlive, value); }

    private string _proxyMode = "rule";
    public string ProxyMode { get => _proxyMode; private set => Set(ref _proxyMode, value); }

    private string _trafficText = "↑ 0 B/s   ↓ 0 B/s";
    public string TrafficText { get => _trafficText; private set => Set(ref _trafficText, value); }

    // ── 命令 ─────────────────────────────────────────────────────────────
    public AsyncRelayCommand ToggleConnectCommand { get; }
    public AsyncRelayCommand TestAllCommand { get; }
    public AsyncRelayCommand ImportSubscriptionCommand { get; }
    public AsyncRelayCommand ApplySettingsCommand { get; }
    public AsyncRelayCommand SaveAllCommand { get; }
    public AsyncRelayCommand RefreshGeoCommand { get; }
    public RelayCommand SetModeCommand { get; }
    public RelayCommand RemoveSubscriptionCommand { get; }
    public RelayCommand OpenLogCommand { get; }
    public RelayCommand RestartAsAdminCommand { get; }
    public RelayCommand ExitCommand { get; }
    public RelayCommand ToggleTunCommand { get; }

    private string _subscriptionInput = "";
    public string SubscriptionInput { get => _subscriptionInput; set => Set(ref _subscriptionInput, value); }

    private string _mixedPortText = "7890";
    public string MixedPortText { get => _mixedPortText; set => Set(ref _mixedPortText, value); }
    private string _httpPortText = "0";
    public string HttpPortText { get => _httpPortText; set => Set(ref _httpPortText, value); }
    private string _socksPortText = "0";
    public string SocksPortText { get => _socksPortText; set => Set(ref _socksPortText, value); }
    private string _apiPortText = "9090";
    public string ApiPortText { get => _apiPortText; set => Set(ref _apiPortText, value); }
    private bool _allowLan;
    public bool AllowLan { get => _allowLan; set => Set(ref _allowLan, value); }
    private bool _tunOn;
    public bool TunOn { get => _tunOn; set { if (Set(ref _tunOn, value)) SyncTunStatus(); } }
    private string _testUrlText = "";
    public string TestUrlText { get => _testUrlText; set => Set(ref _testUrlText, value); }
    private string _logLevelChoice = "info";
    public string LogLevelChoice { get => _logLevelChoice; set => Set(ref _logLevelChoice, value); }
    private bool _snifferOn = true;
    public bool SnifferOn { get => _snifferOn; set => Set(ref _snifferOn, value); }
    private bool _smartOn = true;
    public bool SmartOn { get => _smartOn; set => Set(ref _smartOn, value); }
    private bool _ipv6On;
    public bool Ipv6On { get => _ipv6On; set => Set(ref _ipv6On, value); }
    private bool _dnsOverrideOn;
    public bool DnsOverrideOn { get => _dnsOverrideOn; set => Set(ref _dnsOverrideOn, value); }
    private string _dnsServersText = "";
    public string DnsServersText { get => _dnsServersText; set => Set(ref _dnsServersText, value); }

    /// <summary>
    /// DNS 覆写的默认值：阿里 + 腾讯的 DoT 端点（国内可达、加密、不用翻墙），
    /// 和没开覆写时内核内置的那组一致 —— 用户打开开关就能看到能用的东西，而不是面对一个空框。
    /// </summary>
    public const string DefaultDnsServers = "tls://223.5.5.5:853\ntls://1.12.12.12:853";

    private string _dnsFeedback = "";

    /// <summary>DNS 复写的逐行校验结果，写不进内核的那几条必须当场说出来。</summary>
    public string DnsFeedback { get => _dnsFeedback; private set => Set(ref _dnsFeedback, value); }
    private bool _rulesOn = true;
    public bool RulesOn { get => _rulesOn; set => Set(ref _rulesOn, value); }
    private bool _adRulesOn;
    public bool AdRulesOn { get => _adRulesOn; set => Set(ref _adRulesOn, value); }
    private string _customRulesText = "";
    public string CustomRulesText { get => _customRulesText; set => Set(ref _customRulesText, value); }
    private string _forceProxyText = "";
    public string ForceProxyText { get => _forceProxyText; set => Set(ref _forceProxyText, value); }
    private string _forceDirectText = "";
    public string ForceDirectText { get => _forceDirectText; set => Set(ref _forceDirectText, value); }
    private string _appProcesses = "";
    public string AppProcesses { get => _appProcesses; set => Set(ref _appProcesses, value); }
    private string _appRoutingChoice = "all";
    public string AppRoutingChoice { get => _appRoutingChoice; set => Set(ref _appRoutingChoice, value); }
    private bool _autoStartOn;
    public bool AutoStartOn { get => _autoStartOn; set => Set(ref _autoStartOn, value); }
    private string _closeChoice = "ask";

    /// <summary>
    /// 选完立刻落盘。以前它只活在内存里，要等「应用设置」那颗按钮才写盘，
    /// 而「常规」这张卡上没有那颗按钮 —— 于是用户反馈的「三个选择都没用，每次都缩到托盘」。
    /// </summary>
    public string CloseChoice
    {
        get => _closeChoice;
        set
        {
            if (!Set(ref _closeChoice, value)) return;
            _manager.Settings.Close = ToCloseBehavior(value);
            _manager.SaveSettings();
            Raise(nameof(CloseMode));
        }
    }

    internal static CloseBehavior ToCloseBehavior(string choice) => choice switch
    {
        "tray" => CloseBehavior.Tray,
        "exit" => CloseBehavior.Exit,
        _ => CloseBehavior.Ask,
    };

    private string _geoSummaryText = "";
    public string GeoSummaryText { get => _geoSummaryText; private set => Set(ref _geoSummaryText, value); }

    private string _ruleFeedback = "";
    public string RuleFeedback { get => _ruleFeedback; private set => Set(ref _ruleFeedback, value); }

    private string _tunStatusText = "";
    public string TunStatusText { get => _tunStatusText; private set => Set(ref _tunStatusText, value); }

    public bool IsAdmin { get; } = Elevation.IsAdmin;
    public bool ShowElevationHint => !IsAdmin;

    /// <summary>侧栏上的版本号：用户反复重装测试时，得能一眼看出自己跑的是哪一版。</summary>
    public string VersionText { get; } = typeof(MainViewModel).Assembly
        .GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
        .Cast<System.Reflection.AssemblyInformationalVersionAttribute>()
        .FirstOrDefault()?.InformationalVersion.Split('+')[0] ?? "0.0.0";

    public string SubscriptionCountText => Subscriptions.Count == 0
        ? "还没有订阅" : $"{Subscriptions.Count} 条订阅 · {Nodes.Count} 个节点";

    /// <summary>workspace 可注入：测试用默认值会写到用户真实的 %APPDATA%\TunBox。</summary>
    public MainViewModel(Workspace? workspace = null)
    {
        _workspace = workspace ?? new Workspace();
        _manager = new ConnectionManager(_workspace);
        _manager.Changed += OnManagerChanged;

        ToggleConnectCommand = new AsyncRelayCommand(_ => ToggleConnectAsync());
        TestAllCommand = new AsyncRelayCommand(_ => TestAllAsync(), _ => _manager.Nodes.Count > 0);
        ImportSubscriptionCommand = new AsyncRelayCommand(_ => ImportAsync());
        ApplySettingsCommand = new AsyncRelayCommand(_ => ApplySettingsAsync());
        SaveAllCommand = new AsyncRelayCommand(_ => SaveAllAsync());
        RefreshGeoCommand = new AsyncRelayCommand(_ => RefreshGeoAsync());
        SetModeCommand = new RelayCommand(p =>
        {
            var mode = (string?)p ?? "rule";
            _ = _manager.SetProxyModeAsync(mode);
            ProxyMode = mode;
        });
        SelectSmartCommand = new AsyncRelayCommand(_ => SelectSmartAsync());
        RefreshEgressCommand = new AsyncRelayCommand(_ => QueryEgressAsync());
        RemoveSubscriptionCommand = new RelayCommand(p =>
        {
            if (p is SubscriptionItem item) _manager.RemoveSubscription(item.Model.Id);
        });
        OpenLogCommand = new RelayCommand(_ =>
        {
            var path = Path.Combine(_workspace.RuntimeDir, "core.log");
            if (File.Exists(path)) Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
            else DetailText = "还没有内核日志：内核还没跑过一次。";
        });
        RestartAsAdminCommand = new RelayCommand(_ => RestartElevated(), _ => !IsAdmin);
        ExitCommand = new RelayCommand(_ =>
        {
            if (Application.Current is App app) app.ExitApplication();
            else Application.Current?.Shutdown();
        });
        ToggleTunCommand = new RelayCommand(_ =>
        {
            TunOn = !TunOn;
            _ = ApplySettingsAsync();
        });
        // 任何命令漏出来的异常都落到状态栏：不弹窗、也不再把进程带崩。
        foreach (var c in new[] { ToggleConnectCommand, TestAllCommand, ImportSubscriptionCommand,
                                  ApplySettingsCommand, SaveAllCommand, RefreshGeoCommand })
            c.Failed += OnCommandFailed;

        RebuildLists();
        SyncFromSettings();
        if (_manager.Nodes.Count > 0) _ = _manager.EnsureStandbyAsync();
    }

    // ── 状态同步 ─────────────────────────────────────────────────────────

    /// <summary>命令里冒出来的异常：说人话落在状态栏，绝不弹模态窗。</summary>
    private void OnCommandFailed(Exception e)
        => DetailText = e is OperationCanceledException
            ? "内核这一拍没应答（超时），再点一次试试。"
            : "这一步没走完：" + e.Message;

    private void SyncFromSettings()
    {
        var s = _manager.Settings;
        ProxyMode = s.ProxyMode;
        MixedPortText = s.MixedPort.ToString();
        HttpPortText = s.HttpPort.ToString();
        SocksPortText = s.SocksPort.ToString();
        ApiPortText = s.ApiPort.ToString();
        AllowLan = s.AllowLan;
        TunOn = s.TunEnabled;
        TestUrlText = s.TestUrl;
        LogLevelChoice = s.CoreLogLevel;
        SnifferOn = s.SniffingEnabled;
        SmartOn = s.UseSmartGroup;
        RulesOn = s.RulesEnabled;
        AdRulesOn = s.AdRulesEnabled;
        CustomRulesText = string.Join("\n", s.CustomRules);
        ForceProxyText = string.Join(", ", s.ForceProxySites);
        ForceDirectText = string.Join(", ", s.ForceDirectSites);
        AppProcesses = string.Join(", ", s.AppProcesses);
        AppRoutingChoice = s.AppRouting switch
        {
            AppRoutingMode.OnlySelected => "include",
            AppRoutingMode.BypassSelected => "exclude",
            _ => "all",
        };
        AutoStartOn = AutoStart.IsEnabled();
        // 直接落字段再通知：走 CloseChoice 的 setter 会在每次读档时回写一遍盘。
        _closeChoice = s.Close switch { CloseBehavior.Tray => "tray", CloseBehavior.Exit => "exit", _ => "ask" };
        Raise(nameof(CloseChoice));
        Raise(nameof(CloseMode));
        Ipv6On = s.Ipv6Enabled;
        DnsOverrideOn = s.DnsOverrideEnabled;
        DnsServersText = s.DnsServers.Count > 0 ? string.Join("\n", s.DnsServers) : DefaultDnsServers;
        SyncTunStatus();
        SyncGeoSummary();
    }

    private void SyncTunStatus()
    {
        // 读界面上的开关（TunOn），不是设置里的旧值：用户一勾选，状态行就得跟着变，
        // 不能等「应用设置」落盘之后才动（真机反馈：勾了还显示未启用）。
        // 判据是我们自己的虚拟网卡，不是 Windows 右下角那个图标（它画的是物理链路）——
        // 但这话不必说给用户听：他要的是状态，不是一段科普。
        TunStatusText = !TunOn ? "未启用"
            : _manager.TunActive ? "已接管"
            : _manager.TunPending ? "内核正在建网卡…"
            : _manager.State == TunnelState.Connected
                ? (_manager.TunAdapterPresent() ? "网卡在，但没拿到默认路由" : "网卡没起来（看内核日志）")
                : !IsAdmin ? "需要管理员：点下方按钮重启"
                : "已打开：点「连接」时接管";
    }

    private void SyncGeoSummary()    {
        var parts = new List<string>();
        foreach (var a in _manager.GeoAssets.Statuses)
        {
            if (a.Key == GeoAssetStore.AdRulesKey && !_manager.GeoAssets.AdRulesWanted) continue;
            parts.Add($"{a.Title}：{a.Detail}");
        }
        GeoSummaryText = parts.Count == 0 ? "分流库：还没开始下载" : string.Join("\n", parts);
    }

    // ── 出口信息卡（首页，虚拟网卡与实时连接之间）───────────────────────
    // 这张卡的存在理由就是用户报的那件事：「我选的节点和我查到的 IP 不对应」。
    // 走代理问一次出口 IP + 归属，再和直连问到的本机 IP 并排摆出来，对不对一眼就看穿。
    private EgressSnapshot _egress = EgressSnapshot.Empty;
    private bool _egressBusy;
    private string _egressStamp = "";
    private int _egressGeneration;

    public bool EgressBusy { get => _egressBusy; private set => Set(ref _egressBusy, value); }
    public string EgressIpText => _egress.HasEgress ? _egress.EgressIp : (_egressBusy ? "查询中…" : "—");
    public string EgressLocationText => _egress.HasEgress ? _egress.LocationText : "—";
    public string EgressCarrierText => _egress.HasEgress ? _egress.CarrierText : "—";
    public string LocalIpText => _egress.HasLocal ? _egress.LocalIp : "—";
    public bool HasEgressInfo => _egress.HasEgress;

    /// <summary>右下角那句提醒：出口=本机说明压根没走代理；查询失败就引用接口给的原因。</summary>
    public string EgressNote
    {
        get
        {
            if (_egress.Error != null) return "查不到：" + _egress.Error;
            if (_egress.SameAsLocal) return "出口 IP 与本机相同，这条连接没走代理（检查分流规则或换节点）";
            if (!_egress.HasEgress) return IsConnected ? "" : "点「连接」之后才能查出口 IP";
            return _egress.At == DateTime.MinValue ? "" : $" {_egress.At:HH:mm} 更新";
        }
    }

    public bool ShowEgressWarn => _egress.SameAsLocal || _egress.Error != null;

    private void RaiseEgress()
    {
        foreach (var n in new[]
                 {
                     nameof(EgressIpText), nameof(EgressLocationText), nameof(EgressCarrierText),
                     nameof(LocalIpText), nameof(HasEgressInfo), nameof(EgressNote), nameof(ShowEgressWarn),
                 })
            Raise(n);
    }

    /// <summary>测试缝隙：换一下「出口身份」并排队一次出口查询（模拟用户连着点节点）。</summary>
    internal void PokeEgressForTests(string selectedNodeId)
    {
        _manager.Settings.SelectedNodeId = selectedNodeId;
        RefreshEgressSoon();
    }

    private async Task QueryEgressAsync()
    {
        if (EgressBusy) return;
        if (!_manager.EgressQueryable)
        {
            _egress = EgressSnapshot.Empty with { Connected = IsConnected };
            RaiseEgress();
            return;
        }
        EgressBusy = true;
        RaiseEgress();
        try
        {
            // 本机 IP 只在第一次（或用户手动刷新）时直连问一次，别每轮都多打一个请求
            _egress = await _manager.QueryEgressAsync(withLocal: !_egress.HasLocal);
        }
        catch (Exception e)
        {
            _egress = _egress with { Error = e.Message };
        }
        EgressBusy = false;
        RaiseEgress();
    }

    /// <summary>
    /// 出口该变了就重查一次：连接上、换节点、切模式都算；连珠炮式的重建合并成一次。
    /// 这里不用 CancellationTokenSource：上一版让 UI 线程 Cancel/Dispose 旧令牌、后台任务再 Dispose 一次，
    /// 谁先谁后没有约定 —— 抢输了就是用户看到的「界面刷新出错：ObjectDisposedException」。
    /// 改成只数代数：过期的那次自己走人，没有任何可被释放的对象。
    /// </summary>
    internal void RefreshEgressSoon()
    {
        var stamp = $"{(_manager.State == TunnelState.Connected ? "on" : "off")}"
            + $"|{_manager.Settings.ProxyMode}|{_manager.Settings.SelectedNodeId}";
        if (stamp == _egressStamp) return;
        _egressStamp = stamp;
        var generation = Interlocked.Increment(ref _egressGeneration);
        _ = Task.Run(async () =>
        {
            await Task.Delay(800);
            if (generation != Volatile.Read(ref _egressGeneration)) return;   // 后面又点过了，让最新那次去查
            Application.Current?.Dispatcher.InvokeAsync(() =>
            {
                if (generation != Volatile.Read(ref _egressGeneration)) return;
                _ = QueryEgressAsync();
            });
        });
    }

    private void OnManagerChanged()
    {
        // 内核事件来自后台线程，一秒能来好几次：这里抛一个异常就是一格一帧的弹窗风暴，
        // 所以整段兜底 —— 刷新失败落到状态栏，绝不让它逃出去。
        Application.Current?.Dispatcher.BeginInvoke(() =>
        {
            try
            {
                RebuildLists();
                IsConnected = _manager.IsConnected;
                IsCoreAlive = _manager.CoreAlive;
                IsConnecting = _manager.State == TunnelState.Connecting;
                Raise(nameof(RingStateText));
                if (_manager.LastError != null) DetailText = _manager.LastError;
                else if (_manager.LastDrop is { HasDrop: true } d) DetailText = d.Summary();
                ProxyMode = _manager.Settings.ProxyMode;
                SyncTunStatus();
                SyncGeoSummary();
                foreach (var item in Nodes) item.Refresh();
                // 导入完节点数变了，自动优选的可用性与候选数得跟着刷新
                Raise(nameof(SmartAvailable));
                Raise(nameof(SmartActive));
                Raise(nameof(SmartSubtitle));
                Raise(nameof(SelectedEgressText));
                foreach (var c in new[] { TestAllCommand, ToggleConnectCommand }) c.Refresh();
                // 出口换了就该重新查一次出口 IP（连接、换节点、切模式都会走到这里，800ms 合并）
                RefreshEgressSoon();
            }
            catch (Exception e)
            {
                DetailText = "界面刷新出错：" + e.GetType().Name + " " + e.Message;
            }
        });
    }

    private bool _rebuilding;

    // ── 列表重建 ─────────────────────────────────────────────────────────

    /// <summary>
    /// 节点行实例全项目只有一批（挂在总表 Nodes 上），订阅卡按 SubscriptionId 引用同一批
    /// —— 测速结果刷新一次，展开的每一张卡都跟着变。
    ///
    /// 关键：**重建必须保留上次的显示顺序和选中的分组**。内核事件一秒能来好几次，
    /// 每次都 Clear + 按原序重加，界面上就是「刚排好的延迟顺序又弹回去了」
    /// —— 用户反馈的「全部测速没生效」正是这个，而不是排序代码没跑。
    /// </summary>
    private void RebuildLists()
    {
        var selectedName = SelectedNode?.Model.Name;
        var keepGroup = new Dictionary<string, string>(StringComparer.Ordinal);
        var keepExpanded = new Dictionary<string, bool>(StringComparer.Ordinal);
        foreach (var card in Subscriptions)
        {
            if (card.ActiveGroup is { Name.Length: > 0 } g) keepGroup[card.Model.Id] = g.Name;
            keepExpanded[card.Model.Id] = card.IsExpanded;
        }
        var previousOrder = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var i = 0; i < Nodes.Count; i++) previousOrder.TryAdd(Nodes[i].Model.Id, i);

        _rebuilding = true;
        try
        {
            Nodes.Clear();
            Subscriptions.Clear();
            var bySub = new Dictionary<string, List<NodeItem>>(StringComparer.Ordinal);
            foreach (var n in _manager.Nodes)
            {
                var item = new NodeItem(n)
                {
                    IsSelectedNow = n.Id == _manager.Settings.SelectedNodeId,
                };
                Nodes.Add(item);
                if (!bySub.TryGetValue(n.SubscriptionId, out var list)) bySub[n.SubscriptionId] = list = new List<NodeItem>();
                list.Add(item);
            }
            ReorderBy(Nodes, previousOrder);
            foreach (var s in _manager.Subscriptions)
            {
                var card = new SubscriptionItem(s);
                // 折叠态要活过每一次重建：用户收起来的卡，切个页面回来不能又弹开。
                card.IsExpanded = !keepExpanded.TryGetValue(s.Id, out var expanded) || expanded;
                if (bySub.TryGetValue(s.Id, out var list)) foreach (var item in list) card.Nodes.Add(item);
                // 第一颗是「全部节点」：分组是筛选器，用户必须能一键回到不筛选的状态。
                card.Groups.Add(new GroupChip("", "", card.Nodes.Select(n => n.Model.Name)) { Owner = card });
                // 订阅声明的分组 → 点它筛选出该组的节点
                foreach (var g in _manager.Groups.Where(g => g.SubscriptionId == s.Id))
                    card.Groups.Add(new GroupChip(g.Name, g.GroupType, g.Members) { Owner = card });
                if (keepGroup.TryGetValue(s.Id, out var name))
                {
                    var same = card.Groups.FirstOrDefault(x => x.Name == name);
                    if (same != null) card.ActiveGroup = same;
                }
                card.ApplyFilter();
                Subscriptions.Add(card);
            }
            var match = Nodes.FirstOrDefault(x => x.Model.Name == selectedName)
                        ?? Nodes.FirstOrDefault(n => n.Model.Id == _manager.Settings.SelectedNodeId)
                        ?? Nodes.FirstOrDefault();
            if (!ReferenceEquals(SelectedNode, match)) SelectedNode = match;
        }
        finally { _rebuilding = false; }
        Raise(nameof(SubscriptionCountText));
        Raise(nameof(Nodes));
    }

    /// <summary>按上次的显示位置就地重排（用 Move，不重建集合）；新出现的节点保持原有相对顺序往后放。</summary>
    private static void ReorderBy(
        System.Collections.ObjectModel.ObservableCollection<NodeItem> list,
        Dictionary<string, int> previousOrder)
    {
        if (previousOrder.Count == 0) return;
        var want = list.OrderBy(x => previousOrder.TryGetValue(x.Model.Id, out var at) ? at : int.MaxValue)
            .ThenBy(x => list.IndexOf(x)).ToList();
        for (var i = 0; i < want.Count; i++)
        {
            var at = list.IndexOf(want[i]);
            if (at >= 0 && at != i) list.Move(at, i);
        }
    }

    /// <summary>点节点卡上的延迟数字：只测这一个，用来验证「这家不行还是这个不行」。</summary>
    public void TestOne(NodeItem item) => _ = TestOneCoreAsync(item);

    private async Task TestOneCoreAsync(NodeItem item)
    {
        if (!_manager.CoreAlive && !await _manager.EnsureStandbyAsync())
        {
            DetailText = _manager.LastError ?? "内核起不来，测不了速";
            return;
        }
        item.Model.State = DelayState.Testing;
        item.Refresh();
        var r = await _manager.TestNodeAsync(item.Model.Name);
        item.Refresh();
        DetailText = r == null ? "这个节点已经不在列表里了，先更新订阅。"
            : r.Ok ? $"{item.Name} · {r.DelayMs} ms"
            : $"{item.Name} · " + (r.Error ?? r.Text);
    }

    public async Task UpdateSubscriptionAsync(SubscriptionItem item)
    {
        DetailText = $"正在更新「{item.Name}」…";
        var ok = await _manager.RefreshSubscriptionAsync(item.Model.Id);
        DetailText = ok
            ? $"已更新「{item.Name}」，当前 {_manager.Nodes.Count} 个节点。"
            : (_manager.LastError ?? "更新失败");
        RebuildLists();
        Raise(nameof(SubscriptionCountText));
    }

    public void RemoveSubscription(SubscriptionItem item)
    {
        _manager.RemoveSubscription(item.Model.Id);
        RebuildLists();
        Raise(nameof(SubscriptionCountText));
        DetailText = $"已删除订阅「{item.Name}」。";
    }

    // ── 首页动作 ─────────────────────────────────────────────────────────

    private async Task ToggleConnectAsync()
    {
        if (_manager.IsConnected) { await _manager.DisconnectAsync(); return; }
        await ConnectNowAsync();
    }

    private async Task<bool> ConnectNowAsync()
    {
        var ok = await _manager.ConnectAsync();
        if (!ok) { DetailText = _manager.LastError ?? "连接失败"; return false; }
        // 「连接」必须真的生效：系统代理写不进注册表要当场说出来，而不是让用户
        // 以为主页那个「已接管流量」等于浏览器会走代理（真机反馈的「没生效」）。
        if (_manager.Settings.SystemProxyEnabled && !_manager.EnsureSystemProxy())
            DetailText = "内核已接管，但系统代理写不进注册表（可能被安全软件拦了）。"
                + "可以手动给浏览器配 HTTP 代理 127.0.0.1:" + _manager.Settings.SystemProxyPort() + "，或检查安全软件设置。";
        else
            DetailText = "已接管流量。" + (_manager.LastTiming is { Length: > 0 } t ? "（" + t + "）" : "");
        return true;
    }

    /// <summary>分组单独测速：只测这一组成员，结果写回模型，订阅页的节点行跟着变色。</summary>
    /// <summary>把一张列表按「已测延迟升序，测速中/未测在后」实时上浮。用 Move，不重建集合，滚动位置不丢。</summary>
    private static void SortByRank(
        System.Collections.ObjectModel.ObservableCollection<NodeItem> list)
    {
        var ordered = list.OrderBy(SortRank).ToList();
        for (var i = 0; i < ordered.Count; i++)
        {
            var at = list.IndexOf(ordered[i]);
            if (at >= 0 && at != i) list.Move(at, i);
        }
    }

    private void SortCardsByLatency()
    {
        SortByRank(Nodes);
        // 两张列表都要排：界面绑的是 VisibleNodes（筛选后的那一屏），只排 Nodes 用户看不到变化。
        foreach (var card in Subscriptions) SortByRank(card.VisibleNodes);
    }

    /// <summary>点分组 chip = 按该分组筛选节点（不是测速）。</summary>
    public void SelectGroup(GroupChip? chip)
    {
        var card = chip?.Owner;
        if (card == null || chip == null) return;
        card.ActiveGroup = chip;
        if (card.FilterNote.Length > 0) { DetailText = card.FilterNote; return; }
        DetailText = chip.Name.Length == 0
            ? $"「{card.Name}」已切回全部 {card.VisibleNodes.Count} 个节点。"
            : $"「{card.Name}」按分组「{chip.Name}」显示 {card.VisibleNodes.Count} 个节点。"
              + "点订阅上的 ⚡ 只测这一屏。";
    }

    /// <summary>订阅卡上的 ⚡：只测当前页面显示的那一屏节点（选了分组就只测该组）。</summary>
    public void TestSubscription(SubscriptionItem? card)
    {
        if (card == null || card.IsTesting) return;
        _ = TestListCoreAsync(card, card.VisibleNodes.ToList(), $"「{card.Name}」这一页");
    }

    private async Task TestListCoreAsync(SubscriptionItem card, List<NodeItem> targets, string what)
    {
        if (targets.Count == 0) { DetailText = "这一页没有节点可测。"; return; }
        if (!_manager.CoreAlive && !await _manager.EnsureStandbyAsync())
        {
            DetailText = _manager.LastError ?? "内核起不来，测不了速";
            return;
        }
        card.IsTesting = true;
        var done = 0;
        try
        {
            foreach (var t in targets)
            {
                t.Model.State = DelayState.Testing;
                t.Refresh();
            }
            SortCardsByLatency();
            DetailText = $"⚡ {what} {targets.Count} 个节点测速中…（按延迟实时排序）";
            var results = await _manager.Api.DelayManyAsync(
                targets.Select(t => t.Model.Name).ToList(), _manager.Settings.TestUrl,
                onEach: r => Application.Current?.Dispatcher.BeginInvoke(() =>
                {
                    ApplyResult(r);
                    var n = Interlocked.Increment(ref done);
                    DetailText = $"⚡ {what}：{n}/{targets.Count}…（按延迟实时排序）";
                    SortCardsByLatency();
                }));
            var ok = results.Count(r => r.Ok);
            foreach (var item in Nodes) item.Refresh();
            SortCardsByLatency();
            DetailText = ok > 0
                ? $"{what}测完：{ok}/{targets.Count} 通，已按延迟从低到高排好。"
                : $"{what}没有一个节点通：多半是测速地址不可达（设置里可换），或订阅过期。";
        }
        finally
        {
            card.IsTesting = false;
        }
    }

    private static int SortRank(NodeItem item) => item.Model.State switch
    {
        DelayState.Ok => item.Model.LastLatency,
        DelayState.Testing => 1_000_000,       // 正在测的跟在已出结果的后面
        _ => 2_000_000,                        // 未测 / 超时 / 失败垫底（超时失败在 UI 上有红色区分）
    };

    /// <summary>单条测速结果写回节点模型。</summary>
    private void ApplyResult(DelayResult r)
    {
        var node = _manager.Nodes.FirstOrDefault(n => n.Name == r.Name);
        if (node == null) return;
        node.LastLatency = r.Ok ? r.DelayMs : -1;
        node.State = r.State;
        node.DelayError = r.Error;
        var item = Nodes.FirstOrDefault(x => x.Model.Name == r.Name);
        item?.Refresh();
    }

    public void EditSubscription(SubscriptionItem item, string newName, string newUrl)
    {
        if (item == null) return;
        _manager.UpdateSubscriptionMeta(item.Model.Id, newName, newUrl);
        RebuildLists();
        DetailText = "订阅已修改。" + (item.Model.Url.Length > 0 ? "改过链接的话，点「更新」拉取新地址。" : "");
    }

    public async Task ImportFileAsync(string path)
    {
        try
        {
            var ok = await _manager.ImportFileAsync(path);
            DetailText = ok
                ? $"已导入「{Path.GetFileNameWithoutExtension(path)}」，当前 {_manager.Nodes.Count} 个节点。"
                : (_manager.LastError ?? "导入失败");
        }
        catch (Exception e)
        {
            DetailText = "导入失败：" + e.GetType().Name + " " + e.Message;
        }
        finally
        {
            RebuildLists();
            Raise(nameof(SubscriptionCountText));
        }
    }

    private async Task TestAllAsync()
    {
        if (!_manager.CoreAlive && !await _manager.EnsureStandbyAsync())
        {
            DetailText = _manager.LastError ?? "内核起不来，测不了速";
            return;
        }
        var done = 0;
        var total = _manager.Nodes.Count;
        var ok = await _manager.TestAllAsync(_ =>
        {
            var n = Interlocked.Increment(ref done);
            Application.Current?.Dispatcher.BeginInvoke(() =>
            {
                DetailText = $"⚡ 测速中 {n}/{total}…（按延迟实时排序）";
                foreach (var item in Nodes) item.Refresh();
                SortCardsByLatency();
            });
        });
        DetailText = ok > 0
            ? $"测速完成：{ok}/{total} 通，已按延迟从低到高排好。点节点卡上的延迟可单测一个。"
            : $"{total} 个节点都没通。多半是测速地址不可达（设置里可换），或订阅过期。";
        foreach (var item in Nodes) item.Refresh();
    }

    // ── 订阅页 ───────────────────────────────────────────────────────────

    public Task ImportAsync(string input)
    {
        SubscriptionInput = input ?? "";
        return ImportAsync();
    }

    private async Task ImportAsync()
    {
        var input = SubscriptionInput.Trim();
        if (input.Length == 0) { DetailText = "请输入订阅链接，或直接粘贴一批节点链接。"; return; }
        try
        {
            var ok = await _manager.AddSubscriptionAsync(input);
            DetailText = ok
                ? $"已导入，当前 {_manager.Nodes.Count} 个节点。" + (_manager.SaveWarning is { Length: > 0 } w ? " 注意：" + w : "")
                : (_manager.LastError ?? "导入失败");
            if (ok) SubscriptionInput = "";
        }
        catch (Exception e)
        {
            // 导入的任何错误都必须落在状态栏里：让它逃出去就是一串弹窗（用户实测的崩溃形态）
            DetailText = "导入失败：" + e.GetType().Name + " " + e.Message;
        }
        finally
        {
            RebuildLists();
        }
    }

    // ── 设置页 ───────────────────────────────────────────────────────────

    private async Task ApplySettingsAsync()
    {
        if (!TrySaveSettings()) return;
        SyncAutoStart();
        DetailText = _manager.CoreAlive ? "设置已保存，正在让内核原地重载…" : "设置已保存。";
        await ApplyChangesAsync("设置");
    }

    /// <summary>
    /// 首页那颗开关的语义 = 别的客户端的总开关：**拨开就接管，拨回就放手**。
    /// 以前它只把设置写进磁盘，用户还得再去点一次「连接」——那就是「点了没反应」。
    /// </summary>
    public async Task ApplySwitchAsync()
    {
        if (!TrySaveSettings()) return;
        // 拨开 TUN 就直接接管（内核没跑就顺手起来），拨回去也只是不再走网卡 ——
        // 系统代理跟着总开关走，不该让用户点完开关还要去点第二次。
        if (TunOn && !_manager.IsConnected) { await ConnectNowAsync(); return; }
        if (_manager.CoreAlive) await ApplyChangesAsync("开关");
        else DetailText = "设置已保存。";
    }

    /// <summary>校验界面上的输入并写进设置 + 落盘。返回 false = 有不合法的东西，原因已经写在状态栏。</summary>
    private bool TrySaveSettings()
    {
        var s = _manager.Settings;
        if (!TryReadPort(MixedPortText, out var mixed)) { DetailText = "混合端口要填 0-65535 的整数（0 = 不监听）"; return false; }
        if (!TryReadPort(HttpPortText, out var http)) { DetailText = "HTTP 端口要填 0-65535 的整数"; return false; }
        if (!TryReadPort(SocksPortText, out var socks)) { DetailText = "SOCKS 端口要填 0-65535 的整数"; return false; }
        if (!TryReadPort(ApiPortText, out var api)) { DetailText = "API 端口要填 1024-65535 的整数"; return false; }
        s.MixedPort = mixed;
        s.HttpPort = http;
        s.SocksPort = socks;
        s.ApiPort = api;
        s.AllowLan = AllowLan;
        // 系统代理不再是给用户关的开关：点电源键启动 = 走系统代理，少一个「开了但没生效」的入口。
        s.SystemProxyEnabled = true;
        s.TunEnabled = TunOn;
        var url = TestUrlText.Trim();
        if (url.Length == 0 || (!url.StartsWith("http://") && !url.StartsWith("https://")))
        {
            DetailText = "测速地址要填完整的 http(s) 地址，否则延迟数字没有意义。";
            return false;
        }
        s.TestUrl = url;
        s.CoreLogLevel = LogLevelChoice is "debug" or "info" ? LogLevelChoice : "info";
        s.SniffingEnabled = SnifferOn;
        s.UseSmartGroup = SmartOn;
        s.RulesEnabled = RulesOn;
        s.AdRulesEnabled = AdRulesOn;
        s.Ipv6Enabled = Ipv6On;
        s.DnsOverrideEnabled = DnsOverrideOn;
        if (DnsOverrideOn)
        {
            var dnsLines = DnsServersText.Split('\n').Select(x => x.Trim())
                .Where(x => x.Length > 0 && !x.StartsWith('#')).ToList();
            var problems = new List<string>();
            for (var i = 0; i < dnsLines.Count; i++)
            {
                var why = ClashConfigGenerator.ValidateDnsServer(dnsLines[i]);
                if (why.Length > 0) problems.Add($"第 {i + 1} 行没收下（{why}）");
            }
            var kept = ClashConfigGenerator.NormalizeDnsServers(dnsLines);
            DnsFeedback = problems.Count > 0 ? string.Join("；", problems.Take(4)) : "";
            if (kept.Count == 0)
            {
                DetailText = "DNS 复写至少要有一条能用的地址，否则内核会退回内置 DNS —— "
                    + "要么填地址（如 223.5.5.5、tls://223.5.5.5:853、https://doh.pub/dns-query），要么关掉复写。";
                return false;
            }
            s.DnsServers.Clear();
            foreach (var d in kept) s.DnsServers.Add(d);
        }
        s.Close = ToCloseBehavior(CloseChoice);
        _manager.SaveSettings();
        return true;
    }

    /// <summary>开机自启只在真的变了时写注册表：每次点开关都去碰 Run 项，容易被安全软件盯上。</summary>
    private void SyncAutoStart()
    {
        var want = AutoStartOn;
        if (want == AutoStart.IsEnabled()) return;
        var exe = Environment.ProcessPath;
        if (exe != null && !AutoStart.Set(want, exe))
            DetailText = "开机自启没写上：注册表 Run 项被策略或安全软件拦了。";
        else AutoStartOn = AutoStart.IsEnabled();
    }

    private static bool TryReadPort(string text, out int port)
        => int.TryParse(text.Trim(), out port) && port is >= 0 and <= 65535;

    /// <summary>校验 + 写进设置（不动内核）。不合法的行只反馈在卡上，不会拦下其他保存。</summary>
    private bool TrySaveRules()
    {
        var s = _manager.Settings;
        var lines = CustomRulesText.Split('\n')
            .Select(x => x.Trim()).Where(x => x.Length > 0 && !x.StartsWith('#')).ToList();
        var accepted = new List<string>();
        var problems = new List<string>();
        for (var i = 0; i < lines.Count; i++)
        {
            var why = ClashConfigGenerator.ValidateCustomRule(lines[i]);
            if (why.Length > 0) problems.Add($"第 {i + 1} 行没收下（{why}）");
            else accepted.Add(lines[i]);
        }
        s.CustomRules.Clear();
        s.CustomRules.AddRange(accepted);
        s.ForceProxySites.Clear();
        s.ForceProxySites.AddRange(SplitDomains(ForceProxyText));
        s.ForceDirectSites.Clear();
        s.ForceDirectSites.AddRange(SplitDomains(ForceDirectText));
        s.AppRouting = AppRoutingChoice switch
        {
            "include" => AppRoutingMode.OnlySelected,
            "exclude" => AppRoutingMode.BypassSelected,
            _ => AppRoutingMode.All,
        };
        s.AppProcesses.Clear();
        foreach (var p in AppProcesses.Split(new[] { ',', '\n', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var name = p.Trim();
            if (name.Length > 0 && !s.AppProcesses.Contains(name)) s.AppProcesses.Add(name);
        }
        RuleFeedback = problems.Count > 0 ? string.Join("；", problems.Take(4)) : "";
        return true;
    }

    /// <summary>
    /// 设置页右上角那颗「保存设置」：改完任意参数点一次就全存下并让内核生效，
    /// 不再每张卡各放一颗按钮（用户数过：同一页六颗「应用设置」）。
    /// </summary>
    private async Task SaveAllAsync()
    {
        if (!TrySaveSettings()) return;
        TrySaveRules();
        SyncAutoStart();
        DetailText = _manager.CoreAlive ? "已保存，正在让内核生效…" : "已保存。";
        await ApplyChangesAsync("设置");
    }

    private async Task RefreshGeoAsync()
    {
        DetailText = "正在下载 / 更新分流库…";
        var landed = await _manager.RefreshGeoAsync();
        DetailText = landed ? "分流库已更新，规则已按新库重载。"
            : (_manager.LastError ?? "分流库没有变化，或一个都没下到。");
        SyncGeoSummary();
    }

    private static List<string> SplitDomains(string text) => text
        .Split(new[] { '\n', '\r', ',', ';', '、', ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries)
        .Select(x => x.Trim().TrimEnd('.')).Where(x => x.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).ToList();

    private async Task ApplyChangesAsync(string what)
    {
        var ok = await _manager.ApplyChangesAsync();
        DetailText = ok
            ? $"{what}已生效（{_manager.LastApplyNote ?? "配置没变，无需重载"}）。"
              + (_manager.TunActive ? " 虚拟网卡在接管。" : "")
            : (_manager.LastError ?? _manager.PendingConfigNote ?? $"{what}生效失败");
        SyncTunStatus();
        SyncGeoSummary();
    }

    private void RestartElevated()
    {
        var exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe)) { DetailText = "拿不到当前程序路径，无法提权重启。"; return; }
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = exe,
                Arguments = "--replace-instance",
                UseShellExecute = true,
                Verb = "runas",
                WorkingDirectory = Path.GetDirectoryName(exe) ?? "",
            });
            DetailText = "正在以管理员身份重启…";
            if (Application.Current is App app) app.ExitApplication();
        }
        catch (Exception e)
        {
            DetailText = "没有获得管理员授权（" + e.Message + "），虚拟网卡还用不了。";
        }
    }

    // ── 连接页 ───────────────────────────────────────────────────────────

    private bool _onConnectionsPage;
    private System.Windows.Threading.DispatcherTimer? _poll;
    private bool _polling;
    private long _lastUp, _lastDown;
    private DateTime _lastPollAt = DateTime.MinValue;

    internal bool IsPollingConnections => _poll != null;

    public void SetActiveTab(string? header)
    {
        // 竖屏三页里「实时连接」并进了首页，所以轮询跟着首页走（只有看得见这张卡的时候才值得轮询）
        _onConnectionsPage = header == "首页";
        ShowSaveButton = header == "设置";
        if (!_onConnectionsPage) { StopConnectionsPolling(); return; }
        StartConnectionsPolling();
    }

    private bool _showSaveButton;

    /// <summary>右上角那颗悬浮「保存设置」只在设置页出现：它挂在滚动区外面，往下滑也不会被盖住。</summary>
    public bool ShowSaveButton { get => _showSaveButton; private set => Set(ref _showSaveButton, value); }

    /// <summary>
    /// 两张次要卡的折叠态放在视图模型里，不放控件上：TabControl 切页会把上一页的视觉树丢掉，
    /// 绑在控件上的话切回来就弹开了（订阅卡的折叠态踩过同一个坑）。
    /// </summary>
    private bool _connectionsExpanded;
    public bool ConnectionsExpanded { get => _connectionsExpanded; set => Set(ref _connectionsExpanded, value); }

    private bool _portsExpanded;
    public bool PortsExpanded { get => _portsExpanded; set => Set(ref _portsExpanded, value); }

    private bool _kernelExpanded;
    public bool KernelExpanded { get => _kernelExpanded; set => Set(ref _kernelExpanded, value); }

    private bool _rulesExpanded;
    public bool RulesExpanded { get => _rulesExpanded; set => Set(ref _rulesExpanded, value); }

    private bool _generalExpanded;
    public bool GeneralExpanded { get => _generalExpanded; set => Set(ref _generalExpanded, value); }

    private void StartConnectionsPolling()
    {
        if (_poll != null) return;
        _poll = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _poll.Tick += (_, _) => PollTick();
        _poll.Start();
        PollTick();
    }

    private void StopConnectionsPolling()
    {
        if (_poll == null) return;
        _poll.Stop();
        _poll = null;
        _lastPollAt = DateTime.MinValue;
    }

    private void PollTick()
    {
        if (_polling) return;
        if (!_manager.CoreAlive)
        {
            Connections.Clear();
            TrafficText = "↑ 0 B/s   ↓ 0 B/s";
            return;
        }
        _polling = true;
        Task.Run(async () =>
        {
            var snap = await _manager.Api.SnapshotAsync().ConfigureAwait(false);
            _polling = false;
            Application.Current?.Dispatcher.BeginInvoke(() => ApplySnapshot(snap));
        });
    }

    internal static (double Up, double Down) Rates(long prevUp, long prevDown, long up, long down, double seconds)
    {
        if (seconds <= 0) return (0, 0);
        // 负差值 == 内核重启过、累计值归零：这一刻的速率是 0，不是天文数字。
        return (Math.Max(0, up - prevUp) / seconds, Math.Max(0, down - prevDown) / seconds);
    }

    internal void ApplySnapshot(Snapshot snap)
    {
        var now = DateTime.Now;
        var seconds = _lastPollAt == DateTime.MinValue ? 0 : Math.Max(0.25, (now - _lastPollAt).TotalSeconds);
        var (up, down) = Rates(_lastUp, _lastDown, snap.UploadTotal, snap.DownloadTotal, seconds);
        _lastUp = snap.UploadTotal;
        _lastDown = snap.DownloadTotal;
        _lastPollAt = now;

        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var c in snap.Connections)
        {
            if (c.Id.Length == 0) continue;
            seen.Add(c.Id);
            var row = Connections.FirstOrDefault(x => x.Id == c.Id);
            if (row == null) { row = new ConnectionItem(c.Id); Connections.Add(row); }
            row.Apply(c, now);
        }
        for (var i = Connections.Count - 1; i >= 0; i--)
            if (!seen.Contains(Connections[i].Id)) Connections.RemoveAt(i);

        var want = Connections.OrderByDescending(x => x.StartAt).ToList();
        for (var i = 0; i < want.Count; i++)
        {
            var at = Connections.IndexOf(want[i]);
            if (at >= 0 && at != i) Connections.Move(at, i);
        }

        TrafficText = $"↑ {ConnectionItem.FmtSpeed(up)}   ↓ {ConnectionItem.FmtSpeed(down)}"
            + $"   ·   累计 ↑{ConnectionItem.FmtBytes(snap.UploadTotal)}"
            + $" ↓{ConnectionItem.FmtBytes(snap.DownloadTotal)}";
        // 连接数从顶栏挪到「实时连接」卡的标题上：顶栏要一直显示得下速率 + 累计，
        // 再塞一段「· 34 条连接」最右边就被截掉（用户点名）。
        Raise(nameof(ConnectionsHeader));
    }

    /// <summary>实时连接卡的标题：折叠着也能看见现在有几条。</summary>
    public string ConnectionsHeader => Connections.Count > 0
        ? $"实时连接（{Connections.Count}）" : "实时连接";

    public void CloseConnection(ConnectionItem? item)
    {
        if (item == null) return;
        _ = CloseOneAsync(item);
    }

    private async Task CloseOneAsync(ConnectionItem item)
    {
        var ok = await _manager.Api.CloseConnectionAsync(item.Id);
        DetailText = ok ? "已断开 " + item.Target + "。" : "那条连接已经自己结束了。";
    }

    // ── 生命周期 ─────────────────────────────────────────────────────────

    public string CloseMode => _manager.Settings.Close switch
    {
        CloseBehavior.Tray => "tray",
        CloseBehavior.Exit => "exit",
        _ => "ask",
    };

    public void RememberCloseBehavior(string choice)
    {
        _manager.Settings.Close = choice switch
        {
            "tray" => CloseBehavior.Tray,
            "exit" => CloseBehavior.Exit,
            _ => CloseBehavior.Ask,
        };
        _manager.SaveSettings();
    }

    // ── 测试接缝 ───────────────────────────────────────────────────────────
    internal void SortForTests() => SortCardsByLatency();
    internal void RebuildForTests() => RebuildLists();

    public async Task ShutdownAsync()
    {
        if (_manager.IsConnected) await _manager.DisconnectAsync();
        _manager.Dispose();
    }

    public void Dispose()
    {
        StopConnectionsPolling();
        _manager.Dispose();
    }
}
