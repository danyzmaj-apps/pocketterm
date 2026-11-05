using System.Security.Cryptography;
using System.Text;
using PocketTerm.Core;
using PocketTerm.Desktop.Tests.Store;

namespace PocketTerm.Desktop.Tests;

/// <summary>The Flutter app's files, byte for byte as its plugins wrote them, brought over once.</summary>
public sealed class FlutterMigrationTests : IDisposable
{
    /// <summary>shared_preferences_windows' shared_preferences.json as Flutter 0.1.7 left it (Dart's jsonEncode,
    /// one line), with a key of another plugin's that isn't PocketTerm's.</summary>
    private const string FlutterPreferences =
        """{"flutter.theme":"tokyoNight","flutter.terminal_bridge":true,"flutter.hosting":false""" +
        ""","flutter.hosting_port":47900,"flutter.ratio":1.0,"flutter.project_roots":["C:\\Users\\me\\Dev","D:\\wörk"]""" +
        ""","flutter.backend_url":"https://pocketterm.example.com","flutter.empty_roots":[],"other.key":"not ours"}""";

    /// <summary>flutter_secure_storage_windows' JSON before CryptProtectData: key to string, unprefixed.</summary>
    private const string FlutterSecrets =
        """{"device_token":"{\"url\":\"https://pocketterm.example.com\",\"token\":\"t0k\"}","channel_key_7f3a":"q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA="}""";

    private readonly TempDir _dir = new();

    public void Dispose() => _dir.Dispose();

    [Fact]
    public void ThePreferencesComeOverWithoutTheirPrefixAndEachKind()
    {
        File.WriteAllText(_dir[FlutterMigration.PreferencesFile], FlutterPreferences);
        var store = new JsonPreferenceStore(_dir["preferences.json"]);

        Assert.Equal(8, FlutterMigration.MigratePreferences(_dir.Path, store));

        Assert.Equal("tokyoNight", store.GetString("theme"));
        Assert.True(store.GetBool("terminal_bridge"));
        Assert.False(store.GetBool("hosting"));
        Assert.Equal(47900, store.GetInt("hosting_port"));
        Assert.Equal(1.0, store.GetDouble("ratio"));
        Assert.Equal([@"C:\Users\me\Dev", @"D:\wörk"], store.GetStringList("project_roots"));
        Assert.Equal([], store.GetStringList("empty_roots"));
        Assert.Equal("https://pocketterm.example.com", store.GetString("backend_url"));
        Assert.False(store.ContainsKey("other.key"));
        Assert.False(store.ContainsKey("key"));
        Assert.True(store.GetBool(FlutterMigration.PreferencesDone));
        // Left as it was, for an older PocketTerm installed again.
        Assert.Equal(FlutterPreferences, File.ReadAllText(_dir[FlutterMigration.PreferencesFile]));
    }

    [Fact]
    public void PreferencesComeOverOnceAndNeverOverAValueTheNativeAppHas()
    {
        File.WriteAllText(_dir[FlutterMigration.PreferencesFile], FlutterPreferences);
        var store = new MemoryPreferenceStore();
        store.SetString("theme", "dawn");

        // Into a store without doubles: the one double stays behind.
        Assert.Equal(6, FlutterMigration.MigratePreferences(_dir.Path, store));
        Assert.Equal("dawn", store.GetString("theme"));
        Assert.Equal(47900, store.GetInt("hosting_port"));

        store.SetInt("hosting_port", 1);
        Assert.Equal(0, FlutterMigration.MigratePreferences(_dir.Path, store));
        Assert.Equal(1, store.GetInt("hosting_port"));
    }

    [Fact]
    public void NoFlutterPreferencesIsDoneToo()
    {
        var store = new MemoryPreferenceStore();
        Assert.Equal(0, FlutterMigration.MigratePreferences(_dir.Path, store));
        Assert.True(store.GetBool(FlutterMigration.PreferencesDone));

        // One that turns up later (an older PocketTerm run in between) isn't read.
        File.WriteAllText(_dir[FlutterMigration.PreferencesFile], FlutterPreferences);
        Assert.Equal(0, FlutterMigration.MigratePreferences(_dir.Path, store));
        Assert.Null(store.GetString("theme"));
    }

    [Fact]
    public async Task TheSecretsComeOverOnceFromTheSealedFile()
    {
        var protector = new FakeProtector();
        var old = _dir[FlutterMigration.SecretsFile];
        // flutter_secure_storage_windows keeps only strings; another value is left out.
        var sealedBytes = protector.Protect(Encoding.UTF8.GetBytes(FlutterSecrets[..^1] + ",\"n\":1}"));
        File.WriteAllBytes(old, sealedBytes);
        var store = new DpapiSecureStore(_dir[DpapiSecureStore.FileName], protector);
        await store.WriteAsync("channel_key_kept", "native");

        Assert.Equal(2, await FlutterMigration.MigrateSecretsAsync(_dir.Path, store, protector));

        Assert.Equal("{\"url\":\"https://pocketterm.example.com\",\"token\":\"t0k\"}", await store.ReadAsync("device_token"));
        Assert.Equal("q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA=", await store.ReadAsync("channel_key_7f3a"));
        Assert.NotNull(ChannelKey.TryParse(await store.ReadAsync("channel_key_7f3a")));
        Assert.Null(await store.ReadAsync("n"));
        Assert.Equal("native", await store.ReadAsync("channel_key_kept"));
        Assert.Equal(sealedBytes, File.ReadAllBytes(old));

        await store.DeleteAsync("device_token");
        Assert.Equal(0, await FlutterMigration.MigrateSecretsAsync(_dir.Path, store, protector));
        Assert.Null(await store.ReadAsync("device_token"));
    }

    [Fact]
    public async Task SecretsThatCantBeOpenedAreTriedAgainNextStartAndLeftAlone()
    {
        var old = _dir[FlutterMigration.SecretsFile];
        File.WriteAllText(old, "another user's");
        var store = new MemorySecureStore();
        await Assert.ThrowsAsync<CryptographicException>(() => FlutterMigration.MigrateSecretsAsync(_dir.Path, store, new FakeProtector()));
        Assert.Null(await store.ReadAsync(FlutterMigration.SecretsDone));
        Assert.Equal("another user's", File.ReadAllText(old));

        // RunAsync logs it instead and still brings the preferences over.
        var prefs = new MemoryPreferenceStore();
        File.WriteAllText(_dir[FlutterMigration.PreferencesFile], FlutterPreferences);
        await FlutterMigration.RunAsync(_dir.Path, prefs, store, new FakeProtector());
        Assert.Equal("tokyoNight", prefs.GetString("theme"));
        Assert.Null(await store.ReadAsync(FlutterMigration.SecretsDone));

        File.WriteAllBytes(old, new FakeProtector().Protect(Encoding.UTF8.GetBytes(FlutterSecrets)));
        await FlutterMigration.RunAsync(_dir.Path, prefs, store, new FakeProtector());
        Assert.Equal("1", await store.ReadAsync(FlutterMigration.SecretsDone));
        Assert.NotNull(await store.ReadAsync("device_token"));
    }

    [StoreWindowsFact]
    public async Task OnWindowsTheFlutterFileIsOpenedWithDpapi()
    {
        if (!OperatingSystem.IsWindows()) return;
        // What flutter_secure_storage_windows wrote: CryptProtectData of the UTF-8 JSON, no entropy.
        File.WriteAllBytes(_dir[FlutterMigration.SecretsFile],
            ProtectedData.Protect(Encoding.UTF8.GetBytes(FlutterSecrets), null, DataProtectionScope.CurrentUser));
        var store = new DpapiSecureStore(_dir[DpapiSecureStore.FileName], new DpapiProtector());
        Assert.Equal(2, await FlutterMigration.MigrateSecretsAsync(_dir.Path, store, new DpapiProtector()));
        Assert.Equal("q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA=", await store.ReadAsync("channel_key_7f3a"));
    }
}
