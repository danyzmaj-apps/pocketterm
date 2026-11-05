using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace PocketTerm.Core;

/// <summary>
/// URIs as Dart's <c>Uri</c> reads and writes the ones PocketTerm uses (server URLs, setup links):
/// <see cref="TryParse"/> splits per RFC 3986 with Dart's normalisation (scheme and host in lower case,
/// IPv6 host without brackets), <see cref="QueryParameters"/> decodes <c>+</c> as a space and keeps the
/// last of a repeated name, and <see cref="Build"/> encodes query values as Dart's
/// <c>Uri(queryParameters: …)</c> does (only <c>A–Z a–z 0–9 - . _ ~</c> kept, space as <c>+</c>, upper-case hex).
/// </summary>
public sealed partial class DartUri
{
    private DartUri(string scheme, string? userInfo, string? host, int? port, string path, string? query, string? fragment)
    {
        Scheme = scheme;
        UserInfo = userInfo;
        HostOrNull = host;
        Port = port;
        Path = path;
        Query = query;
        Fragment = fragment;
    }

    /// <summary>Lower case; empty when none (Dart's <c>scheme</c>).</summary>
    public string Scheme { get; }

    public bool HasScheme => Scheme.Length > 0;

    public string? UserInfo { get; }

    private string? HostOrNull { get; }

    /// <summary>Dart's <c>host</c>: lower case, an IPv6 address without its brackets; empty when none.</summary>
    public string Host => HostOrNull ?? "";

    public bool HasAuthority => HostOrNull is not null;

    /// <summary>The port as written, or null.</summary>
    public int? Port { get; }

    public string Path { get; }

    /// <summary>The raw query (after <c>?</c>), or null when there's no <c>?</c>.</summary>
    public string? Query { get; }

    public bool HasQuery => Query is not null;

    public string? Fragment { get; }

    public bool HasFragment => Fragment is not null;

    /// <summary>Dart's <c>Uri.tryParse</c>, for the forms PocketTerm reads; null when it isn't one.</summary>
    public static DartUri? TryParse(string text)
    {
        var m = Rfc3986().Match(text);
        if (!m.Success) return null;
        var scheme = m.Groups[2].Success ? m.Groups[2].Value : "";
        if (m.Groups[1].Success && !SchemeChars().IsMatch(scheme)) return null;
        string? userInfo = null;
        string? host = null;
        int? port = null;
        if (m.Groups[3].Success)
        {
            var authority = m.Groups[4].Value;
            var at = authority.LastIndexOf('@');
            if (at >= 0)
            {
                userInfo = authority[..at];
                authority = authority[(at + 1)..];
            }
            string portText;
            if (authority.StartsWith('['))
            {
                var close = authority.IndexOf(']');
                if (close < 0) return null;
                host = authority[1..close].ToLowerInvariant();
                var rest = authority[(close + 1)..];
                if (rest.Length > 0 && rest[0] != ':') return null;
                portText = rest.Length > 0 ? rest[1..] : "";
            }
            else
            {
                var colon = authority.LastIndexOf(':');
                host = (colon >= 0 ? authority[..colon] : authority).ToLowerInvariant();
                portText = colon >= 0 ? authority[(colon + 1)..] : "";
                if (host.IndexOfAny([' ', '<', '>', '"', '{', '}', '|', '\\', '^', '`']) >= 0) return null;
            }
            if (portText.Length > 0)
            {
                if (!portText.All(c => c is >= '0' and <= '9')) return null;
                if (!int.TryParse(portText, NumberStyles.None, CultureInfo.InvariantCulture, out var p)) return null;
                port = p;
            }
        }
        var query = m.Groups[6].Success ? m.Groups[7].Value : null;
        var fragment = m.Groups[8].Success ? m.Groups[9].Value : null;
        return new DartUri(scheme.ToLowerInvariant(), userInfo, host, port, m.Groups[5].Value, query, fragment);
    }

    /// <summary>Dart's <c>Uri.parse</c>: throws <see cref="FormatException"/> where Dart does.</summary>
    public static DartUri Parse(string text) => TryParse(text) ?? throw new FormatException($"Not a URI: {text}");

    /// <summary>Dart's <c>queryParameters</c>: names and values decoded (<c>+</c> is a space), the last of a
    /// repeated name kept, <c>=v</c> (no name) skipped. A bad percent escape throws <see cref="FormatException"/>.</summary>
    public IReadOnlyDictionary<string, string> QueryParameters
    {
        get
        {
            var map = new Dictionary<string, string>();
            if (string.IsNullOrEmpty(Query)) return map;
            foreach (var element in Query.Split('&'))
            {
                var index = element.IndexOf('=');
                if (index == -1)
                {
                    if (element.Length > 0) map[DecodeQueryComponent(element)] = "";
                }
                else if (index != 0)
                {
                    map[DecodeQueryComponent(element[..index])] = DecodeQueryComponent(element[(index + 1)..]);
                }
            }
            return map;
        }
    }

    /// <summary>A query parameter, or null (also when the query can't be decoded).</summary>
    public string? Param(string name)
    {
        try
        {
            return QueryParameters.TryGetValue(name, out var v) ? v : null;
        }
        catch (FormatException)
        {
            return null;
        }
    }

    /// <summary>Dart's <c>Uri.decodeQueryComponent</c>: <c>+</c> is a space, <c>%XX</c> UTF-8 bytes.</summary>
    public static string DecodeQueryComponent(string s)
    {
        if (s.IndexOfAny(['%', '+']) < 0) return s;
        var bytes = new List<byte>(s.Length);
        for (var i = 0; i < s.Length; i++)
        {
            var c = s[i];
            if (c == '+')
            {
                bytes.Add((byte)' ');
            }
            else if (c == '%')
            {
                if (i + 2 >= s.Length || !IsHex(s[i + 1]) || !IsHex(s[i + 2])) throw new FormatException("Invalid URL encoding");
                bytes.Add((byte)Convert.ToInt32(s.Substring(i + 1, 2), 16));
                i += 2;
            }
            else if (c > 0x7f)
            {
                bytes.AddRange(Encoding.UTF8.GetBytes(c.ToString()));
            }
            else
            {
                bytes.Add((byte)c);
            }
        }
        // Dart decodes with utf8 allowing malformed input (U+FFFD), as .NET's default does.
        return Encoding.UTF8.GetString(bytes.ToArray());
    }

    private static bool IsHex(char c) => c is >= '0' and <= '9' or >= 'a' and <= 'f' or >= 'A' and <= 'F';

    /// <summary>A query component as Dart's <c>Uri(queryParameters: …)</c> writes it.</summary>
    public static string EncodeQueryComponent(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var b in Encoding.UTF8.GetBytes(s))
        {
            var c = (char)b;
            if (c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '.' or '_' or '~') sb.Append(c);
            else if (c == ' ') sb.Append('+');
            else sb.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }

    /// <summary>A query string from <paramref name="parameters"/> in order, as Dart writes it.</summary>
    public static string EncodeQuery(IEnumerable<KeyValuePair<string, string>> parameters) =>
        string.Join('&', parameters.Select(p => EncodeQueryComponent(p.Key) + "=" + EncodeQueryComponent(p.Value)));

    /// <summary><c>Uri(scheme:, host:, port:, path:, queryParameters:).toString()</c>.</summary>
    public static string Build(string scheme, string host, int? port = null, string path = "", IEnumerable<KeyValuePair<string, string>>? query = null)
    {
        var sb = new StringBuilder();
        sb.Append(scheme).Append("://").Append(host.Contains(':') ? $"[{host}]" : host);
        if (port is { } p) sb.Append(':').Append(p.ToString(CultureInfo.InvariantCulture));
        sb.Append(path);
        if (query != null) sb.Append('?').Append(EncodeQuery(query));
        return sb.ToString();
    }

    /// <summary>This URI with another scheme, path and query (Dart's <c>replace</c>), as text.</summary>
    public string Replace(string scheme, string path, IEnumerable<KeyValuePair<string, string>>? query = null) =>
        Build(scheme, Host, Port, path, query);

    public override string ToString()
    {
        var sb = new StringBuilder();
        if (HasScheme) sb.Append(Scheme).Append(':');
        if (HostOrNull is not null)
        {
            sb.Append("//");
            if (UserInfo is not null) sb.Append(UserInfo).Append('@');
            sb.Append(Host.Contains(':') ? $"[{Host}]" : Host);
            if (Port is { } p) sb.Append(':').Append(p.ToString(CultureInfo.InvariantCulture));
        }
        sb.Append(Path);
        if (Query is not null) sb.Append('?').Append(Query);
        if (Fragment is not null) sb.Append('#').Append(Fragment);
        return sb.ToString();
    }

    // RFC 3986 appendix B.
    [GeneratedRegex(@"^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?\z", RegexOptions.Singleline)]
    private static partial Regex Rfc3986();

    [GeneratedRegex(@"^[A-Za-z][A-Za-z0-9+.\-]*\z")]
    private static partial Regex SchemeChars();
}
