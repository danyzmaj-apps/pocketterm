# PocketTerm on Supabase

The PocketTerm server as a Supabase project: the third setup choice in the desktop wizard ([docs/SELF_HOSTING.md](../../../docs/SELF_HOSTING.md#supabase)). It speaks the same protocol as the PocketTerm server ([PROTOCOL.md](../../../packages/pocketterm_server/PROTOCOL.md#pocketterm-on-supabase)), so the apps use it the same way.

- `migrations/`: the `pocketterm` schema (devices, computers, pairing codes, push and Live Activity tokens with each iPhone activity's last state, blobs, redeem failures), the `public.pocketterm_*` functions only the service role may call, the private Storage bucket `pocketterm-blobs`, the Realtime policies and the pg_cron tick. A change goes in a new migration: projects set up before keep the ones they applied.
- `functions/pocketterm/index.ts`: the Edge Function `pocketterm`, deployed without JWT checks (it checks device tokens itself), at `https://<ref>.supabase.co/functions/v1/pocketterm`.

## How the desktop setup deploys it

The desktop app bundles this folder as assets. With a personal access token it uses Supabase's Management API (`lib/onboarding/supabase_admin.dart`, `lib/onboarding/supabase_setup.dart`): it creates a project named PocketTerm (or updates the one that already has PocketTerm on it), applies the migrations it hasn't applied yet, imports a new ES256 signing key as the project's JWT signing key and keeps it as the function secret `PT_REALTIME_JWK`, makes Realtime private-only, deploys the function, and signs the computer in with a fresh setup token (only its hash goes to the database). Every step can run again. The token is used only during setup and never stored.

## Running it locally

`tool/supabase-local.sh` runs it on a local Supabase in Docker (colima's socket unless `DOCKER_HOST` is set), on ports 55420-55429, in a throwaway project at `~/.cache/pocketterm-supabase`:

```sh
tool/supabase-local.sh start   # copy this folder in and start
tool/supabase-local.sh sync    # copy the function and migrations again
tool/supabase-local.sh reset   # empty the database and apply the migrations again
tool/supabase-local.sh link    # a computer's setup link
tool/supabase-local.sh stop    # stop and remove the throwaway project
```

The client tests run against it from `packages/pocketterm_core`:

```sh
POCKETTERM_SUPABASE=1 fvm flutter test -j 1 test/server_client_test.dart test/session_test.dart
# -j 1: each test empties the one local project, so test files must not run side by side.
```

## Design

- **Database through the function only.** The function calls the Postgres functions (RPCs) with the service key; nothing in the schema is open to the publishable key. Device tokens, pairing codes and the setup token are stored as hashes.
- **Live channel.** Supabase Realtime broadcast on private topics (each computer's id). `POST /v1/live/token` mints a device a 10-minute ES256 token, signed with the imported signing key, carrying the claim `pt_device`. Row level security on `realtime.messages` lets it in only while that device still exists. Messages are the same sealed envelopes as over the PocketTerm server's WebSocket.
- **`pt.left`.** When a device is signed out, an empty `pt.left` is broadcast on every computer's topic; devices then check they're still signed in. A signed-out device keeps its live connection at most until its token runs out.
- **Blobs.** Sealed images and files sit in the private bucket `pocketterm-blobs` for at most 1 hour, within caps of 200 MiB per device and 1 GiB in all.
- **Tick.** pg_cron calls the function every minute: it ends Live Activities of computers that went quiet and cleans up old blobs, pairing codes and redeem failures.
- **Pushes.** Sealed to the relay's key exactly as the PocketTerm server does (sealed request, opaque tags, no ids). A computer's check-in (`PUT /v1/desktops/:id`) sends the iPhones following its sessions their last state again once it is 110 seconds old, quietly, so their Live Activities don't go stale while it is idle.

Differences from the PocketTerm server:

- Push retries happen inside the request's background time (up to 5 attempts within 2 minutes) instead of the server's 2-minute queue.
- The redeem throttle keys on the first `X-Forwarded-For` address, as Supabase's edge reports it.
- No `GET /v1/ws`: the live channel is Realtime. Two extra endpoints: `POST /v1/setup/new` and `POST /v1/live/token`.
- Free projects pause after about a week without use; restore at [supabase.com/dashboard](https://supabase.com/dashboard).

Security, and what Supabase sees: [SECURITY.md](../../../SECURITY.md).
