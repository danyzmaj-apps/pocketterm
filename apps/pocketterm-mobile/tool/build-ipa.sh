#!/usr/bin/env bash
# Builds the App Store .ipa for TestFlight. Baker (project pocketterm-ios) runs
# this as ../tool/build-ipa.sh from apps/pocketterm-mobile/ios and appends
# --build-name=<v> --build-number=<n>; the ipa lands where Baker looks for it,
# under the project's build/ (ios/build/ipa/PocketTerm.ipa). Runs from any
# folder. Export only, no upload.
set -euo pipefail

usage() { echo "usage: $0 [--build-name X] [--build-number N]" >&2; exit 2; }

name="" number=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-name) [[ $# -ge 2 ]] || usage; name="$2"; shift 2 ;;
    --build-name=*) name="${1#*=}"; shift ;;
    --build-number) [[ $# -ge 2 ]] || usage; number="$2"; shift 2 ;;
    --build-number=*) number="${1#*=}"; shift ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

mobile="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$mobile/../.." && pwd)"
ios="$mobile/ios"

# The team comes from the shared xcconfig; Local.xcconfig (git-ignored) wins
# when it sets one, as it does for the Xcode build itself.
team=""
for f in "$repo/config/PocketTerm.xcconfig" "$repo/config/Local.xcconfig"; do
  [[ -f "$f" ]] || continue
  t="$(sed -n 's/^[[:space:]]*POCKETTERM_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' "$f" | tail -n 1)"
  [[ -n "$t" ]] && team="$t"
done
[[ -n "$team" ]] || { echo "error: POCKETTERM_TEAM not found in config/PocketTerm.xcconfig" >&2; exit 1; }

work="$ios/build"
archive="$work/PocketTerm.xcarchive"
ipadir="$work/ipa"
rm -rf "$archive" "$ipadir"
mkdir -p "$work"

(cd "$ios" && xcodegen generate)

overrides=()
[[ -n "$name" ]] && overrides+=("MARKETING_VERSION=$name")
[[ -n "$number" ]] && overrides+=("CURRENT_PROJECT_VERSION=$number")

# Where the app's crash reports go (Info.plist SentryDSN): SENTRY_DSN from the environment, else its KEY=VALUE
# line in ios/.env (git-ignored; Baker writes it there). None → the app never starts reporting. It reaches
# xcodebuild as the environment variable POCKETTERM_BUILD_SENTRY_DSN (project.yml), not as a command-line or
# -xcconfig setting: xcodebuild prints those in its log.
dsn="${SENTRY_DSN:-}"
if [[ -z "$dsn" && -f "$ios/.env" ]]; then
  # The last SENTRY_DSN= line (optionally `export`ed or quoted), without its quotes; a CRLF's CR goes with the
  # trailing space.
  dsn="$(sed -n \
    "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}SENTRY_DSN[[:space:]]*=[[:space:]]*[\"']\{0,1\}\([^\"'[:space:]]*\)[\"']\{0,1\}[[:space:]]*\$/\2/p" \
    "$ios/.env" | tail -n 1)"
fi
# Where usage statistics go (Info.plist UmamiWebsiteID): UMAMI_WEBSITE_ID, the same way, as
# POCKETTERM_BUILD_UMAMI_WEBSITE_ID. None → the app records nothing.
umami="${UMAMI_WEBSITE_ID:-}"
if [[ -z "$umami" && -f "$ios/.env" ]]; then
  umami="$(sed -n \
    "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}UMAMI_WEBSITE_ID[[:space:]]*=[[:space:]]*[\"']\{0,1\}\([^\"'[:space:]]*\)[\"']\{0,1\}[[:space:]]*\$/\2/p" \
    "$ios/.env" | tail -n 1)"
fi

POCKETTERM_BUILD_SENTRY_DSN="$dsn" POCKETTERM_BUILD_UMAMI_WEBSITE_ID="$umami" xcodebuild archive \
  -project "$ios/PocketTerm.xcodeproj" -scheme PocketTerm -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$team" ${overrides[@]+"${overrides[@]}"}

plist="$work/ExportOptions.plist"
cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$team</string>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
EOF

xcodebuild -exportArchive -archivePath "$archive" -exportPath "$ipadir" \
  -exportOptionsPlist "$plist" -allowProvisioningUpdates

ipa="$ipadir/PocketTerm.ipa"
[[ -f "$ipa" ]] || { echo "error: export produced no $ipa" >&2; ls "$ipadir" >&2; exit 1; }
echo "$ipa"
