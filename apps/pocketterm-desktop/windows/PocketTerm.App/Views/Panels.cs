using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace PocketTerm.App.Views;

/// <summary>Lays its children out left to right, wrapping to a new line when the next doesn't fit (chips, theme
/// tiles); WinUI has no wrap panel of its own.</summary>
internal sealed class WrapPanel : Panel
{
    public double Spacing { get; set; } = 8;

    public double LineSpacing { get; set; } = 8;

    protected override Size MeasureOverride(Size available)
    {
        double x = 0, y = 0, line = 0, width = 0;
        foreach (var child in Children)
        {
            child.Measure(new Size(available.Width, double.PositiveInfinity));
            var d = child.DesiredSize;
            if (x > 0 && x + d.Width > available.Width)
            {
                y += line + LineSpacing;
                x = 0;
                line = 0;
            }
            x += d.Width + Spacing;
            line = Math.Max(line, d.Height);
            width = Math.Max(width, x - Spacing);
        }
        return new Size(double.IsInfinity(available.Width) ? width : Math.Min(width, available.Width), y + line);
    }

    protected override Size ArrangeOverride(Size final)
    {
        double x = 0, y = 0, line = 0;
        foreach (var child in Children)
        {
            var d = child.DesiredSize;
            if (x > 0 && x + d.Width > final.Width)
            {
                y += line + LineSpacing;
                x = 0;
                line = 0;
            }
            child.Arrange(new Rect(x, y, d.Width, d.Height));
            x += d.Width + Spacing;
            line = Math.Max(line, d.Height);
        }
        return final;
    }
}

/// <summary>
/// A panel's children kept in step with a list (Flutter rebuilt them): an item's element is made once, by its
/// key, updated while the item stays and dropped when it goes, so its state (an expander's, a button's focus)
/// survives a refresh.
/// </summary>
internal static class Keyed
{
    private static readonly ConditionalWeakTable<Panel, Dictionary<string, UIElement>> Elements = new();

    public static void Sync<T>(
        this Panel panel,
        IEnumerable<T> items,
        Func<T, string> key,
        Func<T, UIElement> create,
        Action<UIElement, T>? update = null)
    {
        var byKey = Elements.GetOrCreateValue(panel);
        var want = new List<UIElement>();
        var seen = new HashSet<string>();
        foreach (var item in items)
        {
            var k = key(item);
            if (!seen.Add(k)) continue;
            if (byKey.TryGetValue(k, out var element))
            {
                update?.Invoke(element, item);
            }
            else
            {
                element = create(item);
                byKey[k] = element;
            }
            want.Add(element);
        }
        foreach (var gone in byKey.Keys.Where(k => !seen.Contains(k)).ToList()) byKey.Remove(gone);
        if (panel.Children.Count == want.Count && panel.Children.Zip(want).All(p => ReferenceEquals(p.First, p.Second))) return;
        panel.Children.Clear();
        foreach (var e in want) panel.Children.Add(e);
    }
}
