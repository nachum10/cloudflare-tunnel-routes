#!/usr/bin/env bash
# Remove an ingress route from the active cloudflared config.
# Usage: remove-route.sh <hostname> [--path /prefix] [--keep-dns]
#
# Removes the ingress block from config.yml and reloads cloudflared.
# The DNS CNAME is NOT deleted automatically - cloudflared has no API for
# that - the script prints instructions for the dashboard / Cloudflare API.
# Pass --keep-dns to suppress that hint (e.g. when scripting bulk cleanups).

set -eu
export LC_ALL=C

show_preview() {
    local orig="$1" new="$2"
    if [ "$show_diff" = "true" ]; then
        if command -v delta >/dev/null 2>&1; then
            $SUDO diff -u "$orig" "$new" 2>/dev/null | delta || true
        elif command -v colordiff >/dev/null 2>&1; then
            $SUDO diff -u "$orig" "$new" 2>/dev/null | colordiff || true
        else
            $SUDO diff -u "$orig" "$new" 2>/dev/null || true
        fi
    else
        echo "----- 8< -----"
        $SUDO cat "$new"
        echo "----- >8 -----"
    fi
}

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <hostname> [--path /prefix] [--keep-dns] [--dry-run] [--diff]"
    exit 1
fi

hostname="$1"
shift

path=""
keep_dns="false"
dry_run="false"
show_diff="false"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --path)    path="$2"; shift 2 ;;
        --keep-dns) keep_dns="true"; shift ;;
        --dry-run)  dry_run="true"; shift ;;
        --diff)     dry_run="true"; show_diff="true"; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Validate inputs - same shape as add-route.sh
if ! [[ "$hostname" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || [ "${#hostname}" -gt 253 ]; then
    echo "ERROR: invalid hostname: $hostname" >&2; exit 1
fi
if [ -n "$path" ]; then
    if [[ "$path" != /* ]]; then
        echo "ERROR: --path must start with /" >&2; exit 1
    fi
    if [ "${#path}" -gt 1024 ]; then
        echo "ERROR: --path too long (>1024 chars)" >&2; exit 1
    fi
    case "$path" in
        *$'\n'*|*$'\r'*|*$'\t'*|*' '*|*\"*|*\'*|*\#*|*:*)
            echo "ERROR: invalid --path: $path" >&2
            echo "       Disallowed: whitespace, quotes, '#', ':'." >&2
            exit 1
            ;;
    esac
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

binary=""; config=""; tunnel_id=""; credentials=""; needs_sudo=""; service_mode=""
detect_out="$(bash "$SCRIPT_DIR/detect.sh")" || {
    rc=$?
    if [ "$rc" = "2" ]; then
        echo "ERROR: detect.sh refused to emit values - config may be tampered." >&2
    else
        echo "ERROR: No cloudflared tunnel detected." >&2
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

SUDO=""
if [ "$needs_sudo" = "true" ]; then
    SUDO="sudo"
fi

backup="${config}.bak.$(date +%Y%m%d-%H%M%S)"
[ "$dry_run" = "true" ] && echo "==> DRY RUN: no changes will be made"
if [ "$dry_run" = "true" ]; then
    echo "==> [dry-run] would: backup $config to $backup"
else
    echo "==> Backing up config to $backup"
    $SUDO cp "$config" "$backup"

    # Keep only the 5 most recent backups (mirrors add-route.sh)
    rotate_backups() {
        # shellcheck disable=SC2012
        local stale
        mapfile -t stale < <($SUDO ls -1t "${config}".bak.* 2>/dev/null | tail -n +6) || true
        if [ "${#stale[@]}" -gt 0 ]; then
            $SUDO rm -f -- "${stale[@]}"
        fi
    }
    rotate_backups
fi

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
        # Decide whether the buffered block (if any) should be skipped
        # BEFORE flushing - otherwise consecutive blocks for the same
        # hostname all leak through.
        if (in_block) {
            if (p == "" || p == cur_path) skip = 1
            in_block = 0
        }
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
    in_block && /^[[:space:]]+[^-[:space:]#]/ {
        # Indented continuation of the block, but NOT:
        #   - the start of a new list item (`  - ...`)
        #   - a comment line (`  # ...`) - comments between blocks must
        #     never be swallowed into the deletion buffer; let them fall
        #     through to the default block, which closes the current
        #     block first and then prints the comment.
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

if [ "$dry_run" = "true" ]; then
    if diff -q "$config" "$tmp" >/dev/null 2>&1; then
        echo "    [dry-run] no matching entry - config unchanged."
    else
        if [ "$show_diff" = "true" ]; then
            echo "    [dry-run] diff against $config:"
        else
            echo "    [dry-run] would write the following to $config:"
        fi
        show_preview "$config" "$tmp"
    fi
    rm -f "$tmp"
    echo
    echo "==> [dry-run] would: validate config + restart cloudflared ($service_mode)"
    echo "==> [dry-run] no changes made."
    exit 0
fi

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
    manual)
        cf_pids=()
        while read -r pid; do
            [ -z "$pid" ] && continue
            comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
            [ "$comm" = "cloudflared" ] || continue
            args="$($SUDO ps -o args= -p "$pid" 2>/dev/null || true)"
            case "$args" in
                *"$tunnel_id"*|*"$config"*) cf_pids+=("$pid") ;;
            esac
        done < <($SUDO pgrep -f 'cloudflared.*tunnel.*run' 2>/dev/null || true)
        if [ "${#cf_pids[@]}" -gt 0 ]; then
            $SUDO kill -HUP "${cf_pids[@]}" || true
        fi
        ;;
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
