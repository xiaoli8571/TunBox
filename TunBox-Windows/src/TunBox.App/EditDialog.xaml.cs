using System.Windows;
using System.Windows.Controls;

namespace TunBox.App;

/// <summary>编辑订阅：改名 / 改订阅链接。纯代码构建。Values 为 null = 取消。</summary>
public sealed class EditDialog : Window
{
    private readonly TextBox _name = new();
    private readonly TextBox _url = new();

    public (string Name, string Url) Values => (_name.Text.Trim(), _url.Text.Trim());

    public EditDialog(string name, string url)
    {
        // 样式合并进窗口自己：对话框不能指望 App 级资源（裸 Application 宿主里取不到）
        Resources.MergedDictionaries.Add(new ResourceDictionary
        {
            Source = new System.Uri("/TunBox;component/Assets/Styles.xaml", System.UriKind.Relative),
        });
        Title = "编辑订阅";
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Width = 430;
        SizeToContent = SizeToContent.Height;
        Background = TryFindResource("PageBg") as System.Windows.Media.Brush ?? System.Windows.Media.Brushes.White;
        FontFamily = new System.Windows.Media.FontFamily("Segoe UI, Microsoft YaHei UI");
        FontSize = 13;

        var panel = new StackPanel { Margin = new Thickness(20, 16, 20, 16) };
        panel.Children.Add(new TextBlock
        {
            Text = "编辑订阅",
            FontSize = 16,
            FontWeight = FontWeights.Bold,
            Foreground = TryFindResource("TextMain") as System.Windows.Media.Brush ?? System.Windows.Media.Brushes.Black,
        });

        panel.Children.Add(new TextBlock
        {
            Text = "订阅名称",
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 14, 0, 6),
            Foreground = TryFindResource("TextMain") as System.Windows.Media.Brush ?? System.Windows.Media.Brushes.Black,
        });
        _name.Text = name;
        panel.Children.Add(_name);

        panel.Children.Add(new TextBlock
        {
            Text = "订阅链接（本地导入的订阅没有链接，留空即可）",
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 12, 0, 6),
            Foreground = TryFindResource("TextMain") as System.Windows.Media.Brush ?? System.Windows.Media.Brushes.Black,
        });
        _url.Text = url;
        panel.Children.Add(_url);

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 16, 0, 0),
        };
        var ok = new Button { Content = "保存", Width = 92, IsDefault = true };
        ok.Click += (_, _) => DialogResult = true;
        var cancel = new Button
        {
            Content = "取消",
            Width = 80,
            Style = TryFindResource("QuietButton") as Style,
            IsCancel = true,
        };
        buttons.Children.Add(ok);
        buttons.Children.Add(cancel);
        panel.Children.Add(buttons);
        Content = panel;

        Loaded += (_, _) => { DialogFit.ToOwner(this); _name.Focus(); _name.SelectAll(); };
    }
}
