# Building from source

## Tools

- **Mac and iPhone apps:** Xcode 26 or newer with your Apple ID signed in (Xcode → Settings → Accounts), and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`): both Xcode projects are generated from a `project.yml`. The shared Swift package `packages/PocketTermKit` (Swift 6) needs nothing more; `swift test` in it runs its tests.
- **Android:** a JDK 17 (`brew install openjdk@17`, or Android Studio's) and the Android SDK (Android Studio, or the command-line tools) with platform 37 and build-tools 36. The Gradle wrapper (`apps/pocketterm-mobile/android/gradlew`) fetches the rest.
- **Windows app:** a Windows 10 1809+ or 11 PC with the .NET 8 SDK (or Visual Studio 2022 17.10+ with the .NET desktop workload), and [Inno Setup 6](https://jrsoftware.org/isinfo.php) for the installer (`winget install JRSoftware.InnoSetup`). The WinUI app builds only on Windows; its libraries and tests build anywhere with the .NET 8 SDK.
- **Dart, for the server:** [fvm](https://fvm.app). The built-in server the desktop apps bundle, the server itself, the relay's test vectors and the end-to-end harness are Dart. `.fvmrc` pins a Flutter release only because fvm pins Dart through one: it is that release's Dart (3.13.4) that `fvm dart` runs, and the apps don't use Flutter. CI on Windows installs the same Dart with `dart-lang/setup-dart`.
- **Server and relay:** Docker to build the server's image, and [Deno](https://deno.com) for the relay's and the integrations' checks. PocketTerm on a local Supabase (`tool/supabase-local.sh`) needs the [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started) and Docker (colima's socket unless `DOCKER_HOST` is set).

```sh
# at the repo root, once
fvm install
fvm dart pub get   # the Dart workspace: packages/pocketterm_server, apps/pocketterm-server, tool/e2e
```

| Path | What | Built with |
| --- | --- | --- |
| `apps/pocketterm-desktop/macos` | Mac app | Xcode, on `packages/PocketTermKit` |
| `apps/pocketterm-desktop/windows` | Windows app (`PocketTerm.sln`) | .NET 8 |
| `apps/pocketterm-mobile/ios` | iPhone app | Xcode, on `packages/PocketTermKit` |
| `apps/pocketterm-mobile/android` | Android app (`:app`) and its protocol core (`:core`) | Gradle |
| `packages/pocketterm_server`, `apps/pocketterm-server` | The PocketTerm server and its Docker distribution | Dart |
| `apps/pocketterm-relay` | The push relay | Deno |

Each command below says which directory it runs in.

## Your signing identity

Every Xcode target, in both the Mac and the iPhone app, takes its team, bundle id and App Group from [config/PocketTerm.xcconfig](../config/PocketTerm.xcconfig). The values there belong to the upstream project, and Apple only lets their owner sign with them. To build under your own account:

```sh
# at the repo root
cp config/Local.xcconfig.example config/Local.xcconfig   # git-ignored
```

Then set your own values in it:

- `POCKETTERM_TEAM`: your team id (developer.apple.com → Membership).
- `POCKETTERM_BUNDLE_ID`: any id you own, like `com.yourname.pocketterm`. The iPhone's extensions are `<this>.PocketTermLive` and `<this>.PocketTermPush`.
- `POCKETTERM_APP_GROUP`: `group.` + your bundle id.

Automatic signing registers the ids and the App Group the first time you build with `-allowProvisioningUpdates` (below).

## Mac

The Mac app is native (SwiftUI on AppKit, macOS 13+) in `apps/pocketterm-desktop/macos`, on the Swift package `packages/PocketTermKit`. Its Xcode project is generated from `project.yml` with [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`):

```sh
# in apps/pocketterm-desktop/macos
xcodegen generate
xcodebuild -project PocketTerm.xcodeproj -scheme PocketTerm -configuration Debug -derivedDataPath build \
  -allowProvisioningUpdates build test
open build/Build/Products/Debug/PocketTerm.app    # or open PocketTerm.xcodeproj and run the PocketTerm scheme
```

The build bundles the built-in server ("On this computer"): `tool/server-sidecar.sh` compiles the Dart server (fvm's Dart) into `build/server-sidecar/`, and the build does that itself when it's missing or older than the server's code; `macos/scripts/bundle-resources.sh` puts it at `Contents/Helpers/pocketterm-server` with `integrations/`, `supabase/` and the theme icons. The first time, and whenever a provisioning profile expires (yearly), keep `-allowProvisioningUpdates` so Xcode fetches profiles.

A free Apple ID can build and run the Mac app for yourself. Notarized releases need a paid account ([RELEASING.md](RELEASING.md)).

### Running a second PocketTerm for testing

A debug build next to the PocketTerm you use shares more than its code. Built with the same bundle id, it reads and writes the same preferences (server, account, this computer's id), and by default both write `~/.config/pocketterm/cli.json` (the terminal API's port and token) and talk to the kitty behind `/tmp/kitty*`. To keep a test run apart, run a test build (a Debug build, or a Release one built with `OTHER_SWIFT_FLAGS='$(inherited) -D POCKETTERM_SMOKE'`; only such a build reads the variables below, a released one ignores them):

```sh
mkdir -p /tmp/pocketterm-e2e
POCKETTERM_PROFILE=dev POCKETTERM_CLI_JSON=/tmp/pocketterm-e2e/cli.json POCKETTERM_KITTY_DIR=/tmp/pocketterm-e2e \
  apps/pocketterm-desktop/macos/build/Build/Products/Debug/PocketTerm.app/Contents/MacOS/PocketTerm
```

- `POCKETTERM_PROFILE`: secrets in memory (never the Keychain), preferences in their own defaults domain (`<bundle id>.<profile>`) and the built-in server's data in its own folder, so the PocketTerm you use keeps its settings and its server.
- `POCKETTERM_CLI_JSON`: the file it writes its port and token to. omp's extension and the Claude Code plugin read the same variable, so start the omp or `claude` you test with under it too.
- `POCKETTERM_KITTY_DIR`: the directory whose `kitty*` sockets it uses for Terminal from phone. Give it a kitty of its own: `kitty -o allow_remote_control=socket-only -o listen_on=unix:/tmp/pocketterm-e2e/kitty`.
- `POCKETTERM_TAILSCALE`: a Tailscale CLI to use instead of the real one (`tool/smoke/fake_tailscale.sh` with `FAKE_TAILSCALE_STATE`), so "On this computer" never changes your Serve settings. `POCKETTERM_APPEARANCE=light|dark` sets its look.

The installed-app smoke (`tool/smoke/run.sh`, `tool/smoke/scenario.sh`) and the end-to-end run (`tool/e2e`) do all of this for you.

PocketTerm installs its own omp extension (`~/.omp/agent/extensions/pocketterm-live.ts`, and the same under `~/.omp/profiles/<name>/agent/extensions/` for each omp profile) and Claude Code plugin (`pocketterm@pocketterm`).

## Windows

The Windows app is native (C# 12, .NET 8, WinUI 3; unpackaged and self-contained) in `apps/pocketterm-desktop/windows` ([its README](../apps/pocketterm-desktop/windows/README.md)). On a Windows PC, in a checkout of this repo:

```powershell
pwsh tool/server-sidecar.ps1          # the built-in server: build\server-sidecar\windows-x64\pocketterm-server.exe
dotnet build apps/pocketterm-desktop/windows/PocketTerm.sln
dotnet test apps/pocketterm-desktop/windows/PocketTerm.sln
dotnet run --project apps/pocketterm-desktop/windows/PocketTerm.App -p:Platform=x64
```

A build without the sidecar runs, minus **On this computer**. On a Mac or Linux the libraries and their tests build too (`~/.dotnet/dotnet test apps/pocketterm-desktop/windows/PocketTerm.Libraries.slnf`), and `PocketTerm.App` compiles as a type check only.

Only one PocketTerm runs per Windows user: starting it again brings the running one's window to the front, and a `pocketterm://` link (a setup link) goes to the running one. A debug build and an installed copy are the same app to Windows, so quit the installed one first.

**The installer.** The release build and its installer, from the repo root:

```powershell
dotnet publish apps/pocketterm-desktop/windows/PocketTerm.App -c Release -p:Platform=x64 -p:Version=0.2.0 `
  -p:PocketTermRelease=true -o apps/pocketterm-desktop/build/windows/publish
cd apps/pocketterm-desktop
& "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" /DMyAppVersion=0.2.0 windows\installer.iss
# → build\windows\installer\PocketTerm-0.2.0-setup.exe
```

`-p:PocketTermRelease=true` refuses to build without the sidecar. [windows/installer.iss](../apps/pocketterm-desktop/windows/installer.iss) installs per user (no admin prompt) into `%LOCALAPPDATA%\Programs\PocketTerm`, updates a 0.1.x install in place, registers the `pocketterm://` link under `HKCU\Software\Classes\pocketterm`, and removes both those keys and the Launch at login entry (`HKCU\…\CurrentVersion\Run\PocketTerm`) when uninstalled. The installer is unsigned. CI builds the same one for every release ([RELEASING.md](RELEASING.md#windows)).

On Windows, Terminal from phone works with WezTerm only; the setup wizard and **Settings → Terminals** install it (`Terminals/WezTermSetup.cs` pins the release and its checksum).

## iPhone

For your own phone without TestFlight, install it from source. It needs a **paid** Apple Developer account: the app shares the server address (App Group) and the computers' channel keys (Keychain, through the same App Group) with its push extension, and push and Live Activities need the Push Notifications capability.

The iPhone app is native (SwiftUI, iOS 17+) in `apps/pocketterm-mobile/ios`, on the same Swift package as the Mac app:

```sh
# in apps/pocketterm-mobile/ios
xcodegen generate
open PocketTerm.xcodeproj      # pick your phone, run the PocketTerm scheme (Release for daily use)
# or, for the Simulator and its tests:
xcodebuild -project PocketTerm.xcodeproj -scheme PocketTerm -destination 'platform=iOS Simulator,name=<a simulator>' \
  -allowProvisioningUpdates build test
```

Debug builds carry the end-to-end hooks (`Model/E2E.swift`), switched on only by the `POCKETTERM_E2E` launch argument or environment variable ([SECURITY.md](../SECURITY.md#test-builds)). `tool/build-ipa.sh` (in `apps/pocketterm-mobile`) builds the App Store `.ipa` the way releases do.

Then pair it: on the computer, **Settings → Phone → Add a phone…**, and scan the code with the app ([SELF_HOSTING.md](SELF_HOSTING.md#connect-the-apps)).

Pushes reach a phone only through a relay that holds an APNs key of the team that signed it. With your own team, deploy your own relay ([SELF_HOSTING.md](SELF_HOSTING.md#your-own-app-id-and-relay)).

## Android

The Android app is native (Kotlin, Jetpack Compose, Material 3; Android 8.0+) in `apps/pocketterm-mobile/android`: the app in `:app`, its protocol core (pure Kotlin) in `:core`. With `JAVA_HOME` at a JDK 17:

```sh
# in apps/pocketterm-mobile/android
./gradlew :app:installDebug           # debug build, debug signing, onto the connected device or emulator
./gradlew :core:test :app:testDebugUnitTest
./gradlew :app:assembleRelease        # → app/build/outputs/apk/release/app-release.apk
./gradlew :app:bundleRelease          # → app/build/outputs/bundle/release/app-release.aab (for Google Play)
```

`-PpockettermE2e=true` makes a debug build with the end-to-end hooks (the Maestro end-to-end run builds it); release builds never have them.

**Release signing.** Release builds are signed with an upload key described in `apps/pocketterm-mobile/android/key.properties` (git-ignored); a release build without it fails. Start from the example:

```sh
# in apps/pocketterm-mobile
cp android/key.properties.example android/key.properties
```

and point it at your own keystore (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`). To make one, outside the repo:

```sh
keytool -genkeypair -v -keystore <your-keys-folder>/pocketterm-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

Keep the keystore and its password outside the repo, and back them up: Google Play needs the same upload key for every update.

**Push.** Android push goes through Firebase Cloud Messaging. Put your Firebase project's `google-services.json` (Firebase console → Project settings → your Android app, package `com.danyzmaj.pocketterm` or your own) in `apps/pocketterm-mobile/android/app/` (git-ignored). Without it a debug build builds and works with push off; a release build stops, so a store build never ships without push by accident (`./gradlew :app:bundleRelease -PallowNoPush=true` builds one anyway). Pushes only arrive if the relay your server uses holds the service account of that same Firebase project ([SELF_HOSTING.md](SELF_HOSTING.md#your-own-app-id-and-relay)).

**Your own package name.** The application id is `com.danyzmaj.pocketterm` in `apps/pocketterm-mobile/android/app/build.gradle.kts`. Google Play needs it to be unique, so a fork that publishes changes it there (and registers that id in its Firebase project).

Then pair the phone as above.

## A server, locally

```sh
# at the repo root
fvm dart run apps/pocketterm-server/bin/pocketterm_server.dart serve \
  --data build/local-server --port 47900 --address 127.0.0.1 --public-url http://127.0.0.1:47900
# in another terminal: the setup link
fvm dart run apps/pocketterm-server/bin/pocketterm_server.dart setup-link --data build/local-server --public-url http://127.0.0.1:47900
```

Paste that link in the desktop app (**On my own server**) to sign the computer in, then add a phone with **Settings → Phone → Add a phone…**. `pocketterm-server help` lists every option. Pushes go through the publisher's relay unless you pass `--relay`. A phone on a device (not the Simulator) can't reach `127.0.0.1`; for one, pick **On this computer**, the server built into the desktop app.

PocketTerm on a local Supabase instead: `tool/supabase-local.sh start`, then `tool/supabase-local.sh link` prints a computer's setup link for it, pasted the same way under **Supabase → Paste a setup link** ([apps/pocketterm-desktop/supabase/README.md](../apps/pocketterm-desktop/supabase/README.md#running-it-locally)).

## Checks

The checks to run before a pull request, and which of them CI runs (Baker on the maintainer's Mac, and `.github/workflows/ci.yml` for Windows), are listed in [CONTRIBUTING.md](../CONTRIBUTING.md#pull-requests).

[Maestro](https://maestro.mobile.dev) drives the phone app. `apps/pocketterm-mobile/maestro/demo.yaml` walks through the demo (dismissing the first-use tips with `tips.yaml`) and needs no server (`maestro test apps/pocketterm-mobile/maestro/demo.yaml`, the app signed out). Set `appId` in a flow to your bundle id.

The whole path, end to end, runs on a Mac with `tool/e2e/run.sh`: a server (`--server local`, the default; `builtin`, the one in the desktop app over Tailscale; `supabase`, PocketTerm on a local Supabase; `supabase-cloud`, a new project on supabase.com made by the desktop's own setup and deleted after; or a server's URL with its setup link), the real desktop app, throwaway kitty, Ghostty, WezTerm and iTerm2 windows with a fake omp, and the phone in the Simulator or an Android emulator (`--platform android --avd <name>`), which signs in with the computer's **Add a phone…** code (`apps/pocketterm-mobile/maestro/e2e/`). It prints a pass/fail table; artifacts go to `build/e2e/<stamp>/`. `tool/e2e/bin/run.dart` describes every option; [TESTING.md](TESTING.md) what each run covers.

The installed app, as from Finder: `tool/smoke/run.sh prepare` builds a test build and copies it to a throwaway place, then `tool/smoke/scenario.sh wizard getready settings menubar quit` drives it through accessibility (the terminal running it needs Accessibility and Screen Recording). `tool/smoke/run.sh clean` removes what it made.

The screenshots in `docs/images` are taken from the real apps: the iPhone's with Maestro's `takeScreenshot` on the demo, the Mac's by `tool/smoke/scenario.sh` (with `POCKETTERM_APPEARANCE=light|dark`), the Windows app's by `tool/smoke.ps1` in CI (the `PocketTerm-windows-smoke` artifact).
