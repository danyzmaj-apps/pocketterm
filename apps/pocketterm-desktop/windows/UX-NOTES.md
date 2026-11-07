# Windows app: what looks or works differently from the Flutter app

The native app keeps every screen, string and action of the Flutter desktop app (0.1.7) and the AutomationIds
named after its ValueKeys. These are the deliberate differences, made so it looks and behaves like a Windows 11 app.

## Everywhere

- **Windows' own look.** Mica window, the system title bar extended into the content, Segoe UI Variable, Segoe
  Fluent icons, WinUI controls (InfoBar, ContentDialog, Expander, ComboBox, ToggleSwitch, settings cards). The
  Flutter-drawn chrome (hover cards, gradients, custom chips, the drag strip) is gone.
- **Light and dark follow Windows.** The themes, System (the default: Windows' own accent, code black on white or
  light on near-black), Catppuccin (Latte / Mocha), Rosé Pine (Dawn / Rosé Pine) and Tokyo Night (Day / Night), each
  have a light and a dark half that follows Windows' setting live. They color commands, links and paths shown as code,
  and the accent (buttons, switches, links); Rosé Pine and Tokyo Night still switch the window's and tray's icon.
  Gruvbox is gone (its people are on Catppuccin). The window itself is Windows' light or dark.
- **No intro animation.** The window simply opens.
- **Confirmations are ContentDialogs** with Cancel as the default button (Reset key, Sign out, sign a phone out,
  Erase, installs, commands). Toasts ("New key made", "Copied") are a short InfoBar at the bottom of the window.
- **Notices** (a link's message while signed in) are an InfoBar under the title bar, closed with its ×, instead of
  a card with OK. A setup link to another server asks in a dialog ("Connect to <host>?") instead of an overlay.
- **Project folders** are picked one at a time (Windows' folder picker); Flutter's picker took several at once.

## First-run setup

- No choice of server any more (Supabase and "On my own server" are gone): setup opens on the Tailscale
  checklist with Start, and one secondary button, "Join another computer's PocketTerm…" (`setup-join`), that
  takes the setup link another computer's Settings → Add a computer… makes. A release build accepts only
  `https://<name>.<tailnet>.ts.net` servers there ("This link isn't for a PocketTerm on Tailscale."); a test
  build (`E2E`) any http(s) URL, so the CI smoke joins a local sidecar.
- A computer upgraded while signed in to Supabase or a VPS is signed out once at launch and setup shows an
  InfoBar (`setup-migration-note`): "PocketTerm now runs its server on this computer, over Tailscale. …"
- Explainers ("What is Tailscale?", …) are Expanders; notices, errors and clock warnings are InfoBars; busy
  buttons show a progress ring.
- Installs offered by setup use winget or the download page only (the Homebrew branch and its "your Mac password"
  line were Mac-only).

## Setup checklist

- Step cards are Windows cards with a Fluent status icon (done, to do, optional, working); Done is an accent
  button at the end instead of a full-width one.
- The pairing code stays dark on white in dark mode too, so phones read it.
- Add a computer: "Copy link" turns into "Link copied" instead of showing a toast behind the dialog.

## Settings

- A **NavigationView** (left pane: Phone, Coding agents, Terminals, Account) instead of the tab bar; a tab with
  something to look at carries an attention badge.
- Cards are one column of Windows-Settings-style rows, actions at the row's end, instead of a two-column grid.
- The status bar is an InfoBar: informational while checking, success when all set, warning when something needs
  attention; Show/Hide and the items are in it, "Open setup checklist" is its link. The update bar is an InfoBar
  with Download.
- Theme tiles are radio buttons, each with a small preview of the theme's colors.
- The account card uses Windows' PersonPicture.
- Mac-only parts (kitty's Set up, Automation's Allow…, Ghostty in tmux) aren't shown: Windows has only WezTerm.
