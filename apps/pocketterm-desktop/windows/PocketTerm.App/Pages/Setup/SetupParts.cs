using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Views;

namespace PocketTerm.App.Pages;

/// <summary>The pieces every first-run setup screen is made of: its heading with Back, an option to pick, a
/// notice, the screen's main button and its error.</summary>
internal static class SetupParts
{
    private const string ChevronRight = "\uE76C";

    /// <summary>A screen's heading and its way back (<c>setup-back</c>).</summary>
    public static StackPanel Header(string title, string text, Action onBack) => Ui.Stack(
        8,
        Ui.IconButton(Ui.Glyph.Back, "Back", onBack, "setup-back").Align(HorizontalAlignment.Left),
        Ui.Text(title, TextKind.Subtitle),
        Ui.Text(text)).Margin(0, 0, 0, 10);

    /// <summary>One of a screen's choices: a full-width button with an icon, its title and what it means.</summary>
    public static Button Option(string id, string glyph, string title, string text, Action onClick)
    {
        var grid = new Grid { ColumnSpacing = 14 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = Ui.Icon(glyph, 24, "PtAccentIcon");
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 2, 0, 0);
        grid.Children.Add(icon);
        var texts = Ui.Stack(4, Ui.Strong(title), Ui.Dim(text));
        Grid.SetColumn(texts, 1);
        grid.Children.Add(texts);
        var chevron = Ui.Icon(ChevronRight, 12, "PtDimIcon");
        chevron.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(chevron, 2);
        grid.Children.Add(chevron);
        var button = new Button
        {
            Content = grid,
            Padding = new Thickness(16),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        button.Click += (_, _) => onClick();
        return button.Id(id, title);
    }

    /// <summary>A note the person must not miss (Flutter's <c>_notice</c>), open while it has <paramref name="text"/>.</summary>
    public static InfoBar Notice(string? text, string id, InfoBarSeverity severity = InfoBarSeverity.Informational, string? glyph = null)
    {
        var bar = new InfoBar { IsClosable = false, Severity = severity }.Id(id);
        if (glyph != null) bar.IconSource = new FontIconSource { Glyph = glyph };
        Show(bar, text);
        return bar;
    }

    /// <summary>A screen's error: open while there is one.</summary>
    public static InfoBar Error(string id) => Notice(null, id, InfoBarSeverity.Error);

    /// <summary>Opens <paramref name="bar"/> with <paramref name="text"/>, or closes it for null.</summary>
    public static void Show(InfoBar bar, string? text)
    {
        if (text != null && bar.Message != text) bar.Message = text;
        bar.IsOpen = text != null;
        bar.Shown(text != null);
    }

    /// <summary>A screen's main action: the accent button, full width.</summary>
    public static Button Primary(string label, Action onClick, string id)
    {
        var button = Ui.Button(label, onClick, id, accent: true);
        button.HorizontalAlignment = HorizontalAlignment.Stretch;
        button.Padding = new Thickness(12, 8, 12, 8);
        AutomationProperties.SetName(button, label);
        return button;
    }

    /// <summary>A main button while its work runs: a progress ring instead of its label, and it waits.</summary>
    public static void Busy(Button button, string label, bool busy, bool enabled = true)
    {
        button.IsEnabled = enabled && !busy;
        if (busy)
        {
            if (button.Content is not ProgressRing) button.Content = new ProgressRing { IsActive = true, Width = 16, Height = 16 };
        }
        else if (button.Content is not string s || s != label)
        {
            button.Content = label;
        }
    }

    /// <summary>A text with a link to its right (Flutter's Row of text and TextButton).</summary>
    public static Grid TextWithLink(string text, string label, string url, string id) =>
        Ui.Split(Ui.Dim(text), Ui.WebLink(label, url, id));
}
