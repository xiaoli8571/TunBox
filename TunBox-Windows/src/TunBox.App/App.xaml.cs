using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using TunBox.Core.Runtime;

namespace TunBox.App;

public partial class App : Application
{
    private const string MutexName = "Local\\TunBox.Windows.SingleInstance";
    private const string ShowEventName = "Local\\TunBox.Windows.Show";
    private const string ReplaceInstanceFlag = "--replace-instance";
    private const string MinimizedFlag = "--minimized";

    private TrayIcon? _tray;
    private MainWindow? _window;
    private Mutex? _mutex;
    private EventWaitHandle? _showEvent;
    private bool _cleaningUp;

    /// <summary>已经在走退出流程：不能再拦 OnClosing 去弹询问，否则关窗时自己把自己挡回去。</summary>
    public bool IsExiting { get; private set; }

    /// <summary>托盘是否真的可用；不可用时关窗口必须直接退出。</summary>
    public bool TrayAvailable => _tray is { Available: true };

    /// <summary>崩溃/异常日志目录：%APPDATA%\TunBox\logs。用户报告「弹窗后退出了」全靠它定位。</summary>
    public static string CrashLogDir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "TunBox", "logs");

    private static void WriteCrashLog(string kind, Exception? e, string extra)
    {
        try
        {
            Directory.CreateDirectory(CrashLogDir);
            var file = Path.Combine(CrashLogDir, kind + "-" + DateTime.Now.ToString("yyyyMMdd") + ".log");
            // 上限 8MB：渲染循环每帧抛一次的话，无上限的日志一分钟能写 70MB（实测）。
            // 超限轮转（删旧开新）而不是停写：否则真正需要日志的那次崩溃什么都不会留下。
            if (File.Exists(file) && new FileInfo(file).Length > 8 * 1024 * 1024) File.Delete(file);
            File.AppendAllText(file,
                $"[{DateTime.Now:HH:mm:ss.fff}] {kind} {extra}\n"
                + (e == null ? "(无异常对象)" : e.GetType().Name + ": " + e.Message + "\n" + e.StackTrace) + "\n\n");
        }
        catch { /* 日志写不进去也不能再抛 */ }
    }

    private int _popupCount;

    /// <summary>启动路径面包屑：静默退出（退出码 0）时，最后一条就是断点。</summary>
    private void Step(string what) => WriteCrashLog("steps", null, what);

    /// <summary>
    /// UI 线程未处理异常。弹窗必须有上限：如果是渲染路径反复抛（比如某个模板每帧都炸），
    /// 无上限就是用户看到的「导入订阅弹出一大堆弹窗」。
    /// </summary>
    private void OnDispatcherException(object sender, DispatcherUnhandledExceptionEventArgs args)
    {
        WriteCrashLog("ui", args.Exception, "");
        args.Handled = true;
        var count = Interlocked.Increment(ref _popupCount);
        if (count <= 3)
        {
            var detail = args.Exception.InnerException?.Message ?? args.Exception.Message;
            System.Windows.MessageBox.Show(
                "出现未处理的异常（已记录到 " + CrashLogDir + "）：\n" + detail,
                "TunBox", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        else if (count == 4)
        {
            System.Windows.MessageBox.Show(
                "同类异常反复出现，后续不再弹窗。完整记录在 " + CrashLogDir,
                "TunBox", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        Step("startup begin");
        _mutex = new Mutex(true, MutexName, out var isNew);
        Step("mutex isNew=" + isNew);
        if (!isNew && e.Args.Contains(ReplaceInstanceFlag)) isNew = WaitForPreviousInstance();
        if (!isNew)
        {
            // 已经有实例：能把它叫回来就安静退出，叫不动才提示一句。
            if (WakeRunningInstance()) { Step("single-instance: wake ok, shutdown"); Shutdown(); return; }
            Step("single-instance: wake failed, showing messagebox");
            System.Windows.MessageBox.Show("TunBox 已经在运行（托盘图标可能被 Win11 收进了溢出区，点托盘小箭头找找）。",
                "TunBox", MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }
        Step("single-instance passed");

        // 上次崩溃可能把系统代理留在一个死端口上；必须在任何 UI 之前先恢复。
        try { SystemProxy.RestoreIfStale(); } catch { /* 注册表被拦时不阻止启动 */ }
        try { CoreHost.KillOrphanCores(); } catch { /* 清理失败不挡启动 */ }
        Step("cleanup done");

        DispatcherUnhandledException += OnDispatcherException;
        AppDomain.CurrentDomain.ProcessExit += (_, _) => Cleanup();
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            // 进程即将终止前的最后记录：没有这份日志，「导入时弹一堆窗然后退出」永远查不出原因
            WriteCrashLog("fatal", args.ExceptionObject as Exception,
                "IsTerminating=" + args.IsTerminating);
            Cleanup();
        };
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            WriteCrashLog("task", args.Exception, "");
            args.SetObserved();   // 记下来即可，不该让一个被遗忘的后台任务带走进程
        };

        // 托盘要在建窗口之前搞定：视图模型要显示「托盘到底可用吗」。
        SetupTray();
        Step("tray done, available=" + TrayAvailable);
        StartShowListener();
        _window = new MainWindow();
        if (e.Args.Contains(MinimizedFlag)) _window.Hide();   // 开机自启：不要弹窗口挡在桌面上
        else _window.Show();
        Step("window shown");
        base.OnStartup(e);
    }

    private static bool WakeRunningInstance()
    {
        try
        {
            if (!EventWaitHandle.TryOpenExisting(ShowEventName, out var handle)) return false;
            using (handle) { return handle.Set(); }
        }
        catch { return false; }
    }

    private void StartShowListener()
    {
        try { _showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName, out _); }
        catch { return; }
        var listener = new Thread(() =>
        {
            while (true)
            {
                try { if (_showEvent == null || !_showEvent.WaitOne(Timeout.Infinite)) return; }
                catch { return; }
                if (IsExiting) return;
                try { Dispatcher.BeginInvoke(ShowMainWindow); }
                catch { return; }
            }
        }) { IsBackground = true, Name = "tunbox-show-listener" };
        listener.Start();
    }

    /// <summary>前一个实例正在退出（提权重启的交接窗口）。等到锁放开为止。</summary>
    private bool WaitForPreviousInstance()
    {
        try { return _mutex!.WaitOne(TimeSpan.FromSeconds(15)); }
        catch (AbandonedMutexException) { return true; }
        catch { return false; }
    }

    /// <summary>托盘：纯 Win32 Shell_NotifyIcon（见 TrayIcon）。</summary>
    private void SetupTray()
    {
        try
        {
            var iconPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "TunBox", "tray.ico");
            using (var stream = GetResourceStream(new Uri("Assets/tunbox.ico", UriKind.Relative))?.Stream)
            {
                if (stream == null) return;
                using var target = File.Create(iconPath);
                stream.CopyTo(target);
            }

            _tray = new TrayIcon(iconPath, "TunBox");
            if (!_tray.TryCreate()) { _tray = null; return; }
            _tray.ShowRequested += ShowMainWindow;
            _tray.ExitRequested += ExitApplication;
        }
        catch
        {
            // 托盘建不出来时绝不能把关窗口当成隐藏：那样进程既看不见也关不掉。
            _tray = null;
        }
    }

    private void ShowMainWindow()
    {
        if (_window == null) return;
        _window.Show();
        MainWindow = _window;
        _window.WindowState = WindowState.Normal;
        _window.Activate();
    }

    public void MinimizeToTray()
    {
        _window?.Hide();
        try { _tray?.ShowBalloon("TunBox 正在后台运行",
            "点托盘图标或再运行一次 TunBox 都能唤回主窗口。要彻底退出请用托盘菜单里的「退出」。"); }
        catch { /* 气泡失败不影响主流程 */ }
    }

    /// <summary>唯一可靠的退出入口：ShutdownMode 是 OnExplicitShutdown。</summary>
    public async void ExitApplication()
    {
        IsExiting = true;
        await CleanupAsync();
        Shutdown();
    }

    private async Task CleanupAsync()
    {
        if (_cleaningUp) return;
        _cleaningUp = true;
        try { if (_window?.ViewModel != null) await _window.ViewModel.ShutdownAsync(); }
        catch { /* 退出路径上的异常不能再抛出去 */ }
        try { SystemProxy.Disable(); } catch { }
        _tray?.Dispose();
        _tray = null;
    }

    private void Cleanup()
    {
        // 进程退出钩子里没有可用的消息循环，只能同步等一小会儿。
        try { CleanupAsync().Wait(TimeSpan.FromSeconds(5)); } catch { }
        try { _mutex?.ReleaseMutex(); } catch { }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        Cleanup();
        base.OnExit(e);
    }
}
