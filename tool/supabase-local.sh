#!/usr/bin/env bash
# PocketTerm on a local Supabase in Docker, for tests and the E2E run (tool/e2e --server supabase).
#
#   tool/supabase-local.sh start   # copies apps/pocketterm-desktop/supabase into a throwaway project, starts it
#   tool/supabase-local.sh sync    # copies the function and migrations again (the function reloads; new
#                                  # migrations need `reset`)
#   tool/supabase-local.sh reset   # empties the database and applies the migrations again
#   tool/supabase-local.sh link    # a computer's setup link (a new setup token each time)
#   tool/supabase-local.sh stop    # stops it and removes the throwaway project
#
# The project lives in $POCKETTERM_SUPABASE_DIR (default ~/.cache/pocketterm-supabase: Docker under colima sees
# only the home folder, and the functions are mounted from there) with its own config.toml on
# ports 55420-55429 (another project of this Mac uses Supabase's default 54321-54329), a throwaway ES256 key the
# function signs Realtime tokens with, imported as the local Auth's signing key the way the desktop's setup
# imports one into a cloud project. Pushes go to http://host.docker.internal:55429/relay, sealed to the key of
# the test relay (seed 32 x 0x07; packages/pocketterm_core/test/supabase_server.dart), unless PUSH_RELAY_URL and
# PUSH_RELAY_KEY say otherwise. Docker: colima's socket unless DOCKER_HOST is set.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
src="$repo/apps/pocketterm-desktop/supabase"
dir="${POCKETTERM_SUPABASE_DIR:-$HOME/.cache/pocketterm-supabase}"
export DOCKER_HOST="${DOCKER_HOST:-unix://$HOME/.colima/default/docker.sock}"
export SUPABASE_TELEMETRY_DISABLED=1
api_port=55421
db_container=supabase_db_pocketterm-local
# Where pg_cron (in the database's container) reaches the function.
tick_url=http://kong:8000/functions/v1/pocketterm/v1/tick

sync() {
  mkdir -p "$dir/supabase/functions"
  rm -rf "$dir/supabase/migrations" "$dir/supabase/functions/pocketterm"
  cp -R "$src/migrations" "$dir/supabase/migrations"
  cp -R "$src/functions/pocketterm" "$dir/supabase/functions/pocketterm"
}

psql_c() {
  docker exec -i "$db_container" psql -v ON_ERROR_STOP=1 -U postgres -d postgres -Atq -c "$1"
}

case "${1:-}" in
start)
  mkdir -p "$dir/supabase"
  sync
  if [ ! -f "$dir/supabase/signing_keys.json" ]; then
    supabase gen signing-key --algorithm ES256 2>/dev/null |
      deno eval 'const k = JSON.parse(await new Response(Deno.stdin.readable).text()); console.log(JSON.stringify(Array.isArray(k) ? k : [k]))' \
        >"$dir/supabase/signing_keys.json"
    chmod 600 "$dir/supabase/signing_keys.json"
  fi
  cat >"$dir/supabase/config.toml" <<EOF
project_id = "pocketterm-local"

[api]
port = $api_port

[db]
port = 55422
shadow_port = 55420
major_version = 17

[db.pooler]
enabled = false

[studio]
enabled = false

[local_smtp]
enabled = false

[analytics]
enabled = false

[storage]
file_size_limit = "50MiB"

[auth]
signing_keys_path = "./signing_keys.json"

[edge_runtime]
policy = "per_worker"
deno_version = 2

[edge_runtime.secrets]
PT_REALTIME_JWK = "env(PT_REALTIME_JWK)"
PUSH_RELAY_URL = "env(PUSH_RELAY_URL)"
PUSH_RELAY_KEY = "env(PUSH_RELAY_KEY)"

[functions.pocketterm]
verify_jwt = false
EOF
  # The key as the function takes it: the one JWK (the file holds a list).
  PT_REALTIME_JWK="$(deno eval 'const k = JSON.parse(Deno.readTextFileSync(Deno.args[0])); console.log(JSON.stringify(Array.isArray(k) ? k[0] : k))' "$dir/supabase/signing_keys.json")"
  export PT_REALTIME_JWK
  export PUSH_RELAY_URL="${PUSH_RELAY_URL:-http://host.docker.internal:55429/relay}"
  export PUSH_RELAY_KEY="${PUSH_RELAY_KEY:-E75P6uryBMf9M1j8nAByGIHRdCeBKCJ+xnTzf3/pe20=}"
  (cd "$dir" && supabase start >"$dir/start.log" 2>&1) || { cat "$dir/start.log" >&2; exit 1; }
  psql_c "select public.pocketterm_tick_url('$tick_url')"
  echo "http://127.0.0.1:$api_port"
  ;;
sync)
  sync
  ;;
reset)
  sync
  (cd "$dir" && supabase db reset >"$dir/reset.log" 2>&1) || { cat "$dir/reset.log" >&2; exit 1; }
  # The function says it within 10 minutes; the minute's tick needn't wait.
  psql_c "select public.pocketterm_tick_url('$tick_url')"
  ;;
link)
  token="$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')"
  hash="$(printf %s "$token" | shasum -a 256 | cut -d' ' -f1)"
  psql_c "select pocketterm.set_setup_hash('$hash')"
  echo "pocketterm://setup?kind=supabase&url=http%3A%2F%2F127.0.0.1%3A$api_port&setup=$token"
  ;;
sql)
  psql_c "$2"
  ;;
stop)
  if [ -d "$dir/supabase" ]; then
    (cd "$dir" && supabase stop --no-backup >/dev/null 2>&1) || true
  fi
  rm -rf "$dir"
  ;;
*)
  sed -n '2,15p' "$0" >&2
  exit 64
  ;;
esac
