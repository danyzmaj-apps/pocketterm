using System.Collections.Concurrent;

namespace PocketTerm.Core;

/// <summary>
/// The app's plain preferences (what <c>shared_preferences</c> was): small values by key, kept
/// across launches. The app provides it (Windows: a JSON file under %APPDATA%; the Flutter
/// keys, stored as <c>flutter.&lt;key&gt;</c>, are migrated by the app once). Writes are
/// synchronous from the caller's view; an implementation may persist in the background.
/// </summary>
public interface IPreferenceStore
{
    string? GetString(string key);

    bool? GetBool(string key);

    long? GetInt(string key);

    IReadOnlyList<string>? GetStringList(string key);

    void SetString(string key, string value);

    void SetBool(string key, bool value);

    void SetInt(string key, long value);

    void SetStringList(string key, IReadOnlyList<string> value);

    void Remove(string key);
}

/// <summary>
/// Secrets (what <c>flutter_secure_storage</c> was): the sign-in token, channel keys. The app
/// provides it (Windows: DPAPI-protected file).
/// </summary>
public interface ISecureStore
{
    Task<string?> ReadAsync(string key);

    Task WriteAsync(string key, string value);

    Task DeleteAsync(string key);
}

/// <summary>An <see cref="IPreferenceStore"/> in memory: tests, and runs that keep nothing (end-to-end).</summary>
public sealed class MemoryPreferenceStore : IPreferenceStore
{
    private readonly ConcurrentDictionary<string, object> _values = new();

    public string? GetString(string key) => _values.TryGetValue(key, out var v) ? v as string : null;

    public bool? GetBool(string key) => _values.TryGetValue(key, out var v) && v is bool b ? b : null;

    public long? GetInt(string key) => _values.TryGetValue(key, out var v) && v is long l ? l : null;

    public IReadOnlyList<string>? GetStringList(string key) =>
        _values.TryGetValue(key, out var v) ? v as IReadOnlyList<string> : null;

    public void SetString(string key, string value) => _values[key] = value;

    public void SetBool(string key, bool value) => _values[key] = value;

    public void SetInt(string key, long value) => _values[key] = value;

    public void SetStringList(string key, IReadOnlyList<string> value) => _values[key] = value.ToArray();

    public void Remove(string key) => _values.TryRemove(key, out _);
}

/// <summary>An <see cref="ISecureStore"/> in memory: tests, and runs that keep nothing (end-to-end).</summary>
public sealed class MemorySecureStore : ISecureStore
{
    private readonly ConcurrentDictionary<string, string> _values = new();

    public Task<string?> ReadAsync(string key) => Task.FromResult(_values.TryGetValue(key, out var v) ? v : null);

    public Task WriteAsync(string key, string value)
    {
        _values[key] = value;
        return Task.CompletedTask;
    }

    public Task DeleteAsync(string key)
    {
        _values.TryRemove(key, out _);
        return Task.CompletedTask;
    }
}
