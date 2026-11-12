<div align="center">

<img src="docs/images/icon.png" width="112" alt="PocketTerm icon">

# PocketTerm

**Control the coding agents running on your computer from your phone.**

[![Latest release](https://img.shields.io/github/v/release/danyzmaj-apps/pocketterm?label=release)](https://github.com/danyzmaj-apps/pocketterm/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platforms](https://img.shields.io/badge/platforms-macOS%20%C2%B7%20Windows%20%C2%B7%20iOS%20%C2%B7%20Android-555)

<br>

<img src="docs/images/phone-terminal.png" width="30%" alt="Phone: sessions grouped by project, then the other terminal windows">
&nbsp;
<img src="docs/images/phone-session.png" width="30%" alt="Phone: a coding session as a conversation, with the attach button">
&nbsp;
<img src="docs/images/phone-switch.png" width="30%" alt="Phone: switching a screen-only omp window to the conversation view">

</div>

---

PocketTerm is a desktop app (macOS menu bar, Windows tray) and a phone app (iPhone, Android). Leave [omp](https://github.com/can1357/oh-my-pi) or [Claude Code](https://github.com/anthropics/claude-code) working in a terminal and keep driving it from your phone. Computer and phone meet in a PocketTerm server built into the desktop app, reached over your own [Tailscale](https://tailscale.com) network, and everything between them is end-to-end encrypted. There is no PocketTerm cloud.

## What it does

- **Conversations.** Each coding session reads as a conversation: streamed Markdown answers, tool calls as cards. Prompt, steer or queue, stop a run, and type `/` for the agent's slash commands. Queued prompts wait on your computer, where you can edit, reorder, delete or pause them from the phone until each one's turn.
- **Images and files.** Up to 10 per message, from the camera roll, the clipboard or the phone's files, up to 20 MB each. The agent gets them the way you would give them at the computer: saved there and named in the prompt as `@path`.
- **Approvals and questions.** Answer the agent's questions, approve tool calls and review plans with a tap.
- **Screens and keys.** Every other terminal window is a live screen you can type and press keys in.
- **New and ended sessions.** Start your agent or a shell in any project folder without taking the computer's focus; swipe a row to end a session or close a window.
- **An orchestrator.** Ask one omp session about all the others from the bar beside the +: it lists them, reads their conversations, and prompts or stops one when you ask. It runs in PocketTerm's own folder on the computer, and only it gets those tools.
- **Switch to conversation.** A session opened before PocketTerm was installed shows only its screen. **Switch to conversation** restarts omp on the same conversation (`omp -c`), or reloads Claude Code's plugins.
- **Notifications and Live Activities.** Opt-in pushes when a run finishes or the agent needs you, and a Live Activity (iPhone) or ongoing notification (Android) for the sessions you follow.
- **Several computers.** One server, several Macs and Windows PCs on your tailnet; pick one on the phone.
- **A demo.** **Try the demo** on the phone shows made-up sessions, with no computer or server.

## How it works

The desktop app finds your coding sessions (through the omp extension and Claude Code plugin it installs) and your terminal windows (through each terminal's own API) and passes them to your phone through the PocketTerm server built into the desktop app.

| | |
| --- | --- |
| Who runs the server | This computer (built into the desktop app, listening on 127.0.0.1 only) |
| Phone reaches it over | [Tailscale](https://tailscale.com) (`tailscale serve`), same account on computer and phone |
| Cost | Free (Tailscale Personal plan) |
| More computers | **Settings → Account → Add a computer…** on the first one; paste the link into **Join another computer's PocketTerm…** on the new one |
| Contents (sessions, prompts, images, files, notification text) | End-to-end encrypted |
| Who can see metadata (device list, computer names, push tokens, when devices talk) | Only you; Tailscale sees device names and IPs |
| Reachable from the internet | No, only your own Tailscale devices |

Your sessions and the server run on the computer, so it has to be awake, with PocketTerm running and **Terminal from phone** on. While that switch is on, PocketTerm keeps the computer from idle sleep. Pushes go out only when nobody has touched the computer for 60 seconds.

Interactive diagrams of the setup and of pairing: [docs/how-it-works.html](docs/how-it-works.html).

## Security and privacy

- **End-to-end encryption.** Each computer makes its own 256-bit key. It reaches a phone only inside that computer's QR code, scanned with the in-app scanner, and never goes to any server. Sessions, screens, keystrokes, prompts, images, files and notification text are sealed with it (AES-256-GCM). Every live message carries a timestamp, a random id and a sequence number, so a recorded message can't be replayed.
- **Your server.** It runs on your computer; nothing is shared between owners. It stores your device list (a SHA-256 of each device token), your computers' names, pairing codes for 10 minutes and your phones' push tokens. Images and files wait there sealed until the computer fetches them, at most an hour. Everything else passes through as ciphertext and isn't kept.
- **Push relay (opt-in).** Notifications pass through PocketTerm's push relay at `push.danyzmaj.com`, a small service Danijel Lovric runs on his own server in Croatia, in the EU. It can't read them: your computer encrypts each one so that only your phone can open it. The relay hands it to Apple or Google to deliver. It and they see an encrypted message, a push token and a time, never which computer or session it is about. The relay keeps nothing.
- **iPhone Lock Screen.** Apple delivers Live Activity updates unencrypted, so a followed session's state (working, needs you, finished) is visible to Apple, the relay and your server. It never carries text, names, folders or ids.
- **Tailscale** sees device metadata: which of your devices connect and when, not what they send. The server listens only on 127.0.0.1 and is published only to your tailnet.
- **Error reports.** The iPhone and Android apps from TestFlight and Google Play report crashes and unexpected errors to the publisher's self-hosted [GlitchTip](https://glitchtip.com) (`glitchtip.danyzmaj.com`): the error's type, its message with URLs, addresses, host names and emails cut out, the stack, the app version, and the phone's model and OS version. Never terminal contents, prompts, sessions, names, folders, keys or your server's address, and no trail of what happened before. The desktop app and its built-in server report nothing unless you set `POCKETTERM_SENTRY_DSN` to your own Sentry or GlitchTip ([how](docs/SELF_HOSTING.md#error-reports)); phone apps built from source report nothing.
- **Usage statistics (opt-in).** Off by default. If you turn on **Settings → Share anonymous usage statistics** in the TestFlight or Google Play app, it sends the publisher's self-hosted [Umami](https://umami.is) (`umami.danyzmaj.com`, in the EU) which screens you open and a fixed list of events with only yes/no or category values (for example that pairing worked, or that a terminal connected over the tailnet), with the app version, phone model, OS, language and screen size, under a random install id kept only on the phone. Umami derives an approximate location from the address and doesn't store the address. Never host names, addresses, commands, prompts, terminal contents, names or keys. Turning it off deletes the install id and anything not yet sent. The desktop app, its server and phone apps built from source send none ([SECURITY.md](SECURITY.md#usage-statistics)).
- **No keys from links.** Only the in-app scanner adds a key; a link opened from outside the app never can.
- **Reset key.** **Settings → Phone → Reset key** makes a new key: a lost phone can no longer read your sessions, and your other phones scan again. **Settings → Account** lists the phones signed in to your server; **Sign out…** next to a lost one ends its sign-in, so it can no longer reach your server or get notifications.

Full model: [SECURITY.md](SECURITY.md). What the publisher collects: the [privacy policy](https://www.danyzmaj.com/pocketterm/privacy/).

## Requirements

| Device | Requires |
| --- | --- |
| Mac | macOS 13 or later |
| Windows PC | Windows 10 (1809 or later) or 11, x64 |
| iPhone | iOS 17 or later |
| Android | Android 8.0 or later |

**Coding agents:** [omp](https://github.com/can1357/oh-my-pi) and [Claude Code](https://github.com/anthropics/claude-code) 2.1.287 or later. Any other program in a supported terminal shows as a live screen.

**Terminals:**

| Terminal | Platform | Notes |
| --- | --- | --- |
| kitty | macOS | One click in **Settings → Terminals → Set up**, then restart kitty |
| iTerm2 | macOS | Needs macOS Automation permission. Screens show without colors |
| Ghostty 1.3 or later, with tmux | macOS | Needs macOS Automation permission. Without tmux, sessions show without a screen and answers happen on the computer |
| WezTerm 20230326 or later | macOS, Windows | The only supported terminal on Windows; PocketTerm offers to install it |
| tmux | macOS | Inside any of the above |

**Tailscale** on the computer and the phone, signed in to the same account: the free Personal plan is enough. Sign in with a personal Google, Apple, GitHub or Microsoft account; a work email domain may start a business trial instead.

## Getting started

1. **Install.**

   | Device | Get it |
   | --- | --- |
   | Mac | [PocketTerm-1.0.0.dmg](https://github.com/danyzmaj-apps/pocketterm/releases/download/v1.0.0/PocketTerm-1.0.0.dmg): notarized, updates itself |
   | Windows | [PocketTerm-1.0.0-setup.exe](https://github.com/danyzmaj-apps/pocketterm/releases/download/v1.0.0/PocketTerm-1.0.0-setup.exe): per-user install. Not code-signed yet: on the SmartScreen warning choose **More info → Run anyway** |
   | iPhone | TestFlight, for invited testers |
   | Android | Google Play internal testing, for invited testers |

   Without an invitation, [build the phone app from source](docs/BUILDING.md).

2. **Set up the server.** Open PocketTerm on the computer. The wizard checks Tailscale (installed, signed in, HTTPS on) and starts the built-in server. It shows every command before it runs anything. For a second computer, choose **Join another computer's PocketTerm…** and paste the link from **Settings → Account → Add a computer…** on the first.
3. **Get the computer ready.** The checklist offers to install PocketTerm into omp and Claude Code (one click each), fixes up your terminals and offers your project folders.
4. **Scan the code.** In the phone app, tap **Scan the code from your computer** and scan the QR code the checklist shows (later: **Settings → Phone → Add a phone…**). The code is single-use for sign-in, expires in 10 minutes and carries the computer's key: show it only to your own phone. With several computers, scan each one's code once.

<p align="center">
  <img src="docs/images/mac-setup.png" width="45%" align="top" alt="Setup: Tailscale checklist and Start">
  <img src="docs/images/get-ready.png" width="45%" align="top" alt="Get this computer ready: coding agents, terminals, project folders, your phone">
</p>

On first launch the phone offers a short tour of what you can tap. Problems: [Troubleshooting](docs/SELF_HOSTING.md#troubleshooting).

## Your server

The server is yours: it runs inside the desktop app on your computer. [docs/SELF_HOSTING.md](docs/SELF_HOSTING.md) covers the wizard step by step, adding computers and phones, updating, running your own push relay and removing everything. Coming from an earlier version: [moving to the built-in server](docs/SELF_HOSTING.md#moving-from-supabase-or-your-own-server). For the server on its own: [the PocketTerm server](apps/pocketterm-server/README.md).

## Development

Native apps, one per platform, sharing a protocol core per language and talking to the Dart server.

| Path | What |
| --- | --- |
| [`apps/pocketterm-desktop/macos`](apps/pocketterm-desktop/macos) | Mac app: Swift, SwiftUI on AppKit, menu-bar item, Sparkle |
| [`apps/pocketterm-desktop/windows`](apps/pocketterm-desktop/windows) | Windows app: C#, .NET 8, WinUI 3, tray item, Inno Setup installer |
| [`apps/pocketterm-mobile/ios`](apps/pocketterm-mobile/ios) | iPhone app: Swift, SwiftUI, Live Activity and push extension |
| [`apps/pocketterm-mobile/android`](apps/pocketterm-mobile/android) | Android app: Kotlin, Jetpack Compose, Material 3; its protocol core in `:core` |
| [`packages/PocketTermKit`](packages/PocketTermKit) | Swift package for the Mac and iPhone apps: the protocol core, the Mac's terminal hosts and desktop services |
| [`apps/pocketterm-desktop`](apps/pocketterm-desktop) | What both desktop apps bundle: the omp extension and Claude Code plugin ([`integrations/`](apps/pocketterm-desktop/integrations)), the icons |
| [`packages/pocketterm_server`](packages/pocketterm_server) | The server (Dart): HTTP and WebSocket API ([PROTOCOL.md](packages/pocketterm_server/PROTOCOL.md)), storage, relay client; bundled into the desktop apps as a sidecar binary |
| [`apps/pocketterm-server`](apps/pocketterm-server) | Server command the desktop apps run as a sidecar |
| [`apps/pocketterm-relay`](apps/pocketterm-relay) | Push relay (Deno) to APNs and FCM |
| [`tool/vectors`](tool/vectors) | The frozen wire vectors every core's tests check against |
| [`tool/e2e`](tool/e2e), [`tool/smoke`](tool/smoke) | End-to-end harness; installed-app smoke |
| [`docs`](docs) | [Architecture](docs/ARCHITECTURE.md), [building](docs/BUILDING.md), [testing](docs/TESTING.md), [releasing](docs/RELEASING.md), [self-hosting](docs/SELF_HOSTING.md) |

```sh
fvm install && fvm dart pub get                     # repo root: Dart for the server and the harness

(cd packages/PocketTermKit && swift test)
(cd apps/pocketterm-desktop/macos && xcodegen generate && xcodebuild -scheme PocketTerm build test)
(cd apps/pocketterm-mobile/ios && xcodegen generate && open PocketTerm.xcodeproj)
(cd apps/pocketterm-mobile/android && ./gradlew :core:test :app:testDebugUnitTest :app:installDebug)   # JDK 17
dotnet test apps/pocketterm-desktop/windows/PocketTerm.Libraries.slnf    # the whole app builds on Windows
# packages/pocketterm_server
fvm dart format -l 120 lib test && fvm dart analyze --fatal-infos && fvm dart test
# apps/pocketterm-relay
deno fmt --check && deno check main.ts tests/*.ts && deno task test
```

End to end on a Mac (a server, the desktop app, kitty, Ghostty, WezTerm and iTerm2, the phone in the iOS Simulator or an Android emulator; results in `build/e2e/`). `--server` picks a local server (the default) or the built-in one over Tailscale. Run only what covers your change and the features around it; how to pick and what each covers: [docs/TESTING.md](docs/TESTING.md#what-to-run-for-a-change).

```sh
tool/e2e/run.sh --terminal kitty --phone-only fresh,pair-accept,theme   # e.g. a change to the phone's theme picker
```

Contributions: [CONTRIBUTING.md](CONTRIBUTING.md). Changes per version: [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE) © 2026 Danijel Lovric
