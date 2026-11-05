using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Views;

namespace PocketTerm.App.Components;

/// <summary>
/// A command to type, with a button that copies it (and says so: Copied, with a check). The <c>id</c> given names
/// the command's text; its button is <c>&lt;id&gt;-copy</c>.
/// </summary>
internal sealed class CopyCommand : View
{
    private readonly CodeBlock _code;
    private readonly Button _copy;
    private bool _copied;

    public CopyCommand(string command, string? id = null)
    {
        _code = new CodeBlock(command, id);
        _copy = new Button { Padding = new Thickness(8), VerticalAlignment = VerticalAlignment.Top };
        _copy.Click += (_, _) =>
        {
            Ui.Copy(_code.Text);
            _copied = true;
            Paint();
        };
        _copy.Id(id == null ? "copy-command" : $"{id}-copy");
        var grid = new Grid { ColumnSpacing = 6 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(_code);
        Grid.SetColumn(_copy, 1);
        grid.Children.Add(_copy);
        Content = grid;
        Paint();
    }

    /// <summary>The command shown; a new one isn't copied yet.</summary>
    public string Command
    {
        get => _code.Text;
        set
        {
            if (value == _code.Text) return;
            _code.Text = value;
            _copied = false;
            Paint();
        }
    }

    private void Paint()
    {
        var label = _copied ? "Copied" : "Copy";
        _copy.Content = _copied ? Ui.Icon(Ui.Glyph.Check, 14, "PtOkIcon") : Ui.Icon(Ui.Glyph.Copy, 14);
        ToolTipService.SetToolTip(_copy, label);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_copy, label);
    }
}
