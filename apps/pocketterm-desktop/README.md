# PocketTerm for Mac

The menu-bar app: one window holding the setup wizard that creates a user's server, sign-in and Settings, the local terminal API, and the bridge that lets a phone reach omp, Claude Code and this computer's terminals (kitty, tmux, WezTerm, iTerm2, Terminal, Ghostty).

It also carries the backend, because the wizard bundles it as app assets and deploys it:

| Path | What |
| --- | --- |
| `lib/` | Flutter app (shared code comes from [`packages/pocketterm_core`](../../packages/pocketterm_core/)) |
| `macos/` | Xcode project: Runner (main window, menu bar item) |
| `supabase/migrations/` | The database schema; add a new file, never edit a shipped one |
| `supabase/functions/` | Edge functions: `pair`, `push` (every user's server) and `relay` (the publisher's push relay only) |
| `tool/setup-backend.sh` | Set up or update a server from a terminal |
| `tool/deploy-relay.sh` | Deploy the publisher's push relay (APNs and FCM) |
| `tool/release.sh` | Build, notarize and publish a release |
| `tool/make_icon.swift` | Draw the app icons |
| `integrations/omp/` | omp extension `pocketterm-live.ts`: sessions for the phone |
| `integrations/claude/` | Claude Code marketplace with PocketTerm's `pocketterm` plugin: sessions for the phone (`plugins/pocketterm/hooks/`); `claude plugin test integrations/claude/plugins/pocketterm` runs its tests |
| `test/screenshots/` | The docs' Mac screenshots (Settings, setup wizard), rendered on made-up data |

Run it from this directory:

```sh
fvm flutter run -d macos
```
