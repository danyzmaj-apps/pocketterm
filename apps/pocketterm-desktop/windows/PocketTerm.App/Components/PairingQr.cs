using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using PocketTerm.App.Views;
using PocketTerm.Core;
using QRCoder;
using Windows.Storage.Streams;

namespace PocketTerm.App.Components;

/// <summary>
/// A QR the phone opens in PocketTerm (its Scan button, or the iPhone's Camera): the server's address, a one-time
/// sign-in code and this computer's channel key, so the phone is set up, signed in and able to read this computer by
/// the scan alone (a phone has no other way in). Anyone who scans it gets into the account and can read this
/// computer's sessions, so it is made fresh when shown, its sign-in works once, and it hides itself when it runs out;
/// the key stays good until Reset key (Settings → Phone).
/// </summary>
internal sealed class PairingQr : View
{
    /// <summary>How long a phone's code works (POST /v1/pair).</summary>
    public static readonly TimeSpan PairingLifetime = TimeSpan.FromMinutes(10);

    private readonly Session _session;
    private readonly Image _image = new() { Stretch = Stretch.Uniform };
    private int _generation;
    private bool _loading;
    private string? _error;
    private DateTime _expiresAt;
    private bool _expired;

    public PairingQr(Session session)
    {
        _session = session;
        var code = new Border
        {
            // A QR reads dark on light, whatever the window's theme.
            Background = new SolidColorBrush(Colors.White),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(10),
            Child = _image,
        }.Id("pairing-qr");
        var ring = new ProgressRing { IsActive = true, Width = 24, Height = 24 }.Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        var message = Ui.Dim("");
        message.TextAlignment = TextAlignment.Center;
        message.TextWrapping = TextWrapping.Wrap;
        var action = Ui.Link("", () => Run(LoadAsync), "pairing-renew").Align(HorizontalAlignment.Center);
        var placeholder = Ui.Stack(8, message, action).Align(HorizontalAlignment.Stretch, VerticalAlignment.Center);
        var box = new Grid { Width = 210, Height = 210, HorizontalAlignment = HorizontalAlignment.Center };
        box.Children.Add(code);
        box.Children.Add(ring);
        box.Children.Add(placeholder);

        var how = Ui.Dim(
            "On your phone: install PocketTerm and tap Scan the code from your computer " +
            "(on iPhone the Camera works too). It connects and signs in; nothing to type.");
        how.TextAlignment = TextAlignment.Center;
        how.TextWrapping = TextWrapping.Wrap;
        var secret = Ui.Dim(
            "This code is a secret. Anyone who scans it can read this computer's sessions. " +
            "The sign-in works once, for 10 minutes; the key in it works until you reset it in Settings.");
        secret.FontSize = 11.5;
        secret.TextAlignment = TextAlignment.Center;
        secret.TextWrapping = TextWrapping.Wrap;
        Content = Ui.Stack(0, box, how.Margin(0, 14, 0, 0), secret.Margin(0, 8, 0, 0));

        OnRefresh(() =>
        {
            var ready = !_expired && !_loading && _error == null;
            code.Shown(ready);
            ring.Shown(!_expired && _loading);
            placeholder.Shown(_expired || (!_loading && _error != null));
            message.Text = _expired ? "This code ran out." : _error ?? "";
            action.Content = _expired ? "Make a new one" : "Retry";
        });
        // The code runs out after PairingLifetime; looked at now and then rather than with a timer per code.
        Every(TimeSpan.FromSeconds(5), () =>
        {
            if (!_expired && !_loading && DateTime.UtcNow >= _expiresAt) _expired = true;
            return Task.CompletedTask;
        });
        Run(LoadAsync);
    }

    /// <summary>A fresh code (the first, or after it ran out or failed).</summary>
    private async Task LoadAsync()
    {
        var generation = ++_generation;
        _loading = true;
        _error = null;
        _expired = false;
        _expiresAt = DateTime.UtcNow + PairingLifetime;
        if (Live) Refresh();
        try
        {
            var link = await _session.PairingLink();
            var source = await RenderAsync(link);
            if (generation != _generation) return;
            _image.Source = source;
        }
        catch (Exception e)
        {
            if (generation != _generation) return;
            _error = e is PairingException p ? p.Message : $"Couldn't make a code: {e.Message}";
        }
        finally
        {
            if (generation == _generation) _loading = false;
        }
    }

    /// <summary><paramref name="text"/> as a QR picture.</summary>
    private static async Task<BitmapImage> RenderAsync(string text)
    {
        byte[] png;
        using (var generator = new QRCodeGenerator())
        using (var data = generator.CreateQrCode(text, QRCodeGenerator.ECCLevel.L))
        {
            // The white box around it is the quiet zone.
            png = new PngByteQRCode(data).GetGraphic(10, false);
        }
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
        {
            writer.WriteBytes(png);
            await writer.StoreAsync();
            await writer.FlushAsync();
            writer.DetachStream();
        }
        stream.Seek(0);
        var image = new BitmapImage();
        await image.SetSourceAsync(stream);
        return image;
    }
}

/// <summary>Settings → Phone → "Add a phone…" (showPairingQr).</summary>
internal static class PairingDialog
{
    public static async Task ShowAsync(Session session) =>
        await Dialogs.InfoAsync("Set up your phone", new PairingQr(session).Width(320), "Done", "pairing-dialog");
}
