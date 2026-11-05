using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using PocketTerm.App.Components;
using PocketTerm.App.Views;
using PocketTerm.Core;
using PocketTerm.Desktop;

namespace PocketTerm.App.Pages;

/// <summary>
/// Not yet: the VPS's address, the commands that set the server up there (<see cref="Vps"/>), and checks that follow
/// it live (the name resolves, HTTPS answers, the server is healthy); once it is, its setup link.
/// </summary>
internal sealed class NewServerSetup : View
{
    private const string SelfHostingGuide =
        "https://github.com/danyzmaj-apps/pocketterm/blob/main/docs/SELF_HOSTING.md#on-my-own-server";

    private readonly AppController _app;
    private readonly ServerChecks _checks;
    private readonly TextBox _address;
    private ServerAddress _parsed;

    /// <summary>What the checks found for <see cref="_checked"/>: null until known.</summary>
    private string? _checked;
    private bool? _resolves;
    private bool? _https;
    private bool? _healthy;
    private string? _healthProblem;

    /// <summary>This computer's clock is too far off the server's (<see cref="Backend.ClockWarning"/>).</summary>
    private string? _clock;
    private bool _looking;

    /// <summary>The domain the commands and the link form were made for.</summary>
    private string? _shownFor;

    public NewServerSetup(AppController app, Action onBack, TimeSpan? poll = null, ServerChecks? checks = null)
    {
        _app = app;
        _checks = checks ?? new ServerChecks();
        var every = poll ?? TimeSpan.FromSeconds(3);
        _parsed = ServerAddress.Parse(app.SetupAddress);
        _address = new TextBox
        {
            Text = app.SetupAddress,
            PlaceholderText = "203.0.113.7 or pocketterm.example.com",
            IsSpellCheckEnabled = false,
            IsTextPredictionEnabled = false,
            InputScope = new InputScope { Names = { new InputScopeName(InputScopeNameValue.Url) } },
        }.Id("setup-address", "Server address");
        _address.TextChanged += (_, _) => Changed(_address.Text);

        var addressError = Ui.Text("", TextKind.Error).Id("setup-address-error");
        var domainText = Ui.Dim("").Id("setup-domain");
        var ssh = new CopyCommand("", "setup-ssh");
        var commands = Ui.Stack(12);
        var checking = Ui.Strong("");
        var dns = new SetupCheck(CheckState.Later, "", id: "check-dns");
        var https = new SetupCheck(
            CheckState.Later,
            "HTTPS answers",
            "Not yet. Run steps 1 to 3. Getting the certificate takes a minute after the server starts; if it stays " +
            "here, open ports 80 and 443.",
            id: "check-https");
        var health = new SetupCheck(CheckState.Later, "The PocketTerm server answers", id: "check-health");
        var clock = SetupParts.Notice(null, "setup-clock", InfoBarSeverity.Warning, Ui.Glyph.Clock);
        var linkHost = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch, IsTabStop = false };
        var up = Ui.Stack(
            10,
            Ui.Text("Your server is up. Paste the setup link step 4 printed:"),
            linkHost).Margin(0, 14, 0, 0);

        var domainPart = Ui.Stack(
            0,
            domainText,
            SetupParts.Notice(
                "Ports 80 and 443 must be open to the internet: check your provider’s firewall. The server gets its " +
                "certificate from Let’s Encrypt, which checks port 80.",
                "setup-ports",
                glyph: Ui.Glyph.Shield).Margin(0, 16, 0, 0),
            Ui.Text(
                "Run these on the server, not here. To get there, type this in PowerShell " +
                "(some providers sign you in as ubuntu or debian instead of root):").Margin(0, 16, 0, 6),
            ssh,
            commands.Margin(0, 16, 0, 0),
            Ui.Dim("Signed in as root? You can leave out sudo.").Margin(0, 4, 0, 0),
            checking.Margin(0, 16, 0, 4),
            dns,
            https,
            health,
            clock.Margin(0, 10, 0, 0),
            up);

        Content = Ui.Stack(
            0,
            SetupParts.Header(
                "Set up a server on a VPS",
                "Rent a small Linux VPS from any provider (1 GB of memory is plenty) and open a terminal on it with SSH. " +
                "What’s its address?",
                onBack),
            new Explainer(
                "What do Docker and Caddy do?",
                "Docker runs the PocketTerm server in a container, so nothing else on the VPS changes. Caddy runs next to " +
                "it: it answers on ports 80 and 443 and gets a free HTTPS certificate from Let’s Encrypt, renewing it on " +
                "its own. The server keeps your device list, computer names, pairing codes and push tokens, and passes " +
                "your encrypted messages along.",
                "why-docker").Margin(0, 0, 0, 8),
            _address,
            addressError.Margin(0, 8, 0, 0),
            domainPart.Margin(0, 8, 0, 0),
            Ui.WebLink("The full guide, with other ways to run it", SelfHostingGuide, "setup-guide").Margin(0, 14, 0, 0));

        OnRefresh(() =>
        {
            var domain = _parsed.Domain;
            var typed = _address.Text.DartTrim().Length > 0;
            addressError.Text = _parsed.Error ?? "";
            addressError.Shown(typed && _parsed.Error != null);
            domainPart.Shown(domain != null);
            if (domain == null) return;
            if (domain != _shownFor)
            {
                _shownFor = domain;
                var sslip = domain.EndsWith(".sslip.io", StringComparison.Ordinal);
                domainText.Inlines.Clear();
                domainText.Inlines.Add(new Run { Text = "Your server’s name: " });
                domainText.Inlines.Add(new Run { Text = domain, FontWeight = FontWeights.SemiBold });
                domainText.Inlines.Add(new Run
                {
                    Text = sslip
                        ? " (sslip.io turns the IP address into a name, so the server gets an HTTPS certificate)."
                        : ". Point its DNS A record at the server first.",
                });
                commands.Children.Clear();
                foreach (var (c, i) in Vps.Commands(domain, Shell.Version).Select((c, i) => (c, i)))
                {
                    commands.Children.Add(Ui.Stack(6, Ui.Strong($"{i + 1}. {c.Title}"), new CopyCommand(c.Command, $"setup-command-{i}")));
                }
                checking.Text = $"Checking {domain}";
                dns.Title = $"{domain} resolves";
                dns.Note = sslip
                    ? "sslip.io doesn’t answer. Check this computer’s internet connection."
                    : $"Not yet. Add an A record for {domain} with your server’s IP address; it can take a few minutes.";
                linkHost.Content = null;
            }
            ssh.Command = _parsed.Ssh ?? "";
            dns.State = Check(_resolves, reached: true);
            https.State = Check(_https, reached: _resolves ?? false);
            health.State = Check(_healthy, reached: _https ?? false);
            health.Note = _healthProblem ?? "Not yet.";
            SetupParts.Show(clock, _clock);
            var healthy = _healthy ?? false;
            up.Shown(healthy);
            // A new form each time the server comes up (as the Flutter one was rebuilt): nothing pasted for another address stays.
            if (healthy && linkHost.Content == null) linkHost.Content = new SetupLinkForm(_app, _checks, clock: false);
            if (!healthy) linkHost.Content = null;
        });

        if (every > TimeSpan.Zero) Every(every, LookAsync);
        else Run(LookAsync);
    }

    private static CheckState Check(bool? ok, bool reached) => ok switch
    {
        true => CheckState.Done,
        false => CheckState.Now,
        null when !reached => CheckState.Later,
        null => CheckState.Looking,
    };

    private void Changed(string text)
    {
        if (text != _app.SetupAddress) _app.SetSetupAddress(text);
        _parsed = ServerAddress.Parse(text);
        if (_parsed.Domain != _checked) Run(LookAsync);
        else Refresh();
    }

    /// <summary>One round of checks on the address as it is now, each only once the one before passed. A healthy
    /// server isn't looked at again.</summary>
    private async Task LookAsync()
    {
        var domain = _parsed.Domain;
        if (domain != _checked)
        {
            _checked = domain;
            _resolves = _https = _healthy = null;
            _healthProblem = _clock = null;
            Refresh();
        }
        if (domain == null || (_healthy ?? false) || _looking) return;
        _looking = true;
        try
        {
            var resolves = await _checks.ResolvesAsync(domain);
            var https = resolves && await _checks.HttpsAsync(domain);
            BackendHealth? health = https ? await _checks.HealthAsync(domain) : null;
            if (!Live || _checked != domain) return;
            _resolves = resolves;
            _https = resolves ? https : null;
            _healthy = health == null ? null : health.Value.Error == null;
            _healthProblem = health?.Error;
            _clock = Backend.ClockWarning(health?.ClockOffset);
        }
        finally
        {
            _looking = false;
            // The address changed while this round ran: look at the new one now.
            if (Live && domain != _parsed.Domain) Run(LookAsync);
        }
    }
}
