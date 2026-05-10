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
export LC_ALL=C

# show_preview <original-file> <proposed-file>
# Pretty-print the change: unified diff if --diff, full file otherwise.
# Picks delta / colordiff if available, otherwise falls back to plain diff.
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

if [ "$#" -lt 2 ]; then
    cat <<EOF
Usage: $0 <hostname> <port-or-url> [--path /prefix] [--comment "TEXT"] [--dry-run] [--diff]

Examples:
  $0 app.example.com 8080
  $0 api.example.com http://127.0.0.1:3000
  $0 example.com 9015 --path /myapp
  $0 app.example.com 8080 --comment "Gradio demo - object detection"
  $0 app.example.com 8080 --dry-run    # show full preview, no writes
  $0 app.example.com 8080 --diff       # show unified diff (implies --dry-run)
EOF
    exit 1
fi

hostname="$1"
target="$2"
shift 2

path=""
comment=""
dry_run="false"
show_diff="false"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --path)
            path="$2"
            shift 2
            ;;
        --comment)
            comment="$2"
            shift 2
            ;;
        --dry-run)
            dry_run="true"
            shift
            ;;
        --diff)
            dry_run="true"
            show_diff="true"
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# Validate inputs BEFORE they reach awk regexes / YAML / cloudflared.
# Hostnames in DNS: letters, digits, dots, hyphens. No newlines, no quotes.
if ! [[ "$hostname" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || [ "${#hostname}" -gt 253 ]; then
    echo "ERROR: invalid hostname: $hostname" >&2
    echo "       Allowed: letters, digits, dots, hyphens (max 253 chars)." >&2
    exit 1
fi

# Comment: optional, opt-in only. Reject newlines (which would break out of
# the comment line in YAML) and cap length so a stray paragraph doesn't end
# up inline.
if [ -n "$comment" ]; then
    case "$comment" in
        *$'\n'*|*$'\r'*)
            echo "ERROR: --comment cannot contain newlines." >&2; exit 1
            ;;
    esac
    if [ "${#comment}" -gt 200 ]; then
        echo "ERROR: --comment too long (>200 chars). Keep it short." >&2; exit 1
    fi
fi

# Path: optional. cloudflared treats `path:` as a Go regex, so we want to
# allow regex/glob metacharacters (.*, +, ?, [, ], etc.). Validate by
# rejecting only what would break the YAML emission or be otherwise
# nonsensical: control chars, whitespace, quotes, '#' (yaml comment),
# ':' (yaml key separator).
if [ -n "$path" ]; then
    if [[ "$path" != /* ]]; then
        echo "ERROR: --path must start with /" >&2; exit 1
    fi
    if [ "${#path}" -gt 1024 ]; then
        echo "ERROR: --path too long (>1024 chars)" >&2; exit 1
    fi
    # Bash variables can never hold a NUL, so we don't need to check for it.
    case "$path" in
        *$'\n'*|*$'\r'*|*$'\t'*|*' '*|*\"*|*\'*|*\#*|*:*)
            echo "ERROR: invalid --path: $path" >&2
            echo "       Disallowed: whitespace, quotes, '#', ':'." >&2
            exit 1
            ;;
    esac
fi

# Target: bare port number, full http(s) URL, or host:port. Reject anything
# that could embed a newline / quote into the YAML service: line.
if [[ "$target" =~ ^[0-9]+$ ]]; then
    if [ "$target" -lt 1 ] || [ "$target" -gt 65535 ]; then
        echo "ERROR: port out of range: $target" >&2; exit 1
    fi
    service="http://127.0.0.1:${target}"
elif [[ "$target" =~ ^https?://[A-Za-z0-9.:_/-]+$ ]]; then
    service="$target"
elif [[ "$target" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]]; then
    service="http://${target}"
else
    echo "ERROR: invalid target: $target" >&2
    echo "       Use a port (8080), host:port, or http(s) URL." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse detect.sh output WITHOUT eval (config.yml is partly user-controlled).
binary=""; config=""; tunnel_id=""; credentials=""; needs_sudo=""; service_mode=""
detect_out="$(bash "$SCRIPT_DIR/detect.sh")" || {
    rc=$?
    if [ "$rc" = "2" ]; then
        echo "ERROR: detect.sh refused to emit values - config may be tampered." >&2
    else
        echo "ERROR: No cloudflared tunnel detected." >&2
        echo "Run setup-new-tunnel.sh to create one first." >&2
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

echo "==> Tunnel: $tunnel_id"
echo "==> Config: $config"
echo "==> Adding: $hostname${path:+ (path: $path)} -> $service"
[ "$dry_run" = "true" ] && echo "==> DRY RUN: no changes will be made"
echo

# Step 1: Create DNS record
# Skips quietly if record already exists (cloudflared returns specific error).
if [ "$dry_run" = "true" ]; then
    echo "==> [dry-run] would: $binary tunnel route dns $tunnel_id $hostname"
else
    echo "==> Creating DNS CNAME for $hostname..."
    dns_log="$(mktemp)"
    trap 'rm -f "$dns_log"' EXIT
    if ! "$binary" tunnel route dns "$tunnel_id" "$hostname" 2>&1 | tee "$dns_log"; then
        if grep -qiE "already exists|record with that host already exists" "$dns_log"; then
            echo "    (DNS record already exists - continuing)"
        else
            echo "ERROR: Failed to create DNS record" >&2
            exit 1
        fi
    fi
fi

# Step 2: Backup config and insert ingress block before the catch-all
backup="${config}.bak.$(date +%Y%m%d-%H%M%S)"
echo
if [ "$dry_run" = "true" ]; then
    echo "==> [dry-run] would: backup $config to $backup"
else
    echo "==> Backing up config to $backup"
    $SUDO cp "$config" "$backup"
fi

# Keep only the 5 most recent backups - .bak files contain the credentials
# path and accumulate every run.
rotate_backups() {
    # shellcheck disable=SC2012
    local stale
    mapfile -t stale < <($SUDO ls -1t "${config}".bak.* 2>/dev/null | tail -n +6) || true
    if [ "${#stale[@]}" -gt 0 ]; then
        $SUDO rm -f -- "${stale[@]}"
    fi
}
rotate_backups

# Sanity check: the awk insertion below pivots on a SINGLE catch-all line
# (`service: http_status:404`). If the file has zero or multiple, the
# awk would either silently no-op (producing an unchanged file that
# still passes `tunnel ingress validate`) or duplicate the new block.
# Detect that up front and refuse with a clear error.
catchall_count="$($SUDO grep -cE '^[[:space:]]*(-[[:space:]]+)?service:[[:space:]]*http_status:404[[:space:]]*$' "$config" || true)"
if [ "$catchall_count" != "1" ]; then
    echo "ERROR: expected exactly one 'service: http_status:404' catch-all in $config, found $catchall_count." >&2
    echo "       Fix the config manually so the catch-all is the LAST ingress entry, then retry." >&2
    exit 1
fi

# Detect the indent that the catch-all line uses, so the new block matches
# the existing style (e.g. 2-space indent under `ingress:`). Falls back to
# empty (zero-indent) if the catch-all has no leading whitespace.
catchall_indent="$($SUDO sed -n -E 's/^([[:space:]]*)(-[[:space:]]+)?service:[[:space:]]*http_status:404[[:space:]]*$/\1/p' "$config" | head -1)"

# Build the new YAML block with matching indentation.
# The list-item dash sits at $catchall_indent; subsequent keys are 2 spaces
# deeper, lined up with the hostname value.
key_indent="${catchall_indent}  "
comment_line=""
if [ -n "$comment" ]; then
    # Inserted ABOVE the - hostname: line, at the list-item indent.
    comment_line="${catchall_indent}# Added by cloudflare-tunnel-routes on $(date +%Y-%m-%d) | ${comment}
"
fi
if [ -n "$path" ]; then
    new_block="${comment_line}${catchall_indent}- hostname: ${hostname}
${key_indent}path: ${path}
${key_indent}service: ${service}"
else
    new_block="${comment_line}${catchall_indent}- hostname: ${hostname}
${key_indent}service: ${service}"
fi

# Check if hostname (with same path) already exists.
# Match by exact string comparison on the parsed YAML field, NEVER by
# interpolating $hostname into the awk regex source.
already_present="false"
if [ -n "$path" ]; then
    if $SUDO awk -v h="$hostname" -v p="$path" '
        /^[[:space:]]*-[[:space:]]*hostname:/ {
            cur = $NF; gsub(/["'"'"']/, "", cur)
            in_block = (cur == h)
            next
        }
        in_block && /^[[:space:]]+path:/ {
            cp = $NF; gsub(/["'"'"']/, "", cp)
            if (cp == p) { found = 1; exit }
            in_block = 0
        }
        END { exit found ? 0 : 1 }
    ' "$config"; then
        already_present="true"
    fi
else
    if $SUDO awk -v h="$hostname" '
        /^[[:space:]]*-[[:space:]]*hostname:/ {
            if (in_block && !saw_path) { found = 1; exit }
            cur = $NF; gsub(/["'"'"']/, "", cur)
            in_block = (cur == h)
            saw_path = 0
            next
        }
        in_block && /^[[:space:]]+path:/ { saw_path = 1 }
        END {
            if (in_block && !saw_path) found = 1
            exit found ? 0 : 1
        }
    ' "$config"; then
        already_present="true"
    fi
fi

if [ "$already_present" = "true" ]; then
    echo "==> Ingress entry for $hostname${path:+ + path $path} already exists - skipping config edit."
    if [ "$dry_run" = "true" ]; then
        echo "==> [dry-run] no changes needed."
        exit 0
    fi
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

    if [ "$dry_run" = "true" ]; then
        if [ "$show_diff" = "true" ]; then
            echo "==> [dry-run] diff against $config:"
        else
            echo "==> [dry-run] would write the following to $config:"
        fi
        show_preview "$config" "$tmp"
        rm -f "$tmp"
        echo
        echo "==> [dry-run] would: validate config + restart cloudflared ($service_mode)"
        echo "==> [dry-run] no changes made."
        exit 0
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
        # Find the PID of the cloudflared process running THIS tunnel/config.
        # 1. pgrep candidates by command-line keyword
        # 2. require comm == cloudflared (skip editors/grep/helpers that
        #    happen to contain the same string)
        # 3. require the argv to mention either our tunnel_id or our
        #    config path (so we don't HUP an unrelated cloudflared running
        #    a different tunnel on the same host).
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
        if [ "${#cf_pids[@]}" -eq 0 ]; then
            echo "WARN: no cloudflared process found for tunnel $tunnel_id - restart manually." >&2
        else
            $SUDO kill -HUP "${cf_pids[@]}" || {
                echo "WARN: SIGHUP failed - restart manually." >&2
            }
        fi
        ;;
    none)
        echo "WARN: cloudflared is not currently running." >&2
        echo "      Start it with: cloudflared tunnel run $tunnel_id" >&2
        echo "      Or as a service: sudo cloudflared service install" >&2
        ;;
esac

echo
echo "==> Done. Test with: curl -I https://${hostname}${path:-/}"
