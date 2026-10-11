using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using TunBox.Core.Api;

namespace TunBox.Core.Runtime;

public enum CoreState { Stopped, Starting, Running, Failed }

/// <summary>
/// mihomo 子进程宿主。
///
/// 就绪判定是三重信号，不再用「HTTP 轮询 30 秒」这一种（那就是「测速/连接转圈 30 秒然后
/// 连接异常」的来源——本机回环 HTTP 被安全软件拦掉时，内核其实早就起来了）：
///  1. 进程 HasExited → 立刻失败，把日志尾部带给 UI（不再等满预算）；
///  2. stdout 出现 "RESTful API listening at: ..." → 内核侧 API 已就绪（与内核源码核对过这行）；
///  3. 短预算的 GET /version 探测（300ms 一次），作为第 2 条的佐证。
/// 预算 20 秒，总比 30 秒短；同时启动前先杀同路径孤儿内核。
///
/// 子进程挂进 Windows Job Object（KILL_ON_JOB_CLOSE）：GUI 崩溃/被强杀时内核跟着死，
/// 不会留一个占着端口和（TUN 模式下）整机路由的孤儿——v2rayN 同款做法。
/// </summary>
public sealed class CoreHost : IDisposable
{
    /// <summary>必须无 BOM：BOM 会让内核读不到第一个键（mixed-port），卡在初始化之后不监听也不报错。</summary>
    private static readonly Encoding NoBomUtf8 = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);

    private static readonly TimeSpan StartupBudget = TimeSpan.FromSeconds(20);

    private readonly string _homeDir;
    private readonly object _gate = new();
    private readonly Queue<string> _recentLines = new();
    private Process? _process;
    private StreamWriter? _logWriter;
    private int _restartAttempts;
    private IntPtr _job = IntPtr.Zero;

    /// <summary>
    /// stdout 出现 API 监听行的那一刻把它点亮：就绪等待因此是事件驱动的。
    /// 实测内核 42ms 就打印这行，用 500ms 一轮的轮询等它，白等的全是用户体感里的「开关慢」。
    /// </summary>
    private TaskCompletionSource<bool> _listenSignal = NewSignal();

    /// <summary>进程自己退了（配置被拒、崩溃）：就绪等待必须立刻结束，而不是等满预算。</summary>
    private TaskCompletionSource<bool> _exitSignal = NewSignal();

    private static TaskCompletionSource<bool> NewSignal() =>
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    public CoreState State { get; private set; } = CoreState.Stopped;
    public string ConfigPath => Path.Combine(_homeDir, "config.yaml");
    public string LogPath => Path.Combine(_homeDir, "core.log");
    public event Action<CoreState>? StateChanged;

    public static string CoreExecutablePath()
    {
        var candidates = new List<string>
        {
            Path.Combine(AppContext.BaseDirectory, "core", "tunbox-core.exe"),
            Path.Combine(AppContext.BaseDirectory, "tunbox-core.exe"),
        };
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        for (var depth = 0; dir != null && depth < 7; depth++, dir = dir.Parent)
        {
            candidates.Add(Path.Combine(dir.FullName, "core", "tunbox-core.exe"));
            candidates.Add(Path.Combine(dir.FullName, "TunBox-Windows", "core", "tunbox-core.exe"));
        }
        foreach (var c in candidates) if (File.Exists(c)) return c;
        return candidates[0];
    }

    public CoreHost(string homeDir)
    {
        _homeDir = homeDir;
        Directory.CreateDirectory(_homeDir);
    }

    /// <summary>干掉上次崩溃留下的同路径孤儿内核（占着端口甚至整机路由）。</summary>
    public static int KillOrphanCores()
    {
        var own = CoreExecutablePath();
        var killed = 0;
        foreach (var p in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(own)))
        {
            try
            {
                if (p.Id == Environment.ProcessId) continue;
                string? file = null;
                try { file = p.MainModule?.FileName; }
                catch { /* 位数不同或权限受限时读不到模块名：认不准就不杀 */ }
                if (file == null || !string.Equals(file, own, StringComparison.OrdinalIgnoreCase)) continue;
                p.Kill(entireProcessTree: true);
                p.WaitForExit(3000);
                killed++;
            }
            catch { /* 它可能正好自己退了 */ }
            finally { p.Dispose(); }
        }
        return killed;
    }

    public bool IsRunningWith(string config)
    {
        lock (_gate) { return State == CoreState.Running && _lastConfig == config; }
    }

    /// <summary>
    /// 当前跑着的那份配置有没有开 TUN。调用方拿它判断「这次变更是不是要把虚拟网卡打开」——
    /// 实测热重载开 TUN 时网卡要 15s 才就绪，而带 TUN 重启内核只要 363ms，两者必须分开走。
    /// </summary>
    public bool RunningTunEnabled
    {
        get
        {
            lock (_gate) return State == CoreState.Running && _lastConfig.Contains("tun:\n  enable: true");
        }
    }

    public void SetState(CoreState state)
    {
        lock (_gate) { if (State == state) return; State = state; }
        StateChanged?.Invoke(state);
    }

    /// <summary>热重载成功后把新配置落盘并记住：崩溃自愈读它，IsRunningWith 也比它。</summary>
    public void SaveConfig(string configContent)
    {
        File.WriteAllText(ConfigPath, configContent, NoBomUtf8);
        lock (_gate) { _lastConfig = configContent; }
    }

    public async Task StartAsync(string configContent, int apiPort, string secret, CancellationToken ct = default)
    {
        if (State == CoreState.Running) return;
        SetState(CoreState.Starting);
        try
        {
            await File.WriteAllTextAsync(ConfigPath, configContent, NoBomUtf8, ct).ConfigureAwait(false);
            lock (_gate) { _lastConfig = configContent; }
            var exe = CoreExecutablePath();
            if (!File.Exists(exe))
                throw new FileNotFoundException($"找不到内核文件：{exe}。请重新安装 TunBox（安装包应包含 core 目录）。");

            _logWriter?.Dispose();
            _logWriter = new StreamWriter(new FileStream(LogPath, FileMode.Append, FileAccess.Write, FileShare.Read))
            { AutoFlush = true };

            var psi = new ProcessStartInfo
            {
                FileName = exe,
                Arguments = $"-d \"{_homeDir}\" -f \"{ConfigPath}\"",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                WorkingDirectory = _homeDir,
            };
            var p = Process.Start(psi) ?? throw new InvalidOperationException("内核进程启动失败");
            lock (_gate)
            {
                _recentLines.Clear();
                _listenSignal = NewSignal();
                _exitSignal = NewSignal();
                _process = p;
            }
            // 从 spawn 这一刻就要持续读走 stdout/stderr：内核的日志管道写满而不被读时，
            // 它会阻塞在写日志上，**永远走不到创建 API 监听那一步**（Clash Verge 踩过的坑）。
            p.OutputDataReceived += (_, e) => OnCoreLine(p, "out", e.Data);
            p.ErrorDataReceived += (_, e) => OnCoreLine(p, "err", e.Data);
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            p.EnableRaisingEvents = true;
            p.Exited += (_, _) => OnProcessExited(p);
            AssignToJobObject(p);

            var client = new ControllerClient();
            client.Configure(apiPort, secret);
            try
            {
                var sawListenLine = await WaitReadyAsync(client, apiPort, p, ct).ConfigureAwait(false);
                if (p.HasExited)
                    throw new InvalidOperationException(
                        $"内核启动后 {StartupBudget.TotalSeconds:0}s 内自己退出了。日志尾部：\n{TailLog(10)}");
                if (!sawListenLine)
                    throw new TimeoutException(
                        $"内核 {apiPort} 端口控制器在 {StartupBudget.TotalSeconds:0}s 内未就绪。日志尾部：\n{TailLog(10)}");
            }
            finally { client.Dispose(); }
            _restartAttempts = 0;
            SetState(CoreState.Running);
        }
        catch
        {
            SetState(CoreState.Failed);
            StopProcess();
            throw;
        }
    }

    /// <summary>
    /// 等待就绪：**两路信号赛跑，谁先到算谁**，不再按固定节奏轮询。
    /// 实测内核从 spawn 到打印 API 监听行只要 42ms，轮询（300ms 探测 + 200ms 睡）
    /// 白等的都是用户体感里的「开关卡一下」。
    /// 进程自己退了 → 立刻失败；监听行先到 → 只给 /version 400ms 佐证预算
    /// （回环 HTTP 被拦的机器上探不到，但内核是真就绪的，不能让用户陪跑预算）。
    /// </summary>
    private async Task<bool> WaitReadyAsync(ControllerClient client, int apiPort, Process p, CancellationToken ct)
    {
        TaskCompletionSource<bool> listen;
        TaskCompletionSource<bool> exited;
        lock (_gate) { listen = _listenSignal; exited = _exitSignal; }
        if (SawListenLine(apiPort)) listen.TrySetResult(true);

        // 取消位连着三路等待：赢家出现后，输的那些必须马上收摊，
        // 不能留一个还在轮询已 Dispose 的 HttpClient 的后台任务。
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var budget = Task.Delay(StartupBudget, stop.Token);
        var versionCall = client.WaitReadyAsync(StartupBudget, stop.Token);
        var http = Watch(versionCall);
        var won = await Task.WhenAny(listen.Task, http, exited.Task, budget).ConfigureAwait(false);
        var byHttp = ReferenceEquals(won, http) && versionCall.IsCompletedSuccessfully && versionCall.Result;
        stop.Cancel();
        await Task.WhenAll(http, Watch(budget)).ConfigureAwait(false);

        if (byHttp) return true;
        if (exited.Task.IsCompleted || p.HasExited) return false;
        if (ReferenceEquals(won, budget)) return false;

        // 监听行先到：给 /version 一小段佐证预算（回环 HTTP 被拦的机器上探不到，仍按就绪处理）
        var confirm = client.WaitReadyAsync(TimeSpan.FromMilliseconds(400), CancellationToken.None);
        await Watch(confirm).ConfigureAwait(false);
        if (!confirm.IsCompletedSuccessfully || !confirm.Result)
            WriteLog("app", "API 监听行已出现，但 /version 没探测到——回环 HTTP 可能被本机安全软件拦住，仍按就绪处理");
        return true;
    }

    /// <summary>把「输了的那一路」安静地收掉：不能让它在后台抛未观察异常，也不能卡住调用方。</summary>
    private static async Task Watch(Task task)
    {
        try { await task.ConfigureAwait(false); }
        catch { /* 输掉的比赛任务：取消/超时都是正常结局 */ }
    }

    private bool SawListenLine(int apiPort)
    {
        lock (_gate)
        {
            var marker = $"RESTful API listening at: 127.0.0.1:{apiPort}";
            return _recentLines.Any(l => l.Contains(marker, StringComparison.OrdinalIgnoreCase)
                || (l.Contains("RESTful API listening", StringComparison.OrdinalIgnoreCase) && l.Contains(apiPort.ToString())));
        }
    }

    private void OnCoreLine(Process p, string tag, string? line)
    {
        if (line == null) return;
        var listening = line.Contains("RESTful API listening", StringComparison.OrdinalIgnoreCase);
        lock (_gate)
        {
            _recentLines.Enqueue(line);
            while (_recentLines.Count > 200) _recentLines.Dequeue();
            if (listening) _listenSignal.TrySetResult(true);
        }
        WriteLog(tag, line);
    }

    private void WriteLog(string tag, string line)
    {
        try { _logWriter?.WriteLine($"[{DateTime.Now:HH:mm:ss}] {tag}: {line}"); }
        catch { /* 日志失败绝不能影响转发 */ }
    }

    /// <summary>内核自己挂了（配置错误、崩溃）时就地重试，带退避与次数上限。</summary>
    private void OnProcessExited(Process p)
    {
        lock (_gate)
        {
            _exitSignal.TrySetResult(true);
            if (_process != p) return;      // 已被 Stop() 主动替换/结束
            _process = null;
        }
        if (State == CoreState.Stopped) return;
        if (_restartAttempts >= 3)
        {
            SetState(CoreState.Failed);
            WriteLog("app", $"内核连续失败 {_restartAttempts} 次，停止自动恢复");
            return;
        }
        _restartAttempts++;
        SetState(CoreState.Starting);
        Task.Run(async () =>
        {
            await Task.Delay(1000 * _restartAttempts).ConfigureAwait(false);
            try
            {
                if (File.Exists(ConfigPath))
                {
                    var cfg = await File.ReadAllTextAsync(ConfigPath).ConfigureAwait(false);
                    await StartAsync(cfg, _apiPort, _secret).ConfigureAwait(false);
                }
            }
            catch (Exception e)
            {
                WriteLog("app", "自动恢复失败: " + e.Message);
                SetState(CoreState.Failed);
            }
        });
    }

    public string TailLog(int lines = 8)
    {
        try
        {
            if (!File.Exists(LogPath)) return "";
            using var fs = new FileStream(LogPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var start = Math.Max(0, fs.Length - 16384);
            fs.Seek(start, SeekOrigin.Begin);
            using var reader = new StreamReader(fs, Encoding.UTF8);
            var text = reader.ReadToEnd();
            var all = text.Split('\n').Select(l => l.Replace("\r", "")).Where(l => l.Trim().Length > 0).ToList();
            return string.Join('\n', all.Skip(Math.Max(0, all.Count - Math.Max(1, lines))));
        }
        catch { return ""; }
    }

    public Task StartWithParamsAsync(string configContent, int apiPort, string secret, CancellationToken ct = default)
    {
        _apiPort = apiPort;
        _secret = secret;
        return StartAsync(configContent, apiPort, secret, ct);
    }

    public void Stop()
    {
        SetState(CoreState.Stopped);
        StopProcess();
    }

    /// <summary>
    /// 停内核。**别指望 CloseMainWindow**：内核是 CreateNoWindow 的隐藏进程，没有主窗口可关，
    /// 那句只会让我们白等满 2 秒（实测「拨一下 TUN 开关要 2.5s」全卡在这）。
    /// 直接 Kill（Job Object 连子进程一起收），等进程真退了再确认监听端口放开——
    /// 端口没放开就重启，下一次启动就是「bind: Only one usage of each socket address」。
    /// </summary>
    private void StopProcess()
    {
        Process? p;
        lock (_gate) { p = _process; _process = null; }
        if (p == null) return;
        try
        {
            if (!p.HasExited)
            {
                p.Kill(entireProcessTree: true);
                p.WaitForExit(1500);
            }
        }
        catch { /* 进程可能已经自己退了 */ }
        finally { p.Dispose(); }
        WaitForPortReleased();
    }

    private void WaitForPortReleased(int budgetMs = 1200)
    {
        if (_apiPort <= 0) return;
        var deadline = Environment.TickCount64 + budgetMs;
        while (Environment.TickCount64 < deadline)
        {
            if (TunBox.Core.Config.LocalPorts.Available(_apiPort)) return;
            Thread.Sleep(50);
        }
    }

    // ── Windows Job Object：GUI 死了内核必须跟着死 ─────────────────────────

    public void Dispose()
    {
        StopProcess();
        _logWriter?.Dispose();
        if (_job != IntPtr.Zero)
        {
            CloseHandle(_job);
            _job = IntPtr.Zero;
        }
    }

    private void AssignToJobObject(Process p)
    {
        try
        {
            _job = CreateJobObject(IntPtr.Zero, null);
            var info = new JOBOBJECT_BASIC_LIMIT_INFORMATION
            {
                LimitFlags = JobObjectLimitFlags.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            };
            var ext = new IO_COUNTERS();
            var pointer = IntPtr.Size == 8
                ? Marshal.AllocHGlobal(Marshal.SizeOf<JobObjectExtendedLimitInformation64>())
                : Marshal.AllocHGlobal(Marshal.SizeOf<JobObjectExtendedLimitInformation32>());
            try
            {
                if (IntPtr.Size == 8)
                {
                    var ext64 = new JobObjectExtendedLimitInformation64 { BasicLimitInformation = info, IoInfo = ext };
                    Marshal.StructureToPtr(ext64, pointer, false);
                    if (SetInformationJobObject(_job, JobObjectInfoClass.JobObjectExtendedLimitInformation,
                            pointer, Marshal.SizeOf<JobObjectExtendedLimitInformation64>()))
                        _ = AssignProcessToJobObject(_job, p.Handle);
                }
                else
                {
                    var ext32 = new JobObjectExtendedLimitInformation32 { BasicLimitInformation = info, IoInfo = ext };
                    Marshal.StructureToPtr(ext32, pointer, false);
                    if (SetInformationJobObject(_job, JobObjectInfoClass.JobObjectExtendedLimitInformation,
                            pointer, Marshal.SizeOf<JobObjectExtendedLimitInformation32>()))
                        _ = AssignProcessToJobObject(_job, p.Handle);
                }
            }
            finally { Marshal.FreeHGlobal(pointer); }
        }
        catch { /* 分配不上就退化为旧行为：孤儿由下次启动清理 */ }
    }

    private string _lastConfig = "";
    private int _apiPort = 9090;
    private string _secret = "";

    private enum JobObjectInfoClass { JobObjectExtendedLimitInformation = 9 }

    [Flags]
    private enum JobObjectLimitFlags : uint
    {
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000,
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public JobObjectLimitFlags LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformation64
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformation32
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public uint ProcessMemoryLimit;
        public uint JobMemoryLimit;
        public uint PeakProcessMemoryUsed;
        public uint PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string? lpName);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr hJob, JobObjectInfoClass infoClass,
        IntPtr lpInfo, int cbInfo);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);
}
