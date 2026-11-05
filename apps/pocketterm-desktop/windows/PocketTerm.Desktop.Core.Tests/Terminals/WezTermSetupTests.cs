using System.Net;
using System.Security.Cryptography;
using System.Text;
using PocketTerm.Core.Tests;

namespace PocketTerm.Desktop.Tests;

/// <summary>Answers every request with <c>Answer</c>, checking it asks for WezTerm's installer.</summary>
internal sealed class SetupFakeHandler(Func<HttpResponseMessage> answer) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Assert.Equal(WezTermSetup.Url, request.RequestUri);
        return Task.FromResult(answer());
    }

    public static HttpClient Serving(byte[] body) =>
        new(new SetupFakeHandler(() => new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(body) }));
}

/// <summary>A body whose first bytes arrive, then nothing more.</summary>
internal sealed class SetupStallingStream(byte[] first) : Stream
{
    private bool _sent;

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        if (!_sent)
        {
            _sent = true;
            first.CopyTo(buffer);
            return first.Length;
        }
        await Task.Delay(Timeout.Infinite, cancellationToken);
        return 0;
    }

    public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}

public sealed class WezTermSetupTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("pocketterm_wezterm_setup").FullName;
    private static readonly byte[] Bytes = Encoding.UTF8.GetBytes("WezTerm setup");
    private static readonly string Good = Convert.ToHexString(SHA256.HashData(Bytes)).ToLowerInvariant();

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    [Fact]
    public async Task DownloadsTheInstallerOpensItAndIsDoneOnceWezTermIsFound()
    {
        var installed = false;
        var installer = new TaskCompletionSource();
        var opened = new List<string>();
        var open = new TaskCompletionSource();
        using var setup = new WezTermSetup(
            () => installed,
            SetupFakeHandler.Serving(Bytes),
            _dir,
            run: path =>
            {
                opened.Add(path);
                open.SetResult();
                return installer.Task;
            },
            poll: TimeSpan.FromMilliseconds(10),
            checksum: Good);

        var going = setup.InstallAsync();
        await open.Task;
        Assert.Equal(WezTermSetupState.Installing, setup.State);
        Assert.Equal(Bytes, File.ReadAllBytes(Assert.Single(opened))); // the installer it opens is the download

        installed = true;
        installer.SetResult();
        await going;
        Assert.Equal(WezTermSetupState.Installed, setup.State);
        Assert.Null(setup.Error);
    }

    [Fact]
    public async Task ADownloadThatDoesNotMatchThePublishedChecksumIsNeverOpened()
    {
        var opened = new List<string>();
        using var setup = new WezTermSetup(
            () => false,
            SetupFakeHandler.Serving(Encoding.UTF8.GetBytes("something else")),
            _dir,
            run: path =>
            {
                opened.Add(path);
                return Task.CompletedTask;
            },
            checksum: Good);

        await setup.InstallAsync();
        Assert.Empty(opened);
        Assert.Equal(WezTermSetupState.Missing, setup.State);
        Assert.Contains("checksum", setup.Error);
        Assert.Empty(Directory.EnumerateFileSystemEntries(_dir)); // the bad download is deleted
    }

    [Fact]
    public async Task ClosingTheInstallerWithoutInstallingLeavesItMissingReadyToTryAgain()
    {
        var installer = new TaskCompletionSource();
        using var setup = new WezTermSetup(() => false, SetupFakeHandler.Serving(Bytes), _dir, run: _ => installer.Task, checksum: Good);

        var going = setup.InstallAsync();
        await Wait.Until(() => setup.State == WezTermSetupState.Installing);
        installer.SetResult();
        await going;
        Assert.Equal(WezTermSetupState.Missing, setup.State);
        Assert.Equal("The installer closed before WezTerm was installed.", setup.Error);
        Assert.Equal(setup.Error, setup.Note);
    }

    [Fact]
    public async Task WezTermInstalledAnotherWayIsNoticedWithoutAClick()
    {
        var installed = false;
        using var setup = new WezTermSetup(() => installed, SetupFakeHandler.Serving(Bytes), _dir, poll: TimeSpan.FromMilliseconds(10));
        Assert.Equal(WezTermSetupState.Missing, setup.State);

        installed = true;
        await Wait.Until(() => setup.State == WezTermSetupState.Installed, seconds: 2);
    }

    [Fact]
    public async Task ADownloadThatStallsMidWayStopsWithAnErrorReadyToTryAgain()
    {
        using var setup = new WezTermSetup(
            () => false,
            new HttpClient(new SetupFakeHandler(() =>
                new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new SetupStallingStream(Bytes)) })),
            _dir,
            run: _ => throw new InvalidOperationException("a stalled download is never opened"),
            stall: TimeSpan.FromMilliseconds(50),
            checksum: Good);

        await setup.InstallAsync();
        Assert.Equal(WezTermSetupState.Missing, setup.State);
        Assert.Contains("stopped answering", setup.Error);
    }

    [Fact]
    public async Task AnErrorFromGitHubSaysItsStatusAndADownloadShowsHowFarItIs()
    {
        using var refused = new WezTermSetup(
            () => false,
            new HttpClient(new SetupFakeHandler(() => new HttpResponseMessage(HttpStatusCode.NotFound))),
            _dir,
            checksum: Good);
        await refused.InstallAsync();
        Assert.Equal("WezTerm didn't download: HttpException: GitHub answered 404", refused.Error);

        var notes = new List<string?>();
        var installer = new TaskCompletionSource();
        using var setup = new WezTermSetup(() => false, SetupFakeHandler.Serving(Bytes), _dir, run: _ => installer.Task, checksum: Good);
        setup.PropertyChanged += (_, _) => notes.Add(setup.Note);
        var going = setup.InstallAsync();
        await Wait.Until(() => setup.State == WezTermSetupState.Installing);
        Assert.Equal("Downloading WezTerm…", notes[0]);
        Assert.Contains("Downloading WezTerm · 100%…", notes);
        Assert.Equal("WezTerm's installer is open: click through it, then come back here.", setup.Note);
        // A second click while it runs does nothing.
        await setup.InstallAsync();
        Assert.Equal(WezTermSetupState.Installing, setup.State);
        installer.SetResult();
        await going;
    }
}
