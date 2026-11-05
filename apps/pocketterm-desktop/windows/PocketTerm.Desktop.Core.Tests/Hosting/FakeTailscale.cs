using System.Text.Json.Nodes;
using System.Threading.Channels;
using PocketTerm.Core;

namespace PocketTerm.Desktop.Tests;

/// <summary>
/// Tailscale's CLI as a test sets it up, recording every command in <see cref="Calls"/> (without the CLI's path).
/// Not installed by default. A Mac's on any computer: Open Tailscale runs <c>open -a Tailscale</c>.
/// </summary>
internal sealed class FakeTailscale
{
    public const string EnableLink = "https://login.tailscale.com/f/serve?node=nTEST123";

    private readonly object _gate = new();
    private readonly List<string> _calls = [];
    private JsonObject _serveConfig = new();

    public FakeTailscale(bool installed = false, bool https = true, string backendState = "Running")
    {
        Installed = installed;
        Https = https;
        BackendState = backendState;
        Tailscale = new Tailscale(StartAsync, () => Installed ? "/fake/bin/tailscale" : null, windows: false);
    }

    public bool Installed { get; set; }

    /// <summary>The Tailscale service runs (else the CLI can't reach it).</summary>
    public bool Daemon { get; set; } = true;

    public string BackendState { get; set; }

    public string DnsName { get; set; } = "mac.tail1234.ts.net";

    /// <summary>HTTPS certificates (and Serve) are on for the tailnet.</summary>
    public bool Https { get; set; }

    /// <summary><c>tailscale serve status</c> fails (exits non-zero) while set.</summary>
    public bool StatusFails { get; set; }

    /// <summary><c>tailscale serve --bg</c> waits for this before it publishes, when set.</summary>
    public TaskCompletionSource? ServeGate { get; set; }

    /// <summary><c>serve</c> processes still running (one that asks for HTTPS waits until killed).</summary>
    public List<FakeTailscaleProcess> Running { get; } = [];

    public Tailscale Tailscale { get; }

    /// <summary>Every command so far.</summary>
    public List<string> Calls
    {
        get
        {
            lock (_gate) return [.. _calls];
        }
    }

    /// <summary>What <c>tailscale serve status --json</c> prints: <c>serve --bg</c> sets it, <c>serve --https=443 off</c> clears it.</summary>
    public JsonObject ServeConfig
    {
        get
        {
            lock (_gate) return (JsonObject)_serveConfig.DeepClone();
        }
        set
        {
            lock (_gate) _serveConfig = value;
        }
    }

    /// <summary>Serve publishing <paramref name="proxy"/> on 443, as <c>tailscale serve --bg &lt;proxy&gt;</c> leaves it.</summary>
    public void Serving(string proxy) => ServeConfig = new JsonObject
    {
        ["TCP"] = new JsonObject { ["443"] = new JsonObject { ["HTTPS"] = true } },
        ["Web"] = new JsonObject
        {
            [$"{DnsName}:443"] = new JsonObject
            {
                ["Handlers"] = new JsonObject { ["/"] = new JsonObject { ["Proxy"] = proxy } },
            },
        },
    };

    private async Task<ITailscaleProcess> StartAsync(string exe, IReadOnlyList<string> args)
    {
        lock (_gate) _calls.Add(string.Join(' ', args));
        var first = args.Count > 0 ? args[0] : null;
        if (first == "status")
        {
            if (!Daemon) return FakeTailscaleProcess.Done(1, err: "failed to connect to local Tailscale service; is Tailscale running?\n");
            return FakeTailscaleProcess.Done(0, output: DartJson.Encode(new JsonObject
            {
                ["BackendState"] = BackendState,
                ["Self"] = new JsonObject { ["DNSName"] = $"{DnsName}.", ["TailscaleIPs"] = new JsonArray("100.101.102.103") },
                ["CertDomains"] = Https ? new JsonArray(DnsName) : null,
            }));
        }
        if (args.Count >= 2 && first == "serve" && args[1] == "status")
        {
            if (StatusFails) return FakeTailscaleProcess.Done(1, err: "failed to connect to local Tailscale service\n");
            var config = ServeConfig;
            return FakeTailscaleProcess.Done(0, output: config.Count == 0 ? "null\n" : DartJson.Encode(config));
        }
        if (first == "serve" && args[^1] != "off" && !Https)
        {
            // What the CLI prints, then it waits for HTTPS to be turned on.
            var p = FakeTailscaleProcess.Waiting($"Serve is not enabled on your tailnet.\nTo enable, visit:\n\n         {EnableLink}\n\n");
            lock (_gate) Running.Add(p);
            return p;
        }
        if (first == "serve" && args[^1] != "off")
        {
            if (ServeGate is { } gate) await gate.Task;
            Serving(args[^1]);
            return FakeTailscaleProcess.Done(0, output: $"Available within your tailnet:\n\nhttps://{DnsName}/\n|-- proxy {args[^1]}\n");
        }
        if (first == "serve") ServeConfig = new JsonObject();
        return FakeTailscaleProcess.Done(0);
    }
}

/// <summary>A process that prints what it's given, then exits with its code, or keeps running until killed.</summary>
internal sealed class FakeTailscaleProcess : ITailscaleProcess
{
    private readonly Channel<string> _output = Channel.CreateUnbounded<string>();
    private readonly TaskCompletionSource<int> _exit = new(TaskCreationOptions.RunContinuationsAsynchronously);

    private FakeTailscaleProcess()
    {
    }

    public bool Killed { get; private set; }

    public ChannelReader<string> Output => _output.Reader;

    public Task<int> Exit => _exit.Task;

    public static FakeTailscaleProcess Done(int code, string output = "", string err = "")
    {
        var p = new FakeTailscaleProcess();
        p.Print(output, err);
        p.End(code);
        return p;
    }

    public static FakeTailscaleProcess Waiting(string output = "")
    {
        var p = new FakeTailscaleProcess();
        p.Print(output, "");
        return p;
    }

    private void Print(string output, string err)
    {
        if (output.Length > 0) _output.Writer.TryWrite(output);
        if (err.Length > 0) _output.Writer.TryWrite(err);
    }

    private void End(int code)
    {
        _output.Writer.TryComplete();
        _exit.TrySetResult(code);
    }

    public void Kill()
    {
        Killed = true;
        End(-15);
    }
}
