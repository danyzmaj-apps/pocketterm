using System.Text;
using System.Text.Json.Nodes;
using PocketTerm.Core;

namespace PocketTerm.Core.Tests;

/// <summary>Port of packages/pocketterm_core/test/live_test.dart (the screen-parsing cases are in LiveVectorTests).</summary>
public class LiveTests
{
    private static LiveItem Text(string id, string text, ItemKind kind = ItemKind.Assistant) => new(id, kind) { Text = text };

    private static JsonObject Wire(JsonObject o) => DartJson.TryDecodeObject(DartJson.Encode(o))!;

    /// <summary>What a phone ends up with when every op reaches it through JSON.</summary>
    private static LiveView Follow(LiveLog log, IEnumerable<LiveOp> ops, LiveView? view = null)
    {
        var v = view ?? new LiveView(log.Epoch);
        Assert.True(v.Apply(log.Epoch, ops.Select(o => LiveOp.FromJson(Wire(o.ToJson()))).ToList()));
        return v;
    }

    private static LiveView CaughtUp(LiveLog log, int cap = 3000)
    {
        var view = new LiveView(log.Epoch, cap: cap);
        view.CatchUp(log.Epoch, log.Seq, true, log.Items, true);
        return view;
    }

    [Fact]
    public void LiveRoutedKeySplitsBack()
    {
        foreach (var key in new[] { "kitty-1/2", "tmux:default/0", "ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074" })
            Assert.Equal(("ab12cd34", key), Live.SplitRoutedKey(Live.RoutedKey("ab12cd34", key)));
        foreach (var s in new[] { "kitty-1/2", "ab12cd3/kitty-1/2", "ab12cd345/kitty-1/2", "AB12CD34/kitty-1/2", "ab12cd34kitty-1", "ab12cd34/", "" })
            Assert.Null(Live.SplitRoutedKey(s));
    }

    [Fact]
    public void LiveFollowerEndsWithWhatTheMacHas()
    {
        var log = new LiveLog([Text("u1", "hi", ItemKind.User)], older: false);
        var view = CaughtUp(log);
        var ops = new[]
        {
            log.Upsert(Text("a1", "")),
            log.Append("a1", "Hel")!,
            log.Append("a1", "lo")!,
            log.Upsert(new LiveItem("t1", ItemKind.Tool) { Tool = "bash", Args = "ls" }),
            log.Upsert(new LiveItem("t1", ItemKind.Tool) { Tool = "bash", Args = "ls", Output = "a\nb" }),
        };
        Follow(log, ops, view);
        Assert.Equal(["u1", "a1", "t1"], view.Items.Select(i => i.Id));
        Assert.Equal("Hello", view.Items[1].Text);
        Assert.Equal("a\nb", view.Items[2].Output);
        Assert.Equal(log.Seq, view.Seq);
    }

    [Fact]
    public void LiveReplacedItemShowsNewTextAfterARead()
    {
        var log = new LiveLog([], older: false);
        var view = Follow(log, [log.Upsert(Text("a1", "")), log.Append("a1", "Hel")!]);
        Assert.Equal("Hel", view.Items.Single().Text);
        Follow(log, [log.Upsert(Text("a1", "Hello."))], view);
        Assert.Equal("Hello.", view.Items.Single().Text);
    }

    [Fact]
    public void LiveOpHoldsItemAsItWas()
    {
        var log = new LiveLog([], older: false);
        var upsert = log.Upsert(Text("a1", "He"));
        var append = log.Append("a1", "llo")!;
        Assert.Equal("Hello", Follow(log, [upsert, append]).Items.Single().Text);
    }

    [Fact]
    public void LiveMissingOpIsDetectedAndCatchUpFills()
    {
        var log = new LiveLog([], older: false);
        var view = Follow(log, [log.Upsert(Text("a1", "one"))]);
        log.Upsert(Text("a2", "two")); // lost on the way
        var third = log.Upsert(Text("a3", "three"));
        Assert.False(view.Apply(log.Epoch, [third]));
        view.CatchUp(log.Epoch, log.Seq, false, log.Since(view.Seq), true);
        Assert.Equal(["one", "two", "three"], view.Items.Select(i => i.Text));
        Assert.Equal(log.Seq, view.Seq);
        Assert.True(view.Apply(log.Epoch, [third]));
        Assert.Equal(3, view.Items.Count);
    }

    [Fact]
    public void LiveNewEpochRefusedByApplyReplacedOnReset()
    {
        var old = new LiveLog([Text("x", "old")], older: false);
        var view = CaughtUp(old);
        var log = new LiveLog([Text("y", "new")], older: true);
        Assert.False(view.Apply(log.Epoch, [log.Upsert(Text("z", "!"))]));
        view.CatchUp(log.Epoch, log.Seq, true, log.Items, true, log.Older);
        Assert.Equal(["y", "z"], view.Items.Select(i => i.Id));
        Assert.True(view.Older);
    }

    [Fact]
    public void LiveSeqMovesOnlyWithLastChunk()
    {
        var log = new LiveLog(Enumerable.Range(0, 4).Select(i => Text($"{i}", $"{i}")), older: false);
        var view = new LiveView(log.Epoch);
        var items = log.Items;
        view.CatchUp(log.Epoch, log.Seq, true, items.Take(2), false);
        Assert.Equal(0, view.Seq);
        view.CatchUp(log.Epoch, log.Seq, true, items.Skip(2), true);
        Assert.Equal(log.Seq, view.Seq);
        Assert.Equal(4, view.Items.Count);
    }

    [Fact]
    public void LiveOlderItemsGoAboveTheOldest()
    {
        var log = new LiveLog([Text("c", "c"), Text("d", "d")], older: true);
        var view = CaughtUp(log);
        Follow(log, log.AddOlder([Text("a", "a"), Text("b", "b"), Text("c", "dup")], more: false), view);
        Assert.Equal(["a", "b", "c", "d"], view.Items.Select(i => i.Id));
        Assert.Equal("c", view.Items[2].Text);
        Assert.False(log.Older);
    }

    [Fact]
    public void LiveLogCapDropsOldest()
    {
        var log = new LiveLog(Enumerable.Range(0, 5).Select(i => Text($"{i}", $"{i}")), older: false, cap: 3);
        Assert.Equal(["2", "3", "4"], log.Items.Select(i => i.Id));
        Assert.True(log.Older);
        log.Upsert(Text("5", "5"));
        Assert.Equal(["3", "4", "5"], log.Items.Select(i => i.Id));
    }

    [Fact]
    public void LiveViewCapDropsOldestButKeepsPagedIn()
    {
        var log = new LiveLog(Enumerable.Range(0, 3).Select(i => Text($"{i}", $"{i}")), older: false, cap: 5);
        var view = CaughtUp(log, cap: 3);
        Assert.False(view.Older);
        Follow(log, [log.Upsert(Text("3", "3")), log.Upsert(Text("4", "4"))], view);
        Assert.Equal(["2", "3", "4"], view.Items.Select(i => i.Id));
        Assert.True(view.Older);
        Follow(log, log.AddOlder([Text("a", "a")], more: false), view);
        Assert.Equal("a", view.Items[0].Id);
        Follow(log, [log.Upsert(Text("5", "5"))], view);
        Assert.Equal(["3", "4", "5"], view.Items.Select(i => i.Id));
    }

    [Fact]
    public void LiveDiskCacheKeepsNewest()
    {
        var log = new LiveLog(Enumerable.Range(0, 10).Select(i => Text($"{i}", $"{i}")), older: false);
        var view = CaughtUp(log);
        var back = LiveView.FromJson(Wire(view.ToJson(keep: 4)));
        Assert.Equal(["6", "7", "8", "9"], back.Items.Select(i => i.Id));
        Assert.True(back.Older);
        Assert.Equal(view.Seq, back.Seq);
        Follow(log, [log.Upsert(Text("10", "x"))], back);
        Assert.Equal("10", back.Items[^1].Id);
    }

    [Fact]
    public void LiveJsonBytesMatchesEncoding()
    {
        foreach (var s in new[] { "plain", "quote \" and \\ back", "tab\tnl\n\0\u001b[31m", "é中文", "😀👍🏽", "שלום", "a\u200db", "\ud800 lone" })
            Assert.Equal(Encoding.UTF8.GetByteCount(DartJson.Encode(JsonValue.Create(s))) - 2, Live.JsonBytes(s));
    }

    [Fact]
    public void LiveHugeItemIsCutTheSameForMacAndPhone()
    {
        var log = new LiveLog([], older: false);
        var huge = string.Concat(Enumerable.Repeat("中文 ok 😀 \u001b[1m\"", 40000));
        var ops = new List<LiveOp> { log.Upsert(Text("u", huge, ItemKind.User)), log.Upsert(Text("a", "")) };
        for (var i = 0; i < 300; i++)
        {
            if (log.Append("a", $"{i} {new string('x', 500)}\n") is { } op) ops.Add(op);
        }
        ops.Add(log.Upsert(new LiveItem("t", ItemKind.Tool) { Tool = "bash", Args = new string('y', 100000), Output = new string('z', 100000) + "END" }));
        var view = Follow(log, ops);
        foreach (var i in log.Items)
            Assert.True(DartJson.EncodeUtf8(i.ToJson()).Length < Live.MaxItemTextBytes + 32 * 1024, i.Id);
        Assert.StartsWith("中文 ok 😀", log.Items[0].Text, StringComparison.Ordinal);
        Assert.EndsWith(Live.CutNote, log.Items[0].Text, StringComparison.Ordinal);
        Assert.EndsWith(Live.CutNote, log.Items[1].Text, StringComparison.Ordinal);
        Assert.EndsWith("END", log.Items[2].Output, StringComparison.Ordinal);
        static string Texts(LiveItem i) => DartJson.Encode(LiveJson.Strings([i.Id, i.Text, i.Args, i.Output]));
        Assert.Equal(log.Items.Select(Texts), view.Items.Select(Texts));
        foreach (var chunk in Live.ChunkJson(log.Items.Select(i => i.ToJson())))
            Assert.True(DartJson.EncodeUtf8(new JsonArray(chunk.Select(c => (JsonNode?)c).ToArray())).Length * 4 / 3 < 256 * 1024);
    }

    // ------------------------------------------------------------ answerKeys

    private static readonly LiveQuestion Db = new("db", "Database?", ["SQLite", "Postgres", "MySQL"]);

    private static LiveAsk Ask(params LiveQuestion[] qs) => LiveAsk.OfQuestions("call", qs);

    private static List<string> Flat(IEnumerable<KeyStep> steps) => steps.Select(s => s switch
    {
        Keys k => string.Join(' ', k.KeyNames),
        Typed t => $"type:{t.Text}",
        _ => "wait",
    }).ToList();

    private static string To(int row, int rows) => string.Join(' ', Enumerable.Repeat("up", rows).Concat(Enumerable.Repeat("down", row)));

    [Fact]
    public void LiveAnswerKeysSingleChoice() =>
        Assert.Equal([$"{To(1, 4)} enter"], Flat(Live.AnswerKeys(Ask(Db), [new LiveAnswer([1])])));

    [Fact]
    public void LiveAnswerKeysTyped() =>
        Assert.Equal([$"{To(3, 4)} enter", "wait", "type:DuckDB", "enter", "wait"], Flat(Live.AnswerKeys(Ask(Db), [new LiveAnswer(Custom: " DuckDB ")])));

    [Fact]
    public void LiveAnswerKeysTypedSeveral()
    {
        var q2 = new LiveQuestion("wt", "Worktree?", ["Yes", "No"]);
        Assert.Equal(
            [$"{To(3, 4)} enter", "wait", "type:a", "enter", "wait", $"{To(2, 3)} enter", "wait", "type:b", "enter", "wait", "enter"],
            Flat(Live.AnswerKeys(Ask(Db, q2), [new LiveAnswer(Custom: "a"), new LiveAnswer(Custom: "b")])));
    }

    [Fact]
    public void LiveAnswerKeysMultiple()
    {
        var q = new LiveQuestion("f", "Features?", ["a", "b", "c"], Multi: true);
        Assert.Equal([$"{To(0, 4)} space {To(2, 4)} space enter"], Flat(Live.AnswerKeys(Ask(q), [new LiveAnswer([0, 2])])));
    }

    [Fact]
    public void LiveAnswerKeysLoneMultipleTyped()
    {
        var q = new LiveQuestion("f", "Features?", ["a"], Multi: true);
        Assert.Equal(
            [$"{To(0, 2)} space {To(1, 2)} enter", "wait", "type:z", "enter", "wait", "enter"],
            Flat(Live.AnswerKeys(Ask(q), [new LiveAnswer([0], "z")])));
    }

    [Fact]
    public void LiveAnswerKeysSeveral()
    {
        var q2 = new LiveQuestion("os", "OS?", ["mac", "linux"]);
        Assert.Equal([$"{To(2, 4)} enter {To(0, 3)} enter", "wait", "enter"], Flat(Live.AnswerKeys(Ask(Db, q2), [new LiveAnswer([2]), new LiveAnswer([0])])));
    }

    [Fact]
    public void LiveAnswerKeysApproval()
    {
        var a = LiveAsk.OfApproval("call", "bash");
        Assert.Equal(["enter"], Flat(Live.AnswerKeys(a, approve: true)));
        Assert.Equal(["down enter"], Flat(Live.AnswerKeys(a)));
        Assert.Equal(["1"], Flat(Live.AnswerKeys(a, approve: true, agent: Agent.Claude)));
        Assert.Equal(["esc"], Flat(Live.AnswerKeys(a, agent: Agent.Claude)));
    }

    [Fact]
    public void LiveAnswerKeysRefused()
    {
        Assert.Throws<ArgumentException>(() => Live.AnswerKeys(Ask(Db), []));
        Assert.Throws<ArgumentException>(() => Live.AnswerKeys(Ask(Db), [new LiveAnswer([3])]));
        Assert.Throws<ArgumentException>(() => Live.AnswerKeys(Ask(Db), [new LiveAnswer([0, 1])]));
        Assert.Throws<ArgumentException>(() => Live.AnswerKeys(Ask(Db), [new LiveAnswer(Custom: "  ")]));
        Assert.Throws<ArgumentException>(() => Live.AnswerKeys(LiveAsk.OfPlan("p")));
    }

    [Fact]
    public void LiveAskOnScreenBasics()
    {
        var q = new LiveQuestion("x", "Which **storage** backend should the sync layer use?", ["a"]);
        Assert.True(Live.AskOnScreen(LiveAsk.OfQuestions("c", [q]), " Which storage backend should\n the sync layer use?\n > a"));
        Assert.False(Live.AskOnScreen(LiveAsk.OfQuestions("c", [q]), "π > waiting for input"));
        var a = LiveAsk.OfApproval("c", "bash");
        Assert.True(Live.AskOnScreen(a, "Run bash?\n> Approve\n  Deny"));
        Assert.False(Live.AskOnScreen(a, "Approve the plan"));
    }

    [Fact]
    public void LiveMenuKeys()
    {
        Assert.Equal(["down", "down", "enter"], Live.MenuKeys(1, 3));
        Assert.Equal(["up", "up", "up", "enter"], Live.MenuKeys(3, 0));
        Assert.Equal(["enter"], Live.MenuKeys(2, 2));
        Assert.Equal(["up", "up", "up"], Live.MenuKeys(4, 1, enter: false));
        Assert.Throws<ArgumentException>(() => Live.MenuKeys(2, -1));
        Assert.Throws<ArgumentException>(() => Live.MenuKeys(-1, 0));
    }

    [Fact]
    public void LivePlanAskThroughJson()
    {
        var ask = LiveAsk.OfPlan("call", "notes-plan", ["Approve and execute", "Refine plan"], 1);
        var back = LiveAsk.FromJson(Wire(ask.ToJson()));
        Assert.True(back.IsPlan);
        Assert.Equal("call", back.Id);
        Assert.Equal("notes-plan", back.Title);
        Assert.Equal(ask.Options, back.Options);
        Assert.Equal(1, back.Selected);
        Assert.Equal("Plan ready: notes-plan", back.Text);
        var bare = LiveAsk.FromJson(new JsonObject { ["kind"] = "plan", ["id"] = "x", ["title"] = "notes-plan" });
        Assert.True(bare.IsPlan);
        Assert.Empty(bare.Options);
    }

    [Fact]
    public void LivePickerAskThroughJson()
    {
        var ask = LiveAsk.OfMenu("menu-3", "Select model", [new("opus", "Anthropic · 200k"), new("gpt-5", "")], 1, true);
        var back = LiveAsk.FromJson(Wire(ask.ToJson()));
        Assert.True(back.IsMenu);
        Assert.Equal("menu-3", back.Id);
        Assert.Equal("Select model", back.Title);
        Assert.Equal(ask.Items, back.Items);
        Assert.Equal(1, back.Selected);
        Assert.True(back.Filter);
        Assert.Equal("Select model", back.Text);
    }

    // ------------------------------------------------------------ ScreenDiff

    private static List<string> Lines(int from, int to) => Enumerable.Range(from, to - from).Select(i => $"line {i}").ToList();

    [Fact]
    public void LiveScreenDiffScrolled()
    {
        var a = Lines(0, 100);
        var b = Lines(5, 105);
        var d = ScreenDiff.Between(a, b)!;
        Assert.Equal((5, 95, 5), (d.Drop, d.Keep, d.Tail.Count));
        Assert.Equal(b, d.Apply(a));
    }

    [Fact]
    public void LiveScreenDiffRedrawnBottom()
    {
        var a = Lines(0, 50);
        List<string> b = [.. Lines(0, 45), "x", "y"];
        var d = ScreenDiff.Between(a, b)!;
        Assert.Equal(["x", "y"], d.Tail);
        Assert.Equal(b, d.Apply(a));
    }

    [Fact]
    public void LiveScreenDiffUnrelatedAndWrongBase()
    {
        Assert.Null(ScreenDiff.Between(Lines(0, 10), Lines(50, 60)));
        Assert.Null(ScreenDiff.Between(Lines(0, 100), Lines(10, 110))!.Apply(Lines(0, 20)));
    }

    // ------------------------------------------------------------ summaries, commands, chunks

    private static LiveSummary Summary(string profile = "", IReadOnlyList<LiveCommand>? commands = null) =>
        new() { Key = "k", Id = "s", Title = "", Cwd = "/x", Epoch = "e", Seq = 1, Profile = profile, Commands = commands ?? [] };

    [Fact]
    public void LiveSummaryProfileThroughJson()
    {
        var s = Summary("personal");
        Assert.Equal("personal", s.ToJson().Str("profile"));
        Assert.Equal("personal", LiveSummary.FromJson(Wire(s.ToJson())).Profile);
        Assert.False(Summary().ToJson().ContainsKey("profile"));
        Assert.Equal("", LiveSummary.FromJson(new JsonObject { ["key"] = "k" }).Profile);
    }

    private static readonly LiveCommand[] Commands =
    [
        new("model", "Switch model for this session"),
        new("new", "Start a new session"),
        new("compact", "Manually compact the session context"),
        new("plan-review", ""),
        new("plan", "Toggle plan mode"),
        new("skill:Pdf", "Read PDFs"),
    ];

    private static IEnumerable<string> Names(string text, int max = 6) => Live.MatchCommands(Commands, text, max).Select(c => c.Name);

    [Fact]
    public void LiveSummaryKeepsCommands()
    {
        Assert.Equal(Commands, LiveSummary.FromJson(Wire(Summary(commands: Commands).ToJson())).Commands);
        Assert.Empty(LiveSummary.FromJson(new JsonObject { ["key"] = "k" }).Commands);
    }

    [Fact]
    public void LiveMatchCommands()
    {
        Assert.Equal(["plan-review", "plan", "compact", "skill:Pdf"], Names("/p"));
        Assert.Equal(["plan-review", "plan"], Names("/PL"));
        Assert.Equal(["new", "plan-review", "plan"], Names("/n"));
        Assert.Equal(["model", "new", "compact"], Names("/", 3));
        Assert.Empty(Names("/new "));
        Assert.Empty(Names("/compact keep the API"));
        Assert.Empty(Names("new"));
        Assert.Empty(Names("/zzz"));
    }

    [Fact]
    public void LiveChunkJsonKeepsUnderLimit()
    {
        var items = Enumerable.Range(0, 50).Select(i => new JsonObject { ["id"] = $"{i}", ["t"] = new string('x', 900) }).ToList();
        var chunks = Live.ChunkJson(items, 5000);
        Assert.True(chunks.Count > 1);
        foreach (var c in chunks)
            Assert.True(DartJson.EncodeUtf8(new JsonArray(c.Select(i => (JsonNode?)i.DeepClone()).ToArray())).Length < 5100);
        Assert.Equal(50, chunks.Sum(c => c.Count));
    }
}
