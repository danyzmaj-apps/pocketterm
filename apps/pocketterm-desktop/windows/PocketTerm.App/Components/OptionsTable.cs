using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Views;

namespace PocketTerm.App.Components;

/// <summary>The three options side by side (the first-run setup's choice). The table scrolls sideways when the
/// window is narrow; its AutomationId (<c>compare-table</c>) is on that scroller.</summary>
internal sealed class OptionsTable : UserControl
{
    private static readonly string[][] Rows =
    [
        ["", "On this computer", "On my own server", "Supabase"],
        ["Who runs the server", "This computer (built in)", "You, on a VPS you rent", "Supabase, in a region you pick"],
        ["Who holds the metadata", "Only you", "You and your VPS host", "Supabase"],
        ["Reached through", "Tailscale", "Your domain (HTTPS)", "supabase.co"],
        ["Cost", "Free", "A VPS", "Free plan (pauses after a week unused)"],
        ["This computer must be awake", "Yes", "Yes (your sessions run on it)", "Yes (your sessions run on it)"],
        ["Contents end-to-end encrypted", "Yes", "Yes", "Yes"],
    ];

    public OptionsTable()
    {
        IsTabStop = false;
        var grid = new Grid { MinWidth = 440 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.25, GridUnitType.Star) });
        for (var c = 1; c < 4; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var r = 0; r < Rows.Length; r++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            if (r > 0)
            {
                var line = Ui.Divider();
                line.VerticalAlignment = VerticalAlignment.Top;
                Grid.SetRow(line, r);
                Grid.SetColumnSpan(line, 4);
                grid.Children.Add(line);
            }
            for (var c = 0; c < 4; c++)
            {
                var cell = Ui.Text(Rows[r][c], r == 0 || c == 0 ? TextKind.Body : TextKind.Dim);
                cell.FontSize = 12;
                if (r == 0) cell.FontWeight = FontWeights.SemiBold;
                cell.Margin = new Thickness(0, 5, 8, 5);
                Grid.SetRow(cell, r);
                Grid.SetColumn(cell, c);
                grid.Children.Add(cell);
            }
        }
        var table = new ScrollViewer
        {
            Content = grid,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollMode = ScrollMode.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollMode = ScrollMode.Disabled,
        }.Id("compare-table", "How the three options compare");
        Content = Ui.Stack(
            10,
            table,
            Ui.Dim(
                "Your sessions, images, files and notification text are end-to-end encrypted in all three: whoever runs " +
                "the server passes them along but can’t read them. Your sessions always run on this computer, so it has to " +
                "be awake with every option."));
    }
}
