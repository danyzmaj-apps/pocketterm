using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>
/// WezTerm, through <c>wezterm cli</c> against each running GUI's socket
/// (<c>~/.local/share/wezterm/gui-sock-&lt;pid&gt;</c>, on Windows too). Window keys:
/// <c>wezterm:&lt;gui pid&gt;/&lt;pane id&gt;</c>; its window <c>wezterm:&lt;gui pid&gt;/w&lt;window id&gt;</c>
/// and its tab <c>wezterm:&lt;gui pid&gt;/t&lt;tab id&gt;</c>, as <c>cli list</c> tells them.
/// Thread-safe: the found executable, the sockets that stopped answering and the asked release
/// sit behind one lock, never held across an await.
/// </summary>
public sealed partial class WezTerm : TerminalHost
{
    /// <param name="clock">The time, for when a socket that stopped answering is asked again.</param>
    /// <param name="windowsPath">On Windows, the PATH a new login would have
    /// (<see cref="Terminal.MergeWindowsPath"/>), to find wezterm and to hand the WezTerm it starts, so a
    /// shell there finds what was installed while PocketTerm ran; PocketTerm's own PATH if null.</param>
    public WezTerm(
        string? executable = null,
        string? socketDir = null,
        string? home = null,
        bool? windows = null,
        Func<DateTime>? clock = null,
        Func<string>? windowsPath = null)
    {
        _given = executable;
        _windows = windows ?? OperatingSystem.IsWindows();
        _now = clock ?? (() => DateTime.UtcNow);
        _windowsPath = windowsPath;
        _dir = socketDir ?? Path.Combine(home ?? Terminal.HomeDir(windows: _windows), ".local", "share", "wezterm");
    }

    private readonly object _lock = new();
    private readonly string? _given;
    private readonly Func<string>? _windowsPath;
    private readonly string _dir;
    private readonly bool _windows;
    private readonly Func<DateTime> _now;
    private string? _found;

    private string? Find() => Terminal.FindExecutable(
        "wezterm",
        extra: _windows
            ? [$"{Environment.GetEnvironmentVariable("ProgramFiles") ?? @"C:\Program Files"}\\WezTerm\\wezterm.exe"]
            : ["/Applications/WezTerm.app/Contents/MacOS/wezterm"],
        env: _windows && _windowsPath != null ? new Dictionary<string, string> { ["PATH"] = _windowsPath() } : null,
        windows: _windows);

    /// <summary>Looked for again while it isn't found: WezTerm installed while PocketTerm runs (Settings
    /// or the setup checklist installs it) counts.</summary>
    private string? Exe
    {
        get
        {
            if (_given != null) return _given;
            lock (_lock)
            {
                if (_found != null) return _found;
            }
            var found = Find();
            lock (_lock)
            {
                return _found ??= found;
            }
        }
    }

    /// <summary>Sockets that stopped answering (Windows, where a GUI's socket outlives it), by when: not
    /// asked again for <see cref="DeadFor"/>. A live GUI that was slow once comes back; a stale socket
    /// whose GUI's pid a process snapshot lacks is skipped by <see cref="Sockets"/> anyway.</summary>
    private readonly Dictionary<string, DateTime> _dead = [];

    private static readonly TimeSpan DeadFor = TimeSpan.FromMinutes(1);

    private bool IsDead(string socket)
    {
        lock (_lock)
        {
            if (!_dead.TryGetValue(socket, out var at)) return false;
            if (_now() - at < DeadFor) return true;
            _dead.Remove(socket);
            return false;
        }
    }

    private void MarkDead(string socket)
    {
        lock (_lock) _dead[socket] = _now();
    }

    public override string Id => "wezterm";

    public override string Label => "WezTerm";

    public override string? AppName => "WezTerm";

    public override string? BundleId => "com.github.wez.wezterm";

    public override IReadOnlySet<TermCap> Caps => TermCaps.All;

    public override bool Owns(string key) => key.StartsWith("wezterm:", StringComparison.Ordinal);

    /// <summary>Whether wezterm is on this computer now.</summary>
    public bool Installed => Exe is { } exe && File.Exists(exe);

    /// <summary>GUI pid → its socket, in the folder's order, for each socket whose GUI still runs (when
    /// <paramref name="procs"/> tell: on Windows, an empty process list tells nothing) and that didn't
    /// stop answering.</summary>
    private List<(string Pid, string Socket)> Sockets(Procs? procs)
    {
        if (!Directory.Exists(_dir)) return [];
        var out_ = new List<(string, string)>();
        var check = procs != null && !(_windows && procs.All.Count == 0);
        IEnumerable<string> entries;
        try
        {
            entries = Directory.EnumerateFileSystemEntries(_dir).ToList();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return [];
        }
        foreach (var e in entries)
        {
            if (Directory.Exists(e)) continue;
            var m = SocketName().Match(Path.GetFileName(e));
            if (!m.Success || IsDead(e)) continue;
            var pid = m.Groups[1].Value;
            if (check && (!int.TryParse(pid, out var n) || procs!.ByPid(n) == null)) continue;
            out_.Add((pid, e));
        }
        return out_;
    }

    /// <summary>What a WezTerm too old for a command PocketTerm sends says.</summary>
    public const string TooOld = "WezTerm is too old: update it.";

    /// <summary>The most UTF-8 bytes of text one <c>send-text</c> carries: it goes on the command line, at
    /// most 32K characters on Windows.</summary>
    public const int TypeBytes = 8000;

    /// <summary><c>wezterm cli</c> with <paramref name="args"/> on the GUI behind
    /// <paramref name="socket"/>; killed when it hasn't answered in five seconds.</summary>
    private async Task<string> CliAsync(string socket, IReadOnlyList<string> args)
    {
        var exe = Exe ?? throw new TerminalException("WezTerm is not installed.");
        var info = new ProcessStartInfo(exe)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            // wezterm writes UTF-8 (the default is the ANSI code page on Windows); anything malformed
            // reads as U+FFFD rather than failing the answer.
            StandardOutputEncoding = Utf8,
            StandardErrorEncoding = Utf8,
        };
        info.ArgumentList.Add("cli");
        info.ArgumentList.Add("--no-auto-start");
        foreach (var a in args) info.ArgumentList.Add(a);
        info.Environment["WEZTERM_UNIX_SOCKET"] = socket;
        Process p;
        try
        {
            p = Process.Start(info) ?? throw new TerminalException("WezTerm: it didn't start.");
        }
        catch (Win32Exception e)
        {
            throw new TerminalException($"WezTerm: {new Win32Exception(e.NativeErrorCode).Message}");
        }
        using (p)
        {
            try
            {
                p.StandardInput.Close();
            }
            catch (IOException)
            {
                // It quit already.
            }
            var out_ = p.StandardOutput.ReadToEndAsync();
            var err = p.StandardError.ReadToEndAsync();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            try
            {
                await p.WaitForExitAsync(timeout.Token);
            }
            catch (OperationCanceledException)
            {
                try
                {
                    p.Kill();
                }
                catch (InvalidOperationException)
                {
                    // Gone meanwhile.
                }
                if (_windows) MarkDead(socket);
                throw new TerminalException("WezTerm did not answer.");
            }
            if (p.ExitCode != 0)
            {
                var e = (await err).DartTrim();
                if (e.Contains("no such pane") || e.Contains("is not valid") || e.Contains("pane") && e.Contains("not found"))
                {
                    throw new TerminalException("That window is gone.");
                }
                // A command or flag this WezTerm doesn't have: the GUI is fine.
                if (e.Contains("unrecognized subcommand") || e.Contains("unexpected argument"))
                {
                    throw new TerminalException(TooOld);
                }
                if (_windows) MarkDead(socket);
                // Its GUI quit and left the socket behind.
                if (e.Contains("failed to connect")) throw new TerminalException("WezTerm isn't running.");
                // Its last line, without the log's time and level, or the reason the GUI gave.
                var last = LogPrefix().Replace(e.Split('\n')[^1], "", 1);
                var reason = Reason().Match(last);
                throw new TerminalException($"WezTerm: {(reason.Success ? reason.Groups[1].Value : last)}");
            }
            await err;
            return await out_;
        }
    }

    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);

    private (string Socket, string Pane) Parse(string key)
    {
        var m = PaneKey().Match(key);
        var socket = m.Success ? Sockets(null).FirstOrDefault(s => s.Pid == m.Groups[1].Value).Socket : null;
        if (socket == null) throw new TerminalException("That window is gone.");
        return (socket, m.Groups[2].Value);
    }

    public override async Task<TermStatus> StatusAsync(Procs procs)
    {
        if (!Installed)
        {
            return _windows
                ? new TermStatus(
                    Id,
                    Label,
                    TermState.Missing,
                    Note: "Needed for your phone to reach this PC's terminals",
                    Fix: TermFix.Install)
                : new TermStatus(Id, Label, TermState.Missing);
        }
        if (await ReleaseAsync() is { } release && release < MinRelease)
        {
            return new TermStatus(
                Id,
                Label,
                TermState.Setup,
                Note: $"WezTerm {release} is too old for PocketTerm: update it to {MinRelease} or later" +
                    (_windows ? " (winget upgrade wez.wezterm)" : ""));
        }
        if (Sockets(procs).Count == 0) return new TermStatus(Id, Label, TermState.Idle, Note: "Not running");
        var n = (await WindowsAsync(procs)).Count;
        return new TermStatus(Id, Label, TermState.Ready, Note: $"{n} window{(n == 1 ? "" : "s")}");
    }

    /// <summary>The oldest WezTerm release (its date) whose <c>wezterm cli</c> has all PocketTerm uses:
    /// kill-pane came in 20230326-111934-3666303c.</summary>
    public const int MinRelease = 20230326;

    private (string Exe, DateTime Modified, int? Release)? _asked;

    /// <summary>The release date of the installed wezterm, asked once per version of the file (an update
    /// in place is asked again); null when it doesn't say.</summary>
    private async Task<int?> ReleaseAsync()
    {
        var exe = Exe;
        if (exe == null) return null;
        DateTime modified;
        try
        {
            if (!File.Exists(exe)) return null;
            modified = File.GetLastWriteTimeUtc(exe);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
        lock (_lock)
        {
            if (_asked is var (e, at, r) && e == exe && at == modified) return r;
        }
        int? release;
        try
        {
            release = WezTermRelease(await VersionAsync(exe));
        }
        catch (Exception)
        {
            release = null;
        }
        lock (_lock) _asked = (exe, modified, release);
        return release;
    }

    /// <summary><c>wezterm --version</c>'s output; throws when it can't run or takes over five seconds.</summary>
    private static async Task<string> VersionAsync(string exe)
    {
        var info = new ProcessStartInfo(exe)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Utf8,
        };
        info.ArgumentList.Add("--version");
        using var p = Process.Start(info) ?? throw new TerminalException("WezTerm: it didn't start.");
        var out_ = p.StandardOutput.ReadToEndAsync();
        var err = p.StandardError.ReadToEndAsync();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        try
        {
            await p.WaitForExitAsync(timeout.Token);
        }
        catch (OperationCanceledException)
        {
            try
            {
                p.Kill();
            }
            catch (InvalidOperationException)
            {
                // Gone meanwhile.
            }
            throw;
        }
        await err;
        return await out_;
    }

    public override async Task<IReadOnlyList<TermWindow>> WindowsAsync(Procs procs)
    {
        var out_ = new List<TermWindow>();
        foreach (var (pid, socket) in Sockets(procs))
        {
            string json;
            try
            {
                json = await CliAsync(socket, ["list", "--format", "json"]);
            }
            catch (TerminalException)
            {
                continue;
            }
            out_.AddRange(ParseWezTermList(pid, json, procs, _windows));
        }
        // The foreground program's own folder, where the shell's report is older.
        var cwds = await Procs.CwdsAsync(
            out_.Select(w => procs.Foreground(w.Tty)).OfType<Proc>().Select(p => p.Pid).ToList(),
            _windows);
        return out_
            .Select(w => procs.Foreground(w.Tty) is { } p && cwds.TryGetValue(p.Pid, out var cwd) ? w with { Cwd = cwd } : w)
            .ToList();
    }

    public override async Task<IReadOnlyList<string>> LinesAsync(string key, bool history = false)
    {
        var (socket, pane) = Parse(key);
        List<string> args = ["get-text", "--pane-id", pane, "--escapes"];
        if (history) args.AddRange(["--start-line", "-10000"]);
        return Terminal.ScreenLines(await CliAsync(socket, args));
    }

    public override async Task<string> PlainScreenAsync(string key)
    {
        var (socket, pane) = Parse(key);
        return (await CliAsync(socket, ["get-text", "--pane-id", pane])).TrimEnd();
    }

    /// <summary><c>--no-paste</c>: as typed, not a bracketed paste.</summary>
    private async Task WriteAsync(string key, string bytes)
    {
        var (socket, pane) = Parse(key);
        await CliAsync(socket, ["send-text", "--pane-id", pane, "--no-paste", "--", bytes]);
    }

    /// <summary>In pieces of <see cref="TypeBytes"/>, a command each.</summary>
    public override async Task TypeAsync(string key, string text)
    {
        foreach (var chunk in Terminal.TextChunks(text, TypeBytes)) await WriteAsync(key, chunk);
    }

    public override async Task PressKeysAsync(string key, IReadOnlyList<string> names)
    {
        var runs = Terminal.KeyRuns(names);
        for (var i = 0; i < runs.Count; i++)
        {
            if (i > 0) await Task.Delay(TimeSpan.FromMilliseconds(40));
            await WriteAsync(key, runs[i]);
        }
    }

    public override async Task CloseAsync(string key)
    {
        var (socket, pane) = Parse(key);
        await CliAsync(socket, ["kill-pane", "--pane-id", pane]);
    }

    /// <summary>
    /// With <paramref name="into"/> (<c>wezterm:&lt;gui pid&gt;/w&lt;id&gt;</c>), a new tab in that window;
    /// otherwise, or if that window is gone, a new window. A WezTerm not running is started in the
    /// background (on Windows, its GUI in <paramref name="cwd"/>), and its first window is the new one.
    /// </summary>
    public override async Task<string> LaunchAsync(string cwd, IReadOnlyList<string>? command = null, string? into = null)
    {
        if (!Directory.Exists(cwd)) throw new TerminalException($"No such folder: {cwd}");
        var sockets = Sockets(await Procs.SnapshotAsync(_windows));
        var fresh = sockets.Count == 0;
        if (fresh)
        {
            if (_windows)
            {
                var exe = Exe ?? throw new TerminalException("WezTerm is not installed.");
                StartGui(Path.Combine(Path.GetDirectoryName(exe) ?? "", "wezterm-gui.exe"), cwd);
            }
            else
            {
                await RunAsync("/usr/bin/open", ["-g", "-a", "WezTerm"]);
            }
            for (var i = 0; i < 40 && sockets.Count == 0; i++)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(250));
                sockets = Sockets(await Procs.SnapshotAsync(_windows));
            }
            if (sockets.Count == 0) throw new TerminalException("WezTerm didn't start.");
        }
        // The GUI holding [into], else the newest one.
        var target = WindowKey().Match(into ?? "");
        var at = target.Success ? sockets.FindLastIndex(s => s.Pid == target.Groups[1].Value) : -1;
        var (pid, socket) = at >= 0 ? sockets[at] : sockets[^1];
        var panes = (DartJson.Decode(await CliAsync(socket, ["list", "--format", "json"])) as JsonArray ?? [])
            .OfType<JsonObject>()
            .ToList();
        if (fresh && command == null && panes.Count == 1)
        {
            var key = $"wezterm:{pid}/{Text(panes[0]["pane_id"])}";
            // Windows' GUI started in cwd already.
            if (!_windows) await TypeAsync(key, $" cd -- {Terminal.ShellQuote(cwd)} && clear\r");
            return key;
        }
        var window = target.Success && target.Groups[1].Value == pid &&
            panes.Any(p => Text(p["window_id"]) == target.Groups[2].Value)
                ? target.Groups[2].Value
                : null;
        List<string> args = ["spawn"];
        if (window != null) args.AddRange(["--window-id", window]);
        else args.Add("--new-window");
        args.AddRange(["--cwd", cwd]);
        if (command != null)
        {
            args.Add("--");
            args.AddRange(command);
        }
        // On a Mac the Dart host kept the front app around a new window (keepFront); the macOS app is
        // Swift, and on Windows WezTerm's new window may take the front as it did there.
        var pane = (await CliAsync(socket, args)).DartTrim();
        return $"wezterm:{pid}/{pane}";
    }

    /// <summary>WezTerm's GUI in <paramref name="cwd"/>, on its own: its shells find what was installed
    /// since PocketTerm started.</summary>
    private void StartGui(string gui, string cwd)
    {
        var info = new ProcessStartInfo(gui) { UseShellExecute = false };
        info.ArgumentList.Add("start");
        info.ArgumentList.Add("--cwd");
        info.ArgumentList.Add(cwd);
        if (_windowsPath != null) info.Environment["PATH"] = _windowsPath();
        try
        {
            Process.Start(info)?.Dispose();
        }
        catch (Win32Exception e)
        {
            throw new TerminalException($"WezTerm: {new Win32Exception(e.NativeErrorCode).Message}");
        }
    }

    private static async Task RunAsync(string exe, IReadOnlyList<string> args)
    {
        var info = new ProcessStartInfo(exe) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var a in args) info.ArgumentList.Add(a);
        try
        {
            using var p = Process.Start(info);
            if (p == null) return;
            var out_ = p.StandardOutput.ReadToEndAsync();
            var err = p.StandardError.ReadToEndAsync();
            await p.WaitForExitAsync();
            await Task.WhenAll(out_, err);
        }
        catch (Win32Exception e)
        {
            throw new TerminalException($"WezTerm: {new Win32Exception(e.NativeErrorCode).Message}");
        }
    }

    /// <summary>A JSON value as Dart's string interpolation writes it (<c>3</c>, <c>null</c>).</summary>
    private static string Text(JsonNode? n) => n == null ? "null" : DartJson.AsString(n) ?? DartJson.Encode(n);

    /// <summary><c>wezterm cli list --format json</c> (the GUI with pid <paramref name="pid"/>) as windows.
    /// A pane with no tty (Windows) names its program by its title. <paramref name="windows"/>: folders
    /// as Windows has them (<see cref="CwdOfUri"/>).</summary>
    public static List<TermWindow> ParseWezTermList(
        string pid, string json, Procs? procs = null, bool windows = false, string? localHost = null)
    {
        var list = DartJson.Decode(json) as JsonArray ?? throw new FormatException("Not a list of panes");
        var out_ = new List<TermWindow>();
        foreach (var node in list)
        {
            var pane = node as JsonObject ?? throw new FormatException("Not a pane");
            var tty = (DartJson.AsString(pane["tty_name"]) ?? "").ReplaceFirst("/dev/", "");
            var title = Terminal.CleanTitle(DartJson.AsString(pane["title"]) ?? "");
            var fg = procs?.Foreground(tty);
            // A `%` the shell didn't escape (a folder named `100%`) as itself.
            var cwd = DartUri.TryParse(BarePercent().Replace(DartJson.AsString(pane["cwd"]) ?? "", "%25"));
            out_.Add(new TermWindow
            {
                Key = $"wezterm:{pid}/{Text(pane["pane_id"])}",
                OsWindow = $"wezterm:{pid}/w{Text(pane["window_id"])}",
                TabId = $"wezterm:{pid}/t{Text(pane["tab_id"])}",
                Title = title,
                Tab = Terminal.CleanTitle(DartJson.AsString(pane["tab_title"]) ?? ""),
                Cwd = cwd != null && cwd.Scheme == "file" ? CwdOfUri(cwd, windows, localHost) : "",
                Program = fg?.Program ?? (tty.Length == 0 ? Terminal.ProgramOfTitle(title) : ""),
                Focused = DartJson.AsBool(pane["is_active"]) == true,
                App = "wezterm",
                Tty = tty,
            });
        }
        return out_;
    }

    /// <summary>
    /// A <c>file:</c> URI's folder: a Mac's path as is; <c>file:///C:/Users/x/</c> (any host dropped) as
    /// <c>C:\Users\x</c>, a drive's root as <c>C:\</c>. <paramref name="windows"/>: a share's
    /// (<c>file://wsl.localhost/Ubuntu/home/x/</c>, <c>file://wsl$/…</c>, <c>file://server/share/</c>) as
    /// its UNC path (<c>\\wsl.localhost\Ubuntu\home\x</c>), unless its host is this computer
    /// (<paramref name="localHost"/>, else its name, or localhost): a WSL shell telling its own Linux
    /// folder, kept as is.
    /// </summary>
    public static string CwdOfUri(DartUri u, bool windows = false, string? localHost = null)
    {
        static string Trim(string path, int root) =>
            path.Length > root && path.EndsWith('\\') ? path[..^1] : path;
        if (DrivePath().IsMatch(u.Path)) return Trim(WindowsFilePath(u.Path[1..]), 3);
        var host = u.Host.ToLowerInvariant();
        var here = (localHost ?? System.Net.Dns.GetHostName()).ToLowerInvariant();
        if (windows && host.Length > 0 && host != "localhost" && host != here && u.Path.Length > 1)
        {
            return Trim($"\\\\{host}{WindowsFilePath(u.Path)}", 2);
        }
        return DecodePercent(u.Path);
    }

    /// <summary>A URI path as Windows writes it: escapes decoded, <c>\</c> between its parts.</summary>
    private static string WindowsFilePath(string path) => DecodePercent(path).Replace('/', '\\');

    /// <summary><paramref name="path"/> with its <c>%XX</c> escapes as the UTF-8 they stand for; bytes that
    /// aren't UTF-8 as U+FFFD rather than an error.</summary>
    private static string DecodePercent(string path) => PercentRun().Replace(path, m =>
    {
        var bytes = new byte[m.Value.Length / 3];
        for (var i = 0; i < bytes.Length; i++) bytes[i] = Convert.ToByte(m.Value.Substring(i * 3 + 1, 2), 16);
        return Utf8.GetString(bytes);
    });

    /// <summary>The release date <c>wezterm --version</c> tells (<c>wezterm 20240203-110809-5046fc22</c> →
    /// 20240203); null for a build that tells none.</summary>
    public static int? WezTermRelease(string version) =>
        ReleaseDate().Match(version) is { Success: true } m ? int.Parse(m.Groups[1].Value) : null;

    [GeneratedRegex(@"^gui-sock-(\d+)\z")]
    private static partial Regex SocketName();

    [GeneratedRegex(@"^[\d:.]+\s+ERROR\s+\S+\s+>\s*")]
    private static partial Regex LogPrefix();

    [GeneratedRegex(@"reason: ""(?:Error: )?((?:[^""\\]|\\.)*)""")]
    private static partial Regex Reason();

    [GeneratedRegex(@"^wezterm:(\d+)/(\d+)\z")]
    private static partial Regex PaneKey();

    [GeneratedRegex(@"^wezterm:(\d+)/w(\d+)\z")]
    private static partial Regex WindowKey();

    [GeneratedRegex("%(?![0-9A-Fa-f]{2})")]
    private static partial Regex BarePercent();

    [GeneratedRegex("^/[A-Za-z]:/")]
    private static partial Regex DrivePath();

    [GeneratedRegex("(?:%[0-9A-Fa-f]{2})+")]
    private static partial Regex PercentRun();

    [GeneratedRegex(@"\b(\d{8})-\d{6}-[0-9a-f]+\b")]
    private static partial Regex ReleaseDate();
}

/// <summary>Dart string helpers the terminal hosts use.</summary>
internal static class DartStrings
{
    /// <summary>Dart's <c>replaceFirst</c> with a plain string.</summary>
    public static string ReplaceFirst(this string s, string from, string to)
    {
        var i = s.IndexOf(from, StringComparison.Ordinal);
        return i < 0 ? s : string.Concat(s.AsSpan(0, i), to, s.AsSpan(i + from.Length));
    }
}
