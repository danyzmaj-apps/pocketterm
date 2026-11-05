using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Views;
using PocketTerm.Core;
using PocketTerm.Desktop;

namespace PocketTerm.App.Components;

/// <summary>
/// An agent session opened before PocketTerm was in its agent: where it runs, and what to type there to pick
/// PocketTerm up (<see cref="Agents.PickUp"/>) with a button that copies it. The setup checklist and Settings list
/// these.
/// </summary>
internal sealed class SessionToPickUp : View
{
    private readonly Terminals _terminals;
    private readonly TextBlock _where;
    private readonly CodeBlock _command;
    private readonly Button _copy;
    private readonly FontIcon _copyIcon;
    private TermWindow _window;

    /// <summary>The command was copied: the button says so.</summary>
    private bool _copied;

    public SessionToPickUp(TermWindow window, Terminals terminals)
    {
        _window = window;
        _terminals = terminals;
        _where = Ui.Text("");
        _where.TextWrapping = TextWrapping.Wrap;
        _command = new CodeBlock("");
        _command.TextElement.TextWrapping = TextWrapping.NoWrap;
        _copyIcon = Ui.Icon(Ui.Glyph.Copy, 14);
        _copy = new Button { Content = _copyIcon, Padding = new Thickness(8, 6, 8, 6) }.Id("pick-up-copy");
        _copy.Click += (_, _) =>
        {
            Ui.Copy(Typed(_window));
            _copied = true;
            Refresh();
        };
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = Ui.Icon(Ui.Glyph.Refresh, 16, "PtWarnIcon");
        icon.VerticalAlignment = VerticalAlignment.Center;
        _where.VerticalAlignment = VerticalAlignment.Center;
        _command.VerticalAlignment = VerticalAlignment.Center;
        _copy.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(icon);
        Grid.SetColumn(_where, 1);
        grid.Children.Add(_where);
        Grid.SetColumn(_command, 2);
        grid.Children.Add(_command);
        Grid.SetColumn(_copy, 3);
        grid.Children.Add(_copy);
        Content = grid;
        OnRefresh(Show);
    }

    /// <summary>The same session as it is now (its folder, its profile may change).</summary>
    public void Update(TermWindow window)
    {
        if (window == _window) return;
        _window = window;
        Refresh();
    }

    private void Show()
    {
        var w = _window;
        if (w.Agent is not { } agent) return;
        var cwd = Tilde(w.Cwd, _terminals.Home);
        var where = new List<string>();
        if (w.Cwd.Length > 0) where.Add($"in {cwd}");
        where.Add(_terminals.Hosts.FirstOrDefault(h => h.Id == w.App)?.Label ?? w.App);
        _where.Text = $"{Integrations.Name(agent)} {string.Join(" · ", where)}";
        _command.Text = agent.PickUpIn(w.Profile);
        var tip = _copied ? "Copied" : "Copy";
        ToolTipService.SetToolTip(_copy, tip);
        AutomationProperties.SetName(_copy, tip);
        _copyIcon.Glyph = _copied ? Ui.Glyph.Check : Ui.Glyph.Copy;
        _copyIcon.Style = Ui.Style(_copied ? "PtOkIcon" : "PtDimIcon");
    }

    /// <summary>As typed: the no-break characters keep it whole on screen, not in a terminal.</summary>
    private static string Typed(TermWindow w) =>
        w.Agent is { } agent ? agent.PickUpIn(w.Profile).Replace('\u00A0', ' ').Replace("\u2060", "") : "";

    /// <summary><paramref name="path"/> with <paramref name="home"/> as <c>~</c>.</summary>
    public static string Tilde(string path, string home)
    {
        if (path == home) return "~";
        var parent = home.TrimEnd('\\', '/');
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var within = parent.Length > 0 && path.Length > parent.Length + 1 && path.StartsWith(parent, comparison) &&
            path[parent.Length] is '\\' or '/';
        return within ? $"~{path[parent.Length..]}" : path;
    }
}
