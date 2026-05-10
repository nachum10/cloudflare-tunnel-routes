#!/usr/bin/env bash
# Remove an ingress route from the active cloudflared config.
# Usage: remove-route.sh <hostname> [--path /prefix] [--keep-dns]
#
# By default removes BOTH the ingress block and the DNS CNAME.
# Pass --keep-dns to keep the DNS record (only removes ingress).

set -eu

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <hostname> [--path /prefix] [--keep-dns]"
    exit 1
fi

hostname="$1"
shift

path=""
keep_dns="false"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --path)    path="$2"; shift 2 ;;
        --keep-dns) keep_dns="true"; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
eval "$("$SCRIPT_DIR/detect.sh")" || {
    echo "ERROR: No cloudflared tunnel detected." >&2
    exit 1
}

SUDO=""
if [ "$needs_sudo" = "true" ]; then
    SUDO="sudo"
fi

backup="${config}.bak.$(date +%Y%m%d-%H%M%S)"
echo "==> Backing up config to $backup"
$SUDO cp "$config" "$backup"

echo "==> Removing ingress block for $hostname${path:+ + path $path}..."
tmp="$(mktemp)"

# AWK: walk blocks of `- hostname: X` ... up to next `- hostname:` or end-of-list.
# Skip the block if hostname matches AND (no --path given OR path matches).
# After a skip, also swallow one trailing blank line so config stays tidy.
$SUDO awk -v h="$hostname" -v p="$path" '
    function flush() {
        if (skip) {
            skip = 0; n = 0
            just_removed = 1
            return
        }
        for (i = 1; i <= n; i++) print buf[i]
        n = 0
    }
    /^[[:space:]]*-[[:space:]]*hostname:/ {
        flush()
        just_removed = 0
        cur = $NF; gsub(/["'"'"']/, "", cur)
        cur_path = ""
        in_block = (cur == h)
        n = 1; buf[n] = $0
        next
    }
    in_block && /^[[:space:]]+path:/ {
        cur_path = $NF; gsub(/["'"'"']/, "", cur_path)
        n++; buf[n] = $0
        next
    }
    in_block && /^[[:space:]]+/ {
        n++; buf[n] = $0
        next
    }
    {
        # End of any block: decide whether to skip the buffered block
        if (in_block) {
            if (p == "" || p == cur_path) skip = 1
            in_block = 0
        }
        # flush() MUST be called for every non-hostname line so buf drains
        # correctly. flush() sets just_removed=1 if it discarded a skipped block.
        flush()
        # Swallow a blank line that immediately follows a removed block
        if (just_removed && /^[[:space:]]*$/) {
            just_removed = 0
            next
        }
        just_removed = 0
        print
    }
    END { flush() }
' "$config" > "$tmp"

if ! diff -q "$config" "$tmp" >/dev/null 2>&1; then
    $SUDO cp "$tmp" "$config"
    echo "    Removed."
else
    echo "    No matching entry found in config."
fi
rm -f "$tmp"

# Validate
echo "==> Validating config..."
if ! $SUDO "$binary" --config "$config" tunnel ingress validate 2>&1; then
    echo "ERROR: Config invalid - restoring backup." >&2
    $SUDO cp "$backup" "$config"
    exit 1
fi

# Restart
echo "==> Restarting cloudflared ($service_mode)..."
case "$service_mode" in
    systemd) $SUDO systemctl restart cloudflared ;;
    manual)  $SUDO pkill -HUP -f "cloudflared.*tunnel.*run" || true ;;
esac

# Remove DNS unless --keep-dns
if [ "$keep_dns" = "false" ]; then
    echo
    echo "==> Note: Cloudflared CLI cannot delete DNS records directly."
    echo "    To remove the DNS CNAME for $hostname, do one of:"
    echo "      1. Delete it in the Cloudflare dashboard (DNS tab), OR"
    echo "      2. Use the API: curl -X DELETE \\"
    echo "         -H 'Authorization: Bearer \$CF_API_TOKEN' \\"
    echo "         https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/dns_records/<RECORD_ID>"
fi

echo
echo "==> Done."
