using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Views;
using PocketTerm.Desktop;

namespace PocketTerm.App.Components;

/// <summary>
/// Where the built-in server stands, in a line (<see cref="BuiltInServer.Status"/>), with what to do about it:
/// install or open Tailscale, turn HTTPS on, look again; and, once a rename broke the phones' address, what that
/// means with a Got it.
/// </summary>
internal sealed class HostingStatusView : View
{
    public HostingStatusView(BuiltInServer server)
    {
        var ring = new ProgressRing { IsActive = true, Width = 16, Height = 16 };
        var ok = Ui.Icon(Ui.Glyph.Check, 16, "PtOkIcon");
        var warn = Ui.Icon(Ui.Glyph.Warning, 16, "PtWarnIcon");
        var mark = new Grid { Width = 16, Height = 16, Children = { ring, ok, warn } };
        var text = Ui.Dim("").Selectable();
        text.TextWrapping = TextWrapping.Wrap;
        text.Id("hosting-status");
        var actions = new WrapPanel { Margin = new Thickness(26, 0, 0, 0) };
        var renamed = new InfoBar
        {
            Severity = InfoBarSeverity.Warning,
            IsOpen = true,
            IsClosable = false,
            ActionButton = Ui.Button("Got it", server.RenameSeen, "hosting-renamed-seen"),
        }.Id("hosting-renamed");
        Content = Ui.Stack(8, Ui.Leading(mark, text), actions, renamed);

        Watch(server);
        OnRefresh(() =>
        {
            var status = server.Status;
            ring.Shown(status.Ok == null);
            ring.IsActive = status.Ok == null;
            ok.Shown(status.Ok == true);
            warn.Shown(status.Ok == false);
            text.Text = status.Text;
            actions.Shown(status.Actions.Count > 0);
            actions.Sync(
                status.Actions.Select((a, i) => (Action: a, First: i == 0)),
                a => $"{a.Action}:{a.First}",
                a => Button(server, a.Action, a.First));
            renamed.Shown(status.Renamed != null);
            renamed.Message = status.Renamed ?? "";
        });
    }

    /// <summary>The button for <paramref name="action"/>; the first is the fix, in the accent color.</summary>
    private Button Button(BuiltInServer server, HostAction action, bool first) => action switch
    {
        HostAction.InstallTailscale => Ui.Button("Install Tailscale", () => Ui.Open(Tailscale.Download), "hosting-install-tailscale", first),
        HostAction.OpenTailscale => Ui.Button("Open Tailscale", () => Run(server.Tailscale.OpenAsync), "hosting-open-tailscale", first),
        HostAction.TurnOnHttps => Ui.Button("Turn on HTTPS…", () => Ui.Open(server.HttpsPage), "hosting-enable-https", first),
        _ => Ui.Button("Check again", () => Run(server.RefreshAsync), "hosting-check-again", first),
    };
}
