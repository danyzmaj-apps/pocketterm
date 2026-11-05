using System.Globalization;
using System.Text.RegularExpressions;

namespace PocketTerm.Core;

/// <summary>
/// Dart's <c>DateTime.parse</c> / <c>tryParse</c> (ISO 8601 as Dart takes it: a time without an offset is
/// local) and <c>toUtc().toIso8601String()</c> (<c>2026-10-22T12:00:00.000Z</c>, microseconds only when
/// there are any).
/// </summary>
public static partial class DartDate
{
    /// <summary>Dart's <c>DateTime.tryParse</c>; null when Dart's would be.</summary>
    public static DateTimeOffset? TryParse(string? text)
    {
        if (text is null) return null;
        var m = Iso().Match(text);
        if (!m.Success) return null;
        int G(int i) => m.Groups[i].Success && m.Groups[i].Value.Length > 0 ? int.Parse(m.Groups[i].Value, CultureInfo.InvariantCulture) : 0;
        var year = int.Parse(m.Groups[1].Value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
        var month = G(2);
        var day = G(3);
        var hour = G(4);
        var minute = G(5);
        var second = G(6);
        long ticks = 0;
        if (m.Groups[7].Success)
        {
            // Dart reads milli- and microseconds (the first 6 digits); ticks go one digit further.
            var frac = m.Groups[7].Value;
            frac = frac.Length > 6 ? frac[..6] : frac.PadRight(6, '0');
            ticks = long.Parse(frac, CultureInfo.InvariantCulture) * 10;
        }
        try
        {
            // Dart lets fields overflow into the next (month 13 is next January); so does this.
            var local = new DateTime(year, 1, 1, 0, 0, 0, DateTimeKind.Unspecified)
                .AddMonths(month - 1).AddDays(day - 1).AddHours(hour).AddMinutes(minute).AddSeconds(second).AddTicks(ticks);
            if (!m.Groups[8].Success) return new DateTimeOffset(DateTime.SpecifyKind(local, DateTimeKind.Local));
            var utc = local;
            if (m.Groups[9].Success)
            {
                var sign = m.Groups[9].Value == "-" ? -1 : 1;
                var offset = new TimeSpan(G(10), G(11), 0);
                utc = local - sign * offset;
            }
            return new DateTimeOffset(utc, TimeSpan.Zero);
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    /// <summary>Dart's <c>DateTime.parse</c>: throws <see cref="FormatException"/>.</summary>
    public static DateTimeOffset Parse(string text) => TryParse(text) ?? throw new FormatException($"Invalid date format {text}");

    /// <summary>Dart's <c>toUtc().toIso8601String()</c>.</summary>
    public static string ToIso8601Utc(DateTimeOffset t)
    {
        var u = t.UtcDateTime;
        var micros = u.Ticks % TimeSpan.TicksPerSecond / 10;
        var ms = micros / 1000;
        var us = micros % 1000;
        var year = u.Year.ToString(u.Year >= 10000 ? "+000000" : "0000", CultureInfo.InvariantCulture);
        var s = $"{year}-{u:MM}-{u:dd}T{u:HH}:{u:mm}:{u:ss}.{ms:000}";
        if (us != 0) s += us.ToString("000", CultureInfo.InvariantCulture);
        return s + "Z";
    }

    /// <summary>Milliseconds since the epoch (Dart's <c>millisecondsSinceEpoch</c>).</summary>
    public static long Ms(this DateTimeOffset t) => t.ToUnixTimeMilliseconds();

    /// <summary>Dart's <c>DateTime.fromMillisecondsSinceEpoch</c>.</summary>
    public static DateTimeOffset FromMs(long ms) => DateTimeOffset.FromUnixTimeMilliseconds(ms);

    [GeneratedRegex(@"^([+-]?[0-9]{4,6})-?([0-9][0-9])-?([0-9][0-9])(?:[ T]([0-9][0-9])(?::?([0-9][0-9])(?::?([0-9][0-9])(?:[.,]([0-9]+))?)?)?( ?[zZ]| ?([-+])([0-9][0-9])(?::?([0-9][0-9]))?)?)?\z")]
    private static partial Regex Iso();
}
