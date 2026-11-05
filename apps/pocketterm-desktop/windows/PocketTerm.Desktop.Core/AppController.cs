using System.Security.Cryptography;
using System.Text.Json.Nodes;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>
/// The desktop app (Dart's <c>AppController</c>): <see cref="Session"/> plus its main window, the
/// terminal bridge, the built-in server and every preference. The WinUI app binds to it
/// (<see cref="System.ComponentModel.INotifyPropertyChanged"/>: an empty property name means
/// "anything may have changed"); events fire on whatever thread changed it, the app marshals.
/// State shared with the bridge, the local API and timers is guarded by a lock; the bridge's
/// start/stop runs one at a time.
/// </summary>
public class AppController : Session
{
    /// <param name="prefs">Where the preferences are (<see cref="JsonPreferenceStore"/>).</param>
    /// <param name="device">What this computer calls itself (<see cref="IDesktopHost.DeviceNameAsync"/>).</param>
    /// <param name="host">The window, the tray item, idle time, keeping awake.</param>
    /// <param name="integrations">Installs PocketTerm into the coding agents; the bundled ones by default.</param>
    /// <param name="secrets">Where the sign-in and the channel keys are kept (<see cref="SystemSecrets"/>).</param>
    /// <param name="tailscale">The Tailscale CLI, which publishes the built-in server.</param>
    /// <param name="serverDir">Where the built-in server keeps its data; app support <c>pocketterm-server</c> by default.</param>
    /// <param name="commands">The installs setup offers (winget).</param>
    /// <param name="hostingPort">Where the built-in server listens on its first start; tests give 0.</param>
    /// <param name="terminals">This computer's terminals; WezTerm with a fresh PATH by default.</param>
    /// <param name="updates">The GitHub release check (the app passes one; null: none).</param>
    /// <param name="serverExecutable">The bundled <c>pocketterm-server</c> sidecar; next to the app by default.</param>
    public AppController(
        IPreferenceStore prefs,
        string device,
        IDesktopHost host,
        Integrations? integrations = null,
        ISecureStore? secrets = null,
        Tailscale? tailscale = null,
        Func<string>? serverDir = null,
        Commands? commands = null,
        int hostingPort = 47900,
        Terminals? terminals = null,
        UpdateCheck? updates = null,
        string? serverExecutable = null)
        : base(device, prefs)
    {
        Host = host;
        Integrations = integrations ?? new Integrations();
        var store = secrets ?? SystemSecrets.Create(TestHooks.Env());
        _keys = new ChannelKeys(store);
        _deviceTokens = new SecretDeviceTokens(store);
        Tailscale = tailscale ?? new Tailscale();
        Commands = commands ?? new Commands();
        HostingPort = hostingPort;
        _serverDir = serverDir ?? (() => AppPaths.ServerDataDir);
        _serverExecutable = serverExecutable;
        Terminals = terminals ?? Terminals.Standard(
            kittyDir: KittyDir(TestHooks.Env()),
            windowsPath: OperatingSystem.IsWindows() ? WindowsSystem.FreshWindowsPath : null);
        Live = new LiveHub(locate: Terminals.LocateAsync);
        Live.Events += e => _ = OnLive(e);
        Updates = updates;
    }

    private readonly object _lock = new();
    private readonly IDeviceTokens _deviceTokens;

    protected override IDeviceTokens DeviceTokens => _deviceTokens;

    private IPreferenceStore Prefs => Preferences;

    /// <summary>The computer's side: the window, the tray item, launch at login, keeping awake.</summary>
    public IDesktopHost Host { get; }

    /// <summary>Installs PocketTerm into the coding agents (Integrations/).</summary>
    public Integrations Integrations { get; }

    /// <summary>Installs the setup offers to run (winget's), each once the person confirmed it.</summary>
    public Commands Commands { get; }

    // ---------------------------------------------------------------- launch at login

    private bool? _launchAtLogin;

    /// <summary>Whether PocketTerm starts at login, as the system has it; null until <see cref="RefreshLaunchAtLoginAsync"/> asked.</summary>
    public bool? LaunchAtLogin
    {
        get
        {
            lock (_lock) return _launchAtLogin;
        }
    }

    public async Task RefreshLaunchAtLoginAsync()
    {
        var on = await Host.LaunchAtLoginAsync().ConfigureAwait(false);
        lock (_lock) _launchAtLogin = on;
        NotifyChanged();
    }

    /// <summary>Throws what the system said when it refused; <see cref="LaunchAtLogin"/> is then how it stands still.</summary>
    public async Task SetLaunchAtLoginAsync(bool on)
    {
        try
        {
            await Host.SetLaunchAtLoginAsync(on).ConfigureAwait(false);
        }
        finally
        {
            await RefreshLaunchAtLoginAsync().ConfigureAwait(false);
        }
    }

    // ---------------------------------------------------------------- terminal from phone

    /// <summary>Set once this computer has had its first sign-in (<see cref="OnSignedIn"/>).</summary>
    private const string FirstSignInKey = "first_sign_in_done";

    private const string TerminalKey = "terminal_bridge";

    /// <summary>
    /// The phone may see and type into this computer's terminals and the coding sessions
    /// (<see cref="TerminalBridge"/>): whoever holds the account can then type here. Turned on by the
    /// first sign-in (<see cref="OnSignedIn"/>), then as Settings has it.
    /// </summary>
    public bool TerminalOn => Prefs.GetBool(TerminalKey) ?? false;

    private TerminalBridge? _bridge;

    /// <summary>Whose <c>&lt;desktop id&gt;</c> topic <see cref="_bridge"/> is on: the server's id.</summary>
    private string? _bridgeUser;

    /// <summary>How far a phone's clock is off this computer's while it's too far for anything from it to be
    /// taken (TerminalBridge.ClockOff); null otherwise.</summary>
    public virtual TimeSpan? PhoneClockOff
    {
        get
        {
            lock (_lock) return _bridge?.ClockOff;
        }
    }

    /// <summary><see cref="StartBridge"/> calls, one after the other.</summary>
    private readonly SemaphoreSlim _bridging = new(1, 1);

    /// <summary>While the bridge runs: this computer tells the server it's there (<see cref="Seen"/>) every
    /// <see cref="SeenEvery"/>, so the phone lists it.</summary>
    private Timer? _seenTimer;

    private Task _seenOut = Task.CompletedTask;
    private static readonly TimeSpan SeenEvery = TimeSpan.FromSeconds(60);

    private const string IdChars = "abcdefghijklmnopqrstuvwxyz0123456789";

    /// <summary>This computer on server <paramref name="userId"/> (its desktops list): made up the first time, then kept.</summary>
    public string DesktopId(string userId)
    {
        var key = $"desktop_id_{userId}";
        lock (_lock)
        {
            if (Prefs.GetString(key) is { } id) return id;
            var made = string.Create(8, 0, (span, _) =>
            {
                for (var i = 0; i < span.Length; i++) span[i] = IdChars[RandomNumberGenerator.GetInt32(IdChars.Length)];
            });
            Prefs.SetString(key, made);
            return made;
        }
    }

    private readonly ChannelKeys _keys;

    /// <summary>This computer's channel key for the signed-in account (Storage/ChannelKeys.cs).</summary>
    public Task<ChannelKey> ChannelKeyAsync() => _keys.OfAsync(DesktopId(User!.Id));

    protected override async Task<ComputerKey?> PairingComputer() =>
        new ComputerKey(DesktopId(User!.Id), await ChannelKeyAsync().ConfigureAwait(false));

    /// <summary>A new channel key (Settings → Phone → Reset key): every phone has to scan this computer's code
    /// again. The bridge starts over with it.</summary>
    public async Task ResetChannelKeyAsync()
    {
        await _keys.ResetAsync(DesktopId(User!.Id)).ConfigureAwait(false);
        lock (_lock) _bridgeUser = null;
        await StartBridge().ConfigureAwait(false);
    }

    /// <summary>What the phone calls this computer: its name, as the server takes it.</summary>
    public static string DesktopName(string device)
    {
        var name = device.DartTrim();
        if (name.Length == 0) return "Computer";
        return name.Length <= 80 ? name : name[..80];
    }

    /// <summary>This computer's terminals (on Windows the WezTerm it starts gets the PATH a new login has).</summary>
    public Terminals Terminals { get; }

    /// <summary>Where kitty's sockets are: /tmp, or the directory <c>POCKETTERM_KITTY_DIR</c> names in a test
    /// build (<see cref="TestHooks"/>), so a second PocketTerm under test talks to a kitty of its own.</summary>
    public static string KittyDir(IReadOnlyDictionary<string, string> env) =>
        env.TryGetValue("POCKETTERM_KITTY_DIR", out var dir) && dir.Length > 0 ? dir : "/tmp";

    // ---------------------------------------------------------------- preferences

    private const string TerminalAppKey = "terminal_app";

    /// <summary>The terminal app new sessions from the phone open in: an app's id, or <c>auto</c> (the one used last).</summary>
    public string TerminalApp => Prefs.GetString(TerminalAppKey) ?? "auto";

    public void SetTerminalApp(string id)
    {
        Prefs.SetString(TerminalAppKey, id);
        NotifyChanged();
    }

    private const string PlacementKey = "session_placement";

    /// <summary>Whether a new session from the phone opens as a tab in its project's window (the default) or in
    /// a window of its own.</summary>
    public Placement Placement => DartEnum.Parse<Placement>(Prefs.GetString(PlacementKey)) ?? Placement.ProjectWindow;

    public void SetPlacement(Placement placement)
    {
        Prefs.SetString(PlacementKey, placement.Name());
        NotifyChanged();
    }

    private const string ProjectRootsKey = "project_roots";

    /// <summary>Folders holding the user's projects (Settings → Project folders): the phone lists the git
    /// repositories under them and makes new projects there.</summary>
    public IReadOnlyList<string> ProjectRoots => Prefs.GetStringList(ProjectRootsKey) ?? [];

    public void SetProjectRoots(IReadOnlyList<string> roots)
    {
        Prefs.SetStringList(ProjectRootsKey, roots);
        NotifyChanged();
    }

    private const string AgentKey = "coding_agent";

    /// <summary>The coding agent a new session from the phone starts.</summary>
    public Agent CodingAgent => Agents.Parse(Prefs.GetString(AgentKey));

    public void SetCodingAgent(Agent agent)
    {
        Prefs.SetString(AgentKey, agent.Name());
        NotifyChanged();
    }

    private const string SetupStepKey = "setup_step";
    private const string SetupAddressKey = "setup_address";

    /// <summary>Where the first-run setup was left: the screen's name, null on the first one. It opens there again.</summary>
    public string? SetupStep => Prefs.GetString(SetupStepKey);

    public void SetSetupStep(string? step)
    {
        if (step == null) Prefs.Remove(SetupStepKey);
        else Prefs.SetString(SetupStepKey, step);
    }

    /// <summary>The VPS address typed in the first-run setup, as typed.</summary>
    public string SetupAddress => Prefs.GetString(SetupAddressKey) ?? "";

    public void SetSetupAddress(string address) => Prefs.SetString(SetupAddressKey, address);

    private const string GetReadyKey = "get_ready_done";

    /// <summary>The setup checklist was finished or skipped on this computer; until then the signed-in window shows it.</summary>
    public bool GetReadyDone => Prefs.GetBool(GetReadyKey) ?? false;

    public void SetGetReadyDone(bool done)
    {
        Prefs.SetBool(GetReadyKey, done);
        NotifyChanged();
    }

    // ---------------------------------------------------------------- agents

    private IReadOnlyDictionary<Agent, AgentCheck>? _agents;
    private Task? _checkingAgents;
    private IReadOnlyList<string> _ompProfiles = [];
    private DateTime? _agentsAt;

    /// <summary>The coding agents found on this computer and PocketTerm in each, as of the last
    /// <see cref="CheckAgentsAsync"/>; null before the first one ends.</summary>
    public IReadOnlyDictionary<Agent, AgentCheck>? CodingAgents
    {
        get
        {
            lock (_lock) return _agents;
        }
    }

    /// <summary>This computer's omp profiles besides the default, as of the last <see cref="CheckAgentsAsync"/>; empty without omp.</summary>
    public IReadOnlyList<string> OmpProfiles
    {
        get
        {
            lock (_lock) return _ompProfiles;
        }
    }

    /// <summary>Looks for the coding agents and PocketTerm in them. One look at a time: a call while one runs waits for it.</summary>
    public Task CheckAgentsAsync()
    {
        lock (_lock)
        {
            return _checkingAgents ??= LookForAgents();
        }
    }

    private async Task LookForAgents()
    {
        try
        {
            var found = new Dictionary<Agent, AgentCheck>();
            foreach (var agent in Enum.GetValues<Agent>())
            {
                try
                {
                    if (!await Integrations.FoundAsync(agent).ConfigureAwait(false)) continue;
                    var state = await Integrations.StateAsync(agent).ConfigureAwait(false);
                    var modsOff = agent == Agent.Claude && state.Installed &&
                        await Integrations.ClaudeModsOffAsync().ConfigureAwait(false);
                    found[agent] = new AgentCheck(state, modsOff);
                }
                catch (Exception e)
                {
                    found[agent] = new AgentCheck(new IntegrationState(false, false, e.Message), false);
                }
            }
            var profiles = found.ContainsKey(Agent.Omp) ? Integrations.OmpProfiles() : [];
            lock (_lock)
            {
                _agents = found;
                _ompProfiles = profiles;
                _agentsAt = DateTime.UtcNow;
            }
            NotifyChanged();
        }
        finally
        {
            lock (_lock) _checkingAgents = null;
        }
    }

    /// <summary>Installs (or updates) PocketTerm in <paramref name="agent"/>, then looks again. Throws what went wrong.</summary>
    public async Task InstallAgentAsync(Agent agent)
    {
        try
        {
            await Integrations.InstallAsync(agent).ConfigureAwait(false);
        }
        finally
        {
            await CheckAgentsAsync().ConfigureAwait(false);
        }
    }

    /// <summary>What the phone hears (<see cref="TerminalBridge"/>): looked at again when the last look is older
    /// than <see cref="AgentsEvery"/>, since it runs <c>claude</c>.</summary>
    private async Task<IReadOnlyDictionary<Agent, AgentIntegration>> AgentsForPhone()
    {
        DateTime? at;
        lock (_lock) at = _agentsAt;
        if (at == null || DateTime.UtcNow - at.Value > AgentsEvery) await CheckAgentsAsync().ConfigureAwait(false);
        var agents = CodingAgents ?? new Dictionary<Agent, AgentCheck>();
        return agents.ToDictionary(e => e.Key, e => Integrations.IntegrationOf(e.Value));
    }

    private static readonly TimeSpan AgentsEvery = TimeSpan.FromSeconds(30);

    /// <summary>The terminal windows running a coding agent that no live session claims: started before
    /// PocketTerm was in it (or with it off), so they reach the phone only as screens.</summary>
    public IReadOnlyList<TermWindow> UnreportedAgentWindows(IReadOnlyList<TermWindow> windows)
    {
        var claimed = Live.Sessions.Select(s => s.Window).OfType<string>().ToHashSet();
        return windows.Where(w => w.Agent != null && !claimed.Contains(w.Key)).ToList();
    }

    // ---------------------------------------------------------------- phone

    private bool? _phoneSignedIn;

    /// <summary>A phone has signed in to this server: it's among the server's devices (<see cref="PhoneCodeUsed"/>)
    /// or said hello to this computer. Kept per server on this computer once seen. Null until known.</summary>
    public bool? PhoneSignedIn
    {
        get
        {
            lock (_lock) return _phoneSignedIn ?? (PhoneKept ? true : null);
        }
    }

    private string PhoneKey => $"phone_signed_in_{User?.Id ?? ""}";

    private bool PhoneKept => User != null && (Prefs.GetBool(PhoneKey) ?? false);

    /// <summary>Asks the server, until the answer is yes.</summary>
    public async Task CheckPhoneAsync()
    {
        if (PhoneSignedIn ?? false) return;
        try
        {
            var used = await PhoneCodeUsed().ConfigureAwait(false);
            if (used)
            {
                PhoneHeard();
                return;
            }
            lock (_lock)
            {
                if (used == _phoneSignedIn) return;
                _phoneSignedIn = used;
            }
            NotifyChanged();
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: phone sign-in unknown: {e.Message}");
        }
    }

    /// <summary>A phone is signed in to this server (GET /v1/devices).</summary>
    protected virtual async Task<bool> PhoneCodeUsed() =>
        (await Server!.Devices().ConfigureAwait(false)).Any(d => d.Role == DeviceRole.Phone);

    private void PhoneHeard()
    {
        if (User != null) Prefs.SetBool(PhoneKey, true);
        lock (_lock)
        {
            if (_phoneSignedIn ?? false) return;
            _phoneSignedIn = true;
        }
        NotifyChanged();
    }

    /// <summary>The coding sessions reporting to the local API (integrations/).</summary>
    public LiveHub Live { get; }

    /// <summary>Settings' Terminal from phone switch.</summary>
    public virtual async Task SetTerminalAsync(bool on)
    {
        Prefs.SetBool(TerminalKey, on);
        NotifyChanged();
        await StartBridge().ConfigureAwait(false);
    }

    /// <summary>
    /// One bridge for the signed-in user while <see cref="TerminalOn"/>: a new one when the user changes, none
    /// when they're gone however they went. Calls run one at a time, so two at once (the switch while a sign-in
    /// lands) don't both build one.
    /// </summary>
    private async Task StartBridge()
    {
        await _bridging.WaitAsync().ConfigureAwait(false);
        try
        {
            await SyncBridge().ConfigureAwait(false);
        }
        finally
        {
            _bridging.Release();
        }
    }

    private async Task SyncBridge()
    {
        var want = TerminalOn ? User?.Id : null;
        TerminalBridge? old;
        lock (_lock)
        {
            if (want == _bridgeUser) return;
            old = _bridge;
            _bridge = null;
            _bridgeUser = null;
            _seenTimer?.Dispose();
            _seenTimer = null;
        }
        if (old != null) await old.StopAsync().ConfigureAwait(false);
        if (want == null) return;
        var id = DesktopId(want);
        var key = await _keys.OfAsync(id).ConfigureAwait(false);
        var bridge = new TerminalBridge(
            Server!,
            id,
            key,
            Terminals,
            Live,
            Host,
            () => CodingAgent,
            () => TerminalApp,
            () => ProjectRoots,
            agents: AgentsForPhone,
            ompProfiles: () => OmpProfiles,
            placement: () => Placement,
            onPhone: PhoneHeard);
        lock (_lock)
        {
            _bridgeUser = want;
            _bridge = bridge;
        }
        await bridge.StartAsync().ConfigureAwait(false);
        Seen(id);
        lock (_lock) _seenTimer = new Timer(_ => Seen(id), null, SeenEvery, SeenEvery);
    }

    /// <summary>Tells the server this computer <paramref name="id"/> is there now (the server stamps seen_at by
    /// its own clock); a failure waits for the next beat.</summary>
    private void Seen(string id)
    {
        lock (_lock) _seenOut = SeenAfter(_seenOut, id);
    }

    private async Task SeenAfter(Task before, string id)
    {
        await before.ConfigureAwait(false);
        try
        {
            if (Server is { } s) await s.PutDesktop(id, DesktopName(Device), Platform).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: computer not listed: {e.Message}");
        }
    }

    /// <summary>A run ended, or the agent waits for an answer: the phones hear about it, unless it's showing that
    /// session right now.</summary>
    private async Task OnLive(LiveEvent e)
    {
        try
        {
            var s = e.Session;
            TerminalBridge? bridge;
            lock (_lock) bridge = _bridge;
            if (bridge?.Watching(s.Key) ?? false) return;
            var project = Live.ProjectName(s);
            var where = project.Length == 0 ? "" : $" · {project}";
            var (title, body, state) = e switch
            {
                LiveFinished f => ($"{s.Agent.LabelIn(s.Profile)} finished{where}", f.Summary, "done"),
                LiveAsked a => ($"{s.Agent.LabelIn(s.Profile)} needs you{where}", a.Ask.Text, "needs"),
                _ => throw new InvalidOperationException($"Unknown live event {e}"),
            };
            await NotifyPhoneAsync(title, body, session: s.Key, activity: state).ConfigureAwait(false);
        }
        catch (Exception x)
        {
            Log.Print($"PocketTerm: {x.Message}");
        }
    }

    /// <summary>Windows' check for a newer PocketTerm (the Mac has Sparkle): Settings and the tray offer it while
    /// there is one.</summary>
    public UpdateCheck? Updates { get; }

    public override async Task Start()
    {
        await Host.StartAsync(OnHost).ConfigureAwait(false);
        if (Updates is { } u)
        {
            u.PropertyChanged += (_, _) =>
            {
                Host.SetUpdate(u.Update);
                NotifyChanged();
            };
            u.Start();
        }
        if (Prefs.GetBool(HostingKey) ?? false)
        {
            try
            {
                await StartHosting().ConfigureAwait(false);
                // Where it listens now, should the port have moved: the sign-in kept for the old one doesn't
                // count, and this computer signs in again.
                Hosting!.Backend.Save(Prefs);
            }
            catch (Exception e)
            {
                Log.Print($"PocketTerm: built-in server not started: {e.Message}");
            }
        }
        await base.Start().ConfigureAwait(false);
        await SignInToOwnServer().ConfigureAwait(false);
        // Not set up or signed out: there's nothing to do but that, so say so.
        if (User == null) await OpenMainAsync().ConfigureAwait(false);
    }

    // ---------------------------------------------------------------- hosting

    /// <summary>This computer runs the server ("This computer" in the first-run setup): it starts with the app,
    /// until signing out here.</summary>
    private const string HostingKey = "hosting";

    /// <summary>The port it listened on last, tried first next time.</summary>
    private const string HostingPortKey = "hosting_port";

    /// <summary>Where the built-in server listens on its first start (the next free port above it when taken).
    /// Tests give 0, a port the system picks.</summary>
    public int HostingPort { get; }

    /// <summary>The Tailscale CLI, which publishes the built-in server.</summary>
    public Tailscale Tailscale { get; }

    private readonly Func<string> _serverDir;
    private readonly string? _serverExecutable;

    private BuiltInServer? _hosting;

    /// <summary>The built-in server, while this computer runs it.</summary>
    public BuiltInServer? Hosting
    {
        get
        {
            lock (_lock) return _hosting;
        }
    }

    public override bool HostsServer => Hosting?.Running ?? false;

    /// <summary>The ports this app's built-in server listens on now and listened on last: a Serve entry to one of
    /// these is this app's own.</summary>
    public IReadOnlySet<int> OwnServerPorts
    {
        get
        {
            var ports = new HashSet<int>();
            if (Hosting is { Running: true } h) ports.Add(h.Port);
            if (Prefs.GetInt(HostingPortKey) is { } last) ports.Add((int)last);
            return ports;
        }
    }

    /// <summary>
    /// "This computer": starts the built-in server, from now on at every launch, and signs this computer in to it.
    /// Throws what went wrong. A sign-in that fails (the secrets store refused it, say) takes it all back: the
    /// server stops and nothing is kept, so a later choice isn't overruled at the next launch;
    /// <see cref="Session.AuthError"/> says why.
    /// </summary>
    public async Task StartHostingAsync()
    {
        await StartHosting().ConfigureAwait(false);
        try
        {
            await SignInToOwnServer().ConfigureAwait(false);
        }
        catch
        {
            await UndoStart().ConfigureAwait(false);
            throw;
        }
        if (User == null)
        {
            await UndoStart().ConfigureAwait(false);
            return;
        }
        Prefs.SetBool(HostingKey, true);
    }

    private async Task UndoStart()
    {
        var why = AuthError;
        await Disconnect().ConfigureAwait(false);
        AuthError = why;
        NotifyChanged();
    }

    private async Task StartHosting()
    {
        if (Hosting != null) return;
        var h = new BuiltInServer(_serverDir(), Tailscale, executable: _serverExecutable);
        try
        {
            var last = Prefs.GetInt(HostingPortKey) is { } l ? (int)l : (int?)null;
            await h.StartAsync(port: last ?? HostingPort, earlier: last).ConfigureAwait(false);
        }
        catch
        {
            h.Dispose();
            throw;
        }
        h.PropertyChanged += OnHostingChanged;
        lock (_lock) _hosting = h;
        Prefs.SetInt(HostingPortKey, h.Port);
        NotifyChanged();
    }

    private void OnHostingChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e) => NotifyChanged();

    /// <summary>A computer running the server signs itself in with the server's own setup token, on 127.0.0.1.</summary>
    private async Task SignInToOwnServer()
    {
        var h = Hosting;
        if (h == null || User != null) return;
        await ConnectLink(await h.OwnSetupLinkAsync().ConfigureAwait(false)).ConfigureAwait(false);
    }

    private async Task StopHosting()
    {
        BuiltInServer? h;
        lock (_lock)
        {
            h = _hosting;
            _hosting = null;
        }
        if (h == null) return;
        h.PropertyChanged -= OnHostingChanged;
        Prefs.SetBool(HostingKey, false);
        await h.StopAsync().ConfigureAwait(false);
        h.Dispose();
        NotifyChanged();
    }

    /// <summary>"Add a computer…": the link another computer sets up with (through Tailscale); null until
    /// Tailscale serves this one.</summary>
    public Task<string?> ComputerSetupLinkAsync() => Hosting?.SetupLinkAsync() ?? Task.FromResult<string?>(null);

    /// <summary>A phone's code from a computer running the server carries its Tailscale address: phones can't
    /// reach 127.0.0.1.</summary>
    public override async Task<string> PairingLink()
    {
        var h = Hosting;
        if (h == null) return await base.PairingLink().ConfigureAwait(false);
        var url = h.PublicUrl ?? throw new PairingException("Tailscale isn’t serving this computer yet. See Settings → Account.");
        string code;
        try
        {
            code = await Server!.CreatePairingCode().ConfigureAwait(false);
        }
        catch (ServerException e)
        {
            throw new PairingException(e.Message);
        }
        return new Backend(url).LinkWithCode(code, await PairingComputer().ConfigureAwait(false));
    }

    /// <summary>Every computer and phone signed in to the server.</summary>
    public virtual Task<List<Device>> ServerDevicesAsync() => Server!.Devices();

    /// <summary>Signs device <paramref name="id"/> out of the server (a lost phone): its sign-in stops working and
    /// its push registrations go.</summary>
    public virtual Task RevokeServerDeviceAsync(string id) => Server!.RevokeDevice(id);

    /// <summary>Signing out of a server this computer runs stops it, and the first-run setup shows again. Its data
    /// stays: This computer starts it again with the same phones and computers.</summary>
    public override async Task SignOut()
    {
        await base.SignOut().ConfigureAwait(false);
        if (Hosting != null) await Disconnect().ConfigureAwait(false);
    }

    public override async Task Disconnect()
    {
        await base.Disconnect().ConfigureAwait(false);
        await StopHosting().ConfigureAwait(false);
    }

    /// <summary>Erasing signs this computer out too; it signs in again at once, as the first computer of an empty server.</summary>
    public override async Task EraseServer()
    {
        var phoneKey = PhoneKey;
        await base.EraseServer().ConfigureAwait(false);
        Prefs.Remove(phoneKey);
        await SignInToOwnServer().ConfigureAwait(false);
    }

    /// <summary>Stops what a quit ends with the process: the terminal bridge, the beat that lists this computer,
    /// the server connection, the built-in server.</summary>
    public async Task ShutDownAsync()
    {
        TerminalBridge? bridge;
        Task seen;
        lock (_lock)
        {
            _seenTimer?.Dispose();
            _seenTimer = null;
            seen = _seenOut;
            bridge = _bridge;
            _bridge = null;
            _bridgeUser = null;
        }
        await seen.ConfigureAwait(false);
        if (bridge != null) await bridge.StopAsync().ConfigureAwait(false);
        if (Hosting is { } h) await h.StopAsync().ConfigureAwait(false);
        Server?.Close();
    }

    public override void Dispose()
    {
        lock (_lock)
        {
            _seenTimer?.Dispose();
            _seenTimer = null;
        }
        Updates?.Dispose();
        base.Dispose();
    }

    /// <summary>The first sign-in on this computer turns on Terminal from phone (what PocketTerm is for); after that
    /// it stays as the user leaves it. Launch at login stays off until the user turns it on (Settings → Account): a
    /// login item is the person's to add.</summary>
    protected override async Task OnSignedIn(Account user)
    {
        if (Prefs.GetBool(FirstSignInKey) ?? false)
        {
            await StartBridge().ConfigureAwait(false);
            return;
        }
        try
        {
            await SetTerminalAsync(true).ConfigureAwait(false);
        }
        finally
        {
            Prefs.SetBool(FirstSignInKey, true);
        }
    }

    /// <summary>The phone stops listing this computer.</summary>
    protected override async Task OnSigningOut()
    {
        Task seen;
        lock (_lock)
        {
            _seenTimer?.Dispose();
            _seenTimer = null;
            seen = _seenOut;
        }
        await seen.ConfigureAwait(false);
        var id = Prefs.GetString($"desktop_id_{User?.Id}");
        if (id == null) return;
        if (Server is { } s) await s.DeleteDesktop(id).ConfigureAwait(false);
    }

    /// <summary>However the sign-in went (signed out here, the server stopped taking it): the terminal bridge stops.</summary>
    protected override async Task OnSignedOut()
    {
        // The next account's phones are its own.
        lock (_lock) _phoneSignedIn = null;
        try
        {
            await StartBridge().ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: terminal bridge not stopped: {e.Message}");
        }
    }

    /// <summary>A setup link to another server waits for a yes: in the main window.</summary>
    protected override void OnLinkToConfirm() => _ = OpenMainAsync();

    /// <summary>What a link said while signed in shows in the main window.</summary>
    protected override void OnNotice(string message) => _ = OpenMainAsync();

    // ---------------------------------------------------------------- window

    /// <summary>Runs when PocketTerm quits, before the app goes (a second at most): the local API takes itself out
    /// of cli.json.</summary>
    public Func<Task>? OnQuit { get; set; }

    /// <summary>What the host says: the tray item, quitting. A closed window (mainClosed) is only hidden:
    /// <see cref="MainHidden"/> says so.</summary>
    private Task OnHost(string @event)
    {
        switch (@event)
        {
            // Settings is the window while signed in.
            case "openMain" or "openSettings":
                _ = OpenMainAsync();
                break;
            case "mainClosed":
                SetMainHidden(true);
                break;
            case "quitting":
                var quitting = new List<Task>();
                if (OnQuit?.Invoke() is { } q) quitting.Add(q);
                if (Hosting is { } h) quitting.Add(h.StopAsync());
                return Task.WhenAll(quitting);
        }
        return Task.CompletedTask;
    }

    private int _mainShown;
    private bool _mainHidden;

    /// <summary>Ticks each time the main window is shown: it stays alive while hidden, so Settings checks the
    /// terminals and the agent's integration afresh.</summary>
    public int MainShown
    {
        get
        {
            lock (_lock) return _mainShown;
        }
    }

    /// <summary>The main window was closed (hidden) and not shown since.</summary>
    public bool MainHidden
    {
        get
        {
            lock (_lock) return _mainHidden;
        }
    }

    private void SetMainHidden(bool hidden)
    {
        lock (_lock)
        {
            if (_mainHidden == hidden) return;
            _mainHidden = hidden;
        }
        OnPropertyChanged(nameof(MainHidden));
    }

    /// <summary>Shows the main window.</summary>
    public Task OpenMainAsync()
    {
        lock (_lock) _mainShown++;
        OnPropertyChanged(nameof(MainShown));
        SetMainHidden(false);
        return Host.ShowMainAsync();
    }

    /// <summary>
    /// Pushes <paramref name="title"/> / <paramref name="body"/> to the phones (POST /v1/push/notify) when nobody
    /// has touched this computer for a minute: at the desk, its own screen says it already.
    /// <paramref name="session"/>: the coding session a tap opens; <paramref name="activity"/>: where it stands
    /// (done, needs). Sealed with this computer's key; outside the seal go only this computer's push tag and the
    /// session's (PushTag, SessionTag), which mean nothing without the key. False if it didn't go.
    /// </summary>
    public async Task<bool> NotifyPhoneAsync(string title, string body, string? session = null, string? activity = null)
    {
        if (User == null || await Host.IdleSecondsAsync().ConfigureAwait(false) < 60) return false;
        try
        {
            var id = DesktopId(User!.Id);
            var key = await ChannelKeyAsync().ConfigureAwait(false);
            var routed = session == null ? null : PocketTerm.Core.Live.RoutedKey(id, session);
            var notice = new JsonObject { ["title"] = title, ["body"] = body };
            notice.PutIfNotNull("session", routed);
            notice.PutIfNotNull("state", activity);
            var push = new JsonObject
            {
                ["tag"] = E2e.PushTag(key),
                ["enc"] = E2e.SealNotice(key, id, notice),
            };
            // Lets a newer push for the same session replace an older one.
            if (routed != null) push["collapse"] = E2e.SessionTag(key, routed);
            var data = await InvokePush("notify", push).ConfigureAwait(false);
            return (data.Int("sent") ?? 0) > 0;
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: notify failed: {e.Message}");
            return false;
        }
    }

    /// <summary>Push <paramref name="action"/> with <paramref name="body"/> on the server; its answer.</summary>
    protected virtual Task<JsonObject> InvokePush(string action, JsonObject body) => Server!.Push(action, body);
}
