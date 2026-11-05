using System.Text;
using System.Text.Json.Nodes;
using PocketTerm.Core;

namespace PocketTerm.Desktop.Tests;

// Dart test/terminal_bridge_test.dart. Windows has WezTerm only, so the Dart test's kitty and Ghostty are fake
// hosts with their labels and caps; the Mac's tmux branch of cantAnswer has no counterpart here (no tmux host).
public class TerminalBridgeTests
{
    private const string GhosttyKey = "ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074";

    /// <summary>Terminals that touch nothing on this computer: a kitty-like host that can do everything, and a
    /// Ghostty-like one that can't show its screen.</summary>
    private static Terminals Terms(BridgeFakeHost? kitty = null, BridgeFakeHost? ghostty = null, Func<Task<Procs>>? snapshot = null) =>
        new("/nonexistent-pocketterm", [kitty ?? BridgeFakeHost.Kitty([]), ghostty ?? BridgeFakeHost.Ghostty()], snapshot ?? (() => Task.FromResult(new Procs([]))));

    private static int Size(JsonNode? json) => DartJson.EncodeUtf8(json).Length;

    [Fact]
    public void AnsweringWorksWhereTheScreenCanBeReadAndKeysPressed()
    {
        var terms = Terms();
        foreach (var key in new[] { "kitty-1/2", "kitty-3/0" }) Assert.Null(BridgeHelpers.CantAnswer(terms, key));
    }

    [Fact]
    public void AnsweringWhereTheTerminalCantShowItsScreenSaysTmuxIsTheWayOut()
    {
        var ghostty = BridgeHelpers.CantAnswer(Terms(), GhosttyKey)!;
        Assert.StartsWith("Ghostty can't show its screen", ghostty);
        Assert.Contains("brew install tmux", ghostty);
        Assert.StartsWith("This terminal can't show its screen", BridgeHelpers.CantAnswer(Terms(), "nowhere:1"));
    }

    [Fact]
    public void ThePhoneHearsOfInstalledTerminalsAndOfTmuxEvenWhenMissing()
    {
        TermStatus[] statuses =
        [
            new("kitty", "kitty", TermState.Ready),
            new("tmux", "tmux", TermState.Missing, Note: "Install tmux"),
            new("wezterm", "WezTerm", TermState.Missing),
            new("ghostty", "Ghostty", TermState.Limited),
        ];
        Assert.Equal(["kitty", "tmux", "ghostty"], BridgeHelpers.PhoneTerminals(statuses).Select(s => s.Id));
    }

    private static readonly JsonArray CmdsTemplate = new([.. Enumerable.Range(0, 90).Select(i =>
        (JsonNode)new JsonArray($"command-{i}", $"What command {i} does, in up to eighty characters or so, as omp says"))]);

    private static JsonObject State(int sessions = 60, int projects = 5000, int windows = 80) => new()
    {
        ["windows"] = new JsonArray([.. Enumerable.Range(0, windows).Select(i => (JsonNode)new JsonObject
        {
            ["key"] = $"kitty-1/{i}",
            ["title"] = $"π > 中文 window {i} 😀",
            ["cwd"] = $"/Users/me/p {i}",
        })]),
        ["sessions"] = new JsonArray([.. Enumerable.Range(0, sessions).Select(i => (JsonNode)new JsonObject
        {
            ["key"] = $"kitty-1/{i}",
            ["id"] = $"s{i}",
            ["title"] = $"Fix {i}",
            ["cmds"] = CmdsTemplate.DeepClone(),
        })]),
        ["projects"] = new JsonArray([.. Enumerable.Range(0, projects).Select(i => (JsonNode)$"/Users/me/Dev/some-organisation/project-number-{i}")]),
        ["home"] = "/Users/me",
    };

    [Fact]
    public void ASmallStateGoesAsItIs()
    {
        var s = State(sessions: 2, projects: 10);
        Assert.Same(s, TerminalBridge.FitState(s, new HashSet<string>()));
    }

    [Fact]
    public void ManySessionsAndRepositoriesUnwatchedCommandsGoFirstThenRepositoriesPastWhatFits()
    {
        var fit = TerminalBridge.FitState(State(), new HashSet<string> { "kitty-1/3" });
        Assert.True(Size(fit) <= 150000);
        var sessions = fit["sessions"]!.AsArray().Select(s => s!.AsObject()).ToList();
        Assert.Equal(60, sessions.Count); // every session is still listed
        Assert.Equal(["kitty-1/3"], sessions.Where(s => s["cmds"] != null).Select(s => (string)s["key"]!));
        Assert.Equal(DartJson.Encode(CmdsTemplate), DartJson.Encode(sessions[3]["cmds"])); // the watched one keeps them whole
        Assert.Equal(80, fit["windows"]!.AsArray().Count);
        var projects = fit["projects"]!.AsArray();
        Assert.NotEmpty(projects);
        Assert.True(projects.Count < 5000);
        Assert.Equal("/Users/me/Dev/some-organisation/project-number-0", (string)projects[0]!);
    }

    [Fact]
    public void WithNothingElseLeftToCutWindowsGoFromTheEnd()
    {
        var fit = TerminalBridge.FitState(State(windows: 4000, projects: 0), new HashSet<string>(), maxBytes: 100000);
        Assert.True(Size(fit) <= 100000);
        Assert.Equal("kitty-1/0", (string)fit["windows"]![0]!["key"]!);
    }

    [Fact]
    public void UnwatchedQueuedPromptsKeepTheirStartBeforeAnythingAPhoneShowsGoes()
    {
        var longText = string.Join(' ', Enumerable.Repeat("word", 4000));
        var s = State(sessions: 8, projects: 100);
        foreach (var session in s["sessions"]!.AsArray().Select(x => x!.AsObject()))
        {
            session["queue"] = new JsonArray([.. Enumerable.Range(0, 4).Select(i => (JsonNode)new JsonObject
            {
                ["id"] = $"{session["key"]}-{i}",
                ["t"] = longText,
                ["im"] = 1,
            })]);
        }
        var fit = TerminalBridge.FitState(s, new HashSet<string> { "kitty-1/3" });
        Assert.True(Size(fit) <= 150000);
        var sessions = fit["sessions"]!.AsArray().Select(x => x!.AsObject()).ToList();
        var watched = sessions[3]["queue"]!.AsArray().Select(q => q!.AsObject()).ToList();
        Assert.All(watched, q => Assert.Equal(longText, (string)q["t"]!)); // the session a phone shows keeps them whole
        Assert.All(watched, q => Assert.Null(q["c"]));
        var other = LiveSummary.FromJson(sessions[0]).Queue;
        Assert.All(other, q => Assert.True(q.Cut));
        Assert.StartsWith("word word", other[0].Text);
        Assert.True(other[0].Text.Length < longText.Length);
        Assert.Equal(1, other[0].Images);
        Assert.Equal(100, fit["projects"]!.AsArray().Count); // nothing else had to go
    }

    [Fact]
    public void AScreenKeepsItsNewestLinesAndASingleLineTooLongKeepsItsStart()
    {
        var lines = Enumerable.Range(0, 5000).Select(i => $"\u001b[38;2;1;2;3m{i} 中文 😀\u001b[0m").ToList();
        var fit = TerminalBridge.FitLines(lines, 60000);
        Assert.True(Size(new JsonArray([.. fit.Select(l => (JsonNode)l)])) <= 60000);
        Assert.Equal(lines[^1], fit[^1]);
        Assert.Equal(lines.Skip(lines.Count - fit.Count), fit);
        var longLine = TerminalBridge.FitLines([new string('x', 200000)], 60000);
        Assert.True(Size(new JsonArray([.. longLine.Select(l => (JsonNode)l)])) <= 60000);
        Assert.StartsWith("xxx", Assert.Single(longLine));
        Assert.Empty(TerminalBridge.FitLines([], 60000));
    }

    [Fact]
    public void AnErrorOnlyWhenNothingShowsAndNoTerminalIsUsable()
    {
        var setup = new TermStatus("kitty", "kitty", TermState.Setup, Note: "kitty isn't listening.");
        var idle = new TermStatus("ghostty", "Ghostty", TermState.Idle);
        var limited = new TermStatus("wezterm", "WezTerm", TermState.Limited);
        Assert.Equal("kitty isn't listening.", BridgeHelpers.TerminalsError([idle, setup], nothingShown: true));
        Assert.Null(BridgeHelpers.TerminalsError([idle, setup], nothingShown: false));
        Assert.Null(BridgeHelpers.TerminalsError([setup, limited], nothingShown: true));
        Assert.Null(BridgeHelpers.TerminalsError([idle], nothingShown: true));
    }

    [Fact]
    public void ASlashCommandForASessionInNoTerminalPocketTermDrivesIsRefused()
    {
        var terms = Terms();
        foreach (var key in new[] { "kitty-1/2", GhosttyKey }) Assert.Null(BridgeHelpers.CantCommand(terms, key));
        Assert.StartsWith("Slash commands are typed into the agent's terminal window", BridgeHelpers.CantCommand(terms, null));
        Assert.Equal(
            "This terminal can't take a typed line, so run the command on the computer.",
            BridgeHelpers.CantCommand(terms, "nowhere:1"));
    }

    [Fact]
    public async Task APhoneImageGoesAsPngOrJpegOffTheMacNothingElse()
    {
        byte[] png = [0x89, 0x50, 0x4E, 0x47, 0x0D];
        byte[] jpeg = [0xFF, 0xD8, 0xFF, 0xE0];
        byte[] heic = [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63];
        Assert.Equal("image/png", (await TerminalBridge.ImageAsync(png, macos: false)).MimeType);
        Assert.Equal("image/jpeg", (await TerminalBridge.ImageAsync(jpeg, macos: false)).MimeType);
        var e = await Assert.ThrowsAsync<LiveException>(() => TerminalBridge.ImageAsync(heic, macos: false));
        Assert.Equal("This computer reads PNG and JPEG images only.", e.Message);
        // Just the magic, nothing after it: not an image.
        await Assert.ThrowsAsync<LiveException>(() => TerminalBridge.ImageAsync([0xFF, 0xD8, 0xFF], macos: false));
    }

    [Fact]
    public async Task APhonesImageOrFileOpensOnlyWithThisComputersKeyForItsOwnPath()
    {
        // The phone seals a blob for its path (terminal_remote.dart): AAD ImageAad(path).
        var key = ChannelKey.Generate();
        byte[] png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 1, 2, 3];
        var pdf = Encoding.ASCII.GetBytes("%PDF-1.7 quarterly numbers");
        var path = Guid.NewGuid().ToString();
        var filePath = Guid.NewGuid().ToString();
        Assert.True(Server.IsBlobPath(path));
        var sealedImage = E2e.SealBytes(key, png, E2e.ImageAad(path));
        var sealedFile = E2e.SealBytes(key, pdf, E2e.ImageAad(filePath));
        Assert.Equal(png, TerminalBridge.OpenBlob(key, path, sealedImage));
        Assert.Equal("image/png", (await TerminalBridge.ImageAsync(TerminalBridge.OpenBlob(key, path, sealedImage), macos: false)).MimeType);
        Assert.Throws<LiveException>(() => TerminalBridge.OpenBlob(ChannelKey.Generate(), path, sealedImage));
        Assert.Throws<LiveException>(() => TerminalBridge.OpenBlob(key, "another", sealedImage));
        Assert.Equal(pdf, TerminalBridge.OpenBlob(key, filePath, sealedFile));
        Assert.Throws<LiveException>(() => TerminalBridge.OpenBlob(key, path, sealedFile));
    }

    [Fact]
    public void AFollowedSessionsUpdateGoesSealedForAndroidIPhonesGetOnlyItsState()
    {
        var key = ChannelKey.Generate();
        var body = TerminalBridge.ActivityPush(key, "abcd1234", "kitty-1/2", new(ActivityState.Needs, ActivityKind.Approval));
        Assert.Equal(["enc", "kind", "session", "state", "tag"], body.Select(e => e.Key).Order());
        Assert.Equal("abcd1234/kitty-1/2", (string)body["session"]!);
        Assert.Equal("needs", (string)body["state"]!);
        Assert.Equal("approval", (string)body["kind"]!);
        // The phone finds the key by this computer's tag; the computer's id goes only inside the seal.
        Assert.Equal(E2e.PushTag(key), (string)body["tag"]!);

        var sealedBytes = Convert.FromBase64String((string)body["enc"]!);
        var opened = DartJson.TryDecodeObject(E2e.OpenBytes(key, sealedBytes, E2e.ActivityAad("abcd1234"))!)!;
        Assert.Equal(["id", "kind", "session", "since", "state", "ts"], opened.Select(e => e.Key).Order());
        Assert.Equal("abcd1234/kitty-1/2", (string)opened["session"]!);
        Assert.Equal("needs", (string)opened["state"]!);
        Assert.Equal("approval", (string)opened["kind"]!);
        Assert.NotNull(DartJson.AsInt(opened["since"]));
        Assert.NotNull(DartJson.AsInt(opened["ts"]));
        Assert.NotNull(DartJson.AsString(opened["id"]));
        // Not another computer's, not a notification.
        Assert.Null(E2e.OpenBytes(key, sealedBytes, E2e.ActivityAad("zzzz9999")));
        Assert.Null(E2e.OpenBytes(key, sealedBytes, E2e.PushAad("abcd1234")));
    }

    [Fact]
    public void ARequestSentAgainUnderItsIdIsAnsweredAsBeforeNotRunTwice()
    {
        var now = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        var runs = new RunLog(clock: () => now);
        var again = new List<JsonObject>();
        Assert.True(runs.Start("a", again.Add));
        Assert.False(runs.Start("a", again.Add)); // still running: its answer goes out when it ends
        Assert.Empty(again);
        runs.Done("a", new JsonObject { ["id"] = "a", ["error"] = "nope" });
        Assert.False(runs.Start("a", again.Add));
        Assert.Equal("""{"id":"a","error":"nope","repeat":true}""", DartJson.Encode(Assert.Single(again)));
        Assert.True(runs.Start("b", again.Add)); // another request runs
        now = now.AddMinutes(3);
        Assert.True(runs.Start("a", again.Add));
    }

    [Fact]
    public void APhonesLaunchRunsOmpOnlyInAProfileThisComputerHas()
    {
        string[] profiles = ["personal"];
        Assert.Equal("personal", BridgeHelpers.LaunchProfile("personal", Agent.Omp, profiles));
        Assert.Equal("", BridgeHelpers.LaunchProfile(null, Agent.Omp, profiles));
        Assert.Equal("", BridgeHelpers.LaunchProfile("", Agent.Omp, profiles));
        Assert.Throws<TerminalException>(() => BridgeHelpers.LaunchProfile("x", Agent.Omp, profiles));
        Assert.Throws<TerminalException>(() => BridgeHelpers.LaunchProfile("a; rm -rf ~", Agent.Omp, profiles));
        Assert.Equal("", BridgeHelpers.LaunchProfile("personal", Agent.Claude, profiles));
    }

    // ------------------------------------------------------------ switching a screen-only agent window

    private const string Window = "kitty-1/7";
    private const string Tty = "ttys004";

    private sealed class Switching
    {
        public readonly List<string> Log = [];
        public List<string> Foreground = ["omp"];
        public readonly BridgeFakeHost Kitty;

        public Switching() => Kitty = BridgeFakeHost.Kitty(Log);

        /// <summary>A kitty that records what it's told, and `ps` showing <see cref="Foreground"/>'s programs on the
        /// tty in turn (the last one from then on).</summary>
        public Terminals Terms() => TerminalBridgeTests.Terms(kitty: Kitty, snapshot: () =>
        {
            string program;
            lock (Log)
            {
                program = Foreground[0];
                if (Foreground.Count > 1) Foreground.RemoveAt(0);
                Log.Add($"ps {program}");
            }
            var zsh = program == "zsh";
            List<Proc> procs = [new(40, 1, 40, zsh ? 40 : 50, Tty, "Ss", "-zsh")];
            if (!zsh) procs.Add(new(50, 40, 50, 50, Tty, "S+", program));
            return Task.FromResult(new Procs(procs));
        });

        public Task Run(Terminals t, Agent agent, string tty = Tty, string profile = "") =>
            BridgeHelpers.SwitchToConversationAsync(
                t,
                Window,
                agent,
                tty: tty,
                profile: profile,
                settle: TimeSpan.Zero,
                noTty: TimeSpan.Zero,
                pollEvery: TimeSpan.Zero,
                quitFor: TimeSpan.FromMilliseconds(200));
    }

    [Fact]
    public async Task OmpEscCtrlCCtrlDThenOmpCOnceOmpHasQuit()
    {
        var s = new Switching { Foreground = ["omp", "omp", "omp", "zsh"] };
        await s.Run(s.Terms(), Agent.Omp);
        Assert.Equal(
            ["ps omp", "keys esc", "keys ctrl+c", "keys ctrl+d", "ps omp", "ps omp", "ps zsh", "type omp -c", "keys enter"],
            s.Log);
    }

    [Fact]
    public async Task OmpInAProfileStartsAgainInThatProfile()
    {
        var s = new Switching { Foreground = ["omp --profile=personal", "omp --profile=personal", "zsh"] };
        await s.Run(s.Terms(), Agent.Omp, profile: "personal");
        Assert.Equal(["type omp --profile=personal -c"], s.Log.Where(l => l.StartsWith("type")));
    }

    [Fact]
    public async Task AnAgentThatQuitSinceThePhoneLookedGetsNoKeys()
    {
        var s = new Switching { Foreground = ["zsh"] };
        foreach (var agent in Enum.GetValues<Agent>())
        {
            var e = await Assert.ThrowsAsync<TerminalException>(() => s.Run(s.Terms(), agent));
            Assert.Contains("isn't running", e.Message);
        }
        Assert.DoesNotContain(s.Log, l => !l.StartsWith("ps"));
    }

    [Fact]
    public async Task OmpInATerminalThatTellsNoTtyGetsOmpCAfterAWait()
    {
        var s = new Switching();
        await s.Run(s.Terms(), Agent.Omp, tty: "");
        Assert.Equal(["keys esc", "keys ctrl+c", "keys ctrl+d", "type omp -c", "keys enter"], s.Log);
    }

    [Fact]
    public async Task OmpThatDoesntQuitGetsNothingTypedIntoIt()
    {
        var s = new Switching();
        var e = await Assert.ThrowsAsync<TerminalException>(() => s.Run(s.Terms(), Agent.Omp));
        Assert.StartsWith("omp didn't quit.", e.Message);
        Assert.DoesNotContain(s.Log, l => l.StartsWith("type"));
    }

    [Fact]
    public async Task ClaudeCodeReloadsPluginsNothingRestarts()
    {
        var s = new Switching { Foreground = ["claude"] };
        await s.Run(s.Terms(), Agent.Claude);
        Assert.Equal(["ps claude", "type /reload-plugins", "keys enter"], s.Log);
    }

    [Fact]
    public async Task ATerminalThatCantPressKeysIsRefused()
    {
        var s = new Switching();
        var e = await Assert.ThrowsAsync<TerminalException>(() =>
            BridgeHelpers.SwitchToConversationAsync(s.Terms(), "nowhere:1", Agent.Omp));
        Assert.StartsWith("This terminal can't press keys", e.Message);
    }

    [Fact]
    public async Task ProbeIsBusyWhenTheScreenChangesBetweenTwoReads()
    {
        var s = new Switching();
        s.Kitty.Screens = ["π ⠋ Working", "π ⠙ Working"];
        Assert.True(await BridgeHelpers.ScreenChangesAsync(s.Terms(), Window, gap: TimeSpan.Zero));
        s.Kitty.Screens = ["π > idle", "π > idle"];
        Assert.False(await BridgeHelpers.ScreenChangesAsync(s.Terms(), Window, gap: TimeSpan.Zero));
    }

    [Fact]
    public async Task ProbeInATerminalThatCantShowItsScreenIsBusyWhenTheTitleSpins()
    {
        var ghostty = BridgeFakeHost.Ghostty();
        var t = Terms(ghostty: ghostty);
        ghostty.Titles = ["π ⠋ chat", "π ⠋ chat", "π ⠙ chat"];
        Assert.True(await BridgeHelpers.ScreenChangesAsync(t, GhosttyKey, gap: TimeSpan.Zero));
        ghostty.Titles = ["π > chat"];
        Assert.False(await BridgeHelpers.ScreenChangesAsync(t, GhosttyKey, gap: TimeSpan.Zero));
        ghostty.Titles = [];
        await Assert.ThrowsAsync<TerminalException>(() => BridgeHelpers.ScreenChangesAsync(t, GhosttyKey, gap: TimeSpan.Zero));
    }
}

/// <summary>A terminal as the bridge drives it: what it's told goes to <see cref="Log"/>; its screen is
/// <see cref="Screens"/> in turn; one window titled <see cref="Titles"/> in turn (none: no window).</summary>
internal sealed class BridgeFakeHost(string id, string label, string prefix, IReadOnlySet<TermCap> caps, List<string> log) : TerminalHost
{
    public static BridgeFakeHost Kitty(List<string> log) => new("kitty", "kitty", "kitty-", TermCaps.All, log);

    public static BridgeFakeHost Ghostty() =>
        new("ghostty", "Ghostty", "ghostty:", new HashSet<TermCap> { TermCap.Type, TermCap.Line, TermCap.Keys, TermCap.Close }, []);

    public List<string> Log => log;
    public List<string> Screens = [""];
    public List<string> Titles = [];

    public override string Id => id;
    public override string Label => label;
    public override IReadOnlySet<TermCap> Caps => caps;
    public override string? AppName => label;
    public override bool Owns(string key) => key.StartsWith(prefix, StringComparison.Ordinal);
    public override Task<TermStatus> StatusAsync(Procs procs) => Task.FromResult(new TermStatus(id, label, TermState.Ready));

    public override Task<IReadOnlyList<TermWindow>> WindowsAsync(Procs procs)
    {
        if (id != "ghostty" || Titles.Count == 0) return Task.FromResult<IReadOnlyList<TermWindow>>([]);
        var title = Titles[0];
        if (Titles.Count > 1) Titles.RemoveAt(0);
        return Task.FromResult<IReadOnlyList<TermWindow>>(
        [
            new TermWindow { Key = "ghostty:CB2035E7-67BF-48C7-8D0A-83F3FA5B8074", Title = title, Tab = "", Cwd = "/p/chat", Program = "", App = "ghostty", Caps = caps },
        ]);
    }

    public override Task<string> PlainScreenAsync(string key)
    {
        var screen = Screens[0];
        if (Screens.Count > 1) Screens.RemoveAt(0);
        return Task.FromResult(screen);
    }

    public override Task PressKeysAsync(string key, IReadOnlyList<string> names)
    {
        lock (log) log.Add($"keys {string.Join(' ', names)}");
        return Task.CompletedTask;
    }

    public override Task TypeAsync(string key, string text)
    {
        lock (log) log.Add($"type {text}");
        return Task.CompletedTask;
    }

    public override Task<string> LaunchAsync(string cwd, IReadOnlyList<string>? command = null, string? into = null) =>
        throw new TerminalException($"{label} can't open windows here.");
}
