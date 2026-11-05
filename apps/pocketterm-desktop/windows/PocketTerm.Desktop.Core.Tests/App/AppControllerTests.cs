using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PocketTerm.Core;
using PocketTerm.Core.Tests;
using PocketTerm.Desktop;

namespace PocketTerm.Desktop.Tests;

public class AppControllerTests
{
    [Fact]
    public void KittysSocketsAreInTmpUnlessPocketTermKittyDirNamesAnotherDirectory()
    {
        Assert.Equal("/tmp", AppController.KittyDir(new Dictionary<string, string>()));
        Assert.Equal("/tmp", AppController.KittyDir(new Dictionary<string, string> { ["POCKETTERM_KITTY_DIR"] = "" }));
        Assert.Equal(
            "/tmp/pocketterm-e2e",
            AppController.KittyDir(new Dictionary<string, string> { ["POCKETTERM_KITTY_DIR"] = "/tmp/pocketterm-e2e" }));
    }

    [Fact]
    public async Task SignedOutNothingGoesToThePhoneAndTheComputerIsNotEvenAsked()
    {
        using var app = TestApp.Create();
        Assert.False(await app.NotifyPhoneAsync("omp finished · app", "Done.", session: "wezterm-1/1"));
        Assert.Empty(app.FakeHost.Calls);
    }

    [Fact]
    public async Task AtTheDeskInputWithinTheMinuteNothingGoesToThePhone()
    {
        using var app = TestApp.Create(new Dictionary<string, object> { ["first_sign_in_done"] = true });
        await app.SignedInAsync();
        app.FakeHost.Idle = 59;
        Assert.False(await app.NotifyPhoneAsync("omp finished · app", "Done."));
        Assert.Equal(["idleSeconds"], app.FakeHost.Calls);
        Assert.Empty(app.Pushes);
    }

    [Fact]
    public async Task APushGoesSealedOutsideTheSealOnlyTagsThatMeanNothingWithoutThisComputersKey()
    {
        using var app = TestApp.Create(new Dictionary<string, object> { ["first_sign_in_done"] = true });
        await app.SignedInAsync();
        app.FakeHost.Idle = 600;
        Assert.True(await app.NotifyPhoneAsync("omp finished · secret-project", "Fixed the login bug.", session: "wezterm-1/2"));

        var (action, body) = Assert.Single(app.Pushes);
        var desktop = app.DesktopId(app.User!.Id);
        var key = Backend.ComputerKey(DartUri.Parse(await app.PairingLink()))!.Key;
        Assert.Equal("notify", action);
        Assert.Equal(["collapse", "enc", "tag"], body.Select(p => p.Key).Order());
        // The phone finds this computer's key by its tag; a newer push for the session replaces this one.
        Assert.Equal(E2e.PushTag(key), body.Str("tag"));
        Assert.Equal(E2e.SessionTag(key, $"{desktop}/wezterm-1/2"), body.Str("collapse"));
        var wire = DartJson.Encode(body);
        foreach (var secret in new[] { "secret-project", "login", "finished", desktop, "wezterm-1/2" }) Assert.DoesNotContain(secret, wire);

        // A phone that scanned this computer's code opens it.
        var enc = Convert.FromBase64String(body.Str("enc")!);
        var opened = E2e.OpenBytes(key, enc, E2e.PushAad(desktop));
        var notice = (JsonObject)DartJson.Decode(Encoding.UTF8.GetString(opened!))!;
        Assert.Equal(["body", "id", "session", "title", "ts"], notice.Select(p => p.Key).Order());
        Assert.Equal("omp finished · secret-project", notice.Str("title"));
        Assert.Equal("Fixed the login bug.", notice.Str("body"));
        Assert.Equal($"{desktop}/wezterm-1/2", notice.Str("session"));
        // A phone refuses an old or repeated notice.
        Assert.InRange(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - notice.Int("ts")!.Value, 0, 60000);
        Assert.NotNull(notice.Str("id"));
        Assert.Null(E2e.OpenBytes(key, enc, E2e.PushAad("zzzz9999")));
    }

    [Fact]
    public async Task ResetKeyTheCodeCarriesANewKeyAndAPhoneWithTheOldOneCantOpenWhatComesNext()
    {
        using var app = TestApp.Create(new Dictionary<string, object> { ["first_sign_in_done"] = true });
        await app.SignedInAsync();
        app.FakeHost.Idle = 600;
        var old = Backend.ComputerKey(DartUri.Parse(await app.PairingLink()))!;
        Assert.Equal(old, Backend.ComputerKey(DartUri.Parse(await app.PairingLink()))); // the key stays until reset

        await app.ResetChannelKeyAsync();
        var fresh = Backend.ComputerKey(DartUri.Parse(await app.PairingLink()))!;
        Assert.Equal(old.Desktop, fresh.Desktop);
        Assert.NotEqual(old.Key, fresh.Key);

        await app.NotifyPhoneAsync("Claude Code needs you · app", "Allow?");
        var enc = Convert.FromBase64String(Assert.Single(app.Pushes).Body.Str("enc")!);
        Assert.Null(E2e.OpenBytes(old.Key, enc, E2e.PushAad(old.Desktop)));
        Assert.NotNull(E2e.OpenBytes(fresh.Key, enc, E2e.PushAad(old.Desktop)));
    }

    [Fact]
    public async Task TheFirstSignInTurnsOnTerminalFromPhoneOnceAndNeverAddsALoginItemOnItsOwn()
    {
        using var app = TestApp.Create();
        await app.SignedInAsync();
        await Wait.Until(() => app.Prefs.GetBool("first_sign_in_done") == true);
        Assert.True(app.TerminalOn);
        Assert.False(app.FakeHost.LoginItem);
        Assert.DoesNotContain("setLaunchAtLogin(true)", app.FakeHost.Calls);

        // Turned off again, it stays off at the next sign-in.
        await app.SetTerminalAsync(false);
        await app.SignOut();
        app.FakeHost.ClearCalls();
        await app.Connect(new Backend(TestApp.Url));
        await Wait.Until(() => app.User != null);
        Assert.False(app.TerminalOn);
        Assert.Empty(app.FakeHost.Calls);
    }

    [Fact]
    public async Task AComputerThatHadItsFirstSignInKeepsItsSettings()
    {
        using var app = TestApp.Create(new Dictionary<string, object> { ["first_sign_in_done"] = true });
        await app.SignedInAsync();
        Assert.False(app.TerminalOn);
        Assert.Empty(app.FakeHost.Calls);
    }

    [Fact]
    public async Task AtLaunchAComputerNotSetUpYetShowsItsWindow()
    {
        using var app = TestApp.Create();
        await app.Start();
        Assert.Equal(["start", "showMain"], app.FakeHost.Calls);
        Assert.Equal(1, app.MainShown);
    }

    [Fact]
    public async Task AtLaunchSignedInItStartsInTheBackground()
    {
        using var app = TestApp.Create(new Dictionary<string, object> { ["first_sign_in_done"] = true });
        new Backend(TestApp.Url).Save(app.Prefs);
        await app.Start();
        Assert.NotNull(app.User);
        Assert.Equal(["start"], app.FakeHost.Calls);
    }

    [Fact]
    public async Task TheHostsMenuItemsOpenTheWindowAndQuittingWaitsForOnQuit()
    {
        using var app = TestApp.Create(new Dictionary<string, object> { ["first_sign_in_done"] = true });
        new Backend(TestApp.Url).Save(app.Prefs);
        await app.Start();
        var quit = new TaskCompletionSource();
        app.OnQuit = () => quit.Task;
        app.FakeHost.ClearCalls();

        await app.FakeHost.OnEvent!("openSettings");
        await app.FakeHost.OnEvent!("mainClosed");
        Assert.Equal(["showMain"], app.FakeHost.Calls);
        Assert.True(app.MainHidden);

        var quitting = app.FakeHost.OnEvent!("quitting");
        await Task.Delay(50);
        Assert.False(quitting.IsCompleted);
        quit.SetResult();
        await quitting.WaitAsync(TimeSpan.FromSeconds(5));
    }

    [Fact]
    public void ThisComputersIdIsMadeOncePerUserInTheFormTheServerTakes()
    {
        using var app = TestApp.Create();
        var id = app.DesktopId("user-1");
        Assert.Matches(new Regex("^[a-z0-9]{8}$"), id);
        Assert.Equal(id, app.DesktopId("user-1"));
        Assert.NotEqual(id, app.DesktopId("user-2"));
    }

    [Fact]
    public void TheComputersNameFitsTheServers1To80Characters()
    {
        Assert.Equal("Ana’s PC", AppController.DesktopName("  Ana’s PC  "));
        Assert.Equal("Computer", AppController.DesktopName(" "));
        Assert.Equal(new string('x', 80), AppController.DesktopName(new string('x', 100)));
    }

    [Fact]
    public async Task APhoneHeardIsKeptPerServerAndForgottenWhenTheServerIsLeft()
    {
        using var app = TestApp.Create(new Dictionary<string, object> { ["first_sign_in_done"] = true });
        await app.SignedInAsync();
        Assert.Null(app.PhoneSignedIn);
        await app.CheckPhoneAsync();
        Assert.False(app.PhoneSignedIn);
        app.Servers[^1].DeviceList = [new Device("phone-1", DeviceRole.Phone, "iPhone", "ios")];
        await app.CheckPhoneAsync();
        Assert.True(app.PhoneSignedIn);
        Assert.True(app.Prefs.GetBool("phone_signed_in_server-1"));
        await app.SignOut();
        await Wait.Until(() => app.PhoneSignedIn == null);
    }

    [Fact]
    public async Task PreferencesKeepTheFlutterKeysAndDefaults()
    {
        using var app = TestApp.Create();
        Assert.Equal("auto", app.TerminalApp);
        Assert.Equal(Placement.ProjectWindow, app.Placement);
        Assert.Equal(Agent.Omp, app.CodingAgent);
        Assert.Empty(app.ProjectRoots);
        app.SetTerminalApp("wezterm");
        app.SetPlacement(Placement.NewWindow);
        app.SetCodingAgent(Agent.Claude);
        app.SetProjectRoots([@"C:\Users\me\code"]);
        app.SetSetupStep("vps");
        app.SetGetReadyDone(true);
        Assert.Equal("wezterm", app.Prefs.GetString("terminal_app"));
        Assert.Equal("newWindow", app.Prefs.GetString("session_placement"));
        Assert.Equal("claude", app.Prefs.GetString("coding_agent"));
        Assert.Equal([@"C:\Users\me\code"], app.Prefs.GetStringList("project_roots"));
        Assert.Equal("vps", app.Prefs.GetString("setup_step"));
        Assert.True(app.Prefs.GetBool("get_ready_done"));
        app.SetSetupStep(null);
        Assert.Null(app.SetupStep);
        await app.SetLaunchAtLoginAsync(true);
        Assert.True(app.LaunchAtLogin);
    }
}
