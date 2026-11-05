using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>
/// The computer's orchestrator: an omp session PocketTerm starts in its own folder (beside cli.json,
/// <see cref="LiveHub.OrchestratorDir"/>) that the PocketTerm extension gives tools to see and steer the other
/// sessions (integrations/omp/pocketterm-live.ts). Its calls come to the hub as <c>call</c> frames; this is what
/// they answer. The texts read the hub under its lock.
/// </summary>
public static partial class Orchestrator
{
    /// <summary>The file in the orchestrator folder omp appends to its system prompt
    /// (<c>omp --append-system-prompt ORCHESTRATOR.md</c>).</summary>
    public const string OrchestratorPromptFile = "ORCHESTRATOR.md";

    /// <summary>What the orchestrator is told, beyond omp's own system prompt.</summary>
    public const string OrchestratorInstructions =
        "You are the PocketTerm orchestrator on this computer. The person talks to you from their phone, often in short typed or spoken messages, to find out about and steer the other coding sessions running here.\n" +
        "\n" +
        "- Use pocketterm_sessions to see what is running, and pocketterm_read to look inside a session before saying anything about it. Never guess what a session is doing.\n" +
        "- Answer briefly, for a phone screen: the answer first, sessions named by project and title, not by key.\n" +
        "- Use pocketterm_prompt only when the person asks you to tell a session something or clearly agrees to it; when the wording isn't obvious, say what you will send. Use deliver \"followUp\" unless they want the session's current run redirected now.\n" +
        "- Use pocketterm_stop only when the person asks you to stop a session.\n" +
        "- You run in an empty folder. Don't edit files or run commands to answer questions about sessions: their transcripts are the source of truth.\n";

    /// <summary>Whether a session in <paramref name="cwd"/> is the orchestrator: <paramref name="cwd"/> is
    /// <paramref name="dir"/> (symlinks resolved; Windows ignores case).</summary>
    public static bool IsOrchestratorDir(string cwd, string? dir)
    {
        if (dir == null || cwd.Length == 0) return false;
        return string.Equals(Real(cwd), Real(dir), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
    }

    /// <summary><paramref name="path"/> with its symlinks resolved (Dart's <c>resolveSymbolicLinksSync</c>), or
    /// normalized when it can't be (gone, say).</summary>
    private static string Real(string path)
    {
        try
        {
            var full = Path.GetFullPath(path);
            if (!Directory.Exists(full) && !File.Exists(full)) return Normalize(full);
            // Part by part: a link anywhere along the way counts, and so do links in where it leads.
            var real = Path.GetPathRoot(full) ?? "";
            var rest = new List<string>(Parts(full[real.Length..]));
            var hops = 0;
            while (rest.Count > 0)
            {
                var next = Path.Combine(real, rest[0]);
                rest.RemoveAt(0);
                FileSystemInfo info = Directory.Exists(next) ? new DirectoryInfo(next) : new FileInfo(next);
                if (info.LinkTarget is { } target)
                {
                    if (++hops > 40) throw new IOException($"Too many levels of symbolic links: {path}");
                    var to = Path.GetFullPath(target, real);
                    real = Path.GetPathRoot(to) ?? "";
                    rest.InsertRange(0, Parts(to[real.Length..]));
                    continue;
                }
                real = next;
            }
            return Normalize(real);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return Normalize(path);
        }
    }

    private static string[] Parts(string path) =>
        path.Split([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries);

    private static string Normalize(string path)
    {
        var full = Path.GetFullPath(path);
        var root = Path.GetPathRoot(full) ?? "";
        return full.Length > root.Length ? full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) : full;
    }

    /// <summary>Makes <paramref name="dir"/> and (re)writes its <see cref="OrchestratorPromptFile"/> with
    /// <see cref="OrchestratorInstructions"/>.</summary>
    public static async Task PrepareOrchestratorDirAsync(string dir)
    {
        Directory.CreateDirectory(dir);
        await File.WriteAllTextAsync(Path.Combine(dir, OrchestratorPromptFile), OrchestratorInstructions);
    }

    /// <summary>How a call's answer names <paramref name="s"/>: <c>&lt;project&gt; "&lt;title&gt;" (&lt;key&gt;)</c>.</summary>
    public static string NamedSession(LiveHub hub, LiveSession s)
    {
        lock (hub.Gate) return $"{Project(hub, s)} \"{Title(s)}\" ({s.Key})";
    }

    private static string Project(LiveHub hub, LiveSession s)
    {
        var name = hub.ProjectName(s);
        return name.Length > 0 ? name : (s.Cwd.Length > 0 ? s.Cwd : "(no folder)");
    }

    private static string Title(LiveSession s) => s.Title.Length == 0 ? "(untitled)" : s.Title;

    private static string State(LiveSession s) =>
        s.Ask != null ? "waiting for an answer" : s.Busy ? "working" : s.Failed ? "last run failed" : "idle";

    private static string Ago(DateTime at, DateTime now)
    {
        var d = now - at;
        // Dart's Duration.inMinutes/inHours/inSeconds truncate toward zero.
        if ((long)d.TotalMinutes < 1) return $"{Math.Clamp((long)d.TotalSeconds, 0, 59)}s ago";
        if ((long)d.TotalHours < 1) return $"{(long)d.TotalMinutes} min ago";
        return $"{(long)d.TotalHours} h ago";
    }

    /// <summary><paramref name="s"/> cut to <paramref name="max"/> characters, ending with <c>…</c> when cut.</summary>
    private static string Clip(string s, int max) => s.Length <= max ? s : $"{s[..max]}…";

    private static string AgentAndModel(LiveSession s) => s.Model.Length > 0 ? $"{s.Agent.Label()} {s.Model}" : s.Agent.Label();

    /// <summary>The <c>sessions</c> call's text: every session but the orchestrators.</summary>
    public static string SessionsText(LiveHub hub, DateTime now)
    {
        lock (hub.Gate)
        {
            static int Rank(LiveSession s) => s.Ask != null ? 0 : (s.Busy ? 1 : 2);
            var sessions = hub.Sessions.Where(s => !s.Orchestrator).ToList();
            // Stable, as Dart's sort is on lists this short (insertion sort).
            sessions = sessions.Select((s, i) => (s, i))
                .OrderBy(x => Rank(x.s)).ThenByDescending(x => x.s.At).ThenBy(x => x.i)
                .Select(x => x.s).ToList();
            if (sessions.Count == 0) return "No other coding sessions are running on this computer.";
            var out_ = new StringBuilder($"{sessions.Count} coding session{(sessions.Count == 1 ? "" : "s")} on this computer:");
            foreach (var s in sessions)
            {
                var summary = s.Summary;
                var parts = new List<string> { s.Key, Project(hub, s), $"\"{Title(s)}\"", AgentAndModel(s), State(s) };
                if (s.Ctx != null) parts.Add($"ctx {s.Ctx}%");
                if (s.Cost is { } cost) parts.Add($"${cost.ToString("F2", CultureInfo.InvariantCulture)}");
                if (summary.Queue.Count > 0) parts.Add($"{summary.Queue.Count} queued{(summary.Paused ? ", paused" : "")}");
                parts.Add($"active {Ago(s.At, now)}");
                out_.Append($"\n- {string.Join(" | ", parts)}");
                if (s.Ask != null) out_.Append($"\n  waiting on: {s.Ask.Text}");
                if (s.Preview.Length > 0) out_.Append($"\n  last answer: {s.Preview}");
            }
            return out_.ToString();
        }
    }

    /// <summary>The most a <c>read</c> answer takes, in characters.</summary>
    private const int MaxRead = 40000;

    /// <summary>The <c>read</c> call's text: <paramref name="s"/>'s newest <paramref name="last"/> items (1..200).</summary>
    public static string TranscriptText(LiveHub hub, LiveSession s, int last)
    {
        lock (hub.Gate)
        {
            var header = $"Session {s.Key} — {Project(hub, s)} · \"{Title(s)}\" · {AgentAndModel(s)} · {State(s)}";
            var items = s.Log.Items;
            var take = Math.Clamp(Math.Clamp(last, 1, 200), 0, items.Count);
            var newest = items.GetRange(items.Count - take, take);
            var blocks = new List<string>();
            var size = 0;
            for (var n = newest.Count - 1; n >= 0; n--)
            {
                var b = Block(newest[n]);
                if (size + b.Length + 2 > MaxRead) break;
                size += b.Length + 2;
                blocks.Add(b);
            }
            blocks.Reverse();
            var summary = s.Summary;
            var parts = new List<string> { header };
            if (blocks.Count < items.Count || s.Log.Older) parts.Add("(earlier items left out)");
            parts.AddRange(blocks);
            if (s.Ask != null) parts.Add($"Waiting on: {s.Ask.Text}");
            if (summary.Queue.Count > 0)
            {
                parts.Add($"Queued prompts{(summary.Paused ? " (paused)" : "")}:");
                for (var n = 0; n < summary.Queue.Count; n++) parts.Add($"{n + 1}. {Clip(summary.Queue[n].Text, 300)}");
            }
            return string.Join("\n\n", parts);
        }
    }

    private static string Block(LiveItem i) => i.Kind switch
    {
        ItemKind.User => $"[user] {Clip(i.Text, 2000)}{(i.Images > 0 ? $" (+{i.Images} images)" : "")}",
        ItemKind.Assistant => $"[assistant] {Clip(i.Text, 6000)}",
        ItemKind.Tool => i.Output.Length > 0
            ? $"{ToolLine(i)}\n{Tail(i.Output)}"
            : ToolLine(i),
        _ => $"[notice] {Clip(i.Text, 500)}",
    };

    private static string ToolLine(LiveItem i) =>
        $"[tool {i.Tool} {i.Status.Name()}] {Clip(Spaces().Replace(i.Title.Length > 0 ? i.Title : i.Args, " ").DartTrim(), 200)}";

    /// <summary>A tool's output as <c>read</c> shows it: its last 12 lines, at most their last 1200 characters, indented.</summary>
    private static string Tail(string output)
    {
        var end = output.Length;
        while (end > 0 && DartString.IsDartWhitespace(output[end - 1])) end--;
        var lines = output[..end].Split('\n');
        var text = string.Join("\n", lines.Skip(lines.Length > 12 ? lines.Length - 12 : 0));
        if (text.Length > 1200) text = $"…{text[^1200..]}";
        return string.Join("\n", text.Split('\n').Select(l => $"  {l}"));
    }

    /// <summary>Dart's (JavaScript's) regex <c>\s+</c>.</summary>
    [GeneratedRegex(@"[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+")]
    private static partial Regex Spaces();
}
