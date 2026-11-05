using System.Net;
using System.Net.Sockets;
using PocketTerm.Core;
using PocketTerm.Desktop;

namespace PocketTerm.Desktop.Tests;

/// <summary>hosting_test.dart's "This computer": the controller with the real built-in server (the sidecar).</summary>
public sealed class ThisComputerTests : IAsyncLifetime
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"pocketterm-host-{Guid.NewGuid():N}");
    private readonly FakeTailscale _fake = new(installed: true);
    private readonly List<TestApp> _apps = [];

    public Task InitializeAsync()
    {
        Directory.CreateDirectory(_dir);
        return Task.CompletedTask;
    }

    public async Task DisposeAsync()
    {
        foreach (var a in _apps)
        {
            if (a.Hosting is { } h) await h.StopAsync();
            a.Dispose();
        }
        Directory.Delete(_dir, recursive: true);
    }

    private TestApp App(IReadOnlyDictionary<string, object>? prefs = null, ISecureStore? secrets = null, MemoryPreferenceStore? store = null)
    {
        var a = TestApp.Create(prefs, real: true, tailscale: _fake.Tailscale, serverDir: _dir, serverExecutable: Sidecar.Binary,
            secrets: secrets, store: store);
        _apps.Add(a);
        return a;
    }

    private static async Task<bool> Listening(int port)
    {
        using var c = new TcpClient();
        try
        {
            await c.ConnectAsync(IPAddress.Loopback, port);
            return true;
        }
        catch (SocketException)
        {
            return false;
        }
    }

    [SidecarFact]
    public async Task StartingTheServerSignsThisComputerInToItOn127001()
    {
        var a = App();
        await a.StartHostingAsync();
        Assert.NotNull(a.User);
        Assert.Equal(DeviceRole.Desktop, a.User!.Device.Role);
        Assert.True(a.HostsServer);
        Assert.Equal(a.Hosting!.Backend, a.Backend);
        Assert.Equal("127.0.0.1", DartUri.Parse(a.Backend!.Url).Host);
    }

    [SidecarFact]
    public async Task AStartWhoseSignInTheSecretsStoreRefusesTakesItAllBackAlsoForTheNextLaunch()
    {
        var secrets = new LockableSecrets { Locked = true };
        var a = App(secrets: secrets);
        await a.StartHostingAsync();
        Assert.Null(a.User);
        Assert.Equal(Session.KeychainProblem, a.AuthError);
        Assert.Null(a.Hosting);
        Assert.False(a.HostsServer);
        Assert.Null(a.Backend);
        Assert.False(a.Prefs.GetBool("hosting") ?? false);
        var port = (int)a.Prefs.GetInt("hosting_port")!.Value;
        Assert.False(await Listening(port));

        // Launched again, it waits for a choice: no server of its own starts.
        var again = App(secrets: secrets, store: a.Prefs);
        await again.Start();
        Assert.Null(again.Hosting);
        Assert.Null(again.Backend);

        // Unlocked, Start works.
        secrets.Locked = false;
        await again.StartHostingAsync();
        Assert.NotNull(again.User);
        Assert.True(again.Prefs.GetBool("hosting"));
    }

    [SidecarFact]
    public async Task APhonesCodeCarriesTheTsNetAddressAndItsCodeSignsAPhoneIn()
    {
        var a = App();
        await a.StartHostingAsync();
        await a.Hosting!.RefreshAsync();
        var link = DartUri.Parse(await a.PairingLink());
        Assert.Equal("https://mac.tail1234.ts.net", Backend.FromLink(link)!.Url);
        Assert.Equal(a.DesktopId(a.User!.Id), Backend.ComputerKey(link)!.Desktop);
        // The phone reaches it through Tailscale; here, on 127.0.0.1.
        var phone = new PocketTermServerClient(a.Backend!, new MemoryDeviceTokens());
        var account = await phone.RedeemCode(Backend.PairingCode(link)!, "iPhone", "ios");
        Assert.Equal(a.User!.Id, account.Id);
        Assert.Equal([DeviceRole.Desktop, DeviceRole.Phone], (await a.ServerDevicesAsync()).Select(d => d.Role).Order());
        phone.Close();
    }

    [SidecarFact]
    public async Task UntilTailscaleServesItTheresNoPhoneCodeToShow()
    {
        _fake.Https = false;
        var a = App();
        await a.StartHostingAsync();
        await a.Hosting!.RefreshAsync();
        Assert.Equal(HostState.HttpsOff, a.Hosting!.State);
        await Assert.ThrowsAsync<PairingException>(a.PairingLink);
    }

    [SidecarFact]
    public async Task AddAComputerItsLinkSignsAnotherComputerInToThisServer()
    {
        var a = App();
        await a.StartHostingAsync();
        await a.Hosting!.RefreshAsync();
        var link = DartUri.Parse((await a.ComputerSetupLinkAsync())!);
        Assert.Equal("https://mac.tail1234.ts.net", Backend.FromLink(link)!.Url);
        var other = new PocketTermServerClient(a.Backend!, new MemoryDeviceTokens());
        var account = await other.RedeemSetup(Backend.SetupToken(link)!, "Mac mini", "macos");
        Assert.Equal(a.User!.Id, account.Id);
        Assert.Equal(DeviceRole.Desktop, account.Device.Role);
        other.Close();
    }

    [SidecarFact]
    public async Task AtLaunchItStartsAgainAndSignsInByItselfAlsoWhenItsPortWasTaken()
    {
        var first = App();
        await first.StartHostingAsync();
        var port = first.Hosting!.Port;
        Assert.True(first.Prefs.GetBool("hosting"));
        Assert.Equal(port, first.Prefs.GetInt("hosting_port"));
        var firstUser = first.User!.Id;
        await first.ShutDownAsync();

        using var taken = new TcpListener(IPAddress.Loopback, port);
        taken.Start();
        // The same computer launched again (its preferences and secrets kept).
        var again = App(store: first.Prefs, secrets: null);
        await again.Start();
        Assert.NotEqual(port, again.Hosting!.Port);
        Assert.NotNull(again.User);
        Assert.Equal(firstUser, again.User!.Id);
    }

    [SidecarFact]
    public async Task SigningOutStopsTheServerTakesItOffTheTailnetAndShowsTheSetupAgain()
    {
        var a = App();
        await a.StartHostingAsync();
        await a.Hosting!.RefreshAsync();
        var port = a.Hosting!.Port;
        await a.SignOut();
        Assert.Null(a.Hosting);
        Assert.Null(a.Backend);
        Assert.Null(a.User);
        Assert.Contains("serve --https=443 off", _fake.Calls);
        Assert.False(await Listening(port));
        Assert.False(a.Prefs.GetBool("hosting"));
    }

    [SidecarFact]
    public async Task AComputerThatRunsTheServerStartsItAtLaunchQuittingTakesItOffTheTailnetAndStopsIt()
    {
        var a = App(new Dictionary<string, object> { ["hosting"] = true });
        await a.Start();
        Assert.NotNull(a.User);
        await a.Hosting!.RefreshAsync();
        Assert.Equal(HostState.Ready, a.Hosting!.State);
        var port = a.Hosting!.Port;
        await a.FakeHost.OnEvent!("quitting");
        Assert.Equal("serve --https=443 off", _fake.Calls[^1]);
        Assert.False(await Listening(port));
    }

    [SidecarFact]
    public async Task ErasingSignsEveryPhoneOutAndThisComputerBackIn()
    {
        var a = App();
        await a.StartHostingAsync();
        await a.Hosting!.RefreshAsync();
        var phone = new PocketTermServerClient(a.Backend!, new MemoryDeviceTokens());
        await phone.RedeemCode(Backend.PairingCode(DartUri.Parse(await a.PairingLink()))!, "iPhone", "ios");
        var before = a.User!.Device.Id;

        await a.EraseServer();
        Assert.NotNull(a.User);
        Assert.NotEqual(before, a.User!.Device.Id);
        var e = await Assert.ThrowsAsync<ServerException>(phone.Devices);
        Assert.Equal(401, e.Status);
        Assert.Equal(DeviceRole.Desktop, Assert.Single(await a.ServerDevicesAsync()).Role);
        phone.Close();
    }
}
