# Building from source

## Tools

- [fvm](https://fvm.app): the Flutter version is pinned in `.fvmrc` (`fvm install` fetches it).
- **Mac and iPhone apps:** Xcode 26 or newer with your Apple ID signed in (Xcode → Settings → Accounts), and CocoaPods (`brew install cocoapods`).
- **Android:** [Android Studio](https://developer.android.com/studio) (or the command-line Android SDK) with a JDK 17; `fvm flutter doctor` says what's missing.
- **Windows app:** a Windows 10 1809+ or 11 PC with Visual Studio 2022 and its "Desktop development with C++" workload (`fvm flutter doctor` checks it), and [Inno Setup 6](https://jrsoftware.org/isinfo.php) for the installer (`winget install JRSoftware.InnoSetup`).
- **Backend:** the Supabase CLI, Docker (only to run Supabase locally) and [Deno](https://deno.com) for the function checks.

```sh
# at the repo root
fvm install
fvm flutter pub get   # resolves the whole workspace
```

The repo is a Dart pub workspace: the desktop app (macOS and Windows) in `apps/pocketterm-desktop`, the phone app (iPhone and Android) in `apps/pocketterm-mobile`, the shared code in `packages/pocketterm_core`. Each command below says which directory it runs in.

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

A debug build next to the PocketTerm you use shares more than its code. Built with the same bundle id, it reads and writes the same preferences (server, account, this computer's id), and by default both write `~/.config/pocketterm/cli.json` (the terminal API's port and token) and talk to the kitty behind `/tmp/kitty*`. To keep a test run apart:

```sh
# in apps/pocketterm-desktop
mkdir -p /tmp/pocketterm-e2e
POCKETTERM_CLI_JSON=/tmp/pocketterm-e2e/cli.json POCKETTERM_KITTY_DIR=/tmp/pocketterm-e2e fvm flutter run -d macos
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

Only one PocketTerm runs per Windows user: starting it again brings the running one's window to the front, and a `pocketterm://` link (the GitHub sign-in callback) goes to the running one. A debug build and an installed copy are the same app to Windows, so quit the installed one first.

**The installer.** After the release build, in `apps/pocketterm-desktop`:

```powershell
& "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" /DMyAppVersion=0.1.0 windows\installer.iss
# → build\windows\installer\PocketTerm-0.1.0-setup.exe
```

[windows/installer.iss](../apps/pocketterm-desktop/windows/installer.iss) installs per user (no admin prompt) into `%LOCALAPPDATA%\Programs\PocketTerm`, registers the `pocketterm://` link under `HKCU\Software\Classes\pocketterm`, and removes both those keys and the Launch at login entry (`HKCU\…\CurrentVersion\Run\PocketTerm`) when uninstalled. The installer is unsigned. CI builds the same one for every release ([RELEASING.md](RELEASING.md#windows)).

On Windows, Terminal from phone works with WezTerm only; the setup wizard and **Settings → Terminals** install it (`WezTermSetup` in `lib/wezterm_setup.dart` pins the release and its checksum).

## iPhone

For your own phone without TestFlight, install it from source. It needs a **paid** Apple Developer account: the app shares the server address and its push key with its push extension through an App Group, and push and Live Activities need the Push Notifications capability.

```sh
cd apps/pocketterm-mobile
open ios/Runner.xcworkspace   # once: pick your phone, let Xcode register the device
fvm flutter run -d <your-iphone> --release
```

Then pair it: on the computer, **Settings → Add a phone…**, and scan the code with the app ([SELF_HOSTING.md](SELF_HOSTING.md#connect-the-apps)).

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

## Backend, locally

```sh
cd apps/pocketterm-desktop                       # the backend lives with the desktop app, which bundles it for its setup wizard
supabase start                                   # Docker; applies supabase/migrations
supabase functions serve --no-verify-jwt
```

Point the desktop app at `http://127.0.0.1:54321` with the local publishable key from `supabase status` (**I already have one: connect it**). GitHub sign-in against a local stack needs a second GitHub OAuth app whose callback is `http://127.0.0.1:54321/auth/v1/callback`, with its id and secret as `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` in `apps/pocketterm-desktop/supabase/.env` (git-ignored). A local `push` sends through the publisher's relay unless you set `PUSH_RELAY_URL`.

## Checks

The checks to run before a pull request, and which of them CI runs (`.github/workflows/ci.yml`), are listed in [CONTRIBUTING.md](../CONTRIBUTING.md#pull-requests). On Windows, tests that need a POSIX system (`/bin/sh`, unix sockets, `chmod`) are tagged `posix`: run `fvm flutter test --exclude-tags posix` there.

[Maestro](https://maestro.mobile.dev) drives the iOS simulator app with `apps/pocketterm-mobile/maestro/sign_in.yaml`. It needs a simulator and a test backend. Set `appId` in the flow to your bundle id. Phones sign in only with a code from a computer, so the flow pastes one when the app isn't signed in: pass a reviewer code's link (**Settings → Reviewer access**, shown after pressing ⌥ Option; reusable) as `SETUP_LINK`, or a fresh **Add a phone…** code for a single run.

```sh
maestro test -e SETUP_LINK='pocketterm://setup?url=…&key=…&code=…' apps/pocketterm-mobile/maestro/sign_in.yaml
```
