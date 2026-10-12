using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;

namespace TunBox.App;

/// <summary>连接按钮文案：随连接状态在「连接 / 断开」间切换。</summary>
public sealed class ConnectLabelConverter : IValueConverter
{
    public static readonly ConnectLabelConverter Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => value is bool b && b ? "断开连接" : "连接";

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

/// <summary>模式分段按钮底色：parameter 是这一档代表的模式，与当前 mode 相等即选中。
/// macOS 分段控件：选中段 = 白色浮起片，未选中 = 透明（凹槽色由 SegTrack 提供）。</summary>
public sealed class ModeChipConverter : IValueConverter
{
    public static readonly ModeChipConverter Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var selected = string.Equals(value as string, parameter as string, StringComparison.Ordinal);
        var brush = Application.Current?.TryFindResource(selected ? "CardBg" : "SegTrack") as Brush
                    ?? (selected ? Brushes.White : Brushes.Transparent);
        return brush;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

/// <summary>模式分段按钮文字：选中的那档用主文本色（白底黑字），未选中的用次级灰。</summary>
public sealed class ModeChipTextConverter : IValueConverter
{
    public static readonly ModeChipTextConverter Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var selected = string.Equals(value as string, parameter as string, StringComparison.Ordinal);
        var brush = Application.Current?.TryFindResource(selected ? "TextMain" : "TextMuted") as Brush
                    ?? (selected ? Brushes.Black : Brushes.Gray);
        return brush;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}

/// <summary>有内容才占位。</summary>
public sealed class NonEmptyToVisibilityConverter : IValueConverter
{
    public static readonly NonEmptyToVisibilityConverter Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
        => string.IsNullOrWhiteSpace(value as string) ? Visibility.Collapsed : Visibility.Visible;

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
        => throw new NotSupportedException();
}
