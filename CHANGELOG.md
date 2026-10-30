# Changelog

What each PocketTerm release brings.

## 0.1.7

Servers and the push relay need no update. To have omp and Claude Code in iTerm2 found as their window, click **Update** for them in PocketTerm on the computer.

### Desktop app

- **iTerm2 works with PocketTerm.** Its tabs and split panes show on the phone with their screens (without colors) and take typing, keys and closing; sessions you start from the phone can open in iTerm2 as a new tab, and **Settings → Terminals** lists it (macOS asks once whether PocketTerm may control iTerm2). omp and Claude Code running in iTerm2 are tied to their window.

### Phone app

- **Voice prompts in Croatian.** The microphone now listens in Croatian as well as English, still recognized on the phone itself. **Auto** (the default) checks what the phone has: Croatian when it comes before English in the phone's languages and the phone can recognize it, otherwise English, so it never stops at a missing language. Pick one yourself in the account sheet's **Voice prompt language**, which shows for each language whether it's **On this phone**, can be downloaded (**Download**), turned on (**Open Settings**: on an iPhone, Dictation in that language) or is **Not supported on this phone** (then it can't be picked). Or tap the language at the top of the voice screen to switch, even while talking: what you've said stays and listening goes on in the other language. On iOS 26 a language Apple's new recognizer lacks falls back to the older one when that has it on the device.

## 0.1.6

Servers and the push relay need no update. To see what a session has cost on the phone, click **Update** for omp and Claude Code in PocketTerm on the computer.

### Desktop app

- **Nothing installs without asking.** **Install** or **Update** for omp or Claude Code, in the checklist or in Settings, and **Install WezTerm** on Windows first explain why it's needed, what it changes and how to take it out, and install only once you confirm.

### Phone app

- **A session's row reads like your agent's status bar.** Under the title, next to how it stands (**Working…**, **Needs you**, **7 h ago**), are its model, how full its context is and what it has cost so far, as omp and Claude Code count it (`Opus 4.5 · 49% · $43.34`); under them a thin bar fills with the context, turning amber past 70% and red past 90%. The first line of the last answer no longer shows there.
- **Done only when you haven't seen it.** A session whose run ends while you're reading its conversation no longer lights its row as done when you go back to the list.
- **Even room around a highlighted row.** A project with one session leaves as much room above and below its row's border as at its sides.
- **Sheets show all of themselves.** A sheet is as tall as what's in it instead of stopping at part of the screen, so its last row (like the account sheet's **PocketTerm is open source** link) is no longer cut off; a sheet too tall for the screen scrolls on under the home indicator.
- **Attached images show while they load.** From the moment the photo picker closes, the composer shows a spinner tile for each image still loading (photos, files or a pasted image), and each turns into its thumbnail as soon as it's ready instead of all of them appearing at once at the end. **Send** and the attach button wait until the last one is in. Photos are now scaled down by the phone as they're picked, so they load faster and go as JPEG instead of a larger PNG.

## 0.1.5

Servers and the push relay need no update. To see a session's error border on the phone, click **Update** for omp and Claude Code in PocketTerm on the computer.

### Desktop app

- **Get this computer ready installs nothing by itself.** Opening it only checks your coding agents; PocketTerm goes into omp or Claude Code when you click its **Install** (or **Update**).
- **The phone hears when a run broke off on an error.** omp and Claude Code now say so when an answer ends in an error no retry got past (not when you stop it), so the phone can show it. The PocketTerm integration in omp and Claude Code needs its **Update** for this; older ones simply never report it.

### Phone app

- **Your words keep up with you.** On iOS 26 the transcript updates after every word instead of at each pause, and a word the phone corrects changes in place instead of fading in again.
- **A star shows it's listening.** The big microphone and the **Stop** button are gone: at the bottom of the voice screen a star of a few thousand specks in your theme's colours gathers itself out of the dark as the screen opens, then breathes and slowly turns, with a faint ring of dust. As you talk your voice rises from its equator toward the poles in spikes, and flares stream off them in the theme's warm colour. It glows on the dark themes, is drawn in ink on Rosé Pine Dawn, and its specks are soft on Mocha, crisp on Tokyo Night and square pixels on Gruvbox. It turns red while a held press is slid away to cancel. Tap it to stop; it bursts into specks that fly into the buttons for what's next, and **Keep talking** flies them back out of the buttons into the star.
- **Keep talking.** After you stop, **Keep talking** sits on its own row above **Insert** and **Send**, side by side; **Cancel** is gone, the close button and dragging the sheet down do that; it listens again and adds the new words after what's there, edits included.
- **Opens straight into its intro.** On iPhone the app icon you tap stays on screen while the app starts, where and as large as the intro begins, in your theme's colours; the phone then ducks into the pocket without a blank screen or a jump in between.
- **Sessions show how they stand by their border.** Like a terminal tab's colour, each session in the list is framed: a light runs round a working one like a snake chasing its tail, one that needs you is outlined in the theme's warning colour, one whose last run broke off on an error in its error colour (it reads **Stopped on an error**), one with its queue paused in grey, and one that finished a run you haven't opened since in green. The small coloured words under the title are quiet now; the border says it. With reduced motion the working border holds still.
- **Rename and colour your rows.** Swipe a session or window left and **Rename** and **Color** sit beside **End session**; a long press offers the same three. A name you give replaces the agent's title in the list, and a colour tints the row (instead of the flash a question brings); **Reset** and **No color** put them back. They stay on this phone, per computer.
- **Sorting is one tap.** The order above the projects switches between **Name** and **Recent activity** when tapped, instead of opening a menu.
- **A question's long answers show whole.** When an agent asks you to choose, an answer too long for one line wraps inside its button instead of being cut off.
- **What you typed waits for you.** Text you've typed into a session but not sent stays there when you go back to the list and when the app is closed, until you send or delete it; each session keeps its own. Attached images and files aren't kept.

## 0.1.4

Servers and the push relay need no update.

### Phone app

- **The whole queue on its own screen.** Tap **Queued · N** above the field and every queued prompt opens over the screen, numbered and whole (a long one opens with **Show more**), with its images and files. Tap one to edit it in place; drag it by its handle, or hold it, to move it. Its menu has **Send now** (omp), **Move to top**, **Move to bottom**, **Duplicate** and **Delete**; a swipe left deletes too, and a prompt with only text comes back with **Undo**. **Clear all**, **Pause** and **Resume** sit at the top, and the field at the bottom adds a prompt to the end while the agent works. The screen follows the computer: the prompt that goes shows as **Sent** for a moment. Offline you can look but not change anything. The demo's working session has a queue to try it on.
- **Talk to the agent.** With nothing typed, the button beside the field is a microphone. Tap it and a screen slides up that listens until **Stop**, your words appearing large as you speak; or hold it, talk, and let go (slide away first to cancel). Then fix any word in place and **Send** it as the field would (steering or queued while the agent works), **Insert** it into the field to go on typing, or **Cancel**. With text in the field, a smaller microphone beside **Send** adds what you say after it. English only, recognized on the phone itself (an iPhone, or Android 12 and later; older Android, or one without an on-device recognizer, asks its recognizer to stay offline): if the phone has no English for that, the screen says so and offers its download (iOS 26, Android 13) or the setting. A call, Siri or leaving the app stops listening and keeps what you said. The first use asks for the microphone (and, on an iPhone before iOS 26, speech recognition).
- **Changes you can follow.** The phone now shows what changed instead of cutting to it: picking a theme cross-fades the whole app into its colors; new messages, tool rows and your own prompt rise into the conversation (an answer that streams in just grows); a tool row's spinner turns into its check and its arrow turns as it opens; the microphone turns into **Send** as you type, and grows on a disc while you hold it; the words you say fade in as they're heard, and **Stop** cross-fades into **Cancel**, **Insert** and **Send**; queued prompts glide to their new place when moved, deleted or brought back with **Undo**, and open into the editor in place. In the session list a session's state changes in place, a new one slides in, and one that starts needing you lights up once. Light taps confirm a prompt sent, an answer picked and sent, and a queued prompt dropped in its place. With Reduce Motion (iOS) or Remove animations (Android) on, things only fade or change at once.

## 0.1.3

Servers and the push relay need no update.

The iPhone build is 261: build 260 couldn't install over 0.1.2 on a phone that had picked Mocha, whose icon it had dropped (TestFlight said "Unable to Install"). 261 keeps that icon.

### Desktop app and phone app

- **Catppuccin Mocha is the default theme; Auto is gone.** The apps no longer switch with your system's light or dark: a new install starts in Mocha, and if you were on Auto you're now on Mocha. Pick another of the four themes any time, as before.
- **A new app icon.** Mocha's icon, the phone in its pocket in Mocha's colors, is now PocketTerm's own icon everywhere: on the iPhone and Android home screens, the Mac's Dock and Finder, and Windows. The other themes still bring their own icon when you pick them.
- **You can see what you picked.** When a coding agent asks a question, the answers you pick on the phone now fill with the theme's accent color, in every theme; so do the folder you create a project in, the **Queue** switch and the highlighted row in a picker the agent opens.
- **The intro opens onto the app itself.** Once the phone has sprung out of its pocket, its screen shows PocketTerm's real first screen, live, and the view dives in until that screen fills yours: no fade at the end. The app starts while the intro plays and takes your taps as soon as it ends; a tap still skips the intro, and with reduced motion it's still a short fade.

## 0.1.2

Servers and the push relay need no update.

### Desktop app and phone app

- **Themes.** Pick one of the four themes kitty uses, each with its own colors and shapes: **Catppuccin Mocha** and **Rosé Pine Dawn** (soft and rounded), **Tokyo Night** (crisp) and **Gruvbox Material** (square, capital labels). **Auto**, the default, shows Mocha when your system is dark and Dawn when it's light, and switches with it. Each computer and each phone keeps its own choice: on the computer in **Settings → Account → Theme**, on the phone in the account sheet under **Theme**.
- **An intro.** At launch the app icon's phone springs out of its pocket, stands up and the view dives into its screen, which opens onto the app, in your theme's colors (on the computer the first time the window opens). A tap skips it; with reduced motion on it's a short fade.
- **An app icon per theme.** Picking a theme gives PocketTerm that theme's icon: on the iPhone's home screen (iOS confirms the change), in the Android launcher (once you leave the app), in the Mac's Dock while the window is open, and on the Windows window, taskbar and tray. **Auto** keeps the usual icon.

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
