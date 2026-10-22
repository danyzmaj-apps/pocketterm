# PocketTerm server

## What it needs

For admins who run their own servers already; the Docker walkthrough is [below](#run-it-on-a-vps-with-docker).

- **One process:** one container (`ghcr.io/danyzmaj-apps/pocketterm-server`) or one binary, `pocketterm-server serve`. No database, no other services.
- **Port 47900, plain HTTP** (`--port`, `--address`, default `0.0.0.0`). Terminate HTTPS in front of it and set `--public-url` to that `https://` address.
- **WebSocket at `/v1/ws`** must pass through the proxy (Upgrade headers), with an idle timeout above 60 seconds. The server pings every 25 seconds.
- **`--trust-proxy`** when it sits behind a proxy that sets `X-Forwarded-For`, so rate limits count the real caller. Leave it off when clients reach it directly.
- **One data folder to back up:** `/data` in the container (`--data`, default `./data` for the binary).
- **Health:** `pocketterm-server health` exits 0 when it answers; or `GET /v1/health` returns 200.
- **Outbound:** HTTPS to `push.danyzmaj.com`, only if phones turn notifications on.

Every option also reads an environment variable (`POCKETTERM_PORT`, `POCKETTERM_DATA`, `POCKETTERM_PUBLIC_URL`, `POCKETTERM_TRUST_PROXY=1`, …); `pocketterm-server help` lists them.

The server your computers and phones talk to: pairing, the list of your computers, the live channel between a
computer and its phones, images on their way from phone to computer, and push notifications. It serves one
owner. Everything between a computer and a phone is end-to-end encrypted by the apps, so the server only ever
passes on ciphertext.

The protocol is in [packages/pocketterm_server/PROTOCOL.md](../../packages/pocketterm_server/PROTOCOL.md).

## Run it on a VPS with Docker

You need a machine with a public IP address, Docker with Compose, and ports **80 and 443 open** to the
internet (Caddy gets the HTTPS certificate from Let's Encrypt, which checks port 80).

1. Get the compose file:

   ```sh
   mkdir pocketterm && cd pocketterm
   curl -fsSLO https://raw.githubusercontent.com/danyzmaj-apps/pocketterm/main/apps/pocketterm-server/docker-compose.yml
   ```

2. Pick the server's name and start it.

   With a domain of your own, point an A (and AAAA) record at the machine, then:

   ```sh
   echo "DOMAIN=pocketterm.example.com" > .env
   docker compose up -d
   ```

   Without one, use [sslip.io](https://sslip.io), which turns the IP address into a name
   (`203-0-113-7.sslip.io`):

   ```sh
   echo "DOMAIN=$(curl -s https://ifconfig.me | tr . -).sslip.io" > .env
   docker compose up -d
   ```

3. Print the setup link and open it on each of your computers (PocketTerm, Your own server). Phones are added
   from a computer afterwards (Add a phone).

   ```sh
   docker compose exec server pocketterm-server setup-link
   ```

   The setup link signs a computer in to your server: keep it private. If it leaks, replace it (computers
   already signed in stay signed in):

   ```sh
   docker compose exec server pocketterm-server setup-link --new
   ```

## Update

```sh
docker compose pull && docker compose up -d
```

Everything the server keeps is in the `pocketterm-data` volume, which an update leaves as it is: devices stay signed
in. Phones and computers reconnect on their own within a minute; a push sent during the restart may be lost. An app
newer than its server says "Update the server"; a server newer than the app says "Update PocketTerm".

## Back up and restore

Back up while it runs (`state.json` is always whole on disk):

```sh
docker run --rm -v pocketterm_pocketterm-data:/data:ro -v "$PWD":/backup alpine \
  tar czf /backup/pocketterm-data.tgz -C /data .
```

Restore on this or a new machine (the same `DOMAIN`, so the setup link and the apps' saved address still work):

```sh
docker compose down
docker run --rm -v pocketterm_pocketterm-data:/data -v "$PWD":/backup alpine \
  sh -c 'cd /data && tar xzf /backup/pocketterm-data.tgz && chown -R 65532:65532 /data'
docker compose up -d
```

The backup holds the setup token and every device's token hash: keep it as private as the setup link. Back up
`caddy-data` the same way to keep the HTTPS certificate when moving, so Let's Encrypt isn't asked for a new one.
Without a backup, a lost volume means every computer opens the setup link again and every phone scans a new code.

## Behind another reverse proxy or a Cloudflare Tunnel

Run the image on its own and point the proxy at port 47900 (WebSockets on `/v1/ws` must be passed through):

```sh
docker run -d --name pocketterm --restart unless-stopped -p 127.0.0.1:47900:47900 -v pocketterm-data:/data \
  -e POCKETTERM_PUBLIC_URL=https://pocketterm.example.com -e POCKETTERM_TRUST_PROXY=1 \
  ghcr.io/danyzmaj-apps/pocketterm-server:latest
```

Set `POCKETTERM_TRUST_PROXY=1` only when the proxy is the only way in: the server then rate limits failed
sign-ins by the last address in `X-Forwarded-For`.

For a container healthcheck, use the server itself (the image has no shell, curl or wget):
`healthcheck: {test: ["CMD", "pocketterm-server", "health"]}` exits 0 when it answers `GET /v1/health`.

The proxy must pass WebSocket upgrades on `/v1/ws`, keep them open (the server pings each socket every 25
seconds; an idle timeout of 60 seconds or more is fine) and accept request bodies up to 20 MB (images).

nginx, in the `server` block that already has your certificate:

```nginx
location / {
    proxy_pass http://127.0.0.1:47900;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_read_timeout 1h;
    client_max_body_size 20m;
}
```

Traefik (Docker labels on the server container, joined to Traefik's network, with no port published;
Traefik passes WebSockets as they are):

```yaml
labels:
  - traefik.enable=true
  - traefik.http.routers.pocketterm.rule=Host(`pocketterm.example.com`)
  - traefik.http.routers.pocketterm.tls.certresolver=letsencrypt
  - traefik.http.services.pocketterm.loadbalancer.server.port=47900
```

Cloudflare: a proxied name (orange cloud) works, WebSockets included, with SSL/TLS set to **Full (strict)**:
**Flexible** sends Cloudflare's requests to port 80, where Caddy redirects them to HTTPS, over and over. With
the compose file's Caddy behind Cloudflare, the simplest is a DNS-only (grey cloud) record for this name.

## Without Docker

```sh
dart compile exe apps/pocketterm-server/bin/pocketterm_server.dart -o pocketterm-server
./pocketterm-server serve --data ./data --port 47900 --public-url https://pocketterm.example.com
```

It speaks plain HTTP: put it behind something that adds HTTPS, or reach it over Tailscale.

## Options

| Flag             | Environment              | Default                  |                                              |
|------------------|--------------------------|--------------------------|----------------------------------------------|
| `--data`         | `POCKETTERM_DATA`        | `./data` (`/data` image) | where everything is kept                     |
| `--public-url`   | `POCKETTERM_PUBLIC_URL`  | required                 | the address put in setup links               |
| `--port`         | `POCKETTERM_PORT`        | `47900`                  | the port to listen on                        |
| `--address`      | `POCKETTERM_ADDRESS`     | `0.0.0.0`                | the address to listen on (`::` for IPv6 and IPv4) |
| `--relay`        | `PUSH_RELAY_URL`         | the publisher's relay    | where push notifications are sent            |
| `--relay-key`    | `PUSH_RELAY_KEY`         | the publisher's relay's  | the relay's X25519 public key (base64); every push is sealed to it |
| `--trust-proxy`  | `POCKETTERM_TRUST_PROXY` | off                      | rate limit by `X-Forwarded-For` (set to `1`) |

## What it keeps

In the data directory: `state.json` (devices with the SHA-256 of their tokens, computers, pairing codes, push
tokens), rewritten atomically on every change, with the state before the last change in `state.json.bak`;
`setup-token`; `.lock`, held while a server runs (a second server on the same folder refuses to start); and `blobs/`,
images waiting for their computer, deleted once downloaded or after an hour. Push notifications go to the
publisher's relay, which holds the Apple and Google keys and sees only the phone's push token and the encrypted text.

A `state.json` that doesn't read (edited by hand, a broken disk) is never replaced by an empty one: the server
starts from `state.json.bak` and keeps the bad file as `state.json.corrupt-<time>`, or, without a usable backup,
refuses to start and says so in its log.

## When something is wrong

`docker compose logs server` and `docker compose logs caddy` say most of it.

| What you see | Why, and what to do |
|---|---|
| The app: "Couldn't make a secure connection" | Caddy has no certificate yet. `docker compose logs caddy`: ports 80 and 443 must be open to the internet (cloud firewalls too); `DOMAIN` must point at this machine (`dig +short $DOMAIN`); Let's Encrypt allows 5 certificates per name a week and 50 per domain (busy shared names like sslip.io hit it: wait, or use a domain of your own). Only add an AAAA record when the machine answers on IPv6, as Let's Encrypt tries IPv6 first. |
| `The server didn't start: Can't write to the data folder` | A folder mounted at `/data` that the server (user 65532) doesn't own: `sudo chown -R 65532:65532 <folder>`. |
| `The server didn't start: Another PocketTerm server is using /data` | Two containers on one volume: stop the other one. |
| `The server didn't start: …state.json doesn't read…` | Restore the data folder from a backup, or move `state.json` away to start over (every device signs in again). |
| The app: "The server couldn't save this" (507) | The disk is full or the folder not writable: `df -h`, then free space. Nothing is lost that was saved before. |
| "Too many tries from this network" when pairing | 10 wrong codes from one address in 10 minutes. Wait, or `docker compose restart server` to clear it. |
| Pushes don't arrive | `docker compose logs server` shows `relay …` lines when the push relay can't be reached or turns a push away (it retries for 2 minutes). |

Over IPv6 without Docker's IPv6 NAT, every IPv6 caller reaches Caddy from Docker's own address, so they share one
redeem throttle; enable `ip6tables` in Docker's daemon settings to keep them apart.

## Build the image

From the repository root:

```sh
docker build -f apps/pocketterm-server/Dockerfile -t pocketterm-server .
```

Release tags (`v*`) publish `ghcr.io/danyzmaj-apps/pocketterm-server` for amd64 and arm64
(`.github/workflows/server-image.yml`).
