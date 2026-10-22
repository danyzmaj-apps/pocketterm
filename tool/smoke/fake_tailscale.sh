#!/bin/sh
# A stand-in Tailscale CLI for the installed-app smoke (POCKETTERM_TAILSCALE):
# running, signed in, HTTPS on, as this Mac's Tailscale answers; `serve`
# keeps its config in $FAKE_TAILSCALE_STATE (a JSON file) and nothing else,
# so the throwaway copy never changes the Mac's real Serve settings. Every
# call is logged to $FAKE_TAILSCALE_STATE.log.
#
# Files next to the state change what it answers, read on every call
# (tool/smoke/scenario.sh walks the On this computer checklist with them):
#   $FAKE_TAILSCALE_STATE.backend  Running (the default), Stopped or NeedsLogin.
#                                  Stopped fails every command with the CLI's
#                                  not-running error and exit 1, as Tailscale does.
#   $FAKE_TAILSCALE_STATE.certs    off: no HTTPS certificates (CertDomains null).
# Another proxy already on port 443 is a $FAKE_TAILSCALE_STATE written so.
state=${FAKE_TAILSCALE_STATE:?FAKE_TAILSCALE_STATE is not set}
name=${FAKE_TAILSCALE_NAME:-pocketterm-smoke.tail0000.ts.net}
echo "$*" >> "$state.log"
[ -f "$state" ] || echo '{}' > "$state"
backend=$(cat "$state.backend" 2>/dev/null)
certs=$(cat "$state.certs" 2>/dev/null)
if [ "$backend" = Stopped ]; then
  echo "failed to connect to local Tailscale service; is Tailscale running?" >&2
  exit 1
fi
case "$*" in
  "status --json")
    if [ "$backend" = NeedsLogin ]; then
      # Signed out: no name, no certificates.
      echo '{"BackendState":"NeedsLogin","Self":{"DNSName":""},"CertDomains":null}'
    elif [ "$certs" = off ]; then
      printf '{"BackendState":"Running","Self":{"DNSName":"%s."},"CertDomains":null}\n' "$name"
    else
      printf '{"BackendState":"Running","Self":{"DNSName":"%s."},"CertDomains":["%s"]}\n' "$name" "$name"
    fi ;;
  "serve status --json")
    cat "$state" ;;
  "serve --bg --https=443 "*)
    to=${4:?}
    printf '{"TCP":{"443":{"HTTPS":true}},"Web":{"%s:443":{"Handlers":{"/":{"Proxy":"%s"}}}}}\n' "$name" "$to" > "$state"
    echo "Available within your tailnet:"
    echo "https://$name/"
    echo "|-- proxy $to" ;;
  "serve --https=443 off")
    echo '{}' > "$state" ;;
  *)
    echo "fake tailscale: unknown command: $*" >&2
    exit 1 ;;
esac
