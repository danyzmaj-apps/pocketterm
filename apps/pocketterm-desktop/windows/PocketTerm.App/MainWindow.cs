using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using PocketTerm.App.Pages;
using PocketTerm.App.Views;
using PocketTerm.Core;
using PocketTerm.Desktop;
using Windows.Graphics;

namespace PocketTerm.App;

/// <summary>
/// PocketTerm's one window, made at launch and kept for the app's life: closing it hides it (the tray item
/// brings it back), as the Flutter app's did. Mica, Windows' own title bar (extended into the content), about
/// 760 × 600 inside its frame, at least 480 × 360, centered.
/// </summary>
internal sealed class MainWindow : Window
{
    private readonly TitleBar _titleBar;
    private ShellView? _shell;

    public MainWindow()
    {
        Title = "PocketTerm";
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        _titleBar = new TitleBar
        {
            Title = "PocketTerm",
            IconSource = new ImageIconSource { ImageSource = new BitmapImage(new Uri(Path.Combine(AppPaths.BaseDir, "Assets", "app.ico"))) },
        }.Id("title-bar");
        Size(776, 640);
        if (AppWindow.Presenter is OverlappedPresenter p)
        {
            p.PreferredMinimumWidth = Scaled(480);
            p.PreferredMinimumHeight = Scaled(360);
        }
        Center();
    }

    /// <summary>Builds the content for <paramref name="app"/> (once the services exist; the window is made first,
    /// since the host they need is its own).</summary>
    public void Attach(AppController app)
    {
        _shell = new ShellView(app, _titleBar);
        Content = _shell;
        SetTitleBar(_titleBar);
    }

    /// <summary>The window's handle, for the Win32 calls (foreground, icon).</summary>
    public IntPtr Handle => WinRT.Interop.WindowNative.GetWindowHandle(this);

    public void Toast(string text) => _shell?.Toast(text);

    /// <summary>Shows the window in front, restored if it was minimized.</summary>
    public void ShowInFront()
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } p) p.Restore();
        AppWindow.Show(true);
        Activate();
        SetForegroundWindow(Handle);
    }

    private int Scaled(double dips) => (int)Math.Round(dips * GetDpiForWindow(Handle) / 96.0);

    private void Size(double width, double height) => AppWindow.Resize(new SizeInt32(Scaled(width), Scaled(height)));

    private void Center()
    {
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var size = AppWindow.Size;
        AppWindow.Move(new PointInt32(area.X + (area.Width - size.Width) / 2, area.Y + (area.Height - size.Height) / 2));
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr hwnd);
}

/// <summary>
/// The window's content (Flutter's <c>MainWindow</c>): the first-run setup, then sign-in, then the setup
/// checklist until it's done, then Settings. Over them: a setup link to another server waits for a yes (a
/// dialog), and what a link said while signed in shows in an InfoBar until closed.
/// </summary>
internal sealed class ShellView : View
{
    private readonly AppController _app;
    private readonly ContentControl _page = new()
    {
        HorizontalContentAlignment = HorizontalAlignment.Stretch,
        VerticalContentAlignment = VerticalAlignment.Stretch,
        IsTabStop = false,
    };
    private readonly InfoBar _notice;
    private readonly InfoBar _toast;
    private readonly DispatcherQueueTimer _toastTimer;
    private string? _route;
    private string? _confirming;
    private ContentDialog? _confirmDialog;

    public ShellView(AppController app, TitleBar titleBar)
    {
        _app = app;
        _notice = new InfoBar
        {
            Severity = InfoBarSeverity.Warning,
            IsClosable = true,
            IsOpen = false,
            Margin = new Thickness(16, 0, 16, 8),
        }.Id("link-notice");
        _toast = new InfoBar
        {
            Severity = InfoBarSeverity.Success,
            IsClosable = false,
            IsOpen = false,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(16, 0, 16, 24),
            MaxWidth = 520,
        }.Id("toast");
        _toastTimer = UiQueue.CreateTimer();
        _toastTimer.Interval = TimeSpan.FromMilliseconds(1600);
        _toastTimer.IsRepeating = false;
        _toastTimer.Tick += (_, _) => _toast.IsOpen = false;

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(titleBar);
        Grid.SetRow(_notice, 1);
        root.Children.Add(_notice);
        Grid.SetRow(_page, 2);
        root.Children.Add(_page);
        Grid.SetRow(_toast, 2);
        root.Children.Add(_toast);
        Content = root;

        app.Notices += (_, message) => OnUi(() =>
        {
            _notice.Message = message;
            _notice.IsOpen = _app.User != null;
        });
        Watch(app);
        OnRefresh(Route);
        OnRefresh(ConfirmLink);
    }

    public void Toast(string text)
    {
        _toast.Message = text;
        _toast.IsOpen = true;
        _toastTimer.Stop();
        _toastTimer.Start();
    }

    private void Route()
    {
        var route = _app.Backend == null ? "setup"
            : _app.User == null ? "sign-in"
            : !_app.GetReadyDone ? "get-ready"
            : "settings";
        if (_app.User == null) _notice.IsOpen = false;
        if (route == _route) return;
        _route = route;
        _page.Content = route switch
        {
            "setup" => new SetupPage(_app),
            "sign-in" => new SignInPage(_app),
            "get-ready" => new GetReadyPage(_app),
            _ => new SettingsPage(_app),
        };
    }

    /// <summary>A setup link from outside the app to another server (Session.LinkToConfirm): nothing happens until
    /// the person says yes. Anyone can send such a link, and this computer's sessions would then go through that
    /// server.</summary>
    private void ConfirmLink()
    {
        var link = _app.User == null ? _app.LinkToConfirm : null;
        if (link == _confirming) return;
        _confirmDialog?.Hide();
        _confirmDialog = null;
        _confirming = link;
        if (link == null) return;
        var dialog = new ContentDialog
        {
            Title = $"Connect to {_app.LinkToConfirmHost ?? "?"}?",
            Content = Ui.Text(
                "A link asks to connect PocketTerm to this server. Only connect if you opened it yourself, from your own "
                + "computer or server: your sessions and the images you send go through it."),
            PrimaryButtonText = "Connect",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        }.Id("confirm-link");
        _confirmDialog = dialog;
        Run(async () =>
        {
            var answer = await Dialogs.ShowAsync(dialog);
            if (!ReferenceEquals(_confirmDialog, dialog)) return;
            _confirmDialog = null;
            await _app.AnswerLink(answer == ContentDialogResult.Primary);
        });
    }
}
