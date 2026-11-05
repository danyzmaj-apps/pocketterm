#!/bin/bash
# Xcode build phase of the PocketTerm target: puts into the app what its services read
# (packages/PocketTermKit/Sources/PocketTermDesktop/README.md, "Wiring at launch"):
#   Contents/Helpers/pocketterm-server   the built-in server (tool/server-sidecar.sh), signed with the hardened runtime
#   Resources/integrations               the coding agents' integrations, as the Flutter app bundled them (no tests)
#   Resources/supabase                   the Supabase setup's migrations and function
#   Resources/icon/macos-<theme>.png     the other themes' Dock icons (Catppuccin Mocha's is the app's own)
#
# The server: $POCKETTERM_SIDECAR if set, else build/server-sidecar/macos-universal (tool/server-sidecar.sh with
# DART_X64), else build/server-sidecar/macos-arm64, built here when missing or older than the server's code.
set -euo pipefail
repo=$(cd "$SRCROOT/../../.." && pwd)
desktop=$repo/apps/pocketterm-desktop
app=$TARGET_BUILD_DIR/$WRAPPER_NAME
resources=$app/Contents/Resources
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/fvm/bin:$HOME/.pub-cache/bin:$PATH"

sidecar=${POCKETTERM_SIDECAR:-}
if [ -z "$sidecar" ]; then
  out=$repo/build/server-sidecar
  if [ -x "$out/macos-universal/pocketterm-server" ]; then
    sidecar=$out/macos-universal/pocketterm-server
  else
    sidecar=$out/macos-arm64/pocketterm-server
  fi
  # The server's code changed since (or it was never built): build it again.
  if [ ! -x "$sidecar" ] || [ -n "$(find "$repo/apps/pocketterm-server" "$repo/packages/pocketterm_server" \
    -name '*.dart' -newer "$sidecar" -print -quit 2>/dev/null)" ]; then
    echo "note: building the built-in server (tool/server-sidecar.sh)"
    "$repo/tool/server-sidecar.sh" --out "$out"
    [ -x "$out/macos-universal/pocketterm-server" ] && sidecar=$out/macos-universal/pocketterm-server ||
      sidecar=$out/macos-arm64/pocketterm-server
  fi
fi
[ -x "$sidecar" ] || { echo "error: no built-in server at $sidecar (tool/server-sidecar.sh)"; exit 1; }
if [ "$CONFIGURATION" = Release ] && ! lipo -archs "$sidecar" | grep -q x86_64; then
  echo "warning: the built-in server is arm64 only ($sidecar): Intel Macs can't start it. Build it with DART_X64 (tool/server-sidecar.sh)."
fi
mkdir -p "$app/Contents/Helpers"
ditto "$sidecar" "$app/Contents/Helpers/pocketterm-server"

# The Flutter app's asset list (pubspec.yaml): no tests, no READMEs.
rm -rf "$resources/integrations" "$resources/supabase" "$resources/icon"
for d in omp claude/.claude-plugin claude/plugins/pocketterm/.claude-plugin claude/plugins/pocketterm/hooks; do
  mkdir -p "$resources/integrations/$d"
  ditto "$desktop/integrations/$d" "$resources/integrations/$d"
done
for d in migrations functions/pocketterm; do
  mkdir -p "$resources/supabase/$d"
  ditto "$desktop/supabase/$d" "$resources/supabase/$d"
done
mkdir -p "$resources/icon"
for t in dawn tokyoNight; do cp "$desktop/assets/icon/macos-$t.png" "$resources/icon/"; done

# Signed before the app is (Xcode signs the bundle after this phase): the hardened runtime, as notarization wants
# for every executable. A Developer ID export signs it again with the release identity.
identity=${EXPANDED_CODE_SIGN_IDENTITY:--}
[ -n "$identity" ] || identity=-
codesign --force --options runtime --timestamp=none --identifier "$PRODUCT_BUNDLE_IDENTIFIER.server" \
  --entitlements "$SRCROOT/scripts/server.entitlements" --sign "$identity" "$app/Contents/Helpers/pocketterm-server"
