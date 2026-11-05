using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace PocketTerm.Desktop;

/// <summary>How a command went: its exit code (null when it was stopped) and what it printed, both streams.</summary>
public readonly record struct CommandResult(int? Code, string Output);

/// <summary>
/// Runs a program with its arguments, <paramref name="environment"/> added to this app's own; tests hand in a
/// fake. Throws <see cref="Win32Exception"/> when the program isn't there (as <c>Process.Start</c>).
/// </summary>
public delegate Task<CommandResult> RunCommand(string executable, IReadOnlyList<string> arguments, IReadOnlyDictionary<string, string> environment);

/// <summary>
/// The installs the setup offers to run for the person (<c>winget install Tailscale.Tailscale</c>,
/// <see cref="Tailscale.WingetInstall"/>), each only after they confirmed it, never on its own. The Mac app's
/// Homebrew/MacPorts branch stays with the Mac app.
/// </summary>
public sealed class Commands
{
    private readonly RunCommand _run;
    private readonly bool _windows;

    public Commands(RunCommand? run = null, bool? windows = null)
    {
        _run = run ?? RunProcess;
        _windows = windows ?? OperatingSystem.IsWindows();
    }

    /// <summary>
    /// Windows' package manager, which comes with Windows 10 and 11 (App Installer); null elsewhere. Whether it
    /// really runs shows when it does.
    /// </summary>
    public string? Winget => _windows ? "winget" : null;

    /// <summary>
    /// Runs <paramref name="argv"/> (the program first). The command keeps this app's own environment. A PC without
    /// winget gets a failed result that says so, not an exception.
    /// </summary>
    public async Task<CommandResult> RunAsync(IReadOnlyList<string> argv)
    {
        try
        {
            return await _run(argv[0], argv.Skip(1).ToList(), new Dictionary<string, string>()).ConfigureAwait(false);
        }
        catch (Win32Exception) when (argv[0] == "winget")
        {
            return new CommandResult(127, "winget isn’t on this PC (it comes with Windows’ App Installer, from the Microsoft Store).");
        }
    }

    private static async Task<CommandResult> RunProcess(string exe, IReadOnlyList<string> args, IReadOnlyDictionary<string, string> env)
    {
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        foreach (var (k, v) in env) psi.Environment[k] = v;
        using var process = Process.Start(psi) ?? throw new Win32Exception($"{exe} didn't start.");
        var output = new StringBuilder();
        var gate = new object();

        async Task Pump(StreamReader reader)
        {
            var buffer = new char[4096];
            int n;
            while ((n = await reader.ReadAsync(buffer).ConfigureAwait(false)) > 0)
            {
                lock (gate) output.Append(buffer, 0, n);
            }
        }

        await Task.WhenAll(Pump(process.StandardOutput), Pump(process.StandardError)).ConfigureAwait(false);
        await process.WaitForExitAsync().ConfigureAwait(false);
        return new CommandResult(process.ExitCode, output.ToString());
    }
}
