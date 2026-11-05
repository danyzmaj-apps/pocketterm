using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Components;
using PocketTerm.App.Views;
using PocketTerm.Core;
using PocketTerm.Desktop;

namespace PocketTerm.App.Pages;

internal sealed partial class SettingsPage
{
    /// <summary>Something that needs the person on this computer: the tab it's on, a few words for the status bar's
    /// line, the whole of it for its list, and the button that does it where one can (<see cref="ActionKey"/> says
    /// which, so a row is made again only when it changes).</summary>
    private sealed record Item(SettingsTab Tab, string Short, string Text, string? ActionKey = null, Func<UIElement>? Action = null);

    /// <summary>What needs the person on this computer, each with the button that does it where one can: the status
    /// bar's list.</summary>
    private List<Item> Attention()
    {
        var items = new List<Item>();
        if (_app.CodingAgents is { } agents)
        {
            if (agents.Count == 0)
            {
                items.Add(new(
                    SettingsTab.Agents,
                    "No coding agent found",
                    "No coding agent found: install omp or Claude Code, and PocketTerm offers to set it up here"));
            }
            foreach (var (agent, check) in agents)
            {
                var name = Integrations.Name(agent);
                var failed = _installNotes.TryGetValue(agent, out var note) && note.Kind == TextKind.Error ? note.Text : null;
                var installing = _installing.Contains(agent) ? "installing" : "";
                switch (Integrations.IntegrationOf(check))
                {
                    case AgentIntegration.Installed:
                        break;
                    case AgentIntegration.Off:
                        items.Add(new(SettingsTab.Agents, $"{name} has mods off", Integrations.ModsOffHint));
                        break;
                    case AgentIntegration.Outdated:
                        items.Add(new(
                            SettingsTab.Agents,
                            $"PocketTerm in {name} is out of date",
                            failed ?? $"PocketTerm in {name} is out of date",
                            $"update{installing}",
                            () => AgentButton(agent, "Update")));
                        break;
                    case AgentIntegration.Missing:
                        var problem = check.State.Problem;
                        items.Add(new(
                            SettingsTab.Agents,
                            problem ?? $"PocketTerm isn\u2019t installed in {name}",
                            problem ?? failed ?? $"PocketTerm isn\u2019t installed in {name}",
                            problem == null ? $"install{installing}" : null,
                            problem == null ? () => AgentButton(agent, "Install") : null));
                        break;
                }
            }
        }
        foreach (var agent in Enum.GetValues<Agent>())
        {
            var windows = _unreported.Where(w => w.Agent == agent).ToList();
            var n = windows.Count;
            if (n == 0) continue;
            var them = n == 1 ? "it" : "them";
            items.Add(new(
                SettingsTab.Agents,
                agent switch
                {
                    Agent.Claude => $"{Count(n, "Claude Code session")} to reload",
                    _ => $"{Count(n, "omp session")} to reopen",
                },
                agent switch
                {
                    Agent.Claude => $"{Count(n, "Claude Code session")} opened before PocketTerm: type {agent.PickUp()} in {them}",
                    _ => $"{Count(n, "omp session")} opened before PocketTerm: quit omp in {them} and run {PickUpOf(agent, windows)}",
                }));
        }
        var terminals = _terminals ?? [];
        foreach (var s in TerminalFixes.TerminalsNeedingSetup(terminals))
        {
            var (key, action) = FixAction(s);
            items.Add(new(
                SettingsTab.Terminals,
                $"{s.Label} needs setup",
                // Their notes name the terminal already.
                _fixed.TryGetValue(s.Id, out var f) ? f.Note : s.Note.Length == 0 ? $"{s.Label} needs setup" : s.Note,
                key,
                action));
        }
        if (_terminals != null && TerminalFixes.NoTerminalApp(terminals))
        {
            items.Add(new(
                SettingsTab.Terminals,
                "No terminal app found",
                "No terminal app found: PocketTerm works with kitty, iTerm2, Ghostty and WezTerm"));
        }
        if (_clock is { } clock) items.Add(new(SettingsTab.Account, "This computer\u2019s clock is off", clock));
        if (_app.PhoneClockOff is { } off)
        {
            // Dart: (off.inSeconds.abs() / 60).round(), inSeconds truncating, round() half away from zero.
            var minutes = (long)Math.Round(Math.Abs((long)off.TotalSeconds) / 60.0, MidpointRounding.AwayFromZero);
            items.Add(new(
                SettingsTab.Phone,
                "A phone\u2019s clock is off",
                $"A phone\u2019s clock is {minutes} minutes {(off < TimeSpan.Zero ? "behind" : "ahead of")} this computer\u2019s, so "
                + "what it sends is refused: turn on automatic date and time on both"));
        }
        if (_app.Hosting is { } h && h.State != HostState.Ready && h.State != HostState.Checking)
        {
            var open = h.State is HostState.TailscaleOff or HostState.LoggedOut;
            items.Add(new(
                SettingsTab.Account,
                "Phones can\u2019t reach your server",
                h.State switch
                {
                    HostState.NoTailscale => "Tailscale isn\u2019t installed, so phones can\u2019t reach the server on this computer",
                    HostState.TailscaleOff => "Tailscale isn\u2019t running, so phones can\u2019t reach the server on this computer",
                    HostState.LoggedOut => "Tailscale is signed out, so phones can\u2019t reach the server on this computer",
                    _ => "Tailscale doesn\u2019t serve this computer\u2019s server, so phones can\u2019t reach it: see Account",
                },
                open ? "open-tailscale" : null,
                open ? () => Ui.Button("Open Tailscale", () => Run(h.Tailscale.OpenAsync), "attention-open-tailscale") : null));
        }
        else if (_app.Hosting?.RenamedFrom is { } old)
        {
            items.Add(new(
                SettingsTab.Account,
                "Tailscale address changed",
                $"This computer\u2019s Tailscale address changed from {DartUri.TryParse(old)?.Host ?? old}: each phone must scan its code again",
                "renamed",
                () => Ui.Button("Add a phone…", () =>
                {
                    _app.Hosting?.RenameSeen();
                    Run(AddPhoneAsync);
                }, "attention-add-phone-renamed")));
        }
        if (_app.PhoneSignedIn == false)
        {
            items.Add(new(
                SettingsTab.Phone,
                "No phone yet",
                "No phone signed in yet",
                "add-phone",
                () => Ui.Button("Add a phone…", () => Run(AddPhoneAsync), "attention-add-phone")));
        }
        if (_app.ProjectRoots.Count == 0)
        {
            items.Add(new(
                SettingsTab.Phone,
                "No project folders",
                "No project folders: your phone can\u2019t list your projects",
                "add-folder",
                () => Ui.Button("Add folder…", () => Run(AddFoldersAsync), "attention-add-folder")));
        }
        return items;
    }

    /// <summary>Settings' top: all set, or what needs attention (listed on Show); and the way back to the setup
    /// checklist.</summary>
    private InfoBar StatusBar()
    {
        var list = new StackPanel { Spacing = 8, Margin = new Thickness(0, 4, 0, 8) };
        var listScroll = new ScrollViewer
        {
            Content = list,
            MaxHeight = 220,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        var toggle = Ui.Link("Show", () =>
        {
            _showAttention = !_showAttention;
            Refresh();
        }, "settings-attention-toggle");
        var bar = new InfoBar
        {
            IsOpen = true,
            IsClosable = false,
            ActionButton = Ui.Link("Open setup checklist", () => _app.SetGetReadyDone(false), "settings-open-checklist"),
            Content = Ui.Stack(0, toggle, listScroll),
        }.Id("settings-status");
        return Bind(bar, b =>
        {
            var checking = Checking;
            var items = checking ? [] : Attention();
            var n = items.Count;
            // Not a spinner: a look may take a while (claude), and nothing moves meanwhile.
            b.Severity = checking ? InfoBarSeverity.Informational : n == 0 ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
            b.Title = checking
                ? "Checking this computer…"
                : n == 0
                    ? "All set"
                    : $"{n} {(n == 1 ? "thing needs" : "things need")} attention";
            b.Message = string.Join(" · ", items.Select(i => i.Short));
            toggle.Shown(n > 0);
            toggle.Content = _showAttention ? "Hide" : "Show";
            listScroll.Shown(_showAttention && n > 0);
            list.Sync(
                _showAttention ? items : [],
                i => $"{i.Tab}|{i.Text}|{i.ActionKey}",
                i =>
                {
                    var text = Ui.Text(i.Text);
                    text.TextWrapping = TextWrapping.Wrap;
                    return Ui.Split(text, i.Action?.Invoke());
                });
        });
    }

    /// <summary>A newer PocketTerm, under the status bar.</summary>
    private InfoBar UpdateBar()
    {
        var download = Ui.Button("Download", () =>
        {
            if (_app.Updates?.Update is { } u) Ui.Open(u.Url);
        }, "settings-update-download", accent: true);
        var bar = new InfoBar
        {
            IsClosable = false,
            Severity = InfoBarSeverity.Informational,
            IconSource = new FontIconSource { Glyph = Ui.Glyph.Download },
            ActionButton = download,
        }.Id("settings-update");
        return Bind(bar, b =>
        {
            var u = _app.Updates?.Update;
            b.IsOpen = u != null;
            b.Shown(u != null);
            b.Title = u == null ? "" : $"PocketTerm {u.Version} is out";
        });
    }
}
