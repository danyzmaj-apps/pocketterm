# pocketterm_core

Dart and Flutter code shared by the desktop app and the phone app:

| File | What |
| --- | --- |
| `session.dart`, `backend.dart`, `connect.dart`, `account.dart` | The connected server and signing in, setup links, connecting to an existing server, the sign-in page and avatar |
| `server_client.dart` | The PocketTerm server's API ([PROTOCOL.md](../pocketterm_server/PROTOCOL.md)) for one signed-in device |
| `e2e.dart` | End-to-end encryption between a computer and its phones (AES-256-GCM, one channel key per computer) |
| `desktops.dart` | The account's computers |
| `agent.dart` | The coding agents (omp, Claude Code): new sessions, names, steering, answers as keys |
| `live.dart`, `terminal_channel.dart`, `terminal_remote.dart` | The terminal protocol, its channel over the server's live connection and the phone's remote for one computer |
| `terminal.dart`, `terminals.dart` | The terminal layer (`TerminalHost`, `TermWindow`, `TermCap`, `TermStatus`) and every installed terminal as one |
| `kitty.dart`, `tmux.dart`, `wezterm.dart`, `ghostty.dart`, `ghostty_config.dart` | One `TerminalHost` per terminal; Ghostty's config for opening new windows in tmux |
| `live_activity.dart` | Followed sessions (Live Activities on iOS, ongoing notifications on Android) |
| `ansi.dart`, `chat_images.dart` | Screen lines with ANSI colors; images for prompts |
| `native.dart` | The `pocketterm/native` platform channel |
| `ui.dart`, `logo.dart` | Shared UI and the logo |

Not published to pub.dev; it is a member of the repo's pub workspace. Test it from this directory:

```sh
fvm flutter test
```

See [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md).
