using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>
/// Every terminal on this computer as one: their windows listed together, each request routed to the
/// window's own terminal, and new windows opened where the person works. On Windows that is WezTerm
/// alone (<see cref="Standard"/>).
/// <para>Ported from the Dart core's <c>terminals.dart</c> for the Windows app. Left out, as the Mac's
/// only: the kitty, tmux, iTerm2 and Ghostty hosts and what only they need — merging a terminal window
/// attached to tmux into its tmux pane (<c>merge</c>, <c>tieGhostty</c>, the windows PocketTerm opened
/// to show a pane), running new windows of a limited terminal in tmux, finding a Ghostty window by its
/// folder in <see cref="LocateAsync"/>, and the Mac's most-recently-used apps (<c>lsappinfo</c>). The
/// macOS app has them in Swift. The class still takes any list of hosts.</para>
/// Thread-safe: its only state, <see cref="Problems"/>, is replaced whole.
/// </summary>
public sealed partial class Terminals
{
    /// <param name="hosts">The terminals, in the order their windows are listed.</param>
    /// <param name="snapshot">The computer's processes now; tests pass their own.</param>
    /// <param name="recency">App names, most recently used first; none on Windows. Tests pass their own.</param>
    /// <param name="windows">Windows' rules for folders and project names (this platform's if null).</param>
    public Terminals(
        string home,
        IReadOnlyList<TerminalHost> hosts,
        Func<Task<Procs>>? snapshot = null,
        Func<Task<IReadOnlyList<string>>>? recency = null,
        bool? windows = null)
    {
        Home = home;
        Hosts = hosts;
        _windows = windows ?? OperatingSystem.IsWindows();
        var w = _windows;
        _snapshot = snapshot ?? (() => Procs.SnapshotAsync(w));
        _recency = recency ?? (() => Task.FromResult<IReadOnlyList<string>>([]));
    }

    /// <summary>The terminals of this computer: WezTerm alone on Windows (<paramref name="windowsPath"/>:
    /// the PATH a new login has, for the WezTerm it starts; see <see cref="WezTerm"/>). Elsewhere too,
    /// WezTerm is the one host ported (<paramref name="kittyDir"/>, kitty's sockets, is for the Mac's
    /// hosts, which the macOS app has).
    /// </summary>
    public static Terminals Standard(string kittyDir = "/tmp", string? home = null, bool? windows = null, Func<string>? windowsPath = null)
    {
        var win = windows ?? OperatingSystem.IsWindows();
        var h = home ?? Terminal.HomeDir(windows: win);
        return win
            ? new Terminals(h, [new WezTerm(home: h, windows: true, windowsPath: windowsPath)], windows: true)
            : new Terminals(h, [new WezTerm(home: h, windows: false)], windows: false);
    }

    private readonly bool _windows;
    private readonly Func<Task<Procs>> _snapshot;
    private readonly Func<Task<IReadOnlyList<string>>> _recency;

    /// <summary>The home folder, which the phone shows as ~.</summary>
    public string Home { get; }

    /// <summary>In the order their windows are listed.</summary>
    public IReadOnlyList<TerminalHost> Hosts { get; }

    /// <summary>The terminal apps (tmux isn't one), in the order Auto prefers them when none was used lately.</summary>
    public IReadOnlyList<TerminalHost> Apps => Hosts.Where(h => h.Id != "tmux").ToList();

    /// <summary>WezTerm, when it's one of <see cref="Hosts"/>.</summary>
    public WezTerm? WezTerm => Hosts.OfType<WezTerm>().FirstOrDefault();

    /// <summary>The computer's processes now.</summary>
    public Task<Procs> SnapshotAsync() => _snapshot();

    private volatile IReadOnlyDictionary<string, string> _problems = new Dictionary<string, string>();

    /// <summary>What each terminal said went wrong on the last <see cref="WindowsAsync"/>, by id.</summary>
    public IReadOnlyDictionary<string, string> Problems => _problems;

    public TerminalHost? HostOf(string key) => Hosts.FirstOrDefault(h => h.Owns(key));

    private TerminalHost Host(string key) => HostOf(key) ?? throw new TerminalException("That window is gone.");

    /// <summary>What window <paramref name="key"/>'s terminal can do.</summary>
    public IReadOnlySet<TermCap> CapsOf(string key) => HostOf(key)?.Caps ?? new HashSet<TermCap>();

    public bool Can(string key, TermCap cap) => CapsOf(key).Contains(cap);

    /// <summary>What an error says, as the person reads it.</summary>
    private static string Says(Exception e) => e.Message;

    /// <summary>Every window of every terminal. An omp window with a tty carries the profile its command
    /// line names (<see cref="TermWindow.Profile"/>).</summary>
    public async Task<List<TermWindow>> WindowsAsync()
    {
        var procs = await _snapshot();
        var problems = new Dictionary<string, string>();
        var lists = await Task.WhenAll(Hosts.Select(async h =>
        {
            try
            {
                return await h.WindowsAsync(procs);
            }
            catch (Exception e)
            {
                lock (problems) problems[h.Id] = Says(e);
                return (IReadOnlyList<TermWindow>)[];
            }
        }));
        _problems = problems;
        return lists
            .SelectMany(l => l)
            .Select(w => w.Agent == Agent.Omp && w.Tty.Length > 0
                ? w with { Profile = Agents.OmpProfileOfArgs(procs.Foreground(w.Tty)?.Args ?? "") }
                : w)
            .ToList();
    }

    /// <summary>How each installed terminal stands, for Settings and the phone.</summary>
    public async Task<List<TermStatus>> StatusesAsync()
    {
        var procs = await _snapshot();
        var all = await Task.WhenAll(Hosts.Select(async h =>
        {
            try
            {
                return await h.StatusAsync(procs);
            }
            catch (Exception e)
            {
                return new TermStatus(h.Id, h.Label, TermState.Limited, Note: Says(e));
            }
        }));
        return all.ToList();
    }

    /// <summary>Where an agent runs, from the <c>term</c> its extension reports
    /// (<see cref="Terminal.WindowOfTerm"/>). <paramref name="cwd"/>, <paramref name="title"/>,
    /// <paramref name="agent"/> and <paramref name="claimed"/> found a Ghostty window on a Mac, which
    /// tells nothing to match; WezTerm always tells its pane.</summary>
    public Task<string?> LocateAsync(JsonObject? term, string cwd, string title, Agent agent, IReadOnlySet<string> claimed) =>
        Task.FromResult(term == null ? null : Terminal.WindowOfTerm(term));

    // ------------------------------------------------------------ requests

    public Task<IReadOnlyList<string>> LinesAsync(string key, bool history = false) => Host(key).LinesAsync(key, history);

    public Task<string> PlainScreenAsync(string key) => Host(key).PlainScreenAsync(key);

    public Task<Dictionary<string, object>?> ColorsAsync(string key) => Host(key).ColorsAsync(key);

    public Task SendAsync(string key, string text, bool enter) => Host(key).SendAsync(key, text, enter);

    public Task TypeAsync(string key, string text) => Host(key).TypeAsync(key, text);

    public Task PressKeysAsync(string key, IReadOnlyList<string> names) => Host(key).PressKeysAsync(key, names);

    /// <summary>One of <see cref="Terminal.PhoneKeys"/> (what the phone may press).</summary>
    public async Task PressAsync(string key, string name)
    {
        if (!Terminal.PhoneKeys.Contains(name)) throw new TerminalException($"Unknown key: {name}");
        await PressKeysAsync(key, [name]);
    }

    /// <summary>Closes window <paramref name="key"/>.</summary>
    public Task CloseAsync(string key) => Host(key).CloseAsync(key);

    // ------------------------------------------------------------ new windows

    /// <summary>The terminal app new windows open in: <paramref name="choice"/> (an app's id) if it's
    /// installed; else (Auto) the running one used most recently; else the first installed of
    /// <see cref="Apps"/>.</summary>
    public async Task<TerminalHost> OpensInAsync(string choice)
    {
        var procs = await _snapshot();
        var statuses = new Dictionary<string, TermStatus>();
        foreach (var h in Apps)
        {
            try
            {
                statuses[h.Id] = await h.StatusAsync(procs);
            }
            catch (Exception)
            {
                statuses[h.Id] = new TermStatus(h.Id, h.Label, TermState.Limited);
            }
        }
        return PickApp(Apps, statuses, choice, await _recency());
    }

    /// <summary><see cref="OpensInAsync"/>'s choice among <paramref name="apps"/>, given their
    /// <paramref name="statuses"/> and the apps by <paramref name="recency"/>: a chosen app that's
    /// installed; else the usable one used last; else the first usable one; else the first that can be
    /// started (kitty can't be: it must listen first).</summary>
    public static TerminalHost PickApp(
        IReadOnlyList<TerminalHost> apps,
        IReadOnlyDictionary<string, TermStatus> statuses,
        string choice,
        IReadOnlyList<string> recency)
    {
        var chosen = apps.FirstOrDefault(h => h.Id == choice);
        if (chosen != null && statuses.GetValueOrDefault(choice)?.State != TermState.Missing) return chosen;
        foreach (var name in recency)
        {
            var h = apps.FirstOrDefault(h => h.AppName == name);
            if (h != null && (statuses.GetValueOrDefault(h.Id)?.Usable ?? false)) return h;
        }
        return apps.FirstOrDefault(h => statuses.GetValueOrDefault(h.Id)?.Usable ?? false) ??
            apps.FirstOrDefault(h => h.Id != "kitty" && statuses.GetValueOrDefault(h.Id)?.State == TermState.Idle) ??
            apps[^1];
    }

    /// <summary>Whether a window <paramref name="host"/> opens runs in tmux: never here, as tmux isn't one
    /// of the hosts (WezTerm can do everything anyway).</summary>
    public bool ViaTmux(TerminalHost host) => false;

    /// <summary>How the phone names where a new session opens: "WezTerm".</summary>
    public string Describe(TerminalHost host) => ViaTmux(host) ? $"{host.Label} (in tmux)" : host.Label;

    /// <summary>
    /// A new window in <paramref name="cwd"/> in <paramref name="host"/> running the login shell, which
    /// then starts <paramref name="agent"/> if given, in omp <paramref name="profile"/> ('' the default),
    /// with <paramref name="flags"/> after its command: with <see cref="Placement.ProjectWindow"/> a tab in
    /// <paramref name="host"/>'s window that holds <paramref name="cwd"/>'s tabs
    /// (<see cref="ProjectWindow"/>). Its key and where it went, as the phone says it.
    /// </summary>
    public async Task<Opened> LaunchAsync(
        string cwd,
        TerminalHost host,
        Agent? agent = null,
        Placement placement = Placement.ProjectWindow,
        string profile = "",
        string flags = "")
    {
        if (!Directory.Exists(cwd)) throw new TerminalException($"No such folder: {cwd}");
        var into = placement == Placement.ProjectWindow ? ProjectWindow(await WindowsAsync(), host, cwd, Home, _windows) : null;
        var key = await host.LaunchAsync(cwd, into: into);
        // The shell reads it once it's up: the terminal holds what's typed.
        if (agent is { } a)
        {
            var command = a.CommandIn(profile);
            await SendAsync(key, flags.Length == 0 ? command : $"{command} {flags}", enter: true);
        }
        var where = into == null
            ? $"a new {host.Label} window"
            : $"a new tab in the {host.Label} window with {ProjectName(cwd, Home, _windows)}";
        return new Opened(key, where);
    }

    /// <summary>Whether <paramref name="a"/> and <paramref name="b"/> are one folder as a terminal and
    /// tmux tell it (<c>/private/tmp</c> is <c>/tmp</c>); never for an empty one.</summary>
    private static bool SameFolder(string a, string b, bool windows) =>
        a.Length > 0 && b.Length > 0 &&
        (PathRules.Same(a, b, windows) || PathRules.Same($"/private{a}", b, windows) || PathRules.Same(a, $"/private{b}", windows));

    /// <summary>How a project folder is named to the person: its folder's name, and General for the home
    /// folder (where a session about nothing in particular starts). <paramref name="windows"/>: Windows'
    /// rules for folders (this platform's if null).</summary>
    public static string ProjectName(string cwd, string home, bool? windows = null)
    {
        var win = windows ?? OperatingSystem.IsWindows();
        return SameFolder(cwd, home, win) ? "General" : PathRules.Basename(cwd, win);
    }

    /// <summary>The window of <paramref name="host"/> (its <see cref="TermWindow.OsWindow"/>) whose tabs
    /// are most in <paramref name="cwd"/> (in it or under it; the home folder only itself, as nearly
    /// everything is under it), of <paramref name="windows"/>; the first such in the list on a tie; null
    /// when no tab of <paramref name="host"/>'s is there. A tmux pane counts for the app window showing
    /// it.</summary>
    public static string? ProjectWindow(
        IReadOnlyList<TermWindow> windows, TerminalHost host, string cwd, string home, bool? windowsRules = null)
    {
        var win = windowsRules ?? OperatingSystem.IsWindows();
        bool InProject(string dir) => SameFolder(dir, cwd, win) || Under(dir, cwd, home, win);
        var tabs = new List<(string Window, HashSet<string> Tabs)>();
        foreach (var w in windows)
        {
            var mine = w.Via.Length == 0 ? w.App == host.Id : w.Via == host.Label;
            if (!mine || w.OsWindow.Length == 0 || !InProject(w.Cwd)) continue;
            var at = tabs.FindIndex(t => t.Window == w.OsWindow);
            if (at < 0) tabs.Add((w.OsWindow, []));
            tabs[at < 0 ? ^1 : at].Tabs.Add(w.TabId.Length == 0 ? w.Key : w.TabId);
        }
        (string Window, HashSet<string> Tabs)? best = null;
        foreach (var t in tabs)
        {
            if (best == null || t.Tabs.Count > best.Value.Tabs.Count) best = t;
        }
        return best?.Window;
    }

    /// <summary>Whether <paramref name="dir"/> is somewhere under <paramref name="project"/> (not the home
    /// folder <paramref name="home"/>).</summary>
    private static bool Under(string dir, string project, string home, bool windows)
    {
        if (SameFolder(project, home, windows) || dir.Length == 0 || project.Length == 0) return false;
        static string Bare(string d) => d.StartsWith("/private/", StringComparison.Ordinal) ? d["/private".Length..] : d;
        // Either separator on Windows (WezTerm's folders there are C:\…), and its case.
        return PathRules.IsWithin(Bare(project), Bare(dir), windows);
    }

    /// <summary>Git repositories up to three levels under <paramref name="roots"/> (the Project folders
    /// setting), for the phone's New session list. A symlinked folder is followed (under the link's own
    /// path), each real folder once: a link loop, or two roots that are one folder, list nothing
    /// twice.</summary>
    public Task<List<string>> ProjectsAsync(IReadOnlyList<string> roots) => Task.Run(() =>
    {
        // Each repository by its real folder: under that path when it's found there too, else the first link to it.
        var found = new Dictionary<string, string>();
        // Each real folder walked, with how deep it was walked from there.
        var seen = new Dictionary<string, int>();
        void Walk(string dir, int depth)
        {
            string real;
            List<string> entries;
            try
            {
                real = PathRules.RealPath(dir);
                if (dir == real && found.ContainsKey(real)) found[real] = real;
                if (seen.GetValueOrDefault(real, -1) >= depth) return;
                seen[real] = depth;
                entries = Directory.EnumerateFileSystemEntries(dir).ToList();
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                return;
            }
            if (entries.Any(e => Path.GetFileName(e) == ".git"))
            {
                found[real] = dir == real ? real : found.GetValueOrDefault(real) ?? dir;
                return;
            }
            if (depth == 0) return;
            foreach (var e in entries)
            {
                var name = Path.GetFileName(e);
                if (name.StartsWith('.') || name == "node_modules") continue;
                // A folder, or a link to one.
                if (Directory.Exists(e)) Walk(e, depth - 1);
            }
        }

        foreach (var root in roots)
        {
            var dir = root.Length > 1 && root.EndsWith('/') ? root[..^1] : root;
            if (Directory.Exists(dir)) Walk(dir, 3);
        }
        var paths = found.Values.ToList();
        paths.Sort(StringComparer.Ordinal);
        return paths;
    });

    /// <summary>A new project folder <paramref name="name"/> under <paramref name="root"/>, which must be
    /// one of <paramref name="roots"/> (the Project folders setting); its path. Only the folder is made.
    /// <paramref name="windows"/>: also Windows' rules for names (these terminals' if null).</summary>
    public string CreateProject(string root, string name, IReadOnlyList<string> roots, bool? windows = null)
    {
        if (!roots.Contains(root)) throw new TerminalException($"Not one of your project folders: {root}");
        var n = name.DartTrim();
        if (n.Length == 0 || BadNameChar().IsMatch(n) || n.StartsWith('.') || n.Any(c => c < 0x20 || c == 0x7f))
        {
            throw new TerminalException(
                @"A project name can’t be empty, contain /, \, : or control characters, or start with a dot.");
        }
        if ((windows ?? _windows) && !Terminal.WindowsFileName(n))
        {
            throw new TerminalException(
                "Windows doesn’t allow that name: no < > \" | ? *, no dot at the end, " +
                "and not a device name such as CON, NUL, COM1 or LPT1.");
        }
        if (!Directory.Exists(root)) throw new TerminalException($"No such folder: {root}");
        var path = Path.Combine(root, n);
        if (File.Exists(path) || Directory.Exists(path)) throw new TerminalException($"There is already something named {n} there.");
        try
        {
            Directory.CreateDirectory(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            throw new TerminalException($"Couldn’t create {path}: {e.Message}");
        }
        return path;
    }

    /// <summary>The phone's New project: <see cref="CreateProject"/>, then a window in it as
    /// <see cref="LaunchAsync"/> (a window of its own: no tab is in a folder just made). Should no window
    /// open, the folder goes again (while still empty), so trying again with the same name works.</summary>
    public async Task<Opened> LaunchNewProjectAsync(
        string root,
        string name,
        IReadOnlyList<string> roots,
        TerminalHost host,
        Agent? agent = null,
        string profile = "")
    {
        var cwd = CreateProject(root, name, roots);
        try
        {
            return await LaunchAsync(cwd, host, agent, Placement.NewWindow, profile);
        }
        catch
        {
            try
            {
                Directory.Delete(cwd);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // Something was put in it meanwhile: it stays.
            }
            throw;
        }
    }

    [GeneratedRegex(@"[/\\:]")]
    private static partial Regex BadNameChar();
}
