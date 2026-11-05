using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using PocketTerm.Core;

namespace PocketTerm.Core.Tests;

/// <summary>The <c>terminal</c>, <c>ansi</c> and <c>fileTypes</c> vector sections, and
/// <c>live.models.TermWindow</c> / <c>TermStatus</c>.</summary>
public class TermVectorTests
{
    private static JsonObject T => Vectors.Section("terminal");

    private static IEnumerable<JsonObject> Cases(JsonNode? list) => ((JsonArray)list!).Select(c => (JsonObject)c!);

    private static JsonArray Strings(IEnumerable<string> items) => new(items.Select(s => (JsonNode?)s).ToArray());

    private static List<string> ToStrings(JsonNode? list) => ((JsonArray)list!).Select(n => (string)n!).ToList();

    [Fact]
    public void WindowOfTerm()
    {
        foreach (var c in Cases(T["windowOfTerm"]))
        {
            Assert.True(c.Str("window") == Terminal.WindowOfTerm(c["term"] as JsonObject), c.Str("note"));
        }
    }

    [Fact]
    public void TmuxSocketName()
    {
        foreach (var c in Cases(T["tmuxSocketName"]))
        {
            Assert.True(c.Bool("ok") == Terminal.TmuxSocketName(c.Str("name")!), $"{c.Str("note")}: {c.Str("name")}");
        }
    }

    [Fact]
    public void KeyBytes()
    {
        foreach (var c in Cases(T["keyBytes"]))
        {
            var name = c.Str("name")!;
            if (c.Str("error") is { } error)
            {
                var e = Assert.Throws<TerminalException>(() => Terminal.KeyBytes(name));
                Assert.Equal(error, e.Message);
                continue;
            }
            var bytes = Terminal.KeyBytes(name);
            Assert.True(c.Str("bytes") == bytes, $"{c.Str("note")}: {name}");
            Assert.Equal(c.Str("hex"), Convert.ToHexString(Encoding.UTF8.GetBytes(bytes)).ToLowerInvariant());
        }
    }

    [Fact]
    public void KeyRunsAndPhoneKeys()
    {
        foreach (var c in Cases(T["keyRuns"]))
        {
            Vectors.AssertJson(c["runs"], Strings(Terminal.KeyRuns(ToStrings(c["names"]))), c.Str("note"));
        }
        Vectors.AssertJson(T["phoneKeys"], Strings(Terminal.PhoneKeys));
    }

    [Fact]
    public void TextChunks()
    {
        foreach (var c in Cases(T["textChunks"]))
        {
            Vectors.AssertJson(
                c["chunks"], Strings(Terminal.TextChunks(Vectors.Text(c["text"]), (int)c.Int("maxBytes")!)), c.Str("note"));
        }
    }

    [Fact]
    public void CleanTitle()
    {
        var s = T.Obj("cleanTitle")!;
        Assert.Equal(s.Int("titleRunes"), Terminal.TitleRunes);
        foreach (var c in Cases(s["cases"]))
        {
            Assert.True(c.Str("title") == Terminal.CleanTitle(Vectors.Text(c["input"])), c.Str("note"));
        }
    }

    [Fact]
    public void ScreenLines()
    {
        var s = T.Obj("screenLines")!;
        Assert.Equal(s.Int("historyBytes"), Terminal.HistoryBytes);
        foreach (var c in Cases(s["cases"]))
        {
            Vectors.AssertJson(c["lines"], Strings(Terminal.ScreenLines(Vectors.Text(c["input"]))), c.Str("note"));
        }
        foreach (var c in Cases(s["long"]))
        {
            var lines = Terminal.ScreenLines(Vectors.Text(c["input"]));
            var want = Cases(c["lines"]).ToList();
            Assert.True(want.Count == lines.Count, c.Str("note"));
            for (var i = 0; i < lines.Count; i++)
            {
                var line = lines[i];
                var w = want[i];
                var utf8 = Encoding.UTF8.GetBytes(line);
                Assert.Equal(w.Int("codeUnits"), line.Length);
                Assert.Equal(w.Int("utf8Bytes"), utf8.Length);
                Assert.Equal(w.Str("sha256"), Convert.ToHexString(SHA256.HashData(utf8)).ToLowerInvariant());
                var runes = line.EnumerateRunes().Select(r => r.ToString()).ToList();
                Assert.Equal(w.Str("head"), string.Concat(runes.Take(40)));
                Assert.Equal(w.Str("tail"), string.Concat(runes.Skip(runes.Count - 40)));
            }
        }
    }

    [Fact]
    public void Processes()
    {
        var p = T.Obj("processes")!;
        static JsonObject ProcJson(Proc x) => new()
        {
            ["pid"] = x.Pid, ["ppid"] = x.Ppid, ["pgid"] = x.Pgid, ["tpgid"] = x.Tpgid,
            ["tty"] = x.Tty, ["stat"] = x.Stat, ["args"] = x.Args, ["program"] = x.Program,
        };
        var ps = p.Obj("parsePs")!;
        var parsed = Terminal.ParsePs(ps.Str("input")!);
        Vectors.AssertJson(ps["procs"], new JsonArray(parsed.Select(x => (JsonNode?)ProcJson(x)).ToArray()), ps.Str("note"));

        var procs = new Procs(parsed);
        foreach (var c in Cases(p["foreground"]))
        {
            Assert.True(c.Int("pid") == procs.Foreground(c.Str("tty")!)?.Pid, $"{c.Str("note")}: {c.Str("tty")}");
        }

        var tl = p.Obj("parseTasklist")!;
        Vectors.AssertJson(
            tl["procs"],
            new JsonArray(Terminal.ParseTasklist(tl.Str("input")!).Select(x => (JsonNode?)ProcJson(x)).ToArray()),
            tl.Str("note"));

        foreach (var c in Cases(p["parseLsofCwd"]))
        {
            var o = new JsonObject();
            foreach (var (pid, dir) in Terminal.ParseLsofCwd(c.Str("input")!)) o[pid.ToString()] = dir;
            Vectors.AssertJson(c["cwds"], o, c.Str("note"));
        }
        foreach (var c in Cases(p["programOf"]))
        {
            Assert.True(c.Str("program") == Terminal.ProgramOf(c.Str("args")!), $"{c.Str("note")}: {c.Str("args")}");
        }
        foreach (var c in Cases(p["programOfTitle"]))
        {
            Assert.True(c.Str("program") == Terminal.ProgramOfTitle(c.Str("title")!), $"{c.Str("note")}: {c.Str("title")}");
        }
        foreach (var c in Cases(p["utf8Locale"]))
        {
            var env = c.Obj("env")!.ToDictionary(kv => kv.Key, kv => (string)kv.Value!);
            var o = new JsonObject();
            foreach (var (k, v) in Terminal.Utf8Locale(env)) o[k] = v;
            Vectors.AssertJson(c["add"], o, c.Str("note"));
        }
    }

    [Fact]
    public void WindowsHelpers()
    {
        var w = T.Obj("windows")!;
        foreach (var c in Cases(w["windowsFileName"]))
        {
            Assert.True(c.Bool("ok") == Terminal.WindowsFileName(c.Str("name")!), $"{c.Str("note")}: {c.Str("name")}");
        }
        foreach (var c in Cases(w["windowsPathDirs"]))
        {
            Vectors.AssertJson(c["dirs"], Strings(Terminal.WindowsPathDirs(c.Str("path")!)), c.Str("note"));
        }
        foreach (var c in Cases(w["mergeWindowsPath"]))
        {
            Assert.True(
                c.Str("merged") == Terminal.MergeWindowsPath(c.Str("current")!, c.Str("machine"), c.Str("user")), c.Str("note"));
        }
        foreach (var c in Cases(w["windowsCommand"]))
        {
            var (program, argv) = Terminal.WindowsCommand(c.Str("executable")!, ToStrings(c["arguments"]));
            Assert.True(c.Str("program") == program, c.Str("note"));
            Vectors.AssertJson(c["argv"], Strings(argv), c.Str("note"));
        }
    }

    [Fact]
    public void ShellQuote()
    {
        foreach (var c in Cases(T["shellQuote"]))
        {
            Assert.True(c.Str("quoted") == Terminal.ShellQuote(c.Str("input")!), c.Str("note"));
        }
    }

    [Fact]
    public void Caps()
    {
        var c = T.Obj("caps")!;
        Vectors.AssertJson(c["all"], Strings(Enum.GetValues<TermCap>().Select(x => x.Name())));
        Vectors.AssertJson(c["allCaps"], Strings(Enum.GetValues<TermCap>().Where(TermCaps.All.Contains).Select(x => x.Name())));
        Assert.Equal(6, TermCaps.All.Count);
        Vectors.AssertJson(c["termStates"], Strings(Enum.GetValues<TermState>().Select(x => x.Name())));
        foreach (var p in Cases(c["placement"]))
        {
            var placement = DartEnum.Parse<Placement>(p.Str("name"))!.Value;
            Assert.Equal(p.Str("describe"), placement.Describe());
        }
        Assert.Equal(2, Cases(c["placement"]).Count());
    }

    [Fact]
    public void LiveModels()
    {
        var models = Vectors.Section("live").Obj("models")!;
        foreach (var c in Cases(models["TermWindow"]))
        {
            var w = TermWindow.FromJson((JsonObject)c["input"]!);
            Vectors.AssertJson(c["output"], w.ToJson(), c.Str("note"));
            Assert.True(c.Str("agent") == w.Agent?.Name(), c.Str("note"));
        }
        foreach (var c in Cases(models["TermStatus"]))
        {
            Vectors.AssertJson(c["output"], TermStatus.FromJson((JsonObject)c["input"]!).ToJson(), c.Str("note"));
        }
    }

    [Fact]
    public void AnsiSpans()
    {
        var a = Vectors.Section("ansi");
        var colors = a.Obj("colors")!;
        var fb = TermColors.Fallback;
        Assert.Equal(colors.Str("foreground"), Argb.Hex(fb.Foreground));
        Assert.Equal(colors.Str("background"), Argb.Hex(fb.Background));
        Vectors.AssertJson(colors["palette"], Strings(fb.Palette.Select(Argb.Hex)));

        var fj = a.Obj("termColorsFromJson")!;
        var parsed = TermColors.FromJson((JsonObject)fj["input"]!);
        Assert.Equal(fj.Str("foreground"), Argb.Hex(parsed.Foreground));
        Assert.Equal(fj.Str("background"), Argb.Hex(parsed.Background));
        Vectors.AssertJson(fj["palette"], Strings(parsed.Palette.Select(Argb.Hex)));

        foreach (var c in Cases(a["cases"]))
        {
            var spans = new JsonArray(Ansi.Spans(Vectors.Text(c["input"]), fb).Select(s => (JsonNode?)new JsonObject
            {
                ["text"] = s.Text,
                ["fg"] = Argb.Hex(s.Fg),
                ["bg"] = s.Bg is { } bg ? Argb.Hex(bg) : null,
                ["bold"] = s.Bold,
                ["italic"] = s.Italic,
                ["decoration"] = s.Decoration?.Name(),
            }).ToArray());
            Vectors.AssertJson(c["spans"], spans, c.Str("note"));
        }
    }

    [Fact]
    public void FileTypesVectors()
    {
        var f = Vectors.Section("fileTypes");
        foreach (var c in Cases(f["byName"]))
        {
            var name = c.Str("name")!;
            Assert.True(c.Str("extension") == FileTypes.FileExtension(name), $"{c.Str("note")}: {name}");
            Assert.True(c.Str("mime") == FileTypes.FileMime(name), $"{c.Str("note")}: {name}");
        }
        foreach (var c in Cases(f["extensionOf"]))
        {
            Assert.True(c.Str("extension") == FileTypes.MimeExtension(c.Str("mime")!), $"{c.Str("note")}: {c.Str("mime")}");
        }
    }
}
