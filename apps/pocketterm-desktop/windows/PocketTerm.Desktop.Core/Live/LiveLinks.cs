using System.Globalization;
using System.Net.WebSockets;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>One extension's connection, whatever carries it (<see cref="LocalApi"/>): a WebSocket (omp) or HTTP long
/// polls (Claude Code).</summary>
public interface LiveLink
{
    /// <summary>A JSON frame to the extension. Never blocks, never throws: frames go out in order.</summary>
    void Send(string frame);

    Task CloseAsync();
}

/// <summary>A WebSocket as a <see cref="LiveLink"/>: frames go out one at a time, in order, from a queue (a
/// WebSocket takes one send at a time); <see cref="Frames"/> reads the text messages that come in.</summary>
public sealed class SocketLink : LiveLink
{
    private readonly WebSocket _ws;
    private readonly Channel<string> _out = Channel.CreateUnbounded<string>(new UnboundedChannelOptions { SingleReader = true });
    private readonly Task _pump;
    private int _closing;

    public SocketLink(WebSocket ws)
    {
        _ws = ws;
        _pump = Task.Run(PumpAsync);
    }

    public void Send(string frame) => _out.Writer.TryWrite(frame);

    private async Task PumpAsync()
    {
        try
        {
            await foreach (var frame in _out.Reader.ReadAllAsync())
            {
                await _ws.SendAsync(Encoding.UTF8.GetBytes(frame), WebSocketMessageType.Text, endOfMessage: true, CancellationToken.None);
            }
        }
        catch (Exception e) when (e is WebSocketException or ObjectDisposedException or InvalidOperationException or OperationCanceledException or IOException)
        {
            // The socket has gone: what's left goes nowhere, as with Dart's add on a closed WebSocket.
        }
    }

    /// <summary>Closes it after the frames queued, as Dart's <c>WebSocket.close()</c>; with 1000, as a close frame
    /// without a status (1005) mustn't be sent.</summary>
    public Task CloseAsync() => CloseAsync(WebSocketCloseStatus.NormalClosure);

    /// <summary>Sends a close with <paramref name="status"/> after the frames queued (once), not waiting for the other
    /// side's close.</summary>
    public async Task CloseAsync(WebSocketCloseStatus status)
    {
        _out.Writer.TryComplete();
        if (Interlocked.Exchange(ref _closing, 1) == 1) return;
        try
        {
            await _pump.WaitAsync(TimeSpan.FromSeconds(5));
            if (_ws.State is WebSocketState.Open or WebSocketState.CloseReceived)
            {
                await _ws.CloseOutputAsync(status, null, CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(5));
            }
        }
        catch (Exception e) when (e is WebSocketException or ObjectDisposedException or InvalidOperationException or OperationCanceledException or IOException or TimeoutException)
        {
            // A peer that doesn't read: let it go.
            _ws.Abort();
        }
    }

    /// <summary>The text messages that come in (binary ones skipped) until the other side closes; the close is
    /// answered with its own status. A connection that breaks throws.</summary>
    public async IAsyncEnumerable<string> Frames([EnumeratorCancellation] CancellationToken cancel = default)
    {
        var buffer = new byte[16 * 1024];
        using var message = new MemoryStream();
        while (true)
        {
            var r = await _ws.ReceiveAsync(buffer, cancel);
            if (r.MessageType == WebSocketMessageType.Close)
            {
                await CloseAsync(r.CloseStatus is { } status and not WebSocketCloseStatus.Empty ? status : WebSocketCloseStatus.NormalClosure);
                yield break;
            }
            message.Write(buffer, 0, r.Count);
            if (!r.EndOfMessage) continue;
            if (r.MessageType == WebSocketMessageType.Text) yield return Encoding.UTF8.GetString(message.GetBuffer(), 0, (int)message.Length);
            message.SetLength(0);
        }
    }
}

/// <summary>Dart's <c>as</c> casts on decoded JSON, which the live frames lean on: a value of another type throws
/// (the frame is skipped), a missing one is null.</summary>
internal static class LiveCasts
{
    /// <summary><c>m[k] as String?</c>.</summary>
    public static string? OptStr(JsonObject m, string k) =>
        m[k] is null ? null : DartJson.AsString(m[k]) ?? throw new InvalidCastException($"'{k}' is not a String");

    /// <summary><c>m[k] as String</c>.</summary>
    public static string ReqStr(JsonObject m, string k) =>
        DartJson.AsString(m[k]) ?? throw new InvalidCastException($"'{k}' is not a String");

    /// <summary><c>m[k] as num?</c>.</summary>
    public static double? OptNum(JsonObject m, string k) =>
        m[k] is null ? null : DartJson.AsNum(m[k]) ?? throw new InvalidCastException($"'{k}' is not a num");

    /// <summary><c>m[k] as Map?</c>.</summary>
    public static JsonObject? OptMap(JsonObject m, string k) =>
        m[k] is null ? null : m[k] as JsonObject ?? throw new InvalidCastException($"'{k}' is not a Map");

    /// <summary><c>m[k] as List?</c>.</summary>
    public static JsonArray? OptList(JsonObject m, string k) =>
        m[k] is null ? null : m[k] as JsonArray ?? throw new InvalidCastException($"'{k}' is not a List");

    /// <summary><c>v == true</c>.</summary>
    public static bool IsTrue(JsonNode? v) => DartJson.AsBool(v) == true;

    /// <summary>Dart's <c>num.round()</c>: halves away from zero.</summary>
    public static long? Round(double? v) => v is { } x ? (long)Math.Round(x, MidpointRounding.AwayFromZero) : null;

    /// <summary>Dart's <c>num.toInt()</c>, as an int: toward zero.</summary>
    public static int? ToInt(double? v) => v is { } x ? (int)Math.Clamp(Math.Truncate(x), int.MinValue, int.MaxValue) : null;

    /// <summary>Dart's <c>'$v'</c> of a decoded scalar (<c>null</c>, <c>42</c>, <c>x</c>, <c>4.0</c>).</summary>
    public static string DartToString(JsonNode? v) => v switch
    {
        null => "null",
        _ when DartJson.AsString(v) is { } s => s,
        _ when DartJson.AsInt(v) is { } i => i.ToString(CultureInfo.InvariantCulture),
        _ => DartJson.Encode(v),
    };
}
