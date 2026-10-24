# Changelog

What each PocketTerm release brings.

## 0.1.1

Update the desktop app and the phone app together: the queue lives on the computer. Servers and the push relay need no update.

### Phone app (iPhone and Android)

- **A sent prompt shows at once.** Your message appears at the bottom of the conversation as you tap Send, dimmed with **Sending…** until the computer takes it, and gives way to the agent's own copy when that comes. One that didn't go says why, with **Not sent. Tap to retry**. Slash commands show nothing: their picker or screen answers them.
- **A queue you can change.** A prompt you queue while the agent works (with **Queue** on in omp, any prompt to Claude Code) waits on your computer, listed above the field as **Queued · N**: its **⋮** menu edits or deletes it (and in omp **Send now** steers the run with it), its handle drags it to another place, and a swipe left deletes it. Each run end sends the next one; the session shows as working in between, with no "finished" push. **Stop** (or Esc at the computer) holds the queue as **Queue paused** until you tap **Resume**; **Pause** holds it too. A queue takes up to 20 prompts and keeps them when the agent restarts in the same window.
- **Notifications come back by themselves.** A push registration that didn't reach the server goes again as soon as the server answers or the account sheet opens, which shows **Registering…** meanwhile.

## 0.1.0

The first release of PocketTerm: the omp and Claude Code sessions on your computer, on your phone, end-to-end encrypted, through a PocketTerm server of your own: on the computer, on a VPS or on a Supabase project.

### Desktop app (macOS and Windows)

- **Runs in the background:** in the menu bar on the Mac, in the tray on Windows. Closing the window keeps it running; **Quit PocketTerm** is in **Settings → Account**.
- **Setup wizard with three choices.** **On this computer** runs the PocketTerm server inside the app and reaches your phone through Tailscale; **On my own server** connects to a server on a VPS, either one you already have (paste its setup link) or a new one (the wizard shows the commands and checks each step); **Supabase** puts the server on a free Supabase project. PocketTerm never runs a command without asking: buttons that install Tailscale or tmux show the exact command and run it only after you press **Run**.
- **Supabase.** With a Supabase personal access token, the wizard creates a free project named PocketTerm in the organization and region you pick (or updates the one that has PocketTerm on it), sets up its database, live channel and server function, and signs the computer in. Other computers join with a setup link from **Settings → Account → Add a computer…**, no token needed. Phones scan the computer's code as with the other choices. Free projects pause after about a week unused.
- **Get this computer ready.** After the first sign-in, a checklist installs PocketTerm into every coding agent it finds (omp, Claude Code), lists sessions that were already open with the command that picks PocketTerm up in each (`omp -c` in omp, `/reload-plugins` in Claude Code), shows your terminals with their one-click fixes, offers your usual project folders and shows the QR code for your phone. Each step checks itself off.
- **Settings: a status bar over four tabs.** The status bar says **All set**, or how many things need attention; **Show** lists them with the button that fixes each, and **Open setup checklist** brings the checklist back. **Phone**: Terminal from phone, **Add a phone…**, **Reset key**, project folders. **Coding agents**: **Install** or **Update** per agent, sessions to reopen, **Make default**. **Terminals**: where new sessions open, and each terminal with its fix. **Account**: your server and the phones signed in to it, each with **Sign out…** for a lost one, Tailscale when this computer runs the server, **Add a computer…**, **Launch at login**, **How your data is protected**, **Sign out**, **Erase this server's data** on a computer that runs the server, the version and **Quit PocketTerm**.
- **Several computers.** Every computer signed in to your server shows up on the phone, which picks one. **Add a computer…** on a computer that runs the server, or on one signed in to a Supabase project, gives the others a setup link.
- **Launch at login is off** until you turn it on in **Settings → Account**. When macOS holds PocketTerm back, the switch says to allow it in System Settings → General → Login Items.
- **Opened from Finder or the Dock**, PocketTerm works as from a terminal: it finds Claude Code installed with npm, Tailscale's Mac app and tmux, and reads folder and window names that aren't in ASCII.
- **A locked or missing Keychain** stops a sign-in with a plain message and **Try again**.
- **Keeps the computer awake** while **Terminal from phone** is on, and pushes to your phone only when nobody has touched the computer for 60 seconds.
- **Mac:** a notarized DMG that updates itself (Sparkle). kitty is set up with one click (**Set up**), Ghostty asks for macOS's Automation permission (**Allow…**), and **Install tmux** runs `brew install tmux` once you confirm.
- **Windows:** a per-user installer (`PocketTerm-0.1.0-setup.exe`, not code-signed), and a link in Settings when a newer version is out. **Install WezTerm** downloads WezTerm's own installer, checks it against WezTerm's published checksum and opens it.

### Phone app (iPhone and Android)

- **Connects by scanning a code.** **Scan the code from your computer** (or paste it) signs the phone in to your server and gives it that computer's key. The sign-in works once, for 10 minutes. Scan each computer's code once; a computer the phone can't read yet shows as locked, with a **Scan** button. Through Tailscale, the phone says to approve it in the Tailscale admin console under **Machines** when Tailscale shows **Awaiting Approval**.
- **Try the demo.** Made-up sessions to look around without a computer. Nothing connects.
- **Your sessions by project.** omp and Claude Code sessions grouped by project, then every other terminal window. Sort projects by name or recent activity, tap a project's heading to fold it, long-press it for a new session there or to fold the others.
- **Sessions as conversations.** Streamed Markdown answers, tool calls as cards, prompts with images and files, steer, queue and stop, questions, approvals, plan reviews and `/` slash commands.
- **Images and files with a prompt.** Up to 10 per message, from Photos, the clipboard or **Choose from Files** (the system's file picker: Files on iPhone, the document picker on Android), each file up to 20 MB. Images are scaled down to 2048 px; other files go as they are. The computer saves each file under its own name in a folder of its own in its temp folder (`pocketterm-files`, removed after a day) and names it in the prompt as `@path`, as you would at the computer: omp reads it in (a prompt that steers a run names it for the agent to open), Claude Code opens it without asking.
- **Screens.** Every other terminal window is a live screen you can type and press keys in.
- **Switch to conversation.** A session opened before PocketTerm was installed in its agent shows only its screen. **Switch to conversation** restarts omp on the same conversation (`omp -c`); if it was working, **Restart and continue** has it carry on and **Just restart** leaves it stopped. In Claude Code it types `/reload-plugins` and nothing restarts.
- **New and ended sessions.** Start your agent or a shell in a project without taking the computer's focus; **New project…** makes the folder first. Swipe a row left to **End session** (or **Close window**).
- **Notifications, if you turn them on.** A push when a run finishes or the agent needs you, and a Live Activity on iPhone (an ongoing notification on Android) for the sessions you follow. The phone explains who sees what before it asks; **Account → Notifications** changes it later. When notifications are off in the phone's Settings it says so, with a way there; when Apple or Google gives the phone no notification address, it says to check the internet connection and try again.
- **First-use tips, if you want them.** The first time you reach your sessions (or the demo), the phone asks **New here?**: **Show me** starts short tips that point out what you can tap, one at a time and each once; **No thanks** skips them. It asks once per phone; **Show tips again** in the account sheet brings the tips back.
- **Leave this server** in the account sheet signs the phone out and removes its keys.

### Your server

- **The PocketTerm server** pairs your phones, keeps the list of your computers, passes the live channel between a computer and its phones, holds images and files on their way from phone to computer and sends pushes. One process, no database: everything it keeps is in one data folder.
- **On this computer:** built into the desktop app, listening on 127.0.0.1 and published to your own devices with `tailscale serve` at `https://<this computer>.<tailnet>.ts.net`. It starts with the app and updates with it.
- **On your own server:** a Docker image (`ghcr.io/danyzmaj-apps/pocketterm-server`, amd64 and arm64) with a compose file that puts Caddy in front for HTTPS from Let's Encrypt. Works with a domain of your own or an sslip.io name for the server's IP address, and behind nginx, Traefik or Cloudflare. `pocketterm-server setup-link` prints the link that signs a computer in; `setup-link --new` replaces it. `pocketterm-server health` exits 0 when the server answers, for container healthchecks.
- **On Supabase:** an Edge Function named `pocketterm` that answers the same requests as the PocketTerm server, a database, a private Storage bucket for sealed images and files, and Supabase Realtime for the live channel, with a 10-minute token per device. The desktop app sets it up and updates it.
- **Live Activities stay fresh while the computer checks in.** An iPhone's Lock Screen shows "No word from the computer" 3 minutes after its last update; every server (on the computer, on a VPS, on Supabase) now sends a followed session's last state again, quietly, about every 2 minutes while its computer checks in, so an idle session no longer looks cut off. A computer that stops checking in still has its Live Activities ended after 3 minutes. To do that the server keeps each iPhone Live Activity's last state (working, needs you, finished, and since when) until it ends.

### Security and privacy

- **End-to-end encrypted.** Each computer makes its own key and keeps it in the Keychain on a Mac, or in a file encrypted for your Windows user (DPAPI) on Windows. It reaches a phone only in that computer's QR code. Sessions, screens, prompts, images, files (their names too) and notification text are sealed with it (AES-256-GCM), so your server only passes on ciphertext. Live messages carry a timestamp and are dropped when more than 5 minutes off, and the computer drops a message from a phone that it has seen already.
- **Reset key** (Settings → Phone) makes a new key after a lost phone; every phone you keep scans the computer's code again.
- **Pushes** are sealed by the computer and go from your server to the push relay at `push.danyzmaj.com`, run by Danijel Lovric in Germany, which passes them to Apple or Google. Every request to the relay is sealed to the relay's own key (X25519, AES-256-GCM). The relay stores nothing. A notification names its computer and session only by tags made with that computer's key, so the push relay, Apple and Google see an encrypted message, a push token and when it was sent. A Lock Screen update on iPhone carries only its state (working, needs you, finished), never text; which session it shows stays on the phone. Android's followed sessions name theirs the same way.
- **Supabase** (the company, in the region you pick) holds the server's metadata (device list, computer names, push tokens, timing) and sees connection IP addresses; the function and Realtime pass on ciphertext only. The access token covers the whole Supabase organization; PocketTerm uses it only during setup and never stores it. Who sees what, side by side: [SECURITY.md](SECURITY.md), [docs/SELF_HOSTING.md](docs/SELF_HOSTING.md#supabase).
- **Pairing codes** work once, for 10 minutes; ten wrong codes from one address in 10 minutes are turned away for a while. The server keeps only the SHA-256 of each device's token.
- **Local only:** the desktop app's API for the agents listens on 127.0.0.1 behind a random token.

### Terminals and agents

- **Coding agents:** omp, and Claude Code 2.1.287 or later.
- **Terminals on the Mac:** kitty, WezTerm, tmux in any terminal, and Ghostty 1.3 or later. Ghostty sessions started from the phone run in tmux for full control; **Start new windows in tmux** (Settings → Terminals) does the same for Ghostty windows you open yourself, and each such window is one row on the phone. A line from an earlier PocketTerm in Ghostty's config is brought up to date by itself.
- **Terminals on Windows:** WezTerm 20230326 or later.
