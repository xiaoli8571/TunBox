using System.IO;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using TunBox.App;
using TunBox.Core.Models;

namespace TunBox.App;

public partial class MainWindow : Window
{
    public MainViewModel ViewModel { get; }

    public MainWindow() : this(null) { }

    /// <summary>可注入视图模型：默认构造会落到用户真实的 %APPDATA%\TunBox，测试必须能注入。</summary>
    public MainWindow(MainViewModel? viewModel)
    {
        InitializeComponent();
        ViewModel = viewModel ?? new MainViewModel();
        DataContext = ViewModel;
        try
        {
            // 任务栏/标题栏的大图标从磁盘上的 ico 取：WPF 对多帧 ico 取帧的大小
            // 与位图来源有关，直接用文件最稳。SetupTray 已把它写到 %APPDATA%\TunBox。
            var iconPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "TunBox", "tray.ico");
            if (File.Exists(iconPath))
                Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri(iconPath));
            else
                Icon = System.Windows.Media.Imaging.BitmapFrame.Create(
                    new Uri("pack://application:,,,/Assets/tunbox.ico"));
        }
        catch { /* 图标失败不影响功能 */ }
    }

    /// <summary>「＋」导入：链接 / 本地文件 / 粘贴节点（对话框里三选一）。</summary>
    private async void OnImportClick(object sender, RoutedEventArgs e)
    {
        var dialog = new ImportDialog { Owner = this };
        if (dialog.ShowDialog() != true || dialog.Result == null) return;
        var (kind, value) = dialog.Result.Value;
        switch (kind)
        {
            case "file": await ViewModel.ImportFileAsync(value); break;
            case "url" or "text": await ViewModel.ImportAsync(value); break;
        }
    }

    /// <summary>首页的开关：拨一下就把「保存 + 立刻接管/放手」整条路走完，不用再去点「连接」。</summary>
    private async void OnToggleApply(object sender, RoutedEventArgs e)
    {
        await ViewModel.ApplySwitchAsync();
    }

    /// <summary>点分组 chip = 按该分组筛选节点。直接调视图模型，不走命令绑定（绑定失败是静默的，踩过）。</summary>
    private void OnGroupChipClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: GroupChip chip })
            ViewModel.SelectGroup(chip);
    }

    /// <summary>订阅卡上的 ⚡：只测当前页面显示的那一屏节点。</summary>
    private void OnTestSubClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: SubscriptionItem item })
            ViewModel.TestSubscription(item);
    }

    /// <summary>编辑订阅（名称 / 链接）。</summary>
    private void OnEditSubClick(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: SubscriptionItem item }) return;
        var dialog = new EditDialog(item.Name, item.Model.Url) { Owner = this };
        if (dialog.ShowDialog() != true) return;
        var (name, url) = dialog.Values;
        if (name.Length == 0) { ViewModel.DetailText = "订阅名称不能为空。"; return; }
        ViewModel.EditSubscription(item, name, url);
    }

    /// <summary>
    /// 设置页每一节都可折叠；折叠着的排在上面，展开的自动挪到后面 ——
    /// 这样这一页平时是一列整齐的条，不会有人展开一节就高低不平。
    /// </summary>
    private void OnSectionToggled(object sender, RoutedEventArgs e) =>
        Dispatcher.BeginInvoke(new Action(SortSettingsSections));

    private void SortSettingsSections()
    {
        var sections = new[] { SecNetwork, SecKernel, SecRules, SecGeneral };
        // 稳定排序：折叠(0) 在前、展开(1) 在后，同组内保持声明顺序
        var order = sections
            .OrderBy(b => ((System.Windows.Controls.Expander)((System.Windows.Controls.Border)b).Child).IsExpanded ? 1 : 0)
            .ToList();
        for (var i = 0; i < order.Count; i++)
        {
            var at = SettingsPanel.Children.IndexOf(order[i]);
            // UIElementCollection 没有 Move（ObservableCollection 才有），只能摘了再插
            if (at >= 0 && at != i)
            {
                SettingsPanel.Children.Remove(order[i]);
                SettingsPanel.Children.Insert(i, order[i]);
            }
        }
    }

    /// <summary>页签切换 → 连接页要轮询，别的页不该摊上这份开销。</summary>
    private void OnTabChanged(object sender, SelectionChangedEventArgs e)
    {
        if (sender is TabControl { SelectedItem: TabItem tab })
            ViewModel.SetActiveTab(tab.Header as string);
    }

    /// <summary>点节点行 = 把出口切到这一行。</summary>
    private void OnNodeRowClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: NodeItem item })
            ViewModel.SelectedNode = item;
    }

    /// <summary>点延迟数字 = 只测这一个节点。</summary>
    private void OnLatencyClick(object sender, System.Windows.Input.MouseButtonEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: NodeItem item })
        {
            ViewModel.TestOne(item);
            e.Handled = true;   // 别让同一次点击又触发整行的选中
        }
    }

    private void OnUpdateSubClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: SubscriptionItem item })
            _ = ViewModel.UpdateSubscriptionAsync(item);
    }

    private void OnRemoveSubClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: SubscriptionItem item })
            ViewModel.RemoveSubscription(item);
    }

    private void OnCloseConnClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: ConnectionItem item })
            ViewModel.CloseConnection(item);
    }

    /// <summary>
    /// 点 X 的去向：问一次并记住，或者按记住的选择走。托盘不可用时不给「缩到托盘」这个选项。
    /// </summary>
    protected override void OnClosing(CancelEventArgs e)
    {
        if (Application.Current is not App app || app.IsExiting)
        {
            base.OnClosing(e);
            return;
        }
        e.Cancel = true;
        var choice = ViewModel.CloseMode;
        if (choice == "ask")
        {
            var allowTray = app.TrayAvailable;
            var result = MessageBox.Show(this,
                allowTray ? "关闭窗口后缩到系统托盘继续运行吗？\n\n「是」= 缩到托盘，「否」= 退出 TunBox，进程和内核都结束。"
                          : "系统托盘不可用：现在关闭窗口就会退出 TunBox。确定退出吗？",
                "TunBox", MessageBoxButton.YesNo, MessageBoxImage.Question);
            choice = result == MessageBoxResult.Yes ? (allowTray ? "tray" : "exit") : "cancel";
            if (choice == "cancel") return;
            ViewModel.RememberCloseBehavior(choice);
        }
        if (choice == "tray" && app.TrayAvailable) app.MinimizeToTray();
        else app.ExitApplication();
    }
}
