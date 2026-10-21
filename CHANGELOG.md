# Changelog

User-visible changes to PocketTerm. Each release says whether servers need `apps/pocketterm-desktop/tool/setup-backend.sh` again and whether the push relay must be redeployed.

## 0.1.0

The first release: your computer's omp and Claude Code sessions on your phone, through a Supabase server you own.

**Servers:** a server set up with an earlier 0.1.0 build needs `apps/pocketterm-desktop/tool/setup-backend.sh` again ([Updating](docs/SELF_HOSTING.md#updating)) for the new `pair` function: its "That code doesn't work" message names **Settings → Add a phone…**, and it keeps used phone codes so the computer keeps knowing a phone signed in. A new server needs nothing extra. The push relay needs no redeploy.

### Desktop app (macOS and Windows)

- **Runs in the background:** in the menu bar on the Mac, in the tray on Windows. Closing the window keeps it running; **Quit PocketTerm** is in **Settings → Account**.
- **Setup wizard.** Creates your own Supabase server, or connects one you already have. Step 1 explains why the Supabase token has to cover the whole organization, what PocketTerm does with it, that it's never saved, and how to wall it off in an organization of its own; the last step reminds you to delete it. Step 3 warns, in amber, to untick GitHub's "Allow wildcard matching", and **Set up my server** stays off until you confirm you did. Sign-in is with GitHub.
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
- **Screen only to conversation.** An omp or Claude Code window that doesn't report as a conversation is badged **Screen only**, with the reason the computer found: PocketTerm isn't installed in that agent, it's out of date, Claude Code has mods turned off, or the session was opened before PocketTerm was installed. Where it can, its screen page offers **Switch to conversation**: in omp, PocketTerm quits omp in that window and runs `omp -c`, so the same conversation comes back (if omp was working, the session page offers **Continue** afterwards); in Claude Code it types `/reload-plugins` and nothing restarts.
- **Ending a session.** Swipe a row left to reveal **End session** (**Close window** for a plain window); the close button on a session or screen asks in place.
- **New session.** Start your agent or a shell in one of your projects without taking the computer's focus; **New project…** makes the folder first.
- **First-use tips.** The first time a control is on screen, it's spotlit with a short tip: the switch from a screen-only session to a conversation first, then folding projects, swiping a row, sorting, the +, and on a conversation `/` commands, Queue, following and Screen. Tap the control or **Got it**; each shows once on this phone. **Show tips again** in the account sheet brings them back.
- **The list runs under the home indicator**, and its last row still scrolls clear of the +.
- **Pushes** when a run finishes or the agent needs you, encrypted for your phone and sent through the publisher's relay. A Live Activity on iPhone and an ongoing notification on Android for each session you follow. Pushes say which computer a session is on, so a tap opens it there.

### Terminals and coding agents

- **Coding agents:** omp and Claude Code (2.1.287 or later).
- **Terminals:** kitty, tmux, WezTerm, iTerm2, Terminal and Ghostty on the Mac; WezTerm on Windows.

### Backend

- A minimal schema (sign-up rules, pairing and reviewer codes, the terminal channel and image bucket, push registrations, the computers list) and two functions, `pair` and `push`. Give PocketTerm a Supabase project of its own ([docs/SELF_HOSTING.md](docs/SELF_HOSTING.md)).
