using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading.Channels;

namespace PocketTerm.Core;

/// <summary>What a device is to its server.</summary>
public enum DeviceRole
{
    Desktop,
    Phone,
}

/// <summary>A computer or phone signed in to the server (packages/pocketterm_server/PROTOCOL.md, Device).</summary>
/// <param name="Id">16 characters, made by the server.</param>
/// <param name="Platform"><c>macos</c>, <c>windows</c>, <c>linux</c>, <c>ios</c> or <c>android</c>.</param>
/// <param name="Current">It's the device asking (GET /v1/devices).</param>
public sealed record Device(string Id, DeviceRole Role, string Label, string Platform, DateTimeOffset? SeenAt = null, bool Current = false)
{
    public static Device FromJson(JsonObject j) => new(
        j.Str("id") ?? throw new InvalidCastException("A device has an id."),
        j.Str("role") == "phone" ? DeviceRole.Phone : DeviceRole.Desktop,
        j.Str("label") ?? "",
        j.Str("platform") ?? "",
        DartDate.TryParse(j.Str("seen_at") ?? ""),
        DartJson.AsBool(j["current"]) == true);

    public JsonObject ToJson() => new()
    {
        ["id"] = Id,
        ["role"] = Role.Name(),
        ["label"] = Label,
        ["platform"] = Platform,
    };
}

/// <summary>This device, signed in to its server: what's kept per server is keyed on <see cref="Id"/>, the
/// server's own id, which never changes.</summary>
/// <param name="Id">The server's id (GET /v1/me).</param>
/// <param name="Device">This device, as the server knows it.</param>
public sealed record Account(string Id, Device Device);

/// <summary>Where a device keeps its sign-in (the device token and what came with it, one string): the Keychain or
/// a DPAPI-encrypted file in %APPDATA% on a computer, the phone's own secure storage.</summary>
public interface IDeviceTokens
{
    Task<string?> Read();

    /// <summary>Null forgets it.</summary>
    Task Write(string? value);
}

/// <summary>A sign-in that lasts as long as the app runs (tests, a computer's own built-in server).</summary>
public sealed class MemoryDeviceTokens : IDeviceTokens
{
    public string? Value { get; set; }

    public Task<string?> Read() => Task.FromResult(Value);

    public Task Write(string? value)
    {
        Value = value;
        return Task.CompletedTask;
    }
}

/// <summary>What the server answered instead (<c>{error, message}</c>), or that it couldn't be reached
/// (<see cref="Status"/> 0). <see cref="Exception.Message"/> is worded for the person.</summary>
public sealed class ServerException(int status, string code, string message) : Exception(message)
{
    public int Status { get; } = status;

    /// <summary>The server's <c>error</c> (<c>invalid_code</c>, <c>unauthorized</c>, …; <c>offline</c>).</summary>
    public string Code { get; } = code;

    public override string ToString() => Message;
}

/// <summary>
/// The live channel's connection, in the frames of PROTOCOL.md's WebSocket (<c>join</c>, <c>send</c>,
/// <c>leave</c>, <c>ping</c> out; <c>joined</c>, <c>msg</c>, <c>pong</c>, <c>error</c> in), whatever carries
/// them: the PocketTerm server's own WebSocket.
/// <see cref="CloseCode"/> 4003 once closed: this device was signed out.
/// </summary>
public interface ILiveSocket
{
    /// <summary>Each frame as it comes; completed when the connection is done.</summary>
    ChannelReader<string> Frames { get; }

    void Add(string frame);

    int? CloseCode { get; }

    Task Close(int code = 1000);
}

/// <summary>
/// Where this device is signed in (packages/pocketterm_server/PROTOCOL.md): signing in, pairing, the computers
/// list, images and push, and the live channel (<see cref="ConnectLive"/>). <see cref="Server.Create"/> makes
/// a <see cref="PocketTermServerClient"/>.
/// </summary>
public interface IServer
{
    Backend Backend { get; }

    /// <summary>This device, signed in; null while signed out.</summary>
    Account? Account { get; }

    /// <summary>The server refused this device's token: it's signed out here now.</summary>
    event EventHandler? Ended;

    /// <summary>Back at the front: the next requests go on new connections.</summary>
    void FreshConnections();

    /// <summary>Reads the sign-in this device kept for this server, without asking it.</summary>
    Task Load();

    /// <summary>Asks the server whether the sign-in still holds; a refusal ends it.</summary>
    Task Recheck();

    /// <summary>Signs this computer in with the server's setup token (its setup link).</summary>
    Task<Account> RedeemSetup(string setup, string label, string platform);

    /// <summary>Signs this phone in with a computer's pairing code (its QR).</summary>
    Task<Account> RedeemCode(string code, string label, string platform);

    /// <summary>Leaves the server: the token stops working there and is forgotten here.</summary>
    Task Leave();

    /// <summary>Computer only: wipes everything on the server, this device's sign-in too. Its setup link and id stay.</summary>
    Task Erase();

    /// <summary>The server refused the token: forgotten here, <see cref="Ended"/> says so.</summary>
    Task Refused();

    /// <summary>Computer only: a pairing code for a phone, good once for 10 minutes.</summary>
    Task<string> CreatePairingCode();

    /// <summary>Every computer and phone signed in to the server, oldest first.</summary>
    Task<List<Device>> Devices();

    /// <summary>Computer only: signs device <paramref name="id"/> out.</summary>
    Task RevokeDevice(string id);

    /// <summary>The computers phones list, most recently seen first.</summary>
    Task<List<JsonObject>> Desktops();

    /// <summary>Computer only: lists computer <paramref name="id"/> (also stamps it seen now).</summary>
    Task PutDesktop(string id, string name, string platform);

    Task DeleteDesktop(string id);

    /// <summary>A new path for an image or file: the phone seals it for this path first.</summary>
    string NewBlobPath();

    Task PutBlob(string path, byte[] bytes);

    /// <summary>The blob at <paramref name="path"/>; the server deletes it once sent.</summary>
    Task<byte[]> GetBlob(string path);

    Task DeleteBlob(string path);

    /// <summary>Push <paramref name="action"/> with its <paramref name="body"/>; the server's answer.</summary>
    Task<JsonObject> Push(string action, JsonObject body);

    /// <summary>The live channel, signed in as this device.</summary>
    Task<ILiveSocket> ConnectLive();

    void Close();
}

/// <summary>Makes the <see cref="IServer"/> for a backend (Dart's <c>Server(backend, tokens:)</c>), and
/// the limits every server shares.</summary>
public static partial class Server
{
    /// <summary>The most a blob may hold (the server's limit, 20 MiB).</summary>
    public const int MaxBlobBytes = 20 * 1024 * 1024;

    public static IServer Create(Backend backend, IDeviceTokens tokens) => new PocketTermServerClient(backend, tokens);

    /// <summary><paramref name="path"/> can be one of <see cref="IServer.NewBlobPath"/>'s.</summary>
    public static bool IsBlobPath(string path) => BlobPath().IsMatch(path);

    [GeneratedRegex(@"^[A-Za-z0-9-]{1,64}\z")]
    private static partial Regex BlobPath();
}

/// <summary>
/// The PocketTerm server (packages/pocketterm_server/PROTOCOL.md) through this device's token: signing in,
/// pairing, the computers list, images and push. Signed in is having a token (<see cref="Account"/>); once the
/// server refuses it (the device was revoked or left, the server was erased) it is forgotten and
/// <see cref="Ended"/> says so. The live channel is <see cref="TerminalChannel"/>.
/// </summary>
public class PocketTermServerClient : IServer
{
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(20);

    private readonly object _gate = new();
    private HttpClient _http = NewHttp();
    private Account? _account;
    private string? _token;

    /// <summary>The sign-in as kept in <see cref="Tokens"/>, so an unchanged one isn't written again.</summary>
    private string? _kept;

    private bool _closed;

    public PocketTermServerClient(Backend backend, IDeviceTokens tokens)
    {
        Backend = backend;
        Tokens = tokens;
    }

    public Backend Backend { get; }

    /// <summary>Where this device's sign-in is kept.</summary>
    public IDeviceTokens Tokens { get; }

    public event EventHandler? Ended;

    private static HttpClient NewHttp() => new(new SocketsHttpHandler
    {
        ConnectTimeout = TimeSpan.FromSeconds(8),
        AllowAutoRedirect = true,
        MaxAutomaticRedirections = 5,
    })
    {
        Timeout = Timeout.InfiniteTimeSpan,
    };

    /// <summary>Back at the front: the next requests go on new connections. The ones kept open from before may be
    /// dead without having said so (the system stops an app's network in the background, the computer changed
    /// networks), and a request on one would wait out its whole timeout. Requests under way finish where they are.</summary>
    public void FreshConnections()
    {
        HttpClient old;
        lock (_gate)
        {
            old = _http;
            _http = NewHttp();
        }
        // Disposing now would cancel the requests under way: they have at most their timeouts left.
        _ = Task.Delay(RequestTimeout * 4).ContinueWith(_ => old.Dispose(), TaskScheduler.Default);
    }

    /// <summary>This device, signed in; null while signed out.</summary>
    public Account? Account
    {
        get
        {
            lock (_gate) return _account;
        }
    }

    private string? Token
    {
        get
        {
            lock (_gate) return _token;
        }
    }

    /// <summary>Reads the sign-in this device kept for this server: <see cref="Account"/> at once, without asking
    /// the server (<see cref="Recheck"/> does), so a launch shows what it had before the network answers.</summary>
    public async Task Load()
    {
        try
        {
            var raw = await Tokens.Read().ConfigureAwait(false);
            if (raw != null &&
                DartJson.TryDecodeObject(raw) is { } saved &&
                saved.Str("url") is { } url &&
                saved.Str("token") is { } token &&
                saved.Str("server") is { } server &&
                saved.Obj("device") is { } device &&
                url == Backend.Url)
            {
                var account = new Account(server, Device.FromJson(device));
                lock (_gate)
                {
                    _token = token;
                    _account = account;
                    _kept = raw;
                }
            }
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: sign-in not read: {e.Message}");
        }
    }

    /// <summary>Asks the server whether the sign-in still holds, and keeps what it says of this device. A refusal
    /// ends it (<see cref="Ended"/>); no answer (offline), or one this app doesn't read (a captive portal's page),
    /// keeps it.</summary>
    public async Task Recheck()
    {
        var token = Token;
        if (token == null) return;
        try
        {
            var me = await Json("GET", "/v1/me", token: token).ConfigureAwait(false);
            // Signed out, or in anew, meanwhile: the answer is about a sign-in that's gone.
            if (Token == token) await Keep(token, me).ConfigureAwait(false);
        }
        catch (ServerException e)
        {
            if (e.Status == 401 && Token == token) await Refused().ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: sign-in not checked: {e.Message}");
        }
    }

    public Task<Account> RedeemSetup(string setup, string label, string platform) =>
        Redeem("/v1/setup/redeem", new JsonObject { ["setup"] = setup, ["label"] = label, ["platform"] = platform });

    public Task<Account> RedeemCode(string code, string label, string platform) =>
        Redeem("/v1/pair/redeem", new JsonObject { ["code"] = code, ["label"] = label, ["platform"] = platform });

    private async Task<Account> Redeem(string path, JsonObject body)
    {
        var answer = await Json("POST", path, body: body, auth: false).ConfigureAwait(false);
        if (answer is JsonObject o && o.Str("token") is { } token) return await SignedIn(token).ConfigureAwait(false);
        throw new ServerException(500, "internal", "The server didn't send a sign-in.");
    }

    /// <summary>Asks the server who <paramref name="token"/> is and keeps it.</summary>
    private async Task<Account> SignedIn(string token) =>
        await Keep(token, await Json("GET", "/v1/me", token: token).ConfigureAwait(false)).ConfigureAwait(false);

    /// <summary><paramref name="token"/> and the device the server's GET /v1/me (<paramref name="me"/>) says it is.</summary>
    private async Task<Account> Keep(string token, JsonNode? me)
    {
        if (me is JsonObject m && m.Obj("device") is { } device && m.Obj("server")?.Str("id") is { } server)
        {
            var account = new Account(server, Device.FromJson(device));
            var kept = DartJson.Encode(new JsonObject
            {
                ["url"] = Backend.Url,
                ["token"] = token,
                ["server"] = server,
                ["device"] = account.Device.ToJson(),
            });
            string? before;
            lock (_gate) before = _kept;
            if (kept != before) await Tokens.Write(kept).ConfigureAwait(false);
            lock (_gate)
            {
                _kept = kept;
                _token = token;
                _account = account;
            }
            return account;
        }
        throw new ServerException(500, "internal", "The server sent an answer this app doesn't read.");
    }

    /// <summary>Leaves the server: the token stops working there (DELETE /v1/devices/me) and is forgotten here,
    /// also when the server can't be reached.</summary>
    public async Task Leave()
    {
        try
        {
            if (Token != null) await Json("DELETE", "/v1/devices/me").ConfigureAwait(false);
        }
        finally
        {
            await Forget().ConfigureAwait(false);
        }
    }

    /// <summary>Computer only: wipes everything on the server (every device, this one too, the computers list,
    /// codes, push tokens, images). Its setup link and id stay.</summary>
    public async Task Erase()
    {
        await Json("POST", "/v1/erase").ConfigureAwait(false);
        await Forget().ConfigureAwait(false);
    }

    private async Task Forget()
    {
        lock (_gate)
        {
            _token = null;
            _account = null;
            _kept = null;
        }
        await Tokens.Write(null).ConfigureAwait(false);
    }

    /// <summary>The server refused the token (an answer 401, the live channel closed with 4003): forgotten here,
    /// <see cref="Ended"/> says so (unless <see cref="Close"/>d by then).</summary>
    public async Task Refused()
    {
        if (Token == null) return;
        await Forget().ConfigureAwait(false);
        bool closed;
        lock (_gate) closed = _closed;
        if (!closed) Ended?.Invoke(this, EventArgs.Empty);
    }

    public async Task<string> CreatePairingCode()
    {
        var answer = await Json("POST", "/v1/pair").ConfigureAwait(false);
        if (answer is JsonObject o && o.Str("code") is { } code) return code;
        throw new ServerException(500, "internal", "The server didn't send a code.");
    }

    public async Task<List<Device>> Devices()
    {
        var list = (JsonArray)(await Json("GET", "/v1/devices").ConfigureAwait(false))!;
        return list.Select(d => Device.FromJson((JsonObject)d!)).ToList();
    }

    /// <summary>Computer only: signs device <paramref name="id"/> out (a lost phone); it's told so the next time it asks.</summary>
    public Task RevokeDevice(string id) => Json("DELETE", $"/v1/devices/{id}");

    public async Task<List<JsonObject>> Desktops()
    {
        var list = (JsonArray)(await Json("GET", "/v1/desktops").ConfigureAwait(false))!;
        return list.Select(d => (JsonObject)d!).ToList();
    }

    public Task PutDesktop(string id, string name, string platform) =>
        Json("PUT", $"/v1/desktops/{id}", body: new JsonObject { ["name"] = name, ["platform"] = platform });

    public Task DeleteDesktop(string id) => Json("DELETE", $"/v1/desktops/{id}");

    public string NewBlobPath() => Guid.NewGuid().ToString("D");

    /// <summary>Uploads <paramref name="bytes"/> to <paramref name="path"/>. One over <see cref="Server.MaxBlobBytes"/>
    /// fails here, with the reason: sent, the server would cut it off and the reason would be lost.</summary>
    public async Task PutBlob(string path, byte[] bytes)
    {
        if (bytes.Length > Server.MaxBlobBytes)
        {
            throw new ServerException(413, "too_large", "That file is too large: the most is 20 MB.");
        }
        await Json("PUT", $"/v1/blobs/{path}", bytes: bytes).ConfigureAwait(false);
    }

    public async Task<byte[]> GetBlob(string path) => (await Send("GET", $"/v1/blobs/{path}").ConfigureAwait(false)).Bytes;

    public Task DeleteBlob(string path) => Json("DELETE", $"/v1/blobs/{path}");

    /// <summary>Push <paramref name="action"/> (register, unregister, notify, activity_register, activity_end,
    /// activity) with its <paramref name="body"/>; the server's answer (<c>{sent}</c> for notify and activity).</summary>
    public async Task<JsonObject> Push(string action, JsonObject body) =>
        (JsonObject)(await Json("POST", $"/v1/push/{action}", body: body).ConfigureAwait(false))!;

    /// <summary>The server's WebSocket (GET /v1/ws), signed in as this device.</summary>
    public virtual async Task<ILiveSocket> ConnectLive()
    {
        var token = Token ?? throw new ServerException(401, "unauthorized", "Not signed in.");
        var url = DartUri.Parse(Backend.Api);
        var ws = await WebSocketConnection.Connect(
            url.Replace(url.Scheme == "https" ? "wss" : "ws", $"{url.Path}/v1/ws"),
            new Dictionary<string, string> { ["authorization"] = $"Bearer {token}" },
            RequestTimeout).ConfigureAwait(false);
        return new WebSocketLive(ws);
    }

    public void Close()
    {
        HttpClient http;
        lock (_gate)
        {
            _closed = true;
            http = _http;
        }
        http.Dispose();
    }

    private async Task<JsonNode?> Json(string method, string path, JsonObject? body = null, byte[]? bytes = null, bool auth = true, string? token = null)
    {
        var res = await Send(method, path, body, bytes, auth, token).ConfigureAwait(false);
        return res.Bytes.Length == 0 ? null : DartJson.Decode(DartString.StrictUtf8.GetString(res.Bytes));
    }

    private async Task<(int Status, byte[] Bytes)> Send(
        string method,
        string path,
        JsonObject? body = null,
        byte[]? bytes = null,
        bool auth = true,
        string? token = null)
    {
        var bearer = token ?? Token;
        if (auth && bearer == null) throw new ServerException(401, "unauthorized", "Not signed in.");
        (int Status, byte[] Bytes) res;
        try
        {
            HttpClient http;
            lock (_gate) http = _http;
            using var req = new HttpRequestMessage(new HttpMethod(method), $"{Backend.Api}{path}");
            if (auth) req.Headers.TryAddWithoutValidation("authorization", $"Bearer {bearer}");
            if (bytes != null)
            {
                req.Content = new ByteArrayContent(bytes);
                req.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
            }
            else if (body != null)
            {
                req.Content = new StringContent(DartJson.Encode(body), Encoding.UTF8, "application/json");
            }
            // Dart gives opening the request and then its answer 20 s each, and reading the body 20 s more.
            using var sent = new CancellationTokenSource(RequestTimeout * 2);
            using var answer = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, sent.Token).ConfigureAwait(false);
            using var read = new CancellationTokenSource(RequestTimeout);
            res = ((int)answer.StatusCode, await answer.Content.ReadAsByteArrayAsync(read.Token).ConfigureAwait(false));
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: {method} {path}: {e.Message}");
            throw new ServerException(0, "offline", Backend.Unreachable);
        }
        if (res.Status < 400) return res;
        var code = "internal";
        var message = $"The server failed ({res.Status}).";
        try
        {
            if (DartJson.Decode(DartString.StrictUtf8.GetString(res.Bytes)) is JsonObject o &&
                o.Str("error") is { } c &&
                o.Str("message") is { } m)
            {
                code = c;
                message = m;
            }
        }
        catch (Exception e) when (e is System.Text.Json.JsonException or DecoderFallbackException or ArgumentException)
        {
            // Not the server's own answer (a proxy's error page).
        }
        // The token this device holds stopped working.
        if (res.Status == 401 && auth && token == null) await Refused().ConfigureAwait(false);
        throw new ServerException(res.Status, code, message);
    }
}

/// <summary>The PocketTerm server's WebSocket as an <see cref="ILiveSocket"/>: its frames as they are.</summary>
internal sealed class WebSocketLive(WebSocketConnection ws) : ILiveSocket
{
    public ChannelReader<string> Frames => ws.Frames;

    public void Add(string frame) => ws.Add(frame);

    public int? CloseCode => ws.CloseCode;

    public Task Close(int code = 1000) => ws.Close(code);
}
