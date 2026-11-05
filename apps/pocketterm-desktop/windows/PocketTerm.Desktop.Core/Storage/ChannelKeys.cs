using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>
/// This computer's sign-in on its server (the device token and what came with it), kept in the
/// <see cref="ISecureStore"/> next to the channel keys as <c>device_token</c>. A store that fails throws
/// <see cref="SecureStoreException"/>, which the sign-in shows as a keychain problem it can retry.
/// </summary>
public sealed class SecretDeviceTokens(ISecureStore store) : IDeviceTokens
{
    private const string Name = "device_token";

    public Task<string?> Read() => Guard(() => store.ReadAsync(Name));

    public Task Write(string? value) => Guard(async () =>
    {
        if (value == null) await store.DeleteAsync(Name).ConfigureAwait(false);
        else await store.WriteAsync(Name, value).ConfigureAwait(false);
        return true;
    });

    private static async Task<T> Guard<T>(Func<Task<T>> op)
    {
        try
        {
            return await op().ConfigureAwait(false);
        }
        catch (Exception e) when (e is not SecureStoreException)
        {
            throw new SecureStoreException(e.Message, e);
        }
    }
}

/// <summary>
/// This computer's channel keys (PocketTerm.Core's <see cref="ChannelKey"/>), one per computer id (an
/// account's): made the first time one is needed, then kept in the <see cref="ISecureStore"/> as
/// <c>channel_key_&lt;id&gt;</c>. Never sent to a server; a phone gets it from this computer's QR code.
/// Thread-safe: a lock guards the cache of pending loads, never held across an await.
/// </summary>
public sealed class ChannelKeys(ISecureStore store)
{
    private readonly object _gate = new();
    private readonly Dictionary<string, Task<ChannelKey>> _keys = new(StringComparer.Ordinal);

    /// <summary>Computer <paramref name="desktopId"/>'s key; two asking at once get the same one. A store
    /// that failed is asked again next time.</summary>
    public async Task<ChannelKey> OfAsync(string desktopId)
    {
        Task<ChannelKey> pending;
        TaskCompletionSource<ChannelKey>? mine = null;
        lock (_gate)
        {
            if (_keys.TryGetValue(desktopId, out var existing))
            {
                pending = existing;
            }
            else
            {
                mine = new TaskCompletionSource<ChannelKey>(TaskCreationOptions.RunContinuationsAsynchronously);
                pending = mine.Task;
                _keys[desktopId] = pending;
            }
        }
        if (mine != null)
        {
            try
            {
                mine.SetResult(await LoadAsync(desktopId).ConfigureAwait(false));
            }
            catch (Exception e)
            {
                mine.SetException(e);
            }
        }
        try
        {
            return await pending.ConfigureAwait(false);
        }
        catch (Exception)
        {
            lock (_gate)
            {
                if (_keys.TryGetValue(desktopId, out var k) && k == pending) _keys.Remove(desktopId);
            }
            throw;
        }
    }

    /// <summary>A new key for <paramref name="desktopId"/>: phones with the old one can't read it any more.</summary>
    public async Task<ChannelKey> ResetAsync(string desktopId)
    {
        var key = ChannelKey.Generate();
        await store.WriteAsync(NameOf(desktopId), key.ToBase64()).ConfigureAwait(false);
        lock (_gate) _keys[desktopId] = Task.FromResult(key);
        return key;
    }

    private async Task<ChannelKey> LoadAsync(string desktopId)
    {
        if (ChannelKey.TryParse(await store.ReadAsync(NameOf(desktopId)).ConfigureAwait(false)) is { } kept) return kept;
        var key = ChannelKey.Generate();
        await store.WriteAsync(NameOf(desktopId), key.ToBase64()).ConfigureAwait(false);
        return key;
    }

    /// <summary>The secret's name for <paramref name="desktopId"/>'s key.</summary>
    public static string NameOf(string desktopId) => $"channel_key_{desktopId}";
}
