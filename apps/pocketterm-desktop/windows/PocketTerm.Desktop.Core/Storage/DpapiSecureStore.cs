using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>Seals the secrets file's bytes for this user and opens them again (DPAPI on Windows; tests
/// pass their own, so the file format is tested anywhere).</summary>
public interface ISecretProtector
{
    byte[] Protect(byte[] plain);

    /// <summary>Throws <see cref="CryptographicException"/> for bytes it didn't seal.</summary>
    byte[] Unprotect(byte[] sealedBytes);
}

/// <summary>DPAPI for the current Windows user, no extra entropy: what flutter_secure_storage_windows 4.1.0's
/// CryptProtectData/CryptUnprotectData calls did, so the same user opens either's files.</summary>
[SupportedOSPlatform("windows")]
public sealed class DpapiProtector : ISecretProtector
{
    public byte[] Protect(byte[] plain) => ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser);

    public byte[] Unprotect(byte[] sealedBytes) => ProtectedData.Unprotect(sealedBytes, null, DataProtectionScope.CurrentUser);
}

/// <summary>
/// The secrets (the sign-in, the channel keys) in one file in the app's %APPDATA% folder
/// (<c>&lt;SupportDir&gt;\secrets.dat</c>), encrypted for this Windows user (DPAPI), so no size limit as in
/// Credential Manager; uninstalling leaves it. The format is flutter_secure_storage_windows' own: the
/// sealed UTF-8 of a JSON object of name to value. Each change reads the whole file, changes it and
/// writes it back (through a rename), so operations run one at a time across every instance in the
/// process (lib/channel_keys.dart's <c>_serial</c>): two writes at once (the device token and a channel
/// key, at sign-in) would otherwise keep only one. A failure throws <see cref="SecureStoreException"/>.
/// </summary>
public sealed class DpapiSecureStore : ISecureStore
{
    /// <summary>The file's name in <see cref="AppPaths.SupportDir"/>.</summary>
    public const string FileName = "secrets.dat";

    /// <summary>One operation at a time, across every store (a failed one doesn't stop the next).</summary>
    private static readonly SemaphoreSlim Serial = new(1, 1);

    private readonly ISecretProtector _protector;

    /// <summary><paramref name="path"/>: the file; <paramref name="protector"/>: how it's sealed.</summary>
    public DpapiSecureStore(string path, ISecretProtector protector)
    {
        Path = path;
        _protector = protector;
    }

    /// <summary>The system's: <see cref="FileName"/> in <see cref="AppPaths.SupportDir"/>, sealed with DPAPI.</summary>
    [SupportedOSPlatform("windows")]
    public DpapiSecureStore() : this(System.IO.Path.Combine(AppPaths.SupportDir, FileName), new DpapiProtector())
    {
    }

    /// <summary>Where the secrets are kept.</summary>
    public string Path { get; }

    public Task<string?> ReadAsync(string key) => Run(map => (map.GetValueOrDefault(key), false));

    public Task WriteAsync(string key, string value) => Run<string?>(map =>
    {
        map[key] = value;
        return (null, true);
    });

    public Task DeleteAsync(string key) => Run<string?>(map => (null, map.Remove(key)));

    /// <summary>
    /// The secrets in a file of this format (<paramref name="path"/>); none when it doesn't exist. Values
    /// that aren't strings are left out, as flutter_secure_storage_windows did. Throws
    /// <see cref="CryptographicException"/> when it can't be opened, <see cref="FormatException"/> when it
    /// isn't a JSON object; never changes the file.
    /// </summary>
    public static Dictionary<string, string> ReadFile(string path, ISecretProtector protector)
    {
        byte[] sealedBytes;
        try
        {
            sealedBytes = File.ReadAllBytes(path);
        }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException)
        {
            return new Dictionary<string, string>(StringComparer.Ordinal);
        }
        var plain = protector.Unprotect(sealedBytes);
        string text;
        try
        {
            text = new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(plain);
        }
        catch (DecoderFallbackException e)
        {
            throw new FormatException($"Not UTF-8: {path}", e);
        }
        if (DartJson.TryDecode(text) is not JsonObject o) throw new FormatException($"Not a JSON object: {path}");
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (k, v) in o)
        {
            if (DartJson.AsString(v) is { } s) map[k] = s;
        }
        return map;
    }

    /// <summary>Writes <paramref name="map"/> to <paramref name="path"/> in this format, through a rename.</summary>
    public static void WriteFile(string path, IReadOnlyDictionary<string, string> map, ISecretProtector protector)
    {
        var o = new JsonObject();
        foreach (var (k, v) in map) o[k] = v;
        var sealedBytes = protector.Protect(DartJson.EncodeUtf8(o));
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path))!);
        var tmp = path + ".tmp";
        using (var f = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.None))
        {
            f.Write(sealedBytes);
            f.Flush(flushToDisk: true);
        }
        File.Move(tmp, path, overwrite: true);
    }

    /// <summary>Loads the file, lets <paramref name="op"/> read or change it, and writes it back when it says
    /// it changed — one at a time.</summary>
    private async Task<T> Run<T>(Func<Dictionary<string, string>, (T Result, bool Changed)> op)
    {
        await Serial.WaitAsync().ConfigureAwait(false);
        try
        {
            var map = Load();
            var (result, changed) = op(map);
            if (changed) WriteFile(Path, map, _protector);
            return result;
        }
        catch (SecureStoreException)
        {
            throw;
        }
        catch (Exception e)
        {
            throw new SecureStoreException($"Couldn't keep secrets in {Path}: {e.Message}", e);
        }
        finally
        {
            Serial.Release();
        }
    }

    /// <summary>
    /// The file's secrets. One that can't be opened or read (another user's, damaged) would fail every
    /// operation from now on: as flutter_secure_storage_windows did, it's dropped and the operation fails
    /// (the next starts afresh) — moved aside to <c>secrets.dat.bad</c> rather than deleted.
    /// </summary>
    private Dictionary<string, string> Load()
    {
        try
        {
            return ReadFile(Path, _protector);
        }
        catch (Exception e) when (e is CryptographicException or FormatException)
        {
            Log.Print($"PocketTerm: secrets unreadable, set aside: {e.Message}");
            try
            {
                File.Move(Path, Path + ".bad", overwrite: true);
            }
            catch (Exception m) when (m is IOException or UnauthorizedAccessException)
            {
                Log.Print($"PocketTerm: secrets not set aside: {m.Message}");
            }
            throw new SecureStoreException($"Couldn't read secrets in {Path}: {e.Message}", e);
        }
    }
}

/// <summary>Where the app keeps its secrets (lib/channel_keys.dart's <c>SystemSecrets</c>).</summary>
public static class SystemSecrets
{
    /// <summary>A throwaway profile's secrets, for as long as the process runs.</summary>
    internal static readonly MemorySecureStore Profile = new();

    /// <summary>
    /// The system's: <paramref name="system"/>, or the <see cref="DpapiSecureStore"/> on Windows. A throwaway
    /// <c>POCKETTERM_PROFILE</c> (tool/smoke: a test build tried out as installed) keeps them in memory
    /// instead, shared for the process, and never reaches the person's. <paramref name="env"/>: where
    /// <c>POCKETTERM_PROFILE</c> is read, <see cref="TestHooks.Env"/> if null.
    /// </summary>
    public static ISecureStore Create(IReadOnlyDictionary<string, string>? env = null, ISecureStore? system = null)
    {
        if (IsThrowaway(env)) return Profile;
        if (system != null) return system;
        if (OperatingSystem.IsWindows()) return new DpapiSecureStore();
        throw new PlatformNotSupportedException("The system's secrets are kept with DPAPI, on Windows only");
    }

    /// <summary>A throwaway <c>POCKETTERM_PROFILE</c> is set in <paramref name="env"/> (<see cref="TestHooks.Env"/> if null).</summary>
    public static bool IsThrowaway(IReadOnlyDictionary<string, string>? env = null) =>
        !string.IsNullOrEmpty((env ?? TestHooks.Env()).GetValueOrDefault("POCKETTERM_PROFILE"));
}
