using System.Diagnostics;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using PocketTerm.Core;
using Windows.ApplicationModel.DataTransfer;

namespace PocketTerm.App.Views;

/// <summary>The text styles of <c>Styles.xaml</c>.</summary>
internal enum TextKind
{
    Body,
    Strong,
    Dim,
    Subtitle,
    Title,
    Section,
    Ok,
    Warn,
    Error,
}

/// <summary>
/// Builders for the controls every screen uses, in Windows' own look: system fonts, theme brushes (through
/// <c>Styles.xaml</c>, so light and dark follow Windows), Segoe Fluent icons, settings cards. Every
/// interactive control gets an AutomationId (<see cref="Id{T}"/>) named after the Flutter ValueKey it
/// replaces.
/// </summary>
internal static class Ui
{
    /// <summary>Loads <c>Styles.xaml</c> into the app's resources (once, at start).</summary>
    public static void LoadStyles(Application app)
    {
        using var stream = typeof(Ui).Assembly.GetManifestResourceStream("PocketTerm.App.Views.Styles.xaml")
            ?? throw new InvalidOperationException("Styles.xaml isn't embedded");
        using var reader = new StreamReader(stream);
        app.Resources.MergedDictionaries.Add((ResourceDictionary)XamlReader.Load(reader.ReadToEnd()));
    }

    public static Style Style(string key) => (Style)Application.Current.Resources[key];

    /// <summary>Sets the AutomationId (and, when given, the name a screen reader says).</summary>
    public static T Id<T>(this T element, string id, string? name = null)
        where T : DependencyObject
    {
        AutomationProperties.SetAutomationId(element, id);
        if (name != null) AutomationProperties.SetName(element, name);
        return element;
    }

    public static T Margin<T>(this T element, double left, double top, double right, double bottom)
        where T : FrameworkElement
    {
        element.Margin = new Thickness(left, top, right, bottom);
        return element;
    }

    public static T Margin<T>(this T element, double all)
        where T : FrameworkElement
    {
        element.Margin = new Thickness(all);
        return element;
    }

    public static T Shown<T>(this T element, bool shown)
        where T : UIElement
    {
        element.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        return element;
    }

    public static T Width<T>(this T element, double width)
        where T : FrameworkElement
    {
        element.Width = width;
        return element;
    }

    public static T MaxWidth<T>(this T element, double width)
        where T : FrameworkElement
    {
        element.MaxWidth = width;
        return element;
    }

    public static T Align<T>(this T element, HorizontalAlignment h, VerticalAlignment v = VerticalAlignment.Stretch)
        where T : FrameworkElement
    {
        element.HorizontalAlignment = h;
        element.VerticalAlignment = v;
        return element;
    }

    // ------------------------------------------------------------------ text

    public static TextBlock Text(string text, TextKind kind = TextKind.Body) => new()
    {
        Text = text,
        Style = Style(kind switch
        {
            TextKind.Strong => "PtStrong",
            TextKind.Dim => "PtDim",
            TextKind.Subtitle => "PtSubtitle",
            TextKind.Title => "PtTitle",
            TextKind.Section => "PtSection",
            TextKind.Ok => "PtOkText",
            TextKind.Warn => "PtWarnText",
            TextKind.Error => "PtErrorText",
            _ => "PtBody",
        }),
    };

    public static TextBlock Dim(string text) => Text(text, TextKind.Dim);

    public static TextBlock Strong(string text) => Text(text, TextKind.Strong);

    /// <summary>Text the person may select and copy (an error, an address).</summary>
    public static TextBlock Selectable(this TextBlock text)
    {
        text.IsTextSelectionEnabled = true;
        return text;
    }

    /// <summary>The monospaced font, for commands and paths.</summary>
    public static readonly FontFamily Mono = new("Cascadia Mono, Cascadia Code, Consolas");

    // ------------------------------------------------------------------ icons

    /// <summary>Segoe Fluent Icons' glyphs the screens use.</summary>
    public static class Glyph
    {
        public const string Phone = "\uE8EA";
        public const string Robot = "\uE99A";
        public const string Terminal = "\uE756";
        public const string Account = "\uE77B";
        public const string Settings = "\uE713";
        public const string Check = "\uE73E";
        public const string CheckCircle = "\uEC61";
        public const string Warning = "\uE7BA";
        public const string Error = "\uEA39";
        public const string Info = "\uE946";
        public const string More = "\uE712";
        public const string Copy = "\uE8C8";
        public const string Folder = "\uE8B7";
        public const string FolderAdd = "\uE8F4";
        public const string Add = "\uE710";
        public const string Remove = "\uE711";
        public const string Refresh = "\uE72C";
        public const string Download = "\uE896";
        public const string Back = "\uE72B";
        public const string Forward = "\uE72A";
        public const string Globe = "\uE774";
        public const string Server = "\uE968";
        public const string Cloud = "\uE753";
        public const string Computer = "\uE7F8";
        public const string Lock = "\uE72E";
        public const string Key = "\uE8D7";
        public const string Shield = "\uEA18";
        public const string QrCode = "\uED14";
        public const string Link = "\uE71B";
        public const string OpenInNew = "\uE8A7";
        public const string Help = "\uE897";
        public const string Color = "\uE790";
        public const string Power = "\uE7E8";
        public const string SignOut = "\uF3B1";
        public const string Delete = "\uE74D";
        public const string Clock = "\uE823";
        public const string Ring = "\uEA3A";
        public const string Circle = "\uEA3B";
        public const string Sync = "\uE895";
        public const string Notification = "\uEA8F";
        public const string Code = "\uE943";
        public const string ChevronDown = "\uE70D";
        public const string ChevronUp = "\uE70E";
    }

    public static FontIcon Icon(string glyph, double size = 16, string? style = null)
    {
        var icon = new FontIcon { Glyph = glyph, FontSize = size };
        if (style != null) icon.Style = Style(style);
        return icon;
    }

    // ------------------------------------------------------------------ layout

    public static StackPanel Stack(double spacing, params UIElement?[] children)
    {
        var panel = new StackPanel { Spacing = spacing };
        foreach (var c in children)
        {
            if (c != null) panel.Children.Add(c);
        }
        return panel;
    }

    public static StackPanel Row(double spacing, params UIElement?[] children)
    {
        var panel = Stack(spacing, children);
        panel.Orientation = Orientation.Horizontal;
        return panel;
    }

    /// <summary>A row with <paramref name="main"/> taking the room and <paramref name="trailing"/> at the end,
    /// both centered vertically.</summary>
    public static Grid Split(UIElement main, UIElement? trailing, double spacing = 12)
    {
        var grid = new Grid { ColumnSpacing = spacing };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (main is FrameworkElement m) m.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(main);
        if (trailing != null)
        {
            if (trailing is FrameworkElement t) t.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn((FrameworkElement)trailing, 1);
            grid.Children.Add(trailing);
        }
        return grid;
    }

    /// <summary>A page's scrolling content, centered at most <paramref name="maxWidth"/> wide.</summary>
    public static ScrollViewer Page(UIElement content, double maxWidth = 760, string? id = null)
    {
        var inner = new Border
        {
            Child = content,
            MaxWidth = maxWidth,
            Padding = new Thickness(32, 16, 32, 32),
        };
        var scroll = new ScrollViewer
        {
            Content = inner,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        if (id != null) scroll.Id(id);
        return scroll;
    }

    public static Border Divider() => new() { Style = Style("PtDivider") };

    // ------------------------------------------------------------------ cards

    /// <summary>A plain card around <paramref name="content"/>.</summary>
    public static Border Card(UIElement content) => new() { Style = Style("PtCard"), Child = content };

    /// <summary>
    /// A settings card (Windows 11 Settings): <paramref name="icon"/>, <paramref name="header"/> with
    /// <paramref name="description"/> below it, <paramref name="trailing"/> (a switch, a button) at the end, and
    /// <paramref name="body"/> under a divider when given. Returns the parts so screens can update them.
    /// </summary>
    public static SettingsCard SettingsCard(
        string header,
        string? description = null,
        string? icon = null,
        UIElement? trailing = null,
        UIElement? body = null) => new(header, description, icon, trailing, body);

    /// <summary>A boxed note with an icon (Flutter's <c>_notice</c>).</summary>
    public static Border Note(string text, string glyph = Glyph.Info) => new()
    {
        Style = Style("PtNote"),
        Child = Leading(Icon(glyph, 14, "PtDimIcon"), Text(text, TextKind.Dim)),
    };

    /// <summary><paramref name="icon"/> at the top left, <paramref name="content"/> beside it taking the room.</summary>
    public static Grid Leading(FrameworkElement icon, UIElement content, double spacing = 10)
    {
        var grid = new Grid { ColumnSpacing = spacing };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        icon.VerticalAlignment = VerticalAlignment.Top;
        icon.Margin = new Thickness(0, 2, 0, 0);
        grid.Children.Add(icon);
        Grid.SetColumn((FrameworkElement)content, 1);
        grid.Children.Add(content);
        return grid;
    }

    // ------------------------------------------------------------------ buttons

    public static Button Button(string label, Action onClick, string? id = null, bool accent = false)
    {
        var b = new Button { Content = label };
        if (accent) b.Style = Style("AccentButtonStyle");
        b.Click += (_, _) => onClick();
        if (id != null) b.Id(id);
        return b;
    }

    /// <summary>A button with a Fluent icon before its label.</summary>
    public static Button IconButton(string glyph, string label, Action onClick, string? id = null, bool accent = false)
    {
        var b = Button(label, onClick, id, accent);
        b.Content = Row(8, Icon(glyph, 14), new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center });
        AutomationProperties.SetName(b, label);
        return b;
    }

    /// <summary>A text-only action (Flutter's TextButton): a borderless button in the accent color.</summary>
    public static HyperlinkButton Link(string label, Action onClick, string? id = null)
    {
        var b = new HyperlinkButton { Content = label, Padding = new Thickness(4, 2, 4, 2) };
        b.Click += (_, _) => onClick();
        if (id != null) b.Id(id);
        return b;
    }

    /// <summary>A link to a web page, opened in the browser.</summary>
    public static HyperlinkButton WebLink(string label, string url, string? id = null) => Link(label, () => Open(url), id);

    // ------------------------------------------------------------------ the system

    /// <summary>Opens <paramref name="url"/> in the browser (or its app).</summary>
    public static void Open(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true })?.Dispose();
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: couldn't open {url}: {e.Message}");
        }
    }

    public static void Open(Uri url) => Open(url.AbsoluteUri);

    /// <summary>Puts <paramref name="text"/> on the clipboard.</summary>
    public static void Copy(string text)
    {
        var data = new DataPackage();
        data.SetText(text);
        Clipboard.SetContent(data);
        Clipboard.Flush();
    }

    /// <summary>Plural Flutter-style: "1 window", "2 windows".</summary>
    public static string Count(int n, string noun) => $"{n} {noun}{(n == 1 ? "" : "s")}";
}

/// <summary>A settings card's parts (<see cref="Ui.SettingsCard"/>); the card itself is <see cref="Root"/>.</summary>
internal sealed class SettingsCard
{
    public SettingsCard(string header, string? description, string? icon, UIElement? trailing, UIElement? body)
    {
        Header = Ui.Strong(header);
        Description = Ui.Dim(description ?? "");
        Description.Visibility = description == null ? Visibility.Collapsed : Visibility.Visible;
        var texts = Ui.Stack(2, Header, Description);
        texts.VerticalAlignment = VerticalAlignment.Center;
        var top = new Grid { ColumnSpacing = 16 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (icon != null)
        {
            IconElement = Ui.Icon(icon, 20);
            IconElement.VerticalAlignment = VerticalAlignment.Center;
            top.Children.Add(IconElement);
        }
        Grid.SetColumn(texts, 1);
        top.Children.Add(texts);
        Trailing = new ContentPresenter { Content = trailing, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(Trailing, 2);
        top.Children.Add(Trailing);
        Body = new Border { Style = Ui.Style("PtCardBody"), Child = body, Visibility = body == null ? Visibility.Collapsed : Visibility.Visible };
        var all = new StackPanel();
        all.Children.Add(new Border { Padding = new Thickness(16, 14, 16, 14), Child = top });
        all.Children.Add(Body);
        Root = new Border { Style = Ui.Style("PtCard"), Padding = new Thickness(0), Child = all };
    }

    public Border Root { get; }

    public TextBlock Header { get; }

    public TextBlock Description { get; }

    public FontIcon? IconElement { get; }

    public ContentPresenter Trailing { get; }

    /// <summary>The part under the divider; hidden while it has no child.</summary>
    public Border Body { get; }

    public void SetDescription(string? text)
    {
        Description.Text = text ?? "";
        Description.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
    }

    public void SetBody(UIElement? body)
    {
        if (!ReferenceEquals(Body.Child, body)) Body.Child = body;
        Body.Visibility = body == null ? Visibility.Collapsed : Visibility.Visible;
    }

    public void SetTrailing(UIElement? trailing)
    {
        if (!ReferenceEquals(Trailing.Content, trailing)) Trailing.Content = trailing;
    }

    public static implicit operator UIElement(SettingsCard card) => card.Root;
}
