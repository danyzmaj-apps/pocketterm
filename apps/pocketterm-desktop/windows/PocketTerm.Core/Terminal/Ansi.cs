using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace PocketTerm.Core;

/// <summary>
/// A terminal's colors: default foreground and background plus the 256-color palette, as the
/// terminal reports them (kitty's <c>get-colors</c>). Colors are ARGB (<c>0xAARRGGBB</c>).
/// </summary>
public sealed record TermColors(uint Foreground, uint Background, IReadOnlyList<uint> Palette)
{
    /// <summary><c>{fg, bg, palette}</c> as 0xRRGGBB ints, made opaque.</summary>
    public static TermColors FromJson(JsonObject j)
    {
        static uint Opaque(JsonNode? n) =>
            0xFF000000u | (uint)(DartJson.AsInt(n) ?? throw new InvalidCastException("not an int"));
        var palette = ((JsonArray)(j["palette"] ?? throw new InvalidCastException("palette is not a List")))
            .Select(Opaque).ToList();
        return new TermColors(Opaque(j["fg"]), Opaque(j["bg"]), palette);
    }

    private static readonly uint[] Basic =
    [
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ];

    /// <summary>The xterm defaults, until the computer has sent the terminal's.</summary>
    public static readonly TermColors Fallback =
        new(0xFFDDDDDD, 0xFF000000, Enumerable.Range(0, 256).Select(Xterm).ToList());

    /// <summary>xterm's 256 colors: 16 basic, a 6×6×6 cube, 24 greys.</summary>
    public static uint Xterm(int i)
    {
        if (i < 16) return 0xFF000000u | Basic[i];
        if (i < 232)
        {
            static int Level(int v) => v == 0 ? 0 : 55 + v * 40;
            var n = i - 16;
            return Argb.FromArgb(255, Level(n / 36), Level(n / 6 % 6), Level(n % 6));
        }
        var g = 8 + (i - 232) * 10;
        return Argb.FromArgb(255, g, g, g);
    }
}

/// <summary>ARGB colors as <c>uint</c>s (<c>0xAARRGGBB</c>).</summary>
public static class Argb
{
    /// <summary>Flutter's <c>Color.fromARGB</c>: each part masked to 8 bits.</summary>
    public static uint FromArgb(int a, int r, int g, int b) =>
        ((uint)(a & 0xff) << 24) | ((uint)(r & 0xff) << 16) | ((uint)(g & 0xff) << 8) | (uint)(b & 0xff);

    /// <summary>Flutter's <c>color.withValues(alpha: a)</c>.</summary>
    public static uint WithAlpha(uint color, double alpha) =>
        ((uint)Math.Round(Math.Clamp(alpha, 0, 1) * 255) << 24) | (color & 0x00FFFFFF);

    /// <summary>Flutter's <c>Color.lerp(a, b, t)</c>, per channel.</summary>
    public static uint Lerp(uint a, uint b, double t)
    {
        uint Channel(int shift)
        {
            double x = (a >> shift) & 0xff, y = (b >> shift) & 0xff;
            var v = Math.Clamp((x / 255.0) + ((y / 255.0) - (x / 255.0)) * t, 0, 1);
            return (uint)Math.Round(v * 255.0) & 0xff;
        }
        return (Channel(24) << 24) | (Channel(16) << 16) | (Channel(8) << 8) | Channel(0);
    }

    /// <summary><c>#AARRGGBB</c>.</summary>
    public static string Hex(uint color) => $"#{color:X8}";
}

/// <summary>A span's line: underline wins over line-through.</summary>
public enum AnsiDecoration
{
    Underline,
    LineThrough,
}

/// <summary>A run of text in one style: <see cref="Bg"/> null is no background.</summary>
public sealed record AnsiSpan(string Text, uint Fg, uint? Bg, bool Bold, bool Italic, AnsiDecoration? Decoration);

/// <summary>Terminal text with ANSI escapes as styled spans.</summary>
public static partial class Ansi
{
    private sealed class Pen
    {
        public uint? Fg;
        public uint? Bg;
        public bool Bold, Dim, Italic, Underline, Strike, Reverse;

        public void Reset()
        {
            Fg = Bg = null;
            Bold = Dim = Italic = Underline = Strike = Reverse = false;
        }

        public AnsiSpan Span(string text, TermColors c)
        {
            var f = Fg ?? c.Foreground;
            var b = Bg;
            if (Reverse) (f, b) = (b ?? c.Background, f);
            if (Dim) f = Argb.WithAlpha(f, .6);
            return new AnsiSpan(
                text, f, b, Bold, Italic,
                Underline ? AnsiDecoration.Underline : Strike ? AnsiDecoration.LineThrough : null);
        }
    }

    // SGR, other CSI (or one cut off at the end), OSC (to BEL or ESC \, or cut off), DCS, APC, PM
    // and SOS strings (kitty's graphics, tmux passthrough; to ESC \ or cut off), and any other
    // escape: two bytes, or more with intermediates (a charset choice, ESC ( B, as WezTerm sends),
    // or a lone ESC at the end.
    [GeneratedRegex(@"\x1b\[([0-9;:]*)m|\x1b\[[0-9;:?<=>]*[ -/]*(?:[@-~]|\z)|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)?|\x1b[P_^X][^\x1b]*(?:\x1b\\)?|\x1b[ -/]*[0-~]?")]
    private static partial Regex Escape();

    /// <summary>Terminal text with ANSI escapes as styled spans: SGR colors (16, 256 and truecolor,
    /// <c>;</c> or kitty's <c>:</c> form) and attributes; every other escape (hyperlinks, prompt
    /// marks) is dropped.</summary>
    public static List<AnsiSpan> Spans(string text, TermColors colors)
    {
        var spans = new List<AnsiSpan>();
        var pen = new Pen();
        var at = 0;
        foreach (Match m in Escape().Matches(text))
        {
            if (m.Index > at) spans.Add(pen.Span(text[at..m.Index], colors));
            at = m.Index + m.Length;
            if (m.Groups[1].Success) Sgr(m.Groups[1].Value, pen, colors);
        }
        if (at < text.Length) spans.Add(pen.Span(text[at..], colors));
        return spans;
    }

    private static void Sgr(string parameters, Pen pen, TermColors colors)
    {
        // `38:2:r:g:b` stays one group; `38;2;r;g;b` spreads over five.
        var groups = parameters.Length == 0 ? ["0"] : parameters.Split(';');
        for (var i = 0; i < groups.Length; i++)
        {
            var parts = groups[i].Split(':');
            var code = DartString.TryParseInt(parts[0]) ?? 0;
            switch (code)
            {
                case 0: pen.Reset(); break;
                case 1: pen.Bold = true; break;
                case 2: pen.Dim = true; break;
                case 3: pen.Italic = true; break;
                case 4: pen.Underline = parts.Length < 2 || parts[1] != "0"; break;
                case 7: pen.Reverse = true; break;
                case 9: pen.Strike = true; break;
                case 22: pen.Bold = false; pen.Dim = false; break;
                case 23: pen.Italic = false; break;
                case 24: pen.Underline = false; break;
                case 27: pen.Reverse = false; break;
                case 29: pen.Strike = false; break;
                case >= 30 and <= 37: pen.Fg = colors.Palette[(int)code - 30]; break;
                case 39: pen.Fg = null; break;
                case >= 40 and <= 47: pen.Bg = colors.Palette[(int)code - 40]; break;
                case 49: pen.Bg = null; break;
                case >= 90 and <= 97: pen.Fg = colors.Palette[(int)code - 90 + 8]; break;
                case >= 100 and <= 107: pen.Bg = colors.Palette[(int)code - 100 + 8]; break;
                case 38 or 48 or 58:
                    List<long?> args;
                    if (parts.Length > 1)
                    {
                        args = parts.Skip(1).Select(DartString.TryParseInt).ToList();
                    }
                    else
                    {
                        var mode = i + 1 < groups.Length ? DartString.TryParseInt(groups[i + 1]) : null;
                        var n = mode == 2 ? 4 : mode == 5 ? 2 : 1;
                        args = groups.Skip(i + 1).Take(n).Select(DartString.TryParseInt).ToList();
                        i += args.Count;
                    }
                    var color = Extended(args, colors);
                    if (code == 38) pen.Fg = color;
                    if (code == 48) pen.Bg = color;
                    break;
            }
        }
    }

    /// <summary><c>5;n</c> or <c>2;[colorspace;]r;g;b</c>, without the leading 38/48.</summary>
    private static uint? Extended(List<long?> args, TermColors colors)
    {
        if (args.Count == 0) return null;
        if (args[0] == 5 && args.Count > 1)
        {
            var n = args[1];
            return n is { } k && k >= 0 && k < colors.Palette.Count ? colors.Palette[(int)k] : null;
        }
        if (args[0] == 2)
        {
            var rgb = args.Count >= 5 ? args.Skip(args.Count - 3).ToList() : args.Skip(1).ToList();
            if (rgb.Count != 3) return null;
            return Argb.FromArgb(255, (int)(rgb[0] ?? 0), (int)(rgb[1] ?? 0), (int)(rgb[2] ?? 0));
        }
        return null;
    }
}
