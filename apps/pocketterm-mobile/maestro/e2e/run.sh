#!/bin/bash
# Runs the phone's end-to-end flows (Maestro) against what tool/e2e/run.sh set
# up: a server, the desktop app and terminals with fake agents. Reads the run
# dir's phone-link.txt, phone-link-2.txt and expect.json; writes screenshots,
# Maestro's reports and a summary to <run dir>/phone/<platform>/<phase>/.
#
#   run.sh --run-dir build/e2e/<ts> [--platform ios|android] [--phase main|server-restart|desktop-restart|real-omp|revoke]
#          [--only <flow>[,<flow>…]] [--device <id>] [--avd <name>] [--no-build]
#
# The app is built from HEAD in a detached git worktree ($PHONE_SRC, default
# $TMPDIR/pocketterm-e2e-phone), not from the working tree, so edits in flight
# don't get in; commit what the run should test. --no-build reuses the
# installed app.
# iOS: the Simulator "PocketTerm E2E" (made and booted when missing), an E2E
# debug build (its scanner takes a pasted code: lib/e2e_hooks.dart).
# Android: the running emulator, or --avd booted without saving its snapshot;
# `adb reverse` makes the server's 127.0.0.1 port the emulator's too.
# Exit status: 0 when every flow passed.
set -o pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
APP=$(cd "$HERE/../.." && pwd)
REPO=$(git -C "$APP" rev-parse --show-toplevel)
PHONE_SRC=${PHONE_SRC:-${TMPDIR:-/tmp}/pocketterm-e2e-phone}
MAESTRO=${MAESTRO:-$HOME/.maestro/bin/maestro}
ADB=${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}
EMULATOR=${EMULATOR:-$HOME/Library/Android/sdk/emulator/emulator}
SIM_NAME="PocketTerm E2E"

RUN_DIR="" PLATFORM=ios PHASE=main ONLY="" DEVICE="" AVD="" BUILD=1
while [ $# -gt 0 ]; do
  case $1 in
    --run-dir) RUN_DIR=$2; shift 2 ;;
    --platform) PLATFORM=$2; shift 2 ;;
    --phase) PHASE=$2; shift 2 ;;
    --only) ONLY=$2; shift 2 ;;
    --device) DEVICE=$2; shift 2 ;;
    --avd) AVD=$2; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$RUN_DIR" ] || { echo "--run-dir is required" >&2; exit 2; }
RUN_DIR=$(cd "$RUN_DIR" && pwd)
OUT="$RUN_DIR/phone/$PLATFORM/$PHASE"
mkdir -p "$OUT"
SUMMARY="$OUT/summary.txt"
: >"$SUMMARY"

# expect.json, flattened to shell variables (missing fields come out empty).
# Names the flows match against (Maestro reads text as a regex) come escaped
# too, as <NAME>_RE.
eval "$(python3 - "$RUN_DIR/expect.json" <<'PY'
import json, re, shlex, sys
e = json.load(open(sys.argv[1]))
s = e.get("sessions") or []
v = {
  "COMPUTER": e.get("computer", ""),
  "LOCKED_COMPUTER": e.get("lockedComputer", ""),
  "TERMINAL": e.get("terminal", ""),
  "TERMINAL_ID": e.get("terminalId", ""),
  "PROMPT": e.get("prompt", ""),
  "SESSION_COUNT": str(len(s)),
  "APPROVAL_SESSION": (e.get("approval") or {}).get("session", ""),
  "APPROVAL_ANSWER": (e.get("approval") or {}).get("answer", "Approve"),
  "SCREEN_WINDOW": (e.get("screen") or {}).get("window", ""),
  "SWITCH_CONTINUE": e.get("switchContinue", ""),
  "SWITCH_RESTART": e.get("switchRestart", ""),
  "NEW_SESSION_PROJECT": e.get("newSessionProject", ""),
  "END_SESSION": e.get("endSession", ""),
  "REAL_OMP": (e.get("realOmp") or {}).get("title", ""),
}
for i, x in enumerate(s):
  v[f"SESSION_{i}"] = x.get("title", "")
  v[f"PROJECT_{i}"] = x.get("project", "")
for k, val in list(v.items()):
  v[k + "_RE"] = re.escape(val)
for k, val in v.items():
  print(f"{k}={shlex.quote(val)}")
PY
)" || { echo "expect.json unreadable" >&2; exit 2; }
LINK=$(cat "$RUN_DIR/phone-link.txt" 2>/dev/null || true)
LINK2=$(cat "$RUN_DIR/phone-link-2.txt" 2>/dev/null || true)

# ------------------------------------------------------------------ device

ios_device() {
  local udid
  udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
for rt, ds in json.load(sys.stdin)["devices"].items():
  for d in ds:
    if d["name"] == sys.argv[1]: print(d["udid"]); sys.exit()' "$SIM_NAME")
  if [ -z "$udid" ]; then
    local runtime
    runtime=$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
r = [x for x in json.load(sys.stdin)["runtimes"] if x["platform"] == "iOS" and x["isAvailable"]]
print(r[-1]["identifier"])')
    udid=$(xcrun simctl create "$SIM_NAME" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro "$runtime")
  fi
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" >/dev/null
  echo "$udid"
}

android_device() {
  local serial
  serial=$("$ADB" devices | awk '/^emulator-.*device$/ {print $1; exit}')
  if [ -z "$serial" ]; then
    [ -n "$AVD" ] || { echo "no emulator running; pass --avd <name>" >&2; return 1; }
    "$EMULATOR" -avd "$AVD" -no-snapshot-save -no-boot-anim -no-audio >"$OUT/emulator.log" 2>&1 &
    "$ADB" wait-for-device
    until [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 2; done
    serial=$("$ADB" devices | awk '/^emulator-.*device$/ {print $1; exit}')
  fi
  echo "$serial"
}

if [ -z "$DEVICE" ]; then
  if [ "$PLATFORM" = ios ]; then DEVICE=$(ios_device); else DEVICE=$(android_device) || exit 2; fi
fi
echo "$DEVICE" >"$OUT/device.txt"

# The server's port, reachable as 127.0.0.1 on the emulator too.
if [ "$PLATFORM" = android ]; then
  PORT=$(python3 -c 'import sys,urllib.parse as u;q=u.parse_qs(u.urlparse(sys.argv[1]).query);print(u.urlparse(q["url"][0]).port or "")' "$LINK" 2>/dev/null || true)
  [ -n "$PORT" ] && "$ADB" -s "$DEVICE" reverse "tcp:$PORT" "tcp:$PORT" >/dev/null
fi

# An E2E debug build (pasted codes, tips start seen: lib/e2e_hooks.dart) of
# HEAD, built and installed once per run; a photo in the library for
# image.yaml.
FIXTURE="$APP/assets/icon/ios.png"
if [ "$PHASE" = main ] && [ $BUILD = 1 ]; then
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
  if [ -e "$PHONE_SRC/.git" ]; then
    git -C "$PHONE_SRC" checkout -q --force --detach "$HEAD_SHA" || exit 1
  else
    git -C "$REPO" worktree add -q --detach "$PHONE_SRC" "$HEAD_SHA" || exit 1
  fi
  SRC_APP="$PHONE_SRC/${APP#"$REPO"/}"
  echo "phone build: $HEAD_SHA in $PHONE_SRC" | tee -a "$SUMMARY"
  if [ "$PLATFORM" = ios ]; then
    (cd "$SRC_APP" && fvm flutter build ios --simulator --debug --dart-define=POCKETTERM_E2E=true) >"$OUT/build.log" 2>&1 ||
      { echo "build failed: $OUT/build.log" >&2; exit 1; }
    xcrun simctl install "$DEVICE" "$SRC_APP/build/ios/iphonesimulator/Runner.app"
  else
    # Push needs the Firebase config, kept out of git.
    cp "$APP/android/app/google-services.json" "$SRC_APP/android/app/" 2>/dev/null
    (cd "$SRC_APP" && fvm flutter build apk --debug --dart-define=POCKETTERM_E2E=true) >"$OUT/build.log" 2>&1 ||
      { echo "build failed: $OUT/build.log" >&2; exit 1; }
    "$ADB" -s "$DEVICE" install -r "$SRC_APP/build/app/outputs/flutter-apk/app-debug.apk" >/dev/null
  fi
fi
if [ "$PHASE" = main ]; then
  if [ "$PLATFORM" = ios ]; then
    xcrun simctl addmedia "$DEVICE" "$FIXTURE"
  else
    "$ADB" -s "$DEVICE" push "$FIXTURE" /sdcard/Pictures/pocketterm-e2e.png >/dev/null
    "$ADB" -s "$DEVICE" shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
      -d file:///sdcard/Pictures/pocketterm-e2e.png >/dev/null
  fi
fi

re_escape() { python3 -c 'import re,sys;print(re.escape(sys.argv[1]))' "$1"; }

# ------------------------------------------------------------------- flows

FAILED=0 STOP=0 CRITICAL=1
# flow <name> <file> [-e K=V ...]: one Maestro run. A failure while CRITICAL
# (setting up: the scenarios after need it) stops the phase; a scenario's
# failure doesn't stop the next, which starts from the session list anyway.
flow() {
  local name=$1 file=$2
  shift 2
  if [ $STOP = 1 ] || { [ -n "$ONLY" ] && [[ ",$ONLY," != *",$name,"* ]]; }; then return; fi
  local dir="$OUT/$name"
  mkdir -p "$dir"
  local started=$SECONDS
  if "$MAESTRO" --device "$DEVICE" test "$HERE/$file" --test-output-dir "$dir" --debug-output "$dir" \
    --format junit --output "$dir/report.xml" \
    -e PLATFORM="$PLATFORM" -e COMPUTER="$COMPUTER" -e COMPUTER_RE="$COMPUTER_RE" -e TERMINAL="$TERMINAL" -e TERMINAL_RE="$TERMINAL_RE" \
    "$@" >"$dir/maestro.log" 2>&1; then
    printf 'PASS  %-24s %4ss\n' "$name" $((SECONDS - started)) | tee -a "$SUMMARY"
  else
    printf 'FAIL  %-24s %4ss  %s\n' "$name" $((SECONDS - started)) "$dir/maestro.log" | tee -a "$SUMMARY"
    FAILED=1
    STOP=$CRITICAL
  fi
}

# What conversation-<i> sends to session i: expect.prompt, numbered after the
# first. Every prompt of a run is different: the harness checks each reaches
# the agent once.
prompt() { if [ "$1" = 0 ]; then echo "$PROMPT"; else echo "$PROMPT #$1"; fi; }

case $PHASE in
  main)
    flow fresh fresh.yaml
    flow pair-accept pair.yaml -e LINK="$LINK" -e PUSH=accept
    flow tips tips_home.yaml -e SESSION="$SESSION_0_RE"
    flow sign-out signout.yaml
    # The tips flow turned every tip back on; a fresh install again (signed
    # out already) starts them seen, so none covers what the scenarios tap.
    flow fresh-again fresh.yaml
    flow demo ../demo.yaml
    flow pair-decline pair.yaml -e LINK="$LINK2" -e PUSH=decline
    flow push-toggle push_toggle.yaml
    if [ -n "$LOCKED_COMPUTER" ]; then
      flow computers computers.yaml -e LOCKED_COMPUTER_RE="$LOCKED_COMPUTER_RE"
    fi
    # Answered first: the other sessions are idle, this one is asking. Ghostty
    # can't show its screen, which answering reads: the phone says so.
    if [ "$TERMINAL_ID" = ghostty ]; then THEN=".*Ghostty can.t show its screen.*"; else THEN=approved; fi
    CRITICAL=0
    flow approval approval.yaml -e SESSION="$APPROVAL_SESSION_RE" -e ANSWER="$APPROVAL_ANSWER" -e THEN="$THEN"
    for ((i = 0; i < SESSION_COUNT; i++)); do
      t=SESSION_${i}_RE
      flow "conversation-$i" conversation.yaml -e SESSION="${!t}" -e PROMPT="$(prompt $i)" \
        -e PROMPT_RE="$(re_escape "$(prompt $i)")"
    done
    flow slash-new slash_new.yaml -e SESSION="$SESSION_0_RE"
    flow screen screen.yaml -e WINDOW="$SCREEN_WINDOW_RE"
    flow image image.yaml -e SESSION="$SESSION_0_RE" -e IMAGE_PROMPT="what is in this image $TERMINAL_ID"
    flow new-session new_session.yaml -e PROJECT="$NEW_SESSION_PROJECT_RE"
    flow switch-continue switch.yaml -e WINDOW=".*$SWITCH_CONTINUE_RE" -e HOW="Restart and continue"
    flow switch-restart switch.yaml -e WINDOW=".*$SWITCH_RESTART_RE" -e HOW="Just restart"
    flow end-session end_session.yaml -e SESSION="$END_SESSION_RE"
    ;;
  server-restart | desktop-restart)
    # A new prompt goes and comes back once; conversation-1's exchange (session
    # 0's was reset by /new) shows once, nothing replayed.
    t=SESSION_1_RE
    flow reconnect reconnect.yaml -e SESSION="$SESSION_0_RE" -e PROMPT="after ${PHASE/-/ } $TERMINAL_ID" \
      -e PROMPT_RE="$(re_escape "after ${PHASE/-/ } $TERMINAL_ID")" \
      -e OLD_SESSION="${!t:-$SESSION_0_RE}" -e OLD_PROMPT_RE="$(re_escape "$(prompt 1)")"
    ;;
  real-omp)
    flow real-omp real_omp.yaml -e SESSION="$REAL_OMP_RE"
    ;;
  revoke)
    flow revoked revoked.yaml
    ;;
  *) echo "unknown phase: $PHASE" >&2; exit 2 ;;
esac

echo "phone $PLATFORM $PHASE: $([ $FAILED = 0 ] && echo PASS || echo FAIL)" | tee -a "$SUMMARY"
exit $FAILED
