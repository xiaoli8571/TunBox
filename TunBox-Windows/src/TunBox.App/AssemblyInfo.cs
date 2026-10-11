using System.Runtime.CompilerServices;
using System.Windows;

// 视图模型里「读回设置 / 看生成出来的配置」几个口子只给单测用：
// XAML 绑定写错名字是静默失败，编译过不了说明不了问题。
[assembly: InternalsVisibleTo("TunBox.Core.Tests")]

[assembly: ThemeInfo(
    ResourceDictionaryLocation.None,
    ResourceDictionaryLocation.SourceAssembly
)]
