using System.Net.WebSockets;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using PocketTerm.Core;

namespace PocketTerm.Desktop.Tests;

/// <summary>An extension's side of a /v1/live WebSocket (the Dart tests' <c>_Ext</c>): frames out in order, frames in
/// one by one with <see cref="Request"/>.</summary>
internal sealed class LiveExt : IAsyncDisposable
{
    private readonly Channel<JsonObject> _received = Channel.CreateUnbounded<JsonObject>();
    private readonly Task _reader;

    private LiveExt(ClientWebSocket ws)
    {
        Ws = ws;
        Link = new SocketLink(ws);
        _reader = Task.Run(async () =>
        {
            try
            {
                await foreach (var f in Link.Frames()) _received.Writer.TryWrite((JsonObject)DartJson.Decode(f)!);
            }
            catch (Exception)
            {
                // The hub's side went away.
            }
            _received.Writer.TryComplete();
        });
    }

    public ClientWebSocket Ws { get; }
    public SocketLink Link { get; }

    /// <summary>Done when the hub's side has closed.</summary>
    public Task Closed => _reader;

    public static async Task<LiveExt> Connect(string url, string? token = null)
    {
        var ws = new ClientWebSocket();
        if (token != null) ws.Options.SetRequestHeader("authorization", $"Bearer {token}");
        await ws.ConnectAsync(new Uri(url), CancellationToken.None);
        return new LiveExt(ws);
    }

    public void Send(JsonObject m) => Link.Send(DartJson.Encode(m));

    public void SendRaw(string frame) => Link.Send(frame);

    /// <summary>The hub's next frame.</summary>
    public async Task<JsonObject> Request() => await _received.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));

    public void Hello(string? window = "kitty-1/7", string id = "s1", JsonArray? items = null, JsonArray? commands = null) => Send(new JsonObject
    {
        ["t"] = "hello",
        ["v"] = 1,
        ["session"] = new JsonObject { ["id"] = id, ["title"] = "Fix bug", ["cwd"] = "/Users/me/Dev/pocketterm", ["model"] = "m" },
        ["window"] = window,
        ["pid"] = 42,
        ["busy"] = false,
        ["items"] = items ?? [],
        ["older"] = false,
        ["commands"] = commands ?? [],
    });

    /// <summary>Closes the extension's side, as an agent that quits.</summary>
    public async Task CloseAsync()
    {
        try
        {
            await Ws.CloseAsync(WebSocketCloseStatus.NormalClosure, null, CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(5));
        }
        catch (Exception)
        {
            Ws.Abort();
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Ws.State == WebSocketState.Open) await CloseAsync();
        Ws.Dispose();
    }
}

/// <summary>A folder of its own under the temp folder, deleted at the end.</summary>
internal sealed class LiveTemp : IDisposable
{
    public LiveTemp(string prefix = "pocketterm_live")
    {
        Path = Directory.CreateTempSubdirectory(prefix).FullName;
    }

    public string Path { get; }

    public string this[string name] => System.IO.Path.Combine(Path, name);

    public void Dispose()
    {
        try
        {
            Directory.Delete(Path, recursive: true);
        }
        catch (IOException)
        {
        }
    }
}
