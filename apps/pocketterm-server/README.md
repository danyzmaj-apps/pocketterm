# PocketTerm server

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

Update with `docker compose pull && docker compose up -d`. Everything the server keeps is in the
`pocketterm-data` volume; back it up to keep your devices signed in after moving machines.

## Behind another reverse proxy or a Cloudflare Tunnel

Run the image on its own and point the proxy at port 47900 (WebSockets on `/v1/ws` must be passed through):

```sh
docker run -d --name pocketterm --restart unless-stopped -p 127.0.0.1:47900:47900 -v pocketterm-data:/data \
  -e POCKETTERM_PUBLIC_URL=https://pocketterm.example.com -e POCKETTERM_TRUST_PROXY=1 \
  ghcr.io/danyzmaj-apps/pocketterm-server:latest
```

Set `POCKETTERM_TRUST_PROXY=1` only when the proxy is the only way in: the server then rate limits failed
sign-ins by the last address in `X-Forwarded-For`.

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

Traefik (Docker labels on the server container, joined to Traefik's network instead of publishing the port;
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
| `--address`      | `POCKETTERM_ADDRESS`     | `0.0.0.0`                | the address to listen on                     |
| `--relay`        | `PUSH_RELAY_URL`         | the publisher's relay    | where push notifications are sent            |
| `--relay-key`    | `PUSH_RELAY_KEY`         | the publisher's relay's  | the relay's X25519 public key (base64); every push is sealed to it |
| `--trust-proxy`  | `POCKETTERM_TRUST_PROXY` | off                      | rate limit by `X-Forwarded-For` (set to `1`) |

## What it keeps

In the data directory: `state.json` (devices with the SHA-256 of their tokens, computers, pairing codes, push
tokens), rewritten atomically on every change; `setup-token`; and `blobs/`, images waiting for their computer,
deleted once downloaded or after an hour. Push notifications go to the publisher's relay, which holds the Apple
and Google keys and sees only the phone's push token and the encrypted text.

## Build the image

From the repository root:

```sh
docker build -f apps/pocketterm-server/Dockerfile -t pocketterm-server .
```

Release tags (`v*`) publish `ghcr.io/danyzmaj-apps/pocketterm-server` for amd64 and arm64
(`.github/workflows/server-image.yml`).
