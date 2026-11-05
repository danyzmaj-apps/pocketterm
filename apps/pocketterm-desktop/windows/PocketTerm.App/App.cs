using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.XamlTypeInfo;
using Microsoft.Windows.AppLifecycle;
using PocketTerm.App.Views;
using PocketTerm.Core;
using PocketTerm.Desktop;

namespace PocketTerm.App;

/// <summary>
/// The WinUI application: loads WinUI's resources and the app's styles, then wires the services as the Flutter
/// app's <c>lib/main.dart</c> did (Desktop.Core README, "What the app wires at launch"). The app has no XAML pages,
/// so it hands WinUI's own control types to the XAML parser itself (what the XAML compiler would generate).
/// </summary>
internal sealed partial class App : Application, IXamlMetadataProvider
{
    private readonly string[] _args;
    private readonly XamlControlsXamlMetaDataProvider _types = new();

    public App(string[] args)
    {
        _args = args;
        UnhandledException += (_, e) =>
        {
            // A screen's bug shouldn't take the server and the phone's bridge down with the window.
            Log.Print($"PocketTerm: {e.Exception}");
            e.Handled = true;
        };
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            Log.Print($"PocketTerm: {e.Exception.InnerException?.Message ?? e.Exception.Message}");
            e.SetObserved();
        };
    }

    public IXamlType GetXamlType(Type type) => _types.GetXamlType(type);

    public IXamlType GetXamlType(string fullName) => _types.GetXamlType(fullName);

    public XmlnsDefinition[] GetXmlnsDefinitions() => _types.GetXmlnsDefinitions();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            Resources.MergedDictionaries.Add(new XamlControlsResources());
            Ui.LoadStyles(this);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: couldn't load the app's resources: {e}");
            throw;
        }
        // PocketTerm lives in the tray: no window open is no reason to stop.
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        _ = StartAsync();
    }

    private async Task StartAsync()
    {
        try
        {
            var env = TestHooks.Env();
            var secrets = SystemSecrets.Create(env);
            var prefs = new JsonPreferenceStore();
            // Once: a Flutter 0.1.x install's preferences and secrets become the native app's.
            await FlutterMigration.RunAsync(
                AppPaths.SupportDir,
                prefs,
                SystemSecrets.IsThrowaway(env) ? null : secrets,
                new DpapiProtector());
            Appearance.Shared.Load(prefs);
            Accent.Apply(this, Appearance.Shared.Theme);

            var window = new MainWindow();
            Shell.Window = window;
            var host = new WinUiDesktopHost(window, _args);
            Shell.Host = host;
            AppIcon.Follow(Appearance.Shared, host.SetAppIconAsync);
            var app = new AppController(prefs, await host.DeviceNameAsync(), host, secrets: secrets, updates: new UpdateCheck());
            Shell.App = app;
            window.Attach(app);
            Appearance.Shared.PropertyChanged += (_, _) => window.DispatcherQueue.TryEnqueue(() =>
            {
                Accent.Apply(this, Appearance.Shared.Theme);
                if (window.Content is FrameworkElement root) Accent.Repaint(root);
            });
            AppInstance.GetCurrent().Activated += (_, a) => window.DispatcherQueue.TryEnqueue(() => OnRedirected(app, host, a));

            var api = new LocalApi(app.Live);
            try
            {
                await api.StartAsync();
                app.OnQuit = api.StopAsync;
            }
            catch (Exception e)
            {
                Log.Print($"PocketTerm: terminal API unavailable: {e.Message}");
            }
            await app.Start();
            if (Program.LinkIn(_args) is { } link) app.HandleLink(link);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: couldn't start: {e}");
            throw;
        }
    }

    /// <summary>A second start handed its activation over: its window comes up, with its link if it had one.</summary>
    private static void OnRedirected(AppController app, WinUiDesktopHost host, AppActivationArguments activation)
    {
#if E2E
        // tool/smoke ends a run with `PocketTerm.exe --quit`: the tray's Quit, without a tray to click.
        if (activation.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs l
            && Program.SplitCommandLine(l.Arguments).Contains("--quit"))
        {
            _ = host.QuitAsync();
            return;
        }
#endif
        _ = app.OpenMainAsync();
        if (Program.LinkIn(activation) is { } link) app.HandleLink(link);
    }

    /// <summary>
    /// The smoke and end-to-end builds' own hooks, besides Desktop.Core's (<see cref="TestHooks"/>):
    /// <c>POCKETTERM_DATA</c>, a throwaway support folder instead of <c>%APPDATA%\Danijel Lovric\PocketTerm</c>,
    /// and <c>POCKETTERM_LOG</c>, a file the log lines go to. A released build has an empty <paramref name="env"/>.
    /// Set first thing in <c>Main</c>, so the log has what goes wrong from the start.
    /// </summary>
    public static void Hooks(IReadOnlyDictionary<string, string> env)
    {
        if (env.TryGetValue("POCKETTERM_DATA", out var data) && data.Length > 0) AppPaths.SupportDir = data;
        if (env.TryGetValue("POCKETTERM_LOG", out var file) && file.Length > 0)
        {
            var gate = new object();
            Log.Sink = line =>
            {
                lock (gate) File.AppendAllText(file, line + Environment.NewLine);
            };
        }
    }
}
