# Contributing

Thanks for helping. PocketTerm is small and opinionated, so for anything bigger than a fix, open an issue first so we can agree on the shape before you build it.

## Setup

[docs/BUILDING.md](docs/BUILDING.md) covers tools, your own signing identity (`config/Local.xcconfig`, Android `key.properties`, `google-services.json`), the Windows build and a local backend. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the pieces fit.

The repo is a pub workspace: `apps/pocketterm-desktop` (the desktop app for macOS and Windows, and the backend), `apps/pocketterm-mobile` (iPhone and Android), `packages/pocketterm_core` (shared). Code both apps use belongs in `pocketterm_core`. A change to the desktop app should work on macOS and Windows, and a change to the phone app on iPhone and Android; if one platform can't do it, say so in the PR.

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
  # in apps/pocketterm-desktop
  deno check supabase/functions/*/index.ts
  deno test --allow-env supabase/functions/_tests/       # pair, push and relay in-process, fake network
  deno check --config integrations/omp-check.json integrations/omp/*.ts
  # in apps/pocketterm-desktop (Docker; CI pins Supabase CLI 2.116.0)
  supabase db start && supabase db lint --level error
  supabase test db                                       # pgTAP in supabase/tests: pairing, sign-up hook, account deletion and the demo account, RLS
  # the Claude Code plugin, in apps/pocketterm-desktop/integrations/claude, locally
  # (CI can't: Claude Code mods need a logged-in claude)
  claude plugin validate . && claude plugin test plugins/pocketterm
  ```
- Add a test when you change behavior that can quietly break: parsing, the terminal protocol, session routing, platform paths. Platform checks take an injectable `windows` flag, so Windows behavior is testable on a Mac too.
- Database changes go in a **new** migration in `apps/pocketterm-desktop/supabase/migrations/`, timestamped after the latest. Never edit one that has shipped: self-hosters have already applied it.
- Note user-visible changes under a `## Unreleased` heading at the top of `CHANGELOG.md` (add it if it isn't there), and say whether self-hosters must rerun `apps/pocketterm-desktop/tool/setup-backend.sh`.
- Never commit `config/Local.xcconfig`, `apps/pocketterm-desktop/supabase/.env*`, `apps/pocketterm-mobile/android/key.properties`, `google-services.json`, keystores or any key.

## Style

Format Dart with `fvm dart format -l 120`. Comments explain *why*: the platform quirk, the race, the constraint.
