using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;

namespace PocketTerm.Core;

/// <summary>Dart semantics the live protocol leans on: <c>as</c> casts on decoded JSON, <c>toString</c>,
/// <c>trim</c> and the regex <c>\s</c> class.</summary>
internal static class LiveJson
{
    /// <summary>Dart's (JavaScript's) regex <c>\s</c>, as a character class body.</summary>
    public const string Ws = @"\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff";

    /// <summary>The characters Dart's <c>String.trim</c> removes (DartString.DartTrim's set).</summary>
    private static readonly char[] TrimChars =
    [
        '\t', '\n', '\v', '\f', '\r', ' ', '\u0085', '\u00a0', '\u1680', '\u2000', '\u2001', '\u2002', '\u2003',
        '\u2004', '\u2005', '\u2006', '\u2007', '\u2008', '\u2009', '\u200a', '\u2028', '\u2029', '\u202f',
        '\u205f', '\u3000', '\ufeff',
    ];

    /// <summary>Dart's <c>s.trimLeft()</c>.</summary>
    public static string DartTrimLeft(this string s) => s.TrimStart(TrimChars);

    /// <summary><c>j[k] as String</c>.</summary>
    public static string ReqStr(JsonObject j, string k) =>
        DartJson.AsString(j[k]) ?? throw new InvalidCastException($"'{k}' is not a String");

    /// <summary><c>j[k] as String?</c>.</summary>
    public static string? OptStr(JsonObject j, string k)
    {
        var n = j[k];
        if (n is null) return null;
        return DartJson.AsString(n) ?? throw new InvalidCastException($"'{k}' is not a String?");
    }

    /// <summary><c>j[k] as int</c>.</summary>
    public static long ReqInt(JsonObject j, string k) =>
        DartJson.AsInt(j[k]) ?? throw new InvalidCastException($"'{k}' is not an int");

    /// <summary><c>j[k] as int?</c>.</summary>
    public static long? OptInt(JsonObject j, string k)
    {
        var n = j[k];
        if (n is null) return null;
        return DartJson.AsInt(n) ?? throw new InvalidCastException($"'{k}' is not an int?");
    }

    /// <summary><c>j[k] as List?</c>.</summary>
    public static JsonArray? OptList(JsonObject j, string k)
    {
        var n = j[k];
        if (n is null) return null;
        return n as JsonArray ?? throw new InvalidCastException($"'{k}' is not a List?");
    }

    /// <summary><c>j[k] as Map?</c>.</summary>
    public static JsonObject? OptMap(JsonObject j, string k)
    {
        var n = j[k];
        if (n is null) return null;
        return n as JsonObject ?? throw new InvalidCastException($"'{k}' is not a Map?");
    }

    public static bool IsTrue(JsonNode? n) => DartJson.AsBool(n) == true;

    /// <summary>Dart's <c>'$v'</c> of a decoded JSON value.</summary>
    public static string DartToString(JsonNode? n)
    {
        var sb = new StringBuilder();
        Write(sb, n);
        return sb.ToString();
    }

    private static void Write(StringBuilder sb, JsonNode? n)
    {
        switch (n)
        {
            case null:
                sb.Append("null");
                return;
            case JsonArray a:
                sb.Append('[');
                for (var i = 0; i < a.Count; i++)
                {
                    if (i > 0) sb.Append(", ");
                    Write(sb, a[i]);
                }
                sb.Append(']');
                return;
            case JsonObject o:
                sb.Append('{');
                var first = true;
                foreach (var (k, v) in o)
                {
                    if (!first) sb.Append(", ");
                    first = false;
                    sb.Append(k).Append(": ");
                    Write(sb, v);
                }
                sb.Append('}');
                return;
        }
        if (DartJson.AsString(n) is { } s) sb.Append(s);
        else if (DartJson.AsBool(n) is { } b) sb.Append(b ? "true" : "false");
        else if (DartJson.AsInt(n) is { } i) sb.Append(i.ToString(CultureInfo.InvariantCulture));
        else if (DartJson.AsNum(n) is { } d) sb.Append(DartJson.FormatDouble(d));
        else sb.Append("null");
    }

    public static JsonArray Strings(IEnumerable<string> items) => new(items.Select(s => (JsonNode?)JsonValue.Create(s)).ToArray());
}
