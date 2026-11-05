using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using PocketTerm.App.Views;
using PocketTerm.Desktop;

namespace PocketTerm.App.Components;

/// <summary>
/// A button that runs <c>argv</c> for the person, after they read what it does (<c>what</c>) and the command
/// itself, and confirmed it: never on its own. While it runs, it says so; then Done, or what went wrong and Try
/// again. (The Mac's password note has no Windows counterpart: winget asks through Windows' own prompt.)
/// </summary>
internal sealed class ConfirmedCommand : View
{
    private enum RunState
    {
        Idle,
        Running,
        Done,
        Failed,
    }

    private readonly Commands _commands;
    private readonly string _label;
    private readonly IReadOnlyList<string> _argv;
    private readonly string _what;
    private readonly Action? _onDone;
    private readonly Button _button;
    private readonly TextBlock _failed;
    private readonly ContentPresenter _host = new();
    private readonly UIElement _running;
    private readonly UIElement _done;
    private readonly UIElement _failure;
    private RunState _state = RunState.Idle;

    /// <param name="commands">What runs it.</param>
    /// <param name="label">The button's words: what it gets done ("Install Tailscale").</param>
    /// <param name="argv">The program and its arguments.</param>
    /// <param name="what">What running it does, a sentence or two, shown before it runs.</param>
    /// <param name="onDone">It went through.</param>
    public ConfirmedCommand(Commands commands, string label, IReadOnlyList<string> argv, string what, Action? onDone = null)
    {
        _commands = commands;
        _label = label;
        _argv = argv;
        _what = what;
        _onDone = onDone;
        _button = Ui.Button(label, () => Run(ConfirmAsync), $"command-{argv[^1]}");
        _running = Ui.Row(
            8,
            new ProgressRing { IsActive = true, Width = 14, Height = 14 },
            Ui.Dim($"Running {Command}…"));
        _done = Ui.Row(6, Ui.Icon(Ui.Glyph.Check, 14, "PtOkIcon"), Ui.Dim("Done").Id("command-done"));
        _failed = Ui.Text("", TextKind.Error).Selectable().Id("command-failed");
        var again = Ui.Button("Try again", () => Run(ConfirmAsync), $"command-{argv[^1]}");
        _failure = Ui.Stack(6, _failed, again);
        Content = _host;
        OnRefresh(() => _host.Content = _state switch
        {
            RunState.Running => _running,
            RunState.Done => _done,
            RunState.Failed => _failure,
            _ => _button,
        });
    }

    private string Command => string.Join(' ', _argv);

    private async Task ConfirmAsync()
    {
        var dialog = new ContentDialog
        {
            Title = _label,
            Content = Ui.Stack(
                12,
                Ui.Text(_what),
                Ui.Dim("PocketTerm will run:"),
                new CodeBlock(Command, "command-shown")),
            PrimaryButtonText = "Run",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        dialog.Opened += (_, _) => Find(dialog, "PrimaryButton")?.Id("command-run");
        if (await Dialogs.ShowAsync(dialog) == ContentDialogResult.Primary) await RunItAsync();
    }

    private async Task RunItAsync()
    {
        _state = RunState.Running;
        Refresh();
        CommandResult result;
        try
        {
            result = await _commands.RunAsync(_argv);
        }
        catch (Exception e)
        {
            result = new CommandResult(null, e.Message);
        }
        if (!Live) return;
        var ok = result.Code == 0;
        _state = ok ? RunState.Done : RunState.Failed;
        var lines = result.Output.Trim().Split('\n').Where(l => l.Trim().Length > 0).ToList();
        var last = string.Join('\n', lines.Skip(lines.Count > 3 ? lines.Count - 3 : 0));
        _failed.Text = $"That didn’t work:\n{(last.Length == 0 ? $"It stopped with code {result.Code?.ToString() ?? "null"}." : last)}";
        Refresh();
        if (ok) _onDone?.Invoke();
    }

    /// <summary>The dialog template's part <paramref name="name"/> (its buttons carry no AutomationId of their own).</summary>
    private static Button? Find(DependencyObject root, string name)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is Button { Name: var n } b && n == name) return b;
            if (Find(child, name) is { } found) return found;
        }
        return null;
    }
}
