using Microsoft.UI.Xaml;
using PocketTerm.App.Views;

namespace PocketTerm.App.Components;

/// <summary>
/// How your data is protected, in plain words: the first-run setup shows it, Settings → Account opens it again
/// (<see cref="ShowAsync"/>). Kept true to the code: PocketTerm.Core's E2e, SECURITY.md,
/// apps/pocketterm-relay/SECURITY.md.
/// </summary>
internal static class DataProtection
{
    public static IReadOnlyList<(string Glyph, string Title, string Text)> Sections { get; } =
    [
        (
            Ui.Glyph.Lock,
            "Encrypted from end to end",
            "Each computer makes its own key and keeps it in a file in %APPDATA% encrypted for your Windows account (on " +
            "a Mac, in its Keychain). A phone gets it only by scanning that computer’s QR code. Your sessions, prompts, " +
            "screens, images, files and notification text travel sealed with it (AES-256-GCM), so nothing in between " +
            "can read them."
        ),
        (
            Ui.Glyph.Server,
            "Your PocketTerm server",
            "Keeps your list of devices, your computers’ names, pairing codes for 10 minutes and your phones’ push tokens. " +
            "Images and files you send wait there sealed until the computer fetches them, at most an hour. It passes " +
            "everything else on without being able to read it."
        ),
        (
            Ui.Glyph.Globe,
            "Tailscale (On this computer)",
            "Connects your own devices privately. Tailscale sees which of your devices connect and when, not what they " +
            "send."
        ),
        (
            Ui.Glyph.Notification,
            "Notifications, if you turn them on",
            "They pass through PocketTerm’s push relay (push.danyzmaj.com), a small service Danijel Lovric runs on his own " +
            "server in Croatia, in the EU. It can’t read them: your computer encrypts each notification so that only your " +
            "phone can open it. The relay just hands it to Apple or Google to deliver. It never learns which computer or " +
            "session a notification is about, and it keeps nothing."
        ),
        (
            Ui.Glyph.Info,
            "Lock Screen updates (iPhone)",
            "When you follow a session, iOS shows its state on the Lock Screen: working, needs you, or finished. Apple " +
            "doesn’t let apps decrypt these updates, so this state travels unencrypted. It never includes any text from " +
            "your sessions, and it carries no names, folders or ids."
        ),
        (
            Ui.Glyph.QrCode,
            "The QR code is a key",
            "Whoever scans it can read this computer’s sessions: show it only to your own phone. Settings → Phone → Reset " +
            "key makes a new key; every phone then scans the code again."
        ),
    ];

    /// <summary>The sections, each with its icon.</summary>
    public static UIElement Build()
    {
        var all = Ui.Stack(14);
        foreach (var (glyph, title, text) in Sections)
        {
            all.Children.Add(Ui.Leading(Ui.Icon(glyph, 18, "PtAccentIcon"), Ui.Stack(3, Ui.Strong(title), Ui.Dim(text)), 12));
        }
        return all;
    }

    /// <summary>The sections in a dialog (Settings → Account).</summary>
    public static async Task ShowAsync() =>
        await Dialogs.InfoAsync("How your data is protected", Build(), "Done", "data-protection");
}
