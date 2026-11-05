using Microsoft.UI.Xaml;
using PocketTerm.Core;
using Windows.UI;

namespace PocketTerm.App.Views;

/// <summary>
/// The chosen theme's accent as Windows' accent color for the app (buttons, switches, links, selection): the
/// five themes are terminal-and-accent themes here, the window itself is Windows' light or dark.
/// </summary>
internal static class Accent
{
    private static readonly Color White = Color.FromArgb(255, 255, 255, 255);
    private static readonly Color Black = Color.FromArgb(255, 0, 0, 0);

    /// <summary>Sets the accent resources WinUI's brushes are made of. Before the first window, or followed by
    /// <see cref="Repaint"/>.</summary>
    public static void Apply(Application app, PtTheme theme)
    {
        var c = CodeBlock.Colorize(theme.Accent);
        var r = app.Resources;
        r["SystemAccentColor"] = c;
        r["SystemAccentColorLight1"] = Lerp(c, White, .2);
        r["SystemAccentColorLight2"] = Lerp(c, White, .4);
        r["SystemAccentColorLight3"] = Lerp(c, White, .6);
        r["SystemAccentColorDark1"] = Lerp(c, Black, .25);
        r["SystemAccentColorDark2"] = Lerp(c, Black, .45);
        r["SystemAccentColorDark3"] = Lerp(c, Black, .6);
    }

    /// <summary>WinUI resolves theme resources again only when a theme changes: flipping <paramref name="root"/>'s
    /// theme and back makes the controls take the new accent.</summary>
    public static void Repaint(FrameworkElement root)
    {
        var theme = root.RequestedTheme;
        root.RequestedTheme = root.ActualTheme == ElementTheme.Dark ? ElementTheme.Light : ElementTheme.Dark;
        root.RequestedTheme = theme;
    }

    private static Color Lerp(Color a, Color b, double t) => Color.FromArgb(
        255,
        (byte)Math.Round(a.R + (b.R - a.R) * t),
        (byte)Math.Round(a.G + (b.G - a.G) * t),
        (byte)Math.Round(a.B + (b.B - a.B) * t));
}
