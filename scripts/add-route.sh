#!/usr/bin/env bash
# Add a new route to the active cloudflared tunnel.
# Usage: add-route.sh <hostname> <local-port-or-url> [--path /prefix]
#
# Examples:
#   add-route.sh app.example.com 8080
#   add-route.sh api.example.com http://127.0.0.1:3000
#   add-route.sh example.com 9015 --path /myapp
#
# Steps performed:
#   1. Create DNS CNAME via `cloudflared tunnel route dns`
#   2. Insert ingress block into config.yml BEFORE the catch-all 404
#   3. Reload/restart cloudflared

set -eu

if [ "$#" -lt 2 ]; then
    cat <<EOF
Usage: $0 <hostname> <port-or-url> [--path /prefix]

Examples:
  $0 app.example.com 8080
  $0 api.example.com http://127.0.0.1:3000
  $0 example.com 9015 --path /myapp
EOF
    exit 1
fi

hostname="$1"
target="$2"
shift 2

path=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --path)
            path="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# Normalize target into a full service URL
if [[ "$target" =~ ^[0-9]+$ ]]; then
    service="http://127.0.0.1:${target}"
elif [[ "$target" =~ ^https?:// ]]; then
    service="$target"
else
    service="http://${target}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
eval "$("$SCRIPT_DIR/detect.sh")" || {
    echo "ERROR: No cloudflared tunnel detected." >&2
    echo "Run setup-new-tunnel.sh to create one first." >&2
    exit 1
}

SUDO=""
if [ "$needs_sudo" = "true" ]; then
    SUDO="sudo"
fi

echo "==> Tunnel: $tunnel_id"
echo "==> Config: $config"
echo "==> Adding: $hostname${path:+ (path: $path)} -> $service"
echo

# Step 1: Create DNS record
# Skips quietly if record already exists (cloudflared returns specific error).
echo "==> Creating DNS CNAME for $hostname..."
if ! "$binary" tunnel route dns "$tunnel_id" "$hostname" 2>&1 | tee /tmp/cf-dns.log; then
    if grep -qiE "already exists|record with that host already exists" /tmp/cf-dns.log; then
        echo "    (DNS record already exists - continuing)"
    else
        echo "ERROR: Failed to create DNS record" >&2
        exit 1
    fi
fi

# Step 2: Backup config and insert ingress block before the catch-all
backup="${config}.bak.$(date +%Y%m%d-%H%M%S)"
echo
echo "==> Backing up config to $backup"
$SUDO cp "$config" "$backup"

# Build the new YAML block
if [ -n "$path" ]; then
    new_block="- hostname: ${hostname}
  path: ${path}
  service: ${service}"
else
    new_block="- hostname: ${hostname}
  service: ${service}"
fi

# Check if hostname (with same path) already exists
already_present="false"
if [ -n "$path" ]; then
    # match hostname followed by matching path within ~5 lines
    if $SUDO awk -v h="$hostname" -v p="$path" '
        /^[[:space:]]*-[[:space:]]*hostname:[[:space:]]*'"'"'?'"'"'?'"$hostname"''"'"'?[[:space:]]*$/ { in_block=1; next }
        in_block && /^[[:space:]]+path:/ {
            gsub(/["'"'"']/, "", $2)
            if ($2 == p) { found=1; exit }
            in_block=0
        }
        END { exit found ? 0 : 1 }
    ' "$config"; then
        already_present="true"
    fi
else
    if $SUDO grep -qE "^[[:space:]]*-[[:space:]]*hostname:[[:space:]]*${hostname}[[:space:]]*$" "$config"; then
        # only consider it a duplicate if there's no path on the next line
        if ! $SUDO awk -v h="$hostname" '
            /^[[:space:]]*-[[:space:]]*hostname:[[:space:]]*/ {
                cur=$NF; gsub(/["'"'"']/, "", cur)
                if (cur == h) { in_block=1; next }
                in_block=0
            }
            in_block && /^[[:space:]]+path:/ { exit 1 }
            in_block && /^[[:space:]]*-[[:space:]]*hostname:/ { exit 0 }
        ' "$config"; then
            already_present="true"
        fi
    fi
fi

if [ "$already_present" = "true" ]; then
    echo "==> Ingress entry for $hostname${path:+ + path $path} already exists - skipping config edit."
else
    echo "==> Inserting ingress block before catch-all..."
    # Insert the new block immediately before the line containing "service: http_status:404"
    tmp="$(mktemp)"
    $SUDO awk -v block="$new_block" '
        /service:[[:space:]]*http_status:404/ {
            n = split(block, lines, "\n")
            for (i=1; i<=n; i++) print lines[i]
        }
        { print }
    ' "$config" > "$tmp"

    if [ ! -s "$tmp" ]; then
        echo "ERROR: Generated config is empty - aborting" >&2
        rm -f "$tmp"
        exit 1
    fi

    $SUDO cp "$tmp" "$config"
    rm -f "$tmp"
fi

# Step 3: Validate the new config
echo
echo "==> Validating config..."
if ! $SUDO "$binary" --config "$config" tunnel ingress validate 2>&1; then
    echo "ERROR: Config validation failed - restoring backup" >&2
    $SUDO cp "$backup" "$config"
    exit 1
fi

# Step 4: Reload/restart cloudflared
echo
echo "==> Restarting cloudflared ($service_mode)..."
case "$service_mode" in
    systemd)
        $SUDO systemctl restart cloudflared
        sleep 2
        $SUDO systemctl is-active --quiet cloudflared && echo "    Active." || {
            echo "ERROR: cloudflared failed to start" >&2
            $SUDO systemctl status cloudflared --no-pager -n 20
            exit 1
        }
        ;;
    manual)
        echo "    Sending SIGHUP to running cloudflared (manual mode)..."
        $SUDO pkill -HUP -f "cloudflared.*tunnel.*run" || {
            echo "WARN: SIGHUP failed - restart manually." >&2
        }
        ;;
    none)
        echo "WARN: cloudflared is not currently running." >&2
        echo "      Start it with: cloudflared tunnel run $tunnel_id" >&2
        echo "      Or as a service: sudo cloudflared service install" >&2
        ;;
esac

echo
echo "==> Done. Test with: curl -I https://${hostname}${path:-/}"
