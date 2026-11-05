using System.Diagnostics;
using System.Runtime.Versioning;

namespace PocketTerm.Desktop.Tests;

public class JobObjectTests
{
    [HostingWindowsFact]
    [SupportedOSPlatform("windows")]
    public void ClosingTheJobKillsWhatItHolds()
    {
        // A child that would run for a minute on its own.
        var psi = new ProcessStartInfo("ping") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
        foreach (var a in new[] { "-n", "60", "127.0.0.1" }) psi.ArgumentList.Add(a);
        using var child = Process.Start(psi)!;
        var job = JobObject.Create();
        job.Assign(child);
        Assert.False(child.HasExited);
        job.Dispose();
        Assert.True(child.WaitForExit(TimeSpan.FromSeconds(5)));
    }
}

/// <summary>Runs on Windows only.</summary>
file sealed class HostingWindowsFactAttribute : FactAttribute
{
    public HostingWindowsFactAttribute()
    {
        if (!OperatingSystem.IsWindows()) Skip = "Job Objects are Windows'.";
    }
}
