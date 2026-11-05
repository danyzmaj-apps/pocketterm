using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PocketTerm.App.Views;
using PocketTerm.Core;
using PocketTerm.Desktop;

namespace PocketTerm.App.Components;

/// <summary>Asking before something is installed on this computer (confirm_install.dart).</summary>
internal static class ConfirmInstall
{
    /// <summary>
    /// Asks before something is installed on this computer: <paramref name="title"/>, why it's needed
    /// (<paramref name="why"/>), what it changes (<paramref name="what"/>, with <paramref name="command"/> shown as
    /// typed when there is one) and how to take it out again (<paramref name="undo"/>). True once the person pressed
    /// <paramref name="action"/>; nothing is installed without it.
    /// </summary>
    public static async Task<bool> ShowAsync(
        string title,
        string why,
        string what,
        string? command = null,
        string? undo = null,
        string action = "Install")
    {
        var whyText = Ui.Text(why);
        whyText.TextWrapping = TextWrapping.Wrap;
        var whatText = Ui.Dim(what);
        whatText.TextWrapping = TextWrapping.Wrap;
        var content = Ui.Stack(12, whyText, whatText, command == null ? null : new CodeBlock(command, "confirm-install-command"));
        if (undo != null)
        {
            var undoText = Ui.Dim(undo);
            undoText.FontSize = 12;
            undoText.TextWrapping = TextWrapping.Wrap;
            content.Children.Add(undoText);
        }
        content.MaxWidth = 420;
        var dialog = new ContentDialog
        {
            Title = title,
            Content = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            PrimaryButtonText = action,
            CloseButtonText = "Not now",
            DefaultButton = ContentDialogButton.Primary,
        }.Id("confirm-install");
        dialog.Opened += (_, _) => IdPart(dialog, "PrimaryButton", "confirm-install-go");
        return await Dialogs.ShowAsync(dialog) == ContentDialogResult.Primary;
    }

    /// <summary>
    /// <see cref="ShowAsync"/> for PocketTerm going into <paramref name="agent"/> (<paramref name="update"/>:
    /// replacing an older copy there), with where <paramref name="integrations"/> puts it shown below
    /// <paramref name="home"/> as <c>~</c>.
    /// </summary>
    public static Task<bool> AgentAsync(Agent agent, Integrations integrations, string home, bool update = false)
    {
        var name = Integrations.Name(agent);
        string Tilde(string dir)
        {
            var relative = Path.GetRelativePath(home, dir);
            var within = relative != "." && !relative.StartsWith("..", StringComparison.Ordinal) && !Path.IsPathRooted(relative);
            return within ? $"~/{relative.Replace('\\', '/')}" : dir;
        }
        var verb = update ? "Update" : "Install";
        IReadOnlyList<string> ompDirs = agent == Agent.Omp ? integrations.OmpDirs : [];
        return ShowAsync(
            title: $"{verb} PocketTerm in {name}?",
            action: verb,
            why: update
                ? $"The copy of PocketTerm in {name} is older than this app. Updating it keeps your phone working with " +
                    $"your {name} sessions."
                : $"So your phone sees your {name} sessions as conversations, not just their screen: read the replies, " +
                    $"answer questions and approvals, and get a notification when a run finishes. Without it, {name} " +
                    "windows show on your phone only as a screen.",
            what: agent switch
            {
                Agent.Omp =>
                    $"{(update ? "Replaces" : "Copies")} PocketTerm\u2019s omp extension (pocketterm-live.ts) " +
                    $"{(update ? "in" : "into")} {string.Join(" and ", ompDirs.Select(Tilde))}. Open omp sessions load it once you " +
                    $"restart them with {agent.Resume()}.",
                _ =>
                    $"{(update ? "Replaces" : "Copies")} PocketTerm\u2019s Claude Code plugin " +
                    $"{(update ? "in" : "to")} {Tilde(integrations.ClaudeDir)} and has Claude Code " +
                    $"{(update ? "update" : "install")} it. Open Claude Code sessions load it when you type " +
                    $"{agent.PickUp()}.",
            },
            command: agent switch
            {
                Agent.Omp => null,
                _ => update
                    ? "claude plugin marketplace update pocketterm\nclaude plugin update pocketterm@pocketterm"
                    : $"claude plugin marketplace add {Tilde(integrations.ClaudeDir)}\n" +
                        "claude plugin install pocketterm@pocketterm",
            },
            undo: agent switch
            {
                Agent.Omp =>
                    $"To take it out later, delete pocketterm-live.ts from {(ompDirs.Count > 1 ? "those folders" : "that folder")}.",
                _ => "To take it out later, run claude plugin uninstall pocketterm@pocketterm.",
            });
    }

    /// <summary>Gives the dialog's template part <paramref name="part"/> (its PrimaryButton, say) an AutomationId:
    /// the template builds those buttons, so they are found once it's open.</summary>
    internal static void IdPart(ContentDialog dialog, string part, string id)
    {
        if (Find(dialog, part) is { } element) element.Id(id);
    }

    private static FrameworkElement? Find(DependencyObject root, string name)
    {
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < count; i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is FrameworkElement f && f.Name == name) return f;
            if (Find(child, name) is { } found) return found;
        }
        return null;
    }
}
