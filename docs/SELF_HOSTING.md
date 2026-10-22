# Self-hosting

PocketTerm has no central server. Your computers and phones meet in a **PocketTerm server** that you run: it pairs your phones, keeps the list of your computers, passes the live channel between a computer and its phones and sends pushes. Everything between a computer and a phone is end-to-end encrypted by the apps, so the server only ever passes on ciphertext ([How your data is protected](#how-your-data-is-protected)).

The server runs in one of two places, and the desktop app sets up either:

| | **On this computer** | **On my own server** |
| --- | --- | --- |
| What | The server built into the PocketTerm app | A VPS you rent, running the server in Docker |
| Cost | Free | The VPS (a small one is enough) |
| Needs | [Tailscale](https://tailscale.com) on this computer and on your phone, signed in to the same account | A VPS with a public IP address and ports 80 and 443 open |
| Good to know | This computer must stay awake for your phone to connect | No Tailscale, and several computers can share one server. Sessions still run on your computers, so a computer must be awake for its sessions |

Servers are set up from a computer, never from a phone: the iPhone and Android apps only pair with a server that exists.

## The setup wizard

Install PocketTerm on your Mac or Windows PC ([Releases](https://github.com/danyzmaj-apps/pocketterm/releases/latest)) and open it. With no server yet, its window is a setup wizard that follows your choice. Every screen has **Back**, and the wizard remembers where you were if you close it and come back. **How your data is protected** on its first screen sums up who can see what; **Settings → Account** shows the same again later.

<p align="center">
  <img src="images/mac-setup.png" width="45%" alt="Setup: On this computer, or On my own server">
  <img src="images/mac-setup-data.png" width="45%" alt="Setup: how your data is protected">
</p>

PocketTerm never runs anything on your computer without asking first. Where it can install something for you (Tailscale or tmux with Homebrew), the button shows the exact command and runs it only after you press **Run**; anything else is a line to copy.

### On this computer

The server runs inside the PocketTerm app, listening on this computer only. [Tailscale](https://tailscale.com) makes a private network between your own devices and gives this computer an HTTPS address that only they reach (`https://<this computer>.<tailnet>.ts.net`, through `tailscale serve`). Tailscale sees which of your devices connect and when, not what PocketTerm sends.

The wizard shows a checklist that looks again every few seconds and moves on by itself. Each step shows only its own button; finished steps fold to one line:

1. **Install Tailscale.** With Homebrew on a Mac, **Install Tailscale** runs `brew install --cask tailscale-app` once you confirm (macOS asks for your password: Tailscale's installer needs it). **Download instead** opens [tailscale.com/download](https://tailscale.com/download).
2. **Start Tailscale.** **Open Tailscale** and switch it on.
3. **Sign in to Tailscale.** **Open Tailscale to sign in**, with any account (Google, GitHub, Microsoft, Apple). Use the same one on your phone.
4. **Turn on HTTPS certificates.** **Turn on HTTPS…** opens the page Tailscale names for your tailnet (or the admin console's [DNS page](https://login.tailscale.com/admin/dns)): turn on HTTPS, and MagicDNS if it asks.
5. **Start** runs the server and signs this computer in to it.

Your phone needs the Tailscale app too, from the App Store or Google Play, signed in to the same Tailscale account. The wizard and the phone step of the checklist both say so.

<p align="center">
  <img src="images/mac-setup-tailscale-install.png" width="32%" alt="Install Tailscale, with what Tailscale is">
  <img src="images/mac-setup-tailscale-sign-in.png" width="32%" alt="Sign in to Tailscale">
  <img src="images/mac-setup-https-off.png" width="32%" alt="Turn on HTTPS certificates">
</p>
<p align="center">
  <img src="images/mac-setup-this-computer.png" width="45%" alt="Everything ready: Start">
  <img src="images/mac-setup-confirm.png" width="45%" alt="Install Tailscale asks first and shows the command">
</p>

From now on the server starts with the app. **Settings → Account** shows how Tailscale stands. Another computer of yours can use this computer's server too: on this one, **Settings → Account → Add a computer…** shows a setup link; on the other one (signed in to Tailscale with the same account), choose **On my own server → Yes** and paste it.

### On my own server

The wizard first asks: **Do you already have a PocketTerm server?**

<p align="center">
  <img src="images/mac-setup-own-server.png" width="45%" alt="Do you already have a PocketTerm server?">
  <img src="images/mac-setup-have-server.png" width="45%" alt="A pasted setup link, its server answering">
</p>

**Yes:** paste its setup link (`pocketterm://setup?url=…&setup=…`). The wizard checks it as you paste: that it's a setup link at all, that it's a computer's link and not a phone's, and that its server answers. **Connect** signs this computer in. To see the link again, run on the server:

```sh
cd ~/pocketterm && sudo docker compose exec server pocketterm-server setup-link
```

**Not yet:** the wizard asks for the server's address, an IPv4 address (`203.0.113.7`) or a domain (`pocketterm.example.com`), and shows the commands for it, each with a copy button. A domain is used as it is (point its DNS A record at the server first). An IP address becomes its [sslip.io](https://sslip.io) name, `203-0-113-7.sslip.io`, a name that resolves to that address, so the server can get an HTTPS certificate without a domain of your own. IPv6 addresses aren't accepted: use the server's IPv4 address or a domain.

Rent a small Linux VPS (1 GB of memory is plenty), open **ports 80 and 443** to the internet in your provider's firewall, and open a terminal on it with SSH. Then run, in order (signed in as root, you can leave out `sudo`):

1. Install Docker:

   ```sh
   curl -fsSL https://get.docker.com | sudo sh
   ```

2. Get the server (the compose file of the release your app is, here 0.1.0; the wizard fills in yours):

   ```sh
   mkdir -p ~/pocketterm && cd ~/pocketterm && curl -fsSLO https://raw.githubusercontent.com/danyzmaj-apps/pocketterm/v0.1.0/apps/pocketterm-server/docker-compose.yml
   ```

3. Start it, with your server's name (here the sslip.io name of `203.0.113.7`):

   ```sh
   cd ~/pocketterm && echo "DOMAIN=203-0-113-7.sslip.io" > .env && sudo docker compose up -d
   ```

4. Print its setup link:

   ```sh
   cd ~/pocketterm && sudo docker compose exec server pocketterm-server setup-link
   ```

Docker runs the PocketTerm server in a container, so nothing else on the VPS changes. [Caddy](https://caddyserver.com) runs next to it: it answers on ports 80 and 443 and gets a free HTTPS certificate from Let's Encrypt (which checks port 80), renewing it on its own.

While you work, the wizard checks the address and turns each line green: **the name resolves**, **HTTPS answers** (Caddy has its certificate, usually a minute after step 3), **the PocketTerm server answers** (`/v1/health`). Then it shows the box for the setup link step 4 printed.

<p align="center">
  <img src="images/mac-setup-vps.png" width="45%" alt="The commands for 203.0.113.7, HTTPS not answering yet">
  <img src="images/mac-setup-vps-ready.png" width="45%" alt="Every check green, and the box for the setup link">
</p>

The setup link signs a computer in to your server: keep it private. If it leaks, replace it (computers already signed in stay signed in):

```sh
cd ~/pocketterm && sudo docker compose exec server pocketterm-server setup-link --new
```

Everything the server keeps is in the `pocketterm-data` Docker volume; back it up to keep your devices signed in after moving machines. Other ways to run it (behind another reverse proxy or a Cloudflare Tunnel, without Docker) and its options: [apps/pocketterm-server/README.md](../apps/pocketterm-server/README.md).

## After the first sign-in

The first sign-in on a computer opens **Get this computer ready**, a checklist whose steps check themselves off:

1. **Your coding agents.** PocketTerm installs itself into every coding agent it finds (omp, Claude Code), says how each went, and offers **Retry** if one failed. An agent that isn't installed is left for later: Settings offers it once it shows up. **Sessions that were already open** don't have PocketTerm's add-on yet (an agent loads add-ons when it starts), so the phone sees only their screen. They're listed, each with what to do once, with a copy button: in Claude Code type `/reload-plugins` (nothing restarts); in omp quit it and run `omp -c` (same conversation). New sessions don't need it.
2. **Your terminals.** On a Mac, the terminals it found (kitty, Ghostty, WezTerm), with **Set up** for kitty (it turns on kitty's remote control in `kitty.conf`; restart kitty after) and **Allow…** for one that needs Automation permission. Ghostty doesn't let other apps read or type into its windows, so PocketTerm runs Ghostty sessions in tmux: when tmux is missing, **Install tmux** runs `brew install tmux` once you confirm (or copy the line), and **Start new windows in tmux** adds two lines to Ghostty's config so each new Ghostty window opens in tmux (**Settings → Terminals → Remove** takes them out). On Windows, PocketTerm works through WezTerm: **Install WezTerm** downloads WezTerm's own installer from its GitHub release, checks it against WezTerm's published checksum and opens it for you to click through, or you type the `winget` line it shows into PowerShell.
3. **Project folders** (optional). The usual folders found in your home folder (`Dev`, `Developer`, `Projects`, `code`, `src`, `repos`, `git`; on Windows also `source\repos` and `Documents\GitHub`), one click each, or **Choose folder…**.
4. **Your phone.** The QR code from [Connect the apps](#connect-the-apps), checked off once a phone has signed in. Through Tailscale, it reminds you that the phone needs the Tailscale app, signed in to the same account.

<p align="center">
  <img src="images/get-ready.png" width="45%" alt="Get this computer ready: agents, terminals, project folders, your phone">
</p>

**Done** goes to Settings and says what's still left. Settings starts with a status bar: **All set**, or how many things need attention; **Show** lists them with the button that fixes each, including a coding agent installed later, and a dot marks the tab they're on. **Open setup checklist** shows the checklist again. On Windows, a bar under it links to a new version when one is out. Below it are four tabs: **Phone** (Terminal from phone, **Add a phone…**, **Reset key**, project folders), **Coding agents** (PocketTerm in each agent with **Install** or **Update**, sessions to reopen, **Make default**), **Terminals** (where new sessions open, each terminal with its fix) and **Account** (your server, Tailscale when this computer runs it, **Add a computer…**, Launch at login, **How your data is protected**, the version and **Quit PocketTerm**).

<p align="center">
  <img src="images/mac-settings-phone.png" width="49%" alt="Settings, Phone: Terminal from phone, your phones, project folders">
  <img src="images/mac-settings-agents.png" width="49%" alt="Settings, Coding agents: omp with two sessions to reopen, Claude Code out of date">
  <img src="images/mac-settings-terminals.png" width="49%" alt="Settings, Terminals: where new sessions open, each terminal and how it stands">
  <img src="images/mac-settings-account.png" width="49%" alt="Settings, Account: your server, Launch at login, how your data is protected">
</p>

## Connect the apps

- **More computers**: install PocketTerm and paste the setup link in the wizard (**On my own server → Yes**): the VPS's from `setup-link`, or, for a server built into another computer, the link from that computer's **Settings → Account → Add a computer…**. Every computer you sign in on shows up in the phone's list of computers.
- **iPhone and Android**: phones sign in only with a code from a computer. On the computer, **Settings → Add a phone…** shows a QR code. In the phone app, tap **Scan the code from your computer**. The code carries the server address, a one-time sign-in code and that computer's encryption key, so the phone signs in and can read that computer's sessions. The sign-in code works once and expires after 10 minutes; the key works until you **Reset key** (**Settings → Phone**). Anyone who scans the code can read that computer's sessions, so only show it to your own phone. No camera? **Paste a code instead** takes the same code as text (the whole `pocketterm://setup?…&code=…` link).

One phone sign-in covers all your computers, but each computer encrypts its sessions with its own key: scan each computer's code once. A computer the phone can't read yet shows as locked with a **Scan** button (or **Scan a computer's code** in the computer picker). After **Reset key**, every phone scans that computer's code again.

## How your data is protected

- **Encrypted from end to end.** Each computer makes its own 32-byte key and keeps it in the system's secure storage (the Keychain on a Mac, Credential Manager on Windows). It never goes to any server: a phone gets it only by scanning that computer's QR code. Sessions, prompts, screens, images and notification text are sealed with it (AES-256-GCM).
- **Your PocketTerm server** keeps your list of devices, your computers' names, pairing codes (10 minutes) and your phones' push tokens, and passes everything else on without being able to read it.
- **Tailscale** (On this computer) sees which of your devices connect and when, not what they send.
- **Push notifications**, if you turn them on in the phone app, go from your server through PocketTerm's push relay (`push.danyzmaj.com`, run by Danijel Lovric on his server in Germany) to Apple or Google. They get encrypted text, the phone's push token and which computer it's from; the relay stores nothing ([apps/pocketterm-relay/SECURITY.md](../apps/pocketterm-relay/SECURITY.md)).
- **What you trust on a VPS.** The commands run Docker's install script (`get.docker.com`) and the compose file as root. The compose file comes from the release tag matching your app (`v<version>`, not a moving branch) and runs the server image of that same version; Docker's script is Docker's own, fetched over HTTPS. Read either before you run it if you prefer, or install Docker from your distribution's packages instead.
- **One exception: Live Activities.** On iPhone, a followed session on the Lock Screen (and its ongoing notification on Android) shows its state (working, needs you, finished), since when, and whether it waits on a question, an approval or a plan. Apple delivers those to the system directly, so they can't be encrypted. They never carry any text.

The full model: [SECURITY.md](../SECURITY.md).

## Push

A computer pushes coding-session notifications (a run ended, the agent needs you) and the state of the sessions you follow to your phones, only when nobody has touched it for 60 seconds. Only the app's publisher holds the credentials that reach PocketTerm's installs (the APNs key for iPhones, the Firebase service account for Android), so your server hands each notification to the publisher's **relay**, which passes it to Apple's APNs or Google's Firebase Cloud Messaging. Each phone asks before it registers for notifications. A phone without a computer's key shows a plain "PocketTerm" alert for it. No setup on your side: your server seals each request to the relay's key, so nothing in between can read it.

### Your own app id and relay

A relay only reaches apps signed with the publisher's ids. A fork that ships its own phone app (its own bundle id or Android package) runs its own relay ([apps/pocketterm-relay](../apps/pocketterm-relay/README.md), a container): an APNs key from its Apple team, a Firebase project with its Android app (its `google-services.json` goes into its Android build), that project's service account, and an X25519 key pair of its own. Then point each server that serves those apps at it, in the VPS's `~/pocketterm/.env` next to `DOMAIN`:

```sh
PUSH_RELAY_URL=https://<relay host>/v1/push
PUSH_RELAY_KEY=<the relay's public key, base64; the relay logs it at start>
```

## Updating

- **On this computer**: the server is part of the app and updates with it. The Mac app updates itself; on Windows, Settings links to a new version when one is out.
- **On my own server**: the compose file runs the server version it came with. To move to another one (here 0.2.0), on the VPS run

  ```sh
  cd ~/pocketterm && echo "POCKETTERM_VERSION=0.2.0" >> .env && sudo docker compose pull && sudo docker compose up -d
  ```

[CHANGELOG.md](../CHANGELOG.md) says when a new app version needs a server update.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| Setup: **Install Tailscale** says it didn't work | Use **Download instead**. If macOS blocked Tailscale's system extension, allow it in System Settings → Privacy & Security, then try again. |
| Setup: **Turn on HTTPS certificates** stays | On the page that opened (or [login.tailscale.com/admin/dns](https://login.tailscale.com/admin/dns)), turn on MagicDNS and HTTPS Certificates. The checklist sees it within a few seconds. |
| Setup: "That isn't a setup link" | Copy the whole line `setup-link` printed, starting with `pocketterm://setup?url=`. |
| Setup: "That link signs in a phone, not a computer" | That's a phone's code. Use the server's setup link (`setup-link` on the server, or **Add a computer…** on a computer that runs the server). |
| Setup: "Couldn't reach …" | Check the address, that the server runs (`cd ~/pocketterm && sudo docker compose ps`) and that ports 80 and 443 are open. For a server built into another computer, this computer must be signed in to the same Tailscale account. |
| Setup: "That setup link doesn't work: the server has a newer one" | It was replaced with `setup-link --new`. Run `setup-link` on the server for the current one. |
| Setup: the name doesn't resolve | For a domain, add a DNS A record with the server's IP address and wait a few minutes. For an sslip.io name, check this computer's internet connection. |
| Setup: **HTTPS answers** stays | Open ports 80 and 443 in the provider's firewall; Caddy says why in `cd ~/pocketterm && sudo docker compose logs caddy`. |
| Setup: "Leave out the port" or "private address" | Type the server's public IPv4 address or its domain only, as your VPS provider shows it. |
| Phone can't reach a computer that runs the server | Install the Tailscale app on the phone, sign in to the same Tailscale account and turn it on. |
| Phone: "That code doesn't work" | It ran out (10 minutes) or was used already: make a new one (**Settings → Add a phone…**). |
| Phone: "Too many tries" | Ten wrong codes from one place in ten minutes: wait a few minutes, then use a fresh code. |
| Phone: "<computer> isn't answering" | That computer is asleep, off, or PocketTerm isn't running there, or **Terminal from phone** (**Settings → Phone**) is off. |
| Terminal: "PocketTerm may not control Ghostty" | Allow it in System Settings → Privacy & Security → Automation → PocketTerm. |
| Terminal: kitty windows don't show | **Settings → Terminals → Set up**, then restart kitty. |
| Terminal: Ghostty shows no screen, or the phone can't answer | Install tmux (`brew install tmux`): sessions the phone starts in Ghostty run in tmux. For windows you open yourself, **Settings → Terminals → Start new windows in tmux**. |
| Terminal: no windows on Windows | Only WezTerm windows are listed; install it from **Settings → Terminals**. |
| Terminal: a Ghostty session isn't matched to its window | Ghostty tells no tty, so PocketTerm matches the session by its folder and, when several Ghostty windows share it, by the window title omp sets (the session's title, or the folder's name until it has one) and by which windows other sessions already run in. Give a session a title, or keep one Ghostty window per folder. |
| Windows: "This computer reads PNG and JPEG images only." | Send PNG or JPEG images; the phone apps send JPEG. |
| Claude Code sessions don't show up | Claude Code needs 2.1.287 or later with mods on. If Settings says mods are off, run `claude /login`, start `claude` once, then type `/reload-plugins` in your sessions. |
| Phone: omp or Claude windows show only as screens (**Screen only**), not as conversations | Where PocketTerm is installed in that agent, open the window on the phone and tap **Switch to conversation**: omp restarts on the same conversation (`omp -c`; if it was working, **Restart and continue** has it carry on), Claude Code reloads its plugins (nothing restarts). Otherwise the note above them says why: PocketTerm isn't installed in that agent (**Install** in Settings' status bar or **Settings → Coding agents**), it's out of date (**Update**), or the window's terminal can't press keys and type. Then, once per session: in Claude Code type `/reload-plugins`; in omp quit it and run `omp -c`. If the switch says "It didn't come back as a conversation", look at the window on the computer: omp may still be asking something or the shell may not have run `omp -c`. |

## Removing it

**Settings → Account → Sign out** on each computer. On a computer that runs the server, **Erase this server's data** first signs every computer and phone out and deletes what it keeps. On a VPS, `cd ~/pocketterm && sudo docker compose down -v` stops the server and deletes its data; then delete the VPS.
