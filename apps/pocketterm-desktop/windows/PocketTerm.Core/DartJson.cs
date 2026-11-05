using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace PocketTerm.Core;

/// <summary>
/// JSON exactly as Dart's <c>dart:convert</c> writes and reads it: what crosses the wire
/// (live channel messages, chunk sizes, the local API's frames) must be byte for byte what
/// the Dart server, the phones and the extensions expect. <see cref="Encode"/> is Dart's
/// <c>jsonEncode</c>: no whitespace, only <c>"</c>, <c>\</c>, control characters and lone
/// surrogates escaped (lower-case hex), every other character as is; doubles as Dart prints
/// them (<c>1.0</c>, <c>1e+21</c>). Maps keep their insertion order (as Dart's do).
/// The accessors answer Dart's type tests on a decoded value: <see cref="AsInt"/> is
/// <c>v is int</c> (so <c>1.0</c> is not an int), <see cref="AsNum"/> is <c>v is num</c>.
/// </summary>
public static class DartJson
{
    private static readonly JsonNodeOptions NodeOptions = new() { PropertyNameCaseInsensitive = false };
    private static readonly JsonDocumentOptions DocumentOptions = new() { MaxDepth = 1024 };

    /// <summary>Dart's <c>jsonEncode(node)</c>.</summary>
    public static string Encode(JsonNode? node)
    {
        var sb = new StringBuilder();
        Write(sb, node);
        return sb.ToString();
    }

    /// <summary>The UTF-8 of <see cref="Encode"/>.</summary>
    public static byte[] EncodeUtf8(JsonNode? node) => Encoding.UTF8.GetBytes(Encode(node));

    /// <summary>Dart's <c>jsonDecode(text)</c>; throws <see cref="JsonException"/> on bad JSON.</summary>
    public static JsonNode? Decode(string text) => JsonNode.Parse(text, NodeOptions, DocumentOptions);

    /// <summary><see cref="Decode(string)"/> of UTF-8 bytes.</summary>
    public static JsonNode? Decode(ReadOnlySpan<byte> utf8) => JsonNode.Parse(utf8, NodeOptions, DocumentOptions);

    /// <summary>The decoded value, or null when <paramref name="text"/> isn't JSON.</summary>
    public static JsonNode? TryDecode(string text)
    {
        try
        {
            return Decode(text);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>The JSON object in <paramref name="text"/>, or null (not JSON, or not an object).</summary>
    public static JsonObject? TryDecodeObject(string text) => TryDecode(text) as JsonObject;

    /// <summary>The JSON object in UTF-8 <paramref name="utf8"/>, or null (not UTF-8 JSON, or not an object).</summary>
    public static JsonObject? TryDecodeObject(ReadOnlySpan<byte> utf8)
    {
        try
        {
            return Decode(utf8) as JsonObject;
        }
        catch (JsonException)
        {
            return null;
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    // ------------------------------------------------------------ type tests

    /// <summary>Dart's <c>v is int ? v : null</c>.</summary>
    public static long? AsInt(JsonNode? node)
    {
        if (node is not JsonValue v) return null;
        if (v.TryGetValue(out JsonElement e))
        {
            if (e.ValueKind != JsonValueKind.Number) return null;
            var raw = e.GetRawText();
            if (raw.IndexOfAny(['.', 'e', 'E']) >= 0) return null;
            return e.TryGetInt64(out var l) ? l : null;
        }
        if (v.TryGetValue(out long l64)) return l64;
        if (v.TryGetValue(out int i32)) return i32;
        if (v.TryGetValue(out short i16)) return i16;
        if (v.TryGetValue(out byte u8)) return u8;
        if (v.TryGetValue(out sbyte i8)) return i8;
        if (v.TryGetValue(out ushort u16)) return u16;
        if (v.TryGetValue(out uint u32)) return u32;
        if (v.TryGetValue(out ulong u64)) return u64 <= long.MaxValue ? (long)u64 : null;
        return null;
    }

    /// <summary>Dart's <c>v is num ? v.toDouble() : null</c>.</summary>
    public static double? AsNum(JsonNode? node)
    {
        if (node is not JsonValue v) return null;
        if (v.TryGetValue(out JsonElement e)) return e.ValueKind == JsonValueKind.Number ? e.GetDouble() : null;
        if (AsInt(node) is { } i) return i;
        if (v.TryGetValue(out double d)) return d;
        if (v.TryGetValue(out float f)) return f;
        if (v.TryGetValue(out decimal m)) return (double)m;
        return null;
    }

    /// <summary>Whether the value is a number that Dart would decode as a double (<c>v is double</c>).</summary>
    public static bool IsDouble(JsonNode? node) => AsNum(node) is not null && AsInt(node) is null;

    /// <summary>Dart's <c>v is String ? v : null</c>.</summary>
    public static string? AsString(JsonNode? node)
    {
        if (node is not JsonValue v) return null;
        if (v.TryGetValue(out JsonElement e)) return e.ValueKind == JsonValueKind.String ? e.GetString() : null;
        if (v.TryGetValue(out string? s)) return s;
        if (v.TryGetValue(out char c)) return c.ToString();
        return null;
    }

    /// <summary>Dart's <c>v is bool ? v : null</c>.</summary>
    public static bool? AsBool(JsonNode? node)
    {
        if (node is not JsonValue v) return null;
        if (v.TryGetValue(out JsonElement e))
        {
            return e.ValueKind switch
            {
                JsonValueKind.True => true,
                JsonValueKind.False => false,
                _ => null,
            };
        }
        return v.TryGetValue(out bool b) ? b : null;
    }

    /// <summary>Dart's <c>v is Map ? v : null</c>.</summary>
    public static JsonObject? AsObject(JsonNode? node) => node as JsonObject;

    /// <summary>Dart's <c>v is List ? v : null</c>.</summary>
    public static JsonArray? AsArray(JsonNode? node) => node as JsonArray;

    /// <summary>The value's copy, free to be put into another object or array.</summary>
    public static JsonNode? Clone(JsonNode? node) => node?.DeepClone();

    // ------------------------------------------------------------ writing

    private static void Write(StringBuilder sb, JsonNode? node)
    {
        switch (node)
        {
            case null:
                sb.Append("null");
                break;
            case JsonObject o:
                sb.Append('{');
                var first = true;
                foreach (var (k, v) in o)
                {
                    if (!first) sb.Append(',');
                    first = false;
                    WriteString(sb, k);
                    sb.Append(':');
                    Write(sb, v);
                }
                sb.Append('}');
                break;
            case JsonArray a:
                sb.Append('[');
                for (var i = 0; i < a.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    Write(sb, a[i]);
                }
                sb.Append(']');
                break;
            case JsonValue v:
                WriteValue(sb, v);
                break;
            default:
                throw new JsonException($"Not JSON: {node.GetType()}");
        }
    }

    private static void WriteValue(StringBuilder sb, JsonValue v)
    {
        if (v.TryGetValue(out JsonElement e))
        {
            switch (e.ValueKind)
            {
                case JsonValueKind.String:
                    WriteString(sb, e.GetString()!);
                    return;
                case JsonValueKind.True:
                    sb.Append("true");
                    return;
                case JsonValueKind.False:
                    sb.Append("false");
                    return;
                case JsonValueKind.Null:
                    sb.Append("null");
                    return;
                case JsonValueKind.Number:
                    if (AsInt(v) is { } i) sb.Append(i.ToString(CultureInfo.InvariantCulture));
                    else sb.Append(FormatDouble(e.GetDouble()));
                    return;
                default:
                    Write(sb, JsonNode.Parse(e.GetRawText()));
                    return;
            }
        }
        if (AsString(v) is { } s)
        {
            WriteString(sb, s);
            return;
        }
        if (v.TryGetValue(out bool b))
        {
            sb.Append(b ? "true" : "false");
            return;
        }
        if (AsInt(v) is { } n)
        {
            sb.Append(n.ToString(CultureInfo.InvariantCulture));
            return;
        }
        if (AsNum(v) is { } d)
        {
            sb.Append(FormatDouble(d));
            return;
        }
        throw new JsonException($"Not JSON: {v}");
    }

    /// <summary>A string as Dart's <c>jsonEncode</c> writes it, quotes included.</summary>
    public static void WriteString(StringBuilder sb, string s)
    {
        sb.Append('"');
        for (var i = 0; i < s.Length; i++)
        {
            var c = s[i];
            if (c > '\\')
            {
                if (char.IsSurrogate(c))
                {
                    var paired = char.IsHighSurrogate(c)
                        ? i + 1 < s.Length && char.IsLowSurrogate(s[i + 1])
                        : i > 0 && char.IsHighSurrogate(s[i - 1]);
                    if (!paired)
                    {
                        sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        continue;
                    }
                }
                sb.Append(c);
            }
            else if (c < ' ')
            {
                switch (c)
                {
                    case '\b': sb.Append("\\b"); break;
                    case '\t': sb.Append("\\t"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\f': sb.Append("\\f"); break;
                    case '\r': sb.Append("\\r"); break;
                    default: sb.Append("\\u00").Append(((int)c).ToString("x2", CultureInfo.InvariantCulture)); break;
                }
            }
            else if (c is '"' or '\\')
            {
                sb.Append('\\').Append(c);
            }
            else
            {
                sb.Append(c);
            }
        }
        sb.Append('"');
    }

    /// <summary>A double as Dart's <c>double.toString()</c> prints it (JavaScript's rules, integral values with <c>.0</c>).</summary>
    public static string FormatDouble(double d)
    {
        if (double.IsNaN(d) || double.IsInfinity(d)) throw new JsonException($"Not JSON: {d}");
        if (d == 0) return double.IsNegative(d) ? "-0.0" : "0.0";
        var sign = d < 0 ? "-" : "";
        var r = Math.Abs(d).ToString("R", CultureInfo.InvariantCulture);
        // r is "123.45", "0.001" or "1.2345E+20": digits and n, value = 0.digits × 10^n.
        var exp = 0;
        var ePos = r.IndexOf('E');
        if (ePos >= 0)
        {
            exp = int.Parse(r[(ePos + 1)..], CultureInfo.InvariantCulture);
            r = r[..ePos];
        }
        var dot = r.IndexOf('.');
        var intPart = dot < 0 ? r : r[..dot];
        var frac = dot < 0 ? "" : r[(dot + 1)..];
        var all = intPart + frac;
        var n = intPart.Length + exp;
        var lead = 0;
        while (lead < all.Length - 1 && all[lead] == '0') lead++;
        n -= lead;
        var digits = all[lead..].TrimEnd('0');
        if (digits.Length == 0) digits = "0";
        var k = digits.Length;
        string s;
        if (k <= n && n <= 21) s = digits + new string('0', n - k) + ".0";
        else if (0 < n && n <= 21) s = digits[..n] + "." + digits[n..];
        else if (-6 < n && n <= 0) s = "0." + new string('0', -n) + digits;
        else
        {
            var e = n - 1;
            s = digits[..1] + (k > 1 ? "." + digits[1..] : "") + "e" + (e < 0 ? "-" : "+") + Math.Abs(e).ToString(CultureInfo.InvariantCulture);
        }
        return sign + s;
    }
}

/// <summary>Dart-like typed reads of a JSON object's fields (<c>m['k'] is String ? … : null</c>).</summary>
public static class JsonObjectExtensions
{
    public static string? Str(this JsonObject o, string key) => DartJson.AsString(o[key]);

    public static long? Int(this JsonObject o, string key) => DartJson.AsInt(o[key]);

    public static double? Num(this JsonObject o, string key) => DartJson.AsNum(o[key]);

    public static bool? Bool(this JsonObject o, string key) => DartJson.AsBool(o[key]);

    public static JsonObject? Obj(this JsonObject o, string key) => o[key] as JsonObject;

    public static JsonArray? Arr(this JsonObject o, string key) => o[key] as JsonArray;

    /// <summary>Sets <paramref name="key"/> only when <paramref name="value"/> isn't null (Dart's <c>'k': ?v</c>).</summary>
    public static JsonObject PutIfNotNull(this JsonObject o, string key, JsonNode? value)
    {
        if (value is not null) o[key] = value;
        return o;
    }
}

/// <summary>
/// Base64 as Dart's <c>dart:convert</c> does it: <see cref="Decode"/> is <c>base64Decode</c>, which takes
/// both alphabets (standard and URL-safe) with or without padding; the encoders are <c>base64Encode</c>
/// (standard, padded) and <c>base64UrlEncode</c> with the padding stripped.
/// </summary>
public static class DartBase64
{
    /// <summary>Dart's <c>base64Encode</c>: standard alphabet, padded.</summary>
    public static string Encode(ReadOnlySpan<byte> bytes) => Convert.ToBase64String(bytes);

    /// <summary>Dart's <c>base64UrlEncode(bytes).replaceAll('=', '')</c>.</summary>
    public static string EncodeUrlNoPadding(ReadOnlySpan<byte> bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    /// <summary>Dart's <c>base64Decode</c>; throws <see cref="FormatException"/> as Dart does.</summary>
    public static byte[] Decode(string s) => TryDecode(s) ?? throw new FormatException("Invalid base64");

    /// <summary><see cref="Decode"/>, or null where Dart throws.</summary>
    public static byte[]? TryDecode(string s)
    {
        var sb = new StringBuilder(s.Length + 3);
        var pad = -1;
        for (var i = 0; i < s.Length; i++)
        {
            var c = s[i];
            if (c == '=')
            {
                pad = i;
                break;
            }
            if (c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '+' or '/') sb.Append(c);
            else if (c == '-') sb.Append('+');
            else if (c == '_') sb.Append('/');
            else return null;
        }
        if (pad >= 0)
        {
            // Padding must complete the last quantum, and nothing follows it.
            var tail = s[pad..];
            if (tail.Any(ch => ch != '=')) return null;
            if ((sb.Length + tail.Length) % 4 != 0) return null;
            var need = (4 - sb.Length % 4) % 4;
            if (need == 0 || tail.Length != need) return null;
        }
        if (sb.Length % 4 == 1) return null;
        while (sb.Length % 4 != 0) sb.Append('=');
        try
        {
            return Convert.FromBase64String(sb.ToString());
        }
        catch (FormatException)
        {
            return null;
        }
    }
}
