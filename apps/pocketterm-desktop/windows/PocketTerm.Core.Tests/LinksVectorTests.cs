using System.Text.Json.Nodes;

namespace PocketTerm.Core.Tests;

/// <summary>tool/vectors: the <c>links</c> and <c>desktops</c> sections.</summary>
public class LinksVectorTests
{
    private static readonly JsonObject Links = Vectors.Section("links");

    private static IEnumerable<JsonObject> Cases(string name) => Links.Arr(name)!.Select(c => (JsonObject)c!);

    [Fact]
    public void Parse()
    {
        foreach (var c in Cases("parse"))
        {
            var (backend, error) = Backend.Parse(c.Str("input")!);
            Assert.True(c.Str("error") == error, $"{c.Str("note")}: {error}");
            if (c.Obj("backend") is not { } b)
            {
                Assert.Null(backend);
                continue;
            }
            Assert.NotNull(backend);
            Assert.Equal(b.Str("url"), backend.Url);
            Assert.Equal("pocketterm", b.Str("kind"));
            Assert.Equal(b.Str("api"), backend.Api);
            Assert.Equal(b.Str("host"), backend.Host);
            Assert.Equal(b.Bool("onTailnet"), backend.OnTailnet);
            Assert.Equal(b.Str("unreachable"), backend.Unreachable);
        }
    }

    [Fact]
    public void Build()
    {
        foreach (var c in Cases("build"))
        {
            var b = c.Obj("backend")!;
            var backend = new Backend(b.Str("url")!);
            var computer = c.Obj("computer") is { } k ? new ComputerKey(k.Str("desktop")!, new ChannelKey(Vectors.Hex(k["keyHex"]))) : null;
            var link = c.Str("fn") switch
            {
                "link" => backend.Link,
                "linkWithSetup" => backend.LinkWithSetup(c.Str("setup")!),
                "linkWithCode" => backend.LinkWithCode(c.Str("code")!, computer),
                var fn => throw new InvalidOperationException(fn),
            };
            Assert.True(c.Str("link") == link, $"{c.Str("note")}: {link}");
            // Every link made reads back as what made it.
            Assert.Equal(backend, Backend.FromLink(link));
        }
    }

    [Fact]
    public void Read()
    {
        foreach (var c in Cases("read"))
        {
            var uri = DartUri.Parse(c.Str("link")!);
            var note = c.Str("note");
            var backend = Backend.FromLink(uri);
            if (c.Obj("backend") is { } b)
            {
                Assert.True(backend != null, note);
                Assert.Equal(b.Str("url"), backend.Url);
                Assert.Equal("pocketterm", b.Str("kind"));
            }
            else
            {
                Assert.True(backend == null, note);
            }
            Assert.True(c.Str("pairingCode") == Backend.PairingCode(uri), note);
            Assert.True(c.Str("setupToken") == Backend.SetupToken(uri), note);
            var key = Backend.ComputerKey(uri);
            if (c.Obj("computerKey") is { } k)
            {
                Assert.True(key != null, note);
                Assert.Equal(k.Str("desktop"), key.Desktop);
                Assert.Equal(k.Str("keyHex"), Convert.ToHexString(key.Key.Bytes).ToLowerInvariant());
            }
            else
            {
                Assert.True(key == null, note);
            }
        }
    }

    [Fact]
    public void ClockWarning()
    {
        foreach (var c in Cases("clockWarning"))
        {
            TimeSpan? offset = c.Int("offsetSeconds") is { } s ? TimeSpan.FromSeconds(s) : null;
            Assert.True(c.Str("warning") == Backend.ClockWarning(offset), $"{c.Str("note")}: {Backend.ClockWarning(offset)}");
        }
    }

    [Fact]
    public void Constants()
    {
        var c = Links.Obj("constants")!;
        Assert.Equal(c.Int("protocol"), Backend.Protocol);
        Assert.Equal(Backend.MinServer, c.Str("minServer"));
        Assert.Equal(c.Int("clockToleranceSeconds"), (long)Backend.ClockTolerance.TotalSeconds);
    }

    [Fact]
    public void Desktops()
    {
        var d = Vectors.Section("desktops");
        Assert.Equal(d.Int("onlineWithinSeconds"), (long)Desktop.OnlineWithin.TotalSeconds);
        Assert.Equal(d.Int("keepForDays"), (long)Core.Desktops.KeepFor.TotalDays);
        foreach (var node in d.Arr("cases")!)
        {
            var c = (JsonObject)node!;
            var desktop = Desktop.FromJson(c.Obj("input")!);
            Vectors.AssertJson(c["output"], desktop.ToJson(), c.Str("note"));
            Assert.Equal(c.Bool("windows"), desktop.Windows);
        }
    }
}
