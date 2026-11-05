using System.Globalization;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Text.RegularExpressions;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>
/// The name a VPS's server answers at, from what the person typed: a domain as it is, an IPv4 address as its
/// sslip.io name (<c>203.0.113.7</c> → <c>203-0-113-7.sslip.io</c>, a name that resolves to that address), so
/// Caddy can get a certificate for it. Either <see cref="Domain"/> or <see cref="Error"/> is set.
/// </summary>
public sealed partial record ServerAddress
{
    private ServerAddress(string? domain, string? error, string? host = null, string? user = null)
    {
        Domain = domain;
        Error = error;
        Host = host;
        User = user;
    }

    public string? Domain { get; }

    /// <summary>Why what was typed can't be used, for the person.</summary>
    public string? Error { get; }

    /// <summary>What was typed, as SSH reaches the server: its IP address or domain.</summary>
    public string? Host { get; }

    /// <summary>The user, if one was typed with it.</summary>
    public string? User { get; }

    /// <summary>How to sign in to the server from here.</summary>
    public string? Ssh => Host == null ? null : $"ssh {(string.IsNullOrEmpty(User) ? "root" : User)}@{Host}";

    public static ServerAddress Parse(string typed)
    {
        var s = typed.DartTrim().ToLowerInvariant();
        s = Scheme().Replace(s, "", 1);
        var slash = s.IndexOf('/', StringComparison.Ordinal);
        if (slash >= 0) s = s[..slash];
        // user@host, as an SSH line has it ("ssh ubuntu@203.0.113.7").
        var at = s.LastIndexOf('@');
        var user = at < 0 ? null : Whitespace().Split(s[..at])[^1];
        s = s[(at + 1)..];
        s = s.TrimEnd('.');
        if (s.Length == 0) return new ServerAddress(null, "Enter your server’s IP address or domain name.");
        var bracketed = s.StartsWith('[') && s.EndsWith(']') ? s[1..^1] : s;
        var ip = ParseIp(bracketed);
        if (ip?.AddressFamily == AddressFamily.InterNetworkV6 || (ip == null && s.StartsWith('[')))
        {
            return new ServerAddress(
                null,
                "Use the server’s IPv4 address (like 203.0.113.7) or a domain name. An IPv6-only server doesn’t work: " +
                "Docker gets the server from GitHub’s registry (ghcr.io), which has no IPv6, and many phone networks reach " +
                "only IPv4. Most providers add an IPv4 address for a small fee.");
        }
        if (ip != null)
        {
            var b = ip.GetAddressBytes();
            // Loopback 127/8, link-local 169.254/16, or private.
            if (b[0] == 127 || (b[0] == 169 && b[1] == 254) || IsPrivate(b))
            {
                return new ServerAddress(
                    null,
                    "That’s a private address. Use the public IP address your VPS provider shows for the server.");
            }
            return new ServerAddress($"{s.Replace('.', '-')}.sslip.io", null, s, user);
        }
        if (s.Contains(':')) return new ServerAddress(null, "Leave out the port: the server answers on 443.");
        var labels = s.Split('.');
        if (labels.Length < 2 || !labels.All(l => Label().IsMatch(l)) || Digits().IsMatch(labels[^1]))
        {
            return new ServerAddress(null, "That isn’t an IP address or a domain name, like pocketterm.example.com.");
        }
        return new ServerAddress(s, null, s, user);
    }

    /// <summary>
    /// Dart's <c>InternetAddress.tryParse</c>: a dotted quad only for IPv4 (.NET also takes <c>10</c> or
    /// <c>10.1</c>), any IPv6 form.
    /// </summary>
    private static IPAddress? ParseIp(string s)
    {
        var quad = DottedQuad().Match(s);
        if (quad.Success)
        {
            var bytes = new byte[4];
            for (var i = 0; i < 4; i++)
            {
                if (!int.TryParse(quad.Groups[i + 1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out var n) || n > 255) return null;
                bytes[i] = (byte)n;
            }
            return new IPAddress(bytes);
        }
        return s.Contains(':') && !s.Contains('[') && IPAddress.TryParse(s, out var v6) && v6.AddressFamily == AddressFamily.InterNetworkV6 ? v6 : null;
    }

    /// <summary>10/8, 172.16/12, 192.168/16, 100.64/10 (carrier-grade NAT, Tailscale).</summary>
    private static bool IsPrivate(byte[] b) =>
        b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 100 && b[1] >= 64 && b[1] < 128) ||
        b[0] == 0;

    [GeneratedRegex("^[a-z]+://")]
    private static partial Regex Scheme();

    [GeneratedRegex(@"\s+")]
    private static partial Regex Whitespace();

    [GeneratedRegex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")]
    private static partial Regex Label();

    [GeneratedRegex(@"^\d+$")]
    private static partial Regex Digits();

    [GeneratedRegex(@"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")]
    private static partial Regex DottedQuad();
}

/// <summary>One command to run on the VPS, and what it does.</summary>
public sealed record VpsCommand(string Title, string Command);

/// <summary>The commands the own-server setup shows for a new VPS.</summary>
public static class Vps
{
    /// <summary>
    /// The compose file the commands fetch: the repository's at release tag v<paramref name="version"/>, this app's
    /// version, so the VPS runs what this release shipped (the file pins the image to the same version).
    /// </summary>
    public static string ComposeUrl(string version) =>
        $"https://raw.githubusercontent.com/danyzmaj-apps/pocketterm/v{version}/apps/pocketterm-server/docker-compose.yml";

    /// <summary>
    /// What to run on a fresh VPS for a server at <paramref name="domain"/>, with this app's
    /// <paramref name="version"/>, in order: Docker, the compose file, start it, its setup link. Each one stands
    /// alone (it changes to ~/pocketterm itself), so a new SSH session can pick up where the last one left off.
    /// docs/SELF_HOSTING.md shows the same commands.
    /// </summary>
    public static IReadOnlyList<VpsCommand> Commands(string domain, string version) =>
    [
        new("Install Docker", "curl -fsSL https://get.docker.com | sudo sh"),
        new("Get the server", $"mkdir -p ~/pocketterm && cd ~/pocketterm && curl -fsSLO {ComposeUrl(version)}"),
        new("Start it", $"cd ~/pocketterm && echo \"DOMAIN={domain}\" > .env && sudo docker compose up -d"),
        new("Print its setup link", "cd ~/pocketterm && sudo docker compose exec server pocketterm-server setup-link"),
    ];
}

/// <summary>
/// What the setup looks at while a VPS is being set up: the name resolves, HTTPS answers on it (Caddy got its
/// certificate), the server is healthy. Tests hand in their own.
/// </summary>
public class ServerChecks
{
    /// <summary>
    /// <paramref name="domain"/> resolves to an IPv4 address (an A record: an IPv6-only name leaves out the phone
    /// networks that reach only IPv4).
    /// </summary>
    public virtual async Task<bool> ResolvesAsync(string domain)
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(8));
            var found = await Dns.GetHostAddressesAsync(domain, AddressFamily.InterNetwork, cts.Token).ConfigureAwait(false);
            return found.Length > 0;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>A TLS handshake with <paramref name="domain"/> on 443 succeeds: a valid certificate.</summary>
    public virtual async Task<bool> HttpsAsync(string domain)
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(8));
            using var tcp = new TcpClient();
            await tcp.ConnectAsync(domain, 443, cts.Token).ConfigureAwait(false);
            await using var tls = new SslStream(tcp.GetStream());
            await tls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions { TargetHost = domain }, cts.Token).ConfigureAwait(false);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>The server at <paramref name="domain"/>: <c>https://&lt;domain&gt;</c>.</summary>
    public Backend BackendFor(string domain) => new($"https://{domain}");

    /// <summary>
    /// GET /v1/health: <c>Error</c> is null when it's a PocketTerm server this app speaks to, else what's wrong;
    /// <c>ClockOffset</c>, how far its clock is from this computer's (<see cref="Backend.ClockWarning"/>).
    /// </summary>
    public Task<BackendHealth> HealthAsync(string domain) => AnswersAsync(BackendFor(domain));

    /// <summary><paramref name="backend"/>'s GET /v1/health, as <see cref="HealthAsync"/> (a pasted setup link's server).</summary>
    public virtual Task<BackendHealth> AnswersAsync(Backend backend) => backend.Health();
}
