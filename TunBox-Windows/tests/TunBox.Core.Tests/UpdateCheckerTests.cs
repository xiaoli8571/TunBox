using TunBox.Core.Services;
using Xunit;

namespace TunBox.Core.Tests;

/// <summary>
/// 检查更新的纯逻辑：tag 解析（认 windows-v 历史前缀与两端统一的 v 前缀）、
/// 多 tag 里挑最大版本、版本比较（严格大于才算新）。网络部分不在单测里碰。
/// </summary>
public class UpdateCheckerTests
{
    [Theory]
    [InlineData("windows-v0.3.1", "0.3.1")]   // 旧 Windows 线的 tag
    [InlineData("v0.3.1", "0.3.1")]           // 两端合体的统一 tag
    [InlineData("v0.2.0", "0.2.0")]           // 历史鸿蒙端 tag：合体后也算可识别版本
    [InlineData("windows-v1.2.3", "1.2.3")]
    [InlineData("windows-v0.3.1-beta", null)] // 非三段版本：跳过
    [InlineData("release-1", null)]
    [InlineData("", null)]
    [InlineData(null, null)]
    public void Release_tags_parse_from_both_lines(string? tag, string? expected)
        => Assert.Equal(expected, UpdateChecker.ParseReleaseTag(tag));

    [Fact]
    public void Pick_latest_prefers_the_highest_version_across_lines()
    {
        var best = UpdateChecker.PickLatest(new[] { "windows-v0.3.0", "v0.3.1", "v0.2.0" });
        Assert.Equal(("v0.3.1", "0.3.1"), best);
    }

    [Fact]
    public void Pick_latest_returns_null_when_nothing_matches()
    {
        Assert.Null(UpdateChecker.PickLatest(new[] { "windows-v0.3.1-beta", "data-v1", "", null }));
        Assert.Null(UpdateChecker.PickLatest(System.Linq.Enumerable.Empty<string?>()));
    }

    [Theory]
    [InlineData("0.3.0", "0.3.1", true)]
    [InlineData("0.3.1", "0.3.1", false)]
    [InlineData("0.4.0", "0.3.9", false)]
    [InlineData("0.3.0", "1.0.0", true)]
    [InlineData("", "0.3.1", true)]           // 读不出当前版本：宁可提示
    public void Newer_only_when_candidate_is_strictly_greater(string current, string candidate, bool expected)
        => Assert.Equal(expected, UpdateChecker.IsNewer(current, candidate));
}
