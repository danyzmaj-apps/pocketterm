using System.Text.Json.Nodes;
using System.Threading.Channels;

namespace PocketTerm.Core;

/// <summary>A Realtime token for this device, when it runs out, and the project's publishable key (Realtime takes
/// it with every connection).</summary>
public sealed record LiveToken(string Token, DateTimeOffset Expires, string Apikey);

/// <summary>
/// PocketTerm set up on a Supabase project (apps/pocketterm-desktop/supabase): the same REST paths as the
/// PocketTerm server under <c>&lt;project&gt;/functions/v1/pocketterm</c>, so everything but the live channel is
/// <see cref="PocketTermServerClient"/>'s. The live channel is Supabase Realtime broadcast on private topics: the
/// function mints this device a Realtime token for 10 minutes at a time (POST /v1/live/token), which Realtime
/// checks against the devices still signed in on every join and refresh.
/// </summary>
public sealed class SupabaseServerClient(Backend backend, IDeviceTokens tokens) : PocketTermServerClient(backend, tokens)
{
    /// <summary>Computer only: a setup link for another computer (POST /v1/setup/new). The one before stops
    /// working; nobody is signed out.</summary>
    public async Task<string> NewSetupLink()
    {
        var answer = await Request("POST", "/v1/setup/new").ConfigureAwait(false);
        if (answer is JsonObject o && o.Str("setup") is { } setup) return Backend.LinkWithSetup(setup);
        throw new ServerException(500, "internal", "The server didn't send a setup link.");
    }

    /// <summary>A Realtime token for this device, when it runs out, and the project's publishable key.</summary>
    public async Task<LiveToken> LiveToken()
    {
        var answer = await Request("POST", "/v1/live/token").ConfigureAwait(false);
        if (answer is JsonObject o && o.Str("token") is { } token && o.Int("expires") is { } expires && o.Str("apikey") is { } apikey)
        {
            return new LiveToken(token, DateTimeOffset.FromUnixTimeMilliseconds(expires * 1000), apikey);
        }
        throw new ServerException(500, "internal", "The server didn't send a live channel token.");
    }

    public override async Task<ILiveSocket> ConnectLive()
    {
        var first = await LiveToken().ConfigureAwait(false);
        var url = DartUri.Parse(Backend.Url);
        var ws = await WebSocketConnection.Connect(
            url.Replace(
                url.Scheme == "https" ? "wss" : "ws",
                "/realtime/v1/websocket",
                [new("apikey", first.Apikey), new("vsn", "1.0.0")]),
            null,
            TimeSpan.FromSeconds(20)).ConfigureAwait(false);
        return new RealtimeLive(this, ws, first);
    }
}

/// <summary>
/// Supabase Realtime (Phoenix channels, protocol 1.0.0) as an <see cref="ILiveSocket"/>: PROTOCOL.md's frames in
/// and out. A <c>join</c> joins the private channel <c>realtime:&lt;topic&gt;</c> with this device's token,
/// <c>send</c> broadcasts, <c>ping</c> is Phoenix's heartbeat. The token is renewed a minute before it runs out; a
/// refusal (the device was signed out) closes this with 4003. A join Realtime refuses, or a channel it closes,
/// closes this too (the live channel connects again), after asking the server whether the sign-in still holds.
/// <c>pt.left</c> on a topic (someone was signed out) asks it too.
/// </summary>
public sealed class RealtimeLive : ILiveSocket
{
    private readonly SupabaseServerClient _server;
    private readonly WebSocketConnection _ws;
    private readonly Channel<string> _out = Channel.CreateUnbounded<string>();
    private readonly object _gate = new();
    private LiveToken _token;
    private Timer? _renew;
    private int? _code;
    private int _ref;
    private bool _outClosed;

    /// <summary>The topics joined (or joining) and their join refs.</summary>
    private readonly Dictionary<string, string> _joins = new();

    /// <summary>Join refs waiting for Realtime's answer, and their topics.</summary>
    private readonly Dictionary<string, string> _joining = new();

    /// <summary>Heartbeat refs waiting for an answer.</summary>
    private readonly HashSet<string> _beats = new();

    internal RealtimeLive(SupabaseServerClient server, WebSocketConnection ws, LiveToken token)
    {
        _server = server;
        _ws = ws;
        _token = token;
        _ = Task.Run(Listen);
        RenewLater();
    }

    public ChannelReader<string> Frames => _out.Reader;

    public int? CloseCode
    {
        get
        {
            lock (_gate) return _code ?? _ws.CloseCode;
        }
    }

    private string Next() => (++_ref).ToString(System.Globalization.CultureInfo.InvariantCulture);

    private void Phx(string topic, string @event, JsonObject payload, string? @ref = null, string? joinRef = null)
    {
        if (_outClosed) return;
        var frame = new JsonObject { ["topic"] = topic, ["event"] = @event, ["payload"] = payload, ["ref"] = @ref };
        frame.PutIfNotNull("join_ref", joinRef);
        _ws.Add(DartJson.Encode(frame));
    }

    private void Emit(JsonObject frame)
    {
        if (!_outClosed) _out.Writer.TryWrite(DartJson.Encode(frame));
    }

    public void Add(string frame)
    {
        if (DartJson.TryDecode(frame) is not JsonObject f) return;
        lock (_gate)
        {
            switch (f.Str("t"))
            {
                case "join" when f.Str("topic") is { } topic:
                {
                    var r = Next();
                    _joins[topic] = r;
                    _joining[r] = topic;
                    Phx(
                        $"realtime:{topic}",
                        "phx_join",
                        new JsonObject
                        {
                            ["config"] = new JsonObject
                            {
                                ["broadcast"] = new JsonObject { ["self"] = false, ["ack"] = false },
                                ["presence"] = new JsonObject { ["key"] = "", ["enabled"] = false },
                                ["private"] = true,
                            },
                            ["access_token"] = _token.Token,
                        },
                        r,
                        r);
                    break;
                }
                case "send" when f.Str("topic") is { } topic && f.Str("event") is { } ev && f.ContainsKey("payload"):
                {
                    if (!_joins.TryGetValue(topic, out var joinRef) || _joining.ContainsValue(topic))
                    {
                        Emit(new JsonObject { ["t"] = "error", ["error"] = "not_joined", ["message"] = $"Join {topic} first." });
                        return;
                    }
                    Phx(
                        $"realtime:{topic}",
                        "broadcast",
                        new JsonObject { ["type"] = "broadcast", ["event"] = ev, ["payload"] = f["payload"]?.DeepClone() },
                        Next(),
                        joinRef);
                    break;
                }
                case "leave" when f.Str("topic") is { } topic:
                    if (_joins.Remove(topic, out var leaveRef)) Phx($"realtime:{topic}", "phx_leave", new JsonObject(), Next(), leaveRef);
                    break;
                case "ping":
                {
                    var r = Next();
                    _beats.Add(r);
                    Phx("phoenix", "heartbeat", new JsonObject(), r);
                    break;
                }
            }
        }
    }

    private async Task Listen()
    {
        try
        {
            await foreach (var data in _ws.Frames.ReadAllAsync().ConfigureAwait(false)) Receive(data);
        }
        catch (Exception)
        {
            // Gone either way.
        }
        Gone();
    }

    private void Receive(string data)
    {
        if (DartJson.TryDecode(data) is not JsonObject m) return;
        var refused = false;
        var recheck = false;
        lock (_gate)
        {
            var topic = ReplaceFirst(m.Str("topic") ?? "", "realtime:", "");
            var payload = m["payload"];
            var r = m.Str("ref");
            switch (m.Str("event"))
            {
                case "phx_reply" when r != null && _beats.Remove(r):
                    Emit(new JsonObject { ["t"] = "pong" });
                    break;
                case "phx_reply" when r != null && _joining.ContainsKey(r):
                {
                    _joining.Remove(r, out var joined);
                    if (payload is JsonObject p && p.Str("status") == "ok")
                    {
                        Emit(new JsonObject { ["t"] = "joined", ["topic"] = joined });
                        return;
                    }
                    Log.Print($"PocketTerm: Realtime refused {joined}: {DartJson.Encode(payload is JsonObject pp ? pp["response"] : payload)}");
                    refused = true;
                    break;
                }
                case "broadcast" when _joins.ContainsKey(topic):
                    if (payload is JsonObject b && b.Str("event") is { } ev && b.ContainsKey("payload"))
                    {
                        // Someone was signed out: this device asks whether it was.
                        if (ev == "pt.left") recheck = true;
                        else Emit(new JsonObject { ["t"] = "msg", ["topic"] = topic, ["event"] = ev, ["payload"] = b["payload"]?.DeepClone() });
                    }
                    break;
                case "phx_error" or "phx_close" when _joins.ContainsKey(topic):
                    Log.Print($"PocketTerm: Realtime closed {topic} ({m.Str("event")})");
                    refused = true;
                    break;
                case "system" when payload is JsonObject s && s.Str("status") == "error":
                    Log.Print($"PocketTerm: Realtime: {DartJson.AsString(s["message"]) ?? DartJson.Encode(s["message"])}");
                    refused = true;
                    break;
            }
        }
        if (recheck) _ = _server.Recheck();
        if (refused) Refused();
    }

    private static string ReplaceFirst(string s, string what, string with)
    {
        var i = s.IndexOf(what, StringComparison.Ordinal);
        return i < 0 ? s : s[..i] + with + s[(i + what.Length)..];
    }

    /// <summary>Realtime turned this device away or closed its channel (an old token, a device signed out
    /// meanwhile): ask the server, then connect again.</summary>
    private void Refused()
    {
        _ = _server.Recheck();
        _ = Close();
    }

    private void RenewLater()
    {
        lock (_gate)
        {
            var wait = _token.Expires - DateTimeOffset.UtcNow - TimeSpan.FromMinutes(1);
            Schedule(wait < TimeSpan.FromSeconds(10) ? TimeSpan.FromSeconds(10) : wait);
        }
    }

    private void Schedule(TimeSpan wait)
    {
        _renew?.Dispose();
        if (_outClosed) return;
        _renew = new Timer(_ => _ = RenewNow(), null, wait, Timeout.InfiniteTimeSpan);
    }

    private async Task RenewNow()
    {
        LiveToken token;
        try
        {
            token = await _server.LiveToken().ConfigureAwait(false);
        }
        catch (ServerException e)
        {
            if (e.Status == 401)
            {
                await Close(4003).ConfigureAwait(false);
                return;
            }
            lock (_gate) Schedule(TimeSpan.FromSeconds(15));
            return;
        }
        lock (_gate)
        {
            _token = token;
            if (_outClosed) return;
            foreach (var (topic, joinRef) in _joins)
            {
                Phx($"realtime:{topic}", "access_token", new JsonObject { ["access_token"] = _token.Token }, Next(), joinRef);
            }
        }
        RenewLater();
    }

    private void Gone()
    {
        lock (_gate)
        {
            _renew?.Dispose();
            _renew = null;
            _outClosed = true;
            _out.Writer.TryComplete();
        }
    }

    public async Task Close(int code = 1000)
    {
        lock (_gate)
        {
            _code ??= code == 1000 ? null : code;
            _renew?.Dispose();
            _renew = null;
            _outClosed = true;
            _out.Writer.TryComplete();
        }
        try
        {
            await _ws.Close(1000).ConfigureAwait(false);
        }
        catch (Exception)
        {
            // Gone already.
        }
    }
}
