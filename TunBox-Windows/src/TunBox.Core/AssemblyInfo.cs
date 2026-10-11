using System.Runtime.CompilerServices;

// 解析器、拉取器、分流库的替身注入与契约测试都要能摸到 internal 成员：
// 「半截下载绝不能落盘」「UA 链逐个试」这类行为只有真测才拦得住回归。
[assembly: InternalsVisibleTo("TunBox.Core.Tests")]
