#!/usr/bin/env bash
# Builds, signs, notarizes and publishes the Mac app (apps/pocketterm-desktop/macos, native SwiftUI) as a DMG on
# GitHub Releases, with the Sparkle appcast the installed apps update from.
#
#   apps/pocketterm-desktop/tool/release.sh            the version in macos/project.yml → GitHub release v<version>
#   apps/pocketterm-desktop/tool/release.sh --dry-run  same build, Developer ID signed and appcast signed, nothing
#                                                      notarized or published (the notarytool commands are printed)
#
# The app is universal (arm64 + x86_64); so must its built-in server be (tool/server-sidecar.sh): set DART_X64 to an
# Intel Dart SDK's `dart` (run under Rosetta; e.g. unzip dartsdk-macos-x64-release.zip of the same Dart version into
# ~/.local/share/dart-x64 and set DART_X64=~/.local/share/dart-x64/dart-sdk/bin/dart). A dry run without it bundles an arm64-only server and says so; a real
# release refuses, since Intel Macs couldn't run "On this computer".
#
# Needs (checked below): Xcode signed in to the team in config/PocketTerm.xcconfig with a "Developer ID
# Application" certificate, a notarytool keychain profile for that team (NOTARY_PROFILE, default pocketterm-notary;
# `xcrun notarytool store-credentials <name>` makes one), PocketTerm's Sparkle signing key — the file
# SPARKLE_KEY_FILE (default /Users/danyzmaj/Dev/keys/pocketterm-sparkle-private-key) or else the login keychain
# under the account "pocketterm" (Sparkle's generate_keys --account pocketterm; the SPM package brings the tool),
# xcodegen, fvm (the server) and gh. See docs/RELEASING.md.
set -euo pipefail
# Runs in the Mac app (apps/pocketterm-desktop); config/ and CHANGELOG.md are the repo's, two levels up.
cd "$(dirname "$0")/.."
ROOT=../..

DRY=false
[[ "${1:-}" == "--dry-run" ]] && DRY=true
NOTARY_PROFILE="${NOTARY_PROFILE:-pocketterm-notary}"
REPO="${REPO:-danyzmaj-apps/pocketterm}"

die() { echo "release: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

setting() { sed -n "s/^ *$1: *\"\{0,1\}\([0-9.]*\)\"\{0,1\} *$/\1/p" macos/project.yml | head -1; }
VERSION=$(setting MARKETING_VERSION)
BUILD=$(setting CURRENT_PROJECT_VERSION)
[[ -n "$VERSION" && -n "$BUILD" ]] || die "no MARKETING_VERSION / CURRENT_PROJECT_VERSION in macos/project.yml"
# `claude plugin update` (Settings → Coding agents) takes a plugin only at a new version: one that kept its
# version would leave every installed copy on its old hooks while Settings calls it current.
PLUGIN_VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' integrations/claude/plugins/pocketterm/.claude-plugin/plugin.json)
[[ "$PLUGIN_VERSION" == "$VERSION" ]] ||
  die "integrations/claude/plugins/pocketterm/.claude-plugin/plugin.json is at $PLUGIN_VERSION; set its version to $VERSION"
# The VPS setup fetches docker-compose.yml from tag v$VERSION; its image must be this release's too.
COMPOSE_VERSION=$(sed -n 's/.*POCKETTERM_VERSION:-\([^}]*\)}.*/\1/p' ../pocketterm-server/docker-compose.yml)
[[ "$COMPOSE_VERSION" == "$VERSION" ]] ||
  die "apps/pocketterm-server/docker-compose.yml pins the server image at $COMPOSE_VERSION; set POCKETTERM_VERSION's default to $VERSION"
TEAM=""
[[ -f $ROOT/config/Local.xcconfig ]] && TEAM=$(sed -n 's/^POCKETTERM_TEAM *= *//p' $ROOT/config/Local.xcconfig | tail -1)
[[ -n "$TEAM" ]] || TEAM=$(sed -n 's/^POCKETTERM_TEAM *= *//p' $ROOT/config/PocketTerm.xcconfig | tail -1)
OUT=build/release
# Sparkle's tools come with its Swift package, resolved into the archive's derived data.
SPARKLE=$OUT/dd/SourcePackages/artifacts/sparkle/Sparkle/bin
# The keychain account PocketTerm's Sparkle key is stored under (its public half is SUPublicEDKey in Info.plist).
SPARKLE_ACCOUNT=pocketterm
SPARKLE_KEY_FILE="${SPARKLE_KEY_FILE:-/Users/danyzmaj/Dev/keys/pocketterm-sparkle-private-key}"
# Fed on stdin so the key never lands in argv; a keychain read would stall the script on an access prompt.
sparkle_sign() {
  if [[ -f "$SPARKLE_KEY_FILE" ]]; then "$@" --ed-key-file - <"$SPARKLE_KEY_FILE"; else "$@" --account "$SPARKLE_ACCOUNT"; fi
}
DMG="$OUT/PocketTerm-$VERSION.dmg"

step "Checking prerequisites (v$VERSION build $BUILD, team $TEAM)"
command -v xcodegen >/dev/null || die "xcodegen is not installed (brew install xcodegen)"
command -v fvm >/dev/null || die "fvm is not installed (https://fvm.app)"
if ! $DRY; then
  command -v gh >/dev/null || die "gh is not installed (brew install gh)"
  [[ -n "${DART_X64:-}" ]] || die "DART_X64 is not set: the built-in server would be arm64 only (see the top of this script)"
  [[ -z "$(git status --porcelain)" ]] || die "the working tree has uncommitted changes"
  git rev-parse "v$VERSION" >/dev/null 2>&1 && die "tag v$VERSION exists; bump MARKETING_VERSION (and CURRENT_PROJECT_VERSION) in macos/project.yml"
  grep -q "^## $VERSION" $ROOT/CHANGELOG.md || die "CHANGELOG.md has no '## $VERSION' section"
  git fetch --quiet origin main || die "can't fetch origin/main"
  git merge-base --is-ancestor HEAD origin/main || die "HEAD isn't on origin/main; release from a pushed main commit"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "no notarytool profile '$NOTARY_PROFILE' (xcrun notarytool store-credentials $NOTARY_PROFILE)"
fi
# The SHA-1 of this team's identity, so codesign never finds another team's certificate ambiguous.
IDENTITY=$(security find-identity -v -p codesigning \
  | awk -v t="($TEAM)" '/Developer ID Application/ && index($0, t) { print $2; exit }')
[[ -n "$IDENTITY" ]] \
  || die "no 'Developer ID Application' certificate for team $TEAM (Xcode → Settings → Accounts → Manage Certificates → +)"

step "Building the built-in server"
rm -rf "$OUT" && mkdir -p "$OUT"
# Absolute: server-sidecar.sh resolves relative paths from the repo root.
$ROOT/tool/server-sidecar.sh --out "$PWD/$OUT/server-sidecar"
SIDECAR=$OUT/server-sidecar/macos-universal/pocketterm-server
if [[ ! -x "$SIDECAR" ]]; then
  $DRY || die "no universal server was built"
  SIDECAR=$OUT/server-sidecar/macos-arm64/pocketterm-server
  echo "release: dry run: the built-in server is arm64 only (set DART_X64 for a universal one)" >&2
fi
SIDECAR=$(cd "$(dirname "$SIDECAR")" && pwd)/pocketterm-server

step "Archiving"
(cd macos && xcodegen generate --quiet)
# A generic destination: with "My Mac" listed per arch, xcodebuild otherwise picks one and can stall.
xcodebuild -quiet -project macos/PocketTerm.xcodeproj -scheme PocketTerm -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$OUT/dd" -archivePath "$OUT/PocketTerm.xcarchive" -allowProvisioningUpdates \
  POCKETTERM_SIDECAR="$SIDECAR" archive
[[ -x "$SPARKLE/generate_keys" ]] || die "Sparkle's tools aren't in $SPARKLE (did the Sparkle package resolve?)"
# Presence only (no -w): reading the secret would prompt for keychain access.
[[ -f "$SPARKLE_KEY_FILE" ]] || security find-generic-password -s https://sparkle-project.org -a "$SPARKLE_ACCOUNT" >/dev/null 2>&1 ||
  die "no Sparkle signing key: neither $SPARKLE_KEY_FILE nor keychain account $SPARKLE_ACCOUNT (see docs/RELEASING.md)"

step "Exporting (developer-id)"
cat >"$OUT/export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
EOF
xcodebuild -quiet -exportArchive -archivePath "$OUT/PocketTerm.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/export.plist" -allowProvisioningUpdates
APP="$OUT/export/PocketTerm.app"
HELPER="$APP/Contents/Helpers/pocketterm-server"
codesign --verify --deep --strict "$APP"
# Universal, the team's, and the server inside signed like the app with the hardened runtime (notarization
# rejects any executable without it).
# Captured, not piped into `grep -q`: its early exit SIGPIPEs codesign, which pipefail reads as a failure.
APP_ARCHS=$(lipo -archs "$APP/Contents/MacOS/PocketTerm")
HELPER_ARCHS=$(lipo -archs "$HELPER")
APP_SIG=$(codesign -dvv "$APP" 2>&1)
HELPER_SIG=$(codesign -dvv "$HELPER" 2>&1)
HELPER_ENT=$(codesign -d --entitlements - "$HELPER" 2>/dev/null)
[[ "$APP_ARCHS" == *x86_64* && "$APP_ARCHS" == *arm64* ]] || die "the app isn't universal: $APP_ARCHS"
[[ "$HELPER_ARCHS" == *x86_64* && "$HELPER_ARCHS" == *arm64* ]] || $DRY || die "the built-in server isn't universal: $HELPER_ARCHS"
[[ "$APP_SIG" == *"TeamIdentifier=$TEAM"* ]] || die "the app isn't signed by team $TEAM"
[[ "$HELPER_SIG" == *"TeamIdentifier=$TEAM"* ]] || die "the built-in server isn't signed by team $TEAM"
[[ "$HELPER_SIG" == *"(runtime)"* ]] || die "the built-in server isn't signed with the hardened runtime"
# Without it macOS kills the Dart server at exec (macos/scripts/server.entitlements).
[[ "$HELPER_ENT" == *allow-unsigned-executable-memory* ]] ||
  die "the built-in server lost its entitlement (macos/scripts/server.entitlements)"
[[ "$APP_SIG" == *"Authority=Developer ID Application"* ]] || die "the app isn't signed with the Developer ID"
[[ "$HELPER_SIG" == *"Authority=Developer ID Application"* ]] || die "the built-in server isn't signed with the Developer ID"
echo "PocketTerm.app $APP_ARCHS, server $HELPER_ARCHS, team $TEAM"

notarize() {
  if $DRY; then echo "dry run, skipped: xcrun notarytool submit $1 --keychain-profile $NOTARY_PROFILE --wait; xcrun stapler staple ${2:-$1}"; return; fi
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$OUT/notary.log"
  grep -q "status: Accepted" "$OUT/notary.log" || die "notarization failed for $1 (see $OUT/notary.log)"
}

step "Notarizing the app"
ditto -c -k --keepParent "$APP" "$OUT/PocketTerm.zip"
notarize "$OUT/PocketTerm.zip" "$APP"
$DRY || xcrun stapler staple "$APP"

step "Making the DMG"
mkdir -p "$OUT/dmg" && cp -R "$APP" "$OUT/dmg/" && ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname "PocketTerm $VERSION" -srcfolder "$OUT/dmg" -fs HFS+ -format ULFO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
if ! $DRY; then
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature "$DMG"
fi

step "Writing the appcast"
mkdir -p "$OUT/appcast" && cp "$DMG" "$OUT/appcast/"
# The previous appcast keeps older versions listed (and enables delta updates).
$DRY || gh release download --repo "$REPO" --pattern appcast.xml --dir "$OUT/appcast" 2>/dev/null || true
sparkle_sign "$SPARKLE/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --full-release-notes-url "https://github.com/$REPO/releases/tag/v$VERSION" \
  "$OUT/appcast"
grep -q 'sparkle:edSignature=' "$OUT/appcast/appcast.xml" || die "the appcast entry isn't signed"

if $DRY; then
  step "Dry run done: $DMG and $OUT/appcast/appcast.xml (Developer ID signed, not notarized, not published)"
  exit 0
fi

step "Publishing v$VERSION"
awk -v v="$VERSION" '$0 ~ "^## "v {on=1; next} /^## / {on=0} on' $ROOT/CHANGELOG.md >"$OUT/notes.md"
# gh creates the tag on GitHub together with the release, so a failed upload leaves no tag behind.
gh release create "v$VERSION" --repo "$REPO" --target "$(git rev-parse HEAD)" --title "PocketTerm $VERSION" \
  --notes-file "$OUT/notes.md" "$DMG" "$OUT/appcast/appcast.xml"
git fetch --quiet origin tag "v$VERSION"
echo "Released: https://github.com/$REPO/releases/tag/v$VERSION"
