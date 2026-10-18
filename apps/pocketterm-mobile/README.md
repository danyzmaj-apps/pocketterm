# PocketTerm for iPhone and Android

The phone app: your computer's coding sessions and terminal windows, pairing with a server by scanning the code PocketTerm shows on your computer. Phones don't set up servers.

| Path | What |
| --- | --- |
| `lib/` | Flutter app (shared code comes from [`packages/pocketterm_core`](../../packages/pocketterm_core/)) |
| `ios/` | Runner (native channel, push, Live Activities), `PocketTermLive` (the Live Activity), `PocketTermPush` (decrypts pushes) |
| `android/` | `MainActivity` (native channel), FCM service, the ongoing notification for followed coding sessions |
| `maestro/` | iOS simulator flows |
| `test/screenshots/` | The docs' phone screenshots, rendered on made-up data |

The two platforms do the same things, push included. Building Android from source, push needs your Firebase project's `android/app/google-services.json` (not committed); a debug build without it works without push, and a release build stops unless you pass `-P allowNoPush=true`.

Run it from this directory:

```sh
fvm flutter run -d <device>
```
