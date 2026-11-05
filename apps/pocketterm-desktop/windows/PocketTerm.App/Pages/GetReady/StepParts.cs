using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Views;

namespace PocketTerm.App.Pages.GetReady;

/// <summary>Where a step of the checklist, or a line in one, stands.</summary>
internal enum StepStatus
{
    Done,
    Action,
    Optional,
    Working,
}

/// <summary>A step's or a line's status: an icon, or a ring while it's working.</summary>
internal sealed class StatusMark : Grid
{
    private readonly FontIcon _icon;
    private readonly ProgressRing _ring;
    private readonly bool _step;

    /// <param name="step">A step's (its header's larger, circled icons) rather than a line's.</param>
    public StatusMark(bool step)
    {
        _step = step;
        var size = step ? 18 : 16;
        Width = size;
        Height = size;
        VerticalAlignment = VerticalAlignment.Center;
        _icon = Ui.Icon(Ui.Glyph.Circle, size);
        _ring = new ProgressRing { Width = size - 2, Height = size - 2, IsActive = false };
        Children.Add(_icon);
        Children.Add(_ring);
    }

    public void Set(StepStatus status, bool error = false)
    {
        _ring.IsActive = status == StepStatus.Working;
        _ring.Shown(status == StepStatus.Working);
        _icon.Shown(status != StepStatus.Working);
        (_icon.Glyph, _icon.Style) = status switch
        {
            StepStatus.Done => (_step ? Ui.Glyph.CheckCircle : Ui.Glyph.Check, Ui.Style("PtOkIcon")),
            StepStatus.Action when error => (Ui.Glyph.Error, Ui.Style("PtErrorIcon")),
            StepStatus.Action => (Ui.Glyph.Warning, Ui.Style("PtWarnIcon")),
            StepStatus.Optional => (_step ? Ui.Glyph.Circle : Ui.Glyph.Remove, Ui.Style("PtDimIcon")),
            _ => (_icon.Glyph, _icon.Style),
        };
    }
}

/// <summary>One step of the checklist: its status, its title (Optional beside it until it's done) and its
/// body.</summary>
internal sealed class StepCard
{
    private readonly StatusMark _mark = new(step: true);
    private readonly TextBlock? _optional;

    public StepCard(string id, string title, UIElement body, bool optional = false)
    {
        var header = Ui.Row(10, _mark, Ui.Strong(title).Align(HorizontalAlignment.Left, VerticalAlignment.Center));
        if (optional)
        {
            _optional = Ui.Dim("Optional");
            _optional.FontSize = 12;
            _optional.VerticalAlignment = VerticalAlignment.Center;
            header.Children.Add(_optional);
        }
        Root = Ui.Card(Ui.Stack(10, header, body)).Id(id);
    }

    public Border Root { get; }

    public void Set(StepStatus status)
    {
        _mark.Set(status);
        _optional?.Shown(status != StepStatus.Done);
    }
}

/// <summary>A line in a step: its status, what it says and, when there's something to do, an action at its
/// end.</summary>
internal sealed class StatusLine : Grid
{
    private readonly StatusMark _mark = new(step: false);
    private readonly TextBlock _text;
    private readonly HyperlinkButton _action;
    private Action? _onAction;

    public StatusLine()
    {
        ColumnSpacing = 10;
        Margin = new Thickness(0, 2, 0, 0);
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _text = Ui.Text("").Selectable();
        _text.TextWrapping = TextWrapping.Wrap;
        _text.VerticalAlignment = VerticalAlignment.Center;
        _action = Ui.Link("", () => _onAction?.Invoke());
        _action.VerticalAlignment = VerticalAlignment.Center;
        Children.Add(_mark);
        SetColumn(_text, 1);
        Children.Add(_text);
        SetColumn(_action, 2);
        Children.Add(_action);
    }

    /// <summary>The action's AutomationId.</summary>
    public StatusLine ActionId(string id)
    {
        _action.Id(id);
        return this;
    }

    public void Set(StepStatus status, string text, bool error = false, string? action = null, Action? onAction = null)
    {
        _mark.Set(status, error);
        _text.Text = text;
        _text.Style = Ui.Style(error ? "PtErrorText" : status == StepStatus.Optional ? "PtDim" : "PtBody");
        _onAction = onAction;
        _action.Content = action ?? "";
        _action.Shown(action != null);
    }
}
