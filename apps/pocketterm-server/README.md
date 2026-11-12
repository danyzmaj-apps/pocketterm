# PocketTerm server

The server built into the PocketTerm desktop apps (Mac, Windows). The app runs it as a child process on
127.0.0.1 and publishes it to the owner's tailnet with `tailscale serve`; it never listens on another address.

It does pairing, the list of your computers, the live channel between a computer and its phones, images and files
on their way from phone to computer, and push notifications. It serves one owner. Everything between a computer
and a phone is end-to-end encrypted by the apps, so the server only ever passes on ciphertext.

The protocol is in [packages/pocketterm_server/PROTOCOL.md](../../packages/pocketterm_server/PROTOCOL.md).

## How the apps run it

```sh
pocketterm-server serve --data <app support>/pocketterm-server --address 127.0.0.1 --port <port> \
  --trust-loopback-proxy --exit-with-stdin [--relay <url> --relay-key <base64>]
```

- `<port>` is the port the server had last time, else `0` (the system picks a free one).
- `serve` writes exactly one line to stdout once it listens:
  `{"event":"listening","address":"127.0.0.1","port":47900}`. Its log goes to stderr. The app reads the port from
  that line and talks to the server at `http://127.0.0.1:<port>`.
- Exit codes: `0` stopped (SIGINT/Ctrl+C, SIGTERM, closing the Windows console, or stdin closing with
  `--exit-with-stdin`), `1` didn't start, `98` the port is taken (the app starts it again with `--port 0`),
  `64` bad options.
- The app keeps the child's stdin open and closes it to stop the server, so the server also stops (and frees the
  data folder) when the app dies.
- Requests from `tailscale serve` arrive from 127.0.0.1 with the caller in `X-Forwarded-For`, hence
  `--trust-loopback-proxy`: each tailnet caller gets its own pairing throttle. Callers that don't come through a
  proxy on this machine are counted by their own address.

Setup links (the app's own, and the one **Settings → Account → Add a computer…** shows) come from:

```sh
pocketterm-server setup-link --data <same folder> --public-url https://<computer>.<tailnet>.ts.net [--new]
```

It prints only the link and works while a server runs on the same folder. `--new` replaces the setup token first:
the old link stops working, computers already signed in stay signed in.

`pocketterm-server health` exits 0 when the server on this machine answers `GET /v1/health`.

## Where the apps bundle it

- macOS: `PocketTerm.app/Contents/Helpers/pocketterm-server`
- Windows: `pocketterm-server.exe`, next to the app's exe

## Build it

From the repository root:

```sh
tool/server-sidecar.sh [--out <dir>]          # build/server-sidecar/<os>-<arch>/pocketterm-server(.exe)
pwsh tool/server-sidecar.ps1 [-Out <dir>]     # Windows runners: build/server-sidecar/windows-<arch>/pocketterm-server.exe
```

On macOS it builds arm64; with `DART_X64=/path/to/x86_64/dart` (an Intel Dart SDK, run under Rosetta) it also
builds x86_64 and joins both into `build/server-sidecar/macos-universal/pocketterm-server` with `lipo`.

## Run it by hand

For development, from the repository root:

```sh
fvm dart run apps/pocketterm-server/bin/pocketterm_server.dart serve --data <tmp> --port 0
fvm dart run apps/pocketterm-server/bin/pocketterm_server.dart setup-link --data <tmp> --public-url http://127.0.0.1:<port>
```

## Options

Every option also reads an environment variable; `pocketterm-server help` lists them.

| Flag | Environment | Default | |
|---|---|---|---|
| `--data` | `POCKETTERM_DATA` | `./data` | where everything is kept |
| `--public-url` | `POCKETTERM_PUBLIC_URL` | required for `setup-link`; `serve`: `http://<address>:<port>` | the address put in setup links, like `https://mac.tail1234.ts.net` |
| `--port` | `POCKETTERM_PORT` | `47900` | `serve`, `health`: the port; `serve`: `0` lets the system pick a free one |
| `--address` | `POCKETTERM_ADDRESS` | `127.0.0.1` | `serve`, `health`: the loopback address to listen on (any other is refused) |
| `--relay` | `PUSH_RELAY_URL` | the publisher's relay | `serve`: where push notifications are sent |
| `--relay-key` | `PUSH_RELAY_KEY` | the publisher's relay's | `serve`: the relay's X25519 public key (base64); every push is sealed to it |
| `--trust-loopback-proxy` | `POCKETTERM_TRUST_LOOPBACK_PROXY=1` | off | `serve`: rate limit by the last `X-Forwarded-For` address for connections from a loopback address (a proxy on this machine, like `tailscale serve`) |
| `--exit-with-stdin` | | off | `serve`: stop when stdin closes, so the server never outlives the app that started it |
| `--new` | | off | `setup-link`: replace the setup token first |

## Its data folder

`<app support>/pocketterm-server` in the apps. In it:

- `state.json`: devices with the SHA-256 of their tokens, computers, pairing codes, push tokens. Rewritten atomically
  on every change, with the state before the last change in `state.json.bak`.
- `setup-token`: what the setup link carries.
- `.lock`: held while a server runs. One server per folder: a second one on the same folder refuses to start.
- `blobs/`: sealed images and files waiting for their computer, at most 1 GiB (200 MiB per device), deleted once
  downloaded or after an hour.

A `state.json` that doesn't read (edited by hand, a broken disk) is never replaced by an empty one: the server
starts from `state.json.bak` and keeps the bad file as `state.json.corrupt-<time>`, or, without a usable backup,
refuses to start and says so in its log.

To back it up or move it to another computer, quit PocketTerm, copy the folder, and copy it back the same way. The
copy holds the setup token and every device's token hash: keep it as private as the setup link. Without a backup,
a lost folder means every computer opens a new setup link and every phone scans a new code.

Push notifications go to the publisher's relay ([apps/pocketterm-relay](../pocketterm-relay/README.md)), which
holds the Apple and Google keys and sees only the phone's push token and the encrypted text.

## Error reports

Off by default. With `POCKETTERM_SENTRY_DSN` set in its environment (the desktop app passes its own on), the server
sends its crashes, its 500s and unexpected start failures to that Sentry-compatible service (GlitchTip, Sentry),
tagged `component=server`. `POCKETTERM_SENTRY_ENVIRONMENT` (default `production`) and `POCKETTERM_SENTRY_RELEASE`
(default `pocketterm-server@<version>`) label them. The SDK's own `SENTRY_DSN`, `SENTRY_ENVIRONMENT`,
`SENTRY_RELEASE` and `SENTRY_DIST` are ignored, so a developer's Sentry setup never turns PocketTerm's reports on.
A report holds the error's type, its message and stack; URLs, IP addresses, tailnet/LAN host names, email addresses
and the home folder are blanked out of the message, cut to 300 characters. No log lines, requests, host name, user or
data folder contents are sent.

## When something is wrong

The server's log (stderr) says most of it; the desktop app shows the line that made it stop.

| What you see | Why, and what to do |
|---|---|
| `The server didn't start: Can't write to the data folder …` | The user the app runs as can't write to the data folder: fix its owner and permissions, or free disk space. |
| `The server didn't start: Another PocketTerm server is using …. Stop it first.` | Another server holds `.lock` on this folder: quit the other PocketTerm (or a `serve` you ran by hand on the same folder). |
| `The server didn't start: …state.json doesn't read … and there is no usable …state.json.bak` | Quit PocketTerm and restore the data folder from a backup, or move `state.json` away to start over (every device then signs in again). |
| `The server didn't start: …state.json is missing and …state.json.bak doesn't read` | The same: restore from a backup, or remove `state.json.bak` to start over. |
| The app: "The server couldn't save this" (507) | The disk is full or the folder isn't writable. Nothing is lost that was saved before. |
| "Too many tries from this network" when pairing | 10 wrong codes from one address in 10 minutes. Wait, or restart PocketTerm to clear it. |
| Pushes don't arrive | The log shows `relay …` lines when the push relay can't be reached or turns a push away (it retries for 2 minutes). |
