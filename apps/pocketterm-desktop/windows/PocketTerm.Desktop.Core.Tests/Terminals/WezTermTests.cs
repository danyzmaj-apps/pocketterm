using System.Text;
using PocketTerm.Core;

namespace PocketTerm.Desktop.Tests;

/// <summary>Runs where a shell script can stand in for wezterm (as the Dart tests' fake), not on Windows.</summary>
file sealed class WezPosixFactAttribute : FactAttribute
{
    public WezPosixFactAttribute()
    {
        if (OperatingSystem.IsWindows()) Skip = "needs a shell script as wezterm";
    }
}

/// <summary>WezTerm through a fake <c>wezterm</c> (a shell script), and its pane list and folders.</summary>
public sealed class WezTermTests : IDisposable
{
    /// <summary><c>wezterm cli list --format json</c> of WezTerm 20240203 on a Mac, its pane in
    /// <c>sp ace'q 漢字 100%</c> (a <c>%</c> the shell's report left unescaped).</summary>
    private const string MacList =
        """
        [{"window_id":0,"tab_id":0,"pane_id":0,"workspace":"default","title":"bash\u0007\u001b[31mx","tab_title":"",
        "cwd":"file:///private/tmp/ptw/sp%20ace'q%20%E6%BC%A2%E5%AD%97%20100%","is_active":true,"tty_name":"/dev/ttys014"}]
        """;

    /// <summary><c>ps</c> lines of the window in <see cref="MacTerminalList"/>.</summary>
    private const string PsWezTerm = " 1129  1128  1129 5249 ttys008  Ss+  -zsh\n 5249  1129  5249 5249 ttys008  S+   claude\n";

    private const string MacTerminalList =
        """
        [
          {
            "window_id": 0, "tab_id": 0, "pane_id": 0, "workspace": "default",
            "size": {"rows": 24, "cols": 80, "pixel_width": 1120, "pixel_height": 768, "dpi": 144},
            "title": "cap-wezterm", "cwd": "file://mac.local/tmp/dzt/cap-wezterm",
            "cursor_x": 15, "cursor_y": 0, "cursor_shape": "Default", "cursor_visibility": "Visible",
            "left_col": 0, "top_row": 0, "tab_title": "", "window_title": "cap-wezterm",
            "is_active": true, "is_zoomed": false, "tty_name": "/dev/ttys008"
          }
        ]
        """;

    /// <summary><c>tasklist /fo csv /nh</c> as Windows 11 prints it.</summary>
    private const string Tasklist =
        "\"System Idle Process\",\"0\",\"Services\",\"0\",\"8 K\"\n" +
        "\"System\",\"4\",\"Services\",\"0\",\"2,404 K\"\n" +
        "\"wezterm-gui.exe\",\"4242\",\"Console\",\"1\",\"98,120 K\"\n" +
        "\"pwsh.exe\",\"5120\",\"Console\",\"1\",\"80,312 K\"\n";

    /// <summary><c>wezterm cli list --format json</c> on Windows: no tty, the folder as a drive path.</summary>
    private const string WindowsList =
        """
        [
          {"window_id": 0, "tab_id": 0, "pane_id": 3, "title": "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
           "cwd": "file:///C:/Users/x/src/", "tab_title": "", "is_active": true, "tty_name": null}
        ]
        """;

    private readonly string _dir = Directory.CreateTempSubdirectory("ptw").FullName;

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    private static void Executable(string path, string script)
    {
        File.WriteAllText(path, script);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
    }

    /// <summary>A WezTerm whose <c>wezterm</c> runs <paramref name="script"/> (each run's last argument
    /// appended to <c>log</c>, RS after it), and a GUI socket for pid 1.</summary>
    private WezTerm Fake(string script, bool windows = false)
    {
        var exe = Path.Combine(_dir, "wezterm");
        Executable(exe, $"#!/bin/sh\nfor a; do last=\"$a\"; done\nprintf '%s\\036' \"$last\" >> {_dir}/log\n{script}\n");
        File.WriteAllText(Path.Combine(_dir, "gui-sock-1"), "");
        return new WezTerm(executable: exe, socketDir: _dir, windows: windows);
    }

    private List<string> Runs()
    {
        var log = Path.Combine(_dir, "log");
        if (!File.Exists(log)) return [];
        var parts = File.ReadAllText(log, Encoding.UTF8).Split('\x1e');
        return parts[..^1].ToList();
    }

    private static async Task Says(string message, Func<Task> action) =>
        Assert.Equal(message, (await Assert.ThrowsAsync<TerminalException>(action)).Message);

    [WezPosixFact]
    public async Task APaneWezTermNoLongerHasReadsAsGone()
    {
        var w = Fake(
            "echo '03:33:56.758  ERROR  wezterm > unexpected response Ok(ErrorResponse(ErrorResponse { reason: \"Error: no " +
            "such pane 99\" })); terminating' >&2; exit 1");
        await Says("That window is gone.", () => w.TypeAsync("wezterm:1/99", "x"));
        await Says("That window is gone.", () => w.CloseAsync("wezterm:1/99"));
    }

    [WezPosixFact]
    public async Task AGuiThatQuitAndLeftItsSocketSaysWezTermIsNotRunning()
    {
        var w = Fake(
            "echo '03:18:43.546  ERROR  wezterm > failed to connect to Socket(\"/x/gui-sock-1\"): connecting to " +
            "/x/gui-sock-1; terminating' >&2; exit 1");
        await Says("WezTerm isn't running.", () => w.PlainScreenAsync("wezterm:1/0"));
    }

    [WezPosixFact]
    public async Task AnotherErrorSaysWhatTheGuiGaveAsItsReason()
    {
        var w = Fake(
            "echo '03:33:56.823  ERROR  wezterm > unexpected response Ok(ErrorResponse(ErrorResponse { reason: \"Error: " +
            "window_id 99 not found on this server\" })); terminating' >&2; exit 1");
        await Says("WezTerm: window_id 99 not found on this server", () => w.PlainScreenAsync("wezterm:1/0"));
    }

    [WezPosixFact]
    public async Task OnWindowsACommandTooNewDoesNotHideItsWindowsForAMinute()
    {
        var w = Fake("echo \"error: unrecognized subcommand 'kill-pane'\" >&2; exit 2", windows: true);
        await Says(WezTerm.TooOld, () => w.CloseAsync("wezterm:1/0"));
        // The socket is still asked: the GUI is fine.
        await Says(WezTerm.TooOld, () => w.CloseAsync("wezterm:1/0"));
        Assert.Equal(2, Runs().Count);
    }

    [WezPosixFact]
    public async Task OutputThatIsNotUtf8ReadsWithReplacementCharacters()
    {
        var w = Fake(@"printf 'a\377b'");
        Assert.Equal("a\uFFFDb", await w.PlainScreenAsync("wezterm:1/0"));
    }

    [WezPosixFact]
    public async Task LongTextGoesInPiecesACommandLineTakesInOrder()
    {
        var w = Fake("exit 0");
        var text = string.Concat(Enumerable.Range(0, 3000).Select(i => $"é漢👍\"'$x{i} "));
        await w.TypeAsync("wezterm:1/0", text);
        var sent = Runs();
        Assert.True(sent.Count > 1);
        Assert.All(sent, s => Assert.True(Encoding.UTF8.GetByteCount(s) <= WezTerm.TypeBytes));
        Assert.Equal(text, string.Concat(sent));
    }

    [Fact]
    public void AFolderInThePaneListHasItsEscapesDecodedABarePercentKeptAndATitleWithoutEscapes()
    {
        var w = Assert.Single(WezTerm.ParseWezTermList("1", MacList));
        Assert.Equal("/private/tmp/ptw/sp ace'q 漢字 100%", w.Cwd);
        Assert.Equal("bashx", w.Title);
        Assert.Equal(("wezterm:1/w0", "wezterm:1/t0"), (w.OsWindow, w.TabId));
    }

    [Fact]
    public void ListOnAMacHasThePaneKeyWithTheGuiPidItsFolderAndTheProgramFromTheTty()
    {
        var w = Assert.Single(WezTerm.ParseWezTermList("1128", MacTerminalList, new Procs(Terminal.ParsePs(PsWezTerm))));
        Assert.Equal(
            ("wezterm:1128/0", "cap-wezterm", "/tmp/dzt/cap-wezterm", "ttys008", "claude", true, "wezterm"),
            (w.Key, w.Title, w.Cwd, w.Tty, w.Program, w.Focused, w.App));
        Assert.Equal(("wezterm:1128/w0", "wezterm:1128/t0"), (w.OsWindow, w.TabId));
    }

    [Fact]
    public void ListOnWindowsHasTheFolderFromTheDriveUrlAndTheProgramFromTheTitle()
    {
        var w = Assert.Single(WezTerm.ParseWezTermList("4242", WindowsList, new Procs(Terminal.ParseTasklist(Tasklist)), windows: true));
        Assert.Equal(("wezterm:4242/3", @"C:\Users\x\src", "", "pwsh"), (w.Key, w.Cwd, w.Tty, w.Program));
    }

    [Fact]
    public void CwdOfUriGivesADrivePathWithAnyHostDroppedAndAMacPathAsIs()
    {
        Assert.Equal(@"C:\Users\x", WezTerm.CwdOfUri(DartUri.Parse("file:///C:/Users/x/")));
        Assert.Equal(@"C:\x", WezTerm.CwdOfUri(DartUri.Parse("file://PC/C:/x")));
        Assert.Equal(@"C:\", WezTerm.CwdOfUri(DartUri.Parse("file:///C:/")));
        Assert.Equal("/Users/me/Dev", WezTerm.CwdOfUri(DartUri.Parse("file://mac.local/Users/me/Dev")));
    }

    [Fact]
    public void CwdOfUriOnWindowsGivesAShareAsItsUncPathAndTheWslShellsOwnFolderAsIs()
    {
        static string Cwd(string uri) => WezTerm.CwdOfUri(DartUri.Parse(uri), windows: true, localHost: "DESKTOP-1");
        Assert.Equal(@"\\wsl.localhost\Ubuntu\home\x", Cwd("file://wsl.localhost/Ubuntu/home/x/"));
        Assert.Equal(@"\\wsl$\Ubuntu-22.04\home\x\my app", Cwd("file://wsl$/Ubuntu-22.04/home/x/my%20app"));
        Assert.Equal(@"\\nas\projects", Cwd("file://nas/projects/"));
        // A shell in WSL (OSC 7) names the PC itself: a Linux folder, no share.
        Assert.Equal("/home/x", Cwd("file://desktop-1/home/x"));
        Assert.Equal("/home/x", Cwd("file://localhost/home/x"));
        Assert.Equal(@"C:\Users\Jürgen M\src", Cwd("file:///C:/Users/J%C3%BCrgen%20M/src/"));
        // On a Mac a host is never a share.
        Assert.Equal("/projects/", WezTerm.CwdOfUri(DartUri.Parse("file://nas/projects/"), localHost: "mac"));
    }

    [Fact]
    public void WezTermReleaseIsTheDateOfAReleaseOrNightlyAndNullWhenItTellsNone()
    {
        Assert.Equal(20240203, WezTerm.WezTermRelease("wezterm 20240203-110809-5046fc22\r\n"));
        Assert.Equal(WezTerm.MinRelease, WezTerm.WezTermRelease("wezterm 20230326-111934-3666303c"));
        Assert.Null(WezTerm.WezTermRelease("wezterm 0-unknown"));
        Assert.Null(WezTerm.WezTermRelease(""));
    }

    [WezPosixFact]
    public async Task TooOldForKillPaneNeedsAnUpdateSaidInTheStatus()
    {
        var exe = Path.Combine(_dir, "wezterm");
        Executable(exe, "#!/bin/sh\necho \"wezterm $(cat \"$0.v\")\"\n");
        var version = $"{exe}.v";
        File.WriteAllText(version, "20230320-124340-559cb7b0");
        var wez = new WezTerm(executable: exe, socketDir: _dir, windows: true);

        var old = await wez.StatusAsync(new Procs([]));
        Assert.Equal(TermState.Setup, old.State);
        Assert.Contains("too old", old.Note);
        Assert.Contains("winget upgrade wez.wezterm", old.Note);
        // Updated in place: asked again since the file changed.
        File.WriteAllText(version, "20240203-110809-5046fc22");
        File.SetLastWriteTimeUtc(exe, DateTime.UtcNow.AddMinutes(1));
        Assert.Equal(TermState.Idle, (await wez.StatusAsync(new Procs([]))).State);
    }

    [WezPosixFact]
    public async Task OnWindowsASocketThatFailedOnceIsAskedAgainAMinuteLater()
    {
        File.WriteAllText(Path.Combine(_dir, "gui-sock-4242"), "");
        File.WriteAllText(Path.Combine(_dir, "list.json"), WindowsList);
        var exe = Path.Combine(_dir, "wezterm");
        Executable(exe, $"#!/bin/sh\nif [ -f \"{_dir}/ok\" ]; then cat \"{_dir}/list.json\"; else echo busy >&2; exit 1; fi\n");
        var now = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        var wez = new WezTerm(executable: exe, socketDir: _dir, windows: true, clock: () => now);
        var procs = new Procs([]);

        Assert.Empty(await wez.WindowsAsync(procs));
        File.WriteAllText(Path.Combine(_dir, "ok"), "");
        Assert.Empty(await wez.WindowsAsync(procs)); // skipped right after failing
        now = now.AddMinutes(1);
        Assert.Equal(["wezterm:4242/3"], (await wez.WindowsAsync(procs)).Select(w => w.Key));
    }

    [Fact]
    public async Task MissingOnWindowsOffersAnInstallFix()
    {
        var s = await new WezTerm(
            executable: "/nonexistent-pocketterm/wezterm.exe",
            socketDir: "/nonexistent-pocketterm",
            windows: true).StatusAsync(new Procs([]));
        Assert.Equal((TermState.Missing, (TermFix?)TermFix.Install), (s.State, s.Fix));
    }

    /// <summary>A WezTerm (GUI pid 1) with windows 0 and 3 whose <c>spawn</c> makes pane 9 and writes its
    /// arguments to <c>spawned</c>.</summary>
    private WezTerm Two() => Fake(
        // Its arguments: cli --no-auto-start <command> ...
        "case \"$1 $3\" in\n" +
        "\"cli list\") echo '[{\"window_id\":0,\"tab_id\":0,\"pane_id\":0},{\"window_id\":3,\"tab_id\":4,\"pane_id\":5}]';;\n" +
        $"\"cli spawn\") shift 3; echo \"$*\" > {_dir}/spawned; echo 9;;\n" +
        "esac");

    private string Spawned() => File.ReadAllText(Path.Combine(_dir, "spawned")).Trim();

    [WezPosixFact]
    public async Task ANewSessionAskedIntoAWindowIsATabInIt()
    {
        Assert.Equal("wezterm:1/9", await Two().LaunchAsync(_dir, into: "wezterm:1/w3"));
        Assert.Equal($"--window-id 3 --cwd {_dir}", Spawned());
    }

    [WezPosixFact]
    public async Task ANewSessionAskedIntoAWindowThatIsGoneIsANewWindow()
    {
        foreach (var into in new[] { "wezterm:1/w7", "wezterm:2/w3" })
        {
            Assert.Equal("wezterm:1/9", await Two().LaunchAsync(_dir, into: into));
            Assert.Equal($"--new-window --cwd {_dir}", Spawned());
        }
    }

    [WezPosixFact]
    public async Task ANewSessionAskedIntoNoWindowIsANewWindowEvenWithWindowsOpen()
    {
        Assert.Equal("wezterm:1/9", await Two().LaunchAsync(_dir, command: ["omp"]));
        Assert.Equal($"--new-window --cwd {_dir} -- omp", Spawned());
    }

    [Fact]
    public async Task ANewSessionInAFolderThatIsGoneSaysSo()
    {
        var w = new WezTerm(executable: "/nonexistent-pocketterm/wezterm", socketDir: _dir, windows: true);
        var gone = Path.Combine(_dir, "gone");
        await Says($"No such folder: {gone}", () => w.LaunchAsync(gone));
    }
}
