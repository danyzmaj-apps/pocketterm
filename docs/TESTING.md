# Testing PocketTerm

Five layers, cheapest first:

- **Unit tests**, per platform (below). CI runs them all.
- **Wire vectors and interop**: every core reads `tool/vectors/vectors.json` (frozen, made from the Dart code) in its unit tests; opt-in interop tests talk to the real Dart server.
- **Installed-app smoke** (macOS): `tool/smoke/run.sh` + `tool/smoke/scenario.sh`, the native app as a person opens it, driven through accessibility.
- **End-to-end run**: `tool/e2e/run.sh`: a server, the native Mac app, throwaway terminals with a fake omp, and the phone app (iOS Simulator or Android emulator) driven by Maestro.
- **Manual**: what needs a camera, real push delivery, a real right click, Windows hardware, or the owner's own accounts (end of this file).

## Unit tests

| What | Command |
| --- | --- |
| Swift core (`PocketTermKit`, `PocketTermTerminals`, `PocketTermDesktop`) | `cd packages/PocketTermKit && swift test` |
| Mac app | `cd apps/pocketterm-desktop/macos && xcodegen generate && xcodebuild -project PocketTerm.xcodeproj -scheme PocketTerm test` |
| iPhone app | `cd apps/pocketterm-mobile/ios && xcodegen generate && xcodebuild -project PocketTerm.xcodeproj -scheme PocketTerm -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test` |
| Android core and app | `cd apps/pocketterm-mobile/android && ./gradlew :core:test :app:testDebugUnitTest` (JDK 17) |
| Windows cores (`PocketTerm.Core`, `PocketTerm.Desktop.Core`) | `~/.dotnet/dotnet test apps/pocketterm-desktop/windows/PocketTerm.sln` (the cross-platform parts run on macOS; the WinUI app builds in CI on `windows-latest`) |
| Dart server | `fvm dart test` in `packages/pocketterm_server` |
| Relay | `deno test` in `apps/pocketterm-relay` |
| Claude Code plugin | `claude plugin test .` in `apps/pocketterm-desktop/integrations/claude/plugins/pocketterm` |

**Vectors.** `tool/vectors/vectors.json` holds sealed frames, AAD strings, base64 variants, ping proofs and envelopes made by the Dart implementation. The Swift, Kotlin and C# cores' unit tests decode and re-encode every one: a core that drifts from the wire format fails there first. The file is frozen; regenerate it only with a deliberate protocol change.

**Interop.** Each core has an opt-in test against the real server. Start one (`fvm dart run apps/pocketterm-server/bin/pocketterm_server.dart serve --data <tmp> --address 127.0.0.1 --port 0`), make a setup link (`… setup-link --data <tmp> --public-url <url>`), then run the core's tests with `POCKETTERM_INTEROP_SERVER=http://127.0.0.1:<port>` and the link in the environment (each core's README names the variable): setup, pairing, a topic, sealed frames both ways, a blob up and down.

## Installed-app smoke (macOS)

`tool/smoke/run.sh prepare` builds a Release app with `-D POCKETTERM_SMOKE`, copies it as `com.danyzmaj.pocketterm.smoke` with a throwaway home, Keychain and tmux; `tool/smoke/scenario.sh wizard getready settings theme menubar quit` walks it through accessibility (`tool/smoke/ax.swift`). Needs Accessibility and Screen Recording for the terminal it runs in. The Windows app's smoke is CI's build and its unit tests; the app itself is checked by hand on Windows.

## Maestro flows on the demo

`apps/pocketterm-mobile/maestro/{demo,queue,voice,tips,orchestrator}.yaml` run on the phone's demo, no computer needed: `~/.maestro/bin/maestro test apps/pocketterm-mobile/maestro/queue.yaml`. On iOS they need a Debug build launched with `POCKETTERM_E2E` (the flows pass it).

## The end-to-end run

```
tool/e2e/run.sh [--terminal kitty|ghostty|wezterm|iterm|all]
                [--server local|builtin]
                [--no-phone] [--platform ios|android [--avd <name>]] [--device <id>]
                [--phone-only <flow>,…] [--phone-from-tree] [--desktop-only <text>,…] [--hold] [--from-head]
```

`tool/e2e/bin/run.dart` documents every option. For each terminal:

1. **Server**: `local` (the compiled Dart server on a free port) or `builtin` (the app's own "On this computer" server, published by the real `tailscale serve`).
2. **Desktop**: the native Mac app, built as a test build of its own (`com.danyzmaj.pocketterm.e2e`, Debug, into `apps/pocketterm-desktop/macos/build/e2e`), opened by Launch Services as from Finder (launchd's PATH, no TERM, no locale) with a throwaway home. `tool/e2e/lib/desktop.dart` drives it two ways (`tool/e2e/lib/mac_app.dart`): accessibility through `ax.swift`'s `serve` mode (the screens' identifiers), and the app's test hooks (`apps/pocketterm-desktop/macos/PocketTerm/App/E2E.swift`, compiled into test builds only, switched on by `POCKETTERM_E2E_DIR`): requests in a folder answered with what the controller, the terminals and the server say; secrets in a file of the run's (never the Keychain), launch at login in memory, the folder picker answering with the run's projects folder, omp found at the fake, the pairing links and phone notifications recorded.
3. **Terminals**: throwaway kitty / Ghostty / WezTerm / iTerm2 windows and the run's own tmux server, each with only the run's config, the fake omp (`tool/e2e/bin/fake_omp.dart`) first on the PATH and a shell that logs every command and key.
4. **Phone**: `apps/pocketterm-mobile/maestro/e2e/run.sh` builds the native E2E build (iOS: `xcodebuild` Debug for the Simulator "PocketTerm E2E", made when missing, the flows launching it with `POCKETTERM_E2E`; Android: `./gradlew :app:assembleDebug -PpockettermE2e=true`, the emulator `pocketterm_api35` cold-booted when none runs, `adb reverse` for the server's port) and runs the flows of each phase: `main`, `profiles`, `computer-off`, `server-down`, `server-restart`, `desktop-restart`, `real-omp`, `revoke`. The desktop hands it `phone-link.txt`, `phone-link-2.txt` and `expect.json`, answers its rpc requests (`approve-on-computer`, `terminal-on`) and checks on the computer what each flow did.

Everything a run saw is in `build/e2e/<stamp>/`: `summary.txt` (the pass/fail table), `summary.json`, `junit.xml`, per terminal `results.jsonl`, `desktop-e2e.log`, `desktop-<n>.log` (the app's own output), `server.log`, `screenshots/` (a failure adds `fail-<step>.png` and `fail-<step>.ax.txt`, what accessibility read), `phone/<platform>/<phase>/<flow>/` (Maestro's log, screenshots, report) and `work/` (the fake omp's logs, the shells' typed logs, the throwaway configs).

`--no-phone` runs the desktop alone; the checks of what the phone did are then skipped (the Flutter era's in-process stand-in phone is gone with the Dart core). `--hold` stops after the hand-off so you can run phone flows one by one against the live desktop (`run.sh --run-dir <run>/<terminal> --phase main --only <flow> --no-build`), then `rm <run>/<terminal>/hold` to go on.

Run it on a quiet Mac: it opens terminal windows, and refuses to start Ghostty or iTerm2 while another of it runs. The terminal it runs in needs Accessibility and Screen Recording. Phone runs on the iOS Simulator can't overlap (Maestro's iOS driver uses one port).

### The Flutter desktop test, step by step

`apps/pocketterm-desktop/integration_test/e2e_test.dart` drove the Flutter app in-process; `tool/e2e/lib/desktop.dart` keeps every step under the same name:

| Flutter step (`e2e_test.dart`) | Native check (`desktop.dart`) |
| --- | --- |
| desktop: runs as from Finder | the app's own environment from its hooks (`state.env`): no Homebrew on the PATH, no TERM/locale, the run's HOME |
| terminals: throwaway windows open | unchanged (`e2e.dart` throwaways; Ghostty's through the app's Ghostty host via `ghostty-launch`) |
| setup: On this computer shows Tailscale as it is / …starts its server | AX: `setup-this-computer`, each `check-*` row's text against the real Tailscale CLI, `setup-start-server` enabled state; builtin: Start, hooks' `hosting.publicUrl`, `/v1/health` through it |
| setup: link problems are explained | AX: `setup-link` set, `setup-error` per bad link, no `setup-link-health`, Connect signs nothing in (hooks' `state.backend`) |
| setup: join another computer, paste link | AX: `setup-join`, `setup-link`, "answers" in `setup-link-health`, `setup-connect`; then signed in, Terminal from phone on, no login item |
| get ready: omp / sessions already open / terminals / project folders / phone code / Done | AX: Install → `confirm-install` text → `confirm-install-go`, extension file; `get-ready-open-sessions`, `get-ready-unreported-<key>`; hooks' `statuses`; `get-ready-choose-folder`; `pairing-qr` and a recorded pairing link; `get-ready-done` |
| windows: sessions in their own windows / plain shell is a screen | hooks' `sessions`, `windows`, `unreported` |
| settings: status bar, coding agents tab, data protection, launch at login, new sessions open in | AX: `settings-status`, `settings-open-checklist`; `settings-agent-omp`/`-claude`, `settings-default-omp`; `settings-data-protection`, `data-protection-done`; `settings-launch-at-login` value and the hooks' in-memory login item; `settings-terminal-app` picked |
| add a phone: two pairing links / hand-off files | AX: `settings-add-phone` twice, the sheet's Done; links from the hooks; the spare computer signed in by the hooks (`spare`) |
| phone: … (every `_verifyMain` check) | unchanged: the fake omp's and the shells' logs, hooks' `sessions`/`windows` |
| profiles: … | AX: `settings-omp-profiles`, Install in `settings-agent-omp`, `confirm-install` paths; hooks' sessions, windows and recorded notifications |
| phone: computer off, then Retry | AX: `settings-terminal-from-phone` off, on again on the phone's rpc |
| restart: server / desktop app | the harness's server (or the hooks' `hosting-stop`/`hosting-start`); the desktop really quits and starts again, still signed in |
| real omp: … | unchanged, through the hooks' `send` and `live` |
| revoke | hooks' `server-devices`, `revoke` |
| ghostty: Start new windows in tmux / Remove | AX: `settings-ghostty-tmux` |
| settings: project folders remove and add | AX: `settings-folder-<path>`, `settings-add-folder` |
| account: Add a computer / Reset key / Erase / sign out | AX: `settings-add-computer` + `add-computer-link`; `settings-reset-key` + the alert's Reset key, a new channel key; `settings-erase` + Erase, the spare signed out; `settings-sign-out` (+ the alert when hosting), `sign-in-other-server`, back on the setup window |
| stand-in phone (`--no-phone`) | removed: the Dart client it was made of is gone; `--no-phone` skips the phone checks |

There is no XCUITest target: XCUITest needs UI automation mode allowed by `sudo`, the AX driver doesn't.

## What to run for a change

1. The unit tests of every package and app you touched.
2. A protocol, crypto or envelope change: the vectors (all three cores) and an interop run.
3. A Mac UI change: the smoke scenario for that screen, and the e2e desktop steps that touch it: `tool/e2e/run.sh --terminal kitty --no-phone --desktop-only <step text>`.
4. A phone UI change: its flows on the platform you changed: `tool/e2e/run.sh --terminal kitty --platform ios|android --phone-only fresh,pair-accept,<flow> --phone-from-tree` (or `--hold` and run the flows by hand). Some flows need an earlier one: `conversation-1` talks to the session the fake omp stops for approval, so it needs `approval` before it, and `deep-link-server-restart`/`deep-link-desktop-restart` check `conversation-1`'s reply.
5. A terminal adapter change: a full run on that terminal.
6. Big cross-cutting changes (protocol, routing, the bridge): the whole run on iOS and Android, kitty and Ghostty at least.

## What ran end to end for this build (native apps, 2026-11-05)

Commit 69a6486 plus the uncommitted app, flow and harness fixes of that day (`--phone-from-tree`), server `--server local`, Android emulator API 35 (`pocketterm_api35` on `-port 5584`, `--device emulator-5584`) and the iPhone Simulator (iOS 26.5).

**This was not one unattended run.** It was per-flow verification: one full iOS run early on, then a held Android run with flows re-run one by one, then `--phone-only` runs of what changed or had failed. The Mac was under heavy load from other work (load averages up to 600), and the emulator's app hit ANRs from CPU starvation; a flow that failed only on an ANR was re-run.

| Phone | Run | Command / how | Result |
| --- | --- | --- | --- |
| iPhone, kitty | `build/e2e/20261105-113429` | full unattended run, every phase | Every phone flow (59) passed; every desktop step passed except the orchestrator's prompt check (fixed since, see the next rows) |
| iPhone, kitty | `build/e2e/20261105-175223` | `--platform ios --phone-only fresh,pair-accept,new-session,orchestrator,theme,account-sheet --desktop-only orchestrator` | ALL PASSED: the flows changed since the full run (`theme`, `orchestrator`, `account-sheet`) and the desktop's "the orchestrator starts in kitty and steers a session" with its prompt check |
| Android, kitty | held run `build/e2e/20261105-135149`, flows re-run with `maestro/e2e/run.sh --only` | phase `main` | All 46 flows passed at least once: fresh, pair-accept, tips, sign-out, fresh-again, demo, pair-decline, push-toggle, computers, approval, conversation-0/1/2, slash-new, screen, image, file, new-session, steer-queue, stop, question, plan, menu-model, menu-resume, follow, session-screen, screen-keys, new-shell, new-tab, windows, new-project, project-list, close-window, attach-limit, too-large, account-sheet, theme, voice-language, switch-continue, switch-restart, end-session, cold-start, away-60s, resume-60s, deep-link-cold, push-tap-cold |
| Android, kitty | `build/e2e/20261105-165730` | `--phone-only fresh,pair-accept,new-session,orchestrator --desktop-only orchestrator` | ALL PASSED, the desktop's orchestrator step (prompt check included) too |
| Android, kitty | `build/e2e/20261105-170103` | the later phases, `--phone-only …,real-omp,revoked,unreachable,offline,retry` | Passed: real-omp, revoked, unreachable (server-down), offline and retry (computer-off), conversation-0; desktop: real omp, revoke, computer off, profiles' Settings and reporting. Failed, re-run below: profiles (an ANR under load), conversation-1 and the two deep-link restarts |
| Android, kitty | `build/e2e/20261105-174040` | `--platform android --device emulator-5584 --phone-only fresh,pair-accept,approval,conversation-0,conversation-1,profiles,deep-link-server-restart,deep-link-desktop-restart,reconnect --desktop-only 'profiles,restart'` | ALL PASSED: every flow listed (reconnect in both server-down and desktop-restart), the desktop's profiles steps, restart: server and restart: desktop app |
| iPhone, Ghostty 1.3.1 (phone sessions in tmux) | `build/e2e/20261105-182754` | `--terminal ghostty --platform ios --phone-from-tree --phone-only fresh,pair-accept,screen,screen-keys,new-shell,new-tab,windows` (every desktop step) | ALL PASSED: those 7 phone flows and all 38 desktop steps that ran, "ghostty: Start new windows in tmux" and "Remove takes tmux out" included |

What the failures were:

- Android `conversation-1` (and so the deep-link restarts) in `20261105-170103`: not an app bug. Its session is the one the fake omp stops for approval ("Approve bash? echo e2e"), and that run left `approval` out of `--phone-only`, so no reply could come. With `approval` before it, it passes.
- Android `profiles` in `20261105-170103`: an ANR dialog ("PocketTerm isn't responding") over the list while the Mac was at a load average in the hundreds; passes on the re-run.
- `build/e2e/20261105-172709`: the harness's accessibility helper (`tool/smoke/ax.swift`) crashed with a stack overflow walking the setup window: its tree briefly held a cycle. `walk` now skips elements it has seen and stops at depth 256.
- Ghostty, `build/e2e/20261105-175912` and `-180159`: stopped at "terminals: throwaway windows open". macOS asked whether the test build (`com.danyzmaj.pocketterm.e2e`) may control Ghostty, a one-time Automation permission a person has to allow. The harness now waits up to 3 minutes for that answer, and says so, instead of failing at once.
- Ghostty, `build/e2e/20261105-180253`: new-shell, new-tab and windows failed, and so did "ghostty: Start new windows in tmux". An app bug, also in the Dart code: the phone's session opened in a tmux session (attached in a new Ghostty window), yet no window list showed it. `Tmux.sockets()` found the run's server in `$TMUX_TMPDIR/tmux-501/default`, then let `/private/tmp/tmux-501/default` (a socket left behind by a server long gone) replace it because the names matched, so tmux showed no panes and Ghostty's window gave way to a pane that wasn't listed. A name found twice now keeps its first path (a learnt socket, then `$TMUX_TMPDIR`'s, then `/private/tmp`'s); `TmuxTests.testASocketLeftBehindLaterUnderTheSameNameDoesntHideTheLiveServer` covers it. Passes in `20261105-182754`.

Nothing is failing. Not run for this build: WezTerm, iTerm2 and the built-in server; the Ghostty flows on Android.

## Manual only

- Camera scanning of a code (the Simulator has no camera; E2E builds paste it).
- Real push delivery to a real device and what a Live Activity or notification shows.
- The menu-bar icon's right-click menu and Check for Updates… (Sparkle).
- Launch at login for real, macOS Automation/Accessibility prompts, a locked Keychain.
- The Windows app: WezTerm install and PATH, the tray menu, the update notice, start at login.
- Installing Tailscale, tmux or WezTerm for real; a tailnet with device approval.
