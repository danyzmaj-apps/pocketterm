using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>What went wrong talking to Supabase, worded for the person setting up.</summary>
public sealed class AdminException(string message, int? status = null) : Exception(message)
{
    public int? Status { get; } = status;

    public override string ToString() => Message;
}

/// <summary>A Supabase organization; <paramref name="Plan"/> is <c>free</c>, <c>pro</c>, ….</summary>
public sealed record SupabaseOrg(string Slug, string Name, string Plan);

/// <summary>A Supabase project.</summary>
public sealed record SupabaseProject(string Ref, string Name, string Status, string Region, string Org);

/// <summary>
/// The Supabase Management API (api.supabase.com), with the personal access token the person pasted in the setup.
/// Only the calls the setup needs. The token is never stored: it lives as long as this object.
/// </summary>
public sealed class SupabaseAdmin : IDisposable
{
    private readonly string _token;
    private readonly HttpClient _http;
    private readonly string _base;

    /// <param name="handler">Where requests go (tests: a fake); the network by default.</param>
    /// <param name="baseUrl">The API's address; <c>https://api.supabase.com</c> by default.</param>
    public SupabaseAdmin(string token, HttpMessageHandler? handler = null, string? baseUrl = null)
    {
        _token = token;
        _http = handler == null ? new HttpClient() : new HttpClient(handler, disposeHandler: false);
        // The timeouts are each call's own.
        _http.Timeout = Timeout.InfiniteTimeSpan;
        _base = (baseUrl ?? "https://api.supabase.com").TrimEnd('/');
    }

    public void Dispose() => _http.Dispose();

    private async Task<List<JsonObject>> ListAsync(string path, IEnumerable<KeyValuePair<string, string>>? query = null)
    {
        var json = await SendAsync(HttpMethod.Get, path, query: query).ConfigureAwait(false);
        var items = json is JsonObject o && o["keys"] is JsonArray keys ? keys : json;
        return items is JsonArray list ? list.OfType<JsonObject>().ToList() : [];
    }

    private async Task<JsonObject> MapAsync(HttpMethod method, string path, JsonNode? body = null)
    {
        var json = await SendAsync(method, path, body).ConfigureAwait(false);
        return json as JsonObject ?? throw new AdminException("Supabase sent an unexpected answer.");
    }

    private string Url(string path, IEnumerable<KeyValuePair<string, string>>? query = null) =>
        query == null ? $"{_base}{path}" : $"{_base}{path}?{DartUri.EncodeQuery(query)}";

    private async Task<JsonNode?> SendAsync(HttpMethod method, string path, JsonNode? body = null, IEnumerable<KeyValuePair<string, string>>? query = null)
    {
        using var req = new HttpRequestMessage(method, Url(path, query));
        req.Headers.TryAddWithoutValidation("authorization", $"Bearer {_token}");
        if (body != null) req.Content = new StringContent(DartJson.Encode(body), Encoding.UTF8, "application/json");
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(60));
        HttpResponseMessage res;
        byte[] bytes;
        try
        {
            res = await _http.SendAsync(req, cts.Token).ConfigureAwait(false);
            bytes = await res.Content.ReadAsByteArrayAsync(cts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw new AdminException("Supabase took too long to answer. Try again.");
        }
        catch (Exception)
        {
            throw new AdminException("Couldn't reach Supabase. Check your connection.");
        }
        using (res) return Decode((int)res.StatusCode, bytes);
    }

    private static JsonNode? Decode(int status, byte[] bytes)
    {
        var text = Encoding.UTF8.GetString(bytes);
        JsonNode? json;
        try
        {
            json = text.Length == 0 ? null : DartJson.Decode(text);
        }
        catch (JsonException)
        {
            json = null;
        }
        if (status is >= 200 and < 300) return json;
        var detail = json is JsonObject o
            ? Said(o["message"] ?? o["msg"] ?? o["error"])
            : text.DartTrim();
        throw new AdminException(status switch
        {
            401 => "Supabase refused that access token. Create a new one and paste it again.",
            403 => $"That access token isn't allowed to do this{(detail.Length == 0 ? "" : $": {detail}")}",
            429 => "Supabase is rate-limiting requests. Wait a minute, then retry.",
            _ => detail.Length == 0 ? $"Supabase answered with an error ({status})." : detail,
        }, status);
    }

    /// <summary>Dart's <c>toString()</c> of a JSON value: a string as it is, anything else as JSON.</summary>
    private static string Said(JsonNode? node) => node == null ? "" : DartJson.AsString(node) ?? DartJson.Encode(node);

    private static SupabaseProject ToProject(JsonObject p) => new(
        p.Str("id") ?? p.Str("ref") ?? throw new AdminException("Supabase sent an unexpected answer."),
        p.Str("name") ?? "",
        p.Str("status") ?? "",
        p.Str("region") ?? "",
        p.Str("organization_slug") ?? p.Str("organization_id") ?? "");

    public async Task<IReadOnlyList<SupabaseOrg>> OrganizationsAsync() =>
        (await ListAsync("/v1/organizations").ConfigureAwait(false))
        .Select(o => new SupabaseOrg(
            o.Str("slug") ?? o.Str("id") ?? throw new AdminException("Supabase sent an unexpected answer."),
            o.Str("name") ?? "",
            o.Str("plan") ?? ""))
        .ToList();

    /// <summary>The organization in full (its plan: <c>free</c>, <c>pro</c>, …).</summary>
    public async Task<SupabaseOrg> OrganizationAsync(string slug)
    {
        var o = await MapAsync(HttpMethod.Get, $"/v1/organizations/{slug}").ConfigureAwait(false);
        return new SupabaseOrg(o.Str("slug") ?? slug, o.Str("name") ?? "", o.Str("plan") ?? "");
    }

    public async Task<IReadOnlyList<SupabaseProject>> ProjectsAsync() =>
        (await ListAsync("/v1/projects").ConfigureAwait(false)).Select(ToProject).ToList();

    public async Task<SupabaseProject> ProjectAsync(string @ref) =>
        ToProject(await MapAsync(HttpMethod.Get, $"/v1/projects/{@ref}").ConfigureAwait(false));

    /// <summary>
    /// A new project; it takes a minute or two to come up (<see cref="WaitUntilReadyAsync"/>).
    /// <paramref name="dbPassword"/> is the database's; PocketTerm never needs it again.
    /// </summary>
    public async Task<SupabaseProject> CreateProjectAsync(string org, string name, string region, string dbPassword)
    {
        try
        {
            return ToProject(await MapAsync(
                HttpMethod.Post,
                "/v1/projects",
                new JsonObject
                {
                    ["organization_slug"] = org,
                    ["name"] = name,
                    ["db_pass"] = dbPassword,
                    ["region_selection"] = new JsonObject { ["type"] = "specific", ["code"] = region },
                }).ConfigureAwait(false));
        }
        catch (AdminException e)
        {
            var m = e.Message.ToLowerInvariant();
            // 429 is "rate-limiting", not the plan.
            if (e.Status != 429 && (m.Contains("limit") || m.Contains("maximum")))
            {
                throw new AdminException(
                    "This Supabase account already has the two active projects the free plan allows. Pause or delete one " +
                    "you don't need (at supabase.com/dashboard), or choose an organization on a paid plan, then try again.",
                    e.Status);
            }
            throw;
        }
    }

    /// <summary>Polls until the project is up, or fails after <paramref name="timeout"/> (6 minutes). False when <paramref name="stop"/> fires first.</summary>
    public async Task<bool> WaitUntilReadyAsync(string @ref, TimeSpan? timeout = null, TimeSpan? poll = null, CancellationToken stop = default)
    {
        var end = DateTime.UtcNow + (timeout ?? TimeSpan.FromMinutes(6));
        var every = poll ?? TimeSpan.FromSeconds(5);
        while (!stop.IsCancellationRequested)
        {
            var status = (await ProjectAsync(@ref).ConfigureAwait(false)).Status;
            if (stop.IsCancellationRequested) break;
            if (status == "ACTIVE_HEALTHY") return true;
            if (status.Contains("FAILED", StringComparison.Ordinal) || status == "INACTIVE" || status == "PAUSED")
            {
                throw new AdminException($"The project is {status}. Restore it in the Supabase dashboard, then retry.");
            }
            if (DateTime.UtcNow >= end)
            {
                throw new AdminException("The project is still starting. Give it another minute, then continue.");
            }
            try
            {
                await Task.Delay(every, stop).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
        return false;
    }

    /// <summary>Runs SQL as the database owner; the rows of the last statement.</summary>
    public async Task<IReadOnlyList<JsonObject>> QueryAsync(string @ref, string sql)
    {
        var rows = await SendAsync(HttpMethod.Post, $"/v1/projects/{@ref}/database/query", new JsonObject { ["query"] = sql }).ConfigureAwait(false);
        return rows is JsonArray list ? list.OfType<JsonObject>().ToList() : [];
    }

    /// <summary>The key apps use: the publishable one, else the legacy anon key.</summary>
    public async Task<string> PublishableKeyAsync(string @ref)
    {
        var keys = await ListAsync($"/v1/projects/{@ref}/api-keys", [new("reveal", "false")]).ConfigureAwait(false);
        string? Find(Func<JsonObject, bool> test) => keys.FirstOrDefault(test)?.Str("api_key");
        var key = Find(k => k.Str("type") == "publishable") ?? Find(k => k.Str("name") == "anon");
        return key ?? throw new AdminException("The project has no publishable key. Create one under API Keys.");
    }

    /// <summary>The project's JWT signing keys: <c>id</c>, <c>algorithm</c>, <c>status</c> (<c>in_use</c>, <c>standby</c>, <c>previously_used</c>, <c>revoked</c>).</summary>
    public Task<List<JsonObject>> SigningKeysAsync(string @ref) => ListAsync($"/v1/projects/{@ref}/config/auth/signing-keys");

    /// <summary>Imports <paramref name="privateJwk"/> as a standby JWT signing key; its id.</summary>
    public async Task<string> AddSigningKeyAsync(string @ref, JsonObject privateJwk)
    {
        var key = await MapAsync(
            HttpMethod.Post,
            $"/v1/projects/{@ref}/config/auth/signing-keys",
            new JsonObject
            {
                ["algorithm"] = privateJwk["alg"]?.DeepClone() ?? "ES256",
                ["private_jwk"] = privateJwk.DeepClone(),
            }).ConfigureAwait(false);
        return key.Str("id") ?? throw new AdminException("Supabase sent an unexpected answer.");
    }

    /// <summary>Moves signing key <paramref name="id"/> to <paramref name="status"/> (<c>in_use</c> rotates to it).</summary>
    public Task SetSigningKeyStatusAsync(string @ref, string id, string status) =>
        SendAsync(HttpMethod.Patch, $"/v1/projects/{@ref}/config/auth/signing-keys/{id}", new JsonObject { ["status"] = status });

    /// <summary>Sets the Edge Functions' secrets (replacing those of the same names).</summary>
    public Task SetSecretsAsync(string @ref, IEnumerable<KeyValuePair<string, string>> secrets) => SendAsync(
        HttpMethod.Post,
        $"/v1/projects/{@ref}/secrets",
        new JsonArray(secrets.Select(s => (JsonNode)new JsonObject { ["name"] = s.Key, ["value"] = s.Value }).ToArray()));

    /// <summary>The names of the Edge Functions' secrets (their values never come back).</summary>
    public async Task<IReadOnlySet<string>> SecretNamesAsync(string @ref) =>
        (await ListAsync($"/v1/projects/{@ref}/secrets").ConfigureAwait(false)).Select(s => s.Str("name")).OfType<string>().ToHashSet();

    /// <summary>Realtime takes only private channels (every join checked against RLS).</summary>
    public Task RealtimePrivateOnlyAsync(string @ref) =>
        SendAsync(HttpMethod.Patch, $"/v1/projects/{@ref}/config/realtime", new JsonObject { ["private_only"] = true });

    /// <summary>Deploys one Edge Function from its source; Supabase bundles it.</summary>
    public async Task DeployFunctionAsync(string @ref, string slug, string source, bool verifyJwt)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, Url($"/v1/projects/{@ref}/functions/deploy", [new("slug", slug)]));
        req.Headers.TryAddWithoutValidation("authorization", $"Bearer {_token}");
        var form = new MultipartFormDataContent();
        var metadata = new StringContent(DartJson.Encode(new JsonObject
        {
            ["entrypoint_path"] = "index.ts",
            ["name"] = slug,
            ["verify_jwt"] = verifyJwt,
        }));
        // A plain form field, as Dart's http sends one.
        metadata.Headers.ContentType = null;
        metadata.Headers.ContentDisposition = new ContentDispositionHeaderValue("form-data") { Name = "\"metadata\"" };
        form.Add(metadata);
        var file = new ByteArrayContent(Encoding.UTF8.GetBytes(source));
        file.Headers.ContentType = MediaTypeHeaderValue.Parse("text/plain; charset=utf-8");
        file.Headers.ContentDisposition = new ContentDispositionHeaderValue("form-data") { Name = "\"file\"", FileName = "\"index.ts\"" };
        form.Add(file);
        req.Content = form;
        using var cts = new CancellationTokenSource(TimeSpan.FromMinutes(2));
        HttpResponseMessage res;
        byte[] bytes;
        try
        {
            res = await _http.SendAsync(req, cts.Token).ConfigureAwait(false);
            bytes = await res.Content.ReadAsByteArrayAsync(cts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw new AdminException($"Deploying {slug} took too long. Retry.");
        }
        catch (Exception)
        {
            throw new AdminException("Couldn't reach Supabase. Check your connection.");
        }
        using (res) Decode((int)res.StatusCode, bytes);
    }
}
