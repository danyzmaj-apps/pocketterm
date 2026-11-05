using System.Security.Cryptography;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>Which screen of the Supabase branch shows.</summary>
public enum SupabaseStage
{
    /// <summary>Paste a setup link, or set a project up.</summary>
    Choose,

    /// <summary>A computer already on a project made a setup link: paste it.</summary>
    Paste,

    /// <summary>What Supabase holds and what the token covers; the token.</summary>
    Token,

    /// <summary>The organization, then a new project's region or the project PocketTerm is on already.</summary>
    Project,

    /// <summary><see cref="SupabaseSetup.RunAsync"/> step by step.</summary>
    Progress,
}

/// <summary>Where one setup step stands on the progress screen.</summary>
public enum SupabaseStepState
{
    /// <summary>Not yet.</summary>
    Later,

    /// <summary>Running.</summary>
    Looking,

    /// <summary>Failed: Retry picks up here.</summary>
    Now,

    /// <summary>Done.</summary>
    Done,
}

/// <summary>
/// The first-run setup's Supabase branch without its widgets: paste the setup link of a computer already on a
/// project, or set a project up. Setting up asks for a personal access token, then a project (a new one in the
/// picked organization and region, or the one PocketTerm is already on there), then runs
/// <see cref="SupabaseSetup"/> step by step and signs this computer in with the link it makes. The token lives only
/// in this object (and its <see cref="SupabaseAdmin"/>) until <see cref="Drop"/>.
/// <para>
/// Threading: the page calls it from the UI thread; work under way that no longer counts (Back, a new token) is
/// told apart by a run number, so a late answer changes nothing. State is guarded by one lock; changes raise
/// <see cref="ObservableObject.PropertyChanged"/> on whatever thread made them.
/// </para>
/// </summary>
public sealed class SupabaseFlow : ObservableObject, IDisposable
{
    /// <summary>Where the person makes an access token.</summary>
    public const string TokensPage = "https://supabase.com/dashboard/account/tokens";

    /// <summary>The regions a new project can go to, nearest-sounding names for people, in the order the setup lists them.</summary>
    public static IReadOnlyList<KeyValuePair<string, string>> Regions { get; } =
    [
        new("us-east-1", "US East (N. Virginia)"),
        new("us-west-1", "US West (N. California)"),
        new("ca-central-1", "Canada (Central)"),
        new("sa-east-1", "South America (São Paulo)"),
        new("eu-central-1", "Europe (Frankfurt)"),
        new("eu-west-2", "Europe (London)"),
        new("ap-south-1", "Asia Pacific (Mumbai)"),
        new("ap-southeast-1", "Asia Pacific (Singapore)"),
        new("ap-northeast-1", "Asia Pacific (Tokyo)"),
    ];

    /// <summary>What the progress screen says while <see cref="Waiting"/>.</summary>
    public const string WaitNotice = "Supabase lets a project change its signing key only every few minutes. Waiting…";

    /// <summary>Why the setup failed when the sign-in gave no reason (the controller's auth error comes first).</summary>
    public const string NotSignedIn = "The setup link didn’t sign this computer in.";

    private readonly object _gate = new();
    private readonly Func<string, Task<string?>> _signIn;
    private readonly Func<string, SupabaseAdmin> _admin;
    private readonly Func<SupabaseAdmin, string, SupabaseSetup> _setup;
    private readonly HashSet<SupabaseStep> _done = [];
    private SupabaseAdmin? _adminNow;

    /// <summary>Bumped whenever the work under way no longer counts (Back, a new token).</summary>
    private int _run;
    private SupabaseStage _stage = SupabaseStage.Choose;
    private bool _busy;
    private string? _error;
    private IReadOnlyList<SupabaseOrg>? _orgs;
    private string? _org;
    private string _region = "eu-central-1";
    private SupabaseProject? _existing;
    private string? _ref;
    private SupabaseStep? _current;
    private bool _waiting;

    /// <param name="signIn">
    /// Signs this computer in with the setup link the setup made (the controller's <c>ConnectLinkAsync</c>): null
    /// once signed in, else why not (it disconnects again itself).
    /// </param>
    /// <param name="admin">The Management API with a token (tests: over a fake).</param>
    /// <param name="setup">The setup of one project (tests: waiting for nothing).</param>
    public SupabaseFlow(
        Func<string, Task<string?>> signIn,
        Func<string, SupabaseAdmin>? admin = null,
        Func<SupabaseAdmin, string, SupabaseSetup>? setup = null)
    {
        _signIn = signIn;
        _admin = admin ?? (token => new SupabaseAdmin(token));
        _setup = setup ?? ((a, r) => new SupabaseSetup(a, r));
    }

    public SupabaseStage Stage
    {
        get
        {
            lock (_gate) return _stage;
        }
    }

    /// <summary>Supabase is being asked something: the buttons wait.</summary>
    public bool Busy
    {
        get
        {
            lock (_gate) return _busy;
        }
    }

    /// <summary>What went wrong, for the person.</summary>
    public string? Error
    {
        get
        {
            lock (_gate) return _error;
        }
    }

    /// <summary>The token's organizations, once read.</summary>
    public IReadOnlyList<SupabaseOrg>? Orgs
    {
        get
        {
            lock (_gate) return _orgs;
        }
    }

    /// <summary>The picked organization's slug.</summary>
    public string? Org
    {
        get
        {
            lock (_gate) return _org;
        }
    }

    /// <summary>A new project's region (<see cref="Regions"/>); Frankfurt until picked.</summary>
    public string Region
    {
        get
        {
            lock (_gate) return _region;
        }
        set
        {
            lock (_gate) _region = value;
            NotifyChanged();
        }
    }

    /// <summary>The project PocketTerm is on already in <see cref="Org"/>, if any: Update that project instead of Create.</summary>
    public SupabaseProject? Existing
    {
        get
        {
            lock (_gate) return _existing;
        }
    }

    /// <summary>Create the project: once an organization is picked.</summary>
    public bool CanCreate => Org != null;

    /// <summary>Supabase makes the signing key wait (<see cref="WaitNotice"/>).</summary>
    public bool Waiting
    {
        get
        {
            lock (_gate) return _waiting;
        }
    }

    /// <summary>The project being set up.</summary>
    public string? Ref
    {
        get
        {
            lock (_gate) return _ref;
        }
    }

    /// <summary>An organization as the picker lists it: <c>Work (pro plan)</c>.</summary>
    public static string OrgLabel(SupabaseOrg org) => org.Plan.Length == 0 ? org.Name : $"{org.Name} ({org.Plan} plan)";

    /// <summary>Where <paramref name="step"/> stands on the progress screen.</summary>
    public SupabaseStepState StepState(SupabaseStep step)
    {
        lock (_gate)
        {
            if (_done.Contains(step)) return SupabaseStepState.Done;
            if (step == _current) return _error == null ? SupabaseStepState.Looking : SupabaseStepState.Now;
            return SupabaseStepState.Later;
        }
    }

    /// <summary>One of the first screen's options: <see cref="SupabaseStage.Paste"/> or <see cref="SupabaseStage.Token"/>.</summary>
    public void Show(SupabaseStage stage)
    {
        lock (_gate) _stage = stage;
        NotifyChanged();
    }

    /// <summary>Back: to the first screen, forgetting the token and the work done with it; false on the first screen (the setup's own Back).</summary>
    public bool Back()
    {
        lock (_gate)
        {
            if (_stage == SupabaseStage.Choose) return false;
        }
        Drop();
        lock (_gate) _stage = SupabaseStage.Choose;
        NotifyChanged();
        return true;
    }

    /// <summary>Forgets the token and the work done with it.</summary>
    public void Drop()
    {
        SupabaseAdmin? admin;
        lock (_gate)
        {
            _run++;
            admin = _adminNow;
            _adminNow = null;
            _busy = false;
            _error = null;
            _orgs = null;
            _org = null;
            _existing = null;
            _ref = null;
            _done.Clear();
            _current = null;
            _waiting = false;
        }
        admin?.Dispose();
        NotifyChanged();
    }

    public void Dispose() => Drop();

    private static string Why(Exception e) => e is AdminException a ? a.Message : $"Something went wrong: {e.Message}";

    /// <summary>Update this object's state under the lock, then say so; nothing when run <paramref name="run"/> no longer counts.</summary>
    private bool Set(int run, Action change)
    {
        lock (_gate)
        {
            if (run != _run) return false;
            change();
        }
        NotifyChanged();
        return true;
    }

    /// <summary>Continue on the token screen: the token's organizations, and the one picked when it's the only one.</summary>
    public async Task ContinueAsync(string typed)
    {
        var token = typed.DartTrim();
        if (!token.StartsWith("sbp_", StringComparison.Ordinal))
        {
            lock (_gate) _error = "That isn’t a Supabase access token. It starts with sbp_.";
            NotifyChanged();
            return;
        }
        int run;
        SupabaseAdmin? old;
        var admin = _admin(token);
        lock (_gate)
        {
            run = ++_run;
            old = _adminNow;
            _adminNow = admin;
            _busy = true;
            _error = null;
        }
        old?.Dispose();
        NotifyChanged();
        try
        {
            var orgs = await admin.OrganizationsAsync().ConfigureAwait(false);
            if (orgs.Count == 0) throw new AdminException("This Supabase account has no organization. Create one first.");
            if (!Set(run, () =>
                {
                    _orgs = orgs;
                    _stage = SupabaseStage.Project;
                    _busy = false;
                }))
            {
                return;
            }
            if (orgs.Count == 1) await PickOrgAsync(orgs[0].Slug).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Set(run, () =>
            {
                _busy = false;
                _error = Why(e);
            });
        }
    }

    /// <summary>
    /// Picks <paramref name="slug"/> and looks for a project PocketTerm is on there already (best effort: one that
    /// can't be asked counts as not).
    /// </summary>
    public async Task PickOrgAsync(string slug)
    {
        int run;
        SupabaseAdmin admin;
        lock (_gate)
        {
            run = ++_run;
            admin = _adminNow ?? throw new InvalidOperationException("No access token yet.");
            _org = slug;
            _existing = null;
            _busy = true;
            _error = null;
        }
        NotifyChanged();
        SupabaseProject? found = null;
        try
        {
            foreach (var p in await admin.ProjectsAsync().ConfigureAwait(false))
            {
                if (p.Org != slug || p.Status != "ACTIVE_HEALTHY") continue;
                try
                {
                    if (await _setup(admin, p.Ref).HasPocketTermAsync().ConfigureAwait(false))
                    {
                        found = p;
                        break;
                    }
                }
                catch (Exception e)
                {
                    Log.Print($"PocketTerm: looking at Supabase project {p.Ref} failed: {e.Message}");
                }
            }
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: listing Supabase projects failed: {e.Message}");
        }
        Set(run, () =>
        {
            _existing = found;
            _busy = false;
        });
    }

    /// <summary>32 random letters and digits: the new project's database password, which PocketTerm never needs again.</summary>
    public static string NewDatabasePassword() =>
        RandomNumberGenerator.GetString("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", 32);

    /// <summary>Create the project: a new project <c>PocketTerm</c> in <see cref="Org"/> and <see cref="Region"/>, then the setup on it.</summary>
    public async Task CreateAsync()
    {
        int run;
        SupabaseAdmin admin;
        string org, region;
        lock (_gate)
        {
            run = ++_run;
            admin = _adminNow ?? throw new InvalidOperationException("No access token yet.");
            org = _org ?? throw new InvalidOperationException("No organization picked.");
            region = _region;
            _busy = true;
            _error = null;
        }
        NotifyChanged();
        try
        {
            var project = await admin.CreateProjectAsync(org, "PocketTerm", region, NewDatabasePassword()).ConfigureAwait(false);
            lock (_gate)
            {
                if (run != _run) return;
                _ref = project.Ref;
            }
            await SetUpAsync().ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Set(run, () =>
            {
                _busy = false;
                _error = Why(e);
            });
        }
    }

    /// <summary>Update that project: the setup on <see cref="Existing"/>.</summary>
    public Task UpdateAsync()
    {
        lock (_gate) _ref = (_existing ?? throw new InvalidOperationException("No project to update.")).Ref;
        return SetUpAsync();
    }

    /// <summary>Runs the setup on <see cref="Ref"/> from where it stopped, then signs in (Retry calls it again).</summary>
    public async Task SetUpAsync()
    {
        int run;
        SupabaseAdmin admin;
        string @ref;
        HashSet<SupabaseStep> done;
        lock (_gate)
        {
            run = ++_run;
            admin = _adminNow ?? throw new InvalidOperationException("No access token yet.");
            @ref = _ref ?? throw new InvalidOperationException("No project picked.");
            _stage = SupabaseStage.Progress;
            _busy = true;
            _error = null;
            _waiting = false;
            // The step that failed runs again; it isn't done.
            _current = null;
            done = [.. _done];
        }
        NotifyChanged();
        try
        {
            var link = await _setup(admin, @ref).RunAsync(
                done: done,
                onStep: step => Set(run, () =>
                {
                    if (_current is { } c) _done.Add(c);
                    _current = step;
                    _waiting = false;
                }),
                onWait: () => Set(run, () => _waiting = true)).ConfigureAwait(false);
            lock (_gate)
            {
                if (run != _run) return;
            }
            var why = await _signIn(link).ConfigureAwait(false);
            // Signed in: the window moves on; the token and the admin go now.
            if (why == null)
            {
                Drop();
                return;
            }
            throw new AdminException(why);
        }
        catch (Exception e)
        {
            Set(run, () =>
            {
                _busy = false;
                _waiting = false;
                _error = Why(e);
            });
        }
    }
}
