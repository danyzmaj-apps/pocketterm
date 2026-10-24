# PocketTerm for macOS and Windows

The desktop app: one window holding the first-run setup (**On this computer**: the server built into the app, published to the owner's tailnet by Tailscale; **On my own server**: a server's setup link, or the commands that set one up on a VPS; **Supabase**: a Supabase project PocketTerm sets up, or a setup link to one), sign-in, the setup checklist (**Get this computer ready**) and Settings (a status bar over the Phone, Coding agents, Terminals and Account tabs); otherwise it runs in the background (menu bar on the Mac, tray on Windows) with the local terminal API and the bridge that lets a phone reach omp, Claude Code and this computer's terminals (macOS: kitty, tmux, WezTerm, Ghostty; Windows: WezTerm).

| Path | What |
| --- | --- |
| `lib/` | Flutter app (shared code comes from [`packages/pocketterm_core`](../../packages/pocketterm_core/)); `desktop_host.dart` and `windows_host.dart` hold what differs per platform |
| `lib/hosting/` | The built-in server ([`packages/pocketterm_server`](../../packages/pocketterm_server/) on 127.0.0.1) and the Tailscale CLI that serves it at `https://<computer>.<tailnet>.ts.net`; a VPS's commands and checks |
| `lib/onboarding/` | The setup checklist, the pairing QR, how your data is protected, and the wizard's Supabase branch (`supabase_view.dart`, `supabase_admin.dart`, `supabase_setup.dart`) |
| `supabase/` | PocketTerm on Supabase: the migrations and the Edge Function the wizard deploys, bundled as assets ([README](supabase/README.md)) |
| `macos/` | Xcode project: Runner (main window, menu-bar item, Sparkle updates) |
| `windows/` | Windows runner (single instance, `pocketterm://` links) and `installer.iss`, the Inno Setup installer |
| `assets/` | App assets, including the tray icon (`tray.ico`) |
| `tool/release.sh` | Build, notarize and publish a Mac release |
| `tool/make_icon.swift` | Draw the app icons |
| `integrations/omp/` | omp extension `pocketterm-live.ts`: sessions for the phone |
| `integrations/claude/` | Claude Code marketplace with PocketTerm's `pocketterm` plugin: sessions for the phone (`plugins/pocketterm/hooks/`); `claude plugin test integrations/claude/plugins/pocketterm` runs its tests |
| `integration_test/e2e_test.dart` | The desktop half of the end-to-end run ([`tool/e2e`](../../tool/e2e/)) |
| `test/screenshots/` | Renders the Mac screenshots in [`docs/images`](../../docs/images/): `fvm flutter test --tags screenshots --run-skipped` |

Run it from this directory:

```sh
fvm flutter run -d macos     # on a Mac
fvm flutter run -d windows   # on a Windows PC
```

Building, signing and the installer: [docs/BUILDING.md](../../docs/BUILDING.md).
