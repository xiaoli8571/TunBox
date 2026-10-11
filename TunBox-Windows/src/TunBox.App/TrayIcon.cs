using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace TunBox.App;

/// <summary>
/// 纯 Win32 托盘图标（Shell_NotifyIcon），不经过 WinForms。
///
/// 为什么要抛弃 WinForms NotifyIcon：实测（本机）WinForms 控件的
/// <c>Control.get_IsAccessibilityObjectCreated</c> 在自包含发布下加载
/// Accessibility 程序集失败 → FileNotFoundException → 进程致命退出，
/// 而且触发点在系统消息回调里，任何 try/catch 都拦不住。
/// 应用里 WinForms 只为这一个托盘图标存在，不值得为它背一整个崩溃面。
/// </summary>
public sealed class TrayIcon : IDisposable
{
    private const int WM_APP_TRAY = 0x8000;          // WM_APP
    private const int WM_LBUTTONUP = 0x0202;
    private const int WM_LBUTTONDBLCLK = 0x0203;
    private const int WM_RBUTTONUP = 0x0205;
    private const int NIM_ADD = 0x0;
    private const int NIM_MODIFY = 0x1;
    private const int NIM_DELETE = 0x2;
    private const int NIF_MESSAGE = 0x1;
    private const int NIF_ICON = 0x2;
    private const int NIF_TIP = 0x4;
    private const int NIF_INFO = 0x10;
    private const int NIIF_INFO = 0x1;

    public event Action? ShowRequested;
    public event Action? ExitRequested;

    private IntPtr _hwnd;
    private HwndSource? _source;
    private IntPtr _hicon;
    private bool _added;
    private readonly string _tip;
    private readonly string _iconPath;

    public bool Available => _added;

    public TrayIcon(string iconPath, string tip)
    {
        _iconPath = iconPath;
        _tip = tip;
    }

    /// <summary>创建消息窗口并注册托盘图标。失败返回 false（界面照常可用，只是没有托盘）。</summary>
    public bool TryCreate()
    {
        try
        {
            var parameters = new HwndSourceParameters("TunBoxTrayWindow", 0, 0)
            {
                WindowStyle = 0,                       // message-only：不显示、不进任务栏
                ExtendedWindowStyle = 0,
                PositionX = 0,
                PositionY = 0,
                Width = 0,
                Height = 0,
                ParentWindow = new IntPtr(-3),          // HWND_MESSAGE
            };
            _source = new HwndSource(parameters);
            _hwnd = _source.Handle;
            _source.AddHook(WndProc);

            _hicon = LoadImage(IntPtr.Zero, _iconPath, IMAGE_ICON, 0, 0,
                LR_LOADFROMFILE | LR_DEFAULTSIZE);
            if (_hicon == IntPtr.Zero) return false;

            var data = WithTip(new NOTIFYICONDATAW
            {
                cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATAW>(),
                hWnd = _hwnd,
                uID = 1,
                uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP,
                uCallbackMessage = WM_APP_TRAY,
                hIcon = _hicon,
            }, _tip);
            _added = Shell_NotifyIcon(NIM_ADD, ref data);
            return _added;
        }
        catch { return false; }
    }

    public void SetTip(string tip)
    {
        if (!_added) return;
        var data = WithTip(new NOTIFYICONDATAW
        {
            cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATAW>(),
            hWnd = _hwnd,
            uID = 1,
            uFlags = NIF_TIP,
        }, tip);
        Shell_NotifyIcon(NIM_MODIFY, ref data);
    }

    /// <summary>气泡提示（「程序还在后台运行」等）。</summary>
    public void ShowBalloon(string title, string message)
    {
        if (!_added) return;
        var data = WithTip(new NOTIFYICONDATAW
        {
            cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATAW>(),
            hWnd = _hwnd,
            uID = 1,
            uFlags = NIF_INFO,
        }, message);
        CopyTitle(ref data, title);
        data.dwInfoFlags = NIIF_INFO;
        Shell_NotifyIcon(NIM_MODIFY, ref data);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != WM_APP_TRAY) return IntPtr.Zero;
        handled = true;
        switch (lParam.ToInt64())
        {
            case WM_LBUTTONUP or WM_LBUTTONDBLCLK:
                ShowRequested?.Invoke();
                break;
            case WM_RBUTTONUP:
                ShowMenu();
                break;
        }
        return IntPtr.Zero;
    }

    /// <summary>右键菜单：显示 / 退出。WPF 的 ContextMenu 用绝对坐标打开即可，不需要宿主窗口。</summary>
    private void ShowMenu()
    {
        var menu = new System.Windows.Controls.ContextMenu();
        var show = new System.Windows.Controls.MenuItem { Header = "显示主界面" };
        show.Click += (_, _) => ShowRequested?.Invoke();
        var exit = new System.Windows.Controls.MenuItem { Header = "退出 TunBox" };
        exit.Click += (_, _) => ExitRequested?.Invoke();
        menu.Items.Add(show);
        menu.Items.Add(new System.Windows.Controls.Separator());
        menu.Items.Add(exit);
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.AbsolutePoint;
        GetCursorPos(out var pt);
        menu.PlacementRectangle = new System.Windows.Rect(pt.X, pt.Y - 8, 0, 0);
        menu.IsOpen = true;
    }

    private static NOTIFYICONDATAW WithTip(NOTIFYICONDATAW data, string tip)
    {
        data.szTip = tip.Length > 127 ? tip[..127] : tip;   // ByValTStr[128]，留一个收尾
        return data;
    }

    private static void CopyTitle(ref NOTIFYICONDATAW data, string title)
    {
        data.szInfoTitle = title.Length > 63 ? title[..63] : title;
    }

    public void Dispose()
    {
        if (_added)
        {
            var data = new NOTIFYICONDATAW
            {
                cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATAW>(),
                hWnd = _hwnd,
                uID = 1,
            };
            Shell_NotifyIcon(NIM_DELETE, ref data);
            _added = false;
        }
        if (_hicon != IntPtr.Zero) { DestroyIcon(_hicon); _hicon = IntPtr.Zero; }
        _source?.Dispose();
        _source = null;
    }

    // ── Win32 ─────────────────────────────────────────────────────────────

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NOTIFYICONDATAW
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szTip;
        public uint dwState;
        public uint dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string szInfo;
        public uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Shell_NotifyIcon(int message, ref NOTIFYICONDATAW data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadImage(IntPtr hInstance, string name, uint type,
        int cx, int cy, uint load);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr hIcon);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT point);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }

    private const uint IMAGE_ICON = 1;
    private const uint LR_LOADFROMFILE = 0x10;
    private const uint LR_DEFAULTSIZE = 0x40;
}
