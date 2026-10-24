#!/bin/bash
# Runs the phone's end-to-end flows (Maestro) against what tool/e2e/run.sh set
# up: a server, the desktop app and terminals with fake agents. Reads the run
# dir's phone-link.txt, phone-link-2.txt and expect.json; writes screenshots,
# Maestro's reports and a summary to <run dir>/phone/<platform>/<phase>/.
#
#   run.sh --run-dir build/e2e/<ts> [--platform ios|android]
#          [--phase main|server-restart|desktop-restart|real-omp|revoke|server-down|computer-off]
#          [--only <flow>[,<flow>…]] [--device <id>] [--avd <name>] [--no-build]
#
# The app is built from HEAD in a detached git worktree ($PHONE_SRC, default
# $TMPDIR/pocketterm-e2e-phone), not from the working tree, so edits in flight
# don't get in; commit what the run should test. --no-build reuses the
# installed app.
# iOS: the Simulator "PocketTerm E2E" (made and booted when missing), an E2E
# debug build (its scanner takes a pasted code: lib/e2e_hooks.dart).
# Android: the running emulator, or --avd cold-booted (its snapshot neither
# loaded nor saved);
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
  "ASK_SESSION": e.get("askSession", ""),
  "CLOSE_WINDOW": e.get("closeWindow", ""),
  "NEW_SHELL_PROJECT": e.get("newShellProject", ""),
  "NEW_PROJECT_NAME": e.get("newProjectName", ""),
}
for i, x in enumerate(s):
  v[f"SESSION_{i}"] = x.get("title", "")
  v[f"PROJECT_{i}"] = x.get("project", "")
  # Its routed key (<computer id>/<session key>): what links to a followed session and pushes carry.
  v[f"SESSION_{i}_KEY"] = x.get("key", "")
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
    "$EMULATOR" -avd "$AVD" -no-snapshot-load -no-snapshot-save -no-boot-anim -no-audio >"$OUT/emulator.log" 2>&1 &
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

# Firebase hands the phone its push token over the internet: an emulator
# whose network never came up (its modem out of service after a cold boot,
# seen on hopjar_api35) gets none, so there's no Follow and the flows fail
# far from the cause. Wait a minute for it, then say so.
if [ "$PLATFORM" = android ]; then
  online=""
  for _ in $(seq 30); do
    if "$ADB" -s "$DEVICE" shell ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then online=1; break; fi
    sleep 2
  done
  if [ -z "$online" ]; then
    echo "$DEVICE has no internet, so Firebase gives the phone no push token (no Follow): cold-boot it again (adb -s $DEVICE emu kill)" >&2
    exit 2
  fi
fi

# The server's port, reachable as 127.0.0.1 on the emulator too.
if [ "$PLATFORM" = android ]; then
  PORT=$(python3 -c 'import sys,urllib.parse as u;q=u.parse_qs(u.urlparse(sys.argv[1]).query);print(u.urlparse(q["url"][0]).port or "")' "$LINK" 2>/dev/null || true)
  [ -n "$PORT" ] && "$ADB" -s "$DEVICE" reverse "tcp:$PORT" "tcp:$PORT" >/dev/null
fi

# An E2E debug build (pasted codes, tips start seen: lib/e2e_hooks.dart) of
# HEAD, built and installed once per run; a photo in the library for
# image.yaml and ten more for attach_limit.yaml (each its own size, so none
# is the same as another), and documents in the phone's files (simctl
# addmedia takes photos only: on iOS they go straight into the Files app's
# On My iPhone storage, on Android into Download): one for file.yaml, and a
# 21 MB one, over what a message takes, for too_large.yaml. The first is the
# one the desktop's stand-in phone sends (integration_test/e2e_test.dart
# checks it arrives as it was), its name with spaces, so its @path is quoted.
FIXTURE="$APP/assets/icon/ios.png"
DOC_NAME="notes from the phone.txt"
DOC_FIXTURE="$OUT/$DOC_NAME"
printf 'PocketTerm e2e notes\n' >"$DOC_FIXTURE"
BIG_NAME="too big for the phone.bin"
BIG_FIXTURE="$OUT/$BIG_NAME"
PHOTOS=()
if [ "$PHASE" = main ]; then
  dd if=/dev/zero of="$BIG_FIXTURE" bs=1048576 count=21 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sips -Z $((200 + i * 20)) "$FIXTURE" --out "$OUT/photo-$i.png" >/dev/null && PHOTOS+=("$OUT/photo-$i.png")
  done
fi
if [ "$PHASE" = main ] && [ $BUILD = 1 ]; then
  HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
  if [ -e "$PHONE_SRC/.git" ]; then
    git -C "$PHONE_SRC" checkout -q --force --detach "$HEAD_SHA" || exit 1
  else
    git -C "$REPO" worktree add -q --detach "$PHONE_SRC" "$HEAD_SHA" || exit 1
  fi
  SRC_APP="$PHONE_SRC/${APP#"$REPO"/}"
  echo "phone build: $HEAD_SHA in $PHONE_SRC" | tee -a "$SUMMARY"
  # Flutter regenerates the Dart plugin registrant only when the workspace's
  # package_config.json changes; a plugin the desktop app already pulled in
  # (file_selector) leaves it as it was, and the phone gets the plugin's
  # native side without its Dart side (MissingPluginException). Built anew.
  rm -f "$SRC_APP/.dart_tool/flutter_build/dart_plugin_registrant.dart"
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
    xcrun simctl addmedia "$DEVICE" "${PHOTOS[@]}" "$FIXTURE"
    local_storage=$(xcrun simctl get_app_container "$DEVICE" com.apple.DocumentsApp groups 2>/dev/null |
      awk -F'\t' '$1 == "group.com.apple.FileProvider.LocalStorage" {print $2}')
    if [ -n "$local_storage" ]; then
      mkdir -p "$local_storage/File Provider Storage"
      cp "$DOC_FIXTURE" "$BIG_FIXTURE" "$local_storage/File Provider Storage/"
    else
      echo "no Files storage on $DEVICE: file.yaml and too_large.yaml will not find their documents" | tee -a "$SUMMARY"
    fi
  else
    for f in "${PHOTOS[@]}" "$FIXTURE"; do
      n="pocketterm-e2e-$(basename "$f")"
      "$ADB" -s "$DEVICE" push "$f" "/sdcard/Pictures/$n" >/dev/null
      "$ADB" -s "$DEVICE" shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
        -d "file:///sdcard/Pictures/$n" >/dev/null
    done
    for f in "$DOC_FIXTURE" "$BIG_FIXTURE"; do
      n=$(basename "$f")
      "$ADB" -s "$DEVICE" push "$f" "/sdcard/Download/$n" >/dev/null
      "$ADB" -s "$DEVICE" shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
        -d "file:///sdcard/Download/${n// /%20}" >/dev/null
    done
  fi
fi

re_escape() { python3 -c 'import re,sys;print(re.escape(sys.argv[1]))' "$1"; }
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

APP_ID=com.danyzmaj.pocketterm
# open_cold link|push <routed key>: stops the app, then opens it as a followed
# session's link (pocketterm://session?key=…) does, or (Android) as a tapped
# terminal push does: MainActivity with the session in its extra
# (Notifications.kt).
open_cold() {
  local how=$1 key=$2 url
  url="pocketterm://session?key=$(python3 -c 'import sys,urllib.parse as u;print(u.quote(sys.argv[1],safe=""))' "$key")"
  if [ "$PLATFORM" = ios ]; then
    xcrun simctl terminate "$DEVICE" "$APP_ID" 2>/dev/null
    sleep 1
    xcrun simctl openurl "$DEVICE" "$url"
  else
    "$ADB" -s "$DEVICE" shell am force-stop "$APP_ID"
    sleep 1
    if [ "$how" = link ]; then
      # -p: only this app takes the link, so no "Open with" chooser.
      "$ADB" -s "$DEVICE" shell am start -a android.intent.action.VIEW -d "'$url'" -p "$APP_ID" >/dev/null
    else
      "$ADB" -s "$DEVICE" shell am start -n "$APP_ID/.MainActivity" --es com.danyzmaj.pocketterm.session "'$key'" >/dev/null
    fi
  fi
}

# ------------------------------------------------------------------ timing

# What the app logs of getting connected (debug builds: lib/timing.dart in
# pocketterm_core), with a mark at each flow's start; timing.txt reads them
# after the phase (timing_report).
TIMING_LOG="$OUT/timing.log" MARKS="$OUT/timing-marks.log"
: >"$MARKS"
if [ "$PLATFORM" = ios ]; then
  xcrun simctl spawn "$DEVICE" log stream --style compact --level debug \
    --predicate 'eventMessage CONTAINS "PocketTerm timing"' >"$TIMING_LOG" 2>&1 &
else
  "$ADB" -s "$DEVICE" logcat -c
  "$ADB" -s "$DEVICE" logcat -v brief -s flutter:I >"$TIMING_LOG" 2>&1 &
fi
LOG_PID=$!

# Per launch (the app's `launch`) and per return to the front (`resumed`):
# how long after it each step came, and how long the app was away.
timing_report() {
  python3 - "$TIMING_LOG" "$MARKS" <<'PY' >"$OUT/timing.txt"
import re, sys
events = []
for line in open(sys.argv[1], errors="replace"):
    m = re.search(r"PocketTerm timing (\d{13}) (.+?)\s*$", line)
    if m: events.append((int(m.group(1)), m.group(2)))
marks = []
for line in open(sys.argv[2]):
    t, _, name = line.strip().partition(" ")
    if t.isdigit(): marks.append((int(t), name))
events.sort()
steps = ["signed in", "home", "computers listed", "computers failed", "attach", "socket connecting",
         "socket failed", "socket open", "joined", "first state", "deep link", "session page", "caught up"]
def flow_at(t):
    name = "-"
    for mt, n in marks:
        if mt <= t: name = n
    return name
paused = None
runs = []
for i, (t, what) in enumerate(events):
    if what == "paused": paused = t
    if what not in ("launch", "resumed"): continue
    seen = {}
    for t2, w2 in events[i + 1:]:
        if w2 in ("launch", "resumed"): break
        if w2 == "paused" and what == "resumed": break
        seen.setdefault(w2, t2 - t)
    away = f" after {round((t - paused) / 1000)} s away" if what == "resumed" and paused else ""
    runs.append(f"{flow_at(t):<22} {what}{away}: " + ", ".join(f"{s} +{seen[s]} ms" for s in steps if s in seen))
print("\n".join(runs) if runs else "no timing lines (not a debug build?)")
PY
  cat "$OUT/timing.txt" >>"$SUMMARY"
}
trap 'timing_report; kill $LOG_PID 2>/dev/null' EXIT

# ------------------------------------------------------------------- flows

FAILED=0 STOP=0 CRITICAL=1
# flow <name> <file> [-e K=V ...]: one Maestro run. A failure while CRITICAL
# (setting up: the scenarios after need it) stops the phase; a scenario's
# failure doesn't stop the next, which starts from the session list anyway.
# BEFORE (sh, optional) runs first: how the app is opened (a link, a tapped
# push) when the flow itself doesn't.
flow() {
  local name=$1 file=$2
  shift 2
  if [ $STOP = 1 ] || { [ -n "$ONLY" ] && [[ ",$ONLY," != *",$name,"* ]]; }; then return; fi
  local dir="$OUT/$name"
  mkdir -p "$dir"
  local started=$SECONDS ok=0 try
  # A flow whose Maestro driver didn't start on the device never touched
  # the app: it runs once more.
  for try in 1 2; do
    echo "$(now_ms) $name" >>"$MARKS"
    if [ -n "${BEFORE:-}" ]; then eval "$BEFORE"; fi
    if "$MAESTRO" --device "$DEVICE" test "$HERE/$file" --test-output-dir "$dir" --debug-output "$dir" \
      --format junit --output "$dir/report.xml" \
      -e PLATFORM="$PLATFORM" -e COMPUTER="$COMPUTER" -e COMPUTER_RE="$COMPUTER_RE" -e TERMINAL="$TERMINAL" -e TERMINAL_RE="$TERMINAL_RE" \
      "$@" >"$dir/maestro.log" 2>&1; then
      ok=1
      break
    fi
    grep -qE "MaestroDriverStartupException|IOSDriverTimeoutException" "$dir/maestro.log" || break
    cp "$dir/maestro.log" "$dir/maestro-driver-$try.log"
  done
  if [ $ok = 1 ]; then
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
    if [ "$TERMINAL_ID" = ghostty ]; then SCREEN=no; else SCREEN=yes; fi
    flow tips tips_home.yaml -e SESSION="$SESSION_0_RE" -e SCREEN="$SCREEN"
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
    # Ghostty: then the person answers on the computer (the desktop test does,
    # asked through its rpc folder), so omp isn't still waiting for the rest.
    if [ "$TERMINAL_ID" = ghostty ] && [ -d "$OUT/approval" ]; then
      RPC="$RUN_DIR/rpc"
      rm -f "$RPC/approve-on-computer.done"
      date >"$RPC/approve-on-computer.req"
      for ((w = 0; w < 30; w++)); do [ -f "$RPC/approve-on-computer.done" ] && break; sleep 1; done
      echo "approved on the computer: $(cat "$RPC/approve-on-computer.done" 2>/dev/null || echo 'no answer')"
    fi
    for ((i = 0; i < SESSION_COUNT; i++)); do
      t=SESSION_${i}_RE
      flow "conversation-$i" conversation.yaml -e SESSION="${!t}" -e PROMPT="$(prompt $i)" \
        -e PROMPT_RE="$(re_escape "$(prompt $i)")"
    done
    flow slash-new slash_new.yaml -e SESSION="$SESSION_0_RE"
    flow screen screen.yaml -e WINDOW="$SCREEN_WINDOW_RE" -e SCREEN="$SCREEN"
    flow image image.yaml -e SESSION="$SESSION_0_RE" -e IMAGE_PROMPT="what is in this image $TERMINAL_ID"
    flow file file.yaml -e SESSION="$SESSION_0_RE" -e FILE_PROMPT="what is in this file $TERMINAL_ID"
    flow new-session new_session.yaml -e PROJECT="$NEW_SESSION_PROJECT_RE"
    # On the session new-session started (where the phone opened it, so its
    # screen can be read: in tmux under Ghostty), each prompt different.
    flow steer-queue steer_queue.yaml -e SESSION="$ASK_SESSION_RE" -e SLOW="e2e-slow steer run $TERMINAL_ID" \
      -e STEER="steer from phone $TERMINAL_ID" -e STEER_RE="$(re_escape "steer from phone $TERMINAL_ID")" \
      -e QUEUE="queue from phone $TERMINAL_ID" -e QUEUE_RE="$(re_escape "queue from phone $TERMINAL_ID")"
    flow stop stop.yaml -e SESSION="$ASK_SESSION_RE" -e SLOW="e2e-slow stop run $TERMINAL_ID" \
      -e HELD="after stop $TERMINAL_ID" -e HELD_RE="$(re_escape "after stop $TERMINAL_ID")"
    flow question question.yaml -e SESSION="$ASK_SESSION_RE" -e PROMPT="e2e-question $TERMINAL_ID"
    flow plan plan.yaml -e SESSION="$ASK_SESSION_RE" -e PROMPT="e2e-plan $TERMINAL_ID"
    flow menu-model menu_model.yaml -e SESSION="$ASK_SESSION_RE"
    flow menu-resume menu_resume.yaml -e SESSION="$ASK_SESSION_RE"
    flow follow follow.yaml -e SESSION="$ASK_SESSION_RE"
    flow session-screen session_screen.yaml -e SESSION="$ASK_SESSION_RE"
    flow screen-keys screen_keys.yaml -e WINDOW="$SCREEN_WINDOW_RE" -e SCREEN="$SCREEN"
    flow new-shell new_shell.yaml -e PROJECT="$NEW_SHELL_PROJECT_RE"
    flow new-project new_project.yaml -e NAME="$NEW_PROJECT_NAME" -e NAME_RE="$NEW_PROJECT_NAME_RE"
    flow project-list project_list.yaml -e PROJECT="$PROJECT_0_RE"
    flow close-window close_window.yaml -e WINDOW="$CLOSE_WINDOW_RE"
    flow attach-limit attach_limit.yaml -e SESSION="$SESSION_0_RE"
    flow too-large too_large.yaml -e SESSION="$SESSION_0_RE"
    flow account-sheet account_sheet.yaml
    flow switch-continue switch.yaml -e WINDOW=".*$SWITCH_CONTINUE_RE" -e HOW="Restart and continue"
    flow switch-restart switch.yaml -e WINDOW=".*$SWITCH_RESTART_RE" -e HOW="Just restart"
    flow end-session end_session.yaml -e SESSION="$END_SESSION_RE"
    # How long a cold start and a return to the front take (timing.txt), and
    # that a followed session's link opens its session on a cold start.
    # E2E_AWAY_LONG=1 also leaves the app in the background for 10 minutes.
    REPLY_1="fake reply: $(re_escape "$(prompt 1)")"
    flow cold-start cold_start.yaml -e SESSION="$SESSION_1_RE" -e REPLY="$REPLY_1"
    for away in 60 ${E2E_AWAY_LONG:+600}; do
      flow "away-${away}s" background.yaml -e SESSION="$SESSION_1_RE" -e REPLY="$REPLY_1"
      [ -d "$OUT/away-${away}s" ] && sleep "$away"
      flow "resume-${away}s" foreground.yaml -e REPLY="$REPLY_1"
    done
    BEFORE="open_cold link '$SESSION_1_KEY'" flow deep-link-cold deep_link.yaml -e SESSION="$SESSION_1_RE" \
      -e REPLY="$REPLY_1"
    if [ "$PLATFORM" = android ]; then
      BEFORE="open_cold push '$SESSION_1_KEY'" flow push-tap-cold deep_link.yaml -e SESSION="$SESSION_1_RE" \
        -e REPLY="$REPLY_1"
    fi
    ;;
  server-restart | desktop-restart)
    # A new prompt goes and comes back once; conversation-1's exchange (session
    # 0's was reset by /new) shows once, nothing replayed.
    t=SESSION_1_RE
    # First, cold from a followed session's link, with the server just back.
    BEFORE="open_cold link '$SESSION_1_KEY'" flow "deep-link-$PHASE" deep_link.yaml -e SESSION="${!t}" \
      -e REPLY="fake reply: $(re_escape "$(prompt 1)")"
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
  server-down)
    # The server stopped (the desktop starts it again after this phase).
    flow unreachable unreachable.yaml
    ;;
  computer-off)
    # Settings → Terminal from phone is off on the computer; then the desktop
    # turns it back on when asked through its rpc folder, and Retry brings
    # the computer back. Asked even when offline.yaml failed: the phases
    # after need it on.
    flow offline offline.yaml
    RPC="$RUN_DIR/rpc"
    rm -f "$RPC/terminal-on.done"
    date >"$RPC/terminal-on.req"
    for ((w = 0; w < 60; w++)); do [ -f "$RPC/terminal-on.done" ] && break; sleep 1; done
    echo "terminal from phone on: $(cat "$RPC/terminal-on.done" 2>/dev/null || echo 'no answer')"
    flow retry retry.yaml -e SESSION="$SESSION_1_RE"
    ;;
  *) echo "unknown phase: $PHASE" >&2; exit 2 ;;
esac

echo "phone $PLATFORM $PHASE: $([ $FAILED = 0 ] && echo PASS || echo FAIL)" | tee -a "$SUMMARY"
exit $FAILED
