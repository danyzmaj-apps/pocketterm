using System.Text.Json.Nodes;
using PocketTerm.Core;

namespace PocketTerm.Desktop.Tests;

public class TailscaleTests
{
    private static readonly HashSet<int> Ours47900 = [47900];

    private static Func<string, bool> Only(params string[] files) => files.Contains;

    [Fact]
    public void FoundInTheMacAppFirstThenOnThePathOrInHomebrewWindowsHasItsOwn()
    {
        var none = new Dictionary<string, string>();
        Assert.Equal(
            Tailscale.MacCli,
            Tailscale.FindCli(new Dictionary<string, string> { ["PATH"] = "/usr/bin" }, none, Only(Tailscale.MacCli, "/usr/bin/tailscale"), windows: false));
        Assert.Equal(
            "/bin/tailscale",
            Tailscale.FindCli(new Dictionary<string, string> { ["PATH"] = "/usr/bin:/bin" }, none, Only("/bin/tailscale"), windows: false));
        Assert.Equal(
            "/opt/homebrew/bin/tailscale",
            Tailscale.FindCli(new Dictionary<string, string> { ["PATH"] = "/usr/bin" }, none, Only("/opt/homebrew/bin/tailscale"), windows: false));
        const string programs = @"C:\Program Files";
        Assert.Equal(
            @"C:\Program Files\Tailscale\tailscale.exe",
            Tailscale.FindCli(
                new Dictionary<string, string> { ["PATH"] = @"C:\Windows", ["ProgramFiles"] = programs },
                none,
                Only(Tailscale.WindowsCli(programs)),
                windows: true));
        // Program Files on another drive.
        Assert.Equal(
            @"D:\Program Files\Tailscale\tailscale.exe",
            Tailscale.FindCli(
                new Dictionary<string, string> { ["PATH"] = @"C:\Windows", ["ProgramFiles"] = @"D:\Program Files" },
                none,
                Only(@"D:\Program Files\Tailscale\tailscale.exe"),
                windows: true));
        // On the PATH on Windows.
        Assert.Equal(
            @"C:\Tools\tailscale.exe",
            Tailscale.FindCli(
                new Dictionary<string, string> { ["PATH"] = @"C:\Windows;C:\Tools\", ["ProgramFiles"] = programs },
                none,
                Only(@"C:\Tools\tailscale.exe"),
                windows: true));
        Assert.Null(Tailscale.FindCli(new Dictionary<string, string> { ["PATH"] = "/usr/bin" }, none, _ => false, windows: false));
        // A smoke run's stand-in, before the real app's, in a build for tool/smoke.
        Assert.Equal(
            "/tmp/fake-tailscale",
            Tailscale.FindCli(
                hooks: new Dictionary<string, string> { ["POCKETTERM_TAILSCALE"] = "/tmp/fake-tailscale" },
                exists: f => f == Tailscale.MacCli,
                windows: false));
    }

    [ReleaseBuildFact]
    public void ABuildNotMadeForSmokeIgnoresPocketTermTailscale()
    {
        Assert.Equal(
            Tailscale.MacCli,
            Tailscale.FindCli(
                new Dictionary<string, string> { ["POCKETTERM_TAILSCALE"] = "/tmp/fake-tailscale" },
                exists: f => f == Tailscale.MacCli,
                windows: false));
    }

    [Fact]
    public async Task NotInstalledItsServiceNotRunningSignedOutRunning()
    {
        var fake = new FakeTailscale();
        Assert.Equal(TailscaleState.Missing, (await fake.Tailscale.StatusAsync()).State);
        Assert.Empty(fake.Calls);

        fake.Installed = true;
        fake.Daemon = false;
        Assert.Equal(TailscaleState.Stopped, (await fake.Tailscale.StatusAsync()).State);

        fake.Daemon = true;
        fake.BackendState = "NeedsLogin";
        Assert.Equal(TailscaleState.LoggedOut, (await fake.Tailscale.StatusAsync()).State);

        fake.BackendState = "Stopped";
        Assert.Equal(TailscaleState.Stopped, (await fake.Tailscale.StatusAsync()).State);

        fake.BackendState = "Running";
        var running = await fake.Tailscale.StatusAsync();
        Assert.Equal(TailscaleState.Running, running.State);
        Assert.Equal("mac.tail1234.ts.net", running.DnsName);
        Assert.Equal("https://mac.tail1234.ts.net", running.Url);
        Assert.True(running.Https);

        fake.Https = false;
        Assert.False((await fake.Tailscale.StatusAsync()).Https);
    }

    [Fact]
    public void StatusOutputWithNoiseBeforeItsJsonStillReads()
    {
        var status = Tailscale.ParseStatus("Warning: client version != tailscaled\n{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"pc.tail1.ts.net.\"},\"CertDomains\":[]}");
        Assert.Equal(new TailscaleStatus(TailscaleState.Running, "pc.tail1.ts.net", false), status);
        Assert.Equal(TailscaleState.Stopped, Tailscale.ParseStatus("not json").State);
        Assert.Equal(TailscaleState.Stopped, Tailscale.ParseStatus("null").State);
        Assert.Equal(TailscaleState.LoggedOut, Tailscale.ParseStatus("{\"BackendState\":\"NeedsMachineAuth\"}").State);
    }

    [Fact]
    public async Task ServeOnATailnetWithHttpsOffAnswersWithThePageThatTurnsItOnWithoutWaitingOnTheCli()
    {
        var fake = new FakeTailscale(installed: true, https: false);
        var result = await fake.Tailscale.ServeAsync(47900).WaitAsync(TimeSpan.FromSeconds(5));
        Assert.False(result.Ok);
        Assert.Equal(FakeTailscale.EnableLink, result.EnableLink);
        Assert.True(Assert.Single(fake.Running).Killed);
    }

    [Fact]
    public async Task ServePublishes127001AtThePortOnHttps443InTheBackground()
    {
        var fake = new FakeTailscale(installed: true);
        Assert.True((await fake.Tailscale.ServeAsync(47901)).Ok);
        Assert.Equal(["serve status --json", "serve --bg --https=443 http://127.0.0.1:47901"], fake.Calls);
        await fake.Tailscale.UnserveAsync(47901);
        Assert.Equal("serve --https=443 off", fake.Calls[^1]);
    }

    [Fact]
    public void WhatElseServePublishesOn443IsToldApartFromTheBuiltInServer()
    {
        string? At(JsonObject config, IReadOnlySet<int>? ours = null) => Tailscale.ServedElsewhere(DartJson.Encode(config), ours ?? Ours47900);
        JsonObject Web(JsonObject handlers) => new()
        {
            ["TCP"] = new JsonObject { ["443"] = new JsonObject { ["HTTPS"] = true } },
            ["Web"] = new JsonObject { ["mac.tail1234.ts.net:443"] = new JsonObject { ["Handlers"] = handlers } },
        };
        JsonObject Proxy(string to) => new() { ["Proxy"] = to };

        Assert.Null(At(new JsonObject()));
        Assert.Null(Tailscale.ServedElsewhere("not json", Ours47900));
        // This app's, from this run or the one before, whose port moved.
        Assert.Null(At(Web(new JsonObject { ["/"] = Proxy("http://127.0.0.1:47900") })));
        Assert.Null(At(Web(new JsonObject { ["/"] = Proxy("http://127.0.0.1:47900") }), new HashSet<int> { 47901, 47900 }));
        // Another PocketTerm's (another user, another copy), though on a port of the same range.
        Assert.Equal("http://127.0.0.1:47900", At(Web(new JsonObject { ["/"] = Proxy("http://127.0.0.1:47900") }), new HashSet<int> { 47901 }));
        Assert.Equal("http://127.0.0.1:47900", At(Web(new JsonObject { ["/"] = Proxy("http://127.0.0.1:47900") }), new HashSet<int>()));
        Assert.Equal("http://127.0.0.1:3000", At(Web(new JsonObject { ["/"] = Proxy("http://127.0.0.1:3000") })));
        Assert.Equal(
            "http://127.0.0.1:3000 at /grafana",
            At(Web(new JsonObject { ["/"] = Proxy("http://127.0.0.1:47900"), ["/grafana"] = Proxy("http://127.0.0.1:3000") })));
        Assert.Equal(
            "a TCP forward to 127.0.0.1:22",
            At(new JsonObject { ["TCP"] = new JsonObject { ["443"] = new JsonObject { ["TCPForward"] = "127.0.0.1:22" } } }));
        // Another port of the tailnet name is no business of this one.
        Assert.Null(At(new JsonObject
        {
            ["Web"] = new JsonObject
            {
                ["mac.tail1234.ts.net:8443"] = new JsonObject { ["Handlers"] = new JsonObject { ["/"] = Proxy("http://127.0.0.1:3000") } },
            },
        }));
        // A `tailscale serve` running in a terminal (not --bg).
        Assert.Equal(
            "/Users/me/site",
            At(new JsonObject { ["Foreground"] = new JsonObject { ["session1"] = Web(new JsonObject { ["/"] = new JsonObject { ["Path"] = "/Users/me/site" } }) } }));
    }

    [Fact]
    public async Task ServeLeavesWhatElseServePublishesOn443AloneAndSoDoesUnserve()
    {
        var fake = new FakeTailscale(installed: true);
        fake.Serving("http://127.0.0.1:3000");
        var result = await fake.Tailscale.ServeAsync(47900);
        Assert.False(result.Ok);
        Assert.Equal("http://127.0.0.1:3000", result.Taken);
        Assert.DoesNotContain(fake.Calls, c => c.StartsWith("serve --", StringComparison.Ordinal));

        await fake.Tailscale.UnserveAsync(47900);
        Assert.DoesNotContain("serve --https=443 off", fake.Calls);
    }

    [Fact]
    public async Task WhileServeStatusCantSayWhatsOn443ServeAndUnserveChangeNothing()
    {
        var fake = new FakeTailscale(installed: true);
        fake.Serving("http://127.0.0.1:3000");
        fake.StatusFails = true;
        Assert.IsType<ServingUnknown>(await fake.Tailscale.Port443Async(Ours47900));
        var result = await fake.Tailscale.ServeAsync(47900);
        Assert.False(result.Ok);
        Assert.Equal(Tailscale.Unreadable, result.Error);
        await fake.Tailscale.UnserveAsync(47900);
        Assert.DoesNotContain(fake.Calls, c => c.StartsWith("serve --", StringComparison.Ordinal));
        Assert.Contains("http://127.0.0.1:3000", DartJson.Encode(fake.ServeConfig));

        // Readable again: nothing there, this app's own, or something else.
        fake.StatusFails = false;
        fake.ServeConfig = new JsonObject();
        Assert.IsType<ServingNothing>(await fake.Tailscale.Port443Async(Ours47900));
        fake.Serving("http://127.0.0.1:47900");
        Assert.IsType<ServingOurs>(await fake.Tailscale.Port443Async(Ours47900));
        Assert.IsType<ServingElsewhere>(await fake.Tailscale.Port443Async(new HashSet<int> { 47901 }));
        Assert.IsType<ServingUnknown>(Tailscale.ReadServing("not json", Ours47900));
    }

    [Fact]
    public void TheOpenSourceBuildsOperatorRuleSaysHowToLetPocketTermIn()
    {
        Assert.Contains("--operator", Tailscale.ServeError("Access denied: serve config denied\nUse sudo or set operator\n"));
        Assert.Equal("something broke", Tailscale.ServeError("first\nsomething broke\n\n"));
        Assert.Equal("tailscale serve failed.", Tailscale.ServeError("  \n"));
    }

    [Fact]
    public async Task EnableHttpsLinkTakesBackAServeThatWentThroughAndFallsBackToTheAdminConsole()
    {
        var on = new FakeTailscale(installed: true);
        Assert.Equal(Tailscale.AdminDns, await on.Tailscale.EnableHttpsLinkAsync(47900));
        Assert.Equal("serve --https=443 off", on.Calls[^1]);
        Assert.Empty(on.ServeConfig);

        var off = new FakeTailscale(installed: true, https: false);
        Assert.Equal(FakeTailscale.EnableLink, await off.Tailscale.EnableHttpsLinkAsync(47900));
    }

    [Fact]
    public async Task OpenTailscaleShowsItsApp()
    {
        var fake = new FakeTailscale(installed: true);
        await fake.Tailscale.OpenAsync();
        Assert.Equal("-a Tailscale", fake.Calls[^1]);
    }
}

/// <summary>Runs only in a build without test hooks (as released): a test build reads them on purpose.</summary>
file sealed class ReleaseBuildFactAttribute : FactAttribute
{
    public ReleaseBuildFactAttribute()
    {
        if (TestHooks.TestBuild) Skip = "A test build reads POCKETTERM_TAILSCALE on purpose.";
    }
}
