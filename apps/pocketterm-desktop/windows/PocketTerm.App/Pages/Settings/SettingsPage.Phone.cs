using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PocketTerm.App.Components;
using PocketTerm.App.Views;

namespace PocketTerm.App.Pages;

internal sealed partial class SettingsPage
{
    private UIElement PhoneTab()
    {
        // Terminal from phone.
        var terminalSwitch = new ToggleSwitch().Id("settings-terminal-from-phone", "Terminal from phone");
        terminalSwitch.Toggled += (_, _) =>
        {
            if (terminalSwitch.IsOn == _app.TerminalOn) return;
            var on = terminalSwitch.IsOn;
            Run(async () =>
            {
                await _app.SetTerminalAsync(on);
                await CheckTerminalsAsync();
            });
        };
        Bind(terminalSwitch, s => s.IsOn = _app.TerminalOn);
        var windows = Bind(Ui.Dim(""), t =>
        {
            t.Text = _terminals == null
                ? "Looking for terminals…"
                : $"{Count(_windowCount, "terminal window")} · {Count(_app.Live.Sessions.Count, "coding session")}";
        });
        var terminal = Ui.SettingsCard(
            "Terminal from phone",
            "Your phone sees and drives this computer\u2019s sessions. Keeps it awake while on.",
            Ui.Glyph.Terminal,
            terminalSwitch);
        OnRefresh(() => terminal.SetBody(_app.TerminalOn ? windows : null));

        // Your phones.
        var phones = Ui.SettingsCard(
            "Your phones",
            icon: Ui.Glyph.Phone,
            body: Ui.Row(
                8,
                Ui.Button("Add a phone…", () => Run(() => PairingDialog.ShowAsync(_app)), "settings-add-phone"),
                Ui.Button("Reset key…", () => Run(ResetKeyAsync), "settings-reset-key")));
        OnRefresh(() =>
        {
            phones.SetDescription(_app.PhoneSignedIn ?? false ? "A phone is signed in" : "No phone yet");
            Kind(phones.Description, _app.PhoneSignedIn == false ? TextKind.Warn : TextKind.Dim);
        });

        // Project folders.
        var none = Ui.Dim("None yet · your phone can still open any path you type");
        var chips = new WrapPanel();
        var folders = Ui.SettingsCard(
            "Project folders",
            "Your phone lists the git repositories in these (up to three levels deep) and starts new projects there.",
            Ui.Glyph.Folder,
            body: Ui.Stack(8, none, chips));
        OnRefresh(() =>
        {
            var roots = _app.ProjectRoots;
            none.Shown(roots.Count == 0);
            chips.Sync(
                roots.Select(r => (string?)r).Append(null),
                r => r ?? "\0add",
                r => r == null ? AddFolderChip() : FolderChip(r));
        });

        return Cards(terminal, phones, folders);
    }

    /// <summary>A project folder, with its home as <c>~</c>; a click removes it.</summary>
    private Button FolderChip(string root)
    {
        var b = new Button
        {
            Content = Ui.Row(6, Ui.Text(Tilde(root)), Ui.Icon(Ui.Glyph.Remove, 10, "PtDimIcon")),
        }.Id($"settings-folder-{root}", $"Remove {Tilde(root)}");
        ToolTipService.SetToolTip(b, "Remove");
        b.Click += (_, _) => _app.SetProjectRoots(_app.ProjectRoots.Where(r => r != root).ToList());
        return b;
    }

    private Button AddFolderChip() => Ui.IconButton(Ui.Glyph.FolderAdd, "Add folder…", () => Run(AddFoldersAsync), "settings-add-folder");

    /// <summary><paramref name="p"/> with the home folder as <c>~</c>.</summary>
    private string Tilde(string p)
    {
        var home = _app.Terminals.Home;
        if (p == home) return "~";
        foreach (var sep in new[] { '\\', '/' })
        {
            if (p.StartsWith(home + sep, StringComparison.Ordinal)) return "~" + p[home.Length..];
        }
        return p;
    }

    /// <summary>A new channel key (after losing a phone): every phone must scan again.</summary>
    private async Task ResetKeyAsync()
    {
        var reset = await Dialogs.ConfirmAsync(
            "Reset this computer\u2019s key?",
            "Your phones read this computer\u2019s sessions with a key from its code. A new key locks out every phone "
            + "that has the old one, including a lost one. Each phone you keep must scan this computer\u2019s code again "
            + "(Settings → Phone → Add a phone…). To keep a lost phone off your server too, sign it out under "
            + "Settings → Account.",
            "Reset key",
            "settings-reset-key-dialog");
        if (!reset) return;
        try
        {
            await _app.ResetChannelKeyAsync();
        }
        catch (Exception e)
        {
            if (Live) Shell.Toast($"Key not reset: {e.Message}");
            return;
        }
        if (Live) Shell.Toast("New key made. Scan this computer\u2019s code on each phone.");
    }
}
