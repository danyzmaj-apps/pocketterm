using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>Another computer's setup link, as the person pastes it (Join another computer's PocketTerm…): made
/// by that computer's Settings, Add a computer….</summary>
public static class SetupLinks
{
    /// <summary>Why a link isn't one to join: its server isn't a PocketTerm on Tailscale.</summary>
    public const string NotTailscale = "This link isn't for a PocketTerm on Tailscale.";

    /// <summary>
    /// What's wrong with <paramref name="text"/> as another computer's setup link, for the person; null when it is
    /// one (<c>pocketterm://setup?url=https://&lt;name&gt;.&lt;tailnet&gt;.ts.net&amp;setup=&lt;token&gt;</c>).
    /// <paramref name="anyServer"/> (test builds only) accepts any http(s) server, so the e2e harness and the CI
    /// smoke can join a local sidecar.
    /// </summary>
    public static string? Problem(string text, bool anyServer = false)
    {
        var link = DartUri.TryParse(text.DartTrim());
        if (link == null || link.Scheme != "pocketterm" || link.Host != "setup" || link.Param("url") is not { } url)
        {
            return "That isn’t a setup link. It starts with pocketterm://setup?url= : on the other computer, open " +
                "Settings, Add a computer… and copy the whole link.";
        }
        var kind = link.Param("kind") ?? "";
        if (kind.Length > 0 && kind != "pocketterm") return NotTailscale;
        var backend = Backend.FromLink(link);
        if (backend == null)
        {
            if (!anyServer) return NotTailscale;
            if (Backend.Parse(url).Error is { } error) return $"The server address in that link doesn’t work. {error}";
        }
        else if (!anyServer && (!backend.Url.StartsWith("https://", StringComparison.Ordinal) || !backend.OnTailnet))
        {
            return NotTailscale;
        }
        if (Backend.SetupToken(link) != null) return null;
        return Backend.PairingCode(link) != null
            ? "That link signs in a phone, not a computer. On the other computer, open Settings, Add a computer… and " +
              "paste the link it shows."
            : "That link has no setup token. On the other computer, open Settings, Add a computer… and copy the whole " +
              "link.";
    }
}
