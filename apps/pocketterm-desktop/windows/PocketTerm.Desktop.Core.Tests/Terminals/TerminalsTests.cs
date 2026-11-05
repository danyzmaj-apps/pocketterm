using System.Text.Json.Nodes;
using PocketTerm.Core;

namespace PocketTerm.Desktop.Tests;

/// <summary>Needs symlinks a test can make, which Windows reserves for admins.</summary>
file sealed class TermsPosixFactAttribute : FactAttribute
{
    public TermsPosixFactAttribute()
    {
        if (OperatingSystem.IsWindows()) Skip = "needs symlinks";
    }
}

/// <summary>A terminal that lists the windows it's given and records what it's asked.</summary>
internal sealed class TermsFakeHost(string id, string label, string? appName = null) : TerminalHost
{
    public IReadOnlyList<TermWindow> Listed { get; set; } = [];
    public Exception? Fails { get; set; }
    public string? Opened { get; set; }
    public List<string> Asked { get; } = [];

    public override string Id => id;
    public override string Label => label;
    public override string? AppName => appName;
    public override IReadOnlySet<TermCap> Caps => TermCaps.All;
    public override bool Owns(string key) => key.StartsWith(id, StringComparison.Ordinal);

    public override Task<TermStatus> StatusAsync(Procs procs) =>
        Fails != null ? Task.FromException<TermStatus>(Fails) : Task.FromResult(new TermStatus(Id, Label, TermState.Ready));

    public override Task<IReadOnlyList<TermWindow>> WindowsAsync(Procs procs) =>
        Fails != null ? Task.FromException<IReadOnlyList<TermWindow>>(Fails) : Task.FromResult(Listed);

    public override Task TypeAsync(string key, string text)
    {
        Asked.Add($"type {key} {text}");
        return Task.CompletedTask;
    }

    public override Task PressKeysAsync(string key, IReadOnlyList<string> names)
    {
        Asked.Add($"press {key} {string.Join(',', names)}");
        return Task.CompletedTask;
    }

    public override Task<string> LaunchAsync(string cwd, IReadOnlyList<string>? command = null, string? into = null)
    {
        Asked.Add($"launch {cwd} into {into ?? "-"}");
        return Opened == null
            ? Task.FromException<string>(new TerminalException($"{Label} isn't listening."))
            : Task.FromResult(Opened);
    }
}

public sealed class TerminalsTests
{
    private static TermWindow W(
        string key, string app = "x", string cwd = "", string osWindow = "", string tabId = "", string via = "", string tty = "",
        string program = "") =>
        new()
        {
            Key = key,
            Title = "",
            Tab = "",
            Cwd = cwd,
            Program = program,
            App = app,
            Tty = tty,
            OsWindow = osWindow,
            TabId = tabId,
            Via = via,
        };

    private static Terminals With(params TerminalHost[] hosts) =>
        new("/nonexistent-pocketterm", hosts, () => Task.FromResult(new Procs([])), windows: false);

    [Fact]
    public void StandardOnWindowsIsWezTermOnly()
    {
        var terms = Terminals.Standard(home: @"C:\Users\x", windows: true);
        Assert.Equal(["wezterm"], terms.Hosts.Select(h => h.Id));
        Assert.Equal(["wezterm"], terms.Apps.Select(h => h.Id));
        Assert.Equal(@"C:\Users\x", terms.Home);
        Assert.Same(terms.Hosts[0], terms.WezTerm);
    }

    [Fact]
    public void CreateProjectOnWindowsTurnsDownANameWindowsWouldRefuseOrChangeBeforeAnythingIsMade()
    {
        var root = Directory.CreateTempSubdirectory("pocketterm-proj").FullName;
        try
        {
            var terms = Terminals.Standard(home: root, windows: true);
            foreach (var name in new[] { "CON", "app.", "a?b" })
            {
                var e = Assert.Throws<TerminalException>(() => terms.CreateProject(root, name, [root], windows: true));
                Assert.Contains("Windows", e.Message);
            }
            Assert.Empty(Directory.EnumerateFileSystemEntries(root));
            // The terminals' own rules when none are given.
            Assert.Throws<TerminalException>(() => terms.CreateProject(root, "NUL", [root]));
            Assert.Equal(Path.Combine(root, "app"), terms.CreateProject(root, "app", [root], windows: true));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private static readonly TermsFakeHost Kitty = new("kitty", "kitty");

    private static string? Find(IReadOnlyList<TermWindow> ws, string cwd) =>
        Terminals.ProjectWindow(ws, Kitty, cwd, "/Users/me", windowsRules: false);

    [Fact]
    public void ProjectWindowIsTheAppsWindowWithTheMostOfTheProjectsTabsPanesOfOneTabCountingOnce()
    {
        TermWindow[] ws =
        [
            W("kitty-1/1", app: "kitty", cwd: "/Users/me/a", osWindow: "kitty-1/os1", tabId: "kitty-1/tab1"),
            W("kitty-1/2", app: "kitty", cwd: "/Users/me/a", osWindow: "kitty-1/os1", tabId: "kitty-1/tab1"),
            W("kitty-1/3", app: "kitty", cwd: "/Users/me/b", osWindow: "kitty-1/os1", tabId: "kitty-1/tab2"),
            W("kitty-1/4", app: "kitty", cwd: "/Users/me/a/lib", osWindow: "kitty-1/os2", tabId: "kitty-1/tab3"),
            W("kitty-1/5", app: "kitty", cwd: "/Users/me/a", osWindow: "kitty-1/os2", tabId: "kitty-1/tab5"),
            // Another app's window, and a tmux pane no app shows: not kitty's to open a tab in.
            W("wezterm:9/1", app: "wezterm", cwd: "/Users/me/a", osWindow: "wezterm:9/w1", tabId: "wezterm:9/t1"),
            W("tmux:default/0", app: "tmux", cwd: "/Users/me/a", osWindow: "tmux:default/s1"),
        ];
        Assert.Equal("kitty-1/os2", Find(ws, "/Users/me/a"));
        Assert.Equal("kitty-1/os1", Find(ws, "/Users/me/b"));
        Assert.Null(Find(ws, "/Users/me/ab")); // a folder whose name starts the same is another project
    }

    [Fact]
    public void ProjectWindowCountsAPaneForTheAppWindowShowingIt()
    {
        TermWindow[] ws =
        [
            W("tmux:default/0", app: "tmux", via: "kitty", cwd: "/Users/me/a", osWindow: "kitty-1/os3", tabId: "kitty-1/tab7"),
        ];
        Assert.Equal("kitty-1/os3", Find(ws, "/Users/me/a"));
    }

    [Fact]
    public void ProjectWindowForTheHomeFolderCountsOnlyTabsInIt()
    {
        TermWindow[] ws =
        [
            W("kitty-1/1", app: "kitty", cwd: "/Users/me/a", osWindow: "kitty-1/os1", tabId: "kitty-1/tab1"),
            W("kitty-1/2", app: "kitty", cwd: "/Users/me/b", osWindow: "kitty-1/os1", tabId: "kitty-1/tab2"),
            W("kitty-1/3", app: "kitty", cwd: "/Users/me", osWindow: "kitty-1/os2", tabId: "kitty-1/tab3"),
        ];
        Assert.Equal("kitty-1/os2", Find(ws, "/Users/me"));
        Assert.Null(Find(ws[..2], "/Users/me"));
    }

    [Fact]
    public void AWindowThatTellsNoAppWindowIsNoPlaceForATab() =>
        Assert.Null(Find([W("kitty-1/1", app: "kitty", cwd: "/Users/me/a")], "/Users/me/a"));

    [Fact]
    public void ProjectWindowOnWindowsTakesEitherSeparatorAndAnyCase()
    {
        var wez = new TermsFakeHost("wezterm", "WezTerm");
        TermWindow[] ws =
        [
            W("wezterm:1/0", app: "wezterm", cwd: @"c:\users\me\APP", osWindow: "wezterm:1/w0", tabId: "wezterm:1/t0"),
            W("wezterm:1/1", app: "wezterm", cwd: @"C:\Users\me\app\src", osWindow: "wezterm:1/w2", tabId: "wezterm:1/t1"),
            W("wezterm:1/2", app: "wezterm", cwd: @"C:\Users\me\app\lib\", osWindow: "wezterm:1/w2", tabId: "wezterm:1/t2"),
            W("wezterm:1/3", app: "wezterm", cwd: @"C:\Users\me\application", osWindow: "wezterm:1/w3", tabId: "wezterm:1/t3"),
        ];
        Assert.Equal("wezterm:1/w2", Terminals.ProjectWindow(ws, wez, "C:/Users/me/app/", @"C:\Users\me", windowsRules: true));
        Assert.Equal("wezterm:1/w3", Terminals.ProjectWindow(ws, wez, @"C:\Users\me\Application", @"C:\Users\me", windowsRules: true));
        // The home folder is only itself.
        Assert.Null(Terminals.ProjectWindow(ws, wez, @"C:\Users\me", @"C:\Users\me", windowsRules: true));
    }

    [Fact]
    public void TheHomeFolderIsGeneralAndAProjectIsItsFolder()
    {
        Assert.Equal("General", Terminals.ProjectName("/Users/me", "/Users/me", windows: false));
        Assert.Equal("wrkly", Terminals.ProjectName("/Users/me/wrkly", "/Users/me", windows: false));
        Assert.Equal("General", Terminals.ProjectName(@"c:\users\ME\", @"C:\Users\me", windows: true));
        Assert.Equal("wrkly", Terminals.ProjectName(@"C:\Users\me\wrkly\", @"C:\Users\me", windows: true));
        Assert.Equal("Me", Terminals.ProjectName("/Users/Me", "/Users/me", windows: false));
    }

    private static TermStatus S(string id, TermState state) => new(id, id, state);

    private static readonly TerminalHost[] Apps =
        [new TermsFakeHost("kitty", "kitty", "kitty"), new TermsFakeHost("wezterm", "WezTerm", "WezTerm"), new TermsFakeHost("ghostty", "Ghostty", "Ghostty")];

    private static readonly Dictionary<string, TermStatus> Statuses = new()
    {
        ["kitty"] = S("kitty", TermState.Setup),
        ["wezterm"] = S("wezterm", TermState.Limited),
        ["ghostty"] = S("ghostty", TermState.Idle),
    };

    [Fact]
    public void PickAppTakesAChosenAppThatIsInstalledEvenWhenNotRunning() =>
        Assert.Equal("ghostty", Terminals.PickApp(Apps, Statuses, "ghostty", ["WezTerm"]).Id);

    [Fact]
    public void PickAppOnAutoTakesTheUsableAppUsedMostRecentlySkippingOnesThatNeedSetup()
    {
        Assert.Equal("wezterm", Terminals.PickApp(Apps, Statuses, "auto", ["Zen", "kitty", "Ghostty", "WezTerm"]).Id);
        // A missing choice falls back the same way.
        var noGhostty = new Dictionary<string, TermStatus>(Statuses) { ["ghostty"] = S("ghostty", TermState.Missing) };
        Assert.Equal("wezterm", Terminals.PickApp(Apps, noGhostty, "ghostty", ["WezTerm"]).Id);
    }

    [Fact]
    public void PickAppOnAutoWithNoneUsedLatelyTakesTheFirstUsableElseOneThatCanBeStarted()
    {
        Assert.Equal("wezterm", Terminals.PickApp(Apps, Statuses, "auto", []).Id);
        var none = new Dictionary<string, TermStatus>
        {
            ["kitty"] = S("kitty", TermState.Idle),
            ["wezterm"] = S("wezterm", TermState.Missing),
            ["ghostty"] = S("ghostty", TermState.Idle),
        };
        // kitty can't be started listening: Ghostty, the next idle app.
        Assert.Equal("ghostty", Terminals.PickApp(Apps, none, "auto", []).Id);
    }

    [Fact]
    public async Task OpensInOnWindowsIsWezTermEvenWhenItIsMissing()
    {
        var terms = new Terminals(
            @"C:\Users\x",
            [new WezTerm(executable: "/nonexistent-pocketterm/wezterm.exe", socketDir: "/nonexistent-pocketterm", windows: true)],
            () => Task.FromResult(new Procs([])),
            windows: true);
        var host = await terms.OpensInAsync("auto");
        Assert.Equal("wezterm", host.Id);
        Assert.False(terms.ViaTmux(host));
        Assert.Equal("WezTerm", terms.Describe(host));
    }

    [Fact]
    public async Task AnOmpWindowCarriesTheProfileItsCommandLineNamesAndOtherWindowsAndTheDefaultDoNot()
    {
        var host = new TermsFakeHost("wezterm:", "WezTerm")
        {
            Listed =
            [
                W("wezterm:1/1", tty: "ttys004", program: "omp"),
                W("wezterm:1/2", tty: "ttys005", program: "zsh"),
                W("wezterm:1/3", tty: "ttys006", program: "omp"),
            ],
        };
        var terms = new Terminals(
            "/nonexistent-pocketterm",
            [host],
            () => Task.FromResult(new Procs(Terminal.ParsePs(
                "  500   400   500   500 ttys004  S+   omp --profile=personal\n" +
                "  600     1   600   600 ttys005  Ss+  -zsh --profile=personal\n" +
                "  700   400   700   700 ttys006  S+   /opt/homebrew/bin/omp -c\n"))));
        Assert.Equal(
            [("wezterm:1/1", "personal"), ("wezterm:1/2", ""), ("wezterm:1/3", "")],
            (await terms.WindowsAsync()).Select(w => (w.Key, w.Profile)));
    }

    [Fact]
    public async Task ATerminalThatFailsToListLeavesTheOthersAndSaysWhatWentWrong()
    {
        var broken = new TermsFakeHost("kitty", "kitty") { Fails = new TerminalException("kitty isn't listening.") };
        var wez = new TermsFakeHost("wezterm", "WezTerm") { Listed = [W("wezterm:1/0", app: "wezterm")] };
        var terms = With(broken, wez);
        Assert.Equal(["wezterm:1/0"], (await terms.WindowsAsync()).Select(w => w.Key));
        Assert.Equal("kitty isn't listening.", terms.Problems["kitty"]);

        var statuses = await terms.StatusesAsync();
        Assert.Equal((TermState.Limited, "kitty isn't listening."), (statuses[0].State, statuses[0].Note));
        Assert.Equal(TermState.Ready, statuses[1].State);
    }

    [Fact]
    public async Task RequestsGoToTheWindowsOwnTerminalAndOnlyPhoneKeysArePressed()
    {
        var wez = new TermsFakeHost("wezterm", "WezTerm");
        var terms = With(wez);
        await terms.SendAsync("wezterm:1/0", "a\nb", enter: true);
        await terms.PressAsync("wezterm:1/0", "esc");
        Assert.Equal(
            ["type wezterm:1/0 a", "press wezterm:1/0 shift+enter", "type wezterm:1/0 b", "press wezterm:1/0 enter", "press wezterm:1/0 esc"],
            wez.Asked);
        Assert.Equal("Unknown key: f1", (await Assert.ThrowsAsync<TerminalException>(() => terms.PressAsync("wezterm:1/0", "f1"))).Message);
        Assert.Equal("That window is gone.", (await Assert.ThrowsAsync<TerminalException>(() => terms.TypeAsync("kitty-1/1", "x"))).Message);
        Assert.True(terms.Can("wezterm:1/0", TermCap.Keys));
        Assert.False(terms.Can("kitty-1/1", TermCap.Read));
    }

    [Fact]
    public async Task LocateTakesThePaneWezTermNames()
    {
        var terms = Terminals.Standard(home: @"C:\Users\x", windows: true);
        var term = new JsonObject
        {
            ["TERM_PROGRAM"] = "WezTerm",
            ["WEZTERM_PANE"] = "3",
            ["WEZTERM_UNIX_SOCKET"] = @"C:\Users\x\.local\share\wezterm\gui-sock-4242",
        };
        Assert.Equal("wezterm:4242/3", await terms.LocateAsync(term, "", "", Agent.Omp, new HashSet<string>()));
        Assert.Null(await terms.LocateAsync(null, "", "", Agent.Omp, new HashSet<string>()));
        Assert.Null(await terms.LocateAsync(new JsonObject { ["TERM_PROGRAM"] = "ghostty" }, "", "", Agent.Omp, new HashSet<string>()));
    }

    [Fact]
    public async Task LaunchOpensATabInTheProjectsWindowAndStartsTheAgentInItsProfile()
    {
        var dir = Directory.CreateTempSubdirectory("pocketterm-launch").FullName;
        try
        {
            var project = Directory.CreateDirectory(Path.Combine(dir, "wrkly")).FullName;
            var wez = new TermsFakeHost("wezterm", "WezTerm")
            {
                Listed = [W("wezterm:1/0", app: "wezterm", cwd: project, osWindow: "wezterm:1/w0", tabId: "wezterm:1/t0")],
                Opened = "wezterm:1/9",
            };
            var terms = new Terminals(dir, [wez], () => Task.FromResult(new Procs([])));

            var opened = await terms.LaunchAsync(project, wez, Agent.Omp, profile: "personal", flags: "--x");
            Assert.Equal(new Opened("wezterm:1/9", "a new tab in the WezTerm window with wrkly"), opened);
            Assert.Equal(
                [$"launch {project} into wezterm:1/w0", $"type wezterm:1/9 {Agent.Omp.CommandIn("personal")} --x", "press wezterm:1/9 enter"],
                wez.Asked);

            wez.Asked.Clear();
            Assert.Equal(
                new Opened("wezterm:1/9", "a new WezTerm window"),
                await terms.LaunchAsync(project, wez, placement: Placement.NewWindow));
            Assert.Equal([$"launch {project} into -"], wez.Asked);

            var gone = Path.Combine(dir, "gone");
            Assert.Equal($"No such folder: {gone}", (await Assert.ThrowsAsync<TerminalException>(() => terms.LaunchAsync(gone, wez))).Message);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    // ------------------------------------------------------------ projects

    private sealed class Root : IDisposable
    {
        private readonly string _dir = Directory.CreateTempSubdirectory("pocketterm-projects").FullName;

        public Root() => Path_ = PathRules.RealPath(_dir);

        public string Path_ { get; }

        public string P(string rel) => Path.Combine(Path_, rel.Replace('/', Path.DirectorySeparatorChar));

        public void Mk(string rel) => Directory.CreateDirectory(P(rel));

        public void Dispose() => Directory.Delete(_dir, recursive: true);
    }

    [Fact]
    public async Task ProjectsAreGitRepositoriesUpToThreeLevelsUnderTheGivenFoldersNotInsideOneAnother()
    {
        using var r = new Root();
        r.Mk("a/.git");
        r.Mk("a/sub/.git");
        r.Mk("org/b/.git");
        r.Mk("plain/x");
        r.Mk(".hidden/c/.git");
        r.Mk("1/2/3/.git");
        r.Mk("4/5/6/7/.git");
        r.Mk("node_modules/d/.git");
        var terms = With();
        List<string> expected = [r.P("1/2/3"), r.P("a"), r.P("org/b")];
        Assert.Equal(expected, await terms.ProjectsAsync([r.Path_, r.P("nonexistent")]));
        // Nested folders list a repository once.
        Assert.Equal(expected, await terms.ProjectsAsync([r.Path_, r.P("org")]));
        Assert.Empty(await terms.ProjectsAsync([]));
    }

    [TermsPosixFact]
    public async Task SymlinkedFoldersAreFollowedUnderTheirOwnPathAndALoopOrOneFolderByTwoPathsListsOnce()
    {
        using var r = new Root();
        r.Mk("real/repo/.git");
        r.Mk("elsewhere/linked/.git");
        r.Mk("deep/x/y/z/.git");
        Directory.CreateSymbolicLink(r.P("projects"), r.P("elsewhere"));
        Directory.CreateSymbolicLink(r.P("real/loop"), r.Path_);
        Directory.CreateSymbolicLink(r.P("real/again"), r.P("real/repo"));
        var terms = With();
        Assert.Equal([r.P("projects/linked"), r.P("real/repo")], await terms.ProjectsAsync([r.Path_]));
        // A root inside another is walked to its own depth; a trailing slash changes nothing.
        Assert.Equal(
            [r.P("deep/x/y/z"), r.P("projects/linked"), r.P("real/repo")],
            await terms.ProjectsAsync([$"{r.Path_}/", r.P("deep")]));
    }

    [Fact]
    public void CreateProjectMakesTheFolderUnderOneOfTheProjectFoldersOnce()
    {
        using var r = new Root();
        var root = r.Path_;
        var terms = With();
        Assert.Equal(r.P("new"), terms.CreateProject(root, " new ", [root]));
        Assert.True(Directory.Exists(r.P("new")));
        Assert.Contains("already", Assert.Throws<TerminalException>(() => terms.CreateProject(root, "new", [root])).Message);
        Assert.Throws<TerminalException>(() => terms.CreateProject(root, "other", []));
        foreach (var name in new[] { "", "  ", "a/b", @"a\b", "C:x", ".x", "..", "a\0b", "a\nb" })
        {
            Assert.Throws<TerminalException>(() => terms.CreateProject(root, name, [root]));
        }
        // A Project folder deleted since it was added.
        var gone = r.P("gone");
        Assert.StartsWith("No such folder", Assert.Throws<TerminalException>(() => terms.CreateProject(gone, "x", [gone])).Message);
    }

    [Fact]
    public async Task LaunchNewProjectTakesTheFolderBackWhenNoWindowOpensSoTryingAgainWorks()
    {
        using var r = new Root();
        var root = r.Path_;
        // The terminal isn't listening here: the launch fails.
        var kitty = new TermsFakeHost("kitty", "kitty");
        var terms = With(kitty);
        Task<Opened> Attempt() => terms.LaunchNewProjectAsync(root, "demo", [root], kitty);
        await Assert.ThrowsAsync<TerminalException>(Attempt);
        Assert.False(Directory.Exists(r.P("demo")));
        // The same failure again, not "already something named demo there".
        Assert.DoesNotContain("already", (await Assert.ThrowsAsync<TerminalException>(Attempt)).Message);

        kitty.Opened = "kitty-1/1";
        Assert.Equal(new Opened("kitty-1/1", "a new kitty window"), await Attempt());
        Assert.True(Directory.Exists(r.P("demo")));
    }
}
