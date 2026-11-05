using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>
/// The desktop side of Terminal from the phone (protocol: PocketTerm.Core's Live): the coding sessions
/// <see cref="LiveHub"/> knows and the terminals' windows (<see cref="Terminals"/>) go out on this computer's topic
/// on the server (its id), sealed with its channel key; what the phone asks for is done here, where the window's
/// terminal can do it. The terminals are polled only while a phone has said hello lately.
/// Threading: the channel's handlers run on its reader thread, the hub's events on whatever thread caused them and
/// the timers on pool threads. All mutable state is guarded by one lock (<c>_gate</c>), held only for the synchronous
/// stretches between awaits (what Dart ran without yielding) and never while calling into the hub or the terminals.
/// </summary>
public sealed partial class TerminalBridge
{
    private readonly IServer _server;
    private readonly string _desktopId;
    private readonly ChannelKey _key;
    private readonly Terminals _terms;
    private readonly LiveHub _hub;
    private readonly IDesktopHost _host;
    private readonly Func<Agent> _agent;
    private readonly Func<string> _app;
    private readonly Func<Placement> _placement;
    private readonly Func<IReadOnlyList<string>> _roots;
    private readonly Func<Task<IReadOnlyDictionary<Agent, AgentIntegration>>>? _agents;
    private readonly Func<IReadOnlyList<string>>? _ompProfiles;
    private readonly Action? _onPhone;
    private readonly TerminalChannel _ch;
    private readonly object _gate = new();

    private IReadOnlyDictionary<Agent, AgentIntegration>? _agentsNow;

    /// <summary>A phone that hasn't said hello for this long has left.</summary>
    private static readonly TimeSpan Gone = TimeSpan.FromSeconds(12);

    /// <summary>How often a watched window's screen is read; the window list every third time.</summary>
    private static readonly TimeSpan TickEvery = TimeSpan.FromMilliseconds(700);

    /// <summary>Live ops wait this long to go out together.</summary>
    private static readonly TimeSpan Batch = TimeSpan.FromMilliseconds(150);

    /// <summary>The server closes a socket on a frame over 256 KiB, and sealed and in base64 a message grows by a third
    /// (see ChunkJson): a full screen is cut to this much JSON, a state to <see cref="MaxStateJson"/>.</summary>
    private const int MaxScreenJson = 60000;
    private const int MaxStateJson = 150000;

    private Timer? _tick;
    private int _ticks;
    private bool _polling;
    private bool _subscribed;

    /// <summary>Each listening phone (its <c>from</c>): what it shows, when it last said hello.</summary>
    private readonly Dictionary<string, (string? Session, string? Window, DateTime Seen)> _phones = [];

    private IReadOnlyList<TermWindow> _windows = [];
    private string? _termError;
    private List<string>? _projects;
    private DateTime? _projectsAt;
    private IReadOnlyList<string> _projectsRoots = [];

    /// <summary>The installed terminals and how they stand, and where a new session opens (its label), as of
    /// <see cref="_statusesAt"/>.</summary>
    private IReadOnlyList<TermStatus> _statuses = [];
    private string? _opensIn;
    private DateTime? _statusesAt;

    /// <summary>The last state sent: without the sessions' seq and time, which change with every live op, and with
    /// them.</summary>
    private string? _sentState;
    private string? _sentClock;
    private DateTime _sentAt = DateTime.MinValue;
    private Timer? _stateSoon;

    /// <summary>A state that differs only in seq and time (live ops already carry those) goes out at most this often;
    /// phones use it to notice lost ops.</summary>
    private static readonly TimeSpan ClockEvery = TimeSpan.FromSeconds(4);

    /// <summary>Per watched window: the version and lines the phones have.</summary>
    private readonly Dictionary<string, (int V, List<string> Lines)> _screens = [];
    private readonly HashSet<string> _fullScreen = [];

    /// <summary>Ops waiting for the next batch, per session key (in arrival order).</summary>
    private readonly List<(string Key, string Epoch, List<LiveOp> Ops)> _pendingOps = [];
    private Timer? _flush;

    /// <summary>Asks (their ids) whose screen is being followed: plan reviews, and Claude Code's approvals, which its
    /// plugin can't see answered.</summary>
    private readonly HashSet<string> _followed = [];
    private volatile bool _stopped;

    /// <summary>How often a followed ask's screen is read: often while it opens, then now and then to follow its cursor
    /// and notice it go.</summary>
    private static readonly TimeSpan AskSoon = TimeSpan.FromMilliseconds(500);
    private const int AskOpening = 6;
    private static readonly TimeSpan AskEvery = TimeSpan.FromSeconds(3);

    /// <summary>Sessions whose screen is followed for pickers (/resume, /model …) after a slash command from the phone,
    /// and the pickers' ids so far.</summary>
    private readonly Dictionary<string, MenuWatch> _menus = [];
    private int _menuIds;

    /// <summary>A picker's screen is read this often for <see cref="MenuOpening"/> after the command or an answer, then
    /// <see cref="MenuEvery"/>, until nothing changed for <see cref="MenuIdle"/>.</summary>
    private static readonly TimeSpan MenuSoon = TimeSpan.FromMilliseconds(400);
    private static readonly TimeSpan MenuOpening = TimeSpan.FromSeconds(3);
    private static readonly TimeSpan MenuEvery = TimeSpan.FromMilliseconds(1500);
    private static readonly TimeSpan MenuIdle = TimeSpan.FromMinutes(2);

    /// <summary>Each session's Live Activity state as last seen and as last pushed; a change goes out once it has held
    /// for <see cref="ActivityWait"/>, so a quick busy flicker between turns stays home.</summary>
    private readonly Dictionary<string, ActivityStatus> _activitySeen = [];
    private readonly Dictionary<string, ActivityStatus> _activitySent = [];
    private readonly Dictionary<string, Timer> _activitySoon = [];
    private static readonly TimeSpan ActivityWait = TimeSpan.FromSeconds(2);

    /// <summary>How much of a queued prompt's text a state too big for it keeps.</summary>
    private const int QueuedStart = 200;

    /// <summary>How often Settings-like statuses are read again while phones listen.</summary>
    private static readonly TimeSpan StatusEvery = TimeSpan.FromSeconds(30);

    /// <summary>The phones' requests of the last minutes, by id.</summary>
    private readonly RunLog _runs = new();

    private bool _askingAgents;

    /// <summary>What the windows (and the sessions' windows) were at the last relink.</summary>
    private string? _relinkedFor;

    /// <summary>An orchestrator launch still going: another <c>orchestrator</c> op meanwhile (Send again, a second
    /// phone) gets it.</summary>
    private Task<string>? _orchestratorStart;

    /// <param name="server">Where this computer is signed in.</param>
    /// <param name="desktopId">This computer, among the user's.</param>
    /// <param name="key">This computer's channel key.</param>
    /// <param name="terms">The terminals.</param>
    /// <param name="hub">The coding sessions.</param>
    /// <param name="host">Keeps this computer awake while the bridge runs.</param>
    /// <param name="agent">The agent a new session from the phone starts (this computer's setting).</param>
    /// <param name="app">The terminal app it opens in: an app's id or <c>auto</c> (this computer's setting).</param>
    /// <param name="roots">This computer's Project folders setting.</param>
    /// <param name="agents">Where PocketTerm stands in each coding agent found here (this computer's checks, which keep
    /// themselves fresh); none told if null.</param>
    /// <param name="ompProfiles">This computer's omp profiles besides the default.</param>
    /// <param name="placement">Whether a new session is a tab in the project's window or a window of its own (this
    /// computer's setting); the project's window if null.</param>
    /// <param name="onPhone">A phone said hello: one is signed in to this account.</param>
    public TerminalBridge(
        IServer server,
        string desktopId,
        ChannelKey key,
        Terminals terms,
        LiveHub hub,
        IDesktopHost host,
        Func<Agent> agent,
        Func<string> app,
        Func<IReadOnlyList<string>> roots,
        Func<Task<IReadOnlyDictionary<Agent, AgentIntegration>>>? agents = null,
        Func<IReadOnlyList<string>>? ompProfiles = null,
        Func<Placement>? placement = null,
        Action? onPhone = null)
    {
        _server = server;
        _desktopId = desktopId;
        _key = key;
        _terms = terms;
        _hub = hub;
        _host = host;
        _agent = agent;
        _app = app;
        _roots = roots;
        _agents = agents;
        _ompProfiles = ompProfiles;
        _placement = placement ?? (() => Placement.ProjectWindow);
        _onPhone = onPhone;
        _ch = new TerminalChannel(
            server,
            desktopId,
            new Dictionary<string, Action<JsonObject>>
            {
                ["hello"] = OnHello,
                ["sync"] = OnSync,
                ["run"] = m => _ = OnRunAsync(m),
            },
            key,
            "terminal bridge");
    }

    /// <summary>Phones show this session now (said so within 12 s).</summary>
    public bool Watching(string sessionKey)
    {
        lock (_gate) return _phones.Values.Any(p => p.Session == sessionKey);
    }

    /// <summary>How far a phone's clock is off this computer's while it's too far for anything from it to be taken
    /// (more than 5 minutes); null otherwise.</summary>
    public TimeSpan? ClockOff => _ch.ClockOff;

    public async Task StartAsync()
    {
        _stopped = false;
        _ch.Open();
        lock (_gate)
        {
            if (!_subscribed)
            {
                _subscribed = true;
                _hub.Ops += OnOps;
                _hub.Changes += OnHubChanged;
                _hub.Events += OnHubEvent;
            }
        }
        // Away from the computer, an idle sleep would end the bridge; the lid still sleeps it.
        await _host.SetKeepAwakeAsync(true).ConfigureAwait(false);
    }

    public async Task StopAsync()
    {
        _stopped = true;
        List<MenuWatch> menus;
        lock (_gate)
        {
            menus = [.. _menus.Values];
            if (_subscribed)
            {
                _subscribed = false;
                _hub.Ops -= OnOps;
                _hub.Changes -= OnHubChanged;
                _hub.Events -= OnHubEvent;
            }
            _tick?.Dispose();
            _tick = null;
            _flush?.Dispose();
            _flush = null;
            _stateSoon?.Dispose();
            _stateSoon = null;
            foreach (var t in _activitySoon.Values) t.Dispose();
            _activitySoon.Clear();
        }
        foreach (var w in menus) w.Wake();
        await _host.SetKeepAwakeAsync(false).ConfigureAwait(false);
        lock (_gate) _phones.Clear();
        await _ch.Close().ConfigureAwait(false);
    }

    private void OnHubChanged()
    {
        StateChanged();
        ActivitiesChanged();
    }

    private void OnHubEvent(LiveEvent e)
    {
        if (e is LiveAsked asked && (asked.Ask.IsPlan || (asked.Ask.IsApproval && asked.Session.Agent == Agent.Claude)))
        {
            _ = FollowAskAsync(asked.Session.Key, asked.Ask.Id);
        }
    }

    private void Send(string @event, JsonObject payload)
    {
        Task sent;
        try
        {
            sent = _ch.Send(@event, payload);
        }
        catch (Exception e)
        {
            sent = Task.FromException(e);
        }
        sent.ContinueWith(
            t => Log.Print($"PocketTerm: terminal bridge: {Describe(t.Exception!.InnerException!)}"),
            CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    /// <summary>An exception as Dart's <c>'$e'</c> printed it: ours carry their message.</summary>
    private static string Describe(Exception e) => e is TerminalException or LiveException ? e.Message : e.ToString();

    // ------------------------------------------------------------ phones

    private void OnHello(JsonObject p)
    {
        var from = p.Str("from");
        if (from == null) return;
        var window = p.Str("window");
        bool first;
        lock (_gate)
        {
            first = !_phones.TryGetValue(from, out var before);
            _phones[from] = (p.Str("session"), window, DateTime.UtcNow);
            // Every hello gets the state: it's how the phone knows the computer is there.
            _sentState = null;
            if (window != null && (first || before.Window != window)) _fullScreen.Add(window);
            _tick ??= new Timer(_ => _ = PollAsync(), null, TickEvery, TickEvery);
        }
        if (first) _onPhone?.Invoke();
        _ = PollAsync(windows: true);
    }

    private void OnSync(JsonObject p)
    {
        var from = p.Str("from");
        if (from == null) return;
        var window = p.Str("window");
        if (window != null)
        {
            lock (_gate) _fullScreen.Add(window);
            _ = PollAsync();
            return;
        }
        var key = p.Str("session");
        var s = key == null ? null : _hub[key];
        if (s == null) return;
        // Pending ops would arrive after this answer, which covers them already.
        FlushNow();
        var log = s.Log;
        var since = p.Int("since") ?? 0;
        var reset = p.Str("epoch") != log.Epoch || since > log.Seq || since <= 0;
        var items = reset ? log.Items : log.Since(since);
        var chunks = Live.ChunkJson(items.Select(i => i.ToJson()));
        for (var n = 0; n < chunks.Count; n++)
        {
            Send("items", new JsonObject
            {
                ["to"] = from,
                ["session"] = key,
                ["epoch"] = log.Epoch,
                ["seq"] = log.Seq,
                ["reset"] = reset,
                ["items"] = new JsonArray([.. chunks[n]]),
                ["last"] = n == chunks.Count - 1,
                ["older"] = log.Older,
            });
        }
    }

    // ------------------------------------------------------------ live sessions

    private void OnOps((LiveSession Session, List<LiveOp> Ops) change)
    {
        var (s, ops) = change;
        if (!Watching(s.Key)) return;
        var epoch = s.Log.Epoch;
        var flushFirst = false;
        lock (_gate)
        {
            var i = _pendingOps.FindIndex(x => x.Key == s.Key);
            if (i >= 0 && _pendingOps[i].Epoch == epoch)
            {
                _pendingOps[i].Ops.AddRange(ops);
                _flush ??= new Timer(_ => FlushNow(), null, Batch, Timeout.InfiniteTimeSpan);
                return;
            }
            flushFirst = i >= 0;
        }
        if (flushFirst) FlushNow();
        lock (_gate)
        {
            _pendingOps.Add((s.Key, epoch, [.. ops]));
            _flush ??= new Timer(_ => FlushNow(), null, Batch, Timeout.InfiniteTimeSpan);
        }
    }

    private void FlushNow()
    {
        List<(string Key, string Epoch, List<LiveOp> Ops)> pending;
        lock (_gate)
        {
            _flush?.Dispose();
            _flush = null;
            pending = [.. _pendingOps];
            _pendingOps.Clear();
        }
        foreach (var (key, epoch, ops) in pending)
        {
            foreach (var chunk in Live.ChunkJson(ops.Select(op => op.ToJson())))
            {
                Send("live", new JsonObject { ["session"] = key, ["epoch"] = epoch, ["ops"] = new JsonArray([.. chunk]) });
            }
        }
    }

    private void StateChanged()
    {
        lock (_gate)
        {
            if (_phones.Count == 0) return;
            _stateSoon ??= new Timer(
                _ =>
                {
                    lock (_gate)
                    {
                        _stateSoon?.Dispose();
                        _stateSoon = null;
                    }
                    SendState();
                },
                null,
                TimeSpan.FromMilliseconds(200),
                Timeout.InfiniteTimeSpan);
        }
    }

    // ------------------------------------------------------------ Live Activities

    /// <summary>A session started or stopped working, asks or stopped asking, or went: the phones following it hear
    /// about it through the server (POST /v1/push/activity, <see cref="ActivityPush"/>), which does nothing for a
    /// session no phone follows. A session seen for the first time pushes nothing: no phone can follow it yet.</summary>
    private void ActivitiesChanged()
    {
        var sessions = _hub.Sessions.ToList();
        var keys = sessions.Select(s => s.Key).ToHashSet();
        lock (_gate)
        {
            foreach (var s in sessions)
            {
                var status = LiveActivity.Status(s.Busy, s.Ask);
                var known = _activitySeen.TryGetValue(s.Key, out var seen);
                _activitySeen[s.Key] = status;
                if (!known)
                {
                    _activitySent.TryAdd(s.Key, status);
                }
                else if (seen != status)
                {
                    PushSoon(s.Key);
                }
            }
            foreach (var key in _activitySeen.Keys.Where(k => !keys.Contains(k)).ToList())
            {
                if (_activitySeen[key].State == ActivityState.Ended) continue;
                _activitySeen[key] = new(ActivityState.Ended, null);
                PushSoon(key);
            }
        }
    }

    /// <summary>Under <c>_gate</c>.</summary>
    private void PushSoon(string key)
    {
        if (_activitySoon.TryGetValue(key, out var old)) old.Dispose();
        _activitySoon[key] = new Timer(_ => PushActivity(key), null, ActivityWait, Timeout.InfiniteTimeSpan);
    }

    private void PushActivity(string key)
    {
        ActivityStatus status;
        lock (_gate)
        {
            if (_activitySoon.Remove(key, out var t)) t.Dispose();
            if (!_activitySeen.TryGetValue(key, out status)) return;
            if (_activitySent.TryGetValue(key, out var sent) && sent == status) return;
            _activitySent[key] = status;
            if (status.State == ActivityState.Ended)
            {
                _activitySeen.Remove(key);
                _activitySent.Remove(key);
            }
        }
        _ = Task.Run(async () =>
        {
            try
            {
                await _server.Push("activity", ActivityPush(_key, _desktopId, key, status)).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                Log.Print($"PocketTerm: Live Activity push: {Describe(e)}");
            }
        });
    }

    /// <summary>What goes to POST /v1/push/activity for coding session <paramref name="key"/> now at
    /// <paramref name="status"/>: its routed key (for the server to find the phones following it; it never reaches
    /// the relay), state and kind in the clear for iPhones' Live Activities (Apple can't open anything sealed), and
    /// the same sealed with this computer's <paramref name="channelKey"/> as <c>enc</c>, the only thing Android phones
    /// get, with this computer's push tag to find the key by.</summary>
    public static JsonObject ActivityPush(ChannelKey channelKey, string desktopId, string key, ActivityStatus status)
    {
        var session = Live.RoutedKey(desktopId, key);
        var body = new JsonObject { ["session"] = session };
        var inner = new JsonObject { ["session"] = session };
        foreach (var (k, v) in LiveActivity.ToJson(status))
        {
            body[k] = v?.DeepClone();
            inner[k] = v?.DeepClone();
        }
        inner["since"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        body["tag"] = E2e.PushTag(channelKey);
        body["enc"] = E2e.SealActivity(channelKey, desktopId, inner);
        return body;
    }

    private void SendState()
    {
        var sessions = _hub.Sessions.Select(s => s.Summary.ToJson()).ToList();
        var roots = _roots();
        var agent = _agent().Name();
        var placement = _placement().Name();
        var profiles = _ompProfiles?.Invoke();
        JsonObject state;
        lock (_gate)
        {
            state = new JsonObject
            {
                ["windows"] = new JsonArray([.. _windows.Select(w => (JsonNode)w.ToJson())]),
                ["sessions"] = new JsonArray([.. sessions]),
                ["projects"] = _projects == null ? null : new JsonArray([.. _projects.Select(p => (JsonNode)p)]),
                ["roots"] = new JsonArray([.. roots.Select(r => (JsonNode)r)]),
                ["home"] = _terms.Home,
                ["agent"] = agent,
            };
            state.PutIfNotNull("opensIn", _opensIn);
            state["placement"] = placement;
            state["terminals"] = new JsonArray([.. BridgeHelpers.PhoneTerminals(_statuses).Select(s => (JsonNode)s.ToJson())]);
            state.PutIfNotNull("error", _termError);
            if (_agentsNow is { } a) state["agents"] = AgentIntegrations.ToJsonAll(a);
            if (profiles is { Count: > 0 } p) state["profiles"] = new JsonArray([.. p.Select(x => (JsonNode)x)]);
            var watched = _phones.Values.Select(v => v.Session).OfType<string>().ToHashSet();
            state = FitState(state, watched);
            var shown = state["sessions"]!.AsArray().OfType<JsonObject>().ToList();
            var keyed = (JsonObject)state.DeepClone();
            keyed["sessions"] = new JsonArray([.. shown.Select(s =>
            {
                var c = (JsonObject)s.DeepClone();
                c["seq"] = null;
                c["at"] = null;
                return (JsonNode)c;
            })]);
            var key = DartJson.Encode(keyed);
            var clock = DartJson.Encode(new JsonArray([.. shown.Select(s =>
                (JsonNode)$"({DartJson.Encode(s["seq"])}, {DartJson.Encode(s["at"])})")]));
            var now = DateTime.UtcNow;
            if (key == _sentState && (clock == _sentClock || now - _sentAt < ClockEvery)) return;
            _sentState = key;
            _sentClock = clock;
            _sentAt = now;
        }
        Send("state", state);
    }

    /// <summary>
    /// <paramref name="state"/> cut to at most <paramref name="maxBytes"/> of JSON, least needed first: the slash
    /// commands of the sessions no phone shows (<paramref name="watched"/>: the ones phones show), the queued prompts
    /// of those sessions to their start, the repositories in the Project folders that don't fit, every command's
    /// description, every session's commands, every queued prompt to its start, then windows from the end of the
    /// list. Many coding sessions (each with its agent's whole list of commands) or a Project folder with thousands
    /// of repositories would otherwise make a state the server can't take. A state that fits is returned as it is.
    /// </summary>
    public static JsonObject FitState(JsonObject state, IReadOnlySet<string> watched, int maxBytes = MaxStateJson)
    {
        static int Size(JsonNode? json) => DartJson.EncodeUtf8(json).Length;
        var text = DartJson.Encode(state);
        // UTF-8 takes at most three bytes per UTF-16 unit: most states are measured without encoding them.
        if (text.Length * 3 <= maxBytes) return state;
        var total = System.Text.Encoding.UTF8.GetByteCount(text);
        if (total <= maxBytes) return state;
        var output = (JsonObject)state.DeepClone();
        List<JsonObject> Sessions() => output["sessions"]!.AsArray().OfType<JsonObject>().ToList();

        void Cmds(Func<JsonObject, JsonArray, JsonNode?> keep)
        {
            var next = new JsonArray();
            foreach (var s in Sessions())
            {
                if (s["cmds"] is JsonArray c)
                {
                    var o = new JsonObject();
                    foreach (var (k, v) in s)
                    {
                        if (k != "cmds") o[k] = v?.DeepClone();
                    }
                    o.PutIfNotNull("cmds", keep(s, c));
                    next.Add(o);
                }
                else
                {
                    next.Add(s.DeepClone());
                }
            }
            output["sessions"] = next;
            total = Size(output);
        }

        Cmds((s, c) => DartJson.AsString(s["key"]) is { } k && watched.Contains(k) ? c.DeepClone() : null);

        // A queued prompt cut to its start: the phone shows it, but doesn't offer to edit it.
        void Queues(Func<JsonObject, bool> which)
        {
            if (total <= maxBytes) return;
            var next = new JsonArray();
            foreach (var s in Sessions())
            {
                var o = (JsonObject)s.DeepClone();
                if (o["queue"] is JsonArray queue && which(s))
                {
                    foreach (var q in queue.OfType<JsonObject>())
                    {
                        if (DartJson.AsString(q["t"]) is { } t && t.Length > QueuedStart)
                        {
                            q["t"] = $"{t[..QueuedStart]}…";
                            q["c"] = true;
                        }
                    }
                }
                next.Add(o);
            }
            output["sessions"] = next;
            total = Size(output);
        }

        bool Watched(JsonObject s) => DartJson.AsString(s["key"]) is { } k && watched.Contains(k);

        Queues(s => !Watched(s));
        if (output["projects"] is JsonArray projects && total > maxBytes)
        {
            var room = maxBytes - (total - Size(projects));
            var kept = new JsonArray();
            foreach (var p in projects)
            {
                if ((room -= Size(p) + 1) >= 0) kept.Add(p?.DeepClone());
            }
            output["projects"] = kept;
            total = Size(output);
        }
        if (total > maxBytes)
        {
            Cmds((s, c) => new JsonArray([.. c.OfType<JsonArray>().Where(cmd => cmd.Count > 0).Select(cmd => (JsonNode)new JsonArray(cmd[0]?.DeepClone()))]));
        }
        if (total > maxBytes) Cmds((s, c) => null);
        Queues(s => true);
        if (total > maxBytes)
        {
            var windows = output["windows"]!.AsArray().Select(w => w?.DeepClone()).ToList();
            while (total > maxBytes && windows.Count > 0)
            {
                total -= Size(windows[^1]) + 1;
                windows.RemoveAt(windows.Count - 1);
            }
            output["windows"] = new JsonArray([.. windows]);
        }
        return output;
    }

    /// <summary>Where the agents stand, in the background (it may run <c>claude</c>); a change goes out with the next
    /// state.</summary>
    private void AskAgents()
    {
        var ask = _agents;
        lock (_gate)
        {
            if (ask == null || _askingAgents) return;
            _askingAgents = true;
        }
        _ = Task.Run(async () =>
        {
            try
            {
                var a = await ask().ConfigureAwait(false);
                bool changed;
                lock (_gate)
                {
                    changed = !_stopped && !SameAgents(a, _agentsNow);
                    if (changed) _agentsNow = a;
                }
                if (changed) StateChanged();
            }
            catch (Exception e)
            {
                Log.Print($"PocketTerm: coding agents: {Describe(e)}");
            }
            finally
            {
                lock (_gate) _askingAgents = false;
            }
        });
    }

    private static bool SameAgents(IReadOnlyDictionary<Agent, AgentIntegration> a, IReadOnlyDictionary<Agent, AgentIntegration>? b) =>
        b != null && a.Count == b.Count && a.All(e => b.TryGetValue(e.Key, out var v) && v == e.Value);

    // ------------------------------------------------------------ terminals

    private async Task PollAsync(bool windows = false)
    {
        lock (_gate)
        {
            if (_polling) return;
            _polling = true;
        }
        try
        {
            var now = DateTime.UtcNow;
            bool list;
            lock (_gate)
            {
                foreach (var gone in _phones.Where(v => now - v.Value.Seen > Gone).Select(v => v.Key).ToList()) _phones.Remove(gone);
                if (_phones.Count == 0)
                {
                    _tick?.Dispose();
                    _tick = null;
                    _screens.Clear();
                    return;
                }
                list = windows || _ticks++ % 3 == 0;
            }
            if (list)
            {
                var found = await _terms.WindowsAsync().ConfigureAwait(false);
                lock (_gate) _windows = found;
                Relink();
                bool statuses;
                lock (_gate) statuses = windows || _statusesAt == null || now - _statusesAt.Value > StatusEvery;
                if (statuses)
                {
                    lock (_gate) _statusesAt = now;
                    var got = await _terms.StatusesAsync().ConfigureAwait(false);
                    var opensIn = _terms.Describe(await _terms.OpensInAsync(_app()).ConfigureAwait(false));
                    lock (_gate)
                    {
                        _statuses = got;
                        _opensIn = opensIn;
                    }
                }
                var noSessions = !_hub.Sessions.Any();
                lock (_gate) _termError = BridgeHelpers.TerminalsError(_statuses, nothingShown: _windows.Count == 0 && noSessions);
                AskAgents();
                var roots = _roots();
                bool scan;
                lock (_gate)
                {
                    scan = _projectsAt == null || !roots.SequenceEqual(_projectsRoots) || now - _projectsAt.Value > TimeSpan.FromMinutes(5);
                    if (scan)
                    {
                        _projectsAt = now;
                        _projectsRoots = roots;
                    }
                }
                if (scan) _ = ScanProjectsAsync(roots);
            }
            SendState();
            List<string> watched;
            lock (_gate)
            {
                watched = _phones.Values.Select(v => v.Window).OfType<string>().Distinct().ToList();
                foreach (var k in _screens.Keys.Where(k => !watched.Contains(k)).ToList()) _screens.Remove(k);
            }
            foreach (var w in watched)
            {
                TermWindow? shown;
                lock (_gate) shown = _windows.FirstOrDefault(x => x.Key == w);
                if (shown == null || !shown.Can(TermCap.Read)) continue;
                try
                {
                    await SendScreenAsync(w).ConfigureAwait(false);
                }
                catch (TerminalException e)
                {
                    Log.Print($"PocketTerm: terminal screen {w}: {e.Message}");
                }
            }
        }
        catch (Exception e)
        {
            // Dart's unawaited poll would surface this as an uncaught error; here it's logged, not lost.
            Log.Print($"PocketTerm: terminal bridge: {Describe(e)}");
        }
        finally
        {
            lock (_gate) _polling = false;
        }
    }

    private async Task ScanProjectsAsync(IReadOnlyList<string> roots)
    {
        try
        {
            var p = await _terms.ProjectsAsync(roots).ConfigureAwait(false);
            lock (_gate)
            {
                // A scan of folders since changed (a slow one, of ~ say) is stale.
                if (!roots.SequenceEqual(_projectsRoots)) return;
                _projects = p;
            }
            StateChanged();
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: terminal bridge: {Describe(e)}");
        }
    }

    /// <summary>Sessions without a window look for one again once the windows change (a window's title follows its
    /// session's).</summary>
    private void Relink()
    {
        var sessions = _hub.Sessions.ToList();
        if (sessions.All(s => s.Window != null)) return;
        lock (_gate)
        {
            var now = string.Join("\n", _windows.Select(w => $"{w.Key}\t{w.Title}\t{w.Cwd}").Concat(sessions.Select(s => s.Window).OfType<string>()));
            if (now == _relinkedFor) return;
            _relinkedFor = now;
        }
        _ = _hub.RelinkAsync().ContinueWith(
            t => Log.Print($"PocketTerm: terminal bridge: {Describe(t.Exception!.InnerException!)}"),
            CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted,
            TaskScheduler.Default);
    }

    private async Task SendScreenAsync(string window)
    {
        var lines = FitLines(await _terms.LinesAsync(window, history: true).ConfigureAwait(false), MaxScreenJson);
        (int V, List<string> Lines)? before;
        bool full;
        int v;
        lock (_gate)
        {
            before = _screens.TryGetValue(window, out var b) ? b : null;
            full = before == null | _fullScreen.Remove(window);
            if (!full && before!.Value.Lines.SequenceEqual(lines)) return;
            v = (before?.V ?? 0) + 1;
            _screens[window] = (v, lines);
        }
        var diff = full ? null : ScreenDiff.Between(before!.Value.Lines, lines);
        if (diff != null)
        {
            Send("screen", new JsonObject { ["window"] = window, ["v"] = v, ["diff"] = diff.ToJson() });
            return;
        }
        var payload = new JsonObject
        {
            ["window"] = window,
            ["v"] = v,
            ["lines"] = new JsonArray([.. lines.Select(l => (JsonNode)l)]),
        };
        if (before == null && await _terms.ColorsAsync(window).ConfigureAwait(false) is { } colors)
        {
            payload["colors"] = JsonSerializer.SerializeToNode(colors);
        }
        Send("screen", payload);
    }

    /// <summary>The newest of <paramref name="lines"/> that take at most <paramref name="maxBytes"/> as JSON (one line
    /// at least, itself cut to fit): what a screen sends whole. Its diffs are made between these too, so they're never
    /// larger.</summary>
    public static List<string> FitLines(IReadOnlyList<string> lines, int maxBytes)
    {
        var size = 2;
        var from = lines.Count;
        while (from > 0)
        {
            var next = size + Live.JsonBytes(lines[from - 1]) + 3;
            if (next > maxBytes) break;
            size = next;
            from--;
        }
        if (from == lines.Count && lines.Count > 0)
        {
            // One line longer than all of it: its start, which is what a terminal shows of it.
            var last = lines[^1];
            var end = last.Length;
            while (end > 0 && Live.JsonBytes(last[..end]) + 5 > maxBytes) end = end * 3 / 4;
            return [last[..end]];
        }
        return from == 0 ? [.. lines] : lines.Skip(from).ToList();
    }

    // ------------------------------------------------------------ requests

    private static string Req(JsonObject p, string key) =>
        p.Str(key) ?? throw new InvalidCastException($"type 'Null' is not a subtype of type 'String' in type cast ({key})");

    private async Task OnRunAsync(JsonObject p)
    {
        var id = p.Str("id");
        if (id == null || !_runs.Start(id, ran => Send("ran", ran))) return;
        string? error = null;
        string? window = null;
        string? where = null;
        bool? busy = null;
        string? queued = null;
        var op = p.Str("op");
        try
        {
            switch (op)
            {
                case "send":
                    await _terms.SendAsync(Req(p, "window"), p.Str("text") ?? "", enter: p.Bool("enter") != false).ConfigureAwait(false);
                    break;
                case "key":
                    var pressed = Req(p, "window");
                    await _terms.PressAsync(pressed, Req(p, "key")).ConfigureAwait(false);
                    // Esc on a picker, say: see it go soon.
                    foreach (var s in _hub.Sessions)
                    {
                        if (s.Window != pressed) continue;
                        MenuWatch? w;
                        lock (_gate) _menus.TryGetValue(s.Key, out w);
                        w?.Arm();
                    }
                    break;
                case "close":
                    await _terms.CloseAsync(Req(p, "window")).ConfigureAwait(false);
                    break;
                case "probe":
                    busy = await BridgeHelpers.ScreenChangesAsync(_terms, Req(p, "window")).ConfigureAwait(false);
                    break;
                case "switch":
                {
                    var at = Req(p, "window");
                    var agent = DartEnum.Parse<Agent>(p["agent"]) ?? throw new TerminalException("Unknown coding agent.");
                    // As the windows are now: it may have closed since the phone's list.
                    var shown = (await _terms.WindowsAsync().ConfigureAwait(false)).FirstOrDefault(w => w.Key == at)
                        ?? throw new TerminalException("That window has closed.");
                    // Typed into a shell: only a profile this computer has (else the default's conversation).
                    var known = _ompProfiles?.Invoke() ?? [];
                    var profile = known.Contains(shown.Profile) ? shown.Profile : "";
                    await BridgeHelpers.SwitchToConversationAsync(_terms, at, agent, tty: shown.Tty, profile: profile).ConfigureAwait(false);
                    break;
                }
                case "launch":
                {
                    // An older phone says `omp` for "start the coding agent".
                    var start = p.Bool("agent") == true || p.Bool("omp") == true;
                    var host = await _terms.OpensInAsync(_app()).ConfigureAwait(false);
                    Agent? agent = start ? _agent() : null;
                    var opened = await _terms.LaunchAsync(
                        Req(p, "cwd"),
                        host,
                        agent: agent,
                        placement: _placement(),
                        profile: agent is { } a ? BridgeHelpers.LaunchProfile(p["profile"], a, _ompProfiles?.Invoke() ?? []) : "").ConfigureAwait(false);
                    (window, where) = (opened.Window, opened.Where);
                    break;
                }
                case "create":
                {
                    Agent? agent = p.Bool("agent") == true ? _agent() : null;
                    var root = Req(p, "root");
                    var name = p.Str("name") ?? "";
                    var roots = _roots();
                    var host = await _terms.OpensInAsync(_app()).ConfigureAwait(false);
                    var opened = await _terms.LaunchNewProjectAsync(
                        root,
                        name,
                        roots,
                        host,
                        agent: agent,
                        profile: agent is { } a ? BridgeHelpers.LaunchProfile(p["profile"], a, _ompProfiles?.Invoke() ?? []) : "").ConfigureAwait(false);
                    (window, where) = (opened.Window, opened.Where);
                    break;
                }
                case "prompt":
                    queued = await PromptAsync(p).ConfigureAwait(false);
                    break;
                case "queue":
                    await QueueAsync(p).ConfigureAwait(false);
                    break;
                case "abort":
                    await _hub.AbortAsync(Req(p, "session")).ConfigureAwait(false);
                    break;
                case "answer":
                    await AnswerAsync(p).ConfigureAwait(false);
                    break;
                case "older":
                    await _hub.OlderAsync(Req(p, "session")).ConfigureAwait(false);
                    break;
                case "orchestrator":
                    window = await OrchestratorAsync().ConfigureAwait(false);
                    break;
                default:
                    error = "Unknown request.";
                    break;
            }
        }
        catch (TerminalException e)
        {
            error = e.Message;
        }
        catch (LiveException e)
        {
            error = e.Message;
        }
        catch (Exception e)
        {
            error = $"The computer could not do that: {e.Message}";
        }
        var ran = new JsonObject { ["id"] = id };
        ran.PutIfNotNull("error", error);
        ran.PutIfNotNull("window", window);
        ran.PutIfNotNull("where", where);
        ran.PutIfNotNull("busy", busy);
        ran.PutIfNotNull("queued", queued);
        _runs.Done(id, ran);
        Send("ran", ran);
        _ = PollAsync(windows: op is "launch" or "create" or "close" or "switch" or "orchestrator");
    }

    /// <summary>The phone's prompt, with its images and files fetched from Storage (and deleted): the id it waits under
    /// in the session's queue, if it waits there.</summary>
    private async Task<string?> PromptAsync(JsonObject p)
    {
        // The agent's own commands (/resume, /model …) are read by its editor, not the model: type them into its
        // window like the person would, and follow the pickers they open.
        var text = (p.Str("text") ?? "").DartTrim();
        var key = Req(p, "session");
        var window = _hub[key]?.Window;
        var paths = (p.Arr("images") ?? []).Select(n => DartJson.AsString(n) ?? throw new InvalidCastException("type is not a subtype of type 'String'")).ToList();
        var files = new List<(string Path, string Name, string Mime)>();
        foreach (var f in p.Arr("files") ?? [])
        {
            if (f is JsonObject o && o.Str("path") is { } path && o.Str("name") is { } name)
            {
                files.Add((path, name, o.Str("mime") ?? ""));
            }
            else
            {
                throw new LiveException("Bad file.");
            }
        }
        var blobs = paths.Concat(files.Select(f => f.Path)).ToList();
        if (text.StartsWith('/') && blobs.Count == 0)
        {
            // Sent as a prompt instead, the agent would take it for chat.
            if (BridgeHelpers.CantCommand(_terms, window) is { } why) throw new LiveException(why);
            await _terms.SendAsync(window!, text, enter: true).ConfigureAwait(false);
            _ = FollowMenusAsync(key);
            return null;
        }
        foreach (var path in blobs)
        {
            if (!Server.IsBlobPath(path)) throw new LiveException("Bad image or file path.");
        }
        try
        {
            var images = new List<(byte[] Bytes, string MimeType)>();
            foreach (var path in paths)
            {
                images.Add(await ImageAsync(OpenBlob(_key, path, await _server.GetBlob(path).ConfigureAwait(false))).ConfigureAwait(false));
            }
            var opened = new List<PromptFile>();
            foreach (var f in files)
            {
                opened.Add(new PromptFile(f.Name, f.Mime, OpenBlob(_key, f.Path, await _server.GetBlob(f.Path).ConfigureAwait(false))));
            }
            return await _hub.PromptAsync(
                key,
                p.Str("text") ?? "",
                images: images,
                files: opened,
                followUp: p.Str("deliver") == "followUp",
                id: p.Str("id")).ConfigureAwait(false);
        }
        finally
        {
            // The server drops one once it's downloaded; one that didn't come down goes too.
            foreach (var path in blobs)
            {
                _ = _server.DeleteBlob(path).ContinueWith(
                    t => Log.Print($"PocketTerm: blob cleanup: {Describe(t.Exception!.InnerException!)}"),
                    CancellationToken.None,
                    TaskContinuationOptions.OnlyOnFaulted,
                    TaskScheduler.Default);
            }
        }
    }

    /// <summary>The phone's change to a session's queue (LiveHub).</summary>
    private async Task QueueAsync(JsonObject p)
    {
        var key = Req(p, "session");
        var item = p.Str("item") ?? "";
        switch (p.Str("do"))
        {
            case "edit":
                _hub.EditQueued(key, item, p.Str("text") ?? "");
                break;
            case "remove":
                _hub.RemoveQueued(key, item);
                break;
            case "move":
                _hub.MoveQueued(key, item, (int)(p.Num("to") ?? 0));
                break;
            case "send":
                await _hub.SendQueuedNowAsync(key, item).ConfigureAwait(false);
                break;
            case "pause":
                _hub.PauseQueue(key, paused: true);
                break;
            case "resume":
                _hub.PauseQueue(key, paused: false);
                break;
            default:
                throw new LiveException("Unknown change to the queue.");
        }
    }

    /// <summary>A phone's image or file as stored at <paramref name="path"/>, opened with <paramref name="key"/> (the
    /// phone sealed it for that path).</summary>
    public static byte[] OpenBlob(ChannelKey key, string path, byte[] sealedBytes) =>
        E2e.OpenBytes(key, sealedBytes, E2e.ImageAad(path))
        ?? throw new LiveException("The image or file didn't open: it wasn't sealed with this computer's key.");

    /// <summary>PNG and JPEG go as they are; on a Mac anything else (HEIC from Photos) becomes PNG first, which every
    /// model reads. Elsewhere (no <c>sips</c>) only PNG and JPEG do; the phone sends JPEG anyway.</summary>
    public static async Task<(byte[] Bytes, string MimeType)> ImageAsync(byte[] bytes, bool? macos = null)
    {
        bool Starts(byte[] magic) => bytes.Length > magic.Length && bytes.AsSpan(0, magic.Length).SequenceEqual(magic);
        if (Starts([0x89, 0x50, 0x4E, 0x47])) return (bytes, "image/png");
        if (Starts([0xFF, 0xD8, 0xFF])) return (bytes, "image/jpeg");
        if (!(macos ?? OperatingSystem.IsMacOS())) throw new LiveException("This computer reads PNG and JPEG images only.");
        var dir = Directory.CreateTempSubdirectory("pocketterm-image").FullName;
        try
        {
            var input = Path.Combine(dir, "in");
            await File.WriteAllBytesAsync(input, bytes).ConfigureAwait(false);
            var png = Path.Combine(dir, "out.png");
            var info = new ProcessStartInfo("/usr/bin/sips") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
            foreach (var a in new[] { "-s", "format", "png", input, "--out", png }) info.ArgumentList.Add(a);
            using var conv = Process.Start(info) ?? throw new LiveException("The computer couldn't read that image.");
            var drainOut = conv.StandardOutput.ReadToEndAsync();
            var drainErr = conv.StandardError.ReadToEndAsync();
            await conv.WaitForExitAsync().ConfigureAwait(false);
            await Task.WhenAll(drainOut, drainErr).ConfigureAwait(false);
            if (conv.ExitCode != 0) throw new LiveException("The computer couldn't read that image.");
            return (await File.ReadAllBytesAsync(png).ConfigureAwait(false), "image/png");
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
