using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Views;

namespace PocketTerm.App.Components;

/// <summary>Where one step of a live checklist stands.</summary>
internal enum CheckState
{
    /// <summary>Not known yet: the first look is on its way.</summary>
    Looking,

    /// <summary>Done: one line, nothing to do.</summary>
    Done,

    /// <summary>The step to do now: what and how, with its buttons.</summary>
    Now,

    /// <summary>Waits for an earlier one.</summary>
    Later,
}

/// <summary>
/// One step of a live checklist: done ones collapse to a line, the one to do now shows its <see cref="Note"/> and
/// its actions, later ones only their title. Built once; the screen sets <see cref="State"/>, <see cref="Title"/>
/// and <see cref="Note"/> as the checks change. The AutomationId goes on the title, the part screen readers read.
/// </summary>
internal sealed class SetupCheck : UserControl
{
    private readonly ContentPresenter _mark = new() { Width = 18, Height = 18 };
    private readonly TextBlock _title = Ui.Text("");
    private readonly TextBlock _note = Ui.Dim("");
    private readonly WrapPanel? _actions;
    private CheckState _state;
    private CheckState? _painted;
    private string? _noteText;

    public SetupCheck(CheckState state, string title, string? note = null, IReadOnlyList<UIElement>? actions = null, string? id = null)
    {
        IsTabStop = false;
        if (id != null) _title.Id(id);
        if (actions is { Count: > 0 })
        {
            _actions = new WrapPanel();
            foreach (var a in actions) _actions.Children.Add(a);
        }
        _state = state;
        _title.Text = title;
        _noteText = note;
        Content = Ui.Leading(_mark, Ui.Stack(6, _title, _note, _actions)).Margin(0, 6, 0, 6);
        Paint();
    }

    public CheckState State
    {
        get => _state;
        set
        {
            _state = value;
            Paint();
        }
    }

    public string Title
    {
        get => _title.Text;
        set => _title.Text = value;
    }

    /// <summary>What to do, shown only while this is the step to do now.</summary>
    public string? Note
    {
        get => _noteText;
        set
        {
            _noteText = value;
            Paint();
        }
    }

    private void Paint()
    {
        var now = _state == CheckState.Now;
        _note.Text = _noteText ?? "";
        _note.Shown(now && _noteText != null);
        _actions?.Shown(now);
        if (_painted == _state) return;
        _painted = _state;
        _mark.Content = _state switch
        {
            CheckState.Looking => new ProgressRing { IsActive = true, Width = 14, Height = 14 },
            CheckState.Done => Ui.Icon(Ui.Glyph.CheckCircle, 16, "PtOkIcon"),
            CheckState.Now => Ui.Icon(Ui.Glyph.Forward, 16, "PtWarnIcon"),
            _ => Ui.Icon(Ui.Glyph.Circle, 16, "PtDimIcon"),
        };
        _title.Style = Ui.Style(now ? "PtStrong" : "PtBody");
        // Looking and later: the step isn't reached yet, so its title stays quiet (an opacity follows light and dark).
        _title.Opacity = _state is CheckState.Looking or CheckState.Later ? 0.6 : 1;
    }
}
