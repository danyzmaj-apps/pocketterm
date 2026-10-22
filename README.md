<div align="center">

<img src="docs/images/icon.png" width="112" alt="PocketTerm icon">

# PocketTerm

**Control the coding agents running on your computer from your phone.**

[![CI](https://github.com/danyzmaj-apps/pocketterm/actions/workflows/ci.yml/badge.svg)](https://github.com/danyzmaj-apps/pocketterm/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/danyzmaj-apps/pocketterm?label=release)](https://github.com/danyzmaj-apps/pocketterm/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platforms](https://img.shields.io/badge/platforms-macOS%20%C2%B7%20Windows%20%C2%B7%20iOS%20%C2%B7%20Android-555)

<br>

<img src="docs/images/phone-terminal.png" width="30%" alt="Phone: sessions grouped by project, then the other terminal windows">
&nbsp;
<img src="docs/images/phone-session.png" width="30%" alt="Phone: a coding session as a conversation">
&nbsp;
<img src="docs/images/phone-switch.png" width="30%" alt="Phone: switching a screen-only omp window to the conversation view">

</div>

---

PocketTerm is a desktop app (macOS menu bar, Windows tray) and a phone app (iPhone, Android). Leave [omp](https://github.com/can1357/oh-my-pi) or [Claude Code](https://github.com/anthropics/claude-code) working in a terminal, walk away, and keep driving it from your phone. The phone reaches your computer through a [Supabase](https://supabase.com) project that you own; there is no PocketTerm cloud.

## What it does

- **Your sessions, by project.** omp and Claude Code sessions grouped by project, then every other terminal window. Sort projects by name or recent activity, tap a project's heading to fold it, long-press it for a new session there or to fold the others.
- **Conversations.** Each session reads as a conversation: streamed Markdown answers, tool calls as cards. Prompt (with images), steer or queue, stop a run, and type `/` for slash commands.
- **Screens.** Every other terminal window is a live screen you can type and press keys in.
- **Approvals and questions.** Answer the agent's questions, approve tool calls and review plans with a tap.
- **Pushes.** A notification when a run finishes or the agent needs you. A Live Activity on iPhone and an ongoing notification on Android for the sessions you follow.
- **Switch to conversation.** A session opened before PocketTerm was installed shows only its screen. **Switch to conversation** restarts omp on the same conversation (`omp -c`); if it was working, **Restart and continue** has it carry on and **Just restart** leaves it stopped. In Claude Code it reloads the plugins and nothing restarts.
- **New and ended sessions.** Start your agent or a shell in any project without taking the computer's focus. Swipe a row left to **End session** (or **Close window**).
- **Tips on first use.** The first time a control shows up, a spotlight says what it does, once per phone; **Show tips again** in the account sheet brings them back.
- **Several computers.** One account, several Macs and Windows PCs; pick one on the phone.

## How it works

Interactive diagrams of both setups: [docs/how-it-works.html](docs/how-it-works.html)

```mermaid
flowchart LR
  subgraph computer ["Your computer"]
    agents["omp · Claude Code<br/>with PocketTerm's add-on"]
    terms["Terminal windows<br/>kitty · WezTerm · tmux · …"]
    desktop["PocketTerm desktop app"]
    agents <-->|"local API"| desktop
    desktop <-->|"read, type, keys"| terms
  end
  subgraph yours ["Your Supabase project"]
    rt[("Realtime channel<br/>per computer")]
    fn["pair · push"]
  end
  phone["PocketTerm phone app"]
  relay["Publisher's push relay<br/>ciphertext only"]
  desktop <-->|"sessions, screens, prompts<br/>end-to-end encrypted"| rt
  rt <--> phone
  desktop -->|"run finished, needs you"| fn
  fn -->|"encrypted push"| relay
  relay -->|"APNs / FCM"| phone
```

- **The desktop app** finds your coding sessions (the omp extension and Claude Code plugin it installs report to it over `127.0.0.1`) and your terminal windows (through each terminal's own API), and relays them to your phone.
- **Your Supabase project** is the only server: it signs you in, pairs your phones, carries a private Realtime channel per computer and sends pushes. It relays your sessions, images and notifications only as ciphertext. The free plan is enough for one person. The setup wizard creates it for you.
- **End-to-end encryption.** Each computer has its own key, which reaches a phone only in that computer's QR code. Sessions, screens, prompts, images and push text are sealed with it on one end and opened on the other.
- **Pushes** are sealed by the computer and reach Apple or Google through the publisher's relay, which can't read them.

The sessions live on the computer: it has to be awake, with PocketTerm running and **Terminal from phone** on. While that switch is on, PocketTerm keeps the computer from idle sleep; a closed lid (without an external display) or a shut-down computer ends it. A push goes out only when nobody has touched the computer for 60 seconds.

## Supported platforms

| Device | Requires |
| --- | --- |
| Mac | macOS 13 or later |
| Windows PC | Windows 10 (1809 or later) or 11, x64 |
| iPhone | iOS 17 or later |
| Android | Android 8.0 or later |

**Coding agents:** [omp](https://github.com/can1357/oh-my-pi) and [Claude Code](https://github.com/anthropics/claude-code) 2.1.287 or later. Any other program in a supported terminal shows as a live screen.

**Terminals:** what the phone can do depends on the terminal.

| Terminal | Platform | Sessions and screens | Colors | Keys and answers from the phone |
| --- | --- | --- | --- | --- |
| kitty | macOS | Yes | Yes | Yes |
| WezTerm | macOS, Windows | Yes | Yes | Yes |
| tmux (in any terminal) | macOS | Yes | Yes | Yes |
| Ghostty | macOS | Sessions, no screen | No | Keys; answer on the computer |

- **macOS:** with tmux installed (`brew install tmux`), sessions the phone starts in Ghostty run inside tmux and get full control. For Ghostty windows you open yourself, **Settings → Terminals → Start new windows in tmux** does the same (it adds a marked `command =` line to your Ghostty config; **Remove** takes it out). kitty needs one click in **Settings → Terminals → Set up** (then restart kitty); Ghostty needs macOS's Automation permission (**Allow…**).
- **Windows:** only [WezTerm](https://wezterm.org) windows are listed: it is the only Windows terminal another program can read and type into. The setup checklist and **Settings → Terminals** install it for you (or run `winget install --id wez.wezterm --exact`). Windows Terminal, conhost and WSL windows don't show up. Images sent from the phone must be PNG or JPEG (the phone apps send JPEG).

## Getting started

### 1. Install

| Device | Get it |
| --- | --- |
| Mac | [PocketTerm-0.1.0.dmg](https://github.com/danyzmaj-apps/pocketterm/releases/download/v0.1.0/PocketTerm-0.1.0.dmg). Notarized; updates itself. |
| Windows | [PocketTerm-0.1.0-setup.exe](https://github.com/danyzmaj-apps/pocketterm/releases/download/v0.1.0/PocketTerm-0.1.0-setup.exe). Installs for your user only. Not code-signed yet, so SmartScreen warns: **More info → Run anyway**. Settings shows a link when a new version is out. |
| iPhone | TestFlight, for invited testers only. |
| Android | Google Play internal testing, for invited testers only. |

All downloads are on the [releases page](https://github.com/danyzmaj-apps/pocketterm/releases/latest). The phone apps aren't on the App Store or Google Play; without an invitation, [build the phone app from source](docs/BUILDING.md).

### 2. Set up your server

Open PocketTerm on your computer and click **Set up my server**. The wizard takes about five minutes and needs a free [Supabase](https://supabase.com) account (it hosts your server) and a [GitHub](https://github.com) account (you sign in with it). Already have a server? Choose **I already have one: connect it**. Prefer a script? See [Self-hosting](#self-hosting).

### 3. Get the computer ready

After you sign in with GitHub, **Get this computer ready** installs PocketTerm into omp and Claude Code, then lists your terminals with their one-click fixes, offers your usual project folders and shows the code for your phone. Each step checks itself off; **Done** opens Settings. Sessions that were already open show only their screen until they pick PocketTerm up: tap **Switch to conversation** on the phone, or do it on the computer (`/reload-plugins` in Claude Code; quit omp and run `omp -c`).

### 4. Pair your phone

In the phone app, tap **Scan the code from your computer** and scan the QR code the checklist shows (later: **Add a phone…** in Settings). Its sign-in works once, for 10 minutes. One sign-in covers every computer on your account, but each computer's sessions are encrypted with that computer's own key, so scan each computer's code once (the phone shows a computer it can't read yet as locked, with a **Scan** button).

<p align="center">
  <img src="docs/images/wizard-token.png" width="32%" align="top" alt="Setup wizard: Supabase access token">
  <img src="docs/images/get-ready.png" width="24%" align="top" alt="Get this computer ready: coding agents, terminals, project folders, your phone">
  <img src="docs/images/phone-setup.png" width="24%" align="top" alt="Phone: sign in with the computer's code">
</p>

### 5. Settings

After the checklist, the window is Settings. At the top, a status bar says **All set**, or how many things need attention: **Show** lists each with the button that fixes it, a dot marks the tab it's on, and **Open setup checklist** brings the checklist back. On Windows, a bar below it links to a new version when one is out. Four tabs:

- **Phone:** the **Terminal from phone** switch, your phones with **Add a phone…**, and your project folders.
- **Coding agents:** a card per agent with **Install** or **Update**, sessions opened before PocketTerm with the command that picks it up, and **Make default** (what a new session from the phone starts).
- **Terminals:** where new sessions open (**Auto** picks the terminal app you used last), and a card per terminal with how it stands and its one-click fix.
- **Account:** who you're signed in as, your server, **Launch at login**, **Delete account**, the version and **Quit PocketTerm**.

<p align="center">
  <img src="docs/images/mac-settings-phone.png" width="49%" align="top" alt="Settings, Phone: Terminal from phone, your phones, project folders">
  <img src="docs/images/mac-settings-agents.png" width="49%" align="top" alt="Settings, Coding agents: omp with two sessions to reopen, Claude Code out of date">
</p>

Closing the window keeps PocketTerm running in the menu bar (Mac) or tray (Windows). Problems? See [Troubleshooting](docs/SELF_HOSTING.md#troubleshooting).

## Self-hosting

Every user runs their own server; nothing is shared between users. [docs/SELF_HOSTING.md](docs/SELF_HOSTING.md) covers the wizard in detail, setting up a server by script (`apps/pocketterm-desktop/tool/setup-backend.sh`), sharing a server, updating it, running your own push relay and troubleshooting.

## Security and privacy

- **Your server.** Sign-in, pairing, the terminal channel and push registrations live in your Supabase project, behind row-level security. The apps hold only its publishable key. Sign-up is private: after the first account, nobody gets in unless you allow their email.
- **End-to-end encrypted.** Sessions, screens, prompts, images and notification text are sealed (AES-256-GCM) with a key per computer that never goes to a server: a phone gets it only by scanning that computer's QR code, so treat the QR as a secret. Your server sees who you are, your computers, push tokens and when messages go, never what they say. **Reset key** (Settings → Phone) locks out every phone, a lost one included; the others scan again.
- **Nothing stored.** Sessions and screens travel over a Realtime channel per computer that only your account can join; nothing on it is stored. Images you send pass sealed through a private storage bucket in your project and are deleted once used.
- **Encrypted push.** The relay sees only ciphertext and stores nothing. Live Activity updates can't be encrypted, so they carry only a session's state, never text.
- **Local only.** The desktop app's API listens on `127.0.0.1` behind a random token.
- **Delete account** (Settings → Account on the computer, or the account sheet on the phone) removes everything.

Details are in [SECURITY.md](SECURITY.md) and the [privacy policy](https://www.danyzmaj.com/pocketterm/privacy/). Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md#reporting).

## Development

PocketTerm is one Dart pub workspace, with Flutter pinned in `.fvmrc`:

| Path | What |
| --- | --- |
| [`apps/pocketterm-desktop`](apps/pocketterm-desktop) | The desktop app for macOS and Windows, the backend it deploys (`supabase/`), the omp extension and Claude Code plugin (`integrations/`), and the setup and release scripts (`tool/`) |
| [`apps/pocketterm-mobile`](apps/pocketterm-mobile) | The phone app for iPhone and Android |
| [`packages/pocketterm_core`](packages/pocketterm_core) | Code both apps share: sign-in, the terminal protocol, the terminal hosts |
| [`config`](config) | The Xcode signing identity (team, bundle id, App Group) |
| [`docs`](docs) | Architecture, building, releasing, self-hosting |

```sh
# at the repo root: Flutter and the whole workspace's packages
fvm install && fvm flutter pub get

# in apps/pocketterm-desktop
fvm flutter run -d macos        # or -d windows on a Windows PC

# in apps/pocketterm-mobile
fvm flutter run -d <device>

# in each of packages/pocketterm_core, apps/pocketterm-desktop, apps/pocketterm-mobile
fvm dart format -l 120 lib test && fvm flutter analyze && fvm flutter test
```

| Doc | What |
| --- | --- |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the pieces fit: layout, backend, terminals, local API |
| [BUILDING.md](docs/BUILDING.md) | Building every app with your own signing identity, and a local backend |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Every check CI runs, and what a pull request needs |
| [RELEASING.md](docs/RELEASING.md) | How releases are made (maintainer notes) |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each version |

## License

[MIT](LICENSE) © 2026 Danijel Lovric
