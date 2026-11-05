using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PocketTerm.Core;

namespace PocketTerm.Core.Tests;

/// <summary>terminal_test.dart and windows_test.dart's logic.</summary>
public class TermLogicTests
{
    private const string Ps = """
        98233 94784 98233 98234 ttys009  Ss   login -pf me
        98234 98233 98234 98234 ttys009  S+   -zsh
        97914 97159 97914 97914 ttys010  Ss+  /usr/bin/login -flp me /bin/bash --noprofile --norc -c exec -l '/opt/homebrew/bin/tmux' 'attach-session' '-t' '=pt-mv82o7z3'
        97915 97914 97914 97914 ttys010  S+   -/opt/homebrew/bin/tmux attach-session -t =pt-mv82o7z3
         5150  5149  5150  5249 ttys008  Ss   -zsh
         5249  5150  5249  5249 ttys008  Rl+  omp --no-extensions -e /Users/me/live.ts
         7885 95874  7885     -1 ?        Rsl  /opt/homebrew/Cellar/omp/18.4.2/bin/omp __omp_worker_daemon_broker

        """;

    [Fact]
    public void ParsePsReadsEveryLineAMissingTtyAsEmpty()
    {
        var procs = Terminal.ParsePs(Ps);
        Assert.Equal([98233, 98234, 97914, 97915, 5150, 5249, 7885], procs.Select(p => p.Pid));
        var d = procs[^1];
        Assert.Equal((95874, 7885, -1, "", "Rsl"), (d.Ppid, d.Pgid, d.Tpgid, d.Tty, d.Stat));
        Assert.Equal("omp --no-extensions -e /Users/me/live.ts", procs[5].Args);
        var procsAll = new Procs(procs);
        Assert.Equal("zsh", procsAll.Foreground("ttys009")?.Program);
        Assert.Equal("omp", procsAll.Foreground("/dev/ttys008")?.Program);
        Assert.Null(procsAll.Foreground(""));
        Assert.True(procsAll.Running("-zsh"));
        Assert.Equal(98234, procsAll.PidOf("-zsh"));
    }

    [Fact]
    public void ParseTasklistEachProcessByPidAndImage()
    {
        const string tasklist = "\"System Idle Process\",\"0\",\"Services\",\"0\",\"8 K\"\n\"System\",\"4\",\"Services\",\"0\",\"2,404 K\"\n\"wezterm-gui.exe\",\"4242\",\"Console\",\"1\",\"98,120 K\"\n";
        var procs = new Procs(Terminal.ParseTasklist(tasklist));
        Assert.Equal([(0, "System Idle Process"), (4, "System"), (4242, "wezterm-gui.exe")], procs.All.Select(p => (p.Pid, p.Args)));
        Assert.Equal("wezterm-gui.exe", procs.ByPid(4242)?.Program);
        Assert.Empty(Terminal.ParseTasklist("INFO: No tasks are running which match the specified criteria.\n"));
    }

    [Fact]
    public void KeysAndChunks()
    {
        Assert.Equal("\u0003", Terminal.KeyBytes("ctrl+c"));
        Assert.Throws<TerminalException>(() => Terminal.KeyBytes("ctrl+shift+x"));
        Assert.Equal(["\u001b[A", "\u001b", "x"], Terminal.KeyRuns(["up", "esc", "x"]));
        Assert.Empty(Terminal.KeyRuns([]));

        var text = "ab漢👍🏽e\u0301" + new string('x', 20);
        var chunks = Terminal.TextChunks(text, 5);
        Assert.Equal(text, string.Concat(chunks));
        Assert.All(chunks, c => Assert.InRange(Encoding.UTF8.GetByteCount(c), 1, 5));
        Assert.Contains("👍", chunks);
        Assert.Empty(Terminal.TextChunks("", 5));
        Assert.Equal(["short"], Terminal.TextChunks("short", 100));
    }

    [Fact]
    public void ANewestLineLongerThanTheHistoryComesAsItsEnd()
    {
        var lines = Terminal.ScreenLines("older\n\u001b[38:2:1:2:3m" + new string('é', Terminal.HistoryBytes) + "\n\n");
        Assert.Single(lines);
        Assert.True(Encoding.UTF8.GetByteCount(lines[0]) < Terminal.HistoryBytes);
        Assert.EndsWith(new string('é', 100), lines[0], StringComparison.Ordinal);
        var colored = string.Concat(Enumerable.Repeat("\u001b[31mx", Terminal.HistoryBytes / 4));
        Assert.Matches(new Regex("^(\u001b\\[31m)?x(\u001b\\[31mx)*\\z"), Terminal.ScreenLines(colored).Single());
    }

    [Fact]
    public void ALongTitleIsCutNeverInsideAnEmoji()
    {
        var t = Terminal.CleanTitle(string.Concat(Enumerable.Repeat("👍", 1000)));
        Assert.Equal(Terminal.TitleRunes, t.EnumerateRunes().Count());
        Assert.EndsWith("👍\u2026", t, StringComparison.Ordinal);
        Assert.Equal(new string('t', Terminal.TitleRunes), Terminal.CleanTitle(new string('t', Terminal.TitleRunes)));
    }

    [Fact]
    public void AnOlderMacsWindowIsKittysAndCapsSurviveTheTrip()
    {
        var w = TermWindow.FromJson(new JsonObject { ["key"] = "kitty-1/2", ["title"] = "t", ["program"] = "claude" });
        Assert.Equal("kitty", w.App);
        Assert.True(TermCaps.All.SetEquals(w.Caps));
        Assert.Equal(Agent.Claude, w.Agent);

        var tmux = new TermWindow
        {
            Key = "tmux:default/0", Title = "x", Tab = "s:w", Cwd = "/x", Program = "zsh", App = "tmux", Via = "Ghostty",
            Caps = new HashSet<TermCap> { TermCap.Type, TermCap.Keys },
        };
        var json = tmux.ToJson();
        ((JsonArray)json["caps"]!).Add("teleport");
        var back = TermWindow.FromJson(json);
        Assert.Equal(("tmux", "Ghostty"), (back.App, back.Via));
        Assert.True(back.Caps.SetEquals([TermCap.Type, TermCap.Keys]));
        Assert.Equal("p", (tmux with { Profile = "p" }).ToJson().Str("profile"));
        Assert.Throws<InvalidCastException>(() => TermWindow.FromJson(new JsonObject { ["title"] = "no key" }));
    }

    [Fact]
    public void HomeDirByPlatform()
    {
        var env = new Dictionary<string, string> { ["HOME"] = "/Users/me", ["USERPROFILE"] = @"C:\Users\me" };
        Assert.Equal(@"C:\Users\me", Terminal.HomeDir(env, windows: true));
        Assert.Equal("/Users/me", Terminal.HomeDir(env, windows: false));
        Assert.Equal("", Terminal.HomeDir(new Dictionary<string, string>(), windows: true));
    }

    [Fact]
    public void FindExecutableOnWindowsExeThenExtraThenCmdNeverTheBareName()
    {
        var dir = Directory.CreateTempSubdirectory("pocketterm-exe");
        try
        {
            var npm = Directory.CreateDirectory(Path.Combine(dir.FullName, "npm")).FullName;
            var bin = Directory.CreateDirectory(Path.Combine(dir.FullName, "bin")).FullName;
            File.Create(Path.Combine(npm, "claude")).Dispose();
            File.Create(Path.Combine(npm, "claude.cmd")).Dispose();
            var native = Path.Combine(dir.FullName, "claude.exe");
            File.Create(native).Dispose();
            var env = new Dictionary<string, string> { ["PATH"] = string.Join(';', Path.Combine(dir.FullName, "missing"), npm, $"\"{bin}\"") };
            string? Find(string[] extra) => Terminal.FindExecutable("claude", extra, env, windows: true);

            Assert.Equal(Path.Combine(npm, "claude.cmd"), Find([]));
            Assert.Equal(native, Find([native]));
            File.Create(Path.Combine(bin, "claude.exe")).Dispose();
            Assert.Equal(Path.Combine(bin, "claude.exe"), Find([native]));
            Assert.Null(Terminal.FindExecutable("kitty", env: env, windows: true));
        }
        finally
        {
            dir.Delete(recursive: true);
        }
    }

    [Fact]
    public void MergeWindowsPathSystemThenUserThenProcess()
    {
        Assert.Equal(
            string.Join(';', @"C:\Windows\system32", @"C:\Windows", @"C:\Program Files\Git\cmd", @"C:\Users\x\.local\bin",
                @"C:\Users\x\AppData\Roaming\npm", @"C:\Users\x\AppData\Local\Temp\pocketterm-dev"),
            Terminal.MergeWindowsPath(
                machine: @"C:\Windows\system32;C:\Windows;""C:\Program Files\Git\cmd""",
                user: @"C:\Users\x\.local\bin;C:\Users\x\AppData\Roaming\npm;;",
                current: @"C:\WINDOWS\system32\;C:\Windows;C:\Users\x\AppData\Local\Temp\pocketterm-dev"));
        Assert.Equal(@"C:\a;C:\b", Terminal.MergeWindowsPath(@"C:\a;C:\b"));
    }

    [Fact]
    public void WindowsFileNameRefusesWhatWindowsChanges()
    {
        foreach (var ok in new[] { "app", "my app", "CONSOLE", "con-app", "nul2", "Jürgen", "a.b", "com10" })
            Assert.True(Terminal.WindowsFileName(ok), ok);
        foreach (var bad in new[] { "a<b", "a>b", "a\"b", "a|b", "a?", "a*", "app.", "app ", "CON", "con.txt", "Nul", "COM1", "lpt9.md" })
            Assert.False(Terminal.WindowsFileName(bad), bad);
    }

    [Fact]
    public async Task SendTypesLinesWithShiftEnterBetween()
    {
        var host = new RecordingHost();
        await host.SendAsync("k", "a\r\nb\rc\n", enter: true);
        Assert.Equal(["type a", "keys shift+enter", "type b", "keys shift+enter", "type c", "keys shift+enter", "keys enter"], host.Calls);
        Assert.Equal("Rec can't close its windows.", (await Assert.ThrowsAsync<TerminalException>(() => host.CloseAsync("k"))).Message);
    }

    private sealed class RecordingHost : TerminalHost
    {
        public List<string> Calls { get; } = [];
        public override string Id => "rec";
        public override string Label => "Rec";
        public override IReadOnlySet<TermCap> Caps => TermCaps.All;
        public override string? AppName => null;
        public override bool Owns(string key) => true;
        public override Task<TermStatus> StatusAsync(Procs procs) => Task.FromResult(new TermStatus("rec", "Rec", TermState.Ready));
        public override Task<IReadOnlyList<TermWindow>> WindowsAsync(Procs procs) => Task.FromResult<IReadOnlyList<TermWindow>>([]);
        public override Task<string> LaunchAsync(string cwd, IReadOnlyList<string>? command = null, string? into = null) => Task.FromResult("k");

        public override Task TypeAsync(string key, string text)
        {
            Calls.Add($"type {text}");
            return Task.CompletedTask;
        }

        public override Task PressKeysAsync(string key, IReadOnlyList<string> names)
        {
            Calls.Add($"keys {string.Join(',', names)}");
            return Task.CompletedTask;
        }
    }
}

/// <summary>ansi_test.dart.</summary>
public class TermAnsiTests
{
    private static readonly TermColors C = TermColors.Fallback;

    private static string Text(string s) => string.Concat(Ansi.Spans(s, C).Select(x => x.Text));

    [Fact]
    public void TruecolorInBothForms()
    {
        var spans = Ansi.Spans("\u001b[38:2:0:180:255ma\u001b[38;2;1;2;3;48;5;196mb\u001b[0mc", C);
        Assert.Equal(0xFF00B4FFu, spans[0].Fg);
        Assert.Equal(0xFF010203u, spans[1].Fg);
        Assert.Equal(C.Palette[196], spans[1].Bg);
        Assert.Equal(C.Foreground, spans[2].Fg);
        Assert.Null(spans[2].Bg);
    }

    [Fact]
    public void AttributesAndColors()
    {
        var spans = Ansi.Spans("\u001b[1;31ma\u001b[22;39;94mb", C);
        Assert.True(spans[0].Bold);
        Assert.Equal(C.Palette[1], spans[0].Fg);
        Assert.False(spans[1].Bold);
        Assert.Equal(C.Palette[12], spans[1].Fg);
    }

    [Fact]
    public void OtherEscapesLeaveOnlyText()
    {
        Assert.Equal("link end", Text("\u001b]133;A\u001b\\\u001b]8;id=1;file:///x\u001b\\link\u001b]8;;\u001b\\ \u001b[2Kend"));
        Assert.Equal("abc", Text("\u001b(B\u001b[32ma\u001b(0\u001b#8b\u001b7c"));
        foreach (var cut in new[] { "\u001b]8;;https://example.com/a", "\u001b[38;2;1", "\u001b" })
            Assert.Equal("text", Text("text" + cut));
        Assert.Equal("red", Text("\u001b]0;title\u001b[31mred"));
        Assert.Equal("abc", Text("a\u001b_Gf=100,a=T;iVBORw0KGgo=\u001b\\b\u001bPtmux;\u001b\u001b]52;c;eA==\u0007\u001b\\c"));
        var spans = Ansi.Spans("\u001b[?2004h\u001b[>4;2m\u001b[=1;u\u001b[38;5ma\u001b[48;5;999mb", C);
        Assert.Equal("ab", string.Concat(spans.Select(s => s.Text)));
        Assert.Null(spans[^1].Bg);
    }
}

/// <summary>theme_test.dart and app_icon_test.dart, the data parts.</summary>
public class TermThemeTests
{
    [Fact]
    public void SystemUntilPickedThePickedOneKept()
    {
        var prefs = new MemoryPreferenceStore();
        var first = new Appearance();
        first.Load(prefs);
        Assert.Equal(ThemeChoice.System, first.Choice);
        Assert.Same(PtTheme.SystemLight, first.Theme);
        Assert.Null(prefs.GetString(Appearance.PrefsKey));
        var changes = 0;
        first.PropertyChanged += (_, _) => changes++;
        first.Choose(ThemeChoice.RosePine);
        first.Choose(ThemeChoice.RosePine);
        Assert.Equal(1, changes);
        Assert.Same(PtTheme.Dawn, first.Theme);
        Assert.Equal("rosePine", prefs.GetString(Appearance.PrefsKey));
        var next = new Appearance();
        next.Load(prefs);
        Assert.Equal(ThemeChoice.RosePine, next.Choice);
    }

    [Theory]
    [InlineData("mocha", ThemeChoice.Catppuccin)]
    [InlineData("auto", ThemeChoice.Catppuccin)]
    [InlineData("gruvbox", ThemeChoice.Catppuccin)]
    [InlineData("dawn", ThemeChoice.RosePine)]
    [InlineData("tokyoNight", ThemeChoice.TokyoNight)]
    [InlineData("solarized", ThemeChoice.System)]
    [InlineData("system", ThemeChoice.System)]
    [InlineData("catppuccin", ThemeChoice.Catppuccin)]
    public void AnEarlierVersionsNameMovesToItsFamilyAndIsKeptSo(string kept, ThemeChoice want)
    {
        var prefs = new MemoryPreferenceStore();
        prefs.SetString(Appearance.PrefsKey, kept);
        var a = new Appearance();
        a.Load(prefs);
        Assert.Equal(want, a.Choice);
        Assert.Equal(want.Name(), prefs.GetString(Appearance.PrefsKey));
    }

    [Fact]
    public void ThePaletteFollowsWindowsAppearance()
    {
        var a = new Appearance();
        a.Load(new MemoryPreferenceStore());
        a.Choose(ThemeChoice.Catppuccin);
        Assert.Same(PtTheme.Latte, a.Theme);
        var changes = 0;
        a.PropertyChanged += (_, _) => changes++;
        a.Follow(dark: true);
        a.Follow(dark: true);
        Assert.Equal(1, changes);
        Assert.Same(PtTheme.Mocha, a.Theme);
        a.Choose(ThemeChoice.TokyoNight);
        Assert.Same(PtTheme.TokyoNight, a.Theme);
        a.Follow(dark: false);
        Assert.Same(PtTheme.TokyoNightDay, a.Theme);
    }

    [Fact]
    public void EveryFamilyHasALightAndADarkHalf()
    {
        Assert.Equal(["System", "Catppuccin", "Rosé Pine", "Tokyo Night"], Enum.GetValues<ThemeChoice>().Select(c => c.Label()));
        Assert.Equal(["system", "catppuccin", "rosePine", "tokyoNight"], Enum.GetValues<ThemeChoice>().Select(c => c.Name()));
        foreach (var c in Enum.GetValues<ThemeChoice>())
        {
            Assert.False(c.Light().Dark);
            Assert.True(c.Dark().Dark);
            Assert.Same(c.Dark(), c.Palette(dark: true));
            Assert.Same(c.Light(), c.Palette(dark: false));
            Assert.Equal(c == ThemeChoice.System, c.Light().PlatformAccent);
            Assert.Equal(c == ThemeChoice.System, c.Dark().PlatformAccent);
            Assert.Equal(16, c.Light().Ansi.Count);
            Assert.Equal(16, c.Dark().Ansi.Count);
        }
    }

    [Fact]
    public void SystemIsBlackOnWhiteOrLightOnNearBlackWithXtermsColors()
    {
        Assert.Equal(0xFFFFFFFFu, PtTheme.SystemLight.Win);
        Assert.Equal(0xFF000000u, PtTheme.SystemLight.Text);
        Assert.Equal(0xFF1E1E1Eu, PtTheme.SystemDark.Win);
        Assert.Equal(PtTheme.SystemLight.Ansi, PtTheme.SystemDark.Ansi);
        Assert.Equal(0xFFCD0000u, PtTheme.SystemDark.Ansi[1]);
        Assert.Equal(0xFF5C5CFFu, PtTheme.SystemDark.Ansi[12]);
    }

    [Fact]
    public void OfficialPaletteSpotChecksTheSameAsTheSwiftAndKotlinCores()
    {
        Assert.Equal(0xFFEFF1F5u, PtTheme.Latte.Win);
        Assert.Equal(0xFFCBA6F7u, PtTheme.Mocha.Accent);
        Assert.Equal(0xFF575279u, PtTheme.Dawn.Text);
        Assert.Equal(0xFF191724u, PtTheme.RosePine.Win);
        Assert.Equal(0xFFE1E2E7u, PtTheme.TokyoNightDay.Win);
        Assert.Equal(0xFFFF899Du, PtTheme.TokyoNight.Ansi[9]);
    }

    [Fact]
    public void APalettesTerminalColors()
    {
        var colors = PtTheme.Mocha.TermColors;
        Assert.Equal(PtTheme.Mocha.Text, colors.Foreground);
        Assert.Equal(PtTheme.Mocha.Win, colors.Background);
        Assert.Equal(256, colors.Palette.Count);
        Assert.Equal(PtTheme.Mocha.Ansi, colors.Palette.Take(16));
        Assert.Equal(TermColors.Fallback.Palette.Skip(16), colors.Palette.Skip(16));
    }

    [Fact]
    public async Task TheIconFollowsThePickedTheme()
    {
        var prefs = new MemoryPreferenceStore();
        prefs.SetString(Appearance.PrefsKey, "tokyoNight");
        var a = new Appearance();
        a.Load(prefs);
        var applied = new List<string>();
        var stop = AppIcon.Follow(a, icon => { applied.Add(icon); return Task.CompletedTask; });
        Assert.Equal(["tokyoNight"], applied);
        a.Choose(ThemeChoice.Catppuccin);
        // System shows the same icon as Catppuccin: nothing to change; an appearance change neither.
        a.Choose(ThemeChoice.System);
        a.Follow(dark: true);
        a.Choose(ThemeChoice.RosePine);
        Assert.Equal(["tokyoNight", "default", "dawn"], applied);
        stop();
        a.Choose(ThemeChoice.TokyoNight);
        Assert.Equal(3, applied.Count);
        Assert.Equal(["default", "default", "dawn", "tokyoNight"], Enum.GetValues<ThemeChoice>().Select(AppIcon.For));

        // A platform without the switch does not break the theme change.
        var b = new Appearance();
        b.Load(new MemoryPreferenceStore());
        AppIcon.Follow(b, _ => throw new NotSupportedException("no icons here"));
        b.Choose(ThemeChoice.RosePine);
        await Task.Yield();
        Assert.Equal(ThemeChoice.RosePine, b.Choice);
    }
}
