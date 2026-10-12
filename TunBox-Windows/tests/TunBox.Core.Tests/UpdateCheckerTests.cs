using TunBox.Core.Services;
using Xunit;

namespace TunBox.Core.Tests;

/// <summary>
/// 检查更新的纯逻辑：tag 解析（只认 windows-v 前缀，鸿蒙端 Release 不能混进来）与
/// 版本比较（严格大于才算新）。网络部分不在单测里碰。
/// </summary>
public class UpdateCheckerTests
{
    [Theory]
    [InlineData("windows-v0.3.1", "0.3.1")]
    [InlineData("windows-v1.2.3", "1.2.3")]
    [InlineData("v0.2.0", null)]              // 鸿蒙端的 tag：跳过
    [InlineData("windows-v0.3.1-beta", null)] // 非三段版本：跳过
    [InlineData("", null)]
    [InlineData(null, null)]
    public void Windows_tags_parse_only_from_the_windows_line(string? tag, string? expected)
        => Assert.Equal(expected, UpdateChecker.ParseWindowsTag(tag));

    [Theory]
    [InlineData("0.3.0", "0.3.1", true)]
    [InlineData("0.3.1", "0.3.1", false)]
    [InlineData("0.4.0", "0.3.9", false)]
    [InlineData("0.3.0", "1.0.0", true)]
    [InlineData("", "0.3.1", true)]           // 读不出当前版本：宁可提示
    public void Newer_only_when_candidate_is_strictly_greater(string current, string candidate, bool expected)
        => Assert.Equal(expected, UpdateChecker.IsNewer(current, candidate));
}
