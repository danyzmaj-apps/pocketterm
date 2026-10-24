# Security

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's [private vulnerability reporting](https://github.com/danyzmaj-apps/pocketterm/security/advisories/new) (the repository's **Security** tab). Don't open a public issue. You get an answer within a week, and credit in the advisory if you want it.

What the publisher collects: the [privacy policy](https://www.danyzmaj.com/pocketterm/privacy/).

## Scope

- The desktop app for macOS and Windows (`apps/pocketterm-desktop`), including its local API, the omp extension and the Claude Code plugin (`integrations/`).
- The phone app for iPhone and Android (`apps/pocketterm-mobile`) and the shared code (`packages/pocketterm_core`).
- The PocketTerm server (`packages/pocketterm_server`, [PROTOCOL.md](packages/pocketterm_server/PROTOCOL.md)), both built into the desktop app (`apps/pocketterm-desktop/lib/hosting`) and as the Docker image with Caddy (`apps/pocketterm-server`), and PocketTerm on Supabase (`apps/pocketterm-desktop/supabase`, [its README](apps/pocketterm-desktop/supabase/README.md)): the Edge Function, the migrations and the setup that deploys them.
- The publisher's push relay (`apps/pocketterm-relay`, [its SECURITY.md](apps/pocketterm-relay/SECURITY.md)).

Out of scope: Tailscale, Supabase, Apple, Google, Microsoft, Docker, Caddy and Let's Encrypt themselves; the terminals and coding agents PocketTerm drives; a server whose owner gave its setup link, a pairing code or a computer's QR code to someone else; attacks that need an unlocked device the attacker already controls.

Most valuable: getting a device token without a valid setup token or pairing code, or past the redeem throttle; using the server without a device token; reading or changing anything a computer seals without its key, or planting a key on a phone; reaching the built-in server from outside the owner's tailnet, or the local API from another user or machine; getting the relay to send anything but ciphertext or a checked Live Activity state.

## Threat model

There is no central PocketTerm server. Each owner runs their own, which serves only their computers and phones. The server, the network, the push relay, Apple and Google are treated as untrusted for content: they carry ciphertext they can't read or forge. What keeps one computer's sessions from a device is that computer's key, not the server.

PocketTerm trusts the computer it runs on and the phones that scanned its code. Anyone holding a computer's key can read and drive that computer's sessions.

## What each party sees

| Party | Sees | Never sees |
| --- | --- | --- |
| **Your PocketTerm server** | Device labels and platforms, when each signed in and was last active; computer ids, names and platforms; the setup token; SHA-256 of device tokens and pairing codes; push tokens; which sessions each phone follows and their state (working, needs you, finished, ended); for each iPhone Live Activity, its last state (with since when and, for needs you, what for) and when it went out, kept until it ends so the server can send it again while the computer checks in; the size, timing, topic and event name of each live message; that a blob of some size passed through; callers' addresses (in memory, for the redeem throttle) | Sessions, transcripts, prompts, screens, keystrokes, window titles, folders, images, files, file names, notification text |
| **Push relay** (opt-in; in memory, for one request) | The push token, the ciphertext, the opaque tags, an iPhone Live Activity's state, your server's address | Notification text, computer ids, session keys or names |
| **Apple (APNs) / Google (FCM)** | The push token, the ciphertext, the opaque tags, the time; an iPhone Live Activity's state; that an Android followed-session notification ended | Notification text, computer ids, session keys or names |
| **Tailscale** (On this computer) | Your devices' names and addresses, and when they connect | Anything PocketTerm sends (WireGuard, plus PocketTerm's own encryption inside HTTPS) |
| **VPS provider** (On my own server) | Encrypted traffic, and with access to the machine, what the server stores (above) | Anything the computer seals |
| **Supabase** (the company, in the region you pick; Supabase option) | What the server stores (above): the device list (names, platforms, when created and last seen), computer names, push tokens, which sessions each phone follows and each iPhone Live Activity's last state, pairing codes for 10 minutes (hashed), device tokens (hashed), the timing of messages and pushes; connection IP addresses | Anything the computer seals: the function and Realtime relay ciphertext only |
| **Cloudflare** (in front of the relay) | That your server sent an encrypted request of some size, and the status code | The push token, the tags, the kind of push |

## Keys and storage

Each computer makes a 32-byte channel key the first time it needs one (`apps/pocketterm-desktop/lib/channel_keys.dart`). It never goes to any server.

| Platform | Where keys and the device token live |
| --- | --- |
| macOS | The login Keychain |
| Windows | A file in the app's `%APPDATA%` folder, encrypted for the Windows user with DPAPI |
| iPhone | The Keychain in the app's App Group, `AfterFirstUnlockThisDeviceOnly` (readable by the notification extension; not in backups or on another device) |
| Android | App-private storage, encrypted with a key held in the Android Keystore; excluded from backups and device-to-device transfer |

A device token is 32 random bytes; the server keeps only its SHA-256. It works until the device signs out or is revoked, or the server's data is erased; its WebSockets then close.

## Pairing and Reset key

- **Setup link.** A computer signs in with the server's setup link (`pocketterm://setup?url=…&setup=…`), whose token is 32 random bytes, reusable by the owner's computers until replaced with `pocketterm-server setup-link --new`. It lets a computer sign in, list and revoke devices and erase the server's data, but never read a computer's sessions. The server keeps it in its data folder (`setup-token`).
- **Phone sign-in.** A phone signs in only by scanning a code from a signed-in computer: 140 random bits, single use, valid 10 minutes, stored as SHA-256. Unknown, expired and used codes get the same answer. Setup tokens and pairing codes share one throttle: after 10 failures from one address (an IPv6 address counts by its /64) within 10 minutes, every redeem from it gets 429 until the oldest failure is 10 minutes old.
- **The QR code carries the key.** The same QR code holds the server address, the pairing code and the computer's id and channel key, so it is a secret; the app says so where it shows it. A phone keeps one key per computer and shows a computer it holds no key for as locked.
- **No keys from links.** Only the in-app scanner adds a key. A link opened from outside the app never does, and one that would sign a signed-out device in to another server waits for the person to confirm.
- **Reset key** (computer's **Settings → Phone**) makes a new key. Every phone must scan again; a lost phone's key opens nothing new.
- **Sign out a phone** (computer's **Settings → Account**, **Sign out…** next to the phone) revokes its device token (`DELETE /v1/devices/:id`): it can no longer list the computers, upload or get pushes. For a lost phone, do both.
- **Leaving.** **Sign out** on a computer and **Leave this server** on a phone end that device's sign-in and delete its keys. **Erase this server's data** signs every device out and deletes what the server keeps.

## Encryption and replay protection

Code: `packages/pocketterm_core/lib/e2e.dart`.

- Everything between a computer and its phones is sealed with AES-256-GCM under the computer's channel key, with a random 12-byte nonce and additional data naming what it is: `pocketterm/v1|<computer id>|<event>` for live messages, `pocketterm/v1|image|<blob path>` for images and files, `pocketterm/v1|push|<computer id>` for notifications, `pocketterm/v1|activity|<computer id>` for Android followed sessions. A sealed message can't be moved to another computer, event, blob or purpose.
- Every live message carries a timestamp, a random id, its sender's random epoch and a sequence number. The receiver drops a message more than 5 minutes off its clock or older than the receiving app's start, an id seen in the last 10 minutes, and a sequence number at or below the last one from that epoch.
- Sealed notifications carry a timestamp and a random id inside, so a phone refuses old or repeated ones.
- The server passes live messages on untouched and stores none of them. Anything that doesn't open with the computer's key is dropped.

## Attachments

- A phone sends up to 10 images and files per message, each up to 20 MB (the server's 20 MiB blob limit less the sealing). Images are scaled to at most 2048 px.
- Each file's bytes are sealed with the computer's key, with the blob path as additional data. The file name and type travel only inside the sealed prompt. The server sees a blob of some size and deletes it once downloaded, or after an hour if nobody downloads it.
- The computer saves each prompt's files in a folder of its own, `pocketterm-files/<12 random characters>/` in the user's temp folder (`$TMPDIR` on a Mac, where the folder is mode 700; the per-user `%TEMP%` on Windows). Images for Claude Code go to `pocketterm-images/` in the same temp folder. Both are deleted once older than a day, when PocketTerm starts and when new ones arrive.
- File names are reduced to their last path component, stripped of control characters, `<>:"|?*` and trailing dots and spaces, kept off Windows device names and capped at 120 characters. Nothing is overwritten: a clash becomes `name (2).ext`. The prompt names each file as `@path`; the Claude Code plugin lets Claude read these files without asking.

## Push notifications

Pushes are off until the person turns them on in the phone app, which explains who sees what before asking.

- The computer seals each notification (title, text, session, state) itself and hands the server `{tag, enc, collapse}`. `tag` is the first 8 bytes of HMAC-SHA256(channel key, `pocketterm/v1|push-tag`), so a phone finds the right key; `collapse` is a per-session HMAC under the same key, so a newer notification replaces an older one. Neither means anything without the key.
- The server sends the relay one request per phone, its whole body sealed to the relay's X25519 public key (fresh ephemeral key, HKDF-SHA256, AES-256-GCM; `packages/pocketterm_server/lib/src/relay.dart`). No computer id or session key leaves the seal.
- The relay (`https://push.danyzmaj.com/v1/push`, run by Danijel Lovric on his server in Germany) opens the request in memory, refuses unknown fields, forwards `enc` and the tags to APNs or FCM and stores nothing. A phone without the key shows a plain "PocketTerm" notification.
- A fork can run its own relay and point its servers at it with `PUSH_RELAY_URL` and `PUSH_RELAY_KEY`.

## Local API

The desktop app's API (`apps/pocketterm-desktop/lib/local_api.dart`) listens on `127.0.0.1` only, behind a random token in `~/.config/pocketterm/cli.json` (`%USERPROFILE%\.config\pocketterm` on Windows). On macOS the file is mode 600 in a mode 700 folder, and no token is written if that fails. The omp extension and Claude Code plugin send the token only after the app proves it holds it (an HMAC-SHA256 of a fresh nonce), so a stale port never receives it. The file is removed when PocketTerm quits. kitty is reached over its unix sockets, and only sockets owned by the current user count.

## Where the server listens

- **On this computer:** the built-in server listens on `127.0.0.1`. `tailscale serve` publishes it at `https://<computer>.<tailnet>.ts.net` to the owner's tailnet only; Funnel is never used. PocketTerm changes Tailscale's Serve settings only after reading them (`tailscale serve status`): it never replaces or removes what something else serves on port 443, and changes nothing while they can't be read.
- **On my own server:** only Caddy is published (ports 80 and 443, Let's Encrypt certificate); the server's port 47900 stays on Docker's network. The server image has no shell and runs as user 65532. The compose file comes from the release tag matching the app and pins the server image of the same version.
- **Supabase:** a project in the owner's Supabase organization, in the region they pick. One Edge Function (`pocketterm`) answers the same REST paths at `https://<ref>.supabase.co/functions/v1/pocketterm`; the database, tables and Storage bucket are reachable only through it (service-role RPCs, a private bucket). The live channel is Supabase Realtime on private topics: the function gives a signed-in device a 10-minute token, and Realtime's row level security lets it in only while that device is still signed in. Contents stay end-to-end encrypted exactly as with the other options.
  - **Access token.** The wizard asks for a Supabase personal access token. It covers the whole Supabase organization (every project in it). PocketTerm uses it only during setup and never stores it. Use a Supabase organization of its own for PocketTerm, and delete the token at [supabase.com/dashboard/account/tokens](https://supabase.com/dashboard/account/tokens) afterwards.
  - **Signing key.** The setup imports a signing key PocketTerm made into the project as its JWT signing key; the function keeps it as a secret to sign the 10-minute live channel tokens. Anyone with access to the project (members of the organization, Supabase) could use it: the same trust as the project itself.
  - **Revoking.** A phone or computer that is signed out is told at once over the live channel and refused at its next connection; at worst its live connection lasts until its 10-minute token runs out (messages stay sealed).
  - **Free projects pause** after about a week without use (reliability, not security): restore it at [supabase.com/dashboard](https://supabase.com/dashboard). The free plan allows 2 active projects per account.

## Test builds

tool/smoke and tool/e2e build the desktop app with `--dart-define=POCKETTERM_SMOKE=true` (`apps/pocketterm-desktop/lib/test_hooks.dart`). Only such a build reads the environment variables that point it at stand-ins: `POCKETTERM_TAILSCALE` (another program run as the Tailscale CLI), `POCKETTERM_CLI_JSON` (another file for the local API's port and token), `POCKETTERM_KITTY_DIR` (another folder of kitty sockets) and `POCKETTERM_PROFILE` (secrets kept in memory instead of the Keychain, the accessibility tree always on). A released build ignores them. The Mac app's window code still reads `POCKETTERM_PROFILE` to announce its accessibility tree, which only asks macOS to read the window as VoiceOver would.

## Updates

Mac updates are accepted only when signed with the project's Sparkle EdDSA key, and are notarized. The Windows app links to the latest GitHub release; its installer is not code-signed yet. Phone builds go to invited testers through TestFlight and Google Play internal testing.

## Known limits

- **iPhone Lock Screen.** Apple delivers Live Activity updates to the system, which apps can't decrypt, so a followed session's state (`working`, `needs`, `done`, `ended`, since when and, for `needs`, whether it is a question, an approval or a plan) travels in plain text to Apple, the relay and your server, which keeps the last one of each iPhone Live Activity until it ends (to send it again so it doesn't show as stale while the computer checks in). It never carries text, names, folders or ids. An Android followed session's end, when the server sends it for a computer that went quiet, is likewise plain: `ended`, a time and the session's opaque tag.
- **Metadata.** The server, the relay, Apple, Google and the network see when messages and pushes are sent and how big they are.
- **The relay is open.** It can't tell callers apart, since self-hosted servers hold no publisher credentials. Anyone who knows a phone's push token can make it show a generic "PocketTerm" alert, or move or end one of its Live Activities, within the relay's rate limits.
- **Secrets on the server.** Whoever can read the server's data folder can read the setup token and sign in a computer: list and revoke devices or erase the server's data, but not read sessions.
- **The computer.** Received files stay in the temp folder, readable by the computer's user and its coding agents, until they are older than a day and PocketTerm starts or receives new ones. On Windows, the local API token file relies on the user profile's default permissions.
