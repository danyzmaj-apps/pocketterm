# PocketTerm push relay

The one service that can reach PocketTerm's phones through Apple (APNs) and Google (FCM), because it holds the
publisher's APNs key and Firebase service account. Every PocketTerm server sends its pushes here. It runs on the
publisher's own server, at **https://push.danyzmaj.com**.

It stores nothing. It can't read your notifications. What it and everyone around it can see is in
[SECURITY.md](SECURITY.md).

## API

| Path            |                                                         |
| --------------- | ------------------------------------------------------- |
| `POST /v1/push` | one push, sealed to the relay's key (below)             |
| `GET /health`   | `ok`                                                    |
| `GET /metrics`  | Prometheus metrics; not public (the tunnel answers 404) |

Answers to a push: `200` sent, `410` the phone is gone (the server forgets it), `429` over a rate limit (`Retry-After`),
`400` malformed or not sealed to this relay, `413` a body over 16 KiB (refused unread), `501` FCM not configured, `502`
Apple or Google said no. The body of an answer never repeats the request. A Live Activity's `since` from a server whose
clock is off is held to the last week (never the future) rather than refused. Servers retry `429` and `5xx` on their own
(after `Retry-After`, or 2, 4, 8 … seconds), and never `501`.

What's inside the seal (the server builds it; see
[packages/pocketterm_server/PROTOCOL.md](../../packages/pocketterm_server/PROTOCOL.md)):

- iPhone alert: `{"token", "kind": "terminal", "enc", "tag", "collapse"?}`
- iPhone Live Activity:
  `{"token", "kind": "liveactivity", "event": "update"|"end", "state": {"state", "since", "kind"?}, "quiet"?: true}`
- Android alert: `{"platform": "android", "token", "kind": "terminal", "enc", "tag", "collapse"?}`
- Android coding session: `{"platform": "android", "token", "kind": "activity", "enc", "tag", "ref"}`, or its end in
  plain text: `{"platform": "android", "token", "kind": "activity", "ref", "state": {"state": "ended", "since"}}`
- Any other field is refused (`400`).
- iPhone Live Activities go stale 3 minutes after an update (`stale-date`) and leave the Lock Screen 10 minutes after
  their end (`dismissal-date`). Updates go at Apple's priority 10, except `working` and `quiet` ones (the same state
  again, which a server sends while the computer checks in so the activity doesn't go stale) at priority 5.

`enc` is the notification (or an Android session's state), sealed on your computer with its channel key; the relay
passes it to the phone as it is. No computer id or session key reaches the relay: `tag` is an HMAC under the computer's
channel key (the phone finds the key it belongs to), and `collapse` and `ref` are an HMAC of the session's key under the
same key (a newer push for a session replaces an older one; an Android end names its session by it). A Live Activity
push goes to the activity's own token, which is all Apple needs; the phone set which session it shows when the activity
started.

## Sealed requests (v1)

Each request body is encrypted to the relay's static X25519 public key, so Cloudflare, proxies and any log on the way
see only ciphertext, device tokens included:

```
(esk, epk) = a fresh X25519 key pair for this request
shared     = X25519(esk, relay public key)
key        = HKDF-SHA256(ikm = shared, salt = epk ‖ relay public key, info = "pocketterm-relay/v1", 32 bytes)
c          = AES-256-GCM(key, n = 12 random bytes, the JSON body) ‖ 16-byte tag
body       = {"v": 1, "kid": the first 11 characters of base64(relay public key), "epk": base64(epk), "n": base64(n),
              "c": base64(c)}
```

The relay's public key ships in the server package (`defaultRelayKey` in
`packages/pocketterm_server/lib/src/relay.dart`):

```
VjwMi0GtvYoVT3Q9FlENy/dQOVe0vuqU8K4t+fw3fHc=
```

The relay logs it at start (`listening`), so you can check the two match. A fork running its own relay sets
`PUSH_RELAY_URL` and `PUSH_RELAY_KEY` on its servers.

## Code

| Path             |                                                                                                          |
| ---------------- | -------------------------------------------------------------------------------------------------------- |
| `main.ts`        | the HTTP service: routes, settings, JSON logs, metrics                                                   |
| `src/relay.ts`   | checks a push and sends it to APNs or FCM                                                                |
| `src/seal.ts`    | opens sealed requests                                                                                    |
| `src/fcm.ts`     | FCM HTTP v1: service-account token, message, errors                                                      |
| `src/limits.ts`  | in-memory rate limits, keyed by HMAC under a daily random salt                                           |
| `src/metrics.ts` | Prometheus text format                                                                                   |
| `tests/`         | `deno task test`: the relay against a fake network, and `vectors.json` (requests the Dart server sealed) |

```sh
deno task test
# after changing the sealing on either side, new vectors from the Dart side:
(cd ../../packages/pocketterm_server && dart run tool/relay_vectors.dart ../../apps/pocketterm-relay/tests/vectors.json)
```

## Deploy

It runs on danyzmaj-server as app `pocketterm-relay`
([connect-an-app](https://github.com/danyzmaj-apps/danyzmaj-server/blob/master/docs/connect-an-app.md)): `Dockerfile`
(Deno, non-root, read-only filesystem, no capabilities) and `deploy/compose.yaml`. [Baker](https://baker.danyzmaj.com)'s
_Relay_ workflow (project `pocketterm-mobile`) tests it and deploys it on every push to `main` that touches this
folder, or on _Deploy_ in Baker.

Settings and secrets live on the server only, in `/etc/danyzmaj/pocketterm-relay/` (folder `750 root:runner`):

| File                       | Mode | What                                        |
| -------------------------- | ---- | ------------------------------------------- |
| `app.env`                  | 640  | `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` |
| `relay-x25519.key`         | 644  | the relay's X25519 private key (PEM)        |
| `apns.p8`                  | 644  | the APNs key, `AuthKey_<APNS_KEY_ID>.p8`    |
| `fcm-service-account.json` | 644  | the Firebase service account                |

The originals are in the publisher's `~/Dev/keys/` (`pocketterm-relay-x25519.key`, `AuthKey_<id>.p8`,
`pocketterm-fcm-service-account.json`). To replace one:

```sh
ssh deploy@server.danyzmaj.com 'sudo install -m 644 -o root -g runner /dev/stdin /etc/danyzmaj/pocketterm-relay/apns.p8' < ~/Dev/keys/AuthKey_<id>.p8
```

then redeploy (Baker → _Relay_ → _Deploy_).

### Rotating the relay key

The relay can hold its key and the one before, so servers move over without missing a push. `kid` names the key a
request was sealed to (a request without `kid` is tried with each key).

1. Make the new key straight into the keys folder:
   `openssl genpkey -algorithm X25519 -out
   ~/Dev/keys/pocketterm-relay-x25519-<year>.key && chmod 600 ~/Dev/keys/pocketterm-relay-x25519-<year>.key`.
2. On the server, the current key becomes the previous one and the new one takes its place:
   `sudo cp /etc/danyzmaj/pocketterm-relay/relay-x25519.key /etc/danyzmaj/pocketterm-relay/relay-x25519-previous.key`,
   then install the new one as `relay-x25519.key` (as for `apns.p8` above).
3. In `deploy/compose.yaml`, add the secret `relay_key_previous` (file `relay-x25519-previous.key`) to the service and
   the `secrets:` list, and redeploy. The `listening` log line shows both `publicKey` and `previousKey`.
4. Put the new public key (`publicKey` in that log line) in `defaultRelayKey` and release the server.
5. Once servers have updated (months: self-hosted servers update rarely), drop the previous key and its secret. For a
   leaked key skip the wait: servers still on it get `400` until they update.

The public route is in danyzmaj-server's `monitoring/cloudflared/config.yml`: only `/v1/push` and `/health` reach the
container; everything else is `404`.
