using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Views;

namespace PocketTerm.App.Components;

/// <summary>
/// A question with its answer folded away ("What is Tailscale?"): an <see cref="Expander"/>, closed until the person
/// opens it. A string answer becomes secondary text.
/// </summary>
internal sealed class Explainer : UserControl
{
    public Explainer(string title, UIElement child, string? id = null)
    {
        IsTabStop = false;
        Expander = new Expander
        {
            Header = title,
            Content = child,
            IsExpanded = false,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        if (id != null) Expander.Id(id, title);
        Content = Expander;
    }

    public Explainer(string title, string text, string? id = null)
        : this(title, Ui.Dim(text).Selectable(), id)
    {
    }

    public Expander Expander { get; }
}
