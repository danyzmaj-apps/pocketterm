using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Components;
using PocketTerm.App.Views;
using PocketTerm.Desktop;

namespace PocketTerm.App.Pages;

/// <summary>
/// First run: PocketTerm's server runs on this computer, reached through Tailscale, after a checklist that follows
/// Tailscale as the person sets it up. Or this computer joins another computer's PocketTerm by the setup link
/// that computer's Settings, Add a computer… makes. Where it was left is kept
/// (<see cref="AppController.SetupStep"/>) and it opens there again.
/// </summary>
internal sealed class SetupPage : View
{
    /// <summary>The setup's screens, saved by name.</summary>
    private enum Step
    {
        /// <summary>The Tailscale checklist, then Start.</summary>
        ThisComputer,

        /// <summary>Another computer's setup link.</summary>
        Join,
    }

    private static string StepName(Step step) => step == Step.Join ? "join" : "thisComputer";

    private readonly AppController _app;
    private readonly TimeSpan _poll;
    private readonly ContentControl _host = new()
    {
        HorizontalContentAlignment = HorizontalAlignment.Stretch,
        IsTabStop = false,
    };
    private readonly ScrollViewer _scroll;

    /// <param name="app">The controller.</param>
    /// <param name="poll">How often the checklist looks again (3 s); zero: only once.</param>
    public SetupPage(AppController app, TimeSpan? poll = null)
    {
        _app = app;
        _poll = poll ?? TimeSpan.FromSeconds(3);
        _scroll = Ui.Page(_host, 560, "setup-page");
        Content = _scroll;
        Show(app.SetupStep == StepName(Step.Join) ? Step.Join : Step.ThisComputer);
    }

    private void Go(Step step)
    {
        _app.SetSetupStep(step == Step.ThisComputer ? null : StepName(step));
        Show(step);
    }

    private void Show(Step step)
    {
        _host.Content = step switch
        {
            Step.Join => Ui.Stack(
                0,
                SetupParts.Header(
                    "Join another computer’s PocketTerm",
                    "On a computer whose PocketTerm runs its server, open Settings → Add a computer…, then paste the " +
                    "setup link it shows. Both computers need Tailscale, on the same tailnet.",
                    () => Go(Step.ThisComputer)),
                new SetupLinkForm(_app)),
            _ => new ThisComputerSetup(_app, () => Go(Step.Join), _poll),
        };
        _scroll.ChangeView(null, 0, null, true);
    }
}
