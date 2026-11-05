using System.Text;
using System.Text.Json.Nodes;
using Microsoft.AspNetCore.Http;

namespace PocketTerm.Core.Tests;

/// <summary>packages/pocketterm_core/test/backend_test.dart (what the vectors don't pin) and desktops_test.dart.</summary>
public class BackendTests
{
    /// <summary>A server on a free port that answers every request with <paramref name="answer"/>.</summary>
    private static Task<FakeHttp> Answering(RequestDelegate answer) => FakeHttp.Start(answer);

    [Fact]
    public async Task AnythingElseAnsweringIsNamed()
    {
        await using var other = await Answering(ctx => ctx.Response.WriteAsync("<html>hello</html>"));
        Assert.Contains("No PocketTerm server", await new Backend(other.Url).Check());
    }

    [InteropFact]
    public async Task APocketTermServerPassesAndItsClockIsClose()
    {
        await using var own = await DartServer.Start();
        Assert.Null(await own.Backend.Check());
        var ok = await own.Backend.Health();
        Assert.Null(ok.Error);
        Assert.Null(Backend.ClockWarning(ok.ClockOffset));
    }

    [Fact]
    public async Task AServerThatDropsTheConnectionMidAnswerIsAMessage()
    {
        // Answers half a status line, then hangs up.
        using var server = new RawServer(async c =>
        {
            using (c)
            {
                await c.GetStream().WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 200"));
            }
        });
        Assert.Contains("Couldn't reach", await server.Backend.Check());
    }

    [Fact]
    public async Task AServerThatStallsTheBodyTimesOutWithAMessage()
    {
        await using var server = await FakeHttp.Start(async ctx =>
        {
            ctx.Response.ContentLength = 100;
            await ctx.Response.WriteAsync("""{"pocketterm":""");
            await ctx.Response.Body.FlushAsync();
            await Task.Delay(TimeSpan.FromSeconds(10), ctx.RequestAborted).ContinueWith(_ => { });
        });
        var health = await new Backend(server.Url).Health(TimeSpan.FromMilliseconds(300)).WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Contains("took too long to answer", health.Error);
    }

    [Fact]
    public async Task ADeviceWhoseClockIsOffIsTold()
    {
        await using var ahead = await Answering(ctx => ctx.Response.WriteAsync(DartJson.Encode(new JsonObject
        {
            ["pocketterm"] = 1,
            ["version"] = Backend.MinServer,
            ["time"] = DartDate.ToIso8601Utc(DateTimeOffset.UtcNow + TimeSpan.FromMinutes(10)),
        })));
        var skewed = await new Backend(ahead.Url).Health();
        Assert.Null(skewed.Error);
        Assert.InRange(skewed.ClockOffset!.Value.TotalMinutes, 9, 10.01);
        Assert.Contains("10 minutes behind", Backend.ClockWarning(skewed.ClockOffset));
        Assert.Contains("ahead of", Backend.ClockWarning(TimeSpan.FromMinutes(-3)));
        Assert.Null(Backend.ClockWarning(TimeSpan.FromSeconds(90)));
    }

    [Fact]
    public async Task AServerOlderThanThisAppNeedsSaysToUpdateIt()
    {
        await using var old = await Answering(ctx => ctx.Response.WriteAsync("""{"pocketterm":1,"version":"0.0.9"}"""));
        Assert.Contains("Update the server", await new Backend(old.Url).Check());
        await using var newer = await Answering(ctx => ctx.Response.WriteAsync("""{"pocketterm":1,"version":"0.10.0"}"""));
        Assert.Null(await new Backend(newer.Url).Check());
        await using var future = await Answering(ctx => ctx.Response.WriteAsync("""{"pocketterm":2}"""));
        Assert.Contains("newer than this app", await new Backend(future.Url).Check());
    }

    [Fact]
    public async Task CloudflareAndARedirectLoopAreNamed()
    {
        await using var cloudflare = await Answering(ctx =>
        {
            ctx.Response.StatusCode = 521;
            ctx.Response.Headers["cf-ray"] = "8a1b2c3d4e5f-FRA";
            return Task.CompletedTask;
        });
        Assert.Contains("Cloudflare", await new Backend(cloudflare.Url).Check());

        FakeHttp? loop = null;
        loop = await Answering(ctx =>
        {
            ctx.Response.StatusCode = 301;
            ctx.Response.Headers.Location = $"{loop!.Url}/v1/health";
            return Task.CompletedTask;
        });
        await using (loop)
        {
            Assert.Contains("redirecting", await new Backend(loop.Url).Check());
        }
    }

    [Fact]
    public void AComputersBackendIsInItsPreferences()
    {
        var backend = new Backend("https://pt.example.com");
        var supabase = new Backend("https://abcdefghijklmnop.supabase.co", BackendKind.Supabase);
        var prefs = new MemoryPreferenceStore();
        Assert.Null(Backend.Load(prefs));
        backend.Save(prefs);
        Assert.Equal(backend, Backend.Load(prefs));
        supabase.Save(prefs);
        Assert.Equal(supabase, Backend.Load(prefs));
        backend.Save(prefs);
        Assert.Equal(backend, Backend.Load(prefs));
        Backend.Clear(prefs);
        Assert.Null(Backend.Load(prefs));

        var before = new MemoryPreferenceStore();
        before.SetString("backend_url", "https://abc.supabase.co");
        before.SetString("backend_key", "sb_x");
        Assert.Null(Backend.Load(before));
    }

    [Fact]
    public void ATailscaleAddressSaysToConnectTailscale()
    {
        var tailnet = new Backend("https://my-mac.tail1234.ts.net");
        Assert.True(tailnet.OnTailnet);
        Assert.Contains("open Tailscale on this device", tailnet.Unreachable);
        var vps = new Backend("https://pocketterm.example.com");
        Assert.False(vps.OnTailnet);
        Assert.DoesNotContain("Tailscale", vps.Unreachable);
    }

    [Fact]
    public async Task NothingListeningIsTheBackendsOfflineAnswer()
    {
        int port;
        using (var closed = new RawServer(_ => Task.CompletedTask)) port = closed.Port;
        var client = new PocketTermServerClient(new Backend($"http://127.0.0.1:{port}"), new MemoryDeviceTokens());
        var e = await Assert.ThrowsAsync<ServerException>(() => client.RedeemCode("K7QM", "iPhone", "ios"));
        Assert.Equal(client.Backend.Unreachable, e.Message);
        Assert.Equal(0, e.Status);
    }

    [Fact]
    public async Task ARefusalThatLandsAfterTheClientClosedIsQuiet()
    {
        var tokens = new MemoryDeviceTokens
        {
            Value = """{"url":"http://127.0.0.1:9","token":"token-1","server":"srv0000000000001","device":{"id":"dev0000000000001","role":"phone","label":"iPhone","platform":"ios"}}""",
        };
        var client = new PocketTermServerClient(new Backend("http://127.0.0.1:9"), tokens);
        await client.Load();
        Assert.NotNull(client.Account);
        var ended = 0;
        client.Ended += (_, _) => ended++;
        client.Close();
        await client.Refused();
        Assert.Null(client.Account);
        Assert.Null(tokens.Value);
        Assert.Equal(0, ended);
    }

    [Fact]
    public async Task BackAtTheFrontRequestsGoOnNewConnections()
    {
        // Answers the first request on each connection, keeping it open, and then never another on it.
        var connections = 0;
        using var quiet = new RawServer(async c =>
        {
            Interlocked.Increment(ref connections);
            var s = c.GetStream();
            var buffer = new byte[4096];
            var answered = false;
            while (await s.ReadAsync(buffer) > 0)
            {
                if (answered) continue;
                answered = true;
                await s.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 2\r\n\r\n[]"));
            }
        });
        var client = new PocketTermServerClient(quiet.Backend, new MemoryDeviceTokens
        {
            Value = DartJson.Encode(new JsonObject
            {
                ["url"] = quiet.Backend.Url,
                ["token"] = "token-1",
                ["server"] = "srv0000000000001",
                ["device"] = new JsonObject { ["id"] = "dev0000000000001", ["role"] = "phone", ["label"] = "iPhone", ["platform"] = "ios" },
            }),
        });
        await client.Load();
        Assert.Empty(await client.Desktops());
        client.FreshConnections();
        Assert.Empty(await client.Desktops().WaitAsync(TimeSpan.FromSeconds(3)));
        Assert.Equal(2, connections);
        client.Close();
    }
}

/// <summary>packages/pocketterm_core/test/desktops_test.dart.</summary>
public class DesktopsTests
{
    private static readonly PocketTermServerClient Client = new(new Backend("http://localhost:1"), new MemoryDeviceTokens());

    private static JsonObject Row(string id, TimeSpan ago, string platform = "macos") => new()
    {
        ["id"] = id,
        ["name"] = $"Computer {id}",
        ["platform"] = platform,
        ["seen_at"] = DartDate.ToIso8601Utc(DateTimeOffset.UtcNow - ago),
    };

    [Fact]
    public void TheComputerLastShownStaysShownWhileListed()
    {
        var changes = new List<string?>();
        var d = new Desktops(Client, saved: "bbbbbbbb", onChanged: (_, id) => changes.Add(id));
        d.Apply([Row("aaaaaaaa", TimeSpan.Zero), Row("bbbbbbbb", TimeSpan.FromHours(2))]);
        Assert.Equal("bbbbbbbb", d.Selected?.Id);
        Assert.Equal(["bbbbbbbb"], changes);
    }

    [Fact]
    public void WithTheLastOneGoneTheNewestIsShownAndKept()
    {
        var d = new Desktops(Client, saved: "gone0000");
        d.Apply([Row("aaaaaaaa", TimeSpan.Zero), Row("bbbbbbbb", TimeSpan.FromMinutes(1))]);
        Assert.Equal("aaaaaaaa", d.Selected?.Id);
        d.Apply([Row("bbbbbbbb", TimeSpan.Zero), Row("aaaaaaaa", TimeSpan.FromMinutes(1))]);
        Assert.Equal("aaaaaaaa", d.Selected?.Id);
    }

    [Fact]
    public void NoneListedNoneShownThirtyDaysUnseenIsNotListed()
    {
        var d = new Desktops(Client);
        d.Apply([]);
        Assert.Null(d.Selected);
        d.Apply([Row("aaaaaaaa", TimeSpan.FromDays(31))]);
        Assert.Empty(d.All);
        Assert.Null(d.Selected);
    }

    [Fact]
    public void ThePersonPicksAListedComputerOnly()
    {
        var changes = new List<string?>();
        var d = new Desktops(Client, onChanged: (_, id) => changes.Add(id));
        d.Apply([Row("aaaaaaaa", TimeSpan.Zero), Row("bbbbbbbb", TimeSpan.Zero, platform: "windows")]);
        d.Select("bbbbbbbb");
        d.Select("cccccccc");
        Assert.Equal("bbbbbbbb", d.Selected?.Id);
        Assert.True(d.Selected?.Windows);
        Assert.Equal(["aaaaaaaa", "bbbbbbbb"], changes);
    }

    [Fact]
    public void AComputerAskedForIsShownOnceListed()
    {
        var d = new Desktops(Client);
        d.Apply([Row("aaaaaaaa", TimeSpan.Zero)]);
        d.Show("bbbbbbbb");
        Assert.Equal("aaaaaaaa", d.Selected?.Id);
        d.Apply([Row("cccccccc", TimeSpan.Zero), Row("bbbbbbbb", TimeSpan.FromMinutes(1))]);
        Assert.Equal("bbbbbbbb", d.Selected?.Id);
        d.Apply([Row("aaaaaaaa", TimeSpan.Zero), Row("bbbbbbbb", TimeSpan.FromMinutes(1))]);
        Assert.Equal("bbbbbbbb", d.Selected?.Id);
        d.Show("aaaaaaaa");
        Assert.Equal("aaaaaaaa", d.Selected?.Id);
    }

    [Fact]
    public void TheCachedListShowsTheComputerLastShown()
    {
        var cached = Desktop.FromJson(Row("bbbbbbbb", TimeSpan.FromMinutes(5)));
        var d = new Desktops(Client, cached: [cached], saved: "bbbbbbbb");
        Assert.False(d.Loaded);
        Assert.Equal(cached, d.Selected);
        Assert.Equal(cached, Desktop.FromJson(cached.ToJson()));
    }

    [Fact]
    public void OnlineMeansSeenWithinTwoAndAHalfMinutes()
    {
        Assert.True(Desktop.FromJson(Row("aaaaaaaa", TimeSpan.FromSeconds(140))).Online);
        Assert.False(Desktop.FromJson(Row("aaaaaaaa", TimeSpan.FromSeconds(160))).Online);
    }

    [InteropFact]
    public async Task AServerThatStopsAnsweringKeepsTheListAndSaysWhy()
    {
        await using var own = await DartServer.Start();
        var phone = await own.Phone(await own.Desktop());
        var cached = Desktop.FromJson(Row("bbbbbbbb", TimeSpan.FromMinutes(5)));
        var d = new Desktops(phone, cached: [cached], saved: "bbbbbbbb");
        var told = 0;
        d.PropertyChanged += (_, _) => told++;
        await own.StopServer();
        await d.Refresh();
        Assert.Equal(phone.Backend.Unreachable, d.Error);
        Assert.Equal(cached, d.Selected);
        Assert.Equal(1, told);
        await d.Refresh();
        Assert.Equal(1, told);
        d.Apply([Row("aaaaaaaa", TimeSpan.Zero)]);
        Assert.Null(d.Error);
    }

    [InteropFact]
    public async Task AListThatComesAfterThePhoneLeftIsNotKept()
    {
        await using var own = await DartServer.Start();
        var phone = await own.Phone(await own.Desktop());
        var kept = new List<IReadOnlyList<Desktop>>();
        var d = new Desktops(phone, onChanged: (all, _) => kept.Add(all));
        var refreshed = d.Refresh();
        d.Dispose();
        await refreshed;
        Assert.Empty(kept);
    }
}
