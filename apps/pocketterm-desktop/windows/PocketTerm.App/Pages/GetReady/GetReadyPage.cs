using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Components;
using PocketTerm.App.Pages.GetReady;
using PocketTerm.App.Views;
using PocketTerm.Core;
using PocketTerm.Desktop;

namespace PocketTerm.App.Pages;

/// <summary>
/// The setup checklist: what this computer and the phone need after the first sign-in here, each step checking
/// itself off as it gets done. The signed-in window until it's finished (<see cref="AppController.GetReadyDone"/>);
/// Settings' status bar opens it again.
/// <list type="number">
/// <item>Coding agents: each agent found (omp, Claude Code) with whether PocketTerm is in it; Install puts it there
/// once the person read why and confirmed (<see cref="ConfirmInstall.AgentAsync"/>), never on its own. Agent
/// sessions opened before it are listed with what picks it up there, until they report.</item>
/// <item>Terminals: WezTerm on Windows.</item>
/// <item>Project folders (optional): the usual ones found in the home folder.</item>
/// <item>Your phone: the pairing QR, until a phone has signed in.</item>
/// </list>
/// </summary>
internal sealed class GetReadyPage : View
{
    /// <summary>How often the terminals' windows and the phone are looked at.</summary>
    private static readonly TimeSpan Poll = TimeSpan.FromSeconds(3);

    /// <summary>How long looking goes on once the window is hidden; while it shows, it keeps looking.</summary>
    private static readonly TimeSpan LookHidden = TimeSpan.FromMinutes(10);

    private readonly AppController _app;

    /// <summary>Agents PocketTerm is going into now, and why it didn't go into others.</summary>
    private readonly HashSet<Agent> _installing = [];
    private readonly Dictionary<Agent, string> _failed = [];

    /// <summary>Agent windows no live session claims; null until looked at.</summary>
    private IReadOnlyList<TermWindow>? _unreported;

    /// <summary>The terminals as last found, where there's no WezTerm to install (not on Windows).</summary>
    private List<TermStatus>? _terminals;

    /// <summary>Installing WezTerm (Windows); made while the page shows, as the Flutter state owned it.</summary>
    private WezTermSetup? _wezterm;

    /// <summary>When looking stops, the window being hidden; null while it shows.</summary>
    private DateTime? _lookUntil;

    /// <summary><see cref="AppController.MainShown"/> as last seen: it ticks each time the window shows.</summary>
    private int _mainShown;

    private readonly Action _liveChanged;

    private readonly ContentControl _terminalsBody = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly StackPanel _terminalList = new() { Spacing = 8 };
    private readonly ContentControl _hostingBody = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly ContentControl _qrBody = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private PairingQr? _qr;

    public GetReadyPage(AppController app)
    {
        _app = app;
        _mainShown = app.MainShown;
        _liveChanged = () => OnUi(() => Run(LookAtWindowsAsync));
        _wezterm = WezTermSetup.ForHost(app.Terminals.WezTerm);
        ShowTerminals();

        var title = Ui.Text("Get this computer ready", TextKind.Title);
        var intro = Ui.Dim(
            "A few things so your phone sees your coding sessions and terminals. Each one checks itself off " +
            "when it\u2019s done.");
        intro.TextWrapping = TextWrapping.Wrap;

        var agents = new StepCard("get-ready-agents", "Your coding agents", AgentsBody(out var updateAgents));
        var terminals = new StepCard("get-ready-terminals", "Your terminals", _terminalsBody);
        var folders = new StepCard("get-ready-folders", "Project folders", FoldersBody(out var updateFolders), optional: true);
        var phone = new StepCard("get-ready-phone", "Your phone", PhoneBody(out var updatePhone));

        var left = Ui.Dim("").Id("get-ready-left");
        left.FontSize = 12.5;
        left.TextWrapping = TextWrapping.Wrap;
        var done = Ui.Button("Done", () => app.SetGetReadyDone(true), "get-ready-done", accent: true)
            .Align(HorizontalAlignment.Right);
        done.MinWidth = 120;

        Content = Ui.Page(
            Ui.Stack(
                12,
                title,
                intro.Margin(0, 0, 0, 6),
                agents.Root,
                terminals.Root,
                folders.Root,
                phone.Root,
                left.Margin(0, 4, 0, 0),
                done),
            maxWidth: 640,
            id: "get-ready");

        Watch(app);
        Follow(() => _wezterm);
        OnRefresh(() =>
        {
            // The window showed again: look afresh. Hidden: look for a while longer, then stop.
            if (app.MainShown != _mainShown)
            {
                _mainShown = app.MainShown;
                _lookUntil = null;
                Run(app.CheckAgentsAsync);
                Run(LookAsync);
            }
            if (app.MainHidden) _lookUntil ??= DateTime.UtcNow + LookHidden;

            agents.Set(AgentsStatus);
            terminals.Set(TerminalsStatus);
            folders.Set(FoldersStatus);
            phone.Set(PhoneStatus);
            updateAgents();
            updateFolders();
            updatePhone();
            UpdateTerminalList();
            var still = Left;
            left.Shown(still.Count > 0);
            left.Text = $"Still to do: {string.Join(" and ", still)}. Settings keeps track of what\u2019s left.";
        });
        Every(Poll, LookAsync);
    }

    protected override void OnShown()
    {
        _app.Live.Changes += _liveChanged;
        if (_wezterm == null && WezTermSetup.ForHost(_app.Terminals.WezTerm) is { } setup)
        {
            _wezterm = setup;
            ShowTerminals();
        }
        Run(_app.CheckAgentsAsync);
    }

    protected override void OnHidden()
    {
        _app.Live.Changes -= _liveChanged;
        _wezterm?.Dispose();
        _wezterm = null;
    }

    private async Task InstallAsync(Agent agent)
    {
        var check = _app.CodingAgents?.GetValueOrDefault(agent);
        var update = check != null && Integrations.IntegrationOf(check) == AgentIntegration.Outdated;
        if (!await ConfirmInstall.AgentAsync(agent, _app.Integrations, home: _app.Terminals.Home, update: update)) return;
        if (!Live) return;
        _installing.Add(agent);
        _failed.Remove(agent);
        Refresh();
        string? error = null;
        try
        {
            await _app.InstallAgentAsync(agent);
        }
        catch (Exception e)
        {
            error = e.Message;
        }
        if (!Live) return;
        _installing.Remove(agent);
        if (error != null) _failed[agent] = error;
        Refresh();
        await LookAtWindowsAsync();
    }

    private async Task LookAsync()
    {
        if (_lookUntil is { } until && DateTime.UtcNow > until) return;
        await LookAtWindowsAsync();
        if (_wezterm == null && Live) _terminals = await _app.Terminals.StatusesAsync();
        if (!(_app.PhoneSignedIn ?? false)) await _app.CheckPhoneAsync();
    }

    private async Task LookAtWindowsAsync()
    {
        try
        {
            var windows = await _app.Terminals.WindowsAsync();
            if (Live) _unreported = _app.UnreportedAgentWindows(windows);
        }
        catch (TerminalException)
        {
            // As before.
        }
    }

    // ---------------------------------------------------------------- state

    private StepStatus AgentsStatus
    {
        get
        {
            var agents = _app.CodingAgents;
            if (agents == null || _installing.Count > 0) return StepStatus.Working;
            var ready = agents.Count > 0 &&
                agents.Values.All(c => Integrations.IntegrationOf(c) == AgentIntegration.Installed) &&
                (_unreported?.Count ?? 0) == 0;
            return ready ? StepStatus.Done : StepStatus.Action;
        }
    }

    private StepStatus TerminalsStatus
    {
        get
        {
            if (_wezterm is { } w) return w.Installed ? StepStatus.Done : StepStatus.Action;
            var t = _terminals;
            if (t == null) return StepStatus.Working;
            return TerminalFixes.TerminalsNeedingSetup(t).Count == 0 && !TerminalFixes.NoTerminalApp(t) ? StepStatus.Done : StepStatus.Action;
        }
    }

    private StepStatus FoldersStatus => _app.ProjectRoots.Count == 0 ? StepStatus.Optional : StepStatus.Done;

    private StepStatus PhoneStatus => _app.PhoneSignedIn == true ? StepStatus.Done : StepStatus.Action;

    /// <summary>The essential steps not done yet, by name, for the Done button.</summary>
    private List<string> Left
    {
        get
        {
            var left = new List<string>();
            if (AgentsStatus != StepStatus.Done) left.Add("your coding agents");
            if (TerminalsStatus != StepStatus.Done) left.Add("your terminals");
            return left;
        }
    }

    // ---------------------------------------------------------------- agents

    private UIElement AgentsBody(out Action update)
    {
        var looking = new StatusLine();
        looking.Set(StepStatus.Working, "Looking for omp and Claude Code…");
        var none = new StatusLine();
        none.Set(
            StepStatus.Action,
            "No coding agent found. PocketTerm works with omp and Claude Code: install one, then come back here.");
        var lines = Enum.GetValues<Agent>().ToDictionary(
            a => a,
            a => new StatusLine().Id($"get-ready-agent-{a.Name()}").ActionId($"get-ready-agent-{a.Name()}-install"));

        var openTitle = Ui.Strong("Sessions that were already open").Id("get-ready-open-sessions");
        openTitle.FontSize = 13;
        var how = new Dictionary<Agent, TextBlock>();
        foreach (var agent in Enum.GetValues<Agent>())
        {
            how[agent] = Note(agent switch
            {
                Agent.Claude => $"{Integrations.Name(agent)}: type {agent.PickUp()} in it. Nothing restarts.",
                _ => $"{Integrations.Name(agent)}: quit it and run {agent.PickUp()}. You\u2019re back in the same conversation.",
            });
        }
        var rows = new StackPanel { Spacing = 8, Margin = new Thickness(0, 2, 0, 0) };
        var open = Ui.Stack(
            6,
            openTitle,
            Note(
                "PocketTerm talks to your phone through a small add-on inside omp and Claude Code. An agent loads " +
                "add-ons when it starts, so sessions opened before PocketTerm don\u2019t have it yet: your phone sees " +
                "only their screen, not the conversation. Do this once in each; new sessions don\u2019t need it."));
        foreach (var t in how.Values) open.Children.Add(t);
        open.Children.Add(Note(
            "Afterwards your phone shows the conversation: answer questions and approvals there and get a " +
            "notification when a run finishes."));
        open.Children.Add(rows);
        open.Margin = new Thickness(0, 10, 0, 0);

        var body = Ui.Stack(4, looking, none);
        foreach (var line in lines.Values) body.Children.Add(line);
        body.Children.Add(open);

        update = () =>
        {
            var agents = _app.CodingAgents;
            var unreported = _unreported ?? [];
            looking.Shown(agents == null);
            none.Shown(agents != null && agents.Count == 0 && _installing.Count == 0);
            var each = agents != null && !(agents.Count == 0 && _installing.Count == 0);
            foreach (var (agent, line) in lines)
            {
                line.Shown(each);
                if (each) SetAgentLine(line, agent, agents!.GetValueOrDefault(agent));
            }
            open.Shown(unreported.Count > 0);
            foreach (var (agent, text) in how) text.Shown(unreported.Any(w => w.Agent == agent));
            rows.Sync(
                unreported,
                w => w.Key,
                w => new SessionToPickUp(w, _app.Terminals).Id($"get-ready-unreported-{w.Key}"),
                (e, w) => ((SessionToPickUp)e).Update(w));
        };
        return body;
    }

    private void SetAgentLine(StatusLine line, Agent agent, AgentCheck? check)
    {
        var name = Integrations.Name(agent);
        if (_installing.Contains(agent))
        {
            line.Set(StepStatus.Working, $"Installing PocketTerm in {name}…");
            return;
        }
        if (_failed.TryGetValue(agent, out var error))
        {
            line.Set(StepStatus.Action, $"Couldn't install PocketTerm in {name}: {error}", error: true, "Retry", () => Run(() => InstallAsync(agent)));
            return;
        }
        if (check == null)
        {
            line.Set(StepStatus.Optional, $"{name} not found: install it later and PocketTerm offers it in Settings");
            return;
        }
        if (check.State.Problem is { } problem)
        {
            line.Set(StepStatus.Action, problem);
            return;
        }
        switch (Integrations.IntegrationOf(check))
        {
            case AgentIntegration.Installed:
                line.Set(StepStatus.Done, $"PocketTerm is installed in {name}");
                break;
            case AgentIntegration.Off:
                line.Set(StepStatus.Action, Integrations.ModsOffHint);
                break;
            case AgentIntegration.Outdated:
                line.Set(StepStatus.Action, $"PocketTerm in {name} is out of date", action: "Update", onAction: () => Run(() => InstallAsync(agent)));
                break;
            default:
                line.Set(StepStatus.Action, $"PocketTerm isn\u2019t installed in {name}", action: "Install", onAction: () => Run(() => InstallAsync(agent)));
                break;
        }
    }

    private static TextBlock Note(string text)
    {
        var t = Ui.Dim(text);
        t.FontSize = 12.5;
        t.TextWrapping = TextWrapping.Wrap;
        return t;
    }

    // ---------------------------------------------------------------- terminals

    /// <summary>The terminals step's body: WezTerm's card, or (where WezTerm isn't the one terminal, so not on
    /// Windows) the terminals found.</summary>
    private void ShowTerminals() =>
        _terminalsBody.Content = _wezterm is { } w ? new WezTermCard(w) : _terminalList;

    private void UpdateTerminalList()
    {
        if (_wezterm != null) return;
        _terminalList.Sync(
            (_terminals ?? []).Where(s => s.State != TermState.Missing),
            s => s.Id,
            s =>
            {
                var line = new StatusLine().Id($"terminal-{s.Id}");
                SetTerminalLine(line, s);
                return line;
            },
            (e, s) => SetTerminalLine((StatusLine)e, s));
    }

    private static void SetTerminalLine(StatusLine line, TermStatus s) => line.Set(
        s.State is TermState.Ready or TermState.Idle ? StepStatus.Done : StepStatus.Action,
        s.Note.Length > 0 ? $"{s.Label}: {s.Note}" : s.Label);

    // ---------------------------------------------------------------- folders

    private UIElement FoldersBody(out Action update)
    {
        var intro = Ui.Dim("Your phone lists the git repositories in these and starts new projects there.");
        intro.TextWrapping = TextWrapping.Wrap;
        var roots = new StackPanel { Spacing = 4 };
        var chips = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
        var choose = Ui.IconButton(
            Ui.Glyph.FolderAdd,
            "Choose folder…",
            () => Run(async () => AddFolders(await _app.Host.PickFoldersAsync())),
            "get-ready-choose-folder");

        update = () =>
        {
            roots.Sync(
                _app.ProjectRoots,
                r => r,
                r =>
                {
                    var line = new StatusLine();
                    line.Set(StepStatus.Done, Tilde(r));
                    return line;
                });
            var suggested = ProjectFolders.Suggestions(_app.Terminals.Home, _app.ProjectRoots);
            chips.Sync(
                suggested.Select(s => (string?)s).Append(null),
                s => s ?? "",
                s => s == null
                    ? choose
                    : Ui.IconButton(Ui.Glyph.Add, Tilde(s), () => AddFolders([s]), $"get-ready-folder-{s}"));
        };
        return Ui.Stack(8, intro, roots, chips);
    }

    private void AddFolders(IReadOnlyList<string> picked)
    {
        if (picked.Count == 0) return;
        _app.SetProjectRoots(_app.ProjectRoots.Concat(picked).Distinct().ToList());
    }

    // ---------------------------------------------------------------- phone

    private UIElement PhoneBody(out Action update)
    {
        var signedIn = Ui.Dim("A phone is signed in. To add another: Settings \u2192 Phone \u2192 Add a phone\u2026");
        signedIn.TextWrapping = TextWrapping.Wrap;
        var tailscale = Ui.Dim(BuiltInServer.PhoneTailscaleNote).Id("get-ready-phone-tailscale");
        tailscale.TextWrapping = TextWrapping.Wrap;
        var testers = Ui.Dim(
            "PocketTerm for iPhone is on TestFlight and for Android on Google Play internal testing, " +
            "for invited testers.");
        testers.FontSize = 11.5;
        testers.TextAlignment = TextAlignment.Center;
        testers.TextWrapping = TextWrapping.Wrap;
        var pairing = Ui.Stack(10, tailscale.Margin(0, 0, 0, 2), _qrBody, testers);

        update = () =>
        {
            var phone = _app.PhoneSignedIn ?? false;
            // A computer running the server: the phone's code needs Tailscale's address.
            var hosting = phone ? null : _app.Hosting is { State: not HostState.Ready } h ? h : null;
            var qr = !phone && hosting == null;
            signedIn.Shown(phone);
            _hostingBody.Shown(hosting != null);
            if (hosting == null) _hostingBody.Content = null;
            else if (!ReferenceEquals(_hostingBody.Tag, hosting) || _hostingBody.Content == null)
            {
                _hostingBody.Tag = hosting;
                _hostingBody.Content = new HostingStatusView(hosting);
            }
            pairing.Shown(qr);
            // A fresh code each time the QR comes back, as the Flutter widget made one when built.
            if (!qr) _qr = null;
            else _qr ??= new PairingQr(_app);
            if (!ReferenceEquals(_qrBody.Content, _qr)) _qrBody.Content = _qr;
            // Through Tailscale (this computer's server, or another computer's): the phone needs it too.
            tailscale.Shown(_app.Hosting != null || (_app.Backend?.Host.EndsWith(".ts.net", StringComparison.Ordinal) ?? false));
        };
        return Ui.Stack(0, signedIn, _hostingBody, pairing);
    }

    private string Tilde(string path) => SessionToPickUp.Tilde(path, _app.Terminals.Home);
}
