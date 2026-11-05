using System.Text.Json.Nodes;

namespace PocketTerm.Core;

/// <summary>
/// Seals what goes out on <see cref="Topic"/> with the computer's <see cref="Key"/> and opens what comes in
/// (<see cref="E2e"/>). Each message gets a <c>ts</c>, a random <c>mid</c>, this seal's <c>ep</c> (random, new
/// for each seal: each start of a sender) and <c>seq</c> (1, 2, 3 …). What doesn't open or the
/// <see cref="ReplayGuard"/> refuses (stale, seen before, out of order) is dropped and logged once per kind. The
/// guard is the computer's for this run of the app (<see cref="ReplayGuard.Of"/>) unless one is given
/// (<c>guard</c>, or a fresh one on a test <c>clock</c>). Thread-safe.
/// </summary>
public sealed class ChannelSeal
{
    private readonly Func<DateTimeOffset> _clock;
    private readonly ReplayGuard _guard;
    private readonly HashSet<string> _logged = new();
    private readonly string _epoch = E2e.NewMessageId();
    private readonly object _gate = new();
    private long _seq;
    private TimeSpan? _clockOff;

    public ChannelSeal(ChannelKey key, string topic, string name = "channel", ReplayGuard? guard = null, Func<DateTimeOffset>? clock = null)
    {
        Key = key;
        Topic = topic;
        Name = name;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        _guard = guard ?? (clock == null ? ReplayGuard.Of(topic) : new ReplayGuard(clock: clock));
    }

    public ChannelKey Key { get; }

    public string Topic { get; }

    /// <summary>Who this is, in the log.</summary>
    public string Name { get; }

    /// <summary><paramref name="payload"/> of <paramref name="event"/>, as it goes on the topic. Seal in the order
    /// sent: a receiver drops a <c>seq</c> below one it already took. The payload goes whole under <c>m</c>, beside
    /// the envelope's <c>ts</c>, <c>mid</c>, <c>ep</c> and <c>seq</c>, so a payload's own keys of those names (an
    /// items catch-up's <c>seq</c>) stay.</summary>
    public JsonObject Seal(string @event, JsonObject payload)
    {
        long seq;
        lock (_gate) seq = ++_seq;
        return E2e.SealEnvelope(Key, new JsonObject
        {
            ["m"] = payload.DeepClone(),
            ["ts"] = _clock().ToUnixTimeMilliseconds(),
            ["mid"] = E2e.NewMessageId(),
            ["ep"] = _epoch,
            ["seq"] = seq,
        }, E2e.ChannelAad(Topic, @event));
    }

    /// <summary>How far the other side's clock is ahead of this one (behind: negative), as the last message dropped
    /// for its time showed; null once a message opens. The guard drops every message more than its window off, so
    /// with a clock that wrong nothing gets through at all.</summary>
    public TimeSpan? ClockOff
    {
        get
        {
            lock (_gate) return _clockOff;
        }
    }

    /// <summary>What <paramref name="wire"/> (an <paramref name="event"/> off the topic) says: the payload
    /// <see cref="Seal"/> put in; null when it's dropped.</summary>
    public JsonObject? Open(string @event, JsonObject wire)
    {
        var (message, drop) = E2e.OpenEnvelope(Key, wire, E2e.ChannelAad(Topic, @event));
        var why = drop ?? _guard.Check(message!);
        lock (_gate)
        {
            if (why == "time" && message?.Int("ts") is { } ts)
            {
                var off = TimeSpan.FromMilliseconds(ts - _clock().ToUnixTimeMilliseconds());
                // A message from before this app started is old, not off.
                if (off.Duration() > _guard.Window)
                {
                    _clockOff = off;
                    if (_logged.Add("clock")) Log.Print($"PocketTerm: {Name}: the other side's clock is off by {(long)off.TotalSeconds} s");
                }
            }
            if (why != null)
            {
                if (_logged.Add($"{@event} {why}")) Log.Print($"PocketTerm: {Name}: dropped {@event} ({why}); more alike go unlogged");
                return null;
            }
            _clockOff = null;
            if (message!["m"] is not JsonObject payload)
            {
                if (_logged.Add($"{@event} shape")) Log.Print($"PocketTerm: {Name}: dropped {@event} (no payload)");
                return null;
            }
            return payload;
        }
    }
}

/// <summary>
/// A computer's <see cref="Topic"/> (its id) on the server's live channel (GET /v1/ws,
/// packages/pocketterm_server/PROTOCOL.md; Supabase Realtime for a Supabase project, <see cref="RealtimeLive"/>),
/// kept joined while open. Everything on it is sealed with the computer's key (<see cref="ChannelSeal"/>): the
/// server only relays envelopes; handlers get the opened messages, in the order they came.
///
/// Whenever it isn't joined (no connection, the server went away or restarted, a join nobody answers, two pings
/// without a pong) this connects again after 1 s, 2 s, 4 s … up to 30 s. A close with 4003 (this device was revoked
/// or left) ends the sign-in instead (<see cref="IServer.Refused"/>). Thread-safe; handlers and callbacks run on
/// a background thread, one at a time per connection.
/// </summary>
public sealed class TerminalChannel
{
    private static readonly TimeSpan FirstWait = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan MaxWait = TimeSpan.FromSeconds(30);

    /// <summary>How long a join may take before it counts as stuck.</summary>
    private static readonly TimeSpan Stuck = TimeSpan.FromSeconds(20);

    /// <summary>How often to ping the server; two without a pong and the link is dead.</summary>
    private static readonly TimeSpan PingEvery = TimeSpan.FromSeconds(25);

    /// <summary>The largest frame the server takes (packages/pocketterm_server/PROTOCOL.md); a larger one would
    /// close the socket, and every message after it would be lost until the next join.</summary>
    public const int MaxFrameBytes = 256 * 1024;

    private readonly IServer _server;
    private readonly IReadOnlyDictionary<string, Action<JsonObject>> _handlers;
    private readonly ChannelSeal _seal;
    private readonly object _gate = new();

    private ILiveSocket? _ws;
    private bool _open;
    private bool _joined;
    private Timer? _retry;
    private Timer? _joinWait;
    private Timer? _ping;
    private int _unanswered;
    private TimeSpan _wait = FirstWait;
    private bool _unreachable;

    /// <summary>Bumped by <see cref="Open"/> and <see cref="Close"/>: a connection still on its way from before
    /// must not make a second one.</summary>
    private int _gen;

    /// <param name="onJoined">The channel joined (true), or stopped being joined (false).</param>
    /// <param name="onUnreachable"><see cref="Unreachable"/> changed.</param>
    public TerminalChannel(
        IServer server,
        string topic,
        IReadOnlyDictionary<string, Action<JsonObject>> handlers,
        ChannelKey key,
        string name,
        Action<bool>? onJoined = null,
        Action? onUnreachable = null)
    {
        _server = server;
        Topic = topic;
        _handlers = handlers;
        Name = name;
        OnJoined = onJoined;
        OnUnreachable = onUnreachable;
        _seal = new ChannelSeal(key, topic, name);
    }

    /// <summary>The topic joined: the computer's id.</summary>
    public string Topic { get; }

    /// <summary>Who this is, in the log.</summary>
    public string Name { get; }

    public Action<bool>? OnJoined { get; }

    public Action? OnUnreachable { get; }

    public bool Joined
    {
        get
        {
            lock (_gate) return _joined;
        }
    }

    /// <summary>How far the other side's clock is off this one's, while it's too far for its messages to be taken
    /// (<see cref="ChannelSeal.ClockOff"/>).</summary>
    public TimeSpan? ClockOff => _seal.ClockOff;

    /// <summary>The last try to connect got no connection to the server (offline, DNS, TLS, a timeout), as opposed
    /// to one still on its way; false again once a connection is made, and after <see cref="Close"/>.</summary>
    public bool Unreachable
    {
        get
        {
            lock (_gate) return _unreachable;
        }
    }

    public void Open()
    {
        int gen;
        lock (_gate)
        {
            if (_open) return;
            _open = true;
            gen = ++_gen;
            Log.Print($"PocketTerm: {Name}: open");
            _wait = FirstWait;
        }
        _ = Connect(gen);
    }

    public Task Close()
    {
        var events = new Events();
        lock (_gate)
        {
            if (!_open) return Task.CompletedTask;
            _open = false;
            _gen++;
            Log.Print($"PocketTerm: {Name}: close");
            _retry?.Dispose();
            _retry = null;
            _unreachable = false;
            Drop(events);
        }
        events.Fire();
        return Task.CompletedTask;
    }

    /// <summary>Connects again at once, on a new socket, with the wait between tries back at its shortest: the
    /// person asked (Retry), so whatever the last try ran into may be gone. Nothing while closed.</summary>
    public void Reconnect()
    {
        var events = new Events();
        int gen;
        lock (_gate)
        {
            if (!_open) return;
            gen = ++_gen;
            Log.Print($"PocketTerm: {Name}: reconnect");
            _retry?.Dispose();
            _retry = null;
            Drop(events);
            _wait = FirstWait;
            SetUnreachable(false, events);
        }
        events.Fire();
        _ = Connect(gen);
    }

    /// <summary>Drops <paramref name="event"/> if the channel isn't joined: whoever waits on an answer times out,
    /// and the other side catches up after the next join. A message too big for the server fails with a
    /// <see cref="TerminalException"/> and goes nowhere; the connection stays.</summary>
    public Task Send(string @event, JsonObject payload)
    {
        lock (_gate)
        {
            var ws = _ws;
            if (ws == null || !_joined) return Task.CompletedTask;
            // Sealed and sent under one lock: a receiver drops a seq below one it already took.
            var sealedPayload = _seal.Seal(@event, payload);
            // Sealed, it's all ASCII: its length is its size in bytes.
            var frame = DartJson.Encode(new JsonObject { ["t"] = "send", ["topic"] = Topic, ["event"] = @event, ["payload"] = sealedPayload });
            if (frame.Length > MaxFrameBytes)
            {
                Log.Print($"PocketTerm: {Name}: {@event} not sent: {frame.Length} bytes, over {MaxFrameBytes}");
                return Task.FromException(new TerminalException("That is too big to send in one go. Send it in smaller parts."));
            }
            ws.Add(frame);
            return Task.CompletedTask;
        }
    }

    private async Task Connect(int gen)
    {
        bool Stale() => !_open || gen != _gen;
        ILiveSocket ws;
        try
        {
            Log.Timing("socket connecting");
            ws = await _server.ConnectLive().ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Log.Timing("socket failed");
            var events = new Events();
            lock (_gate)
            {
                if (Stale()) return;
                SetUnreachable(true, events);
            }
            // Refused at the door: maybe the token stopped working.
            _ = _server.Recheck();
            events.Fire();
            Again(null, e.Message);
            return;
        }
        var opened = new Events();
        lock (_gate)
        {
            if (Stale())
            {
                _ = CloseQuietly(ws);
                return;
            }
            Log.Timing("socket open");
            SetUnreachable(false, opened);
            _ws = ws;
            ws.Add(DartJson.Encode(new JsonObject { ["t"] = "join", ["topic"] = Topic }));
            _joinWait = new Timer(_ => Again(ws, "no answer to the join"), null, Stuck, Timeout.InfiniteTimeSpan);
            _unanswered = 0;
            _ping = new Timer(_ => Ping(ws), null, PingEvery, PingEvery);
        }
        opened.Fire();
        _ = Listen(ws);
    }

    private void Ping(ILiveSocket ws)
    {
        lock (_gate)
        {
            if (!ReferenceEquals(ws, _ws)) return;
            if (_unanswered < 2)
            {
                _unanswered++;
                ws.Add(DartJson.Encode(new JsonObject { ["t"] = "ping" }));
                return;
            }
        }
        Again(ws, "no answer to the pings");
    }

    private async Task Listen(ILiveSocket ws)
    {
        try
        {
            await foreach (var data in ws.Frames.ReadAllAsync().ConfigureAwait(false)) Frame(ws, data);
        }
        catch (Exception)
        {
            // Errors end the stream as its end does.
        }
        Closed(ws);
    }

    private void Frame(ILiveSocket ws, string data)
    {
        var events = new Events();
        Action<JsonObject>? handler = null;
        JsonObject? wire = null;
        string? @event = null;
        string? again = null;
        lock (_gate)
        {
            if (!ReferenceEquals(ws, _ws)) return;
            if (DartJson.TryDecode(data) is not JsonObject frame) return;
            switch (frame.Str("t"))
            {
                case "joined" when frame.Str("topic") == Topic:
                    Log.Timing("joined");
                    _joinWait?.Dispose();
                    _joinWait = null;
                    _wait = FirstWait;
                    SetJoined(true, events);
                    break;
                case "msg" when frame.Str("topic") == Topic && frame.Str("event") is { } ev && frame.Obj("payload") is { } p:
                    if (_handlers.TryGetValue(ev, out var h))
                    {
                        handler = h;
                        wire = p;
                        @event = ev;
                    }
                    break;
                case "pong":
                    _unanswered = 0;
                    break;
                case "error" when frame.Str("error") is { } error:
                    Log.Print($"PocketTerm: {Name}: the server said {error}");
                    // Joined on the server no more (it restarted under us).
                    if (error == "not_joined") again = error;
                    break;
            }
        }
        events.Fire();
        if (again != null) Again(ws, again);
        if (handler == null) return;
        // Opened and handled on this connection's reader: in the order they came.
        try
        {
            if (_seal.Open(@event!, wire!) is { } message) handler(message);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: {Name}: {@event}: {e.Message}");
        }
    }

    private void Closed(ILiveSocket ws)
    {
        var events = new Events();
        lock (_gate)
        {
            if (!ReferenceEquals(ws, _ws)) return;
            if (ws.CloseCode == 4003)
            {
                Log.Print($"PocketTerm: {Name}: this device was signed out on the server");
                Drop(events);
            }
        }
        events.Fire();
        if (ws.CloseCode == 4003)
        {
            _ = _server.Refused();
            return;
        }
        Again(ws, $"closed{(ws.CloseCode == null ? "" : $" ({ws.CloseCode})")}");
    }

    /// <summary>Leaves the connection there is, if any. Under the lock.</summary>
    private void Drop(Events events)
    {
        _joinWait?.Dispose();
        _ping?.Dispose();
        _joinWait = _ping = null;
        SetJoined(false, events);
        var ws = _ws;
        _ws = null;
        if (ws != null) _ = CloseQuietly(ws);
    }

    private async Task CloseQuietly(ILiveSocket ws)
    {
        try
        {
            await ws.Close().ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: {Name}: {e.Message}");
        }
    }

    /// <summary><paramref name="ws"/> (null: none was made) is no good: a new one after a while.</summary>
    private void Again(ILiveSocket? ws, string why)
    {
        var events = new Events();
        lock (_gate)
        {
            if (!_open || _retry != null || !ReferenceEquals(ws, _ws)) return;
            Drop(events);
            var wait = _wait;
            _wait = _wait * 2 > MaxWait ? MaxWait : _wait * 2;
            Log.Print($"PocketTerm: {Name}: joining again in {(long)wait.TotalSeconds} s ({why})");
            var gen = _gen;
            _retry = new Timer(_ =>
            {
                lock (_gate)
                {
                    _retry?.Dispose();
                    _retry = null;
                    if (gen != _gen) return;
                }
                _ = Connect(gen);
            }, null, wait, Timeout.InfiniteTimeSpan);
        }
        events.Fire();
    }

    private void SetUnreachable(bool unreachable, Events events)
    {
        if (_unreachable == unreachable) return;
        _unreachable = unreachable;
        if (OnUnreachable is { } cb) events.Add(cb);
    }

    private void SetJoined(bool joined, Events events)
    {
        if (_joined == joined) return;
        _joined = joined;
        Log.Print($"PocketTerm: {Name}: {(joined ? "joined" : "not joined")}");
        if (OnJoined is { } cb) events.Add(() => cb(joined));
    }

    /// <summary>Callbacks gathered under the lock, called once it's let go (a callback may call back in).</summary>
    private sealed class Events
    {
        private List<Action>? _list;

        public void Add(Action a) => (_list ??= []).Add(a);

        public void Fire()
        {
            if (_list == null) return;
            foreach (var a in _list) a();
        }
    }
}
