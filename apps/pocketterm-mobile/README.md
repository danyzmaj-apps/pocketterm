# PocketTerm for iPhone and Android

The phone app: your computers' coding sessions and terminal windows, pairing with a server by scanning the code PocketTerm shows on your computer. Phones don't set up servers. With several computers on one account, the home screen's title picks which one to show. **Try the demo** on the setup screen shows the app on a made-up computer (`lib/demo/`), with no server and no network.

Notifications are opt-in: after the first sign-in on a server the phone explains the push relay (push.danyzmaj.com) and asks; **Account → Notifications** changes it later. Off, the phone's tokens are unregistered from the server and followed sessions end. When turning them on doesn't work, the phone says why: notifications off in the phone's Settings (with a way there), or no notification address from Apple or Google.

The first time it reaches your sessions (or the demo), the phone asks **New here?** and, on **Show me**, shows short tips one at a time; **Show tips again** in the account sheet brings them back.

| Path | What |
| --- | --- |
| `lib/` | Flutter app (shared code comes from [`packages/pocketterm_core`](../../packages/pocketterm_core/)) |
| `ios/` | Runner (native channel, push, Live Activities), `PocketTermLive` (the Live Activity), `PocketTermPush` (decrypts pushes) |
| `android/` | `MainActivity` (native channel), FCM service, the ongoing notification for followed coding sessions |
| `maestro/` | Maestro flows: `e2e/` (with its `run.sh`) for the end-to-end run, `demo.yaml` through the demo (with `tips.yaml`, which dismisses the first-use tips) |
| `test/screenshots/` | Renders the phone screenshots in [`docs/images`](../../docs/images/): `fvm flutter test --tags screenshots --run-skipped` |

The two platforms do the same things, push included. Building Android from source, push needs your Firebase project's `android/app/google-services.json` (not committed); a debug build without it works without push, and a release build stops unless you pass `-P allowNoPush=true`.

Run it from this directory:

```sh
fvm flutter run -d <device>
```

Building and signing: [docs/BUILDING.md](../../docs/BUILDING.md).
