using System.Net;
using System.Net.Http;
using System.Security.Authentication;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace PocketTerm.Core;

/// <summary>What answers a <see cref="Backend"/>: PocketTerm's own server, or PocketTerm set up on a Supabase
/// project (apps/pocketterm-desktop/supabase).</summary>
public enum BackendKind
{
    /// <summary>packages/pocketterm_server, on a VPS or built into a computer's app.</summary>
    Pocketterm,

    /// <summary>The Edge Function <c>pocketterm</c> on a Supabase project: the same REST paths under
    /// <c>/functions/v1/pocketterm</c>, the live channel over Supabase Realtime.</summary>
    Supabase,
}

/// <summary>The outcome of <see cref="Backend.Parse"/>: a backend, or why the URL can't be used.</summary>
public readonly record struct BackendParse(Backend? Backend, string? Error);

/// <summary>The outcome of <see cref="Backend.Health"/>: <c>Error</c> is null when all is well; <c>ClockOffset</c>
/// is how far the server's clock is ahead of this device's (null when it didn't say).</summary>
public readonly record struct BackendHealth(string? Error, TimeSpan? ClockOffset);

/// <summary>
/// The server this device connects through (packages/pocketterm_server/PROTOCOL.md): one on a VPS, the one
/// built into a computer's app, reached on the same network or through Tailscale, or a Supabase project
/// (<see cref="Kind"/>). A computer signs in with the server's setup link
/// (<c>pocketterm://setup?url=…&amp;setup=…</c>, printed by the server; <c>kind=supabase</c> for a Supabase
/// project); a phone with a computer's code, a setup link with a pairing code and that computer's key in it
/// (<c>pocketterm://setup?url=…&amp;code=…&amp;d=…&amp;k=…</c>). A computer keeps it in its preferences
/// (<see cref="Load"/>, <see cref="Save"/>).
/// </summary>
public sealed partial class Backend : IEquatable<Backend>
{
    /// <summary>The protocol version this app speaks (GET /v1/health).</summary>
    public const int Protocol = 1;

    /// <summary>The oldest PocketTerm server this app works with (GET /v1/health's <c>version</c>).</summary>
    public const string MinServer = "0.1.0";

    /// <summary>How far this device's clock may be off the server's before <see cref="ClockWarning"/> speaks up:
    /// each side drops sealed messages more than 5 minutes off its own clock, so two devices each within 2
    /// minutes stay within reach of each other.</summary>
    public static readonly TimeSpan ClockTolerance = TimeSpan.FromMinutes(2);

    /// <summary>What a Supabase project that doesn't answer may be: paused.</summary>
    private const string Paused =
        "Free Supabase projects pause after about a week without use: open supabase.com/dashboard and restore " +
        "the project, then retry.";

    // A computer keeps it in its preferences under these keys.
    private const string UrlKey = "backend_url";
    private const string KindKey = "backend_kind";

    /// <summary>Where an app from before kept its Supabase project's key.</summary>
    private const string OldKeyKey = "backend_key";

    public Backend(string url, BackendKind kind = BackendKind.Pocketterm)
    {
        Url = url;
        Kind = kind;
    }

    /// <summary>The server's public URL, <c>https://pocketterm.example.com</c> or
    /// <c>https://my-mac.tail1234.ts.net</c>, without a trailing slash; for a Supabase project, the project's
    /// (<c>https://&lt;ref&gt;.supabase.co</c>).</summary>
    public string Url { get; }

    public BackendKind Kind { get; }

    public bool IsSupabase => Kind == BackendKind.Supabase;

    /// <summary>Where the REST paths of PROTOCOL.md start (<c>&lt;api&gt;/v1/health</c>, …).</summary>
    public string Api => IsSupabase ? $"{Url}/functions/v1/pocketterm" : Url;

    /// <summary><paramref name="url"/> as typed, or a reason it can't be used.</summary>
    public static BackendParse Parse(string url, BackendKind kind = BackendKind.Pocketterm)
    {
        var u = url.DartTrim();
        while (u.EndsWith('/')) u = u[..^1];
        // The API's own path works too.
        u = kind == BackendKind.Supabase ? SupabaseApiPath().Replace(u, "", 1) : ApiPath().Replace(u, "", 1);
        var uri = DartUri.TryParse(u);
        if (u.Length == 0 || uri == null || !uri.HasScheme || uri.Host.Length == 0)
        {
            return new(null, kind == BackendKind.Supabase
                ? "Enter your Supabase project URL, like https://abcdefghijklmnop.supabase.co."
                : "Enter your server URL, like https://pocketterm.example.com.");
        }
        if (uri.Scheme != "https" && !(uri.Scheme == "http" && IsThisMachine(uri.Host)))
        {
            return new(null, "The server URL must start with https://.");
        }
        if (uri.Path.Length > 0 || uri.HasQuery || uri.HasFragment)
        {
            return new(null, "Use the server URL alone, without a path.");
        }
        return new(new Backend(u, kind), null);
    }

    /// <summary>A <c>pocketterm://setup?url=…</c> link (its pairing code, if any, is <see cref="PairingCode"/>'s;
    /// its setup token <see cref="SetupToken"/>'s). A link carrying a <c>key</c> isn't one, nor one of a
    /// <c>kind</c> this app doesn't know.</summary>
    public static Backend? FromLink(DartUri uri)
    {
        IReadOnlyDictionary<string, string> q;
        try
        {
            q = uri.QueryParameters;
        }
        catch (FormatException)
        {
            return null;
        }
        if (uri.Scheme != "pocketterm" || uri.Host != "setup" || q.ContainsKey("key")) return null;
        q.TryGetValue("url", out var url);
        q.TryGetValue("kind", out var kindName);
        BackendKind? kind = kindName switch
        {
            null or "" or "pocketterm" => BackendKind.Pocketterm,
            "supabase" => BackendKind.Supabase,
            _ => null,
        };
        return url == null || kind == null ? null : Parse(url, kind.Value).Backend;
    }

    /// <summary><see cref="FromLink(DartUri)"/> of link text; null when it isn't a URI.</summary>
    public static Backend? FromLink(string link) => DartUri.TryParse(link) is { } uri ? FromLink(uri) : null;

    /// <summary>The pairing code in a setup link (the computer's QR), if it has one: it signs a phone in.</summary>
    public static string? PairingCode(DartUri uri) => Param(uri, "code");

    /// <summary>The setup token in a server's setup link, if it has one: it signs a computer in.</summary>
    public static string? SetupToken(DartUri uri) => Param(uri, "setup");

    private static string? Param(DartUri uri, string name)
    {
        if (FromLink(uri) == null) return null;
        var value = uri.Param(name)?.DartTrim() ?? "";
        return value.Length == 0 ? null : value;
    }

    /// <summary>The computer and its channel key in a setup link (<c>d</c>, <c>k</c>: the computer's QR), if it
    /// has them. A link without them still signs in; that computer then stays locked on the phone.</summary>
    public static ComputerKey? ComputerKey(DartUri uri)
    {
        if (FromLink(uri) == null) return null;
        var desktop = uri.Param("d") ?? "";
        var key = ChannelKey.TryParse(uri.Param("k"));
        if (key == null || !DesktopId().IsMatch(desktop)) return null;
        return new ComputerKey(desktop, key);
    }

    private List<KeyValuePair<string, string>> Where()
    {
        var w = new List<KeyValuePair<string, string>>();
        if (IsSupabase) w.Add(new("kind", "supabase"));
        w.Add(new("url", Url));
        return w;
    }

    /// <summary>The setup link of this server, without a secret.</summary>
    public string Link => DartUri.Build("pocketterm", "setup", query: Where());

    /// <summary><see cref="Link"/> with a computer's <paramref name="setup"/> token: what signs another computer
    /// in. A secret: whoever has it can add a computer.</summary>
    public string LinkWithSetup(string setup) => DartUri.Build("pocketterm", "setup", query: [.. Where(), new("setup", setup)]);

    /// <summary><see cref="Link"/> with a pairing code and, from a computer, its <paramref name="computer"/> key:
    /// what the computer's QR holds. A secret: whoever has it reads that computer's sessions.</summary>
    public string LinkWithCode(string code, ComputerKey? computer = null)
    {
        var q = Where();
        q.Add(new("code", code));
        if (computer != null)
        {
            q.Add(new("d", computer.Desktop));
            q.Add(new("k", computer.Key.ToBase64Url()));
        }
        return DartUri.Build("pocketterm", "setup", query: q);
    }

    /// <summary>The host, for display.</summary>
    public string Host => DartUri.TryParse(Url)?.Host ?? "";

    /// <summary>Reached through Tailscale (<c>tailscale serve</c> on a computer): only a device on that tailnet,
    /// with Tailscale on, can reach it.</summary>
    public bool OnTailnet => Host.EndsWith(".ts.net", StringComparison.Ordinal);

    /// <summary>Why this device gets no answer from the server, worded for the person: a Tailscale address
    /// needs Tailscale on here.</summary>
    public string Unreachable => OnTailnet
        ? $"Can't reach {Host}. It's on your tailnet: open Tailscale on this device and connect."
        : $"Can't reach {Host}. Check your connection.";

    /// <summary>Plain http only to this machine (a computer reaching the server built into it); everything else,
    /// Tailscale included (<c>tailscale serve</c> gives it a ts.net certificate), needs https.</summary>
    private static bool IsThisMachine(string host) =>
        host is "localhost" or "::1" or "[::1]" || host.StartsWith("127.", StringComparison.Ordinal);

    /// <summary>Asks the server for its health: reachable, a PocketTerm server, one this app speaks to. Null when
    /// all is well, else what's wrong.</summary>
    public async Task<string?> Check() => (await Health().ConfigureAwait(false)).Error;

    /// <summary>GET /v1/health: <c>Error</c> is null when all is well, else what's wrong, worded for the person.
    /// <c>ClockOffset</c> is how far the server's clock is ahead of this device's (null when it didn't say); see
    /// <see cref="ClockWarning"/>. The headers and then the body each have <paramref name="wait"/> to arrive.</summary>
    public async Task<BackendHealth> Health(TimeSpan? wait = null)
    {
        var timeout = wait ?? TimeSpan.FromSeconds(10);
        // Dart's HttpClient follows up to 5 redirects and then gives up (RedirectException).
        using var handler = new SocketsHttpHandler
        {
            ConnectTimeout = TimeSpan.FromSeconds(8),
            AllowAutoRedirect = true,
            MaxAutomaticRedirections = 5,
        };
        using var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        static BackendHealth Fail(string error) => new(error, null);
        try
        {
            var sent = DateTimeOffset.UtcNow;
            using var headers = new CancellationTokenSource(timeout);
            using var res = await client.GetAsync($"{Api}/v1/health", HttpCompletionOption.ResponseHeadersRead, headers.Token).ConfigureAwait(false);
            using var bodyWait = new CancellationTokenSource(timeout);
            var bytes = await res.Content.ReadAsByteArrayAsync(bodyWait.Token).ConfigureAwait(false);
            var body = DartString.StrictUtf8.GetString(bytes);
            var received = DateTimeOffset.UtcNow;
            var status = (int)res.StatusCode;
            if (status is >= 300 and < 400 && res.Headers.Location != null)
            {
                throw new RedirectLoopException();
            }
            if (IsSupabase && status != 200 && status != 404)
            {
                return Fail($"Your Supabase project {Host} doesn't answer ({status}). {Paused}");
            }
            if (status is >= 520 and <= 530 && (res.Headers.Contains("cf-ray") || Cloudflare(res)))
            {
                return Fail(
                    $"Cloudflare answers for {Host} but can't reach your server ({status}). Turn the orange cloud off for " +
                    "this name (DNS only), or set SSL/TLS to Full (strict) in Cloudflare.");
            }
            if (status is 502 or 503 or 504)
            {
                return Fail(
                    $"{Host} answers, but the PocketTerm server behind it doesn't ({status}). On a VPS, check that it runs: " +
                    "`docker compose ps` and `docker compose logs server`.");
            }
            if (status == 404) return Fail(NoServer);
            if (status != 200) return Fail($"The server answered with an error ({status}).");
            var health = DartJson.Decode(body);
            var version = health is JsonObject h0 ? DartJson.AsInt(h0["pocketterm"]) : null;
            if (version is not { } v) return Fail(NoServer);
            if (v > Protocol) return Fail("Your server is newer than this app. Update PocketTerm, then retry.");
            var map = (JsonObject)health!;
            if (map.Str("version") is { } serverVersion && OlderThan(serverVersion, MinServer))
            {
                return Fail(IsSupabase
                    ? $"Your Supabase project runs PocketTerm {serverVersion}; this app needs {MinServer} or newer. Set " +
                      "PocketTerm up on Supabase again from a computer (it updates the project), then retry."
                    : $"Your server runs PocketTerm server {serverVersion}; this app needs {MinServer} or newer. Update the " +
                      "server (on a VPS: `docker compose pull && docker compose up -d`; built into PocketTerm on a " +
                      "computer: update PocketTerm there), then retry.");
            }
            var time = DartDate.TryParse(map.Str("time") ?? "");
            // The server read its clock about halfway through the round trip.
            var here = sent + (received - sent) / 2;
            return new(null, time - here);
        }
        catch (HttpRequestException e) when (e.InnerException is AuthenticationException || e.HttpRequestError == HttpRequestError.SecureConnectionError)
        {
            return Fail(
                $"Couldn't make a secure connection to {Host}: its HTTPS certificate isn't valid or isn't there yet. A new " +
                "server takes a minute to get one; on a VPS, `docker compose logs caddy` says what went wrong.");
        }
        catch (RedirectLoopException)
        {
            return Fail(
                $"{Host} keeps redirecting to itself. If it is behind Cloudflare, set SSL/TLS to Full (strict) in " +
                "Cloudflare.");
        }
        catch (OperationCanceledException)
        {
            return Fail($"{Host} took too long to answer.{(IsSupabase ? " " + Paused : "")}");
        }
        catch (Exception e) when (e is HttpRequestException or IOException)
        {
            // Refused, reset, or closed mid-answer, e.g. a captive portal or a proxy.
            return Fail(OnTailnet ? Unreachable : $"Couldn't reach {Host}. Check the URL and your connection.");
        }
        catch (Exception e) when (e is System.Text.Json.JsonException or DecoderFallbackException or FormatException)
        {
            return Fail(NoServer);
        }
    }

    private sealed class RedirectLoopException : Exception;

    /// <summary>What to tell the person when this device's clock is <paramref name="offset"/> off the server's by
    /// more than <see cref="ClockTolerance"/>; null when it's close enough or unknown.</summary>
    public static string? ClockWarning(TimeSpan? offset)
    {
        if (offset is not { } o || o.Duration() <= ClockTolerance) return null;
        // Dart: (offset.inSeconds.abs() / 60).round(), inSeconds truncating, round() half away from zero.
        var seconds = Math.Abs((long)o.TotalSeconds);
        var minutes = (long)Math.Round(seconds / 60.0, MidpointRounding.AwayFromZero);
        return $"This device's clock is {minutes} minutes {(o < TimeSpan.Zero ? "ahead of" : "behind")} the server's, so " +
               "its messages to your other devices are dropped. Turn on Set time automatically in this device's date and " +
               "time settings.";
    }

    private static bool Cloudflare(HttpResponseMessage res) =>
        res.Headers.TryGetValues("server", out var v) && string.Join(", ", v).ToLowerInvariant() == "cloudflare";

    private string NoServer => IsSupabase
        ? "PocketTerm isn’t set up on this Supabase project. Set it up from a computer: PocketTerm, Supabase."
        : "No PocketTerm server answers at this URL.";

    /// <summary>Whether version <paramref name="a"/> (<c>1.2.3</c>) comes before <paramref name="b"/>.</summary>
    internal static bool OlderThan(string a, string b)
    {
        static List<long> Parts(string v) => v.Split('-')[0].Split('.').Select(p => DartString.TryParseInt(p) ?? 0).ToList();
        var x = Parts(a);
        var y = Parts(b);
        for (var i = 0; i < 3; i++)
        {
            var d = (i < x.Count ? x[i] : 0) - (i < y.Count ? y[i] : 0);
            if (d != 0) return d < 0;
        }
        return false;
    }

    /// <summary>The server this computer was connected to, if any. One saved by an app from before (a Supabase
    /// project, which came with a key) isn't one.</summary>
    public static Backend? Load(IPreferenceStore prefs)
    {
        var url = prefs.GetString(UrlKey);
        if (url == null || prefs.GetString(OldKeyKey) != null) return null;
        return Parse(url, KindOf(prefs.GetString(KindKey))).Backend;
    }

    private static BackendKind KindOf(string? name) => name == "supabase" ? BackendKind.Supabase : BackendKind.Pocketterm;

    public void Save(IPreferenceStore prefs)
    {
        prefs.SetString(UrlKey, Url);
        if (IsSupabase) prefs.SetString(KindKey, Kind.Name());
        else prefs.Remove(KindKey);
        prefs.Remove(OldKeyKey);
    }

    public static void Clear(IPreferenceStore prefs)
    {
        prefs.Remove(UrlKey);
        prefs.Remove(KindKey);
        prefs.Remove(OldKeyKey);
    }

    public bool Equals(Backend? other) => other is not null && other.Url == Url && other.Kind == Kind;

    public override bool Equals(object? obj) => obj is Backend b && Equals(b);

    public override int GetHashCode() => HashCode.Combine(Url, Kind);

    public static bool operator ==(Backend? a, Backend? b) => a is null ? b is null : a.Equals(b);

    public static bool operator !=(Backend? a, Backend? b) => !(a == b);

    public override string ToString() => $"Backend({Url}, {Kind.Name()})";

    [GeneratedRegex(@"/functions/v1/pocketterm(/v1)?\z")]
    private static partial Regex SupabaseApiPath();

    [GeneratedRegex(@"/v1\z")]
    private static partial Regex ApiPath();

    [GeneratedRegex(@"^[a-z0-9]{8}\z")]
    private static partial Regex DesktopId();
}
