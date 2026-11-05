using System.Text.Json.Nodes;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>The bridge's pure helpers (Dart terminal_bridge.dart's top-level functions).</summary>
public static class BridgeHelpers
{
    /// <summary>The terminals the phone hears about: the installed ones, and tmux either way (its note says how to get
    /// it).</summary>
    public static List<TermStatus> PhoneTerminals(IReadOnlyList<TermStatus> statuses) =>
        statuses.Where(s => s.State != TermState.Missing || s.Id == "tmux").ToList();

    /// <summary>The phone's error line: only when <paramref name="nothingShown"/> (no window, no session) and no
    /// terminal is usable, what the first one needing setup says.</summary>
    public static string? TerminalsError(IReadOnlyList<TermStatus> statuses, bool nothingShown) =>
        nothingShown && !statuses.Any(s => s.Usable)
            ? statuses.Where(s => s.State == TermState.Setup).Select(s => s.Note).FirstOrDefault()
            : null;

    /// <summary>Why an agent's ask in <paramref name="window"/> can't be answered from the phone (null: it can):
    /// answering reads the screen and presses keys.</summary>
    public static string? CantAnswer(Terminals terms, string window)
    {
        var read = terms.Can(window, TermCap.Read);
        if (read && terms.Can(window, TermCap.Keys)) return null;
        var label = terms.HostOf(window)?.Label ?? "This terminal";
        // No tmux host on Windows: Dart's `terms.tmux?.installed ?? false` is false there.
        return $"{label} can't {(read ? "press keys" : "show its screen")}, so answer this on the computer. "
            + "With tmux installed (Homebrew: brew install tmux, or MacPorts: sudo port install tmux), sessions you start from the phone can.";
    }

    /// <summary>Why a slash command for the session in <paramref name="window"/> can't be run from the phone (null:
    /// it can): the agent's editor reads commands, so they're typed into its terminal window.</summary>
    public static string? CantCommand(Terminals terms, string? window)
    {
        if (window == null)
        {
            return "Slash commands are typed into the agent's terminal window, and PocketTerm can't reach this one: it isn't in "
                + "kitty, tmux, WezTerm, iTerm2 or Ghostty. Run it on the computer.";
        }
        if (terms.Can(window, TermCap.Line)) return null;
        return $"{terms.HostOf(window)?.Label ?? "This terminal"} can't take a typed line, so run the command on the computer.";
    }

    /// <summary>Whether <paramref name="window"/>'s screen changes over <paramref name="gap"/> (2 s by default): the
    /// agent in it is at work (a spinner, a clock, output). Where the terminal can't show its screen, its title, read
    /// a few times over the gap: an agent at work spins there too.</summary>
    public static async Task<bool> ScreenChangesAsync(Terminals terms, string window, TimeSpan? gap = null)
    {
        var g = gap ?? TimeSpan.FromSeconds(2);
        if (!terms.Can(window, TermCap.Read))
        {
            async Task<string?> Title() => (await terms.WindowsAsync().ConfigureAwait(false)).FirstOrDefault(w => w.Key == window)?.Title;
            var first = await Title().ConfigureAwait(false) ?? throw new TerminalException("That window has closed.");
            for (var i = 0; i < 4; i++)
            {
                await Task.Delay(g / 4).ConfigureAwait(false);
                if (await Title().ConfigureAwait(false) is { } t && t != first) return true;
            }
            return false;
        }
        var before = await terms.PlainScreenAsync(window).ConfigureAwait(false);
        await Task.Delay(g).ConfigureAwait(false);
        return await terms.PlainScreenAsync(window).ConfigureAwait(false) != before;
    }

    /// <summary>The omp profile a phone's <c>launch</c>/<c>create</c> asks for: '' for none asked or another agent;
    /// one this computer doesn't have is refused (it's typed into a shell, so only a listed name goes).</summary>
    public static string LaunchProfile(JsonNode? requested, Agent agent, IReadOnlyList<string> profiles)
    {
        if (DartJson.AsString(requested) is not { Length: > 0 } name || agent != Agent.Omp) return "";
        if (!profiles.Contains(name)) throw new TerminalException($"omp has no profile {name} on this computer.");
        return name;
    }

    /// <summary>
    /// Switches <paramref name="agent"/> in <paramref name="window"/> (an agent window no live session claims) to
    /// reporting its session to PocketTerm. omp quits and starts again on the same conversation: Esc stops a run,
    /// Ctrl+C empties its editor (Ctrl+U clears one line only), Ctrl+D on an empty editor quits; once the foreground
    /// program on <paramref name="tty"/> isn't omp anymore (or after <paramref name="noTty"/>, where the terminal
    /// tells no tty) the shell gets <c>omp -c</c>, in the omp <paramref name="profile"/> it ran in. Claude Code
    /// reloads its plugins in place. Where the tty tells, nothing is pressed unless the agent still runs there: it may
    /// have quit since the phone last looked, and Ctrl+D would end the shell (and close the window) instead.
    /// Defaults: settle 400 ms, quitFor 8 s, noTty 2 s, pollEvery 250 ms.
    /// </summary>
    public static async Task SwitchToConversationAsync(
        Terminals terms,
        string window,
        Agent agent,
        string tty = "",
        string profile = "",
        TimeSpan? settle = null,
        TimeSpan? quitFor = null,
        TimeSpan? noTty = null,
        TimeSpan? pollEvery = null)
    {
        var settleFor = settle ?? TimeSpan.FromMilliseconds(400);
        if (!terms.Can(window, TermCap.Keys) || !terms.Can(window, TermCap.Type))
        {
            throw new TerminalException(
                $"{terms.HostOf(window)?.Label ?? "This terminal"} can't press keys and type here, so switch it on the computer.");
        }
        async Task<bool> Runs() =>
            Agents.OfProgram((await terms.SnapshotAsync().ConfigureAwait(false)).Foreground(tty)?.Program ?? "") == agent;
        if (tty.Length > 0 && !await Runs().ConfigureAwait(false))
        {
            throw new TerminalException($"{agent.Label()} isn't running in that window anymore.");
        }
        switch (agent)
        {
            case Agent.Claude:
                await terms.SendAsync(window, "/reload-plugins", enter: true).ConfigureAwait(false);
                break;
            case Agent.Omp:
                await terms.PressKeysAsync(window, ["esc"]).ConfigureAwait(false);
                await Task.Delay(settleFor).ConfigureAwait(false);
                await terms.PressKeysAsync(window, ["ctrl+c"]).ConfigureAwait(false);
                await Task.Delay(settleFor).ConfigureAwait(false);
                await terms.PressKeysAsync(window, ["ctrl+d"]).ConfigureAwait(false);
                if (tty.Length == 0)
                {
                    await Task.Delay(noTty ?? TimeSpan.FromSeconds(2)).ConfigureAwait(false);
                }
                else
                {
                    var until = DateTime.UtcNow + (quitFor ?? TimeSpan.FromSeconds(8));
                    while (await Runs().ConfigureAwait(false))
                    {
                        if (DateTime.UtcNow > until)
                        {
                            throw new TerminalException(
                                $"omp didn't quit. Quit it on the computer, then run {agent.CommandIn(profile)} -c there.");
                        }
                        await Task.Delay(pollEvery ?? TimeSpan.FromMilliseconds(250)).ConfigureAwait(false);
                    }
                }
                await terms.SendAsync(window, $"{agent.CommandIn(profile)} -c", enter: true).ConfigureAwait(false);
                break;
        }
    }
}

/// <summary>
/// The requests phones sent lately, by id, and their answers. A phone that heard no answer (its app went to the
/// background, the network dropped) sends the same request again under the same id: it gets the answer it missed
/// (marked <c>repeat</c>) instead of the request running twice; one still running is answered once it ends.
/// Thread-safe (one lock).
/// </summary>
public sealed class RunLog(TimeSpan? keep = null, Func<DateTime>? clock = null)
{
    private readonly Func<DateTime> _clock = clock ?? (() => DateTime.UtcNow);
    private readonly Dictionary<string, (DateTime At, JsonObject? Ran)> _runs = [];

    /// <summary>How long a request's answer is kept for a repeat (2 minutes).</summary>
    public TimeSpan Keep { get; } = keep ?? TimeSpan.FromMinutes(2);

    /// <summary>Whether request <paramref name="id"/> is new, and then taken as running; for one that already ran,
    /// its answer goes to <paramref name="again"/>.</summary>
    public bool Start(string id, Action<JsonObject> again)
    {
        JsonObject? repeat = null;
        lock (_runs)
        {
            var now = _clock();
            foreach (var old in _runs.Where(r => now - r.Value.At > Keep).Select(r => r.Key).ToList()) _runs.Remove(old);
            if (_runs.TryGetValue(id, out var r))
            {
                if (r.Ran is { } ran)
                {
                    repeat = (JsonObject)ran.DeepClone();
                    repeat["repeat"] = true;
                }
            }
            else
            {
                _runs[id] = (now, null);
                return true;
            }
        }
        if (repeat != null) again(repeat);
        return false;
    }

    /// <summary>Request <paramref name="id"/> ended with <paramref name="ran"/>.</summary>
    public void Done(string id, JsonObject ran)
    {
        lock (_runs) _runs[id] = (_clock(), (JsonObject)ran.DeepClone());
    }
}

/// <summary>One session's screen followed for pickers: when it was last told to look soon (a command, an answer, a
/// key) and last saw a change, and what the phone typed into the current picker's search. Thread-safe.</summary>
internal sealed class MenuWatch
{
    private readonly object _gate = new();
    private DateTime _armed = DateTime.UtcNow;
    private DateTime _changed = DateTime.UtcNow;
    private string _query = "";
    private TaskCompletionSource? _wake;

    public DateTime Armed
    {
        get { lock (_gate) return _armed; }
    }

    public DateTime Changed
    {
        get { lock (_gate) return _changed; }
        set { lock (_gate) _changed = value; }
    }

    public string Query
    {
        get { lock (_gate) return _query; }
        set { lock (_gate) _query = value; }
    }

    /// <summary>Reads soon again, for a while.</summary>
    public void Arm()
    {
        lock (_gate) _armed = _changed = DateTime.UtcNow;
        Wake();
    }

    public void Wake()
    {
        TaskCompletionSource? c;
        lock (_gate)
        {
            c = _wake;
            _wake = null;
        }
        c?.TrySetResult();
    }

    /// <summary>Waits <paramref name="d"/>, or less if woken.</summary>
    public async Task SleepAsync(TimeSpan d)
    {
        var c = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_gate) _wake = c;
        using var cancel = new CancellationTokenSource();
        await Task.WhenAny(c.Task, Task.Delay(d, cancel.Token)).ConfigureAwait(false);
        cancel.Cancel();
    }
}
