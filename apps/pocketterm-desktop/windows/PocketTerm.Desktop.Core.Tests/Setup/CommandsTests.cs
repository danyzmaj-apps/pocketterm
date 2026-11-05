using System.ComponentModel;

namespace PocketTerm.Desktop.Tests;

public class CommandsTests
{
    [Fact]
    public async Task APcWithoutWingetGetsAFailedInstallThatSaysSoNotAnException()
    {
        var pc = new Commands((exe, args, env) => throw new Win32Exception(2, "The system cannot find the file specified."), windows: true);
        Assert.Equal("winget", pc.Winget);
        var result = await pc.RunAsync(["winget", "install", "--id", "Tailscale.Tailscale"]);
        Assert.NotEqual(0, result.Code);
        Assert.Contains("winget", result.Output);
    }

    [Fact]
    public async Task AnotherMissingProgramIsAnError()
    {
        var pc = new Commands((exe, args, env) => throw new Win32Exception(2, "gone"), windows: true);
        await Assert.ThrowsAsync<Win32Exception>(() => pc.RunAsync(["wezterm", "--version"]));
    }

    [Fact]
    public async Task TheRealRunnerReportsTheExitCodeAndBothStreams()
    {
        if (OperatingSystem.IsWindows()) return;
        var result = await new Commands().RunAsync(["/bin/sh", "-c", "echo out; echo err >&2; exit 3"]);
        Assert.Equal(3, result.Code);
        Assert.Contains("out", result.Output);
        Assert.Contains("err", result.Output);
    }
}
