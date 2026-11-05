using System.Collections.Concurrent;
using System.Text.Json.Nodes;

namespace PocketTerm.Core;

/// <summary>
/// Dart enums travel by their <c>name</c> (lowerCamel: <c>tokyoNight</c>); the C# members are the same
/// words in PascalCase (<c>TokyoNight</c>). <see cref="Name{T}"/> is Dart's <c>value.name</c>,
/// <see cref="Parse{T}(string?)"/> is <c>values.asNameMap()[name]</c>.
/// </summary>
public static class DartEnum
{
    private static readonly ConcurrentDictionary<Type, Dictionary<string, object>> Maps = new();

    /// <summary>Dart's <c>value.name</c>.</summary>
    public static string Name<T>(this T value)
        where T : struct, Enum
    {
        var s = value.ToString();
        return char.ToLowerInvariant(s[0]) + s[1..];
    }

    /// <summary>Dart's <c>values.asNameMap()[name]</c>: the value named so, or null.</summary>
    public static T? Parse<T>(string? name)
        where T : struct, Enum
    {
        if (name is null) return null;
        var map = Maps.GetOrAdd(typeof(T), _ => Enum.GetValues<T>().ToDictionary(v => v.Name(), v => (object)v));
        return map.TryGetValue(name, out var v) ? (T)v : null;
    }

    /// <summary><see cref="Parse{T}(string?)"/> of a JSON value (null unless it's a string).</summary>
    public static T? Parse<T>(JsonNode? name)
        where T : struct, Enum => Parse<T>(DartJson.AsString(name));
}
