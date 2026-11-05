using System.Net;
using PocketTerm.Core;

namespace PocketTerm.Desktop.Tests;

public sealed class TerminalFixesTests
{
    private static readonly TermStatus WezMissing =
        new("wezterm", "WezTerm", TermState.Missing, "Needed for your phone to reach this PC's terminals", TermFix.Install);

    [Fact]
    public void TerminalsNeedingSetupAreThoseNeedingSetupAndWezTermToInstall()
    {
        TermStatus[] all =
        [
            WezMissing,
            new("kitty", "kitty", TermState.Setup, Fix: TermFix.KittyConfig),
            new("ghostty", "Ghostty", TermState.Missing),
            new("iterm", "iTerm2", TermState.Ready),
            new("tmux", "tmux", TermState.Idle),
        ];
        Assert.Equal(["wezterm", "kitty"], TerminalFixes.TerminalsNeedingSetup(all).Select(s => s.Id));
    }

    [Fact]
    public void NoTerminalAppWhenOnlyTmuxOrNothingIsInstalledWhileWezTermToInstallCounts()
    {
        Assert.True(TerminalFixes.NoTerminalApp([]));
        Assert.True(TerminalFixes.NoTerminalApp([new("tmux", "tmux", TermState.Ready), new("kitty", "kitty", TermState.Missing)]));
        Assert.False(TerminalFixes.NoTerminalApp([WezMissing]));
        Assert.False(TerminalFixes.NoTerminalApp([new("wezterm", "WezTerm", TermState.Idle)]));
    }

    [Fact]
    public async Task WezTermsFixIsItsInstallAndTheMacsFixesAreNotHere()
    {
        var dir = Directory.CreateTempSubdirectory("pocketterm-fix").FullName;
        try
        {
            using var setup = new WezTermSetup(
                () => false,
                new HttpClient(new SetupFakeHandler(() => new HttpResponseMessage(HttpStatusCode.BadGateway))),
                dir);
            Assert.Equal(("", false), await TerminalFixes.FixTerminalAsync(WezMissing, setup));
            // The click started the download, which GitHub refused.
            Assert.Equal("WezTerm didn't download: HttpException: GitHub answered 502", setup.Error);

            Assert.Equal(("", false), await TerminalFixes.FixTerminalAsync(new("wezterm", "WezTerm", TermState.Ready), setup));
            await Assert.ThrowsAsync<PlatformNotSupportedException>(() =>
                TerminalFixes.FixTerminalAsync(new("kitty", "kitty", TermState.Setup, Fix: TermFix.KittyConfig), setup));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
