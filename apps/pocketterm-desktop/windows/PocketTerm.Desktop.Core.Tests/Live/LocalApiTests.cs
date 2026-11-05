using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using PocketTerm.Core;
using PocketTerm.Core.Tests;

namespace PocketTerm.Desktop.Tests;

/// <summary>A test of POSIX file modes: skipped on Windows, which has none.</summary>
file sealed class PosixFactAttribute : FactAttribute
{
    public PosixFactAttribute()
    {
        if (OperatingSystem.IsWindows()) Skip = "File modes are POSIX only.";
    }
}

/// <summary>apps/pocketterm-desktop/test/local_api_test.dart: cli.json ownership. Every LocalApi here writes to a
/// temporary folder, never ~/.config/pocketterm.</summary>
public sealed class LocalApiCliJsonTests : IDisposable
{
    private const string Ours = """{"port":5000,"token":"mine","pid":1}""";
    private readonly LiveTemp _tmp = new("pocketterm-cli");

    public void Dispose() => _tmp.Dispose();

    private LiveHub Hub() => new(files: new PromptFiles(_tmp["files"]), images: _tmp["images"]);

    private static Task<bool> Reclaim(string? text, bool running = false) =>
        LocalApi.ShouldReclaimAsync(text, Ours, (port, token) => Task.FromResult(running));

    private static string TokenOf(LocalApi api) => DartJson.TryDecodeObject(File.ReadAllText(api.File))!.Str("token")!;

    [Fact]
    public async Task Keeps_its_own_file_and_one_naming_another_running_PocketTerm()
    {
        Assert.False(await Reclaim(Ours));
        Assert.False(await Reclaim("""{"port":6000,"token":"other","pid":2}""", running: true));
    }

    [Fact]
    public async Task Takes_it_back_when_missing_unreadable_or_naming_a_PocketTerm_that_is_gone()
    {
        Assert.True(await Reclaim(null));
        Assert.True(await Reclaim("""{"port":"""));
        Assert.True(await Reclaim("""{"port":"6000"}"""));
        Assert.True(await Reclaim("""{"port":6000,"token":"other","pid":2}"""));
    }

    [Fact]
    public async Task A_running_PocketTerm_writes_its_address_back_after_another_one_overwrote_it()
    {
        var file = _tmp["cli.json"];
        var api = new LocalApi(Hub(), file);
        await api.StartAsync();
        try
        {
            var written = File.ReadAllText(file);
            Assert.Equal(api.Port, DartJson.TryDecodeObject(written)!.Int("port"));
            Assert.Equal(Environment.ProcessId, DartJson.TryDecodeObject(written)!.Int("pid"));
            if (!OperatingSystem.IsWindows()) Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(file));
            // A debug build that has quit since.
            File.WriteAllText(file, """{"port":1,"token":"dead","pid":999999}""");
            await Task.Delay(TimeSpan.FromSeconds(6));
            Assert.Equal(written, File.ReadAllText(file));
        }
        finally
        {
            await api.StopAsync();
        }
    }

    [Fact]
    public async Task PocketTerm_proves_it_is_the_one_at_its_port_without_the_token_being_sent()
    {
        var api = new LocalApi(Hub(), _tmp["cli.json"]);
        await api.StartAsync();
        var token = TokenOf(api);
        var port = api.Port!.Value;
        Assert.True(await LocalApi.AnswersAsync(port, token));
        // Some other server's token, or nobody at the port.
        Assert.False(await LocalApi.AnswersAsync(port, "not-its-token"));
        await api.StopAsync();
        Assert.False(await LocalApi.AnswersAsync(port, token));
    }

    [Fact]
    public void A_proof_is_good_for_one_port_only_so_a_stand_in_at_an_old_port_cannot_relay_it()
    {
        const string nonce = "0123456789abcdef";
        Assert.NotEqual(LocalApi.PingProof("t", 5000, nonce), LocalApi.PingProof("t", 5001, nonce));
        Assert.NotEqual(LocalApi.PingProof("t", 5000, nonce), LocalApi.PingProof("u", 5000, nonce));
    }

    [Fact]
    public async Task Stopping_takes_cli_json_out_unless_another_PocketTerm_wrote_it_since()
    {
        var file = _tmp["cli.json"];
        var api = new LocalApi(Hub(), file);
        await api.StartAsync();
        await api.StopAsync();
        Assert.False(File.Exists(file));

        var again = new LocalApi(Hub(), file);
        await again.StartAsync();
        File.WriteAllText(file, """{"port":6000,"token":"other","pid":2}""");
        await again.StopAsync();
        Assert.Contains("\"other\"", File.ReadAllText(file));
    }

    [Fact]
    public async Task Stopping_ends_the_live_sessions_on_WebSockets_too_the_agents_connect_again_to_the_next_PocketTerm()
    {
        var hub = Hub();
        var api = new LocalApi(hub, _tmp["cli.json"]);
        await api.StartAsync();
        await using var ext = await LiveExt.Connect($"ws://127.0.0.1:{api.Port}/v1/live", TokenOf(api));
        ext.Send((JsonObject)DartJson.Decode("""{"t":"hello","v":1,"agent":"omp","session":{"id":"s1","cwd":"/tmp"},"pid":7}""")!);
        await Wait.Until(() => hub.Sessions.Count > 0);
        await api.StopAsync();
        await ext.Closed.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(WebSocketCloseStatus.EndpointUnavailable, ext.Ws.CloseStatus);
        await Wait.Until(() => hub.Sessions.Count == 0);
    }

    [PosixFact]
    public async Task A_folder_POCKETTERM_CLI_JSON_names_keeps_its_mode_only_the_file_is_private()
    {
        if (OperatingSystem.IsWindows()) return;
        var open = UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute | UnixFileMode.GroupRead
            | UnixFileMode.GroupExecute | UnixFileMode.OtherRead | UnixFileMode.OtherExecute;
        File.SetUnixFileMode(_tmp.Path, open);
        var api = new LocalApi(Hub(), _tmp["pocketterm.json"]);
        await api.StartAsync();
        try
        {
            Assert.Equal(open, File.GetUnixFileMode(_tmp.Path));
            Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(api.File));
        }
        finally
        {
            await api.StopAsync();
        }
    }

    [Fact]
    public void The_default_file_is_cli_json_under_the_home_folder_and_the_orchestrator_folder_is_beside_it()
    {
        var hub = Hub();
        var api = new LocalApi(hub, windows: OperatingSystem.IsWindows());
        // A test build may be pointed elsewhere (POCKETTERM_CLI_JSON); otherwise it's the home folder's.
        var named = TestHooks.Env().GetValueOrDefault("POCKETTERM_CLI_JSON");
        Assert.Equal(
            named is { Length: > 0 } ? named : Path.Combine(Terminal.HomeDir(), ".config", "pocketterm", "cli.json"),
            api.File);
        Assert.Equal(Path.Combine(Path.GetDirectoryName(api.File)!, "orchestrator"), hub.OrchestratorDir);
    }
}

/// <summary>apps/pocketterm-desktop/test/local_api_test.dart: live sessions over HTTP long polls, and the routes.</summary>
public sealed class LocalApiPollTests : IAsyncLifetime
{
    private readonly LiveTemp _tmp = new("pocketterm-poll");
    private LiveHub _hub = null!;
    private LocalApi _api = null!;
    private string _token = "";

    public async Task InitializeAsync()
    {
        _hub = new LiveHub(files: new PromptFiles(_tmp["files"]), images: _tmp["images"]);
        _api = new LocalApi(_hub, _tmp["cli.json"]);
        await _api.StartAsync();
        _token = DartJson.TryDecodeObject(File.ReadAllText(_api.File))!.Str("token")!;
    }

    public async Task DisposeAsync()
    {
        await _api.StopAsync();
        _tmp.Dispose();
    }

    private async Task<(int Status, JsonObject Body)> Post(JsonObject body, string? auth = null)
    {
        using var client = new HttpClient(new SocketsHttpHandler { UseProxy = false });
        using var req = new HttpRequestMessage(HttpMethod.Post, $"http://127.0.0.1:{_api.Port}/v1/live/http")
        {
            Content = new StringContent(DartJson.Encode(body), Encoding.UTF8),
        };
        req.Headers.TryAddWithoutValidation("authorization", $"Bearer {auth ?? _token}");
        using var res = await client.SendAsync(req);
        return ((int)res.StatusCode, DartJson.TryDecodeObject(await res.Content.ReadAsStringAsync())!);
    }

    private static JsonObject Hello() => (JsonObject)DartJson.Decode("""
        {"t":"hello","v":1,"agent":"claude","session":{"id":"s1","title":"","cwd":"/work/repo","model":"m"},
         "window":"kitty-1/3","pid":"x","busy":false,"items":[],"older":false,"commands":[]}
        """)!;

    [Fact]
    public async Task A_hello_opens_a_session_the_computers_request_waits_in_the_next_poll_the_reply_answers_it()
    {
        var (status, opened) = await Post(new JsonObject { ["frames"] = new JsonArray(Hello()) });
        Assert.Equal(200, status);
        var conn = opened.Str("conn")!;
        await Wait.Until(() => _hub["kitty-1/3"] != null);
        Assert.Equal(Agent.Claude, _hub["kitty-1/3"]!.Agent);

        var poll = Post(new JsonObject { ["conn"] = conn, ["frames"] = new JsonArray(), ["wait"] = true });
        var prompted = _hub.PromptAsync("kitty-1/3", "hi");
        var (_, polled) = await poll;
        var frame = (JsonObject)polled.Arr("frames")!.Single()!;
        Assert.Equal("prompt", frame.Str("t"));
        Assert.Equal("followUp", frame.Str("deliver"));
        Assert.Empty(frame.Arr("files")!);
        await Post(new JsonObject
        {
            ["conn"] = conn,
            ["frames"] = new JsonArray(new JsonObject { ["t"] = "reply", ["req"] = frame["req"]!.DeepClone() }),
        });
        await prompted;
    }

    [Fact]
    public async Task Frames_from_an_unknown_connection_get_404_and_closing_ends_the_session()
    {
        var (status, _) = await Post(new JsonObject { ["conn"] = "nope", ["frames"] = new JsonArray() });
        Assert.Equal(404, status);
        var (_, opened) = await Post(new JsonObject { ["frames"] = new JsonArray(Hello()) });
        await Wait.Until(() => _hub["kitty-1/3"] != null);
        await Post(new JsonObject { ["conn"] = opened["conn"]!.DeepClone(), ["frames"] = new JsonArray(), ["close"] = true });
        await Wait.Until(() => _hub["kitty-1/3"] == null);
        var (after, body) = await Post(new JsonObject { ["conn"] = opened["conn"]!.DeepClone(), ["frames"] = new JsonArray() });
        Assert.Equal(404, after);
        Assert.Equal("No such connection: say hello again.", body.Str("error"));
    }

    [Fact]
    public async Task A_wrong_token_is_refused()
    {
        var (status, body) = await Post(new JsonObject { ["frames"] = new JsonArray(Hello()) }, auth: "wrong");
        Assert.Equal(403, status);
        Assert.Equal("Bad token.", body.Str("error"));
        Assert.Empty(_hub.Sessions);
    }

    /// <summary>One request on a socket of its own (headers as given, a WebSocket upgrade's included): its status.</summary>
    private async Task<int> Status(string method, string path, string? auth = null, string? body = null)
    {
        using var tcp = new TcpClient();
        await tcp.ConnectAsync(IPAddress.Loopback, _api.Port!.Value);
        var stream = tcp.GetStream();
        var head = new StringBuilder($"{method} {path} HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: {(path == "/v1/live" ? "Upgrade" : "close")}\r\n");
        if (auth != null) head.Append($"authorization: Bearer {auth}\r\n");
        if (path == "/v1/live")
        {
            head.Append("upgrade: websocket\r\nsec-websocket-version: 13\r\nsec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\n");
        }
        var bytes = body == null ? [] : Encoding.UTF8.GetBytes(body);
        head.Append($"content-length: {bytes.Length}\r\n\r\n");
        await stream.WriteAsync(Encoding.ASCII.GetBytes(head.ToString()));
        await stream.WriteAsync(bytes);
        using var reader = new StreamReader(stream, Encoding.ASCII);
        var line = await reader.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(5));
        return int.Parse(line!.Split(' ')[1]);
    }

    [Fact]
    public async Task Every_route_but_the_nonce_ping_wants_the_token_and_it_listens_on_loopback_only()
    {
        foreach (var (method, path) in new[] { ("GET", "/v1/ping"), ("GET", "/v1/nothing"), ("GET", "/v1/live"), ("POST", "/v1/live/http") })
        {
            foreach (var auth in new[] { null, "wrong" })
            {
                var status = await Status(method, path, auth, method == "GET" ? null : """{"title":"x"}""");
                Assert.True(status == 403, $"{method} {path} with {auth ?? "no"} token: {status}");
            }
        }
        Assert.Equal(200, await Status("GET", "/v1/ping?nonce=0123456789abcdef"));
        // With the token, anything but the live routes and the ping isn't there.
        Assert.Equal(200, await Status("GET", "/v1/ping", _token));
        Assert.Equal(404, await Status("GET", "/v1/nothing", _token));
        Assert.Equal(404, await Status("POST", "/v1/ideas", _token, """{"title":"x"}"""));
        Assert.Equal(405, await Status("GET", "/v1/live/http", _token));

        // Nothing listens on this computer's other addresses.
        var others = NetworkInterface.GetAllNetworkInterfaces()
            .SelectMany(i => i.GetIPProperties().UnicastAddresses)
            .Select(a => a.Address)
            .Where(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a))
            .ToList();
        foreach (var a in others)
        {
            using var tcp = new TcpClient();
            using var cut = new CancellationTokenSource(TimeSpan.FromSeconds(1));
            await Assert.ThrowsAnyAsync<Exception>(async () => await tcp.ConnectAsync(a, _api.Port!.Value, cut.Token));
        }
    }

    [Fact]
    public async Task The_ping_with_the_token_names_this_process()
    {
        using var client = new HttpClient(new SocketsHttpHandler { UseProxy = false });
        using var req = new HttpRequestMessage(HttpMethod.Get, $"http://127.0.0.1:{_api.Port}/v1/ping");
        req.Headers.TryAddWithoutValidation("authorization", $"Bearer {_token}");
        using var res = await client.SendAsync(req);
        Vectors.AssertJson(
            new JsonObject { ["app"] = "pocketterm", ["pid"] = Environment.ProcessId },
            DartJson.Decode(await res.Content.ReadAsStringAsync()));
        Assert.Equal("application/json; charset=utf-8", res.Content.Headers.ContentType?.ToString());
    }

    [Fact]
    public async Task A_request_whose_body_never_comes_holds_up_nobody_else()
    {
        // Headers promise a body that never arrives.
        using var stuck = new TcpClient();
        await stuck.ConnectAsync(IPAddress.Loopback, _api.Port!.Value);
        await stuck.GetStream().WriteAsync(Encoding.ASCII.GetBytes(
            $"POST /v1/live/http HTTP/1.1\r\nhost: 127.0.0.1\r\nauthorization: Bearer {_token}\r\n" +
            "content-type: application/json\r\ncontent-length: 1000000\r\n\r\n{\"frames\":"));
        var (status, _) = await Post(new JsonObject { ["frames"] = new JsonArray(Hello()) }).WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(200, status);
    }

    /// <summary>Content that doesn't say its length: it goes in chunks.</summary>
    private sealed class Chunked(byte[] bytes) : HttpContent
    {
        protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context)
        {
            for (var at = 0; at < bytes.Length; at += 64 * 1024) await stream.WriteAsync(bytes.AsMemory(at, Math.Min(64 * 1024, bytes.Length - at)));
        }

        protected override bool TryComputeLength(out long length)
        {
            length = 0;
            return false;
        }
    }

    private async Task<int> SendBig(bool sayLength)
    {
        var body = Hello();
        var big = DartJson.EncodeUtf8(new JsonObject { ["frames"] = new JsonArray(body), ["pad"] = new string('x', LocalApi.MaxBody) });
        using var client = new HttpClient(new SocketsHttpHandler { UseProxy = false });
        using var req = new HttpRequestMessage(HttpMethod.Post, $"http://127.0.0.1:{_api.Port}/v1/live/http")
        {
            Content = sayLength ? new ByteArrayContent(big) : new Chunked(big),
        };
        req.Headers.TryAddWithoutValidation("authorization", $"Bearer {_token}");
        try
        {
            using var res = await client.SendAsync(req);
            return (int)res.StatusCode;
        }
        catch (HttpRequestException)
        {
            // The server stopped reading and answered before all of it went.
            return 413;
        }
    }

    [Fact]
    public async Task A_body_over_the_cap_that_says_its_length_is_refused_with_413_and_opens_no_connection()
    {
        Assert.Equal(413, await SendBig(sayLength: true));
        Assert.Empty(_hub.Sessions);
    }

    [Fact]
    public async Task A_body_over_the_cap_sent_in_chunks_is_refused_with_413_and_opens_no_connection()
    {
        Assert.Equal(413, await SendBig(sayLength: false));
        Assert.Empty(_hub.Sessions);
    }
}
