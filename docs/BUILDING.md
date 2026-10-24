# Building from source

## Tools

- [fvm](https://fvm.app): the Flutter version is pinned in `.fvmrc` (`fvm install` fetches it).
- **Mac and iPhone apps:** Xcode 26 or newer with your Apple ID signed in (Xcode → Settings → Accounts), and CocoaPods (`brew install cocoapods`).
- **Android:** [Android Studio](https://developer.android.com/studio) (or the command-line Android SDK) with a JDK 17; `fvm flutter doctor` says what's missing.
- **Windows app:** a Windows 10 1809+ or 11 PC with Visual Studio 2022 and its "Desktop development with C++" workload (`fvm flutter doctor` checks it), and [Inno Setup 6](https://jrsoftware.org/isinfo.php) for the installer (`winget install JRSoftware.InnoSetup`).
- **Server and relay:** nothing extra to run the server from source (it is Dart); Docker to build its image, and [Deno](https://deno.com) for the relay's checks. PocketTerm on a local Supabase (`tool/supabase-local.sh`) needs the [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started) and Docker (colima's socket unless `DOCKER_HOST` is set).

```sh
# at the repo root
fvm install
fvm flutter pub get   # resolves the whole workspace
```

The repo is a Dart pub workspace: the desktop app (macOS and Windows) in `apps/pocketterm-desktop` (PocketTerm on Supabase in its `supabase/`), the phone app (iPhone and Android) in `apps/pocketterm-mobile`, the shared code in `packages/pocketterm_core`, the PocketTerm server in `packages/pocketterm_server` (its Docker distribution in `apps/pocketterm-server`). The push relay in `apps/pocketterm-relay` is Deno. Each command below says which directory it runs in.

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

```sh
cd apps/pocketterm-desktop
fvm flutter run -d macos
```

The first time, and whenever a provisioning profile expires (yearly), let Xcode fetch profiles once; `flutter run` doesn't:

```sh
# in apps/pocketterm-desktop
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -allowProvisioningUpdates build
```

A free Apple ID can build and run the Mac app for yourself. Notarized releases need a paid account ([RELEASING.md](RELEASING.md)).

### Running a second PocketTerm for testing

A debug build next to the PocketTerm you use shares more than its code. Built with the same bundle id, it reads and writes the same preferences (server, account, this computer's id), and by default both write `~/.config/pocketterm/cli.json` (the terminal API's port and token) and talk to the kitty behind `/tmp/kitty*`. To keep a test run apart, build it as a test build (`POCKETTERM_SMOKE`; only such a build reads the variables below, a released one ignores them):

```sh
# in apps/pocketterm-desktop
mkdir -p /tmp/pocketterm-e2e
POCKETTERM_CLI_JSON=/tmp/pocketterm-e2e/cli.json POCKETTERM_KITTY_DIR=/tmp/pocketterm-e2e fvm flutter run -d macos --dart-define=POCKETTERM_SMOKE=true
```

- `POCKETTERM_CLI_JSON`: the file it writes its port and token to. omp's extension and the Claude Code plugin read the same variable, so start the omp or `claude` you test with under it too.
- `POCKETTERM_KITTY_DIR`: the directory whose `kitty*` sockets it uses for Terminal from phone. Give it a kitty of its own: `kitty -o allow_remote_control=socket-only -o listen_on=unix:/tmp/pocketterm-e2e/kitty`.
- Preferences: the simple way is to quit the installed PocketTerm while the test build runs. To run both at once, set another `POCKETTERM_BUNDLE_ID` and `POCKETTERM_APP_GROUP` in `config/Local.xcconfig` ([above](#your-signing-identity)) and build once with the `xcodebuild … -allowProvisioningUpdates` line above, so Xcode registers them. Until then `flutter run` and `flutter build macos` fail with "No profiles for '<id>'".

PocketTerm installs its own omp extension (`~/.omp/agent/extensions/pocketterm-live.ts`) and Claude Code plugin (`pocketterm@pocketterm`).

## Windows

On a Windows PC, in a checkout of this repo:

```powershell
fvm install
fvm flutter pub get
cd apps/pocketterm-desktop
fvm flutter run -d windows                 # debug
fvm flutter build windows --release        # → build\windows\x64\runner\Release\PocketTerm.exe and its DLLs
```

Only one PocketTerm runs per Windows user: starting it again brings the running one's window to the front, and a `pocketterm://` link (a setup link) goes to the running one. A debug build and an installed copy are the same app to Windows, so quit the installed one first.

**The installer.** After the release build, in `apps/pocketterm-desktop`:

```powershell
& "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" /DMyAppVersion=0.1.0 windows\installer.iss
# → build\windows\installer\PocketTerm-0.1.0-setup.exe
```

[windows/installer.iss](../apps/pocketterm-desktop/windows/installer.iss) installs per user (no admin prompt) into `%LOCALAPPDATA%\Programs\PocketTerm`, registers the `pocketterm://` link under `HKCU\Software\Classes\pocketterm`, and removes both those keys and the Launch at login entry (`HKCU\…\CurrentVersion\Run\PocketTerm`) when uninstalled. The installer is unsigned. CI builds the same one for every release ([RELEASING.md](RELEASING.md#windows)).

On Windows, Terminal from phone works with WezTerm only; the setup wizard and **Settings → Terminals** install it (`WezTermSetup` in `lib/wezterm_setup.dart` pins the release and its checksum).

## iPhone

For your own phone without TestFlight, install it from source. It needs a **paid** Apple Developer account: the app shares the server address (App Group) and the computers' channel keys (Keychain, through the same App Group) with its push extension, and push and Live Activities need the Push Notifications capability.

```sh
cd apps/pocketterm-mobile
open ios/Runner.xcworkspace   # once: pick your phone, let Xcode register the device
fvm flutter run -d <your-iphone> --release
```

Then pair it: on the computer, **Settings → Phone → Add a phone…**, and scan the code with the app ([SELF_HOSTING.md](SELF_HOSTING.md#connect-the-apps)).

Pushes reach a phone only through a relay that holds an APNs key of the team that signed it. With your own team, deploy your own relay ([SELF_HOSTING.md](SELF_HOSTING.md#your-own-app-id-and-relay)).

## Android

```sh
cd apps/pocketterm-mobile
fvm flutter run -d <your-android-device>          # debug build, debug signing
fvm flutter build apk --release                   # → build/app/outputs/flutter-apk/app-release.apk
fvm flutter build appbundle --release             # → build/app/outputs/bundle/release/app-release.aab (for Google Play)
```

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

**Push.** Android push goes through Firebase Cloud Messaging. Put your Firebase project's `google-services.json` (Firebase console → Project settings → your Android app, package `com.danyzmaj.pocketterm` or your own) in `apps/pocketterm-mobile/android/app/` (git-ignored). Without it a debug build builds and works with push off; a release build stops, so a store build never ships without push by accident (`fvm flutter build appbundle --release -P allowNoPush=true` builds one anyway). Pushes only arrive if the relay your server uses holds the service account of that same Firebase project ([SELF_HOSTING.md](SELF_HOSTING.md#your-own-app-id-and-relay)).

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

The checks to run before a pull request, and which of them CI runs (`.github/workflows/ci.yml`), are listed in [CONTRIBUTING.md](../CONTRIBUTING.md#pull-requests). On Windows, tests that need a POSIX system (`/bin/sh`, unix sockets, `chmod`) are tagged `posix`: run `fvm flutter test --exclude-tags posix` there.

[Maestro](https://maestro.mobile.dev) drives the phone app. `apps/pocketterm-mobile/maestro/demo.yaml` walks through the demo (dismissing the first-use tips with `tips.yaml`) and needs no server (`maestro test apps/pocketterm-mobile/maestro/demo.yaml`, the app signed out). Set `appId` in a flow to your bundle id.

The whole path, end to end, runs on a Mac with `tool/e2e/run.sh`: a server (`--server local`, the default; `builtin`, the one in the desktop app over Tailscale; `supabase`, PocketTerm on a local Supabase; `supabase-cloud`, a new project on supabase.com made by the desktop's own setup and deleted after; or a server's URL with its setup link), the real desktop app, throwaway kitty, Ghostty and WezTerm windows with a fake omp, and the phone in the Simulator or an Android emulator (`--platform android --avd <name>`), which signs in with the computer's **Add a phone…** code (`apps/pocketterm-mobile/maestro/e2e/`). It prints a pass/fail table; artifacts go to `build/e2e/<stamp>/`. `tool/e2e/bin/run.dart` describes every option; [TESTING.md](TESTING.md) what each run covers.

The installed app, as from Finder: `tool/smoke/run.sh prepare` builds a test build and copies it to a throwaway place, then `tool/smoke/scenario.sh wizard getready settings menubar quit` drives it through accessibility (the terminal running it needs Accessibility and Screen Recording). `tool/smoke/run.sh clean` removes what it made.

The screenshots in `docs/images` are rendered by each app's screenshot tests: `fvm flutter test --tags screenshots --run-skipped` in `apps/pocketterm-desktop` (the Mac's) and in `apps/pocketterm-mobile` (the phone's).
