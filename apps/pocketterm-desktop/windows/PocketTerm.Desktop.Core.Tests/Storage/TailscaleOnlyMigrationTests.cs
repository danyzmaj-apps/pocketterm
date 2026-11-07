using PocketTerm.Core;

namespace PocketTerm.Desktop.Tests;

/// <summary>Upgrading to the Tailscale-only PocketTerm: Supabase and VPS sign-ins go, once; the rest stays.</summary>
public sealed class TailscaleOnlyMigrationTests
{
    private static readonly Account Signed = new("server-1", new Device("device-1", DeviceRole.Desktop, "PC", "windows"));

    private sealed record Run(MemoryPreferenceStore Prefs, MemoryDeviceTokens Tokens, List<FakeServer> Servers, bool SignedOut);

    private static async Task<Run> Migrate(Action<MemoryPreferenceStore> saved)
    {
        var prefs = new MemoryPreferenceStore();
        saved(prefs);
        var tokens = new MemoryDeviceTokens { Value = "token" };
        var servers = new List<FakeServer>();
        var signedOut = await TailscaleOnlyMigration.RunAsync(prefs, tokens, (b, _) =>
        {
            var s = new FakeServer(b, Signed);
            servers.Add(s);
            return s;
        });
        return new(prefs, tokens, servers, signedOut);
    }

    [Fact]
    public async Task AVpsSignInLeavesTheServerAndOpensSetupWithTheNote()
    {
        var run = await Migrate(p =>
        {
            p.SetString("backend_url", "https://pocketterm.example.com");
            p.SetString("setup_step", "haveServer");
        });
        Assert.True(run.SignedOut);
        // Told the VPS it's gone (DELETE /v1/devices/me).
        Assert.Null(Assert.Single(run.Servers).Account);
        Assert.Null(run.Tokens.Value);
        Assert.Null(Backend.Load(run.Prefs));
        Assert.Null(run.Prefs.GetString("backend_url"));
        Assert.Null(run.Prefs.GetString("setup_step"));
        Assert.True(run.Prefs.GetBool(TailscaleOnlyMigration.NoteKey));
    }

    [Fact]
    public async Task ASupabaseSignInIsOnlyForgotten()
    {
        var run = await Migrate(p =>
        {
            p.SetString("backend_url", "https://abcdefghijklmnop.supabase.co");
            p.SetString("backend_kind", "supabase");
        });
        Assert.True(run.SignedOut);
        Assert.Empty(run.Servers);
        Assert.Null(run.Tokens.Value);
        Assert.Null(run.Prefs.GetString("backend_url"));
        Assert.Null(run.Prefs.GetString("backend_kind"));
        Assert.True(run.Prefs.GetBool(TailscaleOnlyMigration.NoteKey));
    }

    [Theory]
    [InlineData("https://my-pc.tail1234.ts.net", false)]
    [InlineData("http://127.0.0.1:47900", true)]
    public async Task ItsOwnServerOrAnotherComputersOverTailscaleStays(string url, bool hosting)
    {
        var run = await Migrate(p =>
        {
            p.SetString("backend_url", url);
            if (hosting) p.SetBool("hosting", true);
        });
        Assert.False(run.SignedOut);
        Assert.Empty(run.Servers);
        Assert.Equal("token", run.Tokens.Value);
        Assert.Equal(url, Backend.Load(run.Prefs)?.Url);
        Assert.Null(run.Prefs.GetBool(TailscaleOnlyMigration.NoteKey));
    }

    [Fact]
    public async Task ItRunsOnce()
    {
        var run = await Migrate(_ => { });
        Assert.False(run.SignedOut);
        Assert.True(run.Prefs.GetBool(TailscaleOnlyMigration.DoneKey));
        // A server saved later (not possible from setup, but say a restore) is left alone.
        run.Prefs.SetString("backend_url", "https://pocketterm.example.com");
        Assert.False(await TailscaleOnlyMigration.RunAsync(run.Prefs, run.Tokens));
        Assert.NotNull(Backend.Load(run.Prefs));
    }

    [Fact]
    public async Task AppStartSignsOutAndSetupShowsTheNoteOnce()
    {
        using var app = TestApp.Create(new Dictionary<string, object>
        {
            ["backend_url"] = "https://pocketterm.example.com",
            [TailscaleOnlyMigration.DoneKey] = false,
        });
        await app.Start();
        Assert.Null(app.User);
        Assert.Null(app.Backend);
        Assert.Equal(TailscaleOnlyMigration.Note, app.MigrationNote);
        app.DismissMigrationNote();
        Assert.Null(app.MigrationNote);
    }
}

/// <summary>Join another computer's PocketTerm: only a PocketTerm on Tailscale, except in test builds.</summary>
public sealed class SetupLinksTests
{
    [Theory]
    [InlineData("https://pocketterm.example.com")]
    [InlineData("http://127.0.0.1:47900")]
    [InlineData("https://abcdefghijklmnop.supabase.co")]
    public void AReleaseBuildTakesOnlyTailscale(string url)
    {
        var link = new Backend(url).LinkWithSetup("tok");
        Assert.Equal(SetupLinks.NotTailscale, SetupLinks.Problem(link));
        Assert.Null(SetupLinks.Problem(new Backend("https://my-pc.tail1234.ts.net").LinkWithSetup("tok")));
    }

    [Fact]
    public void ATestBuildTakesAnyServer()
    {
        Assert.Null(SetupLinks.Problem(new Backend("http://127.0.0.1:47900").LinkWithSetup("tok"), anyServer: true));
        Assert.Null(SetupLinks.Problem(new Backend("https://pocketterm.example.com").LinkWithSetup("tok"), anyServer: true));
    }

    [Fact]
    public void ASupabaseLinkIsNoLongerOne()
    {
        const string link = "pocketterm://setup?kind=supabase&url=https%3A%2F%2Fabcdefghijklmnop.supabase.co&setup=tok";
        Assert.Equal(SetupLinks.NotTailscale, SetupLinks.Problem(link));
        Assert.Equal(SetupLinks.NotTailscale, SetupLinks.Problem(link, anyServer: true));
    }

    [Fact]
    public void APhonesCodeIsNotAComputersLink()
    {
        var link = new Backend("https://my-pc.tail1234.ts.net").LinkWithCode("code");
        Assert.Contains("signs in a phone", SetupLinks.Problem(link));
    }
}
