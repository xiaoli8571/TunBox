using System.IO;
using System.Windows;
using System.Windows.Controls;

namespace TunBox.App;

/// <summary>
/// 子窗口必须比主窗口小：主程序是 470×880 的竖屏，对话框再写死 560 宽就会横着盖住整个主界面
/// （用户点名的「弹出来的框比主页面大」）。所有对话框 Loaded 时都过一遍这里。
/// </summary>
internal static class DialogFit
{
    public static void ToOwner(Window dlg)
    {
        var owner = dlg.Owner ?? Application.Current?.MainWindow;
        if (owner == null || owner.ActualWidth < 200) return;
        dlg.MaxWidth = Math.Max(280, owner.ActualWidth - 24);
        if (dlg.Width > dlg.MaxWidth) dlg.Width = dlg.MaxWidth;
        dlg.MaxHeight = Math.Max(320, owner.ActualHeight - 60);
    }
}

/// <summary>
/// 「＋」导入入口：一个输入框同时吃订阅链接与节点链接，另外支持本地文件
/// （选择或拖拽，Clash Verge 同款三路）。Result 为 null = 取消。
/// </summary>
public partial class ImportDialog : Window
{
    /// <summary>kind = url / file / text。</summary>
    public (string Kind, string Value)? Result { get; private set; }

    private string? _pickedFile;

    public ImportDialog()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            DialogFit.ToOwner(this);
            // Owner 是调用方用对象初始化器赋的，构造函数里还是 null —— 图标只能在这里补
            if (Owner?.Icon != null) Icon = Owner.Icon;
            InputBox.Focus();
            InputBox.CaretIndex = InputBox.Text.Length;
        };
    }

    private void OnPickFile(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog
        {
            Filter = "订阅配置 (yaml|yml|conf|txt)|*.yaml;*.yml;*.conf;*.txt|所有文件|*.*",
        };
        if (dialog.ShowDialog(this) != true) return;
        if (new FileInfo(dialog.FileName).Length > 4_000_000)
        {
            MessageBox.Show(this, "文件超过 4MB，不像订阅配置。", "TunBox", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        _pickedFile = dialog.FileName;
        FileName.Text = Path.GetFileName(dialog.FileName);
    }

    private void OnDropFile(object sender, DragEventArgs e)
    {
        try
        {
            if (e.Data.GetData(DataFormats.FileDrop) is not string[] files || files.Length == 0) return;
            var path = files[0];
            if (!path.EndsWith(".yaml", StringComparison.OrdinalIgnoreCase)
                && !path.EndsWith(".yml", StringComparison.OrdinalIgnoreCase)
                && !path.EndsWith(".conf", StringComparison.OrdinalIgnoreCase)
                && !path.EndsWith(".txt", StringComparison.OrdinalIgnoreCase))
            {
                MessageBox.Show(this, "只支持 .yaml / .yml / .conf / .txt 文件。", "TunBox",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            _pickedFile = path;
            FileName.Text = Path.GetFileName(path);
        }
        catch { /* 拖放失败不算事 */ }
    }

    private void OnImport(object sender, RoutedEventArgs e)
    {
        if (_pickedFile != null) { Result = ("file", _pickedFile); }
        else if (InputBox.Text.Trim().Length > 0)
        {
            var text = InputBox.Text.Trim();
            // 一行 http(s) = 订阅 URL；否则当节点链接文本交给解析器
            var isUrl = text.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
                        || text.StartsWith("https://", StringComparison.OrdinalIgnoreCase);
            Result = (isUrl ? "url" : "text", text);
        }
        else
        {
            MessageBox.Show(this, "先填订阅链接（或节点链接），选一个文件，或把文件拖进来。", "TunBox",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        DialogResult = true;
    }
}
