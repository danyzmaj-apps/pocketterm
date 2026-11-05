using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace PocketTerm.App.Views;

/// <summary>ContentDialogs over the main window. WinUI shows one at a time: a second waits for the first.</summary>
internal static class Dialogs
{
    private static readonly SemaphoreSlim One = new(1, 1);

    /// <summary>Shows <paramref name="dialog"/> in the window's theme; what was pressed.</summary>
    public static async Task<ContentDialogResult> ShowAsync(ContentDialog dialog)
    {
        await One.WaitAsync();
        try
        {
            var root = Shell.Window.Content as FrameworkElement
                ?? throw new InvalidOperationException("The window has no content yet");
            dialog.XamlRoot = root.XamlRoot;
            dialog.RequestedTheme = root.ActualTheme;
            if (Application.Current.Resources.TryGetValue("DefaultContentDialogStyle", out var style)) dialog.Style = (Style)style;
            return await dialog.ShowAsync();
        }
        finally
        {
            One.Release();
        }
    }

    /// <summary>
    /// Asks before something that can't be undone (Flutter's <c>confirmDanger</c>): true when the person presses
    /// <paramref name="action"/>. Cancel is the default button, so Enter doesn't do it.
    /// </summary>
    public static async Task<bool> ConfirmAsync(string title, string body, string action, string? id = null)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = Ui.Text(body),
            PrimaryButtonText = action,
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        if (id != null) dialog.Id(id);
        return await ShowAsync(dialog) == ContentDialogResult.Primary;
    }

    /// <summary>An information dialog with one button (<paramref name="close"/>) around <paramref name="content"/>.</summary>
    public static Task<ContentDialogResult> InfoAsync(string title, UIElement content, string close = "Done", string? id = null)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            CloseButtonText = close,
            DefaultButton = ContentDialogButton.Close,
        };
        if (id != null) dialog.Id(id);
        return ShowAsync(dialog);
    }
}
