#!/bin/bash
# The installed-app smoke: a release build of PocketTerm, copied to a
# throwaway place as its own app (bundle id <id>.smoke, ad-hoc signed), started
# by Launch Services (`open -n -a`, as from Finder: no TERM, no locale,
# launchd's PATH) with a throwaway home, tmux, kitty socket folder and Keychain
# namespace (POCKETTERM_PROFILE), and driven through macOS accessibility
# (tool/smoke/ax.swift). The person's data, terminals, tmux and Serve settings
# stay as they are.
#
#   tool/smoke/run.sh prepare [<PocketTerm.app>]   copy + throwaway home (default: the release build)
#   tool/smoke/run.sh launch [--real-tailscale]    start it; Tailscale is a stand-in (fake_tailscale.sh)
#                                                  unless --real-tailscale (then never press Start while
#                                                  `tailscale serve status` serves anything)
#   tool/smoke/run.sh ax <command> [args…]         ax.swift on the running copy (dump, texts, has, press, set)
#   tool/smoke/run.sh shot <name>                  screenshot of its window → $SHOTS/<name>.png
#   tool/smoke/run.sh quit                         quits it
#   tool/smoke/run.sh clean                        quits it and removes everything it made
#
# SMOKE (default /private/tmp/pt-smoke) holds it all; SHOTS (default
# /private/tmp/pt-smoke-shots) the screenshots, which `clean` keeps. Needs
# Accessibility and Screen Recording for the terminal it runs in (System
# Settings → Privacy & Security).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
SMOKE=${SMOKE:-/private/tmp/pt-smoke}
bundle=com.danyzmaj.pocketterm.smoke
app="$SMOKE/PocketTerm Smoke.app"
home="$SMOKE/home"
SHOTS=${SHOTS:-/private/tmp/pt-smoke-shots}
ax="$SMOKE/ax"

pid() { /usr/bin/pgrep -f "^$app/Contents/MacOS/" | head -1; }

case "${1:-}" in
  prepare)
    src=${2:-$repo/apps/pocketterm-desktop/build/macos/Build/Products/Release/PocketTerm.app}
    rm -rf "$SMOKE"
    mkdir -p "$SHOTS" "$SMOKE/t" "$SMOKE/k" "$home/.config" "$home/.local/bin" "$home/Projects/smoke é漢"
    chmod 700 "$SMOKE/t" "$SMOKE/k"
    /usr/bin/swiftc -O -o "$ax" "$here/ax.swift"
    # The throwaway home's own login Keychain (macOS looks for it under HOME;
    # without one it asks "Keychain Not Found"): nothing goes in the person's.
    mkdir -p "$home/Library/Keychains"
    HOME="$home" /usr/bin/security create-keychain -p smoke "$home/Library/Keychains/login.keychain-db"
    HOME="$home" /usr/bin/security set-keychain-settings "$home/Library/Keychains/login.keychain-db"
    /usr/bin/ditto "$src" "$app"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle" -c "Set :CFBundleName PocketTerm Smoke" "$app/Contents/Info.plist"
    # Every launch of the copy is throwaway, however it's opened (a link, the
    # Dock, `open -n` without --env): Launch Services hands it these.
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" \
      -c "Add :LSEnvironment:HOME string $home" -c "Add :LSEnvironment:TMUX_TMPDIR string $SMOKE/t" \
      -c "Add :LSEnvironment:POCKETTERM_KITTY_DIR string $SMOKE/k" -c "Add :LSEnvironment:POCKETTERM_PROFILE string smoke" \
      "$app/Contents/Info.plist"
    /usr/bin/codesign --force --deep --sign - "$app" 2>/dev/null
    # Claude Code as installed, in the throwaway home (its own ~/.claude there).
    for c in "$HOME/.local/bin/claude"; do [ -e "$c" ] && ln -s "$(readlink -f "$c")" "$home/.local/bin/claude"; done
    cp "$here/fake_tailscale.sh" "$SMOKE/tailscale"
    chmod 755 "$SMOKE/tailscale"
    echo "$app"
    ;;
  launch)
    env=(--env "HOME=$home" --env "TMUX_TMPDIR=$SMOKE/t" --env "POCKETTERM_KITTY_DIR=$SMOKE/k"
         --env "POCKETTERM_PROFILE=smoke")
    if [ "${2:-}" != --real-tailscale ]; then
      env+=(--env "POCKETTERM_TAILSCALE=$SMOKE/tailscale" --env "FAKE_TAILSCALE_STATE=$SMOKE/serve.json")
    fi
    /usr/bin/open -n -a "$app" "${env[@]}"
    for _ in $(seq 1 100); do [ -n "$(pid)" ] && break; sleep 0.1; done
    p=$(pid)
    [ -n "$p" ] || { echo "it didn't start" >&2; exit 1; }
    # Its accessibility tree builds once the window's first frames are out.
    for _ in $(seq 1 100); do "$ax" "$p" has "PocketTerm" 2>/dev/null && [ "$("$ax" "$p" texts | wc -l)" -gt 3 ] && break; sleep 0.2; done
    echo "$p"
    ;;
  ax)
    shift
    "$ax" "$(pid)" "$@"
    ;;
  shot)
    w=$("$ax" "$(pid)" window)
    /usr/sbin/screencapture -x -o -l "$w" "$SHOTS/$2.png"
    echo "$SHOTS/$2.png"
    ;;
  quit|clean)
    p=$(pid || true)
    if [ -n "$p" ]; then
      /usr/bin/osascript -e "tell application id \"$bundle\" to quit" >/dev/null 2>&1 || kill "$p"
      for _ in $(seq 1 50); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done
      kill -9 "$p" 2>/dev/null || true
    fi
    [ "$1" = quit ] && exit 0
    # Its tmux server, its Keychain items (the throwaway Keychain, and any it
    # put in the person's under its own service), its preferences and data
    # (under the throwaway home or the real one, whichever macOS used), then
    # the folder.
    for s in "$SMOKE"/t/tmux-*/*; do
      if [ -S "$s" ]; then /opt/homebrew/bin/tmux -S "$s" kill-server 2>/dev/null || true; fi
    done
    if [ -f "$home/Library/Keychains/login.keychain-db" ]; then
      HOME="$home" /usr/bin/security delete-keychain "$home/Library/Keychains/login.keychain-db" || true
    fi
    while /usr/bin/security delete-generic-password -s PocketTerm.smoke >/dev/null 2>&1; do :; done
    /usr/bin/defaults delete "$bundle" >/dev/null 2>&1 || true
    # What macOS asked about it (Automation: controlling Ghostty).
    /usr/bin/tccutil reset All "$bundle" >/dev/null 2>&1 || true
    for h in "$home" "$HOME"; do
      rm -rf "$h/Library/Preferences/$bundle.plist" "$h/Library/Application Support/$bundle" \
        "$h/Library/Caches/$bundle" "$h/Library/Saved Application State/$bundle.savedState" \
        "$h/Library/HTTPStorages/$bundle" "$h/Library/WebKit/$bundle"
    done
    rm -rf "$SMOKE"
    ;;
  *)
    sed -n '2,24p' "$0"
    exit 2
    ;;
esac
