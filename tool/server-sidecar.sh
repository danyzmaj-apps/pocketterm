#!/usr/bin/env bash
# Compiles the PocketTerm server (apps/pocketterm-server) into one native binary the desktop apps bundle for the
# built-in server ("On this computer"): <out>/<os>-<arch>/pocketterm-server (.exe on Windows, under Git Bash).
#
#   tool/server-sidecar.sh [--out <dir>]          (default --out: build/server-sidecar)
#
# macOS: with DART_X64=/path/to/an/x86_64/dart (an Intel Dart SDK, run under Rosetta) it also builds x86_64 and
# lipos both into <out>/macos-universal/pocketterm-server; otherwise it builds arm64 only and says so.
# Windows CI runners use tool/server-sidecar.ps1.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/server-sidecar
while [ $# -gt 0 ]; do
  case $1 in
    --out) OUT=${2:?--out needs a directory}; shift 2 ;;
    --out=*) OUT=${1#--out=}; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

ENTRY=apps/pocketterm-server/bin/pocketterm_server.dart
case $(uname -s) in
  Darwin) OS=macos EXT="" ;;
  Linux) OS=linux EXT="" ;;
  MINGW* | MSYS* | CYGWIN*) OS=windows EXT=.exe ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 2 ;;
esac
case $(uname -m) in
  arm64 | aarch64) ARCH=arm64 ;;
  x86_64 | amd64) ARCH=x64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 2 ;;
esac

fvm dart pub get >/dev/null
mkdir -p "$OUT/$OS-$ARCH"
fvm dart compile exe "$ENTRY" -o "$OUT/$OS-$ARCH/pocketterm-server$EXT"
echo "built $OUT/$OS-$ARCH/pocketterm-server$EXT"

if [ "$OS" = macos ]; then
  if [ -n "${DART_X64:-}" ]; then
    mkdir -p "$OUT/macos-x64" "$OUT/macos-universal"
    arch -x86_64 "$DART_X64" compile exe "$ENTRY" -o "$OUT/macos-x64/pocketterm-server"
    lipo -create "$OUT/macos-arm64/pocketterm-server" "$OUT/macos-x64/pocketterm-server" \
      -output "$OUT/macos-universal/pocketterm-server"
    echo "built $OUT/macos-universal/pocketterm-server ($(lipo -archs "$OUT/macos-universal/pocketterm-server"))"
  else
    echo "DART_X64 is not set: arm64 only, no macos-universal (Intel Macs need DART_X64=/path/to/x86_64/dart)." >&2
  fi
fi
