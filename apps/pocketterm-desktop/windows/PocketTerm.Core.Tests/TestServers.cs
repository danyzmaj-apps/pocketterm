using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace PocketTerm.Core.Tests;

/// <summary>A test that talks to the real Dart server: runs only with <c>POCKETTERM_INTEROP=1</c>.</summary>
public sealed class InteropFactAttribute : FactAttribute
{
    public InteropFactAttribute()
    {
        if (!DartServer.Enabled) Skip = "Set POCKETTERM_INTEROP=1 to run against the real Dart server.";
    }
}

/// <summary>Polls until a condition holds (Dart tests' <c>until</c>).</summary>
internal static class Wait
{
    public static async Task Until(Func<bool> check, int seconds = 5)
    {
        var end = DateTime.UtcNow.AddSeconds(seconds);
        while (!check() && DateTime.UtcNow < end) await Task.Delay(10);
        Assert.True(check(), "condition not met in time");
    }
}

/// <summary>A Kestrel server on loopback answering every request with a handler: the Dart tests' HttpServer.bind.</summary>
internal sealed class FakeHttp : IAsyncDisposable
{
    private readonly WebApplication _app;

    private FakeHttp(WebApplication app, int port)
    {
        _app = app;
        Port = port;
    }

    public int Port { get; }

    public string Url => $"http://127.0.0.1:{Port}";

    public static async Task<FakeHttp> Start(RequestDelegate handler, int port = 0)
    {
        var builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.UseKestrel(o => o.Listen(IPAddress.Loopback, port));
        var app = builder.Build();
        app.UseWebSockets(new WebSocketOptions { KeepAliveInterval = TimeSpan.Zero });
        app.Run(handler);
        await app.StartAsync();
        var address = app.Services.GetRequiredService<Microsoft.AspNetCore.Hosting.Server.IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.First();
        return new FakeHttp(app, new Uri(address).Port);
    }

    /// <summary>Stops listening; connections under way are cut after a moment.</summary>
    public async Task Stop()
    {
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(200));
        try
        {
            await _app.StopAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
        }
    }

    public async ValueTask DisposeAsync()
    {
        await Stop();
        await _app.DisposeAsync();
    }
}

/// <summary>
/// The real PocketTerm server (apps/pocketterm-server, Dart) on loopback in a temporary data directory, as the
/// desktop apps run it: <c>serve --data … --address 127.0.0.1 --port 0 --exit-with-stdin</c>, its port from the
/// <c>{"event":"listening"}</c> line, setup links from <c>setup-link</c>. Compiled once per test run with
/// <c>fvm dart compile exe</c> (or <c>POCKETTERM_SERVER_BIN</c>). With a fake push relay that records what reaches it.
/// </summary>
internal sealed class DartServer : IAsyncDisposable
{
    public static bool Enabled => Environment.GetEnvironmentVariable("POCKETTERM_INTEROP") == "1";

    private static readonly SemaphoreSlim BuildLock = new(1, 1);
    private static string? _binary;

    private readonly Process _process;
    private readonly string _dir;
    private readonly FakeHttp _relay;

    private DartServer(Process process, string dir, FakeHttp relay, int port)
    {
        _process = process;
        _dir = dir;
        _relay = relay;
        Port = port;
    }

    public int Port { get; }

    /// <summary>What reached the push relay, in order.</summary>
    public List<JsonObject> Relayed { get; } = [];

    public Backend Backend => new($"http://127.0.0.1:{Port}");

    private static async Task<string> Binary()
    {
        if (Environment.GetEnvironmentVariable("POCKETTERM_SERVER_BIN") is { Length: > 0 } given) return given;
        await BuildLock.WaitAsync();
        try
        {
            if (_binary != null) return _binary;
            var outDir = Path.Combine(Path.GetTempPath(), $"pocketterm-cs-tests-{Environment.ProcessId}");
            Directory.CreateDirectory(outDir);
            var exe = Path.Combine(outDir, RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "pocketterm-server.exe" : "pocketterm-server");
            var (code, output) = await Run("fvm", ["dart", "compile", "exe", "apps/pocketterm-server/bin/pocketterm_server.dart", "-o", exe], Vectors.RepoRoot);
            if (code != 0) throw new InvalidOperationException($"compiling the server failed:\n{output}");
            // One build per test run, gone with it.
            AppDomain.CurrentDomain.ProcessExit += (_, _) =>
            {
                try
                {
                    Directory.Delete(outDir, recursive: true);
                }
                catch (IOException)
                {
                }
            };
            return _binary = exe;
        }
        finally
        {
            BuildLock.Release();
        }
    }

    private static async Task<(int Code, string Output)> Run(string file, IEnumerable<string> args, string? cwd = null)
    {
        var psi = new ProcessStartInfo(file) { RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = cwd ?? "" };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        var stdout = p.StandardOutput.ReadToEndAsync();
        var stderr = p.StandardError.ReadToEndAsync();
        await p.WaitForExitAsync();
        return (p.ExitCode, await stdout + await stderr);
    }

    public static async Task<DartServer> Start()
    {
        var bin = await Binary();
        var dir = Directory.CreateTempSubdirectory("pocketterm_cs_server").FullName;
        DartServer? self = null;
        var relay = await FakeHttp.Start(async ctx =>
        {
            using var reader = new StreamReader(ctx.Request.Body, Encoding.UTF8);
            var body = await reader.ReadToEndAsync();
            lock (self!.Relayed) self.Relayed.Add((JsonObject)DartJson.Decode(body)!);
        });
        var psi = new ProcessStartInfo(bin)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var a in new[] { "serve", "--data", dir, "--address", "127.0.0.1", "--port", "0", "--exit-with-stdin", "--relay", $"{relay.Url}/relay" })
        {
            psi.ArgumentList.Add(a);
        }
        var process = Process.Start(psi)!;
        process.ErrorDataReceived += (_, _) => { };
        process.BeginErrorReadLine();
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        int port;
        while (true)
        {
            var line = await process.StandardOutput.ReadLineAsync(cts.Token) ?? throw new InvalidOperationException("the server exited before listening");
            if (DartJson.TryDecodeObject(line) is { } o && o.Str("event") == "listening")
            {
                port = (int)o.Int("port")!.Value;
                break;
            }
        }
        // Keep reading stdout so the server never blocks on a full pipe.
        _ = Task.Run(async () =>
        {
            while (await process.StandardOutput.ReadLineAsync() != null)
            {
            }
        });
        return self = new DartServer(process, dir, relay, port);
    }

    /// <summary>The server's setup link (<c>setup-link --data … --public-url …</c>).</summary>
    public async Task<string> SetupLink()
    {
        var (code, output) = await Run(await Binary(), ["setup-link", "--data", _dir, "--public-url", $"http://127.0.0.1:{Port}"]);
        Assert.Equal(0, code);
        return output.Split('\n').Select(l => l.Trim()).First(l => l.StartsWith("pocketterm://", StringComparison.Ordinal));
    }

    public async Task<string> SetupToken() => Backend.SetupToken(DartUri.Parse(await SetupLink()))!;

    public PocketTermServerClient Client(IDeviceTokens? tokens = null) => new(Backend, tokens ?? new MemoryDeviceTokens());

    /// <summary>A computer signed in with the setup token.</summary>
    public async Task<PocketTermServerClient> Desktop(string label = "MacBook Pro")
    {
        var c = Client();
        await c.RedeemSetup(await SetupToken(), label, "macos");
        return c;
    }

    /// <summary>A phone signed in with a code from <paramref name="desktop"/>.</summary>
    public async Task<PocketTermServerClient> Phone(IServer desktop, string label = "iPhone")
    {
        var c = Client();
        await c.RedeemCode(await desktop.CreatePairingCode(), label, "ios");
        return c;
    }

    /// <summary>Stops the server (its stdin closes, as when the app quits) but keeps its data.</summary>
    public async Task StopServer()
    {
        if (_process.HasExited) return;
        try
        {
            _process.StandardInput.Close();
        }
        catch (IOException)
        {
        }
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        try
        {
            await _process.WaitForExitAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            _process.Kill(entireProcessTree: true);
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopServer();
        _process.Dispose();
        await _relay.DisposeAsync();
        try
        {
            Directory.Delete(_dir, recursive: true);
        }
        catch (IOException)
        {
        }
    }
}

/// <summary>A raw TCP server on loopback (the Dart tests' ServerSocket.bind).</summary>
internal sealed class RawServer : IDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _stop = new();

    public RawServer(Func<TcpClient, Task> onConnection)
    {
        _listener.Start();
        _ = Task.Run(async () =>
        {
            while (!_stop.IsCancellationRequested)
            {
                TcpClient c;
                try
                {
                    c = await _listener.AcceptTcpClientAsync(_stop.Token);
                }
                catch (Exception)
                {
                    return;
                }
                _ = Task.Run(() => onConnection(c));
            }
        });
    }

    public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

    public Backend Backend => new($"http://127.0.0.1:{Port}");

    public void Dispose()
    {
        _stop.Cancel();
        _listener.Stop();
    }
}
