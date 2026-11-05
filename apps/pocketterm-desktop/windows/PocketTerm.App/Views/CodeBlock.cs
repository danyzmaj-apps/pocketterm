using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PocketTerm.Core;
using Windows.UI;

namespace PocketTerm.App.Views;

/// <summary>
/// A command, a path or a link shown as code: monospaced, selectable, in the chosen terminal theme's colors (the
/// themes color what's terminal-like; the rest of the window is Windows' light or dark). Follows a theme change.
/// </summary>
internal sealed class CodeBlock : View
{
    private readonly TextBlock _text;
    private readonly Border _box;

    public CodeBlock(string text, string? id = null)
    {
        _text = new TextBlock
        {
            Text = text,
            FontFamily = Ui.Mono,
            FontSize = 12.5,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        };
        _box = new Border
        {
            Child = _text,
            Padding = new Thickness(12, 9, 12, 9),
            CornerRadius = new CornerRadius(6),
            BorderThickness = new Thickness(1),
        };
        if (id != null) _text.Id(id);
        Content = _box;
        Watch(Appearance.Shared);
        OnRefresh(Paint);
    }

    public string Text
    {
        get => _text.Text;
        set => _text.Text = value;
    }

    /// <summary>The block's text element (for an AutomationId on what screen readers read).</summary>
    public TextBlock TextElement => _text;

    private void Paint()
    {
        var t = Appearance.Shared.Theme;
        _box.Background = new SolidColorBrush(Colorize(t.Win));
        _box.BorderBrush = new SolidColorBrush(Colorize(t.Line));
        _text.Foreground = new SolidColorBrush(Colorize(t.Text));
        _text.SelectionHighlightColor = new SolidColorBrush(Accent.Of(t));
    }

    /// <summary>A theme's ARGB as a WinUI color.</summary>
    public static Color Colorize(uint argb) =>
        ColorHelper.FromArgb((byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb);
}
