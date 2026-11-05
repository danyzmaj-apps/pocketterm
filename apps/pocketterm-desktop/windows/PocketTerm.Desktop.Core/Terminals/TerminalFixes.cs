using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>
/// A terminal's one-click fix (<see cref="TermStatus.Fix"/>) as Settings and the setup checklist offer
/// it, and which terminals still need the person. On Windows the one fix is WezTerm's install
/// (<see cref="WezTermSetup"/>); the Mac's (kitty's lines added to kitty.conf, System Settings opened
/// where Automation is allowed) belong to the Mac's hosts, which the macOS app has.
/// </summary>
public static class TerminalFixes
{
    /// <summary>
    /// Settings' one click for <paramref name="s"/>: WezTerm's installer fetched, checked and opened
    /// (<see cref="WezTermSetup.InstallAsync"/>; the task ends with it, Settings needn't wait — its
    /// progress is the setup's own note). What to tell the person next, and whether the fix failed (its
    /// button stays to try again): nothing to say for the install, which speaks for itself.
    /// </summary>
    /// <exception cref="PlatformNotSupportedException">A Mac terminal's fix, which no host here reports.</exception>
    public static async Task<(string Note, bool Failed)> FixTerminalAsync(TermStatus s, WezTermSetup? wezterm)
    {
        switch (s.Fix)
        {
            case TermFix.Install:
                if (wezterm != null) await wezterm.InstallAsync();
                return ("", false);
            case null:
                return ("", false);
            default:
                throw new PlatformNotSupportedException($"{s.Label}'s fix is the Mac's.");
        }
    }

    /// <summary>The terminals the phone can't reach until the person acts: one that needs setup or a
    /// permission, WezTerm not installed on Windows.</summary>
    public static List<TermStatus> TerminalsNeedingSetup(IEnumerable<TermStatus> statuses) =>
        statuses.Where(s => s.State == TermState.Setup || (s.Fix == TermFix.Install && s.State == TermState.Missing)).ToList();

    /// <summary>No terminal app the phone could use is installed (tmux alone isn't one); WezTerm to install
    /// on Windows counts, <see cref="TerminalsNeedingSetup"/> has it.</summary>
    public static bool NoTerminalApp(IEnumerable<TermStatus> statuses) =>
        !statuses.Any(s => s.Id != "tmux" && (s.State != TermState.Missing || s.Fix == TermFix.Install));
}
