using System.Text.Json.Nodes;

namespace PocketTerm.Core;

// The computer's terminals as the phone reaches them: one TerminalHost per terminal app (kitty,
// WezTerm, iTerm2, Ghostty) or multiplexer (tmux), each with what its scripting can do (TermCap).
// A window's key starts with its host's prefix and fits the push function's session keys,
// `[\w.:/-]{1,64}`:
//
//   kitty      kitty-<pid>/<window id>       (the socket's name, as before)
//   tmux       tmux:<socket name>/<pane n>   (%n is the pane)
//   wezterm    wezterm:<gui pid>/<pane id>
//   ghostty    ghostty:<terminal UUID>
//   iterm      iterm:<session UUID>          (ITERM_SESSION_ID's)

/// <summary>What a window's terminal lets the phone do with it.</summary>
public enum TermCap
{
    /// <summary>Its screen can be read (as text, with colors if <see cref="Ansi"/>).</summary>
    Read,

    /// <summary>Its screen comes with its colors as ANSI escapes.</summary>
    Ansi,

    /// <summary>Text can be typed without Enter, and Enter and Shift+Enter pressed.</summary>
    Type,

    /// <summary>A line can be typed and run (Enter after it).</summary>
    Line,

    /// <summary>Keys can be pressed: arrows, Esc, Tab, Ctrl+C, digits.</summary>
    Keys,

    /// <summary>It can be closed.</summary>
    Close,
}

/// <summary>Sets of <see cref="TermCap"/>.</summary>
public static class TermCaps
{
    /// <summary>Everything, as an older Mac's windows (kitty's) could.</summary>
    public static readonly IReadOnlySet<TermCap> All =
        new HashSet<TermCap> { TermCap.Read, TermCap.Ansi, TermCap.Type, TermCap.Line, TermCap.Keys, TermCap.Close };
}

/// <summary>
/// One terminal window (a tab, a pane, a split: whatever the app calls the thing a shell runs in),
/// as the phone sees it. <see cref="OsWindow"/> and <see cref="TabId"/> say where it sits on the
/// computer: the app's window (Cmd+N) and the tab in it.
/// </summary>
public sealed record TermWindow
{
    /// <summary>The host's prefix, then which window of which instance.</summary>
    public required string Key { get; init; }

    public required string Title { get; init; }

    /// <summary>The tab's title.</summary>
    public required string Tab { get; init; }

    /// <summary>The foreground program's working directory.</summary>
    public required string Cwd { get; init; }

    /// <summary>The foreground program's name: <c>omp</c>, <c>claude</c>, <c>zsh</c>, <c>nvim</c>.</summary>
    public required string Program { get; init; }

    /// <summary>The window its app has focused.</summary>
    public bool Focused { get; init; }

    /// <summary>Its host's id: kitty, tmux, wezterm, iterm, ghostty.</summary>
    public string App { get; init; } = "kitty";

    public IReadOnlySet<TermCap> Caps { get; init; } = TermCaps.All;

    /// <summary>The terminal app a tmux pane shows in (its client's), by label.</summary>
    public string Via { get; init; } = "";

    /// <summary>Its tty (<c>ttys012</c>), when the app says; the computer's own business.</summary>
    public string Tty { get; init; } = "";

    /// <summary>
    /// The app window it is in (what Cmd+N opens), unique across apps and starting with the app's
    /// key prefix (<c>kitty-123/os2</c>); empty when the app doesn't tell (an older Mac). A tmux pane
    /// a terminal app shows carries that app's window; a pane no app shows, its tmux session's.
    /// </summary>
    public string OsWindow { get; init; } = "";

    /// <summary>The tab it is in, unique across apps like <see cref="OsWindow"/>; empty when unknown.
    /// Panes split in one tab share it.</summary>
    public string TabId { get; init; } = "";

    /// <summary>The omp profile its foreground omp runs, from its command line; '' for the default,
    /// for anything else, or where no tty tells.</summary>
    public string Profile { get; init; } = "";

    /// <summary>The coding agent running in it, if one is.</summary>
    public Agent? Agent => Agents.OfProgram(Program);

    public bool Can(TermCap cap) => Caps.Contains(cap);

    public static TermWindow FromJson(JsonObject j)
    {
        HashSet<TermCap>? caps = null;
        if (j["caps"] is JsonArray list)
        {
            caps = [];
            foreach (var c in list)
            {
                if (DartEnum.Parse<TermCap>(c) is { } cap) caps.Add(cap);
            }
        }
        return new TermWindow
        {
            Key = Field(j, "key") ?? throw new InvalidCastException("TermWindow: key is not a String"),
            Title = Field(j, "title") ?? "",
            Tab = Field(j, "tab") ?? "",
            Cwd = Field(j, "cwd") ?? "",
            Program = Field(j, "program") ?? "",
            Focused = DartJson.AsBool(j["focused"]) == true,
            // An older Mac lists only kitty, which can do everything.
            App = Field(j, "app") ?? "kitty",
            Caps = caps ?? TermCaps.All,
            Via = Field(j, "via") ?? "",
            OsWindow = Field(j, "osWindow") ?? "",
            TabId = Field(j, "tabId") ?? "",
            Profile = Field(j, "profile") ?? "",
        };
    }

    /// <summary>Dart's <c>j[key] as String?</c>: null when absent, a cast error when not a string.</summary>
    internal static string? Field(JsonObject j, string key)
    {
        var v = j[key];
        if (v is null) return null;
        return DartJson.AsString(v) ?? throw new InvalidCastException($"{key} is not a String");
    }

    public JsonObject ToJson()
    {
        var caps = new JsonArray();
        foreach (var c in Enum.GetValues<TermCap>())
        {
            if (Caps.Contains(c)) caps.Add(c.Name());
        }
        var o = new JsonObject
        {
            ["key"] = Key,
            ["title"] = Title,
            ["tab"] = Tab,
            ["cwd"] = Cwd,
            ["program"] = Program,
            ["focused"] = Focused,
            ["app"] = App,
            ["caps"] = caps,
        };
        if (Via.Length > 0) o["via"] = Via;
        if (OsWindow.Length > 0) o["osWindow"] = OsWindow;
        if (TabId.Length > 0) o["tabId"] = TabId;
        if (Profile.Length > 0) o["profile"] = Profile;
        return o;
    }
}

/// <summary>Where a session the phone starts opens on the computer (the computer's setting).</summary>
public enum Placement
{
    /// <summary>A new tab in the app window that holds the project's tabs (the most of them); a new
    /// window when none does.</summary>
    ProjectWindow,

    /// <summary>A new app window each time.</summary>
    NewWindow,
}

/// <summary><see cref="Placement"/>'s members.</summary>
public static class Placements
{
    /// <summary>As the phone shows it after "Opens in kitty": "as a tab in the project's window".</summary>
    public static string Describe(this Placement p) => p switch
    {
        Placement.ProjectWindow => "as a tab in the project's window",
        _ => "in a new window",
    };
}

/// <summary>
/// A window the phone had opened: its <c>window</c> key, and <c>where</c> it went on the computer as
/// the phone says it ("a new tab in the kitty window with wrkly"); empty from one that doesn't say.
/// </summary>
public readonly record struct Opened(string Window, string Where);

/// <summary>Something a terminal couldn't do, said the way the phone shows it.</summary>
public class TerminalException(string message) : Exception(message)
{
    public override string ToString() => Message;
}

/// <summary>How a terminal stands, for Settings → Terminal.</summary>
public enum TermState
{
    /// <summary>Usable: the phone sees its windows and can do what its caps say.</summary>
    Ready,

    /// <summary>Usable, but its scripting can't do everything (<see cref="TermStatus.Note"/> says what's missing).</summary>
    Limited,

    /// <summary>Installed, and needs one thing done first (<see cref="TermStatus.Fix"/>).</summary>
    Setup,

    /// <summary>Installed and not running: nothing to list now.</summary>
    Idle,

    /// <summary>Not on this computer.</summary>
    Missing,
}

/// <summary>The one-click fixes Settings offers.</summary>
public enum TermFix
{
    /// <summary>Append kitty's remote control lines to kitty.conf (then restart kitty).</summary>
    KittyConfig,

    /// <summary>Open System Settings → Privacy &amp; Security → Automation.</summary>
    Automation,

    /// <summary>Open the terminal's install page (WezTerm on Windows).</summary>
    Install,
}

/// <summary>A terminal's state, for Settings and the phone.</summary>
public sealed record TermStatus(string Id, string Label, TermState State, string Note = "", TermFix? Fix = null)
{
    /// <summary>As the phone gets it in the bridge's state (without <see cref="Fix"/>, which only
    /// Settings on the computer offers); an unknown state reads as limited.</summary>
    public static TermStatus FromJson(JsonObject j) => new(
        TermWindow.Field(j, "id") ?? "",
        TermWindow.Field(j, "label") ?? "",
        DartEnum.Parse<TermState>(j["state"]) ?? TermState.Limited,
        Note: TermWindow.Field(j, "note") ?? "");

    public bool Usable => State is TermState.Ready or TermState.Limited;

    public JsonObject ToJson() => new()
    {
        ["id"] = Id,
        ["label"] = Label,
        ["state"] = State.Name(),
        ["note"] = Note,
    };
}

/// <summary>A terminal window's text as the phone has it: version <see cref="V"/> of its
/// <see cref="Lines"/> (ANSI), and how many lines have scrolled off the top since the phone first
/// saw it (<see cref="Base"/>), so a view can keep its place while it scrolls.</summary>
public sealed record TermScreen(int V, IReadOnlyList<string> Lines, int Base);

/// <summary>A file a prompt takes along, as it is: its name and type go inside the sealed request,
/// its bytes sealed in a blob.</summary>
public sealed record PromptFile(string Name, string Mime, byte[] Bytes);
