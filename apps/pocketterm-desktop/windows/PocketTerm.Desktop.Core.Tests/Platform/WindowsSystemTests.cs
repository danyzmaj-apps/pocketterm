using Microsoft.Win32;
using PocketTerm.Core;
using PocketTerm.Desktop.Tests.Store;

namespace PocketTerm.Desktop.Tests;

public sealed class WindowsSystemTests
{
    [Fact]
    public void StartedHiddenOnlyWithTheHiddenArgument()
    {
        Assert.True(WindowsSystem.StartedHidden(["--hidden"]));
        Assert.True(WindowsSystem.StartedHidden(["pocketterm://setup?x=1", "--hidden"]));
        Assert.False(WindowsSystem.StartedHidden([]));
        Assert.False(WindowsSystem.StartedHidden(["--hiddenx", "hidden"]));
    }

    [Fact]
    public void IdleTimeSurvivesTheTickCountersWrap()
    {
        Assert.Equal(3, WindowsSystem.IdleSecondsOf(5_000, 2_000));
        Assert.Equal(0, WindowsSystem.IdleSecondsOf(2_999, 2_000));
        // 49.7 days after boot the counter starts again at 0: input 1 s before the wrap, now 1 s after.
        Assert.Equal(2, WindowsSystem.IdleSecondsOf(1_000, uint.MaxValue - 999));
    }

    [Fact]
    public void TheRunValueIsTheQuotedExecutableStartedHidden() =>
        Assert.Equal("\"C:\\Program Files\\PocketTerm\\PocketTerm.exe\" --hidden",
            WindowsSystem.RunValue(@"C:\Program Files\PocketTerm\PocketTerm.exe"));

    [Fact]
    public void TaskManagersSwitchIsOffOnlyForAnOddFirstByte()
    {
        Assert.True(WindowsSystem.StartupApproved(null));
        Assert.True(WindowsSystem.StartupApproved([]));
        Assert.True(WindowsSystem.StartupApproved([2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]));
        Assert.True(WindowsSystem.StartupApproved([6, 0]));
        Assert.False(WindowsSystem.StartupApproved([3, 0, 0, 0, 0x8e, 0x1a, 0, 0, 0, 0, 0, 0]));
    }

    [StoreWindowsFact]
    public void TheSupportFolderIsTheFlutterAppsOne()
    {
        if (!OperatingSystem.IsWindows()) return;
        Assert.Equal(
            Path.Combine(Environment.GetEnvironmentVariable("APPDATA")!, "Danijel Lovric", "PocketTerm"),
            AppPaths.SupportDir);
    }

    [StoreWindowsFact]
    public void LaunchAtLoginWritesTheRunKeyAndTaskManagersSwitchAsLaunchAtStartupDid()
    {
        if (!OperatingSystem.IsWindows()) return;
        var name = $"PocketTerm-test-{Guid.NewGuid():N}";
        const string exe = @"C:\Apps\PocketTerm\PocketTerm.exe";
        const string run = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string approved = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
        try
        {
            WindowsSystem.EnsureStartupApproved();
            Assert.False(WindowsSystem.LaunchAtLogin(name, exe));

            WindowsSystem.SetLaunchAtLogin(true, name, exe);
            using (var key = Registry.CurrentUser.OpenSubKey(run)!) Assert.Equal($"\"{exe}\" --hidden", key.GetValue(name));
            using (var key = Registry.CurrentUser.OpenSubKey(approved)!)
            {
                Assert.Equal(RegistryValueKind.Binary, key.GetValueKind(name));
                Assert.Equal(new byte[] { 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, key.GetValue(name));
            }
            Assert.True(WindowsSystem.LaunchAtLogin(name, exe));
            // Another install's entry isn't this one's.
            Assert.False(WindowsSystem.LaunchAtLogin(name, @"D:\Other\PocketTerm.exe"));

            // Task Manager's Disabled.
            using (var key = Registry.CurrentUser.OpenSubKey(approved, writable: true)!)
            {
                key.SetValue(name, new byte[] { 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, RegistryValueKind.Binary);
            }
            Assert.False(WindowsSystem.LaunchAtLogin(name, exe));

            WindowsSystem.SetLaunchAtLogin(false, name, exe);
            using (var key = Registry.CurrentUser.OpenSubKey(run)!) Assert.Null(key.GetValue(name));
            using (var key = Registry.CurrentUser.OpenSubKey(approved)!) Assert.Null(key.GetValue(name));
            Assert.False(WindowsSystem.LaunchAtLogin(name, exe));
        }
        finally
        {
            using (var key = Registry.CurrentUser.OpenSubKey(run, writable: true)) key?.DeleteValue(name, false);
            using (var key = Registry.CurrentUser.OpenSubKey(approved, writable: true)) key?.DeleteValue(name, false);
        }
    }

    [StoreWindowsFact]
    public void TheLinkIsRegisteredForThisExecutable()
    {
        if (!OperatingSystem.IsWindows()) return;
        var scheme = $@"Software\Classes\pocketterm-test-{Guid.NewGuid():N}";
        try
        {
            WindowsSystem.RegisterLink(@"C:\Apps\PocketTerm\PocketTerm.exe", scheme);
            using (var key = Registry.CurrentUser.OpenSubKey(scheme)!)
            {
                Assert.Equal("URL:PocketTerm", key.GetValue(""));
                Assert.Equal("", key.GetValue("URL Protocol"));
            }
            using (var key = Registry.CurrentUser.OpenSubKey($@"{scheme}\shell\open\command")!)
            {
                Assert.Equal("\"C:\\Apps\\PocketTerm\\PocketTerm.exe\" \"%1\"", key.GetValue(""));
            }
            // A moved install points it at the new place.
            WindowsSystem.RegisterLink(@"D:\PocketTerm\PocketTerm.exe", scheme);
            using (var key = Registry.CurrentUser.OpenSubKey($@"{scheme}\shell\open\command")!)
            {
                Assert.Equal("\"D:\\PocketTerm\\PocketTerm.exe\" \"%1\"", key.GetValue(""));
            }
        }
        finally
        {
            Registry.CurrentUser.DeleteSubKeyTree(scheme, throwOnMissingSubKey: false);
        }
    }

    [StoreWindowsFact]
    public void TheFreshPathStartsWithTheSystemsFoldersExpanded()
    {
        if (!OperatingSystem.IsWindows()) return;
        var system32 = Environment.GetFolderPath(Environment.SpecialFolder.System);
        var dirs = Terminal.WindowsPathDirs(WindowsSystem.FreshWindowsPath());
        Assert.Contains(dirs, d => string.Equals(d.TrimEnd('\\'), system32, StringComparison.OrdinalIgnoreCase));
    }
}
