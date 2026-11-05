using System.Text;
using System.Text.Json.Nodes;
using PocketTerm.Core;
using PocketTerm.Core.Tests;

namespace PocketTerm.Desktop.Tests;

/// <summary>tool/vectors/vectors.json against the local API: the ping proof, and the live frames of
/// <c>live.frames.local</c> replayed by a fake extension over both transports.</summary>
public sealed class LocalApiVectorTests : IAsyncLifetime
{
    private readonly LiveTemp _tmp = new("pocketterm-vectors");
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

    public static IEnumerable<object[]> PingCases() =>
        Vectors.Section("localApiPing").Arr("cases")!.Select(c => new object[] { c!.AsObject().Str("note")! });

    private static JsonObject PingCase(string note) =>
        Vectors.Section("localApiPing").Arr("cases")!.Select(c => c!.AsObject()).Single(c => c.Str("note") == note);

    [Theory]
    [MemberData(nameof(PingCases))]
    public async Task Ping_proof_and_nonce_bounds(string note)
    {
        var c = PingCase(note);
        var nonce = c.Str("nonce")!;
        Assert.Equal(c.Str("proof"), LocalApi.PingProof(c.Str("token")!, (int)c.Int("port")!, nonce));

        using var client = new HttpClient(new SocketsHttpHandler { UseProxy = false });
        using var res = await client.GetAsync($"http://127.0.0.1:{_api.Port}/v1/ping?nonce={Uri.EscapeDataString(nonce)}");
        var body = DartJson.TryDecodeObject(await res.Content.ReadAsStringAsync())!;
        if (c.Bool("nonceAccepted") == true)
        {
            Assert.Equal(200, (int)res.StatusCode);
            Vectors.AssertJson(new JsonObject { ["app"] = "pocketterm", ["proof"] = LocalApi.PingProof(_token, _api.Port!.Value, nonce) }, body);
        }
        else
        {
            Assert.Equal(400, (int)res.StatusCode);
            Assert.Equal("nonce: 16 to 128 characters.", body.Str("error"));
        }
    }

    // ------------------------------------------------------------ the live frames

    private static JsonObject Local(string note) =>
        Vectors.Section("live").Obj("frames")!.Arr("local")!.Select(f => f!.AsObject()).Single(f => f.Str("note") == note);

    /// <summary>The frame of vector <paramref name="note"/>, a copy to change.</summary>
    private static JsonObject F(string note) => Local(note).Obj("frame")!.DeepClone().AsObject();

    private static JsonNode? Parsed(string note, string field) => Local(note).Obj("parsed")![field];

    /// <summary><paramref name="actual"/> is vector <paramref name="note"/>'s frame, field for field in its order, but
    /// for <c>req</c> (the vectors name requests <c>q1</c>…, the hub counts them).</summary>
    private static void AssertFrame(string note, JsonObject actual, params string[] except)
    {
        var expected = F(note);
        Assert.Equal(expected.Select(p => p.Key), actual.Select(p => p.Key));
        foreach (var (k, v) in expected)
        {
            if (k == "req") Assert.NotNull(DartJson.AsInt(actual["req"]));
            else if (!except.Contains(k)) Vectors.AssertJson(v, actual[k], k);
        }
    }

    /// <summary>A reply frame of vector <paramref name="note"/> answering <paramref name="request"/>.</summary>
    private static JsonObject ReplyTo(string note, JsonObject request)
    {
        var r = F(note);
        r["req"] = request["req"]!.DeepClone();
        return r;
    }

    /// <summary>An extension's side of a transport.</summary>
    private interface IExt
    {
        Task Send(JsonObject frame);

        Task<JsonObject> Next();
    }

    private sealed class SocketExt(LiveExt ext) : IExt
    {
        public Task Send(JsonObject frame)
        {
            ext.Send(frame);
            return Task.CompletedTask;
        }

        public Task<JsonObject> Next() => ext.Request();
    }

    /// <summary>The Claude Code plugin's way: frames posted, the hub's picked up from each answer, long polls for more.</summary>
    private sealed class PollExt(int port, string token) : IExt
    {
        private readonly Queue<JsonObject> _inbox = new();
        public string? Conn { get; private set; }

        public async Task<int> Post(JsonArray frames, bool wait = false, bool close = false)
        {
            var body = new JsonObject();
            if (Conn != null) body["conn"] = Conn;
            body["frames"] = frames;
            if (wait) body["wait"] = true;
            if (close) body["close"] = true;
            using var client = new HttpClient(new SocketsHttpHandler { UseProxy = false });
            using var req = new HttpRequestMessage(HttpMethod.Post, $"http://127.0.0.1:{port}/v1/live/http")
            {
                Content = new StringContent(DartJson.Encode(body), Encoding.UTF8, "application/json"),
            };
            req.Headers.TryAddWithoutValidation("authorization", $"Bearer {token}");
            using var res = await client.SendAsync(req);
            var answer = DartJson.TryDecodeObject(await res.Content.ReadAsStringAsync())!;
            if ((int)res.StatusCode != 200) return (int)res.StatusCode;
            Conn = answer.Str("conn");
            foreach (var f in answer.Arr("frames")!) _inbox.Enqueue(f!.DeepClone().AsObject());
            return 200;
        }

        public async Task Send(JsonObject frame) => Assert.Equal(200, await Post(new JsonArray(frame)));

        public async Task<JsonObject> Next()
        {
            var end = DateTime.UtcNow.AddSeconds(30);
            while (_inbox.Count == 0 && DateTime.UtcNow < end) Assert.Equal(200, await Post([], wait: true));
            return _inbox.Dequeue();
        }
    }

    /// <summary>The <c>local</c> frames in a session's life: a hello registers it, a prompt sent while it works waits in
    /// its queue and goes to the extension when the run ends, and the rest as Dart's hub does it.</summary>
    private async Task Replay(IExt ext)
    {
        const string key = "kitty-1/7";
        var events = new List<LiveEvent>();
        _hub.Events += e =>
        {
            lock (events) events.Add(e);
        };
        var ops = new List<LiveOp>();
        _hub.Ops += e =>
        {
            lock (ops) ops.AddRange(e.Ops);
        };
        int Count<T>(List<T> l)
        {
            lock (l) return l.Count;
        }
        static JsonArray Commands(LiveSession s) =>
            new(s.Commands.Select(c => (JsonNode?)new JsonObject { ["name"] = c.Name, ["description"] = c.Description }).ToArray());

        await ext.Send(F("hello on connect"));
        await Wait.Until(() => _hub[key] != null);
        var s = _hub[key]!;
        Assert.Equal(Agent.Omp, s.Agent);
        Assert.Equal("personal", s.Profile);
        Assert.Equal(("s1", "Fix bug", "/Users/me/Dev/pocketterm", "m"), (s.Id, s.Title, s.Cwd, s.Model));
        Assert.Equal((12L, 0.42), (s.Ctx, s.Cost));
        Assert.Equal("hi", s.Preview);
        Assert.False(s.Busy);
        Vectors.AssertJson(Parsed("hello on connect", "commands"), Commands(s));

        await ext.Send(F("meta"));
        await Wait.Until(() => s.Title == "Fix missing playable sources");
        Assert.Equal(("opus", 40L, 43.34), (s.Model, s.Ctx, s.Cost));
        Vectors.AssertJson(Parsed("meta", "commands"), Commands(s));

        await ext.Send(F("item"));
        await ext.Send(F("append"));
        await Wait.Until(() => Count(ops) == 2);
        Assert.Equal("a", ops[0].Item!.Id);
        Assert.Equal(("a", "Hel"), (ops[1].Id, ops[1].Append));
        Assert.Equal("Hel", s.Log.Items.Single().Text);

        await ext.Send(F("busy start"));
        await Wait.Until(() => s.Busy);
        // A prompt sent to wait while it works goes to its queue.
        var prompt = F("prompt");
        var image = prompt.Arr("images")![0]!.AsObject();
        var queued = await _hub.PromptAsync(key, prompt.Str("text")!, [(Convert.FromBase64String(image.Str("data")!), image.Str("mimeType")!)], followUp: true);
        Assert.NotNull(queued);
        var q = s.Summary.Queue.Single();
        Assert.Equal((queued, "go on", 1L), (q.Id, q.Text, q.Images));

        // The run ends: it goes now, and nothing finished.
        await ext.Send(F("busy end with summary"));
        var handed = await ext.Next();
        AssertFrame("prompt", handed);
        Assert.True(s.Busy, "working from the hand-off on");
        Assert.Empty(s.Summary.Queue);
        await ext.Send(ReplyTo("reply ok", handed));
        await ext.Send(F("busy start"));
        await ext.Send(F("busy end with summary"));
        await Wait.Until(() => Count(events) == 1);
        Assert.Equal("All done", Assert.IsType<LiveFinished>(events[0]).Summary);

        await ext.Send(F("busy end, stopped"));
        await ext.Send(F("busy end, failed"));
        await Wait.Until(() => s.Failed);

        await ext.Send(F("ask"));
        await Wait.Until(() => Count(events) == 2);
        Vectors.AssertJson(Parsed("ask", "ask"), Assert.IsType<LiveAsked>(events[1]).Ask.ToJson());
        await ext.Send(F("ask cleared"));
        await Wait.Until(() => s.Ask == null);
        await ext.Send(F("plan ask"));
        await Wait.Until(() => s.Ask?.IsPlan ?? false);
        Vectors.AssertJson(Parsed("plan ask", "ask"), s.Ask!.ToJson());

        var aborting = _hub.AbortAsync(key);
        var abort = await ext.Next();
        AssertFrame("abort", abort);
        await ext.Send(ReplyTo("reply error", abort));
        Assert.Equal("Nothing to stop.", (await Assert.ThrowsAsync<LiveException>(() => aborting)).Message);

        // Said hello again (/new) with older items to fetch.
        var again = F("hello on connect");
        again["older"] = true;
        await ext.Send(again);
        await Wait.Until(() => s.Log.Older);
        var older = _hub.OlderAsync(key, 50);
        var asked = await ext.Next();
        AssertFrame("older", asked);
        await ext.Send(ReplyTo("reply with older items", asked));
        await older;
        Assert.Equal(["o", "a"], s.Log.Items.Select(i => i.Id));
        Assert.True(s.Log.Older);

        // Not the orchestrator: its call is refused.
        await ext.Send(F("orchestrator call"));
        var result = await ext.Next();
        AssertFrame("call error", result, "id", "error");
        Assert.Equal("c1", result.Str("id"));
        Assert.Equal("Only the PocketTerm orchestrator can do that.", result.Str("error"));
    }

    [Fact]
    public async Task The_local_frames_over_the_WebSocket()
    {
        await using var ws = await LiveExt.Connect($"ws://127.0.0.1:{_api.Port}/v1/live", _token);
        await Replay(new SocketExt(ws));
        await ws.CloseAsync();
        await Wait.Until(() => _hub.Sessions.Count == 0);
    }

    [Fact]
    public async Task The_local_frames_over_HTTP_long_polls()
    {
        var ext = new PollExt(_api.Port!.Value, _token);
        await Replay(ext);

        // Claude Code on its own connection: images as files, files as docs, both named in the text.
        var claude = new PollExt(_api.Port!.Value, _token);
        var hello = F("hello on connect");
        hello["agent"] = "claude";
        hello["window"] = "kitty-1/8";
        await claude.Send(hello);
        await Wait.Until(() => _hub["kitty-1/8"]?.Agent == Agent.Claude);
        var png = Convert.FromBase64String(F("prompt").Arr("images")![0]!.AsObject().Str("data")!);
        var sending = _hub.PromptAsync("kitty-1/8", "see", [(png, "image/png")], [new PromptFile("a.pdf", "application/pdf", "%PDF"u8.ToArray())]);
        var frame = await claude.Next();
        AssertFrame("prompt with files and docs (Claude Code)", frame, "text", "files", "docs", "deliver");
        var doc = DartJson.AsString(frame.Arr("docs")!.Single())!;
        Assert.Equal("a.pdf", Path.GetFileName(doc));
        Assert.Equal($"see\n\n{PromptFiles.FileMention(doc)}", frame.Str("text"));
        Assert.Equal(png, File.ReadAllBytes(DartJson.AsString(frame.Arr("files")!.Single())!));
        Assert.Equal("followUp", frame.Str("deliver"));
        await claude.Send(ReplyTo("reply ok", frame));
        Assert.Null(await sending);

        // Quitting closes the connection, and the session goes.
        Assert.Equal(200, await ext.Post([], close: true));
        Assert.Equal(200, await claude.Post([], close: true));
        await Wait.Until(() => _hub.Sessions.Count == 0);
    }
}
