using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Windows.ApplicationModel.Activation;

namespace PocketTerm.App;

/// <summary>
/// The entry point. One PocketTerm per user: a second start (a <c>pocketterm://</c> link, the Start menu, login)
/// hands what it was started with to the running one, which brings its window up, and exits.
/// </summary>
public static class Program
{
    /// <summary>The key the running PocketTerm registers (the Flutter runner's mutex had the same name).</summary>
    private const string InstanceKey = "PocketTermSingleInstance";

    [STAThread]
    private static int Main(string[] args)
    {
        App.Hooks(PocketTerm.Desktop.TestHooks.Env());
        AppDomain.CurrentDomain.UnhandledException += (_, e) => PocketTerm.Core.Log.Print($"PocketTerm: crashed: {e.ExceptionObject}");
        WinRT.ComWrappersSupport.InitializeComWrappers();
        var me = AppInstance.FindOrRegisterForKey(InstanceKey);
        if (!me.IsCurrent)
        {
            Redirect(me);
            return 0;
        }
        Application.Start(started =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App(args);
        });
        return 0;
    }

    /// <summary>The link a start carries, if any: <c>pocketterm://…</c> among <paramref name="args"/>.</summary>
    public static string? LinkIn(IEnumerable<string> args) =>
        args.FirstOrDefault(a => a.StartsWith("pocketterm:", StringComparison.OrdinalIgnoreCase));

    /// <summary>The link in an activation the running PocketTerm got from a second start.</summary>
    public static string? LinkIn(AppActivationArguments activation) => activation.Data switch
    {
        IProtocolActivatedEventArgs p => p.Uri.AbsoluteUri,
        ILaunchActivatedEventArgs l => LinkIn(SplitCommandLine(l.Arguments)),
        _ => null,
    };

    /// <summary>A command line's arguments, Windows' way (quotes group, backslashes before a quote escape it).</summary>
    public static IReadOnlyList<string> SplitCommandLine(string? line)
    {
        if (string.IsNullOrWhiteSpace(line)) return [];
        var argv = CommandLineToArgvW(line, out var count);
        if (argv == IntPtr.Zero) return [];
        try
        {
            var args = new string[count];
            for (var i = 0; i < count; i++) args[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size)) ?? "";
            return args;
        }
        finally
        {
            LocalFree(argv);
        }
    }

    /// <summary>
    /// Hands this start's activation to the running PocketTerm (the Windows App SDK's way: the redirect runs off the
    /// STA thread, which waits without blocking COM), letting it take the foreground.
    /// </summary>
    private static void Redirect(AppInstance running)
    {
        var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
        AllowSetForegroundWindow(running.ProcessId);
        var done = CreateEvent(IntPtr.Zero, true, false, null);
        _ = Task.Run(() =>
        {
            try
            {
                running.RedirectActivationToAsync(activation).AsTask().Wait();
            }
            catch (Exception e)
            {
                Debug.WriteLine($"PocketTerm: couldn't reach the running PocketTerm: {e.Message}");
            }
            finally
            {
                SetEvent(done);
            }
        });
        _ = CoWaitForMultipleObjects(0, 0xFFFFFFFF, 1, [done], out _);
        CloseHandle(done);
    }

    [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CommandLineToArgvW(string cmdLine, out int numArgs);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr mem);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateEvent(IntPtr attributes, bool manualReset, bool initialState, string? name);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetEvent(IntPtr handle);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("ole32.dll")]
    private static extern uint CoWaitForMultipleObjects(uint flags, uint timeout, uint count, IntPtr[] handles, out uint index);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AllowSetForegroundWindow(uint processId);
}
