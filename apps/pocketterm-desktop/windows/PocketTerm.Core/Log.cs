using System.Diagnostics;
using System.Globalization;

namespace PocketTerm.Core;

/// <summary>
/// Dart's <c>debugPrint</c>: the app's log lines (<c>PocketTerm: …</c>). They go to <see cref="Sink"/>,
/// which the app points at its log (and the end-to-end harness reads); by default the debugger's output.
/// </summary>
public static class Log
{
    /// <summary>Where lines go. Called on whatever thread logs.</summary>
    public static Action<string> Sink { get; set; } = line => Debug.WriteLine(line);

    /// <summary>One line (Dart's <c>debugPrint(line)</c>).</summary>
    public static void Print(string line)
    {
        try
        {
            Sink(line);
        }
        catch (Exception)
        {
            // A log that fails mustn't take what logged down with it.
        }
    }

    /// <summary>
    /// Debug builds only: one step of getting connected (the sign-in read, the WebSocket up, …), logged
    /// as <c>PocketTerm timing &lt;epoch ms&gt; &lt;what&gt;</c> for the end-to-end run's timing report.
    /// In release builds the call is compiled away (pass constant text).
    /// </summary>
    [Conditional("DEBUG")]
    public static void Timing(string what) =>
        Print($"PocketTerm timing {DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture)} {what}");
}
