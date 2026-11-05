using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>One migration: <c>supabase/migrations/&lt;version&gt;_&lt;name&gt;.sql</c>.</summary>
public sealed record Migration(string Version, string Name, string Sql);

/// <summary>
/// What PocketTerm puts on a Supabase project, shipped with the app (apps/pocketterm-desktop/supabase is bundled
/// next to it), so a downloaded app sets a project up without the repo or the Supabase CLI.
/// </summary>
public interface ISupabaseSource
{
    /// <summary>Oldest first.</summary>
    Task<IReadOnlyList<Migration>> MigrationsAsync();

    /// <summary>The Edge Function <c>pocketterm</c> (supabase/functions/pocketterm/index.ts).</summary>
    Task<string> FunctionAsync();
}

/// <summary>The bundled <c>supabase/</c> folder: next to the app by default (<see cref="AppContext.BaseDirectory"/>).</summary>
public sealed class FolderSupabaseSource(string? dir = null) : ISupabaseSource
{
    /// <summary>The folder: migrations/ and functions/pocketterm/index.ts.</summary>
    public string Dir { get; } = dir ?? Path.Combine(AppContext.BaseDirectory, "supabase");

    public async Task<IReadOnlyList<Migration>> MigrationsAsync()
    {
        var paths = Directory.GetFiles(Path.Combine(Dir, "migrations"), "*.sql").Order(StringComparer.Ordinal).ToList();
        var migrations = new List<Migration>();
        foreach (var p in paths) migrations.Add(SupabaseSetup.MigrationFromFile(p, await File.ReadAllTextAsync(p).ConfigureAwait(false)));
        return migrations;
    }

    public Task<string> FunctionAsync() => File.ReadAllTextAsync(Path.Combine(Dir, "functions", "pocketterm", "index.ts"));
}

/// <summary>The steps of <see cref="SupabaseSetup.RunAsync"/>, in order.</summary>
public enum SupabaseStep
{
    Project,
    Database,
    LiveChannel,
    Function,
    SignIn,
}

/// <summary>What the setup shows for each <see cref="SupabaseStep"/>.</summary>
public static class SupabaseSteps
{
    public static string Label(this SupabaseStep step) => step switch
    {
        SupabaseStep.Project => "Starting the project",
        SupabaseStep.Database => "Database",
        SupabaseStep.LiveChannel => "Live channel key",
        SupabaseStep.Function => "Server function",
        _ => "Signing this computer in",
    };
}

/// <summary>
/// Puts PocketTerm on a Supabase project (or updates it there): the migrations, the live channel's signing key,
/// the Edge Function, and a setup token for this computer. Every step can run again: applied migrations are
/// skipped, a project that has its live channel key keeps it, the function is deployed anew. One run at a time
/// (no shared state of its own beyond its settings).
/// </summary>
public sealed partial class SupabaseSetup
{
    /// <param name="poll">How often waits look again (3 s).</param>
    /// <param name="schemaWait">
    /// A new project says it's healthy before Realtime and Storage have made their tables, which the migrations
    /// add to. Realtime makes <c>realtime.messages</c> only once a client first connects, so
    /// <see cref="MigrateAsync"/> connects (<paramref name="wakeRealtime"/>) and waits up to this long (3 min).
    /// </param>
    /// <param name="keyWait">How long <see cref="LiveChannelAsync"/> waits for Supabase to take a new signing key: it allows a signing key change only every few minutes (8 min).</param>
    /// <param name="health">The function's GET /v1/health once deployed (null: it answers).</param>
    public SupabaseSetup(
        SupabaseAdmin admin,
        string @ref,
        ISupabaseSource? source = null,
        TimeSpan? poll = null,
        TimeSpan? schemaWait = null,
        TimeSpan? keyWait = null,
        Func<SupabaseSetup, Task>? wakeRealtime = null,
        Func<Backend, Task<string?>>? health = null)
    {
        Admin = admin;
        Ref = @ref;
        Source = source ?? new FolderSupabaseSource();
        Poll = poll ?? TimeSpan.FromSeconds(3);
        SchemaWait = schemaWait ?? TimeSpan.FromMinutes(3);
        KeyWait = keyWait ?? TimeSpan.FromMinutes(8);
        WakeRealtime = wakeRealtime ?? ConnectRealtimeAsync;
        Health = health ?? (b => b.Check());
    }

    public SupabaseAdmin Admin { get; }

    public string Ref { get; }

    public ISupabaseSource Source { get; }

    public TimeSpan Poll { get; }

    public TimeSpan SchemaWait { get; }

    public TimeSpan KeyWait { get; }

    public Func<SupabaseSetup, Task> WakeRealtime { get; }

    public Func<Backend, Task<string?>> Health { get; }

    public string Url => $"https://{Ref}.supabase.co";

    public Backend Backend => new(Url, BackendKind.Supabase);

    /// <summary><c>…/20261023000000_pocketterm.sql</c> → version <c>20261023000000</c>, name <c>pocketterm</c>.</summary>
    public static Migration MigrationFromFile(string path, string sql)
    {
        var file = SqlSuffix().Replace(path.Split('/', '\\')[^1], "", 1);
        var cut = file.IndexOf('_', StringComparison.Ordinal);
        return new Migration(cut < 0 ? file : file[..cut], cut < 0 ? "" : file[(cut + 1)..], sql);
    }

    [GeneratedRegex(@"\.sql$")]
    private static partial Regex SqlSuffix();

    /// <summary>
    /// A new P-256 key pair as a private JWK (ES256) with a random <c>kid</c>: what the function signs live channel
    /// tokens with, imported as the project's JWT signing key so Realtime takes those tokens.
    /// </summary>
    public static JsonObject NewLiveSigningKey()
    {
        using var ec = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var p = ec.ExportParameters(includePrivateParameters: true);
        var kid = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        return new JsonObject
        {
            ["kty"] = "EC",
            ["crv"] = "P-256",
            ["alg"] = "ES256",
            ["kid"] = $"{kid[..8]}-{kid[8..12]}-4{kid[13..16]}-a{kid[17..20]}-{kid[20..]}",
            ["x"] = DartBase64.EncodeUrlNoPadding(Fixed32(p.Q.X!)),
            ["y"] = DartBase64.EncodeUrlNoPadding(Fixed32(p.Q.Y!)),
            ["d"] = DartBase64.EncodeUrlNoPadding(Fixed32(p.D!)),
        };
    }

    /// <summary>A coordinate as 32 big-endian bytes, as a JWK has it.</summary>
    private static byte[] Fixed32(byte[] b)
    {
        if (b.Length == 32) return b;
        var padded = new byte[32];
        b.AsSpan(Math.Max(0, b.Length - 32)).CopyTo(padded.AsSpan(Math.Max(0, 32 - b.Length)));
        return padded;
    }

    /// <summary>A setup token: 32 random bytes, base64url without padding (43 characters).</summary>
    public static string NewSetupToken() => DartBase64.EncodeUrlNoPadding(RandomNumberGenerator.GetBytes(32));

    private static async Task ConnectRealtimeAsync(SupabaseSetup s)
    {
        var key = await s.Admin.PublishableKeyAsync(s.Ref).ConfigureAwait(false);
        using var ws = new ClientWebSocket();
        using (var connect = new CancellationTokenSource(TimeSpan.FromSeconds(15)))
        {
            await ws.ConnectAsync(
                new Uri($"wss://{s.Ref}.supabase.co/realtime/v1/websocket?apikey={DartUri.EncodeQueryComponent(key)}&vsn=1.0.0"),
                connect.Token).ConfigureAwait(false);
        }
        var join = DartJson.EncodeUtf8(new JsonObject
        {
            ["topic"] = "realtime:pocketterm-setup",
            ["event"] = "phx_join",
            ["payload"] = new JsonObject(),
            ["ref"] = "1",
        });
        await ws.SendAsync(join, WebSocketMessageType.Text, endOfMessage: true, CancellationToken.None).ConfigureAwait(false);
        try
        {
            using var first = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            await ws.ReceiveAsync(new byte[4096], first.Token).ConfigureAwait(false);
        }
        finally
        {
            try
            {
                using var close = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, null, close.Token).ConfigureAwait(false);
            }
            catch (Exception)
            {
                // Closing is best effort: the socket goes either way.
            }
        }
    }

    /// <summary>Whether PocketTerm is on this project already (an update).</summary>
    public async Task<bool> HasPocketTermAsync() =>
        (await Admin.QueryAsync(Ref, "select to_regnamespace('pocketterm') is not null as ours").ConfigureAwait(false))
        .FirstOrDefault()?.Bool("ours") == true;

    /// <summary>
    /// Applies the migrations the project hasn't had yet, each in its own transaction, recorded where the Supabase
    /// CLI keeps them. How many.
    /// </summary>
    public async Task<int> MigrateAsync()
    {
        await WaitForSchemasAsync().ConfigureAwait(false);
        await Admin.QueryAsync(
            Ref,
            "create schema if not exists supabase_migrations;\n" +
            "create table if not exists supabase_migrations.schema_migrations " +
            "(version text primary key, statements text[], name text);").ConfigureAwait(false);
        var applied = (await Admin.QueryAsync(Ref, "select version from supabase_migrations.schema_migrations").ConfigureAwait(false))
            .Select(r => r.Str("version"))
            .OfType<string>()
            .ToHashSet();
        var count = 0;
        foreach (var m in await Source.MigrationsAsync().ConfigureAwait(false))
        {
            if (applied.Contains(m.Version)) continue;
            await Admin.QueryAsync(
                Ref,
                $"begin;\n{m.Sql}\n;\n" +
                "insert into supabase_migrations.schema_migrations (version, name) " +
                $"values ('{m.Version}', '{m.Name.Replace("'", "''", StringComparison.Ordinal)}');\ncommit;").ConfigureAwait(false);
            count++;
        }
        return count;
    }

    private async Task WaitForSchemasAsync()
    {
        var deadline = DateTime.UtcNow + SchemaWait;
        var woken = false;
        while (true)
        {
            var r = await Admin.QueryAsync(
                Ref,
                "select to_regclass('realtime.messages') is not null and to_regclass('storage.buckets') is not null as ready").ConfigureAwait(false);
            if (r.FirstOrDefault()?.Bool("ready") == true) return;
            if (DateTime.UtcNow > deadline)
            {
                throw new AdminException("Supabase is still starting the project. Wait a minute, then retry.");
            }
            if (!woken)
            {
                woken = true;
                try
                {
                    await WakeRealtime(this).ConfigureAwait(false);
                }
                catch (Exception e)
                {
                    Log.Print($"PocketTerm: waking Realtime failed: {e.Message}");
                }
            }
            await Task.Delay(Poll).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// The live channel's key: a new ES256 key, imported as the project's JWT signing key and put to use (Realtime
    /// then takes tokens it signs), and given to the function as its secret PT_REALTIME_JWK with the publishable key
    /// (PT_PUBLISHABLE_KEY). Realtime takes private channels only. A project that has its key already keeps it.
    /// <paramref name="onWait"/> hears when Supabase makes it wait (a signing key changes every few minutes at most).
    /// </summary>
    public async Task LiveChannelAsync(Action? onWait = null)
    {
        var secrets = await Admin.SecretNamesAsync(Ref).ConfigureAwait(false);
        if (!secrets.Contains("PT_REALTIME_JWK"))
        {
            var jwk = NewLiveSigningKey();
            // A standby key the project made itself would refuse a second one; it never signed anything.
            foreach (var k in await Admin.SigningKeysAsync(Ref).ConfigureAwait(false))
            {
                if (k.Str("status") == "standby" && k.Str("id") is { } standby)
                {
                    await Admin.SetSigningKeyStatusAsync(Ref, standby, "previously_used").ConfigureAwait(false);
                }
            }
            var id = await Admin.AddSigningKeyAsync(Ref, jwk).ConfigureAwait(false);
            var deadline = DateTime.UtcNow + KeyWait;
            var told = false;
            while (true)
            {
                try
                {
                    await Admin.SetSigningKeyStatusAsync(Ref, id, "in_use").ConfigureAwait(false);
                    break;
                }
                catch (AdminException e) when (!(DateTime.UtcNow > deadline || e.Status == 401 || e.Status == 403))
                {
                    Log.Print($"PocketTerm: signing key not in use yet: {e.Message}");
                    if (!told) onWait?.Invoke();
                    told = true;
                    await Task.Delay(Poll * 10).ConfigureAwait(false);
                }
            }
            await Admin.SetSecretsAsync(Ref, [new("PT_REALTIME_JWK", DartJson.Encode(jwk))]).ConfigureAwait(false);
        }
        await Admin.SetSecretsAsync(Ref, [new("PT_PUBLISHABLE_KEY", await Admin.PublishableKeyAsync(Ref).ConfigureAwait(false))]).ConfigureAwait(false);
        try
        {
            await Admin.RealtimePrivateOnlyAsync(Ref).ConfigureAwait(false);
        }
        catch (AdminException e)
        {
            // Every channel PocketTerm opens is private anyway.
            Log.Print($"PocketTerm: Realtime private-only not set: {e.Message}");
        }
    }

    /// <summary>Deploys the function and waits for it to answer.</summary>
    public async Task DeployAsync()
    {
        await Admin.DeployFunctionAsync(Ref, "pocketterm", await Source.FunctionAsync().ConfigureAwait(false), verifyJwt: false).ConfigureAwait(false);
        string? problem = null;
        for (var i = 0; i < 20; i++)
        {
            problem = await Health(Backend).ConfigureAwait(false);
            if (problem == null) return;
            await Task.Delay(Poll).ConfigureAwait(false);
        }
        throw new AdminException($"The PocketTerm function on Supabase doesn’t answer yet: {problem}");
    }

    /// <summary>
    /// A new setup token for this project (only its SHA-256 goes there); the link this computer signs in with. The
    /// one before stops working.
    /// </summary>
    public async Task<string> SetupLinkAsync()
    {
        var token = NewSetupToken();
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(token))).ToLowerInvariant();
        await Admin.QueryAsync(Ref, $"select pocketterm.set_setup_hash('{hash}')").ConfigureAwait(false);
        return Backend.LinkWithSetup(token);
    }

    /// <summary>
    /// Everything, in order; <paramref name="onStep"/> hears each step as it starts, <paramref name="onWait"/> when
    /// Supabase makes the live channel key wait. Steps in <paramref name="done"/> are skipped (a retry picks up where
    /// it stopped). The setup link this computer signs in with.
    /// </summary>
    public async Task<string> RunAsync(Action<SupabaseStep>? onStep = null, Action? onWait = null, IReadOnlySet<SupabaseStep>? done = null)
    {
        async Task Step(SupabaseStep s, Func<Task> work)
        {
            if (done?.Contains(s) == true) return;
            onStep?.Invoke(s);
            await work().ConfigureAwait(false);
        }

        await Step(SupabaseStep.Project, () => Admin.WaitUntilReadyAsync(Ref, poll: Poll)).ConfigureAwait(false);
        await Step(SupabaseStep.Database, MigrateAsync).ConfigureAwait(false);
        await Step(SupabaseStep.LiveChannel, () => LiveChannelAsync(onWait)).ConfigureAwait(false);
        await Step(SupabaseStep.Function, DeployAsync).ConfigureAwait(false);
        onStep?.Invoke(SupabaseStep.SignIn);
        return await SetupLinkAsync().ConfigureAwait(false);
    }
}
