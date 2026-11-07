#!/usr/bin/env bash
# Builds the signed Android App Bundle for Play. Baker (project
# pocketterm-android) runs this as ../tool/build-aab.sh from
# apps/pocketterm-mobile/android and appends --build-name=<v> --build-number=<n>;
# it picks up the bundle Gradle writes to
# android/app/build/outputs/bundle/release/app-release.aab. Runs from any folder.
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
android="$mobile/android"

if [[ ! -f "$android/key.properties" ]]; then
  echo "error: $android/key.properties is missing; release signing needs it (see docs/RELEASING.md)." >&2
  exit 1
fi

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
# Baker's worktree has no local.properties (git-ignored), so Gradle finds the SDK here.
[[ -f "$android/local.properties" ]] || export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

args=(:app:bundleRelease)
[[ -n "$name" ]] && args+=("-PversionName=$name")
[[ -n "$number" ]] && args+=("-PversionCode=$number")
(cd "$android" && ./gradlew "${args[@]}")

echo "$android/app/build/outputs/bundle/release/app-release.aab"
