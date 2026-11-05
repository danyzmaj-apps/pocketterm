using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace PocketTerm.Core;

/// <summary>terminal.dart's pure helpers: keys, text, titles, screens, where an agent runs, and
/// the Windows/POSIX command helpers.</summary>
public static partial class Terminal
{
    // ------------------------------------------------------------ keys

    /// <summary>
    /// What a key sends to the program in the terminal, for hosts that write bytes. kitty's names:
    /// <c>enter</c>, <c>esc</c>, <c>tab</c>, <c>shift+tab</c>, <c>space</c>, <c>backspace</c>, arrows,
    /// <c>ctrl+&lt;letter&gt;</c>, a single character. Shift+Enter goes as Alt+Enter (ESC CR), which
    /// omp's and Claude Code's editors read as a new line where the terminal can't send Shift+Enter itself.
    /// </summary>
    public static string KeyBytes(string name)
    {
        string? named = name switch
        {
            "enter" or "return" => "\r",
            "esc" or "escape" => "\x1b",
            "tab" => "\t",
            "shift+tab" => "\x1b[Z",
            "space" => " ",
            "backspace" => "\x7f",
            "delete" => "\x1b[3~",
            "up" => "\x1b[A",
            "down" => "\x1b[B",
            "right" => "\x1b[C",
            "left" => "\x1b[D",
            "home" => "\x1b[H",
            "end" => "\x1b[F",
            "page_up" or "pageup" => "\x1b[5~",
            "page_down" or "pagedown" => "\x1b[6~",
            "shift+enter" or "alt+enter" => "\x1b\r",
            _ => null,
        };
        if (named != null) return named;
        var ctrl = CtrlKey().Match(name);
        if (ctrl.Success) return ((char)(ctrl.Groups[1].Value[0] - 0x60)).ToString();
        if (RuneCount(name) == 1) return name;
        throw new TerminalException($"Unknown key: {name}");
    }

    /// <summary><paramref name="names"/> as the byte runs to write: one run, except that Esc goes on its
    /// own (followed by more bytes it would read as Alt+key).</summary>
    public static List<string> KeyRuns(IEnumerable<string> names)
    {
        var runs = new List<string>();
        var current = new StringBuilder();
        foreach (var n in names)
        {
            var b = KeyBytes(n);
            if (b == "\x1b")
            {
                if (current.Length > 0) runs.Add(current.ToString());
                runs.Add(b);
                current.Clear();
            }
            else
            {
                current.Append(b);
            }
        }
        if (current.Length > 0) runs.Add(current.ToString());
        return runs;
    }

    /// <summary>Keys the phone may press itself (the screen page's key row), in Dart's set order.</summary>
    public static readonly IReadOnlyList<string> PhoneKeys = ["esc", "tab", "up", "down", "enter", "ctrl+c"];

    /// <summary>
    /// <paramref name="text"/> in pieces of at most <paramref name="maxBytes"/> UTF-8 bytes each, in
    /// order, cut between characters only: a terminal's scripting takes a bounded amount in one
    /// command (tmux refuses one over 16 KB, kitty a message over about 128 KB; a command line is at
    /// most 1 MB on a Mac, 32K characters on Windows).
    /// </summary>
    public static List<string> TextChunks(string text, int maxBytes)
    {
        var output = new List<string>();
        var start = 0;
        var bytes = 0;
        var i = 0;
        while (i < text.Length)
        {
            int c = text[i];
            var pair = (c & 0xFC00) == 0xD800 && i + 1 < text.Length && (text[i + 1] & 0xFC00) == 0xDC00;
            var n = pair ? 4 : c < 0x80 ? 1 : c < 0x800 ? 2 : 3;
            if (bytes + n > maxBytes && i > start)
            {
                output.Add(text[start..i]);
                start = i;
                bytes = 0;
            }
            bytes += n;
            i += pair ? 2 : 1;
        }
        if (start < text.Length) output.Add(text[start..]);
        return output;
    }

    /// <summary>The most characters of a window's or tab's title the phone gets.</summary>
    public const int TitleRunes = 200;

    /// <summary>
    /// A window's or tab's <paramref name="title"/> as the phone shows it: escape sequences and control
    /// characters dropped (kitty and WezTerm let some through), a tab or line break as a space, bidi
    /// overrides dropped (they would turn the text after the title around), and at most
    /// <see cref="TitleRunes"/> characters (a program may set a title of any length).
    /// </summary>
    public static string CleanTitle(string title)
    {
        var t = TitleEscape().Replace(title, "");
        t = TitleBreak().Replace(t, " ");
        t = TitleControl().Replace(t, "");
        if (RuneCount(t) <= TitleRunes) return t;
        return t[..RuneEnd(t, TitleRunes - 1)] + "\u2026";
    }

    /// <summary>Dart's <c>s.runes.length</c>: code points, a lone surrogate counting as one.</summary>
    internal static int RuneCount(string s)
    {
        var n = 0;
        for (var i = 0; i < s.Length; i += IsPairAt(s, i) ? 2 : 1) n++;
        return n;
    }

    /// <summary>The index after the first <paramref name="runes"/> code points of <paramref name="s"/>.</summary>
    private static int RuneEnd(string s, int runes)
    {
        var i = 0;
        for (var n = 0; n < runes && i < s.Length; n++) i += IsPairAt(s, i) ? 2 : 1;
        return i;
    }

    private static bool IsPairAt(string s, int i) =>
        char.IsHighSurrogate(s[i]) && i + 1 < s.Length && char.IsLowSurrogate(s[i + 1]);

    // ------------------------------------------------------------ screens

    /// <summary>A sealed message grows by a third and the server closes a socket on a frame over 256 KB,
    /// so scrollback keeps only its newest lines up to this many UTF-8 bytes.</summary>
    public const int HistoryBytes = 60000;

    /// <summary>
    /// A terminal's <paramref name="text"/> as the phone's lines: charset choices (ESC ( B, which WezTerm
    /// puts before its SGR resets) dropped, plain spaces among a line's closing escapes dropped
    /// (padding), trailing blank lines dropped, and only the newest lines within <see cref="HistoryBytes"/>;
    /// a newest line longer than that (kitty joins a wrapped line's rows) as its end.
    /// </summary>
    public static List<string> ScreenLines(string text)
    {
        var raw = Charset().Replace(text.Replace("\r\n", "\n"), "").Split('\n');
        var kept = new List<string>();
        var bytes = 0;
        for (var i = raw.Length - 1; i >= 0; i--)
        {
            var line = Pad().Replace(raw[i], m => string.Concat(Sgr().Matches(m.Value).Select(e => e.Value)), 1);
            if (kept.Count == 0 && Sgr().Replace(line, "").Length == 0) continue;
            bytes += Encoding.UTF8.GetByteCount(line) + 1;
            if (bytes > HistoryBytes)
            {
                if (kept.Count == 0) kept.Add(Tail(line, HistoryBytes - 1));
                break;
            }
            kept.Add(line);
        }
        kept.Reverse();
        return kept;
    }

    /// <summary>The end of <paramref name="line"/> within <paramref name="maxBytes"/> UTF-8 bytes, cut
    /// between characters and not inside an escape sequence.</summary>
    private static string Tail(string line, int maxBytes)
    {
        var at = line.Length;
        var bytes = 0;
        while (at > 0)
        {
            int c = line[at - 1];
            var pair = (c & 0xFC00) == 0xDC00 && at > 1 && (line[at - 2] & 0xFC00) == 0xD800;
            var n = pair ? 4 : c < 0x80 ? 1 : c < 0x800 ? 2 : 3;
            if (bytes + n > maxBytes) break;
            bytes += n;
            at -= pair ? 2 : 1;
        }
        foreach (Match m in TailEscape().Matches(line))
        {
            var end = m.Index + m.Length;
            if (end <= at) continue;
            if (m.Index < at) at = end;
            break;
        }
        return line[at..];
    }

    // ------------------------------------------------------------ where an agent runs

    /// <summary>
    /// The key of the window a coding agent runs in, from the <c>term</c> its extension reports (its
    /// environment, raw: TERM_PROGRAM, KITTY_*, TMUX, TMUX_PANE, WEZTERM_*, ITERM_SESSION_ID, and
    /// <c>tty</c>). tmux wins (the pane, not the terminal showing it); then the terminal TERM_PROGRAM
    /// names (other terminals' variables leak into apps started from them); then kitty's own
    /// variables. Null when it can't be told without asking a terminal (Ghostty).
    /// </summary>
    public static string? WindowOfTerm(JsonObject? term)
    {
        if (term == null) return null;
        string? V(string name) => DartJson.AsString(term[name]) is { Length: > 0 } s ? s : null;

        var tmux = V("TMUX");
        var tmuxPane = V("TMUX_PANE");
        if (tmux != null && tmuxPane != null)
        {
            var socket = tmux.Split(',')[0].Split('/')[^1];
            var n = ReplaceFirst(tmuxPane, "%", "");
            if (TmuxSocket().IsMatch(socket) && Digits().IsMatch(n)) return $"tmux:{socket}/{n}";
        }

        string? Kitty()
        {
            var window = V("KITTY_WINDOW_ID");
            if (window == null) return null;
            var listen = V("KITTY_LISTEN_ON");
            var socket = listen != null
                ? (listen.StartsWith("unix:", StringComparison.Ordinal) ? listen[5..] : listen).Split('/')[^1]
                : V("KITTY_PID") != null ? $"kitty-{V("KITTY_PID")}" : null;
            return socket != null && KittySocket().IsMatch(socket) ? $"{socket}/{window}" : null;
        }

        string? WezTerm()
        {
            var pane = V("WEZTERM_PANE");
            var m = WezSocket().Match(V("WEZTERM_UNIX_SOCKET") ?? "");
            return pane != null && m.Success ? $"wezterm:{m.Groups[1].Value}/{pane}" : null;
        }

        string? ITerm()
        {
            var m = ITermSession().Match(V("ITERM_SESSION_ID") ?? "");
            return m.Success ? $"iterm:{m.Groups[1].Value}" : null;
        }

        return V("TERM_PROGRAM") switch
        {
            "WezTerm" => WezTerm(),
            "iTerm.app" => ITerm(),
            "ghostty" => null,
            _ => Kitty() ?? WezTerm(),
        };
    }

    /// <summary>Valid tmux socket names in keys.</summary>
    public static bool TmuxSocketName(string name) => TmuxSocket().IsMatch(name);

    private static string ReplaceFirst(string s, string from, string to)
    {
        var i = s.IndexOf(from, StringComparison.Ordinal);
        return i < 0 ? s : string.Concat(s.AsSpan(0, i), to, s.AsSpan(i + from.Length));
    }

    // ------------------------------------------------------------ processes

    /// <summary>The program <paramref name="args"/> (ps's <c>args</c>) runs.</summary>
    public static string ProgramOf(string args)
    {
        var words = DartWhitespace().Split(args.DartTrim());
        if (words.Length == 0 || words[0].Length == 0) return "";
        static string Base(string w)
        {
            var last = w.Split('/')[^1];
            return last.StartsWith('-') ? last[1..] : last;
        }
        var first = Base(words[0]);
        if (first is "node" or "bun" or "deno" or "python" or "python3" or "ruby" or "perl")
        {
            foreach (var w in words.Skip(1))
            {
                if (w.StartsWith('-')) continue;
                return ScriptExtension().Replace(Base(w), "", 1);
            }
        }
        return first;
    }

    /// <summary>The program a window <paramref name="title"/> names, for terminals that tell no tty
    /// (WezTerm on Windows): its first word (or its path, up to <c>.exe</c>), the last part of that
    /// path, without <c>.exe</c>, lowercased.</summary>
    public static string ProgramOfTitle(string title)
    {
        var t = title.DartTrim();
        var exe = ExePrefix().Match(t);
        var word = exe.Success ? exe.Value : DartWhitespace().Split(t)[0];
        return ExeSuffix().Replace(PathSeparators().Split(word)[^1], "", 1).ToLowerInvariant();
    }

    /// <summary><c>ps -Ao pid=,ppid=,pgid=,tpgid=,tty=,stat=,args=</c> as <see cref="Proc"/>s.</summary>
    public static List<Proc> ParsePs(string output)
    {
        var procs = new List<Proc>();
        foreach (var l in SplitLines(output))
        {
            var m = PsLine().Match(l);
            if (!m.Success) continue;
            var tty = m.Groups[5].Value;
            procs.Add(new Proc(
                int.Parse(m.Groups[1].Value),
                int.Parse(m.Groups[2].Value),
                int.Parse(m.Groups[3].Value),
                int.Parse(m.Groups[4].Value),
                tty is "?" or "??" ? "" : tty,
                m.Groups[6].Value,
                m.Groups[7].Value));
        }
        return procs;
    }

    /// <summary><c>tasklist /fo csv /nh</c> (<c>"image","pid","session","session#","memory"</c> lines) as
    /// <see cref="Proc"/>s: only the pid and the image name are known.</summary>
    public static List<Proc> ParseTasklist(string csv)
    {
        var procs = new List<Proc>();
        foreach (var l in SplitLines(csv))
        {
            var fields = CsvField().Matches(l).Select(m => m.Groups[1].Value.Replace("\"\"", "\"")).ToList();
            if (fields.Count < 2) continue;
            if (DartString.TryParseInt(fields[1]) is not { } pid) continue;
            procs.Add(new Proc((int)pid, 0, 0, -1, "", "", fields[0]));
        }
        return procs;
    }

    /// <summary><c>lsof -a -d cwd -Fpn -p …</c> as pid → directory.</summary>
    public static Dictionary<int, string> ParseLsofCwd(string output)
    {
        var cwds = new Dictionary<int, string>();
        int? pid = null;
        foreach (var l in SplitLines(output))
        {
            if (l.StartsWith('p')) pid = DartString.TryParseInt(l[1..]) is { } p ? (int)p : null;
            if (l.StartsWith('n') && pid != null) cwds[pid.Value] = l[1..];
        }
        return cwds;
    }

    /// <summary>Dart's <c>LineSplitter</c>: lines ended by <c>\n</c>, <c>\r\n</c> or <c>\r</c>; no
    /// empty line after a final break.</summary>
    internal static List<string> SplitLines(string s)
    {
        var lines = new List<string>();
        var start = 0;
        for (var i = 0; i < s.Length; i++)
        {
            if (s[i] != '\n' && s[i] != '\r') continue;
            lines.Add(s[start..i]);
            if (s[i] == '\r' && i + 1 < s.Length && s[i + 1] == '\n') i++;
            start = i + 1;
        }
        if (start < s.Length) lines.Add(s[start..]);
        return lines;
    }

    /// <summary>For a program whose output PocketTerm reads (<c>ps</c>, <c>lsof</c>): UTF-8, whatever
    /// locale PocketTerm has. An app started from Finder or the Dock has none (no <c>LANG</c>), and then
    /// <c>ps</c> writes a name's other letters as <c>M-</c> escapes and <c>lsof</c> as <c>\xNN</c>.</summary>
    public static readonly IReadOnlyDictionary<string, string> Utf8Output =
        new Dictionary<string, string> { ["LC_ALL"] = "en_US.UTF-8" };

    /// <summary>What a program PocketTerm starts for the person (a tmux server, and so every shell in it)
    /// needs besides <paramref name="env"/> to read and write UTF-8: <c>LC_CTYPE=UTF-8</c> when
    /// <paramref name="env"/> (this process's when null) has no UTF-8 locale, as an app started from
    /// Finder or the Dock has none; else nothing.</summary>
    public static IReadOnlyDictionary<string, string> Utf8Locale(IReadOnlyDictionary<string, string>? env = null)
    {
        string? Get(string k) => env != null ? env.GetValueOrDefault(k) : Environment.GetEnvironmentVariable(k);
        var locale = new[] { Get("LC_ALL"), Get("LC_CTYPE"), Get("LANG") }.FirstOrDefault(v => !string.IsNullOrEmpty(v));
        return locale != null && Utf8Name().IsMatch(locale)
            ? new Dictionary<string, string>()
            : new Dictionary<string, string> { ["LC_CTYPE"] = "UTF-8" };
    }

    /// <summary>The home folder: <c>USERPROFILE</c> on Windows, else <c>HOME</c>; empty if unset.</summary>
    public static string HomeDir(IReadOnlyDictionary<string, string>? env = null, bool? windows = null)
    {
        var name = windows ?? OperatingSystem.IsWindows() ? "USERPROFILE" : "HOME";
        return (env != null ? env.GetValueOrDefault(name) : Environment.GetEnvironmentVariable(name)) ?? "";
    }

    /// <summary>
    /// An executable named <paramref name="name"/> in the usual places (a GUI app's PATH is short), or
    /// in <paramref name="extra"/>; null if none. On Windows: PATH (split on <c>;</c>, a quoted entry
    /// unquoted), <c>&lt;name&gt;.exe</c> in any folder, then <paramref name="extra"/>, then
    /// <c>&lt;name&gt;.cmd</c> and <c>&lt;name&gt;.bat</c> (npm's shims; run them through
    /// <see cref="WindowsCommand"/>). Never the bare <c>&lt;name&gt;</c>, which on Windows is a script
    /// CreateProcess can't run.
    /// </summary>
    public static string? FindExecutable(
        string name, IReadOnlyList<string>? extra = null, IReadOnlyDictionary<string, string>? env = null, bool? windows = null)
    {
        extra ??= [];
        var path = (env != null ? env.GetValueOrDefault("PATH") : Environment.GetEnvironmentVariable("PATH")) ?? "";
        var win = windows ?? OperatingSystem.IsWindows();
        var candidates = new List<string>();
        if (win)
        {
            var dirs = WindowsPathDirs(path);
            candidates.AddRange(dirs.Select(dir => Path.Combine(dir, $"{name}.exe")));
            candidates.AddRange(extra);
            foreach (var dir in dirs)
            {
                candidates.Add(Path.Combine(dir, $"{name}.cmd"));
                candidates.Add(Path.Combine(dir, $"{name}.bat"));
            }
        }
        else
        {
            var dirs = path.Split(':').Where(d => d.Length > 0)
                .Concat(["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]);
            candidates.AddRange(dirs.Select(dir => $"{dir}/{name}"));
            candidates.AddRange(extra);
        }
        return candidates.FirstOrDefault(File.Exists);
    }

    /// <summary>Whether Windows takes <paramref name="name"/> (no folder parts) as a file or folder name:
    /// none of <c>&lt; &gt; " | ? *</c>, no dot or space at the end (Windows drops it, so the folder made
    /// isn't the one named), and not a device name (CON, PRN, AUX, NUL, COM1–9, LPT1–9), with or
    /// without an extension.</summary>
    public static bool WindowsFileName(string name) =>
        name.IndexOfAny(['<', '>', '"', '|', '?', '*']) < 0 &&
        !name.EndsWith('.') &&
        !name.EndsWith(' ') &&
        !DeviceName().IsMatch(name);

    /// <summary>A Windows PATH's folders: split on <c>;</c>, each without the quotes an installer may
    /// have put around it, empty ones dropped.</summary>
    public static List<string> WindowsPathDirs(string path) =>
        path.Split(';').Select(d => d.DartTrim().Replace("\"", "")).Where(d => d.Length > 0).ToList();

    /// <summary>A Windows PATH as a new login would have it: the system's folders
    /// (<paramref name="machine"/>), then the user's (<paramref name="user"/>), then those only this
    /// process has (<paramref name="current"/>: what PocketTerm started with), each folder once (Windows
    /// compares them ignoring case). An app that installs itself and adds its folder while PocketTerm
    /// runs is then found, and terminals PocketTerm starts find it too.</summary>
    public static string MergeWindowsPath(string current, string? machine = null, string? user = null)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var dirs = WindowsPathDirs(machine ?? "").Concat(WindowsPathDirs(user ?? "")).Concat(WindowsPathDirs(current));
        return string.Join(';', dirs.Where(dir => seen.Add(TrailingBackslashes().Replace(dir.ToLowerInvariant(), "", 1))));
    }

    /// <summary>The program and arguments that run <paramref name="executable"/> with
    /// <paramref name="arguments"/> on Windows. A batch file (<c>.cmd</c>, <c>.bat</c>: npm's
    /// <c>claude.cmd</c>) runs only through <c>cmd.exe</c>; <c>call</c> keeps cmd from stripping the
    /// quotes around a path with a space when an argument is quoted too. <c>/d</c>: without the
    /// person's cmd AutoRun.</summary>
    public static (string Program, IReadOnlyList<string> Arguments) WindowsCommand(string executable, IReadOnlyList<string> arguments) =>
        BatchFile().IsMatch(executable)
            ? ("cmd.exe", ["/d", "/c", "call", executable, .. arguments])
            : (executable, arguments);

    /// <summary>A shell word for <paramref name="s"/>.</summary>
    public static string ShellQuote(string s) => $"'{s.Replace("'", "'\\''")}'";

    // ------------------------------------------------------------ patterns (Dart's, made .NET-exact)

    [GeneratedRegex(@"^ctrl\+([a-z])\z")]
    private static partial Regex CtrlKey();

    [GeneratedRegex(@"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b[ -/]*[0-~]?")]
    private static partial Regex TitleEscape();

    [GeneratedRegex(@"[\t\n\r]+")]
    private static partial Regex TitleBreak();

    [GeneratedRegex("[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]")]
    private static partial Regex TitleControl();

    [GeneratedRegex(@"\x1b[ -/]+[0-~]")]
    private static partial Regex Charset();

    [GeneratedRegex(@"(?: |\x1b\[[0-9;:]*m)+\z")]
    private static partial Regex Pad();

    [GeneratedRegex(@"\x1b\[[0-9;:]*m")]
    private static partial Regex Sgr();

    [GeneratedRegex(@"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")]
    private static partial Regex TailEscape();

    [GeneratedRegex(@"^[A-Za-z0-9_.-]{1,40}\z")]
    private static partial Regex TmuxSocket();

    [GeneratedRegex(@"^[0-9]+\z")]
    private static partial Regex Digits();

    [GeneratedRegex(@"^kitty[A-Za-z0-9_.-]*\z")]
    private static partial Regex KittySocket();

    [GeneratedRegex(@"gui-sock-([0-9]+)\z")]
    private static partial Regex WezSocket();

    [GeneratedRegex(@"^w[0-9]+t[0-9]+p[0-9]+:([0-9A-Fa-f-]{36})\z")]
    private static partial Regex ITermSession();

    // Dart's (JavaScript's) \s: no U+0085, but U+FEFF.
    [GeneratedRegex("[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+")]
    private static partial Regex DartWhitespace();

    [GeneratedRegex(@"\.(m?js|ts|py|rb|pl)\z")]
    private static partial Regex ScriptExtension();

    [GeneratedRegex(@"^[^\r\n\u2028\u2029]*?\.exe(?![A-Za-z0-9_])", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex ExePrefix();

    [GeneratedRegex(@"\.exe\z", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex ExeSuffix();

    [GeneratedRegex(@"[\\/]")]
    private static partial Regex PathSeparators();

    // Dart's ^\s*(\d+)\s+(\d+)\s+(\d+)\s+(-?\d+)\s+(\S+)\s+(\S+)\s+(.*)$ with its \s spelt out.
    [GeneratedRegex("^[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]*([0-9]+)[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+([0-9]+)[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+([0-9]+)[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+(-?[0-9]+)[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+([^\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+)[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+([^\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+)[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+([^\r\n\u2028\u2029]*)\\z")]
    private static partial Regex PsLine();

    [GeneratedRegex("\"((?:[^\"]|\"\")*)\"")]
    private static partial Regex CsvField();

    [GeneratedRegex("utf-?8", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex Utf8Name();

    [GeneratedRegex(@"^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(\.[^\r\n\u2028\u2029]*)?\z", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex DeviceName();

    [GeneratedRegex(@"\\+\z")]
    private static partial Regex TrailingBackslashes();

    [GeneratedRegex(@"\.(cmd|bat)\z", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex BatchFile();
}
