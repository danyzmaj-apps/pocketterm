using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using PocketTerm.App.Pages;
using PocketTerm.App.Views;
using PocketTerm.Core;
using PocketTerm.Desktop;

namespace PocketTerm.App.Components;

/// <summary>
/// A setup link, checked as it's pasted (a link at all, a computer's, its server answering, this computer's clock
/// against the server's), then redeemed by Connect.
/// </summary>
internal sealed class SetupLinkForm : View
{
    private readonly AppController _app;
    private readonly ServerChecks _checks;
    private readonly TextBox _link;
    private bool _busy;
    private string? _error;

    /// <summary>The pasted link's server: null while not asked, <c>""</c> while asking.</summary>
    private string? _health;

    /// <summary>This computer's clock is too far off the server's (<see cref="Backend.ClockWarning"/>).</summary>
    private string? _clock;
    private int _asked;

    /// <param name="app">Signs in with the link.</param>
    /// <param name="checks">What asks the pasted link's server for its health.</param>
    /// <param name="clock">Says when this computer's clock is off the server's; false where the screen already says so.</param>
    public SetupLinkForm(AppController app, ServerChecks? checks = null, bool clock = true)
    {
        _app = app;
        _checks = checks ?? new ServerChecks();
        _link = new TextBox
        {
            PlaceholderText = "pocketterm://setup?url=…&setup=…",
            IsSpellCheckEnabled = false,
            IsTextPredictionEnabled = false,
            InputScope = new InputScope { Names = { new InputScopeName(InputScopeNameValue.Url) } },
        }.Id("setup-link", "Setup link");
        _link.TextChanged += (_, _) => Changed(_link.Text);
        _link.KeyDown += (_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.Enter || _busy) return;
            e.Handled = true;
            Run(ConnectAsync);
        };

        var asking = new ProgressRing { IsActive = true, Width = 14, Height = 14 };
        var answers = Ui.Icon(Ui.Glyph.Check, 14, "PtOkIcon");
        var healthText = Ui.Dim("").Id("setup-link-health");
        var health = Ui.Row(8, asking, answers, healthText);
        var clockNotice = SetupParts.Notice(null, "setup-link-clock", InfoBarSeverity.Warning, Ui.Glyph.Clock);
        var connect = SetupParts.Primary("Connect", () => Run(ConnectAsync), "setup-connect");
        var error = SetupParts.Error("setup-error");

        Content = Ui.Stack(10, _link, health, clockNotice, connect.Margin(0, 4, 0, 0), error);
        OnRefresh(() =>
        {
            _link.IsEnabled = !_busy;
            health.Shown(_health != null && _error == null);
            asking.Shown(_health == "");
            answers.Shown(!string.IsNullOrEmpty(_health));
            healthText.Text = _health == "" ? "Asking the server…" : _health ?? "";
            SetupParts.Show(clockNotice, clock ? _clock : null);
            SetupParts.Busy(connect, "Connect", _busy);
            SetupParts.Show(error, _error);
        });
    }

    private void Changed(string text)
    {
        var asked = ++_asked;
        var trimmed = text.DartTrim();
        var problem = trimmed.Length == 0 ? null : SetupLinks.Problem(text);
        _error = problem;
        _health = null;
        _clock = null;
        if (trimmed.Length == 0 || problem != null)
        {
            Refresh();
            return;
        }
        var backend = Backend.FromLink(trimmed)!;
        _health = "";
        Refresh();
        Run(async () =>
        {
            var h = await _checks.AnswersAsync(backend);
            if (!Live || asked != _asked) return;
            _health = h.Error == null ? $"{backend.Host} answers" : null;
            _error = h.Error;
            _clock = Backend.ClockWarning(h.ClockOffset);
        });
    }

    private async Task ConnectAsync()
    {
        if (SetupLinks.Problem(_link.Text) is { } problem)
        {
            _error = problem;
            return;
        }
        _asked++;
        _busy = true;
        _error = null;
        Refresh();
        try
        {
            await _app.ConnectLink(_link.Text.DartTrim());
            // A link that didn't sign in leaves nothing behind: the form says why.
            if (_app.User == null)
            {
                var why = _app.AuthError ?? "That setup link didn’t sign this computer in.";
                if (_app.Backend != null) await _app.Disconnect();
                _error = why;
            }
        }
        finally
        {
            _busy = false;
        }
    }
}
