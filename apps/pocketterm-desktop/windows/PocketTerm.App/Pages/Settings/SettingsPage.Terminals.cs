using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Views;
using PocketTerm.Core;
using PocketTerm.Desktop;

namespace PocketTerm.App.Pages;

internal sealed partial class SettingsPage
{
    /// <summary>A ComboBox's selection being set from the settings, not by the person.</summary>
    private bool _choosing;

    /// <summary>WezTerm was installed as of the last refresh: once it is, the terminals are looked at again.</summary>
    private bool _weztermInstalled;

    private UIElement TerminalsTab()
    {
        var opensIn = Ui.SettingsCard("New sessions open in", icon: Ui.Glyph.Terminal, trailing: TerminalAppChoice());
        OnRefresh(() => opensIn.SetDescription(OpensInSub()));
        var place = Ui.SettingsCard("Place them", icon: Ui.Glyph.Computer, trailing: PlacementChoice());
        OnRefresh(() => place.SetDescription(_app.Placement switch
        {
            Placement.ProjectWindow =>
                "A new tab in the window that already has the project\u2019s tabs; a new window when none does. "
                + "Sessions in your home folder (General) share a window too.",
            _ => "A new window for every session.",
        }));

        var cards = new Dictionary<string, TerminalCard>();
        var list = new StackPanel { Spacing = 6 };
        OnRefresh(() =>
        {
            if (_wezterm?.Installed == true && !_weztermInstalled) Run(CheckTerminalsAsync);
            _weztermInstalled = _wezterm?.Installed == true;
            var shown = (_terminals ?? []).Where(s => s.State != TermState.Missing || s.Id == "tmux" || s.Fix != null).ToList();
            foreach (var gone in cards.Keys.Except(shown.Select(s => s.Id)).ToList()) cards.Remove(gone);
            list.Sync(
                shown,
                s => s.Id,
                s =>
                {
                    var card = new TerminalCard(this, s.Id);
                    cards[s.Id] = card;
                    card.Update(s);
                    return card.Card;
                },
                (_, s) => cards[s.Id].Update(s));
        });

        return Cards(opensIn, place, list);
    }

    /// <summary>Where a session from the phone opens, and what tmux adds there.</summary>
    private string OpensInSub()
    {
        var chosen = _app.Terminals.Apps.FirstOrDefault(h => h.Id == _app.TerminalApp);
        var where = chosen == null ? "Auto: the terminal app you used last" : $"Always {chosen.Label}";
        var tmux = _terminals?.FirstOrDefault(s => s.Id == "tmux");
        if (tmux == null) return where;
        return tmux.State == TermState.Missing
            ? $"{where} · in Ghostty your phone can\u2019t see the screen or answer: install tmux for full control"
            : $"{where} · in Ghostty they run in tmux, so your phone has full control";
    }

    /// <summary>Auto, or one of the terminal apps found here (and the one chosen, should it be gone).</summary>
    private ComboBox TerminalAppChoice()
    {
        var box = new ComboBox { MinWidth = 160 }.Id("settings-terminal-app", "New sessions open in");
        var shown = "";
        box.SelectionChanged += (_, _) =>
        {
            if (_choosing || box.SelectedItem is not ComboBoxItem { Tag: string id } || id == _app.TerminalApp) return;
            _app.SetTerminalApp(id);
        };
        return Bind(box, b =>
        {
            var chosen = _app.TerminalApp;
            var apps = _app.Terminals.Apps
                .Where(h => h.Id == chosen || (_terminals?.Any(s => s.Id == h.Id && s.State != TermState.Missing) ?? false))
                .Select(h => (Id: h.Id, Label: h.Label))
                .Prepend((Id: "auto", Label: "Auto"))
                .ToList();
            var value = chosen == "auto" || apps.Any(a => a.Id == chosen) ? chosen : "auto";
            _choosing = true;
            try
            {
                var key = string.Join("\n", apps.Select(a => $"{a.Id}\t{a.Label}"));
                if (key != shown)
                {
                    shown = key;
                    b.Items.Clear();
                    foreach (var (id, label) in apps) b.Items.Add(new ComboBoxItem { Content = label, Tag = id }.Id($"settings-terminal-app-{id}"));
                }
                b.SelectedItem = b.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == value);
            }
            finally
            {
                _choosing = false;
            }
        });
    }

    private ComboBox PlacementChoice()
    {
        var box = new ComboBox { MinWidth = 160 }.Id("settings-placement", "Place them");
        box.Items.Add(new ComboBoxItem { Content = "Tab in the project\u2019s window", Tag = Placement.ProjectWindow }.Id("settings-placement-projectWindow"));
        box.Items.Add(new ComboBoxItem { Content = "New window", Tag = Placement.NewWindow }.Id("settings-placement-newWindow"));
        box.SelectionChanged += (_, _) =>
        {
            if (_choosing || box.SelectedItem is not ComboBoxItem { Tag: Placement p } || p == _app.Placement) return;
            _app.SetPlacement(p);
        };
        return Bind(box, b =>
        {
            _choosing = true;
            try
            {
                b.SelectedItem = b.Items.OfType<ComboBoxItem>().First(i => (Placement)i.Tag == _app.Placement);
            }
            finally
            {
                _choosing = false;
            }
        });
    }

    /// <summary><paramref name="s"/>'s one-click fix as the status bar offers it: which (so its row is made again when
    /// it changes) and the control. On Windows the one fix is WezTerm's Install (<see cref="WezTermSetup"/>).</summary>
    private (string? Key, Func<UIElement>? Make) FixAction(TermStatus s) => s.Fix switch
    {
        TermFix.Install when _wezterm == null => (null, null),
        TermFix.Install when _wezterm.State == WezTermSetupState.Missing =>
            ("install", () => Ui.Button("Install", () => Run(() => FixAsync(s)), $"attention-fix-{s.Id}")),
        TermFix.Install => ("installing", () => new ProgressRing { IsActive = true, Width = 16, Height = 16 }),
        _ => (null, null),
    };

    /// <summary>Settings' one click for <paramref name="s"/>: WezTerm's installer fetched and opened
    /// (<see cref="WezTermSetup"/>), whose progress its card shows; any other fix through
    /// <see cref="TerminalFixes.FixTerminalAsync"/>, its note shown on the card until the status changes.</summary>
    private async Task FixAsync(TermStatus s)
    {
        if (s.Fix == TermFix.Install)
        {
            if (_wezterm is { } w) Run(w.InstallAsync);
            return;
        }
        var (note, failed) = await TerminalFixes.FixTerminalAsync(s, _wezterm);
        _fixed[s.Id] = (s.Fix, note, failed);
        Refresh();
        await CheckTerminalsAsync();
    }

    /// <summary>A terminal's card: how it stands, and its one-click fix if it has one.</summary>
    private sealed class TerminalCard
    {
        private readonly SettingsPage _page;
        private readonly SettingsCard _card;
        private readonly Button _install;
        private readonly ProgressRing _ring = new() { IsActive = true, Width = 16, Height = 16 };
        private TermStatus? _status;

        public TerminalCard(SettingsPage page, string id)
        {
            _page = page;
            _install = Ui.Button("Install", () =>
            {
                if (_status != null) page.Run(() => page.FixAsync(_status));
            }, $"settings-fix-{id}", accent: true);
            _card = Ui.SettingsCard(id, icon: Ui.Glyph.Terminal);
            _card.Root.Id($"settings-terminal-{id}");
        }

        public UIElement Card => _card.Root;

        public void Update(TermStatus s)
        {
            _status = s;
            var wezterm = _page._wezterm;
            var state = s.State switch
            {
                TermState.Ready => "Ready",
                TermState.Limited => "Limited",
                TermState.Setup => "Needs setup",
                TermState.Idle => "Not running",
                _ => "Not installed",
            };
            // Only tmux, and a terminal with an install fix, show while missing, with how to get it.
            var installing = s.Fix == TermFix.Install ? wezterm?.Note : null;
            var note = installing
                ?? (_page._fixed.TryGetValue(s.Id, out var f) ? f.Note : null)
                ?? (s.State == TermState.Missing || s.Note.Length == 0 || s.Note == state
                    ? (s.Note.Length == 0 ? state : s.Note)
                    : $"{state} · {s.Note}");
            var attention = s.State == TermState.Setup || (s.Fix == TermFix.Install && s.State == TermState.Missing);
            _card.Header.Text = s.Label;
            _card.SetDescription(note);
            Kind(_card.Description, installing != null && wezterm?.Error != null
                ? TextKind.Error
                : attention || s.State == TermState.Limited
                    ? TextKind.Warn
                    : s.State == TermState.Ready
                        ? TextKind.Ok
                        : TextKind.Dim);
            _card.SetTrailing(s.Fix switch
            {
                TermFix.Install when wezterm == null => null,
                TermFix.Install when wezterm.State == WezTermSetupState.Missing => _install,
                TermFix.Install => _ring,
                _ => null,
            });
        }
    }
}
