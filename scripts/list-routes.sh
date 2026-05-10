#!/usr/bin/env bash
# List all ingress routes from the active cloudflared config.
# Format: HOSTNAME [PATH] -> SERVICE

set -eu
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

binary=""; config=""; tunnel_id=""; credentials=""; needs_sudo=""; service_mode=""
detect_out="$(bash "$SCRIPT_DIR/detect.sh")" || {
    rc=$?
    if [ "$rc" = "2" ]; then
        echo "ERROR: detect.sh refused to emit values - config may be tampered." >&2
    else
        echo "ERROR: No cloudflared tunnel detected. Run setup-new-tunnel.sh first." >&2
    fi
    exit 1
}
while IFS='=' read -r k v; do
    case "$k" in
        binary)       binary="$v" ;;
        config)       config="$v" ;;
        tunnel_id)    tunnel_id="$v" ;;
        credentials)  credentials="$v" ;;
        needs_sudo)   needs_sudo="$v" ;;
        service_mode) service_mode="$v" ;;
    esac
done <<<"$detect_out"

reader="cat"
if [ "$needs_sudo" = "true" ]; then
    reader="sudo cat"
fi

echo "Tunnel: $tunnel_id"
echo "Config: $config"
echo "---"

# Prefer yq when available - this is a read-only operation, so a real YAML
# parser handles quoted strings, anchors, comments-on-same-line, and unusual
# indentation correctly. The awk fallback covers the simple shape that this
# tool itself produces.
list_with_yq() {
    # Same expression works for both Mike Farah's Go yq (v4+) and kislyuk's
    # Python yq (a jq wrapper). Quote service explicitly because it can be
    # the magic value `http_status:404` which yq might emit as 'null' under
    # some configurations; `// ""` keeps the column lined up regardless.
    local out
    out="$(
        $reader "$config" \
            | yq -r '.ingress[]? | [(.hostname // "*"), (.path // ""), (.service // "")] | @tsv' \
            2>/dev/null
    )" || return 1
    [ -n "$out" ] || return 1
    # Use awk -F'\t' for printing, NOT shell `read` - bash collapses
    # consecutive tabs when IFS is only whitespace, dropping empty path
    # fields silently.
    printf '%s\n' "$out" | awk -F'\t' '{ printf "%-45s %-20s -> %s\n", $1, $2, $3 }'
}

list_with_awk() {
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
}

if command -v yq >/dev/null 2>&1 && list_with_yq; then
    :
else
    list_with_awk
fi
