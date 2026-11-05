using System.Collections;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading.Channels;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>Where Tailscale stands on this computer.</summary>
public enum TailscaleState
{
    /// <summary>No Tailscale CLI here: install Tailscale.</summary>
    Missing,

    /// <summary>Installed, but not running or switched off: open Tailscale.</summary>
    Stopped,

    /// <summary>Running, but signed out of its tailnet: open Tailscale and sign in.</summary>
    LoggedOut,

    /// <summary>Connected to its tailnet.</summary>
    Running,
}

/// <summary>What <c>tailscale status --json</c> says about this computer.</summary>
/// <param name="DnsName">This computer's MagicDNS name without the trailing dot (<c>mac.tail1234.ts.net</c>); null without MagicDNS.</param>
/// <param name="Https">HTTPS certificates are on for the tailnet (CertDomains isn't empty).</param>
public sealed record TailscaleStatus(TailscaleState State, string? DnsName = null, bool Https = false)
{
    /// <summary>Where <c>tailscale serve</c> publishes this computer: <c>https://&lt;dnsName&gt;</c>.</summary>
    // Dart's Uri lowercases the host.
    public string? Url => DnsName == null ? null : $"https://{DnsName.ToLowerInvariant()}";
}

/// <summary>How <c>tailscale serve</c> went.</summary>
public sealed class ServeResult
{
    private ServeResult(string? enableLink, string? error, string? taken)
    {
        EnableLink = enableLink;
        Error = error;
        Taken = taken;
    }

    /// <summary>Published.</summary>
    public static ServeResult Success { get; } = new(null, null, null);

    /// <summary>The tailnet has HTTPS (Serve) off: <paramref name="enableLink"/> turns it on.</summary>
    public static ServeResult NeedsHttps(string enableLink) => new(enableLink, null, null);

    /// <summary>The CLI failed otherwise.</summary>
    public static ServeResult Failed(string error) => new(null, error, null);

    /// <summary>Port 443 of this computer's Tailscale name already serves something else (<paramref name="taken"/> says what), so nothing was changed.</summary>
    public static ServeResult TakenBy(string taken) => new(
        null,
        $"Tailscale already serves {taken} on this computer’s HTTPS port (443). PocketTerm leaves it alone: " +
        "remove it with tailscale serve --https=443 off, or serve it on another port, then check again.",
        taken);

    /// <summary>The tailnet has HTTPS (Serve) off: the page that turns it on.</summary>
    public string? EnableLink { get; }

    /// <summary>What the CLI said when it failed otherwise.</summary>
    public string? Error { get; }

    /// <summary>What already uses port 443 (<see cref="TakenBy"/>).</summary>
    public string? Taken { get; }

    public bool Ok => EnableLink == null && Error == null;
}

/// <summary>What port 443 of this computer's Tailscale name serves (<see cref="Tailscale.Port443Async"/>).</summary>
public abstract record Serving;

/// <summary>Nothing.</summary>
public sealed record ServingNothing : Serving;

/// <summary>This app's built-in server, and nothing else.</summary>
public sealed record ServingOurs : Serving;

/// <summary>Something else, <paramref name="What"/> in words: it stays.</summary>
public sealed record ServingElsewhere(string What) : Serving;

/// <summary>The CLI couldn't say (it failed, or took too long): nothing is changed.</summary>
public sealed record ServingUnknown : Serving;

/// <summary>A program started for the Tailscale CLI: what it prints, as it prints it, and its exit.</summary>
public interface ITailscaleProcess
{
    /// <summary>Its output, stdout and stderr as they come; completes once both streams end.</summary>
    ChannelReader<string> Output { get; }

    /// <summary>Its exit code.</summary>
    Task<int> Exit { get; }

    /// <summary>Stops it.</summary>
    void Kill();
}

/// <summary>Starts a program (Dart's <c>Process.start</c>); tests hand in a fake.</summary>
public delegate Task<ITailscaleProcess> StartTailscale(string executable, IReadOnlyList<string> arguments);

/// <summary>
/// The Tailscale CLI: whether Tailscale runs here and under which name, and <c>tailscale serve</c>, which
/// publishes the built-in server at <c>https://&lt;this computer&gt;.&lt;tailnet&gt;.ts.net</c> to the tailnet
/// only. Stateless: safe from any thread.
/// </summary>
public sealed partial class Tailscale
{
    private readonly StartTailscale _start;
    private readonly Func<string?> _locate;
    private readonly bool _windows;

    /// <param name="windows">Windows' Tailscale (<see cref="OpenAsync"/>); this computer's by default.</param>
    public Tailscale(StartTailscale? start = null, Func<string?>? locate = null, bool? windows = null)
    {
        _start = start ?? StartCli;
        _locate = locate ?? (() => FindCli());
        _windows = windows ?? OperatingSystem.IsWindows();
    }

    /// <summary>
    /// The Mac app's binary is the CLI only when started from a terminal; started by an app (no TERM), it tries
    /// to open its window and prints nothing. <c>TAILSCALE_BE_CLI</c> tells it to act as the CLI either way.
    /// </summary>
    public static IReadOnlyDictionary<string, string> CliEnvironment { get; } = new Dictionary<string, string> { ["TAILSCALE_BE_CLI"] = "1" };

    /// <summary>Where to get Tailscale.</summary>
    public const string Download = "https://tailscale.com/download";

    /// <summary>The admin console's DNS page: MagicDNS and HTTPS certificates.</summary>
    public const string AdminDns = "https://login.tailscale.com/admin/dns";

    /// <summary>The Mac app's CLI (App Store and standalone builds alike).</summary>
    public const string MacCli = "/Applications/Tailscale.app/Contents/MacOS/Tailscale";

    /// <summary>Where to get Tailscale for Windows by hand.</summary>
    public const string WindowsDownload = "https://tailscale.com/download/windows";

    /// <summary>What <c>winget</c> installs on Windows.</summary>
    public static IReadOnlyList<string> WingetInstall { get; } =
    [
        "winget",
        "install",
        "--id",
        "Tailscale.Tailscale",
        "--exact",
        "--source",
        "winget",
        "--accept-source-agreements",
        "--accept-package-agreements",
    ];

    /// <summary>Why PocketTerm changed nothing: <c>tailscale serve status</c> didn't answer.</summary>
    public const string Unreadable =
        "PocketTerm couldn’t read Tailscale’s Serve settings, so it changed nothing. It checks again by itself.";

    /// <summary>Windows' CLI in Program Files (<paramref name="programFiles"/>, which needn't be on C:).</summary>
    public static string WindowsCli(string? programFiles = null) => WindowsJoin(programFiles ?? ProgramFiles, "Tailscale", "tailscale.exe");

    /// <summary>The Windows app that shows Tailscale's window, in Program Files.</summary>
    public static string WindowsApp(string? programFiles = null) => WindowsJoin(programFiles ?? ProgramFiles, "Tailscale", "tailscale-ipn.exe");

    private static string ProgramFiles => Environment.GetEnvironmentVariable("ProgramFiles") ?? @"C:\Program Files";

    /// <summary>
    /// The CLI: <c>POCKETTERM_TAILSCALE</c> when set in a test build (<see cref="TestHooks.Env"/>; tool/smoke: a
    /// stand-in, so a throwaway copy never changes Serve settings), the app's own on a Mac or Windows, else
    /// <c>tailscale</c> on the PATH (a GUI app's PATH is short, so Homebrew's folders too on a Mac). Null when
    /// Tailscale isn't installed.
    /// </summary>
    public static string? FindCli(
        IReadOnlyDictionary<string, string>? env = null,
        IReadOnlyDictionary<string, string>? hooks = null,
        Func<string, bool>? exists = null,
        bool? windows = null)
    {
        var isFile = exists ?? File.Exists;
        var win = windows ?? OperatingSystem.IsWindows();
        var vars = env ?? ProcessEnvironment();
        if ((hooks ?? TestHooks.Env()).TryGetValue("POCKETTERM_TAILSCALE", out var standIn) && standIn.Length > 0) return standIn;
        var app = win ? WindowsCli(vars.TryGetValue("ProgramFiles", out var pf) ? pf : @"C:\Program Files") : MacCli;
        if (isFile(app)) return app;
        var dirs = (vars.TryGetValue("PATH", out var path) ? path : "")
            .Split(win ? ';' : ':')
            .Where(d => d.Length > 0)
            .ToList();
        if (!win) dirs.AddRange(["/opt/homebrew/bin", "/usr/local/bin"]);
        foreach (var dir in dirs)
        {
            var candidate = win ? WindowsJoin(dir, "tailscale.exe") : PosixJoin(dir, "tailscale");
            if (isFile(candidate)) return candidate;
        }
        return null;
    }

    /// <summary>This process's environment; Windows' names are case-insensitive (<c>Path</c> is <c>PATH</c>).</summary>
    private static Dictionary<string, string> ProcessEnvironment()
    {
        var env = new Dictionary<string, string>(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
        foreach (DictionaryEntry e in Environment.GetEnvironmentVariables())
        {
            if (e.Key is string k && e.Value is string v) env[k] = v;
        }
        return env;
    }

    /// <summary>Whether Tailscale runs here, signed in, and this computer's name.</summary>
    public async Task<TailscaleStatus> StatusAsync()
    {
        var cli = _locate();
        if (cli == null) return new TailscaleStatus(TailscaleState.Missing);
        (int? Code, string Out) run;
        try
        {
            run = await RunAsync(cli, ["status", "--json"], TimeSpan.FromSeconds(10)).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: tailscale status: {e.Message}");
            return new TailscaleStatus(TailscaleState.Stopped);
        }
        return ParseStatus(run.Out);
    }

    /// <summary><c>tailscale status --json</c>'s output read; anything else (the service isn't running) reads as stopped.</summary>
    public static TailscaleStatus ParseStatus(string output)
    {
        if (DecodeFromBrace(output, out var node) is false || node is not JsonObject json) return new TailscaleStatus(TailscaleState.Stopped);
        var state = DartJson.AsString(json["BackendState"]) switch
        {
            "Running" => TailscaleState.Running,
            "NeedsLogin" or "NeedsMachineAuth" => TailscaleState.LoggedOut,
            _ => TailscaleState.Stopped,
        };
        if (state != TailscaleState.Running) return new TailscaleStatus(state);
        var name = (json["Self"] as JsonObject)?.Str("DNSName") ?? "";
        name = name.TrimEnd('.');
        var certs = json["CertDomains"] as JsonArray;
        return new TailscaleStatus(state, name.Length == 0 ? null : name, certs is { Count: > 0 });
    }

    /// <summary>
    /// Publishes <c>http://127.0.0.1:&lt;port&gt;</c> at <c>https://&lt;this computer's name&gt;</c> on the
    /// tailnet, in the background (<c>tailscale serve --bg</c>), so it lasts until <see cref="UnserveAsync"/>. A
    /// tailnet with HTTPS off answers with the page that turns it on: the CLI prints it and waits, so it's stopped
    /// there. Something else already served on 443 stays: it's never replaced, and nothing is changed while
    /// <c>tailscale serve status</c> can't say. <paramref name="earlier"/>: the port this app's server had before
    /// (its entry is this app's to move).
    /// </summary>
    public async Task<ServeResult> ServeAsync(int port, int? earlier = null)
    {
        var cli = _locate();
        if (cli == null) return ServeResult.Failed("Tailscale isn’t installed.");
        var ours = new HashSet<int> { port };
        if (earlier is { } e) ours.Add(e);
        switch (await Port443Async(ours).ConfigureAwait(false))
        {
            case ServingElsewhere elsewhere:
                return ServeResult.TakenBy(elsewhere.What);
            case ServingUnknown:
                return ServeResult.Failed(Unreadable);
        }
        (int? Code, string Out) run;
        try
        {
            run = await RunAsync(
                cli,
                ["serve", "--bg", "--https=443", $"http://127.0.0.1:{port}"],
                TimeSpan.FromSeconds(30),
                stopWhen: o => EnableLinkIn(o) != null).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            return ServeResult.Failed(ex.Message);
        }
        if (EnableLinkIn(run.Out) is { } link) return ServeResult.NeedsHttps(link);
        if (run.Code == 0) return ServeResult.Success;
        return ServeResult.Failed(ServeError(run.Out));
    }

    /// <summary>What <c>tailscale serve</c> printed when it failed, for the person.</summary>
    public static string ServeError(string output)
    {
        // The open source build's daemon runs as root and lets only its operator change Serve.
        if (output.Contains("access denied", StringComparison.OrdinalIgnoreCase))
        {
            return "Tailscale didn’t let PocketTerm change its Serve settings. Run sudo tailscale set --operator=$USER " +
                "once in a terminal, then check again.";
        }
        var said = output.Trim().Split('\n').LastOrDefault(l => l.Trim().Length > 0)?.Trim() ?? "";
        return said.Length == 0 ? "tailscale serve failed." : said;
    }

    /// <summary>
    /// What serves on port 443 now (<c>tailscale serve status --json</c>): this app's built-in server at one of
    /// <paramref name="ours"/>, something else, nothing, or unknown when the CLI can't say.
    /// </summary>
    public async Task<Serving> Port443Async(IReadOnlySet<int> ours)
    {
        var cli = _locate();
        if (cli == null) return new ServingUnknown();
        try
        {
            var run = await RunAsync(cli, ["serve", "status", "--json"], TimeSpan.FromSeconds(10)).ConfigureAwait(false);
            return run.Code == 0 ? ReadServing(run.Out, ours) : new ServingUnknown();
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: tailscale serve status: {e.Message}");
            return new ServingUnknown();
        }
    }

    /// <summary>
    /// A proxy to 127.0.0.1 at one of <paramref name="ours"/>: the ports this app's own built-in server has had.
    /// Only those: another PocketTerm on this computer (a second user, a second copy) serves on a port of the
    /// same range, and its entry isn't this one's to replace.
    /// </summary>
    private static bool IsOurs(string proxy, IReadOnlySet<int> ours)
    {
        var m = OursProxy().Match(proxy.Trim());
        return m.Success && int.TryParse(m.Groups[1].Value, out var p) && ours.Contains(p);
    }

    [GeneratedRegex(@"^(?:https?://)?(?:(?:127\.0\.0\.1|localhost):)?(\d+)/?$")]
    private static partial Regex OursProxy();

    /// <summary>
    /// <paramref name="json"/> (<c>tailscale serve status --json</c>, a ServeConfig, or <c>null</c> when nothing
    /// is served) read for port 443: what serves there that isn't the built-in server at one of
    /// <paramref name="ours"/>, in words; null when nothing else does.
    /// </summary>
    public static string? ServedElsewhere(string json, IReadOnlySet<int> ours) =>
        ReadServing(json, ours) is ServingElsewhere e ? e.What : null;

    /// <summary><paramref name="json"/> (<c>tailscale serve status --json</c>) read for port 443; output that isn't a ServeConfig is unknown.</summary>
    public static Serving ReadServing(string json, IReadOnlySet<int> ours)
    {
        if (!DecodeFromBrace(json, out var config)) return new ServingUnknown();
        if (config == null) return new ServingNothing();
        if (config is not JsonObject root) return new ServingUnknown();
        var oursSeen = false;

        string? Look(JsonObject c)
        {
            if ((c["TCP"] as JsonObject)?["443"] is JsonObject tcp)
            {
                if (DartJson.AsString(tcp["TCPForward"]) is { Length: > 0 } to) return $"a TCP forward to {to}";
                if (DartJson.AsBool(tcp["HTTP"]) == true) return "plain HTTP";
            }
            if (c["Web"] is JsonObject web)
            {
                foreach (var (key, value) in web)
                {
                    if (!key.EndsWith(":443", StringComparison.Ordinal) || value is not JsonObject site) continue;
                    if (site["Handlers"] is not JsonObject handlers) continue;
                    foreach (var (mount, h) in handlers)
                    {
                        var proxy = h is JsonObject ho ? DartJson.AsString(ho["Proxy"]) : null;
                        if (mount == "/" && proxy != null && IsOurs(proxy, ours))
                        {
                            oursSeen = true;
                            continue;
                        }
                        var what = h is JsonObject handler
                            ? DartJson.AsString(handler["Proxy"]) ?? DartJson.AsString(handler["Path"]) ?? "a page"
                            : "a page";
                        return mount == "/" ? what : $"{what} at {mount}";
                    }
                }
            }
            if (c["Foreground"] is JsonObject sessions)
            {
                foreach (var (_, s) in sessions)
                {
                    if (s is JsonObject session && Look(session) is { } what) return what;
                }
            }
            return null;
        }

        if (Look(root) is { } elsewhere) return new ServingElsewhere(elsewhere);
        return oursSeen ? new ServingOurs() : new ServingNothing();
    }

    /// <summary>
    /// The JSON from the first <c>{</c> of <paramref name="text"/> on (the whole text without one), as Dart's
    /// <c>jsonDecode(out.substring(out.indexOf('{').clamp(0, out.length)))</c>; false when it isn't JSON.
    /// </summary>
    private static bool DecodeFromBrace(string text, out JsonNode? node)
    {
        var brace = text.IndexOf('{', StringComparison.Ordinal);
        try
        {
            node = DartJson.Decode(text[Math.Max(brace, 0)..]);
            return true;
        }
        catch (JsonException)
        {
            node = null;
            return false;
        }
    }

    /// <summary>The login.tailscale.com page <c>tailscale serve</c> asks for, if it does.</summary>
    public static string? EnableLinkIn(string output)
    {
        var m = EnableLink().Match(output);
        return m.Success && DartUri.TryParse(m.Value) != null ? m.Value : null;
    }

    [GeneratedRegex(@"https://login\.tailscale\.com/\S+")]
    private static partial Regex EnableLink();

    /// <summary>
    /// The page that turns HTTPS on for this tailnet, as <c>tailscale serve</c> names it (it asks for it on a
    /// tailnet with HTTPS off); the admin console's DNS page when it names none. A serve that went through (HTTPS
    /// was on after all) is taken back at once.
    /// </summary>
    public async Task<string> EnableHttpsLinkAsync(int port = 47900)
    {
        var result = await ServeAsync(port).ConfigureAwait(false);
        if (result.Ok) await UnserveAsync(port).ConfigureAwait(false);
        return result.EnableLink ?? AdminDns;
    }

    /// <summary>
    /// Stops publishing the built-in server at <paramref name="port"/> (<c>tailscale serve --https=443 off</c>),
    /// only while port 443 serves it and nothing else: something else there would go with it, and nothing is
    /// changed while <c>tailscale serve status</c> can't say.
    /// </summary>
    public async Task UnserveAsync(int port)
    {
        var cli = _locate();
        if (cli == null) return;
        if (await Port443Async(new HashSet<int> { port }).ConfigureAwait(false) is not ServingOurs) return;
        try
        {
            await RunAsync(cli, ["serve", "--https=443", "off"], TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: tailscale serve off: {e.Message}");
        }
    }

    /// <summary>Shows Tailscale's app, to start it or sign in.</summary>
    public async Task OpenAsync()
    {
        try
        {
            var process = _windows
                ? await _start(WindowsApp(), []).ConfigureAwait(false)
                : await _start("/usr/bin/open", ["-a", "Tailscale"]).ConfigureAwait(false);
            _ = process.Exit.ContinueWith(_ => { }, TaskScheduler.Default);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: Tailscale not opened: {e.Message}");
        }
    }

    /// <summary>
    /// Runs <paramref name="cli"/> with <paramref name="args"/>: its exit code and what it printed (both
    /// streams). Stopped (no code) after <paramref name="timeout"/>, or once <paramref name="stopWhen"/> likes the
    /// output so far.
    /// </summary>
    private async Task<(int? Code, string Out)> RunAsync(string cli, IReadOnlyList<string> args, TimeSpan timeout, Func<string, bool>? stopWhen = null)
    {
        var process = await _start(cli, args).ConfigureAwait(false);
        var output = new StringBuilder();
        int? code = null;
        var stopped = false;
        using var cts = new CancellationTokenSource(timeout);
        try
        {
            await foreach (var chunk in process.Output.ReadAllAsync(cts.Token).ConfigureAwait(false))
            {
                output.Append(chunk);
                if (stopWhen?.Invoke(output.ToString()) ?? false)
                {
                    stopped = true;
                    break;
                }
            }
            if (!stopped) code = await process.Exit.WaitAsync(cts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception)
        {
            // Its exit couldn't be had: as stopped.
        }
        if (code == null) process.Kill();
        return (code, output.ToString());
    }

    private static Task<ITailscaleProcess> StartCli(string executable, IReadOnlyList<string> arguments) =>
        Task.FromResult<ITailscaleProcess>(SystemTailscaleProcess.Start(executable, arguments, CliEnvironment));

    private static string WindowsJoin(params string[] parts) => Join('\\', parts);

    private static string PosixJoin(params string[] parts) => Join('/', parts);

    /// <summary>package:path's join: one separator between parts, none added after one that ends with it.</summary>
    private static string Join(char separator, string[] parts)
    {
        var sb = new StringBuilder();
        foreach (var part in parts)
        {
            if (part.Length == 0) continue;
            if (sb.Length > 0 && sb[^1] != separator && !(separator == '\\' && sb[^1] == '/')) sb.Append(separator);
            sb.Append(part);
        }
        return sb.ToString();
    }

    /// <summary>A real process, its stdout and stderr read as UTF-8 into <see cref="Output"/>.</summary>
    private sealed class SystemTailscaleProcess : ITailscaleProcess
    {
        private readonly Process _process;
        private readonly Channel<string> _output = Channel.CreateUnbounded<string>();

        private SystemTailscaleProcess(Process process)
        {
            _process = process;
            var pumps = new[] { Pump(process.StandardOutput), Pump(process.StandardError) };
            Exit = Finish(pumps);
        }

        public ChannelReader<string> Output => _output.Reader;

        public Task<int> Exit { get; }

        public static SystemTailscaleProcess Start(string executable, IReadOnlyList<string> arguments, IReadOnlyDictionary<string, string> environment)
        {
            var psi = new ProcessStartInfo(executable)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            foreach (var a in arguments) psi.ArgumentList.Add(a);
            foreach (var (k, v) in environment) psi.Environment[k] = v;
            return new SystemTailscaleProcess(Process.Start(psi) ?? throw new InvalidOperationException($"{executable} didn't start."));
        }

        private async Task Pump(StreamReader reader)
        {
            var buffer = new char[4096];
            try
            {
                int n;
                while ((n = await reader.ReadAsync(buffer).ConfigureAwait(false)) > 0) _output.Writer.TryWrite(new string(buffer, 0, n));
            }
            catch (Exception)
            {
                // The process went (killed): what it printed so far is all.
            }
        }

        private async Task<int> Finish(Task[] pumps)
        {
            try
            {
                await Task.WhenAll(pumps).ConfigureAwait(false);
            }
            finally
            {
                _output.Writer.TryComplete();
            }
            await _process.WaitForExitAsync().ConfigureAwait(false);
            var code = _process.ExitCode;
            _process.Dispose();
            return code;
        }

        public void Kill()
        {
            try
            {
                _process.Kill(entireProcessTree: true);
            }
            catch (Exception)
            {
                // Gone already.
            }
        }
    }
}
