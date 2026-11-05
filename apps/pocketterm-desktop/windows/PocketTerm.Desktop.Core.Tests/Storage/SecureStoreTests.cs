using System.Security.Cryptography;
using System.Text;
using PocketTerm.Core;
using PocketTerm.Desktop.Tests.Store;

namespace PocketTerm.Desktop.Tests;

/// <summary>DpapiSecureStore, SystemSecrets, SecretDeviceTokens and ChannelKeys (test/channel_keys_test.dart).</summary>
public sealed class SecureStoreTests : IDisposable
{
    private readonly TempDir _dir = new();

    public void Dispose() => _dir.Dispose();

    private string File1 => _dir["secrets.dat"];

    [Fact]
    public async Task SecretsSurviveARestartSealedAsAJsonObject()
    {
        var protector = new FakeProtector();
        var store = new DpapiSecureStore(File1, protector);
        Assert.Null(await store.ReadAsync("device_token"));
        await store.WriteAsync("device_token", "tök\"en");
        await store.WriteAsync("channel_key_d1", "AAAA");
        await store.DeleteAsync("channel_key_d1");
        await store.DeleteAsync("never there");

        Assert.DoesNotContain("device_token", Encoding.UTF8.GetString(File.ReadAllBytes(File1)));
        Assert.Equal("{\"device_token\":\"tök\\\"en\"}", Encoding.UTF8.GetString(protector.Unprotect(File.ReadAllBytes(File1))));
        Assert.Equal("tök\"en", await new DpapiSecureStore(File1, protector).ReadAsync("device_token"));
    }

    [Fact]
    public async Task WritesAtOnceFromTheDeviceTokenAndTheChannelKeysAllStay()
    {
        // Two stores on one file, as the controller has (one for the sign-in, one for the keys), each
        // write slow enough that two at once would overlap.
        var protector = new FakeProtector { Delay = TimeSpan.FromMilliseconds(20) };
        var tokens = new SecretDeviceTokens(new DpapiSecureStore(File1, protector));
        var keys = new ChannelKeys(new DpapiSecureStore(File1, protector));
        // Started in this order, as at sign-in: the last write of the token is the one kept.
        await Task.WhenAll(
            tokens.Write("token"),
            keys.OfAsync("desk-1"),
            keys.OfAsync("desk-2"),
            tokens.Write("token 2"));
        var all = DpapiSecureStore.ReadFile(File1, protector);
        Assert.Equal(["channel_key_desk-1", "channel_key_desk-2", "device_token"], all.Keys.Order(StringComparer.Ordinal));
        Assert.Equal("token 2", all["device_token"]);
        Assert.Equal("token 2", await tokens.Read());
    }

    [Fact]
    public async Task AFailedWriteFailsAloneAndTheNextOnesStillRun()
    {
        var protector = new FakeProtector { FailNext = true };
        var secrets = new DpapiSecureStore(File1, protector);
        var first = secrets.WriteAsync("a", "1");
        var second = secrets.WriteAsync("b", "2");
        var e = await Assert.ThrowsAsync<SecureStoreException>(() => first);
        Assert.IsType<CryptographicException>(e.InnerException);
        await second;
        Assert.Equal(new Dictionary<string, string> { ["b"] = "2" }, DpapiSecureStore.ReadFile(File1, protector));
    }

    [Fact]
    public async Task AFileThatCantBeOpenedFailsOnceAndIsSetAsideForAFreshStart()
    {
        File.WriteAllText(File1, "someone else's");
        var store = new DpapiSecureStore(File1, new FakeProtector());
        await Assert.ThrowsAsync<SecureStoreException>(() => store.ReadAsync("device_token"));
        Assert.Equal("someone else's", File.ReadAllText(File1 + ".bad"));
        await store.WriteAsync("device_token", "new");
        Assert.Equal("new", await store.ReadAsync("device_token"));
    }

    [Fact]
    public async Task AThrowawayProfileKeepsItsSecretsInMemoryAndNeverReachesThePersons()
    {
        var protector = new FakeProtector();
        var persons = new DpapiSecureStore(File1, protector);
        await persons.WriteAsync("device_token", "the person's");
        var smoke = new Dictionary<string, string> { ["POCKETTERM_PROFILE"] = "smoke" };

        var tokens = new SecretDeviceTokens(SystemSecrets.Create(smoke, persons));
        Assert.Null(await tokens.Read());
        await tokens.Write("throwaway");
        Assert.Equal("throwaway", await tokens.Read());
        // Shared for the process, as a second store made for the profile sees.
        Assert.Equal("throwaway", await new SecretDeviceTokens(SystemSecrets.Create(smoke, persons)).Read());
        Assert.Equal(new Dictionary<string, string> { ["device_token"] = "the person's" }, DpapiSecureStore.ReadFile(File1, protector));
        Assert.Equal("the person's", await new SecretDeviceTokens(SystemSecrets.Create(new Dictionary<string, string>(), persons)).Read());
        Assert.Same(persons, SystemSecrets.Create(new Dictionary<string, string> { ["POCKETTERM_PROFILE"] = "" }, persons));
    }

    [Fact]
    public async Task DeviceTokensForgetOnNullAndReportAFailingStoreAsSecureStoreException()
    {
        var store = new MemorySecureStore();
        var tokens = new SecretDeviceTokens(store);
        await tokens.Write("t");
        Assert.Equal("t", await store.ReadAsync("device_token"));
        await tokens.Write(null);
        Assert.Null(await store.ReadAsync("device_token"));

        var broken = new SecretDeviceTokens(new FailingStore());
        Assert.IsType<IOException>((await Assert.ThrowsAsync<SecureStoreException>(() => broken.Read())).InnerException);
        await Assert.ThrowsAsync<SecureStoreException>(() => broken.Write("t"));
    }

    [Fact]
    public async Task AChannelKeyIsMadeOnceKeptAndAskedForAtOnceGivesTheSameOne()
    {
        var store = new MemorySecureStore();
        var keys = new ChannelKeys(store);
        var both = await Task.WhenAll(keys.OfAsync("d1"), keys.OfAsync("d1"));
        Assert.Same(both[0], both[1]);
        Assert.Equal(both[0].ToBase64(), await store.ReadAsync("channel_key_d1"));
        Assert.Equal(both[0], await new ChannelKeys(store).OfAsync("d1"));
        Assert.NotEqual(both[0], await keys.OfAsync("d2"));
    }

    [Fact]
    public async Task AResetKeyReplacesTheOldOneForGood()
    {
        var store = new MemorySecureStore();
        var keys = new ChannelKeys(store);
        var old = await keys.OfAsync("d1");
        var fresh = await keys.ResetAsync("d1");
        Assert.NotEqual(old, fresh);
        Assert.Equal(fresh, await keys.OfAsync("d1"));
        Assert.Equal(fresh, await new ChannelKeys(store).OfAsync("d1"));
    }

    [Fact]
    public async Task AStoreThatFailedIsAskedAgainNextTime()
    {
        var store = new FailingStore();
        var keys = new ChannelKeys(store);
        await Assert.ThrowsAsync<IOException>(() => keys.OfAsync("d1"));
        store.Fails = false;
        var key = await keys.OfAsync("d1");
        Assert.Equal(key.ToBase64(), await store.ReadAsync("channel_key_d1"));
    }

    [StoreWindowsFact]
    public async Task OnWindowsTheFileIsSealedWithDpapiForThisUser()
    {
        if (!OperatingSystem.IsWindows()) return;
        var store = new DpapiSecureStore(File1, new DpapiProtector());
        await store.WriteAsync("device_token", "secret token");
        var bytes = File.ReadAllBytes(File1);
        Assert.DoesNotContain("secret token", Encoding.UTF8.GetString(bytes));
        Assert.Equal("{\"device_token\":\"secret token\"}",
            Encoding.UTF8.GetString(ProtectedData.Unprotect(bytes, null, DataProtectionScope.CurrentUser)));
        Assert.Equal("secret token", await new DpapiSecureStore(File1, new DpapiProtector()).ReadAsync("device_token"));
    }

    /// <summary>A store that throws while <see cref="Fails"/>, else keeps secrets in memory.</summary>
    private sealed class FailingStore : ISecureStore
    {
        private readonly MemorySecureStore _memory = new();

        public bool Fails { get; set; } = true;

        public Task<string?> ReadAsync(string key) => Fails ? Task.FromException<string?>(new IOException("locked")) : _memory.ReadAsync(key);

        public Task WriteAsync(string key, string value) => Fails ? Task.FromException(new IOException("locked")) : _memory.WriteAsync(key, value);

        public Task DeleteAsync(string key) => Fails ? Task.FromException(new IOException("locked")) : _memory.DeleteAsync(key);
    }
}
