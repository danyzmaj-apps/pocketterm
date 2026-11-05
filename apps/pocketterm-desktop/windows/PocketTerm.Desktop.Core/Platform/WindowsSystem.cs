using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Win32;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>
/// Windows itself, for the app (what lib/windows_host.dart did besides its window and tray): idle
/// time, keeping the computer awake, launch at login, the <c>pocketterm://</c> link and the PATH a new
/// login has. Every member that touches Windows is <c>[SupportedOSPlatform("windows")]</c>; the pure
/// ones (<see cref="StartedHidden"/>, <see cref="IdleSecondsOf"/>, <see cref="RunValue"/>) work anywhere.
/// Safe from any thread: the registry and the power request are the only state, and the request is
/// guarded by a lock.
/// </summary>
public static class WindowsSystem
{
    /// <summary>The Run key's value name launch_at_startup wrote (its <c>appName</c>).</summary>
    public const string AppName = "PocketTerm";

    /// <summary>What launch at login starts PocketTerm with: the window stays hidden.</summary>
    public const string HiddenArg = "--hidden";

    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    /// <summary>Task Manager's Startup apps switch.</summary>
    private const string StartupApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";

    /// <summary>launch_at_startup's StartupApproved value: 12 bytes, the first 2 (on).</summary>
    private const int StartupApprovedLength = 12;

    private static readonly object AwakeGate = new();
    private static IntPtr _awake;

    // ------------------------------------------------------------ pure

    /// <summary>Started at login: the command line has <c>--hidden</c>.</summary>
    public static bool StartedHidden(IReadOnlyList<string> args) => args.Contains(HiddenArg);

    /// <summary>Seconds between <paramref name="lastInput"/> and <paramref name="now"/>, both milliseconds since
    /// boot as 32 bits: the subtraction wraps, so it survives the counter's wrap after 49.7 days.</summary>
    public static int IdleSecondsOf(uint now, uint lastInput) => (int)(unchecked(now - lastInput) / 1000);

    /// <summary>The Run key's value for <paramref name="exe"/>, as launch_at_startup 0.5.1 made it:
    /// <c>"&lt;exe&gt;" --hidden</c>.</summary>
    public static string RunValue(string exe) => $"\"{exe}\" {HiddenArg}";

    /// <summary>Whether StartupApproved's <paramref name="value"/> lets the app start (launch_at_startup's
    /// reading): none, empty or an even first byte; an odd one is Task Manager's Disabled.</summary>
    public static bool StartupApproved(byte[]? value) => value is not { Length: > 0 } || value[0] % 2 == 0;

    // ------------------------------------------------------------ Windows

    /// <summary>Seconds since the last keyboard or mouse input; 0 when Windows doesn't say.</summary>
    [SupportedOSPlatform("windows")]
    public static int IdleSeconds()
    {
        var info = new LastInputInfo { Size = (uint)Marshal.SizeOf<LastInputInfo>() };
        if (!GetLastInputInfo(ref info)) return 0;
        return IdleSecondsOf(GetTickCount(), info.Time);
    }

    /// <summary>
    /// Keeps the computer from idle sleep while <paramref name="on"/> (the lid or the power button still
    /// sleep it). The Flutter app called SetThreadExecutionState, which holds only while the thread that
    /// called it lives and is per thread; callers here are on any thread, so a power request
    /// (PowerCreateRequest + PowerSetRequest SystemRequired) holds it for the process instead, until
    /// turned off or PocketTerm exits. <c>powercfg /requests</c> lists it.
    /// </summary>
    [SupportedOSPlatform("windows")]
    public static void SetKeepAwake(bool on)
    {
        lock (AwakeGate)
        {
            if (!on)
            {
                if (_awake == IntPtr.Zero) return;
                PowerClearRequest(_awake, PowerRequestSystemRequired);
                CloseHandle(_awake);
                _awake = IntPtr.Zero;
                return;
            }
            if (_awake != IntPtr.Zero) return;
            var reason = Marshal.StringToHGlobalUni("PocketTerm keeps this computer awake for the phone");
            try
            {
                var context = new ReasonContext
                {
                    Version = PowerRequestContextVersion,
                    Flags = PowerRequestContextSimpleString,
                    SimpleReasonString = reason,
                };
                var request = PowerCreateRequest(ref context);
                if (request == InvalidHandle)
                {
                    Log.Print($"PocketTerm: keep awake: error {Marshal.GetLastWin32Error()}");
                    return;
                }
                if (!PowerSetRequest(request, PowerRequestSystemRequired))
                {
                    Log.Print($"PocketTerm: keep awake: error {Marshal.GetLastWin32Error()}");
                    CloseHandle(request);
                    return;
                }
                _awake = request;
            }
            finally
            {
                Marshal.FreeHGlobal(reason);
            }
        }
    }

    /// <summary>PocketTerm starts at login: the Run key has this executable with <c>--hidden</c> and Task Manager
    /// hasn't switched it off. False (logged) when the registry can't be read.</summary>
    [SupportedOSPlatform("windows")]
    public static bool LaunchAtLogin() => LaunchAtLogin(AppName, Exe());

    [SupportedOSPlatform("windows")]
    internal static bool LaunchAtLogin(string appName, string exe)
    {
        try
        {
            using var run = Registry.CurrentUser.OpenSubKey(RunKey);
            if (run?.GetValue(appName) as string != RunValue(exe)) return false;
            // launch_at_startup threw (and the Flutter app answered false) where this key is missing.
            using var approved = Registry.CurrentUser.OpenSubKey(StartupApprovedKey);
            if (approved == null) return false;
            return StartupApproved(approved.GetValue(appName) as byte[]);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            Log.Print($"PocketTerm: launch at login: {e.Message}");
            return false;
        }
    }

    /// <summary>Turns launch at login on or off as launch_at_startup did: the Run key's value and the
    /// StartupApproved value (on: 12 bytes, the first 2), both removed when off.</summary>
    [SupportedOSPlatform("windows")]
    public static void SetLaunchAtLogin(bool on) => SetLaunchAtLogin(on, AppName, Exe());

    [SupportedOSPlatform("windows")]
    internal static void SetLaunchAtLogin(bool on, string appName, string exe)
    {
        using var run = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
        using var approved = Registry.CurrentUser.CreateSubKey(StartupApprovedKey, writable: true);
        if (on)
        {
            run.SetValue(appName, RunValue(exe), RegistryValueKind.String);
            var bytes = new byte[StartupApprovedLength];
            // 2 first: Task Manager's Enabled.
            bytes[0] = 2;
            approved.SetValue(appName, bytes, RegistryValueKind.Binary);
        }
        else
        {
            run.DeleteValue(appName, throwOnMissingValue: false);
            approved.DeleteValue(appName, throwOnMissingValue: false);
        }
    }

    /// <summary>
    /// Launch at login reads and writes <c>Explorer\StartupApproved\Run</c> (Task Manager's Startup apps
    /// switch), which is missing on a profile where no app ever asked to start at login; made here,
    /// empty, so the Launch at login switch works there too.
    /// </summary>
    [SupportedOSPlatform("windows")]
    public static void EnsureStartupApproved()
    {
        try
        {
            Registry.CurrentUser.CreateSubKey(StartupApprovedKey).Dispose();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            Log.Print($"PocketTerm: StartupApproved: {e.Message}");
        }
    }

    /// <summary>Points <c>pocketterm://</c> (setup links, session links) at <paramref name="exe"/>, unless it
    /// already is. The installer writes the same keys; this follows a moved install or a development build.</summary>
    [SupportedOSPlatform("windows")]
    public static void RegisterLink(string exe) => RegisterLink(exe, @"Software\Classes\pocketterm");

    [SupportedOSPlatform("windows")]
    internal static void RegisterLink(string exe, string schemeKey)
    {
        var command = $"\"{exe}\" \"%1\"";
        try
        {
            using var open = Registry.CurrentUser.CreateSubKey($@"{schemeKey}\shell\open\command", writable: true);
            if (open.GetValue("") as string == command) return;
            using (var scheme = Registry.CurrentUser.CreateSubKey(schemeKey, writable: true))
            {
                scheme.SetValue("", "URL:PocketTerm", RegistryValueKind.String);
                scheme.SetValue("URL Protocol", "", RegistryValueKind.String);
            }
            open.SetValue("", command, RegistryValueKind.String);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            Log.Print($"PocketTerm: pocketterm:// not registered: {e.Message}");
        }
    }

    /// <summary>
    /// The PATH a new login would have now (<see cref="Terminal.MergeWindowsPath"/>): the system's and the
    /// user's <c>Path</c> from the registry, expanded, then this process's own. An app installed while
    /// PocketTerm runs (Claude Code, Node) is on it; PocketTerm's own environment is the one Explorer gave
    /// it at start.
    /// </summary>
    [SupportedOSPlatform("windows")]
    public static string FreshWindowsPath() =>
        Terminal.MergeWindowsPath(
            Environment.GetEnvironmentVariable("PATH") ?? "",
            machine: ReadPath(Registry.LocalMachine, @"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"),
            user: ReadPath(Registry.CurrentUser, "Environment"));

    [SupportedOSPlatform("windows")]
    private static string? ReadPath(RegistryKey hive, string path)
    {
        try
        {
            using var key = hive.OpenSubKey(path);
            // GetValue expands a REG_EXPAND_SZ (%SystemRoot%…) as win32_registry's expandPaths did.
            return key?.GetValue("Path") as string;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return null;
        }
    }

    private static string Exe() => Environment.ProcessPath ?? "";

    // ------------------------------------------------------------ Win32

    [StructLayout(LayoutKind.Sequential)]
    private struct LastInputInfo
    {
        public uint Size;
        public uint Time;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ReasonContext
    {
        public uint Version;
        public uint Flags;
        public IntPtr SimpleReasonString;
    }

    private const uint PowerRequestContextVersion = 0;
    private const uint PowerRequestContextSimpleString = 0x1;
    private const int PowerRequestSystemRequired = 1;
    private static readonly IntPtr InvalidHandle = new(-1);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetLastInputInfo(ref LastInputInfo info);

    [DllImport("kernel32.dll")]
    private static extern uint GetTickCount();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr PowerCreateRequest(ref ReasonContext context);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PowerSetRequest(IntPtr request, int type);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PowerClearRequest(IntPtr request, int type);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);
}
