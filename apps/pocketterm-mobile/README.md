# PocketTerm for iPhone and Android

The phone app: your computers' coding sessions and terminal windows, pairing with a server by scanning the code PocketTerm shows on your computer. Phones don't set up servers. With several computers on one account, the home screen's title picks which one to show. **Try the demo** on the setup screen shows the app on a made-up computer (`ios/PocketTerm/Demo/`, `android/…/demo/`), with no server and no network.

Notifications are opt-in: after the first sign-in on a server the phone explains the push relay (push.danyzmaj.com) and asks; **Notifications** in the account sheet (iPhone) or Settings (Android) changes it later. Off, the phone's tokens are unregistered from the server and followed sessions end. When turning them on doesn't work, the phone says why: notifications off in the phone's Settings (with a way there), or no notification address from Apple or Google.

The first time it reaches your sessions (or the demo), the phone asks **New here?** and, on **Show me**, shows short tips one at a time; **Show tips again** in the account sheet brings them back.

Two native apps, one per platform, with the same features, strings and test ids:

| Path | What |
| --- | --- |
| `ios/` | The iPhone app (Swift 6, SwiftUI, iOS 17+), on the shared Swift package [`packages/PocketTermKit`](../../packages/PocketTermKit/): `PocketTerm/` (the app), `PocketTermLive/` (the Live Activity), `PocketTermPush/` (decrypts pushes), `Shared/`, `PocketTermTests/`; the Xcode project comes from `project.yml` (xcodegen). What looks different from 0.1.x: [UX-NOTES.md](ios/UX-NOTES.md) |
| `android/` | The Android app (Kotlin, Jetpack Compose, Material 3, Android 8.0+): `:app` (UI, FCM, the ongoing notification for followed sessions, dictation, launcher icons) and `:core` (the protocol core, pure Kotlin). [UX-NOTES.md](android/UX-NOTES.md) |
| `maestro/` | Maestro flows: `e2e/` (with its `run.sh`) for the end-to-end run, `demo.yaml` through the demo (with `tips.yaml`, which dismisses the first-use tips), `voice.yaml`, `queue.yaml`, `orchestrator.yaml` |
| `tool/` | `build-ipa.sh`, `build-aab.sh`: the store builds |
| `assets/icon/` | The app icon's source images (drawn by [`make_icon.swift`](../pocketterm-desktop/tool/make_icon.swift)) |

The two platforms do the same things, push included. Building Android from source, push needs your Firebase project's `android/app/google-services.json` (not committed); a debug build without it works without push, and a release build stops unless you pass `-PallowNoPush=true`.

**Error reports.** Off unless the build bakes in a GlitchTip/Sentry DSN, as the store builds do. Android: `-PsentryDsn=…` or the `SENTRY_DSN` environment variable at build time. iPhone: `SENTRY_DSN` in `config/Local.xcconfig` (written `https:/$()/…`) or on the xcodebuild command line; it lands in Info.plist as `SentryDSN`. `tool/build-aab.sh` and `tool/build-ipa.sh` take `SENTRY_DSN` from the environment or from `android/.env` / `ios/.env` (git-ignored; Baker writes them). With one, crashes, ANRs and app hangs are sent with the exception type, stack and app/OS version; messages have URLs, IPs, host names and email addresses replaced and are cut to 300 characters; no breadcrumbs, sessions, screenshots, user, device name or terminal content. Builds from source have no DSN unless you give one, so they send nothing.

Run it:

```sh
(cd ios && xcodegen generate && open PocketTerm.xcodeproj)    # then run the PocketTerm scheme
(cd android && ./gradlew :app:installDebug)                    # JDK 17
```

Building and signing: [docs/BUILDING.md](../../docs/BUILDING.md).
