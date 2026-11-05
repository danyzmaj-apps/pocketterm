using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Components;
using PocketTerm.App.Views;
using PocketTerm.Core;
using PocketTerm.Desktop;

namespace PocketTerm.App.Pages;

/// <summary>Settings' tabs, by the names their AutomationIds carry.</summary>
internal enum SettingsTab
{
    Phone,
    Agents,
    Terminals,
    Account,
}

/// <summary>
/// Settings, the whole window while signed in (main_window.dart's SettingsPage): Windows Settings' left pane with
/// the tabs (Phone, Coding agents, Terminals, Account), each with a dot when something on it needs attention; over
/// the tab's cards the status bar (all set, or what needs attention with its buttons) and a newer PocketTerm.
/// </summary>
internal sealed partial class SettingsPage : View
{
    private readonly AppController _app;

    /// <summary>The status bar lists what needs attention.</summary>
    private bool _showAttention;

    /// <summary>Why Launch at login didn't change, when the system refused.</summary>
    private string? _launchError;

    /// <summary>The terminals as the bridge would find them, and their windows.</summary>
    private List<TermStatus>? _terminals;
    private int _windowCount;

    /// <summary>What a one-click fix said, by terminal id, with the fix it was for and whether it failed: shown until
    /// the terminal's status no longer carries that fix, then the live status speaks.</summary>
    private readonly Dictionary<string, (TermFix? Fix, string Note, bool Failed)> _fixed = [];

    /// <summary>Agents PocketTerm is going into, and how it went in each since the window was last shown.</summary>
    private readonly HashSet<Agent> _installing = [];
    private readonly Dictionary<Agent, (string Text, TextKind Kind)> _installNotes = [];

    /// <summary>Agent windows no live session claims, as of <see cref="CheckTerminalsAsync"/>.</summary>
    private IReadOnlyList<TermWindow> _unreported = [];

    /// <summary>The agents whose sessions to pick up are listed.</summary>
    private readonly HashSet<Agent> _showSessions = [];

    /// <summary>Installing WezTerm from its card; null off Windows (or without its host).</summary>
    private WezTermSetup? _wezterm;
    private bool _weztermDisposed;

    /// <summary>Who is signed in to the server, for the Account tab; null until known.</summary>
    private List<Device>? _devices;

    /// <summary>This computer's clock is too far off its server's (a VPS's, another computer's): phones drop what
    /// it sends (<see cref="Backend.ClockWarning"/>).</summary>
    private string? _clock;

    /// <summary>The window's showings seen: a new one checks again.</summary>
    private int _shown;

    private SettingsTab _tab = SettingsTab.Phone;
    private readonly Border _tabHost = new();
    private readonly Dictionary<SettingsTab, UIElement> _tabPages = [];

    public SettingsPage(AppController app)
    {
        _app = app;
        _shown = app.MainShown;
        _wezterm = WezTermSetup.ForHost(app.Terminals.WezTerm);
        Watch(app);
        Watch(app.Updates);
        Watch(Appearance.Shared);
        Watch(_wezterm);
        Follow(() => app.Hosting);

        _tabPages[SettingsTab.Phone] = PhoneTab();
        _tabPages[SettingsTab.Agents] = AgentsTab();
        _tabPages[SettingsTab.Terminals] = TerminalsTab();
        _tabPages[SettingsTab.Account] = AccountTab();

        var nav = new NavigationView
        {
            PaneDisplayMode = NavigationViewPaneDisplayMode.Auto,
            IsSettingsVisible = false,
            IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
            OpenPaneLength = 240,
            AlwaysShowHeader = true,
            PaneHeader = Ui.Text("Settings", TextKind.Strong).Margin(16, 8, 0, 8),
        };
        var header = Ui.Text(Label(_tab), TextKind.Title);
        nav.Header = header;
        var items = new Dictionary<SettingsTab, NavigationViewItem>();
        foreach (var tab in Enum.GetValues<SettingsTab>())
        {
            var dot = new InfoBadge { Visibility = Visibility.Collapsed }.Id($"settings-tab-dot-{TabName(tab)}");
            if (Application.Current.Resources.TryGetValue("CautionDotInfoBadgeStyle", out var dotStyle)) dot.Style = (Style)dotStyle;
            var item = new NavigationViewItem
            {
                Content = Label(tab),
                Icon = new FontIcon { Glyph = Glyph(tab) },
                Tag = tab,
                InfoBadge = dot,
            }.Id($"settings-tab-{TabName(tab)}");
            items[tab] = item;
            nav.MenuItems.Add(item);
        }
        nav.SelectedItem = items[_tab];
        nav.SelectionChanged += (_, e) =>
        {
            if (e.SelectedItem is not NavigationViewItem { Tag: SettingsTab tab } || tab == _tab) return;
            _tab = tab;
            header.Text = Label(tab);
            _tabHost.Child = _tabPages[tab];
        };
        _tabHost.Child = _tabPages[_tab];

        var scroll = new ScrollViewer
        {
            Content = new Border
            {
                Child = _tabHost,
                MaxWidth = 880,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(0, 4, 0, 32),
            },
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        }.Id("settings-content");

        var top = Ui.Stack(8, StatusBar(), UpdateBar()).MaxWidth(880);
        top.HorizontalAlignment = HorizontalAlignment.Stretch;
        var body = new Grid { Padding = new Thickness(24, 0, 24, 0), RowSpacing = 12 };
        body.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        body.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        body.Children.Add(top);
        Grid.SetRow(scroll, 1);
        body.Children.Add(scroll);
        nav.Content = body;
        Content = nav;

        // The tabs' dots: every tab with something that needs attention.
        OnRefresh(() =>
        {
            var attention = Checking ? [] : Attention().Select(i => i.Tab).ToHashSet();
            foreach (var (tab, item) in items) item.InfoBadge.Shown(attention.Contains(tab));
        });
        // The (hidden, never rebuilt) window was shown again: how installs went is old news, and everything is
        // looked at afresh.
        OnRefresh(() =>
        {
            if (app.MainShown == _shown) return;
            _shown = app.MainShown;
            _installNotes.Clear();
            Check();
        });
        Check();
    }

    private static string TabName(SettingsTab tab) => tab.Name();

    private static string Label(SettingsTab tab) => tab switch
    {
        SettingsTab.Phone => "Phone",
        SettingsTab.Agents => "Coding agents",
        SettingsTab.Terminals => "Terminals",
        _ => "Account",
    };

    private static string Glyph(SettingsTab tab) => tab switch
    {
        SettingsTab.Phone => Ui.Glyph.Phone,
        SettingsTab.Agents => Ui.Glyph.Robot,
        SettingsTab.Terminals => Ui.Glyph.Terminal,
        _ => Ui.Glyph.Account,
    };

    protected override void OnShown()
    {
        _app.Live.Changes += LiveChanged;
        if (_weztermDisposed)
        {
            // Back on screen after leaving it: a fresh installer watch.
            Unwatch(_wezterm);
            _wezterm = WezTermSetup.ForHost(_app.Terminals.WezTerm);
            _weztermDisposed = false;
            Watch(_wezterm);
            Refresh();
        }
    }

    protected override void OnHidden()
    {
        _app.Live.Changes -= LiveChanged;
        _wezterm?.Dispose();
        _weztermDisposed = _wezterm != null;
    }

    /// <summary>A coding session came or went: the agent windows it claims change.</summary>
    private void LiveChanged() => OnUi(() => Run(CheckUnreportedAsync));

    // ---------------------------------------------------------------- checks

    /// <summary>Still looking at the agents or the terminals.</summary>
    private bool Checking => _app.CodingAgents == null || _terminals == null;

    /// <summary>What the system, the terminals and the agents say now: on first build and each time the (hidden,
    /// never rebuilt) window is shown again.</summary>
    private void Check()
    {
        Run(_app.RefreshLaunchAtLoginAsync);
        Run(CheckTerminalsAsync);
        Run(_app.CheckAgentsAsync);
        Run(_app.CheckPhoneAsync);
        Run(CheckDevicesAsync);
        Run(CheckClockAsync);
    }

    private async Task CheckDevicesAsync()
    {
        if (_app.Server == null) return;
        try
        {
            _devices = await _app.ServerDevicesAsync();
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: devices not listed: {e.Message}");
        }
    }

    /// <summary>Whether this computer's clock is far off its server's, while signed in to one; the server built into
    /// this app keeps this computer's own time.</summary>
    private async Task CheckClockAsync()
    {
        var backend = _app.Backend;
        if (backend == null || _app.Server == null || _app.Hosting != null) return;
        var health = await backend.Health();
        if (health.Error == null) _clock = Backend.ClockWarning(health.ClockOffset);
    }

    private async Task CheckTerminalsAsync()
    {
        var statuses = await _app.Terminals.StatusesAsync();
        IReadOnlyList<TermWindow> windows = [];
        try
        {
            windows = await _app.Terminals.WindowsAsync();
        }
        catch (TerminalException)
        {
            // Counted as none.
        }
        _terminals = statuses;
        foreach (var t in statuses)
        {
            if (_fixed.TryGetValue(t.Id, out var f) && f.Fix != t.Fix) _fixed.Remove(t.Id);
        }
        _windowCount = windows.Count;
        _unreported = _app.UnreportedAgentWindows(windows);
    }

    private async Task CheckUnreportedAsync()
    {
        try
        {
            _unreported = _app.UnreportedAgentWindows(await _app.Terminals.WindowsAsync());
        }
        catch (TerminalException)
        {
            // As before.
        }
    }

    // ---------------------------------------------------------------- shared actions

    /// <summary>Phone → Project folders → Add folder…: the picked folders join the list, each once.</summary>
    private async Task AddFoldersAsync()
    {
        var picked = await _app.Host.PickFoldersAsync();
        if (picked.Count == 0) return;
        _app.SetProjectRoots(_app.ProjectRoots.Concat(picked).Distinct().ToList());
    }

    /// <summary>Installs (or updates) PocketTerm in <paramref name="agent"/> once the person confirmed it, from its
    /// card or the status bar; its card says how it went.</summary>
    private async Task InstallAsync(Agent agent)
    {
        var check = _app.CodingAgents?.GetValueOrDefault(agent);
        var update = check != null && Integrations.IntegrationOf(check) == AgentIntegration.Outdated;
        if (!await ConfirmInstall.AgentAsync(agent, _app.Integrations, home: _app.Terminals.Home, update: update)) return;
        if (!Live) return;
        _installing.Add(agent);
        _installNotes.Remove(agent);
        Refresh();
        string? error = null;
        try
        {
            await _app.InstallAgentAsync(agent);
        }
        catch (Exception e)
        {
            error = $"Couldn\u2019t install PocketTerm in {Integrations.Name(agent)}: {e.Message}";
        }
        // Whether it runs: mods may be off.
        var modsOff = _app.CodingAgents?.GetValueOrDefault(agent)?.ModsOff ?? false;
        _installing.Remove(agent);
        _installNotes[agent] = error != null
            ? (error, TextKind.Error)
            : modsOff
                ? ($"Installed · {Integrations.ModsOffHint}", TextKind.Warn)
                : (agent switch
                {
                    Agent.Omp => $"Installed · restart your omp sessions to load it ({agent.Resume()})",
                    _ => $"Installed · type {agent.PickUp()} in open Claude Code sessions to load it",
                }, TextKind.Ok);
    }

    /// <summary><paramref name="agent"/>'s Install (or Update) as <paramref name="label"/>, or that it's going in
    /// (the status bar's; its rows are made again when that changes).</summary>
    private Button AgentButton(Agent agent, string label)
    {
        var installing = _installing.Contains(agent);
        var b = Ui.Button(installing ? "Installing…" : label, () => Run(() => InstallAsync(agent)), accent: !installing);
        b.IsEnabled = !installing;
        return b;
    }

    /// <summary>What picks PocketTerm up in <paramref name="windows"/> (all running <paramref name="agent"/>): in
    /// their omp profile when they share one; the default's command when they're in several (each window's own
    /// shows under Show sessions).</summary>
    private static string PickUpOf(Agent agent, IReadOnlyList<TermWindow> windows)
    {
        var profiles = windows.Select(w => w.Profile).ToHashSet();
        return agent.PickUpIn(profiles.Count == 1 ? profiles.Single() : "");
    }

    private static string Count(int n, string noun) => Ui.Count(n, noun);

    private static void Kind(TextBlock text, TextKind kind) => text.Style = Ui.Style(kind switch
    {
        TextKind.Strong => "PtStrong",
        TextKind.Dim => "PtDim",
        TextKind.Subtitle => "PtSubtitle",
        TextKind.Title => "PtTitle",
        TextKind.Section => "PtSection",
        TextKind.Ok => "PtOkText",
        TextKind.Warn => "PtWarnText",
        TextKind.Error => "PtErrorText",
        _ => "PtBody",
    });

    /// <summary>A tab's cards, one under another as in Windows Settings.</summary>
    private static StackPanel Cards(params UIElement?[] cards) => Ui.Stack(6, cards);
}
