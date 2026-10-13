# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # globals are set / used by the callers
# Shared helpers for add-route.sh / remove-route.sh. Sourced, not executed.
#
# Callers must set: SUDO ("" or "sudo"), config, service_mode, service_unit,
# service_candidates, tunnel_id.

# The ONE catch-all pattern (POSIX ERE). Used for counting AND for picking
# the insertion line, so a commented-out `# - service: http_status:404`
# can never be counted as zero yet still receive an insert.
CFTR_CATCHALL_RE='^[[:space:]]*(-[[:space:]]+)?service:[[:space:]]*http_status:404[[:space:]]*$'

# cftr_route_blocks <file>
# One TSV line per `- hostname:` ingress block:
#   start_line  end_line  comment_start  hostname  path
# A block is the `- hostname:` line plus every following line indented
# DEEPER than its dash - keys, comments, nested `- ` list items (Access
# audTag, originRequest) - up to the next non-blank line at dash indent or
# less. Blank lines never extend a block on their own. comment_start is
# the first line of a run of comment lines sitting directly above the
# block at the same indent (or start_line if there is none). Only the
# block's own top-level `path:` key counts. Values are $NF with quotes
# stripped, so they never contain tabs.
cftr_route_blocks() {
    $SUDO awk '
        function indent_of(s) { match(s, /^[ \t]*/); return RLENGTH }
        function strip(v) { gsub(/["'"'"']/, "", v); return v }
        function close_block() {
            if (in_b) printf "%d\t%d\t%d\t%s\t%s\n", bstart, bend, cstart, host, path
            in_b = 0
        }
        /^[[:space:]]*$/ { next }
        {
            ind = indent_of($0)
            if (in_b && ind > dash) {
                bend = NR
                if (!seen_key && $0 !~ /^[[:space:]]*#/) { key_ind = ind; seen_key = 1 }
                if (!seen_path && ind == key_ind && $0 ~ /^[[:space:]]*path:/) {
                    path = strip($NF); seen_path = 1
                }
                next
            }
            close_block()
            if ($0 ~ /^[[:space:]]*-[[:space:]]*hostname:/) {
                in_b = 1; dash = ind; bstart = NR; bend = NR
                seen_key = 0; seen_path = 0; path = ""
                host = strip($NF)
                cstart = (crun_end == NR - 1 && crun_ind == ind) ? crun_start : NR
                next
            }
            if ($0 ~ /^[[:space:]]*#/) {
                if (crun_end == NR - 1 && crun_ind == ind) {
                    crun_end = NR
                } else {
                    crun_start = NR; crun_end = NR; crun_ind = ind
                }
            }
        }
        END { close_block() }
    ' "$1"
}

# cftr_file_meta <file>  ->  "uid gid mode" (GNU stat, then BSD/macOS stat).
cftr_file_meta() {
    $SUDO stat -c '%u %g %a' "$1" 2>/dev/null || $SUDO stat -f '%u %g %Lp' "$1"
}

# cftr_stage <src> <uid> <gid> <mode>
# Copy <src> into a fresh temp file NEXT TO $config (same filesystem, so
# the final mv is an atomic rename) with the given owner/group/mode, and
# print its path. The name must never match "${config}.bak.*".
cftr_stage() {
    local src="$1" uid="$2" gid="$3" mode="$4" staged cur
    staged="$($SUDO mktemp "${config}.cftr-tmp.XXXXXX")" || return 1
    if ! { $SUDO cp "$src" "$staged" && $SUDO chmod "$mode" "$staged"; }; then
        $SUDO rm -f -- "$staged"; return 1
    fi
    cur="$(cftr_file_meta "$staged")" || { $SUDO rm -f -- "$staged"; return 1; }
    if [ "${cur% *}" != "$uid $gid" ] && ! $SUDO chown "$uid:$gid" "$staged"; then
        echo "ERROR: cannot give the new config owner $uid:$gid (same as $config)." >&2
        $SUDO rm -f -- "$staged"; return 1
    fi
    printf '%s\n' "$staged"
}

# cftr_backup  ->  prints the new backup path. Unique per run (mktemp
# suffix), so two runs in the same second never overwrite each other.
cftr_backup() {
    local b
    b="$($SUDO mktemp "${config}.bak.$(date +%Y%m%d-%H%M%S).XXXXXX")" || return 1
    $SUDO cp "$config" "$b" || { $SUDO rm -f -- "$b"; return 1; }
    printf '%s\n' "$b"
}

# Keep only the 5 most recent backups - .bak files contain the credentials
# path and accumulate every run. Only ever called on the apply path.
cftr_rotate_backups() {
    # shellcheck disable=SC2012
    local stale
    mapfile -t stale < <($SUDO ls -1t "${config}".bak.* 2>/dev/null | tail -n +6) || true
    if [ "${#stale[@]}" -gt 0 ]; then
        $SUDO rm -f -- "${stale[@]}"
    fi
}

# cftr_reload
# Restart the cloudflared that serves $config. cloudflared has no reload
# signal (SIGHUP terminates it), so the only safe automatic action is a
# systemctl restart of the ONE unit detect.sh matched to this config.
# Returns 0 = restarted (or nothing running), 1 = restart failed,
#         3 = config is on disk but cloudflared was NOT reloaded.
cftr_reload() {
    case "$service_mode" in
        systemd)
            echo "==> Restarting $service_unit..."
            if $SUDO systemctl restart "$service_unit" && sleep 2 \
                && $SUDO systemctl is-active --quiet "$service_unit"; then
                echo "    Active."
                return 0
            fi
            echo "ERROR: $service_unit failed to start" >&2
            # NOT `systemctl status`: its CGroup lines print the full command
            # line, which can include a tunnel --token.
            $SUDO systemctl show -p ActiveState -p SubState -p Result "$service_unit" >&2 || true
            return 1
            ;;
        ambiguous)
            echo "WARN: config updated but cloudflared was NOT reloaded." >&2
            echo "      Several systemd units reference $config: ${service_candidates//,/ }" >&2
            echo "      Restart the right one: sudo systemctl restart <unit>" >&2
            echo "      (or re-run with CFTR_SERVICE=<unit> so the script can do it)." >&2
            return 3
            ;;
        manual)
            echo "WARN: config updated but cloudflared was NOT reloaded." >&2
            echo "      No systemd unit references $config; cloudflared seems to run by hand." >&2
            echo "      Restart cloudflared manually: stop the running process (Ctrl-C) and start it again:" >&2
            echo "        cloudflared --config $config tunnel run $tunnel_id" >&2
            echo "      (If it IS a systemd unit, re-run with CFTR_SERVICE=<unit>.)" >&2
            return 3
            ;;
        none)
            echo "WARN: cloudflared is not currently running." >&2
            echo "      Start it with: cloudflared --config $config tunnel run $tunnel_id" >&2
            echo "      Or as a service: sudo cloudflared service install" >&2
            return 0
            ;;
        *)
            echo "WARN: config updated but cloudflared was NOT reloaded (service mode: $service_mode)." >&2
            echo "      Restart cloudflared manually." >&2
            return 3
            ;;
    esac
}
