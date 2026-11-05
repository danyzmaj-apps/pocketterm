using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Views;
using PocketTerm.Desktop;

namespace PocketTerm.App.Components;

/// <summary>
/// Windows: WezTerm, checked off when it's on the PC, else one button to install it (its own installer, visible,
/// checked against WezTerm's published SHA-256) and the winget line for those who'd rather type it.
/// </summary>
internal sealed class WezTermCard : View
{
    private readonly WezTermSetup _setup;

    public WezTermCard(WezTermSetup setup)
    {
        _setup = setup;
        var installedText = Ui.Text("WezTerm is installed: your phone can reach its windows.");
        installedText.TextWrapping = TextWrapping.Wrap;
        var installed = Ui.Leading(Ui.Icon(Ui.Glyph.CheckCircle, 18, "PtOkIcon"), installedText).Id("wezterm-installed");

        var why = Ui.Dim(
            "On Windows, PocketTerm works through WezTerm, a free terminal app. Sessions you start from " +
            "your phone open in it, and its windows show on your phone. Windows Terminal and PowerShell " +
            "windows don't.");
        why.TextWrapping = TextWrapping.Wrap;
        var install = Ui.Button("Install WezTerm", () => Run(InstallAsync), "wezterm-install", accent: true);
        var progress = new ProgressBar { Minimum = 0, Maximum = 1 }.Id("wezterm-progress");
        var note = Ui.Dim("").Selectable();
        note.TextWrapping = TextWrapping.Wrap;
        note.Id("wezterm-note");
        var or = Ui.Dim("Or type this in PowerShell");
        or.FontSize = 11.5;
        var missing = Ui.Stack(
            0,
            why,
            install.Margin(0, 12, 0, 0),
            progress.Margin(0, 8, 0, 0),
            note.Margin(0, 8, 0, 0),
            or.Margin(0, 12, 0, 6),
            new CopyCommand(WezTermSetup.WingetCommand, "wezterm-winget"));
        Content = Ui.Stack(0, installed, missing);

        Watch(setup);
        OnRefresh(() =>
        {
            var state = setup.State;
            installed.Shown(state == WezTermSetupState.Installed);
            missing.Shown(state != WezTermSetupState.Installed);
            install.IsEnabled = state == WezTermSetupState.Missing;
            install.Content = state switch
            {
                WezTermSetupState.Downloading => "Downloading WezTerm…",
                WezTermSetupState.Installing => "Finish in WezTerm\u2019s installer",
                _ => "Install WezTerm",
            };
            var downloading = state == WezTermSetupState.Downloading;
            progress.Shown(downloading);
            progress.IsIndeterminate = setup.Progress == null;
            progress.Value = setup.Progress ?? 0;
            var n = setup.Note;
            note.Shown(n != null && !downloading);
            note.Text = n ?? "";
            note.Style = Ui.Style(setup.Error != null ? "PtErrorText" : "PtDim");
        });
    }

    /// <summary>Downloads and opens WezTerm's installer once the person confirmed it.</summary>
    private async Task InstallAsync()
    {
        var go = await ConfirmInstall.ShowAsync(
            title: "Install WezTerm?",
            why:
                "On Windows, PocketTerm works through WezTerm: sessions you start from your phone open in it, and its " +
                "windows show on your phone.",
            what:
                "PocketTerm downloads WezTerm\u2019s own installer from its GitHub release, checks it against WezTerm\u2019s " +
                "published checksum and opens it; you click through the installer yourself.",
            undo: "To take it out later, uninstall WezTerm from Windows Settings, Apps.");
        if (go) await _setup.InstallAsync();
    }
}
