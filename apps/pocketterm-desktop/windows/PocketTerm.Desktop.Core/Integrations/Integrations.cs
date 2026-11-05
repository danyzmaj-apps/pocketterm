using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>Where an agent's PocketTerm integration stands: installed, and current (the same as the copy
/// bundled with the app), or the problem that keeps it from being installed at all.</summary>
public sealed record IntegrationState(bool Installed, bool Current, string? Problem);

/// <summary>A coding agent found on this computer and PocketTerm in it: <see cref="State"/> as
/// <see cref="Integrations.StateAsync"/> has it, <see cref="ModsOff"/> as <see cref="Integrations.ClaudeModsOffAsync"/>.</summary>
public sealed record AgentCheck(IntegrationState State, bool ModsOff);

/// <summary>Installing an integration failed: <see cref="Exception.Message"/> says why, for Settings.</summary>
public sealed class IntegrationException(string message) : Exception(message)
{
    public override string ToString() => Message;
}

/// <summary>
/// Installs the coding agents' PocketTerm integrations (apps/pocketterm-desktop/integrations) from the
/// copies bundled with the app: omp's extension, Claude Code's plugin. Keeps no state of its own, so
/// any thread may call it; installs of the same agent at once are the caller's to avoid (Settings runs
/// one at a time).
/// </summary>
public sealed partial class Integrations
{
    /// <summary>What a run of a program ended with, its output read as UTF-8.</summary>
    public sealed record RunResult(int ExitCode, string Stdout, string Stderr);

    /// <summary>Runs <paramref name="executable"/> with <paramref name="arguments"/> (tests pass their own).</summary>
    public delegate Task<RunResult> Run(string executable, IReadOnlyList<string> arguments);

    /// <summary>
    /// The folders bundled with the Flutter app (its pubspec's assets), below the integrations folder:
    /// only the files right in each, so Claude Code's plugin goes without its tests/. The install
    /// writes exactly these, whatever else the app's integrations folder holds.
    /// </summary>
    internal static readonly string[] BundledDirs =
    [
        "omp",
        "claude/.claude-plugin",
        "claude/plugins/pocketterm/.claude-plugin",
        "claude/plugins/pocketterm/hooks",
    ];

    /// <summary>What Settings says when a <c>claude</c> run outlasts its timeout.</summary>
    public const string NoAnswer = "Claude Code didn't answer";

    /// <summary>What to do while Claude Code has mods off (<see cref="ClaudeModsOffAsync"/>): its rollout switch
    /// stays cached as off until Claude Code, logged in, fetches it again.</summary>
    public const string ModsOffHint =
        "Claude Code has mods turned off for now: run claude /login, start claude once, " +
        "then type /reload-plugins in your Claude Code sessions";

    /// <summary>The oldest Claude Code whose plugins may have mods (hooks/*.ts).</summary>
    public static readonly IReadOnlyList<int> MinClaude = [2, 1, 287];

    private const string Plugin = "pocketterm@pocketterm";

    private readonly Func<string> _windowsPath;
    private readonly string _bundled;
    private readonly Run _run;
    private readonly bool _windows;
    private readonly TimeSpan _claudeTimeout;
    private readonly IReadOnlyList<string>? _claudePaths;
    private readonly IReadOnlyList<string>? _ompPaths;

    /// <summary>
    /// <paramref name="home"/>: the home folder (<see cref="Terminal.HomeDir"/> if null).
    /// <paramref name="bundled"/>: the integrations folder bundled with the app (<see cref="AppPaths.IntegrationsDir"/> if null).
    /// <paramref name="run"/>: runs a program (a real process if null).
    /// <paramref name="claudePaths"/>: where <c>claude</c> may be, on macOS before asking a login shell, on
    /// Windows after PATH; the usual install places if null. <paramref name="ompPaths"/>: the same for <c>omp</c>.
    /// <paramref name="windows"/>: look for <c>claude</c> as on Windows (PATH, then the native installer's
    /// <c>claude.exe</c>; no login shell), else as the running platform. <paramref name="windowsPath"/>: Windows'
    /// PATH to look in, as a new login has it (<see cref="WindowsSystem.FreshWindowsPath"/>: an agent installed
    /// while PocketTerm runs counts); this process's PATH when not on Windows. <paramref name="claudeTimeout"/>:
    /// how long a <c>claude</c> run may take before it counts as <see cref="NoAnswer"/> (and is killed); 60 s if null.
    /// </summary>
    public Integrations(
        string? home = null,
        string? bundled = null,
        Run? run = null,
        IReadOnlyList<string>? claudePaths = null,
        IReadOnlyList<string>? ompPaths = null,
        bool? windows = null,
        Func<string>? windowsPath = null,
        TimeSpan? claudeTimeout = null)
    {
        _windows = windows ?? OperatingSystem.IsWindows();
        _windowsPath = windowsPath ?? (() => OperatingSystem.IsWindows()
            ? WindowsSystem.FreshWindowsPath()
            : Environment.GetEnvironmentVariable("PATH") ?? "");
        Home = home ?? Terminal.HomeDir(windows: windows);
        _bundled = bundled ?? AppPaths.IntegrationsDir;
        _claudeTimeout = claudeTimeout ?? TimeSpan.FromSeconds(60);
        _run = run ?? ProcessIn(Home, _claudeTimeout);
        _claudePaths = claudePaths;
        _ompPaths = ompPaths;
    }

    public string Home { get; }

    /// <summary>What Settings calls the agent: Claude's product name in full.</summary>
    public static string Name(Agent agent) => agent switch
    {
        Agent.Omp => "omp",
        _ => "Claude Code",
    };

    /// <summary>What the phone hears of <paramref name="check"/> (the state's <c>agents</c>).</summary>
    public static AgentIntegration IntegrationOf(AgentCheck check)
    {
        var s = check.State;
        if (!s.Installed || s.Problem != null) return AgentIntegration.Missing;
        if (!s.Current) return AgentIntegration.Outdated;
        return check.ModsOff ? AgentIntegration.Off : AgentIntegration.Installed;
    }

    /// <summary>Where omp loads extensions from in <paramref name="profile"/> (<c>omp --profile</c>); '' is the default profile.</summary>
    public string OmpDirOf(string profile) => profile.Length == 0
        ? Path.Combine(Home, ".omp", "agent", "extensions")
        : Path.Combine(Home, ".omp", "profiles", profile, "agent", "extensions");

    /// <summary>The omp profiles on this computer besides the default (the folders under <c>~/.omp/profiles</c>
    /// named as omp names them), sorted.</summary>
    public IReadOnlyList<string> OmpProfiles()
    {
        try
        {
            var names = Directory.GetDirectories(Path.Combine(Home, ".omp", "profiles"))
                .Select(d => Path.GetFileName(d))
                .Where(Agents.IsOmpProfile)
                .ToList();
            names.Sort(StringComparer.Ordinal);
            return names;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    /// <summary>Where omp loads extensions from: the default profile's folder, then each of <see cref="OmpProfiles"/>'.</summary>
    public IReadOnlyList<string> OmpDirs => [OmpDirOf(""), .. OmpProfiles().Select(OmpDirOf)];

    /// <summary>The marketplace Claude Code is pointed at: a stable copy of the bundled one, which it loads the
    /// plugin from in place.</summary>
    public string ClaudeDir => Path.Combine(Home, ".config", "pocketterm", "claude-plugin");

    public async Task<IntegrationState> StateAsync(Agent agent)
    {
        if (agent == Agent.Omp)
        {
            // Installed only where every profile has it, so a profile made since asks for Install again.
            var files = Bundled("omp");
            var dirs = OmpDirs;
            var installed = dirs.All(d => files.Keys.All(f => File.Exists(Under(d, f))));
            var current = installed;
            foreach (var d in dirs)
            {
                if (!current) break;
                current = Same(files, d);
            }
            return new(installed, current, null);
        }
        var claude = await ClaudeAsync().ConfigureAwait(false);
        if (claude.Problem != null) return new(false, false, claude.Problem);
        JsonObject? entry;
        try
        {
            entry = await ListedAsync(claude.Path!).ConfigureAwait(false);
        }
        catch (IntegrationException e) when (e.Message == NoAnswer)
        {
            return new(false, false, NoAnswer);
        }
        var on = LoadsOurs(entry) && DartJson.AsBool(entry!["enabled"]) != false;
        return new(on, on && Same(Bundled("claude"), ClaudeDir, exact: true), null);
    }

    /// <summary><paramref name="agent"/> is on this computer: omp's folder (<c>~/.omp</c>, made the first time it
    /// runs) or its executable; Claude Code's executable, even one too old for PocketTerm (<see cref="StateAsync"/>
    /// says so).</summary>
    public async Task<bool> FoundAsync(Agent agent)
    {
        if (agent == Agent.Omp)
        {
            return Directory.Exists(Path.Combine(Home, ".omp")) ||
                   await FindAsync("omp", _ompPaths ?? (_windows ? [Path.Combine(Home, ".bun", "bin", "omp.exe")] : UsualPlaces(Home, "omp")))
                       .ConfigureAwait(false) != null;
        }
        return (await ClaudeAsync().ConfigureAwait(false)).Path != null;
    }

    /// <summary>Installs <paramref name="agent"/>'s integration, or updates it to the bundled copy. Its running
    /// sessions load it when they restart (omp) or reload their plugins (Claude Code). Throws
    /// <see cref="IntegrationException"/> saying why it couldn't.</summary>
    public async Task InstallAsync(Agent agent)
    {
        if (agent == Agent.Omp)
        {
            var files = Bundled("omp");
            foreach (var d in OmpDirs)
            {
                Directory.CreateDirectory(d);
                Write(files, d);
            }
            return;
        }
        var claude = await ClaudeAsync().ConfigureAwait(false);
        if (claude.Problem != null) throw new IntegrationException(claude.Problem);
        var exe = claude.Path!;
        var entry = await ListedAsync(exe).ConfigureAwait(false);
        var bundled = Bundled("claude");
        if (Directory.Exists(ClaudeDir)) Directory.Delete(ClaudeDir, recursive: true);
        Write(bundled, ClaudeDir);
        await ClaudeRunAsync(exe, LoadsOurs(entry)
            ? ["plugin", "marketplace", "update", "pocketterm", "--json"]
            : ["plugin", "marketplace", "add", ClaudeDir, "--json"]).ConfigureAwait(false);
        if (entry == null)
        {
            await ClaudeRunAsync(exe, ["plugin", "install", Plugin, "--json"]).ConfigureAwait(false);
        }
        else
        {
            await ClaudeRunAsync(exe, ["plugin", "update", Plugin, "--json"]).ConfigureAwait(false);
            if (DartJson.AsBool(entry["enabled"]) == false)
            {
                await ClaudeRunAsync(exe, ["plugin", "enable", Plugin, "--json"]).ConfigureAwait(false);
            }
        }
    }

    /// <summary>Claude Code has mods (hooks/*.ts, the plugin's whole runtime) turned off. Its rollout switch is
    /// cached as off until Claude Code, logged in, refreshes it; <c>claude plugin test</c> checks that switch
    /// before anything else and says so. False when claude can't be run at all (<see cref="StateAsync"/> says why).</summary>
    public async Task<bool> ClaudeModsOffAsync()
    {
        var claude = await ClaudeAsync().ConfigureAwait(false);
        if (claude.Problem != null) return false;
        // An empty directory: with mods on there is nothing to run or write.
        var empty = Directory.CreateTempSubdirectory("pocketterm-mods");
        try
        {
            var r = await ClaudeCallAsync(claude.Path!, ["plugin", "test", empty.FullName]).ConfigureAwait(false);
            return r.ExitCode != 0 && (r.Stderr + r.Stdout).Contains("modules are turned off", StringComparison.Ordinal);
        }
        catch (IntegrationException)
        {
            // No answer: StateAsync says so.
            return false;
        }
        finally
        {
            try
            {
                empty.Delete(recursive: true);
            }
            catch (IOException)
            {
                // Gone already, or held by a claude still running: the temp folder's to clear.
            }
        }
    }

    // ------------------------------------------------------------ bundled files

    /// <summary>The bundled files of <paramref name="agentDir"/> (<c>omp</c>, <c>claude</c>), by their path below
    /// it with <c>/</c>.</summary>
    private SortedDictionary<string, byte[]> Bundled(string agentDir)
    {
        var files = new SortedDictionary<string, byte[]>(StringComparer.Ordinal);
        foreach (var dir in BundledDirs.Where(d => d == agentDir || d.StartsWith(agentDir + "/", StringComparison.Ordinal)))
        {
            var folder = Under(_bundled, dir);
            if (!Directory.Exists(folder)) throw new IntegrationException($"PocketTerm's copy of the integration is missing: {folder}");
            var below = dir == agentDir ? "" : dir[(agentDir.Length + 1)..] + "/";
            foreach (var file in Directory.GetFiles(folder))
            {
                files[below + Path.GetFileName(file)] = File.ReadAllBytes(file);
            }
        }
        return files;
    }

    /// <summary><paramref name="f"/>, a bundled path with <c>/</c>, under <paramref name="dir"/>.</summary>
    private static string Under(string dir, string f) => Path.Combine([dir, .. f.Split('/')]);

    /// <summary><paramref name="files"/> are in <paramref name="dir"/> as they are here (<paramref name="exact"/>: and
    /// nothing else is).</summary>
    private static bool Same(IReadOnlyDictionary<string, byte[]> files, string dir, bool exact = false)
    {
        foreach (var (f, bytes) in files)
        {
            var file = Under(dir, f);
            if (!File.Exists(file) || !File.ReadAllBytes(file).AsSpan().SequenceEqual(bytes)) return false;
        }
        if (!exact) return true;
        if (!Directory.Exists(dir)) return files.Count == 0;
        return Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories).Count() == files.Count;
    }

    /// <summary>Writes <paramref name="files"/> into <paramref name="dir"/> through a rename, so a symlinked one is
    /// replaced rather than written through and nothing reads half a file.</summary>
    private static void Write(IReadOnlyDictionary<string, byte[]> files, string dir)
    {
        foreach (var (f, bytes) in files)
        {
            var file = Under(dir, f);
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            var tmp = file + ".pocketterm-tmp";
            using (var s = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                s.Write(bytes);
                s.Flush(flushToDisk: true);
            }
            File.Move(tmp, file, overwrite: true);
        }
    }

    // ------------------------------------------------------------ finding and running the agents

    /// <summary>Where <paramref name="name"/> goes on macOS when installed by hand, by Homebrew, bun, npm (a global
    /// prefix, nvm with the newest Node first, Volta): a GUI app started from Finder or the Dock has none of these
    /// on its PATH, and a login shell has only what the profile files add, not ~/.zshrc (where bun's and nvm's
    /// installers put theirs).</summary>
    internal static List<string> UsualPlaces(string home, string name)
    {
        var nvm = Path.Combine(home, ".nvm", "versions", "node");
        var nodes = Directory.Exists(nvm) ? Directory.GetDirectories(nvm).ToList() : [];
        nodes.Sort((a, b) =>
        {
            var (x, y) = (Version(a), Version(b));
            for (var i = 0; i < x.Count && i < y.Count; i++)
            {
                if (x[i] != y[i]) return y[i].CompareTo(x[i]);
            }
            return y.Count.CompareTo(x.Count);
        });
        var places = new List<string> { Path.Combine(home, ".local", "bin", name) };
        if (name == "claude") places.Add(Path.Combine(home, ".claude", "local", "claude"));
        places.Add(Path.Combine(home, ".bun", "bin", name));
        places.Add(Path.Combine(home, ".npm-global", "bin", name));
        places.AddRange(nodes.Select(n => Path.Combine(n, "bin", name)));
        places.Add(Path.Combine(home, ".volta", "bin", name));
        places.Add($"/opt/homebrew/bin/{name}");
        places.Add($"/usr/local/bin/{name}");
        return places;

        static List<long> Version(string dir) =>
            Digits().Matches(Path.GetFileName(dir)).Select(m => long.TryParse(m.Value, out var n) ? n : long.MaxValue).ToList();
    }

    /// <summary><paramref name="name"/>'s executable: on macOS in <paramref name="candidates"/> before asking a login
    /// shell (a GUI app has no login shell's PATH); on Windows PATH, then <paramref name="candidates"/>. The shell's
    /// answer is its last line that is a path (a profile may print something first); a shell that doesn't answer
    /// within 10 s counts as not finding it.</summary>
    private async Task<string?> FindAsync(string name, IReadOnlyList<string> candidates)
    {
        if (_windows)
        {
            return Terminal.FindExecutable(name, candidates, new Dictionary<string, string> { ["PATH"] = _windowsPath() }, windows: true);
        }
        if (candidates.FirstOrDefault(File.Exists) is { } path) return path;
        RunResult r;
        try
        {
            r = await _run("/bin/zsh", ["-lc", $"command -v {name}"]).WaitAsync(TimeSpan.FromSeconds(10)).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            return null;
        }
        if (r.ExitCode != 0) return null;
        return r.Stdout.Split('\n').Select(l => l.DartTrim()).LastOrDefault(l => l.StartsWith('/'));
    }

    /// <summary>The <c>claude</c> executable and whether it's new enough: on macOS the usual install places first,
    /// then the shell; on Windows PATH, then the native installer's place.</summary>
    private async Task<(string? Path, string? Problem)> ClaudeAsync()
    {
        var path = await FindAsync(
            "claude",
            _claudePaths ?? (_windows ? [Path.Combine(Home, ".local", "bin", "claude.exe")] : UsualPlaces(Home, "claude"))).ConfigureAwait(false);
        if (path == null) return (null, "Claude Code isn't installed");
        RunResult r;
        try
        {
            r = await ClaudeCallAsync(path, ["--version"]).ConfigureAwait(false);
        }
        catch (IntegrationException e)
        {
            return (path, e.Message);
        }
        var version = ClaudeVersion().Match(r.Stdout);
        if (!version.Success) return (path, $"Couldn't run Claude Code: {MessageOf(r)}");
        var v = Enumerable.Range(1, 3).Select(i => long.TryParse(version.Groups[i].Value, out var n) ? n : long.MaxValue).ToArray();
        var tooOld = v[0] != MinClaude[0] ? v[0] < MinClaude[0] : v[1] != MinClaude[1] ? v[1] < MinClaude[1] : v[2] < MinClaude[2];
        if (tooOld)
        {
            return (path, $"Claude Code {version.Value} is too old: update it to {string.Join('.', MinClaude)} or later");
        }
        return (path, null);
    }

    /// <summary>Claude Code's record of PocketTerm's plugin, if it has one.</summary>
    private async Task<JsonObject?> ListedAsync(string claude)
    {
        var r = await ClaudeRunAsync(claude, ["plugin", "list", "--json"]).ConfigureAwait(false);
        if (DartJson.TryDecode(r.Stdout) is not JsonArray list) throw new FormatException($"Not a list: {r.Stdout}");
        return list.OfType<JsonObject>().FirstOrDefault(p => p.Str("id") == Plugin);
    }

    /// <summary><paramref name="entry"/> loads from <see cref="ClaudeDir"/> (not from a marketplace elsewhere that is
    /// also called pocketterm, such as a checkout of this repo).</summary>
    private bool LoadsOurs(JsonObject? entry) =>
        entry?.Str("readFromFolder") is { } folder && SamePath(folder, Path.Combine(ClaudeDir, "plugins", "pocketterm"));

    /// <summary>The path package's <c>p.equals</c>: the same place, ignoring case on Windows.</summary>
    private static bool SamePath(string a, string b)
    {
        static string Norm(string p) => Path.TrimEndingDirectorySeparator(Path.GetFullPath(p));
        return string.Equals(Norm(a), Norm(b), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
    }

    private async Task<RunResult> ClaudeRunAsync(string claude, IReadOnlyList<string> args)
    {
        var r = await ClaudeCallAsync(claude, args).ConfigureAwait(false);
        if (r.ExitCode != 0) throw new IntegrationException(MessageOf(r));
        return r;
    }

    /// <summary><paramref name="claude"/> run with <paramref name="args"/>; <see cref="NoAnswer"/> once it outlasts the timeout.</summary>
    private async Task<RunResult> ClaudeCallAsync(string claude, IReadOnlyList<string> args)
    {
        try
        {
            return await _run(claude, args).WaitAsync(_claudeTimeout).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            throw new IntegrationException(NoAnswer);
        }
    }

    /// <summary>What a failed run said: the <c>message</c> of its <c>--json</c> line, else stderr.</summary>
    private static string MessageOf(RunResult r)
    {
        var last = r.Stdout.DartTrim().Split('\n')[^1];
        if (DartJson.TryDecodeObject(last)?.Str("message") is { } m) return m;
        var err = r.Stderr.DartTrim();
        return err.Length > 0 ? err : $"exit code {r.ExitCode}";
    }

    // ------------------------------------------------------------ the real runner

    /// <summary>A process, output read as UTF-8 (what claude writes; the default is the ANSI code page on
    /// Windows), an npm <c>claude.cmd</c> through cmd.exe; on a Mac with <see cref="AgentPath"/> as PATH. A run
    /// still going after <paramref name="limit"/> is killed and throws <see cref="TimeoutException"/>.</summary>
    private static Run ProcessIn(string home, TimeSpan limit) => (executable, arguments) =>
    {
        if (OperatingSystem.IsWindows())
        {
            var (exe, args) = Terminal.WindowsCommand(executable, arguments);
            return Bounded(exe, args, null, limit);
        }
        return Bounded(executable, arguments, new Dictionary<string, string>
        {
            ["PATH"] = AgentPath(executable, home, Environment.GetEnvironmentVariable("PATH") ?? ""),
        }, limit);
    };

    /// <summary>A process with UTF-8 output, killed once it runs longer than <paramref name="limit"/>.</summary>
    private static async Task<RunResult> Bounded(string exe, IReadOnlyList<string> args, IReadOnlyDictionary<string, string>? env, TimeSpan limit)
    {
        var info = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
        };
        foreach (var a in args) info.ArgumentList.Add(a);
        if (env != null)
        {
            foreach (var (k, v) in env) info.Environment[k] = v;
        }
        using var process = Process.Start(info) ?? throw new IOException($"{exe} didn't start");
        // Nothing to say to it: an end of input rather than a pipe left open.
        process.StandardInput.Close();
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        using var deadline = new CancellationTokenSource(limit);
        try
        {
            await process.WaitForExitAsync(deadline.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
                // Ended just now.
            }
            throw new TimeoutException($"{exe} ran longer than {limit}");
        }
        return new RunResult(process.ExitCode, await output.ConfigureAwait(false), await error.ConfigureAwait(false));
    }

    /// <summary>The PATH <paramref name="executable"/> runs with: its folder and the one it links into, where Node
    /// goes (<see cref="UsualPlaces"/>), then <paramref name="current"/>. Claude Code installed with npm is a
    /// <c>#!/usr/bin/env node</c> script, and an app started from Finder or the Dock has only
    /// <c>/usr/bin:/bin:/usr/sbin:/sbin</c>, no node.</summary>
    internal static string AgentPath(string executable, string home, string current)
    {
        string? linked = null;
        try
        {
            var file = new FileInfo(executable);
            if (file.Exists) linked = file.ResolveLinkTarget(returnFinalTarget: true)?.FullName ?? file.FullName;
        }
        catch (IOException)
        {
            linked = null;
        }
        var dirs = new List<string> { Path.GetDirectoryName(executable) ?? "" };
        if (linked != null) dirs.Add(Path.GetDirectoryName(linked) ?? "");
        dirs.AddRange(UsualPlaces(home, "node").Select(n => Path.GetDirectoryName(n) ?? ""));
        dirs.AddRange(current.Split(':').Where(d => d.Length > 0));
        return string.Join(':', dirs.Distinct(StringComparer.Ordinal));
    }

    [GeneratedRegex("[0-9]+")]
    private static partial Regex Digits();

    [GeneratedRegex("([0-9]+)\\.([0-9]+)\\.([0-9]+)")]
    private static partial Regex ClaudeVersion();
}
