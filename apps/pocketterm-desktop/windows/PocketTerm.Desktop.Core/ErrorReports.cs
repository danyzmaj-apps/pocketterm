using System.Text.RegularExpressions;
using PocketTerm.Core;
using Sentry;

namespace PocketTerm.Desktop;

/// <summary>
/// Error reports to GlitchTip (Sentry's protocol): crashes and genuinely unexpected failures, nothing else. Off
/// unless the operator sets <c>POCKETTERM_SENTRY_DSN</c> in the environment (<c>setx POCKETTERM_SENTRY_DSN …</c>): the
/// app is self-hosted, so no DSN is built in. <c>POCKETTERM_SENTRY_ENVIRONMENT</c> and <c>POCKETTERM_SENTRY_RELEASE</c>
/// override the defaults. PocketTerm's own names, never Sentry's <c>SENTRY_*</c>: <c>setx</c> is global, so a developer's
/// own <c>SENTRY_DSN</c> mustn't opt PocketTerm into their project. The built-in server inherits all three
/// (<see cref="BuiltInServer"/> starts it with this process's environment) and reports its own errors.
/// <para>
/// What goes is the exception's type, its stack and a scrubbed message (<see cref="Scrub(string, string)"/>): no
/// breadcrumbs (they'd carry log lines and URLs), no user, request, machine or device name, no performance data,
/// no sessions.
/// </para>
/// </summary>
public static partial class ErrorReports
{
    /// <summary>The <c>component</c> tag every report carries (the server's say <c>server</c>).</summary>
    public const string Component = "app";

    /// <summary>The most of a message that goes: enough to tell errors apart, too little for a screen of terminal output.</summary>
    public const int MaxText = 300;

    /// <summary>
    /// Starts reporting when <c>POCKETTERM_SENTRY_DSN</c> is set; first thing in <c>Main</c>, so a crash at start is caught.
    /// Disposing flushes what's queued. A DSN the SDK rejects is logged, not fatal: reports are the operator's
    /// extra, never a reason for PocketTerm not to start.
    /// </summary>
    public static IDisposable Start()
    {
        var options = Options(Environment.GetEnvironmentVariable, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        if (options == null) return Off.Instance;
        try
        {
            return SentrySdk.Init(options);
        }
        catch (Exception e)
        {
            Log.Print($"PocketTerm: error reports are off: {e.Message}");
            return Off.Instance;
        }
    }

    /// <summary>The SDK's options from <paramref name="env"/>; null when there's no DSN (reporting stays off).</summary>
    /// <param name="home">The user's folder, written <c>~</c> in what's sent.</param>
    public static SentryOptions? Options(Func<string, string?> env, string home)
    {
        var dsn = env("POCKETTERM_SENTRY_DSN")?.Trim();
        if (string.IsNullOrEmpty(dsn)) return null;
        // Dsn, Environment and Release are always set here: the SDK reads SENTRY_DSN/_ENVIRONMENT/_RELEASE from the
        // environment only for options left null.
        var options = new SentryOptions
        {
            Dsn = dsn,
            Environment = Set(env("POCKETTERM_SENTRY_ENVIRONMENT")) ?? DefaultEnvironment,
            Release = Set(env("POCKETTERM_SENTRY_RELEASE")) ?? $"pocketterm-windows@{UpdateCheck.Installed()}",
            SendDefaultPii = false,
            // The SDK fills the machine's name in when this is null.
            ServerName = "",
            // Errors only: no performance data, no profiles, no sessions.
            TracesSampleRate = 0,
            AutoSessionTracking = false,
            // Breadcrumbs would carry log lines, terminal output and URLs.
            MaxBreadcrumbs = 0,
            DisableSentryHttpMessageHandler = true,
            SendClientReports = false,
            // A desktop app has one user: one scope for every thread.
            IsGlobalModeEnabled = true,
        };
        options.SetBeforeBreadcrumb((Breadcrumb _) => null);
        options.SetBeforeSend((evt, _) => Scrub(evt, home));
        options.DisableDiagnosticSourceIntegration();
        options.DisableSystemDiagnosticsMetricsIntegration();
        // Its reflection hook needs Application.Current, which doesn't exist yet when Main starts reporting: App
        // reports WinUI's unhandled exceptions itself (CaptureUnhandled).
        options.DisableWinUiUnhandledExceptionIntegration();
        return options;
    }

    /// <summary>
    /// An exception WinUI's <c>Application.UnhandledException</c> got: reported as unhandled even when the app
    /// keeps running past it (a screen's bug). Nothing happens while reporting is off.
    /// </summary>
    public static void CaptureUnhandled(Exception e, bool handled)
    {
        if (!SentrySdk.IsEnabled) return;
        e.SetSentryMechanism("Microsoft.UI.Xaml.UnhandledException", "Caught by WinUI's Application.UnhandledException.", handled);
        SentrySdk.CaptureException(e);
        // Not handled: the process is going down, so the report has to leave now.
        if (!handled) SentrySdk.Flush(TimeSpan.FromSeconds(2));
    }

    /// <summary>A failure the app logs and didn't expect (not a network error): reported, when reporting is on.</summary>
    public static void Capture(Exception e)
    {
        if (SentrySdk.IsEnabled) SentrySdk.CaptureException(e);
    }

    /// <summary>
    /// What leaves the computer: messages and exception values scrubbed, no user, request, server or device name,
    /// the user's folder as <c>~</c> in paths, and no exception data (it can carry anything). Types and stacks stay.
    /// </summary>
    internal static SentryEvent Scrub(SentryEvent evt, string home)
    {
        if (evt.Message is { } message)
        {
            message.Message = ScrubOrNull(message.Message, home);
            message.Formatted = ScrubOrNull(message.Formatted, home);
            message.Params = null;
        }
        foreach (var exception in evt.SentryExceptions ?? [])
        {
            exception.Value = ScrubOrNull(exception.Value, home);
            exception.Mechanism?.Data.Clear();
            foreach (var frame in exception.Stacktrace?.Frames ?? [])
            {
                frame.AbsolutePath = HomeOrNull(frame.AbsolutePath, home);
                frame.FileName = HomeOrNull(frame.FileName, home);
            }
        }
        foreach (var image in evt.DebugImages ?? [])
        {
            // Where PocketTerm's DLLs were loaded from: %LOCALAPPDATA%, under the user's folder.
            image.CodeFile = HomeOrNull(image.CodeFile, home);
            image.DebugFile = HomeOrNull(image.DebugFile, home);
        }
        evt.User = new SentryUser();
        evt.Request = new SentryRequest();
        evt.ServerName = null;
        evt.Contexts.Device.Name = null;
        evt.SetTag("component", Component);
        return evt;
    }

    /// <summary>
    /// <paramref name="text"/> without what could say who or where: the user's folder becomes <c>~</c>, URLs
    /// <c>scheme://&lt;redacted&gt;</c>, emails <c>&lt;email&gt;</c>, Tailscale and LAN host names <c>&lt;host&gt;</c>,
    /// IP addresses <c>&lt;ip&gt;</c>; then at most <see cref="MaxText"/> characters.
    /// </summary>
    public static string Scrub(string text, string home)
    {
        text = Home(text, home);
        text = UrlPattern().Replace(text, "${scheme}://<redacted>");
        text = EmailPattern().Replace(text, "<email>");
        text = HostPattern().Replace(text, "<host>");
        text = Ipv4Pattern().Replace(text, "<ip>");
        // An IPv6 address, not a time (12:30:45): it has "::" or at least three colons.
        text = Ipv6Pattern().Replace(text, m => m.Value.Contains("::", StringComparison.Ordinal) || m.Value.Count(c => c == ':') >= 3 ? "<ip>" : m.Value);
        return text.Length <= MaxText ? text : text[..MaxText];
    }

    /// <summary>The user's folder as <c>~</c>, either slash (Windows paths are case-insensitive).</summary>
    private static string Home(string text, string home)
    {
        home = home.TrimEnd('\\', '/');
        if (home.Length == 0) return text;
        text = text.Replace(home, "~", StringComparison.OrdinalIgnoreCase);
        return text.Replace(home.Replace('\\', '/'), "~", StringComparison.OrdinalIgnoreCase);
    }

    private static string? ScrubOrNull(string? text, string home) => text == null ? null : Scrub(text, home);

    private static string? HomeOrNull(string? text, string home) => text == null ? null : Home(text, home);

    private static string? Set(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

#if DEBUG
    private const string DefaultEnvironment = "development";
#else
    private const string DefaultEnvironment = "production";
#endif

    [GeneratedRegex(@"\b(?<scheme>[A-Za-z][A-Za-z0-9+.\-]*)://[^\s'""<>)\]]*")]
    private static partial Regex UrlPattern();

    [GeneratedRegex(@"[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}")]
    private static partial Regex EmailPattern();

    /// <summary>A Tailscale name (<c>pc.tail1234.ts.net</c>) or a LAN one (<c>pc.local</c>, <c>pc.lan</c>).</summary>
    [GeneratedRegex(@"\b[a-z0-9\-]+(?:\.[a-z0-9\-]+)*\.(?:ts\.net|local|lan)\b", RegexOptions.IgnoreCase)]
    private static partial Regex HostPattern();

    [GeneratedRegex(@"\b(?:\d{1,3}\.){3}\d{1,3}\b")]
    private static partial Regex Ipv4Pattern();

    [GeneratedRegex(@"(?<![\w:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:])")]
    private static partial Regex Ipv6Pattern();

    /// <summary>What <see cref="Start"/> returns while reporting is off.</summary>
    private sealed class Off : IDisposable
    {
        public static readonly Off Instance = new();

        public void Dispose()
        {
        }
    }
}
