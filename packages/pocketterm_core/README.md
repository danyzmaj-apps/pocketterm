# pocketterm_core

Dart and Flutter code shared by the desktop app and the phone app:

| File | What |
| --- | --- |
| `session.dart`, `backend.dart`, `connect.dart`, `account.dart` | The connected server and signing in, setup links, confirming a link to another server, the sign-in page and avatar |
| `server_client.dart`, `supabase_server.dart` | The PocketTerm server's API ([PROTOCOL.md](../pocketterm_server/PROTOCOL.md)) for one signed-in device; the same on a Supabase project, with the live channel on Supabase Realtime |
| `e2e.dart` | End-to-end encryption between a computer and its phones (AES-256-GCM, one channel key per computer) |
| `desktops.dart` | The account's computers |
| `agent.dart` | The coding agents (omp, Claude Code): new sessions, names, steering, answers as keys |
| `live.dart`, `terminal_channel.dart`, `terminal_remote.dart` | The terminal protocol, its channel over the server's live connection and the phone's remote for one computer |
| `terminal.dart`, `terminals.dart` | The terminal layer (`TerminalHost`, `TermWindow`, `TermCap`, `TermStatus`) and every installed terminal as one |
| `kitty.dart`, `tmux.dart`, `wezterm.dart`, `ghostty.dart`, `ghostty_config.dart` | One `TerminalHost` per terminal; Ghostty's config for opening new windows in tmux |
| `live_activity.dart` | Followed sessions (Live Activities on iOS, ongoing notifications on Android) |
| `ansi.dart`, `chat_images.dart`, `file_types.dart` | Screen lines with ANSI colors; the images and files a prompt takes (up to 10, files up to 20 MB) and their types |
| `native.dart` | The `pocketterm/native` platform channel |
| `ui.dart`, `logo.dart` | Shared UI and the logo |
| `timing.dart` | Debug builds only: connection timings for the end-to-end run's report |

Not published to pub.dev; it is a member of the repo's pub workspace. Test it from this directory:

```sh
fvm flutter test
```

With PocketTerm running on a local Supabase ([apps/pocketterm-desktop/supabase](../../apps/pocketterm-desktop/supabase/README.md#running-it-locally)), the client tests also run against it, one file at a time:

```sh
POCKETTERM_SUPABASE=1 fvm flutter test -j 1 test/server_client_test.dart test/session_test.dart
```

See [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md).
