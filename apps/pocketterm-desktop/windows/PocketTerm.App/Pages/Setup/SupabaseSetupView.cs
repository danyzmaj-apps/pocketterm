using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Components;
using PocketTerm.App.Views;
using PocketTerm.Desktop;

namespace PocketTerm.App.Pages;

/// <summary>
/// Supabase: paste the setup link of a computer already on a project, or set a project up (<see cref="SupabaseFlow"/>).
/// Setting up asks for a personal access token after saying what it covers and what Supabase holds, then a project
/// (a new one in the picked organization and region, or the one PocketTerm is already on there), then runs the setup
/// step by step and signs this computer in with the link it makes. The token lives only in this screen: its
/// PasswordBox and the flow, both cleared on Back and when the screen goes.
/// </summary>
internal sealed class SupabaseSetupView : View
{
    private readonly SupabaseFlow _flow;
    private readonly Action _onBack;
    private readonly PasswordBox _token;
    private readonly ComboBox _org;
    private readonly ComboBox _region;
    private IReadOnlyList<SupabaseOrg>? _orgsShown;

    /// <summary>The pickers are being brought up to date: their selection changes aren't the person's.</summary>
    private bool _syncing;

    public SupabaseSetupView(
        AppController app,
        Action onBack,
        ServerChecks? checks = null,
        Func<string, SupabaseAdmin>? admin = null,
        Func<SupabaseAdmin, string, SupabaseSetup>? setup = null)
    {
        _onBack = onBack;
        _flow = new SupabaseFlow(
            async link =>
            {
                await app.ConnectLink(link);
                if (app.User != null) return null;
                var why = app.AuthError ?? SupabaseFlow.NotSignedIn;
                if (app.Backend != null) await app.Disconnect();
                return why;
            },
            admin,
            setup);

        // Choose.
        var choose = Ui.Stack(
            12,
            SetupParts.Header("Supabase", "Is PocketTerm already on a Supabase project of yours?", Back),
            SetupParts.Option(
                "supabase-paste",
                Ui.Glyph.Link,
                "Paste a setup link",
                "Another computer of yours already uses it: open Settings, Account, Add a computer… there and paste its " +
                "link here.",
                () => _flow.Show(SupabaseStage.Paste)),
            SetupParts.Option(
                "supabase-new",
                Ui.Glyph.Add,
                "Set up a project",
                "PocketTerm makes a free project in your Supabase account and sets it up. It takes a few minutes.",
                () => _flow.Show(SupabaseStage.Token)));

        // Paste.
        var paste = Ui.Stack(
            0,
            SetupParts.Header(
                "Paste a setup link",
                "On a computer already signed in to your Supabase project, open Settings, Account, Add a computer… and copy " +
                "the link it shows.",
                Back),
            new SetupLinkForm(app, checks));

        // Token.
        _token = new PasswordBox { PlaceholderText = "sbp_…" }.Id("supabase-token", "Supabase access token");
        _token.KeyDown += (_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.Enter || _flow.Busy) return;
            e.Handled = true;
            Continue();
        };
        var continueButton = SetupParts.Primary("Continue", Continue, "supabase-continue");
        var token = Ui.Stack(
            0,
            SetupParts.Header(
                "Set up a Supabase project",
                "PocketTerm makes a free project in your Supabase account and puts its server there. First, what that means.",
                Back),
            Ui.Stack(
                14,
                Para(
                    "What stays private",
                    "Your sessions, images, files and notification text stay end-to-end encrypted, exactly as with the other " +
                    "options. The project only passes them along, sealed.",
                    "supabase-security"),
                Para(
                    "What Supabase holds",
                    "Supabase, in the region you pick, holds what any PocketTerm server holds: your list of devices (names, " +
                    "platforms, when they were added and last seen), your computers’ names, your phones’ push tokens, " +
                    "pairing codes for 10 minutes, and when messages and pushes go through. Supabase also sees the IP " +
                    "addresses your devices connect from."),
                Para(
                    "Signing out a device",
                    "A phone or computer you sign out hears it at once and is refused at its next connection. At most its " +
                    "live connection lasts until its 10-minute token runs out, and what it gets stays sealed."),
                Para(
                    "Free projects pause",
                    "Supabase pauses a free project after about a week without use. Restore it at supabase.com/dashboard. " +
                    "The free plan allows 2 active projects per account."),
                Para(
                    "Your access token",
                    "PocketTerm needs a personal access token to make and set up the project. It covers your whole Supabase " +
                    "organization, every project in it. PocketTerm uses it only during this setup and never stores it. " +
                    "Best: give PocketTerm a Supabase organization of its own, and delete the token once this is done.")),
            SetupParts.TextWithLink(
                "Create a token at supabase.com/dashboard/account/tokens, then paste it here.",
                "Create a token",
                SupabaseFlow.TokensPage,
                "supabase-open-tokens").Margin(0, 16, 0, 8),
            _token,
            continueButton.Margin(0, 14, 0, 0));

        // Project.
        _org = new ComboBox
        {
            PlaceholderText = "Choose…",
            HorizontalAlignment = HorizontalAlignment.Stretch,
        }.Id("supabase-org", "Organization");
        _org.SelectionChanged += (_, _) =>
        {
            if (_syncing || _org.SelectedItem is not ComboBoxItem { Tag: string slug } || slug == _flow.Org) return;
            Run(() => _flow.PickOrgAsync(slug));
        };
        _region = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch }.Id("supabase-region", "Region");
        foreach (var (key, label) in SupabaseFlow.Regions) _region.Items.Add(new ComboBoxItem { Content = label, Tag = key });
        _region.SelectionChanged += (_, _) =>
        {
            if (_syncing || _region.SelectedItem is not ComboBoxItem { Tag: string key } || key == _flow.Region) return;
            _flow.Region = key;
        };
        var existing = SetupParts.Notice(null, "supabase-existing");
        var update = SetupParts.Primary("Update that project", () => Run(_flow.UpdateAsync), "supabase-update");
        var create = SetupParts.Primary("Create the project", () => Run(_flow.CreateAsync), "supabase-create");
        var newProject = Ui.Stack(
            0,
            Label("Region"),
            _region,
            Ui.Dim("Pick one near you: your device list is kept there.").Margin(0, 6, 0, 0),
            create.Margin(0, 14, 0, 0));
        var project = Ui.Stack(
            0,
            SetupParts.Header("Choose where it goes", "PocketTerm makes a new project called PocketTerm. It touches no other.", Back),
            Label("Organization"),
            _org,
            existing.Margin(0, 14, 0, 0),
            update.Margin(0, 14, 0, 0),
            newProject.Margin(0, 14, 0, 0));

        // Progress.
        var steps = Enum.GetValues<SupabaseStep>()
            .Select(s => (Step: s, Check: new SetupCheck(CheckState.Later, s.Label(), id: $"supabase-step-{DartName(s)}")))
            .ToList();
        var progress = Ui.Stack(
            0,
            SetupParts.Header("Setting up your project", "This takes a few minutes. Keep this window open.", Back));
        foreach (var (_, check) in steps) progress.Children.Add(check);
        var wait = SetupParts.Notice(null, "supabase-wait", glyph: Ui.Glyph.Clock);
        progress.Children.Add(wait.Margin(0, 12, 0, 0));

        var error = SetupParts.Error("supabase-error");
        var retry = SetupParts.Primary("Retry", () => Run(_flow.SetUpAsync), "supabase-retry");

        Content = Ui.Stack(0, choose, paste, token, project, progress, error.Margin(0, 12, 0, 0), retry.Margin(0, 14, 0, 0));
        Watch(_flow);
        OnRefresh(() =>
        {
            var stage = _flow.Stage;
            var busy = _flow.Busy;
            choose.Shown(stage == SupabaseStage.Choose);
            paste.Shown(stage == SupabaseStage.Paste);
            token.Shown(stage == SupabaseStage.Token);
            project.Shown(stage == SupabaseStage.Project);
            progress.Shown(stage == SupabaseStage.Progress);

            _token.IsEnabled = !busy;
            SetupParts.Busy(continueButton, "Continue", busy);

            _syncing = true;
            try
            {
                SyncOrgs(_flow.Orgs);
                _org.IsEnabled = !busy;
                _org.SelectedItem = _org.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == _flow.Org);
                _region.IsEnabled = !busy;
                _region.SelectedItem = _region.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == _flow.Region);
            }
            finally
            {
                _syncing = false;
            }
            var found = _flow.Existing;
            SetupParts.Show(
                existing,
                found == null
                    ? null
                    : $"PocketTerm is already on {found.Name} in this organization. Update that project instead of making " +
                      "another: every phone and computer on it stays signed in.");
            update.Shown(found != null);
            SetupParts.Busy(update, "Update that project", busy);
            newProject.Shown(found == null);
            SetupParts.Busy(create, "Create the project", busy, _flow.CanCreate);

            foreach (var (step, check) in steps)
            {
                check.State = _flow.StepState(step) switch
                {
                    SupabaseStepState.Done => CheckState.Done,
                    SupabaseStepState.Looking => CheckState.Looking,
                    SupabaseStepState.Now => CheckState.Now,
                    _ => CheckState.Later,
                };
            }
            SetupParts.Show(wait, _flow.Waiting ? SupabaseFlow.WaitNotice : null);

            var failed = stage is SupabaseStage.Token or SupabaseStage.Project or SupabaseStage.Progress ? _flow.Error : null;
            SetupParts.Show(error, failed);
            retry.Shown(stage == SupabaseStage.Progress && failed != null);
        });
    }

    /// <summary>The Dart enum's name, which the AutomationIds keep (<c>liveChannel</c>).</summary>
    private static string DartName(SupabaseStep step)
    {
        var name = step.ToString();
        return char.ToLowerInvariant(name[0]) + name[1..];
    }

    private static UIElement Para(string title, string text, string? id = null)
    {
        var heading = Ui.Strong(title);
        if (id != null) heading.Id(id);
        return Ui.Stack(4, heading, Ui.Dim(text));
    }

    private static TextBlock Label(string text) => Ui.Dim(text).Margin(0, 0, 0, 6);

    private void SyncOrgs(IReadOnlyList<SupabaseOrg>? orgs)
    {
        if (ReferenceEquals(orgs, _orgsShown)) return;
        _orgsShown = orgs;
        _org.Items.Clear();
        foreach (var o in orgs ?? []) _org.Items.Add(new ComboBoxItem { Content = SupabaseFlow.OrgLabel(o), Tag = o.Slug });
    }

    private void Continue()
    {
        var typed = _token.Password;
        Run(() => _flow.ContinueAsync(typed));
    }

    private void Back()
    {
        _token.Password = "";
        if (!_flow.Back()) _onBack();
    }

    protected override void OnShown()
    {
        // Back on screen after the token went (OnHidden): a screen that needs it starts over.
        if (_flow.Orgs == null && _flow.Stage is SupabaseStage.Project or SupabaseStage.Progress) _flow.Show(SupabaseStage.Choose);
    }

    protected override void OnHidden()
    {
        // The token lives only while this screen shows.
        _token.Password = "";
        _flow.Drop();
    }
}
