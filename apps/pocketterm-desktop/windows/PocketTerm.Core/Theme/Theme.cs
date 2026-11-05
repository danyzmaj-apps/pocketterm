using System.ComponentModel;

namespace PocketTerm.Core;

/// <summary>
/// How a theme's parts are shaped, after the kitty theme it comes from: soft round and airy
/// (Catppuccin, Rosé Pine), crisp small corners and hairlines (Tokyo Night), boxy square, heavy
/// borders and capital labels (Gruvbox).
/// </summary>
/// <param name="Name">Dart's enum name: <c>soft</c>, <c>crisp</c>, <c>boxy</c>.</param>
/// <param name="MaxRadius">The largest corner radius anything gets: a pill on soft stays a pill, on crisp it's 6, on boxy nearly square.</param>
/// <param name="Border">Border width of fields, cards and dialogs.</param>
/// <param name="Caps">Section and chip labels in capitals.</param>
/// <param name="DividerAlpha">How strongly separators show, from the line color.</param>
/// <param name="Density">Spacing of buttons, fields and list rows: Flutter's VisualDensity on both axes (standard 0, comfortable −1).</param>
public sealed record ThemeShape(string Name, double MaxRadius, double Border, bool Caps, double DividerAlpha, double Density)
{
    public static readonly ThemeShape Soft = new("soft", double.PositiveInfinity, 1, false, .6, 0);
    public static readonly ThemeShape Crisp = new("crisp", 6, .5, false, 1, -1);
    public static readonly ThemeShape Boxy = new("boxy", 2, 2, true, 1, 0);

    /// <summary><paramref name="radius"/> as the shape allows: as is when soft, capped when crisp or boxy.</summary>
    public double R(double radius) => radius < MaxRadius ? radius : MaxRadius;

    /// <summary>A section or chip label in the shape's case.</summary>
    public string Label(string text) => Caps ? text.ToUpperInvariant() : text;
}

/// <summary>One theme: a kitty theme's colors (ARGB <c>uint</c>s) and its <see cref="Shape"/>.</summary>
public sealed record PtTheme
{
    public required string Name { get; init; }

    public required bool Dark { get; init; }

    public required ThemeShape Shape { get; init; }

    /// <summary>The window's background.</summary>
    public required uint Win { get; init; }

    /// <summary>Title, tab and status bars.</summary>
    public required uint Bar { get; init; }

    /// <summary>Text fields and pressed or hovered rows.</summary>
    public required uint Field { get; init; }

    /// <summary>The selected row or tab.</summary>
    public required uint Sel { get; init; }

    /// <summary>Borders and separators.</summary>
    public required uint Line { get; init; }

    public required uint Text { get; init; }

    /// <summary>Secondary text.</summary>
    public required uint Dim { get; init; }

    /// <summary>Hints and what's off.</summary>
    public required uint Dim2 { get; init; }

    public required uint Accent { get; init; }

    /// <summary>Text and icons on <see cref="Accent"/>.</summary>
    public required uint OnAccent { get; init; }

    public required uint Ok { get; init; }

    public required uint Warn { get; init; }

    public required uint Error { get; init; }

    /// <summary>Raised surfaces: cards, sheets, dialogs, menus.</summary>
    public required uint Card { get; init; }

    /// <summary>A field's border: a step stronger than <see cref="Line"/>.</summary>
    public uint Line2 => Argb.Lerp(Line, Dim2, .3);

    /// <summary>Separators between rows.</summary>
    public uint Divider => Argb.WithAlpha(Line, Shape.DividerAlpha);

    public static readonly PtTheme Mocha = new()
    {
        Name = "Catppuccin Mocha",
        Dark = true,
        Shape = ThemeShape.Soft,
        Win = 0xFF1E1E2E,
        Bar = 0xFF181825,
        Field = 0xFF313244,
        Sel = 0xFF313244,
        Line = 0xFF45475A,
        Text = 0xFFCDD6F4,
        Dim = 0xFF82879E,
        Dim2 = 0xFF71758C,
        Accent = 0xFFCBA6F7,
        OnAccent = 0xFF1E1E2E,
        Ok = 0xFFA6E3A1,
        Warn = 0xFFFAB387,
        Error = 0xFFF38BA8,
        Card = 0xFF181825,
    };

    public static readonly PtTheme Dawn = new()
    {
        Name = "Rosé Pine Dawn",
        Dark = false,
        Shape = ThemeShape.Soft,
        Win = 0xFFFAF4ED,
        Bar = 0xFFF2E9E1,
        Field = 0xFFF2E9E1,
        Sel = 0xFFE0D6CB,
        Line = 0xFFDFDAD9,
        Text = 0xFF534E73,
        Dim = 0xFF6F6B89,
        Dim2 = 0xFF837D92,
        Accent = 0xFF286983,
        OnAccent = 0xFFFAF4ED,
        Ok = 0xFF55784D,
        Warn = 0xFF9E6210,
        Error = 0xFFAB526C,
        Card = 0xFFFFFAF3,
    };

    public static readonly PtTheme TokyoNight = new()
    {
        Name = "Tokyo Night",
        Dark = true,
        Shape = ThemeShape.Crisp,
        Win = 0xFF1A1B26,
        Bar = 0xFF16161E,
        Field = 0xFF24283B,
        Sel = 0xFF24283B,
        Line = 0xFF2F3549,
        Text = 0xFFC0CAF5,
        Dim = 0xFF767DA4,
        Dim2 = 0xFF656F9E,
        Accent = 0xFF7AA2F7,
        OnAccent = 0xFF16161E,
        Ok = 0xFF9ECE6A,
        Warn = 0xFFFF9E64,
        Error = 0xFFF7768E,
        Card = 0xFF16161E,
    };

    public static readonly PtTheme Gruvbox = new()
    {
        Name = "Gruvbox Material",
        Dark = true,
        Shape = ThemeShape.Boxy,
        Win = 0xFF282828,
        Bar = 0xFF1D2021,
        Field = 0xFF32302F,
        Sel = 0xFF32302F,
        Line = 0xFF45403D,
        Text = 0xFFD4BE98,
        Dim = 0xFF928374,
        Dim2 = 0xFF87796D,
        Accent = 0xFF7DAEA3,
        OnAccent = 0xFF1D2021,
        Ok = 0xFFA9B665,
        Warn = 0xFFD8A657,
        Error = 0xFFEA6962,
        Card = 0xFF1D2021,
    };
}

/// <summary>The theme the person picked; <see cref="Mocha"/> until they pick one.</summary>
public enum ThemeChoice
{
    Mocha,
    Dawn,
    TokyoNight,
    Gruvbox,
}

/// <summary><see cref="ThemeChoice"/>'s members.</summary>
public static class ThemeChoices
{
    /// <summary>How Settings names it.</summary>
    public static string Label(this ThemeChoice c) => c.Theme().Name;

    /// <summary>The theme this choice shows.</summary>
    public static PtTheme Theme(this ThemeChoice c) => c switch
    {
        ThemeChoice.Dawn => PtTheme.Dawn,
        ThemeChoice.TokyoNight => PtTheme.TokyoNight,
        ThemeChoice.Gruvbox => PtTheme.Gruvbox,
        _ => PtTheme.Mocha,
    };
}

/// <summary>The active theme and the choice behind it, kept per device; notifies when the choice changes.</summary>
public sealed class Appearance : ObservableObject
{
    /// <summary>The preference the choice is kept under.</summary>
    public const string PrefsKey = "theme";

    /// <summary>The app's one <see cref="Appearance"/>.</summary>
    public static Appearance Shared { get; } = new();

    private IPreferenceStore? _prefs;

    public ThemeChoice Choice { get; private set; } = ThemeChoice.Mocha;

    /// <summary>The theme showing now.</summary>
    public PtTheme Theme => Choice.Theme();

    /// <summary>Reads the kept choice: Catppuccin Mocha when there's none or it's one this version
    /// doesn't know (0.1.2's <c>auto</c> among them).</summary>
    public void Load(IPreferenceStore prefs)
    {
        _prefs = prefs;
        Choice = DartEnum.Parse<ThemeChoice>(prefs.GetString(PrefsKey)) ?? ThemeChoice.Mocha;
        NotifyChanged();
    }

    /// <summary>Shows <paramref name="choice"/> now and keeps it.</summary>
    public void Choose(ThemeChoice choice)
    {
        if (choice == Choice) return;
        Choice = choice;
        NotifyChanged();
        _prefs?.SetString(PrefsKey, choice.Name());
    }
}

/// <summary>The app icon that goes with the theme.</summary>
public static class AppIcon
{
    /// <summary>The app icon that goes with <paramref name="choice"/>: <c>default</c> (the bundle's own
    /// icon, Catppuccin Mocha's) for Mocha, else <c>dawn</c>, <c>tokyoNight</c> or <c>gruvbox</c>, the
    /// alternates the native sides know by these names.</summary>
    public static string For(ThemeChoice choice) => choice == ThemeChoice.Mocha ? "default" : choice.Name();

    /// <summary>Keeps the app icon on <paramref name="appearance"/>'s choice: <paramref name="apply"/> gets
    /// <see cref="For"/>'s name now and after each change of choice. Returns what stops it.</summary>
    public static Action Follow(Appearance appearance, Func<string, Task> apply)
    {
        string? shown = null;
        void Sync()
        {
            var icon = For(appearance.Choice);
            if (icon == shown) return;
            shown = icon;
            _ = Run(icon);
        }
        async Task Run(string icon)
        {
            try
            {
                await apply(icon);
            }
            catch (Exception e)
            {
                Log.Print($"PocketTerm: app icon {icon}: {e.Message}");
            }
        }
        void Changed(object? sender, PropertyChangedEventArgs e) => Sync();
        appearance.PropertyChanged += Changed;
        Sync();
        return () => appearance.PropertyChanged -= Changed;
    }
}
