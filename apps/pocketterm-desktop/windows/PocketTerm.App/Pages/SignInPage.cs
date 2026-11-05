using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using PocketTerm.App.Views;
using PocketTerm.Desktop;

namespace PocketTerm.App.Pages;

/// <summary>
/// Signing this computer in (pocketterm_core's <c>SignInPage</c>): a server is chosen but nobody is signed in.
/// The server's setup link signs it in; until one arrives this says how to get it, or why the last one failed.
/// </summary>
internal sealed class SignInPage : View
{
    public SignInPage(AppController app)
    {
        var logo = new Image
        {
            Source = new BitmapImage(new Uri(Path.Combine(AppPaths.BaseDir, "Assets", "app.ico"))),
            Width = 64,
            Height = 64,
        };
        var help = Bind(Ui.Text("", TextKind.Dim).Selectable(), t =>
        {
            t.Text = app.AuthError
                ?? "Open your server\u2019s setup link on this computer. To see it again, run `pocketterm-server setup-link` on the server.";
            t.Style = Ui.Style(app.AuthError == null ? "PtDim" : "PtErrorText");
            t.TextAlignment = TextAlignment.Center;
        }).Id("sign-in-help");
        var retry = Bind(Ui.Button("Try again", () => Run(app.Retry), "sign-in-retry", accent: true), b => b.Shown(app.RetryLink != null))
            .Align(HorizontalAlignment.Center);
        var other = Bind(Ui.Link("", () => Run(app.Disconnect), "sign-in-other-server"), b =>
            b.Content = $"Connected to {app.Backend?.Host ?? "?"} · Use a different server").Align(HorizontalAlignment.Center);

        var title = Ui.Text("PocketTerm", TextKind.Subtitle);
        title.TextAlignment = TextAlignment.Center;
        var sub = Ui.Text("Sign in to connect this computer to your phone.", TextKind.Body);
        sub.TextAlignment = TextAlignment.Center;
        var column = Ui.Stack(12, logo.Align(HorizontalAlignment.Center), title, sub, help, retry, other.Margin(0, 8, 0, 0))
            .Width(360)
            .Align(HorizontalAlignment.Center, VerticalAlignment.Center);
        Content = column;
        Watch(app);
    }
}
