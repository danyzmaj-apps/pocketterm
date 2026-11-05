using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace PocketTerm.Core;

/// <summary>One process as <c>ps</c> lists it; <c>Tty</c> is <c>ttys012</c>, or empty.</summary>
public sealed record Proc(int Pid, int Ppid, int Pgid, int Tpgid, string Tty, string Stat, string Args)
{
    /// <summary>What runs, by name: <c>omp</c>, <c>claude</c>, <c>zsh</c>, <c>tmux</c>; a script's name for
    /// an interpreter (<c>node …/x.js</c> is x).</summary>
    public string Program => Terminal.ProgramOf(Args);
}

/// <summary>A snapshot of the computer's processes (one <c>ps</c>; <c>tasklist</c> on Windows), to tell a
/// tty's foreground program and whether an app runs.</summary>
public sealed class Procs(IReadOnlyList<Proc> all)
{
    public IReadOnlyList<Proc> All { get; } = all;

    public static async Task<Procs> SnapshotAsync(bool? windows = null)
    {
        if (windows ?? OperatingSystem.IsWindows())
        {
            var tasks = await RunAsync("tasklist", ["/fo", "csv", "/nh"], null);
            return new Procs(tasks == null ? [] : Terminal.ParseTasklist(tasks));
        }
        var ps = await RunAsync("/bin/ps", ["-Ao", "pid=,ppid=,pgid=,tpgid=,tty=,stat=,args="], Terminal.Utf8Output);
        return new Procs(ps == null ? [] : Terminal.ParsePs(ps));
    }

    /// <summary>The foreground program on <paramref name="tty"/> (<c>ttys012</c> or <c>/dev/ttys012</c>):
    /// the leader of its foreground process group.</summary>
    public Proc? Foreground(string tty)
    {
        var i = tty.IndexOf("/dev/", StringComparison.Ordinal);
        var t = i < 0 ? tty : tty.Remove(i, 5);
        if (t.Length == 0) return null;
        var on = All.Where(p => p.Tty == t).ToList();
        return on.FirstOrDefault(p => p.Pid == p.Tpgid) ??
            on.FirstOrDefault(p => p.Pgid == p.Tpgid) ??
            on.LastOrDefault(p => p.Stat.Contains('+'));
    }

    public Proc? ByPid(int pid) => All.FirstOrDefault(p => p.Pid == pid);

    /// <summary>Whether a process whose command starts with <paramref name="exe"/> runs.</summary>
    public bool Running(string exe) => All.Any(p => p.Args.StartsWith(exe, StringComparison.Ordinal));

    /// <summary>The pid of the first process whose command starts with <paramref name="exe"/>.</summary>
    public int? PidOf(string exe) => All.FirstOrDefault(p => p.Args.StartsWith(exe, StringComparison.Ordinal))?.Pid;

    /// <summary>Working directories of <paramref name="pids"/>, in one <c>lsof</c>; none on Windows.</summary>
    public static async Task<IReadOnlyDictionary<int, string>> CwdsAsync(IEnumerable<int> pids, bool? windows = null)
    {
        if (windows ?? OperatingSystem.IsWindows()) return new Dictionary<int, string>();
        var list = pids.Distinct().ToList();
        if (list.Count == 0) return new Dictionary<int, string>();
        var output = await RunAsync(
            "/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p", string.Join(',', list)], Terminal.Utf8Output);
        return output == null ? new Dictionary<int, string>() : Terminal.ParseLsofCwd(output);
    }

    /// <summary>A program's standard output (UTF-8); null when it can't be started (Dart's ProcessException).</summary>
    private static async Task<string?> RunAsync(string exe, IReadOnlyList<string> args, IReadOnlyDictionary<string, string>? env)
    {
        var info = new ProcessStartInfo(exe)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
        };
        foreach (var a in args) info.ArgumentList.Add(a);
        if (env != null)
        {
            foreach (var (k, v) in env) info.Environment[k] = v;
        }
        try
        {
            using var p = Process.Start(info);
            if (p == null) return null;
            var stdout = p.StandardOutput.ReadToEndAsync();
            var stderr = p.StandardError.ReadToEndAsync();
            await p.WaitForExitAsync();
            await stderr;
            return await stdout;
        }
        catch (Win32Exception)
        {
            return null;
        }
    }
}
