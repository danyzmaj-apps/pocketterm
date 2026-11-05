# PocketTermDesktop

The Mac app's services without its UI: what `apps/pocketterm-desktop/lib` did in Dart, ported to Swift. macOS only
(every file is inside `#if os(macOS)`, so the package still builds for iOS). The SwiftUI app
(`apps/pocketterm-desktop/macos/`) builds its windows on this; nothing here draws.

Stateful services are `@MainActor`. Observable ones are `ObservableObject`s (macOS 13 has no Observation): bind
views to their `@Published` properties, and re-read computed ones (preferences) on `objectWillChange`.

## Wiring at launch (what `lib/main.dart` did)

```swift
migrateFlutterPreferences()                         // flutter.<key> → <key>, once
let prefs = UserDefaultsPreferenceStore()
let host = MacHost(showWindow: { … }, hideWindow: { … }, mainWindow: { … })
let app = AppController(prefs: prefs, device: await host.deviceName(), host: host)
let api = LocalApi(live: app.live)
do { try await api.start(); app.onQuit = { await api.stop() } }
catch { /* "terminal API unavailable": the app still runs */ }
await app.start()                                    // after the UI is up
```

- Theme: PocketTermKit's `Appearance` (preference key `theme`); follow it into the Dock icon with
  `followAppIcon(appearance) { await host.setAppIcon($0) }`.
- Every URL the app is opened with (`pocketterm://setup?…`) goes to `app.openedLink(_:)`.
- `NSApplicationDelegate.applicationShouldTerminate` → `await host.quitting()` (waits ≤ 1 s for `onQuit` and the
  built-in server), the window's close → `host.windowClosed()`, the menu-bar item / Dock / ⌘, →
  `host.event("openMain" | "openSettings")`.
- Bundle resources the services read: `Contents/Helpers/pocketterm-server` (`tool/server-sidecar.sh`),
  `Resources/integrations` (← `apps/pocketterm-desktop/integrations/`), `Resources/supabase`
  (← `apps/pocketterm-desktop/supabase/`), `Resources/icon/macos-<theme>.png` (← `assets/icon/`).

## Services

### `AppController` (controller.dart) — `Session` subclass, the app's model

Everything a screen shows or does goes through it. Window routing (main_window.dart): `backend == nil` → setup
wizard; `user == nil` → sign-in; `!getReadyDone` → Get ready; else Settings. `linkToConfirm` → the confirm-link
dialog; `notices` → the `link-notice` banner.

| Member | Kind | Flutter screen |
|---|---|---|
| `backend`, `user`, `authError`, `retryLink`, `linkToConfirm`, `signedOutReason` (from `Session`) | `@Published` | MainWindow routing, sign-in, ConfirmLink |
| `connectLink(_:)`, `answerLink(connect:)`, `retry()`, `signOut()`, `disconnect()`, `eraseServer()`, `userName`, `notices` | Session | setup link form, Account tab, Sign out / Erase dialogs |
| `mainShown` (ticks per show), `mainHidden` | `@Published` | Settings re-checks on each show; Get ready keeps polling 10 min after hide |
| `openMain()` | async | any "bring the window up" |
| `terminalOn`, `setTerminal(on:)` | computed / async throws | Phone tab → Terminal from phone (`settings-terminal-from-phone`) |
| `terminalBridge` (`clockOff`), `phoneClockOff` | computed | status bar "A phone's clock is … minutes behind/ahead" |
| `phoneSignedIn: Bool?`, `checkPhone()` | computed / async | Phone tab "Your phones", Get ready step 4, attention "No phone yet" |
| `pairingLink()` | async throws `PairingException` | Add a phone… (pairing QR, 10-min code) |
| `resetChannelKey()` | async throws | Reset key… |
| `channelKey()`, `desktopId(_:)`, `pairingComputer()` | | QR contents |
| `agents: [Agent: AgentCheck]?`, `ompProfiles`, `checkAgents()`, `installAgent(_:)` | `@Published` / async | Coding agents tab, Get ready step 1 |
| `unreportedAgentWindows(_:)` | | "N sessions to reopen/reload" |
| `codingAgent` / `setCodingAgent(_:)` | prefs `coding_agent` | Make default |
| `terminalApp` / `setTerminalApp(_:)` | prefs `terminal_app` ("auto") | Terminals tab → New sessions open in |
| `placement` / `setPlacement(_:)` | prefs `session_placement` | Terminals tab → Place them |
| `projectRoots` / `setProjectRoots(_:)` | prefs `project_roots` | Phone tab → Project folders, Get ready step 3 |
| `setupStep` / `setSetupStep(_:)`, `setupAddress` / `setSetupAddress(_:)` | prefs | setup wizard position, VPS address |
| `getReadyDone` / `setGetReadyDone(_:)` | prefs | Get ready Done / "Open setup checklist" |
| `launchAtLogin: Bool?`, `refreshLaunchAtLogin()`, `setLaunchAtLogin(on:)` (throws the System Settings hint) | `@Published` / async | Account tab → Launch at login |
| `hosting: BuiltInServer?`, `hostsServer`, `startHosting()`, `ownServerPorts`, `computerSetupLink()` | `@Published` / async | On this computer → Start, Account → Your server, Add a computer… |
| `serverDevices()`, `revokeServerDevice(_:)` | async throws | Account → phones, Sign out… |
| `terminals: Terminals`, `live: LiveHub`, `integrations`, `commands`, `tailscale`, `host` | | cards that ask them directly |
| `notifyPhone(_:_:session:activity:)` | async → Bool | (internal use: a run finished / needs you while idle ≥ 60 s) |
| `onQuit` | closure | set to `LocalApi.stop` |
| `shutDown()` | async | e2e: a second app in the same process |

Behaviour kept from Dart: the first sign-in turns on Terminal from phone once (`first_sign_in_done`), never a login
item; the bridge restarts on user change and is serialised; `putDesktop` every 60 s while bridging; signing out
deletes the computer from the list; a built-in server starts at launch while `hosting` is set and signs in with its
own setup link; a failed sign-in (locked Keychain) undoes Start.

### `LocalApi` (local_api.dart)

`LocalApi(live:file:)`, `start() async throws`, `stop() async`, `port`, `file`. 127.0.0.1 on a random port (swift-nio),
`~/.config/pocketterm/cli.json` (`{port, token, pid}`, folder 700, file 600; `POCKETTERM_CLI_JSON` in test builds),
`GET /v1/ping[?nonce]`, `GET /v1/live` (WebSocket, omp), `POST /v1/live/http` (long poll, Claude Code), the 5 s
reclaim watcher. No UI; the app starts it at launch.

### `LiveHub` / `LiveSession` / `LiveEvent` (live_hub.dart), `PromptFiles`, Orchestrator

The coding sessions the integrations report. `sessions`, `subscript(key)`, `changes`/`ops`/`events` streams,
`projectName(_:)`, `prompt(…)`, queue edits (`editQueued`, `removeQueued`, `moveQueued`, `sendQueuedNow`,
`pauseQueue`), `abort`, `older`. Settings reads `sessions` (via `unreportedAgentWindows`); the phone drives the rest
through the bridge. `orchestratorInstructions`, `sessionsText`, `transcriptText` are the orchestrator's text.

### `TerminalBridge` (terminal_bridge.dart)

Built by `AppController` while Terminal from phone is on; the UI only reads `app.terminalBridge?.clockOff`. It holds
the keep-awake assertion (`host.setKeepAwake(on:)`) while it runs.

### `BuiltInServer`, `HostState` (hosting/built_in_server.dart), `Tailscale`, `Vps`

| Member | Flutter screen |
|---|---|
| `state` (`checking`, `noTailscale`, `tailscaleOff`, `loggedOut`, `httpsOff`, `failed`, `taken`, `ready`), `error`, `publicUrl`, `enableHttps`, `refresh()` | HostingStatusView (Account tab, Get ready step 4, attention items) |
| `renamedFrom`, `renameSeen()` | `hosting-renamed` banner |
| `port`, `running`, `backend` | Account → Your server |

`Tailscale`: `status()` → `TailscaleStatus` (installed / running / signed in / HTTPS, `url`), `port443(ports)` →
`Serving`, `enableHttpsLink(port:)`, `open()`, `Tailscale.download` — the On this computer checklist
(`check-installed` … `check-serve-free`). `Vps`: `ServerAddress.parse(_:)`, `vpsCommands(_:_:)`, `composeUrl(_:)`,
`NetworkServerChecks` (`check-dns`, `check-https`, `check-health`) — the New server screen.
`setupLinkProblem(_:)` (SetupLinks.swift) — the setup link form's checks.

### `Commands` (commands.dart)

`brew`, `macPorts`, `run(_ argv:password:)` → `CommandResult`, `Commands.tmuxInstall`, `Commands.tailscaleInstall` —
ConfirmedCommand dialogs (`command-run`, `command-done`, `command-failed`), the tmux and Tailscale install offers.

### `SupabaseAdmin`, `SupabaseSetup` (onboarding/supabase_admin.dart, supabase_setup.dart)

The Supabase wizard: `SupabaseAdmin(token)` (`organizations`, `projects`, `createProject`, …), `SupabaseSetup.run
(onStep:onWait:done:)` with `SupabaseStep` names/labels (`supabase-step-<name>`), `supabaseRegions`, migrations and
the function from `Resources/supabase`. The access token is never stored.

### `Integrations` (integrations.dart)

`found`, `state`, `install`, `claudeModsOff`, `ompProfiles`, `Integrations.name(_:)`, `modsOffHint`, `noAnswer` —
Coding agents tab, Get ready step 1, confirm-install dialogs (via `AppController.installAgent`).

### `TerminalFixes` (terminal_fixes.dart)

`fixTerminal(_:_:)` → `TerminalFixResult`, `terminalsNeedingSetup(_:)`, `noTerminalApp(_:)` — Terminals tab
`settings-fix-<id>`, Get ready step 2, attention items.

### Storage: `SystemSecrets`, `KeychainStore`, `ChannelKeys`, `SecretDeviceTokens`, `UserDefaultsPreferenceStore`

Secrets stay in the same login-Keychain items flutter_secure_storage wrote (service `PocketTerm`, accounts
`device_token` and `channel_key_<desktop id>`), so an upgrade needs no secret migration. `POCKETTERM_PROFILE` (test
builds) keeps them in memory. Preferences: `migrateFlutterPreferences()` copies `flutter.<key>` once (marker
`flutter_preferences_migrated`).

### `MacHost: DesktopHost` (desktop_host.dart + MainFlutterWindow.swift)

`showMain`/`hideMain` (activation policy `.regular` / `.accessory`: the Dock icon only while the window shows),
`quit`, `deviceName`, `idleSeconds` (CGEventSource), `launchAtLogin`/`setLaunchAtLogin(on:)` (SMAppService, with
`MacHost.loginItemsHint`), `pickFolders` (NSOpenPanel), `setKeepAwake(on:)` (IOPM assertion, instead of
`caffeinate`), `setAppIcon(_:)`. The app reports `event(_:)`, `windowClosed()`, `quitting()`.

### Test hooks (test_hooks.dart)

`testBuild` is true in DEBUG builds and with `-D POCKETTERM_SMOKE`; only then `testHooks()` reads
`POCKETTERM_TAILSCALE`, `POCKETTERM_CLI_JSON`, `POCKETTERM_KITTY_DIR`, `POCKETTERM_PROFILE`.
