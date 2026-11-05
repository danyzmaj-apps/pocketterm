# PocketTerm.Desktop.Core

The Windows app's services without UI: what `apps/pocketterm-desktop/lib` was for the Flutter
desktop app, minus its widgets. `net8.0`, so it builds and its tests run on macOS too; the
Windows-only parts (registry, DPAPI, Job Objects, power requests, `GetLastInputInfo`) carry
`[SupportedOSPlatform("windows")]` and their callers check `OperatingSystem.IsWindows()`.
It builds on `PocketTerm.Core` (protocol, crypto, server clients, `Session`, live models,
terminal model types). Everything is in the `PocketTerm.Desktop` namespace.

```sh
~/.dotnet/dotnet test apps/pocketterm-desktop/windows/PocketTerm.sln
# with the real built-in server (the sidecar) too:
tool/server-sidecar.sh --out /tmp/sidecar
POCKETTERM_SERVER_BIN=/tmp/sidecar/<platform>/pocketterm-server ~/.dotnet/dotnet test apps/pocketterm-desktop/windows/PocketTerm.sln
```

Windows-only tests skip elsewhere; the sidecar tests (`SidecarFact`) skip without
`POCKETTERM_SERVER_BIN` (or `POCKETTERM_INTEROP=1`, which builds the sidecar once per run).

## Threading

The Flutter app ran on one isolate; here Kestrel requests, timers and the live channel's reader
call in on pool threads. Each service guards its own state with a lock that is never held across
an `await`, and raises its events after releasing it. `PropertyChanged` (every `ObservableObject`,
an empty property name meaning "anything may have changed") and every event fire on whatever
thread changed the state: **the WinUI app marshals to its dispatcher**.

## What the app wires at launch

What `lib/main.dart` did, in this order:

```csharp
var env = TestHooks.Env();                      // the e2e/smoke hooks; empty in a release build
var secrets = SystemSecrets.Create(env);        // DPAPI file, or memory for a throwaway POCKETTERM_PROFILE
var prefs = new JsonPreferenceStore();          // <SupportDir>\preferences.json
await FlutterMigration.RunAsync(AppPaths.SupportDir, prefs,
    SystemSecrets.IsThrowaway(env) ? null : secrets, new DpapiProtector());  // once: Flutter 0.1.x → native
var host = new WinUiDesktopHost(...);           // the app's IDesktopHost (window, tray, WindowsSystem)
var app = new AppController(prefs, await host.DeviceNameAsync(), host, secrets: secrets, updates: new UpdateCheck());
var api = new LocalApi(app.Live);
try { await api.StartAsync(); app.OnQuit = api.StopAsync; }
catch (Exception e) { Log.Print($"PocketTerm: terminal API unavailable: {e.Message}"); }
await app.Start();                              // the host starts, the built-in server, the saved sign-in
// pocketterm:// activations (first launch and redirected ones): app.HandleLink(uri)
```

Bundled next to the exe (`AppPaths.BaseDir`, `AppContext.BaseDirectory` by default):
`pocketterm-server.exe` (tool/server-sidecar.ps1), `integrations\` (from
`apps/pocketterm-desktop/integrations`: `omp`, `claude/.claude-plugin`,
`claude/plugins/pocketterm/.claude-plugin`, `claude/plugins/pocketterm/hooks`) and `supabase\`
(from `apps/pocketterm-desktop/supabase`: `migrations\`, `functions\`).

## Services

| Service | Owns | Observable state | Commands | Flutter screen that used it |
|---|---|---|---|---|
| `AppController : Session` (AppController.cs) | the sign-in (Core `Session`), the built-in server's lifetime, desktop id per server, channel key, terminal bridge lifecycle, sealed pushes, coding agents found, phone-signed-in detection, every preference | `User`, `Backend`, `Server`, `AuthError`, `RetryLink`, `SignedOutReason`, `LinkToConfirm(Host)`, `TerminalOn`, `TerminalApp`, `Placement`, `ProjectRoots`, `CodingAgent`, `SetupStep`, `SetupAddress`, `GetReadyDone`, `LaunchAtLogin`, `CodingAgents` (`AgentCheck` per agent), `OmpProfiles`, `PhoneSignedIn`, `PhoneClockOff`, `Hosting`, `HostsServer`, `OwnServerPorts`, `MainShown`, `MainHidden`, `Updates`; events `Notices` | `Start`, `HandleLink`, `ConnectLink`, `AnswerLink`, `Retry`, `SignOut`, `Disconnect`, `EraseServer`, `PairingLink`, `ComputerSetupLinkAsync`, `StartHostingAsync`, `SetTerminalAsync`, `ResetChannelKeyAsync`, `Set…` for each preference, `SetLaunchAtLoginAsync`/`RefreshLaunchAtLoginAsync`, `CheckAgentsAsync`, `InstallAgentAsync`, `CheckPhoneAsync`, `ServerDevicesAsync`, `RevokeServerDeviceAsync`, `UnreportedAgentWindows`, `NotifyPhoneAsync`, `OpenMainAsync`, `ShutDownAsync`; `OnQuit` | everything: main_window (Settings tabs), setup_page, get_ready, pair |
| `IDesktopHost` (IDesktopHost.cs) | implemented by the app: window, tray (Open PocketTerm, Settings…, Update available…, Quit), idle seconds, keep awake, launch at login, folder picker, app icon | — | events to the controller: `openMain`, `openSettings`, `mainClosed`, `quitting` | windows_host.dart |
| `WindowsSystem` (Platform/) | `IdleSeconds` (GetLastInputInfo), `SetKeepAwake` (power request), launch at login (Run key `PocketTerm` = `"<exe>" --hidden` + `StartupApproved\Run`, as launch_at_startup 0.5.1), `EnsureStartupApproved`, `RegisterLink` (HKCU `pocketterm://`), `FreshWindowsPath`, `StartedHidden(args)` | — | statics | windows_host.dart |
| `AppPaths` (Platform/) | `SupportDir` = `%APPDATA%\Danijel Lovric\PocketTerm` (the Flutter app's, so the built-in server's data and the stores survive the upgrade), `ServerDataDir`, `BaseDir`, `IntegrationsDir` | — | — | path_provider |
| `JsonPreferenceStore`, `DpapiSecureStore`, `SystemSecrets`, `FlutterMigration` (Storage/) | preferences (`preferences.json`), secrets (`secrets.dat`, DPAPI CurrentUser), the one-time migration from Flutter's `shared_preferences.json` (`flutter.` keys) and `flutter_secure_storage.dat` | — | `RunAsync` | shared_preferences, flutter_secure_storage |
| `ChannelKeys`, `SecretDeviceTokens` (Storage/) | this computer's channel key per desktop id (`channel_key_<id>`), the sign-in (`device_token`) | — | `OfAsync`, `ResetAsync` | channel_keys.dart (Settings → Phone → Reset key) |
| `Integrations` (Integrations/) | finding omp / Claude Code, installing or updating the bundled omp extension and Claude plugin, `ClaudeModsOffAsync`, `OmpProfiles` | — | `FoundAsync`, `StateAsync`, `InstallAsync`; `IntegrationOf(AgentCheck)` | Settings → Coding agents, get_ready, confirm_install |
| `LiveHub` (Live/) | the coding sessions reporting to the local API: hello/meta/items/asks, prompt queues (20 at most, text caps, hand-off at run end), orphans, orchestrator calls, prompt files and images | `Sessions`, `this[key]`; events `Ops`, `Changes`, `Events` (`LiveFinished`, `LiveAsked`) | `PromptAsync`, `EditQueued`, `RemoveQueued`, `MoveQueued`, `PauseQueue`, `SendQueuedNowAsync`, `AbortAsync`, `OlderAsync`, `UpdateAsk`, `RelinkAsync` | (no screen: the bridge and notifications) |
| `LocalApi` (Live/) | Kestrel on 127.0.0.1 (random port), `cli.json` in `%USERPROFILE%\.config\pocketterm\` (or `POCKETTERM_CLI_JSON`), `/v1/ping` proof, `/v1/live` WebSocket, `/v1/live/http` long poll, reclaiming cli.json | `Port`, `File` | `StartAsync`, `StopAsync` | main.dart |
| `Orchestrator`, `PromptFiles` (Live/) | the orchestrator session's folder and texts; files sent with prompts | — | statics / `SaveAsync`, `PruneAsync` | (bridge) |
| `TerminalBridge` (Bridge/) | the phone's view of this computer on the `<desktop id>` topic: state, screens, ops, activities, asks/menus, every `run` op; keep-awake while on | `ClockOff`, `Watching(session)` | `StartAsync`, `StopAsync` (the controller runs it) | Settings → Terminal from phone |
| `Terminals`, `WezTerm` (Terminals/) | WezTerm (`wezterm cli` per GUI socket), the window list, statuses, locate, send/type/keys/close, launch with placement, projects | `Problems` | `WindowsAsync`, `StatusesAsync`, `LaunchAsync`, `ProjectsAsync`, `CreateProject`, … | Settings → Terminals, terminals_card |
| `WezTermSetup` (Terminals/) | downloading WezTerm's installer from its GitHub release, SHA-256 check, running it, waiting for the install | `State`, `Progress`, `Error`, `Note`, `Installed` | `InstallAsync`; `ForHost(WezTerm?)` | get_ready's WezTerm card, Settings' Install fix |
| `TerminalFixes`, `ProjectFolders` (Terminals/) | fixes for terminal statuses, which terminals need setup; project folder suggestions | — | statics | main_window attention items, get_ready |
| `BuiltInServer` (Hosting/) | the bundled sidecar (`serve --exit-with-stdin`, port retry on exit 98, `setup-link`), Tailscale Serve, the hosting status | `Running`, `Port`, `Backend`, `PublicUrl`, `TailscaleStatus`, `State` (`HostState`), `Status` (`HostStatus`: text, ok, actions), `EnableHttps`, `HttpsPage`, `Error`, `RenamedFrom` | `StartAsync`, `RefreshAsync`, `StopAsync`, `SetupLinkAsync`, `OwnSetupLinkAsync`, `RenameSeen` | setup_page ("This computer"), Settings → Account, hosting_view |
| `Tailscale` (Hosting/) | the Tailscale CLI (Program Files, PATH, `POCKETTERM_TAILSCALE`) | — | `StatusAsync`, `ServeAsync`, `UnserveAsync`, `EnableHttpsLinkAsync`, `OpenAsync` | hosting_view |
| `Vps`, `ServerAddress`, `ServerChecks` (Hosting/) | the own-server (VPS) setup: compose commands, address parsing, DNS/HTTPS/health checks | — | statics, `ResolvesAsync`, `HttpsAsync`, `AnswersAsync` | setup_page (Your own server) |
| `Commands` (Setup/) | winget installs the setup offers | — | `RunAsync` | commands_view |
| `SupabaseAdmin`, `SupabaseSetup`, `SupabaseFlow` (Setup/) | the Supabase Management API, migrations/function from the bundled `supabase\`, the setup flow (org, region, project, keys, deploy, sign-in) | `SupabaseFlow`: `Stage`, `Busy`, `Error`, `Orgs`, `Org`, `Region`, `Existing`, `CanCreate`, `Waiting`, `Ref` | `ContinueAsync`, `PickOrgAsync`, `CreateAsync`, `UpdateAsync`, `SetUpAsync`, `Back`, `Drop` | supabase_view |
| `SetupLinks` (Setup/) | what's wrong with a pasted setup link | — | `Problem(text)` | setup_page |
| `UpdateCheck` (UpdateCheck.cs) | GitHub's latest release, every 24 h | `Update` (`UpdateInfo`) | `Start`, `CheckAsync` | Settings, tray "Update available…" |
| `TestHooks` (TestHooks.cs) | `E2E` builds (Debug, or `-p:PocketTermE2E=true`) read `POCKETTERM_TAILSCALE`, `POCKETTERM_CLI_JSON`, `POCKETTERM_KITTY_DIR`, `POCKETTERM_PROFILE` | — | `Env()` | test_hooks.dart |

## Deliberate differences from the Flutter app

- The built-in server is the bundled sidecar process instead of running in the app; its setup
  links come from `pocketterm-server setup-link`, so `SetupLinkAsync`/`OwnSetupLinkAsync` and
  `ComputerSetupLinkAsync` are async. On Windows the sidecar is in a kill-on-close Job Object.
- Keep-awake uses a power request (`PowerSetRequest`) so it holds whichever thread asks.
- New store files (`preferences.json`, `secrets.dat`) next to Flutter's, which stay untouched;
  the migration runs once.
- `UpdateCheck` is passed in by the app (Flutter made one on Windows itself) and sends a
  `User-Agent`, which GitHub's API requires.
- Only WezTerm is a terminal host (the Mac-only kitty, tmux, iTerm2 and Ghostty hosts aren't here).
- `LiveHub.MoveQueued` can move a prompt to the last place (Dart's clamp couldn't, and lost a
  lone prompt).
