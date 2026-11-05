using System.ComponentModel;

namespace PocketTerm.Core;

/// <summary>One half of a theme, light or dark (ARGB <c>uint</c>s): what colors code, terminal output and
/// the accent. The window itself is Windows' own.</summary>
public sealed record PtTheme
{
    public required string Name { get; init; }

    public required bool Dark { get; init; }

    /// <summary>The terminal's and code blocks' background.</summary>
    public required uint Win { get; init; }

    /// <summary>Bars over terminal output.</summary>
    public required uint Bar { get; init; }

    /// <summary>Fields and pressed rows over terminal output.</summary>
    public required uint Field { get; init; }

    /// <summary>The selected row or tab.</summary>
    public required uint Sel { get; init; }

    /// <summary>Borders and separators.</summary>
    public required uint Line { get; init; }

    /// <summary>The terminal's default foreground.</summary>
    public required uint Text { get; init; }

    /// <summary>Secondary text.</summary>
    public required uint Dim { get; init; }

    /// <summary>Hints and what's off.</summary>
    public required uint Dim2 { get; init; }

    /// <summary>The accent; on <see cref="PlatformAccent"/> palettes only a stand-in for Windows' own.</summary>
    public required uint Accent { get; init; }

    /// <summary>Text and icons on <see cref="Accent"/>.</summary>
    public required uint OnAccent { get; init; }

    public required uint Ok { get; init; }

    public required uint Warn { get; init; }

    public required uint Error { get; init; }

    /// <summary>Raised surfaces over terminal output.</summary>
    public required uint Card { get; init; }

    public required uint Cursor { get; init; }

    /// <summary>Selected text's background (it may be translucent).</summary>
    public required uint Selection { get; init; }

    /// <summary>ANSI colors 0–15: 8 normal, then 8 bright.</summary>
    public required IReadOnlyList<uint> Ansi { get; init; }

    /// <summary>The accent is the platform's (the System theme): the app puts Windows' own in place of
    /// <see cref="Accent"/>.</summary>
    public bool PlatformAccent { get; init; }

    /// <summary>A terminal's colors from this palette: its 16 ANSI colors, then xterm's cube and greys.</summary>
    public TermColors TermColors => new(Text, Win, Ansi.Concat(Enumerable.Range(16, 240).Select(TermColors.Xterm)).ToList());

    private static uint[] Rgb(params uint[] rgb) => rgb.Select(c => 0xFF000000u | c).ToArray();

    /// <summary>xterm's 16 basic colors, the System theme's in light and dark alike
    /// (https://github.com/ThomasDickey/xterm-snapshots/blob/master/XTerm-col.ad, as <see cref="TermColors.Xterm"/>).</summary>
    public static readonly IReadOnlyList<uint> Xterm16 = Enumerable.Range(0, 16).Select(TermColors.Xterm).ToArray();

    // System: Apple Terminal's Basic profile, black on white or light on near-black, with xterm's colors; the
    // greys, greens, oranges and reds are Apple's system colors
    // (https://developer.apple.com/design/human-interface-guidelines/color), the same on every platform. The
    // accent is the platform's.
    public static readonly PtTheme SystemLight = new()
    {
        Name = "System Light", Dark = false,
        Win = 0xFFFFFFFF, Bar = 0xFFF2F2F7, Field = 0xFFF2F2F7, Sel = 0xFFE5E5EA, Line = 0xFFC6C6C8,
        Text = 0xFF000000, Dim = 0xFF8E8E93, Dim2 = 0xFFAEAEB2, Accent = 0xFF007AFF, OnAccent = 0xFFFFFFFF,
        Ok = 0xFF34C759, Warn = 0xFFFF9500, Error = 0xFFFF3B30, Card = 0xFFF2F2F7, Cursor = 0xFF929292,
        Selection = 0xFFB3D7FF, Ansi = Xterm16, PlatformAccent = true,
    };

    public static readonly PtTheme SystemDark = new()
    {
        Name = "System Dark", Dark = true,
        Win = 0xFF1E1E1E, Bar = 0xFF1C1C1E, Field = 0xFF2C2C2E, Sel = 0xFF3A3A3C, Line = 0xFF38383A,
        Text = 0xFFF2F2F2, Dim = 0xFF8E8E93, Dim2 = 0xFF636366, Accent = 0xFF0A84FF, OnAccent = 0xFFFFFFFF,
        Ok = 0xFF30D158, Warn = 0xFFFF9F0A, Error = 0xFFFF453A, Card = 0xFF1C1C1E, Cursor = 0xFF929292,
        Selection = 0xFF3F638B, Ansi = Xterm16, PlatformAccent = true,
    };

    // Catppuccin: https://github.com/catppuccin/palette/blob/main/palette.json (v1.8.0, colors and ansiColors);
    // cursor Rosewater and selection Overlay 2 at 25% as
    // https://github.com/catppuccin/catppuccin/blob/main/docs/style-guide.md has them.
    public static readonly PtTheme Latte = new()
    {
        Name = "Catppuccin Latte", Dark = false,
        Win = 0xFFEFF1F5, Bar = 0xFFE6E9EF, Field = 0xFFCCD0DA, Sel = 0xFFCCD0DA, Line = 0xFFBCC0CC,
        Text = 0xFF4C4F69, Dim = 0xFF6C6F85, Dim2 = 0xFF8C8FA1, Accent = 0xFF8839EF, OnAccent = 0xFFEFF1F5,
        Ok = 0xFF40A02B, Warn = 0xFFFE640B, Error = 0xFFD20F39, Card = 0xFFE6E9EF, Cursor = 0xFFDC8A78,
        Selection = 0x407C7F93,
        Ansi = Rgb(
            0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
            0x6C6F85, 0xDE293E, 0x49AF3D, 0xEEA02D, 0x456EFF, 0xFE85D8, 0x2D9FA8, 0xBCC0CC),
    };

    public static readonly PtTheme Mocha = new()
    {
        Name = "Catppuccin Mocha", Dark = true,
        Win = 0xFF1E1E2E, Bar = 0xFF181825, Field = 0xFF313244, Sel = 0xFF313244, Line = 0xFF45475A,
        Text = 0xFFCDD6F4, Dim = 0xFFA6ADC8, Dim2 = 0xFF7F849C, Accent = 0xFFCBA6F7, OnAccent = 0xFF1E1E2E,
        Ok = 0xFFA6E3A1, Warn = 0xFFFAB387, Error = 0xFFF38BA8, Card = 0xFF181825, Cursor = 0xFFF5E0DC,
        Selection = 0x409399B2,
        Ansi = Rgb(
            0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
            0x585B70, 0xF37799, 0x89D88B, 0xEBD391, 0x74A8FC, 0xF2AEDE, 0x6BD7CA, 0xBAC2DE),
    };

    // Rosé Pine: https://rosepinetheme.com/palette/ingredients/ (roles: love errors, gold warnings, foam
    // additions); cursor, selection and ANSI colors from https://github.com/rose-pine/kitty/tree/main/dist.
    public static readonly PtTheme Dawn = new()
    {
        Name = "Rosé Pine Dawn", Dark = false,
        Win = 0xFFFAF4ED, Bar = 0xFFF2E9E1, Field = 0xFFF2E9E1, Sel = 0xFFDFDAD9, Line = 0xFFDFDAD9,
        Text = 0xFF575279, Dim = 0xFF797593, Dim2 = 0xFF9893A5, Accent = 0xFF286983, OnAccent = 0xFFFAF4ED,
        Ok = 0xFF56949F, Warn = 0xFFEA9D34, Error = 0xFFB4637A, Card = 0xFFFFFAF3, Cursor = 0xFFCECACD,
        Selection = 0xFFDFDAD9,
        Ansi = Rgb(
            0xF2E9E1, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x575279,
            0x9893A5, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x575279),
    };

    public static readonly PtTheme RosePine = new()
    {
        Name = "Rosé Pine", Dark = true,
        Win = 0xFF191724, Bar = 0xFF1F1D2E, Field = 0xFF26233A, Sel = 0xFF403D52, Line = 0xFF403D52,
        Text = 0xFFE0DEF4, Dim = 0xFF908CAA, Dim2 = 0xFF6E6A86, Accent = 0xFF9CCFD8, OnAccent = 0xFF191724,
        Ok = 0xFF31748F, Warn = 0xFFF6C177, Error = 0xFFEB6F92, Card = 0xFF1F1D2E, Cursor = 0xFF524F67,
        Selection = 0xFF403D52,
        Ansi = Rgb(
            0x26233A, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
            0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4),
    };

    // Tokyo Night: https://github.com/folke/tokyonight.nvim/blob/main/extras/lua/tokyonight_day.lua and
    // tokyonight_night.lua (bg, bg_dark, bg_highlight, bg_visual, fg_gutter, fg, dark5, comment, blue, green,
    // orange, red); cursor and ANSI colors from extras/kitty/tokyonight_day.conf and tokyonight_night.conf.
    public static readonly PtTheme TokyoNightDay = new()
    {
        Name = "Tokyo Night Day", Dark = false,
        Win = 0xFFE1E2E7, Bar = 0xFFD0D5E3, Field = 0xFFC4C8DA, Sel = 0xFFB7C1E3, Line = 0xFFA8AECB,
        Text = 0xFF3760BF, Dim = 0xFF68709A, Dim2 = 0xFF848CB5, Accent = 0xFF2E7DE9, OnAccent = 0xFFE1E2E7,
        Ok = 0xFF587539, Warn = 0xFFB15C00, Error = 0xFFF52A65, Card = 0xFFD0D5E3, Cursor = 0xFF3760BF,
        Selection = 0xFFB7C1E3,
        Ansi = Rgb(
            0xB4B5B9, 0xF52A65, 0x587539, 0x8C6C3E, 0x2E7DE9, 0x9854F1, 0x007197, 0x6172B0,
            0xA1A6C5, 0xFF4774, 0x5C8524, 0xA27629, 0x358AFF, 0xA463FF, 0x007EA8, 0x3760BF),
    };

    public static readonly PtTheme TokyoNight = new()
    {
        Name = "Tokyo Night", Dark = true,
        Win = 0xFF1A1B26, Bar = 0xFF16161E, Field = 0xFF292E42, Sel = 0xFF283457, Line = 0xFF3B4261,
        Text = 0xFFC0CAF5, Dim = 0xFF737AA2, Dim2 = 0xFF565F89, Accent = 0xFF7AA2F7, OnAccent = 0xFF16161E,
        Ok = 0xFF9ECE6A, Warn = 0xFFFF9E64, Error = 0xFFF7768E, Card = 0xFF16161E, Cursor = 0xFFC0CAF5,
        Selection = 0xFF283457,
        Ansi = Rgb(
            0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
            0x414868, 0xFF899D, 0x9FE044, 0xFABA4A, 0x8DB0FF, 0xC7A9FF, 0xA4DAFF, 0xC0CAF5),
    };
}

/// <summary>The theme the person picked; <see cref="System"/> until they pick one. Each has a light and a
/// dark palette, shown as Windows' appearance is.</summary>
public enum ThemeChoice
{
    System,
    Catppuccin,
    RosePine,
    TokyoNight,
}

/// <summary><see cref="ThemeChoice"/>'s members.</summary>
public static class ThemeChoices
{
    /// <summary>How Settings names it.</summary>
    public static string Label(this ThemeChoice c) => c switch
    {
        ThemeChoice.Catppuccin => "Catppuccin",
        ThemeChoice.RosePine => "Rosé Pine",
        ThemeChoice.TokyoNight => "Tokyo Night",
        _ => "System",
    };

    public static PtTheme Light(this ThemeChoice c) => c switch
    {
        ThemeChoice.Catppuccin => PtTheme.Latte,
        ThemeChoice.RosePine => PtTheme.Dawn,
        ThemeChoice.TokyoNight => PtTheme.TokyoNightDay,
        _ => PtTheme.SystemLight,
    };

    public static PtTheme Dark(this ThemeChoice c) => c switch
    {
        ThemeChoice.Catppuccin => PtTheme.Mocha,
        ThemeChoice.RosePine => PtTheme.RosePine,
        ThemeChoice.TokyoNight => PtTheme.TokyoNight,
        _ => PtTheme.SystemDark,
    };

    /// <summary>The half that goes with the system's appearance.</summary>
    public static PtTheme Palette(this ThemeChoice c, bool dark) => dark ? c.Dark() : c.Light();

    /// <summary>The accent is the platform's own.</summary>
    public static bool PlatformAccent(this ThemeChoice c) => c == ThemeChoice.System;

    /// <summary>The choice a kept name stands for: this version's names, and those of earlier ones
    /// (<c>mocha</c> and 0.1.2's <c>auto</c> → Catppuccin, <c>dawn</c> → Rosé Pine, <c>gruvbox</c>, which is
    /// gone, → Catppuccin); nothing kept, or a name no version had → System.</summary>
    public static ThemeChoice Migrating(string? kept) => kept switch
    {
        null => ThemeChoice.System,
        "mocha" or "auto" or "gruvbox" => ThemeChoice.Catppuccin,
        "dawn" => ThemeChoice.RosePine,
        _ => DartEnum.Parse<ThemeChoice>(kept) ?? ThemeChoice.System,
    };
}

/// <summary>The active theme, the choice behind it and Windows' appearance, kept per device; notifies when
/// either changes. The app tells it the appearance (<see cref="Follow"/>).</summary>
public sealed class Appearance : ObservableObject
{
    /// <summary>The preference the choice is kept under.</summary>
    public const string PrefsKey = "theme";

    /// <summary>The app's one <see cref="Appearance"/>.</summary>
    public static Appearance Shared { get; } = new();

    private IPreferenceStore? _prefs;

    public ThemeChoice Choice { get; private set; } = ThemeChoice.System;

    /// <summary>Windows shows dark.</summary>
    public bool Dark { get; private set; }

    /// <summary>The palette showing now.</summary>
    public PtTheme Theme => Choice.Palette(Dark);

    /// <summary>Reads the kept choice (<see cref="ThemeChoices.Migrating"/>); an earlier version's name is
    /// kept under this version's.</summary>
    public void Load(IPreferenceStore prefs)
    {
        _prefs = prefs;
        var kept = prefs.GetString(PrefsKey);
        Choice = ThemeChoices.Migrating(kept);
        if (kept is not null && kept != Choice.Name()) prefs.SetString(PrefsKey, Choice.Name());
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

    /// <summary>Windows' appearance changed (or is first known).</summary>
    public void Follow(bool dark)
    {
        if (dark == Dark) return;
        Dark = dark;
        NotifyChanged();
    }
}

/// <summary>The app icon that goes with the theme.</summary>
public static class AppIcon
{
    /// <summary>The app icon that goes with <paramref name="choice"/>: <c>default</c> (the bundle's own
    /// icon, Catppuccin Mocha's) for System and Catppuccin, else <c>dawn</c> (Rosé Pine) or
    /// <c>tokyoNight</c>, the alternates the native sides know by these names.</summary>
    public static string For(ThemeChoice choice) => choice switch
    {
        ThemeChoice.RosePine => "dawn",
        ThemeChoice.TokyoNight => "tokyoNight",
        _ => "default",
    };

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
