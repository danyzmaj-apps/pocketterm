namespace PocketTerm.Desktop;

/// <summary>
/// Folder comparisons as Dart's <c>path</c> package made them on each platform: on Windows either
/// separator and any case (WezTerm's folders there are <c>C:\…</c>), elsewhere <c>/</c> and exact case;
/// <c>.</c>, <c>..</c>, doubled and trailing separators don't count. Plus the real path of a folder
/// (Dart's <c>resolveSymbolicLinks</c>).
/// </summary>
internal static class PathRules
{
    /// <summary>Dart's <c>p.equals</c>.</summary>
    public static bool Same(string a, string b, bool windows) =>
        string.Equals(Normalize(a, windows), Normalize(b, windows), windows ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    /// <summary>Dart's <c>p.isWithin</c>: <paramref name="child"/> somewhere under <paramref name="parent"/>
    /// (never itself).</summary>
    public static bool IsWithin(string parent, string child, bool windows)
    {
        var p = Normalize(parent, windows);
        var c = Normalize(child, windows);
        var sep = windows ? '\\' : '/';
        var prefix = p.EndsWith(sep) ? p : p + sep;
        var cmp = windows ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        return c.Length > prefix.Length && c.StartsWith(prefix, cmp);
    }

    /// <summary>Dart's <c>p.basename</c>: the last part, trailing separators aside.</summary>
    public static string Basename(string path, bool windows)
    {
        var trimmed = path.TrimEnd(Separators(windows));
        if (trimmed.Length == 0) return path;
        var i = trimmed.LastIndexOfAny(Separators(windows));
        return i < 0 ? trimmed : trimmed[(i + 1)..];
    }

    private static char[] Separators(bool windows) => windows ? ['\\', '/'] : ['/'];

    /// <summary><paramref name="path"/> with one separator between parts, <c>.</c> and <c>..</c> resolved,
    /// no trailing separator but a root's (<c>/</c>, <c>C:\</c>, <c>\\server\share</c>).</summary>
    public static string Normalize(string path, bool windows)
    {
        if (path.Length == 0) return path;
        var sep = windows ? '\\' : '/';
        var s = windows ? path.Replace('/', '\\') : path;
        string root;
        if (windows && s.StartsWith(@"\\", StringComparison.Ordinal)) root = @"\\";
        else if (windows && s.Length >= 2 && char.IsAsciiLetter(s[0]) && s[1] == ':') root = s.Length > 2 && s[2] == '\\' ? s[..3] : s[..2];
        else if (s[0] == sep) root = sep.ToString();
        else root = "";
        var parts = new List<string>();
        foreach (var part in s[root.Length..].Split(sep, StringSplitOptions.RemoveEmptyEntries))
        {
            if (part == ".") continue;
            if (part == ".." && parts.Count > 0 && parts[^1] != "..") parts.RemoveAt(parts.Count - 1);
            else if (part == ".." && root.Length > 0) continue;
            else parts.Add(part);
        }
        var joined = root + string.Join(sep, parts);
        return joined.Length == 0 ? "." : joined;
    }

    /// <summary>
    /// The folder <paramref name="path"/> really is: absolute, every link on the way followed (Dart's
    /// <c>resolveSymbolicLinks</c>). Throws <see cref="IOException"/> when it doesn't exist or links
    /// loop.
    /// </summary>
    public static string RealPath(string path) => RealPath(path, 0);

    private static string RealPath(string path, int hops)
    {
        var full = Path.GetFullPath(path);
        var root = Path.GetPathRoot(full) ?? "";
        var current = root;
        foreach (var part in full[root.Length..].Split(
                     [Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries))
        {
            var next = Path.Combine(current, part);
            if (!File.Exists(next) && !Directory.Exists(next)) throw new DirectoryNotFoundException($"No such folder: {next}");
            var target = new FileInfo(next).LinkTarget;
            if (target != null)
            {
                if (hops > 40) throw new IOException($"Too many links: {path}");
                next = RealPath(Path.IsPathRooted(target) ? target : Path.Combine(current, target), hops + 1);
            }
            current = next;
        }
        return current;
    }
}
