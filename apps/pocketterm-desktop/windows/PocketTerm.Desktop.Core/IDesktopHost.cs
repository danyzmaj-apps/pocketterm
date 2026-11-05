namespace PocketTerm.Desktop;

/// <summary>
/// What the computer's own side does for the services (Dart's <c>DesktopHost</c>): the main
/// window, the tray item, launch at login, keeping the computer awake. The WinUI app implements
/// it (its window and tray) on top of <see cref="WindowsSystem"/>; tests pass fakes.
/// </summary>
public interface IDesktopHost
{
    /// <summary>
    /// Starts listening. <paramref name="onEvent"/>: <c>openMain</c> (the tray item),
    /// <c>openSettings</c> (its Settings… item), <c>mainClosed</c> (the window was closed: hidden,
    /// the app keeps running) and <c>quitting</c> (the app is about to quit: it waits up to a second
    /// for the task <paramref name="onEvent"/> returns).
    /// </summary>
    Task StartAsync(Func<string, Task> onEvent);

    Task ShowMainAsync();

    Task HideMainAsync();

    /// <summary>Quits the app, after <c>quitting</c> has run.</summary>
    Task QuitAsync();

    /// <summary>What this computer calls itself.</summary>
    Task<string> DeviceNameAsync();

    /// <summary>Seconds since the last keyboard or mouse input.</summary>
    Task<int> IdleSecondsAsync();

    Task<bool> LaunchAtLoginAsync();

    Task SetLaunchAtLoginAsync(bool on);

    /// <summary>A folder picker; the folders chosen, none if cancelled.</summary>
    Task<IReadOnlyList<string>> PickFoldersAsync();

    /// <summary>Keeps the computer from idle sleep while <paramref name="on"/>.</summary>
    Task SetKeepAwakeAsync(bool on);

    /// <summary>
    /// Shows <paramref name="icon"/> (<c>AppIcon.For</c> names) as the app's icon while it runs: the
    /// window's, taskbar's and tray's.
    /// </summary>
    Task SetAppIconAsync(string icon);

    /// <summary>
    /// Shows the tray's Update available… item while <paramref name="update"/> is a newer release
    /// (<see cref="UpdateCheck"/>), hides it at null.
    /// </summary>
    void SetUpdate(UpdateInfo? update);
}
