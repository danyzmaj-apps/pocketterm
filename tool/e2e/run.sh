#!/bin/sh
# PocketTerm's end-to-end run on this Mac: a local server, the real desktop
# app, throwaway kitty / Ghostty / WezTerm windows with a fake omp, and the
# phone in the Simulator (Maestro). Prints a pass/fail table; artifacts in
# build/e2e/<stamp>/.
#
#   tool/e2e/run.sh [--terminal kitty|ghostty|wezterm|all] [--server local|<https url> --setup-link <link>]
#                   [--no-phone] [--platform ios|android]
set -eu
cd "$(dirname "$0")/../.."
exec fvm dart run tool/e2e/bin/run.dart "$@"
