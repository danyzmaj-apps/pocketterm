using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>
/// Once, on launch: PocketTerm's only server is now the one built into the app, over Tailscale. A computer still
/// signed in to a Supabase project or a server of its own (a VPS) is signed out here, its saved server
/// forgotten, and setup opens with <see cref="Note"/>.
/// </summary>
public static class TailscaleOnlyMigration
{
    /// <summary>Set once the migration ran on this computer.</summary>
    public const string DoneKey = "tailscale_only_migrated";

    /// <summary>The note setup shows once afterwards, while set.</summary>
    public const string NoteKey = "tailscale_only_note";

    public const string Note =
        "PocketTerm now runs its server on this computer, over Tailscale. Set it up below; then scan the new code " +
        "with your phone.";

    // What an app from before saved; see Backend.
    private const string HostingKey = "hosting";
    private const string OldKeyKey = "backend_key";
    private const string SetupStepKey = "setup_step";
    private const string SetupAddressKey = "setup_address";

    /// <summary>
    /// Runs it unless it ran before. A PocketTerm server (a VPS) is told this computer is gone through
    /// <paramref name="client"/> (best effort: DELETE /v1/devices/me); a Supabase project is only forgotten. True when this computer
    /// was signed out.
    /// </summary>
    public static async Task<bool> RunAsync(IPreferenceStore prefs, IDeviceTokens tokens, Func<Backend, IDeviceTokens, IServer>? client = null)
    {
        if (prefs.GetBool(DoneKey) ?? false) return false;
        prefs.SetBool(DoneKey, true);
        // The old setup screens are gone: start setup from the top.
        if (prefs.GetString(SetupStepKey) is not (null or "thisComputer")) prefs.Remove(SetupStepKey);
        prefs.Remove(SetupAddressKey);
        var url = prefs.GetString(Backend.UrlKey);
        if (url == null) return false;
        var supabase = prefs.GetString(Backend.KindKey) is { Length: > 0 } || prefs.GetString(OldKeyKey) != null;
        var backend = supabase ? null : Backend.Parse(url).Backend;
        // Its own built-in server, or another computer's over Tailscale: nothing changes.
        if (backend != null && ((prefs.GetBool(HostingKey) ?? false) || backend.OnTailnet)) return false;
        if (backend != null)
        {
            try
            {
                var server = (client ?? Server.Create)(backend, tokens);
                await server.Load().ConfigureAwait(false);
                await server.Leave().WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            }
            catch (Exception e)
            {
                Log.Print($"PocketTerm: couldn't leave {backend.Host}: {e.Message}");
            }
        }
        try
        {
            await tokens.Write(null).ConfigureAwait(false);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: couldn't forget the old sign-in: {e.Message}");
        }
        Backend.Clear(prefs);
        prefs.Remove(SetupStepKey);
        prefs.SetBool(NoteKey, true);
        return true;
    }
}
