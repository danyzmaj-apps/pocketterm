namespace PocketTerm.Core;

/// <summary>A secure store (Keychain, DPAPI file) that couldn't keep a secret: the sign-in fails with
/// <see cref="Session.KeychainProblem"/> and can be retried (<see cref="Session.Retry"/>).</summary>
public sealed class SecureStoreException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>Why a pairing code couldn't be made, worded for the person.</summary>
public sealed class PairingException(string message) : Exception(message)
{
    public override string ToString() => Message;
}

/// <summary>
/// The connected server (<see cref="Backend"/>) and signing in to it (the server's setup link on a computer, a
/// computer's code on a phone): what the desktop and the phone apps share. Signed in is holding a device token
/// (<see cref="IServer.Account"/>), kept in <see cref="DeviceTokens"/>. The app hands it setup links opened from
/// outside (<see cref="HandleLink"/>: the <c>pocketterm://</c> activation) and overrides the hooks.
/// </summary>
public abstract class Session : ObservableObject, IDisposable
{
    /// <summary>What a sign-in says when the Keychain (locked, or missing) didn't let PocketTerm keep it.</summary>
    public const string KeychainProblem =
        "PocketTerm can\u2019t use your keychain (it may be locked or missing). Unlock it in Keychain Access, then " +
        "try again.";

    private const string CodeUsed =
        "That code doesn't work: it was used, or it's more than 10 minutes old. Make a new one on your computer " +
        "(Settings → Phone → Add a phone…).";

    private Backend? _backend;
    private IServer? _server;
    private Account? _user;
    private string? _signedOutReason;
    private string? _linkToConfirm;
    private Backend? _saved;

    /// <summary>Set by <see cref="SignOut"/> and <see cref="EraseServer"/> just before the sign-in goes.</summary>
    private string? _leaving;

    /// <param name="device">This machine's name: its label on the server and of its push registration.</param>
    /// <param name="preferences">Where the server this device connects through is kept.</param>
    protected Session(string device, IPreferenceStore preferences)
    {
        Device = device;
        Preferences = preferences;
    }

    /// <summary>This machine's name: its label on the server and of its push registration.</summary>
    public string Device { get; }

    protected IPreferenceStore Preferences { get; }

    /// <summary>What this device is to the server: a computer, unless a phone says so. A computer signs in with the
    /// server's setup token, a phone only with a computer's pairing code.</summary>
    public virtual DeviceRole Role => DeviceRole.Desktop;

    /// <summary>This device's platform, as the server takes it: <c>macos</c>, <c>windows</c>, <c>linux</c>,
    /// <c>ios</c> or <c>android</c>.</summary>
    public virtual string Platform =>
        OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsMacOS() ? "macos" : OperatingSystem.IsLinux() ? "linux" : "unknown";

    /// <summary>Where this device keeps its sign-in: the Keychain or a DPAPI file on a computer.</summary>
    protected abstract IDeviceTokens DeviceTokens { get; }

    /// <summary>The server this device connects through; null until one is set up (the setup screen shows then).</summary>
    public Backend? Backend => _backend;

    /// <summary>Only while <see cref="Backend"/> is set.</summary>
    public IServer? Server => _server;

    /// <summary>This device, signed in; null while signed out.</summary>
    public Account? User => _user;

    /// <summary>Why the last sign-in or connect didn't happen, for the signed-out pages; null once one did, and
    /// after signing out.</summary>
    public string? AuthError { get; set; }

    /// <summary>What a link says to this device while it's signed in, once: one it can't use as is (a code for
    /// another server, a computer's key that wasn't scanned, a code that didn't work). The page in front shows it;
    /// <see cref="AuthError"/> stays the signed-out pages'.</summary>
    public event EventHandler<string>? Notices;

    private void Notice(string message)
    {
        Notices?.Invoke(this, message);
        OnNotice(message);
    }

    /// <summary>A notice went out (<see cref="Notices"/>): the computer brings its window up.</summary>
    protected virtual void OnNotice(string message)
    {
    }

    /// <summary>The key this device holds for <paramref name="desktopId"/>, if any (a phone's, from a scanned code).</summary>
    public virtual ChannelKey? ComputerKey(string desktopId) => null;

    /// <summary>The link whose sign-in failed only because the Keychain couldn't keep it
    /// (<see cref="KeychainProblem"/>): <see cref="Retry"/> tries it again.</summary>
    public string? RetryLink { get; set; }

    /// <summary>Signs in again with <see cref="RetryLink"/>.</summary>
    public async Task Retry()
    {
        if (RetryLink is { } link) await ConnectLink(link).ConfigureAwait(false);
    }

    /// <summary>Why the last sign-in is gone, once it is (signed out here, the server ended it); null after a sign-in.</summary>
    public string? SignedOutReason => _signedOutReason;

    /// <summary>Launch: opens the server this device was set up with, if any. Setup links
    /// (<c>pocketterm://setup?url=…[&amp;code=…|&amp;setup=…]</c>) opened meanwhile come through <see cref="HandleLink"/>.</summary>
    public virtual async Task Start()
    {
        _saved = Backend.Load(Preferences);
        if (_saved is { } backend) await Connect(backend).ConfigureAwait(false);
    }

    /// <summary>A link opened from outside the app (the <c>pocketterm://</c> activation, a second instance's
    /// arguments). Same as Dart's link stream: <see cref="OpenedLink"/> with the backend saved at launch.</summary>
    public void HandleLink(string link)
    {
        if (DartUri.TryParse(link) is not { } uri)
        {
            OnOtherLink(link);
            return;
        }
        OpenedLink(uri, _saved ?? Backend.Load(Preferences));
    }

    /// <summary>A setup link opened from outside the app (a web page, a message, the camera app). One that would
    /// connect this signed-out device to a server other than its own (<paramref name="saved"/> until
    /// <see cref="Connect"/> is done) waits for the person (<see cref="LinkToConfirm"/>): anyone can send a link,
    /// and this device's sessions would then go through that server. Any other link goes to <see cref="OnOtherLink"/>.</summary>
    internal void OpenedLink(DartUri uri, Backend? saved)
    {
        var backend = Backend.FromLink(uri);
        if (backend == null)
        {
            OnOtherLink(uri.ToString());
            return;
        }
        if (_user == null && backend != (_backend ?? saved))
        {
            _linkToConfirm = uri.ToString();
            NotifyChanged();
            OnLinkToConfirm();
            return;
        }
        _ = ConnectLink(uri.ToString());
    }

    /// <summary>A setup link to another server, waiting for <see cref="AnswerLink"/>.</summary>
    public string? LinkToConfirm => _linkToConfirm;

    /// <summary>The host <see cref="LinkToConfirm"/> would connect to, for the question ("Connect to …?").</summary>
    public string? LinkToConfirmHost => _linkToConfirm is { } l ? Backend.FromLink(l)?.Host ?? "?" : null;

    /// <summary>The person's answer to <see cref="LinkToConfirm"/>: <see cref="Connect"/> goes on with it.</summary>
    public async Task AnswerLink(bool connect)
    {
        var uri = _linkToConfirm;
        _linkToConfirm = null;
        NotifyChanged();
        if (connect && uri != null) await ConnectLink(uri).ConfigureAwait(false);
    }

    /// <summary>A link now waits in <see cref="LinkToConfirm"/>: the computer brings its window up.</summary>
    protected virtual void OnLinkToConfirm()
    {
    }

    /// <summary>A link opened from outside the app that isn't a setup link.</summary>
    protected virtual void OnOtherLink(string uri)
    {
    }

    /// <summary>
    /// A setup link: connects to its server and signs in with what it carries (a computer: the server's setup
    /// token; a phone: a computer's pairing code). A computer key in it (<see cref="Backend.ComputerKey"/>) goes to
    /// <see cref="AddComputerKey"/> only when the link was <paramref name="scanned"/> with the in-app scanner, also
    /// when already signed in (a phone scanning one more computer): anyone can send a link from outside the app, and
    /// a key it planted would let them read that computer's sessions. A key that would replace another one held for
    /// that computer counts only once the code's pairing code works: only a computer signed in to this server makes
    /// one. Problems land in <see cref="AuthError"/>, or in <see cref="Notices"/> while signed in.
    /// </summary>
    public virtual async Task ConnectLink(string link, bool scanned = false)
    {
        if (DartUri.TryParse(link) is not { } uri) return;
        var backend = Backend.FromLink(uri);
        if (backend == null) return;
        var phone = Role == DeviceRole.Phone;
        var secret = phone ? Backend.PairingCode(uri) : Backend.SetupToken(uri);
        var computer = scanned ? Backend.ComputerKey(uri) : null;
        if (User != null)
        {
            if (backend != Backend)
            {
                // A phone keeps one server: a computer on another needs it to leave this one first.
                Notice(phone
                    ? $"That code is for a computer on {backend.Host}, and this phone is on {UserName}. To switch, leave " +
                      "this server (Account → Leave this server), then scan the code again."
                    : $"Sign out before switching to {backend.Host}.");
            }
            else if (computer != null)
            {
                var held = ComputerKey(computer.Desktop);
                var problem = held == null || held == computer.Key ? null : await CodeWorks(backend, secret).ConfigureAwait(false);
                if (problem != null)
                {
                    Notice(problem);
                    return;
                }
                await AddComputerKey(computer).ConfigureAwait(false);
            }
            else if (phone && Backend.ComputerKey(uri) != null)
            {
                Notice("To connect to a computer, scan its code with PocketTerm's scanner.");
            }
            NotifyChanged();
            return;
        }
        if (secret == null)
        {
            AuthError = phone
                ? "That link has no sign-in code. On your computer, open PocketTerm: Settings → Phone → Add a phone…"
                : "That link has no setup token. On your server, run `pocketterm-server setup-link` and open the link " +
                  "it prints.";
            NotifyChanged();
            return;
        }
        if (backend != _backend)
        {
            var problem = await backend.Check().ConfigureAwait(false);
            if (problem != null)
            {
                AuthError = problem;
                NotifyChanged();
                return;
            }
            await Connect(backend).ConfigureAwait(false);
        }
        AuthError = null;
        RetryLink = null;
        NotifyChanged();
        try
        {
            var s = Server!;
            var account = phone
                ? await s.RedeemCode(secret, Device, Platform).ConfigureAwait(false)
                : await s.RedeemSetup(secret, Device, Platform).ConfigureAwait(false);
            // Before the sign-in lands, so the computer shows unlocked at once.
            if (computer != null) await AddComputerKey(computer).ConfigureAwait(false);
            SetUser(account);
            return;
        }
        catch (ServerException e)
        {
            AuthError = e.Code switch
            {
                "invalid_code" when phone => CodeUsed,
                "invalid_code" =>
                    "That setup link doesn't work: the server has a newer one. Run `pocketterm-server setup-link` on the " +
                    "server and open the link it prints.",
                _ => e.Message,
            };
        }
        catch (SecureStoreException)
        {
            AuthError = KeychainProblem;
            RetryLink = link;
        }
        catch (Exception e)
        {
            AuthError = $"Sign-in failed: {e.Message}";
        }
        NotifyChanged();
    }

    /// <summary>Whether pairing <paramref name="code"/> works on <paramref name="backend"/>: it's redeemed by a
    /// sign-in of its own that leaves at once. Null when it did, else why not.</summary>
    private async Task<string?> CodeWorks(Backend backend, string? code)
    {
        if (code == null) return CodeUsed;
        var probe = Client(backend, new MemoryDeviceTokens());
        try
        {
            await probe.RedeemCode(code, Device, Platform).ConfigureAwait(false);
            await probe.Leave().ConfigureAwait(false);
            return null;
        }
        catch (ServerException e)
        {
            return e.Code == "invalid_code" ? CodeUsed : e.Message;
        }
        finally
        {
            probe.Close();
        }
    }

    /// <summary>A client for <paramref name="backend"/> keeping its sign-in in <paramref name="tokens"/>.</summary>
    protected virtual IServer Client(Backend backend, IDeviceTokens tokens) => global::PocketTerm.Core.Server.Create(backend, tokens);

    /// <summary>A computer's key from a scanned setup link: the phone keeps it, over any it held for that computer.</summary>
    protected virtual Task AddComputerKey(ComputerKey computer) => Task.CompletedTask;

    /// <summary>This computer and its key, for the setup link a phone scans; null where there's none (a phone).</summary>
    protected virtual Task<ComputerKey?> PairingComputer() => Task.FromResult<ComputerKey?>(null);

    /// <summary>A setup link that signs a phone in (POST /v1/pair) and carries this computer's key
    /// (<see cref="PairingComputer"/>): the code works once, for 10 minutes; the key until reset. Only while signed
    /// in. Fails with a <see cref="PairingException"/> that says why.</summary>
    public virtual async Task<string> PairingLink()
    {
        string code;
        try
        {
            code = await Server!.CreatePairingCode().ConfigureAwait(false);
        }
        catch (ServerException e)
        {
            throw new PairingException(e.Message);
        }
        return _backend!.LinkWithCode(code, await PairingComputer().ConfigureAwait(false));
    }

    /// <summary>Opens <paramref name="backend"/> (and remembers it): the one saved at launch, the setup screen's, or
    /// a setup link's, with the sign-in this device kept for it. With <see cref="SignInAtOnce"/> that's signed in
    /// before the server says it still holds; otherwise once it did (or didn't answer). A refusal signs out, with
    /// the reason. Switching needs the user signed out.</summary>
    public async Task Connect(Backend backend)
    {
        if (_user != null) throw new InvalidOperationException("Sign out before switching servers.");
        CloseServer();
        var s = _server = Client(backend, DeviceTokens);
        backend.Save(Preferences);
        _saved = backend;
        _backend = backend;
        AuthError = null;
        NotifyChanged();
        await s.Load().ConfigureAwait(false);
        s.Ended += OnEnded;
        var check = s.Recheck();
        if (!SignInAtOnce) await check.ConfigureAwait(false);
        SetUser(s.Account);
        Log.Timing("signed in");
    }

    private void OnEnded(object? sender, EventArgs e)
    {
        if (!ReferenceEquals(sender, _server)) return;
        _leaving ??= EndedReason;
        SetUser(null);
    }

    /// <summary>A launch shows the sign-in kept here at once and asks the server about it meanwhile: a phone, which
    /// then shows what it had without waiting on the network. A computer asks first: one running the server signs
    /// in to it anew when it refused the kept one.</summary>
    protected virtual bool SignInAtOnce => false;

    /// <summary>Why the sign-in is gone when the server stopped taking it (this device was removed, the server
    /// erased), worded for the person.</summary>
    protected virtual string EndedReason => Role == DeviceRole.Phone
        ? "Your sign-in ended on the server. Scan a new code from PocketTerm on your computer."
        : "Your sign-in ended on the server. Open your server's setup link to sign in again.";

    /// <summary>Signs out and forgets the server: the setup screen shows again.</summary>
    public virtual async Task Disconnect()
    {
        if (_user != null) await SignOut().ConfigureAwait(false);
        CloseServer();
        Backend.Clear(Preferences);
        _saved = null;
        _backend = null;
        AuthError = null;
        NotifyChanged();
    }

    private void CloseServer()
    {
        if (_server == null) return;
        _server.Ended -= OnEnded;
        _server.Close();
        _server = null;
    }

    /// <summary>Runs once a user is signed in (sign-in, or launch while signed in).</summary>
    protected virtual Task OnSignedIn(Account user) => Task.CompletedTask;

    /// <summary>Runs before signing out, while the token still works on the server.</summary>
    protected virtual Task OnSigningOut() => Task.CompletedTask;

    /// <summary>Runs once the sign-in is gone, however that happened (signed out here, the server ended it).</summary>
    protected virtual Task OnSignedOut() => Task.CompletedTask;

    /// <summary><see cref="Connect"/>'s restore and the server's answers both report the sign-in: only a change of
    /// device runs <see cref="OnSignedIn"/> or <see cref="OnSignedOut"/>.</summary>
    private void SetUser(Account? user)
    {
        var reason = _signedOutReason;
        if (user != null)
        {
            _signedOutReason = _leaving = null;
            _linkToConfirm = null;
        }
        else if (_user != null || _leaving != null)
        {
            _signedOutReason = _leaving ?? EndedReason;
            _leaving = null;
        }
        if (user?.Device.Id == _user?.Device.Id)
        {
            _user = user ?? _user;
            if (_signedOutReason != reason) NotifyChanged();
            return;
        }
        _user = user;
        _ = Hook(user != null ? OnSignedIn(user) : OnSignedOut());
        NotifyChanged();
    }

    private static async Task Hook(Task hook)
    {
        try
        {
            await hook.ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: {e.Message}");
        }
    }

    /// <summary>Signs out: this device leaves the server (its token stops working there, DELETE /v1/devices/me)
    /// and forgets it here, also when <see cref="OnSigningOut"/> or the server fails (offline).</summary>
    public virtual async Task SignOut()
    {
        _leaving ??= "You signed out.";
        try
        {
            await OnSigningOut().ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: sign-out cleanup failed: {e.Message}");
        }
        try
        {
            if (Server is { } s) await s.Leave().ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: the server missed the sign-out: {e.Message}");
        }
        ForgetError();
        SetUser(null);
    }

    /// <summary>A sign-in that went before leaves no problem behind for the next one.</summary>
    private void ForgetError()
    {
        AuthError = null;
        RetryLink = null;
    }

    /// <summary>This computer runs the server it's connected to (the one built into the app): only then may it
    /// erase it (<see cref="EraseServer"/>).</summary>
    public virtual bool HostsServer => false;

    /// <summary>Erases everything on the server (<see cref="HostsServer"/> only): every computer and phone is signed
    /// out, the images and push registrations go.</summary>
    public virtual async Task EraseServer()
    {
        if (!HostsServer) throw new InvalidOperationException("Only the computer running the server erases it.");
        try
        {
            await OnSigningOut().ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: sign-out cleanup failed: {e.Message}");
        }
        await Server!.Erase().ConfigureAwait(false);
        _leaving = "This server's data was erased.";
        ForgetError();
        SetUser(null);
    }

    /// <summary>What this device's sign-in is called on screen: its server.</summary>
    public string UserName => _backend?.Host ?? "you";

    public virtual void Dispose()
    {
        if (_server != null) _server.Ended -= OnEnded;
        GC.SuppressFinalize(this);
    }
}
