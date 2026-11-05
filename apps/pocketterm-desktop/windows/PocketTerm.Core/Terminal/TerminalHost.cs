namespace PocketTerm.Core;

/// <summary>
/// One terminal app (or tmux) on this computer, behind the interface the bridge uses. Keys are
/// always those <see cref="Owns"/> accepts.
/// </summary>
public abstract class TerminalHost
{
    /// <summary>The key prefix family and the id in Settings: kitty, tmux, wezterm, iterm, ghostty.</summary>
    public abstract string Id { get; }

    /// <summary>How people name it: "WezTerm".</summary>
    public abstract string Label { get; }

    /// <summary>What its windows can do.</summary>
    public abstract IReadOnlySet<TermCap> Caps { get; }

    /// <summary>What a window of it can't do, said once for Settings and the phone (empty: nothing missing).</summary>
    public virtual string Limits => "";

    /// <summary>The name of its app in <c>lsappinfo visibleProcessList</c> (null: not an app).</summary>
    public abstract string? AppName { get; }

    /// <summary>Its app's bundle id, for keeping the front app (null: not an app).</summary>
    public virtual string? BundleId => null;

    public abstract bool Owns(string key);

    /// <summary>Is it installed / running / reachable; never launches it.</summary>
    public abstract Task<TermStatus> StatusAsync(Procs procs);

    /// <summary>Every window, in the app's order. Throws when the app can't be asked.</summary>
    public abstract Task<IReadOnlyList<TermWindow>> WindowsAsync(Procs procs);

    /// <summary>What the window shows now (with <paramref name="history"/>, its scrollback above too),
    /// line by line, with colors as ANSI escapes where it has them.</summary>
    public virtual Task<IReadOnlyList<string>> LinesAsync(string key, bool history = false) =>
        throw new TerminalException($"{Label} can't share its screen.");

    /// <summary>What the window shows now as plain text.</summary>
    public virtual Task<string> PlainScreenAsync(string key) =>
        throw new TerminalException($"{Label} can't share its screen.");

    /// <summary>The window's colors (<c>{fg, bg, palette}</c> as 0xRRGGBB), when the app tells.</summary>
    public virtual Task<Dictionary<string, object>?> ColorsAsync(string key) =>
        Task.FromResult<Dictionary<string, object>?>(null);

    /// <summary>Types <paramref name="text"/> as keystrokes (not as a paste), without Enter.</summary>
    public virtual Task TypeAsync(string key, string text) =>
        throw new TerminalException($"{Label} can't type into its windows.");

    /// <summary>Presses <paramref name="names"/> in order: kitty's key names (<see cref="Terminal.KeyBytes"/> knows them).</summary>
    public virtual Task PressKeysAsync(string key, IReadOnlyList<string> names) =>
        throw new TerminalException($"{Label} can't press keys in its windows.");

    /// <summary>
    /// Types <paramref name="text"/>, a line break (<c>\n</c>, <c>\r\n</c> or <c>\r</c>: a lone CR
    /// typed would be Enter, running a half-written line) as Shift+Enter (a new line in an agent's
    /// editor; a shell runs the line), then Enter if <paramref name="enter"/>.
    /// </summary>
    public virtual async Task SendAsync(string key, string text, bool enter)
    {
        var lines = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            if (i > 0) await PressKeysAsync(key, ["shift+enter"]);
            if (lines[i].Length > 0) await TypeAsync(key, lines[i]);
        }
        if (enter) await PressKeysAsync(key, ["enter"]);
    }

    /// <summary>Closes the window and what runs in it.</summary>
    public virtual Task CloseAsync(string key) => throw new TerminalException($"{Label} can't close its windows.");

    /// <summary>
    /// A new window in <paramref name="cwd"/> running the login shell, or <paramref name="command"/>
    /// (argv) instead; or, with <paramref name="into"/> (one of this app's <see cref="TermWindow.OsWindow"/>s),
    /// a new tab in that window, and a new window when that one is gone. Its key. Never takes the
    /// focus where the app allows.
    /// </summary>
    public abstract Task<string> LaunchAsync(string cwd, IReadOnlyList<string>? command = null, string? into = null);
}
