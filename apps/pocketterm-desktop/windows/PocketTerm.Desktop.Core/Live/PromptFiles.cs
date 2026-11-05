using System.Security.Cryptography;
using System.Text.RegularExpressions;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>
/// The files phones send with prompts, as the agent gets them: each prompt's in a folder of its own under
/// <see cref="Dir"/> (by default <c>pocketterm-files</c> in the user's temp folder, <c>%TEMP%</c> on Windows), under
/// the name it had on the phone, made safe (<see cref="SafeFileName"/>). The prompt names them as <c>@path</c>
/// (<see cref="WithMentions"/>), as one would at the computer. Folders older than a day go when more come and when
/// PocketTerm starts. Stateless apart from the disk: safe to call from any thread.
/// </summary>
public sealed partial class PromptFiles
{
    public PromptFiles(string? dir = null)
    {
        Dir = dir ?? Path.Combine(Path.GetTempPath(), "pocketterm-files");
    }

    public string Dir { get; }

    public static readonly TimeSpan Keep = TimeSpan.FromDays(1);

    /// <summary>Writes <paramref name="files"/> into a new folder, none over another; their paths.</summary>
    public async Task<List<string>> SaveAsync(IReadOnlyList<PromptFile> files)
    {
        if (files.Count == 0) return [];
        if (!Directory.Exists(Dir))
        {
            Directory.CreateDirectory(Dir);
            // Private to this user; Windows' per-user temp folder already is.
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(Dir, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
        await PruneAsync();
        var folder = Directory.CreateDirectory(Path.Combine(Dir, RandomName(12))).FullName;
        var paths = new List<string>(files.Count);
        foreach (var f in files) paths.Add(await WriteAsync(folder, SafeFileName(f.Name, f.Mime), f.Bytes));
        return paths;
    }

    /// <summary><paramref name="length"/> random characters of <c>[0-9a-z]</c>.</summary>
    internal static string RandomName(int length)
    {
        Span<char> c = stackalloc char[length];
        for (var i = 0; i < length; i++) c[i] = "0123456789abcdefghijklmnopqrstuvwxyz"[RandomNumberGenerator.GetInt32(36)];
        return new string(c);
    }

    /// <summary><paramref name="bytes"/> as <paramref name="name"/> in <paramref name="folder"/>, or <c>name (2)</c>,
    /// <c>name (3)</c> … when that is taken.</summary>
    private static async Task<string> WriteAsync(string folder, string name, byte[] bytes)
    {
        var ext = Extension(name);
        var stem = name[..^ext.Length];
        for (var n = 1; ; n++)
        {
            var path = Path.Combine(folder, n == 1 ? name : $"{stem} ({n}){ext}");
            FileStream file;
            try
            {
                file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            }
            catch (IOException) when (File.Exists(path))
            {
                continue;
            }
            await using (file)
            {
                await file.WriteAsync(bytes);
                await file.FlushAsync();
            }
            return path;
        }
    }

    /// <summary>Deletes the folders older than <see cref="Keep"/>.</summary>
    public Task PruneAsync() => Task.Run(() =>
    {
        if (!Directory.Exists(Dir)) return;
        var before = DateTime.UtcNow - Keep;
        IEnumerable<string> entries;
        try
        {
            entries = Directory.EnumerateDirectories(Dir).ToList();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Print($"PocketTerm: prompt files cleanup: {e.Message}");
            return;
        }
        foreach (var e in entries)
        {
            try
            {
                if (Directory.GetLastWriteTimeUtc(e) < before) Directory.Delete(e, recursive: true);
            }
            catch (Exception err) when (err is IOException or UnauthorizedAccessException)
            {
                Log.Print($"PocketTerm: prompt files cleanup: {err.Message}");
            }
        }
    });

    /// <summary>
    /// <paramref name="name"/> as a file name that stays in its folder: only what follows its last <c>/</c> or
    /// <c>\</c>, without control characters or the ones Windows refuses (<c>&lt;&gt;:"|?*</c>), spaces and dots at its
    /// end (so never <c>.</c> or <c>..</c>) or a Windows device name (<c>CON</c>, <c>CONIN$</c>, <c>COM¹</c>, … with
    /// any extension, also with spaces before it); at most 120 characters, its extension kept. Without an extension
    /// it gets the one <paramref name="mime"/> has. <c>file</c> when nothing is left.
    /// </summary>
    public static string SafeFileName(string name, string mime = "")
    {
        var n = Separators().Split(name)[^1];
        n = Refused().Replace(n, "").DartTrim();
        n = TrailingDots().Replace(n, "", 1);
        if (n.Length == 0) n = "file";
        if (FileTypes.FileExtension(n).Length == 0 && FileTypes.MimeExtension(mime) is { } ext) n = $"{n}.{ext}";
        if (DeviceName().IsMatch(n)) n = $"_{n}";
        if (n.Length > 120)
        {
            var e = Extension(n);
            n = e.Length < 20 ? $"{TrimRight(n[..(120 - e.Length)])}{e}" : n[..120];
        }
        return n;
    }

    /// <summary>The path package's <c>extension</c>: from the last dot of the name on, none for a name that only
    /// starts with one (<c>.env</c>).</summary>
    private static string Extension(string name)
    {
        var dot = name.LastIndexOf('.');
        return dot <= 0 ? "" : name[dot..];
    }

    private static string TrimRight(string s)
    {
        var end = s.Length;
        while (end > 0 && DartString.IsDartWhitespace(s[end - 1])) end--;
        return s[..end];
    }

    [GeneratedRegex(@"[/\\]")]
    private static partial Regex Separators();

    [GeneratedRegex("[\\x00-\\x1f\\x7f<>:\"|?*]")]
    private static partial Regex Refused();

    [GeneratedRegex(@"[. ]+\z")]
    private static partial Regex TrailingDots();

    /// <summary>A name Windows opens as a device: its part before the first dot, spaces after it ignored, is one of these.</summary>
    [GeneratedRegex(@"^(con|prn|aux|nul|conin\$|conout\$|com[0-9¹²³]|lpt[0-9¹²³]) *(\.[^\n\r\u2028\u2029]*)?\z", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex DeviceName();

    /// <summary>
    /// <paramref name="path"/> as omp and Claude Code take a file named in a prompt: <c>@path</c>, or <c>@"path"</c>
    /// when it holds a character that would end the mention (a space, a quote) or a trailing one they'd take for
    /// punctuation.
    /// </summary>
    public static string FileMention(string path) => Mentionable().IsMatch(path) ? $"@{path}" : $"@\"{path}\"";

    [GeneratedRegex(@"^[A-Za-z0-9_./+~,=%-]*[A-Za-z0-9_/+~=%-]\z")]
    private static partial Regex Mentionable();

    /// <summary><paramref name="text"/> with a mention (<see cref="FileMention"/>) of each of <paramref name="paths"/> after it.</summary>
    public static string WithMentions(string text, IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return text;
        return string.Join("\n\n", new[] { text.DartTrim(), string.Join(" ", paths.Select(FileMention)) }.Where(s => s.Length > 0));
    }
}
