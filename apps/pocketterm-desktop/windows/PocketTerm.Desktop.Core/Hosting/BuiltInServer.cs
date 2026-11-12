using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>Where the built-in server stands, for the person: what to do next.</summary>
public enum HostState
{
    /// <summary>Looking at Tailscale for the first time.</summary>
    Checking,

    /// <summary>Tailscale isn't installed: Install.</summary>
    NoTailscale,

    /// <summary>Tailscale isn't running or is switched off: Open Tailscale.</summary>
    TailscaleOff,

    /// <summary>Tailscale is signed out: Open Tailscale.</summary>
    LoggedOut,

    /// <summary>The tailnet has HTTPS off (or MagicDNS): the page that turns it on.</summary>
    HttpsOff,

    /// <summary><c>tailscale serve</c> failed for another reason (<see cref="BuiltInServer.Error"/>).</summary>
    Failed,

    /// <summary>Port 443 of this computer's Tailscale name serves something else, left alone (<see cref="BuiltInServer.Error"/> says what).</summary>
    Taken,

    /// <summary>Phones reach it at <see cref="BuiltInServer.PublicUrl"/>.</summary>
    Ready,
}

/// <summary>What the person can do about the built-in server's state (Settings and the setup show them as buttons).</summary>
public enum HostAction
{
    /// <summary>Opens <see cref="Tailscale.Download"/>.</summary>
    InstallTailscale,

    /// <summary><see cref="Tailscale.OpenAsync"/>.</summary>
    OpenTailscale,

    /// <summary>Opens <see cref="BuiltInServer.HttpsPage"/>.</summary>
    TurnOnHttps,

    /// <summary><see cref="BuiltInServer.RefreshAsync"/>.</summary>
    CheckAgain,
}

/// <summary>The built-in server's state in a line (<see cref="BuiltInServer.Status"/>).</summary>
/// <param name="Ok">null while looking, true when phones reach it, false when something needs doing.</param>
/// <param name="Renamed">While ready: this computer's Tailscale address changed, and what that means (a Got it button calls <see cref="BuiltInServer.RenameSeen"/>).</param>
public sealed record HostStatus(string Text, bool? Ok, IReadOnlyList<HostAction> Actions, string? Renamed);

/// <summary>The built-in server didn't start, or its CLI failed.</summary>
public sealed class BuiltInServerException(string message) : Exception(message);

/// <summary>
/// The PocketTerm server built into the app ("This computer"): it listens on 127.0.0.1 only, and Tailscale
/// publishes it to the owner's tailnet at <c>https://&lt;this computer&gt;.&lt;tailnet&gt;.ts.net</c>
/// (<c>tailscale serve</c>), so phones get real HTTPS and nothing else on the network reaches it. This computer
/// signs itself in on 127.0.0.1 with the server's own setup token.
/// <para>
/// The server is the bundled sidecar (<c>pocketterm-server serve … --exit-with-stdin</c>, apps/pocketterm-server
/// README, "Bundled in the desktop apps"), a child process: its stdin stays open as the lifeline, and on Windows it
/// sits in a Job Object that kills it with the app. Threading: state is guarded by one lock, never held across an
/// await; <see cref="RefreshAsync"/> runs one look at a time; <see cref="ObservableObject.PropertyChanged"/> fires
/// on whatever thread changed it.
/// </para>
/// </summary>
public sealed class BuiltInServer : ObservableObject, IDisposable
{
    /// <summary>The phone needs Tailscale too, on the same account; the setup and the phone's QR both say so.</summary>
    public const string PhoneTailscaleNote =
        "Your phone needs the Tailscale app too, signed in to the same Tailscale account. Get it from the App Store or " +
        "Google Play. If Tailscale says Awaiting Approval, approve this phone in the Tailscale admin console under " +
        "Machines.";

    /// <summary>Add a computer: what the other computer does with <see cref="SetupLinkAsync"/>'s link.</summary>
    public const string AddComputerHow =
        "On the other computer, sign in to Tailscale with the same account, install PocketTerm, choose Join another " +
        "computer’s PocketTerm… and paste this link.";

    /// <summary>Add a computer: the link is a key.</summary>
    public const string AddComputerWarning =
        "Anyone who has this link can sign a computer in to your server. Send it only to yourself.";

    /// <summary><c>serve</c>'s exit code when its port is taken: try another.</summary>
    internal const int ExitPortInUse = 98;

    private const string ServedFile = "tailscale_url";
    private const string RenamedFile = "tailscale_renamed_from";

    private readonly object _gate = new();
    private readonly string _executable;
    private Sidecar? _server;

    /// <summary>The port this app's server had last time (<see cref="StartAsync"/>).</summary>
    private int? _earlier;
    private Timer? _timer;
    private Task? _refreshing;
    private TailscaleStatus? _status;
    private string? _served;
    private string? _enableHttps;
    private string? _error;
    private bool _taken;

    /// <summary><c>tailscale serve</c> was run since <see cref="StartAsync"/>: <see cref="StopAsync"/> takes back what it published.</summary>
    private bool _serveRan;

    /// <param name="dataDir">The server's data (app support <c>pocketterm-server/</c>).</param>
    /// <param name="recheck">How often Tailscale is looked at again while it isn't serving (10 s); <see cref="TimeSpan.Zero"/>: only when asked.</param>
    /// <param name="recheckReady">The same once it is (1 min): it may sign out, or the computer get another name.</param>
    /// <param name="relay">The push relay; the publisher's by default.</param>
    /// <param name="relayKey">The relay's X25519 public key; the publisher's relay's by default.</param>
    /// <param name="executable">The sidecar: <c>pocketterm-server.exe</c> next to the app on Windows, <c>pocketterm-server</c> elsewhere.</param>
    public BuiltInServer(
        string dataDir,
        Tailscale tailscale,
        TimeSpan? recheck = null,
        TimeSpan? recheckReady = null,
        string? relay = null,
        byte[]? relayKey = null,
        string? executable = null)
    {
        DataDir = dataDir;
        Tailscale = tailscale;
        Recheck = recheck ?? TimeSpan.FromSeconds(10);
        RecheckReady = recheckReady ?? TimeSpan.FromMinutes(1);
        Relay = relay;
        RelayKey = relayKey;
        _executable = executable ?? DefaultExecutable;
    }

    /// <summary>The bundled sidecar next to the app.</summary>
    public static string DefaultExecutable =>
        Path.Combine(AppContext.BaseDirectory, OperatingSystem.IsWindows() ? "pocketterm-server.exe" : "pocketterm-server");

    /// <summary>The server's data (app support <c>pocketterm-server/</c>).</summary>
    public string DataDir { get; }

    public Tailscale Tailscale { get; }

    public TimeSpan Recheck { get; }

    public TimeSpan RecheckReady { get; }

    public string? Relay { get; }

    public byte[]? RelayKey { get; }

    /// <summary>Running (between <see cref="StartAsync"/> and <see cref="StopAsync"/>).</summary>
    public bool Running
    {
        get
        {
            lock (_gate) return _server != null;
        }
    }

    /// <summary>The port it listens on, on 127.0.0.1. Throws while it isn't running.</summary>
    public int Port
    {
        get
        {
            lock (_gate) return _server?.Port ?? throw new InvalidOperationException("The built-in server isn't running.");
        }
    }

    /// <summary>How this computer reaches it: <c>http://127.0.0.1:&lt;port&gt;</c>.</summary>
    public Backend Backend => new($"http://127.0.0.1:{Port}");

    /// <summary>What Tailscale said last; null before the first look.</summary>
    public TailscaleStatus? TailscaleStatus
    {
        get
        {
            lock (_gate) return _status;
        }
    }

    /// <summary>Where phones and other computers reach it, while Tailscale serves it.</summary>
    public string? PublicUrl
    {
        get
        {
            lock (_gate) return _served;
        }
    }

    /// <summary>The tailnet's page that turns HTTPS on, when <c>tailscale serve</c> asked for it.</summary>
    public string? EnableHttps
    {
        get
        {
            lock (_gate) return _enableHttps;
        }
    }

    /// <summary>Turn on HTTPS…: <see cref="EnableHttps"/>, else the admin console's DNS page.</summary>
    public string HttpsPage => EnableHttps ?? Tailscale.AdminDns;

    /// <summary>What <c>tailscale serve</c> said when it failed otherwise.</summary>
    public string? Error
    {
        get
        {
            lock (_gate) return _error;
        }
    }

    /// <summary>The sidecar's process id while it runs (tests: it's gone after a stop).</summary>
    internal int? ProcessId
    {
        get
        {
            lock (_gate) return _server?.Process.Id;
        }
    }

    /// <summary>
    /// This computer's address before Tailscale gave it another one (the computer was renamed, or Tailscale
    /// signed in to another tailnet): phones and computers set up with it can't reach this one any more. Kept until
    /// <see cref="RenameSeen"/>.
    /// </summary>
    public string? RenamedFrom
    {
        get
        {
            var path = Path.Combine(DataDir, RenamedFile);
            string text;
            try
            {
                if (!File.Exists(path)) return null;
                text = File.ReadAllText(path).DartTrim();
            }
            catch (IOException)
            {
                return null;
            }
            var old = DartUri.TryParse(text);
            return old == null || old.Host.Length == 0 ? null : text;
        }
    }

    /// <summary>The person has seen <see cref="RenamedFrom"/>: it goes.</summary>
    public void RenameSeen()
    {
        var path = Path.Combine(DataDir, RenamedFile);
        try
        {
            File.Delete(path);
        }
        catch (IOException e)
        {
            Log.Print($"PocketTerm: Tailscale address not kept: {e.Message}");
        }
        NotifyChanged();
    }

    /// <summary>
    /// Tailscale serves it at <paramref name="url"/> now; another address before means a rename. Renamed again
    /// before that was seen, the first address stays: it's the one the phones have.
    /// </summary>
    private void ServedAt(string url)
    {
        try
        {
            var served = Path.Combine(DataDir, ServedFile);
            var renamed = Path.Combine(DataDir, RenamedFile);
            var before = File.Exists(served) ? File.ReadAllText(served).DartTrim() : "";
            if (before.Length > 0 && before != url && RenamedFrom == null) File.WriteAllText(renamed, before);
            // Back at the old name: nothing changed for the phones after all.
            if (RenamedFrom == url) File.Delete(renamed);
            File.WriteAllText(served, url);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Print($"PocketTerm: Tailscale address not kept: {e.Message}");
        }
    }

    public HostState State
    {
        get
        {
            lock (_gate) return StateLocked();
        }
    }

    private HostState StateLocked()
    {
        var s = _status;
        if (s == null) return HostState.Checking;
        return s.State switch
        {
            TailscaleState.Missing => HostState.NoTailscale,
            TailscaleState.Stopped => HostState.TailscaleOff,
            TailscaleState.LoggedOut => HostState.LoggedOut,
            _ when _served != null => HostState.Ready,
            _ when _taken => HostState.Taken,
            _ when _error != null => HostState.Failed,
            _ => HostState.HttpsOff,
        };
    }

    /// <summary>Where it stands, in a line, with what to do about it: install or open Tailscale, turn HTTPS on, look again.</summary>
    public HostStatus Status
    {
        get
        {
            HostState state;
            string? error, served;
            lock (_gate)
            {
                state = StateLocked();
                error = _error;
                served = _served;
            }
            (string Text, bool? Ok, HostAction[] Actions) line = state switch
            {
                HostState.Checking => ("Looking for Tailscale…", null, []),
                HostState.NoTailscale => ("Tailscale isn’t installed. Your phone reaches this computer through it.", false, [HostAction.InstallTailscale]),
                HostState.TailscaleOff => ("Tailscale isn’t running. Open it and switch it on.", false, [HostAction.OpenTailscale, HostAction.CheckAgain]),
                HostState.LoggedOut => ("Tailscale is signed out. Open it and sign in.", false, [HostAction.OpenTailscale, HostAction.CheckAgain]),
                HostState.HttpsOff => (
                    "HTTPS is off for your tailnet. Turn it on, so your phone gets a secure address for this computer.",
                    false,
                    [HostAction.TurnOnHttps, HostAction.CheckAgain]),
                HostState.Failed => ($"Tailscale didn’t publish the server: {error}", false, [HostAction.CheckAgain]),
                HostState.Taken => (error ?? "", false, [HostAction.CheckAgain]),
                _ => ($"Tailscale serves it to your own devices at {served}", true, []),
            };
            string? renamed = null;
            if (state == HostState.Ready && RenamedFrom is { } old)
            {
                renamed = $"This computer’s Tailscale address changed from {DartUri.Parse(old).Host}. Phones and computers set up " +
                    "with the old one can’t reach it: scan this computer’s code again on each phone (Add a " +
                    "phone…), and paste a new link on each other computer (Add a computer…).";
            }
            return new HostStatus(line.Text, line.Ok, line.Actions, renamed);
        }
    }

    /// <summary>
    /// Starts listening on 127.0.0.1:<paramref name="port"/>, or the next free port above it (up to 20 more),
    /// then has Tailscale publish it. <paramref name="earlier"/>: the port this app's server listened on last time,
    /// whose Serve entry is this app's to move; null on a first start (an entry there is someone else's).
    /// </summary>
    public async Task StartAsync(int port = 47900, int? earlier = null)
    {
        lock (_gate)
        {
            if (_server != null) return;
            _earlier = earlier;
        }
        Directory.CreateDirectory(DataDir);
        Sidecar? started = null;
        for (var p = port; p < port + 20 && started == null; p++)
        {
            started = await Sidecar.StartAsync(_executable, ServeArguments(p)).ConfigureAwait(false);
        }
        if (started == null) throw new BuiltInServerException("No free port for the server.");
        lock (_gate)
        {
            if (_server != null)
            {
                // Another start won meanwhile.
                _ = started.StopAsync();
                return;
            }
            _server = started;
        }
        NotifyChanged();
        // Tailscale may take a while (serve waits up to 30 seconds); the server works on 127.0.0.1 meanwhile.
        RefreshInBackground();
    }

    private List<string> ServeArguments(int port)
    {
        var args = new List<string>
        {
            "serve", "--data", DataDir, "--address", "127.0.0.1", "--port", $"{port}",
            // tailscale serve forwards from 127.0.0.1 with the tailnet caller in X-Forwarded-For: each gets its
            // own redeem throttle instead of one shared by everyone.
            "--trust-loopback-proxy",
            // The server stops when the app does, however it ends.
            "--exit-with-stdin",
        };
        if (Relay != null) args.AddRange(["--relay", Relay]);
        if (RelayKey != null) args.AddRange(["--relay-key", Convert.ToBase64String(RelayKey)]);
        return args;
    }

    /// <summary>
    /// Looks at Tailscale again and has it publish the server when it can (again when this computer's name
    /// changed). A call while one runs waits for that one.
    /// </summary>
    public Task RefreshAsync()
    {
        lock (_gate) return _refreshing ??= RefreshOnce();
    }

    private async Task RefreshOnce()
    {
        // Lets RefreshAsync keep this task before it can finish.
        await Task.Yield();
        try
        {
            await DoRefresh().ConfigureAwait(false);
        }
        finally
        {
            lock (_gate) _refreshing = null;
        }
    }

    private void RefreshInBackground() => _ = RefreshAsync().ContinueWith(
        t => Log.Print($"PocketTerm: looking at Tailscale failed: {t.Exception?.InnerException?.Message}"),
        CancellationToken.None,
        TaskContinuationOptions.OnlyOnFaulted,
        TaskScheduler.Default);

    private async Task DoRefresh()
    {
        Sidecar? server;
        lock (_gate) server = _server;
        if (server == null) return;
        var status = await Tailscale.StatusAsync().ConfigureAwait(false);
        string? url;
        bool serve;
        lock (_gate)
        {
            if (_server != server) return;
            _status = status;
            url = status.Url;
            if (status.State != TailscaleState.Running || url == null)
            {
                _served = null;
                _enableHttps = null;
                _error = null;
                _taken = false;
                serve = false;
                url = null;
            }
            else
            {
                serve = _served != url;
            }
        }
        if (url != null)
        {
            if (!serve)
            {
                var now = await Tailscale.Port443Async(new HashSet<int> { server.Port }).ConfigureAwait(false);
                lock (_gate)
                {
                    if (_server != server) return;
                    switch (now)
                    {
                        case ServingElsewhere elsewhere:
                            // Something else took port 443 since: it stays, and phones can't reach this one.
                            _served = null;
                            _error = ServeResult.TakenBy(elsewhere.What).Error;
                            _taken = true;
                            break;
                        case ServingNothing:
                            // This app's entry went (tailscale serve reset, say): Tailscale publishes it again.
                            serve = true;
                            break;
                    }
                }
            }
            if (serve)
            {
                int? earlier;
                lock (_gate)
                {
                    _serveRan = true;
                    earlier = _earlier;
                }
                var result = await Tailscale.ServeAsync(server.Port, earlier).ConfigureAwait(false);
                lock (_gate)
                {
                    if (_server != server) return;
                    _served = result.Ok ? url : null;
                    _enableHttps = result.EnableLink;
                    _error = result.Error;
                    _taken = result.Taken != null;
                }
                if (result.Ok) ServedAt(url);
            }
        }
        Schedule(server);
        NotifyChanged();
    }

    private void Schedule(Sidecar server)
    {
        lock (_gate)
        {
            _timer?.Dispose();
            _timer = null;
            if (_server != server) return;
            var every = StateLocked() == HostState.Ready ? RecheckReady : Recheck;
            if (every > TimeSpan.Zero) _timer = new Timer(_ => RefreshInBackground(), null, every, Timeout.InfiniteTimeSpan);
        }
    }

    /// <summary>
    /// Stops publishing it on the tailnet and stops it. A look at Tailscale under way ends first, so what its
    /// <c>tailscale serve</c> published goes too.
    /// </summary>
    public async Task StopAsync()
    {
        Sidecar? server;
        Task? refreshing;
        lock (_gate)
        {
            _timer?.Dispose();
            _timer = null;
            server = _server;
            if (server == null) return;
            _server = null;
            refreshing = _refreshing;
        }
        if (refreshing != null)
        {
            try
            {
                await refreshing.ConfigureAwait(false);
            }
            catch (Exception)
            {
                // Its failure was the look's; stopping goes on.
            }
        }
        bool served;
        lock (_gate)
        {
            served = _serveRan;
            _serveRan = false;
            _served = null;
            _status = null;
            _enableHttps = null;
            _error = null;
            _taken = false;
        }
        await Task.WhenAll(served ? Tailscale.UnserveAsync(server.Port) : Task.CompletedTask, server.StopAsync()).ConfigureAwait(false);
        NotifyChanged();
    }

    /// <summary>
    /// The link another computer sets up with ("Add a computer…"): the Tailscale address and the server's setup
    /// token. Null until Tailscale serves it. (Dart's was synchronous: the server ran in-process; here the
    /// sidecar's <c>setup-link</c> makes it.)
    /// </summary>
    public async Task<string?> SetupLinkAsync()
    {
        var served = PublicUrl;
        return served == null ? null : await SetupLinkForAsync(served).ConfigureAwait(false);
    }

    /// <summary>The same for this computer itself, on 127.0.0.1.</summary>
    public Task<string> OwnSetupLinkAsync() => SetupLinkForAsync(Backend.Url);

    /// <summary><c>pocketterm-server setup-link --data &lt;dataDir&gt; --public-url &lt;publicUrl&gt;</c>: the link it prints.</summary>
    private async Task<string> SetupLinkForAsync(string publicUrl)
    {
        var psi = new ProcessStartInfo(_executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in new[] { "setup-link", "--data", DataDir, "--public-url", publicUrl }) psi.ArgumentList.Add(a);
        using var process = Start(psi);
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync().ConfigureAwait(false);
        var output = await stdout.ConfigureAwait(false);
        var errors = await stderr.ConfigureAwait(false);
        var link = output.Split('\n').Select(l => l.Trim()).FirstOrDefault(l => l.StartsWith("pocketterm://", StringComparison.Ordinal));
        if (process.ExitCode != 0 || link == null)
        {
            throw new BuiltInServerException($"The built-in server made no setup link (exit code {process.ExitCode}): {errors.Trim()}");
        }
        return link;
    }

    private static Process Start(ProcessStartInfo psi)
    {
        try
        {
            return Process.Start(psi) ?? throw new BuiltInServerException($"The built-in server didn’t start: {psi.FileName}");
        }
        catch (Win32Exception e)
        {
            throw new BuiltInServerException($"The built-in server didn’t start: {psi.FileName}: {e.Message}");
        }
    }

    /// <summary>Stops looking at Tailscale, and the sidecar with it when it still runs (it can't outlive this).</summary>
    public void Dispose()
    {
        Sidecar? server;
        lock (_gate)
        {
            _timer?.Dispose();
            _timer = null;
            server = _server;
            _server = null;
        }
        server?.Stop(TimeSpan.FromSeconds(2));
    }

    /// <summary>One run of <c>pocketterm-server serve</c>.</summary>
    private sealed class Sidecar
    {
        private readonly object _stderrGate = new();
        private readonly Queue<string> _stderr = new();
        /// <summary>Windows: the Job Object that kills it with the app (<see cref="JobObject"/>).</summary>
        private readonly IDisposable? _job;
        private volatile bool _stopping;

        private Sidecar(Process process, IDisposable? job)
        {
            Process = process;
            _job = job;
        }

        public Process Process { get; }

        public int Port { get; private set; }

        /// <summary>
        /// Starts it on <paramref name="args"/> and waits for its listening line (30 seconds at most); null when
        /// it exited <see cref="ExitPortInUse"/>: the port is taken.
        /// </summary>
        public static async Task<Sidecar?> StartAsync(string executable, IReadOnlyList<string> args)
        {
            var psi = new ProcessStartInfo(executable)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            // The server inherits this process's environment, POCKETTERM_SENTRY_DSN/_ENVIRONMENT/_RELEASE included
            // (it reads the same names): the operator's error-report setting (ErrorReports) covers it too. Don't
            // clear psi.Environment.
            foreach (var a in args) psi.ArgumentList.Add(a);
            var process = Start(psi);
            JobObject? job = null;
            if (OperatingSystem.IsWindows())
            {
                try
                {
                    job = JobObject.Create();
                    job.Assign(process);
                }
                catch (Win32Exception e)
                {
                    // Closing its stdin still stops it with the app.
                    job?.Dispose();
                    job = null;
                    Log.Print($"PocketTerm: the built-in server isn't tied to the app: {e.Message}");
                }
            }
            var sidecar = new Sidecar(process, job);
            process.ErrorDataReceived += (_, e) => sidecar.Logged(e.Data);
            process.BeginErrorReadLine();
            int? port = null;
            using (var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30)))
            {
                try
                {
                    while (port == null && await process.StandardOutput.ReadLineAsync(cts.Token).ConfigureAwait(false) is { } line)
                    {
                        if (DartJson.TryDecodeObject(line) is { } o && o.Str("event") == "listening") port = (int?)o.Int("port");
                    }
                }
                catch (OperationCanceledException)
                {
                    sidecar.Stop(TimeSpan.Zero);
                    throw new BuiltInServerException($"The built-in server didn’t start in time: {sidecar.LastLog()}");
                }
            }
            if (port == null)
            {
                // Its stdout ended: it exited.
                await process.WaitForExitAsync().ConfigureAwait(false);
                var code = process.ExitCode;
                var log = sidecar.LastLog();
                sidecar.Stop(TimeSpan.Zero);
                if (code == ExitPortInUse) return null;
                throw new BuiltInServerException($"The built-in server didn’t start (exit code {code}): {log}");
            }
            sidecar.Port = port.Value;
            // Keep reading stdout so the server never blocks on a full pipe (it says nothing more).
            _ = Task.Run(async () =>
            {
                try
                {
                    while (await process.StandardOutput.ReadLineAsync().ConfigureAwait(false) != null)
                    {
                    }
                }
                catch (Exception)
                {
                    // Gone.
                }
            });
            process.EnableRaisingEvents = true;
            process.Exited += (_, _) =>
            {
                if (!sidecar._stopping) Log.Print("PocketTerm: the built-in server stopped by itself.");
            };
            return sidecar;
        }

        private void Logged(string? line)
        {
            if (line == null) return;
            Log.Print($"PocketTerm server: {line}");
            lock (_stderrGate)
            {
                _stderr.Enqueue(line);
                while (_stderr.Count > 5) _stderr.Dequeue();
            }
        }

        private string LastLog()
        {
            lock (_stderrGate) return string.Join("\n", _stderr).Trim();
        }

        /// <summary>Closes its stdin, so it stops and frees the data folder; killed when it hasn't within 5 seconds.</summary>
        public async Task StopAsync()
        {
            _stopping = true;
            CloseInput();
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            try
            {
                await Process.WaitForExitAsync(cts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                Kill();
                await Process.WaitForExitAsync().ConfigureAwait(false);
            }
            Release();
        }

        /// <summary><see cref="StopAsync"/> without waiting longer than <paramref name="wait"/>.</summary>
        public void Stop(TimeSpan wait)
        {
            _stopping = true;
            CloseInput();
            if (!Process.WaitForExit(wait))
            {
                Kill();
                Process.WaitForExit(TimeSpan.FromSeconds(5));
            }
            Release();
        }

        private void CloseInput()
        {
            try
            {
                Process.StandardInput.Close();
            }
            catch (Exception e) when (e is IOException or InvalidOperationException or ObjectDisposedException)
            {
                // Gone already.
            }
        }

        private void Kill()
        {
            try
            {
                Process.Kill(entireProcessTree: true);
            }
            catch (Exception e) when (e is InvalidOperationException or Win32Exception)
            {
                // Gone already.
            }
        }

        private void Release()
        {
            _job?.Dispose();
            Process.Dispose();
        }
    }
}
