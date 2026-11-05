using System.Text;
using System.Text.Json.Nodes;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>
/// The app's preferences in one JSON file (<c>&lt;SupportDir&gt;\preferences.json</c>): an object of key
/// to string, bool, integer, double or list of strings, as shared_preferences_windows kept its own
/// (<see cref="FlutterMigration"/> brings those over once). Read whole when made; every change is
/// written at once, through a temporary file and a rename so a crash never leaves half a file. One lock
/// guards the values and the write, so any thread may use it.
/// </summary>
public sealed class JsonPreferenceStore : IPreferenceStore
{
    /// <summary>The file's name in <see cref="AppPaths.SupportDir"/>.</summary>
    public const string FileName = "preferences.json";

    private readonly object _gate = new();
    private readonly JsonObject _values;

    /// <summary><paramref name="path"/>: the file; <see cref="FileName"/> in <see cref="AppPaths.SupportDir"/> if null.</summary>
    public JsonPreferenceStore(string? path = null)
    {
        Path = path ?? System.IO.Path.Combine(AppPaths.SupportDir, FileName);
        _values = Load(Path);
    }

    /// <summary>Where the preferences are kept.</summary>
    public string Path { get; }

    public string? GetString(string key)
    {
        lock (_gate) return DartJson.AsString(_values[key]);
    }

    public bool? GetBool(string key)
    {
        lock (_gate) return DartJson.AsBool(_values[key]);
    }

    public long? GetInt(string key)
    {
        lock (_gate) return DartJson.AsInt(_values[key]);
    }

    /// <summary>A double kept with <see cref="SetDouble"/> (shared_preferences' <c>getDouble</c>); null for an integer.</summary>
    public double? GetDouble(string key)
    {
        lock (_gate) return DartJson.IsDouble(_values[key]) ? DartJson.AsNum(_values[key]) : null;
    }

    public IReadOnlyList<string>? GetStringList(string key)
    {
        lock (_gate) return StringList(_values[key]);
    }

    /// <summary>Whether <paramref name="key"/> has a value of any kind.</summary>
    public bool ContainsKey(string key)
    {
        lock (_gate) return _values.ContainsKey(key);
    }

    public void SetString(string key, string value) => Set(key, JsonValue.Create(value));

    public void SetBool(string key, bool value) => Set(key, JsonValue.Create(value));

    public void SetInt(string key, long value) => Set(key, JsonValue.Create(value));

    /// <summary>Keeps a double (shared_preferences' <c>setDouble</c>); written as Dart writes one, <c>1.0</c> for a whole number.</summary>
    public void SetDouble(string key, double value)
    {
        if (!double.IsFinite(value)) throw new ArgumentOutOfRangeException(nameof(value), value, "Not a JSON number");
        Set(key, JsonValue.Create(value));
    }

    public void SetStringList(string key, IReadOnlyList<string> value) =>
        Set(key, new JsonArray(value.Select(v => (JsonNode?)JsonValue.Create(v)).ToArray()));

    public void Remove(string key)
    {
        lock (_gate)
        {
            if (_values.Remove(key)) Save();
        }
    }

    /// <summary>The strings of a JSON array of strings; null for anything else.</summary>
    internal static IReadOnlyList<string>? StringList(JsonNode? node)
    {
        if (node is not JsonArray a) return null;
        var list = new List<string>(a.Count);
        foreach (var item in a)
        {
            if (DartJson.AsString(item) is not { } s) return null;
            list.Add(s);
        }
        return list;
    }

    private void Set(string key, JsonNode value)
    {
        lock (_gate)
        {
            _values[key] = value;
            Save();
        }
    }

    /// <summary>Under <see cref="_gate"/>. A write that fails is logged and the value kept for this run, as
    /// shared_preferences did.</summary>
    private void Save()
    {
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
            var tmp = Path + ".tmp";
            File.WriteAllText(tmp, DartJson.Encode(_values), new UTF8Encoding(false));
            File.Move(tmp, Path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Print($"PocketTerm: preferences not saved: {e.Message}");
        }
    }

    /// <summary>The file's object; empty when there is none yet, or it isn't one (logged; the next change
    /// replaces it).</summary>
    private static JsonObject Load(string path)
    {
        try
        {
            if (!File.Exists(path)) return new JsonObject();
            var text = File.ReadAllText(path, Encoding.UTF8);
            if (text.Length == 0) return new JsonObject();
            if (DartJson.TryDecodeObject(text) is { } o) return o;
            Log.Print($"PocketTerm: preferences unreadable, starting over: {path}");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Print($"PocketTerm: preferences unreadable: {e.Message}");
        }
        return new JsonObject();
    }
}
