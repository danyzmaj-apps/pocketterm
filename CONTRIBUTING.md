# Contributing

Thanks for helping. PocketTerm is small and opinionated, so for anything bigger than a fix, open an issue first so we can agree on the shape before you build it.

## Setup

[docs/BUILDING.md](docs/BUILDING.md) covers tools, your own signing identity (`config/Local.xcconfig`, Android `key.properties`, `google-services.json`), the Windows build and a local server. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the pieces fit.

The repo is a pub workspace: `apps/pocketterm-desktop` (the desktop app for macOS and Windows), `apps/pocketterm-mobile` (iPhone and Android), `packages/pocketterm_core` (shared), `packages/pocketterm_server` (the PocketTerm server, its protocol in [PROTOCOL.md](packages/pocketterm_server/PROTOCOL.md)) with its Docker distribution in `apps/pocketterm-server`, and `apps/pocketterm-relay` (the push relay, Deno). Code both apps use belongs in `pocketterm_core`. A change to the desktop app should work on macOS and Windows, and a change to the phone app on iPhone and Android; if one platform can't do it, say so in the PR.

## Pull requests

- Keep each PR to one change, and describe what a user will notice.
- Run the checks; CI runs them too:
  ```sh
  # in each of packages/pocketterm_core, apps/pocketterm-desktop, apps/pocketterm-mobile
  fvm dart format -l 120 --set-exit-if-changed lib test
  fvm flutter analyze
  fvm flutter test
  # on Windows, in packages/pocketterm_core and apps/pocketterm-desktop (CI's dart-windows job)
  fvm flutter test --exclude-tags posix
  fvm flutter build windows --debug
  # in packages/pocketterm_server and apps/pocketterm-server
  fvm dart format -l 120 --set-exit-if-changed lib test   # bin in apps/pocketterm-server
  fvm dart analyze --fatal-infos
  fvm dart test
  docker build -f apps/pocketterm-server/Dockerfile -t pocketterm-server .   # from the repo root
  # in apps/pocketterm-desktop
  deno check --config integrations/omp-check.json integrations/omp/*.ts
  # the relay: its crypto must match the server's
  (cd packages/pocketterm_server && fvm dart run tool/relay_vectors.dart ../../apps/pocketterm-relay/tests/vectors.json)
  (cd apps/pocketterm-relay && deno fmt --check && deno check main.ts tests/*.ts && deno task test)
  # the Claude Code plugin, in apps/pocketterm-desktop/integrations/claude/plugins/pocketterm
  deno check --no-config hooks/items.ts
  claude plugin validate --strict . && claude plugin test .
  # PocketTerm on Supabase (not in CI): in packages/pocketterm_core, after tool/supabase-local.sh start
  POCKETTERM_SUPABASE=1 fvm flutter test -j 1 test/server_client_test.dart test/session_test.dart
  ```
- Add a test when you change behavior that can quietly break: parsing, the terminal protocol, session routing, platform paths. Platform checks take an injectable `windows` flag, so Windows behavior is testable on a Mac too.
- A change to the server's API keeps [PROTOCOL.md](packages/pocketterm_server/PROTOCOL.md) in step, and says in the PR whether apps and servers of different versions still work together.
- Note user-visible changes in the next version's `## <version>` section at the top of `CHANGELOG.md` (add it if it isn't there), and say whether servers or the relay must be updated.
- End-to-end: `tool/e2e/run.sh` runs a server, the desktop app, real terminals and the phone in the iOS Simulator or an Android emulator on a Mac; [docs/TESTING.md](docs/TESTING.md) says what tests each feature.
- Never commit `config/Local.xcconfig`, `apps/pocketterm-mobile/android/key.properties`, `google-services.json`, a server's data folder, keystores or any key.

## Style

Format Dart with `fvm dart format -l 120`. Comments explain *why*: the platform quirk, the race, the constraint.
