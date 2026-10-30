#!/bin/sh
# PocketTerm's end-to-end run on this Mac: a local server, the real desktop
# app, throwaway kitty / Ghostty / WezTerm windows with a fake omp, and the
# phone in the Simulator (Maestro). Prints a pass/fail table; artifacts in
# build/e2e/<stamp>/.
#
#   tool/e2e/run.sh [--terminal kitty|ghostty|wezterm|all]
#                   [--server local|builtin|<https url> --setup-link-file <file>
#                    [--server-stop-cmd <sh> --server-start-cmd <sh>] [--server-ca <pem>]]
#                   [--no-phone] [--platform ios|android [--avd <name>]] [--phone-only <flow>,…]
#                   [--phone-from-tree] [--desktop-only <text>,…] [--from-head]
# (tool/e2e/bin/run.dart says what each does.)
set -eu
cd "$(dirname "$0")/../.."
exec fvm dart run tool/e2e/bin/run.dart "$@"
