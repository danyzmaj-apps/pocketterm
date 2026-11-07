#!/bin/sh
# PocketTerm's end-to-end run on this Mac: a server, the native Mac app (a
# test build driven through accessibility and its test hooks), throwaway
# kitty / Ghostty / WezTerm / iTerm2 windows with a fake omp, and the phone on
# the iOS Simulator or an Android emulator (Maestro). Prints a pass/fail
# table; artifacts in build/e2e/<stamp>/.
#
#   tool/e2e/run.sh [--terminal kitty|ghostty|wezterm|iterm|all]
#                   [--server local|builtin]
#                   [--no-phone] [--platform ios|android [--avd <name>]] [--device <id>] [--phone-only <flow>,…]
#                   [--phone-from-tree] [--desktop-only <text>,…] [--hold] [--from-head]
# (tool/e2e/bin/run.dart says what each does; docs/TESTING.md how it fits.)
set -eu
cd "$(dirname "$0")/../.."
exec fvm dart run tool/e2e/bin/run.dart "$@"
