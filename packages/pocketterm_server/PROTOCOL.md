# PocketTerm server protocol, version 1

The PocketTerm server serves one owner: their computers (role `desktop`) and their phones (role `phone`).
It relays what the apps send without reading it: live channel payloads, images and notification text are
end-to-end encrypted by the apps (see the envelope in `pocketterm_core/lib/e2e.dart`).

Everything lives under `<url>/v1/`, where `<url>` is the server's public URL (`https://pt.example.com`,
`http://100.101.102.103:47900`, …), with no trailing slash.

## Conventions

- Requests and responses are JSON (`content-type: application/json; charset=utf-8`), except blob bodies.
- Times are ISO 8601 in UTC with milliseconds: `"2026-10-22T09:15:00.000Z"`.
- Authenticated endpoints take `Authorization: Bearer <device token>`. Only `GET /v1/health`,
  `POST /v1/setup/redeem` and `POST /v1/pair/redeem` work without one.
- A JSON request body is at most 65536 bytes (64 KiB); a missing or empty body reads as `{}`.
- Unknown fields in a request are ignored; clients should ignore unknown fields in responses.

### Errors

Every error is an HTTP status of 400 or more with this body:

```json
{"error": "<code>", "message": "<a sentence a person can read>"}
```

| Status | `error`              | When                                                                      |
|--------|----------------------|---------------------------------------------------------------------------|
| 400    | `bad_request`        | malformed JSON or a field that fails validation (the message names it)    |
| 400    | `invalid_code`       | a setup token or pairing code that doesn't work (any reason, same answer) |
| 401    | `unauthorized`       | no `Authorization` header, or the token is unknown or revoked             |
| 403    | `forbidden`          | the device's role can't do this (a phone making a pairing code)           |
| 404    | `not_found`          | no such endpoint, device or blob (a blob that ran out or was downloaded)  |
| 405    | `method_not_allowed` | the endpoint exists, the method doesn't                                   |
| 409    | `conflict`           | a blob path that is already taken                                         |
| 413    | `too_large`          | a body over its limit                                                     |
| 429    | `rate_limited`       | too many failed redeems from this address; `Retry-After` gives seconds    |
| 500    | `internal`           | a bug on the server                                                       |

## Objects

**Device**: a signed-in computer or phone.

```json
{"id": "k3v9x0q2m7d1a8bz", "role": "desktop", "label": "Dany's MacBook", "platform": "macos",
 "created_at": "2026-10-22T09:15:00.000Z", "seen_at": "2026-10-22T09:20:00.000Z"}
```

- `id`: 16 characters `[a-z0-9]`, made by the server.
- `role`: `desktop` | `phone`.
- `label`: at most 80 characters, may be empty.
- `platform`: `macos` | `windows` | `linux` for a desktop, `ios` | `android` for a phone.
- `seen_at`: the last authenticated request or WebSocket connect (kept to the minute).

**Desktop**: a computer as phones list it.

```json
{"id": "a1b2c3d4", "name": "MacBook Pro", "platform": "macos", "seen_at": "2026-10-22T09:20:00.000Z", "online": true}
```

- `id`: the computer's own 8-character id `[a-z0-9]{8}`, the live channel topic.
- `name`: at most 80 characters. `platform`: `macos` | `windows` | `linux`.
- `online`: `seen_at` is less than 150 seconds old by the server's clock (a computer stamps it every 60 seconds).

## Setup link and tokens

On first start the server makes a **setup token** (43 characters, base64url) and prints a setup link for computers:

```
pocketterm://setup?url=<public url>&setup=<setup token>
```

The setup token is reusable (every computer of the owner redeems it) until the owner replaces it
(`pocketterm-server setup-link --new`). Replacing it signs nobody out.

A **device token** (43 characters, base64url) is what every other call presents. The server stores only its
SHA-256. It works until the device is revoked or leaves.

A **pairing code** is 28 characters of Crockford base32 in groups of four (`K7QM-3XRT-…`, 140 bits), single use,
valid 10 minutes. Case, separators and look-alikes (`O`→`0`, `I`/`L`→`1`) don't matter when redeeming.
Phones get it in the computer's QR:

```
pocketterm://setup?url=<public url>&code=<pairing code>&d=<desktop id>&k=<base64url channel key>
```

## REST

### `GET /v1/health`

200 `{"pocketterm": 1, "version": "0.1.0"}`. `pocketterm` is this protocol's version.

### `POST /v1/setup/redeem` (no token)

Request `{"setup": "<setup token>", "label": "Dany's MacBook", "platform": "macos"}`.
`label` is optional; `platform` is required (`macos` | `windows` | `linux`).

200 `{"token": "<device token>", "device": <Device, role desktop>}`.
400 `invalid_code` for a wrong or replaced setup token. Rate limited (below).

### `POST /v1/pair` (desktop)

No body. 200 `{"code": "K7QM-3XRT-…", "expires": "<time, 10 minutes from now>"}`. 403 for a phone.

### `POST /v1/pair/redeem` (no token)

Request `{"code": "<pairing code>", "label": "Pixel 9", "platform": "android"}`.
`label` is optional; `platform` is required (`ios` | `android`).

200 `{"token": "<device token>", "device": <Device, role phone>}`. The code is used up.
400 `invalid_code` for an unknown, expired or used code (one answer for all three). Rate limited (below).

### Rate limit on the redeem endpoints

Both redeem endpoints share one counter per caller address: after 10 failed redeems (`invalid_code` or
`bad_request`) within 10 minutes, every redeem from that address gets 429 `rate_limited` with `Retry-After`
until the oldest failure is 10 minutes old, right code or not. Successful redeems don't count. The address is
the TCP peer's, or with `--trust-proxy` the last address in `X-Forwarded-For` (what Caddy or the nearest proxy
puts there).

### `GET /v1/me`

200 `{"device": <Device>, "server": {"id": "<16 characters [a-z0-9]>"}}`. The cheap way to check a token
(401 when it no longer works). `server.id` is made once when the data directory is new and never changes:
key per-server state on it.

### `GET /v1/desktops`

200 `[<Desktop>, …]`, most recently seen first.

### `PUT /v1/desktops/:id` (desktop)

Request `{"name": "MacBook Pro", "platform": "macos"}`. Creates or replaces the computer `:id`
(`[a-z0-9]{8}`) and stamps its `seen_at` with the server's time. Call it on start and every 60 seconds.

200 `<Desktop>`. 400 for a bad id, name or platform. 403 for a phone.

### `DELETE /v1/desktops/:id`

Removes the computer from the list (sign out on that computer, or a phone forgetting it).
200 `{"ok": true}`, also when it wasn't there.

### `GET /v1/devices`

200 `[<Device> + {"current": true|false}, …]`, oldest first; `current` marks the caller.

### `DELETE /v1/devices/me`

Leave: the caller's token stops working, its push and Live Activity tokens are forgotten and its WebSockets
close with code 4003. 200 `{"ok": true}`.

### `DELETE /v1/devices/:id` (desktop)

Revoke another device, with the same effects as leaving. 200 `{"ok": true}`, 404 `not_found` for an unknown
id, 403 for a phone (a phone leaves with `/v1/devices/me`).

### `POST /v1/erase` (desktop)

Erases everything the owner has on the server: every device (the caller included), computer, pairing code,
push and Live Activity token and blob. Every WebSocket closes with 4003 and every token stops working. The setup
token and `server.id` stay, so computers set up again with the same setup link. 200 `{"ok": true}`, 403 for a
phone.

### `PUT /v1/blobs/:path`

The client picks the path (a UUID v4 in the apps; any `[A-Za-z0-9-]{1,64}`), so it can seal the bytes with the
path in the AAD before uploading. The body is the raw bytes (any `content-type`; the apps send AES-GCM sealed
images as `application/octet-stream`), at most 20971520 bytes (20 MiB), else 413.

201 `{"path": "<path>"}`. 409 `conflict` when that path already holds a blob. 400 for a bad path.

### `GET /v1/blobs/:path`

200 with the bytes (`content-type: application/octet-stream`, `content-length`). The blob is deleted once it
has been sent in full: a second download is 404. A blob nobody downloads is deleted 1 hour after upload.

### `DELETE /v1/blobs/:path`

200 `{"ok": true}`, also when it was already gone.

### Push

The server forwards to the push relay (`PUSH_RELAY_URL`, by default the publisher's, which holds the APNs key and
the Firebase service account) and forgets a token when the relay answers 410. Every push body may carry
`"platform": "ios" | "android"` (default `ios`); any other value is 400.

| Endpoint                             | Request                                                       | 200                 |
|--------------------------------------|---------------------------------------------------------------|---------------------|
| `POST /v1/push/register`             | `{"token", "label"?, "platform"?}`                            | `{"ok": true}`      |
| `POST /v1/push/unregister`           | `{"token"}`                                                   | `{"ok": true}`      |
| `POST /v1/push/notify`               | `{"desktop", "enc", "collapse"?}`                             | `{"sent": <count>}` |
| `POST /v1/push/activity_register`    | `{"token", "session", "platform"?}`                           | `{"ok": true}`      |
| `POST /v1/push/activity_end`         | `{"token", "session"?}`                                       | `{"ok": true}`      |
| `POST /v1/push/activity`             | `{"session", "state", "kind"?}`                               | `{"sent": <count>}` |

- `token`: iOS, the APNs device token in hex (64 to 200 characters; a Live Activity's up to 400); Android, the
  FCM registration token (`[A-Za-z0-9_:-]{100,4096}`). Registering a token again replaces its row.
- `label`: at most 80 characters.
- `desktop`: the computer's 8-character id. `enc`: base64 of nonce 12 ‖ ciphertext ‖ tag 16 (AES-256-GCM with the
  computer's channel key over `{title, body, session?, state?}`, AAD `pocketterm/v1|push|<desktop>`), at most 3000
  characters, more than 28 bytes decoded.
- `session` / `collapse`: a coding session key, `[\w.:/-]{1,64}`.
- `state`: `working` | `needs` | `done` | `ended`; `kind` (with `needs` only): `question` | `approval` | `plan`.
- `unregister` also ends every Live Activity that token follows (an Android phone's sessions use its FCM token).
- `activity_register` for iOS moves the token to this session (an iPhone's activity follows one session).
- `activity_end` without `session` ends every session the token follows.
- `activity` with `ended` forgets every token of that session after sending.

What reaches the relay (one POST per phone, `content-type: application/json`):

- notify, iOS: `{"token", "kind": "terminal", "enc", "desktop", "collapse"?}`
- notify, Android: `{"platform": "android", "token", "kind": "terminal", "enc", "desktop", "collapse"?}`
- activity, iOS: `{"token", "kind": "liveactivity", "event": "update" | "end", "state": {"state", "since", "kind"?}}`
- activity, Android: `{"platform": "android", "token", "kind": "activity", "session", "state": {"state", "since",
  "kind"?}, "collapse": <session>}`

`since` is seconds since the epoch.

## WebSocket: the live channel

`GET /v1/ws` with `Authorization: Bearer <device token>` upgrades to a WebSocket (401 `unauthorized` before the
upgrade otherwise). Every frame is a text frame holding one JSON object with a `t` field. A topic is a computer's
id (any `[A-Za-z0-9_.:-]{1,128}` is accepted); an event is `[A-Za-z0-9_.:-]{1,64}`.

Client to server:

```json
{"t": "join", "topic": "a1b2c3d4"}
{"t": "send", "topic": "a1b2c3d4", "event": "state", "payload": {"v": 1, "n": "…", "c": "…"}}
{"t": "leave", "topic": "a1b2c3d4"}
{"t": "ping"}
```

Server to client:

```json
{"t": "joined", "topic": "a1b2c3d4"}
{"t": "msg", "topic": "a1b2c3d4", "event": "state", "payload": {"v": 1, "n": "…", "c": "…"}}
{"t": "pong"}
{"t": "error", "error": "not_joined", "message": "…"}
```

- `send` delivers `msg` to every other WebSocket joined to the topic, the sender's other sockets included, never
  back to the sending socket. `payload` is any JSON value and is passed on untouched. Sending to a topic this
  socket hasn't joined is an `error` frame (`not_joined`) and nothing is delivered.
- `join` answers `joined` (also when already joined); `leave` answers nothing.
- Errors are frames, not closes: `bad_frame` (not JSON, unknown `t`, bad topic or event), `not_joined`,
  `too_many_topics` (more than 32 topics on one socket).
- Delivery is at most once, in order per sender; a socket that isn't connected misses messages (the apps resync
  with `sync`).

Limits and keepalive:

- A frame is at most 262144 bytes (256 KiB); a larger one closes the socket with 1009.
- The server sends a WebSocket ping control frame every 25 seconds and closes a socket whose pong hasn't arrived
  by the next ping. Clients may also send `{"t": "ping"}` (answered `{"t": "pong"}`) to notice a dead link on
  their side; every 25 seconds, giving up after 2 missed pongs, is a good default.

Close codes from the server: 1001 the server is stopping, 1009 frame too large, 4003 the device was revoked or
left (don't reconnect with that token).
