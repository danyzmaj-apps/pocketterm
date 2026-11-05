using System.Net.WebSockets;
using System.Text;
using System.Threading.Channels;

namespace PocketTerm.Core;

/// <summary>
/// A text WebSocket the way Dart's <c>WebSocket</c> behaves: frames in as a stream that completes when the
/// connection is gone, <see cref="Add"/> queues a frame (sent in order, never blocking the caller),
/// <see cref="CloseCode"/> the peer's close code. <see cref="ClientWebSocket"/> takes one send and one receive
/// at a time; the loops here keep it so.
/// </summary>
internal sealed class WebSocketConnection
{
    private static readonly TimeSpan CloseWait = TimeSpan.FromSeconds(3);

    private readonly ClientWebSocket _ws;
    private readonly Channel<string> _in = Channel.CreateUnbounded<string>(new UnboundedChannelOptions { SingleWriter = true });
    private readonly Channel<string> _out = Channel.CreateUnbounded<string>(new UnboundedChannelOptions { SingleReader = true });
    private readonly CancellationTokenSource _stop = new();
    private Task _receiving = Task.CompletedTask;
    private Task _sending = Task.CompletedTask;
    private int _closeCode = 1000;
    private int? _peerCode;
    private int _closing;

    private WebSocketConnection(ClientWebSocket ws) => _ws = ws;

    /// <summary>Opens <paramref name="url"/> (ws:// or wss://) with <paramref name="headers"/>, in at most
    /// <paramref name="timeout"/>.</summary>
    public static async Task<WebSocketConnection> Connect(string url, IReadOnlyDictionary<string, string>? headers, TimeSpan timeout)
    {
        var ws = new ClientWebSocket();
        if (headers != null)
        {
            foreach (var (k, v) in headers) ws.Options.SetRequestHeader(k, v);
        }
        // Dart's WebSocket doesn't ping on its own; the live channel pings itself.
        ws.Options.KeepAliveInterval = TimeSpan.Zero;
        using var cts = new CancellationTokenSource(timeout);
        try
        {
            await ws.ConnectAsync(new Uri(url), cts.Token).ConfigureAwait(false);
        }
        catch
        {
            ws.Dispose();
            throw;
        }
        var c = new WebSocketConnection(ws);
        c._receiving = Task.Run(c.Receive);
        c._sending = Task.Run(c.SendLoop);
        return c;
    }

    public ChannelReader<string> Frames => _in.Reader;

    /// <summary>The close code the other side sent, once it did.</summary>
    public int? CloseCode => _peerCode ?? (_ws.CloseStatus is { } s ? (int)s : null);

    public void Add(string frame) => _out.Writer.TryWrite(frame);

    /// <summary>Sends a close with <paramref name="code"/> after what's queued, waits a moment for the other side's,
    /// then lets the connection go.</summary>
    public async Task Close(int code = 1000)
    {
        if (Interlocked.Exchange(ref _closing, 1) == 1)
        {
            await _receiving.ConfigureAwait(false);
            return;
        }
        _closeCode = code;
        _out.Writer.TryComplete();
        await Task.WhenAny(_sending, Task.Delay(CloseWait)).ConfigureAwait(false);
        await Task.WhenAny(_receiving, Task.Delay(CloseWait)).ConfigureAwait(false);
        _stop.Cancel();
        if (!_receiving.IsCompleted) _ws.Abort();
        await _receiving.ConfigureAwait(false);
        _ws.Dispose();
    }

    private async Task Receive()
    {
        var buffer = new byte[16 * 1024];
        var message = new MemoryStream();
        try
        {
            while (true)
            {
                var r = await _ws.ReceiveAsync(buffer, _stop.Token).ConfigureAwait(false);
                if (r.MessageType == WebSocketMessageType.Close)
                {
                    _peerCode = r.CloseStatus is { } s ? (int)s : null;
                    break;
                }
                message.Write(buffer, 0, r.Count);
                if (!r.EndOfMessage) continue;
                if (r.MessageType == WebSocketMessageType.Text)
                {
                    _in.Writer.TryWrite(Encoding.UTF8.GetString(message.GetBuffer(), 0, (int)message.Length));
                }
                message.SetLength(0);
            }
            // Answer the other side's close, as Dart's WebSocket does.
            if (_ws.State == WebSocketState.CloseReceived)
            {
                using var cts = new CancellationTokenSource(CloseWait);
                await _ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, cts.Token).ConfigureAwait(false);
            }
        }
        catch (Exception)
        {
            // Reset, aborted or closed: the stream ends either way.
        }
        finally
        {
            _out.Writer.TryComplete();
            _in.Writer.TryComplete();
        }
    }

    private async Task SendLoop()
    {
        try
        {
            await foreach (var frame in _out.Reader.ReadAllAsync(_stop.Token).ConfigureAwait(false))
            {
                if (_ws.State != WebSocketState.Open) continue;
                await _ws.SendAsync(Encoding.UTF8.GetBytes(frame), WebSocketMessageType.Text, true, _stop.Token).ConfigureAwait(false);
            }
            if (_ws.State == WebSocketState.Open && Volatile.Read(ref _closing) == 1)
            {
                using var cts = new CancellationTokenSource(CloseWait);
                await _ws.CloseOutputAsync((WebSocketCloseStatus)_closeCode, null, cts.Token).ConfigureAwait(false);
            }
        }
        catch (Exception)
        {
            // The connection went: the receive loop ends the stream.
        }
    }
}
