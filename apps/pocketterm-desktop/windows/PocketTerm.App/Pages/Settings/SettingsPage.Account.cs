using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using PocketTerm.App.Components;
using PocketTerm.App.Views;
using PocketTerm.Core;
using PocketTerm.Desktop;

namespace PocketTerm.App.Pages;

internal sealed partial class SettingsPage
{
    private UIElement AccountTab()
    {
        // Who is signed in.
        var avatar = new PersonPicture { Width = 40, Height = 40 };
        var userName = Ui.Strong("");
        var userSub = Ui.Dim("");
        var user = Ui.Card(Ui.Split(
            Ui.Row(14, avatar, Ui.Stack(2, userName, userSub).Align(HorizontalAlignment.Left, VerticalAlignment.Center)),
            Ui.Button("Sign out", () => Run(SignOutAsync), "settings-sign-out")));
        OnRefresh(() =>
        {
            avatar.DisplayName = _app.UserName;
            userName.Text = _app.UserName;
            userSub.Text = _app.Hosting != null
                ? "This computer runs your server"
                : _app.Backend?.IsSupabase ?? false
                    ? "Signed in to your Supabase project"
                    : "Signed in to this server";
        });

        // Your server: who is signed in to it, and the built-in server's status.
        var phones = new StackPanel { Spacing = 6 };
        var hostingView = new ContentPresenter();
        BuiltInServer? hostingShown = null;
        var addComputer = Ui.Button("Add a computer…", () => Run(AddComputerAsync), "settings-add-computer");
        var serverBody = Ui.Stack(10, phones, hostingView, addComputer);
        var server = Ui.SettingsCard("Your server", icon: Ui.Glyph.Server);
        server.Root.Id("settings-server");
        OnRefresh(() =>
        {
            var hosting = _app.Hosting;
            var backend = _app.Backend;
            var parts = new List<string>();
            // A computer running the server says where in its status below.
            if (hosting == null && (backend?.IsSupabase ?? false)) parts.Add($"Supabase, {backend.Host}");
            else if (hosting == null) parts.Add(backend?.Host ?? "");
            if (_devices is { } d) parts.Add(DevicesLine(d));
            server.SetDescription(string.Join(" · ", parts));

            var phoneDevices = (_devices ?? []).Where(d => d.Role == DeviceRole.Phone).ToList();
            phones.Sync(phoneDevices, d => $"{d.Id}\n{d.Label}", PhoneRow);
            phones.Shown(phoneDevices.Count > 0);
            if (!ReferenceEquals(hosting, hostingShown))
            {
                hostingShown = hosting;
                hostingView.Content = hosting == null ? null : new HostingStatusView(hosting);
            }
            hostingView.Shown(hosting != null);
            var canAdd = hosting?.State == HostState.Ready || _app.Server is SupabaseServerClient;
            addComputer.Shown(canAdd);
            server.SetBody(phoneDevices.Count > 0 || hosting != null || canAdd ? serverBody : null);
        });

        // Launch at login.
        var launchSwitch = new ToggleSwitch().Id("settings-launch-at-login", "Launch at login");
        launchSwitch.Toggled += (_, _) =>
        {
            if (_app.LaunchAtLogin is not { } now || launchSwitch.IsOn == now) return;
            var on = launchSwitch.IsOn;
            Run(async () =>
            {
                try
                {
                    await _app.SetLaunchAtLoginAsync(on);
                    _launchError = null;
                }
                catch (Exception e)
                {
                    _launchError = e.Message;
                }
            });
        };
        var launch = Ui.SettingsCard("Launch at login", icon: Ui.Glyph.Power, trailing: launchSwitch);
        OnRefresh(() =>
        {
            launchSwitch.IsEnabled = _app.LaunchAtLogin != null;
            launchSwitch.IsOn = _app.LaunchAtLogin ?? false;
            launch.SetDescription(_launchError ?? "Start PocketTerm when you log in");
            Kind(launch.Description, _launchError != null ? TextKind.Error : TextKind.Dim);
        });

        // Erasing the server this computer runs.
        var erase = Ui.SettingsCard(
            "Erase this server\u2019s data",
            "Signs out every computer and phone and deletes what the server keeps",
            Ui.Glyph.Delete,
            Ui.Button("Erase…", () => Run(EraseAsync), "settings-erase"));
        OnRefresh(() => erase.Root.Shown(_app.HostsServer));

        // Theme.
        var tiles = new WrapPanel { Spacing = 8, LineSpacing = 8 };
        var radios = new Dictionary<ThemeChoice, RadioButton>();
        foreach (var c in Enum.GetValues<ThemeChoice>())
        {
            var radio = new RadioButton
            {
                GroupName = "settings-theme",
                Content = Ui.Row(10, ThemePreview(c), new TextBlock { Text = c.Label(), VerticalAlignment = VerticalAlignment.Center }),
            }.Id($"settings-theme-{c.Name()}", c.Label());
            radio.Checked += (_, _) => Appearance.Shared.Choose(c);
            radios[c] = radio;
            tiles.Children.Add(radio);
        }
        OnRefresh(() =>
        {
            foreach (var (c, radio) in radios) radio.IsChecked = Appearance.Shared.Choice == c;
        });
        var theme = Ui.SettingsCard("Theme", "For this computer.", Ui.Glyph.Color, body: tiles);
        theme.Root.Id("settings-theme");

        var data = Ui.SettingsCard(
            "How your data is protected",
            "End-to-end encryption, and what your server, Tailscale and the push relay can see",
            Ui.Glyph.Shield,
            Ui.Button("Read…", () => Run(DataProtection.ShowAsync), "settings-data-protection"));

        var about = Ui.SettingsCard(
            $"PocketTerm {Shell.Version}",
            icon: Ui.Glyph.Info,
            trailing: Ui.Button("Quit PocketTerm", () => Run(_app.Host.QuitAsync), "settings-quit"));

        return Cards(user, server, launch, erase, theme, data, about);
    }

    /// <summary>A small picture of <paramref name="choice"/>'s colors: its light half beside its dark half, each
    /// its background with the accent across the top and its ok, warning and error colors below.</summary>
    private static Border ThemePreview(ThemeChoice choice)
    {
        static SolidColorBrush Brush(uint argb) => new(CodeBlock.Colorize(argb));
        static Grid Half(PtTheme t)
        {
            var dots = Ui.Row(3);
            foreach (var c in new[] { t.Ok, t.Warn, t.Error })
                dots.Children.Add(new Ellipse { Width = 6, Height = 6, Fill = Brush(c) });
            var half = new Grid { Padding = new Thickness(5, 5, 5, 5), RowSpacing = 6, Background = Brush(t.Win) };
            half.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            half.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            half.Children.Add(new Border { Height = 5, CornerRadius = new CornerRadius(2), Background = new SolidColorBrush(Accent.Of(t)) });
            Grid.SetRow(dots, 1);
            half.Children.Add(dots);
            return half;
        }
        var halves = new Grid { CornerRadius = new CornerRadius(3) };
        halves.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        halves.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var light = Half(choice.Light());
        var dark = Half(choice.Dark());
        Grid.SetColumn(dark, 1);
        halves.Children.Add(light);
        halves.Children.Add(dark);
        return new Border
        {
            Width = 92,
            Height = 32,
            CornerRadius = new CornerRadius(4),
            BorderThickness = new Thickness(1),
            BorderBrush = Brush(choice.Dark().Line),
            Child = halves,
        };
    }

    /// <summary>"2 computers, 1 phone".</summary>
    private static string DevicesLine(List<Device> devices)
    {
        var phones = devices.Count(d => d.Role == DeviceRole.Phone);
        return $"{Count(devices.Count - phones, "computer")}, {Count(phones, "phone")}";
    }

    /// <summary>A phone signed in to the server, with Sign out (a lost one).</summary>
    private UIElement PhoneRow(Device d)
    {
        var name = d.Label.Length == 0 ? "Phone" : d.Label;
        return Ui.Split(
            Ui.Leading(Ui.Icon(Ui.Glyph.Phone, 14, "PtDimIcon"), Ui.Text(name)),
            Ui.Button("Sign out…", () => Run(() => SignOutPhoneAsync(d, name)), $"settings-phone-sign-out-{d.Id}"))
            .Id($"settings-phone-{d.Id}");
    }

    /// <summary>Signs <paramref name="d"/> out of the server, asked first.</summary>
    private async Task SignOutPhoneAsync(Device d, string name)
    {
        var go = await Dialogs.ConfirmAsync(
            $"Sign out {name}?",
            "It can no longer reach your server or get its notifications. To use it again, scan this computer\u2019s "
            + "code on it (Settings → Phone → Add a phone…).",
            "Sign out",
            "settings-phone-sign-out-dialog");
        if (!go) return;
        try
        {
            await _app.RevokeServerDeviceAsync(d.Id);
        }
        catch (Exception e)
        {
            if (Live) Shell.Toast($"Not signed out: {e.Message}");
        }
        await CheckDevicesAsync();
    }

    /// <summary>Signing out of a server this computer runs stops it: asked first.</summary>
    private async Task SignOutAsync()
    {
        if (_app.Hosting != null)
        {
            var go = await Dialogs.ConfirmAsync(
                "Stop your server and sign out?",
                "This computer runs your server. Signing out stops it, and your phones and other computers can\u2019t "
                + "connect until you choose This computer again. What the server keeps stays on this computer.",
                "Sign out",
                "settings-sign-out-dialog");
            if (!go) return;
        }
        await _app.SignOut();
    }

    private async Task EraseAsync()
    {
        var go = await Dialogs.ConfirmAsync(
            "Erase this server\u2019s data?",
            "Every computer and phone is signed out of this server, and its images and push registrations "
            + "are deleted. This cannot be undone.",
            "Erase",
            "settings-erase-dialog");
        if (!go) return;
        try
        {
            await _app.EraseServer();
        }
        catch (Exception e)
        {
            if (Live) Shell.Toast($"Not erased: {e.Message}");
        }
        Run(CheckDevicesAsync);
    }

    /// <summary>Add a computer…: the built-in server's link for another computer, or a new setup link from the
    /// Supabase project (the one before stops working).</summary>
    private async Task AddComputerAsync()
    {
        if (_app.Hosting is { State: HostState.Ready })
        {
            // Ready means Tailscale serves it, so there is a link.
            if (await _app.ComputerSetupLinkAsync() is { } link) await AddComputerDialog.ShowAsync(link);
            return;
        }
        if (_app.Server is not SupabaseServerClient supabase) return;
        string newLink;
        try
        {
            newLink = await supabase.NewSetupLink();
        }
        catch (Exception e)
        {
            if (Live) Shell.Toast($"No link: {e.Message}");
            return;
        }
        if (!Live) return;
        await AddComputerDialog.ShowAsync(
            newLink,
            how: "On the other computer, open PocketTerm, choose Supabase, then Paste a setup link, and paste this link. "
                + "A link you made before this one stops working.");
    }
}
