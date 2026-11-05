using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace PocketTerm.Core;

// End-to-end encryption between a computer and its phones (docs/ARCHITECTURE.md,
// SECURITY.md). Each computer has one channel key, made on the computer and
// handed to a phone only in its QR code; the server relays what it seals and
// can't read it. Sealed bytes are nonce (12) || ciphertext || tag (16),
// AES-256-GCM, with additional data naming what they are, so a message can't
// be moved to another computer, event, image or push.

/// <summary>A computer (its id, <see cref="Desktop"/>) and its channel key, as the computer's QR code hands
/// them to a phone.</summary>
public sealed record ComputerKey(string Desktop, ChannelKey Key);

/// <summary>One computer's channel key: 32 random bytes.</summary>
public sealed class ChannelKey : IEquatable<ChannelKey>
{
    public const int Length = 32;

    private readonly byte[] _bytes;

    public ChannelKey(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length != Length) throw new ArgumentException($"A channel key is {Length} bytes, not {bytes.Length}.");
        _bytes = bytes.ToArray();
    }

    /// <summary>A copy of the key's bytes.</summary>
    public byte[] Bytes => (byte[])_bytes.Clone();

    internal ReadOnlySpan<byte> Span => _bytes;

    /// <summary>A new random key.</summary>
    public static ChannelKey Generate() => new(RandomNumberGenerator.GetBytes(Length));

    /// <summary>A key as <see cref="ToBase64"/> or <see cref="ToBase64Url"/> write it, with or without
    /// padding; null when it isn't one.</summary>
    public static ChannelKey? TryParse(string? text)
    {
        if (text is null) return null;
        var bytes = DartBase64.TryDecode(text.DartTrim().Replace('+', '-').Replace('/', '_'));
        return bytes is { Length: Length } ? new ChannelKey(bytes) : null;
    }

    /// <summary>Standard base64 with padding: how the phone's native side keeps it.</summary>
    public string ToBase64() => DartBase64.Encode(_bytes);

    /// <summary>URL-safe base64 without padding: how a setup link carries it.</summary>
    public string ToBase64Url() => DartBase64.EncodeUrlNoPadding(_bytes);

    public bool Equals(ChannelKey? other) => other is not null && CryptographicOperations.FixedTimeEquals(other._bytes, _bytes);

    public override bool Equals(object? obj) => obj is ChannelKey k && Equals(k);

    public override int GetHashCode()
    {
        var h = new HashCode();
        h.AddBytes(_bytes);
        return h.ToHashCode();
    }

    public static bool operator ==(ChannelKey? a, ChannelKey? b) => a is null ? b is null : a.Equals(b);

    public static bool operator !=(ChannelKey? a, ChannelKey? b) => !(a == b);

    public override string ToString() => "ChannelKey(…)";
}

/// <summary>Sealing and opening (lib/e2e.dart): AAD strings, push tags, bytes and envelopes.</summary>
public static class E2e
{
    private const int NonceLength = 12;
    private const int TagLength = 16;

    /// <summary>What sealing adds to the bytes: the nonce and the tag.</summary>
    public const int SealedOverhead = NonceLength + TagLength;

    /// <summary>The version an envelope's <c>v</c> says.</summary>
    public const int EnvelopeVersion = 1;

    /// <summary>The additional data of a live channel <paramref name="event"/> on <paramref name="topic"/>.</summary>
    public static string ChannelAad(string topic, string @event) => $"pocketterm/v1|{topic}|{@event}";

    /// <summary>The additional data of an image, or a file a prompt takes, stored at <paramref name="path"/>
    /// (the same for both: the file's name and type travel in the sealed prompt).</summary>
    public static string ImageAad(string path) => $"pocketterm/v1|image|{path}";

    /// <summary>The additional data of a push from computer <paramref name="desktopId"/>.</summary>
    public static string PushAad(string desktopId) => $"pocketterm/v1|push|{desktopId}";

    /// <summary>The additional data of a followed session's update (Android) from computer <paramref name="desktopId"/>.</summary>
    public static string ActivityAad(string desktopId) => $"pocketterm/v1|activity|{desktopId}";

    /// <summary>What a push says about the computer that sealed it, instead of its id: the first 8 bytes of
    /// HMAC-SHA256(key, <c>pocketterm/v1|push-tag</c>) in base64url without padding (11 characters). The same
    /// for every push from that computer and meaningless without its key: the phone finds the key whose tag it
    /// is, the relay and the push services can't tell which computer it is.</summary>
    public static string PushTag(ChannelKey key) => Tag(key, "pocketterm/v1|push-tag", 8);

    /// <summary>What a push says about coding session <paramref name="routedKey"/> (<c>&lt;desktop id&gt;/&lt;key&gt;</c>):
    /// the first 16 bytes of HMAC-SHA256(key, <c>pocketterm/v1|push-session|&lt;routedKey&gt;</c>) in base64url
    /// without padding (22 characters). It lets a newer push for the session replace an older one (collapse id)
    /// and, on Android, names the session a plain end is for, without telling anyone on the way which session it is.</summary>
    public static string SessionTag(ChannelKey key, string routedKey) => Tag(key, $"pocketterm/v1|push-session|{routedKey}", 16);

    private static string Tag(ChannelKey key, string what, int length)
    {
        var mac = HMACSHA256.HashData(key.Span, Encoding.UTF8.GetBytes(what));
        return DartBase64.EncodeUrlNoPadding(mac.AsSpan(0, length));
    }

    /// <summary><paramref name="plain"/> sealed with <paramref name="key"/> for <paramref name="aad"/>: nonce || ciphertext || tag.</summary>
    public static byte[] SealBytes(ChannelKey key, ReadOnlySpan<byte> plain, string aad) =>
        SealBytes(key, plain, aad, RandomNumberGenerator.GetBytes(NonceLength));

    /// <summary><see cref="SealBytes(ChannelKey, ReadOnlySpan{byte}, string)"/> with a given nonce (tests).</summary>
    internal static byte[] SealBytes(ChannelKey key, ReadOnlySpan<byte> plain, string aad, ReadOnlySpan<byte> nonce)
    {
        if (nonce.Length != NonceLength) throw new ArgumentException("A nonce is 12 bytes.");
        var sealedBytes = new byte[NonceLength + plain.Length + TagLength];
        nonce.CopyTo(sealedBytes);
        using var aes = new AesGcm(key.Span, TagLength);
        aes.Encrypt(
            nonce,
            plain,
            sealedBytes.AsSpan(NonceLength, plain.Length),
            sealedBytes.AsSpan(NonceLength + plain.Length, TagLength),
            Encoding.UTF8.GetBytes(aad));
        return sealedBytes;
    }

    /// <summary>What <paramref name="sealedBytes"/> holds, or null when it wasn't sealed with <paramref name="key"/>
    /// for <paramref name="aad"/> (another key, another purpose, changed on the way, too short).</summary>
    public static byte[]? OpenBytes(ChannelKey key, ReadOnlySpan<byte> sealedBytes, string aad)
    {
        if (sealedBytes.Length < NonceLength + TagLength) return null;
        var length = sealedBytes.Length - NonceLength - TagLength;
        var plain = new byte[length];
        try
        {
            using var aes = new AesGcm(key.Span, TagLength);
            aes.Decrypt(
                sealedBytes[..NonceLength],
                sealedBytes.Slice(NonceLength, length),
                sealedBytes[(NonceLength + length)..],
                plain,
                Encoding.UTF8.GetBytes(aad));
            return plain;
        }
        catch (CryptographicException)
        {
            return null;
        }
    }

    /// <summary><paramref name="message"/> as it goes on the live channel:
    /// <c>{"v":1,"n":"&lt;base64 nonce&gt;","c":"&lt;base64 ciphertext and tag&gt;"}</c>.</summary>
    public static JsonObject SealEnvelope(ChannelKey key, JsonObject message, string aad) =>
        Envelope(SealBytes(key, DartJson.EncodeUtf8(message), aad));

    private static JsonObject Envelope(byte[] sealedBytes) => new()
    {
        ["v"] = EnvelopeVersion,
        ["n"] = DartBase64.Encode(sealedBytes.AsSpan(0, NonceLength)),
        ["c"] = DartBase64.Encode(sealedBytes.AsSpan(NonceLength)),
    };

    /// <summary>The message in <paramref name="envelope"/>, or why it was dropped: <c>version</c> (not one this
    /// reads), <c>sealed</c> (not sealed with <paramref name="key"/> for <paramref name="aad"/>), <c>json</c>
    /// (not a JSON object inside).</summary>
    public static (JsonObject? Message, string? Drop) OpenEnvelope(ChannelKey key, JsonObject envelope, string aad)
    {
        // Dart's `!=` on a number: 1.0 is 1 too.
        if (DartJson.AsNum(envelope["v"]) != EnvelopeVersion) return (null, "version");
        var n = envelope.Str("n");
        var c = envelope.Str("c");
        if (n is null || c is null) return (null, "sealed");
        var nonce = DartBase64.TryDecode(n);
        var rest = DartBase64.TryDecode(c);
        if (nonce is null || rest is null) return (null, "sealed");
        if (nonce.Length != NonceLength) return (null, "sealed");
        var plain = OpenBytes(key, [.. nonce, .. rest], aad);
        if (plain is null) return (null, "sealed");
        try
        {
            if (DartJson.Decode(DartString.StrictUtf8.GetString(plain)) is JsonObject message) return (message, null);
        }
        catch (Exception e) when (e is System.Text.Json.JsonException or DecoderFallbackException or ArgumentException)
        {
            // Below.
        }
        return (null, "json");
    }

    /// <summary>A new message id: 16 random URL-safe characters.</summary>
    public static string NewMessageId() => DartBase64.EncodeUrlNoPadding(RandomNumberGenerator.GetBytes(12));

    /// <summary>A push <paramref name="notice"/> (<c>{title, body, session?, state?}</c>) from computer
    /// <paramref name="desktopId"/>, sealed with its key for the phones (AAD <see cref="PushAad"/>), in base64:
    /// the <c>enc</c> the server forwards. Inside it gains <c>ts</c> (ms since epoch) and <c>id</c> (random), so a
    /// phone can refuse an old or repeated one.</summary>
    public static string SealNotice(ChannelKey key, string desktopId, JsonObject notice) => SealPush(key, notice, PushAad(desktopId));

    /// <summary>A followed session's <paramref name="activity"/> (<c>{session, state, since, kind?}</c>) from
    /// computer <paramref name="desktopId"/> for Android phones, sealed like <see cref="SealNotice"/> (also with
    /// <c>ts</c> and <c>id</c> inside) but for <see cref="ActivityAad"/>.</summary>
    public static string SealActivity(ChannelKey key, string desktopId, JsonObject activity) =>
        SealPush(key, activity, ActivityAad(desktopId));

    private static string SealPush(ChannelKey key, JsonObject body, string aad)
    {
        var inner = (JsonObject)body.DeepClone();
        inner["ts"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        inner["id"] = NewMessageId();
        return DartBase64.Encode(SealBytes(key, DartJson.EncodeUtf8(inner), aad));
    }
}

/// <summary>
/// Drops opened live channel messages that are stale, seen before or out of order. Every message carries
/// <c>ts</c> (ms since epoch), <c>mid</c> (a random id), <c>ep</c> (its sender's epoch: random, new each time a
/// sender starts) and <c>seq</c> (that sender's count, from 1). Dropped: a <c>ts</c> more than
/// <see cref="Window"/> off this clock or before <see cref="NotBefore"/> (sent before this guard existed, so
/// before this app started: nothing here remembers it), a <c>mid</c> seen in the last <see cref="Remember"/>,
/// and a <c>seq</c> at or below the last one taken for its <c>ep</c>. Memory stays bounded: epochs and ids go
/// after <see cref="Remember"/> unseen, and past <see cref="MaxEpochs"/> / <see cref="MaxIds"/> the oldest go
/// first (a message that old is out of the window by then anyway, or caught by the other check).
/// Thread-safe.
/// </summary>
public sealed class ReplayGuard
{
    private static readonly Dictionary<string, ReplayGuard> ByTopic = new();

    private readonly Func<DateTimeOffset> _clock;
    private readonly object _gate = new();

    // Both in the order last seen, oldest first.
    private readonly OrderedMap<string, DateTimeOffset> _ids = new();
    private readonly OrderedMap<string, (long Seq, DateTimeOffset At)> _epochs = new();

    public ReplayGuard(
        TimeSpan? window = null,
        TimeSpan? remember = null,
        int maxEpochs = 64,
        int maxIds = 10000,
        Func<DateTimeOffset>? clock = null)
    {
        Window = window ?? TimeSpan.FromMinutes(5);
        Remember = remember ?? TimeSpan.FromMinutes(10);
        MaxEpochs = maxEpochs;
        MaxIds = maxIds;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
        NotBefore = _clock();
    }

    /// <summary>One guard per computer (<paramref name="topic"/>, its id) for this whole run of the app: it
    /// outlives each channel, so a channel made again (the bridge restarted, another sign-in) still knows what it took.</summary>
    public static ReplayGuard Of(string topic)
    {
        lock (ByTopic)
        {
            if (!ByTopic.TryGetValue(topic, out var guard)) ByTopic[topic] = guard = new ReplayGuard();
            return guard;
        }
    }

    public TimeSpan Window { get; }

    /// <summary>How long an id or an epoch is kept after it was last seen; at least twice <see cref="Window"/>,
    /// so a message taken once can't come back in time.</summary>
    public TimeSpan Remember { get; }

    public int MaxEpochs { get; }

    public int MaxIds { get; }

    /// <summary>When this guard started: messages from before it are dropped.</summary>
    public DateTimeOffset NotBefore { get; }

    /// <summary>Null when <paramref name="message"/> may go on (and it is remembered), else why not:
    /// <c>time</c>, <c>replay</c> or <c>order</c>.</summary>
    public string? Check(JsonObject message)
    {
        lock (_gate)
        {
            var now = _clock();
            var nowMs = now.ToUnixTimeMilliseconds();
            if (message.Int("ts") is not { } ts ||
                Math.Abs(nowMs - ts) > (long)Window.TotalMilliseconds ||
                ts < NotBefore.ToUnixTimeMilliseconds())
            {
                return "time";
            }
            var mid = message.Str("mid");
            var ep = message.Str("ep");
            var seq = message.Int("seq");
            if (string.IsNullOrEmpty(mid) || string.IsNullOrEmpty(ep) || seq is not { } s || s < 1) return "replay";
            _ids.RemoveWhere((_, at) => now - at > Remember);
            _epochs.RemoveWhere((_, e) => now - e.At > Remember);
            if (_ids.ContainsKey(mid)) return "replay";
            if (_epochs.Remove(ep, out var last) && s <= last.Seq)
            {
                _epochs.Set(ep, last);
                return "order";
            }
            _epochs.Set(ep, (s, now));
            _ids.Set(mid, now);
            while (_epochs.Count > MaxEpochs) _epochs.RemoveFirst();
            while (_ids.Count > MaxIds) _ids.RemoveFirst();
            return null;
        }
    }
}

/// <summary>A map in insertion order with O(1) lookups (Dart's default <c>Map</c>): setting an existing key
/// keeps its place.</summary>
internal sealed class OrderedMap<TKey, TValue>
    where TKey : notnull
{
    private readonly Dictionary<TKey, LinkedListNode<KeyValuePair<TKey, TValue>>> _index = new();
    private readonly LinkedList<KeyValuePair<TKey, TValue>> _order = new();

    public int Count => _index.Count;

    public bool ContainsKey(TKey key) => _index.ContainsKey(key);

    public void Set(TKey key, TValue value)
    {
        if (_index.TryGetValue(key, out var node)) node.Value = new(key, value);
        else _index[key] = _order.AddLast(new KeyValuePair<TKey, TValue>(key, value));
    }

    public bool Remove(TKey key, out TValue value)
    {
        if (_index.Remove(key, out var node))
        {
            _order.Remove(node);
            value = node.Value.Value;
            return true;
        }
        value = default!;
        return false;
    }

    public void RemoveFirst()
    {
        var first = _order.First!;
        _order.RemoveFirst();
        _index.Remove(first.Value.Key);
    }

    public void RemoveWhere(Func<TKey, TValue, bool> test)
    {
        for (var node = _order.First; node != null;)
        {
            var next = node.Next;
            if (test(node.Value.Key, node.Value.Value))
            {
                _order.Remove(node);
                _index.Remove(node.Value.Key);
            }
            node = next;
        }
    }
}
