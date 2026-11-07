using System.Text.Json.Nodes;
using PocketTerm.Core;
using PocketTerm.Core.Tests;
using PocketTerm.Desktop;

namespace PocketTerm.Desktop.Tests;

/// <summary>The computer's side, recording what it was asked in <see cref="Calls"/>.</summary>
internal sealed class FakeDesktopHost : IDesktopHost
{
    private readonly object _gate = new();
    private readonly List<string> _calls = [];

    public List<string> Calls
    {
        get
        {
            lock (_gate) return [.. _calls];
        }
    }

    public void ClearCalls()
    {
        lock (_gate) _calls.Clear();
    }

    private void Call(string what)
    {
        lock (_gate) _calls.Add(what);
    }

    /// <summary>What <see cref="IdleSecondsAsync"/> answers.</summary>
    public int Idle { get; set; }

    /// <summary>Whether PocketTerm is a login item.</summary>
    public bool LoginItem { get; set; }

    /// <summary>What <see cref="StartAsync"/> was given.</summary>
    public Func<string, Task>? OnEvent { get; private set; }

    public UpdateInfo? Update { get; private set; }

    public Task StartAsync(Func<string, Task> onEvent)
    {
        Call("start");
        OnEvent = onEvent;
        return Task.CompletedTask;
    }

    public Task ShowMainAsync()
    {
        Call("showMain");
        return Task.CompletedTask;
    }

    public Task HideMainAsync()
    {
        Call("hideMain");
        return Task.CompletedTask;
    }

    public Task QuitAsync()
    {
        Call("quit");
        return Task.CompletedTask;
    }

    public Task<string> DeviceNameAsync()
    {
        Call("deviceName");
        return Task.FromResult("PC");
    }

    public Task<int> IdleSecondsAsync()
    {
        Call("idleSeconds");
        return Task.FromResult(Idle);
    }

    public Task<bool> LaunchAtLoginAsync()
    {
        Call("launchAtLogin");
        return Task.FromResult(LoginItem);
    }

    public Task SetLaunchAtLoginAsync(bool on)
    {
        Call($"setLaunchAtLogin({(on ? "true" : "false")})");
        LoginItem = on;
        return Task.CompletedTask;
    }

    public Task<IReadOnlyList<string>> PickFoldersAsync()
    {
        Call("pickFolders");
        return Task.FromResult<IReadOnlyList<string>>([]);
    }

    public Task SetKeepAwakeAsync(bool on)
    {
        Call($"setKeepAwake({(on ? "true" : "false")})");
        return Task.CompletedTask;
    }

    public Task SetAppIconAsync(string icon)
    {
        Call($"setAppIcon({icon})");
        return Task.CompletedTask;
    }

    public void SetUpdate(UpdateInfo? update) => Update = update;
}

/// <summary>A server that signs in whoever comes (<see cref="Account"/> once loaded), records what this computer
/// told it, and never opens a live channel.</summary>
internal sealed class FakeServer(Backend backend, Account? account) : IServer
{
    public Backend Backend { get; } = backend;

    public Account? Account { get; private set; } = account;

    public event EventHandler? Ended;

    public List<string> Listed { get; } = [];

    public List<string> Unlisted { get; } = [];

    public List<Device> DeviceList { get; set; } = [];

    private int _codes;

    public void FreshConnections()
    {
    }

    public Task Load() => Task.CompletedTask;

    public Task Recheck() => Task.CompletedTask;

    public Task<Account> RedeemSetup(string setup, string label, string platform)
    {
        Account = new Account("server-1", new Device("device-1", DeviceRole.Desktop, label, platform));
        return Task.FromResult(Account);
    }

    public Task<Account> RedeemCode(string code, string label, string platform) => throw new NotSupportedException();

    public Task Leave()
    {
        Account = null;
        return Task.CompletedTask;
    }

    public Task Erase() => throw new NotSupportedException();

    public Task Refused()
    {
        Account = null;
        Ended?.Invoke(this, EventArgs.Empty);
        return Task.CompletedTask;
    }

    public Task<string> CreatePairingCode() => Task.FromResult($"PAIR-{++_codes}AAA-BBBB-CCCC-DDDD-EEEE-FFFF");

    public Task<List<Device>> Devices() => Task.FromResult(DeviceList);

    public Task RevokeDevice(string id) => throw new NotSupportedException();

    public Task<List<JsonObject>> Desktops() => Task.FromResult(new List<JsonObject>());

    public Task PutDesktop(string id, string name, string platform)
    {
        lock (Listed) Listed.Add($"{id} {name} {platform}");
        return Task.CompletedTask;
    }

    public Task DeleteDesktop(string id)
    {
        lock (Unlisted) Unlisted.Add(id);
        return Task.CompletedTask;
    }

    public string NewBlobPath() => throw new NotSupportedException();

    public Task PutBlob(string path, byte[] bytes) => throw new NotSupportedException();

    public Task<byte[]> GetBlob(string path) => throw new NotSupportedException();

    public Task DeleteBlob(string path) => throw new NotSupportedException();

    public Task<JsonObject> Push(string action, JsonObject body) => throw new NotSupportedException();

    public Task<ILiveSocket> ConnectLive() => throw new ServerException(0, "offline", "No live channel in this test.");

    public void Close()
    {
    }
}

/// <summary>
/// An <see cref="AppController"/> as the tests drive it: preferences and secrets in memory, no coding agents, no
/// terminals, Tailscale not installed, and (unless <c>real</c>) <see cref="FakeServer"/>s instead of servers.
/// </summary>
internal sealed class TestApp : AppController
{
    public const string Url = "https://pt.example.com";

    private TestApp(
        MemoryPreferenceStore prefs,
        bool real,
        Account? account,
        Tailscale? tailscale,
        string? serverDir,
        string? serverExecutable,
        ISecureStore? secrets)
        : base(
            prefs,
            "PC",
            new FakeDesktopHost(),
            integrations: new Integrations(
                home: "/nonexistent-pocketterm-test",
                bundled: "/nonexistent-pocketterm-test/integrations",
                run: (_, _) => Task.FromResult(new Integrations.RunResult(1, "", "")),
                claudePaths: [],
                ompPaths: []),
            secrets: secrets ?? new MemorySecureStore(),
            tailscale: tailscale ?? new FakeTailscale().Tailscale,
            serverDir: () => serverDir ?? "/nonexistent-pocketterm-test/server",
            commands: new Commands((_, _, _) => Task.FromResult(new CommandResult(127, "")), windows: false),
            // Its built-in server apart from the other tests' (run side by side): no 47900 and up.
            hostingPort: 0,
            terminals: new Terminals("/nonexistent-pocketterm-test", [], snapshot: () => Task.FromResult(new Procs([]))),
            serverExecutable: serverExecutable)
    {
        Prefs = prefs;
        _real = real;
        _account = account;
    }

    private readonly bool _real;
    private readonly Account? _account;

    public MemoryPreferenceStore Prefs { get; }

    public FakeDesktopHost FakeHost => (FakeDesktopHost)Host;

    /// <summary>The servers this app was given, newest last.</summary>
    public List<FakeServer> Servers { get; } = [];

    /// <summary>What went to the server's push, in order: the action and its body.</summary>
    public List<(string Action, JsonObject Body)> Pushes { get; } = [];

    /// <summary>[prefs]: what this computer had saved (or <paramref name="store"/>, kept from an earlier launch).
    /// With <paramref name="real"/>, servers are Session's own.</summary>
    public static TestApp Create(
        IReadOnlyDictionary<string, object>? prefs = null,
        bool real = false,
        Tailscale? tailscale = null,
        string? serverDir = null,
        string? serverExecutable = null,
        ISecureStore? secrets = null,
        MemoryPreferenceStore? store = null)
    {
        store ??= new MemoryPreferenceStore();
        foreach (var (k, v) in prefs ?? new Dictionary<string, object>())
        {
            switch (v)
            {
                case bool b: store.SetBool(k, b); break;
                case string s: store.SetString(k, s); break;
                case int i: store.SetInt(k, i); break;
                default: throw new ArgumentException($"{k}: {v}");
            }
        }
        // Its saved https://pt.example.com isn't signed out by the one-time migration, unless a test asks for it.
        if (store.GetBool(TailscaleOnlyMigration.DoneKey) == null) store.SetBool(TailscaleOnlyMigration.DoneKey, true);
        var account = new Account("server-1", new Device("device-1", DeviceRole.Desktop, "PC", "windows"));
        return new TestApp(store, real, account, tailscale, serverDir, serverExecutable, secrets);
    }

    /// <summary>Signs in as server-1 on <see cref="Url"/> (what a launch with a kept sign-in does).</summary>
    public async Task SignedInAsync()
    {
        await Connect(new Backend(Url));
        await Wait.Until(() => User != null);
    }

    protected override IServer Client(Backend backend, IDeviceTokens tokens)
    {
        if (_real) return base.Client(backend, tokens);
        var s = new FakeServer(backend, _account);
        Servers.Add(s);
        return s;
    }

    protected override Task<JsonObject> InvokePush(string action, JsonObject body)
    {
        Pushes.Add((action, body));
        return Task.FromResult(new JsonObject { ["sent"] = 1 });
    }

    /// <summary>No bridge to the terminals in these tests: Terminal from phone is only its setting.</summary>
    public override Task SetTerminalAsync(bool on)
    {
        Prefs.SetBool("terminal_bridge", on);
        return Task.CompletedTask;
    }
}

/// <summary>Secrets kept in memory, as the system would keep them; while <see cref="Locked"/>, writes fail as a
/// locked store's do.</summary>
internal sealed class LockableSecrets : ISecureStore
{
    private readonly MemorySecureStore _values = new();

    public bool Locked { get; set; }

    public Task<string?> ReadAsync(string key) => _values.ReadAsync(key);

    public Task WriteAsync(string key, string value) =>
        Locked ? throw new SecureStoreException("The secrets file couldn't be written.") : _values.WriteAsync(key, value);

    public Task DeleteAsync(string key) => _values.DeleteAsync(key);
}
