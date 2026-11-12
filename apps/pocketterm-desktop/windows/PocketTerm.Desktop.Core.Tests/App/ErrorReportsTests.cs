using System.Text;
using System.Text.Json.Nodes;
using PocketTerm.Desktop;
using Sentry;
using Sentry.Extensibility;
using Sentry.Protocol.Envelopes;

namespace PocketTerm.Desktop.Tests;

public class ErrorReportsTests
{
    private const string Home = @"C:\Users\alice";
    private const string Dsn = "https://public@glitchtip.example.invalid/1";

    private static Func<string, string?> Env(params (string Key, string Value)[] vars) =>
        key => vars.FirstOrDefault(v => v.Key == key).Value;

    [Fact]
    public void WithoutADsnReportingStaysOff()
    {
        Assert.Null(ErrorReports.Options(Env(), Home));
        Assert.Null(ErrorReports.Options(Env(("POCKETTERM_SENTRY_DSN", "")), Home));
        Assert.Null(ErrorReports.Options(Env(("POCKETTERM_SENTRY_DSN", "   ")), Home));
        // The others alone don't turn it on.
        Assert.Null(ErrorReports.Options(Env(("POCKETTERM_SENTRY_ENVIRONMENT", "staging"), ("POCKETTERM_SENTRY_RELEASE", "x@1")), Home));
    }

    [Fact]
    public void SentrysOwnVariablesNeitherTurnItOnNorChangeIt()
    {
        // A developer's global SENTRY_DSN (setx) is for their own project, not PocketTerm.
        Assert.Null(ErrorReports.Options(Env(("SENTRY_DSN", Dsn)), Home));
        var options = ErrorReports.Options(
            Env(("POCKETTERM_SENTRY_DSN", Dsn), ("SENTRY_DSN", "https://other@sentry.example.invalid/2"),
                ("SENTRY_ENVIRONMENT", "theirs"), ("SENTRY_RELEASE", "theirs@1")),
            Home)!;
        Assert.Equal(Dsn, options.Dsn);
        // Set, so the SDK doesn't fall back to SENTRY_ENVIRONMENT/SENTRY_RELEASE from the process's environment.
        Assert.NotEqual("theirs", options.Environment);
        Assert.False(string.IsNullOrWhiteSpace(options.Environment));
        Assert.StartsWith("pocketterm-windows@", options.Release);
    }

    [Fact]
    public void ADsnTurnsItOnWithErrorsOnlyAndNothingThatNamesTheMachine()
    {
        var options = ErrorReports.Options(Env(("POCKETTERM_SENTRY_DSN", $"  {Dsn}\n")), Home)!;
        Assert.Equal(Dsn, options.Dsn);
        Assert.StartsWith("pocketterm-windows@", options.Release);
#if DEBUG
        Assert.Equal("development", options.Environment);
#else
        Assert.Equal("production", options.Environment);
#endif
        Assert.False(options.SendDefaultPii);
        Assert.Equal(0, options.TracesSampleRate);
        Assert.Equal(0, options.MaxBreadcrumbs);
        Assert.False(options.AutoSessionTracking);
        Assert.Equal("", options.ServerName);
    }

    [Fact]
    public void ItsEnvironmentAndReleaseVariablesOverrideTheDefaults()
    {
        var options = ErrorReports.Options(
            Env(("POCKETTERM_SENTRY_DSN", Dsn), ("POCKETTERM_SENTRY_ENVIRONMENT", "staging"), ("POCKETTERM_SENTRY_RELEASE", "pocketterm-windows@9.9.9")),
            Home)!;
        Assert.Equal("staging", options.Environment);
        Assert.Equal("pocketterm-windows@9.9.9", options.Release);
    }

    [Theory]
    [InlineData(@"Can't read C:\Users\alice\AppData\Roaming\x.json", @"Can't read ~\AppData\Roaming\x.json")]
    [InlineData("Can't read c:/users/ALICE/.wezterm.lua", "Can't read ~/.wezterm.lua")]
    [InlineData("GET https://pc.tail1234.ts.net:8443/api?token=abc failed", "GET https://<redacted> failed")]
    [InlineData("Opening pocketterm://setup?url=x&token=y", "Opening pocketterm://<redacted>")]
    [InlineData("Connection refused (100.64.1.2:7681)", "Connection refused (<ip>:7681)")]
    [InlineData("No route to fd7a:115c:a1e0::1 or fe80::1", "No route to <ip> or <ip>")]
    [InlineData("No route to 2001:db8:0:0:0:0:0:1", "No route to <ip>")]
    [InlineData("Signed in as alice.smith@example.com", "Signed in as <email>")]
    [InlineData("Can't resolve desktop.tail1234.ts.net, studio.local or nas.lan", "Can't resolve <host>, <host> or <host>")]
    [InlineData("Timed out at 12:30:45 after 3.5 s", "Timed out at 12:30:45 after 3.5 s")]
    [InlineData("Object reference not set to an instance of an object.", "Object reference not set to an instance of an object.")]
    public void ScrubTakesOutWhoAndWhereAndKeepsTheRest(string text, string expected)
    {
        Assert.Equal(expected, ErrorReports.Scrub(text, Home));
    }

    [Fact]
    public void ScrubKeepsAtMostThreeHundredCharacters()
    {
        var scrubbed = ErrorReports.Scrub("x" + new string('y', 5000), Home);
        Assert.Equal(ErrorReports.MaxText, scrubbed.Length);
        Assert.StartsWith("xy", scrubbed);
    }

    [Fact]
    public async Task AReportLeavesScrubbedWithoutUserServerOrExceptionData()
    {
        var transport = new CapturingTransport();
        var options = ErrorReports.Options(Env(("POCKETTERM_SENTRY_DSN", Dsn)), Home)!;
        options.Transport = transport;
        options.AutoSessionTracking = false;
        using (var client = new SentryClient(options))
        {
            Exception error;
            try
            {
                throw new InvalidOperationException(@"Couldn't open C:\Users\alice\x for bob@example.com at http://10.0.0.7:7681/live");
            }
            catch (InvalidOperationException e)
            {
                error = e;
            }
            error.Data["terminal"] = "secret terminal output";
            var evt = new SentryEvent(error)
            {
                User = new SentryUser { Username = "alice", IpAddress = "10.0.0.7" },
                ServerName = "ALICES-PC",
            };
            evt.SetExtra("ignored", "kept");
            client.CaptureEvent(evt);
            await client.FlushAsync(TimeSpan.FromSeconds(5));
        }

        var sent = Assert.Single(transport.Events);
        var json = JsonNode.Parse(sent)!;
        var exception = json["exception"]!["values"]![0]!;
        Assert.Equal("System.InvalidOperationException", (string?)exception["type"]);
        Assert.Equal(@"Couldn't open ~\x for <email> at http://<redacted>", (string?)exception["value"]);
        Assert.NotNull(exception["stacktrace"]);
        Assert.Equal("app", (string?)json["tags"]!["component"]);
        foreach (var leak in new[] { "alice", "bob@", "10.0.0.7", "ALICES-PC", "secret terminal output", "server_name" })
        {
            Assert.DoesNotContain(leak, sent, StringComparison.OrdinalIgnoreCase);
        }
    }

    /// <summary>The events the SDK would have sent, as the JSON on the wire; nothing goes over the network.</summary>
    private sealed class CapturingTransport : ITransport
    {
        public List<string> Events { get; } = [];

        public async Task SendEnvelopeAsync(Envelope envelope, CancellationToken cancellationToken = default)
        {
            foreach (var item in envelope.Items.Where(i => i.TryGetType() == "event"))
            {
                using var stream = new MemoryStream();
                await item.Payload.SerializeAsync(stream, null, cancellationToken);
                lock (Events) Events.Add(Encoding.UTF8.GetString(stream.ToArray()));
            }
        }
    }
}
