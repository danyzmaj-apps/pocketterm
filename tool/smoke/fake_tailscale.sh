#!/bin/sh
# A stand-in Tailscale CLI for the installed-app smoke (POCKETTERM_TAILSCALE):
# running, signed in, HTTPS on, as this Mac's Tailscale answers; `serve`
# keeps its config in $FAKE_TAILSCALE_STATE (a JSON file) and nothing else,
# so the throwaway copy never changes the Mac's real Serve settings. Every
# call is logged to $FAKE_TAILSCALE_STATE.log.
state=${FAKE_TAILSCALE_STATE:?FAKE_TAILSCALE_STATE is not set}
name=${FAKE_TAILSCALE_NAME:-pocketterm-smoke.tail0000.ts.net}
echo "$*" >> "$state.log"
[ -f "$state" ] || echo '{}' > "$state"
case "$*" in
  "status --json")
    printf '{"BackendState":"Running","Self":{"DNSName":"%s."},"CertDomains":["%s"]}\n' "$name" "$name" ;;
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
