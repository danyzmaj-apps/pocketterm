using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace PocketTerm.Core;

/// <summary>
/// The coding agents whose sessions PocketTerm brings to the phone (Live*): what a new session
/// from the phone starts, how notifications and the phone name a session, and how its dialogs
/// are answered. Travels by <see cref="DartEnum.Name{T}"/> (<c>omp</c>, <c>claude</c>).
/// </summary>
public enum Agent
{
    Omp,
    Claude,
}

/// <summary>What each <see cref="Agent"/> is (Dart's enum members), and parsing.</summary>
public static partial class Agents
{
    /// <summary>How the phone and notifications name it: "Claude finished".</summary>
    public static string Label(this Agent a) => a == Agent.Omp ? "omp" : "Claude";

    /// <summary>What a shell starts it with, which is also the program the terminal reports.</summary>
    public static string Command(this Agent a) => a.Name();

    /// <summary><see cref="Command"/> in an omp <paramref name="profile"/> (<c>omp --profile=personal</c>), as typed;
    /// '' is the default profile, and Claude Code has none.</summary>
    public static string CommandIn(this Agent a, string profile) =>
        a == Agent.Omp && profile.Length > 0 ? $"{a.Command()} --profile={profile}" : a.Command();

    /// <summary><see cref="Label"/> with an omp profile that isn't the default: "omp · personal".</summary>
    public static string LabelIn(this Agent a, string profile) =>
        a == Agent.Omp && profile.Length > 0 ? $"{a.Label()} · {profile}" : a.Label();

    /// <summary>The command that restarts it on the conversation it had (<c>omp -c</c>), for text: it never
    /// breaks across lines (a no-break space, and a word joiner after the hyphen) yet copies as typed.</summary>
    public static string Resume(this Agent a) => a.ResumeIn("");

    /// <summary><see cref="Resume"/> in an omp profile (<c>omp --profile=personal -c</c>), with the same no-break characters.</summary>
    public static string ResumeIn(this Agent a, string profile) =>
        a == Agent.Omp && profile.Length > 0
            ? $"{a.Command()}\u00A0-\u2060-\u2060profile={profile}\u00A0-\u2060c"
            : $"{a.Command()}\u00A0-\u2060c";

    /// <summary>What a session opened before PocketTerm was installed needs to load it, for text:
    /// Claude Code reloads its plugins in place, omp restarts on the same conversation (<see cref="Resume"/>).</summary>
    public static string PickUp(this Agent a) => a.PickUpIn("");

    /// <summary><see cref="PickUp"/> for a session in an omp profile.</summary>
    public static string PickUpIn(this Agent a, string profile) => a switch
    {
        Agent.Omp => a.ResumeIn(profile),
        _ => "/reload-plugins",
    };

    /// <summary>A prompt sent while it works steers the run (omp); Claude Code queues it until the run ends.</summary>
    public static bool Steers(this Agent a) => a == Agent.Omp;

    /// <summary>The name as it travels; omp for anything else (an older peer sends none).</summary>
    public static Agent Parse(string? name) => DartEnum.Parse<Agent>(name) ?? Agent.Omp;

    /// <summary><see cref="Parse(string?)"/> of a JSON value.</summary>
    public static Agent Parse(JsonNode? name) => Parse(DartJson.AsString(name));

    /// <summary>The agent a terminal window's foreground <paramref name="program"/> is, if it is one.</summary>
    public static Agent? OfProgram(string program) => DartEnum.Parse<Agent>(program);

    /// <summary>The session a terminal <paramref name="title"/> this agent set names: omp sets
    /// <c>π &gt; &lt;session name&gt;</c> (<c>&gt;</c> idle; <c>:</c> or a spinner frame working, <c>!</c>
    /// asking; <c>π: </c> with its title spinner off), the name being its folder's until the session has
    /// one. Null for a title it didn't set, and for Claude Code, whose title names nothing its sessions report.</summary>
    public static string? SessionOfTitle(this Agent a, string title)
    {
        if (a != Agent.Omp) return null;
        var m = OmpTitle().Match(title);
        return m.Success ? m.Groups[1].Value.Trim() : null;
    }

    /// <summary>Whether <paramref name="name"/> is a name omp takes for a profile (<c>omp --profile &lt;name&gt;</c>).</summary>
    public static bool IsOmpProfile(string name) => OmpProfileName().IsMatch(name) && !name.EndsWith('.');

    /// <summary>The omp profile a command line <paramref name="args"/> runs in, from its <c>--profile=&lt;name&gt;</c>
    /// or <c>--profile &lt;name&gt;</c> as omp reads them: the last one before <c>--</c>, <c>default</c> being none;
    /// '' for none, and for a name omp wouldn't take.</summary>
    public static string OmpProfileOfArgs(string args)
    {
        var words = Whitespace().Split(args);
        string? found = null;
        for (var i = 0; i < words.Length; i++)
        {
            var w = words[i];
            if (w == "--") break;
            if (w.StartsWith("--profile=", StringComparison.Ordinal)) found = w["--profile=".Length..];
            else if (w == "--profile" && i + 1 < words.Length) found = words[++i];
        }
        return found != null && found != "default" && IsOmpProfile(found) ? found : "";
    }

    // Dart's `$` is the very end (.NET's would also match before a final \n: \z here) and its `.`
    // stops at \r and \n too.
    [GeneratedRegex(@"^π(?:: | \S )([^\r\n\u2028\u2029]+)\z")]
    private static partial Regex OmpTitle();

    [GeneratedRegex(@"^[a-z0-9][a-z0-9._-]{0,63}\z")]
    private static partial Regex OmpProfileName();

    [GeneratedRegex(@"\s+")]
    private static partial Regex Whitespace();
}

/// <summary>
/// Where PocketTerm stands in a coding agent found on a computer, as the computer tells the phone
/// (the state's <c>agents</c>): its sessions report to PocketTerm only once it's <see cref="Installed"/>
/// and they started after that.
/// </summary>
public enum AgentIntegration
{
    /// <summary>Installed and the same as the app's copy.</summary>
    Installed,

    /// <summary>Installed, older than the app's copy.</summary>
    Outdated,

    /// <summary>Not installed, or the agent can't take it (Claude Code too old).</summary>
    Missing,

    /// <summary>Installed in Claude Code, which has mods (its plugins' runtime) turned off.</summary>
    Off,
}

/// <summary>The state's <c>agents</c> map.</summary>
public static class AgentIntegrations
{
    /// <summary>The state's <c>agents</c>: agent name to value; agents or values this side doesn't know are
    /// left out, and an older computer sends none (empty).</summary>
    public static Dictionary<Agent, AgentIntegration> ParseAll(JsonNode? json)
    {
        var all = new Dictionary<Agent, AgentIntegration>();
        if (json is not JsonObject o) return all;
        foreach (var (key, value) in o)
        {
            if (DartEnum.Parse<Agent>(key) is { } a && DartEnum.Parse<AgentIntegration>(value) is { } i) all[a] = i;
        }
        return all;
    }

    public static JsonObject ToJsonAll(IReadOnlyDictionary<Agent, AgentIntegration> agents)
    {
        var o = new JsonObject();
        foreach (var (key, value) in agents) o[key.Name()] = value.Name();
        return o;
    }
}
