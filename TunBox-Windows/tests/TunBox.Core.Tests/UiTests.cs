using System.IO;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Media;
using TunBox.App;
using TunBox.Core.Storage;
using Xunit;

namespace TunBox.Core.Tests;

/// <summary>共享的 WPF STA 宿主：UI 层的 bug 只有真的起了消息泵才测得出来。</summary>
internal static class WpfHost
{
    private static readonly object Gate = new();
    private static System.Windows.Threading.Dispatcher? _dispatcher;

    public static System.Windows.Threading.Dispatcher Ui
    {
        get
        {
            lock (Gate)
            {
                if (_dispatcher != null) return _dispatcher;
                Exception? bootError = null;
                var ready = new ManualResetEventSlim(false);
                var thread = new Thread(() =>
                {
                    try
                    {
                        _ = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
                        _dispatcher = System.Windows.Threading.Dispatcher.CurrentDispatcher;
                        ready.Set();
                        System.Windows.Threading.Dispatcher.Run();
                    }
                    catch (Exception e) { bootError = e; ready.Set(); }
                });
                thread.SetApartmentState(ApartmentState.STA);
                thread.IsBackground = true;
                thread.Name = "tunbox-wpf-test-pump";
                thread.Start();
                if (!ready.Wait(TimeSpan.FromSeconds(15))) throw new TimeoutException("STA 宿主启动超时");
                if (bootError != null) throw bootError;
                return _dispatcher!;
            }
        }
    }

    public static void OnUi(Action action) => Ui.Invoke(action);

    public static Task<T> OnUi<T>(Func<T> func) => Task.FromResult(Ui.Invoke(func));

    public static bool PumpUntil(Func<bool> predicate, int milliseconds = 8000)
    {
        var deadline = DateTime.UtcNow + TimeSpan.FromMilliseconds(milliseconds);
        var frame = new System.Windows.Threading.DispatcherFrame();
        Ui.InvokeAsync(() =>
        {
            while (DateTime.UtcNow < deadline && !predicate())
            {
                System.Windows.Threading.Dispatcher.CurrentDispatcher.Invoke(
                    System.Windows.Threading.DispatcherPriority.Background, new Action(() => { }));
                Thread.Sleep(20);
            }
            frame.Continue = false;
        });
        System.Windows.Threading.Dispatcher.PushFrame(frame);
        return predicate();
    }
}

/// <summary>
/// UI 层回归。XAML 写错绑定名是**静默**的（不报错、那块区域永远空白），
/// 所以绑定名当成契约逐个验；导入后的列表刷新必须真的发生。
/// </summary>
public class UiTests
{
    private static string TempHome(string tag) => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "TunBox", "ui-" + tag + "-" + Guid.NewGuid().ToString("N")[..6]);

    /// <summary>
    /// 命令里冒出来的异常（真机：热重载超时抛 TaskCanceledException → 「未处理的异常」弹窗）
    /// 必须落在 Failed 上，而不是把弹窗糊在用户脸上。
    /// </summary>
    [Fact]
    public void Async_command_reports_failure_instead_of_popping_a_crash_dialog()
    {
        var seen = WpfHost.OnUi(() =>
        {
            var cmd = new AsyncRelayCommand(_ => Task.FromException(new TaskCanceledException("The operation was canceled.")));
            Exception? caught = null;
            cmd.Failed += e => caught = e;
            cmd.Execute(null);
            WpfHost.PumpUntil(() => caught != null);
            return caught?.GetType().Name;
        }).Result;
        Assert.Equal(nameof(TaskCanceledException), seen);
    }

    /// <summary>总开关要能用颜色分状态：未接管 = 品牌蓝，已接管 = 绿（同色被用户点过名）。</summary>
    [Fact]
    public void Connect_button_changes_color_when_traffic_is_taken_over()
    {
        var xaml = File.ReadAllText(FindSourceFile("MainWindow.xaml"));
        var styles = File.ReadAllText(FindSourceFile(Path.Combine("Assets", "Styles.xaml")));
        Assert.Contains("<SolidColorBrush x:Key=\"Running\"", styles);
        Assert.Contains(@"<DataTrigger Binding=""{Binding IsConnected}"" Value=""True"">", xaml);
        Assert.Contains(@"Value=""{StaticResource Running}""", xaml);
    }

    private static string FindSourceFile(string name)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        for (var depth = 0; dir != null && depth < 8; depth++, dir = dir.Parent)
        {
            foreach (var candidate in new[]
                     {
                         Path.Combine(dir.FullName, "src", "TunBox.App", name),
                         Path.Combine(dir.FullName, "TunBox-Windows", "src", "TunBox.App", name),
                     })
                if (File.Exists(candidate)) return candidate;
        }
        throw new FileNotFoundException("找不到 " + name);
    }

    [Fact]
    public void Every_binding_name_in_the_main_window_resolves_to_a_real_property()
    {
        var xaml = File.ReadAllText(FindSourceFile("MainWindow.xaml"));
        var owners = new[] { typeof(MainViewModel), typeof(NodeItem), typeof(GroupChip),
                              typeof(SubscriptionItem), typeof(ConnectionItem) };
        var unknown = new List<string>();
        foreach (Match m in Regex.Matches(xaml,
                     @"\{Binding\s+(?:Path=)?([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)"))
        {
            var path = m.Groups[1].Value.StartsWith("DataContext.", StringComparison.Ordinal)
                ? m.Groups[1].Value["DataContext.".Length..]
                : m.Groups[1].Value;
            var segments = path.Split('.');
            var candidates = owners;
            var ok = true;
            foreach (var segment in segments)
            {
                var next = new List<Type>();
                foreach (var t in candidates)
                {
                    var prop = t.GetProperty(segment);
                    if (prop != null) next.Add(prop.PropertyType);
                }
                candidates = next.ToArray();
                if (candidates.Length == 0) { ok = false; break; }
            }
            if (!ok) unknown.Add(path);
        }
        Assert.Empty(unknown);
    }

    [Fact]
    public void Main_window_xaml_loads_and_viewmodel_initialises()
    {
        var home = TempHome("load");
        var failure = WpfHost.OnUi(() =>
        {
            try
            {
                var window = new MainWindow(new MainViewModel(new Workspace(home)));
                if (!ReferenceEquals(window.ViewModel, window.DataContext)) return "DataContext 未接上";
                if (window.ViewModel.ProxyMode != "rule") return "默认应为规则模式";
                return null;
            }
            catch (Exception e) { return e.GetType().Name + ": " + e.Message; }
        }).Result;
        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    [Fact]
    public void Importing_share_links_populates_the_merged_subscription_page()
    {
        var home = TempHome("import");
        var (error, nodeCount, cardCount) = WpfHost.OnUi(() =>
        {
            try
            {
                var vm = new MainViewModel(new Workspace(home));
                vm.ImportAsync(
                    "ss://YWVzLTI1Ni1nY206cEBzcw==@1.1.1.1:8389#HK%2001\n"
                    + "ss://YWVzLTI1Ni1nY206cEBzcw==@2.2.2.2:8389#HK%2002");
                var pumped = WpfHost.PumpUntil(() => vm.Nodes.Count > 0);
                if (!pumped) return ("等待超时，列表没有刷新", 0, 0);
                // 订阅卡必须引用同一批 NodeItem：测速刷新一次，展开的每张卡都跟着变
                var card = Assert.Single(vm.Subscriptions);
                return ((string?)null, vm.Nodes.Count, card.Nodes.Count);
            }
            catch (Exception e) { return (e.GetType().Name + ": " + e.Message, 0, 0); }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(error);
        Assert.Equal(2, nodeCount);
        Assert.Equal(2, cardCount);
    }

    /// <summary>选中态必须有视觉反馈，且只有一行被选中（用户报告的「点了没反应」）。</summary>
    [Fact]
    public void Selecting_a_node_marks_it_and_only_it()
    {
        var home = TempHome("select");
        var (first, second, selectedName) = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.ImportAsync(
                "ss://YWVzLTI1Ni1nY206cEBzcw==@1.1.1.1:8389#HK%2001\n"
                + "ss://YWVzLTI1Ni1nY206cEBzcw==@2.2.2.2:8389#HK%2002");
            WpfHost.PumpUntil(() => vm.Nodes.Count > 0);
            var target = vm.Nodes.First(n => n.Name == "HK 02");
            vm.SelectedNode = target;
            return (vm.Nodes[0].IsSelectedNow, vm.Nodes[1].IsSelectedNow, vm.SelectedNode.Name);
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.False(first);
        Assert.True(second);
        Assert.Equal("HK 02", selectedName);
    }

    [Fact]
    public void Latency_colors_follow_the_verge_thresholds()
    {
        var item = WpfHost.OnUi(() =>
        {
            Brush Get(TunBox.Core.Models.ProxyNode n) =>
                (Brush)new NodeItem(n).LatencyBrush;
            return new[]
            {
                (Get(new TunBox.Core.Models.ProxyNode { State = TunBox.Core.Models.DelayState.Ok, LastLatency = 120 }),
                 Get(new TunBox.Core.Models.ProxyNode { State = TunBox.Core.Models.DelayState.Ok, LastLatency = 300 })),
                (Get(new TunBox.Core.Models.ProxyNode { State = TunBox.Core.Models.DelayState.Ok, LastLatency = 500 }),
                 Get(new TunBox.Core.Models.ProxyNode { State = TunBox.Core.Models.DelayState.Timeout, LastLatency = -1 })),
            };
        }).Result;

        Assert.NotEqual(item[0].Item1, item[0].Item2);   // <250 与 250-400 不同色
        Assert.NotEqual(item[1].Item1, item[1].Item2);   // ≥400 与 超时 不同色（橙 vs 红）
    }

    [Fact]
    public void Settings_round_trip_through_disk()
    {
        var home = TempHome("settings");
        var readback = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.MixedPortText = "7897";
            vm.TunOn = false;
            vm.TestUrlText = "http://www.google.com/generate_204";
            vm.ApplySettingsCommand.Execute(null);
            WpfHost.PumpUntil(() => !vm.ApplySettingsCommand.IsRunning);
            var again = new MainViewModel(new Workspace(home));
            return (again.MixedPortText, again.TestUrlText);
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal("7897", readback.MixedPortText);
        Assert.Equal("http://www.google.com/generate_204", readback.TestUrlText);
    }

    /// <summary>
    /// 复现「导入订阅弹一堆窗然后退出」：大订阅（200 节点 + 机场分组 + 信息条伪节点）
    /// 走真实窗口与消息泵，任何 UI 线程异常都会被记进 handler —— 一条都不许有。
    /// </summary>
    [Fact]
    public void Importing_a_large_subscription_does_not_throw_on_the_ui_thread()
    {
        var home = TempHome("stress");
        var failures = new List<string>();
        var home2 = home;
        var (error, nodeCount, subCount) = WpfHost.OnUi(() =>
        {
            var app = Application.Current;
            System.Windows.Threading.DispatcherUnhandledExceptionEventHandler onErr = (_, e) =>
            {
                failures.Add(e.Exception.GetType().Name + ": " + e.Exception.Message);
                e.Handled = true;
            };
            app!.DispatcherUnhandledException += onErr;
            try
            {
                var sb = new System.Text.StringBuilder("proxies:\n");
                for (var i = 1; i <= 200; i++)
                {
                    sb.Append($"  - {{name: HK {i:D3}, type: ss, server: 1.2.3.{i % 250 + 1}, port: {8000 + i}, "
                        + "cipher: aes-256-gcm, password: pw, udp: true}\n");
                }
                sb.Append("  - {name: \"剩余流量：100 GB\", type: ss, server: info.example.com, port: 80, "
                    + "cipher: aes-256-gcm, password: x}\n");
                sb.Append("proxy-groups:\n");
                sb.Append("  - {name: \"🚀 节点选择\", type: select, proxies: [\"HK 001\", \"HK 002\"]}\n");
                sb.Append("  - {name: 自动, type: url-test, proxies: [\"HK 001\", \"HK 002\", \"HK 003\"], "
                    + "url: \"http://cp.cloudflare.com/generate_204\", interval: 300}\n");

                var window = new MainWindow(new MainViewModel(new Workspace(home2)));
                window.Show();
                try
                {
                    window.ViewModel.ImportAsync(sb.ToString());
                    WpfHost.PumpUntil(() => window.ViewModel.Nodes.Count > 0, 15000);
                    WpfHost.PumpUntil(() => window.ViewModel.Subscriptions.Count > 0, 8000);
                    // 每一页都要真正渲染一遍：TwoWay 绑到只读属性这类错，
                    // 只在那一页的卡片被实例化时才炸（订阅页漏测过一次，就是弹窗风暴的来源）
                    foreach (var header in new[] { "订阅", "设置", "首页" })
                    {
                        var tab = FindTab(window, header);
                        if (tab == null) { failures.Add("找不到页签「" + header + "」"); continue; }
                        tab.IsSelected = true;
                        WpfHost.PumpUntil(() => tab.IsSelected);
                        PumpIdle(600);
                    }
                    return ((string?)null, window.ViewModel.Nodes.Count, window.ViewModel.Subscriptions.Count);
                }
                finally { window.Close(); }
            }
            finally { app.DispatcherUnhandledException -= onErr; }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.True(string.IsNullOrEmpty(error), error ?? "");
        Assert.True(nodeCount >= 200, "节点数 " + nodeCount);
        Assert.True(subCount >= 1, "订阅卡数 " + subCount);
        Assert.Empty(failures);
    }

    /// <summary>底部导航必须只有三颗、排在同一行、顺序稳定（竖屏形态，用户钦定）。</summary>
    [Fact]
    public void Bottom_navigation_has_three_tabs_in_one_stable_row()
    {
        var home = TempHome("nav");
        var failure = WpfHost.OnUi<string?>(() =>
        {
            try
            {
                var window = new MainWindow(new MainViewModel(new Workspace(home)));
                window.Show();
                try
                {
                    WpfHost.PumpUntil(() => window.ActualWidth > 100);
                    var tabs = Descendants(window).OfType<System.Windows.Controls.TabItem>()
                        .Where(t => window.Shell.Items.Contains(t)).ToList();
                    if (tabs.Count != 3) return "底部页签数量 " + tabs.Count + "（应为 首页/订阅/设置）";
                    var want = new[] { "首页", "订阅", "设置" };
                    for (var i = 0; i < tabs.Count; i++)
                        if ((string)tabs[i].Header != want[i]) return $"第 {i + 1} 颗应是「{want[i]}」，实际「{tabs[i].Header}」";
                    // 同一行、从左到右：竖屏底部栏不能换行，也不能随选中项重排
                    var pts = tabs.Select(t => t.TranslatePoint(new Point(0, 0), window)).ToList();
                    for (var i = 1; i < pts.Count; i++)
                    {
                        if (Math.Abs(pts[0].Y - pts[i].Y) > 0.5) return $"「{tabs[i].Header}」不在同一行";
                        if (pts[i].X <= pts[i - 1].X) return $"「{tabs[i].Header}」没有排在「{tabs[i - 1].Header}」右边";
                    }
                    // 底部栏必须在窗口下沿（不是顶部）
                    var last = pts[^1];
                    if (last.Y < window.ActualHeight / 2) return "导航栏不在底部";
                    return null;
                }
                finally { window.Close(); }
            }
            catch (Exception e) { return e.GetType().Name + ": " + e.Message; }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    /// <summary>
    /// 「关闭主窗口时」的三个选择必须选完就落盘。以前它只改内存，要等「应用设置」那颗按钮才写，
    /// 而那颗按钮在另一张卡上 —— 用户反馈的「三个选择都没用，每次都缩到托盘」就是这么来的。
    /// </summary>
    [Fact]
    public void Choosing_a_close_behavior_persists_immediately()
    {
        var home = TempHome("close");
        var (exitReadback, trayReadback, liveMode) = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.CloseChoice = "exit";
            var afterExit = new MainViewModel(new Workspace(home)).CloseMode;
            vm.CloseChoice = "tray";
            return (afterExit, new MainViewModel(new Workspace(home)).CloseMode, vm.CloseMode);
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal("exit", exitReadback);
        Assert.Equal("tray", trayReadback);
        Assert.Equal("tray", liveMode);   // 窗口自己也得立刻知道现在是哪个模式
    }

    /// <summary>本轮点名的界面契约：测速用闪电、连接页不再整页断开、退出放在侧栏。</summary>
    [Fact]
    public void Lightning_test_button_and_sidebar_exit_replace_the_old_controls()
    {
        var xaml = File.ReadAllText(FindSourceFile("MainWindow.xaml"));
        Assert.DoesNotContain("断开全部连接", xaml);
        Assert.DoesNotContain("CloseAllConnectionsCommand", xaml);
        Assert.DoesNotContain("全部测速\"", xaml);
        Assert.Contains("&#x26A1;", xaml);
        Assert.Contains("Click=\"OnGroupChipClick\"", xaml);

        var exitAt = xaml.IndexOf("Content=\"退出\"", StringComparison.Ordinal);
        var firstTabAt = xaml.IndexOf("<TabItem Header=", StringComparison.Ordinal);
        Assert.True(exitAt >= 0 && firstTabAt > exitAt, "退出按钮应在顶栏，位于所有页签之前");
        Assert.Equal(exitAt, xaml.LastIndexOf("Content=\"退出\"", StringComparison.Ordinal));   // 全窗口只有一颗
        Assert.DoesNotContain("Content=\"退出 TunBox\"", xaml);   // 长文案会被流量串盖住，已改短

        // 顶栏那条流量串可以很长（速率 + 连接数 + 累计），必须截断，否则会压到退出按钮上
        var header = xaml[..exitAt];
        Assert.Contains("TextTrimming=\"CharacterEllipsis\"", header);
        Assert.Contains("Margin=\"0,0,64,0\"", header);          // 给右上角按钮留出固定空间
    }

    /// <summary>分组 chip 是筛选器，不再是测速按钮（用户明确要「按订阅真实分组显示分组下面的节点」）。</summary>
    [Fact]
    public void Group_chips_are_filters_not_test_buttons()
    {
        var chip = new GroupChip("节点选择", "select", new[] { "a", "b" });
        Assert.Contains("节点选择", chip.Label);
        Assert.Contains("2", chip.Label);           // 成员数要看得见，否则不知道这是谁
        Assert.DoesNotContain("⚡", chip.Label);     // 它不再兼职测速
        var all = new GroupChip("", "", new[] { "a", "b" });
        Assert.StartsWith("全部节点", all.Label);
    }

    /// <summary>点分组只剩该组节点，点「全部节点」再回到全量。</summary>
    [Fact]
    public void Clicking_a_group_shows_only_that_group_s_nodes()
    {
        var home = TempHome("filter");
        var (chips, hkOnly, backToAll) = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.ImportAsync("proxies:\n"
                + "  - {name: HK 01, type: ss, server: 1.2.3.4, port: 8389, cipher: aes-256-gcm, password: pw}\n"
                + "  - {name: HK 02, type: ss, server: 1.2.3.5, port: 8389, cipher: aes-256-gcm, password: pw}\n"
                + "  - {name: US 01, type: ss, server: 1.2.3.6, port: 8389, cipher: aes-256-gcm, password: pw}\n"
                + "proxy-groups:\n"
                + "  - {name: HK组, type: url-test, proxies: [\"HK 01\", \"HK 02\"], "
                + "url: \"http://cp.cloudflare.com/generate_204\", interval: 300}\n");
            WpfHost.PumpUntil(() => vm.Subscriptions.Count > 0);
            var card = vm.Subscriptions.First();
            vm.SelectGroup(card.Groups.FirstOrDefault(g => g.Name == "HK组"));
            var only = card.VisibleNodes.Select(n => n.Name).OrderBy(x => x, StringComparer.Ordinal).ToList();
            vm.SelectGroup(card.Groups.First(g => g.Name.Length == 0));
            return (card.Groups.Count, only, card.VisibleNodes.Count);
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal(2, chips);                     // 「全部节点」+ HK组
        Assert.Equal(new[] { "HK 01", "HK 02" }, hkOnly);
        Assert.Equal(3, backToAll);
    }

    /// <summary>
    /// 测速排序必须作用在**筛选后的列表**上，而且不能被随后的列表重建弹回去：
    /// 界面绑的是 VisibleNodes，只排 Nodes 的话用户看到的顺序一动没动（「全部测速没生效」）。
    /// </summary>
    [Fact]
    public void Latency_sorting_reorders_the_visible_list_and_survives_a_rebuild()
    {
        var home = TempHome("sort");
        var (before, after, kept) = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.ImportAsync("proxies:\n"
                + "  - {name: A slow, type: ss, server: 1.2.3.4, port: 8389, cipher: aes-256-gcm, password: pw}\n"
                + "  - {name: B fast, type: ss, server: 1.2.3.5, port: 8389, cipher: aes-256-gcm, password: pw}\n"
                + "  - {name: C mid, type: ss, server: 1.2.3.6, port: 8389, cipher: aes-256-gcm, password: pw}\n");
            WpfHost.PumpUntil(() => vm.Subscriptions.Count > 0);
            var card = vm.Subscriptions.First();
            var b = card.VisibleNodes.Select(n => n.Name).ToList();
            foreach (var n in vm.Nodes)
                ApplyLatency(n, n.Model.Name.StartsWith("A") ? 900 : n.Model.Name.StartsWith("B") ? 30 : 300);
            vm.SortForTests();
            var a = card.VisibleNodes.Select(n => n.Name).ToList();
            vm.RebuildForTests();
            return (b, a, card.VisibleNodes.Select(n => n.Name).ToList());
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal(new[] { "A slow", "B fast", "C mid" }, before);
        Assert.Equal(new[] { "B fast", "C mid", "A slow" }, after);
        Assert.Equal(after, kept);
    }

    private static void ApplyLatency(NodeItem item, int ms)
    {
        item.Model.State = TunBox.Core.Models.DelayState.Ok;
        item.Model.LastLatency = ms;
    }

    /// <summary>
    /// 从界面一路走到磁盘：打开重绘过的下拉框 → 选中「直接退出」→ CloseMode 变 → 重启还记住。
    /// ComboBox 换了模板，绑定和容器生成都得在真视觉树里验一遍，光看字符串看不出问题。
    /// </summary>
    [Fact]
    public void Closing_choice_combo_box_flows_from_the_ui_to_disk()
    {
        var home = TempHome("combobox");
        var failure = WpfHost.OnUi<string?>(() =>
        {
            try
            {
                var window = new MainWindow(new MainViewModel(new Workspace(home)));
                window.Show();
                try
                {
                    var tab = FindTab(window, "设置");
                    if (tab == null) return "找不到设置页";
                    tab.IsSelected = true;
                    WpfHost.PumpUntil(() => tab.IsSelected);
                    // 「常规」现在默认折叠，下拉框在折叠里 —— 先展开（也证明折叠可用）
                    window.ViewModel.GeneralExpanded = true;
                    PumpIdle(500);

                    var box = Descendants(window).OfType<System.Windows.Controls.ComboBox>()
                        .FirstOrDefault(b => b.Items.OfType<System.Windows.Controls.ComboBoxItem>()
                            .Any(i => (i.Tag as string) == "exit"));
                    if (box == null) return "找不到「关闭主窗口时」的下拉框";

                    box.IsDropDownOpen = true;
                    WpfHost.PumpUntil(() => box.IsDropDownOpen);
                    var item = box.ItemContainerGenerator.ContainerFromIndex(2)
                        as System.Windows.Controls.ComboBoxItem;
                    if (item == null) return "下拉列表没渲染出第三项（模板或容器出问题了）";
                    item.IsSelected = true;
                    WpfHost.PumpUntil(() => (box.SelectedValue as string) == "exit");
                    if ((box.SelectedValue as string) != "exit") return "SelectedValue 没变成 exit";
                    if (window.ViewModel.CloseMode != "exit") return "CloseMode 没跟着界面变";
                    return new MainViewModel(new Workspace(home)).CloseMode == "exit"
                        ? null : "重启后关闭方式没记住";
                }
                finally { window.Close(); }
            }
            catch (Exception e) { return e.GetType().Name + ": " + e.Message; }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    /// <summary>摆位用坐标断言：竖屏窗口、退出按钮在顶栏、下拉框真的画出一颗控件。</summary>
    [Fact]
    public void Portrait_window_keeps_exit_in_the_top_bar_and_combo_boxes_render()
    {
        var home = TempHome("layout");
        var failure = WpfHost.OnUi<string?>(() =>
        {
            try
            {
                var window = new MainWindow(new MainViewModel(new Workspace(home)));
                window.Show();
                try
                {
                    WpfHost.PumpUntil(() => window.ActualWidth > 100);
                    var tabs = Descendants(window).OfType<System.Windows.Controls.TabItem>()
                        .Where(t => window.Shell.Items.Contains(t)).ToList();
                    var exit = Descendants(window).OfType<System.Windows.Controls.Button>()
                        .FirstOrDefault(b => (b.Content as string) == "退出");
                    if (exit == null) return "顶栏里没有退出按钮";
                    var p = exit.TranslatePoint(new Point(0, 0), window);
                    if (window.ActualWidth >= window.ActualHeight) return "窗口不是竖屏（宽 ≥ 高）";
                    if (p.Y > 60) return "退出按钮不在顶栏（Y=" + p.Y + "）";
                    var firstTab = tabs[0].TranslatePoint(new Point(0, 0), window);
                    if (p.Y >= firstTab.Y) return "退出按钮应在导航栏上面";
                    if (p.X + exit.ActualWidth > window.ActualWidth + 0.5) return "退出按钮掉到窗口外面了";

                    var settings = FindTab(window, "设置");
                    if (settings == null) return "找不到设置页";
                    settings.IsSelected = true;
                    WpfHost.PumpUntil(() => settings.IsSelected);
                    // 网络配置与内核两张卡默认折叠，下拉框藏在折叠里 —— 先展开（顺带证明折叠可用）
                    window.ViewModel.PortsExpanded = true;
                    window.ViewModel.GeneralExpanded = true;
                    window.ViewModel.KernelExpanded = true;
                    PumpIdle(500);
                    var boxes = Descendants(window).OfType<System.Windows.Controls.ComboBox>().ToList();
                    if (boxes.Count < 2) return "设置页上的下拉框数量 " + boxes.Count;
                    foreach (var b in boxes)
                    {
                        if (!b.IsVisible) return "有下拉框没显示出来";
                        if (b.ActualHeight < 26) return "下拉框高度只有 " + b.ActualHeight + "，新模板没撑开";
                    }
                    return null;
                }
                finally { window.Close(); }
            }
            catch (Exception e) { return e.GetType().Name + ": " + e.Message; }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    /// <summary>底部提示必须 3 秒自己消失（用户：导入完那句「已导入 24 个节点」一直挂着）。</summary>
    [Fact]
    public void Bottom_hint_disappears_after_three_seconds()
    {
        var home = TempHome("hint");
        var (shown, goneAway) = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.DetailText = "已导入，当前 3 个节点。";
            var shownNow = vm.DetailText;
            var pumped = WpfHost.PumpUntil(() => vm.DetailText.Length == 0, 6000);
            return (shownNow, pumped);
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Equal("已导入，当前 3 个节点。", shown);
        Assert.True(goneAway, "提示没有自动消失");
    }

    /// <summary>子对话框必须比主窗口小（竖屏主窗口只有 470 宽，写死 560 的框会整个盖在上面）。</summary>
    [Fact]
    public void Dialogs_fit_inside_the_main_window()
    {
        var home = TempHome("dialogs");
        var failure = WpfHost.OnUi<string?>(() =>
        {
            var window = new MainWindow(new MainViewModel(new Workspace(home)));
            window.Show();
            WpfHost.PumpUntil(() => window.ActualWidth > 100);
            try
            {
                var import = new ImportDialog { Owner = window };
                import.Show();
                WpfHost.PumpUntil(() => import.ActualWidth > 10);
                var edit = new EditDialog("订阅 A", "https://example.com/sub") { Owner = window };
                edit.Show();
                WpfHost.PumpUntil(() => edit.ActualWidth > 10);
                var msgs = new List<string>();
                if (import.ActualWidth >= window.ActualWidth) msgs.Add($"导入框 {import.ActualWidth:0} ≥ 主窗口 {window.ActualWidth:0}");
                if (edit.ActualWidth >= window.ActualWidth) msgs.Add($"编辑框 {edit.ActualWidth:0} ≥ 主窗口");
                if (import.ActualHeight >= window.ActualHeight) msgs.Add("导入框比主窗口还高");
                import.Close(); edit.Close();
                return msgs.Count > 0 ? string.Join("；", msgs) : null;
            }
            finally { window.Close(); }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    /// <summary>折叠态必须活过列表重建（内核事件一秒好几次，切页回来不能又全弹开）。</summary>
    [Fact]
    public void Collapsed_subscription_card_stays_collapsed_after_a_rebuild()
    {
        var home = TempHome("collapse");
        var (before, after) = WpfHost.OnUi(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.ImportAsync("ss://YWVzLTI1Ni1nY206cEBzcw==@1.1.1.1:8389#HK%2001\n"
                + "ss://YWVzLTI1Ni1nY206cEBzcw==@2.2.2.2:8389#HK%2002");
            WpfHost.PumpUntil(() => vm.Subscriptions.Count > 0);
            var card = vm.Subscriptions.First();
            card.IsExpanded = false;
            vm.RebuildForTests();
            return (false, vm.Subscriptions.First().IsExpanded);
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.False(before);
        Assert.False(after);
    }

    /// <summary>本轮点名的界面契约：电源环、没有系统代理卡、设置页只有一颗悬浮保存、DNS 叫「覆写」且有默认值。</summary>
    [Fact]
    public void Portrait_contracts_power_ring_one_save_button_and_dns_default()
    {
        var xaml = File.ReadAllText(FindSourceFile("MainWindow.xaml"));
        Assert.Contains("x:Name=\"arc\"", xaml);                // 电源符号是画出来的（U+233B 在 Windows 字体里没字形）
        Assert.Contains("x:Name=\"stem\"", xaml);
        Assert.Contains("x:Key=\"PowerRing\"", xaml);
        Assert.Contains("RepeatBehavior=\"Forever\"", xaml);    // 已连接时的呼吸发光
        Assert.DoesNotContain("系统代理", xaml);                  // 启动即系统代理，不给单独开关
        Assert.Equal(1, xaml.Split("Content=\"保存设置\"").Length - 1);
        Assert.DoesNotContain("Content=\"应用设置\"", xaml);
        Assert.DoesNotContain("保存规则设置", xaml);
        Assert.Contains("DNS 覆写", xaml);
        Assert.DoesNotContain("DNS 复写", xaml);
        Assert.Contains("Command=\"{Binding SaveAllCommand}\"", xaml);
        // 两张次要卡可折叠，且折叠态绑在视图模型上（切页回来不能弹开）
        Assert.Contains("IsExpanded=\"{Binding ConnectionsExpanded, Mode=TwoWay}\"", xaml);
        Assert.Contains("IsExpanded=\"{Binding PortsExpanded, Mode=TwoWay}\"", xaml);

        var home = TempHome("dns-default");
        var text = WpfHost.OnUi(() => new MainViewModel(new Workspace(home)).DnsServersText).Result;
        try { Directory.Delete(home, true); } catch { }
        Assert.Contains("tls://223.5.5.5", text);                // 默认值填好，不让用户面对空框
        Assert.Contains("tls://1.12.12.12", text);
    }

    /// <summary>
    /// 顶栏那条流量串可以很长（速率 + 连接数 + 累计），用户截图里它把「退出」按钮盖住了。
    /// 这里用真实长度量一次：两者矩形不许相交。
    /// </summary>
    [Fact]
    public void Long_traffic_line_never_covers_the_exit_button()
    {
        var home = TempHome("overlap");
        var failure = WpfHost.OnUi<string?>(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            var conns = new List<TunBox.Core.Api.Connection>();
            for (var i = 0; i < 34; i++)
                conns.Add(new TunBox.Core.Api.Connection("id" + i, "日本01·移", "api.example-long-host.com",
                    "198.18.0.1", 443, "WeChatAppEx.exe", "tcp", "GEOIP,CN", DateTime.Now, 40_000_000, 14_400_000));
            vm.ApplySnapshot(new TunBox.Core.Api.Snapshot(1_189_000, 14_400_000, conns));
            var window = new MainWindow(vm);
            window.Show();
            WpfHost.PumpUntil(() => window.ActualWidth > 100);
            try
            {
                // 喂快照必须在窗口出来之后：首页一显示就会起轮询，内核没跑时第一轮就把
                // TrafficText 打回「↑ 0 B/s ↓ 0 B/s」了（第一版测试就是这么瞎的）。
                vm.ApplySnapshot(new TunBox.Core.Api.Snapshot(1_189_000, 14_400_000, conns));
                if (vm.TrafficText.Length < 30) return "流量串太短，测不出遮挡：" + vm.TrafficText;
                var exit = Descendants(window).OfType<System.Windows.Controls.Button>()
                    .FirstOrDefault(b => (b.Content as string) == "退出");
                var traffic = Descendants(window).OfType<System.Windows.Controls.TextBlock>()
                    .FirstOrDefault(t => (t.Text ?? "").Contains("累计"));
                if (exit == null) return "找不到退出按钮";
                if (traffic == null)
                {
                    var seen = string.Join(" | ", Descendants(window).OfType<System.Windows.Controls.TextBlock>()
                        .Select(t => t.Text).Where(s => !string.IsNullOrEmpty(s)).Take(12));
                    return $"找不到流量文字（TrafficText={vm.TrafficText}）；树里的文字：{seen}";
                }
                var right = traffic.TranslatePoint(new Point(traffic.ActualWidth, 0), window).X;
                var left = exit.TranslatePoint(new Point(0, 0), window).X;
                return right <= left ? null
                    : $"流量串（右沿 {right:0}）压到退出按钮（左沿 {left:0}）：{vm.TrafficText}";
            }
            finally { window.Close(); }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    /// <summary>
    /// 设置页四节的顺序是固定的（网络配置 / 内核 / 分流规则 / 常规）：
    /// 展开某一节只能在原位撑开，不许跳到页尾——0.4.7 就是靠重排把「网络配置」甩到了最后一个。
    /// </summary>
    [Fact]
    public void Settings_sections_keep_their_order_when_one_expands()
    {
        var home = TempHome("sectionorder");
        var failure = WpfHost.OnUi<string?>(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            vm.PortsExpanded = vm.KernelExpanded = vm.RulesExpanded = vm.GeneralExpanded = false;
            var window = new MainWindow(vm);
            window.Show();
            WpfHost.PumpUntil(() => window.ActualWidth > 100);
            try
            {
                var settings = FindTab(window, "设置");
                if (settings == null) return "找不到设置页";
                settings.IsSelected = true;
                WpfHost.PumpUntil(() => settings.IsSelected);
                PumpIdle(400);

                string? TopDown()
                {
                    var known = new[] { "网络配置", "内核", "分流规则", "常规" };
                    var cards = Descendants(window).OfType<System.Windows.Controls.Border>()
                        .Where(b => b.Child is System.Windows.Controls.Expander
                            && known.Contains(((System.Windows.Controls.Expander)b.Child).Header as string))
                        .OrderBy(b => b.TranslatePoint(new Point(0, 0), window).Y)
                        .Select(b => (string)((System.Windows.Controls.Expander)b.Child).Header!)
                        .ToList();
                    return cards.Count != 4 ? "设置页的四节数量 " + string.Join("/", cards) : string.Join(",", cards);
                }

                var declared = TopDown();
                if (declared!.Contains("数量")) return declared;

                vm.KernelExpanded = true;
                PumpIdle(800);

                var after = TopDown()!;
                return after == declared ? null : $"展开「内核」后排位变了：{declared} → {after}";
            }
            finally { window.Close(); }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    private static System.Windows.Controls.TabItem? FindTab(Window window, string header) =>        Descendants(window).OfType<System.Windows.Controls.TabItem>()
            .FirstOrDefault(t => (t.Header as string) == header);

    /// <summary>
    /// 首页的「出口信息」卡必须夹在虚拟网卡与实时连接之间（用户指定的位置），
    /// 四行标签都要有值 —— 绑错名字的后果是卡片一片空白，用户只会以为程序坏了。
    /// </summary>
    [Fact]
    public void Home_page_puts_the_egress_card_between_tun_and_connections()
    {
        var home = TempHome("egresscard");
        var failure = WpfHost.OnUi<string?>(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            var window = new MainWindow(vm);
            window.Show();
            WpfHost.PumpUntil(() => window.ActualWidth > 100);
            try
            {
                double Y(string text) => Descendants(window).OfType<System.Windows.Controls.TextBlock>()
                    .Where(t => t.Text == text)
                    .Select(t => (double?)t.TranslatePoint(new Point(0, 0), window).Y)
                    .FirstOrDefault() ?? -1;

                var tun = Y("虚拟网卡（TUN）");
                var card = Y("出口信息");
                var conns = Descendants(window).OfType<System.Windows.Controls.Expander>()
                    .Select(e => (double?)e.TranslatePoint(new Point(0, 0), window).Y)
                    .FirstOrDefault() ?? -1;
                if (tun < 0) return "找不到虚拟网卡卡";
                if (card < 0) return "找不到「出口信息」卡";
                if (conns < 0) return "找不到实时连接卡";
                if (!(tun < card && card < conns))
                    return $"卡片位置不对：网卡 y={tun:0} 出口 y={card:0} 连接 y={conns:0}";

                foreach (var label in new[] { "出口 IP", "位置", "运营商", "本机 IP" })
                {
                    var found = Descendants(window).OfType<System.Windows.Controls.TextBlock>()
                        .Any(t => t.Text == label);
                    if (!found) return $"出口信息卡少了「{label}」这一行";
                }
                // 没连接时不许显示成「查到了」，但要有一句话解释为什么是空的
                if (vm.EgressIpText.Length == 0) return "出口 IP 一格没有初值";
                if (vm.EgressNote.Length == 0 && vm.IsConnected) return "已连接却没有说明文案";
                return null;
            }
            finally { window.Close(); }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    /// <summary>
    /// 连着点节点时，「800ms 后查一次出口」的排队不许把界面刷崩。
    /// 上一版用 CancellationTokenSource 做防抖：UI 线程对上一枚 Cancel/Dispose，
    /// 后台任务的 finally 又 Dispose 一次，谁先谁后没有约定 —— 抢输了就是真机那句
    /// 「界面刷新出错：ObjectDisposedException The CancellationTokenSource has been disposed」。
    /// 所以这里刻意留出间隔，让前一次的后台任务先跑完（旧代码在第二次点时必抛）。
    /// </summary>
    [Fact]
    public void Egress_requeue_survives_clicks_spaced_apart()
    {
        var home = TempHome("egressstorm");
        var failure = WpfHost.OnUi<string?>(() =>
        {
            var vm = new MainViewModel(new Workspace(home));
            try
            {
                for (var i = 0; i < 4; i++)
                {
                    vm.PokeEgressForTests($"node-{i}");
                    PumpIdle(1000);   // 让上一轮的延时任务跑完并释放自己
                }
                return null;
            }
            catch (Exception e) { return e.GetType().Name + " " + e.Message; }
        }).Result;

        try { Directory.Delete(home, true); } catch { }
        Assert.Null(failure);
    }

    private static void PumpIdle(int ms) =>
        WpfHost.PumpUntil(() => false, ms);

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        var n = VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < n; i++)
        {
            var c = VisualTreeHelper.GetChild(root, i);
            yield return c;
            foreach (var d in Descendants(c)) yield return d;
        }
    }
}
