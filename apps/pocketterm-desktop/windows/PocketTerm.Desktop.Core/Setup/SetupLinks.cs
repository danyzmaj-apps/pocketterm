using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>A computer's setup link, as the person pastes it (Your own server, Supabase).</summary>
public static class SetupLinks
{
    /// <summary>
    /// What's wrong with <paramref name="text"/> as a computer's setup link, for the person; null when it is one
    /// (<c>pocketterm://setup?url=&lt;https url&gt;&amp;setup=&lt;token&gt;</c>, with <c>kind=supabase</c> for a
    /// Supabase project).
    /// </summary>
    public static string? Problem(string text)
    {
        var link = DartUri.TryParse(text.DartTrim());
        if (link == null || link.Scheme != "pocketterm" || link.Host != "setup" || link.Param("url") is not { } url)
        {
            return "That isn’t a setup link. It starts with pocketterm://setup?url= : copy the whole line setup-link " +
                "printed.";
        }
        var kind = link.Param("kind") ?? "";
        var supabase = kind == BackendKind.Supabase.Name();
        if (Backend.FromLink(link) == null)
        {
            if (kind.Length > 0 && kind != BackendKind.Pocketterm.Name() && !supabase)
            {
                return "That link is for a newer PocketTerm. Update PocketTerm, then paste it again.";
            }
            var parsed = Backend.Parse(url, supabase ? BackendKind.Supabase : BackendKind.Pocketterm);
            if (parsed.Error is { } error) return $"The server address in that link doesn’t work. {error}";
        }
        if (Backend.SetupToken(link) != null) return null;
        if (supabase)
        {
            return Backend.PairingCode(link) != null
                ? "That link signs in a phone, not a computer. On a computer already signed in, open Settings, Account, " +
                  "Add a computer… and paste the link it shows."
                : "That link has no setup token. On a computer already signed in, open Settings, Account, Add a " +
                  "computer… and copy the whole link.";
        }
        if (Backend.PairingCode(link) != null)
        {
            return "That link signs in a phone, not a computer. Use the server’s setup link: on the server, run " +
                "sudo docker compose exec server pocketterm-server setup-link.";
        }
        return "That link has no setup token: copy the whole line setup-link printed.";
    }
}
