using System.Text;
using System.Text.Json.Nodes;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>
/// Brings the Flutter app's (0.1.x) preferences and secrets into the native stores the first time the
/// native app runs, so an upgrade keeps the sign-in, the channel keys and every setting. Both Flutter
/// files sit in <see cref="AppPaths.SupportDir"/> (path_provider_windows' support folder):
/// <list type="bullet">
/// <item><see cref="PreferencesFile"/> (shared_preferences_windows 2.4.1): one JSON object, each key with
/// shared_preferences' <c>flutter.</c> prefix, values strings, bools, ints (<c>1</c>), doubles (<c>1.0</c>)
/// and lists of strings.</item>
/// <item><see cref="SecretsFile"/> (flutter_secure_storage_windows 4.1.0, its default
/// <c>useBackwardCompatibility: false</c>, so nothing in Credential Manager): CryptProtectData of the UTF-8
/// of one JSON object of key to string value, keys as the app named them (no prefix).</item>
/// </list>
/// Each runs once: done is marked in the new store (<see cref="PreferencesDone"/>,
/// <see cref="SecretsDone"/>), a key the new store already has is left alone, and the Flutter files are
/// never changed or deleted (an older PocketTerm installed again still finds them).
/// </summary>
public static class FlutterMigration
{
    /// <summary>shared_preferences_windows' file in the support folder.</summary>
    public const string PreferencesFile = "shared_preferences.json";

    /// <summary>flutter_secure_storage_windows' file in the support folder.</summary>
    public const string SecretsFile = "flutter_secure_storage.dat";

    /// <summary>What shared_preferences put before every key.</summary>
    public const string Prefix = "flutter.";

    /// <summary>The preference that says the preferences were brought over.</summary>
    public const string PreferencesDone = "migratedFromFlutter";

    /// <summary>The secret that says the secrets were brought over.</summary>
    public const string SecretsDone = "migrated_from_flutter";

    /// <summary>
    /// Copies the Flutter preferences in <paramref name="supportDir"/> into <paramref name="into"/> without
    /// their prefix, unless done before; how many were copied. A double goes only into a
    /// <see cref="JsonPreferenceStore"/> (<see cref="IPreferenceStore"/> has none; PocketTerm kept none).
    /// Throws <see cref="IOException"/> when the file can't be read (not marked done: the next start tries
    /// again); a file that isn't a JSON object counts as no preferences, as shared_preferences took it.
    /// </summary>
    public static int MigratePreferences(string supportDir, IPreferenceStore into)
    {
        if (into.GetBool(PreferencesDone) == true) return 0;
        var path = Path.Combine(supportDir, PreferencesFile);
        var copied = 0;
        if (File.Exists(path))
        {
            var text = File.ReadAllText(path, Encoding.UTF8);
            var o = text.Length == 0 ? null : DartJson.TryDecodeObject(text);
            foreach (var (key, value) in o ?? new JsonObject())
            {
                if (!key.StartsWith(Prefix, StringComparison.Ordinal)) continue;
                var name = key[Prefix.Length..];
                if (Has(into, name)) continue;
                if (Copy(into, name, value)) copied++;
            }
        }
        into.SetBool(PreferencesDone, true);
        return copied;
    }

    /// <summary>
    /// Copies the Flutter secrets in <paramref name="supportDir"/> into <paramref name="into"/>, opened with
    /// <paramref name="protector"/> (<see cref="DpapiProtector"/> on Windows), unless done before; how many were
    /// copied. Throws when the file can't be read or opened (not marked done: the next start tries again).
    /// Not for a throwaway profile (<see cref="SystemSecrets.IsThrowaway"/>): the person's secrets stay theirs.
    /// </summary>
    public static async Task<int> MigrateSecretsAsync(string supportDir, ISecureStore into, ISecretProtector protector)
    {
        if (await into.ReadAsync(SecretsDone).ConfigureAwait(false) != null) return 0;
        var old = DpapiSecureStore.ReadFile(Path.Combine(supportDir, SecretsFile), protector);
        var copied = 0;
        foreach (var (key, value) in old)
        {
            if (await into.ReadAsync(key).ConfigureAwait(false) != null) continue;
            await into.WriteAsync(key, value).ConfigureAwait(false);
            copied++;
        }
        await into.WriteAsync(SecretsDone, "1").ConfigureAwait(false);
        return copied;
    }

    /// <summary>Both, at start: what fails is logged and tried again next start. <paramref name="secrets"/>
    /// null skips the secrets (a throwaway profile).</summary>
    public static async Task RunAsync(string supportDir, IPreferenceStore preferences, ISecureStore? secrets, ISecretProtector protector)
    {
        try
        {
            var n = MigratePreferences(supportDir, preferences);
            if (n > 0) Log.Print($"PocketTerm: {n} preferences brought over from the Flutter app");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Print($"PocketTerm: Flutter preferences not brought over: {e.Message}");
        }
        if (secrets == null) return;
        try
        {
            var n = await MigrateSecretsAsync(supportDir, secrets, protector).ConfigureAwait(false);
            if (n > 0) Log.Print($"PocketTerm: {n} secrets brought over from the Flutter app");
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: Flutter secrets not brought over: {e.Message}");
        }
    }

    /// <summary>Sets <paramref name="name"/> to the Flutter <paramref name="value"/> by its kind; false for one
    /// shared_preferences couldn't have written (or a double <paramref name="into"/> can't keep).</summary>
    private static bool Copy(IPreferenceStore into, string name, JsonNode? value)
    {
        if (DartJson.AsString(value) is { } s) into.SetString(name, s);
        else if (DartJson.AsBool(value) is { } b) into.SetBool(name, b);
        else if (DartJson.AsInt(value) is { } i) into.SetInt(name, i);
        else if (DartJson.IsDouble(value) && into is JsonPreferenceStore json) json.SetDouble(name, DartJson.AsNum(value)!.Value);
        else if (JsonPreferenceStore.StringList(value) is { } list) into.SetStringList(name, list);
        else return false;
        return true;
    }

    private static bool Has(IPreferenceStore store, string name) =>
        store is JsonPreferenceStore json
            ? json.ContainsKey(name)
            : store.GetString(name) != null || store.GetBool(name) != null || store.GetInt(name) != null ||
              store.GetStringList(name) != null;
}
