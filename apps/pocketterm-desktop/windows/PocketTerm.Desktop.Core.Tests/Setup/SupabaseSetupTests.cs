using System.Net;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PocketTerm.Core;
using PocketTerm.Core.Tests;

namespace PocketTerm.Desktop.Tests;

/// <summary>
/// The Management API of one Supabase account, in memory: two organizations, projects as created, SQL answered by
/// what it asks.
/// </summary>
internal sealed class FakeSupabase : HttpMessageHandler
{
    private readonly object _gate = new();
    private readonly List<string> _requests = [];
    private int _keyTries;

    /// <summary>The bodies of POST /v1/projects.</summary>
    public List<JsonObject> Created { get; } = [];

    public List<JsonObject> Projects { get; } =
    [
        new() { ["id"] = "hopjarref0000000", ["name"] = "hopjar", ["status"] = "ACTIVE_HEALTHY", ["organization_id"] = "org-work" },
    ];

    /// <summary>Projects PocketTerm is on already.</summary>
    public HashSet<string> Ours { get; } = [];

    /// <summary>Migrations the project has had.</summary>
    public HashSet<string> Applied { get; } = [];

    /// <summary>The Edge Functions' secrets the project has.</summary>
    public HashSet<string> Secrets { get; } = [];

    /// <summary>The project's signing keys (<c>id</c>, <c>status</c>).</summary>
    public JsonArray SigningKeys { get; } = [];

    /// <summary>Times Realtime's and Storage's tables aren't there yet.</summary>
    public int NotReady { get; set; }

    /// <summary>Every SQL run, in order.</summary>
    public List<string> Sql { get; } = [];

    /// <summary>What the next deploy answers with, once: a status and a message.</summary>
    public (int Status, string Message)? DeployFails { get; set; }

    /// <summary>Times the signing key is refused before it's taken (Supabase's wait).</summary>
    public int KeyRefusals { get; set; }

    /// <summary>While set, a refused signing key waits for it before the next try.</summary>
    public TaskCompletionSource? KeyGate { get; set; }

    /// <summary>While true, POST /v1/projects is refused for the free plan's limit.</summary>
    public bool AtLimit { get; set; }

    public List<string> Requests
    {
        get
        {
            lock (_gate) return [.. _requests];
        }
    }

    /// <summary>How many <see cref="Requests"/> were <paramref name="request"/> (<c>METHOD /path</c>).</summary>
    public int Count(string request) => Requests.Count(r => r == request);

    private static HttpResponseMessage Json(JsonNode? body, int status = 200) =>
        new((HttpStatusCode)status) { Content = new StringContent(DartJson.Encode(body), Encoding.UTF8, "application/json") };

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken cancellationToken)
    {
        var path = req.RequestUri!.AbsolutePath;
        var method = req.Method.Method;
        lock (_gate) _requests.Add($"{method} {path}");
        var body = req.Content == null ? "" : await req.Content.ReadAsStringAsync(cancellationToken);
        var parts = path.Split('/');
        switch ((method, path))
        {
            case ("GET", "/v1/organizations"):
                return Json(new JsonArray(
                    new JsonObject { ["slug"] = "org-mine", ["name"] = "Mine", ["plan"] = "free" },
                    new JsonObject { ["slug"] = "org-work", ["name"] = "Work", ["plan"] = "pro" }));
            case ("GET", "/v1/projects"):
                return Json(new JsonArray(Projects.Select(p => (JsonNode)p.DeepClone()).ToArray()));
            case ("POST", "/v1/projects") when AtLimit:
                return Json(new JsonObject { ["message"] = "The maximum limit of 2 free projects has been reached" }, 400);
            case ("POST", "/v1/projects"):
            {
                var created = (JsonObject)DartJson.Decode(body)!;
                Created.Add(created);
                var p = new JsonObject
                {
                    ["id"] = "newproject000000",
                    ["name"] = created["name"]!.DeepClone(),
                    ["status"] = "COMING_UP",
                    ["organization_id"] = created["organization_slug"]!.DeepClone(),
                };
                Projects.Add(p);
                return Json(p.DeepClone(), 201);
            }
        }
        if (parts.Length >= 4 && parts[2] == "projects")
        {
            var @ref = parts[3];
            var rest = string.Join('/', parts.Skip(4));
            var project = Projects.First(p => p.Str("id") == @ref);
            switch ((method, rest))
            {
                case ("GET", ""):
                    project["status"] = "ACTIVE_HEALTHY";
                    return Json(project.DeepClone());
                case ("POST", "database/query"):
                {
                    var sql = ((JsonObject)DartJson.Decode(body)!).Str("query")!;
                    lock (_gate) Sql.Add(sql);
                    if (sql.Contains("to_regnamespace")) return Json(new JsonArray(new JsonObject { ["ours"] = Ours.Contains(@ref) }));
                    if (sql.Contains("to_regclass('realtime.messages')")) return Json(new JsonArray(new JsonObject { ["ready"] = NotReady-- <= 0 }));
                    if (sql.Contains("select version from")) return Json(new JsonArray(Applied.Select(v => (JsonNode)new JsonObject { ["version"] = v }).ToArray()));
                    return Json(new JsonArray());
                }
                case ("GET", "secrets"):
                    return Json(new JsonArray(Secrets.Select(s => (JsonNode)new JsonObject { ["name"] = s }).ToArray()));
                case ("POST", "secrets"):
                    foreach (var s in ((JsonArray)DartJson.Decode(body)!).OfType<JsonObject>()) Secrets.Add(s.Str("name")!);
                    return Json(new JsonObject());
                case ("GET", "config/auth/signing-keys"):
                    return Json(new JsonObject { ["keys"] = SigningKeys.DeepClone() });
                case ("POST", "config/auth/signing-keys"):
                    return Json(new JsonObject { ["id"] = "key-1" }, 201);
                case ("PATCH", "config/auth/signing-keys/key-1"):
                    if (_keyTries++ < KeyRefusals)
                    {
                        if (_keyTries > 1 && KeyGate is { } gate) await gate.Task;
                        return Json(new JsonObject { ["message"] = "Wait before rotating again" }, 400);
                    }
                    return Json(new JsonObject());
                case ("PATCH", _) when rest.StartsWith("config/auth/signing-keys/", StringComparison.Ordinal):
                    return Json(new JsonObject());
                case ("GET", "api-keys"):
                    return Json(new JsonArray(new JsonObject { ["type"] = "publishable", ["api_key"] = "sb_publishable_test" }));
                case ("PATCH", "config/realtime"):
                    return Json(new JsonObject());
                case ("POST", "functions/deploy"):
                    if (DeployFails is { } fails)
                    {
                        DeployFails = null;
                        return Json(new JsonObject { ["message"] = fails.Message }, fails.Status);
                    }
                    return Json(new JsonObject { ["id"] = "fn" }, 201);
            }
        }
        return Json(new JsonObject { ["message"] = "Not found" }, 404);
    }
}

/// <summary>One migration and a function, as the bundled supabase/ folder would have them.</summary>
file sealed class TestSource : ISupabaseSource
{
    public Task<IReadOnlyList<Migration>> MigrationsAsync() =>
        Task.FromResult<IReadOnlyList<Migration>>([new Migration("20261023000000", "pocketterm", "select 1")]);

    public Task<string> FunctionAsync() => Task.FromResult("Deno.serve(() => new Response(\"ok\"));");
}

/// <summary>Answers every request with <paramref name="status"/> and <paramref name="body"/>.</summary>
file sealed class Answer(int status, string body) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
        Task.FromResult(new HttpResponseMessage((HttpStatusCode)status) { Content = new StringContent(body) });
}

public class SupabaseSetupTests
{
    private readonly FakeSupabase _fake = new();

    /// <summary>The links the setup signed in with.</summary>
    private readonly List<string> _links = [];

    /// <summary>The tokens the flow made an admin with.</summary>
    private readonly List<string> _tokens = [];

    private SupabaseSetup Setup(SupabaseAdmin admin, string @ref) => new(
        admin,
        @ref,
        new TestSource(),
        poll: TimeSpan.Zero,
        wakeRealtime: _ => Task.CompletedTask,
        health: _ => Task.FromResult<string?>(null));

    /// <summary>The Supabase branch over the fake, waiting for nothing; <paramref name="refuse"/>: why the sign-in fails.</summary>
    private SupabaseFlow Flow(string? refuse = null) => new(
        link =>
        {
            _links.Add(link);
            return Task.FromResult(refuse);
        },
        token =>
        {
            _tokens.Add(token);
            return new SupabaseAdmin(token, _fake);
        },
        Setup);

    private static string SupabaseDir([CallerFilePath] string here = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(here)!, "..", "..", "..", "supabase"));

    [Fact]
    public async Task NotATokenAsksSupabaseNothing()
    {
        var flow = Flow();
        flow.Show(SupabaseStage.Token);
        await flow.ContinueAsync("hello");
        Assert.Contains("It starts with sbp_", flow.Error);
        Assert.Empty(_tokens);
        Assert.Empty(_fake.Requests);
        Assert.Equal(SupabaseStage.Token, flow.Stage);
    }

    [Fact]
    public async Task ANewProjectInThePickedOrganizationAndRegionSetUpStepByStepSignsThisComputerIn()
    {
        _fake.KeyRefusals = 2;
        _fake.KeyGate = new TaskCompletionSource();
        var flow = Flow();
        flow.Show(SupabaseStage.Token);
        await flow.ContinueAsync(" sbp_secret ");
        Assert.Equal(["sbp_secret"], _tokens);
        Assert.Equal(SupabaseStage.Project, flow.Stage);
        // Two organizations: none picked for the person, and nothing to create in yet.
        Assert.Equal(["Mine (free plan)", "Work (pro plan)"], flow.Orgs!.Select(SupabaseFlow.OrgLabel));
        Assert.False(flow.CanCreate);

        await flow.PickOrgAsync("org-work");
        Assert.Equal(1, _fake.Count("GET /v1/projects"));
        // Another project there isn't PocketTerm's: it's only asked about, never offered.
        Assert.Null(flow.Existing);
        Assert.True(flow.CanCreate);
        flow.Region = "eu-west-2";
        var create = flow.CreateAsync();

        // Supabase makes the signing key wait: the flow says so.
        await Wait.Until(() => flow.Waiting);
        Assert.Equal(SupabaseStage.Progress, flow.Stage);
        Assert.Equal(SupabaseStepState.Done, flow.StepState(SupabaseStep.Database));
        Assert.Equal(SupabaseStepState.Looking, flow.StepState(SupabaseStep.LiveChannel));
        Assert.Equal(SupabaseStepState.Later, flow.StepState(SupabaseStep.Function));
        _fake.KeyGate.SetResult();
        await create;

        var created = Assert.Single(_fake.Created);
        Assert.Equal("org-work", created.Str("organization_slug"));
        Assert.Equal("PocketTerm", created.Str("name"));
        Assert.Equal(32, created.Str("db_pass")!.Length);
        Assert.Equal("{\"type\":\"specific\",\"code\":\"eu-west-2\"}", DartJson.Encode(created["region_selection"]));
        var link = Assert.Single(_links);
        Assert.Equal(new Backend("https://newproject000000.supabase.co", BackendKind.Supabase), Backend.FromLink(link));
        Assert.NotNull(Backend.SetupToken(DartUri.Parse(link)));
        Assert.Equal(1, _fake.Count("POST /v1/projects/newproject000000/functions/deploy"));
        Assert.Null(flow.Error);
        // Signed in: the token and the work done with it go.
        Assert.Null(flow.Orgs);
        Assert.Null(flow.Ref);
    }

    [Fact]
    public async Task ASupabaseErrorShowsItsMessageAndRetryPicksUpAtTheStepThatFailed()
    {
        _fake.DeployFails = (500, "Bundling the function failed.");
        var flow = Flow();
        await flow.ContinueAsync("sbp_secret");
        await flow.PickOrgAsync("org-mine");
        await flow.CreateAsync();
        Assert.Equal("Bundling the function failed.", flow.Error);
        Assert.Equal(SupabaseStepState.Done, flow.StepState(SupabaseStep.LiveChannel));
        Assert.Equal(SupabaseStepState.Now, flow.StepState(SupabaseStep.Function));
        Assert.Empty(_links);

        await flow.SetUpAsync();
        Assert.Single(_links);
        // Nothing done before runs again: one project, one signing key.
        Assert.Equal(1, _fake.Count("POST /v1/projects"));
        Assert.Equal(1, _fake.Count("POST /v1/projects/newproject000000/config/auth/signing-keys"));
        Assert.Equal(2, _fake.Count("POST /v1/projects/newproject000000/functions/deploy"));
        Assert.True(Backend.FromLink(_links[0])!.IsSupabase);
    }

    [Fact]
    public async Task AProjectSupabaseWontCreateSaysWhyAndCreateWorksOnceItWould()
    {
        _fake.AtLimit = true;
        var flow = Flow();
        await flow.ContinueAsync("sbp_secret");
        await flow.PickOrgAsync("org-mine");
        await flow.CreateAsync();
        Assert.Contains("already has the two active projects the free plan allows", flow.Error);
        Assert.Equal(SupabaseStage.Project, flow.Stage);

        _fake.AtLimit = false;
        await flow.CreateAsync();
        Assert.Single(_links);
        Assert.Single(_fake.Created);
    }

    [Fact]
    public async Task AnOrganizationPocketTermIsOnAlreadyOffersToUpdateThatProjectNotToMakeAnother()
    {
        _fake.Projects.Add(new JsonObject
        {
            ["id"] = "oldpocketterm000",
            ["name"] = "PocketTerm",
            ["status"] = "ACTIVE_HEALTHY",
            ["organization_id"] = "org-mine",
        });
        _fake.Ours.Add("oldpocketterm000");
        var flow = Flow();
        await flow.ContinueAsync("sbp_secret");
        await flow.PickOrgAsync("org-mine");
        Assert.Equal("oldpocketterm000", flow.Existing?.Ref);
        await flow.UpdateAsync();
        Assert.Empty(_fake.Created);
        Assert.Equal("https://oldpocketterm000.supabase.co", Backend.FromLink(Assert.Single(_links))!.Url);
    }

    [Fact]
    public async Task ASignInThatFailsSaysWhyAndKeepsTheProjectForRetry()
    {
        var flow = Flow(refuse: "Windows couldn’t keep the sign-in.");
        await flow.ContinueAsync("sbp_secret");
        await flow.PickOrgAsync("org-mine");
        await flow.CreateAsync();
        Assert.Equal("Windows couldn’t keep the sign-in.", flow.Error);
        Assert.Equal("newproject000000", flow.Ref);
        Assert.Equal(SupabaseStepState.Now, flow.StepState(SupabaseStep.SignIn));
    }

    [Fact]
    public async Task BackForgetsTheTokenAndTheWorkDoneWithIt()
    {
        var flow = Flow();
        Assert.False(flow.Back());
        flow.Show(SupabaseStage.Token);
        await flow.ContinueAsync("sbp_secret");
        Assert.NotNull(flow.Orgs);
        Assert.True(flow.Back());
        Assert.Equal(SupabaseStage.Choose, flow.Stage);
        Assert.Null(flow.Orgs);
        Assert.Null(flow.Org);
        // No token any more: nothing can be asked of Supabase with it.
        await Assert.ThrowsAsync<InvalidOperationException>(() => flow.PickOrgAsync("org-mine"));
    }

    [Fact]
    public async Task MigrationsAlreadyAppliedAreSkippedAndRealtimeIsWokenOnceWhileItsTablesAreMissing()
    {
        _fake.Applied.Add("20261023000000");
        _fake.NotReady = 2;
        var woken = 0;
        using var admin = new SupabaseAdmin("sbp_secret", _fake);
        var setup = new SupabaseSetup(admin, "hopjarref0000000", new FolderSupabaseSource(SupabaseDir()), poll: TimeSpan.Zero, wakeRealtime: _ =>
        {
            woken++;
            return Task.CompletedTask;
        });
        Assert.Equal(1, await setup.MigrateAsync());
        Assert.Equal(1, woken);
        var insert = Assert.Single(_fake.Sql, s => s.Contains("insert into supabase_migrations.schema_migrations"));
        Assert.Contains("values ('20261024000000', 'activity_refresh');\ncommit;", insert);
        Assert.StartsWith("begin;\n", insert);
    }

    [Fact]
    public async Task AProjectThatHasItsLiveChannelKeyKeepsItAndAStandbyKeyGoesBeforeANewOne()
    {
        using var admin = new SupabaseAdmin("sbp_secret", _fake);
        _fake.Secrets.Add("PT_REALTIME_JWK");
        await Setup(admin, "hopjarref0000000").LiveChannelAsync();
        Assert.Equal(0, _fake.Count("POST /v1/projects/hopjarref0000000/config/auth/signing-keys"));
        Assert.Contains("PT_PUBLISHABLE_KEY", _fake.Secrets);

        _fake.Secrets.Clear();
        _fake.SigningKeys.Add(new JsonObject { ["id"] = "made-by-supabase", ["status"] = "standby" });
        await Setup(admin, "hopjarref0000000").LiveChannelAsync();
        var requests = _fake.Requests;
        var retired = requests.IndexOf("PATCH /v1/projects/hopjarref0000000/config/auth/signing-keys/made-by-supabase");
        Assert.True(retired >= 0);
        Assert.True(retired < requests.IndexOf("POST /v1/projects/hopjarref0000000/config/auth/signing-keys"));
        Assert.Contains("PT_REALTIME_JWK", _fake.Secrets);
    }

    [Fact]
    public async Task SupabasesErrorsAreWordedForThePersonAndARateLimitIsntThePlansLimit()
    {
        async Task<AdminException> Fails(int status, string body)
        {
            using var admin = new SupabaseAdmin("sbp_x", new Answer(status, body));
            return await Assert.ThrowsAsync<AdminException>(() => admin.CreateProjectAsync("org", "PocketTerm", "eu-central-1", "pw"));
        }

        Assert.Equal("Supabase refused that access token. Create a new one and paste it again.", (await Fails(401, "{}")).Message);
        Assert.Equal("That access token isn't allowed to do this: Forbidden resource", (await Fails(403, "{\"message\":\"Forbidden resource\"}")).Message);
        Assert.Equal("That access token isn't allowed to do this", (await Fails(403, "")).Message);
        var limited = await Fails(429, "{\"message\":\"rate limit\"}");
        Assert.Equal("Supabase is rate-limiting requests. Wait a minute, then retry.", limited.Message);
        Assert.Equal(429, limited.Status);
        Assert.Equal("Supabase answered with an error (500).", (await Fails(500, "  ")).Message);
        Assert.Equal("upstream went away", (await Fails(502, "upstream went away\n")).Message);
    }

    [Fact]
    public async Task TheBundledFolderHasTheMigrationsOldestFirstAndTheFunction()
    {
        var source = new FolderSupabaseSource(SupabaseDir());
        var migrations = await source.MigrationsAsync();
        Assert.Equal(["20261023000000", "20261024000000"], migrations.Select(m => m.Version));
        Assert.Equal(["pocketterm", "activity_refresh"], migrations.Select(m => m.Name));
        Assert.Contains("pocketterm", await source.FunctionAsync());
        Assert.Equal(new Migration("20261023000000", "pocketterm", "x"), SupabaseSetup.MigrationFromFile(@"C:\PocketTerm\supabase\migrations\20261023000000_pocketterm.sql", "x"));
    }

    [Fact]
    public void ThePastedSetupLinkOfASupabaseProjectIsAComputersItsPhoneLinkAndUnknownKindsSayWhatToDo()
    {
        var project = new Backend("https://abcdefghijklmnop.supabase.co", BackendKind.Supabase);
        Assert.Null(SetupLinks.Problem(project.LinkWithSetup("s3cret")));
        Assert.Contains("Add a computer…", SetupLinks.Problem(project.LinkWithCode("K7QM-3XRT")));
        Assert.Contains("Update PocketTerm", SetupLinks.Problem("pocketterm://setup?kind=mars&url=https%3A%2F%2Fpt.example.com&setup=s3cret"));
        Assert.StartsWith("The server address in that link doesn’t work.", SetupLinks.Problem("pocketterm://setup?kind=supabase&url=nope&setup=s3cret"));
        // A PocketTerm server's link still works, and its phone link still names the server's command.
        Assert.Null(SetupLinks.Problem(new Backend("https://pt.example.com").LinkWithSetup("s3cret")));
        Assert.Contains("pocketterm-server setup-link", SetupLinks.Problem("pocketterm://setup?url=https%3A%2F%2Fpt.example.com&code=K7QM-3XRT"));
        Assert.StartsWith("That isn’t a setup link.", SetupLinks.Problem("https://pt.example.com"));
    }

    [Fact]
    public void TheLiveChannelKeyIsAP256KeyPairItsKidAUuid()
    {
        var jwk = SupabaseSetup.NewLiveSigningKey();
        Assert.Equal("EC", jwk.Str("kty"));
        Assert.Equal("P-256", jwk.Str("crv"));
        Assert.Equal("ES256", jwk.Str("alg"));
        byte[] Bytes(string name) => DartBase64.Decode(jwk.Str(name)!);
        var (x, y, d) = (Bytes("x"), Bytes("y"), Bytes("d"));
        Assert.Equal([32, 32, 32], new[] { x.Length, y.Length, d.Length });
        // x and y are d·G: what d signs, the public point verifies.
        using var signer = ECDsa.Create(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, D = d, Q = new ECPoint { X = x, Y = y } });
        using var verifier = ECDsa.Create(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, Q = new ECPoint { X = x, Y = y } });
        var data = "pocketterm"u8.ToArray();
        Assert.True(verifier.VerifyData(data, signer.SignData(data, HashAlgorithmName.SHA256), HashAlgorithmName.SHA256));
        Assert.Matches(new Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"), jwk.Str("kid")!);
        Assert.NotEqual(jwk.Str("kid"), SupabaseSetup.NewLiveSigningKey().Str("kid"));
        Assert.Equal(43, SupabaseSetup.NewSetupToken().Length);
    }
}
