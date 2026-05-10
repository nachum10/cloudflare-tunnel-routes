#!/usr/bin/env bash
# List all ingress routes from the active cloudflared config.
# Format: HOSTNAME [PATH] -> SERVICE

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
eval "$("$SCRIPT_DIR/detect.sh")" || {
    echo "ERROR: No cloudflared tunnel detected. Run setup-new-tunnel.sh first." >&2
    exit 1
}

reader="cat"
if [ "$needs_sudo" = "true" ]; then
    reader="sudo cat"
fi

echo "Tunnel: $tunnel_id"
echo "Config: $config"
echo "---"

$reader "$config" | awk '
BEGIN { hostname=""; path=""; service="" }
/^[[:space:]]*-[[:space:]]*hostname:/ {
    if (hostname != "") {
        printf "%-45s %-20s -> %s\n", hostname, (path ? path : ""), service
    }
    hostname = $NF; path=""; service=""
    next
}
/^[[:space:]]+path:/ { path = $NF; next }
/^[[:space:]]+service:/ { service = $NF; next }
END {
    if (hostname != "") {
        printf "%-45s %-20s -> %s\n", hostname, (path ? path : ""), service
    }
}' | sed 's/"//g; s/'\''//g'
