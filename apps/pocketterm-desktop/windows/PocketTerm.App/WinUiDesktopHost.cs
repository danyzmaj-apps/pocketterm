using System.Runtime.Versioning;
using System.Windows.Input;
using H.NotifyIcon;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Views;
using PocketTerm.Core;
using PocketTerm.Desktop;

namespace PocketTerm.App;

/// <summary>
/// The Windows side for the services (Flutter's <c>WindowsHost</c>): the tray item and its menu, the main
/// window (closing it hides it), launch at login (<c>--hidden</c>: the window stays hidden), the
/// <c>pocketterm://</c> link and keeping the computer awake. The services call in on any thread; window and
/// tray work runs on the UI thread.
/// </summary>
[SupportedOSPlatform("windows10.0.17763.0")]
internal sealed class WinUiDesktopHost : IDesktopHost
{
    private readonly DispatcherQueue _ui;
    private readonly MainWindow _window;
    private readonly bool _startedHidden;
    private Func<string, Task>? _onEvent;
    private TaskbarIcon? _tray;
    private UpdateInfo? _update;
    private bool _quitting;

    /// <summary>What <see cref="SetAppIconAsync"/> last showed; the tray item starts with it.</summary>
    private string _icon = "default";

    public WinUiDesktopHost(MainWindow window, IReadOnlyList<string> args)
    {
        _window = window;
        _ui = window.DispatcherQueue;
        _startedHidden = WindowsSystem.StartedHidden(args);
        window.AppWindow.Closing += (_, e) =>
        {
            if (_quitting) return;
            e.Cancel = true;
            window.AppWindow.Hide();
            Emit("mainClosed");
        };
    }

    private string TrayIconPath => _icon == "default"
        ? Path.Combine(AppPaths.BaseDir, "assets", "tray.ico")
        : Path.Combine(AppPaths.BaseDir, "assets", "icon", $"tray-{_icon}.ico");

    public Task StartAsync(Func<string, Task> onEvent)
    {
        _onEvent = onEvent;
        WindowsSystem.EnsureStartupApproved();
        WindowsSystem.RegisterLink(Environment.ProcessPath ?? Path.Combine(AppPaths.BaseDir, "PocketTerm.exe"));
        return OnUi(() =>
        {
            StartTray();
            // Through the app, which counts each showing.
            if (!_startedHidden) Emit("openMain");
        });
    }

    private void StartTray()
    {
        try
        {
            var tray = new TaskbarIcon
            {
                ToolTipText = "PocketTerm",
                Icon = new System.Drawing.Icon(TrayIconPath),
                ContextMenuMode = ContextMenuMode.PopupMenu,
                NoLeftClickDelay = true,
                LeftClickCommand = new Command(() => Emit("openMain")),
                DoubleClickCommand = new Command(() => Emit("openMain")),
            };
            _tray = tray;
            SetMenu();
            // Efficiency mode would throttle the process: it runs the built-in server and the phone's bridge.
            tray.ForceCreate(enablesEfficiencyMode: false);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: no tray icon: {e.Message}");
        }
    }

    /// <summary>The tray item's menu: Open PocketTerm, Settings…, Update available… (while <see cref="SetUpdate"/>
    /// has one), Quit.</summary>
    private void SetMenu()
    {
        if (_tray == null) return;
        var menu = new MenuFlyout();
        void Add(string label, string id, Action onClick)
        {
            var item = new MenuFlyoutItem { Text = label, Command = new Command(onClick) }.Id(id);
            menu.Items.Add(item);
        }
        Add("Open PocketTerm", "tray-open", () => Emit("openMain"));
        Add("Settings…", "tray-settings", () => Emit("openSettings"));
        if (_update is { } u) Add("Update available…", "tray-update", () => Ui.Open(u.Url));
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("Quit", "tray-quit", () => _ = QuitAsync());
        _tray.ContextFlyout = menu;
    }

    public void SetUpdate(UpdateInfo? update) => _ui.TryEnqueue(() =>
    {
        if (update == _update) return;
        _update = update;
        SetMenu();
    });

    private void Emit(string @event)
    {
        var on = _onEvent;
        if (on == null) return;
        _ = Task.Run(async () =>
        {
            try
            {
                await on(@event);
            }
            catch (Exception e)
            {
                Log.Print($"PocketTerm: {@event}: {e.Message}");
            }
        });
    }

    public Task ShowMainAsync() => OnUi(_window.ShowInFront);

    public Task HideMainAsync() => OnUi(() => _window.AppWindow.Hide());

    /// <summary>Removes the tray item, gives quitting up to a second, then exits.</summary>
    public async Task QuitAsync()
    {
        await OnUi(() =>
        {
            _quitting = true;
            _tray?.Dispose();
            _tray = null;
        });
        try
        {
            var quitting = _onEvent?.Invoke("quitting") ?? Task.CompletedTask;
            await Task.WhenAny(quitting, Task.Delay(TimeSpan.FromSeconds(1)));
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: quitting: {e.Message}");
        }
        Environment.Exit(0);
    }

    /// <summary>The host name, as Flutter's <c>Platform.localHostname</c> gave it.</summary>
    public Task<string> DeviceNameAsync() => Task.FromResult(System.Net.Dns.GetHostName());

    public Task<int> IdleSecondsAsync() => Task.FromResult(WindowsSystem.IdleSeconds());

    public Task<bool> LaunchAtLoginAsync()
    {
        try
        {
            return Task.FromResult(WindowsSystem.LaunchAtLogin());
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: launch at login: {e.Message}");
            return Task.FromResult(false);
        }
    }

    public Task SetLaunchAtLoginAsync(bool on)
    {
        WindowsSystem.SetLaunchAtLogin(on);
        return Task.CompletedTask;
    }

    /// <summary>Windows' folder picker, over the window. It picks one folder at a time.</summary>
    public async Task<IReadOnlyList<string>> PickFoldersAsync()
    {
        var done = new TaskCompletionSource<IReadOnlyList<string>>();
        _ui.TryEnqueue(async () =>
        {
            try
            {
                var picker = new Microsoft.Windows.Storage.Pickers.FolderPicker(_window.AppWindow.Id);
                var picked = await picker.PickSingleFolderAsync();
                done.TrySetResult(picked?.Path is { Length: > 0 } path ? [path] : []);
            }
            catch (Exception e)
            {
                done.TrySetException(e);
            }
        });
        return await done.Task;
    }

    public Task SetKeepAwakeAsync(bool on)
    {
        WindowsSystem.SetKeepAwake(on);
        return Task.CompletedTask;
    }

    /// <summary>The window's icon (title bar, taskbar, Alt-Tab) and the tray item's; the installer's and
    /// Explorer's stay the exe's own.</summary>
    public Task SetAppIconAsync(string icon) => OnUi(() =>
    {
        _icon = icon;
        var window = Path.Combine(AppPaths.BaseDir, "assets", "icon", $"windows-{icon}.ico");
        if (File.Exists(window)) _window.AppWindow.SetIcon(window);
        if (_tray != null && File.Exists(TrayIconPath))
        {
            var old = _tray.Icon;
            _tray.Icon = new System.Drawing.Icon(TrayIconPath);
            old?.Dispose();
        }
    });

    private Task OnUi(Action action)
    {
        if (_ui.HasThreadAccess)
        {
            action();
            return Task.CompletedTask;
        }
        var done = new TaskCompletionSource();
        if (!_ui.TryEnqueue(() =>
        {
            try
            {
                action();
                done.TrySetResult();
            }
            catch (Exception e)
            {
                done.TrySetException(e);
            }
        }))
        {
            done.TrySetException(new InvalidOperationException("The UI thread is gone"));
        }
        return done.Task;
    }

    /// <summary>An <see cref="ICommand"/> for the tray's clicks and menu items.</summary>
    private sealed class Command(Action run) : ICommand
    {
        public event EventHandler? CanExecuteChanged
        {
            add { }
            remove { }
        }

        public bool CanExecute(object? parameter) => true;

        public void Execute(object? parameter) => run();
    }
}
