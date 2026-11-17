# PocketTerm for Mac: what changed from the Flutter app

The native app (SwiftUI on AppKit, macOS 13+) keeps every feature, string and setting of the Flutter app
(0.1.7) and its services' behaviour (packages/PocketTermKit). What looks or works differently, and why:

## App shell

- **Two windows instead of one.** The setup window holds the first-run setup, the sign-in and the setup checklist;
  once this computer is signed in and the checklist is done (or skipped), the window PocketTerm opens is Settings,
  a standard Mac Settings window with a toolbar of tabs (Phone, Coding agents, Terminals, Account). "Open setup
  checklist" switches back. Both remember their place (`PocketTermMain`, `PocketTermSettings`), and closing either
  (⌘W, the red button) only hides it, as before: the Dock icon and menu bar go with it.
- **The menu-bar item opens a panel** (a click) with how this computer stands ("All set" / "N things need
  attention" / "Checking this computer…"), the Terminal from phone switch with its terminal and session counts,
  what needs attention (each opens its Settings tab), Add a phone…, Settings… (or Open setup checklist / Set up
  PocketTerm…), Check for Updates… and Quit PocketTerm. A right click (or ⌃-click) still gives the short menu
  (Open PocketTerm, Settings…, Check for Updates…, Quit PocketTerm). The Flutter app opened the window on a click.
- **The app's lifecycle is AppKit's** (NSStatusItem + NSPopover rather than SwiftUI's MenuBarExtra, NSWindows hosting
  SwiftUI rather than SwiftUI scenes): the activation policy switching (Dock icon only while a window is open),
  ⌘, opening Settings from any state, and the window routing need control SwiftUI scenes don't give on macOS 13.
- **Menus**: PocketTerm (About, Check for Updates…, Settings… ⌘,, Services, Hide, Quit ⌘Q), File (Close Window ⌘W),
  Edit (so ⌘V pastes a setup link), Window. The Flutter app had no Edit menu.
- **No launch intro animation**; the windows open straight away.
- **No drag strip**: the title bar is the system's (transparent over the setup window), so the window drags as any.
- **Colors**: the app follows macOS light and dark; the theme, System (the default: the Mac's own accent),
  Catppuccin (Latte / Mocha), Rosé Pine (Dawn / Rosé Pine) or Tokyo Night (Day / Night), tints the accent with its
  light or dark half as macOS shows, and Rosé Pine and Tokyo Night still switch the Dock icon. Settings shows each
  theme's light and dark half. Gruvbox is gone (its people are on Catppuccin).
- **Toasts** ("New key made…", "Key not reset: …") are short messages next to the control that did it.
- **Status bar → status section**: Settings' status bar ("All set" / what needs attention, Show / Hide, Open setup
  checklist) is the first section of every tab; a tab with something to do has a red dot on its toolbar icon.
- **Sparkle** doesn't check in test builds (`POCKETTERM_SMOKE`) either, so a smoke copy never replaces itself.

## Desk (beta)

New in the native app, not in the Flutter one ([docs/DESK.md](../../../docs/DESK.md)).

- **A third window**, `PocketTermDesk` (`pocketterm-desk-window`), opened from the menu-bar panel (`menu-open-desk`),
  the right-click menu or Desk → Open Desk. It keeps the Dock icon and menu bar while it shows, whatever the other
  windows do (`MacHost.windowShown`); ⌘W hides it and its terminals keep running.
- **Keyboard first, ⌘ keys only**: a terminal never gets ⌘, so no key is taken from the programs in it. A small set
  that other Mac apps use for the same things (⌘K go to, ⌘J next waiting, ⌘1…⌘9, ⌘⇧[ ⌘⇧], ⌘T, ⌘⇧T, ⌘⇧W, ⌘⇧↩),
  all in the File and Desk menus; the status bar names the three to remember. Every action moves the keyboard into
  the focused terminal.
- **Native parts**: a sidebar list (`NavigationSplitView`), the system's text colors in the terminals (light and
  dark with the Mac), a segmented layout picker, alerts before ending what still runs.
- Identifiers: `desk-*` (`desk-pane-<session>`, `desk-session-<session>`, `desk-palette`, `desk-new`, `desk-layout`).

## Setup: Tailscale only

- **One setup page.** PocketTerm's server is only the one built into the app, published over Tailscale: the setup
  opens on the Tailscale checklist (`check-*`) with Start (`setup-start-server`). The choose screen (On this
  computer / On my own server / Supabase), the VPS screens (address, commands, live checks) and the Supabase setup
  (access token, project, migrations, function) are gone.
- **Join another computer's PocketTerm…** (`setup-join`), under Start, opens the paste-a-link screen (`setup-link`,
  `setup-link-health`, `setup-connect`, `setup-error`, `setup-back`) for the link another computer's Settings →
  Account → Add a computer… shows. A release build takes only `https://<name>.<tailnet>.ts.net` servers ("This
  link isn't for a PocketTerm on Tailscale."); a test build takes any http(s) server, which tool/e2e and tool/smoke
  sign in to on 127.0.0.1.
- **Moving off Supabase or a VPS**: at launch, a computer signed in to a server that is neither its own built-in
  one nor a `*.ts.net` one is signed out here (a VPS is told in the background, Supabase isn't), its saved server
  forgotten, and the setup says once, until the next sign-in (`setup-moved`): "PocketTerm now runs its server on
  this computer, over Tailscale. Set it up below; then scan the new code with your phone."
- Add a computer… is offered only by a computer running the built-in server; the Supabase one is gone.

## Test builds

- A test build is a Debug build or one compiled with `-D POCKETTERM_SMOKE` (tool/smoke/run.sh passes it on the
  xcodebuild command line so the PocketTermKit package is built with it too). Only it reads `POCKETTERM_TAILSCALE`,
  `POCKETTERM_CLI_JSON`, `POCKETTERM_KITTY_DIR`, `POCKETTERM_PROFILE` and, new, `POCKETTERM_APPEARANCE`
  (`light` / `dark`, for screenshots).
- A `POCKETTERM_PROFILE` keeps its preferences in the `<bundle id>.<profile>` defaults domain and the built-in
  server's data under its `HOME`, besides its secrets in memory: the person's own PocketTerm keeps its settings.
