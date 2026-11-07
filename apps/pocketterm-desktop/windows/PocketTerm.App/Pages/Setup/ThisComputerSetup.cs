using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Components;
using PocketTerm.App.Views;
using PocketTerm.Desktop;

namespace PocketTerm.App.Pages;

/// <summary>
/// On this computer: a checklist that follows Tailscale as it's set up, looking again every poll: installed,
/// running, signed in, HTTPS certificates on, port 443 free for PocketTerm. Each step shows only its own action;
/// then Start runs the built-in server and signs this computer in to it.
/// </summary>
internal sealed class ThisComputerSetup : View
{
    private readonly AppController _app;
    private TailscaleStatus? _status;

    /// <summary>What already serves on port 443 of this computer's Tailscale name; null while nothing else does (or not asked yet).</summary>
    private string? _taken;

    /// <summary><c>tailscale serve status</c> didn't say what serves on port 443.</summary>
    private bool _unreadable;
    private bool _busy;
    private bool _askingHttps;
    private string? _error;

    /// <param name="app">The controller.</param>
    /// <param name="onJoin">Join another computer's PocketTerm by its setup link instead.</param>
    /// <param name="poll">How often the list looks again; zero: only once.</param>
    public ThisComputerSetup(AppController app, Action onJoin, TimeSpan? poll = null)
    {
        _app = app;
        var ts = app.Tailscale;
        var commands = app.Commands;
        var every = poll ?? TimeSpan.FromSeconds(3);

        var installActions = commands.Winget != null
            ? new Microsoft.UI.Xaml.UIElement[]
            {
                new ConfirmedCommand(
                    commands,
                    "Install Tailscale",
                    Tailscale.WingetInstall,
                    "winget, Windows’ own installer, downloads Tailscale from Tailscale and installs it. Windows asks you " +
                    "to allow it. Then open Tailscale from here.",
                    () => Run(LookAsync)),
                Ui.Button("Download instead", () => Ui.Open(Tailscale.WindowsDownload), "setup-download-tailscale"),
            }
            : [Ui.Button("Install Tailscale", () => Ui.Open(Tailscale.Download), "setup-download-tailscale")];
        var installed = new SetupCheck(
            CheckState.Looking,
            "Install Tailscale",
            "Tailscale’s Personal plan is free (up to 3 users, 100 devices). Sign in with a personal Google, Apple, " +
            "GitHub or Microsoft account; a work email domain may start a paid business trial instead.",
            installActions,
            "check-installed");
        var running = new SetupCheck(
            CheckState.Later,
            "Start Tailscale",
            "Open Tailscale and switch it on.",
            [Ui.Button("Open Tailscale", () => Run(ts.OpenAsync), "setup-open-tailscale")],
            "check-running");
        var signedIn = new SetupCheck(
            CheckState.Later,
            "Sign in to Tailscale",
            "Any account works: Google, GitHub, Microsoft or Apple. Use the same one on your phone.",
            [Ui.Button("Open Tailscale to sign in", () => Run(ts.OpenAsync), "setup-open-tailscale-sign-in")],
            "check-signed-in");
        var turnOnHttps = Ui.Button("Turn on HTTPS…", () => Run(TurnOnHttpsAsync), "setup-turn-on-https");
        var httpsActions = new List<Microsoft.UI.Xaml.UIElement> { turnOnHttps };
        var https = new SetupCheck(
            CheckState.Later,
            "Turn on HTTPS certificates",
            "On the Tailscale page that opens, turn on HTTPS (and MagicDNS, if it asks). Your phone then gets a secure " +
            "address for this computer. On a work tailnet only its admin can: ask them.",
            httpsActions,
            "check-https");
        var serveFree = new SetupCheck(CheckState.Later, "Tailscale’s HTTPS port (443) for PocketTerm", id: "check-serve-free");
        var start = SetupParts.Primary("Start", () => Run(StartAsync), "setup-start-server");
        var error = SetupParts.Error("setup-error");
        // Once, after an upgrade signed this computer out of Supabase or its own server.
        var migration = SetupParts.Notice(app.MigrationNote, "setup-migration-note").Margin(0, 0, 0, 10);
        app.DismissMigrationNote();

        Content = Ui.Stack(
            0,
            Ui.Text("Set up PocketTerm", TextKind.Subtitle),
            Ui.Text(
                "PocketTerm runs your server here. Tailscale gives it a private HTTPS address that only your own devices " +
                "reach, at home or away. This list checks itself as you go.").Margin(0, 8, 0, 10),
            migration,
            new Explainer(
                "What is Tailscale, and why?",
                "Tailscale makes a private network between your own devices, wherever they are. Your phone reaches this " +
                "computer through it, and nothing on the internet can. Tailscale sees which of your devices connect and " +
                "when; PocketTerm’s messages are encrypted, so not what they say.",
                "why-tailscale").Margin(0, 0, 0, 8),
            installed,
            running,
            signedIn,
            https,
            serveFree,
            SetupParts.Notice(BuiltInServer.PhoneTailscaleNote, "setup-phone-tailscale", glyph: Ui.Glyph.Phone).Margin(0, 14, 0, 0),
            start.Margin(0, 18, 0, 0),
            error.Margin(0, 12, 0, 0),
            Ui.Button("Join another computer’s PocketTerm…", onJoin, "setup-join").Margin(0, 18, 0, 0));

        OnRefresh(() =>
        {
            var s = _status;
            bool[]? done = s == null
                ? null
                :
                [
                    s.State != TailscaleState.Missing,
                    s.State is TailscaleState.LoggedOut or TailscaleState.Running,
                    s.State == TailscaleState.Running,
                    s.State == TailscaleState.Running && s.Https && s.DnsName != null,
                    s.State == TailscaleState.Running && s.Https && s.DnsName != null && _taken == null && !_unreadable,
                ];
            var current = done == null ? -1 : Array.IndexOf(done, false);
            var allDone = done != null && current == -1;
            CheckState State(int i) => done switch
            {
                null => i == 0 ? CheckState.Looking : CheckState.Later,
                _ when done[i] && (current == -1 || i < current) => CheckState.Done,
                _ when i == current => CheckState.Now,
                _ => CheckState.Later,
            };
            installed.State = State(0);
            installed.Title = installed.State == CheckState.Done ? "Tailscale is installed" : "Install Tailscale";
            running.State = State(1);
            running.Title = running.State == CheckState.Done ? "Tailscale is running" : "Start Tailscale";
            signedIn.State = State(2);
            signedIn.Title = signedIn.State == CheckState.Done ? "Signed in to Tailscale" : "Sign in to Tailscale";
            https.State = State(3);
            https.Title = https.State == CheckState.Done ? "HTTPS certificates are on" : "Turn on HTTPS certificates";
            turnOnHttps.Content = _askingHttps ? "Opening…" : "Turn on HTTPS…";
            turnOnHttps.IsEnabled = !_askingHttps;
            serveFree.State = State(4);
            serveFree.Title = serveFree.State switch
            {
                CheckState.Done => "Tailscale’s HTTPS port is free for PocketTerm",
                CheckState.Now => "Free Tailscale’s HTTPS port (443)",
                _ => "Tailscale’s HTTPS port (443) for PocketTerm",
            };
            serveFree.Note = _taken != null
                ? $"Tailscale already serves {_taken} there. PocketTerm needs that port and won’t replace it: remove it " +
                  "with tailscale serve --https=443 off, or move it to another port (tailscale serve --https=8443 …). " +
                  "This list checks again by itself."
                : _unreadable
                    ? "PocketTerm couldn’t read Tailscale’s Serve settings, so it doesn’t know yet whether that port is " +
                      "free. This list checks again by itself."
                    : null;
            SetupParts.Busy(start, "Start", _busy, allDone);
            SetupParts.Show(error, _error);
        });

        if (every > TimeSpan.Zero) Every(every, LookAsync);
        else Run(LookAsync);
    }

    private async Task LookAsync()
    {
        var ts = _app.Tailscale;
        var status = await ts.StatusAsync();
        var ready = status.State == TailscaleState.Running && status.Https && status.DnsName != null;
        var serving = ready ? await ts.Port443Async(_app.OwnServerPorts) : null;
        if (!Live) return;
        _status = status;
        _taken = serving is ServingElsewhere elsewhere ? elsewhere.What : null;
        _unreadable = serving is ServingUnknown;
    }

    private async Task TurnOnHttpsAsync()
    {
        _askingHttps = true;
        Refresh();
        try
        {
            Ui.Open(await _app.Tailscale.EnableHttpsLinkAsync());
        }
        finally
        {
            _askingHttps = false;
        }
    }

    private async Task StartAsync()
    {
        _busy = true;
        _error = null;
        Refresh();
        try
        {
            await _app.StartHostingAsync();
        }
        catch (Exception e)
        {
            _error = $"The server didn’t start: {e.Message}";
        }
        if (!Live) return;
        _busy = false;
        if (_app.User == null) _error ??= _app.AuthError;
    }
}
