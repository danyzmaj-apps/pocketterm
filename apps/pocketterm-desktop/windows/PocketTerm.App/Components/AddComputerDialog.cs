using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Views;
using PocketTerm.Desktop;

namespace PocketTerm.App.Components;

/// <summary>
/// Settings → Account → "Add a computer…" (showAddComputer): the setup link another computer pastes (Join another
/// computer's PocketTerm…) to join this computer's server through Tailscale. <c>how</c> says what the other computer does with it.
/// </summary>
internal static class AddComputerDialog
{
    public static async Task ShowAsync(string link, string how = BuiltInServer.AddComputerHow)
    {
        var howText = Ui.Dim(how);
        howText.TextWrapping = TextWrapping.Wrap;
        var warning = Ui.Dim(BuiltInServer.AddComputerWarning);
        warning.FontSize = 11.5;
        warning.TextWrapping = TextWrapping.Wrap;
        var content = Ui.Stack(12, howText, new CodeBlock(link, "add-computer-link"), warning);
        content.MaxWidth = 380;
        var dialog = new ContentDialog
        {
            Title = "Add a computer",
            Content = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            PrimaryButtonText = "Copy link",
            CloseButtonText = "Done",
            DefaultButton = ContentDialogButton.Close,
        }.Id("add-computer");
        // Copying keeps the dialog open; its button says it worked (a toast would sit behind the dialog).
        dialog.PrimaryButtonClick += (d, e) =>
        {
            e.Cancel = true;
            Ui.Copy(link);
            d.PrimaryButtonText = "Link copied";
        };
        dialog.Opened += (_, _) => ConfirmInstall.IdPart(dialog, "PrimaryButton", "add-computer-copy");
        await Dialogs.ShowAsync(dialog);
    }
}
