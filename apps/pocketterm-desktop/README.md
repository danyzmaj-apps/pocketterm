# PocketTerm for macOS and Windows

The desktop app: one window holding the setup wizard that creates a user's server, sign-in and Settings; otherwise it runs in the background (menu bar on the Mac, tray on Windows) with the local terminal API and the bridge that lets a phone reach omp, Claude Code and this computer's terminals (macOS: kitty, tmux, WezTerm, iTerm2, Terminal, Ghostty; Windows: WezTerm).

It also carries the backend, because the wizard bundles it as app assets and deploys it:

| Path | What |
| --- | --- |
| `lib/` | Flutter app (shared code comes from [`packages/pocketterm_core`](../../packages/pocketterm_core/)); `desktop_host.dart` and `windows_host.dart` hold what differs per platform |
| `macos/` | Xcode project: Runner (main window, menu-bar item, Sparkle updates) |
| `windows/` | Windows runner (single instance, `pocketterm://` links) and `installer.iss`, the Inno Setup installer |
| `assets/` | App assets, including the tray icon (`tray.ico`) |
| `supabase/migrations/` | The database schema; add a new file, never edit a shipped one |
| `supabase/functions/` | Edge functions: `pair`, `push` (every user's server) and `relay` (the publisher's push relay only) |
| `supabase/tests/` | pgTAP tests (`supabase test db`) |
| `tool/setup-backend.sh` | Set up or update a server from a terminal |
| `tool/deploy-relay.sh` | Deploy the publisher's push relay (APNs and FCM) |
| `tool/release.sh` | Build, notarize and publish a Mac release |
| `tool/make_icon.swift` | Draw the app icons |
| `integrations/omp/` | omp extension `pocketterm-live.ts`: sessions for the phone |
| `integrations/claude/` | Claude Code marketplace with PocketTerm's `pocketterm` plugin: sessions for the phone (`plugins/pocketterm/hooks/`); `claude plugin test integrations/claude/plugins/pocketterm` runs its tests |

Run it from this directory:

```sh
fvm flutter run -d macos     # on a Mac
fvm flutter run -d windows   # on a Windows PC
```

Building, signing and the installer: [docs/BUILDING.md](../../docs/BUILDING.md).
