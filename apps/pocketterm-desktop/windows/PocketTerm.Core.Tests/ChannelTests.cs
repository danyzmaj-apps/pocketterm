using System.Diagnostics;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Http;

namespace PocketTerm.Core.Tests;

/// <summary>packages/pocketterm_core/test/terminal_channel_test.dart.</summary>
public sealed class ChannelTests : IAsyncLifetime
{
    private const string Topic = "abcd1234";
    private static readonly ChannelKey Key = new(Enumerable.Repeat((byte)3, 32).ToArray());

    /// <summary>The computer's side of the topic, sealing what <see cref="FakeServer.Deliver"/> relays.</summary>
    private readonly ChannelSeal _computer = new(Key, Topic);

    private FakeServer _server = null!;
    private PocketTermServerClient _client = null!;
    private TerminalChannel _channel = null!;
    private readonly List<bool> _states = [];
    private readonly List<JsonObject> _received = [];

    /// <summary>
    /// A PocketTerm server on loopback as far as the live channel goes (PROTOCOL.md): <c>GET /v1/me</c>, and
    /// <c>GET /v1/ws</c> answering joins of the topic. It refuses the first <see cref="Refuse"/> connections at the
    /// door, and can drop or end the one there is.
    /// </summary>
    private sealed class FakeServer
    {
        private FakeHttp _http = null!;
        private WebSocket? _ws;
        private readonly SemaphoreSlim _sendLock = new(1, 1);

        public int Refuse;
        public int JoinCount;

        /// <summary>What the client sent on the topic.</summary>
        public List<(string Event, JsonObject Payload)> Sent { get; } = [];

        public int Port => _http.Port;

        public async Task Start(int at = 0)
        {
            _http = await FakeHttp.Start(Handle, at);
        }

        private async Task Handle(HttpContext ctx)
        {
            var authorized = ctx.Request.Headers.Authorization.ToString() == "Bearer token-1";
            if (ctx.Request.Path == "/v1/me")
            {
                ctx.Response.StatusCode = authorized ? 200 : 401;
                await ctx.Response.WriteAsync("""{"device":{"id":"dev0000000000001","role":"phone","label":"iPhone","platform":"ios"},"server":{"id":"srv0000000000001"}}""");
                return;
            }
            if (ctx.Request.Path != "/v1/ws" || !ctx.WebSockets.IsWebSocketRequest || !authorized || Refuse > 0)
            {
                Interlocked.Decrement(ref Refuse);
                ctx.Response.StatusCode = 401;
                return;
            }
            var ws = _ws = await ctx.WebSockets.AcceptWebSocketAsync();
            var buffer = new byte[1 << 20];
            try
            {
                while (ws.State == WebSocketState.Open)
                {
                    var r = await ws.ReceiveAsync(buffer, CancellationToken.None);
                    if (r.MessageType == WebSocketMessageType.Close) break;
                    var frame = (JsonObject)DartJson.Decode(Encoding.UTF8.GetString(buffer, 0, r.Count))!;
                    switch (frame.Str("t"))
                    {
                        case "join" when frame.Str("topic") == Topic:
                            Interlocked.Increment(ref JoinCount);
                            await Send(ws, $$"""{"t":"joined","topic":"{{Topic}}"}""");
                            break;
                        case "send" when frame.Str("topic") == Topic:
                            lock (Sent) Sent.Add((frame.Str("event")!, frame.Obj("payload")!));
                            break;
                        case "ping":
                            await Send(ws, """{"t":"pong"}""");
                            break;
                    }
                }
            }
            catch (Exception)
            {
                // The connection went.
            }
        }

        private async Task Send(WebSocket ws, string text)
        {
            await _sendLock.WaitAsync();
            try
            {
                await ws.SendAsync(Encoding.UTF8.GetBytes(text), WebSocketMessageType.Text, true, CancellationToken.None);
            }
            finally
            {
                _sendLock.Release();
            }
        }

        /// <summary>Relays <paramref name="payload"/> of <paramref name="event"/> to the client, as from another device.</summary>
        public Task Deliver(string @event, JsonObject payload) =>
            Send(_ws!, DartJson.Encode(new JsonObject { ["t"] = "msg", ["topic"] = Topic, ["event"] = @event, ["payload"] = payload }));

        /// <summary>Closes the connection there is with <paramref name="code"/>: 1001 the server stopping, 4003 this device revoked.</summary>
        public async Task Drop(int code)
        {
            var ws = _ws!;
            await _sendLock.WaitAsync();
            try
            {
                await ws.CloseOutputAsync((WebSocketCloseStatus)code, null, CancellationToken.None);
            }
            catch (Exception)
            {
                ws.Abort();
            }
            finally
            {
                _sendLock.Release();
            }
        }

        public Task Stop() => _http.DisposeAsync().AsTask();
    }

    public Task InitializeAsync() => Task.CompletedTask;

    public async Task DisposeAsync()
    {
        if (_channel != null) await _channel.Close();
        _client?.Close();
        if (_server != null) await _server.Stop();
    }

    private async Task SetUpServer(int refuse = 0)
    {
        _server = new FakeServer { Refuse = refuse };
        await _server.Start();
        var backend = new Backend($"http://127.0.0.1:{_server.Port}");
        var tokens = new MemoryDeviceTokens
        {
            Value = DartJson.Encode(new JsonObject
            {
                ["url"] = backend.Url,
                ["token"] = "token-1",
                ["server"] = "srv0000000000001",
                ["device"] = new JsonObject { ["id"] = "dev0000000000001", ["role"] = "phone", ["label"] = "iPhone", ["platform"] = "ios" },
            }),
        };
        _client = new PocketTermServerClient(backend, tokens);
        await _client.Load();
        Assert.NotNull(_client.Account);
        _channel = new TerminalChannel(
            _client,
            Topic,
            new Dictionary<string, Action<JsonObject>> { ["state"] = m => { lock (_received) _received.Add(m); } },
            Key,
            "test",
            onJoined: joined => { lock (_states) _states.Add(joined); });
    }

    private Task Joined(int count) => Wait.Until(() => _server.JoinCount >= count, 10);

    [Fact]
    public async Task AConnectionTheServerDropsIsMadeAgainAndMessagesReachItAfter()
    {
        await SetUpServer();
        _channel.Open();
        await Joined(1);
        await Wait.Until(() => _channel.Joined);

        await _server.Drop(1001);
        await Wait.Until(() => !_channel.Joined);
        await Joined(2);
        await Wait.Until(() => _channel.Joined);
        Assert.Equal([true, false, true], _states);

        await _server.Deliver("state", _computer.Seal("state", new JsonObject { ["windows"] = 3 }));
        await Wait.Until(() => _received.Count > 0);
        Vectors.AssertJson(new JsonObject { ["windows"] = 3 }, _received.Single());
    }

    [Fact]
    public async Task OpenedMessagesReachTheHandlerInOrderUnsealedOnesNeverSentOnesGoSealed()
    {
        await SetUpServer();
        _channel.Open();
        await Wait.Until(() => _channel.Joined);

        await _server.Deliver("state", new JsonObject { ["windows"] = 99 });
        for (var i = 0; i < 20; i++) await _server.Deliver("state", _computer.Seal("state", new JsonObject { ["windows"] = i }));
        await Wait.Until(() => _received.Count == 20);
        Assert.Equal(Enumerable.Range(0, 20).Select(i => (long)i), _received.Select(m => m.Int("windows")!.Value));

        await _channel.Send("hello", new JsonObject { ["from"] = "phone" });
        await Wait.Until(() => _server.Sent.Count > 0);
        var (ev, payload) = _server.Sent.Single();
        Assert.Equal(["c", "n", "v"], payload.Select(p => p.Key).Order());
        Vectors.AssertJson(new JsonObject { ["from"] = "phone" }, _computer.Open(ev, payload));
    }

    [Fact]
    public async Task AConnectionRefusedAtTheDoorIsTriedAgainUntilLetIn()
    {
        await SetUpServer(refuse: 2);
        _channel.Open();
        await Joined(1);
        await Wait.Until(() => _channel.Joined);
        Assert.Equal([true], _states);
        Assert.NotNull(_client.Account);
    }

    [Fact]
    public async Task RetryConnectsAtOnceHoweverLongTheWaitHadGrown()
    {
        await SetUpServer(refuse: 1000);
        _channel.Open();
        // Refused at 0, 1 and 3 s: the next try would be at 7 s.
        for (var i = 0; i < 50 && _server.Refuse > 997; i++) await Task.Delay(100);
        Assert.Equal(997, _server.Refuse);
        Assert.True(_channel.Unreachable);

        _server.Refuse = 0;
        var retried = Stopwatch.StartNew();
        _channel.Reconnect();
        Assert.False(_channel.Unreachable);
        await Wait.Until(() => _channel.Joined);
        Assert.True(retried.Elapsed < TimeSpan.FromSeconds(1));
        Assert.Equal([true], _states);
    }

    [Fact]
    public async Task AfterCloseNothingJoinsAgain()
    {
        await SetUpServer();
        _channel.Open();
        await Joined(1);
        await _channel.Close();
        await _server.Drop(1001);
        await Task.Delay(1500);
        Assert.Equal(1, _server.JoinCount);
        Assert.False(_channel.Joined);
    }

    [Fact]
    public async Task AMessageTooBigIsRefusedBeforeItGoes()
    {
        await SetUpServer();
        _channel.Open();
        await Wait.Until(() => _channel.Joined);

        await Assert.ThrowsAsync<TerminalException>(() => _channel.Send("run", new JsonObject { ["text"] = new string('x', 200 * 1024) }));
        await _channel.Send("run", new JsonObject { ["text"] = "small" });
        await Wait.Until(() => _server.Sent.Count > 0);
        Vectors.AssertJson(new JsonObject { ["text"] = "small" }, _computer.Open("run", _server.Sent.Single().Payload));
        Assert.Equal([true], _states);
    }

    [Fact]
    public void ASenderWhoseClockIsFarOffIsToldApart()
    {
        var now = DateTimeOffset.UtcNow;
        var skew = TimeSpan.FromMinutes(12);
        var phone = new ChannelSeal(Key, Topic, clock: () => DateTimeOffset.UtcNow + skew);
        var mac = new ChannelSeal(Key, Topic, clock: () => DateTimeOffset.UtcNow);
        Assert.Null(mac.Open("hello", phone.Seal("hello", new JsonObject { ["from"] = "p" })));
        Assert.InRange(mac.ClockOff!.Value.TotalSeconds, 12 * 60 - 2, 12 * 60 + 2);
        skew = TimeSpan.FromMinutes(-30);
        Assert.Null(mac.Open("hello", phone.Seal("hello", new JsonObject { ["from"] = "p" })));
        Assert.InRange(mac.ClockOff!.Value.TotalSeconds, -30 * 60 - 2, -30 * 60 + 2);
        skew = TimeSpan.Zero;
        Vectors.AssertJson(new JsonObject { ["from"] = "p" }, mac.Open("hello", phone.Seal("hello", new JsonObject { ["from"] = "p" })));
        Assert.Null(mac.ClockOff);
        // A message from before the receiver started is old, not off.
        var early = new ChannelSeal(Key, Topic, clock: () => now - TimeSpan.FromSeconds(30));
        var late = new ChannelSeal(Key, Topic, clock: () => DateTimeOffset.UtcNow);
        Assert.Null(late.Open("hello", early.Seal("hello", new JsonObject())));
        Assert.Null(late.ClockOff);
    }

    [Fact]
    public async Task ACloseForARevokedDeviceEndsTheSignInAndNothingJoinsAgain()
    {
        await SetUpServer();
        var ended = false;
        _client.Ended += (_, _) => ended = true;
        _channel.Open();
        await Joined(1);
        await _server.Drop(4003);
        await Wait.Until(() => ended);
        Assert.Null(_client.Account);
        await Task.Delay(1500);
        Assert.Equal(1, _server.JoinCount);
        Assert.False(_channel.Joined);
    }

    [Fact]
    public async Task AServerThatGoesAwayReadsAsUnreachableUntilLetInAgain()
    {
        await SetUpServer();
        var told = 0;
        _channel = new TerminalChannel(_client, Topic, new Dictionary<string, Action<JsonObject>>(), Key, "test", onUnreachable: () => Interlocked.Increment(ref told));
        _channel.Open();
        await Joined(1);
        Assert.False(_channel.Unreachable);

        var port = _server.Port;
        await _server.Drop(1001);
        await _server.Stop();
        await Wait.Until(() => _channel.Unreachable);
        Assert.False(_channel.Joined);

        _server = new FakeServer();
        await _server.Start(port);
        for (var i = 0; i < 150 && !_channel.Joined; i++) await Task.Delay(100);
        Assert.True(_channel.Joined);
        Assert.False(_channel.Unreachable);
        Assert.Equal(2, told);

        await _channel.Close();
        Assert.False(_channel.Unreachable);
    }
}
