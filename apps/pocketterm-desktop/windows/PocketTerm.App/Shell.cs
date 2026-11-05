using PocketTerm.Desktop;

namespace PocketTerm.App;

/// <summary>
/// The app's one of each, set at launch (App.cs) before the first screen is built: the controller, the host
/// (window, tray) and the main window. PocketTerm has a single window, so the screens reach them here.
/// </summary>
internal static class Shell
{
    public static AppController App { get; set; } = null!;

    public static WinUiDesktopHost Host { get; set; } = null!;

    public static MainWindow Window { get; set; } = null!;

    /// <summary>This build's version (<c>x.y.z</c>), as Settings shows it.</summary>
    public static string Version { get; } = UpdateCheckVersion();

    /// <summary>A short message at the bottom of the window (Flutter's Toaster), gone after a moment.</summary>
    public static void Toast(string text) => Window.Toast(text);

    private static string UpdateCheckVersion()
    {
        var info = typeof(Shell).Assembly
            .GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
            .OfType<System.Reflection.AssemblyInformationalVersionAttribute>()
            .FirstOrDefault()?.InformationalVersion;
        return string.IsNullOrEmpty(info) ? "0.0.0" : info.Split('+')[0];
    }
}
