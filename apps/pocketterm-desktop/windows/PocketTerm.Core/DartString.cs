using System.Text;

namespace PocketTerm.Core;

/// <summary>Dart's <c>String</c> methods where .NET's differ.</summary>
public static class DartString
{
    /// <summary>Dart's whitespace for <c>trim()</c>: Unicode White_Space plus the BOM (U+FEFF), which .NET's
    /// <c>Trim()</c> keeps.</summary>
    public static bool IsDartWhitespace(char c) => char.IsWhiteSpace(c) || c == '\uFEFF';

    /// <summary>Dart's <c>s.trim()</c>.</summary>
    public static string DartTrim(this string s)
    {
        var start = 0;
        var end = s.Length;
        while (start < end && IsDartWhitespace(s[start])) start++;
        while (end > start && IsDartWhitespace(s[end - 1])) end--;
        return start == 0 && end == s.Length ? s : s[start..end];
    }

    /// <summary>Dart's <c>int.tryParse(s)</c> (base 10): an optional sign, then digits, nothing else (Dart
    /// trims whitespace first).</summary>
    public static long? TryParseInt(string s)
    {
        var t = s.DartTrim();
        if (t.Length == 0) return null;
        var i = t[0] is '+' or '-' ? 1 : 0;
        if (i == t.Length) return null;
        for (var j = i; j < t.Length; j++)
        {
            if (t[j] is < '0' or > '9') return null;
        }
        return long.TryParse(t, System.Globalization.NumberStyles.AllowLeadingSign, System.Globalization.CultureInfo.InvariantCulture, out var v)
            ? v
            : null;
    }

    /// <summary>Strict UTF-8 (Dart's <c>utf8.decode</c>): throws <see cref="DecoderFallbackException"/> on bad bytes.</summary>
    public static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
}
