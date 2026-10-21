# Architecture

How PocketTerm is put together. For what it does and how to set it up, see the [README](../README.md) and [SELF_HOSTING.md](SELF_HOSTING.md).

One Dart pub workspace (root `pubspec.yaml`): the desktop app for macOS and Windows in `apps/pocketterm-desktop/` (with the backend it bundles), the phone app for iPhone and Android in `apps/pocketterm-mobile/`, and what both use in `packages/pocketterm_core/`. Below, `core/` stands for `packages/pocketterm_core/`, `desktop/` for `apps/pocketterm-desktop/` and `mobile/` for `apps/pocketterm-mobile/`.

```mermaid
flowchart LR
  subgraph computer ["A computer (Mac or Windows PC)"]
    agent["omp or Claude Code<br/>with PocketTerm's integration"]
    term["Terminal windows<br/>kitty · tmux · WezTerm · iTerm2 · Terminal · Ghostty<br/>(Windows: WezTerm)"]
    app["PocketTerm desktop"]
    agent -->|"transcript, questions<br/>(local API)"| app
    app -->|"prompts, stop"| agent
    app <-->|"read screen, type, keys"| term
  end
  rt[("Your Supabase<br/>terminal:&lt;user&gt;:&lt;desktop&gt;")]
  phone["Phone<br/>Terminal list"]
  app <-->|"state, items, screens<br/>hello, sync, run"| rt
  rt <--> phone
  app -.->|"push: finished, needs you"| phone
```

## Layout

| Path | What |
| --- | --- |
| `core/lib/session.dart` | The connected backend and signing in (GitHub on a computer, a computer's code on a phone), pairing and reviewer codes (`functions/pair`), account deletion |
| `core/lib/backend.dart`, `connect.dart` | Which Supabase project to use: parsing and checking it, setup links, saving it (shared preferences on the desktop; the native side on phones, so the iPhone's push extension can read it from the App Group), the connect-an-existing-server form |
| `core/lib/account.dart` | Sign-in page and GitHub button (desktop), avatar |
| `core/lib/desktops.dart` | The account's computers (`desktops`): which ones the phone lists and which it picks |
| `core/lib/agent.dart` | The coding agents (omp, Claude Code): what a new session starts, how a session is named, whether a prompt steers, how an answer becomes keys |
| `core/lib/live.dart` | Terminal from the phone: the protocol (described at the top of the file), topics and routed session keys, transcript items and their seq/epoch log, questions, screen diffs |
| `core/lib/e2e.dart` | End-to-end encryption: a computer's channel key, sealing and opening bytes and envelopes (AES-256-GCM with additional data), the replay guard |
| `core/lib/terminal_channel.dart` | The private Realtime topic, kept joined on both sides; seals what goes out and opens what comes in (`ChannelSeal`), in order |
| `core/lib/terminal_remote.dart` | Phone: the remote for one computer (with that computer's key; images sealed before upload) and its disk cache |
| `core/lib/live_activity.dart` | Phone: followed sessions (Live Activities on iOS, ongoing notifications on Android) and their push tokens |
| `core/lib/terminal.dart`, `terminals.dart` | The terminal layer: `TerminalHost`, `TermWindow`, `TermCap`, `TermStatus`, keys, process snapshots, `windowOfTerm`; `Terminals`, every installed terminal as one |
| `core/lib/kitty.dart`, `tmux.dart`, `wezterm.dart`, `iterm.dart`, `apple_terminal.dart`, `ghostty.dart` | One `TerminalHost` per terminal |
| `core/lib/ansi.dart`, `chat_images.dart`, `ui.dart`, `logo.dart`, `native.dart` | Screen lines with ANSI colors; images for prompts; shared UI; the logo; the `pocketterm/native` platform channel |
| `desktop/lib/main.dart`, `controller.dart`, `main_window.dart` | The desktop app: one window that is the wizard, sign-in, the setup checklist or Settings (a status bar over the Phone, Coding agents, Terminals and Account tabs); `AppController` (account, this computer's id and its `desktops` row, its channel key and **Reset key**, the bridge, sealed pushes, the coding agents found and whether a phone has signed in) |
| `desktop/lib/channel_keys.dart` | This computer's channel key per account, in the system's secure storage (`flutter_secure_storage`: the login Keychain on a Mac, Credential Manager on Windows) |
| `desktop/lib/desktop_host.dart`, `windows_host.dart` | What differs per platform: window, menu-bar or tray item, launch at login, folder picker, idle time, keeping awake (`MacHost` over the native channel, `WindowsHost` in Dart) |
| `desktop/lib/update_check.dart` | Windows: the GitHub release check (the Mac uses Sparkle) |
| `desktop/lib/setup_page.dart`, `desktop/lib/onboarding/` | First-run setup: the wizard (`flow.dart`, `wizard.dart`), provisioning through the Supabase Management API (`supabase_admin.dart`, `provision.dart`); after the first sign-in, the setup checklist (`get_ready.dart`: coding agents, terminals, project folders, the phone) with its terminals (`terminals_card.dart`: the Mac's, WezTerm's install on Windows) and the pairing QR (`pair.dart`); reviewer codes (`reviewer.dart`) |
| `desktop/lib/terminal_fixes.dart`, `wezterm_setup.dart` | A Mac terminal's one-click fix for Settings and the setup checklist (kitty's lines in kitty.conf, System Settings' Automation page), and which terminals need one; on Windows, WezTerm's own installer, downloaded from its GitHub release, checked against its published SHA-256 and opened |
| `desktop/lib/local_api.dart`, `live_hub.dart` | The 127.0.0.1 API the agents report to, and their live sessions |
| `desktop/lib/terminal_bridge.dart` | The phone's way in: sessions and screens out on this computer's topic, its requests in |
| `desktop/lib/integrations.dart` | Finding omp and Claude Code on the computer, and installing and updating the bundled omp extension and Claude Code plugin (**Settings → Coding agents**, the setup checklist, Settings' status bar) |
| `desktop/macos/Runner/` | The Mac's native side: the main window, the menu-bar item, activation policy, launch at login, idle time, Sparkle |
| `desktop/windows/` | The Windows runner (single instance, `pocketterm://` links handed to the running instance) and `installer.iss` |
| `desktop/integrations/omp/pocketterm-live.ts` | omp extension: the session, live, for the phone |
| `desktop/integrations/claude/` | Claude Code marketplace with the `pocketterm` plugin: `hooks/pocketterm.ts` (the session, live), `hooks/items.ts` (Claude's transcript as items, its dialogs as questions), `tests/` |
| `desktop/supabase/` | Migrations, pgTAP tests, and the `pair` and `push` functions (bundled as app assets for the wizard); `relay` is the publisher's push relay |
| `mobile/lib/main.dart`, `mobile.dart`, `links.dart` | Phone app: sign-in by code, the computers' keys (loaded at start from the native side), the home page with the Terminal list (its sort and folded projects kept), a locked computer until its code is scanned, the computer picker, the account sheet, push and link routing; links to the desktop downloads and GitHub |
| `mobile/lib/terminal_view.dart`, `session_view.dart`, `switch_view.dart` | The Terminal list (sessions by project, sorted by name or recent activity; a project's heading folds on tap and offers a new session and folding on long press), screens, new sessions; a coding session's transcript and composer; switching an agent window that shows only as a screen to the conversation view |
| `mobile/lib/setup_page.dart`, `onboarding/scan.dart`, `chrome.dart` | Scanning or pasting a computer's code; the per-platform chrome (Cupertino on iPhone, Material 3 on Android) |
| `mobile/ios/Runner/AppDelegate.swift`, `mobile/ios/Shared/` | The iPhone half of `native.dart`: App Group, push registration, notification taps, Live Activities |
| `mobile/ios/PocketTermLive/`, `PocketTermPush/` | The Live Activity (WidgetKit); the notification service extension that decrypts pushes |
| `mobile/android/…/pocketterm/` | The Android half: `MainActivity.kt`, `PushService.kt` (FCM), `SessionActivities.kt` (ongoing notifications), `Notifications.kt`, `PocketTermShared.kt` |
| `config/PocketTerm.xcconfig` | Team, bundle id and App Group for every Xcode target (`Local.xcconfig` overrides them) |

## Backend

Every user runs their own Supabase project, built from `desktop/supabase/migrations` and `desktop/supabase/config.toml`; nothing is shared between users.

| Migration | Holds |
| --- | --- |
| `…_server.sql` | `allowed_signups` and the `before_user_created` hook (GitHub only; the first account owns the server); `pairing_codes`, `pairing_failures`, `redeem_pairing_code`; the reviewer demo account (`reviewer_access_active`, `end_idle_demo_sessions`, its pg_cron job); `delete_my_account` |
| `…_terminal.sql` | The Realtime policies for the terminal topic; the private `terminal` storage bucket images from the phone pass through |
| `…_push.sql` | `push_devices` and `activity_tokens` (service role only) |
| `…_desktops.sql` | `desktops`, the account's computers (own rows only); the topic policies per computer |
| `…_desktops_seen_at.sql` | The trigger that stamps `desktops.seen_at` with the server's clock |
| `…_push_e2e.sql` | Drops `push_devices.key`: push text is sealed on the computer now |

- **Auth.** A computer signs in with GitHub through each owner's OAuth app (`[auth.external.github]`, redirect `pocketterm://login-callback`). Phones never use GitHub: they redeem a code from a computer (`functions/pair`), which makes a fresh session of their own.
- **Computers.** Each desktop picks a random 8-character id per account (preference `desktop_id_<user id>`), upserts its `desktops` row (name, `macos` or `windows`) while its bridge runs and every 60 s, and deletes it on sign-out. A trigger (`…_desktops_seen_at.sql`) stamps `seen_at` with the server's clock on every write, so a computer's wrong clock can't skew it. The phone lists rows seen in the last 30 days and calls one online when it was seen in the last 150 s.
- **Terminal topic.** Each computer talks to the phones on the private Realtime broadcast topic `terminal:<user id>:<desktop id>`. RLS on `realtime.messages` lets a user join only topics that start with `terminal:<their id>:`. Nothing on it is stored, and everything on it is sealed with the computer's key (below). The protocol is at the top of `core/lib/live.dart`; its `state` carries, per coding agent found on the computer, whether PocketTerm is installed, out of date or missing in it (`agents`, `AgentIntegration` in `core/lib/agent.dart`), so the phone can say why an agent's window shows only as a screen.
- **End-to-end encryption** (`core/lib/e2e.dart`).
  - *Keys.* Each computer has one channel key per account, 32 random bytes made the first time it's needed (`desktop/lib/channel_keys.dart`, under `channel_key_<desktop id>` in the system's secure storage). It never goes to a server. **Reset key** (Settings → Phone) replaces it and restarts the bridge; every phone must scan again. A phone keeps a map of desktop id to key on its native side (`Native.setChannelKey`, `removeChannelKey`, `channelKeys`: the Keychain in the App Group on iPhone, Keystore-backed on Android) where the push extension reads it too, and caches it in Dart (`MobileSession.computerKey`). Sign-out removes every key.
  - *Pairing.* The computer's QR is `pocketterm://setup?url=…&key=…&code=…&d=<desktop id>&k=<base64url key>` (`Backend.linkWithCode`, `Backend.computerKey`). Scanning it signed out signs in and stores the key; signed in (the locked computer's **Scan**, or **Scan a computer's code** in the picker) it only stores the key. A link without `d`/`k` still signs in; that computer stays locked. A link opened from outside the app never replaces a key the phone holds. A computer the phone has no key for gets no remote: nothing joins its topic.
  - *Envelope.* Every live event's payload is replaced by `{"v":1,"n":"<base64 nonce>","c":"<base64 ciphertext and tag>"}`: AES-256-GCM, 12-byte random nonce, AAD `pocketterm/v1|<topic>|<event>`, plaintext the original JSON plus `ts` (ms since epoch) and, from a phone, `mid` (16 random characters). The receiver drops a bad version or tag, a `ts` more than 5 minutes off and (on the computer) a missing `mid` or one seen in the last 10 minutes, and logs each kind once. Sealing and opening are queued so messages keep their order. Chunks (`chunkJson`) stay under 40 000 bytes of JSON and a full screen under 60 000, so a sealed message fits Realtime's limits (a self-hosted server's default is 100 KB).
  - *Images.* The phone seals each image's bytes (AAD `pocketterm/v1|image|<path>`, raw `nonce ‖ ciphertext ‖ tag`) before uploading it as `application/octet-stream`; the computer downloads, opens and deletes it.
  - *Push.* Below.
- **A phone signed in.** The setup checklist and Settings know a phone has signed in when one of the user's single-use pairing codes has been used (`pairing_codes.last_used_at`, which RLS lets its maker read) or a phone says hello on the terminal topic.
- **Push.** `functions/push` registers phones (`register`: the push token, nothing secret) and takes `notify` and `activity` calls from computers. A computer seals each notification's JSON `{title, body, session, state}` itself with its channel key (AES-256-GCM, AAD `pocketterm/v1|push|<desktop id>`) and sends `{desktop, enc, collapse?}`; the function hands `enc` and the desktop id to the publisher's relay (`PUSH_RELAY_URL`) unread, the relay puts them in the push as `enc` and `d`, and the phone's notification extension (iOS) or FCM service (Android) opens it with that computer's key, or shows a generic "PocketTerm" alert when it has none. Live Activity pushes carry a state only and stay unencrypted (Apple shows them without the app). Session keys in pushes, Live Activities and `pocketterm://session?key=` links are routed: `<desktop id>/<session key>`, so a tap selects that computer before opening the session.
- **Setup wizard.** With a Management API token, the desktop app does what `desktop/tool/setup-backend.sh` does. The migrations and function sources ship as app assets, so a downloaded app needs neither the repo nor the CLI. Migrations are recorded in `supabase_migrations.schema_migrations`, the CLI's own table, so the script and the wizard agree on what's applied.

## Terminals

Each terminal is a `TerminalHost` (`core/lib/terminal.dart`): list its windows (`TermWindow`: key, title, cwd, foreground program, `app`, `caps`, `via`), read a screen, type, press keys, open a window, close one, and a `TermStatus` (`ready`, `limited`, `setup`, `idle`, `missing`, with a note and a fix) for **Settings → Terminals** and the setup checklist. Capabilities (`TermCap`): `read`, `ansi`, `type`, `line`, `keys`, `close`; the phone shows only what a window can do, and answers questions with keys only where the window can be read and take keys.

| Terminal | How | Window key |
| --- | --- | --- |
| kitty | Remote control over its unix socket (`listen_on unix:/tmp/kitty`); only sockets the current user owns | `kitty-<pid>/<id>` |
| tmux | The `tmux` CLI on every server socket of the user | `tmux:<socket>/<pane n>` |
| WezTerm | `wezterm cli` per GUI socket (`~/.local/share/wezterm/gui-sock-<pid>`; on Windows under `%USERPROFILE%`) | `wezterm:<gui pid>/<pane>` |
| iTerm2 | AppleScript | `iterm:<session UUID>` |
| Terminal | AppleScript | `terminal:ttysNNN` |
| Ghostty | AppleScript | `ghostty:<UUID>` |

`Terminals` (`core/lib/terminals.dart`) puts the installed ones together: all six on macOS, WezTerm only on Windows (Settings and the setup checklist install it there: `desktop/lib/wezterm_setup.dart`). A tmux pane shown in a GUI window is listed once, as the pane. An app that can't both read and press keys (Terminal, Ghostty) launches a phone-started session inside tmux when tmux is installed. An agent's `hello` carries its terminal environment (`TERM_PROGRAM`, `KITTY_*`, `TMUX`, `WEZTERM_PANE`, …), which `windowOfTerm` turns into its window's key.

**Screen only to conversation.** An agent window no live session claims (opened before PocketTerm was installed in its agent) shows on the phone as a screen, badged **Screen only**. Where the computer says PocketTerm is installed in that agent and the window's terminal can press keys and type, the phone offers to switch it, with two `run` ops (`core/lib/live.dart`) the bridge does with the window's terminal (`desktop/lib/terminal_bridge.dart`):

| Op | The computer | Answer |
| --- | --- | --- |
| `probe {window}` | Reads the screen, waits 2 s, reads it again | `ran {busy}`: the text changed (the agent is at work) |
| `switch {window, agent}` | omp: Esc (stops a run), Ctrl+C (empties its editor; Ctrl+U clears one line only), Ctrl+D (quits on an empty editor), waits until the tty's foreground program isn't omp (up to 8 s; 2 s where the terminal tells no tty), then types `omp -c` and Enter. Claude Code: types `/reload-plugins` and Enter | `ran {}`, or `ran {error}` |

The phone shows "Switching…" until a session reports from that window, then its session page replaces the screen; after 25 s it says the window didn't come back as a conversation. When the probe said busy, the sheet offers **Restart and continue**, whose session page prompts `continue` once the session is online and at rest (showing **Continue** instead if that fails), and **Just restart**, whose session page shows **Continue**.

## Local API

On launch the desktop app listens on a random 127.0.0.1 port and writes `{port, token, pid}` to `~/.config/pocketterm/cli.json` (on Windows under `%USERPROFILE%`), or to the file `POCKETTERM_CLI_JSON` names. The extensions ask `/v1/ping?nonce=<fresh>` without the token and send it only if `proof` is the HMAC-SHA256 of `pocketterm-ping\n<port>\n<nonce>` under the token, so whatever listens on a port a stale `cli.json` names gets neither the token nor any commands.

```
GET   /v1/ping?nonce=N   → {"app": "pocketterm", "proof"}   no token
GET   /v1/ping           → {"app": "pocketterm", "pid"}   with the token: this PocketTerm is up
GET   /v1/live           WebSocket: a coding session reporting itself (omp)
POST  /v1/live/http      {conn?, frames, wait?, close?} → {conn, frames}   the same over HTTP long polls (Claude Code)
Authorization: Bearer <token>   (everything but /v1/ping?nonce=)
```

## Building and testing

See [BUILDING.md](BUILDING.md) and [CONTRIBUTING.md](../CONTRIBUTING.md#pull-requests).
