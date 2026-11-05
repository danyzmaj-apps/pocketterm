using System.Text;
using System.Text.Json.Nodes;
using PocketTerm.Core;

namespace PocketTerm.Core.Tests;

/// <summary>
/// tool/vectors/vectors.json, the frozen cross-language contract (see its README.md),
/// read from the repo this test runs in.
/// </summary>
internal static class Vectors
{
    private static readonly Lazy<JsonObject> _root = new(Load);

    public static JsonObject Root => _root.Value;

    /// <summary>A top-level section (<c>crypto</c>, <c>live</c>, …).</summary>
    public static JsonObject Section(string name) => (JsonObject)Root[name]!;

    /// <summary>The repository's root (where tool/vectors lives).</summary>
    public static string RepoRoot { get; } = FindRepoRoot();

    private static string FindRepoRoot()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir != null; dir = dir.Parent)
        {
            if (File.Exists(Path.Combine(dir.FullName, "tool", "vectors", "vectors.json"))) return dir.FullName;
        }
        throw new FileNotFoundException("tool/vectors/vectors.json not found above " + AppContext.BaseDirectory);
    }

    private static JsonObject Load() =>
        (JsonObject)DartJson.Decode(File.ReadAllText(Path.Combine(RepoRoot, "tool", "vectors", "vectors.json")))!;

    /// <summary>A string input: as is, or <c>{"repeat": u, "times": n, "then"?: s, "prefix"?: p}</c> expanded.</summary>
    public static string Text(JsonNode? node)
    {
        if (DartJson.AsString(node) is { } s) return s;
        var o = (JsonObject)node!;
        var sb = new StringBuilder();
        sb.Append(o.Str("prefix") ?? "");
        var unit = o.Str("repeat")!;
        for (var i = 0; i < o.Int("times"); i++) sb.Append(unit);
        sb.Append(o.Str("then") ?? "");
        return sb.ToString();
    }

    /// <summary>Standard base64 bytes.</summary>
    public static byte[] Bytes(JsonNode? node) => Convert.FromBase64String(DartJson.AsString(node)!);

    /// <summary>Hex bytes.</summary>
    public static byte[] Hex(JsonNode? node) => Convert.FromHexString(DartJson.AsString(node)!);

    /// <summary>Deep JSON equality, with a readable failure.</summary>
    public static void AssertJson(JsonNode? expected, JsonNode? actual, string? because = null)
    {
        if (JsonNode.DeepEquals(expected, actual)) return;
        Assert.Fail($"{because}\nexpected: {DartJson.Encode(expected)}\nactual:   {DartJson.Encode(actual)}");
    }
}
