using System.Diagnostics;
using System.Security.Cryptography;
using PocketTerm.Core;

namespace PocketTerm.Desktop;

/// <summary>Where <see cref="WezTermSetup"/> is.</summary>
public enum WezTermSetupState
{
    /// <summary>Not installed, nothing going on.</summary>
    Missing,

    /// <summary>Fetching WezTerm's installer.</summary>
    Downloading,

    /// <summary>WezTerm's installer is open: the person clicks through it.</summary>
    Installing,

    /// <summary>WezTerm is on this PC.</summary>
    Installed,
}

/// <summary>
/// WezTerm on Windows, the one terminal PocketTerm drives there. <see cref="InstallAsync"/> fetches
/// WezTerm's own installer for the release PocketTerm is tested with from WezTerm's GitHub release,
/// checks it against the SHA-256 WezTerm publishes, and opens it: the person sees WezTerm's usual setup
/// and Windows' admin prompt, nothing runs silently. Whichever way WezTerm arrives (this, or
/// <see cref="WingetCommand"/> in a terminal), <see cref="Installed"/> turns true within the
/// constructor's <c>poll</c>.
/// Shown by the setup checklist's WezTerm card and Settings → Terminals (its Install fix). Thread-safe:
/// state sits behind a lock; <c>PropertyChanged</c> fires on the installing task's or the poll timer's
/// thread.
/// </summary>
public sealed class WezTermSetup : ObservableObject, IDisposable
{
    /// <param name="isInstalled">Whether WezTerm is on this PC now.</param>
    /// <param name="downloads">Where the installer goes: <c>%TEMP%\pocketterm</c> if null.</param>
    /// <param name="run">Opens the installer at the path given; the task ends when it closes.</param>
    /// <param name="poll">How often <paramref name="isInstalled"/> is asked while it's missing (2 s).</param>
    /// <param name="stall">How long the download may go without an answer or a byte (30 s).</param>
    /// <param name="checksum">The SHA-256 (hex) a download must have to be opened.</param>
    public WezTermSetup(
        Func<bool> isInstalled,
        HttpClient? client = null,
        string? downloads = null,
        Func<string, Task>? run = null,
        TimeSpan? poll = null,
        TimeSpan? stall = null,
        string checksum = Sha256Hex)
    {
        IsInstalled = isInstalled;
        _client = client ?? new HttpClient();
        _downloads = downloads ?? Path.Combine(Path.GetTempPath(), "pocketterm");
        _run = run ?? RunInstallerAsync;
        Stall = stall ?? TimeSpan.FromSeconds(30);
        Checksum = checksum;
        if (isInstalled())
        {
            _state = WezTermSetupState.Installed;
        }
        else
        {
            var every = poll ?? TimeSpan.FromSeconds(2);
            _timer = new Timer(_ => Look(), null, every, every);
        }
    }

    /// <summary>This PC's: on Windows, for its WezTerm <paramref name="host"/>; null elsewhere (a Mac has
    /// other terminals, and WezTerm there is the person's choice).</summary>
    public static WezTermSetup? ForHost(WezTerm? host) =>
        OperatingSystem.IsWindows() && host != null ? new WezTermSetup(() => host.Installed) : null;

    /// <summary>The release PocketTerm is tested with.</summary>
    public const string Version = "20240203-110809-5046fc22";

    /// <summary>Its installer's SHA-256 as WezTerm publishes it (<c>&lt;installer&gt;.sha256</c> on the release).</summary>
    public const string Sha256Hex = "35a6ec0eff7aa65e3987f14223bfb9df831eaab2964eb441ed6cad4356d252ff";

    private const string FileName = $"WezTerm-{Version}-setup.exe";

    /// <summary>The installer on WezTerm's GitHub release.</summary>
    public static readonly Uri Url = new($"https://github.com/wez/wezterm/releases/download/{Version}/{FileName}");

    /// <summary>The same, typed into PowerShell or Command Prompt.</summary>
    public const string WingetCommand = "winget install --id wez.wezterm --exact";

    /// <summary>Whether WezTerm is on this PC now.</summary>
    public Func<bool> IsInstalled { get; }

    /// <summary>How long the download may go without an answer or a byte before it stops with an error
    /// (a stalled connection, a captive portal).</summary>
    public TimeSpan Stall { get; }

    /// <summary>The installer's SHA-256 a download must have to be opened.</summary>
    public string Checksum { get; }

    private readonly HttpClient _client;
    private readonly string _downloads;
    private readonly Func<string, Task> _run;
    private readonly object _lock = new();
    private Timer? _timer;
    private WezTermSetupState _state = WezTermSetupState.Missing;
    private double? _progress;
    private string? _error;

    public WezTermSetupState State
    {
        get { lock (_lock) return _state; }
    }

    /// <summary>While downloading: how far, 0–1; null while the size is unknown.</summary>
    public double? Progress
    {
        get { lock (_lock) return _progress; }
    }

    /// <summary>Why the last <see cref="InstallAsync"/> stopped.</summary>
    public string? Error
    {
        get { lock (_lock) return _error; }
    }

    public bool Installed => State == WezTermSetupState.Installed;

    /// <summary>What it's doing, for a row's note; null when there's nothing to say.</summary>
    public string? Note
    {
        get
        {
            lock (_lock)
            {
                return _state switch
                {
                    WezTermSetupState.Downloading =>
                        $"Downloading WezTerm{(_progress == null ? "" : $" · {(int)Math.Round(_progress.Value * 100, MidpointRounding.AwayFromZero)}%")}…",
                    WezTermSetupState.Installing => "WezTerm's installer is open: click through it, then come back here.",
                    WezTermSetupState.Installed => null,
                    _ => _error,
                };
            }
        }
    }

    private void Look()
    {
        if (!IsInstalled()) return;
        lock (_lock)
        {
            _timer?.Dispose();
            _timer = null;
            _state = WezTermSetupState.Installed;
            _error = null;
        }
        NotifyChanged();
    }

    /// <summary>Sets <paramref name="s"/> only while it's still <paramref name="from"/>: WezTerm found
    /// meanwhile stays found.</summary>
    private bool SetFrom(WezTermSetupState from, WezTermSetupState s, string? error = null)
    {
        lock (_lock)
        {
            if (_state != from) return false;
            _state = s;
            _error = error;
            _progress = null;
        }
        NotifyChanged();
        return true;
    }

    /// <summary>Downloads, checks and opens WezTerm's installer; done once WezTerm is found. A second call
    /// while one runs does nothing.</summary>
    public async Task InstallAsync()
    {
        lock (_lock)
        {
            if (_state != WezTermSetupState.Missing) return;
            _state = WezTermSetupState.Downloading;
            _error = null;
            _progress = null;
        }
        NotifyChanged();
        string file;
        try
        {
            file = await DownloadAsync();
        }
        catch (Exception e)
        {
            SetFrom(
                WezTermSetupState.Downloading,
                WezTermSetupState.Missing,
                e switch
                {
                    MismatchException m => m.Message,
                    TimeoutException => "WezTerm didn't download: the connection stopped answering.",
                    _ => $"WezTerm didn't download: {e.Message}",
                });
            return;
        }
        if (!SetFrom(WezTermSetupState.Downloading, WezTermSetupState.Installing)) return;
        try
        {
            await _run(file);
        }
        catch (Exception e)
        {
            SetFrom(WezTermSetupState.Installing, WezTermSetupState.Missing, $"WezTerm's installer didn't open: {e.Message}");
            return;
        }
        // The installer has closed: installed, or given up on.
        Look();
        SetFrom(WezTermSetupState.Installing, WezTermSetupState.Missing, "The installer closed before WezTerm was installed.");
    }

    private async Task<string> DownloadAsync()
    {
        using var stall = new CancellationTokenSource(Stall);
        HttpResponseMessage response;
        try
        {
            response = await _client.GetAsync(Url, HttpCompletionOption.ResponseHeadersRead, stall.Token);
        }
        catch (OperationCanceledException) when (stall.IsCancellationRequested)
        {
            throw new TimeoutException();
        }
        using (response)
        {
            // As Dart's HttpException said it.
            if ((int)response.StatusCode != 200) throw new HttpRequestException($"HttpException: GitHub answered {(int)response.StatusCode}");
            Directory.CreateDirectory(_downloads);
            var file = Path.Combine(_downloads, FileName);
            var total = response.Content.Headers.ContentLength;
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            await using (var sink = new FileStream(file, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                await using var body = await response.Content.ReadAsStreamAsync(stall.Token);
                var buffer = new byte[81920];
                long got = 0;
                while (true)
                {
                    stall.CancelAfter(Stall);
                    int n;
                    try
                    {
                        n = await body.ReadAsync(buffer, stall.Token);
                    }
                    catch (OperationCanceledException) when (stall.IsCancellationRequested)
                    {
                        throw new TimeoutException();
                    }
                    if (n == 0) break;
                    await sink.WriteAsync(buffer.AsMemory(0, n));
                    hash.AppendData(buffer, 0, n);
                    got += n;
                    if (total is > 0)
                    {
                        lock (_lock) _progress = (double)got / total.Value;
                        NotifyChanged();
                    }
                }
            }
            if (Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant() != Checksum)
            {
                File.Delete(file);
                throw new MismatchException();
            }
            return file;
        }
    }

    /// <summary>Opens the installer as is (WezTerm's setup asks Windows for admin itself); ends when it closes.</summary>
    private static async Task RunInstallerAsync(string path)
    {
        using var p = Process.Start(new ProcessStartInfo(path) { UseShellExecute = false })
            ?? throw new InvalidOperationException("it didn't start");
        await p.WaitForExitAsync();
    }

    public void Dispose()
    {
        lock (_lock)
        {
            _timer?.Dispose();
            _timer = null;
        }
        _client.Dispose();
    }

    private sealed class MismatchException()
        : Exception("The download didn't match WezTerm's published checksum, so PocketTerm didn't open it.");
}
