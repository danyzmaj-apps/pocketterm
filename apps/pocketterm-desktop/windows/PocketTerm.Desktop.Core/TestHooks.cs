using System.Collections;

namespace PocketTerm.Desktop;

/// <summary>
/// A build made for tool/smoke or tool/e2e (the <c>E2E</c> compilation symbol: Debug builds, or
/// <c>-p:PocketTermE2E=true</c>). Only such a build reads the environment variables that point
/// PocketTerm at stand-ins: <c>POCKETTERM_TAILSCALE</c> (the Tailscale CLI),
/// <c>POCKETTERM_CLI_JSON</c> (where the local API's port and token go), <c>POCKETTERM_KITTY_DIR</c>
/// (kitty's sockets) and <c>POCKETTERM_PROFILE</c> (secrets in memory). A released build ignores them.
/// </summary>
public static class TestHooks
{
#if E2E
    public static bool TestBuild { get; } = true;
#else
    public static bool TestBuild { get; } = false;
#endif

    /// <summary>Where those variables are read from: this process's environment in a <see cref="TestBuild"/>, none otherwise.</summary>
    public static IReadOnlyDictionary<string, string> Env()
    {
        if (!TestBuild) return new Dictionary<string, string>();
        var env = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (DictionaryEntry e in Environment.GetEnvironmentVariables())
        {
            if (e.Key is string k && e.Value is string v) env[k] = v;
        }
        return env;
    }
}
