# Windows app: what looks or works differently from the Flutter app

The native app keeps every screen, string and action of the Flutter desktop app (0.1.7) and the AutomationIds
named after its ValueKeys. These are the deliberate differences, made so it looks and behaves like a Windows 11 app.

## Everywhere

- **Windows' own look.** Mica window, the system title bar extended into the content, Segoe UI Variable, Segoe
  Fluent icons, WinUI controls (InfoBar, ContentDialog, Expander, ComboBox, ToggleSwitch, settings cards). The
  Flutter-drawn chrome (hover cards, gradients, custom chips, the drag strip) is gone.
- **Light and dark follow Windows.** The four themes (Catppuccin Mocha, Rosé Pine Dawn, Tokyo Night, Gruvbox
  Material) are terminal-and-accent themes: they color commands, links and paths shown as code, and the accent
  (buttons, switches, links); they still switch the window's and tray's icon. The window itself is Windows' light or
  dark.
- **No intro animation.** The window simply opens.
- **Confirmations are ContentDialogs** with Cancel as the default button (Reset key, Sign out, sign a phone out,
  Erase, installs, commands). Toasts ("New key made", "Copied") are a short InfoBar at the bottom of the window.
- **Notices** (a link's message while signed in) are an InfoBar under the title bar, closed with its ×, instead of
  a card with OK. A setup link to another server asks in a dialog ("Connect to <host>?") instead of an overlay.
- **Project folders** are picked one at a time (Windows' folder picker); Flutter's picker took several at once.

## First-run setup

- The three choices (and Yes / Not yet) are full-width buttons with an icon, title, description and chevron.
- Explainers ("Why a server?", …) are Expanders; notices, errors, clock warnings and Supabase's wait notice are
  InfoBars; busy buttons show a progress ring.
- Supabase's organization and region pickers are ComboBoxes; the access token goes in a password box.
- Installs offered by setup use winget or the download page only (the Homebrew branch and its "your Mac password"
  line were Mac-only). The VPS's ssh line says to type it in PowerShell.

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
