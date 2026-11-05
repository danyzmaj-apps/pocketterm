using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Http;

namespace PocketTerm.Core.Tests;

/// <summary>A computer, or with <c>phone</c> a phone, keeping its sign-in in its tokens and the computer keys from
/// links in <see cref="Keys"/> (session_test.dart's _Device).</summary>
internal class TestDevice : Session
{
    public TestDevice(string device, bool phone = false, bool atOnce = false, IDeviceTokens? tokens = null, IPreferenceStore? prefs = null)
        : base(device, prefs ?? new MemoryPreferenceStore())
    {
        Phone = phone;
        AtOnce = atOnce;
        Tokens = tokens ?? new MemoryDeviceTokens();
        Notices += (_, m) => Told.Add(m);
    }

    public bool Phone { get; }

    public bool AtOnce { get; }

    public IDeviceTokens Tokens { get; }

    public List<ComputerKey> Keys { get; } = [];

    /// <summary>What a computer puts in its phone codes.</summary>
    public ComputerKey? Computer { get; set; }

    /// <summary>What <see cref="Session.Notices"/> said, in order.</summary>
    public List<string> Told { get; } = [];

    public override DeviceRole Role => Phone ? DeviceRole.Phone : DeviceRole.Desktop;

    public override string Platform => Phone ? "ios" : "macos";

    protected override IDeviceTokens DeviceTokens => Tokens;

    protected override bool SignInAtOnce => AtOnce;

    protected override Task AddComputerKey(ComputerKey computer)
    {
        Keys.Add(computer);
        return Task.CompletedTask;
    }

    public override ChannelKey? ComputerKey(string desktopId) => Keys.LastOrDefault(k => k.Desktop == desktopId)?.Key;

    public override bool HostsServer => !Phone;

    protected override Task<ComputerKey?> PairingComputer() => Task.FromResult(Computer);
}

/// <summary>A signed-out phone that records which setup links it acts on.</summary>
internal sealed class LinkSession() : TestDevice("iPhone", phone: true)
{
    public List<string> Connected { get; } = [];

    public List<bool> Scans { get; } = [];

    public override Task ConnectLink(string link, bool scanned = false)
    {
        Connected.Add(link);
        Scans.Add(scanned);
        return Task.CompletedTask;
    }
}

/// <summary>A Keychain that refuses until <see cref="Locked"/> is turned off, as a locked or missing one does.</summary>
internal sealed class LockedKeychain : IDeviceTokens
{
    public bool Locked = true;

    public string? Value;

    public Task<string?> Read() => Task.FromResult(Value);

    public Task Write(string? value)
    {
        if (Locked) throw new SecureStoreException("Code: -25308, Message: locked");
        Value = value;
        return Task.CompletedTask;
    }
}

/// <summary>packages/pocketterm_core/test/session_test.dart: against the real server (interop) where it needs one.</summary>
public sealed class SessionTests : IAsyncLifetime
{
    private DartServer _own = null!;
    private TestDevice _mac = null!;
    private string _setupLink = null!;
    private readonly List<TestDevice> _devices = [];

    public async Task InitializeAsync()
    {
        if (!DartServer.Enabled) return;
        _own = await DartServer.Start();
        _setupLink = await _own.SetupLink();
        _mac = new TestDevice("MacBook Pro") { Computer = new ComputerKey("abcd1234", ChannelKey.Generate()) };
        await _mac.ConnectLink(_setupLink);
    }

    public async Task DisposeAsync()
    {
        if (!DartServer.Enabled) return;
        foreach (var d in _devices) await d.Disconnect();
        await _mac.Disconnect();
        await _own.DisposeAsync();
    }

    private TestDevice Device(string name, bool phone = false, bool atOnce = false, IDeviceTokens? tokens = null)
    {
        var d = new TestDevice(name, phone, atOnce, tokens);
        _devices.Add(d);
        return d;
    }

    [InteropFact]
    public async Task AComputerSignsInWithTheSetupLinkAPhoneWithItsCode()
    {
        Assert.Null(_mac.AuthError);
        Assert.Equal(DeviceRole.Desktop, _mac.User?.Device.Role);
        Assert.Equal("MacBook Pro", _mac.User?.Device.Label);

        var phone = Device("iPhone", phone: true);
        await phone.ConnectLink(await _mac.PairingLink(), scanned: true);
        Assert.Null(phone.AuthError);
        Assert.Equal(DeviceRole.Phone, phone.User?.Device.Role);
        Assert.Equal(_mac.User?.Id, phone.User?.Id);
        Assert.Equal([_mac.Computer!], phone.Keys);

        // A code works once.
        var link = await _mac.PairingLink();
        var second = Device("iPad", phone: true);
        await second.ConnectLink(link);
        Assert.NotNull(second.User);
        var third = Device("Pixel", phone: true);
        await third.ConnectLink(link);
        Assert.Null(third.User);
        Assert.Contains("used", third.AuthError);
    }

    [InteropFact]
    public async Task AKeychainThatRefusesSaysSoPlainlyAndTryAgainSignsIn()
    {
        var keychain = new LockedKeychain();
        var other = Device("Mac mini", tokens: keychain);
        await other.ConnectLink(_setupLink);
        Assert.Null(other.User);
        Assert.Equal(Session.KeychainProblem, other.AuthError);
        Assert.Equal(_setupLink, other.RetryLink);

        keychain.Locked = false;
        await other.Retry();
        Assert.Null(other.AuthError);
        Assert.Equal("Mac mini", other.User?.Device.Label);
        Assert.Null(other.RetryLink);
    }

    [InteropFact]
    public async Task ALinkNotFromTheScannerNeverGivesAComputersKey()
    {
        var phone = Device("iPhone", phone: true);
        await phone.ConnectLink(await _mac.PairingLink());
        Assert.NotNull(phone.User);
        Assert.Empty(phone.Keys);

        var planted = new ComputerKey("zzzz9999", ChannelKey.Generate());
        var link = _mac.Backend!.LinkWithCode("ABCD-1234", planted);
        await phone.ConnectLink(link);
        Assert.Empty(phone.Keys);
        Assert.Contains("scanner", phone.Told.Single());
        Assert.Null(phone.AuthError);

        await phone.ConnectLink(link, scanned: true);
        Assert.Equal([planted], phone.Keys);
    }

    [InteropFact]
    public async Task ALinkWithoutWhatThisDeviceSignsInWithSaysSo()
    {
        var phone = Device("iPhone", phone: true);
        await phone.ConnectLink(_setupLink);
        Assert.Null(phone.User);
        Assert.Contains("no sign-in code", phone.AuthError);

        var other = Device("Mac mini");
        await other.ConnectLink(_own.Backend.LinkWithCode(await _mac.Server!.CreatePairingCode()));
        Assert.Null(other.User);
        Assert.Contains("no setup token", other.AuthError);
    }

    [InteropFact]
    public async Task ARelaunchIsSignedInFromWhatTheDeviceKeptSigningOutLeavesForGood()
    {
        var tokens = new MemoryDeviceTokens();
        var phone = Device("iPhone", phone: true, tokens: tokens);
        await phone.ConnectLink(await _mac.PairingLink());
        var id = phone.User!.Device.Id;

        var relaunched = Device("iPhone", phone: true, tokens: tokens);
        await relaunched.Connect(_own.Backend);
        Assert.Equal(id, relaunched.User?.Device.Id);

        await relaunched.SignOut();
        Assert.Null(relaunched.User);
        Assert.Equal("You signed out.", relaunched.SignedOutReason);
        Assert.Null(tokens.Value);
        Assert.DoesNotContain(id, (await _mac.Server!.Devices()).Select(d => d.Id));
    }

    [InteropFact]
    public async Task APhoneTheComputerSignedOutHearsItWithTheReason()
    {
        var phone = Device("iPhone", phone: true);
        await phone.ConnectLink(await _mac.PairingLink());
        await _mac.Server!.RevokeDevice(phone.User!.Device.Id);

        await Assert.ThrowsAsync<ServerException>(() => phone.Server!.Desktops());
        await Wait.Until(() => phone.User == null);
        Assert.Contains("Scan a new code", phone.SignedOutReason);

        // A relaunch with the token it kept before is signed out too.
        var kept = Device("iPhone", phone: true, tokens: new MemoryDeviceTokens { Value = ((MemoryDeviceTokens)phone.Tokens).Value });
        await kept.Connect(_own.Backend);
        Assert.Null(kept.User);
    }

    [InteropFact]
    public async Task ASignedInPhoneThatScansAnotherServersComputerStays()
    {
        var phone = Device("iPhone", phone: true);
        await phone.ConnectLink(await _mac.PairingLink(), scanned: true);
        var before = phone.User;
        var elsewhere = new Backend("https://other.example.com");
        var link = elsewhere.LinkWithCode("ABCD-1234", new ComputerKey("zzzz9999", ChannelKey.Generate()));
        await phone.ConnectLink(link, scanned: true);
        Assert.Same(before, phone.User);
        Assert.Equal(_own.Backend, phone.Backend);
        Assert.Equal([_mac.Computer!], phone.Keys);
        Assert.Contains("other.example.com", phone.Told.Single());
        Assert.Contains("Leave this server", phone.Told.Single());

        await phone.SignOut();
        Assert.Null(phone.AuthError);
    }

    [InteropFact]
    public async Task AScannedCodeCantSwapTheKeyUnlessItsPairingCodeWorks()
    {
        var phone = Device("iPhone", phone: true);
        await phone.ConnectLink(await _mac.PairingLink(), scanned: true);
        var devices = (await _mac.Server!.Devices()).Count;

        // A QR anyone could make: this server, a real computer's id, their own key.
        var planted = new ComputerKey(_mac.Computer!.Desktop, ChannelKey.Generate());
        var link = _mac.Backend!.LinkWithCode("ABCD-EFGH-JKMN-PQRS-TVWX-YZ01-2345", planted);
        await phone.ConnectLink(link, scanned: true);
        Assert.Equal(_mac.Computer.Key, phone.ComputerKey(planted.Desktop));
        Assert.Contains("doesn't work", phone.Told.Single());

        // The computer reset its key: its new code carries the new one, and the phone takes it.
        _mac.Computer = new ComputerKey(_mac.Computer.Desktop, ChannelKey.Generate());
        await phone.ConnectLink(await _mac.PairingLink(), scanned: true);
        Assert.Equal(_mac.Computer.Key, phone.ComputerKey(planted.Desktop));
        Assert.Single(phone.Told);
        Assert.NotNull(phone.User);
        Assert.Equal(devices, (await _mac.Server!.Devices()).Count);
    }

    [InteropFact]
    public async Task ErasingTheServerLeavesNoSignInProblemBehind()
    {
        _mac.AuthError = "Sign out before switching to other.example.com.";
        await _mac.EraseServer();
        Assert.Null(_mac.User);
        Assert.Null(_mac.AuthError);
        Assert.Equal("This server's data was erased.", _mac.SignedOutReason);
    }

    [InteropFact]
    public async Task SigningOutWithTheServerOutOfReachStillForgetsTheSignIn()
    {
        var tokens = new MemoryDeviceTokens();
        var phone = Device("iPhone", phone: true, tokens: tokens);
        await phone.ConnectLink(await _mac.PairingLink());
        await _own.StopServer();
        await phone.SignOut();
        Assert.Null(phone.User);
        Assert.Null(tokens.Value);
        Assert.Equal("You signed out.", phone.SignedOutReason);
    }

    [InteropFact]
    public async Task TheBackendIsKeptInThePreferencesAndDisconnectForgetsIt()
    {
        var prefs = new MemoryPreferenceStore();
        var mac = new TestDevice("Mac mini", prefs: prefs);
        _devices.Add(mac);
        await mac.ConnectLink(_setupLink);
        Assert.Equal(_own.Backend, Backend.Load(prefs));
        var again = new TestDevice("Mac mini", prefs: prefs, tokens: mac.Tokens);
        _devices.Add(again);
        await again.Start();
        Assert.Equal(mac.User?.Device.Id, again.User?.Device.Id);
        await again.Disconnect();
        Assert.Null(Backend.Load(prefs));
        Assert.Null(again.Backend);
    }
}

/// <summary>session_test.dart: a phone launched with the sign-in it kept, against a server that holds GET /v1/me.</summary>
public sealed class SessionHeldTests : IAsyncLifetime
{
    private const string Me = """{"device":{"id":"dev0000000000001","role":"phone","label":"iPhone","platform":"ios"},"server":{"id":"srv0000000000001"}}""";

    private FakeHttp _http = null!;
    private readonly object _gate = new();
    private (int Status, string Body)? _answer;
    private readonly List<TaskCompletionSource> _waiting = [];
    private MemoryDeviceTokens _kept = null!;
    private TestDevice? _phone;

    private Backend Backend => new(_http.Url);

    public async Task InitializeAsync()
    {
        _http = await FakeHttp.Start(async ctx =>
        {
            var me = ctx.Request.Path == "/v1/me";
            TaskCompletionSource? held = null;
            lock (_gate)
            {
                if (me && _answer == null)
                {
                    held = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                    _waiting.Add(held);
                }
            }
            if (held != null) await held.Task;
            var (status, body) = me ? _answer!.Value : (200, "{}");
            ctx.Response.StatusCode = status;
            await ctx.Response.WriteAsync(body);
        });
        _kept = new MemoryDeviceTokens
        {
            Value = DartJson.Encode(new JsonObject
            {
                ["url"] = Backend.Url,
                ["token"] = "token-1",
                ["server"] = "srv0000000000001",
                ["device"] = new JsonObject { ["id"] = "dev0000000000001", ["role"] = "phone", ["label"] = "iPhone", ["platform"] = "ios" },
            }),
        };
    }

    public async Task DisposeAsync()
    {
        if (_phone != null) await _phone.Disconnect();
        await _http.DisposeAsync();
    }

    /// <summary>Answers, once the GET /v1/me is there, with <paramref name="status"/> and <paramref name="body"/>.</summary>
    private async Task Answer(int status, string body)
    {
        for (var i = 0; i < 100; i++)
        {
            lock (_gate)
            {
                if (_waiting.Count > 0) break;
            }
            await Task.Delay(20);
        }
        lock (_gate)
        {
            _answer = (status, body);
            foreach (var w in _waiting) w.SetResult();
            _waiting.Clear();
        }
        // Each answer read before going on.
        await Task.Delay(100);
    }

    private async Task<TestDevice> Launch()
    {
        _phone = new TestDevice("iPhone", phone: true, atOnce: true, tokens: _kept);
        await _phone.Connect(Backend).WaitAsync(TimeSpan.FromSeconds(2));
        return _phone;
    }

    [Fact]
    public async Task IsSignedInBeforeTheServerAnswersAndStaysSoWhenTheAnswerIsNoSignInAnswer()
    {
        var phone = await Launch();
        Assert.Equal("dev0000000000001", phone.User?.Device.Id);
        // A captive portal's page, say.
        await Answer(200, "<html>Sign in to the Wi-Fi</html>");
        Assert.NotNull(phone.User);
        Assert.NotNull(_kept.Value);
    }

    [Fact]
    public async Task IsSignedOutWithTheReasonOnceTheServerRefuses()
    {
        var phone = await Launch();
        Assert.NotNull(phone.User);
        await Answer(401, """{"error":"unauthorized","message":"Sign in again."}""");
        await Wait.Until(() => phone.User == null);
        Assert.Contains("Scan a new code", phone.SignedOutReason);
        Assert.Null(_kept.Value);
    }

    [Fact]
    public async Task SignedOutWhileTheServerIsAskedTheLaterAnswerDoesntSignItBackIn()
    {
        var phone = await Launch();
        await phone.SignOut();
        await Answer(200, Me);
        Assert.Null(phone.User);
        Assert.Null(_kept.Value);
        Assert.Null(phone.Server!.Account);
    }
}

/// <summary>session_test.dart: a setup link opened from outside the app.</summary>
public class SessionLinkTests
{
    private static readonly Backend Mine = new("https://mine.example.com");
    private static readonly Backend Theirs = new("https://theirs.example.com");

    [Fact]
    public async Task ConnectsASignedOutDeviceToAnotherServerOnlyOnceThePersonSaysSo()
    {
        var session = new LinkSession();
        var link = Theirs.LinkWithCode("ABCD-1234");
        session.OpenedLink(DartUri.Parse(link), Mine);
        Assert.Empty(session.Connected);
        Assert.Equal(link, session.LinkToConfirm);
        Assert.Equal("theirs.example.com", session.LinkToConfirmHost);
        await session.AnswerLink(connect: true);
        Assert.Equal([link], session.Connected);
        Assert.Null(session.LinkToConfirm);
    }

    [Fact]
    public async Task IsDroppedWhenThePersonSaysNoAndAsksOnADeviceSetUpNowhere()
    {
        var session = new LinkSession();
        session.OpenedLink(DartUri.Parse(Theirs.LinkWithCode("ABCD-1234")), null);
        Assert.NotNull(session.LinkToConfirm);
        await session.AnswerLink(connect: false);
        Assert.Empty(session.Connected);
        Assert.Null(session.LinkToConfirm);
    }

    [Fact]
    public void GoesAheadForTheDevicesOwnServerNeverAsAScan()
    {
        var session = new LinkSession();
        var link = Mine.LinkWithCode("ABCD-1234");
        session.OpenedLink(DartUri.Parse(link), Mine);
        Assert.Equal([link], session.Connected);
        Assert.Equal([false], session.Scans);
        Assert.Null(session.LinkToConfirm);
    }

    [Fact]
    public void HandleLinkUsesTheSavedBackend()
    {
        var prefs = new MemoryPreferenceStore();
        Mine.Save(prefs);
        var session = new LinkSessionWith(prefs);
        session.HandleLink(Mine.LinkWithCode("ABCD-1234"));
        Assert.Single(session.Connected);
        session.HandleLink(Theirs.LinkWithCode("ABCD-1234"));
        Assert.Single(session.Connected);
        Assert.NotNull(session.LinkToConfirm);
    }

    private sealed class LinkSessionWith(IPreferenceStore prefs) : TestDevice("iPhone", phone: true, prefs: prefs)
    {
        public List<string> Connected { get; } = [];

        public override Task ConnectLink(string link, bool scanned = false)
        {
            Connected.Add(link);
            return Task.CompletedTask;
        }
    }
}
