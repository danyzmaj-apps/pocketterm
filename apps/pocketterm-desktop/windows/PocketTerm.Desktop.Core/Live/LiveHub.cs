using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PocketTerm.Core;
using static PocketTerm.Desktop.LiveCasts;

namespace PocketTerm.Desktop;

/// <summary>Where a session runs (Terminals.LocateAsync): from the <paramref name="term"/> its extension reports, else
/// (Ghostty) by its folder, its title as its <paramref name="agent"/> shows it in the window's, and the windows
/// <paramref name="claimed"/> by other sessions.</summary>
public delegate Task<string?> Locate(JsonObject? term, string cwd, string title, Agent agent, IReadOnlySet<string> claimed);

/// <summary>
/// One coding session, as its agent's extension reports it (integrations/: omp's pocketterm-live.ts, the Claude
/// Code plugin). Its hub changes it under the hub's lock; read it there too (<see cref="Summary"/> takes it).
/// </summary>
public sealed class LiveSession
{
    private readonly object _gate;

    internal LiveSession(object gate, LiveLink link, string key, LiveLog log)
    {
        _gate = gate;
        Link = link;
        Key = key;
        Log = log;
    }

    internal LiveLink Link { get; }

    /// <summary>The terminal window it runs in (the hosts' keys: <c>kitty-&lt;pid&gt;/&lt;id&gt;</c>,
    /// <c>tmux:default/3</c>, <c>wezterm:…</c>), or <c>pid:&lt;pid&gt;</c>; a window found after it said hello
    /// (<see cref="LiveHub.RelinkAsync"/>) is <see cref="Window"/> only.</summary>
    public string Key { get; }

    public LiveLog Log { get; internal set; }
    public Agent Agent { get; internal set; } = Agent.Omp;

    /// <summary>The omp profile it runs in (<see cref="LiveSummary.Profile"/>).</summary>
    public string Profile { get; internal set; } = "";
    public string? Window { get; internal set; }

    /// <summary>What its extension said of its terminal, to find <see cref="Window"/> again.</summary>
    internal JsonObject? Term { get; set; }
    public string Id { get; internal set; } = "";
    public string Title { get; internal set; } = "";
    public string Cwd { get; internal set; } = "";
    public string Model { get; internal set; } = "";
    public bool Busy { get; internal set; }

    /// <summary>Its last run ended in an error (<see cref="LiveSummary.Failed"/>); a new run clears it.</summary>
    public bool Failed { get; internal set; }
    public LiveAsk? Ask { get; internal set; }
    public long? Ctx { get; internal set; }

    /// <summary>What the session has cost so far, in US dollars (<see cref="LiveSummary.Cost"/>).</summary>
    public double? Cost { get; internal set; }
    public string Preview { get; internal set; } = "";
    public IReadOnlyList<LiveCommand> Commands { get; internal set; } = [];

    /// <summary>The last change (UTC).</summary>
    public DateTime At { get; internal set; } = DateTime.UtcNow;

    /// <summary>Prompts waiting for a run to end, next first (<see cref="LiveHub.PromptAsync"/>); <see cref="Paused"/> holds them.</summary>
    internal List<LiveQueuedPrompt> Queue { get; } = [];
    public bool Paused { get; internal set; }

    /// <summary>Its folder is the orchestrator folder (<see cref="LiveHub.OrchestratorDir"/>): it may make calls.</summary>
    public bool Orchestrator { get; internal set; }

    /// <summary>The queue's next prompt went to the agent, which hasn't said yet that it started; <see cref="Handoff"/> gives up on that.</summary>
    internal bool Handing { get; set; }
    internal LiveHub.Later? Handoff { get; set; }

    private long _req;
    private readonly Dictionary<long, TaskCompletionSource<JsonObject>> _pending = [];

    public LiveSummary Summary
    {
        get
        {
            lock (_gate)
            {
                return new LiveSummary
                {
                    Key = Key,
                    Id = Id,
                    Agent = Agent,
                    Profile = Profile,
                    Window = Window,
                    Title = Title,
                    Cwd = Cwd,
                    Model = Model,
                    Busy = Busy,
                    Ask = Ask,
                    Ctx = Ctx,
                    Cost = Cost,
                    Preview = Preview,
                    At = new DateTimeOffset(DateTime.SpecifyKind(At, DateTimeKind.Utc)),
                    Epoch = Log.Epoch,
                    Seq = Log.Seq,
                    Older = Log.Older,
                    Commands = Commands,
                    Queue = Queue.Select(q => q.Summary).ToList(),
                    Paused = Paused,
                    Failed = Failed,
                    Orchestrator = Orchestrator,
                };
            }
        }
    }

    /// <summary>Sends a <paramref name="type"/> request with <paramref name="payload"/> and waits for its reply.</summary>
    internal async Task<JsonObject> RequestAsync(string type, JsonObject payload, TimeSpan timeout)
    {
        long req;
        var done = new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_pending)
        {
            req = ++_req;
            _pending[req] = done;
        }
        var frame = new JsonObject { ["t"] = type, ["req"] = req };
        foreach (var (k, v) in payload) frame[k] = v?.DeepClone();
        Link.Send(DartJson.Encode(frame));
        try
        {
            JsonObject reply;
            try
            {
                reply = await done.Task.WaitAsync(timeout);
            }
            catch (TimeoutException)
            {
                throw new LiveException($"{Agent.Label()} did not answer.");
            }
            if (OptStr(reply, "error") is { } error) throw new LiveException(error);
            return reply;
        }
        finally
        {
            lock (_pending) _pending.Remove(req);
        }
    }

    /// <summary>A <c>reply</c> frame: completes the request it answers.</summary>
    internal void Reply(JsonObject m)
    {
        var n = DartJson.AsNum(m["req"]);
        if (n is not { } r || r != Math.Floor(r) || Math.Abs(r) > long.MaxValue) return;
        lock (_pending)
        {
            if (_pending.TryGetValue((long)r, out var done)) done.TrySetResult(m);
        }
    }

    internal void Fail()
    {
        lock (_pending)
        {
            foreach (var c in _pending.Values) c.TrySetException(new LiveException($"The {Agent.Label()} session ended."));
            _pending.Clear();
        }
    }
}

/// <summary>A prompt in a session's queue, as it will go to the agent.</summary>
internal sealed class LiveQueuedPrompt
{
    public LiveQueuedPrompt(string id, string text, List<JsonObject> images, List<string> imageFiles, List<string> docs)
    {
        Id = id;
        Text = text;
        Images = images;
        ImageFiles = imageFiles;
        Docs = docs;
    }

    public string Id { get; }

    /// <summary>What the person typed; <see cref="Docs"/> are named after it as <c>@path</c> when it goes.</summary>
    public string Text { get; set; }

    /// <summary>For an agent that steers (omp): the images themselves (<c>{data, mimeType}</c>); else saved on this
    /// computer for it to read.</summary>
    public List<JsonObject> Images { get; }
    public List<string> ImageFiles { get; }

    /// <summary>The files sent with it, saved on this computer (<see cref="PromptFiles"/>).</summary>
    public List<string> Docs { get; }

    public bool Empty => Text.DartTrim().Length == 0 && Images.Count == 0 && ImageFiles.Count == 0 && Docs.Count == 0;

    public LiveQueued Summary => new(Id, Text, Images.Count + ImageFiles.Count, Docs.Select(d => Path.GetFileName(d)).ToList());
}

/// <summary>What the hub refuses or an agent answers with an error: <see cref="Exception.Message"/> is for the person.</summary>
public sealed class LiveException(string message) : Exception(message)
{
    public override string ToString() => Message;
}

/// <summary>Something worth a notification.</summary>
public abstract record LiveEvent(LiveSession Session);

/// <summary>The agent stopped and isn't about to go on by itself.</summary>
public sealed record LiveFinished(LiveSession Session, string Summary) : LiveEvent(Session);

/// <summary>The agent asks a question, wants a tool approved, or has a plan for review.</summary>
public sealed record LiveAsked(LiveSession Session, LiveAsk Ask) : LiveEvent(Session);

/// <summary>
/// The coding sessions on this computer: their extensions connect to the local API (<see cref="LocalApi"/>) and keep
/// it up to date; the terminal bridge passes them on to the phone.
/// Threading: one lock (<see cref="Gate"/>) guards the hub and its sessions; it's never held across an await, and
/// <see cref="Ops"/>, <see cref="Changes"/> and <see cref="Events"/> fire after it's released, on the thread that
/// caused them (a connection's reader, a timer, or the caller), in order for any one session.
/// </summary>
public sealed partial class LiveHub
{
    /// <param name="locate">Where a session runs (Terminals.LocateAsync); <see cref="Terminal.WindowOfTerm"/> by default.</param>
    /// <param name="files">Where files sent with prompts go.</param>
    /// <param name="images">Where images for an agent that reads them from disk go. The ones older than a day go now,
    /// and when more come.</param>
    public LiveHub(Locate? locate = null, PromptFiles? files = null, string? images = null)
    {
        _locate = locate ?? ByTerm;
        _files = files ?? new PromptFiles();
        _imageDir = images ?? Path.Combine(Path.GetTempPath(), "pocketterm-images");
        _ = _files.PruneAsync();
        PruneImages();
    }

    private static Task<string?> ByTerm(JsonObject? term, string cwd, string title, Agent agent, IReadOnlySet<string> claimed) =>
        Task.FromResult(Terminal.WindowOfTerm(term));

    private readonly Locate _locate;
    private readonly PromptFiles _files;

    /// <summary>The sessions by key, in the order they came (Dart's map order: a key replaced keeps its place).</summary>
    private readonly Dictionary<string, LiveSession> _byKey = [];
    private readonly List<string> _order = [];

    /// <summary>Guards the hub and its sessions.</summary>
    internal object Gate { get; } = new();

    /// <summary>Transcript changes, per session.</summary>
    public event Action<(LiveSession Session, List<LiveOp> Ops)>? Ops;

    /// <summary>A session came, went, or its summary changed.</summary>
    public event Action? Changes;

    /// <summary>Something worth a notification (<see cref="LiveFinished"/>, <see cref="LiveAsked"/>).</summary>
    public event Action<LiveEvent>? Events;

    /// <summary>The sessions now, in the order they came.</summary>
    public IReadOnlyList<LiveSession> Sessions
    {
        get
        {
            lock (Gate) return _order.Select(k => _byKey[k]).ToList();
        }
    }

    public LiveSession? this[string key]
    {
        get
        {
            lock (Gate) return _byKey.GetValueOrDefault(key);
        }
    }

    /// <summary>PocketTerm's orchestrator folder, next to cli.json; set by <see cref="LocalApi"/>. Null: no orchestrator.</summary>
    public string? OrchestratorDir { get; set; }

    private bool IsCurrent(LiveSession s) => _byKey.TryGetValue(s.Key, out var now) && ReferenceEquals(now, s);

    private void Put(string key, LiveSession s)
    {
        if (!_byKey.ContainsKey(key)) _order.Add(key);
        _byKey[key] = s;
    }

    private void RemoveKey(string key)
    {
        if (_byKey.Remove(key)) _order.Remove(key);
    }

    /// <summary>
    /// What notifications call <paramref name="s"/>'s project: its folder's name, with the one above it when another
    /// session's folder has the same name (two checkouts called <c>api</c>); empty when its folder isn't known.
    /// </summary>
    public string ProjectName(LiveSession s)
    {
        static List<string> Parts(string cwd) => cwd.Split('\\', '/').Where(p => p.Length > 0).ToList();
        lock (Gate)
        {
            var mine = Parts(s.Cwd);
            if (mine.Count == 0) return s.Cwd == "/" ? "/" : "";
            var clash = _byKey.Values.Any(o => !ReferenceEquals(o, s) && o.Cwd != s.Cwd && Parts(o.Cwd).LastOrDefault() == mine[^1]);
            return clash && mine.Count > 1 ? $"{mine[^2]}/{mine[^1]}" : mine[^1];
        }
    }

    /// <summary>
    /// Serves one extension, whose JSON <paramref name="frames"/> come in order over <paramref name="link"/>, until
    /// they end. A frame this side can't read (an extension older or newer than the app, with fields missing or of
    /// another shape) is skipped; the session goes on.
    /// </summary>
    public async Task AcceptAsync(IAsyncEnumerable<string> frames, LiveLink link)
    {
        LiveSession? session = null;
        try
        {
            await foreach (var frame in frames)
            {
                try
                {
                    if (DartJson.Decode(frame) is not JsonObject m) continue;
                    if (DartJson.AsString(m["t"]) == "hello")
                    {
                        session = await HelloAsync(link, session, m);
                    }
                    else if (session != null)
                    {
                        bool current;
                        lock (Gate) current = IsCurrent(session);
                        if (current) Handle(session, m);
                    }
                }
                catch (Exception e)
                {
                    Log.Print($"PocketTerm: live session: a frame skipped: {e.Message}");
                }
            }
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: live session: {e.Message}");
        }
        finally
        {
            if (session != null)
            {
                session.Fail();
                var after = new After();
                lock (Gate)
                {
                    session.Handoff?.Dispose();
                    if (IsCurrent(session))
                    {
                        RemoveKey(session.Key);
                        KeepQueue(session);
                        Changed(after);
                    }
                }
                after.Run();
            }
        }
    }

    /// <summary>Sessions gone with prompts in their queue, by key: the same agent saying hello again in the same
    /// window soon (restarted, reconnected) takes them over.</summary>
    private readonly Dictionary<string, (LiveSession Session, Later Timer)> _orphans = [];
    private static readonly TimeSpan OrphanFor = TimeSpan.FromMinutes(10);

    private void KeepQueue(LiveSession s)
    {
        if (s.Queue.Count == 0 && !s.Handing) return;
        if (_orphans.Remove(s.Key, out var was)) was.Timer.Dispose();
        var key = s.Key;
        _orphans[key] = (s, new Later(OrphanFor, later =>
        {
            lock (Gate)
            {
                if (!later.Cancelled) _orphans.Remove(key);
            }
        }));
    }

    /// <summary><paramref name="to"/> takes over <paramref name="from"/>'s queue, when they're the same agent.</summary>
    private static void TakeQueue(LiveSession to, LiveSession? from)
    {
        if (from == null || ReferenceEquals(from, to) || from.Agent != to.Agent || from.Queue.Count == 0) return;
        to.Queue.AddRange(from.Queue);
        to.Paused = from.Paused;
        from.Queue.Clear();
    }

    /// <summary>
    /// The session's key is the window it runs in: where its <c>term</c> says (an older extension reports only
    /// kitty's, as <c>window</c>), else its pid. A <c>term</c> that names no window is trusted over <c>window</c>,
    /// which an extension also reads from KITTY_* variables leaked from a kitty that started the terminal (they'd name
    /// a window of that kitty). The same agent saying hello again stays where it is, under the same key.
    /// </summary>
    private async Task<LiveSession> HelloAsync(LiveLink link, LiveSession? current, JsonObject m)
    {
        // All of it read first: a hello this side can't read changes nothing.
        var s = OptMap(m, "session") ?? new JsonObject();
        var term = OptMap(m, "term");
        var agent = Agents.Parse(m["agent"]);
        var cwd = OptStr(s, "cwd") ?? "";
        var title = OptStr(s, "title") ?? "";
        var said = term == null ? OptStr(m, "window") : null;
        var pid = DartToString(m["pid"]);
        var items = new List<LiveItem>();
        foreach (var i in OptList(m, "items") ?? [])
        {
            if (i is JsonObject o && DartJson.AsString(o["id"]) != null) items.Add(LiveItem.FromJson(o));
        }
        var older = IsTrue(m["older"]);
        var profile = agent == Agent.Omp && DartJson.AsString(m["profile"]) is { } p && Agents.IsOmpProfile(p) ? p : "";
        var id = OptStr(s, "id") ?? "";
        var model = OptStr(s, "model") ?? "";
        var busy = IsTrue(m["busy"]);
        var ctx = Round(OptNum(m, "ctx"));
        var cost = OptNum(m, "cost");
        var commands = Live.LiveCommands(m["commands"]);
        var orchestrator = Desktop.Orchestrator.IsOrchestratorDir(cwd, OrchestratorDir);

        IReadOnlySet<string> claimed;
        lock (Gate) claimed = Claimed(current);
        string? window = null;
        try
        {
            window = await _locate(term, cwd, title, agent, claimed);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: where a live session runs: {e.Message}");
        }
        if (term == null) window ??= said;

        var after = new After();
        LiveSession session;
        try
        {
            lock (Gate)
            {
                var same = current != null && IsCurrent(current) ? current : null;
                window ??= same?.Window;
                var key = same != null && same.Window == window ? same.Key : window ?? $"pid:{pid}";
                var log = new LiveLog(items, older);
                if (current != null && current.Key == key && IsCurrent(current))
                {
                    // Another session in the same agent (/new, /resume, /clear): a new transcript.
                    session = current;
                    session.Log = log;
                }
                else
                {
                    var moved = same;
                    if (moved != null) RemoveKey(moved.Key);
                    session = new LiveSession(Gate, link, key, log) { Agent = agent };
                    // The same window's previous agent, if its connection hasn't closed yet.
                    var old = _byKey.GetValueOrDefault(key);
                    if (old != null && !ReferenceEquals(old.Link, link)) after.Add(() => _ = old.Link.CloseAsync());
                    Put(key, session);
                    LiveSession? orphan = null;
                    if (_orphans.Remove(key, out var o))
                    {
                        o.Timer.Dispose();
                        orphan = o.Session;
                    }
                    TakeQueue(session, moved);
                    TakeQueue(session, old);
                    TakeQueue(session, orphan);
                }
                session.Agent = agent;
                session.Profile = profile;
                session.Window = window;
                session.Term = term;
                session.Id = id;
                session.Title = title;
                session.Cwd = cwd;
                session.Model = model;
                session.Busy = busy;
                session.Failed = false;
                session.Handing = false;
                session.Ctx = ctx;
                session.Cost = cost;
                session.Ask = null;
                session.Commands = commands;
                session.Preview = Preview(log.Items.LastOrDefault(i => i.Kind == ItemKind.Assistant)?.Text ?? "");
                session.At = DateTime.UtcNow;
                session.Orchestrator = orchestrator;
                session.Handoff?.Dispose();
                Changed(after);
                Drain(session, after);
                // A window claimed can leave another session the one window left.
                if (window != null) RelinkSoon(after);
            }
        }
        finally
        {
            after.Run();
        }
        return session;
    }

    /// <summary>The windows the sessions other than <paramref name="except"/> run in.</summary>
    private HashSet<string> Claimed(LiveSession? except) =>
        _byKey.Values.Where(s => !ReferenceEquals(s, except) && s.Window != null).Select(s => s.Window!).ToHashSet();

    private bool _relinking;
    private bool _relinkAgain;

    /// <summary>
    /// Looks again for the window of each session that has none, by what changed since its hello: a Ghostty window is
    /// told apart by its title (a session gets one after its first prompt) and by the windows other sessions run in.
    /// A window found becomes the session's <see cref="LiveSession.Window"/>; its key stays the one the phone knows.
    /// </summary>
    public async Task RelinkAsync()
    {
        lock (Gate)
        {
            if (_relinking)
            {
                _relinkAgain = true;
                return;
            }
            _relinking = true;
        }
        try
        {
            bool found;
            bool again;
            do
            {
                lock (Gate) _relinkAgain = false;
                found = false;
                foreach (var s in Sessions)
                {
                    JsonObject? term;
                    string cwd, title;
                    Agent agent;
                    IReadOnlySet<string> claimed;
                    lock (Gate)
                    {
                        if (s.Window != null || s.Term == null) continue;
                        (term, cwd, title, agent, claimed) = (s.Term, s.Cwd, s.Title, s.Agent, Claimed(s));
                    }
                    string? window = null;
                    try
                    {
                        window = await _locate(term, cwd, title, agent, claimed);
                    }
                    catch (Exception e)
                    {
                        Log.Print($"PocketTerm: where a live session runs: {e.Message}");
                    }
                    var after = new After();
                    lock (Gate)
                    {
                        // Gone, placed or beaten to it meanwhile.
                        if (window == null || s.Window != null || !IsCurrent(s) || Claimed(s).Contains(window)) continue;
                        s.Window = window;
                        found = true;
                        Changed(after);
                    }
                    after.Run();
                }
                // A window claimed can leave another session the one window left.
                lock (Gate) again = _relinkAgain;
            } while (found || again);
        }
        finally
        {
            lock (Gate) _relinking = false;
        }
    }

    private void RelinkSoon(After after)
    {
        if (_byKey.Values.Any(s => s.Window == null && s.Term != null)) after.Add(() => _ = RelinkAsync());
    }

    private static string Preview(string text)
    {
        var line = text.Split('\n').Select(l => Markup().Replace(l, "").DartTrim()).FirstOrDefault(l => l.Length > 0) ?? "";
        return line.Length > 140 ? $"{line[..139]}…" : line;
    }

    [GeneratedRegex("[`*_#>]")]
    private static partial Regex Markup();

    private void Handle(LiveSession s, JsonObject m)
    {
        var after = new After();
        try
        {
            lock (Gate) HandleLocked(s, m, after);
        }
        finally
        {
            after.Run();
        }
    }

    private void HandleLocked(LiveSession s, JsonObject m, After after)
    {
        switch (DartJson.AsString(m["t"]))
        {
            case "item":
            {
                var item = LiveItem.FromJson(m["item"] as JsonObject ?? throw new InvalidCastException("'item' is not a Map"));
                s.At = DateTime.UtcNow;
                Op(after, s, [s.Log.Upsert(item)]);
                if (item.Kind == ItemKind.Assistant && item.Text.Length > 0)
                {
                    var preview = Preview(item.Text);
                    if (preview != s.Preview)
                    {
                        s.Preview = preview;
                        Changed(after);
                    }
                }
                break;
            }
            case "append":
            {
                var op = s.Log.Append(ReqStr(m, "id"), OptStr(m, "text") ?? "");
                if (op != null) Op(after, s, [op]);
                break;
            }
            case "busy":
            {
                var busy = IsTrue(m["busy"]);
                s.Handing = false;
                s.Handoff?.Dispose();
                s.Busy = busy;
                s.Failed = !busy && IsTrue(m["failed"]);
                s.At = DateTime.UtcNow;
                // Stopped (Stop from the phone, Esc at the computer): what waits stays until Resume.
                if (!busy && IsTrue(m["stopped"]) && s.Queue.Count > 0) s.Paused = true;
                // The queue's next prompt goes now: the agent goes on, so nothing finished.
                if (Drainable(s))
                {
                    Drain(s, after);
                    return;
                }
                Changed(after);
                var summary = OptStr(m, "summary");
                if (!busy && summary != null) Event(after, new LiveFinished(s, summary));
                break;
            }
            case "ask":
            {
                var ask = m["ask"] is JsonObject a ? LiveAsk.FromJson(a) : null;
                s.Ask = ask;
                Changed(after);
                if (ask != null) Event(after, new LiveAsked(s, ask));
                Drain(s, after);
                break;
            }
            case "meta":
            {
                if (DartJson.AsString(m["title"]) is { } title && title != s.Title)
                {
                    s.Title = title;
                    if (s.Window == null) RelinkSoon(after);
                }
                if (DartJson.AsString(m["model"]) is { } model) s.Model = model;
                if (m.ContainsKey("ctx")) s.Ctx = Round(OptNum(m, "ctx"));
                if (m.ContainsKey("cost")) s.Cost = OptNum(m, "cost");
                if (m["commands"] is JsonArray) s.Commands = Live.LiveCommands(m["commands"]);
                Changed(after);
                break;
            }
            case "reply":
                s.Reply(m);
                break;
            case "call":
                after.Add(() => _ = CallAsync(s, m));
                break;
        }
    }

    private LiveSession Session(string key) => _byKey.GetValueOrDefault(key) ?? throw new LiveException("That session has ended.");

    /// <summary>Answers a call of the orchestrator's tools (<see cref="LiveSession.Orchestrator"/> only): a
    /// <c>result</c> with the text for its model, or the error.</summary>
    private async Task CallAsync(LiveSession s, JsonObject m)
    {
        var id = m["id"]?.DeepClone();
        string? text = null;
        string? error = null;
        try
        {
            bool orchestrator;
            lock (Gate) orchestrator = s.Orchestrator;
            if (!orchestrator) throw new LiveException("Only the PocketTerm orchestrator can do that.");
            switch (DartJson.AsString(m["op"]))
            {
                case "sessions":
                    text = Desktop.Orchestrator.SessionsText(this, DateTime.UtcNow);
                    break;
                case "read":
                    text = Desktop.Orchestrator.TranscriptText(this, Target(m), ToInt(OptNum(m, "last")) ?? 30);
                    break;
                case "prompt":
                {
                    var words = (OptStr(m, "text") ?? "").DartTrim();
                    if (words.Length == 0) throw new LiveException("Nothing to send.");
                    if (words.StartsWith('/')) throw new LiveException("Slash commands can't be sent from the orchestrator.");
                    var t = Target(m);
                    var queued = await PromptAsync(t.Key, words, followUp: DartJson.AsString(m["deliver"]) != "steer");
                    text = queued == null
                        ? $"Sent to {Desktop.Orchestrator.NamedSession(this, t)}."
                        : $"Queued in {Desktop.Orchestrator.NamedSession(this, t)}: it goes when its current run ends.";
                    break;
                }
                case "stop":
                {
                    var t = Target(m);
                    await AbortAsync(t.Key);
                    int n;
                    lock (Gate) n = t.Queue.Count;
                    text = $"Stopped {Desktop.Orchestrator.NamedSession(this, t)}."
                        + (n == 0 ? "" : $" Its {n} queued prompt{(n == 1 ? "" : "s")} wait{(n == 1 ? "s" : "")} until the person resumes them.");
                    break;
                }
                default:
                    throw new LiveException("Unknown call.");
            }
        }
        catch (Exception e)
        {
            error = e.Message;
        }
        lock (Gate)
        {
            if (!IsCurrent(s)) return;
        }
        var result = new JsonObject { ["t"] = "result", ["id"] = id };
        if (text != null) result["text"] = text;
        if (error != null) result["error"] = error;
        s.Link.Send(DartJson.Encode(result));
    }

    /// <summary>The session a call names: not gone, not the orchestrator itself.</summary>
    private LiveSession Target(JsonObject m)
    {
        lock (Gate)
        {
            var t = Session(OptStr(m, "session") ?? "");
            if (t.Orchestrator) throw new LiveException("That is the orchestrator itself.");
            return t;
        }
    }

    /// <summary>
    /// Replaces session <paramref name="key"/>'s ask, while it's still <paramref name="id"/> (null: while there is
    /// none), with what this computer read off its screen: a plan review's options, a picker a slash command opened,
    /// or null once it's gone. Not the agent asking, so no event. False when the session's ask has moved on.
    /// </summary>
    public bool UpdateAsk(string key, string? id, LiveAsk? ask)
    {
        var after = new After();
        try
        {
            lock (Gate)
            {
                var s = _byKey.GetValueOrDefault(key);
                if (s == null || s.Ask?.Id != id) return false;
                s.Ask = ask;
                Changed(after);
                Drain(s, after);
                return true;
            }
        }
        finally
        {
            after.Run();
        }
    }

    /// <summary>Where images for an agent that reads them from disk (Claude Code) wait for it
    /// (<c>pocketterm-images</c> in the temp folder by default).</summary>
    private readonly string _imageDir;

    /// <summary>
    /// Sends <paramref name="text"/> (and <paramref name="images"/> and <paramref name="files"/>) as the person's
    /// prompt. While omp works it steers the run, or waits for the run to end with <paramref name="followUp"/>;
    /// Claude Code always waits, and gets the images as files. <paramref name="files"/> are saved on this computer
    /// (<see cref="PromptFiles"/>) and named in the text as <c>@path</c>, as one would at the computer: omp reads them
    /// in when it isn't working, else the agent opens them; Claude Code's extension lets it read them without asking.
    /// One that waits goes to the session's queue, under <paramref name="id"/> (a new one by default), which it
    /// returns; it goes to the agent when a run ends, next in line. Null when it went to the agent now.
    /// </summary>
    public async Task<string?> PromptAsync(
        string key,
        string text,
        IReadOnlyList<(byte[] Bytes, string MimeType)>? images = null,
        IReadOnlyList<PromptFile>? files = null,
        bool followUp = false,
        string? id = null)
    {
        images ??= [];
        files ??= [];
        bool steers;
        lock (Gate) steers = Session(key).Agent.Steers();
        var saved = await _files.SaveAsync(files);
        var inline = steers
            ? images.Select(i => new JsonObject { ["data"] = Convert.ToBase64String(i.Bytes), ["mimeType"] = i.MimeType }).ToList()
            : [];
        var imageFiles = steers ? [] : await SaveImagesAsync(images);
        var q = new LiveQueuedPrompt(id ?? NewId(), text, inline, imageFiles, saved);
        // As it is now: it may have started or ended a run, or said hello again, meanwhile.
        LiveSession s;
        var after = new After();
        try
        {
            lock (Gate)
            {
                s = Session(key);
                if ((followUp || !steers) && (s.Busy || s.Ask != null))
                {
                    Room(s, q.Text.Length, another: true);
                    s.Queue.Add(q);
                    Changed(after);
                    return q.Id;
                }
            }
        }
        finally
        {
            after.Run();
        }
        await SendAsync(s, q, followUp || !steers ? "followUp" : "steer");
        return null;
    }

    /// <summary>At most this many prompts wait in a session's queue, with at most <see cref="MaxQueuedText"/>
    /// characters of text together: the phones get every one whole with each state.</summary>
    public const int MaxQueued = 20;
    public const int MaxQueuedText = 32000;

    /// <summary>Throws unless <paramref name="s"/>'s queue has room for <paramref name="chars"/> more characters, and
    /// <paramref name="another"/> prompt.</summary>
    private static void Room(LiveSession s, int chars, bool another = false)
    {
        if (another && s.Queue.Count >= MaxQueued) throw new LiveException($"The queue is full: {MaxQueued} prompts wait already.");
        if (s.Queue.Sum(q => q.Text.Length) + chars > MaxQueuedText)
        {
            throw new LiveException("That is more text than the queue holds: send it when the run ends.");
        }
    }

    private static string NewId() => PromptFiles.RandomName(16);

    private Task<JsonObject> SendAsync(LiveSession s, LiveQueuedPrompt q, string deliver)
    {
        JsonObject payload;
        lock (Gate)
        {
            var steers = s.Agent.Steers();
            payload = new JsonObject
            {
                ["text"] = PromptFiles.WithMentions(q.Text, q.Docs),
                ["images"] = new JsonArray(q.Images.Select(i => (JsonNode?)i.DeepClone()).ToArray()),
            };
            if (!steers) payload["files"] = new JsonArray(q.ImageFiles.Select(f => (JsonNode?)JsonValue.Create(f)).ToArray());
            if (!steers && q.Docs.Count > 0) payload["docs"] = new JsonArray(q.Docs.Select(f => (JsonNode?)JsonValue.Create(f)).ToArray());
            payload["deliver"] = deliver;
        }
        return s.RequestAsync("prompt", payload, TimeSpan.FromSeconds(15));
    }

    /// <summary>Whether <paramref name="s"/>'s queue's next prompt can go: the agent is at rest and asks nothing,
    /// nothing holds the queue.</summary>
    private bool Drainable(LiveSession s) =>
        s.Queue.Count > 0 && !s.Paused && !s.Busy && s.Ask == null && !s.Handing && IsCurrent(s);

    /// <summary>How long the agent may take to say it started on a prompt from the queue before it's taken to be at rest.</summary>
    public static readonly TimeSpan HandoffWait = TimeSpan.FromSeconds(10);

    /// <summary>Hands <paramref name="s"/>'s queue's next prompt to the agent, if it can go (<see cref="Drainable"/>).
    /// The session shows as working from here on, so it never looks done in between. One that doesn't go returns to
    /// the front, and the queue pauses.</summary>
    private void Drain(LiveSession s, After after)
    {
        if (!Drainable(s)) return;
        var q = s.Queue[0];
        s.Queue.RemoveAt(0);
        s.Handing = true;
        s.Busy = true;
        s.Failed = false;
        s.At = DateTime.UtcNow;
        if (s.Queue.Count == 0) s.Paused = false;
        Changed(after);
        after.Add(() => _ = HandOffAsync(s, q));
    }

    private async Task HandOffAsync(LiveSession s, LiveQueuedPrompt q)
    {
        var after = new After();
        try
        {
            try
            {
                await SendAsync(s, q, "followUp");
            }
            catch (Exception e)
            {
                Log.Print($"PocketTerm: a queued prompt did not go: {e.Message}");
                lock (Gate)
                {
                    s.Queue.Insert(0, q);
                    s.Paused = true;
                    if (s.Handing)
                    {
                        s.Handing = false;
                        s.Busy = false;
                    }
                    Changed(after);
                }
                return;
            }
            lock (Gate)
            {
                if (!s.Handing) return;
                s.Handoff?.Dispose();
                s.Handoff = new Later(HandoffWait, later =>
                {
                    var a = new After();
                    lock (Gate)
                    {
                        if (later.Cancelled || !s.Handing) return;
                        s.Handing = false;
                        s.Busy = false;
                        if (Drainable(s)) Drain(s, a);
                        else Changed(a);
                    }
                    a.Run();
                });
            }
        }
        finally
        {
            after.Run();
        }
    }

    private static LiveQueuedPrompt Queued(LiveSession s, string id) =>
        s.Queue.FirstOrDefault(q => q.Id == id) ?? throw new LiveException("That prompt has gone to the agent already.");

    /// <summary>Replaces the text of prompt <paramref name="id"/> in session <paramref name="key"/>'s queue.</summary>
    public void EditQueued(string key, string id, string text)
    {
        var after = new After();
        try
        {
            lock (Gate)
            {
                var s = Session(key);
                var q = Queued(s, id);
                var was = q.Text;
                q.Text = text;
                if (q.Empty)
                {
                    q.Text = was;
                    throw new LiveException("A prompt needs some text, an image or a file.");
                }
                q.Text = was;
                Room(s, text.Length - was.Length);
                q.Text = text;
                Changed(after);
            }
        }
        finally
        {
            after.Run();
        }
    }

    /// <summary>Takes prompt <paramref name="id"/> out of session <paramref name="key"/>'s queue: it never goes.</summary>
    public void RemoveQueued(string key, string id)
    {
        var after = new After();
        try
        {
            lock (Gate)
            {
                var s = Session(key);
                s.Queue.Remove(Queued(s, id));
                if (s.Queue.Count == 0) s.Paused = false;
                Changed(after);
            }
        }
        finally
        {
            after.Run();
        }
    }

    /// <summary>Moves prompt <paramref name="id"/> to place <paramref name="to"/> (0: next) in session
    /// <paramref name="key"/>'s queue; past the end is last.</summary>
    public void MoveQueued(string key, string id, int to)
    {
        var after = new After();
        try
        {
            lock (Gate)
            {
                var s = Session(key);
                var q = Queued(s, id);
                s.Queue.Remove(q);
                s.Queue.Insert(Math.Clamp(to, 0, s.Queue.Count), q);
                Changed(after);
            }
        }
        finally
        {
            after.Run();
        }
    }

    /// <summary>Sends prompt <paramref name="id"/> out of session <paramref name="key"/>'s queue now: it steers the
    /// run. omp only; Claude Code can't take a prompt while it works. One that doesn't go goes back where it was.</summary>
    public async Task SendQueuedNowAsync(string key, string id)
    {
        LiveSession s;
        LiveQueuedPrompt q;
        int at;
        var after = new After();
        try
        {
            lock (Gate)
            {
                s = Session(key);
                if (!s.Agent.Steers()) throw new LiveException($"{s.Agent.Label()} can't take a prompt while it works.");
                q = Queued(s, id);
                at = s.Queue.IndexOf(q);
                s.Queue.RemoveAt(at);
                if (s.Queue.Count == 0) s.Paused = false;
                Changed(after);
            }
        }
        finally
        {
            after.Run();
        }
        try
        {
            await SendAsync(s, q, "steer");
        }
        catch
        {
            var back = new After();
            lock (Gate)
            {
                s.Queue.Insert(Math.Min(at, s.Queue.Count), q);
                Changed(back);
            }
            back.Run();
            throw;
        }
    }

    /// <summary>Holds session <paramref name="key"/>'s queue, or lets it go on: its next prompt goes now if the agent
    /// is at rest.</summary>
    public void PauseQueue(string key, bool paused)
    {
        var after = new After();
        try
        {
            lock (Gate)
            {
                var s = Session(key);
                s.Paused = paused && s.Queue.Count > 0;
                Changed(after);
                Drain(s, after);
            }
        }
        finally
        {
            after.Run();
        }
    }

    private async Task<List<string>> SaveImagesAsync(IReadOnlyList<(byte[] Bytes, string MimeType)> images)
    {
        if (images.Count == 0) return [];
        var dir = _imageDir;
        if (!Directory.Exists(dir))
        {
            Directory.CreateDirectory(dir);
            // Private to this user; Windows' per-user temp folder already is.
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(dir, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
        PruneImages();
        var paths = new List<string>(images.Count);
        foreach (var i in images)
        {
            var path = Path.Combine(dir, $"{PromptFiles.RandomName(12)}.{(i.MimeType == "image/jpeg" ? "jpg" : "png")}");
            await File.WriteAllBytesAsync(path, i.Bytes);
            paths.Add(path);
        }
        return paths;
    }

    /// <summary>Deletes the images older than <see cref="PromptFiles.Keep"/>.</summary>
    private void PruneImages()
    {
        if (!Directory.Exists(_imageDir)) return;
        var before = DateTime.UtcNow - PromptFiles.Keep;
        string[] files;
        try
        {
            files = Directory.GetFiles(_imageDir);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Print($"PocketTerm: image cleanup: {e.Message}");
            return;
        }
        foreach (var f in files)
        {
            try
            {
                if (File.GetLastWriteTimeUtc(f) < before) File.Delete(f);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                Log.Print($"PocketTerm: image cleanup: {e.Message}");
            }
        }
    }

    /// <summary>Esc: stops what the agent is doing. What waits in its queue stays there until Resume.</summary>
    public async Task AbortAsync(string key)
    {
        LiveSession s;
        var after = new After();
        try
        {
            lock (Gate)
            {
                s = Session(key);
                if (s.Queue.Count > 0 && !s.Paused)
                {
                    s.Paused = true;
                    Changed(after);
                }
            }
        }
        finally
        {
            after.Run();
        }
        await s.RequestAsync("abort", new JsonObject(), TimeSpan.FromSeconds(5));
    }

    /// <summary>Fetches the items before the oldest one the hub has; they go out as ops.</summary>
    public async Task OlderAsync(string key, int limit = 150)
    {
        LiveSession s;
        LiveLog log;
        lock (Gate)
        {
            s = Session(key);
            if (!s.Log.Older) return;
            log = s.Log;
        }
        var reply = await s.RequestAsync("older", new JsonObject { ["limit"] = limit }, TimeSpan.FromSeconds(10));
        var after = new After();
        try
        {
            lock (Gate)
            {
                // Another session started meanwhile: these belong to the old one.
                if (!ReferenceEquals(s.Log, log)) return;
                var items = (OptList(reply, "items") ?? [])
                    .Select(i => LiveItem.FromJson(i as JsonObject ?? throw new InvalidCastException("item is not a Map")))
                    .ToList();
                var ops = log.AddOlder(items, more: IsTrue(reply["older"]));
                if (ops.Count > 0) Op(after, s, ops);
                Changed(after);
            }
        }
        finally
        {
            after.Run();
        }
    }

    private void Changed(After after) => after.Add(() => Changes?.Invoke());

    private void Op(After after, LiveSession s, List<LiveOp> ops) => after.Add(() => Ops?.Invoke((s, ops)));

    private void Event(After after, LiveEvent e) => after.Add(() => Events?.Invoke(e));

    /// <summary>What a change under the lock does once it's released: the events it raises, the work it starts, in order.</summary>
    private sealed class After
    {
        private List<Action>? _actions;

        public void Add(Action a) => (_actions ??= []).Add(a);

        public void Run()
        {
            if (_actions == null) return;
            var actions = _actions;
            _actions = null;
            foreach (var a in actions)
            {
                try
                {
                    a();
                }
                catch (Exception e)
                {
                    // A listener that throws mustn't stop the others, nor the hub (as a Dart stream listener's error).
                    Log.Print($"PocketTerm: live hub listener: {e.Message}");
                }
            }
        }
    }

    /// <summary>A one-shot timer (Dart's <c>Timer</c>): <see cref="Dispose"/> under the hub's lock cancels it, and its
    /// action, which takes the lock, checks <see cref="Cancelled"/> first.</summary>
    internal sealed class Later : IDisposable
    {
        private readonly Timer _timer;

        public Later(TimeSpan due, Action<Later> run)
        {
            _timer = new Timer(_ => run(this), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
            _timer.Change(due, Timeout.InfiniteTimeSpan);
        }

        public bool Cancelled { get; private set; }

        public void Dispose()
        {
            Cancelled = true;
            _timer.Dispose();
        }
    }
}
