using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using PocketTerm.Core;

namespace PocketTerm.Core.Tests;

/// <summary>Every case of tool/vectors/vectors.json's <c>live</c> section (TermWindow/TermStatus models aside).</summary>
public class LiveVectorTests
{
    private static JsonObject Live_ => Vectors.Section("live");

    private static IEnumerable<JsonObject> Cases(JsonNode? n) => ((JsonArray)n!).Select(c => (JsonObject)c!);

    private static string Note(JsonObject c) => c.Str("note") ?? "";

    /// <summary>Same JSON as Dart writes it (so 43.0 stays a double, 43 an int).</summary>
    private static void Same(JsonNode? expected, JsonNode? actual, string note) =>
        Assert.True(DartJson.Encode(expected) == DartJson.Encode(actual), $"{note}\nexpected: {DartJson.Encode(expected)}\nactual:   {DartJson.Encode(actual)}");

    private static JsonObject O(JsonNode? n) => (JsonObject)n!.DeepClone();

    private static Agent AgentOf(JsonObject c) => DartEnum.Parse<Agent>(c["agent"]) ?? Agent.Omp;

    private static List<string> StringList(JsonNode? n) => ((JsonArray)n!).Select(x => DartJson.AsString(x)!).ToList();

    [Fact]
    public void LiveRoutedKeys()
    {
        foreach (var c in Cases(Live_["routedKey"]))
            Assert.True(c.Str("routed") == Core.Live.RoutedKey(c.Str("desktop")!, c.Str("key")!), Note(c));
        foreach (var c in Cases(Live_["splitRoutedKey"]))
        {
            var r = Core.Live.SplitRoutedKey(c.Str("input")!);
            JsonNode? actual = r is { } x ? new JsonObject { ["desktop"] = x.Desktop, ["key"] = x.Key } : null;
            Same(c["result"], actual, Note(c));
        }
    }

    [Fact]
    public void LiveJsonBytes()
    {
        foreach (var c in Cases(Live_["jsonBytes"]))
        {
            var s = c.Str("input") ?? new string(((JsonArray)c["utf16"]!).Select(u => (char)DartJson.AsInt(u)!.Value).ToArray());
            Assert.True(c.Int("bytes") == Core.Live.JsonBytes(s), Note(c));
        }
    }

    [Fact]
    public void LiveChunkJson()
    {
        foreach (var c in Cases(Live_["chunkJson"]))
        {
            var items = Cases(c["items"]).Select(i => (JsonObject)i.DeepClone()).ToList();
            var chunks = Core.Live.ChunkJson(items, (int)c.Int("maxBytes")!);
            var actual = new JsonArray(chunks.Select(ch => (JsonNode?)new JsonArray(ch.Select(i => (JsonNode?)i.DeepClone()).ToArray())).ToArray());
            Same(c["chunks"], actual, Note(c));
        }
    }

    [Fact]
    public void LiveConstants()
    {
        var k = (JsonObject)Live_["constants"]!;
        Assert.True(k.Str("cutNote") == Core.Live.CutNote, "cutNote");
        Assert.Equal(k.Int("maxItemTextBytes"), Core.Live.MaxItemTextBytes);
        Assert.Equal(k.Int("maxOutputBytes"), Core.Live.MaxOutputBytes);
        Assert.Equal(k.Int("maxArgsBytes"), Core.Live.MaxArgsBytes);
        Assert.Equal(k.Int("maxTitleBytes"), Core.Live.MaxTitleBytes);
        Assert.Equal(k.Int("chunkJsonDefaultMaxBytes"), DefaultChunkMax());
        Assert.Equal(k.Int("logCap"), new LiveLog([], older: false).Cap);
        Assert.Equal(k.Int("viewCap"), new LiveView("e").Cap);
        Assert.Equal(k.Int("viewCacheKeep"), DefaultKeep());
    }

    // The defaults, observed through behaviour: two items that take exactly the default fit one chunk, one byte more
    // splits them; the items a cache keeps.
    private static long DefaultChunkMax()
    {
        // {"t":"<n x>"} is n + 8 bytes, + 1 in the count.
        static JsonObject Item(int bytes) => new() { ["t"] = new string('x', bytes - 9) };
        var fits = Core.Live.ChunkJson([Item(20000), Item(20000)]).Count == 1;
        var splits = Core.Live.ChunkJson([Item(20000), Item(20001)]).Count == 2;
        return fits && splits ? 40000 : -1;
    }

    private static long DefaultKeep()
    {
        var view = new LiveView("e", items: Enumerable.Range(0, 700).Select(i => new LiveItem($"{i}", ItemKind.User) { Order = i }));
        return ((JsonArray)view.ToJson()["items"]!).Count;
    }

    // ------------------------------------------------------------ clip

    private static string Head(string s, int points, bool fromEnd)
    {
        var runes = new List<string>();
        for (var i = 0; i < s.Length; i++)
        {
            if (char.IsHighSurrogate(s[i]) && i + 1 < s.Length && char.IsLowSurrogate(s[i + 1]))
            {
                runes.Add(s.Substring(i, 2));
                i++;
            }
            else
            {
                runes.Add(s[i].ToString());
            }
        }
        return string.Concat(fromEnd ? runes.Skip(Math.Max(0, runes.Count - points)) : runes.Take(points));
    }

    private static void Summary(JsonNode? expected, string s, string note)
    {
        var e = (JsonObject)expected!;
        var utf8 = Encoding.UTF8.GetBytes(s);
        var actual = new JsonObject
        {
            ["codeUnits"] = s.Length,
            ["utf8Bytes"] = utf8.Length,
            ["jsonBytes"] = Core.Live.JsonBytes(s),
            ["sha256"] = Convert.ToHexString(SHA256.HashData(utf8)).ToLowerInvariant(),
            ["head"] = Head(s, 40, false),
            ["tail"] = Head(s, 40, true),
        };
        var keys = new JsonObject();
        foreach (var (k, _) in e) keys[k] = actual[k]!.DeepClone();
        Same(e, keys, note);
    }

    private static JsonObject Expand(JsonObject input)
    {
        var o = new JsonObject();
        foreach (var (k, val) in input) o[k] = val is JsonObject ? Vectors.Text(val) : val?.DeepClone();
        return o;
    }

    [Fact]
    public void LiveClip()
    {
        foreach (var c in Cases(((JsonObject)Live_["clip"]!)["cases"]))
        {
            var note = Note(c);
            if (c["input"] is JsonObject input)
            {
                var log = new LiveLog([], older: false);
                var op = log.Upsert(LiveItem.FromJson(Expand(input)));
                var stored = log.Items.Single();
                Summary(c["text"], stored.Text, note + " text");
                Summary(c["title"], stored.Title, note + " title");
                Summary(c["args"], stored.Args, note + " args");
                Summary(c["output"], stored.Output, note + " output");
                Assert.Equal(DartJson.Encode(stored.ToJson()), DartJson.Encode(op.Item!.ToJson()));
                continue;
            }
            var l = new LiveLog([], older: false);
            l.Upsert(new LiveItem("a", ItemKind.Assistant));
            var nonNull = 0;
            LiveOp? lastOp = null;
            for (var i = 0; i < 140; i++)
            {
                var o = l.Append("a", $"{i} {new string('x', 500)}\n");
                if (o == null) continue;
                nonNull++;
                lastOp = o;
            }
            Assert.True(c.Int("appendsNonNull") == nonNull, note);
            var exp = (JsonObject)c["lastNonNullOp"]!;
            Assert.Equal(exp.Int("s"), lastOp!.Seq);
            Assert.Equal(exp.Str("id"), lastOp.Id);
            Summary(exp["a"], lastOp.Append!, note + " op");
            Summary(c["text"], l.Items.Single().Text, note + " text");
        }
    }

    // ------------------------------------------------------------ log & view

    private static List<LiveItem> Items(JsonNode? n) => Cases(n).Select(i => LiveItem.FromJson(O(i))).ToList();

    private static JsonArray ItemsJson(IEnumerable<LiveItem> items) => new(items.Select(i => (JsonNode?)i.ToJson()).ToArray());

    [Fact]
    public void LiveLogScenario()
    {
        var sc = (JsonObject)Live_["logScenario"]!;
        var log = new LiveLog(Items(sc["snapshot"]), older: true, epoch: "e1");
        Same(sc["snapshotStored"], ItemsJson(log.Items), "snapshot stored");
        var wire = new List<LiveOp>();
        foreach (var step in Cases(sc["steps"]))
        {
            var a = (JsonObject)step["action"]!;
            List<LiveOp?> ops;
            if (a["upsert"] is JsonObject u) ops = [log.Upsert(LiveItem.FromJson(O(u)))];
            else if (a["append"] is JsonObject ap) ops = [log.Append(ap.Str("id")!, ap.Str("text")!)];
            else
            {
                var older = (JsonObject)a["addOlder"]!;
                ops = [.. log.AddOlder(Items(older["items"]), older.Bool("more")!.Value)];
            }
            Same(step["ops"], new JsonArray(ops.Select(o => (JsonNode?)o?.ToJson()).ToArray()), Note(step));
            wire.AddRange(ops.OfType<LiveOp>().Select(o => LiveOp.FromJson(DartJson.TryDecodeObject(DartJson.Encode(o.ToJson()))!)));
        }
        Assert.Equal(sc.Int("finalSeq"), log.Seq);
        Assert.Equal(sc.Bool("finalOlder"), log.Older);
        Same(sc["finalItems"], ItemsJson(log.Items), "finalItems");
        Same(sc["since3"], ItemsJson(log.Since(3)), "since3");

        LiveView Caught(string epoch = "e1") => new(epoch, 1, items: Items(sc["snapshotStored"]));
        var all = (JsonObject)sc["viewApplyAll"]!;
        var view = Caught();
        Assert.Equal(all.Bool("result"), view.Apply("e1", wire));
        Same(all["view"], view.ToJson(), "viewApplyAll");
        Assert.Equal(((JsonObject)sc["viewApplyWithGap"]!).Bool("result"), Caught().Apply("e1", wire.Skip(1)));
        Assert.Equal(((JsonObject)sc["viewApplyOtherEpoch"]!).Bool("result"), Caught("e0").Apply("e1", wire));
    }

    [Fact]
    public void LiveViewCatchUp()
    {
        var sc = (JsonObject)Live_["viewCatchUp"]!;
        var view = LiveView.FromJson(O(sc["initial"]));
        foreach (var step in Cases(sc["steps"]))
        {
            var c = (JsonObject)step["catchUp"]!;
            view.CatchUp(c.Str("epoch")!, c.Int("seq")!.Value, c.Bool("reset")!.Value, Items(c["items"]), c.Bool("last")!.Value, c.Bool("older"));
            Same(step["view"], view.ToJson(), Note(step));
        }
    }

    // ------------------------------------------------------------ commands

    private static JsonArray CommandsJson(IEnumerable<LiveCommand> cs) =>
        new(cs.Select(c => (JsonNode?)new JsonObject { ["name"] = c.Name, ["description"] = c.Description }).ToArray());

    [Fact]
    public void LiveCommandsAndMatches()
    {
        foreach (var c in Cases(Live_["liveCommands"]))
            Same(c["commands"], CommandsJson(Core.Live.LiveCommands(c["input"])), Note(c));
        var m = (JsonObject)Live_["matchCommands"]!;
        var commands = Cases(m["commands"]).Select(c => new LiveCommand(c.Str("name")!, c.Str("description")!)).ToList();
        foreach (var c in Cases(m["cases"]))
        {
            var names = Core.Live.MatchCommands(commands, c.Str("text")!, (int)c.Int("max")!).Select(x => x.Name);
            Same(c["names"], LiveJson.Strings(names), Note(c));
        }
    }

    // ------------------------------------------------------------ dialogs

    internal static JsonNode StepJson(KeyStep s) => s switch
    {
        Keys k => new JsonObject { ["keys"] = LiveJson.Strings(k.KeyNames) },
        Typed t => new JsonObject { ["type"] = t.Text },
        _ => new JsonObject { ["settle"] = true },
    };

    [Fact]
    public void LiveAnswerKeys()
    {
        foreach (var c in Cases(((JsonObject)Live_["answerKeys"]!)["cases"]))
        {
            var ask = LiveAsk.FromJson(O(c["ask"]));
            var answers = Cases(c["answers"]).Select(a => LiveAnswer.FromJson(O(a))).ToList();
            JsonNode actual;
            try
            {
                actual = new JsonArray(Core.Live.AnswerKeys(ask, answers, c.Bool("approve") ?? false, AgentOf(c)).Select(s => (JsonNode?)StepJson(s)).ToArray());
            }
            catch (ArgumentException)
            {
                actual = "error";
            }
            Same(c["steps"], actual, Note(c));
        }
    }

    [Fact]
    public void LiveMenuKeysAndRows()
    {
        foreach (var c in Cases(Live_["menuKeys"]))
        {
            JsonNode actual;
            try
            {
                actual = LiveJson.Strings(Core.Live.MenuKeys((int)c.Int("current")!, (int)c.Int("target")!, c.Bool("enter") ?? true));
            }
            catch (ArgumentException)
            {
                actual = "error";
            }
            Same(c["keys"], actual, Note(c));
        }
        foreach (var c in Cases(Live_["claudeRowKey"]))
            Assert.True(c.Str("key") == Core.Live.ClaudeRowKey(c.Int("row")!.Value), Note(c));
    }

    [Fact]
    public void LiveParsePlanReview()
    {
        foreach (var c in Cases(Live_["parsePlanReview"]))
        {
            var r = Core.Live.ParsePlanReview(c.Str("screen")!, AgentOf(c));
            JsonNode? actual = r == null ? null : new JsonObject { ["options"] = LiveJson.Strings(r.Options), ["current"] = r.Current };
            Same(c["result"], actual, Note(c));
        }
    }

    [Fact]
    public void LiveParseMenu()
    {
        foreach (var c in Cases(Live_["parseMenu"]))
        {
            var r = Core.Live.ParseMenu(c.Str("screen")!);
            JsonNode? actual = r == null
                ? null
                : new JsonObject
                {
                    ["title"] = r.Title,
                    ["items"] = new JsonArray(r.Items.Select(i => (JsonNode?)new JsonObject { ["label"] = i.Label, ["detail"] = i.Detail }).ToArray()),
                    ["current"] = r.Current,
                    ["filter"] = r.Filter,
                };
            Same(c["result"], actual, Note(c));
        }
    }

    [Fact]
    public void LiveAskOnScreen()
    {
        foreach (var c in Cases(Live_["askOnScreen"]))
            Assert.True(c.Bool("onScreen") == Core.Live.AskOnScreen(LiveAsk.FromJson(O(c["ask"])), c.Str("screen")!, AgentOf(c)), Note(c));
    }

    [Fact]
    public void LiveScreenDiff()
    {
        var sd = (JsonObject)Live_["screenDiff"]!;
        foreach (var c in Cases(sd["between"]))
        {
            var a = StringList(c["a"]);
            var b = StringList(c["b"]);
            var d = ScreenDiff.Between(a, b);
            Same(c["diff"], d?.ToJson(), Note(c));
            if (d != null) Same(c["applied"], LiveJson.Strings(d.Apply(a)!), Note(c) + " applied");
            else Assert.True(c["applied"] is null, Note(c));
        }
        foreach (var c in Cases(sd["apply"]))
        {
            var r = ScreenDiff.FromJson(O(c["diff"])).Apply(StringList(c["a"]));
            Same(c["result"], r == null ? null : LiveJson.Strings(r), Note(c));
        }
    }

    // ------------------------------------------------------------ models

    [Fact]
    public void LiveModels()
    {
        var m = (JsonObject)Live_["models"]!;
        void Each(string name, Func<JsonObject, JsonNode?> roundTrip)
        {
            foreach (var c in Cases(m[name])) Same(c["output"], roundTrip(c), $"{name}: {Note(c)}");
        }
        Each("LiveItem", c => LiveItem.FromJson(O(c["input"])).ToJson());
        Each("LiveQueued", c => LiveQueued.FromJson(O(c["input"])).ToJson());
        Each("LiveOp", c => LiveOp.FromJson(O(c["input"])).ToJson());
        Each("LiveAnswer", c => LiveAnswer.FromJson(O(c["input"])).ToJson());
        Each("LiveSummary", c => LiveSummary.FromJson(O(c["input"])).ToJson());
        Each("LiveView", c => c.Int("keep") is { } keep ? LiveView.FromJson(O(c["input"])).ToJson((int)keep) : LiveView.FromJson(O(c["input"])).ToJson());
        Each("ScreenDiff", c => ScreenDiff.FromJson(O(c["input"])).ToJson());
        Each("AgentIntegration", c => AgentIntegrations.ToJsonAll(AgentIntegrations.ParseAll(c["input"])));
        foreach (var c in Cases(m["LiveAsk"]))
        {
            var ask = LiveAsk.FromJson(O(c["input"]));
            Same(c["output"], ask.ToJson(), $"LiveAsk: {Note(c)}");
            Assert.True(c.Str("text") == ask.Text, $"LiveAsk text: {Note(c)}");
        }
    }

    // ------------------------------------------------------------ agent

    [Fact]
    public void LiveAgentVectors()
    {
        var a = (JsonObject)Live_["agent"]!;
        foreach (var c in Cases(a["agents"]))
        {
            var agent = DartEnum.Parse<Agent>(c["name"])!.Value;
            var n = c.Str("name");
            Assert.True(c.Str("label") == agent.Label(), n);
            Assert.True(c.Str("command") == agent.Command(), n);
            Assert.True(c.Bool("steers") == agent.Steers(), n);
            Assert.True(c.Str("resume") == agent.Resume(), n);
            Assert.True(c.Str("pickUp") == agent.PickUp(), n);
            foreach (var (p, val) in (JsonObject)c["commandIn"]!) Assert.True(DartJson.AsString(val) == agent.CommandIn(p), $"{n} commandIn {p}");
            foreach (var (p, val) in (JsonObject)c["labelIn"]!) Assert.True(DartJson.AsString(val) == agent.LabelIn(p), $"{n} labelIn {p}");
            foreach (var (p, val) in (JsonObject)c["resumeIn"]!) Assert.True(DartJson.AsString(val) == agent.ResumeIn(p), $"{n} resumeIn {p}");
            foreach (var (p, val) in (JsonObject)c["pickUpIn"]!) Assert.True(DartJson.AsString(val) == agent.PickUpIn(p), $"{n} pickUpIn {p}");
        }
        foreach (var c in Cases(a["parse"]))
            Assert.True(c.Str("agent") == Agents.Parse(c["input"]).Name(), $"{Note(c)}: {DartJson.Encode(c["input"])}");
        foreach (var c in Cases(a["ofProgram"]))
            Assert.True(c.Str("agent") == Agents.OfProgram(c.Str("input")!)?.Name(), $"{Note(c)}: {c.Str("input")}");
        foreach (var c in Cases(a["sessionOfTitle"]))
            Assert.True(c.Str("session") == AgentOf(c).SessionOfTitle(c.Str("title")!), $"{Note(c)}: {c.Str("title")}");
        foreach (var c in Cases(a["isOmpProfile"]))
            Assert.True(c.Bool("ok") == Agents.IsOmpProfile(c.Str("input")!), $"{Note(c)}: {c.Str("input")}");
        foreach (var c in Cases(a["ompProfileOfArgs"]))
            Assert.True(c.Str("profile") == Agents.OmpProfileOfArgs(c.Str("args")!), $"{Note(c)}: {c.Str("args")}");
    }

    // ------------------------------------------------------------ frames

    private static JsonArray Map(JsonNode? n, Func<JsonObject, JsonNode> f) => new(Cases(n).Select(x => (JsonNode?)f(O(x))).ToArray());

    [Fact]
    public void LiveFrames()
    {
        var fr = (JsonObject)Live_["frames"]!;
        foreach (var c in Cases(fr["channel"]))
        {
            var note = Note(c);
            var payload = (JsonObject)c["payload"]!;
            // Every payload is a JSON object that survives Dart's encoding as is.
            Assert.Equal(DartJson.Encode(payload), DartJson.Encode(DartJson.TryDecodeObject(DartJson.Encode(payload))));
            if (c["parsed"] is not JsonObject parsed) continue;
            var actual = new JsonObject();
            foreach (var (k, _) in parsed)
            {
                actual[k] = k switch
                {
                    "windows" => Map(payload["windows"], w => TermWindow.FromJson(w).ToJson()),
                    "terminals" => Map(payload["terminals"], t => TermStatus.FromJson(t).ToJson()),
                    "sessions" => Map(payload["sessions"], s => LiveSummary.FromJson(s).ToJson()),
                    "agents" => AgentIntegrations.ToJsonAll(AgentIntegrations.ParseAll(payload["agents"])),
                    "items" => Map(payload["items"], i => LiveItem.FromJson(i).ToJson()),
                    "ops" => Map(payload["ops"], o => LiveOp.FromJson(o).ToJson()),
                    _ => throw new InvalidOperationException($"{note}: unknown parsed key {k}"),
                };
            }
            Same(parsed, actual, note);
        }
        foreach (var c in Cases(fr["local"]))
        {
            var note = Note(c);
            var frame = (JsonObject)c["frame"]!;
            Assert.Equal(DartJson.Encode(frame), DartJson.Encode(DartJson.TryDecodeObject(DartJson.Encode(frame))));
            if (c["parsed"] is not JsonObject parsed) continue;
            var actual = new JsonObject();
            foreach (var (k, _) in parsed)
            {
                actual[k] = k switch
                {
                    "commands" => CommandsJson(Core.Live.LiveCommands(frame["commands"])),
                    "item" => LiveItem.FromJson(O(frame["item"])).ToJson(),
                    "ask" => frame["ask"] is JsonObject ask ? LiveAsk.FromJson(O(ask)).ToJson() : null,
                    _ => throw new InvalidOperationException($"{note}: unknown parsed key {k}"),
                };
            }
            Same(parsed, actual, note);
        }
    }
}
