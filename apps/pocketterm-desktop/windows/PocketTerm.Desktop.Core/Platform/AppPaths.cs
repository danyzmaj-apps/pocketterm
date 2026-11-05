namespace PocketTerm.Desktop;

/// <summary>
/// Where PocketTerm keeps its data and finds what it ships with. <see cref="SupportDir"/> is the very
/// folder the Flutter app had (path_provider's <c>getApplicationSupportDirectory()</c>), so its built-in
/// server's data, its preferences and its secrets are where an upgrade looks for them. Both are set
/// once at start (tests point them elsewhere) and read from any thread after.
/// </summary>
public static class AppPaths
{
    /// <summary>The Flutter build's <c>CompanyName</c> (windows/runner/Runner.rc), which path_provider_windows
    /// named the support folder after. Fixed here: the new executable's own version resources don't matter.</summary>
    public const string Company = "Danijel Lovric";

    /// <summary>The Flutter build's <c>ProductName</c> (windows/runner/Runner.rc).</summary>
    public const string Product = "PocketTerm";

    /// <summary>
    /// <c>%APPDATA%\Danijel Lovric\PocketTerm</c>: FOLDERID_RoamingAppData, then the company and product
    /// names as path_provider_windows 2.3.0 put them (none has a character it replaces). Not made here:
    /// whatever writes into it makes it.
    /// </summary>
    public static string SupportDir { get; set; } = DefaultSupportDir();

    /// <summary>The app's install folder, where <c>integrations\</c>, <c>supabase\</c> and
    /// <c>pocketterm-server.exe</c> are bundled next to the executable.</summary>
    public static string BaseDir { get; set; } = AppContext.BaseDirectory;

    /// <summary>The coding agents' integrations bundled with the app (apps/pocketterm-desktop/integrations).</summary>
    public static string IntegrationsDir => Path.Combine(BaseDir, "integrations");

    /// <summary>The built-in server's data folder (what lib/controller.dart passed as <c>--data</c>).</summary>
    public static string ServerDataDir => Path.Combine(SupportDir, "pocketterm-server");

    /// <summary>The support folder for <paramref name="appData"/> (the roaming AppData folder).</summary>
    public static string SupportDirIn(string appData) => Path.Combine(appData, Company, Product);

    private static string DefaultSupportDir() =>
        SupportDirIn(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData, Environment.SpecialFolderOption.DoNotVerify));
}
