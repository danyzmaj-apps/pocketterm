#!/usr/bin/env bash
# Builds the signed Android App Bundle for Play. Baker runs this from
# apps/pocketterm-mobile and appends --build-name/--build-number; the bundle
# lands where Baker looks for it (build/app/outputs/bundle/).
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
android="$mobile/android"

if [[ ! -f "$android/key.properties" ]]; then
  echo "error: $android/key.properties is missing; release signing needs it (see docs/RELEASING.md)." >&2
  exit 1
fi

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"

args=(:app:bundleRelease)
[[ -n "$name" ]] && args+=("-PversionName=$name")
[[ -n "$number" ]] && args+=("-PversionCode=$number")
(cd "$android" && ./gradlew "${args[@]}")

out="$mobile/build/app/outputs/bundle/release/app-release.aab"
mkdir -p "$(dirname "$out")"
cp "$android/app/build/outputs/bundle/release/app-release.aab" "$out"
echo "$out"
