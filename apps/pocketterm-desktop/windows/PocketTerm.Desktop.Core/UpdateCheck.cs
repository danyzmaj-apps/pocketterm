using System.Globalization;
using System.Net.Http.Headers;
using System.Reflection;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>A PocketTerm release newer than this one: its <c>Version</c> (<c>0.6.0</c>) and its release page, where the installer is.</summary>
public sealed record UpdateInfo(string Version, Uri Url);

/// <summary>
/// Windows' update check (the Mac has Sparkle): asks GitHub for the latest release on
/// <see cref="Start"/> and every <see cref="Every"/> after. <see cref="Update"/> is that release
/// while it's newer than this build; a check that fails shows nothing.
/// </summary>
public sealed partial class UpdateCheck : ObservableObject, IDisposable
{
    /// <param name="client">GitHub's API; tests pass a fake.</param>
    /// <param name="version">This build's version, without its build number; the app's own by default.</param>
    public UpdateCheck(HttpClient? client = null, Func<Task<string>>? version = null, TimeSpan? every = null)
    {
        _client = client ?? new HttpClient();
        _version = version ?? (() => Task.FromResult(Installed()));
        Every = every ?? TimeSpan.FromHours(24);
    }

    private readonly HttpClient _client;
    private readonly Func<Task<string>> _version;
    private readonly object _lock = new();
    private Timer? _timer;
    private UpdateInfo? _update;

    public TimeSpan Every { get; }

    public static readonly Uri Latest = new("https://api.github.com/repos/danyzmaj-apps/pocketterm/releases/latest");

    public UpdateInfo? Update
    {
        get
        {
            lock (_lock) return _update;
        }
    }

    /// <summary>The entry assembly's version (<c>InformationalVersion</c> without its <c>+build</c>).</summary>
    internal static string Installed()
    {
        var assembly = Assembly.GetEntryAssembly() ?? typeof(UpdateCheck).Assembly;
        var info = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        if (!string.IsNullOrEmpty(info)) return info.Split('+')[0];
        var v = assembly.GetName().Version;
        return v == null ? "0.0.0" : $"{v.Major}.{v.Minor}.{Math.Max(v.Build, 0)}";
    }

    public void Start()
    {
        _ = CheckAsync();
        lock (_lock) _timer ??= new Timer(_ => _ = CheckAsync(), null, Every, Every);
    }

    public async Task CheckAsync()
    {
        UpdateInfo? found = null;
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, Latest);
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
            // GitHub's API refuses a request without one (Dart's client sent its own).
            request.Headers.UserAgent.Add(new ProductInfoHeaderValue("PocketTerm", null));
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            using var r = await _client.SendAsync(request, cts.Token).ConfigureAwait(false);
            if ((int)r.StatusCode == 200)
            {
                var body = await r.Content.ReadAsStringAsync(cts.Token).ConfigureAwait(false);
                found = Newer(DartJson.Decode(body), await _version().ConfigureAwait(false));
            }
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: update check: {e.Message}");
        }
        lock (_lock)
        {
            if (found == _update) return;
            _update = found;
        }
        NotifyChanged();
    }

    /// <summary>
    /// <paramref name="release"/> (GitHub's JSON for one) if its tag, without a leading <c>v</c>, is a
    /// higher semantic version than <paramref name="current"/>, it has an https page and its Windows
    /// installer (<c>PocketTerm-&lt;version&gt;-setup.exe</c>) is on it: the Mac publishes a release
    /// before the Windows build attaches its installer, and an update offered then would lead to a
    /// page with nothing to run.
    /// </summary>
    public static UpdateInfo? Newer(JsonNode? release, string current)
    {
        if (release is not JsonObject o) return null;
        if (DartJson.AsString(o["tag_name"]) is not { } tag || DartJson.AsString(o["html_url"]) is not { } url) return null;
        var version = tag.StartsWith('v') ? tag[1..] : tag;
        var page = DartUri.TryParse(url);
        var installer = o["assets"] is JsonArray assets && assets.Any(a =>
            a is JsonObject m && DartJson.AsString(m["name"]) is { } name &&
            name.ToLowerInvariant().EndsWith("-setup.exe", StringComparison.Ordinal));
        if ((CompareVersions(version, current) ?? 0) > 0 && page != null && page.Scheme == "https" && installer &&
            Uri.TryCreate(url, UriKind.Absolute, out var uri))
        {
            return new UpdateInfo(version, uri);
        }
        return null;
    }

    [GeneratedRegex(@"^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$")]
    private static partial Regex Semver();

    /// <summary>
    /// Semantic version order of <paramref name="a"/> and <paramref name="b"/> (negative, zero,
    /// positive), the build metadata (<c>+5</c>) ignored; null if either isn't one.
    /// </summary>
    public static int? CompareVersions(string a, string b)
    {
        var x = Semver().Match(a);
        var y = Semver().Match(b);
        if (!x.Success || !y.Success) return null;
        for (var i = 1; i <= 3; i++)
        {
            // Dart's int.parse: digits beyond a long would throw there too; compare as big numbers.
            var c = System.Numerics.BigInteger.Parse(x.Groups[i].Value, CultureInfo.InvariantCulture)
                .CompareTo(System.Numerics.BigInteger.Parse(y.Groups[i].Value, CultureInfo.InvariantCulture));
            if (c != 0) return Math.Sign(c);
        }
        // A pre-release (1.0.0-beta) comes before its release (1.0.0).
        string? p = x.Groups[4].Success ? x.Groups[4].Value : null;
        string? q = y.Groups[4].Success ? y.Groups[4].Value : null;
        if (p == null || q == null) return p == q ? 0 : (p == null ? 1 : -1);
        var ps = p.Split('.');
        var qs = q.Split('.');
        for (var i = 0; i < Math.Min(ps.Length, qs.Length); i++)
        {
            var m = DartString.TryParseInt(ps[i]);
            var n = DartString.TryParseInt(qs[i]);
            var c = (m, n) switch
            {
                ({ } mm, { } nn) => mm.CompareTo(nn),
                ({ }, null) => -1,
                (null, { }) => 1,
                _ => Math.Sign(string.CompareOrdinal(ps[i], qs[i])),
            };
            if (c != 0) return c;
        }
        return ps.Length.CompareTo(qs.Length);
    }

    public void Dispose()
    {
        lock (_lock)
        {
            _timer?.Dispose();
            _timer = null;
        }
        _client.Dispose();
    }
}
