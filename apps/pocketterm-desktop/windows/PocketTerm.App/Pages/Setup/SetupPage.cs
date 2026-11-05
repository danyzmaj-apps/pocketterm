using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using PocketTerm.App.Components;
using PocketTerm.App.Views;
using PocketTerm.Desktop;

namespace PocketTerm.App.Pages;

/// <summary>
/// First run: where this computer's PocketTerm server runs. <b>On this computer</b>: the built-in server, reached
/// through Tailscale, after a checklist that follows Tailscale as the person sets it up. <b>On my own server</b>: a
/// VPS, by its setup link, or, without one yet, the commands that set one up, checked live. <b>Supabase</b>: a free
/// Supabase project the setup makes with the person's access token. Either way, the setup checklist follows
/// sign-in. Where it was left is kept (<see cref="AppController.SetupStep"/>, the Flutter app's step names) and it
/// opens there again.
/// </summary>
internal sealed class SetupPage : View
{
    /// <summary>The setup's screens, saved by name.</summary>
    private enum Step
    {
        /// <summary>On this computer, on my own server, or Supabase.</summary>
        Choose,

        /// <summary>The Tailscale checklist, then Start.</summary>
        ThisComputer,

        /// <summary>Do you already have a PocketTerm server?</summary>
        OwnServer,

        /// <summary>Yes: its setup link.</summary>
        HaveServer,

        /// <summary>Not yet: its address, the commands for it, live checks, its setup link.</summary>
        NewServer,

        /// <summary>A Supabase project: set one up with an access token, or paste the setup link of a computer already on one.</summary>
        Supabase,
    }

    /// <summary>The step's saved name, as the Flutter app saved it (an upgrade opens where it was left).</summary>
    private static string StepName(Step step) => step switch
    {
        Step.ThisComputer => "thisComputer",
        Step.OwnServer => "ownServer",
        Step.HaveServer => "haveServer",
        Step.NewServer => "newServer",
        Step.Supabase => "supabase",
        _ => "choose",
    };

    private const string ServerNeeds =
        "https://github.com/danyzmaj-apps/pocketterm/blob/main/apps/pocketterm-server/README.md#what-it-needs";

    private readonly AppController _app;
    private readonly TimeSpan _poll;
    private readonly ServerChecks _checks;
    private readonly Func<string, SupabaseAdmin>? _supabaseAdmin;
    private readonly Func<SupabaseAdmin, string, SupabaseSetup>? _supabaseSetup;
    private readonly ContentControl _host = new()
    {
        HorizontalContentAlignment = HorizontalAlignment.Stretch,
        IsTabStop = false,
    };
    private readonly ScrollViewer _scroll;

    /// <param name="app">The controller.</param>
    /// <param name="poll">How often the live checks look again (3 s); zero: only once.</param>
    /// <param name="checks">What the VPS checks ask the network.</param>
    /// <param name="supabaseAdmin">What the Supabase branch talks to with the pasted token (tests: a fake).</param>
    /// <param name="supabaseSetup">The setup of one Supabase project (tests: one that waits for nothing).</param>
    public SetupPage(
        AppController app,
        TimeSpan? poll = null,
        ServerChecks? checks = null,
        Func<string, SupabaseAdmin>? supabaseAdmin = null,
        Func<SupabaseAdmin, string, SupabaseSetup>? supabaseSetup = null)
    {
        _app = app;
        _poll = poll ?? TimeSpan.FromSeconds(3);
        _checks = checks ?? new ServerChecks();
        _supabaseAdmin = supabaseAdmin;
        _supabaseSetup = supabaseSetup;
        _scroll = Ui.Page(_host, 560, "setup-page");
        Content = _scroll;
        var saved = Enum.GetValues<Step>().FirstOrDefault(s => StepName(s) == app.SetupStep);
        Show(saved);
    }

    private void Go(Step step)
    {
        _app.SetSetupStep(step == Step.Choose ? null : StepName(step));
        Show(step);
    }

    private void Show(Step step)
    {
        _host.Content = step switch
        {
            Step.ThisComputer => new ThisComputerSetup(_app, () => Go(Step.Choose), () => Go(Step.OwnServer), _poll),
            Step.OwnServer => OwnServer(),
            Step.HaveServer => Ui.Stack(
                0,
                SetupParts.Header(
                    "Paste your server’s setup link",
                    "On the server, in ~/pocketterm, run: sudo docker compose exec server pocketterm-server setup-link. " +
                    "A computer of yours that runs PocketTerm’s server has one too, in Settings → Account → Add a " +
                    "computer…",
                    () => Go(Step.OwnServer)),
                new SetupLinkForm(_app, _checks)),
            Step.NewServer => new NewServerSetup(_app, () => Go(Step.OwnServer), _poll, _checks),
            Step.Supabase => new SupabaseSetupView(_app, () => Go(Step.Choose), _checks, _supabaseAdmin, _supabaseSetup),
            _ => Choose(),
        };
        _scroll.ChangeView(null, 0, null, true);
    }

    private UIElement Choose()
    {
        var logo = new Image
        {
            Source = new BitmapImage(new Uri(Path.Combine(AppPaths.BaseDir, "Assets", "app.ico"))),
            Width = 56,
            Height = 56,
        }.Align(HorizontalAlignment.Center);
        var title = Ui.Text("Set up PocketTerm", TextKind.Subtitle);
        title.TextAlignment = TextAlignment.Center;
        var sub = Ui.Text("Your phone reaches this computer through a PocketTerm server. Where should it run?");
        sub.TextAlignment = TextAlignment.Center;
        return Ui.Stack(
            12,
            logo.Margin(0, 16, 0, 2),
            title,
            sub.Margin(0, 0, 0, 10),
            SetupParts.Option(
                "setup-this-computer",
                Ui.Glyph.Computer,
                "On this computer",
                "Free, set up in a few clicks. Uses Tailscale, on this computer and your phone. This computer must stay " +
                "awake.",
                () => Go(Step.ThisComputer)),
            SetupParts.Option(
                "setup-own-server",
                Ui.Glyph.Server,
                "On my own server",
                "A VPS you rent. No Tailscale, and several computers share one server. Your sessions still run here, " +
                "so this computer stays awake for them too.",
                () => Go(Step.OwnServer)),
            SetupParts.Option(
                "setup-supabase",
                Ui.Glyph.Cloud,
                "Supabase",
                "A free Supabase project PocketTerm sets up for you. No Tailscale, no server to run. Supabase holds your " +
                "device list.",
                () => Go(Step.Supabase)),
            Ui.Stack(
                4,
                new Explainer(
                    "What is a PocketTerm server?",
                    "It introduces your phone to your computers and passes their messages along. It keeps your list of " +
                    "devices, your computers’ names, pairing codes for 10 minutes and your phones’ push tokens. Your sessions " +
                    "pass through it only encrypted, so it can’t read them.",
                    "why-server"),
                new Explainer("How the three options compare", new OptionsTable(), "why-compare"),
                new Explainer("How your data is protected", DataProtection.Build(), "why-data")).Margin(0, 6, 0, 0));
    }

    private UIElement OwnServer() => Ui.Stack(
        12,
        SetupParts.Header("On my own server", "Do you already have a PocketTerm server?", () => Go(Step.Choose)),
        SetupParts.Option(
            "setup-have-server",
            Ui.Glyph.Link,
            "Yes",
            "Paste its setup link. A link from another computer of yours that runs PocketTerm’s server works too.",
            () => Go(Step.HaveServer)),
        SetupParts.Option(
            "setup-new-server",
            Ui.Glyph.Add,
            "Not yet",
            "Set one up on a VPS: you get the commands to copy, and each step is checked as you go.",
            () => Go(Step.NewServer)),
        SetupParts.TextWithLink(
            "Already run your own servers? See what the PocketTerm server needs.",
            "Open link",
            ServerNeeds,
            "setup-server-needs").Margin(0, 2, 0, 0));
}
