namespace PocketTerm.Desktop;

/// <summary>
/// The project folders the setup checklist suggests (the Project folders setting, where
/// <see cref="Terminals.ProjectsAsync"/> looks for repositories): the usual names in the home folder,
/// and on Windows Visual Studio's and GitHub Desktop's folders.
/// </summary>
public static class ProjectFolders
{
    /// <summary>The names a folder of projects in the home folder usually has.</summary>
    public static readonly IReadOnlyList<string> Usual =
        ["Dev", "Developer", "Projects", "projects", "code", "Code", "src", "repos", "dev", "git"];

    /// <summary>Windows' usual project folders that exist here: Visual Studio's and GitHub Desktop's below
    /// <paramref name="home"/>, and GitHub Desktop's below OneDrive's folders (<paramref name="env"/>'s
    /// OneDrive, OneDriveConsumer, OneDriveCommercial), where OneDrive's backup moves Documents.</summary>
    public static List<string> WindowsProjectFolders(string home, IReadOnlyDictionary<string, string> env, Func<string, bool> exists)
    {
        var all = new List<string> { Join(home, @"source\repos"), Join(home, @"Documents\GitHub") };
        foreach (var key in new[] { "OneDrive", "OneDriveConsumer", "OneDriveCommercial" })
        {
            if (env.TryGetValue(key, out var root) && root.Length > 0) all.Add(Join(root, @"Documents\GitHub"));
        }
        return all.Distinct(StringComparer.Ordinal).Where(exists).ToList();
    }

    /// <summary>Dart's <c>p.windows.join</c> for a folder and the parts below it.</summary>
    private static string Join(string dir, string below) =>
        dir.Length == 0 || dir.EndsWith('\\') || dir.EndsWith('/') ? dir + below : $"{dir}\\{below}";

    /// <summary>The usual project folders that exist here and aren't in <paramref name="roots"/> yet,
    /// sorted. The home folder is listed rather than each name tried, so a case-insensitive disk doesn't
    /// offer ~/Projects twice. <paramref name="windows"/>: Windows' folders too (this platform's if null),
    /// <paramref name="env"/> this process's if null.</summary>
    public static List<string> Suggestions(
        string home, IReadOnlyList<string> roots, bool? windows = null, IReadOnlyDictionary<string, string>? env = null)
    {
        var found = new List<string>();
        try
        {
            foreach (var e in Directory.EnumerateDirectories(home))
            {
                // A real folder, not a link to one.
                if (new DirectoryInfo(e).LinkTarget == null && Usual.Contains(Path.GetFileName(e))) found.Add(e);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException)
        {
            // No home folder to look in.
        }
        if (windows ?? OperatingSystem.IsWindows())
        {
            var vars = env ?? Environment.GetEnvironmentVariables()
                .Cast<System.Collections.DictionaryEntry>()
                .ToDictionary(v => (string)v.Key, v => (string?)v.Value ?? "");
            found.AddRange(WindowsProjectFolders(home, vars, Directory.Exists));
        }
        found.Sort(StringComparer.Ordinal);
        return found.Where(f => !roots.Contains(f)).ToList();
    }
}
