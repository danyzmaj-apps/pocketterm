using System.Text.Json.Nodes;

namespace PocketTerm.Core;

/// <summary>What a transcript entry is.</summary>
public enum ItemKind
{
    User,
    Assistant,
    Tool,
    Notice,
}

/// <summary>How a tool call went.</summary>
public enum ToolStatus
{
    Running,
    Ok,
    Error,
}

/// <summary>One entry of a session's transcript, as the phone draws it.</summary>
public sealed class LiveItem
{
    public LiveItem(string id, ItemKind kind)
    {
        Id = id;
        Kind = kind;
    }

    public static LiveItem FromJson(JsonObject j) => new(LiveJson.ReqStr(j, "id"), DartEnum.Parse<ItemKind>(j["k"]) ?? ItemKind.Notice)
    {
        Text = LiveJson.OptStr(j, "t") ?? "",
        Images = LiveJson.OptInt(j, "im") ?? 0,
        Tool = LiveJson.OptStr(j, "tl") ?? "",
        Title = LiveJson.OptStr(j, "ti") ?? "",
        Args = LiveJson.OptStr(j, "a") ?? "",
        Output = LiveJson.OptStr(j, "out") ?? "",
        Status = DartEnum.Parse<ToolStatus>(j["st"]) ?? ToolStatus.Ok,
        Order = LiveJson.OptInt(j, "o") ?? 0,
        Seq = LiveJson.OptInt(j, "s") ?? 0,
    };

    public string Id { get; }
    public ItemKind Kind { get; }

    /// <summary>user, assistant (Markdown), notice: the text.</summary>
    public string Text { get; set; } = "";

    /// <summary>user: how many images came with it.</summary>
    public long Images { get; set; }

    /// <summary>tool: its name (<c>bash</c>, <c>edit</c>), what it says it's doing, its
    /// arguments in brief, the end of its output, how it went.</summary>
    public string Tool { get; set; } = "";
    public string Title { get; set; } = "";
    public string Args { get; set; } = "";
    public string Output { get; set; } = "";
    public ToolStatus Status { get; set; } = ToolStatus.Running;

    /// <summary>Its place in the transcript, and the hub's seq of its last change.</summary>
    public long Order { get; set; }
    public long Seq { get; set; }

    public JsonObject ToJson()
    {
        var o = new JsonObject { ["id"] = Id, ["k"] = Kind.Name() };
        if (Text.Length > 0) o["t"] = Text;
        if (Images > 0) o["im"] = Images;
        if (Kind == ItemKind.Tool)
        {
            o["tl"] = Tool;
            if (Title.Length > 0) o["ti"] = Title;
            if (Args.Length > 0) o["a"] = Args;
            if (Output.Length > 0) o["out"] = Output;
            o["st"] = Status.Name();
        }
        o["o"] = Order;
        o["s"] = Seq;
        return o;
    }

    public LiveItem Copy() => FromJson(ToJson());
}

/// <summary>A prompt waiting in a session's queue on the computer (LiveHub), for a run to end.</summary>
public sealed record LiveQueued(string Id, string Text, long Images = 0, IReadOnlyList<string>? Files = null, bool Cut = false)
{
    /// <summary>How many images go with it, and the names of its files.</summary>
    public IReadOnlyList<string> Files { get; init; } = Files ?? [];

    public static LiveQueued FromJson(JsonObject j) => new(
        LiveJson.ReqStr(j, "id"),
        LiveJson.OptStr(j, "t") ?? "",
        LiveJson.OptInt(j, "im") ?? 0,
        (LiveJson.OptList(j, "f") ?? []).Select(DartJson.AsString).OfType<string>().ToList(),
        LiveJson.IsTrue(j["c"]));

    public JsonObject ToJson()
    {
        var o = new JsonObject { ["id"] = Id };
        if (Text.Length > 0) o["t"] = Text;
        if (Images > 0) o["im"] = Images;
        if (Files.Count > 0) o["f"] = LiveJson.Strings(Files);
        if (Cut) o["c"] = true;
        return o;
    }
}

/// <summary>A change to a session's transcript: <see cref="Item"/> whole, or <see cref="Append"/> added to
/// item <see cref="Id"/>'s text.</summary>
public sealed class LiveOp
{
    private LiveOp(long seq, LiveItem? item, string? id, string? append)
    {
        Seq = seq;
        Item = item;
        Id = id;
        Append = append;
    }

    public static LiveOp OfItem(long seq, LiveItem item) => new(seq, item, null, null);

    public static LiveOp OfAppend(long seq, string id, string append) => new(seq, null, id, append);

    public static LiveOp FromJson(JsonObject j)
    {
        var item = LiveJson.OptMap(j, "item");
        return item != null
            ? OfItem(LiveJson.ReqInt(j, "s"), LiveItem.FromJson(item))
            : OfAppend(LiveJson.ReqInt(j, "s"), LiveJson.ReqStr(j, "id"), LiveJson.ReqStr(j, "a"));
    }

    public long Seq { get; }
    public LiveItem? Item { get; }
    public string? Id { get; }
    public string? Append { get; }

    public JsonObject ToJson() =>
        Item != null
            ? new JsonObject { ["s"] = Seq, ["item"] = Item.ToJson() }
            : new JsonObject { ["s"] = Seq, ["id"] = Id, ["a"] = Append };
}

/// <summary>One question the agent asks (omp's <c>ask</c> tool, Claude Code's AskUserQuestion).</summary>
public sealed record LiveQuestion(string Id, string Question, IReadOnlyList<string> Options, string Header = "", bool Multi = false, long? Recommended = null)
{
    public static LiveQuestion FromJson(JsonObject j) => new(
        LiveJson.OptStr(j, "id") ?? "",
        LiveJson.OptStr(j, "question") ?? "",
        (LiveJson.OptList(j, "options") ?? []).Select(o => LiveJson.DartToString(o is JsonObject m ? m["label"] : o)).ToList(),
        LiveJson.OptStr(j, "header") ?? "",
        LiveJson.IsTrue(j["multi"]),
        LiveJson.OptInt(j, "recommended"));

    public JsonObject ToJson()
    {
        var o = new JsonObject { ["id"] = Id, ["question"] = Question };
        if (Header.Length > 0) o["header"] = Header;
        o["options"] = LiveJson.Strings(Options);
        if (Multi) o["multi"] = true;
        o.PutIfNotNull("recommended", Recommended is { } r ? JsonValue.Create(r) : null);
        return o;
    }
}

/// <summary>What an agent waits on the person for.</summary>
public enum AskKind
{
    Questions,
    Approval,
    Plan,
    Menu,
}

/// <summary>One row of an agent's picker: its <c>label</c>, and what it shows under or beside it (<c>detail</c>).</summary>
public readonly record struct MenuItem(string Label, string Detail);

/// <summary>
/// The agent is waiting on the person: its questions, approval of <see cref="Tool"/> (<see cref="Summary"/>: what it
/// would do), its plan review (plan mode's last step) of the plan <see cref="Title"/>, or a picker a slash command
/// opened (/resume, /model …) titled <see cref="Title"/>. A plan's <see cref="Options"/>, a picker's
/// <see cref="Items"/> and the <see cref="Selected"/> row of either are read off the agent's screen by the Mac (none
/// when it couldn't read them); a picker with <see cref="Filter"/> narrows as you type.
/// </summary>
public sealed class LiveAsk
{
    private LiveAsk(string id, AskKind kind)
    {
        Id = id;
        Kind = kind;
    }

    public static LiveAsk OfQuestions(string id, IReadOnlyList<LiveQuestion> questions) => new(id, AskKind.Questions) { Questions = questions };

    public static LiveAsk OfApproval(string id, string tool, string summary = "") => new(id, AskKind.Approval) { Tool = tool, Summary = summary };

    public static LiveAsk OfPlan(string id, string title = "Plan", IReadOnlyList<string>? options = null, int selected = 0) =>
        new(id, AskKind.Plan) { Title = title, Options = options ?? [], Selected = selected };

    public static LiveAsk OfMenu(string id, string title, IReadOnlyList<MenuItem> items, int selected = 0, bool filter = false) =>
        new(id, AskKind.Menu) { Title = title, Items = items, Selected = selected, Filter = filter };

    public static LiveAsk FromJson(JsonObject j) => DartJson.AsString(j["kind"]) switch
    {
        "approval" => OfApproval(LiveJson.ReqStr(j, "id"), LiveJson.OptStr(j, "tool") ?? "", LiveJson.OptStr(j, "summary") ?? ""),
        "plan" => OfPlan(
            LiveJson.ReqStr(j, "id"),
            LiveJson.OptStr(j, "title") ?? "Plan",
            (LiveJson.OptList(j, "options") ?? []).Select(LiveJson.DartToString).ToList(),
            (int)(LiveJson.OptInt(j, "selected") ?? 0)),
        "menu" => OfMenu(
            LiveJson.ReqStr(j, "id"),
            LiveJson.OptStr(j, "title") ?? "",
            (LiveJson.OptList(j, "items") ?? []).Select(i =>
            {
                var m = i as JsonObject ?? throw new InvalidCastException("item is not a Map");
                return new MenuItem(m["label"] is { } l ? LiveJson.DartToString(l) : "", LiveJson.OptStr(m, "detail") ?? "");
            }).ToList(),
            (int)(LiveJson.OptInt(j, "selected") ?? 0),
            LiveJson.IsTrue(j["filter"])),
        _ => OfQuestions(
            LiveJson.ReqStr(j, "id"),
            (LiveJson.OptList(j, "questions") ?? []).Select(q => LiveQuestion.FromJson(q as JsonObject ?? throw new InvalidCastException("question is not a Map"))).ToList()),
    };

    /// <summary>The tool call it belongs to.</summary>
    public string Id { get; }
    public AskKind Kind { get; }
    public IReadOnlyList<LiveQuestion>? Questions { get; private init; }
    public string Tool { get; private init; } = "";
    public string Summary { get; private init; } = "";
    public string Title { get; private init; } = "";
    public IReadOnlyList<string> Options { get; private init; } = [];
    public IReadOnlyList<MenuItem> Items { get; private init; } = [];
    public int Selected { get; private init; }
    public bool Filter { get; private init; }

    public bool IsApproval => Kind == AskKind.Approval;
    public bool IsPlan => Kind == AskKind.Plan;
    public bool IsMenu => Kind == AskKind.Menu;

    /// <summary>What a notification says.</summary>
    public string Text => Kind switch
    {
        AskKind.Approval => $"Approve {Tool}{(Summary.Length == 0 ? "" : $": {Summary}")}?",
        AskKind.Plan => $"Plan ready: {Title}",
        AskKind.Menu => Title,
        _ => string.Join("\n", Questions!.Select(q => q.Question)),
    };

    public JsonObject ToJson()
    {
        switch (Kind)
        {
            case AskKind.Approval:
            {
                var o = new JsonObject { ["kind"] = "approval", ["id"] = Id, ["tool"] = Tool };
                if (Summary.Length > 0) o["summary"] = Summary;
                return o;
            }
            case AskKind.Plan:
            {
                var o = new JsonObject { ["kind"] = "plan", ["id"] = Id, ["title"] = Title };
                if (Options.Count > 0)
                {
                    o["options"] = LiveJson.Strings(Options);
                    o["selected"] = Selected;
                }
                return o;
            }
            case AskKind.Menu:
            {
                var items = new JsonArray();
                foreach (var i in Items)
                {
                    var io = new JsonObject { ["label"] = i.Label };
                    if (i.Detail.Length > 0) io["detail"] = i.Detail;
                    items.Add(io);
                }
                var o = new JsonObject { ["kind"] = "menu", ["id"] = Id, ["title"] = Title, ["items"] = items, ["selected"] = Selected };
                if (Filter) o["filter"] = true;
                return o;
            }
            default:
                return new JsonObject
                {
                    ["kind"] = "ask",
                    ["id"] = Id,
                    ["questions"] = new JsonArray(Questions!.Select(q => (JsonNode?)q.ToJson()).ToArray()),
                };
        }
    }
}

/// <summary>The person's answer to one <see cref="LiveQuestion"/>: the options picked (indexes) and/or their own text.</summary>
public sealed record LiveAnswer(IReadOnlyList<long>? Picks = null, string? Custom = null)
{
    public IReadOnlyList<long> Picks { get; init; } = Picks ?? [];

    public static LiveAnswer FromJson(JsonObject j) => new(
        (LiveJson.OptList(j, "picks") ?? []).Select(p => DartJson.AsInt(p) ?? throw new InvalidCastException("pick is not an int")).ToList(),
        LiveJson.OptStr(j, "custom"));

    public JsonObject ToJson()
    {
        var o = new JsonObject { ["picks"] = new JsonArray(Picks.Select(p => (JsonNode?)JsonValue.Create(p)).ToArray()) };
        if (Custom != null) o["custom"] = Custom;
        return o;
    }
}

/// <summary>One step of answering an agent's dialog with the keyboard: keys (kitty's names) pressed, or text typed.</summary>
public abstract record KeyStep;

/// <summary>Keys pressed, in order.</summary>
public sealed record Keys(List<string> KeyNames) : KeyStep;

/// <summary>Text typed.</summary>
public sealed record Typed(string Text) : KeyStep;

/// <summary>Wait for the agent to redraw before the next keys: opening or closing a typed answer and moving to the
/// Submit tab take a moment, and keys sent before that are dropped.</summary>
public sealed record Settle : KeyStep;

/// <summary>One of omp's slash commands, without its <c>/</c>.</summary>
public readonly record struct LiveCommand(string Name, string Description);

/// <summary>Plan review options read off a screen, and the one the cursor is on.</summary>
public sealed record PlanReview(IReadOnlyList<string> Options, int Current);

/// <summary>A picker read off a screen (<see cref="Live.ParseMenu"/>).</summary>
public sealed record ParsedMenu(string Title, IReadOnlyList<MenuItem> Items, int Current, bool Filter);

/// <summary>A live session in the phone's list.</summary>
public sealed record LiveSummary
{
    /// <summary>Stable for the agent's process: its terminal window's key (<c>kitty-&lt;pid&gt;/&lt;id&gt;</c>,
    /// <c>tmux:default/3</c> …), or <c>pid:&lt;pid&gt;</c> when its window can't be told. What the
    /// phone opens and notifications point at.</summary>
    public required string Key { get; init; }

    /// <summary>The agent's session id (changes on /new, /resume, /clear).</summary>
    public required string Id { get; init; }

    /// <summary>Which coding agent this is.</summary>
    public Agent Agent { get; init; } = Agent.Omp;

    /// <summary>The omp profile it runs in (<c>omp --profile</c>); '' for the default and for Claude Code.</summary>
    public string Profile { get; init; } = "";
    public string? Window { get; init; }
    public required string Title { get; init; }
    public required string Cwd { get; init; }
    public string Model { get; init; } = "";
    public bool Busy { get; init; }
    public LiveAsk? Ask { get; init; }

    /// <summary>How full the context window is, in percent.</summary>
    public long? Ctx { get; init; }

    /// <summary>What the session has spent so far, in US dollars, as its agent tallies it.</summary>
    public double? Cost { get; init; }

    /// <summary>The last answer's first line.</summary>
    public string Preview { get; init; } = "";

    /// <summary>The last change.</summary>
    public DateTimeOffset? At { get; init; }
    public required string Epoch { get; init; }
    public required long Seq { get; init; }
    public bool Older { get; init; }

    /// <summary>The agent's slash commands, for the composer.</summary>
    public IReadOnlyList<LiveCommand> Commands { get; init; } = [];

    /// <summary>Prompts waiting on the computer for the run to end, next first; <see cref="Paused"/> holds them (a stopped run, Pause).</summary>
    public IReadOnlyList<LiveQueued> Queue { get; init; } = [];
    public bool Paused { get; init; }

    /// <summary>The last run ended in an error (the answer broke off with one; not a stop, and no retry got past it).
    /// The next run clears it.</summary>
    public bool Failed { get; init; }

    /// <summary>Started by PocketTerm as this computer's orchestrator (an omp session in PocketTerm's orchestrator
    /// folder): the phone shows it in its own bar, not in the list.</summary>
    public bool Orchestrator { get; init; }

    public static LiveSummary FromJson(JsonObject j)
    {
        double? ctx = j["ctx"] is null ? null : (DartJson.AsNum(j["ctx"]) ?? throw new InvalidCastException("'ctx' is not a num?"));
        double? cost = j["cost"] is null ? null : (DartJson.AsNum(j["cost"]) ?? throw new InvalidCastException("'cost' is not a num?"));
        var commands = new List<LiveCommand>();
        foreach (var c in LiveJson.OptList(j, "cmds") ?? [])
        {
            if (c is JsonArray a && a.Count > 0 && DartJson.AsString(a[0]) is { } name)
                commands.Add(new LiveCommand(name, a.Count > 1 && DartJson.AsString(a[1]) is { } d ? d : ""));
        }
        var queue = new List<LiveQueued>();
        foreach (var q in LiveJson.OptList(j, "queue") ?? [])
        {
            if (q is JsonObject m && DartJson.AsString(m["id"]) != null) queue.Add(LiveQueued.FromJson(m));
        }
        return new LiveSummary
        {
            Key = LiveJson.ReqStr(j, "key"),
            Id = LiveJson.OptStr(j, "id") ?? "",
            Agent = Agents.Parse(j["agent"]),
            Profile = LiveJson.OptStr(j, "profile") ?? "",
            Window = LiveJson.OptStr(j, "window"),
            Title = LiveJson.OptStr(j, "title") ?? "",
            Cwd = LiveJson.OptStr(j, "cwd") ?? "",
            Model = LiveJson.OptStr(j, "model") ?? "",
            Busy = LiveJson.IsTrue(j["busy"]),
            Ask = j["ask"] is JsonObject ask ? LiveAsk.FromJson(ask) : null,
            // num.toInt() truncates.
            Ctx = ctx is { } x ? (long)Math.Truncate(x) : null,
            Cost = cost,
            Preview = LiveJson.OptStr(j, "preview") ?? "",
            At = DartJson.AsInt(j["at"]) is { } at ? DateTimeOffset.FromUnixTimeMilliseconds(at) : null,
            Epoch = LiveJson.OptStr(j, "epoch") ?? "",
            Seq = LiveJson.OptInt(j, "seq") ?? 0,
            Older = LiveJson.IsTrue(j["older"]),
            Commands = commands,
            Queue = queue,
            Paused = LiveJson.IsTrue(j["paused"]),
            Failed = LiveJson.IsTrue(j["failed"]),
            Orchestrator = LiveJson.IsTrue(j["orch"]),
        };
    }

    public JsonObject ToJson()
    {
        var o = new JsonObject { ["key"] = Key, ["id"] = Id, ["agent"] = Agent.Name() };
        if (Profile.Length > 0) o["profile"] = Profile;
        if (Window != null) o["window"] = Window;
        o["title"] = Title;
        o["cwd"] = Cwd;
        if (Model.Length > 0) o["model"] = Model;
        if (Busy) o["busy"] = true;
        if (Ask != null) o["ask"] = Ask.ToJson();
        if (Ctx is { } ctx) o["ctx"] = ctx;
        if (Cost is { } cost) o["cost"] = cost;
        if (Preview.Length > 0) o["preview"] = Preview;
        if (At is { } at) o["at"] = at.ToUnixTimeMilliseconds();
        o["epoch"] = Epoch;
        o["seq"] = Seq;
        if (Older) o["older"] = true;
        if (Commands.Count > 0)
        {
            o["cmds"] = new JsonArray(Commands.Select(c => (JsonNode?)LiveJson.Strings(c.Description.Length > 0 ? [c.Name, c.Description] : [c.Name])).ToArray());
        }
        if (Queue.Count > 0) o["queue"] = new JsonArray(Queue.Select(q => (JsonNode?)q.ToJson()).ToArray());
        if (Paused) o["paused"] = true;
        if (Failed) o["failed"] = true;
        if (Orchestrator) o["orch"] = true;
        return o;
    }
}

/// <summary>How a screen's lines changed: <see cref="Drop"/> from the top, the next <see cref="Keep"/>
/// unchanged, then <see cref="Tail"/> new. Scrolling and a redrawn bottom cost a few lines instead of the whole screen.</summary>
public sealed record ScreenDiff(int Drop, int Keep, IReadOnlyList<string> Tail)
{
    public static ScreenDiff FromJson(JsonObject j) => new(
        (int)LiveJson.ReqInt(j, "drop"),
        (int)LiveJson.ReqInt(j, "keep"),
        ((j["tail"] as JsonArray) ?? throw new InvalidCastException("'tail' is not a List"))
            .Select(t => DartJson.AsString(t) ?? throw new InvalidCastException("tail line is not a String")).ToList());

    /// <summary>From <paramref name="a"/> to <paramref name="b"/>; null when sending <paramref name="b"/> whole is about as cheap.</summary>
    public static ScreenDiff? Between(IReadOnlyList<string> a, IReadOnlyList<string> b)
    {
        if (a.Count == 0 || b.Count == 0) return null;
        var bestDrop = 0;
        var bestKeep = 0;
        // Where b's first line sits in a: 0 unless lines scrolled off the top.
        var tries = 0;
        for (var d = 0; d < a.Count && tries < 8; d++)
        {
            if (a[d] != b[0]) continue;
            tries++;
            var k = 0;
            while (k < b.Count && d + k < a.Count && a[d + k] == b[k]) k++;
            if (k > bestKeep)
            {
                bestKeep = k;
                bestDrop = d;
            }
        }
        if (bestKeep < b.Count / 4) return null;
        return new ScreenDiff(bestDrop, bestKeep, b.Skip(bestKeep).ToList());
    }

    /// <summary><paramref name="a"/> changed into what <see cref="Between"/> was given; null if <paramref name="a"/>
    /// isn't what this diff was made from (the phone missed a version).</summary>
    public List<string>? Apply(IReadOnlyList<string> a)
    {
        if (Drop + Keep > a.Count) return null;
        return [.. a.Skip(Drop).Take(Keep), .. Tail];
    }

    public JsonObject ToJson() => new() { ["drop"] = Drop, ["keep"] = Keep, ["tail"] = LiveJson.Strings(Tail) };
}
