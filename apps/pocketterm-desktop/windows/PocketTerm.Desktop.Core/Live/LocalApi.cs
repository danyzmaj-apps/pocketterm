using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using KestrelServer = Microsoft.AspNetCore.Hosting.Server.IServer;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using PocketTerm.Core;
using static PocketTerm.Desktop.LiveCasts;
using IOFile = System.IO.File;

namespace PocketTerm.Desktop;

/// <summary>
/// The terminal's way in (the live sessions of omp and Claude Code): HTTP on 127.0.0.1 at a random port, guarded by
/// a random token. Both are written to <c>~/.config/pocketterm/cli.json</c> (<c>%USERPROFILE%\.config\pocketterm\cli.json</c>
/// on Windows; mode 600 elsewhere; <c>POCKETTERM_CLI_JSON</c> names another file in a test build) for the clients to
/// read, and taken out again when PocketTerm quits.
/// <code>
///   GET   /v1/ping?nonce=N   → {"app": "pocketterm", "proof"}: no token; proof is PingProof, so a client knows it's
///                              this PocketTerm before its token goes anywhere
///   GET   /v1/ping           → {"app": "pocketterm", "pid"}: this PocketTerm is up
///   GET   /v1/live           WebSocket: a coding session reporting itself (omp's integrations/omp/pocketterm-live.ts, LiveHub)
///   POST  /v1/live/http      {conn?, frames, wait?, close?} → {conn, frames}: the same over HTTP long polls (the Claude Code plugin)
/// </code>
/// The orchestrator's folder (<see cref="LiveHub.OrchestratorDir"/>) is <c>orchestrator</c> beside <see cref="File"/>: a
/// session started there may call on the hub (<see cref="Orchestrator"/>). Kestrel serves requests on pool threads;
/// the hub has its own lock, the connections here are in concurrent maps.
/// </summary>
public sealed class LocalApi
{
    /// <param name="live">The hub the sessions go to.</param>
    /// <param name="file">Where the port and token go; by default cli.json as above.</param>
    /// <param name="windows">Windows' rules for <paramref name="file"/> (no chmod; the per-user profile keeps it
    /// private), else the running platform's.</param>
    public LocalApi(LiveHub live, string? file = null, bool? windows = null)
    {
        _live = live;
        File = file ?? DefaultFile(windows);
        _ownFolder = file == null && !Named(TestHooks.Env());
        _windows = windows ?? OperatingSystem.IsWindows();
        _live.OrchestratorDir = Path.Combine(Parent(File), "orchestrator");
    }

    private readonly LiveHub _live;
    private WebApplication? _app;
    private readonly string _token = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();

    /// <summary>What this app wrote to <see cref="File"/>.</summary>
    private string? _written;
    private CancellationTokenSource? _watch;
    private volatile bool _stopping;

    /// <summary>How often <see cref="File"/> is checked for another PocketTerm having taken it over.</summary>
    private static readonly TimeSpan WatchEvery = TimeSpan.FromSeconds(5);

    /// <summary>HTTP long-poll connections (/v1/live/http) by id.</summary>
    private readonly ConcurrentDictionary<string, PollLink> _polls = new();

    /// <summary>The live sessions' WebSockets (/v1/live), open now.</summary>
    private readonly ConcurrentDictionary<SocketLink, byte> _sockets = new();

    /// <summary>How long a long poll waits for frames from the hub.</summary>
    public static readonly TimeSpan PollHold = TimeSpan.FromSeconds(25);

    /// <summary>Where the port and token go: <c>~/.config/pocketterm/cli.json</c>, or the file <c>POCKETTERM_CLI_JSON</c> names.</summary>
    public string File { get; }

    /// <summary><see cref="File"/>'s folder is PocketTerm's own <c>~/.config/pocketterm</c>, kept private (700). One
    /// <c>POCKETTERM_CLI_JSON</c> names (a home folder, a project) keeps its mode.</summary>
    private readonly bool _ownFolder;

    private readonly bool _windows;

    private static bool Named(IReadOnlyDictionary<string, string> env) => env.GetValueOrDefault("POCKETTERM_CLI_JSON") is { Length: > 0 };

    private static string DefaultFile(bool? windows)
    {
        var hooks = TestHooks.Env();
        return Named(hooks)
            ? hooks["POCKETTERM_CLI_JSON"]
            : Path.Combine(Terminal.HomeDir(null, windows), ".config", "pocketterm", "cli.json");
    }

    private static string Parent(string path) => Path.GetDirectoryName(path) is { Length: > 0 } d ? d : ".";

    /// <summary>The port it listens on, once started.</summary>
    public int? Port { get; private set; }

    /// <summary>
    /// What /v1/ping?nonce= answers: HMAC-SHA256 under <paramref name="token"/> of the <paramref name="port"/> asked
    /// and the client's <paramref name="nonce"/>, in hex. Only the PocketTerm that wrote cli.json can make it, and only
    /// for its own port: whatever else listens there (after PocketTerm quit, say) can't, nor pass on a real PocketTerm's.
    /// </summary>
    public static string PingProof(string token, int port, string nonce) =>
        Convert.ToHexString(HMACSHA256.HashData(
            Encoding.UTF8.GetBytes(token),
            Encoding.UTF8.GetBytes($"pocketterm-ping\n{port.ToString(CultureInfo.InvariantCulture)}\n{nonce}"))).ToLowerInvariant();

    public async Task StartAsync()
    {
        var builder = WebApplication.CreateEmptyBuilder(new WebApplicationOptions());
        builder.Services.AddLogging();
        builder.WebHost.UseKestrelCore().ConfigureKestrel(o =>
        {
            o.AddServerHeader = false;
            o.Listen(IPAddress.Loopback, 0);
        });
        var app = builder.Build();
        app.UseWebSockets(new WebSocketOptions { KeepAliveInterval = TimeSpan.Zero });
        app.Run(ctx => ctx.Request.Path.Value switch
        {
            "/v1/live" => UpgradeAsync(ctx),
            "/v1/live/http" => PollAsync(ctx),
            _ => HandleAsync(ctx),
        });
        await app.StartAsync();
        _app = app;
        var address = app.Services.GetRequiredService<KestrelServer>().Features.Get<IServerAddressesFeature>()!.Addresses.First();
        Port = new Uri(address).Port;
        _written = DartJson.Encode(new JsonObject { ["port"] = Port, ["token"] = _token, ["pid"] = Environment.ProcessId });
        await WriteAsync();
        _watch = new CancellationTokenSource();
        _ = WatchAsync(_watch.Token);
    }

    /// <summary>
    /// Stops listening, ends the live sessions' connections and takes <see cref="File"/> back out, unless another
    /// PocketTerm has it now. Runs when PocketTerm quits.
    /// </summary>
    public async Task StopAsync()
    {
        _stopping = true;
        _watch?.Cancel();
        foreach (var ws in _sockets.Keys.ToList())
        {
            // Not waiting for the agent's side of the close: quitting can't.
            _ = ws.CloseAsync(WebSocketCloseStatus.EndpointUnavailable);
        }
        foreach (var p in _polls.Values.ToList()) await p.CloseAsync();
        if (_app is { } app)
        {
            _app = null;
            using var cut = new CancellationTokenSource(TimeSpan.FromSeconds(1));
            try
            {
                await app.StopAsync(cut.Token);
            }
            catch (OperationCanceledException)
            {
                // Connections still open after a moment are cut.
            }
            await app.DisposeAsync();
        }
        try
        {
            if (_written != null && IOFile.Exists(File) && await IOFile.ReadAllTextAsync(File) == _written) IOFile.Delete(File);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Print($"PocketTerm: {File} not removed: {e.Message}");
        }
    }

    /// <summary>Writes <see cref="_written"/> to <see cref="File"/> as a whole (a reader never sees half of it), private
    /// before the token goes in: a chmod that fails stops it. Windows has no chmod; the file is as private as the
    /// user's profile it's in.</summary>
    private async Task WriteAsync()
    {
        var f = File;
        var dir = Parent(f);
        Directory.CreateDirectory(dir);
        if (_ownFolder && !_windows && !OperatingSystem.IsWindows())
        {
            IOFile.SetUnixFileMode(dir, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
        var tmp = $"{f}.{Environment.ProcessId.ToString(CultureInfo.InvariantCulture)}.tmp";
        await IOFile.WriteAllTextAsync(tmp, "");
        try
        {
            if (!_windows && !OperatingSystem.IsWindows()) IOFile.SetUnixFileMode(tmp, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            await using (var s = new FileStream(tmp, FileMode.Truncate, FileAccess.Write, FileShare.None))
            {
                await s.WriteAsync(Encoding.UTF8.GetBytes(_written!));
                s.Flush(flushToDisk: true);
            }
            // Over one that exists, on Windows too.
            IOFile.Move(tmp, f, overwrite: true);
        }
        catch
        {
            if (IOFile.Exists(tmp)) IOFile.Delete(tmp);
            throw;
        }
    }

    private async Task WatchAsync(CancellationToken stop)
    {
        using var timer = new PeriodicTimer(WatchEvery);
        try
        {
            while (await timer.WaitForNextTickAsync(stop)) await ReclaimAsync();
        }
        catch (OperationCanceledException)
        {
            // Stopped.
        }
    }

    /// <summary>Another PocketTerm (a debug build, say) took <see cref="File"/> over and has quit or died since,
    /// leaving the terminal pointed at nothing: this one's address goes back.</summary>
    private async Task ReclaimAsync()
    {
        var f = File;
        string? text;
        try
        {
            text = IOFile.Exists(f) ? await IOFile.ReadAllTextAsync(f) : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            text = null;
        }
        if (!await ShouldReclaimAsync(text, _written!, AnswersAsync) || _stopping) return;
        Log.Print($"PocketTerm: {f} named no running PocketTerm; writing this one back");
        try
        {
            await WriteAsync();
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: {f} not written: {e.Message}");
        }
    }

    /// <summary>Whether cli.json as it reads now (<paramref name="text"/>, null when missing) should give way to
    /// <paramref name="ours"/>: it's gone or unreadable, or names a PocketTerm that doesn't <paramref name="answers"/>
    /// at its port with its token anymore.</summary>
    public static async Task<bool> ShouldReclaimAsync(string? text, string ours, Func<int, string, Task<bool>> answers)
    {
        if (text == ours) return false;
        JsonNode? json;
        try
        {
            json = DartJson.Decode(text ?? "");
        }
        catch (JsonException)
        {
            return true;
        }
        if (json is not JsonObject m || DartJson.AsInt(m["port"]) is not { } port || DartJson.AsString(m["token"]) is not { } token) return true;
        // A port no socket can have: nothing answers there.
        if (port is < 0 or > 65535) return true;
        return !await answers((int)port, token);
    }

    /// <summary>The PocketTerm that holds <paramref name="token"/> answers /v1/ping at <paramref name="port"/>: it
    /// proves it (<see cref="PingProof"/>) without the token being sent.</summary>
    public static async Task<bool> AnswersAsync(int port, string token)
    {
        var nonce = NewId();
        using var handler = new SocketsHttpHandler { ConnectTimeout = TimeSpan.FromSeconds(2), UseProxy = false };
        using var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        try
        {
            using var headers = new CancellationTokenSource(TimeSpan.FromSeconds(4));
            using var res = await client.GetAsync($"http://127.0.0.1:{port.ToString(CultureInfo.InvariantCulture)}/v1/ping?nonce={nonce}", HttpCompletionOption.ResponseHeadersRead, headers.Token);
            using var body = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            var json = DartJson.Decode(await res.Content.ReadAsStringAsync(body.Token));
            return res.StatusCode == HttpStatusCode.OK && json is JsonObject m && DartJson.AsString(m["proof"]) == PingProof(token, port, nonce);
        }
        catch (Exception)
        {
            return false;
        }
    }

    private bool Authorized(HttpContext ctx)
    {
        var auth = ctx.Request.Headers.Authorization;
        return auth.Count == 1 && auth[0] == $"Bearer {_token}";
    }

    private async Task UpgradeAsync(HttpContext ctx)
    {
        if (!Authorized(ctx) || !ctx.WebSockets.IsWebSocketRequest)
        {
            ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
            return;
        }
        var link = new SocketLink(await ctx.WebSockets.AcceptWebSocketAsync());
        _sockets[link] = 0;
        try
        {
            await _live.AcceptAsync(link.Frames(), link);
        }
        finally
        {
            _sockets.TryRemove(link, out _);
            await link.CloseAsync();
        }
    }

    /// <summary>One long poll: the extension's frames go to its connection in order, and the answer carries the hub's,
    /// waiting <see cref="PollHold"/> for some when asked to. A request without a connection opens one.</summary>
    private async Task PollAsync(HttpContext ctx)
    {
        var res = ctx.Response;
        res.ContentType = "application/json; charset=utf-8";
        var status = StatusCodes.Status200OK;
        string? answer = null;
        try
        {
            if (!HttpMethods.IsPost(ctx.Request.Method))
            {
                status = StatusCodes.Status405MethodNotAllowed;
            }
            else if (!Authorized(ctx))
            {
                status = StatusCodes.Status403Forbidden;
                answer = Error("Bad token.");
            }
            else
            {
                var body = DartJson.Decode(await BodyOfAsync(ctx.Request)) as JsonObject
                    ?? throw new InvalidCastException("The body is not a JSON object.");
                var id = OptStr(body, "conn");
                PollLink? link;
                if (id == null)
                {
                    link = new PollLink(NewId(), gone => _polls.TryRemove(gone, out _));
                    _polls[link.Id] = link;
                    _ = _live.AcceptAsync(link.Frames, link);
                }
                else
                {
                    _polls.TryGetValue(id, out link);
                }
                List<string>? out_ = null;
                if (link != null)
                {
                    var frames = (OptList(body, "frames") ?? []).Select(DartJson.Encode).ToList();
                    out_ = await link.ExchangeAsync(frames, IsTrue(body["wait"]) ? PollHold : null);
                    // The agent is quitting: its session ends now.
                    if (IsTrue(body["close"])) await link.CloseAsync();
                }
                if (out_ == null)
                {
                    status = StatusCodes.Status404NotFound;
                    answer = Error("No such connection: say hello again.");
                }
                else
                {
                    // The hub's frames are JSON already.
                    answer = $"{{\"conn\":{DartJson.Encode(JsonValue.Create(link!.Id))},\"frames\":[{string.Join(",", out_)}]}}";
                }
            }
        }
        catch (TooLargeException)
        {
            status = StatusCodes.Status413PayloadTooLarge;
            answer = Error($"Request over {MaxBody / (1024 * 1024)} MiB.");
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: live poll: {e.Message}");
            status = StatusCodes.Status400BadRequest;
            answer = Error($"Bad request: {e.Message}");
        }
        try
        {
            res.StatusCode = status;
            if (answer != null) await res.WriteAsync(answer);
        }
        catch (Exception e)
        {
            // The extension gave up on a long poll.
            Log.Print($"PocketTerm: live poll: {e.Message}");
        }
    }

    private static string Error(string message) => DartJson.Encode(new JsonObject { ["error"] = message });

    /// <summary>The most a long poll's body may hold; more is refused (413) unread.</summary>
    public const int MaxBody = 8 * 1024 * 1024;

    /// <summary><paramref name="req"/>'s body as UTF-8, <see cref="TooLargeException"/> past <see cref="MaxBody"/>.</summary>
    private static async Task<string> BodyOfAsync(HttpRequest req)
    {
        if (req.ContentLength > MaxBody) throw new TooLargeException();
        using var bytes = new MemoryStream();
        var chunk = new byte[64 * 1024];
        int n;
        while ((n = await req.Body.ReadAsync(chunk)) > 0)
        {
            if (bytes.Length + n > MaxBody) throw new TooLargeException();
            bytes.Write(chunk, 0, n);
        }
        return DartString.StrictUtf8.GetString(bytes.GetBuffer(), 0, (int)bytes.Length);
    }

    private static string NewId() => Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();

    private async Task HandleAsync(HttpContext ctx)
    {
        var res = ctx.Response;
        res.ContentType = "application/json; charset=utf-8";
        int status;
        JsonObject body;
        try
        {
            (status, body) = Route(ctx);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: API error: {e.Message}");
            (status, body) = (400, new JsonObject { ["error"] = $"Bad request: {e.Message}" });
        }
        res.StatusCode = status;
        await res.WriteAsync(DartJson.Encode(body));
    }

    private (int, JsonObject) Route(HttpContext ctx)
    {
        var path = PathSegments(ctx.Request.Path.Value ?? "");
        var ping = HttpMethods.IsGet(ctx.Request.Method) && path.Length == 2 && path[0] == "v1" && path[1] == "ping";
        // Dart's queryParameters of the raw query: decoded, the last of a repeated name kept; a bad escape throws.
        var query = DartUri.Parse($"http://127.0.0.1/{ctx.Request.QueryString.Value}").QueryParameters;
        // Before the token: a client asks this way whether to send it here.
        if (ping && query.TryGetValue("nonce", out var nonce))
        {
            if (nonce.Length < 16 || nonce.Length > 128) return (400, new JsonObject { ["error"] = "nonce: 16 to 128 characters." });
            return (200, new JsonObject { ["app"] = "pocketterm", ["proof"] = PingProof(_token, Port!.Value, nonce) });
        }
        if (!Authorized(ctx)) return (403, new JsonObject { ["error"] = "Bad token." });
        if (ping) return (200, new JsonObject { ["app"] = "pocketterm", ["pid"] = Environment.ProcessId });
        return (404, new JsonObject { ["error"] = "Not found." });
    }

    /// <summary>Dart's <c>Uri.pathSegments</c>: <c>/v1/ping</c> is <c>[v1, ping]</c>, <c>/v1/ping/</c> has an empty third.</summary>
    private static string[] PathSegments(string path)
    {
        var p = path.StartsWith('/') ? path[1..] : path;
        return p.Length == 0 ? [] : p.Split('/');
    }

    /// <summary>A long poll's body over <see cref="MaxBody"/>.</summary>
    private sealed class TooLargeException : Exception
    {
    }
}

/// <summary>
/// One extension on the HTTP long-poll transport (/v1/live/http): its frames go to the hub in the order they came,
/// and the hub's wait here for its next request. Gone, and its session with it, after <see cref="Idle"/> without one.
/// Requests come on pool threads: its state is under its own lock.
/// </summary>
internal sealed class PollLink : LiveLink
{
    public PollLink(string id, Action<string> gone)
    {
        Id = id;
        _gone = gone;
        _idleTimer = new Timer(_ => IdleOut(), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
        lock (_lock) StartIdle();
    }

    public string Id { get; }
    private readonly Action<string> _gone;
    public static readonly TimeSpan Idle = TimeSpan.FromSeconds(60);

    private readonly object _lock = new();
    private readonly Channel<string> _in = Channel.CreateUnbounded<string>(new UnboundedChannelOptions { SingleReader = true });
    private readonly List<string> _out = [];
    private TaskCompletionSource? _waiting;
    private readonly Timer _idleTimer;

    /// <summary>When the idle wait on now ends (<see cref="Environment.TickCount64"/>): a timer that fires for an
    /// older one finds it later.</summary>
    private long _idleUntil = long.MaxValue;
    private int _active;
    private bool _closed;

    /// <summary>The extension's frames, for <see cref="LiveHub.AcceptAsync"/>.</summary>
    public IAsyncEnumerable<string> Frames => _in.Reader.ReadAllAsync();

    public void Send(string frame)
    {
        lock (_lock)
        {
            if (_closed) return;
            _out.Add(frame);
            Wake();
        }
    }

    private void Wake()
    {
        var w = _waiting;
        _waiting = null;
        w?.TrySetResult();
    }

    private void StartIdle()
    {
        _idleUntil = Environment.TickCount64 + (long)Idle.TotalMilliseconds;
        _idleTimer.Change(Idle, Timeout.InfiniteTimeSpan);
    }

    private void StopIdle()
    {
        _idleUntil = long.MaxValue;
        _idleTimer.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    private void IdleOut()
    {
        lock (_lock)
        {
            // A request came meanwhile, or one is under way.
            if (_closed || _active > 0 || _idleUntil == long.MaxValue) return;
            var left = _idleUntil - Environment.TickCount64;
            if (left > 0)
            {
                // Fired for an older wait, or a tick early: this one ends later.
                _idleTimer.Change(TimeSpan.FromMilliseconds(left), Timeout.InfiniteTimeSpan);
                return;
            }
        }
        _ = CloseAsync();
    }

    public Task CloseAsync()
    {
        lock (_lock)
        {
            if (_closed) return Task.CompletedTask;
            _closed = true;
            StopIdle();
            Wake();
        }
        _idleTimer.Dispose();
        _gone(Id);
        _in.Writer.TryComplete();
        return Task.CompletedTask;
    }

    /// <summary>One request: <paramref name="frames"/> in, then the hub's out, waiting up to <paramref name="hold"/>
    /// for some when there are none yet (a newer wait ends an older one). Null once closed.</summary>
    public async Task<List<string>?> ExchangeAsync(IReadOnlyList<string> frames, TimeSpan? hold)
    {
        TaskCompletionSource? wait = null;
        lock (_lock)
        {
            if (_closed) return null;
            _active++;
            StopIdle();
            foreach (var f in frames) _in.Writer.TryWrite(f);
            if (_out.Count == 0 && hold != null)
            {
                Wake();
                wait = _waiting = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            }
        }
        try
        {
            if (wait != null)
            {
                try
                {
                    await wait.Task.WaitAsync(hold!.Value);
                }
                catch (TimeoutException)
                {
                    // Nothing came: an empty answer.
                }
            }
            lock (_lock)
            {
                var out_ = _out.ToList();
                _out.Clear();
                return out_;
            }
        }
        finally
        {
            lock (_lock)
            {
                if (--_active == 0 && !_closed) StartIdle();
            }
        }
    }
}
