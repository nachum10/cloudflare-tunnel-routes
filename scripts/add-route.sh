#!/usr/bin/env bash
# Add a new route to the active cloudflared tunnel.
# Usage: add-route.sh <hostname> <local-port-or-url> [--path /prefix]
#
# Examples:
#   add-route.sh app.example.com 8080
#   add-route.sh api.example.com http://127.0.0.1:3000
#   add-route.sh example.com 9015 --path /myapp
#
# Steps performed (each one only if the previous succeeded):
#   1. Build the new config in a temp file (block inserted BEFORE the
#      catch-all 404, or above a host-only rule it would be shadowed by)
#   2. Validate it with `cloudflared tunnel ingress validate`
#   3. Create DNS CNAME via `cloudflared tunnel route dns`
#   4. Back up config.yml, then replace it atomically (owner/mode kept)
#   5. Restart the systemd unit serving this config; roll back on failure
#
# Exit status: 0 = done, 1 = failed (config unchanged or restored),
#              3 = config updated but cloudflared NOT reloaded (no unique
#                  systemd unit for this config) - restart it yourself.

set -euo pipefail
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
# up inline. Beyond \n and \r, YAML parsers also break lines on NEL (U+0085),
# LS (U+2028) and PS (U+2029), so a "single-line" comment could still smuggle
# in a hidden ingress rule. Allow printable ASCII only ([[:print:]] under
# LC_ALL=C is 0x20-0x7E): no control chars, no bytes >= 0x80.
if [ -n "$comment" ]; then
    case "$comment" in
        *$'\n'*|*$'\r'*)
            echo "ERROR: --comment cannot contain newlines." >&2; exit 1
            ;;
    esac
    if ! [[ "$comment" =~ ^[[:print:]]+$ ]]; then
        echo "ERROR: --comment must be printable ASCII (no control or non-ASCII characters)." >&2; exit 1
    fi
    if [ "${#comment}" -gt 200 ]; then
        echo "ERROR: --comment too long (>200 chars). Keep it short." >&2; exit 1
    fi
fi

# Path: optional. cloudflared treats `path:` as a Go regex, so we want to
# allow regex/glob metacharacters (.*, +, ?, [, ], etc.). Validate by
# rejecting only what would break the YAML emission or be otherwise
# nonsensical: control chars, whitespace, quotes, '#' (yaml comment),
# ':' (yaml key separator), and anything outside printable ASCII (YAML
# treats NEL / U+2028 / U+2029 as line breaks, same as in --comment).
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
    if ! [[ "$path" =~ ^[[:print:]]+$ ]]; then
        echo "ERROR: invalid --path: must be printable ASCII (no control or non-ASCII characters)." >&2
        exit 1
    fi
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
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

# Parse detect.sh output WITHOUT eval (config.yml is partly user-controlled).
binary=""; config=""; tunnel_id=""; credentials=""; needs_sudo=""; service_mode=""
service_unit=""; service_candidates=""; remote_managed=""
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
        service_unit) service_unit="$v" ;;
        service_candidates) service_candidates="$v" ;;
        remote_managed) remote_managed="$v" ;;
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
if [ "$remote_managed" = "true" ]; then
    echo "WARN: ${service_unit:-the cloudflared unit} runs 'tunnel run --token' (remotely-managed tunnel)." >&2
    echo "      cloudflared then ignores the ingress rules in $config; manage routes in the" >&2
    echo "      Cloudflare Zero Trust dashboard instead." >&2
fi
echo

# One EXIT handler for every temp file, plus the orphan-DNS hint: if the
# CNAME was created but a later step failed, say how to remove it. We
# never delete DNS records ourselves.
tmp=""; staged=""; dns_log=""; dns_done="false"; host_known="false"
on_exit() {
    local rc=$?
    [ -n "$tmp" ] && rm -f -- "$tmp"
    [ -n "$dns_log" ] && rm -f -- "$dns_log"
    [ -n "$staged" ] && $SUDO rm -f -- "$staged"
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ] && [ "$dns_done" = "true" ] && [ "$host_known" = "false" ]; then
        echo >&2
        echo "NOTE: the DNS CNAME for $hostname was created, but the config change did not go live." >&2
        echo "      If you will not retry, delete that CNAME in the Cloudflare dashboard" >&2
        echo "      (your zone -> DNS -> Records -> $hostname -> Delete)." >&2
    fi
    return "$rc"
}
trap on_exit EXIT

# Sanity check: the insertion pivots on a SINGLE catch-all line. With zero
# or several, the edit would silently no-op (an unchanged file still passes
# `tunnel ingress validate`) or land twice. Count and locate with the SAME
# anchored regex, so what we count is exactly what we insert before.
mapfile -t catchall_lines < <($SUDO env cftr_re="$CFTR_CATCHALL_RE" awk '$0 ~ ENVIRON["cftr_re"] { print NR }' "$config")
if [ "${#catchall_lines[@]}" != "1" ]; then
    echo "ERROR: expected exactly one 'service: http_status:404' catch-all in $config, found ${#catchall_lines[@]}." >&2
    echo "       Fix the config manually so the catch-all is the LAST ingress entry, then retry." >&2
    exit 1
fi
catchall_line="${catchall_lines[0]}"

# Detect the indent that the catch-all line uses, so the new block matches
# the existing style (e.g. 2-space indent under `ingress:`). Falls back to
# empty (zero-indent) if the catch-all has no leading whitespace.
catchall_indent="$($SUDO sed -n -E "${catchall_line}{s/^([[:space:]]*).*/\\1/p;q;}" "$config")"

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

# Walk the existing route blocks (see cftr_route_blocks in lib.sh).
# Compare hostname/path as exact strings in bash - never as regex source.
#   - already_present: same hostname + same path (or both path-less)
#   - insert_line: normally the catch-all. A --path rule must go ABOVE an
#     existing host-only rule for the same hostname: cloudflared matches
#     top-down, so the host-only rule would otherwise shadow the new path
#     forever. We insert above that rule's own leading comment lines, so
#     its "# Added by ..." note stays attached to it.
already_present="false"
insert_line="$catchall_line"
shadow_note=""
while IFS=$'\t' read -r b_start _ b_cstart b_host b_path; do
    [ "$b_host" = "$hostname" ] || continue
    host_known="true"
    if [ "$b_path" = "$path" ]; then
        already_present="true"
    fi
    if [ -n "$path" ] && [ -z "$b_path" ] && [ -z "$shadow_note" ] && [ "$b_cstart" -lt "$insert_line" ]; then
        insert_line="$b_cstart"
        shadow_note="above the existing host-only rule for $hostname (line $b_start)"
    fi
done < <(cftr_route_blocks "$config")

if [ "$already_present" = "true" ]; then
    echo "==> Ingress entry for $hostname${path:+ + path $path} already exists - skipping config edit."
    if [ "$dry_run" = "true" ]; then
        echo "==> [dry-run] no changes needed."
        exit 0
    fi
else
    echo "==> Inserting ingress block ${shadow_note:-before catch-all}..."
    # Build the candidate config in a private temp file. The block goes
    # in via ENVIRON, NEVER `awk -v`: -v processes backslash escapes (\n,
    # \040, and `\.` -> `.` in gawk/busybox), which would let a --path /
    # --comment smuggle in extra YAML lines.
    tmp="$(mktemp)"
    $SUDO env cftr_block="$new_block" cftr_at="$insert_line" awk '
        NR == ENVIRON["cftr_at"] + 0 {
            n = split(ENVIRON["cftr_block"], lines, "\n")
            for (i = 1; i <= n; i++) print lines[i]
        }
        { print }
    ' "$config" > "$tmp"

    if [ ! -s "$tmp" ]; then
        echo "ERROR: Generated config is empty - aborting" >&2
        exit 1
    fi

    if [ "$dry_run" = "true" ]; then
        if [ "$show_diff" = "true" ]; then
            echo "==> [dry-run] diff against $config:"
        else
            echo "==> [dry-run] would write the following to $config:"
        fi
        show_preview "$config" "$tmp"
        echo
        echo "==> [dry-run] would: validate, create DNS ($binary tunnel route dns $tunnel_id $hostname),"
        echo "                     backup $config, replace it, restart cloudflared ($service_mode${service_unit:+: $service_unit})"
        echo "==> [dry-run] no changes made."
        exit 0
    fi

    # Stage the candidate NEXT TO the config with the original owner, group
    # and mode, then validate THAT file. Permission problems and invalid
    # ingress both surface here - before any DNS record exists.
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
    echo
    echo "==> Validating new config..."
    if ! $SUDO "$binary" --config "$staged" tunnel ingress validate 2>&1; then
        echo "ERROR: Config validation failed - nothing changed (no DNS record, config untouched)." >&2
        exit 1
    fi
fi

# Create the DNS CNAME. Any non-zero exit is a failure - including the
# "An A, AAAA, or CNAME record with that host already exists" CONFLICT,
# where the name points somewhere else. (A record already routed to THIS
# tunnel makes cloudflared exit 0, so re-runs stay idempotent.)
echo
echo "==> Creating DNS CNAME for $hostname..."
dns_log="$(mktemp)"
dns_rc=0
"$binary" tunnel route dns "$tunnel_id" "$hostname" >"$dns_log" 2>&1 || dns_rc=$?
cat "$dns_log"
if [ "$dns_rc" -ne 0 ]; then
    echo "ERROR: Failed to create DNS record (cloudflared exit $dns_rc) - config untouched." >&2
    dns_out="$(cat "$dns_log")"
    if [[ "${dns_out,,}" == *"already exists"* ]]; then
        echo "       $hostname already has an A/AAAA/CNAME record that points elsewhere." >&2
        echo "       If (and only if) you want to repoint it to this tunnel, run yourself:" >&2
        echo "         $binary tunnel route dns --overwrite-dns $tunnel_id $hostname" >&2
        echo "       then re-run this command. This script never overwrites DNS on its own." >&2
    fi
    exit 1
fi
dns_done="true"

if [ "$already_present" = "true" ]; then
    echo
    echo "==> Config unchanged - no restart needed."
    echo "==> Done. Test with: curl -I https://${hostname}${path:-/}"
    exit 0
fi

# Backup, then swap in the staged file with an atomic same-directory rename.
echo
backup="$(cftr_backup)" || {
    echo "ERROR: could not back up $config - config untouched." >&2
    exit 1
}
echo "==> Backed up config to $backup"
cftr_rotate_backups
$SUDO mv -f -- "$staged" "$config"
staged=""
echo "==> Config updated."

# Restart the unit that serves THIS config. On failure, put the backup
# back (same owner/mode, atomic again) and restart once more.
echo
reload_rc=0
cftr_reload || reload_rc=$?
if [ "$reload_rc" -eq 1 ]; then
    echo "ERROR: restoring previous config from $backup" >&2
    if staged="$(cftr_stage "$backup" "$cfg_uid" "$cfg_gid" "$cfg_mode")"; then
        $SUDO mv -f -- "$staged" "$config"
        staged=""
        cftr_reload || echo "ERROR: restart after restore failed too - check the service manually." >&2
    else
        staged=""
        echo "ERROR: could not restore automatically; copy $backup over $config by hand." >&2
    fi
    exit 1
fi

echo
if [ "$reload_rc" -eq 3 ]; then
    echo "==> Config written, but NOT live until cloudflared restarts (exit 3)." >&2
    exit 3
fi
echo "==> Done. Test with: curl -I https://${hostname}${path:-/}"
