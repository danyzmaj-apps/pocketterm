using System.Text;
using System.Text.Json.Nodes;

namespace PocketTerm.Core.Tests;

/// <summary>tool/vectors: the <c>crypto</c> and <c>replayGuard</c> sections.</summary>
public class CryptoVectorTests
{
    private static readonly JsonObject Crypto = Vectors.Section("crypto");

    private static ChannelKey Key(JsonNode? name) => new(Vectors.Hex(Crypto.Obj("keys")!.Obj(DartJson.AsString(name)!)!["hex"]));

    private static IEnumerable<JsonObject> Cases(string name) => Crypto.Arr(name)!.Select(c => (JsonObject)c!);

    [Fact]
    public void Constants()
    {
        var c = Crypto.Obj("constants")!;
        Assert.Equal(28, c.Int("sealedOverhead"));
        Assert.Equal(E2e.SealedOverhead, c.Int("sealedOverhead"));
        Assert.Equal(E2e.EnvelopeVersion, c.Int("envelopeVersion"));
        Assert.Equal(ChannelKey.Length, c.Int("keyLength"));
        Assert.Equal(12 + 16, c.Int("nonceLength") + c.Int("tagLength"));
    }

    [Fact]
    public void KeysSpellBothWays()
    {
        foreach (var (name, node) in Crypto.Obj("keys")!)
        {
            var k = (JsonObject)node!;
            var key = new ChannelKey(Vectors.Hex(k["hex"]));
            Assert.Equal(k.Str("base64"), key.ToBase64());
            Assert.Equal(k.Str("base64url"), key.ToBase64Url());
            Assert.Equal(key, ChannelKey.TryParse(k.Str("base64")));
            Assert.Equal(key, ChannelKey.TryParse(k.Str("base64url")));
        }
    }

    [Fact]
    public void KeyParse()
    {
        foreach (var c in Cases("keyParse"))
        {
            var key = ChannelKey.TryParse(c.Str("input"));
            Assert.True(c.Str("hex") == (key == null ? null : Convert.ToHexString(key.Bytes).ToLowerInvariant()), c.Str("note"));
        }
    }

    [Fact]
    public void Aad()
    {
        foreach (var c in Cases("aad"))
        {
            var args = c.Arr("args")!.Select(a => DartJson.AsString(a)!).ToArray();
            var aad = c.Str("fn") switch
            {
                "channel" => E2e.ChannelAad(args[0], args[1]),
                "image" => E2e.ImageAad(args[0]),
                "push" => E2e.PushAad(args[0]),
                "activity" => E2e.ActivityAad(args[0]),
                var fn => throw new InvalidOperationException(fn),
            };
            Assert.Equal(c.Str("aad"), aad);
        }
    }

    [Fact]
    public void Tags()
    {
        foreach (var c in Cases("pushTag")) Assert.Equal(c.Str("tag"), E2e.PushTag(Key(c["key"])));
        foreach (var c in Cases("sessionTag")) Assert.Equal(c.Str("tag"), E2e.SessionTag(Key(c["key"]), c.Str("routedKey")!));
    }

    [Fact]
    public void Open()
    {
        foreach (var c in Cases("open"))
        {
            var plain = E2e.OpenBytes(Key(c["key"]), Vectors.Bytes(c["sealed"]), c.Str("aad")!);
            Assert.True(plain != null, c.Str("note"));
            Assert.Equal(Vectors.Bytes(c["plain"]), plain);
        }
    }

    [Fact]
    public void SealFixedNonce()
    {
        foreach (var c in Cases("sealFixedNonce"))
        {
            var sealedBytes = E2e.SealBytes(Key(c["key"]), Vectors.Bytes(c["plain"]), c.Str("aad")!, Vectors.Bytes(c["nonce"]));
            Assert.True(c.Str("sealed") == Convert.ToBase64String(sealedBytes), c.Str("note"));
        }
    }

    [Fact]
    public void OpenFails()
    {
        foreach (var c in Cases("openFails"))
        {
            var plain = E2e.OpenBytes(Key(c["key"]), Vectors.Bytes(c["sealed"]), c.Str("aad")!);
            Assert.True(c.Str("plain") == (plain == null ? null : Convert.ToBase64String(plain)), c.Str("note"));
        }
    }

    [Fact]
    public void Envelopes()
    {
        foreach (var c in Cases("envelopes"))
        {
            Assert.Equal(c.Str("aad"), E2e.ChannelAad(c.Str("topic")!, c.Str("event")!));
            var (message, drop) = E2e.OpenEnvelope(Key(c["key"]), c.Obj("envelope")!, c.Str("aad")!);
            Assert.True(drop == null, c.Str("note"));
            Vectors.AssertJson(c["message"], message, c.Str("note"));
            // And what this side seals, the other side's code opens the same way.
            var resealed = E2e.SealEnvelope(Key(c["key"]), message!, c.Str("aad")!);
            Assert.Equal(["v", "n", "c"], resealed.Select(p => p.Key));
            Vectors.AssertJson(message, E2e.OpenEnvelope(Key(c["key"]), resealed, c.Str("aad")!).Message);
        }
    }

    [Fact]
    public void EnvelopeDrops()
    {
        foreach (var c in Cases("envelopeDrops"))
        {
            var (message, drop) = E2e.OpenEnvelope(Key(c["key"]), c.Obj("envelope")!, c.Str("aad")!);
            Assert.True(c.Str("drop") == drop, $"{c.Str("note")}: {drop}");
            Vectors.AssertJson(c["message"], message, c.Str("note"));
        }
    }

    [Fact]
    public void ChannelOpen()
    {
        var rows = Cases("channelOpen").ToList();
        var now = DateTimeOffset.FromUnixTimeMilliseconds(rows[0].Int("startMs")!.Value);
        var receiver = new ChannelSeal(Key(JsonValue.Create("key")), "abcd1234", clock: () => now);
        foreach (var c in rows.Skip(1))
        {
            now = DateTimeOffset.FromUnixTimeMilliseconds(c.Int("nowMs")!.Value);
            var payload = receiver.Open(c.Str("event")!, c.Obj("envelope")!);
            Vectors.AssertJson(c["payload"], payload, c.Str("note"));
        }
    }

    [Fact]
    public void NoticesAndActivities()
    {
        foreach (var (section, push) in new[] { ("notices", true), ("activities", false) })
        {
            foreach (var c in Cases(section))
            {
                var key = Key(c["key"]);
                var desktop = c.Str("desktop")!;
                Assert.Equal(c.Str("aad"), push ? E2e.PushAad(desktop) : E2e.ActivityAad(desktop));
                var opened = E2e.OpenBytes(key, Vectors.Bytes(c["enc"]), c.Str("aad")!);
                Assert.True(opened != null, c.Str("note"));
                var inner = (JsonObject)DartJson.Decode(Encoding.UTF8.GetString(opened!))!;
                Vectors.AssertJson(c["inner"], inner, c.Str("note"));
                if (!push) Assert.Null(E2e.OpenBytes(key, Vectors.Bytes(c["enc"]), E2e.PushAad(desktop)));

                // This side's seal: the input plus a fresh ts and a 16-character id.
                var mine = push ? E2e.SealNotice(key, desktop, c.Obj("input")!) : E2e.SealActivity(key, desktop, c.Obj("input")!);
                var back = (JsonObject)DartJson.Decode(Encoding.UTF8.GetString(E2e.OpenBytes(key, Convert.FromBase64String(mine), c.Str("aad")!)!))!;
                Assert.Equal(16, back.Str("id")!.Length);
                Assert.True(Math.Abs(back.Int("ts")!.Value - DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()) < 5000);
                back.Remove("ts");
                back.Remove("id");
                Vectors.AssertJson(c["input"], back);
            }
        }
    }

    [Fact]
    public void Images()
    {
        foreach (var c in Cases("images"))
        {
            Assert.Equal(c.Str("aad"), E2e.ImageAad(c.Str("path")!));
            Assert.Equal(Vectors.Bytes(c["plain"]), E2e.OpenBytes(Key(c["key"]), Vectors.Bytes(c["sealed"]), c.Str("aad")!));
            var other = E2e.OpenBytes(Key(c["key"]), Vectors.Bytes(c["sealed"]), E2e.ImageAad(c.Str("path") + "x"));
            Assert.Equal(c.Bool("opensWithOtherPath"), other != null);
        }
    }

    [Fact]
    public void ReplayGuardScenarios()
    {
        foreach (var node in Vectors.Section("replayGuard").Arr("scenarios")!)
        {
            var s = (JsonObject)node!;
            var now = DateTimeOffset.FromUnixTimeMilliseconds(s.Int("startMs")!.Value);
            var guard = new ReplayGuard(
                window: TimeSpan.FromMilliseconds(s.Int("windowMs")!.Value),
                remember: TimeSpan.FromMilliseconds(s.Int("rememberMs")!.Value),
                maxEpochs: (int)s.Int("maxEpochs")!.Value,
                maxIds: (int)s.Int("maxIds")!.Value,
                clock: () => now);
            foreach (var stepNode in s.Arr("steps")!)
            {
                var step = (JsonObject)stepNode!;
                now = DateTimeOffset.FromUnixTimeMilliseconds(step.Int("nowMs")!.Value);
                var result = guard.Check(step.Obj("message")!);
                Assert.True(step.Str("result") == result, $"{s.Str("note")} / {step.Str("note")}: {result}");
            }
        }
    }
}
