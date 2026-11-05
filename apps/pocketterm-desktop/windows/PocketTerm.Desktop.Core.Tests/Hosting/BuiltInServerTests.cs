using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using PocketTerm.Core;
using PocketTerm.Core.Tests;

namespace PocketTerm.Desktop.Tests;

/// <summary>
/// The built-in server as the app runs it: the real sidecar (<c>pocketterm-server</c>, the Dart server compiled
/// by tool/server-sidecar.sh) behind a fake Tailscale CLI.
/// </summary>
public sealed class BuiltInServerTests : IAsyncLifetime
{
    private readonly string _dir = Directory.CreateTempSubdirectory("pocketterm-host").FullName;
    private readonly List<BuiltInServer> _servers = [];

    public Task InitializeAsync() => Task.CompletedTask;

    public async Task DisposeAsync()
    {
        foreach (var s in _servers)
        {
            await s.StopAsync();
            s.Dispose();
        }
        try
        {
            Directory.Delete(_dir, recursive: true);
        }
        catch (IOException)
        {
        }
    }

    private BuiltInServer Server(FakeTailscale fake, TimeSpan? recheckReady = null, string? dir = null)
    {
        var server = new BuiltInServer(dir ?? _dir, fake.Tailscale, recheck: TimeSpan.Zero, recheckReady: recheckReady ?? TimeSpan.Zero, executable: Sidecar.Binary);
        _servers.Add(server);
        return server;
    }

    private async Task<BuiltInServer> Host(FakeTailscale fake)
    {
        var server = Server(fake);
        await server.StartAsync(port: 0);
        await server.RefreshAsync();
        return server;
    }

    /// <summary>Whether anything answers on 127.0.0.1:<paramref name="port"/>.</summary>
    private static async Task<bool> Listening(int port)
    {
        try
        {
            using var c = new TcpClient();
            await c.ConnectAsync(IPAddress.Loopback, port);
            return true;
        }
        catch (SocketException)
        {
            return false;
        }
    }

    private static bool Gone(int pid)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            return p.HasExited;
        }
        catch (ArgumentException)
        {
            return true;
        }
    }

    private static int Count(FakeTailscale fake, string prefix) => fake.Calls.Count(c => c.StartsWith(prefix, StringComparison.Ordinal));

    [SidecarFact]
    public async Task WithoutTailscaleItStillRunsOn127001WithNothingToHandOut()
    {
        var server = await Host(new FakeTailscale());
        Assert.Equal(HostState.NoTailscale, server.State);
        Assert.Null(await new Backend(server.Backend.Url).Check());
        Assert.Null(server.PublicUrl);
        Assert.Null(await server.SetupLinkAsync());
        Assert.Equal([HostAction.InstallTailscale], server.Status.Actions);
    }

    [SidecarFact]
    public async Task ItsOwnSetupLinkSignsThisComputerInOn127001()
    {
        var server = await Host(new FakeTailscale());
        var link = await server.OwnSetupLinkAsync();
        Assert.Equal(server.Backend, Backend.FromLink(link));
        var client = new PocketTermServerClient(server.Backend, new MemoryDeviceTokens());
        var account = await client.RedeemSetup(Backend.SetupToken(DartUri.Parse(link))!, "PC", "windows");
        Assert.Equal(DeviceRole.Desktop, account.Device.Role);
    }

    [SidecarFact]
    public async Task SignedOutOfTailscaleItSaysSoAndServesNothing()
    {
        var fake = new FakeTailscale(installed: true, backendState: "NeedsLogin");
        var server = await Host(fake);
        Assert.Equal(HostState.LoggedOut, server.State);
        Assert.Equal(0, Count(fake, "serve"));
    }

    [SidecarFact]
    public async Task HttpsOffThePageThatTurnsItOnOnceOnTailscaleServesItAtItsTsNetName()
    {
        var fake = new FakeTailscale(installed: true, https: false);
        var server = await Host(fake);
        Assert.Equal(HostState.HttpsOff, server.State);
        Assert.Equal(FakeTailscale.EnableLink, server.EnableHttps);
        Assert.Equal(FakeTailscale.EnableLink, server.HttpsPage);
        Assert.Null(server.PublicUrl);

        fake.Https = true;
        await server.RefreshAsync();
        Assert.Equal(HostState.Ready, server.State);
        Assert.Equal("https://mac.tail1234.ts.net", server.PublicUrl);
        Assert.Equal($"serve --bg --https=443 http://127.0.0.1:{server.Port}", fake.Calls[^1]);
        Assert.Equal("Tailscale serves it to your own devices at https://mac.tail1234.ts.net", server.Status.Text);

        // Looking again doesn't serve again.
        var served = Count(fake, "serve --bg");
        await server.RefreshAsync();
        Assert.Equal(served, Count(fake, "serve --bg"));
    }

    [SidecarFact]
    public async Task StoppingTakesItOffTheTailnetClosesThePortAndLeavesNoProcess()
    {
        var fake = new FakeTailscale(installed: true);
        var server = await Host(fake);
        var port = server.Port;
        var pid = server.ProcessId!.Value;
        Assert.Equal(HostState.Ready, server.State);
        await server.StopAsync();
        Assert.Equal("serve --https=443 off", fake.Calls[^1]);
        Assert.False(server.Running);
        Assert.False(await Listening(port));
        Assert.True(Gone(pid));
    }

    [SidecarFact]
    public async Task DisposingWithoutAStopLeavesNoProcess()
    {
        var server = Server(new FakeTailscale());
        await server.StartAsync(port: 0);
        var port = server.Port;
        var pid = server.ProcessId!.Value;
        server.Dispose();
        Assert.True(Gone(pid));
        Assert.False(await Listening(port));
    }

    [SidecarFact]
    public async Task StoppingWhileTailscaleIsStillServingItTakesBackWhatThatServePublishes()
    {
        var fake = new FakeTailscale(installed: true) { ServeGate = new TaskCompletionSource() };
        var server = Server(fake, recheckReady: TimeSpan.FromMinutes(1));
        await server.StartAsync(port: 0);
        var port = server.Port;
        await Wait.Until(() => fake.Calls.Contains($"serve --bg --https=443 http://127.0.0.1:{port}"), 10);
        var stopped = server.StopAsync();
        fake.ServeGate.SetResult();
        await stopped;
        Assert.Equal("serve --https=443 off", fake.Calls[^1]);
        Assert.Empty(fake.ServeConfig);
        Assert.Equal(HostState.Checking, server.State);
        Assert.False(await Listening(port));
    }

    [SidecarFact]
    public async Task ItsOwnServeEntryGoneWhileReadyItsPublishedAgain()
    {
        var fake = new FakeTailscale(installed: true);
        var server = await Host(fake);
        Assert.Equal(HostState.Ready, server.State);

        // serve status can't say for a moment: nothing changes.
        fake.StatusFails = true;
        var serves = Count(fake, "serve --bg");
        await server.RefreshAsync();
        Assert.Equal(HostState.Ready, server.State);
        Assert.Equal(serves, Count(fake, "serve --bg"));

        fake.StatusFails = false;
        fake.ServeConfig = new();
        await server.RefreshAsync();
        Assert.Equal($"serve --bg --https=443 http://127.0.0.1:{server.Port}", fake.Calls[^1]);
        Assert.Contains($"http://127.0.0.1:{server.Port}", DartJson.Encode(fake.ServeConfig));
        Assert.Equal(HostState.Ready, server.State);
    }

    [SidecarFact]
    public async Task ATakenPortMovesItToTheNextOne()
    {
        var taken = new TcpListener(IPAddress.Loopback, 0);
        taken.Start();
        try
        {
            var port = ((IPEndPoint)taken.LocalEndpoint).Port;
            var server = Server(new FakeTailscale());
            await server.StartAsync(port: port);
            Assert.True(server.Port > port);
            Assert.Null(await server.Backend.Check());
        }
        finally
        {
            taken.Stop();
        }
    }

    [SidecarFact]
    public async Task ASecondServerOnTheSameDataSaysWhyItDidntStart()
    {
        await Server(new FakeTailscale()).StartAsync(port: 0);
        var second = Server(new FakeTailscale());
        var e = await Assert.ThrowsAsync<BuiltInServerException>(() => second.StartAsync(port: 0));
        Assert.Contains("didn’t start", e.Message);
        Assert.False(second.Running);
    }

    [SidecarFact]
    public async Task SomethingElseOn443StaysTheServerSaysSoAndServesNothingUntilItGoes()
    {
        var fake = new FakeTailscale(installed: true);
        fake.Serving("http://127.0.0.1:3000");
        var server = await Host(fake);
        Assert.Equal(HostState.Taken, server.State);
        Assert.Contains("http://127.0.0.1:3000", server.Error);
        Assert.Null(server.PublicUrl);
        Assert.Null(await server.SetupLinkAsync());

        fake.ServeConfig = new();
        await server.RefreshAsync();
        Assert.Equal(HostState.Ready, server.State);
    }

    [SidecarFact]
    public async Task SomethingElseTaking443LaterShowsAndStoppingLeavesItThere()
    {
        var fake = new FakeTailscale(installed: true);
        var server = await Host(fake);
        Assert.Equal(HostState.Ready, server.State);

        fake.Serving("http://127.0.0.1:8080");
        await server.RefreshAsync();
        Assert.Equal(HostState.Taken, server.State);
        Assert.Null(server.PublicUrl);
        await server.StopAsync();
        Assert.NotEmpty(fake.ServeConfig);
    }

    [SidecarFact]
    public async Task AnotherPocketTermsEntryIsTakenOnAFirstStartAndStays()
    {
        var fake = new FakeTailscale(installed: true);
        fake.Serving("http://127.0.0.1:47900");
        var server = await Host(fake);
        Assert.Equal(HostState.Taken, server.State);
        Assert.Contains("http://127.0.0.1:47900", server.Error);
        Assert.Equal(0, Count(fake, "serve --"));
        await server.StopAsync();
        Assert.DoesNotContain("serve --https=443 off", fake.Calls);
        Assert.Contains("http://127.0.0.1:47900", DartJson.Encode(fake.ServeConfig));
    }

    [SidecarFact]
    public async Task ItsOwnEntryFromLastTimeMovesToThePortItHasNow()
    {
        var fake = new FakeTailscale(installed: true);
        fake.Serving("http://127.0.0.1:47950");
        var server = Server(fake);
        await server.StartAsync(port: 0, earlier: 47950);
        // The start's own look may be done already: this one then only finds the entry it moved.
        await server.RefreshAsync();
        Assert.Equal(HostState.Ready, server.State);
        Assert.Contains($"serve --bg --https=443 http://127.0.0.1:{server.Port}", fake.Calls);
        Assert.Contains($"http://127.0.0.1:{server.Port}", DartJson.Encode(fake.ServeConfig));
    }

    [SidecarFact]
    public async Task TailscaleStoppingLaterTakesItOffBackOnItServesAgain()
    {
        var fake = new FakeTailscale(installed: true);
        var server = await Host(fake);
        Assert.Equal(HostState.Ready, server.State);
        fake.BackendState = "Stopped";
        await server.RefreshAsync();
        Assert.Equal(HostState.TailscaleOff, server.State);
        Assert.Null(server.PublicUrl);
        Assert.Equal([HostAction.OpenTailscale, HostAction.CheckAgain], server.Status.Actions);
        fake.BackendState = "Running";
        await server.RefreshAsync();
        Assert.Equal(HostState.Ready, server.State);
    }

    [SidecarFact]
    public async Task ANewTailscaleNameMovesItThereAndIsRememberedAlsoAfterARestartUntilSeen()
    {
        var fake = new FakeTailscale(installed: true);
        var server = await Host(fake);
        Assert.Null(server.RenamedFrom);

        fake.DnsName = "studio.tail1234.ts.net";
        await server.RefreshAsync();
        Assert.Equal("https://studio.tail1234.ts.net", server.PublicUrl);
        Assert.Equal("https://studio.tail1234.ts.net", Backend.FromLink((await server.SetupLinkAsync())!)!.Url);
        Assert.Equal("https://mac.tail1234.ts.net", server.RenamedFrom);
        Assert.Contains("changed from mac.tail1234.ts.net", server.Status.Renamed);

        // Renamed again: the phones still have the first one.
        fake.DnsName = "office.tail1234.ts.net";
        await server.RefreshAsync();
        Assert.Equal("https://mac.tail1234.ts.net", server.RenamedFrom);

        await server.StopAsync();
        var again = await Host(fake);
        Assert.Equal("https://mac.tail1234.ts.net", again.RenamedFrom);

        // Back at the first name: the phones' address works again.
        fake.DnsName = "mac.tail1234.ts.net";
        await again.RefreshAsync();
        Assert.Null(again.RenamedFrom);

        fake.DnsName = "studio.tail1234.ts.net";
        await again.RefreshAsync();
        Assert.NotNull(again.RenamedFrom);
        again.RenameSeen();
        Assert.Null(again.RenamedFrom);
        Assert.Null(again.Status.Renamed);
    }
}

/// <summary>
/// The sidecar binary: <c>POCKETTERM_SERVER_BIN</c>, or with <c>POCKETTERM_INTEROP=1</c> one built once per run
/// with tool/server-sidecar.sh.
/// </summary>
internal static class Sidecar
{
    private static readonly Lazy<string?> Built = new(Build);

    public static bool Available =>
        Environment.GetEnvironmentVariable("POCKETTERM_SERVER_BIN") is { Length: > 0 } ||
        Environment.GetEnvironmentVariable("POCKETTERM_INTEROP") == "1";

    public static string Binary =>
        Environment.GetEnvironmentVariable("POCKETTERM_SERVER_BIN") is { Length: > 0 } given
            ? given
            : Built.Value ?? throw new InvalidOperationException("tool/server-sidecar.sh built nothing.");

    private static string RepoRoot([CallerFilePath] string here = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, "..", "..", "..", "..", ".."));

    private static string? Build()
    {
        var root = RepoRoot();
        var outDir = Path.Combine(Path.GetTempPath(), $"pocketterm-sidecar-tests-{Environment.ProcessId}");
        var psi = new ProcessStartInfo("bash") { WorkingDirectory = root, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var a in new[] { "tool/server-sidecar.sh", "--out", outDir }) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        var output = p.StandardOutput.ReadToEndAsync();
        var errors = p.StandardError.ReadToEnd();
        p.WaitForExit();
        if (p.ExitCode != 0) throw new InvalidOperationException($"tool/server-sidecar.sh failed:\n{output.Result}{errors}");
        var name = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "pocketterm-server.exe" : "pocketterm-server";
        return Directory.GetFiles(outDir, name, SearchOption.AllDirectories).FirstOrDefault();
    }
}

/// <summary>A test that runs the real sidecar: needs <c>POCKETTERM_SERVER_BIN</c> or <c>POCKETTERM_INTEROP=1</c>.</summary>
public sealed class SidecarFactAttribute : FactAttribute
{
    public SidecarFactAttribute()
    {
        if (!Sidecar.Available) Skip = "Set POCKETTERM_SERVER_BIN (tool/server-sidecar.sh builds it) or POCKETTERM_INTEROP=1.";
    }
}
