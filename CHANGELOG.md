# Changelog

User-visible changes to PocketTerm. Each release says whether servers need `apps/pocketterm-desktop/tool/setup-backend.sh` again and whether the push relay must be redeployed.

## Unreleased

**End-to-end encryption.** Your server (Supabase) now relays only ciphertext between a computer and its phones: sessions, screens, prompts, images and notification text.

**Servers:** run `apps/pocketterm-desktop/tool/setup-backend.sh` again ([Updating](docs/SELF_HOSTING.md#updating)): `push` forwards notifications the computer sealed, and a migration drops the per-phone push keys. The push relay must be redeployed first (`apps/pocketterm-desktop/tool/deploy-relay.sh`, publisher only); it still serves servers that aren't updated yet. **Phones pair again once:** scan each computer's code (Settings → Add a phone…) on each phone.

- **A key per computer.** Each computer makes its own key and keeps it in the Keychain (Mac) or Credential Manager (Windows). It reaches a phone only in that computer's QR code, which now says it's a secret. Live messages carry a timestamp and are dropped when more than 5 minutes off; the computer drops a phone message it has already seen.
- **Phone: locked computers.** A computer whose code this phone hasn't scanned shows **Scan this computer's code to connect** with a **Scan** button, and nothing from it shows or goes to it. Scanning a code while signed in adds that computer's key without signing in again. The computer picker marks locked computers and has **Scan a computer's code**. Signing out removes the keys.
- **Desktop: Reset key** (Settings → Phone) makes a new key after losing a phone; every phone scans again.
- **Images** from the phone are sealed before upload; the computer opens them.
- **Push text** is sealed by the computer; your server and the relay pass it on unread. A phone without that computer's key shows a plain "PocketTerm" notification. Live Activity updates still carry only a session's state, unencrypted.

## 0.1.0

The first release: your computer's omp and Claude Code sessions on your phone, through a Supabase server you own.

**Servers:** a server set up with an earlier 0.1.0 build needs `apps/pocketterm-desktop/tool/setup-backend.sh` again ([Updating](docs/SELF_HOSTING.md#updating)) for the new `pair` function: its "That code doesn't work" message names **Settings → Add a phone…**, and it keeps used phone codes so the computer keeps knowing a phone signed in. A new server needs nothing extra. The push relay needs no redeploy.

### Desktop app (macOS and Windows)

- **Runs in the background:** in the menu bar on the Mac, in the tray on Windows. Closing the window keeps it running; **Quit PocketTerm** is in **Settings → Account**.
- **Setup wizard.** Creates your own Supabase server, or connects one you already have. Step 1 explains why the Supabase token has to cover the whole organization, what PocketTerm does with it, that it's never saved, and how to wall it off in an organization of its own; the last step reminds you to delete it. Step 3 warns, in amber, to untick GitHub's "Allow wildcard matching", and **Set up my server** stays off until you confirm you did. Sign-in is with GitHub.
- **New Supabase projects.** The wizard's Database step no longer fails with `relation "realtime.messages" does not exist`: Realtime creates that table only once something connects to it, so the wizard connects first and waits until it's there.
- **tmux installed while PocketTerm runs** is found within seconds, without a restart. Before, PocketTerm looked for tmux once at launch, so the phone kept asking for it. With tmux, Ghostty and Terminal show as **Ready** (sessions from your phone run in tmux, with full control), still naming the limit of windows you open in them yourself.
- **Ghostty: Start new windows in tmux** (Settings → Terminals, Mac, with tmux installed). One click adds two marked lines to your Ghostty config (`command = <tmux> new-session \; set-option destroy-unattached on`), so each new Ghostty window or tab runs in a tmux session of its own, which ends when the window closes, and your phone gets full control there too. **Remove** takes out exactly those lines. When your config already sets a `command`, PocketTerm leaves it alone and says so.
- **Get this computer ready.** After the first sign-in on a computer, a checklist instead of Settings: PocketTerm installs itself into every coding agent it finds (omp, Claude Code) and lists sessions that were already open, each with the command that picks PocketTerm up there and a copy button (`/reload-plugins` in Claude Code, nothing restarts; `omp -c` in omp). Then the terminals with their one-click fixes, project folders found in your home folder (one click each), and the QR code for your phone. Each step checks itself off; **Done** goes to Settings.
- **Settings: a status bar over four tabs.** The status bar says **All set**, or how many things need attention; **Show** lists them with the button that fixes each, and a dot marks the tab they're on. **Open setup checklist** brings the checklist back. **Phone**: Terminal from phone, your phones with **Add a phone…**, project folders. **Coding agents**: a card per agent with **Install** or **Update**, the sessions to reopen, and **Make default**. **Terminals**: where new sessions open, and a card per terminal with its fix. **Account**: you, your server, Launch at login, **Delete account**, the version and **Quit PocketTerm**.
- **Reviewer access** (codes for App Store or Play review) is hidden until you press ⌥ Option (Alt on Windows) in Settings.
- **Several computers per account.** Each computer registers itself and shows as Online by the server's clock, so a computer whose clock is off still reads right.
- **Mac:** a notarized DMG that updates itself (Sparkle). kitty is set up with one click (**Set up**); iTerm2, Terminal and Ghostty ask for macOS's Automation permission (**Allow…**); tmux is recommended with a `brew install tmux` line to copy.
- **Windows:** an unsigned per-user installer (`PocketTerm-0.1.0-setup.exe`); Settings shows a link when a newer version is out. **Install WezTerm** downloads WezTerm's own installer from its GitHub release, checks it against WezTerm's published checksum and opens it (or copy the `winget` line). Non-ASCII text in screens, window titles and user folder names works; Claude Code is found as a native `claude.exe` (preferred) or npm's `claude.cmd`, also when `HOME` points somewhere other than your user folder.

### Phone app (iPhone and Android)

- **Pairing.** Scan the code from your computer (or paste it). It works once, for 10 minutes. The welcome screen links to the desktop downloads, and the account sheet to the source on GitHub.
- **Terminal list.** Your computer's omp and Claude Code sessions by project, then its other terminal windows. Projects are sorted by name or by recent activity (re-ranked when you pull to refresh), and sessions keep their order within a project. Tap a project's heading to fold it to one line that still says what needs you; long-press it for a new session there, **Fold all others** or **Unfold all**. With several computers, the title picks which one to show. With none on the account, the screen says why.
- **Sessions as conversations.** Streamed Markdown answers, tool-call cards, prompts with images, steer, queue and stop, questions, approvals, plan reviews and `/` slash commands.
- **Screens.** Other terminal windows are live screens you can type and press keys in.
- **Screen only to conversation.** An omp or Claude Code window that doesn't report as a conversation is badged **Screen only**, with the reason the computer found: PocketTerm isn't installed in that agent, it's out of date, Claude Code has mods turned off, or the session was opened before PocketTerm was installed. Where it can, its screen page offers **Switch to conversation**: in omp, PocketTerm quits omp in that window and runs `omp -c`, so the same conversation comes back; if omp was working, **Restart and continue** prompts `continue` as soon as it's back, and **Just restart** leaves it stopped with a **Continue** button on its session page. In Claude Code it types `/reload-plugins` and nothing restarts.
- **Ending a session.** Swipe a row left to reveal **End session** (**Close window** for a plain window); the close button on a session or screen asks in place.
- **New session.** Start your agent or a shell in one of your projects without taking the computer's focus; **New project…** makes the folder first.
- **First-use tips.** The first time a control is on screen, it's spotlit with a short tip: the switch from a screen-only session to a conversation first, then folding projects, swiping a row, the +, and on a conversation `/` commands, Queue, following and Screen. Tap the control or **Got it**; each shows once on this phone. **Show tips again** in the account sheet brings them back.
- **Taps look like the control they press.** A press highlights a row inside its rounded card, a project heading as a rounded pill, an icon button as a circle; on iPhone it's a soft highlight (the + darkens), on Android a ripple. Sheets have a grab handle.
- **The list runs under the home indicator**, and its last row still scrolls clear of the +.
- **Pushes** when a run finishes or the agent needs you, encrypted for your phone and sent through the publisher's relay. A Live Activity on iPhone and an ongoing notification on Android for each session you follow. Pushes say which computer a session is on, so a tap opens it there.

### Terminals and coding agents

- **Coding agents:** omp and Claude Code (2.1.287 or later).
- **Terminals:** kitty, tmux, WezTerm, iTerm2, Terminal and Ghostty on the Mac; WezTerm on Windows.
- **Ghostty windows that share a folder** now show once, as their sessions. With two coding agents open in Ghostty in the same folder, each session showed twice on the phone: as a conversation and again as a window under Other windows. PocketTerm now tells the windows apart by the title omp gives each one (the session's title, or the folder's name until it has one) and by which windows other sessions already run in, and finds a session's window again once its title arrives. When it still can't tell, it leaves the session unmatched instead of guessing.

### Backend

- A minimal schema (sign-up rules, pairing and reviewer codes, the terminal channel and image bucket, push registrations, the computers list) and two functions, `pair` and `push`. Give PocketTerm a Supabase project of its own ([docs/SELF_HOSTING.md](docs/SELF_HOSTING.md)).
