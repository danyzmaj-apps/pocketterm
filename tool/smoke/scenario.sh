#!/bin/bash
# Scenarios for the installed-app smoke: each walks the throwaway copy
# (tool/smoke/run.sh) through a part of PocketTerm by accessibility and
# prints a PASS or FAIL line per check, then a summary. It exits 1 on any
# FAIL.
#
#   tool/smoke/run.sh prepare                    first, for a copy never set up
#   tool/smoke/scenario.sh <name>…               these, in this order when several:
#     wizard     On this computer: the Tailscale checklist through each state
#                (stopped, signed out, HTTPS off, port 443 taken, all done), Start
#                enabled only when all is done; Start, then Get this computer ready
#     getready   Get this computer ready: its rows, then Done opens Settings
#     settings   Settings: each tab, How your data is protected (Read…), the status bar
#     menubar    the window closed, the menu bar icon opens it again
#     quit       Settings → Account → Quit PocketTerm: the copy is gone
#
# It drives the copy only through run.sh (launch, ax, shot). It starts the
# copy itself, always with the stand-in Tailscale (fake_tailscale.sh), and
# stops when a copy it didn't start runs: that one may use the real
# Tailscale. Tailscale's states come from the files next to the stand-in's
# state. It never toggles Launch at login, never opens Tailscale and never
# touches the person's Tailscale, Keychain or login items.
#
# Needs Accessibility and Screen Recording for the terminal it runs in
# (System Settings → Privacy & Security). The menu bar icon's right-click
# menu (Open PocketTerm, Settings…, Check for Updates…, Quit PocketTerm)
# needs a real right click and stays a manual check.
set -u
here=$(cd "$(dirname "$0")" && pwd)
run=$here/run.sh
SMOKE=${SMOKE:-/private/tmp/pt-smoke}
export SMOKE
app="$SMOKE/PocketTerm Smoke.app"
state=$SMOKE/serve.json
# The copy this script started, so it never drives one it didn't.
started=$SMOKE/scenario.pid
# Another proxy on port 443 of the stand-in's name (fake_tailscale.sh).
taken='{"TCP":{"443":{"HTTPS":true}},"Web":{"pocketterm-smoke.tail0000.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}}}'
passed=0
failed=0
scenario=setup

pass() { echo "PASS $scenario: $*"; passed=$((passed + 1)); }
fail() { echo "FAIL $scenario: $*"; failed=$((failed + 1)); }
step() { echo "== $scenario: $*"; }

pid() { /usr/bin/pgrep -f "^$app/Contents/MacOS/" | head -1; }
running() { [ -n "$(pid)" ]; }
ax() { "$run" ax "$@" 2>/dev/null; }
has() { ax has "$1" >/dev/null; }
hasnt() { ! has "$1"; }
window() { ax window >/dev/null; }
no_window() { ! window; }
# `ax enabled` exits 1 for a disabled element, 3 when there's none.
enabled() { ax enabled "$1" >/dev/null; }
disabled() {
  ax enabled "$1" >/dev/null
  [ $? -eq 1 ]
}

# wait_for <seconds> <command…>: until it succeeds, or false after that long.
wait_for() {
  local end=$((SECONDS + $1))
  shift
  until "$@"; do
    [ $SECONDS -ge $end ] && return 1
    sleep 0.3
  done
}

# check <what> <command…>: PASS or FAIL as it goes.
check() {
  local what=$1
  shift
  if "$@"; then pass "$what"; else fail "$what"; fi
}

# The checklist looks at Tailscale every 3 seconds: 15 is time for a few looks.
shows() { check "shows \"$1\"" wait_for "${2:-15}" has "$1"; }
hides() { check "no \"$1\"" wait_for "${2:-15}" hasnt "$1"; }
quiet() { "$@" >/dev/null; }
press() { check "press \"$1\"" quiet ax press "$1"; }
shot() { check "screenshot $1" quiet "$run" shot "$1"; }

# tailscale_as <backend> <certs on|off> <port 443 free|taken>: what the stand-in answers from its next call.
tailscale_as() {
  echo "$1" > "$state.backend"
  echo "$2" > "$state.certs"
  if [ "$3" = taken ]; then echo "$taken" > "$state"; else echo '{}' > "$state"; fi
}

# Back to a running, signed in Tailscale with HTTPS on; port 443 freed of the proxy this script put there.
restore_tailscale() {
  rm -f "$state.backend" "$state.certs"
  if [ -f "$state" ] && [ "$(cat "$state")" = "$taken" ]; then echo '{}' > "$state"; fi
}

summary() {
  echo "$passed passed, $failed failed"
  [ $failed -eq 0 ]
}

# A prepared copy, up to date with this folder, running with the stand-in Tailscale, its window open.
ready() {
  if [ ! -x "$SMOKE/ax" ] || [ ! -d "$app" ]; then
    fail "no prepared copy in $SMOKE: run tool/smoke/run.sh prepare"
    return 1
  fi
  if ! /usr/bin/cmp -s "$here/fake_tailscale.sh" "$SMOKE/tailscale" || [ "$here/ax.swift" -nt "$SMOKE/ax" ]; then
    fail "the copy's stand-in Tailscale or ax is older than tool/smoke: run tool/smoke/run.sh prepare"
    return 1
  fi
  if running; then
    if [ "$(pid)" != "$(cat "$started" 2>/dev/null)" ]; then
      fail "a copy this script didn't start is running (it may use the real Tailscale): run tool/smoke/run.sh quit"
      return 1
    fi
  else
    restore_tailscale
    "$run" launch > "$started" || {
      fail "the copy didn't start"
      return 1
    }
    pass "launched with the stand-in Tailscale (pid $(cat "$started"))"
  fi
  if no_window; then ax press-extra PocketTerm >/dev/null; fi
  if ! wait_for 15 window; then
    fail "its window isn't on screen"
    return 1
  fi
}

# Copies: apps/pocketterm-desktop/lib/setup_page.dart (ThisComputerSetup) and
# lib/hosting/hosting_view.dart (phoneTailscaleNote).
wizard() {
  if has 'Open setup checklist' || has 'Get this computer ready'; then
    fail "this copy is set up already; the wizard needs a fresh one (run.sh clean, then run.sh prepare)"
    return
  fi
  tailscale_as Stopped on free
  if has 'Set up PocketTerm'; then press 'On this computer'; fi
  shows 'This list checks itself as you go.'
  shows 'What is Tailscale, and why?'
  shows 'Your phone needs the Tailscale app too, signed in to the same Tailscale account.'

  # Each state's first check is a copy only it shows: the list has looked again by then.
  step 'Tailscale stopped'
  shows 'Open Tailscale and switch it on.'
  shows 'Tailscale is installed'
  shows 'Start Tailscale'
  shows 'Open Tailscale'
  shows 'Sign in to Tailscale'
  shows 'Turn on HTTPS certificates'
  shows 'Tailscale’s HTTPS port (443) for PocketTerm'
  hides 'Tailscale is running'
  check 'Start is disabled' disabled Start
  shot wizard-1-stopped

  step 'Tailscale signed out'
  tailscale_as NeedsLogin on free
  shows 'Any account works: Google, GitHub, Microsoft or Apple. Use the same one on your phone.'
  shows 'Tailscale is running'
  shows 'Sign in to Tailscale'
  shows 'Open Tailscale to sign in'
  hides 'Signed in to Tailscale'
  check 'Start is disabled' disabled Start
  shot wizard-2-signed-out

  step 'HTTPS certificates off'
  tailscale_as Running off free
  shows 'On the Tailscale page that opens, turn on HTTPS (and MagicDNS, if it asks).'
  shows 'Signed in to Tailscale'
  shows 'Turn on HTTPS certificates'
  shows 'Turn on HTTPS…'
  shows 'Use my own server instead'
  hides 'HTTPS certificates are on'
  check 'Start is disabled' disabled Start
  shot wizard-3-https-off

  step 'port 443 taken'
  tailscale_as Running on taken
  shows 'Tailscale already serves http://127.0.0.1:3000 there. PocketTerm needs that port and won’t replace it'
  shows 'HTTPS certificates are on'
  shows 'Free Tailscale’s HTTPS port (443)'
  check 'Start is disabled' disabled Start
  shot wizard-4-port-taken

  step 'all done'
  tailscale_as Running on free
  shows 'Tailscale’s HTTPS port is free for PocketTerm'
  hides 'Tailscale already serves'
  check 'Start is enabled' wait_for 15 enabled Start
  shot wizard-5-all-done

  step 'Start'
  press Start
  # The built-in server starts, Tailscale serves it, this computer signs in.
  if wait_for 90 has 'Get this computer ready'; then
    pass 'shows "Get this computer ready"'
  else
    fail 'shows "Get this computer ready"; the window says:'
    ax texts | sed 's/^/    /'
  fi
  check 'the stand-in Tailscale serves the built-in server' wait_for 30 served
  shot wizard-6-started
  restore_tailscale
}

served() { [[ $(cat "$state" 2>/dev/null) == *'"Proxy":"http://127.0.0.1:'* ]]; }

# Copies: apps/pocketterm-desktop/lib/onboarding/get_ready.dart, lib/hosting/hosting_view.dart,
# lib/main_window.dart.
getready() {
  if has 'Open setup checklist'; then press 'Open setup checklist'; fi
  shows 'Get this computer ready'
  shows 'A few things so your phone sees your coding sessions and terminals.'
  shows 'Your coding agents'
  shows 'Your terminals'
  shows 'Project folders'
  shows 'Your phone'
  # Once the built-in server is served: the phone's code needs Tailscale's address.
  shows 'Your phone needs the Tailscale app too, signed in to the same Tailscale account.' 30
  shows 'PocketTerm for iPhone is on TestFlight and for Android on Google Play internal testing'
  shot getready
  press Done
  shows 'Open setup checklist'
  hides 'Get this computer ready'
  shot getready-done
}

# The status bar's line: checking, all set, or what needs attention.
settled() { has 'All set' || has 'attention'; }

# tab <label> <a copy only it shows> <the previous tab's copy>
tab() {
  step "$1 tab"
  press "$1"
  shows "$2"
  [ -n "${3:-}" ] && hides "$3"
  shot "settings-$(echo "$1" | tr 'A-Z ' 'a-z-')"
}

# Copies: apps/pocketterm-desktop/lib/main_window.dart, lib/onboarding/data_protection.dart.
settings() {
  if ! wait_for 5 has 'Open setup checklist'; then
    fail "Settings isn't open (run getready first)"
    return
  fi
  step 'status bar'
  check 'status bar: All set, or what needs attention' wait_for 60 settled
  shows 'Open setup checklist'
  tab Phone 'Terminal from phone'
  shows 'Your phones'
  shows 'Your phone lists the git repositories in these (up to three levels deep)'
  tab 'Coding agents' 'The default agent is what a new session from your phone starts.' 'Terminal from phone'
  tab Terminals 'New sessions open in' 'The default agent is what a new session from your phone starts.'
  tab Account 'Quit PocketTerm' 'New sessions open in'
  shows 'Your server'
  shows 'Launch at login'
  shows 'How your data is protected'

  step 'How your data is protected'
  press 'Read…'
  shows 'Encrypted from end to end'
  shows 'The QR code is a key'
  shot settings-data-protection
  press Done
  hides 'Encrypted from end to end'
}

# Copies: apps/pocketterm-desktop/macos/Runner/MainFlutterWindow.swift (the icon's accessibility description).
menubar() {
  local heading=''
  for h in 'Open setup checklist' 'Get this computer ready' 'This list checks itself as you go.' 'Set up PocketTerm'; do
    if has "$h"; then
      heading=$h
      break
    fi
  done
  check 'a menu bar icon labelled PocketTerm' extra_listed
  check 'press the close button' quiet ax close
  check 'the window is closed' wait_for 10 no_window
  check 'press the menu bar icon' quiet ax press-extra PocketTerm
  check 'the window is back' wait_for 10 window
  [ -n "$heading" ] && shows "$heading"
  shot menubar-back
}

extra_listed() { [[ $(ax extras) == *PocketTerm* ]]; }

# Copies: apps/pocketterm-desktop/lib/main_window.dart.
quit() {
  if ! wait_for 5 has 'Open setup checklist'; then
    fail "Settings isn't open (run getready first)"
    return
  fi
  press Account
  shows 'Quit PocketTerm'
  press 'Quit PocketTerm'
  check 'the copy quit' wait_for 15 stopped
  rm -f "$started"
}

stopped() { ! running; }

names=("$@")
if [ ${#names[@]} -eq 0 ]; then
  sed -n '2,27p' "$0"
  exit 2
fi
for name in "${names[@]}"; do
  case "$name" in
    wizard | getready | settings | menubar | quit) ;;
    *)
      echo "unknown scenario: $name (wizard, getready, settings, menubar, quit)" >&2
      exit 2
      ;;
  esac
done
trap restore_tailscale EXIT
for name in "${names[@]}"; do
  scenario=setup
  ready || break
  scenario=$name
  "$name"
done
summary || exit 1
