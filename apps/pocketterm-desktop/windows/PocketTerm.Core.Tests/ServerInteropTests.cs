using System.Text;
using System.Text.Json.Nodes;

namespace PocketTerm.Core.Tests;

/// <summary>
/// packages/pocketterm_core/test/server_client_test.dart against the real Dart server (POCKETTERM_INTEROP=1), plus
/// the cross-language interop run: a computer signs in with the setup link, pairs a phone, both join the
/// computer's topic, sealed frames go both ways, a sealed blob goes up and down, and both sign out.
/// </summary>
public sealed class ServerInteropTests : IAsyncLifetime
{
    private DartServer _own = null!;
    private PocketTermServerClient _mac = null!;
    private PocketTermServerClient _phone = null!;

    public async Task InitializeAsync()
    {
        if (!DartServer.Enabled) return;
        _own = await DartServer.Start();
        _mac = await _own.Desktop();
        _phone = await _own.Phone(_mac);
    }

    public async Task DisposeAsync()
    {
        if (!DartServer.Enabled) return;
        _mac.Close();
        _phone.Close();
        await _own.DisposeAsync();
    }

    [InteropFact]
    public async Task InteropSetupPairChannelBlobSignOut()
    {
        // The computer signs in with the server's own setup link, as the desktop app does.
        var link = await _own.SetupLink();
        var backend = Backend.FromLink(link)!;
        Assert.Equal(_own.Backend, backend);
        var computer = new PocketTermServerClient(backend, new MemoryDeviceTokens());
        var account = await computer.RedeemSetup(Backend.SetupToken(DartUri.Parse(link))!, "Windows PC", "windows");
        Assert.Equal(DeviceRole.Desktop, account.Device.Role);
        await computer.PutDesktop("wxyz7890", "Windows PC", "windows");

        // The phone redeems the computer's QR.
        var key = ChannelKey.Generate();
        var qr = backend.LinkWithCode(await computer.CreatePairingCode(), new ComputerKey("wxyz7890", key));
        var qrUri = DartUri.Parse(qr);
        Assert.Equal(key, Backend.ComputerKey(qrUri)!.Key);
        var phone = new PocketTermServerClient(Backend.FromLink(qrUri)!, new MemoryDeviceTokens());
        await phone.RedeemCode(Backend.PairingCode(qrUri)!, "Pixel", "android");
        Assert.Equal(account.Id, phone.Account!.Id);
        var listed = Desktop.FromJson((await phone.Desktops()).Single(d => d.Str("id") == "wxyz7890"));
        Assert.True(listed.Online);
        Assert.True(listed.Windows);

        // Both join the computer's topic; sealed frames go both ways.
        var atComputer = new List<JsonObject>();
        var atPhone = new List<JsonObject>();
        var desk = new TerminalChannel(computer, "wxyz7890", new Dictionary<string, Action<JsonObject>> { ["hello"] = m => { lock (atComputer) atComputer.Add(m); } }, key, "computer");
        var remote = new TerminalChannel(phone, "wxyz7890", new Dictionary<string, Action<JsonObject>> { ["state"] = m => { lock (atPhone) atPhone.Add(m); } }, key, "phone");
        desk.Open();
        remote.Open();
        await Wait.Until(() => desk.Joined && remote.Joined, 15);
        await remote.Send("hello", new JsonObject { ["from"] = "phone-1", ["session"] = "wezterm-1/2" });
        for (var i = 1; i <= 3; i++) await desk.Send("state", new JsonObject { ["windows"] = new JsonArray(), ["n"] = i, ["text"] = "héllo 😀" });
        await Wait.Until(() => atComputer.Count == 1 && atPhone.Count == 3, 10);
        Vectors.AssertJson(new JsonObject { ["from"] = "phone-1", ["session"] = "wezterm-1/2" }, atComputer.Single());
        Assert.Equal([1L, 2L, 3L], atPhone.Select(m => m.Int("n")!.Value));
        Assert.Equal("héllo 😀", atPhone[0].Str("text"));

        // A sealed blob up from the phone, down at the computer, once.
        var path = phone.NewBlobPath();
        var plain = Encoding.UTF8.GetBytes("a prompt file");
        await phone.PutBlob(path, E2e.SealBytes(key, plain, E2e.ImageAad(path)));
        Assert.Equal(plain, E2e.OpenBytes(key, await computer.GetBlob(path), E2e.ImageAad(path)));
        Assert.Equal(404, (await Assert.ThrowsAsync<ServerException>(() => computer.GetBlob(path))).Status);

        // Sign out: both leave; their tokens work no more.
        await desk.Close();
        await remote.Close();
        await phone.Leave();
        Assert.Null(phone.Account);
        Assert.DoesNotContain((await computer.Devices()), d => d.Label == "Pixel");
        await computer.Leave();
        Assert.Null(computer.Account);
        Assert.Equal(401, (await Assert.ThrowsAsync<ServerException>(() => new PocketTermServerClient(backend, new MemoryDeviceTokens()).Devices())).Status);
        computer.Close();
        phone.Close();
    }

    [InteropFact]
    public async Task APhonesCodeSignsItInOnceAWrongOneSignsNobodyIn()
    {
        Assert.Equal(DeviceRole.Desktop, _mac.Account?.Device.Role);
        Assert.Equal(DeviceRole.Phone, _phone.Account?.Device.Role);
        Assert.Equal(_mac.Account?.Id, _phone.Account?.Id);

        var code = await _mac.CreatePairingCode();
        await _own.Client().RedeemCode(code, "iPad", "ios");
        var late = _own.Client();
        Assert.Equal("invalid_code", (await Assert.ThrowsAsync<ServerException>(() => late.RedeemCode(code, "Pixel", "android"))).Code);
        Assert.Null(late.Account);
        Assert.Equal("invalid_code", (await Assert.ThrowsAsync<ServerException>(() => _own.Client().RedeemSetup("not-the-token", "Mac mini", "macos"))).Code);
        await Assert.ThrowsAsync<ServerException>(() => _phone.CreatePairingCode());
    }

    [InteropFact]
    public async Task TheLiveChannelCarriesSealedMessagesBothWays()
    {
        var key = ChannelKey.Generate();
        var atMac = new List<JsonObject>();
        var atPhone = new List<JsonObject>();
        var desk = new TerminalChannel(_mac, "abcd1234", new Dictionary<string, Action<JsonObject>> { ["hello"] = m => { lock (atMac) atMac.Add(m); } }, key, "mac");
        var remote = new TerminalChannel(_phone, "abcd1234", new Dictionary<string, Action<JsonObject>> { ["state"] = m => { lock (atPhone) atPhone.Add(m); } }, key, "phone");
        // Someone on the same server without the key hears nothing it can open.
        var stranger = new List<JsonObject>();
        var other = new TerminalChannel(
            await _own.Phone(_mac),
            "abcd1234",
            new Dictionary<string, Action<JsonObject>> { ["hello"] = m => { lock (stranger) stranger.Add(m); }, ["state"] = m => { lock (stranger) stranger.Add(m); } },
            ChannelKey.Generate(),
            "stranger");
        try
        {
            desk.Open();
            remote.Open();
            other.Open();
            await Wait.Until(() => desk.Joined && remote.Joined && other.Joined, 15);

            await remote.Send("hello", new JsonObject { ["from"] = "phone-1" });
            await desk.Send("state", new JsonObject { ["windows"] = new JsonArray() });
            await Wait.Until(() => atMac.Count > 0 && atPhone.Count > 0);
            Vectors.AssertJson(new JsonObject { ["from"] = "phone-1" }, atMac.Single());
            Vectors.AssertJson(new JsonObject { ["windows"] = new JsonArray() }, atPhone.Single());
            await Task.Delay(200);
            Assert.Empty(stranger);
        }
        finally
        {
            await desk.Close();
            await remote.Close();
            await other.Close();
        }
    }

    [InteropFact]
    public async Task ABlobGoesUpOnceComesDownOnceAndIsGoneAfter()
    {
        var path = _phone.NewBlobPath();
        Assert.True(Server.IsBlobPath(path));
        Assert.False(Server.IsBlobPath("../etc/passwd"));
        var bytes = Enumerable.Range(0, 70000).Select(i => (byte)(i % 251)).ToArray();
        await _phone.PutBlob(path, bytes);
        Assert.Equal(409, (await Assert.ThrowsAsync<ServerException>(() => _phone.PutBlob(path, new byte[1]))).Status);
        Assert.Equal(bytes, await _mac.GetBlob(path));
        Assert.Equal(404, (await Assert.ThrowsAsync<ServerException>(() => _mac.GetBlob(path))).Status);

        var unused = _phone.NewBlobPath();
        await _phone.PutBlob(unused, new byte[4]);
        await _phone.DeleteBlob(unused);
        await Assert.ThrowsAsync<ServerException>(() => _mac.GetBlob(unused));
    }

    [InteropFact]
    public async Task AnImageOverTheLimitIsRefusedWithItsReason()
    {
        var path = _phone.NewBlobPath();
        Assert.Equal(413, (await Assert.ThrowsAsync<ServerException>(() => _phone.PutBlob(path, new byte[Server.MaxBlobBytes + 1]))).Status);
        Assert.Equal(404, (await Assert.ThrowsAsync<ServerException>(() => _mac.GetBlob(path))).Status);
    }

    [InteropFact]
    public async Task AComputerListsItselfForThePhonesAndTakesItselfOff()
    {
        await _mac.PutDesktop("abcd1234", "MacBook Pro", "macos");
        var rows = await _phone.Desktops();
        Assert.Equal("abcd1234", rows.Single().Str("id"));
        Assert.Equal("MacBook Pro", rows.Single().Str("name"));
        Assert.True((DartDate.Parse(rows.Single().Str("seen_at")!) - DateTimeOffset.UtcNow).Duration() < TimeSpan.FromMinutes(1));
        await Assert.ThrowsAsync<ServerException>(() => _phone.PutDesktop("zzzz9999", "Fake", "macos"));

        await _mac.DeleteDesktop("abcd1234");
        Assert.Empty(await _phone.Desktops());
    }

    [InteropFact]
    public async Task AComputersPushReachesEachPhoneTheRelayKnows()
    {
        const string token = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";
        await _phone.Push("register", new JsonObject { ["token"] = token, ["label"] = "iPhone", ["platform"] = "ios" });
        var key = ChannelKey.Generate();
        var enc = Convert.ToBase64String(E2e.SealBytes(key, Encoding.UTF8.GetBytes("""{"title":"done"}"""), E2e.PushAad("abcd1234")));
        var sent = await _mac.Push("notify", new JsonObject
        {
            ["tag"] = E2e.PushTag(key),
            ["enc"] = enc,
            ["collapse"] = E2e.SessionTag(key, "abcd1234/s1"),
        });
        Assert.Equal(1, sent.Int("sent"));
        await Wait.Until(() => _own.Relayed.Count > 0);
        // One request for the one phone, sealed to the relay on its way.
        Assert.Single(_own.Relayed);
        Assert.DoesNotContain(token, DartJson.Encode(_own.Relayed.Single()));

        await _phone.Push("unregister", new JsonObject { ["token"] = token });
        Assert.Equal(0, (await _mac.Push("notify", new JsonObject { ["tag"] = E2e.PushTag(key), ["enc"] = enc })).Int("sent"));
    }

    [InteropFact]
    public async Task APhoneThatLeavesOrIsSignedOutCanDoNothingMore()
    {
        var ended = 0;
        _phone.Ended += (_, _) => ended++;
        await _mac.RevokeDevice(_phone.Account!.Device.Id);
        Assert.Equal(401, (await Assert.ThrowsAsync<ServerException>(() => _phone.Desktops())).Status);
        Assert.Equal(1, ended);
        Assert.Null(_phone.Account);

        var other = await _own.Phone(_mac);
        await other.Leave();
        Assert.Null(other.Account);
        Assert.DoesNotContain(await _mac.Devices(), d => d.Role == DeviceRole.Phone);
    }

    [InteropFact]
    public async Task ErasingTheServerSignsEveryDeviceOutButKeepsItsSetupLink()
    {
        await _mac.PutDesktop("abcd1234", "MacBook Pro", "macos");
        await _mac.Erase();
        Assert.Null(_mac.Account);
        await Assert.ThrowsAsync<ServerException>(() => _phone.Desktops());
        var again = await _own.Desktop();
        Assert.Empty(await again.Desktops());
        again.Close();
    }

    [InteropFact]
    public async Task APhoneSignedOutWhileOnTheLiveChannelIsToldAndItsSignInEnds()
    {
        var key = ChannelKey.Generate();
        await _mac.PutDesktop("abcd1234", "MacBook Pro", "macos");
        var ended = 0;
        _phone.Ended += (_, _) => Interlocked.Increment(ref ended);
        var remote = new TerminalChannel(_phone, "abcd1234", new Dictionary<string, Action<JsonObject>>(), key, "phone");
        try
        {
            remote.Open();
            await Wait.Until(() => remote.Joined, 10);
            await _mac.RevokeDevice(_phone.Account!.Device.Id);
            await Wait.Until(() => ended > 0, 10);
            Assert.Null(_phone.Account);
        }
        finally
        {
            await remote.Close();
        }
    }
}
