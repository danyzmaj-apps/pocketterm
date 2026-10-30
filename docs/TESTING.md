# Testing PocketTerm

Every user-facing feature, and what tests it. Four layers:

- **Unit and widget tests**: `fvm flutter test` (or `fvm dart test`) in each package and app; `deno test` in `apps/pocketterm-relay`; `claude plugin test .` in the Claude Code plugin (`apps/pocketterm-desktop/integrations/claude/plugins/pocketterm`, its tests in `tests/`). The core client tests also run against PocketTerm on a local Supabase (`POCKETTERM_SUPABASE=1 fvm flutter test -j 1 test/server_client_test.dart test/session_test.dart`, after `tool/supabase-local.sh start`); CI doesn't run those.
- **End-to-end run**: `tool/e2e/run.sh` (see `tool/e2e/bin/run.dart`). For each terminal (kitty, Ghostty, WezTerm): a server (`--server local`; `builtin`, over Tailscale; `supabase`, on a local Supabase in Docker; `supabase-cloud`, a new project on supabase.com made by the desktop's setup and deleted after; or a server's URL), the real desktop app under `apps/pocketterm-desktop/integration_test/e2e_test.dart` with throwaway terminals running a fake omp (`tool/e2e/bin/fake_omp.dart`), and the phone app in the iPhone Simulator or an Android emulator driven by Maestro (`apps/pocketterm-mobile/maestro/e2e/run.sh`, phases in order `main`, `profiles`, `computer-off`, `server-down`, `server-restart`, `desktop-restart`, `real-omp`, `revoke`; `supabase-cloud` has no server restart; the phone app is built from HEAD, or from the working tree as it is with `--phone-from-tree`). Below, *flow* `x` is `apps/pocketterm-mobile/maestro/e2e/x.yaml` and *step* "y" is a `report.step` in the desktop test.
- **Installed-app smoke**: `tool/smoke/run.sh` and `tool/smoke/scenario.sh`: a release build copied to a throwaway place, opened as from Finder, driven through accessibility (scenarios `wizard`, `getready`, `settings`, `theme`, `menubar`, `quit`).
- **Manual**: what needs a camera, real push delivery, a real right click, Windows, or the owner's own accounts.

Run the e2e suite on a quiet Mac: it opens throwaway terminal windows and refuses to start Ghostty while another Ghostty runs.

## What to run for a change

Don't run the whole e2e suite for every change: test what you changed and what it touches, so you know nothing near it broke.

1. **Unit and widget tests** of every package and app you touched (CI runs them all anyway).
2. **Find the rows** in the tables below for the features you changed *and* the features that share their code or screens (a sheet you made taller, a shared widget, a native file, a setting both apps read). Their *How it's tested* column names the e2e step, phone flow, smoke scenario or test file.
3. **Run only those**, on the cheapest target that covers them:
   - phone flows: `tool/e2e/run.sh --terminal kitty --phone-only <flow>,… [--phone-from-tree]` (add `fresh,pair-accept` first when the flow needs a paired phone), on the platform the change affects (`--platform android --avd <avd>` for Android code); the desktop then checks only what those flows did;
   - desktop steps: `--desktop-only <text>,…` keeps the steps whose name contains one of the texts (besides setup, Get ready, the windows, pairing and the hand-off, which every run needs), e.g. `tool/e2e/run.sh --terminal kitty --phone-only fresh,pair-accept,profiles --desktop-only profile`; `--no-phone` runs the desktop with the stand-in phone; or a smoke scenario (`tool/smoke/scenario.sh <scenario>`);
   - runs side by side (another checkout's run while yours goes): give each its own Simulator or emulator with `--device <udid or serial>` (`xcrun simctl create "PocketTerm E2E 2" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro <runtime>`); without it every run takes the Simulator "PocketTerm E2E", and one run's `fresh` wipes the app under the other's flows (Maestro then reports the device unreachable or the app stopped);
   - another terminal or server only when the change is about that terminal or server.
4. **New behaviour gets a test** in the same change (a flow, step, scenario or unit test) and a row here, so the next change can find it.

Full matrix runs (every terminal, server and phone platform, below and in [RELEASING.md](RELEASING.md#before-a-release-end-to-end)) are for big cross-cutting changes (protocol, encryption, session routing) or when a targeted run finds something it can't explain.

## Desktop

| Feature | How it's tested | Gap |
| --- | --- | --- |
| Setup: choose On this computer / On my own server / Supabase | step "setup: On this computer shows Tailscale as it is" / "…starts its server, Tailscale serves it" (`--server builtin`); step "setup: Supabase, set up a new project (real Management API)" (`--server supabase-cloud`); `setup_page_test.dart`; smoke `wizard` | none |
| Setup, On this computer: Tailscale checklist (installed, running, signed in, HTTPS, port 443 free) and each row's button | step reads the real Tailscale state and checks every row and that Start is on only when all are done; smoke `wizard` walks Stopped, NeedsLogin, HTTPS off and serve taken with a stand-in CLI; `setup_page_test.dart` "On this computer" | Install Tailscale (brew/winget) and Turn on HTTPS open other apps: unit only |
| Setup, On this computer: Start, the server runs and Tailscale serves it | step (builtin); smoke `wizard` (stand-in Tailscale) | none |
| Setup, own server: I have one, paste link, Connect | step "setup: own server, paste link" | none |
| Setup link problems (not a link, no setup token, server not answering, phone link) | step "setup: link problems are explained"; `setup_page_test.dart` | none |
| Setup, own server: Not yet (server guide, address check, commands, DNS/HTTPS/health checks) | step "setup: Not yet shows the server guide" (address check, commands); `setup_page_test.dart` "not yet" | DNS/HTTPS/health against a real new VPS: manual |
| Setup, Supabase: Set up a project (token, organization, region, Create, the step checklist, sign-in) | steps "setup: Supabase, set up a new project (real Management API)" and "setup: Supabase set up with no Retry" (`--server supabase-cloud`, a project made and deleted on supabase.com); `supabase_setup_test.dart` | Update that project on an existing one: unit only (the cloud run lists only the project it makes) |
| Setup, Supabase: Paste a setup link | the `--server supabase` run signs in with the local project's link (step "setup: own server, paste link"); `supabase_setup_test.dart` (the Supabase branch's paste screen) | none |
| Sign-in when the Keychain refuses (locked, missing): message and Try again | core `session_test.dart`; `setup_page_test.dart`, `hosting_test.dart` | a real locked Keychain: manual |
| First sign-in turns Terminal from phone on, adds no login item | steps "setup: …" assert both | none |
| Get ready: omp gets PocketTerm | step "get ready: omp gets PocketTerm" (Install, confirmed); `get_ready_test.dart`, `integrations_test.dart` | Claude Code install: plugin tests and `integrations_test.dart` only (the e2e never touches the owner's Claude Code) |
| Get ready: sessions already open (unreported) | step "get ready: sessions already open are listed" | none |
| Get ready: terminals row | step "get ready: terminals"; `terminals_card_test.dart` | none |
| Get ready: project folders, Choose folder… | step "get ready: project folders" | none |
| Get ready: phone code (QR, expiry, Retry) | step "get ready: phone code"; `pair_test.dart` | the code running out after 10 minutes: unit only |
| Get ready: Done, Open setup checklist again | steps "get ready: Done", "settings: status bar and Open setup checklist"; smoke `getready` | none |
| Settings status bar (All set / things need attention, Show) | step "settings: status bar and Open setup checklist"; `settings_test.dart`; smoke `settings` | none |
| Phone tab: Terminal from phone switch | step "phone: computer off, then Retry brings it back" (+ phone phase `computer-off`); `settings_test.dart` | none |
| Phone tab: Add a phone… | step "add a phone: two pairing links" | none |
| Phone tab: Reset key… | step "phone tab: Reset key"; `channel_keys_test.dart`, `settings_test.dart` | none |
| Phone tab: project folders (remove, Add folder…) | step "settings: project folders remove and add"; `settings_test.dart` | none |
| Coding agents tab (state, Install/Update, Default, Make default) | step "settings: coding agents tab"; `settings_agent_test.dart` | Make default with two agents installed: unit only (the e2e has no Claude Code) |
| Coding agents tab: omp profiles (Profiles: line; Install puts PocketTerm in the default profile and each one) | step "profiles: Settings lists them, Install puts PocketTerm in each"; `integrations_test.dart` | the Profiles: line: e2e only |
| Sessions carry their omp profile (the extension's hello, a window's `omp --profile` command line) | steps "profiles: omp in a profile reports it; its window says so", "real omp: a profile loads PocketTerm from its own folder and says so"; core `live_test.dart`, `terminals_test.dart`, `agent_test.dart` | none |
| Notifications name an omp profile (`omp · <profile> finished · <project>`) | step "profiles: a finished run is notified as omp · personal finished" (the title the app sends) | delivery: manual |
| Terminals tab: New sessions open in | step "settings: new sessions open in <terminal>" | none |
| Terminals tab: kitty Set up (remote control in kitty.conf) | `kitty_test.dart`, `terminals_card_test.dart` | e2e kitty already listens (its throwaway config); the Set up click: unit only |
| Terminals tab: Allow… (Automation for Ghostty, iTerm2) | `ghostty_test.dart` | manual: a macOS permission prompt for the owner |
| Terminals tab: Ghostty Start new windows in tmux / Remove / line upgrade | steps "ghostty: Start new windows in tmux", "ghostty: Remove takes tmux out"; `ghostty_config_test.dart`, `settings_test.dart` | none |
| Terminals tab: tmux install (brew, MacPorts, no Homebrew) | `terminals_card_test.dart`, `commands_test.dart` | installing for real: manual |
| WezTerm on Windows (install, PATH) | `wezterm_setup_test.dart`, `windows_test.dart` | manual: Windows hardware |
| Account tab: Your server, Add a computer… | step "account: Add a computer" (built-in server); `settings_account_test.dart`, `hosting_test.dart` | Add a computer… on Supabase (`POST /v1/setup/new`): core client tests against the local Supabase only |
| Account tab: phones signed in, Sign out… | `settings_account_test.dart`; step "revoke: phone removed on the server" revokes through the same API call (+ phone phase `revoke`) | the Sign out… button itself: unit only |
| Account tab: Launch at login (off until turned on; Login Items hint) | step "settings: launch at login switch" (E2E host records it, no login item); `controller_test.dart`, `desktop_host_test.dart` | the real login item: manual (it changes the owner's login items) |
| Account tab: Erase… | step "account: Erase" (built-in server); `settings_account_test.dart`; server `edge_test.dart` | none |
| Account tab: Sign out | step "account: sign out"; `settings_account_test.dart` | none |
| Account tab: How your data is protected | step "settings: data protection"; smoke `settings` | none |
| Account tab: Theme (Catppuccin Mocha, the default, Rosé Pine Dawn, Tokyo Night, Gruvbox Material), kept in the preferences; every tab repainted | smoke `theme` (each kept as `flutter.theme`; Account, Phone, Coding agents and Terminals photographed in each; Mocha last); core `theme_test.dart`, `app_icon_test.dart` | the Dock icon per theme (the app's own for Mocha), the intro at the window's first showing and the colour under its first frame: manual; Windows' window and tray icons: manual (Windows hardware) |
| Account tab: Quit PocketTerm | smoke `quit` | none |
| Hosting states (no Tailscale, off, signed out, HTTPS off, failed, taken, renamed) | `hosting_test.dart`; smoke `wizard` (stand-in CLI) | none |
| Menu bar icon: click opens the window | smoke `menubar` | none |
| Menu bar right-click menu (Open, Settings…, Check for Updates…, Quit) | none automated | manual: needs a real right click; Sparkle's update check reaches the network |
| Windows tray menu, update notice (Download) | `desktop_host_test.dart`, `update_check_test.dart` | manual: Windows hardware |
| Runs as from Finder (launchd PATH, no TERM, no locale) | step "desktop: runs as from Finder"; smoke (`open -n`) | none |
| Sessions placed in their own windows; plain shells as screens | steps "windows: sessions in their own windows", "windows: plain shell is a screen" | none |
| Desktop restart keeps the sign-in and sessions | step "restart: desktop app" (+ phone phase `desktop-restart`) | none |
| Real omp extension | steps "real omp: /new from the phone starts a fresh session in place", "real omp: a profile loads PocketTerm from its own folder and says so" (when omp is installed) | none |

## Phone

| Feature | How it's tested | Gap |
| --- | --- | --- |
| Fresh install, setup screen | flow `fresh`; `setup_page_test.dart` | none |
| Scan the computer's code | flow `pair` (an E2E build pastes the code where the camera would read it); `scan_test.dart` | the camera itself: manual |
| Bad or used code | `scan_test.dart`, `session_test.dart` | none |
| Demo | flow `demo` (`maestro/demo.yaml`); `demo_test.dart` | none |
| Tour prompt (New here? Show me / No thanks) | `coach_test.dart` | an E2E build starts it answered; release-build behavior: unit only |
| First-use tips, Show tips again | flow `tips_home`; `coach_test.dart` | none |
| Notifications consent (Turn on / Not now) | flow `pair` (both answers); `push_consent_test.dart` | none |
| Notifications switch in the account sheet; why turning on failed (off in Settings, no address from Apple or Google) | flow `push_toggle`; `push_consent_test.dart` | no address from Apple or Google: unit only |
| Tailscale Awaiting Approval help | `phone_edges_test.dart` | a tailnet with device approval: manual |
| Account sheet rows, Leave this server (Cancel and Leave) | flows `account_sheet`, `signout`; `home_page_test.dart` | none |
| Theme (account sheet → Theme: Catppuccin Mocha, the default, Rosé Pine Dawn, Tokyo Night, Gruvbox Material), kept after a restart; iOS's icon-change alert | flow `theme` (the theme sheet, the session list and a session photographed in each; Mocha last); core `theme_test.dart`, `app_icon_test.dart` | the Android launcher icon (switched in release builds only, once the app leaves the screen), the launch intro and the colour before Flutter's first frame: manual |
| Motion (`lib/motion.dart`): the theme cross-fade, arrivals in a conversation and the session list, tool rows opening, the microphone turning into Send and growing while pressed, the voice sheet's words and buttons, queued prompts gliding to a new place; Reduce Motion / Remove animations; a mic press the system takes back | flows `demo`, `queue`, `voice`, `theme` walk through every one; `voice_test.dart` (the swap, a press taken back), `queue_strip_test.dart` (rows glide back after a refused move); the rest of the widget tests run with each animation | how it looks moving and with Reduce Motion on: manual (record the Simulator with `xcrun simctl io booted recordVideo` while a flow runs) |
| Computer picker, locked computer | flow `computers`; `home_page_test.dart`, `phone_edges_test.dart` | scanning a locked computer's code: manual (camera) |
| Project list: sort, fold, long-press menu | flow `project_list`; `terminal_list_test.dart` | none |
| omp profiles in the list: the row and the session's header name the profile; the profile filter (a profile, one with no sessions, Show all) | flow `profiles` (phase `profiles`); `terminal_list_test.dart` | none |
| Swipe left: End session | flow `end_session` | none |
| Swipe left: Close window | flow `close_window`; step "phone: close a shell window from the window list" | none |
| New session (+): agent in a project | flow `new_session`; step "phone: new session (+) opens in <terminal>" | none |
| New session (+) and the project menu's New omp · <profile> session here, in an omp profile | flow `profiles`; steps "phone: New session in a profile types omp --profile=personal", "phone: a project’s New omp · personal session here starts in it"; `new_session_sheet_test.dart` | none |
| New session (+): plain shell | flow `new_shell`; step "phone: new shell opens in <terminal> without an agent" | none |
| New session (+): New project… | flow `new_project`; step "phone: new project made in the project folder" | none |
| Conversation: prompt and streamed reply | flows `conversation-*`; step "phone: prompt reaches the agent" | none |
| Conversation: steer while it works, Queue | flow `steer_queue`; steps "phone: steer reaches the agent while it works", "phone: a queued prompt runs after the turn"; `live_hub_test.dart` "the queue" (edit, move, remove, Send now, limits, reconnect); `queue_strip_test.dart` | none |
| Conversation: the whole queue (fullscreen: edit in place, drag, Move to top/bottom, Duplicate, Delete and Undo, Clear all, add at the end, Send now, Pause/Resume, Sent as it goes, offline read-only) | flow `queue` (`maestro/queue.yaml`, on the demo's queued session; `-e THEME=<name>` names its screenshots); `queue_screen_test.dart`, `queue_strip_test.dart` (the header opens it) | on a real computer: Clear all, Duplicate and Undo against LiveHub's queue (unit only; the e2e fake's queue drains too fast to hold one open) |
| Conversation: voice prompt (the microphone where Send is while nothing is typed, a smaller one beside Send otherwise; tap listens until Stop, hold listens until lifted, sliding away cancels; edit in place, Send, Insert, Cancel; denied microphone, no English on the device and its download; interruptions keep the text) | flow `voice` (`maestro/voice.yaml`, the demo in an E2E build, whose scripted speaker stands in for the microphone; its header says how to set each theme, `-e NAME=<name>` names the screenshots); `voice_test.dart` (tap and hold flows, the swap, appending, denied, no English, interrupted, leaving the app, steer and queue on Send, the sheet clear of the status bar) | the recognizers themselves (iOS SpeechAnalyzer and SFSpeechRecognizer, Android's on-device SpeechRecognizer), their restarts over long dictation, the English download and a real call interrupting: manual, on a real phone |
| Conversation: Stop | flow `stop`; steps "phone: Stop interrupts the agent", "phone: Stop holds the queue; Resume sends what waits" | none |
| Conversation: Continue chip | flow `switch` (Just restart) | none |
| Slash commands: / list, /new | flows `slash_new`, `real_omp`; step "phone: /new starts a fresh session in place" | none |
| Slash command pickers: /model, /resume (search, Cancel) | flows `menu_model`, `menu_resume`; steps "phone: /model picker answered", "phone: /resume picker searched and answered"; `live_test.dart` (parseMenu) | none |
| Approval (Approve) | flow `approval`; step "phone: approval answered" (Ghostty: left to the computer) | Deny: `live_test.dart`, demo; e2e answers Approve only |
| Questions (choice, Other…); a picked answer filled with the theme's accent | flow `question`; step "phone: the agent’s question answered"; `live_test.dart` (answerKeys); core `ui_test.dart` (picked and unpicked chips in each theme) | typed Other and multiple choice: unit only |
| Plan review | flow `plan`; step "phone: the plan review answered"; `live_test.dart` (parsePlanReview) | none |
| Screen page: key bar (Esc, Tab, arrows, Enter, ^C), typing, wrap | flows `screen`, `screen_keys`; steps "phone: keys reach the window", "phone: screen keys Tab, Enter, Ctrl+C reach the window" | none |
| Screen from a conversation | flow `session_screen` | none |
| Switch to conversation: Restart and continue / Just restart | flows `switch-continue`, `switch-restart`; matching steps | none |
| Switch to conversation in an omp profile (`omp --profile=<name> -c`) | flow `profiles`; step "phone: Switch to conversation resumes in the profile"; `terminal_bridge_test.dart` | omp started with only `OMP_PROFILE` set (no flag on its command line) resumes in the default profile: by design |
| Images from Photos | flow `image`; step "phone: image arrives decrypted at the agent" | Paste image: unit only (no clipboard image in the Simulator) |
| Files from Files | flow `file`; step "phone: a document arrives …" | none |
| 10 attachments at most | flow `attach_limit`; `attachments_test.dart` | none |
| Files over 20 MB refused | flow `too_large`; `attachments_test.dart`, server `server_test.dart` (blobs) | none |
| Follow (Live Activity / Android ongoing notification) | flow `follow` (the switch and its state); `live_activity_test.dart` | what the Lock Screen or the notification shade shows, and its updates by push: manual (real device, real push) |
| Notifications delivered for asks and finished runs | server `server_test.dart` push group, `edge_test.dart` relay; relay `tests` | manual: real APNs/FCM delivery to a real device |
| Tapped notification opens its session | flow `deep_link` via `push-tap-cold` (Android, as the tap's intent) | iOS tap on a real notification: manual |
| Deep link pocketterm://session cold start | flow `deep_link` (`deep-link-cold`, `deep-link-server-restart`, `deep-link-desktop-restart`) | none |
| Cold start, background and back | flows `cold_start`, `background`/`foreground` | none |
| Server unreachable, Retry | flow `unreachable` (phase `server-down`) | none |
| Computer not answering / last seen, Retry | flows `offline`, `retry` (phase `computer-off`) | the clock-differs note: `phone_edges_test.dart` only |
| Reconnect after server or desktop restart (nothing replayed) | flow `reconnect` (phases `server-restart`, `desktop-restart`); steps "restart: …" | none |
| Signed out by the computer (revoked) | flow `revoked` (phase `revoke`); step "revoke: phone removed on the server" | none |

## Server, relay, core

| Feature | How it's tested | Gap |
| --- | --- | --- |
| Setup and pairing codes, throttle | `server_test.dart` (setup, pairing, auth); every e2e sign-in | none |
| Devices list, revoke, erase | `server_test.dart`; steps "revoke: …", "account: Erase" | none |
| Restart keeps state; state on disk | `edge_test.dart`; step "restart: server" | none |
| Blobs (20 MB, download once, 1 h) | `server_test.dart`, `edge_test.dart`; flows `image`, `file`, `too_large` | none |
| PocketTerm on Supabase (function, migrations, Realtime, blobs, push) | core `server_client_test.dart`, `session_test.dart` with `POCKETTERM_SUPABASE=1`; e2e `--server supabase` (local) and `--server supabase-cloud` | not in CI |
| Live channel, reconnect, no replays | `terminal_channel_test.dart`, `terminal_remote_test.dart`; phases `server-restart`, `desktop-restart` | none |
| Push forwarding, sealed to the relay | `server_test.dart` push, `edge_test.dart` relay and queue; relay `tests` | real delivery: manual |
| omp extension | fake omp in the e2e (same protocol, `--profile` too), real omp phase | none |
| Claude Code plugin | plugin `tests` (`pocketterm.test.ts`, `streaming.test.ts`) | never installed by the e2e (it would change the owner's Claude Code); manual |
| kitty adapter | `kitty_test.dart`; e2e `--terminal kitty` | none |
| Ghostty adapter (no screen, tmux, one row per window in tmux, config line upgrade) | `ghostty_test.dart`, `ghostty_surface_test.dart`, `terminals_test.dart`, `ghostty_config_test.dart`; e2e `--terminal ghostty` | none |
| WezTerm adapter | `wezterm_test.dart`; e2e `--terminal wezterm` | Windows: unit only |
| iTerm2 adapter (screen vs scrollback, gone windows, colors, `ITERM_SESSION_ID`) | `iterm_test.dart`, `terminal_test.dart` | e2e: none; launching, typing, keys, closing and finding an agent's window run by hand against a real iTerm2 |
| tmux adapter | `tmux_test.dart`; Ghostty's tmux windows in the e2e | none |

## Per terminal

The e2e runs every phone flow on each terminal. Where a terminal can't do something, the run checks what the phone says instead:

- **Ghostty** can't share its screen: `screen` checks the phone says so; `approval` checks the phone is told to answer on the computer (the desktop then answers). Sessions the phone starts open in tmux inside Ghostty, which can: `question`, `plan`, `menu_model`, `menu_resume`, `steer_queue` and `stop` run on that session for every terminal.
- **kitty** and **WezTerm**: everything, screens included.

## What ran end to end for 0.1.0 (build 14)

| Server | Phone | Terminals | Result |
| --- | --- | --- | --- |
| Local (`--server local`) | iPhone Simulator | kitty, Ghostty, WezTerm | Every desktop step and every phone phase passed, except `steer_queue` on all three (a harness timing, which passed after the fake's fix in a phone-only kitty run) and Ghostty's `resume-60s`, where Maestro's driver died taking a screenshot after every check had passed |
| Local | Android emulator, API 35 | kitty, Ghostty, WezTerm | All passed |
| Local | Android emulator, API 26 (Android 8) | kitty: `fresh`, `pair`, a prompt, `/new` | All passed |
| Supabase in Docker (`--server supabase`) | iPhone Simulator | kitty, Ghostty, WezTerm | All passed |
| Supabase in Docker | Android emulator, API 35 | kitty | All passed |
| Supabase on supabase.com (`--server supabase-cloud`) | iPhone Simulator | kitty | All passed: the desktop's setup made the project on the real Management API, phone `main` (notifications and Follow through push.danyzmaj.com), `computer-off`, `desktop-restart`, `real-omp`, `revoke`; the project was deleted after |
| The test server, pocketterm-test.danyzmaj.com (Docker image, behind a Cloudflare Tunnel) | iPhone Simulator | kitty, Ghostty, WezTerm | Every phone phase passed on all three, and every desktop step; kitty again in full after two harness fixes: all passed |
| Built in, over Tailscale (`--server builtin`) | iPhone Simulator | kitty, Ghostty | Stopped before the end: kitty passed every desktop step it reached (51) and phone `main`; Ghostty passed 20 desktop steps and 10 phone flows. WezTerm didn't run |

The installed-app smoke last ran on the 2026-10-22 build, walked by hand through `tool/smoke/run.sh`: On this computer with the stand-in Tailscale, Get this computer ready, Settings, sign out, the own-server branch, the real Tailscale's port-taken screen and the folder picker. The `scenario.sh` set (`wizard`, `getready`, `theme`, `settings`, `menubar`, `quit`) first ran on 2026-10-25 with the themes work: all passed except the wizard's four "Start is disabled" checks, where accessibility reports the greyed-out Start as enabled (commit 2e947ee, before the themes, fails them the same way).

## Manual only

- Camera scanning of a code (the Simulator has no camera; E2E builds paste the code).
- Real push delivery to a real device (APNs, FCM through the relay) and what a Live Activity or notification shows on a locked phone.
- The menu bar icon's right-click menu and Check for Updates… (Sparkle).
- Launch at login for real (it changes the person's login items), macOS Automation and Accessibility permission prompts, a locked Keychain.
- Windows: WezTerm install and PATH, the tray menu, the update notice, start at login.
- Installing Tailscale, tmux or WezTerm for real; a new VPS's DNS and HTTPS; a tailnet with device approval.
- Updating an existing Supabase project (**Update that project**) and a paused free project.
