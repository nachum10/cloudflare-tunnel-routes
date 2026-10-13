#!/usr/bin/env bash
# Remove an ingress route from the active cloudflared config.
# Usage: remove-route.sh <hostname> [--path /prefix] [--keep-dns]
#
# Removes the ingress block from config.yml and reloads cloudflared.
# The DNS CNAME is NOT deleted automatically - cloudflared has no API for
# that - the script prints instructions for the dashboard / Cloudflare API.
# Pass --keep-dns to suppress that hint (e.g. when scripting bulk cleanups).
#
# Exit status: 0 = done (or nothing matched), 1 = failed (config unchanged
#              or restored), 3 = config updated but cloudflared NOT
#              reloaded (no unique systemd unit for this config).

set -euo pipefail
export LC_ALL=C

show_preview() {
    local orig="$1" new="$2"
    if [ "$show_diff" = "true" ]; then
        if command -v delta >/dev/null 2>&1; then
            $RSUDO diff -u "$orig" "$new" 2>/dev/null | delta || true
        elif command -v colordiff >/dev/null 2>&1; then
            $RSUDO diff -u "$orig" "$new" 2>/dev/null | colordiff || true
        else
            $RSUDO diff -u "$orig" "$new" 2>/dev/null || true
        fi
    else
        echo "----- 8< -----"
        $RSUDO cat "$new"
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
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

binary=""; config=""; tunnel_id=""; credentials=""; needs_sudo=""; service_mode=""
service_unit=""; service_candidates=""; remote_managed=""
detect_out="$(bash "$SCRIPT_DIR/detect.sh")" || {
    rc=$?
    if [ "$rc" = "2" ]; then
        echo "ERROR: detect.sh refused to emit values - config may be tampered." >&2
    elif [ "$rc" = "3" ]; then
        : # detect.sh already printed the "needs root" error
    else
        echo "ERROR: No cloudflared tunnel detected." >&2
    fi
    exit 1
}
# shellcheck disable=SC2034  # every key is parsed; not all are used here
while IFS='=' read -r k v; do
    case "$k" in
        binary)       binary="$v" ;;
        config)       config="$v" ;;
        tunnel_id)    tunnel_id="$v" ;;
        credentials)  credentials="$v" ;;
        needs_sudo)   needs_sudo="$v" ;;
        service_mode) service_mode="$v" ;;
        service_unit) service_unit="$v" ;;
        service_candidates) service_candidates="$v" ;;
        remote_managed) remote_managed="$v" ;;
    esac
done <<<"$detect_out"

SUDO=""
if [ "$needs_sudo" = "true" ]; then
    SUDO="sudo"
fi
# Reads need root only when the config itself is unreadable (see add-route).
RSUDO=""
if [ -n "$SUDO" ] && [ ! -r "$config" ]; then
    RSUDO="$SUDO"
fi

# All writes go to the real file behind $config (it may be a symlink).
config_file="$(cftr_real_path "$config")" || {
    echo "ERROR: cannot resolve symlinks for $config" >&2
    exit 1
}

tmp=""; staged=""
on_exit() {
    local rc=$?
    [ -n "$tmp" ] && rm -f -- "$tmp"
    [ -n "$staged" ] && $SUDO rm -f -- "$staged"
    cftr_lock_release
    return "$rc"
}
trap on_exit EXIT

# Real runs: trustworthy binary for the root-run validate, and an
# exclusive lock from the first read of the config to the restart.
if [ "$dry_run" != "true" ]; then
    cftr_check_sudo || exit 1
    cftr_check_binary || exit 1
    cftr_lock_acquire || exit 1
fi

[ "$dry_run" = "true" ] && echo "==> DRY RUN: no changes will be made"
if [ "$remote_managed" = "true" ]; then
    echo "WARN: ${service_unit:-the cloudflared unit} runs 'tunnel run --token' (remotely-managed tunnel);" >&2
    echo "      local ingress rules are ignored - manage routes in the Zero Trust dashboard." >&2
fi
echo "==> Removing ingress block for $hostname${path:+ + path $path}..."

# Pick the blocks to drop (see cftr_route_blocks in lib.sh): hostname
# matches AND (no --path given OR path matches). A block runs until the
# next line at its dash indent or less, so comments, originRequest maps
# and nested Access lists inside it go with it - and nothing leaks into
# the neighbouring routes. Strings are compared in bash, never as regex.
ranges=""
while IFS=$'\t' read -r b_start b_end _ b_host b_path; do
    [ "$b_host" = "$hostname" ] || continue
    if [ -z "$path" ] || [ "$b_path" = "$path" ]; then
        ranges="$ranges $b_start:$b_end"
    fi
done < <(cftr_route_blocks "$config")

tmp="$(mktemp)"
# Drop the chosen line ranges; after each, also swallow one trailing
# blank line so the config stays tidy.
$RSUDO env cftr_ranges="$ranges" awk '
    BEGIN {
        n = split(ENVIRON["cftr_ranges"], r, " ")
        for (i = 1; i <= n; i++) {
            split(r[i], se, ":")
            for (l = se[1] + 0; l <= se[2] + 0; l++) drop[l] = 1
            after[se[2] + 1] = 1
        }
    }
    NR in drop { next }
    (NR in after) && /^[[:space:]]*$/ { next }
    { print }
' "$config" > "$tmp"

if [ -z "$ranges" ]; then
    if [ "$dry_run" = "true" ]; then
        echo "    [dry-run] no matching entry - config unchanged."
        echo "==> [dry-run] no changes made."
    else
        echo "    No matching entry found in config - nothing to do."
    fi
    exit 0
fi

if [ "$dry_run" = "true" ]; then
    if [ "$show_diff" = "true" ]; then
        echo "    [dry-run] diff against $config:"
    else
        echo "    [dry-run] would write the following to $config:"
    fi
    show_preview "$config" "$tmp"
    echo
    echo "==> [dry-run] would: validate, backup $config, replace it, restart cloudflared ($service_mode${service_unit:+: $service_unit})"
    echo "==> [dry-run] no changes made."
    exit 0
fi

# Stage next to the config with the original owner/group/mode, validate
# the staged file, back up, then swap it in with an atomic rename.
cfg_meta="$(cftr_file_meta "$config")" || {
    echo "ERROR: cannot stat $config" >&2
    exit 1
}
read -r cfg_uid cfg_gid cfg_mode <<<"$cfg_meta"
staged="$(cftr_stage "$tmp" "$cfg_uid" "$cfg_gid" "$cfg_mode")" || {
    staged=""
    echo "ERROR: could not stage the new config next to $config - nothing changed." >&2
    exit 1
}
echo "==> Validating new config..."
if ! $SUDO "$binary" --config "$staged" tunnel ingress validate 2>&1; then
    echo "ERROR: Config invalid - nothing changed." >&2
    exit 1
fi
backup="$(cftr_backup)" || {
    echo "ERROR: could not back up $config - config untouched." >&2
    exit 1
}
echo "==> Backed up config to $backup"
cftr_rotate_backups
$SUDO mv -f -- "$staged" "$config_file"
staged=""
echo "    Removed."

# Restart the unit that serves THIS config; roll back if it won't start.
reload_rc=0
cftr_reload || reload_rc=$?
if [ "$reload_rc" -eq 1 ]; then
    echo "ERROR: restoring previous config from $backup" >&2
    if staged="$(cftr_stage "$backup" "$cfg_uid" "$cfg_gid" "$cfg_mode")"; then
        $SUDO mv -f -- "$staged" "$config_file"
        staged=""
        cftr_reload || echo "ERROR: restart after restore failed too - check the service manually." >&2
    else
        staged=""
        echo "ERROR: could not restore automatically; copy $backup over $config by hand." >&2
    fi
    exit 1
fi

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
if [ "$reload_rc" -eq 3 ]; then
    echo "==> Config written, but NOT live until cloudflared restarts (exit 3)." >&2
    exit 3
fi
echo "==> Done."
