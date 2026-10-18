# pocketterm_core

Dart and Flutter code shared by the desktop app and the phone app: the connected backend and sign-in (`session.dart`, `backend.dart`, `account.dart`), the account's computers (`desktops.dart`), the terminal protocol, channel and remote (`live.dart`, `terminal_*.dart`), the terminal hosts (`terminal.dart`, `terminals.dart`, `kitty.dart`, `tmux.dart`, `wezterm.dart`, `iterm.dart`, `apple_terminal.dart`, `ghostty.dart`), followed sessions (`live_activity.dart`), the `pocketterm/native` platform channel (`native.dart`) and shared UI.

Not published to pub.dev; it is a member of the repo's pub workspace. Test it from this directory:

```sh
fvm flutter test
```

See [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md).
