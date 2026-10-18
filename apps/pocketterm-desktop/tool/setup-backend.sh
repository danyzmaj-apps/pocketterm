#!/usr/bin/env bash
# Sets up your own PocketTerm backend on a Supabase project you created at
# https://supabase.com/dashboard (the free plan is plenty): database, sign-in
# and edge functions. Safe to run again, e.g. after pulling a new
# version (it applies new migrations and redeploys the functions).
#
#   apps/pocketterm-desktop/tool/setup-backend.sh [project-ref]
#
# Needs the Supabase CLI (brew install supabase/tap/supabase), logged in
# (supabase login), and jq (part of macOS 15 and later; brew or your
# package manager otherwise). Walkthrough: docs/SELF_HOSTING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31msetup: %s\033[0m\n' "$*" >&2; exit 1; }
ask() { # ask VAR "prompt" [default] [secret]
  local reply
  if [[ "${4:-}" == secret ]]; then read -rsp "$2: " reply && echo; else read -rp "$2${3:+ [$3]}: " reply; fi
  printf -v "$1" '%s' "${reply:-${3:-}}"
}

command -v supabase >/dev/null || die "install the Supabase CLI first: brew install supabase/tap/supabase"
command -v jq >/dev/null || die "install jq first: brew install jq (or your package manager's jq)"
supabase projects list >/dev/null 2>&1 || die "log in first: supabase login"

REF="${1:-}"
if [[ -z "$REF" ]]; then
  say "Your Supabase projects:"
  supabase projects list
  ask REF "Project ref (the id in https://<ref>.supabase.co)"
fi
[[ "$REF" =~ ^[a-z0-9]{20}$ ]] || die "'$REF' isn't a project ref (20 lowercase letters and digits)"
URL="https://$REF.supabase.co"

say "1/5  Linking $REF"
supabase link --project-ref "$REF"

say "2/5  GitHub sign-in"
ENV=supabase/.env
touch "$ENV" && chmod 600 "$ENV"
if grep -q '^GITHUB_CLIENT_SECRET=.' "$ENV"; then
  echo "Using the GitHub OAuth app in $ENV."
else
  cat <<EOF
Create a GitHub OAuth app: https://github.com/settings/applications/new
  Application name:            PocketTerm
  Homepage URL:                https://github.com/danyzmaj-apps/pocketterm
  Authorization callback URL:  $URL/auth/v1/callback
Then generate a client secret on its page.
EOF
  ask GITHUB_CLIENT_ID "Client ID"
  ask GITHUB_CLIENT_SECRET "Client secret" "" secret
  [[ -n "$GITHUB_CLIENT_ID" && -n "$GITHUB_CLIENT_SECRET" ]] || die "both are needed"
  grep -v '^GITHUB_CLIENT_' "$ENV" >"$ENV.tmp" || true
  printf 'GITHUB_CLIENT_ID=%s\nGITHUB_CLIENT_SECRET=%s\n' "$GITHUB_CLIENT_ID" "$GITHUB_CLIENT_SECRET" >>"$ENV.tmp"
  mv "$ENV.tmp" "$ENV" && chmod 600 "$ENV"
fi

say "3/5  Database"
supabase db push --yes

say "4/5  Auth settings (GitHub, the pocketterm:// redirect, private sign-up)"
supabase config push --yes

say "5/5  Edge functions"
supabase functions deploy pair --no-verify-jwt
supabase functions deploy push --no-verify-jwt

KEY=$(supabase projects api-keys --project-ref "$REF" -o json | jq -r 'map(select(.type == "publishable"))[0].api_key // empty')
[[ -n "$KEY" ]] || die "no publishable key on this project (Project Settings → API Keys → create one)"

curl -fsS "$URL/auth/v1/settings" -H "apikey: $KEY" | grep -q '"github":true' \
  || die "GitHub sign-in didn't turn on; check Authentication → Sign In / Providers in the dashboard"

LINK="pocketterm://setup?url=$(printf %s "$URL" | sed 's/:/%3A/g; s#/#%2F#g')&key=$KEY"
say "Done. Your backend is ready."
cat <<EOF

Connect PocketTerm on this computer by opening the setup link (or paste it into PocketTerm's
setup screen). Phones sign in with a code from the computer: once you're signed in
there, Settings → Set up phone….

  $LINK

The first account to sign in owns this server; nobody else can sign up
unless you add their email (docs/SELF_HOSTING.md, "Sharing").
EOF
if [[ -d /Applications/PocketTerm.app ]]; then
  ask OPEN "Open it in PocketTerm now? (y/n)" "y"
  [[ "$OPEN" == y* ]] && open "$LINK"
fi
