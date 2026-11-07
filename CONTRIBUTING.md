# Contributing

Thanks for helping. PocketTerm is small and opinionated, so for anything bigger than a fix, open an issue first so we can agree on the shape before you build it.

## Setup

[docs/BUILDING.md](docs/BUILDING.md) covers tools, your own signing identity (`config/Local.xcconfig`, Android `key.properties`, `google-services.json`), the Windows build and a local server. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the pieces fit.

The apps are native, one per platform: `apps/pocketterm-desktop/macos` (Swift, SwiftUI) and `apps/pocketterm-mobile/ios` (Swift, SwiftUI), both on the Swift package `packages/PocketTermKit`; `apps/pocketterm-mobile/android` (Kotlin, Compose; its protocol core in the Gradle module `:core`); `apps/pocketterm-desktop/windows` (C#, .NET 8, WinUI 3). The PocketTerm server is Dart, in `packages/pocketterm_server` ([PROTOCOL.md](packages/pocketterm_server/PROTOCOL.md)), its program in `apps/pocketterm-server` (compiled by `tool/server-sidecar.sh`/`.ps1` and bundled in the desktop apps); the push relay is Deno, in `apps/pocketterm-relay`. Protocol code exists once per language (Swift, Kotlin, C#) and must stay byte-compatible with the Dart server: a change to it goes into all three cores, and `tool/vectors/vectors.json` (generated from Dart, then frozen) is what their tests check it against. A change to the desktop app should work on macOS and Windows, and a change to the phone app on iPhone and Android; if one platform can't do it, say so in the PR.

## Pull requests

- Keep each PR to one change, and describe what a user will notice.
- Run the checks for what you touched; CI runs them too, on every push to `main` and every pull request: [Baker](https://baker.danyzmaj.com) on the maintainer's Mac runs all of them except Windows, each reported as a GitHub check; GitHub Actions runs the Windows job (`.github/workflows/ci.yml`: the .NET solution's build and tests, the installer, an install and uninstall, and a smoke run). Baker doesn't run pull requests from forks.
  ```sh
  # Swift: the shared package, the Mac app, the iPhone app
  (cd packages/PocketTermKit && swift test)
  (cd apps/pocketterm-desktop/macos && xcodegen generate && xcodebuild -scheme PocketTerm build test)
  (cd apps/pocketterm-mobile/ios && xcodegen generate && \
    xcodebuild -scheme PocketTerm -destination 'platform=iOS Simulator,name=<a simulator>' build test)
  # Android (JDK 17): unit tests and Android lint
  (cd apps/pocketterm-mobile/android && ./gradlew :core:test :app:testDebugUnitTest :app:lintDebug)
  # Windows: the libraries and tests anywhere; the whole solution on Windows
  dotnet test apps/pocketterm-desktop/windows/PocketTerm.Libraries.slnf
  dotnet build apps/pocketterm-desktop/windows/PocketTerm.sln        # on Windows
  # the server, in packages/pocketterm_server and apps/pocketterm-server (after fvm dart pub get at the root)
  fvm dart format -l 120 --set-exit-if-changed lib test   # bin in apps/pocketterm-server
  fvm dart analyze --fatal-infos
  fvm dart test
  # the omp extension, in apps/pocketterm-desktop
  deno check --config integrations/omp-check.json integrations/omp/*.ts
  # the relay: its crypto must match the server's
  (cd packages/pocketterm_server && fvm dart run tool/relay_vectors.dart ../../apps/pocketterm-relay/tests/vectors.json)
  (cd apps/pocketterm-relay && deno fmt --check && deno check main.ts tests/*.ts && deno task test)
  # the Claude Code plugin, in apps/pocketterm-desktop/integrations/claude/plugins/pocketterm
  deno check --no-config hooks/items.ts
  claude plugin validate --strict . && claude plugin test .
  # the cores against the real Dart server (not in CI): POCKETTERM_INTEROP=1 with each core's tests above
  ```
- Add a test when you change behavior that can quietly break: parsing, the terminal protocol, session routing, platform paths. Windows-only code sits behind `OperatingSystem.IsWindows()` in `PocketTerm.Desktop.Core`, and its tests skip elsewhere; keep the rest of that library testable on a Mac.
- A change to the server's API keeps [PROTOCOL.md](packages/pocketterm_server/PROTOCOL.md) in step, and says in the PR whether apps and servers of different versions still work together.
- Note user-visible changes in the next version's `## <version>` section at the top of `CHANGELOG.md` (add it if it isn't there), and say whether servers or the relay must be updated.
- End-to-end: `tool/e2e/run.sh` runs a server, the desktop app, real terminals and the phone in the iOS Simulator or an Android emulator on a Mac. Run only what covers your change and the features around it, not the whole suite: [docs/TESTING.md](docs/TESTING.md#what-to-run-for-a-change) says how to pick, and what tests each feature.
- Never commit `config/Local.xcconfig`, `apps/pocketterm-mobile/android/key.properties`, `google-services.json`, a server's data folder, keystores or any key.

## Style

There is no formatter configured for Swift, Kotlin or C#: follow the code around you (Xcode's and Android Studio's defaults, `dotnet format` for C# if you like, 120 columns). Format Dart with `fvm dart format -l 120` and Deno code with `deno fmt`. Comments explain *why*: the platform quirk, the race, the constraint.
