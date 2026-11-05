#!/usr/bin/env bash
# Builds the App Store .ipa for TestFlight. Baker runs this from
# apps/pocketterm-mobile and appends --build-name/--build-number; the ipa
# lands where Baker looks for it (build/ios/ipa/). Export only, no upload.
set -euo pipefail

usage() { echo "usage: $0 [--build-name X] [--build-number N]" >&2; exit 2; }

name="" number=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-name) [[ $# -ge 2 ]] || usage; name="$2"; shift 2 ;;
    --build-number) [[ $# -ge 2 ]] || usage; number="$2"; shift 2 ;;
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

work="$mobile/build/ios"
archive="$work/PocketTerm.xcarchive"
ipadir="$work/ipa"
rm -rf "$archive" "$ipadir"
mkdir -p "$work"

(cd "$ios" && xcodegen generate)

overrides=()
[[ -n "$name" ]] && overrides+=("MARKETING_VERSION=$name")
[[ -n "$number" ]] && overrides+=("CURRENT_PROJECT_VERSION=$number")

xcodebuild archive \
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
