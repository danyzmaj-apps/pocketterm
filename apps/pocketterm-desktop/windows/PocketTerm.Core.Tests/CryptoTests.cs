using System.Text;
using System.Text.Json.Nodes;

namespace PocketTerm.Core.Tests;

/// <summary>packages/pocketterm_core/test/e2e_test.dart.</summary>
public class CryptoTests
{
    private static readonly ChannelKey Key = new(Enumerable.Range(0, 32).Select(i => (byte)i).ToArray());
    private static readonly ChannelKey Other = new(Enumerable.Range(0, 32).Select(i => (byte)(255 - i)).ToArray());
    private const string Topic = "abcd1234";

    private static JsonObject J(string json) => (JsonObject)DartJson.Decode(json)!;

    [Fact]
    public void SealedBytesOpenWithTheSameKeyAndPurpose()
    {
        var plain = Encoding.UTF8.GetBytes("a photo, really");
        var sealedBytes = E2e.SealBytes(Key, plain, E2e.ImageAad("u1/x"));
        Assert.Equal(12 + plain.Length + 16, sealedBytes.Length);
        Assert.DoesNotContain("photo", Encoding.UTF8.GetString(sealedBytes));
        Assert.Equal(plain, E2e.OpenBytes(Key, sealedBytes, E2e.ImageAad("u1/x")));
    }

    [Fact]
    public void TwoSealsDiffer() =>
        Assert.NotEqual(E2e.SealBytes(Key, [1, 2, 3], E2e.PushAad(Topic)), E2e.SealBytes(Key, [1, 2, 3], E2e.PushAad(Topic)));

    [Fact]
    public void AChangedByteAnywhereOpensToNothing()
    {
        var sealedBytes = E2e.SealBytes(Key, Encoding.UTF8.GetBytes("hello there"), E2e.ImageAad("u1/x"));
        foreach (var i in new[] { 0, 11, 12, sealedBytes.Length - 17, sealedBytes.Length - 1 })
        {
            var changed = (byte[])sealedBytes.Clone();
            changed[i] ^= 1;
            Assert.Null(E2e.OpenBytes(Key, changed, E2e.ImageAad("u1/x")));
        }
        Assert.Null(E2e.OpenBytes(Key, sealedBytes.AsSpan(0, 27), E2e.ImageAad("u1/x")));
    }

    [Fact]
    public void AnotherKeyOrPurposeOpensToNothing()
    {
        var sealedBytes = E2e.SealBytes(Key, [1, 2, 3], E2e.ImageAad("u1/x"));
        Assert.Null(E2e.OpenBytes(Other, sealedBytes, E2e.ImageAad("u1/x")));
        Assert.Null(E2e.OpenBytes(Key, sealedBytes, E2e.ImageAad("u1/y")));
        Assert.Null(E2e.OpenBytes(Key, sealedBytes, E2e.PushAad(Topic)));
    }

    [Fact]
    public void EnvelopesRoundTripAndDrop()
    {
        var env = E2e.SealEnvelope(Key, J("""{"a":1,"b":"two"}"""), E2e.ChannelAad(Topic, "state"));
        Assert.DoesNotContain("two", DartJson.Encode(env));
        Vectors.AssertJson(J("""{"a":1,"b":"two"}"""), E2e.OpenEnvelope(Key, env, E2e.ChannelAad(Topic, "state")).Message);

        Assert.Equal("sealed", E2e.OpenEnvelope(Key, env, E2e.ChannelAad(Topic, "run")).Drop);
        Assert.Equal("sealed", E2e.OpenEnvelope(Key, env, E2e.ChannelAad("zzzz9999", "state")).Drop);
        var c = Convert.FromBase64String(env.Str("c")!);
        c[0] ^= 1;
        var changed = (JsonObject)env.DeepClone();
        changed["c"] = Convert.ToBase64String(c);
        Assert.Equal("sealed", E2e.OpenEnvelope(Key, changed, E2e.ChannelAad(Topic, "state")).Drop);
        var v2 = (JsonObject)env.DeepClone();
        v2["v"] = 2;
        Assert.Equal("version", E2e.OpenEnvelope(Key, v2, E2e.ChannelAad(Topic, "state")).Drop);
        Assert.Equal("version", E2e.OpenEnvelope(Key, J("""{"windows":3}"""), E2e.ChannelAad(Topic, "state")).Drop);
        var badN = (JsonObject)env.DeepClone();
        badN["n"] = "not base64!";
        Assert.Equal("sealed", E2e.OpenEnvelope(Key, badN, E2e.ChannelAad(Topic, "state")).Drop);
    }

    /// <summary>The live channel group: two sides on one test clock.</summary>
    public class LiveChannel
    {
        private DateTimeOffset _now = new(2026, 10, 22, 12, 0, 0, TimeSpan.Zero);
        private readonly ChannelSeal _phone;
        private readonly ChannelSeal _desktop;

        public LiveChannel()
        {
            _phone = new ChannelSeal(Key, Topic, clock: Clock);
            _desktop = new ChannelSeal(Key, Topic, clock: Clock);
        }

        private DateTimeOffset Clock() => _now;

        [Fact]
        public void BothWays()
        {
            Vectors.AssertJson(J("""{"from":"p1"}"""), _desktop.Open("hello", _phone.Seal("hello", J("""{"from":"p1"}"""))));
            Vectors.AssertJson(J("""{"windows":[]}"""), _phone.Open("state", _desktop.Seal("state", J("""{"windows":[]}"""))));
        }

        [Fact]
        public void APayloadsOwnSeqTsMidAndEpComeThrough()
        {
            var items = J("""{"session":"s1","epoch":"e1","seq":42,"ts":7,"mid":"m","ep":"x","items":[]}""");
            Vectors.AssertJson(items, _phone.Open("items", _desktop.Seal("items", items)));
        }

        [Fact]
        public void TheComputerTakesAPhoneMessageOnce()
        {
            var wire = _phone.Seal("run", J("""{"id":"r1","op":"send"}"""));
            Assert.NotNull(_desktop.Open("run", wire));
            Assert.Null(_desktop.Open("run", wire));
            _now += TimeSpan.FromMinutes(3);
            Assert.Null(_desktop.Open("run", wire));
        }

        [Fact]
        public void AMessageMoreThanFiveMinutesOffIsDroppedEitherWay()
        {
            var fromPhone = _phone.Seal("hello", J("""{"from":"p1"}"""));
            var fromDesktop = _desktop.Seal("state", J("""{"windows":1}"""));
            _now += TimeSpan.FromSeconds(5 * 60 + 1);
            Assert.Null(_desktop.Open("hello", fromPhone));
            Assert.Null(_phone.Open("state", fromDesktop));
        }

        [Fact]
        public void AnotherComputersKeyIsDropped()
        {
            var stranger = new ChannelSeal(Other, Topic, clock: Clock);
            Assert.Null(_desktop.Open("hello", stranger.Seal("hello", J("""{"from":"p1"}"""))));
        }

        [Fact]
        public void APhoneCommandReplayedToTheNextChannelIsDropped()
        {
            var guard = new ReplayGuard(clock: Clock);
            var first = new ChannelSeal(Key, Topic, guard: guard, clock: Clock);
            var wire = _phone.Seal("run", J("""{"id":"r1","op":"send"}"""));
            Assert.NotNull(first.Open("run", wire));
            _now += TimeSpan.FromMinutes(1);
            var next = new ChannelSeal(Key, Topic, guard: guard, clock: Clock);
            Assert.Null(next.Open("run", wire));
            Vectors.AssertJson(J("""{"id":"r2"}"""), next.Open("run", _phone.Seal("run", J("""{"id":"r2"}"""))));
        }

        [Fact]
        public void AMessageSealedBeforeTheAppStartedIsDropped()
        {
            var wire = _phone.Seal("run", J("""{"id":"r1","op":"send"}"""));
            _now += TimeSpan.FromSeconds(30);
            var restarted = new ChannelSeal(Key, Topic, clock: Clock);
            Assert.Null(restarted.Open("run", wire));
            Vectors.AssertJson(J("""{"id":"r2"}"""), restarted.Open("run", _phone.Seal("run", J("""{"id":"r2"}"""))));
        }

        [Fact]
        public void ThePhoneDropsReplayedOrOutOfOrder()
        {
            var first = _desktop.Seal("screen", J("""{"n":1}"""));
            var second = _desktop.Seal("screen", J("""{"n":2}"""));
            var third = _desktop.Seal("ran", J("""{"id":"r1"}"""));
            Vectors.AssertJson(J("""{"n":2}"""), _phone.Open("screen", second));
            Assert.Null(_phone.Open("screen", first));
            Assert.Null(_phone.Open("screen", second));
            Vectors.AssertJson(J("""{"id":"r1"}"""), _phone.Open("ran", third));
            Assert.Null(_phone.Open("ran", third));
        }

        [Fact]
        public void ASenderThatStartsAgainGoesThrough()
        {
            var guard = new ReplayGuard(clock: Clock);
            var computer = new ChannelSeal(Key, Topic, guard: guard, clock: Clock);
            var old = _phone.Seal("run", J("""{"id":"r1"}"""));
            Assert.NotNull(computer.Open("run", old));
            var relaunched = new ChannelSeal(Key, Topic, clock: Clock);
            Vectors.AssertJson(J("""{"from":"p1"}"""), computer.Open("hello", relaunched.Seal("hello", J("""{"from":"p1"}"""))));
            Vectors.AssertJson(J("""{"id":"r2"}"""), computer.Open("run", relaunched.Seal("run", J("""{"id":"r2"}"""))));
            Assert.Null(computer.Open("run", old));
            Vectors.AssertJson(J("""{"id":"r3"}"""), computer.Open("run", _phone.Seal("run", J("""{"id":"r3"}"""))));
        }

        [Fact]
        public void AMessageWithoutEpochAndCountIsDropped()
        {
            var env = E2e.SealEnvelope(Key, new JsonObject
            {
                ["id"] = "r1",
                ["ts"] = _now.ToUnixTimeMilliseconds(),
                ["mid"] = E2e.NewMessageId(),
            }, E2e.ChannelAad(Topic, "run"));
            Assert.Null(_desktop.Open("run", env));
        }

        [Fact]
        public void EpochsPastTheLimitAreForgottenOldestFirst()
        {
            var guard = new ReplayGuard(clock: Clock, maxEpochs: 2);
            JsonObject Msg(string ep, int seq) => new()
            {
                ["ts"] = _now.ToUnixTimeMilliseconds(),
                ["mid"] = E2e.NewMessageId(),
                ["ep"] = ep,
                ["seq"] = seq,
            };
            foreach (var ep in new[] { "a", "b", "c" }) Assert.Null(guard.Check(Msg(ep, 5)));
            Assert.Equal("order", guard.Check(Msg("c", 5)));
            Assert.Equal("order", guard.Check(Msg("b", 4)));
            Assert.Null(guard.Check(Msg("a", 1)));
        }
    }

    [Fact]
    public void ASealedPushOpensForThatComputersPhones()
    {
        var before = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var a = E2e.SealNotice(Key, Topic, J("""{"title":"Claude","body":"Needs approval"}"""));
        var b = E2e.SealNotice(Key, Topic, J("""{"title":"Claude","body":"Needs approval"}"""));
        var opened = J(Encoding.UTF8.GetString(E2e.OpenBytes(Key, Convert.FromBase64String(a), E2e.PushAad(Topic))!));
        var again = J(Encoding.UTF8.GetString(E2e.OpenBytes(Key, Convert.FromBase64String(b), E2e.PushAad(Topic))!));
        Assert.Equal("Claude", opened.Str("title"));
        Assert.True(opened.Int("ts") >= before);
        Assert.NotEqual(opened.Str("id"), again.Str("id"));
        Assert.Null(E2e.OpenBytes(Key, Convert.FromBase64String(a), E2e.PushAad("zzzz9999")));
        var activity = E2e.SealActivity(Key, Topic, J("""{"session":"s1","state":"working"}"""));
        Assert.Null(E2e.OpenBytes(Key, Convert.FromBase64String(activity), E2e.PushAad(Topic)));
        Assert.NotNull(E2e.OpenBytes(Key, Convert.FromBase64String(activity), E2e.ActivityAad(Topic)));
    }

    [Fact]
    public void AKeyReadsBackFromBothSpellings()
    {
        Assert.Equal(Key, ChannelKey.TryParse(Key.ToBase64()));
        Assert.Equal(Key, ChannelKey.TryParse(Key.ToBase64Url()));
        Assert.DoesNotContain("=", Key.ToBase64Url());
        Assert.Null(ChannelKey.TryParse(Convert.ToBase64String(Enumerable.Repeat((byte)1, 16).ToArray())));
        Assert.Null(ChannelKey.TryParse("not a key"));
        Assert.Null(ChannelKey.TryParse(null));
        Assert.NotEqual(ChannelKey.Generate(), ChannelKey.Generate());
    }

    [Fact]
    public void DartJsonWritesAsDartDoes()
    {
        Assert.Equal("""{"a":"é😀\u0001\n\"\\/","b":[1,1.5,1.0,null,true]}""",
            DartJson.Encode(new JsonObject { ["a"] = "é😀\u0001\n\"\\/", ["b"] = new JsonArray(1, 1.5, 1.0, null, true) }));
        Assert.Equal("\"\\ud800x\"", DartJson.Encode(JsonValue.Create("\ud800x")));
        Assert.Equal("1e+21", DartJson.FormatDouble(1e21));
        Assert.Equal("100000000000000000000.0", DartJson.FormatDouble(1e20));
        Assert.Equal("1e-7", DartJson.FormatDouble(1e-7));
        Assert.Equal("0.000001", DartJson.FormatDouble(1e-6));
        Assert.Equal("-2.5", DartJson.FormatDouble(-2.5));
        Assert.Null(DartJson.AsInt(DartJson.Decode("1.0")));
        Assert.Equal(3, DartJson.AsInt(DartJson.Decode("3")));
        Assert.Equal("1.0", DartJson.Encode(DartJson.Decode("1.0")));
    }
}
