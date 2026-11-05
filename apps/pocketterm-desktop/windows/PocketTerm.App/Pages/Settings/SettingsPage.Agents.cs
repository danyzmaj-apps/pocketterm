using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TextRun = Microsoft.UI.Xaml.Documents.Run;
using PocketTerm.App.Components;
using PocketTerm.App.Views;
using PocketTerm.Core;
using PocketTerm.Desktop;

namespace PocketTerm.App.Pages;

internal sealed partial class SettingsPage
{
    private UIElement AgentsTab()
    {
        var cards = Enum.GetValues<Agent>().Select(AgentCard).ToList();
        var footer = Ui.Card(Ui.Dim(
            "The default agent is what a new session from your phone starts. PocketTerm talks to your phone "
            + "through a small add-on inside each agent."));
        return Cards([.. cards, footer]);
    }

    /// <summary>Where PocketTerm in <paramref name="agent"/> stands, for its card.</summary>
    private (string Text, TextKind Kind) AgentState(Agent agent)
    {
        if (_installNotes.TryGetValue(agent, out var note)) return note;
        var agents = _app.CodingAgents;
        if (agents == null) return ("Checking…", TextKind.Dim);
        if (!agents.TryGetValue(agent, out var check)) return ("Not found on this computer", TextKind.Dim);
        if (check.State.Problem is { } problem) return (problem, TextKind.Warn);
        return Integrations.IntegrationOf(check) switch
        {
            AgentIntegration.Installed => ("PocketTerm installed, up to date", TextKind.Ok),
            AgentIntegration.Off => (Integrations.ModsOffHint, TextKind.Warn),
            AgentIntegration.Outdated => ("PocketTerm here is out of date", TextKind.Warn),
            _ => ("PocketTerm isn\u2019t installed here yet", TextKind.Warn),
        };
    }

    private UIElement AgentCard(Agent agent)
    {
        var name = agent.Name();
        var action = Ui.Button("", () => Run(() => InstallAsync(agent)), $"settings-install-{name}", accent: true);
        var badge = new Border
        {
            Style = Ui.Style("PtNote"),
            Padding = new Thickness(10, 2, 10, 2),
            CornerRadius = new CornerRadius(12),
            Child = Ui.Text("Default"),
            VerticalAlignment = VerticalAlignment.Center,
        }.Id($"settings-default-{name}");
        var trailing = Ui.Row(8, action, badge);

        var profiles = Ui.Dim("").Id("settings-omp-profiles");
        var pickUp = new TextBlock { TextWrapping = TextWrapping.Wrap };
        Kind(pickUp, TextKind.Warn);
        var showSessions = Ui.Button("Show sessions", () =>
        {
            if (!_showSessions.Remove(agent)) _showSessions.Add(agent);
            Refresh();
        }, $"settings-show-sessions-{name}");
        var sessions = new StackPanel { Spacing = 6 };
        var makeDefault = Ui.Button("Make default", () => _app.SetCodingAgent(agent), $"settings-make-default-{name}");
        var body = Ui.Stack(10, profiles, pickUp, showSessions, sessions, makeDefault);

        var card = Ui.SettingsCard(Integrations.Name(agent), icon: Ui.Glyph.Robot, trailing: trailing);
        card.Root.Id($"settings-agent-{name}");
        OnRefresh(() =>
        {
            var check = _app.CodingAgents?.GetValueOrDefault(agent);
            var missing = _app.CodingAgents != null && check == null;
            var isDefault = agent == _app.CodingAgent;
            var (text, kind) = AgentState(agent);
            card.SetDescription(text);
            Kind(card.Description, kind);

            var installing = _installing.Contains(agent);
            var offer = installing || check is { State: { Current: false, Problem: null } };
            action.Shown(offer);
            action.Content = installing ? "Installing…" : check?.State.Installed ?? false ? "Update" : "Install";
            action.IsEnabled = !installing;
            badge.Shown(isDefault);
            trailing.Shown(offer || isDefault);

            profiles.Shown(agent == Agent.Omp && _app.OmpProfiles.Count > 0);
            profiles.Text = $"Profiles: default, {string.Join(", ", _app.OmpProfiles)}";

            var windows = _unreported.Where(w => w.Agent == agent).ToList();
            var n = windows.Count;
            var each = n == 1 ? "it" : "each";
            pickUp.Inlines.Clear();
            pickUp.Inlines.Add(new TextRun
            {
                Text = agent switch
                {
                    Agent.Omp => $"{Count(n, "session")} opened before PocketTerm: reopen {each} with ",
                    _ => $"{Count(n, "session")} opened before PocketTerm: type ",
                },
            });
            pickUp.Inlines.Add(new TextRun { Text = PickUpOf(agent, windows), FontFamily = Ui.Mono });
            if (agent == Agent.Claude) pickUp.Inlines.Add(new TextRun { Text = $" in {each}" });
            pickUp.Shown(n > 0);
            var shown = _showSessions.Contains(agent);
            showSessions.Shown(n > 0);
            showSessions.Content = shown ? "Hide sessions" : "Show sessions";
            sessions.Sync(
                n > 0 && shown ? windows : [],
                w => w.Key,
                w => new SessionToPickUp(window: w, terminals: _app.Terminals).Id($"settings-unreported-{w.Key}"));
            sessions.Shown(n > 0 && shown);
            makeDefault.Shown(!isDefault && !missing);

            var anyBody = profiles.Visibility == Visibility.Visible || n > 0 || (!isDefault && !missing);
            card.SetBody(anyBody ? body : null);
            card.Root.Opacity = missing ? .6 : 1;
        });
        return card;
    }
}
